## 1.0.0

First release. Worms throw blood the moment they are hurt, away from the explosion and sized by the damage, bleed for
a while afterwards and burst when they die. Hit worms wear blood on their skin that stays with them as they move, and
worms low on health open gaping wounds: up to five gashes with torn edges and running blood, which close again if the
worm is healed. Blood stains the ground in a depth-projected Post-FX pass that follows the terrain, and heavy hits
spatter the camera lens. Client-only and cosmetic: it reads worm health and positions and the game's damage and
explosion messages, and only draws. Needs Melange 0.3.4 or later for `wum.postfx.setTransient`, which lets it feed the
Post-FX passes every frame without anything being written to `Melange.ini`. Settings: Blood (Off / Light / Heavy /
Absurd), Blood on worms, Blood on the ground, Splatter on the lens and Blood colour (Red / Green).
