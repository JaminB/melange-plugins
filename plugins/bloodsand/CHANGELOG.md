## 1.2.0

Much gorier, and it looks like flesh. A worm's intestines are now ray-marched, simulated tubes: a sixteen-point chain
that slides out of the torn belly, sags, drags and piles up on the ground, stays out of the worm's body, stretches when
the worm is knocked and slides further out with every hit, drawn as ridged, segmented tubes from pale pink-grey to deep
purple-red with veins, a film of blood, wet highlights, light through the thin wall and shadow where they touch the worm
and the ground (a new Post-FX pass, `bloodsand/guts`; the flat ribbons of 1.1 are only drawn if it cannot run). Wounds
and the torn belly are layered: a rolled, lit lip of skin, yellow fat, dark red muscle and a cavity that darkens with
depth and shifts with the camera, with coils inside the belly. Blood on the skin is wet, with a sheen, darker and
glossier pools and beads running down. Burning is new: a burn where the worm was hit (a singed halo, leathery brown skin with blisters and
a black crust cracked by dull dark-red fissures, no lava glow, only a faint ember flicker in the cracks for the first half
second) that fades over three seconds. The skin pass takes its surface normal from the depth of each pixel's own
neighbours instead of the GPU's 2 by 2 block derivatives, so blood and wounds no longer break into blocks at a worm's
silhouette, and its edge is anti-aliased about a pixel wide.

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
walls and overhangs. Overlapping decals are one body of blood with one outline, rim and shoulder (no decal's border shows
inside another, and a speck beside a blot runs into it); splats vary in size (a long tail from specks to big blots,
finer when the hit was fast), outline, stretch and number of satellite drops; and blood no longer lands on worms, smoke,
silhouettes or the wall behind a pool, and fades out as the camera comes up to a stained surface. Droplets stretch as
they fly. On Melange 0.6 and later, plugins can ask where the terrain is (`wum.game.landRay`) and see how fast a worm moves: Bloodsand uses these for the droplets'
collision, for the guts to lie on slopes and for sharper knock and fall detection. On older Melange the droplets fly
through the ground, the guts lie on a flat ground and everything else works as before. Needs Melange 0.3.5 or later.

Keeps clear of Melange's instruction limit (a Lua callback that runs 500000 VM instructions is stopped, and after three
faults the plugin would be off for the session): a frame spawns about 200 particles for bursts and queues the rest, only
the four nearest gutted worms are simulated, the two-second resend is spread over 17 frames, and a blast is dropped from
the match list before its worms are processed. Droplets that fly fast between ray tests are still swept from where they
were last tested, so they leave a splat instead of falling through the ground. All terrain rays are counted together (at
most 64 a frame) and are tried again after "unavailable" instead of being off for the session. Engine-velocity knock
detection now works (it compared a value with itself), and the check of the velocity's units no longer trips on walking.
A held melee weapon only counts for a worm that was knocked, and a donkey's blast no longer explains a later fall.
Intestines need Blood on worms. Where more than four decals overlap, the least deeply held ones are dropped instead of
whole decals being cut off along a circle, and two overlapping gutted worms both draw their guts.

Droplets, mist and steam were flat diamonds and see-through squares; they are round now (as triangle fans; on Melange 0.6
and later they are textured sprites, below). A droplet is a teardrop with a
rounded head and a tapering tail, a fainter fringe of its own colour for an anti-aliased edge, and no white square (only
a tiny faint glint on a big one up close). Far droplets are one thin streak and ones narrower than two pixels are grown a little, so
blood reads at the distance the game is played from; a burst far from the camera throws bigger droplets and more mist.
Mist is a fine red haze and steam a pale grey one, both soft blobs of several translucent layers with an irregular
outline instead of squares. Nothing is drawn nearer than 12 units to the camera and what is just beyond fades in, so no
droplet fills the screen. The fire punch throws blood and a few small burnt flakes (dark cooked blood, soot and ash)
instead of glowing orange drops, with a few faint embers that last a third of a second, and its steam is shorter. The lens splatter is now a Post-FX pass
(`bloodsand/lens`) that runs before the HUD, so it no longer covers the minimap and the timer, and it looks like blood on
glass: the view bends through it, blurs a little, is tinted and darkened, with a highlight along the edge and drips that
run down (the flat HUD splats are only used if the pass cannot run). A death now always throws the big burst and leaves a
pool: it is shown when the worm blows up, which is seen as an explosion at a worm whose health has run out, its state
flipping to dead or its disappearing from the worm list (before, only a state flip was watched, so a worm that went
without one, or only after its body was gone, left nothing; a burst at the moment its health ran out was lost in the
smoke of the hit and the bleeding, with nothing at the death itself), it throws heavy clots that carry past the smoke,
it may overspend a frame's spawn budget, waits longer in the queue and makes room in a full pool, and its pool goes down
in the crater the worm leaves. Bigger stains from big hits and a bigger death pool.

Skin pass: only skin takes anything. A classifier on the scene colour (the ratios of green and blue to red, which light
only scales, with the blue limit rising where sun clips the red) gives each pixel 0 to 1 skin, and everything painted on
the worm (blood, wounds, scorch, the belly, black eyes) is multiplied by it, on the whole body: helmets, hats, glasses,
headbands, bunny ears and the eyes stay clean, and the edge is soft. The blood is no longer a marbled coat: it is soaked
round the wounds and the place the worm was hit, runs down in streaks that thin to a bead, is smeared and spattered on the
hit side and thin elsewhere; none of it is placed from the depth buffer's facets. Black eyes are a clear ring hugging each
eye white (found from the screen, so it follows the head), darkest under the eye, with a lit lip above.

Seen in the game, second round: a helmet, a cowboy hat and an orange moustache still took paint. The classifier now also
tests hue and saturation, measured on the game's own frames (skin is 21 to 28 degrees and 0.60 to 0.69 saturated in the
desert's light, 0.45 to 0.49 in the snow's; a cowboy hat is 34 to 40 degrees, a helmet 47 to 51, brown fur 31 to 36, an
orange moustache 0.76 and up in saturation), with the limits relaxed where sun clips skin to cream and tightened a little
above the eye line and round the mouth; the old test passed 100% of the cowboy hat's pixels and the new one none. The
scorch is one burn on the chest on the side the worm was hit from (a singed halo, leathery brown skin with blisters, a
black cracked crust), no longer a marbled pattern over the whole body and the back of the neck. The black eye is a wider,
darker ring with a swollen lower lid that is still a few pixels wide from across the level, and darker at lower health.
The four effects are switched on for five frames each at the start of a session's first match, so that their first-use
compile and driver build (several milliseconds per effect, 11 to 19 for the stains) are not paid in the middle of a fight.

Seen in the game and put right: blood on a pillar or a faceted rock is no longer cut into strips at the facet edges (a
decal takes surface turned up to about 60 degrees from its own and near its plane by a tolerance that grows away from
the middle, and every pixel's normal comes from its own neighbours, so no edge steps in twos); an explosion's crater
takes the decals in it, so a pool no longer leaves dark bands on the crater's walls or a bar over the water; hats and
helmets stay clean of decals (the worm's volume is taller; the skin pass keeps them and everything else that is not skin
clean, above); the eyes stay clear and a black eye shows through the blood on a bloodied face; the
wounds and the blood's sheen are lit from a smooth normal, so the worm's mesh facets no longer show as angular shards,
and edges inside the worm no longer leave bright yellow lines of bare skin; blood on the ground fades out between 48
and 18 units from the camera, so the aim camera in front of a bloodied rock is no longer half red; a big pool is a
flat film with a broad faint sheen instead of a domed jelly with one round highlight; a lens splat drains away from its
thin parts instead of fading into a pale outlined ghost; droplets are thin streaks with a pixel-wide fringe of their
own colour instead of petals with a lighter rim and a dot, and the fire punch throws a few small burnt flakes
instead of a cloud of black confetti. Without Melange's Post-FX API the plugin no longer stops at load.

On Melange 0.6 and later (which has `wum.draw.sprite`, soft textured world sprites) the particles are drawn with textures
instead of flat triangle fans, which is what made droplets read as hard-edged leaves: a droplet is one sprite of a wet,
shaded teardrop (a dense core, a soft edge about a pixel and a half wide, a dark rim, a baked glint and a tail that thins
out) stretched along its velocity, a heavy clot is a lumpy glossy blob (four shapes), mist and steam are soft rotated puffs
of noise (three and two shapes), burnt flakes are ragged flecks (two), and a big close droplet also gets a small additive
white spark. All tinted per particle with the blood colour (so green blood works), at the same sizes, stretch, near-camera
fade and size limits as before. Each is one call instead of two to six quads, so the script's instruction count drops by a
third on a big blast (a 12-worm Absurd blast peaks at 175000 VM instructions instead of 258000). The sprites are drawn after
the world's other primitives, depth-tested and sorted back to front with other mods' sprites, and a change of texture
in that order costs a draw call, so there are only fourteen small textures (`mod/textures/bs_*.png`, about 155 KB, made by
`tools/make_blood_sprites.js`); a frame draws about 500 at most and a blast peaks at about 280 draw calls a frame. Bloodsand
checks the call once with a sprite of no width, and if it raises, a kind has no textures or a texture will not load, that
kind keeps the fans (older Melange, 0.3.5 to 0.5, always does). Melange 0.6 also gives every texture mipmaps and trilinear
filtering, which only makes the flat HUD lens splats smoother when scaled down. Terrain rays (`wum.game.landRay`) and worm
velocity are also 0.6; each feature falls back on its own, so one plugin runs from Melange 0.3.5 to 0.6.

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
