#!/usr/bin/env python3
"""Draw Holo's icon atlas (mod/textures/ui/icons.png) and the orange arrow cursor (cursor.png).

  python tools/make_icons.py [--check] [--emit-lua]

Every icon is a stack of signed-distance shapes with the inked-cartoon treatment (black outline, cream fill, a hard
shadow) and is drawn in four states: normal, hover (lighter, white rim), press (darker, 2 px down) and off (grey).
Cells are 72x72 at 2x (36x36 at 1x); the glyph itself stays within +-26 so the outline, rim and shadow fit.
"""
from __future__ import annotations

import functools
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _art as A  # noqa: E402

CELL = 72
STRIDE = CELL + 2          # a 2 px transparent gap between cells
PER_ROW_ICONS = 3          # 3 icons x 4 states = 12 cells per row
STATES = ("normal", "hover", "press", "off")
INK_W = 5.0

GREEN = (0x7B, 0xD8, 0x4A)
AMBER = (0xFF, 0xB0, 0x20)
SILVER = (0xF0, 0xF4, 0xF8)
COLORS = {
    "c": A.CREAM, "c2": A.mix(A.CREAM, A.PANEL, 0.3), "red": A.ERROR, "green": GREEN, "amber": AMBER, "gold": A.SEEK,
    "w": SILVER,
}


def L(d, key="c", ink=INK_W):
    return d, key, ink


def cut(d):
    return d, "k", 0.0


def ellipse_ring(X, Y, cx, cy, rx, ry, hw):
    u, v = (X - cx) / rx, (Y - cy) / ry
    k = np.maximum(np.hypot(u, v), 1e-6)
    grad = np.maximum(np.hypot(u / rx, v / ry) / k, 1e-6)  # |grad f| of f = |(u, v)| - 1: first-order distance
    return np.abs((k - 1.0) / grad) - hw


def speaker(X, Y):
    return A.poly(X, Y, [(-20, -4), (-13, -4), (-5, -13), (-5, 13), (-13, 4), (-20, 4)], 2.5)


def head(X, Y, cx, cy, ang, R, size=9.0):
    """Arrow head at angle `ang` (deg) of a clockwise circle arrow."""
    a = np.radians(ang)
    px, py = cx + R * np.cos(a), cy + R * np.sin(a)
    tx, ty = -np.sin(a), np.cos(a)
    nx, ny = np.cos(a), np.sin(a)
    pts = [(px + tx * size, py + ty * size), (px - tx * 2 + nx * 8, py - ty * 2 + ny * 8),
           (px - tx * 2 - nx * 8, py - ty * 2 - ny * 8)]
    return A.poly(X, Y, pts, 1.5)


def skip10(X, Y, flip):
    R = 20.0
    XR = -X if flip else X  # the arrow is mirrored for "back"; the digits are not
    ring = A.arc(XR, Y, 0, 2, R, 3.0, -55, 235)
    h = head(XR, Y, 0, 2, 235, R)
    one = A.union(A.capsule(X, Y, (-5.5, -4), (-5.5, 9), 1.9), A.capsule(X, Y, (-5.5, -4), (-9, -1), 1.9))
    zero = ellipse_ring(X, Y, 5.5, 2.5, 3.6, 6.8, 1.9)
    return [L(A.union(ring, h), ink=4.0), L(A.union(one, zero), ink=3.5)]


def gear(X, Y):
    d = A.circle(X, Y, 0, 0, 14.0)
    for k in range(8):
        u, v = A.rotated(X, Y, 0, 0, k * 45.0)
        d = np.minimum(d, A.rbox(u, v, 10, -4.6, 21.5, 4.6, 2.0))
    return d


def link_ring(X, Y, cx, cy):
    u, v = A.rotated(X, Y, cx, cy, 45.0)
    d = A.rbox(u, v, cx - 14, cy - 8, cx + 14, cy + 8, 8)
    return np.abs(d + 3.0) - 3.0


def icon_layers(name, X, Y):
    """The layers (sdf, colour key, outline width) of one icon, in painting order."""
    if name == "play":
        return [L(A.poly(X, Y, [(-9, -15), (-9, 15), (14, 0)], 5.0))]
    if name == "pause":
        return [L(A.union(A.rbox(X, Y, -17, -19, -4, 19, 4), A.rbox(X, Y, 4, -19, 17, 19, 4)))]
    if name in ("prev", "next"):
        s = -1.0 if name == "next" else 1.0
        xs = X * s
        return [L(A.union(A.rbox(xs, Y, -22, -18, -14, 18, 3), A.poly(xs, Y, [(-4, 0), (14, -13), (14, 13)], 4.0)))]
    if name == "back10":
        return skip10(X, Y, True)
    if name == "fwd10":
        return skip10(X, Y, False)
    if name in ("vol0", "vol1", "vol2"):
        n = int(name[-1])
        ls = [L(speaker(X, Y))]
        if n >= 1:
            ls.append(L(A.arc(X, Y, -4, 0, 10.5, 2.6, -45, 45), ink=4.0))
        if n >= 2:
            ls.append(L(A.arc(X, Y, -4, 0, 18.5, 2.6, -45, 45), ink=4.0))
        return ls
    if name == "mute":
        x = A.union(A.capsule(X, Y, (6, -9), (20, 9), 2.8), A.capsule(X, Y, (6, 9), (20, -9), 2.8))
        return [L(speaker(X, Y)), L(x, "red", 4.0)]
    if name == "speed":
        body = A.union(A.ring(X, Y, 0, 4, 17, 3.0), A.rbox(X, Y, -4.5, -25, 4.5, -18, 2.5),
                       A.capsule(X, Y, (13, -9), (18, -14), 2.6))
        hand = A.union(A.capsule(X, Y, (0, 4), (6, -4.5), 2.4), A.circle(X, Y, 0, 4, 3.4))
        return [L(body), L(hand, ink=3.0)]
    if name == "cc":
        return [L(A.rbox(X, Y, -24, -17, 24, 17, 7)),
                cut(A.arc(X, Y, -10, 0, 6.3, 2.4, 40, 320)), cut(A.arc(X, Y, 10.5, 0, 6.3, 2.4, 40, 320))]
    if name == "audio":
        note = A.union(A.circle(X, Y, -8, 14, 7.0), A.capsule(X, Y, (-2.5, 13), (-2.5, -19), 2.6),
                       A.polyline(X, Y, [(-2.5, -19), (11, -12), (11, -3)], 2.6))
        return [L(note)]
    if name == "quality":
        return [L(gear(X, Y)), cut(A.circle(X, Y, 0, 0, 6.0))]
    if name == "queue":
        d = None
        for y in (-14, 0, 14):
            row = A.union(A.circle(X, Y, -19, y, 3.6), A.rbox(X, Y, -11, y - 3.4, 22, y + 3.4, 3.4))
            d = row if d is None else np.minimum(d, row)
        return [L(d)]
    if name == "minimise":
        return [L(A.union(A.polyline(X, Y, [(-15, -9), (0, 6), (15, -9)], 3.8), A.rbox(X, Y, -18, 14, 18, 20.5, 3.2)))]
    if name == "expand":
        d = None
        for sx in (-1, 1):
            for sy in (-1, 1):
                c = A.polyline(X, Y, [(sx * 20, sy * 8), (sx * 20, sy * 20), (sx * 8, sy * 20)], 3.4)
                d = c if d is None else np.minimum(d, c)
        return [L(d)]
    if name == "hide":
        eye = A.union(ellipse_ring(X, Y, 0, 0, 23, 16, 3.0), A.circle(X, Y, 0, 0, 5.0))
        return [L(eye, ink=2.8), L(A.capsule(X, Y, (-18, 18), (18, -18), 3.0), ink=4.0)]
    if name == "close":
        return [L(A.union(A.capsule(X, Y, (-14, -14), (14, 14), 4.2), A.capsule(X, Y, (14, -14), (-14, 14), 4.2)))]
    if name == "up":
        return [L(A.polyline(X, Y, [(-15, 7), (0, -8), (15, 7)], 4.8))]
    if name == "down":
        return [L(A.polyline(X, Y, [(-15, -7), (0, 8), (15, -7)], 4.8))]
    if name == "add":
        return [L(A.union(A.capsule(X, Y, (-17, 0), (17, 0), 4.8), A.capsule(X, Y, (0, -17), (0, 17), 4.8)))]
    if name == "check":
        return [L(A.polyline(X, Y, [(-17, 1), (-6, 13), (18, -13)], 5.2), "green")]
    if name == "cross":
        return [L(A.union(A.capsule(X, Y, (-13, -13), (13, 13), 5.0), A.capsule(X, Y, (13, -13), (-13, 13), 5.0)), "red")]
    if name == "link":
        return [L(link_ring(X, Y, -7.5, 7.5)), L(link_ring(X, Y, 7.5, -7.5))]
    if name == "magnet":
        body = A.union(A.arc(X, Y, 0, -3, 15, 6.0, 180, 360), A.rbox(X, Y, -21, -3, -9, 14, 2), A.rbox(X, Y, 9, -3, 21, 14, 2))
        tips = A.union(A.rbox(X, Y, -21, 7, -9, 16, 2), A.rbox(X, Y, 9, 7, 21, 16, 2))
        return [L(body, "red"), L(tips, "w", 3.5)]
    if name == "people":
        back = A.union(A.circle(X, Y, 11, -11, 6.5), A.rbox(X, Y, 3, -2, 22, 17, 8))
        front = A.union(A.circle(X, Y, -8, -9, 7.5), A.rbox(X, Y, -20, 3, 4, 22, 9))
        return [L(back, "c2"), L(front)]
    if name == "warning":
        return [L(A.poly(X, Y, [(0, -16), (17, 12), (-17, 12)], 5.0), "amber"),
                cut(A.capsule(X, Y, (0, -6), (0, 2.5), 2.4)), cut(A.circle(X, Y, 0, 9.5, 2.7))]
    if name == "download":
        d = A.union(A.capsule(X, Y, (0, -20), (0, 1), 4.6), A.poly(X, Y, [(-10, -2), (10, -2), (0, 10)], 3.5),
                    A.polyline(X, Y, [(-18, 5), (-18, 19), (18, 19), (18, 5)], 3.5))
        return [L(d)]
    if name == "crown":
        c = A.poly(X, Y, [(-18, 14), (-20, -9), (-9, 2), (0, -14), (9, 2), (20, -9), (18, 14)], 3.5)
        return [L(c, "gold"), cut(A.capsule(X, Y, (-14, 9), (14, 9), 1.8))]
    if name.startswith("spinner"):
        n = int(name[7:]) - 1
        radii = (6.4, 6.0, 5.3, 4.6, 3.9, 3.3, 2.8, 2.4)
        d = None
        for i in range(8):
            ang = np.radians(i * 45.0 - 90.0)
            dot = A.circle(X, Y, 19 * np.cos(ang), 19 * np.sin(ang), radii[(n - i) % 8])
            d = dot if d is None else np.minimum(d, dot)
        return [L(d, ink=3.0)]
    raise KeyError(name)


NAMES = ["play", "pause", "prev", "next", "back10", "fwd10", "vol0", "vol1", "vol2", "mute", "speed", "cc", "audio",
         "quality", "queue", "minimise", "expand", "hide", "close", "up", "down", "add", "check", "cross"] + \
        [f"spinner{i}" for i in range(1, 9)] + ["link", "magnet", "people", "warning", "download", "crown"]


def state_color(key, state):
    if key == "k":
        return A.INK
    base = COLORS[key]
    if state == "hover":
        return A.mix(base, A.WHITE, 0.24)
    if state == "press":
        return A.mix(base, A.INK, 0.2)
    if state == "off":
        lum = (0.3 * base[0] + 0.59 * base[1] + 0.11 * base[2]) / 230.0
        return A.mix(A.TEXT_OFF, A.INK, float(np.clip(1.0 - lum, 0.0, 0.5)) * 0.5)
    return base


def render(name, state):
    oy = CELL / 2 + (2 if state == "press" else 0)
    X, Y = A.grid(CELL, CELL, CELL / 2, oy)
    layers = icon_layers(name, X, Y)
    sil = None
    for d, key, ink in layers:
        if key == "k":
            continue
        e = d - ink
        sil = e if sil is None else np.minimum(sil, e)
    c = A.new_canvas(CELL, CELL)
    shadow_a = {"press": 0.25, "off": 0.25}.get(state, 0.45)
    A.over(c, A.INK, A.blur(A.shift(A.cov(sil), 3, 4), 1.6) * shadow_a)
    if state == "hover":
        A.over(c, A.WHITE, A.cov(sil - 3.0))
    for d, key, ink in layers:
        if key == "k":
            A.over(c, A.INK, A.cov(d))
            continue
        if ink > 0:
            A.over(c, A.INK, A.cov(d - ink))
        col = state_color(key, state)
        grad = A.vgradient(CELL, CELL, A.mix(col, A.WHITE, 0.14), A.mix(col, A.INK, 0.12), 12, 60)
        A.over(c, grad, A.cov(d))
    return c


def cursor():
    S = 96
    X, Y = A.grid(S, S)
    k = 1.3
    ox, oy = 14.0, 14.0
    raw = [(0, 0), (0, 40), (10, 31), (17, 48), (26, 44), (19, 28), (32, 28)]
    pts = [(ox + k * x, oy + k * y) for x, y in raw]
    r, ink = 3.0, 7.0
    d = A.poly(X, Y, pts, r)
    c = A.new_canvas(S, S)
    A.over(c, A.INK, A.blur(A.shift(A.cov(d - ink), 4, 6), 2.5) * 0.45)
    A.over(c, A.WHITE, A.cov(d - ink - 2.5))
    A.over(c, A.INK, A.cov(d - ink))
    grad = A.vgradient(S, S, A.mix(A.ORANGE, A.WHITE, 0.25), A.mix(A.ORANGE, (0xB0, 0x40, 0x00), 0.25), oy, oy + k * 48)
    A.over(c, grad, A.cov(d))
    # hot spot: the outermost point of the white rim along the tip's bisector
    e1 = np.array(pts[1]) - np.array(pts[0])
    e2 = np.array(pts[6]) - np.array(pts[0])
    bis = e1 / np.linalg.norm(e1) + e2 / np.linalg.norm(e2)
    bis /= np.linalg.norm(bis)
    hot = np.array(pts[0]) - bis * (r + ink)
    return c, (int(round(hot[0])), int(round(hot[1])))


@functools.lru_cache(maxsize=None)
def build():
    cols = PER_ROW_ICONS * len(STATES)
    rows = -(-len(NAMES) // PER_ROW_ICONS)
    W, H = cols * STRIDE, rows * STRIDE
    atlas = A.new_canvas(W, H)
    rects = {}
    for i, name in enumerate(NAMES):
        row, col = divmod(i, PER_ROW_ICONS)
        cells = []
        for s, state in enumerate(STATES):
            x, y = (col * len(STATES) + s) * STRIDE, row * STRIDE
            atlas[y:y + CELL, x:x + CELL] = render(name, state)
            cells.append({"x": x, "y": y, "w": CELL, "h": CELL})
        rects[name] = cells
    if W > 1024 or H > 1024:
        raise SystemExit(f"make_icons: atlas {W}x{H} exceeds 1024")
    cur, hot = cursor()
    files = {"mod/textures/ui/icons.png": A.png_bytes(A.to_straight(atlas)),
             "mod/textures/ui/cursor.png": A.png_bytes(A.to_straight(cur))}
    icons = {"file": "textures/ui/icons.png", "w": W, "h": H, "cell": CELL, "states": list(STATES), "rects": rects}
    curl = {"file": "textures/ui/cursor.png", "w": 96, "h": 96, "hot": {"x": hot[0], "y": hot[1]}}
    return files, icons, curl


if __name__ == "__main__":
    sys.exit(A.run_cli("make_icons", build, sys.argv[1:]))
