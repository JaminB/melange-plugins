#!/usr/bin/env python3
"""Checks on Holo's generated art: limits from the design, metrics the core's parser accepts, determinism.

  python tools/tests/test_art.py

Needs numpy and Pillow (like the generators). The byte comparison with the committed files is `make_*.py --check`.
"""
from __future__ import annotations

import io
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import _art as A  # noqa: E402
import make_font  # noqa: E402
import make_icons  # noqa: E402
import make_panels  # noqa: E402
from PIL import Image  # noqa: E402

CONTRACT_PANELS = ["panel", "panel_dark", "btn", "btn_hover", "btn_press", "btn_off", "tag", "pill", "tooltip",
                   "frame_video", "frame_corner", "bar_track", "bar_fill", "well"]
CONTRACT_ICONS = ["play", "pause", "prev", "next", "back10", "fwd10", "vol0", "vol1", "vol2", "mute", "speed", "cc",
                  "audio", "quality", "queue", "minimise", "expand", "hide", "close", "up", "down", "add", "check",
                  "cross", "link", "magnet", "people", "warning", "download", "crown"] + \
                 [f"spinner{i}" for i in range(1, 9)]


def decode(data):
    return Image.open(io.BytesIO(data)).convert("RGBA")


class Art(unittest.TestCase):
    def test_panel_atlas(self):
        files, layout = make_panels.build()
        img = decode(files["mod/textures/ui/panels.png"])
        self.assertLessEqual(img.width, 1024)
        self.assertLessEqual(img.height, 1024)
        self.assertEqual((layout["w"], layout["h"]), img.size)
        for name in CONTRACT_PANELS:
            r = layout["rects"][name]
            self.assertLessEqual(r["x"] + r["w"], img.width, name)
            self.assertLessEqual(r["y"] + r["h"], img.height, name)
            self.assertLessEqual(r["l"] + r["r"], r["w"], name)
            self.assertLessEqual(r["t"] + r["b"], r["h"], name)
            self.assertGreater(img.crop((r["x"], r["y"], r["x"] + r["w"], r["y"] + r["h"])).getchannel("A").getbbox()
                               is not None, 0, name)
        # no two rectangles overlap
        rs = list(layout["rects"].values())
        for i, a in enumerate(rs):
            for b in rs[i + 1:]:
                self.assertTrue(a["x"] + a["w"] <= b["x"] or b["x"] + b["w"] <= a["x"] or a["y"] + a["h"] <= b["y"]
                                or b["y"] + b["h"] <= a["y"])
        for name in ("frame_video", "frame_corner"):
            self.assertIn("inner", layout["rects"][name])

    def test_icon_atlas(self):
        files, icons, cursor = make_icons.build()
        img = decode(files["mod/textures/ui/icons.png"])
        self.assertLessEqual(max(img.size), 1024)
        for name in CONTRACT_ICONS:
            cells = icons["rects"][name]
            self.assertEqual(len(cells), 4, name)
            for c in cells:
                self.assertLessEqual(c["x"] + c["w"], img.width)
                self.assertLessEqual(c["y"] + c["h"], img.height)
                self.assertIsNotNone(img.crop((c["x"], c["y"], c["x"] + c["w"], c["y"] + c["h"])).getchannel("A").getbbox(),
                                     name)
            # a glyph never touches its cell border (outline, rim and shadow fit)
            c = cells[1]
            box = img.crop((c["x"], c["y"], c["x"] + c["w"], c["y"] + c["h"])).getchannel("A").point(
                lambda v: 255 if v > 8 else 0).getbbox()
            self.assertTrue(box[0] > 0 and box[1] > 0 and box[2] < c["w"] and box[3] < c["h"], f"{name} {box}")
        cur = decode(files["mod/textures/ui/cursor.png"])
        self.assertEqual(cur.size, (cursor["w"], cursor["h"]))
        self.assertGreater(cur.getpixel((cursor["hot"]["x"] + 4, cursor["hot"]["y"] + 8))[3], 0)

    def test_fonts(self):
        files, layout = make_font.build()
        self.assertLessEqual(len(layout), 4)  # wum.draw.font: at most 4 per mod
        for key, f in layout.items():
            img = decode(files[f"mod/fonts/{key}.png"])
            self.assertLessEqual(img.width, 2048)
            self.assertLessEqual(img.height, 1024)
            m = json.loads(files[f"mod/fonts/{key}.json"])
            self.assertEqual(m["format"], "holo-font-1")
            self.assertEqual(m["scale"], 2)
            self.assertGreaterEqual(m["lineHeight"], m["ascent"])
            g = m["glyphs"]
            for cp in (32, 63, 65, 122, 0xE9, 0x17E, 0x416, 0x44F, 0x2026):
                self.assertIn(str(cp), g, f"{key}: U+{cp:04X}")
            for k, v in g.items():
                x, y, w, h, xo, yo, adv = v
                self.assertTrue(x >= 0 and y >= 0 and x + w <= img.width and y + h <= img.height, f"{key} {k}")
                self.assertTrue(abs(xo) <= 8192 and abs(yo) <= 8192 and 0 <= adv <= 8192)
            self.assertEqual(f["w"], img.width)
            self.assertEqual(m["name"], "Holo Display" if key.startswith("display") else "Holo Body")
        notice = files["mod/fonts/OFL.txt"].decode("utf-8")
        for needle in ("Lilita", "Baloo 2", "Rubik", "SIL OPEN FONT LICENSE Version 1.1"):
            self.assertIn(needle, notice)

    def test_total_size(self):
        total = sum(len(v) for build in (make_panels.build, make_icons.build, make_font.build) for v in build()[0].values())
        self.assertLess(total, 3 * 1024 * 1024)

    def test_deterministic(self):
        a = make_panels.elements()
        b = make_panels.elements()
        for name in a:
            self.assertTrue((a[name][0] == b[name][0]).all(), name)
        self.assertEqual(A.png_bytes(A.to_straight(make_icons.render("play", "hover"))),
                         A.png_bytes(A.to_straight(make_icons.render("play", "hover"))))

    def test_lua_layout(self):
        import make_font as mf
        layout = {"panels": make_panels.build()[1], "icons": make_icons.build()[1], "cursor": make_icons.build()[2],
                  "fonts": mf.build()[1]}
        text = A.render_lua(layout)
        self.assertTrue(text.count("do\n") == 1 and text.rstrip().endswith("end"))
        self.assertNotIn("\r", text)
        for name in CONTRACT_PANELS + CONTRACT_ICONS:
            self.assertIn(f"{name} = ", text)


if __name__ == "__main__":
    unittest.main(verbosity=1)
