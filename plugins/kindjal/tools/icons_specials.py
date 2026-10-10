#!/usr/bin/env python3
"""Six more Kindjal weapon icons, drawn with make_icons' SDF toolkit: the 'special' variants of the base weapons.

Same house style as draw_spitter / draw_flask / draw_crucible: dark gritty palette, thin near-black outline,
three-tone cel shading from the upper left, tilted pose filling the 256 px frame, a faint soft shadow. Deterministic
(fixed seeds), stdlib only. This module only defines the drawings; make_icons.build() turns each into the 64 px PNG
and the 256 px TGA.
"""
import math
import random

from make_icons import *  # noqa: F401,F403  (SDF primitives, Canvas, cel, stroke, crack, palette, SIZE)

IDENT = lambda f: f

# plum-black shawl / cloth
P0, P1, P2, P3 = (0x10, 0x0D, 0x14), (0x1E, 0x18, 0x26), (0x32, 0x28, 0x3E), (0x52, 0x44, 0x60)
# night-blue hoodie
N0, N1, N2, N3 = (0x0E, 0x12, 0x1C), (0x1A, 0x22, 0x34), (0x2C, 0x38, 0x50), (0x4A, 0x5A, 0x78)
# dim skin
K0, K1, K2, K3 = (0x30, 0x20, 0x1C), (0x5C, 0x42, 0x38), (0x8A, 0x68, 0x56), (0xB4, 0x90, 0x78)
# sickly fat flesh
F0, F1, F2, F3 = (0x3C, 0x20, 0x1C), (0x6C, 0x3E, 0x30), (0x9A, 0x62, 0x48), (0xC8, 0x92, 0x70)
# stained shirt
H0, H1, H2 = (0x26, 0x2A, 0x18), (0x44, 0x4C, 0x2A), (0x6A, 0x72, 0x3E)
# roast meat
M0, M1, M2, M3 = (0x38, 0x1A, 0x0C), (0x78, 0x3C, 0x14), (0xB4, 0x68, 0x26), (0xE6, 0xA6, 0x4A)
# bone
O0, O1, O2, O3 = (0x4A, 0x44, 0x38), (0x8E, 0x86, 0x70), (0xCC, 0xC4, 0xA8), (0xEC, 0xE6, 0xD0)
# hemp rope
W0, W1, W2 = (0x3A, 0x2A, 0x16), (0x7C, 0x5E, 0x34), (0xB8, 0x98, 0x5E)
# grease
GR = (0xE8, 0xD0, 0x7A)
# drum rust, darker iron
X0, X1, X2 = (0x22, 0x12, 0x0A), (0x44, 0x22, 0x12), (0x6C, 0x38, 0x18)
# faded hazard yellow
Y0, Y1, Y2 = (0x8A, 0x70, 0x10), (0xD0, 0xB0, 0x20), (0xF0, 0xD8, 0x48)


def drop(x, y, length, r):
    """A hanging poison/grease drip: neck from (x, y) down `length`, bead at the bottom."""
    d = smooth_union(circle(x, y, r * 0.9), capsule(x, y, x, y + length, r * 0.55), r * 1.2)
    return union(d, circle(x, y + length + r * 0.6, r))


def paint_alpha_cel(cv, f, cols, offs, alphas, outline=OUTLINE_G, ow=3.0, oalpha=0.6):
    cv.paint(grow(f, ow), outline, oalpha)
    cv.paint(f, cols[0], alphas[0])
    for col, (dx, dy), a in zip(cols[1:], offs, alphas[1:]):
        cv.paint(inter(f, shift(f, dx, dy)), col, a)


# ---------------------------------------------------------------- hangwoman: the old woman
def draw_hangwoman():
    cv = Canvas(SIZE, SIZE)
    rng = random.Random(41)

    hem = polygon([(24, 205), (26, 240), (44, 226), (58, 246), (78, 229), (98, 247), (120, 230), (140, 246),
                   (160, 229), (180, 242), (196, 215)])
    shawl = union(smooth_union(ellipse(106, 178, 84, 62), circle(66, 128, 52), 34), hem)
    cel(cv, IDENT, shawl, [P0, P1, P2, P3], [(-6, -8), (-14, -18), (-24, -28)])
    # torn hem shadow and folds
    shl = inter(shawl, shift(shawl, 0, 0))
    for pts in ([(40, 150), (56, 190), (50, 226)], [(92, 178), (96, 208), (92, 236)], [(138, 192), (146, 214), (150, 236)],
                [(30, 124), (44, 150), (62, 160)]):
        stroke(cv, pts, 3.4, P0, 0.9, clip=shl)
    for _ in range(7):
        cv.paint(inter(ellipse(rng.uniform(40, 180), rng.uniform(150, 232), rng.uniform(4, 9), rng.uniform(3, 6)), shawl),
                 P3, 0.35)

    # sleeve and bony hand
    sleeve = capsule(146, 160, 196, 172, 15)
    cel(cv, IDENT, sleeve, [P0, P1, P2], [(-2, -4), (-5, -8)], ow=3.0)
    # the noose: coil knot, rope tail, loop
    loop = ring(214, 220, 17, 26)
    cel(cv, IDENT, loop, [W0, W1, W2], [(-2, -2), (-4, -4)], ow=3.0)
    for k in range(14):
        a = k * 2 * math.pi / 14 + 0.3
        cx, cy = 214 + math.cos(a) * 21.5, 220 + math.sin(a) * 21.5
        stroke(cv, [(cx - math.sin(a) * 3.6 - math.cos(a) * 1.5, cy + math.cos(a) * 3.6 - math.sin(a) * 1.5),
                    (cx + math.sin(a) * 3.6 + math.cos(a) * 1.5, cy - math.cos(a) * 3.6 + math.sin(a) * 1.5)], 1.6, W0, 0.8)
    knot = rbox(214, 191, 9, 13, 3)
    cel(cv, IDENT, knot, [W0, W1, W2], [(-1.5, -2), (-3, -4)], ow=2.8)
    for k in range(4):
        stroke(cv, [(206, 183 + k * 6), (222, 188 + k * 6)], 2.0, W0, 0.9, clip=knot)
    cel(cv, IDENT, capsule(210, 178, 203, 168, 3.2), [W0, W1, W2], [(-1, -1), (-2, -2)], ow=2.4)
    cel(cv, IDENT, polygon([(222, 180), (234, 168), (230, 184)], 1), [W0, W1], [(-1, -1)], ow=2.0)
    # hand over the rope
    hand = union(circle(204, 172, 10), capsule(204, 172, 214, 180, 5))
    cel(cv, IDENT, hand, [K0, K1, K2], [(-2, -2), (-4, -4)], ow=2.8)
    for fx in (198, 206, 213):
        stroke(cv, [(fx, 170), (fx + 3, 183)], 1.6, K0, 0.9, clip=hand)

    # hood and face
    hood = smooth_union(circle(152, 100, 40), polygon([(114, 84), (150, 50), (182, 66)]), 14)
    cel(cv, IDENT, hood, [P0, P1, P2, P3], [(-5, -6), (-11, -13), (-18, -20)])
    stroke(cv, [(126, 86), (140, 66), (160, 56)], 3, P0, 0.9, clip=hood)
    void = ellipse(168, 106, 21, 26)
    cv.paint(grow(void, 3.2), P0)
    cv.paint(void, (0x04, 0x03, 0x06))
    cv.paint(inter(grow(void, 7), shift(grow(void, 7), -3, -3)), P3, 0.0)
    # hooked nose and chin catching a little light, one glinting eye
    cv.paint(inter(polygon([(180, 108), (194, 122), (176, 120)], 1), grow(void, 1)), K1)
    cv.paint(inter(ellipse(172, 124, 11, 5), grow(void, 1)), K1)
    cv.paint(circle(171, 97, 13), (0xE8, 0xC8, 0x40), 0.22)
    cv.paint(circle(171, 97, 8), (0xE8, 0xC8, 0x40), 0.35)
    cv.paint(ellipse(171, 97, 6.4, 5.0), (0xF4, 0xEC, 0xA0))
    cv.paint(circle(173, 98, 2.4), (0x10, 0x08, 0x04))
    cv.paint(circle(169, 95, 1.3), (0xFF, 0xFF, 0xFF))
    stroke(cv, [(160, 90), (171, 90), (181, 94)], 3, P0, 1.0)             # heavy brow
    # grey hair straying from the hood
    for pts in ([(140, 110), (136, 126), (140, 138)], [(146, 118), (144, 134)]):
        stroke(cv, pts, 2.2, (0x88, 0x84, 0x8C), 0.85)
    cv.shadow_under(5, 8, 3, 0.32)
    return cv


# ---------------------------------------------------------------- knifeman: the scouser as a street fighter
def draw_knifeman():
    cv = Canvas(SIZE, SIZE)

    torso = rbox(112, 204, 90, 46, 34)
    cel(cv, IDENT, torso, [N0, N1, N2, N3], [(-5, -5), (-11, -11), (-18, -17)])
    # kangaroo pocket and seams
    pocket = polygon([(66, 208), (160, 208), (172, 244), (54, 244)], 3)
    cv.paint(inter(pocket, torso), N0, 0.9)
    stroke(cv, [(66, 208), (160, 208)], 2.6, N3, 0.65, clip=torso)
    stroke(cv, [(112, 160), (112, 204)], 3, N0, 0.8, clip=torso)

    # left (viewer) arm hanging, fist low
    arm_l = capsule(40, 192, 36, 226, 17)
    cel(cv, IDENT, arm_l, [N0, N1, N2], [(-3, -4), (-6, -8)], ow=3.0)
    cel(cv, IDENT, circle(36, 236, 12), [K0, K1, K2], [(-2, -2), (-4, -4)], ow=2.8)

    # hood: dark cowl with a black hole of a face
    hood = smooth_union(circle(112, 106, 54), ellipse(112, 150, 62, 24), 24)
    cel(cv, IDENT, hood, [N0, N1, N2, N3], [(-6, -7), (-13, -15), (-21, -23)])
    face = ellipse(116, 112, 33, 38)
    cv.paint(grow(face, 3.6), N0)
    cv.paint(face, (0x03, 0x04, 0x07))
    cv.paint(inter(grow(face, 12), shift(face, 0, 0)), N0, 0.0)
    for ex in (103, 128):                       # two cold slits of eye in the dark
        cv.paint(ellipse(ex, 108, 6, 2.2), (0x86, 0x92, 0xA0), 0.55)
    cv.paint(ellipse(116, 140, 9, 2), (0x30, 0x34, 0x3C), 0.7)
    # drawstrings
    for sx, ex in ((94, 90), (130, 134)):
        stroke(cv, [(sx, 148), (ex, 186)], 3.6, N0, 1.0)
        stroke(cv, [(sx, 148), (ex, 186)], 1.8, (0x8A, 0x90, 0x9C), 1.0)
        cv.paint(circle(ex, 188, 3.6), (0x8A, 0x90, 0x9C))
    # right arm raised, fist, knife
    arm_r = capsule(176, 186, 204, 142, 18)
    cel(cv, IDENT, arm_r, [N0, N1, N2], [(-3, -4), (-6, -8)], ow=3.0)
    O, ANG = (206, 130), 14
    T = lambda f: place(f, O[0], O[1], ANG)
    blade = polygon([(-9, -18), (9, -18), (9, -72), (-1, -100), (-9, -66)], 1)
    cel(cv, T, blade, [G0, G1, G2, G3], [(-2.5, 0), (-5, 0), (-7.5, 0)], ow=2.8)
    cv.paint(T(inter(box(7.5, -70, 9, -18), blade)), (0xE8, 0xF0, 0xF0), 0.9)
    cv.paint(T(inter(polygon([(-1, -98), (6, -72), (2, -72)]), blade)), (0xE8, 0xF0, 0xF0), 0.7)
    cel(cv, T, rbox(0, -14, 17, 4, 2), [G0, G1, G2], [(-1, -1), (-2, -2)], ow=2.6)
    cel(cv, T, rbox(0, 6, 8, 18, 4), [C0, C1, C2], [(-1.5, -2), (-3, -4)], ow=2.6)
    cel(cv, IDENT, circle(206, 138, 14), [K0, K1, K2], [(-2, -2), (-4, -4)], ow=2.8)
    for k in range(3):
        stroke(cv, [(197 + k * 9, 128), (199 + k * 9, 146)], 1.8, K0, 0.9)
    # glint and a dark smear near the point
    gx, gy = rot_pt((0, -70), O[0], O[1], ANG)
    cv.paint(polygon([(gx - 12, gy), (gx, gy - 3), (gx + 12, gy), (gx, gy + 3)]), (0xFF, 0xFF, 0xFF), 0.85)
    cv.paint(polygon([(gx - 3, gy - 12), (gx, gy), (gx + 3, gy - 12)]), (0xFF, 0xFF, 0xFF), 0.85)
    cv.shadow_under(5, 8, 3, 0.32)
    return cv


# ---------------------------------------------------------------- gorger: fatkins falling, drumstick in hand
def draw_gorger():
    cv = Canvas(SIZE, SIZE)
    O, ANG = (130, 142), 8

    def T(f):
        return place(f, O[0], O[1], ANG)

    def P(x, y):
        return rot_pt((x, y), O[0], O[1], ANG)

    # speed streaks above, falling
    for sx, sy, ln in ((30, 14, 40), (56, 4, 30), (222, 22, 44), (244, 44, 34), (200, 6, 28)):
        a, b = (sx, sy), (sx - 7, sy + ln)
        stroke(cv, [a, b], 3.2, (0xA8, 0xA8, 0xB0), 0.32)

    # legs, shoes up and flailing
    for lx0, lx1, ly1 in ((-38, -52, 82), (36, 56, 80)):
        cel(cv, T, capsule(lx0, 50, lx1, ly1, 15), [H0, H1, H2], [(-2, -3), (-5, -6)], ow=3.0)
        cel(cv, T, ellipse(lx1 - 6, ly1 + 8, 22, 10), [C0, C1, C2], [(-2, -2), (-4, -4)], ow=2.8)
    # far arm flung out, fingers spread
    arm_r = capsule(70, -22, 104, -54, 14)
    cel(cv, T, arm_r, [F0, F1, F2], [(-2, -3), (-5, -6)], ow=3.0)
    cel(cv, T, circle(112, -62, 13), [F0, F1, F2], [(-2, -2), (-4, -4)], ow=2.8)

    body = ellipse(0, 0, 92, 74)
    cel(cv, T, body, [H0, H1, H2, (0x8A, 0x92, 0x56)], [(-7, -7), (-16, -16), (-26, -26)])
    # belly hanging out under the shirt
    belly = inter(body, box(-100, 30, 100, 100))
    cv.paint(T(belly), F1)
    cv.paint(T(inter(belly, shift(body, -8, -10))), F2)
    cv.paint(T(inter(belly, shift(body, -18, -22))), F3, 0.9)
    stroke(cv, [P(-88, 30), P(-40, 38), P(0, 40), P(44, 36), P(88, 28)], 2.6, OUTLINE, 0.9, clip=T(body))
    cv.paint(T(ellipse(4, 54, 5, 3)), F0)
    # stains
    for (sx, sy, rx, ry) in ((-30, -10, 14, 10), (24, 2, 10, 7), (-56, 6, 8, 6)):
        cv.paint(T(inter(ellipse(sx, sy, rx, ry), body)), H0, 0.85)
    cv.paint(T(circle(2, 18, 4)), OUTLINE, 0.9)                                   # straining button

    # head, chins
    head = smooth_union(circle(8, -78, 38), ellipse(10, -54, 44, 24), 16)
    cel(cv, T, head, [F0, F1, F2, F3], [(-5, -6), (-11, -13), (-18, -20)])
    # the open maw
    maw = ellipse(14, -70, 26, 22)
    cv.paint(T(grow(maw, 3)), OUTLINE)
    cv.paint(T(maw), (0x2A, 0x06, 0x0A))
    cv.paint(T(inter(ellipse(14, -58, 18, 10), maw)), (0x94, 0x24, 0x2C))
    cv.paint(T(inter(ellipse(10, -61, 10, 4), maw)), (0xD0, 0x58, 0x58), 0.8)
    for k in range(5):
        tx = -6 + k * 9.5
        cv.paint(T(inter(polygon([(tx - 4.5, -94), (tx + 4.5, -94), (tx, -81)], 0.8), maw)), O3)
    for k in range(4):
        tx = -1 + k * 9.5
        cv.paint(T(inter(polygon([(tx - 4, -46), (tx + 4, -46), (tx, -57)], 0.8), maw)), O2)
    # small furious eyes
    for ex in (-8, 24):
        cv.paint(T(ellipse(ex, -100, 5.4, 4.2)), OUTLINE)
        cv.paint(T(circle(ex, -100, 2.0)), (0xF0, 0xE8, 0xC0))
    stroke(cv, [P(-16, -111), P(-2, -106)], 3.4, F0)
    stroke(cv, [P(32, -111), P(18, -106)], 3.4, F0)
    # grease: sheen on forehead, belly and chin, drips from the lip
    cv.paint(T(ellipse(-12, -98, 9, 3.6)), GR, 0.8)
    cv.paint(T(ellipse(-50, -16, 4, 18)), GR, 0.5)
    cv.paint(T(ellipse(-24, 48, 14, 3.2)), (0xFF, 0xF2, 0xC0), 0.7)
    for dx, dl in ((-6, 26), (24, 14)):
        d = T(drop(dx, -44, dl, 3.8))
        cel(cv, IDENT, d, [(0x7A, 0x56, 0x14), (0xB4, 0x84, 0x2A), GR], [(-1.2, -1.5), (-2.2, -3)], ow=2.2)

    # near arm and the drumstick
    cel(cv, T, capsule(-64, -26, -84, -62, 15), [F0, F1, F2], [(-2, -3), (-5, -6)], ow=3.0)
    hx, hy = -88, -70
    S = lambda f: place(f, O[0] + 0, O[1] + 0, ANG)  # local frame stays the body's; the stick is tilted on its own
    tx, ty = P(hx, hy)
    stick_ang = ANG - 26
    ST = lambda f: place(f, tx, ty, stick_ang)
    meat = sub(sub(ellipse(0, -36, 25, 32), circle(-23, -54, 9)), circle(-9, -66, 8))
    cel(cv, ST, capsule(0, -10, 0, 16, 5), [O0, O1, O2], [(-1.5, -1), (-3, -2)], ow=2.6)
    for kx in (-5, 5):
        cel(cv, ST, circle(kx, 20, 6.4), [O0, O1, O2, O3], [(-1.5, -1.5), (-3, -3), (-4, -4)], ow=2.4)
    cel(cv, ST, meat, [M0, M1, M2, M3], [(-4, -5), (-9, -11), (-14, -17)])
    cv.paint(ST(ellipse(-9, -48, 5, 8)), GR, 0.8)
    cv.paint(ST(circle(-3, -28, 2)), M0, 0.7)
    cel(cv, T, circle(hx, hy, 14), [F0, F1, F2], [(-2, -2), (-4, -4)], ow=2.8)
    for k in range(3):
        stroke(cv, [P(hx - 8 + k * 8, hy - 8), P(hx - 8 + k * 8, hy + 6)], 1.8, F0, 0.9)
    cv.shadow_under(5, 8, 3, 0.30)
    return cv


# ---------------------------------------------------------------- dead-star: a collapsed black star
def draw_dead_star():
    cv = Canvas(SIZE, SIZE)
    rng = random.Random(77)
    C = (128, 130)
    tips = [122, 98, 116, 90, 124, 96, 110, 102, 118, 92]
    n = len(tips)
    pts = []
    for i in range(n):
        ta = math.radians(i * 360 / n - 90 + rng.uniform(-6, 6))
        va = math.radians((i + 0.5) * 360 / n - 90 + rng.uniform(-5, 5))
        vr = rng.uniform(40, 52)
        pts.append((C[0] + math.cos(ta) * tips[i], C[1] + math.sin(ta) * tips[i]))
        for t in (0.34, 0.68):                                  # jagged, slightly concave edge down into the valley
            a = ta + (va - ta) * t
            r = tips[i] + (vr - tips[i]) * t
            r -= 10 * math.sin(math.pi * t) + rng.uniform(-2, 6)
            pts.append((C[0] + math.cos(a) * r, C[1] + math.sin(a) * r))
        pts.append((C[0] + math.cos(va) * vr, C[1] + math.sin(va) * vr))
        na = math.radians((i + 1) * 360 / n - 90)
        for t in (0.34, 0.68):
            a = va + (na - va) * t
            nr = tips[(i + 1) % n]
            r = vr + (nr - vr) * t
            r -= 10 * math.sin(math.pi * t) + rng.uniform(-2, 6)
            pts.append((C[0] + math.cos(a) * r, C[1] + math.sin(a) * r))
    star = polygon(pts, 1.0)
    cel(cv, IDENT, star, [B0, B1, B2, B3], [(-5, -6), (-11, -13), (-18, -20)], ow=3.4)
    # hot glow bleeding into the dark body, then the crater
    cv.paint(inter(circle(*C, 62), star), E0, 0.20)
    cv.paint(inter(circle(*C, 48), star), E0, 0.28)
    # hot cracks from the core, clipped to the star
    cracks = []
    for k in range(7):
        crack(rng, C[0], C[1], math.radians(k * 51 + rng.uniform(-14, 14)), rng.uniform(70, 104), 1, cracks, 0.5)
    for pts2, depth in cracks:
        stroke(cv, pts2, 10 - 3 * depth, E0, 0.30, clip=star)
    for pts2, depth in cracks:
        stroke(cv, pts2, 4.6 - 1.4 * depth, E1, 1.0, clip=star)
    for pts2, depth in cracks:
        stroke(cv, pts2, 2.0 - 0.5 * depth, E2, 1.0, clip=star)
    crater = circle(*C, 34)
    cv.paint(grow(crater, 3.2), OUTLINE)
    cv.paint(crater, B0)
    for r, col in ((29, E0), (23, E1), (16, E2), (8, E3)):
        cv.paint(circle(C[0] - (29 - r) * 0.12, C[1] - (29 - r) * 0.12, r), col)
    cv.paint(ellipse(C[0] - 9, C[1] - 11, 5, 2.6), (0xFF, 0xFF, 0xE0), 0.9)
    # ash flakes drifting around, a few embers
    for _ in range(26):
        ang = rng.uniform(0, 2 * math.pi)
        rad = rng.uniform(100, 135)
        x, y = C[0] + math.cos(ang) * rad, C[1] + math.sin(ang) * rad * 0.95
        if not (6 < x < 250 and 6 < y < 250) or star(x, y) < 6:
            continue
        r = rng.uniform(2.0, 4.6)
        flake = polygon([(x - r, y - r * 0.3), (x + r * 0.2, y - r), (x + r, y + r * 0.4), (x - r * 0.3, y + r)])
        cv.paint(flake, rng.choice([G1, G2, G2, G3]), rng.uniform(0.55, 0.9))
    for ex, ey, er in ((30, 40, 3.0), (226, 36, 2.6), (232, 214, 3.2), (24, 218, 2.4)):
        cv.paint(circle(ex, ey, er + 1.6), E0, 0.45)
        cv.paint(circle(ex, ey, er), E2)
        cv.paint(circle(ex, ey, er * 0.5), E3)
    cv.shadow_under(5, 7, 3, 0.30)
    return cv


# ---------------------------------------------------------------- plague-arrow: a bow and a poisoned arrow
def draw_plague_arrow():
    cv = Canvas(SIZE, SIZE)
    rng = random.Random(9)
    O, ANG = (122, 134), -36

    def T(f):
        return place(f, O[0], O[1], ANG)

    def P(x, y):
        return rot_pt((x, y), O[0], O[1], ANG)

    STRING = (0xB0, 0xA8, 0x90)
    # bow: a deep arc, black grip wrap, drawn string
    arc = inter(ring(-64, 0, 95, 106), box(-12, -120, 60, 120))
    cel(cv, T, arc, [C0, C1, C2], [(-2, -3), (-4, -6)], ow=3.0)
    grip = rbox(41, 0, 6, 17, 3)
    cel(cv, T, grip, [B0, B1, B2], [(-1, -1.5), (-2, -3)], ow=2.6)
    tipa, tipb = (-12, -88), (-12, 88)
    for tp in (tipa, tipb):
        cel(cv, T, circle(tp[0], tp[1], 6.5), [C0, C1, C2], [(-1, -1.5), (-2, -3)], ow=2.6)
    sp = [P(*tipa), P(-96, 0), P(*tipb)]
    stroke(cv, sp, 5.0, OUTLINE, 1.0)
    stroke(cv, sp, 2.2, STRING, 1.0)

    # arrow shaft
    shaft = capsule(-96, 0, 100, 0, 6.5)
    cel(cv, T, shaft, [C0, C1, C2], [(0, -2.2), (0, -4.2)], ow=3.0)
    # sickly poison soaked into the shaft near the head
    pois = inter(capsule(40, 0, 100, 0, 6.5), box(30, -8, 110, 8))
    cv.paint(T(pois), A0, 0.85)
    cv.paint(T(inter(pois, shift(pois, 0, -2.2))), A1, 0.9)
    cv.paint(T(inter(pois, shift(pois, 0, -4.2))), A2, 0.9)
    for bx in (-8, 12):                                      # wrapped bands
        cv.paint(T(box(bx, -7, bx + 3, 7)), (0x16, 0x11, 0x0E))
    # fletching: three black, ragged vanes
    for sgn in (-1, 1):
        vane = polygon([(-100, sgn * 5), (-60, sgn * 5), (-52, sgn * 20), (-56, sgn * 24), (-66, sgn * 22),
                        (-72, sgn * 31), (-84, sgn * 27), (-92, sgn * 36), (-104, sgn * 28)], 1.5)
        cel(cv, T, vane, [B0, B1, B2, B3], [(2, -3), (4, -6), (6, -9)], ow=2.8)
        for k in range(3):
            stroke(cv, [P(-96 + k * 12, sgn * 8), P(-90 + k * 12, sgn * 26)], 1.6, B0, 0.9)
    cel(cv, T, rbox(-100, 0, 4, 7, 2), [B0, B1, B2], [(-1, -1), (-2, -2)], ow=2.4)
    # poisoned broadhead, glowing a little
    head = polygon([(92, 0), (112, -21), (142, 0), (112, 21)], 1.5)
    cv.paint(T(grow(head, 7)), A1, 0.20)
    cel(cv, T, head, [A0, A1, A2, A3], [(-3, -3), (-7, -6), (-11, -9)], outline=OUTLINE_G, ow=3.0)
    stroke(cv, [P(96, 0), P(138, 0)], 1.8, OUTLINE_G, 0.9)
    cv.paint(T(circle(112, -8, 2.2)), A4, 0.9)

    # skull mark on the shaft, upright on screen
    sx, sy = P(-26, 0)
    sx, sy = sx + 0, sy + 0
    cranium = smooth_union(circle(sx, sy - 2, 14.5), rbox(sx, sy + 12, 8.5, 6, 3), 6)
    cel(cv, IDENT, cranium, [O0, O1, O2, O3], [(-2, -2), (-4, -4), (-6, -6)], ow=2.8)
    for ex in (-5.6, 5.6):
        cv.paint(circle(sx + ex, sy - 1, 3.9), (0x08, 0x06, 0x08))
    cv.paint(polygon([(sx - 2, sy + 5), (sx + 2, sy + 5), (sx, sy + 1.4)]), (0x08, 0x06, 0x08))
    for tx in (-4, 0, 4):
        stroke(cv, [(sx + tx, sy + 9), (sx + tx, sy + 15)], 1.3, O0, 0.9)

    # poison dripping from the head and the shaft
    for (px_, py_, ln, r) in ((100, 14, 30, 5.2), (122, 8, 18, 4.4), (66, 7, 22, 4.0)):
        bx, by = P(px_, py_)
        d = drop(bx, by + 2, ln, r)
        cel(cv, IDENT, d, [A0, A1, A2, A3], [(-1.4, -1.8), (-2.6, -3.4), (-3.6, -5.0)], outline=OUTLINE_G, ow=2.6)
    sx2, sy2 = P(138, 0)
    cv.paint(circle(sx2 + 4, sy2 + 8, 3.0), A2)
    cv.paint(ring(sx2 + 4, sy2 + 8, 3.2, 4.8), OUTLINE_G, 0.9)
    cv.paint(circle(sx2 + 3, sy2 + 7, 1.2), A4)
    cv.shadow_under(5, 8, 3, 0.30)
    return cv


# ---------------------------------------------------------------- rust-canister: a rusted, dented drum that leaks
def draw_rust_canister():
    cv = Canvas(SIZE, SIZE)
    rng = random.Random(63)
    O, ANG = (88, 150), 8

    def T(f):
        return place(f, O[0], O[1], ANG)

    def P(x, y):
        return rot_pt((x, y), O[0], O[1], ANG)

    # valve on top
    cel(cv, T, rbox(-24, -104, 11, 9, 3), [G0, G1, G2], [(-1.5, -2), (-3, -4)], ow=2.8)
    cel(cv, T, rbox(-24, -112, 22, 4.5, 2), [R0, R1, R2], [(-1.5, -1.5), (-3, -3)], ow=2.6)

    body = rbox(0, 0, 66, 92, 15)
    cel(cv, T, body, [X0, X1, X2], [(-10, -5), (-20, -10)])
    # drum hoops: dark iron rims at the ends and two rolled ridges
    for hy in (-86, 86):
        cel(cv, T, rbox(0, hy, 69, 10, 6), [X0, X1, X2], [(-1.5, -2.5), (-3, -4.5)], ow=3.0)
    for hy in (-52, 56):
        cv.paint(T(inter(rbox(0, hy, 68, 5, 2), body)), X0)
        cv.paint(T(inter(rbox(0, hy - 2, 66, 1.6, 1), body)), R2, 0.85)
    # rust blotches, orange flecks and pits
    for _ in range(14):
        px, py = rng.uniform(-60, 56), rng.uniform(-80, 80)
        rx, ry = rng.uniform(5, 15), rng.uniform(4, 11)
        cv.paint(T(inter(ellipse(px, py, rx, ry), body)), X1 if rng.random() < 0.6 else X0, 0.85)
        cv.paint(T(inter(ellipse(px - 1.5, py - 1.5, rx * 0.55, ry * 0.5), body)), R1, 0.8)
    for _ in range(10):
        cv.paint(T(inter(circle(rng.uniform(-60, 60), rng.uniform(-76, 76), rng.uniform(1.4, 2.8)), body)), X0)
    for sx in (-48, -14, 38):
        stroke(cv, [P(sx, -50), P(sx + rng.uniform(-3, 3), -20 + rng.uniform(0, 40))], 3.4, X0, 0.45, clip=T(body))
    # a big dent: shadowed hollow with a bright lip on its lower right
    dent = ellipse(-30, 38, 27, 19)
    cv.paint(T(inter(dent, body)), X0)
    cv.paint(T(inter(shift(dent, 5, 6), body)), R1)
    cv.paint(T(inter(shift(dent, -3, -4), dent)), (0x2A, 0x14, 0x0A))
    cv.paint(T(inter(ring(-30 + 6, 38 + 5, 22, 26), body)), R2, 0.5)
    stroke(cv, [P(-46, 30), P(-34, 40), P(-18, 36)], 1.8, OUTLINE, 0.8, clip=T(body))
    # biohazard mark, faded, over a dark plate
    cx, cy = 6, -8
    plate = circle(cx, cy, 39)
    cv.paint(T(grow(plate, 2.4)), OUTLINE, 0.0)
    cv.paint(T(plate), (0x24, 0x14, 0x0C), 0.35)
    for k in range(3):
        a = math.radians(k * 120 - 90)
        ux, uy = math.cos(a), math.sin(a)
        c = (cx + ux * 15, cy + uy * 15)
        claw = sub(circle(c[0], c[1], 19), circle(c[0] + ux * 11, c[1] + uy * 11, 17))
        cv.paint(T(grow(claw, 1.8)), OUTLINE)
        cv.paint(T(claw), Y1)
        cv.paint(T(inter(claw, shift(claw, -2, -3))), Y2)
    cv.paint(T(circle(cx, cy, 11)), OUTLINE)
    cv.paint(T(ring(cx, cy, 5, 9)), Y1)
    cv.paint(T(circle(cx, cy, 3.4)), Y2)
    for _ in range(5):                                           # corrosion chewing the paint
        cv.paint(T(inter(ellipse(cx + rng.uniform(-28, 28), cy + rng.uniform(-28, 28), rng.uniform(3, 7), rng.uniform(2, 5)),
                         plate)), X1, 0.8)
    cv.paint(T(inter(box(-70, -92, 70, -88), body)), R2, 0.5)

    # the leak: a hole low on the shoulder, a hissing cloud, slime running down
    hx, hy = P(66, -46)
    cv.paint(T(ellipse(64, -46, 6, 9)), (0x08, 0x10, 0x06))
    cv.paint(T(ellipse(63, -46, 3.4, 5.5)), A1)
    for k, (dx, dy) in enumerate(((30, -12), (36, -26), (26, -36))):
        stroke(cv, [(hx + 4, hy), (hx + dx, hy + dy)], 4.2 - k, A3, 0.75)
    cloud = smooth_union(smooth_union(circle(hx + 32, hy - 20, 17), circle(hx + 54, hy - 42, 20), 14),
                         smooth_union(circle(hx + 42, hy - 58, 13), circle(hx + 22, hy - 4, 10), 10), 12)
    cloud = union(cloud, circle(hx + 70, hy - 70, 7))
    paint_alpha_cel(cv, cloud, [A0, A1, A2, A3], [(-4, -5), (-9, -11), (-14, -17)], [0.78, 0.78, 0.8, 0.82])
    for bx, by, br in ((hx + 48, hy - 46, 4.4), (hx + 30, hy - 18, 3.2), (hx + 58, hy - 34, 3), (hx + 40, hy - 62, 2.4)):
        cv.paint(ring(bx, by, br - 1.3, br), A4, 0.7)
    wisp = smooth_union(circle(hx + 80, hy - 36, 7), circle(hx + 74, hy - 48, 4.5), 6)
    paint_alpha_cel(cv, wisp, [A0, A1, A2], [(-2, -3), (-4, -5)], [0.5, 0.55, 0.6], ow=2.2, oalpha=0.4)
    # slime running down from the hole
    ex, ey = P(66, -36)
    run = smooth_union(capsule(ex - 2, ey, ex - 3, ey + 56, 4.2), circle(ex - 2, ey + 4, 6), 6)
    run = union(run, circle(ex - 3, ey + 62, 5.6))
    cel(cv, IDENT, run, [A0, A1, A2], [(-1.5, -2), (-2.5, -3.5)], outline=OUTLINE_G, ow=2.6)
    cv.paint(ellipse(ex - 5, ey + 20, 1.4, 8), A4, 0.8)
    cv.shadow_under(5, 8, 3, 0.30)
    return cv


ICONS = [("hangwoman", draw_hangwoman), ("knifeman", draw_knifeman), ("gorger", draw_gorger),
         ("dead-star", draw_dead_star), ("plague-arrow", draw_plague_arrow), ("rust-canister", draw_rust_canister)]
