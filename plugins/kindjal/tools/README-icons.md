# Weapon icons

`make_icons.py` draws the three Kindjal weapon icons (Acid Spitter, Acid Flask, Crucible). Each is rendered once at
256x256 and written twice:

- `../mod/assets/loose/kindjal.<name>.hud.tga`: the in-game HUD icon. 256x256, 32-bit uncompressed TGA (image type 2,
  bottom-left origin, 8 alpha bits, TGA 2.0 footer), the same layout as the game's own `Data/HUD/Weapons` icons.
- `../mod/assets/icons/<name>.png`: the weapon-panel icon. 64x64 RGBA PNG, the 256 drawing box-filtered down 4x4 in
  premultiplied space, so the two always match.

It is stdlib-only Python 3 (no Pillow) and deterministic (fixed geometry, fixed seeds for the rust and crack patterns),
so re-running gives identical bytes.

    python make_icons.py           # write the files (about 10 s)
    python make_icons.py --check   # regenerate in memory, compare byte-for-byte with disk, exit 1 on any difference

The style follows the vanilla HUD icons: thin near-black outline, three-tone cel shading lit from the upper left, a tilted
pose that fills the frame, a faint soft shadow; the palette is darker and grittier. Shapes are signed-distance functions
with 1px anti-aliased coverage. Palette constants sit at the top of the script. The art is original and drawn by code;
nothing is copied from the game. Edit the geometry or colours there and regenerate; commit the images with the script.
