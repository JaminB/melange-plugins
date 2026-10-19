# Sunstone

A client-only graphics overhaul for Worms Ultimate Mayhem, built from Mirage and the engine's own switches.
Shaders, code and original or permissively licensed art only — no game texture, or anything derived from one, is
ever shipped.

## Quality and look

A **Quality** setting (Off / Low / Subtle / Bold / Ultra) on the Mods page turns Sunstone's effects on together with
sensible parameters; a **Look** setting (Golden / Dusk) picks which of the two colour-grading LUTs the grade
leans toward, **Sunstone lighting** and **Sunstone water** turn the lighting and the water below on or off on their
own, **Distance blur**, **Film grain** and **Lens effects** (dirt, flare and colour fringes) turn those off,
**Material detail** (on by default; Subtle draws it lighter, Bold and Ultra in full, Low and Off not at all) adds each
material's surface to props, weapons and worm gear (see Lighting), and
**Worm skin** gives the worms human skin and **Worm hair** real moustaches (below). All apply live, no restart. Every effect still has its own toggle
and parameters in the overlay's *Mirage/Post-FX* panel
(and in `Melange.ini [MiragePostFX]`) if you want to go off the preset — a manual change there survives until you
next change Quality or a match with a different theme starts.

| Quality | Effects on | Notes |
|---|---|---|
| Off | none | vanilla rendering: the game's own shaders and shadow map |
| Low | SMAA, Sharpen, the single-pass colour and grade, soft shadows, lighting without relief, water without foam, scenery reflections or caustics | 2048² shadow map |
| Subtle | + ambient occlusion, light and atmosphere (haze, sun glow, cloud shadows, a little bloom), a final dither, contact-hardening shadows, texture relief, shore foam, scenery reflections and caustics | close to the game's own look; 2048² shadow map |
| Bold (default) | everything, including contact shadows, light shafts, distance blur, bloom, lens dirt and flare, colour fringes, film grain and a deeper sea | the modern look; 4096² shadow map |
| Ultra (opt-in) | Bold without SMAA, plus 2x2 supersampling | Bold rendered at twice the resolution each way and scaled down: the cleanest edges and the steadiest textures and water, for a GPU with room to spare |

Settings saved as Medium or High by earlier versions read as Bold. The 1.7 fog, sky, bloom and grade effects are
replaced by the light and atmosphere effect below and are switched off on upgrade.

Ultra asks Melange for 2x2 supersampling (`wum.graphics.setSupersample`), so the game renders a 3840x2160 scene for a
1920x1080 window. Ambient occlusion and the light and atmosphere effect switch to their `_u` copies, which run their
reduced-resolution passes at half the usual scale. Pixel-sized blurs, sharpening and fades follow the render scale,
so Ultra keeps Bold's look. The HUD and text render at the higher resolution too. Switching back to another preset
restores the game's own `/SSAA` and FXAA settings. A Melange without `wum.graphics.setSupersample` renders Ultra as
Bold.

## Worm skin

The **Worm skin** setting (Game / Fair / Light / Medium / Olive / Tan / Brown / Deep / Mixed; default Game) gives the
worms human skin. Game keeps the game's cartoon peach. A tone gives every worm that skin; Mixed gives each worm one of
the seven tones (with a few percent of its own variation), picked from its name, so a worm keeps its tone from match to
match. Quality Off turns it off (the game's own rendering).

The skin is drawn by Sunstone's lit-model shader (`shaders/FixedFunction.FFFragmentMainTexLit.glsl`), the same program
that lights every textured model, at the point where a fragment's colour is still the texture's own texel, before any
light, grade or post-FX. Nothing has to be guessed from the finished frame, so lighting, the theme's grade, hats or the
sand can't make the skin look like something else:

- **Finding the skin.** A worm's body, tail, hands, eyes and lids are drawn with a material that nothing else uses
  (specular 0.2/0.18/0.1, gloss 5). Within it, skin is every texel of the peach's colour family: the peach, its shaded
  parts and the pinker ones (the lids' crease, the lips). The eye whites, pupils, teeth and the inside of the mouth are
  other colours and keep them. What a worm wears is drawn with a material it shares with many props, so a glove that
  shows bare skin (the fingers of a fingerless glove, a ringed hand, a wrist) is told by its texture (see Worm hair
  below), and only its peach texels take the tone.
- **The new skin.** The tone replaces the peach texel and keeps the texture's darker drawn detail (creases, the mouth
  line, lids, a glove's painted shading) as its brightness against the peach, not its colour, so the peach's own faint
  blotches and the steps of its 8-bit gradients don't turn into islands of another hue on a tone. Skin albedos (in the
  texture's terms; the game's peach is 0.953/0.620/0.475): fair 0.92/0.80/0.73, light 0.85/0.73/0.50, medium
  0.64/0.46/0.36, olive 0.53/0.47/0.355, tan 0.52/0.38/0.18, brown 0.40/0.26/0.185, deep 0.28/0.18/0.135. Each differs
  from its neighbours in undertone as well as lightness: fair a pink ivory, light a golden beige, medium a warm, rosy
  tan, olive a muted green-brown, tan a golden brown, brown and deep red-browns. The light and the grade roughly halve
  the distances between them on screen, so they are set wider apart than in a photograph. Each worm gets a few percent
  of its own tone and its own ruddiness.
- **Skin shading.** On top of Sunstone's light: blood showing through, blotchy, most at the cheeks, nose and lips and in
  the texture's creases (less pink and more warm on a darker tone, browner on olive); darker skin around the eyes and a
  more tanned back; an oily T-zone (the snout and the brow, in patches) with a tight, strong highlight, against matte
  cheeks and body. Detail sized to be seen from the distance the game is played at: broad blotches of blood and of
  pigment (gradient noise, two sizes each, stronger on darker tones), folds (and close up finer broken wrinkles) round
  the throat, the nape and down the back to where the body bends to the ground (each a valley with a roll of skin above
  it, widened with distance so it never thins below a pixel), a grain on the skin never finer than about 4.5 pixels that shows
  mostly in the sheen, a few moles and small red blemishes on every worm and freckles on most fair and light ones. For
  close views, pores, each a small pit in the surface that breaks up the sheen, about 0.085 world units apart (denser
  and bigger on the T-zone, in patches). The grain, creases, spots and pores are fixed to the skin by the body texture's
  coordinates and measured on the skin, so they stay round and evenly spaced where the texture is stretched, and don't
  slide over the skin as the worm sways (where the texture is stretched too far, on the front of the chin, the grain is
  left out rather than drawn as streaks); the body's texture is mirrored, so each half gets its own spots and pores.
  Each size fades out as it gets smaller than a few pixels, so nothing shimmers; what the pores took from the sheen is
  kept as a rougher sheen where they fade. The face is placed from each worm's centre and facing, which the script
  sends. Light is carried under the
  skin: each channel wraps past the shadow edge as far as it travels in skin (red furthest), and sees a softer copy of
  the bumps (red the smooth surface, blue the bumped one), so the bumps read soft and fleshy and the terminator soft and
  warm, with a band of red light along it; the thin edges glow warm against the light; the shade comes out warmer and
  deeper in colour than the lit skin, and a darker tone's shade is lifted in dim light (as a camera or the eye exposes
  for a dark face), so Brown and Deep keep warm red-brown mid-tones instead of going black while staying dark in the
  sun. The sheen is two GGX lobes, a tight oily one and a broad matte one, and the sky's dull reflection, which keeps a
  dark face's form readable in shade. In bright light the skin rolls off softly by the same factor in every channel,
  sheen included (only its hottest part a little toward white), so a fair skin keeps its colour in the sun and an oily
  nose's highlight rolls off instead of clipping per channel (in full sun it can still read as a small white spot).
  The skin takes only part of the scene
  light's own colour (`skinChroma` per theme in the script, 0.35 by default), so the tones keep their undertones under a
  coloured sun or grade; Horror and War, whose grades grey the frame, get the skin's colour a little richer first
  (`skinVivid`, 1.1 and 1.15), and War's dim shade lifts a darker tone further (`skinShade`). The eye whites go a
  natural white, a little darker beside a darker tone but never brown, with a wet highlight, and shaded toward the
  eyeball's edge so the eye sits in the face. Against colour banding: the texture's own faint blotches and 8-bit steps
  are taken off its detail smoothly (a threshold drew contours around them), the blotches are gradient noise (value
  noise left blobs on a grid), and the skin is dithered by about one step of the 8-bit frame before it is stored, so
  the frame's highlight expansion and the grade don't stretch its gradients into contour bands. With Sunstone's lighting off the tone and its detail stay, lit by the game.
- **Per worm.** The script sends each living worm's body centre, facing, tone, seed and (Mixed hair) hair colour (16
  shader parameters) while the skin is re-toned or the hair is Mixed: only when a worm has moved more than 0.4 units,
  turned or changed, at most three a frame, and it reads the worms every frame only while one moves (every eighth
  otherwise). The shader works out the fragment's world position from the view matrix and takes the nearest worm's.

The *Mirage/Shaders* panel lists the shader's sliders under `FixedFunction.cg:FFFragmentMain*Lit*`: light under the
skin (`sunstoneSkinSss`), sheen (`sunstoneSkinSheen`), pores and blotches (`sunstoneSkinPores`), blood showing through
(`sunstoneSkinFlush`), a darker tone's lift in shade (`sunstoneSkinShade`), the hair's highlights (`sunstoneHairSheen`),
and a debug view (`sunstoneSkinDebug`: 1 shows skin magenta, a glove's skin orange, the worm's other parts green,
moustaches cyan, hair hats yellow and other matte parts blue; 2 shows which worm each fragment takes its colours from;
3 shows the face: red the blood showing through, green the oiliness, blue the lips, folds and wrinkles; 4 shows the skin's sheen and glow
alone). The rest (`sunstoneSkin`, `sunstoneSkinTone`, `sunstoneSkinMixed`, `sunstoneSkinChroma`, `sunstoneSkinAmbient`,
`sunstoneSkinVivid`, `sunstoneHair`, `sunstoneWigs`, `sunstoneWorm0..15`) are set by the script.

**With Bloodsand and Kindjal.** They find skin by its peach colour, which a human tone no longer has. So the shader
marks every opaque skin fragment it draws in the scene's alpha (its colour on the 8-bit grid and the alpha a hash of
that colour), the game's own peach too whenever the shader runs, `shaders/PostProcess.RecombineWorms.glsl` (the game's
pass that lays the turn's worm over the rest of the scene, with the mark carried through; it runs whenever the lit-model
shader does, so a skin or hair change never re-links it) leaves exactly 245/255 in the alpha on skin and 1 everywhere
else, and Bloodsand 1.4.0 and Kindjal 1.2.0 take that mark as skin. Sunstone tells them, in the event
`mod.sunstone.skin` (`{ on, hair, marks, lum = { slot 0 .. 15 } }`), whether the skin is marked, re-toned or wearing
Sunstone's hair, and each worm's skin brightness against the peach. They take their colour test or the mark (so they also
find the peach under Lunar's purple light and on a poisoned worm, a human tone by its mark, and the game's peach by its
colour should Sunstone's shader ever not run; a moustache drawn as real hair can then catch a wound or acid where its
highlights have the peach's colour). A wound, blood's sheen, a burn and the acid are as bright on a dark skin as on the
peach, while a bruise darkens the skin it is on. Bloodsand clears the mark where it painted, so Kindjal's acid does not
eat blood or guts. Where the worm whose turn it is stands behind a ledge or a prop, the game shows it through as a ghost
of what is in front. While the skin is re-toned or Sunstone draws the hair, `shaders/PostProcess.Silhouette_PC.glsl`
draws that ghost so 40% of the worm's own colour and its skin's mark survive under it (the tone carries on
through, dimmed, instead of a hard wedge of grey); that skin is marked 244/255, and Bloodsand and Kindjal find the worm's
body along the view ray, so wounds and acid go on through the ledge (a little fainter). That pass changes only between
scenes (switching it re-links it, which can stall a frame), so a skin change in the middle of a match brings it from the
next scene on. An older Bloodsand or Kindjal paints only on skin of the game's colour;
Sunstone then says so on the screen at the start of a match (and in the log).

A Worm skin or Worm hair change only sets shader parameters: nothing is compiled, linked or logged. (Melange flushes its
log to disk on every line, on the game's thread, so a burst of log lines could stall a frame when the disk was busy.)

**Limits.** On marked skin the brightest 4% of a highlight is clipped (the composition pass divides the colour by the
mark's alpha, which the game's blend multiplies back). The material and the colour family are this game build's; a mod that replaces the worm's texture with other
colours would need them updated. A see-through layer the game blends over the lids keeps its own alpha, so Bloodsand
finds no mark there (it still finds the opaque lids under it). A particle drawn over the skin after the composition pass
can leave the mark's alpha on a thin edge; Bloodsand's and Kindjal's own body-shape tests keep that from showing. With
Mixed, two worms that touch split their tones along the line halfway between their centres.

In the game's instant replay after a hit, a worm with a tone set was seen drawn in the game's peach (the cause is not
known yet; it is not where the tone is placed, since with one tone every worm gets it). Normal play is unaffected.

## Worm hair

The **Worm hair** setting (Game / Natural / Mixed; default Game) draws the worms' moustaches as real hair. Game leaves
them as the game draws them. Natural gives each moustache a natural colour from its own colour family (the game's black,
brown, blond, ginger, grey and white moustaches become black, dark brown, blonde, ginger, grey and white hair). Mixed
gives every worm's moustache a natural colour of its own from its name (black, dark brown, brown, light brown, dark
blonde, blonde, auburn, ginger or grey), weighted by its skin tone as in life (black and dark brown on every tone and
most on deep ones, blond and red mostly on light ones; with the game's peach, the light tones' weights), so a worm keeps
it from match to match. It is independent of Worm skin. Quality Off turns it off.

- **Finding the hair.** Every moustache, glove and hat shares one matte material with many props, so the shader reads the
  texture at three fixed places and compares the three colours with a table of the game's textures: the 23 moustaches
  (20 textures; the safety pin is not hair), the 28 glove textures that show bare skin, and the hair hats. `tools/make_fingerprints.py` builds the table
  from the game's own files (its bundles, read with Melange's XOM reader) and checks it against all 1,050 textures drawn
  with those materials, the game's props and Kindjal's weapons included: each entry is at least twice the match
  tolerance from every texture it must be told from. Every fragment of a draw reads the same three texels; the table
  is sorted by the first texel's red, so a binary search and a look at the few entries near it decide (reading the whole
  table cost up to 0.6 ms a frame where fence posts or barbed wire filled an Ultra view). It runs on matte models only,
  and not at all while both settings are on Game.
- **The hair.** The texture's own strand detail on the natural colour, with finer strands along the texture's strands
  about four pixels apart at any distance (two octaves blended, so the scale never jumps) in locks fixed to the texture;
  lit by Sunstone's light, with the two highlights of a hair fibre (Kajiya-Kay) along the strands in place of the
  material's broad one: a white one toward the tips and one in the hair's colour toward the roots, broken into glints.

**Hair hats (experimental).** The **Realistic hair hats too** setting (off by default, needs Worm hair on) also draws
the hats that are hair (the afro, the pigtails, the punk crest, the professor's hair, and the hair of the caveman,
Frankenstein and Queen of Sheba hats, where only their dark texels are hair) the same way. A hat is never recoloured:
natural ones (the afro, blonde and ginger pigtails, the professor's white) take that natural colour, dyed ones (pink and
blue pigtails, the coloured crests) keep their own. The red pigtails share their texture with the small red moustache, so
they are drawn as hair whenever Worm hair is on.

**Limits.** A worm-texture mod, or a hat or moustache a mod adds, is not in the table and is left as drawn (run
`tools/make_fingerprints.py` with `--extra` on that mod's XOM files to check or extend it). Strands need a few pixels to
show; at the game's usual distance a moustache shows its colour, shading and sheen.

## Texture clarity

16x anisotropic filtering and trilinear minification filtering on the game's own textures, declared in
`mod/spice.json`'s `graphics` block and applied by Melange. Off (vanilla) unless this mod is enabled or
`Melange.ini`'s `[MirageTextures]` overrides it:

```ini
[MirageTextures]
Anisotropy=auto   ; auto | an integer 0-16
Trilinear=auto    ; auto | on | off
LodBias=auto      ; auto | a number from -8 to 8
```

## Anti-aliasing and sharpening

Post-FX effects under `mod/postfx/`, all off until Quality turns them on:

- **`smaa`** (PostWorld): SMAA 1x anti-aliasing ([iryoku/smaa](https://github.com/iryoku/smaa), MIT — `LICENSE.txt` in
  the folder). Use instead of the game's `/FXAA`, not with it.
- **`sharpen`** (PostWorld): AMD FidelityFX Contrast Adaptive Sharpening, no upscale
  ([FidelityFX-CAS](https://github.com/GPUOpen-Effects/FidelityFX-CAS), MIT — `LICENSE.txt` in the folder). It
  fades out on surfaces right in front of the camera and leaves faint steps alone, so magnified textures do not
  turn blocky; local contrast fades out near the camera the same way.

## Atmosphere

All distances are in the game's world units: a worm is about 30 units tall, scenery sits 50 to 3000 units from the
camera, the sea runs out to the horizon and the sky dome is about 9400 units away (about 0.6 of the far plane).
Sky pixels are found by that distance, so no effect darkens, fogs or blooms the sky by mistake.

- **`ssao`** (PostWorld): horizon-based ambient occlusion and short sun contact shadows from the depth buffer,
  applied in linear light.
- **`hdr`** (PostWorld, "Light, atmosphere and grade"): the world in linear light, height fog toward the sky's own
  horizon colour that gives distant islands depth, a sky gradient and sun glow, cloud shadows, light shafts, distance
  blur on far scenery, bloom, lens dirt and flare, then a hue-preserving display transform that rolls bright colours
  softly to white, a colour-grading LUT (`golden.png`, `dusk.png`, generated by `tools/make_luts.py` from pure code)
  and a dither. The textures it reads are generated by `tools/make_textures.py`. Themes where a part does not fit go
  without it: no sun glow or light shafts on Horror, Lunar and War, no cloud shadows on Lunar, no warm LUT on cool or
  violet themes.
- **`lite`** (PostWorld): a single-pass version of the colour and grade for Low.
- **`lens`** (PostWorld): colour fringes toward the corners, film grain and a final dither.

## Shadows

The game draws one shadow map for the whole level at 1024², filtered with a 3x3 average, so shadow edges are
blocky and worm shadows are blobs. Sunstone asks Melange for a larger map (`graphics.shadowMapSize` in
`spice.json`, 2048; the Quality preset changes it live) and replaces the landscape pixel shaders with GLSL versions
(`mod/shaders/`) with their own shadow lookup (and their own lighting, below):

- **Soft** (Low): a wide, smooth tent filter made of bilinear depth-compare taps. No noise, so nothing shimmers.
- **Contact-hardening** (Subtle, Bold): a blocker estimate picks between a sharp and a soft kernel, so shadows are
  crisp where an object meets the ground and soften with distance from it.

Both add a slope-scaled bias and an offset on steep receivers, and surfaces facing away from or edge-on to the sun
shade themselves, which removes the stripes (acne) the game shows on grazing slopes and on steep ground close to the
camera. The sliders are in the overlay's *Mirage/Shaders* panel (`shaders/params.ini`): filter mode (0 is the game's
own filter), penumbra spread, contact distance and bias. `Melange.ini` has the last word on the size:

```ini
[MirageShadows]
ShadowMapSize=auto   ; auto | vanilla | 512 | 1024 | 2048 | 4096
```

A 4096² map uses 64 MB of VRAM. Worms and props still cast shadows but do not receive them; that needs Melange work.

## Lighting

The game lights everything with one flat ambient colour plus the sun, and clips the result per channel, so large
sunlit surfaces wash out to pale cream and anything in shadow loses its shape. Sunstone replaces the pixel shaders
of the landscape (`Landscape.LandscapeFragmentMain`, `Landscape.HeightMapFragmentMain`) and of the game's lit models
(`FixedFunction.FFFragmentMain*Lit*`: worms, props, weapons) with original GLSL written against the same inputs:

- **Hemispheric ambient**: surfaces facing up get the sky's light, surfaces facing down the bounce light off the
  ground, so shaded sides of worms, rocks and cliffs keep their form and worms and props sit on the ground with
  darker undersides. The tints come from a per-theme table.
- **Sun and shade**: a stronger sun and deeper cast shadows, with a warm sun and cooler shade on the themes that
  suit it; shade keeps the colour of the surface rather than turning grey or violet.
- **Grass and foliage**: meadows and leaves move from neon toward natural greens, with softer light through the
  grass and fine detail on the ground. Off on Arctic, Lunar and Horror, whose colours are the theme's art.
- **Energy-conserving Blinn-Phong**: a normalised highlight (narrow and bright on glossy surfaces, wide and faint on
  rough ones), with a Schlick-style rise at grazing angles. Models use the game's own specular colour and gloss per
  material; the landscape uses the theme's reflectance and gloss.
- **Rim light**: edges catch the sky and the sun, strongest when back-lit; on Bold it clearly outlines worms and
  props.
- **Texture relief** (landscape, Subtle and Bold): fine bumps taken from the texture's brightness, built from
  screen-space derivatives so no extra geometry or tangents are needed. It fades out with distance and at grazing
  angles, where it would shimmer.
- **Highlight roll-off**: bright colours roll off toward white, as film does, instead of clipping per channel, so
  sand and stone keep the game's pale character rather than turning orange.
- **Material detail** (2.3; the **Material detail** setting): the lit-model shader draws a material's
  surface over the art (grain, wear, cavities, sheen) from procedural code per material class
  (`tools/materials`), sized in world units and faded by each pixel's footprint so it never shimmers. Melange tells the
  shader which texture is bound (texture tags, `mod/texture_tags.json`: digests and numbers only); with a Melange
  without texture tags, or a texture not in the table, the class is guessed from the material (metal or matte). The
  worms' own skin and hair never get it. `sunstoneMatSplit` and `sunstoneMatDebug` in the *Mirage/Shaders* panel
  compare it and show the classes. Besides the procedural detail, all classes share eight original tileable material
  maps (`mod/assets/detail/materials.png`: grain, wood, brushed metal, stone, weave, leather bumps, wear, bark), one
  texture array bound to the shader by Melange's shader textures, so Sunstone 2.3 needs Melange 0.10 or later.
  The landscape (buildings, bridges, walls, signs and the ground, drawn from the theme's tiles) gets a lighter form of
  it, one shared-map sample per tile for its classes (stone, brick, concrete, wood, painted and rusted metal, sand,
  grass, snow, leaves), in place of its World detail noise; other tiles keep the World detail. It needs a Melange whose
  texture tags follow the Cg runtime's texture binds (the landscape's tile is bound to unit 1 that way).

The per-theme materials (reflectance, gloss, relief depth, sky and ground tints, sun and shade tints, and grade
offsets such as Horror's exposure) are the `THEMES` table in `mod/client/init.lua`. The sliders in the
*Mirage/Shaders* panel (`shaders/params.ini`) cover the same terms, plus `sunstoneLight` (0 is the game's lighting)
and `sunstoneSplit`, which keeps the game's lighting left of a screen x for side-by-side comparisons. Off and the
**Sunstone lighting** setting hand the programs back to the game.

## Water

The game's sea is one textured quad: scrolling normal maps, a colour ramp and a fake environment lookup, drawn
half-transparent, with no sense of depth and a lot of shimmer at grazing angles. Sunstone replaces its pixel shader
(`Water.WaterFragmentMain`) with original GLSL that reads copies of the scene's depth and colour taken just before
the water draws:

- **Depth and refraction**: the water's thickness along each view ray comes from the depth behind it. Shallow water
  shows the sand and rocks below in the water's own hue, gently bent by the waves; the light is absorbed with depth
  toward the game's own water, computed from the game's own water terms (colour ramp, environment map and
  parameters) at run time, so every theme keeps its sea, Horror's murky green included.
- **Caustics** (Subtle, Bold): faint moving light patterns on the floor of the shallows.
- **Reflection**: the scenery above the water, found on screen and faded out softly beside cliffs and other
  silhouettes, then a Fresnel blend toward the game's own sky (taking on the water's hue, so a pale horizon never
  turns the sea cyan). Low reflects only the sky.
- **Glints**: the game's own white wave glints, a sharp sparkle and sheen from the level's sun, sun-facing crests
  and small flecks on ripple crests (fewer on pale water, so they never read as blotches). Facets and crests fade
  out at glancing angles, so the far sea shows no pale bands. A slow rotated swell and a noise that varies the wave
  height across the sea hide the normal map's repeat far out.
- **Rich sea** (Bold): a deeper, more saturated version of the game's own water hue with crisp white glints. The
  colour keeps the hue the game's own water would have at each pixel, so the shallow tint, sky and seabed never pull
  an olive or pale cyan sea toward green or teal.
- **Shore foam** (Subtle, Bold): light, broken, slowly drifting foam where the water is shallow, fading on steep
  banks, from procedural noise computed in the shader (no texture is shipped).
- **No shimmer**: each wave layer fades out where its texels shrink below a pixel.

Sliders in the *Mirage/Shaders* panel (`shaders/params.ini`): deep and shallow tints, clarity, reflection, waves,
refraction, glint, foam, scenery reflections, caustics and rich sea; the `sunstoneWater` view shows the water depth,
the foam, the glints, the reflections or the caustics alone, and `sunstoneSplit` draws the game's own water left of a
screen x for comparisons. The **Sunstone water** setting and Off hand the water back to the game.

## Cost

Measured at 1920x1080 on a mid-range desktop GPU, paused frame, Off and Bold alternated: Bold adds about 1.5 ms of
frame GPU time over Off. About 1 ms of that is the post-FX stack (ambient occlusion 0.34 ms, light and atmosphere
0.41 ms, SMAA 0.12 ms, sharpening 0.06 ms, lens 0.04 ms); the rest is the lighting, shadows and water. Ultra, with its
3840x2160 scene, adds about 6.9 ms over Off.

Worm skin and hair cost nothing measurable at the game's own camera. Close up they add about 0.1 to 0.4 ms of frame GPU
time at Ultra (a face a third of the screen high: +0.1 to +0.4 ms; two worms large on screen: +0.24 to +0.35 ms; tone
against Game alternated, on an RX 7800 XT).
With a tone or Mixed hair the script sends a worm's position and facing only when it moves or turns, and reads the
worms every frame only while one moves; its CPU time per frame did not change measurably.

## Client-only

`"kind": "client-only"` in `spice.json`. Mirage only touches GL state and shaders; no sim data, Tweak or
CRC-listed file is touched by any of the above.

## Known limits

- Worms and props cast shadows but do not receive them; that needs Melange to hand them the shadow map.
- Sunlit sand on Building and Wild West reads a little yellower than the game's own, and on Pirate a little redder.
- After an upgrade from 1.7 the *Mirage/Post-FX* panel can still list the retired fog, sky, bloom and grade effects
  as failed, and after an upgrade from 2.1 the retired post-FX skin (`sunstone/skin`). They are switched off and do
  nothing.
