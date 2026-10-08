-- Bloodsand: blood bursts when worms are hit, bleeding afterwards, blood and gaping wounds on the worms' skin,
-- blackened eyes and intestines on badly hurt worms, vomiting blood, stains on the ground and splatter on the lens.
--
-- It only reads game state (worm health, positions and facing, damage and explosion messages, the camera) and draws. It
-- never changes the simulation, sends anything or asks for a permission, so every player sees their own blood.
--
-- Droplets and mist are world quads drawn from one "world" callback. The ground stains are the bloodsand/stains post-FX
-- effect (eight slots), the blood, wounds, black eyes, scorching and the torn belly painted on a worm are bloodsand/skin
-- (sixteen slots that follow the worms) and the intestines that hang out of a torn belly are bloodsand/guts (up to four
-- worms), a chain simulated here and ray-marched there; all three are fed with wum.postfx.setTransient, which writes
-- nothing to Melange.ini. The lens splats are textures drawn at the "hud" stage.

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
local STREAK_MIN, STREAK_MAX = 3.5, 16  -- ...within these limits

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

-- Ground stains.
local STAIN_SLOTS = 8
local STAIN_BASE, STAIN_PER_DAMAGE, STAIN_MAX, STAIN_DEATH = 9, 0.35, 28, 30
local STAIN_MIN_DAMAGE = 2      -- lighter hits leave nothing on the ground
local STAIN_MERGE = 7           -- blood landing this close to a live stain, or inside most of it, makes that one grow
local REST_SPEED = 40           -- slower than this a worm counts as at rest
local REST_SECS = 0.3
local PENDING_SECS = 8          -- a stain waiting for a thrown worm to land is dropped after this long

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

local NAME_A, NAME_B = {}, {}
for i = 1, STAIN_SLOTS do
    NAME_A[i] = "stain" .. (i - 1)
    NAME_B[i] = "stain" .. (i - 1) .. "b"
end
-- Worm slots are numbered from 0, so slot n is at index n + 1.
local WORM_A, WORM_B, WORM_C = {}, {}, {}
for i = 1, SKIN_SLOTS do
    WORM_A[i] = "worm" .. (i - 1)
    WORM_B[i] = "worm" .. (i - 1) .. "b"
    WORM_C[i] = "worm" .. (i - 1) .. "c"
end

-- ---------------------------------------------------------------- ground stains
local stX, stY, stZ, stR, stSeed, stLive = {}, {}, {}, {}, {}, {}
local stNext = 1

local function updateStainEnable()
    local live = false
    for i = 1, STAIN_SLOTS do
        if stLive[i] then live = true end
    end
    sendEnabled(STAINS, live and preset ~= nil and cfg.stains ~= false)
end

local function clearStains()
    for i = 1, STAIN_SLOTS do
        stLive[i] = false
        sendParam(STAINS, NAME_B[i], 0, 0, 0)
    end
    updateStainEnable()
end

local function placeStain(x, y, z, radius)
    if not (hasPostfx and preset and cfg.stains) then return end
    for i = 1, STAIN_SLOTS do
        if stLive[i] and abs(stY[i] - y) < STAIN_MERGE then
            local dx, dz = stX[i] - x, stZ[i] - z
            local reach = max(STAIN_MERGE, stR[i] * 0.7)
            if dx * dx + dz * dz < reach * reach then
                -- Blood on blood: the stain already there grows a little and keeps its shape.
                local grown = min(STAIN_DEATH, sqrt(stR[i] * stR[i] + radius * radius * 0.5))
                if grown > stR[i] * 1.08 then
                    stR[i] = grown
                    sendParam(STAINS, NAME_B[i], grown, stSeed[i], 1)
                end
                return
            end
        end
    end
    local slot = stNext
    stNext = stNext % STAIN_SLOTS + 1
    stX[slot], stY[slot], stZ[slot], stR[slot], stSeed[slot], stLive[slot] = x, y, z, radius, floor(random() * 1000), true
    sendParam(STAINS, NAME_A[slot], x, y, z)
    sendParam(STAINS, NAME_B[slot], radius, stSeed[slot], 1)
    updateStainEnable()
end

-- ---------------------------------------------------------------- particles
local P = { x = {}, y = {}, z = {}, vx = {}, vy = {}, vz = {}, size = {}, age = {}, life = {}, kind = {},
            r = {}, g = {}, b = {}, a = {} }
local PARTS = { P.x, P.y, P.z, P.vx, P.vy, P.vz, P.size, P.age, P.life, P.kind, P.r, P.g, P.b, P.a }
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
-- camera; mist puffs are flat against the screen.
local function simulate(dt)
    local drag = max(0, 1 - DRAG * dt)
    local mdrag = max(0, 1 - MIST_DRAG * dt)
    local px, py, pz, pvx, pvy, pvz = P.x, P.y, P.z, P.vx, P.vy, P.vz
    local psize, page, plife, pkind, pr, pg, pb, pa = P.size, P.age, P.life, P.kind, P.r, P.g, P.b, P.a
    local draw = CAM.ok
    local cpx, cpy, cpz = CAM.px, CAM.py, CAM.pz
    local rx, ry, rz, ux, uy, uz = CAM.rx, CAM.ry, CAM.rz, CAM.ux, CAM.uy, CAM.uz
    for i = nP, 1, -1 do
        local age = page[i] + dt
        local life = plife[i]
        if age >= life then
            removeParticle(i)
        else
            page[i] = age
            local vx, vy, vz = pvx[i], pvy[i], pvz[i]
            local mist = pkind[i] == MIST
            if mist then
                vx, vy, vz = vx * mdrag, vy * mdrag + GRAVITY * MIST_GRAVITY * dt, vz * mdrag
            else
                vx, vy, vz = vx * drag, vy * drag + GRAVITY * dt, vz * drag
            end
            pvx[i], pvy[i], pvz[i] = vx, vy, vz
            local x, y, z = px[i] + vx * dt, py[i] + vy * dt, pz[i] + vz * dt
            px[i], py[i], pz[i] = x, y, z
            if draw then
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
                        local hl = min(max(sp * STREAK_SECONDS, STREAK_MIN), STREAK_MAX) * 0.5
                        local k = hl / sp
                        local ax, ay, az = vx * k, vy * k, vz * k
                        -- The short axis is perpendicular to both the streak and the line to the camera.
                        local tx, ty, tz = cpx - x, cpy - y, cpz - z
                        local sx, sy, sz = ay * tz - az * ty, az * tx - ax * tz, ax * ty - ay * tx
                        local sl = sqrt(sx * sx + sy * sy + sz * sz)
                        if sl > 1e-6 then
                            local w = psize[i] * 0.5 / sl
                            sx, sy, sz = sx * w, sy * w, sz * w
                            -- A kite: a pointed tail behind, widest just short of the rounded head.
                            local hx, hy, hz = x + ax * 0.45, y + ay * 0.45, z + az * 0.45
                            corner(q1, x - ax, y - ay, z - az)
                            corner(q2, hx + sx, hy + sy, hz + sz)
                            corner(q3, x + ax, y + ay, z + az)
                            corner(q4, hx - sx, hy - sy, hz - sz)
                            local a = pa[i]
                            if t > FADE_START then a = a * (1 - t) / (1 - FADE_START) end
                            emitQuad(pr[i], pg[i], pb[i], a)
                        end
                    end
                end
            end
        end
    end
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
local landRay = wum.game.landRay    -- nil on a Melange without it: the ground is then a flat plane at the worm's feet
local hasLand = landRay ~= nil
local VEL_SCALE = 1                 -- engine velocity (wum.game.worms() vel) to units per second, to be confirmed

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
    if type(vel) ~= "table" then return end
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
    if not hasLand or probesThisFrame >= GUT.PROBE_BUDGET then return end
    probesThisFrame = probesThisFrame + 1
    local ok, t, nx, ny, nz = pcall(landRay, x, y + GUT.PROBE_UP, z, x, y - GUT.PROBE_DOWN, z)
    if not ok then return end
    if t == nil then
        if nx == "unavailable" then
            hasLand = false
        elseif k ~= 1 then
            s.gpok[k] = false   -- no ground under that part of the chain: it hangs there. Under the worm it keeps its plane.
        end
        return
    end
    nx, ny, nz = tonumber(nx), tonumber(ny), tonumber(nz)
    if not (nx and ny and nz) or ny < 0.2 then return end   -- a wall: keep the old plane
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
    if hasLand then probeGround(s, 1, s.px, s.py + 6, s.pz) end
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
local function gutUpdate(s, dt)
    local level = 0
    if s.alive and cfg.guts then
        if s.hasGut and s.wound > GUT.START then level = min(1, (s.wound - GUT.START) / (1 - GUT.START)) end
        if s.previewGut > level then level = s.previewGut end
    end
    s.gut = level
    if level <= 0 then
        s.gutLive, s.gutExtra = false, 0
        return
    end
    local px, py, pz = s.px, s.py, s.pz
    local rx, ry, rz, lx, ly, lz, sh, ch = gutRoot(s)
    local jx, jy, jz = px - s.gutPx, py - s.gutPy, pz - s.gutPz
    s.gutPx, s.gutPy, s.gutPz = px, py, pz
    if not s.gutLive or jx * jx + jy * jy + jz * jz > GUT.JUMP * GUT.JUMP then
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
    local want = min(GUT.POINTS - 2, GUT.OUT_BASE + GUT.OUT_LEVEL * level + s.gutExtra)
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
    if hasLand then
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
    if steps > GUT.MAX_STEPS then
        steps = GUT.MAX_STEPS
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
        for _ = 1, GUT.ITER do
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
    local want = hasPostfx and preset ~= nil and cfg.guts ~= false and not gutsMissing
    local n = 0
    if want then
        for slot, s in pairs(slots) do
            if s.gutLive and s.alive and s.seen == frameId and s.gutNa >= 2 then
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
            sendGutSlot(k, slots[w])
        end
    end
    setGutsEnabled(drawn > 0)
    probesThisFrame = 0
end

-- Is the guts effect usable? Melange lists effects with a failed flag, which a shader that does not compile or does not
-- draw sets. The old ribbons are drawn while it is not.
local function checkGutsFx()
    if not (hasPostfx and wum.postfx.list) then return end
    local ok, list = pcall(wum.postfx.list)
    if not ok or type(list) ~= "table" then return end
    local found = false
    for i = 1, #list do
        local e = list[i]
        if type(e) == "table" and e.id == GUTS.id then
            found = true
            gutsMissing = e.failed == true
            break
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
        if s.gutLive and s.seen == frameId and s.alive and s.gutNa >= 2 then
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
VIS.checkFx = checkGutsFx
VIS.reset = clearGuts
setScorch, woundSites, updateGut, drawGuts = scorchSet, sitesOf, gutUpdate, gutDraw

-- The blood colour, to the guts effect.
function VIS.setBlood(c)
    sendParam(GUTS, "blood", c[1], c[2], c[3])
end

function VIS.clearCache()
    GUTS.cache = {}
end

-- The insurance resend and the start-up zeroing (see resend and zeroAll).
function VIS.resend()
    for k = 1, GUT.SLOTS do
        if gutSlotOf[k] == nil then sendParam4(GUTS, GUT_A[k], 0, 0, 0, 0) end
    end
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
    hurtOpen = false
end

-- Everything back to nothing: the match ended or started, or the amount was turned off.
local function resetAll()
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
    readCamera()
    local worms = wum.game.worms()
    if type(worms) == "table" then
        trackWorms(worms, dt)
    else
        nExp = 0
    end
    updateSkin()
    VIS.updateGuts()
    simulate(dt)
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
    -- A scorch patch too, so it can be seen: it fades over a few seconds, so press Preview again to see it again.
    setScorch(pick.slot, 1)
    if cfg.vomit then startHeave(s) end
end

-- ---------------------------------------------------------------- start
-- Melange keeps a transient value across an effect reload unless the reload removes the param or changes its size, so
-- this is only insurance: everything live is sent again from time to time, zeros included for the slots that are not in
-- use, in case an effect was reloaded with a changed parameter list or a value was lost some other way.
local function resend()
    if not hasPostfx then return end
    STAINS.cache, SKIN.cache = {}, {}
    VIS.clearCache()
    for i = 1, STAIN_SLOTS do
        if stLive[i] then
            sendParam(STAINS, NAME_A[i], stX[i], stY[i], stZ[i])
            sendParam(STAINS, NAME_B[i], stR[i], stSeed[i], 1)
        else
            sendParam(STAINS, NAME_A[i], 0, 0, 0)
            sendParam(STAINS, NAME_B[i], 0, 0, 0)
        end
    end
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
    VIS.setBlood(c)
    VIS.resend()
    sendSeed()
end

-- Every slot of both effects starts at zero, whatever Melange saved in an earlier session.
local function zeroAll()
    for i = 1, STAIN_SLOTS do
        sendParam(STAINS, NAME_A[i], 0, 0, 0)
        sendParam(STAINS, NAME_B[i], 0, 0, 0)
    end
    for i = 1, SKIN_SLOTS do
        sendParam(SKIN, WORM_A[i], 0, 0, 0)
        sendParam(SKIN, WORM_B[i], 0, 0, 0)
        sendParam(SKIN, WORM_C[i], 0, 0, 0)
    end
    VIS.zero()
    VIS.zeroScorch()
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
VIS.checkFx()
wum.timers.every(2, VIS.checkFx)
