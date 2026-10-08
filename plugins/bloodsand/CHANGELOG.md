## 1.2.0

Much gorier, and it looks like flesh. A worm's intestines are now ray-marched, simulated tubes: a sixteen-point chain
that slides out of the torn belly, sags, drags and piles up on the ground, stays out of the worm's body, stretches when
the worm is knocked and slides further out with every hit, drawn as ridged, segmented tubes from pale pink-grey to deep
purple-red with veins, a film of blood, wet highlights, light through the thin wall and shadow where they touch the worm
and the ground (a new Post-FX pass, `bloodsand/guts`; the flat ribbons of 1.1 are only drawn if it cannot run). Wounds
and the torn belly are layered: a rolled, lit lip of skin, yellow fat, dark red muscle and a cavity that darkens with
depth and shifts with the camera, with coils inside the belly. Blood on the skin is wet, with a sheen, darker and
glossier pools and beads running down. Burning is new: a char-black patch with a glowing edge and flickering embers that
fades over four seconds.

Every melee and special weapon now has its own spray, scaled by Blood: the baseball bat flings a wide arc of long
streaks and heavy clots, the prod squirts a thin pulsing jet and then dribbles, the fire punch gushes charred drops up
with embers, steam and smoke and scorches the worm, No more nails fires small jets in a cone, the concrete donkey and
Fatkins flatten a worm into a ring and a pool, the old woman and Scouser shred it into fine fast drops, the ninja rope
smears, falls splat, the shotgun and sniper rifle put an entry puff in front and a fast cone out behind, and the poison
arrow leaves a dark dribble. Hits are matched to weapons from the weapon the active worm holds or fired and the worms
near it. The Preview menu item steps through them. New soft steam and smoke puffs, charred droplets and heavy clots.

Blood now lands on things. The ground stains are replaced by decals: a droplet that hits the ground or a wall leaves a
splat shaped by how it arrived (a round splat with satellite specks when it came down steeply, a teardrop streak with
drips on a wall), pools spread over about two seconds, and fresh blood is wet and glossy and dries to dark matte brown
with a clotted rim over 30 to 60 seconds (settings in the Post-FX panel). There are 32 of them instead of 8, on floors,
walls and overhangs. Droplets are layered, lighter-edged and stretch as they fly. On Melange 0.6 and later, plugins can
ask where the terrain is (`wum.game.landRay`) and see how fast a worm moves: Bloodsand uses these for the droplets'
collision, for the guts to lie on slopes and for sharper knock and fall detection. On older Melange the droplets fly
through the ground, the guts lie on a flat ground and everything else works as before. Needs Melange 0.3.5 or later.

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
