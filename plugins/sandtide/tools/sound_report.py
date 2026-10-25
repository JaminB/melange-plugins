#!/usr/bin/env python3
"""Report on Sandtide's sounds in mod/sounds/: peak and RMS (dBFS), duration, size, and for loops (names ending in
_loop) the seam: the jump from the last sample back to the first, against the largest sample-to-sample step inside
the file. A seam step well above the in-file steps would click every time the loop wraps.

    python sound_report.py           print the table
    python sound_report.py --strict  also exit 1 when a file breaks the mix targets (one-shot peak above -5 dBFS,
                                     loop RMS above -22 dBFS, a loop seam over 4x the median in-file step, or a file
                                     over 2 MiB)

Stdlib only.
"""
import math
import struct
import sys
import wave
from pathlib import Path

DIR = Path(__file__).resolve().parent.parent / "mod" / "sounds"
MAX_BYTES = 2 * 1024 * 1024


def db(v):
    return 20 * math.log10(v) if v > 0 else -999.0


def read(path):
    with wave.open(str(path), "rb") as w:
        ch, sw, sr, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
        if sw != 2:
            raise SystemExit("%s: not 16-bit" % path.name)
        raw = w.readframes(n)
    data = struct.unpack("<%dh" % (len(raw) // 2), raw)
    chans = [[v / 32768.0 for v in data[c::ch]] for c in range(ch)]
    return chans, sr, n


def main():
    strict = "--strict" in sys.argv[1:]
    bad = 0
    print("%-24s %5s %7s %8s %8s %9s %9s  %s" % ("file", "ch", "secs", "peak", "rms", "seam", "maxstep", "bytes"))
    for path in sorted(DIR.glob("*.wav")):
        chans, sr, n = read(path)
        peak = max(max(abs(v) for v in c) for c in chans)
        rms = math.sqrt(sum(sum(v * v for v in c) for c in chans) / (n * len(chans)))
        size = path.stat().st_size
        loop = path.stem.endswith("_loop")
        seam = maxstep = 0.0
        med = 0.0
        if loop:
            for c in chans:
                steps = sorted(abs(c[i + 1] - c[i]) for i in range(n - 1))
                seam = max(seam, abs(c[0] - c[-1]))
                maxstep = max(maxstep, steps[-1])
                med = max(med, steps[len(steps) // 2])
        notes = []
        if not loop and db(peak) > -5:
            notes.append("one-shot peak above -5 dBFS")
        if loop and db(rms) > -22:
            notes.append("loop RMS above -22 dBFS")
        if loop and seam > max(4 * med, 1e-4) and seam > maxstep * 0.5:
            notes.append("seam step %.4f vs median %.4f: may click" % (seam, med))
        if size > MAX_BYTES:
            notes.append("over 2 MiB")
        bad += len(notes)
        print("%-24s %5d %7.2f %8.1f %8.1f %9s %9s  %d %s" % (
            path.name, len(chans), n / sr, db(peak), db(rms),
            ("%.4f" % seam) if loop else "-", ("%.4f" % maxstep) if loop else "-", size,
            ("  <- " + "; ".join(notes)) if notes else ""))
    if strict and bad:
        sys.exit(1)


if __name__ == "__main__":
    main()
