#!/usr/bin/env python3
"""Write Sunstone's texture tag table (mod/texture_tags.json) for Melange's texture tags (mg_texTag).

A development tool, not part of the plugin. Each lit model texture of the inventory gets a row: its class id and the
7 parameters (scale, strength, rough, wear, tint, a, b), keyed by Melange's texture digest (tools/tag_digest.py, scheme gl-level0-sha256-64, a copy of Melange's reference
implementation). The digests are computed straight from the game's bundles and the Kindjal meshes with the XOM reader.
The table holds only digests and numbers: nothing of a game texture ships.

Inputs (the inventory is never committed; pass its folder or set SUNSTONE_INVENTORY):
  <inventory>/inventory.json     the 712 textures (id = legacy sha1 key of the base level, size, format, ...)
  <inventory>/classes.json       the class decision per texture: [{"id": <6 or 16 hex>, "cls": <class>, ...}]
  tools/materials/classes.json   class names and ids
  tools/materials/<class>.glsl   each class's default parameters ('// @default' line; generic.glsl for the rest)
  tools/materials/overrides.json and tools/materials/overrides/*.json   per-texture overrides (optional)

    python tools/make_tag_table.py --inventory <dir>            # write mod/texture_tags.json
    python tools/make_tag_table.py --inventory <dir> --check    # exit 1 when the table is out of date
    python tools/make_tag_table.py --inventory <dir> --by-id t.json   # also a dev table keyed by inventory id

Texture data (defaults: the Steam install, tools/xom of a WUMFix checkout, the repo's kindjal*/mod/assets/meshes):
  --bundles <Data/Bundles>   $WORMS_BUNDLES        --xom <WUMFix/tools/xom>   $WUM_XOM        --extra <glob> (repeatable)
Each inventory texture is found among the XImages by its legacy id, then digested; one that no XImage matches, or two
inventory textures with one digest but different tags, is an error.

Decision ids may be 6-character prefixes of inventory ids: each must match exactly one texture (else it fails).
"""
import argparse
import collections
import glob
import hashlib
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_materials  # noqa: E402
import tag_digest  # noqa: E402

HERE = Path(__file__).resolve().parent
PLUGIN = HERE.parent
OUT = PLUGIN / "mod" / "texture_tags.json"
OVERRIDES = [HERE / "materials" / "overrides.json"]
OVERRIDE_DIR = HERE / "materials" / "overrides"
REPO = PLUGIN.parent.parent
FORMAT = 1
DEFAULT_BUNDLES = "C:/Program Files (x86)/Steam/steamapps/common/WormsXHD/Data/Bundles"
DEFAULT_XOM = "C:/Users/Jamin/Desktop/WUMFix/tools/xom"


class Fail(Exception):
    pass


def resolve(prefix, ids, what):
    """The one inventory id that starts with prefix (6+ hex characters)."""
    p = str(prefix).lower()
    if len(p) < 6 or any(ch not in "0123456789abcdef" for ch in p):
        raise Fail(f"{what}: {prefix!r} is not a 6 to 16 character hex id")
    hits = [i for i in ids if i.startswith(p)]
    if not hits:
        raise Fail(f"{what}: {prefix!r} matches no texture of the inventory")
    if len(hits) > 1:
        raise Fail(f"{what}: {prefix!r} is ambiguous ({', '.join(hits)})")
    return hits[0]


def load_overrides(paths):
    """({key: (file, override)}, {mistyped decision id: corrected id}) from the override files."""
    out, fixes = {}, {}
    for p in paths:
        if not p.exists():
            continue
        data = json.loads(p.read_text(encoding="utf-8"))
        rows = data.get("overrides", {})
        if not isinstance(rows, dict):
            raise Fail(f"{p}: 'overrides' must be an object")
        for k, v in rows.items():
            if k in out:
                raise Fail(f"{p}: {k!r} is overridden in {out[k][0]} too")
            out[k] = (p.name, v)
        for bad, good in data.get("decision_fixes", {}).items():
            if bad in fixes:
                raise Fail(f"{p}: decision fix {bad!r} is given twice")
            fixes[bad] = good
    return out, fixes


def legacy_id(w, h, fmt, data):
    """The inventory's own key for a texture (RGB8/RGBA8 only): sha1 of the base level + b"w,h,fmt", first 16 hex."""
    return hashlib.sha1(data + b"%d,%d,%d" % (w, h, fmt)).hexdigest()[:16]


def _scan_file(path):
    import xom
    out = []
    for o in xom.load(path)["objects"]:
        f = o.get("fields")
        if o.get("type") != "XImage" or not isinstance(f, dict) or "Width" not in f or f.get("Format") not in (0, 1):
            continue
        w, h, fmt = f["Width"], f["Height"], f["Format"]
        raw = f["Data"]
        data = bytes.fromhex(raw["hex"]) if isinstance(raw, dict) else bytes(raw)
        data = data[: w * h * (3 if fmt == 0 else 4)]
        out.append((legacy_id(w, h, fmt, data), tag_digest.digest_ximage(f), os.path.basename(path)))
    return out


def _init(xom_dir):
    sys.path.insert(0, xom_dir)


def scan_digests(bundles, xom_dir, extra_globs):
    """{legacy id: {digest: [file, ...]}} for every RGB8/RGBA8 XImage of the bundles and the extra meshes."""
    from multiprocessing import Pool
    paths = sorted(glob.glob(os.path.join(bundles, "*.xom")))
    for g in extra_globs:
        paths += sorted(glob.glob(g))
    if not paths:
        raise Fail(f"no .xom files under {bundles}")
    sys.path.insert(0, xom_dir)
    try:
        import xom  # noqa: F401
    except ImportError:
        raise Fail(f"the XOM reader (xom.py) is not in {xom_dir}")
    found = {}
    with Pool(8, _init, (xom_dir,)) as pool:
        for res in pool.imap(_scan_file, paths, chunksize=4):
            for lid, dg, fname in res:
                found.setdefault(lid, {}).setdefault(dg, []).append(fname)
    return found


def build(inventory_dir, overrides_paths, found):
    inv = json.loads((inventory_dir / "inventory.json").read_text(encoding="utf-8"))
    decisions = json.loads((inventory_dir / "classes.json").read_text(encoding="utf-8"))
    rows, _, _ = build_materials.class_table()
    by_name = {r["name"]: r for r in rows if r["id"] > 0}
    ids = [e["id"] for e in inv]
    if len(set(ids)) != len(ids):
        raise Fail("inventory.json: duplicate ids")
    errors = []
    chosen = {}
    overrides, fixes = load_overrides(overrides_paths)
    for d in decisions:
        try:
            tid = resolve(fixes.get(d.get("id", ""), d.get("id", "")), ids, "classes.json")
        except Fail as e:
            errors.append(str(e))
            continue
        if d.get("cls") not in by_name:
            errors.append(f"classes.json: {d.get('id')}: unknown class {d.get('cls')!r}")
            continue
        if tid in chosen:
            errors.append(f"classes.json: {tid} is decided twice ({chosen[tid]['src']} and {d.get('id')})")
            continue
        chosen[tid] = {"cls": d["cls"], "src": d.get("id"), "params": {}}
    for key, (fname, ov) in overrides.items():
        try:
            tid = resolve(key, ids, fname)
        except Fail as e:
            errors.append(str(e))
            continue
        if not isinstance(ov, dict):
            errors.append(f"{fname}: {key}: must be an object")
            continue
        row = chosen.setdefault(tid, {"cls": None, "src": key, "params": {}})
        for k, v in ov.items():
            if k == "cls":
                if v not in by_name:
                    errors.append(f"{fname}: {key}: unknown class {v!r}")
                row["cls"] = v
            elif k in build_materials.PARAMS:
                lo, hi = build_materials.PARAM_RANGES[k]
                if not isinstance(v, (int, float)) or not lo <= v <= hi:
                    errors.append(f"{fname}: {key}: {k}={v!r} must be a number in {lo}..{hi}")
                row["params"][k] = v
            elif not k.startswith("_"):
                errors.append(f"{fname}: {key}: unknown field {k!r}")
        if row["cls"] is None:
            errors.append(f"{fname}: {key}: the texture has no class decision, so the override needs 'cls'")
    if errors:
        raise Fail("\n".join(errors))
    tags, by_id, owner, unmatched, same_class = {}, {}, {}, [], []
    for tid in sorted(chosen):
        c = chosen[tid]
        cls = by_name[c["cls"]]
        p = dict(cls["defaults"])
        p.update(c["params"])
        vals = [cls["id"]] + [round(float(p[k]), 4) for k in build_materials.PARAMS]
        hit = found.get(tid)
        if not hit:
            unmatched.append(tid)
            continue
        if len(hit) > 1:
            raise Fail(f"inventory texture {tid} matches XImages with different digests: {sorted(hit)}")
        dg = next(iter(hit))
        if dg in owner and tags[dg] != vals:
            raise Fail(f"digest {dg} is shared by inventory textures {owner[dg]} and {tid} with different tags")
        if dg in owner:
            same_class.append((dg, owner[dg], tid))
        owner[dg] = tid
        tags[dg] = vals
        by_id[tid] = {"cls": c["cls"], "tag": vals, "digest": dg}
    if unmatched:
        raise Fail(f"{len(unmatched)} inventory textures match no XImage of the bundles/meshes: {', '.join(unmatched)}")
    missing = [i for i in ids if i not in chosen]
    return tags, by_id, missing, rows, same_class


def dump(tags, rows):
    """Diff-friendly JSON: one tag per line."""
    def num(v):
        return str(int(v)) if float(v).is_integer() else f"{v:g}"
    head = {
        "format": FORMAT,
        "digest": tag_digest.SCHEME,
        "fields": ["class"] + build_materials.PARAMS,
        "classes": [r["name"] for r in rows],
    }
    lines = ["{"]
    for k, v in head.items():
        lines.append(f"  {json.dumps(k)}: {json.dumps(v)},")
    lines.append('  "tags": {')
    items = sorted(tags.items())
    for i, (dg, vals) in enumerate(items):
        comma = "," if i + 1 < len(items) else ""
        lines.append(f"    {json.dumps(dg)}: [{', '.join(num(v) for v in vals)}]{comma}")
    lines.append("  }")
    lines.append("}")
    return "\n".join(lines) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--inventory", default=os.environ.get("SUNSTONE_INVENTORY"),
                    help="folder with inventory.json and classes.json (default: $SUNSTONE_INVENTORY)")
    ap.add_argument("--bundles", default=os.environ.get("WORMS_BUNDLES", DEFAULT_BUNDLES), help="the game's Data/Bundles")
    ap.add_argument("--xom", default=os.environ.get("WUM_XOM", DEFAULT_XOM), help="folder with the XOM reader (xom.py)")
    ap.add_argument("--extra", action="append", default=None,
                    help="more .xom files (glob, repeatable; default: the repo's kindjal*/mod/assets/meshes/*.xom)")
    ap.add_argument("--out", default=str(OUT), help="the table (default mod/texture_tags.json)")
    ap.add_argument("--by-id", help="also write {inventory id: {cls, tag, digest}} here (dev only: the preview's lookup)")
    ap.add_argument("--check", action="store_true", help="exit 1 when --out is out of date; write nothing")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()
    if not args.inventory:
        sys.exit("pass --inventory <dir> or set SUNSTONE_INVENTORY")
    paths = OVERRIDES + (sorted(OVERRIDE_DIR.glob("*.json")) if OVERRIDE_DIR.is_dir() else [])
    extra = args.extra if args.extra is not None else [str(REPO / "plugins" / "kindjal*" / "mod" / "assets" / "meshes" / "*.xom")]
    try:
        found = scan_digests(args.bundles, args.xom, extra)
        tags, by_id, missing, rows, same_class = build(Path(args.inventory), paths, found)
    except Fail as e:
        sys.exit(str(e))
    text = dump(tags, rows)
    if args.by_id:
        Path(args.by_id).write_text(json.dumps(by_id, indent=0, sort_keys=True), encoding="utf-8")
    out = Path(args.out)
    if args.check:
        old = out.read_text(encoding="utf-8").replace("\r\n", "\n") if out.exists() else ""
        if old != text:
            sys.exit(f"{out} is out of date: run tools/make_tag_table.py")
    else:
        out.write_text(text, encoding="utf-8", newline="\n")
    if not args.quiet:
        per = collections.Counter(v["cls"] for v in by_id.values())
        print(f"{len(tags)} tags ({len(missing)} inventory textures without a decision) -> {out}"
              + ("" if not args.check else " (up to date)"))
        print(f"  {len(by_id)} inventory textures digested, none unmatched; {len(same_class)} digests shared by textures of one tag")
        print("  " + ", ".join(f"{k} {n}" for k, n in per.most_common()))


if __name__ == "__main__":
    main()
