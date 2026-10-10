# Kindjal sounds

`make_sounds.py` synthesises every sound effect into `../mod/sounds/` (12 WAVs, PCM16 mono 44.1 kHz, about 1.1 MB in
total, each under 300 KB). It is stdlib-only Python 3 (the `wave` module, no numpy) and deterministic: every random
source is a seeded `random.Random`, so re-running gives identical bytes.

    python make_sounds.py          # write the files
    python make_sounds.py --check  # regenerate in memory, compare byte-for-byte with disk, exit 1 on any difference

Everything is original: no recordings and nothing from the game. Each file is peak-normalised to -1 dBFS with a 5 ms
fade in and out; `kj_acid_hiss` is a loop, so it has no fades (see below). The synthesis building blocks are the same
throughout:

- noise bursts shaped by an attack/decay envelope (quarter-sine attack, exponential decay)
- RBJ biquad low-pass / band-pass / high-pass, with the cutoff swept over time where the sound needs it
- pitch-dropping sine (optionally blended with a triangle for a harder edge) for sub-booms and thumps
- a few decaying inharmonic sine partials for struck metal
- short band-passed noise grains for crunch and debris, short rising-pitch sine blips for bubbles
- tanh soft clipping for grit, and a few low-passed delayed copies for room reflections on the big blasts

I could not listen while building these. The numbers below (durations, level shape) are verified; how they sound is for
the owner to audition. Every recipe has gain and tuning constants in one place, so adjusting is a one-line edit.

| File | Length | What it is and how it is made |
|---|---|---|
| `kj_swing.wav` | 0.35 s | Melee whoosh. Band-passed noise whose centre sweeps ~380 Hz up to ~2.8 kHz and back (a Doppler-like pass), plus a breathy low-pass layer and a thin high layer, under one swell-and-fall envelope. |
| `kj_impact_bat.wav` | 0.45 s | Wet crunch and nail tink. Pitch-dropping thump (150 to 55 Hz), a mid slap, ten band-passed bone/flesh grains, wet crackle, and four metallic partials (2.4 to 7.1 kHz) ringing in 18 ms behind the hit. Saturated. |
| `kj_impact_stab.wav` | 0.22 s | Short wet stab. Low-pass noise squelch with the cutoff falling 3.2 kHz to 0.5 kHz, a skin tick, a small thump and three tiny bubbles. |
| `kj_impact_spike.wav` | 0.6 s | Hammer on iron plus the spike going in. Hard click, body thump, five inharmonic anvil partials (520 Hz to 4.1 kHz, 0.07 to 0.28 s decays), then a dull crunch of grains and low noise. Saturated hard. |
| `kj_firepunch.wav` | 0.7 s | Ignition roar and thud. Sub whomp (110 to 40 Hz), a fwump whose low-pass cutoff blooms then closes, a fluttering mid and high roar that swells in, hot crackle, and a contact thud. |
| `kj_launch.wav` | 0.5 s | Deep launch thump. Sine 95 to 32 Hz with a triangle edge, low noise body, a click, and a short falling exhaust whoosh. |
| `kj_boom_small.wav` | 0.8 s | Sub-boom 110 to 40 Hz, noise body with a closing low-pass, bright crack, rumble, and 70 debris grains. |
| `kj_boom_med.wav` | 1.4 s | As small, lower (85 to 32 Hz), longer body, 130 debris grains and one reflection. |
| `kj_boom_large.wav` | 2.2 s | As above, lower again (70 to 26 Hz), 210 grains over a longer tail and two reflections. |
| `kj_crucible.wav` | 2.8 s | The detonation. Hard crack, two stacked subs (75 to 20 Hz and 48 to 16 Hz), a long dark body, slow rumble, three rolling reflections, 300 debris grains, then low molten glops and a faint sizzle lingering after the blast. |
| `kj_acid_burst.wav` | 1.2 s | Glass shatter and acid splash. Bright crack, about 130 glass tinks (2.5 to 9 kHz, thickest in the first 0.15 s, gone by 0.5 s), a wet band-passed splash, rising bubbles and a fading sizzle. |
| `kj_acid_hiss.wav` | 2.0 s | Loopable hiss and bubbling. High-passed noise slowly modulated, a faint mid layer, about 28 random rising bubbles per second and a few low glops. The sound is stationary by design, and 0.25 s of extra tail generated past the loop end is crossfaded (equal power) into the head, so the last sample flows straight into the first with no click. No fades, so play it with `loop=true`. |

The boom family shares one recipe (`boom()`), so small, medium and large differ only in pitch range, decay times, debris
count and reflections; that keeps them recognisably one family at three sizes.
