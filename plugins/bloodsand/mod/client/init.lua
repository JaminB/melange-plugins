-- Bloodsand: blood bursts when worms are hit, bleeding afterwards, blood and gaping wounds on the worms' skin,
-- blackened eyes and intestines on badly hurt worms, vomiting blood, stains on the ground and splatter on the lens.
--
-- It only reads game state (worm health, positions and facing, damage and explosion messages, the camera) and draws. It
-- never changes the simulation, sends anything or asks for a permission, so every player sees their own blood.
--
-- Droplets and mist are world quads drawn from one "world" callback. The ground decals are the bloodsand/stains post-FX
-- effect (32 slots of splats and pools on any surface; a droplet that meets the terrain, seen with wum.game.landRay where
-- Melange has it, leaves one), the blood, wounds, black eyes, scorching and the torn belly painted on a worm are
-- bloodsand/skin (sixteen slots that follow the worms) and the intestines that hang out of a torn belly are
-- bloodsand/guts (up to four worms), a chain simulated here and ray-marched there; all three are fed with
-- wum.postfx.setTransient, which writes nothing to Melange.ini. The lens splats are textures drawn at the "hud" stage.

if not (wum.draw and wum.draw.on and wum.game and wum.game.worms) then return end

local DEBUG = false

-- Per "Blood" setting: the most live particles, droplets per point of damage, mist puffs per burst, a multiplier for
-- the bleeding rate and the most splats one burst puts on the lens.
local AMOUNT = {
    light  = { max = 120, perDamage = 1.0, mist = 2, bleed = 0.6, lens = 1 },
    heavy  = { max = 300, perDamage = 2.4, mist = 4, bleed = 1.0, lens = 2 },
    absurd = { max = 480, perDamage = 4.5, mist = 7, bleed = 1.8, lens = 3 },
}
local POOL_MAX = 480
local BURST_MAX = 150           -- droplets in one burst, however much damage it was
-- A Lua callback may run 500000 VM instructions (Melange stops it after three faults for the rest of the session), and a
-- spawned particle costs a few hundred. So one frame spawns about SPAWN particles for bursts; a burst that finds the budget
-- spent waits in a queue of QUEUE entries for the next frames (and is dropped after QUEUE_SECS), and a burst never takes
-- more than half of the room the pool has left (but FAIR_MIN at least) so the worms of one blast share it.
local BUDGET = { SPAWN = 200, MIN_LEFT = 30, QUEUE = 24, QUEUE_SECS = 0.75, FAIR_MIN = 24, spawned = 0 }
local BURST_BASE = 8            -- every hit sprays as if it did this much more damage, so a light one still shows
local DEATH_DAMAGE = 60         -- a death counts as this much damage

-- World units and seconds. A worm is about 30 units tall and +Y is up.
local GRAVITY = -420
local DRAG = 0.6                -- fraction of speed lost per second
local MIST_GRAVITY = 0.15       -- mist falls much more slowly than droplets
local MIST_DRAG = 3
local DROPLET_LIFE = { 0.8, 1.8 }
local DROPLET_SPEED = { 70, 230 }
local DROPLET_SIZE = { 1.1, 3.0 }
local MIST_LIFE = { 0.5, 0.9 }
local MIST_SIZE = { 8, 18 }
local MIST_ALPHA = 0.3
local DROPLET_ALPHA = 0.9
local FADE_START = 0.7          -- droplets start to fade after this fraction of their life
local STREAK_SECONDS = 0.03     -- a streak is as long as the distance covered in this time...
local STREAK_MIN, STREAK_MAX = 3.5, 22  -- ...within these limits
-- A droplet is drawn as a thin lighter film, a dark body and a small gleam. A droplet that has flown a while stretches up
-- to AGE_GAIN more and gets thinner. Only droplets wider than EDGE_SIZE get the film; only those wider than FLECK_SIZE
-- and nearer the camera than FLECK_NEAR get the gleam.
local DROP = { AGE_GAIN = 0.8, EDGE = 1.25, BODY = 0.72, FLECK_NEAR = 260, FLECK_SIZE = 2.0, EDGE_SIZE = 1.5 }

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
local STAIN_BASE, STAIN_PER_DAMAGE, STAIN_MAX, STAIN_DEATH = 9, 0.35, 28, 30
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
    red   = { droplet = { 0.62, 0.03, 0.03 }, mist = { 0.30, 0.01, 0.01 }, stain = { 0.42, 0.02, 0.02 },
              lens = { 0.55, 0.02, 0.02 }, gut = { 0.86, 0.52, 0.54 }, gutDark = { 0.52, 0.20, 0.24 } },
    green = { droplet = { 0.40, 0.80, 0.12 }, mist = { 0.18, 0.42, 0.05 }, stain = { 0.22, 0.48, 0.05 },
              lens = { 0.32, 0.68, 0.08 }, gut = { 0.66, 0.72, 0.42 }, gutDark = { 0.30, 0.38, 0.14 } },
}

local DROPLET, MIST = 1, 2
local MEL = {}                -- the weapon sprays and the hit classification, in one table to spare locals

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

local function sendEnabled(fx, on)
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
-- == Decals == 32 slots of splats (kind 1) and pools (kind 2), each on a surface of any orientation. A slot is two vec4
-- params, "dNa" = (x, y, z, bound) and "dNb" = (normal, flow, birth, size-and-kind), packed as stains.frag documents.
-- The Lua keeps the data and owns recycling: the one blood last landed in longest ago goes first (size counts for a little,
-- so that the slots keep the latest splats of every size and not the biggest few), and a speck does not push out a pool.
-- The shader dries a decal from its birth, p_clock being our own fxClock (it only runs while a match does). The same pass is
-- told where the living worms are ("w0".."w15", sendWorms), so that it keeps blood off them.
-- Everything is inside one do-block so the main chunk keeps its few free local-variable slots (Lua allows 200); what
-- the rest of the file uses is declared here and set below: updateStainEnable, clearStains, requestPool, placeStain,
-- and the DECALS table (update, resend, zero, cast, splat, rayOK, rayUsed).
local updateStainEnable, clearStains, requestPool, placeStain
local DECALS = { rayUsed = 0, rayOK = false, frame = 0, prevHeavy = 0, prevLight = 0, now = 0 }
do
local DS = { live = {}, x = {}, y = {}, z = {}, nx = {}, ny = {}, nz = {}, np = {}, r = {}, rt = {}, e = {}, phi = {},
             birth = {}, seed = {}, kind = {}, thick = {}, dirtyA = {}, dirtyB = {}, sentRq = {}, r0 = {}, t0 = {},
             -- the worms the shader keeps blood off (params "w0".."w15"): where each was last sent, and the frame it was last seen
             wx = {}, wy = {}, wz = {}, wlive = {}, wseen = {}, wtop = 0 }
local DEC_A, DEC_B, DEC_W = {}, {}, {}
for i = 1, SKIN_SLOTS do
    DEC_W[i] = "w" .. (i - 1)
    DS.wx[i], DS.wy[i], DS.wz[i], DS.wlive[i], DS.wseen[i] = 0, 0, 0, false, 0
end
for i = 1, STAIN_SLOTS do
    DEC_A[i], DEC_B[i] = "d" .. (i - 1) .. "a", "d" .. (i - 1) .. "b"
    DS.live[i], DS.dirtyA[i], DS.dirtyB[i], DS.sentRq[i] = false, false, false, -1
    for _, k in ipairs({ "x", "y", "z", "nx", "ny", "nz", "np", "r", "rt", "e", "phi", "birth", "seed", "kind", "thick", "r0", "t0" }) do
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
        local ts = rq * 16384 + (kind * 16 + DS.thick[i]) * 256 + DS.seed[i]
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
    return (0.3 + 2 * math.exp(-(fxClock - DS.birth[i]) / 25)) * (1 + 0.04 * min(DS.rt[i], 40)) * (DS.kind[i] == 2 and 1.6 or 1)
end

-- Puts a decal (kind 1 splat, 2 pool) with the blood landing at (hx, hy, hz) and its shape centred at (cx, cy, cz). A decal
-- of the same orientation that the blood lands in or beside takes it instead (and grows, and is wet again). The normal
-- must be a unit vector. Returns the slot or nil.
local function decalAdd(kind, hx, hy, hz, cx, cy, cz, nx, ny, nz, r, e, phi, thick)
    local qx, qy, qz, np = quantNormal(nx, ny, nz)
    local best, bestD, bestReach
    for i = 1, STAIN_SLOTS do
        -- A pool only joins a pool; a splat joins either.
        if DS.live[i] and (kind == 1 or DS.kind[i] == 2) and DS.nx[i] * qx + DS.ny[i] * qy + DS.nz[i] * qz > 0.85 then
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
        for i = 1, STAIN_SLOTS do
            if kind == 2 or fxClock - DS.t0[i] >= DEC.MIN_LIFE then
                local w = decalWeight(i)
                if not lowest or w < lowest then slot, lowest = i, w end
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
        if s.seen == frameId and s.alive and i >= 1 and i <= SKIN_SLOTS then
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

function placeStain(x, y, z, radius)
    requestPool(x, y, z, radius)
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
local CAM = { ok = false, px = 0, py = 0, pz = 0, rx = 0, ry = 0, rz = 0, ux = 0, uy = 0, uz = 0 }

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

-- Integrates and draws every live particle. Droplets are drops stretched along their velocity that turn to face the
-- camera; mist puffs are flat against the screen. With wum.game.landRay a droplet or clot that reaches the terrain is removed
-- and leaves a decal (see == Droplet collision ==).
local function simulate(dt)
    local px, py, pz, pvx, pvy, pvz = P.x, P.y, P.z, P.vx, P.vy, P.vz
    local psize, page, plife, pkind, pr, pg, pb, pa = P.size, P.age, P.life, P.kind, P.r, P.g, P.b, P.a
    local plx, ply, plz, pph, plt = P.lx, P.ly, P.lz, P.ph, P.lt
    local draw = CAM.ok
    local KP, KD, KG, KGROW, KFADE = MEL.KP, MEL.KD, MEL.KG, MEL.KGROW, MEL.KFADE
    local CLOTK = MEL.CLOT        -- heavy clots from the melee sprays collide like droplets; steam and char do not
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
                if mist then
                    local h = psize[i] * (0.5 + t * KGROW[kd]) * 0.5
                    local a = pa[i] * (1 - t) * (1 - t)
                    local fi = KFADE[kd]
                    if fi > 0 and t * fi < 1 then a = a * t * fi end
                    -- A square and the same square turned 45 degrees overlap into a soft-cornered puff.
                    corner(q1, x - (rx + ux) * h, y - (ry + uy) * h, z - (rz + uz) * h)
                    corner(q2, x + (rx - ux) * h, y + (ry - uy) * h, z + (rz - uz) * h)
                    corner(q3, x + (rx + ux) * h, y + (ry + uy) * h, z + (rz + uz) * h)
                    corner(q4, x + (ux - rx) * h, y + (uy - ry) * h, z + (uz - rz) * h)
                    emitQuad(pr[i], pg[i], pb[i], a)
                    local d = h * 1.2
                    corner(q1, x - ux * d, y - uy * d, z - uz * d)
                    corner(q2, x + rx * d, y + ry * d, z + rz * d)
                    corner(q3, x + ux * d, y + uy * d, z + uz * d)
                    corner(q4, x - rx * d, y - ry * d, z - rz * d)
                    emitQuad(pr[i], pg[i], pb[i], a)
                else
                    local sp = sqrt(vx * vx + vy * vy + vz * vz)
                    if sp > 1e-3 then
                        -- A droplet stretches with its speed, and one that has been flying a while stretches more
                        -- (and thins out, as a stretched drop does).
                        local size = psize[i]
                        local hl2 = min(max(sp * STREAK_SECONDS * (1 + DROP.AGE_GAIN * min(age, 1.2)), STREAK_MIN), STREAK_MAX)
                        local hl = hl2 * 0.5
                        local k = hl / sp
                        local ax, ay, az = vx * k, vy * k, vz * k
                        -- The short axis is perpendicular to both the streak and the line to the camera.
                        local tx, ty, tz = cpx - x, cpy - y, cpz - z
                        local sx, sy, sz = ay * tz - az * ty, az * tx - ax * tz, ax * ty - ay * tx
                        local sl = sqrt(sx * sx + sy * sy + sz * sz)
                        if sl > 1e-6 then
                            local thin = 1 / sqrt(max(1, hl2 / max(size, 0.5) * 0.35))
                            local w = size * 0.5 * thin / sl
                            sx, sy, sz = sx * w, sy * w, sz * w
                            local a = pa[i]
                            if t > FADE_START then a = a * (1 - t) / (1 - FADE_START) end
                            local r, g, b = pr[i], pg[i], pb[i]
                            -- A kite: a pointed tail behind, widest just short of the rounded head. First a wider,
                            -- lighter, thin film around it, then the dark body, then a gleam toward the light.
                            local hx, hy, hz = x + ax * 0.45, y + ay * 0.45, z + az * 0.45
                            if size >= DROP.EDGE_SIZE then
                                corner(q1, x - ax, y - ay, z - az)
                                corner(q2, hx + sx * 1.45, hy + sy * 1.45, hz + sz * 1.45)
                                corner(q3, x + ax * 1.08, y + ay * 1.08, z + az * 1.08)
                                corner(q4, hx - sx * 1.45, hy - sy * 1.45, hz - sz * 1.45)
                                emitQuad(min(1, r * DROP.EDGE), min(1, g * DROP.EDGE), min(1, b * DROP.EDGE), a * 0.4)
                            end
                            corner(q1, x - ax * 0.92, y - ay * 0.92, z - az * 0.92)
                            corner(q2, hx + sx, hy + sy, hz + sz)
                            corner(q3, x + ax, y + ay, z + az)
                            corner(q4, hx - sx, hy - sy, hz - sz)
                            emitQuad(r * DROP.BODY, g * DROP.BODY, b * DROP.BODY, a)
                            if size >= DROP.FLECK_SIZE and tx * tx + ty * ty + tz * tz < DROP.FLECK_NEAR * DROP.FLECK_NEAR then
                                -- The light is up and to the left of the camera: a small bright square near the head.
                                local fs = max(0.25, size * 0.17)
                                local fx = hx + (ux * 0.3 - rx * 0.25) * size * 0.4
                                local fy = hy + (uy * 0.3 - ry * 0.25) * size * 0.4
                                local fz = hz + (uz * 0.3 - rz * 0.25) * size * 0.4
                                corner(q1, fx - (rx + ux) * fs, fy - (ry + uy) * fs, fz - (rz + uz) * fs)
                                corner(q2, fx + (rx - ux) * fs, fy + (ry - uy) * fs, fz + (rz - uz) * fs)
                                corner(q3, fx + (rx + ux) * fs, fy + (ry + uy) * fs, fz + (rz + uz) * fs)
                                corner(q4, fx + (ux - rx) * fs, fy + (uy - ry) * fs, fz + (uz - rz) * fs)
                                emitQuad(1, 0.86, 0.84, a * 0.75)
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
local lensTex = {}
local LS = { x = {}, y = {}, size = {}, tex = {}, age = {}, life = {} }
local nL = 0
local tint = { r = 1, g = 1, b = 1, a = 1 }

local function loadLens()
    if not (wum.render and wum.render.windowSize and wum.draw.texture and wum.draw.hudImage) then return end
    for i = 1, 4 do
        local ok, tex = pcall(wum.draw.texture, "textures/splat" .. i .. ".png")
        if ok and tex then lensTex[#lensTex + 1] = tex end
    end
end

local function addSplat()
    if #lensTex == 0 then return end
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
    LS.tex[slot] = lensTex[random(#lensTex)]
    LS.age[slot] = 0
    LS.life[slot] = LENS_LIFE * rnd(0.85, 1.15)
end

local function ageSplats(dt)
    for i = nL, 1, -1 do
        local age = LS.age[i] + dt
        if age >= LS.life[i] then
            for _, arr in pairs(LS) do arr[i] = arr[nL] end
            nL = nL - 1
        else
            LS.age[i] = age
        end
    end
end

local function drawSplats()
    if nL == 0 or not preset or not cfg.lens then return end
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
        wum.draw.hudImage(cx - half, cy - half, cx + half, cy + half, LS.tex[i], tint)
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
        gore = 0, heading = 0,
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
    if not (cfg.lens and CAM.ok and preset and #lensTex > 0) then return end
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
        [STEAM] = { g = -0.4, drag = 1.3, puff = true, grow = 3.4, fade = 5 },
        [CHAR] = { g = 1, drag = 0.9, puff = false },
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
            local k = rnd(0.5, 1.2)
            r, g, b = (0.045 + c[1] * 0.18) * k, (0.045 + c[2] * 0.18) * k, (0.045 + c[3] * 0.18) * k
        elseif mode == 3 then
            local k = rnd(0.7, 1.1)
            r, g, b = (c[1] * 0.3 + 0.16) * k, (c[2] * 0.3 + 0.22) * k, (c[3] * 0.3 + 0.02) * k
        elseif mode == 4 then
            r, g, b = 1, rnd(0.35, 0.6), 0.08
        elseif mode == 5 then
            local k = rnd(0.62, 0.84)
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
        spawn(kind, x, y, z, vx, vy, vz, size, life, r, g, b, alpha or DROPLET_ALPHA)
    end

    local function drop(kind, mode, x, y, z, ex, ey, ez, speed, size, life)
        local r, g, b = colour(mode)
        spawn(kind, x, y, z, ex * speed, ey * speed, ez * speed, size, life, r, g, b, DROPLET_ALPHA)
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
                 rnd(p.l0, p.l1))
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
        n = min(n, poolRoom())
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
                                 rnd(p.l0, p.l1))
                        elseif jt == DRIB then
                            dropv(DROPLET, p.mode or 1, x + rnd(-1.5, 1.5), y + rnd(-1.5, 1.5), z + rnd(-1.5, 1.5),
                                  j.dx * rnd(6, 28) + rnd(-8, 8), rnd(-12, 8), j.dz * rnd(6, 28) + rnd(-8, 8),
                                  rnd(0.9, 1.7), rnd(0.6, 1.2))
                        else
                            local smoke = random() < 0.3
                            puff(STEAM, smoke and 6 or 5, x + rnd(-5, 5), y + rnd(-6, 8), z + rnd(-4, 4),
                                 rnd(-10, 10), rnd(30, 70), rnd(-10, 10), rnd(9, 16), rnd(0.9, 1.7), smoke and 0.5 or 0.4)
                            if random() < 0.25 then
                                drop(CHAR, 2, x + rnd(-4, 4), y + rnd(-4, 4), z + rnd(-3, 3), rnd(-0.5, 0.5), 1, rnd(-0.5, 0.5),
                                     rnd(40, 100), rnd(1.1, 2.0), rnd(0.5, 1.0))
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

    PR.FP_CHAR = { cone = 0.5, s0 = 150, s1 = 360, z0 = 1.1, z1 = 2.6, l0 = 0.8, l1 = 1.5, mode = 2, kind = CHAR }
    PR.FP_BLOOD = { cone = 0.5, s0 = 130, s1 = 300, z0 = 1.1, z1 = 2.2, l0 = 0.8, l1 = 1.4 }
    PR.FP_EMBER = { cone = 0.9, s0 = 60, s1 = 200, z0 = 1.2, z1 = 2.0, l0 = 0.4, l1 = 0.9, mode = 4, kind = CHAR }

    function F.sprayFire(s, damage, n, dx, dy, dz, cx, cy, cz)
        -- An uppercut: everything goes up, a little away from the attacker.
        local ux, uy, uz = tilt(dx * 0.4, 0, dz * 0.4, 1)
        local nChar, nBlood = floor(n * 0.6), floor(n * 0.2)
        jet(PR.FP_CHAR, cx, cy - 2, cz, ux, uy, uz, nChar)
        jet(PR.FP_BLOOD, cx, cy - 2, cz, ux, uy, uz, nBlood)
        local embers = 4 + floor(n / 14)
        jet(PR.FP_EMBER, cx, cy, cz, ux, uy, uz, embers)
        for _ = 1, min(3, poolRoom()) do
            puff(STEAM, 6, cx + rnd(-4, 4), cy + rnd(-4, 6), cz + rnd(-3, 3), rnd(-12, 12), rnd(40, 80), rnd(-12, 12),
                 rnd(12, 18), rnd(1.0, 1.6), 0.5)
        end
        addJob(STEAMJ, s, 0.05, 1.9, 11 * preset.bleed, cx, cy, cz, 0, 1, 0, nil)
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
        for _ = 1, min(preset.mist + 4, poolRoom()) do
            local a = random() * 2 * pi
            local sp = rnd(30, 70)
            puff(MIST, 7, cx + cos(a) * 4, gy + 3, cz + sin(a) * 4, cos(a) * sp, rnd(0, 15), sin(a) * sp,
                 rnd(MIST_SIZE[1], MIST_SIZE[2]) * 1.4, rnd(MIST_LIFE[1], MIST_LIFE[2]), MIST_ALPHA)
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
    if not (cfg.lens and CAM.ok and preset and #lensTex > 0) then return end
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
    local room = poolRoom()
    if room <= 0 then return end
    local cx, cy, cz = s.px, s.py + CENTRE_Y, s.pz
    local strength = min(damage, DEATH_DAMAGE) / DEATH_DAMAGE
    local spread = death and 1.1 or 0.55
    local count = min(BURST_MAX, floor((damage + BURST_BASE) * preset.perDamage + 0.5))
    -- No more than the frame has left to spawn, and no more than half of the room in the pool (FAIR_MIN at least), so the
    -- worms of one blast, which burst one after another, each get a share.
    count = min(count, BUDGET.SPAWN - BUDGET.spawned, max(BUDGET.FAIR_MIN, floor(room * 0.5)))
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
              rnd(DROPLET_SIZE[1], DROPLET_SIZE[2]), rnd(DROPLET_LIFE[1], DROPLET_LIFE[2]),
              min(1, c[1] * shade), min(1, c[2] * shade), min(1, c[3] * shade), DROPLET_ALPHA)
    end
    local m = palette.mist
    for _ = 1, min(floor((death and preset.mist * 2 or preset.mist) * gen + 0.5), poolRoom()) do
        local shade = rnd(0.8, 1.2)
        local speed = rnd(DROPLET_SPEED[1], DROPLET_SPEED[2]) * 0.25
        spawn(MIST, cx + rnd(-4, 4), cy + rnd(-4, 4), cz + rnd(-2, 2),
              (dx + rnd(-0.5, 0.5)) * speed, (dy + rnd(-0.5, 0.5)) * speed, (dz + rnd(-0.5, 0.5)) * speed,
              rnd(MIST_SIZE[1], MIST_SIZE[2]), rnd(MIST_LIFE[1], MIST_LIFE[2]),
              min(1, m[1] * shade), min(1, m[2] * shade), min(1, m[3] * shade), MIST_ALPHA)
    end
end

local function enqueueBurst(s, damage, dx, dy, dz, death, sig)
    if BQ.n >= BUDGET.QUEUE then return end        -- a storm of hits: the rest only bleed and stain
    local i = (BQ.head + BQ.n - 1) % BUDGET.QUEUE + 1
    BQ.n = BQ.n + 1
    BQ.s[i], BQ.dmg[i], BQ.dx[i], BQ.dy[i], BQ.dz[i], BQ.death[i], BQ.sig[i], BQ.at[i] = s, damage, dx, dy, dz, death, sig, now
    BQ.vslot[i], BQ.hasA[i], BQ.ax[i], BQ.ay[i], BQ.az[i], BQ.expl[i] = MEL.vslot, MEL.hasA, MEL.ax, MEL.ay, MEL.az, MEL.expl
end

-- Once a frame, before anything else bursts: the queued bursts go first, oldest first, while the frame has budget left.
local function drainBursts()
    while BQ.n > 0 do
        local i = BQ.head
        local stale = now - BQ.at[i] > BUDGET.QUEUE_SECS
        if not stale then
            if BUDGET.SPAWN - BUDGET.spawned < BUDGET.MIN_LEFT or poolRoom() <= 0 then break end
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
    if poolRoom() > 0 then
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
    end
    if death or damage >= STAIN_MIN_DAMAGE then
        requestStain(s, death and STAIN_DEATH or min(STAIN_MAX, STAIN_BASE + damage * STAIN_PER_DAMAGE))
    end
    VIS.spillGut(s, damage)
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

-- Scorch: a charred patch with glowing embers on a worm's skin, 0..1, fading to nothing over SCORCH_SECS. The melee
-- code calls setScorch(slot, amount) when a hit sets a worm alight; calling it again only raises the level.
local SCORCH_SECS = 4
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

-- woundSites(slot[, out]): fills out (a table the caller keeps and reuses; one is made when nil) with the open wound sites
-- of the worm in this slot, in world units: out[i] = { x, y, z, nx, ny, nz, open, gut }, where (x, y, z) is on the body,
-- (nx, ny, nz) is the outward unit normal, open is how open the wound is (0..1) and gut is true for the belly opening.
-- Returns n, out: the count (entries past n are stale) and the table. Returns 0, out for a slot that is not tracked or dead.
-- Cheap, and nothing calls it yet.
local function sitesOf(slot, out)
    out = out or {}
    local s = slots[slot]
    if not s or not s.alive then return 0, out end
    local n = 0
    local seed = VIS.seed + slot * 37
    local H = s.heading
    local ch, sh = cos(H), sin(H)
    local px, py, pz = s.px, s.py + CENTRE_Y, s.pz
    local function put(lx, ly, lz, open, gut)
        -- A local direction (the worm faces +Z) to the world: the inverse of the shader's rotation about Y.
        n = n + 1
        local e = out[n]
        if not e then
            e = {}
            out[n] = e
        end
        local wx, wz = lx * ch + lz * sh, -lx * sh + lz * ch
        local nx, ny, nz = lx / BODY_RX, ly / BODY_RY, lz / BODY_RX
        local nl = sqrt(nx * nx + ny * ny + nz * nz)
        if nl < 1e-6 then nl = 1 end
        local nwx, nwz = (nx * ch + nz * sh) / nl, (-nx * sh + nz * ch) / nl
        e.x, e.y, e.z = px + wx * BODY_RX, py + ly * BODY_RY, pz + wz * BODY_RX
        e.nx, e.ny, e.nz = nwx, ny / nl, nwz
        e.open, e.gut = open, gut
    end
    for k = 0, 4 do
        local o = (s.wound - k / 5) * 5
        if o > 0 then
            if o > 1 then o = 1 end
            local az, elev = siteDir(seed, k)
            local ce = cos(elev)
            put(cos(az) * ce, sin(elev), sin(az) * ce, o, false)
        end
    end
    if s.gut > 0 then
        local a = s.gutAz
        put(sin(a) * 0.917, -0.4, cos(a) * 0.917, min(1, 0.4 + s.gut * 0.6), true)
    end
    return n, out
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
    if s.alive and cfg.guts and cfg.skin ~= false and not SKIN.failed then
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
    local found = false
    for i = 1, #list do
        local e = list[i]
        if type(e) == "table" then
            if e.id == GUTS.id then
                found = true
                gutsMissing = e.failed == true
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
    if not (s.alive and cfg.vomit) then
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
                VIS.noteEngineVel(s, w.vel)
                updateMotion(s, x, y, z)
                MEL.track(s, slot, w)
                if s.alive and not alive then
                    local dx, dy, dz = hitDirection(s)
                    s.credited = 0
                    burst(s, DEATH_DAMAGE, dx, dy, dz, true)
                elseif alive and not s.alive then
                    resetSlot(s)
                elseif alive then
                    if health > s.health then
                        resetSlot(s)
                    elseif health < s.health then
                        settleHealth(s, s.health - health)
                    end
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
                if s.seen == frameId and s.alive then
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
        if s.seen ~= frameId then slots[slot] = nil end
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
    if abs(s.gore - skSentGore[i]) > GORE_RESEND or abs(wound - skSentWound[i]) > WOUND_RESEND
        or (wound == 0) ~= (skSentWound[i] == 0) or abs(s.heading - skSentHead[i]) > HEADING_RESEND then
        skSentGore[i], skSentWound[i], skSentHead[i] = s.gore, wound, s.heading
        sendParam(SKIN, WORM_B[i], s.gore, wound, s.heading)
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
            if s.seen == frameId and s.alive and (s.gore > 0 or s.wound > 0 or s.eye > 0 or s.gut > 0 or VIS.scorchLevel(slot + 1) > 0)
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
    -- A new match seed, so the wounds are not in the same places every match.
    matchSeed = random(0, 1000)
    sendSeed()
    live = false
end

-- ---------------------------------------------------------------- frame
local lastClock = nil

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
    frameId = frameId + 1
    BUDGET.spawned = 0
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
    MEL.tick(dt)
    simulate(dt)
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
    if lens ~= cfg.lens then
        cfg.lens = lens
        if not lens then nL = 0 end
    end
    if colour ~= cfg.colour then
        cfg.colour = colour
        palette = COLOURS[colour] or COLOURS.red
        local c = palette.stain
        sendParam(STAINS, "blood", c[1], c[2], c[3])
        sendParam(SKIN, "blood", c[1], c[2], c[3])
        VIS.setBlood(c)
    end
    if not preset then
        clearStains()
        clearSkin()
        VIS.reset()
    end
    updateStainEnable()
    -- Outside a match nothing drives the skin effect, so settle a persisted enabled=1 here instead of waiting for a frame.
    if skinCount == 0 then sendEnabled(SKIN, false) end
end

-- ---------------------------------------------------------------- events and preview
if wum.events and wum.events.on then
    wum.events.on("Explosion", function(p)
        if not preset or type(p) ~= "table" or nExp >= EXPLOSIONS_MAX then return end
        local x, y, z = vec(p.damageEpicentre)
        local damage, radius = tonumber(p.wormDamage), tonumber(p.wormDamageRadius)
        if not (x and damage and radius) or damage <= 0 or radius <= 0 then return end
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
end

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
