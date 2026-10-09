#!/usr/bin/env python3
"""Generate Kanly's control-hint HUD sprites into mod/textures/.

key.png, key_wide.png, mouse*.png, ring*.png, ring_00..16.png, card.png, chip.png. No text is baked in; the Lua
side draws labels over the flat keycap centres. Every shape is a signed-distance function evaluated per pixel, with
coverage = clamp(0.5 - d), which gives exact 1px anti-aliased edges. Layers are composited with premultiplied alpha.
Fixed geometry and no randomness, so the output is deterministic. Original art, nothing from the game. Stdlib only.
"""
import math
import struct
import zlib
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "mod" / "textures"

OUTLINE = (0x2A, 0x1A, 0x0E)
CREAM = (0xF6, 0xEA, 0xD0)
CREAM_HI = (0xFF, 0xFB, 0xEE)
CREAM_LO = (0xC9, 0xB4, 0x8A)
YELLOW = (0xFF, 0xB8, 0x1C)
ORANGE = (0xE0, 0x7B, 0x00)
NAVY = (0x0E, 0x22, 0x36)
GOLD = (0xFF, 0xCC, 0x33)
FIRE_LO = (0xFF, 0xD2, 0x00)
FIRE_HI = (0xE8, 0x22, 0x1A)
WHITE = (255, 255, 255)


# ---- signed distances (negative inside) ----
def rbox(cx, cy, hx, hy, r):
    def f(x, y):
        qx = abs(x - cx) - hx + r
        qy = abs(y - cy) - hy + r
        return math.hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - r
    return f


def ring(cx, cy, r0, r1):
    return lambda x, y: abs(math.hypot(x - cx, y - cy) - (r0 + r1) / 2) - (r1 - r0) / 2


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
    return f


def grow(f, k):
    return lambda x, y: f(x, y) - k


def shift(f, dx, dy):
    return lambda x, y: f(x - dx, y - dy)


def inter(a, b):
    return lambda x, y: max(a(x, y), b(x, y))


def box(x0, y0, x1, y1):
    """Axis-aligned box with hard edges (used for clipping)."""
    return rbox((x0 + x1) / 2, (y0 + y1) / 2, (x1 - x0) / 2, (y1 - y0) / 2, 0)


def cov(d):
    return max(0.0, min(1.0, 0.5 - d))


class Canvas:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.px = [[0.0, 0.0, 0.0, 0.0] for _ in range(w * h)]  # premultiplied r,g,b,a (0..1)

    def paint(self, sdf, color, alpha=1.0):
        """color is an (r,g,b) tuple or a function (x, y) -> (r,g,b)."""
        w = self.w
        for j in range(self.h):
            for i in range(w):
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

    def shadow(self, sdf, alpha, blur):
        """Soft black drop shadow: coverage falls off over `blur` pixels instead of one."""
        for j in range(self.h):
            for i in range(self.w):
                c = max(0.0, min(1.0, 0.5 - sdf(i + 0.5, j + 0.5) / blur)) * alpha
                if c > 0:
                    p = self.px[j * self.w + i]
                    p[3] = c + p[3] * (1 - c)

    def erase(self, sdf):
        for j in range(self.h):
            for i in range(self.w):
                k = cov(sdf(i + 0.5, j + 0.5))
                if k > 0:
                    p = self.px[j * self.w + i]
                    for q in range(4):
                        p[q] *= 1 - k

    def save(self, name, bleed=None):
        """bleed: RGB given to fully transparent pixels so texture filtering never fringes."""
        raw = bytearray()
        for j in range(self.h):
            raw.append(0)
            for i in range(self.w):
                r, g, b, a = self.px[j * self.w + i]
                if a <= 1e-4:
                    raw += bytes(bleed + (0,)) if bleed else bytes(4)
                    continue
                raw += bytes([min(255, round(r / a * 255)), min(255, round(g / a * 255)),
                              min(255, round(b / a * 255)), min(255, round(a * 255))])
        write_png(OUT / name, bytes(raw), self.w, self.h)


def write_png(path, raw, w, h):
    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)
    png = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png)


def keycap(w, h, name):
    cv = Canvas(w, h)
    body = rbox(w / 2, (h - 5) / 2 + 1, w / 2 - 3, (h - 5) / 2 - 0.5, 14)
    cv.shadow(shift(body, 0, 3), 0.35, 2.2)
    cv.paint(body, OUTLINE)
    inner = grow(body, -4)
    cv.paint(inner, CREAM_LO)                              # bottom lip
    face = inter(inner, shift(inner, 0, -4))               # face sits proud; the lip shows below it
    cv.paint(face, CREAM_HI)                               # top bevel
    cv.paint(inter(face, shift(face, 0, 2.5)), CREAM)      # flat centre for text
    cv.save(name)


def mouse(name, part=None, move=False):
    cv = Canvas(64, 80)
    cx, cy = 32, 40
    hx, hy, r = (15, 22, 13) if move else (23, 35, 21)
    body = rbox(cx, cy, hx, hy, r)
    cv.shadow(shift(body, 0, 3), 0.35, 2.2)
    cv.paint(body, OUTLINE)
    inner = grow(body, -3.5)
    cv.paint(inner, CREAM_LO)
    cv.paint(inter(inner, shift(inner, 0, -3)), CREAM)
    top = cy - hy
    split = top + hy * 2 * 0.42
    regions = {
        "l": inter(inner, box(cx - hx - 1, top - 1, cx, split)),
        "r": inter(inner, box(cx, top - 1, cx + hx + 1, split)),
    }
    if part in regions:
        reg = regions[part]
        cv.paint(reg, ORANGE)
        cv.paint(inter(reg, shift(reg, 0, -2.5)), YELLOW)
    sw = 1.4 if move else 1.6
    cv.paint(inter(inner, box(cx - sw, top - 1, cx + sw, split + sw)), OUTLINE)
    cv.paint(inter(inner, box(cx - hx - 1, split - sw, cx + hx + 1, split + sw)), OUTLINE)
    if not move:
        wheel = rbox(cx, top + 14, 5.5, 9, 5.5)
        cv.paint(wheel, OUTLINE)
        wi = grow(wheel, -2.2)
        if part == "wheel":
            cv.paint(wi, ORANGE)
            cv.paint(inter(wi, shift(wi, 0, -2.5)), YELLOW)
        else:
            cv.paint(wi, CREAM)
    else:
        for pts in ([(32, 3), (43, 14), (21, 14)], [(32, 77), (43, 66), (21, 66)],
                    [(3, 40), (14, 29), (14, 51)], [(61, 40), (50, 29), (50, 51)]):
            a = polygon(pts, 1.5)
            cv.paint(a, OUTLINE)
            ai = grow(a, -3)
            cv.paint(ai, ORANGE)
            cv.paint(inter(ai, shift(ai, 0, -1.5)), YELLOW)
    cv.save(name)


def rings():
    c = 32
    cv = Canvas(64, 64)
    cv.paint(ring(c, c, 16, 30), WHITE)
    cv.save("ring.png", bleed=WHITE)
    cv = Canvas(64, 64)
    cv.paint(ring(c, c, 16, 30), NAVY, 0.72)
    cv.save("ring_bg.png", bleed=NAVY)
    steps = 16
    band = ring(c, c, 18.5, 27.5)
    for n in range(steps + 1):
        cv = Canvas(64, 64)
        cv.paint(ring(c, c, 15, 30), NAVY, 0.78)
        if n:
            sweep = n / steps * 2 * math.pi

            def arc(x, y, sweep=sweep, full=(n == steps)):
                d = band(x, y)
                if full:
                    return d
                t = math.atan2(x - c, -(y - c)) % (2 * math.pi)   # clockwise from 12 o'clock
                rr = max(math.hypot(x - c, y - c), 1.0)
                s = t * rr
                if t > math.pi + sweep / 2:
                    s -= 2 * math.pi * rr
                return max(d, -s, s - sweep * rr)

            def col(x, y):
                t = (math.atan2(x - c, -(y - c)) % (2 * math.pi)) / (2 * math.pi)
                return tuple(FIRE_LO[k] + (FIRE_HI[k] - FIRE_LO[k]) * t for k in range(3))
            cv.paint(arc, col)
        cv.save("ring_%02d.png" % n, bleed=NAVY)


def panel(w, h, r, border, name, glow):
    cv = Canvas(w, h)
    outer = rbox(w / 2, h / 2, w / 2, h / 2, r)
    inner = grow(outer, -border)
    cv.paint(outer, GOLD)
    cv.erase(inner)                       # so the translucent body is not tinted by the border colour
    cv.paint(inner, NAVY, 0.82)
    if glow:
        gh = 40
        clip = inter(inner, box(0, 0, w, gh))
        for j in range(gh):
            for i in range(w):
                a = cov(clip(i + 0.5, j + 0.5)) * 0.08 * (1 - j / gh)
                if a > 0:
                    p = cv.px[j * w + i]
                    for q in range(3):
                        p[q] += a
                    p[3] = min(1.0, p[3] + a)
        cv.paint(inter(inner, box(0, border, w, border + 1.5)), WHITE, 0.14)
    cv.save(name, bleed=NAVY)


def main():
    keycap(64, 64, "key.png")
    keycap(160, 64, "key_wide.png")
    mouse("mouse.png")
    mouse("mouse_lmb.png", "l")
    mouse("mouse_rmb.png", "r")
    mouse("mouse_wheel.png", "wheel")
    mouse("mouse_move.png", move=True)
    rings()
    panel(512, 320, 24, 4, "card.png", True)
    panel(256, 48, 24, 2, "chip.png", False)
    for p in sorted(OUT.glob("*.png")):
        print(p.name, p.stat().st_size)


if __name__ == "__main__":
    main()
