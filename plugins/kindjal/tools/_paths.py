"""Where the mesh generators find xomtool and the game's Bundl09.xom.

Nothing here is a machine-specific path. Each lookup tries, in order:

    xomtool    KINDJAL_XOMTOOL, then `xomtool` on PATH
    Bundl09    KINDJAL_BUNDL09 (the file), then KINDJAL_GAME_DATA (the game's Data folder) + Bundles/Bundl09.xom

The command line flags (--xomtool, --bundl09, --game-data) override these. If nothing is found the generators stop
with a message that names the flag and the environment variable to set, instead of failing inside subprocess.
"""
import os
import shutil
import sys


def default_xomtool():
    return os.environ.get("KINDJAL_XOMTOOL") or shutil.which("xomtool") or ""


def default_game_data():
    return os.environ.get("KINDJAL_GAME_DATA", "")


def default_bundl09():
    env = os.environ.get("KINDJAL_BUNDL09")
    if env:
        return env
    data = default_game_data()
    return os.path.join(data, "Bundles", "Bundl09.xom") if data else ""


def require_tools(xomtool, bundl09):
    """Exit with a readable message unless xomtool and Bundl09.xom exist."""
    if not xomtool or not os.path.isfile(xomtool):
        sys.exit("xomtool not found (%s). Pass --xomtool <path> or set KINDJAL_XOMTOOL, or put xomtool on PATH."
                 % (xomtool or "no path given"))
    if not bundl09 or not os.path.isfile(bundl09):
        sys.exit("Bundl09.xom not found (%s). Pass --bundl09 <path> (--game-data <Data folder> for build_meshes.py) "
                 "or set KINDJAL_BUNDL09 or KINDJAL_GAME_DATA." % (bundl09 or "no path given"))


def require_slugs(requested, known):
    """Exit on an unknown --only slug, so a typo cannot turn --check into a check of nothing."""
    unknown = [s for s in requested if s not in known]
    if unknown:
        sys.exit("unknown slug %s (have %s)" % (", ".join(unknown), ", ".join(sorted(known))))
