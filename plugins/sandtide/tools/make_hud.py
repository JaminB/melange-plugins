#!/usr/bin/env python3
"""Generate Sandtide's hourglass HUD art into mod/textures/hud/.

The hourglass is drawn on a 256 x 384 canvas, twice the size it is meant to be shown at (128 x 192 HUD pixels at
scale 1), so it stays sharp on high-DPI screens and when the HUD scale setting is raised. wum.draw.hudImage draws a whole
texture into a rectangle (it has no source rectangle), so every animated element is a stack of separate textures: sand
levels, stream frames, crack stages and shatter frames, each cropped to the part of the canvas it covers. The rectangle
of every texture on the canvas is written to tools/hud_layout.json (and listed in tools/README-art.md); draw them in the
order given there.

Rendering: numpy on a 4x supersampled grid. Shapes are signed distance fields; metal and bone get height fields
(bevels, engraving, a lathe-turned pillar profile with spiral fluting) lit by one key light from the upper left with
a sky/ground environment term and a Blinn highlight; the glass is a thin-walled SDF shell with Fresnel edges, arc
highlights, a hot spot, a cool rim light and a window reflection; the sand has cylinder shading, wall occlusion,
grain, glints and settling strata, and its levels are found by area so the sand that leaves the top bulb is the sand
that arrives in the bottom one. Box-filtered down to the output size; transparent pixels are colour-bled so mipmaps
never fringe. Seeded generators only, so the output is deterministic. Original art made by this script.

Needs numpy and Pillow.

    python make_hud.py                 write the textures and tools/hud_layout.json
    python make_hud.py --preview PATH  also write a preview sheet of the states to PATH
"""
import argparse
import json
import math
import re
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _art import (SS, BONE, BRASS, ENAMEL, IRON, Layer, alpha_sprite, blur, cov, fbm, grid, ramp, save,  # noqa: E402
                  sd_circle, sd_ellipse, sd_rbox, sd_vcapsule, shade, normals, smin, smoothstep, to_image, down)

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "mod" / "textures" / "hud"
LAYOUT = Path(__file__).resolve().parent / "hud_layout.json"

W, H = 256, 384
CX = 128.0
NECK_Y = 192.0
TOP_CY, BOT_CY, BULB_RX, BULB_RY = 116.0, 268.0, 74.0, 64.0
WALL = 3.0
LEVELS = 16          # sand levels 00..15 per bulb
STREAM_FRAMES = 6
SHATTER_FRAMES = 12
DROP_FRAMES = 9

SAND_TOP_RECT = (48, 48, 208, 196)
SAND_BOT_RECT = (48, 188, 208, 336)
STREAM_RECT = (112, 176, 144, 340)
SPILL_RECT = (16, 280, 240, 340)
SHATTER_OFF = (-64, -64)
SHATTER_W, SHATTER_H = 384, 512
DROP_W, DROP_H = 96, 128
DROP_RECT = (80, 128, 176, 256)
PLATE_W, PLATE_H = 224, 72

SAND = [(0.0, (70, 40, 16)), (0.25, (130, 84, 36)), (0.5, (186, 134, 70)), (0.72, (222, 176, 106)),
        (0.9, (242, 210, 148)), (1.1, (255, 240, 200))]


# ---------------------------------------------------------------- glass shape
def glass_sdf(X, Y):
    top = sd_ellipse(X, Y, CX, TOP_CY, BULB_RX, BULB_RY)
    bot = sd_ellipse(X, Y, CX, BOT_CY, BULB_RX, BULB_RY)
    neck = sd_vcapsule(X, Y, CX, 150.0, 234.0, 5.5)
    return smin(smin(top, bot, 4.0), neck, 20.0)


def ang_diff(a, b):
    d = (a - b + math.pi) % (2 * math.pi) - math.pi
    return np.abs(d)


# ---------------------------------------------------------------- sand
class SandField:
    """Noise fields shared by every sand frame, so grains stay put while the level moves."""

    def __init__(self, X, Y):
        rng = np.random.default_rng(1771)
        shape = X.shape
        self.fine = blur(rng.standard_normal(shape), 0.7)
        self.fine /= np.abs(self.fine).max()
        self.mid = fbm(shape, 40, rng, 3)
        self.big = fbm(shape, 8, rng, 2)
        self.glint = (rng.random(shape) > 0.9975).astype(np.float64)
        self.glint = blur(self.glint, 0.8) * 6.0
        self.strata = fbm(shape, 6, rng, 2)


def interior_halfwidth(inside):
    """Half-width (canvas px) of the inside mask per sample row, broadcast to the grid."""
    hw = inside.sum(axis=1) / (2.0 * SS)
    return np.maximum(hw, 0.75)[:, None]


def sand_colour(X, Y, I, depth, field, strata=False, hw=None, cx=CX):
    """Shaded sand. depth = distance below the free surface (canvas px, >= 0 inside the sand)."""
    if hw is None:
        hw = interior_halfwidth(I < 0)
    u = np.clip((X - cx) / hw, -1.0, 1.0)
    cyl = np.sqrt(1.0 - u * u)
    lum = 0.30 + 0.48 * cyl - 0.16 * u
    lum *= 0.62 + 0.38 * smoothstep(0.0, 7.0, -I)                      # occlusion against the glass
    lum += 0.32 * np.exp(-np.maximum(depth, 0) / 1.4) * (0.6 + 0.4 * cyl)  # lit free surface
    lum -= 0.10 * np.exp(-np.maximum(depth - 2.5, 0) / 3.0) * (depth > 2.5)  # its shadowed lip
    lum *= 1.0 + 0.11 * field.fine + 0.07 * field.mid + 0.05 * field.big
    if strata:
        lum *= 1.0 + 0.045 * np.sin((Y - 0.42 * np.abs(X - cx)) * 0.55 + field.strata * 7.0) * (0.6 + 0.4 * field.big)
    lum += field.glint * 0.35 * (lum > 0.45)
    return ramp(lum, SAND)


def top_surface(X, L, f):
    dip = 4.0 + 13.0 * (1.0 - f)
    return L + dip * (1.0 - np.clip(((X - CX) / 62.0) ** 2, 0.0, 1.0))


def bot_surface(X, L):
    return L + 0.44 * (np.sqrt((X - CX) ** 2 + 20.0) - math.sqrt(20.0))


def solve_level(area_fn, target, lo, hi):
    for _ in range(40):
        mid = 0.5 * (lo + hi)
        if area_fn(mid) > target:
            lo = mid
        else:
            hi = mid
    return 0.5 * (lo + hi)


def sand_levels():
    """Free-surface heights for every level, solved on a 2x grid so the sand volume is conserved."""
    X, Y = grid(W, H, ss=2)
    inside = glass_sdf(X, Y) + WALL < 0
    full_top_L = 74.0

    def top_area(L, f):
        return (inside & (Y < NECK_Y) & (Y > top_surface(X, L, f))).sum()

    def bot_area(L):
        return (inside & (Y > NECK_Y) & (Y > bot_surface(X, L))).sum()

    full = top_area(full_top_L, 1.0)
    tops, bots = [], []
    for k in range(LEVELS):
        f = k / (LEVELS - 1)
        tops.append(full_top_L if k == LEVELS - 1 else solve_level(lambda L: top_area(L, f), f * full, 40.0, NECK_Y + 1))
        bots.append(None if k == 0 else _solve_bot(bot_area, f * full))
    return tops, bots


def _solve_bot(area_fn, target):
    lo, hi = NECK_Y - 40.0, 345.0      # area(lo) is large, area(hi) is 0
    for _ in range(40):
        mid = 0.5 * (lo + hi)
        if area_fn(mid) > target:
            lo = mid
        else:
            hi = mid
    return 0.5 * (lo + hi)


def render_sand(X, Y, I, field, kind, L, f):
    lay = Layer(X.shape)
    inside = cov(I + 0.3)
    if kind == "top":
        if f <= 0:
            # an empty bulb keeps a few grains clinging to the funnel
            rng = np.random.default_rng(91)
            m = np.zeros(X.shape)
            for _ in range(70):
                y = rng.uniform(160, 190)
                hw = 2.6 + (190 - y) * 0.9
                x = CX + rng.choice([-1, 1]) * rng.uniform(0.6, 1.0) * hw
                m = np.maximum(m, cov(sd_circle(X, Y, x, y, rng.uniform(0.5, 1.0))))
            m *= inside * (Y < NECK_Y)
            lay.paint(sand_colour(X, Y, I, np.full(X.shape, 4.0), field), m)
            return lay
        surf = top_surface(X, L, f)
        m = inside * cov(surf - Y) * cov(Y - NECK_Y - 0.5)
        depth = Y - surf
        lay.paint(sand_colour(X, Y, I, depth, field), m)
        # a dimple of moving sand right above the neck
        dimple = np.exp(-((X - CX) / 7.0) ** 2) * np.exp(-np.maximum(depth, 0) / 10.0) * m
        lay.paint((120, 76, 34), dimple * 0.35)
    else:
        if f <= 0:
            return lay
        surf = bot_surface(X, L)
        m = inside * cov(surf - Y) * cov(NECK_Y + 0.5 - Y)
        depth = Y - surf
        lay.paint(sand_colour(X, Y, I, depth, field, strata=True), m)
        # the stream lands on the apex: a little crater rim of bright churned sand
        apex = np.exp(-((X - CX) / 4.0) ** 2 - ((Y - L - 1.0) / 2.0) ** 2) * m
        lay.paint((255, 236, 190), apex * 0.6)
    return lay


def render_stream(X, Y, I, frame):
    lay = Layer(X.shape)
    rng = np.random.default_rng(300 + frame)
    phase = frame / STREAM_FRAMES
    t = Y * 0.35 - phase * 22.0
    ys = np.arange(4096)
    n1 = np.interp(t, ys * 1.0, np.random.default_rng(77).random(4096))
    wob = 0.35 * np.sin(Y * 0.31 + frame * 1.7)
    w = 1.05 + 0.55 * n1
    core = cov(np.abs(X - CX - wob) - w)
    gaps = smoothstep(0.12, 0.38, np.interp(Y * 0.12 - phase * 7.5, ys * 1.0,
                                            np.random.default_rng(78).random(4096)))
    alive = cov(186.0 - Y) * cov(Y - 338.0)
    a = core * (0.55 + 0.45 * gaps) * alive
    u = np.clip((X - CX - wob) / np.maximum(w, 0.5), -1, 1)
    lum = 0.62 + 0.30 * (-u) + 0.10 * n1
    lay.paint(ramp(lum, SAND), a)
    # loose grains around the stream
    for _ in range(46):
        y = rng.uniform(190, 336)
        x = CX + rng.normal(0, 1.6) * (1.0 + (y - 190) / 140.0)
        r = rng.uniform(0.35, 0.75)
        patch_circle(lay, X, Y, 0, 0, x, y, r, _sand_rgb(rng.uniform(0.6, 1.0)), 1.0)
    # faint dust sheath
    sheath = np.exp(-((X - CX) / 3.2) ** 2) * alive * 0.18
    lay.under(_flat(X.shape, (240, 214, 160), sheath))
    lay.mask(cov(I + 0.2))
    return lay


def _flat(shape, colour, alpha):
    l = Layer(shape)
    l.paint(colour, alpha)
    return l


# ---------------------------------------------------------------- glass
def render_glass_back(X, Y, G, I):
    lay = Layer(X.shape)
    inside = cov(G)
    lay.paint((30, 24, 18), inside * 0.17)
    # darker toward the far wall's silhouette, like looking through more glass
    edge = np.exp(np.minimum(I, 0) / 5.0) * cov(I)
    lay.paint((44, 32, 22), edge * 0.30)
    # the far wall's own faint highlight, mirrored to the right
    for cy in (TOP_CY, BOT_CY):
        u, v = (X - CX) / BULB_RX, (Y - cy) / BULB_RY
        r, ang = np.hypot(u, v), np.arctan2(v, u)
        band = np.exp(-((r - 0.8) / 0.06) ** 2) * np.exp(-(ang_diff(ang, 0.35) / 0.5) ** 2)
        lay.paint((200, 214, 220), band * 0.10 * cov(I))
    return lay


def render_glass_front(X, Y, G, I):
    lay = Layer(X.shape)
    gy, gx = np.gradient(G)
    gl = np.hypot(gx, gy) + 1e-9
    nxo, nyo = gx / gl, gy / gl
    lit = np.clip(-(nxo * 0.55 + nyo * 0.83), 0.0, 1.0)              # light dir (-0.55,-0.83) in the plane

    # Fresnel: the glass gets more reflective toward the wall
    fres = np.exp(np.minimum(I, 0) / 6.0) * cov(I)
    lay.paint((214, 230, 238), fres * (0.10 + 0.14 * lit))
    # the wall itself
    wall = cov(G) * (1.0 - cov(I))
    wall_col = np.stack([0.80 + 0.18 * lit, 0.86 + 0.13 * lit, 0.90 + 0.10 * lit], axis=-1)
    lay.paint(wall_col, wall * (0.30 + 0.55 * lit))
    # inner wall edge: a thin bright line where light refracts through the wall
    inner = np.exp(-((I) / 0.6) ** 2)
    lay.paint((255, 250, 236), inner * 0.35 * (0.3 + 0.7 * lit) * cov(G))
    # silhouette: a dark hairline so the glass reads on bright backgrounds
    outline = np.exp(-((G + 0.2) / 0.55) ** 2)
    lay.paint((36, 24, 14), outline * 0.55 * (1.0 - 0.6 * lit))

    for cy, hot in ((TOP_CY, 1.0), (BOT_CY, 0.75)):
        u, v = (X - CX) / BULB_RX, (Y - cy) / BULB_RY
        r, ang = np.hypot(u, v), np.arctan2(v, u)
        inside = cov(I)
        # long specular arc on the left
        arc = np.exp(-((r - 0.72) / 0.075) ** 2) * np.exp(-(ang_diff(ang, -2.72) / 0.42) ** 4)
        lay.paint((255, 252, 244), arc * 0.62 * inside * hot)
        arc2 = np.exp(-((r - 0.53) / 0.025) ** 2) * np.exp(-(ang_diff(ang, -2.9) / 0.32) ** 4)
        lay.paint((255, 252, 244), arc2 * 0.38 * inside * hot)
        # hot spot with halo
        hs = np.hypot(u + 0.40, v + 0.58)
        lay.paint((255, 246, 222), np.exp(-(hs / 0.16) ** 2) * 0.28 * inside * hot)
        lay.paint((255, 255, 255), cov((hs - 0.055) * BULB_RX) * 0.95 * inside * hot)
        lay.paint((255, 255, 255), cov((np.hypot(u + 0.28, v + 0.70) - 0.022) * BULB_RX) * 0.8 * inside * hot)
        # cool rim light on the right
        rim = np.exp(-((r - 0.91) / 0.045) ** 2) * np.exp(-(ang_diff(ang, 0.2) / 0.85) ** 2)
        lay.paint((176, 220, 255), rim * 0.42 * inside)
        # a soft window reflection, upper right, with its cross bar
        win = cov((sd_rbox(u, v, 0.43, -0.30, 0.13, 0.22, 0.05)) * BULB_RX, soft=3.0)
        bar = cov((np.minimum(np.abs(u - 0.43), np.abs(v + 0.30)) - 0.012) * BULB_RX)
        lay.paint((236, 244, 255), win * (1.0 - bar) * 0.07 * inside)
        # warm bounce from the sand at the bottom of the bulb
        bounce = np.exp(-((r - 0.86) / 0.08) ** 2) * np.exp(-(ang_diff(ang, 1.75) / 0.6) ** 2)
        lay.paint((255, 196, 120), bounce * 0.16 * inside)
    # neck highlight
    neck = np.exp(-((X - (CX - 2.0)) / 0.7) ** 2) * smoothstep(170, 182, Y) * (1 - smoothstep(202, 214, Y))
    lay.paint((255, 255, 250), neck * 0.55 * cov(G))
    # contact shadows under the collars
    sh = (1.0 - smoothstep(57.0, 72.0, Y)) + smoothstep(312.0, 327.0, Y)
    lay.paint((20, 12, 6), np.clip(sh, 0, 1) * 0.42 * cov(G))
    return lay


# ---------------------------------------------------------------- frame (brass, bone, enamel)
def bump(t, c, w):
    return np.exp(-((t - c) / w) ** 2)


class Part:
    """One frame element: coverage, height field and colour; composited in painter's order with a contact shadow."""

    def __init__(self, cover, colour, shadow=0.55):
        self.cover, self.colour, self.shadow = cover, colour, shadow


def brass_colour(h, rng_field, cavity=None, spec=0.9):
    nx, ny, nz = normals(h)
    c = shade(nx, ny, nz, BRASS, spec_pow=42.0, spec=spec, env=0.38)
    c *= (1.0 + 0.06 * rng_field)[..., None]
    if cavity is not None:
        c *= (1.0 - 0.45 * np.clip(cavity, 0, 1))[..., None]
    return c


def bone_colour(h, grain, cavity=None):
    nx, ny, nz = normals(h)
    c = shade(nx, ny, nz, BONE, spec_pow=18.0, spec=0.30, env=0.25)
    c *= (1.0 + 0.10 * grain)[..., None]
    if cavity is not None:
        c *= (1.0 - 0.40 * np.clip(cavity, 0, 1))[..., None]
    return c


def cavity_of(h, r=2.0):
    return np.clip((blur(h, r * SS) - h) / 1.2, 0.0, 1.0)


def maw_medallion(X, Y, cx, cy, R, teeth, wear):
    """Raised brass ring around a sunk red enamel field with a ring of bone teeth pointing in to a black throat:
    the sandworm's maw."""
    d = np.hypot(X - cx, Y - cy)
    ang = np.arctan2(Y - cy, X - cx)
    ring_in = R * 0.76
    c_all = cov(d - R)
    ring = np.clip(1.0 - ((d - (R + ring_in) / 2) / ((R - ring_in) / 2)) ** 2, 0, 1)
    h_ring = 2.4 * np.sqrt(ring) + 1.0 * smoothstep(R, R - 1.2, d)
    # bead ring on the outer edge
    beads = np.cos(ang * (teeth * 2)) * 0.5 + 0.5
    h_ring += 0.5 * beads * ring
    throat = R * 0.30
    sector = 2 * math.pi / teeth
    a_loc = (ang + sector / 2) % sector - sector / 2
    span = (d - throat) / (ring_in - throat)
    tw = 0.25 + 3.4 * np.clip(span, 0, 1) ** 1.3 * (R / 16.0)
    tooth = cov(np.abs(a_loc) * d - tw) * cov(d - ring_in) * cov(throat - d)
    h_tooth = 1.6 * tooth * np.clip(1.15 - span, 0.3, 1.0) * np.sqrt(np.clip(1.0 - (np.abs(a_loc) * d / np.maximum(tw, 0.3)) ** 2, 0, 1))
    h = np.where(d < ring_in, -0.6 + h_tooth, h_ring)
    col_brass = brass_colour(h, wear)
    col_enamel = shade(*normals(h), ENAMEL, spec_pow=60.0, spec=0.7, env=0.3)
    # a soft radial shading on the enamel: darker toward the throat
    col_enamel *= (0.55 + 0.45 * smoothstep(throat, ring_in, d))[..., None]
    col_bone = bone_colour(h + 1.5, wear)
    col_throat = np.zeros(X.shape + (3,))
    col = np.where((d < ring_in)[..., None], col_enamel, col_brass)
    col = np.where((tooth > 0.5)[..., None], col_bone, col)
    tcov = cov(d - throat)
    col = col * (1 - tcov[..., None]) + col_throat * tcov[..., None]
    # inner rim of the throat catches a little light
    col += (np.exp(-((d - throat) / 0.5) ** 2) * 0.25)[..., None] * np.array([1.0, 0.7, 0.4])
    return c_all, np.clip(col, 0, 1)


def render_frame(X, Y):
    rng = np.random.default_rng(4242)
    wear = fbm(X.shape, 24, rng, 4)
    grain_v = fbm((X.shape[0] // 8, X.shape[1]), 30, rng, 3)       # stretched vertically for bone streaks
    grain_v = np.asarray(Image.fromarray(grain_v.astype(np.float32), "F").resize((X.shape[1], X.shape[0]),
                                                                                  Image.BICUBIC))
    parts = []

    # pillars (painted first: the plates sit on their ends)
    for px in (36.0, 220.0):
        t = np.abs(Y - NECK_Y)
        r = (4.4 + 4.6 * bump(t, 137.5, 3.0) + 2.8 * bump(t, 129.5, 1.8) + 5.6 * bump(t, 0, 5.5)
             + 2.2 * bump(t, 9.5, 1.5) + 3.4 * bump(t, 78, 21) + 1.4 * bump(t, 112, 2.0) + 1.2 * bump(t, 46, 1.6))
        dx = X - px
        inside_y = cov(50.0 - Y) * cov(Y - 334.0)
        c = cov(np.abs(dx) - r) * inside_y
        h = np.sqrt(np.clip(r * r - dx * dx, 0, None))
        is_brass = ((t > 125) | (t < 12) | (np.abs(t - 112) < 2.6) | (np.abs(t - 46) < 2.2)).astype(np.float64)
        theta = np.arcsin(np.clip(dx / np.maximum(r, 1e-3), -1, 1))
        flute = 0.5 + 0.5 * np.sin(theta * 5.0 + Y * 0.42 * np.sign(px - CX))
        h_bone = h - 0.55 * flute * (1 - is_brass)
        cav = cavity_of(h_bone, 1.0)
        col = brass_colour(h, wear) * is_brass[..., None] + bone_colour(h_bone, grain_v, cav) * (1 - is_brass)[..., None]
        # occlusion where the pillar meets the plates
        ao = smoothstep(50, 62, Y) * (1 - smoothstep(322, 334, Y))
        col *= (0.55 + 0.45 * ao)[..., None]
        parts.append(Part(c, col, 0.6))

    # finials on the plate ends
    def sphere(cx, cy, r, mat="brass"):
        d2 = (X - cx) ** 2 + (Y - cy) ** 2
        h = np.sqrt(np.clip(r * r - d2, 0, None))
        c = cov(np.sqrt(d2) - r)
        col = brass_colour(h, wear) if mat == "brass" else bone_colour(h, grain_v)
        return Part(c, col)

    # plates
    def plate(cy, sign):
        d = sd_rbox(X, Y, CX, cy, 110.0, 10.0, 5.0)
        c = cov(d)
        h = 5.0 * smoothstep(0.0, 3.5, -d)
        band = sd_rbox(X, Y, CX, cy, 94.0, 4.2, 2.0)
        bandc = cov(band)
        h -= 1.5 * cov(band, soft=2.0)
        # brass lozenges set into the bone band, with dots between
        xm = ((X - CX) + 7.5) % 15.0 - 7.5
        loz = (np.abs(xm) / 5.2 + np.abs(Y - cy) / 3.6 - 1.0) * 3.0
        lozc = cov(loz) * bandc
        h += 1.6 * np.clip(-loz / 2.0, 0, 1) * bandc
        xd = ((X - CX)) % 15.0 - 7.5
        dots = cov(np.hypot(np.where(np.abs(xd) > 6.0, 7.5 - np.abs(xd), 9.0), Y - cy) - 1.0) * bandc
        h += 0.8 * dots
        # incised lines along the flat
        for gy in (cy - 6.6, cy + 6.6):
            h -= 0.7 * cov(np.abs(Y - gy) - 0.45) * cov(np.abs(X - CX) - 100.0)
        cav = cavity_of(h, 1.2)
        is_bone = bandc * (1 - lozc) * (1 - dots)
        col = brass_colour(h, wear, cav) * (1 - is_bone)[..., None] + bone_colour(h, grain_v, cav) * is_bone[..., None]
        return Part(c, col)

    def lip(cy, rivet_y):
        d = sd_rbox(X, Y, CX, cy, 92.0, 6.0, 4.0)
        c = cov(d)
        h = 6.0 * smoothstep(0.0, 3.0, -d)
        for k in range(5):
            for s in (-1, 1):
                rx = CX + s * (28.0 + 15.0 * k)
                dd = np.hypot(X - rx, Y - rivet_y)
                h += np.sqrt(np.clip(1.9 ** 2 - dd * dd, 0, None)) * 0.9
        cav = cavity_of(h, 1.0)
        return Part(c, brass_colour(h, wear, cav))

    def collar(cy):
        d = sd_rbox(X, Y, CX, cy, 46.0, 5.0, 3.0)
        c = cov(d)
        h = 5.0 * smoothstep(0.0, 2.5, -d)
        h -= 0.9 * cov(np.abs(Y - cy) - 0.5)
        return Part(c, brass_colour(h, wear, cavity_of(h, 1.0)))

    parts.append(plate(40.0, -1))
    parts.append(plate(344.0, 1))
    parts.append(collar(55.0))
    parts.append(collar(329.0))
    parts.append(lip(24.0, 24.0))
    parts.append(lip(360.0, 360.0))
    for x in (20.0, 236.0):
        for y in (40.0, 344.0):
            parts.append(sphere(x, y, 9.0))
        parts.append(sphere(x, 28.5, 3.6))
        parts.append(sphere(x, 355.5, 3.6))
    # bun feet
    parts.append(sphere(42.0, 372.0, 9.5))
    parts.append(sphere(214.0, 372.0, 9.5))
    # small brass knobs either side of the crest
    for s in (-1, 1):
        parts.append(sphere(CX + s * 22.0, 17.5, 3.4))
        parts.append(sphere(CX + s * 30.0, 18.5, 2.2))
    c, col = maw_medallion(X, Y, CX, 18.0, 16.5, 9, wear)
    parts.append(Part(c, col, 0.7))
    c, col = maw_medallion(X, Y, CX, 368.0, 12.0, 8, wear)
    parts.append(Part(c, col, 0.7))

    lay = Layer(X.shape)
    for p in parts:
        sh = blur(p.cover, 2.2 * SS)
        sh = np.roll(np.roll(sh, int(1.2 * SS), axis=1), int(2.0 * SS), axis=0)
        lay.paint((14, 8, 3), sh * p.shadow * (1.0 - p.cover))
        lay.paint(p.colour, p.cover)
    return lay


# ---------------------------------------------------------------- cracks
def crack_paths():
    """Random-walk cracks from three impact points, with branches. Each path is a list of points; stage k draws each
    path up to its budget for that stage, so later stages contain the earlier ones."""
    rng = np.random.default_rng(612)

    def inside(x, y):
        return float(glass_sdf(np.array(x), np.array(y))) < -1.2

    def walk(x, y, a, length, depth=0):
        pts = [(x, y)]
        branches = []
        s = 0.0
        while s < length:
            step = rng.uniform(3.5, 8.0)
            a += rng.normal(0, 0.30)
            nx, ny = x + math.cos(a) * step, y + math.sin(a) * step
            if not inside(nx, ny):
                break
            x, y = nx, ny
            s += step
            pts.append((x, y))
            if depth < 2 and rng.random() < 0.20:
                ba = a + rng.choice([-1, 1]) * rng.uniform(0.5, 1.1)
                branches.append((s, walk(x, y, ba, length * rng.uniform(0.25, 0.5), depth + 1)))
        return {"pts": pts, "branches": branches}

    impacts = {
        "a": (166.0, 90.0, 10, 120.0),
        "b": (94.0, 292.0, 7, 85.0),
        "c": (131.0, 172.0, 4, 40.0),
    }
    out = {}
    for key, (x, y, n, L) in impacts.items():
        paths = []
        for i in range(n):
            a = 2 * math.pi * i / n + rng.uniform(-0.25, 0.25)
            paths.append(walk(x, y, a, L * rng.uniform(0.7, 1.0)))
        out[key] = (x, y, paths)
    return out


BUDGET = {  # per stage: impact -> (radial length, number of radials used, web ring radii)
    1: {"a": (24.0, 5, ())},
    2: {"a": (58.0, 10, (11.0,)), "b": (26.0, 5, ()), },
    3: {"a": (95.0, 10, (11.0, 24.0, 40.0)), "b": (60.0, 7, (10.0, 22.0)), "c": (30.0, 4, ())},
}


def trunc(pts, L):
    out = [pts[0]]
    s = 0.0
    for p, q in zip(pts[:-1], pts[1:]):
        seg = math.dist(p, q)
        if s + seg >= L:
            t = (L - s) / seg
            out.append((p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t))
            return out
        s += seg
        out.append(q)
    return out


def point_at(pts, L):
    t = trunc(pts, L)
    return t[-1], len(t) == len(pts) and L > sum(math.dist(p, q) for p, q in zip(pts[:-1], pts[1:]))


def render_cracks(X, Y, G, stage, paths):
    hi = Image.new("L", (W * SS, H * SS), 0)
    lo = Image.new("L", (W * SS, H * SS), 0)
    dh, dl = ImageDraw.Draw(hi), ImageDraw.Draw(lo)

    def line(pts, width):
        sp = [(x * SS, y * SS) for x, y in pts]
        if len(sp) > 1:
            dh.line(sp, fill=255, width=max(1, int(round(width * SS))), joint="curve")
            dl.line([(x + 0.7 * SS, y + 0.9 * SS) for x, y in sp], fill=255, width=max(1, int(round(width * 1.6 * SS))),
                    joint="curve")

    def draw_path(p, L, width):
        line(trunc(p["pts"], L), width)
        for s0, b in p["branches"]:
            if L > s0:
                draw_path(b, L - s0, width * 0.7)

    for key, (L, n, rings) in BUDGET[stage].items():
        x0, y0, paths_k = paths[key]
        for i, p in enumerate(paths_k[:n]):
            draw_path(p, L, 0.7 if i % 2 == 0 else 0.5)
        for rr in rings:
            ring = []
            for p in paths_k[:n]:
                pt, ended = point_at(p["pts"], rr)
                ring.append(None if ended else pt)
            for i in range(len(ring)):
                a, b = ring[i], ring[(i + 1) % len(ring)]
                if a is not None and b is not None:
                    mx, my = (a[0] + b[0]) / 2, (a[1] + b[1]) / 2
                    # sag the web strand toward the impact
                    mx += (x0 - mx) * 0.12
                    my += (y0 - my) * 0.12
                    line([a, (mx, my), b], 0.55)
    hm = np.asarray(hi, dtype=np.float64) / 255.0
    lm = np.asarray(lo, dtype=np.float64) / 255.0
    clip = cov(G + 0.3)
    lay = Layer(X.shape)
    lay.paint((22, 14, 8), lm * 0.55 * clip)
    glow = blur(hm, 1.6 * SS)
    lay.paint((255, 244, 214), np.clip(glow * 1.2, 0, 1) * 0.30 * clip)
    lay.paint((255, 255, 250), hm * 0.85 * clip)
    # impact stars: chipped bright points
    for key in BUDGET[stage]:
        x0, y0, _ = paths[key]
        s = {1: 0.7, 2: 1.0, 3: 1.25}[stage]
        d = np.hypot(X - x0, Y - y0)
        lay.paint((255, 255, 255), np.exp(-(d / (2.4 * s)) ** 2) * 0.9 * clip)
        lay.paint((255, 230, 180), np.exp(-(d / (7.0 * s)) ** 2) * 0.25 * clip)
    return lay


# ---------------------------------------------------------------- glow and masks
def render_glow(X, Y, G, I):
    outer = Layer(X.shape)
    o = np.exp(-np.maximum(G, 0) / 13.0) * (1.0 - cov(G)) + cov(G) * 0.0
    col = ramp(np.clip(1.0 - np.maximum(G, 0) / 40.0, 0, 1), [(0.0, (255, 70, 10)), (1.0, (255, 176, 70))])
    outer.paint(col, o * 0.85)
    inner = Layer(X.shape)
    e = (0.25 + 0.75 * np.exp(np.minimum(I, 0) / 7.0)) * cov(I)
    neck = np.exp(-((Y - NECK_Y) / 26.0) ** 2) * cov(I)
    inner.paint((255, 190, 100), np.clip(e * 0.55 + neck * 0.4, 0, 1))
    return outer, inner


# ---------------------------------------------------------------- shatter
def render_shatter(glass_look, Gsrc, sand_full_bot, field, paths):
    """Shards of the cracked glass fly apart while the bottom heap slumps onto the base plate."""
    rng = np.random.default_rng(2024)
    # Voronoi seeds inside the glass, denser around impact a
    seeds = []
    while len(seeds) < 54:
        if rng.random() < 0.4:
            x, y = rng.normal(166, 18), rng.normal(92, 16)
        else:
            x, y = rng.uniform(52, 204), rng.uniform(50, 334)
        if float(glass_sdf(np.array(x), np.array(y))) < -0.5:
            seeds.append((x, y))
    seeds = np.array(seeds)
    Xs, Ys = grid(W, H)
    d1 = np.full(Xs.shape, 1e9)
    d2 = np.full(Xs.shape, 1e9)
    lab = np.zeros(Xs.shape, dtype=np.int32)
    for i, (sx, sy) in enumerate(seeds):
        d = np.hypot(Xs - sx, Ys - sy)
        closer = d < d1
        d2 = np.where(closer, d1, np.minimum(d2, d))
        d1 = np.where(closer, d, d1)
        lab = np.where(closer, i, lab)
    edge = np.exp(-((d2 - d1) / 0.9) ** 2)

    # shard look: the cracked glass plus bright fracture edges, a little more opaque than the glass itself
    rgb = glass_look.rgb.copy()
    a = glass_look.a.copy()
    gcov = cov(Gsrc)
    a = np.clip(a * 1.25 + 0.12 * gcov, 0, 1) * gcov
    rgb = np.clip(rgb * 1.15, 0, 1) * gcov[..., None]
    e = edge * gcov
    rgb = rgb * (1 - e[..., None]) + e[..., None] * np.array([1.0, 0.98, 0.92])
    a = np.maximum(a, e * 0.95)

    rng = np.random.default_rng(99)
    shards = []
    for i, (sx, sy) in enumerate(seeds):
        m = lab == i
        if not m.any():
            continue
        ys, xs = np.nonzero(m)
        cx, cy = xs.mean() / SS, ys.mean() / SS
        rad = math.hypot((xs.max() - xs.min()) / SS, (ys.max() - ys.min()) / SS) / 2 + 2
        dx, dy = cx - CX, cy - NECK_Y
        dn = math.hypot(dx, dy) + 1e-6
        near_a = math.exp(-math.hypot(cx - 166, cy - 92) / 50.0)
        speed = rng.uniform(70, 160) * (1.0 + 0.8 * near_a)
        vx = dx / dn * speed + rng.normal(0, 40)
        vy = dy / dn * speed * 0.7 - rng.uniform(60, 170)
        shards.append(dict(i=i, c=(cx, cy), rad=rad, v=(vx, vy), w=rng.normal(0, 7.0), ph=rng.uniform(0, 6.28),
                           y0=int(ys.min()), y1=int(ys.max()) + 1, x0=int(xs.min()), x1=int(xs.max()) + 1))

    # sand heap profile (thickness per column) at full, and the spill it slumps into
    sand_a = sand_full_bot.a
    cols = (sand_a > 0.5)
    top_y = np.where(cols.any(axis=0), cols.argmax(axis=0), sand_a.shape[0]) / SS
    xs_c = (np.arange(W * SS) + 0.5) / SS
    full_thick = np.clip(332.0 - top_y, 0, None) * cols.any(axis=0)
    area = full_thick.sum() / SS * 0.38   # most of the sand pours off the base and out of view
    spill_half = 104.0
    prof = np.clip(1.0 - ((xs_c - CX) / spill_half) ** 2, 0, None) ** 1.25
    spill_thick = prof * area / (prof.sum() / SS)
    border = None

    grains = []
    for _ in range(520):
        src = rng.random()
        if src < 0.7:
            x, y = CX + rng.normal(0, 30), rng.uniform(290, 330)
        else:
            x, y = CX + rng.normal(0, 4), rng.uniform(176, 210)
        dx = x - CX
        grains.append((x, y, dx * rng.uniform(1.5, 3.5) + rng.normal(0, 50), -rng.uniform(40, 190),
                       rng.uniform(0.45, 1.1), rng.uniform(0.55, 1.05)))
    puffs = [(CX + rng.normal(0, 40), rng.uniform(250, 330), rng.uniform(10, 22), rng.uniform(0, 1)) for _ in range(14)]

    frames = []
    ox, oy = SHATTER_OFF
    Xo, Yo = grid(SHATTER_W, SHATTER_H, ox, oy)
    for f in range(SHATTER_FRAMES):
        t = f / (SHATTER_FRAMES - 1)        # 0..1 over the whole effect
        tt = t * 0.9                          # "seconds"
        lay = Layer(Xo.shape)
        # sand: slump from heap to spill
        k = smoothstep(0.05, 0.8, t)
        thick = full_thick * (1 - k) + spill_thick * k
        base = 332.0 + 2.0 * k
        thick_g = np.interp(Xo[0], xs_c, thick)[None, :]
        surf = base - thick_g
        m = cov(surf - Yo) * cov(Yo - base) * (thick_g > 0.05)
        depth = Yo - surf
        hw = np.maximum(np.interp(Xo[0], xs_c, (thick > 0.05) * 1.0).sum() / SS / 2, 5.0)
        fake_I = -np.minimum(np.minimum(depth, base - Yo) * 2.0, 8.0)
        fld = _ShatterField(Xo.shape, field)
        lay.paint(sand_colour(Xo, Yo, fake_I, depth, fld, strata=True, hw=hw), m)
        # dust cloud
        for (px, py, pr, ph) in puffs:
            r = pr * (0.6 + 1.6 * t)
            al = 0.28 * (1 - t) ** 1.5 * smoothstep(0.0, 0.12, t + 0.02)
            dd = np.hypot(Xo - px, (Yo - py + 18 * t) * 1.15)
            lay.paint((214, 176, 120), np.exp(-(dd / r) ** 2) * al)
        # flying grains
        for (gx, gy, vx, vy, r, lum) in grains:
            x = gx + vx * tt
            y = gy + vy * tt + 0.5 * 520.0 * tt * tt
            if y > 340 or t == 0:
                continue
            al = 1.0 - smoothstep(0.6, 1.0, t)
            if abs(x - CX) > 200:
                continue
            patch_circle(lay, Xo, Yo, ox, oy, x, y, r, _sand_rgb(lum), al)
        # shards
        for s in shards:
            if t == 0:
                break
            cx, cy = s["c"]
            px = cx + s["v"][0] * tt
            py = cy + s["v"][1] * tt + 0.5 * 600.0 * tt * tt
            th = s["w"] * tt
            fade = 1.0 - smoothstep(0.45, 1.0, t)
            if fade <= 0:
                continue
            R = s["rad"] + 1
            x0 = int(max((px - R - ox) * SS, 0)); x1 = int(min((px + R - ox) * SS, SHATTER_W * SS))
            y0 = int(max((py - R - oy) * SS, 0)); y1 = int(min((py + R - oy) * SS, SHATTER_H * SS))
            if x1 <= x0 or y1 <= y0:
                continue
            gx_, gy_ = Xo[y0:y1, x0:x1], Yo[y0:y1, x0:x1]
            c, sn = math.cos(-th), math.sin(-th)
            sx_ = c * (gx_ - px) - sn * (gy_ - py) + cx
            sy_ = sn * (gx_ - px) + c * (gy_ - py) + cy
            ix = np.clip((sx_ * SS).astype(int), 0, W * SS - 1)
            iy = np.clip((sy_ * SS).astype(int), 0, H * SS - 1)
            valid = (sx_ >= 0) & (sx_ < W) & (sy_ >= 0) & (sy_ < H) & (lab[iy, ix] == s["i"])
            sa = a[iy, ix] * valid * fade
            glint = 0.75 + 0.6 * abs(math.cos(th * 2.0 + s["ph"]))
            srgb = np.clip(rgb[iy, ix] / np.maximum(a[iy, ix], 1e-6)[..., None] * glint, 0, 1)
            sub = Layer(sa.shape)
            sub.paint(srgb, sa)
            lay.rgb[y0:y1, x0:x1] = sub.rgb + lay.rgb[y0:y1, x0:x1] * (1 - sub.a[..., None])
            lay.a[y0:y1, x0:x1] = sub.a + lay.a[y0:y1, x0:x1] * (1 - sub.a)
        if t == 0:
            # the instant of breaking: the whole cracked glass, blazing
            whole = Layer(Xo.shape)
            sl = (slice(-oy * SS, (-oy + H) * SS), slice(-ox * SS, (-ox + W) * SS))
            whole.rgb[sl] = rgb
            whole.a[sl] = a
            lay.over(whole)
        # flash
        fl = math.exp(-t / 0.10)
        if fl > 0.02:
            for (fx, fy, fr, fa) in ((166, 90, 70, 1.0), (CX, NECK_Y, 120, 0.6)):
                dd = np.hypot(Xo - fx, Yo - fy)
                lay.paint((255, 248, 226), np.exp(-(dd / (fr * (0.6 + t * 2))) ** 2) * fl * fa * 0.9)
            # star rays from the impact
            ang = np.arctan2(Yo - 90, Xo - 166)
            rays = np.clip(np.cos(ang * 6.0) ** 24, 0, 1) * np.exp(-np.hypot(Xo - 166, Yo - 90) / 90.0)
            lay.paint((255, 255, 240), rays * fl * 0.8)
        if border is None:
            mx = np.minimum(Xo - ox, ox + SHATTER_W - Xo)
            my = np.minimum(Yo - oy, oy + SHATTER_H - Yo)
            border = smoothstep(0.0, 28.0, np.minimum(mx, my))
        lay.mask(border)
        frames.append(lay)
    spill = Layer(Xs.shape)
    thick = spill_thick
    base = 334.0
    thick_g = np.interp(Xs[0], xs_c, thick)[None, :]
    surf = base - thick_g
    m = cov(surf - Ys) * cov(Ys - base) * (thick_g > 0.05)
    depth = Ys - surf
    fake_I = -np.minimum(np.minimum(depth, base - Ys) * 2.0, 8.0)
    spill.paint(sand_colour(Xs, Ys, fake_I, depth, field, strata=True, hw=spill_half), m)
    return frames, spill


def patch_circle(lay, Xo, Yo, ox, oy, x, y, r, colour, alpha):
    """Paint one anti-aliased disc, touching only the samples around it."""
    x0 = int(max((x - r - 1 - ox) * SS, 0)); x1 = int(min((x + r + 1 - ox) * SS, Xo.shape[1]))
    y0 = int(max((y - r - 1 - oy) * SS, 0)); y1 = int(min((y + r + 1 - oy) * SS, Xo.shape[0]))
    if x1 <= x0 or y1 <= y0:
        return
    sub = Layer((y1 - y0, x1 - x0))
    sub.paint(colour, cov(np.hypot(Xo[y0:y1, x0:x1] - x, Yo[y0:y1, x0:x1] - y) - r) * alpha)
    lay.rgb[y0:y1, x0:x1] = sub.rgb + lay.rgb[y0:y1, x0:x1] * (1 - sub.a[..., None])
    lay.a[y0:y1, x0:x1] = sub.a + lay.a[y0:y1, x0:x1] * (1 - sub.a)


def _sand_rgb(lum):
    c = ramp(np.array([[lum]]), SAND)[0, 0]
    return tuple(int(v * 255) for v in c)


class _ShatterField:
    """Sand noise fields for the shatter canvas (a different size from the hourglass canvas)."""
    cache = {}

    def __init__(self, shape, base):
        if shape not in _ShatterField.cache:
            rng = np.random.default_rng(5150)
            f = blur(rng.standard_normal(shape), 0.7)
            f /= np.abs(f).max()
            g = (rng.random(shape) > 0.9975).astype(np.float64)
            _ShatterField.cache[shape] = (f, fbm(shape, 60, rng, 3), fbm(shape, 12, rng, 2), blur(g, 0.8) * 6.0,
                                          fbm(shape, 9, rng, 2))
        self.fine, self.mid, self.big, self.glint, self.strata = _ShatterField.cache[shape]


# ---------------------------------------------------------------- water drop
def sd_drop(X, Y, cx, cy_bottom, r1, r2, h):
    """Uneven capsule (iq), pointing up: the big circle at (cx, cy_bottom), the tip circle h above it."""
    px = np.abs(X - cx)
    py = cy_bottom - Y
    b = (r1 - r2) / h
    a = math.sqrt(1 - b * b)
    k = px * (-b) + py * a
    d1 = np.hypot(px, py) - r1
    d2 = np.hypot(px, py - h) - r2
    d3 = px * a + py * b - r1
    return np.where(k < 0, d1, np.where(k > a * h, d2, d3))


def render_drop(fill):
    X, Y = grid(DROP_W, DROP_H)
    cx, cyb = DROP_W / 2, 84.0
    D = sd_drop(X, Y, cx, cyb, 31.0, 1.2, 66.0)
    I = D + 3.0
    lay = Layer(X.shape)
    # soft shadow
    sh = blur(cov(D), 3.0 * SS)
    lay.paint((0, 0, 0), np.roll(sh, int(3 * SS), axis=0) * 0.45)
    # dark glass interior
    lay.paint((10, 16, 24), cov(D) * 0.55)
    # water
    if fill > 0:
        top, bot = 22.0, 115.0
        level = bot - (bot - top) * fill
        wave = 1.2 * np.sin(X * 0.33 + fill * 9.0) + 0.6 * np.sin(X * 0.71 + 1.3)
        surf = level + wave * (fill < 0.999)
        wm = cov(I + 0.3) * cov(surf - Y)
        u = np.clip((X - cx) / 30.0, -1, 1)
        depth = np.clip((Y - surf) / 60.0, 0, 1)
        lum = 0.35 + 0.45 * np.sqrt(1 - u * u) - 0.15 * u - 0.25 * depth
        col = ramp(lum, [(0.0, (4, 22, 52)), (0.4, (16, 70, 140)), (0.7, (40, 140, 210)), (1.0, (150, 220, 255))])
        lay.paint(col, wm)
        # caustic ripples
        rng = np.random.default_rng(8)
        cn = fbm(X.shape, 10, rng, 3)
        caus = np.clip(1.0 - np.abs(cn) * 9.0, 0, 1) ** 3
        lay.paint((170, 230, 255), caus * wm * 0.35)
        # bright surface line and its meniscus
        line = np.exp(-((Y - surf) / 0.7) ** 2) * cov(I + 0.3) * (fill < 0.999)
        lay.paint((220, 248, 255), line * 0.9)
        # bubbles
        for _ in range(9):
            bx, by, br = cx + rng.normal(0, 10), rng.uniform(surf.min() + 8, 110), rng.uniform(0.8, 2.0)
            if by < level + 4:
                continue
            ring = np.exp(-((np.hypot(X - bx, Y - by) - br) / 0.45) ** 2)
            lay.paint((200, 240, 255), ring * 0.55 * wm)
    # glass: wall, Fresnel, highlights
    gy, gx = np.gradient(D)
    gl = np.hypot(gx, gy) + 1e-9
    lit = np.clip(-(gx / gl * 0.55 + gy / gl * 0.83), 0, 1)
    wall = cov(D) * (1 - cov(I))
    lay.paint((200, 228, 245), wall * (0.35 + 0.55 * lit))
    lay.paint((214, 236, 250), np.exp(np.minimum(I, 0) / 5.0) * cov(I) * 0.18)
    lay.paint((10, 20, 30), np.exp(-((D + 0.2) / 0.6) ** 2) * 0.6 * (1 - 0.6 * lit))
    u, v = (X - cx) / 31.0, (Y - cyb) / 31.0
    r, ang = np.hypot(u, v), np.arctan2(v, u)
    arc = np.exp(-((r - 0.72) / 0.08) ** 2) * np.exp(-(ang_diff(ang, -2.6) / 0.5) ** 4)
    lay.paint((255, 255, 255), arc * 0.7 * cov(I))
    lay.paint((255, 255, 255), cov(np.hypot(X - (cx - 12), Y - 62.0) - 2.6) * 0.95)
    lay.paint((255, 255, 255), cov(np.hypot(X - (cx - 7), Y - 55.0) - 1.2) * 0.8)
    # streak up the tip
    tip = np.exp(-((X - (cx - 3.5 + (Y - 30) * -0.12)) / 0.8) ** 2) * smoothstep(24, 32, Y) * (1 - smoothstep(42, 52, Y))
    lay.paint((255, 255, 255), tip * 0.6 * cov(I))
    rim = np.exp(-((r - 0.9) / 0.05) ** 2) * np.exp(-(ang_diff(ang, 0.3) / 0.8) ** 2)
    lay.paint((150, 210, 255), rim * 0.45 * cov(I))
    return lay


# ---------------------------------------------------------------- readout plate
def render_plate():
    X, Y = grid(PLATE_W, PLATE_H)
    cx, cy = PLATE_W / 2, PLATE_H / 2
    rng = np.random.default_rng(31)
    wear = fbm(X.shape, 20, rng, 3)
    lay = Layer(X.shape)
    outer = sd_rbox(X, Y, cx, cy, 92.0, 30.0, 10.0)
    # wings: scrolls on either side
    wings = []
    for s in (-1, 1):
        wings.append(sd_circle(X, Y, cx + s * 98.0, cy, 9.0))
    body = np.minimum(outer, np.minimum(*wings))
    sh = blur(cov(body), 3.0 * SS)
    lay.paint((0, 0, 0), np.roll(np.roll(sh, int(2 * SS), 0), int(1 * SS), 1) * 0.5)
    h = 6.0 * smoothstep(0.0, 4.0, -body)
    # a bead groove inside the rim
    h -= 0.9 * np.exp(-((outer + 6.0) / 0.7) ** 2)
    # wing spirals
    for s in (-1, 1):
        wx = cx + s * 98.0
        d = np.hypot(X - wx, Y - cy)
        a = np.arctan2(Y - cy, (X - wx) * s)
        spiral = np.sin(d * 1.3 - a * 1.0) * smoothstep(9.0, 6.0, d)
        h += 0.7 * spiral * cov(d - 9.0)
    # rivets
    for rx in (cx - 82.0, cx + 82.0):
        for ry in (cy - 21.0, cy + 21.0):
            d = np.hypot(X - rx, Y - ry)
            h += np.sqrt(np.clip(2.4 ** 2 - d * d, 0, None)) * 1.1
    # top crest diamond
    dd = np.abs(X - cx) / 7.0 + np.abs(Y - (cy - 26.0)) / 4.0 - 1.0
    h += 1.4 * np.clip(-dd * 3.0, 0, 1)
    col = brass_colour(h, wear, cavity_of(h, 1.2))
    lay.paint(col, cov(body))
    # recessed screen
    scr = sd_rbox(X, Y, cx, cy, 74.0, 18.0, 6.0)
    sc = cov(scr)
    inner_shadow = np.exp(np.minimum(scr, 0) / 3.0)
    base = ramp(np.clip((Y - (cy - 18)) / 36.0, 0, 1), [(0.0, (8, 6, 5)), (1.0, (30, 20, 13))])
    lay.paint(base, sc)
    lay.paint((0, 0, 0), sc * inner_shadow * 0.6)
    # bevel of the screen's lip: lower edge catches light
    lip = np.exp(-((scr - 0.3) / 0.8) ** 2) * smoothstep(cy - 4, cy + 18, Y)
    lay.paint((255, 220, 150), lip * 0.55)
    # a faint glass sheen on the screen
    sheen = smoothstep(cy - 18, cy - 4, Y) * (1 - smoothstep(cy - 6, cy - 2, Y)) * sc
    lay.paint((255, 240, 220), sheen * 0.06)
    glow = Layer(X.shape)
    glow.a = sc * (0.35 + 0.65 * np.exp(np.minimum(scr, 0) / 9.0))
    glow_img = alpha_sprite(glow.a)
    return lay, glow_img


# ---------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--preview", help="also write a preview sheet PNG here")
    args = ap.parse_args()

    X, Y = grid(W, H)
    G = glass_sdf(X, Y)
    I = G + WALL
    field = SandField(X, Y)
    files = {}

    def put(name, img, rect, note):
        save(img, OUT / name)
        files[name] = {"rect": list(rect), "note": note}
        return img

    full = (0, 0, W, H)
    # shadow
    frame = render_frame(X, Y)

    def drop_shadow(a):
        sh = Layer(X.shape)
        sh.paint((0, 0, 0), np.roll(np.roll(blur(a, 5.0 * SS), int(3 * SS), 1), int(5 * SS), 0) * 0.5)
        return sh
    put("hg_shadow.png", to_image(drop_shadow(frame.a)), full, "soft drop shadow of the frame; draw first")
    put("hg_shadow_glass.png", to_image(drop_shadow(cov(G) * (1 - frame.a))), full,
        "soft drop shadow of the glass; draw after hg_shadow, hide after the strike")
    back = render_glass_back(X, Y, G, I)
    put("hg_glass_back.png", to_image(back), full, "glass interior tint, behind the sand")
    front = render_glass_front(X, Y, G, I)
    put("hg_glass_front.png", to_image(front), full, "glass highlights, rim light, Fresnel; over the sand")
    put("hg_frame.png", to_image(frame), full, "brass and bone frame with the maw medallions; over the glass")

    tops, bots = sand_levels()
    imgs = {}
    for k in range(LEVELS):
        f = k / (LEVELS - 1)
        t = render_sand(X, Y, I, field, "top", tops[k], f)
        imgs[("top", k)] = put("hg_sand_top_%02d.png" % k, to_image(t, crop=SAND_TOP_RECT), SAND_TOP_RECT,
                               "top bulb sand, %d/15 full" % k)
        b = render_sand(X, Y, I, field, "bot", bots[k], f)
        imgs[("bot", k)] = put("hg_sand_bot_%02d.png" % k, to_image(b, crop=SAND_BOT_RECT), SAND_BOT_RECT,
                               "bottom bulb sand, %d/15 full" % k)
        if k == LEVELS - 1:
            bot_full = b
    for fr in range(STREAM_FRAMES):
        s = render_stream(X, Y, I, fr)
        put("hg_stream_%d.png" % fr, to_image(s, crop=STREAM_RECT), STREAM_RECT,
            "falling stream, frame %d of %d (loop); between the sand layers" % (fr, STREAM_FRAMES))
    paths = crack_paths()
    cracks = {}
    for st in (1, 2, 3):
        c = render_cracks(X, Y, G, st, paths)
        cracks[st] = c
        put("hg_crack_%d.png" % st, to_image(c), full, "glass cracks, stage %d (each stage contains the last)" % st)
    gout, gin = render_glow(X, Y, G, I)
    put("hg_glow.png", to_image(gout), full, "amber halo around the glass for the last 15 s; pulse its alpha")
    put("hg_glow_inner.png", to_image(gin), full, "inner ember glow of the glass; pulse with hg_glow")
    for name, rect, sel in (("hg_mask_top.png", SAND_TOP_RECT, Y < NECK_Y), ("hg_mask_bot.png", SAND_BOT_RECT, Y >= NECK_Y)):
        x0, y0, x1, y1 = rect
        a = down(cov(I) * sel)[y0:y1, x0:x1]
        put(name, alpha_sprite(a, ss=1), rect, "white bulb interior mask for tinted overlays")

    look = back.copy()
    look.over(front)
    look.over(cracks[3])
    frames, spill = render_shatter(look, G, bot_full, field, paths)
    srect = (SHATTER_OFF[0], SHATTER_OFF[1], SHATTER_OFF[0] + SHATTER_W, SHATTER_OFF[1] + SHATTER_H)
    shatter_imgs = []
    for i, fl in enumerate(frames):
        shatter_imgs.append(put("hg_shatter_%02d.png" % i, to_image(fl), srect,
                                "shatter frame %d of %d (~40 ms each); replaces glass, sand and cracks" % (i, SHATTER_FRAMES)))
    spill_img = put("hg_sand_spill.png", to_image(spill, crop=SPILL_RECT), SPILL_RECT,
                    "the spilled heap left on the base after the shatter")
    drops = []
    for k in range(DROP_FRAMES):
        d = render_drop(k / (DROP_FRAMES - 1))
        drops.append(put("hg_drop_%02d.png" % k, to_image(d), DROP_RECT,
                         "water drop countdown, %d/8 full; shown in the empty frame after the shatter" % k))
    plate, plate_glow = render_plate()
    prect = (16, 384, 16 + PLATE_W, 384 + PLATE_H)
    plate_img = put("hg_plate.png", to_image(plate), prect, "mm:ss readout plate; text centre at canvas (128, 420)")
    put("hg_plate_glow.png", plate_glow, prect, "white screen-glow mask for the plate; tint orange (last 15 s) or blue (water)")

    layout = {
        "canvas": [W, H],
        "logical": [W // 2, H // 2],
        "note": "Rects are [x0, y0, x1, y1] in canvas pixels (2x). Divide by 2 for HUD pixels at scale 1. "
                "Draw order: hg_shadow, hg_shadow_glass, hg_glow (when shown), hg_glass_back, hg_sand_top_NN, hg_stream_N, "
                "hg_sand_bot_NN, hg_glow_inner (when shown), hg_glass_front, hg_crack_N, hg_frame, then the plate; "
                "after the strike: hg_shadow, hg_frame, hg_drop_NN, hg_shatter_NN (during the shatter) or "
                "hg_sand_spill, then the plate.",
        "plateText": [128, 420],
        "files": files,
    }
    text = json.dumps(layout, indent=1)
    text = re.sub(r"\[\s*(-?\d+),\s*(-?\d+)(?:,\s*(-?\d+),\s*(-?\d+))?\s*\]",
                  lambda m: "[" + ", ".join(g for g in m.groups() if g is not None) + "]", text)
    LAYOUT.write_text(text + "\n", encoding="utf-8")

    if args.preview:
        preview(args.preview, imgs, shatter_imgs, spill_img, drops, plate_img)
    print("wrote %d textures to %s" % (len(files), OUT))


def preview(path, imgs, shatter_imgs, spill_img, drops, plate_img):
    """A sheet of HUD states over a dusky desert backdrop, at canvas size."""
    def L(n):
        return Image.open(OUT / n).convert("RGBA")

    def place(canvas, img, rect, ox, oy):
        x0, y0, x1, y1 = rect
        im = img if img.size == (x1 - x0, y1 - y0) else img.resize((x1 - x0, y1 - y0), Image.LANCZOS)
        canvas.alpha_composite(im, (ox + x0, oy + y0)) if ox + x0 >= 0 and oy + y0 >= 0 else _paste_clip(canvas, im, ox + x0, oy + y0)

    states = [
        ("3:00 to go", 15, 0, 0, None, 0.0, "3:00"),
        ("1:30", 8, 7, 2, None, 0.0, "1:30"),
        ("0:12 cracking", 1, 14, 4, 2, 0.6, "0:12"),
        ("0:02", 0, 15, 1, 3, 1.0, "0:02"),
    ]
    colw, rowh = 300, 500
    sheet_w = colw * 6 + 40
    Hd, Wd = rowh * 2 + 60, sheet_w
    yy = np.linspace(0, 1, Hd)[:, None, None]
    xx = np.linspace(0, 1, Wd)[None, :, None]
    bg = np.array([40, 52, 86]) * (1 - yy) + np.array([196, 120, 70]) * yy + 0 * xx
    dune = (yy > 0.62 + 0.05 * np.sin(xx * 9.0) + 0.03 * np.sin(xx * 23.0 + 1.0))
    bg = np.where(dune, np.array([150, 96, 52]) * (0.8 + 0.3 * yy), bg)
    sheet = Image.fromarray(np.clip(bg, 0, 255).astype(np.uint8), "RGB").convert("RGBA")
    font = _font(30)
    small = _font(16)
    lay = json.loads(LAYOUT.read_text(encoding="utf-8"))["files"]
    d = ImageDraw.Draw(sheet)
    for i, (title, top, bot, sf, crack, glow, txt) in enumerate(states):
        ox, oy = 20 + i * colw, 30
        layers = ["hg_shadow.png", "hg_shadow_glass.png"] + (["hg_glow.png"] if glow else []) + ["hg_glass_back.png", "hg_sand_top_%02d.png" % top]
        if top > 0:
            layers.append("hg_stream_%d.png" % sf)
        layers.append("hg_sand_bot_%02d.png" % bot)
        if glow:
            layers.append("hg_glow_inner.png")
        layers.append("hg_glass_front.png")
        if crack:
            layers.append("hg_crack_%d.png" % crack)
        layers += ["hg_frame.png", "hg_plate.png"]
        for n in layers:
            im = L(n)
            if n in ("hg_glow.png", "hg_glow_inner.png"):
                a = np.asarray(im).copy()
                a[..., 3] = (a[..., 3] * glow).astype(np.uint8)
                im = Image.fromarray(a, "RGBA")
            place(sheet, im, lay[n]["rect"], ox, oy)
        if glow:
            g = L("hg_plate_glow.png")
            a = np.asarray(g).copy()
            a[..., 0], a[..., 1], a[..., 2] = 255, 120, 40
            a[..., 3] = (a[..., 3] * 0.45).astype(np.uint8)
            place(sheet, Image.fromarray(a, "RGBA"), lay["hg_plate_glow.png"]["rect"], ox, oy)
        tx, ty = 128, 420
        col = (255, 214, 150) if not glow else (255, 236, 200)
        d = ImageDraw.Draw(sheet)
        d.text((ox + tx, oy + ty), txt, fill=col, font=font, anchor="mm")
        d.text((ox + 128, oy + rowh - 30), title, fill=(255, 255, 255), font=small, anchor="mm")
    # shatter row and after-states
    for j, fi in enumerate((0, 1, 2, 4, 7, 11)):
        ox, oy = 20 + j * colw, rowh + 40
        place(sheet, L("hg_shadow.png"), lay["hg_shadow.png"]["rect"], ox, oy)
        place(sheet, L("hg_frame.png"), lay["hg_frame.png"]["rect"], ox, oy)
        place(sheet, L("hg_shatter_%02d.png" % fi), lay["hg_shatter_%02d.png" % fi]["rect"], ox, oy)
        d = ImageDraw.Draw(sheet)
        d.text((ox + 128, oy + rowh - 50), "shatter %d" % fi, fill=(255, 255, 255), font=small, anchor="mm")
    # after the strike (column 5 of row 1)
    ox, oy = 20 + 4 * colw, 30
    for n in ("hg_shadow.png", "hg_frame.png", "hg_sand_spill.png", "hg_drop_05.png", "hg_plate.png"):
        place(sheet, L(n), lay[n]["rect"], ox, oy)
    g = L("hg_plate_glow.png")
    a = np.asarray(g).copy()
    a[..., 0], a[..., 1], a[..., 2] = 60, 150, 255
    a[..., 3] = (a[..., 3] * 0.35).astype(np.uint8)
    place(sheet, Image.fromarray(a, "RGBA"), lay["hg_plate_glow.png"]["rect"], ox, oy)
    d = ImageDraw.Draw(sheet)
    d.text((ox + 128, oy + 420), "1:24", fill=(200, 236, 255), font=font, anchor="mm")
    d.text((ox + 128, oy + rowh - 30), "after the strike: water in", fill=(255, 255, 255), font=small, anchor="mm")
    # drop strip (column 6)
    ox, oy = 20 + 5 * colw, 30
    for k, dimg in enumerate(drops):
        x = ox + (k % 3) * 92
        y = oy + (k // 3) * 132
        sheet.alpha_composite(dimg, (x, y))
    d.text((ox + 140, oy + rowh - 30), "drop 0..8", fill=(255, 255, 255), font=small, anchor="mm")
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    sheet.convert("RGB").save(path)
    print("preview:", path)


def _paste_clip(canvas, im, x, y):
    cx0, cy0 = max(0, -x), max(0, -y)
    sub = im.crop((cx0, cy0, im.width, im.height))
    canvas.alpha_composite(sub, (x + cx0, y + cy0))


def _font(size):
    for name in ("georgiab.ttf", "georgia.ttf", "DejaVuSerif-Bold.ttf", "arial.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    return ImageFont.load_default()


if __name__ == "__main__":
    main()
