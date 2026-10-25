#!/usr/bin/env python3
"""Generate Sandtide's world particle sprites into mod/textures/.

    dust_puff.png   128x128  a soft billowing dust cloud (domain-warped fBm inside a radial falloff)
    sand_grain.png   32x32   one grain: a lit sphere (grey shading in RGB) with an anti-aliased edge
    sand_swirl.png  128x128  a spiral wisp of blown sand, broken into streaks and speckled with grains
    sand_band.png   256x64   drifting sand for the sand line: horizontal wisps that tile left to right

Like Kindjal's sprites they are meant to be tinted at draw time: RGB is white (sand_grain carries its shading as grey
in RGB) and the shape lives in alpha, with a clear margin so the quad edge never shows (sand_band is clear at the top
and bottom only, since it tiles sideways). Original art made by this script; seeded, so the output is deterministic.
Needs numpy and Pillow.

    python make_sprites.py
"""
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _art import SS, alpha_sprite, blur, cov, down, fbm, grid, save, smoothstep, tile_noise  # noqa: E402

OUT = Path(__file__).resolve().parent.parent / "mod" / "textures"


def dust_puff():
    n = 128
    X, Y = grid(n, n)
    rng = np.random.default_rng(11)
    wx = fbm(X.shape, 4, rng, 3) * 10.0
    wy = fbm(X.shape, 4, rng, 3) * 10.0
    r = np.hypot(X + wx - n / 2, Y + wy - n / 2) / (n * 0.40)
    body = np.clip(1.0 - r, 0, 1) ** 1.4
    billow = 0.55 + 0.45 * fbm(X.shape, 6, rng, 5)
    lobes = 0.0
    for k in range(6):
        a = 2 * math.pi * k / 6 + rng.uniform(-0.4, 0.4)
        cx, cy = n / 2 + math.cos(a) * n * 0.16, n / 2 + math.sin(a) * n * 0.16
        lobes = np.maximum(lobes, np.clip(1 - np.hypot(X + wx - cx, Y + wy - cy) / (n * rng.uniform(0.17, 0.24)), 0, 1))
    a = np.clip(body * billow * 1.25 + lobes ** 1.5 * 0.35 * billow, 0, 1)
    a *= smoothstep(n * 0.5, n * 0.40, np.hypot(X - n / 2, Y - n / 2))
    return alpha_sprite(a * 0.95)


def sand_grain():
    n = 32
    X, Y = grid(n, n)
    c = n / 2
    r = n * 0.36
    d = np.hypot(X - c, Y - c)
    z = np.sqrt(np.clip(1 - (d / r) ** 2, 0, 1))
    nx, ny = (X - c) / r, (Y - c) / r
    lam = np.clip(-0.45 * nx - 0.6 * ny + 0.66 * z, 0, 1)
    lum = 0.55 + 0.45 * lam + 0.35 * np.clip(lam, 0, 1) ** 20
    a = cov(d - r)
    lum_d = down(lum * a) / np.maximum(down(a), 1e-6)
    al = down(a)
    out = np.dstack([np.clip(lum_d, 0, 1)] * 3 + [al])
    return Image.fromarray((out * 255 + 0.5).astype(np.uint8), "RGBA")


def sand_swirl():
    n = 128
    X, Y = grid(n, n)
    rng = np.random.default_rng(23)
    c = n / 2
    dx, dy = X - c, Y - c
    r = np.hypot(dx, dy) / (n * 0.44)
    th = np.arctan2(dy, dx)
    # a two-armed logarithmic spiral
    phase = th - 2.4 * np.log(np.maximum(r, 1e-3))
    arms = 0.5 + 0.5 * np.cos(2 * phase)
    band = arms ** 6
    streak = 0.5 + 0.5 * fbm(X.shape, 10, rng, 4)
    a = band * smoothstep(1.0, 0.55, r) * smoothstep(0.05, 0.25, r) * (0.35 + 0.9 * streak)
    a = blur(a, 1.2 * SS)
    speck = (rng.random(X.shape) > 0.997).astype(float)
    speck = blur(speck, 0.8 * SS) * 9.0 * band * smoothstep(1.0, 0.5, r)
    a = np.clip(a * 0.85 + speck, 0, 1)
    return alpha_sprite(a)


def sand_band():
    """Wisps are periodic in x (whole numbers of cycles across the 256 px), so the strip tiles sideways."""
    w, h = 256, 64
    rng = np.random.default_rng(37)
    X, Y = grid(w, h)
    u = X / w * 2 * math.pi

    def periodic(kmax, amp_tilt=1.0):
        out = np.zeros_like(X)
        for k in range(1, kmax + 1):
            out += np.cos(k * u + rng.uniform(0, 2 * math.pi)) / k ** amp_tilt
        return out / np.abs(out).max()

    a = np.zeros_like(X)
    for _ in range(16):
        yc = h / 2 + rng.normal(0, h * 0.13)
        k = int(rng.integers(1, 4))
        wob = rng.uniform(1.0, 3.5) * np.sin(k * u + rng.uniform(0, 6.28)) + 1.2 * periodic(6)
        thick = rng.uniform(0.8, 2.6) * (0.7 + 0.3 * periodic(4))
        line = np.exp(-((Y - yc - wob) / thick) ** 2)
        k2 = int(rng.integers(1, 4))
        extent = np.clip(0.5 + 0.5 * np.cos(k2 * u + rng.uniform(0, 6.28)), 0, 1) ** rng.uniform(1.5, 4.0)
        streak = 0.55 + 0.45 * periodic(40, 0.6)
        a = np.maximum(a, line * extent * streak * rng.uniform(0.45, 1.0))
    v = np.exp(-((Y - h / 2) / (h * 0.26)) ** 2)
    speck = (rng.random(X.shape) > 0.9975).astype(float)
    speck = blur(speck, 0.6 * SS) * 7.0
    speck = np.clip(speck, 0, 1) * (0.25 + a)
    alpha = np.clip(a * v + speck * v * 0.8, 0, 1)
    return alpha_sprite(alpha)


def main():
    for name, fn in (("dust_puff", dust_puff), ("sand_grain", sand_grain), ("sand_swirl", sand_swirl),
                     ("sand_band", sand_band)):
        save(fn(), OUT / (name + ".png"))
        print("wrote", name + ".png")


if __name__ == "__main__":
    main()
