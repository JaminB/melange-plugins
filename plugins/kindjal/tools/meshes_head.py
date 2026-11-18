#!/usr/bin/env python3
"""The Grave Spade's severed worm head, as a client mesh (Kindjal draws it itself with wum.draw.mesh).

    python meshes_head.py            write ../mod/assets/meshes/gravespade_head.mesh.txt, gravespade_head.png and
                                     gravespade_head_clean.png
    python meshes_head.py --check    rebuild in memory and compare with the files on disk (the .png by decoded pixels,
                                     the .mesh.txt byte for byte); exit 1 on a difference
    --xomtool <path> / --bundl474 <file>   default: $KINDJAL_XOMTOOL / $KINDJAL_GAME_DATA + Bundles/Bundl474.xom

DERIVED FROM THE GAME (see the README, "What is derived from the game"): the geometry is the upper half of the vanilla
worm (`W4.Worm` in Bundl474.xom, its body shape in bind pose, its two eyes and its teeth), cut off by a slanted plane
through the neck blend band (bind-space y -6 .. +2, where the head bones take over) and closed with a new flat neck
face. The texture is an atlas rebuilt from the worm's own body, eye and teeth textures: the eye is baked from three of
its layers (white, pupil, a half-shut lid, so the head stares), and the neck face is painted here. Nothing is shipped as
the game stores it.

Output frame: the centre of the neck face is the origin, +Y runs up the head, the face looks along +Z (a worm's facing
at yaw 0), units are the worm's own (the whole worm is about 36 tall), so the head lines up with a live worm's head
when placed at its neck with its yaw. The cut face lies in the plane through the origin with normal -CUT_N (it points
out of the neck, down and slightly back).

File format KJM1 as text (also used for gravespade.mesh.txt, see build_meshes.kjm_text): a header line
"KJM1 12 <vertex count> <index count>", one line per vertex (x y z nx ny nz u v r g b a), then the 0-based indices three
per line (counter-clockwise from outside). u, v follow the glTF convention (v measured down from the top row of the
PNG). The vertex colour darkens the skin into a bruise toward the cut; it multiplies the texture.

Two textures with the same layout: `gravespade_head.png` (the neck face is raw meat: muscle, a white vertebra with the
cord, the gullet, blood welling at the rim) for Bloodsand on, `gravespade_head_clean.png` (the same face dried and
crusted with sand, no blood) for Bloodsand off. Stdlib only, deterministic.
"""
import argparse
import json
import math
import os
import re
import struct
import subprocess
import sys
import tempfile
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _paths  # noqa: E402
import _pngcmp  # noqa: E402
import build_meshes  # noqa: E402  (the KJM1 text writer)

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.normpath(os.path.join(HERE, "..", "mod", "assets", "meshes"))
STEM = "gravespade_head"

# The cut: a plane through the neck, tilted so the back of the neck is cut lower than the throat (a chop from the front
# and above). Points with dot(p - CUT_P, CUT_N) >= 0 are kept.
CUT_P = (0.0, -1.2, 0.0)
_T = math.radians(14.0)
CUT_N = (0.0, math.cos(_T), math.sin(_T))
BRUISE = 3.5  # the skin darkens over this distance above the cut

# Atlas 512 x 256: the worm's body texture on the left half, the baked eye, the teeth and the neck face on the right.
AW, AH = 512, 256
R_BODY = (0, 0, 256, 256)
R_EYE = (256, 0, 128, 128)
R_TEETH = (384, 0, 128, 128)
R_NECK = (256, 128, 128, 128)
R_SPARE = (384, 128, 128, 128)  # unused: a flat skin tone


# ---------------------------------------------------------------- small helpers
def sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def unit(a):
    n = math.sqrt(dot(a, a)) or 1.0
    return (a[0] / n, a[1] / n, a[2] / n)


def lerpv(a, b, t):
    return tuple(x + (y - x) * t for x, y in zip(a, b))


def clamp(x, lo=0.0, hi=1.0):
    return lo if x < lo else hi if x > hi else x


def smooth(e0, e1, x):
    t = clamp((x - e0) / (e1 - e0))
    return t * t * (3 - 2 * t)


def mix(c0, c1, t):
    return tuple(a + (b - a) * t for a, b in zip(c0, c1))


def hash2(ix, iy, seed):
    h = (ix * 374761393 + iy * 668265263 + seed * 2147483647) & 0xFFFFFFFF
    h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
    return ((h ^ (h >> 16)) & 0xFFFF) / 65535.0


def vnoise(x, y, seed):
    ix, iy = math.floor(x), math.floor(y)
    fx, fy = x - ix, y - iy
    fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
    a, b = hash2(ix, iy, seed), hash2(ix + 1, iy, seed)
    c, d = hash2(ix, iy + 1, seed), hash2(ix + 1, iy + 1, seed)
    return a + (b - a) * fx + (c - a) * fy + (a - b - c + d) * fx * fy


def fbm(x, y, seed, octaves=4):
    s, amp, norm = 0.0, 1.0, 0.0
    for o in range(octaves):
        s += vnoise(x * 2 ** o, y * 2 ** o, seed + o * 17) * amp
        norm += amp
        amp *= 0.5
    return s / norm


# ---------------------------------------------------------------- PNG in and out (8-bit, non-interlaced)
def png_read(data):
    """-> (w, h, rows of (r, g, b, a) tuples). Gray, RGB and RGBA at 8 bits, filters 0..4."""
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    pos, idat = 8, bytearray()
    while pos < len(data):
        n, tag = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if tag == b"IHDR":
            w, h, depth, ctype, _, _, inter = struct.unpack(">IIBBBBB", body)
            assert depth == 8 and inter == 0 and ctype in (0, 2, 6), "unsupported PNG"
        elif tag == b"IDAT":
            idat += body
        pos += 12 + n
    bpp = {0: 1, 2: 3, 6: 4}[ctype]
    raw = zlib.decompress(bytes(idat))
    stride = w * bpp
    prev = bytearray(stride)
    rows = []
    for y in range(h):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1:
                line[i] = (line[i] + a) & 255
            elif f == 2:
                line[i] = (line[i] + b) & 255
            elif f == 3:
                line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        prev = line
        row = []
        for x in range(w):
            px = line[x * bpp:(x + 1) * bpp]
            if bpp == 1:
                row.append((px[0], px[0], px[0], 255))
            elif bpp == 3:
                row.append((px[0], px[1], px[2], 255))
            else:
                row.append(tuple(px))
        rows.append(row)
    return w, h, rows


def png_write(rows, w, h):
    def chunk(tag, body):
        c = tag + body
        return struct.pack(">I", len(body)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)
    raw = bytearray()
    for row in rows:
        raw.append(0)
        for c in row:
            raw += bytes(int(clamp(v, 0, 255) + 0.5) for v in c[:3])
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


def sample(img, u, v):
    """Bilinear sample of an image (w, h, rows) at glTF u, v (v down from the top row), wrapping."""
    w, h, rows = img
    x, y = (u % 1.0) * w - 0.5, (v % 1.0) * h - 0.5
    x0, y0 = math.floor(x), math.floor(y)
    fx, fy = x - x0, y - y0
    out = [0.0] * 4
    for dx, dy, k in ((0, 0, (1 - fx) * (1 - fy)), (1, 0, fx * (1 - fy)), (0, 1, (1 - fx) * fy), (1, 1, fx * fy)):
        c = rows[(y0 + dy) % h][(x0 + dx) % w]
        for i in range(4):
            out[i] += c[i] * k
    return out


# ---------------------------------------------------------------- reading the vanilla worm
class Game:
    def __init__(self, xomtool, bundl474):
        self.x, self.b = xomtool, bundl474

    def run(self, *args):
        r = subprocess.run([self.x] + list(args), capture_output=True, text=True)
        if r.returncode != 0:
            sys.exit("xomtool %s failed (exit %d): %s" % (args[0], r.returncode, (r.stderr or r.stdout).strip()))
        return r.stdout

    def worm(self, tmp):
        """-> ({primitive name: (pos, nrm, uv, tris)}, {shader name: image (w, h, rows)})"""
        gl = os.path.join(tmp, "worm.gltf")
        self.run("clone", "W4.Worm", "--from", self.b, "--bundle", os.path.join(tmp, "w.xom"), "--as", "kindjal.TmpWorm",
                 "--section", "519", "--out-gltf", gl)
        with open(gl, "r", encoding="utf-8") as f:
            g = json.load(f)
        with open(os.path.join(tmp, g["buffers"][0]["uri"]), "rb") as f:
            b = f.read()

        def acc(i):
            a = g["accessors"][i]
            v = g["bufferViews"][a["bufferView"]]
            fmt = {5126: "f", 5125: "I", 5123: "H"}[a["componentType"]]
            n = {"SCALAR": 1, "VEC2": 2, "VEC3": 3}[a["type"]]
            vals = struct.unpack_from("<%d%s" % (a["count"] * n, fmt), b, v.get("byteOffset", 0) + a.get("byteOffset", 0))
            return [vals[k:k + n] for k in range(0, len(vals), n)] if n > 1 else list(vals)
        prims = {}
        for m in g["meshes"]:
            p = m["primitives"][0]
            idx = acc(p["indices"])
            prims[m["name"]] = (acc(p["attributes"]["POSITION"]), acc(p["attributes"]["NORMAL"]),
                                acc(p["attributes"]["TEXCOORD_0"]), [tuple(idx[k:k + 3]) for k in range(0, len(idx), 3)])
        listing = self.run("clone", "W4.Worm", "--from", self.b, "--list-images")
        images = {}
        for line in listing.splitlines():
            m = re.match(r"\s*\[(\d+)\] #(\d+) .*used by: (.*)$", line)
            if not m:
                continue
            png = os.path.join(tmp, "img%s.png" % m.group(2))
            self.run("convert", "#" + m.group(2), "--from", self.b, "--out", png)
            with open(png, "rb") as f:
                img = png_read(f.read())
            for shader in m.group(3).split(", "):
                images[shader.strip()] = img
        return prims, images


# ---------------------------------------------------------------- geometry
# xomtool's glTF of a clone has v up (PNG row = (1 - v) * height, docs/xomtool.md "--uv-layout"); this file and the
# client use v down, so every vanilla v is flipped on the way in.
BODY = "boggybodyShape_boggybody_shader"
EYES = ("boggybodyShape_boggyrighteye_shader", "boggybodyShape_Boggylefteye_shader")
TEETH = "boggybodyShape_boggyteeth_shader_1"


def side(p):
    return dot(sub(p, CUT_P), CUT_N)


def build_head(prims):
    pos, nrm, uv, tris = prims[BODY]
    verts, out_tris, cut_edges = [], [], []
    vid = {}

    def orig(i):
        if i not in vid:
            verts.append((pos[i], nrm[i], (uv[i][0] * 0.5, 1.0 - uv[i][1]), "body"))
            vid[i] = len(verts) - 1
        return vid[i]
    edge_pt = {}

    def cross_pt(i, j):
        key = (min(i, j), max(i, j))
        if key not in edge_pt:
            si, sj = side(pos[i]), side(pos[j])
            t = si / (si - sj)
            p = lerpv(pos[i], pos[j], t)
            n = unit(lerpv(nrm[i], nrm[j], t))
            q = lerpv(uv[i], uv[j], t)
            verts.append((p, n, (q[0] * 0.5, 1.0 - q[1]), "body"))
            edge_pt[key] = len(verts) - 1
        return edge_pt[key]

    for a, b, c in tris:
        ins = [side(pos[k]) >= 0 for k in (a, b, c)]
        n_in = sum(ins)
        if n_in == 0:
            continue
        if n_in == 3:
            out_tris.append((orig(a), orig(b), orig(c)))
            continue
        ring = (a, b, c)
        # rotate so the polygon walk keeps the winding: emit the clipped polygon in order
        poly, cut = [], []
        for k in range(3):
            i, j = ring[k], ring[(k + 1) % 3]
            ii, ij = ins[k], ins[(k + 1) % 3]
            if ii:
                poly.append(orig(i))
            if ii != ij:
                cp = cross_pt(i, j)
                poly.append(cp)
                cut.append(cp)
        for k in range(1, len(poly) - 1):
            out_tris.append((poly[0], poly[k], poly[k + 1]))
        if len(cut) == 2:
            # the cut edge, oriented so that walking it the kept surface's winding is preserved: the new cap uses it
            # backwards. In the clipped polygon, the edge that runs along the cut goes from the exit point to the entry
            # point; find it in poly order.
            k0 = poly.index(cut[0])
            k1 = poly.index(cut[1])
            if (k0 + 1) % len(poly) == k1:
                cut_edges.append((cut[0], cut[1]))
            else:
                cut_edges.append((cut[1], cut[0]))
    return verts, out_tris, cut_edges


def loops(edges, verts):
    """Chain directed cut edges (matched by position, since a UV seam splits a vertex) into closed loops."""
    def key(i):
        p = verts[i][0]
        return (round(p[0], 4), round(p[1], 4), round(p[2], 4))
    nxt = {}
    for a, b in edges:
        nxt.setdefault(key(a), []).append((a, b))
    used, out = set(), []
    for a, b in edges:
        if (a, b) in used:
            continue
        loop, cur = [], (a, b)
        while cur not in used:
            used.add(cur)
            loop.append(cur[0])
            cands = [e for e in nxt.get(key(cur[1]), []) if e not in used]
            if not cands:
                break
            cur = cands[0]
        out.append(loop)
    return out


def add_part(verts, tris, prim, rect, tag):
    pos, nrm, uv, ptris = prim
    base = len(verts)
    x0, y0, w, h = rect
    for p, n, t in zip(pos, nrm, uv):
        u, v = t[0] % 1.0, (1.0 - t[1]) % 1.0
        verts.append((p, n, ((x0 + u * w) / AW, (y0 + v * h) / AH), tag))
    for a, b, c in ptris:
        if all(side(pos[k]) >= 0 for k in (a, b, c)):
            tris.append((base + a, base + b, base + c))


def geometry(prims):
    verts, tris, cut_edges = build_head(prims)
    lps = loops(cut_edges, verts)
    lps.sort(key=len, reverse=True)
    rim = lps[0]  # the neck: the longest loop (any tiny ones are slivers of the mouth or eye pockets, left open)
    cx = sum(verts[i][0][0] for i in rim) / len(rim)
    cy = sum(verts[i][0][1] for i in rim) / len(rim)
    cz = sum(verts[i][0][2] for i in rim) / len(rim)
    centre = (cx, cy, cz)
    # the neck face: a fan from the centre, wound against the rim's direction so it faces out of the neck (-CUT_N)
    e1 = unit((1.0, 0.0, 0.0))
    e2 = unit((CUT_N[1] * e1[2] - CUT_N[2] * e1[1], CUT_N[2] * e1[0] - CUT_N[0] * e1[2], CUT_N[0] * e1[1] - CUT_N[1] * e1[0]))
    rmax = max(math.sqrt(dot(sub(verts[i][0], centre), sub(verts[i][0], centre))) for i in rim)
    out_n = (-CUT_N[0], -CUT_N[1], -CUT_N[2])

    def neck_uv(p):
        d = sub(p, centre)
        a, b = dot(d, e1) / rmax, dot(d, e2) / rmax
        x0, y0, w, h = R_NECK
        return ((x0 + (0.5 + 0.47 * a) * w) / AW, (y0 + (0.5 - 0.47 * b) * h) / AH)
    c_id = len(verts)
    verts.append((centre, out_n, neck_uv(centre), "neck"))
    ring_ids = {}
    for i in rim:
        ring_ids[i] = len(verts)
        verts.append((verts[i][0], out_n, neck_uv(verts[i][0]), "neck"))
    for k in range(len(rim)):
        a, b = rim[k], rim[(k + 1) % len(rim)]
        tri = (c_id, ring_ids[b], ring_ids[a])
        tris.append(tri)
    for name, rect, tag in ((EYES[0], R_EYE, "eye"), (EYES[1], R_EYE, "eye"), (TEETH, R_TEETH, "teeth")):
        add_part(verts, tris, prims[name], rect, tag)
    # fix the winding of the neck face to face along out_n (the rim direction depends on the body's own winding)
    vol_check = [t for t in tris if verts[t[0]][3] == "neck"]
    p0, p1, p2 = (verts[k][0] for k in vol_check[0])
    gn = ((p1[1] - p0[1]) * (p2[2] - p0[2]) - (p1[2] - p0[2]) * (p2[1] - p0[1]),
          (p1[2] - p0[2]) * (p2[0] - p0[0]) - (p1[0] - p0[0]) * (p2[2] - p0[2]),
          (p1[0] - p0[0]) * (p2[1] - p0[1]) - (p1[1] - p0[1]) * (p2[0] - p0[0]))
    if dot(gn, out_n) < 0:
        tris[:] = [(a, c, b) if verts[a][3] == "neck" else (a, b, c) for a, b, c in tris]
    # compact, move the neck centre to the origin, colour (bruise toward the cut)
    used = sorted({i for t in tris for i in t})
    remap = {o: n for n, o in enumerate(used)}
    out_v = []
    for i in used:
        p, n, t, tag = verts[i]
        d = side(p)
        if tag == "neck":
            col = (1.0, 1.0, 1.0, 1.0)
        else:  # a bruise toward the cut: darker, a little purple
            f = smooth(0.0, BRUISE, d)
            k = 0.55 + 0.45 * f
            col = (k, k * (0.86 + 0.14 * f), k * (0.92 + 0.08 * f), 1.0)
        out_v.append((sub(p, centre), unit(n), t, col))
    out_t = [(remap[a], remap[b], remap[c]) for a, b, c in tris]
    return out_v, out_t, rim


# ---------------------------------------------------------------- texture
def bake(images, clean):
    body = images[BODY]
    eye_white = images[EYES[0]]
    pupil = images[EYES[0] + "color2"] if EYES[0] + "color2" in images else None
    lid = images.get("boggybodyShape_boggyrighteye_shadercolor3_0")
    teeth = images[TEETH]
    rows = [[(0, 0, 0)] * AW for _ in range(AH)]
    skin = sample(body, 0.62, 0.55)  # a plain cheek tone for the spare cell

    def put(rect, fn):
        x0, y0, w, h = rect
        for y in range(y0, y0 + h):
            for x in range(x0, x0 + w):
                rows[y][x] = fn((x - x0 + 0.5) / w, (y - y0 + 0.5) / h)

    put(R_BODY, lambda u, v: sample(body, u, v)[:3])

    def eye(u, v):
        c = sample(eye_white, u, v)[:3]
        for layer in (pupil, lid):
            if layer:
                s = sample(layer, u, v)
                c = mix(c, s[:3], s[3] / 255.0)
        return c
    put(R_EYE, eye)
    put(R_TEETH, lambda u, v: sample(teeth, u, v)[:3])
    put(R_SPARE, lambda u, v: skin[:3])
    put(R_NECK, lambda u, v: neck_face(u, v, clean, skin))
    return png_write(rows, AW, AH)


def neck_face(u, v, clean, skin):
    """The cut seen from below: the skin's rim, fat, muscle in bundles, the gullet in front (+Z, top of the cell), a
    vertebra with the cord at the back. The rim of the cell is skin coloured, so any UV bleed reads as skin."""
    a, b = (u - 0.5) / 0.47, (0.5 - v) / 0.47  # the neck plane, -1..1 (b > 0 toward the throat)
    r = math.hypot(a, b)
    n = fbm(u * 9, v * 9, 7)
    fine = fbm(u * 30, v * 30, 8, 2)
    if clean:
        meat = mix((112, 84, 66), (150, 120, 92), n)  # dried, dusted
        dark = (70, 52, 40)
        bone = (196, 184, 156)
        hole = (46, 36, 28)
    else:
        meat = mix((112, 14, 16), (190, 42, 38), n)  # raw muscle
        dark = (58, 4, 8)
        bone = (232, 222, 200)
        hole = (34, 4, 6)
    col = meat
    # muscle bundles: darker septa
    sep = abs(fbm(u * 6 + 3, v * 6, 11) - 0.5)
    col = mix(col, dark, 0.65 * smooth(0.05, 0.0, sep))
    col = tuple(c * (0.85 + 0.3 * fine) for c in col)
    # a fat layer under the skin, then the skin rim itself
    fat = (226, 204, 150) if not clean else (186, 168, 130)
    col = mix(col, fat, smooth(0.80, 0.86, r) * (1 - smooth(0.9, 0.94, r)))
    col = mix(col, skin[:3], smooth(0.9, 0.95, r))
    # the gullet (front) and the windpipe ring beside it
    g = math.hypot(a / 0.24, (b - 0.42) / 0.16)
    col = mix(col, hole, smooth(1.0, 0.8, g))
    t = math.hypot((a + 0.02) / 0.2, (b - 0.12) / 0.17)
    col = mix(col, mix(bone, (220, 170, 170) if not clean else bone, 0.4), smooth(1.15, 1.0, t) * (1 - smooth(0.8, 0.65, t)))
    col = mix(col, hole, smooth(0.7, 0.55, t))
    # the vertebra at the back with the spinal cord
    vb = math.hypot(a / 0.3, (b + 0.4) / 0.24)
    col = mix(col, bone, smooth(1.0, 0.85, vb))
    col = mix(col, tuple(c * 0.8 for c in bone), smooth(0.55, 0.4, vb) * (1 - smooth(0.32, 0.2, vb)))
    cord = math.hypot(a / 0.1, (b + 0.42) / 0.09)
    col = mix(col, (236, 210, 196) if not clean else (170, 156, 130), smooth(1.0, 0.8, cord))
    if clean:  # sand crust: pale grains
        grain = hash2(int(u * 128), int(v * 128), 31)
        col = mix(col, (214, 190, 140), 0.7 * smooth(0.82, 0.9, grain) * (1 - smooth(0.9, 0.95, r)))
    else:  # blood welling at the rim and glistening wet highlights
        well = smooth(0.62, 0.85, r) * (1 - smooth(0.9, 0.95, r)) * smooth(0.45, 0.6, fbm(u * 14, v * 14, 13))
        col = mix(col, (96, 4, 8), 0.8 * well)
        wet = smooth(0.78, 0.86, fbm(u * 20 + 5, v * 20, 19)) * (1 - smooth(0.85, 0.9, r))
        col = mix(col, (255, 170, 160), 0.5 * wet)
    return col


# ---------------------------------------------------------------- output
def kjm(verts, tris):
    return build_meshes.kjm_text(12, [p + n + t + c for p, n, t, c in verts], [i for t in tris for i in t])


def validate(verts, tris):
    assert len(verts) < 65536, "too many vertices for u16 indices"
    assert len(verts) <= 16384 and len(tris) * 3 <= 49152, "over wum.draw.mesh's per-call limits"
    for a, b, c in tris:
        assert len({a, b, c}) == 3, "degenerate triangle"
    for p, n, t, c in verts:
        assert abs(math.sqrt(dot(n, n)) - 1.0) < 1e-3, "normal not unit"
        assert 0.0 <= t[0] <= 1.0 and 0.0 <= t[1] <= 1.0, "uv out of range"
    # winding: the geometric normal agrees with the vertex normals on nearly every triangle
    agree = 0
    for a, b, c in tris:
        pa, pb, pc = verts[a][0], verts[b][0], verts[c][0]
        e1, e2 = sub(pb, pa), sub(pc, pa)
        g = (e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0])
        s = tuple(verts[a][1][k] + verts[b][1][k] + verts[c][1][k] for k in range(3))
        agree += dot(g, s) > 0
    assert agree >= 0.95 * len(tris), "winding disagrees with the normals on %d triangles" % (len(tris) - agree)


def generate(xomtool, bundl474):
    with tempfile.TemporaryDirectory() as tmp:
        prims, images = Game(xomtool, bundl474).worm(tmp)
    verts, tris, rim = geometry(prims)
    validate(verts, tris)
    files = {STEM + ".mesh.txt": kjm(verts, tris), STEM + ".png": bake(images, False), STEM + "_clean.png": bake(images, True)}
    lo = [min(v[0][k] for v in verts) for k in range(3)]
    hi = [max(v[0][k] for v in verts) for k in range(3)]
    info = "%d vertices, %d triangles, neck rim %d points, box %s .. %s" % (
        len(verts), len(tris), len(rim), [round(x, 2) for x in lo], [round(x, 2) for x in hi])
    return files, info


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--xomtool", default=_paths.default_xomtool())
    data = _paths.default_game_data()
    ap.add_argument("--bundl474", default=os.environ.get("KINDJAL_BUNDL474") or (
        os.path.join(data, "Bundles", "Bundl474.xom") if data else ""))
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    _paths.require_tools(args.xomtool, args.bundl474)
    files, info = generate(args.xomtool, args.bundl474)
    print(info)
    if args.check:
        bad = 0
        for name, data_ in files.items():
            path = os.path.join(OUT_DIR, name)
            ok = os.path.isfile(path) and _pngcmp.same(open(path, "rb").read(), data_, name)
            print(("ok       " if ok else "DIFFERS  ") + name)
            bad += not ok
        sys.exit(1 if bad else 0)
    os.makedirs(OUT_DIR, exist_ok=True)
    for name, data_ in files.items():
        with open(os.path.join(OUT_DIR, name), "wb") as f:
            f.write(data_)
        print("wrote %s (%d bytes)" % (name, len(data_)))


if __name__ == "__main__":
    main()
