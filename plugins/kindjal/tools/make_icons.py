#!/usr/bin/env python3
"""Generate Kindjal's weapon icons: acid-spitter, acid-flask, crucible.

For each weapon one 256x256 drawing is rendered, then written twice:
  mod/assets/loose/kindjal.<name>.hud.tga   256x256 32-bit uncompressed TGA (type 2, bottom-left origin, 8 alpha bits,
                                            TGA 2.0 footer, the same layout as the game's own Data/HUD/Weapons icons)
  mod/assets/icons/<name>.png               64x64 RGBA PNG, that drawing box-filtered down 4x4 in premultiplied space

The look follows the vanilla HUD icons: a thin near-black outline, three-tone cel shading with the light from the
upper left, a tilted three-quarter pose that fills the frame, a faint soft shadow. The palette is dark and gritty.
Every shape is a signed-distance function evaluated per pixel (coverage = clamp(0.5 - d), exact 1px anti-aliasing) and
composited with premultiplied alpha. Fixed geometry and fixed seeds, so the output is deterministic. All art is
original, drawn by code; nothing is copied from the game. Stdlib only.

    python make_icons.py           write the files
    python make_icons.py --check   regenerate in memory and compare byte-for-byte with disk; exit 1 on any difference
"""
import math
import random
import struct
import sys
import pathlib
import zlib
from pathlib import Path

MOD = Path(__file__).resolve().parent.parent / "mod"
PNG_DIR = MOD / "assets" / "icons"
TGA_DIR = MOD / "assets" / "loose"
SIZE = 256
SMALL = 64

OUTLINE = (0x16, 0x11, 0x0E)
OUTLINE_G = (0x0E, 0x1E, 0x08)          # outline for acid shapes: a green-black so the glow reads

# gunmetal
G0, G1, G2, G3 = (0x1E, 0x23, 0x24), (0x37, 0x40, 0x3F), (0x5A, 0x66, 0x62), (0x8A, 0x98, 0x8C)
# rust
R0, R1, R2 = (0x52, 0x26, 0x12), (0x84, 0x40, 0x18), (0xB8, 0x6C, 0x2C)
# acid
A0, A1, A2, A3, A4 = (0x1E, 0x5C, 0x0C), (0x3F, 0x9E, 0x14), (0x7C, 0xD8, 0x2A), (0xB8, 0xF8, 0x56), (0xEA, 0xFF, 0xB4)
# glass
S0, S1, S2, S3 = (0x22, 0x31, 0x34), (0x3A, 0x52, 0x56), (0x62, 0x84, 0x86), (0xDA, 0xF0, 0xEA)
# cork / leather
C0, C1, C2 = (0x33, 0x22, 0x14), (0x62, 0x44, 0x26), (0x92, 0x6C, 0x3E)
# black iron of the crucible
B0, B1, B2, B3 = (0x0C, 0x0B, 0x10), (0x19, 0x17, 0x20), (0x28, 0x26, 0x31), (0x48, 0x44, 0x56)
# ember
E0, E1, E2, E3 = (0xB4, 0x2C, 0x08), (0xFF, 0x6A, 0x12), (0xFF, 0xA8, 0x2E), (0xFF, 0xE6, 0x8A)


# ---------------------------------------------------------------- signed distances (negative inside)
# Every shape carries .bb = (x0, y0, x1, y1), a box that contains the region where its distance is below ~1px, so
# painting only visits those pixels. Combinators below keep the box up to date.
def _sh(f, bb):
    f.bb = tuple(bb)
    return f


def circle(cx, cy, r):
    return _sh(lambda x, y: math.hypot(x - cx, y - cy) - r, (cx - r, cy - r, cx + r, cy + r))


def ellipse(cx, cy, rx, ry):
    def f(x, y):                      # first-order distance estimate; exact enough for 1px edges
        px, py = (x - cx) / rx, (y - cy) / ry
        k0 = math.hypot(px, py)
        if k0 < 1e-9:
            return -min(rx, ry)
        k1 = math.hypot(px / rx, py / ry)
        return k0 * (k0 - 1.0) / k1
    return _sh(f, (cx - rx, cy - ry, cx + rx, cy + ry))


def rbox(cx, cy, hx, hy, r):
    def f(x, y):
        qx = abs(x - cx) - hx + r
        qy = abs(y - cy) - hy + r
        return math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - r
    return _sh(f, (cx - hx, cy - hy, cx + hx, cy + hy))


def box(x0, y0, x1, y1):
    return rbox((x0 + x1) / 2, (y0 + y1) / 2, (x1 - x0) / 2, (y1 - y0) / 2, 0)


def capsule(ax, ay, bx, by, r):
    ex, ey = bx - ax, by - ay
    ll = ex * ex + ey * ey

    def f(x, y):
        wx, wy = x - ax, y - ay
        t = max(0.0, min(1.0, (wx * ex + wy * ey) / ll)) if ll else 0.0
        return math.hypot(wx - ex * t, wy - ey * t) - r
    return _sh(f, (min(ax, bx) - r, min(ay, by) - r, max(ax, bx) + r, max(ay, by) + r))


def ring(cx, cy, r0, r1):
    return _sh(lambda x, y: abs(math.hypot(x - cx, y - cy) - (r0 + r1) / 2) - (r1 - r0) / 2,
               (cx - r1, cy - r1, cx + r1, cy + r1))


def polygon(pts, rad=0.0):
    n = len(pts)

    def f(x, y):
        d = 1e9
        inside = False
        for i in range(n):
            ax, ay = pts[i]
            bx, by = pts[(i + 1) % n]
            ex, ey = bx - ax, by - ay
            wx, wy = x - ax, y - ay
            t = max(0.0, min(1.0, (wx * ex + wy * ey) / (ex * ex + ey * ey)))
            d = min(d, math.hypot(wx - ex * t, wy - ey * t))
            if (ay > y) != (by > y) and x < ax + (y - ay) / (by - ay) * ex:
                inside = not inside
        return (-d if inside else d) - rad
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    return _sh(f, (min(xs) - rad, min(ys) - rad, max(xs) + rad, max(ys) + rad))


def grow(f, k):
    x0, y0, x1, y1 = f.bb
    return _sh(lambda x, y: f(x, y) - k, (x0 - k, y0 - k, x1 + k, y1 + k) if k > 0 else f.bb)


def shift(f, dx, dy):
    x0, y0, x1, y1 = f.bb
    return _sh(lambda x, y: f(x - dx, y - dy), (x0 + dx, y0 + dy, x1 + dx, y1 + dy))


def inter(a, b):
    return _sh(lambda x, y: max(a(x, y), b(x, y)),
               (max(a.bb[0], b.bb[0]), max(a.bb[1], b.bb[1]), min(a.bb[2], b.bb[2]), min(a.bb[3], b.bb[3])))


def sub(a, b):
    return _sh(lambda x, y: max(a(x, y), -b(x, y)), a.bb)


def union(*fs):
    return _sh(lambda x, y: min(f(x, y) for f in fs),
               (min(f.bb[0] for f in fs), min(f.bb[1] for f in fs), max(f.bb[2] for f in fs), max(f.bb[3] for f in fs)))


def smooth_union(a, b, k):
    """Goo-style union: the two shapes bridge with a fillet of about k pixels."""
    def f(x, y):
        da, db = a(x, y), b(x, y)
        h = max(k - abs(da - db), 0.0) / k
        return min(da, db) - h * h * k * 0.25
    return _sh(f, (min(a.bb[0], b.bb[0]) - k, min(a.bb[1], b.bb[1]) - k, max(a.bb[2], b.bb[2]) + k, max(a.bb[3], b.bb[3]) + k))


def place(f, ox, oy, ang):
    """Draw a shape that was built around the origin, rotated clockwise on screen by ang degrees, moved to (ox, oy)."""
    c, s = math.cos(math.radians(ang)), math.sin(math.radians(ang))

    def g(x, y):
        dx, dy = x - ox, y - oy
        return f(c * dx + s * dy, -s * dx + c * dy)
    corners = [(f.bb[0], f.bb[1]), (f.bb[2], f.bb[1]), (f.bb[2], f.bb[3]), (f.bb[0], f.bb[3])]
    pts = [(ox + c * qx - s * qy, oy + s * qx + c * qy) for qx, qy in corners]
    return _sh(g, (min(p[0] for p in pts), min(p[1] for p in pts), max(p[0] for p in pts), max(p[1] for p in pts)))


def rot_pt(q, ox, oy, ang):
    c, s = math.cos(math.radians(ang)), math.sin(math.radians(ang))
    return (ox + c * q[0] - s * q[1], oy + s * q[0] + c * q[1])


def lerp(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def cov(d):
    return max(0.0, min(1.0, 0.5 - d))


# ---------------------------------------------------------------- canvas
class Canvas:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.px = [[0.0, 0.0, 0.0, 0.0] for _ in range(w * h)]  # premultiplied r,g,b,a (0..1)

    def paint(self, sdf, color, alpha=1.0):
        """color is an (r,g,b) tuple or a function (x, y) -> (r,g,b)."""
        w = self.w
        x0, y0, x1, y1 = sdf.bb
        i0, i1 = max(0, int(math.floor(x0 - 1))), min(w, int(math.ceil(x1 + 1)))
        j0, j1 = max(0, int(math.floor(y0 - 1))), min(self.h, int(math.ceil(y1 + 1)))
        for j in range(j0, j1):
            for i in range(i0, i1):
                c = cov(sdf(i + 0.5, j + 0.5)) * alpha
                if c <= 0.0:
                    continue
                r, g, b = color(i + 0.5, j + 0.5) if callable(color) else color
                p = self.px[j * w + i]
                k = 1.0 - c
                p[0] = r / 255 * c + p[0] * k
                p[1] = g / 255 * c + p[1] * k
                p[2] = b / 255 * c + p[2] * k
                p[3] = c + p[3] * k

    def shadow_under(self, dx, dy, blur, alpha):
        """Soft black drop shadow of everything drawn so far, composited behind it."""
        w, h = self.w, self.h
        a = [0.0] * (w * h)
        for j in range(h):
            for i in range(w):
                si, sj = i - dx, j - dy
                if 0 <= si < w and 0 <= sj < h:
                    a[j * w + i] = self.px[sj * w + si][3]
        for _ in range(2):                               # two box blurs of radius `blur` ~ a soft falloff
            for horiz in (True, False):
                out = [0.0] * (w * h)
                for j in range(h):
                    for i in range(w):
                        s, n = 0.0, 0
                        for k in range(-blur, blur + 1):
                            ii, jj = (i + k, j) if horiz else (i, j + k)
                            if 0 <= ii < w and 0 <= jj < h:
                                s += a[jj * w + ii]
                            n += 1
                        out[j * w + i] = s / n
                a = out
        for idx in range(w * h):
            c = a[idx] * alpha
            if c > 0:
                p = self.px[idx]
                k = 1.0 - p[3]                           # existing pixels stay on top
                p[3] += c * k
                # shadow colour is black, so premultiplied rgb is untouched

    def straight(self, bleed):
        """Rows of straight-alpha 8-bit RGBA; fully transparent pixels get `bleed` so filtering never fringes."""
        rows = []
        for j in range(self.h):
            row = bytearray()
            for i in range(self.w):
                r, g, b, a = self.px[j * self.w + i]
                if a <= 1e-4:
                    row += bytes(bleed + (0,))
                else:
                    row += bytes([min(255, round(r / a * 255)), min(255, round(g / a * 255)),
                                  min(255, round(b / a * 255)), min(255, round(a * 255))])
            rows.append(bytes(row))
        return rows

    def downsample(self, f):
        out = Canvas(self.w // f, self.h // f)
        n = f * f
        for j in range(out.h):
            for i in range(out.w):
                acc = [0.0, 0.0, 0.0, 0.0]
                for v in range(f):
                    for u in range(f):
                        p = self.px[(j * f + v) * self.w + i * f + u]
                        for q in range(4):
                            acc[q] += p[q]
                out.px[j * out.w + i] = [x / n for x in acc]
        return out


# ---------------------------------------------------------------- encoders
def png_bytes(cv, bleed):
    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)
    raw = b"".join(b"\x00" + r for r in cv.straight(bleed))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", cv.w, cv.h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def tga_bytes(cv, bleed):
    """Type 2 (uncompressed true colour), 32 bpp, descriptor 0x08 = 8 alpha bits with a bottom-left origin."""
    head = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, cv.w, cv.h, 32, 0x08)
    rows = cv.straight(bleed)
    body = bytearray()
    for row in reversed(rows):                           # bottom row first
        for i in range(cv.w):
            r, g, b, a = row[i * 4:i * 4 + 4]
            body += bytes((b, g, r, a))
    return head + bytes(body) + b"\x00" * 8 + b"TRUEVISION-XFILE.\x00"


# ---------------------------------------------------------------- drawing helpers
def cel(cv, T, f, cols, offs, outline=OUTLINE, ow=3.2):
    """Outlined body with nested lit lenses: cols[0] is the shadow tone, each next colour a smaller lens shifted by the
    matching offset (toward the upper left), which leaves a crescent of the previous tone on the lower right."""
    cv.paint(T(grow(f, ow)), outline)
    cv.paint(T(f), cols[0])
    for col, (dx, dy) in zip(cols[1:], offs):
        cv.paint(T(inter(f, shift(f, dx, dy))), col)


def stroke(cv, pts, w, color, alpha=1.0, clip=None):
    for a, b in zip(pts, pts[1:]):
        s = capsule(a[0], a[1], b[0], b[1], w / 2)
        cv.paint(inter(s, clip) if clip else s, color, alpha)


def crack(rng, x, y, ang, length, depth, out, spread=0.55):
    """Random-walk crack; returns polylines (lists of points) with a width weight, branching a few times."""
    pts = [(x, y)]
    n = max(3, int(length / 11))
    for k in range(n):
        ang += rng.uniform(-spread, spread)
        step = length / n * rng.uniform(0.7, 1.3)
        x, y = x + math.cos(ang) * step, y + math.sin(ang) * step
        pts.append((x, y))
        if depth > 0 and k > 0 and rng.random() < 0.42:
            side = 1 if rng.random() < 0.5 else -1
            crack(rng, x, y, ang + side * rng.uniform(0.7, 1.2), length * rng.uniform(0.35, 0.55), depth - 1, out)
    out.append((pts, depth))


# ---------------------------------------------------------------- icon 1: Acid Spitter
def draw_spitter():
    cv = Canvas(SIZE, SIZE)
    O, ANG = (100, 156), -36

    def T(f):
        return place(f, O[0], O[1], ANG)

    def P(x, y):
        return rot_pt((x, y), O[0], O[1], ANG)

    rng = random.Random(11)
    flare = polygon([(-64, -22), (-94, -35), (-94, 35), (-64, 22)], 3)
    barrel = rbox(0, 0, 70, 25, 7)
    collar = rbox(72, 0, 14, 33, 6)
    tank = rbox(-8, -49, 31, 14, 12)
    grip = polygon([(-34, 22), (-12, 22), (-2, 62), (-26, 68)], 4)
    foregrip = rbox(38, 40, 8, 17, 4)

    cel(cv, T, grip, [C0, (0x4A, 0x31, 0x1E), C1], [(-4, -3), (-8, -5)])
    cel(cv, T, foregrip, [C0, (0x4A, 0x31, 0x1E), C1], [(-3, -3), (-6, -5)])
    cel(cv, T, flare, [G0, G1, G2], [(0, -6), (0, -11)])
    # tank brackets, behind the tank and barrel
    for bx in (-30, 14):
        cel(cv, T, rbox(bx, -30, 5, 8, 2), [G0, G1, G2], [(-1.5, -2), (-3, -4)], ow=2.6)
    cel(cv, T, barrel, [G0, G1, G2, G3], [(0, -7), (0, -13), (0, -19)])
    # rust patches and acid pits on the barrel, clipped to it
    for _ in range(9):
        px, py = rng.uniform(-62, 52), rng.uniform(-18, 18)
        rx, ry = rng.uniform(5, 13), rng.uniform(3, 7)
        cv.paint(T(inter(ellipse(px, py, rx, ry), barrel)), R1)
        cv.paint(T(inter(ellipse(px - 1.5, py - 1.5, rx * 0.6, ry * 0.55), barrel)), R2)
    for _ in range(7):
        cv.paint(T(inter(circle(rng.uniform(-60, 55), rng.uniform(-20, 20), rng.uniform(1.6, 3.2)), barrel)), A2)
    cv.paint(T(inter(box(-70, -26, 70, -22), barrel)), G3, 0.55)    # thin specular along the top edge
    for bx in (-30, 22):
        cel(cv, T, rbox(bx, 0, 6, 29, 3), [G0, G1, G2], [(-1.5, -4), (-3, -8)], ow=2.6)
        cv.paint(T(circle(bx, -18, 1.8)), R2)
        cv.paint(T(circle(bx, 18, 1.8)), R1)
    cel(cv, T, collar, [G0, G1, G2, G3], [(0, -6), (0, -12), (0, -18)])
    for k in range(5):
        cv.paint(T(inter(circle(rng.uniform(62, 84), rng.uniform(-28, 28), rng.uniform(2.0, 3.6)), collar)),
                 A2 if k % 2 else A1)
    # tank of acid, on top
    cel(cv, T, tank, [A0, A1, A2, A3], [(-3, -5), (-7, -9), (-13, -11)], outline=OUTLINE_G)
    cv.paint(T(rbox(-8, -49, 29, 12, 10)), A0, 0.0)
    cv.paint(T(inter(box(-30, -58, 20, -56), tank)), A4, 0.85)
    for k, (bx, by) in enumerate([(-24, -45), (-4, -50), (10, -44), (-14, -53)]):
        cv.paint(T(ring(bx, by, 1.6 + k % 2, 3.4 + k % 2)), A4, 0.8)
    for ex in (-40, 24):
        cel(cv, T, rbox(ex, -49, 5, 18, 3), [G0, G1, G2], [(-1.5, -4), (-3, -9)], ow=2.8)
    # muzzle opening: dark bore with acid glowing inside
    mouth = ellipse(86, 0, 9, 27)
    cv.paint(T(grow(mouth, 3)), OUTLINE)
    cv.paint(T(mouth), (0x08, 0x10, 0x06))
    glow = ellipse(87, 0, 6, 20)
    cv.paint(T(glow), A1)
    cv.paint(T(ellipse(88, -2, 3.6, 12)), A3)
    cv.paint(T(ellipse(88.5, -4, 1.6, 5)), A4)

    # the spat glob in screen space: a fat drop on a thinning strand, with satellite droplets
    mz = P(87, 0)
    gx, gy = 220, 64
    goo = smooth_union(circle(gx, gy, 22), capsule(mz[0] + 12, mz[1] - 9, gx - 12, gy + 9, 4.6), 14)
    goo = smooth_union(goo, circle(gx - 22, gy + 24, 6.5), 10)
    for sx, sy, sr in ((196, 30, 6.0), (242, 100, 5.0), (238, 30, 3.6)):
        goo = union(goo, circle(sx, sy, sr))
    cel(cv, lambda f: f, goo, [A0, A1, A2, A3], [(-4, -5), (-9, -11), (-14, -17)], outline=OUTLINE_G, ow=3.4)
    cv.paint(ellipse(gx - 9, gy - 11, 7, 4.2), A4)
    cv.paint(circle(gx + 5, gy + 4, 2.2), A0, 0.9)
    cv.paint(ring(gx + 6, gy + 6, 2.5, 4.4), A0, 0.9)
    cv.paint(ring(gx - 8, gy + 12, 1.6, 3.2), A0, 0.9)
    # drips hanging off the collar
    for dx, dy, dl, dr in ((171, 146, 26, 3.8), (184, 139, 15, 3.2)):
        d = smooth_union(circle(dx, dy, 5.4), capsule(dx, dy, dx, dy + dl, dr * 0.7), 6)
        d = union(d, circle(dx, dy + dl + 4, dr + 1.2))
        cel(cv, lambda f: f, d, [A0, A1, A2], [(-1.5, -2), (-3, -4)], outline=OUTLINE_G, ow=2.6)
    cv.shadow_under(5, 8, 3, 0.30)
    return cv


# ---------------------------------------------------------------- icon 2: Acid Flask
def draw_flask():
    cv = Canvas(SIZE, SIZE)
    O, ANG = (118, 142), 20

    def T(f):
        return place(f, O[0], O[1], ANG)

    def P(x, y):
        return rot_pt((x, y), O[0], O[1], ANG)

    bulb = circle(0, 30, 60)
    neck = rbox(0, -46, 18, 44, 4)
    glass = smooth_union(bulb, neck, 20)
    lip = rbox(0, -91, 25, 8, 4)
    cork = polygon([(-17, -98), (17, -98), (14, -124), (-14, -124)], 3)

    # cork
    cel(cv, T, cork, [C0, C1, C2], [(-4, -2), (-9, -4)])
    for kx, ky in ((-6, -108), (6, -115), (-2, -119)):
        cv.paint(T(ellipse(kx, ky, 3.4, 1.8)), C0, 0.8)
    # glass body, empty tone then lit lenses (screen-space so the light stays upper left)
    gs = T(glass)
    cv.paint(grow(gs, 3.4), OUTLINE_G)
    cv.paint(gs, S0)
    cv.paint(inter(gs, shift(gs, -7, -7)), S1)
    cv.paint(inter(gs, shift(gs, -15, -15)), S2)
    # acid inside: flat surface in screen space
    inner = grow(gs, -6.5)
    level = 166
    liq = inter(inner, box(0, level, SIZE, SIZE))
    cv.paint(liq, A0)
    cv.paint(inter(liq, shift(inner, -6, -6)), A1)
    cv.paint(inter(liq, shift(inner, -13, -13)), A2)
    cv.paint(inter(inner, box(0, level - 3, SIZE, level + 3)), A3)         # meniscus line
    cv.paint(inter(inner, box(0, level - 3, SIZE, level - 1.2)), A4, 0.9)
    for bx, by, br in ((95, 196, 6.2), (118, 208, 4.2), (88, 178, 3.2), (131, 186, 5.0), (108, 182, 2.6), (140, 205, 3)):
        cv.paint(ring(bx, by, br - 1.8, br), A4, 0.9)
        cv.paint(circle(bx - br * 0.35, by - br * 0.35, 1.1), A4, 0.9)
    for bx, by, br in ((112, 124, 3.4), (119, 140, 2.4), (123, 108, 2.2)):      # vapour bubbles above the surface
        cv.paint(ring(bx, by, br - 1.1, br), S3, 0.6)
    # lip ring over the neck, drawn after so it overlaps the fillet
    cel(cv, T, lip, [S0, S1, S2], [(-3, -2), (-6, -4)], outline=OUTLINE_G, ow=3)
    # glass highlights: one curved arc on the bulb, a stripe down the neck
    bc = P(0, 30)
    arc = inter(ring(bc[0], bc[1], 47, 52), polygon([bc, (bc[0] - 120, bc[1] - 20), (bc[0] - 120, bc[1] - 120), (bc[0] - 30, bc[1] - 120)]))
    cv.paint(inter(arc, gs), S3, 0.85)
    cv.paint(T(inter(rbox(-9, -48, 2.2, 30, 2), glass)), S3, 0.85)
    cv.paint(T(circle(-30, 4, 2.6)), S3, 0.85)
    # crack running down the glass, with acid seeping out of it
    cr = [(128, 112), (137, 126), (129, 139), (146, 153), (140, 170), (154, 184), (149, 200), (160, 207)]
    stroke(cv, cr, 6, A1, 0.85, clip=inter(gs, box(0, 0, SIZE, SIZE)))
    stroke(cv, cr, 4.0, OUTLINE_G, 1.0, clip=gs)
    stroke(cv, cr, 1.7, S3, 0.95, clip=gs)
    for a, b in (((137, 126), (153, 124)), ((129, 139), (116, 142)), ((140, 170), (127, 175)), ((154, 184), (166, 180))):
        stroke(cv, [a, b], 2.4, OUTLINE_G, 1.0, clip=gs)
        stroke(cv, [a, b], 0.9, S3, 0.9, clip=gs)
    # drips running off the outside of the glass and a spill underneath
    ex, ey = 160, 207
    d1 = smooth_union(circle(ex, ey, 6.4), capsule(ex, ey, ex + 1, ey + 13, 3.2), 8)       # teardrop still hanging
    cel(cv, lambda f: f, d1, [A0, A1, A2], [(-1.5, -2), (-3, -4)], outline=OUTLINE_G, ow=2.8)
    d3 = smooth_union(circle(ex + 2, ey + 28, 4.4), capsule(ex + 2, ey + 28, ex + 2, ey + 22, 1.8), 5)  # one falling away
    cel(cv, lambda f: f, d3, [A0, A1, A2], [(-1.5, -2), (-2.5, -3)], outline=OUTLINE_G, ow=2.6)
    d2 = smooth_union(circle(171, 172, 4.6), capsule(171, 172, 172, 190, 3.0), 6)
    d2 = union(d2, circle(172, 194, 4.2))
    cel(cv, lambda f: f, d2, [A0, A1, A2], [(-1.5, -2), (-2.5, -3)], outline=OUTLINE_G, ow=2.6)
    spill = smooth_union(ellipse(128, 244, 52, 6.0), ellipse(168, 241, 18, 4.6), 6)
    cel(cv, lambda f: f, spill, [A0, A1, A2], [(-2, -2), (-5, -3)], outline=OUTLINE_G, ow=2.6)
    cv.paint(ellipse(118, 241.5, 14, 1.6), A4, 0.9)
    cv.shadow_under(5, 7, 3, 0.28)
    return cv


# ---------------------------------------------------------------- icon 3: Crucible
def draw_crucible():
    cv = Canvas(SIZE, SIZE)
    O, ANG = (120, 148), 30

    def T(f):
        return place(f, O[0], O[1], ANG)

    sphere = circle(O[0], O[1], 80)

    # A fan of short, broad spikes radiating over the upper half of the orb, so it reads as a spiked
    # mine rather than a head with ears (three tall horns on top looked like a cat at 64 px).
    # Angles are from straight up in the orb's own frame; each spike is wide at its foot and short.
    spike_angles = (-90, -60, -30, 0, 30, 60, 90)
    for deg in spike_angles:
        a = math.radians(deg)
        ux, uy = math.sin(a), -math.cos(a)            # outward direction
        px, py = -uy, ux                              # across the spike
        r0, r1, hw = 72, 108, 15
        tip = (ux * r1, uy * r1)
        foot_a = (ux * r0 + px * hw, uy * r0 + py * hw)
        foot_b = (ux * r0 - px * hw, uy * r0 - py * hw)
        cel(cv, T, polygon([foot_a, tip, foot_b], 2), [B0, B1, B2], [(-3, -3), (-6, -5)], ow=3.0)
    cel(cv, lambda f: f, sphere, [B0, B1, B2, B3], [(-9, -9), (-20, -22), (-35, -40)], ow=3.4)
    # ember glow in the valleys between the spikes, drawn over the orb's rim
    for deg in (-75, -45, -15, 15, 45, 75):
        a = math.radians(deg)
        gx, gy = math.sin(a) * 78, -math.cos(a) * 78
        cv.paint(T(circle(gx, gy, 3.2)), E1)
        cv.paint(T(circle(gx - 0.6, gy - 0.6, 1.4)), E3)
    # tiny hard glint on the iron
    cv.paint(ellipse(O[0] - 42, O[1] - 46, 9, 4.5), (0x9A, 0x92, 0xB0), 0.9)

    # molten cracks: random-walk polylines from three seeds, clipped to the sphere
    rng = random.Random(23)
    cracks = []
    cx, cy = O[0], O[1]
    crack(rng, cx + 10, cy - 70, math.radians(112), 118, 2, cracks)
    crack(rng, cx + 70, cy - 8, math.radians(158), 92, 2, cracks)
    crack(rng, cx - 20, cy + 76, math.radians(-76), 82, 1, cracks)
    for pts, depth in cracks:                                     # soft halo first, so cores always sit on top
        stroke(cv, pts, 14 - 3 * depth, E0, 0.30, clip=sphere)
    for pts, depth in cracks:
        stroke(cv, pts, 6.4 - 1.5 * depth, E1, 1.0, clip=sphere)
    for pts, depth in cracks:
        stroke(cv, pts, 3.0 - 0.7 * depth, E2, 1.0, clip=sphere)
    for pts, depth in cracks:
        stroke(cv, pts, 1.3, E3, 1.0, clip=sphere)
    # embers drifting off
    for ex, ey, er in ((222, 70, 3.8), (238, 104, 2.8), (30, 76, 3.4), (22, 118, 2.4), (206, 40, 2.6), (232, 140, 2.2)):
        cv.paint(circle(ex, ey, er + 1.6), E0, 0.45)
        cv.paint(circle(ex, ey, er), E2)
        cv.paint(circle(ex, ey, er * 0.5), E3)
    cv.shadow_under(5, 8, 3, 0.30)
    return cv


ICONS = [("acid-spitter", draw_spitter), ("acid-flask", draw_flask), ("crucible", draw_crucible)]

# The vanilla weapons' replacement icons live in one module per group (tools/icons_*.py); each exports its own ICONS.
GROUPS = ("icons_melee", "icons_explosives", "icons_air", "icons_specials")


def all_icons():
    import importlib
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))  # the group modules sit beside this file
    icons = list(ICONS)
    for mod in GROUPS:
        icons += importlib.import_module(mod).ICONS
    return icons


def tile_rgb(x, y):
    """The weapon panel's own cell tile, redrawn: a 64 px rounded teal square with a one-pixel black rim, a dark ring,
    a lit top-left edge and a fill that darkens toward the bottom right. The panel atlas has no alpha, so a replacement
    for a vanilla weapon's icon is composited onto this tile; the values were measured from the game's blank cells."""
    if x + y < 3 or (63 - x) + (63 - y) < 3 or x + (63 - y) < 3 or (63 - x) + y < 3:
        return (0, 0, 0)
    if x == 0 or y == 0 or x == 63 or y == 63:
        return (0, 2, 3)
    if x == 1 or y == 1:
        return (1, 60, 82)
    if x == 62 or y == 62:
        return (2, 72, 97)
    if x == 2 or y == 2:
        return (30, 152, 178)
    if x == 61 or y == 61:
        return (7, 111, 144)
    if x == 3 or y == 3:
        return (8, 121, 156)
    t = min(1.0, max(0.0, (x + y - 54) / 36.0))
    return (0, round(110 - 14 * t), round(147 - 16 * t))


def tiled(cv):
    """cv (64 px, premultiplied) composited onto the panel tile; returns a new opaque Canvas."""
    out = Canvas(cv.w, cv.h)
    for y in range(cv.h):
        for x in range(cv.w):
            r, g, b, a = cv.px[y * cv.w + x]
            tr, tg, tb = (c / 255.0 for c in tile_rgb(x, y))
            out.px[y * cv.w + x] = [r + tr * (1 - a), g + tg * (1 - a), b + tb * (1 - a), 1.0]
    return out


# The three clone weapons keep transparent panel icons: Melange writes those into blank cells of its own.
CLONE_ICONS = {"acid-spitter", "acid-flask", "crucible"}


def build():
    """Every output file as {path: bytes}."""
    out = {}
    for name, draw in all_icons():
        big = draw()
        small = big.downsample(SIZE // SMALL)
        if name not in CLONE_ICONS:
            small = tiled(small)
        out[PNG_DIR / (name + ".png")] = png_bytes(small, OUTLINE)
        out[TGA_DIR / ("kindjal." + name + ".hud.tga")] = tga_bytes(big, OUTLINE)
    return out


def main():
    files = build()
    if "--check" in sys.argv[1:]:
        bad = 0
        for path, data in files.items():
            if not path.exists():
                print("MISSING  ", path)
                bad += 1
            elif path.read_bytes() != data:
                print("DIFFERENT", path)
                bad += 1
            else:
                print("ok       ", path.name)
        sys.exit(1 if bad else 0)
    for path, data in files.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        print(path.name, len(data))


if __name__ == "__main__":
    main()
