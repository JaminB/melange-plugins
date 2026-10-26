#!/usr/bin/env python3
"""Bake Holo's two OFL fonts into outlined bitmap atlases (holo-font-1 metrics).

  python tools/make_font.py [--check] [--emit-lua]

Display = Lilita One, body = Baloo 2 ExtraBold, both SIL OFL 1.1, downloaded from the commit and sha256 pinned in
tools/fonts.lock.json (cached in tools/.cache, or HOLO_FONT_CACHE). Glyphs a font lacks (Latin Extended-A, Cyrillic)
come from Rubik ExtraBold (also OFL), scaled to the same cap height. Each atlas is white fill with a black outline baked
in, drawn at scale 2; wum.draw.hudText tints the fill. Four atlases are written (the 4-fonts-per-mod cap): display (28)
and display_s (20), body (20) and body_s (16), so no text is scaled down by more than the 2x bake. Kerning (GPOS) is not
extracted: the metrics carry an empty "kern" (see README-art.md).

Reserved Font Name: Lilita One's OFL.txt reserves "Lilita", and a baked bitmap atlas counts as a Modified Version, so the
baked assets are named "Holo Display" / "Holo Body" in the metrics and README; the original fonts are credited and every
OFL text ships in mod/fonts/OFL.txt.
"""
from __future__ import annotations

import functools
import hashlib
import json
import os
import sys
import urllib.request
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parent))
import _art  # noqa: E402

LOCK = json.loads((_art.TOOLS / "fonts.lock.json").read_text(encoding="utf-8"))
CACHE = Path(os.environ.get("HOLO_FONT_CACHE", _art.TOOLS / ".cache"))
SCALE = 2

# (key, name in metrics, primary font, size at scale 1, outline at scale 1)
FACES = [
    ("display_s", "Holo Display", "lilita", 20, 2),
    ("body", "Holo Body", "baloo", 20, 2),
    ("body_s", "Holo Body", "baloo", 16, 1),
    # ink on the cream title tags: no outline, the tint is the whole glyph
    ("tag", "Holo Display", "lilita", 24, 0),
]

PUNCT = [0x2013, 0x2014, 0x2018, 0x2019, 0x201A, 0x201C, 0x201D, 0x201E, 0x2020, 0x2021, 0x2022, 0x2026, 0x2030,
         0x2039, 0x203A, 0x20AC, 0x2122, 0x2190, 0x2191, 0x2192, 0x2193, 0x2212, 0x00D7]
CODEPOINTS = (list(range(0x20, 0x7F)) + [c for c in range(0xA0, 0x100) if c != 0xAD] + list(range(0x100, 0x180)) +
              list(range(0x400, 0x460)) + [0x490, 0x491] + PUNCT)


def fetch(url: str, sha256: str, dest: Path) -> bytes:
    if dest.is_file():
        data = dest.read_bytes()
        if hashlib.sha256(data).hexdigest() == sha256:
            return data
    print(f"downloading {url}")
    with urllib.request.urlopen(url, timeout=60) as r:
        data = r.read()
    got = hashlib.sha256(data).hexdigest()
    if got != sha256:
        raise SystemExit(f"make_font: sha256 mismatch for {url}: got {got}, lock says {sha256}")
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(data)
    return data


@functools.lru_cache(maxsize=None)
def font_files() -> dict[str, dict]:
    out = {}
    for key, f in LOCK["fonts"].items():
        path = CACHE / f["file"].replace("[", "_").replace("]", "_")
        fetch(f["url"], f["sha256"], path)
        lic = fetch(f["license_url"], f["license_sha256"], CACHE / f["license_file"])
        out[key] = {"path": path, "weight": f["weight"], "family": f["family"], "license": lic.decode("utf-8-sig")}
    return out


def load(key: str, px: float) -> ImageFont.FreeTypeFont:
    info = font_files()[key]
    f = ImageFont.truetype(str(info["path"]), px, layout_engine=ImageFont.Layout.BASIC)
    if info["weight"]:
        f.set_variation_by_axes([info["weight"]])
    return f


def notdef_of(font):
    m = font.getmask("￿")
    return m.size, bytes(m)


def has_glyph(font, cp: int, notdef) -> bool:
    m = font.getmask(chr(cp))
    return (m.size, bytes(m)) != notdef


def cap_height(font) -> float:
    return -font.getbbox("H", anchor="ls")[1]


def render_glyph(font, ch: str, ow: int):
    """White fill with a black outline of `ow` px: (premultiplied rgba array | None, xoff, yoff, advance)."""
    l, t, r, b = font.getbbox(ch, anchor="ls", stroke_width=ow)
    w, h = max(r - l, 0), max(b - t, 0)
    if w == 0 or h == 0:
        return None, 0, 0, font.getlength(ch)
    w, h = w + 2, h + 2
    ox, oy = -l + 1, -t + 1
    fill = Image.new("L", (w, h), 0)
    ImageDraw.Draw(fill).text((ox, oy), ch, fill=255, font=font, anchor="ls")
    both = Image.new("L", (w, h), 0)
    ImageDraw.Draw(both).text((ox, oy), ch, fill=255, font=font, anchor="ls", stroke_width=ow, stroke_fill=255)
    mf = np.asarray(fill, dtype=np.float32) / 255.0
    ms = np.maximum(np.asarray(both, dtype=np.float32) / 255.0, mf)
    canvas = _art.new_canvas(w, h)
    _art.over(canvas, _art.INK, ms)
    _art.over(canvas, _art.WHITE, mf)
    return canvas, l - 1, t - 1, font.getlength(ch)


def bake(key: str, name: str, primary: str, size: int, outline: int):
    px = size * SCALE
    ow = outline * SCALE
    main = load(primary, px)
    fall = load("rubik", px)
    # Rubik is scaled to the primary's cap height so mixed text keeps one line.
    fall = load("rubik", px * cap_height(main) / cap_height(fall))
    nd_main, nd_fall = notdef_of(main), notdef_of(fall)
    items = []  # (cp, canvas, xoff, yoff, adv)
    for cp in CODEPOINTS:
        if has_glyph(main, cp, nd_main):
            f = main
        elif has_glyph(fall, cp, nd_fall):
            f = fall
        else:
            continue
        canvas, xo, yo, adv = render_glyph(f, chr(cp), ow)
        items.append((cp, canvas, xo, yo, adv))
    gap = 2
    sizes = [(0, 0) if c is None else (c.shape[1], c.shape[0]) for _, c, *_ in items]
    best = None  # the narrowest-area packing within 2048x1024 (widths in steps of 128)
    for w in range(512, 2049, 128):
        p, hh = _art.shelf_pack(sizes, w, gap)
        hh = (hh + 3) // 4 * 4
        if hh <= 1024 and (best is None or w * hh < best[0] * best[2]):
            best = (w, p, hh)
    if best is None:
        raise SystemExit(f"make_font: {key} does not fit 2048x1024")
    width, pos, ah = best
    atlas = _art.new_canvas(width, ah)
    glyphs = {}
    top = 0
    for (cp, canvas, xo, yo, adv), (x, y), (w, h) in zip(items, pos, sizes):
        if canvas is not None:
            atlas[y:y + h, x:x + w] = canvas
        glyphs[str(cp)] = [x, y, w, h, int(xo), int(yo), int(round(adv))]
        if 0x41 <= cp <= 0x5A or 0x30 <= cp <= 0x39:
            top = max(top, -yo)  # the tallest capital or digit, outline included
    _, d = main.getmetrics()
    ascent = int(top)
    descent = int(max(d, ow))
    metrics = {
        "format": "holo-font-1", "name": name, "size": size, "scale": SCALE, "lineHeight": ascent + descent,
        "ascent": ascent, "outline": ow, "glyphs": glyphs, "kern": {},
    }
    return _art.png_bytes(_art.to_straight(atlas)), metrics, (width, ah)


@functools.lru_cache(maxsize=None)
def build():
    files: dict[str, bytes] = {}
    layout = {}
    for key, name, primary, size, outline in FACES:
        png, metrics, (w, h) = bake(key, name, primary, size, outline)
        files[f"mod/fonts/{key}.png"] = png
        text = json.dumps(metrics, separators=(",", ":"), ensure_ascii=True)
        text = text.replace('"glyphs":{', '"glyphs":{\n').replace('],"', '],\n"')  # one glyph per line: readable diffs
        files[f"mod/fonts/{key}.json"] = (text + "\n").encode("utf-8")
        layout[key] = {"png": f"fonts/{key}.png", "json": f"fonts/{key}.json", "size": size, "w": w, "h": h}
    files["mod/fonts/OFL.txt"] = font_notice().encode("utf-8")
    return files, layout


def font_notice() -> str:
    infos = font_files()
    parts = [
        "Holo ships bitmap atlases baked from these fonts (white fill, black outline) and their glyph metrics. The atlases\n"
        "are named \"Holo Display\" (from Lilita One, whose Reserved Font Name is \"Lilita\") and \"Holo Body\" (from Baloo 2),\n"
        "with Rubik supplying the Latin Extended-A and Cyrillic glyphs. Each font is licensed under the SIL Open Font\n"
        "License, Version 1.1; its notice and the licence text follow. The fonts are not sold on their own.\n"
    ]
    for key in ("lilita", "baloo", "rubik"):
        i = infos[key]
        parts.append("=" * 78 + f"\n{i['family']}\n" + "=" * 78 + "\n" + i["license"].replace("\r\n", "\n").strip("\n") + "\n")
    return "\n".join(parts)


if __name__ == "__main__":
    sys.exit(_art.run_cli("make_font", build, sys.argv[1:]))
