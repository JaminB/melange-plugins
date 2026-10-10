#!/usr/bin/env python3
"""Kindjal melee/gun weapon icons, drawn with the make_icons.py primitives (same house style).

Exports ICONS = [(slug, draw_fn)], each draw_fn() returning a 256x256 Canvas. Deterministic (fixed seeds).
"""
import math
import random

from make_icons import *  # noqa: F401,F403  (primitives, Canvas, cel, stroke, palettes)
from make_icons import (Canvas, SIZE, OUTLINE, G0, G1, G2, G3, R0, R1, R2, E0, E1, E2, E3, B0, B1, B2, B3,
                        C0, C1, C2, cel, stroke, place, rot_pt, circle, ellipse, rbox, box, capsule, ring,
                        polygon, grow, shift, inter, sub, union, smooth_union)

# dark wood
W0, W1, W2, W3 = (0x1E, 0x12, 0x0A), (0x3C, 0x24, 0x14), (0x5E, 0x3C, 0x20), (0x84, 0x58, 0x30)
# walnut
N0, N1, N2, N3 = (0x1A, 0x0E, 0x0A), (0x34, 0x1C, 0x14), (0x56, 0x30, 0x20), (0x78, 0x4A, 0x30)
# grimy cloth tape
T0, T1, T2 = (0x2A, 0x28, 0x22), (0x50, 0x4C, 0x40), (0x7C, 0x76, 0x62)
# blood
D0, D1, D2 = (0x3E, 0x06, 0x08), (0x7A, 0x0C, 0x0E), (0xB0, 0x1C, 0x18)
# brass
Y0, Y1, Y2, Y3 = (0x4A, 0x32, 0x0C), (0x86, 0x62, 0x1A), (0xC4, 0x9A, 0x34), (0xF0, 0xD0, 0x70)
# scarred flesh, charred
F0, F1, F2, F3 = (0x26, 0x16, 0x14), (0x4A, 0x2C, 0x26), (0x76, 0x4A, 0x3C), (0xA6, 0x72, 0x58)
# darker worn steel
H0, H1, H2, H3 = (0x0F, 0x12, 0x13), (0x1E, 0x24, 0x25), (0x34, 0x3D, 0x3B), (0x58, 0x64, 0x5E)
# smoke
K0, K1, K2 = (0x0A, 0x09, 0x0B), (0x17, 0x15, 0x19), (0x26, 0x23, 0x2A)


def chain_of(*caps):
    return union(*caps)


def polyline(pts, r):
    return union(*[capsule(a[0], a[1], b[0], b[1], r) for a, b in zip(pts, pts[1:])])


def ident(f):
    return f


def blood_drop(cv, x, y, r=7.0, tail=14):
    d = smooth_union(circle(x, y, r), polygon([(x - r * 0.62, y - r * 0.5), (x + r * 0.62, y - r * 0.5), (x, y - r - tail)], 1), 5)
    cel(cv, ident, d, [D0, D1, D2], [(-1.5, -2), (-3, -3.5)], ow=2.6)


def fleck(cv, x, y, r):
    cv.paint(circle(x, y, r + 1.4), OUTLINE, 0.85)
    cv.paint(circle(x, y, r), D1)
    cv.paint(circle(x - r * 0.3, y - r * 0.3, r * 0.45), D2)


# ---------------------------------------------------------------- nail bat
def draw_nail_bat():
    cv = Canvas(SIZE, SIZE)
    O, ANG = (124, 132), -42

    def T(f):
        return place(f, O[0], O[1], ANG)

    def P(x, y):
        return rot_pt((x, y), O[0], O[1], ANG)

    rng = random.Random(5)
    bat = polygon([(-96, -10), (-30, -13), (30, -23), (80, -29), (100, -20), (104, 0), (100, 20), (80, 29), (30, 23),
                   (-30, 13), (-96, 10)], 3)
    knob = rbox(-102, 0, 9, 16, 6)
    # nails behind the bat first (the lower side), then the bat, then upper nails
    nails_dn = [(36, 1), (56, 0), (76, 1), (94, 0)]
    nails_up = [(30, 0), (50, 1), (70, 0), (90, 1)]

    def nail(x, side, k):
        base = side * 24
        bend = (6 + 3 * k) * (1 if k % 2 else -1)
        pts = [(x, base - side * 3), (x + bend * 0.3, base + side * 20), (x + bend, base + side * 33 + k * 2),
               (x + bend + (11 if k % 2 else -11), base + side * 38 + k * 2)]
        body = polyline(pts, 4.2)
        cv.paint(T(grow(body, 2.4)), OUTLINE)
        cv.paint(T(body), G2)
        cv.paint(T(polyline([(p[0] - 1.0, p[1] - 1.0) for p in pts[:3]], 1.3)), G3, 0.95)
        cv.paint(inter(T(polyline(pts[2:], 3.4)), T(box(-300, -300, 300, 300))), R1, 0.0)
        tp = pts[3]
        cv.paint(T(polyline([(tp[0] + (pts[2][0] - tp[0]) * 0.4, tp[1] + (pts[2][1] - tp[1]) * 0.4), tp], 3.4)), R1, 0.95)

    for k, (x, _) in enumerate(nails_dn):
        nail(x, 1, k)
    cel(cv, T, knob, [W0, W1, W2], [(-2, -3), (-4, -6)])
    cel(cv, T, bat, [W0, W1, W2, W3], [(0, -5), (0, -9), (0, -13)])
    # grain
    for _ in range(7):
        gx = rng.uniform(-10, 85)
        gy = rng.uniform(-14, 14) * (0.4 + gx / 150)
        stroke(cv, [P(gx, gy), P(gx + rng.uniform(14, 28), gy + rng.uniform(-1.5, 1.5))], 1.6, W0, 0.6, clip=T(bat))
    # tape on the grip: grimy bands with diagonal edges, loose end at the top
    for k in range(5):
        x0 = -92 + k * 14
        band = polygon([(x0, -16), (x0 + 11, -16), (x0 + 15, 16), (x0 + 4, 16)], 0)
        cv.paint(inter(T(band), T(bat)), T1)
        cv.paint(inter(T(band), T(shift(bat, 0, 0))), T0, 0.0)
        cv.paint(inter(T(box(x0 - 2, -16, x0 + 18, -3)), inter(T(band), T(bat))), T2, 0.9)
        cv.paint(inter(T(box(x0 - 2, 7, x0 + 18, 14)), inter(T(band), T(bat))), T0, 0.9)
    cv.paint(T(inter(box(-92, -1, -22, 1.2), bat)), OUTLINE, 0.0)
    flap = polygon([(-26, -10), (-12, -13), (-10, -3), (-24, -2)], 1)
    cel(cv, T, flap, [T0, T1, T2], [(-1.2, -1.5), (-2.5, -3)], ow=2.2)
    # head hits: dents, nail heads on the wood, blood
    for k, (x, _) in enumerate(nails_up):
        pass
    for k, (x, _) in enumerate(nails_dn):
        cv.paint(T(ellipse(x, 21, 4.6, 3.2)), G0)
    # upper nails drawn in front, base on the top edge
    for k, (x, _) in enumerate(nails_up):
        nail(x, -1, k + 1)
    for k, (x, _) in enumerate(nails_up):
        cv.paint(T(ellipse(x, -21, 4.8, 3.2)), G0)
        cv.paint(T(circle(x - 0.8, -21.5, 1.4)), G2, 0.9)
    # end-grain nails poking from the face of the head
    for ny in (-11, 11):
        cv.paint(T(circle(103, ny, 3.8)), OUTLINE)
        cv.paint(T(circle(103, ny, 2.6)), G2)
    # blood
    for (bx, by, br) in ((84, -6, 6), (66, 8, 4.6), (92, 6, 3.2), (48, -9, 3.6)):
        e = T(inter(ellipse(bx, by, br * 1.5, br), bat))
        cv.paint(e, D1)
        cv.paint(inter(e, shift(e, -1.5, -1.5)), D2, 0.8)
    fleck(cv, 215, 200, 4.4)
    fleck(cv, 226, 186, 2.6)
    fleck(cv, 202, 214, 2.4)
    cv.shadow_under(5, 8, 3, 0.30)
    return cv


# ---------------------------------------------------------------- hellfist
def flame(pts, r=2):
    return polygon(pts, r)


def draw_hellfist():
    cv = Canvas(SIZE, SIZE)
    O, ANG = (128, 156), 12

    def T(f):
        return place(f, O[0], O[1], ANG)

    # black smoke billowing up behind
    for (sx, sy, sr, c) in ((52, 56, 30, K1), (96, 28, 28, K1), (150, 22, 30, K1), (202, 46, 28, K1), (232, 84, 20, K1),
                            (26, 98, 18, K1), (118, 8, 18, K2)):
        cel(cv, ident, circle(sx, sy, sr), [K0, K1, K2], [(-3, -3), (-7, -7)], ow=2.8)
    # a crown of flame behind the fist: one jagged, leaning silhouette, dark red-orange with a small hot core
    crown = polygon([(36, 214), (20, 170), (40, 128), (30, 84), (58, 112), (70, 64), (92, 104), (110, 40), (128, 100), (150, 24),
                     (166, 96), (190, 58), (200, 108), (222, 90), (216, 142), (238, 176), (220, 214), (128, 236)], 9)
    cel(cv, ident, crown, [(0x5A, 0x0E, 0x06), E0, E1], [(-3, -8), (-6, -20)], ow=3.0)
    core = polygon([(70, 190), (66, 150), (88, 128), (104, 96), (124, 130), (148, 80), (164, 130), (186, 112), (190, 160), (176, 196)], 10)
    cv.paint(core, E2, 0.85)
    for sx, sy, sr in ((70, 34, 22), (116, 14, 20), (176, 10, 22), (222, 44, 20), (28, 58, 16)):
        cel(cv, ident, circle(sx, sy, sr), [K0, K1, K2], [(-3, -3), (-6, -6)], ow=2.6)
    # fist (local frame: knuckles up)
    wrist = rbox(0, 76, 36, 30, 8)
    cel(cv, T, wrist, [F0, F1, F2], [(-4, -2), (-9, -3)])
    cuff = rbox(0, 98, 40, 12, 4)
    cel(cv, T, cuff, [B0, B1, B2], [(-2, -2), (-4, -4)], ow=2.8)
    for rx in (-30, -10, 10, 30):
        cv.paint(T(circle(rx, 98, 2.2)), G2)
    palm = rbox(0, 12, 54, 52, 18)
    cel(cv, T, palm, [F0, F1, F2, F3], [(-5, -4), (-11, -9), (-19, -14)])
    # four knuckle bumps
    for kx in (-39, -13, 13, 39):
        k = circle(kx, -34 + (4 if abs(kx) > 30 else 0), 15)
        cel(cv, T, k, [F0, F1, F2, F3], [(-3, -3), (-6, -6), (-9, -9)], ow=2.8)
        ky = -34 + (4 if abs(kx) > 30 else 0)
        cv.paint(T(ellipse(kx - 3, ky - 5, 7, 4)), E2, 0.85)       # lit by the flames
        cv.paint(T(ellipse(kx - 3, ky - 6, 3.4, 1.8)), E3)
    # finger creases curling in
    for fx in (-26, 0, 26):
        stroke(cv, [T(circle(0, 0, 1)) and rot_pt((fx, -22), O[0], O[1], ANG), rot_pt((fx, -2), O[0], O[1], ANG)], 3.4, OUTLINE, 1.0)
    # thumb across the front
    thumb = rbox(-8, 34, 38, 15, 12)
    cel(cv, T, thumb, [F0, F1, F2, F3], [(-3, -3), (-7, -6), (-11, -9)], ow=3.0)
    cv.paint(T(ellipse(-32, 28, 5, 3)), E2, 0.8)
    # scars: pale stitched slashes and a burn
    stroke(cv, [rot_pt((-30, 4), O[0], O[1], ANG), rot_pt((-10, 26), O[0], O[1], ANG)], 2.4, F3, 0.8)
    for sx in (-26, -20, -14):
        stroke(cv, [rot_pt((sx - 3, 12 + (sx + 26) * 0.2), O[0], O[1], ANG), rot_pt((sx + 3, 4 + (sx + 26) * 0.5), O[0], O[1], ANG)],
               1.6, F0, 0.9)
    stroke(cv, [rot_pt((26, 6), O[0], O[1], ANG), rot_pt((38, 22), O[0], O[1], ANG), rot_pt((32, 38), O[0], O[1], ANG)],
           2.6, F0, 0.9)
    cv.paint(T(ellipse(30, 46, 9, 5)), F0, 0.7)
    # embers
    for ex, ey, er in ((24, 44, 3.2), (240, 60, 3.0), (80, 12, 2.6), (186, 12, 2.4), (246, 130, 2.4)):
        cv.paint(circle(ex, ey, er + 1.6), E0, 0.45)
        cv.paint(circle(ex, ey, er), E2)
        cv.paint(circle(ex, ey, er * 0.5), E3)
    cv.shadow_under(5, 8, 3, 0.30)
    return cv


# ---------------------------------------------------------------- shiv
def draw_shiv():
    cv = Canvas(SIZE, SIZE)
    O, ANG = (112, 134), -44

    def T(f):
        return place(f, O[0], O[1], ANG)

    # jagged ground blade: straight spine, saw-tooth cutting edge, ragged tip
    blade = polygon([(8, -17), (60, -21), (118, -17), (154, -3), (160, 0),
                     (132, 8), (126, 22), (110, 11), (88, 20), (74, 11), (60, 21), (46, 12), (30, 19), (14, 12), (8, 14)], 1.5)
    guard_stub = rbox(8, 0, 6, 22, 3)
    handle = polygon([(-84, -14), (4, -16), (4, 16), (-84, 18)], 5)
    cel(cv, T, handle, [T0, T1, T2], [(0, -4), (0, -8)], ow=3.0)
    # tape wraps: diagonal bands
    for k in range(6):
        x0 = -80 + k * 14
        band = polygon([(x0, -17), (x0 + 3, -17), (x0 + 11, 19), (x0 + 8, 19)], 0)
        cv.paint(inter(T(band), T(handle)), T0, 0.9)
    # frayed end
    for fy in (-10, -2, 6, 13):
        stroke(cv, [rot_pt((-84, fy), O[0], O[1], ANG), rot_pt((-98, fy + (fy * 0.4)), O[0], O[1], ANG)], 3.2, OUTLINE)
        stroke(cv, [rot_pt((-84, fy), O[0], O[1], ANG), rot_pt((-96, fy + (fy * 0.4)), O[0], O[1], ANG)], 1.6, T1)
    cel(cv, T, guard_stub, [T0, T1, T2], [(-1.5, -2), (-3, -4)], ow=2.8)
    cel(cv, T, blade, [G0, G1, G2, G3], [(0, -6), (0, -11), (0, -15)])
    # chips and a worn central ridge
    cv.paint(T(inter(box(10, -2.5, 132, 0), blade)), G3, 0.0)
    stroke(cv, [rot_pt((14, -9), O[0], O[1], ANG), rot_pt((124, -5), O[0], O[1], ANG)], 2, G3, 0.8, clip=T(blade))
    stroke(cv, [rot_pt((20, 4), O[0], O[1], ANG), rot_pt((100, 6), O[0], O[1], ANG)], 1.6, G0, 0.7, clip=T(blade))
    for rx, ry, rr in ((40, -10, 6), (78, -9, 5), (24, 2, 4)):
        cv.paint(inter(T(ellipse(rx, ry, rr * 1.5, rr)), T(blade)), R1, 0.8)
    # old blood in the teeth
    cv.paint(inter(T(box(90, 4, 130, 22)), T(blade)), D1, 0.8)
    tip = rot_pt((160, 0), O[0], O[1], ANG)
    blood_drop(cv, tip[0] + 6, tip[1] + 28, 7.4, 16)
    fleck(cv, tip[0] + 18, tip[1] + 6, 2.4)
    cv.shadow_under(5, 8, 3, 0.30)
    return cv


# ---------------------------------------------------------------- railspike
def draw_railspike():
    """A big rust-orange railroad spike driven into a dark sleeper, a smaller steel sledge raised behind it."""
    cv = Canvas(SIZE, SIZE)
    rng = random.Random(9)
    # sledge hammer behind and up-left: dark haft running down-left, light steel head
    OH, AH = (68, 72), 27

    def TH(f):
        return place(f, OH[0], OH[1], AH)

    SL = ((0x2A, 0x32, 0x3A), (0x5C, 0x6A, 0x74), (0x98, 0xA8, 0xB2), (0xD8, 0xE4, 0xE8))
    cel(cv, TH, rbox(0, 62, 8, 58, 4), [W0, W1, W2], [(-2, -2), (-4, -3)], ow=3.0)
    head = rbox(0, 0, 46, 22, 5)
    cel(cv, TH, head, list(SL), [(-1, -6), (-2, -11), (-4, -15)], ow=3.2)
    cel(cv, TH, rbox(-46, 0, 7, 27, 3), list(SL[:3]), [(-1, -4), (-2, -8)], ow=2.8)
    cel(cv, TH, rbox(46, 0, 7, 27, 3), list(SL[:3]), [(-1, -4), (-2, -8)], ow=2.8)
    # the spike: a big rust-orange iron nail, point down-right, flared head
    O, ANG = (146, 128), 58

    def T(f):
        return place(f, O[0], O[1], ANG)

    ZP = ((0x5C, 0x20, 0x0A), (0xA8, 0x46, 0x14), (0xE0, 0x7C, 0x2A), (0xFF, 0xB8, 0x62))
    shank = polygon([(-72, -14), (60, -10), (112, 0), (60, 10), (-72, 14)], 1.5)
    cap = polygon([(-108, -37), (-72, -25), (-72, 25), (-108, 37)], 3)
    cel(cv, T, shank, list(ZP), [(0, -5), (0, -8), (0, -10)])
    cel(cv, T, cap, list(ZP), [(-2, -6), (-4, -11), (-6, -16)])
    cv.paint(T(inter(box(-76, -26, -70, 26), cap)), ZP[0], 0.8)           # neck shadow under the flare
    for _ in range(12):
        rx, ry = rng.uniform(-100, 70), rng.uniform(-9, 9)
        if rx < -72:
            ry *= 2.4
        cv.paint(inter(T(circle(rx, ry, rng.uniform(1.6, 3.6))), T(union(shank, cap))), ZP[0], 0.8)
    for sx, sy, sl in ((-30, 6, 36), (28, -6, 24)):                          # darker rust streaks
        cv.paint(inter(T(ellipse(sx, sy, sl, 4)), T(shank)), ZP[0], 0.7)
    stroke(cv, [rot_pt((-66, -9), O[0], O[1], ANG), rot_pt((90, -2), O[0], O[1], ANG)], 3.0, ZP[3], 0.8, clip=T(shank))
    stroke(cv, [rot_pt((-100, -30), O[0], O[1], ANG), rot_pt((-100, 28), O[0], O[1], ANG)], 2.4, ZP[3], 0.7, clip=T(cap))
    # the sleeper: a dark wooden plank across the bottom, the spike buried in it
    px, py = rot_pt((105, 0), O[0], O[1], ANG)
    plank = rbox(128, 232, 126, 20, 3)
    cel(cv, IDENT_M, plank, [W0, W1, W2], [(-2, -3), (-4, -6)], ow=3.2)
    for gy in (222, 232, 242):
        stroke(cv, [(10, gy + rng.uniform(-1, 1)), (120, gy + rng.uniform(-2, 2)), (248, gy + rng.uniform(-1, 1))], 1.6, W0, 0.7, clip=plank)
    cv.paint(inter(box(0, 212, 256, 215), plank), W3, 0.7)               # lit top edge
    cv.paint(inter(ellipse(px, 213, 20, 5.5), plank), OUTLINE)            # torn hole around the spike
    cv.paint(inter(ellipse(px + 1, 213, 16, 3.6), plank), (0x05, 0x03, 0x02))
    for sx, sy, a, k in ((px - 26, 206, -30, 1.0), (px - 36, 196, -60, 1.2), (px + 28, 202, 25, 1.0), (px + 38, 190, 55, 1.1), (px + 14, 192, 10, 0.8)):
        c, s_ = math.cos(math.radians(a)), math.sin(math.radians(a))
        pts = [(sx + k * (c * x - s_ * y), sy + k * (s_ * x + c * y)) for x, y in ((-13, -3.5), (13, -2), (9, 3.5))]
        cel(cv, IDENT_M, polygon(pts, 0.6), [W1, W2, W3], [(-1, -1), (-1.5, -1.5)], ow=2.2)
    # sparks at the point
    sy0 = 205
    for ang, ln, w in ((-100, 34, 4), (-60, 44, 4), (-20, 32, 3.4), (-140, 30, 3.4), (-80, 52, 3), (-40, 56, 3)):
        a = math.radians(ang)
        a0, a1 = (px + math.cos(a) * 8, sy0 + math.sin(a) * 8), (px + math.cos(a) * ln, sy0 + math.sin(a) * ln)
        stroke(cv, [a0, a1], w + 2.4, E0, 0.6)
        stroke(cv, [a0, a1], w, E2)
        stroke(cv, [a0, a1], w * 0.4, E3)
    cv.paint(circle(px, sy0, 11), E0, 0.55)
    cv.paint(circle(px, sy0, 6), E2)
    cv.paint(circle(px, sy0, 3), E3)
    for ex, ey, er in ((px + 40, sy0 - 40, 2.6), (px - 30, sy0 - 46, 2.4), (px + 52, sy0 - 12, 2.2)):
        cv.paint(circle(ex, ey, er + 1.4), E0, 0.45)
        cv.paint(circle(ex, ey, er), E3)
    cv.shadow_under(5, 8, 3, 0.30)
    return cv


IDENT_M = lambda f: f  # noqa: E731


# ---------------------------------------------------------------- slug gun
def draw_slug_gun():
    cv = Canvas(SIZE, SIZE)
    O, ANG = (118, 108), -22

    def T(f):
        return place(f, O[0], O[1], ANG)

    stock = polygon([(-100, -16), (-40, -14), (-40, 30), (-70, 44), (-96, 30)], 6)
    cel(cv, T, stock, [W0, W1, W2, W3], [(-3, -3), (-6, -6), (-9, -9)])
    rng = random.Random(3)
    for _ in range(5):
        gx = rng.uniform(-92, -48)
        gy = rng.uniform(-6, 30)
        stroke(cv, [rot_pt((gx, gy), O[0], O[1], ANG), rot_pt((gx + 18, gy + rng.uniform(-3, 3)), O[0], O[1], ANG)], 1.6, W0, 0.6, clip=T(stock))
    guard = ring(-24, 30, 10, 18)
    cv.paint(T(grow(guard, 2.4)), OUTLINE)
    cv.paint(T(guard), G1)
    cv.paint(T(capsule(-20, 24, -18, 36, 2.4)), G2)
    cel(cv, T, rbox(-24, 4, 24, 22, 6), [H0, H1, H2, H3], [(0, -4), (0, -8), (0, -12)])
    for bx in (-24, ):
        cv.paint(T(circle(bx - 8, 4, 3)), G0)
    # twin sawn barrels
    for by in (1, 1):
        pass
    for k, by in enumerate((-12, 13)):
        b = rbox(32, by, 62, 13, 4)
        cel(cv, T, b, [H0, H1, H2, H3], [(0, -4), (0, -8), (0, -11)], ow=3.0)
        for rx, ry, rr in ((20 + 30 * k, by - 3, 6), (60 - 30 * k, by + 4, 5)):
            cv.paint(inter(T(ellipse(rx, ry, rr * 1.5, rr * 0.7)), T(b)), R1, 0.85)
        mouth = ellipse(94, by, 4.5, 11)
        cv.paint(T(grow(mouth, 2.4)), OUTLINE)
        cv.paint(T(mouth), (0x04, 0x04, 0x05))
        cv.paint(T(ellipse(93, by - 3, 1.8, 4)), G2, 0.7)
    cel(cv, T, rbox(36, 1, 62, 3.4, 1.5), [H0, H1], [(0, -1)], ow=2.0)
    cel(cv, T, rbox(-4, 1, 6, 28, 3), [B0, B1, B2], [(-1, -3), (-2, -6)], ow=2.8)       # barrel clamp band
    cel(cv, T, rbox(60, 1, 5, 28, 3), [B0, B1, B2], [(-1, -3), (-2, -6)], ow=2.8)
    # two fat slugs: lead-grey bullets with a rust cuff, lower right
    for (sx, sy, sa) in ((176, 192, -62), (212, 176, -52)):
        sl = place(union(rbox(0, 0, 36, 15, 7), polygon([(26, -15), (50, -8), (50, 8), (26, 15)], 7)), sx, sy, sa)
        cv.paint(grow(sl, 3.2), OUTLINE)
        cv.paint(sl, G0)
        cv.paint(inter(sl, shift(sl, -3, -4)), G1)
        cv.paint(inter(sl, shift(sl, -6, -8)), G2)
        cv.paint(inter(sl, shift(sl, -9, -11)), G3, 0.9)
        cuff = place(rbox(-20, 0, 8, 15, 0), sx, sy, sa)
        cv.paint(inter(cuff, sl), Y1)
        cv.paint(inter(inter(cuff, sl), shift(cuff, -3, -4)), Y2)
        cv.paint(inter(place(box(-22, -15, -12, -9), sx, sy, sa), sl), Y3, 0.9)
        base = place(rbox(-36, 0, 3, 15, 0), sx, sy, sa)
        cv.paint(inter(base, sl), Y0)
    cv.shadow_under(5, 8, 3, 0.30)
    return cv


# ---------------------------------------------------------------- elephant gun
def draw_elephant_gun():
    cv = Canvas(SIZE, SIZE)
    O, ANG = (122, 138), -26

    def T(f):
        return place(f, O[0], O[1], ANG)

    stock = polygon([(-122, -10), (-52, -14), (-44, 14), (-60, 18), (-92, 36), (-120, 30)], 5)
    cel(cv, T, stock, [N0, N1, N2, N3], [(-3, -3), (-6, -6), (-9, -9)])
    rng = random.Random(4)
    for _ in range(6):
        gx = rng.uniform(-112, -60)
        gy = rng.uniform(-6, 24)
        stroke(cv, [rot_pt((gx, gy), O[0], O[1], ANG), rot_pt((gx + 22, gy + rng.uniform(-3, 2)), O[0], O[1], ANG)], 1.6, N0, 0.6, clip=T(stock))
    cel(cv, T, rbox(-118, 12, 4, 20, 2), [Y0, Y1, Y2], [(-1, -3), (-2, -6)], ow=2.4)    # butt plate (brass)
    # forestock under the barrel
    fore = rbox(52, 24, 52, 10, 4)
    cel(cv, T, fore, [N0, N1, N2, N3], [(0, -3), (0, -6), (0, -8)])
    guard = ring(-34, 28, 9, 16)
    cv.paint(T(grow(guard, 2.4)), OUTLINE)
    cv.paint(T(guard), G1)
    # long fat barrel
    barrel = rbox(34, 0, 98, 19, 5)
    cel(cv, T, barrel, [H0, H1, H2, H3], [(0, -5), (0, -9), (0, -13)])
    cel(cv, T, rbox(-30, 0, 24, 22, 5), [H0, H1, H2, H3], [(0, -5), (0, -9), (0, -14)])    # receiver
    for rx, ry, rr in ((0, -4, 8), (50, 6, 6), (84, -5, 5)):
        cv.paint(inter(T(ellipse(rx, ry, rr * 1.5, rr * 0.7)), T(barrel)), R1, 0.8)
    # brass bands
    for bx in (12, 62):
        band = rbox(bx, 0, 6, 24, 2)
        cel(cv, T, band, [Y0, Y1, Y2, Y3], [(-1, -3), (-2, -7), (-3, -11)], ow=2.8)
    # front sight and big brass muzzle ring
    cel(cv, T, polygon([(104, -19), (112, -19), (108, -31)], 1), [H0, H1, H2], [(-1, -2), (-2, -4)], ow=2.2)
    muz = rbox(130, 0, 8, 25, 3)
    cel(cv, T, muz, [Y0, Y1, Y2, Y3], [(-1, -3), (-2, -7), (-3, -11)], ow=2.8)
    mouth = ellipse(135, 0, 9, 21)
    cv.paint(T(grow(mouth, 2.4)), OUTLINE)
    cv.paint(T(mouth), (0x03, 0x03, 0x04))
    cv.paint(T(ellipse(133, -3, 4, 12)), G1, 0.9)
    cv.paint(T(ellipse(132, -7, 1.8, 5)), G2, 0.9)
    cv.shadow_under(5, 8, 3, 0.30)
    return cv


# ---------------------------------------------------------------- gibbet turret
def draw_gibbet_turret():
    cv = Canvas(SIZE, SIZE)
    # base plate and post
    cel(cv, ident, rbox(54, 236, 40, 8, 3), [B0, B1, B2, B3], [(-1, -2), (-2, -4), (-3, -6)], ow=3.0)
    post = rbox(54, 140, 9, 100, 3)
    cel(cv, ident, post, [B0, B1, B2, B3], [(-2, 0), (-4, 0), (-6, 0)], ow=3.2)
    # diagonal brace
    brace = polygon([(60, 100), (63, 70), (130, 28), (134, 36)], 3)
    cel(cv, ident, brace, [B0, B1, B2], [(-1, -2), (-2, -3)], ow=2.8)
    # horizontal arm
    arm = rbox(142, 28, 100, 10, 3)
    cel(cv, ident, arm, [B0, B1, B2, B3], [(0, -2), (0, -4), (0, -6)], ow=3.2)
    # rivets
    for rx, ry in ((54, 28), (54, 120), (54, 210), (100, 31)):
        cv.paint(circle(rx, ry, 3), B3)
        cv.paint(circle(rx - 0.8, ry - 0.8, 1.2), G3)
    # chain hanging from the arm
    links = []
    for k in range(7):
        cy = 44 + k * 14
        links.append((100, cy, k % 2))
    for cx, cy, o in links:
        lk = ring(cx, cy, 2.4, 5.2) if False else None
        e = ellipse(cx, cy, 5.2 if o else 3, 8.5 if o else 8.5)
        if o:
            e = ellipse(cx, cy, 6.2, 9)
        r_ = sub(e, grow(e, -3.4))
        cv.paint(grow(r_, 2.0), OUTLINE)
        cv.paint(r_, G1)
        cv.paint(inter(r_, shift(r_, -1.5, -1.5)), G2)
    hook = ring(100, 160, 6, 11)
    cv.paint(grow(hook, 2.4), OUTLINE)
    cv.paint(hook, G1)
    cv.paint(inter(hook, shift(hook, -2, -2)), G2)
    cel(cv, ident, rbox(100, 172, 3, 10, 2), [H0, H1], [(-1, -1)], ow=2.4)
    # turret body hanging beneath the arm end on a yoke
    cel(cv, ident, rbox(186, 52, 4, 16, 1), [B0, B1, B2], [(-1, -2), (-2, -4)], ow=2.6)
    cel(cv, ident, rbox(186, 92, 48, 38, 8), [H0, H1, H2, H3], [(-5, -5), (-10, -10), (-16, -16)], ow=3.4)
    # side plate rivets and rust
    for rx, ry in ((156, 74), (214, 74), (156, 112), (214, 112)):
        cv.paint(circle(rx, ry, 2.8), G0)
        cv.paint(circle(rx - 0.8, ry - 0.8, 1.2), G3)
    cv.paint(inter(ellipse(172, 104, 12, 6), rbox(186, 92, 48, 38, 8)), R1, 0.9)
    cv.paint(inter(ellipse(206, 78, 9, 4), rbox(186, 92, 48, 38, 8)), R1, 0.9)
    # drum magazine
    cel(cv, ident, circle(168, 142, 21), [B0, B1, B2, B3], [(-3, -3), (-6, -6), (-9, -9)], ow=3.0)
    cv.paint(circle(168, 142, 7), G1)
    cv.paint(ring(168, 142, 7, 9), OUTLINE)
    cv.paint(circle(166.5, 140.5, 2.6), G3)
    # barrel to the right, with a shroud
    cel(cv, ident, rbox(226, 100, 22, 11, 3), [H0, H1, H2, H3], [(0, -3), (0, -6), (0, -8)], ow=3.0)
    cel(cv, ident, rbox(238, 100, 8, 16, 2), [B0, B1, B2, B3], [(-1, -3), (-2, -6), (-3, -9)], ow=2.8)
    # glowing muzzle
    cv.paint(circle(250, 100, 17), E0, 0.35)
    cv.paint(circle(250, 100, 11), E1, 0.7)
    cv.paint(circle(250, 100, 7), E2)
    cv.paint(circle(249.5, 99.5, 3.6), E3)
    cv.shadow_under(5, 8, 3, 0.30)
    return cv


ICONS = [
    ("nail-bat", draw_nail_bat),
    ("hellfist", draw_hellfist),
    ("shiv", draw_shiv),
    ("railspike", draw_railspike),
    ("slug-gun", draw_slug_gun),
    ("elephant-gun", draw_elephant_gun),
    ("gibbet-turret", draw_gibbet_turret),
]
