# Kanly

A client-side plugin for Worms Ultimate Mayhem that adds a game style and four Weapon Factory presets to the vanilla
menus. Kanly is Dune's word for a formal vendetta fought under agreed rules. Only data is shipped: no code, no game
file, and nothing derived from one.

## What it does

- **A Kanly game style**: a short, hard match. It is the Standard style with a five minute round, after which sudden
  death starts and the water rises fast, and a loadout where every weapon is available from the start.
- **Four Weapon Factory presets**: Kanly Red, Kanly Blue, Kanly Green and Kanly Yellow, each a vanilla preset with a
  few numbers changed.

## How to use it

1. Enable the plugin in Melange (needs Melange 0.5.0 or later) and start the game.
2. Choose the style in **Local Game > Versus > Deathmatch > Game Style > Kanly**. The same list is used by the other
   local modes. The list is alphabetical, so Kanly sits between its neighbours.
3. A team's custom weapon is chosen in **My Worms > Customise > Edit Team**. The Kanly presets are in the list of
   Weapon Factory presets there.

## The style

Everything not listed here is as in Standard (100 health, two wins, 45 second turns, the same crates).

| Setting | Kanly | Standard |
| --- | --- | --- |
| Round time | 5 minutes | 20 minutes |
| Sudden death | Raise Water | Raise Water |
| Water rise speed | Fast | Medium |

In the game's own style editor these are the Sudden Death and Water Rise Speed options (in the scheme data,
`SuddenDeath` 0 is 1 Health, 1 is Raise Water and 2 is Draw Round; `WaterSpeed` 1 to 3 is Slow to Fast). When the
round clock runs out the water starts to rise, and it rises fast.

### Loadout

Every weapon has no delay. Ammo per weapon:

| Weapon | Ammo |
| --- | --- |
| Airstrike | 2 |
| BananaBomb | 2 |
| BaseballBat | 10 |
| Bazooka | 10 |
| ClusterGrenade | 2 |
| ConcreteDonkey | 1 |
| CrateShower | 2 |
| CrateSpy | 5 |
| DoubleDamage | 2 |
| Dynamite | 10 |
| FirePunch | 2 |
| GasCanister | 10 |
| Girder | 5 |
| Grenade | 2 |
| HolyHandGrenade | 2 |
| HomingMissile | 2 |
| Jetpack | 5 |
| Landmine | 10 |
| NinjaRope | 5 |
| OldWoman | 10 |
| Parachute | 5 |
| Prod | 2 |
| SelectWorm | 2 |
| Sheep | 10 |
| Shotgun | 10 |
| SkipGo | 2 |
| SuperSheep | 2 |
| Redbull | 2 |
| Flood | 1 |
| Armour | 2 |
| WeaponFactoryWeapon | 2 |
| AlienAbduction | 2 |
| Fatkins | 2 |
| Scouser | 10 |
| NoMoreNails | 2 |
| PoisonArrow | 2 |
| SentryGun | 2 |
| SniperRifle | 2 |
| SuperAirstrike | 2 |
| BubbleTrouble | 2 |
| Starburst | 2 |
| Surrender | 3 |
| Binoculars | 5 |

Weapons Standard gives 0 or 1 of (the super weapons) get 2, except Concrete Donkey and Flood, which get 1. Utilities
(Girder, Jetpack, Parachute, Ninja Rope, Binoculars, Crate Spy) get 5. Surrender keeps its 3. Everything else gets 10.
The 15 mystery crate entries are left as in Standard. Weapons Standard gives unlimited uses (Baseball Bat, Shotgun,
Girder, Parachute) now have a finite count.

## The presets

| Preset | Based on | Changes |
| --- | --- | --- |
| Kanly Red | Wipe Out | Worm damage 1.0 to 1.15 |
| Kanly Blue | Chatter Bomb | Worm damage 1.0 to 1.2, land damage radius 0.4 to 0.6 |
| Kanly Green | Knee Trembler | Cluster is poisonous |
| Kanly Yellow | The Peace Breaker | Weapon push 0 to 0.8 |

All four are stock presets.

## Sudden-death music

When sudden death starts, the game's sudden-death track is replaced by the four Kanly tracks, in a random order per
match, chained one after another. The first track is never the same as the previous match's first track. Each machine
picks its own order, so players in the same match may hear different orders. The vanilla sudden-death commentary stays.

| Title | Original title |
| --- | --- |
| Ash Ridge | Slaughter at Ash Ridge |
| Ash Ridge Reprise | Slaughter at Ash Ridge (second mix) |
| Alabaster Purge | The Alabaster Purge (violin) x Ashes of Elysium (piano) mashup |
| Elysium Ashes | Ashes of Elysium (piano) x Ashes of Elysium mashup |

The music files are the author's own work.

## Client-only

`"kind": "client-only"` in `spice.json`, with no permissions (`unsafe` is false, `filesystem` is `none`). The plugin
declares a `schemes` entry and four `factoryWeapons` entries, which Melange adds to the game's own lists at the
frontend. A host's style reaches the other players by the vanilla protocol, and a team stores only the preset's name,
so peers do not need the plugin. A peer without it may see the raw key (`FETXT.Scheme.Kanly`) as the style name in the
lobby; this has not been verified.

## Limits

- Needs Melange 0.5.0 or later and game build 1077.
- The style appears as a permanent built-in style: it cannot be edited or deleted in game.
- The settings are fixed in the plugin's files; to change them edit `mod/schemes/kanly.json`.
- The music is only heard by players with the plugin. Tracks are joined with a hard cut. Only the sudden-death slot
  exists.
- That the presets are listed in the team editor is expected to work the same way as the style but has not been
  verified in game.

## Licence

MIT, see `LICENSE`.
