#!/usr/bin/env python3
"""Build the petrify post-FX's detail texture, mod/postfx/petrify/sand_detail.png, from mod/textures/sand_albedo.png.

A post-FX effect may only read files in its own folder, and Melange gives post-FX textures no mipmaps, so the shader gets
its own small copy: the albedo box-reduced 4:1 to 128x128 (the reduction keeps it tiling and pre-filters it for the
distances the shader shows it at; petrify.frag fades it out where a texel would be smaller than about a pixel) and
normalised to a mean luminance of 0.5, so the shader can use it as a brightness detail around 1 without moving the
cast's own colour. Run it again whenever sand_albedo.png changes:

    python make_petrify_tex.py

Needs Pillow.
"""
from pathlib import Path

from PIL import Image, ImageStat

MOD = Path(__file__).resolve().parent.parent / "mod"
SRC = MOD / "textures" / "sand_albedo.png"
OUT = MOD / "postfx" / "petrify" / "sand_detail.png"


def main():
    im = Image.open(SRC).convert("RGB")
    w, h = im.size
    im = im.reduce((max(1, w // 128), max(1, h // 128)))
    mean = ImageStat.Stat(im.convert("L")).mean[0] / 255.0
    k = 0.5 / max(mean, 1e-3)
    im = im.point(lambda v: min(255, int(round(v * k))))
    im.save(OUT, optimize=True)
    print(f"{OUT.name}: {im.size[0]}x{im.size[1]}, source mean luminance {mean:.3f}, scaled by {k:.3f}")


if __name__ == "__main__":
    main()
