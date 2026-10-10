#!/usr/bin/env python3
"""Kindjal cloned models, group "guns and rigs": five animated vanilla meshes re-skinned and reshaped by CLONING them.

    python clones_guns.py                  rebuild every bank into ../mod/assets/meshes/
    python clones_guns.py --check          rebuild into a temp folder, compare byte for byte with the files on disk (exit 1 on a difference)
    python clones_guns.py --only slug      one model (slug, gibbet, harpoongun, harpoon, plaguebow)
    python clones_guns.py --preview DIR    also keep the deformed glTF and the painted PNGs of every model in DIR

    --xomtool PATH   xomtool.exe (needs `clone`)          --bundl09 PATH   the game's Data/Bundles/Bundl09.xom (read only)

Each model is a vanilla mesh cloned with `xomtool clone` so it keeps its skeleton / node tree, node names, clip library and
texture stages exactly; only the vertex positions (--deform: scale / push / region ops, same vertex count and order) and the
pixels of every texture (--texture) change. The textures are painted here from nothing: the module asks xomtool for the
deformed clone as glTF, reads the UV layout and the surface positions back, rasterises every triangle into its texture and
shades each texel with a procedural material chosen by shape, UV island and 3D position (so a stripe or a rivet row sits
where it should on the model). Stdlib only (subprocess, json, struct, zlib, math), fixed noise seeds, deterministic.
Importing this module has no side effects.

  slug       Shotgun                 kindjal.SlugGun      500   sawn-off, worn steel and dark wood, brass slug shells
  gibbet     SentryGun               kindjal.GibbetTurret 501   black iron gallows frame, grey-green turret box, ember muzzle
  harpoongun HomingMissile.Weapon    kindjal.HarpoonGun   502   dark steel launcher with a barbed head at the muzzle
  harpoon    HomingMissile.Payload   kindjal.Harpoon      503   barbed iron harpoon, rope-wrapped tail
  plaguebow  Bow                     kindjal.PlagueBow    504   black grip, bone limbs with green rot, skull charm
"""
import argparse
import json
import math
import os
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

# ----------------------------------------------------------------------------------------------------------------------
# small math helpers
# ----------------------------------------------------------------------------------------------------------------------


def clamp(x, a=0.0, b=1.0):
    return a if x < a else (b if x > b else x)


def smooth(a, b, x):
    t = clamp((x - a) / (b - a)) if b != a else (1.0 if x >= a else 0.0)
    return t * t * (3 - 2 * t)


def mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def mul(c, k):
    return (c[0] * k, c[1] * k, c[2] * k)


def hexc(s):
    s = s.lstrip("#")
    return (int(s[0:2], 16), int(s[2:4], 16), int(s[4:6], 16))


def _hash(ix, iy, iz, seed):
    n = (ix * 374761393 + iy * 668265263 + iz * 1103515245 + seed * 1274126177) & 0xFFFFFFFF
    n = ((n ^ (n >> 13)) * 1274126177) & 0xFFFFFFFF
    n ^= n >> 16
    return n / 4294967295.0


def vnoise(x, y, z, seed=0):
    """3D value noise in 0..1 (pure function of position and seed)."""
    ix, iy, iz = math.floor(x), math.floor(y), math.floor(z)
    fx, fy, fz = x - ix, y - iy, z - iz
    fx, fy, fz = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy), fz * fz * (3 - 2 * fz)
    h = _hash
    a = h(ix, iy, iz, seed) * (1 - fx) + h(ix + 1, iy, iz, seed) * fx
    b = h(ix, iy + 1, iz, seed) * (1 - fx) + h(ix + 1, iy + 1, iz, seed) * fx
    c = h(ix, iy, iz + 1, seed) * (1 - fx) + h(ix + 1, iy, iz + 1, seed) * fx
    d = h(ix, iy + 1, iz + 1, seed) * (1 - fx) + h(ix + 1, iy + 1, iz + 1, seed) * fx
    return (a * (1 - fy) + b * fy) * (1 - fz) + (c * (1 - fy) + d * fy) * fz


def fbm(x, y, z, seed=0, octaves=3):
    s, amp, tot = 0.0, 1.0, 0.0
    for o in range(octaves):
        s += amp * vnoise(x, y, z, seed + o * 17)
        tot += amp
        x, y, z, amp = x * 2.03, y * 2.03, z * 2.03, amp * 0.5
    return s / tot


# ----------------------------------------------------------------------------------------------------------------------
# glTF reader (what `xomtool clone --out-gltf` writes) and UV islands
# ----------------------------------------------------------------------------------------------------------------------


def read_gltf(path):
    """-> list of primitives {name, node, pos, nrm, uv (u, v-up as xomtool writes it: PNG row = (1 - v) * height), tris, islands, isl_of_tri}; positions are the shape's own."""
    g = json.loads(open(path, "r", encoding="utf-8").read())
    with open(os.path.splitext(path)[0] + ".bin", "rb") as f:
        buf = f.read()

    def acc(i, n):
        a = g["accessors"][i]
        v = g["bufferViews"][a["bufferView"]]
        fmt = {5126: "f", 5125: "I", 5123: "H"}[a["componentType"]]
        vals = struct.unpack_from("<" + fmt * (a["count"] * n), buf, v.get("byteOffset", 0) + a.get("byteOffset", 0))
        return [vals[k:k + n] for k in range(0, len(vals), n)]

    prims = []

    def walk(i):
        nd = g["nodes"][i]
        if "mesh" in nd:
            me = g["meshes"][nd["mesh"]]
            p = me["primitives"][0]
            at = p["attributes"]
            idx = [x[0] for x in acc(p["indices"], 1)]
            pr = dict(name=me["name"], node=nd["name"], pos=acc(at["POSITION"], 3), nrm=acc(at["NORMAL"], 3),
                      uv=acc(at["TEXCOORD_0"], 2), tris=[tuple(idx[k:k + 3]) for k in range(0, len(idx), 3)])
            _islands(pr)
            prims.append(pr)
        for c in nd.get("children", []):
            walk(c)

    for r in g["scenes"][g.get("scene", 0)]["nodes"]:
        walk(r)
    return prims


def _islands(pr):
    parent = list(range(len(pr["pos"])))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    for a, b, c in pr["tris"]:
        parent[find(a)] = find(b)
        parent[find(b)] = find(c)
    ids, of_tri, isl = {}, [], []
    for t in pr["tris"]:
        r = find(t[0])
        if r not in ids:
            ids[r] = len(isl)
            isl.append(dict(id=len(isl), tris=0, verts=set()))
        i = ids[r]
        of_tri.append(i)
        isl[i]["tris"] += 1
        isl[i]["verts"].update(t)
    for it in isl:
        vs = [pr["pos"][v] for v in it["verts"]]
        it["lo"] = tuple(min(p[k] for p in vs) for k in range(3))
        it["hi"] = tuple(max(p[k] for p in vs) for k in range(3))
        it["c"] = tuple((it["lo"][k] + it["hi"][k]) / 2 for k in range(3))
        us = [pr["uv"][v] for v in it["verts"]]
        it["uvlo"] = (min(u[0] for u in us), min(u[1] for u in us))
        it["uvhi"] = (max(u[0] for u in us), max(u[1] for u in us))
    pr["islands"], pr["isl_of_tri"] = isl, of_tri


# ----------------------------------------------------------------------------------------------------------------------
# canvas: rasterise UV triangles, shade each texel from a function of the surface point
# ----------------------------------------------------------------------------------------------------------------------


class Canvas:
    def __init__(self, w, h, base=(0, 0, 0)):
        self.w, self.h = w, h
        self.d = [list(base) for _ in range(w * h)]
        self.m = bytearray(w * h)

    def raster(self, prims, shader, wrap_limit=9, prio=None):
        """shader(prim, island, pos, nrm, x, y) -> (r, g, b) 0..255, called once per texel a triangle covers (x, y are texel coords).
        UVs outside 0..1 tile (the vanilla atlases use tiled planar UVs), so a triangle is written modulo the image size;
        triangles go in order of decreasing UV area, so the small unique islands land on top of the big stretched ones;
        prio(prim, island) -> int, when given, is sorted on first (a higher number is painted later, so wins a shared texel)."""
        w, h = self.w, self.h
        work = []
        for pi, pr in enumerate(prims):
            uv = pr["uv"]
            for ti, (a, b, c) in enumerate(pr["tris"]):
                # v is up in xomtool's glTF and in its uv-layout (PNG row y = (1 - v) * height), as in the other clone scripts
                A = (uv[a][0] * w, (1 - uv[a][1]) * h)
                B = (uv[b][0] * w, (1 - uv[b][1]) * h)
                C = (uv[c][0] * w, (1 - uv[c][1]) * h)
                area = (B[0] - A[0]) * (C[1] - A[1]) - (B[1] - A[1]) * (C[0] - A[0])
                if abs(area) < 1e-9:
                    continue
                work.append((-abs(area), pi, ti, A, B, C, area))
        pk = (lambda t: (prio(prims[t[1]], prims[t[1]]["islands"][prims[t[1]]["isl_of_tri"][t[2]]]), t[0], t[1], t[2])) if prio else (lambda t: (t[0], t[1], t[2]))
        work.sort(key=pk)
        for _, pi, ti, A, B, C, area in work:
            pr = prims[pi]
            a, b, c = pr["tris"][ti]
            pos, nrm = pr["pos"], pr["nrm"]
            isl = pr["islands"][pr["isl_of_tri"][ti]]
            y0, y1 = int(math.floor(min(A[1], B[1], C[1]))), int(math.ceil(max(A[1], B[1], C[1])))
            x0, x1 = int(math.floor(min(A[0], B[0], C[0]))), int(math.ceil(max(A[0], B[0], C[0])))
            if (x1 - x0 + 1) > wrap_limit * w or (y1 - y0 + 1) > wrap_limit * h:
                continue
            for y in range(y0, y1 + 1):
                for x in range(x0, x1 + 1):
                    px, py = x + 0.5, y + 0.5
                    w0 = ((B[0] - px) * (C[1] - py) - (B[1] - py) * (C[0] - px)) / area
                    w1 = ((C[0] - px) * (A[1] - py) - (C[1] - py) * (A[0] - px)) / area
                    w2 = 1 - w0 - w1
                    if w0 < -0.02 or w1 < -0.02 or w2 < -0.02:
                        continue
                    P = tuple(w0 * pos[a][k] + w1 * pos[b][k] + w2 * pos[c][k] for k in range(3))
                    N = tuple(w0 * nrm[a][k] + w1 * nrm[b][k] + w2 * nrm[c][k] for k in range(3))
                    nl = math.sqrt(N[0] * N[0] + N[1] * N[1] + N[2] * N[2]) or 1.0
                    xm, ym = x % w, y % h
                    self.d[ym * w + xm] = list(shader(pr, isl, P, (N[0] / nl, N[1] / nl, N[2] / nl), xm, ym))
                    self.m[ym * w + xm] = 1

    def dilate(self, passes=3, base=(40, 40, 44)):
        """Spread painted texels into unpainted neighbours (seam bleed for the mip chain, wrapping at the edges);
        anything still unpainted gets `base`."""
        w, h = self.w, self.h
        for _ in range(passes):
            new = bytearray(self.m)
            for y in range(h):
                for x in range(w):
                    i = y * w + x
                    if self.m[i]:
                        continue
                    acc, n = [0, 0, 0], 0
                    for dy in (-1, 0, 1):
                        for dx in (-1, 0, 1):
                            j = ((y + dy) % h) * w + (x + dx) % w
                            if self.m[j]:
                                c = self.d[j]
                                acc[0] += c[0]
                                acc[1] += c[1]
                                acc[2] += c[2]
                                n += 1
                    if n:
                        self.d[i] = [acc[0] / n, acc[1] / n, acc[2] / n]
                        new[i] = 1
            self.m = new
        for i in range(w * h):
            if not self.m[i]:
                self.d[i] = list(base)

    def put(self, x, y, c, a=1.0):
        if 0 <= x < self.w and 0 <= y < self.h:
            o = self.d[y * self.w + x]
            self.d[y * self.w + x] = [o[0] + (c[0] - o[0]) * a, o[1] + (c[1] - o[1]) * a, o[2] + (c[2] - o[2]) * a]

    def rect(self, x0, y0, x1, y1, c, a=1.0):
        for y in range(int(y0), int(y1) + 1):
            for x in range(int(x0), int(x1) + 1):
                self.put(x, y, c, a)

    def disc(self, cx, cy, r, c, a=1.0):
        for y in range(int(cy - r - 1), int(cy + r + 2)):
            for x in range(int(cx - r - 1), int(cx + r + 2)):
                d = math.hypot(x + 0.5 - cx, y + 0.5 - cy)
                if d <= r:
                    self.put(x, y, c, a * clamp(r - d + 0.5))

    def curve(self, gain=1.0, sat=1.0):
        """final contrast / saturation curve (the game's lighting flattens a texture)."""
        for i, c in enumerate(self.d):
            l = 0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2]
            self.d[i] = [128 + (l + (c[k] - l) * sat - 128) * gain for k in range(3)]

    def png(self):
        raw = bytearray()
        for y in range(self.h):
            raw.append(0)
            for x in range(self.w):
                c = self.d[y * self.w + x]
                raw += bytes((max(0, min(255, int(c[0] + 0.5))), max(0, min(255, int(c[1] + 0.5))), max(0, min(255, int(c[2] + 0.5)))))

        def chunk(t, b):
            c = t + b
            return struct.pack(">I", len(b)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

        return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", self.w, self.h, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


# ----------------------------------------------------------------------------------------------------------------------
# models (filled in below)
# ----------------------------------------------------------------------------------------------------------------------

MODELS = {}

# shared palette: dark and gritty, strong value contrast
STEEL_D, STEEL_M, STEEL_L = (22, 25, 30), (78, 86, 90), (168, 176, 176)
WOOD_D, WOOD_M, WOOD_L = (34, 18, 11), (88, 50, 28), (146, 92, 50)
BRASS, BRASS_D = (236, 178, 48), (118, 78, 16)
RUST = (178, 80, 28)
IRON_D, IRON_M = (16, 14, 20), (52, 46, 60)       # violet-black iron
EMBER, EMBER_D = (255, 130, 28), (150, 40, 12)
BONE, BONE_D = (226, 218, 188), (120, 108, 82)
ROT = (112, 220, 34)


def steel(P, seed, base=STEEL_M, rust=0.4, scale=2.2, streak=0.7):
    """worn gunmetal: brushed streaks (stretched along z), pitting, rust patches."""
    n = fbm(P[0] * scale, P[1] * scale, P[2] * scale * streak, seed, 3)
    c = mix(STEEL_D, base, 0.2 + 0.95 * n)
    sp = vnoise(P[0] * 11, P[1] * 11, P[2] * 11, seed + 3)
    if sp > 0.8:
        c = mix(c, STEEL_L, 0.55)
    rv = fbm(P[0] * 0.8 + 3, P[1] * 0.8, P[2] * 0.5, seed + 9, 3)
    return mix(c, RUST, smooth(0.58, 0.72, rv) * rust)


def wood(P, seed, axis=2, dark=WOOD_D, mid=WOOD_M, light=WOOD_L):
    """stained wood, grain stretched along `axis`."""
    q = [P[0] * 3.5, P[1] * 3.5, P[2] * 3.5]
    q[axis] *= 0.12
    g = fbm(q[0], q[1], q[2], seed, 3)
    ring = 0.5 + 0.5 * math.sin((P[(axis + 1) % 3] * 2.1 + P[(axis + 2) % 3] * 1.3) * 1.7 + g * 6)
    c = mix(dark, mid, 0.15 + 0.85 * g)
    return mix(c, light, ring * 0.35 * g)


def finish(cv, gain=1.12, sat=1.1):
    cv.dilate()
    cv.curve(gain, sat)


# ----------------------------------------------------------------------------------------------------------------------
# slug: Shotgun -> kindjal.SlugGun
# ----------------------------------------------------------------------------------------------------------------------

SLUG_DEFORM = {"select": "ShotgunShape*", "ops": [
    {"op": "region", "box": [[-9, -9, -12], [9, 9, -3]], "falloff": 1.5,
     "then": [{"op": "scale", "s": [1, 1, 0.78], "about": [0, 0, -3]}]},
    {"op": "region", "box": [[-9, -9, 2.5], [9, 9, 13]], "falloff": 1.0,
     "then": [{"op": "scale", "s": [1.15, 1.15, 0.52], "about": [0, 3.7, 2.5]}]},
]}


def paint_slug(cv, prims):
    body = [p for p in prims if p["name"].startswith("ShotgunShape")]
    pump = [p for p in prims if p["name"].startswith("shotgun_pump")]
    bz = [v[2] for p in body for v in p["pos"]]
    zmax = max(bz)
    muz = [v for p in body for v in p["pos"] if v[2] > zmax - 0.4]
    mcx = sum(v[0] for v in muz) / len(muz)
    mcy = sum(v[1] for v in muz) / len(muz)
    pz = [v[2] for p in pump for v in p["pos"]]
    pzmax = max(pz)

    def shell_bar(P, N, z0, pitch):
        """a bandolier on the stock side: a dark leather strap with stitched edges, grey slug shells (brass bases) in loops."""
        Y = P[1]
        k = (P[2] - z0) / pitch
        f = k - math.floor(k)
        if abs(Y) > 2.75:                                  # strap edges: stitching
            return mix((44, 28, 18), (150, 124, 84), 0.5 if (P[2] * 3.0) % 1.0 < 0.5 else 0.0)
        dx = abs(f - 0.5) / 0.34                           # 0 at the shell axis, 1 at its edge
        if dx < 1.0 and -2.45 < Y < 2.35:
            if Y < -1.0:                                   # brass base with a dark primer
                if Y < -1.9 and dx < 0.45:
                    return (40, 30, 24)
                return mix(BRASS_D, BRASS, 0.55 + 0.45 * (1 - dx))
            return mix((112, 118, 124), (206, 212, 216), clamp(1.0 - dx * 0.9))   # grey hull, lit down the middle
        return (30, 19, 12)                                # leather between the loops

    def body_shader(pr, isl, P, N, x, y):
        X, Y, Z = P
        if isl["hi"][2] > zmax - 0.5 and isl["hi"][2] - isl["lo"][2] < 0.5:   # muzzle ring face: one plain brass band
            return mix(BRASS_D, BRASS, 0.8 + 0.2 * vnoise(x * 0.5, y * 0.5, 0, 5))
        if isl["hi"][2] > zmax - 0.5 and isl["hi"][2] - isl["lo"][2] < 1.5:   # the bore: black, a hint of brass at the lip
            return mix((6, 5, 6), (40, 28, 14), smooth(5.9, 6.7, Z) * 0.8)
        if Z < -3.2:                                           # stock: warm dark wood, steel butt plate, shell bandolier
            if N[2] < -0.55:
                return steel(P, 21, (74, 86, 100))
            if abs(N[0]) > 0.5 and Z > -8.6 and Y < 1.2:
                return shell_bar(P, N, -8.4, 1.5)
            return wood(P, 11, dark=(52, 28, 16), mid=(112, 64, 34), light=(168, 110, 60))
        if Z > 2.5 and Y > 0.6:                                # barrel: pale blued steel with brass bands
            for zb in (3.6, 6.2):
                if abs(Z - zb) < 0.4:
                    return mix(BRASS_D, BRASS, 0.7 + 0.3 * vnoise(X * 8, Y * 8, Z * 8, 3))
            return steel(P, 31, (150, 168, 184), rust=0.25)
        if Y < -2.1:                                           # trigger guard
            return steel(P, 41, (60, 72, 88), rust=0.3)
        if N[1] > 0.6:                                         # receiver top: dark blued steel
            return steel(P, 51, (40, 50, 64), rust=0.2)
        return steel(P, 61, (58, 72, 90), rust=0.35)           # receiver: dark blue-black steel

    def pump_shader(pr, isl, P, N, x, y):
        X, Y, Z = P
        if Z > pzmax - 0.45 or Z < min(pz) + 0.45:
            return mix(BRASS_D, BRASS, 0.3 + 0.7 * vnoise(X * 5, Y * 5, Z * 5, 8))
        stripe = 0.5 + 0.5 * math.sin(Z * 4.2)
        c = wood(P, 71, axis=0, dark=(40, 22, 12), mid=(104, 60, 32), light=(160, 104, 56))
        return mix(c, (14, 8, 6), smooth(0.55, 0.85, stripe) * 0.7)

    def shader(pr, isl, P, N, x, y):
        return (body_shader if pr["name"].startswith("ShotgunShape") else pump_shader)(pr, isl, P, N, x, y)

    cv.raster(prims, shader)
    finish(cv, 1.15, 1.15)


MODELS["slug"] = dict(vanilla="Shotgun", resource="kindjal.SlugGun", section=500, deform=SLUG_DEFORM,
                      images={0: (256, 256, paint_slug)})


# ----------------------------------------------------------------------------------------------------------------------
# gibbet: SentryGun -> kindjal.GibbetTurret (14 rigid shapes, node clips, four 16x16 lamp images kept as flat lamp frames)
# ----------------------------------------------------------------------------------------------------------------------

GIBBET_DEFORM = {"ops": [
    {"op": "push", "dist": 0.35, "select": ["leg_?Shape*", "spindle_ringShape*"]},
    {"op": "noise", "amp": 0.22, "freq": 0.45, "seed": 4, "select": ["leg_?Shape*", "spindle_ringShape*", "spindleShape*"]},
    {"op": "push", "dist": 0.45, "select": "spindleShape*"},
    {"op": "push", "dist": 0.3, "select": "gunShape*"},
    {"op": "noise", "amp": 0.3, "freq": 0.35, "seed": 9, "select": "gunShape*"},
    # the vanilla rear hoop (an arch beside the box) becomes the gallows arm: stretched tall, then bent over the box top
    {"op": "region", "box": [[15.5, -3, -16.5], [26, 12, -5.5]], "falloff": 1.5,
     "then": [{"op": "scale", "s": [1, 1.9, 1.15], "about": [20, -3, -10]}], "select": "gunShape*"},
] + [
    {"op": "region", "box": [[-30, ya, -30], [40, 60, 30]], "falloff": 2.0,
     "then": [{"op": "translate", "t": [-2.8, 0, 1.8]}], "select": "gunShape*"} for ya in (13.0, 15.5, 18.0, 20.5)
] + [
    {"op": "scale", "s": [1, 1, 1.14], "about": [0, 0, 2], "select": "barrelShape*"},
    {"op": "push", "dist": 0.3, "select": "barrelShape*"},
    # the lamp stalk becomes the hanging chain: stretched up from the weight (the ball) to the arm
    {"op": "scale", "s": [1, 3.0, 1], "about": [0, -0.6, 0], "select": "ball_sec1Shape*"},
    {"op": "translate", "t": [0, 7.4, 0], "select": "ball_sec1Shape*"},
    {"op": "scale", "s": [1, 3.0, 1], "about": [0, -0.8, 0], "select": "ball_sec2Shape*"},
    {"op": "translate", "t": [0, 5.2, 0], "select": "ball_sec2Shape*"},
    {"op": "scale", "s": [0.9, 1.0, 0.9], "select": "ballShape*"},
]}

LAMPS = {1: (255, 120, 24), 2: (255, 22, 18), 3: (96, 255, 64), 4: (255, 226, 110)}


GIB_BOX, GIB_BOX_D = (104, 120, 114), (62, 74, 72)    # turret box: one plain cool grey, far lighter than the iron frame
GIB_ARM_ISL = (11, 12, 13)                             # gun-shape islands of the (deformed) gallows arm


def paint_gibbet(cv, prims):
    """The atlas is overlapped (tiled planar UVs: the box's triangles cover texels that legs, post and barrel also use),
    so paint by material, not by noise: the box is a plain grey, the frame is black iron, and shapes are layered
    box < arm < frame < chain < barrel so a shared texel always resolves to one of the five clean looks."""
    def is_arm(pr, isl, P=None):
        return pr["name"].startswith("gun") and (isl["id"] in GIB_ARM_ISL or (P is not None and P[1] > 11.4))

    def prio(pr, isl):
        n = pr["name"]
        if n.startswith("gun"):
            return 1 if is_arm(pr, isl) else 0
        if n.startswith("barrel"):
            return 4
        if n.startswith("ball_sec"):
            return 3
        return 2

    def shader(pr, isl, P, N, x, y):
        nm = pr["name"]
        X, Y, Z = P
        if nm.startswith("gun") and not is_arm(pr, isl, P):  # the box: plain grey plate, faint grain, thin dark seams
            c = mix(GIB_BOX_D, GIB_BOX, 0.78 + 0.22 * vnoise(x * 0.6, y * 0.6, 0, 12))
            if vnoise(x * 0.11, y * 0.11, 3, 14) > 0.8:
                c = mix(c, (96, 82, 70), 0.35)              # a few rust stains
            return c
        if nm.startswith("gun"):                           # the gallows arm: black iron with a chain of pale links along it
            t = ((X - 20.0) * -0.4 + (Y + 3.0) * 1.0 + (Z + 10.0) * 0.3) * 0.42  # progress along the arm
            u = t % 1.0
            c = mix(IRON_D, IRON_M, 0.2 + 0.5 * vnoise(X * 2, Y * 2, Z * 2, 41))
            link = smooth(0.05, 0.12, u) * (1 - smooth(0.38, 0.46, u))
            return mix(c, (150, 150, 170), link * 0.8)
        if nm.startswith("barrel"):                        # gatling cluster: the frame's black iron, ember only on the muzzle face
            if N[2] > 0.5 and Z > 14.0:
                r = math.hypot(X, Y)
                return mix((255, 160, 44), EMBER_D, smooth(0.0, 2.8, r) * 0.9 + 0.1 * vnoise(X * 4, Y * 4, 0, 4))
            c = mix(IRON_D, IRON_M, 0.2 + 0.7 * fbm(X * 1.4, Y * 1.4, Z * 0.5, 22, 3))
            if abs(Z - 5.2) < 0.7 or abs(Z - 9.4) < 0.5:   # bands
                c = mix(c, (118, 104, 140), 0.7)
            return c
        if nm.startswith("ball_sec"):                      # the hanging chain: alternating pale and dark links
            f = (Y * 0.85) % 1.0
            return mix((10, 9, 12), (176, 176, 192), 0.05 + 0.9 * smooth(0.25, 0.4, f) * (1 - smooth(0.6, 0.75, f)))
        # iron frame: legs, spindle, spindle ring: near-black violet iron, rivets and a little rust
        c = mix(IRON_D, IRON_M, 0.15 + 0.7 * fbm(X * 1.1, Y * 1.1, Z * 1.1, 31, 3))
        if vnoise(X * 9, Y * 9, Z * 9, 33) > 0.86:
            c = mix(c, (150, 140, 170), 0.6)
        if abs(((Y / 3.2) % 1.0) - 0.5) > 0.44:             # hoops
            c = mix(c, (86, 78, 104), 0.7)
        rv = fbm(X * 0.6 + 5, Y * 0.6, Z * 0.6, 35, 3)
        return mix(c, RUST, smooth(0.66, 0.78, rv) * 0.35)

    cv.raster([p for p in prims if not p["name"].startswith("ballShape")], shader, prio=prio)
    finish(cv, 1.2, 1.1)


def paint_lamp(k):
    def painter(cv, prims):
        for i in range(cv.w * cv.h):
            cv.d[i] = [LAMPS[k][0], LAMPS[k][1], LAMPS[k][2]]
    return painter


MODELS["gibbet"] = dict(vanilla="SentryGun", resource="kindjal.GibbetTurret", section=501, deform=GIBBET_DEFORM,
                        images={0: (256, 256, paint_gibbet), 1: (16, 16, paint_lamp(1)), 2: (16, 16, paint_lamp(2)),
                                3: (16, 16, paint_lamp(3)), 4: (16, 16, paint_lamp(4))})


# ----------------------------------------------------------------------------------------------------------------------
# harpoongun: HomingMissile.Weapon -> kindjal.HarpoonGun (gun body + animated frontcover and sight nodes)
# ----------------------------------------------------------------------------------------------------------------------

HARPOONGUN_DEFORM = {"ops": [
    # the frontcover (hinged at the muzzle; its local -z points forward at rest) becomes the barbed harpoon head:
    # lengthen it, flatten it into a blade (thin in x, which is depth for the side-on camera), narrow neck, wide barbs, sharp tip
    {"op": "scale", "s": [1, 1, 3.0], "about": [0, 0, 3.1], "select": "frontcoverShape*"},
    {"op": "scale", "s": [0.7, 1, 1], "about": [0, 0, 0], "select": "frontcoverShape*"},
    {"op": "region", "box": [[-9, -12, -4.0], [9, 6, 4.5]], "falloff": 1.5,
     "then": [{"op": "scale", "s": [1, 0.85, 1]}], "select": "frontcoverShape*"},
    {"op": "region", "box": [[-9, -12, -9.0], [9, 6, -5.0]], "falloff": 1.5,
     "then": [{"op": "scale", "s": [1, 2.6, 1]}], "select": "frontcoverShape*"},
    {"op": "region", "box": [[-9, -12, -24.0], [9, 6, -10.0]], "falloff": 3.0,
     "then": [{"op": "scale", "s": [0.4, 0.16, 1]}], "select": "frontcoverShape*"},
    # the cover's node is tilted 29 degrees at rest, so shear the head back level in steps (each step moves everything beyond it)
] + [
    {"op": "region", "box": [[-9, -30, -40.0], [9, 30, zs]], "falloff": 3.0,
     "then": [{"op": "translate", "t": [0, -2.35, 0]}], "select": "frontcoverShape*"} for zs in (-2.0, -6.0, -10.0, -14.0, -18.0)
] + [
    {"op": "translate", "t": [0, -0.6, 3.0], "select": "frontcoverShape*"},
    {"op": "push", "dist": 0.25, "select": "hominggunShape*"},
    {"op": "region", "box": [[-9, -9, -14], [9, 12, -8.5]], "falloff": 2.0,
     "then": [{"op": "scale", "s": [1.22, 1.22, 1], "about": [0, 2.2, -11]}], "select": "hominggunShape*"},
    {"op": "noise", "amp": 0.14, "freq": 0.5, "seed": 12, "select": ["hominggunShape*", "sightShape*"]},
]}


def paint_harpoongun(cv, prims):
    def shader(pr, isl, P, N, x, y):
        nm = pr["name"]
        X, Y, Z = P
        if nm.startswith("frontcover"):                    # barbed head: pale cold steel, dark blood-rust in the barbs
            c = steel(P, 81, (150, 160, 166), rust=0.0, scale=1.6, streak=0.35)
            c = mix(c, (60, 66, 72), smooth(0.2, 0.9, abs(N[0]) * 0.8 + abs(N[2]) * 0.5) * 0.5)
            rv = fbm(X * 0.9, Y * 0.5, Z * 0.9, 83, 3)
            return mix(c, (120, 44, 22), smooth(0.58, 0.7, rv) * 0.8)
        if nm.startswith("sight"):                         # ring sight with an ember lens
            if abs(Z) < 3.2 and N[2] > 0.55 and Z > 1.2:
                r = math.hypot(X, Y)
                return mix((255, 170, 60), EMBER_D, smooth(0.6, 1.9, r))
            return steel(P, 91, (74, 78, 84), rust=0.3, scale=1.3)
        # body
        ry = Y - 2.2
        if N[2] > 0.6 and Z > 9.0:                         # dark muzzle face with a brass ring
            r = math.hypot(X, ry)
            return mix((8, 8, 10), BRASS_D, smooth(2.2, 3.6, r) * 0.9)
        ang = math.atan2(ry, X)
        if Y < -1.4:                                       # pistol grip: black wrap
            return mix(IRON_D, IRON_M, 0.2 + 0.6 * vnoise(X * 3, Y * 3, Z * 3, 14)) if (Y * 2.0) % 1.0 < 0.6 else (8, 8, 10)
        if -4.2 < Z < 0.2 and math.hypot(X, ry) > 3.2:     # rope wound round the tube: twisted strands
            ph = (Z * 1.5 + ang * 0.95) % 1.0
            return mix((38, 28, 20), (176, 146, 100), 0.15 + 0.85 * smooth(0.1, 0.35, ph) * (1 - smooth(0.65, 0.9, ph)))
        if 6.2 < Z < 7.8:                                  # rusted orange band
            return mix(RUST, (110, 48, 20), vnoise(X * 4, Y * 4, Z * 4, 6))
        if Z < -8.5:                                       # reel end cap
            return steel(P, 95, (62, 66, 72), rust=0.35, scale=1.3)
        return steel(P, 101, (66, 70, 76), rust=0.3, scale=1.3)

    cv.raster(prims, shader)
    finish(cv, 1.2, 1.15)


MODELS["harpoongun"] = dict(vanilla="HomingMissile.Weapon", resource="kindjal.HarpoonGun", section=502,
                            deform=HARPOONGUN_DEFORM, images={0: (256, 256, paint_harpoongun)})


# ----------------------------------------------------------------------------------------------------------------------
# harpoon: HomingMissile.Payload -> kindjal.Harpoon (static projectile, nose at +z)
# ----------------------------------------------------------------------------------------------------------------------

HARPOON_DEFORM = {"ops": [
    {"op": "scale", "s": [1, 1, 2.4], "about": [0, 0, 0]},                      # long
    {"op": "scale", "s": [0.5, 0.5, 1], "about": [0, 0, 0]},                    # thin shaft
    {"op": "region", "box": [[-9, -9, -16], [9, 9, -6.5]], "falloff": 1.5,       # fletching: big tail fins
     "then": [{"op": "scale", "s": [2.4, 2.4, 1], "about": [0, 0, -9]}]},
    {"op": "region", "box": [[-9, -9, 7.4], [9, 9, 9.0]], "falloff": 1.3,        # the head flares into barbs
     "then": [{"op": "scale", "s": [3.8, 3.8, 1], "about": [0, 0, 8.2]}]},
    {"op": "region", "box": [[-9, -9, 6.0], [9, 9, 17.0]], "falloff": 1.0,       # ... flat, a blade the side-on camera sees
     "then": [{"op": "scale", "s": [0.45, 1, 1], "about": [0, 0, 9]}]},
    {"op": "region", "box": [[-9, -9, 10.8], [9, 9, 17.0]], "falloff": 1.8,      # ... and ends in a point
     "then": [{"op": "scale", "s": [0.3, 0.3, 1], "about": [0, 0, 11.5]}]},
    {"op": "noise", "amp": 0.07, "freq": 0.9, "seed": 3},
]}


def paint_harpoon(cv, prims):
    head0 = 6.4                                            # the head starts here (see the deform)

    def shader(pr, isl, P, N, x, y):
        X, Y, Z = P
        r = math.hypot(X, Y)
        if Z > head0:                                      # head: bright steel blade, dark gutter, rust-red barb edges
            c = steel(P, 7, (176, 184, 188), rust=0.0, scale=1.4, streak=0.4)
            if abs(X) < 0.35 and N[0] > 0.1:
                c = mul(c, 0.6)
            edge = smooth(0.35, 0.9, 1 - abs(N[0]))
            return mix(c, (80, 34, 22), edge * 0.45 * fbm(X * 1.4, Y * 1.4, Z * 1.4, 9, 2))
        if Z < -1.8:
            if r > 2.2 and Z < -4.0:                       # tail fins: dark iron with a pale edge
                return mix((26, 26, 32), (86, 88, 100), smooth(0.4, 1.0, vnoise(X * 2, Y * 2, Z * 2, 5)))
            ph = (Z * 1.1 + math.atan2(Y, X) * 0.8) % 1.0   # rope-wrapped tail: tan twisted strands over dark gaps
            return mix((34, 24, 14), (194, 150, 88), 0.1 + 0.9 * smooth(0.1, 0.35, ph) * (1 - smooth(0.65, 0.9, ph)))
        for zb in (0.3, 3.6):                              # rust bands on the grey steel shaft
            if abs(Z - zb) < 0.8:
                return mix(RUST, (110, 48, 20), vnoise(X * 3, Y * 3, Z * 3, 6))
        return steel(P, 11, (122, 130, 134), rust=0.25)

    cv.raster(prims, shader)
    finish(cv, 1.15, 1.1)


MODELS["harpoon"] = dict(vanilla="HomingMissile.Payload", resource="kindjal.Harpoon", section=503, deform=HARPOON_DEFORM,
                         images={0: (64, 64, paint_harpoon)})


# ----------------------------------------------------------------------------------------------------------------------
# plaguebow: Bow -> kindjal.PlagueBow (skinned, 5 bones: root, upper_arm, lower_arm, string1, arrow)
# ----------------------------------------------------------------------------------------------------------------------

# Skinned, so the edit stays small next to the joints: a push of a fraction of the limb width plus low noise for knuckly bone,
# and a larger push on the two tips (knobs) where only one bone has any weight.
PLAGUEBOW_DEFORM = {"ops": [
    {"op": "push", "dist": 0.6},
    {"op": "noise", "amp": 0.2, "freq": 0.4, "seed": 5},
    {"op": "region", "box": [[-20, 31.5, -20], [20, 50, 20]], "falloff": 2.5, "then": [{"op": "push", "dist": 0.5}]},
    {"op": "region", "box": [[-20, -20, -20], [20, -3.5, 20]], "falloff": 2.5, "then": [{"op": "push", "dist": 0.5}]},
    {"op": "region", "box": [[-20, 8.7, -20], [20, 16.8, 20]], "falloff": 2.0, "then": [{"op": "push", "dist": 0.45}]},   # chunkier grip
]}


def bow_limb(x, y):
    """The limbs, the knob tips and the arrow shaft's pale part all live in one small strip of the atlas (64 x 60 texels:
    lower limb, upper limb and the knobs overlap there, tip to joint in opposite directions), so this is a function of the
    texel only. Bright bone in the middle, green rot at both ends of the strip (= the tips of one limb and the joint end
    of the other) with a clean dark edge and drips running into the bone."""
    t = clamp((y - 67.5) / 60.0)    # y counts rows from the bottom of the PNG (the caller passes height - 1 - row)
    e = min(t, 1.0 - t)
    bone = mix((236, 228, 198), (255, 251, 232), vnoise(x * 0.35, y * 0.12, 0, 21))
    if vnoise(x * 0.9, 0.5, 0, 22) > 0.78:
        bone = mul(bone, 0.86)                           # grain lines along the limb
    if vnoise(x * 1.3, y * 1.3, 5, 23) > 0.88:
        bone = mix(bone, (132, 120, 92), 0.6)            # pits
    th = 0.2 + 0.07 * (vnoise(x * 0.5, 1.0, 0, 24) * 2 - 1)
    if vnoise(x * 0.7, 3.0, 0, 25) > 0.64:
        th += 0.1                                        # a drip
    inside = 1.0 - smooth(th - 0.025, th + 0.025, e)
    rot = mix((30, 78, 16), ROT, 0.35 + 0.65 * clamp(1.0 - e / th) + 0.15 * (vnoise(x * 1.2, y * 1.2, 2, 26) - 0.5))
    for tb in (0.3, 0.52, 0.74):                         # dark leather ties: structure that survives 64 px
        if abs(t - tb) < 0.035:
            bone = mix((52, 36, 26), (92, 66, 44), vnoise(x * 0.8, y * 0.8, 7, 27))
    c = mix(bone, rot, inside)
    edge = smooth(th - 0.06, th, e) * (1.0 - smooth(th, th + 0.03, e))
    return mix(c, (22, 44, 12), edge * 0.55)


def paint_plaguebow(cv, prims):
    def part(isl):
        cx, cy, cz = isl["c"]
        sx, sy, sz = (isl["hi"][k] - isl["lo"][k] for k in range(3))
        if sy > 25 and sx < 3.0 and sz < 2.6:
            return "string"
        if cz > 3.0 or isl["hi"][2] > 7.0:
            return "arrow"
        if 8.0 < cy < 17.5:
            return "grip"
        if cy > 31.0 or cy < -3.0:
            return "tip"
        return "limb"

    def skull(Y, Z, yc, zc):
        """a skull in the (z, y) plane around (zc, yc): 1 = bone, 0 = socket / gap, None = outside."""
        dz, dy = (Z - zc) / 0.95, (Y - yc) / 0.95
        if math.hypot(dz, dy - 0.5) < 2.25 or (-2.7 < dy < -0.9 and abs(dz) < 1.3):
            for ez in (-0.95, 0.95):
                if math.hypot(dz - ez, dy - 0.6) < 0.75:
                    return 0.0
            if abs(dz) < 0.35 and -0.7 < dy < 0.0 and abs(dz) < (0.0 - dy) * 0.5 + 0.1:
                return 0.0
            if -2.7 < dy < -0.9 and (abs(dz) % 0.55) < 0.12:
                return 0.0
            return 1.0
        return None

    def shader(pr, isl, P, N, x, y):
        X, Y, Z = P
        kind = part(isl)
        if kind == "string":
            return (232, 226, 198)
        if kind == "arrow":
            if Z > 17.0:                                   # envenomed head: bright rot green, black barbs
                g = vnoise(X * 2, Y * 2, Z * 2, 3)
                return mix((22, 60, 14), ROT, 0.55 + 0.45 * g) if abs(N[0]) > 0.35 or Z > 19 else (14, 20, 12)
            if Z < 8.0:                                    # black fletching
                return mix((10, 10, 12), (52, 48, 60), vnoise(X * 4, Y * 4, Z * 4, 4))
            band = 0.5 + 0.5 * math.sin(Z * 2.1)
            return mix(mix(BONE_D, BONE, 0.5 + 0.5 * vnoise(X * 3, Y * 1.2, Z * 1.2, 6)), (20, 18, 16), smooth(0.7, 0.9, band) * 0.8)
        if kind == "grip":                                 # black wrapped grip, a big bone skull lashed to each side
            if abs(N[0]) > 0.35 and Z < 5.6:
                s = skull(Y, Z, 12.3, 2.7)
                if s is not None:
                    return mix((14, 12, 16), (252, 248, 228), s)
                if math.hypot(Z - 2.7, Y - 12.3) < 2.7:    # dark ring round the charm
                    return (6, 6, 8)
            ph = (Y * 1.25 + Z * 0.55 + X * 0.4) % 1.0
            c = mix((6, 6, 8), (74, 70, 84), 0.15 + 0.85 * smooth(0.15, 0.4, ph) * (1 - smooth(0.6, 0.85, ph)))
            return mix(c, ROT, smooth(0.74, 0.82, fbm(X * 0.8, Y * 0.8, Z * 0.8, 17, 3)) * 0.5)
        return bow_limb(x, cv.h - 1 - y)                   # limbs and knob tips (bow_limb's rows are the strip's, counted from the other edge)

    cv.raster(prims, shader)
    finish(cv, 1.0, 1.1)


MODELS["plaguebow"] = dict(vanilla="Bow", resource="kindjal.PlagueBow", section=504, deform=PLAGUEBOW_DEFORM,
                           images={0: (128, 128, paint_plaguebow)})


# ----------------------------------------------------------------------------------------------------------------------
# driver
# ----------------------------------------------------------------------------------------------------------------------


def run_xomtool(xomtool, args):
    r = subprocess.run([xomtool] + args, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("xomtool %s failed (exit %d): %s" % (" ".join(args[:3]), r.returncode, (r.stderr or r.stdout).strip()))
    return r.stdout


def build_model(slug, xomtool, bundl09, out_dir, work, keep=None):
    m = MODELS[slug]
    os.makedirs(work, exist_ok=True)
    dpath = os.path.join(work, slug + ".deform.json")
    with open(dpath, "w", encoding="utf-8", newline="\n") as f:
        json.dump(m["deform"], f, indent=1, sort_keys=True)
    base = ["clone", m["vanilla"], "--from", bundl09, "--as", m["resource"], "--section", str(m["section"])]
    if m["deform"]:
        base += ["--deform", dpath]
    gltf = os.path.join(work, slug + ".gltf")
    run_xomtool(xomtool, base + ["--bundle", os.path.join(work, slug + ".pre.xom"), "--out-gltf", gltf])
    prims = read_gltf(gltf)
    tex_args = []
    for k, (w, h, painter) in sorted(m["images"].items()):
        cv = Canvas(w, h)
        painter(cv, prims)
        p = os.path.join(work, "%s.image%d.png" % (slug, k))
        with open(p, "wb") as f:
            f.write(cv.png())
        tex_args += ["--texture", "%d=%s" % (k, p)]
    out = os.path.join(out_dir, m["resource"] + ".xom")
    os.makedirs(out_dir, exist_ok=True)
    run_xomtool(xomtool, base + tex_args + ["--bundle", out])
    if keep:
        os.makedirs(keep, exist_ok=True)
        for fn in os.listdir(work):
            if fn.startswith(slug + ".") and not fn.endswith(".pre.xom"):
                with open(os.path.join(work, fn), "rb") as a, open(os.path.join(keep, fn), "wb") as b:
                    b.write(a.read())
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--xomtool", default=DEFAULT_XOMTOOL)
    ap.add_argument("--bundl09", default=DEFAULT_BUNDL09)
    ap.add_argument("--check", action="store_true", help="rebuild into a temp folder and compare with the files on disk")
    ap.add_argument("--only", action="append", help="build only this slug (repeatable)")
    ap.add_argument("--preview", help="folder to keep each model's deformed glTF and painted PNGs in")
    ap.add_argument("--out-dir", default=OUT_DIR)
    a = ap.parse_args(argv)
    _paths.require_tools(a.xomtool, a.bundl09)
    slugs = a.only or list(MODELS)
    _paths.require_slugs(slugs, MODELS)
    bad = 0
    with tempfile.TemporaryDirectory() as tmp:
        for s in slugs:
            if a.check:
                out = build_model(s, a.xomtool, a.bundl09, os.path.join(tmp, "out"), os.path.join(tmp, "work"), a.preview)
                disk = os.path.join(a.out_dir, os.path.basename(out))
                same = os.path.isfile(disk) and open(disk, "rb").read() == open(out, "rb").read()
                print("%-12s %s" % (s, "identical" if same else "DIFFERENT or missing: " + disk))
                bad += 0 if same else 1
            else:
                out = build_model(s, a.xomtool, a.bundl09, a.out_dir, os.path.join(tmp, "work"), a.preview)
                print("built %s (%d bytes)" % (out, os.path.getsize(out)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
