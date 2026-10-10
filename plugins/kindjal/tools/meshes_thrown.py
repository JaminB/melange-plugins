#!/usr/bin/env python3
"""Kindjal weapon meshes, group "launchers and thrown". Imports the helpers from make_meshes (it does not edit it) and exports

    MODELS = [(slug, build_fn, vanilla_reference_name), ...]      build_fn() -> (Mesh, rendered Texture)

    python meshes_thrown.py            write tools/meshes/<slug>.gltf/.bin/.png after validating each (make_meshes' strict
                                       validator with this group's own reference boxes, 12 percent and 400..1800 triangles)
    python meshes_thrown.py --check    regenerate and compare with the files on disk (exit 1 on a difference)

ripper_launcher   Bazooka.Weapon    black launcher tube, a saw-toothed shroud with a crown of fangs, a red-hot muzzle ring
ripper_rocket     Bazooka.Payload   matte-black rocket, glowing orange-red nose, four jagged saw-tooth fins
pipe_bomb         Grenade.Payload   a rusty pipe section with hex end caps, a yellow tape band and a short lit cord
blast_keg         Dynamite          a scorched wooden keg with iron hoops and a short lit cord on the lid
profane_grenade   HolyHandGrenade   a dark violet orb, an upside-down gold cross on both faces, gold cap and ring, red cracks
plantain_bananas  BananaBomb        a bunch of four black, overripe, curved bananas tied with twine round the stem

Each mesh is ONE primitive (positions, normals, uv0, u16 indices), one 128x128 texture, built in the frame of the vanilla
asset it replaces (origin, up and forward axes; the vanilla node matrix baked in, see VANILLA_THROWN, measured with xomtool).
Drawn for game distance (about 60 px): big chunky forms, a broken silhouette, a dark palette with one hot accent, and a
final contrast and saturation curve on every texture. Original art. Fixed seeds, stdlib only, deterministic. Importing this
module has no side effects.
"""
import math
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_meshes as mm  # noqa: E402
from make_meshes import (Fbm, Mesh, Texture, TAU, add, clamp, cross, dot, length, lerp, mix, mul,  # noqa: E402
                         revolve, shade, smooth, sub, unit, wrapdiff, _frames)

TEX = mm.TEX
X, Y, Z = (1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0)

# Vanilla reference boxes with the node matrices applied (reference name, min, max, tris), measured with
# xomtool convert <Name> --from Bundl09.xom (testenv/A). Same tuple layout as make_meshes.VANILLA.
#   Bazooka.Weapon   long axis Z, muzzle at +Z, tube axis at y 1.6 (r 3.6 .. 5.2), grips hang to y -9.6 at z -5 .. 7
#   Bazooka.Payload  long axis Z, nose at +Z, r 2.5 (node offset (-0.024, 0, +0.066) applied)
#   Grenade.Payload  Y up, body sphere r 4.25 on the origin; lever (-X), ring (+Z) and top make the box lopsided
#   Dynamite         Y up, stick r 2.8 from y -7.3 to 3.5, fuse rising to y 8.4 and bending toward -Z
#   HolyHandGrenade  Z up, sphere r 5.3 centred about z -1.9, cross on top (in the XZ plane, facing +-Y) to z 6.8
#   BananaBomb       Y up, one fat banana lying along Z (convex down, y -6.3), its stem rising at z -3 to y 6.3
VANILLA_THROWN = {
    "ripper_launcher": ("Bazooka.Weapon", (-5.240, -9.577, -9.881), (5.240, 6.837, 14.893), 940),
    "ripper_rocket": ("Bazooka.Payload", (-2.513, -2.423, -3.077), (2.512, 2.401, 3.619), 120),
    "pipe_bomb": ("Grenade.Payload", (-5.757, -3.949, -4.253), (4.252, 7.118, 6.389), 668),
    "blast_keg": ("Dynamite", (-2.782, -7.314, -4.484), (2.840, 8.426, 2.782), 192),
    "profane_grenade": ("HolyHandGrenade", (-5.323, -5.144, -7.076), (5.317, 5.146, 6.800), 575),
    "plantain_bananas": ("BananaBomb", (-4.126, -6.322, -5.594), (4.126, 6.264, 7.254), 382),
}
MESH_NAMES = {s: "".join(w.capitalize() for w in s.split("_")) for s in VANILLA_THROWN}
TOL, TRI_MIN, TRI_MAX = 0.12, 400, 1800


# ---------------------------------------------------------------- helpers beyond make_meshes
def xform(mesh, v0, rows=None, off=(0.0, 0.0, 0.0)):
    """Apply a proper rotation (3 row vectors, det +1, so windings stay outward) and then an offset to every vertex from v0."""
    for i in range(v0, len(mesh.pos)):
        p = mesh.pos[i]
        if rows:
            p = (dot(rows[0], p), dot(rows[1], p), dot(rows[2], p))
        mesh.pos[i] = add(p, off)


def basis_y_to(d):
    """Rows of the rotation that takes local +Y onto the unit vector d (right handed)."""
    d = unit(d)
    ex = unit(cross(d, Z)) if abs(d[2]) < 0.95 else unit(cross(d, X))
    ez = cross(ex, d)
    # columns ex, d, ez -> rows
    return [(ex[0], d[0], ez[0]), (ex[1], d[1], ez[1]), (ex[2], d[2], ez[2])]


def rot_z(a):
    c, s = math.cos(a), math.sin(a)
    return [(c, -s, 0.0), (s, c, 0.0), (0.0, 0.0, 1.0)]


def sweep(mesh, gid, pts, rx, ry, e1, sides, rect, flat=False, rot=0.0, caps=(True, True), cap_rects=(None, None)):
    """A closed tube along a polyline with elliptical cross sections: rx along the constant side vector e1, ry along
    cross(tangent, e1); either a scalar or one value per point (0 makes a point). flat=True gives every side its own
    smoothing group (crisp facets). u runs round the tube (side j covers j/sides .. (j+1)/sides of the rect), v from the
    first point (top of the rect) to the last. A cap is a fan; with a cap rect it is mapped planar (a disc in that rect),
    otherwise to one texel row of the side rect."""
    mesh.begin_part()
    n = len(pts)
    rxs = [rx] * n if not isinstance(rx, (list, tuple)) else list(rx)
    rys = [ry] * n if not isinstance(ry, (list, tuple)) else list(ry)
    cum = [0.0]
    for k in range(1, n):
        cum.append(cum[-1] + length(sub(pts[k], pts[k - 1])))
    total = cum[-1] or 1.0
    x0, y0, x1, y1 = rect
    rings = []
    for k, (p, (tan, miter)) in enumerate(zip(pts, _frames(pts))):
        e2 = unit(cross(tan, e1))
        s1 = cross(e2, tan)
        ring = []
        for j in range(sides):
            th = rot + TAU * j / sides
            ring.append((add(p, add(mul(s1, rxs[k] * miter * math.cos(th)), mul(e2, rys[k] * miter * math.sin(th)))), th))
        rings.append(ring)

    def uvp(a, t):
        return ((x0 + (x1 - x0) * a) / TEX, (y0 + (y1 - y0) * t) / TEX)

    ids = []
    for k in range(n):
        t = cum[k] / total
        if flat:
            ids.append([(mesh.vert(rings[k][j][0], uvp(j / sides, t), (gid, "f", j)),
                         mesh.vert(rings[k][(j + 1) % sides][0], uvp((j + 1) / sides, t), (gid, "f", j)))
                        for j in range(sides)])
        else:
            ids.append([mesh.vert(rings[k][j % sides][0], uvp(j / sides, t), (gid, "s")) for j in range(sides + 1)])
    for k in range(n - 1):
        for j in range(sides):
            if flat:
                (a0, a1), (b0, b1) = ids[k][j], ids[k + 1][j]
            else:
                a0, a1, b0, b1 = ids[k][j], ids[k][j + 1], ids[k + 1][j], ids[k + 1][j + 1]
            mesh.tri(a0, b0, b1)
            mesh.tri(a0, b1, a1)
    for end, k in ((0, 0), (1, n - 1)):
        if not caps[end] or rxs[k] < 1e-6 or rys[k] < 1e-6:
            continue
        cr = cap_rects[end]
        if cr:
            cu = lambda c, s, cr=cr: ((cr[0] + (cr[2] - cr[0]) * (0.5 + 0.5 * c)) / TEX, (cr[1] + (cr[3] - cr[1]) * (0.5 - 0.5 * s)) / TEX)
        else:
            t = cum[k] / total
            cu = lambda c, s, t=t: uvp(0.5 + 0.0 * c, t)
        centre = mesh.vert(pts[k], cu(0.0, 0.0), (gid, "cap%d" % end))
        ring = [mesh.vert(q, cu(math.cos(th), math.sin(th)), (gid, "cap%d" % end)) for q, th in rings[k]]
        for j in range(sides):
            if end == 0:
                mesh.tri(centre, ring[j], ring[(j + 1) % sides])
            else:
                mesh.tri(centre, ring[(j + 1) % sides], ring[j])
    mesh.end_part()


def loft(mesh, gid, rings, uvf, flat=True, caps=(True, True)):
    """A closed part from a stack of rings (same point count, same circulation). Each quad is wound to face away from the
    line of ring centroids; flat=True gives every quad its own smoothing group. uvf(p) -> (u, v) in texture space (0..1)."""
    mesh.begin_part()
    n = len(rings[0])
    cents = [tuple(sum(p[k] for p in r) / n for k in range(3)) for r in rings]
    for k in range(len(rings) - 1):
        mid = mul(add(cents[k], cents[k + 1]), 0.5)
        for j in range(n):
            j1 = (j + 1) % n
            q = [rings[k][j], rings[k + 1][j], rings[k + 1][j1], rings[k][j1]]
            fc = tuple(sum(p[i] for p in q) / 4 for i in range(3))
            out = sub(fc, mid)
            g = (gid, k, j) if flat else (gid, k)
            ids = [mesh.vert(p, uvf(p), g) for p in q]
            mesh.tri_out(ids[0], ids[1], ids[2], out)
            mesh.tri_out(ids[0], ids[2], ids[3], out)
    for end, k in ((0, 0), (1, len(rings) - 1)):
        if not caps[end]:
            continue
        out = sub(cents[k], cents[1 if k == 0 else k - 1])
        g = (gid, "cap", end)
        c = mesh.vert(cents[k], uvf(cents[k]), g)
        vs = [mesh.vert(p, uvf(p), g) for p in rings[k]]
        for j in range(n):
            mesh.tri_out(c, vs[j], vs[(j + 1) % n], out)
    mesh.end_part()


def torus(mesh, gid, c, axis, R, r, segs, sides, rect):
    """A closed torus round `axis` through c: u round the big circle, v round the tube."""
    mesh.begin_part()
    axis = unit(axis)
    e1 = unit(cross(axis, X if abs(axis[0]) < 0.9 else Y))
    e2 = cross(axis, e1)
    x0, y0, x1, y1 = rect
    grid = []
    for i in range(segs + 1):
        th = TAU * i / segs
        rd = add(mul(e1, math.cos(th)), mul(e2, math.sin(th)))
        row = []
        for j in range(sides + 1):
            ph = TAU * j / sides
            p = add(c, add(mul(rd, R + r * math.cos(ph)), mul(axis, r * math.sin(ph))))
            row.append(mesh.vert(p, ((x0 + (x1 - x0) * i / segs) / TEX, (y0 + (y1 - y0) * j / sides) / TEX), (gid, 0)))
        grid.append(row)
    for i in range(segs):
        for j in range(sides):
            mesh.tri(grid[i][j], grid[i + 1][j], grid[i + 1][j + 1])
            mesh.tri(grid[i][j], grid[i + 1][j + 1], grid[i][j + 1])
    mesh.end_part()


def spark(mesh, gid, c, size, rect, seed):
    """A little star of thin cones round c (a lit fuse). Bases sit just off the centre so no two cones share a plane."""
    rng = random.Random(seed)
    dirs = [(0.0, 1.0, 0.0), (0.94, 0.3, 0.1), (-0.8, 0.35, 0.5), (0.25, 0.2, -0.95), (-0.35, -0.6, -0.55), (0.45, -0.55, 0.7)]
    for k, d in enumerate(dirs):
        d = unit(d)
        ln = size * rng.uniform(0.8, 1.15)
        mm.cone(mesh, (gid, k), add(c, mul(d, 0.08 * size)), add(c, mul(d, ln)), 0.2 * size, 4, rect)


def rect_ring(c, u, v, a, b):
    """A 4-point ring (rectangle) centre c, half sizes a along u and b along v."""
    return [add(c, add(mul(u, sa * a), mul(v, sb * b))) for sa, sb in ((1, 1), (-1, 1), (-1, -1), (1, -1))]


def sring(c, u, v, a, b, n=8, p=3.0):
    """A superellipse ring of n points round c in the plane (u, v)."""
    out = []
    for j in range(n):
        cs, sn = math.cos(TAU * j / n), math.sin(TAU * j / n)
        out.append(add(c, add(mul(u, a * math.copysign(abs(cs) ** (2.0 / p), cs)), mul(v, b * math.copysign(abs(sn) ** (2.0 / p), sn)))))
    return out


def planar(rect, fn):
    """uvf for loft: fn(p) -> (a, t) in 0..1 across the rect."""
    x0, y0, x1, y1 = rect

    def uv(p):
        a, t = fn(p)
        return ((x0 + (x1 - x0) * clamp(a)) / TEX, (y0 + (y1 - y0) * clamp(t)) / TEX)
    return uv


def bezier(ps, t):
    """A point on a Bezier curve of any degree (de Casteljau)."""
    pts = list(ps)
    while len(pts) > 1:
        pts = [add(mul(a, 1 - t), mul(b, t)) for a, b in zip(pts, pts[1:])]
    return pts[0]


def glow(t):
    """The shared hot ramp: 0 dark red, 0.5 orange, 1 white-yellow."""
    if t < 0.5:
        return mix((120, 14, 6), (255, 96, 16), t * 2)
    return mix((255, 96, 16), (255, 246, 190), (t - 0.5) * 2)


# ================================================================= RIPPER LAUNCHER
# Axis Z, muzzle at +Z, tube axis at y 1.6 like Bazooka.Weapon. A black tube with a flared exhaust bell, a fat gunmetal
# shroud over the front half with three saw-toothed fins (top and both sides) running along it, a crown of eight steel
# fangs round the muzzle with heated tips, and a red-hot muzzle ring around a glowing bore. Pistol grip, trigger guard
# and a fore grip under the shroud reach down to the vanilla grip depth.
RL_AY = 1.6
RL_SEGS = 16
RL_TUBE = (1, 1, 127, 40)      # u round, v front (0) -> rear (1) (range -9.88 .. 14.3)
RL_HOT = (1, 43, 63, 52)       # the muzzle ring, arc
RL_BORE = (65, 43, 127, 52)    # the bore, arc from the lip inward
RL_EXH = (65, 55, 127, 60)     # the rear exhaust, arc
RL_FIN = (1, 55, 62, 90)       # planar z / r on the saw blade
RL_FANG = (83, 63, 127, 90)    # v tip (0) -> base (1)
RL_GRIP = (1, 93, 80, 127)
RL_SIGHT = (83, 93, 127, 127)
RL_LO, RL_HI = -9.88, 14.3
RL_SHROUD_R = 3.1
# the saw blade along the top of the shroud: (z, outer radius from the tube axis); three big teeth raking forward
RL_FIN_PTS = [(2.0, 3.15), (2.3, 3.45), (5.0, 5.22), (5.2, 3.5), (8.0, 5.22), (8.2, 3.5), (11.0, 5.22), (11.35, 3.15)]


def build_ripper_launcher():
    mesh = Mesh()
    rng = (RL_LO, RL_HI)
    v0 = len(mesh.pos)
    R = RL_SHROUD_R
    strips = [
        dict(pts=[(-9.0, 0.0), (-9.0, 1.5)], rect=RL_EXH, vmode="arc"),
        dict(pts=[(-9.0, 1.5), (-9.88, 2.05)], rect=RL_EXH, vmode="arc"),
        dict(pts=[(-9.88, 2.05), (-9.88, 2.4), (-9.5, 2.62), (-8.6, 2.5)], rect=RL_TUBE, range=rng),
        dict(pts=[(-8.6, 2.5), (-6.3, 2.45), (-6.25, 2.8), (-5.45, 2.8), (-5.4, 2.45)], rect=RL_TUBE, range=rng),
        dict(pts=[(-5.4, 2.45), (-2.0, 2.45), (1.6, 2.45)], rect=RL_TUBE, range=rng),
        dict(pts=[(1.6, 2.45), (1.7, R), (5.0, R), (8.5, R), (11.9, R), (12.2, 2.95)], rect=RL_TUBE, range=rng),
        dict(pts=[(12.2, 2.95), (12.4, 3.4), (13.9, 3.4), (14.3, 2.9), (14.3, 2.05)], rect=RL_HOT, vmode="arc"),
        dict(pts=[(14.3, 2.05), (11.0, 2.05), (11.0, 0.0)], rect=RL_BORE, vmode="arc"),
    ]
    revolve(mesh, "tube", strips, RL_SEGS, 2)
    xform(mesh, v0, off=(0.0, RL_AY, 0.0))

    # the saw blade along the top of the shroud (a plank of rectangles in the radial / side plane)
    zf0, zf1 = RL_FIN_PTS[0][0], RL_FIN_PTS[-1][0]
    rad, side = Y, (-1.0, 0.0, 0.0)
    rin = R - 0.3
    rings = [rect_ring(add((0.0, RL_AY, z), mul(rad, (rin + ro) / 2)), rad, side, (ro - rin) / 2, 0.42) for z, ro in RL_FIN_PTS]
    loft(mesh, "blade", rings, planar(RL_FIN, lambda p: ((p[2] - zf0) / (zf1 - zf0), (5.25 - (p[1] - RL_AY)) / 2.0)))
    # a crown of eight fangs round the muzzle, raked forward and out
    for k in range(8):
        ang = TAU * k / 8
        rad = (math.cos(ang), math.sin(ang), 0.0)
        base = add((0.0, RL_AY, 11.0), mul(rad, R - 0.35))
        tip = add((0.0, RL_AY, 14.89), mul(rad, 5.08))
        mm.cone(mesh, ("fang", k), base, tip, 0.85, 4, RL_FANG)
    # pistol grip, fore grip (superellipse rings stacked down a slanted line), trigger guard, trigger
    def grip_uv(p):
        return 0.5 + 0.5 * math.atan2(p[0], 1.0), (1.0 - p[1]) / 10.6
    gp = [(-0.6, -3.5, 0.9, 1.25), (-2.2, -3.75, 1.0, 1.35), (-5.0, -4.15, 1.02, 1.42), (-8.2, -4.6, 1.0, 1.4),
          (-9.2, -4.75, 0.9, 1.3), (-9.577, -4.8, 0.6, 0.95)]
    loft(mesh, "grip", [sring((0.0, y, z), X, Z, a, b, 8, 3.0) for y, z, a, b in gp], planar(RL_GRIP, grip_uv), flat=False)
    fg = [(-1.2, 6.3, 0.85, 1.1), (-3.4, 6.45, 0.95, 1.2), (-5.8, 6.75, 0.95, 1.2), (-7.1, 6.9, 0.85, 1.05),
          (-7.55, 6.95, 0.5, 0.7)]
    loft(mesh, "fore", [sring((0.0, y, z), X, Z, a, b, 8, 3.0) for y, z, a, b in fg], planar(RL_GRIP, grip_uv), flat=False)
    sweep(mesh, "guard", [(0.0, -0.9, -0.6), (0.0, -3.0, -0.75), (0.0, -3.9, -1.5), (0.0, -4.1, -2.6), (0.0, -3.6, -3.2)],
          0.3, 0.3, X, 6, RL_SIGHT)
    loft(mesh, "trigger", [rect_ring((0.0, y, z), X, Z, 0.18, w) for y, z, w in ((-0.9, -2.0, 0.4), (-2.3, -2.2, 0.3), (-2.9, -2.6, 0.2))],
         planar(RL_SIGHT, lambda p: (0.5, 0.5)))
    # rear sight block on top of the tube
    loft(mesh, "sight", [rect_ring((0.0, y, -3.4), X, Z, a, b) for y, a, b in ((3.8, 0.55, 1.1), (5.1, 0.55, 1.0), (5.5, 0.35, 0.8))],
         planar(RL_SIGHT, lambda p: (0.5 + p[0], (6.0 - p[1]) / 2.0)))
    return mesh, paint_ripper_launcher()


def paint_ripper_launcher():
    metal = Fbm(201, 8, 6, 4)
    fine = Fbm(202, 40, 30, 2)
    scuff = Fbm(203, 20, 12, 3)
    soot = Fbm(204, 6, 4, 3)
    span = RL_HI - RL_LO

    def tube(a, t):
        z = RL_HI - t * span
        n = metal.at(a, t)
        col = mix((16, 16, 19), (46, 46, 52), smooth(0.25, 0.8, n))  # matte black
        col = shade(col, 0.85 + 0.3 * fine.at(a, t))
        col = mix(col, (120, 122, 130), 0.75 * smooth(0.74, 0.82, scuff.at(a, t)))  # worn scuffs show steel
        if -6.3 < z < -5.4:  # the steel band at the back
            col = mix((96, 98, 108), (160, 164, 176), metal.at(a, t * 3))
            col = mix(col, (30, 30, 34), smooth(0.08, 0.0, min(z + 6.3, -5.4 - z)))
        if z > 1.65:  # the shroud: dark gunmetal, rows of black vent slots between the fangs
            col = mix((40, 42, 50), (74, 78, 88), smooth(0.25, 0.8, n))
            col = shade(col, 0.85 + 0.3 * fine.at(a, t))
            col = mix(col, (170, 174, 186), 0.85 * smooth(0.12, 0.0, abs(z - 1.75)))  # bright rim at its back edge
            for va in (0.0625, 0.1875, 0.3125, 0.4375, 0.5625, 0.6875, 0.8125, 0.9375):
                for vz in (3.4, 5.6, 7.8):
                    d = math.hypot(wrapdiff(a, va) * TAU * RL_SHROUD_R / 0.42, (z - vz) / 0.75)
                    if d < 1.1:
                        col = mix(col, (6, 6, 8), smooth(1.05, 0.85, d))
            col = mix(col, (255, 90, 20), 0.85 * smooth(11.2, 12.2, z) * (0.6 + 0.4 * metal.at(a, 0.3)))  # heat creeping back
        if z < -8.4:  # the exhaust end: sooty
            col = mix(col, (10, 9, 9), 0.6 * soot.at(a, t))
        return col

    def exh(a, t):
        return mix((60, 56, 54), (12, 10, 10), smooth(0.0, 0.6, t))

    def hot(a, t):  # the muzzle ring: t = 0 at the back edge, 1 at the mouth
        g = 0.35 + 0.6 * smooth(0.0, 0.85, t) + 0.12 * (fine.at(a, t) - 0.5)
        return glow(clamp(g))

    def bore(a, t):  # arc from the lip into the dark
        return mix((255, 120, 24), (40, 6, 4), smooth(0.0, 0.7, t))

    def fin(a, t):  # t = 0 at the saw edge: a bright steel blade, a polished edge, rust spots, dark at the root
        col = mix((150, 156, 168), (200, 206, 216), metal.at(a, t))
        col = shade(col, 0.85 + 0.25 * fine.at(a, t))
        col = mix(col, (255, 255, 255), smooth(0.2, 0.05, t))
        col = mix(col, (120, 40, 20), 0.8 * smooth(0.72, 0.8, scuff.at(a, t)))
        return mix(col, (20, 20, 24), smooth(0.6, 0.85, t))

    def fang(a, t):  # tip glowing, steel behind
        col = mix((210, 214, 224), (70, 74, 84), smooth(0.25, 0.9, t))
        col = shade(col, 0.75 + 0.35 * abs(math.sin(a * math.pi * 4)))
        return mix(col, glow(0.75), smooth(0.28, 0.0, t))

    def grip(a, t):  # dark rubber, wrapped
        col = mix((22, 20, 20), (52, 48, 46), fine.at(a, t))
        ph = (t * 9.0) % 1.0
        return shade(col, 0.7 + 0.5 * smooth(0.0, 0.25, ph) * smooth(1.0, 0.75, ph))

    def sight(a, t):
        col = mix((60, 62, 70), (130, 134, 146), metal.at(a, t))
        return mix(col, (210, 214, 222), 0.7 * smooth(0.15, 0.0, min(t, 1 - t)))

    tex = Texture((24.0, 24.0, 28.0), gain=1.2, sat=1.15)
    tex.region(RL_TUBE, tube)
    tex.region(RL_HOT, hot)
    tex.region(RL_BORE, bore)
    tex.region(RL_EXH, exh)
    tex.region(RL_FIN, fin, wrap=False)
    tex.region(RL_FANG, fang)
    tex.region(RL_GRIP, grip, wrap=False)
    tex.region(RL_SIGHT, sight, wrap=False)
    return tex.render()


# ================================================================= RIPPER ROCKET
# Axis Z, nose at +Z, same box and origin as Bazooka.Payload. A slim matte-black body (r 1.6) with a raised red band, a
# long glowing nose cone, a hot nozzle, and four big jagged fins (saw-toothed trailing edges) that set the width.
RR_SEGS = 16
RR_BODY = (1, 1, 127, 56)      # range z -3.077 .. 3.619
RR_NOZ = (1, 59, 127, 70)
RR_FIN = (1, 73, 127, 127)     # planar z / r
RR_LO, RR_HI = -3.077, 3.619
RR_FIN_PTS = [(-3.0, 2.62), (-2.55, 2.05), (-2.42, 2.6), (-1.95, 2.0), (-1.82, 2.45), (-1.3, 1.9), (-0.4, 1.5)]


def build_ripper_rocket():
    mesh = Mesh()
    rng = (RR_LO, RR_HI)
    strips = [
        dict(pts=[(-2.5, 0.0), (-2.5, 0.75)], rect=RR_NOZ, vmode="arc"),
        dict(pts=[(-2.5, 0.75), (-3.077, 1.12), (-3.077, 1.3)], rect=RR_NOZ, vmode="arc"),
        dict(pts=[(-3.077, 1.3), (-2.7, 1.5), (-2.1, 1.6), (-1.2, 1.62), (-0.3, 1.62), (0.45, 1.6)], rect=RR_BODY, range=rng),
        dict(pts=[(0.45, 1.6), (0.5, 1.78), (1.05, 1.78), (1.1, 1.6)], rect=RR_BODY, range=rng),
        dict(pts=[(1.1, 1.6), (1.7, 1.5), (2.3, 1.22), (2.85, 0.84), (3.3, 0.44), (3.619, 0.0)], rect=RR_BODY, range=rng),
    ]
    revolve(mesh, "rocket", strips, RR_SEGS, 2)
    z0, z1 = RR_FIN_PTS[0][0], RR_FIN_PTS[-1][0]
    for k in range(4):
        ang = TAU * k / 4
        rad = (math.cos(ang), math.sin(ang), 0.0)
        side = (-math.sin(ang), math.cos(ang), 0.0)
        rings = [rect_ring(add((0.0, 0.0, z), mul(rad, (1.2 + ro) / 2)), rad, side, (ro - 1.2) / 2, 0.15) for z, ro in RR_FIN_PTS]

        def fin_uv(p, rad=rad):
            return (p[2] - z0) / (z1 - z0), (2.7 - dot(p, rad)) / 1.5
        loft(mesh, ("fin", k), rings, planar(RR_FIN, fin_uv))
    return mesh, paint_ripper_rocket()


def paint_ripper_rocket():
    metal = Fbm(211, 8, 6, 4)
    fine = Fbm(212, 40, 30, 2)
    span = RR_HI - RR_LO

    def body(a, t):
        z = RR_HI - t * span
        col = mix((14, 14, 16), (44, 44, 50), smooth(0.25, 0.8, metal.at(a, t)))
        col = shade(col, 0.85 + 0.3 * fine.at(a, t))
        for rz in (-1.25, -0.05):  # thin grey seams with rivet dots
            col = mix(col, (120, 122, 132), smooth(0.08, 0.02, abs(z - rz)))
        if 0.45 < z < 1.1:  # the raised red band
            col = mix((150, 18, 12), (220, 40, 22), metal.at(a, t * 2))
            col = mix(col, (40, 6, 4), smooth(0.07, 0.0, min(z - 0.45, 1.1 - z)))
        if z > 1.1:  # the glowing nose: orange-red at the back to white-hot at the tip
            col = glow(clamp(0.38 + 0.62 * smooth(1.1, 3.5, z) + 0.08 * (fine.at(a, t) - 0.5)))
            col = mix(col, (90, 12, 6), smooth(1.35, 1.1, z) * 0.8)
        return col

    def noz(a, t):
        return mix(glow(0.85), (30, 20, 18), smooth(0.3, 0.6, t))

    def fin(a, t):  # t = 0 at the outer saw edge: bright steel, darkening to the root
        col = mix((120, 124, 136), (170, 176, 188), metal.at(a, t))
        col = mix(col, (250, 252, 255), smooth(0.25, 0.05, t))
        return mix(col, (14, 14, 16), smooth(0.6, 0.9, t))

    tex = Texture((20.0, 20.0, 24.0), gain=1.2, sat=1.15)
    tex.region(RR_BODY, body)
    tex.region(RR_NOZ, noz)
    tex.region(RR_FIN, fin, wrap=False)
    return tex.render()


# ================================================================= PIPE BOMB
# Y up like Grenade.Payload. The vanilla grenade is a ball with a lever, a ring and a top, so its box is nearly a cube
# (10.0 x 11.1 x 10.6); a pipe fills it by lying along a body diagonal (as it lies diagonally in the icon). Built along a
# local Y axis (a rusty pipe r 2.12, two hexagonal steel end caps, a raised yellow tape band toward the low end), turned
# onto the diagonal, then a short cord leaves the top cap, curls up and ends in a spark.
PB_PIPE = (1, 1, 100, 60)       # u round, v along the pipe (top cap end first)
PB_TAPE = (1, 63, 100, 82)
PB_CAP = (1, 85, 60, 110)       # hex cap sides
PB_CAPF = (63, 85, 100, 122)    # cap faces (planar)
PB_CORD = (103, 1, 127, 80)
PB_SPARK = (103, 85, 127, 127)
PB_DIR = (0.60, 0.56, 0.57)
PB_C = (-0.6, 0.55, 1.0)
PB_HALF = 5.1


def pipe_frame():
    return basis_y_to(PB_DIR)


def build_pipe_bomb():
    mesh = Mesh()
    v0 = len(mesh.pos)
    sweep(mesh, "pipe", [(0.0, y, 0.0) for y in (3.85, 2.0, 0.0, -2.0, -3.85)], 2.12, 2.12, X, 14, PB_PIPE)
    tape = [(0.0, y, 0.0) for y in (-0.35, -0.5, -1.2, -1.9, -2.05)]
    sweep(mesh, "tape", tape, [2.18, 2.34, 2.38, 2.34, 2.18], [2.18, 2.34, 2.38, 2.34, 2.18], X, 14, PB_TAPE)
    for k, sgn in enumerate((1.0, -1.0)):
        ys = [sgn * y for y in (3.55, 3.7, 4.0, 4.85, PB_HALF)]
        rs = [2.3, 2.62, 2.75, 2.75, 2.45]
        if sgn < 0:
            ys, rs = ys[::-1], rs[::-1]
        sweep(mesh, ("cap", k), [(0.0, y, 0.0) for y in ys], rs, rs, X, 6, PB_CAP, flat=True, rot=TAU / 12,
              cap_rects=(PB_CAPF, PB_CAPF))
    xform(mesh, v0, pipe_frame(), PB_C)
    # the cord, out of the middle of the top cap, curling up and back over the pipe
    rows = pipe_frame()
    top = add(PB_C, (dot(rows[0], (0, PB_HALF - 0.3, 0)), dot(rows[1], (0, PB_HALF - 0.3, 0)), dot(rows[2], (0, PB_HALF - 0.3, 0))))
    d = unit(PB_DIR)
    cord = [top, add(top, mul(d, 0.9)), add(top, add(mul(d, 1.6), (-0.2, 0.9, -0.2))), add(top, (-0.9, 2.5, -0.7)),
            add(top, (-2.0, 2.85, -1.3))]
    sweep(mesh, "cord", cord, 0.32, 0.32, unit(cross(d, Y)), 6, PB_CORD)
    spark(mesh, "spark", add(cord[-1], (-0.25, 0.05, -0.15)), 1.3, PB_SPARK, 31)
    return mesh, paint_pipe_bomb()


def paint_pipe_bomb():
    rust = Fbm(221, 8, 6, 4)
    fine = Fbm(222, 40, 30, 2)
    pit = Fbm(223, 18, 14, 3)
    metal = Fbm(224, 6, 6, 3)
    cloth = Fbm(225, 30, 10, 2)

    def pipe(a, t):
        n = rust.at(a, t)
        col = mix((70, 30, 12), (170, 78, 26), smooth(0.25, 0.8, n))  # dark rust orange
        col = shade(col, 0.82 + 0.34 * fine.at(a, t))
        col = mix(col, (28, 14, 8), 0.9 * smooth(0.66, 0.74, pit.at(a, t)))  # black pitting
        col = mix(col, (214, 120, 50), 0.6 * smooth(0.78, 0.86, fine.at(a * 2, t)))  # flaky light rust
        col = mix(col, (24, 12, 6), 0.9 * smooth(0.02, 0.0, abs(wrapdiff(a, 0.62))))  # the weld seam
        return col

    def tape(a, t):  # yellow electrical tape: bright, dark edges, wrinkles
        col = mix((255, 206, 30), (196, 140, 10), cloth.at(a, t))
        col = shade(col, 0.82 + 0.25 * abs(math.sin(a * TAU * 5 + t * 3)))
        return mix(col, (60, 40, 4), smooth(0.14, 0.02, min(t, 1 - t)))

    def cap(a, t):  # steel hex: grey faces with a bright edge between them, darker chamfers
        col = mix((96, 100, 106), (170, 174, 182), metal.at(a, t))
        e = abs(((a * 6) % 1.0) - 0.5) * 2
        col = mix(col, (220, 224, 232), 0.8 * smooth(0.82, 1.0, e))
        col = mix(col, (60, 62, 68), smooth(0.25, 0.0, t) * 0.7 + smooth(0.8, 1.0, t) * 0.6)
        return mix(col, (110, 50, 18), 0.6 * smooth(0.7, 0.8, rust.at(a, t)))

    def capf(a, t):  # the cap face: a darker disc, a bright rim, the cord hole on the top cap
        r = math.hypot(a - 0.5, t - 0.5) * 2
        col = mix((150, 154, 162), (80, 84, 90), smooth(0.0, 0.9, r))
        col = mix(col, (40, 40, 44), smooth(0.24, 0.16, r))
        return mix(col, (110, 50, 18), 0.6 * smooth(0.7, 0.8, rust.at(a, t)))

    def cord(a, t):  # twisted dark cord, the end burning
        col = mix((40, 30, 22), (100, 80, 56), 0.5 + 0.5 * math.sin((a + t * 6) * TAU * 2))
        return mix(col, glow(0.8), smooth(0.82, 1.0, t))

    def sparkf(a, t):
        return glow(clamp(1.0 - 0.6 * t))

    tex = Texture((60.0, 30.0, 14.0), gain=1.2, sat=1.15)
    tex.region(PB_PIPE, pipe)
    tex.region(PB_TAPE, tape)
    tex.region(PB_CAP, cap)
    tex.region(PB_CAPF, capf, wrap=False)
    tex.region(PB_CORD, cord)
    tex.region(PB_SPARK, sparkf)
    return tex.render()


# ================================================================= BLAST KEG
# Y up like Dynamite (the stick's y -7.3 .. 3.5 becomes the keg, the fuse becomes the cord). Fourteen flat staves bulging to
# r 2.84, four iron hoops standing proud, a planked lid, a cord out of the bung curling toward -Z (where the vanilla fuse
# bends) with a spark at the end. Scorched black from the bottom up, burn holes with glowing rims.
BK_SIDES = 14
BK_WOOD = (1, 1, 100, 70)      # staves: u round, v top -> bottom
BK_HOOP = (1, 73, 100, 90)
BK_LID = (1, 93, 34, 126)
BK_BASE = (37, 93, 70, 126)
BK_CORD = (103, 1, 127, 70)
BK_SPARK = (103, 73, 127, 100)
BK_BOT, BK_TOP = -7.3, 1.8
BK_PROF = [(BK_TOP, 2.42), (1.35, 2.56), (-0.5, 2.78), (-2.75, 2.84), (-5.0, 2.78), (-6.8, 2.55), (BK_BOT, 2.42)]
BK_HOOPS = [(1.5, 1.0), (0.1, -0.4), (-4.9, -5.4), (-6.45, -6.95)]  # (top, bottom) of each hoop


def keg_r(y):
    pts = BK_PROF[::-1]
    return mm.profile_r(pts, y)


def build_blast_keg():
    mesh = Mesh()
    sweep(mesh, "keg", [(0.0, y, 0.0) for y, _ in BK_PROF], [r for _, r in BK_PROF], [r for _, r in BK_PROF], Z, BK_SIDES,
          BK_WOOD, flat=True, cap_rects=(BK_LID, BK_BASE))
    for k, (y1, y0) in enumerate(BK_HOOPS):
        ys = [y1, y1 - 0.05, y0 + 0.05, y0]
        rs = [keg_r(y) + d for y, d in zip(ys, (0.0, 0.17, 0.17, 0.0))]
        sweep(mesh, ("hoop", k), [(0.0, y, 0.0) for y in ys], rs, rs, Z, BK_SIDES, BK_HOOP, flat=True)
    cord = [(0.35, BK_TOP - 0.3, -0.5), (0.35, 2.9, -0.55), (0.1, 4.3, -0.9), (-0.35, 5.5, -1.6), (-0.7, 6.3, -2.5),
            (-0.85, 6.55, -3.0)]
    sweep(mesh, "cord", cord, 0.32, 0.32, X, 6, BK_CORD)
    spark(mesh, "spark", (-0.9, 6.7, -3.3), 1.3, BK_SPARK, 41)
    return mesh, paint_blast_keg()


def paint_blast_keg():
    grain = Fbm(231, 14, 4, 3)
    fine = Fbm(232, 50, 30, 2)
    char = Fbm(233, 6, 5, 4)
    metal = Fbm(234, 8, 4, 3)
    rng = random.Random(2310)
    holes = [(rng.random(), rng.uniform(-5.5, 0.0), rng.uniform(0.35, 0.55)) for _ in range(4)]
    span = BK_TOP - BK_BOT

    def wood(a, t):
        y = BK_TOP - t * span
        ph = (a * BK_SIDES) % 1.0
        col = mix((92, 56, 28), (172, 114, 60), smooth(0.25, 0.8, grain.at(a, t)))
        col = shade(col, 0.82 + 0.3 * fine.at(a * 0.3, t * 2))
        col = mix(col, (20, 12, 6), smooth(0.08, 0.0, min(ph, 1 - ph)))  # dark gap between staves
        burn = smooth(-2.0, -6.4, y + 1.2 * (char.at(a, t * 0.5) - 0.5)) * 0.95 + 0.9 * smooth(0.55, 0.66, char.at(a, t))  # scorched from below, in patches
        col = mix(col, (16, 11, 8), clamp(burn))
        col = mix(col, (255, 110, 24), 0.7 * smooth(0.02, 0.0, abs(char.at(a, t) - 0.52)) * smooth(-4.0, -6.5, y))  # ember edge, low down
        for ha, hy, hr in holes:  # burn holes: black, a glowing ring round each
            d = math.hypot(wrapdiff(a, ha) * TAU * 2.8, y - hy) / hr
            if d < 1.6:
                col = mix(col, glow(0.55), smooth(1.6, 1.1, d) * 0.9)
                col = mix(col, (6, 4, 3), smooth(1.15, 0.9, d))
        return col

    def hoop(a, t):  # iron: grey with bright edges, a rivet on every second stave
        col = mix((70, 72, 78), (140, 144, 152), metal.at(a, t))
        col = mix(col, (210, 214, 222), 0.75 * smooth(0.25, 0.0, min(t, 1 - t)))
        col = mix(col, (36, 36, 40), 0.6 * smooth(0.6, 0.75, char.at(a, t)))
        rv = math.hypot((((a * BK_SIDES / 2) % 1.0) - 0.5) * 3.0, (t - 0.5) * 2.2)
        return mix(col, (230, 232, 238), smooth(0.35, 0.2, rv))

    def lid(a, t):  # planks, a dark chime ring at the edge, the bung where the cord goes in
        x, z = (a - 0.5) * 2, (t - 0.5) * 2
        r = math.hypot(x, z)
        col = mix((90, 54, 26), (150, 98, 52), smooth(0.25, 0.8, grain.at(z * 0.5 + 0.5, x * 0.2 + 0.5)))
        col = mix(col, (24, 14, 8), smooth(0.04, 0.0, abs(((x + 1) * 2.5) % 1.0 - 0.5) - 0.46))
        col = mix(col, (20, 12, 6), smooth(0.8, 0.9, r))
        b = math.hypot(x - 0.35 / 2.42, z + 0.5 / 2.42)
        return mix(col, (10, 6, 4), smooth(0.24, 0.16, b))

    def base(a, t):
        return mix((14, 10, 8), (40, 28, 18), fine.at(a, t))

    def cord(a, t):
        col = mix((50, 36, 22), (130, 104, 70), 0.5 + 0.5 * math.sin((a + t * 7) * TAU * 2))
        return mix(col, glow(0.8), smooth(0.85, 1.0, t))

    def sparkf(a, t):
        return glow(clamp(1.0 - 0.6 * t))

    tex = Texture((40.0, 24.0, 12.0), gain=1.2, sat=1.15)
    tex.region(BK_WOOD, wood)
    tex.region(BK_HOOP, hoop)
    tex.region(BK_LID, lid, wrap=False)
    tex.region(BK_BASE, base, wrap=False)
    tex.region(BK_CORD, cord)
    tex.region(BK_SPARK, sparkf)
    return tex.render()


# ================================================================= PROFANE GRENADE
# Z up like HolyHandGrenade (whose cross stands on top facing +-Y). A dark violet orb (r 5.1 on z -1.9), an upside-down gold
# cross laid on the +-Y faces following the curve (long arm up, crossbar low), a gold cap on top with a pull ring, and
# glowing red cracks painted from the same crack lines on every side.
PG_R, PG_CZ = 4.95, -1.9
PG_SEGS = 20
PG_ORB = (1, 1, 127, 80)
PG_GOLD = (1, 83, 127, 100)    # cross bars: v along the bar
PG_CAP = (1, 103, 80, 127)
PG_RING = (83, 103, 127, 127)
PG_LO, PG_HI = PG_CZ - PG_R, PG_CZ + PG_R


def pg_cracks():
    """Crack polylines on the unit sphere (great-circle random walks with a branch or two). Shared by nothing but the paint,
    but kept as data so the cracks are the same on every run."""
    rng = random.Random(0x50F)
    segs = []

    def walk(p, h, steps, step, branchy):
        for i in range(steps):
            c, s = math.cos(step), math.sin(step)
            p2 = unit(add(mul(p, c), mul(h, s)))
            h2 = sub(mul(h, c), mul(p, s))
            segs.append((p, p2))
            d = rng.uniform(-0.6, 0.6)
            h2 = unit(add(mul(h2, math.cos(d)), mul(cross(p2, h2), math.sin(d))))
            h2 = unit(sub(h2, mul(p2, dot(h2, p2))))
            if branchy and i == 1:
                db = rng.choice((-1, 1)) * rng.uniform(0.7, 1.1)
                walk(p2, unit(add(mul(h2, math.cos(db)), mul(cross(p2, h2), math.sin(db)))), 2, step * 0.8, False)
            p, h = p2, h2

    for i, (lat, lon) in enumerate(((0.35, -1.2), (-0.3, -1.9), (0.2, 0.3), (-0.5, 1.4), (0.45, 2.3), (-0.2, 3.3))):
        p = (math.cos(lat) * math.cos(lon), math.cos(lat) * math.sin(lon), math.sin(lat))
        e1 = unit(cross(p, Z))
        ang = rng.uniform(0, TAU)
        h = add(mul(e1, math.cos(ang)), mul(cross(p, e1), math.sin(ang)))
        walk(p, unit(h), rng.randint(4, 5), 0.3, True)
    return segs


PG_CRACKS = pg_cracks()


def pg_crack_dist(d):
    best = 9.0
    for a, b in PG_CRACKS:
        ab = sub(b, a)
        t = clamp(dot(sub(d, a), ab) / dot(ab, ab))
        q = unit(add(a, mul(ab, t)))
        best = min(best, math.acos(clamp(dot(d, q), -1.0, 1.0)))
    return best


def sph(az, el, r):
    return (r * math.cos(el) * math.cos(az), r * math.cos(el) * math.sin(az), PG_CZ + r * math.sin(el))


def build_profane_grenade():
    mesh = Mesh()
    steps = 12
    pts = [(PG_CZ + PG_R * math.sin(-math.pi / 2 + math.pi * i / steps), PG_R * math.cos(-math.pi / 2 + math.pi * i / steps))
           for i in range(steps + 1)]
    pts[0], pts[-1] = (PG_LO, 0.0), (PG_HI, 0.0)
    revolve(mesh, "orb", [dict(pts=pts, rect=PG_ORB, range=(PG_LO, PG_HI))], PG_SEGS, 2)
    # the inverted cross on the -Y face, then the same turned half a turn onto +Y
    for k, turn in enumerate((0.0, math.pi)):
        v0 = len(mesh.pos)
        az = -math.pi / 2
        rc = PG_R + 0.05
        vert = [sph(az, math.radians(e), rc) for e in (-46, -31, -16, 0, 17, 34, 52)]
        sweep(mesh, ("cross", k, 0), vert, 0.75 * math.sqrt(2), 0.45 * math.sqrt(2), X, 4, PG_GOLD, flat=True, rot=math.pi / 4)
        el = math.radians(-16)
        bar = [sph(az + math.radians(a), el, rc) for a in (-38, -19, 0, 19, 38)]
        e1 = (0.0, math.sin(el), math.cos(el))  # the meridian direction at the bar (across it, in the surface)
        sweep(mesh, ("cross", k, 1), bar, 0.72 * math.sqrt(2), 0.45 * math.sqrt(2), e1, 4, PG_GOLD, flat=True, rot=math.pi / 4)
        if turn:
            xform(mesh, v0, rot_z(turn))
    # the gold cap, a short post and the pull ring (in the XZ plane, facing the same way as the cross)
    cap = [(2.3, 0.0), (2.3, 2.05), (2.75, 2.25), (3.85, 2.25), (4.15, 1.75), (4.35, 0.6), (5.0, 0.5), (5.0, 0.0)]
    revolve(mesh, "cap", [dict(pts=cap[:4], rect=PG_CAP, vmode="arc"), dict(pts=cap[3:6], rect=PG_CAP, vmode="arc"),
                          dict(pts=cap[5:], rect=PG_CAP, vmode="arc")], 14, 2)
    torus(mesh, "ring", (0.0, 0.0, 5.85), Y, 1.05, 0.34, 14, 6, PG_RING)
    return mesh, paint_profane_grenade()


def paint_profane_grenade():
    swirl = Fbm(241, 6, 5, 4)
    fine = Fbm(242, 40, 30, 2)
    metal = Fbm(243, 8, 6, 3)
    span = PG_HI - PG_LO

    def orb(a, t):
        z = PG_HI - t * span
        se = clamp((z - PG_CZ) / PG_R, -1.0, 1.0)
        ce = math.sqrt(max(0.0, 1 - se * se))
        d = (ce * math.cos(TAU * a), ce * math.sin(TAU * a), se)
        col = mix((26, 10, 44), (78, 40, 118), smooth(0.25, 0.8, swirl.at(a, t)))  # dark violet
        col = shade(col, 0.78 + 0.3 * fine.at(a, t) + 0.25 * smooth(-0.3, 0.9, se))
        col = mix(col, (150, 120, 200), 0.6 * smooth(0.8, 0.88, fine.at(a * 0.5, t)) * smooth(0.0, 0.6, se))  # glints
        cd = pg_crack_dist(d)
        col = mix(col, (90, 6, 6), smooth(0.11, 0.06, cd))  # dark red rim
        col = mix(col, (255, 40, 16), smooth(0.07, 0.035, cd))
        col = mix(col, (255, 190, 90), smooth(0.03, 0.0, cd))  # hot core
        return mix(col, (12, 4, 20), smooth(-0.8, -1.0, se) * 0.5)

    def gold(a, t):  # a bar: four flat sides, the outer one bright, edges dark
        side = int(a * 4) % 4
        f = (a * 4) % 1.0
        col = mix((214, 160, 40), (255, 226, 110), metal.at(a, t))
        col = shade(col, (1.0, 0.92, 0.85, 0.92)[side])
        col = mix(col, (110, 66, 10), smooth(0.08, 0.0, min(f, 1 - f)))
        return mix(col, (255, 246, 190), 0.6 * smooth(0.82, 0.92, fine.at(a, t)))

    def capf(a, t):  # the cap: gold, a dark groove, a darker top
        col = mix((176, 120, 24), (255, 210, 90), metal.at(a, t))
        col = mix(col, (70, 40, 8), smooth(0.05, 0.0, abs(t - 0.33)))
        col = mix(col, (70, 40, 8), smooth(0.05, 0.0, abs(t - 0.62)))
        return shade(col, 0.85 + 0.25 * abs(math.sin(a * math.pi * 7)))

    def ring(a, t):
        col = mix((190, 130, 30), (255, 220, 110), 0.5 + 0.5 * math.cos(t * TAU))
        return shade(col, 0.9 + 0.15 * metal.at(a, t))

    tex = Texture((30.0, 14.0, 46.0), gain=1.2, sat=1.15)
    tex.region(PG_ORB, orb)
    tex.region(PG_GOLD, gold)
    tex.region(PG_CAP, capf)
    tex.region(PG_RING, ring)
    return tex.render()


# ================================================================= PLANTAIN BANANAS
# Y up like BananaBomb (one banana along Z, convex down, stem up at z -3). A bunch of four curved, faceted (five-sided)
# overripe bananas fanned across X, their necks gathered into a crown at the top of -Z, bound with two turns of twine, a
# thick cut stem rising out of the crown. Each banana droops down and forward and its tip curls up toward +Z.
PL_SKIN = (1, 1, 100, 100)     # u round, v neck -> tip
PL_STEM = (103, 1, 127, 60)
PL_TWINE = (103, 63, 127, 100)
PL_CUT = (1, 103, 30, 127)
PL_CROWN = (0.0, 2.6, -3.75)
PL_STATIONS = 13
# per banana: neck x offset, (x, y, z) of two control points and the tip
PL_BANANAS = [
    (-0.55, (-2.3, -3.2, -3.4), (-3.4, -6.6, 1.6), (-3.0, -3.9, 5.2)),
    (-0.18, (-0.8, -3.0, -3.0), (-1.2, -5.8, 3.4), (-1.0, -2.4, 6.95)),
    (0.18, (0.8, -2.6, -3.3), (1.25, -4.9, 3.0), (1.0, -0.6, 6.7)),
    (0.55, (2.3, -2.0, -3.8), (3.4, -3.6, 1.4), (3.0, 0.5, 4.6)),
]
PL_RAD = [(0.0, 0.42), (0.08, 0.55), (0.2, 0.92), (0.38, 1.18), (0.6, 1.22), (0.8, 1.06), (0.92, 0.72), (0.98, 0.42),
          (1.0, 0.3)]


def banana_radius(t):
    return mm.profile_r(PL_RAD, t)


def build_plantain_bananas():
    mesh = Mesh()
    cx, cy, cz = PL_CROWN
    for k, (nx, c1, c2, tip) in enumerate(PL_BANANAS):
        p0 = (cx + nx, cy - 0.2, cz)
        ctrl = [p0, add(p0, (0.0, -1.6, 0.25)), c1, c2, tip]
        pts, rs = [], []
        for i in range(PL_STATIONS):
            t = i / (PL_STATIONS - 1)
            pts.append(bezier(ctrl, t))
            rs.append(banana_radius(t))
        sweep(mesh, ("banana", k), pts, rs, [r * 0.95 for r in rs], X, 5, PL_SKIN, flat=True, rot=0.3 * k)
    # the thick stem out of the crown, slightly bent, cut flat on top
    stem = [(cx, cy - 1.0, cz), (cx, cy + 0.6, cz + 0.05), (cx + 0.05, cy + 2.2, cz + 0.25), (cx + 0.1, 6.264, cz + 0.55)]
    sweep(mesh, "stem", stem, [0.95, 0.8, 0.72, 0.8], [0.95, 0.8, 0.72, 0.8], X, 7, PL_STEM, cap_rects=(None, PL_CUT))
    # two turns of twine round the crown
    torus(mesh, "twine0", (cx, cy + 0.15, cz), (0.0, 1.0, -0.12), 1.12, 0.27, 12, 5, PL_TWINE)
    torus(mesh, "twine1", (cx, cy + 0.75, cz + 0.05), (0.08, 1.0, 0.1), 0.98, 0.25, 12, 5, PL_TWINE)
    return mesh, paint_plantain_bananas()


def paint_plantain_bananas():
    blot = Fbm(251, 6, 10, 4)
    fine = Fbm(252, 40, 50, 2)
    streak = Fbm(253, 20, 3, 3)
    fibre = Fbm(254, 30, 6, 2)

    def skin(a, t):  # overripe: dark olive-brown, black blotches, paler ridges, black neck and tip
        f = (a * 5) % 1.0
        col = mix((40, 30, 12), (96, 74, 30), smooth(0.25, 0.8, streak.at(a, t)))
        col = shade(col, 0.82 + 0.3 * fine.at(a, t))
        col = mix(col, (150, 124, 56), 0.8 * smooth(0.1, 0.0, min(f, 1 - f)))  # pale ridge line
        col = mix(col, (10, 8, 4), 0.95 * smooth(0.6, 0.68, blot.at(a, t)))  # black blotches
        sp = fine.at(a * 2, t * 2)
        col = mix(col, (14, 10, 4), 0.9 * smooth(0.78, 0.84, sp))  # freckles
        col = mix(col, (12, 10, 6), smooth(0.12, 0.02, t))  # black neck
        return mix(col, (10, 8, 4), smooth(0.9, 0.98, t))  # black tip

    def stem(a, t):
        col = mix((52, 62, 22), (100, 112, 46), fibre.at(a, t))
        return mix(col, (30, 30, 12), 0.6 * smooth(0.6, 0.75, blot.at(a, t)))

    def twine(a, t):
        col = mix((150, 120, 74), (220, 190, 130), 0.5 + 0.5 * math.sin((a * 12 + t) * TAU))
        return shade(col, 0.85 + 0.2 * fibre.at(a, t))

    def cut(a, t):
        r = math.hypot(a - 0.5, t - 0.5) * 2
        col = mix((176, 168, 100), (110, 120, 50), smooth(0.2, 0.9, r))
        return mix(col, (60, 50, 20), smooth(0.85, 1.0, r))

    tex = Texture((40.0, 32.0, 12.0), gain=1.2, sat=1.1)
    tex.region(PL_SKIN, skin)
    tex.region(PL_STEM, stem)
    tex.region(PL_TWINE, twine)
    tex.region(PL_CUT, cut, wrap=False)
    return tex.render()


MODELS = [
    ("ripper_launcher", build_ripper_launcher, "Bazooka.Weapon"),
    ("ripper_rocket", build_ripper_rocket, "Bazooka.Payload"),
    ("pipe_bomb", build_pipe_bomb, "Grenade.Payload"),
    ("blast_keg", build_blast_keg, "Dynamite"),
    ("profane_grenade", build_profane_grenade, "HolyHandGrenade"),
    ("plantain_bananas", build_plantain_bananas, "BananaBomb"),
]


# ---------------------------------------------------------------- driver
def generate(only=None):
    """Build every model, validate with make_meshes' strict validator against this group's reference boxes. Returns
    ({filename: bytes}, {slug: stats})."""
    saved = (mm.VANILLA, mm.TOL, mm.TRI_MIN, mm.TRI_MAX)
    mm.VANILLA, mm.TOL, mm.TRI_MIN, mm.TRI_MAX = dict(VANILLA_THROWN), TOL, TRI_MIN, TRI_MAX
    files, stats = {}, {}
    try:
        for slug, build, _ref in MODELS:
            if only and slug not in only:
                continue
            mesh, tex = build()
            gltf, binary = mm.build_gltf(slug, MESH_NAMES[slug], mesh)
            png = tex.png()
            stats[slug] = mm.validate(slug, gltf, binary, png)
            files[slug + ".gltf"], files[slug + ".bin"], files[slug + ".png"] = gltf, binary, png
    finally:
        mm.VANILLA, mm.TOL, mm.TRI_MIN, mm.TRI_MAX = saved
    return files, stats


def deviations(slug, s):
    _, rmin, rmax, _ = VANILLA_THROWN[slug]
    return [100.0 * ((s["max"][k] - s["min"][k]) / (rmax[k] - rmin[k]) - 1) for k in range(3)]


def main():
    import argparse
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--check", action="store_true", help="compare regenerated output with the files on disk")
    ap.add_argument("--out", default=str(mm.OUT))
    ap.add_argument("slugs", nargs="*")
    args = ap.parse_args()
    files, stats = generate(set(args.slugs) or None)
    out = Path(args.out)
    if args.check:
        bad = [n for n, d in files.items() if not (out / n).is_file() or (out / n).read_bytes() != d]
        print("thrown meshes up to date" if not bad else "DIFFERS: " + ", ".join(bad))
        sys.exit(1 if bad else 0)
    out.mkdir(parents=True, exist_ok=True)
    for n, d in files.items():
        (out / n).write_bytes(d)
    for slug, s in stats.items():
        dev = deviations(slug, s)
        print(f"{slug}: {s['vertices']} verts, {s['triangles']} tris, size dev % "
              + " ".join(f"{a}{d:+.1f}" for a, d in zip("xyz", dev))
              + f", box {[round(v, 2) for v in s['min']]} .. {[round(v, 2) for v in s['max']]} vs {s['ref']}")


if __name__ == "__main__":
    main()
