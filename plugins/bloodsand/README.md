# Bloodsand

A client-only gore mod for Worms Ultimate Mayhem: worms spray blood when they are hit (with a spray of its own for each
melee and special weapon), wear it on their skin, open layered wounds and get black eyes as their health runs low, throw
up blood and spill ray-marched, simulated intestines when they are nearly dead, leave splats and drying pools on the
floors and walls where the blood lands, and spatter the camera lens. Only code and original procedurally generated art is
shipped — no game file, or anything derived from one.

## What it does

- **Bursts**: the moment a worm is hurt, blood droplets are thrown from it, away from the explosion if there was one.
  The number and speed of the droplets scale with the damage, and even a light hit throws a visible spray.
- **Bleeding**: a wounded worm keeps dripping for a while after the hit.
- **Death**: a worm that dies throws a larger burst.
- **Weapon sprays**: each melee and special weapon has its own signature, scaled by the Blood setting (see below for how
  a hit is matched to a weapon). The **baseball
  bat** flings a wide horizontal arc of long streaks with a few heavy clots and a fine mist. The **prod** squirts a thin
  pulsing jet from the contact point, then dribbles. The **fire punch** throws a gush of blackened, cauterised drops
  straight up with embers, rising steam and smoke, and asks the skin pass for a scorch mark. **No more nails** fires
  several small jets in a ragged cone. The **concrete donkey** and **Fatkins** crush: a flat ring of blood hugging the
  ground and a big pool. The **old woman** and **Scouser** shred: many fine fast drops in every direction on top of the
  blast. A **ninja rope** knock smears blood along the knock. A **fall** splats downward into a pool. The **shotgun**
  and **sniper rifle** puff at the entry and shoot a narrow fast cone out behind the victim (the sniper's is longer,
  faster and heavier). The **poison arrow** leaves an entry wound and a sickly dark dribble that goes on for a while.
  Explosions keep spraying away from the blast.
- **Blood on the worms**: a worm that was hit wears blood on its skin, and the blood stays on it as it moves. Each hit
  adds to it, healing does not wash it off and a death clears it. It is a Post-FX pass, `bloodsand/skin` (PostWorld,
  order 51), that paints the blood from the depth buffer onto the surfaces inside each worm's body. The pattern is
  held in the worm's own frame, so it travels with the worm and turns with the way it faces.
- **Wounds**: once a worm is below about two thirds of its health, gashes open on its body, more and larger the lower
  it gets (up to five). Each is built in layers: a rolled lip of torn skin that catches the light, pink-red raw
  dermis, broken patches of pale fat on parts of the torn edge only, dark wet muscle with glints and a cavity that gets
  darker the deeper it goes and shifts as the camera moves, all under a film of blood. Blood runs down from it in beads. They close again if the worm is healed; the blood on its skin stays. The same
  `bloodsand/skin` pass paints them. Blood on the skin is wet: it has a sheen, and is darker and glossier where it pools.
- **Black eyes**: below four fifths of its health a worm gets a black eye, a purple-black bruise around the eye that
  is darkest in a ring under it. One eye goes first and the other follows; both are fully black at about a third of
  its health. The skin pass paints them on the face, and they fade while a worm is thrown through the air.
- **Throwing up**: a worm at a quarter of its health or less heaves now and then while it stands still: a stream of
  blood from its mouth for about a second, every 12 to 30 seconds, leaving a small stain in front of it.
- **Intestines**: about two worms in five, picked at random each match, have their belly torn open once they are
  badly wounded (around a third of their health). The skin pass paints the opening, with a ragged lip of skin, patches of fat and
  muscle round a dark cavity that holds coils. A length of intestine slides out of it and drops to the ground: a chain
  of sixteen points that sags, drags, lies in coils and piles up on the ground (and follows slopes, with Melange 0.6's
  `wum.game.landRay`), stretches when the worm is knocked, and slides further out every time the worm is hit again. It
  is drawn by a third Post-FX pass, `bloodsand/guts` (PostWorld, order 52), which ray-marches the chain as smooth tubes
  with ridges and segmentation, and lights them: pale pink-grey to deep purple-red with veins, a film of blood, wet
  highlights, light through the thin wall, and shadow where they meet the worm and the ground. It draws up to four
  gutted worms at once, the closest to the camera. If that pass cannot run, the old flat ribbons are drawn instead.
  Without `wum.game.landRay` the gut lies on a flat ground at the worm's feet.
- **Scorching**: the skin pass can char a worm: burnt, cracked flesh, with blackened crust split into plates by dull
  dark-red fissures, a browned rim and a slight dry sheen (nothing glows, except a faint ember flicker in the cracks for
  the first half second), fading out over about three seconds. The fire punch sets it, and so does the preview.
- **Ground decals**: blood that reaches the terrain stays there. A droplet that hits the ground or a wall leaves a
  splat shaped by the way it came in (a round splat with satellite specks when it came down steeply, a teardrop
  streak when it came in low, with drips that run down a wall), and a burst or a heave leaves a pool under the worm
  that spreads over about two seconds. Fresh blood is a wet, glossy bead with a crisp edge: a thin dark line at the rim, a rounded raised shoulder that
  catches the light, a domed middle and darker clots inside; over
  30 to 60 seconds it dries to a dark matte brown with a clotted rim, and a pool cracks. The decals are a
  depth-projected Post-FX pass, `bloodsand/stains` (PostWorld, order 50, so before Sunstone's effects), with 32 slots
  on floors, walls and overhangs; the oldest and smallest are recycled first and a speck never pushes out a big blot.
  Because it is projected from the depth buffer it follows the terrain, and a decal disappears where the terrain under
  it is destroyed. Droplets only collide with the terrain on a Melange that has `wum.game.landRay` (0.6); on an older
  one there are only pools, as before. Droplets of every weapon spray and the heavy clots collide; steam and smoke do
  not. The Post-FX panel has two settings for the pass: drying time and wet gloss.
- **Lens splatter**: heavy hits near the camera splash blood across the lens, fading over a few seconds.

## Settings

On the Mods page:

| Setting | Options | Default | Notes |
|---|---|---|---|
| Blood | Off / Light / Heavy / Absurd | Heavy | how much blood each hit throws, weapon sprays included; Off disables everything |
| Blood on worms | on / off | on | the skin pass: the blood on worms, their wounds, black eyes, burns and torn bellies |
| Worms throw up blood | on / off | on | the heaving of nearly dead worms |
| Intestines | on / off | on | the torn belly and the length of intestine that comes out of it |
| Blood on the ground | on / off | on | the decals pass: splats, drips and pools, and the droplets' collision with the terrain |
| Splatter on the lens | on / off | on | the camera lens splatter |
| Blood colour | Red / Green | Red | the colour of droplets, decals, blood on worms, wounds, guts and lens splatter |

The **Mods > Bloodsand > Preview** menu item throws a test burst at the active worm so you can see the current
settings without hurting anyone. Each press shows the next weapon's signature (bat, prod, fire punch, nails, donkey,
old woman, rope knock, fall, shotgun, sniper, poison arrow, then an ordinary explosion burst, and round again), sprayed
sideways across the screen, and writes its name to the log. It also gives that worm wounds, black eyes, intestines and a
burn that fade away over about twelve seconds (the burn over three), and makes it throw up once. Press it again to see
more of the intestine slide out.

## How it detects hits

The game posts a message the moment a worm is damaged, and another for every explosion with its position, damage and
radius. Bloodsand listens for both and reads every worm's health and position each frame. A hit with an explosion
bleeds away from the blast; a hit without one is matched to a weapon and a victim.

**Which weapon.** The active worm's weapon id is remembered every frame and again when a weapon is fired (the game may
clear the id before the damage message arrives). For a hit without an explosion, the first rule that matches wins:

1. A weapon fired within its window counts: 2.5 s by default, 2 s for the shotgun, 3 s for the sniper rifle and 4 s for the
   poison arrow. The shotgun and the ninja rope get three hits per firing, everything else one.
2. A held melee weapon counts if some other worm is within its reach (bat 52, prod 42, fire punch 48, No more nails 44,
   ninja rope 46 units), unless that worm has just landed from a fall.
3. A bullet needs a worm in front of the shooter's facing, within a cone that narrows with distance.
4. A worm that was stopped from faster than 230 units a second downward gets the fall splat.
5. Anything else is the ordinary blunt hit.

Explosions of the concrete donkey, Fatkins, old woman and Scouser are recognised for 20 s after they were fired and give
every worm in the blast the weapon's signature. Any other explosion keeps the ordinary burst away from the blast.

**Which worm.** The one with the largest impulse (from its engine velocity when Melange reports one, otherwise from how
its position changes), else the nearest candidate. The spray runs from the attacker to the victim, blended toward the
real knock when one was seen.

| Weapon | Signature | Counted as |
|---|---|---|
| Baseball bat | wide horizontal arc of long streaks, a fine arc, a few straight streaks, 3 to 8 heavy clots, mist | 32 damage |
| Prod | thin pulsing jet of 10 to 20 drops for a fifth of a second, then a dribble | 15 |
| Fire punch | upward gush, mostly charred drops, embers, steam and smoke; the worm is scorched | 30 |
| No more nails | five small jets in a narrow cone, a few hundredths of a second apart | 20 |
| Concrete donkey, Fatkins | a ground-hugging ring, low clots and a big pool | 55, 45 |
| Old woman, Scouser | fine fast drops in every direction on top of the blast | 40 |
| Ninja rope knock | a smear along the knock | 14 |
| Fall | a ring on the ground, a small gush upward and a pool that grows with the fall speed | 8 to 40 |
| Shotgun | puff at the entry, narrow cone behind the victim | 22 |
| Sniper rifle | puff, a fast narrow cone and a long streak behind the victim, and a lens splat if close | 48 |
| Poison arrow | dark yellow-green entry jet and a dribble that goes on for 14 s | 14 |

The number of droplets scales with the damage counted and the Blood setting, and Blood caps what one hit can throw. The
damage counted is only an estimate for the size of the spray: the game only takes the health off at the end of the turn,
seconds later; by then the hit has been shown, so the difference between the estimate and the real damage only changes
how long the worm bleeds. Wounds, black eyes, vomiting and intestines follow the worm's health, counting damage already
shown. Where the face and the belly are comes from the worm's position and its facing angle (`yaw` in
`wum.game.worms()`). Nothing is sent back to the game.

## Client-only

`"kind": "client-only"` in `spice.json`, with no permissions (`unsafe` is false, `filesystem` is `none`). The mod only
reads game state and draws, so it cannot change the simulation.

The Post-FX values (the decals' positions and shapes, each bloodied worm's position, facing, blood, wound, eye, gut and
scorch levels, and the points of each hanging gut) are fed with
`wum.postfx.setTransient`, which Melange neither writes to `Melange.ini` nor logs. The only thing Melange saves is
an effect being switched on or off, which happens when the first blood appears and when it is cleared.

## Cost

These are estimates until they are measured in a live match on Melange 0.6. The GPU figures come from a test harness on
a desktop Radeon RX 7800 XT at 1920x1080 (GL timer queries), not from the game; the script figures from a mock of the
game, which leaves out the real cost of drawing the quads and of the terrain rays. Version 1.1 was measured in a live
four-team match: the stains pass about 0.04 ms and the skin pass about 0.07 to 0.1 ms.

- **Skin pass**: about 0.10 ms (1.1: about 0.09), only while a worm wears blood, a wound or a burn.
- **Guts pass**: only on while a gutted worm is in view. About 0.16 to 0.18 ms at the usual zoom, and up to 0.4 ms with
  the camera right on top of the guts. A pass that only copies the screen takes about 0.05 ms of that.
- **Decals pass**: about 0.03 ms with nothing on the ground, 0.1 ms with a handful of decals and a large pool, and
  about 0.2 ms for a deliberately dense pile of 32 covering a sixth of the screen. It is switched off while there are none.
- **Script**: in a stress test with six worms and explosions, weapon sprays and previews back to back, an average of
  about 0.3 ms a frame on Heavy and 0.4 ms on Absurd. A gutted worm takes under 0.1 ms and six take about 0.3 ms. With
  Blood set to Off it takes under 0.01 ms. A Lua callback may run 500000 VM instructions and Melange stops it for the
  session after three faults, so the script keeps clear of that: one frame spawns about 200 particles for bursts (the rest of
  a big blast waits a few frames in a queue, and a burst takes at most half of what the pool has left, so the worms of one
  blast share it), and only the four gutted worms nearest the camera are simulated (with one fixed step and fewer passes
  while more than two are going). In the mock host the world callback peaked at about 230000 instructions for sixteen
  worms in one Absurd blast and at about 260000 for sixteen gutted worms.
- **Terrain rays**: at most 64 calls of `wum.game.landRay` a frame, all counted together (48 for droplets, at most 24
  between the guts' 8 probes, the pools and the melee sprays' ground rays). Melange 0.6 logs their average and worst cost
  at the end of each match; a few microseconds each is expected, and if it is more, the droplets' share is what to lower.
- **Resend**: every two seconds everything is sent to the effects again as insurance; this is spread over 17 frames so no
  single frame makes more than about 80 `wum.postfx.setTransient` calls.

Re-measure with the *Mirage/Post-FX* panel on your own machine.

## Limits

- Needs game build 1077 for game state. On any other build it does nothing.
- Needs Melange 0.3.5 or later, for `wum.postfx.setTransient` and the worms' facing angle.
- Melange 0.6 adds `wum.game.landRay` and the worms' velocity, which Bloodsand uses when they are there. Without them
  droplets do not collide with the terrain (the ground only gets pools), the guts lie on a flat ground at the worm's
  feet and knocks and falls are read from how the worm's position changes. Everything else works the same. If
  `landRay` answers "unavailable" (for one odd level, say) the plugin goes without it for ten seconds and again at the next
  match start, instead of for the rest of the session.
- A weapon's signature depends on seeing its weapon id on the active worm. If a build of the game clears it before the
  hit and no firing message came, the hit gets the ordinary blunt burst instead. A held melee weapon (no firing message)
  needs a worm within reach that was also knocked just then, so an unrelated hit next to a worm holding a bat is not
  taken for a bat swing, but a poke that moves nobody shows nothing. The spray shapes, the fall
  threshold and the reach distances are untuned guesses until seen in the game. A melee hit that the game reports as an
  explosion takes the ordinary burst.
- Everything on a worm's skin is painted from the depth buffer inside the worm's volume. It travels and turns with the
  worm, but it does not follow the mesh's animation: the game gives a worm's position and facing, not its bones.
- Black eyes are placed where the eyes are on a worm standing upright, on the side the game's facing angle says is the
  front (the facing is `(sin yaw, 0, cos yaw)`, the same one the blood and the belly use), and only on surfaces that
  face that way, so never on the back of the head. A worm's head bobs, slumps and looks around, so
  a bruise can sit a little off the eye, and it is not drawn while a worm is thrown. Only skin-coloured pixels are
  darkened, which keeps most hats clean but also makes the bruise faint on a poisoned (green) worm or under strongly
  coloured light.
- The intestines come out of the belly opening that the skin pass paints, so they need Blood on worms (and are off with it).
  They are ray-marched in a screen-space pass. They stay out of the worm's body (a guessed capsule) and on the
  ground below them, but they do not collide with other worms or with walls, and at most four gutted worms (the closest
  to the camera) are drawn at once. They are lit by a fixed key light and the camera, not the level's lights. Where the
  opening sits on the belly was set by eye and may need adjusting.
- Decals are projected from the depth buffer: there are 32 of them, and a pixel shades at most four. Where more than
  four overlap, the ones that hold the pixel least deeply are dropped (a pool with many splats on it can still show a
  hard edge here and there), and a decal vanishes where the terrain under it is destroyed. Droplets are tested against the terrain only, not
  against worms, crates or water.
- Wounds are placed from a per-match seed, not where the hit landed, and which worms have intestines to show is
  chosen at random each match.
- Hats and held weapons inside a worm's volume take blood too.
- A pixel takes the blood of one worm only, the one whose body it is deepest inside, so where two worms overlap on
  screen the pattern of one stops at the other.
- Up to 16 worms can wear blood and wounds at once.
- The guts shader repeats its shape function several times and was tried on one AMD driver only. Another driver could
  link it and draw nothing; the flat ribbons of 1.1 are drawn instead if Melange reports the pass as failed (checked every
  two seconds). The skin and stains shaders are big as well and were tried on the same driver only; they have no
  fallback, so if Melange reports one as failed Bloodsand writes a line to the log and stops feeding it (no droplet rays,
  no guts).
- No sound.

## Tools

`tools/gen_guts.js` writes `mod/postfx/guts/guts.frag` and `effect.ini` from `tools/guts.frag.in` (run it with Node from
this folder): the four worm slots of sixteen chain points are separate parameters, so the declarations are generated.
Edit the template, not the generated files.

`tools/make_splats.py` regenerates the four lens textures (`mod/textures/splat1.png` to `splat4.png`). It uses only
the Python standard library.

## Licence

MIT, see `LICENSE`.
