# Sandtide art and audio

Generators (run from this folder; the art ones need numpy and Pillow, the sound one is stdlib only):

| Script | Writes |
| --- | --- |
| `make_hud.py [--preview PATH]` | `mod/textures/hud/*.png` and `hud_layout.json` (about 2 minutes) |
| `make_sprites.py` | `mod/textures/dust_puff.png`, `sand_grain.png`, `sand_swirl.png`, `sand_band.png` |
| `make_textures.py --src DIR` | `mod/textures/sand_albedo.png`, `sand_normal.png`, `cracks.png` from the CC0 ambientCG maps (see the README's Credits) |
| `make_sounds.py [--check]` | `mod/sounds/*.wav` (about 20 seconds); `--check` compares with the files on disk |

## The hourglass HUD

Canvas 256 x 384, drawn at half size (128 x 192 HUD pixels at hourglass size 1.0). `wum.draw.hudImage` draws a whole
texture, so everything that animates is a stack of textures, each cropped to its own rectangle on the canvas.
`hud_layout.json` has every texture's rectangle `[x0, y0, x1, y1]` in canvas pixels. To place one, map the canvas onto
the screen rectangle of the hourglass: `sx = left + x * scale / 2`, `sy = top + y * scale / 2`.

| Texture | Rect (canvas px) | Use |
| --- | --- | --- |
| `hg_shadow.png` | 0,0,256,384 | soft drop shadow of the frame; always first |
| `hg_shadow_glass.png` | 0,0,256,384 | drop shadow of the glass; hide after the strike |
| `hg_glow.png` | 0,0,256,384 | amber halo round the glass; last 15 s, pulse its alpha with the tick |
| `hg_glass_back.png` | 0,0,256,384 | dark glass interior, behind the sand |
| `hg_sand_top_00..15.png` | 48,48,208,196 | top bulb sand, 15 = full, 00 = empty (a few grains); level = remaining / 180 s * 15, crossfade the two nearest |
| `hg_stream_0..5.png` | 112,176,144,340 | the falling stream, a 6-frame loop (about 12 fps); hide when the top is empty |
| `hg_sand_bot_00..15.png` | 48,188,208,336 | bottom heap, 00 = empty, 15 = full; same index as 15 - top. Draw after the stream, so the heap hides the stream's foot |
| `hg_glow_inner.png` | 0,0,256,384 | ember glow inside the glass; with `hg_glow` |
| `hg_glass_front.png` | 0,0,256,384 | highlights, Fresnel, rim light, collar shadows; over the sand |
| `hg_crack_1..3.png` | 0,0,256,384 | cracks, each stage contains the one before (suggested: 1 at 0:15, 2 at 0:08, 3 at 0:03), with `sdt_glass_crack` |
| `hg_frame.png` | 0,0,256,384 | brass and bone frame with the sandworm-maw medallions |
| `hg_mask_top.png` / `hg_mask_bot.png` | as the sand | white bulb interiors, for tinted flashes inside the glass |
| `hg_shatter_00..11.png` | -64,-64,320,448 | the shatter, 12 frames (about 40 ms each): white flash, shards flying with gravity and fading at the edges, the heap slumping onto the base. Replaces glass, sand, stream, cracks and glows; draw over the frame. Play `sdt_glass_shatter` on frame 0 |
| `hg_sand_spill.png` | 16,280,240,340 | the heap left on the base, after the last shatter frame (it matches frame 11) |
| `hg_drop_00..08.png` | 80,128,176,256 | the water countdown shown in the empty frame after the strike: 00 empty glass drop, 08 full; fill = elapsed since the strike / 120 s |
| `hg_plate.png` | 16,384,240,456 | the mm:ss readout plate under the hourglass; text centred at canvas (128, 420), about 15 px high at scale 1 |
| `hg_plate_glow.png` | 16,384,240,456 | white screen-glow mask for the plate: tint orange in the last 15 s, blue in the water countdown |

Draw order before the strike: shadow, shadow_glass, glow, glass_back, sand_top, stream, sand_bot, glow_inner,
glass_front, crack, frame, plate (+ plate_glow), text. After it: shadow, frame, drop, shatter frame or sand_spill, plate.

## World textures and sprites

| Texture | Size | Use |
| --- | --- | --- |
| `sand_albedo.png` | 512, tiles | the petrify coat's colour (load with `{wrap = "repeat"}` for a shader) |
| `sand_normal.png` | 512, tiles | its OpenGL normal map (+Y up) |
| `cracks.png` | 512, tiles | crack mask in every channel (R=G=B=A), for the coat's cracks and the mound |
| `dust_puff.png` | 128 | dust cloud particle; white, tint it sand-coloured |
| `sand_grain.png` | 32 | one grain; grey-shaded sphere, tint it |
| `sand_swirl.png` | 128 | a spiral wisp of blown sand; spin it slowly, tint it |
| `sand_band.png` | 256 x 64, tiles in x | drifting sand for the sand line: scroll it sideways along the line |

## Sounds

All 16-bit PCM, 44.1 kHz, under 2 MiB, no clipping. Mastered for the mix (`master()` in `make_sounds.py`): one-shots
peak at -6 dBFS with their RMS at most -18 dBFS, loops at an RMS of -24 dBFS. `_loop` files loop seamlessly
(`loop = true`). `python sound_report.py --strict` reads the files back and checks the levels and the loop seams.

| File | Length | Use |
| --- | --- | --- |
| `sdt_wind_loop.wav` | 8.0 s stereo loop | desert wind bed under the camera tour only |
| `sdt_drone_loop.wav` | 10.0 s stereo loop | ominous bed under the camera tour (A1 cluster, choir, heartbeat sub) |
| `sdt_sand_pour_loop.wav` | 4.0 s loop | the hourglass running out: faint, the last 10 s of the clock only |
| `sdt_rumble.wav` | 4.5 s | the earth answering the curse, at the start of the tour |
| `sdt_sand_grind.wav` | 3.6 s | the petrify creeping up one worm (one per worm in the tour, positional at the worm) |
| `sdt_crunch.wav` | 2.8 s | the sting when a worm's tail locks into stone (crack, thump, rock crunch, tritone chord, gong) |
| `sdt_dust_burst.wav` | 1.6 s | the sand mound bursting up |
| `sdt_glass_crack.wav` | 0.9 s | each new crack stage on the hourglass |
| `sdt_glass_shatter.wav` | 2.6 s | the hourglass shattering at the strike |
| `sdt_tick.wav`, `sdt_tock.wav` | 0.25 s | the hourglass tick in the last 15 s; alternate them |
