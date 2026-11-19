#!/usr/bin/env python3
"""Build Kindjal's static mesh banks (19 + the Grave Spade bank) with `xomtool convert --bundle`.

    python build_meshes.py            write ../mod/assets/meshes/kindjal.*.xom, gravespade.xom and the client copies
    python build_meshes.py --check    rebuild into a temp folder, compare byte for byte with the files on disk
                                      (exit 1 on a difference or a missing file)

Inputs are tools/meshes/<name>.gltf + .bin + .png (make_meshes.py) and the vanilla Bundl09.xom, which is read only:
each bank borrows the shader of one vanilla mesh and swaps its texture for ours. Stdlib only.

`gravespade.xom` is one bank holding two meshes (kindjal.GraveSpade and the invisible kindjal.GraveSpadeHidden), so the
pair costs one of the 44 mod sections: each is converted on its own, then the two are joined the way a vanilla
BundlNN.xom is laid out (`merge_docs`, a port of Melange's tools/erg-mcp/bench/caldera/meshes/merge.mjs over
`xomtool unpack` / `pack`). The client also gets the spade as plain data it can draw with wum.draw.mesh
(`gravespade.mesh.txt` + `gravespade.png`, see `kjm_text`).
"""
import argparse
import json
import os
import struct
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

# Banks with several meshes: (file, section, [(source name, resource id, vanilla mesh whose shader is borrowed)])
MULTI = [
    ("gravespade.xom", 495, [("gravespade", "kindjal.GraveSpade", "BaseballBat"),
                             ("gravespade_hidden", "kindjal.GraveSpadeHidden", "BaseballBat")]),
]

# Meshes the client draws itself (wum.draw.mesh): source name -> file stem in ../mod/assets/meshes (.mesh.txt + .png)
CLIENT = [("gravespade", "gravespade")]


def _num(x):
    """Four decimals, trailing zeros dropped, no negative zero."""
    t = ("%.4f" % x).rstrip("0").rstrip(".")
    return "0" if t in ("-0", "") else t


def kjm_text(fpv, verts, idx):
    """Kindjal's client mesh format `KJM1`, as text (the store accepts no binary data files): a header line
    "KJM1 <floats per vertex> <vertex count> <index count>", then one line per vertex (8 numbers: x y z nx ny nz u v;
    12 adds r g b a), then the indices, three per line (0-based, counter-clockwise seen from outside). u, v are glTF
    texture coordinates (v measured down from the top row of the PNG). Lua 5.4 reads it with string.gmatch("%S+") and
    tonumber; add 1 to each index for wum.draw.mesh. Numbers are fixed-point, so the file is the same on every run."""
    lines = ["KJM1 %d %d %d" % (fpv, len(verts), len(idx))]
    for v in verts:
        lines.append(" ".join(_num(x) for x in v))
    for k in range(0, len(idx), 3):
        lines.append("%d %d %d" % tuple(idx[k:k + 3]))
    return ("\n".join(lines) + "\n").encode("ascii")


def write_kjm(gltf_path):
    """A glTF (one primitive: POSITION, NORMAL, TEXCOORD_0, u16 indices) as `kjm_text` with 8 floats per vertex."""
    with open(gltf_path, "r", encoding="utf-8") as f:
        g = json.load(f)
    with open(os.path.join(os.path.dirname(gltf_path), g["buffers"][0]["uri"]), "rb") as f:
        b = f.read()

    def acc(i, fmt, width):
        a = g["accessors"][i]
        v = g["bufferViews"][a["bufferView"]]
        start = v.get("byteOffset", 0) + a.get("byteOffset", 0)
        vals = struct.unpack_from("<%d%s" % (a["count"] * width, fmt), b, start)
        return [vals[k:k + width] for k in range(0, len(vals), width)]
    p = g["meshes"][0]["primitives"][0]
    pos = acc(p["attributes"]["POSITION"], "f", 3)
    nrm = acc(p["attributes"]["NORMAL"], "f", 3)
    uv = acc(p["attributes"]["TEXCOORD_0"], "f", 2)
    idx = [i[0] for i in acc(p["indices"], "H", 1)]
    return kjm_text(8, [q + n + t for q, n, t in zip(pos, nrm, uv)], idx)


def _map_refs(v, fn):
    """Every {"ref": n} (n > 0 is objects[n - 1]; 0 is null) inside a value, rewritten by fn."""
    if isinstance(v, list):
        return [_map_refs(x, fn) for x in v]
    if isinstance(v, dict):
        if list(v.keys()) == ["ref"] and isinstance(v["ref"], int) and not isinstance(v["ref"], bool):
            return {"ref": fn(v["ref"]) if v["ref"] else 0}
        return {k: _map_refs(x, fn) for k, x in v.items()}
    return v


def merge_docs(docs, section):
    """Unpacked one-mesh banks (melange-xom/1 JSON) joined into one: objects grouped by type in the first-seen type
    order, the other banks' root XGraphSets folded into the first's (its Graphs list gets every mesh), every
    XMeshDescriptor given `section`, strings unioned. The same algorithm as Melange's merge.mjs."""
    type_names, type_by = [], {}
    for d in docs:
        if d.get("format") != "melange-xom/1":
            raise ValueError("not a melange-xom/1 document")
        for t in d["types"]:
            have = type_by.get(t["name"])
            if have is None:
                type_by[t["name"]] = dict(t)
                type_names.append(t["name"])
            elif have.get("guid") != t.get("guid") or have.get("version") != t.get("version"):
                raise ValueError("type %s differs between banks" % t["name"])
    roots = []
    for b, d in enumerate(docs):
        r = d["root"] - 1
        if d["objects"][r]["type"] != "XGraphSet":
            raise ValueError("bank %d: the root is not an XGraphSet" % b)
        roots.append(r)
    order = []
    for name in type_names:
        for b, d in enumerate(docs):
            for i, o in enumerate(d["objects"]):
                if o["type"] == name and not (b > 0 and i == roots[b]):
                    order.append((b, i))
    new = [dict() for _ in docs]
    for n, (b, i) in enumerate(order):
        new[b][i] = n
    for b in range(1, len(docs)):
        new[b][roots[b]] = new[0][roots[0]]
    objects = []
    for b, i in order:
        o = dict(docs[b]["objects"][i])
        o["fields"] = _map_refs(o["fields"], lambda r, b=b: new[b][r - 1] + 1)
        objects.append(o)
    root = objects[new[0][roots[0]]]
    graphs = []
    for b, d in enumerate(docs):
        for gr in d["objects"][roots[b]]["fields"]["Graphs"]:
            graphs.append(_map_refs(gr, lambda r, b=b: new[b][r - 1] + 1))
    root["fields"] = dict(root["fields"], Graphs=graphs)
    names = set()
    for o in objects:
        if o["type"] != "XMeshDescriptor":
            continue
        if o["fields"]["ResourceId"] in names:
            raise ValueError("two banks name the mesh %s" % o["fields"]["ResourceId"])
        names.add(o["fields"]["ResourceId"])
        o["fields"] = dict(o["fields"], SectionId=section)
    strings = []
    for d in docs:
        for st in d["strings"]:
            if st not in strings:
                strings.append(st)
    counts = {}
    for o in objects:
        counts[o["type"]] = counts.get(o["type"], 0) + 1
    out = dict(docs[0])
    out.update(types=[dict(type_by[n], count=counts.get(n, 0)) for n in type_names], strings=strings, objects=objects,
               root=new[0][roots[0]] + 1)
    for k in ("strs_raw", "tail_raw", "trailer"):  # rebuilt by the writer
        out.pop(k, None)
    return out


def merge_banks(xomtool, inputs, out, section):
    with tempfile.TemporaryDirectory() as tmp:
        docs = []
        for k, f in enumerate(inputs):
            j = os.path.join(tmp, "%d.json" % k)
            run([xomtool, "unpack", f, "-o", j], "unpack " + os.path.basename(f))
            with open(j, "r", encoding="utf-8") as fh:
                docs.append(json.load(fh))
        j = os.path.join(tmp, "merged.json")
        with open(j, "w", encoding="utf-8") as fh:
            json.dump(merge_docs(docs, section), fh)
        run([xomtool, "pack", j, out], "pack " + os.path.basename(out))


def run(cmd, what):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("xomtool failed: %s (exit %d): %s" % (what, r.returncode, (r.stderr or r.stdout).strip()))


def convert(xomtool, bundle09, src, rid, section, material, out):
    run([xomtool, "convert", os.path.join(MESH_DIR, src + ".gltf"), "--bundle", out, "--as", rid, "--section",
         str(section), "--material-from", material, "--material-file", bundle09,
         "--texture", os.path.join(MESH_DIR, src + ".png"), "--scene-bin", "8"], rid)


def outputs():
    """Every file this script writes into ../mod/assets/meshes."""
    names = [rid + ".xom" for _, rid, _, _ in BANKS] + [f for f, _, _ in MULTI]
    for _, stem in CLIENT:
        names += [stem + ".mesh.txt", stem + ".png"]
    return names


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
    for fname, section, parts in MULTI:
        with tempfile.TemporaryDirectory() as tmp:
            singles = []
            for src, rid, material in parts:
                one = os.path.join(tmp, rid + ".xom")
                convert(xomtool, bundle09, src, rid, section, material, one)
                singles.append(one)
            out = os.path.join(out_dir, fname)
            merge_banks(xomtool, singles, out, section)
        print("built %s (section %d, %s, %d bytes)" % (fname, section, ", ".join(p[1] for p in parts), os.path.getsize(out)))
    for src, stem in CLIENT:
        with open(os.path.join(out_dir, stem + ".mesh.txt"), "wb") as f:
            f.write(write_kjm(os.path.join(MESH_DIR, src + ".gltf")))
        with open(os.path.join(MESH_DIR, src + ".png"), "rb") as f:
            png = f.read()
        with open(os.path.join(out_dir, stem + ".png"), "wb") as f:
            f.write(png)
        print("wrote client mesh %s.mesh.txt + %s.png" % (stem, stem))


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
        for name in outputs():
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
