# Particle and decal sprites

`make_sprites.py` draws every Kindjal sprite into `../mod/textures/`. It is stdlib-only Python 3 (no Pillow) and
deterministic (fixed seeds), so re-running gives identical bytes.

    python make_sprites.py            write the PNGs
    python make_sprites.py --check    regenerate in memory and compare with the files on disk (PNGs by decoded pixels; exit 1 on a difference)

All sprites are RGBA with RGB pure white everywhere; the shape is in the alpha channel, so the client tints them at draw
time (acid green, smoke grey, and so on) without fringing. Each keeps a clear margin so the quad edge never shows.
The art is original, built from signed-distance shapes and value noise. Edit the geometry in the script and
regenerate; commit the PNGs together with the script. This folder (`tools/`) does not ship with the mod.

| File | Size | Use and look |
| --- | --- | --- |
| `kj_smoke1.png` | 128x128 | Acid smoke puff: round, fat, soft turbulent billows with a feathered edge. |
| `kj_smoke2.png` | 128x128 | Acid smoke puff: lobed and wider than tall, spreading sideways. |
| `kj_smoke3.png` | 128x128 | Acid smoke puff: taller column that thins and tears off towards the top. |
| `kj_wisp1.png` | 64x128 | Thin rising vapour curl: a lazy S that ends in a small hook, heavy at the bottom and fading up. |
| `kj_wisp2.png` | 64x128 | Thin rising vapour curl: a long drift that winds into a tight curl at the top. |
| `kj_bubble.png` | 64x64 | Acid bubble: thin ring brighter on two opposite sides, a faint veil inside and a specular dot. |
| `kj_puddle1.png` | 128x128 | Ground puddle decal: round noise-warped blob, brighter rim, mottled body, a few beads. |
| `kj_puddle2.png` | 128x128 | Ground puddle decal: wide lobed splash with a ragged edge and detached beads. |
| `kj_spark.png` | 64x64 | Spark streak: horizontal lens tapering to points, hot core and a faint halo; rotate at draw time. |
| `kj_glint.png` | 64x64 | Glint: four-point star with needle tips and a soft glow at the centre, for blade and spike flashes. |
| `kj_drop.png` | 64x64 | Droplet: teardrop pointing up, brighter skin, specular dot and a dim bounce light. |
