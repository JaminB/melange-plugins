-- Bloodsand: blood bursts when worms are hit, bleeding afterwards, blood and gaping wounds on the worms' skin,
-- blackened eyes and intestines on badly hurt worms, vomiting blood, stains on the ground and splatter on the lens.
--
-- It only reads game state (worm health, positions and facing, damage and explosion messages, the camera) and draws. It
-- never changes the simulation, sends anything or asks for a permission, so every player sees their own blood.
--
-- Droplets, mist and the dangling loop of intestines are world quads drawn from one "world" callback. The ground
-- stains are the bloodsand/stains post-FX effect (eight slots) and the blood, wounds, black eyes and the intestines
-- painted on a wound are bloodsand/skin (sixteen slots that follow the worms); both are fed with
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
    local px, py, pz, pvx, pvy, pvz = P.x, P.y, P.z, P.vx, P.vy, P.vz
    local psize, page, plife, pkind, pr, pg, pb, pa = P.size, P.age, P.life, P.kind, P.r, P.g, P.b, P.a
    local draw = CAM.ok
    local KP, KD, KG, KGROW, KFADE = MEL.KP, MEL.KD, MEL.KG, MEL.KGROW, MEL.KFADE
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
            local kd = pkind[i]
            local mist = KP[kd]
            local dr = 1 - KD[kd] * dt
            if dr < 0 then dr = 0 end
            vx, vy, vz = vx * dr, vy * dr + GRAVITY * KG[kd] * dt, vz * dr
            pvx[i], pvy[i], pvz[i] = vx, vy, vz
            local x, y, z = px[i] + vx * dt, py[i] + vy * dt, pz[i] + vz * dt
            px[i], py[i], pz[i] = x, y, z
            if draw then
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

-- == Melee sprays ===============================================================================================
-- A blood signature for each weapon, built from a few emitters on the particle pool: jets (a narrow pressurised cone;
-- a job runs one over time so it pulses), arcs (a flat fan with long streaks), clots (big slow heavy drops), mist, shred
-- (fine fast drops in every direction), a pancake that hugs the ground and a smear along a line. Particle kinds are
-- registered below (MEL.KG / KD / KP / KGROW / KFADE) and simulate() reads them from there. The classification that picks
-- the signature is in "Melee classification", further down. Everything lives in the one MEL table to spare locals.
for k, v in pairs({
    VEL_SCALE = 1,              -- engine velocity (the vel of wum.game.worms()) times this = units per second
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
        for _ = 1, n do
            local sp = rnd(0.4, 1) * speed
            puff(MIST, 7, ox + rnd(-4, 4), oy + rnd(-4, 4), oz + rnd(-3, 3),
                 (dx + rnd(-spread, spread)) * sp, (dy + rnd(-spread, spread)) * sp, (dz + rnd(-spread, spread)) * sp,
                 rnd(MIST_SIZE[1], MIST_SIZE[2]) * sizeMul, rnd(MIST_LIFE[1], MIST_LIFE[2]), MIST_ALPHA)
        end
    end

    -- Fine fast drops in every direction.
    local function shred(cx, cy, cz, n, s0, s1)
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
    local hasRay = wum.game.landRay ~= nil
    function MEL.ground(s)
        if hasRay then
            -- From the middle of the worm's body (always open air) down past its feet.
            local ok, t, nx, ny, nz = pcall(wum.game.landRay, s.px, s.py + CENTRE_Y, s.pz, s.px, s.py - 30, s.pz)
            if ok and type(t) == "number" and type(ny) == "number" and t > 0.02 then
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
                    while j.acc >= 1 and n < 6 do
                        j.acc = j.acc - 1
                        n = n + 1
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
        for _ = 1, 3 do
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
        for _ = 1, preset.mist + 4 do
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

-- A burst of blood at a worm's body. (dx, dy, dz) is the direction the blood goes, in any length. A weapon signature
-- (see Melee sprays) sprays first and takes its share of the droplets; the ordinary spray gets sig.generic of its usual
-- amount.
local function burst(s, damage, dx, dy, dz, death, sig)
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
    local gen = 1
    if sig then
        gen = sig.generic or 0
        local used = MEL.spray(sig, s, damage, count, dx, dy, dz, cx, cy, cz)
        count = max(0, min(floor(count * gen + 0.5), BURST_MAX - used))
    end
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
    for _ = 1, floor((death and preset.mist * 2 or preset.mist) * gen + 0.5) do
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
            local sp = sqrt(s.vx * s.vx + s.vy * s.vy + s.vz * s.vz)
            if sp > 40 and sp < 600 then
                local ev = sqrt(evx * evx + evy * evy + evz * evz)
                MEL.vSum, MEL.vN = MEL.vSum + min(100, sp / (ev + 1e-3)), MEL.vN + 1
                if MEL.vN >= 200 then MEL.vSum, MEL.vN = MEL.vSum * 0.5, MEL.vN * 0.5 end
                if DEBUG and MEL.vN % 50 == 0 then dbg("vel ratio (position speed / vel)", MEL.vSum / MEL.vN) end
            end
            MEL.velOk = MEL.vN < 30 or (MEL.vSum / MEL.vN >= 0.5 and MEL.vSum / MEL.vN <= 2)
            if MEL.velOk then
                if s.evOk then
                    local cx, cy, cz = evx - s.evx, evy - s.evy, evz - s.evz
                    if cx * cx + cy * cy + cz * cz > IMPULSE_MIN * IMPULSE_MIN then
                        s.ix, s.iy, s.iz, s.iat = cx, cy, cz, now
                    end
                end
                s.evx, s.evy, s.evz, s.evOk = evx, evy, evz, true
                vy = evy
            else
                s.evOk = false
            end
        else
            s.evOk = false
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
        if fsig and MEL.firedLeft > 0 and t - MEL.firedAt <= (fsig.window or 2.5) then
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
                            -- With the weapon only held, a worm that just landed from a fall is a fall.
                            if ok and not MEL.snapFired and (s.fallV or 0) < -FALL_MIN then ok = false end
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
    MEL.clear()
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
    MEL.beginFrame()
    local worms = wum.game.worms()
    if type(worms) == "table" then
        trackWorms(worms, dt)
    else
        nExp = 0
    end
    updateSkin()
    MEL.tick(dt)
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
    if cfg.vomit then startHeave(s) end
end

-- ---------------------------------------------------------------- start
-- Melange keeps a transient value across an effect reload unless the reload removes the param or changes its size, so
-- this is only insurance: everything live is sent again from time to time, zeros included for the slots that are not in
-- use, in case an effect was reloaded with a changed parameter list or a value was lost some other way.
local function resend()
    if not hasPostfx then return end
    STAINS.cache, SKIN.cache = {}, {}
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
end

-- == Melee hooks ================================================================================================
-- Kept at the end of the file, below every local the other sections define, so that these names find them.
--
-- requestPool(x, y, z, size, nx, ny, nz): asks for a big pool of blood on the ground at (x, y, z), `size` being the
-- radius in world units like a stain's, with the unit surface normal (nx, ny, nz) when the game's landRay gave one. Today
-- it is a plain stain; a better version defined above this section under the same name replaces it.
local requestPool = requestPool or function(x, y, z, size)
    placeStain(x, y, z, min(size, STAIN_DEATH))
end
MEL.pool = requestPool

-- setScorch(slot, amount): the skin side's hook for a burnt mark on a worm (0..1, raised to at least amount). It is
-- used when a setScorch defined above this section exists; the amount is also left in the worm's state as s.scorch.
function MEL.scorch(slot, amount)
    if slot == nil then return end
    local s = slots[slot]
    if s then s.scorch = max(s.scorch or 0, amount) end
    if setScorch then setScorch(slot, amount) end
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
