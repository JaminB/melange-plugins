#!/usr/bin/env python3
"""Kindjal air-strike and livestock weapon icons, drawn with the make_icons.py toolkit.

Six more 256x256 drawings in the same house style (thin near-black outline, three-tone cel shading from the upper
left, tilted pose filling the frame, faint soft shadow, dark gritty palette): harpoon, carpet-bombing, carrion-drop,
earthquake-ass, rabid-flock, plague-ram. Every function returns a Canvas exactly like draw_crucible does; ICONS lists
(slug, draw) pairs for build() to pick up. Geometry and random seeds are fixed, so the output is deterministic.
"""
import math
import random

from make_icons import *  # noqa: F401,F403  (SDF primitives, Canvas, cel, stroke, crack, palettes, SIZE)

# dark steel
K0, K1, K2, K3 = (0x14, 0x17, 0x1B), (0x2A, 0x31, 0x38), (0x4A, 0x56, 0x60), (0x86, 0x98, 0xA4)
# hemp rope
H0, H1, H2 = (0x3A, 0x2C, 0x1C), (0x70, 0x58, 0x38), (0xA6, 0x8C, 0x5C)
# bomber / bombs, a blue-black
P0, P1, P2, P3 = (0x08, 0x08, 0x0C), (0x17, 0x18, 0x21), (0x2A, 0x2C, 0x3A), (0x52, 0x54, 0x68)
# bone
N0, N1, N2, N3 = (0x3E, 0x37, 0x2B), (0x77, 0x6D, 0x59), (0xAE, 0xA2, 0x84), (0xDC, 0xD2, 0xB2)
# rotten hide
D0, D1, D2 = (0x2E, 0x10, 0x0E), (0x56, 0x1E, 0x18), (0x7E, 0x32, 0x24)
# stone
T0, T1, T2, T3 = (0x24, 0x27, 0x29), (0x47, 0x4B, 0x4D), (0x78, 0x7C, 0x7B), (0xA6, 0xAA, 0xA3)
# dust
U1, U2 = (0x6E, 0x66, 0x5A), (0xA0, 0x98, 0x88)
# matted wool
W0, W1, W2, W3 = (0x14, 0x11, 0x13), (0x2E, 0x28, 0x2A), (0x4E, 0x45, 0x44), (0x72, 0x66, 0x60)
# plague sheep: pale dirty wool, cape red, plague green
Y0, Y1, Y2, Y3 = (0x3A, 0x38, 0x30), (0x6A, 0x66, 0x56), (0x9A, 0x96, 0x80), (0xC4, 0xC0, 0xA6)
V0, V1, V2 = (0x44, 0x0C, 0x0E), (0x80, 0x18, 0x18), (0xB8, 0x2C, 0x26)
F0, F1, F2, F3 = (0x1E, 0x32, 0x0C), (0x3E, 0x62, 0x14), (0x6E, 0x98, 0x24), (0xA4, 0xC4, 0x4A)
RED0, RED1, RED2 = (0x8C, 0x10, 0x10), (0xE8, 0x24, 0x1C), (0xFF, 0x9A, 0x80)
IDENT = lambda f: f  # noqa: E731


def bezier(p0, p1, p2, p3, n=28):
    pts = []
    for i in range(n + 1):
        t = i / n
        u = 1 - t
        pts.append((u ** 3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t ** 3 * p3[0],
                    u ** 3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t ** 3 * p3[1]))
    return pts


def chain(pts, radii):
    """Union of capsules along a polyline with a radius per point (a tapered limb, horn or bone)."""
    segs = [capsule(a[0], a[1], b[0], b[1], (ra + rb) / 2) for a, b, ra, rb in zip(pts, pts[1:], radii, radii[1:])]
    return union(*segs)


def blob(cv, circles, cols, offs, alpha=1.0, outline=None, ow=2.6):
    """A lumpy cloud: union of (x, y, r) circles, lens-shaded in screen space."""
    f = union(*[circle(*c) for c in circles])
    if outline:
        cv.paint(grow(f, ow), outline, alpha)
    cv.paint(f, cols[0], alpha)
    for col, (dx, dy) in zip(cols[1:], offs):
        cv.paint(inter(f, shift(f, dx, dy)), col, alpha)
    return f


# ---------------------------------------------------------------- icon 1: Harpoon
def draw_harpoon():
    cv = Canvas(SIZE, SIZE)
    O, ANG = (128, 102), -34

    def T(f):
        return place(f, O[0], O[1], ANG)

    def P(x, y):
        return rot_pt((x, y), O[0], O[1], ANG)

    rng = random.Random(41)
    # trailing rope first, so everything else lies over it: from the tail eyelet in a loose S down to the corner
    tail = P(-108, 0)
    rope = bezier(tail, (tail[0] - 46, tail[1] + 6), (tail[0] + 4, tail[1] + 70), (tail[0] + 76, tail[1] + 60), 30)
    rope += bezier(rope[-1], (rope[-1][0] + 40, rope[-1][1] - 8), (170, 224), (206, 246), 20)[1:]
    stroke(cv, rope, 13, OUTLINE)
    stroke(cv, rope, 9, H1)
    stroke(cv, [(x - 1.2, y - 1.8) for x, y in rope], 3.2, H2, 0.9)
    for i in range(1, len(rope) - 1, 2):                      # twisted strands: short dark ticks across the lay
        (ax, ay), (bx, by) = rope[i - 1], rope[i + 1]
        n = math.hypot(bx - ax, by - ay) or 1
        nx, ny = -(by - ay) / n, (bx - ax) / n
        stroke(cv, [(rope[i][0] - nx * 4.2 + (bx - ax) * 0.1, rope[i][1] - ny * 4.2 + (by - ay) * 0.1),
                    (rope[i][0] + nx * 4.2 - (bx - ax) * 0.1, rope[i][1] + ny * 4.2 - (by - ay) * 0.1)], 1.8, H0, 0.9)
    frayed = rope[-1]
    for k, (fx, fy) in enumerate(((10, -7), (14, 2), (8, 9))):
        stroke(cv, [frayed, (frayed[0] + fx, frayed[1] + fy)], 3.0, H1)

    shaft = rbox(4, 0, 96, 7, 3)
    lance = polygon([(142, 0), (102, -12), (96, 12)], 2)
    barbs = [polygon([(124, -5), (78, -40), (98, -5)], 1.5), polygon([(124, 5), (78, 40), (98, 5)], 1.5)]
    fins = [polygon([(-54, -6), (-82, -36), (-98, -36), (-94, -6)], 2), polygon([(-54, 6), (-82, 36), (-98, 36), (-94, 6)], 2)]

    for fn in fins:
        cel(cv, T, fn, [K0, K1, K2], [(-2, -3), (-4, -6)], ow=3.0)
    cel(cv, T, ring(-106, 0, 5, 12), [K0, K1, K2], [(-1, -1.5), (-2, -3)], ow=2.6)   # tail eyelet the rope ties to
    cel(cv, T, shaft, [K0, K1, K2, K3], [(0, -3), (0, -5), (0, -6)], ow=3.2)
    for bx, by in ((-8, 2), (36, -2), (-46, 1), (62, 2)):                         # rust and pits on the iron
        cv.paint(T(inter(ellipse(bx, by, rng.uniform(5, 10), 3.2), shaft)), R1)
        cv.paint(T(inter(ellipse(bx - 1, by - 1, 3.5, 1.6), shaft)), R2)
    for bx in (-30, 10, 56):                                                      # lashing rings
        cv.paint(T(inter(box(bx - 3, -12, bx + 3, 12), grow(shaft, 3))), OUTLINE)
        cv.paint(T(inter(box(bx - 2, -9, bx + 2, 9), grow(shaft, 2))), H1)
        cv.paint(T(inter(box(bx - 2, -9, bx - 0.5, 9), grow(shaft, 2))), H2)
    cel(cv, T, barbs[0], [K0, K1, K2], [(-1.5, -2), (-3, -4)], ow=3.0)
    cel(cv, T, barbs[1], [K0, K1, K2], [(-1.5, -2), (-3, -4)], ow=3.0)
    cel(cv, T, rbox(92, 0, 6, 15, 3), [K0, K1, K2, K3], [(0, -3), (0, -6), (0, -8)], ow=3.0)
    cel(cv, T, lance, [K0, K2, K3], [(-2, -3), (-5, -5)], ow=3.2)
    cv.paint(T(inter(box(96, -2, 140, 0.4), lance)), (0xD8, 0xE6, 0xEE), 0.9)     # honed edge glint
    cv.paint(T(circle(-12, -3, 1.6)), K3, 0.9)
    cv.shadow_under(5, 8, 3, 0.30)
    return cv


# ---------------------------------------------------------------- icon 2: Carpet Bombing
def draw_carpet_bombing():
    cv = Canvas(SIZE, SIZE)
    O, ANG = (122, 62), -10

    def T(f):
        return place(f, O[0], O[1], ANG)

    def P(x, y):
        return rot_pt((x, y), O[0], O[1], ANG)

    cols, offs = [P0, P1, P2, P3], [(-3, -3), (-7, -6), (-12, -9)]
    for sg in (-1, 1):
        wing = polygon([(24, sg * 8), (-4, sg * 54), (-34, sg * 54), (-30, sg * 8)], 3)
        cel(cv, T, wing, [P0, P1, P2], [(-2, -2), (-5, -4)], ow=3.0)
        tailpl = polygon([(-62, sg * 6), (-76, sg * 26), (-92, sg * 26), (-88, sg * 6)], 2)
        cel(cv, T, tailpl, [P0, P1, P2], [(-1.5, -2), (-3, -3)], ow=2.8)
        cel(cv, T, rbox(10, sg * 30, 22, 7, 4), [P0, P1, P2, P3], [(-1, -2), (-3, -3), (-5, -4)], ow=2.8)   # engines
    fin = polygon([(-60, 0), (-86, -2), (-96, 0), (-86, 2)], 2)
    fus = smooth_union(ellipse(8, 0, 84, 14), ellipse(-52, 0, 40, 9), 14)
    cel(cv, T, fus, cols, offs, ow=3.4)
    cv.paint(T(inter(ellipse(46, -3, 18, 6.5), fus)), S2, 0.9)                          # canopy glass
    cv.paint(T(inter(ellipse(42, -5, 8, 2.5), fus)), S3, 0.8)
    stroke(cv, [P(-18, -12), P(-18, 12)], 1.6, P0, 0.8)                                   # panel lines
    stroke(cv, [P(-40, -9), P(-40, 9)], 1.6, P0, 0.8)
    del fin
    for sg in (-1, 1):                                                                    # propeller blur
        cv.paint(T(ellipse(36, sg * 30, 3, 16)), P3, 0.35)
    # red navigation lights on the wingtips
    for q in ((-20, -53), (-20, 53)):
        c = P(*q)
        cv.paint(circle(c[0], c[1], 9), RED0, 0.35)
        cv.paint(circle(c[0], c[1], 5.2), RED1)
        cv.paint(circle(c[0] - 1, c[1] - 1, 2.2), RED2)

    # five bombs, nose down, falling away along the line of flight: the oldest has dropped furthest
    for k in range(5):
        bx, by, ang = 40 + k * 44, 206 - k * 10, 80 - k * 3

        def B(f, bx=bx, by=by, ang=ang):
            return place(f, bx, by, ang)
        body = smooth_union(ellipse(8, 0, 28, 12.5), rbox(-12, 0, 20, 12, 4), 8)
        for sg in (-1, 1):
            cel(cv, B, polygon([(-24, sg * 6), (-42, sg * 22), (-50, sg * 22), (-46, sg * 4)], 1.5),
                [P0, P1, P2], [(-1, -1.5), (-2, -3)], ow=2.6)
        cel(cv, B, rbox(-40, 0, 11, 7, 3), [P0, P1, P2], [(-1, -2), (-2, -3)], ow=2.6)
        cel(cv, B, body, [P0, P1, P2, P3], [(0, -3), (0, -6), (0, -8)], ow=3.0)
        cv.paint(B(inter(box(-4, -14, 2, 14), body)), R1)                                 # rusty band
        cv.paint(B(inter(box(-4, -14, -2.4, 14), body)), R2)
        cv.paint(B(inter(box(18, -14, 21, 14), body)), P0)
        cv.paint(B(inter(ellipse(14, -8, 8, 1.6), body)), (0x9A, 0x9C, 0xB4), 0.8)
        c = rot_pt((-48, 0), bx, by, ang)                                                  # no light on the bombs
        del c
    cv.shadow_under(5, 8, 3, 0.30)
    return cv


# ---------------------------------------------------------------- icon 3: Carrion Drop
def draw_carrion_drop():
    cv = Canvas(SIZE, SIZE)
    O, ANG = (124, 176), 12

    def T(f):
        return place(f, O[0], O[1], ANG)

    def P(x, y):
        return rot_pt((x, y), O[0], O[1], ANG)

    bone = [N0, N1, N2, N3]
    # rushing air behind the falling carcass
    for x0, y0, ln in ((38, 20, 40), (222, 14, 52), (70, 6, 30), (196, 60, 40)):
        stroke(cv, [(x0, y0), (x0 - 4, y0 + ln)], 3.0, (0x70, 0x70, 0x78), 0.55)
    # rotten hide still clinging to the ribcage
    hide = polygon([(-46, -50), (-52, -98), (-40, -146), (-10, -158), (22, -150), (46, -148), (52, -98), (44, -50),
                    (32, -62), (20, -48), (8, -64), (-8, -50), (-22, -62), (-34, -46)], 2)
    cel(cv, T, hide, [D0, D1, D2], [(-4, -4), (-8, -7)], ow=3.2)
    # spine and ribs
    cel(cv, T, chain([(0, -50), (0, -158)], [8, 8]), [N0, N1, N2], [(-1.5, -2), (-3, -3)], ow=2.8)
    for i in range(6):
        cv.paint(T(circle(0, -62 - i * 17, 3.0)), N0, 0.8)
    for i in range(5):
        y0 = -70 - i * 17
        for sg in (-1, 1):
            rib = chain([(sg * 4, y0 - 6), (sg * 26, y0 - 10), (sg * 43, y0 + 2), (sg * 49, y0 + 22)], [5.5, 5.5, 5, 3.5])
            cel(cv, T, rib, [N0, N1, N2], [(-1, -1.5), (-2, -3)], ow=2.6)
    # horns, then the skull over their roots
    for sg in (-1, 1):
        horn = chain([(sg * 30, -24), (sg * 56, -32), (sg * 76, -54), (sg * 84, -86)], [13, 11, 8, 3.5])
        cel(cv, T, horn, [N0, N1, N2, N3], [(-2, -2), (-3, -4), (-4, -6)], ow=3.2)
        cv.paint(T(inter(horn, chain([(sg * 64, -40), (sg * 82, -74)], [3, 2]))), N0, 0.6)
    skull = smooth_union(ellipse(0, -6, 38, 41), rbox(0, 40, 20, 34, 12), 14)
    cel(cv, T, skull, bone, [(-4, -4), (-9, -9), (-15, -14)], ow=3.4)
    cv.paint(T(inter(ellipse(-14, -26, 12, 5), skull)), N3, 0.8)
    for sg in (-1, 1):                                                                  # eye sockets and nostrils
        cv.paint(T(ellipse(sg * 17, -4, 9, 12)), OUTLINE)
        cv.paint(T(ellipse(sg * 17 + 1, -2, 6, 9)), (0x08, 0x06, 0x06))
        cv.paint(T(ellipse(sg * 9, 62, 4.2, 6)), OUTLINE)
        cv.paint(T(inter(ellipse(sg * 24, 22, 3, 14), skull)), N1, 0.9)               # cheek shadow
    stroke(cv, [P(2, -42), P(-4, -30), P(4, -20), P(0, -10)], 2.4, OUTLINE, 0.95)    # crack down the brow
    cv.paint(T(inter(ellipse(20, -30, 11, 6), skull)), D1)                              # strip of hide left on the brow
    cv.paint(T(inter(ellipse(19, -32, 6, 3), skull)), D2)
    cv.paint(T(box(-19, 62, 19, 64)), OUTLINE, 0.5)
    # a few flies
    for fx, fy in ((44, 94), (206, 118), (28, 148), (214, 206), (82, 40)):
        cv.paint(ellipse(fx - 5, fy - 5, 7, 4), (0xC8, 0xD0, 0xD8), 0.6)
        cv.paint(ellipse(fx + 5, fy - 6, 7, 4), (0xC8, 0xD0, 0xD8), 0.6)
        cv.paint(ellipse(fx, fy, 7, 5.2), OUTLINE)
        cv.paint(ellipse(fx, fy, 5, 3.4), (0x1C, 0x1A, 0x1A))
        cv.paint(circle(fx - 4, fy - 1, 1.6), RED1)
    cv.shadow_under(5, 8, 3, 0.30)
    return cv


# ---------------------------------------------------------------- icon 4: Earthquake Ass
def draw_earthquake_ass():
    cv = Canvas(SIZE, SIZE)
    rng = random.Random(53)
    stone = [T0, T1, T2, T3]
    ST = [(-5, -5), (-11, -11), (-18, -16)]

    # ground fissures, drawn first so the plinth sits over them
    for pts in ([(40, 244), (22, 236), (8, 240), (-4, 232)], [(212, 244), (228, 237), (242, 242), (258, 233)],
                [(96, 246), (88, 254)], [(160, 247), (172, 255)]):
        stroke(cv, pts, 6.5, OUTLINE)
        stroke(cv, pts, 3.0, (0x05, 0x04, 0x04))
    plinth = rbox(122, 236, 106, 11, 4)
    cel(cv, IDENT, plinth, [T0, T1, T2], [(-3, -3), (-7, -5)], ow=3.2)
    # far legs
    for x0, x1 in ((140, 146), (74, 68)):
        cel(cv, IDENT, chain([(x0, 120), (x0 + 1, 170), (x1, 222)], [8, 6, 6]), [T0, T1, T2], [(-2, -2), (-4, -3)], ow=3.0)
        cel(cv, IDENT, rbox(x1, 224, 10, 6, 2), [T0, T0, T1], [(-1, -2), (-2, -3)], ow=2.6)
    # tail
    cel(cv, IDENT, chain([(44, 90), (30, 118), (26, 142)], [5, 4.5, 4]), [T0, T1, T2], [(-1.5, -1.5), (-2.5, -3)], ow=2.8)
    cel(cv, IDENT, ellipse(26, 150, 8, 12), [T0, T1, T2], [(-2, -2), (-4, -4)], ow=2.8)
    # long ears, tall and separate
    for (ax, ay, bx, by) in ((168, 112, 182, 52), (180, 120, 222, 82)):
        ear = chain([(ax, ay), ((ax + bx) / 2 - 3, (ay + by) / 2), (bx, by)], [8, 8.5, 3.5])
        cel(cv, IDENT, ear, [T0, T1, T2, T3], [(-2, -2), (-3, -4), (-4, -5)], ow=3.0)
        cv.paint(chain([(ax + 3, ay - 6), (bx + 1, by + 8)], [2.2, 1.6]), T0, 0.9)
    # barrel body, neck, bowed head and muzzle as one block of stone
    body = smooth_union(ellipse(102, 110, 62, 40), chain([(142, 88), (176, 126)], [18, 16]), 20)
    body = smooth_union(body, chain([(176, 126), (198, 186)], [16, 13]), 10)
    body = smooth_union(body, ellipse(203, 196, 16, 14), 6)
    body = smooth_union(body, ellipse(52, 98, 18, 26), 12)
    cel(cv, IDENT, body, stone, ST, ow=3.6)
    # near legs
    for x0, x1 in ((122, 128), (92, 86)):
        leg = chain([(x0, 124), (x0 + 1, 172), (x1, 222)], [9, 7, 7])
        cel(cv, IDENT, leg, stone[:3], [(-3, -2), (-6, -4)], ow=3.2)
        cel(cv, IDENT, rbox(x1, 224, 11, 6.5, 2), [T0, T1, T2], [(-1, -2), (-2, -3)], ow=2.6)
    # stiff mane along the crest of the neck
    for i in range(4):
        t = i / 3
        bx, by = 140 + 28 * t, 80 + 40 * t
        cel(cv, IDENT, polygon([(bx - 3, by + 2), (bx - 9, by - 10), (bx + 3, by - 2)], 1), [T0, T1, T2], [(-1, -1), (-2, -2)], ow=2.2)
    # stone speckle
    for _ in range(40):
        sx, sy = rng.uniform(40, 215), rng.uniform(70, 220)
        r = rng.uniform(1.0, 2.2)
        dark = rng.random() < 0.6
        cv.paint(inter(circle(sx, sy, r), body), T0 if dark else T3, 0.55)
    # chipped back and face details
    cv.paint(inter(polygon([(96, 70), (112, 66), (118, 80), (104, 86)], 1), body), T0)
    cv.paint(inter(polygon([(96, 70), (104, 68), (106, 74), (98, 78)], 1), body), T2, 0.8)
    cv.paint(ellipse(187, 150, 4.6, 2.4), OUTLINE)                                    # sunk, blind eye
    cv.paint(ellipse(210, 202, 2.6, 3.8), OUTLINE)                                    # nostril
    # cracks: two long fissures with a jagged edge, light catching the lip
    cracks = []
    crack(rng, 112, 66, math.radians(95), 120, 2, cracks, 0.45)
    crack(rng, 164, 100, math.radians(170), 100, 1, cracks, 0.5)
    crack(rng, 62, 96, math.radians(80), 90, 1, cracks, 0.5)
    for pts, depth in cracks:
        stroke(cv, [(x + 1.3, y + 1.3) for x, y in pts], 4.8 - depth, T3, 0.6, clip=body)
    for pts, depth in cracks:
        stroke(cv, pts, 5.0 - depth, OUTLINE, 1.0, clip=body)
    for pts, depth in cracks:
        stroke(cv, pts, 2.2 - 0.4 * depth, (0x04, 0x03, 0x03), 1.0, clip=body)
    # falling chips and dust
    for cx, cy, a in ((70, 40, 20), (160, 36, 70), (214, 128, 40), (30, 190, 80)):
        c, s = math.cos(math.radians(a)), math.sin(math.radians(a))
        pts = [(cx + c * x - s * y, cy + s * x + c * y) for x, y in ((-6, -4), (7, -5), (4, 6), (-5, 4))]
        cel(cv, IDENT, polygon(pts, 0.5), [T0, T1, T2], [(-1, -1), (-2, -2)], ow=2.2)
    blob(cv, [(30, 224, 13), (46, 214, 11), (18, 214, 9), (62, 226, 10)], [U1, U2], [(-3, -4)], 0.82)
    blob(cv, [(216, 226, 13), (232, 216, 10), (200, 218, 10), (240, 230, 8)], [U1, U2], [(-3, -4)], 0.82)
    blob(cv, [(24, 170, 9), (36, 160, 7)], [U1, U2], [(-2, -3)], 0.6)
    cv.shadow_under(5, 6, 3, 0.28)
    return cv


# ---------------------------------------------------------------- icon 5: Rabid Flock
def draw_rabid_flock():
    cv = Canvas(SIZE, SIZE)
    rng = random.Random(67)
    wool = [W0, W1, W2, W3]

    # legs: front pair braced and bent, back pair driving
    for x0, y0, x1, y1, d in ((92, 146, 76, 226, 0), (124, 158, 130, 228, 1), (176, 150, 204, 224, 0), (202, 132, 232, 200, 1)):
        cel(cv, IDENT, chain([(x0, y0), ((x0 + x1) / 2 - 6, (y0 + y1) / 2), (x1, y1)], [12, 9.5, 7.5]),
            [(0x0C, 0x0A, 0x0A), (0x22, 0x1C, 0x1C), (0x3E, 0x32, 0x30)], [(-1.5, -1.5), (-3, -3)], ow=2.8)
        cel(cv, IDENT, rbox(x1 - 2, y1 + 2, 8, 5, 2), [W0, W0, W1], [(-1, -1), (-2, -2)], ow=2.4)
    # the hunched, matted fleece: a lump of overlapping tufts with ragged spikes along the top
    tufts = [(150, 98, 40), (104, 100, 34), (186, 110, 36), (126, 136, 34), (168, 142, 32), (78, 120, 28),
             (206, 140, 26), (146, 66, 30), (108, 68, 26), (182, 76, 28), (212, 100, 24), (94, 138, 26)]
    spikes = [polygon([(x - 8, y), (x + 1, y - 20), (x + 10, y)], 2) for x, y in ((120, 50), (156, 40), (190, 56), (86, 80))]
    fleece = union(*[circle(*t) for t in tufts], *spikes)
    cel(cv, IDENT, fleece, wool, [(-6, -7), (-13, -15), (-20, -24)], ow=3.6)
    # matted clumps: dark swirls, a few pale burrs, dried mud
    for _ in range(16):
        cx, cy = rng.uniform(70, 220), rng.uniform(52, 150)
        a = rng.uniform(0, 6.28)
        r = rng.uniform(8, 15)
        pts = [(cx + math.cos(a + t * 0.7) * r * (1 - t * 0.12), cy + math.sin(a + t * 0.7) * r * (1 - t * 0.12)) for t in range(5)]
        stroke(cv, pts, 2.6, W0, 0.85, clip=fleece)
    for _ in range(14):
        cv.paint(inter(circle(rng.uniform(80, 215), rng.uniform(56, 140), rng.uniform(1.6, 3.2)), fleece), W3, 0.7)
    cv.paint(inter(ellipse(168, 128, 18, 9), fleece), R0, 0.8)
    cv.paint(inter(ellipse(124, 102, 10, 6), fleece), R0, 0.7)
    # head, lowered and thrust forward, nose pointing left and down
    def Hd(f):
        return place(f, 66, 146, -22)
    for ex in ((-14, -34), (6, -36)):                                                 # ears pinned back
        cel(cv, Hd, polygon([(ex[0], ex[1]), (ex[0] + 36, ex[1] - 12), (ex[0] + 38, ex[1] + 4), (ex[0] + 6, ex[1] + 14)], 3),
            [(0x2A, 0x18, 0x18), (0x4C, 0x2A, 0x28), (0x6C, 0x40, 0x3C)], [(-1.5, -1.5), (-3, -3)], ow=2.8)
    skull = smooth_union(ellipse(0, 0, 40, 32), ellipse(-34, 8, 28, 19), 14)
    cel(cv, Hd, skull, [(0x24, 0x1C, 0x1C), (0x44, 0x38, 0x36), (0x68, 0x58, 0x52), (0x8A, 0x78, 0x6E)],
        [(-3, -4), (-7, -8), (-12, -13)], ow=3.4)
    # snarl: dark open mouth between the upper muzzle and a dropped jaw, fangs top and bottom
    jaw = chain([(-56, 30), (-30, 40), (-4, 34)], [8, 9, 8])
    cel(cv, Hd, jaw, [(0x20, 0x18, 0x18), (0x3A, 0x2E, 0x2C), (0x58, 0x46, 0x42)], [(-1, -2), (-2, -3)], ow=2.6)
    mouth = polygon([(-62, 20), (-14, 18), (-8, 30), (-52, 32)], 1.5)
    cv.paint(Hd(mouth), OUTLINE)
    cv.paint(Hd(grow(mouth, -2)), (0x70, 0x0C, 0x14))
    cv.paint(Hd(inter(ellipse(-34, 28, 14, 5), mouth)), (0xB0, 0x2C, 0x30))        # tongue
    for tx in (-54, -44, -34, -24):
        cv.paint(Hd(polygon([(tx - 3, 19), (tx + 3, 19), (tx, 29)], 0.6)), (0xEC, 0xE4, 0xCC))
    for tx in (-48, -36, -24):
        cv.paint(Hd(polygon([(tx - 3, 33), (tx + 3, 33), (tx, 25)], 0.6)), (0xE0, 0xD8, 0xC0))
    # red eye with a hard brow
    ex, ey = rot_pt((-12, -10), 66, 146, -22)
    cv.paint(circle(ex, ey, 11), RED0, 0.5)
    cv.paint(circle(ex, ey, 7), OUTLINE)
    cv.paint(circle(ex, ey, 5.2), RED1)
    cv.paint(circle(ex - 1, ey - 1.4, 2.2), RED2)
    cv.paint(Hd(capsule(-28, -26, 6, -12, 3.2)), OUTLINE)
    # foam: froth around the lips and a string of drool
    for fx, fy, fr in ((-62, 30, 6), (-52, 38, 6.4), (-40, 46, 5), (-28, 44, 4), (-66, 20, 4.4)):
        cx, cy = rot_pt((fx, fy), 66, 146, -22)
        cv.paint(circle(cx, cy, fr + 1.6), OUTLINE, 0.9)
        cv.paint(circle(cx, cy, fr), (0xD8, 0xDA, 0xD4))
        cv.paint(circle(cx - fr * 0.3, cy - fr * 0.3, fr * 0.4), (0xFF, 0xFF, 0xFF), 0.9)
    dx, dy = rot_pt((-48, 46), 66, 146, -22)
    stroke(cv, [(dx, dy), (dx - 2, dy + 14)], 3.2, OUTLINE)
    stroke(cv, [(dx, dy), (dx - 2, dy + 14)], 1.6, (0xD8, 0xDA, 0xD4))
    cv.paint(circle(dx - 2, dy + 18, 4.6), OUTLINE)
    cv.paint(circle(dx - 2, dy + 18, 3.2), (0xD8, 0xDA, 0xD4))
    cv.shadow_under(5, 8, 3, 0.30)
    return cv


# ---------------------------------------------------------------- icon 6: Plague Ram
def draw_plague_ram():
    cv = Canvas(SIZE, SIZE)
    O, ANG = (128, 98), -6

    def T(f):
        return place(f, O[0], O[1], ANG)

    def P(x, y):
        return rot_pt((x, y), O[0], O[1], ANG)

    # tattered cape, flaring out behind the shoulders, jagged hem
    cape = polygon([(-40, 40), (-112, 74), (-100, 96), (-116, 112), (-92, 126), (-98, 146), (-62, 134), (-48, 150),
                    (-20, 136), (0, 152), (22, 136), (48, 150), (62, 134), (98, 146), (92, 126), (116, 112), (100, 96),
                    (112, 74), (40, 40)], 3)
    cel(cv, T, cape, [V0, V1, V2], [(-4, -5), (-10, -11)], ow=3.4)
    for fx, fy, ln in ((-60, 90, 26), (-20, 100, 30), (24, 96, 24), (66, 92, 26)):          # folds
        stroke(cv, [P(fx, fy), P(fx + 4, fy + ln)], 2.6, V0, 0.9, clip=T(cape))
    cv.paint(T(inter(polygon([(-82, 124), (-70, 118), (-76, 132)], 1), cape)), (0, 0, 0), 0.0)
    # woolly collar
    collar = union(*[circle(x, y, r) for x, y, r in ((-44, 54, 24), (-18, 62, 26), (12, 62, 26), (40, 54, 24), (0, 44, 28))])
    cel(cv, T, collar, [Y0, Y1, Y2, Y3], [(-4, -5), (-9, -10), (-14, -15)], ow=3.4)
    for sg in (-1, 1):
        stroke(cv, [P(sg * 30, 48), P(sg * 22, 70)], 2.4, Y0, 0.8)
    # clasp holding the cape
    cel(cv, T, circle(0, 82, 8), [K0, K2, K3], [(-1.5, -1.5), (-3, -3)], ow=2.6)
    # horns: thick tapering spirals curling out from the temples, over, down and back in under the cheek
    for sg in (-1, 1):
        pts, rad = [], []
        for k in range(21):
            t = k / 20
            a = math.radians(-155 + 320 * t)
            r = 40 - 20 * t
            pts.append((sg * (62 + math.cos(a) * r), 6 + math.sin(a) * r))
            rad.append(15 - 11 * t)
        horn = chain(pts, rad)
        cel(cv, T, horn, [N0, N1, N2, N3], [(-2, -2), (-4, -4), (-6, -6)], ow=3.2)
        for k in (5, 8, 11, 14):
            q = pts[k]
            stroke(cv, [P(q[0] - sg * 1, q[1] - rad[k] * 0.9), P(q[0] + sg * 1, q[1] + rad[k] * 0.9)], 1.6, N0, 0.0)
        for k in (4, 7, 10, 13):
            (x0, y0), (x1, y1) = pts[k], pts[k + 1]
            n = math.hypot(x1 - x0, y1 - y0)
            nx, ny = -(y1 - y0) / n, (x1 - x0) / n
            stroke(cv, [P(x0 - nx * rad[k] * 0.8, y0 - ny * rad[k] * 0.8), P(x0 + nx * rad[k] * 0.8, y0 + ny * rad[k] * 0.8)],
                   1.8, N0, 0.9, clip=T(horn))
    # ears
    for sg in (-1, 1):
        cel(cv, T, polygon([(sg * 30, 6), (sg * 58, 22), (sg * 52, 36), (sg * 28, 24)], 3),
            [(0x30, 0x2C, 0x26), Y1, Y2], [(-1.5, -1.5), (-3, -3)], ow=2.8)
    # the face: a long pale ram head
    head = smooth_union(ellipse(0, -2, 36, 46), ellipse(0, 28, 22, 34), 18)
    cel(cv, T, head, [Y0, Y1, Y2, Y3], [(-4, -4), (-9, -9), (-14, -14)], ow=3.4)
    cv.paint(T(inter(ellipse(0, -34, 14, 7), head)), Y3, 0.7)
    # gas mask: rubber face piece with straps, two round lenses, a filter canister
    mask = smooth_union(ellipse(0, 14, 30, 30), ellipse(0, 36, 22, 26), 12)
    for sg in (-1, 1):
        stroke(cv, [P(sg * 28, 8), P(sg * 38, 4)], 6.5, OUTLINE)
        stroke(cv, [P(sg * 28, 8), P(sg * 38, 4)], 3.4, (0x1C, 0x1C, 0x20))
    cel(cv, T, mask, [(0x0C, 0x0E, 0x10), (0x1E, 0x24, 0x22), (0x34, 0x3C, 0x38)], [(-3, -3), (-7, -7)], ow=3.2)
    for sg in (-1, 1):
        lx, ly = sg * 15, 2
        cv.paint(T(circle(lx, ly, 15.5)), OUTLINE)
        cv.paint(T(circle(lx, ly, 13)), K1)
        cv.paint(T(circle(lx, ly, 10)), F1)
        cv.paint(T(circle(lx - 1.5, ly - 1.5, 7)), F2)
        cv.paint(T(circle(lx - 3, ly - 3, 3.4)), F3)
        cv.paint(T(ellipse(lx + 3, ly + 4, 3, 1.4)), F0, 0.7)
    cv.paint(T(box(-4, 10, 4, 18)), OUTLINE)                                         # bridge
    can = circle(0, 46, 18)
    cel(cv, T, can, [K0, K1, K2, K3], [(-3, -3), (-6, -6), (-9, -9)], ow=3.0)
    cv.paint(T(ring(0, 46, 8, 11)), K0)
    cv.paint(T(circle(0, 46, 6.5)), F0)
    for k in range(5):
        a = k / 5 * 2 * math.pi
        cv.paint(T(circle(math.cos(a) * 3.0, 46 + math.sin(a) * 3.0, 1.3)), F2)
    # sickly fumes curling off the cape, the horns and the mask
    puffs = [((30, 150), [(30, 150, 10), (42, 140, 9), (22, 138, 8)]),
             ((226, 134), [(226, 134, 11), (212, 124, 9), (234, 120, 8)]),
             ((24, 60), [(24, 60, 9), (14, 46, 8), (30, 42, 6)]),
             ((228, 52), [(228, 52, 9), (240, 38, 7), (222, 36, 6)]),
             ((126, 18), [(120, 20, 8), (134, 14, 7), (150, 22, 6)]),
             ((188, 214), [(188, 214, 12), (172, 222, 9), (206, 220, 9), (194, 200, 8)]),
             ((60, 220), [(60, 222, 12), (78, 230, 9), (44, 232, 8), (68, 208, 7)])]
    for _, circs in puffs:
        blob(cv, circs, [F1, F2, F3], [(-2, -3), (-5, -6)], 0.78, outline=OUTLINE_G, ow=2.2)
    cv.shadow_under(5, 8, 3, 0.30)
    return cv


ICONS = [("harpoon", draw_harpoon), ("carpet-bombing", draw_carpet_bombing), ("carrion-drop", draw_carrion_drop),
         ("earthquake-ass", draw_earthquake_ass), ("rabid-flock", draw_rabid_flock), ("plague-ram", draw_plague_ram)]
