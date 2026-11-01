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
--   Premium -> "premium", no device -> "no-device", an unknown deviceId -> "not-found", a restricted device ->
--   "restricted"), pause/seek/resume act on it and playback reports it ({active, playing, uri, positionMs, at,
--   device}, and linkedFrom for a relinked track).
--   Tests steer it through the fields below.
--   premium in the status is true, false or nil (not known: a Development-mode app is not told at sign-in). Like
--   Melange, the fake learns it from the answers to control requests (play, pause, resume, seek, volume): one that
--   went through -> true, "premium" -> false, each change queued as a "melange.spotify" status event.
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
--   premiumUnknown = true     sign-ins report premium = nil (the account type is learnt from the first control call)
--   relink[uri] = uri2        Spotify relinks a track for this account's market: plays uri2, reports linkedFrom = uri
--   gesture(on)               pretend a click happened (or clear it)
--   why                       set to make available() return false, why
--   connectWhy                makes connect() return nil, connectWhy (e.g. "port-busy")
--   devices                   the Connect devices {{id, name, type, active, restricted, volume}}
--   player                    the simulated playback {uri, pos, at, playing, device} or nil
--   library[key]              songs/playlists by key: "tracks", "playlists", "playlist:<id>"
--   connects                  how many times connect() was called
--   disconnects               how many times disconnect() was called
--
-- Melange 0.14 (FS.install(wum, mock, {api = "0.14", builtin = true, app = "builtin" | "user" | "ini" | nil,
-- ini = false, clipboard = "<text>"})) adds the in-game setup surface of the contract:
--   setup()                   {app, appHint (last 4 of fs.clientId, or "abcd"), builtin, ini, redirectUri, dashboardUrl}
--   status() and the events   carry app; available() says "no-client-id" while app is nil
--   setClientId(id)           a non-string non-nil raises; no click -> nil, "gesture" (not used up); trimmed, not 32
--                             letters and digits -> nil, "invalid"; records fs.clientIds (false for a clear); sets
--                             fs.app "user" (a clear: back to "ini", "builtin" or nil); a changed app cancels a
--                             sign-in and signs out (disconnected, not linked); an error is cleared
--   pasteClientId()           needs a click; the Client ID found in fs.clipboard by the contract's rule, or
--                             nil, "clipboard"
--   copy(what)                a non-string raises; not "redirectUri" -> nil, "invalid"; needs a click;
--                             fs.copies += 1, fs.clipboard = the URI
--   openDashboard()           needs a click and uses it up; fs.dashboards += 1 (fs.dashboardWhy makes it fail)
--   cancel()                  fs.cancels += 1; connecting -> disconnected (or connected when linked), true; otherwise
--                             clears an error, false
--   connect()                 uses the click up; while connecting re-opens the page: fs.reopens += 1, true
--   transfer(opts, fn)        types raise like play; a control request: an unknown id -> "not-found", a restricted
--                             device -> "restricted", Free -> "premium"; moves fs.player to the device (play = true
--                             starts it) and marks the device active
--   devices                   items carry private (false unless set)
--   notAllowlisted()          the account is not on the app's list: error "not-allowlisted", not linked
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
  local CONTROL = {play = true, pause = true, resume = true, seek = true, volume = true, transfer = true}
  local v14 = opts.api == "0.14"
  local fs = {calls = {}, respond = {}, delay = opts.delay or 0.05, manual = opts.manual == true, why = opts.why,
    relink = {}, premiumUnknown = false, v14 = v14,
    connectWhy = nil, connects = 0, disconnects = 0, gestureUntil = -1, player = nil, library = {}, nextRid = 0,
    builtin = opts.builtin ~= false and v14, ini = opts.ini == true, app = opts.app, clipboard = opts.clipboard,
    clientId = opts.clientId, clientIds = {}, copies = 0, dashboards = 0, cancels = 0, reopens = 0,
    redirectUri = "http://127.0.0.1:8780/callback",
    account = {user = "Listener", premium = true},
    status = {state = "disconnected", linked = false},
    devices = {{id = "pc1", name = "DESKTOP", type = "Computer", active = true, restricted = false, volume = 60}}}
  local waiting = 0

  local function nowMs() return mock.now * 1000 end

  local function event()
    local p = deepcopy(fs.status)
    p.type = "status"
    if v14 then p.app = fs.app end
    mock.emit("melange.spotify", p)
  end

  function fs.setStatus(t)
    for k, v in pairs(t) do fs.status[k] = v end
    if fs.status.state ~= "connected" then fs.status.user, fs.status.premium = nil, nil end
    if fs.status.state ~= "error" then fs.status.error = nil end
    event()
  end

  local function shownPremium()
    if fs.premiumUnknown then return nil end
    return fs.account.premium
  end

  function fs.link(premium, user)
    fs.account = {user = user or fs.account.user, premium = premium ~= false}
    fs.status.premium = nil
    fs.setStatus{state = "connected", linked = true, user = fs.account.user, premium = shownPremium()}
  end

  -- Premium as Spotify sees it: the status when known, else the account's.
  local function isPremium()
    if fs.status.premium ~= nil then return fs.status.premium == true end
    return fs.account.premium == true
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
    if not isPremium() then return {error = "premium", message = "Premium required"} end
    local dev
    if o.deviceId then
      dev = findDevice(o.deviceId)
      if not dev then return {error = "not-found", message = "Device not found"} end
    else
      dev = activeDevice()
      if not dev then return {error = "no-device", message = "No active device"} end
    end
    if dev.restricted then return {error = "restricted", message = "Device is restricted"} end
    for _, d in ipairs(fs.devices) do d.active = d == dev end
    local uri = o.uri or (o.uris and o.uris[1]) or o.context
    local linked = fs.relink[uri]
    fs.player = {uri = linked or uri, linkedFrom = linked and uri or nil, pos = o.positionMs or 0, at = nowMs(),
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
      volume = d.volume}, linkedFrom = p.linkedFrom}
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

  function fs.default(c)
    if CONTROL[c.name] and not isPremium() then return {error = "premium", message = "Premium required"} end
    return SIM[c.name](c)
  end

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
    -- Melange learns the account type from control results and tells the mods when it changed
    if CONTROL[c.name] and fs.status.state == "connected" then
      local learnt
      if res.error == nil then learnt = true elseif res.error == "premium" then learnt = false end
      if learnt ~= nil and fs.status.premium ~= learnt then fs.setStatus{premium = learnt} end
    end
    if c.fn then c.fn(deepcopy(res)) end
  end

  function fs.answer(i, res)
    wum.timers.after(0, function() fs.answerNow(i, res) end)
  end

  ---------------------------------------------------------------- the API

  local function available()
    if fs.why then return false, fs.why end
    if v14 and fs.app == nil then return false, "no-client-id" end
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
    local t = ok and deepcopy(fs.status) or {state = "disconnected", linked = false}
    if v14 then t.app = fs.app end
    return t
  end
  function sp.connect()
    fs.connects = fs.connects + 1
    local ok, why = available()
    if not ok then return nil, why end
    if not (fs.gestureUntil >= mock.now) then return nil, "gesture" end
    if fs.connectWhy then return nil, fs.connectWhy end
    if v14 then fs.gestureUntil = -1 end                 -- 0.14: connect uses the click up
    if fs.status.state == "connected" then return true end
    if fs.status.state == "connecting" then
      if not v14 then return nil, "busy" end
      fs.reopens = fs.reopens + 1                        -- this mod's own sign-in: the page opens again
      return true
    end
    if fs.status.linked then
      fs.setStatus{state = "connected", premium = fs.account.premium, user = fs.account.user}
    else
      fs.setStatus{state = "connecting"}
    end
    return true
  end
  function sp.disconnect()
    fs.disconnects = fs.disconnects + 1
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

  ---------------------------------------------------------------- Melange 0.14: the in-game setup

  local function clicked() return fs.gestureUntil >= mock.now end
  local function trimAscii(t) return (t:gsub("^[ \t\r\n\v\f]+", ""):gsub("[ \t\r\n\v\f]+$", "")) end
  local function isId(t) return #t == 32 and t:match("^[0-9A-Za-z]+$") ~= nil end

  -- The contract's rule: the trimmed text is an ID, or the text holds exactly one maximal run of 32 letters / digits.
  function FS.findClientId(text)
    if type(text) ~= "string" then return nil end
    local t = trimAscii(text)
    if isId(t) then return t end
    local found, n = nil, 0
    for run in text:gmatch("[0-9A-Za-z]+") do
      if #run == 32 then found, n = run, n + 1 end
    end
    if n == 1 then return found end
    return nil
  end

  function fs.notAllowlisted()
    fs.setStatus{state = "error", error = "not-allowlisted", linked = false}
  end

  if v14 then
    fs.clientId = fs.clientId or (fs.app and "0123456789abcdef0123456789ab" .. "abcd" or nil)

    function sp.setup()
      return {app = fs.app, appHint = fs.app and (fs.clientId and fs.clientId:sub(-4) or "abcd") or nil,
        builtin = fs.builtin, ini = fs.ini, redirectUri = fs.redirectUri,
        dashboardUrl = "https://developer.spotify.com/dashboard/create"}
    end

    function sp.setClientId(id)
      if id ~= nil and type(id) ~= "string" then error("wum.spotify.setClientId: id must be a string or nil") end
      if fs.why then return nil, fs.why end
      if not clicked() then return nil, "gesture" end
      local t = id and trimAscii(id) or ""
      if t ~= "" and (#id > 1024 or not isId(t)) then return nil, "invalid" end
      if fs.setClientIdWhy then return nil, fs.setClientIdWhy end
      local before = tostring(fs.app) .. ":" .. tostring(fs.clientId)
      if t == "" then
        fs.clientIds[#fs.clientIds + 1] = false
        fs.app = fs.ini and "ini" or (fs.builtin and "builtin" or nil)
        fs.clientId = fs.app and ("fedcba9876543210fedcba98765432" .. (fs.app == "ini" and "in" or "bt")) or nil
      else
        fs.clientIds[#fs.clientIds + 1] = t
        fs.app, fs.clientId = "user", t
      end
      local after = tostring(fs.app) .. ":" .. tostring(fs.clientId)
      if before ~= after and (fs.status.state ~= "disconnected" or fs.status.linked) then
        fs.setStatus{state = "disconnected", linked = false}
      elseif fs.status.state == "error" then
        fs.setStatus{state = "disconnected"}
      else
        event()
      end
      return true
    end

    function sp.pasteClientId()
      if fs.why then return nil, fs.why end
      if not clicked() then return nil, "gesture" end
      local id = FS.findClientId(fs.clipboard)
      if not id then return nil, "clipboard" end
      return id
    end

    function sp.copy(what)
      if type(what) ~= "string" then error("bad argument #1 to 'copy' (string expected)") end
      if fs.why then return nil, fs.why end
      if what ~= "redirectUri" then return nil, "invalid" end
      if not clicked() then return nil, "gesture" end
      fs.copies = fs.copies + 1
      fs.clipboard = fs.redirectUri
      return true
    end

    function sp.openDashboard()
      if fs.why then return nil, fs.why end
      if not clicked() then return nil, "gesture" end
      fs.gestureUntil = -1
      if fs.dashboardWhy then return nil, fs.dashboardWhy end
      fs.dashboards = fs.dashboards + 1
      return true
    end

    function sp.cancel()
      fs.cancels = fs.cancels + 1
      if fs.status.state == "connecting" then
        if fs.status.linked then
          fs.setStatus{state = "connected", premium = fs.account.premium, user = fs.account.user}
        else
          fs.setStatus{state = "disconnected"}
        end
        return true
      end
      if fs.status.state == "error" then fs.setStatus{state = "disconnected"} end
      return false
    end

    function sp.transfer(o, fn)
      if type(o) ~= "table" then error("bad argument #1 to 'transfer' (table expected)") end
      if o.deviceId ~= nil and type(o.deviceId) ~= "string" then
        error("bad argument #1 to 'transfer' (deviceId must be a string)")
      end
      if o.play ~= nil and type(o.play) ~= "boolean" then
        error("bad argument #1 to 'transfer' (play must be a boolean)")
      end
      optFn(fn, 2, "transfer")
      if o.deviceId == nil or #o.deviceId > 128 or not o.deviceId:match("^[0-9A-Za-z_%-]+$") then
        return nil, "invalid"
      end
      return request("transfer", {o}, fn)
    end

    function SIM.transfer(c)
      local o = c.args[1]
      local dev = findDevice(o.deviceId)
      if not dev then return {error = "not-found", message = "Device not found"} end
      if dev.restricted then return {error = "restricted", message = "Device is restricted"} end
      for _, d in ipairs(fs.devices) do d.active = d == dev end
      if fs.player then
        fs.player.pos, fs.player.at = position(), nowMs()
        fs.player.device = dev
        if o.play == true then fs.player.playing = true end
      end
      return {ok = true}
    end

    local listDevices = SIM.devices
    function SIM.devices(c)
      local res = listDevices(c)
      for _, d in ipairs(res.items) do if d.private == nil then d.private = false end end
      return res
    end
  end

  wum.spotify = sp
  fs.api = sp
  mock.spotify = fs
  return fs
end

return FS
