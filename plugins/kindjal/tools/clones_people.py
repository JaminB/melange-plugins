#!/usr/bin/env python3
"""Kindjal character clones: Hangwoman (Oldwoman), Knifeman (Scouser), Gorger (Fatkins.Fatboy).

Each bank is a CLONE of a vanilla skinned mesh (xomtool clone): the skeleton, node names, clip library and texture
stages are the vanilla ones, so the vanilla animation clips still drive it.  What changes is (1) the vertex positions
(a --deform script: same vertex count, same order, same skin weights) and (2) every texture, repainted here.

Painting.  Each texture is painted per UV island.  The vanilla geometry is baked into UV space (every texel remembers
which island, which 3D position and which normal it belongs to; UVs wrap, as they do in game), then a small shader per
model decides the colour from the island and the 3D position, so a feature such as an eye slit, a knife blade or a
stain sits where it should on the mesh whatever the unwrap does.  Everything is deterministic (hash noise, no random).

Run:   python tools/clones_people.py [--only slug,...] [--check]
       [--xomtool PATH] [--bundl09 PATH] [--out-dir DIR]

Importing this file has no side effects; stdlib only.
"""
import argparse
import json
import math
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # the helper sits beside this file
import _paths  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_XOMTOOL = _paths.default_xomtool()
DEFAULT_BUNDL09 = _paths.default_bundl09()
DEFAULT_OUT = os.path.normpath(os.path.join(HERE, "..", "mod", "assets", "meshes"))


# ============================================================ small utilities

def clamp01(x):
    return 0.0 if x < 0 else (1.0 if x > 1 else x)


def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(len(a)))


def smooth(t):
    t = clamp01(t)
    return t * t * (3 - 2 * t)


def hex_rgb(s):
    s = s.lstrip("#")
    return tuple(int(s[i:i + 2], 16) for i in (0, 2, 4))


def shade(c, k):
    return (c[0] * k, c[1] * k, c[2] * k)


def _hash3(ix, iy, iz, seed):
    h = (ix * 374761393 + iy * 668265263 + iz * 2147483647 + seed * 1442695041) & 0xFFFFFFFF
    h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
    h ^= h >> 16
    return (h & 0xFFFF) / 65535.0


def vnoise(x, y, z, seed=1):
    """Value noise in 0..1, a pure function of position and seed."""
    ix, iy, iz = math.floor(x), math.floor(y), math.floor(z)
    fx, fy, fz = smooth(x - ix), smooth(y - iy), smooth(z - iz)
    c = [[[_hash3(ix + a, iy + b, iz + d, seed) for d in (0, 1)] for b in (0, 1)] for a in (0, 1)]
    x00 = c[0][0][0] + (c[1][0][0] - c[0][0][0]) * fx
    x10 = c[0][1][0] + (c[1][1][0] - c[0][1][0]) * fx
    x01 = c[0][0][1] + (c[1][0][1] - c[0][0][1]) * fx
    x11 = c[0][1][1] + (c[1][1][1] - c[0][1][1]) * fx
    y0 = x00 + (x10 - x00) * fy
    y1 = x01 + (x11 - x01) * fy
    return y0 + (y1 - y0) * fz


def fbm(x, y, z, seed=1, octaves=3):
    t, amp, tot = 0.0, 1.0, 0.0
    for o in range(octaves):
        t += amp * vnoise(x, y, z, seed + o * 17)
        tot += amp
        x, y, z, amp = x * 2.03, y * 2.03, z * 2.03, amp * 0.5
    return t / tot


# ============================================================ PNG

def write_png(path, rows, w, h, alpha=False):
    """rows[y][x] = (r,g,b) or (r,g,b,a), floats or ints, top row first."""
    n = 4 if alpha else 3
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        for x in range(w):
            c = rows[y][x]
            for k in range(n):
                v = int(c[k] + 0.5) if k < len(c) else 255
                raw.append(0 if v < 0 else (255 if v > 255 else v))

    def chunk(t, b):
        c = t + b
        return struct.pack(">I", len(b)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    data = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6 if alpha else 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(data)


# ============================================================ xomtool plumbing

class Tool:
    def __init__(self, xomtool, bundl09):
        self.xomtool, self.bundl09 = xomtool, bundl09

    def run(self, *args):
        r = subprocess.run([self.xomtool] + [str(a) for a in args], capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError("xomtool %s failed (%d): %s%s" % (" ".join(map(str, args[:3])), r.returncode, r.stdout, r.stderr))
        return r.stdout

    def clone(self, vanilla, out_xom, name, section, textures=None, deform=None, extra=()):
        a = ["clone", vanilla, "--from", self.bundl09, "--bundle", out_xom, "--as", name, "--section", section]
        for k, p in sorted((textures or {}).items()):
            a += ["--texture", "%d=%s" % (k, p)]
        if deform:
            a += ["--deform", deform]
        return self.run(*(a + list(extra)))

    def geometry(self, xom_path):
        """All XIndexedTriangleSets of a bank, in file order, as dicts of pos/nrm/uv/tris."""
        j = xom_path + ".json"
        self.run("unpack", xom_path, "-o", j)
        with open(j) as f:
            d = json.load(f)
        objs = d["objects"]
        out = []
        for x in objs:
            if x["type"] != "XIndexedTriangleSet":
                continue
            f_ = x["fields"]
            g = lambda k, n: objs[f_[k]["ref"] - 1]["fields"][n]
            idx = g("IndexSet", "Index")
            out.append(dict(pos=g("CoordSet", "Coord"), nrm=g("NormalSet", "Normal"), uv=g("TexCoordSet", "TexCoord"),
                            tris=[tuple(idx[k:k + 3]) for k in range(0, len(idx), 3)]))
        os.remove(j)
        return out


# ============================================================ geometry baking

def islands(geo):
    """Island id per vertex: triangles joined by shared vertex indices; ids ordered by lowest vertex index."""
    n = len(geo["pos"])
    par = list(range(n))

    def find(a):
        while par[a] != a:
            par[a] = par[par[a]]
            a = par[a]
        return a

    for t in geo["tris"]:
        for k in (1, 2):
            ra, rb = find(t[0]), find(t[k])
            if ra != rb:
                par[max(ra, rb)] = min(ra, rb)
    ids, out = {}, []
    for i in range(n):
        r = find(i)
        if r not in ids:
            ids[r] = len(ids)
        out.append(ids[r])
    return out


class Bake:
    """A mesh baked into texel space.  isl[y][x] is the island id (-1 where nothing maps), pos/nrm the interpolated
    3D position / normal.  Gaps within `grow` texels of a mapped texel are filled from it (so seams do not bleed)."""

    def __init__(self, geo, w, h, grow=3, prio=None):
        """prio: {island: priority}; where islands share texels the higher priority keeps them (default 0, ties go
        to the later triangle)."""
        self.w, self.h = w, h
        prio = prio or {}
        vi = islands(geo)
        self.nisl = max(vi) + 1
        self.isl = [[-1] * w for _ in range(h)]
        self.pos = [[None] * w for _ in range(h)]
        self.nrm = [[None] * w for _ in range(h)]
        self.mapped = [[False] * w for _ in range(h)]
        P, N, UV = geo["pos"], geo["nrm"], geo["uv"]
        for (a, b, c) in geo["tris"]:
            ax, ay = UV[a][0] * w, (1 - UV[a][1]) * h
            bx, by = UV[b][0] * w, (1 - UV[b][1]) * h
            cx, cy = UV[c][0] * w, (1 - UV[c][1]) * h
            den = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
            if abs(den) < 1e-9:
                continue
            x0, x1 = int(math.floor(min(ax, bx, cx))), int(math.ceil(max(ax, bx, cx)))
            y0, y1 = int(math.floor(min(ay, by, cy))), int(math.ceil(max(ay, by, cy)))
            isl = vi[a]
            for y in range(y0, y1):
                for x in range(x0, x1):
                    px, py = x + 0.5, y + 0.5
                    l0 = ((by - cy) * (px - cx) + (cx - bx) * (py - cy)) / den
                    l1 = ((cy - ay) * (px - cx) + (ax - cx) * (py - cy)) / den
                    l2 = 1 - l0 - l1
                    if l0 < -0.02 or l1 < -0.02 or l2 < -0.02:
                        continue
                    wx, wy = x % w, y % h
                    if self.isl[wy][wx] >= 0 and prio.get(isl, 0) < prio.get(self.isl[wy][wx], 0):
                        continue
                    self.isl[wy][wx] = isl
                    self.pos[wy][wx] = tuple(l0 * P[a][k] + l1 * P[b][k] + l2 * P[c][k] for k in range(3))
                    self.nrm[wy][wx] = tuple(l0 * N[a][k] + l1 * N[b][k] + l2 * N[c][k] for k in range(3))
                    self.mapped[wy][wx] = True
        for _ in range(grow):
            add = []
            for y in range(h):
                for x in range(w):
                    if self.isl[y][x] >= 0:
                        continue
                    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                        yy, xx = (y + dy) % h, (x + dx) % w
                        if self.isl[yy][xx] >= 0:
                            add.append((y, x, yy, xx))
                            break
            for (y, x, yy, xx) in add:
                self.isl[y][x], self.pos[y][x], self.nrm[y][x] = self.isl[yy][xx], self.pos[yy][xx], self.nrm[yy][xx]

    def paint(self, fn, base=(0, 0, 0)):
        """fn(isl, pos, nrm, x, y) -> colour, for every texel the bake reaches; other texels get `base`."""
        rows = [[base] * self.w for _ in range(self.h)]
        for y in range(self.h):
            for x in range(self.w):
                i = self.isl[y][x]
                if i >= 0:
                    rows[y][x] = fn(i, self.pos[y][x], self.nrm[y][x], x, y)
        return rows


# ============================================================ 2D drawing on a row grid

def blend(c, d, a):
    return (c[0] + (d[0] - c[0]) * a, c[1] + (d[1] - c[1]) * a, c[2] + (d[2] - c[2]) * a)


def ellipse(rows, cx, cy, rx, ry, col, soft=1.0, alpha=1.0):
    h, w = len(rows), len(rows[0])
    for y in range(max(0, int(cy - ry - soft - 1)), min(h, int(cy + ry + soft + 2))):
        for x in range(max(0, int(cx - rx - soft - 1)), min(w, int(cx + rx + soft + 2))):
            d = math.hypot((x + 0.5 - cx) / rx, (y + 0.5 - cy) / ry)
            e = (1 - d) * min(rx, ry) / max(soft, 1e-6)
            a = clamp01(e + 0.5) * alpha
            if a > 0:
                rows[y][x] = blend(rows[y][x], col, a)


def rect(rows, x0, y0, x1, y1, col, alpha=1.0):
    h, w = len(rows), len(rows[0])
    for y in range(max(0, int(y0)), min(h, int(y1))):
        for x in range(max(0, int(x0)), min(w, int(x1))):
            rows[y][x] = blend(rows[y][x], col, alpha)


def line(rows, x0, y0, x1, y1, width, col, alpha=1.0):
    h, w = len(rows), len(rows[0])
    dx, dy = x1 - x0, y1 - y0
    ln2 = dx * dx + dy * dy or 1e-9
    r = width / 2 + 1
    for y in range(max(0, int(min(y0, y1) - r)), min(h, int(max(y0, y1) + r + 1))):
        for x in range(max(0, int(min(x0, x1) - r)), min(w, int(max(x0, x1) + r + 1))):
            t = clamp01(((x + 0.5 - x0) * dx + (y + 0.5 - y0) * dy) / ln2)
            d = math.hypot(x + 0.5 - (x0 + t * dx), y + 0.5 - (y0 + t * dy))
            a = clamp01(width / 2 - d + 0.5) * alpha
            if a > 0:
                rows[y][x] = blend(rows[y][x], col, a)


# ============================================================ model definitions (below)


# ============================================================ KNIFEMAN  (Scouser -> kindjal.Knifeman, section 509)
#
# Scouser: 7 bones, one 256x256 texture, one skinned shape of 625 vertices in 9 islands (hair 3 + hair-back 1, face 2,
# moustache 4, body-and-legs 7, scarf strips 8, back tag 0, hands 5 and 6).  The hands are blobs pointing out along +-x
# whose outer rings (|x| > 5.9) belong to nothing else, so they are bent up into blades; the hair becomes a hood.

HOOD = hex_rgb("46567f")
HOOD_DARK = hex_rgb("151a30")
HOOD_LIGHT = hex_rgb("6a7aa8")
VOID = (7, 8, 15)
STEEL = hex_rgb("a9b6c4")
COLD = hex_rgb("a8f0ff")


def _cloth(p, n, seed, base=HOOD, k=1.0):
    """Hoodie cloth: long vertical folds, a coarse mottling, darker where the normal faces down."""
    folds = fbm(p[0] * 0.9, p[1] * 0.28, p[2] * 0.9, seed, 3)
    grit = vnoise(p[0] * 5.0, p[1] * 5.0, p[2] * 5.0, seed + 5)
    v = 0.30 + 1.15 * folds + 0.18 * (grit - 0.5)
    v *= 0.78 + 0.32 * clamp01(0.5 + 0.5 * n[1]) + 0.1 * clamp01(n[2])
    return mix(shade(HOOD_DARK, 1.0), shade(base, 1.25 * k), clamp01(v))


def knifeman_body(isl, p, n, x, y):
    ax = abs(p[0])
    if isl in (3, 1):  # hood
        c = _cloth(p, n, 11, HOOD, 1.05)
        if isl == 1 or p[2] < 0.5:
            # seam down the back, lighter crown
            if ax < 0.35:
                c = shade(c, 0.35)
            c = mix(c, HOOD_LIGHT, 0.22 * clamp01((p[1] - 26) / 5))
        else:  # inside the opening: swallowed by shadow
            c = mix(c, VOID, smooth((p[2] - 0.5) / 2.0) * 0.9)
        return c
    if isl == 2:  # the face: a void with two cold slits
        c = shade(VOID, 0.8 + 0.6 * vnoise(p[0], p[1], p[2], 3))
        c = mix(c, HOOD_DARK, clamp01((abs(p[0]) - 3.2) / 2.0) * 0.7 + clamp01((p[1] - 25.0) / 1.2) * 0.6)
        for sx in (-1, 1):
            d = math.hypot((ax - 2.15) / 1.45, (p[1] - 23.25 - 0.18 * (ax - 2.15)) / 0.5) if p[0] * sx > 0 else 9
            if d < 3.2:
                c = mix(c, (30, 95, 125), clamp01((3.2 - d) / 2.2) * 0.75)
            if d < 1.0:
                c = mix(COLD, (255, 255, 255), clamp01(1.0 - d * 1.3))
        return c
    if isl == 4:  # where the moustache was
        return shade(VOID, 1.0 + 0.4 * vnoise(p[0] * 3, p[1] * 3, p[2] * 3, 9))
    if isl == 7:  # body and legs
        yy = p[1]
        if yy > 6.6:  # hoodie body
            c = _cloth(p, n, 21, HOOD, 1.0)
            if 7.6 > yy > 6.6:  # ribbed hem
                c = shade(c, 0.55 + 0.35 * (0.5 + 0.5 * math.sin(p[0] * 7)))
            if p[2] > 2.0 and 7.2 < yy < 11.8 and ax < 4.0:  # kangaroo pocket
                edge = min(abs(yy - 11.4), abs(ax - 3.6)) < 0.3 or abs(yy - 7.6) < 0.25
                c = shade(c, 0.4) if edge else shade(c, 1.12)
            return c
        if yy > 1.9:  # trousers
            c = _cloth(p, n, 31, (30, 34, 48), 1.0)
            return shade(c, 0.8)
        # boots with a pale rim
        c = shade((26, 24, 30), 0.8 + 0.7 * vnoise(p[0] * 2, p[1] * 2, p[2] * 2, 5))
        return mix(c, (110, 116, 128), clamp01((0.9 - yy) / 0.5)) if yy < 0.9 else c
    if isl == 8:  # scarf strips become cowl panels with a drawstring
        c = _cloth(p, n, 41, HOOD, 1.2)
        cord = abs(ax - 4.5) < 0.28 and p[1] < 12.5 and p[2] > 3.0
        if cord:
            c = mix(c, (175, 184, 205), 0.9)
        if p[1] < 4.6 and abs(ax - 5.6) < 1.0 and p[2] > 3.0:
            c = shade(c, 0.6)
        return c
    if isl == 0:  # back tag
        d = math.hypot(p[0], p[1] - 12.5)
        c = _cloth(p, n, 51, HOOD, 0.9)
        return mix(c, (170, 180, 200), 0.65) if d < 1.6 and (abs(p[0]) - abs(p[1] - 12.5)) ** 2 < 0.2 else c
    if isl in (5, 6):  # hands: leather glove, brass guard, steel blade
        dy, dz = p[1] - 12.7, p[2]
        if ax > 7.0:
            r = math.hypot(dy, dz) or 1
            cs = abs(dz) / r  # 1 = broad face of the blade, 0 = its edge
            c = shade(STEEL, 0.62 + 0.5 * cs + 0.25 * vnoise(p[0] * 2, p[1] * 3, p[2] * 3, 4))
            if cs < 0.3:
                c = mix(c, (235, 244, 252), 0.85)  # honed edge
            if cs > 0.82 and ax > 7.6:
                c = shade(c, 0.62)  # fuller
            if vnoise(p[0] * 9, p[1] * 2, p[2] * 9, 8) > 0.82:
                c = shade(c, 1.25)  # scratch glints
            return c
        if ax > 6.6:
            return (150, 118, 52)  # brass crossguard
        c = shade((34, 30, 38), 0.8 + 0.8 * vnoise(p[0] * 2, p[1] * 2, p[2] * 2, 6))
        return c
    return HOOD


def _blade_ops(z0):
    """Push the outer hand away from the body (a fist), then flatten, stretch and bend its last three rings up into
    a blade.  z0 is where the hand is (0, or 60 for the parked mirror image of the other one)."""
    return [
        {"op": "region", "box": [[5.9, 9.5, z0 - 5], [10.5, 17, z0 + 5]], "falloff": 0,
         "then": [{"op": "translate", "t": [1.0, 0, 0]}]},
        {"op": "region", "box": [[7.9, 9.5, z0 - 5], [12, 17, z0 + 5]], "falloff": 0,
         "then": [{"op": "scale", "s": [5.6, 0.7, 0.3], "about": [8.0, 12.7, z0]},
                  {"op": "bend", "axis": "x", "dir": "y", "amount": 86, "length": 1.6, "about": [8.0, 12.7, z0]}]},
    ]


KNIFEMAN_DEFORM = {"ops": [
    # the left hand is mirrored into the +x hand's place (parked 60 units behind it in z), shaped with the right one,
    # and mirrored back; the boxes are generous so every hand vertex is inside and no body vertex is
    {"op": "region", "box": [[-10.5, 9.5, -5], [-5.9, 17, 5]], "falloff": 0,
     "then": [{"op": "scale", "s": [-1, 1, 1], "about": [0, 12.7, 0]}, {"op": "translate", "t": [0, 0, 60]}]},
] + _blade_ops(0) + _blade_ops(60) + [
    {"op": "region", "box": [[-1.0, 0, 50], [40, 60, 70]], "falloff": 0,
     "then": [{"op": "translate", "t": [0, 0, -60]}, {"op": "scale", "s": [-1, 1, 1], "about": [0, 12.7, 0]}]},
    # bulk the hoodie body (not the hands)
    {"op": "region", "box": [[-5.0, 3, -8], [5.0, 16.5, 7]], "falloff": 0.8, "then": [{"op": "push", "dist": 0.9}]},
    # hood: swell the back and crown of the head, then pull a peak up and back
    {"op": "region", "box": [[-9, 19, -10], [9, 33, 1.0]], "falloff": 3.0, "then": [{"op": "push", "dist": 1.4}]},
    {"op": "region", "box": [[-3, 27, -6], [3, 33, 0]], "falloff": 3.0, "then": [{"op": "translate", "t": [0, 2.4, -1.8]}]},
]}


# ============================================================ GORGER  (Fatkins.Fatboy -> kindjal.Gorger, section 510)
#
# Fatkins: 17 bones, one 256x256 texture, one skinned shape of 1440 vertices in 37 islands (many are left/right pairs
# sharing texels, so the shader is symmetric in x).  Islands: 4 head, 2/3/5 hair, 1 shirt (+ 6/7/12/13 sleeves),
# 0 belly skin, 8/9/14/15 forearms, 10/11/16/17 wrists, 18 shorts (+19 fly), 20-26/28-35 legs, socks and shoes.

SKIN = hex_rgb("a06f4f")
SKIN_DARK = hex_rgb("4a2c20")
SHIRT = hex_rgb("6b7d3e")
SHIRT_DARK = hex_rgb("28321a")
TOOTH = hex_rgb("e6dcae")


def _gorger_head(p, n, x, y):
    ax = abs(p[0])
    c = shade(SKIN, 0.55 + 0.75 * fbm(p[0] * 0.7, p[1] * 0.7, p[2] * 0.7, 61, 3))
    c = shade(c, 0.85 + 0.3 * vnoise(p[0] * 6, p[1] * 6, p[2] * 6, 62))
    # sallow, sweaty cheeks, shadow under the brow and in the jowls
    c = mix(c, (110, 120, 70), 0.18 * clamp01(1.0 - (p[1] - 14.0) / 5.0))
    if p[2] > 1.5:
        # brow ridge and beady eyes
        for sx in (-1, 1):
            if p[0] * sx > 0:
                ey = 20.75
                d = math.hypot((ax - 1.55) / 0.85, (p[1] - ey) / 0.55)
                brow = 21.9 + 0.55 * (ax - 0.3) - 0.0
                if abs(p[1] - brow) < 0.45 and ax < 3.6:
                    c = mix(c, (30, 16, 12), 0.9)
                if d < 1.8:
                    c = mix(c, (60, 20, 18), clamp01(1.8 - d) * 0.5)
                if d < 1.0:
                    c = mix((235, 225, 190), (170, 60, 50), clamp01(d - 0.65) * 1.2)
                    if math.hypot(ax - 1.4, p[1] - ey) < 0.28:
                        c = (8, 6, 6)
        # nostrils
        if abs(p[1] - 19.2) < 0.4 and abs(ax - 0.8) < 0.35:
            c = (40, 18, 14)
        # the open mouth: lip ring, black throat, teeth top and bottom, a fat tongue, drool
        mx, my, rx, ry = 0.0, 16.0, 4.9, 3.0
        d = math.hypot((p[0] - mx) / rx, (p[1] - my) / ry)
        if d < 1.18:
            c = mix(c, (118, 44, 40), clamp01((1.18 - d) * 8))
        if d < 1.0:
            c = (34, 6, 10)
            top = my + ry * math.sqrt(max(0.0, 1 - (p[0] / rx) ** 2))
            bot = my - ry * math.sqrt(max(0.0, 1 - (p[0] / rx) ** 2))
            ph = (p[0] + 4.9) / 1.0
            f = abs(ph - math.floor(ph) - 0.5)  # 0 at a tooth's middle
            tl = 1.15 * (1.0 - 1.7 * f)
            if top - p[1] < tl and f < 0.5:
                c = shade(TOOTH, 0.7 + 0.5 * vnoise(p[0] * 4, p[1] * 4, 1, 7))
            ph2 = (p[0] + 4.4) / 1.2
            f2 = abs(ph2 - math.floor(ph2) - 0.5)
            if p[1] - bot < 0.8 * (1.0 - 1.8 * f2) and f2 < 0.5:
                c = shade(TOOTH, 0.55 + 0.4 * vnoise(p[0] * 4, p[1] * 4, 2, 7))
            if math.hypot(p[0] / 2.7, (p[1] - (bot + 0.5)) / 1.2) < 1.0:
                c = mix((150, 30, 42), (210, 80, 80), clamp01(0.6 - (p[1] - bot) * 0.3))
        # drool: two yellow-green streaks from the mouth corners
        for sx in (-1, 1):
            if abs(p[0] - sx * 3.3) < 0.25 and p[1] < my - 1.5 and p[1] > 11.8:
                c = mix(c, (200, 190, 90), 0.8)
    if p[2] < 1.5 and p[1] > 17:
        c = shade(c, 0.8)
    return c


def gorger_body(isl, p, n, x, y):
    ax = abs(p[0])
    if isl == 4:
        return _gorger_head(p, n, x, y)
    if isl in (2, 3, 5):  # greasy dark hair
        return shade((46, 30, 22), 0.5 + 1.2 * vnoise(p[0] * 3, p[1] * 3, p[2] * 3, 12))
    if isl in (1, 6, 7, 12, 13):  # the shirt: stained olive with a rotten collar and darker pits
        stain = fbm(p[0] * 0.28, p[1] * 0.28, p[2] * 0.28, 71, 3)
        c = mix(SHIRT_DARK, SHIRT, clamp01(0.35 + 1.5 * fbm(p[0] * 0.9, p[1] * 0.3, p[2] * 0.9, 72, 3)))
        c = shade(c, 0.88 + 0.28 * vnoise(p[0] * 7, p[1] * 7, p[2] * 7, 73))
        if stain > 0.60:
            c = mix(c, (24, 24, 12), clamp01((stain - 0.60) * 9) * 0.85)  # big grease blotches
        for (bx, by, bz, br) in ((-7, 7, 14, 3.0), (6, 10, 12, 2.6), (2, 1, 14.5, 2.0), (-11, 12, 8, 2.4), (10, 3, 13, 2.2)):
            if (p[0] - bx) ** 2 + (p[1] - by) ** 2 + (p[2] - bz) ** 2 < br * br:
                c = shade(c, 0.45)
        if p[1] > 15.5:
            c = shade(c, 0.6)
        if p[1] < 0.8 and isl == 1:
            c = mix(c, (30, 20, 12), clamp01((0.8 - p[1]) / 2.0))  # sweaty hem
        return c
    if isl == 0:  # belly skin with a navel
        c = shade(SKIN, 0.7 + 0.6 * fbm(p[0] * 0.5, p[1] * 0.5, p[2] * 0.5, 81, 3))
        c = mix(c, (118, 70, 66), clamp01((2.5 - p[1]) / 6.0) * 0.5)
        if math.hypot(p[0], p[1] + 0.3) < 0.9 and p[2] > 8:
            c = (36, 16, 12)
        if abs(math.sin(p[0] * 2.5 + p[1] * 0.4)) > 0.96 and p[2] > 5:
            c = shade(c, 0.7)  # stretch marks
        return c
    if isl in (8, 9, 14, 15, 10, 11, 16, 17):  # arms: skin, a dirty bandage, a dark fist
        c = shade(SKIN, 0.55 + 0.8 * fbm(p[0] * 0.5, p[1] * 0.5, p[2] * 0.5, 91, 3))
        if 24.5 < ax < 27.4:
            c = shade((196, 188, 160), 0.7 + 0.5 * vnoise(p[0] * 2, p[1] * 3, p[2] * 3, 92))
            if abs(((ax - 24.5) * 3.0) % 1.0 - 0.5) < 0.07:
                c = shade(c, 0.55)
            if vnoise(p[0], p[1], p[2], 93) > 0.68:
                c = (120, 36, 30)
        if ax > 30:
            c = shade(c, 0.8)
        return c
    if isl in (18, 19, 20, 28):  # shorts
        c = _cloth_g(p, (74, 66, 54), 101)
        if isl == 19:
            c = shade(c, 0.5)
        return c
    if p[1] > -19.4 and isl in (21, 22, 29, 30):  # socks
        return shade((178, 166, 128), 0.6 + 0.7 * vnoise(p[0] * 3, p[1] * 3, p[2] * 3, 111))
    if p[1] < -21.7:  # soles
        return (26, 20, 16)
    return shade((98, 62, 38), 0.55 + 0.9 * fbm(p[0] * 0.9, p[1] * 0.9, p[2] * 0.9, 121, 3))  # shoes and the rest


def _cloth_g(p, base, seed):
    f = fbm(p[0] * 0.6, p[1] * 0.6, p[2] * 0.6, seed, 3)
    return shade(base, 0.45 + 1.1 * f)


GORGER_DEFORM = {"ops": [
    # the belly: swell the whole middle, most of all in front, and let it hang
    {"op": "region", "box": [[-16, -13, -14], [16, 5, 16]], "falloff": 5.0, "then": [{"op": "push", "dist": 2.6}]},
    {"op": "region", "box": [[-12, -10, 4], [12, -2, 16]], "falloff": 4.0, "then": [{"op": "translate", "t": [0, -1.2, 2.2]}]},
    # a dropped jaw: the lower face sinks a little
    {"op": "region", "box": [[-8, 11, 0.5], [8, 17.0, 8]], "falloff": 2.0, "then": [{"op": "translate", "t": [0, -1.4, 0.6]}]},
    # a few lumps so the silhouette is not a perfect ball
    {"op": "region", "box": [[-16, -13, -14], [16, 5, 16]], "falloff": 3.0,
     "then": [{"op": "noise", "amp": 0.45, "freq": 0.25, "seed": 5}]},
]}


# ============================================================ HANGWOMAN  (Oldwoman -> kindjal.Hangwoman, section 508)
#
# Oldwoman: 23 bones + two rigid parts, 4 textures:  [0] 64x64 handbag, [1] 64x64 walking stick, [2] 128x128 the body
# (a skinned shape in 27 islands: 18 face, 19/20 ears, 0/1/15 earrings, 16/17 hood horns, 13/14 hood, 3 back of the
# robe, 6/10 hem, 21/24 sleeves, 22/25 cuffs, 23/26 hands, 7/9/11/12 feet, 4/5 buttons), [3] 32x32 RGBA the eye quad.
# The handbag's black handle becomes a gold noose and the cane a hanging rope (paint only: the rigid parts hang off
# the skeleton and --deform does not reach them).  The eye quad is two quads that share
# their middle vertices; the left one is collapsed to nothing so the face has one eye, and the right one is moved to
# the middle of the face.

ROBE = hex_rgb("5a4478")
ROBE_DARK = hex_rgb("1c1428")
ROBE_LIGHT = hex_rgb("9a80bc")
ROPE = hex_rgb("c8a050")
ROPE_DARK = hex_rgb("4a3216")
BONE = hex_rgb("a8a088")


def _rags(p, n, seed, k=1.0):
    """Ragged shawl: long folds, stitched patches in two other tones, grime that settles low."""
    folds = fbm(p[0] * 0.55, p[1] * 0.2, p[2] * 0.55, seed, 3)
    c = mix(ROBE_DARK, shade(ROBE, 1.15 * k), clamp01(0.15 + 1.35 * folds))
    c = shade(c, 0.88 + 0.24 * vnoise(p[0] * 6, p[1] * 6, p[2] * 6, seed + 3))
    cx, cy, cz = math.floor(p[0] / 3.6), math.floor(p[1] / 3.0), math.floor(p[2] / 3.6)
    h = _hash3(cx, cy, cz, seed + 9)
    if h > 0.72:
        fx, fy, fz = p[0] / 3.6 - cx, p[1] / 3.0 - cy, p[2] / 3.6 - cz
        edge = min(fx, 1 - fx, fy, 1 - fy, fz, 1 - fz)
        if edge > 0.06:
            c = mix(c, ROBE_LIGHT if h > 0.86 else (40, 30, 24), 0.35)
            if edge < 0.14 and int(fx * 24 + fy * 24 + fz * 24) % 2 == 0:
                c = shade(c, 0.4)  # stitches
    return shade(c, 0.55 + 0.5 * clamp01(0.5 + 0.5 * n[1]))


def hangwoman_body(isl, p, n, x, y):
    ax = abs(p[0])
    if isl == 18:  # the face: a hole in the hood, a ghostly chin
        c = mix((9, 6, 14), (20, 12, 26), vnoise(p[0], p[1], p[2], 5))
        low = smooth((3.6 - p[1]) / 1.8)
        return mix(c, (176, 166, 160), low * 0.95 * (0.7 + 0.5 * vnoise(p[0] * 3, p[1] * 3, p[2] * 3, 6)))
    if isl in (19, 20):  # ears and jaw
        return shade((74, 66, 72), 0.7 + 0.6 * vnoise(p[0] * 3, p[1] * 3, p[2] * 3, 7))
    if isl in (0, 1, 15):  # tarnished earrings
        return shade((176, 130, 40), 0.55 + 0.7 * vnoise(p[0] * 4, p[1] * 4, p[2] * 4, 8))
    if isl in (16, 17):  # hood horns: dark, torn
        return shade((70, 42, 98), 0.4 + 0.9 * vnoise(p[0] * 2, p[1] * 2, p[2] * 2, 9))
    if isl in (4, 5):  # buttons
        return (190, 168, 110)
    if isl in (23, 26):  # hands: bone grey, dark knuckle lines
        c = shade(BONE, 0.6 + 0.6 * fbm(p[0] * 0.8, p[1] * 0.8, p[2] * 0.8, 21, 3))
        if abs(math.sin(ax * 2.2)) < 0.12:
            c = shade(c, 0.45)
        return c
    if isl in (22, 25):  # cuffs
        return shade(_rags(p, n, 31, 0.8), 0.7)
    if isl in (7, 9, 11, 12):  # boots
        return shade((38, 26, 20), 0.6 + 0.8 * vnoise(p[0] * 2, p[1] * 2, p[2] * 2, 41))
    if isl in (6, 10):  # hem: charcoal, ragged, mud-stained
        c = shade(_rags(p, n, 51, 0.7), 0.7)
        return mix(c, (30, 22, 16), 0.5 * smooth((-5.5 - p[1]) / 3.0 + 0.3 * vnoise(p[0] * 2, 0, p[2] * 2, 52)))
    c = _rags(p, n, 11, 1.0)
    if isl in (13, 14, 2):  # hood and collar: a little lighter on top so the silhouette reads
        c = mix(c, ROBE_LIGHT, 0.18 * clamp01((p[1] - 8.0) / 5.0))
    if isl in (13, 14) and p[2] > 0 and p[1] < 8.5:
        c = shade(c, 0.5)  # inside the hood
    return c


def hangwoman_eye(bake, geos):
    """32x32 RGBA: transparent border, a dark socket, an amber halo, a slit pupil.  The RGB under the transparent
    texels is the halo colour so mip-mapping and filtering do not fringe."""
    rows = [[(255, 200, 60, 0)] * 32 for _ in range(32)]
    for y in range(32):
        for x in range(32):
            d = math.hypot((x + 0.5 - 16) / 15.0, (y + 0.5 - 16) / 15.0)
            if d >= 1.0:
                continue
            fade = clamp01((1.0 - d) / 0.28)
            a_s = 0.85 * fade * smooth((d - 0.2) / 0.3 + 0.3)
            a_g = fade * smooth((0.62 - d) / 0.4)
            a = a_g + a_s * (1 - a_g)
            glow, sock = (255, 190, 40), (6, 4, 10)
            col = tuple((glow[k] * a_g + sock[k] * a_s * (1 - a_g)) / (a or 1) for k in range(3))
            rows[y][x] = (col[0], col[1], col[2], 255 * a)
    for y in range(32):
        for x in range(32):
            d = math.hypot((x + 0.5 - 16) / 11.0, (y + 0.5 - 16) / 11.0)
            r = rows[y][x]
            if d < 1.0:  # the iris
                t = clamp01((1.0 - d) / 0.25)
                c = mix((255, 170, 30), (255, 255, 215), clamp01(1.0 - d * 1.3))
                r = (r[0] + (c[0] - r[0]) * t, r[1] + (c[1] - r[1]) * t, r[2] + (c[2] - r[2]) * t, max(r[3], 255 * t))
            if abs(x + 0.5 - 16) < 1.1 and abs(y + 0.5 - 16) < 8.0:  # slit pupil
                r = (10, 4, 6, 255)
            rows[y][x] = r
    return rows


hangwoman_eye.whole = True


def hangwoman_bag(isl, p, n, x, y):
    ax = abs(p[0])
    if isl in (2, 4, 3, 5):  # the handle is now a noose: twisted gold rope
        t = math.atan2(p[1] + 4.2, ax + 0.001)
        tw = math.sin(t * 22 + p[2] * 3.0 + (p[0] > 0) * 1.7)
        c = mix(ROPE_DARK, ROPE, clamp01(0.5 + 0.55 * tw))
        return shade(c, 0.8 + 0.4 * vnoise(p[0] * 5, p[1] * 5, p[2] * 5, 3))
    if isl == 1:
        return (232, 192, 80)
    weave = 0.75 + 0.25 * math.sin(p[0] * 7) * math.sin(p[1] * 7 + 1.0)
    c = shade((66, 52, 40), weave * (0.6 + 0.8 * fbm(p[0] * 0.6, p[1] * 0.6, p[2] * 0.6, 9, 3)))
    c = mix(c, (92, 20, 24), 0.55 * smooth(vnoise(p[0] * 0.5, p[1] * 0.5, p[2] * 0.5, 4) * 2.2 - 1.0))  # stains
    if abs(p[1] + 5.8) < 0.3:
        c = (28, 22, 18)  # tied neck of the sack
    return shade(c, 0.5 + 0.5 * clamp01(0.5 + 0.5 * n[1]))


def hangwoman_stick(isl, p, n, x, y):
    ang = math.atan2(p[2], p[0])
    if isl == 2:  # the knot
        w = 0.5 + 0.5 * math.sin(p[1] * 12 + ang)
        return shade(mix(ROPE_DARK, ROPE, w), 0.9 + 0.2 * vnoise(p[0] * 6, p[1] * 6, p[2] * 6, 2))
    tw = math.sin(p[1] * 3.4 + ang * 2.0 + (1.5 if isl == 0 else 0.0))
    c = mix(ROPE_DARK, ROPE, clamp01(0.5 + 0.6 * tw))
    c = shade(c, 0.75 + 0.5 * vnoise(p[0] * 4, p[1] * 4, p[2] * 4, 6))
    if isl == 1 and p[1] < -11.8:
        c = mix(c, (140, 130, 110), 0.5)  # frayed end
    return c


HANGWOMAN_BODY = "*_oldwoman_shader"
HANGWOMAN_EYE = "*oldwomaneye_shader"
HANGWOMAN_DEFORM = {"ops": [
    # eyes: collapse the left quad onto the shared middle edge, move what is left to the middle and shrink it
    {"op": "region", "select": HANGWOMAN_EYE, "box": [[-5.0, 3, 2.5], [-4.0, 11, 5]], "falloff": 0,
     "then": [{"op": "translate", "t": [4.6, 0, 0.88]}]},
    {"op": "translate", "select": HANGWOMAN_EYE, "t": [-2.3, 0, 0.3]},
    {"op": "scale", "select": HANGWOMAN_EYE, "s": 1.8},
    # the hunch: bend the upper body (eyes included, they sit on the face) forward from the hips up
    {"op": "bend", "select": [HANGWOMAN_BODY, HANGWOMAN_EYE], "axis": "y", "dir": "z", "amount": 13, "length": 9,
     "about": [0, 1.0, 0]},
    # a taller, deeper hood and a swollen, ragged shawl at the back
    {"op": "region", "select": HANGWOMAN_BODY, "box": [[-7, 6.5, -6], [7, 15, 5]], "falloff": 2.0,
     "then": [{"op": "push", "dist": 0.9}]},
    {"op": "region", "select": HANGWOMAN_BODY, "box": [[-4, 11, -4], [4, 16, 3]], "falloff": 3.0,
     "then": [{"op": "translate", "t": [0, 2.0, -0.3]}]},
    {"op": "region", "select": HANGWOMAN_BODY, "box": [[-12, -9, -21], [12, 8, -6]], "falloff": 4.0,
     "then": [{"op": "push", "dist": 0.6}]},
    {"op": "region", "select": HANGWOMAN_BODY, "box": [[-25, -10, -22], [25, -5.5, 6]], "falloff": 1.5,
     "then": [{"op": "noise", "amp": 0.7, "freq": 0.55, "seed": 3}]},
]}


# ============================================================ build machinery

class Spec:
    def __init__(self, slug, vanilla, name, section, images, deform):
        """images: {k: (width, height, alpha, geometry_set_index, paint_fn, island_priorities)}; paint_fn(isl, pos, nrm, x, y) -> colour,
        or a callable taking (bake, geos) when it is a whole-image painter (see Spec.painter_kind)."""
        self.slug, self.vanilla, self.name, self.section = slug, vanilla, name, section
        self.images, self.deform = images, deform

    @property
    def resource(self):
        return "kindjal." + self.name


SPECS = {}


def spec(s):
    SPECS[s.slug] = s
    return s


spec(Spec("knifeman", "Scouser", "Knifeman", 509,
          {0: (256, 256, False, 0, knifeman_body, {})}, KNIFEMAN_DEFORM))
spec(Spec("hangwoman", "Oldwoman", "Hangwoman", 508,
          {0: (64, 64, False, 2, hangwoman_bag, {}), 1: (64, 64, False, 3, hangwoman_stick, {}),
           2: (128, 128, False, 0, hangwoman_body, {}), 3: (32, 32, True, 1, hangwoman_eye, {})}, HANGWOMAN_DEFORM))
spec(Spec("gorger", "Fatkins.Fatboy", "Gorger", 510,
          {0: (256, 256, False, 0, gorger_body, {0: 2})}, GORGER_DEFORM))


def build_one(sp, tool, out_xom, work, verbose=True):
    """Rebuild one bank into out_xom (work is a scratch directory)."""
    os.makedirs(work, exist_ok=True)
    van = os.path.join(work, sp.slug + ".van.xom")
    tool.clone(sp.vanilla, van, "kindjal.Tmp" + sp.name, sp.section)
    geos = tool.geometry(van)
    textures = {}
    for k, (w, h, alpha, si, fn, prio) in sorted(sp.images.items()):
        bake = Bake(geos[si], w, h, prio=prio)
        if getattr(fn, "whole", False):
            rows = fn(bake, geos)
        else:
            rows = bake.paint(fn, (0, 0, 0))
        path = os.path.join(work, "%s.tex%d.png" % (sp.slug, k))
        write_png(path, rows, w, h, alpha)
        textures[k] = path
    dpath = os.path.join(work, sp.slug + ".deform.json")
    with open(dpath, "w") as f:
        json.dump(sp.deform, f, indent=1, sort_keys=True)
    out = tool.clone(sp.vanilla, out_xom, sp.resource, sp.section, textures, dpath)
    if verbose:
        print(out.strip().splitlines()[-1])
    return textures


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--xomtool", default=DEFAULT_XOMTOOL)
    ap.add_argument("--bundl09", default=DEFAULT_BUNDL09)
    ap.add_argument("--out-dir", default=DEFAULT_OUT)
    ap.add_argument("--only", default="", help="comma separated slugs (default: all)")
    ap.add_argument("--check", action="store_true", help="rebuild into a temp dir and compare bytes with --out-dir")
    ap.add_argument("--keep", default="", help="also copy the painted PNGs and deform JSONs into this directory")
    a = ap.parse_args(argv)
    _paths.require_tools(a.xomtool, a.bundl09)
    slugs = [s for s in a.only.split(",") if s] or list(SPECS)
    _paths.require_slugs(slugs, SPECS)
    tool = Tool(a.xomtool, a.bundl09)
    bad = 0
    with tempfile.TemporaryDirectory() as tmp:
        for slug in slugs:
            sp = SPECS[slug]
            target = os.path.join(a.out_dir, sp.resource + ".xom")
            work = os.path.join(tmp, slug)
            if a.check:
                built = os.path.join(tmp, sp.resource + ".xom")
                build_one(sp, tool, built, work, verbose=False)
                same = os.path.exists(target) and open(built, "rb").read() == open(target, "rb").read()
                print("%-10s %s" % (slug, "identical" if same else "DIFFERS"))
                bad += 0 if same else 1
            else:
                os.makedirs(a.out_dir, exist_ok=True)
                build_one(sp, tool, target, work)
                if a.keep:
                    os.makedirs(a.keep, exist_ok=True)
                    for fn in os.listdir(work):
                        if fn.endswith((".png", ".json")):
                            shutil.copy(os.path.join(work, fn), a.keep)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
