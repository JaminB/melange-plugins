#!/usr/bin/env python3
"""Generate Bloodsand's lens splatter textures: splat1.png .. splat4.png into mod/textures/.

256x256 RGBA. RGB is pure white on every pixel, including the transparent ones, so the tint the mod applies never
fringes at the edges; the shape lives entirely in the alpha channel. Each splat is built from a signed-distance field
(a noise-warped main blot, tapered curving fingers, satellite droplets and drips with a bead at the end) that is
smooth-unioned, then turned into soft anti-aliased alpha. Pure code with fixed random seeds, so the output is
deterministic and nothing here comes from the game or any other image. Stdlib only.
"""
import math
import random
import struct
import zlib
from pathlib import Path

SIZE = 256
MARGIN = 6
PEAK = 235
BIG = -1.0e9


class Noise:
    """Smooth value noise on a coarse lattice, so the rim wobbles and the interior varies slowly."""

    def __init__(self, rng, cells):
        self.cells = cells
        self.grid = [[rng.random() for _ in range(cells + 2)] for _ in range(cells + 2)]

    def at(self, x, y):
        fx = x / SIZE * self.cells
        fy = y / SIZE * self.cells
        ix, iy = int(fx), int(fy)
        tx, ty = fx - ix, fy - iy
        tx = tx * tx * (3 - 2 * tx)
        ty = ty * ty * (3 - 2 * ty)
        g = self.grid
        a = g[iy][ix] + (g[iy][ix + 1] - g[iy][ix]) * tx
        b = g[iy + 1][ix] + (g[iy + 1][ix + 1] - g[iy + 1][ix]) * tx
        return a + (b - a) * ty


class Field:
    """Signed distance in pixels, positive inside the blood. Primitives are merged only inside their bounding box."""

    def __init__(self):
        self.f = [BIG] * (SIZE * SIZE)

    def _merge(self, x0, y0, x1, y1, fn, smooth):
        x0 = max(0, int(x0))
        y0 = max(0, int(y0))
        x1 = min(SIZE - 1, int(x1) + 1)
        y1 = min(SIZE - 1, int(y1) + 1)
        f = self.f
        k = smooth
        for y in range(y0, y1 + 1):
            row = y * SIZE
            for x in range(x0, x1 + 1):
                b = fn(x + 0.5, y + 0.5)
                a = f[row + x]
                if b < -k - 2:
                    continue
                if a <= BIG / 2 or k <= 0:
                    f[row + x] = a if a > b else b
                else:
                    h = max(k - abs(a - b), 0.0) / k
                    f[row + x] = (a if a > b else b) + h * h * k * 0.25

    def blot(self, cx, cy, radius, rng, wobble=0.22, stretch=(1.0, 1.0), smooth=0.0):
        """A radial blot whose radius is warped by a few random harmonics."""
        harm = [(n, rng.uniform(0, math.tau), wobble * rng.uniform(0.4, 1.0) / (n ** 0.5)) for n in (2, 3, 4, 5, 7, 9, 12)]
        ext = radius * (1 + wobble * 2.5) + 4

        def fn(x, y):
            dx = (x - cx) / stretch[0]
            dy = (y - cy) / stretch[1]
            d = math.hypot(dx, dy)
            a = math.atan2(dy, dx)
            r = radius * (1 + sum(m * math.sin(n * a + p) for n, p, m in harm))
            return r - d

        self._merge(cx - ext * stretch[0], cy - ext * stretch[1], cx + ext * stretch[0], cy + ext * stretch[1], fn, smooth)

    def disc(self, cx, cy, r, smooth=0.0):
        self._merge(cx - r - 3, cy - r - 3, cx + r + 3, cy + r + 3, lambda x, y: r - math.hypot(x - cx, y - cy), smooth)

    def capsule(self, p0, p1, r0, r1, smooth=0.0):
        """A tapered segment: radius r0 at p0 easing to r1 at p1."""
        (ax, ay), (bx, by) = p0, p1
        vx, vy = bx - ax, by - ay
        ll = vx * vx + vy * vy or 1.0
        pad = max(r0, r1) + 3

        def fn(x, y):
            t = ((x - ax) * vx + (y - ay) * vy) / ll
            t = 0.0 if t < 0 else 1.0 if t > 1 else t
            return r0 + (r1 - r0) * t - math.hypot(x - (ax + vx * t), y - (ay + vy * t))

        self._merge(min(ax, bx) - pad, min(ay, by) - pad, max(ax, bx) + pad, max(ay, by) + pad, fn, smooth)

    def finger(self, cx, cy, angle, start, length, width, rng, curl=0.35, smooth=5.0):
        """A streak leaving the blot: a few capsules along a gently curving path, thinning to a point."""
        steps = max(3, int(length / 9))
        x = cx + math.cos(angle) * start
        y = cy + math.sin(angle) * start
        a = angle
        seg = length / steps
        for i in range(steps):
            a += rng.uniform(-curl, curl) * 0.5
            nx, ny = x + math.cos(a) * seg, y + math.sin(a) * seg
            r0 = width * (1 - i / steps) + 0.4
            r1 = width * (1 - (i + 1) / steps) + 0.4
            self.capsule((x, y), (nx, ny), r0, r1, smooth)
            x, y = nx, ny
        # A small bead where the streak ends, as flung blood tends to pool at the tip.
        if width > 2.2 and rng.random() < 0.7:
            self.disc(x, y, width * rng.uniform(0.55, 0.9) + 0.6, 2.0)

    def drip(self, x, y, length, width, rng):
        """Runs straight down (+y in the image) from the blot, with a rounded bead at the end."""
        sway = rng.uniform(-3, 3)
        ex, ey = x + sway, y + length
        bead = width * rng.uniform(1.35, 1.7) + 1.0
        self.capsule((x, y), (ex, ey), width * 1.1, width * 0.55, 6.0)
        self.disc(ex, ey, bead, 4.0)
        # A thin neck just above the bead, so it reads as a drop that is still hanging on.
        self.capsule((ex, ey - length * 0.25), (ex, ey), width * 0.7, width * 0.5, 3.0)


def droplets(field, rng, cx, cy, count, rmin, rmax, size_lo, size_hi, direction=None, spread=math.pi, streak=0.0,
             power=1.0):
    """Scatter satellite droplets. Far ones are smaller; a streak value turns some into short radial smears."""
    placed = 0
    tries = 0
    while placed < count and tries < count * 20:
        tries += 1
        u = rng.random() ** power
        dist = rmin + (rmax - rmin) * u
        ang = (direction if direction is not None else rng.uniform(0, math.tau)) + rng.uniform(-spread, spread)
        x = cx + math.cos(ang) * dist
        y = cy + math.sin(ang) * dist
        if not (MARGIN + 8 < x < SIZE - MARGIN - 8 and MARGIN + 8 < y < SIZE - MARGIN - 8):
            continue
        fall = 1.0 - (dist - rmin) / max(1.0, rmax - rmin)
        r = size_lo + (size_hi - size_lo) * (rng.random() ** 2.2) * (0.35 + 0.65 * fall)
        if rng.random() < streak and r > 1.4:
            tail = r * rng.uniform(1.5, 3.5)
            self_x, self_y = x - math.cos(ang) * tail, y - math.sin(ang) * tail
            field.capsule((self_x, self_y), (x, y), r * 0.35, r, 0.0)
        else:
            field.disc(x, y, r)
        placed += 1


def render(field, seed):
    """Turn the signed distance into alpha: soft edge, a thinner rim and some slow variation inside."""
    rng = random.Random(seed)
    rough = Noise(rng, 22)
    thin = Noise(rng, 5)
    fine = Noise(rng, 60)
    alpha = bytearray(SIZE * SIZE)
    f = field.f
    for y in range(SIZE):
        for x in range(SIZE):
            d = f[y * SIZE + x]
            if d < -3:
                continue
            # Wobble the edge a little so it is not a perfect curve, then soften it over about two pixels.
            d += (rough.at(x, y) - 0.5) * 1.6
            cov = d / 1.6 + 0.5
            if cov <= 0:
                continue
            cov = 1.0 if cov >= 1 else cov * cov * (3 - 2 * cov)
            rim = 0.72 + 0.28 * min(1.0, max(0.0, d) / 7.0)
            body = 0.80 + 0.20 * thin.at(x, y) - 0.10 * fine.at(x, y)
            a = PEAK * rim * min(1.0, body + 0.1)
            # Small things stay a touch thinner, like tiny beads that have not gathered much blood.
            a *= 0.8 + 0.2 * min(1.0, max(0.0, d) / 2.5)
            alpha[y * SIZE + x] = int(round(min(PEAK, a * cov)))
    # Keep a clear margin so the quad edge never shows.
    for y in range(SIZE):
        for x in range(SIZE):
            if x < MARGIN or y < MARGIN or x >= SIZE - MARGIN or y >= SIZE - MARGIN:
                alpha[y * SIZE + x] = 0
    return alpha


def splat_round():
    """Dense and round: a heavy centre, short fat fingers all round, fine spray, two short drips."""
    rng = random.Random(1101)
    fl = Field()
    fl.blot(128, 118, 52, rng, wobble=0.2, smooth=0)
    for _ in range(3):
        a = rng.uniform(0, math.tau)
        fl.disc(128 + math.cos(a) * 30, 118 + math.sin(a) * 30, rng.uniform(16, 24), 10.0)
    for i in range(18):
        a = i / 18 * math.tau + rng.uniform(-0.12, 0.12)
        fl.finger(128, 118, a, 36, rng.uniform(20, 62), rng.uniform(2.5, 6.0), rng)
    droplets(fl, rng, 128, 118, 55, 70, 112, 1.0, 5.2, power=0.8, streak=0.35)
    fl.drip(104, 150, 46, 3.4, rng)
    fl.drip(152, 158, 28, 2.8, rng)
    return fl


def splat_directional():
    """Thrown sideways: a compact head on the left, long streaks flung to the right, elongated droplets."""
    rng = random.Random(2202)
    fl = Field()
    fl.blot(82, 128, 34, rng, wobble=0.24, stretch=(1.45, 0.85))
    fl.disc(104, 122, 17, 8.0)
    fl.disc(62, 134, 14, 8.0)
    for _ in range(17):
        a = rng.gauss(0.0, 0.34)
        a = max(-0.95, min(0.95, a))
        fl.finger(92, 128 + rng.uniform(-12, 12), a, 12, rng.uniform(55, 140), rng.uniform(1.8, 5.0), rng, curl=0.2)
    for _ in range(5):
        a = rng.uniform(math.pi * 0.6, math.pi * 1.4)
        fl.finger(82, 128, a, 18, rng.uniform(10, 24), rng.uniform(2.2, 4.0), rng)
    droplets(fl, rng, 100, 128, 70, 40, 140, 0.9, 4.6, direction=0.0, spread=0.6, streak=0.7, power=0.9)
    return fl


def splat_spray():
    """Mostly droplets: a small ragged core and a wide burst of fine drops and radial smears."""
    rng = random.Random(3303)
    fl = Field()
    fl.blot(128, 128, 17, rng, wobble=0.3)
    for i in range(11):
        a = i / 11 * math.tau + rng.uniform(-0.2, 0.2)
        fl.finger(128, 128, a, 12, rng.uniform(18, 46), rng.uniform(1.6, 3.2), rng, curl=0.5)
    droplets(fl, rng, 128, 128, 170, 20, 118, 0.8, 5.0, power=1.0, streak=0.45)
    droplets(fl, rng, 128, 128, 28, 30, 100, 3.0, 6.5, power=1.2)
    return fl


def splat_drips():
    """Heavy drips: a broad blot near the top with five drips of different lengths running down."""
    rng = random.Random(4404)
    fl = Field()
    fl.blot(128, 78, 46, rng, wobble=0.2, stretch=(1.25, 0.9))
    fl.disc(100, 90, 20, 10.0)
    fl.disc(156, 84, 22, 10.0)
    for i in range(9):
        a = i / 9 * math.tau + rng.uniform(-0.2, 0.2)
        fl.finger(128, 78, a, 40, rng.uniform(14, 40), rng.uniform(2.2, 4.5), rng)
    for x, length, w in ((82, 70, 4.2), (106, 128, 3.4), (128, 92, 5.0), (150, 150, 3.0), (174, 58, 3.8)):
        fl.drip(x, 88, length, w, rng)
    droplets(fl, rng, 128, 78, 40, 62, 105, 1.0, 4.0, power=0.9, streak=0.2)
    return fl


SPLATS = {
    "splat1.png": (splat_round, 11),
    "splat2.png": (splat_directional, 22),
    "splat3.png": (splat_spray, 33),
    "splat4.png": (splat_drips, 44),
}


def write_png(path, alpha, width, height):
    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter type: none
        for x in range(width):
            raw += b"\xff\xff\xff" + bytes((alpha[y * width + x],))
    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)  # 8-bit RGBA
    idat = zlib.compress(bytes(raw), 9)
    with open(path, "wb") as f:
        f.write(sig)
        f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", idat))
        f.write(chunk(b"IEND", b""))


def main():
    out_dir = Path(__file__).resolve().parent.parent / "mod" / "textures"
    out_dir.mkdir(parents=True, exist_ok=True)
    for name, (build, seed) in SPLATS.items():
        alpha = render(build(), seed)
        write_png(out_dir / name, alpha, SIZE, SIZE)
        print(f"wrote {out_dir / name}")


if __name__ == "__main__":
    main()
