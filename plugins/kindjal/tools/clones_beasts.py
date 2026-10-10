#!/usr/bin/env python3
"""Kindjal animal clones: RabidSheep, PlagueRam, Carcass.

Each model is a CLONE of a vanilla skinned Worms Ultimate Mayhem mesh made with `xomtool clone`: the skeleton, node
names, skin weights and clip library stay exactly as in the vanilla bank. What changes is (a) vertex positions, through
an `xomtool --deform` script (same vertex count and order, so the weights and clips still fit) and (b) every texture,
repainted here procedurally into the vanilla UV layout.

    kindjal.RabidSheep  <- Sheep         section 505  (held sheep, walking projectile, Super Sheep / Starburst held mesh)
    kindjal.PlagueRam   <- SuperSheep    section 506  (flying sheep: Fly / FlyLR / RollLR clips, 19 bones)
    kindjal.Carcass     <- Cow.Payload   section 507  (Hang / Skydive / Run2Sink / Sink clips, 24 bones)

Stdlib only and deterministic (hash noise, fixed seeds).  Importing this module has no side effects.

    python clones_beasts.py [--xomtool EXE] [--bundl09 XOM] [--out DIR] [--only slug,..] [--work DIR]
    python clones_beasts.py --check      # rebuild into a temp dir and compare bytes with the checked-in banks

How a texture is painted: the clone is first built with its deform and written as glTF (`--out-gltf`), so the painter
sees the final geometry.  Every triangle is rasterised into texture space, which gives each texel its 3D position,
normal and UV island.  The painters colour a texel from where it is on the animal (wool lumps from 3D cellular noise,
eyes and teeth from positions on the head, ribs from the belly's position), so the paint follows the model without
hand-placed pixels.  Texels no triangle reaches are filled from their neighbours so mip-mapping never bleeds black.
"""
import argparse
import json
import math
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # the helper sits beside this file
import _paths  # noqa: E402

HERE = Path(__file__).resolve().parent
DEFAULT_XOMTOOL = _paths.default_xomtool()
DEFAULT_BUNDL09 = _paths.default_bundl09()
DEFAULT_OUT = HERE.parent / "mod" / "assets" / "meshes"

# ----------------------------------------------------------------------------------------------------------------------
# small maths helpers
# ----------------------------------------------------------------------------------------------------------------------


def clamp(x, lo=0.0, hi=1.0):
    return lo if x < lo else hi if x > hi else x


def smooth(a, b, x):
    t = clamp((x - a) / (b - a)) if b != a else (1.0 if x >= a else 0.0)
    return t * t * (3 - 2 * t)


def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def scale(c, k):
    return (c[0] * k, c[1] * k, c[2] * k)


def dist3(a, b):
    return math.sqrt((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2 + (a[2] - b[2]) ** 2)


_M = 0xFFFFFFFF


def _hash(ix, iy, iz, seed):
    h = (ix * 73856093 ^ iy * 19349663 ^ iz * 83492791 ^ (seed * 2654435761 & _M)) & _M
    h = ((h ^ (h >> 13)) * 1274126177) & _M
    h = ((h ^ (h >> 16)) * 2246822519) & _M
    return ((h ^ (h >> 15)) & _M) / _M


def vnoise(x, y, z, seed=0):
    """Value noise in [0, 1], smooth, a pure function of position."""
    ix, iy, iz = math.floor(x), math.floor(y), math.floor(z)
    fx, fy, fz = x - ix, y - iy, z - iz
    fx, fy, fz = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy), fz * fz * (3 - 2 * fz)
    def l(a, b, t):
        return a + (b - a) * t
    c = [[[_hash(ix + i, iy + j, iz + k, seed) for k in (0, 1)] for j in (0, 1)] for i in (0, 1)]
    return l(l(l(c[0][0][0], c[0][0][1], fz), l(c[0][1][0], c[0][1][1], fz), fy),
             l(l(c[1][0][0], c[1][0][1], fz), l(c[1][1][0], c[1][1][1], fz), fy), fx)


def fbm(x, y, z, seed=0, octaves=3):
    tot, amp, norm, f = 0.0, 1.0, 0.0, 1.0
    for o in range(octaves):
        tot += amp * vnoise(x * f, y * f, z * f, seed + 17 * o)
        norm += amp
        amp *= 0.5
        f *= 2.03
    return tot / norm


def worley(x, y, z, seed=0):
    """Distance to the nearest feature point of a jittered 3D grid (cell size 1): about 0 at a centre, about 0.9 at a crease."""
    ix, iy, iz = math.floor(x), math.floor(y), math.floor(z)
    best = 9.0
    for i in (-1, 0, 1):
        for j in (-1, 0, 1):
            for k in (-1, 0, 1):
                cx, cy, cz = ix + i, iy + j, iz + k
                px = cx + _hash(cx, cy, cz, seed + 1)
                py = cy + _hash(cx, cy, cz, seed + 2)
                pz = cz + _hash(cx, cy, cz, seed + 3)
                d = (px - x) ** 2 + (py - y) ** 2 + (pz - z) ** 2
                if d < best:
                    best = d
    return math.sqrt(best)


def rnd2(x, y, seed=0):
    return _hash(x, y, 7919, seed)

# ----------------------------------------------------------------------------------------------------------------------
# PNG (read: all filters, 8-bit; write: RGB8)
# ----------------------------------------------------------------------------------------------------------------------


def write_png(path, w, h, rows):
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            c = rows[y][x]
            raw += bytes((int(clamp(c[0], 0, 255) + 0.5), int(clamp(c[1], 0, 255) + 0.5), int(clamp(c[2], 0, 255) + 0.5)))
    def chunk(tag, body):
        c = tag + body
        return struct.pack(">I", len(body)) + c + struct.pack(">I", zlib.crc32(c) & _M)
    Path(path).write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))

# ----------------------------------------------------------------------------------------------------------------------
# geometry: parse the glTF xomtool writes, rasterise it into texture space
# ----------------------------------------------------------------------------------------------------------------------


class Island:
    def __init__(self, idx, tris, pr):
        self.idx = idx
        self.tris = tris
        vs = sorted({v for t in tris for v in t})
        P = [pr["pos"][v] for v in vs]
        U = [pr["uv"][v] for v in vs]
        self.lo = tuple(min(p[k] for p in P) for k in range(3))   # 3D bounds (deformed bind pose)
        self.hi = tuple(max(p[k] for p in P) for k in range(3))
        self.uvb = (min(u[0] for u in U), min(u[1] for u in U), max(u[0] for u in U), max(u[1] for u in U))

    @property
    def uc(self):
        return (self.uvb[0] + self.uvb[2]) / 2, (self.uvb[1] + self.uvb[3]) / 2


def load_gltf(path):
    path = Path(path)
    g = json.loads(path.read_text())
    blob = path.with_suffix(".bin").read_bytes()
    def acc(i, n, fmt):
        a = g["accessors"][i]
        bv = g["bufferViews"][a["bufferView"]]
        vals = struct.unpack_from("<" + fmt * (a["count"] * n), blob, bv.get("byteOffset", 0))
        return [vals[k:k + n] for k in range(0, len(vals), n)]
    prims = []
    for m in g["meshes"]:
        for p in m["primitives"]:
            at = p["attributes"]
            fmt = {5123: "H", 5125: "I"}[g["accessors"][p["indices"]]["componentType"]]
            idx = [i[0] for i in acc(p["indices"], 1, fmt)]
            pr = {"pos": acc(at["POSITION"], 3, "f"), "nrm": acc(at["NORMAL"], 3, "f"), "uv": acc(at["TEXCOORD_0"], 2, "f"),
                  "tris": [tuple(idx[i:i + 3]) for i in range(0, len(idx), 3)]}
            par = list(range(len(pr["pos"])))
            def find(a):
                while par[a] != a:
                    par[a] = par[par[a]]
                    a = par[a]
                return a
            for t in pr["tris"]:
                par[find(t[1])] = find(t[0])
                par[find(t[2])] = find(t[0])
            groups = {}
            for t in pr["tris"]:
                groups.setdefault(find(t[0]), []).append(t)
            pr["islands"] = [Island(i, ts, pr) for i, ts in enumerate(groups.values())]
            prims.append(pr)
    return prims


class Texel:
    __slots__ = ("x", "y", "u", "v", "p", "n", "isl")


def rasterise(pr, w, h):
    """Texel -> Texel(pos, normal, island) for every texel centre inside a triangle. Smaller islands are drawn last, so a
    small island that overlaps a big one (an eye on a face) wins its texels."""
    grid = [None] * (w * h)
    order = sorted(pr["islands"], key=lambda i: -len(i.tris))
    for isl in order:
        for (a, b, c) in isl.tris:
            ua, ub, uc = pr["uv"][a], pr["uv"][b], pr["uv"][c]
            A = (ua[0] * w, (1 - ua[1]) * h)
            B = (ub[0] * w, (1 - ub[1]) * h)
            C = (uc[0] * w, (1 - uc[1]) * h)
            area = (B[0] - A[0]) * (C[1] - A[1]) - (B[1] - A[1]) * (C[0] - A[0])
            if abs(area) < 1e-9:
                continue
            x0 = max(0, int(math.floor(min(A[0], B[0], C[0]))))
            x1 = min(w - 1, int(math.ceil(max(A[0], B[0], C[0]))))
            y0 = max(0, int(math.floor(min(A[1], B[1], C[1]))))
            y1 = min(h - 1, int(math.ceil(max(A[1], B[1], C[1]))))
            for y in range(y0, y1 + 1):
                for x in range(x0, x1 + 1):
                    px, py = x + 0.5, y + 0.5
                    w0 = ((B[0] - px) * (C[1] - py) - (B[1] - py) * (C[0] - px)) / area
                    w1 = ((C[0] - px) * (A[1] - py) - (C[1] - py) * (A[0] - px)) / area
                    w2 = 1 - w0 - w1
                    if w0 < -0.02 or w1 < -0.02 or w2 < -0.02:
                        continue
                    t = Texel()
                    t.x, t.y, t.isl = x, y, isl
                    t.u, t.v = px / w, 1 - py / h
                    pa, pb, pc = pr["pos"][a], pr["pos"][b], pr["pos"][c]
                    na, nb, nc = pr["nrm"][a], pr["nrm"][b], pr["nrm"][c]
                    t.p = tuple(w0 * pa[k] + w1 * pb[k] + w2 * pc[k] for k in range(3))
                    n = tuple(w0 * na[k] + w1 * nb[k] + w2 * nc[k] for k in range(3))
                    ln = math.sqrt(sum(v * v for v in n)) or 1.0
                    t.n = (n[0] / ln, n[1] / ln, n[2] / ln)
                    grid[y * w + x] = t
    return grid


def paint_texture(pr, w, h, fn, post=None, fill=(40, 40, 40)):
    """Colour every covered texel with fn(texel), dilate into the uncovered ones, then run post(canvas) (2D touch-ups)."""
    grid = rasterise(pr, w, h)
    cv = [[None] * w for _ in range(h)]
    for t in grid:
        if t is not None:
            cv[t.y][t.x] = fn(t)
    for _ in range(6):   # dilate: copy the average of painted neighbours into holes
        nxt = [row[:] for row in cv]
        for y in range(h):
            for x in range(w):
                if cv[y][x] is not None:
                    continue
                acc, n = [0.0, 0.0, 0.0], 0
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        yy, xx = y + dy, x + dx
                        if 0 <= yy < h and 0 <= xx < w and cv[yy][xx] is not None:
                            c = cv[yy][xx]
                            acc[0] += c[0]; acc[1] += c[1]; acc[2] += c[2]; n += 1
                if n:
                    nxt[y][x] = (acc[0] / n, acc[1] / n, acc[2] / n)
        cv = nxt
    for y in range(h):
        for x in range(w):
            if cv[y][x] is None:
                cv[y][x] = fill
    if post:
        post(cv, grid)
    return cv

# ----------------------------------------------------------------------------------------------------------------------
# RabidSheep (Sheep) - matted dark wool, red eyes, bared teeth, foam
# ----------------------------------------------------------------------------------------------------------------------

# spike vertices along the back and shoulders: (x, y, z, move) in the vanilla bind pose.  Spikes are separated by dips
# (negative moves) at the vertices between them, so the back reads as a crown of points rather than one taller dome.
_SHEEP_SPIKES = [
    (0.0, 6.0, -4.1, 3.4), (2.8, 6.0, -1.3, 3.3), (-2.8, 6.0, -1.3, 3.3), (0.0, 5.6, 1.4, 3.0),
    (4.8, 4.0, -1.5, 3.0), (-4.8, 4.0, -1.5, 3.0), (0.0, 4.2, -6.0, 3.2),
    (4.7, 4.2, -4.6, 2.6), (-4.7, 4.2, -4.6, 2.6), (4.8, 3.8, 1.4, 2.6), (-4.8, 3.8, 1.4, 2.6),
    (0.0, 5.9, -1.3, -0.6), (2.6, 5.3, -4.0, -0.5), (-2.6, 5.3, -4.0, -0.5), (2.5, 5.0, 1.3, -0.5), (-2.5, 5.0, 1.3, -0.5),
]


def _spike_ops(spikes, r=0.8, fall=0.25):
    """One small region box per back vertex that drags it out along a mostly upward direction: a tuft that ends in a point
    (a push along the welded normal would only swell the lump)."""
    ops = []
    for (x, y, z, d) in spikes:
        v = (x * 0.30, 1.0, -0.25)
        if abs(x) > 4.0:
            v = (x * 0.35, 0.7, -0.15)
        ln = math.sqrt(sum(c * c for c in v))
        t = [round(d * c / ln, 3) for c in v]
        ops.append({"op": "region", "box": [[x - r, y - r, z - r], [x + r, y + r, z + r]], "falloff": fall,
                    "then": [{"op": "translate", "t": t}]})
    return ops


def sheep_deform():
    ops = _spike_ops(_SHEEP_SPIKES)
    ops += [
        # bulky, matted fleece
        {"op": "region", "box": [[-6.5, -4.8, -7.5], [6.5, 6.5, 4.6]], "falloff": 1.0,
         "then": [{"op": "push", "dist": 0.45}, {"op": "noise", "amp": 0.5, "freq": 0.8, "seed": 3}]},
        # shaggy forelock
        {"op": "region", "box": [[-3.6, 2.8, 3.2], [3.6, 8.5, 11.6]], "falloff": 0.6,
         "then": [{"op": "push", "dist": 0.35}, {"op": "noise", "amp": 0.45, "freq": 1.0, "seed": 5}]},
        # heavy jaw: the lower face drops and juts so the bared teeth are on show
        {"op": "region", "box": [[-3.0, -5.2, 7.5], [3.0, -2.6, 12.0]], "falloff": 1.0,
         "then": [{"op": "translate", "t": [0.0, -0.45, 0.5]}]},
    ]
    return {"ops": ops}


def _paint_sheep(prims):
    pr = prims[0]
    ISL = {}
    for isl in pr["islands"]:
        uc = isl.uc
        # roles by UV position (the layout is the vanilla one): body wool, head wool, face, ears, legs, eyes, neck
        if isl.uvb[2] < 0.7 and isl.uvb[3] < 0.55 and len(isl.tris) > 100:
            ISL[isl.idx] = "wool"
        elif len(isl.tris) == 40:
            ISL[isl.idx] = "wool"            # forelock
        elif len(isl.tris) == 86:
            ISL[isl.idx] = "face"
        elif len(isl.tris) == 54:
            ISL[isl.idx] = "leg"
        elif len(isl.tris) == 17:
            ISL[isl.idx] = "ear"
        elif len(isl.tris) == 6:
            ISL[isl.idx] = "eye"
        else:
            ISL[isl.idx] = "wool"            # the 8-triangle neck cap

    def wool(t):
        x, y, z = t.p
        cl = worley(x * 0.55, y * 0.55, z * 0.55, 21)      # matted clumps ~ 1.8 units
        cl2 = worley(x * 1.6 + 5, y * 1.6, z * 1.6, 33)    # tufts
        n = fbm(x * 0.6, y * 0.6, z * 0.6, 5, 3)
        lobe = clamp(1.0 - cl / 0.85)
        base = mix((22, 22, 26), (146, 148, 152), clamp(lobe * 1.2 * (0.55 + 0.9 * n)))
        base = mix(base, (186, 188, 190), 0.6 * smooth(0.55, 0.9, 1 - cl2 / 0.8) * smooth(0.42, 0.7, n))  # grey dry tufts
        base = scale(base, 0.8 + 0.35 * smooth(0.2, 0.9, 1 - cl2))
        # spiky ridge catches the light
        base = mix(base, (200, 202, 204), 0.4 * smooth(4.0, 7.5, y) * smooth(0.5, 0.8, n))
        # dried blood stains: big blotches, darker core
        s = fbm(x * 0.35 + 9, y * 0.35, z * 0.35 + 3, 9, 3)
        base = mix(base, (130, 14, 16), smooth(0.62, 0.72, s) * 0.85)
        base = mix(base, (70, 6, 10), smooth(0.66, 0.78, s) * 0.8)
        # flank is darker (underside); belly almost black
        base = scale(base, 0.45 + 0.55 * smooth(-4.5, 1.0, y))
        return base

    def face(t):
        x, y, z = t.p
        ax = abs(x)
        skin = mix((66, 48, 56), (36, 26, 32), fbm(x * 0.9, y * 0.9, z * 0.9, 41, 3))
        skin = scale(skin, 0.7 + 0.5 * smooth(-2.0, 4.0, y))
        # bloodshot ring around each eye (eyes sit at x ~ +-1.1, y ~ 0.8, z ~ 10.8)
        e = math.sqrt((ax - 1.15) ** 2 + (y - 0.85) ** 2 + (z - 10.7) ** 2 * 0.25)
        ring = smooth(2.1, 0.7, e)
        skin = mix(skin, (150, 18, 18), ring * 0.85)
        skin = mix(skin, (60, 4, 6), smooth(1.2, 0.5, e) * 0.9)
        # scratched nose
        if y < -0.8 and z > 10.0:
            skin = mix(skin, (24, 16, 20), 0.5)
        # mouth: a dark red gap with a row of fangs hanging from the top lip and shorter ones rising from the bottom lip,
        # y -3.0 .. -4.8 on the front, wrapped round the muzzle sides
        mouth = smooth(-2.35, -2.65, y) * smooth(-5.1, -4.8, y) * smooth(7.4, 9.2, z)
        if mouth > 0.01:
            tri = abs((ax * 1.25) % 1.0 - 0.5) * 2.0          # 0 at a tooth centre, 1 in the gap
            tri2 = abs((ax * 1.25 + 0.5) % 1.0 - 0.5) * 2.0
            col = (70, 4, 10)
            if y > -2.65 - 2.0 * (1.0 - tri) ** 0.7 and y < -2.55:
                col = (255, 250, 228)
            elif y < -5.0 + 1.5 * (1.0 - tri2) ** 0.7:
                col = (246, 238, 212)
            skin = mix(skin, col, mouth)
        # foam at the corners of the mouth and a drip down the chin
        f = fbm(x * 1.7 + 3, y * 1.7, z * 1.7, 55, 3)
        foam = smooth(0.5, 0.62, f) * smooth(-2.4, -3.6, y) * smooth(7.0, 9.0, z)
        skin = mix(skin, (236, 240, 232), foam)
        return skin

    def leg(t):
        x, y, z = t.p
        sk = mix((62, 46, 54), (28, 20, 26), fbm(x * 1.2, y * 1.2, z * 1.2, 61, 3))
        sk = mix(sk, (110, 20, 22), smooth(0.62, 0.74, fbm(x * 0.8, y * 0.8, z * 0.8, 71, 3)) * 0.7)  # raw patches
        hoof = smooth(-8.2, -9.2, y)
        return mix(sk, (10, 8, 10), hoof)

    def ear(t):
        x, y, z = t.p
        return mix((48, 30, 38), (120, 22, 28), smooth(0.45, 0.8, fbm(x, y, z, 81, 2)) * 0.8)

    def eye(t):
        # eye island UV is shared by both eyes; paint relative to the island's own UV box
        u0, v0, u1, v1 = t.isl.uvb
        fu = (t.u - u0) / max(u1 - u0, 1e-6)
        fv = (t.v - v0) / max(v1 - v0, 1e-6)
        d = math.sqrt(((fu - 0.5) / 0.5) ** 2 + ((fv - 0.5) / 0.5) ** 2)
        col = mix((255, 60, 24), (255, 215, 70), smooth(0.55, 0.0, d))   # hot red, bright core
        slit = smooth(0.2, 0.1, abs(fu - 0.5))
        col = mix(col, (8, 0, 0), slit * smooth(0.95, 0.5, abs(fv - 0.5) * 1.6) * 0.95)
        return mix(col, (70, 0, 0), smooth(0.7, 1.0, d))

    def fn(t):
        role = ISL[t.isl.idx]
        return {"wool": wool, "face": face, "leg": leg, "ear": ear, "eye": eye}[role](t)

    return {0: paint_texture(pr, 128, 128, fn, fill=(40, 30, 34))}

# ----------------------------------------------------------------------------------------------------------------------
# PlagueRam (SuperSheep) - hooked horns, gas mask with green lenses, tattered red cape
# ----------------------------------------------------------------------------------------------------------------------

# The ear is a 12-vertex fin.  Its five root vertices sit on the head and stay put; the other seven become a hooked horn:
# a mid ring that rises and moves out, and a tip that sweeps down and forward.  (x is mirrored for the other side.)
_EAR_MID = [(4.11, 3.2, 5.97), (4.27, 1.96, 5.06), (4.38, 3.25, 4.57), (4.69, 4.39, 5.8), (4.83, 1.93, 6.62), (5.24, 3.19, 7.12)]
_EAR_TIP = (6.06, 2.83, 5.36)


def _vbox(p, sgn, r):
    x = p[0] * sgn
    return [[min(x - r, x + r), p[1] - r, p[2] - r], [max(x - r, x + r), p[1] + r, p[2] + r]]


def _horn_ops():
    ops = []
    cx = sum(p[0] for p in _EAR_MID) / 6.0
    cy = sum(p[1] for p in _EAR_MID) / 6.0
    cz = sum(p[2] for p in _EAR_MID) / 6.0
    mid_to = (6.4, 5.0, 5.8)       # centre of the horn's middle ring
    tip_to = (8.6, 1.6, 9.0)       # the point
    for sgn in (1, -1):
        for p in _EAR_MID:
            new = (mid_to[0] + (p[0] - cx) * 0.95, mid_to[1] + (p[1] - cy) * 0.95, mid_to[2] + (p[2] - cz) * 0.95)
            t = [round((new[0] - p[0]) * sgn, 3), round(new[1] - p[1], 3), round(new[2] - p[2], 3)]
            ops.append({"op": "region", "box": _vbox(p, sgn, 0.05), "falloff": 0.02, "then": [{"op": "translate", "t": t}]})
        t = [round((tip_to[0] - _EAR_TIP[0]) * sgn, 3), round(tip_to[1] - _EAR_TIP[1], 3), round(tip_to[2] - _EAR_TIP[2], 3)]
        ops.append({"op": "region", "box": _vbox(_EAR_TIP, sgn, 0.05), "falloff": 0.02, "then": [{"op": "translate", "t": t}]})
    return ops


# cape vertices (x mirrored): ragged hem, long trailing tails and notches between them
_CAPE_TEAR = [
    ((7.7, 3.1, -9.2), (0.9, -1.4, -2.0)),     # corner tail
    ((4.1, 7.3, -8.5), (0.0, -0.4, 2.6)),      # notch
    ((7.5, 3.7, -5.0), (0.7, -1.3, -0.4)),     # side tail
    ((6.8, 3.6, -1.2), (-1.0, 0.6, 0.6)),      # side notch
    ((5.2, 3.0, 2.2), (0.6, -1.4, -0.3)),      # front-side tail
    ((2.91, 5.11, 3.24), (0.4, -1.5, 0.5)),    # front tail
    ((3.58, 6.8, 0.05), (-0.4, 0.5, 0.5)),     # shoulder notch
]


def plague_deform():
    ops = _horn_ops()
    for sgn in (1, -1):
        for (p, t) in _CAPE_TEAR:
            ops.append({"op": "region", "box": _vbox(p, sgn, 0.1), "falloff": 0.02,
                        "then": [{"op": "translate", "t": [round(t[0] * sgn, 3), t[1], t[2]]}]})
    # long central tail, dragging off the ridge
    ops.append({"op": "region", "box": [[-0.3, 8.2, -8.5], [0.3, 8.8, -7.9]], "falloff": 0.02,
                "then": [{"op": "translate", "t": [0.0, -3.4, -1.6]}]})
    ops += [
        # dingy, matted fleece (the spiky tufts are left to the sheep; the cape hides the back)
        {"op": "region", "box": [[-6.5, -4.8, -7.5], [6.5, 6.5, 4.6]], "falloff": 1.0,
         "then": [{"op": "push", "dist": 0.35}, {"op": "noise", "amp": 0.45, "freq": 0.8, "seed": 13}]},
        # gas mask: the face front is pushed out into a rubber muzzle with a canister bump...
        {"op": "region", "box": [[-1.6, -4.6, 9.6], [1.6, -1.4, 12.0]], "falloff": 1.0,
         "then": [{"op": "translate", "t": [0.0, -0.1, 1.5]}]},
        # ...and the two lenses bulge
        {"op": "region", "box": [[0.3, -0.4, 10.2], [1.8, 1.9, 11.2]], "falloff": 0.5,
         "then": [{"op": "scale", "s": 1.35, "about": [1.05, 0.8, 10.7]}, {"op": "push", "dist": 0.5}]},
        {"op": "region", "box": [[-1.8, -0.4, 10.2], [-0.3, 1.9, 11.2]], "falloff": 0.5,
         "then": [{"op": "scale", "s": 1.35, "about": [-1.05, 0.8, 10.7]}, {"op": "push", "dist": 0.5}]},
    ]
    return {"ops": ops}


def _paint_plague(prims):
    pr = prims[0]
    ROLE = {}
    for isl in pr["islands"]:
        n, uc = len(isl.tris), isl.uc
        if n == 24:
            ROLE[isl.idx] = "cape" if uc[0] < 0.64 else "capein"
        elif n == 50:
            ROLE[isl.idx] = "collar"
        elif n in (130, 40, 8):
            ROLE[isl.idx] = "wool"
        elif n == 86:
            ROLE[isl.idx] = "face"
        elif n == 54:
            ROLE[isl.idx] = "leg"
        elif n == 17:
            ROLE[isl.idx] = "horn"
        elif n == 6 and uc[0] < 0.1:
            ROLE[isl.idx] = "lens"
        else:
            ROLE[isl.idx] = "cloth"            # tie, sleeve and strap pieces on the costume part of the sheet

    def wool(t):
        x, y, z = t.p
        cl = worley(x * 0.55, y * 0.55, z * 0.55, 121)
        cl2 = worley(x * 1.6 + 5, y * 1.6, z * 1.6, 133)
        n = fbm(x * 0.6, y * 0.6, z * 0.6, 15, 3)
        lobe = clamp(1.0 - cl / 0.85)
        base = mix((150, 142, 122), (250, 244, 222), clamp(lobe * 1.1 * (0.6 + 0.8 * n)))
        base = scale(base, 0.82 + 0.28 * smooth(0.2, 0.9, 1 - cl2))
        s = fbm(x * 0.4 + 2, y * 0.4, z * 0.4 + 8, 19, 3)
        base = mix(base, (150, 190, 70), smooth(0.64, 0.72, s) * 0.55)         # a few sickly green stains
        base = mix(base, (86, 120, 30), smooth(0.72, 0.8, s) * 0.5)
        return scale(base, 0.62 + 0.38 * smooth(-4.5, 1.0, y))

    def face(t):
        x, y, z = t.p
        ax = abs(x)
        skin = mix((176, 168, 150), (108, 102, 88), fbm(x * 0.9, y * 0.9, z * 0.9, 141, 3))
        skin = scale(skin, 0.75 + 0.35 * smooth(-2.0, 4.0, y))
        # rubber mask over everything in front of the ears, with a seam and straps behind it
        mask = smooth(7.4, 8.4, z) * smooth(3.0, 2.2, y)
        rub = mix((22, 26, 26), (58, 64, 62), fbm(x * 1.5, y * 1.5, z * 1.5, 143, 2))
        rub = mix(rub, (92, 98, 92), 0.55 * smooth(0.5, 1.0, t.n[1]))          # sheen on the top planes
        skin = mix(skin, rub, mask)
        edge = smooth(8.9, 8.2, z) * smooth(7.0, 7.4, z)                       # seam
        skin = mix(skin, (8, 10, 10), edge * 0.9)
        strap = smooth(0.35, 0.0, abs(z - 6.0)) * smooth(-1.0, 0.0, 3.2 - y)
        skin = mix(skin, (40, 34, 24), strap * 0.9)
        # lens rims: black ring, then a metal ring
        e = math.sqrt(((ax - 1.05) / 1.25) ** 2 + ((y - 0.8) / 1.7) ** 2)
        if z > 9.0:
            skin = mix(skin, (112, 114, 100), smooth(2.05, 1.6, e) * smooth(1.2, 1.5, e))
            skin = mix(skin, (6, 8, 6), smooth(1.6, 1.15, e))
        # canister on the muzzle: rim, olive can, grille
        cd = math.sqrt((ax / 1.35) ** 2 + ((y + 2.6) / 1.45) ** 2)
        if z > 10.4:
            skin = mix(skin, (120, 122, 96), smooth(1.15, 0.95, cd))
            can = mix((70, 78, 40), (118, 128, 66), smooth(0.2, 0.9, cd))
            grille = 0.0 if (int((ax + 5) * 4.0) + int((y + 5) * 4.0)) % 2 else 1.0
            can = mix(can, (10, 14, 6), grille * 0.8 * smooth(0.9, 0.5, cd))
            skin = mix(skin, can, smooth(0.95, 0.85, cd))
        return skin

    def lens(t):
        u0, v0, u1, v1 = t.isl.uvb
        fu = (t.u - u0) / max(u1 - u0, 1e-6)
        fv = (t.v - v0) / max(v1 - v0, 1e-6)
        d = math.sqrt(((fu - 0.5) / 0.5) ** 2 + ((fv - 0.5) / 0.5) ** 2)
        col = mix((60, 220, 40), (210, 255, 120), smooth(0.5, 0.0, d))
        col = mix(col, (14, 80, 20), smooth(0.55, 0.95, d))
        hl = smooth(0.2, 0.0, math.sqrt((fu - 0.3) ** 2 + (fv - 0.7) ** 2))
        return mix(col, (245, 255, 235), hl * 0.9)

    def leg(t):
        x, y, z = t.p
        sk = mix((214, 200, 174), (136, 124, 104), fbm(x * 1.2, y * 1.2, z * 1.2, 161, 3))
        sk = mix(sk, (110, 150, 40), smooth(0.66, 0.76, fbm(x * 0.8, y * 0.8, z * 0.8, 171, 3)) * 0.6)
        return mix(sk, (14, 12, 10), smooth(-8.2, -9.2, y))

    def horn(t):
        x, y, z = t.p
        d = dist3((abs(x), y, z), (3.0, 3.4, 6.2))
        ring = abs((d * 0.9) % 1.0 - 0.5) * 2.0                      # 1 between ridges, 0 on a ridge
        col = mix((232, 220, 178), (150, 126, 84), smooth(0.35, 0.0, ring) * 0.85)
        col = mix(col, (90, 66, 38), smooth(4.0, 7.0, d))            # darkening to the point
        return mix(col, (30, 22, 14), smooth(6.4, 7.5, d))

    def cloth_uv(t, dark=1.0, emblem=True):
        u0, v0, u1, v1 = t.isl.uvb
        fu = (t.u - u0) / max(u1 - u0, 1e-6)          # 0 at the outer edge, 1 at the spine
        fv = (t.v - v0) / max(v1 - v0, 1e-6)          # 0 at the hem, 1 at the neck
        fold = 0.5 + 0.5 * math.sin(fu * 17.0 + 3.0 * vnoise(fu * 3.0, fv * 2.0, 0.0, 201))
        n = fbm(t.x * 0.12, t.y * 0.12, 0.0, 203, 3)
        col = mix((84, 8, 14), (206, 26, 34), clamp(0.2 + 0.7 * fold * (0.5 + 0.6 * n)))
        col = mix(col, (62, 4, 8), smooth(0.5, 0.78, vnoise(t.x * 0.35, t.y * 0.35, 3.0, 205)) * 0.8)   # grime and old blood
        # burnt, ragged edges
        rag = vnoise(fu * 9.0, fv * 9.0, 1.0, 207)
        edge = min(fu * 1.4, fv * 1.0 + 0.1 * rag)
        col = mix((22, 4, 6), col, smooth(0.04 + 0.06 * rag, 0.16 + 0.08 * rag, edge))
        # worn-through patches
        col = mix(col, (14, 2, 4), smooth(0.74, 0.8, fbm(t.x * 0.22, t.y * 0.22, 5.0, 209, 3)))
        if emblem:   # toxic spatter: green splashes with a dark rim
            sp = fbm(t.x * 0.16 + 4.0, t.y * 0.16, 7.0, 215, 3)
            col = mix(col, (28, 36, 6), smooth(0.6, 0.64, sp))
            col = mix(col, (150, 236, 40), smooth(0.64, 0.68, sp))
        return scale(col, dark)

    def cloth(t):
        x, y, z = t.p
        return mix((70, 8, 12), (140, 20, 26), fbm(x * 1.4, y * 1.4, z * 1.4, 211, 2))

    def collar(t):
        x, y, z = t.p
        c = mix((54, 6, 10), (150, 18, 24), fbm(x * 0.9, y * 0.9, z * 0.9, 213, 3))
        stud = worley(x * 1.5, y * 1.5, z * 1.5, 215)
        return mix(c, (170, 160, 130), smooth(0.2, 0.1, stud) * 0.8)

    def fn(t):
        r = ROLE[t.isl.idx]
        if r == "cape":
            return cloth_uv(t)
        if r == "capein":
            return cloth_uv(t, 0.7, False)
        return {"wool": wool, "face": face, "leg": leg, "horn": horn, "lens": lens, "cloth": cloth, "collar": collar}[r](t)

    return {0: paint_texture(pr, 128, 128, fn, fill=(70, 20, 20))}


# ----------------------------------------------------------------------------------------------------------------------
# Carcass (Cow.Payload) - a rotting cow: ribs through torn hide, bone skull with long horns, wasted belly
# ----------------------------------------------------------------------------------------------------------------------

# the vanilla horn stub is a 4-vertex tetrahedron on top of the head (x mirrored): the tip and its three base vertices
_HORN_TIP = (3.58, 15.3, 14.84)
_HORN_BASE = [(1.54, 16.05, 14.63), (1.94, 14.03, 15.75), (2.39, 13.86, 13.78)]


def carcass_deform():
    ops = []
    cx = sum(p[0] for p in _HORN_BASE) / 3.0
    cy = sum(p[1] for p in _HORN_BASE) / 3.0
    cz = sum(p[2] for p in _HORN_BASE) / 3.0
    for sgn in (1, -1):
        # long, hooked horns: base ring leans out, the tip rises and curls outward
        ops.append({"op": "region", "box": _vbox(_HORN_TIP, sgn, 0.05), "falloff": 0.02,
                    "then": [{"op": "translate", "t": [round(5.6 * sgn, 3), 8.0, -2.6]}]})
        for p in _HORN_BASE:
            # lean the base ring out and spread it about its centre so the horn has a thick root
            ox, oy, oz = ((p[0] - cx) * 0.7, (p[1] - cy) * 0.7, (p[2] - cz) * 0.7)
            ops.append({"op": "region", "box": _vbox(p, sgn, 0.05), "falloff": 0.02,
                        "then": [{"op": "translate", "t": [round((1.1 + ox) * sgn, 3), round(1.6 + oy, 3), round(-0.2 + oz, 3)]}]})
    ops += [
        # wasted belly and sunken flanks: everything below the ribs is drawn in
        {"op": "region", "box": [[-12.5, -11.0, -17.5], [12.5, -0.5, 12.0]], "falloff": 4.0,
         "then": [{"op": "push", "dist": -2.2}, {"op": "noise", "amp": 0.5, "freq": 0.3, "seed": 21}]},
        # a ridge of spine and hip bones
        {"op": "region", "box": [[-1.5, 10.0, -17.0], [1.5, 13.5, 11.0]], "falloff": 2.0,
         "then": [{"op": "push", "dist": 0.9}]},
        # shrivelled udder
        {"op": "region", "box": [[-5.5, -11.5, -17.8], [5.5, 1.5, -6.0]], "falloff": 1.0,
         "then": [{"op": "push", "dist": -1.1}]},
        # thin shanks
        {"op": "region", "box": [[-11.5, -16.5, -16.0], [11.5, -9.0, 12.0]], "falloff": 2.0,
         "then": [{"op": "push", "dist": -0.3}]},
        # a long bare skull: the muzzle narrows and reaches forward
        {"op": "region", "box": [[-6.5, -1.5, 17.0], [6.5, 9.5, 26.5]], "falloff": 1.5,
         "then": [{"op": "scale", "s": [0.78, 0.82, 1.18], "about": [0.0, 4.0, 18.5]}]},
        # the whole animal is gaunt, lumpy and rotten
        {"op": "region", "box": [[-12.5, -16.5, -32.0], [12.5, 16.5, 26.5]], "falloff": 1.0,
         "then": [{"op": "noise", "amp": 0.3, "freq": 0.45, "seed": 5}]},
    ]
    return {"ops": ops}


def _paint_carcass(prims):
    body_pr, eye_pr = prims[0], prims[1]
    ROLE = {}
    for isl in body_pr["islands"]:
        n = len(isl.tris)
        if n == 90:
            ROLE[isl.idx] = "body"
        elif n == 80:
            ROLE[isl.idx] = "head"
        elif n == 44:
            ROLE[isl.idx] = "muzzle"
        elif n == 3:
            ROLE[isl.idx] = "horn"
        elif n in (15,):
            ROLE[isl.idx] = "ear"
        elif n == 32 and isl.hi[1] < 3.0:
            ROLE[isl.idx] = "udder"
        elif n in (32, 20, 2):
            ROLE[isl.idx] = "tail"
        elif n == 12:
            ROLE[isl.idx] = "udder"
        elif n in (30, 24):
            ROLE[isl.idx] = "leg"
        elif n == 16 or (n == 4 and isl.hi[1] < -15.0):
            ROLE[isl.idx] = "hoof"
        else:
            ROLE[isl.idx] = "ear"                       # the 4-triangle ear linings

    BONE = (232, 220, 186)
    BONE_D = (150, 128, 96)

    def hide(x, y, z):
        """Rotten hide: leathery brown-grey, mottled with green and purple, black dead patches where the spots were."""
        n = fbm(x * 0.18, y * 0.18, z * 0.18, 301, 3)
        c = mix((46, 34, 30), (96, 82, 66), n)
        c = mix(c, (66, 86, 50), smooth(0.55, 0.7, fbm(x * 0.12 + 3, y * 0.12, z * 0.12, 303, 3)) * 0.75)    # green rot
        c = mix(c, (92, 46, 66), smooth(0.58, 0.72, fbm(x * 0.14, y * 0.14 + 7, z * 0.14, 305, 3)) * 0.6)    # bruise
        c = mix(c, (12, 8, 8), smooth(0.6, 0.66, fbm(x * 0.1 + 9, y * 0.1, z * 0.1, 307, 2)))              # dead black patches
        return c

    def raw(x, y, z):
        return mix((66, 26, 24), (110, 40, 34), fbm(x * 0.5, y * 0.5, z * 0.5, 311, 3))

    def body(t):
        x, y, z = t.p
        ax = abs(x)
        c = hide(x, y, z)
        c = mix(c, (122, 40, 36), smooth(0.64, 0.72, fbm(x * 0.2 + 1, y * 0.2, z * 0.2, 309, 3)) * 0.8)       # weeping sores
        # ribs: bone bars that slant back over the flanks, seen through a big tear in the hide
        flank = smooth(4.0, 7.0, ax)
        zone = smooth(-13.5, -10.0, z) * smooth(10.5, 7.0, z) * smooth(11.5, 5.0, y) * smooth(-9.5, -4.0, y)
        torn = fbm(x * 0.16, y * 0.2, z * 0.16, 313, 3) * 0.35 + 0.65 * zone * flank
        expo = smooth(0.42, 0.5, torn)
        if expo > 0.0:
            ph = (z + 0.35 * (y - 2.0)) / 2.5
            frac = ph - math.floor(ph)
            rib = smooth(0.14, 0.26, frac) * smooth(0.86, 0.74, frac)
            cavity = mix(raw(x, y, z), (62, 24, 22), smooth(2.0, 7.0, ax) * 0.4)
            bone = mix(cavity, mix((190, 170, 136), BONE, smooth(0.0, 0.5, 1.0 - abs(frac - 0.5) * 2.0)), rib)
            bone = mix(bone, (150, 26, 30), (smooth(0.42, 0.46, torn) - smooth(0.46, 0.52, torn)) * 0.95)   # raw edge of the tear
            c = mix(c, bone, expo)
        # spine knuckles along the top
        k = smooth(9.5, 11.5, y) * smooth(1.8, 0.8, ax)
        vert = abs((z / 2.2) % 1.0 - 0.5) * 2.0
        c = mix(c, mix(BONE_D, BONE, smooth(0.8, 0.3, vert)), k * 0.9)
        # hips: bare bones at the back
        c = mix(c, BONE, smooth(0.62, 0.72, fbm(x * 0.3, y * 0.3, z * 0.3 + 4.0, 317, 2)) * smooth(-9.0, -13.0, z) * 0.8)
        # underside darkens
        return scale(c, 0.6 + 0.5 * smooth(-10.0, 4.0, y))

    def skull(t, muzzle=False):
        x, y, z = t.p
        ax = abs(x)
        c = mix(BONE, BONE_D, fbm(x * 0.35, y * 0.35, z * 0.35, 321, 3) * 1.1)
        # dark cracks and stains
        crack = abs(vnoise(x * 0.55, y * 0.55, z * 0.55, 323) - 0.5)
        c = mix((60, 44, 30), c, smooth(0.0, 0.04, crack) * 0.9 + 0.1)
        # hide remnants clinging near the ears and the neck
        h = smooth(0.58, 0.68, fbm(x * 0.2, y * 0.2, z * 0.2, 325, 3)) * smooth(15.5, 11.0, z) * 0.9
        c = mix(c, hide(x, y, z), h)
        # eye sockets: dark hollows ringed with shadow
        e = math.sqrt((ax - 4.3) ** 2 + (y - 9.3) ** 2 + ((z - 16.0) * 0.8) ** 2)
        c = mix(c, (10, 6, 6), smooth(4.4, 2.6, e))
        # forehead dip and nasal cavity
        nasal = math.sqrt((ax / 1.4) ** 2 + ((y - 4.5) / 1.8) ** 2)
        if z > 21.0:
            c = mix(c, (8, 4, 4), smooth(1.15, 0.8, nasal))
        # teeth: a bone-white comb along the jaw with dark gaps
        if z > 17.0:
            band = smooth(0.2, 0.9, 2.6 - y) * smooth(-0.9, -0.2, y)
            tooth = abs(((ax + 0.2) * 0.62) % 1.0 - 0.5) * 2.0
            gap = smooth(0.62, 0.85, tooth)
            c = mix(c, mix((246, 238, 212), (6, 2, 2), gap), band)
        return c

    def head(t):
        return skull(t)

    def muzzle(t):
        return skull(t, True)

    def horn(t):
        x, y, z = t.p
        d = y - 13.0
        ring = abs((d * 0.55) % 1.0 - 0.5) * 2.0
        c = mix(BONE, BONE_D, smooth(0.4, 0.0, ring) * 0.8)
        return mix(c, (46, 34, 22), smooth(4.0, 9.0, d))

    def ear(t):
        x, y, z = t.p
        c = mix((40, 28, 26), (84, 64, 52), fbm(x * 0.4, y * 0.4, z * 0.4, 331, 2))
        return mix(c, (110, 20, 26), smooth(0.6, 0.75, fbm(x * 0.5, y * 0.5, z * 0.5, 333, 2)) * 0.8)

    def udder(t):
        x, y, z = t.p
        return mix((96, 72, 70), (150, 118, 108), fbm(x * 0.4, y * 0.4, z * 0.4, 341, 3))

    def tail(t):
        x, y, z = t.p
        if z < -22.0:      # the tuft is a clot of black matted hair
            return mix((8, 6, 6), (58, 46, 40), fbm(x * 0.8, y * 0.8, z * 0.8, 343, 2))
        ring = abs((z * 0.45) % 1.0 - 0.5) * 2.0
        return mix(BONE, (40, 24, 20), smooth(0.7, 1.0, ring) * 0.9)

    def leg(t):
        x, y, z = t.p
        sk = hide(x, y, z)
        # shin bones show through below the knee
        shin = smooth(-4.0, -8.0, y)
        k = abs(vnoise(x * 0.5, y * 0.3, z * 0.5, 351) - 0.5)
        bone = mix(BONE, BONE_D, smooth(0.0, 0.2, k))
        return scale(mix(sk, bone, shin * 0.95), 0.85)

    def hoof(t):
        x, y, z = t.p
        return mix((16, 12, 12), (48, 38, 34), fbm(x * 0.8, y * 0.8, z * 0.8, 361, 2))

    def fn(t):
        return {"body": body, "head": head, "muzzle": muzzle, "horn": horn, "ear": ear, "udder": udder, "tail": tail,
                "leg": leg, "hoof": hoof}[ROLE[t.isl.idx]](t)

    def eye(t):
        # the 32x32 eyeball sheet: a dead black ball with one dull ember
        fu, fv = t.u, t.v
        d = math.sqrt((fu - 0.55) ** 2 + (fv - 0.42) ** 2)
        c = mix((16, 10, 12), (34, 18, 22), smooth(0.5, 0.0, math.sqrt((fu - 0.5) ** 2 + (fv - 0.5) ** 2)))
        c = mix(c, (255, 120, 30), smooth(0.16, 0.06, d))
        return mix(c, (255, 220, 120), smooth(0.07, 0.02, d))

    return {0: paint_texture(body_pr, 128, 128, fn, fill=(40, 30, 28)),
            1: paint_texture(eye_pr, 32, 32, eye, fill=(16, 10, 12))}


# ----------------------------------------------------------------------------------------------------------------------
# model table
# ----------------------------------------------------------------------------------------------------------------------


class Model:
    def __init__(self, slug, vanilla, name, section, images, deform, painter):
        self.slug, self.vanilla, self.name, self.section = slug, vanilla, name, section
        self.images = images    # [(w, h)] in --list-images order
        self.deform = deform
        self.painter = painter


MODELS = [
    Model("rabid_sheep", "Sheep", "RabidSheep", 505, [(128, 128)], sheep_deform, _paint_sheep),
    Model("plague_ram", "SuperSheep", "PlagueRam", 506, [(128, 128)], plague_deform, _paint_plague),
    Model("carcass", "Cow.Payload", "Carcass", 507, [(128, 128), (32, 32)], carcass_deform, _paint_carcass),
]

# ----------------------------------------------------------------------------------------------------------------------
# build
# ----------------------------------------------------------------------------------------------------------------------


def run(cmd):
    r = subprocess.run([str(c) for c in cmd], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError("command failed (%d): %s\n%s%s" % (r.returncode, " ".join(str(c) for c in cmd), r.stdout, r.stderr))
    return r.stdout


def list_images(xomtool, bundl09, vanilla):
    out = run([xomtool, "clone", vanilla, "--from", bundl09, "--list-images"])
    return [(int(m.group(2)), int(m.group(3))) for m in re.finditer(r"\[(\d+)\].*?\s(\d+)x(\d+)\s", out)]


def build_model(m, xomtool, bundl09, out_xom, work):
    work = Path(work)
    work.mkdir(parents=True, exist_ok=True)
    sizes = list_images(xomtool, bundl09, m.vanilla)
    if sizes != m.images:
        raise RuntimeError("%s: vanilla images are %s, painter expects %s" % (m.vanilla, sizes, m.images))
    deform = work / (m.slug + ".deform.json")
    deform.write_text(json.dumps(m.deform(), indent=1, sort_keys=True))
    base = [xomtool, "clone", m.vanilla, "--from", bundl09, "--as", "kindjal." + m.name, "--section", m.section, "--deform", deform]
    # pass 1: the deformed geometry (vanilla textures), as glTF, for the painter
    geo = work / (m.slug + ".geo.gltf")
    run(base + ["--bundle", work / (m.slug + ".geo.xom"), "--out-gltf", geo])
    prims = load_gltf(geo)
    textures = m.painter(prims)
    args = []
    for k, cv in sorted(textures.items()):
        w, h = m.images[k]
        png = work / ("%s.tex%d.png" % (m.slug, k))
        write_png(png, w, h, cv)
        args += ["--texture", "%d=%s" % (k, png)]
    # pass 2: the bank
    run(base + ["--bundle", out_xom, "--out-gltf", work / (m.slug + ".gltf")] + args)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--xomtool", default=DEFAULT_XOMTOOL)
    ap.add_argument("--bundl09", default=DEFAULT_BUNDL09)
    ap.add_argument("--out", default=str(DEFAULT_OUT), help="directory for kindjal.<Name>.xom")
    ap.add_argument("--only", default="", help="comma separated slugs")
    ap.add_argument("--work", default="", help="keep textures, deform JSON and glTF previews here")
    ap.add_argument("--check", action="store_true", help="rebuild into a temp dir and compare bytes with --out")
    a = ap.parse_args(argv)
    _paths.require_tools(a.xomtool, a.bundl09)
    want = [s for s in a.only.split(",") if s]
    _paths.require_slugs(want, [m.slug for m in MODELS])
    models = [m for m in MODELS if not want or m.slug in want]
    tmp = Path(tempfile.mkdtemp(prefix="clones_beasts_"))
    bad = 0
    try:
        for m in models:
            fname = "kindjal.%s.xom" % m.name
            dest = (tmp / "out") if a.check else Path(a.out)
            dest.mkdir(parents=True, exist_ok=True)
            work = Path(a.work) / m.slug if a.work else tmp / "work" / m.slug
            build_model(m, a.xomtool, a.bundl09, dest / fname, work)
            size = (dest / fname).stat().st_size
            if a.check:
                ref = Path(a.out) / fname
                same = ref.exists() and ref.read_bytes() == (dest / fname).read_bytes()
                print("%-24s %s" % (fname, "identical" if same else "DIFFERS"))
                bad += 0 if same else 1
            else:
                print("%-24s %d bytes  section %d" % (fname, size, m.section))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
