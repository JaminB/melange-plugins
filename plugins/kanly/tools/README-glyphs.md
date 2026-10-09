# Control-hint sprites

`make_glyphs.py` draws every HUD sprite (keycaps, mouse glyphs, power rings, legend card and chip) into
`../mod/textures/`. It is stdlib-only Python 3 (no Pillow) and deterministic, so re-running gives identical bytes.

    python make_glyphs.py

Shapes are signed-distance functions rasterised with 1px anti-aliased coverage; no text is baked in, so the Lua side
draws labels over the flat keycap centres. Palette constants sit at the top of the script. The art is original.
Edit the geometry or colours there and regenerate; commit the PNGs together with the script.
