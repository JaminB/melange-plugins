# Kindjal Brutal

A Kindjal add-on for Worms Ultimate Mayhem that restores **Kindjal 1.0.0's original knockback**, two to three times
the game's own: the Ripper throws at 0.64, the Gorger at 1.80, the Earthquake Ass at 1.30. Kindjal 1.1.0 brought
knockback back to near vanilla; Brutal puts the old power back. It ships one Lua script and no game content.

## Using it

Enable Kindjal Brutal on the Mods page next to Kindjal (1.3.0 or later is required). Enable at most one Kindjal
knockback preset: Brutal conflicts with Kindjal Heavy.

## It is a content mod

Its simulation script is part of the content hash, like Kindjal's. **Every player in an online match must enable the
same Kindjal add-on, or none**; the host refuses to start with a mismatch.

## What it does

At match start, after Kindjal has written its numbers, Brutal writes Kindjal 1.0.0's `ImpulseMagnitude` and
`ImpulseRadius` for every weapon, absolute numbers copied from 1.0.0, including the Acid Spitter (0.25), Acid Flask
(0.15) and Crucible (1.35 over 195). They do not follow Kindjal's own `KNOCKBACK`, `REACH` and `MELEE` constants.
Where 1.0.0 set no reach (the four melee weapons, the Slug Gun, the Acid Spitter and the Acid Flask) Brutal sets none
and Kindjal 1.1.0's stays. Damage, blast radius and craters are untouched. The game's own numbers come back at the end
of the match.

The one exception is the Buddy Bomb, the labradoodle that took the sheep's slot after 1.0.0: its blast is bigger than
the Plague Ram's, so Brutal gives it more than the Plague Ram's 0.70 / 170, 0.85 over 200.

| Weapon | Kindjal | Brutal |
| --- | --- | --- |
| Ripper (Bazooka) | 0.35 / 120 | 0.64 / 155 |
| Pipe Bomb (Grenade) | 0.34 / 120 | 0.45 / 110 |
| Blast Keg (Dynamite) | 0.43 / 145 | 0.90 / 200 |
| Gorger (Fatkins) | 0.72 / 220 | 1.80 / 260 |
| Earthquake Ass | 0.56 / 185 | 1.30 / 280 |
| Crucible | 0.62 / 185 | 1.35 / 195 |
| Buddy Bomb (Sheep) | 0.50 / 175 | 0.85 / 200 |

The log line `kindjal-brutal 1.0.0: N fields applied, M refused` says how many writes landed; a refused field is logged
as a warning and skipped.

## Limits

- The sentry's shot container (`kWeaponSentryGunPayload`) may be refused by the engine, as in Kindjal itself; the log
  says so.
- Not yet played in a match.

## Licence

MIT, see `LICENSE`.
