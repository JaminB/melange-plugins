#!/usr/bin/env python3
"""Generate Sunstone's shared material detail maps: mod/assets/detail/materials.png.

A development tool, not part of the plugin. Eight original tileable 256x256 layers, made from scratch here from
seeded noise (no game or third-party pixels), stacked as a vertical strip (layer 0 at the top, 256x2048) that
Melange loads as one GL_TEXTURE_2D_ARRAY (wum.draw.texture(..., {wrap = "repeat", layers = 8})). The material
snippets sample it through MatMap / MatMapWorld (tools/materials/_common.glsl); tools/materials/README.md lists the
layers and the scales they are made for.

  layer 0 grain    fine grain and pores (plastic, painted and skin-like matte)
  layer 1 wood     wood grain: rings along u with pores
  layer 2 brushed  brushed metal along u, with scratches at every angle
  layer 3 stone    stone / concrete: pitted, veined, mottled
  layer 4 weave    woven fabric: plain weave, 16 threads a tile, fibre noise
  layer 5 bumps    leather / rubber / organic: pebbled cells with creases
  layer 6 wear     chips, scratches and scuffs as a wear order (A: worn where A > 1 - wear)
  layer 7 bark     bark fissures along v and a crack network (foliage, bark, dried and cracked surfaces)

Channels (RGBA8, every channel 0.5 = neutral, which is also what Melange's unbound sampler reads):
  R, G  tangent-space normal x, y (x along +u, y along +v, i.e. down the PNG: Melange uploads the PNG's top row at
        v = 0); z = sqrt(1 - x^2 - y^2) is rebuilt in the shader
  B     height: 0.5 the surface, below it cavities (pores, grooves, pits), above it ridges
  A     a variation about 0.5: roughness (+ rougher) on grain, brushed and bumps; albedo (+ lighter) on wood, stone,
        weave and bark; the wear order on wear

Mips: Melange builds them by plain averaging of the stored bytes. Every height field here is periodic, so the
averaged normal of a whole tile is flat (R, G = 0.5) and the coarse mips flatten the normal: desired, detail goes
away with distance instead of sparkling. The slopes are kept moderate (|xy| about 0.3 to 0.55 at the 98th
percentile) so the plainly averaged mips stay near the true filtered normal.

    python tools/make_detail_maps.py                    # write mod/assets/detail/materials.png
    python tools/make_detail_maps.py --preview x.png    # also write a contact sheet (lit, normal, B, A, a mip)
    python tools/make_detail_maps.py --check            # exit 1 when the committed PNG differs from a fresh build

Needs numpy and Pillow. Deterministic: the same seed gives the same bytes.
"""
import argparse
import io
import sys
from pathlib import Path

import numpy as np
from PIL import Image

PLUGIN = Path(__file__).resolve().parent.parent
OUT = PLUGIN / "mod" / "assets" / "detail" / "materials.png"
N = 256
SEED = 2306
LAYERS = ["grain", "wood", "brushed", "stone", "weave", "bumps", "wear", "bark"]
# The 98th percentile of the normal's |xy| each layer is scaled to (moderate: mips stay near-correct).
SLOPE = {"grain": 0.30, "wood": 0.35, "brushed": 0.38, "stone": 0.45, "weave": 0.55, "bumps": 0.45, "wear": 0.50,
         "bark": 0.50}

# Frequencies in cycles per tile, x along the columns (u), y along the rows (v).
_F = np.fft.fftfreq(N) * N
KX, KY = np.meshgrid(_F, _F)
YY, XX = np.mgrid[0:N, 0:N].astype(np.float64)


def rng(*k):
    return np.random.default_rng([SEED, *k])


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def band(r, lo, hi, slope=1.0, sx=1.0, sy=1.0):
    """Periodic Gaussian noise, std 1, with its spectrum between lo and hi cycles a tile falling as f^-slope.
    sx > 1 shortens the reach of the x frequencies, so the pattern stretches along x (streaks along u); sy likewise."""
    k = np.hypot(KX * sx, KY * sy)
    w = np.where(k > 0, k, 1.0) ** (-slope)
    w *= (1.0 - np.exp(-(k / lo) ** 4)) * np.exp(-(k / hi) ** 4)
    w[0, 0] = 0.0
    z = np.real(np.fft.ifft2(np.fft.fft2(r.standard_normal((N, N))) * w))
    return z / (z.std() + 1e-12)


def sample(img, x, y):
    """Bilinear sample of a periodic field at pixel coordinates (x along columns), wrapping."""
    x0 = np.floor(x).astype(int)
    y0 = np.floor(y).astype(int)
    fx, fy = x - x0, y - y0
    x0 %= N
    y0 %= N
    x1, y1 = (x0 + 1) % N, (y0 + 1) % N
    return ((img[y0, x0] * (1 - fx) + img[y0, x1] * fx) * (1 - fy)
            + (img[y1, x0] * (1 - fx) + img[y1, x1] * fx) * fy)


def splat_segments(r, count, length, depth, width, angle=None, curve=0.0):
    """Wrapped anti-aliased line segments (scratches): the max of Gaussian profiles across each, fading at the ends.
    Returns a 0..1 mask scaled by each segment's depth."""
    out = np.zeros((N, N))
    for _ in range(count):
        L = r.uniform(*length)
        a = r.uniform(0, np.pi) if angle is None else angle + r.normal(0, 0.06)
        d = r.uniform(*depth)
        s = r.uniform(*width)
        bend = r.normal(0, curve)
        cx, cy = r.uniform(0, N, 2)
        t = np.arange(-L / 2, L / 2, 0.35)
        px = cx + np.cos(a) * t - np.sin(a) * bend * (t / L) ** 2 * L
        py = cy + np.sin(a) * t + np.cos(a) * bend * (t / L) ** 2 * L
        amp = d * np.clip(1.0 - np.abs(t) / (L / 2), 0, 1) ** 0.35
        rad = int(np.ceil(3 * s))
        for oy in range(-rad, rad + 1):
            for ox in range(-rad, rad + 1):
                ix = np.floor(px).astype(int) + ox
                iy = np.floor(py).astype(int) + oy
                dist2 = (ix + 0.5 - px) ** 2 + (iy + 0.5 - py) ** 2
                v = amp * np.exp(-dist2 / (2 * s * s))
                np.maximum.at(out, (iy % N, ix % N), v)
    return out


def splat_discs(r, count, radius, depth, profile="pit"):
    """Wrapped small round dents: 'pit' a smooth bowl, 'crater' a bowl with a slight rim. A 0..1-ish mask."""
    out = np.zeros((N, N))
    for _ in range(count):
        rad = r.uniform(*radius)
        d = r.uniform(*depth)
        cx, cy = r.uniform(0, N, 2)
        R = int(np.ceil(rad * 1.6)) + 1
        ys, xs = np.mgrid[-R:R + 1, -R:R + 1]
        ix, iy = np.floor(cx).astype(int) + xs, np.floor(cy).astype(int) + ys
        q = np.hypot(ix + 0.5 - cx, iy + 0.5 - cy) / rad
        if profile == "crater":
            v = d * (np.clip(1 - q * q, 0, None) ** 1.5 - 0.25 * np.exp(-((q - 1.15) / 0.2) ** 2))
        else:
            v = d * np.clip(1 - q * q, 0, None) ** 2
        np.add.at(out, (iy % N, ix % N), v)
    return out


def worley(r, count, warp=None):
    """Periodic cellular noise from count jittered points: F1, F2 (pixels) and the nearest point's index."""
    pts = r.uniform(0, N, (count, 2))
    x, y = XX, YY
    if warp is not None:
        x, y = XX + warp[0], YY + warp[1]
    best1 = np.full((N, N), 1e9)
    best2 = np.full((N, N), 1e9)
    idx = np.zeros((N, N), int)
    for i, (px, py) in enumerate(pts):
        dx = (x - px + N / 2) % N - N / 2
        dy = (y - py + N / 2) % N - N / 2
        d = np.hypot(dx, dy)
        closer = d < best1
        best2 = np.where(closer, best1, np.minimum(best2, d))
        best1 = np.where(closer, d, best1)
        idx = np.where(closer, i, idx)
    return best1, best2, idx


# ---------------------------------------------------------------- the layers: (height in arbitrary units, A in -1..1)

def layer_grain():
    r = rng(0)
    h = 0.55 * band(r, 10, 40, 1.0) + 0.3 * band(r, 30, 80, 0.5)
    pores = splat_discs(r, 1100, (0.7, 1.4), (0.6, 1.0))
    h -= 1.6 * pores
    a = 0.6 * band(r, 3, 12, 1.0) + 0.25 * band(r, 20, 60, 0.5) + 0.6 * np.clip(pores, 0, 1)
    return h, a


def layer_wood():
    r = rng(1)
    rings = 11  # whole number: the rings tile
    warp = 0.9 * band(r, 1, 4, 1.0, sx=3.0) + 0.25 * band(r, 3, 10, 1.0, sx=4.0)
    t = YY / N * rings + warp
    f = t - np.floor(t)
    # Earlywood rises slowly, latewood is a narrow dense band (raised: soft wood wears away around it).
    late = np.exp(-((f - 0.82) / 0.07) ** 2) + np.exp(-((f - 1.82) / 0.07) ** 2) + np.exp(-((f + 0.18) / 0.07) ** 2)
    fibre = band(r, 30, 110, 0.4, sx=12.0)
    pn = band(r, 24, 110, 0.3, sx=9.0)
    pores = smoothstep(1.5, 2.4, -pn) * (0.4 + 0.6 * (1 - late))
    h = 0.7 * late - 1.0 * pores + 0.18 * fibre + 0.25 * band(r, 2, 8, 1.0, sx=3.0)
    a = -0.75 * late - 0.45 * pores + 0.12 * fibre + 0.35 * band(r, 2, 10, 1.0, sx=3.0)
    return h, a


def layer_brushed():
    r = rng(2)
    brushed = band(r, 20, 120, 0.25, sx=28.0)
    scratches = splat_segments(r, 150, (14, 150), (0.25, 1.0), (0.45, 0.8), curve=0.04)
    h = 0.35 * brushed - 1.3 * scratches
    a = 0.35 * band(r, 2, 12, 1.0, sx=6.0) + 0.2 * brushed + 0.9 * np.clip(scratches, 0, 1)
    return h, a


def layer_stone():
    r = rng(3)
    fbm = band(r, 2, 110, 1.15)
    wx, wy = 6 * band(r, 1, 5, 1.0), 6 * band(r, 1, 5, 1.0)
    vn = sample(band(r, 3, 14, 1.0), XX + wx, YY + wy)
    vein = smoothstep(0.88, 0.985, 1 - np.abs(vn) / 3.0)
    pits = splat_discs(r, 260, (1.2, 4.0), (0.4, 1.0), profile="crater")
    h = 0.8 * fbm - 1.5 * pits - 0.6 * vein + 0.2 * band(r, 40, 110, 0.3)
    a = 0.55 * band(r, 2, 10, 1.0) - 0.8 * vein - 0.3 * np.clip(pits, 0, 1) + 0.15 * band(r, 30, 90, 0.5)
    return h, a


def layer_weave():
    r = rng(4)
    T = 16  # threads a tile in each direction (even: the over/under parity tiles too)
    cx, cy = XX / N * T, YY / N * T
    i, j = np.floor(cx), np.floor(cy)
    fa, fb = cx - i, cy - j
    # Warp threads run along v (columns), weft along u (rows); the warp is on top where i + j is even.
    warp_z = 0.5 * np.cos(np.pi * (cy - 0.5 + i))
    weft_z = -0.5 * np.cos(np.pi * (cx - 0.5 + j))
    prof = lambda q: np.sqrt(np.clip(1 - ((q - 0.5) / 0.46) ** 2, 0, 1))
    pw, pf = prof(fa), prof(fb)
    # Fibres along each thread, and the ply's twist as faint diagonal highlights.
    fib_w = band(r, 30, 120, 0.3, sy=10.0)
    fib_f = band(r, 30, 120, 0.3, sx=10.0)
    tw_w = np.cos(2 * np.pi * (cy * 3.0 + fa * 1.2))
    tw_f = np.cos(2 * np.pi * (cx * 3.0 + fb * 1.2))
    hw = np.where(pw > 0, 0.55 * warp_z + 0.9 * pw + 0.06 * fib_w + 0.05 * tw_w, -1.2)
    hf = np.where(pf > 0, 0.55 * weft_z + 0.9 * pf + 0.06 * fib_f + 0.05 * tw_f, -1.2)
    top_w = hw >= hf
    h = np.maximum(hw, hf)
    # A: each thread a slightly different shade, fibres, and the gaps darker.
    ri = rng(40).normal(0, 1, T)[(i.astype(int)) % T]
    rj = rng(41).normal(0, 1, T)[(j.astype(int)) % T]
    a = np.where(top_w, 0.25 * ri + 0.3 * fib_w, 0.25 * rj + 0.3 * fib_f)
    a -= 0.7 * smoothstep(0.2, -0.6, h)
    return h, a


def layer_bumps():
    r = rng(5)
    warp = (5 * band(r, 1, 6, 1.0), 5 * band(r, 1, 6, 1.0))
    f1, f2, _ = worley(r, 190, warp)
    edge = f2 - f1
    crease = 1 - smoothstep(0.0, 4.0, edge)
    dome = smoothstep(0.0, 9.0, edge) ** 0.6
    h = 1.0 * dome - 0.5 * crease + 0.12 * band(r, 40, 110, 0.4) + 0.3 * band(r, 2, 6, 1.0)
    a = 0.7 * crease - 0.3 * dome + 0.2 * band(r, 20, 80, 0.5)
    return h, a


def layer_wear():
    r = rng(6)
    base = band(r, 2, 30, 1.0)
    # Chips: sharp-edged blobs with jagged rims; worn first at their middle.
    cn = band(r, 6, 36, 0.8) + 0.35 * band(r, 30, 100, 0.3)
    chip = smoothstep(1.55, 1.75, cn)
    chip_core = smoothstep(1.55, 2.6, cn)
    scratches = splat_segments(r, 70, (10, 90), (0.4, 1.0), (0.4, 0.75), curve=0.08)
    scuff = smoothstep(0.9, 2.2, band(r, 4, 40, 0.8, sx=5.0)) * (0.6 + 0.4 * band(r, 20, 80, 0.3).clip(-1, 1))
    # The order a texel wears in: the bare surface 0.24..0.48 (only heavy wear, above 0.5, reaches it), scuffs
    # from 0.52, scratches from 0.62, chips from 0.72, their cores first (up to 0.99).
    order = 0.36 + 0.06 * np.clip(base, -2, 2)
    order = np.where(scuff > 0.05, np.maximum(order, 0.52 + 0.2 * np.clip(scuff, 0, 1)), order)
    order = np.where(scratches > 0.08, np.maximum(order, 0.62 + 0.36 * np.clip(scratches, 0, 1)), order)
    order = np.where(chip > 0.02, np.maximum(order, 0.72 + 0.27 * chip_core), order)
    h = -1.0 * chip - 0.6 * scratches - 0.08 * scuff
    a = (np.clip(order, 0.0, 1.0) - 0.5) / 0.5  # mapped back to 0..1 by the encoder
    return h, a


def layer_bark():
    r = rng(7)
    wx = 7 * band(r, 1, 4, 1.0, sy=3.0)
    fn = sample(band(r, 3, 22, 1.0, sy=5.0), XX + wx, YY)
    fissure = smoothstep(0.80, 0.97, 1 - np.abs(fn) / 2.5)
    plates = band(r, 2, 40, 1.1, sy=2.0)
    warp = (3 * band(r, 2, 8, 1.0), 3 * band(r, 2, 8, 1.0))
    f1, f2, _ = worley(r, 70, warp)
    crack = 1 - smoothstep(0.4, 1.6, f2 - f1)
    h = 0.6 * plates - 1.3 * fissure - 0.8 * crack + 0.15 * band(r, 40, 110, 0.4, sy=3.0)
    a = 0.3 * band(r, 2, 10, 1.0) - 0.75 * fissure - 0.55 * crack + 0.15 * plates
    return h, a


BUILDERS = [layer_grain, layer_wood, layer_brushed, layer_stone, layer_weave, layer_bumps, layer_wear, layer_bark]


# ---------------------------------------------------------------- encoding

def encode(name, h, a):
    """RGBA float 0..1 for one layer: the normal of h (scaled to the layer's slope), h as B, a as A."""
    dx = (np.roll(h, -1, 1) - np.roll(h, 1, 1)) * 0.5
    dy = (np.roll(h, -1, 0) - np.roll(h, 1, 0)) * 0.5
    g = np.hypot(dx, dy)
    # Slope s (normal xy length) for gradient k*g is k*g / sqrt(1 + (k*g)^2): set k so the 98th percentile hits SLOPE.
    s98 = SLOPE[name]
    g98 = np.percentile(g, 98)
    k = (s98 / np.sqrt(1 - s98 * s98)) / max(g98, 1e-9)
    nx, ny = -k * dx, -k * dy
    inv = 1.0 / np.sqrt(1.0 + nx * nx + ny * ny)
    nx, ny = nx * inv, ny * inv
    ref = np.median(h)
    span = max(abs(np.percentile(h, 0.3) - ref), abs(np.percentile(h, 99.7) - ref), 1e-9)
    b = 0.5 + 0.44 * np.clip((h - ref) / span, -1, 1)
    if name == "wear":
        av = 0.5 + 0.5 * a
    else:
        av = 0.5 + 0.4 * np.clip(a / max(np.percentile(np.abs(a), 99.5), 1e-9), -1, 1)
    # Alpha never reaches 0 or 1 (tools that premultiply would lose RGB at 0).
    av = np.clip(av, 8 / 255, 247 / 255)
    return np.stack([0.5 + 0.5 * nx, 0.5 + 0.5 * ny, b, av], -1)


def to8(x):
    return np.clip(np.floor(x * 255.0 + 0.5), 0, 255).astype(np.uint8)


def build():
    tiles = []
    for name, fn in zip(LAYERS, BUILDERS):
        h, a = fn()
        tiles.append(to8(encode(name, h, a)))
    return np.concatenate(tiles, 0)


def png_bytes(strip):
    buf = io.BytesIO()
    Image.fromarray(strip, "RGBA").save(buf, "PNG", optimize=True, compress_level=9)
    return buf.getvalue()


def mips(tile):
    """Melange's chain: plain 2x2 averages of the stored bytes, rounded."""
    out = [tile.astype(np.float64)]
    while out[-1].shape[0] > 1:
        t = out[-1]
        t = (t[0::2, 0::2] + t[1::2, 0::2] + t[0::2, 1::2] + t[1::2, 1::2]) / 4.0
        out.append(np.floor(t + 0.5))
    return out


def report(strip):
    print("layer     R/G mean     |xy| p98  B mean  A mean   1x1 mip RGBA        |xy| at 32/8/2 px")
    for k, name in enumerate(LAYERS):
        t = strip[k * N:(k + 1) * N]
        f = t.astype(np.float64) / 255.0
        xy = np.hypot(f[..., 0] * 2 - 1, f[..., 1] * 2 - 1)
        ch = mips(t)
        tail = []
        for lv in (3, 5, 7):
            m = ch[lv] / 255.0
            tail.append(f"{np.hypot(m[..., 0] * 2 - 1, m[..., 1] * 2 - 1).mean():.3f}")
        one = " ".join(f"{int(v):3d}" for v in ch[-1][0, 0])
        print(f"{k} {name:8s} {f[..., 0].mean():.3f}/{f[..., 1].mean():.3f}  {np.percentile(xy, 98):.3f}"
              f"     {f[..., 2].mean():.3f}   {f[..., 3].mean():.3f}    {one}      {' / '.join(tail)}")


def preview(strip, path):
    """Contact sheet: per layer, lit 2x2 tiling (seams would show), normal, B, A, and mip 3 (32 px) enlarged."""
    rows = []
    l = np.array([-0.55, -0.45, 0.7])
    l /= np.linalg.norm(l)
    for k in range(len(LAYERS)):
        t = strip[k * N:(k + 1) * N].astype(np.float64) / 255.0
        nx, ny = t[..., 0] * 2 - 1, t[..., 1] * 2 - 1
        nz = np.sqrt(np.clip(1 - nx * nx - ny * ny, 0, 1))
        lit = np.clip(nx * l[0] + ny * l[1] + nz * l[2], 0, 1) * (0.55 + 0.45 * t[..., 2] / 0.5).clip(0, 1.2)
        lit = np.tile(lit, (2, 2))
        lit = Image.fromarray(to8(lit / 1.1)).resize((N, N), Image.LANCZOS).convert("RGB")
        nrm = Image.fromarray(to8(np.stack([t[..., 0], t[..., 1], nz * 0.5 + 0.5], -1)))
        b = Image.fromarray(to8(t[..., 2])).convert("RGB")
        a = Image.fromarray(to8(t[..., 3])).convert("RGB")
        m3 = mips(strip[k * N:(k + 1) * N])[3].astype(np.uint8)
        m3 = Image.fromarray(m3[..., :3]).resize((N, N), Image.NEAREST)
        row = Image.new("RGB", (5 * N + 4 * 4, N), (27, 29, 34))
        for c, im in enumerate([lit, nrm, b, a, m3]):
            row.paste(im, (c * (N + 4), 0))
        rows.append(row)
    sheet = Image.new("RGB", (rows[0].width, len(rows) * (N + 4)), (27, 29, 34))
    for k, row in enumerate(rows):
        sheet.paste(row, (0, k * (N + 4)))
    sheet.save(path)
    print(f"preview: {path} (columns: lit 2x2 tiling, normal, B height, A, mip 3 RGB)")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=str(OUT), help="the strip PNG (default mod/assets/detail/materials.png)")
    ap.add_argument("--preview", help="also write a contact sheet here")
    ap.add_argument("--check", action="store_true", help="exit 1 when the PNG at --out differs from a fresh build")
    args = ap.parse_args()
    strip = build()
    data = png_bytes(strip)
    out = Path(args.out)
    if args.check:
        if not out.exists():
            sys.exit(f"{out}: missing (run tools/make_detail_maps.py)")
        old = np.asarray(Image.open(out).convert("RGBA"))
        if old.shape != strip.shape or not np.array_equal(old, strip):
            sys.exit(f"{out}: out of date (run tools/make_detail_maps.py)")
        print(f"{out}: up to date")
        return
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(data)
    print(f"{out}: {strip.shape[1]}x{strip.shape[0]}, {len(LAYERS)} layers, {len(data)} bytes")
    report(strip)
    if args.preview:
        preview(strip, args.preview)


if __name__ == "__main__":
    main()
