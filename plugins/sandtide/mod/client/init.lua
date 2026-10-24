-- Sandtide, the client side (Lua 5.4). A stub: it parses the sim's two messages and logs them. The hourglass HUD,
-- the sand line band, the camera tour and the petrify effects replace this file.
--
-- Sandtide.Line   p.value = "lineY|minY|maxY|strikeMs|roundMs|phase"   (phase 0 running, 1 empty, 2 struck)
-- Sandtide.Curse  p.value = "slots|holdTicks|curseTick|intro,per,outro|status"
-- See mod/sim/main.lua for the exact meaning of every field.

local function log(...)
    if wum.log and wum.log.info then wum.log.info(...) end
end

local function split(s, sep)
    local out = {}
    for part in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do out[#out + 1] = part end
    return out
end

local function parseLine(v)
    local f = split(v, "|")
    return {
        line = tonumber(f[1]), minY = tonumber(f[2]), maxY = tonumber(f[3]),
        strikeMs = tonumber(f[4]), roundMs = tonumber(f[5]), phase = tonumber(f[6]),
    }
end

local function parseCurse(v)
    local f = split(v, "|")
    local slots = {}
    if f[1] and f[1] ~= "" then
        for _, s in ipairs(split(f[1], ",")) do slots[#slots + 1] = tonumber(s) end
    end
    local t = split(f[4] or "0,0,0", ",")
    return {
        slots = slots, holdTicks = tonumber(f[2]) or 0, tick = tonumber(f[3]) or -1,
        intro = tonumber(t[1]) or 0, per = tonumber(t[2]) or 0, outro = tonumber(t[3]) or 0,
        status = f[5] or "",
    }
end

local function on(name, fn)
    if not (wum.events and wum.events.on) then return end
    pcall(wum.events.on, name, function(p)
        local ok, err = pcall(fn, p)
        if not ok then log("sandtide: " .. name .. ": " .. tostring(err)) end
    end)
end

on("Sandtide.Line", function(p)
    local l = parseLine(tostring(p and p.value or ""))
    log(("sandtide: line %.2f, strike at %d ms, phase %d"):format(l.line or 0, l.strikeMs or 0, l.phase or -1))
end)

on("Sandtide.Curse", function(p)
    local c = parseCurse(tostring(p and p.value or ""))
    log(("sandtide: curse at tick %d, %d worms, hold %d ticks, %s"):format(c.tick, #c.slots, c.holdTicks, c.status))
end)
