#!/usr/bin/env python3
"""Build the texture fingerprint table of Sunstone's lit-model shader (mod/shaders/FixedFunction.FFFragmentMainTexLit.glsl).

The worms' skin is found in that shader by the worm's own material and its peach texel, but the parts a worm wears are drawn
with a material it shares with many props (specular = rim colour (0.3, 0.275, 0.175), gloss 8; the afro wig has a second
one). Which of those textures is a moustache, a hair hat or a glove with the worm's bare skin in it is told by the texture
itself: the shader reads it at three fixed places (PROBES) and compares the three colours with this table. The game's
textures are read from its bundles (Data\\Bundles\\*.xom) with the XOM reader in Melange's repository (tools/xom), so this is
a development tool, not part of the plugin; it rewrites the block between the BEGIN/END FINGERPRINTS markers of the shader.

Every texture drawn with one of those materials (about 760 of them, props included) is checked: an entry must be at least
2 * TOLERANCE away (largest channel difference over the three probes) from every other texture that is not identical to it
or of the same kind (a glove need only be told from textures that have the skin's colour in them), or the tool stops.

    python tools/make_fingerprints.py --bundles "<game>/Data/Bundles" --xom "<melange repo>/tools/xom"         --extra "plugins/kindjal*/mod/assets/meshes/*.xom" [--report] [--search]

Classes (the shader's code is class * 16 + hair colour):
  1 glove      the texels with the worm skin's colour (SkinChroma, brighter than the entry's minimum red) take the tone
  2 moustache  hair; Natural gives it the entry's colour, Mixed the worm's own
  3 hair hat   hair (with Realistic hair hats on), in the entry's colour (0: its own dyed colour)
  4 hair hat   only its dark texels are hair (below the entry's cutoff luminance); the rest (bone, a forehead, gold) is not
Hair colours (the shader's HairAlbedo): 1 black, 2 dark brown, 3 brown, 4 light brown, 5 dark blonde, 6 blonde, 7 auburn,
8 ginger, 9 grey, 10 white; 0 the texture's own colour.

Stdlib only, except --search (numpy), which looks for better probe places.
"""
import argparse
import glob
import hashlib
import os
import re
import sys
from pathlib import Path

SHADER = Path(__file__).resolve().parent.parent / "mod" / "shaders" / "FixedFunction.FFFragmentMainTexLit.glsl"

# Texture coordinates of the three probes (GL: v = 0 is the first row the game uploads, the image's bottom row).
PROBES = [(0.0546875, 0.9765625), (0.9609375, 0.4609375), (0.6484375, 0.1953125)]
TOLERANCE = 0.03

# Natural hair colour of every moustache and hair hat, by its resource id.
HAIR = {
    "Mustache.Afro": 1, "Mustache.Afro.Blond": 6, "Mustache.Afro.Grey": 9, "Mustache.Afro.Red": 8,
    "Mustache.Chinese": 9,
    "Mustache.Cowboy": 2, "Mustache.Cowboy.Black": 1, "Mustache.Cowboy.Grey": 9, "Mustache.Cowboy.Blond": 6,
    "Mustache.Curly": 2, "Mustache.Curly.Blond": 6, "Mustache.Curly.Grey": 9, "Mustache.Curly.Red": 8,
    "Mustache.Professor": 10, "Mustache.Scott": 8,
    "Mustache.Small.Brown": 2, "Mustache.Small.Blonde": 6, "Mustache.Small.Red": 8, "Mustache.Small.White": 9,
    "Mustache.Viking": 5, "Mustache.Viking.Black": 1, "Mustache.Viking.Grey": 9, "Mustache.Viking.Red": 8,
    "Hat.Afro": 1, "Hat.Professor": 10,
    "Hat.Pigtails": 0, "Hat.Pigtails.Bl": 0, "Hat.Pigtails.Bnd": 6, "Hat.Pigtails.R": 8,
    "Hat.Punk": 0, "Hat.Punk.Bl": 0, "Hat.Punk.Gr": 0, "Hat.Punk.Y": 0,
    "Hat.Prehistoric": 1, "Hat.Frankenstein": 1, "Hat.QueenOfSheba": 1,
}
# Hair hats whose texture also holds other things: the hair is what is darker than this luminance.
PARTIAL = {"Hat.Prehistoric": 0.36, "Hat.Frankenstein": 0.36, "Hat.QueenOfSheba": 0.42}
# Gloves whose cloth or leather has the skin's chroma where it is dark: only texels this bright are skin there.
GLOVE_RMIN = {"Gloves.Sport": 0.8, "Gloves.Knight": 0.8}
GLOVE_RMIN_DEFAULT = 0.5
# Which class a texture shared by two kinds of part takes.
PRIORITY = {2: 3, 3: 2, 4: 2, 1: 1}


def matte(mat):
    spec, power = mat[0], mat[2]
    return 0.24 <= spec[0] <= 0.31 and 4.5 <= power <= 8.5


def skin_chroma(c):
    r, g, b = c[0], c[1], c[2]
    if r < 1e-3:
        return False
    u, v = g / r, b / r
    return 0.56 < u < 0.73 and 0.39 < v < 0.57 and r > 0.48


def lum(c):
    return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]


class Image:
    def __init__(self, w, h, bpp, data):
        self.w, self.h, self.bpp, self.data = w, h, bpp, data
        self.digest = hashlib.sha1(data).hexdigest()

    def texel(self, x, y):
        o = ((y % self.h) * self.w + (x % self.w)) * self.bpp
        return [self.data[o + k] / 255.0 for k in range(3)]

    def sample(self, u, v):
        """Bilinear, as the GPU filters the base level of a texture read at a constant coordinate."""
        x, y = u * self.w - 0.5, v * self.h - 0.5
        x0, y0 = int(x // 1), int(y // 1)
        fx, fy = x - x0, y - y0
        a, b, c, d = self.texel(x0, y0), self.texel(x0 + 1, y0), self.texel(x0, y0 + 1), self.texel(x0 + 1, y0 + 1)
        return [a[k] * (1 - fx) * (1 - fy) + b[k] * fx * (1 - fy) + c[k] * (1 - fx) * fy + d[k] * fx * fy for k in range(3)]

    def pixels(self):
        for i in range(self.w * self.h):
            o = i * self.bpp
            yield (self.data[o] / 255.0, self.data[o + 1] / 255.0, self.data[o + 2] / 255.0)


def gather(paths, xom):
    """Every image drawn with a matte material, with the bundle's resource id and the shader's name."""
    out = []
    for path in paths:
        doc = xom.load(path)
        objs = doc["objects"]
        ids = [o["fields"].get("ResourceId") for o in objs if isinstance(o.get("fields"), dict) and o["fields"].get("ResourceId")]
        rid = ids[0] if ids else ""
        for o in objs:
            if o.get("type") != "XSimpleShader":
                continue
            f = o["fields"]
            mat = None
            for a in f.get("Attributes", []):
                ao = xom.obj(doc, a)
                if ao and ao.get("type") == "XMaterial":
                    af = ao["fields"]
                    mat = [af["Specular"][:3], af.get("Fresnel", [0, 0, 0])[:3], af["Power"]]
            if not mat or not matte(mat):
                continue
            for t in f.get("TextureStages", []):
                to = xom.obj(doc, t)
                if not (to and "Texture" in to.get("fields", {})):
                    continue
                im = xom.obj(doc, to["fields"]["Texture"])
                if not (im and im.get("type") == "XImage") or im["fields"]["Format"] not in (0, 1):
                    continue
                imf = im["fields"]
                bpp = 3 if imf["Format"] == 0 else 4
                raw = imf["Data"]
                data = bytes.fromhex(raw["hex"]) if isinstance(raw, dict) else bytes(raw)
                data = data[: imf["Width"] * imf["Height"] * bpp]   # the base level, rows bottom-up as uploaded
                out.append((rid, f.get("Name") or "", Image(imf["Width"], imf["Height"], bpp, data)))
    return out


def classify(rid, shader, img):
    if rid.startswith("Gloves"):
        n = sum(1 for p in img.pixels() if skin_chroma(p))
        return 1 if n >= 0.005 * img.w * img.h else 0
    if rid.startswith("Mustache") and rid in HAIR:
        return 2
    if rid in PARTIAL:
        return 4
    if rid in HAIR and rid.startswith("Hat") and (not rid.startswith("Hat.Pigtails") or "pigtailhair" in shader):
        return 3
    return 0


def build(items):
    """One entry per distinct texture; a texture shared by a moustache and a hat is a moustache."""
    entries = {}
    for rid, shader, img in items:
        cls = classify(rid, shader, img)
        if not cls:
            continue
        e = entries.get(img.digest)
        if e and PRIORITY[e["cls"]] >= PRIORITY[cls]:
            continue
        base = next((k for k in GLOVE_RMIN if rid.startswith(k)), None)
        if cls == 1:
            extra = GLOVE_RMIN.get(base, GLOVE_RMIN_DEFAULT)
            mean = 1.0
        else:
            cut = PARTIAL.get(rid, 9.0)
            hair = [lum(p) for p in img.pixels() if lum(p) < cut]
            mean = sum(hair) / max(1, len(hair))
            extra = cut if cls == 4 else 0.0
        entries[img.digest] = {"rid": rid, "cls": cls, "hair": HAIR.get(rid, 0), "mean": mean, "extra": extra, "img": img,
                               "probes": [img.sample(u, v) for u, v in PROBES]}
    # Sorted by probe A's red, which the shader binary-searches (a scan of the whole table in every fragment of every
    # matte prop cost up to 0.6 ms a frame where props filled the screen).
    return sorted(entries.values(), key=lambda e: (e["probes"][0][0], e["cls"], e["rid"]))


def check(entries, items):
    """The smallest distance from each entry to any other texture it must be told from."""
    probes = {}
    for rid, shader, img in items:
        if img.digest not in probes:
            skin = any(skin_chroma(p) for p in img.pixels())
            probes[img.digest] = (rid, skin, [img.sample(u, v) for u, v in PROBES])
    worst = []
    for e in entries:
        best, who = 9.0, ""
        for dig, (rid, skin, ps) in probes.items():
            # A texture taken for a glove only has its skin-coloured texels toned: one with none cannot be harmed.
            if dig == e["img"].digest or (e["cls"] == 1 and (rid.startswith("Gloves") or not skin)):
                continue
            d = max(abs(a - b) for pa, pb in zip(ps, e["probes"]) for a, b in zip(pa, pb))
            if d < best:
                best, who = d, rid
        worst.append((best, e["rid"], who))
    return worst


def fmt(v):
    s = f"{v:.3f}".rstrip("0").rstrip(".")
    return s if "." in s else s + ".0"


def glsl(entries):
    n = len(entries)
    rows_a, rows_b, rows_c = [], [], []
    for e in entries:
        pa, pb, pc = e["probes"]
        rows_a.append(f"vec4({fmt(pa[0])}, {fmt(pa[1])}, {fmt(pa[2])}, {fmt(e['cls'] * 16 + e['hair'])})")
        rows_b.append(f"vec4({fmt(pb[0])}, {fmt(pb[1])}, {fmt(pb[2])}, {fmt(e['mean'])})")
        rows_c.append(f"vec4({fmt(pc[0])}, {fmt(pc[1])}, {fmt(pc[2])}, {fmt(e['extra'])})")
    names = ", ".join(sorted({e["rid"] for e in entries}))
    out = ["// BEGIN FINGERPRINTS (generated by tools/make_fingerprints.py; do not edit by hand)"]
    out.append(f"// {n} textures: " + names)
    out.append(f"const vec2 PROBE_A = vec2({PROBES[0][0]!r}, {PROBES[0][1]!r});")
    out.append(f"const vec2 PROBE_B = vec2({PROBES[1][0]!r}, {PROBES[1][1]!r});")
    out.append(f"const vec2 PROBE_C = vec2({PROBES[2][0]!r}, {PROBES[2][1]!r});")
    out.append(f"const float FP_TOL = {fmt(TOLERANCE)};")
    out.append(f"const int FP_N = {n};")
    for name, rows, what in (("FP_A", rows_a, "probe A colour, class * 16 + hair colour (sorted by red, see Fingerprint)"),
                             ("FP_B", rows_b, "probe B colour, mean luminance of the hair"),
                             ("FP_C", rows_c, "probe C colour, hair cutoff (class 4) or the glove skin's minimum red")):
        out.append(f"// {what}")
        out.append(f"const vec4 {name}[FP_N] = vec4[FP_N](")
        out.append(",\n".join("    " + r for r in rows))
        out.append(");")
    out.append("// END FINGERPRINTS")
    return "\n".join(out)


def search(items):
    import itertools
    import numpy as np
    uniq = {}
    for rid, shader, img in items:
        uniq.setdefault(img.digest, (rid, classify(rid, shader, img), img))
    keys = list(uniq)
    G = 64
    cands = [((i + 0.5) / G, (j + 0.5) / G) for i in range(G) for j in range(G)]
    arr = {}
    for k in keys:
        img = uniq[k][2]
        a = np.frombuffer(img.data, np.uint8).reshape(img.h, img.w, img.bpp)[..., :3].astype(np.float32) / 255
        arr[k] = a
    L = np.zeros((len(keys), len(cands), 3), np.float32)
    S = np.zeros((len(keys), len(cands)), np.float32)
    for ki, k in enumerate(keys):
        a = arr[k]
        h, w = a.shape[:2]
        for ci, (u, v) in enumerate(cands):
            x, y = u * w - 0.5, v * h - 0.5
            x0, y0 = int(np.floor(x)), int(np.floor(y))
            fx, fy = x - x0, y - y0
            t = lambda xx, yy: a[yy % h, xx % w]
            L[ki, ci] = t(x0, y0) * (1 - fx) * (1 - fy) + t(x0 + 1, y0) * fx * (1 - fy) + t(x0, y0 + 1) * (1 - fx) * fy + t(x0 + 1, y0 + 1) * fx * fy
            S[ki, ci] = np.abs(L[ki, ci] - a[int(np.floor(v * h)) % h, int(np.floor(u * w)) % w]).max()
    pos = [i for i, k in enumerate(keys) if uniq[k][1]]
    others = {p: np.array([q for q in range(len(keys)) if q != p and not (uniq[keys[p]][1] == 1 and uniq[keys[q]][1] == 1)]) for p in pos}
    smooth = S[pos].max(0)
    cand = list(np.argsort(smooth)[:80])

    def mind(cs):
        worst = 9.0
        for p in pos:
            o = others[p]
            dd = np.zeros(len(o), np.float32)
            for c in cs:
                dd = np.maximum(dd, np.abs(L[o, c] - L[p, c]).max(-1))
            worst = min(worst, float(dd.min()))
        return worst

    best2 = max((mind((a, b)), a, b) for a, b in itertools.combinations(cand, 2))
    best3 = max((mind((best2[1], best2[2], c)), c) for c in cand if c not in best2[1:])
    picks = [best2[1], best2[2], best3[1]]
    print("separation", round(best3[0], 3), "smoothness", [round(float(smooth[c]), 3) for c in picks])
    print("PROBES =", [cands[c] for c in picks])


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bundles", required=True, help="the game's Data/Bundles folder")
    ap.add_argument("--xom", required=True, help="tools/xom of Melange's repository (the XOM reader)")
    ap.add_argument("--extra", action="append", default=[],
                    help="more XOM files (a glob) whose textures the table must not take for anything, e.g. the meshes "
                         "of plugins that add weapons (repeatable)")
    ap.add_argument("--report", action="store_true", help="list the entries and their margins")
    ap.add_argument("--search", action="store_true", help="look for probe places instead (needs numpy)")
    ap.add_argument("--shader", default=str(SHADER))
    args = ap.parse_args()
    sys.path.insert(0, args.xom)
    import xom  # noqa: E402

    paths = sorted(glob.glob(os.path.join(args.bundles, "*.xom")))
    for pattern in args.extra:
        paths += sorted(glob.glob(pattern))
    items = gather(paths, xom)
    if args.search:
        search(items)
        return
    entries = build(items)
    worst = check(entries, items)
    if args.report:
        for e, (d, rid, who) in zip(entries, worst):
            print(f"{e['cls']} {e['hair']:2d} {e['rid']:28s} mean {e['mean']:.3f} extra {e['extra']:.2f}  nearest {d:.3f} ({who})")
    if len(entries) > 127:
        sys.exit("more than 127 entries: raise the shader's binary search steps in Fingerprint()")
    bad = [w for w in worst if w[0] < 2 * TOLERANCE]
    if bad:
        for d, rid, who in bad:
            print(f"too close: {rid} and {who} ({d:.3f})", file=sys.stderr)
        sys.exit(1)
    text = Path(args.shader).read_text(encoding="utf-8")
    block = glsl(entries)
    new, n = re.subn(r"// BEGIN FINGERPRINTS.*?// END FINGERPRINTS", lambda m: block, text, flags=re.S)
    if n != 1:
        sys.exit("the shader has no BEGIN/END FINGERPRINTS block")
    Path(args.shader).write_text(new, encoding="utf-8", newline="\n")
    print(f"{len(entries)} entries from {len(items)} matte textures; nearest other texture {min(w[0] for w in worst):.3f}")


if __name__ == "__main__":
    main()
