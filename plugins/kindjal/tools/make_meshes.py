#!/usr/bin/env python3
"""Generate Kindjal's weapon meshes into tools/meshes/ (glTF 2.0 + .bin + texture PNG, one set per weapon).

    python make_meshes.py            write the files
    python make_meshes.py --check    regenerate in memory and compare byte for byte with the files on disk

nail_bat      replaces BaseballBat      tapered bat, grip knob, tape wrap, 12 cone nails
acid_flask    replaces GasCanister      round-bottomed glass flask, neck, lip, cork, crack painted in the glass
acid_round    replaces Bazooka.Payload  a corroded shell, corrosion pits carved into the surface
crucible      replaces HolyHandGrenade  a cracked black orb with ember seams and a flared rim

Every mesh is ONE primitive (positions, normals, uv0, u16 indices) with one baseColorTexture, built with the same
scale, origin and orientation as the vanilla asset it replaces (the reference boxes are measured, see VANILLA below and
README-meshes.md). Geometry is built from surfaces of revolution plus a few loose parts (the nails). A part is closed,
so its winding is fixed by its signed volume; normals are accumulated per smoothing group, so a crease is just a
profile break. The textures are painted per pixel from periodic value noise and from the same analytic description
the geometry was carved with (crack lines, pit centres), so the paint lines up with the relief. The tools/ folder
does not ship in the store zip; these are ready for whichever mesh loader picks them up. Original art, nothing from
the game. Fixed seeds, stdlib only, deterministic.
"""
import argparse
import json
import math
import random
import struct
import sys
import zlib
from pathlib import Path

OUT = Path(__file__).resolve().parent / "meshes"
TEX = 128  # every texture is 128x128
TAU = math.tau

# Vanilla reference boxes, measured with xomtool convert <name> --from Bundl09.xom and with the node matrix applied
# (min, max). Our boxes must agree within TOL on every axis (size and centre).
VANILLA = {
    "nail_bat": ("BaseballBat", (-2.887, -12.581, -2.855), (2.887, 13.295, 2.855), 504),
    "acid_flask": ("GasCanister", (-4.519, -6.006, -4.519), (4.519, 6.006, 4.519), 496),
    "acid_round": ("Bazooka.Payload", (-2.513, -2.423, -3.077), (2.512, 2.401, 3.619), 120),
    "crucible": ("HolyHandGrenade", (-5.323, -5.144, -7.076), (5.317, 5.146, 6.800), 575),
}
TOL = 0.10
TRI_MIN, TRI_MAX = 300, 900


# ---------------------------------------------------------------- small maths
def sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def add(a, b):
    return (a[0] + b[0], a[1] + b[1], a[2] + b[2])


def mul(a, k):
    return (a[0] * k, a[1] * k, a[2] * k)


def dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def length(a):
    return math.sqrt(dot(a, a))


def unit(a):
    n = length(a)
    return (a[0] / n, a[1] / n, a[2] / n) if n > 1e-12 else (0.0, 1.0, 0.0)


def clamp(x, lo=0.0, hi=1.0):
    return lo if x < lo else hi if x > hi else x


def lerp(a, b, t):
    return a + (b - a) * t


def mix(c0, c1, t):
    t = clamp(t)
    return (c0[0] + (c1[0] - c0[0]) * t, c0[1] + (c1[1] - c0[1]) * t, c0[2] + (c1[2] - c0[2]) * t)


def smooth(e0, e1, x):
    t = clamp((x - e0) / (e1 - e0))
    return t * t * (3 - 2 * t)


def shade(c, k):
    return (c[0] * k, c[1] * k, c[2] * k)


def wrapdiff(a, b):
    """Signed difference of two positions on a period-1 circle."""
    return ((a - b + 0.5) % 1.0) - 0.5


def seg_dist(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    t = clamp(((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy or 1.0))
    return math.hypot(px - (ax + dx * t), py - (ay + dy * t))


# ---------------------------------------------------------------- noise (periodic on both axes, period 1)
class Noise:
    def __init__(self, seed, nx, ny):
        rng = random.Random(seed)
        self.nx, self.ny = nx, ny
        self.g = [[rng.random() for _ in range(nx)] for _ in range(ny)]

    def at(self, a, t):
        x, y = a * self.nx, t * self.ny
        ix, iy = math.floor(x), math.floor(y)
        fx, fy = x - ix, y - iy
        fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
        x0, x1 = ix % self.nx, (ix + 1) % self.nx
        y0, y1 = iy % self.ny, (iy + 1) % self.ny
        g = self.g
        top = g[y0][x0] + (g[y0][x1] - g[y0][x0]) * fx
        bot = g[y1][x0] + (g[y1][x1] - g[y1][x0]) * fx
        return top + (bot - top) * fy


class Fbm:
    def __init__(self, seed, nx, ny, octaves=4, gain=0.55):
        self.layers = [Noise(seed * 101 + i, nx * 2 ** i, ny * 2 ** i) for i in range(octaves)]
        self.gain = gain
        self.norm = sum(gain ** i for i in range(octaves))

    def at(self, a, t):
        return sum(n.at(a, t) * self.gain ** i for i, n in enumerate(self.layers)) / self.norm


# ---------------------------------------------------------------- mesh building
class Mesh:
    def __init__(self):
        self.pos, self.uv, self.grp, self.tris = [], [], [], []
        self._t0 = 0

    def vert(self, p, uv, grp):
        self.pos.append(p)
        self.uv.append(uv)
        self.grp.append(grp)
        return len(self.pos) - 1

    def tri(self, a, b, c):
        pa, pb, pc = self.pos[a], self.pos[b], self.pos[c]
        if length(cross(sub(pb, pa), sub(pc, pa))) < 1e-9:  # collapsed (pole): drop
            return
        self.tris.append((a, b, c))

    def begin_part(self):
        self._t0 = len(self.tris)

    def end_part(self):
        """Parts are closed, so the sign of the enclosed volume says whether the winding faces outward."""
        vol = 0.0
        for a, b, c in self.tris[self._t0:]:
            vol += dot(self.pos[a], cross(self.pos[b], self.pos[c]))
        if vol < 0:
            self.tris[self._t0:] = [(a, c, b) for a, b, c in self.tris[self._t0:]]

    def finish(self):
        """Compact unused vertices, accumulate area-weighted normals per (group, position), return flat arrays."""
        used = sorted({i for t in self.tris for i in t})
        remap = {old: new for new, old in enumerate(used)}
        pos = [self.pos[i] for i in used]
        uv = [self.uv[i] for i in used]
        grp = [self.grp[i] for i in used]
        tris = [(remap[a], remap[b], remap[c]) for a, b, c in self.tris]

        def key(i):
            p = pos[i]
            return (grp[i], round(p[0] * 1e4), round(p[1] * 1e4), round(p[2] * 1e4))

        acc = {}
        for a, b, c in tris:
            n = cross(sub(pos[b], pos[a]), sub(pos[c], pos[a]))
            for i in (a, b, c):
                k = key(i)
                acc[k] = add(acc.get(k, (0.0, 0.0, 0.0)), n)
        nrm = [unit(acc[key(i)]) for i in range(len(pos))]
        return pos, nrm, uv, tris


def place(axis, ax, r, th):
    c, s = math.cos(th), math.sin(th)
    if axis == 1:
        return (r * c, ax, r * s)
    return (r * c, r * s, ax)


def revolve(mesh, gid, strips, segs, axis):
    """One closed surface of revolution. A strip is {pts:[(axis position, radius)..], rect:(x0,y0,x1,y1) in texels,
    vmode:'ax'|'arc', range:(lo,hi), disp:fn(p, theta, ax, r)->p}. Strips are separate smoothing groups, so the join
    between two strips is a hard crease. The texture rect maps u around the axis and v along it (v=0 at the high end
    for 'ax'; from the first point for 'arc')."""
    mesh.begin_part()
    for si, s in enumerate(strips):
        pts = s["pts"]
        x0, y0, x1, y1 = s["rect"]
        lo, hi = s.get("range", (min(p[0] for p in pts), max(p[0] for p in pts)))
        cum = [0.0]
        for k in range(1, len(pts)):
            cum.append(cum[-1] + math.hypot(pts[k][0] - pts[k - 1][0], pts[k][1] - pts[k - 1][1]))
        disp = s.get("disp")
        rings = []
        for k, (ax, r) in enumerate(pts):
            t = (hi - ax) / (hi - lo) if s.get("vmode", "ax") == "ax" else cum[k] / cum[-1]
            ring = []
            for j in range(segs + 1):
                th = TAU * j / segs
                p = place(axis, ax, r, th)
                if disp:
                    p = disp(p, th, ax, r)
                uv = ((x0 + (x1 - x0) * j / segs) / TEX, (y0 + (y1 - y0) * t) / TEX)
                ring.append(mesh.vert(p, uv, (gid, si)))
            rings.append((ring, r))
        for k in range(len(rings) - 1):
            (r0, rad0), (r1, rad1) = rings[k], rings[k + 1]
            for j in range(segs):
                a0, a1, b0, b1 = r0[j], r0[j + 1], r1[j], r1[j + 1]
                if rad0 < 1e-9:
                    mesh.tri(a0, b0, b1)
                elif rad1 < 1e-9:
                    mesh.tri(a0, b0, a1)
                else:
                    mesh.tri(a0, b0, b1)
                    mesh.tri(a0, b1, a1)
    mesh.end_part()


def cone(mesh, gid, base, tip, radius, sides, rect):
    """A closed cone (side + base fan) from a base centre to a tip; u around, v tip to base."""
    mesh.begin_part()
    axis = unit(sub(tip, base))
    helper = (0.0, 1.0, 0.0) if abs(axis[1]) < 0.9 else (1.0, 0.0, 0.0)
    e1 = unit(cross(axis, helper))
    e2 = cross(axis, e1)
    x0, y0, x1, y1 = rect
    ring, apex = [], []
    for j in range(sides + 1):
        th = TAU * j / sides
        p = add(base, add(mul(e1, radius * math.cos(th)), mul(e2, radius * math.sin(th))))
        u = (x0 + (x1 - x0) * j / sides) / TEX
        ring.append(mesh.vert(p, (u, y1 / TEX), (gid, "side")))
        apex.append(mesh.vert(tip, ((x0 + (x1 - x0) * (j + 0.5) / sides) / TEX, y0 / TEX), (gid, "side")))
    for j in range(sides):
        mesh.tri(ring[j], ring[j + 1], apex[j])
    centre = mesh.vert(base, ((x0 + x1) / 2 / TEX, y1 / TEX), (gid, "base"))
    bring = [mesh.vert(mesh.pos[ring[j]], mesh.uv[ring[j]], (gid, "base")) for j in range(sides + 1)]
    for j in range(sides):
        mesh.tri(centre, bring[j + 1], bring[j])
    mesh.end_part()


def profile_r(pts, ax):
    """Linear interpolation of a profile's radius at an axis position (profile is ordered by ax)."""
    for k in range(len(pts) - 1):
        a0, r0 = pts[k]
        a1, r1 = pts[k + 1]
        if a0 <= ax <= a1 and a1 > a0:
            return lerp(r0, r1, (ax - a0) / (a1 - a0))
    return pts[-1][1] if ax > pts[-1][0] else pts[0][1]


# ---------------------------------------------------------------- texture painting
class Texture:
    """128x128 RGB. Regions are painted as fn(a, t) -> (r, g, b) with a, t in 0..1 across the region (a wraps around
    the axis, t runs top to bottom). Every region is first painted 3 texels past its edge (so bilinear filtering and
    mips never see a neighbour), then all regions are painted exactly over the top."""

    def __init__(self, base=(92.0, 84.0, 76.0)):
        self.px = [[base] * TEX for _ in range(TEX)]  # unused texels take a neutral base colour (a tone of the part), never black
        self.jobs = []

    def region(self, rect, fn, wrap=True):
        self.jobs.append((rect, fn, wrap))

    def render(self):
        for pad in (3, 0):
            for (x0, y0, x1, y1), fn, wrap in self.jobs:
                for py in range(max(0, y0 - pad), min(TEX, y1 + pad)):
                    t = clamp((py + 0.5 - y0) / (y1 - y0))
                    row = self.px[py]
                    for px in range(max(0, x0 - pad), min(TEX, x1 + pad)):
                        a = (px + 0.5 - x0) / (x1 - x0)
                        a = a % 1.0 if wrap else clamp(a)
                        row[px] = fn(a, t)
        return self

    def png(self):
        raw = bytearray()
        for row in self.px:
            raw.append(0)
            for c in row:
                raw += bytes((int(clamp(c[0], 0, 255) + 0.5), int(clamp(c[1], 0, 255) + 0.5), int(clamp(c[2], 0, 255) + 0.5)))
        return write_png(bytes(raw), TEX, TEX)


def write_png(raw, w, h):
    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


# ================================================================= NAIL BAT
# Axis Y, grip knob at -Y, hitting end at +Y, origin where the vanilla bat has it.
BAT_LO, BAT_HI = -12.58, 13.295
BAT_SEGS = 12
BAT_BODY = (1, 1, 95, 127)
BAT_NAILRECT = (100, 2, 126, 26)
BAT_BARREL = [(-3.0, 1.26), (-2.1, 1.38), (0.0, 1.62), (1.5, 1.80), (3.0, 1.95), (5.0, 2.15), (7.0, 2.27),
              (9.0, 2.35), (10.5, 2.30), (11.8, 2.10), (12.7, 1.75), (13.15, 1.20), (BAT_HI, 0.0)]


def bat_nails():
    """(angle fraction, y) of each nail, a golden-angle spiral up the barrel; shared by geometry and paint."""
    rng = random.Random(1313)
    out = []
    for i in range(12):
        y = 3.2 + 8.2 * i / 11 + rng.uniform(-0.25, 0.25)
        out.append(((i * 0.381966 + rng.uniform(-0.03, 0.03)) % 1.0, y, rng.uniform(-0.2, 0.2)))
    return out


def build_bat():
    mesh = Mesh()
    strips = [
        dict(pts=[(-12.58, 0.0), (-12.42, 0.95), (-11.95, 1.65), (-11.2, 2.0), (-10.4, 2.05), (-9.7, 1.7),
                  (-9.2, 1.1), (-9.0, 0.92)]),
        dict(pts=[(-9.0, 0.92), (-7.6, 0.90), (-6.7, 0.95)]),
        dict(pts=[(-6.7, 0.95), (-6.65, 1.05), (-5.6, 1.10), (-4.6, 1.15), (-3.6, 1.28), (-3.05, 1.36),
                  (-3.0, 1.26)]),
        dict(pts=BAT_BARREL),
    ]
    for s in strips:
        s["rect"], s["range"] = BAT_BODY, (BAT_LO, BAT_HI)
    revolve(mesh, "bat", strips, BAT_SEGS, 1)
    for n, (a, y, tilt) in enumerate(bat_nails()):
        th = TAU * a
        radial = (math.cos(th), 0.0, math.sin(th))
        d = unit(add(mul(radial, math.cos(tilt)), (0.0, math.sin(tilt), 0.0)))
        r = profile_r(BAT_BARREL, y)
        surface = (radial[0] * r, y, radial[2] * r)
        cone(mesh, ("nail", n), sub(surface, mul(d, 0.30)), add(surface, mul(d, 0.66)), 0.30, 5, BAT_NAILRECT)
    return mesh


def paint_bat():
    grain = Fbm(11, 26, 3, 3)
    fine = Fbm(12, 70, 5, 2)
    blood = Fbm(13, 5, 4, 4)
    spat = Fbm(14, 24, 20, 2)
    rust = Fbm(15, 6, 6, 4)
    cloth = Fbm(16, 40, 40, 2)
    nails = bat_nails()
    circ = TAU * 2.0
    span = BAT_HI - BAT_LO

    def body(a, t):
        y = BAT_HI - t * span
        g = grain.at(a, t * 0.5)
        col = mix((46, 28, 17), (104, 66, 38), smooth(0.3, 0.75, g))
        col = shade(col, 0.86 + 0.3 * fine.at(a, t))
        if y < -9.0:  # knob: worn pale wood, a dark leather lanyard band
            col = mix(col, (150, 106, 66), 0.35 * smooth(0.4, 0.7, g))
            col = mix(col, (36, 24, 16), smooth(1.0, 0.4, abs(y + 9.55) / 0.35))
        if -6.75 < y < -2.95:  # wrapped cloth tape, spiral stripes with a dark seam
            ph = (a * 3.0 + (y + 6.7) * 0.42) % 1.0
            tape = mix((124, 114, 96), (88, 78, 64), cloth.at(a, t))
            tape = shade(tape, 0.78 + 0.22 * smooth(0.0, 0.18, ph) * smooth(1.0, 0.82, ph))
            if ph < 0.05:
                tape = (36, 30, 24)
            edge = smooth(0.0, 0.18, min(y + 6.75, -2.95 - y))
            col = mix(col, tape, edge)
            col = mix(col, (90, 16, 12), 0.5 * smooth(0.66, 0.74, blood.at(a, t)))
        if y > 1.4:  # barrel: dried blood and spatter, thickest where it hits
            m = smooth(1.4, 5.0, y)
            b = smooth(0.6, 0.68, blood.at(a, t)) * m
            col = mix(col, mix((104, 16, 12), (56, 8, 8), spat.at(a, t)), 0.88 * b)
            col = mix(col, (70, 10, 9), 0.9 * smooth(0.76, 0.82, spat.at(a, t)) * m)
        if y > 12.55:  # end grain
            ring = 0.5 + 0.5 * math.sin((13.3 - y) * 24 + 4 * grain.at(a, 0.2))
            col = mix(col, mix((58, 36, 22), (96, 62, 36), ring), smooth(12.55, 12.95, y))
        for na, ny, _ in nails:  # each nail has a puncture: dark hole, rusty rim, a blood run below it
            dx, dy = wrapdiff(a, na) * circ, y - ny
            d = math.hypot(dx, dy)
            if d < 0.62:
                col = mix(col, (104, 44, 20), smooth(0.62, 0.34, d))
                col = mix(col, (14, 8, 6), smooth(0.36, 0.2, d))
            if abs(dx) < 0.13 and -1.6 < dy < 0:
                col = mix(col, (86, 12, 10), 0.8 * smooth(0.13, 0.04, abs(dx)) * smooth(-1.6, -0.2, dy))
        return col

    def nail(a, t):
        n = rust.at(a, t)
        col = mix((86, 82, 80), (150, 76, 30), smooth(0.4, 0.7, n))
        col = mix(col, (176, 172, 164), 0.5 * smooth(0.0, 0.5, 0.5 - t) * (1 - smooth(0.5, 0.7, n)))
        return shade(col, 0.9 + 0.2 * fine.at(a, t))

    tex = Texture((58.0, 37.0, 24.0))  # unused texels are plain dark wood, not a grey block
    tex.region(BAT_BODY, body)
    tex.region(BAT_NAILRECT, nail)
    return tex.render()


# ================================================================= ACID FLASK
# Axis Y, bottle round at the bottom, cork on top. Same box and origin as GasCanister (+-4.52, +-6.0, +-4.52).
FL_SEGS = 16
FL_BODY = (1, 1, 127, 100)
FL_LIP = (1, 103, 127, 109)
FL_CORK = (1, 112, 127, 127)
FL_TOP, FL_BOT = 4.95, -6.0
FL_LIQUID = 0.9
FL_CRACK = [(0.62, 3.2), (0.60, 2.4), (0.64, 1.6), (0.61, 0.7), (0.63, -0.4), (0.58, -1.4), (0.60, -2.3)]
FL_BRANCH = [[(0.64, 1.6), (0.69, 0.9), (0.72, 0.2)], [(0.61, 0.7), (0.56, 0.1), (0.545, -0.5)]]


def build_flask():
    mesh = Mesh()
    body = [(-6.0, 0.0), (-5.92, 1.3), (-5.6, 2.4), (-5.0, 3.3), (-4.0, 4.0), (-2.8, 4.4), (-1.6, 4.5), (-0.4, 4.35),
            (0.8, 3.85), (1.8, 3.05), (2.6, 2.25), (3.3, 1.7), (3.9, 1.5), (4.5, 1.5), (4.62, 1.95), (4.95, 2.0)]
    strips = [
        dict(pts=body, rect=FL_BODY, range=(FL_BOT, FL_TOP)),
        dict(pts=[(4.95, 2.0), (4.95, 1.25)], rect=FL_LIP, vmode="arc"),
        dict(pts=[(4.95, 1.25), (5.4, 1.35), (5.9, 1.45), (6.0, 1.3), (6.0, 0.0)], rect=FL_CORK, range=(4.95, 6.0)),
    ]
    revolve(mesh, "flask", strips, FL_SEGS, 1)
    return mesh


def paint_flask():
    swirl = Fbm(21, 5, 5, 4)
    fine = Fbm(22, 30, 30, 2)
    pore = Fbm(23, 34, 12, 2)
    arc = TAU * 4.0
    rng = random.Random(2121)
    bubbles = [(rng.random(), rng.uniform(-5.2, 0.5), rng.uniform(0.18, 0.5)) for _ in range(16)]

    def body(a, t):
        y = FL_TOP - t * (FL_TOP - FL_BOT)
        surface = FL_LIQUID + 0.1 * math.sin(TAU * a * 3)
        glass = mix((164, 214, 180), (110, 170, 130), smooth(0.5, 1.0, abs(wrapdiff(a, 0.0)) * 2) * 0.6)
        if y < surface:
            deep = smooth(surface, -5.5, y)
            col = mix((178, 238, 58), (40, 138, 12), deep)
            col = mix(col, (214, 252, 90), 0.5 * smooth(0.5, 0.8, swirl.at(a, t)))
            col = mix(col, glass, 0.18)
            for ba, by, br in bubbles:
                d = math.hypot(wrapdiff(a, ba) * arc, y - by)
                if d < br + 0.1:
                    col = mix(col, (236, 255, 160), 0.85 * smooth(0.07, 0.0, abs(d - br)))
                    col = mix(col, shade(col, 1.18), 0.5 * smooth(br, 0.0, d))
                hd = math.hypot(wrapdiff(a, ba) * arc + br * 0.35, y - by - br * 0.35)
                if hd < br * 0.22:
                    col = mix(col, (255, 255, 235), 0.9)
            col = mix(col, (230, 255, 130), smooth(0.14, 0.0, abs(y - surface)))
        else:
            col = glass
            col = shade(col, 0.94 + 0.12 * fine.at(a, t))
        for ha, hw, hs in ((0.14, 0.022, 0.55), (0.70, 0.035, 0.22)):  # window-light streaks
            s = math.exp(-((wrapdiff(a, ha) / hw) ** 2)) * smooth(-5.4, -4.6, y) * smooth(3.6, 3.0, y) * hs
            col = mix(col, (255, 255, 245), s)
        # the crack: a pale fracture with a dark edge, plus two branches
        d = 9.0
        for chain in [FL_CRACK] + FL_BRANCH:
            for (a0, y0), (a1, y1) in zip(chain, chain[1:]):
                d = min(d, seg_dist(a * arc, y, a0 * arc, y0, a1 * arc, y1))
        col = mix(col, (24, 56, 28), 0.8 * smooth(0.4, 0.2, d))  # d is in model units; a texel is ~0.2 x 0.1 of them
        col = mix(col, (240, 252, 225), smooth(0.2, 0.08, d))
        # a bead of acid seeping out where the crack reaches the bottom of the chain
        sd = math.hypot((a - 0.60) * arc, y + 2.55)
        col = mix(col, (210, 255, 70), smooth(0.34, 0.2, sd))
        return col

    def lip(a, t):
        return shade(mix((52, 70, 40), (36, 46, 28), fine.at(a, t)), 1.0)

    def cork(a, t):
        p = pore.at(a, t)
        col = mix((184, 134, 82), (150, 106, 62), smooth(0.35, 0.7, fine.at(a, t)))
        col = mix(col, (96, 62, 34), 0.8 * smooth(0.66, 0.74, p))
        return shade(col, 0.82 + 0.3 * t)

    tex = Texture()
    tex.region(FL_BODY, body)
    tex.region(FL_LIP, lip)
    tex.region(FL_CORK, cork)
    return tex.render()


# ================================================================= ACID ROUND
# Axis Z, nose at +Z, nozzle at -Z. Vanilla Bazooka.Payload box with its node offset (0, 0, +0.066) applied.
RD_SEGS = 20
RD_Z = 0.066
RD_BODY = (1, 1, 127, 100)
RD_NOZ = (1, 104, 127, 112)  # the nozzle is three strips (floor of the bell, its slope, the flat rim ring)
RD_NOZ2 = (1, 114, 127, 120)
RD_NOZ3 = (1, 122, 127, 127)
RD_MAIN = [(-3.14, 1.85), (-2.7, 1.95), (-2.1, 2.2), (-1.4, 2.38), (-0.7, 2.48), (0.0, 2.5), (0.7, 2.5), (1.4, 2.42),
           (2.0, 2.2), (2.5, 1.9), (2.95, 1.4), (3.3, 0.75), (3.553, 0.0)]
RD_MAIN = [(z + RD_Z, r) for z, r in RD_MAIN]
RD_NOZZLE = [[(-2.75 + RD_Z, 0.0), (-2.75 + RD_Z, 0.9)], [(-2.75 + RD_Z, 0.9), (-3.14 + RD_Z, 1.25)],
             [(-3.14 + RD_Z, 1.25), (-3.14 + RD_Z, 1.85)]]


def round_pits():
    """(angle fraction, z, radius, depth) of each corrosion pit; shared by geometry and paint."""
    rng = random.Random(4242)
    out = []
    for _ in range(16):
        out.append((rng.random(), rng.uniform(-1.9, 2.7) + RD_Z, rng.uniform(0.38, 0.72), rng.uniform(0.12, 0.24)))
    return out


def pit_field(theta, z, pits):
    """Sum of pit bumps (each in 0..1) at a surface point, distances measured as arc length / axial length."""
    r = profile_r(RD_MAIN, z)
    total, nearest = 0.0, 9.0
    for pa, pz, rho, depth in pits:
        d = math.hypot(wrapdiff(theta / TAU, pa) * TAU * r, z - pz)
        nearest = min(nearest, d / rho)
        if d < rho:
            total += depth * (1 - (d / rho) ** 2) ** 2
    return total, nearest


def build_round():
    mesh = Mesh()
    pits = round_pits()

    def disp(p, th, ax, r):
        k, _ = pit_field(th, ax, pits)
        if k == 0.0 or r < 1e-6:
            return p
        s = (r - k) / r
        return (p[0] * s, p[1] * s, p[2])

    strips = [
        dict(pts=RD_NOZZLE[0], rect=RD_NOZ, vmode="arc"),
        dict(pts=RD_NOZZLE[1], rect=RD_NOZ2, vmode="arc"),
        dict(pts=RD_NOZZLE[2], rect=RD_NOZ3, vmode="arc"),
        dict(pts=RD_MAIN, rect=RD_BODY, range=(RD_MAIN[0][0], RD_MAIN[-1][0]), disp=disp),
    ]
    revolve(mesh, "round", strips, RD_SEGS, 2)
    return mesh


def paint_round():
    metal = Fbm(31, 7, 5, 4)
    fine = Fbm(32, 44, 30, 2)
    rust = Fbm(33, 5, 4, 4)
    streak = Fbm(34, 19, 2, 3)
    soot = Fbm(35, 8, 4, 3)
    pits = round_pits()
    lo, hi = RD_MAIN[0][0], RD_MAIN[-1][0]

    def body(a, t):
        z = hi - t * (hi - lo)
        col = mix((70, 80, 52), (96, 104, 68), metal.at(a, t))
        col = shade(col, 0.88 + 0.24 * fine.at(a, t))
        for z0, z1, c in ((2.0, 2.45, (196, 160, 36)), (-1.9, -1.6, (150, 52, 36)), (0.95, 1.12, (60, 66, 44))):
            band = smooth(z0 - 0.04, z0 + 0.04, z) * smooth(z1 + 0.04, z1 - 0.04, z)  # worn stencil bands
            col = mix(col, c, band * (0.9 - 0.6 * smooth(0.5, 0.8, rust.at(a, t))))
        r = smooth(0.5, 0.68, rust.at(a, t) + 0.1 * fine.at(a, t))
        col = mix(col, mix((142, 72, 28), (96, 46, 20), fine.at(a, t)), 0.85 * r)
        s = smooth(0.58, 0.7, streak.at(a, t)) * smooth(-2.8, 2.6, z)  # acid runs down the shell, thicker toward the nose
        col = mix(col, mix((104, 196, 36), (176, 232, 64), fine.at(a, t)), 0.85 * s)
        col = mix(col, (24, 22, 18), 0.85 * smooth(-1.6, -3.1, z) * (0.5 + 0.5 * soot.at(a, t)))
        _, near = pit_field(a * TAU, z, pits)
        if near < 1.25:
            col = mix(col, (150, 78, 30), smooth(1.25, 0.85, near))
            col = mix(col, (30, 22, 14), smooth(0.8, 0.45, near))
        return col

    def nozzle(a, t):
        n = soot.at(a, t)
        col = mix((22, 20, 18), (50, 40, 34), n)
        col = mix(col, (140, 70, 26), 0.6 * smooth(0.7, 0.85, t) * smooth(1.0, 0.9, t))
        return mix(col, (200, 90, 22), 0.35 * smooth(0.1, 0.0, t) * (1 - n))

    tex = Texture()
    tex.region(RD_BODY, body)
    for rect in (RD_NOZ, RD_NOZ2, RD_NOZ3):
        tex.region(rect, nozzle)
    return tex.render()


# ================================================================= CRUCIBLE
# Axis Z with the rim at +Z, as the vanilla holy grenade has its cross. Sphere radius 5.2 centred on z=-1.9, flared rim
# to z=6.8, hollow top with a glowing bowl. The cracks are great-circle random walks on the sphere; geometry carves
# grooves along them and the paint lights them from the same description.
CR_R, CR_CZ = 5.2, -1.9
CR_SEGS = 20
CR_SPHERE = (1, 1, 127, 92)
CR_RIM = (1, 94, 127, 110)
CR_BOWL = (1, 112, 127, 127)
CR_PHI_TOP = math.radians(54.8)


def crack_segments():
    rng = random.Random(0xC0DE)
    segs = []

    def walk(p, h, steps, step, branchy):
        for i in range(steps):
            c, s = math.cos(step), math.sin(step)
            p2 = unit(add(mul(p, c), mul(h, s)))
            h2 = sub(mul(h, c), mul(p, s))
            segs.append((p, p2))
            d = rng.uniform(-0.55, 0.55)
            h2 = add(mul(h2, math.cos(d)), mul(cross(p2, h2), math.sin(d)))
            h2 = unit(sub(h2, mul(p2, dot(h2, p2))))
            if branchy and i in (1, 2) and rng.random() < 0.65:
                db = rng.choice((-1, 1)) * rng.uniform(0.7, 1.1)
                hb = add(mul(h2, math.cos(db)), mul(cross(p2, h2), math.sin(db)))
                walk(p2, unit(hb), rng.randint(3, 4), step * 0.9, False)
            p, h = p2, h2

    for i in range(6):
        lon = TAU * (i / 6 + rng.uniform(-0.05, 0.05))
        lat = rng.uniform(-0.95, 0.45)
        p = (math.cos(lat) * math.cos(lon), math.cos(lat) * math.sin(lon), math.sin(lat))
        helper = (0.0, 0.0, 1.0) if abs(p[2]) < 0.9 else (1.0, 0.0, 0.0)
        e1 = unit(cross(p, helper))
        ang = rng.uniform(0, TAU)
        h = add(mul(e1, math.cos(ang)), mul(cross(p, e1), math.sin(ang)))
        walk(p, unit(h), rng.randint(4, 6), 0.34, True)
    return segs


CRACKS = crack_segments()
LUMPS = [(rng_a, rng_f, rng_p) for rng_a, rng_f, rng_p in
         ((0.11, (3.0, 1.0, 2.0), 0.4), (0.09, (-2.0, 3.0, 1.0), 2.1), (0.07, (1.0, -3.0, 4.0), 4.0),
          (0.05, (5.0, 2.0, -3.0), 1.3))]


def crack_dist(d):
    """Angular distance in radians from a unit direction to the nearest crack."""
    best = 9.0
    for a, b in CRACKS:
        ab = sub(b, a)
        t = clamp(dot(sub(d, a), ab) / dot(ab, ab))
        q = unit(add(a, mul(ab, t)))
        c = clamp(dot(d, q), -1.0, 1.0)
        if c > 1.0 - best * best / 2:
            best = min(best, math.acos(c))
    return best


def build_crucible():
    mesh = Mesh()
    centre = (0.0, 0.0, CR_CZ)

    def carve(p, th, ax, r):
        d = unit(sub(p, centre))
        groove = max(0.0, 1.0 - crack_dist(d) / 0.21) ** 2
        lump = sum(amp * math.sin(f[0] * d[0] + f[1] * d[1] + f[2] * d[2] + ph) for amp, f, ph in LUMPS)
        return add(centre, mul(d, CR_R + lump - 0.5 * groove))

    steps = 10
    phis = [-math.pi / 2 + (CR_PHI_TOP + math.pi / 2) * i / steps for i in range(steps + 1)]
    sphere = [(CR_CZ + CR_R * math.sin(p), max(0.0, CR_R * math.cos(p))) for p in phis]
    sphere[0] = (sphere[0][0], 0.0)
    top_z = sphere[-1][0]
    strips = [
        dict(pts=sphere, rect=CR_SPHERE, range=(sphere[0][0], top_z), disp=carve),
        dict(pts=[sphere[-1], (3.2, 2.5), (4.2, 2.35), (5.2, 2.85), (6.0, 3.35), (6.8, 3.3)], rect=CR_RIM,
             range=(top_z, 6.8)),
        dict(pts=[(6.8, 3.3), (6.5, 2.85), (5.6, 2.3), (4.7, 1.4), (4.3, 0.0)], rect=CR_BOWL, vmode="arc"),
    ]
    revolve(mesh, "crucible", strips, CR_SEGS, 2)
    return mesh


def paint_crucible():
    char = Fbm(41, 9, 6, 5)
    grit = Fbm(42, 48, 32, 2)
    heat = Fbm(43, 7, 5, 4)
    spark = Fbm(44, 30, 20, 2)
    magma = Fbm(45, 6, 4, 4)
    sphere_lo, sphere_hi = -CR_R + CR_CZ, CR_CZ + CR_R * math.sin(CR_PHI_TOP)

    def sphere(a, t):
        z = sphere_hi - t * (sphere_hi - sphere_lo)
        sp = clamp((z - CR_CZ) / CR_R, -1.0, 1.0)
        cp = math.sqrt(1 - sp * sp)
        th = TAU * a
        d = (cp * math.cos(th), cp * math.sin(th), sp)
        c = crack_dist(d)
        col = mix((14, 13, 13), (46, 40, 36), smooth(0.35, 0.8, char.at(a, t)))
        col = shade(col, 0.8 + 0.4 * grit.at(a, t))
        col = mix(col, (74, 34, 18), 0.5 * smooth(0.72, 0.9, heat.at(a, t)))  # heat-tinted scale
        col = add(col, mul((130, 32, 4), 0.55 * math.exp(-c / 0.08) * (0.7 + 0.5 * heat.at(a, t))))
        col = mix(col, (236, 92, 14), smooth(0.075, 0.03, c))
        col = mix(col, (255, 214, 104), smooth(0.034, 0.012, c))
        col = mix(col, (255, 244, 190), smooth(0.014, 0.0, c) * (0.6 + 0.4 * heat.at(a, t)))
        e = smooth(0.8, 0.9, spark.at(a, t))  # a few loose embers in the char
        return mix(col, (220, 90, 24), 0.7 * e * smooth(0.3, 0.1, c))

    def rim(a, t):
        col = mix((20, 18, 17), (60, 52, 46), grit.at(a, t))
        glow = smooth(0.55, 1.0, t)  # the lip is hot from the inside
        col = mix(col, (190, 76, 14), 0.75 * glow * smooth(0.4, 0.7, heat.at(a, t)))
        return mix(col, (30, 26, 24), 0.35 * smooth(0.1, 0.0, t))

    def bowl(a, t):
        m = magma.at(a * 1.0, t)
        col = mix((176, 48, 8), (255, 168, 40), smooth(0.3, 0.75, m))
        col = mix(col, (255, 232, 140), smooth(0.65, 0.9, m) * smooth(0.4, 1.0, t))
        return mix(col, (60, 18, 6), smooth(0.16, 0.0, t) * 0.8)

    tex = Texture()
    tex.region(CR_SPHERE, sphere)
    tex.region(CR_RIM, rim)
    tex.region(CR_BOWL, bowl)
    return tex.render()


# ================================================================= glTF
def build_gltf(stem, mesh_name, mesh):
    pos, nrm, uv, tris = mesh.finish()
    n = len(pos)
    if n > 65535:
        raise ValueError(f"{stem}: {n} vertices do not fit u16 indices")
    b_pos = b"".join(struct.pack("<3f", *p) for p in pos)
    b_nrm = b"".join(struct.pack("<3f", *p) for p in nrm)
    b_uv = b"".join(struct.pack("<2f", *p) for p in uv)
    b_idx = b"".join(struct.pack("<3H", *t) for t in tris)
    b_idx += b"\0" * (-len(b_idx) % 4)
    binary = b_pos + b_nrm + b_uv + b_idx
    f32 = lambda x: struct.unpack("<f", struct.pack("<f", x))[0]
    lo = [f32(min(p[k] for p in pos)) for k in range(3)]
    hi = [f32(max(p[k] for p in pos)) for k in range(3)]
    gltf = {
        "asset": {"version": "2.0", "generator": "kindjal make_meshes.py"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"name": mesh_name, "mesh": 0}],
        "meshes": [{"name": mesh_name, "primitives": [{
            "attributes": {"POSITION": 0, "NORMAL": 1, "TEXCOORD_0": 2}, "indices": 3, "material": 0, "mode": 4}]}],
        "materials": [{"name": mesh_name, "pbrMetallicRoughness": {
            "baseColorTexture": {"index": 0}, "metallicFactor": 0.0, "roughnessFactor": 1.0}}],
        "textures": [{"sampler": 0, "source": 0}],
        "samplers": [{"magFilter": 9729, "minFilter": 9987, "wrapS": 10497, "wrapT": 10497}],
        "images": [{"uri": stem + ".png"}],
        "buffers": [{"uri": stem + ".bin", "byteLength": len(binary)}],
        "bufferViews": [
            {"buffer": 0, "byteOffset": 0, "byteLength": len(b_pos), "target": 34962},
            {"buffer": 0, "byteOffset": len(b_pos), "byteLength": len(b_nrm), "target": 34962},
            {"buffer": 0, "byteOffset": len(b_pos) + len(b_nrm), "byteLength": len(b_uv), "target": 34962},
            {"buffer": 0, "byteOffset": len(b_pos) + len(b_nrm) + len(b_uv), "byteLength": len(tris) * 6,
             "target": 34963},
        ],
        "accessors": [
            {"bufferView": 0, "componentType": 5126, "count": n, "type": "VEC3", "min": lo, "max": hi},
            {"bufferView": 1, "componentType": 5126, "count": n, "type": "VEC3"},
            {"bufferView": 2, "componentType": 5126, "count": n, "type": "VEC2"},
            {"bufferView": 3, "componentType": 5123, "count": len(tris) * 3, "type": "SCALAR"},
        ],
    }
    return (json.dumps(gltf, indent=1) + "\n").encode(), binary


# ================================================================= strict validation
def read_png_size(data):
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("png: bad signature")
    pos, w, h, idat = 8, 0, 0, b""
    seen_end = False
    while pos < len(data):
        ln, tag = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + ln]
        crc = struct.unpack(">I", data[pos + 8 + ln:pos + 12 + ln])[0]
        if zlib.crc32(tag + body) & 0xFFFFFFFF != crc:
            raise ValueError(f"png: bad crc in {tag!r}")
        if tag == b"IHDR":
            w, h, depth, ctype = struct.unpack(">IIBB", body[:10])
            if (depth, ctype) != (8, 2):
                raise ValueError("png: expected 8-bit RGB")
        elif tag == b"IDAT":
            idat += body
        elif tag == b"IEND":
            seen_end = True
        pos += 12 + ln
    if not seen_end or len(zlib.decompress(idat)) != h * (1 + 3 * w):
        raise ValueError("png: truncated or wrong decoded size")
    return w, h


def validate(stem, gltf_bytes, binary, png_bytes):
    """Re-read the glTF the way a strict loader would and check it against the vanilla reference. Returns stats."""
    g = json.loads(gltf_bytes)
    must = lambda cond, msg: (_ for _ in ()).throw(ValueError(f"{stem}: {msg}")) if not cond else None
    must(g["asset"]["version"] == "2.0", "asset.version")
    must(len(g["meshes"]) == 1 and len(g["meshes"][0]["primitives"]) == 1, "need exactly one mesh with one primitive")
    must(len(g["nodes"]) == 1 and "matrix" not in g["nodes"][0] and "translation" not in g["nodes"][0],
         "need one node with identity transform")
    prim = g["meshes"][0]["primitives"][0]
    must(prim["mode"] == 4 and set(prim["attributes"]) == {"POSITION", "NORMAL", "TEXCOORD_0"}, "primitive layout")
    must(g["buffers"][0]["byteLength"] == len(binary), "buffer byteLength")
    must(g["buffers"][0]["uri"] == stem + ".bin" and g["images"][0]["uri"] == stem + ".png", "uris")
    w, h = read_png_size(png_bytes)
    must((w, h) == (TEX, TEX), "texture is not 128x128")
    comps = {5126: ("f", 4), 5123: ("H", 2)}
    ncomp = {"SCALAR": 1, "VEC2": 2, "VEC3": 3}

    def read(acc_i):
        acc = g["accessors"][acc_i]
        view = g["bufferViews"][acc["bufferView"]]
        fmt, size = comps[acc["componentType"]]
        cnt = ncomp[acc["type"]]
        start = view.get("byteOffset", 0) + acc.get("byteOffset", 0)
        must(start % size == 0, f"accessor {acc_i} misaligned")
        must(start + acc["count"] * cnt * size <= view["byteOffset"] + view["byteLength"], f"accessor {acc_i} overruns view")
        must(view["byteOffset"] + view["byteLength"] <= len(binary), f"view {acc['bufferView']} overruns buffer")
        vals = struct.unpack_from("<" + fmt * (acc["count"] * cnt), binary, start)
        return acc, [vals[i:i + cnt] for i in range(0, len(vals), cnt)]

    pa, pos = read(prim["attributes"]["POSITION"])
    na, nrm = read(prim["attributes"]["NORMAL"])
    ta, uv = read(prim["attributes"]["TEXCOORD_0"])
    ia, idx = read(prim["indices"])
    n = pa["count"]
    must(na["count"] == n and ta["count"] == n, "attribute counts differ")
    must(ia["componentType"] == 5123 and ia["count"] % 3 == 0, "indices must be u16 triples")
    flat = [i[0] for i in idx]
    must(max(flat) < n and min(flat) >= 0, "index out of range")
    must(len(set(flat)) == n, "unreferenced vertices")
    for k in range(3):
        must(abs(min(p[k] for p in pos) - pa["min"][k]) < 1e-5 and abs(max(p[k] for p in pos) - pa["max"][k]) < 1e-5,
             "POSITION min/max do not match the data")
    must(all(abs(length(v) - 1.0) < 1e-3 for v in nrm), "normals not unit length")
    must(all(0.0 <= c <= 1.0 for t in uv for c in t), "uv outside 0..1")
    tris = [tuple(flat[i:i + 3]) for i in range(0, len(flat), 3)]
    must(all(len({a, b, c}) == 3 for a, b, c in tris), "degenerate (repeated index) triangle")
    must(all(length(cross(sub(pos[b], pos[a]), sub(pos[c], pos[a]))) > 1e-9 for a, b, c in tris), "zero-area triangle")
    # winding: vertex normals must agree with the geometric normal of the face on average (outward-facing)
    agree = sum(1 for a, b, c in tris
                if dot(cross(sub(pos[b], pos[a]), sub(pos[c], pos[a])), add(add(nrm[a], nrm[b]), nrm[c])) > 0)
    must(agree >= 0.97 * len(tris), f"winding disagrees with normals on {len(tris) - agree} triangles")
    ref, rmin, rmax, _ = VANILLA[stem]
    for k, axis in enumerate("xyz"):
        size, rsize = pa["max"][k] - pa["min"][k], rmax[k] - rmin[k]
        mid, rmid = (pa["max"][k] + pa["min"][k]) / 2, (rmax[k] + rmin[k]) / 2
        must(abs(size - rsize) <= TOL * rsize, f"{axis} size {size:.3f} vs vanilla {ref} {rsize:.3f} (over {TOL:.0%})")
        must(abs(mid - rmid) <= TOL * rsize, f"{axis} centre {mid:.3f} vs vanilla {ref} {rmid:.3f}")
    must(TRI_MIN <= len(tris) <= TRI_MAX, f"{len(tris)} triangles outside {TRI_MIN}..{TRI_MAX}")
    return {"vertices": n, "triangles": len(tris), "min": pa["min"], "max": pa["max"], "ref": ref}


# ================================================================= driver
MESHES = [
    ("nail_bat", "NailBat", build_bat, paint_bat),
    ("acid_flask", "AcidFlask", build_flask, paint_flask),
    ("acid_round", "AcidRound", build_round, paint_round),
    ("crucible", "Crucible", build_crucible, paint_crucible),
]


def generate():
    files, stats = {}, {}
    for stem, name, build, paint in MESHES:
        gltf, binary = build_gltf(stem, name, build())
        png = paint().png()
        stats[stem] = validate(stem, gltf, binary, png)
        files[stem + ".gltf"], files[stem + ".bin"], files[stem + ".png"] = gltf, binary, png
    return files, stats


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--check", action="store_true", help="compare regenerated output with the files on disk")
    args = ap.parse_args()
    files, stats = generate()
    if args.check:
        bad = [n for n, data in files.items() if not (OUT / n).is_file() or (OUT / n).read_bytes() != data]
        extra = sorted(p.name for p in OUT.glob("*") if p.is_file() and p.name not in files) if OUT.is_dir() else []
        for n in bad:
            print(f"DIFFERS: {n}")
        for n in extra:
            print(f"UNEXPECTED: {n}")
        print("meshes up to date" if not (bad or extra) else "meshes out of date: run make_meshes.py")
        sys.exit(1 if (bad or extra) else 0)
    OUT.mkdir(parents=True, exist_ok=True)
    for n, data in files.items():
        (OUT / n).write_bytes(data)
        print(f"wrote {OUT / n} ({len(data)} bytes)")
    for stem, s in stats.items():
        print(f"{stem}: {s['vertices']} verts, {s['triangles']} tris, box {s['min']} .. {s['max']} (vanilla {s['ref']})")


if __name__ == "__main__":
    main()
