# Weapon meshes

Kindjal ships 37 mesh banks in `mod/assets/meshes/` (`mod/spice.json` lists them under `meshes`; the weapon definitions
use them as `WeaponGraphicsResourceID` / `PayloadGraphicsResourceID` and the like, and `vehicleMeshes` swaps the two
helicopters). 19 are static meshes: `make_meshes.py` builds them as glTF + texture into `meshes/` (the editable source)
and `build_meshes.py` packs them (see "Building the banks" and "All static banks"). 18 are clones of vanilla skinned
meshes, built by the `clones_*.py` scripts (see "Clone banks"). This page starts with the first four static meshes, the
original set.

**Where the scripts find xomtool and the game.** Nothing is hard-coded. Every script that runs xomtool reads
`KINDJAL_XOMTOOL` (the exe; otherwise `xomtool` on PATH) and `KINDJAL_BUNDL09` (the game's `Bundles/Bundl09.xom`) or
`KINDJAL_GAME_DATA` (the game's `Data` folder), and `--xomtool` / `--bundl09` (`--game-data` for `build_meshes.py`)
override them; if nothing is found the script stops and says which to set (`_paths.py`). `--only` with an unknown slug
is an error.

**Status: shipped, but the look under the game's lighting is not yet verified in game.** The previews used while
authoring were flat-lit, so check the contrast curve (`Texture(gain=, sat=)`) against a real screenshot.

    python make_meshes.py            write meshes/*
    python make_meshes.py --check    regenerate in memory, compare with the files on disk (exit 1 on a difference); the
                                     .png by decoded pixels, because deflate bytes differ between zlib builds, the rest byte for byte

Stdlib only (json, struct, math, random, zlib), fixed seeds, deterministic. Every run also re-reads each glTF with a
strict validator (accessor counts and alignment, buffer bounds, u16 index range, no unreferenced vertices, unit
normals, uv in 0..1, POSITION min/max equal to the data, winding agrees with the normals, no directed edge used twice (an inside-out piece), texture is a valid 128x128 RGB
PNG, bounding box within 10% of the vanilla asset, 300 to 900 triangles) and refuses to write anything that fails.
The art of these static meshes is original; nothing comes from the game except the shader each bank borrows in the
next step (`build_meshes.py`). The clone banks are different: see "Clone banks".

| file set | replaces | vertices | triangles | texture |
| --- | --- | --- | --- | --- |
| `nail_bat.*` | `BaseballBat` | 590 | 720 | 128x128 near-black wood, blood, bright cloth tape and tail, steel-tipped rusty nails |
| `acid_flask.*` | `GasCanister` (the Acid Flask's payload) | 530 | 820 | 128x128 bright toxic-green glass, acid with bubbles, a dark liquid line, skull plaque, cork |
| `acid_round.*` | `Bazooka.Payload` (the Acid Spitter's round) | 596 | 836 | 128x128 olive steel, yellow and dark bands, rust, three pits with bright acid seeping in them |
| `crucible.*` | `HolyHandGrenade` | 617 | 792 | 128x128 charred black, bright ember-orange cracks, iron rim ring and studs, glowing bowl |

**Drawn for game distance.** A held weapon is about 60 px tall at the default camera, so fine detail is lost; the
first set of meshes (12 small nails, hairline cracks) did not read. These are redone with big shapes and a broken
silhouette, and every texture goes through a final contrast and saturation curve (`Texture(gain=, sat=)`) because the
game's lighting flattens it. The art was checked with a throwaway software rasteriser (flat lit, textured,
orthographic) at 256 px and at 64 px (longest side 60 px), iterating until the silhouettes were bold at 64 px.

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
| `nail_bat` | -3.157 .. 3.167 | -12.580 .. 13.295 | -3.139 .. 3.090 | 6.32 x 25.88 x 6.23 |
| `acid_flask` | -4.6 .. 4.6 | -6.0 .. 6.0 | -4.915 .. 4.915 | 9.2 x 12.0 x 9.83 |
| `acid_round` | -2.62 .. 2.62 | -2.593 .. 2.593 | -3.074 .. 3.619 | 5.24 x 5.19 x 6.69 |
| `crucible` | -5.033 .. 4.816 | -5.022 .. 4.851 | -6.928 .. 6.800 | 9.85 x 9.87 x 13.73 |

All agree with the vanilla box within 10% on every axis (the generator refuses anything looser). The loosest are the
bat's x and z (+9.5% and +9.1%), the flask's z (+8.7%, the skull plaques) and the crucible's x (-7.4%). The bat's nails
fill the vanilla radius (they reach r 3.1 .. 3.18); its barrel is slimmer than vanilla (r 1.8) so the nails, not
the wood, set the width. The flask's bulb is r 4.6 and the plaques stand 0.32 proud on the +-Z faces.

## How each was built

All four are surfaces of revolution (`revolve`) with a texture rectangle per strip; a "strip" is a run of profile points
that is one smoothing group, so a profile break is a hard crease. Loose parts are added on top: `tube` (a closed tube
along a polyline, for the bat's bent nails and the crucible's studs), `ribbon` (a thin flat strap, the bat's cloth
tail) and `relief` (a displaced grid patch on the flask's bulb, the skull plaque). Parts are closed, so the winding is fixed by the sign
of the enclosed volume. Normals are area-weighted per (group, position), so seams and poles are smooth where they
should be. The paint is computed per pixel from periodic value noise (wraps around the axis) and from the **same
analytic description** the geometry was carved with, so painted features line up with the relief.

- **nail_bat** (12 segments, Y axis). Profile: a rounded grip knob, a thin handle, a taped band that stands proud
  (r 1.5 against a 0.92 handle, its own strip so the edges are creased) at y -6.6 .. -2.65, and a slim barrel growing
  to r 1.8 near y 9.8 with a rounded end. **Seven nails**, each a closed 6-sided tube in the plane of the nail: sunk
  into the wood, a short radial stub (r 0.75, 2.5x the old 0.30), a kink, then a long throw to the point (about 2.9
  long in all against the old 0.96); six are thrown up the barrel and one down. Most sit on the two flanks (azimuth
  about 0 and 0.5) so they break the silhouette from the side; their positions come from one function that the texture
  also reads (a puncture hole, rusty rim and blood run at each). A **loose cloth tail** (a thin flat ribbon, 1.35 wide,
  with its own flat-shaded faces) hangs off the top edge of the band and flares away from the wood. Texture: much
  darker wood (so the nails and tape stand out), bright off-white tape with dark gaps between the turns, dried blood on
  the barrel, end-grain rings, a lanyard band on the knob; the nail texture runs bright steel at the point (v = 0)
  through dull iron to rust at the base, with a lit and a shaded side baked in; the tail is cloth with a red stripe on
  each edge.
- **acid_flask** (16 segments, Y axis). A fat round bulb (r 4.6 at y -0.7, nearly a sphere), a short thick neck (r 2.05
  against the old 1.5), a flared lip and an **oversized cork** (r 2.5, wider than the neck) on top. **Skull plaque**:
  on the +Z and -Z faces a 9x9 grid of cells (0.4 each) is pushed out of the bulb by a height function: a round plaque
  0.16 proud, the skull (cranium and jaw) another 0.17, eye sockets and nose cut back to the plaque, and the outer ring
  of vertices sunk 0.25 into the body so the plaque has a wall rather than an open edge. The same masks
  (`skull_masks`) paint it: a bright ring, ivory bone, black holes and dark tooth slits, planar-mapped from its own
  60x60 texel rect. The rest of the texture: bright toxic-green glass above, saturated acid below a bold **dark liquid
  line** with a bright band under it, bubbles, white window-light streaks, a dark lip and a bright tan cork with dark
  pores.
- **acid_round** (22 segments, Z axis). A stubby shell: max r 2.5 held to z 1.85 and then a blunt dome to z 3.62 (the
  old ogive tapered from z 1.4), a tail with a recessed nozzle bell (three small strips), and a **raised dark band**
  (r 2.62) near the tail as its own strip. **Three large corrosion pits** (radius 1.05 .. 1.15, 0.52 .. 0.58 deep, 120
  degrees apart at different heights so each flank shows one) are pressed into the front strip as flat-floored
  craters with a slightly raised lip (`pit_field`); the rings in the pit area are 0.5 apart so a crater is about four
  cells across. The paint takes the same list: a rusty ring, a dark wall and **bright green acid** seeping in the
  floor. Texture: pushed-apart olive steel, a yellow stencil band, rust patches, acid runs, a black band with a thin
  red stripe, soot near the nozzle and a hot orange nozzle rim.
- **crucible** (24 segments, Z axis). A sphere of r 5.1 centred on z -1.9 (the lower 145 degrees), a one-step neck, a
  **heavy rim ring** (r 4.4 and 2.6 tall with chamfers, against the old r 3.3 flare) reaching z 6.8, and a cone-shaped
  molten bowl. The relief on the sphere is a few low-frequency lumps (0.05 .. 0.07) and the **carved cracks**: five
  random walks along great circles (some branch), started at spread latitudes so every side has one, each point pulled
  inward by up to **1.25** (the old cracks were 0.5) over a half-width of **0.27 rad** (old 0.21) with a flat 0.05 rad
  floor, so they are real grooves that notch the silhouette. The paint lights the same description: a red-hot wall, a
  bright **ember-orange floor** and a yellow-white core, with loose embers in the char. **Six iron studs** (two belts of
  three, nudged along the belt to stay clear of the cracks) are 5-sided blunt cones standing 0.72 off the sphere, with
  a bright steel point.

The triangle budget (300 to 900) is the hard limit on all of this: the crucible and the round spend theirs on rings
and segments so that a groove or a pit is more than one cell wide, the flask on the plaques, the bat on the nails.

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
  version; it did in the build used here (a `dist/tools/xomtool.exe` built from Melange's `audio` branch).
- This `--into` recipe is the old manual route; the shipped banks come from `build_meshes.py` (next section).

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

    python build_meshes.py            write the banks
    python build_meshes.py --check    rebuild in a temp folder, compare byte for byte (exit 1 on a difference)
    --xomtool <path>                  default: $KINDJAL_XOMTOOL, else xomtool on PATH (needs `convert --bundle`)
    --game-data <Data folder>         default: $KINDJAL_GAME_DATA (only Bundles\Bundl09.xom is read)

Each section is used once because a bank is one mesh and the engine loads a section once per session. Re-run it, and
`--check`, whenever `make_meshes.py` output or xomtool changes; commit the banks with the script.

## All static banks (19)

`make_meshes.py` also runs the three group modules (`meshes_held.py`, `meshes_misc.py`, `meshes_thrown.py`; each exports
`MODELS = [(slug, build_fn, vanilla_reference_name)]` and `generate()`). They validate against their own reference boxes
with a 12% tolerance and 400 to 1800 triangles (the four originals keep 10% and 300 to 900). A plain run regenerates all
19 models; `--check` compares all of them and flags anything else in `meshes/` as UNEXPECTED. `build_meshes.py` builds
one bank per model into `../mod/assets/meshes/` (its `--check` compares only these 19; other files there, such as the
clone banks, are ignored). xomtool accepted every material below, so no substitutions were needed.

| slug | resource id | section | vanilla reference / material | triangles | bank bytes |
| --- | --- | --- | --- | --- | --- |
| `nail_bat` | `kindjal.NailBat` | 476 | `BaseballBat` | 720 | 91476 |
| `acid_flask` | `kindjal.AcidFlask` | 477 | `GasCanister` | 820 | 90160 |
| `acid_round` | `kindjal.AcidRound` | 478 | `Bazooka.Payload` | 836 | 92371 |
| `crucible` | `kindjal.Crucible` | 479 | `HolyHandGrenade` | 792 | 92790 |
| `shiv` | `kindjal.Shiv` | 480 | `BaseballBat` | 820 | 124803 |
| `gauntlet` | `kindjal.Gauntlet` | 481 | `BaseballBat` | 1332 | 151471 |
| `railspike` | `kindjal.Railspike` | 482 | `TailNail` | 880 | 125743 |
| `ripper_launcher` | `kindjal.RipperLauncher` | 483 | `Bazooka.Weapon` | 1084 | 113415 |
| `ripper_rocket` | `kindjal.RipperRocket` | 484 | `Bazooka.Payload` | 704 | 97444 |
| `pipe_bomb` | `kindjal.PipeBomb` | 485 | `Grenade.Payload` | 508 | 87229 |
| `blast_keg` | `kindjal.BlastKeg` | 486 | `Dynamite` | 764 | 102944 |
| `profane_grenade` | `kindjal.ProfaneGrenade` | 487 | `HolyHandGrenade` | 968 | 98312 |
| `plantain_bananas` | `kindjal.Plantains` | 488 | `BananaBomb` | 816 | 97887 |
| `elephant_gun` | `kindjal.ElephantGun` | 489 | `SniperRifle` | 976 | 100501 |
| `rust_canister` | `kindjal.RustCanister` | 490 | `GasCanister` | 1434 | 113853 |
| `field_radio` | `kindjal.FieldRadio` | 491 | `Radio` | 1406 | 110923 |
| `stone_donkey` | `kindjal.StoneDonkey` | 492 | `Donkey` | 1390 | 129587 |
| `plague_arrow` | `kindjal.PlagueArrow` | 493 | `Arrow` | 660 | 93389 |
| `inflated_knifeman` | `kindjal.InflatedKnifeman` | 494 | `InflatedScouser` | 1144 | 101484 |

## Clone banks (18)

These are made with `xomtool clone <Vanilla> --from Bundl09.xom`, which keeps the vanilla skinned mesh: skeleton, node
names, skin weights, clip library, texture stages, vertex count and order, and UV layout all stay the game's, so the
vanilla animations still drive them. A script supplies a `--deform` (new vertex positions) and the repainted textures
(`--texture`). They are not original in the way the static meshes are, and the README says so ("What is derived from
the game"). Each script has `--check` (rebuild in a temp folder, compare byte for byte; the bank holds raw pixels, so
no deflate stream is involved), `--only <slug>` and the path options above.

| script | banks |
| --- | --- |
| `clones_beasts.py` | `RabidSheep`, `PlagueRam`, `Carcass` |
| `clones_people.py` | `Hangwoman`, `Knifeman`, `Gorger` |
| `clones_air.py` | `BlackGunship`, `CarrionGunship` (the vanilla atlas is kept as shading detail under the new colours) |
| `clones_guns.py` | `SlugGun`, `GibbetTurret`, `HarpoonGun`, `Harpoon`, `PlagueBow` |
| `clones_props.py` | `NailCluster`, `NailClusterPiece`, `CarpetShell`, `BearTrap`, `DeadStar` |

Texture rows: xomtool's glTF and its `--uv-layout` have v up, so a texel row is `(1 - v) * height`; every clone script
rasterises that way.
