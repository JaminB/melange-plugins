#!/usr/bin/env python3
"""Generate the Grave Spade's particle sprites into mod/textures/: kj_dirt1..4 (soil clods), kj_dust1..2 (dust puffs),
kj_stonechip (angular rock chip), kj_bloodmist (blood spray mist) and kj_gore_chunk (a wet chunk of meat).

Same conventions as make_sprites.py (it supplies the noise, easing and anti-aliasing helpers): RGBA, a clear margin so
the quad edge never shows, fixed seeds and no clock, so the output is deterministic, stdlib only, original art.
The difference is that the solid pieces (clods, chip, chunk) carry grey shading in RGB, so the tint the client applies
at draw time (soil brown, granite grey, blood red) keeps its lit side, shadow side and grain. The soft ones (dust,
mist) are pure white like the smoke sprites and take their colour entirely from the tint.

    python make_dig_sprites.py          write the PNGs into ../mod/textures/
    python make_dig_sprites.py --check  regenerate in memory and compare with the files on disk (decoded pixels)
"""
import math
import random
import struct
import sys
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _pngcmp  # noqa: E402
from make_sprites import Noise, aa, clamp01, lerp, smoothstep  # noqa: E402

OUT = Path(__file__).resolve().parent.parent / "mod" / "textures"
LIGHT = (-0.55, -0.62, 0.56)  # towards the light: upper left, out of the screen (image y points down)


def shade(nx, ny, nz, ambient=0.34):
    """Lambert grey for a unit normal, with a little wrap so the dark side is never black."""
    ln = math.sqrt(sum(c * c for c in LIGHT))
    d = (nx * LIGHT[0] + ny * LIGHT[1] + nz * LIGHT[2]) / ln
    return clamp01(ambient + (1 - ambient) * (0.5 + 0.5 * d) ** 1.4)


def finish(rgb, alpha, w, h):
    """Zero the outer ring and pack to RGBA bytes. rgb is a list of 0..1 greys (None: white)."""
    out = bytearray(w * h * 4)
    for y in range(h):
        for x in range(w):
            i = y * w + x
            a = 0.0 if x == 0 or y == 0 or x == w - 1 or y == h - 1 else alpha[i]
            g = 255 if rgb is None else int(round(clamp01(rgb[i]) * 255))
            out[i * 4:i * 4 + 4] = bytes((g, g, g, int(round(clamp01(a) * 255))))
    return bytes(out), w, h


# ---- soil clods: 64x64 ----
def make_clod(seed, lobes, rough, elong, pebbles):
    """A lumpy clod. The outline is a polar curve bent by noise; the body is a dome plus bumps, shaded from its
    gradient; grain speckle, dark crevices, and a few embedded pebbles that catch more light."""
    size = 64
    rng = random.Random(seed)
    edge = Noise(rng, 5, 2)
    bump = Noise(rng, 6, 3)
    grain = Noise(rng, 22, 1)
    phase = [rng.uniform(0, math.tau) for _ in range(3)]
    peb = [(rng.uniform(-0.45, 0.45), rng.uniform(-0.45, 0.45), rng.uniform(0.09, 0.17)) for _ in range(pebbles)]
    R = 25.0 / max(1.0, elong * 0.95)
    c = size / 2
    rot = rng.uniform(0, math.tau)
    ca, sa = math.cos(rot), math.sin(rot)
    alpha = [0.0] * (size * size)
    grey = [0.0] * (size * size)

    def height(a, b):
        return max(0.0, 1 - (a * a + b * b)) ** 0.5 * 0.9 + 0.35 * (bump.at(0.5 + a * 0.4, 0.5 + b * 0.4) - 0.5)

    for y in range(size):
        for x in range(size):
            dx, dy = (x + 0.5 - c), (y + 0.5 - c)
            ex, ey = (dx * ca + dy * sa) / elong, (-dx * sa + dy * ca)
            th = math.atan2(ey, ex)
            rr = 1.0 + 0.16 * math.sin(lobes * th + phase[0]) + 0.08 * math.sin((lobes + 2) * th + phase[1])
            rr += rough * (edge.at((x + 0.5) / size, (y + 0.5) / size) - 0.5) * 2
            cov = aa(math.hypot(ex, ey) - R * rr, 1.1)
            if cov <= 0:
                continue
            u, v = ex / (R * rr), ey / (R * rr)
            n = bump.at((x + 0.5) / size, (y + 0.5) / size) - 0.5
            e = 0.04
            gx = (height(u + e, v) - height(u - e, v)) / (2 * e)
            gy = (height(u, v + e) - height(u, v - e)) / (2 * e)
            nl = math.sqrt(gx * gx + gy * gy + 1)
            g = shade(-gx / nl, -gy / nl, 1 / nl)
            g *= 0.8 + 0.4 * grain.at((x + 0.5) / size, (y + 0.5) / size)
            g *= 1 - 0.5 * smoothstep(0.55, 1.0, math.hypot(u, v)) ** 1.5  # darker towards the rim
            if n < -0.18:
                g *= 0.7  # crevice
            for pxx, pyy, pr in peb:
                dd = math.hypot(u - pxx, v - pyy)
                if dd < pr:
                    lit = 0.6 + 0.4 * shade(-(u - pxx) / pr, -(v - pyy) / pr, 0.6)
                    g = lerp(g, 0.55 + 0.45 * (1 - dd / pr) ** 0.8 * lit, 0.8)
            alpha[y * size + x] = cov
            grey[y * size + x] = g
    return finish(grey, alpha, size, size)


# ---- dust puffs: 128x128 ----
def make_dust(seed, wide, clumps):
    """A thin, dry puff, lighter and more ragged than the acid smoke: shoulders of density broken by fine noise, so it
    reads as grains hanging in the air rather than a cloud."""
    size = 128
    rng = random.Random(seed)
    wx, wy = Noise(rng, 3, 2), Noise(rng, 3, 2)
    big = Noise(rng, 4, 3)
    fine = Noise(rng, 16, 2)
    blobs = [(rng.uniform(-0.4, 0.4) * wide, rng.uniform(-0.3, 0.3), rng.uniform(0.2, 0.34)) for _ in range(clumps)]
    alpha = [0.0] * (size * size)
    for y in range(size):
        for x in range(size):
            u0, v0 = (x + 0.5) / size, (y + 0.5) / size
            px = ((x + 0.5) / size * 2 - 1) / wide
            py = (y + 0.5) / size * 2 - 1
            qx = px + (wx.at(u0, v0) - 0.5) * 0.5
            qy = py + (wy.at(u0, v0) - 0.5) * 0.5
            d = 0.0
            for bx, by, br in blobs:
                d += math.exp(-((qx - bx) ** 2 + (qy - by) ** 2) / (br * br * 1.5))
            d *= 0.45 + 0.9 * big.at((qx + 1) / 2, (qy + 1) / 2)
            d *= 0.15 + 1.3 * fine.at(u0, v0) ** 1.3
            a = smoothstep(0.12, 1.3, d) ** 1.1 * 0.55
            a *= 1 - smoothstep(0.55, 0.97, math.hypot(px * wide, py))
            alpha[y * size + x] = a
    return finish(None, alpha, size, size)


# ---- stone chip: 64x64 ----
def make_stonechip():
    """A flaked rock shard: a convex polygon, each facet its own flat grey, lighter bevelled edges where facets
    meet, and fine grain."""
    size = 64
    rng = random.Random(7707)
    c = size / 2
    n = 7
    verts = []
    for i in range(n):
        a = i / n * math.tau + rng.uniform(-0.2, 0.2)
        r = rng.uniform(0.62, 1.0) * 24
        verts.append((c + math.cos(a) * r * 1.15, c + math.sin(a) * r * 0.85))
    hub = (c + 2.0, c - 1.0)
    fac = [rng.uniform(0.35, 1.0) for _ in range(n)]
    grain = Noise(rng, 18, 1)
    area = sum(verts[i][0] * verts[(i + 1) % n][1] - verts[(i + 1) % n][0] * verts[i][1] for i in range(n))
    sgn = 1.0 if area > 0 else -1.0
    edges = []
    for i in range(n):
        a, b = verts[i], verts[(i + 1) % n]
        ln = math.hypot(b[0] - a[0], b[1] - a[1])
        edges.append((a, b, ln))
    alpha = [0.0] * (size * size)
    grey = [0.0] * (size * size)
    for y in range(size):
        for x in range(size):
            px, py = x + 0.5, y + 0.5
            outside = -1e9  # signed distance to the (convex) polygon: max of the half-plane distances
            bevel = 1e9
            for a, b, ln in edges:
                ex, ey = b[0] - a[0], b[1] - a[1]
                dd = sgn * ((px - a[0]) * ey - (py - a[1]) * ex) / ln
                outside = max(outside, dd)
                bevel = min(bevel, abs(dd))
            cov = aa(outside, 1.0)
            if cov <= 0:
                continue
            ang = math.atan2(py - hub[1], px - hub[0])
            facet = int(((ang + math.pi) / math.tau) * n) % n
            g = (0.3 + 0.7 * fac[facet]) * (0.85 + 0.3 * grain.at(px / size, py / size))
            g = lerp(g, min(1.0, g + 0.35), 1 - smoothstep(0.0, 2.6, bevel))  # lit bevel
            alpha[y * size + x] = cov
            grey[y * size + x] = g
    return finish(grey, alpha, size, size)


# ---- blood mist: 128x128 ----
def make_bloodmist():
    """A fine spray: many tiny droplets in a loose fan over a faint haze. Pure white, tinted red at draw."""
    size = 128
    rng = random.Random(8808)
    haze = Noise(rng, 4, 3)
    alpha = [0.0] * (size * size)
    c = size / 2
    for y in range(size):
        for x in range(size):
            r = math.hypot(x + 0.5 - c, y + 0.5 - c) / 60
            alpha[y * size + x] = 0.22 * haze.at((x + 0.5) / size, (y + 0.5) / size) ** 1.4 * math.exp(-r * r * 3.2)
    for _ in range(170):
        r = abs(rng.gauss(0, 0.34))
        a = rng.uniform(0, math.tau)
        dx_, dy_ = c + math.cos(a) * r * 56, c + math.sin(a) * r * 56 * 0.9
        rad, pk = rng.uniform(0.9, 3.4), rng.uniform(0.5, 1.0)
        for y in range(max(1, int(dy_ - rad - 2)), min(size - 1, int(dy_ + rad + 2))):
            for x in range(max(1, int(dx_ - rad - 2)), min(size - 1, int(dx_ + rad + 2))):
                v = aa(math.hypot(x + 0.5 - dx_, y + 0.5 - dy_) - rad, 1.0) * pk
                i = y * size + x
                alpha[i] = max(alpha[i], v)
    for y in range(size):
        for x in range(size):
            r = math.hypot(x + 0.5 - c, y + 0.5 - c) / 62
            alpha[y * size + x] *= 1 - smoothstep(0.7, 1.0, r)
    return finish(None, alpha, size, size)


# ---- gore chunk: 64x64 ----
def make_gore_chunk():
    """A wet lump of meat: lumpy blob, fibre striations along one diagonal, a darker underside and a hard specular
    highlight (the wetness). Grey, tinted deep red at draw."""
    size = 64
    rng = random.Random(9909)
    edge = Noise(rng, 5, 2)
    fibre = Noise(rng, 9, 2)
    bump = Noise(rng, 5, 3)
    c = size / 2
    R = 24.0
    alpha = [0.0] * (size * size)
    grey = [0.0] * (size * size)
    ca, sa = math.cos(0.6), math.sin(0.6)
    half = (LIGHT[0], LIGHT[1], LIGHT[2] + 1.0)
    hn = math.sqrt(sum(k * k for k in half))
    for y in range(size):
        for x in range(size):
            dx, dy = x + 0.5 - c, y + 0.5 - c
            ex, ey = (dx * ca + dy * sa) / 1.18, (-dx * sa + dy * ca)
            th = math.atan2(ey, ex)
            rr = 1 + 0.17 * math.sin(3 * th + 1.1) + 0.1 * math.sin(5 * th + 0.4)
            rr += 0.28 * (edge.at((x + 0.5) / size, (y + 0.5) / size) - 0.5)
            cov = aa(math.hypot(ex, ey) - R * rr, 1.1)
            if cov <= 0:
                continue
            u, v = ex / (R * rr), ey / (R * rr)
            d2 = u * u + v * v
            nz = math.sqrt(max(0.02, 1 - d2))
            nx = u + 0.25 * (bump.at((x + 0.5) / size, (y + 0.5) / size) - 0.5)
            ny = v + 0.25 * (bump.at((x + 9.5) / size, (y + 3.5) / size) - 0.5)
            nl = math.sqrt(nx * nx + ny * ny + nz * nz)
            nx, ny, nz = nx / nl, ny / nl, nz / nl
            g = shade(nx, ny, nz, 0.3) * 0.8
            stripe = 0.5 + 0.5 * math.sin((u * 0.8 + v * 0.6) * 22 + fibre.at((x + 0.5) / size, (y + 0.5) / size) * 7)
            g *= 0.78 + 0.34 * stripe
            hl = max(0.0, (nx * half[0] + ny * half[1] + nz * half[2]) / hn)
            g += 0.85 * hl ** 38 + 0.25 * hl ** 10
            g *= 1 - 0.35 * smoothstep(0.6, 1.0, math.sqrt(d2))
            alpha[y * size + x] = cov
            grey[y * size + x] = g
    return finish(grey, alpha, size, size)


SPRITES = {
    "kj_dirt1.png": lambda: make_clod(4101, 3, 0.06, 1.15, 2),
    "kj_dirt2.png": lambda: make_clod(4202, 4, 0.10, 1.35, 3),
    "kj_dirt3.png": lambda: make_clod(4303, 5, 0.08, 1.0, 1),
    "kj_dirt4.png": lambda: make_clod(4404, 3, 0.13, 1.5, 4),
    "kj_dust1.png": lambda: make_dust(6101, 1.0, 6),
    "kj_dust2.png": lambda: make_dust(6202, 1.25, 7),
    "kj_stonechip.png": make_stonechip,
    "kj_bloodmist.png": make_bloodmist,
    "kj_gore_chunk.png": make_gore_chunk,
}


def encode_png(rgba, width, height):
    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    raw = bytearray()
    for y in range(height):
        raw.append(0)
        raw += rgba[y * width * 4:(y + 1) * width * 4]
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b""))


def build_all():
    return {name: encode_png(*fn()) for name, fn in SPRITES.items()}


def main():
    files = build_all()
    if "--check" in sys.argv[1:]:
        bad = 0
        for name, data in files.items():
            path = OUT / name
            if not path.is_file():
                print(f"MISSING {path}")
                bad += 1
            elif not _pngcmp.same(path.read_bytes(), data, path.name):
                print(f"DIFFERS {path}")
                bad += 1
        if bad:
            print(f"{bad} of {len(files)} sprites out of date; re-run make_dig_sprites.py")
            sys.exit(1)
        print(f"ok: {len(files)} sprites match the generator")
        return
    OUT.mkdir(parents=True, exist_ok=True)
    for name, data in files.items():
        (OUT / name).write_bytes(data)
        print(f"wrote {OUT / name} ({len(data)} bytes)")


if __name__ == "__main__":
    main()
