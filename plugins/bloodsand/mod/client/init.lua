-- Bloodsand: blood bursts when worms are hit, bleeding afterwards, blood and gaping wounds on the worms' skin,
-- blackened eyes and intestines on badly hurt worms, vomiting blood, stains on the ground and splatter on the lens.
--
-- It only reads game state (worm health, positions and facing, damage and explosion messages, the camera) and draws. It
-- never changes the simulation, sends anything or asks for a permission, so every player sees their own blood.
--
-- Droplets, mist and the dangling loop of intestines are world quads drawn from one "world" callback. The ground
-- decals are the bloodsand/stains post-FX effect (32 slots of splats and pools on any surface; a droplet that meets the
-- terrain, seen with wum.game.landRay where Melange has it, leaves one) and the blood, wounds, black eyes and the
-- intestines painted on a wound are bloodsand/skin (sixteen slots that follow the worms); both are fed with
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
local STAIN_MERGE = 7           -- blood landing this close to a live stain, or inside most of it, makes that one grow
local REST_SPEED = 40           -- slower than this a worm counts as at rest
local REST_SECS = 0.3
local PENDING_SECS = 8          -- a stain waiting for a thrown worm to land is dropped after this long

-- Droplet-vs-terrain collision (needs wum.game.landRay) and the decals a landing droplet leaves. Distances are world
-- units, times seconds.
local DEC = {
    SPLAT_MAX = 9,              -- the largest a splat grows to by absorbing blood that lands on it
    POOL_MAX = 40,
    BOUND = 1.55,               -- radius of the shader's bounding sphere, in splat radii times (1 + stretch)
    POOL_BOUND = 1.55,
    RUN = 2.8,                  -- a wall splat's drips may reach this many radii below it (bound only)
    SPREAD_POOL = 2.2,          -- a pool spreads to full size in about two seconds (rate of an exponential)
    SPREAD_SPLAT = 14,
    MIN_MERGE = 2.2,            -- blood landing this close to a live decal of the same orientation joins it
    NEW_PER_FRAME = 4,          -- new decals one frame may start; the rest of the hits only grow what is there
    SENDS_PER_FRAME = 12,       -- slot sends (two setTransient calls at most each) one frame may make
    HIT_SCALE = 1.15,           -- splat radius per unit of droplet size
    -- Terrain rays per frame (Melange allows about 64): droplets get RAY_BUDGET, pools may go over a little. Heavy
    -- droplets (wider than HEAVY_SIZE or faster than HEAVY_SPEED) are tested first and share HEAVY_RAYS of them; the
    -- rest take turns, no droplet waiting more than STRIDE_MAX frames. A droplet of SPLIT_SIZE or more breaks up.
    RAY_BUDGET = 56, HEAVY_RAYS = 36, HEAVY_SIZE = 1.9, HEAVY_SPEED = 170, SPLIT_SIZE = 2.1, STRIDE_MAX = 12,
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

-- Intestines: a worm with a wound level above GUT.START may have a loop hanging from its belly, painted by the shader
-- and drawn as a chain of ribbons here. All to be tuned in game.
local GUT = {
    RESEND = 0.02,
    CHANCE = 0.4,                   -- the share of worms that can show guts at all
    START = 0.6,                    -- the wound level where the gut starts to show; the level is 1 at wound level 1
    AZ = 0.9,                       -- the gut's side is random within this many radians of the facing
    Y = 5.5,                        -- height of the belly above the feet
    OUT = 5.6,                      -- distance of the anchors from the worm's vertical axis
    SPREAD = 0.6,                   -- radians between the two anchors
    DROP = 1.5,                     -- the second anchor sits this much lower
    POINTS = 7,
    SEG = { 1.3, 2.6 },             -- segment rest length at gut level 0 and 1
    WIDTH = 2.2,
    CORE = 0.6,                     -- the light core's width as a fraction of the width
    EXTEND = 1.15,                  -- each ribbon runs this much beyond its segment so neighbours overlap
    GRAVITY = -260,
    DAMP = 0.92,                    -- velocity kept per step at 60 Hz
    ITER = 4,
    JUMP = 60,                      -- the worm moving further than this in a frame was teleported: the loop starts over
}

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
-- The Lua keeps the data and owns recycling: oldest and smallest go first, and a speck never evicts a big blot. The
-- shader dries a decal from its birth, p_clock being our own fxClock (it only runs while a match does).
-- Everything is inside one do-block so the main chunk keeps its few free local-variable slots (Lua allows 200); what
-- the rest of the file uses is declared here and set below: updateStainEnable, clearStains, requestPool, placeStain,
-- and the DECALS table (update, resend, zero, cast, splat, rayOK, rayUsed).
local updateStainEnable, clearStains, requestPool, placeStain
local DECALS = { rayUsed = 0, rayOK = false, frame = 0, prevHeavy = 0, prevLight = 0 }
do
local DS = { live = {}, x = {}, y = {}, z = {}, nx = {}, ny = {}, nz = {}, np = {}, r = {}, rt = {}, e = {}, phi = {},
             birth = {}, seed = {}, kind = {}, thick = {}, dirtyA = {}, dirtyB = {}, sentRq = {} }
local DEC_A, DEC_B = {}, {}
for i = 1, STAIN_SLOTS do
    DEC_A[i], DEC_B[i] = "d" .. (i - 1) .. "a", "d" .. (i - 1) .. "b"
    DS.live[i], DS.dirtyA[i], DS.dirtyB[i], DS.sentRq[i] = false, false, false, -1
    for _, k in ipairs({ "x", "y", "z", "nx", "ny", "nz", "np", "r", "rt", "e", "phi", "birth", "seed", "kind", "thick" }) do
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

function clearStains()
    for i = 1, STAIN_SLOTS do
        DS.live[i], DS.dirtyA[i], DS.dirtyB[i], DS.sentRq[i] = false, false, false, -1
        sendVec4(STAINS, DEC_A[i], 0, 0, 0, 0)
        sendVec4(STAINS, DEC_B[i], 0, 0, 0, 0)
    end
    decCount = 0
    sendParam(STAINS, "count", 0)
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

-- What a slot is worth keeping: big and fresh blood stays.
local function decalWeight(i)
    return DS.rt[i] * (1 + 4 * math.exp(-(fxClock - DS.birth[i]) / 60))
end

-- Puts a decal (kind 1 splat, 2 pool) with the blood landing at (hx, hy, hz) and its shape centred at (cx, cy, cz). A decal
-- of the same orientation that the blood lands in or beside takes it instead (and grows, and is wet again). The normal
-- must be a unit vector. Returns the slot or nil.
local function decalAdd(kind, hx, hy, hz, cx, cy, cz, nx, ny, nz, r, e, phi, thick)
    local qx, qy, qz, np = quantNormal(nx, ny, nz)
    local best, bestD
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
                local reach = max(rt * 0.8 * (1 + 0.3 * DS.e[i]), DEC.MIN_MERGE)
                if d2 < reach * reach and (not bestD or d2 < bestD) then best, bestD = i, d2 end
            end
        end
    end
    if best then
        local i = best
        local rt = DS.rt[i]
        local cap = DS.kind[i] == 2 and DEC.POOL_MAX or DEC.SPLAT_MAX
        local grown = min(cap, sqrt(rt * rt + r * r * (DS.kind[i] == 2 and 0.25 or 0.35)))
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
            local w = decalWeight(i)
            if not lowest or w < lowest then slot, lowest = i, w end
        end
        -- A speck does not push out anything that is worth more than it.
        if r * 5 < lowest * 0.6 then return nil end
    else
        decCount = decCount + 1
    end
    decNew = decNew + 1
    DS.live[slot] = true
    DS.x[slot], DS.y[slot], DS.z[slot] = cx, cy, cz
    DS.nx[slot], DS.ny[slot], DS.nz[slot], DS.np[slot] = qx, qy, qz, np
    DS.rt[slot], DS.e[slot], DS.phi[slot], DS.kind[slot], DS.thick[slot] = r, e, phi, kind, thick
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
    local r = size * DEC.HIT_SCALE * (1 + 0.5 * min(vn, 300) / 300)
    local e, phi = 0, 0
    local fx, fy, fz = 0, 0, 0
    if ts > 2 then
        local qx, qy, qz = quantNormal(nx, ny, nz)
        local tx, ty, tz, bx, by, bz = tangentFrame(qx, qy, qz)
        e = max(0, min(3.5, ts / max(vn, 10) * 0.55 - 0.1)) + (wall and 0.4 or 0)
        local u, v = (tvx * tx + tvy * ty + tvz * tz) / ts, (tvx * bx + tvy * by + tvz * bz) / ts
        phi = math.atan(v, u) % (2 * pi)
        fx, fy, fz = (tx * u + bx * v) * r * e, (ty * u + by * v) * r * e, (tz * u + bz * v) * r * e
    end
    local thick = min(15, max(4, floor(size * 3.5 + 2)))
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

function DECALS.update(dt)
    fxClock = fxClock + dt
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

-- Sends everything again, for the insurance resend: every slot, empty ones as zeros.
function DECALS.resend()
    for i = 1, STAIN_SLOTS do
        DS.dirtyA[i], DS.dirtyB[i] = true, true
        decalSend(i)
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
end

-- The terrain ray. wum.game.landRay is new in Melange 0.6; without it (or when it says it is unavailable) droplets fly on
-- through the ground as they always did and pools sit at the height they are asked for.
local landRay = wum.game.landRay
DECALS.rayOK = type(landRay) == "function"

-- Returns t (0..1 along the segment) and the unit normal of the hit, or nil.
local function castRay(x0, y0, z0, x1, y1, z1)
    DECALS.rayUsed = DECALS.rayUsed + 1
    local ok, t, nx, ny, nz = pcall(landRay, x0, y0, z0, x1, y1, z1)
    if not ok then
        DECALS.rayOK = false
        return nil
    end
    if t == nil then
        if nx == "unavailable" then DECALS.rayOK = false end
        return nil
    end
    if type(t) ~= "number" or type(nx) ~= "number" or type(ny) ~= "number" or type(nz) ~= "number" then return nil end
    local l = sqrt(nx * nx + ny * ny + nz * nz)
    if l < 1e-6 then return nil end
    return t, nx / l, ny / l, nz / l
end

-- A pool of blood under (x, y, z), size being its radius: it lies on the ground below the point (found with a ray when
-- the terrain can be asked, otherwise at the given height, facing up) and spreads over about two seconds.
function requestPool(x, y, z, size)
    if not (hasPostfx and preset and cfg.stains) then return end
    local px, py, pz, nx, ny, nz = x, y, z, 0, 1, 0
    if DECALS.rayOK then
        local t, hx, hy, hz = castRay(x, y + 14, z, x, y - 36, z)
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
-- == Collision state == per droplet: the point its last terrain ray started from and a phase that staggers its rays.
-- spawn does not set them: simulate does on a particle's first step (its age is still 0 then).
P.lx, P.ly, P.lz, P.ph = {}, {}, {}, {}
for _, arr in ipairs({ P.lx, P.ly, P.lz, P.ph }) do PARTS[#PARTS + 1] = arr end
local nP = 0
for _, arr in ipairs(PARTS) do
    for i = 1, POOL_MAX do arr[i] = 0 end
end

local function spawn(kind, x, y, z, vx, vy, vz, size, life, r, g, b, a)
    if not preset or nP >= preset.max or nP >= POOL_MAX then return end
    nP = nP + 1
    local i = nP
    P.x[i], P.y[i], P.z[i] = x, y, z
    P.vx[i], P.vy[i], P.vz[i] = vx, vy, vz
    P.size[i], P.age[i], P.life[i], P.kind[i] = size, 0, life, kind
    P.r[i], P.g[i], P.b[i], P.a[i] = r, g, b, a
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
-- camera; mist puffs are flat against the screen. With wum.game.landRay a droplet that reaches the terrain is removed
-- and leaves a decal (see == Droplet collision ==).
local function simulate(dt)
    local drag = max(0, 1 - DRAG * dt)
    local mdrag = max(0, 1 - MIST_DRAG * dt)
    local px, py, pz, pvx, pvy, pvz = P.x, P.y, P.z, P.vx, P.vy, P.vz
    local psize, page, plife, pkind, pr, pg, pb, pa = P.size, P.age, P.life, P.kind, P.r, P.g, P.b, P.a
    local plx, ply, plz, pph = P.lx, P.ly, P.lz, P.ph
    local draw = CAM.ok
    local cpx, cpy, cpz = CAM.px, CAM.py, CAM.pz
    local rx, ry, rz, ux, uy, uz = CAM.rx, CAM.ry, CAM.rz, CAM.ux, CAM.uy, CAM.uz
    -- == Droplet collision == rays are spent on heavy and fast droplets first; the rest take turns, each droplet
    -- being swept from where it was last tested, so a droplet that waits a few frames still cannot pass through.
    local frame = DECALS.frame + 1
    DECALS.frame = frame
    DECALS.rayUsed = 0
    local collide = DECALS.rayOK and hasPostfx and preset ~= nil and cfg.stains and true or false
    local ceil, castRay, decalSplat = math.ceil, DECALS.cast, DECALS.splat
    local strideH = max(1, min(DEC.STRIDE_MAX, ceil(DECALS.prevHeavy / DEC.HEAVY_RAYS)))
    local strideL = max(1, min(DEC.STRIDE_MAX, ceil(DECALS.prevLight / max(1, DEC.RAY_BUDGET - DEC.HEAVY_RAYS))))
    local nHeavy, nLight = 0, 0
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
            local mist = pkind[i] == MIST
            if mist then
                vx, vy, vz = vx * mdrag, vy * mdrag + GRAVITY * MIST_GRAVITY * dt, vz * mdrag
            else
                vx, vy, vz = vx * drag, vy * drag + GRAVITY * dt, vz * drag
            end
            pvx[i], pvy[i], pvz[i] = vx, vy, vz
            local ox, oy, oz = px[i], py[i], pz[i]
            local x, y, z = ox + vx * dt, oy + vy * dt, oz + vz * dt
            px[i], py[i], pz[i] = x, y, z
            local hit = false
            if collide and pkind[i] == DROPLET then
                if first then
                    plx[i], ply[i], plz[i], pph[i] = ox, oy, oz, random(0, 255)
                end
                local size = psize[i]
                local heavy = size >= DEC.HEAVY_SIZE or vx * vx + vy * vy + vz * vz >= heavySpeed2
                if heavy then nHeavy = nHeavy + 1 else nLight = nLight + 1 end
                local stride = heavy and strideH or strideL
                if DECALS.rayUsed < DEC.RAY_BUDGET and (stride == 1 or (frame + pph[i]) % stride == 0) then
                    local sx, sy, sz = plx[i], ply[i], plz[i]
                    local dx, dy, dz = x - sx, y - sy, z - sz
                    -- A stale start (a stride of many frames, or a droplet that was not tracked) is not trusted far.
                    if dx * dx + dy * dy + dz * dz > 40 * 40 then
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
                    else
                        plx[i], ply[i], plz[i] = x, y, z
                    end
                end
            end
            if draw and not hit then
                local t = age / life
                if mist then
                    local h = psize[i] * (0.5 + t) * 0.5
                    local a = pa[i] * (1 - t) * (1 - t)
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
        credited = 0, creditAt = -100, shownAt = -100,
        bleedUntil = 0, bleedRate = 0, bleedAcc = 0,
        stainRadius = nil, stainAt = 0, restSince = nil,
        gore = 0, heading = 0,
        hmax = health, wound = 0, previewWound = 0,
        frac = 1, eye = 0, eyeShow = 0, previewEyes = 0,
        -- The gut is rolled once per slot, so once per match: whether this worm can show one and on which side.
        hasGut = random() < GUT.CHANCE, gutAz = rnd(-GUT.AZ, GUT.AZ), gut = 0, previewGut = 0,
        gutLive = false, gutPx = x, gutPy = y, gutPz = z,
        gx = {}, gy = {}, gz = {}, hx = {}, hy = {}, hz = {},       -- the chain's points and their previous positions
        vomitAt = nil, vomitStart = 0, vomitUntil = 0, vomitAcc = 0, -- vomitUntil is 0 when no heave is going on
    }
    for i = 1, GUT.POINTS do
        s.gx[i], s.gy[i], s.gz[i], s.hx[i], s.hy[i], s.hz[i] = 0, 0, 0, 0, 0, 0
    end
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

-- A burst of blood at a worm's body. (dx, dy, dz) is the direction the blood goes, in any length.
local function burst(s, damage, dx, dy, dz, death)
    if not preset then return end
    local len = sqrt(dx * dx + dy * dy + dz * dz)
    if len < 1e-4 then
        dx, dy, dz, len = 0, 1, 0, 1
    end
    dx, dy, dz = dx / len, dy / len, dz / len
    local cx, cy, cz = s.px, s.py + CENTRE_Y, s.pz
    local strength = min(damage, DEATH_DAMAGE) / DEATH_DAMAGE
    local spread = death and 1.1 or 0.55
    local count = min(BURST_MAX, floor((damage + BURST_BASE) * preset.perDamage + 0.5))
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
    for _ = 1, death and preset.mist * 2 or preset.mist do
        local shade = rnd(0.8, 1.2)
        local speed = rnd(DROPLET_SPEED[1], DROPLET_SPEED[2]) * 0.25
        spawn(MIST, cx + rnd(-4, 4), cy + rnd(-4, 4), cz + rnd(-2, 2),
              (dx + rnd(-0.5, 0.5)) * speed, (dy + rnd(-0.5, 0.5)) * speed, (dz + rnd(-0.5, 0.5)) * speed,
              rnd(MIST_SIZE[1], MIST_SIZE[2]), rnd(MIST_LIFE[1], MIST_LIFE[2]),
              min(1, m[1] * shade), min(1, m[2] * shade), min(1, m[3] * shade), MIST_ALPHA)
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

-- The gut level, and the loop of intestines that hangs from the belly: a Verlet chain pinned at both ends to anchors on
-- the worm, kept outside the worm's body and above the ground.
local function updateGut(s, dt)
    local level = 0
    if s.alive and cfg.guts then
        if s.hasGut and s.wound > GUT.START then level = min(1, (s.wound - GUT.START) / (1 - GUT.START)) end
        if s.previewGut > level then level = s.previewGut end
    end
    s.gut = level
    if level <= 0 then
        s.gutLive = false
        return
    end
    local px, py, pz = s.px, s.py, s.pz
    local h = s.heading + s.gutAz
    local ha, hb = h - GUT.SPREAD * 0.5, h + GUT.SPREAD * 0.5
    local ax, ay, az = px + GUT.OUT * sin(ha), py + GUT.Y, pz + GUT.OUT * cos(ha)
    local bx, by, bz = px + GUT.OUT * sin(hb), py + GUT.Y - GUT.DROP, pz + GUT.OUT * cos(hb)
    local gx, gy, gz, hx, hy, hz = s.gx, s.gy, s.gz, s.hx, s.hy, s.hz
    local n = GUT.POINTS
    local jx, jy, jz = px - s.gutPx, py - s.gutPy, pz - s.gutPz
    s.gutPx, s.gutPy, s.gutPz = px, py, pz
    if not s.gutLive or jx * jx + jy * jy + jz * jz > GUT.JUMP * GUT.JUMP then
        -- Starts as a straight line between the anchors, at rest.
        for i = 1, n do
            local f = (i - 1) / (n - 1)
            local x, y, z = ax + (bx - ax) * f, ay + (by - ay) * f, az + (bz - az) * f
            gx[i], gy[i], gz[i], hx[i], hy[i], hz[i] = x, y, z, x, y, z
        end
        s.gutLive = true
        return
    end
    gx[1], gy[1], gz[1], gx[n], gy[n], gz[n] = ax, ay, az, bx, by, bz
    local damp = GUT.DAMP ^ (dt * 60)
    local fall = GUT.GRAVITY * dt * dt
    for i = 2, n - 1 do
        local x, y, z = gx[i], gy[i], gz[i]
        gx[i], gy[i], gz[i] = x + (x - hx[i]) * damp, y + (y - hy[i]) * damp + fall, z + (z - hz[i]) * damp
        hx[i], hy[i], hz[i] = x, y, z
    end
    local rest = GUT.SEG[1] + (GUT.SEG[2] - GUT.SEG[1]) * level
    for _ = 1, GUT.ITER do
        for i = 1, n - 1 do
            local j = i + 1
            local dx, dy, dz = gx[j] - gx[i], gy[j] - gy[i], gz[j] - gz[i]
            local d = sqrt(dx * dx + dy * dy + dz * dz)
            if d > 1e-6 then
                -- The pinned end points do not move, so the free neighbour takes the whole correction.
                local wa, wb = i == 1 and 0 or 1, j == n and 0 or 1
                local tot = wa + wb
                if tot > 0 then
                    local k = (d - rest) / d / tot
                    gx[i], gy[i], gz[i] = gx[i] + dx * k * wa, gy[i] + dy * k * wa, gz[i] + dz * k * wa
                    gx[j], gy[j], gz[j] = gx[j] - dx * k * wb, gy[j] - dy * k * wb, gz[j] - dz * k * wb
                end
            end
        end
    end
    local floorY = py + FEET_Y + 0.4
    local sh, ch = sin(h), cos(h)
    for i = 2, n - 1 do
        local dx, dz = gx[i] - px, gz[i] - pz
        local r2 = dx * dx + dz * dz
        if r2 < GUT.OUT * GUT.OUT then
            local r = sqrt(r2)
            if r > 1e-4 then
                gx[i], gz[i] = px + dx / r * GUT.OUT, pz + dz / r * GUT.OUT
            else
                gx[i], gz[i] = px + sh * GUT.OUT, pz + ch * GUT.OUT
            end
        end
        if gy[i] < floorY then gy[i] = floorY end
    end
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

-- The gut ribbons: two camera-facing rectangles per segment, laid like the droplet kite but with square ends. Each is
-- drawn a little longer than its segment so neighbours overlap.
local function drawRibbons(s, width, col)
    local gx, gy, gz = s.gx, s.gy, s.gz
    local r, g, b = col[1], col[2], col[3]
    local half = width * 0.5
    for i = 1, GUT.POINTS - 1 do
        local x1, y1, z1, x2, y2, z2 = gx[i], gy[i], gz[i], gx[i + 1], gy[i + 1], gz[i + 1]
        local mx, my, mz = (x1 + x2) * 0.5, (y1 + y2) * 0.5, (z1 + z2) * 0.5
        local k = 0.5 * GUT.EXTEND
        local ax, ay, az = (x2 - x1) * k, (y2 - y1) * k, (z2 - z1) * k
        local tx, ty, tz = CAM.px - mx, CAM.py - my, CAM.pz - mz
        local sx, sy, sz = ay * tz - az * ty, az * tx - ax * tz, ax * ty - ay * tx
        local sl = sqrt(sx * sx + sy * sy + sz * sz)
        if sl > 1e-6 then
            local w = half / sl
            sx, sy, sz = sx * w, sy * w, sz * w
            corner(q1, mx - ax - sx, my - ay - sy, mz - az - sz)
            corner(q2, mx - ax + sx, my - ay + sy, mz - az + sz)
            corner(q3, mx + ax + sx, my + ay + sy, mz + az + sz)
            corner(q4, mx + ax - sx, my + ay - sy, mz + az - sz)
            emitQuad(r, g, b, 1)
        end
    end
end

-- Draws every dangling gut. A worm's dark edges all go down before its light cores, so no core is covered by the edge
-- of the next segment.
local function drawGuts()
    if not CAM.ok then return end
    for _, s in pairs(slots) do
        if s.gutLive and s.seen == frameId and s.alive then
            drawRibbons(s, GUT.WIDTH, palette.gutDark)
            drawRibbons(s, GUT.WIDTH * GUT.CORE, palette.gut)
        end
    end
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
                updateMotion(s, x, y, z)
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
            for _, s in pairs(slots) do
                if s.seen == frameId and s.alive then
                    local dx, dy, dz = s.px - ex, s.py + CENTRE_Y - ey, s.pz - ez
                    local d = sqrt(dx * dx + dy * dy + dz * dz)
                    if d <= radius + BODY_MARGIN then
                        local est = max(1, damage * (1 - min(max(0, d - BODY_MARGIN) / radius, 1)))
                        if d < 1e-3 then dx, dy, dz, d = 0, 1, 0, 1 end
                        if DEBUG then wum.log.debug("explosion hit", est, d) end
                        credit(s, est)
                        burst(s, est, dx / d, dy / d + 0.35, dz / d)
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
        for _, s in pairs(slots) do
            if s.seen == frameId and s.alive and now - s.iat <= IMPULSE_WINDOW then
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
    sendParam(SKIN, "seed", matchSeed)
end

local function clearSkin()
    for i = 1, SKIN_SLOTS do
        sendParam(SKIN, WORM_B[i], 0, 0, 0)
        sendParam(SKIN, WORM_C[i], 0, 0, 0)
        skSentGore[i], skSentWound[i], skSentHead[i], skSentEyes[i], skSentGut[i] = 0, 0, 0, 0, 0
    end
    skinCount = 0
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
            if s.seen == frameId and s.alive and (s.gore > 0 or s.wound > 0 or s.eye > 0 or s.gut > 0)
                and slot >= 0 and slot < SKIN_SLOTS then
                driveSkin(slot, s)
            end
        end
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
    hurtOpen = false
end

-- Everything back to nothing: the match ended or started, or the amount was turned off.
local function resetAll()
    slots = {}
    clearParticles()
    clearStains()
    clearSkin()
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
    readCamera()
    local worms = wum.game.worms()
    if type(worms) == "table" then
        trackWorms(worms, dt)
    else
        nExp = 0
    end
    updateSkin()
    simulate(dt)
    DECALS.update(dt)
    drawGuts()
    ageSplats(dt)
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
    end
    if not preset then
        clearStains()
        clearSkin()
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
    local dx, dy, dz = rnd(-0.6, 0.6), 1, rnd(-0.3, 0.3)
    burst(s, 40, dx, dy, dz)
    -- Wounds too, so they can be seen: a level that decays back to what the worm's health gives.
    s.previewWound = PREVIEW_WOUND
    s.wound = max(s.wound, PREVIEW_WOUND)
    s.previewEyes, s.previewGut = 1, 1
    if cfg.vomit then startHeave(s) end
end

-- ---------------------------------------------------------------- start
-- Melange keeps a transient value across an effect reload unless the reload removes the param or changes its size, so
-- this is only insurance: everything live is sent again from time to time, zeros included for the slots that are not in
-- use, in case an effect was reloaded with a changed parameter list or a value was lost some other way.
local function resend()
    if not hasPostfx then return end
    STAINS.cache, SKIN.cache = {}, {}
    DECALS.resend()
    for i = 1, SKIN_SLOTS do
        if skFrame[i] == frameId and (skSentGore[i] > 0 or skSentWound[i] > 0 or skSentEyes[i] > 0 or skSentGut[i] > 0) then
            -- The centre goes out at the next frame, which finds the cache empty; the amounts are forced here.
            skSentGore[i], skSentWound[i], skSentEyes[i], skSentGut[i] = -1, -1, -1, -1
        else
            sendParam(SKIN, WORM_A[i], 0, 0, 0)
            sendParam(SKIN, WORM_B[i], 0, 0, 0)
            sendParam(SKIN, WORM_C[i], 0, 0, 0)
        end
    end
    local c = palette.stain
    sendParam(STAINS, "blood", c[1], c[2], c[3])
    sendParam(SKIN, "blood", c[1], c[2], c[3])
    sendSeed()
end

-- Every slot of both effects starts at zero, whatever Melange saved in an earlier session.
local function zeroAll()
    DECALS.zero()
    for i = 1, SKIN_SLOTS do
        sendParam(SKIN, WORM_A[i], 0, 0, 0)
        sendParam(SKIN, WORM_B[i], 0, 0, 0)
        sendParam(SKIN, WORM_C[i], 0, 0, 0)
    end
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
wum.timers.every(RESEND_SECS, resend)
