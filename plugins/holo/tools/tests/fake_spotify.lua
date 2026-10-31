-- A fake wum.spotify (Melange 0.13, docs/lua-api.md "wum.spotify") for Holo's tests. mock_wum.lua stays frozen: this
-- helper extends a mock the documented way (it adds wum.spotify and wraps mock.click), before Holo loads.
--
--   local MW, FS = require("mock_wum"), require("fake_spotify")
--   local wum, mock = MW.new()
--   local fs = FS.install(wum, mock)     -- BEFORE MW.load
--   MW.load("mod/client/init.lua", wum)
--
-- What it fakes, as the contract says:
--   available() / status() / connect() (needs a click on one of the mod's regions, at most a quarter of the window,
--   in the last 2 s: mock.click is wrapped to record it) / disconnect() (cancels waiting requests with
--   {error = "auth"}), and the requests library, devices, play, pause, resume, seek, volume, playback: argument types
--   raise, "auth" / "busy" (8 waiting) / "invalid" come back as nil, reason, and callbacks run later, on a mock timer
--   (fs.delay seconds, default 0.05), never inside the call.
--   A simulated Spotify Connect device answers by default: play starts the track on the given or active device (not
--   Premium -> "premium", no device -> "no-device", an unknown deviceId -> "not-found"), pause/seek/resume act on it
--   and playback reports it ({active, playing, uri, positionMs, at, device}). Tests steer it through the fields
--   below.
--
-- The returned fs:
--   calls                     every request {i, name, args (copied, no function), fn, rid, answered, res}
--   callsOf(name)             the calls of one function
--   respond[name] = fn(call)  a custom answer (return nil to fall back to the simulated device)
--   default(call)             the simulated device's answer
--   manual = true             nothing answers by itself; use answer / answerNow
--   answer(i, res)            answers call i at the next frame (res nil = the default answer); answerNow(i, res) at once
--   setStatus(t)              changes the status fields and queues "melange.spotify" (delivered at the next frame)
--   link(premium, user)       a finished sign-in: connected, linked, premium, user; queues the event
--   account                   {user, premium}: who a sign-in (or a grant of a linked account) connects as
--   gesture(on)               pretend a click happened (or clear it)
--   why                       set to make available() return false, why
--   connectWhy                makes connect() return nil, connectWhy (e.g. "port-busy")
--   devices                   the Connect devices {{id, name, type, active, restricted, volume}}
--   player                    the simulated playback {uri, pos, at, playing, device} or nil
--   library[key]              songs/playlists by key: "tracks", "playlists", "playlist:<id>"
--   connects                  how many times connect() was called
local MW = require("mock_wum")
local deepcopy = MW.deepcopy

local FS = {}

-- A Spotify track URI for a number: "spotify:track:" and 22 base-62 characters.
function FS.uri(n) return "spotify:track:" .. string.format("%022d", n) end

-- A library song row as wum.spotify.library returns it.
function FS.song(n, o)
  o = o or {}
  return {uri = FS.uri(n), name = o.name or ("Song " .. n), artists = o.artists or ("Artist " .. n),
    album = "Album", durationMs = o.durationMs or 600000, playable = o.playable ~= false}
end

function FS.install(wum, mock, opts)
  opts = opts or {}
  local fs = {calls = {}, respond = {}, delay = opts.delay or 0.05, manual = opts.manual == true, why = opts.why,
    connectWhy = nil, connects = 0, gestureUntil = -1, player = nil, library = {}, nextRid = 0,
    account = {user = "Listener", premium = true},
    status = {state = "disconnected", linked = false},
    devices = {{id = "pc1", name = "DESKTOP", type = "Computer", active = true, restricted = false, volume = 60}}}
  local waiting = 0

  local function nowMs() return mock.now * 1000 end

  local function event()
    local p = deepcopy(fs.status)
    p.type = "status"
    mock.emit("melange.spotify", p)
  end

  function fs.setStatus(t)
    for k, v in pairs(t) do fs.status[k] = v end
    if fs.status.state ~= "connected" then fs.status.user, fs.status.premium = nil, nil end
    if fs.status.state ~= "error" then fs.status.error = nil end
    event()
  end

  function fs.link(premium, user)
    fs.account = {user = user or fs.account.user, premium = premium ~= false}
    fs.setStatus{state = "connected", linked = true, premium = fs.account.premium, user = fs.account.user}
  end

  function fs.gesture(on) fs.gestureUntil = on and mock.now + 2 or -1 end

  -- the click rule: a press and release in one of the mod's regions covering at most a quarter of the window
  local click = mock.click
  function mock.click(x, y, button)
    local before = mock.regions()
    local id = click(x, y, button)
    if id then
      for i = #before, 1, -1 do
        local r = before[i]
        if r.id == id then
          local area = (r.x1 - r.x0) * (r.y1 - r.y0)
          if area <= mock.window[1] * mock.window[2] / 4 then fs.gestureUntil = mock.now + 2 end
          break
        end
      end
    end
    return id
  end

  function fs.callsOf(name)
    local out = {}
    for _, c in ipairs(fs.calls) do if c.name == name then out[#out + 1] = c end end
    return out
  end

  ---------------------------------------------------------------- the simulated device

  local function activeDevice()
    for _, d in ipairs(fs.devices) do if d.active then return d end end
  end
  local function findDevice(id)
    for _, d in ipairs(fs.devices) do if d.id == id then return d end end
  end
  local function position()
    local p = fs.player
    if not p then return 0 end
    if p.playing then return p.pos + (nowMs() - p.at) end
    return p.pos
  end
  fs.position = position

  local SIM = {}
  function SIM.play(c)
    local o = c.args[1]
    if fs.status.premium ~= true then return {error = "premium", message = "Premium required"} end
    local dev
    if o.deviceId then
      dev = findDevice(o.deviceId)
      if not dev then return {error = "not-found", message = "Device not found"} end
    else
      dev = activeDevice()
      if not dev then return {error = "no-device", message = "No active device"} end
    end
    for _, d in ipairs(fs.devices) do d.active = d == dev end
    fs.player = {uri = o.uri or (o.uris and o.uris[1]) or o.context, pos = o.positionMs or 0, at = nowMs(),
      playing = true, device = dev}
    return {ok = true}
  end
  function SIM.pause()
    if not fs.player or not activeDevice() then return {error = "no-device"} end
    fs.player.pos, fs.player.at, fs.player.playing = position(), nowMs(), false
    return {ok = true}
  end
  function SIM.resume()
    if not fs.player or not activeDevice() then return {error = "no-device"} end
    fs.player.pos, fs.player.at, fs.player.playing = position(), nowMs(), true
    return {ok = true}
  end
  function SIM.seek(c)
    if not fs.player or not activeDevice() then return {error = "no-device"} end
    fs.player.pos, fs.player.at = c.args[1], nowMs()
    return {ok = true}
  end
  function SIM.volume(c)
    local d = activeDevice()
    if not d then return {error = "no-device"} end
    if d.restricted or d.type == "Smartphone" then return {error = "restricted"} end
    d.volume = c.args[1]
    return {ok = true}
  end
  function SIM.playback()
    local p, d = fs.player, activeDevice()
    if not p or not d then return {active = false} end
    return {active = true, playing = p.playing, uri = p.uri, name = "Song", artists = "Artist", durationMs = 600000,
      positionMs = math.floor(position()), at = nowMs(), device = {id = d.id, name = d.name, type = d.type,
      volume = d.volume}}
  end
  function SIM.devices() return {items = deepcopy(fs.devices)} end
  function SIM.library(c)
    local o = c.args[1]
    local key = o.kind == "playlist" and ("playlist:" .. o.id) or o.kind
    local list = fs.library[key]
    if list == nil and o.kind == "playlist" then return {error = "not-found"} end
    list = list or {}
    local offset, limit = o.offset or 0, o.limit or 50
    local items = {}
    for i = offset + 1, math.min(#list, offset + limit) do items[#items + 1] = deepcopy(list[i]) end
    return {kind = o.kind, items = items, offset = offset, limit = limit, total = #list, next = offset + limit < #list,
      skipped = 0}
  end

  function fs.default(c) return SIM[c.name](c) end

  function fs.answerNow(i, res)
    local c = fs.calls[i]
    assert(c, "no call " .. tostring(i))
    if c.answered then return end
    c.answered = true
    waiting = waiting - 1
    if res == nil then
      local custom = fs.respond[c.name]
      if custom then res = custom(c) end
      if res == nil then res = fs.default(c) end
    end
    c.res = deepcopy(res)
    if c.fn then c.fn(deepcopy(res)) end
  end

  function fs.answer(i, res)
    wum.timers.after(0, function() fs.answerNow(i, res) end)
  end

  ---------------------------------------------------------------- the API

  local function available()
    if fs.why then return false, fs.why end
    return true
  end

  local function request(name, args, fn)
    local ok, why = available()
    if not ok then return nil, why end
    if fs.status.state ~= "connected" then return nil, "auth" end
    if waiting >= 8 then return nil, "busy" end
    waiting = waiting + 1
    fs.nextRid = fs.nextRid + 1
    local c = {i = #fs.calls + 1, name = name, args = deepcopy(args), fn = fn, rid = fs.nextRid, answered = false}
    fs.calls[c.i] = c
    if not fs.manual then wum.timers.after(fs.delay, function() fs.answerNow(c.i) end) end
    return c.rid
  end

  local function optFn(fn, n, name)
    if fn ~= nil and type(fn) ~= "function" then
      error("bad argument #" .. n .. " to '" .. name .. "' (function expected)")
    end
  end

  local function isInt(v, lo, hi)
    return math.type(v) == "integer" and v >= lo and (not hi or v <= hi)
  end

  local function trackUri(u) return type(u) == "string" and #u == 36 and u:match("^spotify:track:[0-9A-Za-z]+$") end

  local sp = {}
  function sp.available() return available() end
  function sp.status()
    local ok, why = available()
    if not ok then return {state = "disconnected", linked = false} end
    return deepcopy(fs.status)
  end
  function sp.connect()
    fs.connects = fs.connects + 1
    local ok, why = available()
    if not ok then return nil, why end
    if not (fs.gestureUntil >= mock.now) then return nil, "gesture" end
    if fs.connectWhy then return nil, fs.connectWhy end
    if fs.status.state == "connected" then return true end
    if fs.status.state == "connecting" then return nil, "busy" end
    if fs.status.linked then
      fs.setStatus{state = "connected", premium = fs.account.premium, user = fs.account.user}
    else
      fs.setStatus{state = "connecting"}
    end
    return true
  end
  function sp.disconnect()
    for _, c in ipairs(fs.calls) do
      if not c.answered then
        c.answered = true
        waiting = waiting - 1
        if c.fn then
          local fn = c.fn
          wum.timers.after(0, function() fn({error = "auth", message = "signed out"}) end)
        end
      end
    end
    fs.setStatus{state = "disconnected", linked = false}
    return true
  end
  function sp.library(o, fn)
    if type(o) ~= "table" then error("bad argument #1 to 'library' (table expected)") end
    if type(fn) ~= "function" then error("bad argument #2 to 'library' (function expected)") end
    local kinds = {tracks = true, playlists = true, playlist = true}
    if not kinds[o.kind] then return nil, "invalid" end
    if o.kind == "playlist" and not (type(o.id) == "string" and #o.id == 22) then return nil, "invalid" end
    if o.offset ~= nil and not isInt(o.offset, 0) then return nil, "invalid" end
    if o.limit ~= nil and not isInt(o.limit, 1, 50) then return nil, "invalid" end
    return request("library", {o}, fn)
  end
  function sp.devices(fn)
    if type(fn) ~= "function" then error("bad argument #1 to 'devices' (function expected)") end
    return request("devices", {}, fn)
  end
  function sp.play(o, fn)
    if type(o) ~= "table" then error("bad argument #1 to 'play' (table expected)") end
    optFn(fn, 2, "play")
    local n = (o.uri ~= nil and 1 or 0) + (o.uris ~= nil and 1 or 0) + (o.context ~= nil and 1 or 0)
    if n ~= 1 then return nil, "invalid" end
    if o.uri ~= nil and not trackUri(o.uri) then return nil, "invalid" end
    if o.positionMs ~= nil and not isInt(o.positionMs, 0) then return nil, "invalid" end
    if o.deviceId ~= nil and type(o.deviceId) ~= "string" then return nil, "invalid" end
    return request("play", {o}, fn)
  end
  function sp.pause(fn)
    optFn(fn, 1, "pause")
    return request("pause", {}, fn)
  end
  function sp.resume(fn)
    optFn(fn, 1, "resume")
    return request("resume", {}, fn)
  end
  function sp.seek(ms, fn)
    if type(ms) ~= "number" then error("bad argument #1 to 'seek' (number expected)") end
    optFn(fn, 2, "seek")
    if not isInt(ms, 0) then return nil, "invalid" end
    return request("seek", {ms}, fn)
  end
  function sp.volume(pct, fn)
    if type(pct) ~= "number" then error("bad argument #1 to 'volume' (number expected)") end
    optFn(fn, 2, "volume")
    if not isInt(pct, 0, 100) then return nil, "invalid" end
    return request("volume", {pct}, fn)
  end
  function sp.playback(fn)
    if type(fn) ~= "function" then error("bad argument #1 to 'playback' (function expected)") end
    return request("playback", {}, fn)
  end

  wum.spotify = sp
  fs.api = sp
  mock.spotify = fs
  return fs
end

return FS
