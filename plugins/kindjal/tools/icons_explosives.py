#!/usr/bin/env python3
"""Kindjal explosives icons: ripper, pipe-bomb, blast-keg, profane-grenade, plantain-hell, nail-cluster, bear-trap.

Same house style and primitives as make_icons.py (SDF shapes, cel() lenses lit from the upper left, thin near-black
outline, faint soft shadow, 256 px drawing that build() box-filters to 64 px). Each draw_* returns a 256x256 Canvas.
Fixed geometry and fixed seeds: deterministic. Stdlib only. Not wired into make_icons.build() here.
"""
import math
import random

from make_icons import *            # noqa: F401,F403  (primitives, palettes, Canvas, cel, stroke, crack, ...)
from make_icons import _sh

# ---------------------------------------------------------------- extra palettes
# wood (powder keg)
W0, W1, W2, W3 = (0x24, 0x16, 0x0C), (0x4C, 0x30, 0x18), (0x7A, 0x52, 0x28), (0xA6, 0x76, 0x3C)
# dull gold (profane cross)
Y0, Y1, Y2, Y3 = (0x4C, 0x34, 0x0C), (0x8C, 0x66, 0x16), (0xCA, 0x9C, 0x28), (0xF6, 0xDA, 0x76)
# black-violet orb
P0, P1, P2, P3 = (0x08, 0x07, 0x0C), (0x18, 0x14, 0x22), (0x2C, 0x26, 0x40), (0x58, 0x4E, 0x78)
# overripe banana skin
K0, K1, K2, K3 = (0x0C, 0x09, 0x07), (0x26, 0x1C, 0x0E), (0x4C, 0x3C, 0x18), (0x84, 0x70, 0x26)
# stem green
N0, N1, N2 = (0x1E, 0x24, 0x0E), (0x3C, 0x46, 0x1C), (0x66, 0x70, 0x30)
# electrical / duct tape
T0, T1, T2 = (0x5A, 0x4A, 0x14), (0x92, 0x7C, 0x26), (0xC4, 0xAA, 0x44)
# fuse rope
F0, F1, F2 = (0x3A, 0x2C, 0x1C), (0x7A, 0x62, 0x3E), (0xB4, 0x9A, 0x66)
# smoke
M0, M1 = (0x2A, 0x2A, 0x2C), (0x4A, 0x4A, 0x4C)


# ---------------------------------------------------------------- helpers
def ident(f):
    return f


def bez(p0, p1, p2, p3, n=18):
    pts = []
    for k in range(n + 1):
        t = k / n
        u = 1 - t
        pts.append((u * u * u * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0],
                    u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1]))
    return pts


def fuse(cv, pts, w=6.0):
    """Twisted rope fuse along a polyline, with a lighter strand and dark twist ticks."""
    stroke(cv, pts, w + 3.4, OUTLINE)
    stroke(cv, pts, w, F1)
    stroke(cv, [(x - 0.9, y - 1.1) for x, y in pts], w * 0.45, F2, 0.9)
    for k in range(2, len(pts) - 1, 2):
        a, b = pts[k], pts[k + 1]
        mx, my = (a[0] + b[0]) / 2, (a[1] + b[1]) / 2
        cv.paint(circle(mx, my, w * 0.3), F0, 0.8)


def spark(cv, x, y, r, rot=0.0):
    pts = []
    for k in range(8):
        a = rot + k * math.pi / 4
        rr = r if k % 2 == 0 else r * 0.36
        pts.append((x + math.cos(a) * rr, y + math.sin(a) * rr))
    cv.paint(polygon(pts, 0.5), E2)
    cv.paint(circle(x, y, r * 0.42), E3)


def ember(cv, x, y, r):
    cv.paint(circle(x, y, r + 1.6), E0, 0.45)
    cv.paint(circle(x, y, r), E2)
    cv.paint(circle(x, y, r * 0.5), E3)


def nail(cv, bx, by, ang, length, col=G2, hi=G3):
    """A nail seen from the side: shaft out of (bx,by) at angle ang (radians), pointed end."""
    ux, uy = math.cos(ang), math.sin(ang)
    px, py = -uy, ux
    sx, sy = bx + ux * (length - 8), by + uy * (length - 8)
    ex, ey = bx + ux * length, by + uy * length
    shape = union(capsule(bx, by, sx, sy, 3.2), polygon([(sx + px * 3.2, sy + py * 3.2), (ex, ey), (sx - px * 3.2, sy - py * 3.2)]))
    cv.paint(grow(shape, 2.2), OUTLINE)
    cv.paint(shape, col)
    cv.paint(capsule(bx - px * 0.8, by - py * 0.8, sx - px * 0.8, sy - py * 0.8, 0.9), hi, 0.9)


def nail_head(cv, x, y, r=4.2):
    cv.paint(circle(x, y, r + 2.0), OUTLINE)
    cv.paint(circle(x, y, r), G1)
    cv.paint(circle(x - 0.5, y - 0.6, r * 0.72), G2)
    cv.paint(circle(x - r * 0.35, y - r * 0.4, r * 0.3), G3)


def clipped_blots(cv, T, rng, clip, n, xr, yr, rr, col, alpha=1.0, flat=0.6):
    for _ in range(n):
        px, py = rng.uniform(*xr), rng.uniform(*yr)
        rx = rng.uniform(*rr)
        cv.paint(T(inter(ellipse(px, py, rx, rx * flat), clip)), col, alpha)


# ---------------------------------------------------------------- 1: Ripper (bazooka rocket)
def draw_ripper():
    cv = Canvas(SIZE, SIZE)
    O, ANG = (142, 118), -34

    def T(f):
        return place(f, O[0], O[1], ANG)

    def P(x, y):
        return rot_pt((x, y), O[0], O[1], ANG)

    rng = random.Random(41)
    body = rbox(-12, 0, 56, 23, 7)
    nose = polygon([(38, -21), (70, -15), (98, 0), (70, 15), (38, 21)], 3)

    # exhaust: smoke puffs far behind, then a ragged flame
    for sx, sy, sr, k in ((-146, 6, 11, 0), (-160, -10, 8, 1), (-132, 24, 7, 0)):
        c = P(sx, sy)
        cv.paint(circle(c[0], c[1], sr + 3), OUTLINE, 0.55)
        cv.paint(circle(c[0], c[1], sr), M1 if k else M0, 0.8)
    flame = polygon([(-66, -13), (-96, -19), (-118, -9), (-146, -3), (-120, 3), (-134, 13), (-98, 17), (-66, 13)], 4)
    cel(cv, T, flame, [E0, E1, E2, E3], [(8, 0), (18, 0), (34, 0)])

    # fins, behind the body: serrated top fin, shorter lower fin
    fin_top = polygon([(-8, -16), (-22, -40), (-28, -34), (-34, -52), (-41, -44), (-50, -62), (-57, -52), (-66, -56), (-74, -16)], 1.5)
    fin_bot = polygon([(-8, 16), (-22, 36), (-27, 30), (-35, 47), (-41, 40), (-52, 54), (-74, 16)], 1.5)
    cel(cv, T, fin_bot, [(0x08, 0x08, 0x0A), (0x14, 0x14, 0x18), (0x24, 0x24, 0x2A)], [(-2, -3), (-4, -5)])
    cel(cv, T, fin_top, [(0x08, 0x08, 0x0A), (0x14, 0x14, 0x18), (0x24, 0x24, 0x2A), (0x3C, 0x3C, 0x46)], [(-3, -3), (-6, -6), (-9, -9)])
    # nozzle
    cel(cv, T, rbox(-78, 0, 9, 17, 3), [G0, G1, G2], [(-1.5, -4), (-3, -8)], ow=2.8)
    cv.paint(T(ellipse(-84, 0, 3, 11)), E1)

    # matte black casing
    cel(cv, T, body, [(0x08, 0x08, 0x0A), (0x14, 0x14, 0x18), (0x24, 0x24, 0x2A), (0x3C, 0x3C, 0x46)], [(0, -7), (0, -13), (0, -18)])
    cv.paint(T(inter(box(-70, -22, 44, -19), body)), (0x9A, 0x92, 0xB0), 0.5)   # edge glint
    cv.paint(T(inter(box(-52, -23, -42, 23), body)), G1)                         # grey band
    cv.paint(T(inter(box(-52, -23, -49, 23), body)), G2, 0.8)
    cv.paint(T(inter(box(10, -23, 17, 23), body)), E0)                            # dull red stripe
    cv.paint(T(inter(box(10, -23, 12.5, 23), body)), E1, 0.8)
    for _ in range(9):                                                            # worn scratches
        x0 = rng.uniform(-50, 30)
        y0 = rng.uniform(-14, 14)
        q0, q1 = P(x0, y0), P(x0 + rng.uniform(5, 12), y0 + rng.uniform(-2, 2))
        stroke(cv, [q0, q1], 1.4, G2, 0.55, clip=T(body))
    # heat soaking back from the nose
    cv.paint(T(inter(box(24, -23, 42, 23), body)), E0, 0.55)
    cv.paint(T(inter(box(34, -23, 42, 23), body)), E1, 0.5)

    # red-hot nose
    cel(cv, T, nose, [E0, E1, E2, E3], [(-5, -7), (-11, -12), (-22, -17)])
    cv.paint(T(rbox(39, 0, 2.6, 21, 1)), OUTLINE)
    tip = P(98, 0)
    for ex, ey, er in ((224, 56, 2.8), (236, 78, 2.2), (206, 38, 2.2)):
        ember(cv, ex, ey, er)
    for ex, ey, er in ((30, 212, 3.0), (52, 232, 2.4), (14, 184, 2.2)):
        ember(cv, ex, ey, er)
    cv.shadow_under(5, 8, 3, 0.28)
    return cv


# ---------------------------------------------------------------- 2: Pipe Bomb
def draw_pipe_bomb():
    cv = Canvas(SIZE, SIZE)
    O, ANG = (108, 156), -27

    def T(f):
        return place(f, O[0], O[1], ANG)

    def P(x, y):
        return rot_pt((x, y), O[0], O[1], ANG)

    rng = random.Random(52)
    pipe = rbox(0, 0, 70, 27, 2)
    capl = rbox(-74, 0, 13, 34, 5)
    capr = rbox(74, 0, 13, 34, 5)

    cel(cv, T, pipe, [(0x34, 0x1A, 0x0E), R0, R1, R2], [(0, -6), (0, -12), (0, -17)], ow=3.2)
    # rust scale and bare steel showing through
    clipped_blots(cv, T, rng, pipe, 7, (-60, 60), (-22, 22), (5, 11), (0x3C, 0x1C, 0x0C), 0.8)
    clipped_blots(cv, T, rng, pipe, 3, (-60, 60), (-20, 0), (3, 6), G1, 0.8)
    clipped_blots(cv, T, rng, pipe, 0, (-60, 60), (-20, 0), (2.5, 5), G3, 0.9)
    cv.paint(T(inter(box(-70, -27, 70, -24), pipe)), R2, 0.8)
    # end caps
    for cap, bx in ((capl, -74), (capr, 74)):
        cel(cv, T, cap, [G0, G1, G2, G3], [(-2, -6), (-4, -12), (-6, -18)], ow=3.0)
        cv.paint(T(circle(bx, -22, 2.4)), G0)
        cv.paint(T(circle(bx, 22, 2.4)), G0)
        cv.paint(T(circle(bx - 0.6, -22.6, 1.1)), G3)
        cv.paint(T(circle(bx - 0.6, 21.4, 1.1)), G3)
    # tape band, frayed end hanging
    tape = rbox(-26, 0, 9, 28.5, 1)
    cel(cv, T, tape, [T0, T1, T2], [(-2.5, -3), (-5, -6)], ow=2.8)
    cv.paint(T(inter(box(-34, -24, -18, -22), tape)), T0, 0.7)
    frayed = polygon([(-34, 26), (-18, 26), (-19, 38), (-25, 34), (-31, 40)], 1.2)
    cel(cv, T, frayed, [T0, T1], [(-2, -3)], ow=2.4)
    # fuse hole and the lit fuse
    s = P(87, -3)
    cv.paint(circle(s[0], s[1], 5.5), OUTLINE)
    pts = bez(s, (s[0] + 40, s[1] + 2), (s[0] + 8, s[1] - 52), (s[0] + 40, s[1] - 66))
    fuse(cv, pts, 5.6)
    ex, ey = pts[-1]
    spark(cv, ex + 2, ey - 3, 13, 0.3)
    for sx, sy, sr in ((ex + 24, ey + 8, 2.8), (ex - 10, ey - 20, 2.4), (ex + 16, ey - 20, 2.2), (ex + 28, ey - 6, 1.8)):
        ember(cv, sx, sy, sr)
    cv.shadow_under(5, 8, 3, 0.30)
    return cv


# ---------------------------------------------------------------- 3: Blast Keg
def draw_blast_keg():
    cv = Canvas(SIZE, SIZE)
    O, ANG = (116, 164), 9

    def T(f):
        return place(f, O[0], O[1], ANG)

    def P(x, y):
        return rot_pt((x, y), O[0], O[1], ANG)

    rng = random.Random(63)
    keg = inter(ellipse(0, 0, 78, 150), box(-100, -78, 100, 78))
    lid = ellipse(0, -78, 69, 16)

    cel(cv, T, keg, [W0, W1, W2, W3], [(-8, -3), (-18, -7), (-30, -12)])
    # stave seams, fanned with the barrel's bulge
    for u in (-0.75, -0.4, 0.0, 0.4, 0.75):
        pts = [P(u * 64, -78), P(u * 77, -39), P(u * 80, 0), P(u * 77, 39), P(u * 64, 78)]
        stroke(cv, pts, 2.0, W0, 0.9, clip=T(keg))
    # iron hoops, curving down toward the viewer
    for yc, w in ((-62, 11), (-32, 9), (32, 9), (62, 11)):
        def edge(y0):
            return [(x, y0 + 7 * (1 - (x / 85.0) ** 2)) for x in range(-90, 91, 15)]
        band = polygon(edge(yc - w / 2) + list(reversed(edge(yc + w / 2))))
        b = T(inter(band, grow(keg, 1)))
        cv.paint(grow(b, 2.0), OUTLINE, 1.0)
        cv.paint(inter(T(grow(keg, 3.4)), b), G1)
        cv.paint(inter(b, T(inter(keg, shift(keg, -9, -3)))), G2)
        cv.paint(inter(b, T(inter(keg, shift(keg, -22, -6)))), G3, 0.85)
        for bx in (-50, -10, 34):
            q = P(bx * (1 + 0.0), yc + 7 * (1 - (bx / 85.0) ** 2))
            cv.paint(circle(q[0], q[1], 1.9), G0)
    # scorch: soot on the rim and low on the shadow side, a few live embers in the char
    soot = ((-8, 74, 56, 14), (52, 40, 22, 38), (46, -40, 14, 26), (-60, 60, 14, 16), (10, -76, 50, 10), (-30, 8, 8, 6))
    for sx, sy, rx, ry in soot:
        cv.paint(T(inter(ellipse(sx, sy, rx, ry), keg)), B0, 0.8)
    for sx, sy in ((20, 52), (-30, 64), (50, -8)):
        cv.paint(T(inter(circle(sx, sy, 3.2), keg)), E1)
        cv.paint(T(inter(circle(sx - 0.6, sy - 0.6, 1.4), keg)), E3)
    stroke(cv, [P(-44, 6), P(-36, 16), P(-42, 28)], 2.4, B0, 0.9, clip=T(keg))
    # lid
    cel(cv, T, lid, [W1, W2, W3], [(-4, -2), (-9, -4)], ow=3.0)
    cv.paint(T(inter(ring(0, -78, 38, 41), lid)), W1, 0.8)
    cv.paint(T(ellipse(0, -78, 22, 8)), B0, 0.55)
    cv.paint(T(ellipse(0, -78, 9, 4)), OUTLINE)                                    # bung hole
    cv.paint(T(ellipse(30, -78, 14, 5)), B0, 0.5)
    # sputtering fuse
    s = P(0, -80)
    pts = bez(s, (s[0] + 36, s[1] - 14), (s[0] - 30, s[1] - 38), (s[0] + 14, s[1] - 66))
    fuse(cv, pts, 5.4)
    ex, ey = pts[-1]
    spark(cv, ex + 1, ey - 2, 13, 0.5)
    for sx, sy, sr in ((ex + 26, ey - 4, 2.8), (ex - 18, ey + 8, 2.4), (ex + 12, ey - 24, 2.2), (ex - 14, ey - 22, 1.9),
                       (ex + 30, ey + 16, 1.8)):
        ember(cv, sx, sy, sr)
    cv.shadow_under(5, 8, 3, 0.30)
    return cv


# ---------------------------------------------------------------- 4: Profane Grenade
def draw_profane_grenade():
    cv = Canvas(SIZE, SIZE)
    O, ANG = (118, 152), 6

    def T(f):
        return place(f, O[0], O[1], ANG)

    def P(x, y):
        return rot_pt((x, y), O[0], O[1], ANG)

    rng = random.Random(74)
    sphere = circle(O[0], O[1], 80)

    # cap on top and a pin ring
    cap = rbox(0, -84, 17, 11, 3)
    cel(cv, T, cap, [Y0, Y1, Y2, Y3], [(-2.5, -3), (-5, -6), (-8, -8)], ow=3.0)
    rc = P(30, -92)
    pr = ring(rc[0], rc[1], 8, 13.5)
    cv.paint(grow(pr, 2.6), OUTLINE)
    cv.paint(pr, Y1)
    cv.paint(inter(pr, shift(pr, -2.5, -3)), Y2)
    cv.paint(inter(pr, shift(pr, -5, -6)), Y3, 0.9)
    # faint red halo, then the orb
    cv.paint(circle(O[0], O[1], 92), E0, 0.13)
    cel(cv, ident, sphere, [(0x06, 0x06, 0x08), (0x12, 0x10, 0x18), (0x22, 0x1E, 0x30), (0x44, 0x3E, 0x5C)], [(-9, -9), (-20, -22), (-34, -38)], ow=3.4)
    cv.paint(ellipse(O[0] - 46, O[1] - 50, 9, 4.2), (0xB8, 0xB0, 0xD8), 0.85)
    cv.paint(circle(O[0] - 58, O[1] - 36, 2.2), (0xB8, 0xB0, 0xD8), 0.75)

    # inverted gold cross: long arm up, crossbar low
    cross = union(rbox(0, -4, 13, 62, 2), rbox(0, 26, 38, 13, 2))
    cel(cv, T, cross, [Y0, Y1, Y2, Y3], [(-3, -3), (-6, -6), (-10, -10)], ow=3.2)
    cv.paint(T(rbox(0, -4, 2.6, 52, 1)), Y0, 0.45)
    cv.paint(T(rbox(0, 26, 30, 2.4, 1)), Y0, 0.45)

    # cracks: thin, dull red, running across the orb and through the cross
    cracks = []
    crack(rng, O[0] + 52, O[1] - 60, math.radians(120), 78, 1, cracks, 0.35)
    crack(rng, O[0] - 78, O[1] + 8, math.radians(10), 54, 1, cracks, 0.35)
    crack(rng, O[0] + 34, O[1] + 74, math.radians(-100), 64, 1, cracks, 0.35)
    for pts, depth in cracks:
        stroke(cv, pts, 13 - 3 * depth, E0, 0.32, clip=sphere)
    for pts, depth in cracks:
        stroke(cv, pts, 6.0 - 1.4 * depth, OUTLINE, 1.0, clip=sphere)
    for pts, depth in cracks:
        stroke(cv, pts, 3.8 - 0.9 * depth, E1, 1.0, clip=sphere)
    for pts, depth in cracks:
        stroke(cv, pts, 1.5, E3, 0.95, clip=sphere)
    for ex, ey, er in ((214, 52, 2.4), (28, 62, 2.2), (232, 112, 2.0)):
        ember(cv, ex, ey, er)
    cv.shadow_under(5, 8, 3, 0.30)
    return cv


# ---------------------------------------------------------------- 5: Plantain Hell
def banana(p0, p1, p2, r, n=16):
    pts = []
    circles = []
    for k in range(n + 1):
        t = k / n
        u = 1 - t
        x = u * u * p0[0] + 2 * u * t * p1[0] + t * t * p2[0]
        y = u * u * p0[1] + 2 * u * t * p1[1] + t * t * p2[1]
        pts.append((x, y))
        circles.append(circle(x, y, r * (0.34 + 0.66 * math.sin(math.pi * t) ** 0.6)))
    return union(*circles), pts


def draw_plantain_hell():
    cv = Canvas(SIZE, SIZE)
    rng = random.Random(85)
    C = (64, 88)
    hands = [
        ((C[0] - 2, C[1] + 6), (40, 190), (104, 244), 19),
        ((C[0] + 2, C[1] + 4), (92, 190), (176, 236), 19),
        ((C[0] + 4, C[1] + 2), (146, 150), (226, 196), 19),
        ((C[0] + 4, C[1] - 2), (190, 80), (234, 146), 19),
    ]
    shapes = []
    for p0, p1, p2, r in hands:
        shapes.append(banana(p0, p1, p2, r))
    for (shape, pts), (p0, p1, p2, r) in zip(shapes, hands):
        cel(cv, ident, shape, [K0, K1, K2], [(-4, -5), (-9, -11)], ow=3.2)
        # mould blotches, bruise spots, and a dark ridge along the spine
        for _ in range(9):
            q = pts[rng.randint(1, len(pts) - 2)]
            cv.paint(inter(circle(q[0] + rng.uniform(-9, 9), q[1] + rng.uniform(-9, 9), rng.uniform(1.8, 4.2)), shape), K0, 0.8)
        for _ in range(4):
            q = pts[rng.randint(2, len(pts) - 3)]
            cv.paint(inter(ellipse(q[0] - 7, q[1] - 8, rng.uniform(3, 5), rng.uniform(1.5, 2.4)), shape), K3, 0.8)
        stroke(cv, [(x + 2, y + 3) for x, y in pts[2:-2]], 2.2, K0, 0.5, clip=shape)
        tx, ty = pts[-1]
        cv.paint(circle(tx, ty, 5.0), K0)                                         # blackened tip
        cv.paint(circle(tx - 1, ty - 1, 1.8), K1)
    # crown: stems bound together
    crown = union(capsule(C[0] + 4, C[1] + 4, C[0] - 18, C[1] - 28, 11), capsule(C[0] - 18, C[1] - 28, C[0] - 22, C[1] - 38, 8))
    cel(cv, ident, crown, [N0, N1, N2], [(-2, -3), (-5, -6)], ow=3.0)
    cv.paint(rbox(C[0] - 6, C[1] - 6, 14, 3.2, 1.5), F1)                          # twine
    cv.paint(rbox(C[0] - 6.5, C[1] - 7, 13, 1.2, 0.6), F2, 0.9)
    # lit fuse out of the crown
    s = (C[0] - 20, C[1] - 36)
    pts = bez(s, (s[0] - 14, s[1] - 22), (s[0] + 30, s[1] - 12), (s[0] + 40, s[1] - 28))
    fuse(cv, pts, 5.2)
    ex, ey = pts[-1]
    spark(cv, ex + 1, ey - 2, 12, 0.2)
    for sx, sy, sr in ((ex + 24, ey + 6, 2.6), (ex + 14, ey - 20, 2.2), (ex - 8, ey - 18, 1.9), (ex + 34, ey - 10, 1.8)):
        ember(cv, sx, sy, sr)
    # fruit flies
    for fx, fy in ((132, 46), (108, 30), (240, 160), (46, 214), (150, 200)):
        cv.paint(ellipse(fx - 3.4, fy - 3.4, 4.2, 2.0), S3, 0.7)
        cv.paint(ellipse(fx + 3.4, fy - 3.0, 4.2, 2.0), S3, 0.7)
        cv.paint(circle(fx, fy, 3.0), OUTLINE)
        cv.paint(circle(fx - 0.6, fy - 0.6, 1.0), (0x8A, 0x20, 0x14))
    cv.shadow_under(5, 8, 3, 0.30)
    return cv


# ---------------------------------------------------------------- 6: Nail Cluster
def draw_nail_cluster():
    cv = Canvas(SIZE, SIZE)
    rng = random.Random(96)
    M = (92, 152)
    MR = 58

    def studded(cx, cy, r, spikes, heads, spike_len, head_r):
        body = circle(cx, cy, r)
        for deg in spikes:                                                # nails stabbing outward, behind the orb
            a = math.radians(deg)
            nail(cv, cx + math.cos(a) * (r - 6), cy + math.sin(a) * (r - 6), a, spike_len + rng.uniform(-2, 4),
                 R2 if rng.random() < 0.4 else G2, G3)
        cel(cv, ident, body, [G0, G1, G2, G3], [(-r * 0.10, -r * 0.10), (-r * 0.24, -r * 0.27), (-r * 0.40, -r * 0.46)],
            ow=3.2)
        for _ in range(int(r / 4.5)):
            px, py = rng.uniform(-r * 0.8, r * 0.8), rng.uniform(-r * 0.8, r * 0.8)
            if math.hypot(px, py) < r * 0.82:
                cv.paint(inter(ellipse(cx + px, cy + py, rng.uniform(4, 9) * r / 58, rng.uniform(2.5, 5) * r / 58), body),
                         R1 if rng.random() < 0.5 else R0, 0.85)
        for hx, hy in heads:
            nail_head(cv, cx + hx * r, cy + hy * r, head_r)

    # spoon lever first, behind the main orb
    spoon = polygon([(80, 98), (66, 98), (40, 128), (47, 134), (74, 108)], 2.5)
    cel(cv, ident, spoon, [G0, G1, G2], [(-1.5, -2), (-3, -4)], ow=2.8)
    studded(M[0], M[1], MR, (-170, -145, -120, -95, -65, -35, -5, 25, 55, 85, 115, 145, 175),
            ((-0.45, -0.1), (-0.1, -0.5), (0.35, -0.3), (0.45, 0.25), (-0.2, 0.3), (0.1, 0.62), (-0.62, 0.3), (0.15, -0.05),
             (-0.5, -0.55), (0.6, -0.05)), 28, 4.6)
    cap = rbox(M[0] + 6, M[1] - MR - 2, 14, 10, 3)
    cel(cv, ident, cap, [G0, G1, G2, G3], [(-2.5, -3), (-5, -6), (-8, -8)], ow=3.0)
    cv.paint(circle(M[0] + 6, M[1] - MR - 3, 3.6), OUTLINE)

    # trails and the split flash
    for (x0, y0, x1, y1) in ((150, 108, 166, 90), (160, 124, 178, 112), (164, 148, 182, 142), (156, 80, 168, 64)):
        stroke(cv, [(x0, y0), (x1, y1)], 4.4, OUTLINE, 0.6)
        stroke(cv, [(x0, y0), (x1, y1)], 2.4, G3, 0.7)
    # the two bomblets
    studded(194, 58, 27, (-150, -100, -50, 0, 40), ((-0.35, -0.2), (0.25, 0.3)), 14, 3.4)
    studded(226, 138, 24, (-60, -10, 40, 90, 130), ((-0.3, -0.25), (0.2, 0.35)), 13, 3.2)
    for (bx, by, d) in ((194, 58 - 27 - 2, 1), (226, 138 - 24 - 2, 1)):
        cv.paint(rbox(bx + 3, by + 1, 6, 4.5, 1.5), G1)
        cv.paint(rbox(bx + 2, by, 4, 2, 0.8), G3, 0.9)
    spark(cv, 170, 124, 10, 0.4)
    ember(cv, 236, 90, 2.6)
    ember(cv, 218, 102, 2.2)
    ember(cv, 150, 62, 2.0)
    cv.shadow_under(5, 8, 3, 0.30)
    return cv


# ---------------------------------------------------------------- 7: Bear Trap
def draw_bear_trap():
    cv = Canvas(SIZE, SIZE)
    O, ANG = (100, 108), -16

    def T(f):
        return place(f, O[0], O[1], ANG)

    def P(x, y):
        return rot_pt((x, y), O[0], O[1], ANG)

    rng = random.Random(107)
    rx, ry, bw = 88, 72, 19
    inner = ellipse(0, 0, rx - bw, ry - bw * 0.75)

    def make_jaw(sign):
        halfspace = box(-200, -200, 200, -13) if sign < 0 else box(-200, 13, 200, 200)
        band = inter(sub(ellipse(0, 0, rx, ry), inner), halfspace)
        teeth = []
        n = 8
        irx, iry = rx - bw, ry - bw * 0.75
        for k in range(n):
            t = 0.22 + (math.pi - 0.44) * (k + 0.5) / n
            dt = (math.pi - 0.44) / n * 0.46
            def ip(tt, s=1.0):
                return (math.cos(tt) * irx * s, sign * math.sin(tt) * iry * s)
            a, b = ip(t - dt, 1.04), ip(t + dt, 1.04)
            tip = ip(t, 0.72)
            teeth.append(polygon([a, tip, b], 1.2))
        return band, teeth

    # extruded undersides first, so the jaws sit proud of the ground
    jaws = [make_jaw(-1), make_jaw(1)]
    for band, teeth in jaws:
        cel(cv, T, shift(union(band, *teeth), 0, 9), [B0, B1], [(0, -2)], ow=3.0)
    for band, teeth in jaws:
        for tooth in teeth:
            cel(cv, T, tooth, [G2, G3, (0xC4, 0xD0, 0xC4)], [(-1.5, -2), (-3, -4)], ow=2.4)
        cel(cv, T, band, [G1, G2, G3], [(-2, -4), (-4, -8)], ow=3.0)
        clipped_blots(cv, T, rng, band, 6, (-80, 80), (-60, 60), (4, 9), R1, 0.8, 0.5)
        clipped_blots(cv, T, rng, band, 3, (-80, 80), (-60, 60), (2.5, 5), R2, 0.8, 0.5)
    # pivot plate across the middle with the tripped pressure pan
    bar = rbox(0, 0, 102, 11, 4)
    cel(cv, T, bar, [G0, G1, G2, G3], [(-2, -4), (-4, -8), (-6, -11)], ow=3.0)
    for bx in (-90, 90):
        cv.paint(T(circle(bx, 0, 4.8)), OUTLINE)
        cv.paint(T(circle(bx, 0, 3.2)), G0)
        cv.paint(T(circle(bx - 0.7, -0.8, 1.2)), G3)
    cv.paint(T(rbox(0, 5, 22, 15, 4)), OUTLINE)
    cv.paint(T(rbox(0, 4, 19.5, 12.5, 3)), B0)                              # the hole the pan has dropped into
    pan = place(shift(rbox(0, 0, 18, 11, 3), 0, 2), 0, 0, 7)
    cel(cv, T, pan, [R0, R1, R2], [(-3, -3), (-6, -6)], ow=2.6)
    cv.paint(T(place(rbox(-4, 0, 9, 2.0, 1.0), 0, 0, 7)), (0xC8, 0x90, 0x58), 0.75)
    latch = polygon([(22, -6), (34, -26), (42, -22), (32, 2)], 1.8)         # cocked trigger tongue
    cel(cv, T, latch, [G0, G1, G2], [(-1.5, -2), (-3, -4)], ow=2.6)
    # chain from the plate to a drag ring
    s = P(100, -2)
    path = bez(s, (s[0] + 52, s[1] - 6), (s[0] + 52, s[1] + 72), (s[0] + 6, s[1] + 128), 7)
    for k in range(len(path) - 1):
        a, b = path[k], path[k + 1]
        ang = math.degrees(math.atan2(b[1] - a[1], b[0] - a[0]))
        if k % 2 == 0:
            link = sub(ellipse(0, 0, 15, 9), ellipse(0, 0, 8.5, 3.6))
        else:
            link = rbox(0, 0, 11, 3.8, 2)
        mx, my = (a[0] + b[0]) / 2, (a[1] + b[1]) / 2
        cel(cv, lambda f, mx=mx, my=my, ang=ang: place(f, mx, my, ang), link, [G0, G1, G2], [(-1.5, -2), (-3, -4)], ow=2.6)
    e = path[-1]
    drag = sub(circle(e[0] + 4, e[1] + 16, 20), circle(e[0] + 4, e[1] + 16, 11))
    cel(cv, ident, drag, [G0, G1, G2, G3], [(-2, -3), (-5, -6), (-8, -9)], ow=3.0)
    cv.shadow_under(5, 8, 3, 0.30)
    return cv


ICONS = [("ripper", draw_ripper), ("pipe-bomb", draw_pipe_bomb), ("blast-keg", draw_blast_keg),
         ("profane-grenade", draw_profane_grenade), ("plantain-hell", draw_plantain_hell),
         ("nail-cluster", draw_nail_cluster), ("bear-trap", draw_bear_trap)]
