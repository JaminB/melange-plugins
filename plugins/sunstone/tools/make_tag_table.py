#!/usr/bin/env python3
"""Write Sunstone's texture tag table (mod/texture_tags.json) for Melange's texture tags (mg_texTag).

A development tool, not part of the plugin. Each lit model texture of the inventory gets a row: its class id and the
7 parameters (scale, strength, rough, wear, tint, a, b), keyed by the digest of its base level (tools/tag_digest.py,
a PLACEHOLDER until Melange's reference scheme lands). The table holds only digests and numbers: nothing of a game
texture ships.

Inputs (the inventory is never committed; pass its folder or set SUNSTONE_INVENTORY):
  <inventory>/inventory.json     the 712 textures (id = 16-hex digest, size, format, material, ...)
  <inventory>/classes.json       the class decision per texture: [{"id": <6 or 16 hex>, "cls": <class>, ...}]
  tools/materials/classes.json   class names and ids
  tools/materials/<class>.glsl   each class's default parameters ('// @default' line; generic.glsl for the rest)
  tools/materials/overrides.json and tools/materials/overrides/*.json   per-texture overrides (optional)

    python tools/make_tag_table.py --inventory <dir>            # write mod/texture_tags.json
    python tools/make_tag_table.py --inventory <dir> --check    # exit 1 when the table is out of date
    python tools/make_tag_table.py --inventory <dir> --by-id t.json   # also a dev table keyed by inventory id

Decision ids may be 6-character prefixes of inventory ids: each must match exactly one texture (else it fails).
"""
import argparse
import collections
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
FORMAT = 1


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


def build(inventory_dir, overrides_paths):
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
    tags, by_id = {}, {}
    entries = {e["id"]: e for e in inv}
    for tid in sorted(chosen):
        c = chosen[tid]
        cls = by_name[c["cls"]]
        p = dict(cls["defaults"])
        p.update(c["params"])
        vals = [cls["id"]] + [round(float(p[k]), 4) for k in build_materials.PARAMS]
        dg = tag_digest.digest_entry(entries[tid])
        if dg in tags and tags[dg] != vals:
            raise Fail(f"two textures share digest {dg} with different tags")
        tags[dg] = vals
        by_id[tid] = {"cls": c["cls"], "tag": vals, "digest": dg}
    missing = [i for i in ids if i not in chosen]
    return tags, by_id, missing, rows


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
    ap.add_argument("--out", default=str(OUT), help="the table (default mod/texture_tags.json)")
    ap.add_argument("--by-id", help="also write {inventory id: {cls, tag, digest}} here (dev only: the preview's lookup)")
    ap.add_argument("--check", action="store_true", help="exit 1 when --out is out of date; write nothing")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()
    if not args.inventory:
        sys.exit("pass --inventory <dir> or set SUNSTONE_INVENTORY")
    paths = OVERRIDES + (sorted(OVERRIDE_DIR.glob("*.json")) if OVERRIDE_DIR.is_dir() else [])
    try:
        tags, by_id, missing, rows = build(Path(args.inventory), paths)
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
        print("  " + ", ".join(f"{k} {n}" for k, n in per.most_common()))


if __name__ == "__main__":
    main()
