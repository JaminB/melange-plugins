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

`tools/build_materials.py` splices `_common`, the snippets, a generated `MatDispatch` (an `if` chain on the class id:
GLSL 1.20 has no `switch`) and `_evaluate` between the `BEGIN/END MATERIALS` markers of both shaders.
`tools/make_tag_table.py` writes `mod/texture_tags.json` from the inventory's class decisions, each snippet's
`@default` line and the overrides.

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
| `fade` | 0..1 distance and grazing fade (applied by the dispatcher; use it to skip work) |

Outputs (`MatOut`): `albedo`; `spec` (specular scale) and `gloss` (exponent scale); `dn` (normal perturbation, added to
`n` before normalising); `ao` (cavity: all of the ambient, a third of the sun).

Helpers in `_common.glsl`: `MatHash12/22/32`; `MatGNoise(p, period)` gradient noise with its slope (period = the
frequency keeps a texture's wrap seamless); `MatFbm(m, uv, freq, octaves)` (each octave faded by its own footprint);
`MatOctave(m, sizeWorld, F0, blend)` (power-of-two frequency for features `sizeWorld` apart, blend two octaves so the
size never jumps between triangles); `MatFadeCells/Uv/World` (1 at four pixels a cell, 0 at the Nyquist limit);
`MatBumpUv(m, dh/duv)` and `MatBumpScreen(m, dh/dxy)`; `MatVary(c, amount, r)`; `MatLum`. A disabled stub for future
shared maps (`sunstoneMat`, a `sampler2DArray`, `#version 130`) sits behind `SUNSTONE_MAT_MAPS`.

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
   under `glslangValidator -S frag` (desktop GLSL 1.20). The library owner runs `python tools/build_materials.py`
   and `python tools/make_tag_table.py --inventory <dir>` once at merge, which rewrite the committed shaders and
   `mod/texture_tags.json`; `--check` on either says whether they are up to date.
