#!/usr/bin/env python3
"""Kindjal clone banks, group "rigid props": vanilla animated props cloned with `xomtool clone` (skeleton, node names, clip
library and texture stages kept), reshaped with `--deform` and repainted with `--texture`.

    python clones_props.py                 write ../mod/assets/meshes/kindjal.<Name>.xom for every model below
    python clones_props.py --check         rebuild into a temp folder and compare byte for byte with the files on disk
    python clones_props.py --keep <dir>    also leave the deform scripts, painted PNGs and a deformed glTF per model in <dir>
    python clones_props.py --only dead_star,bear_trap

slug                vanilla mesh        resource                  section  look
nail_cluster        ClusterGrenade      kindjal.NailCluster       495      rusty gunmetal pineapple swollen into a ball, every
                                                                           other facet pulled out into a nail spike, nail heads
nail_cluster_piece  ClusterBomb         kindjal.NailClusterPiece  496      the hexagonal body rounded into a rusty ball with nail
                                                                           heads, three studs and a point underneath; the four
                                                                           flaps (clip 'spin') folded into short square steel
                                                                           nails pointing out of the upper ball: a spiked ball
bear_trap           Landmine            kindjal.BearTrap          497      a flat base plate with two long spring bars and a chain
                                                                           stub, a low jaw ring of two jaws (two big inward-leaning
                                                                           teeth each, hinged over the springs), the cap pressed
                                                                           down into a pressure plate; both 'MineOn' frames
                                                                           painted alike apart from the plate's centre light,
                                                                           which sits where the mine's blink was
carpet_shell        Airstrike.Payload   kindjal.CarpetShell       498      long slim charcoal bomb, pointed nose, big tail fins,
                                                                           one rusty band
dead_star           Starburst           kindjal.DeadStar          499      the firework rocket remapped onto a hot core with
                                                                           fourteen long black spikes; the rope helix becomes
                                                                           crust bands on the core, the stick and the fuse become
                                                                           two more spikes

How a model is made. The vanilla mesh is cloned once into a temp folder with --out-gltf to read its node tree, shape positions
(node-local, the coordinates --deform works in), UVs and triangles. A design function moves vertices in Python; the result is
written as a deform script of one exact `region` (a box a fraction of the vertex spacing wide, falloff 0) with a `translate`
per moved position, so xomtool applies exactly the designed shape and keeps vertex count, order, UVs and indices. Every
texture is painted at its vanilla size by rasterising the triangles in UV space and colouring each texel from where it lands on
the deformed model (height, distance from the core, spike weight, ...) plus value noise in texture space, then grown a few
texels past the island edges. Then the real clone runs with --deform and one --texture per image. Locator nodes the reshape
moves away from (Airstrike.Payload's smokelocator, Starburst's locator1 under the fuse) are then carried along by editing
their translation in the bank (unpack, set, pack; nothing else changes).

Stdlib only, fixed seeds, deterministic. Importing this module has no side effects.
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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # the helper sits beside this file
import _paths  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.normpath(os.path.join(HERE, "..", "mod", "assets", "meshes"))
DEFAULT_XOMTOOL = _paths.default_xomtool()
DEFAULT_BUNDL09 = _paths.default_bundl09()


# ---------------------------------------------------------------------------------------------------------------- vectors
def add(a, b): return (a[0] + b[0], a[1] + b[1], a[2] + b[2])
def sub(a, b): return (a[0] - b[0], a[1] - b[1], a[2] - b[2])
def mul(a, s): return (a[0] * s, a[1] * s, a[2] * s)
def dot(a, b): return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
def cross(a, b): return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])
def length(a): return math.sqrt(dot(a, a))


def unit(a):
    n = length(a)
    return (a[0] / n, a[1] / n, a[2] / n) if n > 1e-12 else (0.0, 1.0, 0.0)


def clamp(x, lo=0.0, hi=1.0): return lo if x < lo else hi if x > hi else x
def lerp(a, b, t): return a + (b - a) * t
def mix(c1, c2, t): return tuple(c1[k] + (c2[k] - c1[k]) * t for k in range(3))


def smooth(e0, e1, x):
    t = clamp((x - e0) / (e1 - e0)) if e1 != e0 else (1.0 if x >= e1 else 0.0)
    return t * t * (3 - 2 * t)


# ---------------------------------------------------------------------------------------------------------------- noise
def _hash(ix, iy, iz, seed):
    h = (ix * 73856093) ^ (iy * 19349663) ^ (iz * 83492791) ^ (seed * 2654435761)
    h &= 0xFFFFFFFF
    h ^= h >> 13
    h = (h * 1274126177) & 0xFFFFFFFF
    h ^= h >> 16
    return h / 4294967296.0


def vnoise(x, y, z=0.0, seed=0):
    """value noise in 0..1, smooth, a pure function of position and seed"""
    ix, iy, iz = math.floor(x), math.floor(y), math.floor(z)
    fx, fy, fz = x - ix, y - iy, z - iz
    fx, fy, fz = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy), fz * fz * (3 - 2 * fz)
    def h(a, b, c): return _hash(ix + a, iy + b, iz + c, seed)
    x00 = lerp(h(0, 0, 0), h(1, 0, 0), fx); x10 = lerp(h(0, 1, 0), h(1, 1, 0), fx)
    x01 = lerp(h(0, 0, 1), h(1, 0, 1), fx); x11 = lerp(h(0, 1, 1), h(1, 1, 1), fx)
    return lerp(lerp(x00, x10, fy), lerp(x01, x11, fy), fz)


def fbm(x, y, z=0.0, seed=0, octaves=4):
    s, a, tot = 0.0, 1.0, 0.0
    for o in range(octaves):
        s += a * vnoise(x, y, z, seed + 31 * o); tot += a
        x, y, z, a = x * 2.03, y * 2.03, z * 2.03, a * 0.5
    return s / tot


# ---------------------------------------------------------------------------------------------------------------- PNG
def write_png(path, rows):
    h, w = len(rows), len(rows[0])
    raw = bytearray()
    for r in rows:
        raw.append(0)
        for c in r:
            raw += bytes((int(clamp(c[0], 0, 255) + 0.5), int(clamp(c[1], 0, 255) + 0.5), int(clamp(c[2], 0, 255) + 0.5)))
    def chunk(t, b):
        c = t + b
        return struct.pack(">I", len(b)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


# ---------------------------------------------------------------------------------------------------------------- matrices
IDENT = (1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0)


def mat_mul(a, b):  # column-major 4x4
    return tuple(sum(a[k * 4 + r] * b[c * 4 + k] for k in range(4)) for c in range(4) for r in range(4))


def xform(m, p, w=1.0):
    return tuple(m[r] * p[0] + m[4 + r] * p[1] + m[8 + r] * p[2] + m[12 + r] * w for r in range(3))


def mat_inv(m):
    """inverse of an affine column-major 4x4"""
    a = [[m[c * 4 + r] for c in range(3)] for r in range(3)]
    det = (a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
           + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0]))
    inv = [[0.0] * 3 for _ in range(3)]
    for r in range(3):
        for c in range(3):
            r1, r2 = [i for i in range(3) if i != c]
            c1, c2 = [i for i in range(3) if i != r]
            cof = a[r1][c1] * a[r2][c2] - a[r1][c2] * a[r2][c1]
            inv[r][c] = (cof if (r + c) % 2 == 0 else -cof) / det
    t = (m[12], m[13], m[14])
    it = [-(inv[r][0] * t[0] + inv[r][1] * t[1] + inv[r][2] * t[2]) for r in range(3)]
    out = [0.0] * 16
    for c in range(3):
        for r in range(3):
            out[c * 4 + r] = inv[r][c]
    out[12], out[13], out[14], out[15] = it[0], it[1], it[2], 1.0
    return tuple(out)


# ---------------------------------------------------------------------------------------------------------------- geometry
class Shape:
    """one XShape as --out-gltf writes it: node-local positions, normals, uv0, triangles and the node's world matrix"""

    def __init__(self, name, pos, nrm, uv, tris, m):
        self.name, self.pos, self.nrm, self.uv, self.tris, self.M = name, pos, nrm, uv, tris, m
        self.Minv = mat_inv(m)
        self.wpos = [xform(m, p) for p in pos]
        self.wnrm = [unit(xform(m, n, 0.0)) for n in nrm]
        self.uvs_at = {}  # position -> every uv drawn there (a position on a uv seam has several)
        for p, t in zip(pos, uv):
            self.uvs_at.setdefault(p, []).append(t)

    def to_local(self, w):
        return xform(self.Minv, w)


def read_gltf(path):
    with open(path) as f:
        g = json.load(f)
    with open(os.path.join(os.path.dirname(path), g["buffers"][0]["uri"]), "rb") as f:
        b = f.read()

    def acc(i, n):
        a = g["accessors"][i]; v = g["bufferViews"][a["bufferView"]]
        fmt = {5126: "f", 5125: "I", 5123: "H"}[a["componentType"]]
        vals = struct.unpack_from("<" + fmt * (a["count"] * n), b, v.get("byteOffset", 0) + a.get("byteOffset", 0))
        return [tuple(vals[k:k + n]) for k in range(0, len(vals), n)]

    shapes = []

    def walk(ni, parent):
        n = g["nodes"][ni]
        m = mat_mul(parent, tuple(n["matrix"])) if "matrix" in n else parent
        if "mesh" in n:
            me = g["meshes"][n["mesh"]]
            pr = me["primitives"][0]; at = pr["attributes"]
            idx = [i[0] for i in acc(pr["indices"], 1)]
            shapes.append(Shape(me["name"], acc(at["POSITION"], 3), acc(at["NORMAL"], 3), acc(at["TEXCOORD_0"], 2),
                                [tuple(idx[i:i + 3]) for i in range(0, len(idx), 3)], m))
        for c in n.get("children", []):
            walk(c, m)

    for r in g["scenes"][g.get("scene", 0)]["nodes"]:
        walk(r, IDENT)
    return {s.name: s for s in shapes}


# ---------------------------------------------------------------------------------------------------------------- deform
def deform_script(shapes, newpos):
    """One exact region + translate per moved distinct position. Shapes with identical vanilla and designed positions (a
    coordinate array two shapes draw, like the Landmine's two texture stages) go in one op so their array moves once."""
    groups = []  # (names, shape, new)
    for name, shp in shapes.items():
        if name not in newpos:
            continue
        new = newpos[name]
        for gr in groups:
            if gr[1].pos == shp.pos and gr[2] == new:
                gr[0].append(name)
                break
        else:
            groups.append(([name], shp, new))
    ops = []
    for names, shp, new in groups:
        target = {}
        for p, q in zip(shp.pos, new):
            if p in target and target[p] != q:
                raise ValueError("%s: two vertices at %r were given different positions" % (shp.name, p))
            target[p] = q
        uniq = sorted(target)
        mind = 1e9  # Chebyshev spacing between distinct positions: the box must catch exactly one
        for i, a in enumerate(uniq):
            for bb in uniq[i + 1:]:
                d = max(abs(a[0] - bb[0]), abs(a[1] - bb[1]), abs(a[2] - bb[2]))
                if d < mind:
                    mind = d
        eps = min(1e-3, 0.4 * mind)
        if eps <= 1e-6:
            raise ValueError("%s: positions too close for an exact region (%g)" % (shp.name, mind))
        sel = names[0] if len(names) == 1 else names
        for p in uniq:
            t = sub(target[p], p)
            if max(abs(t[0]), abs(t[1]), abs(t[2])) < 1e-6:
                continue
            ops.append({"op": "region", "select": sel,
                        "box": [[p[0] - eps, p[1] - eps, p[2] - eps], [p[0] + eps, p[1] + eps, p[2] + eps]],
                        "falloff": 0, "then": [{"op": "translate", "t": [t[0], t[1], t[2]]}]})
    return {"ops": ops}


def map_world(shp, fn):
    """new local positions from a function of the vanilla world position (and the shape)"""
    return [shp.to_local(fn(w)) for w in shp.wpos]


# ---------------------------------------------------------------------------------------------------------------- painting
class Sample:
    __slots__ = ("shape", "p", "p0", "n", "u", "v", "tu", "tv", "x", "y", "w", "h", "attr")


def paint_image(width, height, shapes, newworld, attrs, painter, prio=None, grow=4, fill=(30, 30, 32)):
    """Rasterise every triangle of `shapes` (uv space, row y = (1 - v) * height) and colour each texel centre with
    painter(Sample). newworld[name] = deformed world positions, attrs[name] = {key: per-vertex floats} interpolated into
    Sample.attr. Where uv islands overlap, the sample with the higher prio(Sample) wins (default: the last one drawn).
    Uncovered texels take the average of covered neighbours for `grow` passes, then `fill`."""
    img = [[None] * width for _ in range(height)]
    best = [[None] * width for _ in range(height)]
    for shp in shapes:
        P, P0, A = newworld[shp.name], shp.wpos, attrs.get(shp.name, {})
        keys = sorted(A)
        for tri in shp.tris:
            a, b, c = tri
            fn = cross(sub(P[b], P[a]), sub(P[c], P[a]))
            n0 = add(add(shp.wnrm[a], shp.wnrm[b]), shp.wnrm[c])
            if length(fn) < 1e-12:
                fn = n0
            elif dot(fn, n0) < 0:
                fn = mul(fn, -1.0)
            fn = unit(fn)
            uvs = [shp.uv[a], shp.uv[b], shp.uv[c]]
            ou = math.floor((uvs[0][0] + uvs[1][0] + uvs[2][0]) / 3.0)
            ov = math.floor((uvs[0][1] + uvs[1][1] + uvs[2][1]) / 3.0)
            T = [((t[0] - ou) * width, (1.0 - (t[1] - ov)) * height) for t in uvs]
            area = (T[1][0] - T[0][0]) * (T[2][1] - T[0][1]) - (T[1][1] - T[0][1]) * (T[2][0] - T[0][0])
            if abs(area) < 1e-12:
                continue
            x0 = max(0, int(math.floor(min(t[0] for t in T)))); x1 = min(width - 1, int(math.ceil(max(t[0] for t in T))))
            y0 = max(0, int(math.floor(min(t[1] for t in T)))); y1 = min(height - 1, int(math.ceil(max(t[1] for t in T))))
            for y in range(y0, y1 + 1):
                for x in range(x0, x1 + 1):
                    px, py = x + 0.5, y + 0.5
                    w0 = ((T[1][0] - px) * (T[2][1] - py) - (T[1][1] - py) * (T[2][0] - px)) / area
                    w1 = ((T[2][0] - px) * (T[0][1] - py) - (T[2][1] - py) * (T[0][0] - px)) / area
                    w2 = 1.0 - w0 - w1
                    if w0 < -0.02 or w1 < -0.02 or w2 < -0.02:
                        continue
                    s = Sample()
                    s.shape = shp.name
                    s.p = add(add(mul(P[a], w0), mul(P[b], w1)), mul(P[c], w2))
                    s.p0 = add(add(mul(P0[a], w0), mul(P0[b], w1)), mul(P0[c], w2))
                    s.n = fn
                    s.x, s.y, s.w, s.h = x, y, width, height
                    s.u, s.v = px / width, 1.0 - py / height
                    rawu = uvs[0][0] * w0 + uvs[1][0] * w1 + uvs[2][0] * w2
                    rawv = uvs[0][1] * w0 + uvs[1][1] * w1 + uvs[2][1] * w2
                    s.tu, s.tv = rawu - ou, rawv - ov
                    s.attr = {k: A[k][a] * w0 + A[k][b] * w1 + A[k][c] * w2 for k in keys}
                    if prio is not None:
                        pr = prio(s)
                        if best[y][x] is not None and pr < best[y][x]:
                            continue
                        best[y][x] = pr
                    img[y][x] = painter(s)
    for _ in range(grow):
        nxt = [row[:] for row in img]
        for y in range(height):
            for x in range(width):
                if img[y][x] is not None:
                    continue
                acc, n = [0.0, 0.0, 0.0], 0
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        yy, xx = y + dy, x + dx
                        if 0 <= yy < height and 0 <= xx < width and img[yy][xx] is not None:
                            c = img[yy][xx]; acc[0] += c[0]; acc[1] += c[1]; acc[2] += c[2]; n += 1
                if n:
                    nxt[y][x] = (acc[0] / n, acc[1] / n, acc[2] / n)
        img = nxt
    return [[c if c is not None else fill for c in row] for row in img]


def grit(s, scale=1.0, seed=0):
    """texture-space value noise 0..1 (texture space, so uv islands that overlap or mirror stay consistent)"""
    return fbm(s.u * 9.0 * scale, s.v * 9.0 * scale, 0.0, seed, 4)


def speck(s, seed, density):
    """single-texel specks"""
    return _hash(s.x, s.y, 7, seed) < density


def shade(col, k):
    return (col[0] * k, col[1] * k, col[2] * k)


# palette: dark, gritty, high value contrast, rust orange as the accent
INK = (14, 13, 14)
CHAR = (34, 33, 35)
GUNMETAL = (66, 70, 76)
GUN_HI = (118, 124, 132)
STEEL = (150, 156, 162)
STEEL_HI = (222, 226, 228)
RUST_D = (82, 36, 16)
RUST = (150, 64, 22)
RUST_HI = (214, 110, 40)
HOT = (255, 116, 24)
HOT_HI = (255, 214, 110)
RED = (214, 26, 18)


def rusty(base, s, amount, seed=1):
    """grimy metal: tone noise, rust blotches and specks, in texture space"""
    g = grit(s, 1.0, seed)
    col = shade(base, 0.82 + 0.36 * g)
    r = fbm(s.u * 5.0, s.v * 5.0, 1.7, seed + 11, 4)
    rr = smooth(0.62 - 0.22 * amount, 0.75 - 0.2 * amount, r)
    col = mix(col, mix(RUST_D, RUST, g), rr * clamp(amount * 1.4))
    if speck(s, seed + 3, 0.05 * amount):
        col = mix(col, RUST_HI, 0.7)
    if speck(s, seed + 5, 0.04):
        col = shade(col, 0.6)
    return col


# ---------------------------------------------------------------------------------------------------------------- models
class Model:
    def __init__(self, slug, vanilla, name, section, design, painters, nodes=None):
        self.slug, self.vanilla, self.name, self.section = slug, vanilla, name, section
        self.design, self.painters = design, painters  # design(shapes) -> (newpos local, attrs); painters {k: fn}
        self.prio = None  # optional prio(Sample) for overlapping uv islands
        # locator nodes to carry along with the reshape: {node name: fn(shapes, newpos, vanilla translate) -> translate}
        self.nodes = nodes or {}


def carry_with(shape_name):
    """a locator node that is a child of the node `shape_name` sits in: moved by the displacement of the shape's vertex
    nearest to it (in that node's frame, which is the shape's local frame)"""
    def fn(shapes, newpos, t):
        shp = shapes[shape_name]
        i = min(range(len(shp.pos)), key=lambda k: length(sub(shp.pos[k], t)))
        return add(t, sub(newpos[shape_name][i], shp.pos[i]))
    return fn


# ---- nail_cluster: ClusterGrenade --------------------------------------------------------------------------------------
NC_CENTRE = (0.0, -2.45, 0.0)
NC_SCALE = 1.2
NC_SPIKE = 3.9


def nc_design(shapes):
    body = shapes["clustergrenadeShape_bottom_shader"]
    top = shapes["clustergrenadeShape_top_shader"]
    c = NC_CENTRE

    def swell(w, k=1.0):
        return add(c, mul(sub(w, c), 1.0 + (NC_SCALE - 1.0) * k))

    # body: every facet is 9 vertices (4 outer corners, 4 inner corners, a centre); tile (iu, iv) = floor of its uv
    tile_of, kind = {}, {}
    for p, uvs in body.uvs_at.items():
        u, v = uvs[0]
        fu, fv = u - math.floor(u), v - math.floor(v)
        if abs(fu - 0.5) < 0.05 and abs(fv - 0.5) < 0.05:
            kind[p] = "centre"; tile_of[p] = (math.floor(u), math.floor(v))
        elif 0.1 < fu < 0.9 and 0.1 < fv < 0.9:
            kind[p] = "inner"; tile_of[p] = (math.floor(u), math.floor(v))
        else:
            kind[p] = "outer"
    centres = {tile_of[p]: p for p in kind if kind[p] == "centre"}

    def spiked(t):
        return (t[0] + t[1]) % 2 == 0

    new, spike = [], []
    for p, w in zip(body.pos, body.wpos):
        k = kind[p]
        q = swell(w)
        dent = (fbm(w[0] * 0.5, w[1] * 0.5, w[2] * 0.5, 41) - 0.5) * 0.5
        q = add(q, mul(unit(sub(w, c)), dent))
        sp = 0.0
        if k != "outer" and spiked(tile_of[p]):
            cw = swell(body.wpos[body.pos.index(centres[tile_of[p]])])
            if k == "centre":
                q = add(cw, mul(unit(sub(cw, c)), NC_SPIKE))
                sp = 1.0
            else:  # pull the spike's base corners in: a slender nail, not a pyramid
                q = add(cw, mul(sub(q, cw), 0.6))
        new.append(body.to_local(q))
        spike.append(sp)
    out = {body.name: new}

    def top_fn(w):
        k = 1.0 - smooth(0.6, 2.6, w[1])  # the plug and the lower spoon follow the swollen body, the neck and lever do not
        return swell(w, k)
    out[top.name] = map_world(top, top_fn)
    return out, {body.name: {"spike": spike}}


def nc_paint_top(s):
    p = s.p
    if s.shape.startswith("pinring") or s.shape.startswith("pinShape"):
        col = rusty(mix(RUST, RUST_HI, 0.35), s, 0.3, 5)  # the pin and ring: the icon's orange accent
        return shade(col, 0.75 + 0.45 * clamp(s.n[1] * 0.5 + 0.5))
    r = math.hypot(p[0], p[2])
    if p[1] < -4.0:  # bottom plug
        return rusty(CHAR, s, 0.4, 7)
    if r < 3.1 and p[1] > 1.5:  # neck and fuse head: dark with a rust collar
        col = rusty(GUNMETAL, s, 0.5, 9)
        if 2.3 < p[1] < 3.0:
            col = mix(col, RUST_HI, 0.55)
        return col
    col = rusty(GUN_HI if s.n[1] > 0.4 else GUNMETAL, s, 0.55, 13)  # spoon/lever
    if speck(s, 21, 0.02):
        col = STEEL_HI
    return col


def nc_paint_body(s):
    """one 32x32 tile drawn on all 32 facets: rusty plate, dark bevel, steel nail (spike faces / flat nail head) in the
    middle"""
    tu, tv = s.tu, s.tv
    d = max(abs(tu - 0.5), abs(tv - 0.5))
    g = grit(s, 1.6, 3)
    if d > 0.31:  # bevel
        col = mix(CHAR, RUST_D, smooth(0.45, 0.7, g))
        if tv > 0.81 or tu < 0.19:
            col = mix(col, RUST, 0.45)  # lit edge
        return col
    rr = math.hypot(tu - 0.5, tv - 0.5)
    if rr < 0.12:
        return mix(STEEL_HI, STEEL, rr / 0.12)
    if rr < 0.16:
        return INK
    base = mix(GUNMETAL, GUN_HI, clamp((0.31 - d) / 0.31) * 0.7)
    col = mix(base, RUST, smooth(0.6, 0.78, g) * 0.75)
    if speck(s, 9, 0.06):
        col = RUST_HI
    return col


# ---- nail_cluster_piece: ClusterBomb -------------------------------------------------------------------------------------
NCP_C = (0.0, -0.1, 0.0)  # ball centre (body-local)
NCP_R = 3.4               # ball radius
NCP_STUDS = (60.0, 180.0, 300.0)  # body-local azimuths of the lower ring's vertices pulled out into studs
NCP_STUD = 1.5            # stud tip distance, in ball radii
NCP_NAIL_ELEV = 22.0      # the four flap nails point out of the upper ball this far above the horizontal
NCP_NAIL = (-1.7, 0.3, 4.9)  # nail root (inside the ball), collar and point, along the nail from the ball's surface
NCP_NAIL_HW = 0.5         # half width of the nail's square collar


def ncp_design(shapes):
    """20 body positions are too few for real spikes (a pulled vertex drags a third of the ball), so the ball gets three broad
    studs on its lower ring and a point underneath, and the spikes come from the four flaps: each 8-vertex petal (2 root, 4
    middle, 2 tip) becomes a short square nail with its point out, splayed radially around the upper ball. The flaps stay
    in their own nodes (clip 'spin' wiggles them +-10 degrees about their hinge), only their vertices move."""
    body = shapes["clusterShape_clustermain_shader"]
    cw = xform(body.M, NCP_C)
    out, attrs = {}, {}
    new, spike = [], []
    for p, w in zip(body.pos, body.wpos):
        d = unit(sub(w, cw))
        q, sp = add(cw, mul(d, NCP_R)), 0.0
        a = math.degrees(math.atan2(p[2], p[0])) % 360.0
        if -3.3 < p[1] < -2.7 and any(abs(((a - s) + 180.0) % 360.0 - 180.0) < 5.0 for s in NCP_STUDS):
            q, sp = add(cw, mul(d, NCP_R * NCP_STUD)), 1.0
        elif p[1] < -3.4:
            q, sp = add(cw, mul(d, NCP_R * 1.4)), 1.0
        new.append(body.to_local(q)); spike.append(sp)
    out[body.name] = new
    attrs[body.name] = {"spike": spike}

    up = (0.0, 1.0, 0.0)
    for name in ("flap1Shape_clusterwing_shader", "flap2Shape_clusterwing_shader",
                 "flap3Shape_clusterwing_shader", "flap4Shape_clusterwing_shader"):
        f = shapes[name]
        # the petal's own frame (local): A root -> tip, W across the root pair, T = W x A (A x T = W, right handed)
        order = sorted(range(len(f.pos)), key=lambda i: length(f.pos[i]))
        roots = sorted(set(f.pos[i] for i in order[:2]))
        rm = mul(add(roots[0], roots[1]), 0.5)
        far = sorted(set(f.pos), key=lambda p: -length(sub(p, rm)))[:2]
        A = unit(sub(mul(add(far[0], far[1]), 0.5), rm))
        W = sub(roots[1], roots[0]); W = unit(sub(W, mul(A, dot(W, A))))
        T = cross(W, A)
        # the nail's frame (world), right handed the same way, so the winding still faces out
        o = xform(f.M, (0.0, 0.0, 0.0))
        az = math.atan2(o[2] - cw[2], o[0] - cw[0])
        el = math.radians(NCP_NAIL_ELEV)
        A2 = (math.cos(el) * math.cos(az), math.sin(el), math.cos(el) * math.sin(az))
        W2 = unit(cross(up, A2))
        T2 = cross(W2, A2)
        base = add(cw, mul(A2, NCP_R))
        nw = []
        for p in f.pos:
            v = sub(p, rm)
            a, t, w = dot(v, A), dot(v, T), dot(v, W)
            if p in roots:
                a2, t2, w2 = NCP_NAIL[0], 0.0, math.copysign(0.4, w)
            elif p in far:
                a2, t2, w2 = NCP_NAIL[2], 0.0, math.copysign(0.05, w)
            elif abs(t) > abs(w):  # inner / outer of the middle ring
                a2, t2, w2 = NCP_NAIL[1], math.copysign(NCP_NAIL_HW, t), 0.0
            else:  # the middle ring's two side corners
                a2, t2, w2 = NCP_NAIL[1], 0.0, math.copysign(NCP_NAIL_HW, w)
            q = add(add(add(base, mul(A2, a2)), mul(T2, t2)), mul(W2, w2))
            nw.append(f.to_local(q))
        out[name] = nw
    return out, attrs


def ncp_paint_body(s):
    """64x64: three facet columns (each drawn on two opposite sides) by two rows, plus the top and bottom fans. Rusty
    gunmetal, a steel nail head in every facet, the studs and the bottom point steel toward their tips"""
    sp = s.attr.get("spike", 0.0)
    col = rusty(GUNMETAL, s, 0.75, 31)
    if s.p[1] > 1.9:
        col = mix(col, CHAR, 0.35)
    # a nail head in the middle of each facet cell (cells: u .14-.38-.62-.86, v .25-.5-.75)
    cu = min((0.26, 0.50, 0.74), key=lambda c: abs(s.tu - c))
    cv = min((0.375, 0.625), key=lambda c: abs(s.tv - c))
    if 0.14 < s.tu < 0.86 and 0.25 < s.tv < 0.75 and sp < 0.2:
        rr = math.hypot((s.tu - cu) * s.w, (s.tv - cv) * s.h)
        if rr < 2.1:
            return mix(STEEL_HI, STEEL, rr / 2.1)
        if rr < 3.1:
            return INK
    col = mix(col, STEEL, smooth(0.2, 0.7, sp))
    col = mix(col, STEEL_HI, smooth(0.8, 0.97, sp))
    if speck(s, 33, 0.012):
        col = STEEL_HI
    return col


def ncp_paint_flap(s):
    """32x32 shared by the four flaps: u across the petal, v from its root (0) through the middle ring (~0.57) to its
    point (1). The root half is inside the ball; the middle ring is the nail's collar, then a steel shank to a dark point"""
    u, v = s.tu, s.tv
    across = abs(u - 0.5) * 2.0
    if v < 0.5:
        return rusty(CHAR, s, 0.6, 43)
    if v < 0.64:  # collar: bright rim, dark seat
        return mix(STEEL_HI, GUN_HI, smooth(0.5, 0.64, v)) if v > 0.55 else INK
    col = mix(STEEL_HI, STEEL, smooth(0.0, 0.6, across))
    col = mix(col, GUNMETAL, smooth(0.6, 1.0, across))
    col = mix(col, RUST, smooth(0.66, 0.8, grit(s, 1.4, 41)) * 0.6)
    if v > 0.88:
        col = mix(col, CHAR, smooth(0.88, 0.98, v))  # dark point
    return col


# ---- bear_trap: Landmine ---------------------------------------------------------------------------------------------------
# The Landmine is 12 segments round: 7 dome rings (the green body, uv v 0.38..0.86), the dome's top ring (also the cap's
# edge), 4 cap rings and the cap centre (the red button), and a bottom centre. Its uvs repeat around the ring (the dome strip
# every 90 degrees, mirrored), so the paint is a function of height and radius, and a protrusion shares its texels with
# three plain stretches of wall. Designed (height, radius) per ring, the mine's small tilt kept as an offset:
BT_DOME = [(0.38, (-3.46, 5.9)), (0.42, (-3.25, 6.0)), (0.50, (-2.85, 5.8)), (0.56, (-2.6, 5.3)), (0.62, (-2.35, 5.0)),
           (0.75, (-1.7, 5.25)), (0.86, (-0.9, 5.2))]   # flat flared base plate, then the jaw's low outer wall
BT_CAP = [(0.14, (-1.0, 4.4)), (0.25, (-1.6, 4.2)), (0.31, (-2.0, 3.4)), (0.44, (-1.95, 2.1)), (0.61, (-1.9, 0.0))]
BT_TIP = (2.7, 3.5)     # tooth tip (height, radius) on the dome's top ring, every other vertex: leaning in, like jaws
BT_GAP = (-0.2, 5.0)    # the notch between two teeth
BT_HINGE = (-0.7, 5.2)  # the two top-ring vertices over the springs drop low: two jaws of two teeth each, hinged there
# two spring arms out of the base plate (dome rings 1 and 2 of two neighbouring columns each, opposite each other) and a
# chain stub along the ground (rings 0 and 1 of two columns a quarter turn round). Columns are the vertices' azimuths.
BT_ARMS = ((-2.0, 28.0), (-178.0, -148.0))
BT_ARM = (11.6, 0.75, -3.3, -2.75)   # end radius, half width, bottom and top height
BT_ARM_ROOT = (6.0, 1.7)             # the next column on each side (same rings) is drawn in to the arm's root: a bar, not a fan
BT_CHAIN = 89.0                      # the chain: dome ring 0 of one column pulled out along the ground, its two neighbours
BT_CHAIN_END = (9.9, -3.42)          # drawn in to its root, and ring 1 over it raised a little into a ridge
BT_CHAIN_ROOT = (5.9, 0.8)
BT_CHAIN_RIDGE = (7.0, -3.0)


def _angdiff(a, b):
    return abs((a - b + 180.0) % 360.0 - 180.0)


def bt_design(shapes):
    s1 = shapes["landmineShape_landmine_shader_1"]
    s2 = shapes["landmineShape_landmine_shader_2"]
    ring_y = {}
    for p, uvs in s1.uvs_at.items():
        ring_y.setdefault(_bt_ring(uvs), []).append(p[1])
    ring_y = {k: sum(v) / len(v) for k, v in ring_y.items()}

    def along(mid, side, r, off, y):
        """r out along azimuth `mid` (degrees), `off` to the side (+ toward larger azimuths), at height y"""
        m = math.radians(mid)
        d = (math.cos(m), math.sin(m)); e = (-d[1], d[0])
        return (d[0] * r + e[0] * off * side, y, d[1] * r + e[1] * off * side)

    new, tooth = [], []
    for p in s1.pos:
        x, y, z = p
        r = math.hypot(x, z)
        a = math.degrees(math.atan2(z, x))
        ring = _bt_ring(s1.uvs_at[p])
        q, tt = p, 0.0
        if ring == "centre":
            q = (x, BT_CAP[-1][1][0] + (y - ring_y[ring]), z)
        elif ring == "bottom":
            q = p
        elif ring == "teeth":
            k = int(round((a + 180.0) / 30.0)) % 12
            hy, hr = BT_HINGE if k in (0, 6) else BT_TIP if k % 2 == 0 else BT_GAP
            tt = 1.0 if k % 2 == 0 and k not in (0, 6) else 0.25
            q = (x / r * hr, hy + (y - ring_y[ring]), z / r * hr)
        elif ring[0] == "dome":
            i = ring[1]
            hy, hr = BT_DOME[i][1]
            q = (x / r * hr, hy + (y - ring_y[ring]), z / r * hr)
            for c0, c1 in BT_ARMS:
                mid = (c0 + c1) / 2.0
                if i in (1, 2):
                    yy = BT_ARM[3] if i == 2 else BT_ARM[2]
                    if _angdiff(a, c0) < 6.0 or _angdiff(a, c1) < 6.0:
                        q = along(mid, 1.0 if _angdiff(a, c1) < 6.0 else -1.0, BT_ARM[0], BT_ARM[1], yy)
                    elif _angdiff(a, c0 - 30.0) < 6.0 or _angdiff(a, c1 + 30.0) < 6.0:
                        q = along(mid, 1.0 if _angdiff(a, c1 + 30.0) < 6.0 else -1.0, BT_ARM_ROOT[0], BT_ARM_ROOT[1],
                                  hy + (y - ring_y[ring]))
            if i == 0 and _angdiff(a, BT_CHAIN) < 6.0:
                q = along(BT_CHAIN, 1.0, BT_CHAIN_END[0], 0.0, BT_CHAIN_END[1])
            elif i == 0 and (_angdiff(a, BT_CHAIN - 30.0) < 6.0 or _angdiff(a, BT_CHAIN + 30.0) < 6.0):
                q = along(BT_CHAIN, 1.0 if _angdiff(a, BT_CHAIN + 30.0) < 6.0 else -1.0, BT_CHAIN_ROOT[0], BT_CHAIN_ROOT[1],
                          hy + (y - ring_y[ring]))
            elif i == 1 and _angdiff(a, BT_CHAIN) < 6.0:
                q = along(BT_CHAIN, 1.0, BT_CHAIN_RIDGE[0], 0.0, BT_CHAIN_RIDGE[1])
        elif ring[0] == "cap":
            hy, hr = BT_CAP[ring[1]][1]
            q = (x / r * hr if r > 1e-6 else x, hy + (y - ring_y[ring]), z / r * hr if r > 1e-6 else z)
        new.append(q); tooth.append(tt)
    return {s1.name: new, s2.name: list(new)}, {s1.name: {"tooth": tooth}, s2.name: {"tooth": tooth}}


def _bt_ring(uvs):
    """which ring a vanilla Landmine position is on, from the uvs drawn there"""
    us = [t for t in uvs]
    dome = [t for t in us if t[1] > 0.25 and not (t[1] < 0.27 and abs(t[0] - 0.5) < 0.05)]
    capuv = [t for t in us if t[1] < 0.25]
    if any(abs(t[0] - 0.5) < 0.05 and abs(t[1] - 0.26) < 0.03 for t in us):
        return "bottom"  # the bottom centre
    if dome:
        v = dome[0][1]
        if v > 0.95:
            return "teeth"  # the dome's top ring, also the cap's edge
        best = min(range(len(BT_DOME)), key=lambda i: abs(BT_DOME[i][0] - v))
        return ("dome", best)
    u = capuv[0][0]
    if u > 0.55:
        return "centre"
    best = min(range(len(BT_CAP)), key=lambda i: abs(BT_CAP[i][0] - u))
    return ("cap", best)


def bt_prio(s):
    """the dome strip repeats round the ring: a texel a protrusion shares with plain wall is painted for the protrusion"""
    return math.hypot(s.p[0], s.p[2])


def _bt_paint(s, lit):
    p = s.p
    r = math.hypot(p[0], p[2])
    y = p[1]
    a = math.degrees(math.atan2(p[2], p[0]))
    g = grit(s, 1.3, 51)
    if r < 0.85 and -2.5 < y < 0.0:  # the light (where the Landmine's blink was): dim in frame 0, glaring in frame 1
        return mix(RED, HOT_HI, 1.0 - r / 0.85) if lit else mix((70, 12, 10), (120, 22, 16), 1.0 - r / 0.85)
    if r > 6.7:  # protrusions
        if _angdiff(a, BT_CHAIN) < 25.0:  # chain: links along the ground, alternately face-on and edge-on
            ph = (r - 6.7) / 0.62
            k = int(ph)
            f = ph - k
            if f < 0.14:
                return INK
            col = rusty(STEEL if k % 2 == 0 else GUN_HI, s, 0.5, 63)
            if k % 2 == 0 and 0.4 < f < 0.74:
                col = shade(col, 0.35)  # the hole of a face-on link
            return col
        if r < 8.6:  # spring coil where the arm leaves the plate
            ph = (r - 6.7) / 0.38
            return STEEL_HI if ph - int(ph) < 0.45 else mix(INK, RUST_D, g)
        col = rusty(GUNMETAL, s, 0.5, 65)  # the flat spring bar
        if s.n[1] > 0.6:
            col = mix(col, GUN_HI, 0.5)
        if r > 10.0:
            col = mix(col, RUST_HI, 0.5)  # worn end
        return col
    if r < 3.75 and -2.5 < y < -1.3 and s.n[1] > 0.5:  # pressure plate
        col = rusty(mix(CHAR, GUNMETAL, 0.6), s, 0.45, 53)
        ring = abs(r - 2.2)
        if ring < 0.2:
            col = INK
        elif ring < 0.4:
            col = mix(col, GUN_HI, 0.6)  # the plate's raised rim
        if lit:
            col = mix(col, RED, 0.35 * (1.0 - smooth(0.85, 2.6, r)))
        return col
    if y < -2.3:  # the flat base plate: dark rusty iron, its top face and lip catching the light, a few bolts
        col = rusty(CHAR, s, 0.85, 59)
        if s.n[1] > 0.6:
            col = mix(col, GUNMETAL, 0.5)
        if -2.95 < y < -2.7 and r > 5.9:
            col = mix(col, GUN_HI, 0.5)
        if speck(s, 61, 0.03):
            col = STEEL
        return col
    t = s.attr.get("tooth", 0.0)
    inner = r < 4.6 and y < -0.6
    if y > -0.6:  # the jaws and their teeth: steel getting brighter toward the points
        k = smooth(-0.6, 2.7, y)
        col = mix(GUN_HI, STEEL_HI, k * (0.5 + 0.5 * t))
        col = shade(col, 0.85 + 0.25 * g)
        if lit:
            col = mix(col, RED, 0.2 * (1.0 - k))
        return col
    if inner:  # inside of the jaw: dark, rusty, a dark gum line under the teeth
        col = rusty(CHAR, s, 0.7, 55)
        if y > -1.15:
            col = INK
        if lit:
            col = mix(col, RED, 0.3)
        return col
    col = rusty(mix(GUNMETAL, GUN_HI, 0.4), s, 0.5, 57)  # the jaws' outer wall, darker toward the plate
    return mix(col, CHAR, smooth(-1.4, -2.3, y) * 0.6)


def bt_paint0(s): return _bt_paint(s, False)
def bt_paint1(s): return _bt_paint(s, True)


# ---- carpet_shell: Airstrike.Payload ---------------------------------------------------------------------------------------
CS_K = 0.083            # the vanilla bomb's axis leans: x = CS_K * z
CS_PIVOT = -8.0
CS_STRETCH = 1.45
CS_SLIM = 0.66
CS_FIN = 1.22


def cs_axis(z): return (CS_K * z, 0.0)


def cs_tf(p, fin=False):
    """the shell's reshape of a point in the air_bomb node's frame (shapes and the smokelocator node alike)"""
    x, y, z = p
    ax, ay = cs_axis(z)
    rx, ry = x - ax, y - ay
    s = CS_PIVOT + (z - CS_PIVOT) * CS_STRETCH
    f = CS_FIN if fin else CS_SLIM
    if fin and z < -15:
        s -= 2.5  # rake the fins' trailing corners back
    rad = math.hypot(rx, ry)
    if z > 3.0 and rad < 0.5:
        s += 5.0  # a long point on the nose
    elif z > -1.0:
        f = 0.62
        s += 1.2
    nax, nay = cs_axis(s)
    return (nax + rx * f, nay + ry * f, s)


def cs_design(shapes):
    bomb = shapes["air_bombShape_lambert14"]
    cap = shapes["air_bombShape_lambert15"]
    out = {}

    def fin_only(p, shp):
        return shp is bomb and all(abs(t[0] - 0.88) < 0.02 for t in shp.uvs_at[p])

    def tf(p, shp):
        return cs_tf(p, fin_only(p, shp))

    out[bomb.name] = [tf(p, bomb) for p in bomb.pos]
    out[cap.name] = [tf(p, cap) for p in cap.pos]
    sv = [tf(p, bomb)[2] for p in bomb.pos]
    fin = [1.0 if fin_only(p, bomb) else 0.0 for p in bomb.pos]
    return out, {bomb.name: {"s": sv, "fin": fin}}


def cs_paint_bomb(s):
    z = s.p[2]
    fin = s.attr.get("fin", 0.0)
    g = grit(s, 1.2, 71)
    col = shade(mix(CHAR, GUNMETAL, 0.55), 0.8 + 0.4 * g)
    col = mix(col, GUN_HI, 0.5 * clamp(s.n[1]))  # a cold sheen on the upper side
    if fin > 0.5:
        col = mix(CHAR, GUNMETAL, 0.4 + 0.3 * g)
        return mix(col, RUST, smooth(0.6, 0.8, grit(s, 2.0, 73)) * 0.7)
    if -6.2 < z < -3.6:  # the rusty band
        col = mix(RUST, RUST_HI, g)
        if speck(s, 75, 0.15):
            col = RUST_D
    elif abs(z + 6.6) < 0.35 or abs(z + 3.2) < 0.35:
        col = INK
    if z > 5.0:
        col = mix(col, INK, 0.6)  # dark nose tip
    if speck(s, 77, 0.03):
        col = RUST
    return col


def cs_paint_cap(s):
    rr = math.hypot(s.tu - 0.5, s.tv - 0.5) * 2.0
    col = mix(INK, CHAR, smooth(0.2, 0.8, rr))
    if rr > 0.8:
        col = mix(RUST_D, RUST, grit(s, 2.0, 79))
    return col


# ---- dead_star: Starburst ----------------------------------------------------------------------------------------------------
DS_C = (0.0, 10.0, -14.31)  # centre of the core
DS_R = 6.3                  # core radius
DS_SPIKES = 14
DS_LEN = (15.0, 19.5)       # spike tip distance from the centre
DS_SEP = 30.0               # least angle between two spikes


def ds_dirs():
    """octahedron + cube directions, jittered with a fixed seed"""
    base = [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)]
    base += [(sx, sy, sz) for sx in (1, -1) for sy in (1, -1) for sz in (1, -1)]
    out = []
    for i, d in enumerate(base):
        j = (vnoise(i * 3.1, 0.5, 0.0, 91) - 0.5, vnoise(i * 3.1, 1.5, 0.0, 92) - 0.5, vnoise(i * 3.1, 2.5, 0.0, 93) - 0.5)
        out.append(unit(add(unit(d), mul(j, 0.45))))
    return out


def ds_design(shapes):
    body = shapes["Star_burstShape_lambert2"]
    fuse = shapes["fuseShape_lambert2"]
    ropes = shapes["ropesShape_lambert2"]
    C = DS_C
    out, attrs = {}, {}

    # ---- body: the rocket's tube and cone go onto the core sphere; the vertex nearest each spike direction becomes its tip
    def is_stick(w):  # the rocket's stick: four square rings below the tube
        return w[1] < 1.0
    uniq = sorted(set(body.wpos))
    near = {}  # position -> positions sharing a triangle with it
    for t in body.tris:
        for i in t:
            for j in t:
                if i != j:
                    near.setdefault(body.wpos[i], set()).add(body.wpos[j])
    tips = {}
    for i, d in enumerate(ds_dirs()):
        if d[1] < -0.8:
            continue  # the stick is the downward spike
        free = [w for w in uniq if not is_stick(w) and w not in tips and not (near[w] & set(tips))
                and all(dot(unit(sub(w, C)), unit(sub(o, C))) < math.cos(math.radians(DS_SEP)) for o in tips)]
        best = max(free, key=lambda w: dot(unit(sub(w, C)), d))
        L = DS_LEN[0] + (DS_LEN[1] - DS_LEN[0]) * vnoise(i * 1.7, 4.2, 0.0, 95)
        tips[best] = L
    stick_dir = unit((0.12, -1.0, 0.3))
    stick_top, stick_bot = 3.34, -11.79
    new, spike = [], []
    for w in body.wpos:
        if is_stick(w):
            t = clamp((stick_top - w[1]) / (stick_top - stick_bot))
            cen = (0.0, w[1], -10.08 + 0.0 * w[1])
            off = sub(w, cen)
            q = add(add(C, mul(stick_dir, DS_R * 0.85 + t * (19.0 - DS_R * 0.85))), mul(off, 0.9 * (1.0 - t)))
            sp = t
        else:
            d = unit(sub(w, C))
            if w in tips:
                L = tips[w]; q = add(C, mul(d, L)); sp = 1.0
            else:
                bump = (fbm(d[0] * 2.0, d[1] * 2.0, d[2] * 2.0, 97) - 0.5) * 0.9
                q = add(C, mul(d, DS_R + bump)); sp = 0.0
        new.append(body.to_local(q)); spike.append(sp)
    out[body.name] = new
    attrs[body.name] = {"spike": spike}

    # ---- ropes: the helix pulled onto the core as crust bands, keeping some of the rope's thickness
    rn = []
    for w in ropes.wpos:
        d = unit(sub(w, C))
        rc = math.hypot(w[0], w[2] - C[2])
        q = add(C, mul(d, DS_R + 0.35 + 0.45 * clamp(rc - 6.6, -1.2, 1.6)))
        rn.append(ropes.to_local(q))
    out[ropes.name] = rn

    # ---- fuse: the hanging fuse becomes a spike down and back (its node is still driven by FireStarburst)
    ys = [w[1] for w in fuse.wpos]
    ytop, ybot = max(ys), min(ys)
    bands = {}
    for w in fuse.wpos:
        bands.setdefault(round((w[1] - ybot) / (ytop - ybot) * 12), []).append(w)
    cen = {k: mul(tuple(sum(c[i] for c in v) for i in range(3)), 1.0 / len(v)) for k, v in bands.items()}
    fdir = unit((-0.55, -0.75, -0.45))
    fn_, fsp = [], []
    for w in fuse.wpos:
        t = clamp((ytop - w[1]) / (ytop - ybot))
        k = round((w[1] - ybot) / (ytop - ybot) * 12)
        off = sub(w, cen[k])
        q = add(add(C, mul(fdir, DS_R * 0.85 + t * (17.0 - DS_R * 0.85))), mul(off, 1.6 * (1.0 - t) ** 1.5))
        fn_.append(fuse.to_local(q)); fsp.append(t)
    out[fuse.name] = fn_
    attrs[fuse.name] = {"spike": fsp}
    return out, attrs


def ds_paint(s):
    d = length(sub(s.p, DS_C))
    g = grit(s, 1.5, 101)
    if s.shape.startswith("ropes"):  # crust bands: black with glowing edges
        col = shade(mix(INK, CHAR, g), 1.0)
        cr = abs(fbm(s.u * 14.0, s.v * 14.0, 3.0, 103) - 0.5)
        if cr < 0.05:
            col = mix(HOT, HOT_HI, 1.0 - cr / 0.05)
        return col
    t = clamp((d - DS_R) / (DS_LEN[1] - DS_R))
    if t < 0.07 and s.attr.get("spike", 0.0) < 0.05:  # the hot core
        return mix(HOT_HI, HOT, smooth(0.3, 0.9, g))
    col = mix(CHAR, INK, smooth(0.05, 0.5, t))
    col = shade(col, 0.8 + 0.4 * g)
    # cracks: hot near the core, fading toward the tips
    cr = abs(fbm(s.u * 11.0, s.v * 11.0, 5.0, 105) - 0.5)
    heat = 1.0 - smooth(0.05, 0.8, t)
    if cr < 0.02 + 0.025 * heat:
        col = mix(col, mix(RED, HOT, heat), 0.5 + 0.5 * heat)
    col = mix(col, HOT, 0.75 * (1.0 - smooth(0.0, 0.09, t)))  # glow where a spike leaves the core
    return col


def ds_prio(s):
    """a texel the core and a spike share is painted for the spike (a dark fleck on the core reads; a hot spike does not)"""
    return length(sub(s.p, DS_C)) + 10.0 * s.attr.get("spike", 0.0)


MODELS = [
    Model("nail_cluster", "ClusterGrenade", "kindjal.NailCluster", 495, nc_design, {0: nc_paint_top, 1: nc_paint_body}),
    Model("nail_cluster_piece", "ClusterBomb", "kindjal.NailClusterPiece", 496, ncp_design,
          {0: ncp_paint_body, 1: ncp_paint_flap}),
    Model("bear_trap", "Landmine", "kindjal.BearTrap", 497, bt_design, {0: bt_paint0, 1: bt_paint1}),
    Model("carpet_shell", "Airstrike.Payload", "kindjal.CarpetShell", 498, cs_design, {0: cs_paint_bomb, 1: cs_paint_cap},
          nodes={"smokelocator": lambda shapes, newpos, t: cs_tf(t)}),  # the smoke trail starts in the tail's recess
    Model("dead_star", "Starburst", "kindjal.DeadStar", 499, ds_design, {0: ds_paint},
          nodes={"locator1": carry_with("fuseShape_lambert2")}),  # under 'fuse': stays by the fuse's end, now its spike
]
MODELS[2].prio = bt_prio
MODELS[-1].prio = ds_prio


# ---------------------------------------------------------------------------------------------------------------- build
def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("xomtool failed (exit %d): %s\n%s" % (r.returncode, " ".join(cmd), (r.stderr or r.stdout).strip()))
    return r.stdout


def list_images(xomtool, bundl09, vanilla):
    """[(k, width, height, [shape names])] from clone --list-images"""
    out = []
    for line in run([xomtool, "clone", vanilla, "--from", bundl09, "--list-images"]).splitlines():
        m = re.match(r"\s*\[(\d+)\]\s+#\d+\s+\"[^\"]*\"\s+(\d+)x(\d+)\s+(\S+)\s+mips=\d+\s+used by:\s*(.*)$", line)
        if m:
            out.append((int(m.group(1)), int(m.group(2)), int(m.group(3)), [n.strip() for n in m.group(5).split(",")]))
    return out


def build_model(m, xomtool, bundl09, out_dir, work, keep=None):
    os.makedirs(work, exist_ok=True)
    probe = os.path.join(work, "vanilla.gltf")
    run([xomtool, "clone", m.vanilla, "--from", bundl09, "--bundle", os.path.join(work, "vanilla.xom"),
         "--as", m.name, "--section", str(m.section), "--out-gltf", probe])
    shapes = read_gltf(probe)
    newpos, attrs = m.design(shapes)
    for name in shapes:
        newpos.setdefault(name, list(shapes[name].pos))
    newworld = {n: [xform(shapes[n].M, p) for p in newpos[n]] for n in shapes}
    deform = os.path.join(work, "deform.json")
    with open(deform, "w") as f:
        json.dump(deform_script(shapes, newpos), f, separators=(",", ":"))
    cmd = [xomtool, "clone", m.vanilla, "--from", bundl09, "--bundle", os.path.join(out_dir, m.name + ".xom"),
           "--as", m.name, "--section", str(m.section), "--deform", deform]
    images = list_images(xomtool, bundl09, m.vanilla)
    if sorted(k for k, _, _, _ in images) != sorted(m.painters):
        sys.exit("%s: images %r but painters for %r" % (m.slug, [k for k, _, _, _ in images], sorted(m.painters)))
    for k, w, h, users in images:
        rows = paint_image(w, h, [shapes[u] for u in users], newworld, attrs, m.painters[k], m.prio)
        png = os.path.join(work, "tex%d.png" % k)
        write_png(png, rows)
        cmd += ["--texture", "%d=%s" % (k, png)]
    if keep:
        os.makedirs(keep, exist_ok=True)
        cmd += ["--out-gltf", os.path.join(keep, m.slug + ".gltf")]
    bank = os.path.join(out_dir, m.name + ".xom")
    run(cmd)
    if m.nodes:
        move_nodes(xomtool, bank, {n: (lambda t, f=f: f(shapes, newpos, t)) for n, f in m.nodes.items()}, work)
    if keep:
        shutil.copy(deform, os.path.join(keep, m.slug + ".deform.json"))
        for k, _, _, _ in images:
            shutil.copy(os.path.join(work, "tex%d.png" % k), os.path.join(keep, "%s.tex%d.png" % (m.slug, k)))
    return bank


def f32(x):
    return struct.unpack("<f", struct.pack("<f", x))[0]


def move_nodes(xomtool, bank, moves, work):
    """--deform moves vertices only, so a locator node (a group with a transform and no shape, which the game reads as an
    effect position) is moved here: unpack the bank, set the node's translation (XTransform.Translate and the matrix's
    translation row, or an XMatrix's) and its point bound, pack it back. moves = {node name: fn(vanilla translate) ->
    translate}. Nothing else in the bank changes (unpack -> pack is byte-exact)."""
    js = os.path.join(work, "nodes.json")
    run([xomtool, "unpack", bank, "-o", js])
    with open(js) as f:
        d = json.load(f)
    objs = d["objects"]
    for name, fn in sorted(moves.items()):
        groups = [o for o in objs if o["type"] == "XGroup" and o["fields"].get("Name") == name]
        if len(groups) != 1:
            sys.exit("%s: %d groups named %r" % (bank, len(groups), name))
        g = groups[0]["fields"]
        core = objs[g["Core"]["ref"] - 1]
        if core["type"] not in ("XTransform", "XMatrix"):
            sys.exit("%s: node %r has a %s, not a transform" % (bank, name, core["type"]))
        mat = core["fields"]["Matrix"]
        old = tuple(mat[9:12])
        new = [f32(v) for v in fn(old)]
        mat[9:12] = new
        if core["type"] == "XTransform":
            core["fields"]["Translate"] = list(new)
        b = g.get("Bounds")
        if b and b[3] < 0 and max(abs(b[k] - old[k]) for k in range(3)) < 1e-6:
            b[0:3] = new  # a locator's bound is its point
    with open(js, "w") as f:
        json.dump(d, f)
    run([xomtool, "pack", js, bank])


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--xomtool", default=DEFAULT_XOMTOOL)
    ap.add_argument("--bundl09", default=DEFAULT_BUNDL09)
    ap.add_argument("--check", action="store_true", help="rebuild into a temp folder and compare with the files on disk")
    ap.add_argument("--keep", help="also write deform scripts, textures and deformed glTFs here")
    ap.add_argument("--only", help="comma-separated slugs")
    a = ap.parse_args(argv)
    _paths.require_tools(a.xomtool, a.bundl09)
    models = MODELS
    if a.only:
        want = set(a.only.split(","))
        _paths.require_slugs(sorted(want), [m.slug for m in MODELS])
        models = [m for m in MODELS if m.slug in want]
    tmp = tempfile.mkdtemp(prefix="kj_clones_props_")
    try:
        bad = 0
        out_dir = os.path.join(tmp, "out") if a.check else OUT_DIR
        os.makedirs(out_dir, exist_ok=True)
        for m in models:
            path = build_model(m, a.xomtool, a.bundl09, out_dir, os.path.join(tmp, m.slug), a.keep)
            if a.check:
                disk = os.path.join(OUT_DIR, m.name + ".xom")
                with open(path, "rb") as f:
                    new = f.read()
                old = open(disk, "rb").read() if os.path.exists(disk) else None
                ok = old == new
                bad += not ok
                print("%-4s %s (%d bytes)%s" % ("ok" if ok else "DIFF", disk, len(new), "" if old is not None else " missing"))
            else:
                print("wrote %s (%d bytes)" % (path, os.path.getsize(path)))
        return 1 if bad else 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
