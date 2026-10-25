#!/usr/bin/env python3
"""Check Holo's CHANGELOG.md the way the Store sees it: the section of the version in mod/spice.json, with wrapped
lines unwrapped (tools/store.py's own function), must exist and be at most 2000 characters.

  python tools/check_changelog.py
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

PLUGIN = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(PLUGIN.parent.parent / "tools"))
import store  # noqa: E402


def main() -> int:
    version = json.loads((PLUGIN / "mod" / "spice.json").read_text(encoding="utf-8"))["version"]
    newest = store.newest_changelog_version(PLUGIN / "CHANGELOG.md")
    if newest != version:
        print(f"check_changelog: newest CHANGELOG heading is {newest!r}, spice.json says {version!r}", file=sys.stderr)
        return 1
    section = store.changelog_section((PLUGIN / "CHANGELOG.md").read_text(encoding="utf-8"), version)
    if not section.strip():
        print(f"check_changelog: the {version} section is empty", file=sys.stderr)
        return 1
    if len(section) > store.MAX_CHANGELOG_CHARS:
        print(f"check_changelog: {version} is {len(section)} characters unwrapped (limit {store.MAX_CHANGELOG_CHARS})",
              file=sys.stderr)
        return 1
    print(f"check_changelog: ok ({len(section)} of {store.MAX_CHANGELOG_CHARS} characters)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
