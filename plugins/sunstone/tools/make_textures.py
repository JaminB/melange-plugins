#!/usr/bin/env python3
"""Generate Sunstone's procedural textures into mod/postfx/: hdr/cloud.png, hdr/dirt.png, hdr/bluenoise.png and
lens/bluenoise.png.

All art is original and deterministic (fixed seeds): tiling value-noise clouds, soft discs and smudges for lens dirt,
and a void-and-cluster blue-noise tile. 8-bit greyscale PNGs, stdlib only.
"""
import math
import random
import struct
import zlib
from pathlib import Path

POSTFX = Path(__file__).resolve().parent.parent / "mod" / "postfx"


def write_png(path, width, height, pixels):
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        raw.extend(pixels[y * width:(y + 1) * width])

    def chunk(tag, data):
        body = tag + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
           + chunk(b"IEND", b""))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(png)


def smoothstep(a, b, x):
    t = max(0.0, min(1.0, (x - a) / (b - a)))
    return t * t * (3.0 - 2.0 * t)


def fade(t):
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)


def tiling_value_noise(size, cells, rng):
    lattice = [[rng.random() for _ in range(cells)] for _ in range(cells)]
    axis = []
    for p in range(size):
        g = p * cells / size
        i = int(g)
        axis.append((i, (i + 1) % cells, fade(g - i)))
    out = []
    for y in range(size):
        y0, y1, fy = axis[y]
        row0, row1 = lattice[y0], lattice[y1]
        for x in range(size):
            x0, x1, fx = axis[x]
            a = row0[x0] + (row0[x1] - row0[x0]) * fx
            b = row1[x0] + (row1[x1] - row1[x0]) * fx
            out.append(a + (b - a) * fy)
    return out


def make_cloud(size=256):
    rng = random.Random(20240601)
    total = [0.0] * (size * size)
    amp = 1.0
    for cells in (4, 8, 16, 32):
        layer = tiling_value_noise(size, cells, rng)
        for i, v in enumerate(layer):
            total[i] += v * amp
        amp *= 0.5
    lo, hi = min(total), max(total)
    span = hi - lo
    return bytes(int(smoothstep(0.2, 0.9, (v - lo) / span) * 255.0 + 0.5) for v in total)


def make_dirt(width=512, height=288):
    rng = random.Random(20240602)
    img = [0.0] * (width * height)

    def edge_point():
        while True:
            x, y = rng.random(), rng.random()
            r2 = (((x - 0.5) * 2.0) ** 2 + ((y - 0.5) * 2.0) ** 2) * 0.5
            if rng.random() < 0.12 + 0.88 * r2 * r2:
                return x * width, y * height

    def disc(cx, cy, radius, strength):
        reach = radius * 1.25
        for y in range(max(0, int(cy - reach)), min(height, int(cy + reach) + 1)):
            for x in range(max(0, int(cx - reach)), min(width, int(cx + reach) + 1)):
                t = math.hypot(x - cx, y - cy) / radius
                if t < 1.25:
                    body = 1.0 - smoothstep(0.55, 1.0, t)
                    rim = math.exp(-(((t - 0.88) / 0.07) ** 2))
                    img[y * width + x] += strength * (0.55 * body + 0.45 * rim)

    def smudge(cx, cy, a, b, angle, strength):
        ca, sa = math.cos(angle), math.sin(angle)
        reach = int(a * 3.0)
        for y in range(max(0, int(cy) - reach), min(height, int(cy) + reach + 1)):
            for x in range(max(0, int(cx) - reach), min(width, int(cx) + reach + 1)):
                dx, dy = x - cx, y - cy
                u = (dx * ca + dy * sa) / a
                w = (-dx * sa + dy * ca) / b
                img[y * width + x] += strength * math.exp(-0.5 * (u * u + w * w))

    for _ in range(26):
        cx, cy = edge_point()
        a = rng.uniform(15.0, 50.0)
        smudge(cx, cy, a, a * rng.uniform(0.2, 0.5), rng.uniform(0.0, math.pi), rng.uniform(0.04, 0.14))
    for _ in range(60):
        cx, cy = edge_point()
        disc(cx, cy, rng.uniform(5.0, 34.0), rng.uniform(0.05, 0.30))
    for _ in range(300):
        cx, cy = edge_point()
        disc(cx, cy, rng.uniform(1.0, 3.0), rng.uniform(0.1, 0.4))

    out = bytearray()
    for y in range(height):
        for x in range(width):
            r2 = (((x + 0.5) / width - 0.5) * 2.0) ** 2 + (((y + 0.5) / height - 0.5) * 2.0) ** 2
            v = img[y * width + x] * (0.4 + 0.6 * min(r2 * 0.5, 1.0))
            out.append(int(min(v, 1.0) * 255.0 + 0.5))
    return bytes(out)


def make_blue_noise(size=64, sigma=1.5, radius=5):
    # Void-and-cluster on a torus; the ranks become a uniform histogram of grey levels.
    rng = random.Random(20240603)
    n = size * size
    kernel = []
    for dy in range(-radius, radius + 1):
        for dx in range(-radius, radius + 1):
            kernel.append((dx, dy, math.exp(-(dx * dx + dy * dy) / (2.0 * sigma * sigma))))
    energy = [0.0] * n
    bits = [0] * n

    def set_bit(index, value):
        bits[index] = value
        sign = 1.0 if value else -1.0
        x, y = index % size, index // size
        for dx, dy, w in kernel:
            energy[((y + dy) % size) * size + (x + dx) % size] += sign * w

    def pick(want, largest):
        best, ties = None, []
        for i in range(n):
            if bits[i] != want:
                continue
            e = energy[i]
            if best is None or (e > best + 1e-9 if largest else e < best - 1e-9):
                best, ties = e, [i]
            elif abs(e - best) <= 1e-9:
                ties.append(i)
        return ties[0] if len(ties) == 1 else rng.choice(ties)

    for i in rng.sample(range(n), n // 10):
        set_bit(i, 1)
    for _ in range(2000):
        cluster = pick(1, True)
        set_bit(cluster, 0)
        void = pick(0, False)
        set_bit(void, 1)
        if void == cluster:
            break

    ones = sum(bits)
    rank = [0] * n
    saved_bits, saved_energy = bits[:], energy[:]
    for r in range(ones - 1, -1, -1):
        cluster = pick(1, True)
        rank[cluster] = r
        set_bit(cluster, 0)
    bits[:], energy[:] = saved_bits, saved_energy
    for r in range(ones, n):
        void = pick(0, False)
        rank[void] = r
        set_bit(void, 1)
    return bytes(r * 256 // n for r in rank)


def main():
    write_png(POSTFX / "hdr" / "cloud.png", 256, 256, make_cloud())
    write_png(POSTFX / "hdr" / "dirt.png", 512, 288, make_dirt())
    noise = make_blue_noise()
    write_png(POSTFX / "hdr" / "bluenoise.png", 64, 64, noise)
    write_png(POSTFX / "lens" / "bluenoise.png", 64, 64, noise)


if __name__ == "__main__":
    main()
