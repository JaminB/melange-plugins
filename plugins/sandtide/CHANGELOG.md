## 1.0.0

First release. Needs Melange 0.11.0 or later and Kindjal 1.3.1 or later.

- The Sandworms game style: Standard with 45 s turns, a five-minute round, then the water rises (medium speed), played
  with the Kindjal weapons.
- A sand line on every map, a quarter of the way up from the water line (or the lowest land) to the highest land, shown
  as a glowing band of drifting sand.
- At 3:00 the hourglass empties. At the next turn end every worm whose feet are below the line has its tail turned to
  sand: it keeps its turns and can turn, aim and fire, but can never walk, jump, rope, jetpack, teleport or parachute
  again, and explosions no longer move it. It takes normal damage and drowns when the water reaches it. Its weapon panel
  greys out what a nailed worm cannot use (the game's own No More Nails rule).
- The camera tours every cursed worm, on every team, before the next turn starts.
- An hourglass at the bottom of the screen counts down to the curse (cracks, glow and ticks in the last 15 s), shatters
  when the curse strikes, then fills a water drop until the water rises.
- The cursed worms keep their sand coat and mound for the rest of the match; the sand washes away under water.
- The rules apply to the Sandworms style only (the sim script reads the game style with `wum.sim.scheme()`); every
  other style plays as before with Sandtide installed.
- Content mod: every player in an online match needs the same version.
