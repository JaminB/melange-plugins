#!/usr/bin/env python3
"""Generate Sunstone's colour-grading LUTs: golden.png and dusk.png into mod/postfx/grade/.

256x16, 16 slices of 16x16 side by side (blue picks the slice, matching grade.frag's SampleLut). Pure code: an ASC
CDL (slope/offset/power) per channel plus a saturation mix, applied to an identity grid. No external image input.
Stdlib only.
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


def saturate(c, amount):
    luma = 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]
    return [max(0.0, min(1.0, luma + (v - luma) * amount)) for v in c]


def make_look(slope, offset, power, sat):
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
    # Warm highlights, a touch of teal in the shadows: a classic "golden hour" grade.
    "golden.png": dict(slope=(1.08, 1.0, 0.88), offset=(0.02, 0.0, -0.02), power=(0.92, 1.0, 1.08), sat=1.08),
    # Cooler shadows, warm highlights, slightly desaturated: dusk rather than noon.
    "dusk.png": dict(slope=(0.95, 0.95, 1.08), offset=(-0.01, -0.02, 0.03), power=(1.05, 1.0, 0.9), sat=0.92),
}


def main():
    out_dir = Path(__file__).resolve().parent.parent / "mod" / "postfx" / "grade"
    for name, look in LOOKS.items():
        rows = make_look(look["slope"], look["offset"], look["power"], look["sat"])
        write_png(out_dir / name, rows, WIDTH, HEIGHT)
        print(f"wrote {out_dir / name}")


if __name__ == "__main__":
    main()
