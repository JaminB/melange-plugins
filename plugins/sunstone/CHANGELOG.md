## 1.6.0

- A new default **Bold** quality: a clearly visible remastered look at normal camera distance. Harder sun and deeper
  shadows (4096² map), a strong rim light on worms and props, richer sky/ground ambient, clear SSAO contact shading,
  a confident filmic grade with vibrance and local contrast, aerial perspective that gives distant islands depth
  while leaving the sea alone, brighter bloom on highlights and glints. Quality is now Off / Low / Subtle / Bold;
  **Subtle** keeps the near-neutral look of 1.5, and settings saved as Medium or High read as Bold.
- Sand keeps the game's pale yellow: bright colours roll off toward white instead of turning orange, the grade
  leaves bright warm colours at their own chroma, and shadows no longer over-saturate.
- Horror is no longer darker than the game: its own exposure, contrast and neutral ambient in the theme table.
- Water is built on the game's own water terms, so every theme keeps its colour (Horror's murky sea no longer turns
  pale) and the game's white wave glints are back, with a sharper sun sparkle. Flecks are smaller and rarer on pale
  water, the reflected sky takes on the water's hue, and a slow rotated swell hides the far-sea tiling.
- `sunstoneSplit` on the water shows the game's own water left of a screen x, so a whole frame can be compared.
- Measured at 1920x1080 on an RX 7800 XT: the Bold post-FX stack costs about 0.7 ms.

## 1.5.0

- Water: a new GLSL water shader. The scene below shows through shallow water with refraction and depth-based
  absorption, so beaches get turquoise shallows that deepen to the theme's own water colour; a Fresnel blend
  reflects the game's own sky; the sun leaves a glint path; ripple crests catch bright flecks; and broken foam
  lines the shore. Wave layers fade out where their texels shrink below a pixel, so distant water no longer
  shimmers. The water colour comes from each theme's own water texture at run time, so every theme keeps its look.
- A **Sunstone water** setting turns it off on its own; Off hands the water back to the game.
- Seen from above, the water keeps the swell's shape and no longer shows large pale streaks.
- The far sea no longer ends in a darker band under the horizon: the haze and the grade now fade out on the way to
  the sky's distance instead of stopping there.
- Needs a Melange 0.3 build that gives GLSL replacements the scene's depth and colour (`mg_depth`, `mg_scene`).

## 1.4.0

- Lighting: new GLSL lighting for the landscape and for lit models (worms, props, weapons). Ambient light now comes
  from a sky/ground hemisphere tinted per theme, specular is energy-conserving Blinn-Phong (a sheen on helmets and
  barrels, a faint one on terrain), a sun-side rim lights back-lit edges, and terrain gets fine relief from its
  texture (faded out where the texture is magnified, so close-ups show no texel grid). Bright colours roll off
  instead of clipping to pale yellow. A per-theme material table in `client/init.lua` sets reflectance, gloss,
  relief depth and the hemisphere tints.
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
