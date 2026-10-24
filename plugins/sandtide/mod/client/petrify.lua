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
