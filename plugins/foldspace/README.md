# Foldspace

Big, hand-built multiplayer maps for Worms Ultimate Mayhem, made with Melange's Erg map editor. Each map is a whole
world to fight over, not a dressed-up copy of a stock level. Foldspace collects them in one plugin, and new maps arrive
as plugin updates.

Needs Melange 0.14.0 or later.

The first map is **Caldera**.

## Caldera

A volcanic island in open sea. A black cone streaked with lava rises from a ring of sand beaches, and its summit holds
a wide crater.

- **The mine factory.** It sits in the crater. Every few turns it throws a volley of mines out of the crater from
  launchers on its inner walls. The mines arc out across the island and land on the slopes, on the beaches and, now and
  then, inside a castle. They keep off the trails. A blast or the rising sea sets them off or drowns them, and the
  factory tops the island up again.
- **Four castles.** Strand, Ashgate, Harbour and Seawall stand on the shore, one per team, and every team starts inside
  its own castle.
- **Switchback trails.** From each castle a trail of pale stone zigzags up the cone to the crater rim. Walking up is
  the slow, safe way to the high ground. Jetpacks, ropes and teleports are the fast way.
- **The sea.** It stays at the beaches until the game style's sudden death begins. Then it rises with the game's own
  Raise Water, at the speed the style sets, and floods the beaches, the castles and the lower slopes.
- **Detail.** Basalt boulders, slabs and shards on the slopes, plants on the beaches and ledges. All of it is
  decoration: it has no collision and never changes a shot.

### Recommended settings

- Local Game > Versus > Deathmatch (or another Versus type), Landscape > Prebuilt > Caldera.
- Four teams, so every castle is used. Two or three teams also work; the other castles stay empty.
- A game style whose sudden death is **Raise Water**. The island was built for a sea that rises. At the "fast" water
  speed the sea reaches the castle floors about five turns after sudden death starts (twice that at the default
  speed), so worms still in their castles drown together; the slopes stay dry for dozens of turns more. A round of 10
  to 15 minutes with 45 to 60 s turns gives time to climb.
- Weapons that move worms (Jetpack, Ninja Rope, Teleport, Girder) make the island far more fun.
- [Sunstone](https://jaminb.github.io/melange-plugins/plugins/sunstone/) is optional: Caldera was checked with and
  without it.

## Maps are built for you

Foldspace ships each map as an Erg **source pack**. That is the map's edits (`maps/<map>/<map>.ergpatch.json`) and its
rock models, not the finished level files. The finished files are built from your own copy of the game, so the plugin
carries no game files.

Melange builds them for you. `Melange.exe` builds Foldspace's maps when it starts and again before it launches the
game, after every install or update, so there is nothing to press. While it works the launcher shows **"Building map
pack Foldspace..."**, and it starts the game when the build ends. Caldera is then under **Prebuilt** in the Landscape
list.

- If a build fails, the Plugins page says why. Erg's **Build** button (under **Map packs to build**) and Melange's
  `xomtool.exe` still work by hand:
  `xomtool level build --patch Mods\foldspace\maps\caldera\caldera.ergpatch.json --game . --out Mods\foldspace\assets\levels`,
  run in the game folder, once per map.
- If you start the game without `Melange.exe`, nothing builds it: the Mods page shows Foldspace as **"not built"** and
  none of its maps or rocks load until `Melange.exe` has built it, or you build by hand as above.
- `[Erg] AutoBuildMaps=0` in `Melange.ini` turns the automatic build off.

## It is a content mod

Every player in an online match needs Foldspace, at the same version, built. A lobby where someone is missing it
holds the start on a Foldspace map with a banner that names who. Maps from Foldspace are never in the game's random
landscape picks (`[Levels] RandomPool=0`, the default).

## Limits

- **Mesh sections.** The game has 44 slots for mod mesh banks shared by every enabled plugin. Foldspace uses one for
  all of Caldera's rocks, so it fits next to Kindjal (38 banks) and most other content plugins. Each further map
  adds one.
- In a Versus match Caldera is drawn in a darker evening light than in Erg's Test. The cause isn't known yet.
- The mine factory follows the engine's payload pool: at most about 30 mines lie on the island at once.
- Caldera places about 860 scenery pieces, more than the game's own mesh pool holds. Melange's `[Fixes] MeshInstances`
  (2000, the default) raises the pool; don't set it to 0 (vanilla) while Foldspace is on.

## For map makers

Each map is built in the Melange repository with Erg and erg-mcp, then copied in here by
`tools/sync_map.py`. That script renames the map into Foldspace's names, records where the copy came from, and checks
the plugin. See [tools/README-maps.md](tools/README-maps.md).

## What is derived from the game

- The finished level files are built on your PC from the game's own Diner Might level (Caldera's base). They are not
  in the plugin.
- Each rock bank borrows the material settings of the game's `HORROR5` rock (from `Bundl31.xom`), made matte. The rock
  shapes and their basalt textures are original, generated by a script in the Melange repository
  (`tools/erg-mcp/bench/caldera/meshes/gen.mjs`).
- The castles, trails and island are new voxel blocks placed by the map. Some decoration is copies of the base level's
  own scenery pieces, placed by the map, not new files.

## Credits

Caldera was designed and built with Erg and erg-mcp by the Melange project, with the plugin owner directing the map:
the volcano, the four castles and their trails, the mines thrown across the island, and the sea at sudden death.

## Licence

MIT, see LICENSE. Foldspace is not made by, affiliated with, or endorsed by Team17.
