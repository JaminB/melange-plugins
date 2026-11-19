#!/usr/bin/env python3
"""Generate Kindjal's weapon meshes into tools/meshes/ (glTF 2.0 + .bin + texture PNG, one set per weapon).

    python make_meshes.py            write the files
    python make_meshes.py --check    regenerate in memory and compare with the files on disk (the .png by decoded pixels, the rest byte for byte)

nail_bat      replaces BaseballBat      slim dark club, taped band with a loose cloth tail, seven long bent nails
acid_flask    replaces GasCanister      fat round flask, thick neck, oversized cork, raised skull plaque on two faces
acid_round    replaces Bazooka.Payload  a stubby shell, a dark band, three large corrosion pits pressed into the body
crucible      replaces HolyHandGrenade  a black orb with deep carved ember cracks, a heavy rim ring and iron studs

These are drawn to be read at game distance (a held weapon is about 60 px tall): big shapes, a broken silhouette, and
textures that are pushed apart (a final contrast and saturation curve per texture) because the game's lighting flattens them.

Every mesh is ONE primitive (positions, normals, uv0, u16 indices) with one baseColorTexture, built with the same
scale, origin and orientation as the vanilla asset it replaces (the reference boxes are measured, see VANILLA below and
README-meshes.md). Geometry is built from surfaces of revolution plus a few loose parts (nails, tail, studs) and a
relief patch (the skull). A part is closed, so its winding is fixed by its signed volume; normals are accumulated per
smoothing group, so a crease is just a profile break. The textures are painted per pixel from periodic value noise and
from the same analytic description the geometry was carved with (crack lines, pit centres, the skull masks), so the
paint lines up with the relief. The tools/ folder does not ship in the store zip; these are ready for whichever mesh
loader picks them up. Original art, nothing from the game. Fixed seeds, stdlib only, deterministic.
"""
import argparse
import json
import math
import random
import struct
import sys
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # the helper sits beside this file
import _pngcmp  # noqa: E402

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

    def tri_out(self, a, b, c, outward):
        """A triangle wound so its geometric normal points along `outward` (for open or thin parts, where the signed
        volume of a closed part cannot decide the winding)."""
        pa, pb, pc = self.pos[a], self.pos[b], self.pos[c]
        if dot(cross(sub(pb, pa), sub(pc, pa)), outward) < 0:
            b, c = c, b
        self.tri(a, b, c)

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


def _frames(pts):
    """Unit tangent at every point of a polyline (the average of the two neighbouring directions) and the miter factor
    that keeps a tube's width constant round a bend."""
    dirs = [unit(sub(pts[k + 1], pts[k])) for k in range(len(pts) - 1)]
    out = []
    for k in range(len(pts)):
        if k == 0:
            out.append((dirs[0], 1.0))
        elif k == len(pts) - 1:
            out.append((dirs[-1], 1.0))
        else:
            t = unit(add(dirs[k - 1], dirs[k]))
            out.append((t, 1.0 / max(0.5, dot(t, dirs[k - 1]))))
    return out


def tube(mesh, gid, pts, radii, e1, sides, rect):
    """A closed tube along a polyline, base first. `radii` is per point (0 makes a point); `e1` is a unit side vector
    that stays constant along the tube (the polyline bends in the plane perpendicular to it). u runs round the tube, v
    from the tip (top of the rect) to the base (bottom), so a texture can run steel at the tip to rust at the base."""
    mesh.begin_part()
    x0, y0, x1, y1 = rect
    cum = [0.0]
    for k in range(1, len(pts)):
        cum.append(cum[-1] + length(sub(pts[k], pts[k - 1])))
    rings = []
    for k, (p, (tan, miter)) in enumerate(zip(pts, _frames(pts))):
        e2 = unit(cross(tan, e1))
        s1 = cross(e2, tan)
        ring = []
        for j in range(sides + 1):
            th = TAU * j / sides
            q = add(p, add(mul(s1, radii[k] * miter * math.cos(th)), mul(e2, radii[k] * miter * math.sin(th))))
            ring.append(mesh.vert(q, ((x0 + (x1 - x0) * j / sides) / TEX, (y1 - (y1 - y0) * cum[k] / cum[-1]) / TEX),
                                  (gid, "side")))
        rings.append(ring)
    for k in range(len(rings) - 1):
        for j in range(sides):
            a0, a1, b0, b1 = rings[k][j], rings[k][j + 1], rings[k + 1][j], rings[k + 1][j + 1]
            mesh.tri(a0, b0, b1)
            mesh.tri(a0, b1, a1)
    centre = mesh.vert(pts[0], ((x0 + x1) / 2 / TEX, y1 / TEX), (gid, "base"))
    bring = [mesh.vert(mesh.pos[rings[0][j]], mesh.uv[rings[0][j]], (gid, "base")) for j in range(sides + 1)]
    for j in range(sides):
        mesh.tri(centre, bring[j], bring[j + 1])  # opposite to the wall's base edge (a1->a0), so the cap faces away
    mesh.end_part()


def ribbon(mesh, gid, pts, e1, width, thick, rect):
    """A thin flat strap along a polyline (a loose cloth tail): four flat faces and two end caps, each its own smoothing
    group so the edges stay crisp. `e1` is the side vector the width runs along; u runs across it, v along it."""
    x0, y0, x1, y1 = rect
    cum = [0.0]
    for k in range(1, len(pts)):
        cum.append(cum[-1] + length(sub(pts[k], pts[k - 1])))
    frames = _frames(pts)
    cors = []
    for p, (tan, _) in zip(pts, frames):
        n = unit(cross(tan, e1))
        s1 = cross(n, tan)
        w, t = mul(s1, width / 2), mul(n, thick / 2)
        cors.append([add(sub(p, w), t), add(add(p, w), t), sub(add(p, w), t), sub(sub(p, w), t)])
    verts = []
    for k, ring in enumerate(cors):
        v = (y0 + (y1 - y0) * cum[k] / cum[-1]) / TEX
        verts.append([[mesh.vert(ring[(f + c) % 4], ((x0 + (x1 - x0) * c) / TEX, v), (gid, f)) for c in (0, 1)]
                      for f in range(4)])
    for k in range(len(cors) - 1):
        centre = mul(add(add(cors[k][0], cors[k][1]), add(cors[k][2], cors[k][3])), 0.25)
        for f in range(4):
            a0, a1 = verts[k][f]
            b0, b1 = verts[k + 1][f]
            out = sub(mul(add(cors[k][f], cors[k][(f + 1) % 4]), 0.5), centre)
            mesh.tri_out(a0, b0, b1, out)
            mesh.tri_out(a0, b1, a1, out)
    for k, sign in ((0, -1.0), (len(cors) - 1, 1.0)):
        c = [mesh.vert(q, ((x0 + x1) / 2 / TEX, (y0 if k else y1) / TEX), (gid, "cap%d" % k)) for q in cors[k]]
        mesh.tri_out(c[0], c[1], c[2], mul(frames[k][0], sign))
        mesh.tri_out(c[0], c[2], c[3], mul(frames[k][0], sign))


def relief(mesh, gid, centre_y, theta0, r_of, half, cells, height, rect, reach):
    """A relief patch on a surface of revolution about the Y axis: a (cells x cells) grid in arc length u (across) and
    y (up) over a square of side 2*half around (theta0, centre_y), pushed out of the body by height(u, v) units (may
    be negative). Cells whose four corners all lie beyond `reach` of the centre are dropped, so the patch is round.
    The outer ring of vertices is sunk into the body (height() returns a negative value there), so the plaque has a
    wall instead of an open edge. Texture coordinates are planar over the whole square, u across and v down."""
    x0, y0, x1, y1 = rect
    n = cells
    grid = {}
    for iy in range(n + 1):
        for ix in range(n + 1):
            u = -half + 2 * half * ix / n
            v = half - 2 * half * iy / n
            y = centre_y + v
            r = r_of(y)
            p = place(1, y, r + height(u, v), theta0 + u / r)
            uv = ((x0 + (x1 - x0) * ix / n) / TEX, (y0 + (y1 - y0) * iy / n) / TEX)
            grid[(ix, iy)] = (p, uv, (u, v))
    used = {}

    def vid(ix, iy):
        if (ix, iy) not in used:
            p, uv, _ = grid[(ix, iy)]
            used[(ix, iy)] = mesh.vert(p, uv, (gid, 0))
        return used[(ix, iy)]

    out = (math.cos(theta0), 0.0, math.sin(theta0))
    for iy in range(n):
        for ix in range(n):
            corners = [(ix, iy), (ix + 1, iy), (ix, iy + 1), (ix + 1, iy + 1)]
            if all(math.hypot(*grid[c][2]) > reach for c in corners):
                continue
            a, b, c, d = (vid(*q) for q in corners)
            mesh.tri_out(a, c, d, out)
            mesh.tri_out(a, d, b, out)


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

    def __init__(self, base=(92.0, 84.0, 76.0), gain=1.0, sat=1.0, pivot=110.0):
        self.px = [[base] * TEX for _ in range(TEX)]  # unused texels take a neutral base colour (a tone of the part), never black
        self.jobs = []
        self.gain, self.sat, self.pivot = gain, sat, pivot  # the game's lighting flattens a texture, so each is pushed apart

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
        if self.gain != 1.0 or self.sat != 1.0:  # one contrast curve over every texel, padding included
            for row in self.px:
                for i, c in enumerate(row):
                    lum = 0.30 * c[0] + 0.59 * c[1] + 0.11 * c[2]
                    row[i] = tuple(self.pivot + (lum + (v - lum) * self.sat - self.pivot) * self.gain for v in c)
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
# Axis Y, grip knob at -Y, hitting end at +Y, origin where the vanilla bat has it. Built to be read at about 60 px: a
# slim dark club so the silhouette is broken by seven long bent nails and a loose cloth tail, not by fine detail. The
# nails (not the barrel) fill the vanilla radius, so the box still agrees with BaseballBat.
BAT_LO, BAT_HI = -12.58, 13.295
BAT_SEGS = 12
BAT_BODY = (1, 1, 95, 127)
BAT_NAILRECT = (100, 2, 126, 34)  # v runs tip (bright steel) to base (rust)
BAT_TAILRECT = (100, 40, 126, 100)
BAT_BARREL = [(-2.65, 1.30), (0.5, 1.50), (3.8, 1.66), (7.0, 1.78), (9.8, 1.80), (11.5, 1.70), (12.6, 1.40),
              (13.15, 0.80), (BAT_HI, 0.0)]
BAT_BAND = (-6.6, -2.65)  # the taped band


def bat_nails():
    """(azimuth in turns, y where it enters the wood, axial throw of the tip, radial reach of the tip) for each nail:
    seven, most of them on the two flanks so they break the silhouette from the side, one thrown downward. Shared by the geometry and the paint (puncture holes)."""
    return [(0.00, 3.0, 2.0, 2.98), (0.50, 4.4, 1.9, 2.95), (0.26, 5.9, -1.8, 2.85), (0.44, 7.2, 1.9, 2.9),
            (0.76, 8.4, 1.7, 2.9), (0.96, 9.7, 1.7, 2.9), (0.54, 11.0, 1.5, 2.85)]


def build_bat():
    mesh = Mesh()
    strips = [
        dict(pts=[(-12.58, 0.0), (-12.3, 1.2), (-11.5, 1.9), (-10.5, 2.05), (-9.7, 1.6), (-9.0, 0.92)]),
        dict(pts=[(-9.0, 0.92), (-6.6, 0.92)]),
        dict(pts=[(-6.6, 0.95), (-6.52, 1.40), (-6.2, 1.50), (-3.2, 1.52), (-2.85, 1.46), (-2.65, 1.30)]),  # the tape band stands proud of the handle and the barrel start
        dict(pts=BAT_BARREL),
    ]
    for s in strips:
        s["rect"], s["range"] = BAT_BODY, (BAT_LO, BAT_HI)
    revolve(mesh, "bat", strips, BAT_SEGS, 1)
    for n, (a, y0, dy, reach) in enumerate(bat_nails()):
        th = TAU * a
        radial = (math.cos(th), 0.0, math.sin(th))
        side = (-math.sin(th), 0.0, math.cos(th))
        rs = profile_r(BAT_BARREL, y0)
        jit = (-1) ** n * 0.10

        def at(r, y, tang=0.0):
            return add(add(mul(radial, r), (0.0, y, 0.0)), mul(side, tang))

        # base sunk in the wood, a short radial stub, then the kink and a long throw to the point
        base, kink, tip = at(rs - 0.35, y0), at(rs + 0.75, y0 + 0.10 * dy, jit * 0.5), at(reach, y0 + dy, jit)
        near = add(kink, mul(sub(tip, kink), 0.82))  # the shaft stays fat to here, then the point
        tube(mesh, ("nail", n), [base, kink, near, tip], [0.75, 0.52, 0.36, 0.0], side, 6, BAT_NAILRECT)
    # loose cloth tail hanging off the top edge of the band, a little twisted
    th = TAU * 0.62
    radial = (math.cos(th), 0.0, math.sin(th))
    side = (-math.sin(th), 0.0, math.cos(th))
    tail = [(1.50, -3.25, 0.0), (1.95, -3.7, 0.10), (2.40, -4.55, 0.22), (2.72, -5.65, 0.12), (2.78, -6.75, -0.10)]
    pts = [add(add(mul(radial, r), (0.0, y, 0.0)), mul(side, s)) for r, y, s in tail]
    ribbon(mesh, "tail", pts, side, 1.35, 0.16, BAT_TAILRECT)
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
        col = mix((44, 25, 13), (122, 72, 38), smooth(0.3, 0.75, g))  # dark wood the nails and tape stand out of, lifted so the final curve keeps grain in it
        col = shade(col, 0.8 + 0.4 * fine.at(a, t))
        if y < -9.0:  # knob: worn lighter wood, a dark leather lanyard band
            col = mix(col, (118, 76, 40), 0.45 * smooth(0.4, 0.7, g))
            col = mix(col, (14, 9, 6), smooth(1.0, 0.4, abs(y + 9.55) / 0.35))
        if BAT_BAND[0] - 0.05 < y < BAT_BAND[1] + 0.05:  # wrapped cloth tape: bright diagonal turns, dark gaps between
            ph = (a * 3.0 + (y - BAT_BAND[0]) * 0.42) % 1.0
            tape = mix((236, 228, 192), (178, 166, 130), cloth.at(a, t))
            tape = shade(tape, 0.70 + 0.30 * smooth(0.0, 0.2, ph) * smooth(1.0, 0.8, ph))
            if ph < 0.07:
                tape = (22, 17, 12)
            edge = smooth(0.0, 0.12, min(y - BAT_BAND[0], BAT_BAND[1] - y))
            col = mix(col, tape, edge)
            col = mix(col, (130, 20, 14), 0.55 * smooth(0.66, 0.74, blood.at(a, t)))
        if y > 1.4:  # barrel: dried blood and spatter, thickest where it hits
            m = smooth(1.4, 5.0, y)
            b = smooth(0.7, 0.76, blood.at(a, t)) * m
            col = mix(col, mix((176, 24, 18), (90, 10, 10), spat.at(a, t)), 0.9 * b)
            col = mix(col, (120, 14, 12), 0.9 * smooth(0.8, 0.86, spat.at(a, t)) * m)
        if y > 12.4:  # end grain
            ring = 0.5 + 0.5 * math.sin((13.3 - y) * 24 + 4 * grain.at(a, 0.2))
            col = mix(col, mix((70, 40, 22), (140, 90, 50), ring), smooth(12.4, 12.9, y))
        for na, ny, _, _ in nails:  # each nail has a puncture: dark hole, rusty rim, a blood run below it
            dx, dy = wrapdiff(a, na) * circ, y - ny
            d = math.hypot(dx, dy)
            if d < 0.9:
                col = mix(col, (150, 66, 24), smooth(0.9, 0.5, d))
                col = mix(col, (6, 4, 3), smooth(0.55, 0.3, d))
            if abs(dx) < 0.16 and -1.8 < dy < 0:
                col = mix(col, (130, 16, 12), 0.85 * smooth(0.16, 0.05, abs(dx)) * smooth(-1.8, -0.2, dy))
        return col

    def nail(a, t):  # t = 0 at the point: bright steel, running to dark rust at the base
        n = rust.at(a, t)
        steel = mix((255, 255, 255), (150, 160, 176), smooth(0.05, 0.3, t))  # a bright point, dull iron behind it
        steel = shade(steel, 0.74 + 0.36 * abs(math.sin(a * math.pi)))  # a lit side and a shaded side, baked in
        col = mix(steel, mix((128, 60, 24), (70, 34, 16), n), smooth(0.3, 0.62, t + 0.12 * (n - 0.5)))
        return shade(col, 0.92 + 0.16 * fine.at(a, t))

    def tail(a, t):  # a frayed strip of cloth, a red stripe down each edge
        col = mix((232, 224, 190), (190, 178, 140), cloth.at(a, t))
        col = mix(col, (170, 26, 20), 0.9 * smooth(0.12, 0.06, min(a, 1 - a)))
        col = shade(col, 0.82 + 0.18 * smooth(0.0, 0.1, t))
        return mix(col, (60, 48, 34), 0.7 * smooth(0.86, 1.0, t) * smooth(0.45, 0.7, cloth.at(a, t * 2)))

    tex = Texture((30.0, 18.0, 10.0), gain=1.22, sat=1.15)  # unused texels are plain dark wood, not a grey block
    tex.region(BAT_BODY, body)
    tex.region(BAT_NAILRECT, nail)
    tex.region(BAT_TAILRECT, tail)
    return tex.render()


# ================================================================= ACID FLASK
# Axis Y, bottle round at the bottom, cork on top. Same box and origin as GasCanister (+-4.52, +-6.0, +-4.52). Built to
# read small: a fat round bulb, a thick short neck, an oversized cork, and a raised skull plaque on two opposite faces
# that is real relief (the body bulges under it), not just paint.
FL_SEGS = 16
FL_BODY = (1, 1, 127, 62)
FL_EMB = (1, 65, 61, 125)  # the skull plaque, planar over a square
FL_LIP = (64, 65, 127, 73)
FL_CORK = (64, 76, 127, 125)
FL_TOP, FL_BOT = 4.35, -6.0
FL_LIQUID = 1.15
FL_BODY_PTS = [(-6.0, 0.0), (-5.7, 2.0), (-4.9, 3.3), (-3.6, 4.2), (-2.1, 4.58), (-0.7, 4.6), (0.7, 4.2), (2.0, 3.3),
               (3.0, 2.5), (3.7, 2.07), (4.35, 2.05)]
FL_EMB_Y, FL_EMB_HALF, FL_EMB_CELLS = -1.2, 1.8, 9  # centre height, half-width, grid cells across


def skull_masks(sx, sy):
    """0..1 masks of the skull plaque at a point (units from its centre, y up): the plaque disc, the skull (cranium and
    jaw) and the dark holes (eyes, nose). The relief and the paint both read these, so they line up."""
    disc = smooth(1.82, 1.55, math.hypot(sx, sy))
    cran = smooth(1.0, 0.8, math.hypot(sx / 0.98, (sy - 0.38) / 0.88))
    jaw = smooth(1.0, 0.8, max(abs(sx) / 0.60, abs(sy + 0.62) / 0.48))
    eyes = max(smooth(1.0, 0.65, math.hypot((abs(sx) - 0.44) / 0.30, (sy - 0.28) / 0.36)),
               smooth(1.0, 0.6, math.hypot(sx / 0.13, (sy + 0.12) / 0.21)))
    return disc, max(cran, jaw), eyes


def skull_height(u, v):
    disc, skull, holes = skull_masks(u, v)
    return -0.25 + 0.41 * disc + 0.17 * skull * disc - 0.17 * holes * disc


def build_flask():
    mesh = Mesh()
    strips = [
        dict(pts=FL_BODY_PTS, rect=FL_BODY, range=(FL_BOT, FL_TOP)),
        dict(pts=[(4.35, 2.05), (4.5, 2.55), (4.8, 2.55), (4.8, 2.15)], rect=FL_LIP, vmode="arc"),
        dict(pts=[(4.8, 2.15), (5.2, 2.4), (5.75, 2.5), (6.0, 2.25), (6.0, 0.0)], rect=FL_CORK, range=(4.8, 6.0)),
    ]
    revolve(mesh, "flask", strips, FL_SEGS, 1)
    for k, th in enumerate((math.pi / 2, 3 * math.pi / 2)):
        relief(mesh, ("skull", k), FL_EMB_Y, th, lambda y: profile_r(FL_BODY_PTS, y), FL_EMB_HALF, FL_EMB_CELLS,
               skull_height, FL_EMB, FL_EMB_HALF)
    return mesh


def paint_flask():
    swirl = Fbm(21, 5, 5, 4)
    fine = Fbm(22, 30, 30, 2)
    pore = Fbm(23, 34, 12, 2)
    arc = TAU * 4.6
    rng = random.Random(2121)
    bubbles = [(rng.random(), rng.uniform(-5.0, 0.4), rng.uniform(0.22, 0.55)) for _ in range(12)]
    span = FL_TOP - FL_BOT

    def body(a, t):
        y = FL_TOP - t * span
        surface = FL_LIQUID + 0.05 * math.sin(TAU * a * 2)
        glass = mix((178, 255, 170), (112, 222, 118), smooth(0.5, 1.0, abs(wrapdiff(a, 0.0)) * 2) * 0.6)  # bright toxic glass
        if y < surface:
            deep = smooth(surface, -5.6, y)
            col = mix((150, 255, 30), (24, 176, 8), deep)
            col = mix(col, (210, 255, 70), 0.55 * smooth(0.5, 0.8, swirl.at(a, t)))
            for ba, by, br in bubbles:
                d = math.hypot(wrapdiff(a, ba) * arc, y - by)
                if d < br + 0.12:
                    col = mix(col, (240, 255, 170), 0.9 * smooth(0.09, 0.0, abs(d - br)))
                    col = mix(col, shade(col, 1.2), 0.5 * smooth(br, 0.0, d))
                hd = math.hypot(wrapdiff(a, ba) * arc + br * 0.35, y - by - br * 0.35)
                if hd < br * 0.25:
                    col = mix(col, (255, 255, 235), 0.95)
            col = mix(col, (14, 70, 8), smooth(0.46, 0.26, abs(y - surface)))  # the dark liquid line, bold
            col = mix(col, (225, 255, 120), smooth(0.2, 0.05, abs(y - surface + 0.55)))  # a bright band just below it
        else:
            col = shade(glass, 0.94 + 0.12 * fine.at(a, t))
        for ha, hw, hs in ((0.20, 0.02, 0.8), (0.78, 0.03, 0.4)):  # window-light streaks, white and bold
            s = math.exp(-((wrapdiff(a, ha) / hw) ** 2)) * smooth(-5.4, -4.4, y) * smooth(3.4, 2.6, y) * hs
            col = mix(col, (255, 255, 250), s)
        return mix(col, (10, 70, 10), smooth(-5.3, -6.0, y) * 0.6)  # a dark rim under the base

    def emb(a, t):
        sx, sy = (a - 0.5) * 2 * FL_EMB_HALF, (0.5 - t) * 2 * FL_EMB_HALF
        disc, skull, holes = skull_masks(sx, sy)
        r = math.hypot(sx, sy)
        col = mix((16, 70, 8), (6, 22, 6), smooth(0.4, 1.6, r))  # plaque: dark green, a bright ring round the edge
        col = mix(col, (170, 255, 70), smooth(0.08, 0.0, abs(r - 1.62)) * 0.95)
        if skull > 0.0:
            bone = mix((255, 252, 216), (212, 208, 160), smooth(0.2, 1.0, fine.at(a, t)))
            bone = shade(bone, 0.82 + 0.18 * smooth(-0.9, 0.9, sy))
            col = mix(col, bone, smooth(0.0, 0.5, skull))
        if holes > 0.0:
            col = mix(col, (4, 10, 3), smooth(0.0, 0.6, holes))
        for tx in (-0.22, 0.0, 0.22):  # teeth: dark slits across the jaw
            if -0.95 < sy < -0.55 and abs(sx - tx) < 0.04 and skull > 0.5:
                col = (30, 32, 18)
        if skull > 0.5 and -0.62 < sy < -0.55 and abs(sx) < 0.5:
            col = (30, 32, 18)
        return col if disc > 0.01 else (6, 22, 6)

    def lip(a, t):
        return mix((26, 40, 22), (12, 20, 10), fine.at(a, t))

    def cork(a, t):
        p = pore.at(a, t)
        col = mix((232, 176, 108), (190, 130, 74), smooth(0.35, 0.7, fine.at(a, t)))
        col = mix(col, (84, 48, 22), 0.9 * smooth(0.62, 0.7, p))
        return shade(col, 0.78 + 0.34 * (1 - t))

    tex = Texture(gain=1.2, sat=1.15)
    tex.region(FL_BODY, body)
    tex.region(FL_EMB, emb, wrap=False)
    tex.region(FL_LIP, lip)
    tex.region(FL_CORK, cork)
    return tex.render()


# ================================================================= ACID ROUND
# Axis Z, nose at +Z, nozzle at -Z. Vanilla Bazooka.Payload box with its node offset (0, 0, +0.066) applied. A stubby shell
# (a blunt dome nose instead of an ogive), a raised dark band near the tail, and three large corrosion pits pressed into
# the body, each with bright acid seeping in the bottom.
RD_SEGS = 22
RD_Z = 0.066
RD_BODY = (1, 1, 127, 100)
RD_NOZ = (1, 104, 127, 112)  # the nozzle is three strips (floor of the bell, its slope, the flat rim ring)
RD_NOZ2 = (1, 114, 127, 120)
RD_NOZ3 = (1, 122, 127, 127)
RD_TAIL = [(-3.14, 1.85), (-2.7, 2.1), (-2.2, 2.35), (-1.95, 2.4)]
RD_BAND = [(-1.95, 2.4), (-1.9, 2.62), (-1.2, 2.62), (-1.15, 2.45)]  # the dark band stands proud of the shell
RD_FRONT = [(-1.15, 2.45), (-0.65, 2.5), (-0.15, 2.5), (0.35, 2.5), (0.85, 2.5), (1.35, 2.5), (1.85, 2.5), (2.35, 2.39),
            (2.8, 2.07), (3.2, 1.52), (3.5, 0.62), (3.553, 0.0)]  # a blunt dome from z 1.85
RD_TAIL, RD_BAND, RD_FRONT = ([(z + RD_Z, r) for z, r in p] for p in (RD_TAIL, RD_BAND, RD_FRONT))
RD_MAIN = RD_TAIL + RD_BAND[1:] + RD_FRONT[1:]  # the whole outline, for radius look-ups
RD_NOZZLE = [[(-2.75 + RD_Z, 0.0), (-2.75 + RD_Z, 0.9)], [(-2.75 + RD_Z, 0.9), (-3.14 + RD_Z, 1.25)],
             [(-3.14 + RD_Z, 1.25), (-3.14 + RD_Z, 1.85)]]


def round_pits():
    """(angle in turns, z, radius, depth) of the three big corrosion pits, 120 degrees apart and at different heights so
    each flank of the shell shows one. Shared by the geometry and the paint."""
    return [(0.05, 0.75 + RD_Z, 1.15, 0.58), (0.38, 1.40 + RD_Z, 1.05, 0.52), (0.71, 0.05 + RD_Z, 1.10, 0.55)]


def pit_field(theta, z, pits):
    """How far the surface is pushed in at a point (units; a flat-floored crater with a slightly raised lip), and the
    distance to the nearest pit centre as a multiple of its radius (arc length across, axial length along)."""
    r = profile_r(RD_MAIN, z)
    total, nearest = 0.0, 9.0
    for pa, pz, rho, depth in pits:
        d = math.hypot(wrapdiff(theta / TAU, pa) * TAU * r, z - pz) / rho
        nearest = min(nearest, d)
        total += depth * (1 - smooth(0.5, 0.95, d)) - 0.10 * math.exp(-((d - 1.08) / 0.16) ** 2)
    return total, nearest


def build_round():
    mesh = Mesh()
    pits = round_pits()

    def disp(p, th, ax, r):
        if ax <= RD_FRONT[0][0] + 1e-9:  # the strip's first ring is shared with the band: a pit lip must not open a crack
            return p
        k, _ = pit_field(th, ax, pits)
        if k == 0.0 or r < 1e-6:
            return p
        s = (r - k) / r
        return (p[0] * s, p[1] * s, p[2])

    lo, hi = RD_MAIN[0][0], RD_MAIN[-1][0]
    strips = [
        dict(pts=RD_NOZZLE[0], rect=RD_NOZ, vmode="arc"),
        dict(pts=RD_NOZZLE[1], rect=RD_NOZ2, vmode="arc"),
        dict(pts=RD_NOZZLE[2], rect=RD_NOZ3, vmode="arc"),
        dict(pts=RD_TAIL, rect=RD_BODY, range=(lo, hi)),
        dict(pts=RD_BAND, rect=RD_BODY, range=(lo, hi)),
        dict(pts=RD_FRONT, rect=RD_BODY, range=(lo, hi), disp=disp),
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
        col = mix((56, 70, 38), (122, 138, 84), metal.at(a, t))  # olive steel, pushed apart
        col = shade(col, 0.82 + 0.34 * fine.at(a, t))
        band = smooth(2.15 + RD_Z, 2.25 + RD_Z, z) * smooth(2.8 + RD_Z, 2.7 + RD_Z, z)  # a worn yellow stencil band
        col = mix(col, (252, 208, 28), band * (0.95 - 0.5 * smooth(0.55, 0.8, rust.at(a, t))))
        r = smooth(0.62, 0.74, rust.at(a, t) + 0.1 * fine.at(a, t))
        col = mix(col, mix((196, 96, 28), (120, 54, 20), fine.at(a, t)), 0.85 * r)
        s = smooth(0.64, 0.74, streak.at(a, t)) * smooth(-1.0, 1.4, z) * smooth(3.0, 2.2, z)  # acid runs down the shell
        col = mix(col, mix((110, 255, 30), (190, 255, 70), fine.at(a, t)), 0.9 * s)
        col = mix(col, (18, 17, 14), 0.85 * smooth(-1.6, -3.1, z) * (0.5 + 0.5 * soot.at(a, t)))
        if -1.97 + RD_Z < z < -1.13 + RD_Z:  # the dark band, with a thin red stripe on its tail side
            e = smooth(0.0, 0.1, min(z + 1.97 - RD_Z, -1.13 + RD_Z - z))
            dark = shade((26, 24, 22), 0.8 + 0.4 * fine.at(a, t))
            dark = mix(dark, (190, 42, 28), smooth(0.07, 0.03, abs(z + 1.77 - RD_Z)))
            col = mix(col, dark, e)
        _, near = pit_field(a * TAU, z, pits)
        if near < 1.45:  # each pit: rusty ring, dark wall, bright acid seep in the floor
            col = mix(col, (190, 90, 26), smooth(1.45, 1.0, near))
            col = mix(col, (24, 18, 12), smooth(1.05, 0.72, near))
            seep = 1.0 - smooth(0.36, 0.62, near + 0.12 * (fine.at(a, t) - 0.5))
            col = mix(col, mix((70, 230, 20), (200, 255, 90), smooth(0.4, 0.0, near)), seep)
        return col

    def nozzle(a, t):
        n = soot.at(a, t)
        col = mix((16, 14, 12), (60, 46, 38), n)
        col = mix(col, (220, 100, 28), 0.7 * smooth(0.7, 0.85, t) * smooth(1.0, 0.9, t))
        return mix(col, (255, 130, 30), 0.5 * smooth(0.1, 0.0, t) * (1 - n))

    tex = Texture(gain=1.22, sat=1.18)
    tex.region(RD_BODY, body)
    for rect in (RD_NOZ, RD_NOZ2, RD_NOZ3):
        tex.region(rect, nozzle)
    return tex.render()


# ================================================================= CRUCIBLE
# Axis Z with the rim at +Z, as the vanilla holy grenade has its cross. Sphere radius 5.1 centred on z=-1.9, a heavy rim
# ring reaching z=6.8, a hollow top with a glowing bowl, and six iron studs. The cracks are great-circle random walks on
# the sphere; the geometry cuts real grooves along them (over a unit deep, a third of a radian wide) and the paint
# lights the groove floor from the same description, bright ember orange.
CR_R, CR_CZ = 5.1, -1.9
CR_SEGS = 24
CR_SPHERE = (1, 1, 127, 76)
CR_NECK = (1, 79, 127, 87)
CR_RING = (1, 89, 127, 103)
CR_BOWL = (1, 106, 100, 127)
CR_STUD = (103, 106, 127, 127)  # v runs tip (bright) to base (dark)
CR_PHI_TOP = math.radians(54.8)
CR_DEPTH = 1.25  # how far a groove floor sits below the sphere
CR_WALL = 0.27  # angular half-width of a groove at the surface, radians
CR_FLOOR = 0.05  # angular half-width of its flat floor


def crack_segments():
    rng = random.Random(0xC0DE)
    segs = []

    def walk(p, h, steps, step, branchy):
        for i in range(steps):
            c, s = math.cos(step), math.sin(step)
            p2 = unit(add(mul(p, c), mul(h, s)))
            h2 = sub(mul(h, c), mul(p, s))
            segs.append((p, p2))
            d = rng.uniform(-0.5, 0.5)
            h2 = add(mul(h2, math.cos(d)), mul(cross(p2, h2), math.sin(d)))
            h2 = unit(sub(h2, mul(p2, dot(h2, p2))))
            if branchy and i in (1, 2) and rng.random() < 0.6:
                db = rng.choice((-1, 1)) * rng.uniform(0.7, 1.1)
                hb = add(mul(h2, math.cos(db)), mul(cross(p2, h2), math.sin(db)))
                walk(p2, unit(hb), rng.randint(2, 3), step * 0.9, False)
            p, h = p2, h2

    for i, lat in enumerate((0.30, -0.35, 0.05, -0.70, 0.40)):  # start latitudes spread so every side has a crack
        lon = TAU * (i * 0.4 + rng.uniform(-0.03, 0.03))
        p = (math.cos(lat) * math.cos(lon), math.cos(lat) * math.sin(lon), math.sin(lat))
        helper = (0.0, 0.0, 1.0) if abs(p[2]) < 0.9 else (1.0, 0.0, 0.0)
        e1 = unit(cross(p, helper))
        ang = rng.uniform(0, TAU)
        h = add(mul(e1, math.cos(ang)), mul(cross(p, e1), math.sin(ang)))
        walk(p, unit(h), rng.randint(4, 6), 0.36, True)
    return segs


CRACKS = crack_segments()
LUMPS = ((0.07, (3.0, 1.0, 2.0), 0.4), (0.06, (-2.0, 3.0, 1.0), 2.1), (0.05, (1.0, -3.0, 4.0), 4.0))


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


def crucible_studs():
    """The direction (a unit vector from the sphere centre) of each of the six studs: two belts of three, each nudged along its
    belt until it sits clear of every crack."""
    out = []
    for lat, az0 in ((0.06, 45.0), (-0.55, 105.0)):
        for k in range(3):
            az = az0 + 120.0 * k
            for _ in range(24):
                d = (math.cos(lat) * math.cos(math.radians(az)), math.cos(lat) * math.sin(math.radians(az)), math.sin(lat))
                if crack_dist(d) > CR_WALL + 0.30:
                    break
                az += 7.0
            out.append(d)
    return out


def build_crucible():
    mesh = Mesh()
    centre = (0.0, 0.0, CR_CZ)

    def carve(p, th, ax, r):
        d = unit(sub(p, centre))
        groove = 1.0 - smooth(CR_FLOOR, CR_WALL, crack_dist(d))
        lump = sum(amp * math.sin(f[0] * d[0] + f[1] * d[1] + f[2] * d[2] + ph) for amp, f, ph in LUMPS)
        return add(centre, mul(d, CR_R + lump - CR_DEPTH * groove))

    steps = 10
    phis = [-math.pi / 2 + (CR_PHI_TOP + math.pi / 2) * i / steps for i in range(steps + 1)]
    sphere = [(CR_CZ + CR_R * math.sin(p), max(0.0, CR_R * math.cos(p))) for p in phis]
    sphere[0] = (sphere[0][0], 0.0)
    top_z = sphere[-1][0]
    neck = [sphere[-1], (4.2, 2.5)]
    ring = [(4.2, 2.5), (4.75, 4.2), (6.5, 4.4), (6.8, 3.8)]  # a heavy chamfered band
    strips = [
        dict(pts=sphere, rect=CR_SPHERE, range=(sphere[0][0], top_z), disp=carve),
        dict(pts=neck, rect=CR_NECK, range=(top_z, 4.2)),
        dict(pts=ring, rect=CR_RING, range=(4.2, 6.8)),
        dict(pts=[(6.8, 3.8), (4.9, 0.0)], rect=CR_BOWL, vmode="arc"),
    ]
    revolve(mesh, "crucible", strips, CR_SEGS, 2)
    for n, d in enumerate(crucible_studs()):
        # a blunt iron cone standing on the sphere, sunk into it a little so there is no gap on the curve
        base, mid, tip = (add(centre, mul(d, CR_R + k)) for k in (-0.3, 0.35, 0.72))
        helper = (0.0, 0.0, 1.0) if abs(d[2]) < 0.9 else (1.0, 0.0, 0.0)
        tube(mesh, ("stud", n), [base, mid, tip], [0.74, 0.62, 0.0], unit(cross(d, helper)), 5, CR_STUD)
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
        col = mix((12, 11, 11), (66, 58, 52), smooth(0.35, 0.8, char.at(a, t)))
        col = shade(col, 0.76 + 0.48 * grit.at(a, t))
        col = mix(col, (96, 44, 22), 0.5 * smooth(0.72, 0.9, heat.at(a, t)))  # heat-tinted scale
        # the groove: a red-hot wall climbing out of the char, an orange floor, a yellow-white core
        col = mix(col, (150, 36, 8), smooth(CR_WALL + 0.06, CR_WALL - 0.06, c) * (0.75 + 0.25 * heat.at(a, t)))
        col = mix(col, (255, 112, 14), smooth(CR_FLOOR + 0.1, CR_FLOOR + 0.02, c))
        col = mix(col, (255, 186, 54), smooth(CR_FLOOR + 0.03, CR_FLOOR - 0.02, c))
        col = mix(col, (255, 244, 190), smooth(0.02, 0.0, c) * (0.6 + 0.4 * heat.at(a, t)))
        e = smooth(0.8, 0.9, spark.at(a, t))  # a few loose embers in the char
        return mix(col, (240, 100, 24), 0.8 * e * smooth(CR_WALL + 0.1, CR_WALL, c))

    def neck(a, t):
        col = mix((26, 22, 20), (92, 56, 36), grit.at(a, t))
        return mix(col, (210, 84, 16), 0.7 * smooth(0.5, 1.0, t) * smooth(0.35, 0.7, heat.at(a, t)))

    def ring(a, t):  # a heavy iron band: bright chamfer edges, a hot glow on the lip, dark between
        col = mix((34, 30, 28), (104, 94, 86), grit.at(a, t))
        for e in (0.0, 0.22, 0.88, 1.0):  # edge highlights where the profile turns
            col = mix(col, (210, 196, 180), 0.8 * smooth(0.06, 0.0, abs(t - e)))
        col = mix(col, (255, 120, 22), 0.85 * smooth(0.22, 0.04, t) * smooth(0.3, 0.6, heat.at(a, t) + 0.25))
        return col

    def bowl(a, t):
        m = magma.at(a * 1.0, t)
        col = mix((200, 52, 6), (255, 180, 40), smooth(0.3, 0.75, m))
        col = mix(col, (255, 240, 150), smooth(0.65, 0.9, m) * smooth(0.4, 1.0, t))
        return mix(col, (70, 20, 6), smooth(0.16, 0.0, t) * 0.8)

    def stud(a, t):  # t = 0 at the tip: a bright worn point, dull iron behind it, dark at the base
        col = mix((250, 240, 222), (132, 122, 112), smooth(0.05, 0.45, t))
        col = mix(col, (40, 34, 30), smooth(0.5, 0.95, t))
        return shade(col, 0.72 + 0.4 * abs(math.sin(a * math.pi)))

    tex = Texture(gain=1.22, sat=1.2)
    tex.region(CR_SPHERE, sphere)
    tex.region(CR_NECK, neck)
    tex.region(CR_RING, ring)
    tex.region(CR_BOWL, bowl)
    tex.region(CR_STUD, stud)
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
    # a closed surface uses each directed edge at most once; twice means two faces wound the same way across a seam (an
    # inverted piece, such as a tube cap facing into its tube), which the normal check above cannot see
    seen = {}
    for a, b, c in tris:
        for e0, e1 in ((a, b), (b, c), (c, a)):
            ek = (tuple(round(x, 4) for x in pos[e0]), tuple(round(x, 4) for x in pos[e1]))
            seen[ek] = seen.get(ek, 0) + 1
    twice = sum(1 for n_ in seen.values() if n_ > 1)
    must(twice == 0, f"{twice} directed edges used twice (a piece is wound inside out)")
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


# The other weapons' models live in one module per group (tools/meshes_*.py); each exports generate() -> (files, stats).
GROUPS = ("meshes_held", "meshes_misc", "meshes_thrown")


def generate():
    files, stats = generate_originals()
    import importlib
    sys.path.insert(0, str(Path(__file__).resolve().parent))  # the group modules sit beside this file
    for mod in GROUPS:
        f, st = importlib.import_module(mod).generate()
        files.update(f)
        stats.update(st)
    return files, stats


def generate_originals():
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
        bad = [n for n, data in files.items() if not (OUT / n).is_file() or not _pngcmp.same((OUT / n).read_bytes(), data, n)]
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
