## 1.0.0

Sandtide's first release. Needs Melange 0.11.0 or later and Kindjal 1.3.1 or later.

- The Sandworms game style: Standard with 45 s turns, a five-minute round, then the water rises (medium speed), played
  with the Kindjal weapons.
- A sand line on every map, a quarter of the way up from the water line (or the lowest land) to the highest land, shown
  as a glowing band of drifting sand.
- At 3:00 the hourglass empties. At the next turn end every worm whose feet are below the line has its tail turned to
  sand: it keeps its turns and can turn, aim and fire, but can never walk, jump, rope, jetpack, teleport or parachute
  again, and explosions no longer move it. It takes normal damage and drowns when the water reaches it. Its weapon panel
  greys out what a nailed worm cannot use (the game's own No More Nails rule).
- The camera tours every cursed worm, on every team, before the next turn starts. Each stop is chosen ahead with dense
  sight rays (a fan over the whole worm, and the frame around it for props right in front of the lens), checked
  again during the shot (it moves to another angle if the worm gets hidden), and the tour hands back to the game on
  a sand wipe once the next turn's camera is in place.
- An hourglass at the bottom of the screen (aside, left of "Ready?", in every turn intro) counts down to the curse
  (cracks, glow and ticks in the last 15 s). When the curse strikes it leaps to the centre of the screen and shatters,
  glass and sand flying, then fills a water drop until the water rises.
- The cursed worms keep their sand coat and mound for the rest of the match; when the water reaches one, the cast
  crumbles and floats off it (with a short camera shot when the rising water brings it), before the game drowns it.
- Only a worm at rest (walking or still) is cursed; one jumping, vaulting, flying, sliding or on a rope is spared.
- The teleport is a crate utility only (the scheme stocks none), and a cursed worm cannot use it.
- Quiet sound, well under the game's own effects, with a *Sound volume* setting (0 to 100, default 60): a soft tick in
  the last 15 s and a faint pour in the last 10, one-shot cracks and the shatter at the strike, and a drone and wind
  only during the camera tour.
- The rules apply to the Sandworms style only (the sim script reads the game style with `wum.sim.scheme()`); every
  other style plays as before with Sandtide installed.
- Content mod: every player in an online match needs the same version.
