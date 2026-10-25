# Sandtide

A content plugin for Worms Ultimate Mayhem that adds the **Sandworms** game style. Most of a Sandworms match is a
normal match played with the [Kindjal](../kindjal) weapons, but the desert keeps time: every map has a sand line, and an
hourglass at the bottom of the screen runs down. When it empties, every worm still standing below the line has its tail
turned to sand, and it stays where it is for the rest of the match. Two minutes later the water rises.

It needs Melange 0.11.0 or later (worm anchoring, the turn-start hold, the render-only camera and `wum.draw.mesh`) and
Kindjal 1.3.1 or later.

## It is a content mod

Sandtide changes the simulation, so **every player in an online match needs the same version of it** (and of
Kindjal). Melange handles that: a host with Sandtide refuses to start against a player who lacks it or has another
version, and a match recorded with Sandtide replays only with Sandtide. Which worms are cursed, and when, is decided by
the sim script from simulation state only, so every machine curses the same worms at the same tick. The hourglass, the
camera tour and every effect are local and never feed back into the game. The rules apply to the Sandworms style only:
with Sandtide installed, every other game style plays as before.

## The rules

Pick **Sandworms** under *Game Style*. It is Standard with:

| Setting | Value |
| --- | --- |
| Turn time | 45 s |
| Round time | 5:00, then sudden death |
| Sudden death | the water rises, medium speed |
| Weapons | the Kindjal set; mobility (rope, jetpack, parachute, girders, select worm) is generous so you can climb before 3:00 |

- **The sand line.** At match start the line is fixed a quarter of the way up from the lowest land you can stand on (the
  water line, when the land reaches under the water) to the highest land. It never moves, even when the land under it
  is blown away. It shows as a glowing band of drifting sand where it meets the land, with a faint sand haze over the
  ground just below it.
- **3:00, the hourglass empties.** The curse waits for the turn in progress to end.
- **The curse.** At that turn end every alive worm whose feet are below the line is cursed: its tail turns to sand and
  it is anchored where it stands, on every team. The camera tours each cursed worm (about 3.5 s each) before the next
  turn starts. When no worm is below the line, the sands spare everyone and play goes straight on. Only a worm at rest
  is cursed: one still jumping, vaulting, flying, sliding or on a rope or jetpack at that moment is spared (it would
  otherwise be pinned in mid-air).
- **A cursed worm** still takes its turns. It can turn on the spot, aim, change weapon and fire. It cannot walk, jump,
  backflip, rope, jetpack, teleport or parachute, and explosions damage it without moving it. Like a worm hit by No More
  Nails, its weapon panel greys out what a nailed worm cannot use: the rope, jetpack, parachute and teleport, and also
  armour, the bridge kit, Red Bull, the melee weapons, the sheep, the Old Woman, Starburst and Scouser. As with No More
  Nails, picking a greyed cell does nothing and the panel stays open, so the next click takes whatever cell is under the
  pointer; pick a usable weapon instead. It has no armour: it takes normal damage, and it drowns when the water reaches
  it: the cast crumbles and floats off as the water reaches it, before the game's own drowning takes it.
- **Teleport.** The Sandworms scheme stocks no teleport: the only one is the Teleport utility that comes out of crates.
  A cursed worm cannot use it (its weapon panel greys it out, and firing it is refused), like the rope, the jetpack and
  the parachute. Girders still work: they move nothing. The other utilities that could move a worm are not stocked
  either (Alien Abduction and Bubble Trouble have no ammo), and an anchored worm's pin holds against anything that
  pushes it.
- **5:00, the water rises.** At the curse the hourglass leaps to the centre of the screen and shatters, then becomes a
  water drop that fills until the water rises. During every turn intro it steps aside, left of "Ready?".

Ammo for the Acid Spitter, Acid Flask and Crucible follows their base weapons (Bazooka, Grenade and Holy Hand Grenade),
as for every Kindjal clone.

## Sound

Sandtide stays well under the game's own effects. The ticking is soft and only in the last 15 s, with a faint pour of
sand over the last 10 s; the glass cracks and shatters as one-shots; the low drone and the wind play only during the
camera tour and stop when it ends (or at the match end, a menu, a reload, or any error). No sound plays more than a few
times a second.

## Settings

| Setting | Default | What it does |
| --- | --- | --- |
| Camera tour of the cursed worms | on | Off keeps the game's own camera during the curse (the turn start is still held, so the timing is the same for everyone) |
| Curse effects | dramatic | How much dust, shake and sand the curse throws around: subtle, full or dramatic |
| Hourglass size | 1.0 | Scales the hourglass, 0.5 to 2.0 |
| Sound volume | 60 | 0 to 100. Sandtide's own sounds only (the hourglass, the strike and the tour); 0 turns them off |

The settings are local: they change only what you see and hear, never the match.

## For mod authors

The sim script (`mod/sim/main.lua`) tells the clients what it decided through two engine messages. Their exact formats
are in the comment at the top of that file:

- `Sandtide.Line` `"lineY|minY|maxY|strikeMs|roundMs|phase"`: the line, the land's height range, when the hourglass
  empties, the round length, and the phase (0 running, 1 empty, 2 struck). Sent when the line is known, when the phase
  changes, and at every turn start.
- `Sandtide.Curse` `"slots|holdTicks|curseTick|intro,per,outro|status"`: the cursed slots in tour order, the hold, the
  tick of the curse, how the hold is split, and `ok`, `spared`, `nohold` or `unavailable`. Sent at the curse and again
  at every turn start.

The tuning constants at the top of the sim script (`STRIKE_MS`, `LINE_FRACTION`, `INTRO`, `PER`, `OUTRO`) are part of
the content hash: a player who edits them has a different Sandtide from everyone else, and the host refuses the match.

## Limits

- The hourglass sits above the game's team health bars, so it can cover part of the picture; make it smaller with the
  *Hourglass size* setting.
- When land stands between two stops of the camera tour, the camera cuts through a short sand wipe instead of flying
  through it.
- The camera tour is render-only: the game's own camera does not move, so the land the game fades for its own camera can
  show world effects faintly through it.
- Players on Melange 0.10 see "mod contributors differ" against 0.11 players (Melange 0.11 adds two Wormsign
  contributors, `melange.wormanchor` for the anchors and `melange.turnhold` for the turn-start hold); everyone needs
  0.11 anyway.

## Credits

External assets (CC0, no attribution required; credited anyway):

| Used in | Source | Author | Licence |
| --- | --- | --- | --- |
| `mod/textures/sand_albedo.png`, `mod/textures/sand_normal.png` | [Ground 097](https://ambientcg.com/a/Ground097) (colour and OpenGL normal maps, 1K-JPG), reduced to 512 px, local contrast and grain added | ambientCG (Lennart Demes) | [CC0 1.0](https://docs.ambientcg.com/license/) |
| `mod/textures/cracks.png` | [Ground 031](https://ambientcg.com/a/Ground031) (displacement map, 1K-JPG), turned into a crack mask and reduced to 512 px | ambientCG (Lennart Demes) | [CC0 1.0](https://docs.ambientcg.com/license/) |

Everything else is original work made by the scripts in `tools/`, under this plugin's MIT licence:

- The hourglass HUD (`mod/textures/hud/`): frame, glass, sand levels, stream, cracks, glow, shatter frames, water drop
  and readout plate, rendered by `tools/make_hud.py`.
- The particle sprites (`dust_puff`, `sand_grain`, `sand_swirl`, `sand_band`), drawn by `tools/make_sprites.py`.
- Every sound in `mod/sounds/`, synthesised from scratch by `tools/make_sounds.py`. No recorded clips are used.

`tools/make_textures.py` rebuilds the three ambientCG-derived textures from the downloaded source maps, which are not
kept in the repository. Nothing is taken from the game.

## Licence

MIT, see LICENSE, for everything the author wrote. Assets listed under Credits keep their own licences. Sandtide is not
made by, affiliated with, or endorsed by Team17.
