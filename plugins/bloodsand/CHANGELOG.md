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
