## 1.1.0

Grade and anti-aliasing (L2) and atmosphere (L3), all as Mirage Post-FX effects under `mod/postfx/`, off by
default: SMAA 1x and AMD CAS sharpening at the Final stage (both MIT, licences included); a filmic curve with a
two-look colour-grading LUT blend, vignette and grain at PostWorld; SSAO rewritten to fix sky artefacts (sky mask,
distance falloff, edge-aware normals, bilateral blur), an analytic sky gradient and sun glow, height/distance fog
with sun-tinted in-scatter, and bloom. A `quality` setting (Off/Low/Medium/High) and a `look` setting
(Golden/Dusk) drive sensible per-effect defaults live; every effect keeps its own ini/overlay toggle underneath.

## 1.0.0

Texture clarity (L1): 16x anisotropic filtering and trilinear minification filtering, applied at the engine's own
texture uploads. Client-only; vanilla filtering is unchanged unless this mod is enabled or `Melange.ini`'s
`[MirageTextures]` overrides it.
