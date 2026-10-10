#!/usr/bin/env python3
"""Kindjal aircraft clones: the vanilla airstrike helicopters cloned with their node tree, repainted and reshaped.

    python clones_air.py                    rebuild every bank into mod/assets/meshes/kindjal.<Name>.xom
    python clones_air.py --check            rebuild into a temp dir and compare the bytes with the banks on disk
    python clones_air.py --gltf-dir D       also write D/<slug>.gltf/.bin (the deformed clone) and D/<slug>.image<k>.png
    options: --xomtool <exe> --bundl09 <Bundl09.xom> --only <slug>

slug             vanilla           resource                 section  icon
black_gunship    BomberHelicopter  kindjal.BlackGunship     511      carpet-bombing
    matte black hull, charcoal belly, blood-red trim and engine cowls, smoked glass, chipped paint, rust runs, a skull and
    crossbones on both nose sides, glowing red lights on the pod tips, the fin top and the nose tip, plain dark armour on the
    bomb-bay doors; a long, pointed, dropped nose, a sagging tail boom and a much taller fin (scaled about the rear rotor hub)
carrion_gunship  SuperAirstrike    kindjal.CarrionGunship   512      carrion-drop
    grimy bone-white hull with painted ribs, blood-red belly and trim, dark red glass, blood runs, a cow-skull badge on the
    nose, a dark meat-locker panel under it with four steel hooks (the front two with meat); the round nose tapers into a
    long vulture beak that hooks down, a dropped chin under it, a knobbly hull

The engine drives these meshes by node name (rear_rotor, top_rotor, trail1, trail2, perspShape, the Bombbaydoor nodes), so
they are made with `xomtool clone`, which keeps every node, shader and texture stage, and only:
  * moves vertices (--deform; node transforms are untouched, so the rotors stay on their hubs), and
  * replaces the pixels of the two images (--texture): image 0 is the 512x512 body atlas, image 1 the 32x32 RGBA rotor blur.

The body atlas is repainted per texel. A first clone of the vanilla mesh (--uv-layout, --out-gltf) gives the vanilla atlas and
the geometry; every texel is mapped back to the 3D points that sample it (in the Chopper node's frame), so the livery is
painted on the model rather than on the atlas: rust and blood streaks run down the hull, the nose art and the meat hooks sit
on the cabin sides, the lights sit on the pod tips, the fin and the nose. The atlas wraps and is mirrored left/right, so the
decorations are functions of (|x|, y, z). The nose art is kept only where every use of a texel agrees; the rust runs, the
lights and the meat hooks take the strongest of a shared texel's uses, so they survive the atlas reuse (at the cost of a
little spill onto panels that borrow the same texels). The bomb-bay doors of the black gunship borrow the striped cowl
texels and get plain dark plate there. The base colour comes from a
classification of the vanilla texel (orange hull, cream belly, red trim, navy glass, steel), which keeps the vanilla's panel
lines and shading as value detail under the new palette.

Stdlib only, deterministic (hash noise with fixed seeds). Importing this module has no side effects.
"""
import argparse
import colorsys
import json
import math
import shutil
import struct
import subprocess
import sys
import tempfile
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUT_DIR = HERE.parent / "mod" / "assets" / "meshes"
XOMTOOL = r"C:\Users\Jamin\Desktop\melange-wt-audio\dist\tools\xomtool.exe"
BUNDL09 = r"C:\Users\Jamin\Desktop\WUMFix\testenv\A\Data\Bundles\Bundl09.xom"


# ---------------------------------------------------------------- PNG
def read_png(path):
    """-> (w, h, rows of RGBA tuples). 8-bit grey, RGB, grey+alpha or RGBA, every filter type."""
    d = Path(path).read_bytes()
    pos, idat = 8, b""
    while pos < len(d):
        ln, tag = struct.unpack(">I4s", d[pos:pos + 8])
        body = d[pos + 8:pos + 8 + ln]
        if tag == b"IHDR":
            w, h, bd, ct = struct.unpack(">IIBB", body[:10])
            if bd != 8:
                raise ValueError(f"{path}: bit depth {bd}")
        elif tag == b"IDAT":
            idat += body
        pos += 12 + ln
    bpp = {0: 1, 2: 3, 4: 2, 6: 4}[ct]
    raw = zlib.decompress(idat)
    st = w * bpp
    prev = bytearray(st)
    rows, p = [], 0
    for _ in range(h):
        f = raw[p]
        line = bytearray(raw[p + 1:p + 1 + st])
        p += 1 + st
        for i in range(st):
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
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else (b if pb <= pc else c))) & 255
        row = []
        for x in range(w):
            px = line[x * bpp:(x + 1) * bpp]
            if bpp == 1:
                row.append((px[0], px[0], px[0], 255))
            elif bpp == 2:
                row.append((px[0], px[0], px[0], px[1]))
            elif bpp == 3:
                row.append((px[0], px[1], px[2], 255))
            else:
                row.append(tuple(px))
        rows.append(row)
        prev = line
    return w, h, rows


def write_png(path, rows, alpha=False):
    h, w = len(rows), len(rows[0])
    n = 4 if alpha else 3
    raw = bytearray()
    for r in rows:
        raw.append(0)
        for c in r:
            raw += bytes(max(0, min(255, int(round(c[k])))) for k in range(n))

    def chunk(t, b):
        return struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b) & 0xFFFFFFFF)
    Path(path).write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6 if alpha else 2, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b""))


# ---------------------------------------------------------------- small maths and noise
def clamp(v, a=0.0, b=1.0):
    return a if v < a else (b if v > b else v)


def smooth(e0, e1, x):
    t = clamp((x - e0) / (e1 - e0)) if e1 != e0 else (1.0 if x >= e0 else 0.0)
    return t * t * (3 - 2 * t)


def mix(a, b, t):
    return tuple(a[k] + (b[k] - a[k]) * t for k in range(len(a)))


def scl(c, s):
    return tuple(v * s for v in c)


def hash2(i, j, seed):
    n = (i * 374761393 + j * 668265263 + seed * 2147483647) & 0xFFFFFFFF
    n = ((n ^ (n >> 13)) * 1274126177) & 0xFFFFFFFF
    return ((n ^ (n >> 16)) & 0xFFFFFF) / float(0xFFFFFF)


def hash1(i, seed):
    return hash2(i, 0x5bd1, seed)


def vnoise(x, y, seed):
    i, j = math.floor(x), math.floor(y)
    fx, fy = x - i, y - j
    fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
    a, b = hash2(i, j, seed), hash2(i + 1, j, seed)
    c, d = hash2(i, j + 1, seed), hash2(i + 1, j + 1, seed)
    return (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy


def fbm(x, y, seed, octaves=4):
    s, a, t = 0.0, 0.5, 0.0
    for o in range(octaves):
        s += a * vnoise(x, y, seed + o * 31)
        t += a
        x, y, a = x * 2.03, y * 2.03, a * 0.5
    return s / t


def seg_dist(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    t = clamp(((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy or 1.0))
    return math.hypot(px - ax - t * dx, py - ay - t * dy)


# ---------------------------------------------------------------- geometry: glTF -> shapes in the Chopper node frame
def _mmul(a, b):  # column-major 4x4
    return [sum(a[r + 4 * k] * b[k + 4 * c] for k in range(4)) for c in range(4) for r in range(4)]


def load_shapes(gltf, frame="Chopper"):
    """-> {shape name: (positions, normals, uvs, triangles)}, positions in node `frame`'s own (local) frame, the frame
    --deform uses for its shapes; the rigid children below it (rotors, gear) are placed by their node matrices."""
    gltf = Path(gltf)
    g = json.loads(gltf.read_text())
    b = (gltf.parent / g["buffers"][0]["uri"]).read_bytes()

    def acc(i):
        a = g["accessors"][i]
        v = g["bufferViews"][a["bufferView"]]
        n = {"SCALAR": 1, "VEC2": 2, "VEC3": 3}[a["type"]]
        fmt = {5126: "f", 5125: "I", 5123: "H"}[a["componentType"]]
        vals = struct.unpack_from("<" + fmt * (a["count"] * n), b, v.get("byteOffset", 0) + a.get("byteOffset", 0))
        return [vals[k:k + n] for k in range(0, len(vals), n)]
    ident = [1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0, 0, 0, 0, 0, 1.0]
    out = {}

    def walk(ni, m, own=True):
        n = g["nodes"][ni]
        w = _mmul(m, n.get("matrix", ident)) if own else m
        if "mesh" in n:
            mesh = g["meshes"][n["mesh"]]
            pr = mesh["primitives"][0]
            at = pr["attributes"]
            pos = [(w[0] * p[0] + w[4] * p[1] + w[8] * p[2] + w[12], w[1] * p[0] + w[5] * p[1] + w[9] * p[2] + w[13],
                    w[2] * p[0] + w[6] * p[1] + w[10] * p[2] + w[14]) for p in acc(at["POSITION"])]
            nrm = [(w[0] * p[0] + w[4] * p[1] + w[8] * p[2], w[1] * p[0] + w[5] * p[1] + w[9] * p[2],
                    w[2] * p[0] + w[6] * p[1] + w[10] * p[2]) for p in acc(at["NORMAL"])]
            idx = [i[0] for i in acc(pr["indices"])]
            out[mesh.get("name", str(n["mesh"]))] = (pos, nrm, acc(at["TEXCOORD_0"]),
                                                      [tuple(idx[i:i + 3]) for i in range(0, len(idx), 3)])
        for c in n.get("children", []):
            walk(c, w)
    root = [i for i, n in enumerate(g["nodes"]) if n.get("name") == frame]
    if not root:
        raise ValueError(f"{gltf}: no node {frame!r}")
    walk(root[0], ident, own=False)
    return out


def texel_map(shapes, names, w, h):
    """-> {(x, y): [(pos, unit normal, shape), ...]}: every 3D point of the named shapes that samples texel (x, y) (UVs
    wrap)."""
    m = {}
    for nm in names:
        if nm not in shapes:
            continue
        P, N, uv, tris = shapes[nm]
        for (a, b, c) in tris:
            A = (uv[a][0] * w, (1 - uv[a][1]) * h)
            B = (uv[b][0] * w, (1 - uv[b][1]) * h)
            C = (uv[c][0] * w, (1 - uv[c][1]) * h)
            area = (B[0] - A[0]) * (C[1] - A[1]) - (B[1] - A[1]) * (C[0] - A[0])
            if abs(area) < 1e-9:
                continue
            e = -0.6 / max(1.0, abs(area)) ** 0.5  # a texel-wide bleed so that edges are covered
            for y in range(math.floor(min(A[1], B[1], C[1])), math.ceil(max(A[1], B[1], C[1])) + 1):
                for x in range(math.floor(min(A[0], B[0], C[0])), math.ceil(max(A[0], B[0], C[0])) + 1):
                    px, py = x + 0.5, y + 0.5
                    w0 = ((B[0] - px) * (C[1] - py) - (B[1] - py) * (C[0] - px)) / area
                    w1 = ((C[0] - px) * (A[1] - py) - (C[1] - py) * (A[0] - px)) / area
                    w2 = 1 - w0 - w1
                    if w0 < e or w1 < e or w2 < e:
                        continue
                    p = tuple(w0 * P[a][k] + w1 * P[b][k] + w2 * P[c][k] for k in range(3))
                    n = tuple(w0 * N[a][k] + w1 * N[b][k] + w2 * N[c][k] for k in range(3))
                    nl = math.sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]) or 1.0
                    m.setdefault((x % w, y % h), []).append((p, (n[0] / nl, n[1] / nl, n[2] / nl), nm))
    return m


# ---------------------------------------------------------------- vanilla texel classes
def classify(c):
    """-> (class, shade): the vanilla atlas' material and its brightness relative to that material's mean."""
    r, g, b = c[0] / 255.0, c[1] / 255.0, c[2] / 255.0
    h, s, v = colorsys.rgb_to_hsv(r, g, b)
    if s >= 0.55 and 0.47 <= h <= 0.88:
        return "glass", v / 0.25
    if s < 0.13 or 0.38 <= h <= 0.88:
        return "metal", v / 0.62
    if h < 0.068 or h > 0.88:
        return "trim", v / 0.75
    if s >= 0.5:
        return "hull", v / 0.86
    return "belly", v / 0.97


# ---------------------------------------------------------------- decorations in the Chopper frame
def streaks(p, n, seed, density, y_lo, y_hi, len_lo, len_hi, width=0.55, cell=1.7):
    """Vertical runs down the hull (rust, blood): 0..1. Columns across the surface (z on the sides, |x| on the ends)."""
    if abs(n[1]) > 0.75:
        return 0.0
    hcoord = p[2] if abs(n[0]) >= abs(n[2]) else abs(p[0]) + 100.0
    ci = math.floor(hcoord / cell)
    best = 0.0
    for k in (ci - 1, ci, ci + 1):
        if hash1(k, seed) > density:
            continue
        cx = (k + 0.2 + 0.6 * hash1(k, seed + 1)) * cell
        y0 = y_lo + (y_hi - y_lo) * hash1(k, seed + 2)
        ln = len_lo + (len_hi - len_lo) * hash1(k, seed + 3)
        wd = width * (0.6 + 0.8 * hash1(k, seed + 4))
        dy = y0 - p[1]
        if dy < -0.4 or dy > ln:
            continue
        taper = 1.0 - dy / ln
        wob = (vnoise(p[1] * 0.9, k * 3.1, seed + 5) - 0.5) * 0.5
        across = abs(hcoord + wob - cx) / (wd * (0.45 + 0.55 * taper))
        a = clamp(1.0 - across) * (0.35 + 0.65 * taper) * smooth(-0.4, 0.3, dy)
        best = max(best, a)
    return best


def skull(s, t):
    """A jolly-roger skull with crossed bones, in decal units (about -1.2..1.2): -> (bone 0..1, dark detail 0..1)."""
    def ell(cx, cy, rx, ry):
        return math.hypot((s - cx) / rx, (t - cy) / ry)
    cran = ell(0.0, 0.22, 0.72, 0.66) < 1.0
    jaw = abs(s) < 0.40 and -0.66 < t < -0.18
    cheek = ell(0.0, -0.12, 0.6, 0.3) < 1.0
    bones = False
    for sx in (-1.0, 1.0):
        d = seg_dist(s, t, -0.95 * sx, -1.05, 0.95 * sx, -0.25)
        knob = min(math.hypot(s - 0.95 * sx, t + 0.25 + 0.08), math.hypot(s - 0.95 * sx + 0.1 * sx, t + 0.25 - 0.08),
                   math.hypot(s + 0.95 * sx, t + 1.05 + 0.08), math.hypot(s + 0.95 * sx - 0.1 * sx, t + 1.05 - 0.08))
        bones = bones or d < 0.12 or knob < 0.13
    fill = cran or jaw or cheek or bones
    dark = 0.0
    if fill:
        if ell(-0.28, 0.12, 0.21, 0.22) < 1.0 or ell(0.28, 0.12, 0.21, 0.22) < 1.0:
            dark = 1.0
        elif -0.32 < t < -0.08 and abs(s) < 0.12 * (t + 0.32) / 0.24 + 0.02:
            dark = 1.0
        elif (cran or jaw or cheek) and -0.62 < t < -0.36 and any(abs(s - q) < 0.035 for q in (-0.24, -0.08, 0.08, 0.24)):
            dark = 1.0
        elif (cran or jaw or cheek) and abs(t + 0.42) < 0.035 and abs(s) < 0.38:
            dark = 1.0
    return (1.0 if fill else 0.0), dark


def meat_hook(s, t, meat):
    """One hook hanging from a rail at t = 0 (units: hook height about 1). -> 0 nothing, 1 dark outline, 2 steel,
    3 meat, 4 fat/bone (a lump of meat on the hook when `meat`)."""
    d = abs(s) if -0.42 < t < 0.0 else 9.0                                   # chain
    d = min(d, abs(s) + 0.0 if -0.74 < t <= -0.42 else 9.0)                  # shank
    ring = math.hypot(s - 0.16, t + 0.74)
    if t < -0.72:
        d = min(d, abs(ring - 0.16))                                         # the J
    elif s > 0.26:
        d = min(d, math.hypot(s - 0.32, t + 0.70))                           # point
    if meat:
        e = math.hypot((s - 0.14) / 0.33, (t + 0.95) / 0.34)
        if e < 1.0:
            return 4 if abs(e - 0.55) < 0.13 and s > 0.08 else 3
        if e < 1.14:
            return 1
    if d < 0.075:
        return 2
    if d < 0.13:
        return 1
    return 0


# ---------------------------------------------------------------- the two liveries
def _grain(x, y, seed, amp):
    return (hash2(x, y, seed) - 0.5) * amp


def paint_black_gunship(base, tmap):
    """Matte black hull, charcoal belly, blood-red trim, smoked glass, rust streaks, a skull on the nose, red lights."""
    H, W = len(base), len(base[0])
    out = []
    for y in range(H):
        row = []
        for x in range(W):
            cls, sh = classify(base[y][x])
            sh = clamp(sh, 0.0, 1.6)
            g = _grain(x, y, 11, 10.0)
            wear = fbm(x / 9.0, y / 9.0, 3)
            if cls == "hull":
                c = scl((44, 45, 49), 0.5 + 0.6 * sh ** 1.3)
                if wear > 0.76:  # chipped paint: bare steel
                    c = mix(c, (96, 96, 100), 0.7 * smooth(0.76, 0.8, wear))
            elif cls == "belly":
                c = scl((62, 62, 64), 0.5 + 0.5 * sh)
                if wear > 0.76:
                    c = mix(c, (105, 102, 98), 0.5)
            elif cls == "trim":
                c = scl((168, 22, 16), 0.5 + 0.55 * sh)
            elif cls == "glass":
                v = clamp(sh / 4.0)
                c = mix((20, 30, 36), (170, 215, 225), v ** 1.3)
            else:
                c = scl((86, 88, 92), 0.25 + 0.75 * sh)
            uses = tmap.get((x, y))
            if uses and cls in ("hull", "trim", "belly") and any(u[2].lower().startswith("bombbay") for u in uses):
                # the bomb-bay doors borrow the striped cowl texels: plain dark armour plate there, no stripes
                c = scl((52, 52, 56), 0.55 + 0.45 * sh)
            c = tuple(v + g for v in c)
            if uses and cls != "glass":
                c = _black_decor(c, cls, uses)
            row.append(c)
        out.append(row)
    return out


# (point in (|x|, y, z), radius): the stub-wing pod tips, the fin top, the nose tip
LIGHTS_BLACK = [((33.8, -2.4, 17.5), 3.4), ((6.5, 19.6, -35.0), 3.6), ((0.0, -2.0, 41.0), 3.0)]


def _black_decor(c, cls, uses):
    # rust runs on the painted panels (not the steel: tyres, struts, pods): a shared texel leans to the strongest run of
    # its uses, so the runs survive the atlas reuse instead of averaging away
    rs = [streaks(p, n, 101, 0.7, -6.0, 24.0, 4.0, 16.0, width=0.85) for p, n, _ in uses]
    rust = 0.6 * max(rs) + 0.4 * sum(rs) / len(rs) if cls != "metal" else 0.0
    if rust > 0:
        p = uses[0][0]
        rc = mix((176, 78, 26), (96, 40, 16), vnoise(p[1] * 1.3, p[2] * 1.3, 7))
        c = mix(c, rc, smooth(0.0, 0.45, rust) * 0.95)
    # skull nose art on the cabin sides, under the canopy
    a = dark = 1.0
    for p, n, _ in uses:
        if abs(n[0]) < 0.35 or abs(p[0]) < 6.0:
            a = dark = 0.0
            break
        sa, sd = skull((p[2] - SKULL_BLACK[0]) / SKULL_BLACK[2], (p[1] - SKULL_BLACK[1]) / SKULL_BLACK[2])
        a, dark = min(a, sa), min(dark, sd)
    if a > 0:
        c = (225, 218, 196) if dark < 0.5 else (150, 10, 8)
    # navigation lights
    glow = max(clamp(1.0 - math.dist((abs(p[0]), p[1], p[2]), q) / r) for q, r in LIGHTS_BLACK for p, n, _ in uses)
    if glow > 0:
        c = mix(c, (255, 34, 22), smooth(0.0, 0.2, glow))
        c = mix(c, (255, 200, 170), smooth(0.55, 0.85, glow))
    return c


SKULL_BLACK = (27.0, -3.0, 4.6)   # z, y of the centre, size (Chopper frame)


def paint_carrion_gunship(base, tmap):
    """Bone-white hull with ribs, blood-red belly and trim, dark red glass, blood runs, meat hooks under the cabin."""
    H, W = len(base), len(base[0])
    out = []
    for y in range(H):
        row = []
        for x in range(W):
            cls, sh = classify(base[y][x])
            sh = clamp(sh, 0.0, 1.6)
            g = _grain(x, y, 23, 12.0)
            grime = fbm(x / 4.5, y / 4.5, 9)
            if cls == "hull":
                c = mix((150, 136, 110), (232, 222, 196), clamp(sh ** 1.8))
                c = mix(c, (96, 80, 62), smooth(0.58, 0.8, grime) * 0.42)
            elif cls == "belly":
                c = scl((128, 16, 14), 0.55 + 0.5 * sh)
                c = mix(c, (60, 8, 8), smooth(0.5, 0.8, grime) * 0.6)
            elif cls == "trim":
                c = scl((80, 8, 8), 0.6 + 0.5 * sh)
            elif cls == "glass":
                v = clamp(sh / 4.0)
                c = mix((22, 6, 6), (220, 150, 130), v ** 1.6)
            else:
                c = scl((74, 62, 56), 0.3 + 0.75 * sh)
                c = mix(c, (110, 50, 26), smooth(0.55, 0.8, grime) * 0.6)
            c = tuple(v + g for v in c)
            uses = tmap.get((x, y))
            if uses and cls != "glass":
                c = _carrion_decor(c, cls, uses)
            row.append(c)
        out.append(row)
    return out


def ribs(p, n):
    """Dark gaps between painted ribs on the cabin sides (0..1)."""
    if abs(n[0]) < 0.3 or abs(p[0]) > 16.0 or not (-12.0 < p[2] < 24.0) or not (-10.0 < p[1] < 18.0):
        return 0.0
    t = (p[1] - 4.0) / 12.0
    s = (p[2] + 12.0) / 4.2 + 0.9 * t * t
    d = abs(s - round(s))
    return smooth(0.16, 0.08, d) * smooth(-12.0, -9.0, p[2]) * smooth(24.0, 20.0, p[2])


def cow_skull(s, t):
    """A cow skull with horns on a round blood-red badge, decal units: -> 0 nothing, 1 outline, 2 badge, 3 bone, 4 socket."""
    r = math.hypot(s, t)
    if r > 1.3:
        return 0
    if r > 1.18:
        return 1
    a = abs(s)
    horn = seg_dist(a, t, 0.28, 0.42, 0.72, 0.58) < 0.11 or seg_dist(a, t, 0.72, 0.58, 0.98, 0.92) < 0.075
    cran = math.hypot(s / 0.44, (t - 0.28) / 0.30) < 1.0
    half = 0.17 + 0.17 * clamp((t + 0.8) / 1.05)                    # the long tapering snout
    snout = -0.86 < t < 0.3 and a < half or math.hypot(s / 0.2, (t + 0.84) / 0.12) < 1.0
    if horn or cran or snout:
        if math.hypot((a - 0.2) / 0.12, (t - 0.18) / 0.14) < 1.0 or math.hypot((a - 0.08) / 0.05, (t + 0.74) / 0.07) < 1.0:
            return 4
        return 3
    return 2


def _carrion_decor(c, cls, uses):
    if cls == "hull":
        r = sum(ribs(p, n) for p, n, _ in uses) / len(uses)
        if r > 0:
            c = mix(c, (58, 30, 22), r * 0.85)
    blood = sum(streaks(p, n, 202, 0.3, 0.0, 24.0, 4.0, 14.0, width=0.65) for p, n, _ in uses) / len(uses)
    if blood > 0 and cls in ("hull", "belly"):
        c = mix(c, (112, 6, 6), smooth(0.0, 0.25, blood) * 0.95)
    # a cow-skull badge on the nose
    marks = set()
    for p, n, _ in uses:
        if abs(n[0]) < 0.35 or abs(p[0]) < 5.0:
            marks.add(0)
            break
        marks.add(cow_skull((p[2] - COW_BADGE[0]) / COW_BADGE[2], (p[1] - COW_BADGE[1]) / COW_BADGE[2]))
    if len(marks) == 1 and 0 not in marks:
        return {1: (20, 12, 12), 2: (104, 8, 8), 3: (230, 220, 196), 4: (30, 10, 10)}[marks.pop()]
    # meat hooks on the lower cabin sides: a dark meat-locker panel, a steel rail and hooks, two of them with meat. A texel
    # shared with another part still gets the hooks (the strongest mark of the uses in the hook zone wins), so they stay
    # whole across the UV seams.
    mark = 0
    z0, z1 = HOOK_Z0 - 0.55 * HOOK_SIZE, HOOK_Z0 + HOOK_STEP * (HOOK_COUNT - 1) + 0.55 * HOOK_SIZE
    for p, n, _ in uses:
        if abs(n[0]) < 0.2 or abs(p[0]) > 16.0 or not (z0 < p[2] < z1):
            continue
        t = (p[1] - HOOK_RAIL_Y) / HOOK_SIZE
        k = min(HOOK_COUNT - 1, max(0, round((p[2] - HOOK_Z0) / HOOK_STEP)))
        if abs(t) < 0.08:
            m = 2
        elif abs(t) < 0.14:
            m = 1
        elif -1.4 < t < 0:
            m = meat_hook((p[2] - (HOOK_Z0 + k * HOOK_STEP)) / HOOK_SIZE, t, k >= HOOK_COUNT - 2) or 5
        else:
            m = 0
        mark = m if m and (not mark or m < 5 and (mark == 5 or m > mark)) else mark
    if mark:
        c = {1: (20, 14, 14), 2: (206, 204, 198), 3: (236, 112, 104), 4: (252, 238, 218), 5: (34, 20, 18)}[mark]
    return c


COW_BADGE = (27.0, -0.4, 3.6)  # z, y of the centre, size (Chopper frame)
HOOK_RAIL_Y, HOOK_SIZE, HOOK_Z0, HOOK_STEP, HOOK_COUNT = -5.6, 5.0, 10.0, 6.0, 4


def paint_rotor(base, tint, alpha_gain=1.15):
    """The 32x32 RGBA rotor blur: the same alpha (shape of the blur), recoloured."""
    out = []
    for r in base:
        row = []
        for c in r:
            v = (c[0] + c[1] + c[2]) / (3 * 255.0)
            red = clamp((c[0] - c[2]) / 80.0)
            col = mix(tint[0], tint[1], red)
            col = scl(col, 0.6 + 0.6 * v)
            row.append((col[0], col[1], col[2], clamp(c[3] * alpha_gain, 0, 255)))
        out.append(row)
    return out


# ---------------------------------------------------------------- shape edits (Chopper-node-local coordinates)
DEFORM_BLACK = {"select": "ChopperShape*", "ops": [
    # a longer, pointed, dropped nose
    {"op": "region", "box": [[-16, -15, 26], [16, 15, 42]], "falloff": 8,
     "then": [{"op": "scale", "s": [0.8, 0.82, 1.0], "about": [0, -3, 26]}]},
    {"op": "region", "box": [[-12, -15, 33], [12, 13, 42]], "falloff": 7,
     "then": [{"op": "scale", "s": [0.6, 0.62, 1.5], "about": [0, -5, 33]}, {"op": "translate", "t": [0, -2.5, 1.5]}]},
    # the tail boom sags between the cabin and the fin
    {"op": "region", "box": [[-8, 0, -29], [8, 13, -19]], "falloff": 5,
     "then": [{"op": "translate", "t": [0, -3.0, 0]}]},
    # a taller, swept fin, scaled about the rear rotor hub so the rotor stays on it
    {"op": "region", "box": [[-14, -4, -40], [14, 21, -31]], "falloff": 2.5,
     "then": [{"op": "scale", "s": [1.0, 1.45, 1.25], "about": [-2.59, 8.65, -33.33]}]},
]}

DEFORM_CARRION = {"select": "ChopperShape*", "ops": [
    # a hooked vulture beak: the round nose tapers to a point, stretches forward and hooks down
    {"op": "region", "box": [[-20, -25, 37], [20, 25, 50]], "falloff": 12,
     "then": [{"op": "scale", "s": [0.4, 0.5, 1.0], "about": [0, -4, 0]}]},
    {"op": "region", "box": [[-20, -25, 40], [20, 25, 50]], "falloff": 12,
     "then": [{"op": "translate", "t": [0, 0, 10]}]},
    {"op": "region", "box": [[-20, -30, 47], [20, 30, 62]], "falloff": 12,
     "then": [{"op": "translate", "t": [0, -9, 0]}]},
    {"op": "region", "box": [[-20, -30, 50], [20, 30, 62]], "falloff": 4,
     "then": [{"op": "translate", "t": [0, -5, -1.5]}]},
    # a sagging crop under the beak
    {"op": "region", "box": [[-12, -30, 24], [12, -9, 33]], "falloff": 5,
     "then": [{"op": "translate", "t": [0, -3.5, 0]}, {"op": "scale", "s": [1.15, 1.0, 1.0], "about": [0, -12, 28]}]},
    # knobbly bone all over
    {"op": "noise", "amp": 0.35, "freq": 0.22, "seed": 41},
]}


MODELS = [
    {"slug": "black_gunship", "vanilla": "BomberHelicopter", "name": "kindjal.BlackGunship", "section": 511,
     "deform": DEFORM_BLACK, "paint": paint_black_gunship, "rotor": ((70, 70, 74), (200, 30, 22))},
    {"slug": "carrion_gunship", "vanilla": "SuperAirstrike", "name": "kindjal.CarrionGunship", "section": 512,
     "deform": DEFORM_CARRION, "paint": paint_carrion_gunship, "rotor": ((226, 214, 186), (150, 12, 10))},
]


# ---------------------------------------------------------------- build
def run(cmd):
    r = subprocess.run([str(c) for c in cmd], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"{' '.join(str(c) for c in cmd)}\n{r.stdout}\n{r.stderr}")
    return r.stdout


def build(model, out_dir, work, xomtool, bundl09, gltf_dir=None):
    slug = model["slug"]
    work = Path(work) / slug
    (work / "uv").mkdir(parents=True, exist_ok=True)
    common = [xomtool, "clone", model["vanilla"], "--from", bundl09, "--as", model["name"], "--section", model["section"]]
    # 1. the vanilla clone: atlas, UV islands and geometry
    run(common + ["--bundle", work / "vanilla.xom", "--uv-layout", work / "uv", "--out-gltf", work / "vanilla.gltf"])
    shapes = load_shapes(work / "vanilla.gltf")
    textures = []
    for k in (0, 1):
        info = json.loads((work / "uv" / f"image{k}.json").read_text())
        w, h, base = read_png(work / "uv" / info["originalPng"])
        if (w, h) != (info["image"]["width"], info["image"]["height"]):
            raise RuntimeError(f"{slug}: image {k} is {w}x{h}")
        png = work / f"image{k}.png"
        if k == 0:
            names = sorted({i["shape"] for i in info["islands"]})
            write_png(png, model["paint"](base, texel_map(shapes, names, w, h)))
        else:
            write_png(png, paint_rotor(base, model["rotor"]), alpha=True)
        textures.append(png)
    deform = work / "deform.json"
    deform.write_text(json.dumps(model["deform"], indent=1))
    # 2. the kindjal bank
    out = Path(out_dir) / (model["name"] + ".xom")
    cmd = common + ["--bundle", out, "--deform", deform]
    for k, png in enumerate(textures):
        cmd += ["--texture", f"{k}={png}"]
    if gltf_dir:
        Path(gltf_dir).mkdir(parents=True, exist_ok=True)
        cmd += ["--out-gltf", Path(gltf_dir) / (slug + ".gltf")]
        for k, png in enumerate(textures):
            shutil.copyfile(png, Path(gltf_dir) / f"{slug}.image{k}.png")
    run(cmd)
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--xomtool", default=XOMTOOL)
    ap.add_argument("--bundl09", default=BUNDL09)
    ap.add_argument("--check", action="store_true", help="rebuild into a temp dir and compare with the banks on disk")
    ap.add_argument("--gltf-dir", help="also write the deformed glTFs and painted textures here (preview)")
    ap.add_argument("--only", action="append", help="build only this slug (repeatable)")
    a = ap.parse_args(argv)
    models = [m for m in MODELS if not a.only or m["slug"] in a.only]
    bad = 0
    with tempfile.TemporaryDirectory(prefix="kindjal-air-") as tmp:
        out_dir = Path(tmp) / "out" if a.check else OUT_DIR
        out_dir.mkdir(parents=True, exist_ok=True)
        for m in models:
            built = build(m, out_dir, Path(tmp) / "work", a.xomtool, a.bundl09, a.gltf_dir)
            if a.check:
                ref = OUT_DIR / built.name
                same = ref.exists() and ref.read_bytes() == built.read_bytes()
                bad += not same
                print(f"{'ok  ' if same else 'DIFF'} {ref}")
            else:
                print(f"wrote {built} ({built.stat().st_size} bytes)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
