#!/usr/bin/env python3
"""Copy an Erg-built map into Foldspace, or check that Foldspace's copy is current and well formed.

Each Foldspace map is made in the Melange repo (Erg, erg-mcp) and exported there as a source pack: a mod of its own
(`<pack>/spice.json`, `src/<slug>.ergpatch.json`, `assets/meshes/<packId>.<Name>.xom`). Foldspace carries several maps
in ONE mod, so this script renames the map into Foldspace's names as it copies it:

    level stem       <packId>_<slug>          ->  foldspace_<slug>        (Melange names a level <modId>_<slug>)
    mesh names       <packId>.<Name>          ->  foldspace.<slug>_<Name> (a bank's names must start with "<modId>.")
    the patch        src/<slug>.ergpatch.json ->  mod/maps/<slug>/<slug>.ergpatch.json, stem and mesh names rewritten
    the mesh banks   assets/meshes/*.xom      ->  mod/assets/meshes/<slug>/foldspace.<slug>_<Name>.xom, renamed with
                                                  xomtool unpack / pack (a round trip that changes nothing else)
    a level script   sim/<slug>.lua           ->  mod/sim/<slug>.lua (none today)

and rewrites that map's entries in mod/spice.json `levels` and `meshes`, leaving the other maps and every other field alone.
It records where the copy came from (the Melange commit, branch, whether the pack had local changes, and each source
file's SHA-256) in tools/maps.lock.json.

mod/spice.json's `melange.range` is the one place Foldspace's minimum Melange version lives. This script never changes it:
it refuses to sync a pack that asks for a newer Melange than that range allows, so raise the range first (and the README's
"Needs Melange" line, which `--verify` compares with it).

    python sync_map.py caldera                 copy the map in (needs the Melange checkout and xomtool)
    python sync_map.py caldera --check         rebuild the copy in memory and compare it with the committed files
    python sync_map.py --verify                offline: the committed maps, spice.json, README and CHANGELOG agree
                                               (no Melange checkout or xomtool needed)

Where it finds things (flags override the environment):
    --melange <dir>   FOLDSPACE_MELANGE, the Melange checkout whose pack is copied (the source path inside it is in
                      tools/maps.json)
    --pack <dir>      the pack folder itself, instead of the checkout + maps.json path
    --xomtool <exe>   FOLDSPACE_XOMTOOL, then <melange>/dist/tools/xomtool.exe, then `xomtool` on PATH
Stdlib only.
"""
from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

PLUGIN = Path(__file__).resolve().parent.parent
MOD = PLUGIN / "mod"
TOOLS = PLUGIN / "tools"
MOD_ID = "foldspace"
MAPS_JSON = TOOLS / "maps.json"
LOCK_JSON = TOOLS / "maps.lock.json"
SLUG_RE = re.compile(r"^[a-z0-9]{1,24}$")
RANGE_RE = re.compile(r"^>=\s*(\d+)\.(\d+)\.(\d+)$")
README_NEEDS_RE = re.compile(r"Needs Melange (\d+\.\d+\.\d+) or later")


def die(msg: str) -> None:
    sys.exit(f"sync_map: {msg}")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def load_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def dump_json(obj) -> str:
    return json.dumps(obj, indent=2, ensure_ascii=False) + "\n"


def range_floor(text: str) -> tuple[int, int, int]:
    m = RANGE_RE.match((text or "").strip())
    if not m:
        die(f"melange.range {text!r} is not a plain lower bound like '>=0.14.0'")
    return tuple(int(g) for g in m.groups())


# ----------------------------------------------------------------------------------------------- the pure renames


def mesh_name(slug: str, pack_id: str, name: str) -> str:
    """'caldera.Boulder' (pack 'caldera', map 'caldera') -> 'foldspace.caldera_Boulder'."""
    prefix = pack_id + "."
    if not name.startswith(prefix) or len(name) == len(prefix):
        die(f"mesh {name!r} is not named '{prefix}<Name>'")
    return f"{MOD_ID}.{slug}_{name[len(prefix):]}"


def rewrite_patch(text: str, slug: str, pack_id: str, meshes: list[str]) -> str:
    """The pack's patch with Foldspace's level stem and mesh names. Only whole JSON strings are replaced."""
    doc = json.loads(text)
    old_stem, new_stem = f"{pack_id}_{slug}", f"{MOD_ID}_{slug}"
    if doc.get("stem") != old_stem:
        die(f"the patch's stem is {doc.get('stem')!r}, expected {old_stem!r}")
    out = text
    for old, new in [(old_stem, new_stem)] + [(m, mesh_name(slug, pack_id, m)) for m in meshes]:
        out = out.replace(json.dumps(old), json.dumps(new))
    left = sorted(set(re.findall(r'"' + re.escape(pack_id) + r'\.[A-Za-z0-9_]+"', out)))
    if left:
        die(f"the patch names meshes the pack does not ship: {', '.join(left)}")
    if json.loads(out).get("stem") != new_stem:
        die("the stem rewrite failed")
    return out


def rename_bank_json(doc_text: str, pack_id: str, slug: str, name: str) -> str:
    """xomtool-unpacked bank JSON with every string that is the mesh's name, or starts with it plus '_', renamed."""
    new = mesh_name(slug, pack_id, name)
    pat = re.compile(r'"' + re.escape(name) + r'((?:_[A-Za-z0-9_]*)?)"')
    out, count = pat.subn(lambda m: json.dumps(new + m.group(1)), doc_text)
    if count == 0:
        die(f"{name}: the bank never names its mesh")
    if re.search(r'"' + re.escape(pack_id) + r'\.', out):
        die(f"{name}: the bank names another {pack_id}.* mesh")
    return out


# ----------------------------------------------------------------------------------------------- the copy


def find_xomtool(arg: str | None, melange: Path | None) -> str:
    cands = [arg, os.environ.get("FOLDSPACE_XOMTOOL")]
    if melange:
        cands.append(str(melange / "dist" / "tools" / "xomtool.exe"))
    cands.append(shutil.which("xomtool"))
    for c in cands:
        if c and os.path.isfile(c):
            return c
    die("xomtool not found: pass --xomtool <exe> or set FOLDSPACE_XOMTOOL (it is dist/tools/xomtool.exe in a built "
        "Melange checkout)")
    return ""


def git(repo: Path, *args: str) -> str:
    try:
        return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return ""


def build_copy(slug: str, pack: Path, xomtool: str) -> tuple[dict[str, bytes], dict, dict]:
    """The files Foldspace carries for this map (paths relative to mod/), its spice.json level entry and the source facts."""
    spice = load_json(pack / "spice.json")
    pack_id = spice.get("id", "")
    levels = [lv for lv in spice.get("levels", []) if lv.get("slug") == slug]
    if len(levels) != 1:
        die(f"{pack / 'spice.json'} has no level '{slug}'")
    level = dict(levels[0])
    files: dict[str, bytes] = {}
    sources: dict[str, str] = {}

    banks = []
    for entry in spice.get("meshes", []):
        rel = entry["file"]
        name = Path(rel).name[: -len(".xom")]
        banks.append((rel, name))
    names = [n for _, n in banks]

    src_rel = level.get("source") or f"src/{slug}.ergpatch.json"
    raw = (pack / src_rel).read_bytes()
    sources[src_rel] = sha256(raw)
    patch_rel = f"maps/{slug}/{slug}.ergpatch.json"
    files[patch_rel] = rewrite_patch(raw.decode("utf-8"), slug, pack_id, names).encode("utf-8")
    level["source"] = patch_rel

    if level.get("sim"):
        sim = (pack / level["sim"]).read_bytes()
        sources[level["sim"]] = sha256(sim)
        level["sim"] = f"sim/{slug}.lua"
        files[level["sim"]] = sim

    with tempfile.TemporaryDirectory(prefix="foldspace-") as tmp:
        for rel, name in banks:
            bank = (pack / rel).read_bytes()
            sources[rel] = sha256(bank)
            j, out = Path(tmp) / f"{name}.json", Path(tmp) / f"{name}.xom"
            subprocess.run([xomtool, "unpack", str(pack / rel), "-o", str(j)], check=True, capture_output=True)
            j.write_text(rename_bank_json(j.read_text(encoding="utf-8"), pack_id, slug, name), encoding="utf-8")
            subprocess.run([xomtool, "pack", str(j), str(out)], check=True, capture_output=True)
            files[f"assets/meshes/{slug}/{mesh_name(slug, pack_id, name)}.xom"] = out.read_bytes()

    facts = {"packId": pack_id, "packVersion": spice.get("version"), "packRange": spice.get("melange", {}).get("range"),
             "sources": dict(sorted(sources.items()))}
    return files, level, facts


def spice_with(spice: dict, slug: str, level: dict, files: dict[str, bytes]) -> dict:
    out = dict(spice)
    levels = [lv for lv in spice.get("levels", []) if lv.get("slug") != slug] + [level]
    out["levels"] = sorted(levels, key=lambda lv: lv["slug"])
    mesh_prefix = f"assets/meshes/{slug}/"
    meshes = [m for m in spice.get("meshes", []) if not m["file"].startswith(mesh_prefix)]
    meshes += [{"file": rel} for rel in sorted(files) if rel.startswith(mesh_prefix)]
    out["meshes"] = sorted(meshes, key=lambda m: m["file"])
    return out


def resolve_pack(args, maps: dict) -> tuple[Path, Path | None]:
    if args.pack:
        pack = Path(args.pack).resolve()
        melange = Path(args.melange).resolve() if args.melange else None
    else:
        root = args.melange or os.environ.get("FOLDSPACE_MELANGE")
        if not root:
            die("pass --melange <Melange checkout> (or set FOLDSPACE_MELANGE), or --pack <pack folder>")
        melange = Path(root).resolve()
        pack = melange / maps[args.map]["pack"]
    if not (pack / "spice.json").is_file():
        die(f"{pack} is not a pack (no spice.json)")
    if melange is None:
        top = git(pack, "rev-parse", "--show-toplevel")
        melange = Path(top) if top else None
    return pack, melange


def cmd_sync(args) -> int:
    maps = load_json(MAPS_JSON)
    if args.map not in maps:
        die(f"unknown map {args.map!r}; tools/maps.json has {', '.join(sorted(maps))}")
    pack, melange = resolve_pack(args, maps)
    xomtool = find_xomtool(args.xomtool, melange)
    files, level, facts = build_copy(args.map, pack, xomtool)

    spice = load_json(MOD / "spice.json")
    ours, theirs = spice["melange"]["range"], facts["packRange"]
    if range_floor(theirs) > range_floor(ours):
        die(f"the pack asks for Melange {theirs} but mod/spice.json says {ours}: raise melange.range (and the README's "
            "'Needs Melange' line) first")
    new_spice = spice_with(spice, args.map, level, files)

    stale = []
    slug_dirs = [MOD / "maps" / args.map, MOD / "assets" / "meshes" / args.map]
    have = {p.relative_to(MOD).as_posix() for d in slug_dirs if d.is_dir() for p in d.rglob("*") if p.is_file()}
    if (MOD / "sim" / f"{args.map}.lua").is_file():
        have.add(f"sim/{args.map}.lua")
    for rel, data in files.items():
        p = MOD / rel
        if not p.is_file() or p.read_bytes() != data:
            stale.append(rel)
    extra = sorted(have - set(files))
    spice_stale = dump_json(new_spice) != (MOD / "spice.json").read_text(encoding="utf-8")

    if args.check:
        bad = stale + [f"{r} (not in the pack)" for r in extra] + (["spice.json"] if spice_stale else [])
        if bad:
            print("sync_map --check: out of date:\n  " + "\n  ".join(bad), file=sys.stderr)
            return 1
        print(f"sync_map --check: {args.map} matches {pack}")
        return 0

    for rel in extra:
        (MOD / rel).unlink()
    for rel, data in files.items():
        p = MOD / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
    (MOD / "spice.json").write_text(dump_json(new_spice), encoding="utf-8", newline="\n")

    lock = load_json(LOCK_JSON) if LOCK_JSON.is_file() else {}
    src = {}
    if melange:
        dirty = git(melange, "status", "--porcelain", "--", str(pack))
        src = {"commit": git(melange, "rev-parse", "HEAD"), "branch": git(melange, "rev-parse", "--abbrev-ref", "HEAD"),
               "path": pack.relative_to(melange).as_posix() if pack.is_relative_to(melange) else str(pack),
               "localChanges": bool(dirty)}
    lock[args.map] = {"melange": src, **facts, "synced": datetime.date.today().isoformat()}
    LOCK_JSON.write_text(dump_json(dict(sorted(lock.items()))), encoding="utf-8", newline="\n")
    print(f"sync_map: {args.map} copied from {pack}" + (f" ({src['branch']} {src['commit'][:7]}"
          + (", with local changes" if src.get("localChanges") else "") + ")" if src else ""))
    print(f"  {len(files)} files, {len(stale)} changed, {len(extra)} removed; record in tools/maps.lock.json")
    return 0


# ----------------------------------------------------------------------------------------------- the offline check


def verify() -> list[str]:
    errs: list[str] = []
    spice = load_json(MOD / "spice.json")
    maps = load_json(MAPS_JSON)
    lock = load_json(LOCK_JSON) if LOCK_JSON.is_file() else {}
    floor = range_floor(spice["melange"]["range"])
    slugs = [lv["slug"] for lv in spice.get("levels", [])]
    if sorted(slugs) != sorted(maps):
        errs.append(f"spice.json levels {sorted(slugs)} != tools/maps.json {sorted(maps)}")
    if len(slugs) > 32:
        errs.append("more than 32 maps in one mod (Melange's limit)")
    listed = {m["file"] for m in spice.get("meshes", [])}
    on_disk = {p.relative_to(MOD).as_posix() for p in (MOD / "assets").rglob("*.xom")} if (MOD / "assets").is_dir() else set()
    for rel in sorted(on_disk - listed):
        errs.append(f"{rel} is not listed under spice.json meshes")
    for rel in sorted(listed - on_disk):
        errs.append(f"spice.json meshes lists {rel}, which is missing")
    if (MOD / "assets" / "levels").exists():
        errs.append("mod/assets/levels exists: built level files hold modified game data and must not be shipped")
    for lv in spice.get("levels", []):
        slug = lv["slug"]
        if not SLUG_RE.match(slug):
            errs.append(f"level slug {slug!r} must match [a-z0-9]{{1,24}}")
            continue
        if lv.get("source") != f"maps/{slug}/{slug}.ergpatch.json":
            errs.append(f"{slug}: source must be maps/{slug}/{slug}.ergpatch.json")
            continue
        if slug not in lock:
            errs.append(f"{slug}: no record in tools/maps.lock.json (run sync_map.py {slug})")
        patch_path = MOD / lv["source"]
        if not patch_path.is_file():
            errs.append(f"{slug}: {lv['source']} is missing")
            continue
        text = patch_path.read_text(encoding="utf-8")
        doc = json.loads(text)
        if doc.get("stem") != f"{MOD_ID}_{slug}":
            errs.append(f"{slug}: the patch's stem is {doc.get('stem')!r}, Melange wants '{MOD_ID}_{slug}'")
        if doc.get("title") != lv.get("title"):
            errs.append(f"{slug}: the patch's title {doc.get('title')!r} != spice.json's {lv.get('title')!r}")
        named = set(re.findall(r'"resource":\s*"(' + MOD_ID + r'\.[A-Za-z0-9_]+)"', text))
        banks = {}
        for rel in listed:
            if rel.startswith(f"assets/meshes/{slug}/"):
                name = Path(rel).name[: -len(".xom")]
                banks[name] = (MOD / rel).read_bytes() if (MOD / rel).is_file() else b""
        for name, data in sorted(banks.items()):
            if not name.startswith(f"{MOD_ID}.{slug}_"):
                errs.append(f"{slug}: bank {name} is not named '{MOD_ID}.{slug}_<Name>'")
            if data and name.encode() + b"\0" not in data and name.encode() not in data:
                errs.append(f"{slug}: bank {name}.xom does not declare the mesh {name}")
        for name in sorted(named - set(banks)):
            errs.append(f"{slug}: the patch names {name}, which no bank of this map carries")
        for name in sorted(set(banks) - named):
            errs.append(f"{slug}: bank {name} is shipped but the patch never names it")
        rec = lock.get(slug, {})
        if rec.get("packRange") and range_floor(rec["packRange"]) > floor:
            errs.append(f"{slug}: its pack needs Melange {rec['packRange']}, above spice.json's {spice['melange']['range']}")
        if rec.get("melange", {}).get("localChanges"):
            errs.append(f"{slug}: copied from a pack with uncommitted changes; sync it again from a commit")
    readme = (PLUGIN / "README.md").read_text(encoding="utf-8")
    needs = README_NEEDS_RE.findall(readme)
    want = ".".join(str(n) for n in floor)
    if not needs:
        errs.append("README.md has no 'Needs Melange X.Y.Z or later' line")
    for v in needs:
        if v != want:
            errs.append(f"README.md says 'Needs Melange {v}', spice.json melange.range says {want}")
    sys.path.insert(0, str(PLUGIN.parent.parent / "tools"))
    import store  # noqa: E402

    version = spice["version"]
    if store.newest_changelog_version(PLUGIN / "CHANGELOG.md") != version:
        errs.append(f"CHANGELOG.md's newest section is not spice.json's version {version}")
    section = store.changelog_section((PLUGIN / "CHANGELOG.md").read_text(encoding="utf-8"), version)
    if not section.strip() or len(section) > store.MAX_CHANGELOG_CHARS:
        errs.append(f"CHANGELOG {version} is {len(section)} characters as the Store shows it (1-{store.MAX_CHANGELOG_CHARS})")
    return errs


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("map", nargs="?", help="the map's slug (tools/maps.json)")
    ap.add_argument("--check", action="store_true", help="compare a fresh copy with the committed files; write nothing")
    ap.add_argument("--verify", action="store_true", help="offline consistency check of the committed plugin")
    ap.add_argument("--melange", help="the Melange checkout (FOLDSPACE_MELANGE)")
    ap.add_argument("--pack", help="the pack folder, instead of the checkout's path from tools/maps.json")
    ap.add_argument("--xomtool", help="xomtool.exe (FOLDSPACE_XOMTOOL)")
    args = ap.parse_args(argv)
    if args.verify:
        errs = verify()
        if errs:
            print("sync_map --verify:\n  " + "\n  ".join(errs), file=sys.stderr)
            return 1
        print("sync_map --verify: ok")
        return 0
    if not args.map:
        ap.error("name a map, or pass --verify")
    return cmd_sync(args)


if __name__ == "__main__":
    sys.exit(main())
