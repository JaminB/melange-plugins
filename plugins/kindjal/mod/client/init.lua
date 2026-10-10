-- Kindjal client script: the look and sound of the mod. The simulation side (sim/main.lua) changes the weapons; this file only
-- reads game state and draws, so it can never desynchronise a match.
--
--   Acid coat      A burst of acid (Acid Spitter, Acid Flask) coats every worm in reach. The coat is the kindjal/acid post-FX
--                  effect: a skin of acid that spreads over the worm for ten seconds, holds, and fades out by about 70 s.
--                  Coated worms give off thin wisps of vapour.
--   Burst smoke    Green-yellow smoke and bubbles at the burst, and a puddle on the ground that smokes while it lasts.
--                  The Crucible has no acid: it throws a ring of dark dust instead.
--   Melee flourish Bat, Prod, Fire Punch and No More Nails: sparks where the hit lands, a short red flash on the screen
--                  (kindjal/hit post-FX) and a matching sound. Optional spike glints on the swing.
--   Sounds         Swing, impact, launch and explosion sounds through wum.audio (Melange 0.9 and later). Every audio call
--                  is guarded, so an older Melange simply plays none.
--
-- Messages used: Kindjal.Burst (sim -> client, p.value = "x,y,z,r,kind"), Explosion, Weapon.Fired, Worm.Damaged,
-- melange.match.start / melange.match.end.
--
-- Post-FX parameters are named without the p_ prefix here ("worm0", "level0"), as in Bloodsand: Melange adds the prefix to
-- the uniform. Both effects are enabled only while they have something to show.

if not (wum and wum.draw and wum.draw.on and wum.game and wum.config) then return end

local sqrt, random, floor, min, max, abs = math.sqrt, math.random, math.floor, math.min, math.max, math.abs
local sin, cos, pi = math.sin, math.cos, math.pi

local function log(msg)
    if wum.log and wum.log.warn then pcall(wum.log.warn, msg) end
end

-- A log line that cannot flood: one per 5 seconds at most (a fault in a per-frame step would otherwise write 60 a second).
local lastErrAt = -100
local function logErr(where, err)
    local t = os.clock()
    if t - lastErrAt < 5 then return end
    lastErrAt = t
    log("kindjal: " .. where .. ": " .. tostring(err))
end

local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end
local function rnd(a, b) return a + random() * (b - a) end

local function cfg(key, default)
    local ok, v = pcall(wum.config.get, key)
    if ok and v ~= nil then return v end
    return default
end

-- Subscribes with a pcall around the handler, so a bug in one handler is logged instead of counting as a fault (three faults
-- disable a callback for the rest of the session).
local function subscribe(name, fn)
    if not (wum.events and wum.events.on) then return end
    local ok, err = pcall(wum.events.on, name, function(p)
        local good, e = pcall(fn, p)
        if not good then logErr(name, e) end
    end)
    if not ok then log("kindjal: cannot subscribe to " .. name .. ": " .. tostring(err)) end
end

-- Vectors arrive as {x, y, z} arrays in event payloads and with named fields from wum.game and wum.render.
local function vec(v)
    if type(v) ~= "table" then return nil end
    local x, y, z = tonumber(v.x or v[1]), tonumber(v.y or v[2]), tonumber(v.z or v[3])
    if x and y and z then return x, y, z end
    return nil
end

-- ---------------------------------------------------------------- constants and state
-- Settings, and what is derived from them. S.preset is nil while the visuals are off.
local PRESETS = {
    subtle = { strength = 0.55, pmax = 200, rate = 0.5 },
    full   = { strength = 1.0,  pmax = 400, rate = 1.0 },
}
local S = { preset = nil, smoke = true, melee = true, sounds = 0.8, spikes = false, seed = 0 }

local CENTRE_Y = 12             -- a worm's body centre is this far above the position the game reports
local SLOTS = 16                -- the acid effect has 16 worm slots

-- Timings (seconds) of the acid coat: level ramps up, holds, fades out; the eaten pattern spreads over SPREAD_SECS.
local COATK = { RAMP = 1.5, HOLD_END = 21.5, FADE_END = 70, SPREAD_SECS = 10, SPREAD_FROM = 0.15,
                WISP_CAP = 8, POS_STEP = 0.25, POS_MOVE = 0.6, POS_EVERY = 0.15, TOKENS = 6 }

-- The melee weapons (ids as in worms()[i].weapon; the same as Bloodsand's MEL.SIG): how far a hit reaches, which sound
-- goes with it, whether the swing whooshes and whether it has spikes for the glints.
local MELEE = {
    [10] = { reach = 52, hit = "impact_bat",   swing = true,  spikes = true },    -- baseball bat
    [11] = { reach = 42, hit = "impact_stab",  swing = true,  spikes = false },   -- prod
    [12] = { reach = 48, hit = "firepunch",    swing = false, spikes = false },   -- fire punch
    [25] = { reach = 44, hit = "impact_spike", swing = true,  spikes = true },    -- no more nails
}

local hasPostfx = wum.postfx and wum.postfx.setTransient and wum.postfx.enable and true or false
local hasSprite = wum.draw.sprite and true or false

local now = os.clock()          -- this frame's time (os.clock is wall time on Windows)

-- ---------------------------------------------------------------- textures
-- Eleven sprites, all white with the shape in alpha so that they take any tint (see the asset list in the README).
local TEX = {}
do
    local names = { "smoke1", "smoke2", "smoke3", "wisp1", "wisp2", "bubble", "puddle1", "puddle2", "spark", "glint", "drop" }
    if wum.draw.texture then
        for _, n in ipairs(names) do
            local ok, id = pcall(wum.draw.texture, "textures/kj_" .. n .. ".png")
            if ok and type(id) == "number" then
                TEX[n] = id
            else
                log("kindjal: texture kj_" .. n .. ".png not loaded: " .. tostring(ok and "no id" or id))
            end
        end
    end
end

-- ---------------------------------------------------------------- sounds
-- wum.audio comes with Melange 0.9. Handles are loaded the first time a sound is wanted (a failed load is tried again after
-- ten seconds), and nothing is played while audio is not ready or the volume setting is 0.
local AUD = { h = {}, retry = {} }

local function audioReady()
    if not (wum.audio and wum.audio.ready and wum.audio.load and wum.audio.play) then return false end
    local ok, r = pcall(wum.audio.ready)
    return ok and r == true
end

-- Plays sounds/kj_<name>.wav at a world point (x == nil: not positional) and returns the voice, or nil.
local function play(name, vol, x, y, z, loop)
    if S.sounds <= 0.001 or not audioReady() then return nil end
    local h = AUD.h[name]
    if not h then
        if (AUD.retry[name] or 0) > os.clock() then return nil end
        local ok, got = pcall(wum.audio.load, "sounds/kj_" .. name .. ".wav")
        if ok and got then
            h = got
            AUD.h[name] = h
        else
            AUD.retry[name] = os.clock() + 10
            return nil
        end
    end
    local opts = { volume = clamp((vol or 1) * S.sounds, 0, 2), pitch = loop and 1 or rnd(0.96, 1.04), loop = loop and true or false }
    if x then opts.pos = { x, y, z, x = x, y = y, z = z } end
    local ok, voice = pcall(wum.audio.play, h, opts)
    if ok then return voice end
    return nil
end

local function stopVoice(v)
    if v and wum.audio and wum.audio.stop then pcall(wum.audio.stop, v) end
end

-- ---------------------------------------------------------------- post-FX
-- Values go through wum.postfx.setTransient (neither saved nor logged by Melange) and one is only sent when it differs from
-- the last value sent to that effect. Only switching an effect on or off is saved, so that is only sent when it changes.
-- The acid effect is metered: the sends for coated worms share a token bucket of TOKENS per coated worm per second.
local FXA = { id = "kindjal/acid", cache = {}, enabled = nil, metered = true }
local FXH = { id = "kindjal/hit", cache = {}, enabled = nil }
local TOK = { v = 8 }

-- Returns true when a value was actually sent. `free` skips the token bucket (zeros that must go out, once-only values).
local function sendParam(fx, name, a, b, c, free)
    if not hasPostfx then return false end
    local old = fx.cache[name]
    if old and old[1] == a and old[2] == b and old[3] == c then return false end
    if fx.metered and not free and TOK.v < 1 then return false end
    -- Melange returns false when it does not know the effect, so the cache only changes once it took the value and a failed
    -- call is tried again at the next change or resend.
    local ok, res
    if c ~= nil then
        ok, res = pcall(wum.postfx.setTransient, fx.id, name, a, b, c)
    elseif b ~= nil then
        ok, res = pcall(wum.postfx.setTransient, fx.id, name, a, b)
    else
        ok, res = pcall(wum.postfx.setTransient, fx.id, name, a)
    end
    if not ok or res == false then return false end
    if not old then
        old = {}
        fx.cache[name] = old
    end
    old[1], old[2], old[3] = a, b, c
    if fx.metered and not free then TOK.v = TOK.v - 1 end
    return true
end

local function sendVec4(fx, name, a, b, c, d, free)
    if not hasPostfx then return false end
    local old = fx.cache[name]
    if old and old[1] == a and old[2] == b and old[3] == c and old[4] == d then return false end
    if fx.metered and not free and TOK.v < 1 then return false end
    local ok, res = pcall(wum.postfx.setTransient, fx.id, name, a, b, c, d)
    if not ok or res == false then return false end
    if not old then
        old = {}
        fx.cache[name] = old
    end
    old[1], old[2], old[3], old[4] = a, b, c, d
    if fx.metered and not free then TOK.v = TOK.v - 1 end
    return true
end

-- Melange compiles an effect when it is first switched on and the driver builds the program on its first draw, which costs
-- several milliseconds in the middle of the action. WARM switches each effect on for a few frames at the start of the first
-- match (one at a time, nothing to draw) so that this happens before anything is on screen. HOLD must outlast Melange's
-- start-up of the PostWorld stage (it registers the stage at the end of the first frame and hooks the engine's slot at the
-- end of the next). WARM.on[id] is true while an effect is held on.
local WARM = { on = {}, ids = { "kindjal/acid", "kindjal/hit" }, frame = 0, done = false, GAP = 6, HOLD = 5 }

local function sendEnabled(fx, on)
    if WARM.on[fx.id] then on = true end
    if not hasPostfx or fx.enabled == on then return end
    local ok, res = pcall(wum.postfx.enable, fx.id, on)
    if not ok or res == false then return end
    fx.enabled = on
end

local function warmStep()
    if WARM.done or not hasPostfx or not S.preset then return end
    local f = WARM.frame + 1
    WARM.frame = f
    for k = 1, #WARM.ids do
        local id, t0 = WARM.ids[k], WARM.GAP * k
        if f == t0 then
            WARM.on[id] = true
        elseif f == t0 + WARM.HOLD then
            WARM.on[id] = nil
        end
    end
    if f >= WARM.GAP * #WARM.ids + WARM.HOLD then
        WARM.done = true
        WARM.on = {}
    end
end

-- Parameter names, built once.
local WN, LN, SN = {}, {}, {}
for i = 0, SLOTS - 1 do WN[i] = "worm" .. i end
for k = 0, 3 do LN[k], SN[k] = "level" .. k, "spread" .. k end

-- ---------------------------------------------------------------- camera
local CAM = { ok = false, rx = 1, ry = 0, rz = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1 }

local function readCamera()
    CAM.ok = false
    if not (wum.render and wum.render.camera) then return end
    local ok, c = pcall(wum.render.camera)
    if not ok or type(c) ~= "table" then return end
    local fx, fy, fz = vec(c.fwd)
    local ux, uy, uz = vec(c.up)
    if not (fx and ux) then return end
    local fl = sqrt(fx * fx + fy * fy + fz * fz)
    if fl < 1e-6 then return end
    fx, fy, fz = fx / fl, fy / fl, fz / fl
    local rx, ry, rz = fy * uz - fz * uy, fz * ux - fx * uz, fx * uy - fy * ux
    local len = sqrt(rx * rx + ry * ry + rz * rz)
    if len < 1e-6 then return end
    rx, ry, rz = rx / len, ry / len, rz / len
    -- Up made exactly perpendicular to forward and right, so a rotated sprite stays square.
    ux, uy, uz = ry * fz - rz * fy, rz * fx - rx * fz, rx * fy - ry * fx
    CAM.rx, CAM.ry, CAM.rz, CAM.ux, CAM.uy, CAM.uz, CAM.fx, CAM.fy, CAM.fz = rx, ry, rz, ux, uy, uz, fx, fy, fz
    CAM.ok = true
end

-- ---------------------------------------------------------------- terrain ray
-- wum.game.landRay is the game's own ray cast against the land. Melange answers "unavailable" for the current level or thread
-- as well as for a build without it, so the flag is not final: it is set again at the next match start and ten seconds after
-- a failure. A frame may make RAY.cap rays of its own (Melange's cap of 256 is for all mods together).
local RAY = { fn = wum.game.landRay, ok = type(wum.game.landRay) == "function", retryAt = 0, used = 0, cap = 12 }

local function rayFailed()
    RAY.ok = false
    RAY.retryAt = os.clock() + 10
end

-- Returns t (0..1 along the segment) and the unit normal of the hit. A miss is nil alone; nil and a reason is a ray that did
-- not run or whose answer was no use.
local function castRay(x0, y0, z0, x1, y1, z1)
    if not RAY.ok then return nil, "unavailable" end
    if RAY.used >= RAY.cap then return nil, "budget" end
    RAY.used = RAY.used + 1
    local ok, t, nx, ny, nz = pcall(RAY.fn, x0, y0, z0, x1, y1, z1)
    if not ok then
        rayFailed()
        return nil, "unavailable"
    end
    if t == nil then
        if nx == "unavailable" then
            rayFailed()
            return nil, "unavailable"
        elseif nx == "budget" then
            RAY.used = RAY.cap
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

-- ---------------------------------------------------------------- particles
-- A struct of arrays: particle i is P.x[i], P.y[i] and so on, and the last particle moves into a freed slot.
local K_PUFF, K_WISP, K_SPARK, K_BUBBLE, K_DROP, K_GLINT = 0, 1, 2, 3, 4, 5

local P = { x = {}, y = {}, z = {}, vx = {}, vy = {}, vz = {}, s0 = {}, s1 = {}, age = {}, life = {}, kind = {}, tex = {},
            add = {}, rgb = {}, a = {}, drag = {}, grav = {}, rot = {}, spin = {} }
local PARTS = { P.x, P.y, P.z, P.vx, P.vy, P.vz, P.s0, P.s1, P.age, P.life, P.kind, P.tex, P.add, P.rgb, P.a, P.drag,
                P.grav, P.rot, P.spin }
local nP = 0

local function rgb8(r, g, b)
    return (floor(clamp(r, 0, 1) * 255 + 0.5) << 24) | (floor(clamp(g, 0, 1) * 255 + 0.5) << 16) | (floor(clamp(b, 0, 1) * 255 + 0.5) << 8)
end

-- size is the half width at birth (s0) and death (s1). `soft` particles (the steady wisps) leave a quarter of the pool free
-- for the bursts and the sparks.
local function spawn(kind, tex, additive, x, y, z, vx, vy, vz, s0, s1, life, r, g, b, a, drag, grav, rot, spin, soft)
    local pre = S.preset
    if not pre or not hasSprite or not tex then return false end
    if nP >= pre.pmax or (soft and nP >= pre.pmax * 0.75) then return false end
    nP = nP + 1
    local i = nP
    P.x[i], P.y[i], P.z[i], P.vx[i], P.vy[i], P.vz[i] = x, y, z, vx, vy, vz
    P.s0[i], P.s1[i], P.age[i], P.life[i], P.kind[i], P.tex[i] = s0, s1, 0, life, kind, tex
    P.add[i], P.rgb[i], P.a[i], P.drag[i], P.grav[i], P.rot[i], P.spin[i] = additive, rgb8(r, g, b), a, drag, grav, rot or 0, spin or 0
    return true
end

local function removeParticle(i)
    for k = 1, #PARTS do
        local arr = PARTS[k]
        arr[i] = arr[nP]
    end
    nP = nP - 1
end

-- Moves, ages and draws every particle in one pass (sprites can only be drawn inside the world callback, where this runs).
local function stepParticles(dt)
    local pre = S.preset
    if not pre or not hasSprite then
        nP = 0
        return
    end
    while nP > pre.pmax do removeParticle(nP) end     -- the amount was turned down
    local sprite = wum.draw.sprite
    local camOk = CAM.ok
    local rx, ry, rz, ux, uy, uz = CAM.rx, CAM.ry, CAM.rz, CAM.ux, CAM.uy, CAM.uz
    for i = nP, 1, -1 do
        local age = P.age[i] + dt
        local life = P.life[i]
        if age >= life then
            removeParticle(i)
        else
            P.age[i] = age
            local vx, vy, vz = P.vx[i], P.vy[i], P.vz[i]
            local dr = P.drag[i]
            if dr > 0 then
                local k = 1 - dr * dt
                if k < 0 then k = 0 end
                vx, vy, vz = vx * k, vy * k, vz * k
            end
            vy = vy + P.grav[i] * dt
            local x, y, z = P.x[i] + vx * dt, P.y[i] + vy * dt, P.z[i] + vz * dt
            P.vx[i], P.vy[i], P.vz[i], P.x[i], P.y[i], P.z[i] = vx, vy, vz, x, y, z

            local t = age / life
            local kind = P.kind[i]
            local s = P.s0[i] + (P.s1[i] - P.s0[i]) * (t * (2 - t))
            local a = P.a[i]
            local ax, ay, az, hl = 0, 0, 0, 0
            local hw = s                                                -- the half width the sprite is drawn with
            if kind == K_PUFF then
                a = a * min(1, age * 4) * (1 - t)
                local rot = P.rot[i] + P.spin[i] * dt
                P.rot[i] = rot
                if camOk then
                    local c, sn = cos(rot), sin(rot)
                    ax, ay, az, hl = rx * c + ux * sn, ry * c + uy * sn, rz * c + uz * sn, s
                end
            elseif kind == K_WISP then
                a = a * sin(pi * t)
                ax, ay, az, hl = -vx * 0.02, -1, -vz * 0.02, s * 2     -- the PNG is 1:2, its top row is the tail
            elseif kind == K_SPARK then
                a = a * (1 - t)
                -- kj_spark.png is a horizontal lens, long along u (the sprite's width), while the sprite's axis stretches v (the
                -- rows). So the streak runs along the width: halfW is the streak's half length, halfL its thin half thickness
                -- (the lens fills about a quarter of the rows), and the axis is turned a quarter turn from the velocity on screen
                -- (forward x velocity lies in the screen plane and is perpendicular to the projected velocity), which puts the
                -- width along the flight.
                local sp = sqrt(vx * vx + vy * vy + vz * vz)
                local len = clamp(sp * 0.045, 1.5, 14)
                hw, hl = len, s * 2
                ax, ay, az = ux, uy, uz                                 -- no camera or a head-on spark: a level streak
                if camOk and sp > 1e-3 then
                    local qx, qy, qz = CAM.fy * vz - CAM.fz * vy, CAM.fz * vx - CAM.fx * vz, CAM.fx * vy - CAM.fy * vx
                    local ql = sqrt(qx * qx + qy * qy + qz * qz)
                    if ql > sp * 0.05 then ax, ay, az = qx / ql, qy / ql, qz / ql end
                end
            elseif kind == K_BUBBLE then
                a = a * min(1, age * 5) * (1 - t * t * t)
                x = x + sin(age * 4 + P.rot[i]) * 1.2
            elseif kind == K_DROP then
                a = a * (1 - t * t)
                local sp = sqrt(vx * vx + vy * vy + vz * vz)
                if sp > 1e-3 then ax, ay, az, hl = vx, vy, vz, s * 1.4 end
            else    -- K_GLINT
                a = a * sin(pi * t)
                local rot = P.rot[i] + P.spin[i] * dt
                P.rot[i] = rot
                if camOk then
                    local c, sn = cos(rot), sin(rot)
                    ax, ay, az, hl = rx * c + ux * sn, ry * c + uy * sn, rz * c + uz * sn, s
                end
            end
            local a8 = floor(a * 255 + 0.5)
            if a8 > 0 and s > 0 then
                if a8 > 255 then a8 = 255 end
                sprite(P.tex[i], x, y, z, hw, hl, ax, ay, az, P.rgb[i] | a8, P.add[i] and "additive" or "alpha")
            end
        end
    end
end

-- ---------------------------------------------------------------- worms
-- W[slot] holds what the last frame saw: position, health, facing, weapon, and the latest drop in health.
local W = {}
local FR = { n = 0 }            -- frame counter; W[slot].seen == FR.n for the worms listed this frame
local ACT = { slot = nil }

local function activeSlot()
    if not wum.game.activeWorm then return nil end
    local ok, a = pcall(wum.game.activeWorm)
    if ok then return tonumber(a) end
    return nil
end

local MEL = { heldWeapon = nil, heldSlot = nil, heldAt = -100, firedSlot = nil, firedWid = nil, firedAt = -100,
              pending = false, hurtAt = -100, hurtWid = nil, lastAt = -100, pv = 0 }

local function trackWorms()
    ACT.slot = activeSlot()
    local ok, worms = pcall(wum.game.worms)
    if not ok or type(worms) ~= "table" then return end
    FR.n = FR.n + 1
    for i = 1, #worms do
        local w = worms[i]
        local slot = type(w) == "table" and tonumber(w.slot)
        local x, y, z
        if slot then x, y, z = vec(w.pos) end
        if x then
            local health = tonumber(w.health) or 0
            local alive = w.alive == true
            local yaw = tonumber(w.yaw)
            if yaw and yaw - yaw ~= 0 then yaw = nil end        -- NaN or infinite
            local s = W[slot]
            if not s then
                s = { hp = health, alive = alive, dropAmt = 0, dropAt = -100 }
                W[slot] = s
            end
            if alive and s.alive and health < s.hp then s.dropAmt, s.dropAt = s.hp - health, now end
            s.px, s.py, s.pz, s.hp, s.alive, s.yaw, s.seen = x, y, z, health, alive, yaw or s.yaw or 0, FR.n
            local wid = tonumber(w.weapon)
            s.weapon = wid
            if wid and slot == ACT.slot then MEL.heldWeapon, MEL.heldSlot, MEL.heldAt = wid, slot, now end
        end
    end
end

-- ---------------------------------------------------------------- acid coat
-- COAT[slot] = { t0 (spread clock), tl (level clock), kind, seed, cx, cy, cz (the position last committed), posAt, wacc }.
-- The level and the spread are packed four slots to a vec4 (slot = 4k + i), quantised to 1/32 and sent when they change.
local COAT = {}
local CS = { n = 0 }
local LVQ, SPQ = {}, {}
local GRP = { [0] = { dirty = false }, { dirty = false }, { dirty = false }, { dirty = false } }
for i = 0, SLOTS - 1 do LVQ[i], SPQ[i] = 0, 0 end

local function smooth(u) return u * u * (3 - 2 * u) end
local function quant(v) return floor(v * 32 + 0.5) / 32 end

local function coatLevel(a)
    if a <= 0 then return 0 end
    if a < COATK.RAMP then return smooth(a / COATK.RAMP) end
    if a < COATK.HOLD_END then return 1 end
    if a < COATK.FADE_END then return 1 - smooth((a - COATK.HOLD_END) / (COATK.FADE_END - COATK.HOLD_END)) end
    return 0
end

local function coatSpread(a)
    if a >= COATK.SPREAD_SECS then return 1 end
    local u = max(0, a) / COATK.SPREAD_SECS
    return COATK.SPREAD_FROM + (1 - COATK.SPREAD_FROM) * (1 - (1 - u) * (1 - u))
end

local function coatAdd(slot, kind)
    if slot < 0 or slot >= SLOTS then return end
    local c = COAT[slot]
    if c then
        -- Hit again: the level carries on from where it is (it never drops), and the hold starts over. The spread keeps going.
        -- The level is a smoothstep of the ramp clock, so the clock is set by inverting that curve (u = 0.5 - sin(asin(1-2y)/3)),
        -- not by scaling: scaling would put the level back below where it was.
        local cur = coatLevel(now - c.tl)
        if cur < 1 then
            local u = 0.5 - sin(math.asin(clamp(1 - 2 * cur, -1, 1)) / 3)
            c.tl = now - u * COATK.RAMP
        else
            c.tl = now - COATK.RAMP
        end
        return
    end
    COAT[slot] = { t0 = now, tl = now, kind = kind, seed = random(0, 1000), posAt = -100, wacc = 0, cx = 0, cy = 0, cz = 0 }
    CS.n = CS.n + 1
    GRP[slot >> 2].dirty = true
end

local function coatRemove(slot)
    if COAT[slot] then
        COAT[slot] = nil
        CS.n = CS.n - 1
        GRP[slot >> 2].dirty = true         -- the next send puts its zeros out
    end
    LVQ[slot], SPQ[slot] = 0, 0
end

-- Wisps of vapour rise from the surface of a coated worm: thin curls, additive, green-grey.
local function spawnWisp(cx, cy, cz)
    local a = rnd(0, 2 * pi)
    local tex = TEX["wisp" .. random(1, 2)]
    spawn(K_WISP, tex, true, cx + cos(a) * 6, cy + rnd(-8, 9), cz + sin(a) * 6,
          cos(a) * 2 + rnd(-3, 3), rnd(16, 28), sin(a) * 2 + rnd(-3, 3), rnd(3.5, 5), rnd(5.5, 8), rnd(1.4, 2.4),
          rnd(0.38, 0.5), rnd(0.55, 0.68), rnd(0.25, 0.34), rnd(0.4, 0.55), 0.3, 0, 0, 0, true)
end

-- Sends group k (slots 4k..4k+3) when it has a coat or has just lost its last one.
local function sendGroup(k)
    local g = GRP[k]
    local any = false
    for i = 0, 3 do
        if COAT[4 * k + i] then any = true break end
    end
    if not (any or g.dirty) then return end
    local free = not any
    for i = 0, 3 do
        local slot = 4 * k + i
        local c = COAT[slot]
        if c then
            sendParam(FXA, WN[slot], c.cx, c.cy, c.cz)
        else
            sendParam(FXA, WN[slot], 0, 0, 0, true)
        end
    end
    local b = 4 * k
    sendVec4(FXA, LN[k], LVQ[b], LVQ[b + 1], LVQ[b + 2], LVQ[b + 3], free)
    sendVec4(FXA, SN[k], SPQ[b], SPQ[b + 1], SPQ[b + 2], SPQ[b + 3], free)
    g.dirty = any
end

local function coatUpdate(dt)
    local pre = S.preset
    local nc = max(1, CS.n)
    TOK.v = min(COATK.TOKENS * nc + 2, TOK.v + dt * COATK.TOKENS * nc)
    local emitting = 0
    for slot, c in pairs(COAT) do
        local s = W[slot]
        local la = now - c.tl
        if not pre or not s or s.seen ~= FR.n or not s.alive or la >= COATK.FADE_END then
            coatRemove(slot)
        else
            local lv, sp = coatLevel(la), coatSpread(now - c.t0)
            LVQ[slot], SPQ[slot] = quant(lv), quant(sp)
            local x, y, z = s.px, s.py + CENTRE_Y, s.pz
            -- The centre is committed (quantised) only after the worm moved a little and a moment has passed.
            local dx, dy, dz = x - c.cx, y - c.cy, z - c.cz
            if c.posAt < 0 or (dx * dx + dy * dy + dz * dz > COATK.POS_MOVE * COATK.POS_MOVE and now - c.posAt >= COATK.POS_EVERY) then
                local q = 1 / COATK.POS_STEP
                c.cx, c.cy, c.cz = floor(x * q + 0.5) / q, floor(y * q + 0.5) / q, floor(z * q + 0.5) / q
                c.posAt = now
            end
            if S.smoke and lv > 0.05 and emitting < COATK.WISP_CAP then
                emitting = emitting + 1
                c.wacc = c.wacc + dt * rnd(4, 6) * lv * pre.rate
                while c.wacc >= 1 do
                    c.wacc = c.wacc - 1
                    spawnWisp(x, y, z)
                end
            end
        end
    end

    -- What the shader gets: worm centres, then the packed levels and spreads. A group that has just emptied sends its zeros
    -- (free of the token bucket) and then goes quiet.
    for k = 0, 3 do sendGroup(k) end
    if CS.n > 0 and pre then
        sendParam(FXA, "seed", S.seed, nil, nil, true)
        sendParam(FXA, "strength", pre.strength, nil, nil, true)
    end
    sendEnabled(FXA, CS.n > 0 and pre ~= nil)
end

-- ---------------------------------------------------------------- puddles
-- A puddle lies on the ground where the acid came down: grows for a second, holds about twelve seconds, shrinks over eight and
-- smokes while it lasts. At most three; a fourth replaces the oldest.
local PUD = {}
local PK = { MAX = 3, GROW = 1, HOLD = 12, SHRINK = 8, MIN_NY = 0.766 }      -- 0.766 is cos(40 degrees)

local function puddleEnd(p)
    stopVoice(p.voice)
    p.voice = nil
end

local function puddleScale(age)
    if age < PK.GROW then return smooth(age / PK.GROW) end
    if age < PK.GROW + PK.HOLD then return 1 end
    local u = (age - PK.GROW - PK.HOLD) / PK.SHRINK
    if u >= 1 then return 0 end
    return 1 - smooth(u)
end

local function puddleAdd(x, y, z, r)
    if not RAY.ok then return end
    -- Straight down from just above the burst; the first ray starts inside land when the crater is deep, then try from higher.
    local t, nx, ny, nz = castRay(x, y + 20, z, x, y - 160, z)
    local py = t and (y + 20 - t * 180)
    if t and t < 0.01 then
        t, nx, ny, nz = castRay(x, y + 90, z, x, y - 230, z)
        py = t and (y + 90 - t * 320)
        if t and t < 0.01 then t = nil end          -- still inside land: no surface to put it on
    end
    if not t or not ny or ny < PK.MIN_NY then return end
    if #PUD >= PK.MAX then
        puddleEnd(PUD[1])
        table.remove(PUD, 1)
    end
    local p = { x = x, y = py, z = z, nx = nx, ny = ny, nz = nz, R = clamp(r * 0.5, 18, 46), t0 = now, wacc = 0 }
    p.voice = play("acid_hiss", 0.35, x, py + 2, z, true)
    PUD[#PUD + 1] = p
end

-- Sprites face the camera, so a puddle is drawn the way a flat disc looks from here: stretched along the ground direction
-- that is square to the view, and as thin as the camera's angle to the ground makes it. It is moved toward the camera along
-- the view ray (the screen position does not change) so that the ground in front of it does not cut off its near half.
local function puddleDraw(p, sc, alpha)
    if not (CAM.ok and TEX.puddle1) then return end
    local nx, ny, nz = p.nx, p.ny, p.nz
    local d = CAM.rx * nx + CAM.ry * ny + CAM.rz * nz
    local tx, ty, tz = CAM.rx - nx * d, CAM.ry - ny * d, CAM.rz - nz * d
    local tl = sqrt(tx * tx + ty * ty + tz * tz)
    if tl < 1e-4 then return end
    tx, ty, tz = tx / tl, ty / tl, tz / tl
    local fn = abs(CAM.fx * nx + CAM.fy * ny + CAM.fz * nz)
    local R = p.R * sc
    local halfW = max(R * fn, R * 0.2)
    local push = min(25, R * sqrt(max(0, 1 - fn * fn)) * 0.45)
    local cx, cy, cz = p.x + nx * 0.6 - CAM.fx * push, p.y + ny * 0.6 - CAM.fy * push, p.z + nz * 0.6 - CAM.fz * push
    local a8 = floor(clamp(alpha, 0, 1) * 255 + 0.5)
    if a8 <= 0 then return end
    local sprite = wum.draw.sprite
    sprite(TEX.puddle1, cx, cy, cz, halfW, R, tx, ty, tz, rgb8(0.36, 0.58, 0.09) | a8, "alpha")
    if TEX.puddle2 then
        local b8 = floor(a8 * 0.6)
        sprite(TEX.puddle2, cx + tx * R * 0.1, cy + ty * R * 0.1, cz + tz * R * 0.1, halfW * 0.72, R * 0.72, tx, ty, tz,
               rgb8(0.62, 0.84, 0.16) | b8, "alpha")
    end
end

local function puddleUpdate(dt)
    local pre = S.preset
    for i = #PUD, 1, -1 do
        local p = PUD[i]
        local age = now - p.t0
        local sc = puddleScale(age)
        if not pre or age >= PK.GROW + PK.HOLD + PK.SHRINK then
            puddleEnd(p)
            table.remove(PUD, i)
        else
            if S.smoke then
                puddleDraw(p, 0.15 + 0.85 * sc, min(1, sc * 1.5) * 0.62)
                if sc > 0.3 then
                    p.wacc = p.wacc + dt * rnd(2, 4) * pre.rate
                    while p.wacc >= 1 do
                        p.wacc = p.wacc - 1
                        local a, d = rnd(0, 2 * pi), rnd(0, 0.6) * p.R * sc
                        spawn(K_WISP, TEX["wisp" .. random(1, 2)], true, p.x + cos(a) * d + p.nx * 2, p.y + p.ny * 2, p.z + sin(a) * d + p.nz * 2,
                              rnd(-3, 3), rnd(14, 24), rnd(-3, 3), rnd(3.5, 5), rnd(6, 9), rnd(1.6, 2.6),
                              rnd(0.38, 0.5), rnd(0.6, 0.72), rnd(0.22, 0.3), rnd(0.35, 0.5), 0.3, 0, 0, 0, true)
                    end
                end
            end
        end
    end
end

-- ---------------------------------------------------------------- bursts
-- Smoke and bubbles of an acid burst, and the drops it throws.
local function acidSmoke(x, y, z, r)
    local R = S.preset.rate
    local spread = clamp(r * 0.22, 6, 24)
    for _ = 1, floor(rnd(25, 40) * R + 0.5) do
        local a, d = rnd(0, 2 * pi), rnd(0, 1) * spread
        spawn(K_PUFF, TEX["smoke" .. random(1, 3)], true, x + cos(a) * d, y + rnd(0, 10), z + sin(a) * d,
              rnd(-12, 12), rnd(8, 26), rnd(-12, 12), rnd(5, 9), rnd(16, 30), rnd(3, 6),
              rnd(0.5, 0.7), rnd(0.75, 0.9), rnd(0.1, 0.22), rnd(0.14, 0.24), 0.5, 0, rnd(0, 2 * pi), rnd(-0.6, 0.6))
    end
    for _ = 1, floor(rnd(10, 15) * R + 0.5) do
        local a, d = rnd(0, 2 * pi), rnd(0, 1) * spread
        spawn(K_BUBBLE, TEX.bubble, false, x + cos(a) * d, y + rnd(0, 6), z + sin(a) * d,
              rnd(-3, 3), rnd(8, 16), rnd(-3, 3), rnd(1.5, 3.5), rnd(2, 4.5), rnd(2, 4),
              0.72, 1, 0.6, rnd(0.55, 0.8), 0.2, 0, rnd(0, 6), 0)
    end
    -- Drops thrown up and out, falling back.
    if TEX.drop then
        for _ = 1, floor(rnd(8, 12) * R + 0.5) do
            local a, sp = rnd(0, 2 * pi), rnd(30, 90)
            spawn(K_DROP, TEX.drop, false, x, y + 4, z, cos(a) * sp, rnd(80, 170), sin(a) * sp, rnd(1.1, 2), rnd(0.8, 1.4),
                  rnd(0.7, 1.2), 0.5, 0.9, 0.14, 0.9, 0, -300, 0, 0)
        end
    end
end

-- The Crucible: a ring of dark dust thrown out along the ground, and a short orange flare in the middle.
local function crucibleDust(x, y, z, r)
    local R = S.preset.rate
    local n = floor(rnd(16, 20) * R + 0.5)
    for i = 1, n do
        local a = (i / n) * 2 * pi + rnd(-0.2, 0.2)
        local sp = rnd(60, 110)
        local c, s = cos(a), sin(a)
        spawn(K_PUFF, TEX["smoke" .. random(1, 3)], false, x + c * r * 0.12, y + rnd(2, 8), z + s * r * 0.12,
              c * sp, rnd(6, 20), s * sp, rnd(10, 14), rnd(30, 40), rnd(3, 5),
              rnd(0.14, 0.2), rnd(0.12, 0.16), rnd(0.1, 0.13), rnd(0.45, 0.6), 0.9, 0, rnd(0, 2 * pi), rnd(-0.5, 0.5))
    end
    for _ = 1, floor(5 * R + 0.5) do
        spawn(K_PUFF, TEX["smoke" .. random(1, 3)], true, x + rnd(-12, 12), y + rnd(2, 14), z + rnd(-12, 12),
              rnd(-10, 10), rnd(30, 60), rnd(-10, 10), rnd(14, 20), rnd(45, 70), rnd(0.5, 0.9),
              1, rnd(0.45, 0.6), 0.14, rnd(0.4, 0.55), 1.2, 0, rnd(0, 2 * pi), rnd(-1, 1))
    end
end

local function onBurst(x, y, z, r, kind)
    -- The sounds do not depend on the visuals setting.
    if kind == 2 then
        play("crucible", 1.0, x, y, z)
    else
        play("acid_burst", kind == 1 and 1.0 or 0.7, x, y, z)
    end
    local pre = S.preset
    if not pre then return end
    if kind == 2 then
        if S.smoke then crucibleDust(x, y, z, r) end
        return
    end
    -- Every living worm in reach is coated; reach is the blast radius plus a little for the size of a worm.
    local reach = r * 1.15 + 12
    for slot, s in pairs(W) do
        if s.seen == FR.n and s.alive then
            local dx, dy, dz = s.px - x, s.py + CENTRE_Y - y, s.pz - z
            if dx * dx + dy * dy + dz * dz <= reach * reach then coatAdd(slot, kind) end
        end
    end
    if S.smoke then
        acidSmoke(x, y, z, r)
        puddleAdd(x, y, z, r)
    end
end

-- Parses "x,y,z,r,kind".
local function onBurstMessage(p)
    local text = type(p) == "table" and p.value or p
    if type(text) ~= "string" then return end
    local v, n = {}, 0
    for num in string.gmatch(text, "[-%d%.eE]+") do
        local d = tonumber(num)
        if d then
            n = n + 1
            v[n] = d
        end
    end
    if n < 5 then return end
    onBurst(v[1], v[2], v[3], v[4], floor(v[5] + 0.5))
end

-- ---------------------------------------------------------------- melee flourish
-- The game says "a worm was damaged" without saying by what or whom. So the swing is remembered when it happens
-- (Weapon.Fired: who, which weapon), a health drop that follows within 0.6 s is matched to it, and the victim is the other worm
-- in reach whose health fell furthest. A weapon id can vanish from worms() before the damage arrives, so the id last seen on
-- the active worm is kept for 2.5 s.
local HF = { on = false, t0 = -100, peak = 0, u = 0.5, v = 0.5 }
local FLASH_SECS = 0.25

local function startFlash(vx, vy, vz, dmg)
    if not (hasPostfx and wum.render and wum.render.worldToScreen and wum.render.windowSize) then return end
    local ok, sx, sy = pcall(wum.render.worldToScreen, { x = vx, y = vy, z = vz })
    if not ok or type(sx) ~= "number" or type(sy) ~= "number" then return end
    local okw, w, h = pcall(wum.render.windowSize)
    if not okw or type(w) ~= "number" or type(h) ~= "number" or w <= 0 or h <= 0 then return end
    HF.on, HF.t0 = true, now
    HF.peak = clamp(dmg, 10, 50) / 50 * 0.35 * S.preset.strength
    -- The shader's uv has its origin at the bottom left; window pixels count from the top left.
    HF.u, HF.v = clamp(sx / w, 0, 1), clamp(1 - sy / h, 0, 1)
    sendParam(FXH, "center", HF.u, HF.v, nil, true)
end

local function hitUpdate()
    if HF.on then
        local age = now - HF.t0
        if age >= FLASH_SECS or not S.preset then
            HF.on = false
            sendParam(FXH, "flash", 0, nil, nil, true)
        else
            local u = 1 - age / FLASH_SECS
            sendParam(FXH, "flash", floor(HF.peak * u * u * 64 + 0.5) / 64, nil, nil, true)
        end
    end
    sendEnabled(FXH, HF.on)
end

local function impactBurst(ix, iy, iz, dx, dy, dz, dmg, wid)
    local R = S.preset.rate
    local boost = 0.7 + 0.3 * clamp(dmg / 30, 0.3, 1.5)
    for _ = 1, floor(rnd(8, 14) * R * boost + 0.5) do
        local sp = rnd(70, 190)
        spawn(K_SPARK, TEX.spark, false, ix, iy, iz, dx * sp + rnd(-60, 60), dy * sp + rnd(10, 90), dz * sp + rnd(-60, 60),
              rnd(0.9, 1.6), 0.5, rnd(0.35, 0.7), rnd(0.32, 0.5), rnd(0.04, 0.08), rnd(0.03, 0.06), 0.9, 0.6, -260)
    end
    local hot = wid == 12 and 2 or 0
    for _ = 1, floor((rnd(3, 5) + hot) * R + 0.5) do
        local sp = rnd(100, 240)
        spawn(K_SPARK, TEX.spark, true, ix, iy, iz, dx * sp + rnd(-70, 70), dy * sp + rnd(0, 100), dz * sp + rnd(-70, 70),
              rnd(1.2, 1.8), 0.4, rnd(0.15, 0.3), 1, rnd(0.45, 0.65), 0.12, 0.9, 0.8, -200)
    end
    spawn(K_GLINT, TEX.glint, true, ix, iy, iz, 0, 0, 0, 6, 10, 0.18, 1, 0.7, 0.3, 0.9, 0, 0, rnd(0, 2 * pi), rnd(-2, 2))
end

-- Spike glints on the swing: a few sparkles at the tip, for a third of a second.
local function spikeGlints(a)
    local s = W[a]
    if not (S.preset and S.spikes and S.melee and s and TEX.glint) then return end
    local yaw = s.yaw or 0
    local gx, gy, gz = s.px + sin(yaw) * 10, s.py + CENTRE_Y + 8, s.pz + cos(yaw) * 10
    for _ = 1, random(2, 3) do
        spawn(K_GLINT, TEX.glint, true, gx + rnd(-3, 3), gy + rnd(-3, 3), gz + rnd(-3, 3), 0, 0, 0, 2.5, 5.5, 0.35,
              1, 0.95, 0.7, 0.9, 0, 0, rnd(0, 2 * pi), rnd(-3, 3))
    end
end

-- One flourish: the matching sound, and (when the visuals are on) sparks at the impact point and the screen flash. The
-- impact point is the victim's centre pulled six units toward the attacker. `force` skips the rate limit (the preview).
local function flourish(aSlot, vSlot, wid, dmg, snap, force)
    if not force and now - MEL.lastAt < 0.4 then return end
    local m = MELEE[wid]
    local a, v = W[aSlot], W[vSlot]
    if not (m and v) then return end
    MEL.lastAt = now
    local vx, vy, vz
    if snap then vx, vy, vz = v.sx or v.px, (v.sy or v.py) + CENTRE_Y, v.sz or v.pz else vx, vy, vz = v.px, v.py + CENTRE_Y, v.pz end
    local ax, ay, az = vx, vy, vz
    if a and a ~= v then
        if snap then ax, ay, az = a.sx or a.px, (a.sy or a.py) + CENTRE_Y, a.sz or a.pz else ax, ay, az = a.px, a.py + CENTRE_Y, a.pz end
    end
    local dx, dy, dz = ax - vx, ay - vy, az - vz                 -- victim to attacker
    local dl = sqrt(dx * dx + dy * dy + dz * dz)
    if dl < 1 then
        -- Same worm, or on top of each other: use the way the attacker faces.
        local yaw = a and a.yaw or 0
        dx, dy, dz, dl = -sin(yaw), 0, -cos(yaw), 1
    end
    dx, dy, dz = dx / dl, dy / dl, dz / dl
    local ix, iy, iz = vx + dx * 6, vy + dy * 6, vz + dz * 6
    play(m.hit, 1.0, ix, iy, iz)
    if S.preset and S.melee then
        -- Sparks fly away from the attacker.
        impactBurst(ix, iy, iz, -dx, -dy, -dz, dmg, wid)
        startFlash(vx, vy, vz, dmg)
    end
end

local function resolveMelee()
    if not MEL.pending then return end
    if now - MEL.hurtAt > 0.35 then
        MEL.pending = false
        return
    end
    local wid = MEL.hurtWid
    local m = wid and MELEE[wid]
    local a = MEL.firedSlot and W[MEL.firedSlot]
    if not (m and a) then
        MEL.pending = false
        return
    end
    -- The victim: another worm in reach (by where everyone stood when the damage was reported) whose health fell, the
    -- biggest fall winning.
    local best, bestDrop
    local ax, ay, az = a.sx or a.px, a.sy or a.py, a.sz or a.pz
    for slot, s in pairs(W) do
        if slot ~= MEL.firedSlot and s.seen == FR.n and s.dropAt >= MEL.hurtAt - 0.25 then
            local dx, dy, dz = (s.sx or s.px) - ax, (s.sy or s.py) - ay, (s.sz or s.pz) - az
            if sqrt(dx * dx + dz * dz) <= m.reach and abs(dy) <= 30 and (not bestDrop or s.dropAmt > bestDrop) then
                best, bestDrop = slot, s.dropAmt
            end
        end
    end
    if best then
        MEL.pending = false
        W[best].dropAt = -100
        flourish(MEL.firedSlot, best, wid, bestDrop, true, false)
    end
end

-- ---------------------------------------------------------------- explosives
local EXPL = { t0 = -100, n = 0 }

local function onExplosion(p)
    if type(p) ~= "table" then return end
    local x, y, z = vec(p.damageEpicentre)
    if not x then return end
    local t = os.clock()
    if t - EXPL.t0 >= 1 then EXPL.t0, EXPL.n = t, 0 end
    if EXPL.n >= 6 then return end
    EXPL.n = EXPL.n + 1
    local wd = tonumber(p.wormDamage) or 0
    local name = wd >= 60 and "boom_large" or (wd >= 35 and "boom_med" or "boom_small")
    play(name, clamp(wd / 100, 0.4, 1.2), x, y, z)
end

local function onFired()
    local t = os.clock()
    local a = activeSlot()
    if not a then return end
    local s = W[a]
    local wid = s and s.weapon
    if not wid and MEL.heldSlot == a and t - MEL.heldAt <= 2.5 then wid = MEL.heldWeapon end
    if not wid then return end
    local m = MELEE[wid]
    if m then
        MEL.firedSlot, MEL.firedWid, MEL.firedAt = a, wid, t
        if s and m.swing then play("swing", 0.8, s.px, s.py + CENTRE_Y, s.pz) end
        if m.spikes then spikeGlints(a) end
    elseif s then
        play("launch", 0.6, s.px, s.py + CENTRE_Y, s.pz)
    end
end

local function onDamaged()
    local t = os.clock()
    -- Only a hit within 0.6 s of a melee swing is a flourish; the positions are those of the last frame, before the knock.
    if MEL.firedWid and t - MEL.firedAt <= 0.6 then
        MEL.pending, MEL.hurtAt, MEL.hurtWid = true, t, MEL.firedWid
        for _, s in pairs(W) do s.sx, s.sy, s.sz = s.px, s.py, s.pz end
    end
end

-- ---------------------------------------------------------------- preview
-- Menu items and one event ("mod.kindjal.preview", p.what = "acid" | "melee" | "age") for the test harness.
local PV = { kind = 2, weapon = 0, radii = { [0] = 70, 60, 243 }, melees = { 10, 11, 25, 12 } }

local function previewTarget()
    local a = ACT.slot or activeSlot()
    local sa = a and W[a]
    if sa and sa.seen ~= FR.n then sa = nil end
    local best, bd
    for slot, s in pairs(W) do
        if s.seen == FR.n and s.alive and slot ~= a then
            local d = 0
            if sa then
                local dx, dy, dz = s.px - sa.px, s.py - sa.py, s.pz - sa.pz
                d = dx * dx + dy * dy + dz * dz
            end
            if not bd or d < bd then best, bd = slot, d end
        end
    end
    if best then return best, a end
    if sa and sa.alive then return a, a end
    return nil
end

local function previewAcid()
    local v = previewTarget()
    local s = v and W[v]
    if not s then return end
    now = os.clock()
    PV.kind = (PV.kind + 1) % 3
    onBurst(s.px, s.py + 2, s.pz, PV.radii[PV.kind], PV.kind)
end

local function previewMelee()
    local v, a = previewTarget()
    if not v then return end
    now = os.clock()
    PV.weapon = PV.weapon % #PV.melees + 1
    flourish(a or v, v, PV.melees[PV.weapon], 30, false, true)
end

local function previewAge()
    for _, c in pairs(COAT) do c.t0, c.tl = c.t0 - 10, c.tl - 10 end
    for _, p in ipairs(PUD) do p.t0 = p.t0 - 10 end
end

-- ---------------------------------------------------------------- lifecycle
-- The insurance resend: Melange keeps a transient value across an effect reload unless the reload changes the parameter
-- list, so everything live is sent again every two seconds, a group of four slots per frame.
local RS = { step = 0 }

local function resendStep()
    local k = RS.step
    if k == 0 then return end
    RS.step = k < 5 and k + 1 or 0
    if k <= 4 then
        local g = k - 1
        for i = 0, 3 do FXA.cache[WN[4 * g + i]] = nil end
        FXA.cache[LN[g]], FXA.cache[SN[g]] = nil, nil
    else
        FXA.cache.seed, FXA.cache.strength = nil, nil
        if HF.on then FXH.cache.flash, FXH.cache.center = nil, nil end
    end
end

-- Everything visual back to nothing: the match ended or started, or the visuals were turned off.
local function clearVisuals()
    nP = 0
    for slot in pairs(COAT) do coatRemove(slot) end
    for i = #PUD, 1, -1 do
        puddleEnd(PUD[i])
        PUD[i] = nil
    end
    HF.on = false
end

local live = false

local function resetAll()
    clearVisuals()
    for slot in pairs(W) do W[slot] = nil end
    MEL.pending, MEL.firedSlot, MEL.firedWid, MEL.firedAt, MEL.heldSlot = false, nil, nil, -100, nil
    EXPL.n = 0
    S.seed = random(0, 1000)
    -- A match edge can cut the warm-up short between "held on" and its release, and WARM.on would force the effect on until
    -- the next match; drop the holds here and let an unfinished warm-up run again from the start.
    WARM.on = {}
    if not WARM.done then WARM.frame = 0 end
    -- Zeros out now (only for the groups that had a coat), then the effects off; nothing runs between matches.
    for k = 0, 3 do sendGroup(k) end
    sendParam(FXH, "flash", 0, nil, nil, true)
    sendEnabled(FXA, false)
    sendEnabled(FXH, false)
    live = false
end

local function frame()
    local t = os.clock()
    local dt = clamp(t - now, 0, 0.05)
    now = t
    local okm, inMatch = pcall(wum.game.inMatch)
    if not (okm and inMatch) then
        if live then resetAll() end
        return
    end
    live = true
    RAY.used = 0
    if not RAY.ok and type(RAY.fn) == "function" and t >= RAY.retryAt then RAY.ok = true end
    warmStep()
    trackWorms()
    resolveMelee()
    -- coatUpdate also runs with the visuals off: it sends the zeros of coats that were just cleared.
    if S.preset then readCamera() end
    coatUpdate(dt)
    if S.preset then
        puddleUpdate(dt)
        stepParticles(dt)
    end
    hitUpdate()
    resendStep()
end

local function onWorld()
    local ok, err = pcall(frame)
    if not ok then logErr("frame", err) end
end

-- ---------------------------------------------------------------- settings
local function applySettings()
    local pre = PRESETS[tostring(cfg("intensity", "full"))]       -- "off" has no preset
    S.smoke = cfg("smoke", true) ~= false
    S.melee = cfg("melee", true) ~= false
    S.sounds = clamp(tonumber(cfg("sounds", 0.8)) or 0.8, 0, 1)
    S.spikes = cfg("spikes", false) == true
    if pre ~= S.preset then
        local was = S.preset
        S.preset = pre
        if not pre then
            -- A warm-up cut short here would leave WARM.on forcing an effect on; start it again from the top later.
            WARM.on, WARM.frame = {}, 0
            if was then clearVisuals() end
        end
    end
    -- Outside a match nothing drives the effects, so settle an enabled=1 that Melange saved earlier.
    local ok, inMatch = pcall(wum.game.inMatch)
    if not (ok and inMatch) then
        sendEnabled(FXA, false)
        sendEnabled(FXH, false)
    end
end

-- ---------------------------------------------------------------- start
S.seed = random(0, 1000)
applySettings()

subscribe("Kindjal.Burst", onBurstMessage)
subscribe("Explosion", onExplosion)
subscribe("Weapon.Fired", onFired)
subscribe("Worm.Damaged", onDamaged)
subscribe("melange.match.start", resetAll)
subscribe("melange.match.end", resetAll)
subscribe("mod.kindjal.preview", function(p)
    local what = type(p) == "table" and p.what
    if what == "acid" then previewAcid() elseif what == "melee" then previewMelee() elseif what == "age" then previewAge() end
end)

wum.draw.on("world", onWorld)
if wum.ui and wum.ui.menu then
    pcall(wum.ui.menu, "Preview acid", previewAcid)
    pcall(wum.ui.menu, "Preview melee", previewMelee)
    pcall(wum.ui.menu, "Acid +10 s", previewAge)
end
wum.timers.every(0.5, applySettings)
wum.timers.every(2, function() if RS.step == 0 then RS.step = 1 end end)
