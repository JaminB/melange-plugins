# Post-FX preview harness (dev tool, not packed)

(The lit-model shader and its material detail have their own preview, `model.mjs`: see "Model preview" at the end.)

Runs real Melange post-FX effect folders from this repo offline, in headless Chromium (WebGL2 on SwiftShader via
Playwright), on a synthetic WUM-like scene or on a real game frame. Use it to preview and screenshot effects such as
`bloodsand/skin` and `kindjal/acid` together, in Melange's order, without the game. (Sunstone's Worm skin and hair are
drawn by its model shader since 2.2, not by a post-FX effect, so the preview cannot run them; a worm's `tone` draws its
skin as that model shader would leave it for the post-FX: in the tone's albedo and marked in the scene's alpha.)

```sh
cd plugins/sunstone
node tools/preview/run.mjs --scenario tools/preview/scenarios/human-skin.json \
  --effects ../bloodsand/mod/postfx/skin,../kindjal/mod/postfx/acid --out /tmp/shots/x.png --compare --diff --stages
```

| Option | Meaning |
|---|---|
| `--scenario f.json` | scene description (below) |
| `--effects a,b,…` | effect folders (`…/mod/postfx/<effect>`), relative to the cwd, `plugins/sunstone` or `plugins/`. A missing folder is skipped with a warning. |
| `--out x.png` | frame after all effects |
| `--compare` | `x.compare.png`: input and output side by side |
| `--diff [--gain 4]` | `x.diff.png`: changed pixels amplified, unchanged pixels dark grey (shows exactly what an effect touched) |
| `--stages` | `x.scene.png`, `x.depth.png`, then one PNG after each effect and each full-size intermediate pass |
| `--param id:name=v1,v2` | override a parameter (repeatable), e.g. `--param bloodsand/skin:strength=0.5` |
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
afro + brown moustache worms with blood, wounds and black eyes near the mouth; the hair scenarios were made for the
post-FX hair of Sunstone 2.1 and now only show the scene). Human skin: `human-skin.json` (fair, deep and medium worms
with Bloodsand's blood, wounds, black eyes and belly and Kindjal's acid, on Sunstone's marked skin). Mouths: `mouths.json` (closed, small o,
shout, grin with teeth, shout with teeth + moustache), `mouth-closeup.json` (one worm filling the frame with an open
mouth), `mouth-bloodied.json` (mouths with blood and wounds, and vomit).

```jsonc
{
  "size": [960, 540], "renderScale": 1,        // renderScale 2 renders the scene at 2x and sets mg_renderScale
  "seed": 417,                                  // match seed pushed to effects that have p_seed
  "ground": "sand",                             // sand | grass
  "sunstone": true,                             // tells drivers Sunstone runs (Kindjal's compat = 1)
  "sunskin": 3, "sunskinAcid": 2,               // optional: how Bloodsand / Kindjal find the skin (their p_sunskin);
                                                // default 3 / 2 when a worm has a tone (colour test or mark), else 0 (colour)
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
    "tone": "deep",                              // Sunstone's Worm skin: fair|light|medium|olive|tan|brown|deep|[r,g,b];
                                                 // the skin takes that albedo and Sunstone's mark (scene alpha 245/255)
    "alive": true                                // anything else is passed to drivers untouched
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
- Both also send `tone0..3`: each slot's skin brightness against the game's peach (0.703), from the worm's `tone`
  (1 without one), as Sunstone's event `mod.sunstone.skin` gives it to their Lua.

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

# Model preview (`model.mjs`)

Renders Sunstone's lit-model shader (`FixedFunction.FFFragmentMainTexLit.glsl`, or `--shader texlitcol`) offline on a
box, sphere or plane with a texture from the texture inventory, three ways side by side:

| panel | shader | what |
|---|---|---|
| `game` | baseline, `sunstoneLight 0` | the game's own lighting |
| `sunstone` | baseline, `sunstoneMatDetail 0` | Sunstone's lighting without material detail |
| `candidate` | built now from `tools/materials` | with material detail (the Quality preset's amount, or `--detail`) |

The baseline is the committed shader (or `--baseline file.glsl`). The candidate comes from
`python tools/build_materials.py --out <tmp>` and the texture's tag from `python tools/make_tag_table.py` into a temp
folder, so edits to a snippet, its `@default` line or the overrides show at once and nothing in the plugin is
written. Uniforms are params.ini's defaults with what `applyLighting`/`applySkin` in `mod/client/init.lua` send for
the Quality preset and theme (`PRESETS`, `THEMES` read from the Lua source); the game's own light colours are
representative constants (`--diffuse`, `--ambient`, `--specular`).

The inventory (`inventory.json`, `classes.json`, `cache/<id>.png`) is read at run time and never committed: pass
`--inventory <dir>` or set `SUNSTONE_INVENTORY`. Playwright: `PLAYWRIGHT=<path to the playwright package>` if it is
not on the module path (as for `run.mjs`). One run takes 5 to 20 s.

```sh
node tools/preview/model.mjs --id ee3d95 --shape box --theme ENGLAND --out /tmp/crate.png      # crate
node tools/preview/model.mjs --sheet ee3d95,548ff2,944413 --out /tmp/sheet.png                  # contact sheet
node tools/preview/model.mjs --sheet class:painted_metal --limit 16 --px 200 --out /tmp/pm.png  # a whole class
node tools/preview/model.mjs --id 944413 --set-candidate sunstoneMatDebug=1 --panels sunstone,candidate --out /tmp/d.png
git show HEAD:plugins/sunstone/mod/shaders/FixedFunction.FFFragmentMainTexLit.glsl > /tmp/old.glsl
node tools/preview/model.mjs --sheet ee3d95,548ff2,944413 --baseline /tmp/old.glsl --check-identical
```

| Option | Meaning |
|---|---|
| `--id x` / `--sheet a,b,…` / `--sheet @file` / `--sheet class:<name>` | one texture, or a contact sheet (a row per texture); ids may be unique prefixes; `class:` takes the class from the tag table; `--limit n` |
| `--shape box\|sphere\|plane`, `--world 20` | the object and its size in world units (a crate is about 20, a worm's head 12) |
| `--density t` | texel density: texels per world unit (default: the texture once per box face) |
| `--dist d`, `--yaw`, `--pitch`, `--fov`, `--px` | camera distance (default 2.6 × size), angles (32°, 22°), field of view (40°), panel size (320) |
| `--quality off\|low\|subtle\|bold\|ultra`, `--theme ARABIAN\|…` | the preset and theme whose model parameters and sun direction are used (default Bold, no theme) |
| `--sun x,y,z`, `--diffuse r,g,b`, `--ambient r,g,b`, `--specular r,g,b` | override the sun direction (world, toward the sun) and the game's light colours |
| `--panels game,sunstone,candidate` | which panels, in order |
| `--detail k` | the candidate's `sunstoneMatDetail` (default the preset's, 1 on Low/Off) |
| `--set "name=v;name=r g b"`, `--set-candidate …` | uniform overrides for every panel / the candidate only (e.g. `sunstoneMatDebug=1`) |
| `--class name`, `--tag c,s,st,r,w,t,a,b`, `--untagged`, `--tags file.json` | force a class (its defaults), a raw tag, no tag (the material fallback), or a `--by-id` table from `make_tag_table.py` |
| `--candidate f.glsl`, `--baseline f.glsl` | shaders to use instead of the built / committed ones |
| `--maps f.png`, `--no-maps` | the shared material maps bound to every `sampler2DArray` (unit 8, a `TEXTURE_2D_ARRAY` with Melange's plain-average mips, repeat, anisotropy 16; default `mod/assets/detail/materials.png`, one square layer per tile of the strip), or none: a neutral 1x1 (0.502), as Melange's sampler reads before a texture is bound |
| `--check-identical [--expect-untouched]` | proves detail off changes nothing: baseline vs candidate with detail 0, with detail on behind `sunstoneMatSplit`, and under the game's lighting, compared byte for byte; `--expect-untouched` adds detail on everywhere (for the worm's own material, skin and hair). Exit 1 on any difference |
| `--time` | SwiftShader ms per draw (CPU: compare panels, not a GPU budget) |
| `--no-labels`, `--out x.png` | |

Gaps: SwiftShader is not the game's GPU (precision and derivatives agree closely; timing does not), the meshes are
simple shapes with one texture density, and the light colours are not the theme's own. Measure the 0.5 ms budget in
the game (see the README's performance section).
