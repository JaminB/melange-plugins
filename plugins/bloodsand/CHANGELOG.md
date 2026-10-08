## 1.2.0 (unreleased)

Viscera that look real.

- Intestines are a new Post-FX pass, `bloodsand/guts`, that ray-marches a sixteen-point chain as smooth tubes: ridged and
  segmented, pale pink-grey to deep purple-red with veins and a film of blood, lit with a key light, a fill, light
  through the thin wall, wet highlights, a rim and shadow where the guts touch the worm and the ground. The chain is
  simulated: it sags, drags and piles up on the ground, stays out of the worm's body, stretches when the worm is
  knocked, and slides further out every time the worm is hit. It follows the terrain when Melange has
  `wum.game.landRay` (0.6 and later) and a flat ground otherwise. The flat ribbons of 1.1 are only drawn if the new pass
  cannot run.
- The torn belly and the gashes are layered: a rolled, lit lip of skin, yellow fat, dark red muscle and a cavity that
  darkens with depth and shows parallax as the camera moves; the belly holds coils in the guts' colours. Blood on the skin
  has a wet sheen, pools darker and runs in beads.
- A worm's scorch level (a charred patch with glowing embers that fades over four seconds) is plumbed through the skin
  pass for the melee code to set with `setScorch(slot, amount)`; `woundSites(slot)` gives where each wound is, in the world,
  for blood that spurts from it.

## 1.1.3

Runs on Melange 0.5. No other change.

## 1.1.2

Runs on Melange 0.4. No other change.

## 1.1.1

Fixes blood, wounds, black eyes and ground stains not being drawn at all on some machines: the shader that paints the
worms was large enough that a graphics driver could accept it and then draw nothing with it, which also discarded the
stains drawn before it. It now picks the one worm a pixel belongs to and does the long work once. Much more blood from
ordinary hits: more and larger droplets, longer bleeding, larger and darker stains, and a first hit now leaves a worm
clearly bloodied instead of speckled. Black eyes no longer fade out while a worm walks.

## 1.1.0

Badly hurt worms now show it in three more ways. Their eyes blacken as health falls: one eye first, then both. Worms
at a quarter of their health or less occasionally throw up blood. Some worms, picked at random each match, have their
intestines out once they are badly wounded: coils in a torn belly and a loop hanging from it that swings as the worm
moves. Blood, wounds and the new marks now turn with the way a worm faces, not the way it last walked. Needs Melange
0.3.5 or later, which gives plugins a worm's facing angle (`yaw` in `wum.game.worms()`). New settings: Worms throw up
blood and Intestines; black eyes follow Blood on worms.

## 1.0.0

First release. Worms throw blood the moment they are hurt, away from the explosion and sized by the damage, bleed for
a while afterwards and burst when they die. Hit worms wear blood on their skin that stays with them as they move, and
worms low on health open gaping wounds: up to five gashes with torn edges and running blood, which close again if the
worm is healed. Blood stains the ground in a depth-projected Post-FX pass that follows the terrain, and heavy hits
spatter the camera lens. Client-only and cosmetic: it reads worm health and positions and the game's damage and
explosion messages, and only draws. Needs Melange 0.3.4 or later for `wum.postfx.setTransient`, which lets it feed the
Post-FX passes every frame without anything being written to `Melange.ini`. Settings: Blood (Off / Light / Heavy /
Absurd), Blood on worms, Blood on the ground, Splatter on the lens and Blood colour (Red / Green).
