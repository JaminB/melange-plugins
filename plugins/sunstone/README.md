# Sunstone

A client-only graphics overhaul for Worms Ultimate Mayhem, built from Mirage and the engine's own switches.
Shaders, code and original or permissively licensed art only — no game texture, or anything derived from one, is
ever shipped.

## Quality and look

A **Quality** setting (Off / Low / Subtle / Bold / Ultra) on the Mods page turns Sunstone's effects on together with
sensible parameters; a **Look** setting (Golden / Dusk) picks which of the two colour-grading LUTs the grade
leans toward, **Sunstone lighting** and **Sunstone water** turn the lighting and the water below on or off on their
own, **Distance blur**, **Film grain** and **Lens effects** (dirt, flare and colour fringes) turn those off, and
**Worm skin** gives the worms human skin (below). All apply live, no restart. Every effect still has its own toggle
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

The **Worm skin** setting (Game / Fair / Medium / Olive / Deep / Mixed; default Game) re-renders the worms' skin as
human skin. Game keeps the game's cartoon peach and the effect stays off. A tone gives every worm that skin, with a few
percent of variation per worm; Mixed gives each worm one of seven tones (fair, light, medium, olive, tan, brown, deep),
picked from its name, so a worm keeps its tone from match to match. Quality Off also turns it off.

It is a Post-FX effect, **`skin`** (PostWorld, order 55), driven every frame by `mod/client/init.lua`: each living worm's
body centre, albedo, heading and how far it moved since the last game tick. It works in screen space:

- **Finding the skin.** A pixel is a worm's skin when it lies on the surface of that worm's body (the same ellipsoid,
  capsule shell, upright and facing tests and the same depth-gap test against the background that Bloodsand and
  Kindjal use) and has the colour of the game's skin (the same classifier: Bloodsand's measured window of hue,
  saturation and channel ratios, with Kindjal's lower hue limit that cuts blood and its widening for Sunstone's tinted
  shade while Sunstone's lighting is on). Hats, helmets, glasses, the eyes and moustaches fall outside it, a little
  more strictly above the eye line and round the mouth; above the eye line, where a hat is, the hue and saturation
  limits are Bloodsand's own, without Kindjal's widening (a sunlit cowboy hat's brown reaches into it).
- **The new skin.** The light on each pixel is read as if it were bare game skin (its colour over the game's peach,
  per channel) and put on the new albedo, so the shading, the game's skin texture and Sunstone's sun and shade come
  through. Most of the light's colour is kept; a real face in cold shade stays warmer than a peach, so part of the cold
  tint is let go (only where there is light enough to read, so a dark blend keeps its own colour). Measured skin
  albedos (sRGB: fair 0.94/0.80/0.71, light 0.88/0.70/0.58, medium 0.78/0.57/0.42, olive 0.70/0.53/0.36, tan
  0.62/0.44/0.30, brown 0.45/0.30/0.20, deep 0.30/0.19/0.13), all redder than the sand; a deep tone is darker than the
  peach, softened so it keeps its shading in the shade.
- **Realism.** Subsurface scattering: along the terminator (found from the body's shape and the theme's sun) the
  falloff is softened and turns red-orange, shade is a deeper, warmer, saturated colour, never grey, and a silhouette
  against the sun glows red as an ear does. A visible but soft sheen toward the theme's sun: a broad lobe and a tighter
  core, stronger on the oily forehead and nose (then the cheeks), rising toward grazing angles and broken up by the
  pores and skin lines, plus a soft grazing sheen; from across the level the core spreads into the broad lobe. Melanin
  and blood under the skin work as absorbers (more melanin is browner and darker, more blood redder, never green):
  broad blotches and patches that read from across the level, a mottle of about a unit, freckles, a flush on the
  cheeks and the nose, redder and slightly darker lips under the snout. Close up, a fine relief (shallow skin lines
  round the body, a finer crosshatch, pores and grain) is lit from the sun as a bump on the smooth body normal, softer
  and warmer in the red as light under the skin blurs it, with its hollows a little darker. Every band fades in only
  where the screen gives it a few pixels (it never shimmers). The pattern lives in the worm's own frame, so it moves
  and turns with the worm and never swims across the screen. Bright skin rolls toward white instead of clipping one
  channel.

The *Mirage/Post-FX* panel lists it as *Human skin*, with sliders for the opacity, how much of the light's colour is
kept, subsurface warmth, sheen, pores and mottling.

**With Bloodsand and Kindjal.** Bloodsand's skin (order 51), guts (52) and gibs (53) and Kindjal's acid (54) find the
skin by its peach colour too. Sunstone's skin runs after all of them, so they classify and paint the game's skin exactly
as before and need no change, and it then recolours only what is still skin, before Sunstone's occlusion (100) and grade
(300), which treat the new skin like the rest of the scene. The classifier gives a soft likelihood, not a hard mask, and
the recolouring is a continuous function of the colour (in effect a gain per channel): full blood, raw wounds, the
charred crust, intestines and acid are not skin and keep their colours; a thin wipe of blood is a blend of red and peach
and comes out as red on the new tone, darker on a deep one; and a pixel on the rim of any of them takes the recolouring
up to the skin beside it, so no peach rim is left. What Bloodsand paints by multiplying the skin (the scorch's singed
halo and cooked leather) takes the skin's gain per channel; its charred crust passes through as painted. Its black eye
is not kept as a purple-black paint: inside the bruise's oval round the eyes, Sunstone reads from it where the bruise
is and how heavy (the share of bruise colour within about a unit and a half, and how much darker than the skin round it
it was painted), then draws the skin again under it with a bruise filter: a faint yellow fringe, a red-purple, and a
deep blue-purple at its heaviest, softened into the skin round it, so a black eye is a bruise on that tone (a dark
brown-purple on a deep one, never a black mask), heavier from across the level so it still reads. The eye whites,
pupils and blood beside it are untouched. Blood and Kindjal's acid take a wet highlight from the sun, and the acid's
pattern is smoothed over about two thirds of a unit so its noise lattice does not show as squares. Kindjal reads any
enabled `sunstone/*` effect as Sunstone being on; the skin effect is off with Quality Off, so that stays right.

**Limits.** It recolours what the camera sees as skin, so it cannot add what the model does not have (lips, nails,
hair). Skin the game lights to a colour outside the classifier's window (an unusual theme light, very dark caves) stays
peach there. While a worm flies fast its body can be a few units from the reported position; the test widens with its
speed, but at the edge of a very fast worm a rim of peach can flash for a frame. A purple hat or headband inside the
bruise's oval round the eyes is redrawn as bruised skin, as a black eye is. Bloodsand's own skin pass can leave a thin
line of unpainted peach down the middle of a worm that fills a large screen (its depth-gap test); Sunstone's skin
recolours that line like the skin round it, and inside a black eye bruises it with its neighbours. Cost: a pixel away from every worm is two fetches and a
sphere test per worm; only pixels on a worm's surface do more.

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

## Client-only

`"kind": "client-only"` in `spice.json`. Mirage only touches GL state and shaders; no sim data, Tweak or
CRC-listed file is touched by any of the above.

## Known limits

- Worms and props cast shadows but do not receive them; that needs Melange to hand them the shadow map.
- Sunlit sand on Building and Wild West reads a little yellower than the game's own, and on Pirate a little redder.
- After an upgrade from 1.7 the *Mirage/Post-FX* panel can still list the retired fog, sky, bloom and grade effects
  as failed. They are switched off and do nothing.
