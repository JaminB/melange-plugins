#!/usr/bin/env python3
"""Generate Sandtide's sound effects into mod/sounds/.

Sixteen-bit PCM WAVs at 44.1 kHz, each under 2 MiB (Melange's wum.audio limit), every one synthesised here from
scratch: noise shaped by envelopes and time-varying biquad filters, pitch-dropping sines for the low thumps, decaying
inharmonic partials for glass and brass, thousands of short band-passed noise grains for sand, naive saws through
sweeping low-passes for the drone, tanh saturation to glue layers. Nothing comes from the game or any other recording.
All randomness comes from seeded random.Random instances, so the output is deterministic; --check regenerates
everything in memory and compares it byte-for-byte with the files on disk. One-shots are DC-blocked, faded over 5 ms at
both ends and peak-normalised to -1 dBFS. Loops (names ending in _loop) are generated past their end and the tail is
crossfaded (equal power) into the head, so the loop point is seamless; they are normalised but not faded.
Stdlib only. The approach and the small DSP helpers follow plugins/kindjal/tools/make_sounds.py.

    python make_sounds.py          write the files
    python make_sounds.py --check  verify the files on disk (exit 1 on any difference)

See tools/README-art.md for what each sound is for.
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
FADE = 0.005
MAX_BYTES = 2 * 1024 * 1024     # wum.audio.load refuses anything larger
TWO_PI = 2 * math.pi


# ---------------------------------------------------------------- helpers
def ms(t):
    return int(round(t * SR))


def zeros(n):
    return [0.0] * n


def noise(rng, n):
    return [rng.random() * 2.0 - 1.0 for _ in range(n)]


def mul(a, b):
    return [p * q for p, q in zip(a, b)]


def scaled(x, peak=1.0):
    m = max(abs(v) for v in x) or 1.0
    return [v * peak / m for v in x]


def add(dst, src, off=0.0, gain=1.0):
    o = ms(off)
    n = min(len(src), len(dst) - o)
    for i in range(max(n, 0)):
        dst[o + i] += src[i] * gain


def sat(x, drive):
    k = math.tanh(drive)
    return [math.tanh(drive * v) / k for v in x]


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


def shape(n, points):
    """Piecewise-linear envelope through (time_s, value) points (smoothstepped between them)."""
    out = zeros(n)
    pts = sorted(points)
    j = 0
    for i in range(n):
        t = i / SR
        while j < len(pts) - 2 and t > pts[j + 1][0]:
            j += 1
        (t0, v0), (t1, v1) = pts[j], pts[j + 1]
        u = min(max((t - t0) / max(t1 - t0, 1e-9), 0.0), 1.0)
        u = u * u * (3 - 2 * u)
        out[i] = v0 + (v1 - v0) * u
    return out


def biquad(x, kind, f, q=0.707, step=8):
    """RBJ biquad ('lp', 'hp' or 'bp' with 0 dB peak); f is Hz or a function of the sample index."""
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
    return scaled(biquad(noise(rng, n), kind, f, q))


def slow_noise(rng, n, hz):
    """Smooth random control signal in about -1..1 (two low-pass passes of white noise)."""
    return scaled(biquad(biquad(noise(rng, n), "lp", hz, 0.7, 64), "lp", hz, 0.7, 64))


def sweep_sine(n, f0, f1, tau, tri=0.0):
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


def partials(n, freqs, decays, amps, phase_rng=None):
    """Decaying inharmonic partials (struck glass, brass)."""
    out = zeros(n)
    for f, d, a in zip(freqs, decays, amps):
        if f >= SR * 0.45:
            continue
        k = 1.0 / (d * SR)
        w = TWO_PI * f / SR
        ph = phase_rng.random() * TWO_PI if phase_rng else 0.0
        m = min(n, int(d * SR * 7))
        for i in range(m):
            out[i] += a * math.exp(-i * k) * math.sin(w * i + ph)
    return out


def grains(x, rng, count, start, span, flo, fhi, dmin, dmax, gain, q=2.5, bias=1.0, density=None):
    """Scatter short band-passed noise grains over [start, start+span]. bias > 1 front-loads them; `density(t)`, a
    function of 0..1, thins them where it is low (by rejection)."""
    placed = 0
    tries = 0
    while placed < count and tries < count * 20:
        tries += 1
        u = rng.random() ** bias
        if density is not None and rng.random() > density(u):
            continue
        placed += 1
        t = start + span * u
        f = flo * (fhi / flo) ** rng.random()
        d = dmin + (dmax - dmin) * rng.random()
        m = ms(d)
        g = noise_band(rng, m, "bp", f, q)
        e = env(m, 0.0006, d / 3.0)
        add(x, mul(g, e), t, gain * (0.35 + 0.65 * rng.random()))


def crackle(rng, n, rate, f, q=1.5):
    p = rate / SR
    imp = [(rng.random() * 2.0 - 1.0) if rng.random() < p else 0.0 for _ in range(n)]
    return scaled(biquad(imp, "bp", f, q))


def saw(n, freq, drift=None):
    """Naive sawtooth (the low-pass after it hides the aliasing at these low pitches)."""
    ph = 0.0
    out = []
    for i in range(n):
        f = freq * (drift[i] if drift else 1.0)
        ph = (ph + f / SR) % 1.0
        out.append(2.0 * ph - 1.0)
    return out


def echoes(x, taps):
    out = list(x)
    for d, g, lp in taps:
        add(out, biquad(x, "lp", lp, 0.6), d, g)
    return out


def dc_block(x, r=0.99886):
    y = zeros(len(x))
    px = py = 0.0
    for i, v in enumerate(x):
        py = v - px + r * py
        px = v
        y[i] = py
    return y


def finish(x, fade=True):
    x = dc_block(x)
    if fade:
        f = ms(FADE)
        for i in range(min(f, len(x))):
            k = i / f
            x[i] *= k
            x[len(x) - 1 - i] *= k
    return scaled(x, PEAK)


def loop_close(x, loop, xf):
    """x has loop + xf samples: crossfade the extra tail into the head so x[loop-1] -> x[0] is continuous."""
    x = dc_block(x)
    out = x[:loop]
    for i in range(xf):
        th = 0.5 * math.pi * i / xf
        out[i] = x[i] * math.sin(th) + x[loop + i] * math.cos(th)
    return out


def stereo_finish(l, r):
    m = max(max(abs(v) for v in l), max(abs(v) for v in r)) or 1.0
    return [v * PEAK / m for v in l], [v * PEAK / m for v in r]


# ---------------------------------------------------------------- the sounds
def wind_loop():
    """8.0 s stereo loop: desert wind. Pinkish noise through a band-pass that breathes with slow gusts, a thin
    whistle that wanders in pitch, a high sand hiss riding the gusts and sparse grains of sand ticking past. The two
    channels share the gusts (the right a little later) but not the noise, so it is wide without phasing."""
    loop, xf = ms(8.0), ms(1.0)
    n = loop + xf
    rg = random.Random(5001)
    gust = slow_noise(rg, n, 0.35)
    chans = []
    for ch, seed, lag in ((0, 5011, 0), (1, 5021, ms(0.35))):
        r = random.Random(seed)
        g = [0.55 + 0.45 * gust[max(i - lag, 0)] for i in range(n)]
        body = biquad(noise(r, n), "bp", lambda i: 380 + 900 * g[i] ** 2, 0.6)
        low = biquad(noise(r, n), "lp", 220, 0.7)
        hiss = biquad(noise(r, n), "hp", lambda i: 3600 + 1800 * g[i], 0.7)
        wob = slow_noise(r, n, 0.25)
        whistle = biquad(noise(r, n), "bp", lambda i: 760 + 260 * wob[i] + 220 * g[i], 14.0)
        ticks = crackle(r, n, 45, 5200, 2.0)
        x = zeros(n)
        body, low, hiss, whistle = scaled(body), scaled(low), scaled(hiss), scaled(whistle)
        for i in range(n):
            gi = g[i]
            x[i] = (body[i] * (0.30 + 0.70 * gi) * 0.85 + low[i] * 0.30 + hiss[i] * gi * gi * 0.22
                    + whistle[i] * max(gi - 0.45, 0) * 0.55 + ticks[i] * gi * 0.10)
        chans.append(loop_close(x, loop, xf))
    return stereo_finish(*chans)


def rumble():
    """4.5 s. The earth answering the curse: a sub at 40 Hz sagging to 31 that trembles irregularly, a low-passed
    roar that swells in over half a second, slow crumbling grains in the low mids and a soft tail."""
    n = ms(4.5)
    r = random.Random(5101)
    x = zeros(n)
    trem = slow_noise(r, n, 9.0)
    sub = sweep_sine(n, 40, 31, 1.6, 0.15)
    e = shape(n, [(0, 0), (0.55, 1.0), (2.2, 0.85), (4.5, 0.0)])
    for i in range(n):
        x[i] += sub[i] * e[i] * (0.75 + 0.25 * trem[i]) * 0.9
    roar = noise_band(r, n, "lp", lambda i: 120 + 260 * e[i], 0.9)
    for i in range(n):
        x[i] += roar[i] * e[i] * (0.7 + 0.3 * trem[i]) * 0.75
    mid = noise_band(r, n, "bp", 260, 0.8)
    add(x, mul(mid, shape(n, [(0, 0), (0.7, 0.35), (2.5, 0.25), (4.5, 0)])), 0, 0.8)
    grains(x, r, 160, 0.15, 3.6, 140, 1400, 0.02, 0.09, 0.35, q=2.0, bias=1.3)
    return finish(sat(x, 1.3))


def sand_grind():
    """3.6 s. The petrify creeping up a worm: a hiss of thousands of sand grains that thickens over two and a half
    seconds, a stone-on-stone grind underneath that stutters, a resonance rising in pitch for the tension, and dry
    ticks of the crust setting. Ends on a settle."""
    n = ms(3.6)
    r = random.Random(5201)
    x = zeros(n)
    dens = shape(n, [(0, 0.05), (0.4, 0.35), (2.6, 1.0), (3.1, 0.5), (3.6, 0.0)])
    grains(x, r, 2600, 0.0, 3.5, 1400, 7500, 0.002, 0.006, 0.30, q=1.6,
           density=lambda u: 0.05 + 0.95 * dens[min(int(u * 3.5 * SR), n - 1)])
    stutter = slow_noise(r, n, 32.0)
    grind = noise_band(r, n, "lp", 340, 1.2)
    for i in range(n):
        x[i] += grind[i] * dens[i] * (0.55 + 0.45 * max(stutter[i], -0.4)) * 0.55
    rise = noise_band(r, n, "bp", lambda i: 380 * (2.8 ** min(i / (2.8 * SR), 1.0)), 5.0)
    add(x, mul(rise, dens), 0, 0.22)
    tick = crackle(r, n, 18, 2600, 3.0)
    add(x, mul(tick, dens), 0, 0.25)
    # the settle: a soft low thud as the crust locks
    add(x, mul(sweep_sine(ms(0.6), 90, 45, 0.08), env(ms(0.6), 0.003, 0.12)), 3.0, 0.5)
    return finish(sat(x, 1.2))


def sand_pour_loop():
    """4.0 s loop: the hourglass running. A steady pour of fine grains (about 1100 a second, 2 to 9 kHz) over a soft
    low hush."""
    loop, xf = ms(4.0), ms(0.5)
    n = loop + xf
    r = random.Random(5301)
    x = zeros(n)
    grains(x, r, int(1100 * n / SR), 0.0, n / SR, 2000, 9000, 0.0015, 0.004, 0.25, q=1.4)
    hush = noise_band(r, n, "bp", 900, 0.5)
    wob = slow_noise(r, n, 1.5)
    for i in range(n):
        x[i] += hush[i] * (0.16 + 0.04 * wob[i])
    return scaled(loop_close(x, loop, xf), PEAK)


def crunch():
    """2.8 s sting. The worm's tail locks into stone: a hard crack, a thump falling to 38 Hz, a dense crunch of
    rock grains and a second smaller one a beat behind, then a low dissonant chord (A, B flat and E flat, a tritone
    cluster) that blooms through a closing low-pass with a dark gong under it, and debris trickling down in a large
    space."""
    n = ms(2.8)
    r = random.Random(5401)
    x = zeros(n)
    add(x, mul(noise_band(r, ms(0.02), "hp", 2500), env(ms(0.02), 0.0003, 0.003)), 0, 0.9)
    add(x, mul(sweep_sine(n, 120, 38, 0.06, 0.3), env(n, 0.002, 0.28)), 0, 1.0)
    add(x, mul(noise_band(r, n, "lp", lambda i: 300 + 2600 * math.exp(-i / (0.05 * SR)), 1.0), env(n, 0.001, 0.12)),
        0, 0.6)
    grains(x, r, 130, 0.0, 0.30, 250, 3800, 0.008, 0.045, 0.85, q=2.2, bias=2.0)
    grains(x, r, 55, 0.16, 0.20, 300, 3000, 0.008, 0.035, 0.7, q=2.2, bias=1.6)
    grains(x, r, 70, 0.4, 1.9, 600, 5000, 0.004, 0.02, 0.18, q=2.5, bias=1.8)
    # the sting chord
    chord = zeros(n)
    for f, a in ((55.0, 1.0), (58.27, 0.7), (77.78, 0.6), (110.0, 0.35), (155.56, 0.25)):
        drift = [1.0 + 0.002 * math.sin(TWO_PI * 0.7 * i / SR + f) for i in range(n)]
        add(chord, saw(n, f, drift), 0, a)
    chord = biquad(chord, "lp", lambda i: 260 + 2200 * math.exp(-i / (0.35 * SR)), 1.1)
    add(x, mul(scaled(chord), env(n, 0.012, 0.9)), 0.02, 0.55)
    gong = partials(n, [61.0, 97.6, 133.1, 171.3, 218.0, 289.0], [1.6, 1.2, 0.9, 0.7, 0.5, 0.35],
                    [1.0, 0.6, 0.5, 0.35, 0.25, 0.15])
    add(x, scaled(gong), 0.0, 0.35)
    x = echoes(x, [(0.11, 0.30, 2600), (0.23, 0.22, 1800), (0.41, 0.15, 1200), (0.67, 0.10, 800)])
    return finish(sat(x, 1.5))


def dust_burst():
    """1.6 s. The sand mound bursting up: a low puff, a whoosh whose band falls from 3 kHz to 400 Hz, and gravel
    raining back down."""
    n = ms(1.6)
    r = random.Random(5501)
    x = zeros(n)
    add(x, mul(noise_band(r, n, "lp", 180, 0.9), env(n, 0.004, 0.10)), 0, 0.9)
    add(x, mul(sweep_sine(n, 95, 50, 0.05), env(n, 0.002, 0.09)), 0, 0.6)
    whoosh = noise_band(r, n, "bp", lambda i: 400 + 2600 * math.exp(-i / (0.22 * SR)), 1.0)
    add(x, mul(whoosh, env(n, 0.012, 0.32)), 0, 0.8)
    grains(x, r, 160, 0.12, 1.3, 800, 6000, 0.003, 0.012, 0.25, q=2.0, bias=1.7)
    return finish(sat(x, 1.25))


def glass_crack():
    """0.9 s. A crack running through the hourglass: a tick, three quick splitting crackles, the glass ringing
    briefly at its own pitches and a low creak of stress under it."""
    n = ms(0.9)
    r = random.Random(5601)
    x = zeros(n)
    add(x, mul(noise_band(r, ms(0.01), "hp", 4000), env(ms(0.01), 0.0002, 0.0015)), 0, 1.0)
    for t in (0.004, 0.021, 0.047):
        m = ms(0.03)
        add(x, mul(crackle(r, m, 2500, 3200, 2.5), env(m, 0.0004, 0.006)), t, 0.7)
    ring = partials(n, [2140, 3480, 5120, 6890, 8810], [0.30, 0.22, 0.15, 0.10, 0.07], [0.6, 0.5, 0.4, 0.3, 0.2], r)
    add(x, scaled(ring), 0.002, 0.30)
    creak = noise_band(r, ms(0.25), "bp", lambda i: 950 - 350 * i / ms(0.25), 9.0)
    add(x, mul(creak, env(ms(0.25), 0.01, 0.06)), 0.01, 0.25)
    x = echoes(x, [(0.06, 0.18, 6000), (0.13, 0.10, 4000)])
    return finish(x)


def glass_shatter():
    """2.6 s. The hourglass bursting: a sharp impact over a low thump, then about two hundred tinkles of glass
    (each two or three high partials ringing for tens of milliseconds) thinning out as they land, with a crunch of
    fragments and sand under them."""
    n = ms(2.6)
    r = random.Random(5701)
    x = zeros(n)
    add(x, mul(noise_band(r, n, "hp", 1500), env(n, 0.0005, 0.05)), 0, 1.0)
    add(x, mul(sweep_sine(n, 95, 45, 0.04), env(n, 0.002, 0.10)), 0, 0.7)
    ring = partials(n, [1830, 2970, 4410, 6020, 7750], [0.5, 0.4, 0.3, 0.2, 0.15], [0.7, 0.6, 0.5, 0.3, 0.2], r)
    add(x, scaled(ring), 0.0, 0.25)
    for _ in range(210):
        t = 1.9 * r.random() ** 2.0
        d = r.uniform(0.02, 0.12)
        m = ms(d * 6)
        k = r.choice((2, 3))
        fs = [r.uniform(2500, 11000) for _ in range(k)]
        tink = partials(m, fs, [d * r.uniform(0.6, 1.0) for _ in fs], [r.uniform(0.4, 1.0) for _ in fs], r)
        add(x, scaled(tink), 0.01 + t, 0.30 * (1.0 - 0.5 * t / 1.9) * r.uniform(0.4, 1.0))
    grains(x, r, 120, 0.0, 1.2, 900, 6000, 0.003, 0.015, 0.25, q=2.0, bias=1.8)
    x = echoes(x, [(0.07, 0.22, 7000), (0.16, 0.14, 5000), (0.29, 0.08, 3500)])
    return finish(sat(x, 1.15))


def tick(pitch=1.0, seed=5801):
    """0.25 s. The hourglass's brass tick: a click into a short resonant knock and two ringing partials."""
    n = ms(0.25)
    r = random.Random(seed)
    x = zeros(n)
    add(x, mul(noise_band(r, ms(0.004), "hp", 3000), env(ms(0.004), 0.0001, 0.0008)), 0, 0.8)
    add(x, mul(noise_band(r, n, "bp", 900 * pitch, 7.0), env(n, 0.0005, 0.012)), 0, 0.7)
    add(x, scaled(partials(n, [1760 * pitch, 2930 * pitch, 4370 * pitch], [0.05, 0.035, 0.02], [1.0, 0.6, 0.35])),
        0, 0.45)
    add(x, mul(sweep_sine(n, 260 * pitch, 180 * pitch, 0.01), env(n, 0.0005, 0.01)), 0, 0.35)
    return finish(x)


def tock():
    """0.25 s. The tick's lower partner, for alternating tick-tock in the last 15 seconds."""
    return tick(0.78, 5811)


def drone_loop():
    """10.0 s stereo loop: the ominous bed under the camera tour. A detuned saw cluster on A1 with a B flat and a
    flat fifth rubbing against it, through low-passes that open and close slowly; a hollow 'oo' choir on A2 through
    formant band-passes; a heartbeat sub at 36 Hz that thuds four times per loop; and a dry wind above it. Every
    periodic part has a whole number of cycles in the loop, and the noisy parts are crossfaded."""
    loop, xf = ms(10.0), ms(1.0)
    n = loop + xf
    out = []
    for ch, seed, det in ((0, 5901, 1.0), (1, 5911, 1.0035)):
        r = random.Random(seed)
        x = zeros(n)
        cluster = zeros(n)
        for f, a in ((55.0, 1.0), (55.3 * det, 0.8), (58.3, 0.30), (77.8, 0.40), (110.6 / det, 0.25)):
            add(cluster, saw(n, f), 0, a)
        lfo = [0.5 + 0.5 * math.sin(TWO_PI * 0.1 * i / SR + ch * 1.3) for i in range(n)]
        lfo2 = [0.5 + 0.5 * math.sin(TWO_PI * 0.3 * i / SR + ch * 0.7) for i in range(n)]
        cl = biquad(cluster, "lp", lambda i: 160 + 520 * lfo[i] ** 1.5 + 80 * lfo2[i], 1.4)
        add(x, scaled(cl), 0, 0.75)
        vib = [1.0 + 0.004 * math.sin(TWO_PI * 5.0 * i / SR) for i in range(n)]
        buzz = saw(n, 110.0, vib)
        choir = zeros(n)
        for fc, q, g in ((310, 6.0, 1.0), (870, 8.0, 0.35), (2250, 10.0, 0.12)):
            add(choir, biquad(buzz, "bp", fc, q), 0, g)
        swell = [0.35 + 0.65 * (0.5 - 0.5 * math.cos(TWO_PI * 0.2 * i / SR)) for i in range(n)]
        add(x, mul(scaled(choir), swell), 0, 0.30)
        beat = zeros(n)
        for k in range(5):
            t0 = k * 2.5 + 0.05
            m = ms(0.9)
            thump = mul(sweep_sine(m, 52, 34, 0.08), env(m, 0.006, 0.18))
            add(beat, thump, t0, 1.0)
            add(beat, mul(sweep_sine(m, 48, 33, 0.08), env(m, 0.006, 0.14)), t0 + 0.32, 0.6)
        add(x, beat, 0, 0.55)
        air = noise_band(r, n, "bp", lambda i: 500 + 400 * lfo2[i], 0.7)
        add(x, air, 0, 0.06)
        out.append(loop_close(x, loop, xf))
    return stereo_finish(*out)


SOUNDS = [
    ("sdt_wind_loop", wind_loop),
    ("sdt_rumble", rumble),
    ("sdt_sand_grind", sand_grind),
    ("sdt_sand_pour_loop", sand_pour_loop),
    ("sdt_crunch", crunch),
    ("sdt_dust_burst", dust_burst),
    ("sdt_glass_crack", glass_crack),
    ("sdt_glass_shatter", glass_shatter),
    ("sdt_tick", tick),
    ("sdt_tock", tock),
    ("sdt_drone_loop", drone_loop),
]


def wav_bytes(x):
    if isinstance(x, tuple):
        l, r = x
        inter = [v for pair in zip(l, r) for v in pair]
        ch = 2
    else:
        inter = x
        ch = 1
    pcm = struct.pack("<%dh" % len(inter), *[max(-32768, min(32767, int(round(v * 32767)))) for v in inter])
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(ch)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm)
    return buf.getvalue(), ch


def render_all(only=None):
    out = {}
    for name, fn in SOUNDS:
        if only and name not in only:
            continue
        data, ch = wav_bytes(fn())
        if len(data) > MAX_BYTES:
            raise SystemExit("%s.wav is %d bytes, over the %d byte limit" % (name, len(data), MAX_BYTES))
        out[name + ".wav"] = (data, ch)
    return out


def main():
    args = sys.argv[1:]
    check = "--check" in args
    only = [a for a in args if not a.startswith("--")]
    files = render_all(only)
    bad = total = 0
    for fname, (data, ch) in files.items():
        total += len(data)
        path = OUT / fname
        secs = (len(data) - 44) / 2 / ch / SR
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
            print("%s %d bytes, %.2f s, %d ch" % (fname, len(data), secs, ch))
    print("total %d bytes" % total)
    if check and bad:
        print("%d file(s) out of date; run make_sounds.py" % bad)
        sys.exit(1)


if __name__ == "__main__":
    main()
