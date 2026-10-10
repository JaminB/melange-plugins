#!/usr/bin/env python3
"""Generate Kindjal's sound effects into mod/sounds/.

Twelve mono 16-bit 44.1 kHz WAVs: kj_swing, kj_impact_bat / _stab / _spike, kj_firepunch, kj_launch,
kj_boom_small / _med / _large, kj_crucible, kj_acid_burst, kj_acid_hiss. Every sound is synthesised here from scratch
(noise bursts shaped by envelopes, time-varying biquad low/band/high-pass filters for body, pitch-dropping sines for
sub-booms, decaying inharmonic partials for the metal, granular blips for bubbles and debris, tanh saturation for grit),
so nothing comes from the game or any other recording. All randomness comes from seeded random.Random instances, so the
output is deterministic; --check regenerates everything in memory and compares it byte-for-byte with the files on disk.
Each sound is peak-normalised to -1 dBFS with a 5 ms fade in and out (kj_acid_hiss is a loop: no fades, and its tail is
crossfaded into its head so the loop point is seamless). Stdlib only.

    python make_sounds.py          write the files
    python make_sounds.py --check  verify the files on disk (exit 1 on any difference)
"""
import io
import math
import random
import struct
import sys
import wave
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "mod" / "sounds"

SR = 44100
PEAK = 10 ** (-1.0 / 20)        # -1 dBFS
FADE = 0.005                    # seconds
MAX_BYTES = 300 * 1000          # per-file store limit we promise in the asset contract
TWO_PI = 2 * math.pi


# ---------------------------------------------------------------- small helpers
def ms(t):
    """Seconds -> samples."""
    return int(round(t * SR))


def zeros(n):
    return [0.0] * n


def noise(rng, n):
    return [rng.random() * 2.0 - 1.0 for _ in range(n)]


def mul(a, b):
    return [p * q for p, q in zip(a, b)]


def scaled(x, peak=1.0):
    """Scale so the largest magnitude is `peak`, so layer gains mean the same thing whatever the filter did."""
    m = max(abs(v) for v in x) or 1.0
    return [v * peak / m for v in x]


def add(dst, src, off=0.0, gain=1.0):
    """Mix `src` into `dst` starting `off` seconds in (clipped to dst's length)."""
    o = ms(off)
    n = min(len(src), len(dst) - o)
    for i in range(n):
        dst[o + i] += src[i] * gain


def sat(x, drive):
    """Soft clip: tanh waveshaper, normalised so a full-scale input stays near full scale. Adds grit and glues layers."""
    k = math.tanh(drive)
    return [math.tanh(drive * v) / k for v in x]


def decay_f(lo, hi, tau):
    """Cutoff/centre-frequency curve starting at `hi` and falling to `lo` with time constant tau (seconds)."""
    return lambda i: lo + (hi - lo) * math.exp(-i / (tau * SR))


def env(n, att, tau, hold=0.0):
    """Quarter-sine attack of `att` s, optional hold, then exponential decay with time constant `tau` s."""
    a = max(att * SR, 1.0)
    h = hold * SR
    k = 1.0 / (tau * SR)
    out = []
    for i in range(n):
        v = math.sin(0.5 * math.pi * i / a) if i < a else 1.0
        if i > a + h:
            v *= math.exp(-(i - a - h) * k)
        out.append(v)
    return out


def biquad(x, kind, f, q=0.707, step=8):
    """RBJ biquad ('lp', 'hp' or 'bp' with 0 dB peak). `f` is a number or a function of the sample index (Hz); the
    coefficients are refreshed every `step` samples so cutoff sweeps stay cheap and smooth."""
    fn = f if callable(f) else (lambda i: f)
    n = len(x)
    y = [0.0] * n
    z1 = z2 = 0.0
    b0 = b1 = b2 = a1 = a2 = 0.0
    for i in range(n):
        if i % step == 0:
            fc = min(max(fn(i), 20.0), SR * 0.45)
            w = TWO_PI * fc / SR
            cw, sw = math.cos(w), math.sin(w)
            al = sw / (2.0 * q)
            if kind == "lp":
                b0 = (1 - cw) / 2
                b1 = 1 - cw
                b2 = b0
            elif kind == "hp":
                b0 = (1 + cw) / 2
                b1 = -(1 + cw)
                b2 = b0
            else:
                b0 = al
                b1 = 0.0
                b2 = -al
            a0 = 1 + al
            b0, b1, b2 = b0 / a0, b1 / a0, b2 / a0
            a1, a2 = -2 * cw / a0, (1 - al) / a0
        xi = x[i]
        yi = b0 * xi + z1
        z1 = b1 * xi - a1 * yi + z2
        z2 = b2 * xi - a2 * yi
        y[i] = yi
    return y


def noise_band(rng, n, kind, f, q=0.707):
    """Peak-normalised filtered white noise."""
    return scaled(biquad(noise(rng, n), kind, f, q))


def sweep_sine(n, f0, f1, tau, tri=0.0):
    """Sine whose pitch falls from f0 to f1 (exponentially, time constant tau s). tri blends in a triangle wave for a
    harder, more thump-like edge."""
    ph = 0.0
    out = []
    for i in range(n):
        fr = f1 + (f0 - f1) * math.exp(-i / (tau * SR))
        ph += TWO_PI * fr / SR
        s = math.sin(ph)
        if tri:
            u = (ph / TWO_PI) % 1.0
            s = s * (1 - tri) + (2.0 * abs(2.0 * u - 1.0) - 1.0) * tri
        out.append(s)
    return out


def metal(n, freqs, decays, amps):
    """Struck metal: a handful of inharmonic partials, each ringing out at its own rate (seconds)."""
    out = zeros(n)
    for f, d, a in zip(freqs, decays, amps):
        k = 1.0 / (d * SR)
        w = TWO_PI * f / SR
        for i in range(n):
            out[i] += a * math.exp(-i * k) * math.sin(w * i)
    return out


def bubble(rng, f0, dur, gain=1.0):
    """One bubble: a short sine blip whose pitch rises as it pops, with a soft 1 ms attack and fast decay."""
    n = ms(dur)
    ph = 0.0
    out = []
    for i in range(n):
        t = i / SR
        ph += TWO_PI * f0 * (1.0 + 1.3 * t / dur) / SR
        out.append(math.sin(ph) * min(1.0, i / 44.0) * math.exp(-t / (dur / 3.2)) * gain)
    return out


def crunch_grains(x, rng, count, start, span, flo, fhi, dmin, dmax, gain, q=2.5, bias=1.5):
    """Scatter short band-passed noise grains (bone, gravel, rubble) over [start, start+span], front-loaded by `bias`."""
    for _ in range(count):
        t = start + span * rng.random() ** bias
        f = flo * (fhi / flo) ** rng.random()
        d = dmin + (dmax - dmin) * rng.random()
        m = ms(d)
        g = noise_band(rng, m, "bp", f, q)
        e = env(m, 0.0007, d / 3.0)
        add(x, mul(g, e), t, gain * (0.4 + 0.6 * rng.random()))


def crackle(rng, n, rate, f, q=1.5):
    """Poisson clicks (random impulses) through a resonant band-pass: sizzle, embers, wet crackle."""
    p = rate / SR
    imp = [(rng.random() * 2.0 - 1.0) if rng.random() < p else 0.0 for _ in range(n)]
    return scaled(biquad(imp, "bp", f, q))


def echoes(x, taps):
    """Add (delay_s, gain, lowpass_hz) reflections, each darker than the last, to fake a large space."""
    out = list(x)
    for d, g, lp in taps:
        add(out, biquad(x, "lp", lp, 0.6), d, g)
    return out


def dc_block(x, r=0.99886):
    """One-pole high-pass near 8 Hz: removes any DC the saturation adds without touching the sub-bass."""
    y = zeros(len(x))
    px = py = 0.0
    for i, v in enumerate(x):
        py = v - px + r * py
        px = v
        y[i] = py
    return y


def finish(x, fade=True):
    """DC-block, fade in/out over 5 ms, peak-normalise to -1 dBFS."""
    x = dc_block(x)
    if fade:
        f = ms(FADE)
        for i in range(min(f, len(x))):
            k = i / f
            x[i] *= k
            x[len(x) - 1 - i] *= k
    return scaled(x, PEAK)


# ---------------------------------------------------------------- melee
def swing():
    """0.35 s whoosh. Band-passed noise whose centre sweeps up and back down (a Doppler-like pass), a breathy
    low layer and a thin high layer, all under one swell-and-fall envelope."""
    n = ms(0.35)
    r = random.Random(1101)
    sh = [math.sin(math.pi * (i / n) ** 0.75) ** 1.6 for i in range(n)]
    a = noise_band(r, n, "bp", lambda i: 380 + 2400 * math.sin(math.pi * (i / n) ** 0.85), 1.4)
    b = noise_band(r, n, "lp", lambda i: 500 + 900 * sh[i], 0.7)
    c = noise_band(r, n, "hp", 4500, 0.7)
    x = [(a[i] + 0.45 * b[i] + 0.12 * c[i]) * sh[i] for i in range(n)]
    return finish(x)


def impact_bat():
    """0.45 s. Wet crunch of the bat landing (a low thump, a mid slap and a burst of bone/flesh grains, a few wet
    crackles) with the nail tink ringing out a beat behind it."""
    n = ms(0.45)
    r = random.Random(1201)
    x = zeros(n)
    add(x, mul(sweep_sine(n, 150, 55, 0.03, 0.3), env(n, 0.001, 0.08)), 0, 0.95)
    add(x, mul(noise_band(r, n, "bp", 900, 0.9), env(n, 0.001, 0.05)), 0, 0.7)
    crunch_grains(x, r, 10, 0.004, 0.14, 350, 2200, 0.012, 0.04, 0.55)
    add(x, mul(crackle(r, n, 220, 1800), env(n, 0.001, 0.09)), 0.01, 0.35)
    add(x, mul(metal(n, [2380, 3720, 5410, 7100], [0.09, 0.07, 0.05, 0.035], [1.0, 0.6, 0.4, 0.2]),
               env(n, 0.0004, 1.0)), 0.018, 0.3)
    return finish(sat(x, 1.6))


def impact_stab():
    """0.22 s. Short wet stab: a low-pass noise squelch whose cutoff drops fast, a skin-tick on top, a small thump
    and three tiny bubbles for the wet."""
    n = ms(0.22)
    r = random.Random(1301)
    x = zeros(n)
    add(x, mul(noise_band(r, n, "lp", decay_f(500, 3200, 0.04), 1.2), env(n, 0.002, 0.05)), 0, 0.9)
    add(x, mul(noise_band(r, n, "hp", 3000), env(n, 0.0005, 0.006)), 0, 0.5)
    add(x, mul(sweep_sine(n, 180, 90, 0.02), env(n, 0.001, 0.04)), 0, 0.6)
    for t in (0.03, 0.065, 0.115):
        add(x, bubble(r, 500 + 400 * r.random(), 0.02 + 0.015 * r.random()), t, 0.25)
    return finish(sat(x, 1.3))


def impact_spike():
    """0.6 s. Hammer on iron: a hard click, a body thump and the anvil's inharmonic partials ringing 0.1-0.35 s,
    followed by the dull crunch of the spike going in."""
    n = ms(0.6)
    r = random.Random(1401)
    x = zeros(n)
    add(x, mul(noise_band(r, n, "hp", 2000), env(n, 0.0003, 0.004)), 0, 0.7)
    add(x, mul(sweep_sine(n, 120, 70, 0.04, 0.2), env(n, 0.001, 0.09)), 0, 0.9)
    add(x, mul(metal(n, [520, 1180, 1960, 2870, 4100], [0.28, 0.2, 0.15, 0.1, 0.07], [1.0, 0.7, 0.5, 0.35, 0.2]),
               env(n, 0.0004, 1.0)), 0, 0.45)
    crunch_grains(x, r, 12, 0.03, 0.16, 250, 1800, 0.015, 0.05, 0.5, q=2.0)
    add(x, mul(noise_band(r, n, "lp", 700, 0.8), env(n, 0.004, 0.07)), 0.03, 0.5)
    return finish(sat(x, 1.8))


def firepunch():
    """0.7 s. Gas ignition: a sub whomp, a low-passed fwump whose cutoff blooms then closes, a fluttering mid roar
    that swells in behind it, hot crackle and a short contact thud."""
    n = ms(0.7)
    r = random.Random(1501)
    x = zeros(n)
    add(x, mul(sweep_sine(n, 110, 40, 0.05), env(n, 0.004, 0.18)), 0, 1.0)
    add(x, mul(noise_band(r, n, "lp", lambda i: 300 + 1700 * min(1.0, (i / SR) / 0.12) * math.exp(1 - (i / SR) / 0.12), 0.8),
               env(n, 0.015, 0.22)), 0, 1.0)
    flutter = scaled(biquad(noise(r, n), "lp", 30, 0.7))
    mod = [max(0.0, 0.7 + 0.6 * v) for v in flutter]
    roar = [a + 0.5 * b for a, b in zip(noise_band(r, n, "bp", 700, 0.6), noise_band(r, n, "hp", 2500, 0.7))]
    add(x, mul(mul(roar, mod), env(n, 0.06, 0.25)), 0.02, 0.8)
    add(x, mul(crackle(r, n, 90, 2500), env(n, 0.002, 0.3)), 0.05, 0.5)
    add(x, mul(noise_band(r, n, "lp", 400), env(n, 0.001, 0.04)), 0, 0.8)
    return finish(sat(x, 2.0))


def launch():
    """0.5 s. Deep launch thump: a pitch-dropping sub, a low noise body, a click, and a short exhaust whoosh that
    tails off behind it."""
    n = ms(0.5)
    r = random.Random(1601)
    x = zeros(n)
    add(x, mul(sweep_sine(n, 95, 32, 0.09, 0.15), env(n, 0.003, 0.12)), 0, 1.0)
    add(x, mul(noise_band(r, n, "lp", 250, 0.8), env(n, 0.002, 0.06)), 0, 0.7)
    add(x, mul(noise_band(r, n, "lp", 2500), env(n, 0.0003, 0.003)), 0, 0.4)
    add(x, mul(noise_band(r, n, "bp", decay_f(350, 1400, 0.12), 0.8), env(n, 0.02, 0.1)), 0.01, 0.45)
    return finish(sat(x, 1.8))


# ---------------------------------------------------------------- explosions
def boom(seed, dur, f0, f1, pitch_tau, sub_tau, body_hz, body_tau, rumble_tau, debris_n, debris_T, crack, drive,
         taps=()):
    """Shared explosion recipe: pitch-dropping sub, a noise body whose low-pass closes as it dies, a bright crack at
    the front, a low rumble, and a debris tail of band-passed grains thinning out exponentially. Optional reflections."""
    n = ms(dur)
    r = random.Random(seed)
    x = zeros(n)
    add(x, mul(sweep_sine(n, f0, f1, pitch_tau, 0.2), env(n, 0.004, sub_tau)), 0, 1.0)
    add(x, mul(noise_band(r, n, "lp", decay_f(120, body_hz, 0.10), 0.9), env(n, 0.002, body_tau)), 0, 0.85)
    add(x, mul(noise_band(r, n, "hp", 1500), env(n, 0.0005, 0.02)), 0, crack)
    add(x, mul(noise_band(r, n, "lp", 90, 0.8), env(n, 0.03, rumble_tau)), 0, 0.5)
    for _ in range(debris_n):
        t = 0.08 + r.expovariate(1.0 / debris_T)
        if t > dur - 0.05:
            continue
        d = 0.006 + 0.03 * r.random()
        m = ms(d)
        f = 300 * (3500 / 300) ** r.random()
        g = mul(noise_band(r, m, "bp", f, 3.0), env(m, 0.0007, d / 3.0))
        add(x, g, t, 0.55 * math.exp(-t / (debris_T * 2.0)) * (0.4 + 0.6 * r.random()))
    x = echoes(x, taps) if taps else x
    return finish(sat(x, drive))


def boom_small():
    return boom(2101, 0.8, 110, 40, 0.05, 0.16, 3000, 0.09, 0.15, 70, 0.20, 0.35, 1.8)


def boom_med():
    return boom(2201, 1.4, 85, 32, 0.07, 0.26, 3200, 0.14, 0.28, 130, 0.35, 0.40, 2.0,
                taps=[(0.11, 0.18, 1500)])


def boom_large():
    return boom(2301, 2.2, 70, 26, 0.09, 0.40, 3400, 0.20, 0.45, 210, 0.55, 0.45, 2.2,
                taps=[(0.14, 0.22, 1400), (0.31, 0.12, 900)])


def crucible():
    """2.8 s. The big one: a hard crack, two stacked subs (the second dropping to 16 Hz), a long dark body, a slow
    rumble, rolling reflections, a wide debris tail, and molten bubbling and sizzle that linger after the blast."""
    dur = 2.8
    n = ms(dur)
    r = random.Random(2401)
    x = zeros(n)
    add(x, mul(sweep_sine(n, 75, 20, 0.11, 0.2), env(n, 0.005, 0.55)), 0, 1.0)
    add(x, mul(sweep_sine(n, 48, 16, 0.18), env(n, 0.012, 0.75)), 0.02, 0.8)
    add(x, mul(noise_band(r, n, "lp", decay_f(100, 3600, 0.14), 0.9), env(n, 0.002, 0.30)), 0, 0.9)
    add(x, mul(noise_band(r, n, "hp", 1200), env(n, 0.0005, 0.035)), 0, 0.55)
    add(x, mul(noise_band(r, n, "lp", 80, 0.8), env(n, 0.04, 0.7)), 0, 0.55)
    for _ in range(300):
        t = 0.08 + r.expovariate(1.0 / 0.75)
        if t > dur - 0.1:
            continue
        d = 0.008 + 0.05 * r.random()
        m = ms(d)
        f = 200 * (3000 / 200) ** r.random()
        g = mul(noise_band(r, m, "bp", f, 3.0), env(m, 0.0007, d / 3.0))
        add(x, g, t, 0.55 * math.exp(-t / 1.5) * (0.4 + 0.6 * r.random()))
    x = echoes(x, [(0.16, 0.22, 1500), (0.37, 0.14, 1000), (0.61, 0.08, 700)])
    # molten tail: low glops and a faint sizzle
    t = 0.5
    while t < 2.6:
        add(x, bubble(r, 110 + 400 * r.random(), 0.03 + 0.05 * r.random()), t, 0.3 * math.exp(-(t - 0.5) / 1.1))
        t += r.expovariate(14.0)
    add(x, mul(noise_band(r, n, "hp", 4500), env(n, 0.3, 0.8)), 0, 0.07)
    return finish(sat(x, 2.2))


# ---------------------------------------------------------------- acid
def acid_burst():
    """1.2 s. Glass flask: a bright crack, a dense cloud of tiny high glass tinks (thick at first, thinning by 0.4 s),
    then the acid splash (a wet band-passed whoosh), rising bubbles and a sizzle that fades out."""
    n = ms(1.2)
    r = random.Random(3101)
    x = zeros(n)
    add(x, mul(noise_band(r, n, "hp", 3000), env(n, 0.0004, 0.012)), 0, 0.8)
    for _ in range(130):
        t = r.random() ** 2.2 * 0.5
        f = 2500 * (9000 / 2500) ** r.random()
        d = 0.02 + 0.10 * r.random()
        m = ms(d * 3)
        g = metal(m, [f, f * 1.51], [d, d * 0.6], [1.0, 0.4])
        add(x, g, t, 0.16 * (0.3 + 0.7 * r.random()))
    add(x, mul(noise_band(r, n, "bp", decay_f(900, 2200, 0.15), 0.9), env(n, 0.01, 0.16)), 0.02, 0.7)
    add(x, mul(noise_band(r, n, "lp", 300, 0.8), env(n, 0.003, 0.05)), 0, 0.45)
    t = 0.1
    while t < 1.1:
        add(x, bubble(r, 300 * (1500 / 300) ** r.random(), 0.012 + 0.03 * r.random()), t,
            0.45 * math.exp(-(t - 0.1) / 0.55) * (0.4 + 0.6 * r.random()))
        t += r.expovariate(55.0 * math.exp(-t / 0.7) + 6.0)
    add(x, mul(noise_band(r, n, "hp", 5000), env(n, 0.05, 0.4)), 0.08, 0.12)
    return finish(sat(x, 1.3))


def acid_hiss():
    """2.0 s loop. Hiss (high-passed noise, slowly modulated) over a faint mid layer, with granular bubbling:
    random rising blips at ~28/s plus a few low glops. It is stationary by design, and the 0.25 s of extra tail
    generated past the loop end is crossfaded (equal power) into the head, so end -> start is continuous."""
    loop = ms(2.0)
    xf = ms(0.25)
    n = loop + xf
    r = random.Random(3201)
    slow = scaled(biquad(noise(r, n), "lp", 6, 0.7))
    mod = [0.65 + 0.35 * v for v in slow]
    hiss = [a + 0.6 * b for a, b in zip(noise_band(r, n, "hp", 3500, 0.7), noise_band(r, n, "bp", 6000, 0.7))]
    mid = noise_band(r, n, "bp", 1800, 0.8)
    x = [(hiss[i] * 0.55 + mid[i] * 0.18) * mod[i] for i in range(n)]
    t = r.expovariate(28.0)
    while t < n / SR:
        add(x, bubble(r, 250 * (1400 / 250) ** r.random(), 0.012 + 0.028 * r.random()), t, 0.15 + 0.45 * r.random())
        t += r.expovariate(28.0)
    t = r.expovariate(3.0)
    while t < n / SR:
        add(x, bubble(r, 120 + 180 * r.random(), 0.05 + 0.04 * r.random()), t, 0.3 + 0.2 * r.random())
        t += r.expovariate(3.0)
    x = dc_block(x)
    out = x[:loop]
    for i in range(xf):
        th = 0.5 * math.pi * i / xf
        out[i] = x[i] * math.sin(th) + x[loop + i] * math.cos(th)   # i=0 is x[loop], the natural successor of x[loop-1]
    return scaled(out, PEAK)


# ---------------------------------------------------------------- output
SOUNDS = [
    ("kj_swing", swing),
    ("kj_impact_bat", impact_bat),
    ("kj_impact_stab", impact_stab),
    ("kj_impact_spike", impact_spike),
    ("kj_firepunch", firepunch),
    ("kj_launch", launch),
    ("kj_boom_small", boom_small),
    ("kj_boom_med", boom_med),
    ("kj_boom_large", boom_large),
    ("kj_crucible", crucible),
    ("kj_acid_burst", acid_burst),
    ("kj_acid_hiss", acid_hiss),
]


def wav_bytes(x):
    pcm = struct.pack("<%dh" % len(x), *[max(-32768, min(32767, int(round(v * 32767)))) for v in x])
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm)
    return buf.getvalue()


def render_all():
    out = {}
    for name, fn in SOUNDS:
        data = wav_bytes(fn())
        if len(data) >= MAX_BYTES:
            raise SystemExit("%s.wav is %d bytes, over the %d byte limit" % (name, len(data), MAX_BYTES))
        out[name + ".wav"] = data
    return out


def main():
    check = "--check" in sys.argv[1:]
    files = render_all()
    bad = 0
    total = 0
    for fname, data in files.items():
        total += len(data)
        path = OUT / fname
        if check:
            if not path.exists():
                print("MISSING", fname)
                bad += 1
            elif path.read_bytes() != data:
                print("DIFFERS", fname)
                bad += 1
            else:
                print("ok     %s (%d bytes)" % (fname, len(data)))
        else:
            OUT.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            print("%s %d bytes, %.2f s" % (fname, len(data), (len(data) - 44) / 2 / SR))
    print("total %d bytes" % total)
    if check and bad:
        print("%d file(s) out of date; run make_sounds.py" % bad)
        sys.exit(1)


if __name__ == "__main__":
    main()
