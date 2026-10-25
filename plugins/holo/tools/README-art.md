# Holo art and fonts

Everything under `mod/textures/ui/` and `mod/fonts/`, and `src/55_atlas.lua`, is generated. Run the scripts from the
plugin folder (they need numpy and Pillow; `make_font.py` also downloads the fonts once into `tools/.cache`):

| Script | Writes |
| --- | --- |
| `python tools/make_panels.py [--check] [--emit-lua]` | `mod/textures/ui/panels.png` |
| `python tools/make_icons.py [--check] [--emit-lua]` | `mod/textures/ui/icons.png`, `cursor.png` |
| `python tools/make_font.py [--check] [--emit-lua]` | `mod/fonts/{display,display_s,body,body_s}.png/.json`, `OFL.txt` |
| `python tools/make_preview.py [--bg SCREENSHOT] [--out PNG]` | a mock layout (not shipped, `tools/preview/` is ignored) |
| `python tools/tests/test_art.py` | limits, metrics sanity, determinism |

`--check` compares the files on disk with a fresh render byte for byte (and `src/55_atlas.lua` too), and exits 1 when
they differ. `--emit-lua` rewrites `src/55_atlas.lua` from all three generators; after changing any atlas run one
generator with `--emit-lua`, then `python tools/build_lua.py` to refresh `mod/client/init.lua`. The renders use seeded
noise and a fixed PNG encoder; the font bake also depends on the FreeType inside Pillow, so rebuild with the same Pillow
major version (12.x) when you need `--check` to agree.

## The look

Vanilla WUM frontend, sampled from screenshots by the style research: teal panels (`#1D5060`, top `#1F5E70`), darker
wells (`#153443`, `#194356`), buttons `#005372` (hover `#0E6C8E`, press `#00435C`, disabled `#605284`), cream text
`#FEE195`, title yellow `#FFF59B`, gold headings `#EFDE84`, paper tags `#FFEFD6`, seek fill `#FFD24A`, error `#E8221A`,
cursor orange `#FF9A30` (an estimate: it has not been sampled from a screenshot). Shapes have a black 4 px wobbly outline,
a white 2 px rim on interactive pieces, a hard shadow (+3,+5 px, 45%, 4 px blur) baked into the margin, an 18 px panel
radius, full-round pills, a bevel line pair, a torn-paper tag and a black ink swash for selected rows. Nothing is taken
from the game's files.

All PNGs are authored at 2x. Load them with `wum.draw.texture(file, {mips = false})` and draw nine-slices with
`scale = 0.5`. Sizes: panels 1024x600, icons 888x962, cursor 96x96, fonts 768-1280 wide (all at most 1024 high); the
whole set is about 1.5 MB.

## `55_atlas.lua`

It fills `SKIN.atlas` and `SKIN.fonts` (the header of the generated file says the same). All rectangles are in texture
pixels of the 2x PNGs and use **named fields**.

* `SKIN.atlas.panels.rects[name] = {x, y, w, h, l, t, r, b, pad = {l, t, r, b}, inner = {l, t, r, b}}`. `x, y, w, h` is
  the source rectangle, `l, t, r, b` the nine-slice insets for `wum.draw.hudNine`, `pad` the transparent margin that holds
  the shadow: the visible shape starts at `pad`, so to put a shape at screen rect `X0..X1` draw the rect from
  `X0 - pad.l*s` to `X1 + pad.r*s` (s = the nine scale, 0.5). `inner` exists on the frames only: the hole's inset from the
  source rect, i.e. where the picture goes (the picture's rectangle is the frame's rect shrunk by `inner*s`; its corners
  are covered by the frame).
  Names: `panel, panel_dark, tooltip, btn, btn_hover, btn_press, btn_off, pill, tag, well, bar_track, bar_fill,
  frame_video, frame_corner`, plus the small parts `tail` (tooltip pointer), `knob` (seek knob, 44 px), `scrim` (black fading
  to nothing upwards, stretch it behind the control bar with `hudImageUV`), `divider` (white brush stroke, stretch
  horizontally) and `swash` (black ink behind a selected row). Plain parts have insets `0`; `divider` and `swash` stretch
  horizontally only.
* Buttons are pills of one fixed height (visible shape 192x96 at 2x, 96x48 at 1x) that stretch horizontally; do not
  stretch them vertically. `bar_track` is 20 px high (10 at 1x) and `bar_fill` goes inside it.
* `SKIN.atlas.icons = {file, w, h, cell, states = {"normal", "hover", "press", "off"}, rects}` with
  `rects[name] = {{x, y, w, h}, ...}` one entry per state, each `cell` (72) square at 2x, 36 at 1x. Names: `play pause
  prev next back10 fwd10 vol0 vol1 vol2 mute speed cc audio quality queue minimise expand hide close up down add check
  cross link magnet people warning download crown spinner1..spinner8`. Hover has a white rim, press is darker and 1 px
  lower, off is grey. `check` is green, `cross` and `mute`'s X red, `warning` amber, `crown` gold. `spinner1..8` are the
  frames of one rotating comet.
* `SKIN.atlas.cursor = {file, w, h, hot = {x, y}}`: the orange arrow (96x96 at 2x), `hot` is its tip in texture pixels.
  Pass the texture as `wum.input.pointer(true, {cursor = tex})`.
* `SKIN.fonts.<display|display_s|body|body_s> = {png, json, size, w, h}`, to be given to `wum.draw.font(png, json)`. `size`
  is the pixel size at scale 1 (28, 20, 20, 16): draw a font at its own `size` for a 1:1 bake, and pick the nearest one.
  Four fonts is the per-mod maximum, all four are used.

## Fonts and the OFL

* Display: **Lilita One** (Copyright 2011 Juan Montoreano). Body: **Baloo 2** ExtraBold (Copyright 2019 The Baloo 2
  Project Authors). Latin Extended-A and Cyrillic glyphs that those two lack come from **Rubik** ExtraBold (Copyright 2015
  The Rubik Project Authors), scaled to the same cap height. All three are SIL Open Font License 1.1, downloaded from
  `google/fonts` at the commit pinned in `fonts.lock.json` with the files' sha256 checked.
* Lilita One's licence file declares a Reserved Font Name ("Lilita"). A baked bitmap atlas can count as a Modified
  Version, so the shipped atlases are called **Holo Display** and **Holo Body** (the `name` field of the metrics, and the
  README credit); the originals are credited and `mod/fonts/OFL.txt` carries each font's copyright line and the licence.
  Baloo 2 and Rubik have no Reserved Font Name; Holo Body is named the same way for uniformity.
* Glyph set: ASCII, Latin-1, Latin Extended-A, Cyrillic (U+0400-045F, U+0490-0491) and common punctuation (dashes, curly
  quotes, bullet, ellipsis, euro, trademark, arrows, minus, multiplication). CJK and emoji are not covered (they draw as
  `?`).
* The fill is white and the outline black, baked in (2 px at 1x for display/body, 1 px for `body_s`), so the tint colours
  the fill only. For **dark text on the cream tag** the outline cannot be dropped: tint `body`/`body_s` near-black
  (`#1A1004`) and the text reads as heavy ink.
* Kerning: the metrics carry an empty `kern`. Pillow's basic layout reads only the legacy `kern` table, and these fonts
  kern through GPOS, so no pairs are extracted; the rounded display fonts are spaced evenly enough that it is not
  noticeable.
