# Weapon meshes

`make_meshes.py` builds Kindjal's four custom weapon meshes into `meshes/`. They live under `tools/` (not `mod/`)
because they only ship once a mesh loader exists that can use them; everything here is ready for that.

**Status: staged, not shipped.** Nothing in `mod/` references these files, and none of them has been loaded in game
(xomtool's `LoadBank` cannot take mesh banks yet). When the mesh loader lands, convert each set to a `.xom` with the
commands further down and place the result under `mod/`.

    python make_meshes.py            write meshes/*
    python make_meshes.py --check    regenerate in memory, compare byte for byte with the files on disk (exit 1 on a difference)

Stdlib only (json, struct, math, random, zlib), fixed seeds, deterministic. Every run also re-reads each glTF with a
strict validator (accessor counts and alignment, buffer bounds, u16 index range, no unreferenced vertices, unit
normals, uv in 0..1, POSITION min/max equal to the data, winding agrees with the normals, texture is a valid 128x128 RGB
PNG, bounding box within 10% of the vanilla asset, 300 to 900 triangles) and refuses to write anything that fails.
The art is original; nothing comes from the game.

| file set | replaces | vertices | triangles | texture |
| --- | --- | --- | --- | --- |
| `nail_bat.*` | `BaseballBat` | 617 | 744 | 128x128 dark wood, blood, taped grip, rusty nails |
| `acid_flask.*` | `GasCanister` (the Acid Flask's payload) | 389 | 608 | 128x128 green glass, acid with bubbles, a painted crack |
| `acid_round.*` | `Bazooka.Payload` (the Acid Spitter's round) | 397 | 560 | 128x128 olive steel, rust, acid runs, pits |
| `crucible.*` | `HolyHandGrenade` | 460 | 720 | 128x128 charred black, ember cracks, glowing bowl |

Each is `<name>.gltf` + `<name>.bin` + `<name>.png`: one node, one mesh, **one primitive** (POSITION, NORMAL, TEXCOORD_0
as f32, u16 indices), one material with one `baseColorTexture`, identity node transform. UVs follow the glTF
convention (v measured down from the top of the PNG); that is also what xomtool writes for the vanilla meshes, and a
round trip through xomtool gives back identical UVs.

## Vanilla reference (measured)

Extracted read-only with `xomtool convert <Name> --from Data/Bundles/Bundl09.xom --out <Name>.gltf`
(testenv/A, Bundl09.xom). Boxes are min..max after applying the node matrix. Triangle counts are the sum over all
shapes of the asset.

| asset | up / long axis | x | y | z | size | tris | notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `BaseballBat` | Y | -2.887 .. 2.887 | -12.581 .. 13.295 | -2.855 .. 2.855 | 5.78 x 25.88 x 5.71 | 504 | one shape, no matrix. Grip knob at -Y (r 2.07), handle r 0.9 growing to the barrel r 2.87 near y 9, rounded end at +Y |
| `GasCanister` | Y | -4.519 .. 4.519 | -6.006 .. 6.006 | -4.519 .. 4.519 | 9.04 x 12.01 x 9.04 | 496 | one shape, uniform scale 1.00007, symmetric about the origin |
| `Bazooka.Payload` | Z, nose at +Z | -2.513 .. 2.512 | -2.423 .. 2.401 | -3.077 .. 3.619 | 5.02 x 4.82 x 6.70 | 120 | one shape; its node matrix translates (-0.024, 0, +0.066), already included. Max radius 2.5 near z 0.4 |
| `HolyHandGrenade` | Z, cross on top at +Z | -5.323 .. 5.317 | -5.144 .. 5.146 | -7.076 .. 6.800 | 10.64 x 10.29 x 13.88 | 575 | two shapes (450 body + 125 cross), no matrices. Sphere radius ~5.3 centred about z -1.9, neck, cross from z 2.1 to 6.8 |

(The other vanilla meshes in the same group, `Grenade.Payload`, are five shapes with node matrices; the flask uses
`GasCanister` because that is what `PayloadGraphicsResourceID` names in `spice.json`, at `Scale` 0.6.)

Ours, from the generator's output:

| mesh | x | y | z | size |
| --- | --- | --- | --- | --- |
| `nail_bat` | -2.862 .. 2.899 | -12.580 .. 13.295 | -2.707 .. 2.919 | 5.76 x 25.88 x 5.63 |
| `acid_flask` | -4.5 .. 4.5 | -6.0 .. 6.0 | -4.5 .. 4.5 | 9.0 x 12.0 x 9.0 |
| `acid_round` | -2.498 .. 2.5 | -2.5 .. 2.5 | -3.074 .. 3.619 | 5.0 x 5.0 x 6.69 |
| `crucible` | -5.038 .. 4.938 | -5.056 .. 5.247 | -7.024 .. 6.800 | 9.98 x 10.30 x 13.82 |

All agree with the vanilla box within 7% on every axis (the crucible is the loosest: its x size is 9.98 against 10.64). The bat's nails are included in its box; the barrel itself is a
little thinner (r 2.35) so the nails fit inside the vanilla radius.

## How each was built

All four are surfaces of revolution (`revolve`) with a texture rectangle per strip; a "strip" is a run of profile points
that is one smoothing group, so a profile break is a hard crease. Parts are closed, so the winding is fixed by the sign
of the enclosed volume. Normals are area-weighted per (group, position), so seams and poles are smooth where they
should be. The paint is computed per pixel from periodic value noise (wraps around the axis) and from the **same
analytic description** the geometry was carved with, so painted features line up with the relief.

- **nail_bat** (12 segments, Y axis). Profile: a rounded grip knob, a thin handle, a slightly raised taped band at
  y -6.7 .. -3.0 (its own strips, so the tape edges are creased), and a barrel growing to r 2.35 near y 9 with a
  rounded end. 12 nails, each a closed 5-sided cone (r 0.30, 0.96 long, sunk 0.30 into the wood) on a golden-angle
  spiral up the barrel at y 3.2 .. 11.4, tilted a few degrees; their positions come from one function that the
  texture also reads, so every nail gets a puncture hole, a rusty rim and a blood run in the paint. Texture: dark wood
  grain along the axis, a spiral cloth tape with a dark seam, dried blood and spatter on the barrel, end-grain rings at
  the tip, a leather band on the knob; a separate rusty-iron patch for the nails.
- **acid_flask** (16 segments, Y axis). A round-bottomed bulb (r 4.5 at y -1.6), shoulder, neck r 1.5, flared lip,
  flat lip top and a cork (r 1.25 .. 1.45) with a rounded top. Texture: pale glass above, toxic green acid below a
  wavy surface line with a bright meniscus, bubbles drawn as rings with a highlight dot, two window-light streaks, a
  jagged **crack with two branches** painted pale with a dark edge on the shoulder running down into the liquid, and a bead
  of acid at its lower end; cork with dark pores.
- **acid_round** (20 segments, Z axis). Ogive nose to z 3.62, max r 2.5, a tapering tail with a recessed nozzle bell
  (three small strips). 16 corrosion pits (random angle, z, radius 0.38 .. 0.72, depth 0.12 .. 0.24) are pressed
  radially into the body as smooth bumps, and painted as dark holes with rust rims from the same list. Texture: olive
  steel, worn stencil bands (yellow nose band, red band, dark band), rust patches, acid runs thickening toward the nose,
  soot near the nozzle.
- **crucible** (20 segments, Z axis). A sphere of r 5.2 centred on z -1.9 (the lower 145 degrees), a pinched neck, a
  flared rim reaching z 6.8, and a hollow top (an inner bowl). The relief on the sphere is two things: a few
  low-frequency lumps, and **carved cracks** - six random walks along great circles (some branch), each point pulled
  inward by up to 0.5 within about 0.2 rad of the crack. The paint takes each pixel's direction on the sphere and lights the same cracks: a
  white-hot core, orange edge, a faint heat glow into the char; loose embers; the lip glows from below and the bowl is
  molten.

## Turning them into mesh banks

xomtool injects a glTF into an existing `.xom` that does not already define the mesh classes, appends a new
`XMeshDescriptor`, borrows the vanilla shader (so the material setup, texture stage and lighting are the game's own)
and replaces the one texture it reaches with ours. Use a tiny container as the target, such as the game's
`Data/Tweak/EMPTY.XOM` (a one-object bank; `-o` writes a new file and leaves it alone). From `tools/`:

    set X=xomtool.exe
    set DATA=C:\path\to\Worms Ultimate Mayhem\Data

    %X% convert meshes\nail_bat.gltf   --into %DATA%\Tweak\EMPTY.XOM --as kindjal.NailBat   --material-from BaseballBat     --material-file %DATA%\Bundles\Bundl09.xom --texture meshes\nail_bat.png   -o kindjal.NailBat.xom
    %X% convert meshes\acid_flask.gltf --into %DATA%\Tweak\EMPTY.XOM --as kindjal.AcidFlask  --material-from GasCanister     --material-file %DATA%\Bundles\Bundl09.xom --texture meshes\acid_flask.png -o kindjal.AcidFlask.xom
    %X% convert meshes\acid_round.gltf --into %DATA%\Tweak\EMPTY.XOM --as kindjal.AcidRound  --material-from Bazooka.Payload --material-file %DATA%\Bundles\Bundl09.xom --texture meshes\acid_round.png -o kindjal.AcidRound.xom
    %X% convert meshes\crucible.gltf   --into %DATA%\Tweak\EMPTY.XOM --as kindjal.Crucible   --material-from HolyHandGrenade --material-file %DATA%\Bundles\Bundl09.xom --texture meshes\crucible.png   -o kindjal.Crucible.xom

All four were run against testenv/A and exit 0; reading each result back with
`xomtool convert kindjal.NailBat --from kindjal.NailBat.xom --out check.gltf` gives the same vertex and triangle counts,
the same box and the same UVs as the input, and `inspect --type XImage` shows the replaced texture as 128x128 RGB
(the vanilla ones are 64x64 or 64x128; xomtool accepted the larger image). Each output is about 85 to 93 KB.

Things to know when wiring them up:

- `HolyHandGrenade` has two shapes with two shaders (body and cross). `--material-from HolyHandGrenade` copies a shader
  for the whole new mesh, so the crucible is one shape with the body's shader and its texture replaced.
- The shaders are the game's lit shaders, so the painted ember light is baked into the texture and the mesh is still
  shaded by the scene lights on top of it.
- Whether xomtool's `--texture` accepts 128x128 for a shader that vanilla fills with a 64x64 image depends on the
  version; it did in the build used here (`dist/tools/xomtool.exe` of the melange-wt-controls worktree).
- Banks built this way are not loadable in game on their own: the game side needs the mesh loader that is being
  prototyped. Nothing in `mod/` references these files yet.

Edit the profiles, seeds and palettes at the top of each section of `make_meshes.py`, run it, and commit the outputs
together with the script.

## Building the banks: `build_meshes.py`

The `--into` recipe above is superseded by `xomtool convert --bundle`, which writes a complete, loadable one-mesh bank
(root `XGraphSet`, descriptor with the mod section, `"world"` graph with the engine's geometry GUID) with no seed file.
`build_meshes.py` runs it once per mesh and writes `../mod/assets/meshes/`:

| bank | section | material borrowed from (Bundl09) | texture |
| --- | --- | --- | --- |
| `kindjal.NailBat.xom` | 476 | `BaseballBat` | `meshes/nail_bat.png` |
| `kindjal.AcidFlask.xom` | 477 | `GasCanister` (one texture stage, so it works) | `meshes/acid_flask.png` |
| `kindjal.AcidRound.xom` | 478 | `Bazooka.Payload` | `meshes/acid_round.png` |
| `kindjal.Crucible.xom` | 479 | `HolyHandGrenade` (first shape's shader) | `meshes/crucible.png` |

    python build_meshes.py            write the four banks
    python build_meshes.py --check    rebuild in a temp folder, compare byte for byte (exit 1 on a difference)
    --xomtool <path>                  default: the melange-wt-audio agent-xom build (needs `convert --bundle`)
    --game-data <Data folder>         default: WUMFix\testenv\A\Data (only Bundles\Bundl09.xom is read)

Each section is used once because a bank is one mesh and the engine loads a section once per session. Re-run it, and
`--check`, whenever `make_meshes.py` output or xomtool changes; commit the banks with the script.
