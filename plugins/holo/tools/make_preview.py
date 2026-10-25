#!/usr/bin/env python3
"""Composite Holo's atlases into mock layouts, to review the look without the game.

  python tools/make_preview.py [--bg SCREENSHOT.png] [--out tools/preview/holo-preview.png] [--size 1920x1080]

It re-implements hudNine / hudImageUV / hudText in PIL on top of the generated atlases (reading the layout from the
generators), then draws the corner player, the half panel with its control bar, the minimised pill and a slice of the
setup panel. With --bg the layouts sit on a screenshot (cropped to fit); otherwise on a flat frontend-teal. Not part of
the shipped mod and not byte-checked.
"""
from __future__ import annotations

import argparse
import io
import json
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _art as A  # noqa: E402
import make_font  # noqa: E402
import make_icons  # noqa: E402
import make_panels  # noqa: E402

CREAM, TITLE, GOLD = A.CREAM, A.TITLE, A.GOLD_HEAD


class Kit:
    def __init__(self):
        pf, self.pl = make_panels.build()
        icf, self.il, self.cl = make_icons.build()
        ff, self.fl = make_font.build()
        self.panels = Image.open(io.BytesIO(pf["mod/textures/ui/panels.png"])).convert("RGBA")
        self.icons = Image.open(io.BytesIO(icf["mod/textures/ui/icons.png"])).convert("RGBA")
        self.cursor = Image.open(io.BytesIO(icf["mod/textures/ui/cursor.png"])).convert("RGBA")
        self.fonts = {}
        for k, v in self.fl.items():
            img = Image.open(io.BytesIO(ff[f"mod/fonts/{k}.png"])).convert("RGBA")
            self.fonts[k] = (img, json.loads(ff[f"mod/fonts/{k}.json"]))

    def nine(self, dst, name, x0, y0, x1, y1, scale=0.5):
        """Draw `name` so that its visible shape (the rect minus the transparent pad) fills (x0, y0, x1, y1)."""
        r = self.pl["rects"][name]
        p = r["pad"]
        x0, y0 = x0 - round(p["l"] * scale), y0 - round(p["t"] * scale)
        x1, y1 = x1 + round(p["r"] * scale), y1 + round(p["b"] * scale)
        sx, sy, sw, sh = r["x"], r["y"], r["w"], r["h"]
        l, t, rr, b = r["l"], r["t"], r["r"], r["b"]
        cols = [(0, l), (l, sw - rr), (sw - rr, sw)]
        rows = [(0, t), (t, sh - b), (sh - b, sh)]
        dl, dt, dr, db = round(l * scale), round(t * scale), round(rr * scale), round(b * scale)
        dcols = [(x0, x0 + dl), (x0 + dl, x1 - dr), (x1 - dr, x1)]
        drows = [(y0, y0 + dt), (y0 + dt, y1 - db), (y1 - db, y1)]
        for (cy0, cy1), (dy0, dy1) in zip(rows, drows):
            for (cx0, cx1), (dx0, dx1) in zip(cols, dcols):
                w, h = dx1 - dx0, dy1 - dy0
                if w <= 0 or h <= 0 or cx1 <= cx0 or cy1 <= cy0:
                    continue
                piece = self.panels.crop((sx + cx0, sy + cy0, sx + cx1, sy + cy1)).resize((w, h), Image.BILINEAR)
                dst.alpha_composite(piece, (dx0, dy0))

    def frame_around(self, dst, name, x0, y0, x1, y1, scale=0.5):
        """Draw a frame whose hole is exactly (x0, y0, x1, y1)."""
        r = self.pl["rects"][name]
        p, i = r["pad"], r["inner"]
        self.nine(dst, name, x0 - round((i["l"] - p["l"]) * scale), y0 - round((i["t"] - p["t"]) * scale),
                  x1 + round((i["r"] - p["r"]) * scale), y1 + round((i["b"] - p["b"]) * scale), scale)

    def icon(self, dst, name, x, y, size=36, state=0):
        q = self.il["rects"][name][state]
        piece = self.icons.crop((q["x"], q["y"], q["x"] + q["w"], q["y"] + q["h"])).resize((size, size), Image.LANCZOS)
        dst.alpha_composite(piece, (x, y))

    def measure(self, font, text, size):
        img, m = self.fonts[font]
        f = size / (m["size"] * m["scale"])
        return sum(m["glyphs"].get(str(ord(c)), m["glyphs"]["63"])[6] for c in text) * f

    def text(self, dst, font, text, x, y, size, color=CREAM, align="left"):
        img, m = self.fonts[font]
        f = size / (m["size"] * m["scale"])
        if align == "center":
            x -= self.measure(font, text, size) / 2
        pen = x
        base = y + m["ascent"] * f
        for ch in text:
            g = m["glyphs"].get(str(ord(ch))) or m["glyphs"]["63"]
            gx, gy, gw, gh, xo, yo, adv = g
            if gw and gh:
                piece = img.crop((gx, gy, gx + gw, gy + gh))
                w, h = max(1, round(gw * f)), max(1, round(gh * f))
                piece = piece.resize((w, h), Image.LANCZOS)
                tint = Image.new("RGBA", piece.size, color + (255,))
                px = Image.new("RGBA", piece.size, (0, 0, 0, 0))
                px.paste(tint, (0, 0), None)
                r, gch, b, a = piece.split()
                tr, tg, tb, _ = tint.split()
                from PIL import ImageChops
                col = Image.merge("RGBA", (ImageChops.multiply(r, tr), ImageChops.multiply(gch, tg),
                                           ImageChops.multiply(b, tb), a))
                dst.alpha_composite(col, (round(pen + xo * f), round(base + yo * f)))
            pen += adv * f


def fake_video(w, h):
    img = Image.new("RGBA", (w, h))
    px = img.load()
    for y in range(h):
        for x in range(w):
            t = x / max(w - 1, 1)
            px[x, y] = (int(40 + 120 * t), int(90 + 60 * (1 - y / h)), int(150 - 60 * t), 255)
    return img


def compose(size, bg_path):
    W, H = size
    canvas = Image.new("RGBA", size, (0x01, 0x47, 0x70, 255))
    if bg_path:
        bg = Image.open(bg_path).convert("RGBA")
        scale = max(W / bg.width, H / bg.height)
        bg = bg.resize((round(bg.width * scale), round(bg.height * scale)), Image.LANCZOS)
        canvas.alpha_composite(bg.crop((0, 0, W, H)))
    k = Kit()
    # corner player, top right
    cw = round(W * 0.22)
    ch = round(cw * 9 / 16)
    x1, y0 = W - 40, 40
    x0 = x1 - cw
    canvas.alpha_composite(fake_video(cw, ch), (x0, y0))
    k.frame_around(canvas, "frame_corner", x0, y0, x1, y0 + ch)
    # half panel, left
    px0, py0, px1, py1 = 40, 150, 40 + 760, 150 + 560
    k.nine(canvas, "panel", px0, py0, px1, py1)
    k.nine(canvas, "tag", px0 + 220, py0 - 8, px0 + 540, py0 + 52)
    k.text(canvas, "tag", "Watch Party", px0 + 380, py0 + 6, 24, (0x1A, 0x10, 0x04), "center")
    vx0, vy0 = px0 + 34, py0 + 64
    vw = px1 - px0 - 68
    vh = round(vw * 9 / 16)
    canvas.alpha_composite(fake_video(vw, vh), (vx0, vy0))
    k.frame_around(canvas, "frame_video", vx0, vy0, vx0 + vw, vy0 + vh)
    sy = vy0 + vh - 120
    scr = k.pl["rects"]["scrim"]
    canvas.alpha_composite(k.panels.crop((scr["x"], scr["y"], scr["x"] + scr["w"], scr["y"] + scr["h"])).resize((vw, 120)),
                           (vx0, sy))
    k.nine(canvas, "bar_track", vx0 + 20, vy0 + vh - 56, vx0 + vw - 20, vy0 + vh - 56 + 14)
    k.nine(canvas, "bar_fill", vx0 + 22, vy0 + vh - 54, vx0 + 22 + (vw - 44) * 2 // 5, vy0 + vh - 54 + 10)
    k.text(canvas, "body_s", "12:34 / 1:02:11", vx0 + 22, vy0 + vh - 90, 16)
    names = ["prev", "back10", "pause", "fwd10", "next"]
    for i, n in enumerate(names):
        k.icon(canvas, n, vx0 + 20 + i * 42, vy0 + vh - 38, 36, 0)
    for i, n in enumerate(["vol2", "speed", "cc", "audio", "quality", "queue", "minimise", "hide"]):
        k.icon(canvas, n, vx0 + 270 + i * 40, vy0 + vh - 38, 34, 1 if n == "cc" else 0)
    # status row under the video
    k.text(canvas, "body", "Only the host (Jamin) controls the party", px0 + 40, py1 - 74, 20)
    for i, n in enumerate(["check", "check", "spinner3", "warning", "cross"]):
        k.icon(canvas, n, px0 + 40 + i * 40, py1 - 46, 34, 0)
    k.text(canvas, "body_s", "Привет, Ünïcode ✓ → ? 日本", px0 + 260, py1 - 40, 16, GOLD)
    # pill
    k.nine(canvas, "pill", W - 340, 300, W - 40, 348)
    k.icon(canvas, "play", W - 330, 305, 38)
    k.text(canvas, "body", "Lofi hip hop radio - be...", W - 288, 311, 20)
    k.icon(canvas, "expand", W - 84, 305, 38)
    # setup panel slice
    sx0, sy0, sx1, sy1 = 880, 420, 1520, 1040
    k.nine(canvas, "panel", sx0, sy0, sx1, sy1)
    k.nine(canvas, "tag", sx0 + 160, sy0 - 10, sx0 + 480, sy0 + 50)
    k.text(canvas, "tag", "Queue", sx0 + 320, sy0 + 6, 24, (0x1A, 0x10, 0x04), "center")
    k.nine(canvas, "well", sx0 + 30, sy0 + 70, sx1 - 130, sy0 + 124)
    k.text(canvas, "body", "https://www.youtube.com/watch?v=", sx0 + 48, sy0 + 83, 20, A.TEXT_OFF)
    k.nine(canvas, "btn", sx1 - 118, sy0 + 70, sx1 - 30, sy0 + 124)
    k.text(canvas, "display_s", "Add", sx1 - 74, sy0 + 83, 20, CREAM, "center")
    for i, title in enumerate(["Cats being cats (10 hours)", "magnet: Big Buck Bunny", "Таймлапс - город ночью"]):
        yy = sy0 + 140 + i * 56
        if i == 1:
            k.nine(canvas, "swash", sx0 + 24, yy - 4, sx1 - 24, yy + 52, 0.5)
        k.text(canvas, "body", title, sx0 + 96, yy + 10, 20, A.WHITE if i == 1 else CREAM)
        k.icon(canvas, "magnet" if i == 1 else "link", sx0 + 44, yy + 6, 34)
        k.icon(canvas, "up", sx1 - 150, yy + 8, 30)
        k.icon(canvas, "close", sx1 - 90, yy + 8, 30, 1 if i == 2 else 0)
    k.nine(canvas, "divider", sx0 + 30, sy1 - 190, sx1 - 30, sy1 - 190 + 22)
    for i, (n, label) in enumerate([("btn", "Start Party"), ("btn_hover", "Hover"), ("btn_press", "Press"), ("btn_off", "Off")]):
        bx = sx0 + 30 + i * 148
        k.nine(canvas, n, bx, sy1 - 150, bx + 136, sy1 - 98)
        k.text(canvas, "display_s", label, bx + 68, sy1 - 138, 20, CREAM if n != "btn_off" else A.TEXT_OFF, "center")
    k.nine(canvas, "tooltip", sx0 + 30, sy1 - 84, sx0 + 260, sy1 - 20)
    k.text(canvas, "body_s", "Pack ready", sx0 + 145, sy1 - 62, 16, GOLD, "center")
    r = k.cl
    canvas.alpha_composite(k.cursor.resize((48, 48), Image.LANCZOS), (sx0 + 380, sy0 + 190))
    return canvas


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--bg")
    ap.add_argument("--out", default=str(A.TOOLS / "preview" / "holo-preview.png"))
    ap.add_argument("--size", default="1920x1080")
    a = ap.parse_args(argv)
    w, h = (int(v) for v in a.size.lower().split("x"))
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    compose((w, h), a.bg).convert("RGB").save(out)
    print("wrote", out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
