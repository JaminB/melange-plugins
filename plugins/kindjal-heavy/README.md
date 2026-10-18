# Kindjal Heavy

A Kindjal add-on for Worms Ultimate Mayhem that throws worms harder. Kindjal 1.1.0 plays near vanilla knockback (about
1.2 times the game's own); Heavy multiplies the knockback Kindjal sets by **1.4** and its reach by **1.15**, so the
result is roughly **1.7 times vanilla** knockback over about 1.27 times the reach. It ships one Lua script and no
game content.

## Using it

Enable Kindjal Heavy on the Mods page next to Kindjal (1.2.0 or later is required). Enable at most one Kindjal
knockback preset: Heavy conflicts with Kindjal Brutal.

## It is a content mod

Its simulation script is part of the content hash, like Kindjal's. **Every player in an online match must enable the
same Kindjal add-on, or none**; the host refuses to start with a mismatch, and a player who edits the factors has a
different Heavy from everyone else.

## What it does

At match start, after Kindjal has written its numbers, Heavy reads each knockback value back from the weapon, scales
it and writes it again: `ImpulseMagnitude` times 1.4 (rounded to 0.001) and `ImpulseRadius` times 1.15 (rounded to a
whole unit). Reading back means Kindjal's own `KNOCKBACK`, `REACH` and `MELEE` constants, and any future retuning,
carry through. Damage, blast radius and craters are untouched. It covers every weapon Kindjal sets knockback on,
including the Acid Spitter, Acid Flask and Crucible. The game's own numbers come back at the end of the match.

| Weapon | Vanilla | Kindjal | Heavy |
| --- | --- | --- | --- |
| Ripper (Bazooka) | 0.29 / 110 | 0.35 / 120 | 0.490 / 138 |
| Pipe Bomb (Grenade) | 0.28 / 110 | 0.34 / 120 | 0.476 / 138 |
| Blast Keg (Dynamite) | 0.35 / 130 | 0.43 / 145 | 0.602 / 167 |
| Gorger (Fatkins) | 0.60 / 200 | 0.72 / 220 | 1.008 / 253 |
| Earthquake Ass | 0.46 / 170 | 0.56 / 185 | 0.784 / 213 |
| Crucible | new weapon | 0.62 / 185 | 0.868 / 213 |
| Buddy Bomb (Sheep) | 0.32 / 130 | 0.50 / 175 | 0.700 / 201 |

Kindjal's table has the vanilla figures it knows. The log line `kindjal-heavy 1.0.0: N fields applied, M refused` says
how many writes landed; a refused field is logged as a warning and skipped.

## Limits

- Needs the Kindjal (1.2.0 or later) sim script to have run first (it does: Heavy depends on Kindjal).
- The sentry's shot container (`kWeaponSentryGunPayload`) may be refused by the engine, as in Kindjal itself; the log
  says so.
- Not yet played in a match.

## Licence

MIT, see `LICENSE`.
