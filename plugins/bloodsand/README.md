# Bloodsand

A client-only gore mod for Worms Ultimate Mayhem: worms spray blood when they are hit, wear it on their skin, open
gaping wounds as their health runs low, stain the ground and spatter the camera lens. Only code and original
procedurally generated art is shipped — no game file, or anything derived from one.

## What it does

- **Bursts**: the moment a worm is hurt, blood droplets are thrown from it, away from the explosion if there was one.
  The number and speed of the droplets scale with the damage.
- **Bleeding**: a wounded worm keeps dripping for a while after the hit.
- **Death**: a worm that dies throws a larger burst.
- **Blood on the worms**: a worm that was hit wears blood on its skin, and the blood stays on it as it moves. Each hit
  adds to it, healing does not wash it off and a death clears it. It is a Post-FX pass, `bloodsand/skin` (PostWorld,
  order 51), that paints the blood from the depth buffer onto the surfaces inside each worm's body. The pattern is
  held in the worm's own frame, so it travels with the worm and turns with the way it walks.
- **Wounds**: once a worm is below about two thirds of its health, gashes open on its body, more and larger the lower
  it gets (up to five), each with raw, torn edges, a dark clotted middle and blood running down from it. They close
  again if the worm is healed; the blood on its skin stays. The same `bloodsand/skin` pass paints them.
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
| Blood on worms | on / off | on | the skin pass: the blood on worms and their wounds |
| Blood on the ground | on / off | on | the stains pass |
| Splatter on the lens | on / off | on | the camera lens splatter |
| Blood colour | Red / Green | Red | the colour of droplets, stains, blood on worms, wounds and lens splatter |

The **Mods > Bloodsand > Preview** menu item throws a test burst at the active worm so you can see the current
settings without hurting anyone. It also gives that worm wounds that fade away over about twelve seconds.

## How it detects hits

The game posts a message the moment a worm is damaged, and another for every explosion with its position, damage and
radius. Bloodsand listens for both and reads every worm's health and position each frame. A hit with an explosion
bleeds away from the blast; a hit without one (a fall, a punch) is given to the worm that was just knocked or stopped
hardest. The game only takes the health off at the end of the turn, seconds later; by then the hit has been shown, so
the difference between the estimate and the real damage only changes how long the worm bleeds. Wounds follow the
worm's health, counting damage already shown. Nothing is sent back to the game.

## Client-only

`"kind": "client-only"` in `spice.json`, with no permissions (`unsafe` is false, `filesystem` is `none`). The mod only
reads game state and draws, so it cannot change the simulation.

The Post-FX values (stain positions, each bloodied worm's position, blood and wound levels) are fed with
`wum.postfx.setTransient`, which Melange neither writes to `Melange.ini` nor logs. The only thing Melange saves is
an effect being switched on or off, which happens when the first blood appears and when it is cleared.

## Cost

Measured on a desktop Radeon RX 7800 XT at 1280x720 in a live match, with Mirage's per-effect timers and the
sandbox's own timer: the stains pass takes about 0.02 ms of GPU time and the skin pass about 0.03 ms, and both are
switched off while there is no blood. The script takes about 0.06 ms a frame with bloodied worms on screen, about
0.1 ms during a burst, and under 0.01 ms with Blood set to Off. Re-measure with the *Mirage/Post-FX* panel on your
own machine.

## Limits

- Needs game build 1077 for game state. On any other build it does nothing.
- Needs Melange 0.3.4 or later, for `wum.postfx.setTransient`.
- Droplets are flat-colour shapes with no collision with the ground.
- Blood and wounds on worms are painted from the depth buffer inside each worm's volume. They travel with the worm and
  turn with the direction it walks, but they do not follow the mesh's animation, and they do not turn when a worm
  only turns to aim.
- Wounds are placed from a per-match seed, not where the hit landed.
- Hats and held weapons inside a worm's volume take blood too.
- Up to 16 worms can wear blood and wounds at once.
- No sound.

## Tools

`tools/make_splats.py` regenerates the four lens textures (`mod/textures/splat1.png` to `splat4.png`). It uses only
the Python standard library.

## Licence

MIT, see `LICENSE`.
