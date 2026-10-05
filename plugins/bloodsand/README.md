# Bloodsand

A client-only gore mod for Worms Ultimate Mayhem: worms spray blood when they are hit, wear it on their skin, open
gaping wounds and get black eyes as their health runs low, throw up blood and spill their intestines when they are
nearly dead, stain the ground and spatter the camera lens. Only code and original procedurally generated art is
shipped — no game file, or anything derived from one.

## What it does

- **Bursts**: the moment a worm is hurt, blood droplets are thrown from it, away from the explosion if there was one.
  The number and speed of the droplets scale with the damage, and even a light hit throws a visible spray.
- **Bleeding**: a wounded worm keeps dripping for a while after the hit.
- **Death**: a worm that dies throws a larger burst.
- **Blood on the worms**: a worm that was hit wears blood on its skin, and the blood stays on it as it moves. Each hit
  adds to it, healing does not wash it off and a death clears it. It is a Post-FX pass, `bloodsand/skin` (PostWorld,
  order 51), that paints the blood from the depth buffer onto the surfaces inside each worm's body. The pattern is
  held in the worm's own frame, so it travels with the worm and turns with the way it faces.
- **Wounds**: once a worm is below about two thirds of its health, gashes open on its body, more and larger the lower
  it gets (up to five), each with raw, torn edges, a dark clotted middle and blood running down from it. They close
  again if the worm is healed; the blood on its skin stays. The same `bloodsand/skin` pass paints them.
- **Black eyes**: below four fifths of its health a worm gets a black eye, a purple-black bruise around the eye that
  is darkest in a ring under it. One eye goes first and the other follows; both are fully black at about a third of
  its health. The skin pass paints them on the face, and they fade while a worm is thrown through the air.
- **Throwing up**: a worm at a quarter of its health or less heaves now and then while it stands still: a stream of
  blood from its mouth for about a second, every 12 to 30 seconds, leaving a small stain in front of it.
- **Intestines**: about two worms in five, picked at random each match, have their belly torn open once they are
  badly wounded (around a third of their health). The skin pass paints the opening and the coils inside it, and a loop
  of intestine hangs from it and swings as the worm moves. The loop is a short chain drawn as ribbons.
- **Ground stains**: a burst can leave a stain on the ground under the worm. Stains are a second depth-projected
  Post-FX pass, `bloodsand/stains` (PostWorld, order 50, so before Sunstone's effects). It has 8 slots and recycles
  the oldest first. Because it is projected from the depth buffer it follows the terrain, and a stain disappears
  where the terrain under it is destroyed. Stains only land on surfaces that face up, not on walls.
- **Lens splatter**: heavy hits near the camera splash blood across the lens, fading over a few seconds.

## Settings

On the Mods page:

| Setting | Options | Default | Notes |
|---|---|---|---|
| Blood | Off / Light / Heavy / Absurd | Heavy | how much blood each hit throws; Off disables everything |
| Blood on worms | on / off | on | the skin pass: the blood on worms, their wounds, black eyes and torn bellies |
| Worms throw up blood | on / off | on | the heaving of nearly dead worms |
| Intestines | on / off | on | the torn belly and the loop hanging from it |
| Blood on the ground | on / off | on | the stains pass |
| Splatter on the lens | on / off | on | the camera lens splatter |
| Blood colour | Red / Green | Red | the colour of droplets, stains, blood on worms, wounds and lens splatter |

The **Mods > Bloodsand > Preview** menu item throws a test burst at the active worm so you can see the current
settings without hurting anyone. It also gives that worm wounds, black eyes and intestines that fade away over about
twelve seconds, and makes it throw up once.

## How it detects hits

The game posts a message the moment a worm is damaged, and another for every explosion with its position, damage and
radius. Bloodsand listens for both and reads every worm's health and position each frame. A hit with an explosion
bleeds away from the blast; a hit without one (a fall, a punch) is given to the worm that was just knocked or stopped
hardest. The game only takes the health off at the end of the turn, seconds later; by then the hit has been shown, so
the difference between the estimate and the real damage only changes how long the worm bleeds. Wounds, black eyes,
vomiting and intestines follow the worm's health, counting damage already shown. Where the face and the belly are
comes from the worm's position and its facing angle (`yaw` in `wum.game.worms()`). Nothing is sent back to the game.

## Client-only

`"kind": "client-only"` in `spice.json`, with no permissions (`unsafe` is false, `filesystem` is `none`). The mod only
reads game state and draws, so it cannot change the simulation.

The Post-FX values (stain positions and each bloodied worm's position, facing and blood, wound, eye and gut levels) are
fed with
`wum.postfx.setTransient`, which Melange neither writes to `Melange.ini` nor logs. The only thing Melange saves is
an effect being switched on or off, which happens when the first blood appears and when it is cleared.

## Cost

Measured on a desktop Radeon RX 7800 XT at 1920x1080 in a live four-team match, with Mirage's per-effect timers and
the sandbox's own timer: the stains pass takes about 0.04 ms of GPU time and the skin pass about 0.07 to 0.1 ms, and
both are switched off while there is no blood. On Heavy the script takes about 0.1 ms a frame with bloodied worms on
screen and 0.3 to 0.4 ms for the second or so of a large burst; on Absurd a burst that fills the particle pool takes
about 0.9 ms. With Blood set to Off it takes under 0.01 ms. Re-measure
with the *Mirage/Post-FX* panel on your own machine.

## Limits

- Needs game build 1077 for game state. On any other build it does nothing.
- Needs Melange 0.3.5 or later, for `wum.postfx.setTransient` and the worms' facing angle.
- Droplets are flat-colour shapes with no collision with the ground.
- Everything on a worm's skin is painted from the depth buffer inside the worm's volume. It travels and turns with the
  worm, but it does not follow the mesh's animation: the game gives a worm's position and facing, not its bones.
- Black eyes are placed where the eyes are on a worm standing upright. A worm's head bobs, slumps and looks around, so
  a bruise can sit a little off the eye, and it is not drawn while a worm is thrown. Only skin-coloured pixels are
  darkened, which keeps most hats clean but also makes the bruise faint on a poisoned (green) worm or under strongly
  coloured light.
- The loop of intestine is flat ribbons. It stays outside the worm's body and above the ground under the worm, but
  does not collide with anything else.
- Wounds are placed from a per-match seed, not where the hit landed, and which worms have intestines to show is
  chosen at random each match.
- Hats and held weapons inside a worm's volume take blood too.
- A pixel takes the blood of one worm only, the one whose body it is deepest inside, so where two worms overlap on
  screen the pattern of one stops at the other.
- Up to 16 worms can wear blood and wounds at once.
- No sound.

## Tools

`tools/make_splats.py` regenerates the four lens textures (`mod/textures/splat1.png` to `splat4.png`). It uses only
the Python standard library.

## Licence

MIT, see `LICENSE`.
