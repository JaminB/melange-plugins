#!/usr/bin/env python3
"""Build Sandtide's tiling surface textures from CC0 ambientCG materials into mod/textures/.

    sand_albedo.png  512x512  Ground097 colour map, box-reduced 2:1, with a touch more local contrast and a fine
                              per-pixel grain so it holds up close on a worm
    sand_normal.png  512x512  Ground097 OpenGL normal map (+Y up, as ambientCG's NormalGL), box-reduced 2:1, renormalised
    cracks.png       512x512  crack mask from Ground031's displacement (dried, cracked desert ground): the narrow
                              valleys, found as depth under a local average; the mask is in every channel (R=G=B=A)

All three tile seamlessly: the sources tile, the 2:1 box reduction keeps that, and every filter here wraps around.
The source materials are CC0 1.0 (https://docs.ambientcg.com/license/) and are not stored in the repo; download the
1K-JPG zips and pass the folder that holds the extracted *_Color.jpg / *_NormalGL.jpg / *_Displacement.jpg files:

    https://ambientcg.com/a/Ground097   https://ambientcg.com/get?file=Ground097_1K-JPG.zip
    https://ambientcg.com/a/Ground031   https://ambientcg.com/get?file=Ground031_1K-JPG.zip

    python make_textures.py --src <folder>

Needs numpy and Pillow.
"""
import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _art import blur, save  # noqa: E402

OUT = Path(__file__).resolve().parent.parent / "mod" / "textures"


def wrap_blur(a, r):
    """Blur with wrap-around edges: blur a 3x3 tiling and keep the centre."""
    h, w = a.shape
    t = np.tile(a, (3, 3))
    return blur(t, r)[h:2 * h, w:2 * w]


def load(src, pattern):
    hits = sorted(Path(src).glob(pattern))
    if not hits:
        sys.exit("no %s in %s" % (pattern, src))
    return Image.open(hits[0])


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--src", required=True, help="folder with the extracted ambientCG 1K-JPG maps")
    args = ap.parse_args()

    # sand albedo
    im = load(args.src, "Ground097_*_Color.jpg").convert("RGB")
    im = im.reduce(im.width // 512)
    a = np.asarray(im, dtype=np.float64) / 255.0
    lum = a.mean(axis=2)
    local = wrap_blur(lum, 10.0)
    detail = lum - local
    a = a + detail[..., None] * 0.6                      # lift the ripples a little
    rng = np.random.default_rng(97)
    grain = rng.standard_normal(lum.shape)
    grain = grain - wrap_blur(grain, 1.0) * 0.5
    a *= (1.0 + 0.045 * grain)[..., None]
    sparkle = (rng.random(lum.shape) > 0.9985) * rng.uniform(0.05, 0.18, lum.shape)
    a += sparkle[..., None]
    out = Image.fromarray((np.clip(a, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB")
    save(out, OUT / "sand_albedo.png")

    # sand normal
    im = load(args.src, "Ground097_*_NormalGL.jpg").convert("RGB")
    im = im.reduce(im.width // 512)
    n = np.asarray(im, dtype=np.float64) / 255.0 * 2.0 - 1.0
    n /= np.linalg.norm(n, axis=2, keepdims=True) + 1e-9
    save(Image.fromarray(((n * 0.5 + 0.5) * 255 + 0.5).astype(np.uint8), "RGB"), OUT / "sand_normal.png")

    # cracks
    im = load(args.src, "Ground031_*_Displacement.jpg").convert("L")
    d = np.asarray(im, dtype=np.float64) / 255.0
    valley = wrap_blur(d, 5.0) - d
    m = np.clip((valley - 0.035) / 0.10, 0.0, 1.0)
    m = wrap_blur(m, 0.6)
    m = np.clip(m * 1.3, 0, 1) ** 0.9
    img = Image.fromarray((m * 255 + 0.5).astype(np.uint8), "L")
    img = img.reduce(img.width // 512)
    g = np.asarray(img)
    save(Image.fromarray(np.dstack([g, g, g, g]), "RGBA"), OUT / "cracks.png")
    print("wrote sand_albedo.png, sand_normal.png, cracks.png to", OUT)


if __name__ == "__main__":
    main()
