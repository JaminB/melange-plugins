"""Shared helpers for Holo's art generators (make_panels.py, make_icons.py, make_font.py, make_preview.py).

Shapes are signed distance fields (negative inside) evaluated on the final pixel grid with analytic anti-aliasing
(coverage = clamp(0.5 - d)), layers are composited premultiplied in float32, and everything random comes from a
seeded numpy generator, so a run is deterministic. PNGs are written without metadata at a fixed compression level.
Every generator takes `--check` (byte compare with the files on disk) and `--emit-lua` (rewrite src/55_atlas.lua).
"""
from __future__ import annotations

import hashlib
import io
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

PLUGIN = Path(__file__).resolve().parent.parent
TOOLS = PLUGIN / "tools"
UI_DIR = PLUGIN / "mod" / "textures" / "ui"
FONT_DIR = PLUGIN / "mod" / "fonts"
LUA_OUT = PLUGIN / "src" / "55_atlas.lua"

# Palette (design 2.8, sampled from the frontend screenshots by r-style.md).
INK = (0, 0, 0)
WHITE = (255, 255, 255)
PANEL = (0x1D, 0x50, 0x60)
PANEL_TOP = (0x1F, 0x5E, 0x70)
PANEL_DARK = (0x15, 0x34, 0x43)
PANEL_DARK2 = (0x19, 0x43, 0x56)
PANEL_LIGHT = (0x31, 0x63, 0x6B)
PANEL_LIGHT2 = (0x47, 0x77, 0x76)
BTN = (0x00, 0x53, 0x72)
BTN_HOVER = (0x0E, 0x6C, 0x8E)
BTN_PRESS = (0x00, 0x43, 0x5C)
BTN_OFF = (0x60, 0x52, 0x84)
TEXT_OFF = (0x94, 0xA1, 0xB8)
CREAM = (0xFE, 0xE1, 0x95)
TITLE = (0xFF, 0xF5, 0x9B)
GOLD_HEAD = (0xEF, 0xDE, 0x84)
PAPER = (0xFF, 0xEF, 0xD6)
SEEK = (0xFF, 0xD2, 0x4A)
ERROR = (0xE8, 0x22, 0x1A)
ORANGE = (0xFF, 0x9A, 0x30)


# ---------------------------------------------------------------------------------------------------- output

def png_bytes(arr: np.ndarray) -> bytes:
    """Straight-alpha uint8 RGBA array to PNG bytes (no metadata, fixed compression)."""
    img = Image.fromarray(np.ascontiguousarray(arr, dtype=np.uint8), "RGBA")
    buf = io.BytesIO()
    img.save(buf, format="PNG", optimize=False, compress_level=9)
    return buf.getvalue()


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sync(path: Path, data: bytes, check: bool, problems: list[str]) -> None:
    """Write `data` to `path`, or in check mode report when the file on disk differs."""
    if check:
        if not path.is_file():
            problems.append(f"missing: {path.relative_to(PLUGIN).as_posix()}")
        elif path.read_bytes() != data:
            problems.append(f"differs: {path.relative_to(PLUGIN).as_posix()}")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    print(f"wrote {path.relative_to(PLUGIN).as_posix()} ({len(data)} bytes)")


def finish(problems: list[str], check: bool, what: str) -> int:
    if problems:
        for p in problems:
            print("check:", p, file=sys.stderr)
        print(f"{what}: out of date; run it without --check and commit the result", file=sys.stderr)
        return 1
    if check:
        print(f"{what}: up to date")
    return 0


def to_straight(premul: np.ndarray) -> np.ndarray:
    """Premultiplied float RGBA (0..1) to straight uint8 RGBA."""
    a = premul[..., 3:4]
    rgb = np.where(a > 1e-6, premul[..., :3] / np.maximum(a, 1e-6), 0.0)
    out = np.concatenate([np.clip(rgb, 0, 1), np.clip(a, 0, 1)], axis=-1)
    return np.rint(out * 255.0).astype(np.uint8)


# ---------------------------------------------------------------------------------------------------- packing

def next_pow2(n: int) -> int:
    p = 1
    while p < n:
        p *= 2
    return p


def shelf_pack(sizes: list[tuple[int, int]], width: int, gap: int) -> tuple[list[tuple[int, int]], int]:
    """Place rectangles on shelves, tallest first (ties keep input order). Returns positions in input order and the
    used height. A `gap` of transparent pixels separates neighbours so bilinear sampling never bleeds."""
    order = sorted(range(len(sizes)), key=lambda i: (-sizes[i][1], i))
    pos: list[tuple[int, int]] = [(0, 0)] * len(sizes)
    x = y = shelf_h = 0
    for i in order:
        w, h = sizes[i]
        if x + w > width:
            x, y, shelf_h = 0, y + shelf_h + gap, 0
        pos[i] = (x, y)
        x += w + gap
        shelf_h = max(shelf_h, h)
    return pos, y + shelf_h


# ---------------------------------------------------------------------------------------------------- SDF toolkit

def grid(w: int, h: int, ox: float = 0.0, oy: float = 0.0) -> tuple[np.ndarray, np.ndarray]:
    """Pixel-centre coordinates (x right, y down), shifted by (ox, oy)."""
    x = np.arange(w, dtype=np.float32) + 0.5 - ox
    y = np.arange(h, dtype=np.float32) + 0.5 - oy
    return np.meshgrid(x, y)


def cov(d: np.ndarray) -> np.ndarray:
    return np.clip(0.5 - d, 0.0, 1.0)


def rbox(X, Y, x0, y0, x1, y1, r):
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    hx, hy = (x1 - x0) / 2 - r, (y1 - y0) / 2 - r
    qx, qy = np.abs(X - cx) - hx, np.abs(Y - cy) - hy
    return np.hypot(np.maximum(qx, 0), np.maximum(qy, 0)) + np.minimum(np.maximum(qx, qy), 0) - r


def circle(X, Y, cx, cy, r):
    return np.hypot(X - cx, Y - cy) - r


def capsule(X, Y, a, b, r):
    ax, ay = a
    bx, by = b
    px, py = X - ax, Y - ay
    dx, dy = bx - ax, by - ay
    t = np.clip((px * dx + py * dy) / max(dx * dx + dy * dy, 1e-9), 0.0, 1.0)
    return np.hypot(px - dx * t, py - dy * t) - r


def polyline(X, Y, pts, r):
    d = capsule(X, Y, pts[0], pts[1], r)
    for a, b in zip(pts[1:-1], pts[2:]):
        d = np.minimum(d, capsule(X, Y, a, b, r))
    return d


def poly(X, Y, pts, r=0.0):
    """Polygon SDF (exact distance, even-odd sign) inflated by r, which also rounds the corners by r."""
    n = len(pts)
    d = np.full(X.shape, 1e9, dtype=np.float32)
    inside = np.zeros(X.shape, dtype=bool)
    for i in range(n):
        ax, ay = pts[i]
        bx, by = pts[(i + 1) % n]
        ex, ey = bx - ax, by - ay
        px, py = X - ax, Y - ay
        t = np.clip((px * ex + py * ey) / max(ex * ex + ey * ey, 1e-9), 0.0, 1.0)
        d = np.minimum(d, np.hypot(px - ex * t, py - ey * t))
        cross = ((ay > Y) != (by > Y)) & (X < (bx - ax) * (Y - ay) / np.where(by == ay, 1e-9, by - ay) + ax)
        inside ^= cross
    return np.where(inside, -d, d) - r


def ring(X, Y, cx, cy, radius, half_w):
    return np.abs(np.hypot(X - cx, Y - cy) - radius) - half_w


def arc(X, Y, cx, cy, radius, half_w, a0, a1):
    """Ring segment with round caps; angles in degrees, 0 = +x, increasing clockwise on screen (y down)."""
    a0r, a1r = np.radians(a0), np.radians(a1)
    p0 = (cx + radius * np.cos(a0r), cy + radius * np.sin(a0r))
    p1 = (cx + radius * np.cos(a1r), cy + radius * np.sin(a1r))
    ang = np.degrees(np.arctan2(Y - cy, X - cx))
    span = (a1 - a0) % 360.0
    rel = (ang - a0) % 360.0
    within = rel <= span
    d_ring = np.abs(np.hypot(X - cx, Y - cy) - radius) - half_w
    d_caps = np.minimum(np.hypot(X - p0[0], Y - p0[1]), np.hypot(X - p1[0], Y - p1[1])) - half_w
    return np.where(within, d_ring, d_caps)


def rotated(X, Y, cx, cy, deg):
    """Coordinates of the grid in a frame rotated by `deg` about (cx, cy), to evaluate a rotated shape."""
    c, s = np.cos(np.radians(deg)), np.sin(np.radians(deg))
    px, py = X - cx, Y - cy
    return px * c + py * s + cx, -px * s + py * c + cy


def union(*ds):
    out = ds[0]
    for d in ds[1:]:
        out = np.minimum(out, d)
    return out


def subtract(a, b):
    return np.maximum(a, -b)


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def value_noise(shape, wavelength: float, seed: int, aspect: float = 1.0) -> np.ndarray:
    """Smooth value noise in -1..1 with the given wavelength in pixels (lattice spacing)."""
    h, w = shape
    rng = np.random.default_rng(seed)
    gw, gh = int(w / wavelength) + 3, int(h / (wavelength * aspect)) + 3
    lat = rng.random((gh, gw)).astype(np.float32) * 2 - 1
    xs = np.arange(w, dtype=np.float32) / wavelength
    ys = np.arange(h, dtype=np.float32) / (wavelength * aspect)
    x0, y0 = xs.astype(int), ys.astype(int)
    fx, fy = smoothstep(0, 1, xs - x0), smoothstep(0, 1, ys - y0)
    a = lat[np.ix_(y0, x0)] * (1 - fx) + lat[np.ix_(y0, x0 + 1)] * fx
    b = lat[np.ix_(y0 + 1, x0)] * (1 - fx) + lat[np.ix_(y0 + 1, x0 + 1)] * fx
    return a * (1 - fy)[:, None] + b * fy[:, None]


def blur(a: np.ndarray, sigma: float) -> np.ndarray:
    """Separable gaussian blur of a 2D array (edges treated as zero)."""
    if sigma <= 0:
        return a
    r = int(np.ceil(sigma * 3))
    k = np.exp(-0.5 * (np.arange(-r, r + 1) / sigma) ** 2).astype(np.float32)
    k /= k.sum()
    for axis in (0, 1):
        pad = [(0, 0), (0, 0)]
        pad[axis] = (r, r)
        p = np.pad(a, pad)
        out = np.zeros_like(a)
        for i, wgt in enumerate(k):
            sl = [slice(None), slice(None)]
            sl[axis] = slice(i, i + a.shape[axis])
            out += wgt * p[tuple(sl)]
        a = out
    return a


def shift(a: np.ndarray, dx: int, dy: int) -> np.ndarray:
    out = np.zeros_like(a)
    h, w = a.shape[:2]
    xs, xd = (slice(0, w - dx), slice(dx, w)) if dx >= 0 else (slice(-dx, w), slice(0, w + dx))
    ys, yd = (slice(0, h - dy), slice(dy, h)) if dy >= 0 else (slice(-dy, h), slice(0, h + dy))
    out[yd, xd] = a[ys, xs]
    return out


# ---------------------------------------------------------------------------------------------------- compositing

def rgb01(c) -> np.ndarray:
    return np.array(c, dtype=np.float32) / 255.0


def new_canvas(w: int, h: int) -> np.ndarray:
    return np.zeros((h, w, 4), dtype=np.float32)


def over(dst: np.ndarray, color, alpha: np.ndarray) -> None:
    """Composite a colour (3-tuple 0..255, or an (h, w, 3) array in 0..1) at `alpha` (h, w) over a premultiplied canvas."""
    c = rgb01(color) if isinstance(color, tuple) else color
    a = np.clip(alpha, 0, 1)[..., None]
    dst[...] = np.concatenate([c * a, a], axis=-1) + dst * (1 - a)


def vgradient(h: int, w: int, top, bottom, y0: float, y1: float) -> np.ndarray:
    """Vertical gradient (h, w, 3) in 0..1 between rows y0 and y1."""
    t = np.clip((np.arange(h, dtype=np.float32) + 0.5 - y0) / max(y1 - y0, 1e-6), 0, 1)[:, None, None]
    return (rgb01(top) * (1 - t) + rgb01(bottom) * t) * np.ones((1, w, 1), dtype=np.float32)


def mix(c, d, t: float):
    return tuple(int(round(a * (1 - t) + b * t)) for a, b in zip(c, d))


# ---------------------------------------------------------------------------------------------------- lua emit

def lua_value(v, indent: int = 0, wrap: int = 118) -> str:
    """Deterministic Lua literal: dicts keep insertion order, short tables stay on one line."""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return repr(round(v, 4))
    if isinstance(v, str):
        return json.dumps(v)
    if isinstance(v, (list, tuple)):
        inner = ", ".join(lua_value(x, indent + 1, wrap) for x in v)
        return "{" + inner + "}"
    if isinstance(v, dict):
        inline = "{" + ", ".join(f"{k} = {lua_value(x, indent + 1, wrap)}" for k, x in v.items()) + "}"
        if len(inline) + 2 * indent <= wrap and "\n" not in inline:
            return inline
        pad = "  " * (indent + 1)
        body = ",\n".join(f"{pad}{k} = {lua_value(x, indent + 1, wrap)}" for k, x in v.items())
        return "{\n" + body + ",\n" + "  " * indent + "}"
    raise TypeError(type(v))


def emit_lua(check: bool) -> int:
    """Rebuild every atlas layout (renders all generators) and write/compare src/55_atlas.lua."""
    import make_font
    import make_icons
    import make_panels

    layout = {"panels": make_panels.build()[1], "icons": make_icons.build()[1], "cursor": make_icons.build()[2],
              "fonts": make_font.build()[1]}
    text = render_lua(layout)
    problems: list[str] = []
    sync(LUA_OUT, text.encode("utf-8"), check, problems)
    return finish(problems, check, "55_atlas.lua")


def render_lua(layout: dict) -> str:
    head = (
        "-- Atlas layout, generated by tools/make_panels.py, make_icons.py and make_font.py (--emit-lua). Do not edit.\n"
        "-- All numbers are texture pixels of the 2x-authored PNGs (draw nine-slices with scale 0.5 for 1x).\n"
        "-- panels.rects[name] = {x, y, w, h, l, t, r, b, pad = {l, t, r, b}[, inner = {l, t, r, b}]}: the source rect, the\n"
        "--   nine-slice insets, the transparent margin that holds the shadow (the shape starts at pad), and for the\n"
        "--   video frames the hole's inset (draw the picture there).\n"
        "-- icons.rects[name] = {{x, y, w, h}, ...} in the order of icons.states (normal, hover, press, off).\n"
        "-- cursor.hot is the arrow's tip in the cursor PNG; fonts.<name> = {png, json, size, w, h} for wum.draw.font.\n"
        "-- Load every PNG with wum.draw.texture(file, {mips = false}).\n"
    )
    body = ["do", "  SKIN.atlas = {"]
    for key in ("panels", "icons", "cursor"):
        body.append(f"    {key} = {lua_value(layout[key], 2)},")
    body.append("  }")
    body.append(f"  SKIN.fonts = {lua_value(layout['fonts'], 1)}")
    body.append("end")
    return head + "\n".join(body) + "\n"


def run_cli(name: str, build, argv: list[str]) -> int:
    """Common `--check` / `--emit-lua` handling. `build()` returns ({relpath: bytes}, ...)."""
    check = "--check" in argv
    problems: list[str] = []
    files = build()[0]
    for rel, data in files.items():
        sync(PLUGIN / rel, data, check, problems)
    rc = finish(problems, check, name)
    if "--emit-lua" in argv or check:
        rc |= emit_lua(check)
    return rc
