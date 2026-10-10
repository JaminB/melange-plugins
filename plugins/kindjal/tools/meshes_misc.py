#!/usr/bin/env python3
"""Kindjal weapon meshes, group "guns and others". Imports the helpers from make_meshes (it does not edit it) and exports

    MODELS = [(slug, build_fn, vanilla_reference_name), ...]      build_fn() -> (Mesh, rendered Texture)

    python meshes_misc.py            write tools/meshes/<slug>.gltf/.bin/.png after validating each (make_meshes' strict validator
                                     with this group's own reference boxes, 12 percent and 400..1800 triangles)
    python meshes_misc.py --check    regenerate and compare with the files on disk

elephant_gun       SniperRifle      huge long rifle: a monstrous hollow bore, brass bands, walnut stock, a hammer and a rear sight
rust_canister      GasCanister      rusted square drum with rolling hoops, dented faces, a biohazard roundel, a leaking shoulder hole
field_radio        Radio            battered olive field radio: whip antenna, skull sticker, red call light, strap handle, crank
stone_donkey       Donkey           a massive cracked stone donkey on a broken plinth: head lowered, long ears, deep fissures
plague_arrow       Arrow            black cross fletching, a bone skull bead, a green-dripping broadhead
inflated_knifeman  InflatedScouser  a bloated hooded figure with taut glowing stitched seams, ready to burst, a knife in one fist

Each mesh is ONE primitive (positions, normals, uv0, u16 indices), one 128x128 texture, built in the frame of the vanilla
asset it replaces with the vanilla node matrix baked in (see VANILLA_MISC, measured with xomtool). Drawn for game distance
(about 60 px tall): big chunky forms, a broken silhouette, a final contrast and saturation curve on every texture.
Original art. Fixed seeds, stdlib only, deterministic. Importing this module has no side effects.
"""
import math
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import make_meshes as mm  # noqa: E402
from make_meshes import (Fbm, Mesh, Texture, TAU, add, clamp, cross, dot, length, mix, mul,  # noqa: E402
                         revolve, shade, smooth, sub, unit, wrapdiff, _frames)

TEX = mm.TEX
X, Y, Z = (1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0)

# Vanilla reference boxes with the node matrix applied (min, max, tris), measured with xomtool convert <Name> --from Bundl09.xom.
# Merge into make_meshes.VANILLA (same tuple layout: reference name, min, max, tris) when wiring the group in.
VANILLA_MISC = {
    "elephant_gun": ("SniperRifle", (-4.323, 2.304, -10.672), (3.183, 18.497, 14.348), 1292),
    "rust_canister": ("GasCanister", (-4.519, -6.006, -4.519), (4.519, 6.006, 4.519), 496),
    "field_radio": ("Radio", (-3.507, -7.566, -5.952), (4.976, 10.530, 6.040), 566),
    "stone_donkey": ("Donkey", (-42.497, -86.479, -57.835), (42.497, 80.362, 49.833), 1180),
    "plague_arrow": ("Arrow", (-2.470, -1.795, -17.625), (2.354, 2.146, 12.021), 356),
    "inflated_knifeman": ("InflatedScouser", (-18.512, -17.987, -15.162), (18.232, 31.043, 17.142), 1018),
}
# The glTF node / mesh name to use for each (CamelCase of the slug), and the vanilla node whose animation a replacement must keep.
MESH_NAMES = {s: "".join(w.capitalize() for w in s.split("_")) for s in VANILLA_MISC}
TOL, TRI_MIN, TRI_MAX = 0.12, 400, 1800


# ---------------------------------------------------------------- helpers beyond make_meshes
def shift(mesh, v0, off):
    for i in range(v0, len(mesh.pos)):
        mesh.pos[i] = add(mesh.pos[i], off)


def part_revolve(mesh, gid, strips, segs, axis, off=(0.0, 0.0, 0.0)):
    """make_meshes.revolve, then the part is moved by `off` (a closed part keeps its winding)."""
    v0 = len(mesh.pos)
    revolve(mesh, gid, strips, segs, 2 if axis == 0 else axis)
    if axis == 0:  # a part about X: build it about Z, then a proper rotation (z->x) so the winding stays outward
        for i in range(v0, len(mesh.pos)):
            q = mesh.pos[i]
            mesh.pos[i] = (q[2], q[1], -q[0])
    shift(mesh, v0, off)


def sweep(mesh, gid, pts, rx, ry, e1, sides, rect, flat=False, rot=0.0, rects=None, disp=None, caps=(True, True), fixed_tan=None):
    """A closed tube along a polyline with ELLIPTICAL cross sections: rx along the (constant) side vector e1, ry along
    cross(tangent, e1); either may be a scalar or one value per point (0 makes a point). `flat` gives every side its own
    smoothing group (a faceted, chiselled look) and `rects` one texture rect per side. `fixed_tan` keeps every ring in the plane
    perpendicular to that direction (a sheared extrusion: a butt plate that stays upright while the centre line drops). u runs round the tube, v from the
    first point (top of the rect) to the last. disp(p, centre, a, t) may move a vertex (a, t = u and v in 0..1)."""
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
        if fixed_tan:
            tan, miter = unit(fixed_tan), 1.0
        e2 = unit(cross(tan, e1))
        s1 = cross(e2, tan)
        ring = []
        for j in range(sides):
            th = rot + TAU * j / sides
            q = add(p, add(mul(s1, rxs[k] * miter * math.cos(th)), mul(e2, rys[k] * miter * math.sin(th))))
            if disp:
                q = disp(q, p, j / sides, cum[k] / total)
            ring.append(q)
        rings.append(ring)

    def uvp(rc, a, t):
        rx0, ry0, rx1, ry1 = rc
        return ((rx0 + (rx1 - rx0) * a) / TEX, (ry0 + (ry1 - ry0) * t) / TEX)

    ids = []
    for k in range(n):
        t = cum[k] / total
        if flat:
            row = []
            for j in range(sides):
                rc = rects[j] if rects else rect
                row.append((mesh.vert(rings[k][j], uvp(rc, 0.0, t), (gid, "f", j)),
                            mesh.vert(rings[k][(j + 1) % sides], uvp(rc, 1.0, t), (gid, "f", j))))
            ids.append(row)
        else:
            ids.append([mesh.vert(rings[k][j % sides], uvp(rect, j / sides, t), (gid, "s")) for j in range(sides + 1)])
    for k in range(n - 1):
        for j in range(sides):
            if flat:
                (a0, a1), (b0, b1) = ids[k][j], ids[k + 1][j]
            else:
                a0, a1, b0, b1 = ids[k][j], ids[k][j + 1], ids[k + 1][j], ids[k + 1][j + 1]
            mesh.tri(a0, b0, b1)
            mesh.tri(a0, b1, a1)
    for end, k in ((0, 0), (1, n - 1)):
        if not caps[end] or (rxs[k] < 1e-6 or rys[k] < 1e-6):
            continue
        t = cum[k] / total
        centre = mesh.vert(pts[k], uvp(rect, 0.5, t), (gid, "cap%d" % end))
        ring = [mesh.vert(rings[k][j], uvp(rect, 0.5, t), (gid, "cap%d" % end)) for j in range(sides)]
        for j in range(sides):
            if end == 0:
                mesh.tri(centre, ring[j], ring[(j + 1) % sides])
            else:
                mesh.tri(centre, ring[(j + 1) % sides], ring[j])
    mesh.end_part()


def ellipsoid(mesh, gid, c, ra, rb, rc, axis, e1, sides, rings, rect, disp=None, flat=False, rot=0.0, rects=None):
    """An ellipsoid with semi-axis ra along `axis`, rb along e1 and rc along cross(axis, e1)... (the sweep's frame). Poles at
    both ends of `axis`; u round the axis, v pole to pole."""
    axis = unit(axis)
    pts, rxs, rys = [], [], []
    for k in range(rings + 1):
        ph = math.pi * k / rings
        pts.append(add(c, mul(axis, ra * math.cos(ph))))
        rxs.append(rb * math.sin(ph))
        rys.append(rc * math.sin(ph))
    sweep(mesh, gid, pts, rxs, rys, e1, sides, rect, flat=flat, rot=rot, disp=disp, rects=rects)


class Face:
    """The six faces of an axis aligned chamfered box (`rbox`). u runs right and v up as seen from outside."""
    FRAMES = {"+x": (X, (0, 0, -1.0), Y), "-x": ((-1.0, 0, 0), Z, Y), "+y": (Y, X, (0, 0, -1.0)),
              "-y": ((0, -1.0, 0), X, Z), "+z": (Z, X, Y), "-z": ((0, 0, -1.0), (-1.0, 0, 0), Y)}


def rbox(mesh, gid, lo, hi, bevel, rects, trim, grids=None, heights=None):
    """A closed box with chamfered edges and corners, every face its own flat smoothing group. rects[face] is the texture rect of a
    face (planar, u right, v up); `trim` the rect of the chamfer strips; grids[face] = (nu, nv) subdivision and heights[face] =
    fn(u, v) -> offset along the normal in world units (u, v measured from the face centre; must be ~0 on its border)."""
    grids, heights = grids or {}, heights or {}
    cen = tuple((a + b) / 2 for a, b in zip(lo, hi))
    half = tuple((b - a) / 2 for a, b in zip(lo, hi))
    tx0, ty0, tx1, ty1 = trim
    corners, fr = {}, {}
    for f, (n, u, v) in Face.FRAMES.items():
        ax_n = max(range(3), key=lambda i: abs(n[i]))
        ax_u = max(range(3), key=lambda i: abs(u[i]))
        ax_v = max(range(3), key=lambda i: abs(v[i]))
        hn, hu, hv = half[ax_n], half[ax_u] - bevel, half[ax_v] - bevel
        c0 = add(cen, mul(n, hn))
        fr[f] = (n, u, v, c0, hu, hv)
        corners[f] = [add(c0, add(mul(u, su * hu), mul(v, sv * hv))) for su, sv in ((-1, -1), (1, -1), (1, 1), (-1, 1))]
        nu, nv = grids.get(f, (1, 1))
        fn = heights.get(f)
        rc = rects[f]
        grid = {}
        for iv in range(nv + 1):
            for iu in range(nu + 1):
                uu, vv = -hu + 2 * hu * iu / nu, -hv + 2 * hv * iv / nv
                h = fn(uu, vv) if fn and 0 < iu < nu and 0 < iv < nv else 0.0
                p = add(c0, add(add(mul(u, uu), mul(v, vv)), mul(n, h)))
                grid[(iu, iv)] = mesh.vert(p, ((rc[0] + (rc[2] - rc[0]) * iu / nu) / TEX,
                                               (rc[3] - (rc[3] - rc[1]) * iv / nv) / TEX), (gid, f))
        for iv in range(nv):
            for iu in range(nu):
                a, b, c, d = grid[(iu, iv)], grid[(iu + 1, iv)], grid[(iu + 1, iv + 1)], grid[(iu, iv + 1)]
                mesh.tri_out(a, b, c, n)
                mesh.tri_out(a, c, d, n)
    names = list(Face.FRAMES)
    for i, f in enumerate(names):
        for g in names[i + 1:]:
            nf, ng = fr[f][0], fr[g][0]
            if abs(dot(nf, ng)) > 0.5:
                continue
            e = cross(nf, ng)
            fp = sorted([q for q in corners[f] if dot(sub(q, cen), ng) > 0], key=lambda q: dot(q, e))
            gp = sorted([q for q in corners[g] if dot(sub(q, cen), nf) > 0], key=lambda q: dot(q, e))
            out = add(nf, ng)
            vs = [mesh.vert(q, ((tx0 + (tx1 - tx0) * w) / TEX, (ty0 + (ty1 - ty0) * s) / TEX), (gid, "t", f, g))
                  for q, w, s in ((fp[0], 0, 0), (fp[1], 0, 1), (gp[1], 1, 1), (gp[0], 1, 0))]
            mesh.tri_out(vs[0], vs[1], vs[2], out)
            mesh.tri_out(vs[0], vs[2], vs[3], out)
    for sx in (-1, 1):
        for sy in (-1, 1):
            for sz in (-1, 1):
                s = (sx, sy, sz)
                pts = []
                for f in ("+x" if sx > 0 else "-x", "+y" if sy > 0 else "-y", "+z" if sz > 0 else "-z"):
                    pts.append(next(q for q in corners[f] if all(dot(sub(q, cen), e_) * sg > 0
                                                                 for e_, sg in ((X, sx), (Y, sy), (Z, sz)) if abs(dot(fr[f][0], e_)) < 0.5)))
                vs = [mesh.vert(q, ((tx0 + tx1) / 2 / TEX, (ty0 + ty1) / 2 / TEX), (gid, "c", s)) for q in pts]
                mesh.tri_out(vs[0], vs[1], vs[2], s)


# ================================================================= ELEPHANT GUN
# Z is the long axis, muzzle at +Z, Y up, like SniperRifle. One huge round barrel (r 3.35, three brass bands, a hollow monstrous bore
# 3.2 deep) 10 units above the origin, a walnut stock with a deep butt, a fore-end, a pistol grip, a brass trigger guard, an
# exposed hammer and an express sight: the silhouette is a fat barrel with sights standing out of it, not fine detail.
GN_SEGS = 14
GN_Y = 10.6
GN_METAL = (1, 1, 127, 56)
GN_WOOD = (1, 58, 127, 100)
GN_BRASS = (1, 102, 63, 127)
GN_BORE = (65, 102, 127, 127)
GN_LO, GN_HI = -5.0, 14.35
GN_BANDS = [(-0.6, 1.0), (5.4, 6.95), (11.2, 12.05)]


def build_gun():
    mesh = Mesh()
    rng = (GN_LO, GN_HI)
    strips = [
        dict(pts=[(-5.0, 0.0), (-5.0, 2.9), (-4.6, 3.2), (-4.2, 3.3), (-0.6, 3.3)], rect=GN_METAL, range=rng),
        dict(pts=[(-0.6, 3.3), (-0.55, 3.5), (0.95, 3.5), (1.0, 2.8)], rect=GN_METAL, range=rng),
        dict(pts=[(1.0, 2.8), (5.4, 2.8)], rect=GN_METAL, range=rng),
        dict(pts=[(5.4, 2.8), (5.45, 3.5), (6.9, 3.5), (6.95, 2.8)], rect=GN_METAL, range=rng),
        dict(pts=[(6.95, 2.8), (11.2, 2.8)], rect=GN_METAL, range=rng),
        dict(pts=[(11.2, 2.8), (11.25, 3.5), (12.0, 3.5), (12.05, 2.9)], rect=GN_METAL, range=rng),
        dict(pts=[(12.05, 2.9), (13.4, 3.1), (14.35, 3.4)], rect=GN_METAL, range=rng),
        dict(pts=[(14.35, 3.4), (14.35, 2.45)], rect=GN_BRASS, vmode="arc"),
        dict(pts=[(14.35, 2.45), (13.9, 2.35), (10.8, 2.15), (10.8, 0.0)], rect=GN_BORE, vmode="arc"),
    ]
    part_revolve(mesh, "barrel", strips, GN_SEGS, 2, (0.0, GN_Y, 0.0))
    # walnut: the stock drops toward a deep butt, the fore-end sits under the barrel, a pistol grip hangs under the receiver
    back = (0.0, 0.0, -1.0)
    sweep(mesh, "stock", [(0, 10.2, -4.4), (0, 9.0, -6.8), (0, 7.8, -9.0), (0, 7.2, -10.1)], [3.1, 2.9, 2.7, 2.5],
          [3.3, 3.8, 4.3, 4.5], X, 10, GN_WOOD, fixed_tan=back)
    sweep(mesh, "butt", [(0, 7.2, -10.1), (0, 7.2, -10.67)], [2.55, 2.55], [4.6, 4.6], X, 10, GN_BRASS, fixed_tan=back)
    sweep(mesh, "fore", [(0, 8.5, 0.9), (0, 8.4, 3.5), (0, 8.3, 7.6)], [2.9, 3.0, 2.8], [1.9, 2.0, 1.8], X, 10, GN_WOOD)
    sweep(mesh, "grip", [(0, 8.0, -2.6), (0, 5.6, -3.4), (0, 3.4, -4.3), (0, 2.5, -4.7), (0, 2.4, -4.8)],
          [1.9, 1.7, 1.5, 1.0, 0.0], [1.6, 1.6, 1.5, 1.1, 0.0], X, 8, GN_WOOD)
    # brass: trigger guard loop, hammer, rear express sight leaves and a front sight post
    sweep(mesh, "guard", [(0, 7.2, -1.1), (0, 5.6, -0.8), (0, 4.3, -1.5), (0, 4.0, -2.5), (0, 4.4, -3.3), (0, 5.8, -3.6)],
          [0.4] * 6, [0.4] * 6, X, 6, GN_BRASS)
    sweep(mesh, "hammer", [(0, 13.4, -4.2), (0, 14.9, -5.0), (0, 15.8, -6.1), (0, 15.8, -6.9)], [1.25, 1.2, 1.2, 1.05],
          [1.25, 1.2, 1.2, 1.05], X, 6, GN_BRASS)
    # one chunky rear sight block (a notch is not needed at game distance) and a stubby front blade
    sweep(mesh, "leaf1", [(0, 13.5, -1.6), (0, 16.3, -1.6)], [2.2, 1.9], [0.95, 0.95], X, 4, GN_BRASS, flat=True, rot=math.pi / 4)
    sweep(mesh, "front", [(0, 13.3, 12.9), (0, 15.2, 12.9), (0, 16.3, 12.9), (0, 16.5, 12.9)], [1.5, 1.35, 1.1, 0.0],
          [1.2, 1.1, 0.9, 0.0], X, 6, GN_BRASS)
    return mesh


def paint_gun():
    steel = Fbm(101, 14, 4, 4)
    pit = Fbm(102, 40, 12, 2)
    rust = Fbm(103, 9, 3, 4)
    streak = Fbm(104, 30, 2, 3)
    grain = Fbm(105, 36, 2, 3)
    ring = Fbm(106, 6, 12, 3)
    fine = Fbm(107, 60, 20, 2)
    span = GN_HI - GN_LO

    def metal(a, t):
        z = GN_HI - t * span
        col = mix((26, 34, 32), (74, 92, 86), smooth(0.3, 0.8, steel.at(a, t)))  # dark gunmetal, a lit side and a shaded side
        col = shade(col, 0.74 + 0.5 * math.sin(math.pi * ((a * 14) % 1.0)) ** 0.7 * 0.6 + 0.2 * pit.at(a, t))
        col = mix(col, (150, 76, 28), 0.85 * smooth(0.70, 0.78, rust.at(a, t) + 0.12 * pit.at(a, t)))  # rust
        col = mix(col, (80, 40, 18), 0.55 * smooth(0.82, 0.9, streak.at(a, t)))
        for b0, b1 in GN_BANDS:  # brass bands: bright face, dark seam on both edges
            if b0 - 0.05 <= z <= b1 + 0.05:
                e = smooth(0.0, 0.18, min(z - b0, b1 - z))
                br = mix((140, 96, 20), (255, 214, 92), smooth(0.2, 0.9, 0.5 + 0.5 * math.sin(TAU * a * 1.0 + 1.2)))
                br = shade(br, 0.85 + 0.3 * fine.at(a, t))
                col = mix(col, mix((48, 30, 8), br, e), 1.0)
        if z > 13.0:  # muzzle: lighter worn steel at the very end
            col = mix(col, (112, 128, 120), 0.55 * smooth(13.0, 14.0, z))
        if z < -3.9:
            col = shade(col, 0.8)
        return col

    def wood(a, t):
        g = grain.at(a, t)
        col = mix((26, 12, 5), (96, 50, 22), smooth(0.25, 0.75, g))  # dark walnut, grain along the stock
        col = shade(col, 0.82 + 0.34 * ring.at(a, t))
        col = mix(col, (14, 7, 4), 0.7 * smooth(0.78, 0.9, fine.at(a, t * 3)))
        return shade(col, 0.75 + 0.5 * smooth(0.0, 0.5, 0.5 + 0.5 * math.sin(TAU * a + 0.5)))

    def brass(a, t):
        col = mix((150, 100, 22), (255, 222, 100), smooth(0.1, 0.9, 0.5 + 0.5 * math.sin(TAU * a + 1.3)))
        col = shade(col, 0.82 + 0.3 * fine.at(a, t))
        return mix(col, (60, 38, 8), 0.4 * smooth(0.6, 1.0, t) * rust.at(a, t))

    def bore(a, t):  # from the rim (t=0, steel) down to black
        col = mix((96, 108, 104), (4, 5, 6), smooth(0.0, 0.35, t) ** 0.7)
        return mix(col, (30, 36, 34), 0.3 * fine.at(a, t) * smooth(0.5, 0.0, t))

    tex = Texture((30.0, 30.0, 28.0), gain=1.25, sat=1.18)
    tex.region(GN_METAL, metal)
    tex.region(GN_WOOD, wood)
    tex.region(GN_BRASS, brass)
    tex.region(GN_BORE, bore)
    return tex.render()


def build_elephant_gun():
    return build_gun(), paint_gun()








# ================================================================= RUST CANISTER
# Y up like GasCanister (+-4.52, +-6.0, +-4.52). A squarish drum (a chamfered box, flat shaded, like the icon's can) with two
# raised rolling hoops, a screw cap with a short neck, a big yellow-and-black three-blade roundel on the +-Z faces with a
# deep real dent below it, dents on the +-X faces, and a crater on the shoulder (the top) that a thick green slime arm climbs out
# of, with a drip running down the +X side. The slime is the one accent colour.
CN_LO, CN_HI = (-4.15, -6.0, -4.15), (4.15, 4.4, 4.15)
CN_BEV = 0.75
CN_FRONT = (1, 1, 62, 80)  # the +-Z faces, planar, u right v up
CN_SIDE = (65, 1, 126, 80)  # the +-X faces
CN_TOP = (1, 82, 43, 122)
CN_CAP = (45, 82, 85, 104)
CN_BOT = (45, 106, 85, 122)
CN_SLIME = (87, 82, 127, 122)
CN_HOOP = (65, 123, 127, 127)
CN_TRIM = (1, 123, 63, 127)
CN_HU = CN_HI[0] - CN_BEV  # face half width (u), 3.4
CN_HV = (CN_HI[1] - CN_LO[1]) / 2 - CN_BEV  # face half height (v)
CN_YC = (CN_HI[1] + CN_LO[1]) / 2
CN_ROUND = (0.0, 0.7, 2.45)  # roundel centre (u, v from the face centre) and radius
CN_DENT_F = (-1.55, -3.05, 1.55, 0.95)  # (u, v, radius u, radius v) of the front dent
CN_DENT_S = (1.5, 2.95, 1.45, 1.0)  # the +-X faces: a dent high on the other side, plus a small one
CN_CRATER = (2.1, 1.4, 1.15)  # on the top face: (u = x, v = -z, radius)


def blades(sx, sy):
    """Roundel masks at a point in units from its centre: disc, rim ring, three blades, their holes, the hub ring."""
    r = math.hypot(sx, sy)
    ang = math.atan2(sy, sx)
    disc = smooth(CN_ROUND[2], CN_ROUND[2] - 0.12, r)
    rim = smooth(CN_ROUND[2] - 0.55, CN_ROUND[2] - 0.43, r) * disc
    bl = 0.0
    hole = 0.0
    for k in range(3):
        ca = math.radians(90 + 120 * k)
        d = abs(math.atan2(math.sin(ang - ca), math.cos(ang - ca)))
        sector = smooth(math.radians(36), math.radians(30), d) * smooth(0.5, 0.62, r) * smooth(1.95, 1.8, r)
        bl = max(bl, sector)
        hx, hy = 1.28 * math.cos(ca), 1.28 * math.sin(ca)
        hole = max(hole, smooth(0.48, 0.36, math.hypot(sx - hx, sy - hy)))
    hub = smooth(0.62, 0.5, r) * smooth(0.22, 0.34, r)
    return disc, rim, bl, hole, hub


def dent_mask(u, v, d):
    return smooth(1.0, 0.25, math.hypot((u - d[0]) / d[2], (v - d[1]) / d[3]))


def face_height(dent):
    def fn(u, v):
        disc, rim, bl, hole, hub = blades(u - CN_ROUND[0], v - CN_ROUND[1])
        h = 0.14 * disc + 0.1 * max(bl * (1 - hole), hub)
        return h - 0.75 * dent_mask(u, v, dent)
    return fn


def crater_mask(u, v):
    r = math.hypot(u - CN_CRATER[0], v - CN_CRATER[1]) / CN_CRATER[2]
    return smooth(1.0, 0.55, r), math.exp(-((r - 1.2) / 0.22) ** 2)


def top_height(u, v):
    inner, lip = crater_mask(u, v)
    return -1.0 * inner + 0.28 * lip


def build_canister():
    mesh = Mesh()
    rects = {"+z": CN_FRONT, "-z": CN_FRONT, "+x": CN_SIDE, "-x": CN_SIDE, "+y": CN_TOP, "-y": CN_BOT}
    rbox(mesh, "body", CN_LO, CN_HI, CN_BEV, rects, CN_TRIM,
         grids={"+z": (9, 11), "-z": (9, 11), "+x": (9, 11), "-x": (9, 11), "+y": (8, 8)},
         heights={"+z": face_height(CN_DENT_F), "-z": face_height(CN_DENT_F), "+x": face_height(CN_DENT_S),
                  "-x": face_height(CN_DENT_S), "+y": top_height})
    hr = {f: CN_HOOP for f in rects}
    for y0, y1 in ((-5.6, -4.95), (3.05, 3.7)):  # two raised rolling hoops
        rbox(mesh, ("hoop", y0), (-4.42, y0, -4.42), (4.42, y1, 4.42), 0.28, hr, CN_HOOP)
    # screw cap on a short neck, off centre
    part_revolve(mesh, "cap", [
        dict(pts=[(4.3, 0.0), (4.3, 1.25), (5.2, 1.25)], rect=CN_CAP, vmode="arc"),
        dict(pts=[(5.2, 1.25), (5.2, 1.9), (5.95, 1.9), (6.0, 1.55), (6.0, 0.0)], rect=CN_CAP, vmode="arc"),
    ], 10, 1, (-1.45, 0.0, 0.9))
    # the slime arm out of the crater (curls over the shoulder, bulbs along it), and a drip down the +X face
    cx, cz = CN_CRATER[0], -CN_CRATER[1]
    arm = [(cx, 3.9, cz), (cx - 0.1, 4.8, cz), (cx + 0.5, 5.45, cz), (cx + 1.5, 5.75, cz), (cx + 2.4, 5.6, cz), (cx + 2.9, 5.2, cz)]
    sweep(mesh, "arm", arm, [1.15, 0.95, 1.0, 0.8, 0.7, 0.0], [1.15, 0.95, 1.0, 0.8, 0.7, 0.0], Z, 8, CN_SLIME)
    for k, (bx, by, br) in enumerate(((cx + 0.4, 5.1, 0.95), (cx + 1.8, 5.65, 0.7))):
        ellipsoid(mesh, ("bulb", k), (bx, by, cz + 0.1), br, br, br, Y, X, 8, 5, CN_SLIME)
    drip = [(4.1, 4.5, cz), (4.55, 3.2, cz), (4.62, 1.6, cz + 0.05), (4.6, -0.2, cz), (4.58, -0.9, cz)]
    sweep(mesh, "drip", drip, [0.5, 0.44, 0.4, 0.5, 0.0], [0.5, 0.44, 0.4, 0.5, 0.0], Z, 6, CN_SLIME)
    ellipsoid(mesh, "drop", (4.6, -1.4, cz), 0.5, 0.5, 0.5, Y, X, 6, 4, CN_SLIME)
    return mesh


def paint_canister():
    rust = Fbm(111, 7, 7, 4)
    pit = Fbm(112, 28, 28, 3)
    streak = Fbm(113, 26, 2, 3)
    flake = Fbm(114, 16, 16, 2)
    sl = Fbm(115, 6, 6, 3)

    def metal(a, t, hu, hv):
        n = rust.at(a, t)
        col = mix((58, 22, 10), (190, 92, 30), smooth(0.25, 0.8, n))  # rust, dark pits and bright flaking orange
        col = shade(col, 0.72 + 0.5 * pit.at(a, t))
        col = mix(col, (24, 14, 10), 0.8 * smooth(0.66, 0.78, streak.at(a, t * 0.5)) * smooth(0.1, 0.6, 1 - t))  # dark runs down the face
        col = mix(col, (205, 130, 56), 0.7 * smooth(0.72, 0.8, flake.at(a, t)))
        return col

    def face(dent):
        def fn(a, t):
            u, v = (a - 0.5) * 2 * CN_HU, (0.5 - t) * 2 * CN_HV
            col = metal(a, t, CN_HU, CN_HV)
            disc, rim, bl, hole, hub = blades(u - CN_ROUND[0], v - CN_ROUND[1])
            if disc > 0:
                plate = mix((18, 14, 10), (232, 188, 24), rim)  # black plate, yellow rim
                yel = mix((246, 204, 30), (180, 140, 18), smooth(0.4, 0.8, flake.at(a, t)))
                plate = mix(plate, yel, max(bl * (1 - hole), hub))
                plate = mix(plate, (14, 10, 8), smooth(0.5, 0.9, flake.at(a * 2, t * 2)) * 0.35)
                col = mix(col, plate, disc)
            dm = dent_mask(u, v, dent)
            if dm > 0:
                col = mix(col, shade(col, 0.3), 0.85 * smooth(0.0, 0.6, dm))
                col = mix(col, (230, 140, 60), 0.6 * smooth(0.25, 0.1, abs(dm - 0.3)))
            return col
        return fn

    def top(a, t):
        u, v = (a - 0.5) * 2 * CN_HU, (0.5 - t) * 2 * CN_HU
        col = metal(a, t, 1, 1)
        inner, lip = crater_mask(u, v)
        col = mix(col, (216, 150, 70), 0.6 * lip)
        col = mix(col, (10, 8, 6), smooth(0.2, 0.9, inner))
        col = mix(col, (90, 235, 24), 0.9 * smooth(0.55, 0.9, inner) * (0.4 + 0.6 * sl.at(a, t)))  # acid pooled in the hole
        return col

    def cap(a, t):
        col = mix((90, 44, 18), (150, 80, 30), rust.at(a, t))
        col = shade(col, 0.7 + 0.5 * pit.at(a, t))
        return mix(col, (220, 150, 70), 0.5 * smooth(0.12, 0.04, abs(t - 0.5)) * smooth(0.3, 0.6, flake.at(a, t)))

    def slime(a, t):
        n = sl.at(a, t)
        col = mix((46, 190, 8), (150, 250, 40), smooth(0.2, 0.8, n))
        col = mix(col, (230, 255, 150), 0.9 * smooth(0.12, 0.02, abs(wrapdiff(a, 0.28))))  # a hard wet highlight
        return mix(col, (20, 100, 6), 0.5 * smooth(0.75, 1.0, t))

    def hoop(a, t):
        col = mix((16, 14, 14), (84, 70, 62), rust.at(a * 2, t * 6))
        return mix(col, (150, 128, 112), 0.7 * smooth(0.45, 0.0, abs(t - 0.5)))

    def trim(a, t):  # the folded, worn edges: bright bare metal under the rust
        return mix((150, 80, 36), (236, 170, 96), rust.at(a, t * 3))

    def bot(a, t):
        return shade(mix((40, 22, 12), (110, 58, 24), rust.at(a, t)), 0.7)

    tex = Texture((70.0, 34.0, 16.0), gain=1.25, sat=1.2)
    tex.region(CN_FRONT, face(CN_DENT_F), wrap=False)
    tex.region(CN_SIDE, face(CN_DENT_S), wrap=False)
    tex.region(CN_TOP, top, wrap=False)
    tex.region(CN_CAP, cap)
    tex.region(CN_BOT, bot)
    tex.region(CN_SLIME, slime)
    tex.region(CN_HOOP, hoop)
    tex.region(CN_TRIM, trim)
    return tex.render()


def build_rust_canister():
    return build_canister(), paint_canister()


# ================================================================= FIELD RADIO
# Y up like Radio. A tall olive box (chamfered, flat shaded) on the same footprint, a speaker bezel and a big cream tuning knob on
# the +Z face, a thick rope-and-leather carry handle on the -Z side (as the vanilla radio has), a hand crank on the +X side, a skull
# sticker on both X faces, a red call lamp on the top and a whip antenna that droops at the tip. The red lamp is the accent.
RD_LO, RD_HI = (-3.4, -7.4, -3.2), (3.4, 4.6, 4.8)
RD_BEV = 0.6
RD_FRONT = (1, 1, 45, 86)
RD_SIDE = (47, 1, 111, 72)
RD_STRAP = (113, 1, 127, 72)
RD_BACK = (1, 88, 45, 127)
RD_TOP = (47, 74, 79, 106)
RD_TRIM = (47, 108, 79, 127)
RD_PARTS = (81, 74, 127, 88)
RD_KNOB = (81, 90, 127, 100)
RD_LAMP = (81, 102, 127, 127)
RD_CEN = tuple((a + b) / 2 for a, b in zip(RD_LO, RD_HI))  # (0, -1.4, 0.8)
RD_HU_F = RD_HI[0] - RD_BEV  # front/back half width 2.8
RD_HU_S = (RD_HI[2] - RD_LO[2]) / 2 - RD_BEV  # side half width (z) 3.4
RD_HV = (RD_HI[1] - RD_LO[1]) / 2 - RD_BEV  # 5.4
RD_HV_T = (RD_HI[2] - RD_LO[2]) / 2 - RD_BEV  # top half depth 3.4
RD_GRILLE = (0.0, 1.9, 2.35)  # speaker bezel on the front: (u, v, radius)
RD_STICKER = (0.0, 1.0, 2.35)  # skull sticker on a side face: (u, v, radius)
RD_DENT = (1.5, -3.5, 1.3, 0.9)
RD_LAMP_XZ = (-1.9, 2.4)
RD_ANT_XZ = (1.8, -0.8)


def bezel_h(u, v):
    r = math.hypot(u - RD_GRILLE[0], v - RD_GRILLE[1])
    ring = smooth(RD_GRILLE[2] + 0.1, RD_GRILLE[2] - 0.1, r) * smooth(RD_GRILLE[2] - 0.7, RD_GRILLE[2] - 0.5, r)  # raised rim
    return 0.34 * ring


def sticker_h(u, v):
    disc, skull, holes = mm.skull_masks((u - RD_STICKER[0]) / (RD_STICKER[2] / 1.82), (v - RD_STICKER[1]) / (RD_STICKER[2] / 1.82))
    d = smooth(0.0, 0.5, disc)
    dent = smooth(1.0, 0.25, math.hypot((u - RD_DENT[0]) / RD_DENT[2], (v - RD_DENT[1]) / RD_DENT[3]))
    return 0.13 * d - 0.5 * dent


def build_radio():
    mesh = Mesh()
    rects = {"+z": RD_FRONT, "-z": RD_BACK, "+x": RD_SIDE, "-x": RD_SIDE, "+y": RD_TOP, "-y": RD_TRIM}
    rbox(mesh, "body", RD_LO, RD_HI, RD_BEV, rects, RD_TRIM,
         grids={"+z": (10, 14), "-z": (3, 4), "+x": (10, 12), "-x": (10, 12), "+y": (4, 4)},
         heights={"+z": bezel_h, "+x": sticker_h, "-x": sticker_h})
    cx, cy, cz = RD_CEN
    front_z = RD_HI[2]
    # front: a cream tuning knob and two toggles
    part_revolve(mesh, "knob", [dict(pts=[(front_z - 0.2, 0.0), (front_z - 0.2, 1.5), (front_z + 0.55, 1.6), (front_z + 1.05, 1.35),
                                          (front_z + 1.2, 1.1), (front_z + 1.2, 0.0)], rect=RD_KNOB, vmode="arc")], 12, 2, (0.0, -4.6, 0.0))
    for sx in (-2.05, 2.05):
        part_revolve(mesh, ("toggle", sx), [dict(pts=[(front_z - 0.2, 0.0), (front_z - 0.2, 0.42), (front_z + 0.7, 0.34), (front_z + 0.8, 0.0)],
                                                 rect=RD_PARTS, vmode="arc")], 6, 2, (sx, -4.6, 0.0))
    # top: red call lamp (a dome in a bezel) and the antenna socket
    lx, lz = RD_LAMP_XZ
    top = RD_HI[1]
    part_revolve(mesh, "lamp", [dict(pts=[(top - 0.2, 0.0), (top - 0.2, 1.25), (top + 0.35, 1.25), (top + 0.35, 1.05)], rect=RD_PARTS, vmode="arc"),
                                dict(pts=[(top + 0.35, 1.0), (top + 0.8, 0.95), (top + 1.2, 0.65), (top + 1.45, 0.0)], rect=RD_LAMP, vmode="arc")],
                 10, 1, (lx, 0.0, lz))
    ax, az = RD_ANT_XZ
    part_revolve(mesh, "socket", [dict(pts=[(top - 0.2, 0.0), (top - 0.2, 1.0), (top + 0.9, 0.85), (top + 1.0, 0.0)], rect=RD_PARTS, vmode="arc")],
                 8, 1, (ax, 0.0, az))
    whip = [(ax, top + 0.8, az), (ax + 0.05, top + 2.8, az), (ax + 0.4, top + 4.4, az + 0.0), (ax + 0.95, top + 5.55, az), (ax + 1.7, top + 6.05, az),
            (ax + 2.2, top + 5.85, az)]
    sweep(mesh, "whip", whip, [0.3, 0.26, 0.22, 0.2, 0.18, 0.14], [0.3, 0.26, 0.22, 0.2, 0.18, 0.14], Z, 5, RD_PARTS)
    ellipsoid(mesh, "tip", (ax + 2.3, top + 5.8, az), 0.4, 0.4, 0.4, Y, X, 6, 4, RD_PARTS)
    # handle on the -Z side: a thick strap loop
    zb = RD_LO[2]
    loop = [(0.0, 2.6, zb + 0.2), (0.0, 3.1, zb - 1.3), (0.0, 2.2, zb - 2.75), (0.0, -2.9, zb - 2.75), (0.0, -3.9, zb - 1.3), (0.0, -4.4, zb + 0.2)]
    sweep(mesh, "handle", loop, [1.1, 0.95, 0.95, 0.95, 0.95, 1.1], [0.62, 0.62, 0.62, 0.62, 0.62, 0.62], X, 6, RD_STRAP)
    # crank on the +X side: axle, arm and a grip
    xs = RD_HI[0]
    zc = 1.2
    part_revolve(mesh, "hub", [dict(pts=[(xs - 0.2, 0.0), (xs - 0.2, 1.25), (xs + 0.35, 1.25), (xs + 0.35, 0.0)], rect=RD_PARTS, vmode="arc")], 10, 0, (0.0, -3.0, zc))
    arm = [(xs + 0.2, -3.0, zc), (xs + 0.9, -3.0, zc), (xs + 0.9, -3.8, zc), (xs + 0.9, -5.3, zc)]
    sweep(mesh, "arm", arm, [0.36] * 4, [0.36] * 4, Z, 6, RD_PARTS)
    sweep(mesh, "grip", [(xs + 0.8, -5.3, zc), (xs + 1.55, -5.3, zc)], [0.62, 0.62], [0.62, 0.62], Y, 6, RD_KNOB)
    return mesh


def paint_radio():
    paint = Fbm(121, 8, 8, 4)
    chip = Fbm(122, 22, 22, 3)
    fine = Fbm(123, 50, 50, 2)
    scr = Fbm(124, 30, 3, 2)
    leather = Fbm(125, 20, 5, 3)

    def olive(a, t):
        n = paint.at(a, t)
        col = mix((68, 78, 42), (100, 112, 60), smooth(0.25, 0.8, n))  # olive drab, lightly mottled (calm, so the lamp and knob read)
        col = shade(col, 0.93 + 0.14 * fine.at(a, t))
        col = mix(col, (20, 16, 12), 0.7 * smooth(0.74, 0.8, chip.at(a, t)))  # chipped to dark primer
        col = mix(col, (176, 150, 120), 0.7 * smooth(0.85, 0.88, chip.at(a * 1.7, t * 1.7)))  # bare metal chips
        col = mix(col, (30, 24, 16), 0.5 * smooth(0.65, 0.8, scr.at(a, t)))
        return col

    def front(a, t):
        u, v = (a - 0.5) * 2 * RD_HU_F, (0.5 - t) * 2 * RD_HV
        col = olive(a, t)
        r = math.hypot(u - RD_GRILLE[0], v - RD_GRILLE[1])
        if r < RD_GRILLE[2] + 0.15:
            if r > RD_GRILLE[2] - 0.55:  # raised bezel, bare brass-grey
                col = mix((84, 82, 70), (178, 170, 140), fine.at(a, t))
                col = mix(col, (240, 230, 190), 0.6 * smooth(0.12, 0.0, abs(r - (RD_GRILLE[2] - 0.15))))
            else:  # speaker cloth: dark with concentric slits
                slit = 0.5 + 0.5 * math.sin(r * 11.0)
                col = mix((8, 8, 6), (70, 70, 52), smooth(0.55, 0.9, slit) * 0.8)
        # a dial scale (white ticks) behind the knob, stencil lines
        dv = v + 3.2
        if abs(dv) < 1.75 and abs(u) < 2.55:
            if math.hypot(u, dv) > 1.65:
                col = mix(col, (28, 30, 20), 0.9)
                tick = (u * 4.2) % 1.0
                if tick < 0.22 and abs(dv) > 1.2:
                    col = (236, 228, 190)
        if abs(v - 5.0) < 0.12 and abs(u) < 2.3:
            col = (230, 222, 182)
        return col

    def side(a, t):
        u, v = (a - 0.5) * 2 * RD_HU_S, (0.5 - t) * 2 * RD_HV
        col = olive(a, t)
        k = RD_STICKER[2] / 1.82
        disc, skull, holes = mm.skull_masks((u - RD_STICKER[0]) / k, (v - RD_STICKER[1]) / k)
        if disc > 0:
            sx, sy = (u - RD_STICKER[0]) / k, (v - RD_STICKER[1]) / k
            plate = mix((236, 226, 190), (200, 186, 146), fine.at(a, t))  # a cream sticker with a black skull
            plate = mix(plate, (14, 12, 10), smooth(0.0, 0.5, skull))
            plate = mix(plate, (236, 226, 190), smooth(0.0, 0.6, holes) * 0.0)
            plate = mix(plate, (236, 226, 190), smooth(0.0, 0.5, holes))
            r = math.hypot(sx, sy)
            plate = mix(plate, (150, 24, 18), smooth(0.1, 0.0, abs(r - 1.62)))  # a thin red ring
            col = mix(col, plate, smooth(0.0, 0.3, disc))
        dm = smooth(1.0, 0.25, math.hypot((u - RD_DENT[0]) / RD_DENT[2], (v - RD_DENT[1]) / RD_DENT[3]))
        if dm > 0:
            col = mix(col, shade(col, 0.3), 0.85 * smooth(0.0, 0.6, dm))
            col = mix(col, (200, 180, 140), 0.5 * smooth(0.25, 0.1, abs(dm - 0.3)))
        if abs(v + 5.0) < 0.35 and abs(u) < 3.0:  # a strip of duct tape across the bottom
            col = mix((150, 150, 142), (110, 110, 104), fine.at(a, t))
        return col

    def back(a, t):
        col = olive(a, t)
        u, v = (a - 0.5) * 2 * RD_HU_F, (0.5 - t) * 2
        if abs(u) < 1.6 and abs(v) < 0.6:  # a battery plate
            col = (50, 50, 44)
        return col

    def topf(a, t):
        u, v = (a - 0.5) * 2 * RD_HU_F, (0.5 - t) * 2 * RD_HV_T
        col = olive(a, t)
        return col

    def trim(a, t):
        return mix((140, 120, 96), (222, 204, 164), paint.at(a, t * 3))

    def parts(a, t):
        col = mix((26, 28, 24), (96, 98, 86), paint.at(a * 2, t * 3))
        return mix(col, (200, 200, 180), 0.6 * smooth(0.18, 0.0, abs(wrapdiff(a, 0.28))))

    def knob(a, t):
        col = mix((228, 214, 170), (172, 154, 112), fine.at(a, t))
        return col

    def lamp(a, t):  # t = 0 at the base ring, 1 at the crown: bright red glowing dome, a white hot spot
        col = mix((140, 6, 6), (255, 46, 26), smooth(0.0, 0.7, t))
        col = mix(col, (255, 190, 160), 0.9 * smooth(0.35, 0.0, math.hypot(wrapdiff(a, 0.28) * 2.2, t - 0.62)))
        return col

    def strap(a, t):
        col = mix((24, 16, 10), (86, 58, 32), leather.at(a, t))
        stitch = (t * 22) % 1.0
        col = mix(col, (210, 190, 140), 0.85 * smooth(0.2, 0.0, abs(stitch - 0.5)) * smooth(0.12, 0.05, abs(wrapdiff(a, 0.5))))
        return col

    tex = Texture((52.0, 60.0, 34.0), gain=1.22, sat=1.15)
    tex.region(RD_FRONT, front, wrap=False)
    tex.region(RD_SIDE, side, wrap=False)
    tex.region(RD_BACK, back, wrap=False)
    tex.region(RD_TOP, topf, wrap=False)
    tex.region(RD_TRIM, trim)
    tex.region(RD_PARTS, parts)
    tex.region(RD_KNOB, knob)
    tex.region(RD_LAMP, lamp)
    tex.region(RD_STRAP, strap)
    return tex.render()


def build_field_radio():
    return build_radio(), paint_radio()








# ================================================================= PLAGUE ARROW
# Z is the arrow axis, head at +Z, fletching at -Z (the vanilla Arrow, node matrix baked in). Four black ragged feather vanes in a
# cross (so it reads from every roll angle), a brown shaft with a green-stained neck, an ivory skull bead with real eye sockets, an
# iron socket and a flat diamond broadhead in glossy acid green with three drips hanging off it. Green is the one accent colour.
AR_WOOD = (1, 1, 60, 30)
AR_FLET = (62, 1, 126, 34)
AR_BONE = (1, 32, 60, 60)
AR_HEAD = (62, 36, 126, 70)
AR_IRON = (1, 62, 60, 80)
AR_BIND = (1, 82, 60, 96)
AR_VANE = [(-10.4, 0.3), (-12.7, 1.95), (-13.7, 1.55), (-14.7, 2.0), (-15.8, 1.6), (-16.7, 1.95), (-17.7, 1.45), (-17.1, 0.3)]
AR_VZ0, AR_VZ1, AR_VR1 = -17.7, -10.4, 2.0
AR_SKULL_Z = -1.2


def slab(mesh, gid, poly, o, ea, eb, thick, rect):
    """A flat plate: the polygon `poly` (star shaped about its centroid) in the plane spanned by ea, eb at origin o, `thick`
    thick. Both faces are planar mapped into rect (u along ea, v from the largest b at the top of the rect to the smallest),
    the rim is a ring of flat quads on a thin strip of the rect."""
    n = unit(cross(ea, eb))
    x0, y0, x1, y1 = rect
    amin, amax = min(p[0] for p in poly), max(p[0] for p in poly)
    bmin, bmax = min(p[1] for p in poly), max(p[1] for p in poly)
    cen = (sum(p[0] for p in poly) / len(poly), bmin + 0.5 * (bmax - bmin) * 0.35)  # the fan centre must see every edge: low, near the root

    def pos(a, b, side):
        return add(add(o, add(mul(ea, a), mul(eb, b))), mul(n, side * thick / 2))

    def uvq(a, b):
        return ((x0 + (x1 - x0) * (a - amin) / (amax - amin)) / TEX, (y0 + (y1 - y0) * (bmax - b) / (bmax - bmin)) / TEX)

    for side in (1, -1):
        c = mesh.vert(pos(cen[0], cen[1], side), uvq(*cen), (gid, "face", side))
        ring = [mesh.vert(pos(a, b, side), uvq(a, b), (gid, "face", side)) for a, b in poly]
        for k in range(len(poly)):
            mesh.tri_out(c, ring[k], ring[(k + 1) % len(poly)], mul(n, side))
    ym = (y0 + y1) / 2 / TEX
    for k in range(len(poly)):
        p, q = poly[k], poly[(k + 1) % len(poly)]
        vs = [mesh.vert(pos(p[0], p[1], 1), ((x0 + x1) / 2 / TEX, ym), (gid, "rim", k)), mesh.vert(pos(q[0], q[1], 1), ((x0 + x1) / 2 / TEX, ym), (gid, "rim", k)),
              mesh.vert(pos(q[0], q[1], -1), ((x0 + x1) / 2 / TEX, ym), (gid, "rim", k)), mesh.vert(pos(p[0], p[1], -1), ((x0 + x1) / 2 / TEX, ym), (gid, "rim", k))]
        mid = ((p[0] + q[0]) / 2 - cen[0], (p[1] + q[1]) / 2 - cen[1])
        out = add(mul(ea, mid[0]), mul(eb, mid[1]))
        mesh.tri_out(vs[0], vs[1], vs[2], out)
        mesh.tri_out(vs[0], vs[2], vs[3], out)


def build_arrow():
    mesh = Mesh()
    # four feather vanes round the shaft (at 0, 90, 180, 270 degrees: x and y)
    for k in range(4):
        th = k * math.pi / 2
        eb = (math.cos(th), math.sin(th), 0.0)
        slab(mesh, ("vane", k), AR_VANE, (0.0, 0.0, 0.0), Z, eb, 0.22, AR_FLET)
    # shaft with the nock end, a green binding at the vanes and a stained neck
    shaft = [(0, 0, -17.7), (0, 0, -17.2), (0, 0, -10.0), (0, 0, -9.4), (0, 0, 3.7)]
    sweep(mesh, "shaft", shaft, [0.7, 0.58, 0.58, 0.66, 0.58], [0.7, 0.58, 0.58, 0.66, 0.58], X, 8, AR_WOOD)
    sweep(mesh, "bind", [(0, 0, -11.4), (0, 0, -10.2)], [0.9, 0.9], [0.9, 0.9], X, 8, AR_BIND)
    # the skull bead: cranium and a small jaw, eye sockets pushed in on both sides
    sz = AR_SKULL_Z

    def sockets(p, c, a, t):
        d = 0.0
        for ea in (0.0, 0.5):
            dx = wrapdiff(a, ea)
            d = max(d, smooth(1.0, 0.3, math.hypot(dx / 0.13, (t - 0.42) / 0.14)))
        if d > 0:
            v = sub(p, c)
            v = (v[0], v[1], 0.0)
            p = sub(p, mul(unit(v), 0.5 * d))
        return p
    ellipsoid(mesh, "skull", (0.0, 0.1, sz), 1.75, 1.55, 1.65, Z, X, 12, 8, AR_BONE, disp=sockets)
    ellipsoid(mesh, "jaw", (0.0, -1.2, sz + 0.25), 1.05, 1.0, 0.8, Z, X, 8, 4, AR_BONE)
    # iron socket and the broadhead: a flat diamond blade, wide barbs just behind the middle, a sharp point
    sweep(mesh, "socket", [(0, 0, 2.3), (0, 0, 2.6), (0, 0, 3.7)], [1.1, 1.1, 0.8], [1.1, 1.1, 0.8], X, 8, AR_IRON)
    zs = [3.4, 4.0, 4.9, 6.2, 8.5, 10.5, 12.021]
    rx = [0.7, 1.7, 2.45, 2.25, 1.55, 0.8, 0.0]
    ry = [0.7, 0.85, 1.0, 1.0, 0.8, 0.5, 0.0]
    sweep(mesh, "blade", [(0.0, 0.0, z) for z in zs], rx, ry, X, 4, AR_HEAD, flat=True)
    for k, (dx, dz, ln) in enumerate(((1.75, 4.9, 1.5), (-1.35, 6.3, 1.25), (0.25, 8.9, 0.95))):
        y0 = -0.6
        sweep(mesh, ("drip", k), [(dx, y0, dz), (dx, y0 - ln * 0.4, dz), (dx, y0 - ln * 0.8, dz), (dx, y0 - ln, dz)],
              [0.46, 0.36, 0.46, 0.0], [0.46, 0.36, 0.46, 0.0], X, 6, AR_HEAD)
    return mesh


def paint_arrow():
    grain = Fbm(131, 40, 3, 3)
    fine = Fbm(132, 40, 20, 2)
    bone = Fbm(133, 12, 12, 3)
    barb = Fbm(134, 6, 6, 2)
    gl = Fbm(135, 5, 5, 3)

    def wood(a, t):
        z = -17.7 + t * 21.4
        col = mix((74, 42, 20), (160, 106, 56), smooth(0.2, 0.8, grain.at(a, t)))
        col = shade(col, 0.8 + 0.4 * fine.at(a, t))
        green = smooth(-3.5, 1.5, z) * (0.4 + 0.6 * gl.at(a, t))  # the neck is stained with poison
        col = mix(col, (80, 210, 24), 0.9 * smooth(0.45, 0.65, green))
        col = mix(col, (10, 8, 6), 0.8 * smooth(-16.8, -17.5, z))  # burnt nock
        return col

    def flet(a, t):
        z = AR_VZ0 + a * (AR_VZ1 - AR_VZ0)
        r = AR_VR1 - t * (AR_VR1 - 0.3)
        col = mix((10, 10, 14), (34, 36, 50), smooth(0.3, 0.8, barb.at(a, t)))
        ph = ((z * 1.3 + r * 2.2) % 1.0)  # diagonal barbs, lighter than the vane
        col = mix(col, (76, 80, 104), 0.65 * smooth(0.28, 0.1, abs(ph - 0.5) * 2 - 0.5 + 0.5) * smooth(0.0, 0.5, r))
        col = mix(col, (214, 204, 170), 0.9 * smooth(0.5, 0.35, r))  # pale quill base along the root
        col = mix(col, (84, 220, 24), 0.95 * smooth(0.55, 0.2, abs(z - (-16.9)) * 0.5 + 0.0) * smooth(0.5, 1.2, r))  # a green dye band near the tail
        col = mix(col, (150, 160, 190), 0.6 * smooth(0.18, 0.0, abs(r - AR_VR1 + 0.1)) * 0.5)
        return col

    def bonef(a, t):
        col = mix((222, 214, 178), (255, 250, 226), smooth(0.2, 0.8, bone.at(a, t)))
        col = shade(col, 0.82 + 0.3 * fine.at(a, t))
        for ea in (0.0, 0.5):  # eye sockets, black, on both sides
            e = math.hypot(wrapdiff(a, ea) / 0.14, (t - 0.42) / 0.16)
            col = mix(col, (6, 6, 4), smooth(1.0, 0.7, e))
            col = mix(col, (120, 110, 80), 0.5 * smooth(0.12, 0.0, abs(e - 1.18)))
        nose = math.hypot(wrapdiff(a, 0.0) / 0.06 + 0.0, (t - 0.7) / 0.07)
        col = mix(col, (50, 44, 30), smooth(1.0, 0.6, nose) * 0.5)
        return col

    def head(a, t):  # across a flat face (u: edge to edge) and along it (t: base to tip)
        col = mix((40, 170, 10), (130, 245, 40), smooth(0.2, 0.8, gl.at(a, t)))
        col = mix(col, (24, 100, 6), 0.8 * smooth(0.12, 0.0, abs(a - 0.5)))  # darker central ridge
        col = mix(col, (214, 255, 110), 0.95 * smooth(0.12, 0.0, min(a, 1 - a)))  # bright cutting edges
        col = mix(col, (236, 255, 190), 0.8 * smooth(0.06, 0.0, abs(a - 0.3) - 0.0) * smooth(0.2, 0.5, t) * smooth(0.9, 0.6, t))
        return col

    def iron(a, t):
        col = mix((16, 16, 20), (88, 90, 100), smooth(0.2, 0.8, gl.at(a, t)))
        return mix(col, (170, 172, 186), 0.7 * smooth(0.12, 0.0, abs(wrapdiff(a, 0.28))))

    def bind(a, t):
        col = mix((20, 120, 10), (70, 200, 24), fine.at(a, t))
        return mix(col, (8, 40, 4), 0.5 * smooth(0.0, 0.15, abs((a * 6) % 1.0 - 0.5) * -1 + 0.5))

    tex = Texture((30.0, 24.0, 20.0), gain=1.22, sat=1.2)
    tex.region(AR_WOOD, wood)
    tex.region(AR_FLET, flet, wrap=False)
    tex.region(AR_BONE, bonef)
    tex.region(AR_HEAD, head, wrap=False)
    tex.region(AR_IRON, iron)
    tex.region(AR_BIND, bind)
    return tex.render()


def build_plague_arrow():
    return build_arrow(), paint_arrow()


















# ================================================================= STONE DONKEY
# Y up, the donkey faces +Z, like the vanilla Donkey (and, like it, stands on a slab: a broken concrete plinth). A massive cracked stone
# donkey, chunky and faceted: fat flat-shaded legs, a barrel body, a thick neck rising forward with the head LOWERED and long upright
# ears (one broken off flat), a row of dark crystal spikes down the mane. The fissures are real grooves: every part is displaced
# inward along crack lines that are given in the part's own (round, along) coordinates, and the paint reads the same lines, so the
# dark floor of each fissure (with a thin ember glow in the deepest part) sits exactly in the groove.
DK_BODY = (1, 1, 127, 36)
DK_HEAD = (1, 38, 60, 66)
DK_MUZ = (62, 38, 95, 66)
DK_NECK = (97, 38, 127, 66)
DK_LEG = (1, 68, 63, 98)
DK_ROCK = (65, 68, 127, 98)  # ears, mane spikes
DK_TOP = (1, 100, 64, 127)
DK_SIDE = (66, 100, 127, 127)
DK_PL_LO, DK_PL_HI, DK_PL_BEV = (-42.4, -86.4, -57.7), (42.4, -62.0, 49.7), 4.5

DK_BODY_C = (0.0, 2.0, -7.0)
DK_BODY_R = (42.0, 28.0, 27.0)  # along z, along x, along y
DK_CR_BODY = [[(0.04, 0.28), (-0.02, 0.37), (0.05, 0.46), (-0.01, 0.56), (0.06, 0.66), (0.0, 0.77)],
              [(0.50, 0.34), (0.55, 0.43), (0.48, 0.52), (0.54, 0.62), (0.49, 0.72)],
              [(0.20, 0.20), (0.27, 0.31), (0.22, 0.41), (0.30, 0.52)]]
DK_CR_HEAD = [[(0.04, 0.45), (-0.02, 0.58), (0.05, 0.7), (0.0, 0.82)], [(0.46, 0.5), (0.52, 0.62), (0.46, 0.76)],
              [(0.2, 0.2), (0.27, 0.34), (0.22, 0.45)]]
DK_CR_MUZ = [[(0.05, 0.3), (-0.02, 0.5), (0.04, 0.72)], [(0.46, 0.35), (0.53, 0.55)]]
DK_CR_NECK = [[(0.05, 0.15), (-0.03, 0.45), (0.04, 0.78)], [(0.52, 0.25), (0.46, 0.6)]]
DK_CR_LEG = [[(0.05, 0.2), (0.12, 0.38), (0.03, 0.52), (0.1, 0.7), (0.02, 0.9)]]
DK_CR_EAR = [[(0.02, 0.3), (0.08, 0.5), (0.0, 0.7)]]
DK_CR_TOP = [[(-30, 38), (-22, 26), (-28, 14), (-16, 4), (-21, -9)], [(30, 32), (21, 21), (27, 9), (15, -2)], [(2, -32), (9, -24), (2, -13), (13, -4)]]
# (circumference, length) of each part in world units for the crack distances, and the groove profile (depth, wall, floor)
DK_SCALE = {"body": (160.0, 100.0), "head": (96.0, 42.0), "muz": (70.0, 38.0), "neck": (90.0, 36.0), "leg": (60.0, 52.0), "ear": (30.0, 36.0)}


def split_rect(rect, n):
    x0, y0, x1, y1 = rect
    return [(x0 + (x1 - x0) * k / n, y0, x0 + (x1 - x0) * (k + 1) / n, y1) for k in range(n)]


def crack_d(polys, circ, length):
    """Distance (world units) from (a, t) to the nearest crack polyline given in (a turns, t) coordinates."""
    segs = []
    for pl in polys:
        for (a0, t0), (a1, t1) in zip(pl, pl[1:]):
            segs.append((a0, t0, a1, t1))

    def d(a, t):
        best = 1e9
        for a0, t0, a1, t1 in segs:
            am = (a0 + a1) / 2
            qa = am + wrapdiff(a, am)
            best = min(best, mm.seg_dist(qa * circ, t * length, a0 * circ, t0 * length, a1 * circ, t1 * length))
        return best
    return d


def groove(d, wall, floor):
    return 1.0 - smooth(floor, wall, d)


def crack_disp(polys, key, depth, wall, floor, jit=0.0, seed=0):
    circ, length = DK_SCALE[key]
    dist = crack_d(polys, circ, length)
    lump = Fbm(160 + seed, 5, 4, 3)

    def disp(p, c, a, t):
        if jit and (t < 1e-4 or t > 1 - 1e-4):  # a pole must stay one point
            return p
        f = groove(dist(a, t), wall, floor)
        amt = -depth * f
        if jit:
            amt += jit * (lump.at(a, t) - 0.5) * 2.0 * math.sqrt(math.sin(math.pi * clamp(t)))  # lumpy rock, closed at the poles
        if amt == 0.0:
            return p
        return add(p, mul(unit(sub(p, c)), amt))
    return disp


def plinth_height(u, v):
    best = 1e9
    for pl in DK_CR_TOP:
        for (a0, b0), (a1, b1) in zip(pl, pl[1:]):
            best = min(best, mm.seg_dist(u, v, a0, b0, a1, b1))
    return -5.5 * groove(best, 7.0, 1.8)


def build_donkey():
    mesh = Mesh()
    rects = {"+y": DK_TOP, "-y": DK_SIDE, "+x": DK_SIDE, "-x": DK_SIDE, "+z": DK_SIDE, "-z": DK_SIDE}
    rbox(mesh, "plinth", DK_PL_LO, DK_PL_HI, DK_PL_BEV, rects, DK_SIDE, grids={"+y": (9, 10), "+x": (4, 1), "-x": (4, 1)},
         heights={"+y": plinth_height})
    # body: a fat faceted barrel
    ellipsoid(mesh, "body", DK_BODY_C, DK_BODY_R[0], DK_BODY_R[1], DK_BODY_R[2], Z, X, 14, 9, DK_BODY, flat=True, rects=split_rect(DK_BODY, 14),
              disp=crack_disp(DK_CR_BODY, "body", 6.5, 9.0, 2.4, 2.6, 1), rot=math.pi / 14)
    # legs: four fat faceted pillars flaring into hooves
    for sx, sz in ((16.0, 28.0), (-16.0, 28.0), (16.5, -30.0), (-16.5, -30.0)):
        ys = [-61.9, -55.0, -40.0, -26.0, -14.0]
        rs = [12.6, 9.4, 8.6, 11.4, 15.0]
        sweep(mesh, ("leg", sx, sz), [(sx, y, sz) for y in ys], rs, rs, X, 8, DK_LEG, flat=True, rects=split_rect(DK_LEG, 8),
              disp=crack_disp(DK_CR_LEG, "leg", 4.5, 7.5, 2.0, 1.4, 2), fixed_tan=Y, rot=math.pi / 8)
    # neck and the lowered head
    neck = [(0.0, 10.0, 16.0), (0.0, 28.0, 25.0), (0.0, 46.0, 29.0)]
    sweep(mesh, "neck", neck, [16.0, 14.5, 13.0], [16.5, 15.0, 13.5], X, 10, DK_NECK, flat=True, rects=split_rect(DK_NECK, 10),
          disp=crack_disp(DK_CR_NECK, "neck", 4.0, 7.0, 2.0, 1.6, 3), rot=math.pi / 10)
    hd = unit((0.0, -0.8, 0.6))  # the head axis: pointing forward and down
    skc = (0.0, 49.0, 20.0)
    ellipsoid(mesh, "skull", skc, 24.0, 20.5, 21.0, hd, X, 12, 6, DK_HEAD, flat=True, rects=split_rect(DK_HEAD, 12),
              disp=crack_disp(DK_CR_HEAD, "head", 3.6, 5.5, 1.4, 1.3, 4), rot=math.pi / 12)
    ellipsoid(mesh, "muzzle", add(skc, mul(hd, 28.0)), 21.0, 15.5, 16.0, hd, X, 10, 6, DK_MUZ, flat=True, rects=split_rect(DK_MUZ, 10),
              disp=crack_disp(DK_CR_MUZ, "muz", 3.0, 5.0, 1.3, 1.0, 5), rot=math.pi / 10)
    # ears: long, upright, tilted out; the left one is snapped off flat
    for sx, end in ((1, (3.4, 2.0)), (-1, (4.4, 2.6))):
        path = [(sx * 9.0, 56.0, 24.0), (sx * 13.5, 66.5, 20.5), (sx * 17.5, 76.0, 17.5), (sx * 19.0, 80.3, 16.0)]
        sweep(mesh, ("ear", sx), path, [6.6, 8.0, 7.0, end[0]], [4.2, 4.0, 3.4, end[1]], X, 8, DK_ROCK, flat=True, rects=split_rect(DK_ROCK, 8),
              disp=crack_disp(DK_CR_EAR, "ear", 1.8, 4.5, 1.0))
    # a row of dark crystal spikes up the mane (the crest of the neck)
    nd = unit((0.0, 36.0, 13.0))
    nrm = unit((0.0, nd[2], -nd[1]))
    for k, (s, ln, rr) in enumerate(((0.3, 13.0, 5.4), (0.46, 15.0, 5.8), (0.62, 16.0, 6.0), (0.78, 15.0, 5.6), (0.92, 13.0, 5.0))):
        cpos = (0.0, 10.0 + 36.0 * s, 16.0 + 13.0 * s)
        rad = 16.0 - 3.0 * s
        base = add(cpos, mul(nrm, rad * 0.78))
        tip = add(base, mul(unit(add(mul(nrm, 0.55), mul(Y, 0.85))), ln))
        sweep(mesh, ("mane", k), [add(base, mul(nrm, -3.0)), base, tip], [rr * 0.9, rr, 0.0], [rr * 0.7, rr * 0.7, 0.0], X, 5, DK_ROCK, flat=True,
              rects=split_rect(DK_ROCK, 5))
    # tail: a stubby cracked stone rope with a heavy tuft
    tail = [(0.0, 12.0, -43.0), (0.0, 4.0, -50.5), (0.0, -10.0, -52.0), (0.0, -20.0, -50.5)]
    sweep(mesh, "tail", tail, [5.2, 4.8, 4.4, 3.8], [5.2, 4.8, 4.4, 3.8], X, 6, DK_LEG, flat=True, rects=split_rect(DK_LEG, 6))
    ellipsoid(mesh, "tuft", (0.0, -27.0, -50.0), 9.0, 7.0, 6.6, (0.0, -1.0, 0.0), X, 7, 5, DK_ROCK, flat=True, rects=split_rect(DK_ROCK, 7))
    return mesh


def paint_donkey():
    stone = Fbm(151, 9, 9, 4)
    speck = Fbm(152, 46, 46, 2)
    band = Fbm(153, 3, 9, 3)
    conc = Fbm(154, 7, 7, 4)
    chip = Fbm(155, 20, 20, 3)

    def stone_col(a, t, lo=(58, 66, 84), hi=(148, 160, 176)):
        col = mix(lo, hi, smooth(0.2, 0.85, stone.at(a, t)))
        col = shade(col, 0.82 + 0.34 * speck.at(a, t))
        return mix(col, shade(col, 0.55), 0.7 * smooth(0.62, 0.72, band.at(a, t)))  # darker weathered bands

    def with_cracks(col, d, wall, floor, a, t):
        g = groove(d, wall, floor)
        col = mix(col, (12, 12, 20), 0.95 * smooth(wall * 0.75, floor * 1.2, d))  # the fissure: a near black floor, dark walls
        col = mix(col, (210, 220, 236), 0.5 * smooth(0.9, 0.0, abs(d - wall * 0.92) * 1.0) * (1 - g))  # a bright broken lip
        ember = smooth(floor * 0.8, 0.0, d) * smooth(0.55, 0.85, chip.at(a * 2, t * 2))  # a broken thread of ember in the deepest part
        return mix(col, (255, 138, 36), 0.95 * ember)

    dists = {k: crack_d(p, *DK_SCALE[k]) for k, p in (("body", DK_CR_BODY), ("head", DK_CR_HEAD), ("muz", DK_CR_MUZ), ("neck", DK_CR_NECK),
                                                     ("leg", DK_CR_LEG), ("ear", DK_CR_EAR))}

    def body(a, t):
        col = stone_col(a, t)
        col = mix(col, shade(col, 0.5), 0.6 * smooth(0.55, 0.9, 0.5 + 0.5 * math.sin(TAU * (a - 0.25) + 0.0) * -1))  # a dark underside
        col = mix(col, (190, 200, 214), 0.35 * smooth(0.6, 1.0, 0.5 + 0.5 * math.sin(TAU * (a - 0.0))))  # light weathering on the top
        return with_cracks(col, dists["body"](a, t), 7.0, 1.8, a, t)

    def headf(a, t):
        col = stone_col(a, t, (66, 74, 92), (160, 172, 188))
        d = dists["head"](a, t)
        col = with_cracks(col, d, 5.0, 1.2, a, t)
        for ea in (0.07, 0.43):  # eyes and heavy brows, both sides, up toward the front of the skull
            dx = wrapdiff(a, ea)
            brow = smooth(1.0, 0.7, math.hypot(dx / 0.1, (t - 0.17) / 0.08))
            col = mix(col, (14, 16, 24), 0.9 * brow)
            e = math.hypot(dx / 0.06, (t - 0.27) / 0.09)
            col = mix(col, (244, 242, 226), smooth(1.0, 0.8, e))
            col = mix(col, (6, 6, 10), smooth(0.5, 0.35, math.hypot(dx / 0.06 - 0.25, (t - 0.27) / 0.09)))
        return col

    def muzf(a, t):
        col = stone_col(a, t, (70, 78, 96), (166, 178, 194))
        col = with_cracks(col, dists["muz"](a, t), 5.0, 1.3, a, t)
        for na in (0.12, 0.38):  # nostrils near the tip
            col = mix(col, (6, 6, 10), 0.95 * smooth(1.0, 0.6, math.hypot(wrapdiff(a, na) / 0.07, (t - 0.1) / 0.07)))
        col = mix(col, (20, 22, 30), 0.8 * smooth(0.06, 0.0, abs(wrapdiff(a, 0.75))) * smooth(0.1, 0.25, t) * smooth(0.7, 0.5, t))  # the mouth line
        return col

    def neckf(a, t):
        col = stone_col(a, t, (60, 68, 86), (150, 162, 178))
        return with_cracks(col, dists["neck"](a, t), 6.0, 1.6, a, t)

    def leg(a, t):
        col = stone_col(a, t * 0.6, (50, 56, 70), (136, 146, 162))
        col = mix(col, (24, 24, 30), 0.85 * smooth(0.14, 0.04, t))  # dark hooves
        return with_cracks(col, dists["leg"](a, t), 6.0, 1.6, a, t)

    def rock(a, t):  # ears and spikes: darker stone, a pale lip at the tips
        col = stone_col(a, t, (36, 42, 56), (104, 114, 132))
        col = with_cracks(col, dists["ear"](a, t), 4.0, 1.0, a, t)
        return mix(col, (12, 12, 18), 0.5 * smooth(0.7, 1.0, t))

    def plinth_top(a, t):
        u, v = (a - 0.5) * 2 * (DK_PL_HI[0] - DK_PL_BEV), (0.5 - t) * 2 * (DK_PL_HI[2] - DK_PL_BEV)
        col = mix((78, 76, 72), (156, 152, 142), smooth(0.25, 0.85, conc.at(a, t)))
        col = shade(col, 0.8 + 0.4 * speck.at(a, t))
        col = mix(col, (36, 34, 32), 0.7 * smooth(0.78, 0.85, chip.at(a, t)))
        best = 1e9
        for pl in DK_CR_TOP:
            for (a0, b0), (a1, b1) in zip(pl, pl[1:]):
                best = min(best, mm.seg_dist(u, v, a0, b0, a1, b1))
        col = mix(col, (12, 12, 18), 0.95 * smooth(7.0 * 0.75, 1.8 * 1.2, best))
        return mix(col, (255, 138, 36), 0.95 * smooth(1.4, 0.0, best) * smooth(0.55, 0.85, chip.at(a * 2, t * 2)))

    def plinth_side(a, t):
        col = mix((70, 68, 64), (140, 136, 128), smooth(0.25, 0.85, conc.at(a, t)))
        col = shade(col, 0.8 + 0.4 * speck.at(a, t))
        col = mix(col, (30, 28, 26), 0.85 * smooth(0.1, 0.0, abs(a * 4 % 1.0 - 0.5) - 0.38) * 0)  # (kept plain)
        col = mix(col, (28, 26, 24), 0.7 * smooth(0.74, 0.8, chip.at(a, t)))
        return mix(col, shade(col, 0.55), 0.6 * smooth(0.55, 1.0, t))  # darker toward the ground

    tex = Texture((70.0, 76.0, 90.0), gain=1.25, sat=1.15)
    tex.region(DK_BODY, body)
    tex.region(DK_HEAD, headf)
    tex.region(DK_MUZ, muzf)
    tex.region(DK_NECK, neckf)
    tex.region(DK_LEG, leg)
    tex.region(DK_ROCK, rock)
    tex.region(DK_TOP, plinth_top, wrap=False)
    tex.region(DK_SIDE, plinth_side)
    return tex.render()


def build_stone_donkey():
    return build_donkey(), paint_donkey()




# ================================================================= INFLATED KNIFEMAN
# Y up, the hood faces +Z, like InflatedScouser (its node matrix, a half turn of about 10 degrees and Z-up to Y-up, is baked in).
# A hugely bloated balloon body of six taut panels whose creases are glowing, stitched seams (real inward pinches), a dark hood
# with a deep recessed face and two pale slit eyes, stubby arms (the right one raises a knife), two boots. The hot orange seams
# are the one accent colour.
KM_SEGS = 24
KM_BELLY = (1, 1, 127, 60)
KM_HOOD = (1, 62, 127, 100)
KM_ARM = (1, 102, 50, 127)
KM_FOOT = (52, 102, 88, 127)
KM_BLADE = (90, 102, 127, 114)
KM_GRIP = (90, 116, 127, 127)
KM_BC, KM_BH, KM_BR = -1.7, 16.3, 15.8  # belly centre y, half height, radius
KM_B_LO, KM_B_HI = KM_BC - KM_BH, KM_BC + KM_BH
KM_H_LO, KM_H_HI = 12.5, 30.6
KM_SEAMS = [(90 + 60 * k) % 360 for k in range(6)]  # degrees about Y: +Z is 90, +X is 0 (revolve places u at (cos, y, sin))
KM_SEAM_A = [d / 360.0 for d in KM_SEAMS]


def seam_f(th):
    """1 on a seam column, 0 half way to the next one (th in radians)."""
    d = min(abs(wrapdiff(th / TAU, a)) for a in KM_SEAM_A) * 360.0
    return clamp(1.0 - d / 15.0)


def hood_mask(th, y):
    """How far the face opening is cut into the hood at (angle, height): 0..1."""
    d = abs(math.atan2(math.sin(th - math.pi / 2), math.cos(th - math.pi / 2)))
    return smooth(0.85, 0.4, d) * smooth(16.0, 18.0, y) * smooth(27.5, 25.0, y)


def build_scouser():
    mesh = Mesh()
    pts = []
    for k in range(11):
        ph = -math.pi / 2 + math.pi * k / 10
        pts.append((KM_BC + KM_BH * math.sin(ph), max(0.0, KM_BR * math.cos(ph))))

    def pinch(p, th, ax, r):
        f = seam_f(th)
        k = 1.8 * f * (r / KM_BR)
        if r < 1e-6:
            return p
        s = (r - k) / r
        return (p[0] * s, p[1], p[2] * s)

    revolve(mesh, "belly", [dict(pts=pts, rect=KM_BELLY, range=(KM_B_LO, KM_B_HI), disp=pinch)], KM_SEGS, 1)
    hood = [(12.5, 0.0), (12.5, 9.2), (14.5, 10.4), (17.0, 11.8), (20.0, 11.6), (23.0, 10.2), (26.0, 7.8), (28.6, 4.8), (30.4, 1.8), (30.6, 0.0)]

    def face(p, th, ax, r):
        m = hood_mask(th, ax)
        if m <= 0 or r < 1e-6:
            return p
        s = (r - 6.0 * m) / r
        return (p[0] * s, p[1], p[2] * s)

    revolve(mesh, "hood", [dict(pts=hood, rect=KM_HOOD, range=(KM_H_LO, KM_H_HI), disp=face)], 18, 1)
    # arms: the left hangs, the right is raised round a knife
    la = [(-12.5, 5.0, 1.5), (-15.2, 1.5, 3.5), (-16.0, -3.0, 5.2), (-15.6, -7.0, 6.8), (-15.4, -9.4, 7.6), (-15.3, -10.4, 8.0)]
    sweep(mesh, "larm", la, [4.0, 3.7, 3.4, 3.1, 2.3, 0.0], [4.0, 3.7, 3.4, 3.1, 2.3, 0.0], Z, 8, KM_ARM)
    ra = [(12.5, 5.0, 1.5), (15.0, 7.5, 4.5), (15.8, 11.5, 7.0), (16.0, 15.5, 8.8), (16.2, 17.6, 9.4), (16.2, 18.8, 9.4)]
    sweep(mesh, "rarm", ra, [3.8, 3.5, 3.2, 3.0, 2.3, 0.0], [3.8, 3.5, 3.2, 3.0, 2.3, 0.0], Z, 8, KM_ARM)
    kx, kz = 16.2, 9.4
    sweep(mesh, "grip", [(kx, 17.2, kz), (kx, 20.3, kz)], [0.95, 0.95], [0.95, 0.95], X, 6, KM_GRIP)
    sweep(mesh, "guard", [(kx - 2.4, 20.6, kz), (kx + 2.4, 20.6, kz)], [0.55, 0.55], [0.8, 0.8], Y, 4, KM_GRIP, flat=True, rot=math.pi / 4)
    ys = [20.9, 22.0, 26.5, 30.6]
    sweep(mesh, "blade", [(kx, y, kz) for y in ys], [1.5, 1.75, 1.4, 0.0], [0.4, 0.45, 0.4, 0.0], X, 4, KM_BLADE, flat=True)
    for sx in (-1, 1):
        ellipsoid(mesh, ("boot", sx), (sx * 6.4, -15.5, 7.4), 7.0, 4.2, 2.8, Z, X, 10, 6, KM_FOOT)
    return mesh


def paint_scouser():
    cloth = Fbm(141, 12, 8, 4)
    fine = Fbm(142, 50, 40, 2)
    weave = Fbm(143, 70, 70, 1)
    fray = Fbm(144, 8, 8, 3)
    span_b = KM_B_HI - KM_B_LO
    span_h = KM_H_HI - KM_H_LO

    def belly(a, t):
        y = KM_B_HI - t * span_b
        th = TAU * a
        f = seam_f(th)
        # taut panels: lighter in the middle of each panel (stretched), darker toward the seams
        mid = 1.0 - f
        col = mix((12, 16, 36), (54, 68, 112), smooth(0.3, 0.95, mid) * (0.6 + 0.4 * cloth.at(a, t)))
        col = shade(col, 0.82 + 0.3 * fine.at(a, t))
        col = mix(col, (130, 150, 204), 0.3 * smooth(0.72, 0.95, cloth.at(a * 2, t * 2)) * mid)  # strain streaks
        # the seam: dark pinch edges, a hot orange glow in the crease and a yellow core, with pale stitches crossing it
        dseam = min(abs(wrapdiff(a, s_)) for s_ in KM_SEAM_A)  # in turns
        col = mix(col, (150, 36, 8), 0.9 * smooth(0.034, 0.012, dseam))
        col = mix(col, (255, 128, 20), smooth(0.022, 0.006, dseam))
        col = mix(col, (255, 230, 120), smooth(0.009, 0.0, dseam))
        stitch = (y * 0.62) % 1.0
        if dseam < 0.026:
            col = mix(col, (236, 224, 176), 0.95 * smooth(0.26, 0.18, abs(stitch - 0.5)) * smooth(0.026, 0.016, dseam) * smooth(0.0, 0.01, dseam - 0.004))
        return col

    def hood(a, t):
        y = KM_H_HI - t * span_h
        th = TAU * a
        col = mix((8, 10, 24), (36, 46, 80), smooth(0.25, 0.85, cloth.at(a, t)))
        col = shade(col, 0.8 + 0.34 * fine.at(a, t))
        m = hood_mask(th, y)
        col = mix(col, (3, 3, 8), smooth(0.05, 0.4, m))  # the void
        col = mix(col, (96, 118, 176), 0.8 * smooth(0.22, 0.02, abs(m - 0.03)) * 0.6)  # a lit hem round the opening
        for ex in (-0.2, 0.2):  # pale slit eyes
            e = math.hypot((math.atan2(math.sin(th - math.pi / 2 - ex), math.cos(th - math.pi / 2 - ex))) / 0.11, (y - 21.6) / 0.85)
            col = mix(col, (200, 230, 255), smooth(1.0, 0.55, e))
        mth = math.hypot(math.atan2(math.sin(th - math.pi / 2), math.cos(th - math.pi / 2)) / 0.18, (y - 18.6) / 0.35)
        col = mix(col, (140, 160, 200), 0.55 * smooth(1.0, 0.6, mth) * smooth(0.05, 0.4, m))
        # stitched seam up the back of the hood
        db = abs(wrapdiff(a, 0.75))
        col = mix(col, (150, 36, 8), 0.9 * smooth(0.02, 0.008, db))
        col = mix(col, (255, 128, 20), smooth(0.011, 0.004, db))
        return col

    def arm(a, t):
        col = mix((10, 14, 32), (44, 56, 96), smooth(0.25, 0.85, cloth.at(a, t)))
        col = shade(col, 0.8 + 0.34 * fine.at(a, t))
        col = mix(col, (150, 36, 8), 0.9 * smooth(0.04, 0.015, abs(wrapdiff(a, 0.0))))  # a seam along the arm
        col = mix(col, (255, 128, 20), smooth(0.02, 0.006, abs(wrapdiff(a, 0.0))))
        skin = mix((226, 164, 116), (188, 126, 84), fine.at(a, t))
        return mix(col, skin, smooth(0.74, 0.8, t))  # the hand at the end

    def foot(a, t):
        col = mix((18, 14, 12), (66, 52, 40), cloth.at(a, t))
        return col

    def blade(a, t):  # a bright steel blade, cutting edges lighter
        col = mix((176, 186, 200), (236, 242, 250), smooth(0.2, 0.8, fine.at(a, t)))
        col = mix(col, (96, 106, 124), 0.9 * smooth(0.18, 0.0, abs(a - 0.5)))
        return mix(col, (255, 255, 255), 0.9 * smooth(0.1, 0.0, min(a, 1 - a)))

    def grip(a, t):
        col = mix((46, 28, 16), (124, 80, 44), cloth.at(a, t))
        return mix(col, (200, 170, 100), 0.8 * smooth(0.12, 0.0, abs(wrapdiff(a, 0.3))))

    tex = Texture((20.0, 24.0, 44.0), gain=1.25, sat=1.05)
    tex.region(KM_BELLY, belly)
    tex.region(KM_HOOD, hood)
    tex.region(KM_ARM, arm)
    tex.region(KM_FOOT, foot)
    tex.region(KM_BLADE, blade, wrap=False)
    tex.region(KM_GRIP, grip)
    return tex.render()


def build_inflated_knifeman():
    return build_scouser(), paint_scouser()


MODELS = [
    ("elephant_gun", build_elephant_gun, "SniperRifle"),
    ("rust_canister", build_rust_canister, "GasCanister"),
    ("field_radio", build_field_radio, "Radio"),
    ("stone_donkey", build_stone_donkey, "Donkey"),
    ("plague_arrow", build_plague_arrow, "Arrow"),
    ("inflated_knifeman", build_inflated_knifeman, "InflatedScouser"),
]


# ---------------------------------------------------------------- driver
def generate(only=None):
    """Build every model, validate with make_meshes' strict validator against this group's reference boxes. Returns
    ({filename: bytes}, {slug: stats})."""
    saved = (mm.VANILLA, mm.TOL, mm.TRI_MIN, mm.TRI_MAX)
    mm.VANILLA, mm.TOL, mm.TRI_MIN, mm.TRI_MAX = dict(VANILLA_MISC), TOL, TRI_MIN, TRI_MAX
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


def main():
    import argparse
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--out", default=str(mm.OUT))
    ap.add_argument("slugs", nargs="*")
    args = ap.parse_args()
    files, stats = generate(set(args.slugs) or None)
    out = Path(args.out)
    if args.check:
        bad = [n for n, d in files.items() if not (out / n).is_file() or (out / n).read_bytes() != d]
        print("misc meshes up to date" if not bad else "DIFFERS: " + ", ".join(bad))
        sys.exit(1 if bad else 0)
    out.mkdir(parents=True, exist_ok=True)
    for n, d in files.items():
        (out / n).write_bytes(d)
    for slug, s in stats.items():
        dev = [round((s["max"][k] - s["min"][k]) / (VANILLA_MISC[slug][2][k] - VANILLA_MISC[slug][1][k]) - 1, 3) for k in range(3)]
        print(f"{slug}: {s['vertices']} verts, {s['triangles']} tris, size dev {dev}, box {[round(v, 2) for v in s['min']]} .. {[round(v, 2) for v in s['max']]}")


if __name__ == "__main__":
    main()
