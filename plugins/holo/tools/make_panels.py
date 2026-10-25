#!/usr/bin/env python3
"""Draw Holo's panel atlas (mod/textures/ui/panels.png): the inked-cartoon pieces of the vanilla frontend look.

  python tools/make_panels.py [--check] [--emit-lua]

Everything is authored at 2x (draw nine-slices with scale 0.5) and packed into one texture of at most 1024x1024.
Shape language (design 2.8): a black 4 px outline with a low-frequency wobble, a white 2 px rim on interactive pieces, a
hard shadow (+3,+5) at 45% with a 4 px blur baked into the margins, 18 px panel radius, full-round pills and a bevel
line pair. Deterministic: seeded noise, fixed PNG settings. `--emit-lua` rewrites src/55_atlas.lua for all atlases.
"""
from __future__ import annotations

import functools
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _art as A  # noqa: E402

# Transparent margin round every shape (2x px): left/top hold the wobble and blur, right/bottom also the shadow offset.
PL, PT, PR, PB = 12, 12, 24, 28
SHADOW = (6, 10, 4.0, 0.45)  # dx, dy, blur sigma, alpha  (design: +3,+5 px at 45%, 4 px blur, at 2x)


def inked(W, H, box, radius, *, seed, wob=((2.4, 70.0),), ink=8, rim=4, rim_alpha=1.0, fill=(A.PANEL_TOP, A.PANEL),
          shadow=SHADOW, bevel=0, bevel_up=True, hi=A.PANEL_LIGHT2, lo=A.PANEL_DARK, inset=0.0, rim_color=A.WHITE,
          ink_color=A.INK):
    """A rounded, wobbly, inked shape: `box` is the outer edge of the rim; ink and fill follow inwards."""
    X, Y = A.grid(W, H)
    d = A.rbox(X, Y, *box, radius)
    for i, (amp, wl) in enumerate(wob):
        d = d + amp * A.value_noise((H, W), wl, seed * 7 + i)
    d_ink = d + rim
    d_fill = d + rim + ink
    c = A.new_canvas(W, H)
    if shadow:
        dx, dy, sigma, alpha = shadow
        A.over(c, A.INK, A.blur(A.shift(A.cov(d), dx, dy), sigma) * alpha)
    if rim_alpha > 0:
        A.over(c, rim_color, A.cov(d) * rim_alpha)
    A.over(c, ink_color, A.cov(d_ink))
    grad = A.vgradient(H, W, fill[0], fill[1], box[1] + rim + ink, box[3] - rim - ink)
    cf = A.cov(d_fill)
    A.over(c, grad, cf)
    if bevel:
        depth = -d_fill
        gy, gx = np.gradient(d_fill)
        n = np.maximum(np.hypot(gx, gy), 1e-6)
        facing = -(gx + gy) / n / np.sqrt(2.0)  # +1 where the outward normal points to the top left
        band = A.cov(np.abs(depth - bevel) - 1.0) * cf
        up = facing if bevel_up else -facing
        A.over(c, hi, band * A.smoothstep(0.15, 0.6, up) * 0.9)
        A.over(c, lo, band * A.smoothstep(0.15, 0.6, -up) * 0.9)
    if inset:
        outside = 1.0 - cf
        A.over(c, A.INK, A.blur(A.shift(outside, 3, 4), 3.0) * inset * cf)
    return c


def frame(hole_w, hole_h, *, ink, rim, r_in, seed):
    """A ring round a rectangular video: the hole is transparent, its inner corners are painted black so the
    rectangular picture reads as rounded. Returns (canvas, inner insets)."""
    b = ink + rim
    W, H = PL + b + hole_w + b + PR, PT + b + hole_h + b + PB
    X, Y = A.grid(W, H)
    hx0, hy0 = PL + b, PT + b
    dh = A.rbox(X, Y, hx0, hy0, hx0 + hole_w, hy0 + hole_h, r_in)
    wob = 1.0 * A.value_noise((H, W), 60.0, seed)
    d_ink = dh - ink + wob
    d_rim = d_ink - rim
    hole = A.cov(dh)
    c = A.new_canvas(W, H)
    dx, dy, sigma, alpha = SHADOW
    A.over(c, A.INK, A.blur(A.shift(A.cov(d_rim), dx, dy), sigma) * alpha * (1 - hole))
    A.over(c, A.WHITE, A.cov(d_rim) * (1 - hole))
    A.over(c, A.INK, A.cov(d_ink) * (1 - hole))
    inner = {"l": PL + b, "t": PT + b, "r": PR + b, "b": PB + b}
    return c, inner


def torn_tag(W, H, seed):
    X, Y = A.grid(W, H)
    box = (PL, PT, W - PR, H - PB)
    d = A.rbox(X, Y, *box, 8)
    d = d + 2.0 * A.value_noise((H, W), 70.0, seed) + 1.5 * A.value_noise((H, W), 9.0, seed + 1)
    c = A.new_canvas(W, H)
    A.over(c, A.INK, A.blur(A.shift(A.cov(d), 4, 6), 3.0) * 0.4)
    A.over(c, A.INK, A.cov(d))
    grad = A.vgradient(H, W, A.PAPER, A.mix(A.PAPER, (0xD9, 0xC0, 0x95), 0.55), box[1], box[3])
    A.over(c, grad, A.cov(d + 6))
    return c


def swash(W, H, seed):
    """The black brush swash behind a selected row: ragged ends, no outline."""
    X, Y = A.grid(W, H)
    d = A.rbox(X, Y, 6, 6, W - 6, H - 6, 18)
    d = d + 3.0 * A.value_noise((H, W), 40.0, seed) + 2.2 * A.value_noise((H, W), 11.0, seed + 1)
    c = A.new_canvas(W, H)
    A.over(c, A.INK, A.cov(d))
    return c


def divider(W, H, seed):
    """A white brush stroke with a dot at each end."""
    X, Y = A.grid(W, H)
    mid = H / 2 - 2
    d = A.capsule(X, Y, (22, mid), (W - 22, mid), 6) + 1.4 * A.value_noise((H, W), 50.0, seed)
    d = np.minimum(d, A.circle(X, Y, 14, mid, 9.5))
    d = np.minimum(d, A.circle(X, Y, W - 14, mid, 9.5))
    c = A.new_canvas(W, H)
    A.over(c, A.INK, A.blur(A.shift(A.cov(d), 2, 3), 2.0) * 0.4)
    A.over(c, A.WHITE, A.cov(d))
    return c


def knob(S):
    X, Y = A.grid(S + PL + PR, S + PT + PB)
    r = S / 2
    cx, cy = PL + r, PT + r
    d = A.circle(X, Y, cx, cy, r)
    c = A.new_canvas(*X.shape[::-1])
    dx, dy, sigma, alpha = SHADOW
    A.over(c, A.INK, A.blur(A.shift(A.cov(d), dx // 2, dy // 2), sigma * 0.6) * alpha)
    A.over(c, A.INK, A.cov(d))
    grad = A.vgradient(X.shape[0], X.shape[1], A.TITLE, A.mix(A.CREAM, (0xC8, 0x9A, 0x40), 0.5), cy - r, cy + r)
    A.over(c, grad, A.cov(d + 6))
    return c


def tail(w, h, seed):
    """The tooltip's pointer: a downward rounded triangle."""
    W, H = w + PL + PR, h + PT + PB
    X, Y = A.grid(W, H)
    cx = PL + w / 2
    pts = [(cx - w / 2 + 8, PT), (cx + w / 2 - 8, PT), (cx, PT + h - 8)]
    d = A.poly(X, Y, pts, 8)
    c = A.new_canvas(W, H)
    A.over(c, A.INK, A.blur(A.shift(A.cov(d), 4, 6), 3.0) * 0.4)
    A.over(c, A.INK, A.cov(d))
    grad = A.vgradient(H, W, (0x21, 0x52, 0x63), (0x21, 0x42, 0x5E), PT, PT + h)
    A.over(c, grad, A.cov(d + 6))
    return c


def scrim(w, h):
    """Black fading to nothing upwards: the control bar's backdrop over the picture."""
    t = np.linspace(0.0, 1.0, h, dtype=np.float32)
    a = (A.smoothstep(0.0, 1.0, t) * 0.72)[:, None] * np.ones((1, w), dtype=np.float32)
    c = A.new_canvas(w, h)
    A.over(c, A.INK, a)
    return c


def bar_fill(W, H):
    X, Y = A.grid(W, H)
    d = A.rbox(X, Y, 2, 2, W - 2, H - 2, (H - 4) / 2)
    c = A.new_canvas(W, H)
    grad = A.vgradient(H, W, A.mix(A.SEEK, A.WHITE, 0.3), A.mix(A.SEEK, (0xB0, 0x70, 0x10), 0.35), 2, H - 2)
    A.over(c, grad, A.cov(d))
    return c


def elements():
    """name -> (canvas, nine-slice insets (l, t, r, b), pad (l, t, r, b), optional inner insets)."""
    out = {}

    def add(name, canvas, nine, pad=(PL, PT, PR, PB), inner=None):
        out[name] = (canvas, nine, pad, inner)

    def panel(name, bw, bh, radius, seed, **kw):
        W, H = PL + bw + PR, PT + bh + PB
        c = inked(W, H, (PL, PT, PL + bw, PT + bh), radius, seed=seed, **kw)
        k = radius + 8
        add(name, c, (PL + k, PT + k, PR + k, PB + k))

    panel("panel", 220, 220, 36, 1, bevel=20, hi=A.PANEL_LIGHT2, lo=A.PANEL_DARK, rim=0, ink=8)
    panel("panel_dark", 180, 180, 28, 2, fill=(A.PANEL_DARK2, A.PANEL_DARK), bevel=18, hi=A.PANEL, lo=(8, 24, 31),
          rim=0, ink=8)
    panel("tooltip", 200, 140, 24, 3, fill=((0x21, 0x52, 0x63), (0x21, 0x42, 0x5E)), bevel=0, rim=0, ink=6,
          shadow=(4, 8, 3.5, 0.45))

    def button(name, seed, fill, rim_alpha=1.0, pressed=False, hi=None, lo=None):
        bw, bh = 192, 96
        W, H = PL + bw + PR, PT + bh + PB
        top = A.mix(fill, A.WHITE, 0.14)
        bot = A.mix(fill, A.INK, 0.08)
        sh = (2, 4, 2.0, 0.40) if pressed else SHADOW
        c = inked(W, H, (PL, PT, PL + bw, PT + bh), bh / 2, seed=seed, wob=((1.6, 60.0),), fill=(top, bot),
                  bevel=10, bevel_up=not pressed, hi=hi or A.mix(fill, A.WHITE, 0.45), lo=lo or A.mix(fill, A.INK, 0.5),
                  rim_alpha=rim_alpha, shadow=sh)
        # Rows t and b are the pill's two halves; the two rows between them are what stretches vertically.
        mid = PT + bh // 2
        add(name, c, (PL + bh // 2 + 4, mid, PR + bh // 2 + 4, H - mid - 2))

    button("btn", 10, A.BTN)
    button("btn_hover", 11, A.BTN_HOVER)
    button("btn_press", 12, A.BTN_PRESS, pressed=True)
    button("btn_off", 13, A.BTN_OFF, rim_alpha=0.0)

    # pill: the minimised player, a panel-teal capsule with the interactive rim.
    bw, bh = 192, 96
    W, H = PL + bw + PR, PT + bh + PB
    c = inked(W, H, (PL, PT, PL + bw, PT + bh), bh / 2, seed=14, wob=((1.6, 60.0),),
              fill=(A.PANEL_TOP, A.PANEL), bevel=10, hi=A.PANEL_LIGHT2, lo=A.PANEL_DARK)
    mid = PT + bh // 2
    add("pill", c, (PL + bh // 2 + 4, mid, PR + bh // 2 + 4, H - mid - 2))

    # tag: the cream torn-paper title label.
    W, H = 240 + PL + PR, 72 + PT + PB
    add("tag", torn_tag(W, H, 20), (PL + 28, PT + 30, PR + 28, H - PT - 32))

    # well: an inset text-field / list background, dark with an inner shadow and no drop shadow.
    pw = (6, 6, 6, 10)
    W, H = 180 + pw[0] + pw[2], 96 + pw[1] + pw[3]
    c = inked(W, H, (pw[0], pw[1], W - pw[2], H - pw[3]), 22, seed=30, wob=((1.4, 60.0),), rim=0, ink=6,
              fill=(A.PANEL_DARK, A.PANEL_DARK2), shadow=None, inset=0.6)
    add("well", c, (pw[0] + 28, pw[1] + 28, pw[2] + 28, H - pw[1] - 30), pad=pw)

    # bars
    tp = (6, 6, 10, 10)
    W, H = 128 + tp[0] + tp[2], 20 + tp[1] + tp[3]
    c = inked(W, H, (tp[0], tp[1], W - tp[2], H - tp[3]), 10, seed=40, wob=((0.6, 40.0),), rim=0, ink=4,
              fill=(A.PANEL_DARK, A.PANEL_DARK2), shadow=(2, 4, 2.0, 0.4), inset=0.5)
    add("bar_track", c, (tp[0] + 16, tp[1] + 8, tp[2] + 16, H - tp[1] - 10), pad=tp)
    W, H = 64, 16
    add("bar_fill", bar_fill(W, H), (8, 7, 8, 7), pad=(2, 2, 2, 2))

    # frames
    c, inner = frame(64, 64, ink=12, rim=6, r_in=20, seed=50)
    b = 18
    add("frame_video", c, (PL + b + 20 + 4, PT + b + 20 + 4, PR + b + 20 + 4, PB + b + 20 + 4), inner=inner)
    c, inner = frame(48, 48, ink=8, rim=4, r_in=12, seed=51)
    b = 12
    add("frame_corner", c, (PL + b + 12 + 4, PT + b + 12 + 4, PR + b + 12 + 4, PB + b + 12 + 4), inner=inner)

    # small parts: no nine-slice (insets 0)
    add("tail", tail(48, 36, 60), (0, 0, 0, 0))
    add("knob", knob(44), (0, 0, 0, 0))
    add("scrim", scrim(8, 112), (0, 0, 0, 0), pad=(0, 0, 0, 0))
    W, H = 256, 44
    add("divider", divider(W, H, 70), (30, 0, 30, 0), pad=(0, 0, 0, 0))
    W, H = 256, 60
    add("swash", swash(W, H, 80), (44, 0, 44, 0), pad=(0, 0, 0, 0))
    return out


@functools.lru_cache(maxsize=None)
def build():
    els = elements()
    names = list(els)
    sizes = [(els[n][0].shape[1], els[n][0].shape[0]) for n in names]
    pos, height = A.shelf_pack(sizes, 1024, 2)
    height = (height + 3) // 4 * 4
    if height > 1024:
        raise SystemExit(f"make_panels: atlas needs {height} rows (limit 1024)")
    atlas = A.new_canvas(1024, height)
    rects = {}
    for n, (x, y), (w, h) in zip(names, pos, sizes):
        atlas[y:y + h, x:x + w] = els[n][0]
        _, (l, t, r, b), pad, inner = els[n]
        rect = {"x": x, "y": y, "w": w, "h": h, "l": l, "t": t, "r": r, "b": b,
                "pad": {"l": pad[0], "t": pad[1], "r": pad[2], "b": pad[3]}}
        if inner:
            rect["inner"] = inner
        rects[n] = rect
    png = A.png_bytes(A.to_straight(atlas))
    layout = {"file": "textures/ui/panels.png", "w": 1024, "h": height, "rects": rects}
    return {"mod/textures/ui/panels.png": png}, layout


if __name__ == "__main__":
    sys.exit(A.run_cli("make_panels", build, sys.argv[1:]))
