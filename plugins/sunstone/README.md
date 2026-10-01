# Sunstone

A client-only graphics overhaul for Worms Ultimate Mayhem, built from Mirage and the engine's own switches.
Shaders, code and original or permissively licensed art only — no game texture, or anything derived from one, is
ever shipped.

This release ships one layer.

## L1 — Texture clarity

16x anisotropic filtering and trilinear minification filtering on the game's own textures. Off (vanilla) by
default; declared in `mod/spice.json`'s `graphics` block, and applied by Melange's `MirageTextures` framework
component the moment this mod is enabled.

### Toggling it

- **Enable/disable the mod** in Thumper's Mods page (or the overlay's Mods panel). That's the normal switch:
  disabling Sunstone returns every texture to vanilla filtering immediately, without a restart.
- **`Melange.ini` override**, for players without the mod, or who want different values:

  ```ini
  [MirageTextures]
  Anisotropy=auto   ; auto | an integer 0-16
  Trilinear=auto    ; auto | on | off
  LodBias=auto      ; auto | a number from -8 to 8
  ```

  `auto` follows whatever enabled mods request (vanilla if none do); an explicit value here always wins over a
  mod's request.
- **Read the current effective settings**: the `mirage.textures` developer console verb logs anisotropy, trilinear,
  LOD bias, and how many textures have been touched so far.

## What's next

Later releases add the rest of the plan: grading and anti-aliasing, atmosphere (fog, sky, SSAO), then the harder
shadow, lighting, water and supersampling layers — each shipped as this plugin's own post-FX passes and shaders,
plus whatever small framework piece they need from Melange.
