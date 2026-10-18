## 1.2.0

- The acid eats Sunstone's human skin: with Sunstone 2.2's Worm skin on a tone, the acid finds the skin by the mark
  Sunstone leaves in the scene instead of by the game's peach colour (which a human tone no longer has), and lights itself
  by that worm's skin brightness, so it looks the same on a dark skin as on the peach. It still leaves blood, wounds and
  guts alone. With Sunstone 2.2 the game's peach is found by the mark too, so the acid also shows under Lunar's purple
  light. The colour test always counts too, so should Sunstone's shader not run the peach is still found. On a dark tone
  the acid covers more of the skin under it, so it reads as the poison's green, not a faint olive stain. Nothing changes
  without Sunstone 2.2.
- With Sunstone 2.2, the acid also shows on a worm seen through a ledge (the game shows the worm whose turn it is through
  what stands in front of it), a little fainter, instead of stopping in a hard line at the ledge's edge.
- The preview event (`mod.kindjal.preview`, `what = "acid"`) takes `target = "active"` to coat the active worm.

## 1.1.0

- Knockback brought back to near the game's own: every weapon now throws worms about 1.2 times as hard as vanilla, over
  about 1.1 times the reach, instead of two to three times as hard (the Ripper 0.64 to 0.35, the Gorger 1.80 to 0.72,
  the Earthquake Ass 1.30 to 0.56, the Crucible 1.35 to 0.62). Damage, blast radius and craters are unchanged.
- The Railspike, Knifeman and Rust Canister, which have no knockback in the game, get a small one.
- Knockback is tunable: `KNOCKBACK`, `REACH` and `MELEE` at the top of `mod/sim/main.lua` scale every knockback and
  reach, the three new weapons included. They live in the sim script, not on the Mods page, because the match cannot
  read Mods-page settings; the file is content-hashed, so every online player must have the same values.
- Two optional add-on plugins pick a different knockback power: Kindjal Heavy (about 1.7 times vanilla) and Kindjal
  Brutal (the 1.0.0 numbers). Enable one; every online player must enable the same one.
- Weapon descriptions no longer promise worms thrown across the map.

## 1.0.0

First release. Needs Melange 0.9.0 or later.

- Every vanilla weapon re-statted darker at match start (damage, blast radius, crater, knockback) and renamed: Nail
  Bat, Hellfist, Shiv, Railspike, Ripper, Pipe Bomb, Blast Keg, Profane Grenade, Plantain Hell, Nail Cluster, Bear Trap,
  Harpoon, Carpet Bombing, Carrion Drop, Earthquake Ass, Rabid Flock, Plague Ram, Hangwoman, Knifeman, Gorger, Dead
  Star, Slug Gun, Elephant Gun, Gibbet Turret, Plague Arrow, Rust Canister.
- Three new weapons: Acid Spitter, Acid Flask and Crucible, with their own icons and models; every renamed weapon
  gets its own panel and HUD icon.
- Models: every renamed weapon has its own held and/or projectile model (37 mesh banks), and the Airstrike and Super
  Airstrike helicopters are replaced by a black and a bone-white gunship. 19 banks are static meshes built from
  scratch; 18 are clones of vanilla skinned meshes that keep the game's rig, skin weights, animation clips and UV layout
  (see "What is derived from the game" in the README). Seen in play so far: the Nail Bat, Acid Flask and Crucible in hand.
- Acid that clings to a worm's skin, bubbles and smokes; acid puddles; melee impact sparks and hit-flash; new sounds.
- Content mod: every player in an online match needs the same version.
