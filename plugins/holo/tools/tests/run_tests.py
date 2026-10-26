#!/usr/bin/env python3
"""Run every tools/tests/test_*.lua with lua54_cli (MELANGE_LUA, or the core worktree's x86-release build).

  python tools/tests/run_tests.py [name-substring ...]

Each test runs in its own process with package.path set to tools/tests/?.lua and the working directory at the plugin
folder, and exits non-zero on failure. The generated init.lua must be up to date first.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

TESTS = Path(__file__).resolve().parent
PLUGIN = TESTS.parent.parent
sys.path.insert(0, str(PLUGIN / "tools"))
import build_lua  # noqa: E402


def main(argv) -> int:
    lua = build_lua.find_lua()
    if lua is None:
        print("run_tests: lua54_cli not found; set MELANGE_LUA or build it: "
              "cmake --build --preset x86-release --target lua54_cli (in the core worktree)", file=sys.stderr)
        return 2
    if build_lua.main(["--check"]) != 0:
        return 1
    files = sorted(TESTS.glob("test_*.lua"))
    if argv:
        files = [f for f in files if any(a in f.name for a in argv)]
    if not files:
        print("run_tests: no tests matched", file=sys.stderr)
        return 1
    prelude = "package.path = [[" + TESTS.as_posix() + "/?.lua]]"
    failed = 0
    for f in files:
        r = subprocess.run([str(lua), "-e", prelude, str(f)], cwd=PLUGIN, capture_output=True, text=True)
        out = (r.stdout + r.stderr).strip()
        print(("ok   " if r.returncode == 0 else "FAIL ") + f.name)
        if r.returncode != 0:
            failed += 1
            print("\n".join("     " + ln for ln in out.splitlines()))
        elif out:
            print("\n".join("     " + ln for ln in out.splitlines()[-3:]))
    print(f"run_tests: {len(files) - failed}/{len(files)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
