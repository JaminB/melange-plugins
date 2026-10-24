-- Sandtide petrify driver: feeds the sandtide/petrify post-FX (mod/postfx/petrify) from the client.
--
-- Melange's client VM has no require or dofile, so this file is ONE statement, `local Petrify = (function() ... end)()`,
-- meant to be pasted (or concatenated by a build step) into client/init.lua above the code that uses it. It defines no
-- other top-level local (init.lua's main chunk may hold at most 200) and subscribes to nothing unless Petrify.install is
-- called.
--
-- API (slot is the worm slot 0..15, as wum.game.worms() and wum.sim.worm() number them):
--   Petrify.setWorm(slot, level[, seed[, dissolve]])
--       level    0..1, how far the cast has crept from the tail up to the waist (0 clears the slot). The caller animates it
--                (the creep over the tour) and holds it at 1 for the rest of the match.
--       seed     any number; picks the worm's own grain, cracks, quartz and the shape of its front. Default: the slot.
--                Use the same seed on every frame (the match's curse order or the slot is fine).
--       dissolve 0..1, how much of the cast has washed away under water (0 whole, 1 gone). Default 0.
--       Values are clamped, and sent in steps of 1/256. The worm's position is read from wum.game.worms() by frame().
--   Petrify.frame()       call once per frame (wum.timers.every(0, ...) or a draw callback). Reads the worms, smooths their
--                         positions, sends what changed, and switches the pass on only while a cast worm is alive and near the
--                         screen. Also warms the shader up (a few frames on, nothing to draw) at the first frame of a match, so
--                         its compile does not hitch at the strike.
--   Petrify.setStrength(s) 0..1 overall opacity (the FX intensity setting). Default 1. 0 switches the pass off.
--   Petrify.hearSkin(p)   handler for the event mod.sunstone.skin (Sunstone's Worm skin tones and marks).
--   Petrify.reset()       clears every slot and switches the pass off (match start and end, mod reload).
--   Petrify.install(on)   optional: subscribes reset to melange.match.start/end, hearSkin to mod.sunstone.skin and a re-probe to
--                         melange.mods.changed. `on` is the subscribe function to use (default wum.events.on).
--   Petrify.get(slot)     -> level, seed, dissolve (debugging); Petrify.ID = "sandtide/petrify".
--
-- Composition: the pass is PostWorld order 55, after Bloodsand (51 to 53) and Kindjal's acid (54), before Sunstone (100, 300).
-- Sunstone is found through wum.postfx.list every 5 s (any enabled sunstone/ effect), and compat eases to it over 0.3 s, as
-- in Kindjal. Every value goes through wum.postfx.setTransient (not saved, not logged), and only when it changed.
local Petrify = (function()
    local M = { ID = "sandtide/petrify" }
    local SLOTS, CENTRE_Y = 16, 12
    local abs, exp, floor, min, max = math.abs, math.exp, math.floor, math.min, math.max
    local hasFx = wum.postfx and wum.postfx.setTransient and wum.postfx.enable and true or false

    -- Per slot: lv, sd, dz (wanted), x, y, z (smoothed feet), alive, seen (frame number).
    local W = {}
    local F = { n = 0, cache = {}, enabled = nil, strength = 1, last = nil, warm = 0, warmed = false, inMatch = false,
                visAt = -100, visLast = -100 }
    local C = { sunstone = false, k = 0, primed = false, nextAt = 0, tone = {}, sunskin = 0 }
    local WN, LN, SN, DN, TN = {}, {}, {}, {}, {}
    for i = 0, SLOTS - 1 do WN[i] = "worm" .. i end
    for k = 0, 3 do LN[k], SN[k], DN[k], TN[k] = "level" .. k, "seed" .. k, "dissolve" .. k, "tone" .. k end

    local function q(v) return floor(v * 256 + 0.5) / 256 end
    local function clamp01(v)
        v = tonumber(v) or 0
        if v ~= v then return 0 end
        return v < 0 and 0 or (v > 1 and 1 or v)
    end

    -- Sends a value when it differs from the last one the effect took (Melange returns false for an unknown effect, and
    -- the cache only changes once a send succeeded, so a failed one is tried again).
    local function send(name, a, b, c, d)
        if not hasFx then return false end
        local old = F.cache[name]
        if old and old[1] == a and old[2] == b and old[3] == c and old[4] == d then return false end
        local ok, res
        if d ~= nil then ok, res = pcall(wum.postfx.setTransient, M.ID, name, a, b, c, d)
        elseif c ~= nil then ok, res = pcall(wum.postfx.setTransient, M.ID, name, a, b, c)
        else ok, res = pcall(wum.postfx.setTransient, M.ID, name, a) end
        if not ok or res == false then return false end
        F.cache[name] = { a, b, c, d }
        return true
    end

    local function enable(on)
        if F.warm > 0 then on = true end
        if not hasFx or F.enabled == on then return end
        local ok, res = pcall(wum.postfx.enable, M.ID, on)
        if ok and res ~= false then F.enabled = on end
    end

    function M.setWorm(slot, level, seed, dissolve)
        slot = tonumber(slot)
        if not slot or slot ~= floor(slot) or slot < 0 or slot >= SLOTS then return false end
        local lv = q(clamp01(level))
        if lv <= 0 then
            W[slot] = nil
            return true
        end
        local s = W[slot]
        if not s then
            s = {}
            W[slot] = s
        end
        local sd = tonumber(seed) or slot
        if sd ~= sd or abs(sd) > 1e6 then sd = slot end
        s.lv, s.sd, s.dz = lv, floor(sd * 64 + 0.5) / 64 % 1024, q(clamp01(dissolve))
        return true
    end

    function M.get(slot)
        local s = W[tonumber(slot) or -1]
        if not s then return 0, nil, 0 end
        return s.lv, s.sd, s.dz
    end

    function M.setStrength(v) F.strength = q(clamp01(v)) end

    -- Sends every value again on the next frame (after the effect was reloaded, which resets its parameters).
    function M.resend() F.cache = {}; F.enabled = nil end

    function M.hearSkin(p)
        local t, mode = {}, 0
        if type(p) == "table" then
            if p.on == true and type(p.lum) == "table" then
                for i = 1, SLOTS do
                    local v = tonumber(p.lum[i])
                    t[i] = (v and v > 0.02 and v < 4) and q(v) or 1
                end
            end
            if p.marks == true then mode = (p.on == true or p.hair == true) and 2 or 1 end
        end
        C.tone, C.sunskin = t, mode
    end

    local function probe()
        C.nextAt = os.clock() + 5
        if not (wum.postfx and wum.postfx.list) then return end
        local ok, list = pcall(wum.postfx.list)
        if not ok or type(list) ~= "table" then return end
        local ss = false
        for i = 1, #list do
            local e = list[i]
            if type(e) == "table" and type(e.id) == "string" and e.failed ~= true and e.enabled == true
               and string.sub(e.id, 1, 9) == "sunstone/" then ss = true end
        end
        C.sunstone = ss
        if not C.primed then
            C.primed, C.k = true, ss and 1 or 0
        end
    end

    function M.reprobe() C.nextAt = 0; M.hearSkin(nil) end

    function M.reset()
        for k in pairs(W) do W[k] = nil end
        F.cache = {}
        enable(false)
    end

    -- The smoothed feet position: the game reports a position per sim tick (50 per second), so it is eased toward the report
    -- (time constant 1/12 s) and a jump of more than 40 units (a teleport, a respawn) is followed at once.
    local function follow(s, x, y, z, dt)
        if not s.x then
            s.x, s.y, s.z = x, y, z
            return
        end
        local dx, dy, dz = x - s.x, y - s.y, z - s.z
        if dx * dx + dy * dy + dz * dz > 1600 then
            s.x, s.y, s.z = x, y, z
            return
        end
        local k = 1 - exp(-max(dt, 0) * 12)
        s.x, s.y, s.z = s.x + dx * k, s.y + dy * k, s.z + dz * k
    end

    local function inView()
        if not (wum.render and wum.render.worldToScreen and wum.render.windowSize) then return true end
        local now = os.clock()
        if now - F.visAt >= 0.25 then
            F.visAt = now
            local okw, w, h = pcall(wum.render.windowSize)
            if not okw or type(w) ~= "number" or type(h) ~= "number" or w <= 0 or h <= 0 then return true end
            local m = 0.5 * h
            for _, s in pairs(W) do
                if s.alive and s.x then
                    local ok, sx, sy = pcall(wum.render.worldToScreen, { x = s.x, y = s.y + CENTRE_Y, z = s.z })
                    if not ok or (type(sx) == "number" and type(sy) == "number" and sx > -m and sx < w + m and sy > -m and sy < h + m) then
                        F.visLast = now
                        break
                    end
                end
            end
        end
        return now - F.visLast < 2
    end

    function M.frame()
        local now = os.clock()
        local dt = F.last and min(now - F.last, 0.25) or 0
        F.last = now
        local okm, inMatch = pcall(wum.game.inMatch)
        inMatch = okm and inMatch == true
        if not inMatch then
            if F.inMatch then M.reset() end
            F.inMatch, F.warmed = false, false
            enable(false)
            return
        end
        F.inMatch = true
        if not F.warmed then
            F.warmed, F.warm = true, 6
        elseif F.warm > 0 then
            F.warm = F.warm - 1
        end
        if os.clock() >= C.nextAt then probe() end
        if C.primed then
            local target = C.sunstone and 1 or 0
            if C.k < target then C.k = min(target, C.k + dt / 0.3) elseif C.k > target then C.k = max(target, C.k - dt / 0.3) end
        end

        F.n = F.n + 1
        local any = false
        if next(W) then
            local ok, worms = pcall(wum.game.worms)
            if ok and type(worms) == "table" then
                for i = 1, #worms do
                    local w = worms[i]
                    local slot = type(w) == "table" and tonumber(w.slot)
                    local s = slot and W[slot]
                    local p = s and w.pos
                    if type(p) == "table" then
                        local x, y, z = tonumber(p.x or p[1]), tonumber(p.y or p[2]), tonumber(p.z or p[3])
                        if x and y and z then
                            follow(s, x, y, z, dt)
                            s.alive, s.seen = w.alive == true, F.n
                        end
                    end
                end
            end
            for _, s in pairs(W) do
                if s.seen ~= F.n then s.alive = false end
                if s.alive then any = true end
            end
        end

        -- Worm centres and the packed groups. A slot that is free or not alive gets level 0 (and its centre 0,0,0).
        for k = 0, 3 do
            local l, sd, dz = {}, {}, {}
            for i = 0, 3 do
                local slot = 4 * k + i
                local s = W[slot]
                if s and s.alive and s.x then
                    send(WN[slot], s.x, s.y + CENTRE_Y, s.z)
                    l[i + 1], sd[i + 1], dz[i + 1] = s.lv, s.sd, s.dz
                else
                    send(WN[slot], 0, 0, 0)
                    l[i + 1], sd[i + 1], dz[i + 1] = 0, 0, 0
                end
            end
            send(LN[k], l[1], l[2], l[3], l[4])
            send(SN[k], sd[1], sd[2], sd[3], sd[4])
            send(DN[k], dz[1], dz[2], dz[3], dz[4])
        end
        local t = C.tone
        for k = 0, 3 do send(TN[k], t[4 * k + 1] or 1, t[4 * k + 2] or 1, t[4 * k + 3] or 1, t[4 * k + 4] or 1) end
        send("sunskin", C.sunskin)
        send("compat", q(C.k))
        send("strength", F.strength)
        enable(any and F.strength > 0 and inView())
    end

    function M.install(on)
        on = on or (wum.events and wum.events.on)
        if type(on) ~= "function" then return false end
        pcall(on, "melange.match.start", function() M.reset(); C.nextAt = 0 end)
        pcall(on, "melange.match.end", function() M.reset() end)
        pcall(on, "mod.sunstone.skin", function(p) M.hearSkin(p) end)
        pcall(on, "melange.mods.changed", function() M.reprobe() end)
        return true
    end

    return M
end)()

-- =====================================================================================================================
-- Sandtide client (Lua 5.4). Everything below the petrify driver above:
--   1. utilities, settings, textures, audio
--   2. the sim's messages (Sandtide.Line, Sandtide.Curse) and the turn-start hold events
--   3. the hourglass HUD (bottom centre): sand, stream, cracks, glow, ticks, the shatter, the water drop
--   4. the sand line: a haze sheet at the line height, a glowing ribbon where it meets the land, drifting grains
--   5. the cursed worms: petrify level, mound mesh, dissolve under water, crumble on death
--   6. the director: the camera tour of the cursed worms inside the sim's hold, captions, letterbox, shake
-- The sim (mod/sim/main.lua) decides everything that matters; this file only shows it. Nothing here feeds back.
-- =====================================================================================================================

if not (wum and wum.draw and wum.draw.on and wum.game and wum.events and wum.timers) then return end

local U = {}          -- utilities
local CFG = { tour = true, fx = "dramatic", scale = 1, vol = 0.8, at = -1,
              fxk = { shake = 1, parts = 1, petrify = 1 } }
local TX = { cache = {}, fail = {} }
local AU = { h = {}, fail = {}, loops = {}, ok = nil }
local G = { inMatch = false, w = nil, byslot = {}, tick = 0, m = nil, now = 0, dt = 0, last = nil, frame = 0,
            sw = 1920, sh = 1080, cam = nil, gcam = nil }
local L = { have = false }   -- Sandtide.Line
local C = nil                -- Sandtide.Curse, the current match's
local HOLD = nil             -- melange.turnHold of this match
local HG = {}                -- hourglass state
local LN = {}                -- sand line state
local CU = { w = {} }        -- cursed worms by slot
local PT = {}                -- particles
local DIR = {}               -- director
local BAN = {}               -- banners

-------------------------------------------------------------------------------------------------------------- 1.
local abs, floor, ceil, min, max, sin, cos, sqrt, exp, pi =
    math.abs, math.floor, math.ceil, math.min, math.max, math.sin, math.cos, math.sqrt, math.exp, math.pi

function U.log(...) if wum.log and wum.log.info then pcall(wum.log.info, ...) end end
function U.warn(...) if wum.log and wum.log.warn then pcall(wum.log.warn, ...) end end
function U.clamp(v, a, b) if v < a then return a elseif v > b then return b end return v end
function U.sat(v) if v ~= v then return 0 end return v < 0 and 0 or (v > 1 and 1 or v) end
function U.lerp(a, b, t) return a + (b - a) * t end
function U.smooth(t) t = U.sat(t); return t * t * (3 - 2 * t) end
function U.smoother(t) t = U.sat(t); return t * t * t * (t * (t * 6 - 15) + 10) end
function U.outCubic(t) t = 1 - U.sat(t); return 1 - t * t * t end
function U.outBack(t)
    t = U.sat(t)
    local c1 = 1.9
    local u = t - 1
    return 1 + (c1 + 1) * u * u * u + c1 * u * u
end
function U.col(rgb, a) return rgb * 256 + floor(U.sat(a) * 255 + 0.5) end
function U.hash(n) local s = sin(n * 12.9898 + 78.233) * 43758.5453; return s - floor(s) end
function U.rand(a, b) return a + (b - a) * math.random() end
function U.vx(v) if type(v) ~= "table" then return nil end return tonumber(v.x or v[1]), tonumber(v.y or v[2]), tonumber(v.z or v[3]) end
function U.mmss(ms)
    local s = ceil(max(ms, 0) / 1000)
    s = math.tointeger(s) or floor(s)
    return string.format("%d:%02d", s // 60, s % 60)
end

-- One error counter per piece (the Kanly pattern): three errors and that piece stops for the session.
local FAULT = {}
function U.guard(name, fn)
    FAULT[name] = FAULT[name] or { n = 0, off = false }
    local f = FAULT[name]
    return function(...)
        if f.off then return end
        local ok, err = pcall(fn, ...)
        if not ok then
            f.n = f.n + 1
            U.warn("sandtide: " .. name .. " error " .. f.n .. ": " .. tostring(err))
            if f.n >= 3 then
                f.off = true
                U.warn("sandtide: " .. name .. " disabled after 3 errors")
                if name == "director" or name == "update" then pcall(DIR.abort, "fault") end
            end
        end
    end
end

function CFG.refresh()
    if G.now - CFG.at < 1 then return end
    CFG.at = G.now
    if not (wum.config and wum.config.get) then return end
    local function get(k, d)
        local ok, v = pcall(wum.config.get, k)
        if ok and v ~= nil then return v end
        return d
    end
    CFG.tour = get("cameraTour", true) ~= false
    CFG.fx = tostring(get("fx", "dramatic"))
    CFG.scale = U.clamp(tonumber(get("hourglassScale", 1)) or 1, 0.5, 2)
    CFG.vol = U.clamp(tonumber(get("sounds", 0.8)) or 0.8, 0, 1)
    local k = CFG.fxk
    if CFG.fx == "subtle" then k.shake, k.parts, k.petrify = 0.25, 0.4, 0.85
    elseif CFG.fx == "full" then k.shake, k.parts, k.petrify = 0.65, 0.75, 1
    else k.shake, k.parts, k.petrify = 1, 1, 1 end
    Petrify.setStrength(k.petrify)
end

function TX.get(name, opts)
    local t = TX.cache[name]
    if t then return t end
    if TX.fail[name] then return nil end
    local ok, id
    if opts then ok, id = pcall(wum.draw.texture, "textures/" .. name .. ".png", opts)
    else ok, id = pcall(wum.draw.texture, "textures/" .. name .. ".png") end
    if ok and id then
        TX.cache[name] = id
        return id
    end
    TX.fail[name] = true
    U.warn("sandtide: texture " .. name .. " did not load: " .. tostring(id))
    return nil
end

-- Audio. The library has no volume control on a playing voice, so beds are layers started and stopped whole.
function AU.ready()
    if AU.ok ~= nil then return AU.ok end
    AU.ok = false
    if wum.audio and wum.audio.ready and wum.audio.load and wum.audio.play then
        local ok, r = pcall(wum.audio.ready)
        AU.ok = ok and r == true
    end
    return AU.ok
end
function AU.handle(name)
    local h = AU.h[name]
    if h or AU.fail[name] then return h end
    local ok, got = pcall(wum.audio.load, "sounds/sdt_" .. name .. ".wav")
    if ok and got then AU.h[name] = got; return got end
    AU.fail[name] = true
    U.warn("sandtide: sound " .. name .. " did not load: " .. tostring(got))
    return nil
end
function AU.play(name, vol, pitch, pos, loop)
    if CFG.vol <= 0 or not AU.ready() then return nil end
    local h = AU.handle(name)
    if not h then return nil end
    local o = { volume = U.clamp((vol or 1) * CFG.vol, 0, 2), pitch = pitch or 1 }
    if pos then o.pos = pos end
    if loop then o.loop = true end
    local ok, v = pcall(wum.audio.play, h, o)
    if ok then return v end
    return nil
end
function AU.loop(key, name, vol, pitch)
    if AU.loops[key] then return end
    AU.loops[key] = AU.play(name, vol, pitch, nil, true) or false
end
function AU.stop(key)
    local v = AU.loops[key]
    if v and wum.audio.stop then pcall(wum.audio.stop, v) end
    AU.loops[key] = nil
end
function AU.stopAll()
    for k in pairs(AU.loops) do AU.stop(k) end
end

-------------------------------------------------------------------------------------------------------------- 2.
function U.split(s, sep)
    local out, i = {}, 1
    while true do
        local j = string.find(s, sep, i, true)
        if not j then out[#out + 1] = string.sub(s, i); return out end
        out[#out + 1] = string.sub(s, i, j - 1)
        i = j + 1
    end
end

local MSG = {}
function MSG.line(p)
    local f = U.split(tostring(p and p.value or ""), "|")
    local line, minY, maxY = tonumber(f[1]), tonumber(f[2]), tonumber(f[3])
    if not line then return end
    local first = not L.have
    L.have, L.line, L.minY, L.maxY = true, line, minY or line, maxY or line
    L.strikeMs, L.roundMs, L.phase = tonumber(f[4]) or 180000, tonumber(f[5]) or 300000, tonumber(f[6]) or 0
    if first then
        U.log(string.format("sandtide: sand line at %.2f (land %.2f..%.2f), strike at %.0f ms", line, L.minY, L.maxY,
            L.strikeMs))
        LN.reset()
    end
end

function MSG.curse(p)
    local f = U.split(tostring(p and p.value or ""), "|")
    local slots = {}
    if f[1] and f[1] ~= "" then
        for _, s in ipairs(U.split(f[1], ",")) do
            local n = math.tointeger(tonumber(s))
            if n and n >= 0 and n < 16 then slots[#slots + 1] = n end
        end
    end
    local t = U.split(f[4] or "", ",")
    local c = { slots = slots, holdTicks = tonumber(f[2]) or 0, tick = tonumber(f[3]) or -1,
                intro = tonumber(t[1]) or 60, per = tonumber(t[2]) or 175, outro = tonumber(t[3]) or 50,
                status = f[5] or "", at = G.now }
    if C and C.tick == c.tick then return end    -- the copy re-sent at every turn start
    C = c
    -- "Live" when the message arrives within a few seconds of the curse; a later copy (a reload, a late client) means
    -- the final state with no show.
    local live = G.tick > 0 and G.tick - c.tick < 150
    U.log(string.format("sandtide: curse at tick %.0f (now %.0f), %d worms, hold %.0f, %s, %s", c.tick, G.tick, #slots,
        c.holdTicks, c.status, live and "live" or "late"))
    CU.begin(c, live)
    HG.strike(live)
    DIR.curse(c, live)
end

function MSG.hold(p)
    if type(p) ~= "table" then return end
    HOLD = { ticks = tonumber(p.ticks) or 0, tick = tonumber(p.tick) or 0, at = G.now, gtick = G.tick }
    U.log(string.format("sandtide: turn hold %.0f ticks at tick %.0f (client tick %.0f)", HOLD.ticks, HOLD.tick, G.tick))
    DIR.hold(HOLD)
end

function MSG.holdEnd(p)
    U.log("sandtide: turn hold ended after " .. tostring(p and p.ticks))
    DIR.holdEnd()
end

-------------------------------------------------------------------------------------------------------------- 3.
-- The hourglass. The art is a 256 x 384 canvas (tools/hud_layout.json) drawn at 128 x 192 HUD px at 1080p and size 1.
local R = {
    full = { 0, 0, 256, 384 }, top = { 48, 48, 208, 196 }, stream = { 112, 176, 144, 340 }, bot = { 48, 188, 208, 336 },
    shatter = { -64, -64, 320, 448 }, spill = { 16, 280, 240, 340 }, drop = { 80, 128, 176, 256 },
    plate = { 16, 384, 240, 456 },
}
local HGN = { top = {}, bot = {}, stream = {}, crack = {}, shatter = {}, drop = {} }
for i = 0, 15 do HGN.top[i] = string.format("hud/hg_sand_top_%02d", i); HGN.bot[i] = string.format("hud/hg_sand_bot_%02d", i) end
for i = 0, 5 do HGN.stream[i] = "hud/hg_stream_" .. i end
for i = 1, 3 do HGN.crack[i] = "hud/hg_crack_" .. i end
for i = 0, 11 do HGN.shatter[i] = string.format("hud/hg_shatter_%02d", i) end
for i = 0, 8 do HGN.drop[i] = string.format("hud/hg_drop_%02d", i) end

local COLS = {
    bone = 0xF4E2BC, amber = 0xFFB050, ember = 0xFF6A2A, red = 0xFF3B2E, water = 0x8FD4FF, deep = 0x5AA8FF,
    sand = 0xE8C890, white = 0xFFFFFF, black = 0x000000, shadow = 0x1A0E06,
    team = { [0] = 0xFF5A4A, 0x5AA0FF, 0x6BE06B, 0xFFD94A },
}

function HG.reset()
    HG.state = "hidden"      -- hidden, run, empty, shatter, water, flood
    HG.crack, HG.lastSec, HG.shAt, HG.jolt, HG.flash = 0, nil, nil, 0, 0
    HG.strikeElapsed, HG.flooded, HG.pourOn, HG.windOn, HG.alpha, HG.tour = nil, false, false, false, 0, 0
    HG.lastLeft, HG.running, HG.runAt = nil, false, -10
    HG.ts, HG.tsAt, HG.intro, HG.overlay, HG.groupsAt = nil, -100, false, false, -1
    HG.turnRan, HG.tl = true, nil
end

-- What the game itself shows over the bottom centre, so the hourglass steps aside for it:
--   overlay: the weapon panel or the pause menu (the game's input groups are then "Menu" alone: measured in game, the
--            panel and the pause menu both leave only Menu; a human turn has Menu+InGame+..., the tour Spectator);
--   intro:   the turn intro ("Ready?" and its countdown), from a new turn start (turnsStarted changes) until the turn
--            clock first counts down. The clock's value during the intro is not a signal: before sudden death the
--            game reports TurnTimeRemaining 0 then, but in sudden death it keeps reporting the previous turn's
--            leftover (39340 for a whole intro, measured in game), so the hourglass sat on the "Ready?" text of every
--            sudden-death turn. A decrease of the value after the turn start is what ends the intro.
function HG.gate(m)
    if G.now - HG.groupsAt >= 0.1 then
        HG.groupsAt = G.now
        local over = false
        if wum.input and wum.input.groups then
            local ok, g = pcall(wum.input.groups)
            if ok and type(g) == "table" and #g > 0 then
                local menu, play = false, false
                for _, n in ipairs(g) do
                    if n == "Menu" then menu = true else play = true end
                end
                over = menu and not play
            end
        end
        HG.overlay = over
    end
    local ts = tonumber(m.turnsStarted)
    if ts and ts ~= HG.ts then
        if HG.ts ~= nil then HG.tsAt, HG.turnRan = G.now, false end
        HG.ts = ts
    end
    local tl = tonumber(m.turnMsLeft) or 0
    if not HG.turnRan and HG.tl and tl > 0 and tl < HG.tl then HG.turnRan = true end
    HG.tl = tl
    HG.intro = not HG.turnRan and G.now - HG.tsAt < 15
end

-- Called when the curse message arrives. A late copy goes straight to the water countdown.
function HG.strike(live)
    HG.strikeElapsed = HG.elapsed or (L.strikeMs or 180000)
    AU.stop("pour"); AU.stop("wind1"); AU.stop("wind2")
    if live then
        HG.state, HG.shAt, HG.jolt, HG.flash = "shatter", G.now, 1, 1
        AU.play("glass_shatter", 1.0)
    else
        HG.state = "water"
    end
end

-- The sand left in the top bulb for `remain` ms of `strike`. The levels are by volume, and the bulb narrows to the
-- neck, so a clock linear in time looks almost empty for the whole last half minute. The last 15 s keep a quarter of
-- the sand instead, so it visibly pours away while the cracks and the ticking build up; the rest drains evenly.
function HG.sandFrac(remain, strike)
    local last, keep = 15000, 0.25
    strike = max(strike, last + 1000)
    if remain <= last then return U.sat(keep * remain / last) end
    return U.sat(keep + (1 - keep) * (remain - last) / (strike - last))
end

function HG.img(name, rect, x0, y0, s, a, rgb)
    if a <= 0.003 then return end
    local t = TX.get(name)
    if not t then return end
    local k = s * 0.5
    pcall(wum.draw.hudImage, x0 + rect[1] * k, y0 + rect[2] * k, x0 + rect[3] * k, y0 + rect[4] * k, t,
        U.col(rgb or 0xFFFFFF, a))
end

function HG.text(cx, cy, str, size, rgb, a, glow)
    local w = #str * size * 0.52
    local x, y = cx - w / 2, cy - size * 0.55
    local o = max(1, size * 0.06)
    local sc = U.col(COLS.shadow, a * 0.8)
    pcall(wum.draw.hudText, x + o * 1.6, y + o * 1.6, str, sc, size)
    pcall(wum.draw.hudText, x - o, y, str, sc, size)
    pcall(wum.draw.hudText, x + o, y, str, sc, size)
    pcall(wum.draw.hudText, x, y - o, str, sc, size)
    pcall(wum.draw.hudText, x, y + o, str, sc, size)
    if glow then pcall(wum.draw.hudText, x, y - o * 0.5, str, U.col(glow, a * 0.4), size) end
    pcall(wum.draw.hudText, x, y, str, U.col(rgb, a), size)
end

-- The state machine, every frame (also without drawing, so the sounds keep time).
function HG.update()
    local m = G.m
    if not (m and L.have) then
        if HG.state ~= "hidden" then HG.reset() end
        return
    end
    local roundMs = tonumber(m.roundMs) or L.roundMs or 300000
    if roundMs <= 0 then roundMs = L.roundMs or 300000 end
    local left = tonumber(m.roundMsLeft) or roundMs
    local elapsed = roundMs - left
    HG.elapsed, HG.roundMs = elapsed, roundMs
    if HG.lastLeft and left ~= HG.lastLeft then HG.runAt = G.now end
    HG.lastLeft = left
    HG.running = G.now - HG.runAt < 0.4
    local strikeMs = L.strikeMs or 180000
    HG.remain = max(0, strikeMs - elapsed)
    -- The hourglass steps aside while the tour's letterbox is up (the shatter itself always shows).
    HG.gate(m)
    local want = (DIR.letter > 0.3 and HG.state ~= "shatter") and 0 or 1
    if HG.overlay then want = 0 elseif HG.intro and HG.state ~= "shatter" then want = 0.12 end
    if HG.alpha < want then HG.alpha = min(want, HG.alpha + G.dt * 2) else HG.alpha = max(want, HG.alpha - G.dt * (HG.overlay and 12 or 3)) end

    if HG.state == "hidden" then HG.state = (L.phase or 0) >= 2 and "water" or "run" end
    if HG.state == "run" or HG.state == "empty" then
        if (L.phase or 0) >= 1 or HG.remain <= 0 then
            if HG.state ~= "empty" then
                HG.state = "empty"
                AU.play("glass_crack", 0.9, 0.8)
                HG.jolt = 1
            end
        end
        -- Cracks at 0:15, 0:08, 0:03; a tick every second of the last 15 (only while the clock runs).
        local stage = HG.state == "empty" and 3 or (HG.remain <= 3000 and 3 or HG.remain <= 8000 and 2 or HG.remain <= 15000 and 1 or 0)
        if stage > HG.crack then
            if HG.crack > 0 or stage == 1 or HG.running then
                AU.play("glass_crack", 0.85, 0.95 + 0.1 * stage)
                HG.jolt = 0.6 + 0.2 * stage
            end
            HG.crack = stage
        elseif stage < HG.crack then
            HG.crack = stage   -- a test that rewinds the clock
        end
        local sec = ceil(HG.remain / 1000)
        if HG.state == "run" and HG.remain <= 15000 and HG.remain > 0 and HG.running and HG.lastSec and sec < HG.lastSec then
            AU.play(sec % 2 == 0 and "tick" or "tock", 0.55 + 0.03 * (15 - sec), 1 + (15 - sec) * 0.012)
            HG.beat = G.now
        end
        HG.lastSec = sec
        if HG.state == "run" and HG.remain <= 60000 and HG.remain > 0 then AU.loop("wind1", "wind_loop", 0.22) end
        if HG.state == "run" and HG.remain <= 15000 and HG.remain > 0 then
            AU.loop("wind2", "wind_loop", 0.35, 0.86)
            AU.loop("pour", "sand_pour_loop", 0.28)
        end
        if HG.state == "empty" then AU.stop("pour") end
    elseif HG.state == "shatter" then
        if G.now - HG.shAt > 12 * 0.055 + 0.15 then HG.state = "water" end
    end
    if HG.state == "water" or HG.state == "flood" then
        local flood = m.suddenDeath == true or elapsed >= roundMs
        if flood and HG.state ~= "flood" then
            HG.state = "flood"
            if not HG.flooded then
                HG.flooded = true
                if G.now - (HG.shAt or -100) > 2 then
                    AU.play("rumble", 0.9, 0.7)
                    BAN.show("THE TIDE RISES", "the drowned sands awaken", COLS.water, 4)
                end
            end
        end
    end
    HG.jolt = HG.jolt * exp(-G.dt * 7)
    HG.flash = HG.flash * exp(-G.dt * 5)
end

function HG.draw()
    if HG.state == "hidden" or not G.m then return end
    local s = G.sh / 1080 * CFG.scale * 0.88
    local W, H = 128 * s, 228 * s
    local x0 = floor(G.sw / 2 - W / 2)
    local y0 = floor(G.sh * 0.815 - H)
    local a = HG.alpha
    if a <= 0.01 then return end
    -- Shake: a jolt at each crack and the strike; a tremble while the empty glass waits.
    local jx, jy = 0, 0
    local amp = HG.jolt * 5 * s + (HG.state == "empty" and 1.3 * s or 0)
    if amp > 0.05 then
        jx = (sin(G.now * 71) + 0.6 * sin(G.now * 113 + 1)) * amp
        jy = (sin(G.now * 89 + 2) + 0.5 * sin(G.now * 131)) * amp * 0.6
    end
    x0, y0 = x0 + jx, y0 + jy
    local st = HG.state
    HG.img("hud/hg_shadow", R.full, x0, y0, s, a * 0.9)

    if st == "run" or st == "empty" then
        local frac = HG.sandFrac(HG.remain, L.strikeMs or 180000)
        local lowT = HG.remain <= 15000 and (1 - HG.remain / 15000) or 0
        if st == "empty" then lowT = 1 end
        -- The pulse follows the tick: a beat at each second, decaying.
        local beat = HG.beat and exp(-(G.now - HG.beat) * 4) or 0
        if st == "empty" then beat = 0.5 + 0.5 * sin(G.now * 9) end
        local glowA = lowT > 0 and (0.25 + 0.35 * lowT + 0.4 * beat) or 0
        HG.img("hud/hg_shadow_glass", R.full, x0, y0, s, a)
        HG.img("hud/hg_glow", R.full, x0, y0, s, a * glowA, st == "empty" and 0xFF7050 or 0xFFFFFF)
        HG.img("hud/hg_glass_back", R.full, x0, y0, s, a)
        -- Sand: 16 levels each, crossfaded between the two nearest. The bottom is the complement (volume kept).
        local lv = frac * 15
        local i0 = floor(lv)
        local f = lv - i0
        if i0 >= 15 then i0, f = 15, 0 end
        HG.img(HGN.top[i0], R.top, x0, y0, s, a)
        if f > 0.01 and i0 < 15 then HG.img(HGN.top[i0 + 1], R.top, x0, y0, s, a * f) end
        if frac > 0.002 then
            local fr = floor(G.now * 12) % 6
            HG.img(HGN.stream[fr], R.stream, x0, y0, s, a * (HG.running and 1 or 0.75))
        end
        local b0 = 15 - i0
        HG.img(HGN.bot[b0], R.bot, x0, y0, s, a)
        if f > 0.01 and b0 > 0 then HG.img(HGN.bot[b0 - 1], R.bot, x0, y0, s, a * f) end
        HG.img("hud/hg_glow_inner", R.full, x0, y0, s, a * glowA)
        HG.img("hud/hg_glass_front", R.full, x0, y0, s, a)
        if HG.crack > 0 then HG.img(HGN.crack[HG.crack], R.full, x0, y0, s, a) end
        HG.img("hud/hg_frame", R.full, x0, y0, s, a)
        HG.img("hud/hg_plate", R.plate, x0, y0, s, a)
        local txt, rgb, glow
        if st == "empty" then
            txt, rgb, glow = "0:00", (sin(G.now * 9) > -0.2) and COLS.red or COLS.ember, COLS.red
            HG.img("hud/hg_plate_glow", R.plate, x0, y0, s, a * (0.45 + 0.35 * beat), COLS.red)
        else
            txt = U.mmss(HG.remain)
            if lowT > 0 then
                rgb, glow = COLS.amber, COLS.ember
                HG.img("hud/hg_plate_glow", R.plate, x0, y0, s, a * (0.2 + 0.5 * beat), COLS.ember)
            else
                rgb = COLS.bone
            end
        end
        HG.text(x0 + 64 * s, y0 + 210 * s, txt, 22 * s, rgb, a, glow)
    else
        HG.img("hud/hg_frame", R.full, x0, y0, s, a)
        -- The drop fills from the strike to the water (5:00).
        local span = max(1000, HG.roundMs - (HG.strikeElapsed or HG.roundMs))
        local wl = max(0, HG.roundMs - HG.elapsed)
        local fill = st == "flood" and 1 or U.sat(1 - wl / span)
        local appear = st == "shatter" and U.sat((G.now - HG.shAt - 0.35) / 0.4) or 1
        local lv = fill * 8
        local i0 = min(8, floor(lv))
        local f = lv - i0
        local bob = 0
        if st == "flood" then bob = sin(G.now * 2.2) * 1.5 * s end
        local da = a * appear * (st == "flood" and (0.85 + 0.15 * sin(G.now * 3)) or 1)
        HG.img(HGN.drop[i0], R.drop, x0, y0 + bob, s, da)
        if f > 0.01 and i0 < 8 then HG.img(HGN.drop[i0 + 1], R.drop, x0, y0 + bob, s, da * f) end
        if st == "shatter" then
            local fr = floor((G.now - HG.shAt) / 0.055)
            if fr <= 11 then
                HG.img(HGN.shatter[fr], R.shatter, x0, y0, s, a)
            else
                HG.img("hud/hg_sand_spill", R.spill, x0, y0, s, a)
            end
        else
            HG.img("hud/hg_sand_spill", R.spill, x0, y0, s, a)
        end
        HG.img("hud/hg_plate", R.plate, x0, y0, s, a)
        local pulse = 0.5 + 0.5 * sin(G.now * (st == "flood" and 2.5 or 1.6))
        HG.img("hud/hg_plate_glow", R.plate, x0, y0, s, a * (st == "flood" and 0.35 + 0.3 * pulse or 0.18 + 0.12 * pulse),
            st == "flood" and COLS.deep or COLS.water)
        local txt = st == "flood" and "RISING" or U.mmss(wl)
        HG.text(x0 + 64 * s, y0 + 210 * s, txt, (st == "flood" and 17 or 22) * s, COLS.water, a * appear, COLS.deep)
    end
    if HG.flash > 0.02 then
        HG.img("hud/hg_glow", R.full, x0, y0, s, HG.flash, 0xFFE0B0)
    end
end

-------------------------------------------------------------------------------------------------------------- 4.
-- The sand line. The land under a grid is found with vertical landRay casts (spread over frames), then:
--   * the sheet: a translucent sand-haze plane at the line height over the land below it (one kept mesh);
--   * the ribbon: a glowing curtain where the line meets the land (marching squares on the grid; one kept mesh);
--   * grains and puffs drifting along the ribbon near the camera.
function LN.reset()
    if LN.sheet then pcall(wum.draw.freeMesh, LN.sheet) end
    if LN.ribbon then pcall(wum.draw.freeMesh, LN.ribbon) end
    LN.sheet, LN.ribbon, LN.probe, LN.nextProbe, LN.segs, LN.ns, LN.flare, LN.off = nil, nil, nil, 0, {}, 0, 0, false
    LN.job, LN.jobArg = nil, nil
    LN.k = 0.5
end

function LN.startProbe()
    local m = G.m
    if not (m and L.have and wum.game.landRay) then return end
    local x0, _, z0 = U.vx(m.landMin)
    local x1, _, z1 = U.vx(m.landMax)
    if not (x0 and x1 and z0 and z1) then return end
    -- The box can reach the arena edge (+-1500); 72 x 72 rays cover it at about 40 units.
    local n = 72
    local dx, dz = (x1 - x0) / (n - 1), (z1 - z0) / (n - 1)
    if dx <= 0 or dz <= 0 then return end
    local top = max(L.maxY or L.line, L.line) + 40
    local bot = min(L.minY or L.line, L.line) - 40
    LN.probe = { n = n, x0 = x0, z0 = z0, dx = dx, dz = dz, i = 0, h = {}, top = top, bot = bot, t0 = G.now }
end

function LN.stepProbe()
    local p = LN.probe
    local total = p.n * p.n
    local budget = 48
    while budget > 0 and p.i < total do
        local i = p.i
        local gx, gz = i % p.n, i // p.n
        local x, z = p.x0 + gx * p.dx, p.z0 + gz * p.dz
        local ok, t, why = pcall(wum.game.landRay, x, p.top, z, x, p.bot, z)
        -- nil alone = no land here; nil, "budget" = the frame's rays are spent, go on next frame; nil, "unavailable"
        -- can clear later (a landscape the sweep cannot take yet), so try the whole probe again in 10 s.
        if not ok then LN.probe = nil; LN.off = true; U.warn("sandtide: landRay: " .. tostring(t)); return end
        if t == nil and why == "budget" then return end
        if t == nil and why == "unavailable" then LN.probe = nil; LN.nextProbe = G.now + 10; return end
        if type(t) == "number" then p.h[i] = p.top + t * (p.bot - p.top) else p.h[i] = false end
        p.i = i + 1
        budget = budget - 1
    end
    if p.i >= total then
        LN.probe = nil
        LN.nextProbe = G.now + 30
        -- The build runs over several frames (each callback has an instruction budget).
        LN.job = coroutine.create(LN.build)
        LN.jobArg = p
    end
end

-- Marching squares on the probed heights, then the two meshes.
function LN.build(p)
    local n, h, line = p.n, p.h, L.line
    local water = G.m and tonumber(G.m.waterLevel) or -1e9
    local segs, ns = {}, 0
    local pts = {}
    local yield = coroutine.yield
    -- Marching squares: corners in order (x0,z0) (x1,z0) (x1,z1) (x0,z1); each edge whose ends straddle the line
    -- gives a crossing point.
    local cx, cz, ch = {}, {}, {}
    for gz = 0, n - 2 do
        if gz % 6 == 5 then yield() end
        for gx = 0, n - 2 do
            local i0 = gz * n + gx
            local h00, h10, h01, h11 = h[i0], h[i0 + 1], h[i0 + n], h[i0 + n + 1]
            if h00 and h10 and h01 and h11 then
                local x0, z0 = p.x0 + gx * p.dx, p.z0 + gz * p.dz
                local x1, z1 = x0 + p.dx, z0 + p.dz
                cx[1], cz[1], ch[1] = x0, z0, h00
                cx[2], cz[2], ch[2] = x1, z0, h10
                cx[3], cz[3], ch[3] = x1, z1, h11
                cx[4], cz[4], ch[4] = x0, z1, h01
                local np = 0
                for e = 1, 4 do
                    local f = e % 4 + 1
                    local ha, hb = ch[e], ch[f]
                    if (ha >= line) ~= (hb >= line) then
                        local t = (line - ha) / (hb - ha)
                        pts[np + 1], pts[np + 2] = cx[e] + (cx[f] - cx[e]) * t, cz[e] + (cz[f] - cz[e]) * t
                        np = np + 2
                    end
                end
                if np >= 4 and ns < 1400 then
                    segs[ns * 4 + 1], segs[ns * 4 + 2], segs[ns * 4 + 3], segs[ns * 4 + 4] = pts[1], pts[2], pts[3], pts[4]
                    ns = ns + 1
                    if np >= 8 then
                        segs[ns * 4 + 1], segs[ns * 4 + 2], segs[ns * 4 + 3], segs[ns * 4 + 4] = pts[5], pts[6], pts[7], pts[8]
                        ns = ns + 1
                    end
                end
            end
        end
    end
    LN.segs, LN.ns = segs, ns

    -- The ribbon: per segment two quads, the glow peaks at the line and fades above and below.
    if LN.ribbon then pcall(wum.draw.freeMesh, LN.ribbon); LN.ribbon = nil end
    if ns > 0 then
        local v, idx, nv = {}, {}, 0
        local rows = { { 16, 0 }, { 1, 1 }, { -7, 0 } }
        for s = 0, ns - 1 do
            if s % 300 == 299 then yield() end
            local ax, az, bx, bz = segs[s * 4 + 1], segs[s * 4 + 2], segs[s * 4 + 3], segs[s * 4 + 4]
            local ua, ub = (ax + az) / 48, (bx + bz) / 48
            local nx, nz = bz - az, -(bx - ax)
            local base = nv
            for r = 1, 3 do
                local dy, al = rows[r][1], rows[r][2]
                for e = 0, 1 do
                    local x, z, u = e == 0 and ax or bx, e == 0 and az or bz, e == 0 and ua or ub
                    local o = nv * 12
                    v[o + 1], v[o + 2], v[o + 3] = x, line + dy, z
                    v[o + 4], v[o + 5], v[o + 6] = nx, 0, nz
                    v[o + 7], v[o + 8] = u, (r - 1) * 0.5
                    v[o + 9], v[o + 10], v[o + 11], v[o + 12] = 1, 1, 1, al
                    nv = nv + 1
                end
            end
            for r = 0, 1 do
                local a, b = base + r * 2 + 1, base + r * 2 + 2
                local c, d = a + 2, b + 2
                local k = #idx
                idx[k + 1], idx[k + 2], idx[k + 3], idx[k + 4], idx[k + 5], idx[k + 6] = a, b, c, b, d, c
            end
        end
        local ok, hnd = pcall(wum.draw.newMesh, v, idx, "pntc")
        if ok and hnd then LN.ribbon = hnd else U.warn("sandtide: ribbon mesh: " .. tostring(hnd)) end
    end

    -- The sheet: alpha 1 where there is land at or under the line (and not deep under the sea), 0 elsewhere.
    if LN.sheet then pcall(wum.draw.freeMesh, LN.sheet); LN.sheet = nil end
    if line > water - 4 then
        local v, idx = {}, {}
        local al = {}
        for i = 0, n * n - 1 do
            local hh = h[i]
            -- A haze over the land just under the line (deepest 40 units below it fade out), never over water.
            al[i] = (hh and hh > water + 1) and U.sat((hh - (line - 40)) / 40) or 0
        end
        for i = 0, n * n - 1 do
            if i % 1500 == 1499 then yield() end
            local gx, gz = i % n, i // n
            local x, z = p.x0 + gx * p.dx, p.z0 + gz * p.dz
            local o = i * 12
            v[o + 1], v[o + 2], v[o + 3] = x, line, z
            v[o + 4], v[o + 5], v[o + 6] = 0, 1, 0
            v[o + 7], v[o + 8] = x / 90, z / 90
            v[o + 9], v[o + 10], v[o + 11], v[o + 12] = 1, 1, 1, al[i]
        end
        for gz = 0, n - 2 do
            for gx = 0, n - 2 do
                local a = gz * n + gx
                if al[a] > 0 or al[a + 1] > 0 or al[a + n] > 0 or al[a + n + 1] > 0 then
                    local k = #idx
                    idx[k + 1], idx[k + 2], idx[k + 3] = a + 1, a + n + 1, a + 2
                    idx[k + 4], idx[k + 5], idx[k + 6] = a + 2, a + n + 1, a + n + 2
                end
            end
        end
        if #idx > 0 then
            local ok, hnd = pcall(wum.draw.newMesh, v, idx, "pntc")
            if ok and hnd then LN.sheet = hnd else U.warn("sandtide: sheet mesh: " .. tostring(hnd)) end
        end
    end
    U.log(string.format("sandtide: sand line mapped in %.1f s: %d contour segments, sheet %s", G.now - p.t0, ns,
        LN.sheet and "on" or "off"))
end

function LN.update()
    if not (L.have and G.m) then return end
    if LN.off then return end
    if LN.job then
        local ok, err = coroutine.resume(LN.job, LN.jobArg)
        if not ok then U.warn("sandtide: line build: " .. tostring(err)); LN.job = nil; LN.off = true
        elseif coroutine.status(LN.job) == "dead" then LN.job = nil end
    elseif LN.probe then
        if not DIR.active then LN.stepProbe() end   -- the tour needs the frame's rays for its shots
    elseif G.now >= LN.nextProbe and not DIR.active then LN.startProbe() end
    -- Intensity: calm at first, rising as the hourglass runs low, a heartbeat in the last 30 s, flares at the curse.
    local k = 0.45
    if HG.state == "run" then
        local f = 1 - U.sat((HG.remain or 0) / max(1, L.strikeMs or 180000))
        k = 0.4 + 0.5 * f * f
        if (HG.remain or 1e9) < 30000 then k = k + 0.25 * (0.5 + 0.5 * sin(G.now * 5)) end
    elseif HG.state == "empty" then
        k = 0.95 + 0.3 * sin(G.now * 7)
    else
        k = 0.55
    end
    LN.flare = LN.flare * exp(-G.dt * 0.9)
    LN.k = k + LN.flare
    PT.lineSpawn()
end

function LN.drawWorld()
    if not L.have then return end
    local sand = TX.get("sand_albedo", { wrap = "repeat" })
    local band = TX.get("sand_band", { wrap = "repeat" })
    if LN.sheet then
        pcall(wum.draw.mesh, LN.sheet, sand, nil, { 1.0, 0.82, 0.52, U.clamp(0.16 + 0.16 * LN.k, 0, 0.45) },
            { lit = false, blend = "alpha", depthWrite = false, cull = false })
    end
    if LN.ribbon then
        pcall(wum.draw.mesh, LN.ribbon, band, nil, { 1.0, 0.74, 0.36, U.clamp(0.45 + 0.8 * LN.k, 0, 1) },
            { lit = false, blend = "additive", depthWrite = false, cull = false })
        -- A second, softer pass seen through the land, so the line still reads where a ridge hides it.
        pcall(wum.draw.mesh, LN.ribbon, band, nil, { 1.0, 0.70, 0.32, U.clamp(0.06 + 0.10 * LN.k, 0, 0.2) },
            { lit = false, blend = "additive", depthWrite = false, cull = false, xray = true })
    end
end

-------------------------------------------------------------------------------------------------------------- particles
-- One pool of tables, reused. kind: 1 grain (stretched along velocity), 2 puff (billboard, grows), 3 swirl (spins).
PT.pool, PT.n, PT.cap = {}, 0, 900
for i = 1, PT.cap do PT.pool[i] = { on = false } end
PT.free = 1
function PT.spawn(kind, x, y, z, vx, vy, vz, life, size, rgb, alpha, grav, drag, grow, mode)
    local p
    for _ = 1, PT.cap do
        local q = PT.pool[PT.free]
        PT.free = PT.free % PT.cap + 1
        if not q.on then p = q; break end
    end
    if not p then return nil end
    p.on, p.kind, p.x, p.y, p.z, p.vx, p.vy, p.vz = true, kind, x, y, z, vx, vy, vz
    p.age, p.life, p.size, p.rgb, p.alpha = 0, life, size, rgb, alpha
    p.grav, p.drag, p.grow, p.mode, p.spin, p.ang = grav or 0, drag or 0, grow or 0, mode or "alpha", 0, math.random() * 6.28
    p.tx, p.ty, p.tz, p.pull = nil, nil, nil, 0
    PT.n = PT.n + 1
    return p
end

-- Grains and puffs drifting along the line near the camera's focus. The wind turns slowly.
function PT.lineSpawn()
    if LN.ns <= 0 or not G.cam then return end
    local px, py, pz = U.vx(G.cam.pos)
    local fx, fy, fz = U.vx(G.cam.fwd)
    if not (px and fx) then return end
    local cx, cz = px + fx * 260, pz + fz * 260
    local want = (8 + 26 * LN.k) * CFG.fxk.parts * G.dt
    PT.acc = (PT.acc or 0) + want
    local wind = G.now * 0.05
    local wx, wz = cos(wind), sin(wind)
    while PT.acc >= 1 do
        PT.acc = PT.acc - 1
        for _ = 1, 4 do
            local s = math.random(0, LN.ns - 1)
            local t = math.random()
            local sx = LN.segs[s * 4 + 1] + (LN.segs[s * 4 + 3] - LN.segs[s * 4 + 1]) * t
            local sz = LN.segs[s * 4 + 2] + (LN.segs[s * 4 + 4] - LN.segs[s * 4 + 2]) * t
            local ddx, ddz = sx - cx, sz - cz
            if ddx * ddx + ddz * ddz < 650 * 650 then
                local sp = U.rand(6, 16)
                if math.random() < 0.82 then
                    PT.spawn(1, sx, L.line + U.rand(-1, 4), sz, wx * sp, U.rand(0.5, 3), wz * sp, U.rand(2, 4.5),
                        U.rand(0.9, 1.8), 0xF0D29A, U.rand(0.6, 0.95), -0.6, 0.1)
                else
                    PT.spawn(2, sx, L.line + U.rand(0, 3), sz, wx * sp * 0.4, U.rand(0.3, 1), wz * sp * 0.4,
                        U.rand(3, 5), U.rand(10, 20), 0xE2C48C, U.rand(0.16, 0.28), 0, 0.2, 1.2)
                end
                break
            end
        end
    end
end

function PT.update()
    local dt = G.dt
    if dt <= 0 then return end
    for i = 1, PT.cap do
        local p = PT.pool[i]
        if p.on then
            p.age = p.age + dt
            if p.age >= p.life then
                p.on = false
                PT.n = PT.n - 1
            else
                if p.pull > 0 and p.tx then
                    -- Converge: spiral toward the target point.
                    local dx, dy, dz = p.tx - p.x, p.ty - p.y, p.tz - p.z
                    local k = p.pull * dt
                    p.vx, p.vy, p.vz = p.vx + dx * k - dz * k * 0.9, p.vy + dy * k, p.vz + dz * k + dx * k * 0.9
                end
                local d = 1 - min(1, p.drag * dt)
                p.vx, p.vy, p.vz = p.vx * d, (p.vy + p.grav * 60 * dt) * d, p.vz * d
                p.x, p.y, p.z = p.x + p.vx * dt, p.y + p.vy * dt, p.z + p.vz * dt
                p.ang = p.ang + p.spin * dt
            end
        end
    end
end

function PT.draw()
    local grain, puff, swirl = TX.get("sand_grain"), TX.get("dust_puff"), TX.get("sand_swirl")
    if not (grain and puff and swirl) then return end
    local ux, uy, uz, rx, ry, rz = 0, 1, 0, 1, 0, 0
    if G.cam then
        local fx, fy, fz = U.vx(G.cam.fwd)
        local ax, ay, az = U.vx(G.cam.up)
        if fx and ax then
            ux, uy, uz = ax, ay, az
            rx, ry, rz = fy * az - fz * ay, fz * ax - fx * az, fx * ay - fy * ax
        end
    end
    local sprite = wum.draw.sprite
    for i = 1, PT.cap do
        local p = PT.pool[i]
        if p.on then
            local t = p.age / p.life
            local fade = U.sat(t * 6) * U.sat((1 - t) * 3)
            local a = p.alpha * fade
            if a > 0.004 then
                if p.kind == 1 then
                    local sp = sqrt(p.vx * p.vx + p.vy * p.vy + p.vz * p.vz)
                    if sp > 2 then
                        sprite(grain, p.x, p.y, p.z, p.size, p.size + sp * 0.03, p.vx, p.vy, p.vz, U.col(p.rgb, a), p.mode)
                    else
                        sprite(grain, p.x, p.y, p.z, p.size, 0, 0, 0, 0, U.col(p.rgb, a), p.mode)
                    end
                elseif p.kind == 2 then
                    sprite(puff, p.x, p.y, p.z, p.size * (1 + p.grow * t), 0, 0, 0, 0, U.col(p.rgb, a), p.mode)
                else
                    local c, s = cos(p.ang), sin(p.ang)
                    local sz = p.size * (1 + p.grow * t)
                    sprite(swirl, p.x, p.y, p.z, sz, sz, ux * c + rx * s, uy * c + ry * s, uz * c + rz * s, U.col(p.rgb, a), p.mode)
                end
            end
        end
    end
end

-- Doom: in the last 20 s, and while the empty glass waits, sand swirls round the feet of every worm below the line.
function PT.doom()
    if not (L.have and G.w) then return end
    if not (HG.state == "empty" or (HG.state == "run" and (HG.remain or 1e9) < 20000)) then return end
    PT.doomAcc = (PT.doomAcc or 0) + G.dt * 6 * CFG.fxk.parts
    if PT.doomAcc < 1 then return end
    PT.doomAcc = PT.doomAcc - 1
    for _, w in ipairs(G.w) do
        if w.alive then
            local x, y, z = U.vx(w.pos)
            if x and y < L.line then
                local a = math.random() * 6.28
                local r = U.rand(8, 16)
                local p = PT.spawn(1, x + cos(a) * r, y + U.rand(0, 3), z + sin(a) * r, -sin(a) * 18, U.rand(4, 9),
                    cos(a) * 18, 1.3, U.rand(1.0, 1.6), 0xF2D49A, 0.9, -0.2, 0.4)
                if p then p.tx, p.ty, p.tz, p.pull = x, y + 4, z, 3 end
                if math.random() < 0.25 then
                    local q = PT.spawn(3, x, y + 2, z, 0, 1, 0, 1.6, 16, 0xE8C890, 0.45, 0, 0, -0.5)
                    if q then q.spin = U.rand(4, 7) end
                end
            end
        end
    end
end

-------------------------------------------------------------------------------------------------------------- 5.
-- The mound: a lumpy dome of sand (unit radius and height, scaled by the model), its own shape per worm.
function CU.buildMound(seed)
    local RINGS, SEGS = 9, 30
    local ph = {}
    for k = 1, 6 do ph[k] = U.hash(seed * 7.13 + k) * 6.28 end
    local function lump(a, t)
        return 0.11 * sin(2 * a + ph[1]) + 0.08 * sin(3 * a + ph[2]) + 0.06 * sin(5 * a + ph[3])
            + 0.05 * sin(7 * a + ph[4] + t * 3)
    end
    local P = {}
    for r = 0, RINGS + 1 do
        local t = min(r / RINGS, 1)
        for s = 0, SEGS do
            local a = s / SEGS * 2 * pi
            local l = lump(a, t)
            local rad, y
            if r <= RINGS then
                rad = (0.18 + 0.82 * sin(t * pi / 2)) * (1 + l)
                if r == 0 then rad = 0.12 * (1 + l) end
                y = (cos(t * pi / 2) ^ 1.5) * (1 + 0.6 * l + 0.12 * sin(4 * a + ph[5])) + 0.02
            else
                rad = 1.14 * (1 + l)
                y = -0.9
            end
            P[#P + 1] = { cos(a) * rad, y, sin(a) * rad, s / SEGS * 5, t * 1.6, t, a }
        end
    end
    local row = SEGS + 1
    local idx = {}
    local nrm = {}
    for i = 1, #P do nrm[i] = { 0, 0, 0 } end
    for r = 0, RINGS do
        for s = 0, SEGS - 1 do
            local a = r * row + s + 1
            local b, c, d = a + 1, a + row, a + row + 1
            for _, tri in ipairs({ { a, b, c }, { b, d, c } }) do
                local p1, p2, p3 = P[tri[1]], P[tri[2]], P[tri[3]]
                local ux, uy, uz = p2[1] - p1[1], p2[2] - p1[2], p2[3] - p1[3]
                local vx, vy, vz = p3[1] - p1[1], p3[2] - p1[2], p3[3] - p1[3]
                local nx, ny, nz = uy * vz - uz * vy, uz * vx - ux * vz, ux * vy - uy * vx
                for _, k in ipairs(tri) do
                    local q = nrm[k]
                    q[1], q[2], q[3] = q[1] + nx, q[2] + ny, q[3] + nz
                end
                idx[#idx + 1], idx[#idx + 2], idx[#idx + 3] = tri[1], tri[2], tri[3]
            end
        end
    end
    -- The seam column (s = 0 and s = SEGS) shares its normal.
    for r = 0, RINGS + 1 do
        local a, b = nrm[r * row + 1], nrm[r * row + row]
        local x, y, z = a[1] + b[1], a[2] + b[2], a[3] + b[3]
        a[1], a[2], a[3], b[1], b[2], b[3] = x, y, z, x, y, z
    end
    local v = {}
    for i = 1, #P do
        local p, q = P[i], nrm[i]
        local o = (i - 1) * 12
        local speck = 0.9 + 0.2 * U.hash(seed + i * 1.7)
        local shade = (p[6] >= 1 and 0.62 or (0.78 + 0.22 * (1 - p[6]))) * speck
        v[o + 1], v[o + 2], v[o + 3] = p[1], p[2], p[3]
        v[o + 4], v[o + 5], v[o + 6] = q[1], q[2], q[3]
        v[o + 7], v[o + 8] = p[4], p[5]
        v[o + 9], v[o + 10], v[o + 11], v[o + 12] = 0.98 * shade, 0.84 * shade, 0.62 * shade, 1
    end
    local ok, h = pcall(wum.draw.newMesh, v, idx, "pntc")
    if ok and h then return h end
    U.warn("sandtide: mound mesh: " .. tostring(h))
    return nil
end

function CU.reset()
    for slot, c in pairs(CU.w) do
        if c.mesh then pcall(wum.draw.freeMesh, c.mesh) end
        Petrify.setWorm(slot, 0)
        CU.w[slot] = nil
    end
    CU.n = 0
end

-- The curse: one record per cursed worm, in tour order. `live` false = straight to the final state.
function CU.begin(c, live)
    CU.reset()
    for k, slot in ipairs(c.slots) do
        local w = G.byslot[slot]
        local x, y, z = nil, nil, nil
        if w then x, y, z = U.vx(w.pos) end
        local rec = { slot = slot, k = k - 1, seed = slot * 3.7 + (c.tick % 97) * 0.13, level = 0, mound = 0,
                      dz = 0, x = x, y = y, z = z, yaw = w and tonumber(w.yaw) or 0, name = w and w.name or ("Worm " .. slot),
                      team = w and tonumber(w.team) or 0, alive = w and w.alive or false, ev = {},
                      mat = {}, crumble = nil, final = not live, up = { 0, 1, 0 } }
        if not live then rec.level, rec.mound = 1, 1 end
        CU.ground(rec)
        CU.w[slot] = rec
    end
    CU.n = #c.slots
end

-- The ground's normal under the worm (tilts the mound on slopes, half way, so it never leans over).
function CU.ground(rec)
    if not (rec.x and wum.game.landRay) then return end
    local ok, t, nx, ny, nz = pcall(wum.game.landRay, rec.x, rec.y + 25, rec.z, rec.x, rec.y - 30, rec.z)
    if ok and type(t) == "number" and ny and ny > 0.3 then
        local ux, uy, uz = nx * 0.55, ny * 0.55 + 0.45, nz * 0.55
        local l = sqrt(ux * ux + uy * uy + uz * uz)
        rec.up = { ux / l, uy / l, uz / l }
        rec.gy = rec.y + 25 + t * -55
    end
end

-- A column-major model matrix: up axis `u`, facing `yaw`, scale, position. Written into `m` (no allocation).
function CU.matrix(m, px, py, pz, u, yaw, sx, sy, sz)
    local fx, fz = sin(yaw), cos(yaw)
    local Yx, Yy, Yz = u[1], u[2], u[3]
    local Xx, Xy, Xz = Yy * fz - Yz * 0, Yz * fx - Yx * fz, Yx * 0 - Yy * fx
    local l = sqrt(Xx * Xx + Xy * Xy + Xz * Xz)
    if l < 1e-4 then Xx, Xy, Xz, l = 1, 0, 0, 1 end
    Xx, Xy, Xz = Xx / l, Xy / l, Xz / l
    local Zx, Zy, Zz = Xy * Yz - Xz * Yy, Xz * Yx - Xx * Yz, Xx * Yy - Xy * Yx
    m[1], m[2], m[3], m[4] = Xx * sx, Xy * sx, Xz * sx, 0
    m[5], m[6], m[7], m[8] = Yx * sy, Yy * sy, Yz * sy, 0
    m[9], m[10], m[11], m[12] = Zx * sz, Zy * sz, Zz * sz, 0
    m[13], m[14], m[15], m[16] = px, py, pz, 1
    return m
end

-- Every frame: positions (pinned, but the snapshot is the truth), the dissolve under water, the crumble on death,
-- and the petrify driver's slot.
function CU.update()
    if not C then return end
    local water = G.m and tonumber(G.m.waterLevel) or -1e9
    -- Mounds are built one per frame (a build is a few tens of thousands of instructions).
    for _, slot in ipairs(C.slots) do
        local rec = CU.w[slot]
        if rec and not rec.meshTried then
            rec.meshTried = true
            rec.mesh = CU.buildMound(rec.seed)
            break
        end
    end
    for slot, rec in pairs(CU.w) do
        local w = G.byslot[slot]
        if w then
            local x, y, z = U.vx(w.pos)
            if x then
                if not rec.x then rec.x, rec.y, rec.z = x, y, z; CU.ground(rec)
                else
                    local k = 1 - exp(-G.dt * 12)
                    rec.x, rec.y, rec.z = rec.x + (x - rec.x) * k, rec.y + (y - rec.y) * k, rec.z + (z - rec.z) * k
                end
            end
            rec.yaw = tonumber(w.yaw) or rec.yaw
            rec.name = w.name or rec.name
        end
        local alive = w and w.alive == true
        if rec.alive and not alive and rec.mound > 0.05 and not rec.crumble then
            rec.crumble = G.now
            PT.burst(rec, 0.5)
        end
        rec.alive = alive
        -- Under water the cast washes away: from the feet (0) to the drowning height (feet + 7).
        local target = rec.y and U.sat((water - rec.y + 0.5) / 7.5) or 0
        if target > rec.dz then rec.dz = min(target, rec.dz + G.dt * 0.6) else rec.dz = max(target, rec.dz - G.dt * 0.3) end
        if rec.final then rec.level, rec.mound = 1, max(rec.mound, rec.crumble and 0 or 1) end
        Petrify.setWorm(slot, alive and rec.level or 0, rec.seed, rec.dz)
    end
end

function CU.drawWorld()
    if not C then return end
    local sand = TX.get("sand_albedo", { wrap = "repeat" })
    for _, rec in pairs(CU.w) do
        if rec.mesh and rec.x and rec.mound > 0.01 then
            local g = rec.mound
            local fadeA = 1
            local sy = g
            if rec.crumble then
                local t = (G.now - rec.crumble) / 1.4
                sy = g * (1 - 0.8 * U.smooth(t))
                fadeA = 1 - U.smooth(t)
            end
            fadeA = fadeA * (1 - rec.dz * 0.85)
            if fadeA > 0.01 then
                local gy = (rec.gy or rec.y) - 0.6 - rec.dz * 3
                -- A low, wide mound (3.4 high): the cast above it, from the mound up to the waist (the petrify
                -- effect's waist, 11.5), is what reads as the worm turning to sand, so the mound must not hide it.
                local m = CU.matrix(rec.mat, rec.x, gy, rec.z, rec.up, rec.yaw, 14.5 * g, 3.4 * sy, 14.5 * g)
                local opaque = fadeA > 0.98
                pcall(wum.draw.mesh, rec.mesh, sand, m, { 1, 1, 1, fadeA },
                    { lit = true, ambient = 0.55, cull = false, depthWrite = opaque, blend = "alpha" })
            end
        end
    end
end

-- A burst: grains thrown out under gravity and dust rolling out low. strength 0..1.
function PT.burst(rec, strength)
    if not rec.x then return end
    local k = CFG.fxk.parts * strength
    local x, y, z = rec.x, (rec.gy or rec.y) + 2, rec.z
    for _ = 1, floor(60 * k) do
        local a = math.random() * 6.28
        local sp = U.rand(25, 70)
        PT.spawn(1, x + cos(a) * 6, y + U.rand(0, 4), z + sin(a) * 6, cos(a) * sp, U.rand(30, 85), sin(a) * sp,
            U.rand(1.1, 2.0), U.rand(0.5, 1.1), 0xEED09A, 0.95, -2.2, 0.35)
    end
    for _ = 1, floor(26 * k) do
        local a = math.random() * 6.28
        local sp = U.rand(10, 34)
        PT.spawn(2, x + cos(a) * 8, y + U.rand(-1, 6), z + sin(a) * 8, cos(a) * sp, U.rand(2, 12), sin(a) * sp,
            U.rand(1.6, 3.0), U.rand(7, 13), 0xD8B987, U.rand(0.35, 0.6), 0.02, 0.9, 1.7)
    end
end

-- Swirls converge on a worm before the cast creeps up it.
function PT.converge(rec)
    if not rec.x then return end
    local k = CFG.fxk.parts
    local x, y, z = rec.x, rec.y, rec.z
    for _ = 1, floor(70 * k) do
        local a = math.random() * 6.28
        local r = U.rand(28, 55)
        local p = PT.spawn(1, x + cos(a) * r, y + U.rand(-2, 22), z + sin(a) * r, -sin(a) * 30, U.rand(-4, 4),
            cos(a) * 30, U.rand(1.4, 2.0), U.rand(0.7, 1.3), 0xF4D8A2, 0.9, 0, 1.1)
        if p then p.tx, p.ty, p.tz, p.pull = x, y + 3, z, 5 end
    end
    for i = 1, max(1, floor(4 * k)) do
        local p = PT.spawn(3, x, y + 3 + i * 2.5, z, 0, 0.5, 0, 1.9, 22 - i * 3, 0xE6C892, 0.55, 0, 0, -0.75)
        if p then p.spin = (i % 2 == 0 and -1 or 1) * U.rand(5, 8) end
    end
end

-------------------------------------------------------------------------------------------------------------- 6.
-- The director. Timeline in hold ticks T (50 per second) from melange.turnHold:
--   [0, intro)                         wide shot, rumble, the line flares
--   [intro + k*per, intro + (k+1)*per) worm k: dolly to a low 3/4 shot, swirls converge, the cast creeps (2 s), the
--                                      mound bursts up, dust, shake, crunch; the name caption
--   [intro + n*per, holdTicks)         back to the game camera
-- Without the camera tour the same timeline plays the effects and captions. Any error ends the override.
DIR.spec = { pos = { x = 0, y = 0, z = 0 }, target = { x = 0, y = 0, z = 0 }, fov = 45, frames = 3 }

function DIR.reset()
    if DIR.cam then pcall(wum.render.cameraOverride, nil) end
    DIR.active, DIR.mode, DIR.cam, DIR.c, DIR.h, DIR.T, DIR.seg, DIR.shots = false, nil, false, nil, nil, 0, -2, {}
    DIR.pose, DIR.from, DIR.letter, DIR.shake, DIR.waitAt, DIR.camOff = nil, nil, 0, 0, nil, false
    DIR.lastTick, DIR.frac = nil, 0
    AU.stop("drone"); AU.stop("tourwind")
end

function DIR.abort(why)
    U.warn("sandtide: tour stopped: " .. tostring(why))
    if DIR.cam then pcall(wum.render.cameraOverride, nil) end
    DIR.cam = false
    DIR.camOff = true
    DIR.wipe = 0
    for _, rec in pairs(CU.w) do rec.final = true end
    DIR.active = false
    AU.stop("drone"); AU.stop("tourwind")
end

function DIR.curse(c, live)
    if not live then return end
    if c.status == "spared" then
        AU.play("rumble", 0.6, 1.2)
        BAN.show("THE SANDS SPARE YOU", "no worm stood below the line", COLS.sand, 4)
        return
    end
    if #c.slots == 0 then return end
    LN.flare = 1.2
    if c.status ~= "ok" or (c.holdTicks or 0) <= 0 then
        DIR.start(c, nil, "quick")
        return
    end
    DIR.c, DIR.waitAt = c, G.now
    -- The hold usually starts within a tick or two of the curse. If it already did, start now.
    if HOLD and HOLD.tick >= c.tick and HOLD.tick - c.tick < 600 then DIR.start(c, HOLD, "tour") end
end

function DIR.hold(h)
    if DIR.c and not DIR.active and h.tick >= DIR.c.tick then DIR.start(DIR.c, h, "tour") end
end

function DIR.holdEnd()
    if DIR.active and DIR.mode == "tour" then
        DIR.finish()
    end
end

function DIR.start(c, h, mode)
    DIR.active, DIR.mode, DIR.c, DIR.h, DIR.waitAt = true, mode, c, h, nil
    DIR.T, DIR.seg, DIR.shots, DIR.t0 = 0, -2, {}, G.now
    DIR.from, DIR.pose, DIR.outFrom, DIR.cur, DIR.segCut, DIR.outCut, DIR.wipe = nil, nil, nil, nil, false, false, 0
    DIR.n = #c.slots
    DIR.total = mode == "tour" and c.holdTicks or (60 + DIR.n * 40 + 150)
    -- Tick sync: the client's tick and the hold's tick are the same clock when they agree at the start.
    DIR.useTick = h and G.tick - h.tick >= -5 and G.tick - h.tick < 40
    DIR.base = h and (DIR.useTick and h.tick or nil)
    DIR.frac, DIR.lastTick = 0, G.tick
    DIR.camOff = not (CFG.tour and mode == "tour" and wum.render.cameraOverride)
    AU.play("rumble", 1.0)
    AU.loop("drone", "drone_loop", 0.55)
    AU.loop("tourwind", "wind_loop", 0.3, 0.8)
    DIR.shake = 0.5
    local n = DIR.n
    BAN.show("THE HOURGLASS IS EMPTY", n == 1 and "one worm is claimed by the sands" or (n .. " worms are claimed by the sands"),
        COLS.sand, mode == "tour" and (c.intro / 50 + 1.4) or 3)
    U.log(string.format("sandtide: tour %s, %d worms, %.0f ticks, camera %s, tick sync %s", mode, n, DIR.total,
        DIR.camOff and "off" or "on", tostring(DIR.useTick)))
end

function DIR.finish()
    DIR.wipe = 0
    if DIR.cam then pcall(wum.render.cameraOverride, nil) end
    DIR.cam = false
    for _, rec in pairs(CU.w) do rec.final = true end
    DIR.active = false
    AU.stop("drone"); AU.stop("tourwind")
    U.log("sandtide: tour done")
end

-- The camera pose for one worm: a low three-quarter view, picked by what the eye would actually see.
--
-- The land ray only answers for one line, and a shot is a frustum: a roof slab just above the line to the worm's
-- chest filled most of one shot in the first in-game runs, and the land ray does not see worms at all, so another
-- worm's head sat in the foreground of others. So every candidate eye is scored by
--   * sight: the share of land rays that reach the worm's feet, waist, head, hat, shoulders and the mound's rim;
--   * worms: the other worms that stand in or next to that line (angular overlap, the nearer the worse, and a worm
--     the eye would sit inside);
--   * a taste for the low three-quarter front view.
-- A coarse pass (one ray per eye) ranks the candidates, a fine pass re-scores the best few, and when nothing at the
-- normal distance sees the worm well (a cave, an overhang), closer rings are tried. About 100 rays of the frame's
-- 256 at most, once per worm.
DIR.RING = { { d = 88, hs = { 16, 30, 46 }, offs = { 35, -35, 70, -70, 0, 110, -110, 145, -145, 180 } },
             { d = 52, hs = { 12, 26 }, offs = { 35, -35, 70, -70, 0, 110, -110, 145, -145, 180 } },
             { d = 32, hs = { 9, 18 }, offs = { 35, -35, 70, -70, 0, 110, -110, 180 } } }
DIR.rays = 0

-- One land ray; true when clear, false when it hits, nil when the frame's budget is spent (unknown).
function DIR.ray(x0, y0, z0, x1, y1, z1)
    DIR.rays = DIR.rays + 1
    local ok, t, why = pcall(wum.game.landRay, x0, y0, z0, x1, y1, z1)
    if not ok then return nil end
    if t == nil then
        if why == nil then return true end
        return nil
    end
    return false
end

-- The share of the worm an eye sees through the land: 1 ray to the waist, or 8 to the whole figure and the mound.
function DIR.sight(ex, ey, ez, rec, full)
    if not wum.game.landRay then return 1 end
    local x, y, z = rec.x, rec.y, rec.z
    local dx, dz = x - ex, z - ez
    local l = sqrt(dx * dx + dz * dz)
    if l < 1e-3 then l = 1 end
    local ax, az = -dz / l, dx / l       -- across the view, in the ground plane
    local pts = DIR.ptsOne
    if full then
        pts = DIR.ptsFull
        pts[5][1], pts[5][3], pts[6][1], pts[6][3] = ax * 7, az * 7, -ax * 7, -az * 7
        pts[7][1], pts[7][3], pts[8][1], pts[8][3] = ax * 11, az * 11, -ax * 11, -az * 11
    end
    local clear, n = 0, 0
    for i = 1, #pts do
        local p = pts[i]
        local r = DIR.ray(ex, ey, ez, x + p[1], y + p[2], z + p[3])
        n = n + 1
        if r == true then clear = clear + 1 elseif r == nil then clear = clear + 0.5 end
    end
    return clear / n
end
-- The waist; the shins (a ray to the feet themselves grazes the ground and answers either way), chest, hat, both
-- shoulders, and the mound's rim on both sides.
DIR.ptsOne = { { 0, 8, 0 } }
DIR.ptsFull = { { 0, 8, 0 }, { 0, 5, 0 }, { 0, 15, 0 }, { 0, 21, 0 }, { 0, 10, 0 }, { 0, 10, 0 }, { 0, 6, 0 }, { 0, 6, 0 } }

-- How close the ground runs under the line of sight: a plateau edge a few units under it hides the worm's legs and
-- the mound behind its own horizon, and the eye then sees mostly that plateau (measured in game: a ledge 10 units
-- under a stop filled the lower half of the frame). Vertical probes at four points along the line; each one with
-- less than 10 units of air under the line costs up to 0.35.
DIR.CLEAR_F = { 0.2, 0.4, 0.6, 0.8 }
function DIR.clearance(ex, ey, ez, rec)
    if not wum.game.landRay then return 0 end
    local tx, ty, tz = rec.x, rec.y + 9, rec.z
    local pen = 0
    for _, f in ipairs(DIR.CLEAR_F) do
        local px, py, pz = ex + (tx - ex) * f, ey + (ty - ey) * f, ez + (tz - ez) * f
        DIR.rays = DIR.rays + 1
        local ok, t = pcall(wum.game.landRay, px, py + 30, pz, px, py - 30, pz)
        if ok and type(t) == "number" then
            local air = 30 - t * 60     -- the line's height over the land there (negative: the ray hit anyway)
            if air < 10 then pen = pen + 0.35 * U.sat((10 - air) / 10) end
        end
    end
    return pen
end

-- Other worms in the way of an eye looking at the worm: 0 when none, about 1 for one worm squarely in front of it,
-- more for one the eye would sit inside. Worms behind the target do not count.
function DIR.wormBlock(ex, ey, ez, rec)
    local tx, ty, tz = rec.x, rec.y + 9, rec.z
    local vx, vy, vz = tx - ex, ty - ey, tz - ez
    local L = sqrt(vx * vx + vy * vy + vz * vz)
    if L < 1 then return 0 end
    vx, vy, vz = vx / L, vy / L, vz / L
    local pen = 0
    for slot, w in pairs(G.byslot) do
        if slot ~= rec.slot and w.alive == true then
            local wx, wy, wz = U.vx(w.pos)
            if wx then
                local px, py, pz = wx - ex, wy + 9 - ey, wz - ez
                local dist = sqrt(px * px + py * py + pz * pz)
                local along = px * vx + py * vy + pz * vz
                if dist < 24 then
                    pen = pen + 1.5
                elseif along > 0 and along < L - 3 then
                    local ox, oy, oz = px - along * vx, py - along * vy, pz - along * vz
                    local off = sqrt(ox * ox + oy * oy + oz * oz)
                    -- Angular overlap: that worm's silhouette (radius 12 with the hat) against the target's (10).
                    local tanOff = off / along
                    local r = 12 / along + 10 / L
                    if tanOff < r then pen = pen + (1 - tanOff / r) * U.sat((L - along) / 30) end
                end
            end
        end
    end
    return pen
end

function DIR.shot(rec)
    if not rec.x then return nil end
    local tx, ty, tz = rec.x, rec.y + 11, rec.z
    local yaw = rec.yaw or 0
    DIR.rays = 0
    local best, bestScore
    local cands = {}
    local function score(c, vis)
        -- Sight weighs most; a foreground worm costs about as much as losing the whole figure.
        return vis * 2 - c.pen * 1.6 + 0.35 * (1 - abs(c.off) / 180 * 0.6 - U.sat((c.h - 9) / 40) * 0.3)
    end
    for ri, ring in ipairs(DIR.RING) do
        -- Coarse: every eye of the ring, by its waist ray and the worms in the way.
        for i = 1, #cands do cands[i] = nil end
        for _, off in ipairs(ring.offs) do
            for _, h in ipairs(ring.hs) do
                local a = yaw + off * pi / 180
                local ex, ey, ez = tx + sin(a) * ring.d, ty + h, tz + cos(a) * ring.d
                local c = { a = a, h = h, d = ring.d, off = off, ex = ex, ey = ey, ez = ez }
                c.pen = DIR.wormBlock(ex, ey, ez, rec)
                c.vis = DIR.sight(ex, ey, ez, rec, false)
                c.s = score(c, c.vis)
                cands[#cands + 1] = c
            end
        end
        table.sort(cands, function(p, q) return p.s > q.s end)
        -- Fine: the whole figure and the ground under the line of sight for the best few.
        for i = 1, min(6, #cands) do
            local c = cands[i]
            if c.vis > 0 then
                c.vis = DIR.sight(c.ex, c.ey, c.ez, rec, true)
                c.pen = c.pen + DIR.clearance(c.ex, c.ey, c.ez, rec)
                c.s = score(c, c.vis)
            end
            if not best or c.s > bestScore then best, bestScore = c, c.s end
        end
        -- Good enough at this distance: a mostly visible worm with nothing in front of it.
        if best and best.vis >= 0.75 and best.pen < 0.3 then break end
        if ri == #DIR.RING or DIR.rays > 170 then break end
    end
    if not best then best = { a = yaw + 0.6, h = 30, d = 70, off = 35, vis = 0, pen = 0 } end
    best.side = best.off >= 0 and 1 or -1
    if best.off == 0 then best.side = 1 end
    best.tx, best.ty, best.tz = tx, ty, tz
    -- The stop itself: the dolly starts 10 % further out and swings 12 degrees round the worm. Each end gets a waist
    -- ray; a blocked swing turns the other way or stays put, a blocked start begins at the stop.
    local function endClear(a, d, h)
        return DIR.ray(tx + sin(a) * d, ty + h, tz + cos(a) * d, tx, ty - 3, tz) ~= false
    end
    best.d0 = endClear(best.a, best.d * 1.1, best.h) and 1.1 or 1.0
    local sw = 12 * pi / 180
    if not endClear(best.a + best.side * sw, best.d * 0.94, best.h * 0.9) then
        if endClear(best.a - best.side * sw, best.d * 0.94, best.h * 0.9) then best.side = -best.side else best.side = 0 end
    end
    U.log(string.format("sandtide: shot for %s: off %d, h %d, d %d, sight %.2f, worms %.2f, swing %d, %d rays",
        tostring(rec.name), best.off, best.h, best.d, best.vis, best.pen, best.side, DIR.rays))
    return best
end

-- The wide shot over every cursed worm, from the game camera's side.
function DIR.wide()
    local sx, sy, sz, n = 0, 0, 0, 0
    for _, rec in pairs(CU.w) do
        if rec.x then sx, sy, sz, n = sx + rec.x, sy + rec.y, sz + rec.z, n + 1 end
    end
    if n == 0 then return nil end
    sx, sy, sz = sx / n, sy / n, sz / n
    local spread = 0
    for _, rec in pairs(CU.w) do
        if rec.x then spread = max(spread, sqrt((rec.x - sx) ^ 2 + (rec.z - sz) ^ 2)) end
    end
    local fx, fz = 0, 1
    if G.gcam then
        local a, _, b = U.vx(G.gcam.fwd)
        if a then
            local l = sqrt(a * a + b * b)
            if l > 0.1 then fx, fz = a / l, b / l end
        end
    end
    local d = 170 + spread * 1.25
    local px, py, pz = sx - fx * d, sy + 120 + spread * 0.55, sz - fz * d
    -- Land between the worms and the eye (a hill behind them): raise the eye, in two steps, while a ray from the
    -- middle of the group gets through.
    if wum.game.landRay then
        for _, lift in ipairs(DIR.WIDE_LIFTS) do
            if DIR.ray(sx, sy + 12, sz, px, py + lift, pz) ~= false then py = py + lift; break end
        end
    end
    return { px = px, py = py, pz = pz, tx = sx, ty = sy + 6, tz = sz, fov = 50 }
end
DIR.WIDE_LIFTS = { 0, 70, 150 }

function DIR.gamePose()
    local c = G.gcam
    if not c then return nil end
    local px, py, pz = U.vx(c.pos)
    local fx, fy, fz = U.vx(c.fwd)
    if not (px and fx) then return nil end
    return { px = px, py = py, pz = pz, tx = px + fx * 200, ty = py + fy * 200, tz = pz + fz * 200,
             fov = tonumber(c.fov) or 45 }
end

function DIR.lerpPose(a, b, e, lift)
    local p = { px = U.lerp(a.px, b.px, e), py = U.lerp(a.py, b.py, e), pz = U.lerp(a.pz, b.pz, e),
                tx = U.lerp(a.tx, b.tx, e), ty = U.lerp(a.ty, b.ty, e), tz = U.lerp(a.tz, b.tz, e),
                fov = U.lerp(a.fov or 45, b.fov or 45, e) }
    if lift and lift > 0 then
        local dx, dz = b.px - a.px, b.pz - a.pz
        local up = min(sqrt(dx * dx + dz * dz) * 0.3, 220) * sin(pi * e) * lift
        p.py, p.ty = p.py + up, p.ty + up * 0.4
    end
    return p
end

-- True when the straight path between two poses' eyes (through the lifted midpoint the dolly takes) misses the land.
function DIR.pathClear(a, b, lift)
    if not (a and b and wum.game.landRay) then return true end
    local m = DIR.lerpPose(a, b, 0.5, lift)
    local ok1, t1 = pcall(wum.game.landRay, a.px, a.py, a.pz, m.px, m.py, m.pz)
    local ok2, t2 = pcall(wum.game.landRay, m.px, m.py, m.pz, b.px, b.py, b.pz)
    return not (ok1 and type(t1) == "number") and not (ok2 and type(t2) == "number")
end

-- A sand wipe hides a cut: in over 0.3 s, the cut, out by 0.65 s. Returns the blend factor (0 before, 1 after).
function DIR.wipeAt(u)
    DIR.wipe = u < 0.3 and U.smooth(u / 0.3) or U.smooth((0.65 - u) / 0.35)
    return u < 0.3 and 0 or 1
end

function DIR.time()
    -- Hold ticks since the start, smoothed between ticks with the wall clock.
    if DIR.mode == "tour" and DIR.useTick then
        if G.tick ~= DIR.lastTick then DIR.lastTick, DIR.frac = G.tick, 0
        else DIR.frac = min(0.98, DIR.frac + G.dt * 50) end
        local T = max(0, G.tick - DIR.base + DIR.frac)
        if T < DIR.T then T = DIR.T end      -- never run backwards
        return T
    end
    return (G.now - DIR.t0) * 50
end

-- One worm's beats at u seconds into its stop.
function DIR.beats(rec, u, cam)
    local ev = rec.ev
    if u >= 0.25 and not ev.swirl then ev.swirl = true; PT.converge(rec) end
    if u >= 0.55 and not ev.grind then
        ev.grind = true
        AU.play("sand_grind", 1.0, U.rand(0.95, 1.05), rec.x and { x = rec.x, y = rec.y, z = rec.z } or nil)
    end
    rec.level = max(rec.level, U.smooth((u - 0.6) / 2.0))
    if u >= 1.75 then rec.mound = max(rec.mound, U.outBack((u - 1.75) / 0.85)) end
    if u >= 1.75 and not ev.dust then ev.dust = true; AU.play("dust_burst", 0.9, U.rand(0.92, 1.08)) end
    if u >= 2.55 and not ev.crunch then
        ev.crunch = true
        rec.level, rec.mound = 1, max(rec.mound, 1)
        PT.burst(rec, 1)
        AU.play("crunch", 1.0, U.rand(0.97, 1.03))
        DIR.shake = max(DIR.shake, cam and 1 or 0.4)
        HG.jolt = max(HG.jolt, 0.5)
    end
    if u >= 0.9 and u < 3.5 then
        local a = U.sat((u - 0.9) / 0.35) * U.sat((3.45 - u) / 0.3)
        BAN.caption(rec, a)
    end
end

function DIR.update()
    if not DIR.active then
        -- The curse came but no hold followed (the hold refused late): play the effects without the camera.
        if DIR.c and DIR.waitAt and G.now - DIR.waitAt > 3 then
            DIR.waitAt = nil
            DIR.start(DIR.c, nil, "quick")
        end
        return
    end
    local c = DIR.c
    local T = DIR.time()
    DIR.T = T
    local n = DIR.n
    local useCam = not DIR.camOff
    local quick = DIR.mode ~= "tour"
    local intro = quick and 60 or c.intro
    local per = quick and 40 or c.per
    local tourEnd = intro + n * per
    if quick then tourEnd = intro + (n - 1) * per + 150 end

    -- The worms' beats.
    for k, slot in ipairs(c.slots) do
        local rec = CU.w[slot]
        if rec and not rec.final then
            local u = (T - (intro + (k - 1) * per)) / 50
            if u >= 0 then
                if rec.alive or u > 3.5 then DIR.beats(rec, u, useCam) else rec.final = true end
            end
        end
    end

    -- The letterbox and the sounds that end with the tour.
    local endT = DIR.total
    local want = (T < endT - (quick and 0 or c.outro * 0.6)) and 1 or 0
    if quick or not useCam then want = 0 end
    DIR.letter = DIR.letter + (want - DIR.letter) * min(1, G.dt * 4)
    DIR.shake = DIR.shake * exp(-G.dt * 3.2)

    if T >= endT then DIR.finish(); return end

    if not useCam then return end
    -- The camera.
    local pose
    if T < intro then
        local wide = DIR.wide() or DIR.gamePose()
        local start = DIR.from or DIR.gamePose()
        DIR.from = start
        if not (wide and start) then DIR.abort("no camera"); return end
        local push = T / intro
        wide.py = wide.py - 18 * push
        pose = DIR.lerpPose(start, wide, U.smoother(T / (intro * 0.75)), 0.35)
    elseif T < tourEnd then
        local k = floor((T - intro) / per)
        if k ~= DIR.seg then
            DIR.seg = k
            DIR.from = DIR.pose
            local rec = CU.w[c.slots[k + 1]]
            DIR.cur = (rec and rec.alive) and DIR.shot(rec) or nil
            DIR.segCut = false
            if DIR.cur and DIR.from then
                local s0 = DIR.cur
                local a = s0.a
                local to = { px = s0.tx + sin(a) * s0.d * s0.d0, py = s0.ty + s0.h, pz = s0.tz + cos(a) * s0.d * s0.d0,
                             tx = s0.tx, ty = s0.ty, tz = s0.tz }
                DIR.segCut = not DIR.pathClear(DIR.from, to, 1)
            end
        end
        local u = (T - intro - k * per) / 50
        local s = DIR.cur
        local target
        if s then
            local tt = U.sat(u / 3.5)
            local a = s.a + s.side * (12 * pi / 180) * U.smooth(tt)
            local d = s.d * (s.d0 - (s.d0 - 0.94) * U.smooth(tt))
            target = { px = s.tx + sin(a) * d, py = s.ty + s.h * (1 - 0.1 * tt), pz = s.tz + cos(a) * d,
                       tx = s.tx, ty = s.ty - 2, tz = s.tz, fov = 44 }
        else
            target = DIR.wide() or DIR.gamePose()
        end
        local from = DIR.from or target
        if DIR.segCut then
            pose = DIR.lerpPose(from, target, DIR.wipeAt(u), 0)
        else
            pose = DIR.lerpPose(from, target, U.smoother(u / 0.95), 1)
        end
    else
        local g = DIR.gamePose()
        if not g then DIR.abort("no game camera"); return end
        if not DIR.outFrom then
            DIR.outFrom = DIR.pose or g
            DIR.outCut = not DIR.pathClear(DIR.outFrom, g, 0.2)
        end
        local span = max(1, endT - tourEnd)
        if DIR.outCut then
            pose = DIR.lerpPose(DIR.outFrom, g, DIR.wipeAt((T - tourEnd) / 50), 0)
        else
            pose = DIR.lerpPose(DIR.outFrom, g, U.smoother((T - tourEnd) / (span * 0.9)), 0.2)
        end
    end
    if not pose then return end
    DIR.pose = pose
    -- Shake: three incommensurate sines per axis, decaying, scaled by the effects setting.
    local sk = DIR.shake * CFG.fxk.shake * 2.6
    local ox, oy, oz = 0, 0, 0
    if sk > 0.01 then
        local t = G.now
        ox = (sin(t * 37.1) + 0.6 * sin(t * 53.7 + 1.3)) * sk
        oy = (sin(t * 41.3 + 0.7) + 0.6 * sin(t * 67.9)) * sk
        oz = (sin(t * 29.9 + 2.1) + 0.6 * sin(t * 59.3 + 0.4)) * sk
    end
    local sp = DIR.spec
    sp.pos.x, sp.pos.y, sp.pos.z = pose.px + ox, pose.py + oy, pose.pz + oz
    sp.target.x, sp.target.y, sp.target.z = pose.tx + ox * 0.4, pose.ty + oy * 0.4, pose.tz + oz * 0.4
    local dx, dy, dz = sp.pos.x - sp.target.x, sp.pos.y - sp.target.y, sp.pos.z - sp.target.z
    if dx * dx + dy * dy + dz * dz < 1 then sp.target.y = sp.target.y - 1 end
    sp.fov = U.clamp(pose.fov or 45, 10, 120)
    local ok, res, why = pcall(wum.render.cameraOverride, sp)
    if not ok or res ~= true then
        DIR.camOff = true
        DIR.cam = false
        U.warn("sandtide: camera override refused: " .. tostring(ok and why or res))
        return
    end
    DIR.cam = true
end

-------------------------------------------------------------------------------------------------------------- banners
BAN.big, BAN.cap = nil, nil
function BAN.show(title, sub, rgb, dur)
    BAN.big = { title = title, sub = sub, rgb = rgb, at = G.now, dur = dur or 3 }
end
function BAN.caption(rec, a)
    BAN.cap = { rec = rec, a = a, at = G.now }
end
function BAN.draw()
    local s = G.sh / 1080
    local W, H = G.sw, G.sh
    -- The letterbox.
    if DIR.letter > 0.01 then
        local bh = floor(H * 0.09 * U.smooth(DIR.letter))
        pcall(wum.draw.hudRect, 0, 0, W, bh, U.col(0x000000, 0.92), true)
        pcall(wum.draw.hudRect, 0, H - bh, W, H, U.col(0x000000, 0.92), true)
    end
    local b = BAN.big
    if b then
        local t = G.now - b.at
        if t > b.dur + 0.8 then BAN.big = nil
        else
            local a = U.sat(t / 0.5) * U.sat((b.dur + 0.8 - t) / 0.8)
            -- A third of the way down: below the game's own turn-intro name and above the hourglass.
            local y = H * 0.33 - (1 - U.outCubic(t / 0.8)) * 14 * s
            local size = 46 * s
            local tw = #b.title * size * 0.52
            pcall(wum.draw.hudRect, W / 2 - tw * 0.62, y - 30 * s, W / 2 + tw * 0.62, y + 48 * s, U.col(0x120904, 0.72 * a), true)
            pcall(wum.draw.hudLine, W / 2 - tw * 0.55, y + 30 * s, W / 2 + tw * 0.55, y + 30 * s, U.col(b.rgb, 0.7 * a), 2 * s)
            HG.text(W / 2, y, b.title, size, b.rgb, a, COLS.ember)
            if b.sub then HG.text(W / 2, y + 42 * s, b.sub, 20 * s, COLS.bone, a * 0.9) end
        end
    end
    if (DIR.wipe or 0) > 0.01 then
        pcall(wum.draw.hudRect, 0, 0, W, H, U.col(0xC9A468, U.sat(DIR.wipe)), true)
    end
    if DIR.active then DIR.wipe = 0 end   -- set again by the director while a wipe runs
    local c = BAN.cap
    if c then
        if G.now - c.at > 0.1 then BAN.cap = nil
        else
            local rec, a = c.rec, c.a
            local y = H * 0.72
            local name = tostring(rec.name or "")
            local rgb = COLS.team[rec.team or 0] or COLS.bone
            local size = 38 * s
            local tw = max(#name * size * 0.52, 300 * s)
            pcall(wum.draw.hudRect, W / 2 - tw * 0.7, y - 30 * s, W / 2 + tw * 0.7, y + 44 * s, U.col(0x0E0703, 0.5 * a), true)
            pcall(wum.draw.hudRect, W / 2 - tw * 0.7, y - 30 * s, W / 2 - tw * 0.7 + 5 * s, y + 44 * s, U.col(rgb, 0.9 * a), true)
            HG.text(W / 2, y, name, size, rgb, a)
            HG.text(W / 2, y + 30 * s, "TURNED TO SAND", 18 * s, COLS.sand, a * 0.9)
        end
    end
end

-------------------------------------------------------------------------------------------------------------- frame
local function resetMatch()
    L = { have = false }
    C, HOLD = nil, nil
    HG.reset()
    LN.reset()
    CU.reset()
    DIR.reset()
    BAN.big, BAN.cap = nil, nil
    AU.stopAll()
    for i = 1, PT.cap do PT.pool[i].on = false end
    PT.n = 0
    Petrify.reset()
end

local function update()
    local now = os.clock()
    G.dt = G.last and U.clamp(now - G.last, 0, 0.1) or 0
    G.last, G.now = now, now
    G.frame = G.frame + 1
    CFG.refresh()
    local ok, im = pcall(wum.game.inMatch)
    im = ok and im == true
    if not im then
        if G.inMatch then resetMatch() end
        G.inMatch = false
        Petrify.frame()
        return
    end
    G.inMatch = true
    local okt, tick = pcall(wum.game.tick)
    local prev = G.tick
    G.tick = okt and tonumber(tick) or 0
    -- A new match without a match end in between (the tick counts from each match's start).
    if G.tick + 100 < prev then resetMatch() end
    local okm, m = pcall(wum.game.match)
    G.m = okm and type(m) == "table" and m or nil
    local okw, w = pcall(wum.game.worms)
    G.w = okw and type(w) == "table" and w or nil
    local by = G.byslot
    for k in pairs(by) do by[k] = nil end
    if G.w then for _, x in ipairs(G.w) do if type(x) == "table" and x.slot then by[x.slot] = x end end end
    if wum.render.windowSize then
        local okz, ww, hh = pcall(wum.render.windowSize)
        if okz and type(ww) == "number" and type(hh) == "number" and hh > 0 then G.sw, G.sh = ww, hh end
    end
    local okc, cam = pcall(wum.render.camera)
    G.cam = okc and type(cam) == "table" and cam or nil
    if wum.render.gameCamera then
        local okg, gc = pcall(wum.render.gameCamera)
        G.gcam = okg and type(gc) == "table" and gc or G.cam
    else
        G.gcam = G.cam
    end
    HG.update()
    LN.update()
    PT.doom()
    PT.update()
    CU.update()
    Petrify.frame()
end

local updateG = U.guard("update", update)
local directorG = U.guard("director", function() DIR.update() end)
wum.timers.every(0, function()
    updateG()
    if G.inMatch then directorG() end
end)

wum.draw.on("world", U.guard("draw.world", function()
    if not G.inMatch then return end
    CU.drawWorld()
end))
wum.draw.on("worldLate", U.guard("draw.worldLate", function()
    if not G.inMatch then return end
    LN.drawWorld()
    if wum.draw.sprite then PT.draw() end
end))
if wum.draw.hudImage and wum.draw.hudText then
    wum.draw.on("hud", U.guard("draw.hud", function()
        if not G.inMatch then return end
        BAN.draw()
        HG.draw()
    end))
end

local function on(name, fn)
    local g = U.guard("event " .. name, fn)
    pcall(wum.events.on, name, function(p) g(p) end)
end
on("Sandtide.Line", MSG.line)
on("Sandtide.Curse", MSG.curse)
on("melange.turnHold", MSG.hold)
on("melange.turnHoldEnd", MSG.holdEnd)
on("melange.match.end", function() resetMatch() end)
Petrify.install()
HG.reset()
LN.reset()
DIR.reset()

-- Debugging through lua.eval @sandtide: SANDTIDE_STATE() returns a one-line summary.
function SANDTIDE_STATE()
    local n = 0
    for _ in pairs(CU.w) do n = n + 1 end
    return string.format("water=%s line=%s phase=%s hg=%s remain=%s elapsed=%s curse=%s hold=%s dir=%s/%s T=%.0f cam=%s cursed=%d parts=%d segs=%d sheet=%s ribbon=%s tick=%s",
        tostring(G.m and G.m.waterLevel), tostring(L.line), tostring(L.phase), tostring(HG.state), tostring(HG.remain), tostring(HG.elapsed),
        C and (C.status .. "@" .. C.tick) or "-", HOLD and (HOLD.ticks .. "@" .. HOLD.tick) or "-",
        tostring(DIR.active), tostring(DIR.mode), DIR.T or 0, tostring(DIR.cam), n, PT.n, LN.ns or 0,
        tostring(LN.sheet), tostring(LN.ribbon), tostring(G.tick))
end

-- SANDTIDE_GROUPS() lists the game's active input groups; SANDTIDE_PETRIFY(slot, level[, dissolve]) casts any worm (a
-- look check without waiting for the curse; 0 clears it).
function SANDTIDE_GROUPS()
    if not (wum.input and wum.input.groups) then return "no wum.input.groups" end
    local ok, g = pcall(wum.input.groups)
    if not ok or type(g) ~= "table" then return "groups: " .. tostring(g) end
    return table.concat(g, ",")
end
function SANDTIDE_LINEPOINT(i)
    i = math.floor(tonumber(i) or 0)
    if not (LN.ns and i >= 0 and i < LN.ns) then return nil end
    return LN.segs[i * 4 + 1], L.line, LN.segs[i * 4 + 2]
end
function SANDTIDE_PETRIFY(slot, level, dissolve)
    Petrify.resend()
    return Petrify.setWorm(slot, level, slot, dissolve)
end
-- SANDTIDE_SHOT(slot) picks and logs the tour's camera stop for any worm (no camera move). SANDTIDE_TOUR("1,2,3")
-- plays the whole curse show on those worms without a sim curse (the camera tour, the casts, the mounds), timed by
-- the wall clock; SANDTIDE_TOUR("") clears it. Both are look checks: nothing reaches the simulation.
function SANDTIDE_SHOT(slot)
    local w = G.byslot[math.tointeger(tonumber(slot) or -1) or -1]
    if not w then return "no worm" end
    local x, y, z = U.vx(w.pos)
    local s = DIR.shot({ slot = w.slot, x = x, y = y, z = z, yaw = tonumber(w.yaw) or 0, name = w.name })
    if not s then return "no shot" end
    return string.format("off %d h %d d %d sight %.2f worms %.2f swing %d d0 %.1f rays %d", s.off, s.h, s.d, s.vis, s.pen,
        s.side, s.d0, DIR.rays)
end
function SANDTIDE_TOUR(csv)
    local slots = {}
    for _, s in ipairs(U.split(tostring(csv or ""), ",")) do
        local n = math.tointeger(tonumber(s))
        if n and n >= 0 and n < 16 then slots[#slots + 1] = n end
    end
    if #slots == 0 then
        DIR.reset(); CU.reset(); C = nil
        return "cleared"
    end
    local c = { slots = slots, holdTicks = 60 + #slots * 175 + 50, tick = G.tick, intro = 60, per = 175, outro = 50,
                status = "ok", at = G.now, test = true }
    C = c
    CU.begin(c, true)
    DIR.start(c, nil, "tour")
    return string.format("tour of %d worms, %d ticks", #slots, c.holdTicks)
end

U.log("sandtide " .. tostring(wum.mod and wum.mod.version) .. " client loaded")
