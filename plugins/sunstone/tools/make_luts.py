#!/usr/bin/env python3
"""Generate Sunstone's colour-grading LUTs: golden.png and dusk.png into mod/postfx/hdr/.

256x16, 16 slices of 16x16 side by side (blue picks the slice, matching composite.frag's SampleLut). Pure code: an
ASC CDL (slope/offset/power) per channel, a split tone (one tint for the shadows, one for the highlights) and a
saturation mix, applied to an identity grid. No external image input. Stdlib only.
"""
import struct
import zlib
from pathlib import Path

SIZE = 16
WIDTH = SIZE * SIZE
HEIGHT = SIZE


def cdl(c, slope, offset, power):
    out = []
    for v, s, o, p in zip(c, slope, offset, power):
        v = max(0.0, min(1.0, v * s + o))
        out.append(v ** p)
    return out


def luma(c):
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]


def smoothstep(e0, e1, x):
    t = max(0.0, min(1.0, (x - e0) / (e1 - e0)))
    return t * t * (3.0 - 2.0 * t)


def split_tone(c, shadows, highlights):
    y = luma(c)
    ws = 1.0 - smoothstep(0.05, 0.5, y)
    wh = smoothstep(0.4, 0.9, y)
    return [max(0.0, min(1.0, v + s * ws + h * wh)) for v, s, h in zip(c, shadows, highlights)]


def saturate(c, amount):
    y = luma(c)
    return [max(0.0, min(1.0, y + (v - y) * amount)) for v in c]


def make_look(slope, offset, power, shadows, highlights, sat):
    rows = []
    for py in range(HEIGHT):
        g = py / (SIZE - 1)
        row = bytearray()
        for px in range(WIDTH):
            s0 = px // SIZE
            r_idx = px % SIZE
            r = r_idx / (SIZE - 1)
            b = s0 / (SIZE - 1)
            c = cdl((r, g, b), slope, offset, power)
            c = split_tone(c, shadows, highlights)
            c = saturate(c, sat)
            row += bytes(int(round(v * 255)) for v in c)
        rows.append(bytes(row))
    return rows


def write_png(path, rows, width, height):
    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    raw = bytearray()
    for row in rows:
        raw.append(0)  # filter type: none
        raw += row
    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)  # 8-bit RGB
    idat = zlib.compress(bytes(raw), 9)
    with open(path, "wb") as f:
        f.write(sig)
        f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", idat))
        f.write(chunk(b"IEND", b""))


LOOKS = {
    # Warm highlights and cool shadows at the scene's own saturation: daylight, not a filter.
    "golden.png": dict(slope=(1.04, 1.0, 0.95), offset=(0.0, 0.0, 0.0), power=(0.97, 1.0, 1.03),
                       shadows=(-0.012, 0.0, 0.016), highlights=(0.022, 0.008, -0.026), sat=1.0),
    # Cooler shadows, warm highlights, slightly desaturated: dusk rather than noon.
    "dusk.png": dict(slope=(0.95, 0.95, 1.08), offset=(-0.01, -0.02, 0.03), power=(1.05, 1.0, 0.9),
                     shadows=(-0.01, 0.0, 0.015), highlights=(0.015, 0.0, -0.015), sat=0.92),
}

OUT_DIRS = [Path(__file__).resolve().parent.parent / "mod" / "postfx" / "hdr"]


def main():
    for name, look in LOOKS.items():
        rows = make_look(look["slope"], look["offset"], look["power"], look["shadows"], look["highlights"], look["sat"])
        for out_dir in OUT_DIRS:
            write_png(out_dir / name, rows, WIDTH, HEIGHT)
            print(f"wrote {out_dir / name}")


if __name__ == "__main__":
    main()
