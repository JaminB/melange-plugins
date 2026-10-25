## 1.0.1

Fixes the false "desync at tick 9004" that Wormsign reported against one player at 3:00 in every online Sandworms match.
No rule or timing of the mode changes; the game itself never desynced from it.

- Wormsign hashes this mod's globals and storage on every tick the sim script runs, and Melange 0.11.0 and 0.11.1
  demote that hash to every 10 ticks on a machine where it measures slow. The demoted machine then folds a stale hash
  into the tick where the hourglass empties (phase 0 to 1) while everyone else hashes the fresh one, so the faster
  machines reported a desync of `mod.sandtide.env` at tick 9004 (3:00.08) with every engine value equal.
- The sim script now keeps the hashed state small (tuning values are locals, the storage table is no longer also a
  global, which was walked twice) and polls the round clock every 25 ticks instead of 5, so the digest runs on under
  5 % of ticks and is never demoted, on any machine. The hourglass is still armed within half a second of 3:00; the
  curse still strikes at the next turn end.
- Melange 0.11.2 fixes the same thing on its side (no demotion by default). This version works with 0.11.0 and later.

## 1.0.0

Sandtide's first release. Needs Melange 0.11.0 or later and Kindjal 1.3.1 or later.

- The Sandworms game style: Standard with 45 s turns and a five-minute round, then the water rises (medium speed),
  played with the Kindjal weapons. Other game styles are not affected.
- A sand line on every map, shown as a glowing band of drifting sand.
- An hourglass at the bottom of the screen counts down to 3:00 (cracks, glow and ticks in the last 15 s). At 3:00 it
  shatters, then fills a water drop until the water rises.
- At the next turn end every worm resting below the line has its tail turned to sand. It keeps its turns and can aim
  and fire, but it can never move again, and explosions no longer push it. It still takes damage and drowns when the
  water reaches it.
- The camera tours every cursed worm on every team before the next turn starts.
- Cursed worms keep their sand coat and mound for the rest of the match. The cast crumbles away when the water reaches
  them.
- Quiet sound, with a *Sound volume* setting.
- Content mod: every player in an online match needs the same version.
