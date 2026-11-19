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
--   Grave Spade    The spade drawn in the worm's hands, which MiragePose carries along every scoop and strike; dirt, dust,
--                  chips and sparks where it digs; and the once-a-match execution: the camera circles the pair, the victim
--                  falls on its back, the attacker climbs on, sets the blade on its chest and takes its head off. The head
--                  rolls away. With Bloodsand 1.6 the gore is Bloodsand's (mod.kindjal.exec); without it, dust and sand.
--   Buddy Bomb     The labradoodle in the sheep's slot sends up a few little hearts when he is set down, barks while he
--                  walks, yelps before he blows, and leaves tufts of fur, a red mist, a spray of blood and a pool of it
--                  where he went off.
--
-- Messages used: Kindjal.Burst (sim -> client, p.value = "x,y,z,r,kind"), Kindjal.Spade (see the Grave Spade section), Explosion, Weapon.Fired, Worm.Damaged,
-- Payload.BigJump, Payload.CollideWithWater, Payload.CollideWithDisarmPlane, Payload.Sunk, GameLogic.Turn.Started /
-- GameLogic.Turn.Ended, melange.match.start / melange.match.end.
--
-- Post-FX parameters are named without the p_ prefix here ("worm0", "level0"), as in Bloodsand: Melange adds the prefix to
-- the uniform. Both effects are enabled only while they have something to show.
--
-- Smoothness. Nothing here counts frames: every motion and every curve is a function of seconds. The step is the measured time
-- between two frames (os.clock), clamped to 1/15 s so a hitch does not throw particles across the screen. Particle motion is
-- integrated in closed form (drag and gravity together), so a particle is in the same place at the same time at 30, 60 or 144
-- frames a second. Steady emitters keep a fractional accumulator and give each new particle the age it would have if it had
-- been born at its exact moment inside the frame, so nothing arrives in bursts of N frames.

if not (wum and wum.draw and wum.draw.on and wum.game and wum.config) then return end

local sqrt, random, floor, min, max, abs = math.sqrt, math.random, math.floor, math.min, math.max, math.abs
local sin, cos, pi, exp = math.sin, math.cos, math.pi, math.exp

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
-- Values are continuous. A level or spread is sent when it moved by more than SEND_EPS since the last send, or after SEND_EVERY
-- seconds; a worm centre when it moved by POS_EPS. TOKENS is only a ceiling on sends per coated worm per second (a runaway
-- guard; the rules above send far fewer, and only during the 1.5 s ramp does a worm need one every frame).
local COATK = { RAMP = 1.5, HOLD_END = 21.5, FADE_END = 70, SPREAD_SECS = 10, SPREAD_FROM = 0.15,
                WISP_CAP = 8, POS_EPS = 0.02, SEND_EPS = 1 / 256, SEND_EVERY = 0.25, TOKENS = 240, FOLLOW = 10 }

-- The melee weapons (ids as in worms()[i].weapon; the same as Bloodsand's MEL.SIG): how far a hit reaches, which sound
-- goes with it, whether the swing whooshes and whether it has spikes for the glints. The Grave Spade is a clone of the
-- Bat (worms()[i].weapon 10 and .clone "kWeaponGraveSpade"): its worms carry the key "spade" instead of 10.
local MELEE = {
    [10] = { reach = 52, hit = "impact_bat",   swing = true,  spikes = true },    -- baseball bat
    spade = { reach = 44, hit = "spade_ring",  swing = true,  spikes = false },   -- the Grave Spade
    [11] = { reach = 42, hit = "impact_stab",  swing = true,  spikes = false },   -- prod
    [12] = { reach = 48, hit = "firepunch",    swing = false, spikes = false },   -- fire punch
    [25] = { reach = 44, hit = "impact_spike", swing = true,  spikes = true },    -- no more nails
}

local hasPostfx = wum.postfx and wum.postfx.setTransient and wum.postfx.enable and true or false
local hasSprite = wum.draw.sprite and true or false

local now = os.clock()          -- this frame's time (os.clock is wall time on Windows)
local lastT = now               -- the time of the frame before (the step is measured from this, so a handler that sets `now`
                                -- for itself cannot shorten the next step)
local curDt = 1 / 60            -- this frame's step in seconds, clamped to MAX_DT
local MAX_DT = 1 / 15

-- Smoothstep and its relatives, used by every curve below.
local function smooth(u)
    if u <= 0 then return 0 elseif u >= 1 then return 1 end
    return u * u * (3 - 2 * u)
end

-- ---------------------------------------------------------------- textures
-- Twelve sprites, all white with the shape in alpha so that they take any tint (see the asset list in the README).
local TEX = {}
do
    local names = { "smoke1", "smoke2", "smoke3", "wisp1", "wisp2", "bubble", "puddle1", "puddle2", "spark", "glint", "drop",
                    "heart" }
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

-- Picking a variant is a table lookup (building the name with .. would make a string every time a particle is born).
local SMOKE_T, WISP_T = {}, {}
for i = 1, 3 do SMOKE_T[i] = TEX["smoke" .. i] end
for i = 1, 2 do WISP_T[i] = TEX["wisp" .. i] end

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
local TOK = { v = 12 }

-- True when the value last sent for `name` is missing, or differs from (a, b, c, d) by more than eps in some component, or
-- differs at all and was sent `every` seconds ago or more. This is what lets a smooth value go out in steps of 1/256 (finer
-- than an 8-bit colour can show) without ever going stale.
local function moved(fx, name, eps, every, sentAt, a, b, c, d)
    local old = fx.cache[name]
    if not old then return true end
    local dm, dx = 0, 0
    dx = abs(a - (old[1] or 0)); if dx > dm then dm = dx end
    if b then dx = abs(b - (old[2] or 0)); if dx > dm then dm = dx end end
    if c then dx = abs(c - (old[3] or 0)); if dx > dm then dm = dx end end
    if d then dx = abs(d - (old[4] or 0)); if dx > dm then dm = dx end end
    return dm > eps or (dm > 0 and now - sentAt >= every)
end

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

-- age < 0 is a particle that has not been born yet: it waits, unseen, and starts moving at age 0 (bursts use this to billow
-- instead of appearing in one frame; a steady emitter uses it to place a particle at its exact moment inside the frame).
-- bias is a fixed distance toward the camera, see BIAS.
local P = { x = {}, y = {}, z = {}, vx = {}, vy = {}, vz = {}, s0 = {}, s1 = {}, age = {}, life = {}, kind = {}, tex = {},
            add = {}, rgb = {}, a = {}, drag = {}, grav = {}, rot = {}, spin = {}, bias = {} }
local PARTS = { P.x, P.y, P.z, P.vx, P.vy, P.vz, P.s0, P.s1, P.age, P.life, P.kind, P.tex, P.add, P.rgb, P.a, P.drag,
                P.grav, P.rot, P.spin, P.bias }
local nP = 0

-- Sprites are sorted back to front by view depth and two at the same depth keep their call order, which changes whenever a
-- particle is removed (the last one takes its slot): that is the flicker of sprites that fight over one depth. So each
-- particle is pulled a fixed, distinct distance toward the camera: a base per kind (sparks over bubbles over wisps over smoke,
-- always) and a per-particle fraction of BIAS_SPREAD from a golden-ratio sequence, which never repeats. The distances are tiny
-- against sprites 5 to 30 units wide, and they do not change from frame to frame, so nothing moves on screen.
local BIAS = { [0] = 0, 0.35, 1.25, 0.7, 1.0, 1.6 }      -- by kind: puff, wisp, spark, bubble, drop, glint
local BIAS_SPREAD = 0.3
local nextId = 0

local function rgb8(r, g, b)
    return (floor(clamp(r, 0, 1) * 255 + 0.5) << 24) | (floor(clamp(g, 0, 1) * 255 + 0.5) << 16) | (floor(clamp(b, 0, 1) * 255 + 0.5) << 8)
end

-- size is the half width at birth (s0) and death (s1). `soft` particles (the steady wisps) leave a quarter of the pool free
-- for the bursts and the sparks. delay (seconds, optional) holds the particle back before it is born. Returns the particle's
-- index (so the caller can adjust it), or false.
local function spawn(kind, tex, additive, x, y, z, vx, vy, vz, s0, s1, life, r, g, b, a, drag, grav, rot, spin, soft, delay)
    local pre = S.preset
    if not pre or not hasSprite or not tex then return false end
    if nP >= pre.pmax or (soft and nP >= pre.pmax * 0.75) then return false end
    nP = nP + 1
    local i = nP
    nextId = nextId + 1
    P.x[i], P.y[i], P.z[i], P.vx[i], P.vy[i], P.vz[i] = x, y, z, vx, vy, vz
    P.s0[i], P.s1[i], P.age[i], P.life[i], P.kind[i], P.tex[i] = s0, s1, -(delay or 0), life, kind, tex
    P.add[i], P.rgb[i], P.a[i], P.drag[i], P.grav[i], P.rot[i], P.spin[i] = additive, rgb8(r, g, b), a, drag, grav, rot or 0, spin or 0
    P.bias[i] = BIAS[kind] + ((nextId * 0.6180339887) % 1) * BIAS_SPREAD
    return i
end

-- A steady emitter's particle, placed at the moment inside the frame when it was due. `over` is how far the emitter's
-- accumulator is past the due moment (a fraction of a particle), `rate` the emitter's particles a second. The step that
-- follows ages the particle by a whole step, so its age is set to age0 - step and it comes out at age0: the time since it
-- was due. The stream therefore has no frame-sized lumps.
local function subframe(i, over, rate)
    if not i then return end
    local age0 = over / rate
    if age0 > curDt then age0 = curDt end
    P.age[i] = age0 - curDt
end

local function removeParticle(i)
    for k = 1, #PARTS do
        local arr = PARTS[k]
        arr[i] = arr[nP]
    end
    nP = nP - 1
end

-- The alpha envelope of a particle: eases in over tin seconds from birth (smoothstep) and eases out over the last `fout` of
-- its life (the fade starts flat and ends flat, so neither end shows as an edge).
local function envelope(age, life, tin, fout)
    local e = 1
    if age < tin then
        local u = age / tin
        e = u * u * (3 - 2 * u)
    end
    local v = (age / life - (1 - fout)) / fout
    if v > 0 then
        if v >= 1 then return 0 end
        e = e * (1 - v * v * (3 - 2 * v))
    end
    return e
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
    local cfx, cfy, cfz = CAM.fx, CAM.fy, CAM.fz
    -- The arrays as locals: a register read per access instead of a field lookup, which is a third of this loop's cost.
    local Px, Py, Pz, Pvx, Pvy, Pvz, Ps0, Ps1 = P.x, P.y, P.z, P.vx, P.vy, P.vz, P.s0, P.s1
    local Page, Plife, Pkind, Ptex, Padd, Prgb, Pa = P.age, P.life, P.kind, P.tex, P.add, P.rgb, P.a
    local Pdrag, Pgrav, Prot, Pspin, Pbias = P.drag, P.grav, P.rot, P.spin, P.bias
    for i = nP, 1, -1 do
        local age = Page[i] + dt
        local life = Plife[i]
        if age >= life then
            removeParticle(i)
        elseif age <= 0 then
            Page[i] = age                                               -- not born yet
        else
            Page[i] = age
            -- A particle born inside this step moves for the rest of it only.
            local step = dt
            if age < step then step = age end
            -- Drag and gravity integrated exactly over the step (v' = -d v + g), so the path does not depend on the step size.
            local vx, vy, vz = Pvx[i], Pvy[i], Pvz[i]
            local dr, gr = Pdrag[i], Pgrav[i]
            local x, y, z = Px[i], Py[i], Pz[i]
            if dr > 1e-4 then
                local e = exp(-dr * step)
                local f = (1 - e) / dr
                x, z = x + vx * f, z + vz * f
                vx, vz = vx * e, vz * e
                if gr ~= 0 then
                    local gd = gr / dr
                    -- v' = -d v + g (positive g lifts, as in the no-drag branch): v settles on the terminal speed g/d.
                    local vt = vy - gd
                    y = y + vt * f + gd * step
                    vy = vt * e + gd
                else
                    y = y + vy * f
                    vy = vy * e
                end
            else
                x, z = x + vx * step, z + vz * step
                y = y + vy * step + 0.5 * gr * step * step
                vy = vy + gr * step
            end
            Pvx[i], Pvy[i], Pvz[i], Px[i], Py[i], Pz[i] = vx, vy, vz, x, y, z

            local t = age / life
            local kind = Pkind[i]
            local a = Pa[i]
            local s0 = Ps0[i]
            local s = s0 + (Ps1[i] - s0) * t * (2 - t)                     -- eased out: grows fast, settles
            local hw                                                        -- the half width the sprite is drawn with (s unless set)
            local ax, ay, az, hl = 0, 0, 0, 0
            if kind == K_PUFF then
                -- Smoke blows up fast and then settles: the size follows sqrt(age), eased in over the first 0.2 s so that it
                -- does not start with a jump.
                local g = sqrt(t)
                if age < 0.2 then g = g * smooth(age * 5) end
                s = s0 + (Ps1[i] - s0) * g
                a = a * envelope(age, life, 0.15, 1)
                local rot = Prot[i] + Pspin[i] * step
                Prot[i] = rot
                if camOk then
                    local c, sn = cos(rot), sin(rot)
                    ax, ay, az, hl = rx * c + ux * sn, ry * c + uy * sn, rz * c + uz * sn, s
                end
            elseif kind == K_WISP then
                a = a * envelope(age, life, 0.35, 0.65)
                -- A slow sideways sway, zero at birth, on top of the rise.
                local ph = Prot[i]
                x = x + (sin(age * 2.3 + ph) - sin(ph)) * 1.6
                z = z + (cos(age * 1.9 + ph) - cos(ph)) * 1.6
                ax, ay, az, hl = -vx * 0.02, -1, -vz * 0.02, s * 2     -- the PNG is 1:2, its top row is the tail
            elseif kind == K_SPARK then
                a = a * envelope(age, life, 0.03, 1)
                -- kj_spark.png is a horizontal lens, long along u (the sprite's width), while the sprite's axis stretches v (the
                -- rows). So the streak runs along the width: halfW is the streak's half length, halfL its thin half thickness
                -- (the lens fills about a quarter of the rows), and the axis is turned a quarter turn from the velocity on screen
                -- (forward x velocity lies in the screen plane and is perpendicular to the projected velocity), which puts the
                -- width along the flight. The length is a smooth function of speed (about 0.05 of a unit per unit of speed,
                -- flattening toward 14): a spark that slows at the top of its arc shrinks to a dot, a fast one never hits a limit.
                local sp = sqrt(vx * vx + vy * vy + vz * vz)
                hw, hl = 1.2 + 12.8 * (1 - exp(-sp * 0.0039)), s * 2
                ax, ay, az = ux, uy, uz                                 -- no camera or a head-on spark: a level streak
                if camOk and sp > 1e-3 then
                    local qx, qy, qz = CAM.fy * vz - CAM.fz * vy, CAM.fz * vx - CAM.fx * vz, CAM.fx * vy - CAM.fy * vx
                    local ql = sqrt(qx * qx + qy * qy + qz * qz)
                    if ql > sp * 0.05 then ax, ay, az = qx / ql, qy / ql, qz / ql end
                end
            elseif kind == K_BUBBLE then
                -- A bubble eases in, holds, then pops: in the last 0.18 s it swells by a third while it fades out.
                local rem = life - age
                if rem < 0.18 then
                    local pop = smooth(1 - rem / 0.18)
                    a = a * (1 - pop)
                    s = s * (1 + 0.35 * pop)
                end
                if age < 0.2 then a = a * smooth(age * 5) end
                local ph = Prot[i]
                x = x + (sin(age * 4 + ph) - sin(ph)) * 1.2             -- zero at birth, so it does not jump
            elseif kind == K_DROP then
                a = a * envelope(age, life, 0.05, 0.6)
                if vx ~= 0 or vy ~= 0 or vz ~= 0 then ax, ay, az, hl = vx, vy, vz, s * 1.4 end
            else    -- K_GLINT
                a = a * envelope(age, life, life * 0.3, 0.7)
                local rot = Prot[i] + Pspin[i] * step
                Prot[i] = rot
                if camOk then
                    local c, sn = cos(rot), sin(rot)
                    ax, ay, az, hl = rx * c + ux * sn, ry * c + uy * sn, rz * c + uz * sn, s
                end
            end
            local a8 = floor(a * 255 + 0.5)
            if a8 > 0 and s > 0 then
                if a8 > 255 then a8 = 255 end
                local b = Pbias[i]
                sprite(Ptex[i], x - cfx * b, y - cfy * b, z - cfz * b, hw or s, hl, ax, ay, az, Prgb[i] | a8,
                       Padd[i] and "additive" or "alpha")
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

-- The game moves a worm 50 times a second (see wum.game.tick) and reports where it was at the last tick, so a position read
-- every frame advances in steps, and at 144 fps it stands still for two frames in three. Anything pinned to a worm (the acid
-- coat) would shudder with it. s.rx/ry/rz is the worm's position smoothed for drawing: it is carried forward at the speed the
-- reported position has been moving and pulled toward the report with a time constant of 1/FOLLOW second, so it never drifts.
-- The speed is measured from the reports (the engine's own velocity is zero while a worm walks) and low-passed over VEL_TAU
-- seconds, which evens out whole ticks arriving two to a frame or none. A jump of more than 40 units is a teleport or a
-- respawn, and is followed at once.
local VEL_TAU = 0.08

local function follow(s, x, y, z)
    local dt = curDt
    if not s.rx or s.px == nil then
        s.rx, s.ry, s.rz, s.evx, s.evy, s.evz = x, y, z, 0, 0, 0
        return
    end
    local dx, dy, dz = x - s.px, y - s.py, z - s.pz
    if dx * dx + dy * dy + dz * dz > 1600 then
        s.rx, s.ry, s.rz, s.evx, s.evy, s.evz = x, y, z, 0, 0, 0
        return
    end
    if dt <= 0 then return end
    local kv = 1 - exp(-dt / VEL_TAU)
    local ivd = 1 / dt
    s.evx, s.evy, s.evz = s.evx + (dx * ivd - s.evx) * kv, s.evy + (dy * ivd - s.evy) * kv, s.evz + (dz * ivd - s.evz) * kv
    local k = 1 - exp(-dt * COATK.FOLLOW)
    local rx, ry, rz = s.rx + s.evx * dt, s.ry + s.evy * dt, s.rz + s.evz * dt
    s.rx, s.ry, s.rz = rx + (x - rx) * k, ry + (y - ry) * k, rz + (z - rz) * k
end

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
            follow(s, x, y, z)
            s.px, s.py, s.pz, s.hp, s.alive, s.yaw, s.seen = x, y, z, health, alive, yaw or s.yaw or 0, FR.n
            local wid = tonumber(w.weapon)
            if wid and w.clone == "kWeaponGraveSpade" then wid = "spade" end
            s.weapon = wid
            s.aim = tonumber(w.aim)
            if wid and slot == ACT.slot then MEL.heldWeapon, MEL.heldSlot, MEL.heldAt = wid, slot, now end
        end
    end
end

-- ---------------------------------------------------------------- with Bloodsand and Sunstone
-- Kindjal's acid draws after Bloodsand's skin (51), guts (52) and gibs (53) and before Sunstone's occlusion (100) and grade
-- (300); its hit flash is Final 900, after both plugins' PostWorld effects, Bloodsand's lens splatter (60) and Sunstone's
-- lens finish (800). Nothing has to be configured: Melange lets a mod read every effect (wum.postfx.list: id, enabled, failed),
-- so the other plugins are found by their effect ids. Asked at the start, at a match edge, when the mod list changes and every
-- five seconds (the player can switch a mod or Sunstone's quality at any time). What is found changes four things:
--   Sunstone   p_compat 1 (the acid's skin test allows for Sunstone's tinted shade, see acid.frag) and the acid's opacity
--              x1.15: Sunstone's occlusion, haze and vignette darken and thin what is behind them, and at the subtle intensity
--              (0.55) that costs more than at the full one. The tonemap itself keeps hue and saturation (README).
--   Bloodsand  the hit flash at 0.6 of its peak, as Bloodsand throws its own red splat on the lens for a heavy hit near the
--              camera (the two together read as one red shock, not two); and no acid or wisps on a worm with no health left,
--              as Bloodsand gibs it: the body is blown apart and the vapour would rise from nothing.
-- Every id Kindjal switches or sets is "kindjal/...": the check below runs at load and turns the post-FX off rather than touch an
-- effect that is not its own (Melange refuses it as well).
local COMPAT = { bloodsand = false, sunstone = false, nextAt = 0, STRENGTH = 1.15, FLASH = 0.6, EVERY = 5 }

for _, id in ipairs({ FXA.id, FXH.id, table.unpack(WARM.ids) }) do
    if string.sub(id, 1, 8) ~= "kindjal/" then
        hasPostfx = false
        log("kindjal: post-FX id " .. id .. " is not namespaced kindjal/, so the post-FX are off")
    end
end

function COMPAT.probe()
    COMPAT.nextAt = os.clock() + COMPAT.EVERY
    if not (wum.postfx and wum.postfx.list) then return end
    local ok, list = pcall(wum.postfx.list)
    if not ok or type(list) ~= "table" then return end
    local bs, ss = false, false
    for i = 1, #list do
        local e = list[i]
        if type(e) == "table" and type(e.id) == "string" and e.failed ~= true then
            -- Bloodsand turns its effects on and off as the gore needs them, so being listed is what counts. Sunstone's
            -- effects are on for as long as its quality setting uses them (any of them means its lighting is on too).
            if string.sub(e.id, 1, 10) == "bloodsand/" then bs = true end
            if string.sub(e.id, 1, 9) == "sunstone/" and e.enabled == true then ss = true end
        end
    end
    COMPAT.bloodsand, COMPAT.sunstone = bs, ss
    if not COMPAT.primed then
        COMPAT.primed = true
        COMPAT.k = ss and 1 or 0
    end
end

function COMPAT.poll()
    if os.clock() >= COMPAT.nextAt then COMPAT.probe() end
end

-- The acid effect's opacity for a preset strength, and its p_compat. Both follow COMPAT.k, which eases to 1 (Sunstone found) or 0
-- over EASE seconds instead of jumping, because the probe can notice a switch up to EVERY seconds late and a coated worm would
-- then change its skin mask and opacity in one frame. k is sent in steps of 1/256, like the coat levels. The first probe sets
-- it directly, so Sunstone already running at load does not fade in.
COMPAT.k, COMPAT.primed, COMPAT.EASE = 0, false, 0.3
function COMPAT.ease(dt)
    local target = COMPAT.sunstone and 1 or 0
    if not COMPAT.primed then return end
    local step = dt / COMPAT.EASE
    if COMPAT.k < target then COMPAT.k = min(target, COMPAT.k + step)
    elseif COMPAT.k > target then COMPAT.k = max(target, COMPAT.k - step) end
end
function COMPAT.strength(base) return min(1, base * (1 + (COMPAT.STRENGTH - 1) * floor(COMPAT.k * 256 + 0.5) / 256)) end
function COMPAT.compat() return floor(COMPAT.k * 256 + 0.5) / 256 end
-- Sunstone's Worm skin: each slot's skin brightness against the game's peach (1 without it), as Sunstone tells it in the
-- event mod.sunstone.skin; the acid is lit by it on a darker skin (see acid.frag's p_tone0..3). And how the skin is found
-- (sunskin, acid.frag's p_sunskin): 0 by its colour, 1 or 2 by its colour or Sunstone's mark (Sunstone marks the game's
-- peach too while its lit-model shader runs; 2: it re-tones the skin or draws the hair). The colour test always stays,
-- so the peach is still found if Sunstone's shader does not run.
COMPAT.tone, COMPAT.TN, COMPAT.sunskin = {}, { [0] = "tone0", "tone1", "tone2", "tone3" }, 0
function COMPAT.hearSkin(p)
    local t = {}
    local mode = 0
    if type(p) == "table" then
        if p.on == true and type(p.lum) == "table" then
            for i = 1, SLOTS do
                local v = tonumber(p.lum[i])
                t[i] = (v and v > 0.02 and v < 4) and floor(v * 256 + 0.5) / 256 or 1
            end
        end
        if p.marks == true then mode = (p.on == true or p.hair == true) and 2 or 1 end
    end
    COMPAT.tone = t
    COMPAT.sunskin = mode
end
-- The factor on the hit flash's peak.
function COMPAT.flash() return COMPAT.bloodsand and COMPAT.FLASH or 1 end
-- True for a worm Bloodsand has blown apart (or is about to): its health is gone, whatever its alive flag still says.
function COMPAT.gibbed(s) return COMPAT.bloodsand and (tonumber(s.hp) or 1) <= 0 end

-- Is a coated worm anywhere near the screen? The acid pass is a full-screen pass, so it is left off while every coated worm is
-- far outside the view (a worm coated for 70 s can be off screen for most of that). Asked four times a second, and it stays on
-- for two seconds after the last time one was in view, so panning back and forth does not switch the effect on and off (Melange
-- saves that switch). When the view cannot be worked out it says yes.
local VIS = { at = -100, last = -100 }

function COMPAT.coatInView(coat)
    if not (wum.render and wum.render.worldToScreen and wum.render.windowSize) then return true end
    if now - VIS.at >= 0.25 then
        VIS.at = now
        local okw, w, h = pcall(wum.render.windowSize)
        if not okw or type(w) ~= "number" or type(h) ~= "number" or w <= 0 or h <= 0 then return true end
        local margin = 0.5 * h              -- a worm is under 100 pixels tall unless zoomed in; half a window is generous
        for slot in pairs(coat) do
            local s = W[slot]
            if not s then
                VIS.last = now              -- no position yet: assume in view
            else
                local ok, sx, sy = pcall(wum.render.worldToScreen, { x = s.px, y = s.py + CENTRE_Y, z = s.pz })
                if not ok then
                    VIS.last = now
                elseif type(sx) == "number" and type(sy) == "number" and sx > -margin and sx < w + margin and sy > -margin and sy < h + margin then
                    VIS.last = now
                end                         -- nil: behind the camera
            end
        end
    end
    return now - VIS.last < 2
end

-- ---------------------------------------------------------------- acid coat
-- COAT[slot] = { t0 (spread clock), tl (level clock), kind, seed, cx, cy, cz (the position last sent), placed, wrate, wacc }.
-- The level and the spread are exact, continuous functions of the clocks (LV, SP hold the current values), packed four slots to
-- a vec4 (slot = 4k + i) and sent when they have moved by SEND_EPS or after SEND_EVERY seconds (see `moved`).
local COAT = {}
local CS = { n = 0 }
local LV, SP = {}, {}
local GRP = { [0] = { dirty = false, lvAt = -100, spAt = -100 }, { dirty = false, lvAt = -100, spAt = -100 },
              { dirty = false, lvAt = -100, spAt = -100 }, { dirty = false, lvAt = -100, spAt = -100 } }
for i = 0, SLOTS - 1 do LV[i], SP[i] = 0, 0 end

-- Rise on a smoothstep, hold, and a long fade that leaves the hold and arrives at nothing with no slope at either end, so
-- there is no visible corner anywhere on the curve.
local function coatLevel(a)
    if a <= 0 then return 0 end
    if a < COATK.RAMP then return smooth(a / COATK.RAMP) end
    if a < COATK.HOLD_END then return 1 end
    if a < COATK.FADE_END then return 1 - smooth((a - COATK.HOLD_END) / (COATK.FADE_END - COATK.HOLD_END)) end
    return 0
end

-- The spread accelerates away from the first spots and settles into the full coat (a smoothstep between the two).
local function coatSpread(a)
    if a >= COATK.SPREAD_SECS then return 1 end
    return COATK.SPREAD_FROM + (1 - COATK.SPREAD_FROM) * smooth(a / COATK.SPREAD_SECS)
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
    -- wrate: this coat's wisps a second at full level, chosen once (a rate redrawn every frame would be noise, not a rate).
    COAT[slot] = { t0 = now, tl = now, kind = kind, seed = random(0, 1000), placed = false, wrate = rnd(4, 6), wacc = 0,
                   cx = 0, cy = 0, cz = 0 }
    CS.n = CS.n + 1
    GRP[slot >> 2].dirty = true
end

local function coatRemove(slot)
    if COAT[slot] then
        COAT[slot] = nil
        CS.n = CS.n - 1
        GRP[slot >> 2].dirty = true         -- the next send puts its zeros out
    end
    LV[slot], SP[slot] = 0, 0
end

-- Wisps of vapour rise from the surface of a coated worm: thin curls, additive, green-grey. They start nearly at rest and
-- are carried up by a lift that the drag balances (a terminal speed of 20 to 33 a second, reached over about a second), so the
-- velocity eases in instead of starting at full speed.
local function spawnWisp(cx, cy, cz, over, rate)
    local a = rnd(0, 2 * pi)
    local i = spawn(K_WISP, WISP_T[random(1, 2)], true, cx + cos(a) * 6, cy + rnd(-8, 9), cz + sin(a) * 6,
                    cos(a) * 1.5 + rnd(-2, 2), rnd(5, 10), sin(a) * 1.5 + rnd(-2, 2), rnd(3.5, 5), rnd(5.5, 8), rnd(1.4, 2.4),
                    rnd(0.38, 0.5), rnd(0.55, 0.68), rnd(0.25, 0.34), rnd(0.4, 0.55), 0.9, rnd(18, 30), rnd(0, 2 * pi), 0, true)
    subframe(i, over, rate)
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
    local eps, every = COATK.SEND_EPS, COATK.SEND_EVERY
    local l1, l2, l3, l4 = LV[b], LV[b + 1], LV[b + 2], LV[b + 3]
    if free or moved(FXA, LN[k], eps, every, g.lvAt, l1, l2, l3, l4) then
        if sendVec4(FXA, LN[k], l1, l2, l3, l4, free) then g.lvAt = now end
    end
    local s1, s2, s3, s4 = SP[b], SP[b + 1], SP[b + 2], SP[b + 3]
    if free or moved(FXA, SN[k], eps, every, g.spAt, s1, s2, s3, s4) then
        if sendVec4(FXA, SN[k], s1, s2, s3, s4, free) then g.spAt = now end
    end
    g.dirty = any
end

local function coatUpdate(dt)
    local pre = S.preset
    local nc = max(1, CS.n)
    COMPAT.ease(dt)
    TOK.v = min(max(12, COATK.TOKENS * nc * 0.1), TOK.v + dt * COATK.TOKENS * nc)
    local emitting = 0
    for slot, c in pairs(COAT) do
        local s = W[slot]
        local la = now - c.tl
        if not pre or not s or s.seen ~= FR.n or not s.alive or COMPAT.gibbed(s) or la >= COATK.FADE_END then
            coatRemove(slot)
        else
            local lv, sp = coatLevel(la), coatSpread(now - c.t0)
            LV[slot], SP[slot] = lv, sp
            local x, y, z = s.rx, s.ry + CENTRE_Y, s.rz
            -- The centre follows the worm continuously; it is only held back while the worm has moved less than POS_EPS.
            local dx, dy, dz = x - c.cx, y - c.cy, z - c.cz
            if not c.placed or dx * dx + dy * dy + dz * dz > COATK.POS_EPS * COATK.POS_EPS then
                c.cx, c.cy, c.cz, c.placed = x, y, z, true
            end
            if S.smoke and lv > 0.002 and emitting < COATK.WISP_CAP then
                emitting = emitting + 1
                local rate = c.wrate * lv * pre.rate
                c.wacc = c.wacc + dt * rate
                while c.wacc >= 1 do
                    c.wacc = c.wacc - 1
                    spawnWisp(x, y, z, c.wacc, rate)
                end
            end
        end
    end

    -- What the shader gets: worm centres, then the packed levels and spreads. A group that has just emptied sends its zeros
    -- (free of the token bucket) and then goes quiet.
    for k = 0, 3 do sendGroup(k) end
    if CS.n > 0 and pre then
        sendParam(FXA, "seed", S.seed, nil, nil, true)
        sendParam(FXA, "strength", COMPAT.strength(pre.strength), nil, nil, true)
        sendParam(FXA, "compat", COMPAT.compat(), nil, nil, true)
        local t = COMPAT.tone
        for k = 0, 3 do
            sendVec4(FXA, COMPAT.TN[k], t[4 * k + 1] or 1, t[4 * k + 2] or 1, t[4 * k + 3] or 1, t[4 * k + 4] or 1, true)
        end
        sendParam(FXA, "sunskin", COMPAT.sunskin, nil, nil, true)
    end
    sendEnabled(FXA, CS.n > 0 and pre ~= nil and COMPAT.coatInView(COAT))
end

-- ---------------------------------------------------------------- puddles
-- A puddle lies on the ground where the acid came down: grows for a second, holds about twelve seconds, shrinks over eight and
-- smokes while it lasts. At most three; a fourth replaces the oldest. A blood pool (p.blood, where the Buddy Bomb went off)
-- is the same puddle in dark red, silent and without smoke, and drawn whatever the smoke setting says.
local PUD = {}
local PK = { MAX = 3, GROW = 1, HOLD = 12, SHRINK = 8, MIN_NY = 0.766 }      -- 0.766 is cos(40 degrees)
local nPuddles = 0

local function puddleEnd(p)
    stopVoice(p.voice)
    p.voice = nil
end

-- It spreads out fast and eases to its full size (ease-out), and shrinks slowly at first and then faster (ease-in).
local function puddleScale(age)
    if age < PK.GROW then
        local u = 1 - age / PK.GROW
        return 1 - u * u * u
    end
    if age < PK.GROW + PK.HOLD then return 1 end
    local u = (age - PK.GROW - PK.HOLD) / PK.SHRINK
    if u >= 1 then return 0 end
    return 1 - u * u
end

local function puddleAdd(x, y, z, r, blood)
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
    nPuddles = nPuddles + 1
    local p = { x = x, y = py, z = z, nx = nx, ny = ny, nz = nz, R = clamp(r * 0.5, 18, 46), t0 = now, wacc = 0, wrate = rnd(2, 4), bias = (nPuddles % 6) * 0.15 }
    if blood then
        p.blood = true
    else
        p.voice = play("acid_hiss", 0.35, x, py + 2, z, true)
    end
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
    -- p.bias: a puddle on top of an older one is a fixed fraction of a unit nearer, so stacked puddles never fight over a depth.
    push = push + p.bias
    local cx, cy, cz = p.x + nx * 0.6 - CAM.fx * push, p.y + ny * 0.6 - CAM.fy * push, p.z + nz * 0.6 - CAM.fz * push
    local a8 = floor(clamp(alpha, 0, 1) * 255 + 0.5)
    if a8 <= 0 then return end
    local sprite = wum.draw.sprite
    sprite(TEX.puddle1, cx, cy, cz, halfW, R, tx, ty, tz, (p.blood and rgb8(0.30, 0.015, 0.025) or rgb8(0.36, 0.58, 0.09)) | a8,
           "alpha")
    if TEX.puddle2 then
        -- The shine layer sits a fixed half unit nearer the camera, so the two never fight over one depth. Blood throws the
        -- ragged splash wider than the pool under it.
        local b8 = floor(a8 * (p.blood and 0.85 or 0.6))
        local k = p.blood and 1.25 or 0.72
        sprite(TEX.puddle2, cx + tx * R * 0.1 - CAM.fx * 0.5, cy + ty * R * 0.1 - CAM.fy * 0.5, cz + tz * R * 0.1 - CAM.fz * 0.5,
               halfW * k, R * k, tx, ty, tz, (p.blood and rgb8(0.52, 0.03, 0.04) or rgb8(0.62, 0.84, 0.16)) | b8, "alpha")
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
        elseif p.blood then
            puddleDraw(p, 0.15 + 0.85 * sc, smooth(sc * 1.5) * 0.85)
        else
            if S.smoke then
                puddleDraw(p, 0.15 + 0.85 * sc, smooth(sc * 1.5) * 0.62)
                -- The smoke thickens as the puddle spreads and thins as it shrinks, with no threshold to cross.
                local rate = p.wrate * smooth((sc - 0.15) / 0.6) * pre.rate
                if rate > 0 then
                    p.wacc = p.wacc + dt * rate
                    while p.wacc >= 1 do
                        p.wacc = p.wacc - 1
                        local a, d = rnd(0, 2 * pi), rnd(0, 0.6) * p.R * sc
                        local j = spawn(K_WISP, WISP_T[random(1, 2)], true, p.x + cos(a) * d + p.nx * 2, p.y + p.ny * 2, p.z + sin(a) * d + p.nz * 2,
                                        rnd(-2, 2), rnd(5, 10), rnd(-2, 2), rnd(3.5, 5), rnd(6, 9), rnd(1.6, 2.6),
                                        rnd(0.38, 0.5), rnd(0.6, 0.72), rnd(0.22, 0.3), rnd(0.35, 0.5), 0.9, rnd(16, 26), rnd(0, 2 * pi), 0, true)
                        subframe(j, p.wacc, rate)
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
        -- Each puff is born up to 0.12 s apart, so the cloud billows out instead of appearing in one frame.
        spawn(K_PUFF, SMOKE_T[random(1, 3)], true, x + cos(a) * d, y + rnd(0, 10), z + sin(a) * d,
              rnd(-12, 12), rnd(8, 26), rnd(-12, 12), rnd(5, 9), rnd(16, 30), rnd(3, 6),
              rnd(0.5, 0.7), rnd(0.75, 0.9), rnd(0.1, 0.22), rnd(0.14, 0.24), 0.5, 0, rnd(0, 2 * pi), rnd(-0.6, 0.6), false,
              rnd(0, 0.12))
    end
    for _ = 1, floor(rnd(10, 15) * R + 0.5) do
        local a, d = rnd(0, 2 * pi), rnd(0, 1) * spread
        spawn(K_BUBBLE, TEX.bubble, false, x + cos(a) * d, y + rnd(0, 6), z + sin(a) * d,
              rnd(-3, 3), rnd(8, 16), rnd(-3, 3), rnd(1.5, 3.5), rnd(2, 4.5), rnd(2, 4),
              0.72, 1, 0.6, rnd(0.55, 0.8), 0.2, 0, rnd(0, 6), 0, false, rnd(0, 0.2))
    end
    -- Drops thrown up and out, falling back.
    if TEX.drop then
        for _ = 1, floor(rnd(8, 12) * R + 0.5) do
            local a, sp = rnd(0, 2 * pi), rnd(30, 90)
            spawn(K_DROP, TEX.drop, false, x, y + 4, z, cos(a) * sp, rnd(80, 170), sin(a) * sp, rnd(1.1, 2), rnd(0.8, 1.4),
                  rnd(0.7, 1.2), 0.5, 0.9, 0.14, 0.9, 0, -300, 0, 0, false, rnd(0, 0.04))
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
        spawn(K_PUFF, SMOKE_T[random(1, 3)], false, x + c * r * 0.12, y + rnd(2, 8), z + s * r * 0.12,
              c * sp, rnd(6, 20), s * sp, rnd(10, 14), rnd(30, 40), rnd(3, 5),
              rnd(0.14, 0.2), rnd(0.12, 0.16), rnd(0.1, 0.13), rnd(0.45, 0.6), 0.9, 0, rnd(0, 2 * pi), rnd(-0.5, 0.5), false,
              rnd(0, 0.08))
    end
    for _ = 1, floor(5 * R + 0.5) do
        spawn(K_PUFF, SMOKE_T[random(1, 3)], true, x + rnd(-12, 12), y + rnd(2, 14), z + rnd(-12, 12),
              rnd(-10, 10), rnd(30, 60), rnd(-10, 10), rnd(14, 20), rnd(45, 70), rnd(0.5, 0.9),
              1, rnd(0.45, 0.6), 0.14, rnd(0.4, 0.55), 1.2, 0, rnd(0, 2 * pi), rnd(-1, 1), false, rnd(0, 0.05))
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
-- The flash is a pulse: a quick smoothstep rise (FLASH_RISE), then an ease-out to nothing over FLASH_SECS, so there is no hard
-- cut at either end. Two pulses can overlap (the later one does not cut the earlier one short); the screen shows the higher.
-- The vignette stays on the victim: the pulse remembers whose hit it was and follows that worm on the screen.
local HF = { on = false, u = 0.5, v = 0.5, last = 0, w = 1920, h = 1080, slot = nil,
             { t0 = -100, peak = 0 }, { t0 = -100, peak = 0 }, next = 1 }
local FLASH_SECS, FLASH_RISE, FLASH_EPS = 0.25, 0.04, 1 / 512
-- The rise and the fall overlap, so their product tops out at 0.708 of the peak (at about 0.037 s); this gain brings the
-- highest point of the flash back to exactly the peak.
local FLASH_GAIN = 1.412

local function flashCurve(age, peak)
    if age <= 0 or age >= FLASH_SECS then return 0 end
    local fall = 1 - age / FLASH_SECS
    return peak * FLASH_GAIN * smooth(age / FLASH_RISE) * fall * fall
end

local function flashCentre(vx, vy, vz)
    local ok, sx, sy = pcall(wum.render.worldToScreen, { x = vx, y = vy, z = vz })
    if not ok or type(sx) ~= "number" or type(sy) ~= "number" then return false end
    -- The shader's uv has its origin at the bottom left; window pixels count from the top left.
    HF.u, HF.v = clamp(sx / HF.w, 0, 1), clamp(1 - sy / HF.h, 0, 1)
    return true
end

local function startFlash(vx, vy, vz, dmg, slot)
    if not (hasPostfx and wum.render and wum.render.worldToScreen and wum.render.windowSize) then return end
    local okw, w, h = pcall(wum.render.windowSize)
    if not okw or type(w) ~= "number" or type(h) ~= "number" or w <= 0 or h <= 0 then return end
    HF.w, HF.h = w, h
    if not flashCentre(vx, vy, vz) then return end
    local pulse = HF[HF.next]
    HF.next = 3 - HF.next
    pulse.t0 = now
    pulse.peak = clamp(dmg, 10, 50) / 50 * 0.35 * S.preset.strength * COMPAT.flash()
    HF.on, HF.slot = true, slot
    sendParam(FXH, "center", HF.u, HF.v, nil, true)
end

local function hitUpdate()
    if HF.on then
        local f = max(flashCurve(now - HF[1].t0, HF[1].peak), flashCurve(now - HF[2].t0, HF[2].peak))
        local live = S.preset and (now - HF[1].t0 < FLASH_SECS or now - HF[2].t0 < FLASH_SECS)
        if not live then
            HF.on, HF.last = false, 0
            sendParam(FXH, "flash", 0, nil, nil, true)
        else
            -- The vignette follows the victim (smoothed position, so it does not shudder with the game's ticks).
            local s = HF.slot and W[HF.slot]
            if s and s.seen == FR.n and s.rx then
                local u0, v0 = HF.u, HF.v
                if flashCentre(s.rx, s.ry + CENTRE_Y, s.rz) and (abs(HF.u - u0) > 1e-4 or abs(HF.v - v0) > 1e-4) then
                    sendParam(FXH, "center", HF.u, HF.v, nil, true)
                end
            end
            -- Continuous, sent when it has moved by 1/512 (the flash peaks at 0.35, so that is half a percent of it at most).
            if abs(f - HF.last) > FLASH_EPS or not FXH.cache.flash then
                HF.last = f
                sendParam(FXH, "flash", f, nil, nil, true)
            end
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
        startFlash(vx, vy, vz, dmg, vSlot)
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

-- ---------------------------------------------------------------- the Buddy Bomb
-- The sheep's slot is a labradoodle with dynamite on its back (sim/main.lua). The game says two things about it: Weapon.Fired
-- while the active worm holds weapon 15 (the Sheep) when the dog is let go, and an Explosion with the Buddy Bomb's own
-- WormDamageRadius (160, no other weapon has it) when it goes off. In between it barks every second or two. It yelps just
-- before its fuse (the Sheep's LifeTime, 30 s) runs out; set off early with a second press of fire it yelps at that press if
-- the game reports the press as Weapon.Fired, and otherwise at the blast. The game gives no position for a walking payload,
-- and the sheep's chase camera keeps the dog in the middle of the screen, so the barks are not placed in the world; the yelp
-- at the blast and the gibs are. He falls quiet the moment he touches water: the game posts Payload.CollideWithWater at the
-- splash and Payload.Sunk only once he is under (up to 1.5 s later in a test, long enough for another bark), so the splash
-- stops the barks and cuts off one still playing; Payload.Sunk and the disarm plane stay as a backstop. Payload.BigJump (a
-- hop, when the vanilla sheep baas) is listened to as well; the game did not post it in tests, so nothing is lost.
local BUDDY = { WEAPON = 15, RADIUS = 160, FUSE = 30, YELP_LEAD = 0.8, QUIET = 1.2,
                live = false, t0 = -100, nextBark = 0, lastBark = -100, yelpedAt = -100, preYelp = false, voice = nil }

local function buddyBark()
    local t = os.clock()
    BUDDY.lastBark = t
    BUDDY.nextBark = t + rnd(1.0, 1.9)
    BUDDY.voice = play(random() < 0.6 and "bark" or "bark2", 0.7)
end

local function buddyYelp(x, y, z)
    local t = os.clock()
    if t - BUDDY.yelpedAt < 1.5 then return end
    BUDDY.yelpedAt = t
    play("yelp", 0.9, x, y, z)
end

local function buddyFired()
    local t = os.clock()
    BUDDY.live, BUDDY.t0, BUDDY.preYelp = true, t, false
    BUDDY.nextBark = t + 0.35
end

local function buddyStop()
    BUDDY.live = false
end

local function buddyUpdate(t)
    if not BUDDY.live then return end
    local age = t - BUDDY.t0
    if age > BUDDY.FUSE + 2 then
        buddyStop()                                     -- sunk, or the blast was missed: give up quietly
        return
    end
    if not BUDDY.preYelp and age >= BUDDY.FUSE - BUDDY.YELP_LEAD then
        BUDDY.preYelp = true
        buddyYelp()
    end
    if age < BUDDY.FUSE - BUDDY.QUIET and t >= BUDDY.nextBark then buddyBark() end
end

-- What is left of the dog: black tufts of fur, a red mist, a wide spray of blood with heavy gouts in it, and a pool of blood
-- on the ground under the blast, the drops thrown up and out and falling back. About 90 particles at the full intensity (half
-- at the subtle one), a burst and not a stream, so it stays well inside the pool of 400. Worms caught in the blast are
-- Bloodsand's to gib; this is only the dog, which Bloodsand does not know about, so his blood is drawn with Bloodsand too. With
-- it the burst is trimmed by a fifth: Bloodsand's own gibs of the worms caught in the same blast fill the screen as well.
local function buddyGibs(x, y, z)
    local pre = S.preset
    if not pre then return end
    local R = pre.rate * (COMPAT.bloodsand and 0.8 or 1)
    for _ = 1, floor(rnd(14, 20) * R + 0.5) do
        local a, sp = rnd(0, 2 * pi), rnd(50, 150)
        spawn(K_PUFF, SMOKE_T[random(1, 3)], false, x + rnd(-6, 6), y + rnd(2, 10), z + rnd(-6, 6),
              cos(a) * sp, rnd(90, 210), sin(a) * sp, rnd(2.5, 4), rnd(5, 8), rnd(1.4, 2.2),
              rnd(0.10, 0.16), rnd(0.10, 0.16), rnd(0.11, 0.18), rnd(0.75, 0.9), 1.0, -160, rnd(0, 2 * pi), rnd(-3, 3), false,
              rnd(0, 0.05))
    end
    -- the red mist: a few dark red puffs that billow out of the blast and hang for a moment
    for _ = 1, floor(rnd(6, 9) * R + 0.5) do
        local a, sp = rnd(0, 2 * pi), rnd(20, 70)
        spawn(K_PUFF, SMOKE_T[random(1, 3)], false, x + rnd(-8, 8), y + rnd(4, 16), z + rnd(-8, 8),
              cos(a) * sp, rnd(20, 60), sin(a) * sp, rnd(5, 8), rnd(16, 26), rnd(1.2, 1.9),
              rnd(0.42, 0.55), rnd(0.02, 0.05), rnd(0.03, 0.06), rnd(0.5, 0.65), 2.2, -12, rnd(0, 2 * pi), rnd(-1, 1), false,
              rnd(0, 0.06))
    end
    if TEX.drop then
        -- the spray: many small, fast drops, the first ones out a little ahead of the rest
        for _ = 1, floor(rnd(36, 46) * R + 0.5) do
            local a, sp = rnd(0, 2 * pi), rnd(50, 230)
            spawn(K_DROP, TEX.drop, false, x + rnd(-3, 3), y + 6, z + rnd(-3, 3), cos(a) * sp, rnd(110, 300), sin(a) * sp,
                  rnd(1.0, 2.0), rnd(0.8, 1.4), rnd(0.9, 1.5), rnd(0.45, 0.62), 0.02, 0.03, 0.95, 0, -320, 0, 0, false,
                  rnd(0, 0.06))
        end
        -- heavy gouts, slower and bigger
        for _ = 1, floor(rnd(10, 14) * R + 0.5) do
            local a, sp = rnd(0, 2 * pi), rnd(30, 120)
            spawn(K_DROP, TEX.drop, false, x, y + 6, z, cos(a) * sp, rnd(140, 280), sin(a) * sp, rnd(2.8, 4.2),
                  rnd(2.4, 3.4), rnd(1.2, 1.8), rnd(0.3, 0.42), 0.03, 0.05, 1, 0, -360, 0, 0, false, rnd(0, 0.05))
        end
    end
    puddleAdd(x, y, z, 84, true)                        -- the pool: R 42, the splash round it wider
end

-- A few little hearts float up where he is set down, pink and red, swaying as they rise and popping at the top: whatever is
-- strapped to him, he is a good boy. Up to eight at the full intensity, staggered so they rise as a short stream.
function BUDDY.hearts(x, y, z)
    local pre = S.preset
    if not (pre and TEX.heart) then return end
    for k = 1, max(3, floor(rnd(6, 8) * pre.rate + 0.5)) do
        local pink = random() < 0.6
        spawn(K_BUBBLE, TEX.heart, false, x + rnd(-7, 7), y + CENTRE_Y + rnd(-4, 6), z + rnd(-7, 7),
              rnd(-6, 6), rnd(18, 30), rnd(-6, 6), rnd(1.8, 2.6), rnd(2.8, 3.8), rnd(1.7, 2.5),
              pink and 1 or 0.92, pink and 0.42 or 0.14, pink and 0.62 or 0.26, 0.95, 0.9, 10, rnd(0, 2 * pi), 0, false,
              (k - 1) * 0.12 + rnd(0, 0.06))
    end
end

-- ---------------------------------------------------------------- explosives
local EXPL = { t0 = -100, n = 0 }

local function onExplosion(p)
    if type(p) ~= "table" then return end
    local x, y, z = vec(p.damageEpicentre)
    if not x then return end
    local t = os.clock()
    local wr = tonumber(p.wormDamageRadius)
    if wr and abs(wr - BUDDY.RADIUS) < 0.5 then
        buddyStop()
        buddyYelp(x, y + CENTRE_Y, z)
        buddyGibs(x, y, z)
    end
    if t - EXPL.t0 >= 1 then EXPL.t0, EXPL.n = t, 0 end
    if EXPL.n >= 6 then return end
    EXPL.n = EXPL.n + 1
    local wd = tonumber(p.wormDamage) or 0
    local name = wd >= 60 and "boom_large" or (wd >= 35 and "boom_med" or "boom_small")
    play(name, clamp(wd / 100, 0.4, 1.2), x, y, z)
end

local function onFired()
    local t = os.clock()
    -- A press of fire while the dog is walking sets it off (the Sheep detonates on a fire press): the yelp goes now.
    if BUDDY.live and t - BUDDY.t0 > 0.4 then
        buddyYelp()
        return
    end
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
    elseif wid == BUDDY.WEAPON then
        buddyFired()                                    -- no launch thump: he is set down, not shot
        if s then BUDDY.hearts(s.px, s.py, s.pz) end
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
-- Menu items and one event ("mod.kindjal.preview", p.what = "acid" | "melee" | "age") for the test harness. The acid lands on
-- the worm nearest the active one; with p.target = "active" on the active worm itself (the one the camera can be turned to).
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

local function previewAcid(target)
    local v, a = previewTarget()
    if target == "active" and a and W[a] and W[a].alive then v = a end
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

-- ---------------------------------------------------------------- the Grave Spade's particles
-- (Was client/spade_fx.lua: mods have no require, so it lives here in its own function scope, one local.)
local SpadeFX = (function()
    -- Grave Spade FX: every dirt, dust, spark and gore particle of the spade, plus a camera-shake helper.
    --
    -- Client only (Lua 5.4 sandbox), so nothing here can desync: it reads the camera and casts land rays, and draws sprites.
    -- Mods have no `require`, so this file is a chunk that ends in `return M`. Use it from init.lua by pasting it inside
    --     local SpadeFX = (function() ... this file ... end)()
    -- (one function scope, so it adds one local to init.lua's 200 limit), or by building init.lua from the two files.
    -- It brings its own particle pool, its own world callback (drawn at "worldLate") and its own timing, and it loads its
    -- textures itself (textures/kj_dirt1..4, kj_dust1..2, kj_stonechip, kj_bloodmist, kj_gore_chunk, kj_spark, kj_glint).
    -- Everything is a no-op if wum.draw.sprite or a texture is missing; a bad call never raises.
    --
    -- Units are world units (a worm is about 20 high). Directions (dx, dy, dz) need not be unit length. Colours are
    -- 0xRRGGBB. `material` is "soil", "sand", "stone" or "building" (anything else is soil).
    --
    --   M.scoop(x, y, z, dx, dy, dz, material, power)   one scoop: clods, dust, chips and sparks. (dx,dy,dz) is the blade's
    --                                                   travel; power 0.3..2, default 1
    --   M.dig(id, x, y, z, dx, dy, dz, material, power) call every frame while fire is held: a continuous spray. `id` is any
    --                                                   string or number (one stream per worm); stops by itself 0.15 s after
    --                                                   the last call, with a final settle puff
    --   M.digStop(id)                                   end a stream now
    --   M.settle(x, y, z, radius, material)             dust that hangs over a fresh cut, spreads along the floor, and
    --                                                   thins out over several seconds, with fine grains falling through it
    --   M.sparks(x, y, z, dx, dy, dz, n, material)      blade sparks (stone and building) with a glint; (dx,dy,dz) is the
    --                                                   direction the sparks fly, n defaults to 10
    --   M.headOff(x, y, z, dx, dz, opts)                the decapitation without Bloodsand: a shock ring of dust, a sand and
    --                                                   dust fountain from the neck, and flung grit. opts: {blood = true}
    --                                                   adds mist and gore chunks (only when Bloodsand is off and you still
    --                                                   want a red result), {scale = 1}
    --   M.shake(amount, seconds)                        start or add to a camera shake (amount in world units, 0.5..6)
    --   M.shakeOffset()                                 -> ox, oy, oz for this frame (0,0,0 when still)
    --   M.shakeCam(spec)                                adds the shake to a wum.render.cameraOverride spec ({pos,target,...},
    --                                                   tables {x,y,z} or {x=,y=,z=}) and returns it
    --   M.clear()  M.count()  M.setQuality(0..1)  M.ready()  M.preview(x, y, z)

    local M = {}

    local floor, sqrt, sin, cos, exp, abs, max, min = math.floor, math.sqrt, math.sin, math.cos, math.exp, math.abs, math.max, math.min
    local random = math.random

    -- ---------------------------------------------------------------- tunables
    local CFG = {
        maxParticles = 700,
        gravity = 360,            -- world units a second squared for clods
        rayCap = 20,              -- land rays this module casts a frame (Melange's 256 is shared by every mod)
        quality = 1.0,            -- scales particle counts; see M.setQuality
        streamRate = 46,          -- clods a second while digging, at power 1 (dust and sparks follow it)
        streamTimeout = 0.15,
        maxDt = 1 / 15,
    }

    -- tint colours (0xRRGGBB) per material: clods, dust, and the grit that the sparks come from
    local MAT = {
        soil     = { clod = { 0x6b4a2c, 0x5a3d24, 0x7c5733, 0x4e3620 }, dust = 0x9a7a55, chip = 0x7a5a3a, sparks = 0 },
        sand     = { clod = { 0xc8a868, 0xb89858, 0xd4b878, 0xa88c50 }, dust = 0xd8c08a, chip = 0xc8a868, sparks = 0 },
        stone    = { clod = { 0x8a8a86, 0x75756f, 0x9c9a92, 0x66665f }, dust = 0xa29e94, chip = 0x9a988f, sparks = 1 },
        building = { clod = { 0x9a7e6a, 0x866a58, 0xa8907c, 0x6e5848 }, dust = 0xb8a898, chip = 0xa89684, sparks = 1 },
    }
    M.MATERIAL = MAT          -- a plugin may tweak the tints (or add a material table with the same fields)

    local function mat(name)
        return MAT[name] or MAT.soil
    end

    -- ---------------------------------------------------------------- state
    local TEX = { dirt = {}, dust = {} }
    local loaded, loadFailAt = false, 0
    local installed = false
    local lastClock = nil
    local rayUsed = 0
    local rayFn = nil
    local rayOffUntil = 0

    local K_CLOD, K_DUST, K_SPARK, K_GLINT, K_GRAIN, K_MIST, K_RING = 1, 2, 3, 4, 5, 6, 7
    local N = 0
    local P = { x = {}, y = {}, z = {}, vx = {}, vy = {}, vz = {}, s0 = {}, s1 = {}, age = {}, life = {}, kind = {}, tex = {},
                rgb = {}, a = {}, drag = {}, grav = {}, rot = {}, spin = {}, bounce = {}, add = {}, bias = {} }
    local PARTS = {}
    for _, arr in pairs(P) do PARTS[#PARTS + 1] = arr end

    local STREAM = {}             -- id -> { x,y,z,dx,dy,dz, material, power, last, acc }
    local LATER = {}              -- delayed calls: { at = clock, fn = function }
    local RUN = {}                -- per-frame calls until a time: { to = clock, fn = function }
    local SHAKE = { amp = 0, t = 0, dur = 0.01, seed = 0, ox = 0, oy = 0, oz = 0, at = -1 }
    local CAM = { ok = false, rx = 1, ry = 0, rz = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1 }
    local nextId = 0

    -- ---------------------------------------------------------------- helpers
    local function clamp(v, a, b) return v < a and a or (v > b and b or v) end

    local function now()
        local ok, c = pcall(os.clock)
        return ok and c or 0
    end

    local function norm(x, y, z)
        local l = sqrt(x * x + y * y + z * z)
        if l < 1e-6 then return 0, 1, 0, 0 end
        return x / l, y / l, z / l, l
    end

    local function vec(v)
        if type(v) ~= "table" then return nil end
        local x, y, z = tonumber(v.x or v[1]), tonumber(v.y or v[2]), tonumber(v.z or v[3])
        if x and y and z then return x, y, z end
    end

    -- 0xRRGGBB and an alpha 0..1 -> 0xRRGGBBAA (an integer)
    local function rgba(c, a)
        return ((c & 0xffffff) << 8) | floor(clamp(a, 0, 1) * 255 + 0.5)
    end

    local function rnd(a, b) return a + (b - a) * random() end

    local function pick(t) return t[random(1, #t)] end

    local function scaled(n)
        local v = n * CFG.quality
        local w = floor(v)
        if random() < v - w then w = w + 1 end
        return w
    end

    local function varyColor(c, amt)
        local k = 1 + (random() * 2 - 1) * amt
        local r, g, b = ((c >> 16) & 255) * k, ((c >> 8) & 255) * k, (c & 255) * k
        return (floor(clamp(r, 0, 255)) << 16) | (floor(clamp(g, 0, 255)) << 8) | floor(clamp(b, 0, 255))
    end

    -- ---------------------------------------------------------------- textures
    local function loadTextures()
        if loaded then return true end
        if not (wum and wum.draw and wum.draw.texture and wum.draw.sprite) then return false end
        if now() < loadFailAt then return false end
        local function tex(name)
            local ok, id = pcall(wum.draw.texture, "textures/kj_" .. name .. ".png")
            if ok and type(id) == "number" then return id end
            return nil
        end
        for i = 1, 4 do TEX.dirt[i] = tex("dirt" .. i) end
        for i = 1, 2 do TEX.dust[i] = tex("dust" .. i) end
        TEX.chip, TEX.mist, TEX.gore = tex("stonechip"), tex("bloodmist"), tex("gore_chunk")
        TEX.spark, TEX.glint = tex("spark"), tex("glint")
        -- Usable if the core ones came up; anything else missing just drops that effect.
        if TEX.dirt[1] and TEX.dust[1] then
            for i = 2, 4 do TEX.dirt[i] = TEX.dirt[i] or TEX.dirt[1] end
            TEX.dust[2] = TEX.dust[2] or TEX.dust[1]
            loaded = true
            return true
        end
        loadFailAt = now() + 10
        return false
    end

    -- ---------------------------------------------------------------- camera and rays
    local function readCamera()
        CAM.ok = false
        if not (wum.render and wum.render.camera) then return end
        local ok, c = pcall(wum.render.camera)
        if not ok or type(c) ~= "table" then return end
        local fx, fy, fz = vec(c.fwd)
        local ux, uy, uz = vec(c.up)
        if not (fx and ux) then return end
        fx, fy, fz = norm(fx, fy, fz)
        local rx, ry, rz = fy * uz - fz * uy, fz * ux - fx * uz, fx * uy - fy * ux
        local l = sqrt(rx * rx + ry * ry + rz * rz)
        if l < 1e-6 then return end
        rx, ry, rz = rx / l, ry / l, rz / l
        ux, uy, uz = ry * fz - rz * fy, rz * fx - rx * fz, rx * fy - ry * fx
        CAM.rx, CAM.ry, CAM.rz, CAM.ux, CAM.uy, CAM.uz, CAM.fx, CAM.fy, CAM.fz = rx, ry, rz, ux, uy, uz, fx, fy, fz
        CAM.ok = true
    end

    -- t, nx, ny, nz or nil (miss, no ray left, or unavailable). Failure turns rays off for ten seconds.
    local function ray(x0, y0, z0, x1, y1, z1)
        if rayUsed >= CFG.rayCap then return nil end
        if rayFn == nil then
            rayFn = (wum.game and wum.game.landRay) or false
        end
        if not rayFn or now() < rayOffUntil then return nil end
        rayUsed = rayUsed + 1
        local ok, t, nx, ny, nz = pcall(rayFn, x0, y0, z0, x1, y1, z1)
        if not ok then
            rayOffUntil = now() + 10
            return nil
        end
        if type(t) ~= "number" or type(nx) ~= "number" or type(ny) ~= "number" or type(nz) ~= "number" then
            if nx == "unavailable" then rayOffUntil = now() + 10 end
            return nil
        end
        local a, b, c = norm(nx, ny, nz)
        return t, a, b, c
    end

    -- ---------------------------------------------------------------- particles
    local function spawn(kind, tex, add, x, y, z, vx, vy, vz, s0, s1, life, color, a, drag, grav, rot, spin, bounce, delay)
        if not tex or N >= CFG.maxParticles then return false end
        N = N + 1
        local i = N
        nextId = nextId + 1
        P.x[i], P.y[i], P.z[i], P.vx[i], P.vy[i], P.vz[i] = x, y, z, vx, vy, vz
        P.s0[i], P.s1[i], P.age[i], P.life[i], P.kind[i], P.tex[i] = s0, s1, -(delay or 0), life, kind, tex
        P.add[i], P.rgb[i], P.a[i], P.drag[i], P.grav[i], P.rot[i], P.spin[i] = add, color, a, drag, grav, rot or 0, spin or 0
        P.bounce[i] = bounce or 0
        P.bias[i] = 0.2 + ((nextId * 0.6180339887) % 1) * 0.5      -- toward the camera, so overlapping sprites never z-fight
        return i
    end

    local function remove(i)
        for k = 1, #PARTS do
            local arr = PARTS[k]
            arr[i] = arr[N]
        end
        N = N - 1
    end

    local function envelope(age, life, tin, fout)
        local e = 1
        if age < tin then
            local u = age / tin
            e = u * u * (3 - 2 * u)
        end
        local v = (age / life - (1 - fout)) / fout
        if v > 0 then
            if v >= 1 then return 0 end
            e = e * (1 - v * v * (3 - 2 * v))
        end
        return e
    end

    -- A direction inside a cone of half angle `spread` (radians) around (dx,dy,dz), unit result.
    local function cone(dx, dy, dz, spread)
        dx, dy, dz = norm(dx, dy, dz)
        local ax, ay, az = 0, 1, 0
        if abs(dy) > 0.9 then ax, ay, az = 1, 0, 0 end
        local px, py, pz = norm(dy * az - dz * ay, dz * ax - dx * az, dx * ay - dy * ax)
        local qx, qy, qz = dy * pz - dz * py, dz * px - dx * pz, dx * py - dy * px
        local ang = random() * 6.2831853
        local r = sin(spread * sqrt(random()))
        local c = sqrt(max(0, 1 - r * r))
        local ca, sa = cos(ang) * r, sin(ang) * r
        return dx * c + px * ca + qx * sa, dy * c + py * ca + qy * sa, dz * c + pz * ca + qz * sa
    end

    local function step(dt)
        local sprite = wum.draw.sprite
        local rx, ry, rz, ux, uy, uz = CAM.rx, CAM.ry, CAM.rz, CAM.ux, CAM.uy, CAM.uz
        local fx, fy, fz = CAM.fx, CAM.fy, CAM.fz
        local camOk = CAM.ok
        for i = N, 1, -1 do
            local age = P.age[i] + dt
            local life = P.life[i]
            if age >= life then
                remove(i)
            elseif age <= 0 then
                P.age[i] = age
            else
                P.age[i] = age
                local h = dt
                if age < h then h = age end
                local kind = P.kind[i]
                local x, y, z = P.x[i], P.y[i], P.z[i]
                local vx, vy, vz = P.vx[i], P.vy[i], P.vz[i]
                local dr, gr = P.drag[i], P.grav[i]
                if dr > 1e-4 then
                    -- velocity under drag with gravity gr (positive pulls down): v' = -d v - g, exact over the step
                    local e = exp(-dr * h)
                    local f = (1 - e) / dr
                    local vt = -gr / dr
                    y = y + vt * h + (vy - vt) * f
                    vy = (vy - vt) * e + vt
                    x, z = x + vx * f, z + vz * f
                    vx, vz = vx * e, vz * e
                else
                    x, z = x + vx * h, z + vz * h
                    y = y + vy * h - 0.5 * gr * h * h
                    vy = vy - gr * h
                end
                -- Clods and sparks hit the land: one ray along the step, a bounce with friction, then they rest and fade.
                if (kind == K_CLOD or kind == K_SPARK or kind == K_GRAIN) and P.bounce[i] > 0 and vy < 0 then
                    local ox, oy, oz = P.x[i], P.y[i], P.z[i]
                    local t, nx, ny, nz = ray(ox, oy, oz, x, y, z)
                    if t then
                        local hx, hy, hz = ox + (x - ox) * t + nx * 0.4, oy + (y - oy) * t + ny * 0.4, oz + (z - oz) * t + nz * 0.4
                        local vn = vx * nx + vy * ny + vz * nz
                        local e = P.bounce[i]
                        vx, vy, vz = (vx - nx * vn * (1 + e)) * 0.7, (vy - ny * vn * (1 + e)) * 0.7, (vz - nz * vn * (1 + e)) * 0.7
                        x, y, z = hx, hy, hz
                        P.bounce[i] = e * 0.45
                        if P.bounce[i] < 0.08 or (vx * vx + vy * vy + vz * vz) < 120 then
                            P.bounce[i] = 0
                            vx, vy, vz = 0, 0, 0
                            P.grav[i] = 0
                            P.drag[i] = 0
                            P.spin[i] = 0
                            if P.life[i] - age > 0.9 then P.life[i] = age + 0.9 end     -- a resting clod fades out
                        end
                    end
                end
                P.x[i], P.y[i], P.z[i], P.vx[i], P.vy[i], P.vz[i] = x, y, z, vx, vy, vz

                life = P.life[i]
                local t = age / life
                local s0, s1 = P.s0[i], P.s1[i]
                local s = s0 + (s1 - s0) * t * (2 - t)
                local a = P.a[i]
                local ax, ay, az, hl, hw = 0, 0, 0, 0, nil
                if kind == K_CLOD or kind == K_GRAIN then
                    a = a * envelope(age, life, 0.02, 0.35)
                    local rot = P.rot[i] + P.spin[i] * h
                    P.rot[i] = rot
                    if camOk then
                        local c, sn = cos(rot), sin(rot)
                        ax, ay, az, hl = rx * c + ux * sn, ry * c + uy * sn, rz * c + uz * sn, s
                    end
                elseif kind == K_DUST or kind == K_MIST then
                    -- expands quickly, then drifts; the alpha eases in and out, so nothing pops
                    s = s0 + (s1 - s0) * sqrt(t)
                    a = a * envelope(age, life, 0.12, 0.8)
                    local rot = P.rot[i] + P.spin[i] * h
                    P.rot[i] = rot
                    if camOk then
                        local c, sn = cos(rot), sin(rot)
                        ax, ay, az, hl = rx * c + ux * sn, ry * c + uy * sn, rz * c + uz * sn, s
                    end
                elseif kind == K_RING then
                    -- the shock ring: dust racing outward along the ground, a puff stretched sideways
                    s = s0 + (s1 - s0) * (1 - (1 - t) * (1 - t))
                    a = a * envelope(age, life, 0.04, 0.7)
                    if camOk then ax, ay, az, hl = rx, ry, rz, s * 0.55 end
                    hw = s
                elseif kind == K_SPARK then
                    a = a * envelope(age, life, 0.02, 1)
                    local sp = sqrt(vx * vx + vy * vy + vz * vz)
                    -- kj_spark.png is a lens along u, so the axis is turned a quarter turn from the velocity on screen
                    hw, hl = 1.0 + 9.0 * (1 - exp(-sp * 0.004)), s * 2
                    ax, ay, az = ux, uy, uz
                    if camOk and sp > 1e-3 then
                        local qx, qy, qz = fy * vz - fz * vy, fz * vx - fx * vz, fx * vy - fy * vx
                        local ql = sqrt(qx * qx + qy * qy + qz * qz)
                        if ql > sp * 0.05 then ax, ay, az = qx / ql, qy / ql, qz / ql end
                    end
                else -- K_GLINT
                    a = a * envelope(age, life, life * 0.25, 0.75)
                    local rot = P.rot[i] + P.spin[i] * h
                    P.rot[i] = rot
                    if camOk then
                        local c, sn = cos(rot), sin(rot)
                        ax, ay, az, hl = rx * c + ux * sn, ry * c + uy * sn, rz * c + uz * sn, s
                    end
                end
                local a8 = floor(a * 255 + 0.5)
                if a8 > 0 and s > 0 then
                    if a8 > 255 then a8 = 255 end
                    local b = P.bias[i]
                    local c = (P.rgb[i] & 0xffffff00) | a8
                    local mode = P.add[i] and "additive" or "alpha"
                    if camOk then
                        pcall(sprite, P.tex[i], x - fx * b, y - fy * b, z - fz * b, hw or s, hl, ax, ay, az, c, mode)
                    else
                        pcall(sprite, P.tex[i], x, y, z, hw or s, 0, 0, 0, 0, c, mode)
                    end
                end
            end
        end
    end

    -- ---------------------------------------------------------------- effects
    local function clodTex() return TEX.dirt[random(1, 4)] end
    local function dustTex() return TEX.dust[random(1, 2)] end

    -- A clod thrown from (x,y,z) around (dx,dy,dz).
    local function throwClod(x, y, z, dx, dy, dz, spread, speed, m, size)
        local vx, vy, vz = cone(dx, dy, dz, spread)
        local sp = speed * rnd(0.55, 1.15)
        local rock = (m.sparks == 1) and random() < 0.55
        local tex = rock and TEX.chip or clodTex()
        local col = rock and varyColor(m.chip, 0.18) or varyColor(pick(m.clod), 0.12)
        local s = size * rnd(0.6, 1.25)
        spawn(K_CLOD, tex or clodTex(), false, x, y, z, vx * sp, vy * sp, vz * sp, s, s * 0.85, rnd(0.9, 1.7), rgba(col, 1), 0.98,
              0.25, CFG.gravity, rnd(0, 6.28), rnd(-9, 9), 0.42)
    end

    local function puff(x, y, z, vx, vy, vz, s0, s1, life, color, alpha)
        spawn(K_DUST, dustTex(), false, x, y, z, vx, vy, vz, s0, s1, life, rgba(color, 1), alpha, 1.8, -6, rnd(0, 6.28),
              rnd(-0.6, 0.6), 0)
    end

    local function glint(x, y, z, size, color)
        if TEX.glint then
            spawn(K_GLINT, TEX.glint, true, x, y, z, 0, 0, 0, size, size * 0.5, rnd(0.08, 0.16), rgba(color or 0xffe2b0, 1), 1, 0, 0,
                  rnd(0, 6.28), rnd(-6, 6), 0)
        end
    end

    function M.sparks(x, y, z, dx, dy, dz, n, material)
        if not loadTextures() or not TEX.spark then return end
        M.install()
        n = scaled(n or 10)
        for _ = 1, n do
            local vx, vy, vz = cone(dx, dy, dz, 0.7)
            local sp = rnd(120, 340)
            local hot = random()
            local col = hot > 0.6 and 0xfff0c8 or (hot > 0.25 and 0xffc060 or 0xff8a30)
            spawn(K_SPARK, TEX.spark, true, x, y, z, vx * sp, vy * sp + 30, vz * sp, 0.55, 0.3, rnd(0.18, 0.5), rgba(col, 1), 1, 0.6,
                  CFG.gravity * 0.8, 0, 0, 0.3)
        end
        glint(x, y, z, rnd(5, 8))
        if random() < 0.5 then glint(x + rnd(-1.5, 1.5), y + rnd(-1.5, 1.5), z + rnd(-1.5, 1.5), rnd(2.5, 4.5), 0xfff4d8) end
    end

    function M.settle(x, y, z, radius, material)
        if not loadTextures() then return end
        M.install()
        local m = mat(material)
        radius = clamp(tonumber(radius) or 10, 3, 60)
        -- low flat puffs spreading along the floor, long lived and thin
        for _ = 1, scaled(7) do
            local a = random() * 6.2831853
            local d = radius * rnd(0.1, 0.8)
            puff(x + cos(a) * d, y + rnd(-0.5, 3), z + sin(a) * d, cos(a) * rnd(4, 14), rnd(1, 5), sin(a) * rnd(4, 14),
                 radius * rnd(0.35, 0.55), radius * rnd(0.9, 1.4), rnd(2.4, 4.2), m.dust, rnd(0.18, 0.3))
        end
        -- grains sifting down through it
        for _ = 1, scaled(10) do
            local a = random() * 6.2831853
            local d = radius * rnd(0, 0.9)
            spawn(K_GRAIN, TEX.chip or clodTex(), false, x + cos(a) * d, y + rnd(2, radius * 0.9), z + sin(a) * d, rnd(-3, 3),
                  rnd(-4, 0), rnd(-3, 3), 0.28, 0.25, rnd(0.8, 1.8), rgba(varyColor(m.dust, 0.15), 1), 0.7, 1.2, 40, rnd(0, 6.28),
                  rnd(-3, 3), 0, rnd(0, 0.5))
        end
    end

    function M.scoop(x, y, z, dx, dy, dz, material, power)
        if not loadTextures() then return end
        M.install()
        local m = mat(material)
        power = clamp(tonumber(power) or 1, 0.3, 2)
        local bx, by, bz = norm(dx, dy, dz)
        -- debris is thrown back out of the cut and up: against the blade's travel, lifted
        local ox, oy, oz = norm(-bx * 0.7, 0.75 + max(0, -by) * 0.2, -bz * 0.7)
        for _ = 1, scaled(9 * power) do
            throwClod(x, y, z, ox, oy, oz, 0.75, 120 * power, m, 1.3 + 0.7 * power)
        end
        -- a few that fly along the blade, past the cut
        for _ = 1, scaled(3 * power) do
            throwClod(x, y, z, bx, by + 0.4, bz, 0.5, 90 * power, m, 1.0)
        end
        puff(x, y + 1, z, ox * 12, oy * 14, oz * 12, 4 * power, 11 * power, rnd(0.9, 1.5), m.dust, 0.5)
        for _ = 1, scaled(3 * power) do
            local vx, vy, vz = cone(ox, oy, oz, 0.9)
            puff(x, y + 1, z, vx * 30, vy * 30, vz * 30, 2.5 * power, 8 * power, rnd(0.7, 1.4), m.dust, rnd(0.25, 0.4))
        end
        if m.sparks == 1 then
            M.sparks(x, y, z, ox, oy + 0.2, oz, 7 * power, material)
        end
        local r = 9 * power
        LATER[#LATER + 1] = { at = now() + 0.35, fn = function() M.settle(x, y, z, r, material) end }
    end

    function M.dig(id, x, y, z, dx, dy, dz, material, power)
        if id == nil then return end
        local s = STREAM[id]
        if not s then
            s = { acc = 0, accDust = 0, accSpark = 0 }
            STREAM[id] = s
        end
        s.x, s.y, s.z, s.dx, s.dy, s.dz = x, y, z, dx, dy, dz
        s.material, s.power, s.last = material, clamp(tonumber(power) or 1, 0.3, 2), now()
        M.install()
    end

    function M.digStop(id)
        local s = STREAM[id]
        if s then
            STREAM[id] = nil
            M.settle(s.x, s.y, s.z, 10 * s.power, s.material)
        end
    end

    local function streamTick(dt, t)
        for id, s in pairs(STREAM) do
            if t - s.last > CFG.streamTimeout then
                M.digStop(id)
            else
                local m = mat(s.material)
                local rate = CFG.streamRate * s.power
                local bx, by, bz = norm(s.dx, s.dy, s.dz)
                local ox, oy, oz = norm(-bx * 0.7, 0.7, -bz * 0.7)
                s.acc = s.acc + rate * dt
                while s.acc >= 1 do
                    s.acc = s.acc - 1
                    if random() < CFG.quality then
                        -- a start point spread back along the frame's travel hides the frame-sized clumps
                        local j = random() - 1
                        throwClod(s.x + j * bx * 3, s.y, s.z + j * bz * 3, ox, oy, oz, 0.6, rnd(60, 130) * s.power, m,
                                  1.0 + 0.5 * s.power)
                    end
                end
                s.accDust = s.accDust + rate * 0.35 * dt
                while s.accDust >= 1 do
                    s.accDust = s.accDust - 1
                    if random() < CFG.quality then
                        local vx, vy, vz = cone(ox, oy, oz, 0.8)
                        puff(s.x, s.y + 1, s.z, vx * 22, vy * 22, vz * 22, 2.5, 7.5 * s.power, rnd(0.8, 1.5), m.dust, rnd(0.25, 0.42))
                    end
                end
                if m.sparks == 1 then
                    s.accSpark = s.accSpark + rate * 0.25 * dt
                    while s.accSpark >= 1 do
                        s.accSpark = s.accSpark - 1
                        M.sparks(s.x, s.y, s.z, ox, oy + 0.3, oz, 3, s.material)
                    end
                end
            end
        end
        local i = 1
        while i <= #LATER do
            local q = LATER[i]
            if t >= q.at then
                table.remove(LATER, i)
                pcall(q.fn)
            else
                i = i + 1
            end
        end
        i = 1
        while i <= #RUN do
            local q = RUN[i]
            if t >= q.to then
                table.remove(RUN, i)
            else
                pcall(q.fn)
                i = i + 1
            end
        end
    end

    function M.headOff(x, y, z, dx, dz, opts)
        if not loadTextures() then return end
        M.install()
        opts = type(opts) == "table" and opts or {}
        local k = clamp(tonumber(opts.scale) or 1, 0.4, 2.5)
        local m = MAT.sand
        local fx, _, fz = norm(dx or 0, 0, dz or 0)
        -- 1. the shock ring: dust racing out along the ground from the body
        spawn(K_RING, dustTex(), false, x, y - 4, z, 0, 0, 0, 4 * k, 26 * k, 0.55, rgba(m.dust, 1), 0.55, 0, 0, 0, 0, 0)
        -- 2. a dust column up from the neck, with the sand fountain inside it
        for _ = 1, scaled(8 * k) do
            local vx, vy, vz = cone(0, 1, 0, 0.45)
            puff(x, y, z, vx * rnd(25, 60), vy * rnd(25, 60), vz * rnd(25, 60), 3 * k, rnd(9, 15) * k, rnd(1.0, 1.9), m.dust,
                 rnd(0.4, 0.6))
        end
        for _ = 1, scaled(26 * k) do
            local vx, vy, vz = cone(fx * 0.5, 1, fz * 0.5, 0.5)
            local sp = rnd(70, 190) * k
            spawn(K_GRAIN, TEX.chip or clodTex(), false, x, y, z, vx * sp, vy * sp, vz * sp, rnd(0.35, 0.7), 0.3, rnd(0.8, 1.6),
                  rgba(varyColor(m.clod[1], 0.15), 1), 0.95, 0.2, CFG.gravity, rnd(0, 6.28), rnd(-12, 12), 0.35)
        end
        -- 3. flung grit along the facing, so the cut has a direction
        for _ = 1, scaled(10 * k) do
            throwClod(x, y, z, fx, 0.5, fz, 0.5, rnd(90, 170), m, 1.1)
        end
        glint(x, y, z, 9 * k, 0xfff0d0)
        if opts.blood and TEX.mist then
            for _ = 1, scaled(7 * k) do
                local vx, vy, vz = cone(0, 1, 0, 0.6)
                local sp = rnd(30, 90)
                spawn(K_MIST, TEX.mist, false, x, y, z, vx * sp, vy * sp, vz * sp, 4 * k, rnd(11, 18) * k, rnd(0.7, 1.4),
                      rgba(0x6a0a10, 1), rnd(0.5, 0.8), 1.4, 120, rnd(0, 6.28), rnd(-1, 1), 0)
            end
            if TEX.gore then
                for _ = 1, scaled(8 * k) do
                    local vx, vy, vz = cone(0, 1, 0, 0.6)
                    local sp = rnd(70, 180)
                    spawn(K_CLOD, TEX.gore, false, x, y, z, vx * sp, vy * sp, vz * sp, rnd(1.0, 2.1), 1.5, rnd(1.0, 1.8),
                          rgba(0x7c0f16, 1), 1, 0.1, CFG.gravity, rnd(0, 6.28), rnd(-10, 10), 0.3)
                end
            end
        end
        M.settle(x, y - 3, z, 16 * k, "sand")
        M.shake(3.2 * k, 0.45)
    end

    -- ---------------------------------------------------------------- camera shake
    -- Decaying noise: a sum of incommensurate sines, so there is no visible repetition and no per-frame random jitter.
    function M.shake(amount, seconds)
        amount = clamp(tonumber(amount) or 1, 0, 6)
        seconds = clamp(tonumber(seconds) or 0.4, 0.05, 3)
        local left = max(0, SHAKE.dur - SHAKE.t)
        local cur = SHAKE.amp * (left / SHAKE.dur) ^ 2
        if amount >= cur then
            SHAKE.amp, SHAKE.dur, SHAKE.t, SHAKE.seed = amount, seconds, 0, random() * 100
        else
            SHAKE.amp = cur + amount * 0.3
            SHAKE.dur, SHAKE.t = max(seconds, left), 0
        end
    end

    function M.shakeOffset()
        local t = now()
        if SHAKE.at == t then return SHAKE.ox, SHAKE.oy, SHAKE.oz end
        local dt = SHAKE.at < 0 and 0 or min(t - SHAKE.at, CFG.maxDt)
        SHAKE.at = t
        SHAKE.t = SHAKE.t + dt
        if SHAKE.t >= SHAKE.dur or SHAKE.amp <= 0 then
            SHAKE.amp, SHAKE.ox, SHAKE.oy, SHAKE.oz = 0, 0, 0, 0
            return 0, 0, 0
        end
        local u = 1 - SHAKE.t / SHAKE.dur
        local a = SHAKE.amp * u * u                                    -- quadratic decay: sharp hit, soft tail
        local s, w = SHAKE.seed, SHAKE.t
        SHAKE.ox = a * (sin(w * 41 + s) * 0.6 + sin(w * 67 + s * 2) * 0.4)
        SHAKE.oy = a * (sin(w * 53 + s * 3) * 0.6 + sin(w * 79 + s) * 0.4) * 0.8
        SHAKE.oz = a * (sin(w * 47 + s * 5) * 0.6 + sin(w * 71 + s * 4) * 0.4)
        return SHAKE.ox, SHAKE.oy, SHAKE.oz
    end

    local function addTo(v, ox, oy, oz, k)
        if type(v) ~= "table" then return end
        if v.x ~= nil then
            v.x, v.y, v.z = v.x + ox * k, v.y + oy * k, v.z + oz * k
        elseif v[1] ~= nil then
            v[1], v[2], v[3] = v[1] + ox * k, v[2] + oy * k, v[3] + oz * k
        end
    end

    function M.shakeCam(spec)
        if type(spec) ~= "table" then return spec end
        local ox, oy, oz = M.shakeOffset()
        if ox ~= 0 or oy ~= 0 or oz ~= 0 then
            addTo(spec.pos, ox, oy, oz, 1)
            addTo(spec.target, ox, oy, oz, 0.35)          -- the target moves less than the eye: a turn of the view, not a slide
        end
        return spec
    end

    -- ---------------------------------------------------------------- driver
    local function onWorld()
        local t = now()
        local dt = lastClock and (t - lastClock) or 0
        lastClock = t
        if dt <= 0 then return end
        if dt > CFG.maxDt then dt = CFG.maxDt end
        rayUsed = 0
        if not loaded and not loadTextures() then return end
        readCamera()
        streamTick(dt, t)
        if N > 0 then step(dt) end
    end

    function M.install()
        if installed then return true end
        if not (wum and wum.draw and wum.draw.on and wum.draw.sprite) then return false end
        local ok = pcall(wum.draw.on, "worldLate", function()
            local good, err = pcall(onWorld)
            if not good and wum.log and wum.log.warn then pcall(wum.log.warn, "kindjal spade fx: " .. tostring(err)) end
        end)
        installed = ok
        return ok
    end

    function M.ready() return loaded end
    function M.count() return N end

    function M.clear()
        N = 0
        for k in pairs(STREAM) do STREAM[k] = nil end
        for i = #LATER, 1, -1 do LATER[i] = nil end
        for i = #RUN, 1, -1 do RUN[i] = nil end
        SHAKE.amp, SHAKE.ox, SHAKE.oy, SHAKE.oz = 0, 0, 0, 0
    end

    -- 0 turns the module off (no particles are born), 1 is full. The pool size follows it.
    function M.setQuality(q)
        q = clamp(tonumber(q) or 1, 0, 1)
        CFG.quality = q
        CFG.maxParticles = floor(120 + 580 * q)
    end

    -- Every effect once, a little apart, for the Preview menu: a soil scoop, a stone dig with sparks, then the head-off.
    function M.preview(x, y, z)
        M.install()
        local t = now()
        M.scoop(x, y, z, 1, -0.2, 0, "soil", 1)
        RUN[#RUN + 1] = { to = t + 3.2, fn = function()
            if now() > t + 1.0 then M.dig("preview", x + 14, y, z, 1, 0, 0, "stone", 1) end
        end }
        LATER[#LATER + 1] = { at = t + 3.4, fn = function() M.headOff(x + 28, y + 8, z, 1, 0, {}) end }
    end

    return M
end)()
SpadeFX.install()

-- ---------------------------------------------------------------- the Grave Spade
-- The Grave Spade, a clone of the Bat in cell 41 (sim/main.lua digs, strikes and kills; this only shows it). Everything here is drawn on this
-- machine alone: poses (wum.render.wormPose), the head copy (wormCopy), the camera, sounds and particles never reach the
-- match. What it shows is driven by the sim's Kindjal.Spade messages, which every machine gets at the same tick:
--   d,slot,tick,x0,y0,z0,x1,y1,z1,removed   a scoop (removed -1: the turn's carve budget is spent)
--   r,slot,tick,n                           the dig button was let go
--   w,slot,tick                             a strike swing started
--   h,attacker,victim,tick                  a strike hit (after the execution: the Shiv's damage)
--   x,a,v,t0,chop,throes,end,ax,ay,az,vx,vy,vz   the execution starts at sim tick t0; chop and end are ticks after t0
--   c,a,v,tick / e,a,v,tick / a,a,v,tick    the chop's kill was posted / the execution is over / it was aborted
-- The spade itself: the engine's held mesh is an invisible speck (kindjal.GraveSpadeHidden), and the real one
-- (assets/meshes/gravespade.mesh.txt) is drawn here in the worm's hands. With MiragePose's palette the hands are carried
-- onto its grip, so they follow every scoop. The execution is the mount (MT below): the victim on its back, the attacker
-- on top of it, the blade on its chest, the chop, and the head off as the worm's own head (wormCopy). Without the body
-- and palette layers (wum.render.wormPoseCaps) the spade turns in the worm's fists where the engine's Bat hold puts them,
-- and the execution is staged upright: no fall and no mount, the blade raised over the shoulder and swung through the neck.
local SPADE = (function()
    local GS = {
        WEAPON = "spade",               -- the Grave Spade clone, as the worm loop keys it (MELEE)
        SCALE = 0.85,                   -- the held mesh is the Bat's size; a worm holds it a little smaller
        GRIP = -11.6, FRONT = -2.0, TIP = 13.0,     -- along the mesh's +Y: the D-grip, the front hand, the blade's point
        STROKE = 0.36,                  -- seconds between scoops while held (sim SPADE.STROKE = 18 ticks)
        FOLLOW = 26,                    -- how fast the drawn spade follows its target pose (1/s)
        FIST_F = 5.5, FIST_Y = 15,      -- no poses: the fists of the engine's Bat hold, ahead of and above the feet
        NECK_Y = 21,                    -- no poses: an upright worm's neck above its feet
        WORM_R = 17, WORM_TOP = 32,     -- the camera keeps this far from a worm's axis, up to this height over its feet
        OCCLUDE_R = 12,                 -- a sight line this close to a worm's axis is blocked by it
        HEAD_R = 10,                    -- the camera keeps this far from the severed head's middle
        HEAD_FOLLOW = 130,              -- the camera leans toward the head while it is this close to the pair
        HEAD_AWAY = 0.5,                -- the head flies at least this much (of its speed) away from the eye
        CAM_FLOOR = 30,                 -- land between the pair and the eye pulls it in, but not nearer than this
        TICK = 50,
        on = false, mesh = nil, tex = nil, head = nil, headTex = nil, headClean = nil, loadedAt = -100,
        material = "soil", aimSign = 1,
        pose = { status = nil, bad = false, since = nil, swap = {} },
        w = {},                         -- per slot: the drawn spade and its animation
        ex = nil,                       -- the execution being shown
        heads = {},                     -- severed heads still on the ground
        bs = { at = -100, on = false }, -- what Bloodsand last said (mod.bloodsand.state)
    }
    local THEME = { ARABIAN = "sand", WILDWEST = "sand", PIRATE = "sand", BUILDING = "building", CAMELOT = "stone",
                    SPACE = "stone", PREHISTORIC = "soil", HORROR = "soil", WAR = "soil" }

    -- ------------------------------------------------------------ small vector and rotation helpers
    local function norm3(x, y, z)
        local l = sqrt(x * x + y * y + z * z)
        if l < 1e-6 then return 0, 1, 0, 0 end
        return x / l, y / l, z / l, l
    end
    local function cross(ax, ay, az, bx, by, bz) return ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx end
    local function lerp(a, b, t) return a + (b - a) * t end
    local function ease(u) return smooth(u) end
    local function seg(t, a, b) return clamp((t - a) / (b - a), 0, 1) end

    -- A rotation as its three rows: the images of world X, Y and Z (row vectors, as MiragePose composes them).
    local function rotAxis(ax, ay, az, ang)
        ax, ay, az = norm3(ax, ay, az)
        local c, s = cos(ang), sin(ang)
        local t = 1 - c
        -- the column-vector matrix R; rows of the row-vector form are its columns
        local r11, r12, r13 = t * ax * ax + c, t * ax * ay - s * az, t * ax * az + s * ay
        local r21, r22, r23 = t * ax * ay + s * az, t * ay * ay + c, t * ay * az - s * ax
        local r31, r32, r33 = t * ax * az - s * ay, t * ay * az + s * ax, t * az * az + c
        return { r11, r21, r31, r12, r22, r32, r13, r23, r33 }
    end
    local IDENT = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }
    local function mul(a, b)            -- row-vector composition: a first, then b
        local o = {}
        for i = 0, 2 do
            for j = 1, 3 do
                o[i * 3 + j] = a[i * 3 + 1] * b[j] + a[i * 3 + 2] * b[3 + j] + a[i * 3 + 3] * b[6 + j]
            end
        end
        return o
    end
    -- The rotation taking the orthonormal frame (r, u, f) onto (r2, u2, f2), as rows.
    local function frameMap(r, u, f, r2, u2, f2)
        local o = {}
        for i = 1, 3 do
            local e = { 0, 0, 0 }
            e[i] = 1
            -- e expressed in the first frame, then rebuilt in the second
            local a = e[1] * r[1] + e[2] * r[2] + e[3] * r[3]
            local b = e[1] * u[1] + e[2] * u[2] + e[3] * u[3]
            local c = e[1] * f[1] + e[2] * f[2] + e[3] * f[3]
            o[(i - 1) * 3 + 1] = a * r2[1] + b * u2[1] + c * f2[1]
            o[(i - 1) * 3 + 2] = a * r2[2] + b * u2[2] + c * f2[2]
            o[(i - 1) * 3 + 3] = a * r2[3] + b * u2[3] + c * f2[3]
        end
        return o
    end
    -- Axis and angle of a rotation (rows), for blending from no turn to it.
    local function axisAngle(m)
        local tr = m[1] + m[5] + m[9]
        local ang = math.acos(clamp((tr - 1) / 2, -1, 1))
        if ang < 1e-4 then return 0, 1, 0, 0 end
        -- rows are the transpose of the column form: axis from the column form's skew part
        local x, y, z = m[6] - m[8], m[7] - m[3], m[2] - m[4]
        local l = sqrt(x * x + y * y + z * z)
        if l < 1e-5 then
            -- 180 degrees: the axis is the column of (R + I) with the largest diagonal
            if m[1] >= m[5] and m[1] >= m[9] then x, y, z = m[1] + 1, m[2], m[3]
            elseif m[5] >= m[9] then x, y, z = m[4], m[5] + 1, m[6]
            else x, y, z = m[7], m[8], m[9] + 1 end
            x, y, z = norm3(x, y, z)
            return x, y, z, ang
        end
        return x / l, y / l, z / l, ang
    end
    local function blendRot(m, t)
        if t >= 1 then return m end
        local x, y, z, a = axisAngle(m)
        if a == 0 or t <= 0 then return IDENT end
        return rotAxis(x, y, z, a * t)
    end
    -- MiragePose's Euler angles (degrees) for a rotation given as rows: roll about Z, then pitch about X, then yaw about Y,
    -- world axes (pose_logic.h Rotate). Row 3 is (cp sy, sp, cp cy), row 1 col 2 is sr cp, row 2 col 2 is cr cp.
    local DEG = 180 / pi
    local function euler(m)
        local sp = clamp(m[8], -1, 1)
        local p = math.asin(sp)
        local y, r
        if abs(sp) < 0.9999 then
            y = math.atan(m[7], m[9])
            r = math.atan(m[2], m[5])
        else
            y = math.atan(-m[3], m[1])
            r = 0
        end
        return { p * DEG, y * DEG, r * DEG }
    end
    -- A worm's frame from its facing: right, up, forward (forward = (sin yaw, 0, cos yaw), right = forward x up).
    local function wormFrame(yaw)
        local fx, fz = sin(yaw), cos(yaw)
        return { -fz, 0, fx }, { 0, 1, 0 }, { fx, 0, fz }
    end

    -- ------------------------------------------------------------ assets
    local function parseKJM(text)
        if type(text) ~= "string" then return nil end
        local it = string.gmatch(text, "%S+")
        if it() ~= "KJM1" then return nil end
        local per, nv, ni = tonumber(it()), tonumber(it()), tonumber(it())
        if not (per and nv and ni) or (per ~= 8 and per ~= 12) then return nil end
        local v, idx = {}, {}
        for i = 1, nv * per do
            local n = tonumber(it())
            if not n then return nil end
            v[i] = n
        end
        for i = 1, ni do
            local n = tonumber(it())
            if not n then return nil end
            idx[i] = n + 1
        end
        return v, idx, per == 12 and "pntc" or nil
    end
    local function loadMesh(rel)
        if not (wum.mod and wum.mod.readFile and wum.draw.newMesh) then return nil end
        local ok, text = pcall(wum.mod.readFile, rel)
        if not ok or type(text) ~= "string" then
            log("kindjal: spade mesh " .. rel .. " not read: " .. tostring(text))
            return nil
        end
        local v, idx, fmt = parseKJM(text)
        if not v then
            log("kindjal: spade mesh " .. rel .. " is not KJM1")
            return nil
        end
        local okM, h = pcall(wum.draw.newMesh, v, idx, fmt)
        if okM and h then return h end
        log("kindjal: spade mesh " .. rel .. " refused: " .. tostring(h))
        return nil
    end
    local function tex(rel)
        if not wum.draw.texture then return nil end
        local ok, id = pcall(wum.draw.texture, rel)
        if ok and type(id) == "number" then return id end
        return nil
    end
    local function ensureAssets()
        if GS.mesh or os.clock() - GS.loadedAt < 10 then return GS.mesh ~= nil end
        GS.loadedAt = os.clock()
        GS.mesh = loadMesh("assets/meshes/gravespade.mesh.txt")
        GS.tex = tex("assets/meshes/gravespade.png")
        GS.head = GS.head or loadMesh("assets/meshes/gravespade_head.mesh.txt")
        GS.headTex = GS.headTex or tex("assets/meshes/gravespade_head.png")
        GS.headClean = GS.headClean or tex("assets/meshes/gravespade_head_clean.png")
        return GS.mesh ~= nil
    end

    -- ------------------------------------------------------------ Bloodsand
    -- Bloodsand 1.6 says whether its gore is on (mod.bloodsand.state) and takes the execution's beats (mod.kindjal.exec).
    -- An older Bloodsand is only seen by its effects (COMPAT.bloodsand) and does not know the beats: Kindjal then draws the
    -- blood itself. With no Bloodsand, or its Blood set to off, the head comes off in dust and sand.
    function GS.goreMode()
        if os.clock() - GS.bs.at < 8 then return GS.bs.on and "bloodsand" or "dust" end
        return COMPAT.bloodsand and "own" or "dust"
    end
    function GS.hearBloodsand(p)
        if type(p) ~= "table" then return end
        GS.bs.at, GS.bs.on = os.clock(), p.on == true
    end
    local function emitExec(t)
        if wum.events and wum.events.emit then pcall(wum.events.emit, "exec", t) end
    end

    -- ------------------------------------------------------------ poses
    -- One call a frame per posed worm, frames = 4 so a hitch does not drop it. A status of "unsupported" or "disabled",
    -- a run of "unavailable" refusals inside a live match, or a status still not "ok" eight seconds after the first pose
    -- turns the poses off until the next match starts (GS.matchStart); the spade, the camera and the effects go on
    -- without them. A single "unavailable" (a call while a match is torn down) or "busy" (another mod poses that worm)
    -- only skips that pose.
    local function poseOk()
        if GS.pose.bad or not wum.render.wormPose then return false end
        if not GS.pose.checked and wum.render.wormPoseStatus then
            -- "unsupported" (the game skins on the CPU) and "disabled" never change: no pose is tried at all
            GS.pose.checked = true
            local okS, st = pcall(wum.render.wormPoseStatus)
            if okS and (st == "unsupported" or st == "disabled") then
                GS.pose.bad = true
                log("kindjal: worm poses " .. tostring(st) .. ": the spade is held in the fists and the execution is staged upright")
                return false
            end
        end
        return true
    end
    -- Which pose layers this Melange has (wum.render.wormPoseCaps), once a match.
    local function poseCaps()
        if GS.pose.caps then return GS.pose.caps end
        local c = {}
        if wum.render.wormPoseCaps then
            local ok, r = pcall(wum.render.wormPoseCaps)
            if ok and type(r) == "table" then c = r end
        end
        GS.pose.caps = c
        return c
    end
    local function setPose(slot, spec)
        if not poseOk() then return false end
        spec.frames = spec.frames or 4
        if GS.pose.noClips then spec.clips, spec.sliders = nil, nil end
        local ok, r, why = pcall(wum.render.wormPose, slot, spec)
        if ok and r ~= true and type(why) == "string" and string.sub(why, 1, 7) == "no clip" then
            -- a library without one of our clips: the poses go on without clips and sliders
            log("kindjal: worm pose " .. why .. ": clips and sliders are left out")
            GS.pose.noClips = true
            spec.clips, spec.sliders = nil, nil
            ok, r, why = pcall(wum.render.wormPose, slot, spec)
        end
        if not ok then
            logErr("wormPose", r)
            GS.pose.bad = true
            return false
        end
        if r ~= true then
            -- "unavailable" also answers a call made outside a match or while one is torn down (the attract demo's end):
            -- only a run of them inside a live match turns the poses off, and only until the next match starts
            if why == "unavailable" then
                local okM, inM = pcall(wum.game.inMatch)
                local now2 = os.clock()
                if okM and inM then
                    GS.pose.fails = (GS.pose.fails or 0) + 1
                    GS.pose.failSince = GS.pose.failSince or now2
                    if GS.pose.fails >= 30 and now2 - GS.pose.failSince > 3 then
                        GS.pose.bad = true
                        log("kindjal: worm poses unavailable in this match: the spade is held in the fists and the execution is staged upright")
                    end
                end
            end
            return false
        end
        GS.pose.fails, GS.pose.failSince = 0, nil
        local now2 = os.clock()
        GS.pose.since = GS.pose.since or now2
        if not GS.pose.status and now2 - GS.pose.since > 2 and wum.render.wormPoseStatus then
            local okS, st = pcall(wum.render.wormPoseStatus)
            if okS and st == "ok" then
                GS.pose.status = "ok"
            elseif okS and (st == "unsupported" or st == "disabled") then
                GS.pose.bad = true
                log("kindjal: worm poses unavailable (" .. tostring(st) .. "): the spade is drawn without the hands")
            elseif now2 - GS.pose.since > 8 then
                GS.pose.bad = true
                log("kindjal: worm poses never identified (" .. tostring(st) .. "): the spade is drawn without the hands")
            end
        end
        return true
    end
    local function clearPose(slot)
        if wum.render.wormPose then pcall(wum.render.wormPose, slot, nil) end
    end
    local function bones(slot)
        if not wum.render.wormBones then return nil end
        local ok, b = pcall(wum.render.wormBones, slot)
        if ok and type(b) == "table" then return b end
        return nil
    end
    local function bone(b, name)
        if not b then return nil end
        return vec(b[name])
    end

    -- ------------------------------------------------------------ the spade's path
    -- A pose is the grip point G (the D-grip, the rear hand) and the point the blade aims at; the mesh is laid from G along
    -- G -> aim. Points are built in the worm's frame: C is its middle, f its facing, a the aim (or the dig's direction).
    local P = {}
    local function setP(gx, gy, gz, tx, ty, tz) P.gx, P.gy, P.gz, P.tx, P.ty, P.tz = gx, gy, gz, tx, ty, tz end
    local function at(c, f, a, kf, ku, ka)
        return c[1] + f[1] * kf + ka * a[1], c[2] + ku + ka * a[2], c[3] + f[3] * kf + ka * a[3]
    end
    -- The dig cycle, q = 0 at the bite (the sim's carve) to 1 at the next: bite, lever up, fling over the shoulder, wind up.
    local DIG = {
        { 0.00, { 0, 2, 4 },   { 0, 0, 30 } },       -- {q, grip {f, up, aim}, aim point {f, up, aim}}
        { 0.28, { -2, -3, 0 }, { 0, 12, 20 } },
        { 0.55, { 2, 4, 0 },   { -6, 24, 0 } },
        { 0.80, { -4, 4, 0 },  { 0, 8, 14 } },
        { 1.00, { 0, 2, 4 },   { 0, 0, 30 } },
    }
    local function digPose(c, f, a, q)
        local k = 1
        while k < #DIG - 1 and q > DIG[k + 1][1] do k = k + 1 end
        local A, B = DIG[k], DIG[k + 1]
        local u = ease(seg(q, A[1], B[1]))
        local g1, g2, t1, t2 = A[2], B[2], A[3], B[3]
        local gx, gy, gz = at(c, f, a, lerp(g1[1], g2[1], u), lerp(g1[2], g2[2], u), lerp(g1[3], g2[3], u))
        local tx, ty, tz = at(c, f, a, lerp(t1[1], t2[1], u), lerp(t1[2], t2[2], u), lerp(t1[3], t2[3], u))
        setP(gx, gy, gz, tx, ty, tz)
    end
    -- At rest: leaning on the spade, its blade planted a little in front.
    local function leanPose(feet, f)
        setP(feet[1] + f[1] * 7, feet[2] + 17, feet[3] + f[3] * 7, feet[1] + f[1] * 12, feet[2] - 2, feet[3] + f[3] * 12)
    end
    -- Aiming: held low along the aim.
    local function readyPose(c, f, a)
        local gx, gy, gz = at(c, f, a, -3, -1, 0)
        local tx, ty, tz = at(c, f, a, 0, 0, 24)
        setP(gx, gy, gz, tx, ty, tz)
    end
    -- A strike: raised over the head and behind, then down along the aim.
    local function strikePose(c, f, a, t)
        if t < 0.18 then
            local u = ease(t / 0.18)
            local gx, gy, gz = at(c, f, a, lerp(-3, -2, u), lerp(-1, 8, u), 0)
            local tx, ty, tz = at(c, f, a, lerp(0, -8, u), lerp(0, 26, u), lerp(24, 0, u))
            setP(gx, gy, gz, tx, ty, tz)
        else
            local u = ease(seg(t, 0.18, 0.3))
            local gx, gy, gz = at(c, f, a, lerp(-2, 0, u), lerp(8, 0, u), lerp(0, 6, u))
            local tx, ty, tz = at(c, f, a, lerp(-8, 0, u), lerp(26, 0, u), lerp(0, 30, u))
            setP(gx, gy, gz, tx, ty, tz)
        end
    end
    -- Places the blade's point on (px, py, pz), coming in along the unit direction (dx, dy, dz).
    local function tipAt(px, py, pz, dx, dy, dz)
        local L = (GS.TIP - GS.GRIP) * GS.SCALE
        setP(px - dx * L, py - dy * L, pz - dz * L, px, py, pz)
    end

    -- No poses: the shaft goes through the worm's fists (the engine's Bat hold), turned the way the pose above aims it,
    -- so a scoop, a lever and a fling turn the spade in the hands instead of moving hands that cannot move.
    local function fists(feet, f)
        return feet[1] + f[1] * GS.FIST_F, feet[2] + GS.FIST_Y, feet[3] + f[3] * GS.FIST_F
    end
    local function pinToFists(hx, hy, hz)
        local dx, dy, dz = norm3(P.tx - P.gx, P.ty - P.gy, P.tz - P.gz)
        local back = (GS.FRONT - GS.GRIP) * GS.SCALE * 0.5        -- the fists sit between the D-grip and the front hand
        local L = (GS.TIP - GS.GRIP) * GS.SCALE
        setP(hx - dx * back, hy - dy * back, hz - dz * back, hx + dx * (L - back), hy + dy * (L - back), hz + dz * (L - back))
    end

    -- The drawn spade of one worm follows its target with a short time constant (no pose ever snaps).
    local function follow(st, dt)
        local k = 1 - exp(-dt * GS.FOLLOW)
        if not st.gx then
            st.gx, st.gy, st.gz, st.tx, st.ty, st.tz = P.gx, P.gy, P.gz, P.tx, P.ty, P.tz
            return
        end
        st.gx, st.gy, st.gz = st.gx + (P.gx - st.gx) * k, st.gy + (P.gy - st.gy) * k, st.gz + (P.gz - st.gz) * k
        st.tx, st.ty, st.tz = st.tx + (P.tx - st.tx) * k, st.ty + (P.ty - st.ty) * k, st.tz + (P.tz - st.tz) * k
    end
    -- The mesh's frame from a drawn pose: +Y from the grip to the aim point, +X across the blade (level when it can be).
    local function spadeFrame(st)
        local yx, yy, yz = norm3(st.tx - st.gx, st.ty - st.gy, st.tz - st.gz)
        local ux, uy, uz = 0, 1, 0
        if abs(yy) > 0.95 then ux, uy, uz = st.fx or 0, 0, st.fz or 1 end
        local xx, xy, xz = norm3(cross(yx, yy, yz, ux, uy, uz))
        local zx, zy, zz = cross(xx, xy, xz, yx, yy, yz)
        return xx, xy, xz, yx, yy, yz, zx, zy, zz
    end
    -- The hands' targets: the rear hand on the D-grip, the front hand down the shaft.
    local function handPoints(st)
        local xx, xy, xz, yx, yy, yz = spadeFrame(st)
        local d = (GS.FRONT - GS.GRIP) * GS.SCALE
        return st.gx, st.gy, st.gz, st.gx + yx * d, st.gy + yy * d, st.gz + yz * d
    end
    local function drawSpade(st, alpha)
        if not (GS.mesh and wum.draw.mesh) then return end
        local xx, xy, xz, yx, yy, yz, zx, zy, zz = spadeFrame(st)
        local s = GS.SCALE
        local ox, oy, oz = st.gx - yx * GS.GRIP * s, st.gy - yy * GS.GRIP * s, st.gz - yz * GS.GRIP * s
        local m = { xx * s, xy * s, xz * s, 0, yx * s, yy * s, yz * s, 0, zx * s, zy * s, zz * s, 0, ox, oy, oz, 1 }
        local a = floor(clamp(alpha or 1, 0, 1) * 255 + 0.5)
        pcall(wum.draw.mesh, GS.mesh, GS.tex, m, 0xffffff00 | a,
              { lit = true, ambient = 0.55, cull = false, depthWrite = a >= 255, blend = "alpha" })
    end
    -- The spade's point in the world, as drawn.
    local function tipOf(st)
        local xx, xy, xz, yx, yy, yz = spadeFrame(st)
        local L = (GS.TIP - GS.GRIP) * GS.SCALE
        return st.gx + yx * L, st.gy + yy * L, st.gz + yz * L
    end

    -- Which posed hand goes to the grip: the wrist nearer the worm's right side, learned once from the tracked bones.
    local function handsFor(slot, f, r, gx, gy, gz, hx, hy, hz)
        local sw = GS.pose.swap[slot]
        if sw == nil then
            local b = bones(slot)
            local lx, ly, lz = bone(b, "wrist_left")
            local rx, ry, rz = bone(b, "wrist_right")
            if lx and rx then
                sw = (rx * r[1] + rz * r[3]) < (lx * r[1] + lz * r[3])
                GS.pose.swap[slot] = sw
            end
        end
        local grip, front = { target = { gx, gy, gz } }, { target = { hx, hy, hz } }
        if sw then return front, grip end
        return grip, front        -- rightHand, leftHand
    end

    -- ------------------------------------------------------------ digging and striking (every wielder, every frame)
    local function material() return GS.material end
    local function dirOf(s)
        local p = (s.aim or 0) * GS.aimSign
        local yaw = s.yaw or 0
        return sin(yaw) * cos(p), sin(p), cos(yaw) * cos(p)
    end

    function GS.onDig(slot, x0, y0, z0, x1, y1, z1, removed)
        local st = GS.w[slot] or {}
        GS.w[slot] = st
        local t = os.clock()
        st.digAt, st.digging = t, true
        st.dx, st.dy, st.dz = norm3(x1 - x0, y1 - y0, z1 - z0)
        local s = W[slot]
        if s and s.aim then
            -- learn the sign of the reported aim from the sim's own direction (the pitch sign is unconfirmed in game)
            local _, py = dirOf(s)
            if abs(st.dy) > 0.25 and abs(py) > 0.25 and (st.dy > 0) ~= (py > 0) then GS.aimSign = -GS.aimSign end
        end
        local m = material()
        local mx, my, mz = x0 + (x1 - x0) * 0.35, y0 + (y1 - y0) * 0.35, z0 + (z1 - z0) * 0.35
        if removed < 0 then
            -- the budget is spent: the blade rings off the face, nothing comes away
            SpadeFX.sparks(mx, my, mz, -st.dx, -st.dy + 0.3, -st.dz, 8, "stone")
            play("spade_ring", 0.5, mx, my, mz)
        elseif removed == 0 then
            SpadeFX.scoop(mx, my, mz, st.dx, st.dy, st.dz, m, 0.35)
            play("dig_scoop" .. random(1, 3), 0.35, mx, my, mz)
        else
            SpadeFX.scoop(mx, my, mz, st.dx, st.dy, st.dz, m, clamp(0.7 + removed * 0.08, 0.7, 1.6))
            if m == "stone" or m == "building" then
                play("dig_stone", 0.75, mx, my, mz)
            else
                play("dig_scoop" .. random(1, 3), 0.85, mx, my, mz)
            end
            SpadeFX.settle(x1, y1, z1, 14, m)
        end
    end
    function GS.onRelease(slot)
        local st = GS.w[slot]
        if st then st.digging = false end
    end
    function GS.onSwing(slot)
        local st = GS.w[slot] or {}
        GS.w[slot] = st
        st.swingAt = os.clock()
        local s = W[slot]
        if s then play("swing", 0.8, s.px, s.py + CENTRE_Y, s.pz) end
    end
    function GS.onHit(a, v)
        local s = W[v]
        if not s then return end
        local sa = W[a]
        local dx, dz = 0, 1
        if sa then
            local nx, _, nz = norm3(s.px - sa.px, 0, s.pz - sa.pz)
            dx, dz = nx, nz
        end
        SpadeFX.sparks(s.px - dx * 4, s.py + CENTRE_Y, s.pz - dz * 4, dx, 0.4, dz, 10, "stone")
        SpadeFX.shake(1.2, 0.25)
    end

    -- A worm wields the spade: the pose this frame, and the drawn spade following it.
    local function wield(slot, s, st, dt, t)
        local feet = { s.rx or s.px, s.ry or s.py, s.rz or s.pz }
        local r, u, f = wormFrame(s.yaw or 0)
        st.fx, st.fz = f[1], f[3]
        local c = { feet[1], feet[2] + CENTRE_Y, feet[3] }
        local ax, ay, az = dirOf(s)
        local aimMoved = st.lastAim == nil or abs((s.aim or 0) - st.lastAim) > 0.002 or abs((s.yaw or 0) - (st.lastYaw or 0)) > 0.002
        if aimMoved then st.aimAt = t end
        st.lastAim, st.lastYaw = s.aim or 0, s.yaw or 0
        local q = st.digAt and (t - st.digAt) / GS.STROKE
        if st.swingAt and t - st.swingAt < 0.7 then
            strikePose(c, f, { ax, ay, az }, t - st.swingAt)
        elseif q and (q < 1 or (st.digging and q < 2.5)) then
            -- the dig: a held dig keeps cycling until its next bite arrives; a tap plays one cycle and settles
            local a = { st.dx or ax, st.dy or ay, st.dz or az }
            digPose(c, f, a, q < 1 and q or 1)
        elseif t - (st.aimAt or 0) < 1.6 then
            readyPose(c, f, { ax, ay, az })
        else
            leanPose(feet, f)
        end
        local posing = poseOk()
        if not posing then pinToFists(fists(feet, f)) end
        follow(st, dt)
        if not posing then
            st.posed = false
            return
        end
        local gx, gy, gz, hx, hy, hz = handPoints(st)
        local rh, lh = handsFor(slot, f, r, gx, gy, gz, hx, hy, hz)
        -- the palette only: the hands ride the spade. Nothing moves the body or the joints in a normal turn.
        local spec = { rightHand = rh, leftHand = lh }
        -- the first frames only track the bones, so the hands can be told apart before they are moved
        if GS.pose.swap[slot] == nil and poseOk() then
            st.learn = (st.learn or 0) + 1
            if st.learn > 3 then GS.pose.swap[slot] = false end
            spec = {}
        end
        st.posed = setPose(slot, spec)
    end

    -- ------------------------------------------------------------ the mount (Melange 0.16 worm poses)
    -- The victim turns to face its killer and falls on its back, head away from him; the attacker hops onto its lower
    -- body facing its head, sets the blade on its chest, slides it up to the neck, raises the spade over its head and
    -- chops. The body layer (the drawn mesh's own transform) lays the victim down and carries the attacker, so hats and
    -- shadows follow; the game's clips and sliders give the hunch, the cower and the looks; the palette puts both
    -- worms' hands on the shaft. All of it is drawn here only: the sim pins both worms where they stand.
    local MT = {
        BACK = 12,          -- the attacker's feet this far from the victim's feet toward him (on its lower body)
        UP = 5.5,           -- and this high over the victim's feet (on its belly)
        LEAN = 16,          -- the attacker's lean over the chest (degrees)
        HOP = 10,           -- the hop on and off
        LIFT = 4,           -- a worm on its back is raised this much onto the ground
        HEAD_C = 9,         -- the head's middle from the neck along the lying body
    }
    function MT.deg(r) return r * DEG end
    function MT.wrap(a)
        a = (a + pi) % (2 * pi)
        return a - pi
    end
    function MT.turn(a, b, u) return a + MT.wrap(b - a) * u end
    -- A posed worm's up and forward (pitch in degrees, + forward onto its face, about its right axis after the heading).
    function MT.dirs(pitchDeg, head)
        local p = pitchDeg / DEG
        local fx, fz, cp, sp = sin(head), cos(head), cos(p), sin(p)
        return { sp * fx, cp, sp * fz }, { cp * fx, -sp, cp * fz }
    end
    -- The world point h along the posed up and f along the posed forward from the drawn origin o.
    function MT.pt(o, pitchDeg, head, h, f)
        local u, g = MT.dirs(pitchDeg, head)
        return o[1] + u[1] * h + g[1] * f, o[2] + u[2] * h + g[2] * f, o[3] + u[3] * h + g[3] * f
    end
    -- Squared distance from a point to the segment a-b.
    function MT.pointSeg2(x, y, z, a, b)
        local ux, uy, uz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
        local uu = ux * ux + uy * uy + uz * uz
        local s = uu > 1e-6 and clamp(((x - a[1]) * ux + (y - a[2]) * uy + (z - a[3]) * uz) / uu, 0, 1) or 0
        local dx, dy, dz = x - a[1] - ux * s, y - a[2] - uy * s, z - a[3] - uz * s
        return dx * dx + dy * dy + dz * dz, a[1] + ux * s, a[2] + uy * s, a[3] + uz * s
    end
    -- Does the sight line p -> q (its first 85 %) pass within r of the capsule axis a-b?
    function MT.blocks(p, q, a, b, r)
        for i = 0, 8 do
            local s = i / 8 * 0.85
            if MT.pointSeg2(p[1] + (q[1] - p[1]) * s, p[2] + (q[2] - p[2]) * s, p[3] + (q[3] - p[3]) * s, a, b) < r * r then
                return true
            end
        end
        return false
    end
    -- The eye pushed out of a capsule (axis a-b, radius r), away from the axis (or from the target when on it).
    function MT.pushOut(px, py, pz, a, b, r, tx, ty, tz)
        local d2, qx, qy, qz = MT.pointSeg2(px, py, pz, a, b)
        if d2 >= r * r then return px, py, pz end
        local dx, dy, dz = px - qx, py - qy, pz - qz
        local d = sqrt(d2)
        if d < 1e-3 then
            dx, dy, dz = px - tx, py - ty, pz - tz
            d = sqrt(dx * dx + dy * dy + dz * dz)
            if d < 1e-3 then dx, dy, dz, d = 0, 1, 0, 1 end
        end
        return qx + dx / d * r, qy + dy / d * r, qz + dz / d * r
    end
    -- A row vector times a 3x3 given as rows.
    function MT.vmul(v, m)
        return v[1] * m[1] + v[2] * m[4] + v[3] * m[7], v[1] * m[2] + v[2] * m[5] + v[3] * m[8],
               v[1] * m[3] + v[2] * m[6] + v[3] * m[9]
    end

    -- Poses, spade and the points the beats need, for one frame. `out` eases everything back to rest at the end.
    function MT.frame(e, T, dt, t, out)
        local chop = e.chop
        local hv = math.atan(-e.dx, -e.dz)          -- the victim faces its killer
        local ha = math.atan(e.dx, e.dz)            -- the attacker faces the victim's head
        local cut = e.chopped and not e.aborted
        local vout = cut and 1 or out                -- a beheaded victim stays down
        -- ---------------------------------------------------------------- the victim
        local fall = seg(T, 0.3, 1.15)
        local vPitch = -90 * fall * fall
        if T >= 1.15 and T < 1.35 then vPitch = -90 + 6 * sin(pi * seg(T, 1.15, 1.35)) end    -- the bounce
        if T >= 2.0 and T < 2.15 then vPitch = -90 + 4 * sin(pi * seg(T, 2.0, 2.15)) end      -- the mount lands on it
        local vHead = MT.turn(e.vYaw, hv, ease(seg(T, 0, 0.35)))
        local lift = MT.LIFT * smooth(fall)
        vPitch, vHead, lift = vPitch * vout, MT.turn(e.vYaw, vHead, vout), lift * vout
        local vspec = { body = { pitch = vPitch, heading = MT.deg(vHead), move = { 0, lift, 0 } } }
        local vUp, vFwd = MT.dirs(vPitch, vHead)
        local oV = { e.vx, e.vy + 3 + lift, e.vz }
        -- the neck and the chest as drawn (wormBones), else where the lying body puts them
        local b = bones(e.v)
        local nx, ny, nz = bone(b, "neck")
        if not nx then nx, ny, nz = MT.pt(oV, vPitch, vHead, -2, 0.2) end
        local neck = { nx, ny, nz }
        local surf = { nx + vFwd[1] * 3.5, ny + vFwd[2] * 3.5, nz + vFwd[3] * 3.5 }        -- the throat's skin
        local chest = { nx - vUp[1] * 3 + vFwd[1] * 4.3, ny - vUp[2] * 3 + vFwd[2] * 4.3, nz - vUp[3] * 3 + vFwd[3] * 4.3 }
        e.vUp, e.vFwd, e.neck = vUp, vFwd, neck
        e.capV = { { oV[1] - vUp[1] * 12, oV[2] - vUp[2] * 12, oV[3] - vUp[3] * 12 },
                   { oV[1] + vUp[1] * 22, oV[2] + vUp[2] * 22, oV[3] + vUp[3] * 22 } }
        local clips, sl = {}, {}
        if T < 1.4 then
            clips[1] = { name = "Cower", time = min(T, 3.8), weight = 1.5 * vout }
            sl.HeadRotX = 1 + 0.4 * smooth(seg(T, 0.3, 1.0))
        elseif T < chop then
            clips[1] = { name = "Terror", time = (T - 1.4) % 2.0, weight = 1.2 * vout }
            if T > 3.0 then
                sl.HeadRotY = 1 + 0.15 * sin(9 * T)
                -- the tail beats on the ground (the palette: TailAngle would stand a lying worm's tail up)
                vspec.tail = { rot = { 6 * sin(2 * pi * 3 * T), 0, 0 } }
            end
        else
            -- the throes: the stump's tail twitches, weaker and weaker
            local k = exp(-(T - chop) * 0.8)
            vspec.tail = { rot = { 10 * sin(2 * pi * 2.2 * T) * k, 6 * sin(2 * pi * 3.1 * T) * k, 0 } }
        end
        -- the tail straightened in line with the body (TailAngle 0), so it lies flat instead of standing up: a worm's tail
        -- runs back along the ground, which on its back would point at the sky
        sl.TailAngle = 1 - smooth(fall) * vout
        vspec.clips, vspec.sliders = clips, sl
        if cut then vspec.hide = { head = "stump", attachments = "hide" } end
        if T > 2.2 and T < 4.4 and e.st.gx then
            -- its hands go to the shaft above the blade and shake there
            local tx, ty, tz = tipOf(e.st)
            local gx, gy, gz = e.st.gx, e.st.gy, e.st.gz
            local sh = sin(T * 31) * 0.5 * smooth(seg(T, 2.2, 2.6))
            vspec.leftHand = { target = { lerp(tx, gx, 0.3) + sh, lerp(ty, gy, 0.3), lerp(tz, gz, 0.3) } }
            vspec.rightHand = { target = { lerp(tx, gx, 0.5) - sh, lerp(ty, gy, 0.5), lerp(tz, gz, 0.5) } }
        end
        if W[e.v] or e.preview then setPose(e.v, vspec) end
        if cut and not e.ending then e.vFinal = { body = vspec.body, hide = vspec.hide, sliders = { TailAngle = 0 } } end
        -- ---------------------------------------------------------------- the attacker
        local M = { e.vx - e.dx * MT.BACK, e.vy + MT.UP, e.vz - e.dz * MT.BACK }
        local on, off = ease(seg(T, 1.25, 2.0)), ease(seg(T, 8.4, 9.6))
        local k = on * (1 - off)
        local arc = MT.HOP * (sin(pi * seg(T, 1.25, 2.0)) + sin(pi * seg(T, 8.4, 9.6)))
        local at = { lerp(e.ax, M[1], k), lerp(e.ay, M[2], k) + arc, lerp(e.az, M[3], k) }
        local aHead = MT.turn(e.aYaw, ha, ease(seg(T, 0, 1.25)) * (1 - off))
        local aPitch
        -- a lean over the chest (more and its head would cover the throat), straighter for the raise, a lunge for the chop
        if T < 1.25 then aPitch = 0
        elseif T < 2.0 then aPitch = MT.LEAN * on
        elseif T < 4.4 then aPitch = MT.LEAN
        elseif T < 5.1 then aPitch = lerp(MT.LEAN, 6, ease(seg(T, 4.4, 5.1)))
        elseif T < chop then aPitch = lerp(6, 32, seg(T, 5.1, chop) ^ 2)
        elseif T < 6.0 then aPitch = 32
        elseif T < 6.6 then aPitch = lerp(32, 10, ease(seg(T, 6.0, 6.6)))
        else aPitch = 10 * (1 - off) end
        aPitch, aHead = aPitch * out, MT.turn(e.aYaw, aHead, out)
        at = { lerp(e.ax, at[1], out), lerp(e.ay, at[2], out), lerp(e.az, at[3], out) }
        local aspec = { body = { pitch = aPitch, heading = MT.deg(aHead), at = at } }
        local ac, asl = {}, {}
        if T < 4.4 then
            ac[1] = { name = "HoldBat", time = (T * 0.8) % 2.0, weight = 2 * out }
        elseif T < 5.1 then
            ac[1] = { name = "Fire2Bat", time = 0.35, weight = 2 * out }
        elseif T < chop then
            ac[1] = { name = "Fire2Bat", time = lerp(0.35, 1.0, seg(T, 5.1, chop)), weight = 2 * out }
        elseif T < 6.6 then
            ac[1] = { name = "Fire2Bat", time = 1.0, weight = lerp(2, 0.2, seg(T, chop + 0.3, 6.6)) * out }
            ac[2] = { name = "HoldBat", time = (T * 0.8) % 2.0, weight = lerp(0, 1.5, seg(T, chop + 0.3, 6.6)) * out }
        else
            ac[1] = { name = "HoldBat", time = (T * 0.8) % 2.0, weight = 1.5 * (1 - off) * out }
        end
        if T > 2.2 and T < 5.1 then asl.HeadRotX = lerp(1, 0.8, smooth(seg(T, 2.2, 2.6))) end
        aspec.clips, aspec.sliders = ac, asl
        local oA = { at[1], at[2] + 3, at[3] }
        local aUp = MT.dirs(aPitch, aHead)
        e.capA = { { oA[1], oA[2], oA[3] }, { oA[1] + aUp[1] * 26, oA[2] + aUp[2] * 26, oA[3] + aUp[3] * 26 } }
        e.focus = { (chest[1] + oA[1]) * 0.5, (chest[2] + oA[2]) * 0.5 + 6, (chest[3] + oA[3]) * 0.5 }
        -- ---------------------------------------------------------------- the spade
        local cx, cy, cz = MT.pt(oA, aPitch, aHead, 11, 0)
        local cA = { cx, cy, cz }
        local hd = { sin(aHead), 0, cos(aHead) }
        local function carried() setP(cx + hd[1] * 2, cy + 8, cz + hd[3] * 2, cx + hd[1] * 9, cy - 14, cz + hd[3] * 9) end
        local dx, dy, dz = norm3(e.dx * 0.28, -1, e.dz * 0.28)        -- the blade comes down steep, a little forward
        local L = (GS.TIP - GS.GRIP) * GS.SCALE
        if T < 1.25 then
            readyPose(cA, hd, { hd[1], -0.25, hd[3] })
        elseif T < 2.2 then
            carried()
        elseif T < 3.0 then
            local u = ease(seg(T, 2.2, 3.0))
            tipAt(chest[1], chest[2] + 12 * (1 - u), chest[3], dx, dy, dz)
        elseif T < 3.8 then
            local tr = sin(T * 41) * 0.25
            tipAt(chest[1] + tr, chest[2] + 0.3, chest[3] - tr, dx, dy, dz)
        elseif T < 4.4 then
            local u = ease(seg(T, 3.8, 4.4))
            tipAt(lerp(chest[1], surf[1], u), lerp(chest[2], surf[2], u) + 0.3, lerp(chest[3], surf[3], u), dx, dy, dz)
        else
            -- raised over the head, the blade's point toward the neck; then down through it
            local gx, gy, gz = MT.pt(oA, aPitch, aHead, 27, -3)
            if T < chop then e.raise = { gx, gy, gz } end
            local G = e.raise or { gx, gy, gz }
            local sx, sy, sz = norm3(neck[1] - G[1], neck[2] - G[2], neck[3] - G[3])
            if T < 5.1 then
                local u = ease(seg(T, 4.4, 5.1))
                local px, py, pz = lerp(surf[1] - dx * L, G[1], u), lerp(surf[2] - dy * L, G[2], u), lerp(surf[3] - dz * L, G[3], u)
                setP(px, py, pz, neck[1], neck[2], neck[3])
            elseif T < chop then
                local u = seg(T, 5.1, chop) ^ 2
                local ex, ey, ez = G[1] + sx * L, G[2] + sy * L, G[3] + sz * L
                tipAt(lerp(ex, neck[1] + sx * 3, u), lerp(ey, neck[2] + sy * 3, u), lerp(ez, neck[3] + sz * 3, u), sx, sy, sz)
            elseif T < 6.0 then
                tipAt(neck[1] + sx * 3, neck[2] + sy * 3, neck[3] + sz * 3, sx, sy, sz)
            elseif T < 6.6 then
                local u = ease(seg(T, 6.0, 6.6))
                tipAt(neck[1] + sx * lerp(3, -10, u), neck[2] + sy * lerp(3, -10, u) + 8 * u, neck[3] + sz * lerp(3, -10, u), sx, sy, sz)
            else
                carried()
            end
        end
        e.st.fx, e.st.fz = hd[1], hd[3]
        if T >= chop - 0.3 and T < chop + 0.4 then
            -- the chop is a snap: no smoothing lag on the blade
            local kf = GS.FOLLOW
            GS.FOLLOW = 90
            follow(e.st, dt)
            GS.FOLLOW = kf
        else
            follow(e.st, dt)
        end
        if T >= chop - 0.3 and not e.swung then
            e.swung = true
            play("swing", 0.9, cx, cy, cz)
        end
        local gx, gy, gz, hx, hy, hz = handPoints(e.st)
        local r = { -hd[3], 0, hd[1] }
        aspec.rightHand, aspec.leftHand = handsFor(e.a, hd, r, gx, gy, gz, hx, hy, hz)
        if W[e.a] or e.preview then setPose(e.a, aspec) end
        e.mountAt = M
        return neck[1], neck[2], neck[3], chest[1], chest[2], chest[3], M[1], M[3]
    end

    -- ------------------------------------------------------------ the execution
    local exUpright
    -- Seconds on the sim's clock since the execution started (wum.game.tick, smoothed between ticks with the wall clock);
    -- the wall clock alone when the tick is not usable (a preview, or a Melange without the sim bridge).
    local function exTime(e)
        local okT, tk = pcall(wum.game.tick)
        tk = okT and tonumber(tk) or 0
        local t = os.clock()
        if e.t0 and tk > 0 and tk - e.t0 >= -5 and tk - e.t0 < e.endT + 300 then
            if tk ~= e.lastTick then e.lastTick, e.tickAt = tk, t end
            local T = (tk - e.t0) / GS.TICK + min(t - (e.tickAt or t), 1 / GS.TICK)
            if T < (e.T or 0) then T = e.T end
            e.T = T
            return T
        end
        local T = (t - e.at) + (e.lead or 0)
        if T < (e.T or 0) then T = e.T end
        e.T = T
        return T
    end

    local function nameOf(slot)
        local okW, list = pcall(wum.game.worms)
        if okW and type(list) == "table" then
            for i = 1, #list do
                if type(list[i]) == "table" and list[i].slot == slot then return tostring(list[i].name or ("worm " .. slot)) end
            end
        end
        return "worm " .. slot
    end

    function GS.exStart(a, v, t0, chop, throes, endT, ax, ay, az, vx, vy, vz, preview)
        local e = { a = a, v = v, t0 = t0, at = os.clock(), chop = chop / GS.TICK, throes = throes / GS.TICK,
                    endT = endT, fin = endT / GS.TICK, preview = preview, gore = GS.goreMode(), an = nameOf(a), vn = nameOf(v) }
        local sa, sv = W[a], W[v]
        -- where the strike put the pair: the drawn (tracked) position, unless it is more than 6 units off the sim's. After
        -- a long frame gap the sim runs the strike before this frame's tracking, and the tracked attacker is still where
        -- it was mid-walk.
        local function fresh(s, x, y, z)
            if not s or not s.px then return false end
            if not x then return true end
            local ddx, ddy, ddz = s.px - x, s.py - y, s.pz - z
            return ddx * ddx + ddy * ddy + ddz * ddz < 36
        end
        if fresh(sa, ax, ay, az) then e.ax, e.ay, e.az = sa.px, sa.py, sa.pz else e.ax, e.ay, e.az = ax, ay, az end
        if fresh(sv, vx, vy, vz) then e.vx, e.vy, e.vz = sv.px, sv.py, sv.pz else e.vx, e.vy, e.vz = vx, vy, vz end
        e.ax, e.ay, e.az = e.ax or 0, e.ay or 0, e.az or 0
        e.vx, e.vy, e.vz = e.vx or 0, e.vy or 0, e.vz or 0
        local dx, _, dz, l = norm3(e.vx - e.ax, 0, e.vz - e.az)
        if l < 3 then
            local yaw = (sa and sa.yaw) or 0
            dx, dz = sin(yaw), cos(yaw)
        end
        e.dx, e.dz = dx, dz
        -- the frames: the victim turns to face its killer and falls on its back, head away from him; the attacker faces the
        -- victim's head
        local rv, uv, fv = wormFrame((sv and sv.yaw) or 0)
        local up, head = { 0, 1, 0 }, { dx, 0, dz }
        local rx2, ry2, rz2 = cross(up[1], up[2], up[3], head[1], head[2], head[3])
        e.vRot = frameMap(rv, uv, fv, { rx2, ry2, rz2 }, head, up)
        e.vRotRev = { rv, uv, fv }
        local ra, ua, fa = wormFrame((sa and sa.yaw) or 0)
        e.aFrame = { ra, ua, fa }
        -- the victim's middle (the main bone, the turn's pivot), from its tracked bones when there are any
        local b = bones(v)
        local mx, my, mz = bone(b, "main")
        e.vMainY = my and (my - e.vy) or 17
        b = bones(a)
        mx, my, mz = bone(b, "main")
        e.aMainY = my and (my - e.ay) or 17
        e.orbit = { th = math.atan(-dz, dx), r = 90, el = 0.62, fov = 52, cx = nil }
        e.vYaw = (sv and sv.yaw) or 0
        e.aYaw = (sa and sa.yaw) or math.atan(dx, dz)
        e.cam = cfg("cinematic", true) ~= false and wum.render.cameraOverride ~= nil
        -- the mount needs the body layer (the drawn worm laid down and carried) and the palette (hands, the stump)
        local caps = poseCaps()
        e.posed = poseOk() == true and caps.body == true and caps.palette == true
        e.st = GS.w[a] or {}
        GS.w[a] = e.st
        GS.ex = e
        play("exec_sting", 1.0)
        play("spade_ring", 0.9, e.vx, e.vy + CENTRE_Y, e.vz)
        SpadeFX.shake(2.0, 0.35)
        if S.preset and S.melee then startFlash(e.vx, e.vy + CENTRE_Y, e.vz, 60, v) end
        if not preview then emitExec({ phase = "start", slot = v, attacker = a, chopIn = e.chop }) end
    end

    function GS.exEnd(abort)
        local e = GS.ex
        if not e or e.ending then return end
        e.ending = os.clock()
        e.endFrom = e.T or 0
        if abort and not e.preview then
            if not e.chopped then
                emitExec({ phase = "abort", slot = e.v })
            elseif e.aborted then
                -- the sim took the kill back after the chop: the worm lives, so its head is back on and Bloodsand
                -- forgets the stump
                if e.headRef then e.headRef.dead = true end
                emitExec({ phase = "abort", slot = e.v, chopped = true })
            end
        end
    end

    -- The victim's posed points: the neck (the head bone) and the chest, from its bones as drawn, or from the lying frame.
    local function victimPoints(e)
        local b = bones(e.v)
        local nx, ny, nz = bone(b, "head")
        local mx, my, mz = bone(b, "main")
        if nx and mx then
            e.nx, e.ny, e.nz, e.mx, e.my, e.mz = nx, ny, nz, mx, my, mz
        elseif not e.nx then
            e.mx, e.my, e.mz = e.vx, e.vy + 5, e.vz
            e.nx, e.ny, e.nz = e.vx + e.dx * 10, e.vy + 5, e.vz + e.dz * 10
        end
        return e.nx, e.ny, e.nz, e.mx + (e.nx - e.mx) * 0.6, e.my + (e.ny - e.my) * 0.6 + 2.5, e.mz + (e.nz - e.mz) * 0.6
    end

    -- The severed head: thrown from the neck along the victim's head direction, rolling on the land (one ray a frame).
    -- It never comes at the lens: the part of its direction toward the eye is taken off until it leaves at least HEAD_AWAY
    -- away from it (seen from the eye, it flies off along the body and away, never into the camera).
    local function headDir(e, nx, nz)
        local dx, dz = e.dx, e.dz
        local p = e.camPos
        local cx, cz
        if p then cx, cz = p[1] - nx, p[3] - nz
        elseif e.orbit and e.orbit.th then cx, cz = sin(e.orbit.th), cos(e.orbit.th) end
        if cx then
            local l = sqrt(cx * cx + cz * cz)
            if l > 1e-3 then
                cx, cz = cx / l, cz / l
                local k = dx * cx + dz * cz
                if k > -GS.HEAD_AWAY then
                    dx, dz = dx - cx * (k + GS.HEAD_AWAY), dz - cz * (k + GS.HEAD_AWAY)
                    local m = sqrt(dx * dx + dz * dz)
                    if m < 1e-3 then dx, dz = -cx, -cz else dx, dz = dx / m, dz / m end
                end
            end
        end
        return dx, dz
    end
    local function launchHead(e, nx, ny, nz)
        local hdx, hdz = headDir(e, nx, nz)
        local h = { slot = e.v, x = nx, y = ny + 5, z = nz, floorY = e.vy, vx = hdx * rnd(55, 75), vy = rnd(70, 95), vz = hdz * rnd(55, 75),
                    R = IDENT, born = os.clock(), copy = e.posed, gore = e.gore, yaw = e.vYaw or 0, rolled = 0, bounces = 0,
                    preview = e.preview }
        if e.posed and e.vUp then
            -- the head lies along the body: its middle is HEAD_C out from the neck, and the copy turns about it. The client
            -- mesh (neck at its origin, +Y up, face +Z) is laid the same way: +Y along the body, the face to the sky.
            local u, f = e.vUp, e.vFwd
            h.x, h.y, h.z = nx + u[1] * MT.HEAD_C, ny + u[2] * MT.HEAD_C, nz + u[3] * MT.HEAD_C
            h.neckOff = { nx - h.x, ny - h.y, nz - h.z }
            local rx, ry, rz = cross(u[1], u[2], u[3], f[1], f[2], f[3])
            h.base = { rx, ry, rz, u[1], u[2], u[3], f[1], f[2], f[3] }
            h.vx, h.vz = h.vx * 0.8, h.vz * 0.8
        end
        GS.heads[#GS.heads + 1] = h
        return h
    end
    local function stepHead(h, dt, t)
        if h.rest then return end
        local x0, y0, z0 = h.x, h.y, h.z
        h.vy = h.vy - 380 * dt
        local nx, ny, nz = h.x + h.vx * dt, h.y + h.vy * dt, h.z + h.vz * dt
        local hit, hx, hy, hz = castRay(x0, y0 + 2, z0, nx, ny - 5, nz)
        if not hit and hx ~= nil and ny - 5 < h.floorY then
            -- no ray this frame (the budget, or none on this level): the victim's ground is the floor
            hit, hx, hy, hz = clamp((y0 + 2 - h.floorY) / max(1e-3, y0 + 2 - (ny - 5)), 0, 1), 0, 1, 0
        end
        if hit then
            local gx, gy, gz = x0 + (nx - x0) * hit, (y0 + 2) + (ny - 5 - y0 - 2) * hit, z0 + (nz - z0) * hit
            -- bounce off the surface: reflect, lose most of the normal speed and some of the rest
            local vn = h.vx * hx + h.vy * hy + h.vz * hz
            if vn < 0 then
                h.vx, h.vy, h.vz = h.vx - 1.45 * vn * hx, h.vy - 1.45 * vn * hy, h.vz - 1.45 * vn * hz
                if -vn > 30 then
                    h.vx, h.vz = h.vx * 0.8, h.vz * 0.8                     -- a bounce
                else
                    local k = exp(-dt * 1.6)                                -- rolling
                    h.vx, h.vz = h.vx * k, h.vz * k
                end
                h.bounces = h.bounces + 1
                if h.bounces <= 3 and -vn > 40 then
                    play("head_roll", clamp(-vn / 160, 0.25, 0.9), gx, gy, gz)
                    if h.gore ~= "bloodsand" then SpadeFX.settle(gx, gy, gz, 6, "sand") end
                    if not h.preview then emitExec({ phase = "head", slot = h.slot, x = gx, y = gy, z = gz, impact = true }) end
                end
            end
            nx, ny, nz = gx, gy + 5, gz
            local sp = sqrt(h.vx * h.vx + h.vz * h.vz)
            if abs(h.vy) < 25 and sp < 8 then
                h.rest, h.restAt = true, t
                if not h.preview then emitExec({ phase = "headRest", slot = h.slot, x = gx, y = gy, z = gz }) end
            end
        end
        -- rolling: a turn about the horizontal axis across the motion, by the distance over the head's radius
        local mx, mz = nx - h.x, nz - h.z
        local d = sqrt(mx * mx + mz * mz)
        if d > 1e-4 then
            local ax, ay, az = cross(0, 1, 0, mx / d, 0, mz / d)
            h.R = mul(h.R, rotAxis(ax, ay, az, d / 6))
            h.rolled = h.rolled + d
        end
        h.x, h.y, h.z = nx, ny, nz
        if not h.preview and h.rolled - (h.trailAt or 0) > 9 then
            h.trailAt = h.rolled
            emitExec({ phase = "head", slot = h.slot, x = h.x, y = h.y - 5, z = h.z })
        end
    end
    -- The head is the worm's own (wormCopy) while the body is drawn; after that, and when copies are not available, the
    -- client mesh (assets/meshes/gravespade_head.mesh.txt) in the same place.
    local function drawHead(h, t)
        local okCopy = false
        -- the neck as drawn: the copy carries the original neck there (turned by R about the head's middle)
        local px, py, pz = h.x, h.y - 5, h.z
        if h.neckOff then
            local ox, oy, oz = MT.vmul(h.neckOff, h.R)
            px, py, pz = h.x + ox, h.y + oy, h.z + oz
        end
        if h.copy and wum.render.wormCopy and not GS.pose.bad then
            local ok, r = pcall(wum.render.wormCopy, h.slot, { pos = { px, py, pz }, rot = euler(h.R), frames = 4 })
            okCopy = ok and r == true
            if okCopy and h.copyFrom == nil then h.copyFrom = t end
            -- the copy is drawn only while the engine draws the body: once its bones stop coming, the body is gone
            if okCopy and t - h.copyFrom > 0.5 and not bones(h.slot) then okCopy = false end
            if not okCopy then
                h.copy = false
                pcall(wum.render.wormCopy, h.slot, nil)
            end
        end
        if okCopy or not (GS.head and wum.draw.mesh) then return end
        -- the mesh: neck at the origin, +Y up, face toward +Z; turned to the victim's old facing, then by the roll
        local yaw = h.yaw
        local base = h.base or { cos(yaw), 0, -sin(yaw), 0, 1, 0, sin(yaw), 0, cos(yaw) }
        local m = mul(base, h.R)
        local age = t - (h.restAt or t)
        local alpha = 1 - smooth((age - 40) / 4)
        if alpha <= 0 then
            h.dead = true
            return
        end
        local texId = h.gore == "dust" and GS.headClean or GS.headTex
        local model = { m[1], m[2], m[3], 0, m[4], m[5], m[6], 0, m[7], m[8], m[9], 0, px, py, pz, 1 }
        pcall(wum.draw.mesh, GS.head, texId, model, 0xffffff00 | floor(alpha * 255 + 0.5),
              { lit = true, ambient = 0.6, cull = true, depthWrite = alpha >= 1, blend = "alpha" })
    end

    -- The eye kept out of every worm drawn near it: a capsule round each worm's axis (feet to WORM_TOP), pushed out
    -- sideways from the axis, away from the target when the eye is on it. The pair counts even when the game no longer
    -- lists them (the victim is dying).
    local function outOfWorms(e, px, py, pz, tx, tz)
        local R = GS.WORM_R
        local function push(x, y, z)
            if py < y - 4 or py > y + GS.WORM_TOP then return end
            local dx, dz = px - x, pz - z
            local d = sqrt(dx * dx + dz * dz)
            if d >= R then return end
            if d < 1e-3 then
                dx, dz = px - tx, pz - tz
                d = sqrt(dx * dx + dz * dz)
                if d < 1e-3 then dx, dz, d = 1, 0, 1 end
            end
            px, pz = x + dx / d * R, z + dz / d * R
        end
        if e.capV and e.capA then
            -- posed: the victim lies along its capsule, the attacker leans along its own
            px, py, pz = MT.pushOut(px, py, pz, e.capV[1], e.capV[2], R, tx, py, tz)
            px, py, pz = MT.pushOut(px, py, pz, e.capA[1], e.capA[2], R, tx, py, tz)
        else
            push(e.ax, e.ay, e.az)
            push(e.vx, e.vy, e.vz)
        end
        for slot, s in pairs(W) do
            if slot ~= e.a and slot ~= e.v and s.seen == FR.n and s.alive then push(s.px, s.py, s.pz) end
        end
        -- and out of the severed head (a ball of HEAD_R round its middle), so the chop's close shot never sits in it
        local h = e.headRef
        if h and not h.dead then
            local dx, dy, dz = px - h.x, py - h.y, pz - h.z
            local d = sqrt(dx * dx + dy * dy + dz * dz)
            if d < GS.HEAD_R then
                if d < 1e-3 then dx, dy, dz, d = 0, 1, 0, 1 end
                px, py, pz = h.x + dx / d * GS.HEAD_R, h.y + dy / d * GS.HEAD_R, h.z + dz / d * GS.HEAD_R
            end
        end
        return px, py, pz
    end

    -- True when the segment p -> q passes through a worm standing at w (its capsule: OCCLUDE_R round the axis, feet to
    -- WORM_TOP), short of q itself (the last 15 % is the subject, not in front of it).
    local function segThroughWorm(px, py, pz, qx, qy, qz, wx, wy, wz)
        local dx, dy, dz = qx - px, qy - py, qz - pz
        local dd = dx * dx + dz * dz
        local t = dd > 1e-6 and ((wx - px) * dx + (wz - pz) * dz) / dd or 0
        t = clamp(t, 0, 0.85)
        local cx, cy, cz = px + dx * t - wx, py + dy * t, pz + dz * t - wz
        if cx * cx + cz * cz > GS.OCCLUDE_R * GS.OCCLUDE_R then return false end
        return cy >= wy - 2 and cy <= wy + GS.WORM_TOP
    end

    -- The head is worth following while it is still in the air or rolling near the pair, above the ground they stand on;
    -- a head lost, gone over an edge or far away is let go and the camera comes back to the pair.
    local function headFollowable(e, h, cx, cz)
        if not h or h.dead then return false end
        local floor = min(e.vy, e.ay)
        if h.y < floor - 30 then return false end
        local dx, dz = h.x - cx, h.z - cz
        return dx * dx + dz * dz < GS.HEAD_FOLLOW * GS.HEAD_FOLLOW
    end

    -- ------------------------------------------------------------ the execution camera
    -- A small set of shots round the pair, picked by line of sight. The shots stand on either side of the victim's body
    -- axis (the pair's line d: the victim lies along it), square to it or turned up to 0.6 rad off, 2-3 worm lengths out
    -- (XC.RS), at two heights. A shot is seen through land rays from its eye to the victim's neck, the victim's head and
    -- the attacker's head; a sight line that a worm's body crosses counts as blocked too. A shot whose eye is inside a
    -- worm or near a fresh blast (a poison drum's gas cloud) is rejected; one with its eye in the land sees nothing (every
    -- ray starts inside it) and drops out by itself. The land ray does not see level props, so every shot stays above
    -- the pair. A few shots are scored a frame and the one in use is checked every frame where it really is (orbiting):
    -- blocked twice running, it moves in along its own line (a nearer shot of the same direction), else cuts to the best
    -- other shot, its own side first. From the raise through the chop only shots within 0.3 rad of square are taken.
    -- After the chop the target leans after the rolling head for a moment, then a wide shot from above holds the
    -- aftermath (the headless body, the attacker, the spade, the grave, the head) until the hold ends.
    local XC = { OFFS = { 0, 0.3, -0.3, 0.6, -0.6 }, ELS = { 0.36, 0.6 }, RS = { 96, 76, 56 },
                 AOFFS = { 0, 0.45, -0.45, 0.9, -0.9 }, AELS = { 0.62, 0.86 },
                 RAYS = 44,              -- the land rays this mod may cast a frame during an execution
                 KEEP = 0.8,             -- seconds a shot's score is kept before it is looked at again
                 BLAST_R = 90, BLAST_T = 15,     -- no eye this close to a blast of the last BLAST_T seconds (its gas)
                 SIDE = 0.31,            -- the most a shot may be off square from the raise through the chop
                 AFTER = 1.5,            -- seconds after the chop the aftermath shot takes over
                 LEAN = 0.5 }            -- how far the target leans toward the rolling head
    GS.blasts = {}
    -- Explosions (an oil drum the strike set off): their gas hangs where they went off, so the camera keeps out of it.
    function GS.noteBlast(p)
        if type(p) ~= "table" then return end
        local x, y, z = vec(p.damageEpicentre)
        if not x then return end
        local t = os.clock()
        for i = #GS.blasts, 1, -1 do
            if t - GS.blasts[i].t > XC.BLAST_T then table.remove(GS.blasts, i) end
        end
        GS.blasts[#GS.blasts + 1] = { x = x, y = y, z = z, t = t }
        local e = GS.ex
        if e and e.xc then e.xc.stale = true end        -- every score again: some eyes are in the gas now
    end

    -- The middle of the scene the shots look at: the lying victim reaches from 12 behind its feet to 22 past them along
    -- d, the attacker sits on its lower body; upright, the pair's midpoint.
    function XC.focusOf(e)
        if e.posed then return { e.vx + e.dx * 4, e.vy + 10, e.vz + e.dz * 4 } end
        return { (e.ax + e.vx) * 0.5, (e.ay + e.vy) * 0.5 + 12, (e.az + e.vz) * 0.5 }
    end
    -- The points a shot must see before the chop, {point, weight, whose}: the neck, the victim's head, the attacker's
    -- head; from the posed bones once the victim is down and the attacker on it, before that where they will be.
    function XC.points(e)
        local d, T = { e.dx, 0, e.dz }, e.Tnow or 0
        local nk, vh, ah
        if e.posed then
            if e.neck and T > 1.2 then
                nk = e.neck
                local u = e.vUp or d
                vh = { nk[1] + u[1] * MT.HEAD_C, nk[2] + u[2] * MT.HEAD_C + 2, nk[3] + u[3] * MT.HEAD_C }
            else
                local by = e.vy + 3 + MT.LIFT + 4
                nk = { e.vx + d[1] * 19, by, e.vz + d[3] * 19 }
                vh = { e.vx + d[1] * 28, by + 2, e.vz + d[3] * 28 }
            end
            if e.capA and T > 2.0 then ah = e.capA[2]
            else ah = { e.vx - d[1] * 6, e.vy + MT.UP + 24, e.vz - d[3] * 6 } end
        else
            nk = { e.vx, e.vy + GS.NECK_Y, e.vz }
            vh = { e.vx, e.vy + GS.NECK_Y + 5, e.vz }
            ah = { e.ax, e.ay + GS.NECK_Y + 5, e.az }
        end
        return { { nk, 3, "v" }, { vh, 2, "v" }, { ah, 2, "a" } }
    end
    -- After the chop: the body, the attacker's head, the severed head (while it is near) and the spade.
    function XC.aftPoints(e)
        local body = e.posed and { e.vx + e.dx * 6, e.vy + 7, e.vz + e.dz * 6 } or { e.vx, e.vy + 8, e.vz }
        local ah = (e.posed and e.capA) and e.capA[2] or { e.ax, e.ay + GS.NECK_Y + 5, e.az }
        local pts = { { body, 3, "v" }, { ah, 2, "a" } }
        local h = e.headRef
        if h and not h.dead and (h.x - e.vx) ^ 2 + (h.z - e.vz) ^ 2 < 160 * 160 and h.y > min(e.vy, e.ay) - 30 then
            pts[#pts + 1] = { { h.x, h.y, h.z }, 2, "h" }
        end
        if e.st and e.st.gx then pts[#pts + 1] = { { e.st.gx, e.st.gy, e.st.gz }, 1, "a" } end
        return pts
    end
    -- The aftermath frame: the middle of its points and the distance that fits them all at its field of view.
    function XC.aftFrame(e)
        local pts = XC.aftPoints(e)
        local lo, hi = { 1e9, 1e9, 1e9 }, { -1e9, -1e9, -1e9 }
        for _, q in ipairs(pts) do
            for i = 1, 3 do lo[i], hi[i] = min(lo[i], q[1][i]), max(hi[i], q[1][i]) end
        end
        local c = { (lo[1] + hi[1]) * 0.5, (lo[2] + hi[2]) * 0.5 + 4, (lo[3] + hi[3]) * 0.5 }
        local R = 20
        for _, q in ipairs(pts) do
            R = max(R, sqrt((q[1][1] - c[1]) ^ 2 + (q[1][2] - c[2]) ^ 2 + (q[1][3] - c[3]) ^ 2))
        end
        return { c = c, dist = clamp(R / math.tan(27 / DEG) * 1.35, 105, 190), fov = 54 }
    end

    -- Is q in sight from p? No land on the segment short of q and no worm's body across it. `who` says whose point it is
    -- ("v" victim, "a" attacker): a worm's own body does not hide it. nil when the ray budget is spent this frame.
    function XC.sees(e, p, q, who)
        local dx, dy, dz = q[1] - p[1], q[2] - p[2], q[3] - p[3]
        local len = sqrt(dx * dx + dy * dy + dz * dz)
        if len < 1 then return true end
        local hit, why = castRay(p[1], p[2], p[3], q[1], q[2], q[3])
        if hit == nil and why == "budget" then return nil end
        if hit and hit * len < len - 4 then return false end
        if e.capA then
            if who ~= "a" and MT.blocks(p, q, e.capA[1], e.capA[2], GS.OCCLUDE_R) then return false end
        else
            if who ~= "a" and segThroughWorm(p[1], p[2], p[3], q[1], q[2], q[3], e.ax, e.ay, e.az) then return false end
            if who ~= "v" and segThroughWorm(p[1], p[2], p[3], q[1], q[2], q[3], e.vx, e.vy, e.vz) then return false end
        end
        for slot, s in pairs(W) do
            if slot ~= e.a and slot ~= e.v and s.seen == FR.n and s.alive
               and segThroughWorm(p[1], p[2], p[3], q[1], q[2], q[3], s.px, s.py, s.pz) then
                return false
            end
        end
        return true
    end
    -- May an eye stand at p? Not inside a worm, not in a fresh blast's gas.
    function XC.eyeOk(e, p)
        local R2 = GS.WORM_R * GS.WORM_R
        if e.capV and MT.pointSeg2(p[1], p[2], p[3], e.capV[1], e.capV[2]) < R2 then return false end
        if e.capA and MT.pointSeg2(p[1], p[2], p[3], e.capA[1], e.capA[2]) < R2 then return false end
        local function inWorm(x, y, z)
            return p[2] > y - 4 and p[2] < y + GS.WORM_TOP and (p[1] - x) ^ 2 + (p[3] - z) ^ 2 < R2
        end
        if not e.capA and (inWorm(e.ax, e.ay, e.az) or inWorm(e.vx, e.vy, e.vz)) then return false end
        for slot, s in pairs(W) do
            if slot ~= e.a and slot ~= e.v and s.seen == FR.n and s.alive and inWorm(s.px, s.py, s.pz) then return false end
        end
        local t = os.clock()
        for _, b in ipairs(GS.blasts) do
            if t - b.t < XC.BLAST_T and (p[1] - b.x) ^ 2 + (p[2] - b.y) ^ 2 + (p[3] - b.z) ^ 2 < XC.BLAST_R * XC.BLAST_R then
                return false
            end
        end
        return true
    end
    -- How well the eye at angle th, height el, distance r from F sees the points: the summed weight of the points in
    -- sight (less 2 for a blast's gas across the view), whether that is good enough (the first point, the neck or the
    -- body, in sight and at least 5 of 7), and the eye. nil when the rays ran out this frame.
    function XC.eval(e, th, el, r, F, pts)
        local ce = cos(el)
        local p = { F[1] + sin(th) * ce * r, F[2] + sin(el) * r, F[3] + cos(th) * ce * r }
        if not XC.eyeOk(e, p) then return -1, false, p end
        if RAY.used > RAY.cap - #pts - 2 then return nil end
        local w, first = 0, false
        for i, q in ipairs(pts) do
            local s = XC.sees(e, p, q[1], q[3])
            if s == nil then return nil end
            if s then
                w = w + q[2]
                if i == 1 then first = true end
            end
        end
        local t = os.clock()
        local q = { F[1] + (p[1] - F[1]) * 0.25, F[2] + (p[2] - F[2]) * 0.25, F[3] + (p[3] - F[3]) * 0.25 }
        for _, b in ipairs(GS.blasts) do
            if t - b.t < XC.BLAST_T and MT.pointSeg2(b.x, b.y, b.z, p, q) < 40 * 40 then w = w - 2 end
        end
        return w, first and w >= 5, p
    end
    -- The shot set: before the chop each direction at three distances; for the aftermath one distance (aftFrame's).
    function XC.build(e, after)
        local list = {}
        local offs, els = after and XC.AOFFS or XC.OFFS, after and XC.AELS or XC.ELS
        for _, side in ipairs({ 1, -1 }) do
            local base = math.atan(-e.dz * side, e.dx * side)
            for _, off in ipairs(offs) do
                for j, el in ipairs(els) do
                    if after then
                        list[#list + 1] = { side = side, off = off, el = el, r = 0, th = base + off, at = -100,
                                            rank = abs(off) * 4 + (j - 1) * 1.5 }
                    else
                        for k, r in ipairs(XC.RS) do
                            list[#list + 1] = { side = side, off = off, el = el, r = r, th = base + off, at = -100,
                                                rank = abs(off) * 6 + (j - 1) + (k - 1) * 1.5 }
                        end
                    end
                end
            end
        end
        return list
    end
    function XC.score(e, s, F, pts, r, t)
        local w, good = XC.eval(e, s.th, s.el, r or s.r, F, pts)
        if w == nil then return false end
        s.v, s.good, s.at = w * 10 - s.rank, good, t
        return true
    end
    -- Scores the shots whose score is older than KEEP, round the list, while the rays last.
    function XC.refresh(e, c, list, F, pts, r, t)
        if c.stale then
            for _, s in ipairs(list) do s.at = -100 end
        end
        local n = #list
        for _ = 1, n do
            c.idx = c.idx % n + 1
            local s = list[c.idx]
            if t - s.at >= XC.KEEP then
                if not XC.score(e, s, F, pts, r, t) then
                    c.idx = c.idx - 1
                    return
                end
            end
        end
    end
    -- The best good shot (within SIDE of square when sideOnly), a bonus for the side the camera is on.
    function XC.best(list, sideOnly, side, except)
        local b, bv
        for _, s in ipairs(list) do
            if s.good and s ~= except and (not sideOnly or abs(s.off) <= XC.SIDE) then
                local v = s.v + ((side and s.side == side) and 6 or 0)
                if not bv or v > bv then b, bv = s, v end
            end
        end
        return b
    end

    -- The camera for one frame. `c` (e.xc) holds the shot in use (cur), the eye and target as drawn, and the shot sets.
    local function exCamera(e, T, dt, t)
        if not e.cam or e.camOff then return end
        local c = e.xc
        if not c then
            c = { idx = 0, bad = 0, drift = 0 }
            c.F = XC.focusOf(e)
            c.list = XC.build(e, false)
            e.xc = c
        end
        local raise = T >= e.chop - 1.6 and T < e.chop + 0.5         -- the raise, the chop, its beat: side-on only
        local aftermath = e.chopped and T >= e.chop + XC.AFTER
        local cut = false
        -- the aftermath set: framed and scored from just after the chop, so it is ready when it takes over
        if e.chopped and not c.alist and T >= e.chop + 0.15 then
            c.aft = XC.aftFrame(e)
            c.alist = XC.build(e, true)
        end
        local pts = XC.points(e)
        if c.alist then
            c.ast = c.ast or { idx = 0 }
            c.ast.stale = c.stale
            XC.refresh(e, c.ast, c.alist, c.aft.c, XC.aftPoints(e), c.aft.dist, t)
            c.ast.stale = nil
        end
        if not aftermath then XC.refresh(e, c, c.list, c.F, pts, nil, t) end
        c.stale = nil
        if not aftermath then
            -- before the chop's beat: pick, check where the eye really is, move in or cut when it is blocked
            if not c.cur or (T < 0.5 and not c.locked) then
                local b = XC.best(c.list, false, c.cur and c.cur.side)
                if b and b ~= c.cur then c.cur, c.drift, cut = b, 0, true end
            end
            if T >= 0.5 then c.locked = true end
            if c.cur then
                if raise and abs(c.cur.off) > XC.SIDE and not c.squared then
                    -- into the raise: a cut to a square shot (the same side when it is clear)
                    c.squared = true
                    local b = XC.best(c.list, true, c.cur.side)
                    if b then c.cur, c.drift, cut = b, 0, true end
                end
                local s = c.cur
                local w, good = XC.eval(e, s.th + c.drift, s.el, s.r, c.F, pts)
                if w ~= nil then c.bad = good and 0 or c.bad + 1 end
                if c.bad >= 2 then
                    c.bad = 0
                    -- nearer along the same line first (a glide), else the best other shot (a cut)
                    local nb
                    for _, q in ipairs(c.list) do
                        if q.good and q.th == s.th and q.el == s.el and q.r < s.r and (not nb or q.r > nb.r) then nb = q end
                    end
                    if nb then
                        c.cur = nb
                    else
                        local b = XC.best(c.list, raise, s.side, s) or XC.best(c.list, false, s.side, s)
                        if b then c.cur, c.drift, cut = b, 0, true end
                    end
                end
                -- the orbit: a slow drift toward square, still from the raise through the chop's beat
                if not raise then
                    local o = c.cur.off
                    if o == 0 then c.drift = 0.07 * sin(T * 0.5)
                    else c.drift = clamp(c.drift - (o > 0 and 1 or -1) * 0.035 * dt, -abs(o) * 0.5, abs(o) * 0.5) end
                end
            end
        else
            -- the aftermath: the best wide shot, glided to when it is on the same side and the way there is clear
            if not c.acur then
                local b = XC.best(c.alist, false, c.cur and c.cur.side)
                if b then
                    c.acur = b
                    local F, ce, r = c.aft.c, cos(b.el), c.aft.dist
                    local np = { F[1] + sin(b.th) * ce * r, F[2] + sin(b.el) * r, F[3] + cos(b.th) * ce * r }
                    local hit = c.pos and castRay(c.pos[1], c.pos[2], c.pos[3], np[1], np[2], np[3])
                    if c.cur and b.side == c.cur.side and not hit then c.glide = { from = c.pos, at = t } else cut = true end
                end
                c.bad = 0
            else
                local s = c.acur
                local w, good = XC.eval(e, s.th, s.el, c.aft.dist, c.aft.c, XC.aftPoints(e))
                if w ~= nil then c.bad = good and 0 or c.bad + 1 end
                if c.bad >= 2 then
                    c.bad = 0
                    local b = XC.best(c.alist, false, s.side, s)
                    if b then c.acur, c.glide, cut = b, nil, true end
                end
            end
        end
        -- where the eye and the target want to be
        local pos, tgt, fov
        if aftermath and c.acur then
            local s = c.acur
            local ce = cos(s.el)
            local F = c.aft.c
            pos = { F[1] + sin(s.th) * ce * c.aft.dist, F[2] + sin(s.el) * c.aft.dist, F[3] + cos(s.th) * ce * c.aft.dist }
            tgt, fov = { F[1], F[2], F[3] }, c.aft.fov
        else
            local s = c.cur or { th = e.orbit.th, el = 0.6, r = XC.RS[1] }
            local ce, th = cos(s.el), s.th + (c.cur and c.drift or 0)
            local F = c.F
            pos = { F[1] + sin(th) * ce * s.r, F[2] + sin(s.el) * s.r, F[3] + cos(th) * ce * s.r }
            if not c.cur then
                -- nothing scored yet (no rays): the land between the pair and the eye pulls it in
                local hit = castRay(F[1], F[2], F[3], pos[1], pos[2], pos[3])
                if hit then
                    local k = max(GS.CAM_FLOOR / s.r, hit * 0.85)
                    pos = { lerp(F[1], pos[1], k), lerp(F[2], pos[2], k), lerp(F[3], pos[3], k) }
                end
            end
            tgt, fov = { F[1], F[2], F[3] }, 48
            -- in on the neck for the blade, the raise and the chop
            local k = smooth(seg(T, 2.2, 3.0)) * 0.35
            if e.neck and k > 0 then tgt = { lerp(F[1], e.neck[1], k), lerp(F[2], e.neck[2], k), lerp(F[3], e.neck[3], k) } end
            fov = lerp(48, 42, smooth(seg(T, 2.2, 4.4)))
            if e.chopped then
                -- the rolling head: the target leans after it (the stump and the attacker stay in the frame)
                local h = e.headRef
                local want = 0
                if h and headFollowable(e, h, c.F[1], c.F[3]) then
                    want = XC.LEAN * smooth(seg(T, e.chop + 0.15, e.chop + 0.6))
                end
                c.headK = (c.headK or 0) + (want - (c.headK or 0)) * (1 - exp(-dt * 4))
                if h and c.headK > 0.002 then
                    tgt = { lerp(tgt[1], h.x, c.headK), lerp(tgt[2], max(h.y, c.F[2] - 6), c.headK), lerp(tgt[3], h.z, c.headK) }
                end
                fov = lerp(42, 50, smooth(seg(T, e.chop, e.chop + 0.8)))
            end
        end
        -- drawn: a cut jumps, a glide eases over 1.2 s, otherwise both follow smoothly
        if cut or not c.pos then
            c.pos, c.tgt, c.fov, c.glide = pos, tgt, fov, nil
        elseif c.glide then
            local u = smooth((t - c.glide.at) / 1.2)
            local f = c.glide.from
            c.pos = { lerp(f[1], pos[1], u), lerp(f[2], pos[2], u), lerp(f[3], pos[3], u) }
            if u >= 1 then c.glide = nil end
        else
            local k = 1 - exp(-dt * 5)
            c.pos = { lerp(c.pos[1], pos[1], k), lerp(c.pos[2], pos[2], k), lerp(c.pos[3], pos[3], k) }
        end
        if not cut and c.tgt then
            local k = 1 - exp(-dt * 4)
            c.tgt = { lerp(c.tgt[1], tgt[1], k), lerp(c.tgt[2], tgt[2], k), lerp(c.tgt[3], tgt[3], k) }
            c.fov = lerp(c.fov, fov, k)
        end
        local spec = { pos = { c.pos[1], c.pos[2], c.pos[3] }, target = { c.tgt[1], c.tgt[2], c.tgt[3] }, fov = c.fov, frames = 4 }
        SpadeFX.shakeCam(spec)
        -- in from the game's camera over the first half second, and back to it at the end
        local blend = smooth(T / 0.5)
        if e.ending then blend = 1 - smooth((t - e.ending) / 0.8) end
        if blend < 1 and wum.render.gameCamera then
            local okG, g = pcall(wum.render.gameCamera)
            if okG and type(g) == "table" then
                local px, py, pz = vec(g.pos)
                local fx, fy, fz = vec(g.fwd)
                if px and fx then
                    local tx, ty, tz = px + fx * 100, py + fy * 100, pz + fz * 100
                    spec.pos = { lerp(px, spec.pos[1], blend), lerp(py, spec.pos[2], blend), lerp(pz, spec.pos[3], blend) }
                    spec.target = { lerp(tx, spec.target[1], blend), lerp(ty, spec.target[2], blend), lerp(tz, spec.target[3], blend) }
                    if g.fov then spec.fov = lerp(g.fov, spec.fov, blend) end
                end
            end
        end
        -- last: out of the worms and the severed head, then once more out of the land
        local px, py, pz = outOfWorms(e, spec.pos[1], spec.pos[2], spec.pos[3], spec.target[1], spec.target[3])
        if px ~= spec.pos[1] or pz ~= spec.pos[3] then
            local tx, ty, tz = spec.target[1], spec.target[2], spec.target[3]
            local hit2 = castRay(tx, ty, tz, px, py, pz)
            if hit2 then px, py, pz = lerp(tx, px, hit2 * 0.85), lerp(ty, py, hit2 * 0.85), lerp(tz, pz, hit2 * 0.85) end
            spec.pos = { px, py, pz }
        end
        local ok, res = pcall(wum.render.cameraOverride, spec)
        if not ok or res ~= true then e.camOff = true end
        e.camSet = true
        e.camPos = spec.pos
        e.camShot = (aftermath and c.acur and "after") or (c.cur and string.format("%d/%.1f/%.2f/%d", c.cur.side, c.cur.off, c.cur.el, c.cur.r)) or "none"
    end

    -- The execution without poses: both worms stay upright where they are pinned. The spade turns in the attacker's fists:
    -- pointed at the victim, raised over the shoulder, held for the beat, then swung through the neck with a short lunge
    -- and followed through into the ground. Returns the neck, the chest and where the attacker stands (for the beats).
    exUpright = function(e, T, dt)
        local fa = e.aFrame[3]
        local hx, hy, hz = fists({ e.ax, e.ay, e.az }, fa)
        local nx, ny, nz = e.vx, e.vy + GS.NECK_Y, e.vz
        local chx, chy, chz = e.vx - e.dx * 3, e.vy + CENTRE_Y + 2, e.vz - e.dz * 3
        local d = { e.dx, 0, e.dz }
        local side = { -e.dz, 0, e.dx }
        local function aim(fw, upw, sw)
            local x, y, z = norm3(d[1] * fw + side[1] * sw, upw, d[3] * fw + side[3] * sw)
            setP(hx, hy, hz, hx + x * 20, hy + y * 20, hz + z * 20)
            pinToFists(hx, hy, hz)
        end
        local tx, ty, tz = norm3(nx - hx, ny - hy, nz - hz)        -- from the fists to the neck
        local raised = { -0.55, 1, 0.25 }
        if T < 1.3 then
            aim(1, ty - 0.15, 0)
        elseif T < 2.8 then
            local u = ease(seg(T, 1.3, 2.4))
            aim(lerp(1, raised[1], u), lerp(ty - 0.15, raised[2], u), lerp(0, raised[3], u))
        elseif T < e.chop - 0.3 then
            -- the beat: held high, trembling, drawn a little further back
            local u = smooth(seg(T, 2.8, e.chop - 0.3))
            local tr = sin(T * 37) * 0.03
            aim(raised[1] - 0.2 * u + tr, raised[2], raised[3] + tr)
        elseif T < e.chop then
            -- the swing: from over the shoulder through the neck, the fists lunging so the edge meets it
            local u = smooth(seg(T, e.chop - 0.3, e.chop))
            local fw, upw, sw = lerp(raised[1] - 0.2, 1, u), lerp(raised[2], ty, u), lerp(raised[3], -0.1, u)
            aim(fw, upw, sw)
            local x, y, z = norm3(d[1] * fw + side[1] * sw, upw, d[3] * fw + side[3] * sw)
            local gx, gy, gz, px, py, pz = P.gx, P.gy, P.gz, P.tx, P.ty, P.tz
            tipAt(nx + x * 3, ny + y * 3, nz + z * 3, x, y, z)
            local k = u * u
            setP(lerp(gx, P.gx, k), lerp(gy, P.gy, k), lerp(gz, P.gz, k), lerp(px, P.tx, k), lerp(py, P.ty, k), lerp(pz, P.tz, k))
        else
            -- follow-through, then the blade rests in the ground before the attacker
            local u = smooth(seg(T, e.chop, e.chop + 0.5))
            aim(lerp(1, 0.45, u), lerp(ty, -1, u), lerp(-0.1, -0.35, u))
        end
        return nx, ny, nz, chx, chy, chz, e.ax + e.dx * 4, e.az + e.dz * 4
    end

    -- Poses, spade and effects of the execution for one frame.
    local function exFrame(e, dt, t)
        local T = exTime(e)
        local sa, sv = W[e.a], W[e.v]
        local up = { 0, 1, 0 }
        -- how far everything is from its rest pose: 1 through the show, back to 0 over the last half second
        local out = 1
        if e.ending then out = 1 - smooth((t - e.ending) / 0.5) end
        if T >= e.fin + 0.2 and not e.ending then GS.exEnd(false) end
        local vNeckX, vNeckY, vNeckZ, chx, chy, chz, mountX, mountZ
        if not e.posed then
            vNeckX, vNeckY, vNeckZ, chx, chy, chz, mountX, mountZ = exUpright(e, T, dt)
            e.st.fx, e.st.fz = e.dx, e.dz
            local k = GS.FOLLOW
            if T >= e.chop - 0.3 and T < e.chop + 0.3 then GS.FOLLOW = 60 end    -- the swing has no smoothing lag
            follow(e.st, dt)
            GS.FOLLOW = k
            if T >= e.chop - 0.3 and not e.swung then
                e.swung = true
                play("swing", 0.9, e.ax, e.ay + CENTRE_Y, e.az)
            end
        else
            vNeckX, vNeckY, vNeckZ, chx, chy, chz, mountX, mountZ = MT.frame(e, T, dt, t, out)
        end
        -- the beats
        if T >= 1.15 and not e.fell and e.posed then
            -- it hits the ground on its back: a thud and dust at its back and down its body
            e.fell = true
            play("impact_bat", 0.6, e.vx, e.vy, e.vz)
            SpadeFX.settle(e.vx, e.vy, e.vz, 18, GS.material)
            SpadeFX.settle(e.vx + e.dx * 14, e.vy, e.vz + e.dz * 14, 14, GS.material)
            SpadeFX.shake(1.2, 0.25)
        end
        if T >= (e.posed and 2.0 or 2.55) and not e.mounted then
            e.mounted = true
            SpadeFX.settle(mountX, e.vy, mountZ, 12, GS.material)
            if e.posed then
                play("impact_bat", 0.45, mountX, e.vy + 6, mountZ)
                SpadeFX.shake(0.8, 0.2)
            end
        end
        if T >= 3.0 and not e.set and e.posed then
            e.set = true
            play("spade_ring", 0.45, chx, chy, chz)
        end
        -- the chop waits for the sim's kill ("c"): an execution the sim aborted (the victim died first, the kill was
        -- refused) never takes a head
        if T >= e.chop and not e.chopped and not e.ending and (e.killed or e.preview) then
            e.chopped = true
            play("chop", 1.0, vNeckX, vNeckY, vNeckZ)
            SpadeFX.shake(4.5, 0.6)
            local h = launchHead(e, vNeckX, vNeckY, vNeckZ)
            e.headRef = h
            local blood = e.gore ~= "dust"
            SpadeFX.headOff(vNeckX, vNeckY, vNeckZ, e.dx, e.dz, { blood = blood, scale = blood and 1.4 or 1.1 })
            if blood then
                play("neck_spurt", 0.9, vNeckX, vNeckY, vNeckZ)
                if S.preset and S.melee then startFlash(vNeckX, vNeckY, vNeckZ, 100, e.v) end
            end
            if not e.preview then
                local ex = { phase = "chop", slot = e.v, attacker = e.a, x = vNeckX, y = vNeckY, z = vNeckZ,
                             dx = e.dx, dy = 0.35, dz = e.dz, hx = h.vx, hy = h.vy, hz = h.vz }
                -- upright, the body is gone a moment after the chop (the sim's short throes): the stump pumps from the ground
                if not e.posed then ex.sx, ex.sy, ex.sz = e.vx, e.vy + 4, e.vz end
                emitExec(ex)
            end
            e.banner = t
        end
        if e.gore == "own" and e.chopped and not e.aborted and T < e.chop + 6 and S.preset then
            -- an older Bloodsand cannot take the beats: a pulse of mist and drops from the stump, twice a second
            if not e.pulseAt or t - e.pulseAt > 0.55 then
                e.pulseAt = t
                local k = exp(-(T - e.chop) * 0.35)
                for _ = 1, floor(6 * k + 0.5) do
                    spawn(K_DROP, TEX.drop, false, vNeckX, vNeckY, vNeckZ, e.dx * rnd(20, 60) + rnd(-15, 15), rnd(60, 130) * k,
                          e.dz * rnd(20, 60) + rnd(-15, 15), rnd(1.0, 1.8), 0.8, rnd(0.6, 1.0), 0.55, 0.02, 0.03, 0.95, 0, -320)
                end
            end
        end
        exCamera(e, T, dt, t)
        e.Tnow = T
        if e.ending and t - e.ending > 0.85 then
            if e.camSet then pcall(wum.render.cameraOverride, nil) end
            clearPose(e.a)
            clearPose(e.v)
            if e.chopped and not e.aborted and not e.preview then emitExec({ phase = "end", slot = e.v }) end
            -- a body still drawn (its throes outlast the show) keeps its stump and stays down until it is gone
            if e.chopped and not e.aborted and e.vFinal then GS.linger = { slot = e.v, spec = e.vFinal, untilT = t + 6, seen = t } end
            GS.ex = nil
        end
    end

    -- The letterbox, the HUD hidden (Melange's hideHud where there is one) and the name card after the chop.
    local function exHud()
        local e = GS.ex
        if not e then return end
        local w, h = 1280, 720
        if wum.render.windowSize then
            local ok, a, b = pcall(wum.render.windowSize)
            if ok and a then w, h = a, b end
        end
        local t = os.clock()
        local k = 0
        if e.cam and not e.camOff then
            -- the cut-scene frame: the engine's HUD out of the picture (Melange 0.16 hideHud) and a letterbox
            if wum.render.hideHud then pcall(wum.render.hideHud, 4) end
            k = smooth((t - e.at) / 0.4)
        end
        if e.ending then k = k * (1 - smooth((t - e.ending) / 0.6)) end
        local bar = floor(h * 0.11 * k + 0.5)
        if bar > 0 then
            pcall(wum.draw.hudRect, 0, 0, w, bar, 0x000000ff, true)
            pcall(wum.draw.hudRect, 0, h - bar, w, h, 0x000000ff, true)
        end
        if e.banner then
            local age = t - e.banner
            local a = smooth(age / 0.25) * (1 - smooth((age - 2.6) / 0.6))
            if a > 0.01 then
                local al = floor(a * 255 + 0.5)
                local y = h - bar + floor(bar * 0.18)
                pcall(wum.draw.hudText, w * 0.5, y, "GRAVE SPADE", 0xd8c8a800 | al, 30,
                      { align = "center", shadow = 0x000000ff })
                pcall(wum.draw.hudText, w * 0.5, y + 34, e.an .. " takes " .. e.vn .. "'s head", 0xb0a08800 | al, 18,
                      { align = "center", shadow = 0x000000ff })
            end
        end
    end

    -- ------------------------------------------------------------ the frame
    function GS.frame(dt)
        if not wum.render then return end
        local t = os.clock()
        -- the execution camera's shots are picked by land rays: more of them while it runs
        RAY.base = RAY.base or RAY.cap
        RAY.cap = GS.ex and (GS.ex.xc and XC.RAYS or 120) or RAY.base     -- the first frame scores the whole shot set
        ensureAssets()
        local e = GS.ex
        local busy = {}
        if e then
            busy[e.a], busy[e.v] = true, true
            local ok, err = pcall(exFrame, e, dt, t)
            if not ok then
                logErr("spade execution", err)
                pcall(wum.render.cameraOverride, nil)
                GS.ex = nil
            end
        end
        -- every other worm with the spade in hand (only the active one wields a weapon)
        for slot, s in pairs(W) do
            local st = GS.w[slot]
            if not busy[slot] and slot == ACT.slot and s.seen == FR.n and s.alive and s.weapon == GS.WEAPON then
                if not st then
                    st = {}
                    GS.w[slot] = st
                end
                local speed = s.evx and sqrt(s.evx * s.evx + s.evz * s.evz + s.evy * s.evy) or 0
                if speed < 120 then
                    wield(slot, s, st, dt, t)
                    st.show = true
                else
                    st.show, st.gx = false, nil          -- thrown or falling: put away
                end
            elseif st and not busy[slot] then
                if st.posed then clearPose(slot) end
                GS.w[slot] = nil
            end
        end
        local lg = GS.linger
        if lg and not busy[lg.slot] then
            if bones(lg.slot) then lg.seen = t end
            if t > lg.untilT or t - lg.seen > 0.5 then
                clearPose(lg.slot)
                GS.linger = nil
            else
                lg.spec.tail = nil
                setPose(lg.slot, lg.spec)
            end
        end
        for i = #GS.heads, 1, -1 do
            local h = GS.heads[i]
            stepHead(h, dt, t)
            if h.dead then table.remove(GS.heads, i) end
        end
    end

    function GS.drawWorld()
        local t = os.clock()
        for slot, st in pairs(GS.w) do
            if st.show or (GS.ex and GS.ex.a == slot and st.gx) then drawSpade(st, 1) end
        end
        for i = 1, #GS.heads do drawHead(GS.heads[i], t) end
    end
    GS.drawHud = exHud

    function GS.onMessage(p)
        local text = type(p) == "table" and p.value or p
        if type(text) ~= "string" then return end
        local kind = string.sub(text, 1, 1)
        local v, n = {}, 0
        for num in string.gmatch(string.sub(text, 3), "[^,]+") do
            n = n + 1
            v[n] = tonumber(num)
        end
        if kind == "d" and n >= 9 then
            GS.onDig(v[1], v[3], v[4], v[5], v[6], v[7], v[8], v[9])
        elseif kind == "r" and n >= 1 then
            GS.onRelease(v[1])
        elseif kind == "w" and n >= 1 then
            GS.onSwing(v[1])
        elseif kind == "h" and n >= 2 then
            GS.onHit(v[1], v[2])
        elseif kind == "x" and n >= 12 then
            if GS.ex then GS.exEnd(true) GS.ex = nil end
            GS.exStart(v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8], v[9], v[10], v[11], v[12], false)
        elseif kind == "c" and n >= 2 then
            if GS.ex and GS.ex.v == v[2] then GS.ex.killed = true end
        elseif kind == "a" then
            if GS.ex and GS.ex.chopped then GS.ex.aborted = true end
            GS.exEnd(true)
        elseif kind == "e" then
            GS.exEnd(false)
        end
    end

    function GS.matchStart()
        -- the poses are looked at again in every match: a refusal in the last one (the attract demo torn down) says
        -- nothing about this one
        GS.pose.bad, GS.pose.checked, GS.pose.status, GS.pose.since = false, false, nil, nil
        GS.pose.fails, GS.pose.failSince = 0, nil
        GS.blasts = {}
        local ok, th = pcall(wum.game.theme)
        GS.material = (ok and THEME[tostring(th)]) or "soil"
        GS.aimSign = 1
    end

    function GS.reset()
        if GS.ex then
            if GS.ex.camSet then pcall(wum.render.cameraOverride, nil) end
            GS.ex = nil
        end
        for slot in pairs(GS.w) do clearPose(slot) end
        if GS.linger then clearPose(GS.linger.slot) end
        GS.w, GS.heads, GS.linger = {}, {}, nil
        GS.pose.swap = {}
        GS.pose.caps, GS.pose.noClips = nil, nil
        SpadeFX.clear()
    end

    function GS.settings()
        local pre = S.preset
        SpadeFX.setQuality(pre and pre.strength or 0)
    end

    -- Menu: the execution on the active worm and the nearest other (no kill, no sim: it only plays here), and a dig. The
    -- event mod.kindjal.preview {what = "spade", attacker =, victim =} picks the pair (tests).
    function GS.preview(what, pa, pv)
        local v, a = previewTarget()
        if pa and pv and pa ~= pv and W[pa] and W[pv] then a, v = pa, pv end
        if not v or not a or v == a then return end
        if what == "dig" then
            local s = W[a]
            if not s then return end
            local dx, dy, dz = dirOf(s)
            local c = { s.px, s.py + CENTRE_Y, s.pz }
            GS.onDig(a, c[1] + dx * 8, c[2] + dy * 8, c[3] + dz * 8, c[1] + dx * 36, c[2] + dy * 36, c[3] + dz * 36, 4)
            return
        end
        local sa, sv = W[a], W[v]
        if GS.ex then return end
        GS.exStart(a, v, nil, 270, 150, 520, sa.px, sa.py, sa.pz, sv.px, sv.py, sv.pz, true)
    end

    return GS
end)()

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
        FXA.cache.seed, FXA.cache.strength, FXA.cache.compat = nil, nil, nil
        for k = 0, 3 do FXA.cache[COMPAT.TN[k]] = nil end
        FXA.cache.sunskin = nil
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
    HF.on, HF.last = false, 0
end

local live = false

local function resetAll()
    clearVisuals()
    for slot in pairs(W) do W[slot] = nil end
    MEL.pending, MEL.firedSlot, MEL.firedWid, MEL.firedAt, MEL.heldSlot = false, nil, nil, -100, nil
    EXPL.n = 0
    buddyStop()
    SPADE.reset()
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
    local dt = clamp(t - lastT, 0, MAX_DT)
    lastT, now, curDt = t, t, dt
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
    buddyUpdate(t)
    SPADE.frame(dt)
    -- coatUpdate also runs with the visuals off: it sends the zeros of coats that were just cleared.
    if S.preset then readCamera() end
    coatUpdate(dt)
    if S.preset then
        puddleUpdate(dt)
        stepParticles(dt)
    end
    hitUpdate()
    resendStep()
    SPADE.drawWorld()
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
    COMPAT.poll()
    SpadeFX.setQuality(pre and pre.strength or 0)
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
subscribe("Kindjal.Spade", SPADE.onMessage)
subscribe("mod.bloodsand.state", SPADE.hearBloodsand)
subscribe("melange.match.start", SPADE.matchStart)
subscribe("Explosion", onExplosion)
subscribe("Explosion", SPADE.noteBlast)
subscribe("Weapon.Fired", onFired)
subscribe("Worm.Damaged", onDamaged)
subscribe("Payload.BigJump", function()
    if BUDDY.live and os.clock() - BUDDY.lastBark > 0.6 and os.clock() - BUDDY.t0 < BUDDY.FUSE - BUDDY.QUIET then buddyBark() end
end)
function BUDDY.inWater()
    if not BUDDY.live then return end
    buddyStop()
    stopVoice(BUDDY.voice)                              -- a bark that started just before the splash
    BUDDY.voice = nil
end
subscribe("Payload.CollideWithWater", BUDDY.inWater)
subscribe("Payload.CollideWithDisarmPlane", BUDDY.inWater)
subscribe("Payload.Sunk", BUDDY.inWater)
subscribe("GameLogic.Turn.Started", buddyStop)
subscribe("GameLogic.Turn.Ended", buddyStop)
subscribe("melange.match.start", resetAll)
subscribe("melange.match.end", resetAll)
-- A mod switched on or off, or a match starting: look at the other plugins again (at the next half second).
-- (And back to the colour test for the skin until Sunstone, if still there, says again: see COMPAT.hearSkin.)
subscribe("melange.mods.changed", function()
    COMPAT.nextAt = 0
    COMPAT.hearSkin(nil)
end)
subscribe("melange.match.start", function() COMPAT.nextAt = 0 end)
subscribe("mod.sunstone.skin", COMPAT.hearSkin)
subscribe("mod.kindjal.preview", function(p)
    local what = type(p) == "table" and p.what
    if what == "acid" then previewAcid(p.target) elseif what == "melee" then previewMelee() elseif what == "age" then previewAge()
    elseif what == "spade" then SPADE.preview("execution", tonumber(p.attacker), tonumber(p.victim)) elseif what == "dig" then SPADE.preview("dig") end
end)

wum.draw.on("world", onWorld)
wum.draw.on("hud", function()
    local ok, err = pcall(SPADE.drawHud)
    if not ok then logErr("spade hud", err) end
end)
if wum.ui and wum.ui.menu then
    pcall(wum.ui.menu, "Preview acid", previewAcid)
    pcall(wum.ui.menu, "Preview melee", previewMelee)
    pcall(wum.ui.menu, "Acid +10 s", previewAge)
    pcall(wum.ui.menu, "Preview Grave Spade execution", function() SPADE.preview("execution") end)
    pcall(wum.ui.menu, "Preview Grave Spade scoop", function() SPADE.preview("dig") end)
end
wum.timers.every(0.5, applySettings)
wum.timers.every(2, function() if RS.step == 0 then RS.step = 1 end end)
