#!/usr/bin/env python3
"""Kindjal air-strike and livestock weapon icons, drawn with the make_icons.py toolkit.

Six more 256x256 drawings in the same house style (thin near-black outline, three-tone cel shading from the upper
left, tilted pose filling the frame, faint soft shadow, dark gritty palette): harpoon, carpet-bombing, carrion-drop,
earthquake-ass, buddy-bomb, plague-ram. Every function returns a Canvas exactly like draw_crucible does; ICONS lists
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
# buddy bomb: black curls with cool grey highlights, the darker ears, a red harness, dynamite red
DG0, DG1, DG2, DG3 = (0x12, 0x12, 0x15), (0x26, 0x26, 0x2B), (0x3C, 0x3C, 0x43), (0x60, 0x60, 0x6A)
EA0, EA1, EA2 = (0x0E, 0x0E, 0x10), (0x1C, 0x1C, 0x21), (0x30, 0x30, 0x37)
HR0, HR1 = (0x6A, 0x0E, 0x10), (0xA8, 0x1C, 0x1E)
DY0, DY1, DY2, DY3 = (0x6A, 0x0E, 0x0E), (0xB4, 0x20, 0x1A), (0xE4, 0x46, 0x34), (0xFF, 0x86, 0x6C)
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
    """Concrete Donkey: a huge stone donkey head and neck in three-quarter profile, two tall splayed ears, fissures, dust."""
    cv = Canvas(SIZE, SIZE)
    rng = random.Random(53)
    # grey stone lit from the upper left, shadow side a cool blue
    Q0, Q1, Q2, Q3 = (0x1A, 0x22, 0x34), (0x3A, 0x47, 0x5E), (0x7C, 0x86, 0x90), (0xB8, 0xBC, 0xBC)
    stone = [Q0, Q1, Q2, Q3]
    ST = [(-8, -7), (-17, -15), (-30, -26)]
    CR = (0x04, 0x05, 0x08)

    # ears first (behind the skull): tall, splayed, dark hollows
    ears = []
    for (pts, rad) in (([(92, 100), (66, 52), (46, 8)], [17, 15, 8]),
                       ([(142, 88), (162, 46), (194, 10)], [17, 15, 8])):
        ear = chain(pts, rad)
        ears.append(ear)
        cel(cv, IDENT, ear, stone[:3], [(-5, -5), (-10, -9)], ow=3.4)
        hol = chain([(pts[0][0] + 1, pts[0][1] - 16), (pts[1][0] + 1, pts[1][1]), (pts[2][0] + 1, pts[2][1] + 12)], [7, 6.2, 2.4])
        cv.paint(inter(hol, ear), CR, 0.95)
    # neck: a thick block leaving the frame at the bottom-left
    neck = polygon([(8, 150), (92, 98), (170, 170), (150, 262), (-12, 262), (-12, 170)], 10)
    cel(cv, IDENT, neck, stone, ST, ow=3.8)
    # skull and long muzzle, one stone mass
    skull = ellipse(124, 118, 54, 46)
    muzzle = chain([(150, 126), (192, 156), (218, 184)], [36, 31, 27])
    head = smooth_union(skull, muzzle, 14)
    cel(cv, IDENT, head, stone, [(-6, -6), (-13, -12), (-21, -18)], ow=3.8)
    # stiff mane ridge: blocky teeth down the back of the head and neck
    for i in range(6):
        t = i / 5
        bx, by = 92 - 78 * t, 96 + 58 * t
        cel(cv, IDENT, polygon([(bx + 9, by + 10), (bx - 4, by - 20), (bx - 12, by + 4)], 1.5), stone[:3], [(-2, -2), (-4, -4)], ow=2.6)
    # stone speckle
    for _ in range(30):
        sx, sy = rng.uniform(30, 210), rng.uniform(80, 210)
        r = rng.uniform(1.2, 2.6)
        cv.paint(inter(circle(sx, sy, r), union(head, neck)), Q0 if rng.random() < 0.6 else Q3, 0.5)
    # face
    # stone brow block over the eye
    cel(cv, IDENT, polygon([(128, 98), (166, 88), (176, 104), (134, 112)], 3), stone[:3], [(-2, -2), (-4, -4)], ow=2.8)
    # big round dark eye with a glint
    cv.paint(circle(153, 118, 12.5), OUTLINE)
    cv.paint(circle(153, 118, 10), (0x08, 0x09, 0x0E))
    cv.paint(circle(149, 114, 3.4), (0xD8, 0xDC, 0xE0))
    # mouth line and nostril
    stroke(cv, [(166, 178), (196, 198), (228, 202)], 4.2, OUTLINE, 1.0, clip=head)
    cv.paint(ellipse(214, 168, 6, 9), OUTLINE)
    cv.paint(ellipse(213, 169, 3.4, 6), CR)
    # three bold fissures with black interiors and a lit lip
    fiss = [[(86, 96), (110, 104), (124, 90), (146, 100)],                      # forehead
            [(52, 168), (66, 190), (50, 212), (64, 244)],                       # neck
            [(166, 52), (176, 38), (168, 28), (180, 20)]]                       # ear
    for pts in fiss:
        stroke(cv, [(x + 2, y + 1.5) for x, y in pts], 5, Q3, 0.7, clip=union(head, neck, *ears))
    for pts in fiss:
        stroke(cv, pts, 10, OUTLINE, 1.0, clip=union(head, neck, *ears))
    for pts in fiss:
        stroke(cv, pts, 6, CR, 1.0, clip=union(head, neck, *ears))
    # chipped ear tip: bite out of the right ear
    cv.paint(polygon([(186, 4), (206, 6), (196, 22)], 1), OUTLINE)
    # flying chips
    for cx, cy, a, k in ((226, 66, 20, 1.2), (124, 30, 70, 1.0)):
        c, s = math.cos(math.radians(a)), math.sin(math.radians(a))
        pts = [(cx + k * (c * x - s * y), cy + k * (s * x + c * y)) for x, y in ((-8, -5), (9, -6), (5, 8), (-6, 5))]
        cel(cv, IDENT, polygon(pts, 0.5), [Q0, Q1, Q2], [(-1.5, -1.5), (-3, -3)], ow=2.6)
    # dust puffs
    DU = [(0x4A, 0x4C, 0x52), (0x80, 0x82, 0x86), (0xB4, 0xB4, 0xB0)]
    blob(cv, [(200, 244, 14), (224, 238, 12), (180, 246, 10), (240, 248, 9)], DU, [(-4, -5), (-9, -9)], 0.92, OUTLINE, 2.4)
    blob(cv, [(228, 134, 11), (244, 124, 8), (240, 146, 7)], DU, [(-3, -4), (-6, -6)], 0.92, OUTLINE, 2.2)
    cv.shadow_under(5, 6, 3, 0.28)
    return cv


# ---------------------------------------------------------------- icon 5: Buddy Bomb
def draw_buddy_bomb():
    cv = Canvas(SIZE, SIZE)
    rng = random.Random(71)
    coat = [DG0, DG1, DG2, DG3]

    # tail first: a curly plume over the rump
    blob(cv, [(222, 98, 13), (232, 82, 12), (238, 66, 10), (232, 52, 8)], [DG1, DG2, DG3], [(-3, -4), (-6, -7)],
         outline=OUTLINE, ow=3.0)
    # legs: the far pair darker, set back; the near pair trotting, each ending in a pale curly paw
    for x0, y0, x1, y1, far in ((114, 152, 100, 214, 1), (190, 150, 206, 210, 1), (96, 156, 70, 222, 0),
                                (176, 158, 180, 226, 0)):
        cols = [DG0, DG1, DG2] if far else [DG1, DG2, DG3]
        cel(cv, IDENT, chain([(x0, y0), ((x0 + x1) / 2 + 4, (y0 + y1) / 2), (x1, y1)], [15, 12, 11]), cols,
            [(-2, -2), (-4, -4)], ow=3.0)
        blob(cv, [(x1 - 4, y1 + 6, 9), (x1 + 6, y1 + 7, 8)], [DG2, DG3, (0x80, 0x80, 0x8A)], [(-2, -2), (-4, -4)],
             outline=OUTLINE, ow=2.6)
    # the body: a long cloud of tight curls
    curls = [(150, 128, 44), (112, 132, 36), (192, 124, 36), (130, 102, 32), (176, 98, 32), (214, 116, 26),
             (96, 112, 26), (150, 158, 30), (120, 156, 26), (186, 152, 26)]
    body = union(*[circle(*c) for c in curls])
    cel(cv, IDENT, body, coat, [(-6, -7), (-13, -15), (-20, -24)], ow=3.6)
    # curl texture: little dark hooks and grey highlights clipped to the coat
    for _ in range(30):
        cx, cy = rng.uniform(80, 228), rng.uniform(76, 178)
        a = rng.uniform(1.2, 2.4)                    # each curl a short arc open to the upper left, lit from there
        r = rng.uniform(3.5, 5.5)
        pts = [(cx + math.cos(a + t * 0.8) * r, cy + math.sin(a + t * 0.8) * r) for t in range(4)]
        stroke(cv, pts, 2.0, DG0, 0.6, clip=body)
    for _ in range(18):
        cv.paint(inter(circle(rng.uniform(86, 222), rng.uniform(80, 150), rng.uniform(2.0, 3.6)), body), DG3, 0.8)
    # the harness: two red straps round the chest and the belly, each with a brass buckle
    for sx in (118, 186):
        strap = inter(rbox(sx, 132, 7, 60, 3), grow(body, -1))
        cv.paint(strap, HR0)
        cv.paint(inter(strap, shift(strap, -2, 0)), HR1)
        cv.paint(circle(sx, 158, 4.2), OUTLINE)
        cv.paint(circle(sx, 158, 2.8), N3)
    # dynamite: three red sticks strapped across the back, the third peeking over the other two
    for sx, sy in ((152, 64), (146, 80), (158, 92)):
        def St(f, sx=sx, sy=sy):
            return place(f, sx, sy, -6)
        cel(cv, St, rbox(0, 0, 50, 9, 8), [DY0, DY1, DY2, DY3], [(0, -3), (0, -6), (0, -8)], ow=3.0)
        for ex in (-50, 50):                                         # paper end caps
            cel(cv, St, ellipse(ex, 0, 4, 8.5), [N1, N2, N3], [(-1, -1), (-2, -2)], ow=2.2)
    for tx in (126, 180):                                            # black tape round the bundle
        cv.paint(place(rbox(0, 0, 5, 26, 2), tx, 80, -6), OUTLINE)
        cv.paint(place(rbox(-1, -1, 3, 24, 1.5), tx, 80, -6), (0x3A, 0x36, 0x30))
    # the lit fuse: a cord from the front stick's cap up into a spark
    fz = bezier((98, 82), (82, 70), (96, 46), (80, 30), 20)
    stroke(cv, fz, 5.4, OUTLINE)
    stroke(cv, fz, 3.0, (0x4A, 0x40, 0x34))
    sx, sy = fz[-1]
    for ang, ln in ((0, 22), (45, 14), (90, 20), (135, 14), (180, 22), (225, 14), (270, 20), (315, 14)):
        tipx = sx + math.cos(math.radians(ang)) * ln
        tipy = sy + math.sin(math.radians(ang)) * ln
        cv.paint(capsule(sx, sy, tipx, tipy, 2.4), E1, 0.95)
    cv.paint(circle(sx, sy, 9), E0, 0.9)
    cv.paint(circle(sx, sy, 6.5), E2)
    cv.paint(circle(sx, sy, 3.6), E3)

    # the head, held up and happy, facing left
    def Hd(f):
        return place(f, 64, 118, -8)
    skull = smooth_union(ellipse(0, 0, 34, 31), ellipse(-30, 14, 24, 17), 12)
    cel(cv, Hd, skull, coat, [(-3, -4), (-7, -8), (-12, -13)], ow=3.4)
    cel(cv, Hd, union(circle(-6, -28, 16), circle(12, -26, 14), circle(-20, -22, 11)), coat,
        [(-3, -4), (-6, -8), (-10, -12)], ow=3.0)                    # top-knot
    for _ in range(10):
        cx, cy = rng.uniform(-40, 26), rng.uniform(-40, 26)
        cv.paint(Hd(inter(circle(cx, cy, rng.uniform(1.8, 3.0)), skull)), DG3, 0.75)
    # open, panting mouth with the tongue hanging out
    mouth = polygon([(-50, 22), (-14, 20), (-18, 30), (-44, 32)], 2)
    cv.paint(Hd(mouth), OUTLINE)
    cv.paint(Hd(grow(mouth, -2)), (0x5A, 0x14, 0x18))
    tongue = smooth_union(ellipse(-30, 34, 9, 7), ellipse(-28, 44, 8, 9), 6)
    cel(cv, Hd, tongue, [(0xB0, 0x3C, 0x50), (0xE4, 0x6E, 0x82), (0xFF, 0xA4, 0xB2)], [(-1, -2), (-3, -4)], ow=2.6)
    cv.paint(Hd(capsule(-29, 30, -28, 46, 1.0)), (0xA0, 0x30, 0x44))
    # the nose: a glossy dark-grey button at the end of the snout
    cel(cv, Hd, ellipse(-52, 6, 9, 7), [(0x2A, 0x28, 0x2C), (0x48, 0x46, 0x4C), (0x6C, 0x6A, 0x72)],
        [(-1, -2), (-3, -3)], ow=2.4)
    cv.paint(Hd(circle(-55, 3, 2.2)), (0xD8, 0xD4, 0xD0), 0.9)
    # a big brown eye with a catch-light, eyebrow raised
    ex, ey = rot_pt((-16, -6), 64, 118, -8)
    cv.paint(circle(ex, ey, 9.5), OUTLINE)
    cv.paint(circle(ex, ey, 7.6), (0x9C, 0x5C, 0x24))
    cv.paint(circle(ex, ey, 4.6), (0x10, 0x0A, 0x06))
    cv.paint(circle(ex - 2.6, ey - 2.8, 2.4), (0xFF, 0xFC, 0xF0))
    cv.paint(Hd(capsule(-26, -20, -8, -22, 2.4)), DG3)
    # the floppy ear hangs over the back of the head
    ear = smooth_union(ellipse(18, 12, 14, 26), circle(14, -10, 11), 8)
    cel(cv, Hd, ear, [EA0, EA1, EA2], [(-2, -3), (-5, -6)], ow=3.0)
    for _ in range(6):
        cv.paint(Hd(inter(circle(rng.uniform(8, 28), rng.uniform(-10, 34), rng.uniform(1.6, 2.6)), ear)), DG2, 0.7)
    # red collar with a brass tag
    cv.paint(Hd(inter(rbox(22, 22, 6, 30, 3), grow(skull, 6))), HR0)
    cv.paint(Hd(inter(rbox(21, 22, 4, 28, 2), grow(skull, 5))), HR1)
    tx, ty = rot_pt((24, 46), 64, 118, -8)
    cv.paint(circle(tx, ty, 6.6), OUTLINE)
    cv.paint(circle(tx, ty, 5.0), N2)
    cv.paint(circle(tx - 1.2, ty - 1.4, 2.0), N3)
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
         ("earthquake-ass", draw_earthquake_ass), ("buddy-bomb", draw_buddy_bomb), ("plague-ram", draw_plague_ram)]
