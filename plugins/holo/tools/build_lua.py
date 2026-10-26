#!/usr/bin/env python3
"""Join Holo's Lua fragments (src/NN_name.lua, in name order) into mod/client/init.lua.

  python tools/build_lua.py            write mod/client/init.lua
  python tools/build_lua.py --check    fail if the committed file differs from a fresh build (byte compare)

Besides joining, it lints the result: no BOM, LF only, every fragment present, fewer than 190 top-level locals
(Lua's hard limit is 200 and the game loads the client entry as one chunk), and, when lua54_cli is found
(MELANGE_LUA, or the core worktree's build\\x86-release\\lua54_cli.exe next to this repo), a syntax check of the output.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

PLUGIN = Path(__file__).resolve().parent.parent
SRC = PLUGIN / "src"
OUT = PLUGIN / "mod" / "client" / "init.lua"
FRAGMENT_RE = re.compile(r"^\d\d_[a-z0-9_]+\.lua$")
MAX_TOP_LOCALS = 190
# These must all exist (a stub is fine): the fragment list of the design.
REQUIRED = ["00_header", "10_util", "20_config", "30_net", "40_party", "45_queue", "50_layout", "55_atlas",
            "60_skin", "70_widgets", "80_player_ui", "85_setup", "90_main"]


def find_lua() -> Path | None:
    env = os.environ.get("MELANGE_LUA")
    candidates = [Path(env)] if env else []
    # plugins/holo -> repo root -> its parent (the Desktop folder that also holds the core worktrees)
    base = PLUGIN.parent.parent.parent
    for wt in ("melange-wt-holo", "melange"):
        candidates.append(base / wt / "build" / "x86-release" / "lua54_cli.exe")
    for c in candidates:
        if c.is_file():
            return c
    return None


def fragments() -> list[Path]:
    files = sorted(p for p in SRC.iterdir() if p.is_file() and p.suffix == ".lua")
    bad = [p.name for p in files if not FRAGMENT_RE.match(p.name)]
    if bad:
        raise SystemExit(f"build_lua: fragment names must look like 10_name.lua: {', '.join(bad)}")
    have = {p.stem for p in files}
    missing = [n for n in REQUIRED if n not in have]
    if missing:
        raise SystemExit(f"build_lua: missing fragments: {', '.join(missing)}")
    return files


def read_fragment(p: Path) -> str:
    raw = p.read_bytes()
    if raw.startswith(b"\xef\xbb\xbf"):
        raise SystemExit(f"build_lua: {p.name} has a BOM")
    if b"\r" in raw:
        raise SystemExit(f"build_lua: {p.name} has CR characters (use LF)")
    text = raw.decode("utf-8")
    return text if text.endswith("\n") else text + "\n"


def build() -> str:
    parts = []
    for p in fragments():
        parts.append(f"-- ==== src/{p.name} ====\n" + read_fragment(p))
    return "\n".join(parts)


LOCAL_RE = re.compile(r"^local\s+(function\s+)?([^=]*?)(=|$)")


def top_level_locals(text: str) -> int:
    """Count the names declared by 'local' statements that start in column 0 (outside long strings and comments)."""
    count = 0
    in_long = None
    for line in text.split("\n"):
        if in_long:
            if in_long in line:
                in_long = None
            continue
        m = re.match(r"^(?:--)?\[(=*)\[", line)
        if m and "]" + m.group(1) + "]" not in line:
            in_long = "]" + m.group(1) + "]"
            continue
        m = LOCAL_RE.match(line)
        if m:
            names = m.group(2)
            count += 1 if m.group(1) else len([n for n in names.split(",") if n.strip()])
    return count


def lint(text: str, lua: Path | None) -> list[str]:
    errors = []
    if text.startswith("﻿"):
        errors.append("BOM")
    n = top_level_locals(text)
    if n >= MAX_TOP_LOCALS:
        errors.append(f"{n} top-level locals (limit {MAX_TOP_LOCALS})")
    if lua:
        tmp = OUT.with_suffix(".lintcheck.lua")
        tmp.parent.mkdir(parents=True, exist_ok=True)
        tmp.write_bytes(text.encode("utf-8"))
        try:
            r = subprocess.run([str(lua), "-e", f"assert(loadfile([[{tmp}]]))"], capture_output=True, text=True)
        finally:
            tmp.unlink(missing_ok=True)
        if r.returncode != 0:
            errors.append("syntax: " + (r.stderr or r.stdout).strip())
    return errors


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="fail if mod/client/init.lua is not up to date")
    ap.add_argument("--no-lua", action="store_true", help="skip the lua54_cli syntax check")
    args = ap.parse_args(argv)

    text = build()
    data = text.encode("utf-8")
    lua = None if args.no_lua else find_lua()
    if lua is None and not args.no_lua:
        print("build_lua: lua54_cli not found (set MELANGE_LUA); skipping the syntax check", file=sys.stderr)
    errors = lint(text, lua)
    if errors:
        print("build_lua: " + "; ".join(errors), file=sys.stderr)
        return 1
    if args.check:
        if not OUT.is_file() or OUT.read_bytes() != data:
            print("build_lua: mod/client/init.lua is out of date; run tools/build_lua.py", file=sys.stderr)
            return 1
        print(f"build_lua: ok ({top_level_locals(text)} top-level locals)")
        return 0
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(data)
    print(f"build_lua: wrote {OUT.relative_to(PLUGIN)} ({len(data)} bytes, {top_level_locals(text)} top-level locals)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
