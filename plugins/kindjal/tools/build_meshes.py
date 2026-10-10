#!/usr/bin/env python3
"""Build Kindjal's static mesh banks (19) with `xomtool convert --bundle`.

    python build_meshes.py            write ../mod/assets/meshes/kindjal.*.xom
    python build_meshes.py --check    rebuild into a temp folder, compare byte for byte with the files on disk
                                      (exit 1 on a difference or a missing file)

Inputs are tools/meshes/<name>.gltf + .bin + .png (make_meshes.py) and the vanilla Bundl09.xom, which is read only:
each bank borrows the shader of one vanilla mesh and swaps its texture for ours. Stdlib only.
"""
import argparse
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # the helper sits beside this file
import _paths  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.normpath(os.path.join(HERE, "..", "mod", "assets", "meshes"))
MESH_DIR = os.path.join(HERE, "meshes")

DEFAULT_XOMTOOL = _paths.default_xomtool()
DEFAULT_GAME_DATA = _paths.default_game_data()

# (source name, resource id, mod section, vanilla mesh whose shader is borrowed)
BANKS = [
    ("nail_bat", "kindjal.NailBat", 476, "BaseballBat"),
    ("acid_flask", "kindjal.AcidFlask", 477, "GasCanister"),
    ("acid_round", "kindjal.AcidRound", 478, "Bazooka.Payload"),
    ("crucible", "kindjal.Crucible", 479, "HolyHandGrenade"),
    ("shiv", "kindjal.Shiv", 480, "BaseballBat"),
    ("gauntlet", "kindjal.Gauntlet", 481, "BaseballBat"),
    ("railspike", "kindjal.Railspike", 482, "TailNail"),
    ("ripper_launcher", "kindjal.RipperLauncher", 483, "Bazooka.Weapon"),
    ("ripper_rocket", "kindjal.RipperRocket", 484, "Bazooka.Payload"),
    ("pipe_bomb", "kindjal.PipeBomb", 485, "Grenade.Payload"),
    ("blast_keg", "kindjal.BlastKeg", 486, "Dynamite"),
    ("profane_grenade", "kindjal.ProfaneGrenade", 487, "HolyHandGrenade"),
    ("plantain_bananas", "kindjal.Plantains", 488, "BananaBomb"),
    ("elephant_gun", "kindjal.ElephantGun", 489, "SniperRifle"),
    ("rust_canister", "kindjal.RustCanister", 490, "GasCanister"),
    ("field_radio", "kindjal.FieldRadio", 491, "Radio"),
    ("stone_donkey", "kindjal.StoneDonkey", 492, "Donkey"),
    ("plague_arrow", "kindjal.PlagueArrow", 493, "Arrow"),
    ("inflated_knifeman", "kindjal.InflatedKnifeman", 494, "InflatedScouser"),
]


def build(xomtool, bundle09, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    for src, rid, section, material in BANKS:
        out = os.path.join(out_dir, rid + ".xom")
        cmd = [
            xomtool, "convert", os.path.join(MESH_DIR, src + ".gltf"),
            "--bundle", out, "--as", rid, "--section", str(section),
            "--material-from", material, "--material-file", bundle09,
            "--texture", os.path.join(MESH_DIR, src + ".png"), "--scene-bin", "8",
        ]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit("xomtool failed for %s (exit %d): %s" % (rid, r.returncode, (r.stderr or r.stdout).strip()))
        print("built %s (section %d, material %s, %d bytes)" % (rid, section, material, os.path.getsize(out)))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--xomtool", default=DEFAULT_XOMTOOL, help="path to xomtool.exe (needs convert --bundle)")
    ap.add_argument("--game-data", default=DEFAULT_GAME_DATA, help="the game's Data folder (read only; or set KINDJAL_GAME_DATA)")
    ap.add_argument("--check", action="store_true", help="compare a fresh build with the files on disk")
    args = ap.parse_args()

    bundle09 = os.path.join(args.game_data, "Bundles", "Bundl09.xom") if args.game_data else ""
    _paths.require_tools(args.xomtool, bundle09)

    if not args.check:
        build(args.xomtool, bundle09, OUT_DIR)
        return
    bad = 0
    with tempfile.TemporaryDirectory() as tmp:
        build(args.xomtool, bundle09, tmp)
        for _, rid, _, _ in BANKS:
            name = rid + ".xom"
            with open(os.path.join(tmp, name), "rb") as f:
                fresh = f.read()
            disk_path = os.path.join(OUT_DIR, name)
            if not os.path.isfile(disk_path):
                print("MISSING " + disk_path)
                bad += 1
                continue
            with open(disk_path, "rb") as f:
                disk = f.read()
            if disk != fresh:
                print("DIFFERS " + name)
                bad += 1
            else:
                print("ok      " + name)
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
