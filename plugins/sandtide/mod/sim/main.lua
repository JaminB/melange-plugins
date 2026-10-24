-- Sandtide, the sim side (Lua 5.0, the match VM; no "#", no "%" operator). Runs identically on every peer.
--
-- The Sandworms rules, as the simulation sees them:
--   1. The sand line. Once the land bounds can be read (wum.sim.land()), the line is fixed for the whole match at
--      minY + LINE_FRACTION * (maxY - minY). It never moves, even when the land is blown away.
--   2. The hourglass. The strike is armed once STRIKE_MS of the round clock have elapsed (RoundTime minus
--      RoundTimeRemaining, the clock the game itself counts down to sudden death).
--   3. The curse. At the first GameLogic.Turn.Ended after the strike is armed, every alive worm whose feet are below
--      the line is anchored for the rest of the match (wum.sim.worm(slot):anchor()), and the next turn start is held
--      for INTRO + n * PER + OUTRO ticks so the clients can tour the cursed worms. It happens once per match.
--
-- Everything the sim decides here reads simulation state only (land bounds, the round clock, worm containers) at
-- fixed points (a 5-tick timer and the engine's own turn-end message), so every machine curses the same worms at the
-- same tick. The state lives in wum.sim.storage (aliased as the global SANDTIDE), which Wormsign hashes.
--
-- Messages to the clients (both sent with wum.sim.sendString; every peer's own sim sends them to its own client):
--
--   Sandtide.Line   "lineY|minY|maxY|strikeMs|roundMs|phase"
--       lineY, minY, maxY: world Y with 2 decimals. strikeMs, roundMs: integer ms of round clock. phase: 0 = the
--       hourglass is running, 1 = it is empty and the curse waits for the turn to end, 2 = the curse has struck.
--       Sent when the line is first known, whenever the phase changes, and at every turn start.
--
--   Sandtide.Curse  "slots|holdTicks|curseTick|intro,per,outro|status"
--       slots: the cursed worm slots, comma-separated, ordered by team, then position in team, then slot ("" when
--       none). holdTicks: the length of the turn-start hold in sim ticks (0 when there is none). curseTick: the sim
--       tick of the curse (the turn end; the hold itself starts at melange.turnHold). intro, per, outro: how the
--       hold's ticks split (the k-th worm, 0-based, is toured from intro + k * per to intro + (k + 1) * per).
--       status: "ok"; "spared" (no worm below the line, no hold); "nohold" (worms cursed, but holdTurn failed);
--       "unavailable" (Melange's WormAnchor is off or the game build is wrong: nobody is cursed).
--       Sent once at the curse, then again, identical, at every turn start (dedupe by curseTick; a copy that arrives
--       after curseTick + holdTicks means "show the final state, no tour").

-- ---------------------------------------------------------------- tuning (part of the content hash)
STRIKE_MS     = 180000  -- round clock elapsed when the hourglass empties
LINE_FRACTION = 0.25    -- the line's height above the lowest land, as a fraction of the land's height range
INTRO         = 60      -- hold ticks before the first worm (50 ticks = 1 s)
PER           = 175     -- hold ticks per cursed worm (3.5 s)
OUTRO         = 50      -- hold ticks after the last worm
HOLD_CAP      = 3000    -- wum.sim.holdTurn's hard cap (60 s)
POLL          = 5       -- ticks between round-clock reads

-- ---------------------------------------------------------------- state (hashed by Wormsign)
local S = wum.sim.storage
SANDTIDE = S
S.phase = 0        -- 0 running, 1 armed, 2 struck
S.line = nil       -- the sand line (world Y), nil until the land bounds are known
S.minY = nil
S.maxY = nil
S.roundMs = nil    -- RoundTime, read at the first poll
S.strikeMs = STRIKE_MS
S.cursed = {}      -- cursed slots, in tour order
S.holdTicks = 0
S.per = PER
S.curseTick = -1
S.status = ""
S.clockFallback = false

local function info(...) wum.log.info(unpack(arg)) end
local function warn(...) wum.log.warn(unpack(arg)) end

-- A data value as a number, or nil (getData answers nil and a reason; it raises only on a bad argument type).
local function readNumber(id)
    local ok, v = pcall(wum.sim.getData, id)
    if ok and type(v) == "number" then return v end
    return nil
end

-- Round clock elapsed in ms. The fallback (no RoundTimeRemaining) counts sim ticks since the match started: the same
-- on every machine, but it also runs between turns, so it strikes a little early; it is logged once.
local function elapsedMs()
    local total = S.roundMs
    local left = readNumber("RoundTimeRemaining")
    if total and left then return total - left end
    if not S.clockFallback then
        S.clockFallback = true
        warn("sandtide: the round clock cannot be read; timing the hourglass by sim ticks instead")
    end
    return wum.sim.tick() * 20
end

local function readRoundTime()
    if S.roundMs then return end
    local r = readNumber("RoundTime")
    if r and r > 0 then
        S.roundMs = math.floor(r)
    else
        S.roundMs = 300000
        warn("sandtide: RoundTime unreadable, assuming", S.roundMs)
    end
    -- A custom round shorter than the strike plus a turn would never strike: strike at 60 % of it instead.
    if S.roundMs < STRIKE_MS + 30000 then
        S.strikeMs = math.floor(S.roundMs * 0.6)
        warn("sandtide: RoundTime", S.roundMs, "is short; the hourglass empties at", S.strikeMs, "ms")
    end
end

-- Fixes the line once, from the land bounds. Returns true when the line is known.
local function computeLine()
    if S.line then return true end
    local ok, minX, minY, minZ, maxX, maxY, maxZ = pcall(wum.sim.land)
    if not ok or type(minY) ~= "number" or type(maxY) ~= "number" then return false end
    if maxY < minY then minY, maxY = maxY, minY end
    S.minY = minY
    S.maxY = maxY
    S.line = minY + LINE_FRACTION * (maxY - minY)
    info(string.format("sandtide: sand line at Y %.2f (land Y %.2f to %.2f)", S.line, minY, maxY))
    return true
end

local function send(name, value)
    local ok, why = wum.sim.sendString(name, value)
    if not ok then warn("sandtide:", name, "not sent:", why) end
end

local function sendLine()
    if not S.line then return end
    send("Sandtide.Line", string.format("%.2f|%.2f|%.2f|%d|%d|%d", S.line, S.minY, S.maxY, S.strikeMs,
        S.roundMs or 0, S.phase))
end

local function sendCurse()
    send("Sandtide.Curse", table.concat(S.cursed, ",") .. "|" .. string.format("%d|%d|%d,%d,%d|", S.holdTicks,
        S.curseTick, INTRO, S.per, OUTRO) .. S.status)
end

-- The worms below the line, alive, ordered by team, position in team, slot. Returns the list, or nil and a reason.
local function victims()
    local list = {}
    local slots, n = wum.sim.worms()
    if type(slots) ~= "table" then return nil, "unavailable" end
    for i = 1, (n or 0) do
        local slot = slots[i]
        local w, why = wum.sim.worm(slot)
        if not w and why == "unavailable" then return nil, "unavailable" end
        if w and w:alive() then
            local x, y, z = w:pos()
            if type(y) == "number" and y < S.line then
                local team, pos = w:team()
                table.insert(list, { slot = slot, team = team or 0, pos = pos or 0, w = w })
            end
        end
    end
    table.sort(list, function(a, b)
        if a.team ~= b.team then return a.team < b.team end
        if a.pos ~= b.pos then return a.pos < b.pos end
        return a.slot < b.slot
    end)
    return list
end

local function strike()
    S.phase = 2
    S.curseTick = wum.sim.tick()
    local list, why = victims()
    if not list then
        S.status = "unavailable"
        warn("sandtide: worms cannot be read (", why, "); the sands curse nobody")
        sendLine()
        sendCurse()
        return
    end
    for i = 1, table.getn(list) do
        local ok, err = list[i].w:anchor(true)
        if ok then
            table.insert(S.cursed, list[i].slot)
        else
            warn("sandtide: worm", list[i].slot, "not anchored:", err)
        end
    end
    local n = table.getn(S.cursed)
    if n == 0 then
        S.status = "spared"
        info("sandtide: the hourglass is empty; the sands spare every worm")
    else
        local per = PER
        if INTRO + n * per + OUTRO > HOLD_CAP then per = math.floor((HOLD_CAP - INTRO - OUTRO) / n) end
        S.per = per
        local ticks = INTRO + n * per + OUTRO
        local ok, err = wum.sim.holdTurn(ticks)
        if ok then
            S.holdTicks = ticks
            S.status = "ok"
        else
            S.status = "nohold"
            warn("sandtide: the turn start cannot be held:", err)
        end
        info("sandtide: the sands curse", n, "worms (", table.concat(S.cursed, ","), "), hold", S.holdTicks, "ticks")
    end
    sendLine()
    sendCurse()
end

-- ---------------------------------------------------------------- hooks
wum.sim.every(POLL, function()
    readRoundTime()
    if not S.line then
        if computeLine() then sendLine() end
    end
    if S.phase == 0 and elapsedMs() >= S.strikeMs then
        S.phase = 1
        info("sandtide: the hourglass is empty at", elapsedMs(), "ms; the curse strikes at the next turn end")
        sendLine()
    end
end)

wum.events.on("GameLogic.Turn.Ended", function()
    if S.phase == 2 then return end
    readRoundTime()
    if not computeLine() then return end
    if S.phase == 0 and elapsedMs() >= S.strikeMs then S.phase = 1 end
    if S.phase == 1 then strike() end
end)

-- Late or reloaded clients pick the state up at the next turn start.
wum.events.on("sim.turnStarted", function()
    sendLine()
    if S.phase == 2 then sendCurse() end
end)

wum.events.on("sim.turnHoldEnd", function(name, held)
    info("sandtide: the tour hold ended after", held, "ticks")
end)

info("sandtide", tostring(wum.mod.version), "sim loaded")
