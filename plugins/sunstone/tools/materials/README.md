# Material library (dev, not packed)

Sunstone 2.3's material detail: procedural surface detail per material class, drawn by the lit textured model
shaders (`mod/shaders/FixedFunction.FFFragmentMainTexLit.glsl` and `...TexLitCol.glsl`). Every texture belongs to one
of 26 classes; Melange's texture tags tell the shader which class and parameters the bound texture has. Nothing here
is derived from a game texture: snippets are original code, and the tag table holds only digests and numbers.

| File | Owner | What |
|---|---|---|
| `classes.json` | library | class ids (the tag format: never renumber), the fallback classes |
| `_common.glsl` | library | `MatIn`, `MatOut`, helpers, `MatSetup` |
| `_evaluate.glsl` | library | the tag, the switches, the blend, the debug views |
| `generic.glsl` | library | the default for classes without a snippet and for untagged matte textures |
| `<class>.glsl` | one class worker each | `MatOut mat_<class>(MatIn m)` |
| `overrides/<class>.json` | that class's worker | per-texture class or parameter overrides (layout as `overrides.json`) |
| `overrides.json` | library | cross-class fixes, and corrections of mistyped ids in the inventory's decisions |
| `../make_detail_maps.py` | library | the shared material maps, `mod/assets/detail/materials.png` (below) |

`tools/build_materials.py` splices `_common`, the snippets, a generated `MatDispatch` (an `if` chain on the class id)
and `_evaluate` between the `BEGIN/END MATERIALS` markers of both shaders, and sets their first line to `#version 130`
(the shared maps are a `sampler2DArray`; the game's Cg vertex programs, GLSL 1.10 writing `gl_TexCoord[]`, link with
it, and the shaders keep `gl_TexCoord[]`, `gl_FragColor` and `texture2D`, which 1.30 still has).
`tools/make_tag_table.py` writes `mod/texture_tags.json` from the inventory's class decisions, each snippet's
`@default` line and the overrides.

## Coverage: which textures have a row in the tag table

The table (`mod/texture_tags.json`) has a row for every texture that Melange can bind on the lit-model path:

- the **lit-model textures** (712): every `XShape`/`XSkinShape` of the bundles and the Kindjal meshes whose `XSimpleShader`
  has an `XMaterial` and `XLightingEnable`; decisions in the inventory's `classes.json` plus the overrides;
- the **landscape tiles** (949 more, `tools/materials/classes_extra.json` + `overrides/extra.json`): the game's
  `ThemeXxx\*.tga` and `Custom\BANK*` textures are not on any shape. Each is an `XBitmapDescriptor` (`ResourceId` `W01`)
  whose `SpriteScene` is an `XTexFont` (unlit, no material) holding the `XImage`; a level picks them by name
  (`Heightmap.BaseTexture`, `Heightmap.SecondTexture`, `Heightmap.Base.Texture`, e.g. `W01` in HighNoonHijinx, `A04` in
  GibbonTake) and the terrain/landscape draw binds them, so a scan of shapes never sees them (the original inventory
  missed ThemeWildwest W01 and W05 and ThemeArabian A04 for that reason). The 47 sky light ramps (256x1), the 123 UI
  sprites and the 283 textures of unlit, material-less shapes are deliberately left out.

The inventory pipeline (kept outside the repo, with `inventory.json` and `cache/`): `extract.py` (shapes) and
`extract_extra.py` (bitmap resources, unlit shapes, UI) write `raw.json` / `raw_extra.json`; `finalize.py` and
`finalize_extra.py` write `inventory.json` (the 712 first, the extras appended, ids stable) and `inventory_extra.json`.
`make_tag_table.py` reads both and the decisions of `classes.json` + `classes_extra.json`; a texture that is in the
inventory but decided nowhere is reported as "without a decision". New textures keep getting a class by hand: view
the `sheets_extra` contact sheets, add `{"id": <full id>, "cls": <class>}` rows to `classes_extra.json`.

## The tag

`uniform vec4 mg_texTag[2]`, sent by Melange per draw for the texture on unit 0:

| | x | y | z | w |
|---|---|---|---|---|
| `mg_texTag[0]` | class id (1..26) | `scale` (feature size multiplier) | `strength` (0..2) | `rough` (roughness bias −1..1) |
| `mg_texTag[1]` = `m.p` | `wear` (0..1) | `tint` (variation amount) | `a` (class parameter) | `b` (class parameter) |

Zero (an older Melange, or a texture not in the table): the class comes from `materialMatrix`, metal (gloss ≥ 30 and
specular ≥ 0.5, e.g. 0.75/40) → `bare_metal`, everything else → `generic`, with those snippets' defaults.

The dispatcher applies `strength`, `rough` (gloss × 2^−2r, specular × 2^−r), the fade and `sunstoneMatDetail` to what
a snippet returns, so a snippet returns its full-strength look.

## The snippet signature

```glsl
// @class wood_planks
// @default scale=1 strength=1 rough=0 wear=0.3 tint=1 a=0.18 b=0
// @param a: plank width in world units
// @param b: unused
MatOut mat_wood_planks(MatIn m) {
    MatOut o = MatNone(m.albedo);   // no change
    ...
    return o;
}
```

Inputs (`MatIn m`, all in eye space unless noted; a worm's head is about 12 world units across):

| field | meaning |
|---|---|
| `albedo`, `alpha` | the texel (the base albedo, before the leaf hue shift) |
| `uv`, `uvDx`, `uvDy`, `uvPx` | texture coordinate (GL_REPEAT space), its screen derivatives, the texture units one pixel covers |
| `uvPerWorld`, `pxWorld`, `aniso` | texel-density metric: texture units per world unit, world units per pixel, stretch (1 none) |
| `pos`, `wpos` | eye-space and world position (props move: prefer `uv`) |
| `n`, `gu`, `gv`, `tu`, `tv` | normal; the derivative-based cotangent frame (gradients and unit directions of u and v) |
| `v`, `l`, `up`, `ndl`, `ndv`, `sky` | light terms: to the eye, to the sun, world up, n·l, n·v, 0 ground..1 sky |
| `lumD` | screen derivatives of the texel's luminance (the art's own edges) |
| `scale`, `strength`, `p`, `seed`, `tagged` | the tag (above), 0..1 per-texture seed, 1 when Melange tagged it |
| `fade` | 0..1 distance, grazing and degenerate-mapping fade (applied by the dispatcher; use it to skip work). The last (`MatDegenerate`) is 0 where the UVs converge to a point, the texture is stretched over 8x or the density is extreme; and the dispatcher caps the normal tilt at 0.7 |

Outputs (`MatOut`): `albedo`; `spec` (specular scale) and `gloss` (exponent scale); `dn` (normal perturbation, added to
`n` before normalising); `ao` (cavity: all of the ambient, a third of the sun).

Helpers in `_common.glsl`: `MatHash12/22/32`; `MatGNoise(p, period)` gradient noise with its slope (period = the
frequency keeps a texture's wrap seamless); `MatFbm(m, uv, freq, octaves)` (each octave faded by its own footprint);
`MatOctave(m, sizeWorld, F0, blend)` (power-of-two frequency for features `sizeWorld` apart, blend two octaves so the
size never jumps between triangles); `MatFadeCells/Uv/World` (1 at four pixels a cell, 0 at the Nyquist limit);
`MatBumpUv(m, dh/duv)` and `MatBumpScreen(m, dh/dxy)`; `MatVary(c, amount, r)`; `MatLum`; and the shared material maps
(`MatMap`, `MatMapAt`, `MatMapWorld`, `MatMapFade`, ...; see "Shared material maps" below).

Rules (`build_materials.py` enforces the first three):

- No `dFdx`/`dFdy`/`fwidth` (a snippet may branch per fragment; use `uvDx`, `lumD`, `MatBumpScreen`), no uniforms,
  no output writes or `discard`.
- Every top-level name starts with `mat_<class>` or `MAT_<CLASS>`, so snippets never collide.
- Size detail in world units through `MatOctave` times `m.scale`, and fade every pattern by its footprint; nothing may
  shimmer at the game's distance.
- Keep the cartoon art: the texture's hue and value stay; detail is mostly light (normal, gloss, cavity), albedo
  changes small (a few percent), and broad flat areas of colour stay flat from afar.
- Budget: 0.5 ms GPU at Ultra for all of material detail together. Uniform branches cost nothing, but every snippet
  adds to the shader's size and register pressure: favour two or three noise calls over long fbm loops.

## Shared material maps

Besides the procedural helpers, every class can sample eight original tileable maps: `mod/assets/detail/materials.png`,
a 256x2048 vertical strip of 256x256 layers (layer 0 at the top). `tools/make_detail_maps.py` generates it from seeded
noise, with no game or third-party pixels; `--check` says whether the committed PNG is current, and `--preview x.png`
writes a contact sheet. `mod/client/init.lua` loads it once with `wum.draw.texture(..., {wrap = "repeat", layers = 8})`
and binds it to `uniform sampler2DArray sunstoneMat` with `wum.shaders.setTexture` (Melange 0.10; on a Melange without
it, material detail stays off). Melange gives it trilinear filtering, the anisotropy of the texture settings and a mip
chain built by plain averaging of the stored bytes.

Channels, the same in every layer. 0.5 is neutral in every channel, and that is also what Melange's sampler reads
before the texture is bound, so an unbound or faded map changes nothing:

| channel | meaning |
|---|---|
| R, G | tangent-space normal x, y: x along +u, y along +v (Melange puts the PNG's top row at v = 0); z is implied. Slopes are moderate (length of xy 0.3 to 0.55 at the 98th percentile), so the plainly averaged mips stay close to the true filtered normal. Averaging flattens the normal with distance, which is what we want |
| B | height: 0.5 the surface, below it cavities (pores, grooves, pits, chips), above it ridges |
| A | a variation about 0.5: roughness (+ rougher) or albedo (+ lighter), per layer below; on `wear`, the wear order |

| layer | constant | what | A | feature size (texels) | one tile, world units |
|---|---|---|---|---|---|
| 0 | `MAT_MAP_GRAIN` | fine grain, mottle and pores: plastic, paint, rubberised and skin-like matte | roughness | 3 | 4 to 8 |
| 1 | `MAT_MAP_WOOD` | wood grain along u: 11 rings a tile (with knot-like loops), latewood bands, long pores | albedo (latewood darker) | 6 | 30 to 60 along the grain (a plank of a 20-unit crate) |
| 2 | `MAT_MAP_BRUSHED` | brushed streaks along u, about 150 scratches at all angles | roughness (scratches rougher) | 3 | 10 to 20 |
| 3 | `MAT_MAP_STONE` | stone and concrete: fbm relief, small craters, veins | albedo (veins darker) | 4 | 30 to 60 |
| 4 | `MAT_MAP_WEAVE` | plain weave, 16 threads a tile each way, fibres and ply twist | albedo (per thread; gaps darker) | 16 (a thread) | 3 to 6 (threads 0.2 to 0.4 apart) |
| 5 | `MAT_MAP_BUMPS` | leather, rubber, organic: pebbled cells with creases | roughness (creases rougher, tops smoother) | 8 | 6 to 12 |
| 6 | `MAT_MAP_WEAR` | chips, scratches and scuffs; B dips at chips and scratches | the wear order: worn where `A > 1 - wear`. Bare surface 0.24 to 0.48 (only `wear` above 0.5 reaches it), scuffs from 0.52, scratches from 0.62, chips from 0.72 (cores first) | 4 | 15 to 30 |
| 7 | `MAT_MAP_BARK` | bark fissures along v and a crack network (bark, dry ground, cracked paint, leaves) | albedo (fissures and cracks darker) | 5 | 15 to 40 |

A tileable map knows nothing of the mesh's edges: for edge wear, combine the wear order with an edge term of your own
(the art's edges in `m.lumD`, or the grazing term `m.ndv`).

Helpers (in `_common.glsl`; they return or take the raw `vec4`):

- `MatMap(layer, uvScaled)`: `texture()` at `(uvScaled, layer)`, with the mip and anisotropy from the sampler. It takes
  implicit derivatives, so call it only in uniform control flow, never after a per-fragment branch such as
  `if (m.fade <= 0.0) return o;`.
- `MatMapAt(m, layer, freq, offset)`: the map tiled `freq` times per texture unit (a whole number keeps the texture's
  own wrap seamless), with explicit derivatives (`textureGrad`), so it is safe anywhere. Prefer it.
- `MatMapWorld(m, layer, tileWorld, texels)`: a tile about `tileWorld` world units across (multiply by `m.scale`), the
  two power-of-two octaves around it blended as `MatOctave` does, and faded to neutral by the footprint. Two samples.
- `MatMapFade(m, freq, texels)`: 1 while a feature `texels` map texels across covers four pixels, 0 at two; use the
  table's feature size. `MatMapNeutral(s, k)` pulls a sample toward neutral by it. The mips flatten the normal by
  themselves; the fade takes what a snippet derives from the sample (gloss, cavity, wear thresholds) to neutral before
  it aliases.
- `MatMapBump(m, s, amount)`: the eye-space `dn` of the sample's normal (amount 1 = the map's own slopes, along `m.tu`
  and `m.tv`). `MatMapHeight(s)` and `MatMapVar(s)`: B and A about 0 (-0.5 to 0.5).

```glsl
// in mat_wood_planks: grain along the texture's u, a tile 40 world units long
vec4 g = MatMapWorld(m, MAT_MAP_WOOD, 40.0 * m.scale, 6.0);
o.dn += MatMapBump(m, g, 0.8);
o.albedo = MatVary(o.albedo, 0.08 * m.p.y, 2.0 * MatMapVar(g));
o.ao *= 1.0 + 0.6 * min(MatMapHeight(g), 0.0);
// wear: worn where the order passes the threshold
vec4 w = MatMapWorld(m, MAT_MAP_WEAR, 24.0 * m.scale, 4.0);
float worn = smoothstep(1.0 - m.p.x, 1.0 - m.p.x + 0.05, w.a);
```

Each `MatMapAt` is one `textureGrad`; `MatMapWorld` is two. A layer's direction is fixed (wood and brushed run along
u, bark along v). Where a texture's art runs the other way, sample `vec2(m.uv.y, m.uv.x)` with your own swapped
derivatives, or ask the library for a rotated helper. To change the maps, edit `tools/make_detail_maps.py`, run it,
and keep the PNG under 1.5 MB. Never paste in pixels from anywhere else. The model preview binds the same strip
(`--maps`, `--no-maps`).

## How a class worker iterates

1. Copy `generic.glsl` to `<class>.glsl`, rename the function and `@class`, set `@default` and `@param` lines.
2. Preview without touching the shaders (the preview builds its own candidate and tag table each run):

   ```sh
   export SUNSTONE_INVENTORY=<inventory folder>  PLAYWRIGHT=<playwright package folder>
   node tools/preview/model.mjs --sheet class:<class> --limit 12 --out /tmp/<class>.png
   node tools/preview/model.mjs --id <id> --shape sphere --density 12 --theme ARCTIC --out /tmp/x.png
   ```

   Look at near (`--dist 25`) and far (`--dist 300 --px 256`) views, two or three themes, `--set-candidate
   sunstoneMatDebug=2` (detail amount) and `=3` (normal detail).
3. Tune per texture in `overrides/<class>.json` (`"<id>": { "scale": 1.5, "wear": 0.7 }`, or `"cls"` to move a
   texture to another class).
4. Before handing in: `python tools/build_materials.py --out /tmp/c.glsl` must pass, and the shaders must compile
   under `glslangValidator -S frag` (desktop GLSL 1.30). The library owner runs `python tools/build_materials.py`
   and `python tools/make_tag_table.py --inventory <dir>` once at merge, which rewrite the committed shaders and
   `mod/texture_tags.json`; `--check` on either says whether they are up to date.
