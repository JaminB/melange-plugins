## 1.3.1

Runs on Melange 0.7 and every later version: the plugin no longer names an upper Melange version, so a new
Melange release no longer moves it to `Mods\.incompatible`. No other change.

## 1.3.0

Gorier again: worms spurt blood, leave trails and pools, and come apart. Three new things that work together, each with
the Blood setting to turn it down and (for the gibs, and the trails and pools) a setting of its own, both on by default.

Gibs. A worm that dies, and one that takes a very big hit (45 damage or more, 30 on Absurd), now throws chunks of meat,
shards of bone and a few organs (a kidney, a liver lobe, a heart, an eyeball on its stump of nerve), with small bits of meat
flying out around them, and they stay: up to 16 on Absurd (14 on Heavy, 8 on Light), the oldest recycled. They are ray-marched
signed distance fields drawn by a new Post-FX pass, `bloodsand/gibs` (PostWorld, order 53, after the guts): flesh is dark red with
lighter fibres, cream marbling, silverskin and fibrous tear faces, bone ivory with a jagged, hollow, porous break, the eye
bloodshot with an iris and a pupil; all wet and glossy with light through the thin flesh at first, drying over about a minute to
a dark, brown, matte finish. The organs and bones were reworked after the first in-game look (they read as glossy pills, cigarette
butts and a tomato): the liver is a dark maroon lobed wedge with a thin sharp edge, a cleft, a vessel stub and torn raw faces; the
kidney a bean with a hilum, fat and the cut stubs of its vein, artery and ureter; the heart a leaning cone with a groove, a lumpy
cap of fat and the hollow, obliquely torn ends of its great vessels; new lung lobes and loops of intestine; bones are ivory, matte
and porous, a long bone with a knobbed joint end, a shaft snapped at both ends, a curved rib or a shard, each with splintered
breaks round a hollow marrow cavity and on some a rag of red meat still clinging; some meat chunks are fatty or dark. The wet
sheen is a thin, patchy, weak film (no glassy glint), with dark clotted blood in the crevices. A gib (and its bits) fades out
between 60 and 25 units from the camera and is gone nearer, one that would fill much of the screen fades too, and in the aim
view (the camera within 40 units of the active worm) the ones near the camera or the worm are hidden so they never block the
aim. They fly with spin, bounce, roll and slide on the terrain (`wum.game.landRay`; on the plane at the
worm's feet without it), come to rest lying on their flattest face and sleep (no rays, nothing sent to the effect), and leave
a splat where they land hard, a streak where they slide and a pool where they lie. An explosion near them throws them again, and
flesh in the middle of its crater is blown into bits; ground dug out from under one lets it fall. A new setting, Gibs (on),
and Preview throws some. If the pass cannot run each gib is drawn as a flat sprite. A frame throws at most twenty gibs between
all the worms that die in it, so a blast that kills the whole pack does not spend its time recycling what it has just thrown.

Blood trails and pools (the new setting "Pools & trails", on by default, which needs Blood on the ground). A worm below
two thirds of its health leaves a line of drips behind it as it walks, and below a quarter of it a smear where it drags
itself, laid on the ground under the worm (slopes included, with Melange 0.6's `wum.game.landRay`). The drips are beads of
every size, one every 8 to 15 units in clusters with bare stretches between, now and then a big splat with a satellite drop
behind it, each a few units across, so that the line reads from the usual play distance. The smear is a stripe of the worm's
own width, streaked along the drag with thicker, darker edges, thinner and drier the further the worm has dragged itself
since its last hit (a hit brings fresh blood), now and then broken for a body length, and pieces are laid overlapping so
that it is one continuous stripe, not dashes. A worm that is dying, or hurt and
lying still, slowly grows a pool under it over six to eight seconds, which stays wet while it spreads and dries later; and
after a worm blows up its grave sits in a pool with smears running out of it and a spatter of splats around.
Light, Heavy and Absurd scale the size, the number of trail pieces (5, 8 and 12) and the smears round a grave (2, 3 and 5).
A trail is a straight strip that the worm lengthens as it goes, two new decal kinds of the stains pass (a dotted line of
drips, and a smear), so it costs a decal slot for every 30 to 50 units and not one for each step; the oldest goes first.
The pass stays within 2% of its old cost (5% in a view full of drip pieces; measured with native GL at 1080p) and keeps its 32 slots: 48 would have cost
21% more with everything in use. Melange's CreateGravestoneMessage has no decoder, so the grave is where the worm was
last seen. Trail and pool pieces follow the same rules as any decal on a worm and on smoke (a pool takes surface up to about
50 degrees from its plane, a grey pixel off the plane is skipped, and a worm's wider volume stays clear of blood however
close its flank is to the plane), so a smear no longer paints a worm standing on a slope.

Arterial spurts. A worm below about a third of its health spurts blood from its deepest open wound in time with a
heartbeat (1.1 to 1.6 beats a second, faster the lower it is, slightly irregular, often with a weaker second beat): each
beat is a pressurised stream, a continuous arc of thin dark-red tubes of blood (a new sprite, `bs_jet.png`, no glint) laid
at a steady rate along the arc and closer together than they are long, thinning and breaking into beads at the far end,
a few beads flying ahead of it, a short sputter after the beat, a fine mist puff at the wound and a weak dribble between
the beats. The jets follow the worm as it moves and turns, land through the existing droplet
collision and leave splats and streaks, pause while the worm is thrown or falling and come back stronger after it lands,
start stronger after a new hit and weaken and stop on a dying worm. One wound spurts on Light and Heavy, two on Absurd. The
previewed worm spurts for a few seconds. They follow the Blood setting and have no setting of their own.
The gashes (and so the spurts) now sit on the middle of the body, not the head: their elevation runs from -0.6 to 0.4 radians
about the body's middle, from -0.35 to 0.75 before (the highest wounds were at three quarters of the worm's height, under
its head), which puts them 6 to 16 units above the feet. The wound sites that the code computes (`woundSites`) are now where `skin.frag` draws the gashes: it used to put them
up to 0.14 of a unit direction off (a unit or two at the upper wounds) and the belly opening about a unit and a half too
high, because the shader finds a gash along the ray from the body's middle in the ellipsoid's own space.

Working together. All three draw on the same limits, which are shared out so that none starves the others. The 32 decal
slots: the spray of a spurting worm used to push the trails and pools it leaves out of them within seconds, so a new splat
now leaves a pool or a trail piece alone while it is still fresh (about fifty seconds for a piece, a minute or more for a
pool), as long as pools and pieces take no more than 18 of the slots, which leaves 14 for splats. The 64 terrain rays a frame:
the flying gibs take up to 20 and go first, the droplets (the spurts' too) up to 48, and the trails, pools, guts and melee
sprays, which can wait a frame, what is left under 24. The frame's spawn budget: bursts first, the spurts after them with 40
spawns kept back for the bursts and no more than 60% of the pool, the gibs' bits of meat (up to 96, sprites) apart from
both. Preview throws a very big hit's worth of gibs (a death's worth every third press), lays a trail piece and a pool and
makes the worm spurt. The insurance resend is still spread over 17 frames.

Needs no new Melange: the sprites, `landRay` and the worms' velocity of 0.6 are used where there, with fallbacks. Costs, in
the test rig at 1080p: the gibs pass about 0.18 ms with sixteen on screen (nothing while none may be seen), the stains pass
within 2% of what it was; in the mock host the script averages 170000 to 210000 VM instructions a frame, and peaks at about
330000 (the limit is 500000), with sixteen badly hurt worms on Absurd crawling, spurting and trailing, then big hits and
thirteen deaths. A few badly hurt worms spurting now make the script's steady cost about two and a half times what it was
in 1.2 (eight worms on Heavy, four of them at 15 health: 113000 instructions a frame, from 42000), nearly all of it the droplets.

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

Seen in the game, third round. Skin: a worm hidden behind a ridge or a dune no longer paints it (the skin pass chose any
pixel inside a worm-sized ellipsoid whose colour passed as skin, and bright sunlit sand does; now a pixel has to lie on a
shell the width of the body round the worm's axis, upright along the body, facing away from the axis, and have depth that falls
away to one side, as a worm's does and a ridge's face does not); the black eye is a smooth bruise (its ring was found with
taps turned by a random angle at every pixel, which came out as grain) that shows at mid range on a worm at 40 to 70 health (the
level went from 0.2 to 0.8 over that range and the first eye was only opaque by half; now 0.39 to 0.91, and a level scales the
bruise's size before its opacity), and it keeps off the moustache; a poisoned worm's yellow skin is accepted down to a
brightness of 0.74 instead of 0.85, so it no longer flips in and out of the mask from pixel to pixel (blotches with hard
edges). Decals: smoke that hangs low over a pool, a worm's flank or tail where the pool's plane crosses it, and a worm
standing on a slope are no longer painted (a pool takes surface up to about 50 degrees from its own, grey pixels off the
plane are skipped, the worm's volume is wider, stays solid up to its edge, and keeps everything that is not ground clear even
where it crosses the plane); wet blood has the sky in it (Fresnel) and a broad soft sheen, a pool's colour moves with its
thickness and with the light there, and in shade it is no longer a flat dark.

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
