#!/usr/bin/env python3
"""Generate Kindjal's particle and decal sprites into mod/textures/: kj_smoke1..3, kj_wisp1..2, kj_bubble,
kj_puddle1..2, kj_spark, kj_glint, kj_drop (see README-sprites.md for what each one is for).

Every sprite is RGBA with RGB pure white on every pixel, including the transparent ones, so the tint the client applies
at draw time never fringes; the shape lives entirely in the alpha channel. Shapes are signed-distance fields or
analytic falloffs, bent with seeded value noise (fBm and domain warping) and turned into soft anti-aliased alpha, and
each sprite keeps a clear margin so the quad edge never shows. Fixed seeds and no clock, so the output is
deterministic. Original art made by this script, nothing from the game or any other image. Stdlib only.

    python make_sprites.py          write the PNGs into ../mod/textures/
    python make_sprites.py --check  regenerate in memory and compare byte for byte with the files on disk
"""
import math
import random
import struct
import sys
import zlib
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "mod" / "textures"


# ---- small helpers ----
def clamp01(v):
    return 0.0 if v < 0.0 else 1.0 if v > 1.0 else v


def smoothstep(e0, e1, x):
    """0 below e0, 1 above e1 (either order), smooth between."""
    if e0 == e1:
        return 0.0 if x < e0 else 1.0
    t = clamp01((x - e0) / (e1 - e0))
    return t * t * (3 - 2 * t)


def lerp(a, b, t):
    return a + (b - a) * t


class Noise:
    """Smooth value noise on a coarse lattice over the unit square, with optional fBm octaves (each doubles the
    frequency and halves the weight). at(u, v) takes u, v in 0..1 and returns 0..1."""

    def __init__(self, rng, cells, octaves=1):
        self.layers = []
        total = 0.0
        for o in range(octaves):
            c = cells * (2 ** o)
            w = 0.5 ** o
            grid = [[rng.random() for _ in range(c + 2)] for _ in range(c + 2)]
            self.layers.append((c, w, grid))
            total += w
        self.total = total

    def at(self, u, v):
        u = 0.0 if u < 0.0 else 0.99999 if u > 0.99999 else u
        v = 0.0 if v < 0.0 else 0.99999 if v > 0.99999 else v
        s = 0.0
        for c, w, g in self.layers:
            fx = u * c
            fy = v * c
            ix, iy = int(fx), int(fy)
            tx, ty = fx - ix, fy - iy
            tx = tx * tx * (3 - 2 * tx)
            ty = ty * ty * (3 - 2 * ty)
            a = g[iy][ix] + (g[iy][ix + 1] - g[iy][ix]) * tx
            b = g[iy + 1][ix] + (g[iy + 1][ix + 1] - g[iy + 1][ix]) * tx
            s += (a + (b - a) * ty) * w
        return s / self.total


def aa(d, width=1.0):
    """Coverage from a signed distance in pixels (negative inside): a smooth edge about `width` pixels wide."""
    return smoothstep(width * 0.5, -width * 0.5, d)


def to_bytes(alpha, size_w, size_h, peak=255):
    """Quantise a float alpha grid (0..1) to bytes and zero the outermost pixel ring."""
    out = bytearray(size_w * size_h)
    for y in range(size_h):
        for x in range(size_w):
            if x == 0 or y == 0 or x == size_w - 1 or y == size_h - 1:
                continue
            out[y * size_w + x] = int(round(clamp01(alpha[y * size_w + x]) * peak))
    return out


# ---- smoke puffs: 128x128 ----
def make_smoke(seed, blobs, squash=(1.0, 1.0), warp=0.22, peak=0.86):
    """A soft turbulent puff. A cluster of Gaussian blobs gives the silhouette; a domain warp bends it, slow
    billow noise and soft creases carve the density, and a radial window guarantees the sprite is empty at its border."""
    size = 128
    rng = random.Random(seed)
    wx = Noise(rng, 3, 2)
    wy = Noise(rng, 3, 2)
    billow = Noise(rng, 4, 3)
    fine = Noise(rng, 11, 2)
    alpha = [0.0] * (size * size)
    for y in range(size):
        for x in range(size):
            px = ((x + 0.5) / size * 2 - 1) / squash[0]
            py = ((y + 0.5) / size * 2 - 1) / squash[1]
            u0 = (x + 0.5) / size
            v0 = (y + 0.5) / size
            qx = px + (wx.at(u0, v0) - 0.5) * 2 * warp
            qy = py + (wy.at(u0, v0) - 0.5) * 2 * warp
            dens = 0.0
            for bx, by, br, bw in blobs:
                dd = ((qx - bx) ** 2 + (qy - by) ** 2) / (br * br * 1.7)
                dens += bw * math.exp(-dd * 1.0)
            u = (qx + 1) / 2
            v = (qy + 1) / 2
            # Slow billows carve the silhouette; a gentler ridged layer adds soft cauliflower creases.
            slow = billow.at(u, v)
            ridge = 1.0 - abs(2 * fine.at(u, v) - 1)
            dens *= 0.35 + 1.1 * slow * slow * (1.4 - 0.5 * slow) + 0.14 * (ridge - 0.5)
            a = smoothstep(0.08, 1.75, dens) ** 0.9
            r = math.hypot(px * squash[0], py * squash[1])
            window = 1.0 - smoothstep(0.62, 0.98, r)
            alpha[y * size + x] = a * window * peak
    return to_bytes(alpha, size, size), size, size


def smoke1():
    """Round and fat, a heavy cloud with a few shoulders."""
    return make_smoke(5101, [(0.0, 0.02, 0.46, 1.0), (-0.28, -0.12, 0.30, 0.7), (0.30, -0.08, 0.28, 0.65),
                             (0.05, 0.26, 0.30, 0.6), (-0.14, 0.24, 0.24, 0.5)])


def smoke2():
    """Lobed and wider than tall, like smoke spreading sideways along a ceiling or a wall."""
    return make_smoke(5202, [(-0.34, 0.06, 0.34, 0.85), (0.04, -0.06, 0.40, 1.0), (0.38, 0.08, 0.32, 0.8),
                             (-0.12, 0.26, 0.24, 0.5), (0.22, -0.26, 0.22, 0.5)], squash=(1.0, 0.86), warp=0.26)


def smoke3():
    """Taller, thinning towards the top: a column that has started to tear off."""
    return make_smoke(5303, [(0.0, 0.26, 0.40, 1.0), (-0.05, -0.02, 0.32, 0.8), (0.08, -0.28, 0.24, 0.6),
                             (-0.10, -0.46, 0.16, 0.4), (0.22, 0.12, 0.24, 0.5)], squash=(0.82, 1.0), warp=0.2,
                      peak=0.82)


# ---- wisps: 64x128 thin rising curls ----
def make_wisp(seed, curvature, turns_scale, lean=0.0):
    """A thin curl drawn as a tapered path. The path is built by turning a heading along its length (so it can
    really curl, not only wave), fitted into the sprite, then rendered as distance-to-polyline with a wispy edge.
    The bottom is the heavy end; it thins and fades towards the top, and fades in a little at the very bottom."""
    w, h = 64, 128
    rng = random.Random(seed)
    edge = Noise(rng, 5, 3)
    along = Noise(rng, 6, 2)
    steps = 120
    pts = []
    x = y = 0.0
    heading = -math.pi / 2 + lean  # straight up in image space
    for i in range(steps + 1):
        t = i / steps
        pts.append((x, y, t))
        heading += curvature(t) * turns_scale / steps
        x += math.cos(heading)
        y += math.sin(heading)
    # Fit the path into the sprite with room for its widest radius, bottom anchored, centred horizontally.
    pad = 9
    minx = min(p[0] for p in pts)
    maxx = max(p[0] for p in pts)
    miny = min(p[1] for p in pts)
    maxy = max(p[1] for p in pts)
    scale = min((w - 2 * pad) / max(1e-6, maxx - minx), (h - 2 * pad) / max(1e-6, maxy - miny))
    ox = w / 2 - (minx + maxx) / 2 * scale
    oy = h - pad - maxy * scale
    path = [(px * scale + ox, py * scale + oy, t) for px, py, t in pts]

    def radius(t):
        # Thickest a third of the way up, narrowing to a hair at both ends.
        return 1.2 + 4.2 * math.sin(math.pi * min(1.0, t * 0.85 + 0.05)) ** 0.8 * (1 - 0.55 * t)

    def intensity(t):
        return smoothstep(0.0, 0.12, t) * (1.0 - smoothstep(0.55, 1.0, t)) * 0.95 + 0.05 * (1 - t)

    alpha = [0.0] * (w * h)
    for yy in range(h):
        for xx in range(w):
            px, py = xx + 0.5, yy + 0.5
            best = 1e9
            bt = 0.0
            for i in range(len(path) - 1):
                ax, ay, ta = path[i]
                bx, by, tb = path[i + 1]
                ex, ey = bx - ax, by - ay
                ll = ex * ex + ey * ey or 1.0
                s = clamp01(((px - ax) * ex + (py - ay) * ey) / ll)
                d = math.hypot(px - (ax + ex * s), py - (ay + ey * s))
                if d < best:
                    best = d
                    bt = lerp(ta, tb, s)
            r = radius(bt)
            u, v = px / w, py / h
            best += (edge.at(u, v) - 0.5) * r * 1.4  # ragged, wispy edge
            if best > r * 2.2:
                continue
            core = math.exp(-((best / r) ** 2) * 1.6)
            streak = 0.72 + 0.5 * (along.at(u, v) - 0.5)
            alpha[yy * w + xx] = clamp01(core * intensity(bt) * streak) * 0.92
    # Window the borders so a curl that runs near the edge still dies out before it.
    for yy in range(h):
        for xx in range(w):
            edge_d = min(xx, yy, w - 1 - xx, h - 1 - yy)
            alpha[yy * w + xx] *= smoothstep(0, 5, edge_d)
    return to_bytes(alpha, w, h), w, h


def wisp1():
    """A lazy S-curve climbing, ending in a small hook."""
    return make_wisp(6101, lambda t: 2.6 * math.sin(t * math.tau) + 5.5 * smoothstep(0.72, 1.0, t) ** 1.3, 1.0)


def wisp2():
    """A mirror-ish drift that winds tighter and tighter into a curl near the top."""
    return make_wisp(6202, lambda t: -1.5 * math.sin(t * math.pi * 1.3) - 24.0 * smoothstep(0.35, 1.0, t) ** 2.0, 1.0,
                     lean=0.2)


# ---- bubble: 64x64 ----
def make_bubble():
    size = 64
    c = size / 2
    R = 26.5
    alpha = [0.0] * (size * size)
    for y in range(size):
        for x in range(size):
            dx, dy = x + 0.5 - c, y + 0.5 - c
            r = math.hypot(dx, dy)
            ang = math.atan2(dy, dx)
            ring_d = abs(r - R) - 1.2
            ring = aa(ring_d, 1.8)
            # Brighter on the lit upper-left and the opposite lower-right, like a thin film catching two lights.
            lit = 0.5 + 0.5 * math.cos(2 * (ang + 2.35))
            rim = ring * (0.45 + 0.4 * lit)
            # A faint fresnel veil inside: almost clear in the middle, denser towards the skin.
            veil = (r / R) ** 3 * 0.16 * aa(r - R, 1.4)
            # Specular dot up and to the left, and a dim one opposite.
            sx, sy = dx + 0.36 * R, dy + 0.42 * R
            spec = math.exp(-(sx * sx + sy * sy) / (2 * 2.4 ** 2))
            tx, ty = dx - 0.45 * R, dy - 0.40 * R
            spec2 = 0.45 * math.exp(-(tx * tx + ty * ty) / (2 * 1.7 ** 2))
            alpha[y * size + x] = max(rim, veil, spec * 1.1, spec2)
    return to_bytes(alpha, size, size), size, size


# ---- puddles: 128x128 ----
def make_puddle(seed, radius, stretch, wobble, lobes, satellites):
    """A flat noise-warped blob: soft edge, a brighter rim just inside it, a slightly mottled body."""
    size = 128
    rng = random.Random(seed)
    warp = Noise(rng, 4, 3)
    mottle = Noise(rng, 6, 2)
    harm = [(n, rng.uniform(0, math.tau), wobble * rng.uniform(0.5, 1.0) / (n ** 0.55)) for n in (2, 3, 4, 5)]
    parts = [(0.0, 0.0, 1.0)]
    for _ in range(lobes):
        a = rng.uniform(0, math.tau)
        parts.append((math.cos(a) * radius * 0.55, math.sin(a) * radius * 0.55 * stretch[1], rng.uniform(0.45, 0.62)))
    dots = []
    for _ in range(satellites):
        a = rng.uniform(0, math.tau)
        dist = radius * rng.uniform(1.12, 1.4)
        rr = rng.uniform(3.0, 6.5)
        # Keep every bead well inside the frame (the shape is centred), so none is cut off by the border.
        lim = size / 2 - rr - 6
        dots.append((max(-lim, min(lim, math.cos(a) * dist * stretch[0])),
                     max(-lim, min(lim, math.sin(a) * dist * stretch[1])), rr))
    cx = cy = size / 2
    alpha = [0.0] * (size * size)
    for y in range(size):
        for x in range(size):
            dx = (x + 0.5 - cx)
            dy = (y + 0.5 - cy)
            best = -1e9
            for ox, oy, rs in parts:
                ex = (dx - ox) / stretch[0]
                ey = (dy - oy) / stretch[1]
                d = math.hypot(ex, ey)
                a = math.atan2(ey, ex)
                rr = radius * rs * (1 + sum(m * math.sin(n * a + p) for n, p, m in harm))
                best = max(best, rr - d)
            for ox, oy, rr in dots:
                best = max(best, rr - math.hypot(dx - ox, dy - oy))
            u, v = (x + 0.5) / size, (y + 0.5) / size
            best += (warp.at(u, v) - 0.5) * 5.0
            if best < -2:
                continue
            cov = aa(-best, 2.6)
            inside = max(0.0, best)
            rim = math.exp(-((inside - 2.5) / 3.6) ** 2)
            body = 0.52 + 0.14 * (mottle.at(u, v) - 0.5) * 2 + 0.1 * min(1.0, inside / 18.0)
            a = lerp(body, 0.93, rim * 0.9)
            alpha[y * size + x] = clamp01(a) * cov * 0.96
    for y in range(size):
        for x in range(size):
            alpha[y * size + x] *= smoothstep(0, 4, min(x, y, size - 1 - x, size - 1 - y))
    return to_bytes(alpha, size, size), size, size


def puddle1():
    """Round and even, a settled spill."""
    return make_puddle(7101, 44, (1.0, 1.0), 0.16, 2, 3)


def puddle2():
    """Wider, lobed and ragged, a splash that has run out sideways with a few detached beads."""
    return make_puddle(7202, 38, (1.25, 0.9), 0.2, 3, 6)


# ---- spark: 64x64 ----
def make_spark():
    """A horizontal streak, a lens that thins to points, with a hot white core and a faint halo. Rotates at draw."""
    size = 64
    c = size / 2
    half = 29.0
    alpha = [0.0] * (size * size)
    for y in range(size):
        for x in range(size):
            dx, dy = x + 0.5 - c, y + 0.5 - c
            u = abs(dx) / half
            if u >= 1.0:
                continue
            taper = (1 - u) ** 1.6
            wid = 0.7 + 4.2 * taper
            body = math.exp(-(dy / wid) ** 2) * (0.45 + 0.55 * taper)
            core = math.exp(-(dy / (0.6 + 1.1 * taper)) ** 2) * (1 - u) ** 0.9
            halo = 0.28 * math.exp(-(dy / (wid * 2.6)) ** 2) * (1 - u) ** 2.2
            heat = math.exp(-(dx * dx + dy * dy) / (2 * 3.2 ** 2))
            alpha[y * size + x] = clamp01(max(body * 0.8, core, halo) + heat * 0.35)
    return to_bytes(alpha, size, size), size, size


# ---- glint: 64x64 ----
def make_glint():
    """A four-point star: concave astroid body with long thin tips, a soft glow at the centre."""
    size = 64
    c = size / 2
    R = 30.0
    alpha = [0.0] * (size * size)
    for y in range(size):
        for x in range(size):
            dx, dy = abs(x + 0.5 - c), abs(y + 0.5 - c)
            v = 1.0 - (math.sqrt(dx / R) + math.sqrt(dy / R))  # > 0 inside the astroid
            star = smoothstep(0.0, 0.5, v) ** 1.3 if v > 0 else 0.0
            # Extra thin hairlines along the axes make the tips needle sharp instead of blunt.
            hair_h = math.exp(-(dy / 0.9) ** 2) * (1 - min(1.0, dx / R)) ** 1.8
            hair_v = math.exp(-(dx / 0.9) ** 2) * (1 - min(1.0, dy / R)) ** 1.8
            glow = 0.55 * math.exp(-(dx * dx + dy * dy) / (2 * 4.6 ** 2))
            alpha[y * size + x] = clamp01(max(star, hair_h * 0.9, hair_v * 0.9) + glow)
    return to_bytes(alpha, size, size), size, size


# ---- drop: 64x64 ----
def make_drop():
    """A teardrop, point up. A bead with a tapering neck, a brighter skin, a specular dot and a dim bounce light."""
    size = 64
    cx = 32.0
    by = 40.0
    br = 16.0
    tip = 6.0
    alpha = [0.0] * (size * size)

    def sdf(px, py):
        d_circle = math.hypot(px - cx, py - by) - br
        # Tapered capsule from the bead centre up to the tip, radius br -> 0.6.
        vy = tip - by
        t = clamp01((py - by) / vy)
        rad = lerp(br * 0.92, 0.6, t ** 0.9)
        d_cone = math.hypot(px - cx, py - (by + vy * t)) - rad
        k = 4.0
        h = clamp01(0.5 + 0.5 * (d_cone - d_circle) / k)
        return lerp(d_cone, d_circle, h) - k * h * (1 - h)

    for y in range(size):
        for x in range(size):
            px, py = x + 0.5, y + 0.5
            d = sdf(px, py)
            cov = aa(d, 1.6)
            if cov <= 0:
                continue
            inside = max(0.0, -d)
            skin = math.exp(-(inside / 2.8) ** 2)
            body = 0.56 + 0.12 * smoothstep(0, 14, inside)
            a = lerp(body, 0.95, skin * 0.85)
            sx, sy = px - (cx - 5.5), py - (by - 6.0)
            spec = math.exp(-(sx * sx + sy * sy * 1.4) / (2 * 2.3 ** 2))
            bx_, by_ = px - (cx + 5.0), py - (by + 8.5)
            bounce = 0.3 * math.exp(-(bx_ * bx_ * 0.6 + by_ * by_ * 2.2) / (2 * 2.2 ** 2))
            alpha[y * size + x] = clamp01(max(a * cov, spec * cov * 1.15, bounce * cov))
    return to_bytes(alpha, size, size), size, size


SPRITES = {
    "kj_smoke1.png": smoke1,
    "kj_smoke2.png": smoke2,
    "kj_smoke3.png": smoke3,
    "kj_wisp1.png": wisp1,
    "kj_wisp2.png": wisp2,
    "kj_bubble.png": make_bubble,
    "kj_puddle1.png": puddle1,
    "kj_puddle2.png": puddle2,
    "kj_spark.png": make_spark,
    "kj_glint.png": make_glint,
    "kj_drop.png": make_drop,
}


def encode_png(alpha, width, height):
    """8-bit RGBA, RGB white everywhere, alpha as given. Returns the file bytes."""

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter type: none
        for x in range(width):
            raw += b"\xff\xff\xff" + bytes((alpha[y * width + x],))
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b""))


def build_all():
    out = {}
    for name, fn in SPRITES.items():
        alpha, w, h = fn()
        out[name] = encode_png(alpha, w, h)
    return out


def main():
    files = build_all()
    if "--check" in sys.argv[1:]:
        bad = 0
        for name, data in files.items():
            path = OUT / name
            if not path.is_file():
                print(f"MISSING {path}")
                bad += 1
            elif path.read_bytes() != data:
                print(f"DIFFERS {path}")
                bad += 1
        if bad:
            print(f"{bad} of {len(files)} sprites out of date; re-run make_sprites.py")
            sys.exit(1)
        print(f"ok: {len(files)} sprites match the generator")
        return
    OUT.mkdir(parents=True, exist_ok=True)
    for name, data in files.items():
        (OUT / name).write_bytes(data)
        print(f"wrote {OUT / name} ({len(data)} bytes)")


if __name__ == "__main__":
    main()
