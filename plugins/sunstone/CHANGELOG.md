## 1.4.0

- Lighting: new GLSL lighting for the landscape and for lit models (worms, props, weapons). Ambient light now comes
  from a sky/ground hemisphere tinted per theme, specular is energy-conserving Blinn-Phong (a sheen on helmets and
  barrels, a faint one on terrain), a sun-side rim lights back-lit edges, and terrain gets fine relief from its
  texture. Bright colours roll off instead of clipping to pale yellow. A per-theme material table in
  `client/init.lua` sets reflectance, gloss, relief depth and the hemisphere tints.
- A **Lighting** setting turns it off on its own; Low drops the relief, Off hands every program back to the game.
- Needs a Melange 0.3 build with `wum.shaders.enableGlsl`; on older builds Off keeps Sunstone's shaders with the
  game's own lighting terms.

## 1.3.0

- Soft shadows: a 2048² shadow map (4096² on High) instead of the game's 1024², and GLSL landscape shaders with a
  smooth soft filter (Low) or contact-hardening shadows (Medium, High). A slope-scaled bias removes the game's
  shadow acne on grazing slopes. Without Melange's shadow support the game's own shadows are kept.
- The grade no longer touches the sky dome, so pale skies stay clean instead of turning milky and teal.
- SSAO fades out close to the camera and keeps its radius within what fits on screen, so low cameras over sand
  slopes no longer get dark smears.
- SMAA and sharpening run on the world only, before the HUD, so menus, labels and HUD text are left untouched.

## 1.2.0

Atmosphere reworked against measured scene scale (a worm is about 30 units tall, the sky dome about 9400 away):

- The sky is now found by distance rather than a depth threshold, which removes the hard polygon seam across the
  menu sky and stops fog and SSAO treating the dome as geometry.
- Fog is now aerial perspective: distant geometry fades a little toward the sky's own horizon colour, read from
  the frame, with height-aware density and a cap, so water stays water.
- SSAO now produces contact shadows: radius and fade distance in world units, and normals that face the camera.
- Bloom thresholds on luminance at quarter resolution with a wider, two-width glow and a screen blend; the sky
  counts for less.
- Grain is gone. The grade's filmic curve runs on luminance, blue and purple pixels keep their hue, and the warm
  LUT is skipped on the Lunar and Horror themes.
- Sky glow is off in every preset. Low no longer turns on fog or sky glow.
- Needs Melange 0.3.

## 1.1.0

Grade and anti-aliasing and atmosphere, all as Mirage Post-FX effects under `mod/postfx/`, off by
default: SMAA 1x and AMD CAS sharpening at the Final stage (both MIT, licences included); a filmic curve with a
two-look colour-grading LUT blend, vignette and grain at PostWorld; SSAO rewritten to fix sky artefacts (sky mask,
distance falloff, edge-aware normals, bilateral blur), an analytic sky gradient and sun glow, height/distance fog
with sun-tinted in-scatter, and bloom. A `quality` setting (Off/Low/Medium/High) and a `look` setting
(Golden/Dusk) drive sensible per-effect defaults live; every effect keeps its own ini/overlay toggle underneath.

## 1.0.0

Texture clarity: 16x anisotropic filtering and trilinear minification filtering, applied at the engine's own
texture uploads. Client-only; vanilla filtering is unchanged unless this mod is enabled or `Melange.ini`'s
`[MirageTextures]` overrides it.
