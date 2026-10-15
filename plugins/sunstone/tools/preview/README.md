# Post-FX preview harness (dev tool, not packed)

Runs real Melange post-FX effect folders from this repo offline, in headless Chromium (WebGL2 on SwiftShader via
Playwright), on a synthetic WUM-like scene or on a real game frame. Use it to preview and screenshot effects such as
`bloodsand/skin`, `kindjal/acid` and `sunstone/skin` together, in Melange's order, without the game.

```sh
cd plugins/sunstone
node tools/preview/run.mjs --scenario tools/preview/scenarios/bloodied.json \
  --effects ../bloodsand/mod/postfx/skin,mod/postfx/skin --out /tmp/shots/x.png --compare --diff --stages
```

| Option | Meaning |
|---|---|
| `--scenario f.json` | scene description (below) |
| `--effects a,b,…` | effect folders (`…/mod/postfx/<effect>`), relative to the cwd, `plugins/sunstone` or `plugins/`. A missing folder is skipped with a warning. |
| `--out x.png` | frame after all effects |
| `--compare` | `x.compare.png`: input and output side by side |
| `--diff [--gain 4]` | `x.diff.png`: changed pixels amplified, unchanged pixels dark grey (shows exactly what an effect touched) |
| `--stages` | `x.scene.png`, `x.depth.png`, then one PNG after each effect and each full-size intermediate pass |
| `--param id:name=v1,v2` | override a parameter (repeatable), e.g. `--param sunstone/skin:tone=2` |
| `--size WxH`, `--keep-order`, `--probe x,y` | size override; run in the given order instead of Melange's; print input/output RGB of a pixel |

Exit code 1 when an effect failed to compile or link (the others still run, as in Melange). Compile errors are mapped
back to `file:line` of the effect's own sources (includes expanded).

Requirements: Node 18+, the `playwright` package (found in `node_modules`, `/opt/node-tools/node_modules` or
`/opt/node22/lib/node_modules`) and its Chromium. Set `PREVIEW_CHROMIUM` to a Chromium binary if the pinned one is
missing. One render takes about 3 s.

## Scenarios

`scenarios/clean.json` (three clean worms), `bloodied.json` (the middle worm: heavy blood, wounds, black eyes),
`closeup.json` (one worm filling the frame, moderate blood), `duel.json` (two worms on grass, light blood),
`frame-example.json` (mode b template). Hair: `hair.json` (seven worms: cowboy hat + brown moustache control, orange
moustache, brown moustache, dark-brown mop wig + brown handlebar, black afro, ginger mohawk, helmet control),
`hair-closeup.json` (brown mop wig + brown moustache filling the frame; the preview's `brown` is at the cowboy hat's
hue, so Hair hats leaves this wig alone by design), `hair-closeup-wigs.json` (the same with a dark-brown wig, Hair hats
on, 1920x1080: the wig is treated close up as at gameplay distance), `hair-bloodied.json` (orange moustache and
afro + brown moustache worms with blood, wounds and black eyes near the mouth). Mouths: `mouths.json` (closed, small o,
shout, grin with teeth, shout with teeth + moustache), `mouth-closeup.json` (one worm filling the frame with an open
mouth), `mouth-bloodied.json` (mouths with blood and wounds, and vomit).

```jsonc
{
  "size": [960, 540], "renderScale": 1,        // renderScale 2 renders the scene at 2x and sets mg_renderScale
  "seed": 417,                                  // match seed pushed to effects that have p_seed
  "ground": "sand",                             // sand | grass
  "sunstone": true,                             // tells drivers Sunstone runs (Kindjal's compat = 1)
  "camera": { "pos": [10, 38, 135], "target": [0, 13, 0], "fov": 40, "near": 2, "far": 4000 },
  "lighting": { "sunDir": [...], "sunCol": [...], "ambient": [...], "skyTop": [...], "skyHorizon": [...],
                "groundColour": [...], "groundNoise": 0.12 },
  "worms": [{
    "slot": 1, "pos": [0, 0, 4], "yawDeg": -8,   // feet position (game units, Y up); facing (sin yaw, 0, cos yaw)
    "hat": "none", "skin": "peach",              // hat: none|cowboy|helmet|beanie|afro|mohawk|wig; skin: peach|warm|pale|[r,g,b]
    "hairColour": "black",                       // afro/mohawk/wig: black|darkbrown|brown|blond|ginger|auburn|grey|orange|[r,g,b]
    "tash": "brown", "tashShape": "walrus",      // moustache colour none|orange|brown|black|… ; shape walrus|handlebar
    "mouth": { "open": 0.6, "shape": "o", "teeth": false, "lip": [r,g,b] },   // opt-in; open 0 = closed (lips + seam), shape o|wide|grin; no field = no mouth
    "vomit": 0,                                  // 0..1 Bloodsand vomit droplets from the mouth; needs "mouth"
    "hairStreak": 0.3,                           // strand streaks in hair/moustache albedo (multiplicative, keeps hue)
    "blood": 0.9, "hitFromDeg": 200, "wound": 0.75, "eye": 0.8, "gut": 0, "gutAz": 0, "scorch": 0,   // Bloodsand
    "acid": 0, "acidSpread": 1,                  // Kindjal
    "alive": true, "tone": "…"                    // anything else is passed to drivers untouched
  }],
  "params": { "bloodsand/skin": { "strength": 1 } }   // per-effect overrides after the driver
}
```

The worms follow what Bloodsand and Kindjal assume: body centre 12 units above the feet (`CENTRE_Y`), an upright
capsule of radius 5.6 straight from −8 to +8 around it, eyes 2.3 to each side and about 3.8 up on the front, all inside
the 9.5 × 16 body ellipsoid. Vanilla peach skin is `(0.98, 0.64, 0.36)`: lit, it lands at hue 21–28°, g/r 0.58–0.65,
b/r 0.31–0.36, which Bloodsand's `SkinTone()` scores 1.0; the cowboy hat (hue ~36°, sat 0.66), the helmet, eyes and
pupils score 0, and sunlit sand scores 1 (as in the game), so the effects' geometric tests are exercised.

Hair (not measured from the game: WORMATTACHMENTS.XOM and the hat meshes are not in the repo; only an Afro is
attested, by a custom team flag name). Moustaches sit under the snout (y ~−2.6..−0.6, z ~5–6.4, inside Bloodsand's mouth
zone). `orange` lands at hue ~25°, saturation 0.80–0.81 and `brown` at g/r 0.75–0.78, b/r 0.47–0.50, max < 0.5 after the
harness light: inside Bloodsand's `MoustTone()` windows (orange = skin hue above SkinTone's 0.76 saturation limit; brown
= SkinTone's `hole`). `black` and the wig colours are not classified by Bloodsand; note `blond` falls inside SkinTone and
`ginger` inside the orange-moustache window, which is what a real blond or ginger wig would do too. Headwear: afro
(curly dome to y ~18.5, back down to y 3.5, fringe above the eyes), mohawk (crest x ±1.5 from y 10 to ~21), mop wig
(bowl cut, 0.75 outside the head, long at the back/sides). They exceed Sunstone skin's Pick shell (rl ≤ 8.1, reach 17).
The harness eye line is y 3.8 (Bloodsand/Sunstone measure EYE_Y = 2.0 in game), kept so older scenarios are unchanged.

### Mode (b): a real frame without depth

Set `"image": "frame.png"` (relative to the scenario) and give every worm `"box": [x0, y0, x1, y1]` in image pixels
(top-left origin) around its whole body. The camera sits at the origin looking down −Z (`mg_view` = identity), each
worm's body is an upright capsule at the distance where 30 units fill its box height (radius from the box width,
4–7.5), and everything else is a backdrop 80 units behind the farthest worm (never sky). The colours are the real
frame's, so colour classifiers are tested for real, but the geometry is approximate: a capsule is not the worm's
silhouette (no head, eyes or hat in the depth), normals are a capsule's, and pixels of the worm outside the capsule get
no effect. Use it for classifier checks on real colours, not for judging shading.

## Drivers (what each mod's Lua would push)

`drivers/<modid>.<effect>.mjs` (an `_u` variant falls back to the base name) exports
`default ({ scenario, worms, effect, params, mode, wrapPi, CENTRE_Y }) => { paramName: value | [values] }`. Each worm has
`slot, pos, centre, yaw, heading (wrapped to ±π), hitBin, radius` plus every scenario field. Shipped:

- `bloodsand.skin.mjs`: `wormN` centre, `wormNb = (blood + 2·hitBin, wound, heading)`, `wormNc = (eye, gut, gutAz)`,
  `scorch0..3`, `seed`; like the Lua, a worm with nothing to paint is not driven.
- `kindjal.acid.mjs`: `wormN`, `level0..3`, `spread0..3`, `seed`, `compat`.
- `sunstone.skin.mjs`: `wormN` centre, `wormNb` the worm's `tone` (a name, fair to deep as in Sunstone's Lua, or
  `[r,g,b]`; default medium), `wormNc = (heading, seed, 0)`, `sunDir` (the scenario's, normalised), `compat`. Hair, only
  where `effect.ini` declares it: scenario `"hair": "game"|"natural"|"mixed"` → `hair`/`hairMode` 0/1/2, per worm
  `hairD` → `wormNd`; scenario `hairParams: {name: v}` are passed as is.

An effect with no driver but a `worm0` parameter gets the generic driver (`wormN` = body centre of every living worm)
and a warning. Parameters a driver sets that `effect.ini` does not declare are ignored with a warning; uniforms
`p_<name>` with no `[param.<name>]` are reported.

## What is emulated, and the gaps

Emulated as documented in Melange's developer guide (Post-processing effects): `effect.ini` (`[effect]` stage/order,
`[param.*]` defaults by type, `[texture.*]` file/filter/wrap with v = 0 at the PNG's top row, `[pass.*]` shader, scale,
format rgba8/rgba16f/r8/rg8, defines, inputs); effects sorted by stage (PostWorld, Final), order, then id; the last pass
of an effect written at scene size in rgba8 and becoming the scene for the next effect; `mg_prev` (previous pass, or the
scene), `mg_scene`, `mg_depth`, `mg_pass_<name>`, `t_<name>`; `mg_uv` (origin bottom-left), `mg_resolution` (this pass's
target), `mg_sceneResolution`, `mg_renderScale`, `mg_time`, `mg_frame`, `mg_proj`, `mg_invProj`, `mg_view`
(world → view, camera looking down −Z, Y up), `mg_nearFar`; `#include "file"`; `#version` (default 120). A sampler used
but not listed in `inputs=` is bound anyway with a warning (Melange would not bind it).

Gaps:

- **GLSL dialect.** Shaders are translated to GLSL ES 3.00 (`texture2D` → `texture`, `varying mg_uv` → `in`,
  `gl_FragColor` → an `out`), which is stricter than desktop GLSL 1.20: implicit int → float conversions (`float a = 1;`)
  fail here although most desktop drivers accept them. Treat that failure as a portability bug worth fixing anyway.
  Desktop-only built-ins (e.g. `gl_FragCoord` works, `gl_TexCoord`, `ftransform` do not) are not provided.
- **Driver behaviour.** SwiftShader is not the player's GPU: precision and the "links then draws nothing" failure of large
  shaders on some drivers are not reproduced, and timings are CPU timings, not `gpuMs`.
- **Depth.** `mg_depth` is a float32 texture (OpenGL [0,1], 1 = sky, NEAREST) rather than the game's 24-bit buffer.
  Scene and pass textures are sampled LINEAR/CLAMP; Melange's own filtering is not documented.
- **The scene.** Smooth ray-marched shapes, not the game's low-poly faceted mesh (so depth-buffer normals are smoother
  than in game; where the skin meets a moustache each side is shaded with its own surface's normal, as the game's
  separate meshes are, so no lit crease line is drawn there); no worm animation, labels, HUD, water, particles or the game's own FXAA/sepia after Final; lighting is
  a simple sun + ambient + soft shadow, not the game's or Sunstone's lit-model shaders (the sun/shade tints that
  Sunstone's FF*Lit* shaders put on worms are not reproduced; set `lighting` to approximate them).
- **Lua.** Only what the drivers model is pushed; effects whose Lua sets other parameters (Sunstone's sun position,
  theme LUTs, exposure) run on their `effect.ini` defaults unless a scenario's `params` sets them. Single frame: no
  `mg_prev` history across frames, `mg_time`/`mg_frame` from the scenario.
- **Mode (b)** is approximate (see above).
