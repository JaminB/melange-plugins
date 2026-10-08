-- Bloodsand: blood bursts when worms are hit, bleeding afterwards, blood and gaping wounds on the worms' skin,
-- blackened eyes and intestines on badly hurt worms, vomiting blood, stains on the ground and splatter on the lens.
--
-- It only reads game state (worm health, positions and facing, damage and explosion messages, the camera) and draws. It
-- never changes the simulation, sends anything or asks for a permission, so every player sees their own blood.
--
-- Droplets (teardrops), mist and steam (soft blobs) are small triangle fans of world quads drawn from one "world" callback. The ground decals are the bloodsand/stains post-FX
-- effect (32 slots of splats and pools on any surface; a droplet that meets the terrain, seen with wum.game.landRay where
-- Melange has it, leaves one), the blood, wounds, black eyes, scorching and the torn belly painted on a worm are
-- bloodsand/skin (sixteen slots that follow the worms) and the intestines that hang out of a torn belly are
-- bloodsand/guts (up to four worms), a chain simulated here and ray-marched there; all three are fed with
-- wum.postfx.setTransient, which writes nothing to Melange.ini. The lens splatter is the bloodsand/lens post-FX effect, which
-- runs before the HUD (only if it cannot run are the splat textures drawn at the "hud" stage instead).
-- Gibs (meat, bone and organs thrown by deaths and very big hits) are the bloodsand/gibs post-FX effect, ray-marched, and are simulated in
-- the == Gibs == section near the end of this file.

if not (wum.draw and wum.draw.on and wum.game and wum.game.worms) then return end

local DEBUG = false

-- Per "Blood" setting: the most live particles, droplets per point of damage, mist puffs per burst, a multiplier for
-- the bleeding rate and the most splats one burst puts on the lens.
local AMOUNT = {
    light  = { max = 120, perDamage = 1.0, mist = 3, bleed = 0.6, lens = 1 },
    heavy  = { max = 300, perDamage = 2.4, mist = 6, bleed = 1.0, lens = 2 },
    absurd = { max = 480, perDamage = 4.5, mist = 10, bleed = 1.8, lens = 3 },
}
local POOL_MAX = 480
local BURST_MAX = 170           -- droplets in one burst, however much damage it was
-- A Lua callback may run 500000 VM instructions (Melange stops it after three faults for the rest of the session), and a
-- spawned particle costs a few hundred. So one frame spawns about SPAWN particles for bursts; a burst that finds the budget
-- spent waits in a queue of QUEUE entries for the next frames (and is dropped after QUEUE_SECS), and a burst never takes
-- more than half of the room the pool has left (but FAIR_MIN at least) so the worms of one blast share it.
-- A death is the one burst that must never be lost: it may overspend the frame's budget by DEATH_EXTRA, waits in the queue
-- DEATH_QUEUE_SECS instead of QUEUE_SECS, and pushes older particles out of a full pool to make room for DEATH_ROOM of its own.
-- A worm that vanishes from the worm list is taken to have died (its blood is thrown) after GONE_SECS.
-- A worm whose health reaches 0 is dying: the game blows it up seconds later (at the end of the turn, once the damage has
-- been counted down), and the death burst waits for that: for its state to turn dead, for it to leave the list, or for an
-- explosion within DYING_REACH of it at least DYING_MIN seconds after its health ran out, and at most DYING_SECS.
-- The death throws DEATH_CLOTS heavy clots as well, which land and splat around the crater.
local BUDGET = { SPAWN = 200, MIN_LEFT = 30, QUEUE = 24, QUEUE_SECS = 0.75, FAIR_MIN = 24, spawned = 0,
                 DEATH_EXTRA = 120, DEATH_QUEUE_SECS = 3, DEATH_ROOM = 90, evicted = 0, GONE_SECS = 0.3,
                 DYING_REACH = 30, DYING_MIN = 0.4, DYING_SECS = 40, DEATH_CLOTS = 14 }
local BURST_BASE = 8            -- every hit sprays as if it did this much more damage, so a light one still shows
local DEATH_DAMAGE = 75         -- a death counts as this much damage
-- A burst this far from the camera (world units) throws bigger droplets and more mist, up to +45% and double at FAR_START + FAR_SPAN,
-- so that it still reads from the usual play distance.
local FAR_START, FAR_SPAN = 250, 900

-- World units and seconds. A worm is about 30 units tall and +Y is up.
local GRAVITY = -420
local DRAG = 0.6                -- fraction of speed lost per second
local MIST_GRAVITY = 0.15       -- mist falls much more slowly than droplets
local MIST_DRAG = 3
local DROPLET_LIFE = { 0.8, 1.8 }
local DROPLET_SPEED = { 70, 230 }
local DROPLET_SIZE = { 1.1, 3.0 }
local MIST_LIFE = { 0.5, 0.9 }
local MIST_SIZE = { 9, 20 }
local MIST_ALPHA = 0.22
local DROPLET_ALPHA = 0.9
local FADE_START = 0.7          -- droplets start to fade after this fraction of their life
local STREAK_SECONDS = 0.045    -- a streak is as long as the distance covered in this time...
local STREAK_MIN, STREAK_MAX = 3.5, 26  -- ...within these limits
-- A droplet is a teardrop (a rounded head and a tail that tapers to a point) drawn as a small triangle fan, longer the faster it
-- goes (see Particle shapes): in flight it reads as a thin streak, not a flat petal. A droplet that has flown a while stretches
-- up to AGE_GAIN more and gets thinner. By its width on the screen, in pixels: under LOD2 it is one thin quad, under LOD3 a
-- six-point fan, and from there an eight-point fan inside a fringe of the same colour about FRINGE_PX pixels wide at
-- FRINGE_ALPHA of the alpha (the edge anti-aliased: world quads have none of their own), and from GLINT_PX (and GLINT_SIZE world
-- units) up a tiny faint glint near the head. At most BIG_MAX droplets a frame get the full shape. A droplet that would be
-- narrower than PX_MIN pixels is grown to it, but by no more than BOOST times; one wider than PX_MAX, or longer than LEN_MAX,
-- is held to it. Nearer the camera than NEAR_CULL a droplet is not drawn, and it fades in up to NEAR_FADE. Puffs (mist, steam)
-- are cut at PUFF_CULL, fade in to PUFF_FADE and are held to PUFF_PX_MAX pixels in radius. Char and ash flakes (CHAR_STREAK of a
-- droplet's stretch) never get more than the six-point shape.
local DROP = { AGE_GAIN = 0.8, BODY = 0.72, FRINGE_PX = 1.1, FRINGE_ALPHA = 0.45, LOD2 = 3.5, LOD3 = 8,
               GLINT_PX = 14, GLINT_SIZE = 2.0, BIG_MAX = 32, PX_MIN = 2, BOOST = 3, PX_MAX = 16, LEN_MAX = 70,
               NEAR_CULL = 12, NEAR_FADE = 34, PUFF_CULL = 20, PUFF_FADE = 60, PUFF_PX_MAX = 260, CHAR_STREAK = 0.45,
               -- with sprites (see Particle sprites): colour factors on the neutral textures, the puff alpha gain and the glint's
               SPR_BODY = 0.9, CLOT_TINT = 1.25, CHAR_TINT = 1.6, PUFF_GAIN = 1.1, GLINT_GAIN = 0.5 }

-- Offsets from the worm's reported position, to be calibrated in game: up to the middle of the body, and down to
-- the ground the worm stands on.
local CENTRE_Y = 12
local FEET_Y = 0

-- Hit detection.
local BODY_MARGIN = 10          -- an explosion reaches a worm this far beyond its centre
local CREDIT_SECS = 30          -- a hit already shown explains a health drop for this long (health settles at turn end)
local DAMAGED_WINDOW = 0.05     -- an explosion and the game's "a worm was damaged" message arrive this close together
local BLUNT_DAMAGE = 12         -- what a hit with no explosion (a fall, a punch) is taken to be until health settles
local IMPULSE_MIN = 120         -- the least sudden velocity change (units per second) that gives a direction
local IMPULSE_WINDOW = 0.4
local TELEPORT_SPEED = 3000     -- a faster apparent movement is a teleport, not a velocity
local REST_GAP = 0.1            -- no position change for this long means the worm is at rest
local EXPLOSIONS_MAX = 16

-- Bleeding: droplets per second per point of damage (up to a ceiling), and how long it lasts.
local BLEED_PER_DAMAGE = 0.3
local BLEED_MIN_RATE = 3
local BLEED_MAX_RATE = 22
local BLEED_SECS = { 5, 16 }
local BLEED_SECS_PER_DAMAGE = 0.2

-- Ground stains (decals).
local STAIN_SLOTS = 32
local STAIN_BASE, STAIN_PER_DAMAGE, STAIN_MAX, STAIN_DEATH = 10, 0.45, 34, 42
local STAIN_MIN_DAMAGE = 2      -- lighter hits leave nothing on the ground
local REST_SPEED = 40           -- slower than this a worm counts as at rest
local REST_SECS = 0.3
local PENDING_SECS = 8          -- a stain waiting for a thrown worm to land is dropped after this long

-- Droplet-vs-terrain collision (needs wum.game.landRay) and the decals a landing droplet leaves. Distances are world
-- units, times seconds.
local DEC = {
    SPLAT_MAX = 11,             -- the largest a splat grows to by absorbing blood that lands on it
    POOL_MAX = 40,
    BOUND = 1.65,               -- radius of the shader's bounding sphere, in splat radii times (1 + stretch)
    POOL_BOUND = 1.65,
    RUN = 2.8,                  -- a wall splat's drips may reach this many radii below it (bound only)
    SPREAD_POOL = 2.2,          -- a pool spreads to full size in about two seconds (rate of an exponential)
    SPREAD_SPLAT = 14,
    MIN_MERGE = 2.2,            -- blood landing this close to a live decal of the same orientation joins it
    NEW_PER_FRAME = 4,          -- new decals one frame may start; the rest of the hits only grow what is there
    SENDS_PER_FRAME = 12,       -- slot sends (two setTransient calls at most each) one frame may make
    HIT_SCALE = 1.15,           -- splat radius per unit of droplet size
    SIZE_SPREAD = 1.5,          -- a hit's size is its droplet's times exp(SIZE_SPREAD * g), g bell-shaped about 0.5 wide: a long tail of big and tiny splats
    SIZE_SPEED = 0.8,           -- ... and a faster hit spreads wider and breaks up into finer ones (this much more spread, a quarter smaller)
    SIZE_MIN = 0.3, SIZE_MAX = 3.6,
    MIN_LIFE = 1.2,             -- a splat is not recycled in its first seconds, however small
    WORM_SEND = 0.4,            -- a worm's position is sent again to the stains pass when it moved this far (the shader's volume is wider than that)
    -- Terrain rays per frame (the plugin as a whole stays near 64: the intestines take up to PROBE_BUDGET, a pool or a melee
    -- hit a few): droplets get RAY_BUDGET. Heavy
    -- droplets (wider than HEAVY_SIZE or faster than HEAVY_SPEED) are tested first and share HEAVY_RAYS of them; the
    -- rest take turns, no droplet waiting more than STRIDE_MAX frames. A droplet of SPLIT_SIZE or more breaks up.
    RAY_BUDGET = 48, HEAVY_RAYS = 30, HEAVY_SIZE = 1.9, HEAVY_SPEED = 170, SPLIT_SIZE = 2.1, STRIDE_MAX = 12,
    -- Every landRay call the plugin makes is counted in DECALS.rayUsed (reset once per frame) and none runs past RAY_TOTAL;
    -- the pools, the melee ground rays and the intestines' probes ("low" callers) stop at RAY_LOW so the droplets keep theirs.
    RAY_TOTAL = 64, RAY_LOW = 24,
    RETRY_SECS = 10,            -- after landRay answered "unavailable" (or threw) it is tried again this much later, and at every match start
}

-- Blood on the worms' skin. Gore is 0..1 per worm and each point of damage adds 1/GORE_DAMAGE of it.
local SKIN_SLOTS = 16
local GORE_DAMAGE = 60
local GORE_FIRST = 0.35         -- the first hit on a worm gives at least this much
local SKIN_LEAD = 0             -- seconds: extrapolates the body centre along the worm's velocity, to be tuned in game
-- The heading is the worm's facing from the game (yaw); only on a Melange without it is it estimated from the walking
-- direction, and then the pattern turns toward the direction of travel only between these speeds.
local HEADING_SPEED = { 15, 400 }
local HEADING_TURN = 8          -- how fast the heading catches up, per second
local HEADING_RESEND = 0.03     -- radians
local GORE_RESEND = 0.01
local RESEND_SECS = 2           -- everything live is sent again this often, as insurance (see resend)
-- Wounds: gashes open on a worm as its health falls. The level is 0..1, 0 above WOUND_START of its highest health and 1
-- at WOUND_FULL of it or below, and each 0.2 of it opens one more of the five gashes.
local WOUND_START = 0.65
local WOUND_FULL = 0.15
local WOUND_RESEND = 0.02
local PREVIEW_WOUND = 0.7         -- the preview gives its worm this wound level, which decays to 0 over PREVIEW_SECS
local PREVIEW_SECS = 12

-- Black eyes (the shader draws them): the level is 0 at or above EYE.START of the health fraction and 1 at or below
-- EYE.FULL. They are hidden while the worm is thrown, since its facing no longer says how it lies; eyeShow fades them.
local EYE = {
    START = 0.8,
    FULL = 0.3,
    SPEED = 90,                     -- faster than this a worm counts as thrown; walking measures about 40
    FADE = 4,                       -- per second
    RESEND = 0.02,
}

-- Intestines: a worm with a wound level above GUT.START may have its guts out: a torn belly painted by bloodsand/skin and a
-- chain of tubes coming out of it, which this file simulates and bloodsand/guts ray-marches. All to be tuned in game.
local GUT = {
    RESEND = 0.02,
    CHANCE = 0.4,                   -- the share of worms that can show guts at all
    START = 0.6,                    -- the wound level where the gut starts to show; the level is 1 at wound level 1
    AZ = 0.9,                       -- the gut's side is random within this many radians of the facing
    Y = 5.5,                        -- height of the belly opening above the feet
    IN = 2.0,                       -- the pinned root sits this far from the worm's vertical axis, inside the body...
    LIP = 4.2,                      -- ...and the pinned lip (where the gut comes out) this far, just inside its surface
    SLOTS = 4,                      -- worms the guts effect draws at once, the closest to the camera
    POINTS = 16,                    -- chain points; guts.frag takes sixteen
    SEG = 2.5,                      -- segment rest length; guts.frag's SEG is the same
    RADIUS = 1.5,                   -- tube radius at the belly
    TAPER = 0.3,                    -- how much thinner the loose end is
    CORE = 0.6,                     -- (flat ribbons only) the light core's width as a fraction of the width
    OUT_BASE = 4,                   -- segments out of the belly at gut level 0...
    OUT_LEVEL = 7,                  -- ...and this many more at level 1
    EXTRA_MAX = 3,                  -- the most more that hits and knocks can pull out
    SPILL = 0.9,                    -- segments pulled out by a hit, and per point of damage on top
    SPILL_PER_DAMAGE = 0.05,
    FEED = 18,                      -- units per second the gut slides out of the belly
    GRAVITY = -700,
    DAMP = 0.985,                   -- velocity kept per step
    STEP = 1 / 72,                  -- the simulation's fixed step, and the most steps in one frame
    MAX_STEPS = 2,
    ITER = 4,
    ITER_LITE = 2,                  -- (and one step a frame) while more than two chains are going
    STALE = 0.3,                    -- a chain not simulated for this long starts over
    FRICTION = 0.3,                 -- share of its sideways speed a point on the ground loses per step
    BODY_R = 6.3,                   -- the worm's body for the chain to stay out of: a capsule of this radius...
    BODY_Y0 = 6.5,                  -- ...from this height above the feet...
    BODY_Y1 = 20,                   -- ...to this one
    SELF = 2.5,                     -- points of different coils stay this far apart
    BEND = 3.0,                     -- points two apart stay this far apart, which is the tightest bend a gut makes
    KICK = 120,                     -- speed (units per second) a hit shakes the chain with
    WRITHE = 900,                   -- how hard a shaken gut on the ground squirms
    TWITCH_SECS = 2.5,
    IMPACT_MIN = 180,               -- a change of the worm's velocity (units per second) above this stretches the gut...
    IMPACT_FULL = 500,              -- ...fully at this one
    STRETCH = 0.45,
    STRETCH_DECAY = 6,
    IMPACT_SPILL = 1.2,
    WET_SECS = 8,                   -- blood on the gut counts as fresh for this long after a hit
    PROBE_BUDGET = 8,               -- wum.game.landRay calls per frame
    PROBE_UP = 8,
    PROBE_DOWN = 40,
    JUMP = 60,                      -- the worm moving further than this in a frame was teleported: the chain starts over
}

-- The viscera code (a do-block further down, see "== Viscera ==") is local to it, so the file's top level, which is limited to 200
-- locals, pays for five names only: VIS, a table holding what the rest of the file calls, setScorch(slot, amount),
-- woundSites(slot[, out]), updateGut and drawGuts.
local VIS, setScorch, woundSites, updateGut, drawGuts = {}, nil, nil, nil, nil

-- Vomiting blood: a worm at or below VOMIT.FRAC of its health heaves now and then while at rest.
local VOMIT = {
    FRAC = 0.25,
    FIRST = { 3, 10 },              -- seconds until the first heave after getting there
    EVERY = { 12, 30 },
    SECS = 0.9,
    RATE = 120,                     -- droplets per second at the peak, times the amount's bleed multiplier
    PER_FRAME = 6,
    MOUTH_Y = 9.5,                  -- above the feet
    MOUTH_OUT = 6,                  -- in front of the axis
    SPEED = { 45, 90 },
    STAIN = 5,                      -- radius
    STAIN_OUT = 11,                 -- how far in front of the feet the stain lands
    GORE = 0.05,
}

-- Lens splatter.
local LENS_MAX = 6
local LENS_MIN_DAMAGE, LENS_NEAR, LENS_DEATH_NEAR = 25, 250, 500
local LENS_SIZE = { 0.22, 0.45 } -- fraction of the window height
local LENS_LIFE = 4
local LENS_CREEP = 6            -- pixels per second downwards
local LENS_ALPHA = 0.85

local COLOURS = {
    red   = { droplet = { 0.62, 0.03, 0.03 }, mist = { 0.52, 0.02, 0.02 }, stain = { 0.42, 0.02, 0.02 },
              lens = { 0.55, 0.02, 0.02 }, gut = { 0.86, 0.52, 0.54 }, gutDark = { 0.52, 0.20, 0.24 } },
    green = { droplet = { 0.40, 0.80, 0.12 }, mist = { 0.24, 0.52, 0.06 }, stain = { 0.22, 0.48, 0.05 },
              lens = { 0.32, 0.68, 0.08 }, gut = { 0.66, 0.72, 0.42 }, gutDark = { 0.30, 0.38, 0.14 } },
}

local DROPLET, MIST = 1, 2
local MEL = {}                -- the weapon sprays and the hit classification, in one table to spare locals
local GIBS = {}               -- meat, bone and organs thrown by deaths and big hits (see == Gibs ==, near the end)
local SP = {}                 -- the arterial spurts (see == Arterial spurts ==): tick, hit and preview

local sqrt, random, floor, min, max, abs = math.sqrt, math.random, math.floor, math.min, math.max, math.abs
local sin, cos, pi = math.sin, math.cos, math.pi

local function rnd(a, b) return a + random() * (b - a) end

-- Vectors arrive as {x, y, z} arrays in event payloads and with named fields from wum.game and wum.render.
local function vec(v)
    if type(v) ~= "table" then return nil end
    local x, y, z = tonumber(v.x or v[1]), tonumber(v.y or v[2]), tonumber(v.z or v[3])
    if x and y and z then return x, y, z end
    return nil
end

-- Settings and what is derived from them.
local cfg = {}
local preset = AMOUNT.heavy     -- nil while the amount is "off"
local palette = COLOURS.red

local hasPostfx = wum.postfx and wum.postfx.setTransient and wum.postfx.enable and true or false
local hasMenu = wum.ui and wum.ui.menu and true or false

-- ---------------------------------------------------------------- post-FX
-- Values go through wum.postfx.setTransient, which Melange neither saves nor logs, and one is only sent when it differs
-- from the last one sent to that effect. Only switching an effect on or off is saved by Melange, so that too is only
-- sent when it changes.
local STAINS = { id = "bloodsand/stains", cache = {}, enabled = nil }
local SKIN = { id = "bloodsand/skin", cache = {}, enabled = nil }

local function sendParam(fx, name, a, b, c)
    if not hasPostfx then return end
    local old = fx.cache[name]
    if old and old[1] == a and old[2] == b and old[3] == c then return end
    -- Melange returns false when it does not know the effect, so the cache only changes once it took the value and a
    -- failed call is tried again at the next change or resend.
    local ok, res
    if b == nil then
        ok, res = pcall(wum.postfx.setTransient, fx.id, name, a)
    else
        ok, res = pcall(wum.postfx.setTransient, fx.id, name, a, b, c)
    end
    if not ok or res == false then return end
    if not old then
        old = {}
        fx.cache[name] = old
    end
    old[1], old[2], old[3] = a, b, c
end

-- Melange compiles an effect when it is first switched on, and the driver builds the program on its first draw, so the first
-- frames of the skin, stains, guts and lens effects used to cost several milliseconds each, in the middle of the action.
-- WARM switches each one on for a few frames at the start of a match (one at a time, with nothing to draw, a few frames
-- apart), so that this happens before anything is on screen. WARM.on[id] is true while an effect is being held on.
local WARM = { on = {}, left = {}, ids = { "bloodsand/stains", "bloodsand/skin", "bloodsand/guts", "bloodsand/lens" },
               started = false, frame = 0, GAP = 3, HOLD = 2 }

local function sendEnabled(fx, on)
    if WARM.on[fx.id] then on = true end
    if not hasPostfx or fx.enabled == on then return end
    local ok, res = pcall(wum.postfx.enable, fx.id, on)
    if not ok or res == false then return end
    fx.enabled = on
end

-- Worm slots are numbered from 0, so slot n is at index n + 1.
local WORM_A, WORM_B, WORM_C = {}, {}, {}
for i = 1, SKIN_SLOTS do
    WORM_A[i] = "worm" .. (i - 1)
    WORM_B[i] = "worm" .. (i - 1) .. "b"
    WORM_C[i] = "worm" .. (i - 1) .. "c"
end

-- ---------------------------------------------------------------- ground decals
-- == Decals == 32 slots of splats (kind 1), pools (kind 2) and trail pieces (kinds 3 and 4, see "Pools & trails" below), each on a surface of any orientation. A slot is two vec4
-- params, "dNa" = (x, y, z, bound) and "dNb" = (normal, flow, birth, size-and-kind), packed as stains.frag documents.
-- The Lua keeps the data and owns recycling: the one blood last landed in longest ago goes first (size counts for a little,
-- so that the slots keep the latest splats of every size and not the biggest few), and a speck does not push out a pool.
-- The shader dries a decal from its birth, p_clock being our own fxClock (it only runs while a match does). The same pass is
-- told where the living worms are ("w0".."w15", sendWorms), so that it keeps blood off them.
-- Everything is inside one do-block so the main chunk keeps its few free local-variable slots (Lua allows 200); what
-- the rest of the file uses is declared here and set below: updateStainEnable, clearStains, requestPool, placeStain,
-- and the DECALS table (update, resend, zero, cast, splat, blast, rayOK, rayUsed).
-- A worm's pool (placeStain) goes down STAIN_DELAY seconds after it is asked for, so that the crater of the explosion that
-- caused it is there to lie in; and an explosion that digs a crater (DECALS.blast) takes away the decals whose middle is
-- within BLAST_K of its land damage radius: their surface is gone, and what was left of them were strips where the old
-- plane cut the new crater.
DEC.STAIN_DELAY, DEC.LATER_MAX, DEC.BLAST_K = 0.4, 12, 0.75
local updateStainEnable, clearStains, requestPool, placeStain
local DECALS = { rayUsed = 0, rayOK = false, frame = 0, prevHeavy = 0, prevLight = 0, now = 0 }
do
local DS = { live = {}, x = {}, y = {}, z = {}, nx = {}, ny = {}, nz = {}, np = {}, r = {}, rt = {}, e = {}, phi = {},
             birth = {}, seed = {}, kind = {}, thick = {}, dirtyA = {}, dirtyB = {}, sentRq = {}, r0 = {}, t0 = {},
             -- trail pieces (kinds 3 and 4): the allocation counter that tells a piece from the one that took its slot, the two ends, the length last sent
             gen = {}, sx = {}, sy = {}, sz = {}, ex = {}, ey = {}, ez = {}, slen = {}, hold = {},
             -- the worms the shader keeps blood off (params "w0".."w15"): where each was last sent, and the frame it was last seen
             wx = {}, wy = {}, wz = {}, wlive = {}, wseen = {}, wtop = 0,
             -- the pools waiting to go down (placeStain): where, how big and when
             lx = {}, ly = {}, lz = {}, lr = {}, lat = {}, ln = 0 }
local DEC_A, DEC_B, DEC_W = {}, {}, {}
for i = 1, SKIN_SLOTS do
    DEC_W[i] = "w" .. (i - 1)
    DS.wx[i], DS.wy[i], DS.wz[i], DS.wlive[i], DS.wseen[i] = 0, 0, 0, false, 0
end
for i = 1, STAIN_SLOTS do
    DEC_A[i], DEC_B[i] = "d" .. (i - 1) .. "a", "d" .. (i - 1) .. "b"
    DS.live[i], DS.dirtyA[i], DS.dirtyB[i], DS.sentRq[i] = false, false, false, -1
    for _, k in ipairs({ "x", "y", "z", "nx", "ny", "nz", "np", "r", "rt", "e", "phi", "birth", "seed", "kind", "thick", "r0", "t0",
                         "gen", "sx", "sy", "sz", "ex", "ey", "ez", "slen", "hold" }) do
        DS[k][i] = 0
    end
end
local decCount = 0          -- live decals
local decNew = 0            -- decals started this frame
local decFlush = 0          -- where the next flush starts, so no slot is starved
local fxClock = 0

-- Like sendParam for the four-float color params the decal slots are.
local function sendVec4(fx, name, a, b, c, d)
    if not hasPostfx then return end
    local old = fx.cache[name]
    if old and old[1] == a and old[2] == b and old[3] == c and old[4] == d then return end
    local ok, res = pcall(wum.postfx.setTransient, fx.id, name, a, b, c, d)
    if not ok or res == false then return end
    if not old then
        old = {}
        fx.cache[name] = old
    end
    old[1], old[2], old[3], old[4] = a, b, c, d
end

function updateStainEnable()
    sendEnabled(STAINS, decCount > 0 and preset ~= nil and cfg.stains ~= false)
end

-- No worm for the shader to keep blood off.
local function zeroWorms()
    for i = 1, SKIN_SLOTS do
        DS.wlive[i] = false
        sendVec4(STAINS, DEC_W[i], 0, 0, 0, 0)
    end
    DS.wtop = 0
    sendParam(STAINS, "wn", 0)
end

function clearStains()
    for i = 1, STAIN_SLOTS do
        DS.live[i], DS.dirtyA[i], DS.dirtyB[i], DS.sentRq[i] = false, false, false, -1
        sendVec4(STAINS, DEC_A[i], 0, 0, 0, 0)
        sendVec4(STAINS, DEC_B[i], 0, 0, 0, 0)
    end
    decCount = 0
    DS.ln = 0
    sendParam(STAINS, "count", 0)
    zeroWorms()
    updateStainEnable()
end

local function q12(v)
    if v < 0 then v = 0 elseif v > 1 then v = 1 end
    return floor(v * 4095 + 0.5)
end

-- The normal as the shader will see it: two 12-bit angles. The tangent frame is built from this rounded normal on both
-- sides, so the flow direction cannot turn by a quarter where the rounding crosses the frame's switch at |ny| = 0.9.
local function quantNormal(nx, ny, nz)
    local az = math.atan(nz, nx)
    local el = math.acos(max(-1, min(1, ny)))
    local qa, qe = q12((az + pi) / (2 * pi)), q12(el / pi)
    az, el = qa / 4095 * 2 * pi - pi, qe / 4095 * pi
    local se = sin(el)
    return se * cos(az), cos(el), se * sin(az), qa * 4096 + qe
end

-- The tangent frame of stains.frag: T along the surface (horizontal on a wall), B across it (up the wall).
local function tangentFrame(nx, ny, nz)
    local rx, ry, rz = 0, 1, 0
    if abs(ny) > 0.9 then rx, ry, rz = 1, 0, 0 end
    local tx, ty, tz = ry * nz - rz * ny, rz * nx - rx * nz, rx * ny - ry * nx
    local l = sqrt(tx * tx + ty * ty + tz * tz)
    if l < 1e-6 then return 1, 0, 0, 0, 0, 1 end
    tx, ty, tz = tx / l, ty / l, tz / l
    return tx, ty, tz, ny * tz - nz * ty, nz * tx - nx * tz, nx * ty - ny * tx
end

local function isWall(ny) return ny < 0.78 and ny > -0.35 end

-- Sends what changed of one slot: (x, y, z, bound) and the packed shape.
local function decalSend(i)
    if not DS.live[i] then
        sendVec4(STAINS, DEC_A[i], 0, 0, 0, 0)
        sendVec4(STAINS, DEC_B[i], 0, 0, 0, 0)
        DS.dirtyA[i], DS.dirtyB[i], DS.sentRq[i] = false, false, -1
        return
    end
    local rt, e, kind = DS.rt[i], DS.e[i], DS.kind[i]
    if DS.dirtyA[i] then
        local bound
        if kind == 2 then
            bound = DEC.POOL_BOUND * rt
        elseif kind >= 3 then
            -- a trail piece: rt is its half-width and e its length, (half length - 2) / 20 (stains.frag, Streak)
            local lh = 2 + 20 * e
            bound = sqrt(lh * lh + (2.2 * rt + 1) * (2.2 * rt + 1)) + 1.5
        else
            bound = DEC.BOUND * rt * (1 + e)
            if isWall(DS.ny[i]) then bound = bound + DEC.RUN * rt end
        end
        sendVec4(STAINS, DEC_A[i], DS.x[i], DS.y[i], DS.z[i], bound)
        DS.dirtyA[i] = false
    end
    if DS.dirtyB[i] then
        local rq = min(1023, floor(DS.r[i] * 10 + 0.5))
        local flow = q12(DS.phi[i] / (2 * pi)) * 4096 + q12(e / 4)
        -- (the type takes two bits: a trail piece is type 3, its kind 3 or 4 the bit above its 3-bit thickness)
        local tk = kind < 3 and kind * 16 + DS.thick[i] or 48 + (kind - 3) * 8 + min(7, DS.thick[i])
        local ts = rq * 16384 + tk * 256 + DS.seed[i]
        sendVec4(STAINS, DEC_B[i], DS.np[i], flow, DS.birth[i], ts)
        DS.sentRq[i] = rq
        DS.dirtyB[i] = false
    end
end

-- What a slot is worth keeping: mostly how recently blood last landed in it, and a little its size (and a pool is worth more).
-- A weight that favoured size would leave the 32 slots to the biggest few splats of a fight, all of about the same size: the
-- ones kept are meant to be the latest ones, with all the sizes there were. A new decal is not put in the place of one
-- that is under DEC.MIN_LIFE seconds old (a pool is).
local function decalWeight(i)
    local w = (0.3 + 2 * math.exp(-(fxClock - DS.birth[i]) / 25)) * (1 + 0.04 * min(DS.rt[i], 40)) * (DS.kind[i] >= 2 and 1.6 or 1)
    -- (a trail piece told to be held, a grave's smears, is worth three times as much until then)
    if DS.kind[i] >= 3 and fxClock < DS.hold[i] then w = w * 3 end
    return w
end

-- Puts a decal (kind 1 splat, 2 pool) with the blood landing at (hx, hy, hz) and its shape centred at (cx, cy, cz). A decal
-- of the same orientation that the blood lands in or beside takes it instead (and grows, and is wet again). The normal
-- must be a unit vector. Returns the slot or nil.
local function decalAdd(kind, hx, hy, hz, cx, cy, cz, nx, ny, nz, r, e, phi, thick)
    local qx, qy, qz, np = quantNormal(nx, ny, nz)
    local best, bestD, bestReach
    for i = 1, STAIN_SLOTS do
        -- A pool only joins a pool; a splat joins either.
        if DS.live[i] and DS.kind[i] <= 2 and (kind == 1 or DS.kind[i] == 2) and DS.nx[i] * qx + DS.ny[i] * qy + DS.nz[i] * qz > 0.85 then
            local mx, my, mz = DS.nx[i], DS.ny[i], DS.nz[i]
            local dx, dy, dz = hx - DS.x[i], hy - DS.y[i], hz - DS.z[i]
            local h = dx * mx + dy * my + dz * mz
            local rt = DS.rt[i]
            if abs(h) < 0.5 * rt + 2.5 then
                local px, py, pz = dx - mx * h, dy - my * h, dz - mz * h
                local d2 = px * px + py * py + pz * pz
                -- (A tiny speck joins only what it lands in or right beside; it does not melt into a blot two units away.)
                local reach = max(rt * 0.8 * (1 + 0.3 * DS.e[i]), kind == 1 and min(DEC.MIN_MERGE, 0.4 + 1.1 * r) or DEC.MIN_MERGE)
                if d2 < reach * reach and (not bestD or d2 < bestD) then best, bestD, bestReach = i, d2, reach end
            end
        end
    end
    if best then
        local i = best
        local rt = DS.rt[i]
        -- A splat grows by what lands near its edge, not by what lands in its middle, and no further than about half as much again
        -- as it started as (a big blot comes from a big hit): the sizes stay as varied as the hits were.
        local cap = DS.kind[i] == 2 and DEC.POOL_MAX or min(DEC.SPLAT_MAX, 0.5 + 1.5 * DS.r0[i])
        local edgeHit = min(1, max(0, (sqrt(bestD) / bestReach - 0.35) / 0.65))
        local grown = min(cap, sqrt(rt * rt + r * r * (DS.kind[i] == 2 and 0.25 or 0.35) * edgeHit))
        if grown > rt * 1.005 then
            DS.rt[i] = grown
            DS.dirtyA[i], DS.dirtyB[i] = true, true
        end
        -- Fresh blood on old: wet again, in proportion, and a little thicker.
        local frac = min(0.4, (r / DS.rt[i]) ^ 2)
        DS.birth[i] = DS.birth[i] + (fxClock - DS.birth[i]) * frac
        if thick > DS.thick[i] and random() < 0.3 then DS.thick[i] = DS.thick[i] + 1 end
        DS.dirtyB[i] = true
        return i
    end
    if decNew >= DEC.NEW_PER_FRAME and kind == 1 then return nil end
    local slot
    for i = 1, STAIN_SLOTS do
        if not DS.live[i] then
            slot = i
            break
        end
    end
    if not slot then
        local lowest
        -- (A new splat does not push out a pool or a trail piece that is still worth DEC.KEEP or more: the spray of a worm that
        -- spurts blood would otherwise wipe, within seconds, the pools and trails that same worm leaves. Only while there are not
        -- more than DEC.KEEP_SLOTS of them, so that the spray always has room.)
        local keep = DEC.KEEP
        if kind == 1 then
            local n = 0
            for i = 1, STAIN_SLOTS do
                if DS.kind[i] >= 2 then n = n + 1 end
            end
            if n > DEC.KEEP_SLOTS then keep = 1e9 end
        else
            keep = 1e9
        end
        for i = 1, STAIN_SLOTS do
            if kind == 2 or fxClock - DS.t0[i] >= DEC.MIN_LIFE then
                local w = decalWeight(i)
                if (DS.kind[i] == 1 or w < keep) and (not lowest or w < lowest) then slot, lowest = i, w end
            end
        end
        -- Everything is too new, or a speck does not push out anything that is worth more than it.
        if not slot or 2.3 * (1 + 0.04 * min(r, 40)) < lowest * 0.6 then return nil end
    else
        decCount = decCount + 1
    end
    decNew = decNew + 1
    DS.live[slot] = true
    DS.x[slot], DS.y[slot], DS.z[slot] = cx, cy, cz
    DS.nx[slot], DS.ny[slot], DS.nz[slot], DS.np[slot] = qx, qy, qz, np
    DS.rt[slot], DS.e[slot], DS.phi[slot], DS.kind[slot], DS.thick[slot], DS.r0[slot] = r, e, phi, kind, thick, r
    DS.t0[slot] = fxClock
    DS.gen[slot] = DS.gen[slot] + 1
    DS.r[slot] = r * (kind == 2 and 0.15 or 0.6)
    DS.birth[slot] = fxClock
    DS.seed[slot] = random(0, 255)
    DS.dirtyA[slot], DS.dirtyB[slot] = true, true
    return slot
end

-- A droplet of this size and velocity reached the terrain at (x, y, z), whose unit normal is (nx, ny, nz): a splat
-- stretched along the way it was going (a round one with satellite specks when it came down steeply), and on a wall
-- the stretch leans downhill, where the shader runs drips.
local function decalSplat(x, y, z, nx, ny, nz, vx, vy, vz, size)
    local vn = -(vx * nx + vy * ny + vz * nz)
    if vn < 0 then
        nx, ny, nz, vn = -nx, -ny, -nz, -vn
    end
    local tvx, tvy, tvz = vx + nx * vn, vy + ny * vn, vz + nz * vn
    local wall = isWall(ny)
    if wall then
        local gx, gy, gz = nx * ny, ny * ny - 1, nz * ny
        local gl = sqrt(gx * gx + gy * gy + gz * gz)
        if gl > 1e-3 then
            tvx, tvy, tvz = tvx + gx / gl * 30, tvy + gy / gl * 30, tvz + gz / gl * 30
        end
    end
    local ts = sqrt(tvx * tvx + tvy * tvy + tvz * tvz)
    -- A droplet's size says little about the splat it leaves: the size is spread over a long tail (a few big blots, many
    -- small ones, specks), and the faster the hit the wider the spread and the finer the splat on average.
    local sf = min(sqrt(vx * vx + vy * vy + vz * vz), 400) / 400
    local g = random() + random() + random() - 1.5
    local k = max(DEC.SIZE_MIN, min(DEC.SIZE_MAX, math.exp(g * (DEC.SIZE_SPREAD + DEC.SIZE_SPEED * sf)) * (1 - 0.25 * sf)))
    local r = size * DEC.HIT_SCALE * (1 + 0.5 * min(vn, 300) / 300) * k
    local e, phi = 0, 0
    local fx, fy, fz = 0, 0, 0
    if ts > 2 then
        local qx, qy, qz = quantNormal(nx, ny, nz)
        local tx, ty, tz, bx, by, bz = tangentFrame(qx, qy, qz)
        -- Elongation varies from splat to splat too.
        e = max(0, min(3.5, (ts / max(vn, 10) * 0.55 - 0.1) * (0.55 + 0.9 * random()))) + (wall and 0.4 or 0)
        local u, v = (tvx * tx + tvy * ty + tvz * tz) / ts, (tvx * bx + tvy * by + tvz * bz) / ts
        phi = math.atan(v, u) % (2 * pi)
        fx, fy, fz = (tx * u + bx * v) * r * e, (ty * u + by * v) * r * e, (tz * u + bz * v) * r * e
    end
    local thick = min(15, max(4, floor(size * 3.5 + 2 + random() * 4 - 2)))
    return decalAdd(1, x, y, z, x + fx, y + fy, z + fz, nx, ny, nz, min(r, DEC.SPLAT_MAX), e, phi, thick)
end

-- == Pools & trails: decal support == trail pieces (kind 3: a dotted line of drips, kind 4: a smear) and growing pools.
-- A piece is a straight strip on the surface from a start point along a unit direction, length len; the shader (stains.frag,
-- Streak) draws it centred between the ends, its half-width being rt. Pieces never merge with anything, they count against
-- a cap (the trail cap of the amount) and the oldest goes first, they are the first thing a splat can push out of a full set
-- of slots, and a piece is told from the one that took its slot by its generation (gen).
DEC.KEEP_SLOTS = 18             -- ... as long as pools and pieces take no more than this many of the slots
DEC.KEEP = 1.0                  -- a splat cannot take the slot of a pool or a piece worth this much or more (see decalAdd)
DEC.TRAIL_PUSH = 1.6            -- a piece pushes out a splat whose worth (decalWeight) is under this, when the slots are full
DEC.TRAIL_SEND = 1.2            -- a piece's length is sent again when it grew this much

-- Starts a piece at (sx, sy, sz) on a surface of unit normal (nx, ny, nz). kind 3 or 4; hw the half-width (the size of the
-- drips for 3); thick 0..7 (the density of the drips for 3); cap the most pieces there may be. Returns the slot and its
-- generation, or nil. Send it its direction and length with DECALS.trailSet at once. When every slot is in use it takes the
-- place of the least valuable splat (the mirror of the rule in decalAdd: any splat older than DEC.MIN_LIFE while there are fewer
-- pieces than cap and pools and pieces take no more than DEC.KEEP_SLOTS slots, so that a worm that spurts cannot keep its own
-- trail from starting; else one worth under push, DEC.TRAIL_PUSH when not given), and it never takes the place of a piece unless
-- the cap is reached, when it is the oldest piece. A piece that is held (hold seconds, when given) is neither counted against the cap
-- nor taken, and other decals take its place less easily (decalWeight): a grave's smears are not a walker's trail to recycle.
function DECALS.trailNew(kind, sx, sy, sz, nx, ny, nz, hw, thick, cap, push, hold)
    local qx, qy, qz, np = quantNormal(nx, ny, nz)
    local nTrail, nHeld, nPool, oldestU, oldestUT, free = 0, 0, 0, nil, nil, nil
    for i = 1, STAIN_SLOTS do
        if DS.live[i] then
            local k = DS.kind[i]
            if k >= 3 then
                -- (a piece that is held, a grave's smear, is not counted against the cap: it is no walker's)
                if fxClock >= DS.hold[i] then
                    nTrail = nTrail + 1
                    if not oldestU or DS.t0[i] < oldestUT then oldestU, oldestUT = i, DS.t0[i] end
                else
                    nHeld = nHeld + 1
                end
            elseif k == 2 then
                nPool = nPool + 1
            end
        elseif not free then
            free = i
        end
    end
    local slot
    if nTrail >= cap and oldestU then
        slot = oldestU
    elseif free then
        slot = free
        decCount = decCount + 1
    else
        local limit = push or DEC.TRAIL_PUSH
        if nTrail < cap and nPool + nTrail + nHeld <= DEC.KEEP_SLOTS then limit = 1e9 end
        local lowest
        for i = 1, STAIN_SLOTS do
            if DS.kind[i] == 1 and (push or fxClock - DS.t0[i] >= DEC.MIN_LIFE) then
                local w = decalWeight(i)
                if w < limit and (not lowest or w < lowest) then slot, lowest = i, w end
            end
        end
        if not slot then return nil end
    end
    DS.live[slot] = true
    DS.x[slot], DS.y[slot], DS.z[slot] = sx, sy, sz
    DS.nx[slot], DS.ny[slot], DS.nz[slot], DS.np[slot] = qx, qy, qz, np
    DS.rt[slot], DS.r[slot], DS.r0[slot], DS.e[slot], DS.phi[slot] = hw, hw, hw, 0, 0
    DS.kind[slot], DS.thick[slot] = kind, max(0, min(7, thick))
    DS.t0[slot], DS.birth[slot] = fxClock, fxClock
    DS.gen[slot] = DS.gen[slot] + 1
    DS.hold[slot] = fxClock + (hold or 0)
    DS.seed[slot] = random(0, 255)
    DS.sx[slot], DS.sy[slot], DS.sz[slot], DS.ex[slot], DS.ey[slot], DS.ez[slot], DS.slen[slot] = sx, sy, sz, sx, sy, sz, -100
    DS.dirtyA[slot], DS.dirtyB[slot] = true, true
    return slot, DS.gen[slot]
end

-- Is this still the piece it was (not recycled, not taken away by a crater)?
function DECALS.trailAlive(slot, gen)
    return DS.live[slot] and DS.gen[slot] == gen and DS.kind[slot] >= 3 or false
end

-- Sets the piece's start, unit direction and length (its length changes as a worm crawls on). Sent to the shader when the
-- length changed by DEC.TRAIL_SEND, or when force is set (the piece is finished). The head end is fresh blood: the
-- piece is wet again from now. Returns false when the piece is gone.
function DECALS.trailSet(slot, gen, sx, sy, sz, dx, dy, dz, len, force)
    if not (DS.live[slot] and DS.gen[slot] == gen and DS.kind[slot] >= 3) then return false end
    if not force and abs(len - DS.slen[slot]) < DEC.TRAIL_SEND then return true end
    local lh = max(2, len * 0.5)
    local tx, ty, tz, bx, by, bz = tangentFrame(DS.nx[slot], DS.ny[slot], DS.nz[slot])
    DS.phi[slot] = math.atan(dx * bx + dy * by + dz * bz, dx * tx + dy * ty + dz * tz) % (2 * pi)
    DS.e[slot] = min(4, (lh - 2) / 20)
    DS.x[slot], DS.y[slot], DS.z[slot] = sx + dx * lh, sy + dy * lh, sz + dz * lh
    DS.sx[slot], DS.sy[slot], DS.sz[slot] = sx, sy, sz
    DS.ex[slot], DS.ey[slot], DS.ez[slot] = sx + dx * len, sy + dy * len, sz + dz * len
    DS.slen[slot] = len
    DS.birth[slot] = fxClock
    DS.dirtyA[slot], DS.dirtyB[slot] = true, true
    return true
end

-- The generation of a pool in this slot, to give back to poolGrow (nil when the slot is not a pool).
function DECALS.poolKey(slot)
    if slot and DS.live[slot] and DS.kind[slot] == 2 then return DS.gen[slot] end
end

-- Makes a pool at least radius r (it spreads there as pools do), and with fresh keeps it wet. False when it is gone.
function DECALS.poolGrow(slot, key, r, fresh)
    if not (DS.live[slot] and DS.kind[slot] == 2 and DS.gen[slot] == key) then return false end
    r = min(DEC.POOL_MAX, r)
    if r > DS.rt[slot] then
        DS.rt[slot] = r
        DS.dirtyA[slot] = true
    end
    if fresh and fxClock - DS.birth[slot] > 1 then
        DS.birth[slot] = fxClock
        DS.dirtyB[slot] = true
    end
    return true
end

-- Frame step of the decals: advances the clock the shader dries them by, spreads the new ones out, sends what changed.
-- The shader skips the slots above this one without looking at them.
local function sendCount()
    local top = 0
    for i = 1, STAIN_SLOTS do
        if DS.live[i] then top = i end
    end
    sendParam(STAINS, "count", top)
end

-- Tells the stains pass where the living worms are, so that blood does not land on them (see stains.frag): the middle of
-- each body, sent again when it moved WORM_SEND, and zeros for the slots that are gone. `slots` is the plugin's table of
-- tracked worms and `frameId` the frame they were seen in.
local function sendWorms(slots, frameId)
    local top = 0
    local mv = DEC.WORM_SEND
    for slot, s in pairs(slots) do
        local i = slot + 1
        if s.seen == frameId and s.alive and not s.dead and i >= 1 and i <= SKIN_SLOTS then
            local x, y, z = s.px, s.py + CENTRE_Y, s.pz
            DS.wseen[i] = frameId
            if i > top then top = i end
            if not DS.wlive[i] or abs(x - DS.wx[i]) > mv or abs(y - DS.wy[i]) > mv or abs(z - DS.wz[i]) > mv then
                DS.wlive[i], DS.wx[i], DS.wy[i], DS.wz[i] = true, x, y, z
                sendVec4(STAINS, DEC_W[i], x, y, z, 1)
            end
        end
    end
    for i = 1, SKIN_SLOTS do
        if DS.wseen[i] ~= frameId then
            DS.wlive[i] = false
            sendVec4(STAINS, DEC_W[i], 0, 0, 0, 0)
        end
    end
    DS.wtop = top
    sendParam(STAINS, "wn", top)
end

function DECALS.update(dt, slots, frameId)
    fxClock = fxClock + dt
    -- The pools that are due go down now.
    local n, k = DS.ln, 1
    while k <= n do
        if DECALS.now >= DS.lat[k] then
            local x, y, z, r = DS.lx[k], DS.ly[k], DS.lz[k], DS.lr[k]
            DS.lx[k], DS.ly[k], DS.lz[k], DS.lr[k], DS.lat[k] = DS.lx[n], DS.ly[n], DS.lz[n], DS.lr[n], DS.lat[n]
            n = n - 1
            DS.ln = n
            requestPool(x, y, z, r)
        else
            k = k + 1
        end
    end
    if decCount > 0 and slots then sendWorms(slots, frameId) end
    for i = 1, STAIN_SLOTS do
        if DS.live[i] then
            local r, rt = DS.r[i], DS.rt[i]
            if r < rt then
                r = rt - (rt - r) * math.exp(-(DS.kind[i] == 2 and DEC.SPREAD_POOL or DEC.SPREAD_SPLAT) * dt)
                if rt - r < 0.02 * rt + 0.04 then r = rt end
                DS.r[i] = r
                if min(1023, floor(r * 10 + 0.5)) ~= DS.sentRq[i] then DS.dirtyB[i] = true end
            end
        end
    end
    if decCount > 0 then sendParam(STAINS, "clock", fxClock) end
    sendCount()
    local sent = 0
    for k = 0, STAIN_SLOTS - 1 do
        local i = (decFlush + k) % STAIN_SLOTS + 1
        if DS.dirtyA[i] or DS.dirtyB[i] then
            decalSend(i)
            sent = sent + 1
            if sent >= DEC.SENDS_PER_FRAME then
                decFlush = i % STAIN_SLOTS
                break
            end
        end
    end
    decNew = 0
    updateStainEnable()
end

-- Sends slots first..last again, for the insurance resend: live ones as they are, empty ones as zeros.
function DECALS.resend(first, last)
    for i = first, min(last, STAIN_SLOTS) do
        STAINS.cache[DEC_A[i]], STAINS.cache[DEC_B[i]] = nil, nil
        DS.dirtyA[i], DS.dirtyB[i] = true, true
        decalSend(i)
    end
end

function DECALS.resendMisc()
    STAINS.cache.clock, STAINS.cache.count, STAINS.cache.blood, STAINS.cache.wn = nil, nil, nil, nil
    -- The worms go out at the next frame (which finds their cache empty), and the empty ones are zeroed there.
    for i = 1, SKIN_SLOTS do
        STAINS.cache[DEC_W[i]] = nil
        DS.wlive[i] = false
    end
    sendParam(STAINS, "clock", fxClock)
    sendCount()
end

function DECALS.zero()
    for i = 1, STAIN_SLOTS do
        sendVec4(STAINS, DEC_A[i], 0, 0, 0, 0)
        sendVec4(STAINS, DEC_B[i], 0, 0, 0, 0)
    end
    sendParam(STAINS, "count", 0)
    zeroWorms()
end

-- The terrain ray. wum.game.landRay is new in Melange 0.6; without it (or when it says it is unavailable) droplets fly on
-- through the ground as they always did and pools sit at the height they are asked for.
local landRay = wum.game.landRay
DECALS.rayOK = type(landRay) == "function"

-- One flag (DECALS.rayOK) says whether landRay can be used, for the decals, the melee code and the intestines alike. Melange
-- answers "unavailable" for the current level or thread as well as for a build without it, so the flag is not final: it is set
-- again at the next match start and RETRY_SECS after a failure.
DECALS.hasFn = type(landRay) == "function"
DECALS.rayRetryAt = 0

local function rayFailed()
    DECALS.rayOK = false
    DECALS.rayRetryAt = os.clock() + DEC.RETRY_SECS
end

-- Returns t (0..1 along the segment) and the unit normal of the hit. A miss is nil alone; nil and a reason is a ray that did
-- not run or whose answer was no use ("budget": the frame's cap, ours or Melange's; "unavailable"; "bad"). A "low" caller
-- (anything but a droplet) is refused earlier, see RAY_LOW.
local function castRay(x0, y0, z0, x1, y1, z1, low)
    if not DECALS.rayOK then return nil, "unavailable" end
    local used = DECALS.rayUsed
    if used >= (low and DEC.RAY_LOW or DEC.RAY_TOTAL) then return nil, "budget" end
    DECALS.rayUsed = used + 1
    local ok, t, nx, ny, nz = pcall(landRay, x0, y0, z0, x1, y1, z1)
    if not ok then
        rayFailed()
        return nil, "unavailable"
    end
    if t == nil then
        if nx == "unavailable" then
            rayFailed()
            return nil, "unavailable"
        elseif nx == "budget" then
            DECALS.rayUsed = DEC.RAY_TOTAL      -- Melange's cap for all mods: nothing more this frame
            return nil, "budget"
        elseif nx ~= nil then
            return nil, "bad"
        end
        return nil
    end
    if type(t) ~= "number" or type(nx) ~= "number" or type(ny) ~= "number" or type(nz) ~= "number" then return nil, "bad" end
    local l = sqrt(nx * nx + ny * ny + nz * nz)
    if l < 1e-6 then return nil, "bad" end
    return t, nx / l, ny / l, nz / l
end

-- A pool of blood under (x, y, z), size being its radius: it lies on the ground below the point (found with a ray when
-- the terrain can be asked, otherwise at the given height, facing up) and spreads over about two seconds. A caller that
-- already knows the ground passes its unit normal (nx, ny, nz) and (x, y, z) is then taken to be on the surface.
function requestPool(x, y, z, size, gx, gy, gz)
    if not (hasPostfx and preset and cfg.stains) or STAINS.failed then return end
    local px, py, pz, nx, ny, nz = x, y, z, 0, 1, 0
    if gx and gy and gz and gy > 0.2 then
        nx, ny, nz = gx, gy, gz
    elseif DECALS.rayOK then
        local t, hx, hy, hz = castRay(x, y + 14, z, x, y - 36, z, true)
        if t then
            py = y + 14 - 50 * t
            nx, ny, nz = hx, hy, hz
            if ny < 0.2 then nx, ny, nz = 0, 1, 0 end
        end
    end
    local phi = random() * 2 * pi
    return decalAdd(2, px, py, pz, px, py, pz, nx, ny, nz, min(DEC.POOL_MAX, max(2, size * 0.9)), 0, phi, random(11, 15))
end

-- A worm's pool: it goes down STAIN_DELAY seconds from now (see DECALS.update), when the crater it may lie in is there.
function placeStain(x, y, z, radius)
    local n = DS.ln
    if n >= DEC.LATER_MAX then
        requestPool(x, y, z, radius)
        return
    end
    n = n + 1
    DS.lx[n], DS.ly[n], DS.lz[n], DS.lr[n], DS.lat[n] = x, y, z, radius, DECALS.now + DEC.STAIN_DELAY
    DS.ln = n
end

-- An explosion at (x, y, z) that digs a crater of radius landR: the decals whose middle is in it go.
function DECALS.blast(x, y, z, landR)
    if not landR or landR <= 0 then return end
    local r = landR * DEC.BLAST_K
    for i = 1, STAIN_SLOTS do
        if DS.live[i] then
            local dx, dy, dz = DS.x[i] - x, DS.y[i] - y, DS.z[i] - z
            local hit = dx * dx + dy * dy + dz * dz < r * r
            if not hit and DS.kind[i] >= 3 then
                -- a trail piece goes when either end is in the crater
                dx, dy, dz = DS.sx[i] - x, DS.sy[i] - y, DS.sz[i] - z
                hit = dx * dx + dy * dy + dz * dz < r * r
                if not hit then
                    dx, dy, dz = DS.ex[i] - x, DS.ey[i] - y, DS.ez[i] - z
                    hit = dx * dx + dy * dy + dz * dz < r * r
                end
            end
            if hit then
                DS.live[i], DS.dirtyA[i] = false, true
                decCount = decCount - 1
            end
        end
    end
end

DECALS.cast, DECALS.splat = castRay, decalSplat
end

-- ---------------------------------------------------------------- particles
local P = { x = {}, y = {}, z = {}, vx = {}, vy = {}, vz = {}, size = {}, age = {}, life = {}, kind = {},
            r = {}, g = {}, b = {}, a = {} }
local PARTS = { P.x, P.y, P.z, P.vx, P.vy, P.vz, P.size, P.age, P.life, P.kind, P.r, P.g, P.b, P.a }
-- == Collision state == per droplet: the point its last terrain ray started from, when that was, and a phase that staggers its rays.
-- spawn does not set them: simulate does on a particle's first step (its age is still 0 then).
P.lx, P.ly, P.lz, P.ph, P.lt = {}, {}, {}, {}, {}
for _, arr in ipairs({ P.lx, P.ly, P.lz, P.ph, P.lt }) do PARTS[#PARTS + 1] = arr end
local nP = 0
for _, arr in ipairs(PARTS) do
    for i = 1, POOL_MAX do arr[i] = 0 end
end

local function spawn(kind, x, y, z, vx, vy, vz, size, life, r, g, b, a)
    if not preset or nP >= preset.max or nP >= POOL_MAX then return end
    nP = nP + 1
    BUDGET.spawned = BUDGET.spawned + 1
    local i = nP
    P.x[i], P.y[i], P.z[i] = x, y, z
    P.vx[i], P.vy[i], P.vz[i] = vx, vy, vz
    P.size[i], P.age[i], P.life[i], P.kind[i] = size, 0, life, kind
    P.r[i], P.g[i], P.b[i], P.a[i] = r, g, b, a
    P.lt[i] = 1e9           -- no terrain test yet: a start from a stale slot is not trusted (see simulate)
end

-- How many more particles fit in the pool (what this amount allows, and the arrays' size).
local function poolRoom()
    if not preset then return 0 end
    return min(preset.max, POOL_MAX) - nP
end

local function removeParticle(i)
    for k = 1, #PARTS do
        local arr = PARTS[k]
        arr[i] = arr[nP]
    end
    nP = nP - 1
end

-- Camera values for this frame, so the particles do not each ask for them.
-- focal is the camera's focal length in pixels: a thing one world unit across at distance d is focal / d pixels wide. It is
-- measured from where wum.render.worldToScreen puts a point ahead and to the right, or guessed from the window height.
local CAM = { ok = false, px = 0, py = 0, pz = 0, rx = 0, ry = 0, rz = 0, ux = 0, uy = 0, uz = 0, focal = 1900, probe = { x = 0, y = 0, z = 0 } }

local function readCamera()
    CAM.ok = false
    if not (wum.render and wum.render.camera) then return end
    local c = wum.render.camera()
    if type(c) ~= "table" then return end
    local px, py, pz = vec(c.pos)
    local fx, fy, fz = vec(c.fwd)
    local ux, uy, uz = vec(c.up)
    if not (px and fx and ux) then return end
    local rx, ry, rz = fy * uz - fz * uy, fz * ux - fx * uz, fx * uy - fy * ux
    local len = sqrt(rx * rx + ry * ry + rz * rz)
    if len < 1e-6 then return end
    CAM.px, CAM.py, CAM.pz = px, py, pz
    CAM.rx, CAM.ry, CAM.rz = rx / len, ry / len, rz / len
    CAM.ux, CAM.uy, CAM.uz = ux, uy, uz
    CAM.ok = true
    local w, h
    if wum.render.windowSize then w, h = wum.render.windowSize() end
    if type(h) == "number" and h > 0 then CAM.focal = h * 1.8 end
    if type(w) == "number" and w > 0 and wum.render.worldToScreen then
        local fl = sqrt(fx * fx + fy * fy + fz * fz)
        if fl > 1e-6 then
            local p, k = CAM.probe, 1 / fl
            p.x, p.y, p.z = px + fx * k * 200 + CAM.rx * 50, py + fy * k * 200 + CAM.ry * 50, pz + fz * k * 200 + CAM.rz * 50
            local ok, sx = pcall(wum.render.worldToScreen, p)
            if ok and type(sx) == "number" and abs(sx - w * 0.5) > 1 then CAM.focal = abs(sx - w * 0.5) * 4 end
        end
    end
end

-- The quad's corner tables and the colour are read by wum.draw.quad before it returns, so one set is reused.
local q1, q2, q3, q4 = { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }
local quadColour = { r = 0, g = 0, b = 0, a = 0 }
local drawQuad = wum.draw.quad

-- World quads are back-face culled and Lua cannot turn that off, so the corners must run counter-clockwise as the
-- camera sees them.
local function emitQuad(r, g, b, a)
    quadColour.r, quadColour.g, quadColour.b, quadColour.a = r, g, b, a
    drawQuad(q1, q2, q3, q4, quadColour)
end

local function corner(q, x, y, z)
    q.x, q.y, q.z = x, y, z
end

-- == Particle shapes ============================================================================================
-- Droplets and puffs are triangle fans. wum.draw.quad draws the triangles (p1, p2, p3) and (p1, p3, p4), so a quad whose p1
-- is the fan centre and whose other three corners are consecutive points of the rim is a fan of two triangles: four of
-- them make an octagon, three a hexagon. The rim points are written once into a few corner tables that are reused (wum.draw.quad
-- reads them before it returns) and each is shared by two quads. Every shape runs counter-clockwise as the camera sees it.
-- Everything is in one do-block, and P.shape is what simulate calls: drop, glint and puff.
P.shape = {}
do
    local VT = {}
    for i = 1, 9 do VT[i] = { x = 0, y = 0, z = 0 } end
    local CT = VT[9]
    local col = { r = 0, g = 0, b = 0, a = 0 }
    local dq = drawQuad

    -- The teardrop outline in (along, across) units: the head at +1, the tail point at -1, in the order that runs
    -- counter-clockwise on the screen for a droplet whose across axis is (along x line to the camera). C8 is where the fan
    -- centre is. (The six-point shape is the same idea, with corners (1, 0), (0.45, -0.95), (-0.4, -0.8), (-1, 0), (-0.4, 0.8),
    -- (0.45, 0.95) and its centre at 0.1; it is written out in drop.)
    local U8 = { 1.0, 0.78, 0.25, -0.28, -1.0, -0.28, 0.25, 0.78 }
    local W8 = { 0, -0.707, -1, -0.707, 0, 0.707, 1, 0.707 }
    local C8 = 0.25

    -- lod 1: one thin kite quad; 2: a six-point fan (three quads); 3: an eight-point fan (four quads). k scales the eight-point shape
    -- about the fan centre (the fringe around a big droplet is drawn with k = 1 and its axes lengthened instead). The centre of the droplet is (x, y, z),
    -- (ax, ay, az) is the half length along its velocity and (sx, sy, sz) the half width.
    function P.shape.drop(lod, k, x, y, z, ax, ay, az, sx, sy, sz, r, g, b, a)
        col.r, col.g, col.b, col.a = r, g, b, a
        if lod == 1 then
            local hx, hy, hz = x + ax * 0.45, y + ay * 0.45, z + az * 0.45
            local v1, v2, v3, v4 = VT[1], VT[2], VT[3], VT[4]
            v1.x, v1.y, v1.z = x - ax * 0.92, y - ay * 0.92, z - az * 0.92
            v2.x, v2.y, v2.z = hx + sx, hy + sy, hz + sz
            v3.x, v3.y, v3.z = x + ax, y + ay, z + az
            v4.x, v4.y, v4.z = hx - sx, hy - sy, hz - sz
            dq(v1, v2, v3, v4, col)
        elseif lod == 2 then
            -- (the six-point shape is only drawn at its own size, so its corners are written out)
            local bx, by, bz, cx, cy, cz = ax * 0.45, ay * 0.45, az * 0.45, ax * 0.4, ay * 0.4, az * 0.4
            local dx, dy, dz, ex, ey, ez = sx * 0.95, sy * 0.95, sz * 0.95, sx * 0.8, sy * 0.8, sz * 0.8
            local v = VT[1]
            v.x, v.y, v.z = x + ax, y + ay, z + az
            v = VT[2]
            v.x, v.y, v.z = x + bx - dx, y + by - dy, z + bz - dz
            v = VT[3]
            v.x, v.y, v.z = x - cx - ex, y - cy - ey, z - cz - ez
            v = VT[4]
            v.x, v.y, v.z = x - ax, y - ay, z - az
            v = VT[5]
            v.x, v.y, v.z = x - cx + ex, y - cy + ey, z - cz + ez
            v = VT[6]
            v.x, v.y, v.z = x + bx + dx, y + by + dy, z + bz + dz
            CT.x, CT.y, CT.z = x + ax * 0.1, y + ay * 0.1, z + az * 0.1
            dq(CT, VT[1], VT[2], VT[3], col)
            dq(CT, VT[3], VT[4], VT[5], col)
            dq(CT, VT[5], VT[6], VT[1], col)
        else
            local k0 = C8 * (1 - k)
            for i = 1, 8 do
                local u, w = k0 + U8[i] * k, W8[i] * k
                local v = VT[i]
                v.x, v.y, v.z = x + ax * u + sx * w, y + ay * u + sy * w, z + az * u + sz * w
            end
            CT.x, CT.y, CT.z = x + ax * C8, y + ay * C8, z + az * C8
            dq(CT, VT[1], VT[2], VT[3], col)
            dq(CT, VT[3], VT[4], VT[5], col)
            dq(CT, VT[5], VT[6], VT[7], col)
            dq(CT, VT[7], VT[8], VT[1], col)
        end
    end

    -- The hexagon corners, for the glint and the puffs: angles go from the camera right toward its up, which is counter-clockwise.
    local HC, HS = {}, {}
    for k = 1, 6 do HC[k], HS[k] = cos((k - 1) * pi / 3), sin((k - 1) * pi / 3) end

    -- A tiny round highlight (a hexagon of radius gr facing the camera) on a big droplet.
    function P.shape.glint(x, y, z, gr, rx, ry, rz, ux, uy, uz, r, g, b, a)
        col.r, col.g, col.b, col.a = r, g, b, a
        for k = 1, 6 do
            local c, s = HC[k] * gr, HS[k] * gr
            local v = VT[k]
            v.x, v.y, v.z = x + rx * c + ux * s, y + ry * c + uy * s, z + rz * c + uz * s
        end
        CT.x, CT.y, CT.z = x, y, z
        dq(CT, VT[1], VT[2], VT[3], col)
        dq(CT, VT[3], VT[4], VT[5], col)
        dq(CT, VT[5], VT[6], VT[1], col)
    end

    -- A soft puff: up to four hexagonal fans one inside the other, each with less of the radius and more of the alpha, so that the
    -- alpha falls off toward the edge in steps too small to see. Every corner of every fan is pulled in or out by its own factor
    -- (the pattern shifts from fan to fan), so the outline is irregular. The seed (0..255) turns the puff and sets the pattern.
    local NZ = { 1.0, 0.8, 1.14, 0.9, 1.07, 0.74 }
    local PX, PY, PZ = {}, {}, {}
    local LSC = { { 1.0 }, { 1.1, 0.6 }, { 1.15, 0.78, 0.42 }, { 1.2, 0.92, 0.64, 0.34 } }
    local LAL = { { 0.45 }, { 0.3, 0.5 }, { 0.22, 0.34, 0.46 }, { 0.15, 0.26, 0.34, 0.42 } }

    function P.shape.puff(x, y, z, R, r, g, b, a, seed, nl, rx, ry, rz, ux, uy, uz)
        local ang = seed * 0.02454
        local ca, sa = cos(ang), sin(ang)
        for k = 1, 6 do
            local c, s = HC[k], HS[k]
            local a1, b1 = c * ca - s * sa, c * sa + s * ca
            PX[k], PY[k], PZ[k] = rx * a1 + ux * b1, ry * a1 + uy * b1, rz * a1 + uz * b1
        end
        CT.x, CT.y, CT.z = x, y, z
        col.r, col.g, col.b = r, g, b
        local sc, al = LSC[nl], LAL[nl]
        for l = 1, nl do
            local s, sh = sc[l] * R, seed + l * 2
            for k = 1, 6 do
                local f = s * NZ[(k + sh) % 6 + 1]
                local v = VT[k]
                v.x, v.y, v.z = x + PX[k] * f, y + PY[k] * f, z + PZ[k] * f
            end
            col.a = a * al[l]
            dq(CT, VT[1], VT[2], VT[3], col)
            dq(CT, VT[3], VT[4], VT[5], col)
            dq(CT, VT[5], VT[6], VT[1], col)
        end
    end
end

-- == Particle sprites ==
-- Melange 0.6 has wum.draw.sprite(tex, x, y, z, halfW, halfL, ax, ay, az, color, mode): a soft textured billboard, depth-tested, with
-- an axis it stretches along (velocity) or, with a zero axis, a round one. With it a droplet is ONE sprite of a wet, shaded
-- teardrop (a dark rim, a glint) instead of two or three flat fans, a clot a lumpy glossy blob, mist and steam soft puffs and
-- char a ragged fleck. The textures (mod/textures/bs_*.png, made by tools/make_blood_sprites.js) are neutral grey: the sprite's
-- colour tints them. Without the call, or a texture that will not load, the particle kind keeps the fans above.
-- DROP.TK[kind] is that kind's list of textures, nil when it has none; DROP.RC and RS are the cosine and sine of a puff's turn
-- (its seed 0..255 of a full circle), which a puff passes as its axis so that it can be rotated.
-- What Melange does with the call (docs/lua-api.md, Sprites): the texture must be one this mod loaded with wum.draw.texture (any
-- other number raises an error, so the ids are only kept from DROP.load, run once per load); calling outside a "world" or
-- "worldLate" callback raises (simulate runs inside onWorld only); a zero axis is a round billboard of 2*halfW that ignores halfL;
-- a non-zero axis with halfL 0 draws nothing (halfL here is always above zero); v = 0, the PNG's top row, is the tail at
-- centre - axis*halfL; sprites of all mods are sorted by depth, so textures that alternate in depth cost a draw call each (the
-- sets are kept small: 2 droplet, 4 clot, 3 mist, 2 steam, 2 char, 1 spark); a mod may draw 4096 a frame and past that the call
-- returns false (about 500 are drawn).
function DROP.load()
    DROP.TK, DROP.RC, DROP.RS = nil, nil, nil
    if not (wum.draw.sprite and wum.draw.texture) then return end
    local function set(prefix, n)
        local list = {}
        for k = 1, n do
            local ok, tex = pcall(wum.draw.texture, "textures/bs_" .. prefix .. (n > 1 and k or "") .. ".png")
            if not (ok and tex) then return nil end
            list[k] = tex
        end
        return list
    end
    local TK = {}
    TK[DROPLET], TK[MIST], TK[MEL.STEAM], TK[MEL.CHAR], TK[MEL.CLOT] = set("drop", 2), set("mist", 3), set("steam", 2), set("char", 2), set("clot", 4)
    local glint = set("glint", 1)
    TK.glint = glint and glint[1] or false
    if not (TK[DROPLET] or TK[MIST] or TK[MEL.STEAM] or TK[MEL.CHAR] or TK[MEL.CLOT]) then return end
    local RC, RS = {}, {}
    for k = 0, 255 do RC[k + 1], RS[k + 1] = cos(k * 0.02454), sin(k * 0.02454) end
    DROP.TK, DROP.RC, DROP.RS = TK, RC, RS
    local first = TK[DROPLET] or TK[MIST] or TK[MEL.STEAM] or TK[MEL.CHAR] or TK[MEL.CLOT]
    DROP.probeTex, DROP.checked = first[1], false
end

-- Once, in the first world callback, before the first sprite: a sprite of no width (Melange draws nothing for it and answers
-- true). If the call raises for any reason, the particles keep the fans for the rest of the session instead of faulting the
-- callback every frame.
function DROP.check()
    DROP.checked = true
    if not pcall(wum.draw.sprite, DROP.probeTex, 0, 0, 0, 0, 0, 0, 0, 0) then
        DROP.TK = nil
        if wum.log and wum.log.warn then wum.log.warn("Bloodsand: wum.draw.sprite failed, so the particles are drawn as fans") end
    end
end

-- Integrates and draws every live particle. Droplets are drops stretched along their velocity that turn to face the
-- camera; mist puffs are flat against the screen. With wum.game.landRay a droplet or clot that reaches the terrain is removed
-- and leaves a decal (see == Droplet collision ==).
local function simulate(dt)
    if DROP.TK and not DROP.checked then DROP.check() end
    local px, py, pz, pvx, pvy, pvz = P.x, P.y, P.z, P.vx, P.vy, P.vz
    local psize, page, plife, pkind, pr, pg, pb, pa = P.size, P.age, P.life, P.kind, P.r, P.g, P.b, P.a
    local plx, ply, plz, pph, plt = P.lx, P.ly, P.lz, P.ph, P.lt
    local draw = CAM.ok
    local KP, KD, KG, KGROW, KFADE = MEL.KP, MEL.KD, MEL.KG, MEL.KGROW, MEL.KFADE
    local CLOTK, CHARK = MEL.CLOT, MEL.CHAR       -- heavy clots from the melee sprays collide like droplets; steam and char do not
    local PD, focal = P.shape, CAM.focal
    local TK, SPR, RC, RS, col = DROP.TK, wum.draw.sprite, DROP.RC, DROP.RS, quadColour
    local SPR_BODY, CLOT_TINT, CHAR_TINT, PUFF_GAIN = DROP.SPR_BODY, DROP.CLOT_TINT, DROP.CHAR_TINT, DROP.PUFF_GAIN
    local BODY, NEAR_CULL, NEAR_FADE, PX_MIN, PX_MAX, BOOST = DROP.BODY, DROP.NEAR_CULL, DROP.NEAR_FADE, DROP.PX_MIN, DROP.PX_MAX, DROP.BOOST
    local PUFF_CULL, PUFF_FADE, PUFF_PX_MAX = DROP.PUFF_CULL, DROP.PUFF_FADE, DROP.PUFF_PX_MAX
    local nBig, nPuff = 0, 0      -- full-shape droplets and puffs drawn so far this frame, which cap the cost (see DROP)
    -- With a crowded pool the shapes give way to simpler ones sooner (up to two and a half times the pixel width at the most particles).
    local lf = nP > 250 and 1 + (nP - 250) / 150 or 1
    local LOD2, LOD3 = DROP.LOD2 * lf, DROP.LOD3 * lf
    local cpx, cpy, cpz = CAM.px, CAM.py, CAM.pz
    local rx, ry, rz, ux, uy, uz = CAM.rx, CAM.ry, CAM.rz, CAM.ux, CAM.uy, CAM.uz
    -- == Droplet collision == rays are spent on heavy and fast droplets first; the rest take turns, each droplet
    -- being swept from where it was last tested, so a droplet that waits a few frames still cannot pass through.
    local frame = DECALS.frame + 1
    DECALS.frame = frame
    local collide = DECALS.rayOK and hasPostfx and preset ~= nil and cfg.stains and not STAINS.failed and true or false
    local ceil, castRay, decalSplat = math.ceil, DECALS.cast, DECALS.splat
    local strideH = max(1, min(DEC.STRIDE_MAX, ceil(DECALS.prevHeavy / DEC.HEAVY_RAYS)))
    local strideL = max(1, min(DEC.STRIDE_MAX, ceil(DECALS.prevLight / max(1, DEC.RAY_BUDGET - DEC.HEAVY_RAYS))))
    local nHeavy, nLight = 0, 0
    local tnow = DECALS.now         -- the frame's clock (the file's `now` is declared further down)
    local heavyRays, lightRays = 0, 0       -- rays spent on each class this frame, against HEAVY_RAYS and the rest of RAY_BUDGET
    local lightCap = DEC.RAY_BUDGET - DEC.HEAVY_RAYS
    local heavySpeed2 = DEC.HEAVY_SPEED * DEC.HEAVY_SPEED
    for i = nP, 1, -1 do
        local age = page[i] + dt
        local life = plife[i]
        if age >= life then
            removeParticle(i)
        else
            local first = page[i] == 0
            page[i] = age
            local vx, vy, vz = pvx[i], pvy[i], pvz[i]
            local kd = pkind[i]
            local mist = KP[kd]
            local dr = 1 - KD[kd] * dt
            if dr < 0 then dr = 0 end
            vx, vy, vz = vx * dr, vy * dr + GRAVITY * KG[kd] * dt, vz * dr
            pvx[i], pvy[i], pvz[i] = vx, vy, vz
            local ox, oy, oz = px[i], py[i], pz[i]
            local x, y, z = ox + vx * dt, oy + vy * dt, oz + vz * dt
            px[i], py[i], pz[i] = x, y, z
            local hit = false
            if collide and (kd == DROPLET or kd == CLOTK) then
                if first then
                    plx[i], ply[i], plz[i], pph[i], plt[i] = ox, oy, oz, random(0, 255), tnow
                end
                local size = psize[i]
                local heavy = size >= DEC.HEAVY_SIZE or vx * vx + vy * vy + vz * vz >= heavySpeed2
                if heavy then nHeavy = nHeavy + 1 else nLight = nLight + 1 end
                local stride = heavy and strideH or strideL
                if (heavy and heavyRays < DEC.HEAVY_RAYS or not heavy and lightRays < lightCap)
                    and (stride == 1 or (frame + pph[i]) % stride == 0) then
                    if heavy then heavyRays = heavyRays + 1 else lightRays = lightRays + 1 end
                    local sx, sy, sz = plx[i], ply[i], plz[i]
                    local dx, dy, dz = x - sx, y - sy, z - sz
                    -- The start is the point of the last test, which may be a stride of frames back: the way since then is
                    -- about speed times the time, and a start further off than that (one that was not tracked, or a jump)
                    -- is not trusted: only the last step is swept then.
                    local trust = max(40, min(2000, sqrt(vx * vx + vy * vy + vz * vz) * (tnow - plt[i]) * 1.5))
                    if dx * dx + dy * dy + dz * dz > trust * trust then
                        sx, sy, sz = ox, oy, oz
                    end
                    local t, nx, ny, nz = castRay(sx, sy, sz, x, y, z)
                    if t then
                        hit = true
                        local hx, hy, hz = sx + (x - sx) * t, sy + (y - sy) * t, sz + (z - sz) * t
                        decalSplat(hx + nx * 0.2, hy + ny * 0.2, hz + nz * 0.2, nx, ny, nz, vx, vy, vz, size)
                        -- A heavy droplet breaks up on a hard hit: a couple of small ones thrown back off the surface.
                        local vn = -(vx * nx + vy * ny + vz * nz)
                        if size >= DEC.SPLIT_SIZE and vn > 80 and nP < preset.max * 0.9 then
                            local kids = vn > 200 and 3 or 2
                            for _ = 1, kids do
                                local k = rnd(0.2, 0.4)
                                local jx, jy, jz = rnd(-1, 1), rnd(-1, 1), rnd(-1, 1)
                                local jl = max(1e-3, sqrt(jx * jx + jy * jy + jz * jz))
                                local sp = sqrt(vx * vx + vy * vy + vz * vz) * 0.35
                                -- Reflected velocity at a fraction of the speed, jittered; never back into the surface.
                                local rvx, rvy, rvz = (vx + 2 * vn * nx) * k + jx / jl * sp, (vy + 2 * vn * ny) * k + jy / jl * sp,
                                    (vz + 2 * vn * nz) * k + jz / jl * sp
                                local into = rvx * nx + rvy * ny + rvz * nz
                                if into < 15 then
                                    rvx, rvy, rvz = rvx + nx * (15 - into), rvy + ny * (15 - into), rvz + nz * (15 - into)
                                end
                                spawn(DROPLET, hx + nx * 0.6, hy + ny * 0.6, hz + nz * 0.6, rvx, rvy, rvz,
                                      size * rnd(0.3, 0.45), rnd(0.35, 0.8), pr[i], pg[i], pb[i], pa[i])
                            end
                        end
                        removeParticle(i)
                    elseif nx == nil then
                        plx[i], ply[i], plz[i], plt[i] = x, y, z, tnow
                    end     -- (a ray the budget refused leaves the start where it was, so the next sweep covers this step too)
                end
            end
            if draw and not hit then
                local t = age / life
                local tx, ty, tz = cpx - x, cpy - y, cpz - z
                local D = sqrt(tx * tx + ty * ty + tz * tz)
                if mist then
                    if first then pph[i] = random(0, 255) end
                    if D > PUFF_CULL then
                        local h = psize[i] * (0.5 + t * KGROW[kd]) * 0.5
                        local ppu = focal / D
                        local R = h * 1.3
                        if R * ppu > PUFF_PX_MAX then R = PUFF_PX_MAX / ppu end
                        local a = pa[i] * (1 - t) * (1 - t)
                        local fi = KFADE[kd]
                        if fi > 0 and t * fi < 1 then a = a * t * fi end
                        if D < PUFF_FADE then a = a * (D - PUFF_CULL) / (PUFF_FADE - PUFF_CULL) end
                        local tl = TK and TK[kd]
                        if a > 0.004 and tl then
                            -- A soft sprite, turned by the puff's seed (its axis is the camera's right turned that far).
                            local sd = pph[i]
                            local c, s = RC[sd + 1], RS[sd + 1]
                            col.r, col.g, col.b, col.a = min(1, pr[i] * PUFF_GAIN), min(1, pg[i] * PUFF_GAIN), min(1, pb[i] * PUFF_GAIN), min(1, a * PUFF_GAIN)
                            R = R * 1.15
                            SPR(tl[sd % #tl + 1], x, y, z, R, R, rx * c + ux * s, ry * c + uy * s, rz * c + uz * s, col, "alpha")
                        elseif a > 0.004 then
                            local rpx = R * ppu / lf
                            local nl = rpx < 4 and 1 or rpx < 14 and 2 or rpx < 40 and 3 or 4
                            nPuff = nPuff + 1
                            if nPuff > 60 then nl = 1 elseif nPuff > 28 and nl > 2 then nl = 2 end
                            PD.puff(x, y, z, R, pr[i], pg[i], pb[i], a, pph[i], nl, rx, ry, rz, ux, uy, uz)
                        end
                    end
                else
                    local sp = sqrt(vx * vx + vy * vy + vz * vz)
                    if sp > 1e-3 and D > NEAR_CULL then
                        -- A droplet stretches with its speed, and one that has been flying a while stretches more (and thins
                        -- out, as a stretched drop does). Far ones are grown a little and near ones held, by their width in pixels.
                        local ppu = focal / D
                        local size = psize[i]
                        local pw = size * ppu
                        if pw < PX_MIN then
                            size = min(size * BOOST, PX_MIN / ppu)
                        elseif pw > PX_MAX then
                            size = PX_MAX / ppu
                        end
                        local hl2 = sp * STREAK_SECONDS * (1 + DROP.AGE_GAIN * min(age, 1.2))
                        if hl2 < STREAK_MIN then hl2 = STREAK_MIN elseif hl2 > STREAK_MAX then hl2 = STREAK_MAX end
                        if kd == CHARK then hl2 = hl2 * DROP.CHAR_STREAK end    -- a flake tumbles, it does not streak
                        if hl2 > DROP.LEN_MAX / ppu then hl2 = DROP.LEN_MAX / ppu end
                        if hl2 < size * 1.2 then hl2 = size * 1.2 end
                        local tl = TK and TK[kd]
                        if tl then
                            -- One soft sprite along the velocity (a unit axis), whatever the size: no fans, no fringe, no levels of detail.
                            local a = pa[i]
                            if t > FADE_START then a = a * (1 - t) / (1 - FADE_START) end
                            if D < NEAR_FADE then a = a * (D - NEAR_CULL) / (NEAR_FADE - NEAR_CULL) end
                            local isp = 1 / sp
                            local ex, ey, ez = vx * isp, vy * isp, vz * isp
                            if first and (not collide or kd == CHARK) then pph[i] = random(0, 255) end
                            local sd = pph[i]
                            if kd == CLOTK then
                                -- a lumpy glossy blob, stretched a little by its speed
                                local hw = size * 0.64
                                col.r, col.g, col.b, col.a = min(1, pr[i] * CLOT_TINT), min(1, pg[i] * CLOT_TINT), min(1, pb[i] * CLOT_TINT), a
                                SPR(tl[sd % 4 + 1], x, y, z, hw, hw * (1 + min(0.7, sp * 0.0025)), ex, ey, ez, col, "alpha")
                            elseif kd == CHARK then
                                -- a dry fleck that tumbles: hardly stretched
                                local hw = size * 0.62
                                col.r, col.g, col.b, col.a = min(1, pr[i] * CHAR_TINT), min(1, pg[i] * CHAR_TINT), min(1, pb[i] * CHAR_TINT), a
                                SPR(tl[sd % 2 + 1], x, y, z, hw, min(hw * 1.8, max(hw, hl2 * 0.5)), ex, ey, ez, col, "alpha")
                            else
                                -- The fat teardrop up to a stretch of about three, the slim one beyond; each texture's widest point is
                                -- 0.84 (0.56) of its width, so the sprite is wider than the body it draws by that.
                                local thin = 1 / sqrt(max(1, hl2 / max(size, 0.5) * 0.35))
                                local hw = size * 0.5 * thin
                                col.r, col.g, col.b, col.a = pr[i] * SPR_BODY, pg[i] * SPR_BODY, pb[i] * SPR_BODY, a
                                if hl2 < hw * 5.8 then
                                    SPR(tl[1], x, y, z, hw * 1.35, hl2 * 0.5, ex, ey, ez, col, "alpha")
                                else
                                    SPR(tl[2], x, y, z, hw * 2.0, hl2 * 0.5, ex, ey, ez, col, "alpha")
                                end
                                local gl = TK.glint
                                if gl and size >= DROP.GLINT_SIZE and hw * 2 * ppu >= DROP.GLINT_PX then
                                    -- The light is up and to the left of the camera: a white spark near the head, a little toward the
                                    -- camera so that the body does not hide it.
                                    local gk, go = 0.4 / D, hw * 0.35
                                    local ha = hl2 * 0.5 * 0.45
                                    col.r, col.g, col.b, col.a = 1, 0.9, 0.88, a * DROP.GLINT_GAIN
                                    local gr = max(0.2, hw * 0.4)
                                    SPR(gl, x + ex * ha + (ux * 0.35 - rx * 0.3) * go + tx * gk, y + ey * ha + (uy * 0.35 - ry * 0.3) * go + ty * gk,
                                        z + ez * ha + (uz * 0.35 - rz * 0.3) * go + tz * gk, gr, gr, 0, 0, 0, col, "additive")
                                end
                            end
                        else
                            local k = hl2 * 0.5 / sp
                            local ax, ay, az = vx * k, vy * k, vz * k
                            -- The short axis is perpendicular to both the streak and the line to the camera.
                            local sx, sy, sz = ay * tz - az * ty, az * tx - ax * tz, ax * ty - ay * tx
                            local sl = sqrt(sx * sx + sy * sy + sz * sz)
                            if sl > 1e-6 then
                                local thin = 1 / sqrt(max(1, hl2 / max(size, 0.5) * 0.35))
                                local hw = size * 0.5 * thin
                                local w = hw / sl
                                sx, sy, sz = sx * w, sy * w, sz * w
                                local a = pa[i]
                                if t > FADE_START then a = a * (1 - t) / (1 - FADE_START) end
                                if D < NEAR_FADE then a = a * (D - NEAR_CULL) / (NEAR_FADE - NEAR_CULL) end
                                local r, g, b = pr[i], pg[i], pb[i]
                                local pxw = hw * 2 * ppu
                                local lod = pxw < LOD2 and 1 or pxw < LOD3 and 2 or 3
                                if lod == 3 and kd == CHARK then lod = 2 end
                                if lod == 3 then
                                    nBig = nBig + 1
                                    if nBig > DROP.BIG_MAX then lod = 2 end
                                end
                                local br, bg, bb = r * BODY, g * BODY, b * BODY
                                if lod == 3 then
                                    -- The fringe first, the same colour and fainter, about a pixel past the edge all round (so the
                                    -- width and the length grow by different factors); then the body.
                                    local kw, kl = 1 + DROP.FRINGE_PX * 2 / pxw, 1 + DROP.FRINGE_PX * 2 / max(pxw, hl2 * ppu)
                                    PD.drop(3, 1, x, y, z, ax * kl, ay * kl, az * kl, sx * kw, sy * kw, sz * kw, br, bg, bb,
                                            a * DROP.FRINGE_ALPHA)
                                end
                                PD.drop(lod, 1, x, y, z, ax, ay, az, sx, sy, sz, br, bg, bb, a)
                                if lod == 3 and pxw >= DROP.GLINT_PX and size >= DROP.GLINT_SIZE then
                                    -- The light is up and to the left of the camera: a tiny faint glint toward the head, a little
                                    -- toward the camera so that the body does not hide it.
                                    local gk, go = 0.4 / D, hw * 0.35
                                    PD.glint(x + ax * 0.45 + (ux * 0.35 - rx * 0.3) * go + tx * gk,
                                             y + ay * 0.45 + (uy * 0.35 - ry * 0.3) * go + ty * gk,
                                             z + az * 0.45 + (uz * 0.35 - rz * 0.3) * go + tz * gk,
                                             max(0.08, hw * 0.13), rx, ry, rz, ux, uy, uz, 1, 0.9, 0.88, a * 0.25)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    DECALS.prevHeavy, DECALS.prevLight = nHeavy, nLight
end

-- ---------------------------------------------------------------- lens splats
-- The lens splatter is the bloodsand/lens post-FX effect, which runs before the HUD is drawn (stage PostWorld) and looks through the
-- splats: it refracts, blurs and darkens the scene where a splat is, lets it run down in drips and shines a highlight along the
-- edge (see lens.frag). Up to LENS_MAX splats are kept here (position and size as fractions of the window, which of the four
-- shapes, and when each was born) and sent once each; the effect works out the age. Only when the effect is missing or has
-- failed (LS.bad) are the same shapes drawn as flat textures on the HUD instead.
local lensTex = {}
local LS = { x = {}, y = {}, size = {}, tex = {}, ti = {}, age = {}, life = {}, seed = {}, birth = {}, bad = false,
             fields = { "x", "y", "size", "tex", "ti", "age", "life", "seed", "birth" }, na = {}, nb = {},
             fx = { id = "bloodsand/lens", cache = {}, enabled = nil } }
local nL = 0
local tint = { r = 1, g = 1, b = 1, a = 1 }
for i = 1, LENS_MAX do LS.na[i], LS.nb[i] = "l" .. (i - 1) .. "a", "l" .. (i - 1) .. "b" end

local function loadLens()
    if not (wum.render and wum.render.windowSize and wum.draw.texture and wum.draw.hudImage) then return end
    for i = 1, 4 do
        local ok, tex = pcall(wum.draw.texture, "textures/splat" .. i .. ".png")
        if ok and tex then lensTex[i] = tex end
    end
end

-- Can a splat be shown at all, by the effect or by the HUD fallback?
function LS.can()
    return (hasPostfx and not LS.bad) or next(lensTex) ~= nil
end

local function addSplat()
    if not LS.can() then return end
    local slot
    if nL < LENS_MAX then
        nL = nL + 1
        slot = nL
    else
        slot = 1
        for i = 2, nL do
            if LS.age[i] > LS.age[slot] then slot = i end
        end
    end
    local x, y = rnd(0.08, 0.92), rnd(0.08, 0.92)
    for _ = 1, 5 do
        if abs(x - 0.5) > 0.12 or abs(y - 0.5) > 0.12 then break end
        x, y = rnd(0.08, 0.92), rnd(0.08, 0.92)
    end
    LS.x[slot], LS.y[slot] = x, y
    LS.size[slot] = rnd(LENS_SIZE[1], LENS_SIZE[2])
    local ti = random(4)
    LS.ti[slot] = ti
    LS.tex[slot] = lensTex[ti] or next(lensTex) and lensTex[next(lensTex)] or false
    LS.age[slot] = 0
    LS.life[slot] = LENS_LIFE * rnd(0.85, 1.15)
    LS.seed[slot] = random(0, 99)
    LS.birth[slot] = os.clock()
end

-- Sends up to four floats to a parameter of the effect, when they changed.
local function lensSend(name, a, b, c, d)
    if not hasPostfx then return end        -- (LS.setBlood calls this on a Melange without post-FX too)
    local fx = LS.fx
    local old = fx.cache[name]
    if old and old[1] == a and old[2] == b and old[3] == c and old[4] == d then return end
    local ok, res = pcall(wum.postfx.setTransient, fx.id, name, a, b, c, d)
    if not ok or res == false then return end
    if not old then
        old = {}
        fx.cache[name] = old
    end
    old[1], old[2], old[3], old[4] = a, b, c, d
end

-- Keeps the effect in step with the splats: sends the live ones (the window's y runs down, the effect's up; the shape index
-- runs 0..3), zeroes the rest, sends the clock they age by and switches the effect on while there are any.
function LS.sync()
    if not hasPostfx or LS.bad then return end
    local on = nL > 0 and preset ~= nil and cfg.lens ~= false
    local want = on or WARM.on[LS.fx.id] == true
    if on or LS.fx.enabled then
        for i = 1, LENS_MAX do
            if on and i <= nL then
                lensSend(LS.na[i], LS.x[i], 1 - LS.y[i], LS.size[i], LS.ti[i] - 1)
                lensSend(LS.nb[i], LS.birth[i], LS.life[i], LS.seed[i], 0)
            else
                lensSend(LS.na[i], 0, 0, 0, 0)
            end
        end
        if on then
            local c = palette.lens
            lensSend("blood", c[1], c[2], c[3], 0)
            lensSend("clock", os.clock(), 0, 0, 0)
        end
    end
    if LS.fx.enabled ~= want then
        local ok, res = pcall(wum.postfx.enable, LS.fx.id, want)
        if ok and res == false then
            LS.bad = true           -- this Melange does not know the effect
        elseif ok then
            LS.fx.enabled = want
        end
    end
end

function LS.setBlood(c)
    lensSend("blood", c[1], c[2], c[3], 0)
end

local function ageSplats(dt)
    for i = nL, 1, -1 do
        local age = LS.age[i] + dt
        if age >= LS.life[i] then
            for _, k in ipairs(LS.fields) do LS[k][i] = LS[k][nL] end
            nL = nL - 1
        else
            LS.age[i] = age
        end
    end
    LS.sync()
end

-- The fallback: flat textures over everything, the HUD included.
local function drawSplats()
    if nL == 0 or not preset or not cfg.lens then return end
    if hasPostfx and not LS.bad then return end
    local w, h = wum.render.windowSize()
    if not (w and h) or w <= 0 or h <= 0 then return end
    local c = palette.lens
    tint.r, tint.g, tint.b = c[1], c[2], c[3]
    for i = 1, nL do
        local t = LS.age[i] / LS.life[i]
        local a = LENS_ALPHA
        if t > 0.5 then a = a * (1 - t) * 2 end
        tint.a = a
        local half = LS.size[i] * h * 0.5
        local cx, cy = LS.x[i] * w, LS.y[i] * h + LS.age[i] * LENS_CREEP
        if LS.tex[i] then wum.draw.hudImage(cx - half, cy - half, cx + half, cy + half, LS.tex[i], tint) end
    end
end

-- ---------------------------------------------------------------- worm tracking and bursts
local slots = {}                -- per worm slot: what was seen last frame, credit for explosions, bleeding, stains
local frameId = 0
local now = 0
local live = false              -- there is tracked state to clear when the match ends

local EX = { x = {}, y = {}, z = {}, dmg = {}, radius = {}, at = {} }
local nExp = 0
-- The game posts Worm.Damaged the moment a worm is hurt, without saying which worm. hurtAt is when the last one
-- came; hurtOpen is true until some burst has answered it.
local hurtAt, hurtOpen = -100, false

local function newSlot(x, y, z, health, alive)
    local s = {
        health = health, alive = alive, seen = frameId,
        px = x, py = y, pz = z, vx = 0, vy = 0, vz = 0, pt = now,
        ix = 0, iy = 0, iz = 0, iat = -100,
        mvx = 0, mvy = 0, mvz = 0, mvOk = false,    -- the engine velocity of the last frame, for the impulse (MEL.track)
        credited = 0, creditAt = -100, shownAt = -100,
        bleedUntil = 0, bleedRate = 0, bleedAcc = 0,
        stainRadius = nil, stainAt = 0, restSince = nil,
        gore = 0, hitQ = 0, heading = 0,    -- hitQ: 1..32, the side of the body the last hit came from (0 unknown), for the skin shader
        hmax = health, wound = 0, previewWound = 0,
        frac = 1, eye = 0, eyeShow = 0, previewEyes = 0,
        -- The gut is rolled once per slot, so once per match: whether this worm can show one and on which side.
        hasGut = random() < GUT.CHANCE, gutAz = rnd(-GUT.AZ, GUT.AZ), gut = 0, previewGut = 0,
        gutLive = false, gutPx = x, gutPy = y, gutPz = z,
        vomitAt = nil, vomitStart = 0, vomitUntil = 0, vomitAcc = 0, -- vomitUntil is 0 when no heave is going on
    }
    VIS.initGut(s)
    return s
end

-- Forgets damage, bleeding, vomiting and the dangling gut without a burst: for healing, a new round or a worm that came
-- back. The eye and gut levels follow health and the wound level on their own.
local function resetSlot(s)
    s.credited, s.shownAt, s.bleedUntil, s.bleedRate, s.bleedAcc = 0, -100, 0, 0, 0
    s.stainRadius, s.restSince = nil, nil
    s.vomitAt, s.vomitUntil, s.vomitAcc = nil, 0, 0
    s.gutLive = false
    s.dead, s.dying, s.dieNow = false, nil, nil
end

local function requestStain(s, radius)
    if not (cfg.stains and hasPostfx) then return end
    local speed2 = s.vx * s.vx + s.vy * s.vy + s.vz * s.vz
    if speed2 > REST_SPEED * REST_SPEED then
        -- Thrown: the stain waits until the worm has landed.
        s.stainRadius = max(s.stainRadius or 0, radius)
        s.stainAt = now
        s.restSince = nil
    else
        placeStain(s.px, s.py + FEET_Y, s.pz, radius)
    end
end

local function addLens(s, damage, death)
    if not (cfg.lens and CAM.ok and preset and LS.can()) then return end
    local dx, dy, dz = s.px - CAM.px, s.py + CENTRE_Y - CAM.py, s.pz - CAM.pz
    local dist = sqrt(dx * dx + dy * dy + dz * dz)
    if death then
        if dist > LENS_DEATH_NEAR then return end
    elseif damage < LENS_MIN_DAMAGE or dist > LENS_NEAR then
        return
    end
    for _ = 1, random(preset.lens) do addSplat() end
end

-- Starts or tops up a worm's bleeding.
local function addBleed(s, damage)
    local rate = min(BLEED_MAX_RATE, max(BLEED_MIN_RATE, damage * BLEED_PER_DAMAGE))
    if now < s.bleedUntil then rate = min(BLEED_MAX_RATE, rate + s.bleedRate) end
    s.bleedRate = rate
    s.bleedUntil = max(s.bleedUntil, now + min(BLEED_SECS[2], BLEED_SECS[1] + damage * BLEED_SECS_PER_DAMAGE))
end

-- == Melee sprays ===============================================================================================
-- A blood signature for each weapon, built from a few emitters on the particle pool: jets (a narrow pressurised cone;
-- a job runs one over time so it pulses), arcs (a flat fan with long streaks), clots (big slow heavy drops), mist, shred
-- (fine fast drops in every direction), a pancake that hugs the ground and a smear along a line. Particle kinds are
-- registered below (MEL.KG / KD / KP / KGROW / KFADE) and simulate() reads them from there. The classification that picks
-- the signature is in "Melee classification", further down. Everything lives in the one MEL table to spare locals.
for k, v in pairs({
    VEL_SCALE = 1,              -- engine velocity (the vel of wum.game.worms(), units per second in Melange 0.6) times this
    VEL_SAMPLE = 60, VEL_SAMPLE_EV = 15,   -- the scale is checked only for a worm moving faster than the first by its position and the second by its velocity
    STEAM = 3, CHAR = 4, CLOT = 5,                  -- particle kinds after DROPLET and MIST
    KG = {}, KD = {}, KP = {}, KGROW = {}, KFADE = {},  -- per kind: gravity multiple, drag per second, puff, growth, fade-in
    SIG = {},                   -- weapon id -> signature
    far = 0, sizeMul = 1,       -- how far from the camera the burst being sprayed is (0..1) and the droplet size factor that goes with it
    JOB_MAX = 24,
    -- the context of the hit being sprayed: set by the classification (or the preview) just before burst()
    vslot = nil, hasA = false, ax = 0, ay = 0, az = 0, expl = false,
}) do MEL[k] = v end

do
    local STEAM, CHAR, CLOT = MEL.STEAM, MEL.CHAR, MEL.CLOT
    local PR, F = {}, {}        -- parameter sets and spray functions, in tables to spare locals

    -- gravity multiple, drag (fraction of speed lost per second), puff (a flat soft quad) or streak (a stretched drop),
    -- growth of a puff over its life and the share of life it takes to fade in
    local KIND = {
        [DROPLET] = { g = 1, drag = DRAG, puff = false },
        [MIST] = { g = MIST_GRAVITY, drag = MIST_DRAG, puff = true, grow = 1, fade = 0 },
        [STEAM] = { g = -0.4, drag = 1.3, puff = true, grow = 2.8, fade = 5 },
        [CHAR] = { g = 0.5, drag = 2.2, puff = false },     -- light flakes: they slow down and flutter down, not fly like drops
        [CLOT] = { g = 1.5, drag = 0.25, puff = false },
    }
    for k, d in pairs(KIND) do
        MEL.KG[k], MEL.KD[k], MEL.KP[k], MEL.KGROW[k], MEL.KFADE[k] = d.g, d.drag, d.puff, d.grow or 1, d.fade or 0
    end

    -- Colour modes: 1 blood, 2 char (blackened), 3 poison (sickly), 4 ember, 5 steam, 6 smoke, 7 mist.
    local function colour(mode)
        local c = palette.droplet
        local r, g, b
        if mode == 1 then
            local k = rnd(0.65, 1.15)
            r, g, b = c[1] * k, c[2] * k, c[3] * k
        elseif mode == 2 then
            -- Burnt: mostly dark cooked blood, some brown soot, a few flecks of grey ash. Nothing bright, and not the flat black
            -- that read as confetti.
            local k, u = rnd(0.75, 1.25), random()
            if u < 0.55 then
                k = k * 0.45
                r, g, b = c[1] * k, c[2] * k, c[3] * k
            elseif u < 0.85 then
                r, g, b = 0.15 * k, 0.11 * k, 0.09 * k
            else
                r, g, b = 0.36 * k, 0.34 * k, 0.32 * k
            end
        elseif mode == 3 then
            local k = rnd(0.7, 1.1)
            r, g, b = (c[1] * 0.3 + 0.16) * k, (c[2] * 0.3 + 0.22) * k, (c[3] * 0.3 + 0.02) * k
        elseif mode == 4 then
            r, g, b = rnd(0.55, 0.75), rnd(0.1, 0.2), 0.03      -- a dull ember, not a bright spark
        elseif mode == 5 then
            local k = rnd(0.72, 0.9)
            r, g, b = k, k, k * 1.02
        elseif mode == 6 then
            local k = rnd(0.12, 0.26)
            r, g, b = k, k, k
        else
            local m, k = palette.mist, rnd(0.8, 1.2)
            r, g, b = m[1] * k, m[2] * k, m[3] * k
        end
        return min(1, r), min(1, g), min(1, b)
    end

    local function dropv(kind, mode, x, y, z, vx, vy, vz, size, life, alpha)
        local r, g, b = colour(mode)
        spawn(kind, x, y, z, vx, vy, vz, size * MEL.sizeMul, life, r, g, b, alpha or DROPLET_ALPHA)
    end

    local function drop(kind, mode, x, y, z, ex, ey, ez, speed, size, life, alpha)
        local r, g, b = colour(mode)
        spawn(kind, x, y, z, ex * speed, ey * speed, ez * speed, size * MEL.sizeMul, life, r, g, b, alpha or DROPLET_ALPHA)
    end

    local function puff(kind, mode, x, y, z, vx, vy, vz, size, life, alpha)
        local r, g, b = colour(mode)
        spawn(kind, x, y, z, vx, vy, vz, size, life, r, g, b, alpha)
    end

    -- A horizontal "side" vector and an "up" vector perpendicular to a direction, for fans and cones.
    local SX, SZ, UX, UY, UZ = 1, 0, 0, 1, 0
    local function basis(dx, dy, dz)
        local sx, sz = dz, -dx
        local l = sqrt(sx * sx + sz * sz)
        if l < 1e-3 then
            sx, sz, l = 1, 0, 1
        end
        SX, SZ = sx / l, sz / l
        UX, UY, UZ = dy * SZ, dz * SX - dx * SZ, -dy * SX
    end

    local function coneDir(dx, dy, dz, spread)
        local rr = spread * sqrt(random())
        local a = random() * 2 * pi
        local ca, sa = cos(a) * rr, sin(a) * rr
        local ex, ey, ez = dx + SX * ca + UX * sa, dy + UY * sa, dz + SZ * ca + UZ * sa
        local l = sqrt(ex * ex + ey * ey + ez * ez)
        if l < 1e-4 then return dx, dy, dz end
        return ex / l, ey / l, ez / l
    end

    local function tilt(dx, dy, dz, up)
        dy = dy + up
        local l = sqrt(dx * dx + dy * dy + dz * dz)
        if l < 1e-4 then return 0, 1, 0 end
        return dx / l, dy / l, dz / l
    end

    -- ------------------------------------------------------------ emitters
    -- Jet: a narrow pressurised cone. p: cone, s0 s1 (speed), z0 z1 (size), l0 l1 (life), mode, kind, gap (the drops come
    -- in up to three pulses this far apart along the jet).
    local function jet(p, ox, oy, oz, dx, dy, dz, n)
        n = min(n, poolRoom())
        if n <= 0 then return 0 end
        basis(dx, dy, dz)
        local kind, mode, gap = p.kind or DROPLET, p.mode or 1, p.gap
        for _ = 1, n do
            local ex, ey, ez = coneDir(dx, dy, dz, p.cone)
            local back = gap and floor(random() * 3) * gap or 0
            drop(kind, mode, ox - dx * back, oy - dy * back, oz - dz * back, ex, ey, ez, rnd(p.s0, p.s1), rnd(p.z0, p.z1),
                 rnd(p.l0, p.l1), p.alpha)
        end
        return n
    end

    -- Arc: a flat fan around a direction with long streaks. p: half (radians), s0 s1, z0 z1, l0 l1, vlo vhi (vertical
    -- speed fraction added), swing (sideways speed along the swing), mode, kind.
    local function arc(p, ox, oy, oz, dx, dy, dz, n, sign)
        n = min(n, poolRoom())
        if n <= 0 then return 0 end
        basis(dx, dy, dz)
        local kind, mode, swing = p.kind or DROPLET, p.mode or 1, (p.swing or 0) * sign
        for _ = 1, n do
            local th = rnd(-p.half, p.half)
            local c, s = cos(th), sin(th)
            local ex, ey, ez = dx * c + SX * s, dy * c + rnd(p.vlo, p.vhi), dz * c + SZ * s
            local l = sqrt(ex * ex + ey * ey + ez * ez)
            local sp = rnd(p.s0, p.s1) / l
            local sw = swing * rnd(0.4, 1)
            dropv(kind, mode, ox + rnd(-3, 3), oy + rnd(-4, 4), oz + rnd(-3, 3), ex * sp + SX * sw, ey * sp, ez * sp + SZ * sw,
                  rnd(p.z0, p.z1), rnd(p.l0, p.l1))
        end
        return n
    end

    local function mist(ox, oy, oz, dx, dy, dz, n, spread, speed, sizeMul)
        n = min(floor(n * (1 + MEL.far) + 0.5), poolRoom())
        sizeMul = sizeMul * (1 + 0.5 * MEL.far)
        for _ = 1, n do
            local sp = rnd(0.4, 1) * speed
            puff(MIST, 7, ox + rnd(-4, 4), oy + rnd(-4, 4), oz + rnd(-3, 3),
                 (dx + rnd(-spread, spread)) * sp, (dy + rnd(-spread, spread)) * sp, (dz + rnd(-spread, spread)) * sp,
                 rnd(MIST_SIZE[1], MIST_SIZE[2]) * sizeMul, rnd(MIST_LIFE[1], MIST_LIFE[2]), MIST_ALPHA)
        end
    end

    -- Fine fast drops in every direction.
    local function shred(cx, cy, cz, n, s0, s1)
        n = min(n, poolRoom())
        if n <= 0 then return 0 end
        for _ = 1, n do
            local ey, a = rnd(-1, 1), random() * 2 * pi
            local rr = sqrt(1 - ey * ey)
            drop(DROPLET, 1, cx + rnd(-3, 3), cy + rnd(-3, 3), cz + rnd(-3, 3), rr * cos(a), ey, rr * sin(a),
                 rnd(s0, s1), rnd(0.7, 1.3), rnd(0.5, 1.0))
        end
        return n
    end

    -- A flat ring that hugs the ground. p: s0 s1, z0 z1, l0 l1, vlo vhi (vertical speed), kind.
    local function pancake(x, y, z, n, p)
        n = min(n, poolRoom())
        if n <= 0 then return 0 end
        local kind = p.kind or DROPLET
        for _ = 1, n do
            local ang = random() * 2 * pi
            local ca, sa = cos(ang), sin(ang)
            local sp = rnd(p.s0, p.s1)
            dropv(kind, 1, x + ca * rnd(2, 6), y + rnd(1, 3), z + sa * rnd(2, 6), ca * sp, rnd(p.vlo, p.vhi), sa * sp,
                  rnd(p.z0, p.z1), rnd(p.l0, p.l1))
        end
        return n
    end

    -- Drops spawned along a line behind the origin, all flung forward: faster at the front.
    local function smear(ox, oy, oz, dx, dy, dz, n, length, s0, s1)
        n = min(n, poolRoom())
        if n <= 0 then return 0 end
        for _ = 1, n do
            local back = random()
            local sp = s0 + (s1 - s0) * (1 - back) * rnd(0.6, 1)
            dropv(DROPLET, 1, ox - dx * back * length + rnd(-1.5, 1.5), oy + rnd(-4, 4), oz - dz * back * length + rnd(-1.5, 1.5),
                  (dx + rnd(-0.12, 0.12)) * sp, dy * sp + rnd(-10, 40), (dz + rnd(-0.12, 0.12)) * sp,
                  rnd(1.1, 2.4), rnd(0.7, 1.3))
        end
        return n
    end

    -- The ground under a worm: its feet, or the landscape from a ray when the game offers one (landRay).
    function MEL.ground(s)
        if DECALS.rayOK then
            -- From the middle of the worm's body (always open air) down past its feet.
            local t, nx, ny, nz = DECALS.cast(s.px, s.py + CENTRE_Y, s.pz, s.px, s.py - 30, s.pz, true)
            if t and t > 0.02 then
                return s.py + CENTRE_Y - t * (CENTRE_Y + 30), nx, ny, nz
            end
        end
        return s.py + FEET_Y, 0, 1, 0
    end

    -- ------------------------------------------------------------ jobs: emitters that run for a while
    -- type 1 jet (pulsing), 2 dribble, 3 steam and smoke. They follow the worm they were started on and end with it.
    local JET, DRIB, STEAMJ = 1, 2, 3
    local J = {}
    for i = 1, MEL.JOB_MAX do J[i] = { on = false } end
    local jobNext = 1

    -- rate is in droplets (or puffs) per second, already scaled by the caller; (ox, oy, oz) is a world point on the worm.
    local function addJob(jtype, s, delay, dur, rate, ox, oy, oz, dx, dy, dz, p, tag)
        if tag then
            for i = 1, MEL.JOB_MAX do
                if J[i].on and J[i].s == s and J[i].tag == tag then J[i].on = false end
            end
        end
        local job
        for i = 1, MEL.JOB_MAX do
            if not J[i].on then
                job = J[i]
                break
            end
        end
        if not job then
            job = J[jobNext]
            jobNext = jobNext % MEL.JOB_MAX + 1
        end
        job.on, job.type, job.s, job.tag, job.p = true, jtype, s, tag, p
        job.t0, job.t1, job.rate, job.acc = now + delay, now + delay + dur, rate, 0.99
        job.ox, job.oy, job.oz = ox - s.px, oy - s.py, oz - s.pz
        job.dx, job.dy, job.dz = dx, dy, dz
    end

    function MEL.tick(dt)
        if not preset then return end
        for i = 1, MEL.JOB_MAX do
            local j = J[i]
            if j.on then
                local s = j.s
                if now >= j.t1 or s.seen ~= frameId or not s.alive then
                    j.on = false
                elseif now >= j.t0 then
                    local x, y, z = s.px + j.ox, s.py + j.oy, s.pz + j.oz
                    local rate = j.rate
                    local jt = j.type
                    if jt == JET then
                        rate = rate * (0.35 + 0.65 * (0.5 + 0.5 * sin((now - j.t0) * (j.p.hz or 14) * 2 * pi)))
                    end
                    j.acc = j.acc + rate * dt
                    local n = 0
                    -- A puff or two per turn of the loop: stop when the pool or the frame's spawn budget is spent.
                    local room = min(poolRoom(), BUDGET.SPAWN + 60 - BUDGET.spawned)
                    while j.acc >= 1 and n < 6 and room > 1 do
                        j.acc = j.acc - 1
                        n = n + 1
                        room = room - 2
                        local p = j.p
                        if jt == JET then
                            basis(j.dx, j.dy, j.dz)
                            local ex, ey, ez = coneDir(j.dx, j.dy, j.dz, p.cone)
                            drop(p.kind or DROPLET, p.mode or 1, x, y, z, ex, ey, ez, rnd(p.s0, p.s1), rnd(p.z0, p.z1),
                                 rnd(p.l0, p.l1), p.alpha)
                        elseif jt == DRIB then
                            dropv(DROPLET, p.mode or 1, x + rnd(-1.5, 1.5), y + rnd(-1.5, 1.5), z + rnd(-1.5, 1.5),
                                  j.dx * rnd(6, 28) + rnd(-8, 8), rnd(-12, 8), j.dz * rnd(6, 28) + rnd(-8, 8),
                                  rnd(0.9, 1.7), rnd(0.6, 1.2))
                        else
                            local smoke = random() < 0.15
                            puff(STEAM, smoke and 6 or 5, x + rnd(-5, 5), y + rnd(-6, 8), z + rnd(-4, 4),
                                 rnd(-10, 10), rnd(30, 70), rnd(-10, 10), rnd(9, 16), rnd(0.6, 1.1), smoke and 0.45 or 0.55)
                            if random() < 0.1 then
                                drop(CHAR, 2, x + rnd(-4, 4), y + rnd(-4, 4), z + rnd(-3, 3), rnd(-0.5, 0.5), 1, rnd(-0.5, 0.5),
                                     rnd(40, 100), rnd(0.5, 1.0), rnd(0.4, 0.8), 0.75)
                            end
                        end
                    end
                    if j.acc > 2 then j.acc = 0 end
                end
            end
        end
    end

    function MEL.clear()
        for i = 1, MEL.JOB_MAX do J[i].on = false end
        MEL.firedLeft, MEL.firedAt, MEL.explUsedAt, MEL.snapWeapon = 0, -100, nil, nil
    end

    -- ------------------------------------------------------------ the signatures
    -- Each takes (s, damage, count, dx, dy, dz, cx, cy, cz): the victim's state, the damage estimate, the droplets the
    -- burst has to spend, the unit direction the blood goes (from the attacker to the victim) and the victim's centre.
    -- It returns how many droplets it used; the ordinary spray gets what is left of `count` times the signature's
    -- `generic` share.
    PR.BAT_ARC = { half = 1.05, s0 = 170, s1 = 440, z0 = 1.1, z1 = 2.4, l0 = 0.8, l1 = 1.5, vlo = -0.1, vhi = 0.45, swing = 90 }
    PR.BAT_FINE = { half = 1.5, s0 = 100, s1 = 320, z0 = 0.7, z1 = 1.1, l0 = 0.5, l1 = 1.0, vlo = -0.2, vhi = 0.6, swing = 40 }
    PR.BAT_STREAK = { cone = 0.2, s0 = 300, s1 = 520, z0 = 1.2, z1 = 2.0, l0 = 0.7, l1 = 1.3 }
    PR.CLOT = { cone = 0.9, s0 = 60, s1 = 170, z0 = 3.6, z1 = 5.6, l0 = 1.0, l1 = 2.0, kind = CLOT }

    function F.sprayBat(s, damage, n, dx, dy, dz, cx, cy, cz)
        local ox, oz = cx - dx * 5, cz - dz * 5          -- the contact point, on the attacker's side
        local sign = random() < 0.5 and -1 or 1
        local nArc, nFine, nStreak = floor(n * 0.5), floor(n * 0.2), floor(n * 0.1)
        arc(PR.BAT_ARC, ox, cy, oz, dx, dy, dz, nArc, sign)
        arc(PR.BAT_FINE, ox, cy, oz, dx, dy, dz, nFine, sign)
        jet(PR.BAT_STREAK, cx, cy, cz, dx, dy, dz, nStreak)
        local clots = min(8, 3 + floor(n / 30))
        jet(PR.CLOT, ox, cy, oz, dx, dy, dz, clots)
        mist(cx, cy, cz, dx, dy, dz, preset.mist + 3, 0.7, 90, 1.25)
        MEL.lens(s, damage, 160)
        return nArc + nFine + nStreak + clots
    end

    PR.PROD_JET = { cone = 0.07, s0 = 230, s1 = 340, z0 = 1.0, z1 = 1.7, l0 = 0.5, l1 = 0.9, gap = 5, hz = 9 }

    function F.sprayProd(s, damage, n, dx, dy, dz, cx, cy, cz)
        local ox, oy, oz = cx - dx * 7, cy + 1, cz - dz * 7
        local ex, ey, ez = tilt(dx, dy, dz, 0.15)
        local first = floor(n * 0.22)
        jet(PR.PROD_JET, ox, oy, oz, ex, ey, ez, first)
        local rest = floor(n * 0.45)
        addJob(JET, s, 0.03, 0.22, rest / 0.22, ox, oy, oz, ex, ey, ez, PR.PROD_JET)
        addJob(DRIB, s, 0.3, 1.4, 7 * preset.bleed, ox, oy - 2, oz, dx * 0.3, 0, dz * 0.3, PR.PROD_JET)
        mist(ox, oy, oz, ex, ey, ez, 1, 0.4, 60, 0.6)
        return first + rest + 8
    end

    -- Burnt flakes: small, few and fainter than blood, so the burn reads in the scorch on the skin and the steam, not in a
    -- cloud of dark confetti.
    PR.FP_CHAR = { cone = 0.6, s0 = 90, s1 = 220, z0 = 0.5, z1 = 1.1, l0 = 0.5, l1 = 0.9, mode = 2, kind = CHAR, alpha = 0.75 }
    PR.FP_BLOOD = { cone = 0.5, s0 = 130, s1 = 300, z0 = 1.1, z1 = 2.2, l0 = 0.7, l1 = 1.2 }
    -- A few faint embers, gone within about a third of a second.
    PR.FP_EMBER = { cone = 0.9, s0 = 50, s1 = 150, z0 = 0.9, z1 = 1.5, l0 = 0.15, l1 = 0.32, mode = 4, kind = CHAR, alpha = 0.5 }

    function F.sprayFire(s, damage, n, dx, dy, dz, cx, cy, cz)
        -- An uppercut: everything goes up, a little away from the attacker.
        local ux, uy, uz = tilt(dx * 0.4, 0, dz * 0.4, 1)
        local nChar, nBlood = floor(n * 0.25), floor(n * 0.45)
        jet(PR.FP_CHAR, cx, cy - 2, cz, ux, uy, uz, nChar)
        jet(PR.FP_BLOOD, cx, cy - 2, cz, ux, uy, uz, nBlood)
        local embers = 2 + floor(n / 40)
        jet(PR.FP_EMBER, cx, cy, cz, ux, uy, uz, embers)
        for _ = 1, min(2, poolRoom()) do
            puff(STEAM, 5, cx + rnd(-4, 4), cy + rnd(-4, 6), cz + rnd(-3, 3), rnd(-12, 12), rnd(40, 80), rnd(-12, 12),
                 rnd(12, 18), rnd(0.7, 1.2), 0.55)
        end
        addJob(STEAMJ, s, 0.05, 0.9, 8 * preset.bleed, cx, cy, cz, 0, 1, 0, nil)
        MEL.scorch(MEL.vslot, 1)
        return nChar + nBlood + embers
    end

    PR.NAIL = { cone = 0.15, s0 = 110, s1 = 250, z0 = 0.9, z1 = 1.7, l0 = 0.5, l1 = 1.1, hz = 30 }

    function F.sprayNails(s, damage, n, dx, dy, dz, cx, cy, cz)
        local holes = 5
        local per = max(2, floor(n / holes))
        basis(dx, dy, dz)
        local sx, sz = SX, SZ
        for h = 1, holes do
            local ox, oy, oz = cx - dx * 6 + sx * rnd(-6, 6), cy + rnd(-8, 8), cz - dz * 6 + sz * rnd(-6, 6)
            local ex, ey, ez = coneDir(dx, dy, dz, 0.5)
            addJob(JET, s, (h - 1) * 0.035 + rnd(0, 0.02), 0.07, per / 0.07, ox, oy, oz, ex, ey, ez, PR.NAIL)
        end
        mist(cx, cy, cz, dx, dy, dz, 2, 0.8, 70, 0.7)
        return per * holes
    end

    PR.PAN = { s0 = 110, s1 = 290, z0 = 1.2, z1 = 3.2, l0 = 0.5, l1 = 1.0, vlo = 10, vhi = 55 }
    PR.PAN_CLOT = { s0 = 70, s1 = 160, z0 = 4.0, z1 = 6.0, l0 = 0.8, l1 = 1.4, vlo = 20, vhi = 60, kind = CLOT }

    function F.sprayCrush(s, damage, n, dx, dy, dz, cx, cy, cz)
        local gy, nx, ny, nz = MEL.ground(s)
        local ring = floor(n * 0.7)
        pancake(cx, gy, cz, ring, PR.PAN)
        local clots = 4 + floor(n / 25)
        pancake(cx, gy, cz, clots, PR.PAN_CLOT)
        for _ = 1, min(floor((preset.mist + 4) * (1 + MEL.far) + 0.5), poolRoom()) do
            local a = random() * 2 * pi
            local sp = rnd(30, 70)
            puff(MIST, 7, cx + cos(a) * 4, gy + 3, cz + sin(a) * 4, cos(a) * sp, rnd(0, 15), sin(a) * sp,
                 rnd(MIST_SIZE[1], MIST_SIZE[2]) * 1.4 * (1 + 0.5 * MEL.far), rnd(MIST_LIFE[1], MIST_LIFE[2]), MIST_ALPHA)
        end
        MEL.pool(cx, gy, cz, 34, nx, ny, nz)
        return ring + clots
    end

    function F.sprayShred(s, damage, n, dx, dy, dz, cx, cy, cz)
        local fine = floor(n * 0.9)
        shred(cx, cy, cz, fine, 180, 460)
        mist(cx, cy, cz, 0, 0, 0, 3, 1, 120, 0.6)
        return fine
    end

    function F.sprayKnock(s, damage, n, dx, dy, dz, cx, cy, cz)
        local ex, ey, ez = tilt(dx, 0, dz, 0.1)
        local count = floor(n * 0.8)
        smear(cx, cy, cz, ex, ey, ez, count, 26, 80, 230)
        mist(cx, cy, cz, ex, ey, ez, 2, 0.4, 60, 0.8)
        return count
    end

    PR.FALL_PAN = { s0 = 70, s1 = 200, z0 = 1.2, z1 = 3.0, l0 = 0.5, l1 = 1.0, vlo = 20, vhi = 80 }
    PR.FALL_UP = { cone = 0.6, s0 = 70, s1 = 170, z0 = 1.2, z1 = 2.4, l0 = 0.5, l1 = 1.0 }

    function F.sprayFall(s, damage, n, dx, dy, dz, cx, cy, cz)
        local gy, nx, ny, nz = MEL.ground(s)
        local ring, up = floor(n * 0.6), floor(n * 0.2)
        pancake(cx, gy, cz, ring, PR.FALL_PAN)
        jet(PR.FALL_UP, cx, gy + 4, cz, 0, 1, 0, up)
        MEL.pool(cx, gy, cz, 12 + min(26, damage * 0.7), nx, ny, nz)
        return ring + up
    end

    -- Bullets: an entry puff on the attacker's side and a narrow fast cone leaving behind the victim.
    PR.ENTRY = { cone = 0.55, s0 = 60, s1 = 150, z0 = 0.9, z1 = 1.6, l0 = 0.4, l1 = 0.8 }
    PR.SHOT_EXIT = { cone = 0.2, s0 = 260, s1 = 520, z0 = 1.0, z1 = 2.0, l0 = 0.5, l1 = 1.0, gap = 5 }
    PR.SNIPE_EXIT = { cone = 0.12, s0 = 380, s1 = 720, z0 = 1.3, z1 = 2.6, l0 = 0.6, l1 = 1.2, gap = 6 }
    PR.SNIPE_LINE = { cone = 0.05, s0 = 600, s1 = 900, z0 = 1.0, z1 = 1.6, l0 = 0.4, l1 = 0.8 }

    function F.sprayBullet(s, damage, n, dx, dy, dz, cx, cy, cz, exit, share, strong)
        local ex, ey, ez = cx - dx * 7, cy - dy * 7, cz - dz * 7
        local entry = 5 + floor(n * 0.12)
        jet(PR.ENTRY, ex, ey, ez, -dx, -dy, -dz, entry)
        mist(ex, ey, ez, -dx, -dy, -dz, 1 + (strong and 1 or 0), 0.5, 50, 0.5)
        local xx, xy, xz = cx + dx * 8, cy + dy * 8, cz + dz * 8
        local out = floor(n * share)
        jet(exit, xx, xy, xz, dx, dy, dz, out)
        local extra = 0
        if strong then
            extra = floor(n * 0.1)
            jet(PR.SNIPE_LINE, xx, xy, xz, dx, dy, dz, extra)
            jet(PR.CLOT, xx, xy, xz, dx, dy, dz, 3)
            extra = extra + 3
            MEL.lens(s, damage, 120)
        end
        mist(xx, xy, xz, dx, dy, dz, 2 + (strong and 2 or 0), 0.25, 120, 0.8)
        return entry + out + extra
    end

    function F.sprayShotgun(s, damage, n, dx, dy, dz, cx, cy, cz)
        return F.sprayBullet(s, damage, n, dx, dy, dz, cx, cy, cz, PR.SHOT_EXIT, 0.45, false)
    end

    function F.spraySniper(s, damage, n, dx, dy, dz, cx, cy, cz)
        return F.sprayBullet(s, damage, n, dx, dy, dz, cx, cy, cz, PR.SNIPE_EXIT, 0.55, true)
    end

    PR.POISON = { cone = 0.5, s0 = 60, s1 = 150, z0 = 1.0, z1 = 1.8, l0 = 0.5, l1 = 1.0, mode = 3 }

    function F.sprayPoison(s, damage, n, dx, dy, dz, cx, cy, cz)
        local ex, ey, ez = cx - dx * 7, cy - dy * 7, cz - dz * 7
        local entry = 4 + floor(n * 0.3)
        jet(PR.POISON, ex, ey, ez, -dx, -dy + 0.2, -dz, entry)
        -- The dribble goes on for a long while, and a second arrow replaces it.
        addJob(DRIB, s, 0.2, 14, 4 * preset.bleed, ex, ey, ez, -dx * 0.4, 0, -dz * 0.4, PR.POISON, "poison")
        return entry
    end

    -- melee: counts for a hit with the weapon held (and so needs the victim within `reach`); ray: a bullet along the
    -- attacker's facing; proj: no attacker position, the victim is whoever was knocked (donkey, old woman); expl: also
    -- shapes an explosion that follows the weapon's firing within `window` seconds; shots: how many hits one firing explains.
    local SIG = MEL.SIG
    SIG[10] = { name = "Baseball bat", fn = F.sprayBat, dmg = 32, melee = true, reach = 52, shots = 1, generic = 0.25 }
    SIG[11] = { name = "Prod", fn = F.sprayProd, dmg = 15, melee = true, reach = 42, shots = 1, generic = 0 }
    SIG[12] = { name = "Fire punch", fn = F.sprayFire, dmg = 30, melee = true, reach = 48, shots = 1, generic = 0.15 }
    SIG[25] = { name = "No more nails", fn = F.sprayNails, dmg = 20, melee = true, reach = 44, shots = 1, generic = 0.1 }
    SIG[18] = { name = "Concrete donkey", fn = F.sprayCrush, dmg = 55, proj = true, expl = true, window = 20, shots = 1, generic = 0.3 }
    SIG[23] = { name = "Fatkins", fn = F.sprayCrush, dmg = 45, proj = true, expl = true, window = 20, shots = 1, generic = 0.3 }
    SIG[17] = { name = "Old woman", fn = F.sprayShred, dmg = 40, proj = true, expl = true, window = 20, shots = 1, generic = 1 }
    SIG[24] = { name = "Scouser", fn = F.sprayShred, dmg = 40, proj = true, expl = true, window = 20, shots = 1, generic = 1 }
    SIG[35] = { name = "Ninja rope knock", fn = F.sprayKnock, dmg = 14, melee = true, reach = 46, needImpulse = true, shots = 3, generic = 0.3 }
    SIG[9] = { name = "Shotgun", fn = F.sprayShotgun, dmg = 22, ray = true, window = 2.0, shots = 3, generic = 0.1 }
    SIG[28] = { name = "Sniper rifle", fn = F.spraySniper, dmg = 48, ray = true, window = 3.0, shots = 1, generic = 0.2 }
    SIG[26] = { name = "Poison arrow", fn = F.sprayPoison, dmg = 14, ray = true, window = 4.0, shots = 1, generic = 0.25 }
    MEL.FALL = { name = "Fall", fn = F.sprayFall, dmg = 14, generic = 0.2 }
end

-- Sprays a signature for burst(): returns the droplets it used.
function MEL.spray(sig, s, damage, count, dx, dy, dz, cx, cy, cz)
    return sig.fn(s, damage, count, dx, dy, dz, cx, cy, cz) or 0
end

-- One more lens splat for a hit close to the camera (the burst's own lens test has already run or will run).
function MEL.lens(s, damage, near)
    if not (cfg.lens and CAM.ok and preset and LS.can()) then return end
    local dx, dy, dz = s.px - CAM.px, s.py + CENTRE_Y - CAM.py, s.pz - CAM.pz
    if dx * dx + dy * dy + dz * dz < near * near then addSplat() end
end

-- The queue of bursts whose droplets did not fit in a frame's spawn budget (BUDGET), a ring in arrays so nothing is allocated.
-- Each entry keeps the context MEL.hit set for it (the victim's slot, the attacker's position, whether it was an explosion).
local BQ = { n = 0, head = 1, s = {}, dmg = {}, dx = {}, dy = {}, dz = {}, death = {}, sig = {}, at = {},
             vslot = {}, hasA = {}, ax = {}, ay = {}, az = {}, expl = {} }

-- The droplets, mist and weapon spray of one burst: the part that costs. The direction is a unit vector. The caller has
-- checked that the pool has room and the frame's spawn budget is not spent.
local function emitBurst(s, damage, dx, dy, dz, death, sig)
    if death then
        -- A full pool gives way to a death: particles go (at most DEATH_ROOM a frame, so a blast of deaths does not clear it).
        for _ = 1, min(BUDGET.DEATH_ROOM - poolRoom(), BUDGET.DEATH_ROOM - BUDGET.evicted) do
            if nP > 0 then
                removeParticle(1)
                BUDGET.evicted = BUDGET.evicted + 1
            end
        end
    end
    local room = poolRoom()
    if room <= 0 then return end
    local cx, cy, cz = s.px, s.py + CENTRE_Y, s.pz
    local strength = min(damage, DEATH_DAMAGE) / DEATH_DAMAGE
    local spread = death and 1.1 or 0.55
    -- Far from the camera a burst throws bigger droplets and more mist, to read at the usual distance of play.
    local far = 0
    if CAM.ok then
        local ex, ey, ez = cx - CAM.px, cy - CAM.py, cz - CAM.pz
        far = min(1, max(0, (sqrt(ex * ex + ey * ey + ez * ez) - FAR_START) / FAR_SPAN))
    end
    local sizeMul = 1 + 0.45 * far
    MEL.far, MEL.sizeMul = far, sizeMul
    local count = min(BURST_MAX, floor((damage + BURST_BASE) * preset.perDamage * (1 + 0.35 * far) + 0.5))
    -- No more than the frame has left to spawn, and no more than half of the room in the pool (FAIR_MIN at least), so the
    -- worms of one blast, which burst one after another, each get a share. A death may overspend the frame (DEATH_EXTRA) and
    -- takes what it needs of the pool.
    if death then
        count = min(count, max(BUDGET.SPAWN + BUDGET.DEATH_EXTRA - BUDGET.spawned, 40), room)
    else
        count = min(count, BUDGET.SPAWN - BUDGET.spawned, max(BUDGET.FAIR_MIN, floor(room * 0.5)))
    end
    local gen = 1
    if sig then
        gen = sig.generic or 0
        local used = MEL.spray(sig, s, damage, count, dx, dy, dz, cx, cy, cz)
        count = max(0, min(floor(count * gen + 0.5), BURST_MAX - used))
    end
    count = min(count, poolRoom())
    local c = palette.droplet
    for _ = 1, count do
        local ex, ey, ez = dx + rnd(-1, 1) * spread, dy + rnd(-1, 1) * spread, dz + rnd(-1, 1) * spread
        local el = sqrt(ex * ex + ey * ey + ez * ez)
        if el < 1e-4 then ex, ey, ez, el = 0, 1, 0, 1 end
        local speed = rnd(DROPLET_SPEED[1], DROPLET_SPEED[2]) * (0.7 + 0.6 * strength) / el
        local shade = rnd(0.65, 1.15)
        spawn(DROPLET, cx + rnd(-4, 4), cy + rnd(-5, 5), cz + rnd(-2, 2), ex * speed, ey * speed, ez * speed,
              rnd(DROPLET_SIZE[1], DROPLET_SIZE[2]) * sizeMul, rnd(DROPLET_LIFE[1], DROPLET_LIFE[2]),
              min(1, c[1] * shade), min(1, c[2] * shade), min(1, c[3] * shade), DROPLET_ALPHA)
    end
    if death then
        -- Heavy clots thrown out of the blast all round and up: they carry past the smoke of the explosion and splat round
        -- the crater, so the death reads as a burst of its own.
        for _ = 1, min(BUDGET.DEATH_CLOTS, poolRoom()) do
            local a, up, sp, shade = random() * 2 * pi, rnd(0.35, 1.1), rnd(140, 280), rnd(0.55, 0.85)
            local hl = sqrt(1 + up * up)
            spawn(MEL.CLOT, cx + rnd(-3, 3), cy + rnd(-3, 3), cz + rnd(-3, 3), cos(a) / hl * sp, up / hl * sp, sin(a) / hl * sp,
                  rnd(3.0, 5.0) * sizeMul, rnd(1.2, 2.0), min(1, c[1] * shade), min(1, c[2] * shade), min(1, c[3] * shade),
                  DROPLET_ALPHA)
        end
    end
    local m = palette.mist
    for _ = 1, min(floor((death and preset.mist * 2 or preset.mist) * gen * (1 + far) + 0.5), poolRoom()) do
        local shade = rnd(0.8, 1.2)
        local speed = rnd(DROPLET_SPEED[1], DROPLET_SPEED[2]) * 0.25
        spawn(MIST, cx + rnd(-4, 4), cy + rnd(-4, 4), cz + rnd(-2, 2),
              (dx + rnd(-0.5, 0.5)) * speed, (dy + rnd(-0.5, 0.5)) * speed, (dz + rnd(-0.5, 0.5)) * speed,
              rnd(MIST_SIZE[1], MIST_SIZE[2]) * (1 + 0.5 * far), rnd(MIST_LIFE[1], MIST_LIFE[2]),
              min(1, m[1] * shade), min(1, m[2] * shade), min(1, m[3] * shade), MIST_ALPHA)
    end
end

local function enqueueBurst(s, damage, dx, dy, dz, death, sig)
    if BQ.n >= BUDGET.QUEUE then
        if not death then return end    -- a storm of hits: the rest only bleed and stain
        BQ.s[BQ.head], BQ.sig[BQ.head] = nil, nil       -- ...but a death takes the place of the oldest entry
        BQ.head = BQ.head % BUDGET.QUEUE + 1
        BQ.n = BQ.n - 1
    end
    local i = (BQ.head + BQ.n - 1) % BUDGET.QUEUE + 1
    BQ.n = BQ.n + 1
    BQ.s[i], BQ.dmg[i], BQ.dx[i], BQ.dy[i], BQ.dz[i], BQ.death[i], BQ.sig[i], BQ.at[i] = s, damage, dx, dy, dz, death, sig, now
    BQ.vslot[i], BQ.hasA[i], BQ.ax[i], BQ.ay[i], BQ.az[i], BQ.expl[i] = MEL.vslot, MEL.hasA, MEL.ax, MEL.ay, MEL.az, MEL.expl
end

-- Once a frame, before anything else bursts: the queued bursts go first, oldest first, while the frame has budget left.
local function drainBursts()
    while BQ.n > 0 do
        local i = BQ.head
        local isDeath = BQ.death[i]
        local stale = now - BQ.at[i] > (isDeath and BUDGET.DEATH_QUEUE_SECS or BUDGET.QUEUE_SECS)
        if not stale then
            if BUDGET.SPAWN + (isDeath and BUDGET.DEATH_EXTRA or 0) - BUDGET.spawned < BUDGET.MIN_LEFT
                or (poolRoom() <= 0 and not isDeath) then break end
            MEL.vslot, MEL.hasA, MEL.ax, MEL.ay, MEL.az, MEL.expl = BQ.vslot[i], BQ.hasA[i], BQ.ax[i], BQ.ay[i], BQ.az[i], BQ.expl[i]
            emitBurst(BQ.s[i], BQ.dmg[i], BQ.dx[i], BQ.dy[i], BQ.dz[i], BQ.death[i], BQ.sig[i])
        end
        BQ.s[i], BQ.sig[i] = nil, nil
        BQ.head = i % BUDGET.QUEUE + 1
        BQ.n = BQ.n - 1
    end
end

-- A burst of blood at a worm's body. (dx, dy, dz) is the direction the blood goes, in any length. A weapon signature
-- (see Melee sprays) sprays first and takes its share of the droplets; the ordinary spray gets sig.generic of its usual
-- amount. The droplets wait for the next frame when this one has spawned its share (BUDGET); the bleeding, gore, stain and
-- lens below are cheap and happen at once.
local function burst(s, damage, dx, dy, dz, death, sig)
    if not preset then return end
    local len = sqrt(dx * dx + dy * dy + dz * dz)
    if len < 1e-4 then
        dx, dy, dz, len = 0, 1, 0, 1
    end
    dx, dy, dz = dx / len, dy / len, dz / len
    if death then
        -- Straight away while the frame can bear it (a death overspends the budget by DEATH_EXTRA), else first in the queue.
        if BUDGET.SPAWN + BUDGET.DEATH_EXTRA - BUDGET.spawned < BUDGET.MIN_LEFT + 20 then
            enqueueBurst(s, damage, dx, dy, dz, death, sig)
        else
            emitBurst(s, damage, dx, dy, dz, death, sig)
        end
    elseif poolRoom() > 0 then
        if BQ.n > 0 or BUDGET.SPAWN - BUDGET.spawned < BUDGET.MIN_LEFT then
            enqueueBurst(s, damage, dx, dy, dz, death, sig)
        else
            emitBurst(s, damage, dx, dy, dz, death, sig)
        end
    end

    if death then
        s.bleedUntil = 0
        s.gore = 0
    else
        addBleed(s, damage)
        s.gore = min(1, max(s.gore, GORE_FIRST) + damage / GORE_DAMAGE)
        -- The blood goes along (dx, dz), so the hit came from the opposite side. A fall or a hit straight down has no side.
        if dx * dx + dz * dz > 0.04 then
            s.hitQ = 1 + floor((math.atan(-dx, -dz) % (2 * pi)) / (2 * pi) * 32) % 32
        end
    end
    if death or damage >= STAIN_MIN_DAMAGE then
        requestStain(s, death and STAIN_DEATH or min(STAIN_MAX, STAIN_BASE + damage * STAIN_PER_DAMAGE))
    end
    VIS.spillGut(s, damage)
    GIBS.onBurst(s, damage, dx, dy, dz, death)
    if not death then SP.hit(s, damage) end
    addLens(s, damage, death)
end

-- Where blood from an uncredited hit goes: along the worm's sudden change of velocity if there was one, otherwise
-- mostly upwards.
local function hitDirection(s)
    if now - s.iat <= IMPULSE_WINDOW then
        local l = sqrt(s.ix * s.ix + s.iy * s.iy + s.iz * s.iz)
        return s.ix, s.iy + l * 0.3, s.iz
    end
    return rnd(-0.5, 0.5), 1, rnd(-0.3, 0.3)
end

local function updateMotion(s, x, y, z)
    local dx, dy, dz = x - s.px, y - s.py, z - s.pz
    if dx * dx + dy * dy + dz * dz > 1e-4 then
        -- After a rest the first move is a change from standing still, so the time spent resting does not count.
        local span = min(now - s.pt, REST_GAP)
        if span > 1e-4 then
            local nx, ny, nz = dx / span, dy / span, dz / span
            if nx * nx + ny * ny + nz * nz > TELEPORT_SPEED * TELEPORT_SPEED then nx, ny, nz = 0, 0, 0 end
            local cx, cy, cz = nx - s.vx, ny - s.vy, nz - s.vz
            if cx * cx + cy * cy + cz * cz > IMPULSE_MIN * IMPULSE_MIN then
                s.ix, s.iy, s.iz, s.iat = cx, cy, cz, now
            end
            s.vx, s.vy, s.vz = nx, ny, nz
        end
        s.pt = now
        s.px, s.py, s.pz = x, y, z
    elseif now - s.pt > REST_GAP then
        s.vx, s.vy, s.vz = 0, 0, 0
    end
end

-- The worm's facing as a unit vector in x and z.
local function facing(s)
    return sin(s.heading), cos(s.heading)
end

-- Only for a Melange that does not report the worm's yaw: turns the blood pattern toward the direction the worm walks,
-- the short way round.
local function steerHeading(s, dt)
    local vx, vz = s.vx, s.vz
    local sp2 = vx * vx + vz * vz
    if sp2 < HEADING_SPEED[1] * HEADING_SPEED[1] or sp2 > HEADING_SPEED[2] * HEADING_SPEED[2] then return end
    local diff = (math.atan(vx, vz) - s.heading + math.pi) % (2 * math.pi) - math.pi
    s.heading = s.heading + diff * min(1, HEADING_TURN * dt)
end

local function emitBleed(s, dt)
    if not (s.alive and now < s.bleedUntil) then return end
    local fade = min(1, (s.bleedUntil - now) / 2)
    s.bleedAcc = s.bleedAcc + s.bleedRate * preset.bleed * fade * dt
    local c = palette.droplet
    local n = 0
    while s.bleedAcc >= 1 and n < 3 do
        s.bleedAcc = s.bleedAcc - 1
        n = n + 1
        local shade = rnd(0.65, 1.1)
        spawn(DROPLET, s.px + rnd(-3, 3), s.py + CENTRE_Y + rnd(-3, 3), s.pz + rnd(-1, 1),
              rnd(-25, 25), rnd(-5, 35), rnd(-10, 10), rnd(0.9, 1.8), rnd(0.6, 1.2),
              min(1, c[1] * shade), min(1, c[2] * shade), min(1, c[3] * shade), DROPLET_ALPHA)
    end
    if s.bleedAcc > 2 then s.bleedAcc = 0 end
end

-- A stain waiting for a thrown worm goes down once the worm has been still for a moment.
local function settleStain(s)
    if not s.stainRadius then return end
    if now - s.stainAt > PENDING_SECS then
        s.stainRadius, s.restSince = nil, nil
    elseif s.vx * s.vx + s.vy * s.vy + s.vz * s.vz < REST_SPEED * REST_SPEED then
        s.restSince = s.restSince or now
        if now - s.restSince >= REST_SECS then
            placeStain(s.px, s.py + FEET_Y, s.pz, s.stainRadius)
            s.stainRadius, s.restSince = nil, nil
        end
    else
        s.restSince = nil
    end
end

-- Remembers that damage has been shown on a worm, so the health the game takes off later is not shown again.
local function credit(s, damage)
    if now - s.creditAt > CREDIT_SECS then s.credited = 0 end
    s.credited = s.credited + damage
    s.creditAt = now
    s.shownAt = now
end

-- The game takes health off at the end of the turn, seconds after the hit. If the hit was already shown, whatever
-- the estimate missed only makes the worm bleed; a drop nothing explains gets its own burst.
local function settleHealth(s, drop)
    if now - s.creditAt > CREDIT_SECS then s.credited = 0 end
    local uncredited = max(0, drop - s.credited)
    s.credited = max(0, s.credited - drop)
    if DEBUG then wum.log.debug("health drop", drop, uncredited) end
    if uncredited < 1 then return end
    if now - s.shownAt <= CREDIT_SECS then
        addBleed(s, uncredited)
        s.gore = min(1, s.gore + uncredited / GORE_DAMAGE)
    else
        local dx, dy, dz = hitDirection(s)
        burst(s, uncredited, dx, dy, dz)
    end
end

-- == Melee classification =======================================================================================
-- Which weapon hurt whom. The game says a worm was damaged without saying by what or which worm, and a weapon id may be
-- gone from wum.game.worms() by then, so the active worm's weapon is remembered every frame (MEL.curWeapon, and
-- MEL.heldWeapon with the time it was last seen) and again at Weapon.Fired, and the weapon is snapshotted when the damage
-- message arrives. A hit then finds its victim among the other worms: a held melee weapon needs a worm within reach, a
-- bullet one in front of the attacker, and a worm that was just knocked hardest wins over a nearer one.
MEL.active = nil                -- the slot whose turn it is, this frame
MEL.curWeapon = nil             -- its weapon id this frame
MEL.heldWeapon, MEL.heldSlot, MEL.heldAt = nil, nil, -100
MEL.firedWeapon, MEL.firedSlot, MEL.firedAt, MEL.firedLeft, MEL.explUsedAt = nil, nil, -100, 0, nil
MEL.snapWeapon, MEL.snapSlot, MEL.snapFired = nil, nil, false
MEL.vSum, MEL.vN, MEL.velOk = 0, 0, true
MEL.dbgAt, MEL.dbgN = -100, 0
MEL.rsStep = 0                  -- the insurance resend's next step, 0 when idle
MEL.pv = 0

do
    local HOLD_KEEP = 2.5       -- seconds a weapon id is remembered after it was last seen on the active worm
    local FALL_MIN = 230        -- a worm stopped from faster than this (downward, units per second) has fallen
    local FALL_KEEP = 0.5       -- ...within this many seconds of its fastest downward speed
    local FALL_DAMAGE = { 8, 40 }

    -- A rate-limited debug line (only with DEBUG): at most a dozen a second.
    local function dbg(...)
        if not DEBUG then return end
        if now - MEL.dbgAt > 1 then MEL.dbgAt, MEL.dbgN = now, 0 end
        if MEL.dbgN >= 12 then return end
        MEL.dbgN = MEL.dbgN + 1
        wum.log.debug("bloodsand", ...)
    end
    MEL.dbg = dbg

    function MEL.beginFrame()
        MEL.curWeapon = nil
        local a = wum.game.activeWorm and wum.game.activeWorm()
        MEL.active = tonumber(a)
    end

    -- Once per frame per known worm, after its motion was updated: its slot number, the active worm's weapon, the engine
    -- velocity (when the game gives one) as a sharper impulse, and the fastest recent fall.
    function MEL.track(s, slot, w)
        s.id = slot
        if slot == MEL.active then
            local wid = tonumber(w.weapon)
            if wid then MEL.curWeapon, MEL.heldWeapon, MEL.heldSlot, MEL.heldAt = wid, wid, slot, now end
        end
        local vy = s.vy
        local evx, evy, evz = vec(w.vel)
        if evx then
            local k = MEL.VEL_SCALE
            evx, evy, evz = evx * k, evy * k, evz * k
            -- Whether the velocity is in the units assumed: compared with the speed worked out from positions while a
            -- worm moves at a plain pace. A ratio far from 1 means VEL_SCALE is wrong, and the velocity is then ignored.
            -- The engine's velocity is about zero while a worm stands or walks, so only a worm that moves fast by its position
            -- (thrown, falling, knocked) and has some velocity says anything about the scale.
            local sp = sqrt(s.vx * s.vx + s.vy * s.vy + s.vz * s.vz)
            local ev = sqrt(evx * evx + evy * evy + evz * evz)
            if sp > MEL.VEL_SAMPLE and ev > MEL.VEL_SAMPLE_EV and sp < 600 then
                MEL.vSum, MEL.vN = MEL.vSum + min(100, sp / ev), MEL.vN + 1
                if MEL.vN >= 200 then MEL.vSum, MEL.vN = MEL.vSum * 0.5, MEL.vN * 0.5 end
                if DEBUG and MEL.vN % 50 == 0 then dbg("vel ratio (position speed / vel)", MEL.vSum / MEL.vN) end
            end
            MEL.velOk = MEL.vN < 30 or (MEL.vSum / MEL.vN >= 0.5 and MEL.vSum / MEL.vN <= 2)
            if MEL.velOk then
                -- The change since the last frame's engine velocity. (s.evx and the like belong to the intestines'
                -- noteEngineVel, which has already put this frame's value there, so the last one is kept apart.)
                if s.mvOk then
                    local cx, cy, cz = evx - s.mvx, evy - s.mvy, evz - s.mvz
                    if cx * cx + cy * cy + cz * cz > IMPULSE_MIN * IMPULSE_MIN then
                        s.ix, s.iy, s.iz, s.iat = cx, cy, cz, now
                    end
                end
                s.mvx, s.mvy, s.mvz, s.mvOk = evx, evy, evz, true
                vy = evy
            else
                s.mvOk = false
            end
        else
            s.mvOk = false
        end
        if vy < -40 and vy <= (s.fallV or 0) then
            s.fallV, s.fallAt = vy, now
        elseif now - (s.fallAt or -100) > FALL_KEEP then
            s.fallV = 0
        end
    end

    function MEL.onFired(t)
        local wid, slot = MEL.curWeapon, MEL.active
        if not wid and t - MEL.heldAt <= HOLD_KEEP then wid, slot = MEL.heldWeapon, MEL.heldSlot end
        local sig = wid and MEL.SIG[wid]
        MEL.firedWeapon, MEL.firedSlot, MEL.firedAt = wid, slot, t
        MEL.firedLeft = sig and sig.shots or 0
        MEL.explUsedAt = nil
        dbg("fired", wid, slot)
    end

    -- The damage message: keep what the attacker held or fired, before it clears.
    function MEL.onDamaged(t)
        local wid, slot, fired
        local fw = MEL.firedWeapon
        local fsig = fw and MEL.SIG[fw]
        -- A blast that was shaped by the fired weapon (explSig) is over after a moment: a later damage message, the fall of a
        -- worm it knocked for one, is not the weapon's.
        local blastOver = MEL.explUsedAt and t - MEL.explUsedAt > 0.3
        if fsig and MEL.firedLeft > 0 and not blastOver and t - MEL.firedAt <= (fsig.window or 2.5) then
            wid, slot, fired = fw, MEL.firedSlot, true
        else
            wid, slot = MEL.curWeapon, MEL.active
            if not wid and t - MEL.heldAt <= HOLD_KEEP then wid, slot = MEL.heldWeapon, MEL.heldSlot end
        end
        MEL.snapWeapon, MEL.snapSlot, MEL.snapFired = wid, slot, fired or false
        -- Where everyone stood before the knock: the hit is resolved a few frames later, when the victim has flown.
        for _, s in pairs(slots) do s.sx, s.sy, s.sz = s.px, s.py, s.pz end
    end

    -- The signature for an explosion that follows the firing of a donkey, an old woman and the like, or nil. All the
    -- worms of one blast get it; a later, unrelated explosion does not.
    function MEL.explSig()
        local fw = MEL.firedWeapon
        local sig = fw and MEL.SIG[fw]
        if not (sig and sig.expl) or now - MEL.firedAt > sig.window then return nil end
        if MEL.explUsedAt and now - MEL.explUsedAt > 0.3 then return nil end
        MEL.explUsedAt = MEL.explUsedAt or now
        return sig
    end

    -- Sets the hit's context and sprays: the burst with its bleeding, gore, stain and lens.
    function MEL.hit(sig, s, vslot, damage, dx, dy, dz, hasA, ax, ay, az, expl)
        MEL.vslot, MEL.hasA, MEL.ax, MEL.ay, MEL.az, MEL.expl = vslot, hasA, ax or 0, ay or 0, az or 0, expl or false
        burst(s, damage, dx, dy, dz, false, sig)
    end

    -- The explosion path: sets the context for the worms of one blast.
    function MEL.explContext(s)
        MEL.vslot, MEL.hasA, MEL.expl = s.id, false, true
    end

    -- A hit that no explosion came with. Returns true when it was handled here; false leaves it to the older code, which
    -- gives the worm knocked hardest an ordinary burst.
    function MEL.resolveHit()
        local wid = MEL.snapWeapon
        local sig = wid and MEL.SIG[wid]
        if sig and not MEL.snapFired and not sig.melee then sig = nil end    -- a rifle in hand explains nothing
        local a = sig and MEL.snapSlot and slots[MEL.snapSlot]
        if a and a.seen ~= frameId then a = nil end
        local victim, vslot, vscore, vimp
        if sig then
            local fx, fz
            if a then fx, fz = sin(a.heading), cos(a.heading) end
            for slot, s in pairs(slots) do
                if s.seen == frameId and s.alive and s ~= a then
                    local imp = 0
                    if now - s.iat <= IMPULSE_WINDOW then imp = s.ix * s.ix + s.iy * s.iy + s.iz * s.iz end
                    local score
                    if sig.proj then
                        if imp > 0 then score = imp end
                    elseif a then
                        local rx, ry, rz = (s.sx or s.px) - (a.sx or a.px), (s.sy or s.py) - (a.sy or a.py), (s.sz or s.pz) - (a.sz or a.pz)
                        local d = sqrt(rx * rx + rz * rz)
                        local ok
                        if sig.reach then
                            ok = d <= sig.reach and abs(ry) <= 30
                            -- With the weapon only held, a worm that just landed from a fall is a fall, and only a worm that was
                            -- knocked can be the victim (any other worm that stands near the attacker is not one).
                            if ok and not MEL.snapFired and ((s.fallV or 0) < -FALL_MIN or imp <= 0) then ok = false end
                            if ok and sig.needImpulse and imp <= 0 then ok = false end
                        else
                            local along = rx * fx + rz * fz
                            ok = along > 0 and abs(rx * fz - rz * fx) < along * 0.25 + 12
                        end
                        if ok then score = imp > 0 and 1e6 + imp or 1000 / (d + 1) end
                    end
                    if score and (not vscore or score > vscore) then victim, vslot, vscore, vimp = s, slot, score, imp end
                end
            end
        end
        local damage, dx, dy, dz
        if victim then
            damage = sig.dmg
            if a then
                local rx, ry, rz = (victim.sx or victim.px) - (a.sx or a.px), (victim.sy or victim.py) - (a.sy or a.py),
                    (victim.sz or victim.pz) - (a.sz or a.pz)
                local h = sqrt(rx * rx + rz * rz)
                if h < 1e-3 then rx, rz, h = sin(a.heading), cos(a.heading), 1 end
                local lim = (sig.ray and 0.6 or 0.35) * h
                ry = max(-lim, min(lim, ry))
                dx, dy, dz = rx / h, ry / h, rz / h
                if vimp > 0 then
                    -- Part of the way toward where the worm was actually knocked.
                    local il = sqrt(vimp)
                    dx, dy, dz = dx + victim.ix / il * 0.5, dy + victim.iy / il * 0.25, dz + victim.iz / il * 0.5
                end
            else
                dx, dy, dz = hitDirection(victim)
            end
        else
            -- No signature fits. Without a weapon, a worm that stopped from a fall gets the splat; anything else is the
            -- older code's blunt hit.
            sig, a = nil, nil
            local best, bestSize, bestSlot
            for slot, s in pairs(slots) do
                if s.seen == frameId and s.alive and now - s.iat <= IMPULSE_WINDOW then
                    local size = s.ix * s.ix + s.iy * s.iy + s.iz * s.iz
                    if not best or size > bestSize then best, bestSize, bestSlot = s, size, slot end
                end
            end
            if not best or (best.fallV or 0) > -FALL_MIN or now - (best.fallAt or -100) > FALL_KEEP + 0.1 then
                dbg("blunt", wid, best and bestSlot)
                return false
            end
            sig, victim, vslot = MEL.FALL, best, bestSlot
            damage = min(FALL_DAMAGE[2], max(FALL_DAMAGE[1], FALL_DAMAGE[1] + (-best.fallV - FALL_MIN) * 0.08))
            dx, dy, dz = 0, 1, 0
        end
        if MEL.snapFired and sig ~= MEL.FALL then MEL.firedLeft = MEL.firedLeft - 1 end
        dbg(sig.name, "victim", vslot, "damage", damage, "dir", dx, dy, dz)
        credit(victim, damage)
        if a then
            MEL.hit(sig, victim, vslot, damage, dx, dy, dz, true, a.px, a.py + CENTRE_Y, a.pz, false)
        else
            MEL.hit(sig, victim, vslot, damage, dx, dy, dz, false, 0, 0, 0, false)
        end
        return true
    end

    -- The signatures in the order the Preview menu item shows them; "explosion" is the ordinary burst.
    local ORDER = { 10, 11, 12, 25, 18, 17, 35, "fall", 9, 28, 26, "explosion" }

    -- Preview: the next signature on the active worm, sprayed sideways across the screen. Returns false for the ordinary
    -- burst, which the caller then throws itself.
    function MEL.preview(s, slot)
        MEL.pv = MEL.pv % #ORDER + 1
        local key = ORDER[MEL.pv]
        local sig = key == "fall" and MEL.FALL or MEL.SIG[key]
        local name = sig and sig.name or "Explosion"
        if wum.log and wum.log.info then wum.log.info("Bloodsand preview: " .. name) end
        if not sig then return false end
        local dx, dz
        if CAM.ok then dx, dz = CAM.rx, CAM.rz else dx, dz = sin(s.heading), cos(s.heading) end
        local l = sqrt(dx * dx + dz * dz)
        if l < 1e-3 then dx, dz, l = 1, 0, 1 end
        dx, dz = dx / l, dz / l
        local dy = sig.ray and 0.05 or 0.1
        if sig == MEL.FALL then dx, dy, dz = 0, 1, 0 end
        MEL.hit(sig, s, slot, sig.dmg, dx, dy, dz, true, s.px - dx * 30, s.py + CENTRE_Y, s.pz - dz * 30, false)
        return true
    end
end

-- The worm's wound level this frame: from its health less the damage already shown but not yet taken off by the game,
-- as a fraction of the highest health seen on the slot. Healing raises health, so the wounds close again. The fraction
-- itself is kept in s.frac (1 when it cannot be worked out and for a dead worm) for the eyes and the vomiting.
local function updateWound(s, dt)
    if not s.alive then
        s.wound, s.previewWound, s.previewEyes, s.previewGut, s.frac = 0, 0, 0, 0, 1
        return
    end
    if s.health > s.hmax then s.hmax = s.health end
    local credited = s.credited
    if now - s.creditAt > CREDIT_SECS then credited = 0 end
    local w = 0
    local frac = 1
    if s.hmax > 0 then
        frac = max(0, s.health - credited) / s.hmax
        w = (WOUND_START - frac) / (WOUND_START - WOUND_FULL)
        if w < 0 then w = 0 elseif w > 1 then w = 1 end
    end
    s.frac = frac
    if s.previewWound > 0 then
        s.previewWound = max(0, s.previewWound - PREVIEW_WOUND / PREVIEW_SECS * dt)
        if s.previewWound > w then w = s.previewWound end
    end
    if s.previewEyes > 0 then s.previewEyes = max(0, s.previewEyes - dt / PREVIEW_SECS) end
    if s.previewGut > 0 then s.previewGut = max(0, s.previewGut - dt / PREVIEW_SECS) end
    s.wound = w
end

-- The eye level sent to the shader: from the health fraction, faded out while the worm is thrown.
local function updateEyes(s, dt)
    if not s.alive then
        s.eye, s.eyeShow = 0, 0
        return
    end
    local level = (EYE.START - s.frac) / (EYE.START - EYE.FULL)
    if level < 0 then level = 0 elseif level > 1 then level = 1 end
    if s.previewEyes > level then level = s.previewEyes end
    local step = EYE.FADE * dt
    if s.vx * s.vx + s.vy * s.vy + s.vz * s.vz < EYE.SPEED * EYE.SPEED then
        s.eyeShow = min(1, s.eyeShow + step)
    else
        s.eyeShow = max(0, s.eyeShow - step)
    end
    s.eye = level * s.eyeShow
end

-- ---------------------------------------------------------------- viscera
-- == Viscera: intestines, scorch and wound sites ==
-- The whole of it is one function, called once at load, so that its locals are its own (a function may have 200 of them, and
-- the file's main function is nearly full) and only what is assigned to VIS and the four names above is visible outside.
do
local function build()
-- The intestines are a chain of GUT.POINTS points pinned at a root inside the belly. The chain is simulated here with
-- Verlet integration (it sags, drags on the ground, piles up in coils, slides out further when the worm is hit again
-- and stretches when it is knocked) and drawn by the bloodsand/guts post-FX effect, which ray-marches it as tubes. Only
-- when that effect is missing or failed are the old flat ribbons drawn instead (drawGuts).
local ceil, exp = math.ceil, math.exp
-- The ground comes from DECALS.cast (the one landRay user, with its flag and per-frame count); without it it is a flat plane at the worm's feet.
local VEL_SCALE = MEL.VEL_SCALE    -- the one scale constant: vel of wum.game.worms() is in units per second (Melange 0.6)

local GUTS = { id = "bloodsand/guts", cache = {}, enabled = nil }
local gutsMissing = false           -- the effect is not there (the old Melange cannot load it) or its shader failed

-- Sends up to four floats to a vec4 parameter, rounded so that a chain at rest sends nothing, and only when changed.
local function sendParam4(fx, name, a, b, c, d)
    if not hasPostfx then return end
    a, b, c, d = floor(a * 64 + 0.5) / 64, floor(b * 64 + 0.5) / 64, floor(c * 64 + 0.5) / 64, floor(d * 64 + 0.5) / 64
    local old = fx.cache[name]
    if old and old[1] == a and old[2] == b and old[3] == c and old[4] == d then return end
    local ok, res = pcall(wum.postfx.setTransient, fx.id, name, a, b, c, d)
    if not ok or res == false then return end
    if not old then
        old = {}
        fx.cache[name] = old
    end
    old[1], old[2], old[3], old[4] = a, b, c, d
end

local GUT_A, GUT_B, GUT_C, GUT_D, GUT_P = {}, {}, {}, {}, {}
for k = 1, GUT.SLOTS do
    GUT_A[k], GUT_B[k], GUT_C[k], GUT_D[k] = "g" .. (k - 1) .. "a", "g" .. (k - 1) .. "b", "g" .. (k - 1) .. "c", "g" .. (k - 1) .. "d"
    local list = {}
    for i = 1, GUT.POINTS do list[i] = "g" .. (k - 1) .. "_" .. (i - 1) end
    GUT_P[k] = list
end

-- Scorch: burnt, cracked, charred flesh on a worm's skin, 0..1, fading to nothing over SCORCH_SECS (a faint ember flicker in
-- the cracks only while the level is still above about 0.82, the first half second or so). The melee code calls
-- setScorch(slot, amount) when a hit sets a worm alight; calling it again only raises the level.
local SCORCH_SECS = 3
local scAmt, scT0 = {}, {}
for i = 1, SKIN_SLOTS do scAmt[i], scT0[i] = 0, 0 end

local function scorchLevel(i)
    local a = scAmt[i]
    if not a or a <= 0 then return 0 end
    local l = a * (1 - (now - scT0[i]) / SCORCH_SECS)
    if l > 0 then return l end
    scAmt[i] = 0
    return 0
end

-- setScorch(slot, amount): amount 0..1 (1 is a fresh, full burn); it fades over SCORCH_SECS and a lower amount never shortens a
-- burn that is still stronger.
local function scorchSet(slot, amount)
    local i = (tonumber(slot) or -1) + 1
    amount = tonumber(amount)
    if not amount or i < 1 or i > SKIN_SLOTS then return end
    if amount > 1 then amount = 1 end
    if amount <= 0 then
        scAmt[i] = 0
    elseif amount > scorchLevel(i) then
        scAmt[i], scT0[i] = amount, now
    end
end

-- The wound sites. skin.frag places gash k of a worm at a direction on its body from the match seed and the slot (SiteDir
-- there); this is the same arithmetic, so a spurt can start where a wound is drawn. A float32 GPU and Lua's doubles agree on it
-- to about 1e-3 because each term is one product and one fract.
local function fract(x) return x - floor(x) end

local function siteDir(seed, k)
    local a0, b0 = fract(seed * 0.7548777), fract(seed * 0.5698403)
    local sa = 0.55 + 0.2 * fract(seed * 0.1234567 + 0.3)
    local sb = 0.30 + 0.2 * fract(seed * 0.2718282 + 0.6)
    return 6.2831853 * fract(a0 + k * sa), -0.35 + 1.1 * fract(b0 + k * sb)
end

local BODY_RX, BODY_RY = 5.6, 12.5  -- the body's radius and half-height, for a point on its surface from a direction
local SH_RX, SH_RY = 9.5, 16        -- skin.frag's ellipsoid for the direction of a point (en = qu / (9.5, 16, 9.5))
local GUT_R, GUT_Y = 5.5, -6.5      -- skin.frag's belly cylinder: its radius and its height above the body's middle

-- woundSites(slot[, out]): fills out (a table the caller keeps and reuses; one is made when nil) with the open wound sites
-- of the worm in this slot, in world units: out[i] = { x, y, z, nx, ny, nz, open, gut }, where (x, y, z) is on the body,
-- (nx, ny, nz) is the outward unit normal, open is how open the wound is (0..1) and gut is true for the belly opening.
-- Returns n, out: the count (entries past n are stale) and the table. Returns 0, out for a slot that is not tracked or dead.
-- The point is where skin.frag draws the gash: the shader puts gash k on the ray from the body's middle in direction s (SiteDir)
-- of its ellipsoid-normalised space qu / (SH_RX, SH_RY, SH_RX), so the point is that ray meeting the body (BODY_RX, BODY_RY),
-- not the body's point of the same unit direction (which is up to 0.14 of a unit direction off at the upper sites). The belly
-- opening is on the shader's cylinder: radius GUT_R, GUT_Y above the middle (sites_check.lua in the tooling compares both).
local sitesOf
do
-- (Hoisted out of sitesOf so that no closure is made per call: this runs every frame for every spurting worm.)
local function sitePut(out, n, px, py, pz, ch, sh, qx, qy, qz, mx, my, mz, open, gut)
    n = n + 1
    local e = out[n]
    if not e then
        e = {}
        out[n] = e
    end
    e.x, e.y, e.z = px + qx * ch + qz * sh, py + qy, pz - qx * sh + qz * ch
    e.nx, e.ny, e.nz = mx * ch + mz * sh, my, -mx * sh + mz * ch
    e.open, e.gut = open, gut
    return n
end
function sitesOf(slot, out)
    out = out or {}
    local s = slots[slot]
    if not s or not s.alive then return 0, out end
    local n = 0
    local seed = VIS.seed + slot * 37
    local H = s.heading
    local ch, sh = cos(H), sin(H)
    local px, py, pz = s.px, s.py + CENTRE_Y, s.pz
    -- (sitePut puts a point (qx, qy, qz) and unit normal (mx, my, mz) in the worm's frame, which faces +Z, into the world: the
    -- inverse of the shader's rotation about Y.)
    for k = 0, 4 do
        local o = (s.wound - k / 5) * 5
        if o > 0 then
            if o > 1 then o = 1 end
            local az, elev = siteDir(seed, k)
            local ce = cos(elev)
            local lx, ly, lz = cos(az) * ce, sin(elev), sin(az) * ce
            -- the ray in the direction (SH_RX lx, SH_RY ly, SH_RX lz) meets the body ellipsoid at t times that
            local ax, ay = SH_RX / BODY_RX, SH_RY / BODY_RY
            local t = 1 / sqrt(ax * ax * (lx * lx + lz * lz) + ay * ay * ly * ly)
            local qx, qy, qz = lx * SH_RX * t, ly * SH_RY * t, lz * SH_RX * t
            local mx, my, mz = qx / (BODY_RX * BODY_RX), qy / (BODY_RY * BODY_RY), qz / (BODY_RX * BODY_RX)
            local ml = sqrt(mx * mx + my * my + mz * mz)
            n = sitePut(out, n, px, py, pz, ch, sh, qx, qy, qz, mx / ml, my / ml, mz / ml, o, false)
        end
    end
    if s.gut > 0 then
        local a = s.gutAz
        n = sitePut(out, n, px, py, pz, ch, sh, sin(a) * GUT_R, GUT_Y, cos(a) * GUT_R, sin(a), 0, cos(a), min(1, 0.4 + s.gut * 0.6), true)
    end
    return n, out
end
end

-- Per-slot gut state. The arrays are made once and reused.
local function initGut(s)
    local n = GUT.POINTS
    s.gx, s.gy, s.gz, s.hx, s.hy, s.hz, s.gr = {}, {}, {}, {}, {}, {}, {}
    for i = 1, n do
        s.gx[i], s.gy[i], s.gz[i], s.hx[i], s.hy[i], s.hz[i], s.gr[i] = 0, 0, 0, 0, 0, 0, 0
    end
    s.gutLive, s.gutLen, s.gutExtra, s.gutStretch, s.gutTwitch, s.gutAcc = false, 0, 0, 0, 0, 0
    s.gutNa, s.gutHitAt = 0, -100
    s.gutSimAt, s.gutDrawnAt = -100, -100
    s.gvx, s.gvy, s.gvz = 0, 0, 0
    s.pax, s.pay, s.paz, s.plx, s.ply, s.plz = 0, 0, 0, 0, 0, 0
    s.evx, s.evy, s.evz, s.evFrame = 0, 0, 0, -1
    s.gutSeed = random() * 100
    -- Ground probes: a plane (a point on the ground and its unit normal) at the worm, the middle of the chain and its end.
    s.gpx, s.gpy, s.gpz, s.gpnx, s.gpny, s.gpnz, s.gpok = { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }, { 1, 1, 1 },
        { 0, 0, 0 }, { false, false, false }
    s.gpNext = 1
    s.gzone = {}
    s.gcontact = {}
    for i = 1, n do s.gzone[i], s.gcontact[i] = 1, false end
end

-- The engine's own velocity of a worm, when Melange reports it; otherwise the velocity worked out from its movement.
local function noteEngineVel(s, vel)
    if type(vel) ~= "table" or not MEL.velOk then return end     -- MEL.track decides that the velocity is in other units
    local x, y, z = vec(vel)
    if not x then return end
    s.evx, s.evy, s.evz, s.evFrame = x * VEL_SCALE, y * VEL_SCALE, z * VEL_SCALE, frameId
end

local function wormVel(s)
    if s.evFrame == frameId then return s.evx, s.evy, s.evz end
    return s.vx, s.vy, s.vz
end

-- A hit on a worm whose guts are out: more of them slides out, they jerk, and the blood on them is fresh. Called from
-- burst(); a no-op for a worm without out guts.
local function spillGut(s, damage)
    if not s.gutLive then return end
    s.gutExtra = min(GUT.EXTRA_MAX, s.gutExtra + GUT.SPILL + (damage or 0) * GUT.SPILL_PER_DAMAGE)
    s.gutTwitch = 1
    s.gutHitAt = now
    local kick = 1 + min(damage or 0, 60) * 0.03
    local hx, hy, hz = s.hx, s.hy, s.hz
    for i = 4, s.gutNa do
        -- A velocity is the difference to the previous position, so moving that is a kick.
        hx[i] = hx[i] + rnd(-1, 1) * GUT.KICK * kick * GUT.STEP
        hz[i] = hz[i] + rnd(-1, 1) * GUT.KICK * kick * GUT.STEP
        hy[i] = hy[i] - rnd(0, 1) * GUT.KICK * kick * GUT.STEP
    end
end

-- The chain's two pinned points: the root, inside the belly, and the lip, where it comes out through the opening.
local function gutRoot(s)
    local h = s.heading + s.gutAz
    local sh, ch = sin(h), cos(h)
    local y = s.py + GUT.Y
    return s.px + GUT.IN * sh, y, s.pz + GUT.IN * ch, s.px + GUT.LIP * sh, y - 0.3, s.pz + GUT.LIP * ch, sh, ch
end

-- One ground probe, from the point (x, y, z) down through the terrain. The result is a plane; a miss means no ground there.
local probesThisFrame = 0

local function probeGround(s, k, x, y, z)
    if not DECALS.rayOK or probesThisFrame >= GUT.PROBE_BUDGET then return end
    probesThisFrame = probesThisFrame + 1
    local t, nx, ny, nz = DECALS.cast(x, y + GUT.PROBE_UP, z, x, y - GUT.PROBE_DOWN, z, true)
    if t == nil then
        -- A clean miss (no second value) means no ground under that part of the chain: it hangs there. Under the worm it
        -- keeps its plane. A refused or failed ray says nothing.
        if nx == nil and k ~= 1 then s.gpok[k] = false end
        return
    end
    if ny < 0.2 then return end   -- a wall: keep the old plane
    s.gpx[k], s.gpy[k], s.gpz[k] = x, y + GUT.PROBE_UP - t * (GUT.PROBE_UP + GUT.PROBE_DOWN), z
    s.gpnx[k], s.gpny[k], s.gpnz[k] = nx, ny, nz
    s.gpok[k] = true
end

-- Resets the chain: a short stub going out of the belly. It then slides out to its length.
local function startGut(s, rx, ry, rz, lx, ly, lz, sh, ch)
    local gx, gy, gz, hx, hy, hz = s.gx, s.gy, s.gz, s.hx, s.hy, s.hz
    local vx, vy, vz = wormVel(s)
    local back = GUT.STEP
    s.gutLen, s.gutAcc, s.gutStretch, s.gutTwitch, s.gutExtra = 1.2, 0, 0, 0, 0
    s.gutNa = 4
    for i = 1, GUT.POINTS do
        -- The root and the lip, a point just outside the lip and one a segment further, falling away from the belly; the
        -- rest wait on the last.
        local x, y, z
        if i == 1 then
            x, y, z = rx, ry, rz
        elseif i == 2 then
            x, y, z = lx, ly, lz
        elseif i == 3 then
            x, y, z = lx + sh * 0.5, ly - 0.1, lz + ch * 0.5
        else
            x, y, z = lx + sh * (0.5 + GUT.SEG * 0.9), ly - GUT.SEG * 0.4, lz + ch * (0.5 + GUT.SEG * 0.9)
        end
        if i > 4 then x, y, z = gx[4], gy[4], gz[4] end
        gx[i], gy[i], gz[i] = x, y, z
        hx[i], hy[i], hz[i] = x - vx * back, y - vy * back, z - vz * back
        s.gcontact[i] = false
    end
    s.pax, s.pay, s.paz, s.plx, s.ply, s.plz = rx, ry, rz, lx, ly, lz
    s.gvx, s.gvy, s.gvz = vx, vy, vz
    s.gutLive = true
    -- Until a probe says otherwise the ground is a plane at the worm's feet.
    for k = 1, 3 do
        s.gpok[k] = true
        s.gpx[k], s.gpy[k], s.gpz[k], s.gpnx[k], s.gpny[k], s.gpnz[k] = s.px, s.py + FEET_Y, s.pz, 0, 1, 0
    end
    if DECALS.rayOK then probeGround(s, 1, s.px, s.py + 6, s.pz) end
end

-- Adds a point just outside the lip (index 3) or takes it away, so the chain's length grows and shrinks at the belly.
local function insertPoint(s, na)
    local gx, gy, gz, hx, hy, hz = s.gx, s.gy, s.gz, s.hx, s.hy, s.hz
    for i = na, 4, -1 do
        gx[i], gy[i], gz[i], hx[i], hy[i], hz[i] = gx[i - 1], gy[i - 1], gz[i - 1], hx[i - 1], hy[i - 1], hz[i - 1]
    end
    -- The new point starts at the lip with a little sideways noise, so a gut pushed out against friction buckles in random
    -- directions instead of folding back on itself.
    gx[3], gy[3], gz[3] = gx[2] + rnd(-0.4, 0.4), gy[2] + rnd(0, 0.3), gz[2] + rnd(-0.4, 0.4)
    hx[3], hy[3], hz[3] = hx[2], hy[2], hz[2]
end

local function removePoint(s, na)
    local gx, gy, gz, hx, hy, hz = s.gx, s.gy, s.gz, s.hx, s.hy, s.hz
    for i = 3, na - 1 do
        gx[i], gy[i], gz[i], hx[i], hy[i], hz[i] = gx[i + 1], gy[i + 1], gz[i + 1], hx[i + 1], hy[i + 1], hz[i + 1]
    end
end

-- The gut level, and the chain. Points 1 and 2 are pinned to the worm (the root inside the belly and the lip of the opening);
-- gutLen is the number of segments out beyond the lip: it follows what the wound level and the hits give, sliding out at
-- GUT.FEED units per second.
-- The worms that have a gut this frame, with their distance to the camera: gutUpdate (once per worm per frame, cheap) fills the
-- list and simGuts (once per frame) simulates the closest GUT.SLOTS of them, the ones the effect can draw. The others keep their
-- chain as it was and start it over when they are among the closest again.
local gutSimList, gutSimD, gutSimN = {}, {}, 0

local function beginGuts()
    gutSimN = 0
end

-- The gut level of a worm, and a candidate for the simulation.
local function gutUpdate(s, dt)
    local level = 0
    -- The tubes come out of the belly opening that bloodsand/skin paints, so no skin, no guts.
    if s.alive and not s.dead and cfg.guts and cfg.skin ~= false and not SKIN.failed then
        if s.hasGut and s.wound > GUT.START then level = min(1, (s.wound - GUT.START) / (1 - GUT.START)) end
        if s.previewGut > level then level = s.previewGut end
    end
    s.gut = level
    if level <= 0 then
        s.gutLive, s.gutExtra = false, 0
        return
    end
    local px, py, pz = s.px, s.py, s.pz
    local jx, jy, jz = px - s.gutPx, py - s.gutPy, pz - s.gutPz
    s.gutPx, s.gutPy, s.gutPz = px, py, pz
    if jx * jx + jy * jy + jz * jz > GUT.JUMP * GUT.JUMP then s.gutLive = false end   -- teleported: starts over
    local n = gutSimN + 1
    gutSimN = n
    gutSimList[n] = s
    if CAM.ok then
        local dx, dy, dz = px - CAM.px, py - CAM.py, pz - CAM.pz
        -- A worm whose guts are drawn this frame has some lead over one of about the same distance, so two worms near the
        -- fourth place do not take turns.
        gutSimD[n] = (dx * dx + dy * dy + dz * dz) * (s.gutDrawnAt == frameId - 1 and 0.64 or 1)
    else
        gutSimD[n] = s.id or 0
    end
end

-- One step of the chain of a worm that is simulated this frame. With more than two chains going it takes one fixed step and
-- fewer constraint passes.
local function gutStep(s, dt, lite)
    local px, py, pz = s.px, s.py, s.pz
    local rx, ry, rz, lx, ly, lz, sh, ch = gutRoot(s)
    local stale = now - s.gutSimAt > GUT.STALE
    s.gutSimAt = now
    if not s.gutLive or stale then
        startGut(s, rx, ry, rz, lx, ly, lz, sh, ch)
        return
    end

    -- A big change of the worm's velocity (a hit, a landing) stretches the gut and shakes it.
    local vx, vy, vz = wormVel(s)
    local dvx, dvy, dvz = vx - s.gvx, vy - s.gvy, vz - s.gvz
    s.gvx, s.gvy, s.gvz = vx, vy, vz
    local dv = sqrt(dvx * dvx + dvy * dvy + dvz * dvz)
    if dv > GUT.IMPACT_MIN then
        local k = min(1, (dv - GUT.IMPACT_MIN) / GUT.IMPACT_FULL)
        s.gutStretch = max(s.gutStretch, GUT.STRETCH * k)
        s.gutExtra = min(GUT.EXTRA_MAX, s.gutExtra + GUT.IMPACT_SPILL * k)
        s.gutTwitch = max(s.gutTwitch, k)
    end
    s.gutStretch = s.gutStretch * exp(-GUT.STRETCH_DECAY * dt)
    s.gutTwitch = max(0, s.gutTwitch - dt / GUT.TWITCH_SECS)

    -- Length: the segments out follow the target, sliding.
    local want = min(GUT.POINTS - 2, GUT.OUT_BASE + GUT.OUT_LEVEL * s.gut + s.gutExtra)
    local feed = GUT.FEED * dt / GUT.SEG
    if s.gutLen < want then
        s.gutLen = min(want, s.gutLen + feed)
    elseif s.gutLen > want + 0.02 then
        s.gutLen = max(want, s.gutLen - feed * 0.5)
    end
    local na = s.gutNa
    local wantNa = min(GUT.POINTS, ceil(s.gutLen) + 2)
    if wantNa < 3 then wantNa = 3 end
    while na < wantNa do
        na = na + 1
        insertPoint(s, na)
    end
    while na > wantNa do
        removePoint(s, na)
        na = na - 1
    end
    s.gutNa = na
    local seg = GUT.SEG * (1 + s.gutStretch)
    local restFeed = seg * (s.gutLen - (na - 3))      -- the segment from the lip to the first free point is the one growing

    -- Ground: one probe per frame in turn (the worm, the middle of the chain, its end) when Melange can say where it is.
    local gx, gy, gz, hx, hy, hz, gr = s.gx, s.gy, s.gz, s.hx, s.hy, s.hz, s.gr
    if DECALS.rayOK then
        local k = s.gpNext
        s.gpNext = k % 3 + 1
        if k == 1 then
            probeGround(s, 1, px, py + 6, pz)
        else
            local i = k == 2 and max(3, floor(na * 0.55)) or na
            probeGround(s, k, gx[i], gy[i], gz[i])
        end
    else
        s.gpx[1], s.gpy[1], s.gpz[1] = px, py + FEET_Y, pz
    end
    local gzone, gcontact = s.gzone, s.gcontact
    for i = 3, na do
        -- The nearest probe's plane is the ground for this point; if that probe found none, there is no ground there.
        local best, bd = 0, 1e18
        for k = 1, 3 do
            local dx, dz = gx[i] - s.gpx[k], gz[i] - s.gpz[k]
            local d = dx * dx + dz * dz
            if d < bd then best, bd = k, d end
        end
        if not s.gpok[best] then best = 0 end
        gzone[i] = best
    end

    -- The simulation in fixed steps; the pinned points move from where they were last frame to where they are now.
    s.gutAcc = s.gutAcc + dt
    local steps = floor(s.gutAcc / GUT.STEP)
    local maxSteps = lite and 1 or GUT.MAX_STEPS
    if steps > maxSteps then
        steps = maxSteps
        s.gutAcc = 0
    else
        s.gutAcc = s.gutAcc - steps * GUT.STEP
    end
    local damp = GUT.DAMP
    local fall = GUT.GRAVITY * GUT.STEP * GUT.STEP
    local rad = GUT.RADIUS
    local twitch = s.gutTwitch * GUT.WRITHE * GUT.STEP * GUT.STEP
    local clock = now * 2.3 + s.gutSeed
    local ax0, ay0, az0, bx0, by0, bz0 = s.pax, s.pay, s.paz, s.plx, s.ply, s.plz
    for st = 1, steps do
        local f = st / steps
        local ax, ay, az = ax0 + (rx - ax0) * f, ay0 + (ry - ay0) * f, az0 + (rz - az0) * f
        local bx, by, bz = bx0 + (lx - bx0) * f, by0 + (ly - by0) * f, bz0 + (lz - bz0) * f
        gx[1], gy[1], gz[1], hx[1], hy[1], hz[1] = ax, ay, az, ax, ay, az
        gx[2], gy[2], gz[2], hx[2], hy[2], hz[2] = bx, by, bz, bx, by, bz
        for i = 3, na do
            local x, y, z = gx[i], gy[i], gz[i]
            local wx, wy, wz = (x - hx[i]) * damp, (y - hy[i]) * damp, (z - hz[i]) * damp
            hx[i], hy[i], hz[i] = x, y, z
            local sx, sz = 0, 0
            if twitch > 0 and gcontact[i] then
                -- A grounded gut writhes: a nudge across the chain, in a wave along it.
                local j, l = min(i + 1, na), i - 1
                local tx, tz = gx[j] - gx[l], gz[j] - gz[l]
                local tl = sqrt(tx * tx + tz * tz)
                if tl > 1e-4 then
                    local w = sin(clock + i * 1.3) * twitch / tl
                    sx, sz = -tz * w, tx * w
                end
            end
            gx[i], gy[i], gz[i] = x + wx + sx, y + wy + fall, z + wz + sz
        end
        for _ = 1, lite and GUT.ITER_LITE or GUT.ITER do
            for i = 2, na - 1 do
                local j = i + 1
                local dx, dy, dz = gx[j] - gx[i], gy[j] - gy[i], gz[j] - gz[i]
                local d = sqrt(dx * dx + dy * dy + dz * dz)
                if d > 1e-6 then
                    local k = (d - (i == 2 and restFeed or seg)) / d
                    if i == 2 then
                        gx[j], gy[j], gz[j] = gx[j] - dx * k, gy[j] - dy * k, gz[j] - dz * k
                    else
                        k = k * 0.5
                        gx[i], gy[i], gz[i] = gx[i] + dx * k, gy[i] + dy * k, gz[i] + dz * k
                        gx[j], gy[j], gz[j] = gx[j] - dx * k, gy[j] - dy * k, gz[j] - dz * k
                    end
                end
            end
            for i = 3, na do
                -- The ground: a plane under the chain, its normal pushing the tube up off it.
                local z = gzone[i]
                if z > 0 then
                    local nx, ny, nz = s.gpnx[z], s.gpny[z], s.gpnz[z]
                    local d = nx * (gx[i] - s.gpx[z]) + ny * (gy[i] - s.gpy[z]) + nz * (gz[i] - s.gpz[z]) - rad * 0.85
                    if d < 0 then
                        gx[i], gy[i], gz[i] = gx[i] - nx * d, gy[i] - ny * d, gz[i] - nz * d
                        gcontact[i] = true
                    else
                        gcontact[i] = d < 0.05
                    end
                else
                    gcontact[i] = false
                end
                -- The worm's body, a vertical capsule, except where the chain comes out of it.
                if i > 3 then
                    local x, y, z2 = gx[i] - px, gy[i], gz[i] - pz
                    local cy = y
                    local y0, y1 = py + GUT.BODY_Y0, py + GUT.BODY_Y1
                    if cy < y0 then cy = y0 elseif cy > y1 then cy = y1 end
                    local dy = y - cy
                    local d2 = x * x + dy * dy + z2 * z2
                    local lim = GUT.BODY_R + rad * 0.8
                    if d2 < lim * lim then
                        local d = sqrt(d2)
                        if d > 1e-4 then
                            local k = lim / d
                            gx[i], gy[i], gz[i] = px + x * k, cy + dy * k, pz + z2 * k
                        else
                            gx[i], gz[i] = px + sh * lim, pz + ch * lim
                        end
                    end
                end
            end
        end
        -- Coils lie on one another instead of passing through: points of different loops keep a tube's width apart.
        for i = 3, na - 2 do
            local x, y, z = gx[i], gy[i], gz[i]
            for j = i + 2, na do
                local dx, dy, dz = gx[j] - x, gy[j] - y, gz[j] - z
                local d2 = dx * dx + dy * dy + dz * dz
                -- Two points apart the limit is the tightest bend; further apart it is a tube's width.
                local lim = j == i + 2 and GUT.BEND or GUT.SELF
                if d2 < lim * lim then
                    local d = sqrt(d2)
                    local k
                    if d > 1e-4 then
                        k = (lim - d) / d * 0.5
                    else
                        dx, dy, dz, k = rnd(-0.5, 0.5), 1, rnd(-0.5, 0.5), lim * 0.5
                    end
                    gx[i], gy[i], gz[i] = gx[i] - dx * k, gy[i] - dy * k, gz[i] - dz * k
                    gx[j], gy[j], gz[j] = gx[j] + dx * k, gy[j] + dy * k, gz[j] + dz * k
                end
            end
        end
        -- Friction: a point on the ground loses most of its sideways speed, and all of its speed into the ground.
        for i = 3, na do
            if gcontact[i] then
                hx[i], hz[i] = hx[i] + (gx[i] - hx[i]) * GUT.FRICTION, hz[i] + (gz[i] - hz[i]) * GUT.FRICTION
                if gzone[i] > 0 and gy[i] - hy[i] < 0 then hy[i] = gy[i] end
            end
        end
    end
    s.pax, s.pay, s.paz, s.plx, s.ply, s.plz = rx, ry, rz, lx, ly, lz
    gx[1], gy[1], gz[1], gx[2], gy[2], gz[2] = rx, ry, rz, lx, ly, lz

    -- Radii for the shader (0 beyond the end of the chain, where the points sit on the tip) and the tip's taper.
    for i = 1, na do
        local f = max(0, i - 2) / max(1, na - 2)
        gr[i] = rad * (1 - GUT.TAPER * f * f)
    end
    for i = na + 1, GUT.POINTS do
        gx[i], gy[i], gz[i], gr[i] = gx[na], gy[na], gz[na], 0
    end
end

-- Simulates the chains of the (up to GUT.SLOTS) closest worms that have a gut.
local function simGuts(dt)
    local n = gutSimN
    gutSimN = 0
    while n > GUT.SLOTS do
        local far = 1
        for i = 2, n do
            if gutSimD[i] > gutSimD[far] then far = i end
        end
        gutSimList[far], gutSimD[far] = gutSimList[n], gutSimD[n]
        n = n - 1
    end
    local lite = n > 2
    for i = 1, n do
        local s = gutSimList[i]
        gutSimList[i] = false
        gutStep(s, dt, lite)
    end
end

-- Which worms' guts the effect draws, in which of its slots. A worm keeps its slot while it stays among the closest.
local gutSlotOf = {}                -- effect slot (1..GUT.SLOTS) -> worm slot, or nil
local gutCand, gutCandD = {}, {}

local function setGutsEnabled(on)
    if WARM.on[GUTS.id] then on = true end
    if gutsMissing or not hasPostfx or GUTS.enabled == on then return end
    local ok, res = pcall(wum.postfx.enable, GUTS.id, on)
    if not ok then return end
    if res == false then
        gutsMissing = true
        return
    end
    GUTS.enabled = on
end

local function sendGutSlot(k, s)
    local gx, gy, gz, gr, na = s.gx, s.gy, s.gz, s.gr, s.gutNa
    local cx, cy, cz = 0, 0, 0
    for i = 1, na do cx, cy, cz = cx + gx[i], cy + gy[i], cz + gz[i] end
    cx, cy, cz = cx / na, cy / na, cz / na
    local r = 0
    for i = 1, na do
        local dx, dy, dz = gx[i] - cx, gy[i] - cy, gz[i] - cz
        local d = dx * dx + dy * dy + dz * dz
        if d > r then r = d end
    end
    sendParam4(GUTS, GUT_A[k], cx, cy, cz, sqrt(r) + GUT.RADIUS * 1.4 + 3)
    sendParam4(GUTS, GUT_B[k], s.px, s.py + CENTRE_Y, s.pz, min(1, 0.7 + 0.3 * s.gore))
    local g = 1
    sendParam4(GUTS, GUT_C[k], s.gpnx[g], s.gpny[g], s.gpnz[g],
               -(s.gpnx[g] * s.gpx[g] + s.gpny[g] * s.gpy[g] + s.gpnz[g] * s.gpz[g]))
    sendParam4(GUTS, GUT_D[k], VIS.seed % 37 + s.gutSeed % 63, max(0, 1 - (now - s.gutHitAt) / GUT.WET_SECS), 0, 0)
    local names = GUT_P[k]
    for i = 1, GUT.POINTS do sendParam4(GUTS, names[i], gx[i], gy[i], gz[i], gr[i]) end
end

local function clearGutSlot(k)
    sendParam4(GUTS, GUT_A[k], 0, 0, 0, 0)
    gutSlotOf[k] = nil
end

-- Runs once per frame after the worms were tracked: gives the (up to four) closest gutted worms a slot of the effect and
-- sends their chains, and keeps the effect on only while one is drawn.
local function updateGuts()
    local want = hasPostfx and preset ~= nil and cfg.guts ~= false and cfg.skin ~= false and not SKIN.failed and not gutsMissing
    local n = 0
    if want then
        for slot, s in pairs(slots) do
            if s.gutLive and s.alive and s.seen == frameId and s.gutNa >= 2 and s.gutSimAt == now then
                n = n + 1
                gutCand[n] = slot
                local dx, dy, dz = s.px - CAM.px, s.py - CAM.py, s.pz - CAM.pz
                gutCandD[n] = CAM.ok and dx * dx + dy * dy + dz * dz or slot
            end
        end
        -- Closest GUT.SLOTS: drop the farthest until few enough remain.
        while n > GUT.SLOTS do
            local far = 1
            for i = 2, n do
                if gutCandD[i] > gutCandD[far] then far = i end
            end
            gutCand[far], gutCandD[far] = gutCand[n], gutCandD[n]
            n = n - 1
        end
    end
    -- Keep each worm in the slot it had; give the rest the free ones.
    for k = 1, GUT.SLOTS do
        local w = gutSlotOf[k]
        local keep = false
        if w ~= nil then
            for i = 1, n do
                if gutCand[i] == w then
                    gutCand[i] = -1
                    keep = true
                    break
                end
            end
        end
        if not keep and w ~= nil then clearGutSlot(k) end
    end
    local drawn = 0
    for k = 1, GUT.SLOTS do
        if gutSlotOf[k] == nil then
            for i = 1, n do
                if gutCand[i] ~= -1 then
                    gutSlotOf[k] = gutCand[i]
                    gutCand[i] = -1
                    break
                end
            end
        end
        local w = gutSlotOf[k]
        if w ~= nil then
            drawn = drawn + 1
            slots[w].gutDrawnAt = frameId
            sendGutSlot(k, slots[w])
        end
    end
    setGutsEnabled(drawn > 0)
    probesThisFrame = 0
end

-- Is the guts effect usable? Melange lists effects with a failed flag, which a shader that does not compile or does not
-- draw sets. The old ribbons are drawn while it is not.
-- The skin and stains effects have no fallback to draw instead: when a driver links one and then draws nothing, Melange marks it
-- failed. What can be done is to say so in the log once, and to stop doing the work for it (SKIN.failed and STAINS.failed: no
-- droplet rays or decals, and no guts, whose tubes need the torn belly the skin effect paints).
local function checkGutsFx()
    if not (hasPostfx and wum.postfx.list) then return end
    local ok, list = pcall(wum.postfx.list)
    if not ok or type(list) ~= "table" then return end
    local found, lensFound, lensFailed = false, false, false
    for i = 1, #list do
        local e = list[i]
        if type(e) == "table" then
            if e.id == GUTS.id then
                found = true
                gutsMissing = e.failed == true
            elseif e.id == LS.fx.id then
                lensFound, lensFailed = true, e.failed == true
            elseif e.id == SKIN.id or e.id == STAINS.id then
                local fx = e.id == SKIN.id and SKIN or STAINS
                fx.failed = e.failed == true
                if fx.failed and not fx.warned then
                    fx.warned = true
                    if wum.log and wum.log.warn then
                        wum.log.warn("Bloodsand: the effect " .. fx.id .. " failed to draw on this graphics driver, so it is off")
                    end
                end
            end
        end
    end
    if not found then gutsMissing = true end
    local lensBad = not lensFound or lensFailed
    if lensBad and lensFound and not LS.warned and wum.log and wum.log.warn then
        LS.warned = true
        wum.log.warn("Bloodsand: the effect " .. LS.fx.id .. " failed to draw on this graphics driver, so the lens splatter is drawn flat")
    end
    LS.bad = lensBad
end

-- The flat ribbons: two camera-facing rectangles per segment, laid like the droplet kite but with square ends, each a
-- little longer than its segment so neighbours overlap. Only drawn when the guts effect cannot draw them.
local function drawRibbons(s, scale, col)
    local gx, gy, gz, gr = s.gx, s.gy, s.gz, s.gr
    local r, g, b = col[1], col[2], col[3]
    for i = 1, s.gutNa - 1 do
        local x1, y1, z1, x2, y2, z2 = gx[i], gy[i], gz[i], gx[i + 1], gy[i + 1], gz[i + 1]
        local mx, my, mz = (x1 + x2) * 0.5, (y1 + y2) * 0.5, (z1 + z2) * 0.5
        local k = 0.5 * 1.15
        local ax, ay, az = (x2 - x1) * k, (y2 - y1) * k, (z2 - z1) * k
        local tx, ty, tz = CAM.px - mx, CAM.py - my, CAM.pz - mz
        local sx, sy, sz = ay * tz - az * ty, az * tx - ax * tz, ax * ty - ay * tx
        local sl = sqrt(sx * sx + sy * sy + sz * sz)
        if sl > 1e-6 then
            local w = (gr[i] + gr[i + 1]) * 0.5 * scale / sl
            sx, sy, sz = sx * w, sy * w, sz * w
            corner(q1, mx - ax - sx, my - ay - sy, mz - az - sz)
            corner(q2, mx - ax + sx, my - ay + sy, mz - az + sz)
            corner(q3, mx + ax + sx, my + ay + sy, mz + az + sz)
            corner(q4, mx + ax - sx, my + ay - sy, mz + az - sz)
            emitQuad(r, g, b, 1)
        end
    end
end

local function gutDraw()
    if not CAM.ok or not (gutsMissing or not hasPostfx) then return end
    for _, s in pairs(slots) do
        if s.gutLive and s.seen == frameId and s.alive and s.gutNa >= 2 and s.gutSimAt == now then
            drawRibbons(s, 1.0, palette.gutDark)
            drawRibbons(s, GUT.CORE, palette.gut)
        end
    end
end

local function clearGuts()
    for k = 1, GUT.SLOTS do clearGutSlot(k) end
    setGutsEnabled(false)
    probesThisFrame = 0
    for i = 1, SKIN_SLOTS do scAmt[i] = 0 end
end

local SCORCH_NAMES = {}
for g = 1, 4 do SCORCH_NAMES[g] = "scorch" .. (g - 1) end

-- What the rest of the file uses.
VIS.seed = 0                        -- the match seed, kept up to date by sendSeed
VIS.scorchLevel = scorchLevel
VIS.setScorch = scorchSet
VIS.woundSites = sitesOf
VIS.initGut = initGut
VIS.noteEngineVel = noteEngineVel
VIS.spillGut = spillGut
VIS.updateGuts = updateGuts
VIS.beginGuts = beginGuts
VIS.simGuts = simGuts
VIS.checkFx = checkGutsFx
VIS.reset = clearGuts
setScorch, woundSites, updateGut, drawGuts = scorchSet, sitesOf, gutUpdate, gutDraw

-- The blood colour, to the guts effect.
function VIS.setBlood(c)
    sendParam(GUTS, "blood", c[1], c[2], c[3])
end

-- The insurance resend and the start-up zeroing (see resend and zeroAll): the effect slot k is forgotten, so that whatever it
-- holds (a chain going out of the next sendGutSlot, or zeros) is sent again.
function VIS.resendSlot(k)
    local cache = GUTS.cache
    cache[GUT_A[k]], cache[GUT_B[k]], cache[GUT_C[k]], cache[GUT_D[k]] = nil, nil, nil, nil
    for i = 1, GUT.POINTS do cache[GUT_P[k][i]] = nil end
    if gutSlotOf[k] == nil then sendParam4(GUTS, GUT_A[k], 0, 0, 0, 0) end
end

function VIS.resendBlood()
    GUTS.cache.blood = nil
end

function VIS.zero()
    for k = 1, GUT.SLOTS do sendParam4(GUTS, GUT_A[k], 0, 0, 0, 0) end
end

-- The skin effect's four scorch parameters, each holding the levels of four worm slots.
function VIS.sendScorch()
    for g = 1, 4 do
        local b = (g - 1) * 4
        sendParam4(SKIN, SCORCH_NAMES[g], scorchLevel(b + 1), scorchLevel(b + 2), scorchLevel(b + 3), scorchLevel(b + 4))
    end
end

function VIS.zeroScorch()
    for g = 1, 4 do sendParam4(SKIN, SCORCH_NAMES[g], 0, 0, 0, 0) end
end
end
build()
end


-- A heave of vomiting: droplets from the mouth for VOMIT.SECS, then a stain in front of the worm.
local function startHeave(s)
    s.vomitStart, s.vomitUntil, s.vomitAcc = now, now + VOMIT.SECS, 0
end

local function updateVomit(s, dt)
    if not (s.alive and cfg.vomit) or s.dead then
        s.vomitAt, s.vomitUntil, s.vomitAcc = nil, 0, 0
        return
    end
    local rest = s.vx * s.vx + s.vy * s.vy + s.vz * s.vz < REST_SPEED * REST_SPEED
    if s.frac <= VOMIT.FRAC then
        if not s.vomitAt then s.vomitAt = now + rnd(VOMIT.FIRST[1], VOMIT.FIRST[2]) end
        if s.vomitUntil == 0 and now >= s.vomitAt and rest then
            startHeave(s)
            s.vomitAt = now + rnd(VOMIT.EVERY[1], VOMIT.EVERY[2])
        end
    else
        s.vomitAt = nil
    end
    if s.vomitUntil == 0 then return end
    local fx, fz = facing(s)
    if now >= s.vomitUntil then
        s.vomitUntil, s.vomitAcc = 0, 0
        -- A worm knocked into the air during the heave leaves no stain: it is no longer over that ground.
        if rest then
            placeStain(s.px + fx * VOMIT.STAIN_OUT, s.py + FEET_Y, s.pz + fz * VOMIT.STAIN_OUT, VOMIT.STAIN)
        end
        s.gore = min(1, s.gore + VOMIT.GORE)
        return
    end
    -- A thrown worm does not spew, as its facing no longer says where its mouth points.
    if not rest then return end
    -- The rate swells and falls over the heave.
    local progress = (now - s.vomitStart) / VOMIT.SECS
    s.vomitAcc = s.vomitAcc + VOMIT.RATE * preset.bleed * sin(pi * min(1, max(0, progress))) * dt
    local c = palette.droplet
    local mx, my, mz = s.px + fx * VOMIT.MOUTH_OUT, s.py + VOMIT.MOUTH_Y, s.pz + fz * VOMIT.MOUTH_OUT
    local n = 0
    while s.vomitAcc >= 1 and n < VOMIT.PER_FRAME do
        s.vomitAcc = s.vomitAcc - 1
        n = n + 1
        local speed = rnd(VOMIT.SPEED[1], VOMIT.SPEED[2])
        local side = rnd(-12, 12)
        local shade = rnd(0.65, 1.1)
        spawn(DROPLET, mx + rnd(-1, 1), my + rnd(-1, 1), mz + rnd(-1, 1),
              fx * speed + fz * side, rnd(-25, 15), fz * speed - fx * side, rnd(0.9, 2.0), rnd(0.5, 1.0),
              min(1, c[1] * shade), min(1, c[2] * shade), min(1, c[3] * shade), DROPLET_ALPHA)
    end
    if s.vomitAcc > 2 then s.vomitAcc = 0 end
end

-- == Pools & trails ============================================================================================
-- A worm below two thirds of its health leaves a trail of blood drips as it walks, and below a quarter a smear where it drags
-- itself; a worm that is dying, or hurt and lying still, grows a pool under it over several seconds; and the gravestone
-- ends up in a pool with smears and spatter around it. All of it is decals (see "== Decals ==": trail pieces of kinds 3
-- and 4, which a worm extends step by step so that a trail costs a slot per 30 to 50 units and not one per step, and
-- DECALS.poolGrow). It follows the setting "Pools & trails" (cfg.pools) and needs "Blood on the ground". Without landRay the
-- ground is a plane at the worm's feet. The game's CreateGravestoneMessage has no decoder in Melange (its payload is empty and
-- it says nowhere the stone lands), so the grave is where the worm was last seen, after the death explosion.
local PT = {}
do
local PTC = {
    DRIP_FRAC = 2 / 3,          -- a worm below this share of its health drips as it walks...
    SMEAR_FRAC = 0.25,          -- ...and below this one drags a smear
    POOL_FRAC = 0.3,            -- a worm this hurt that lies still grows a pool
    STEP = 2.5,                 -- the trail is extended each time the worm has moved this far
    MOVE_MIN = 10, MOVE_MAX = 170, RISE_MAX = 80,   -- a worm walking or crawling: horizontal speed in this window, hardly any vertical speed
    LAT_TOL = 1.4,              -- a trail piece is straight: a point further than this off its line starts a new piece
    FIT_LEN = 12,               -- ...once it is this long; until then its line follows the worm
    MAX_LEN = { 54, 36 },       -- the longest a piece of drips and a piece of smear grow (the shader reaches 82 each way)
    GAP_MAX = 14,               -- a step longer than this was a jump, not a walk
    STILL_SECS = 1.5, STILL_SPEED = 15, POOL_SAME = 10,
    GROW_SECS = 8,              -- a pool under a hurt worm spreads to its size in about this long...
    DYING_SECS = 6,             -- ...a dying worm's in this
    DYING_POOL = { 15, 20 },    -- radii, at Heavy
    GRAVE_DELAY = 1.1, GRAVE_POOL = 16, GRAVE_SECS = 5, GRAVE_HOLD = 8,
    GROW_MAX = 12, GRAVE_MAX = 4,
    CALM_VY = 30, CALM_SECS = 0.4,   -- without landRay: a vertical speed over this is a worm off the ground; calm this long puts it back
}
-- Per amount: the most trail pieces there may be (of the 32 slots), the pool size, trail width and drip density factors, the smears
-- around a grave and the specks of spatter.
local LEVEL = {
    light  = { cap = 5,  pool = 0.7, width = 0.85, dens = 0.8,  smears = 2, splats = 3 },
    heavy  = { cap = 8,  pool = 1.0, width = 1.0,  dens = 1.0,  smears = 3, splats = 6 },
    absurd = { cap = 12, pool = 1.5, width = 1.25, dens = 1.25, smears = 5, splats = 11 },
}
local grow, graves = {}, {}      -- the pools that are spreading, and the graves waiting for their pool

local function level() return LEVEL[cfg.amount] or LEVEL.heavy end

local function active()
    return cfg.pools and cfg.stains and hasPostfx and preset and not STAINS.failed
end

-- The tangent frame of stains.frag (the Lua twin of tangentFrame in the decals section): T along the surface, B across.
local function tframe(nx, ny, nz)
    local rx, ry, rz = 0, 1, 0
    if abs(ny) > 0.9 then rx, ry, rz = 1, 0, 0 end
    local tx, ty, tz = ry * nz - rz * ny, rz * nx - rx * nz, rx * ny - ry * nx
    local l = sqrt(tx * tx + ty * ty + tz * tz)
    if l < 1e-6 then return 1, 0, 0, 0, 0, 1 end
    tx, ty, tz = tx / l, ty / l, tz / l
    return tx, ty, tz, ny * tz - nz * ty, nz * tx - nx * tz, nx * ty - ny * tx
end

-- The ground under (x, y, z): its height and unit normal, found from up units above to down units below with a ray; nil for none
-- (or a wall), false when the frame's rays are spent (ask again next frame). Without landRay it is the plane at y.
local function groundAt(x, y, z, up, down)
    if not DECALS.rayOK then return y, 0, 1, 0 end
    local t, nx, ny, nz = DECALS.cast(x, y + up, z, x, y - down, z, true)
    if t then
        if ny < 0.5 then return nil end
        return y + up - (up + down) * t, nx, ny, nz
    end
    if nx == "budget" then return false end
    if nx == "unavailable" then return y, 0, 1, 0 end
    return nil
end

-- ------------------------------------------------------------------ pools
local function addGrower(slot, r0, r1, secs, fresh)
    local key = DECALS.poolKey(slot)
    if not key then return nil end
    if #grow >= PTC.GROW_MAX then
        grow[1].done = true
        table.remove(grow, 1)
    end
    local g = { slot = slot, key = key, t0 = now, secs = secs, r0 = r0, r1 = r1, cur = r0, fresh = fresh }
    grow[#grow + 1] = g
    return g
end

-- A pool at (x, y, z) that grows from radius r0 to r1 in secs (and stays wet while it does). The worm's state st remembers it, so
-- that a worm that goes on lying there (or starts dying there) makes the same pool bigger and does not start another.
local function startPool(st, x, y, z, r0, r1, secs, fresh)
    local g = st.grow
    if g and (g.x - x) * (g.x - x) + (g.z - z) * (g.z - z) < PTC.POOL_SAME * PTC.POOL_SAME and DECALS.poolKey(g.slot) == g.key then
        g.r0, g.t0, g.secs, g.r1, g.fresh = g.cur, now, secs, max(g.r1, r1), fresh
        if g.done then
            g.done = nil
            if #grow >= PTC.GROW_MAX then
                grow[1].done = true
                table.remove(grow, 1)
            end
            grow[#grow + 1] = g
        end
        return
    end
    local slot = requestPool(x, y, z, r0 / 0.9)
    if not slot then return end
    g = addGrower(slot, r0, r1, secs, fresh)
    if g then
        g.x, g.z = x, z
        st.grow = g
    end
end

-- ------------------------------------------------------------------ trails
-- Sends the worm's piece with its true length now (growing pieces are throttled); closePiece also lets go of it, so that the
-- worm starts another next time, where flush leaves it to go on with the same one.
local function flush(st)
    if st.slot then DECALS.trailSet(st.slot, st.gen, st.sx, st.sy, st.sz, st.dx, st.dy, st.dz, st.len, true) end
    st.flushed = true
end

local function closePiece(st)
    flush(st)
    st.slot = nil
end

-- A step of the worm's trail: it is now at (gx, gy, gz) on a surface of unit normal (nx, ny, nz), and was at (st.lx, st.ly, st.lz)
-- the step before. The piece it is on (mode 3 drips, 4 smear) is lengthened along its line, or a new one started from the last point
-- when the worm turned, went back, outgrew the piece, changed from drips to a smear, or the piece was recycled.
local function extend(st, mode, gx, gy, gz, nx, ny, nz, frac, L)
    local maxLen = PTC.MAX_LEN[mode - 2]
    for _ = 1, 2 do
        if st.slot and (st.mode ~= mode or not DECALS.trailAlive(st.slot, st.gen)) then st.slot = nil end
        if not st.slot then
            local sx, sy, sz = st.lx, st.ly, st.lz
            if not sx then return end
            local vx, vy, vz = gx - sx, gy - sy, gz - sz
            local vl = sqrt(vx * vx + vy * vy + vz * vz)
            if vl < 1 or vl > PTC.GAP_MAX then return end
            local hw, thick
            if mode == 3 then
                local sev = min(1, (PTC.DRIP_FRAC - frac) / (PTC.DRIP_FRAC - PTC.SMEAR_FRAC))
                hw = rnd(0.9, 1.5) * L.width
                thick = floor((0.5 + 6.5 * sev) * L.dens + 0.5)
            else
                local sev = min(1, 1 - frac / PTC.SMEAR_FRAC)
                hw = (1.5 + 1.3 * sev) * L.width * rnd(0.9, 1.15)
                thick = 3 + floor(4 * sev + 0.5)
            end
            local slot, gen = DECALS.trailNew(mode, sx, sy, sz, nx, ny, nz, hw, thick, L.cap)
            if not slot then return end
            st.slot, st.gen, st.mode, st.len = slot, gen, mode, 0
            st.sx, st.sy, st.sz = sx, sy, sz
            st.dx, st.dy, st.dz = vx / vl, vy / vl, vz / vl
        end
        local vx, vy, vz = gx - st.sx, gy - st.sy, gz - st.sz
        local vl2 = vx * vx + vy * vy + vz * vz
        local t = vx * st.dx + vy * st.dy + vz * st.dz
        if st.len < PTC.FIT_LEN and vl2 > 1 then
            -- A young piece is still being aimed: its line is the chord to the worm while that stays within about 25 degrees
            -- of it, so that a little jitter in the first steps does not tilt a piece of 50 units off the path.
            local vl = sqrt(vl2)
            local nx, ny, nz = vx / vl, vy / vl, vz / vl
            if nx * st.dx + ny * st.dy + nz * st.dz > 0.9 then
                st.dx, st.dy, st.dz = nx, ny, nz
                t = vl
            end
        end
        local lat2 = vl2 - t * t
        if t >= st.len - 0.5 and lat2 <= PTC.LAT_TOL * PTC.LAT_TOL and t <= maxLen then
            if t > st.len then st.len = t end
            DECALS.trailSet(st.slot, st.gen, st.sx, st.sy, st.sz, st.dx, st.dy, st.dz, st.len)
            st.flushed = false
            return
        end
        closePiece(st)
    end
end

-- Runs for every worm the file tracks (trackWorms), after its state was updated.
function PT.track(s, dt)
    if not active() then return end
    local st = s.trl
    if not st then
        st = {}
        s.trl = st
    end
    if s.dead or not s.alive then
        closePiece(st)
        st.lx = nil
        return
    end
    local L = level()
    local vx, vy, vz = s.vx, s.vy, s.vz
    local hs2 = vx * vx + vz * vz
    if s.dying then
        -- Its health is gone and the game is about to blow it up: the blood spreads under it while it waits.
        closePiece(st)
        st.lx = nil
        if not st.dying then
            st.dying = true
            startPool(st, s.px, s.py + FEET_Y, s.pz, 2.5, rnd(PTC.DYING_POOL[1], PTC.DYING_POOL[2]) * L.pool, PTC.DYING_SECS, true)
        end
        return
    end
    st.dying = nil
    local frac = s.frac
    -- Hurt and lying still: a pool, once per place.
    if frac < PTC.POOL_FRAC and hs2 + vy * vy < PTC.STILL_SPEED * PTC.STILL_SPEED then
        st.still = st.still or now
        if now - st.still >= PTC.STILL_SECS then
            local g = st.grow
            if not (g and (g.x - s.px) * (g.x - s.px) + (g.z - s.pz) * (g.z - s.pz) < PTC.POOL_SAME * PTC.POOL_SAME) then
                startPool(st, s.px, s.py + FEET_Y, s.pz, 2.5, (6 + 8 * (1 - frac / PTC.POOL_FRAC)) * L.pool, PTC.GROW_SECS, true)
            end
        end
    else
        st.still = nil
    end
    -- A trail while it walks or crawls.
    if frac >= PTC.DRIP_FRAC then
        closePiece(st)
        st.lx = nil
        return
    end
    if not DECALS.rayOK then
        -- Without landRay the ground under the worm is taken to be its own height, which is only so while it walks: once it has
        -- left the ground (a fast rise or fall) nothing is laid until it has been calm for a moment (the apex of a jump is slow too).
        if abs(vy) > PTC.CALM_VY then
            st.air, st.calm = true, 0
        elseif st.air then
            st.calm = st.calm + dt
            if st.calm >= PTC.CALM_SECS then st.air = nil end
        end
        if st.air then
            closePiece(st)
            st.lx = nil
            return
        end
    else
        st.air = nil
    end
    if hs2 > PTC.MOVE_MIN * PTC.MOVE_MIN and hs2 < PTC.MOVE_MAX * PTC.MOVE_MAX and abs(vy) < PTC.RISE_MAX then
        local cx, cz = st.cx, st.cz
        if not cx or (s.px - cx) * (s.px - cx) + (s.pz - cz) * (s.pz - cz) >= PTC.STEP * PTC.STEP then
            local gy, nx, ny, nz = groundAt(s.px, s.py + FEET_Y, s.pz, 10, 12)
            if gy == false then return end
            st.cx, st.cz = s.px, s.pz
            if gy == nil then
                closePiece(st)
                st.lx = nil
            else
                extend(st, frac < PTC.SMEAR_FRAC and 4 or 3, s.px, gy, s.pz, nx, ny, nz, frac, L)
                st.lx, st.ly, st.lz = s.px, gy, s.pz
            end
        end
    elseif st.slot and not st.flushed then
        flush(st)
    end
end

-- A worm's death burst has just gone off: its grave gets a pool, smears and spatter a moment later (see PT.tick).
function PT.death(s)
    if not active() then return end
    local st = s.trl
    if st then closePiece(st) end
    if #graves >= PTC.GRAVE_MAX then table.remove(graves, 1) end
    graves[#graves + 1] = { x = s.px, y = s.py + FEET_Y, z = s.pz, at = now + PTC.GRAVE_DELAY, stage = 0, k = 0 }
end

-- Once a frame: the pools spread, the graves get their gore.
function PT.tick(dt)
    local i = 1
    while i <= #grow do
        local g = grow[i]
        local t = min(1, (now - g.t0) / g.secs)
        local r = g.r0 + (g.r1 - g.r0) * (1 - (1 - t) * (1 - t))
        g.cur = r
        if DECALS.poolGrow(g.slot, g.key, r, g.fresh and t < 1) and t < 1 then
            i = i + 1
        else
            g.done = true
            table.remove(grow, i)
        end
    end
    i = 1
    while i <= #graves do
        local G = graves[i]
        local drop = false
        if now >= G.at then
            local L = level()
            if G.stage == 0 then
                -- The pool the stone sits in and the smears that run out of it. The ground is looked for from well above (the
                -- explosion dug a crater under it) to well below.
                local gy, nx, ny, nz = groundAt(G.x, G.y, G.z, 40, 120)
                if gy == nil then
                    drop = true
                elseif gy ~= false then
                    G.stage, G.gy, G.Rp = 1, gy, PTC.GRAVE_POOL * L.pool
                    local slot = requestPool(G.x, gy, G.z, 4, nx, ny, nz)
                    if slot then addGrower(slot, 3.6, G.Rp, PTC.GRAVE_SECS, true) end
                    local tx, ty, tz, bx, by, bz = tframe(nx, ny, nz)
                    local a0, n = rnd(0, 2 * pi), L.smears
                    for k = 0, n - 1 do
                        local a = a0 + k * 2 * pi / n + rnd(-0.35, 0.35)
                        local ca, sa = cos(a), sin(a)
                        local dx, dy, dz = tx * ca + bx * sa, ty * ca + by * sa, tz * ca + bz * sa
                        local d0 = G.Rp * rnd(0.25, 0.5)
                        local sx, sy, sz = G.x + dx * d0, gy + dy * d0, G.z + dz * d0
                        local sl, gen = DECALS.trailNew(4, sx, sy, sz, nx, ny, nz, rnd(1.8, 3.2) * L.width, random(5, 7), L.cap + n, 4, PTC.GRAVE_HOLD)
                        if sl then DECALS.trailSet(sl, gen, sx, sy, sz, dx, dy, dz, min(PTC.MAX_LEN[2], G.Rp * rnd(0.8, 1.4)), true) end
                    end
                end
            else
                -- Spatter round it, a few specks a frame (a new splat is limited per frame anyway).
                local n = 0
                while G.k < L.splats and n < 3 do
                    G.k, n = G.k + 1, n + 1
                    local a = rnd(0, 2 * pi)
                    local d = G.Rp * rnd(0.7, 1.9) + 4
                    local px, pz = G.x + cos(a) * d, G.z + sin(a) * d
                    local gy, nx, ny, nz = groundAt(px, G.gy, pz, 25, 45)
                    if gy then
                        local sp = rnd(40, 120)
                        DECALS.splat(px, gy, pz, nx, ny, nz, cos(a) * sp, rnd(-260, -120), sin(a) * sp, rnd(1.0, 2.0) * L.width)
                    end
                end
                if G.k >= L.splats then drop = true end
            end
        end
        if drop then table.remove(graves, i) else i = i + 1 end
    end
end

-- The Preview menu: a trail of drips and a smear coming up to the worm, and a pool spreading under it.
function PT.preview(s)
    if not active() then return end
    local L = level()
    local fx, fz = facing(s)
    local gy, nx, ny, nz = groundAt(s.px, s.py + FEET_Y, s.pz, 10, 12)
    if not gy then gy, nx, ny, nz = s.py + FEET_Y, 0, 1, 0 end
    local d = fx * nx + fz * nz
    local dx, dy, dz = fx - nx * d, -ny * d, fz - nz * d
    local dl = sqrt(dx * dx + dy * dy + dz * dz)
    if dl < 1e-3 then return end
    dx, dy, dz = dx / dl, dy / dl, dz / dl
    local function piece(mode, a0, a1, hw, thick)
        local sx, sy, sz = s.px - dx * a0, gy - dy * a0, s.pz - dz * a0
        local slot, gen = DECALS.trailNew(mode, sx, sy, sz, nx, ny, nz, hw, thick, L.cap + 2, nil, 12)
        if slot then DECALS.trailSet(slot, gen, sx, sy, sz, dx, dy, dz, a0 - a1, true) end
    end
    piece(3, 96, 56, 1.0 * L.width, 6)
    piece(4, 56, 6, 2.2 * L.width, 6)
    local st = s.trl
    if not st then
        st = {}
        s.trl = st
    end
    startPool(st, s.px, gy, s.pz, 2.5, 12 * L.pool, 7, true)
end

-- A new match, or the setting turned off: nothing is waiting any more.
function PT.reset()
    grow, graves = {}, {}
end
end

-- A worm's death: the big burst, a pool and the lens, once per death (s.dead), when the body blows up. A worm whose health
-- reaches zero is only dying (s.dying): the game counts the damage down and blows it up seconds later, and a burst at the
-- moment the health ran out was lost in the smoke of the hit and the bleeding already there, with nothing at the death
-- itself. The burst comes with whichever is first: an explosion at the dying worm (the Explosion handler sets s.dieNow),
-- its state flipping to dead (which for a worm killed that way happens once the body is gone), the worm disappearing from
-- the list, or BUDGET.DYING_SECS. A worm that dies without its health running out first (drowned, say) bursts at the flip
-- or the disappearance as before. All but the disappearance come in trackWorms, that one at its end. A dead worm (its
-- grave, while the game still lists it) gets no more skin, guts, vomit or place in the stains pass's worm list.
local function deathBurst(s)
    s.dead = true
    s.credited = 0
    local dx, dy, dz = hitDirection(s)
    burst(s, DEATH_DAMAGE, dx, dy, dz, true)
    PT.death(s)
end

-- == Arterial spurts ============================================================================================
-- A worm below K.START of its health (stronger the lower it goes) spurts blood from its deepest open wounds (VIS.woundSites, the
-- places skin.frag draws them) in time with a heartbeat, K.HZ beats a second (faster the lower it is, a little irregular, and
-- often a weaker second beat after the first). Each beat is a pulse of K.LEN seconds: a pressurised arc of droplets (a narrow
-- stream of the fast ones that carries furthest, and a wider spray of slow ones that is dense at the wound) and a puff of fine
-- mist, with a weak dribble between the pulses. The droplets are ordinary particles, so they land through the usual terrain
-- collision and leave splats. Up to one, two or three wounds spurt at once (Light, Heavy, Absurd; the second and third only
-- when the worm is low enough), each pulse tilted a little differently from the wound's normal. The jet is worked out again at
-- every frame from the worm's wounds, so it follows the worm as it moves and turns. Nothing spurts while the worm is thrown or
-- falling (its facing no longer says where its wounds are), and a pulse resumes, stronger, K.RESUME seconds after it lands.
-- A new hit (SP.hit) brings an extra pulse soon and stronger ones for a few seconds. A dying worm (health 0, waiting for the
-- game to blow it up) goes on for K.DYING_SECS with weakening, slowing pulses. All of it draws on the frame's spawn budget
-- only after the bursts (it runs after the worms were tracked), up to lv.cap droplets a frame shared between the worms, and
-- never fills the pool past K.POOL_SHARE of the amount's maximum, so a burst or a death always finds room.
-- Public: SP.tick(dt) once a frame, SP.hit(s, damage) from burst(), SP.preview(s). State is s.sp, made on first use.
do
local function build()
local K = {
    START = 0.34, STOP = 0.38, FULL = 0.04,        -- health fractions: spurting starts below START, stops above STOP, is at its strongest from FULL down
    HZ = { 1.1, 1.6 }, IRREG = { 0.88, 1.15 },     -- beats a second at START and at FULL, and the random factor on each interval
    LEN = { 0.15, 0.24 },                          -- seconds a pulse lasts
    ATTACK = 0.12, ENV_AREA = 0.46,                -- a pulse's pressure rises over this share of it, then falls; the area under it (of its length)
    DUB = 0.5, DUB_GAP = 0.2, DUB_STR = 0.55,      -- the chance of a second, weaker beat this long after the first
    CALM_SPEED = 90, CALM_VY = 80,                 -- a worm faster than this (units per second) is thrown or falling
    RESUME = 0.35, LAND_GAIN = 1.3,                -- seconds after landing before it spurts again, and how much stronger the first pulse is
    DYING_SECS = 6, DYING_MIN = 0.08,
    HIT_SECS = { 1.2, 3.5 }, HIT_PER_DAMAGE = 0.04, HIT_FULL = 50, HIT_GAIN = 0.6,   -- a new hit: strong pulses for this long, up to this much stronger
    TILT = 0.3, UP = 0.3, MIN_DIR_Y = -0.15,       -- sideways tilt per pulse, the lift added to the wound's normal, the lowest a jet points
    STREAM = 0.55, CONE_STREAM = 0.05, CONE_SPRAY = 0.28,
    JET_SEV = { 0, 0.3, 0.55 }, JET_GAIN = { 1, 0.75, 0.6 },
    MIN_OPEN = 0.15,                               -- a wound less open than this does not spurt
    OUT = 1.2, INHERIT = 0.5,                      -- the jet starts this far off the skin and takes this share of the worm's velocity
    POOL_SHARE = 0.6, RESERVE = 40,                -- the pool share spurts may fill, and the frame's spawns left to the bursts
    PREVIEW_SECS = 6, PREVIEW_SEV = 0.7,
}
local LV = {
    light  = { jets = 1, drops = 10, mist = 1, cap = 14, drib = 2, speed = 125 },
    heavy  = { jets = 2, drops = 22, mist = 2, cap = 30, drib = 4, speed = 150 },
    absurd = { jets = 3, drops = 40, mist = 3, cap = 52, drib = 7, speed = 175 },
}
local AS, ASLOT, ASEV = {}, {}, {}      -- the worms spurting this frame

local function state(s)
    local sp = s.sp
    if not sp then
        sp = { nextAt = 0, pStart = 0, pEnd = 0, len = 0.2, str = 1, nj = 0, key = { 0, 0, 0 }, t1 = { 0, 0, 0 }, t2 = { 0, 0, 0 },
               acc = { 0, 0, 0 }, macc = { 0, 0, 0 }, dacc = 0, airAt = -100, wasAir = false, on = false, boostUntil = 0, boost = 1,
               forceUntil = 0, dubNext = false, beatEnd = 0, fade = 1, sites = {} }
        s.sp = sp
    end
    return sp
end

-- How hard the worm spurts, 0 (not at all) to 1.
local function assess(s, sp)
    if not s.alive or s.dead then return 0 end
    local sev, fade = 0, 1
    if s.dying then
        fade = 1 - (now - s.dying) / K.DYING_SECS
        if fade < K.DYING_MIN then return 0 end
        sev = 1
    else
        local frac = s.frac
        if frac < (sp.on and K.STOP or K.START) then
            sp.on = true
            sev = (K.START - frac) / (K.START - K.FULL)
            if sev < 0.05 then sev = 0.05 elseif sev > 1 then sev = 1 end
        else
            sp.on = false
        end
    end
    if sp.forceUntil > now and sev < K.PREVIEW_SEV then sev = K.PREVIEW_SEV end
    sp.fade = fade
    return sev
end

-- Starts a pulse: its strength and length, when the next beat is, and which wounds spurt (the deepest first) and how each tilts.
local function startPulse(sp, sev, lv, n, sites)
    local fade = sp.fade
    local boosted = now < sp.boostUntil
    local str = 0.6 + 0.4 * sev
    if fade < 1 then str = str * fade ^ 0.7 end
    if boosted then str = str * sp.boost end
    if sp.wasAir then
        str = str * K.LAND_GAIN
        sp.wasAir = false
    end
    if sp.dubNext then
        sp.dubNext = false
        str = str * K.DUB_STR
        sp.nextAt = sp.beatEnd
    else
        local hz = (K.HZ[1] + (K.HZ[2] - K.HZ[1]) * sev) * (0.5 + 0.5 * fade) * (boosted and 1.12 or 1)
        local period = rnd(K.IRREG[1], K.IRREG[2]) / hz
        if random() < K.DUB and period > 0.5 then
            sp.dubNext, sp.beatEnd, sp.nextAt = true, now + period, now + K.DUB_GAP
        else
            sp.nextAt = now + period
        end
    end
    if str > 1.6 then str = 1.6 end
    local len = rnd(K.LEN[1], K.LEN[2]) * (0.85 + 0.3 * min(1, str)) * (boosted and 1.2 or 1)
    sp.pStart, sp.pEnd, sp.len, sp.str = now, now + len, len, str
    local key, nj = sp.key, 0
    for j = 1, lv.jets do
        if sev < K.JET_SEV[j] then break end
        local best, bo, bk = 0, K.MIN_OPEN, 0
        for i = 1, n do
            local e = sites[i]
            local k = e.gut and 99 or i - 1
            if e.open > bo and (j < 2 or k ~= key[1]) and (j < 3 or k ~= key[2]) then best, bo, bk = i, e.open, k end
        end
        if best == 0 then break end
        nj = j
        key[j] = bk
        sp.t1[j], sp.t2[j] = rnd(-1, 1) * K.TILT, rnd(-1, 1) * K.TILT
    end
    sp.nj = nj
end

-- One worm's frame: the beat, then the droplets, mist and dribble this frame owes. Returns how many particles it spawned (at most budget).
local function emitWorm(s, slot, sp, sev, lv, dt, budget)
    local vx, vy, vz = s.vx, s.vy, s.vz
    if s.evFrame == frameId then vx, vy, vz = s.evx, s.evy, s.evz end
    if vx * vx + vz * vz > K.CALM_SPEED * K.CALM_SPEED or abs(vy) > K.CALM_VY then sp.airAt = now end
    if now - sp.airAt <= K.RESUME then
        sp.wasAir = true
        sp.pEnd = 0
        return 0
    end
    local n, sites = VIS.woundSites(slot, sp.sites)
    if n == 0 then return 0 end
    if now >= sp.nextAt and sp.pEnd <= now then startPulse(sp, sev, lv, n, sites) end
    local nj = sp.nj
    if nj == 0 then return 0 end
    local env = 0
    if sp.pEnd > now then
        local p = (now + dt * 0.5 - sp.pStart) / sp.len
        if p < 0 then p = 0 elseif p > 1 then p = 1 end
        env = p < K.ATTACK and p / K.ATTACK or ((1 - p) / (1 - K.ATTACK)) ^ 1.2
    end
    local far = 0
    if CAM.ok then
        local ex, ey, ez = s.px - CAM.px, s.py + CENTRE_Y - CAM.py, s.pz - CAM.pz
        far = min(1, max(0, (sqrt(ex * ex + ey * ey + ez * ez) - FAR_START) / FAR_SPAN))
    end
    local sizeMul = 1 + 0.45 * far
    local boosted = now < sp.boostUntil
    local c, m = palette.droplet, palette.mist
    local used = 0
    local vmax = lv.speed * (0.7 + 0.3 * min(1, sp.str)) * (0.55 + 0.45 * env) * (boosted and 1.1 or 1)
    local wvx, wvy, wvz = vx * K.INHERIT, vy * K.INHERIT, vz * K.INHERIT
    local base = lv.drops / (sp.len * K.ENV_AREA) * env * sp.str * (1 - 0.4 * far)    -- fewer, bigger drops far away
    local mbase = lv.mist / (sp.len * K.ENV_AREA) * env * sp.str
    local key = sp.key
    for j = 1, nj do
        local e
        for i = 1, n do
            local ei = sites[i]
            if (ei.gut and 99 or i - 1) == key[j] then
                e = ei
                break
            end
        end
        if e then
            local nx, ny, nz = e.nx, e.ny, e.nz
            -- Two tangents of the wound, to tilt the jet off its normal, and a lift so the stream arcs up and out.
            local tl = sqrt(nx * nx + nz * nz)
            local t1x, t1z = 1, 0
            if tl > 1e-3 then t1x, t1z = -nz / tl, nx / tl end
            local t2x, t2y, t2z = ny * t1z, nz * t1x - nx * t1z, -ny * t1x
            local a, b = sp.t1[j], sp.t2[j]
            local dx, dy, dz = nx + t1x * a + t2x * b, ny + K.UP + t2y * b, nz + t1z * a + t2z * b
            if dy < K.MIN_DIR_Y then dy = K.MIN_DIR_Y end
            local dl = sqrt(dx * dx + dy * dy + dz * dz)
            dx, dy, dz = dx / dl, dy / dl, dz / dl
            local ox, oy, oz = e.x + nx * K.OUT, e.y + ny * K.OUT, e.z + nz * K.OUT
            local gain = K.JET_GAIN[j]
            local acc = sp.acc[j] + base * gain * dt
            local cnt = floor(acc)
            acc = acc - cnt
            if cnt > budget - used then
                cnt = budget - used
                acc = 0
            end
            sp.acc[j] = acc
            for _ = 1, cnt do
                local stream = random() < K.STREAM
                local cone = stream and K.CONE_STREAM or K.CONE_SPRAY
                local ex, ey, ez = dx + rnd(-cone, cone), dy + rnd(-cone, cone), dz + rnd(-cone, cone)
                local k = (stream and vmax * rnd(0.82, 1.0) or vmax * rnd(0.3, 0.8)) / sqrt(ex * ex + ey * ey + ez * ez)
                local jvx, jvy, jvz = ex * k + wvx, ey * k + wvy, ez * k + wvz
                local lag, shade = random() * dt, rnd(0.8, 1.2)
                spawn(DROPLET, ox + jvx * lag + rnd(-0.4, 0.4), oy + jvy * lag + rnd(-0.4, 0.4), oz + jvz * lag + rnd(-0.4, 0.4),
                      jvx, jvy, jvz, (stream and rnd(1.4, 2.4) or rnd(0.8, 1.5)) * sizeMul, stream and rnd(0.55, 1.5) or rnd(0.45, 0.9),
                      min(1, c[1] * shade), min(1, c[2] * shade), min(1, c[3] * shade), DROPLET_ALPHA)
            end
            used = used + cnt
            -- Fine mist at the wound while the pressure is up.
            local macc = sp.macc[j] + mbase * gain * dt
            local mc = floor(macc)
            macc = macc - mc
            if mc > 2 then mc = 2 end
            if mc > budget - used then mc = budget - used end
            sp.macc[j] = macc
            for _ = 1, mc do
                local shade, v = rnd(0.8, 1.2), rnd(20, 50)
                spawn(MIST, ox + nx * 0.5 + rnd(-0.8, 0.8), oy + ny * 0.5 + rnd(-0.8, 0.8), oz + nz * 0.5 + rnd(-0.8, 0.8),
                      dx * v + rnd(-8, 8) + wvx, dy * v + rnd(-8, 8) + wvy, dz * v + rnd(-8, 8) + wvz,
                      rnd(5, 9) * (1 + 0.5 * far), rnd(0.3, 0.5), min(1, m[1] * shade), min(1, m[2] * shade), min(1, m[3] * shade),
                      MIST_ALPHA * 0.9)
            end
            used = used + mc
            -- The dribble from the deepest wound, between and under the pulses.
            if j == 1 then
                local dacc = sp.dacc + lv.drib * (0.35 + 0.65 * sev) * sp.fade * dt
                local dc = floor(dacc)
                dacc = dacc - dc
                if dc > 2 then dc = 2 end
                if dc > budget - used then dc = budget - used end
                sp.dacc = dacc
                for _ = 1, dc do
                    local shade, v = rnd(0.7, 1.1), rnd(12, 38)
                    spawn(DROPLET, ox + rnd(-0.5, 0.5), oy + rnd(-0.5, 0.5), oz + rnd(-0.5, 0.5),
                          nx * v + wvx, ny * v + rnd(0, 12) + wvy, nz * v + wvz, rnd(0.9, 1.6) * sizeMul, rnd(0.5, 1.0),
                          min(1, c[1] * shade), min(1, c[2] * shade), min(1, c[3] * shade), DROPLET_ALPHA)
                end
                used = used + dc
            end
        end
    end
    return used
end

function SP.tick(dt)
    if not preset then return end
    local lv = preset == AMOUNT.absurd and LV.absurd or preset == AMOUNT.light and LV.light or LV.heavy
    local na = 0
    for slot, s in pairs(slots) do
        if s.seen == frameId and s.alive and not s.dead and (s.frac < K.STOP or s.dying or (s.sp and s.sp.forceUntil > now)) then
            local sp = state(s)
            local sev = assess(s, sp)
            if sev > 0 then
                na = na + 1
                AS[na], ASLOT[na], ASEV[na] = s, slot, sev
            end
        end
    end
    if na == 0 then return end
    local left = min(lv.cap, floor(min(preset.max, POOL_MAX) * K.POOL_SHARE) - nP, BUDGET.SPAWN - K.RESERVE - BUDGET.spawned)
    for i = 1, na do
        local s = AS[i]
        local share = left > 0 and math.ceil(left / (na - i + 1)) or 0
        local used = emitWorm(s, ASLOT[i], s.sp, ASEV[i], lv, dt, share)
        left = left - used
        AS[i] = false
    end
end

-- A hit has been shown on the worm: an extra pulse soon, and stronger ones for a while (more for a bigger hit).
function SP.hit(s, damage)
    local sp = state(s)
    sp.boostUntil = now + min(K.HIT_SECS[2], K.HIT_SECS[1] + damage * K.HIT_PER_DAMAGE)
    sp.boost = 1 + min(1, damage / K.HIT_FULL) * K.HIT_GAIN
    if sp.nextAt > now + 0.12 then
        sp.nextAt = now + 0.12
        sp.dubNext = false
    end
end

-- The preview worm spurts for a few seconds whatever its health.
function SP.preview(s)
    local sp = state(s)
    sp.forceUntil = now + K.PREVIEW_SECS
    sp.airAt = -100
    sp.nextAt = now + 0.1
end
end
build()
end

local function trackWorms(worms, dt)
    for i = 1, #worms do
        local w = worms[i]
        local slot = type(w) == "table" and w.slot
        local x, y, z
        if slot then x, y, z = vec(w.pos) end
        if x then
            local health = tonumber(w.health) or 0
            local alive = w.alive == true
            local s = slots[slot]
            -- The facing from the game, wrapped into -pi..pi; nil on a Melange that does not report it.
            local yaw = tonumber(w.yaw)
            if yaw and yaw - yaw ~= 0 then yaw = nil end    -- NaN or infinite
            if not s then
                s = newSlot(x, y, z, health, alive)
                slots[slot] = s
                if yaw then s.heading = (yaw + pi) % (2 * pi) - pi end
                updateWound(s, dt)
                updateEyes(s, dt)
                updateGut(s, dt)
            else
                s.seen = frameId
                s.gone = nil
                local ox, oy, oz = s.px, s.py, s.pz
                VIS.noteEngineVel(s, w.vel)
                updateMotion(s, x, y, z)
                MEL.track(s, slot, w)
                if s.alive and not alive then
                    if not s.dead then
                        -- A dead worm may be reported somewhere else (or nowhere): burst where it was last seen alive.
                        local jx, jy, jz = s.px - ox, s.py - oy, s.pz - oz
                        if jx * jx + jy * jy + jz * jz > 14400 then s.px, s.py, s.pz = ox, oy, oz end
                        deathBurst(s)
                    end
                elseif alive and not s.alive then
                    resetSlot(s)
                elseif alive then
                    if health > s.health then
                        resetSlot(s)
                    elseif health < s.health then
                        -- (Down to zero it still bleeds what the hit did not show, and starts dying.)
                        settleHealth(s, s.health - health)
                        if health <= 0 and not s.dead and not s.dying then s.dying = now end
                    end
                    if s.dying and not s.dead and (s.dieNow or now - s.dying > BUDGET.DYING_SECS) then deathBurst(s) end
                end
                s.health, s.alive = health, alive
                if not alive then s.gore = 0 end
                if yaw then
                    s.heading = (yaw + pi) % (2 * pi) - pi
                else
                    steerHeading(s, dt)
                end
                updateWound(s, dt)
                updateEyes(s, dt)
                updateGut(s, dt)
                updateVomit(s, dt)
                emitBleed(s, dt)
                PT.track(s, dt)
                settleStain(s)
            end
        end
    end

    -- An explosion is only shown once the game has said a worm was damaged at that moment; one that hurt nobody is
    -- dropped after a short wait. The two messages are matched by when they arrived, not by when this frame runs, so
    -- a long frame cannot separate them. Each worm in reach gets a burst away from the blast, sized by an estimate
    -- that falls off with distance, and that estimate is credited against the health the game takes off later.
    local kept = 0
    for e = 1, nExp do
        if abs(EX.at[e] - hurtAt) <= DAMAGED_WINDOW then
            local ex, ey, ez, damage, radius = EX.x[e], EX.y[e], EX.z[e], EX.dmg[e], EX.radius[e]
            -- Taken before the worms are looked at: if this frame is stopped half way, the entry must not match again.
            EX.at[e] = -1000
            for _, s in pairs(slots) do
                -- (A dying worm that this explosion blows up gets its death burst instead.)
                if s.seen == frameId and s.alive and not s.dead and not s.dieNow then
                    local dx, dy, dz = s.px - ex, s.py + CENTRE_Y - ey, s.pz - ez
                    local d = sqrt(dx * dx + dy * dy + dz * dz)
                    if d <= radius + BODY_MARGIN then
                        local est = max(1, damage * (1 - min(max(0, d - BODY_MARGIN) / radius, 1)))
                        if d < 1e-3 then dx, dy, dz, d = 0, 1, 0, 1 end
                        if DEBUG then wum.log.debug("explosion hit", est, d) end
                        credit(s, est)
                        local esig = MEL.explSig()
                        if esig then MEL.explContext(s) end
                        burst(s, est, dx / d, dy / d + 0.35, dz / d, false, esig)
                        hurtOpen = false
                    end
                end
            end
        elseif now - EX.at[e] < DAMAGED_WINDOW then
            kept = kept + 1
            EX.x[kept], EX.y[kept], EX.z[kept] = EX.x[e], EX.y[e], EX.z[e]
            EX.dmg[kept], EX.radius[kept], EX.at[kept] = EX.dmg[e], EX.radius[e], EX.at[e]
        end
    end
    nExp = kept

    -- A worm was damaged and no explosion came with it: a fall, a punch, a bullet. The worm that was just knocked
    -- or stopped hardest is taken to be the one, and bleeds along that knock.
    if hurtOpen and now - hurtAt > DAMAGED_WINDOW then
        hurtOpen = false
        local best, bestSize
        local handled = MEL.resolveHit()    -- a weapon's signature or a fall; otherwise the blunt hit below
        for _, s in pairs(slots) do
            if not handled and s.seen == frameId and s.alive and now - s.iat <= IMPULSE_WINDOW then
                local size = s.ix * s.ix + s.iy * s.iy + s.iz * s.iz
                if not best or size > bestSize then best, bestSize = s, size end
            end
        end
        if best then
            local dx, dy, dz = hitDirection(best)
            if DEBUG then wum.log.debug("blunt hit", sqrt(bestSize)) end
            credit(best, BLUNT_DAMAGE)
            burst(best, BLUNT_DAMAGE, dx, dy, dz)
        end
    end

    for slot, s in pairs(slots) do
        if s.seen ~= frameId then
            if s.alive and not s.dead and #worms > 0 and preset then
                -- A worm that was alive and is no longer in the list has died without anyone seeing its state change, unless
                -- it is only missing for a moment: it is given GONE_SECS to come back.
                s.gone = s.gone or now
                if now - s.gone >= BUDGET.GONE_SECS then
                    deathBurst(s)
                    slots[slot] = nil
                end
            else
                slots[slot] = nil
            end
        end
    end
end

-- ---------------------------------------------------------------- blood and wounds on worms
-- Per worm slot (index slot + 1): what was last sent as the blood amount, wound level, heading, eye level and gut level,
-- and the frame the slot was last driven in. One random seed per match gives every worm its own wound places in the shader.
local skSentGore, skSentWound, skSentHead, skFrame = {}, {}, {}, {}
local skSentEyes, skSentGut = {}, {}
for i = 1, SKIN_SLOTS do
    skSentGore[i], skSentWound[i], skSentHead[i], skFrame[i] = 0, 0, 0, 0
    skSentEyes[i], skSentGut[i] = 0, 0
end
local skinCount = 0
local matchSeed = random(0, 1000)

local function sendSeed()
    VIS.seed = matchSeed
    sendParam(SKIN, "seed", matchSeed)
end

local function clearSkin()
    for i = 1, SKIN_SLOTS do
        sendParam(SKIN, WORM_B[i], 0, 0, 0)
        sendParam(SKIN, WORM_C[i], 0, 0, 0)
        skSentGore[i], skSentWound[i], skSentHead[i], skSentEyes[i], skSentGut[i] = 0, 0, 0, 0, 0
    end
    skinCount = 0
    VIS.zeroScorch()
    sendEnabled(SKIN, false)
end

-- Sends the body centre and, when they changed enough, the blood amount, wound level and heading of one worm, and its
-- eye level, gut level and the side the gut is on.
local function driveSkin(slot, s)
    local i = slot + 1
    skFrame[i] = frameId
    skinCount = skinCount + 1
    sendParam(SKIN, WORM_A[i], s.px + s.vx * SKIN_LEAD, s.py + CENTRE_Y + s.vy * SKIN_LEAD, s.pz + s.vz * SKIN_LEAD)
    local wound = s.wound
    -- The blood amount carries the side of the last hit: 2 * its bin (1..32) added to the amount, which the shader splits again.
    local gore = s.gore > 0 and s.gore + 2 * s.hitQ or 0
    if abs(gore - skSentGore[i]) > GORE_RESEND or abs(wound - skSentWound[i]) > WOUND_RESEND
        or (wound == 0) ~= (skSentWound[i] == 0) or abs(s.heading - skSentHead[i]) > HEADING_RESEND then
        skSentGore[i], skSentWound[i], skSentHead[i] = gore, wound, s.heading
        sendParam(SKIN, WORM_B[i], gore, wound, s.heading)
    end
    local eye, gut = s.eye, s.gut
    if abs(eye - skSentEyes[i]) > EYE.RESEND or abs(gut - skSentGut[i]) > GUT.RESEND
        or (eye == 0) ~= (skSentEyes[i] == 0) or (gut == 0) ~= (skSentGut[i] == 0) then
        skSentEyes[i], skSentGut[i] = eye, gut
        sendParam(SKIN, WORM_C[i], eye, gut, s.gutAz)
    end
end

-- Runs once per frame after the worms were tracked: drives every living worm that has blood, a wound, black eyes or a
-- gut, zeroes the slots of the rest and keeps the effect on only while there is something to paint.
local function updateSkin()
    skinCount = 0
    if hasPostfx and preset and cfg.skin then
        for slot, s in pairs(slots) do
            if s.seen == frameId and s.alive and not s.dead
                and (s.gore > 0 or s.wound > 0 or s.eye > 0 or s.gut > 0 or VIS.scorchLevel(slot + 1) > 0)
                and slot >= 0 and slot < SKIN_SLOTS then
                driveSkin(slot, s)
            end
        end
        VIS.sendScorch()
    end
    for i = 1, SKIN_SLOTS do
        if skFrame[i] ~= frameId and (skSentGore[i] ~= 0 or skSentWound[i] ~= 0 or skSentEyes[i] ~= 0 or skSentGut[i] ~= 0) then
            skSentGore[i], skSentWound[i], skSentHead[i], skSentEyes[i], skSentGut[i] = 0, 0, 0, 0, 0
            sendParam(SKIN, WORM_B[i], 0, 0, 0)
            sendParam(SKIN, WORM_C[i], 0, 0, 0)
        end
    end
    sendEnabled(SKIN, skinCount > 0 and preset ~= nil and cfg.skin ~= false)
end

local function clearParticles()
    nP, nL, nExp = 0, 0, 0
    LS.sync()
    BQ.n, BQ.head = 0, 1
    hurtOpen = false
    MEL.clear()
end

-- Everything back to nothing: the match ended or started, or the amount was turned off.
local function resetAll()
    DECALS.rayOK = DECALS.hasFn         -- landRay is asked again in every match: "unavailable" can be about one level only
    slots = {}
    clearParticles()
    clearStains()
    clearSkin()
    VIS.reset()
    GIBS.clear()
    PT.reset()
    -- A new match seed, so the wounds are not in the same places every match.
    matchSeed = random(0, 1000)
    sendSeed()
    live = false
end

-- ---------------------------------------------------------------- frame
local lastClock = nil

-- One step of the warm-up (see WARM): the effects the settings allow go on one at a time, GAP frames apart, for HOLD frames each,
-- once per session (a compiled effect stays compiled).
function WARM.step()
    if WARM.started == "done" or not hasPostfx then return end
    local f = WARM.frame + 1
    WARM.frame = f
    WARM.started = true
    local allowed = { ["bloodsand/stains"] = cfg.stains ~= false, ["bloodsand/skin"] = cfg.skin ~= false,
                      ["bloodsand/guts"] = cfg.guts ~= false, ["bloodsand/lens"] = cfg.lens ~= false }
    allowed["bloodsand/gibs"] = cfg.gibs ~= false
    local last = WARM.GAP * #WARM.ids + WARM.HOLD
    for k = 1, #WARM.ids do
        local id, t0 = WARM.ids[k], WARM.GAP * k
        if f == t0 and allowed[id] then
            WARM.on[id] = true
        elseif f == t0 + WARM.HOLD then
            WARM.on[id] = nil
        end
    end
    if f >= last then
        WARM.started = "done"
        WARM.on = {}
    end
end

local function onWorld()
    local t = os.clock()
    local dt = lastClock and min(0.05, max(0, t - lastClock)) or 0
    lastClock = t
    now = t

    if not preset or not wum.game.inMatch() then
        if live then resetAll() end
        return
    end
    live = true
    WARM.step()
    frameId = frameId + 1
    BUDGET.spawned, BUDGET.evicted = 0, 0
    DECALS.rayUsed = 0
    DECALS.now = t
    if not DECALS.rayOK and DECALS.hasFn and t >= DECALS.rayRetryAt then DECALS.rayOK = true end
    readCamera()
    MEL.beginFrame()
    drainBursts()
    local worms = wum.game.worms()
    VIS.beginGuts()
    if type(worms) == "table" then
        trackWorms(worms, dt)
    else
        nExp = 0
    end
    VIS.simGuts(dt)
    updateSkin()
    VIS.updateGuts()
    GIBS.tick(dt)
    MEL.tick(dt)
    SP.tick(dt)
    simulate(dt)
    PT.tick(dt)
    DECALS.update(dt, slots, frameId)
    drawGuts()
    ageSplats(dt)
    MEL.resendStep()
end

-- ---------------------------------------------------------------- settings
local function applySettings()
    local amount = wum.config.get("amount") or "heavy"
    local stains = wum.config.get("stains") ~= false
    local lens = wum.config.get("lens") ~= false
    local skin = wum.config.get("skin") ~= false
    -- Turning either off takes effect at the next frame: updateGut drops the chains and updateVomit ends the heaves.
    cfg.vomit = wum.config.get("vomit") ~= false
    cfg.guts = wum.config.get("guts") ~= false
    cfg.gibs = wum.config.get("gibs") ~= false
    local colour = wum.config.get("colour") or "red"

    if amount ~= cfg.amount then
        cfg.amount = amount
        preset = amount ~= "off" and (AMOUNT[amount] or AMOUNT.heavy) or nil
        if preset then
            nP = min(nP, preset.max)
        else
            slots = {}
            clearParticles()
            live = false
        end
    end
    if skin ~= cfg.skin then
        cfg.skin = skin
        if not skin then clearSkin() end
    end
    if stains ~= cfg.stains then
        cfg.stains = stains
        if not stains then clearStains() end
    end
    local pools = wum.config.get("pools") ~= false
    if pools ~= cfg.pools then
        cfg.pools = pools
        if not pools then PT.reset() end
    end
    if lens ~= cfg.lens then
        cfg.lens = lens
        if not lens then nL = 0 end
        LS.sync()
    end
    if colour ~= cfg.colour then
        cfg.colour = colour
        palette = COLOURS[colour] or COLOURS.red
        local c = palette.stain
        sendParam(STAINS, "blood", c[1], c[2], c[3])
        sendParam(SKIN, "blood", c[1], c[2], c[3])
        VIS.setBlood(c)
        LS.setBlood(palette.lens)
        GIBS.setBlood(c)
    end
    if not preset then
        clearStains()
        clearSkin()
        VIS.reset()
    end
    updateStainEnable()
    GIBS.apply(cfg.gibs)
    -- Outside a match nothing drives the skin effect, so settle a persisted enabled=1 here instead of waiting for a frame.
    if skinCount == 0 then sendEnabled(SKIN, false) end
end

-- ---------------------------------------------------------------- events and preview
if wum.events and wum.events.on then
    wum.events.on("Explosion", function(p)
        if not preset or type(p) ~= "table" then return end
        local x, y, z = vec(p.damageEpicentre)
        if not x then return end
        -- Whatever it hurt: the crater takes the decals in it, and a dying worm it goes off at is blowing up.
        DECALS.blast(x, y, z, tonumber(p.landDamageRadius))
        GIBS.blast(x, y, z, tonumber(p.landDamageRadius), tonumber(p.wormDamageRadius))
        local t, reach = os.clock(), BUDGET.DYING_REACH
        for _, s in pairs(slots) do
            if s.dying and not s.dead and t - s.dying >= BUDGET.DYING_MIN then
                local dx, dy, dz = s.px - x, s.py + CENTRE_Y - y, s.pz - z
                if dx * dx + dy * dy + dz * dz < reach * reach then s.dieNow = true end
            end
        end
        if nExp >= EXPLOSIONS_MAX then return end
        local damage, radius = tonumber(p.wormDamage), tonumber(p.wormDamageRadius)
        if not (damage and radius) or damage <= 0 or radius <= 0 then return end
        nExp = nExp + 1
        EX.x[nExp], EX.y[nExp], EX.z[nExp], EX.dmg[nExp], EX.radius[nExp], EX.at[nExp] = x, y, z, damage, radius, os.clock()
    end)
    wum.events.on("Worm.Damaged", function()
        if not preset then return end
        hurtAt, hurtOpen = os.clock(), true
        MEL.onDamaged(hurtAt)
    end)
    wum.events.on("Weapon.Fired", function()
        if not preset then return end
        MEL.onFired(os.clock())
    end)
    wum.events.on("melange.match.start", resetAll)
    wum.events.on("melange.match.end", resetAll)
end

local function preview()
    if not (preset and wum.game.inMatch()) then return end
    local worms = wum.game.worms()
    if type(worms) ~= "table" then return end
    local active = wum.game.activeWorm()
    local pick
    for i = 1, #worms do
        local w = worms[i]
        if type(w) == "table" and w.alive == true and w.slot and vec(w.pos) then
            if not pick or w.slot == active then pick = w end
            if w.slot == active then break end
        end
    end
    if not pick then return end
    now = os.clock()
    local s = slots[pick.slot]
    if not s then
        local x, y, z = vec(pick.pos)
        s = newSlot(x, y, z, tonumber(pick.health) or 0, true)
        slots[pick.slot] = s
    end
    -- Each press shows the next weapon's signature (MEL.preview); the last of the cycle is the ordinary burst.
    if not MEL.preview(s, pick.slot) then
        local dx, dy, dz = rnd(-0.6, 0.6), 1, rnd(-0.3, 0.3)
        burst(s, 40, dx, dy, dz)
    end
    -- Wounds too, so they can be seen: a level that decays back to what the worm's health gives.
    s.previewWound = PREVIEW_WOUND
    s.wound = max(s.wound, PREVIEW_WOUND)
    s.previewEyes, s.previewGut = 1, 1
    -- A scorch patch too, so it can be seen: it fades over a few seconds, so press Preview again to see it again.
    setScorch(pick.slot, 1)
    if cfg.vomit then startHeave(s) end
    GIBS.preview(s)
    PT.preview(s)
    SP.preview(s)
end

-- ---------------------------------------------------------------- start
-- Melange keeps a transient value across an effect reload unless the reload removes the param or changes its size, so
-- this is only insurance: everything live is sent again from time to time, zeros included for the slots that are not in
-- use, in case an effect was reloaded with a changed parameter list or a value was lost some other way.
local RESEND_STEPS = 17

-- One step of the insurance resend: steps 1-8 are four decal slots each, 9-12 four skin slots each, 13-16 one slot of the guts
-- effect each and 17 the colours and the rest. One step runs per frame (see startResend), so no frame pays for the lot.
local function resendStep()
    local k = MEL.rsStep
    if k == 0 then return end
    MEL.rsStep = k < RESEND_STEPS and k + 1 or 0
    if not hasPostfx then return end
    GIBS.resendStep(k)
    if k <= 8 then
        DECALS.resend((k - 1) * 4 + 1, k * 4)
    elseif k <= 12 then
        local first = (k - 9) * 4 + 1
        for i = first, first + 3 do
            SKIN.cache[WORM_A[i]], SKIN.cache[WORM_B[i]], SKIN.cache[WORM_C[i]] = nil, nil, nil
            if skFrame[i] == frameId and (skSentGore[i] > 0 or skSentWound[i] > 0 or skSentEyes[i] > 0 or skSentGut[i] > 0
                                          or VIS.scorchLevel(i) > 0) then
                -- The centre goes out at the next frame, which finds the cache empty; the amounts are forced here.
                skSentGore[i], skSentWound[i], skSentEyes[i], skSentGut[i] = -1, -1, -1, -1
            else
                sendParam(SKIN, WORM_A[i], 0, 0, 0)
                sendParam(SKIN, WORM_B[i], 0, 0, 0)
                sendParam(SKIN, WORM_C[i], 0, 0, 0)
            end
        end
    elseif k <= 16 then
        VIS.resendSlot(k - 12)
    else
        DECALS.resendMisc()
        SKIN.cache.blood, SKIN.cache.seed = nil, nil
        local c = palette.stain
        sendParam(STAINS, "blood", c[1], c[2], c[3])
        sendParam(SKIN, "blood", c[1], c[2], c[3])
        VIS.resendBlood()
        VIS.setBlood(c)
        sendSeed()
    end
end
MEL.resendStep = resendStep

-- Every RESEND_SECS: starts the steps. In a match they run one a frame (onWorld); outside one they all run now.
local function startResend()
    if not hasPostfx then return end
    MEL.rsStep = 1
    if not live then
        while MEL.rsStep ~= 0 do resendStep() end
    end
end

-- Every slot of both effects starts at zero, whatever Melange saved in an earlier session.
local function zeroAll()
    DECALS.zero()
    for i = 1, SKIN_SLOTS do
        sendParam(SKIN, WORM_A[i], 0, 0, 0)
        sendParam(SKIN, WORM_B[i], 0, 0, 0)
        sendParam(SKIN, WORM_C[i], 0, 0, 0)
    end
    VIS.zero()
    VIS.zeroScorch()
    GIBS.zero()
end

-- == Gibs ==
-- Meat chunks, bone shards and a few organs (a kidney, a liver lobe, a heart, an eye) thrown out of a worm that dies and out of
-- a very big hit. They fly, bounce, roll and come to rest on the terrain, and stay there (up to 16, the oldest recycled) as
-- ray-marched signed distance fields, drawn by the bloodsand/gibs post-FX effect (see tools/gibs.frag.in), with a splat where
-- each first lands, a streak where it slides and a pool where it rests. Small bits of meat (sprites) fly out with them.
--
-- The simulation is a sphere per gib against wum.game.landRay: a ray from where the gib was to where it is going, stretched by
-- its radius (along the motion, or down when it is slow), gives the contact point and the surface normal; the gib then bounces
-- (restitution and friction by kind), rolls (its spin follows its velocity) and, once slow, settles: its radius shrinks to the
-- height of the face it rests on, it turns that face to the ground, and after a quarter of a second at rest it sleeps (no more
-- rays, nothing sent to the effect). A sleeping gib is looked at by one ray a frame in turn, so that terrain dug out from
-- under it lets it fall. An explosion near a gib throws it again (a direct hit pops flesh into bits). Without landRay a gib
-- lands on the plane at the height of the worm's feet.
--
-- The effect's four vec4 per slot: a = (x, y, z, bounding radius), b = orientation quaternion (x, y, z, w), c = half extents and
-- kind, d = (seed, birth, wetness, bloodiness). A flying gib sends a and b every frame (rounded, so a sleeping one sends nothing);
-- c and d go out once. The effect dries a gib from its birth against our clock over about a minute.
-- All of it is in one function called once, so that its locals are its own (the file's main function is nearly full).
do
local function build()
local exp = math.exp
local N, BMAX = 16, 96
local FLY, SETTLE, SLEEP = 1, 2, 3
local MEAT, BONE, KIDNEY, LIVER, HEART, EYE, LUNG, GUT = 0, 1, 2, 3, 4, 5, 6, 7
local FX = { id = "bloodsand/gibs", cache = {}, enabled = nil, failed = false, missing = false }
-- Per "Blood" setting: the pool (never more than the effect's 16 slots), gibs thrown by a death and by a very big hit, and the
-- bits of meat that fly out with them.
local AMT = {
    light  = { pool = 8,  death = 3, big = 1, bits = 10, bitsBig = 4 },
    heavy  = { pool = 14, death = 6, big = 2, bits = 26, bitsBig = 10 },
    absurd = { pool = 16, death = 9, big = 4, bits = 46, bitsBig = 20 },
}
local T = {
    BIG = 45, BIG_ABSURD = 30,          -- damage that throws gibs besides a death
    COOLDOWN = 0.6,                     -- a worm throws gibs for hits no closer together than this
    FRAME_THROWS = 20,                  -- gibs thrown between two frames, all worms together (more only recycle the ones just thrown)
    SPEED = { 55, 150 }, UP = { 0.35, 1.1 },
    REST = { [0] = 0.22, 0.38, 0.24, 0.2, 0.26, 0.5, 0.22, 0.16 },      -- restitution by kind (bounce)
    -- A gib or a bit of meat nearer the camera than NEAR[2] starts to fade and is gone by NEAR[1] (the effect does the same, see
    -- Fade in tools/gibs.frag.in). In the aim view (the camera within AIM_DETECT of the active worm) the ones near the camera
    -- (AIM_CAM) and near the worm (AIM_WORM) are hidden too, so that they never block the aim.
    NEAR = { 25, 60 }, AIM_DETECT = 40, AIM_CAM = { 50, 90 }, AIM_WORM = { 26, 52 },
    MU = 330,                           -- sliding friction: deceleration on a flat floor, units/s^2
    SETTLE_SPEED = 28, SLEEP_SPEED = 6, SLEEP_SECS = 0.25,
    DRAG = 0.12,                        -- fraction of speed lost per second in the air
    RAYS = 20,                          -- terrain rays a frame
    STREAK_EVERY = 9, STREAK_SPEED = 40, DECALS = 3,
    REACH_MIN = 16, POP_FRAC = 0.4, POP_CHANCE = 0.65, GRACE = 0.35,
    BIT_LIFE = { 0.55, 1.15 }, BIT_SIZE = { 1.5, 3.0 },
    KILL_BELOW = 700,                   -- a gib this far under where it started has fallen out of the world
}
local PA, PB, PC, PD = {}, {}, {}, {}
for i = 1, N do
    PA[i], PB[i], PC[i], PD[i] = "g" .. (i - 1) .. "a", "g" .. (i - 1) .. "b", "g" .. (i - 1) .. "c", "g" .. (i - 1) .. "d"
end

-- One array per field, a slot per gib.
local F = {}
for _, k in ipairs({ "st", "x", "y", "z", "vx", "vy", "vz", "qx", "qy", "qz", "qw", "wx", "wy", "wz", "h1", "h2", "h3", "kind", "seed",
                     "birth", "wet", "blood", "cr", "cre", "hrT", "floor", "born", "lastC", "cnx", "cny", "cnz", "sleepT", "streak",
                     "decals", "serial", "bound", "splatAt", "lowY", "axis", "stare" }) do
    F[k] = {}
    for i = 1, N do F[k][i] = 0 end
end
local st, X, Y, Z, VX, VY, VZ = F.st, F.x, F.y, F.z, F.vx, F.vy, F.vz
local QX, QY, QZ, QW, WX, WY, WZ = F.qx, F.qy, F.qz, F.qw, F.wx, F.wy, F.wz
local H1, H2, H3, KIND = F.h1, F.h2, F.h3, F.kind
local G = { clock = 0, serial = 0, n = 0, top = 0, rays = 0, wake = 0, pv = 0, anyVis = false, countSent = -1, clockSent = -1,
            fwdx = 0, fwdy = 0, fwdz = 1, tex = nil, texChecked = false, spriteOK = false, bitsN = 0, bitsTried = false, thrown = 0 }

local B = {}                            -- the bits of meat: struct of arrays
for _, k in ipairs({ "x", "y", "z", "vx", "vy", "vz", "age", "life", "size", "tex", "r", "g", "b", "floor" }) do
    B[k] = {}
    for i = 1, BMAX do B[k][i] = 0 end
end
local col = { r = 1, g = 1, b = 1, a = 1 }

-- ---------------------------------------------------------------- the effect
local function sendV4(name, a, b, c, d)
    if not hasPostfx then return end
    local old = FX.cache[name]
    if old and old[1] == a and old[2] == b and old[3] == c and old[4] == d then return end
    local ok, res = pcall(wum.postfx.setTransient, FX.id, name, a, b, c, d)
    if not ok or res == false then return end
    if not old then
        old = {}
        FX.cache[name] = old
    end
    old[1], old[2], old[3], old[4] = a, b, c, d
end

local function r05(v) return floor(v * 20 + 0.5) / 20 end
local function r10(v) return floor(v * 1024 + 0.5) / 1024 end

-- What the effect is told of slot i. A free slot is all zeros (a radius of 0 means unused).
local function sendSlot(i, moved)
    if st[i] == 0 then
        sendV4(PA[i], 0, 0, 0, 0)
        sendV4(PB[i], 0, 0, 0, 0)
        sendV4(PC[i], 0, 0, 0, 0)
        sendV4(PD[i], 0, 0, 0, 0)
        return
    end
    sendV4(PA[i], r05(X[i]), r05(Y[i]), r05(Z[i]), F.bound[i])
    sendV4(PB[i], r10(QX[i]), r10(QY[i]), r10(QZ[i]), r10(QW[i]))
    sendV4(PC[i], H1[i], H2[i], H3[i], KIND[i])
    sendV4(PD[i], F.seed[i], floor(F.birth[i] * 100 + 0.5) / 100, F.wet[i], F.blood[i])
end

local function fxEnable(on)
    on = on and not FX.missing and not FX.failed
    if WARM.on[FX.id] then on = true end
    if not hasPostfx or FX.enabled == on then return end
    local ok, res = pcall(wum.postfx.enable, FX.id, on)
    if not ok then return end
    if res == false then
        FX.missing = true
        return
    end
    FX.enabled = on
end

local function recount()
    local n, top = 0, 0
    for i = 1, N do
        if st[i] ~= 0 then
            n = n + 1
            top = i
        end
    end
    G.n, G.top = n, top
end

-- ---------------------------------------------------------------- small maths
-- Rotates the orientation by the angle `ang` about the world axis (ax, ay, az), a unit vector.
local function rotate(i, ax, ay, az, ang)
    local s, c = sin(ang * 0.5), cos(ang * 0.5)
    local rx, ry, rz, rw = ax * s, ay * s, az * s, c
    local qx, qy, qz, qw = QX[i], QY[i], QZ[i], QW[i]
    local nx = rw * qx + rx * qw + ry * qz - rz * qy
    local ny = rw * qy - rx * qz + ry * qw + rz * qx
    local nz = rw * qz + rx * qy - ry * qx + rz * qw
    local nw = rw * qw - rx * qx - ry * qy - rz * qz
    local l = 1 / sqrt(nx * nx + ny * ny + nz * nz + nw * nw)
    QX[i], QY[i], QZ[i], QW[i] = nx * l, ny * l, nz * l, nw * l
end

-- Where the gib's local axis k (1 x, 2 y, 3 z) points in the world.
local function localAxis(i, k)
    local x, y, z, w = QX[i], QY[i], QZ[i], QW[i]
    if k == 1 then return 1 - 2 * (y * y + z * z), 2 * (x * y + w * z), 2 * (x * z - w * y) end
    if k == 2 then return 2 * (x * y - w * z), 1 - 2 * (x * x + z * z), 2 * (y * z + w * x) end
    return 2 * (x * z + w * y), 2 * (y * z - w * x), 1 - 2 * (x * x + y * y)
end

-- Turns the gib about the world axis that takes its local axis k (times sign) to the direction (tx, ty, tz) by at most `step`
-- radians, and returns the angle that was left before the turn.
local function turnAxis(i, k, sign, tx, ty, tz, step)
    local ax, ay, az = localAxis(i, k)
    ax, ay, az = ax * sign, ay * sign, az * sign
    local cx, cy, cz = ay * tz - az * ty, az * tx - ax * tz, ax * ty - ay * tx
    local sn = sqrt(cx * cx + cy * cy + cz * cz)
    local ang = math.atan(sn, ax * tx + ay * ty + az * tz)
    if sn > 1e-5 and ang > 1e-4 then rotate(i, cx / sn, cy / sn, cz / sn, ang * min(1, step / ang)) end
    return ang
end

-- Lays the gib down on the surface with the unit normal n, turning by at most `step` radians: the face it lies on is the local
-- axis most nearly along the normal, the shorter axes counting for more (a box lies on its big face, a bone on its side). The half
-- extent along it (the height of the centre when it lies there) is kept in hrT and the angle still to go is returned. An eye is a
-- ball: it needs no face, and one that stares turns its iris towards the camera and up instead.
local function settleTurn(i, nx, ny, nz, step)
    local kind = KIND[i]
    if kind == EYE then
        F.hrT[i] = H1[i] * 0.97
        if F.stare[i] ~= 1 or not CAM.ok then return 0 end
        local tx, ty, tz = CAM.px - X[i], CAM.py - Y[i], CAM.pz - Z[i]
        local tl = sqrt(tx * tx + ty * ty + tz * tz)
        if tl < 1 then return 0 end
        tx, ty, tz = nx * 0.7 + tx / tl * 0.7, ny * 0.7 + ty / tl * 0.7, nz * 0.7 + tz / tl * 0.7
        local l = sqrt(tx * tx + ty * ty + tz * tz)
        if l < 1e-3 then return 0 end
        return turnAxis(i, 1, 1, tx / l, ty / l, tz / l, step)
    end
    local h1, h2, h3 = H1[i], H2[i], H3[i]
    local hm = min(h1, min(h2, h3))
    local best, bk, bsign = -1, 1, 1
    local bh = h1
    for k = 1, 3 do
        local hk = k == 1 and h1 or (k == 2 and h2 or h3)
        local ax, ay, az = localAxis(i, k)
        local d = ax * nx + ay * ny + az * nz
        local sc = abs(d) * (hm / hk) ^ 1.6
        if sc > best then best, bk, bsign, bh = sc, k, d < 0 and -1 or 1, hk end
    end
    local hk = bh
    if kind == BONE then hk = (h2 + h3) * 0.5 end
    if kind == GUT then hk = h2 * 1.22 end
    F.axis[i], F.hrT[i] = bk, hk * 0.86
    return turnAxis(i, bk, bsign, nx, ny, nz, step)
end

-- ---------------------------------------------------------------- decals
-- The ground takes a splat where a gib hits it hard, a streak where it slides and a pool where it comes to rest. All through
-- the decal section (they are not made when the ground stains are off).
local function stainsOn()
    return hasPostfx and preset ~= nil and cfg.stains ~= false and not STAINS.failed
end

local SPLAT_SIZE = { [0] = 3.6, 1.6, 3.0, 3.4, 3.2, 2.0, 3.4, 3.0 }
local POOL_SIZE = { [0] = 6.5, 2.6, 5.2, 6.0, 5.4, 2.6, 5.6, 5.0 }

local function splatAt(i, px, py, pz, nx, ny, nz, vx, vy, vz, size)
    if not stainsOn() then return end
    DECALS.splat(px, py, pz, nx, ny, nz, vx, vy, vz, size)
end

-- ---------------------------------------------------------------- spawning
local function freeSlot()
    local am = AMT[cfg.amount] or AMT.heavy
    local pool = min(N, am.pool)
    for i = 1, pool do
        if st[i] == 0 then return i end
    end
    -- the oldest goes, a sleeping one before one in the air
    local pick, pickKey
    for i = 1, pool do
        local key = F.serial[i] + (st[i] == SLEEP and 0 or 1e6)
        if not pickKey or key < pickKey then pick, pickKey = i, key end
    end
    return pick
end

-- A random unit quaternion.
local function randQuat(i)
    local a, b, c, d = rnd(-1, 1), rnd(-1, 1), rnd(-1, 1), rnd(-1, 1)
    local l = sqrt(a * a + b * b + c * c + d * d)
    if l < 0.1 then a, b, c, d, l = 0, 0, 0, 1, 1 end
    QX[i], QY[i], QZ[i], QW[i] = a / l, b / l, c / l, d / l
end

local function dims(kind, sm)
    if kind == MEAT then return rnd(3.0, 4.8) * sm, rnd(2.0, 3.1) * sm, rnd(2.0, 3.1) * sm end
    if kind == BONE then return rnd(4.0, 7.0) * sm, rnd(1.0, 1.4) * sm, rnd(0.7, 1.0) * sm end
    if kind == KIDNEY then return 2.8 * sm * rnd(0.9, 1.1), 1.8 * sm * rnd(0.9, 1.1), 1.9 * sm * rnd(0.9, 1.1) end
    if kind == LIVER then return 5.0 * sm * rnd(0.85, 1.1), 1.5 * sm * rnd(0.9, 1.1), 3.3 * sm * rnd(0.85, 1.1) end
    if kind == HEART then return 2.6 * sm * rnd(0.9, 1.1), 3.0 * sm * rnd(0.9, 1.1), 2.4 * sm * rnd(0.9, 1.1) end
    if kind == LUNG then return 4.4 * sm * rnd(0.9, 1.1), 3.0 * sm * rnd(0.9, 1.1), 2.2 * sm * rnd(0.9, 1.1) end
    if kind == GUT then return 3.6 * sm * rnd(0.9, 1.1), 1.35 * sm * rnd(0.9, 1.1), 3.6 * sm * rnd(0.9, 1.1) end
    local r = 1.8 * sm * rnd(0.92, 1.08)
    return r, r, r
end

-- One gib, thrown from (x, y, z) with a velocity; floorY is the plane it lands on without landRay.
local function throwGib(kind, x, y, z, vx, vy, vz, floorY, sm)
    local i = freeSlot()
    if not i then return end
    G.serial = G.serial + 1
    local h1, h2, h3 = dims(kind, sm)
    st[i], KIND[i] = FLY, kind
    X[i], Y[i], Z[i], VX[i], VY[i], VZ[i] = x, y, z, vx, vy, vz
    H1[i], H2[i], H3[i] = h1, h2, h3
    randQuat(i)
    local sp = rnd(5, 13)
    local ax, ay, az = rnd(-1, 1), rnd(-1, 1), rnd(-1, 1)
    local al = sqrt(ax * ax + ay * ay + az * az)
    if al < 0.05 then ax, ay, az, al = 1, 0, 0, 1 end
    WX[i], WY[i], WZ[i] = ax / al * sp, ay / al * sp, az / al * sp
    local cr
    if kind == BONE then cr = max(h2 * 1.5, h1 * 0.3)
    elseif kind == LIVER then cr = (h1 + h3) * 0.25
    elseif kind == EYE then cr = h1 * 0.95
    else cr = (h1 + h2 + h3) / 3 * 0.8 end
    F.cr[i], F.cre[i], F.hrT[i] = cr, cr, cr
    F.seed[i] = floor(random() * 970) / 10
    F.birth[i] = G.clock
    F.wet[i] = rnd(0.85, 1)
    F.blood[i] = kind == EYE and 0.3 or (kind == BONE and 0.45 or 0.55)
    F.floor[i], F.lowY[i], F.born[i] = floorY, floorY - T.KILL_BELOW, G.clock
    F.lastC[i], F.cnx[i], F.cny[i], F.cnz[i] = -9, 0, 1, 0
    F.sleepT[i], F.streak[i], F.decals[i], F.splatAt[i] = 0, 0, T.DECALS, -9
    F.serial[i], F.axis[i] = G.serial, 0
    F.stare[i] = (kind == EYE and random() < 0.5) and 1 or 0
    local R = sqrt(h1 * h1 + h2 * h2 + h3 * h3)
    F.bound[i] = kind == BONE and floor(((h1 + 1.5 * h2) * 1.15 + 3) * 10) / 10 or floor((R * 1.2 + 3) * 10) / 10
    recount()
    sendSlot(i)
end

-- The colour (a tint for a grey sprite) of one bit: muscle, a pink scrap, fat or a speck of bone; with a blood colour that is not
-- red (Green) the flesh takes some of it, as the effect's does.
local function bitColour()
    local r, g, b
    local pick = random()
    if pick < 0.55 then r, g, b = rnd(0.62, 0.85), rnd(0.07, 0.13), rnd(0.07, 0.11)         -- muscle
    elseif pick < 0.8 then r, g, b = rnd(0.92, 1.0), rnd(0.42, 0.55), rnd(0.4, 0.5)            -- pink scrap
    elseif pick < 0.93 then r, g, b = 1.0, rnd(0.82, 0.92), rnd(0.55, 0.65)                    -- fat
    else r, g, b = 1.0, 0.95, 0.82 end                                                          -- bone
    local sc = palette.stain
    local m = max(sc[1], sc[2], sc[3], 1e-3)
    local f = 0.35 * (1 - sc[1] / m)
    if f > 0.01 and pick < 0.93 then
        local lum = (0.3 * r + 0.59 * g + 0.11 * b) * 1.8
        r, g, b = min(1, r + (lum * sc[1] / m - r) * f), min(1, g + (lum * sc[2] / m - g) * f), min(1, b + (lum * sc[3] / m - b) * f)
    end
    return r, g, b
end

local function addBit(x, y, z, vx, vy, vz, size, floorY)
    local n = G.bitsN
    if n >= BMAX then return end
    n = n + 1
    G.bitsN = n
    B.x[n], B.y[n], B.z[n], B.vx[n], B.vy[n], B.vz[n] = x, y, z, vx, vy, vz
    B.age[n], B.life[n], B.size[n] = 0, rnd(T.BIT_LIFE[1], T.BIT_LIFE[2]), size
    B.tex[n] = random(1, 3)
    B.r[n], B.g[n], B.b[n] = bitColour()
    B.floor[n] = floorY
end

local function pickKind(k, death, n)
    if death and k == 1 then
        local r = random()
        return r < 0.3 and HEART or (r < 0.48 and EYE or (r < 0.63 and LIVER or (r < 0.75 and KIDNEY or (r < 0.88 and LUNG or GUT))))
    end
    if k == 2 and n >= 6 then return BONE end
    local r = random()
    if r < 0.44 then return MEAT end
    if r < 0.66 then return BONE end
    if r < 0.72 then return KIDNEY end
    if r < 0.79 then return LIVER end
    if r < 0.85 then return HEART end
    if r < 0.91 then return LUNG end
    if r < 0.96 then return GUT end
    return EYE
end

-- The gibs and bits of one worm's death or very big hit. (dx, dy, dz) is the unit direction of the blow.
local function fire(s, dx, dy, dz, n, nbits, strength, death)
    local cx, cy, cz = s.px, s.py + CENTRE_Y, s.pz
    local floorY = s.py + FEET_Y
    local far = 0
    if CAM.ok then
        local ex, ey, ez = cx - CAM.px, cy - CAM.py, cz - CAM.pz
        far = min(1, max(0, (sqrt(ex * ex + ey * ey + ez * ez) - FAR_START) / FAR_SPAN))
    end
    local sm = 1.15 * (1 + 0.3 * far)
    n = max(0, min(n, T.FRAME_THROWS - G.thrown))
    G.thrown = G.thrown + n
    nbits = max(0, min(nbits, BMAX - G.bitsN))
    for k = 1, n do
        local kind = pickKind(k, death, n)
        local a, up = random() * 2 * pi, rnd(T.UP[1], T.UP[2])
        local ex, ey, ez = dx * 0.9 + cos(a) * rnd(0.5, 1), dy * 0.5 + up, dz * 0.9 + sin(a) * rnd(0.5, 1)
        local el = sqrt(ex * ex + ey * ey + ez * ez)
        if el < 1e-4 then ex, ey, ez, el = 0, 1, 0, 1 end
        local sp = rnd(T.SPEED[1], T.SPEED[2]) * (0.65 + 0.5 * strength) / el
        throwGib(kind, cx + rnd(-4, 4), cy + rnd(-5, 6), cz + rnd(-2, 2), ex * sp, ey * sp, ez * sp, floorY, sm)
    end
    for _ = 1, nbits do
        local a, up = random() * 2 * pi, rnd(0.2, 1.2)
        local ex, ey, ez = dx * 0.6 + cos(a), dy * 0.4 + up, dz * 0.6 + sin(a)
        local el = sqrt(ex * ex + ey * ey + ez * ez)
        if el < 1e-4 then ex, ey, ez, el = 0, 1, 0, 1 end
        local sp = rnd(110, 300) * (0.6 + 0.5 * strength) / el
        addBit(cx + rnd(-4, 4), cy + rnd(-5, 6), cz + rnd(-2, 2), ex * sp, ey * sp, ez * sp, rnd(T.BIT_SIZE[1], T.BIT_SIZE[2]) * sm, floorY)
    end
end

-- Called by burst() for every burst of blood: a death, and a hit of at least BIG damage.
function GIBS.onBurst(s, damage, dx, dy, dz, death)
    if not preset or cfg.gibs == false then return end
    local am = AMT[cfg.amount] or AMT.heavy
    local n, nb, strength
    if death then
        n, nb, strength = am.death, am.bits, 1
    else
        local thr = cfg.amount == "absurd" and T.BIG_ABSURD or T.BIG
        if damage < thr then return end
        if s.gibAt and G.clock - s.gibAt < T.COOLDOWN then return end
        n = am.big + (damage >= thr * 2 and 1 or 0)
        nb = am.bitsBig
        strength = min(1, damage / DEATH_DAMAGE)
    end
    s.gibAt = G.clock
    fire(s, dx, dy, dz, min(n, floor(min(N, am.pool) / 2)), nb, strength, death)
end

-- ---------------------------------------------------------------- simulation
-- Where the segment from (x0, y0, z0) to the point r further on along (ex, ey, ez) from (x1, y1, z1) first meets the terrain: the
-- unit normal, the point and how far the end of the segment is beyond the surface (along the normal), or nil.
local function contact(i, x0, y0, z0, x1, y1, z1, ex, ey, ez, r)
    local ax, ay, az = x1 + ex * r, y1 + ey * r, z1 + ez * r
    if DECALS.rayOK then
        if G.rays >= T.RAYS then return nil end
        G.rays = G.rays + 1
        local t, nx, ny, nz = DECALS.cast(x0, y0, z0, ax, ay, az, false)
        if t then
            local hx, hy, hz = x0 + (ax - x0) * t, y0 + (ay - y0) * t, z0 + (az - z0) * t
            return nx, ny, nz, hx, hy, hz, max(0, (hx - ax) * nx + (hy - ay) * ny + (hz - az) * nz)
        end
        return nil
    end
    local fy = F.floor[i]
    if ay <= fy then return 0, 1, 0, ax, fy, az, fy - ay end
    return nil
end

local function stepGib(i, dt)
    local x0, y0, z0 = X[i], Y[i], Z[i]
    local vx, vy, vz = VX[i], VY[i], VZ[i]
    local dk = 1 - T.DRAG * dt
    vx, vy, vz = vx * dk, (vy + GRAVITY * dt) * dk, vz * dk
    local x1, y1, z1 = x0 + vx * dt, y0 + vy * dt, z0 + vz * dt
    local r = F.cre[i]
    local sp = sqrt(vx * vx + vy * vy + vz * vz)
    local clock = G.clock
    local ex, ey, ez
    if sp * dt > 0.35 * r then
        local k = 1 / sp
        ex, ey, ez = vx * k, vy * k, vz * k
    elseif clock - F.lastC[i] < 0.3 then
        ex, ey, ez = -F.cnx[i], -F.cny[i], -F.cnz[i]
    else
        ex, ey, ez = 0, -1, 0
    end
    local kind = KIND[i]
    local nx, ny, nz, hx, hy, hz, pen = contact(i, x0, y0, z0, x1, y1, z1, ex, ey, ez, r)
    local touching = false
    if nx then
        touching = true
        local wasOn = clock - F.lastC[i] < 0.05
        -- pushed back out along the normal by how far it went in (not set down at the hit point: that creeps down a slope)
        x1, y1, z1 = x1 + nx * pen, y1 + ny * pen, z1 + nz * pen
        local vn = vx * nx + vy * ny + vz * nz
        if vn < 0 then
            local imp = -vn
            local tx, ty, tz = vx - vn * nx, vy - vn * ny, vz - vn * nz
            local rest = imp < 55 and 0 or T.REST[kind]
            vx, vy, vz = tx * 0.72 - nx * vn * rest, ty * 0.72 - ny * vn * rest, tz * 0.72 - nz * vn * rest
            -- a blow leaves blood where it lands, no more often than every tenth of a second
            if imp > 70 and clock - F.splatAt[i] > 0.1 then
                F.splatAt[i] = clock
                splatAt(i, hx, hy, hz, nx, ny, nz, tx - nx * imp, ty - ny * imp, tz - nz * imp, SPLAT_SIZE[kind] * (0.8 + 0.4 * min(1, imp / 250)))
            end
        end
        F.lastC[i], F.cnx[i], F.cny[i], F.cnz[i] = clock, nx, ny, nz
        -- friction against the surface, a little less on a slope
        local vn2 = vx * nx + vy * ny + vz * nz
        local tx, ty, tz = vx - vn2 * nx, vy - vn2 * ny, vz - vn2 * nz
        local ts = sqrt(tx * tx + ty * ty + tz * tz)
        if ts > 0 then
            local ts2 = max(0, ts - T.MU * max(ny, 0.15) * dt)
            local k = ts2 / ts
            vx, vy, vz = vx - tx * (1 - k), vy - ty * (1 - k), vz - tz * (1 - k)
            ts = ts2
        end
        -- held by friction: it does not slip down the slope by what this frame's gravity would have moved it
        if ts <= 0 and wasOn and st[i] ~= FLY then x1, y1, z1 = x0, y0, z0 end
        -- it rolls: the spin follows the velocity (a bone only turns slowly, it does not roll)
        local roll = kind == BONE and 0 or min(1, 7 * dt)
        local rwx, rwy, rwz = (ny * tz - nz * ty) / r, (nz * tx - nx * tz) / r, (nx * ty - ny * tx) / r
        local damp = exp(-(kind == BONE and 3.5 or 1.2) * dt)
        WX[i], WY[i], WZ[i] = (WX[i] + (rwx - WX[i]) * roll) * damp, (WY[i] + (rwy - WY[i]) * roll) * damp, (WZ[i] + (rwz - WZ[i]) * roll) * damp
        -- a streak where it slides
        if ts > T.STREAK_SPEED and F.decals[i] > 0 then
            F.streak[i] = F.streak[i] + ts * dt
            if F.streak[i] > T.STREAK_EVERY then
                F.streak[i] = 0
                F.decals[i] = F.decals[i] - 1
                splatAt(i, x1 - nx * r, y1 - ny * r, z1 - nz * r, nx, ny, nz, tx - nx * 20, ty - ny * 20, tz - nz * 20,
                        kind == BONE and 1.0 or 1.5)
            end
        end
        if st[i] == FLY and ts < T.SETTLE_SPEED and vn2 < 30 and ny > 0.45 then st[i] = SETTLE end
    elseif st[i] == SETTLE and clock - F.lastC[i] > 0.25 then
        -- it went over an edge: in the air again
        st[i] = FLY
        F.cre[i] = F.cr[i]
        F.sleepT[i] = 0
    end

    -- turning: tumbling in the air, or lying down on a face once it has settled
    local wx, wy, wz = WX[i], WY[i], WZ[i]
    local wl = sqrt(wx * wx + wy * wy + wz * wz)
    if st[i] == SETTLE then
        local cnx, cny, cnz = F.cnx[i], F.cny[i], F.cnz[i]
        local err = settleTurn(i, cnx, cny, cnz, 9 * dt)
        local ds = 1 - exp(-6 * dt)
        WX[i], WY[i], WZ[i] = wx * (1 - ds), wy * (1 - ds), wz * (1 - ds)
        F.cre[i] = F.cre[i] + (F.hrT[i] - F.cre[i]) * min(1, 10 * dt)
        local still = sqrt(vx * vx + vy * vy + vz * vz) < T.SLEEP_SPEED and wl < 0.5 and err < 0.05 and abs(F.cre[i] - F.hrT[i]) < 0.15 and touching
        if still then
            F.sleepT[i] = F.sleepT[i] + dt
            if F.sleepT[i] >= T.SLEEP_SECS then
                st[i] = SLEEP
                vx, vy, vz = 0, 0, 0
                WX[i], WY[i], WZ[i] = 0, 0, 0
                -- the pool it lies in
                if stainsOn() and cny > 0.2 then
                    requestPool(x1 - cnx * F.cre[i], y1 - cny * F.cre[i], z1 - cnz * F.cre[i], POOL_SIZE[kind], cnx, cny, cnz)
                end
            end
        else
            F.sleepT[i] = 0
        end
    elseif wl > 1e-3 then
        local k = 0.5 * dt
        local qx, qy, qz, qw = QX[i], QY[i], QZ[i], QW[i]
        local nqx = qx + k * (qw * wx + wy * qz - wz * qy)
        local nqy = qy + k * (qw * wy + wz * qx - wx * qz)
        local nqz = qz + k * (qw * wz + wx * qy - wy * qx)
        local nqw = qw - k * (wx * qx + wy * qy + wz * qz)
        local l = 1 / sqrt(nqx * nqx + nqy * nqy + nqz * nqz + nqw * nqw)
        QX[i], QY[i], QZ[i], QW[i] = nqx * l, nqy * l, nqz * l, nqw * l
    end
    X[i], Y[i], Z[i], VX[i], VY[i], VZ[i] = x1, y1, z1, vx, vy, vz
    if y1 < F.lowY[i] then
        st[i] = 0
        sendSlot(i)
        recount()
    end
end

-- One sleeping gib a frame, in turn, is asked whether the ground is still under it: when it is not (an explosion dug it away),
-- it falls.
local function wakeCheck()
    local k = G.wake % N + 1
    G.wake = G.wake + 1
    if st[k] ~= SLEEP or not DECALS.rayOK or G.rays >= T.RAYS + 4 then return end
    local nx, ny, nz = F.cnx[k], F.cny[k], F.cnz[k]
    local reach = F.cre[k] + 2.5
    G.rays = G.rays + 1
    local t, reason = DECALS.cast(X[k], Y[k], Z[k], X[k] - nx * reach, Y[k] - ny * reach, Z[k] - nz * reach, true)
    -- (a miss, not a refusal: the ground under it is gone)
    if not t and reason == nil then
        st[k] = FLY
        F.cre[k], F.sleepT[k], F.lastC[k] = F.cr[k], 0, -9
    end
end

-- ---------------------------------------------------------------- near the camera
local function sstep(a, b, x)
    if x <= a then return 0 end
    if x >= b then return 1 end
    local t = (x - a) / (b - a)
    return t * t * (3 - 2 * t)
end

-- Is the camera in the aim view (close to the active worm)? Then the effect is told where the worm is.
local function updateAim()
    local on, ax, ay, az = false, 0, 0, 0
    if CAM.ok and MEL.active then
        local s = slots[MEL.active]
        if s and not s.dead then
            ax, ay, az = s.px, s.py + CENTRE_Y, s.pz
            local dx, dy, dz = ax - CAM.px, ay - CAM.py, az - CAM.pz
            on = dx * dx + dy * dy + dz * dz < T.AIM_DETECT * T.AIM_DETECT
        end
    end
    G.aimOn, G.aimX, G.aimY, G.aimZ = on, ax, ay, az
    if on then sendV4("aim", r05(ax), r05(ay), r05(az), 1) else sendV4("aim", 0, 0, 0, 0) end
end

-- How much of something at (x, y, z) is left after fading it for being near the camera (1 whole, 0 gone).
local function nearFade(x, y, z)
    if not CAM.ok then return 1 end
    local dx, dy, dz = x - CAM.px, y - CAM.py, z - CAM.pz
    local f = sstep(T.NEAR[1], T.NEAR[2], sqrt(dx * dx + dy * dy + dz * dz))
    if G.aimOn then
        f = min(f, sstep(T.AIM_CAM[1], T.AIM_CAM[2], sqrt(dx * dx + dy * dy + dz * dz)))
        dx, dy, dz = x - G.aimX, y - G.aimY, z - G.aimZ
        f = min(f, sstep(T.AIM_WORM[1], T.AIM_WORM[2], sqrt(dx * dx + dy * dy + dz * dz)))
    end
    return f
end

-- ---------------------------------------------------------------- the bits
local function loadTex()
    G.texChecked = true
    if not (wum.draw.sprite and wum.draw.texture) then return end
    local list = {}
    for k = 1, 3 do
        local ok, tex = pcall(wum.draw.texture, "textures/bs_bit" .. k .. ".png")
        if not (ok and tex) then return end
        list[k] = tex
    end
    G.tex = list
end

local function probeSprite()
    G.spriteOK = G.tex ~= nil and pcall(wum.draw.sprite, G.tex[1], 0, 0, 0, 0, 0, 0, 0, 0)
end

local function stepBits(dt)
    local n = G.bitsN
    local spr = wum.draw.sprite
    local tex = G.tex
    local ok = G.spriteOK
    local i = 1
    while i <= n do
        local age = B.age[i] + dt
        local x, y, z = B.x[i], B.y[i], B.z[i]
        local vx, vy, vz = B.vx[i], B.vy[i], B.vz[i]
        local life = B.life[i]
        if age >= life or y < B.floor[i] then
            -- gone: the last one takes its place
            local m = n
            B.x[i], B.y[i], B.z[i], B.vx[i], B.vy[i], B.vz[i] = B.x[m], B.y[m], B.z[m], B.vx[m], B.vy[m], B.vz[m]
            B.age[i], B.life[i], B.size[i], B.tex[i] = B.age[m], B.life[m], B.size[m], B.tex[m]
            B.r[i], B.g[i], B.b[i], B.floor[i] = B.r[m], B.g[m], B.b[m], B.floor[m]
            n = n - 1
        else
            local dk = 1 - 0.4 * dt
            vx, vy, vz = vx * dk, (vy + GRAVITY * 0.9 * dt) * dk, vz * dk
            x, y, z = x + vx * dt, y + vy * dt, z + vz * dt
            B.x[i], B.y[i], B.z[i], B.vx[i], B.vy[i], B.vz[i], B.age[i] = x, y, z, vx, vy, vz, age
            if ok then
                local t = age / life
                local a = (t > 0.7 and (1 - t) / 0.3 or 1) * nearFade(x, y, z)
                if a > 0.01 then
                    local sp = sqrt(vx * vx + vy * vy + vz * vz)
                    col.r, col.g, col.b, col.a = min(1, B.r[i] * 1.25), min(1, B.g[i] * 1.25), min(1, B.b[i] * 1.25), a
                    local hw = B.size[i] * 0.6
                    local k = sp > 1 and 1 / sp or 0
                    spr(tex[B.tex[i]], x, y, z, hw, hw * (1 + min(0.8, sp * 0.003)), vx * k, vy * k, vz * k, col, "alpha")
                end
            end
            i = i + 1
        end
    end
    G.bitsN = n
end

-- ---------------------------------------------------------------- the fallback
-- Without the effect (an old Melange, or a driver it failed on) a gib is a sprite or two: a lump for flesh, a long pale one for
-- bone.
local function drawFallback()
    if not (G.spriteOK and G.tex) then return end
    local spr = wum.draw.sprite
    for i = 1, N do
        local fd = st[i] ~= 0 and nearFade(X[i], Y[i], Z[i]) or 0
        if fd > 0.01 then
            local kind = KIND[i]
            if kind == BONE then
                local ax, ay, az = localAxis(i, 1)
                col.r, col.g, col.b, col.a = 1, 0.95, 0.82, fd
                spr(G.tex[1], X[i], Y[i], Z[i], H2[i] * 1.2, H1[i], ax, ay, az, col, "alpha")
            else
                if kind == EYE then col.r, col.g, col.b = 1, 0.92, 0.9
                elseif kind == MEAT then col.r, col.g, col.b = 0.9, 0.15, 0.12
                else col.r, col.g, col.b = 0.75, 0.1, 0.1 end
                col.a = fd
                local hw = (H1[i] + H2[i] + H3[i]) / 3
                spr(G.tex[(i % 3) + 1], X[i], Y[i], Z[i], hw, hw, 0, 0, 0, col, "alpha")
            end
        end
    end
end

-- ---------------------------------------------------------------- per frame
local function inView(i)
    if not CAM.ok then return true end
    local dx, dy, dz = X[i] - CAM.px, Y[i] - CAM.py, Z[i] - CAM.pz
    local z = dx * G.fwdx + dy * G.fwdy + dz * G.fwdz
    local r = F.bound[i]
    if z < -r then return false end
    local zr = max(z, 0) + r
    if abs(dx * CAM.rx + dy * CAM.ry + dz * CAM.rz) > zr * 1.0 + r then return false end
    if abs(dx * CAM.ux + dy * CAM.uy + dz * CAM.uz) > zr * 0.7 + r then return false end
    return true
end

function GIBS.tick(dt)
    G.thrown = 0
    if G.n == 0 and G.bitsN == 0 then
        if FX.enabled or WARM.on[FX.id] then fxEnable(false) end
        return
    end
    if not preset or cfg.gibs == false then
        GIBS.clear()
        return
    end
    if dt <= 0 then return end
    if not G.texChecked then loadTex() end
    if G.tex and not G.bitsTried then
        G.bitsTried = true
        probeSprite()
    end
    G.clock = G.clock + dt
    G.rays = 0
    updateAim()
    if CAM.ok then
        G.fwdx, G.fwdy, G.fwdz = CAM.uy * CAM.rz - CAM.uz * CAM.ry, CAM.uz * CAM.rx - CAM.ux * CAM.rz, CAM.ux * CAM.ry - CAM.uy * CAM.rx
    end
    if G.bitsN > 0 then stepBits(dt) end
    local vis = false
    for i = 1, N do
        local s = st[i]
        if s == FLY or s == SETTLE then
            stepGib(i, dt)
            if st[i] ~= 0 then sendSlot(i, true) end
        end
        if not vis and st[i] ~= 0 and inView(i) then vis = true end
    end
    G.anyVis = vis
    wakeCheck()
    -- the effect: a clock it dries by, how many slots to look at, on only while a gib may be on the screen
    local ck = floor(G.clock * 4) / 4
    if ck ~= G.clockSent then
        G.clockSent = ck
        sendParam(FX, "clock", ck)
    end
    if G.top ~= G.countSent then
        G.countSent = G.top
        sendParam(FX, "count", G.top)
    end
    local useFx = not FX.missing and not FX.failed and hasPostfx
    fxEnable(useFx and vis)
    if not useFx and G.n > 0 then drawFallback() end
end

-- ---------------------------------------------------------------- explosions
-- An explosion at (x, y, z) that digs a crater of radius landR and hurts worms within wormR: gibs near it are thrown again, away
-- from it, harder the nearer; a flesh gib right in the crater is blown into bits.
function GIBS.blast(x, y, z, landR, wormR)
    if G.n == 0 then return end
    landR, wormR = landR or 0, wormR or 0
    local reach = max(landR * 1.6, min(wormR, 90) * 0.7)
    if reach <= 0 then return end
    reach = max(reach, T.REACH_MIN)
    local clock = G.clock
    for i = 1, N do
        if st[i] ~= 0 and clock - F.born[i] > T.GRACE then
            local dx, dy, dz = X[i] - x, Y[i] - y, Z[i] - z
            local d2 = dx * dx + dy * dy + dz * dz
            if d2 < reach * reach then
                local d = sqrt(d2)
                local f = 1 - d / reach
                local kind = KIND[i]
                if d < landR * T.POP_FRAC and kind ~= BONE and random() < T.POP_CHANCE then
                    -- popped: bits where it was, and the slot is free
                    local floorY = F.floor[i]
                    for _ = 1, 7 do
                        local a, up = random() * 2 * pi, rnd(0.2, 1.1)
                        local sp = rnd(110, 280)
                        local l = sqrt(1 + up * up)
                        addBit(X[i], Y[i], Z[i], cos(a) / l * sp, up / l * sp, sin(a) / l * sp, rnd(T.BIT_SIZE[1], T.BIT_SIZE[2]), floorY)
                    end
                    st[i] = 0
                    sendSlot(i)
                else
                    local l = d > 1e-3 and 1 / d or 0
                    local ox, oy, oz = dx * l, dy * l, dz * l
                    if d <= 1e-3 then ox, oy, oz = 0, 1, 0 end
                    oy = oy + 0.55
                    local ol = sqrt(ox * ox + oy * oy + oz * oz)
                    local sp = (70 + 190 * f) * rnd(0.8, 1.2) / ol
                    VX[i], VY[i], VZ[i] = ox * sp, oy * sp, oz * sp
                    local wl = rnd(6, 14)
                    local a = random() * 2 * pi
                    WX[i], WY[i], WZ[i] = cos(a) * wl, rnd(-0.5, 0.5) * wl, sin(a) * wl
                    st[i] = FLY
                    F.cre[i], F.sleepT[i], F.lastC[i], F.decals[i] = F.cr[i], 0, -9, T.DECALS
                    F.lowY[i] = min(F.lowY[i], Y[i] - T.KILL_BELOW * 0.5)
                end
            end
        end
    end
    recount()
end

-- ---------------------------------------------------------------- the rest
function GIBS.clear()
    for i = 1, N do
        st[i] = 0
        sendSlot(i)
    end
    G.n, G.top, G.bitsN, G.anyVis = 0, 0, 0, false
    G.countSent = -1
    sendParam(FX, "count", 0)
    sendV4("aim", 0, 0, 0, 0)
    G.aimOn = false
    fxEnable(false)
end

function GIBS.apply(on)
    if on == false and (G.n > 0 or G.bitsN > 0) then GIBS.clear() end
    -- a smaller pool takes the slots above it away
    local pool = min(N, (AMT[cfg.amount] or AMT.heavy).pool)
    local changed = false
    for i = pool + 1, N do
        if st[i] ~= 0 then
            st[i] = 0
            sendSlot(i)
            changed = true
        end
    end
    if changed then recount() end
end

function GIBS.setBlood(c)
    sendParam(FX, "blood", c[1], c[2], c[3])
end

-- Every slot goes out again, one at a time (steps 1..16 of the insurance resend) and the rest at step 17.
function GIBS.resendStep(k)
    if not hasPostfx then return end
    if k <= N then
        FX.cache[PA[k]], FX.cache[PB[k]], FX.cache[PC[k]], FX.cache[PD[k]] = nil, nil, nil, nil
        sendSlot(k)
    else
        FX.cache.clock, FX.cache.count, FX.cache.blood, FX.cache.dryTime, FX.cache.aim = nil, nil, nil, nil, nil
        G.clockSent, G.countSent = -1, -1
        GIBS.setBlood(palette.stain)
    end
end

function GIBS.zero()
    for i = 1, N do sendSlot(i) end
    sendV4("aim", 0, 0, 0, 0)
    sendParam(FX, "count", 0)
    sendParam(FX, "clock", 0)
    GIBS.setBlood(palette.stain)
end

-- Is the effect there and does it run? Asked every couple of seconds.
function GIBS.checkFx()
    if not (hasPostfx and wum.postfx.list) then return end
    local ok, list = pcall(wum.postfx.list)
    if not ok or type(list) ~= "table" then return end
    local found = false
    for i = 1, #list do
        local e = list[i]
        if type(e) == "table" and e.id == FX.id then
            found = true
            FX.failed = e.failed == true
        end
    end
    FX.missing = not found
    if FX.failed and not FX.warned then
        FX.warned = true
        if wum.log and wum.log.warn then
            wum.log.warn("Bloodsand: the effect " .. FX.id .. " failed to draw on this graphics driver, so the gibs are drawn as flat sprites")
        end
    end
end

-- One press of Preview: gibs thrown from the worm like a very big hit, and from every third press like a death.
function GIBS.preview(s)
    if not preset or cfg.gibs == false then return end
    G.pv = G.pv + 1
    local dx, dz
    if CAM.ok then dx, dz = CAM.rx, CAM.rz else dx, dz = sin(s.heading or 0), cos(s.heading or 0) end
    local l = sqrt(dx * dx + dz * dz)
    if l < 1e-3 then dx, dz, l = 1, 0, 1 end
    local am = AMT[cfg.amount] or AMT.heavy
    local death = G.pv % 3 == 0
    fire(s, dx / l * 0.8, 0.5, dz / l * 0.8, death and am.death or am.big + 1, death and am.bits or am.bitsBig + 4, death and 1 or 0.7, death)
end

-- For the tests: the live gibs.
function GIBS.stats()
    local o = { n = G.n, bits = G.bitsN, fly = 0, settle = 0, sleep = 0, top = G.top }
    for i = 1, N do
        local s = st[i]
        if s == FLY then o.fly = o.fly + 1 elseif s == SETTLE then o.settle = o.settle + 1 elseif s == SLEEP then o.sleep = o.sleep + 1 end
    end
    return o
end


end
build()
end
WARM.ids[#WARM.ids + 1] = "bloodsand/gibs"
wum.timers.every(2, GIBS.checkFx)
-- == end Gibs ==

-- == Melee hooks ================================================================================================
-- Kept at the end of the file, below every local the other sections define, so that these names find them.
--
-- requestPool(x, y, z, size, nx, ny, nz) is the decals section's: a big pool of blood on the ground at (x, y, z), `size`
-- being its radius, with the unit surface normal when the game's landRay gave one.
MEL.pool = requestPool

-- setScorch(slot, amount): the skin side's hook for a burnt mark on a worm (0..1, raised to at least amount); the amount
-- is also left in the worm's state as s.scorch.
function MEL.scorch(slot, amount)
    if slot == nil then return end
    local s = slots[slot]
    if s then s.scorch = max(s.scorch or 0, amount) end
    setScorch(slot, amount)
end

loadLens()
DROP.load()
zeroAll()
sendSeed()
applySettings()

wum.draw.on("world", onWorld)
if wum.draw.hudImage then wum.draw.on("hud", drawSplats) end
if hasMenu then wum.ui.menu("Preview", preview) end
-- The same preview for anything that emits the mod event, such as the Lua console.
if wum.events and wum.events.on then wum.events.on("mod.bloodsand.preview", preview) end
wum.timers.every(0.5, applySettings)
wum.timers.every(RESEND_SECS, startResend)
VIS.checkFx()
wum.timers.every(2, VIS.checkFx)
