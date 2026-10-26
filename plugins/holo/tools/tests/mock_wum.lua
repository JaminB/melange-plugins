-- A fake `wum` for Holo's offline tests (plain Lua 5.4, run by tools/tests/run_tests.py with lua54_cli).
--
--   local MW = require("mock_wum")
--   local wum, mock = MW.new()          -- also wum._mock == mock
--   local env = MW.load("mod/client/init.lua", wum)   -- runs Holo in a sandbox-like environment
--   local ns = wum._holoTest.ns         -- the namespace tables (U, CFG, NET, ...) once the header ran
--
-- It fakes every namespace the Melange 0.12 docs list that Holo uses (log, events, timers, config, storage, ui.hotkey,
-- render, draw incl. hudNine/font/textSize/hudClip/media, input, media, peer, lobby, audio.music, game) with
-- recorders and knobs. This file is P0's and frozen: a test extends the mock in its own file (add fields to the
-- tables it returns), it never edits this one.
--
-- Time is virtual. mock.frame(dt) advances it, then delivers queued events (as the game does, at the next frame),
-- runs due timers, and runs the draw callbacks of the "hud" and "screen" stages, in that order.
--
-- Knobs and recorders on `mock`:
--   frame(dt)                 one frame of dt seconds (default 1/60)
--   frames(n, dt)             n frames
--   emit(name, payload)       queue an event for the next frame (like the engine); emitNow delivers at once
--   setTurn{index,team,worm,mine,ai,phase}   what wum.game.turn() returns (nil table = no turn); fires melange.turn
--   setUI{weaponPanel,pause,readyIntro,feCursor,attract}   wum.game.ui(); fires melange.ui on a change
--   setOnline(bool)           wum.game.online()
--   setLobby{...}|nil         wum.lobby.state(); fires melange.lobby.enter/leave/owner/members/phase on changes
--   setPeers{ids}             the ids a peer channel reports reachable (fires onPeer callbacks)
--   peerDeliver(from, tbl, meta)   a message arrives on the channel
--   peerSent                  array of {to=id|"*", tbl=, opts=} sent through the channel
--   drawCalls()               the draw calls of the last frame, {{fn="hudRect", args={...}}, ...}
--   gesture(true|false)       whether wum.media.install sees a fresh click (default false)
--   click(x, y, button)       press + release at x,y: hits the topmost region claimed in the last frame
--   hotkey(keys)              fire a registered hotkey
--   window                    {w, h}, what wum.render.windowSize() returns (default 1920x1080)
--   instructionCount          VM instructions the last mock.frame used (a debug hook, count 100)
--   logs                      array of {level, text}; logsOf(level)
--   now                       virtual seconds since new(); peerNow() in ms
--   players                   the media players opened, mock.torrents the torrents
--   music                     {requested, fade}: the last wum.audio.music.suppress request
--   storageData, configValues the backing tables

local M = {}

local ENV_GLOBALS = {"assert", "error", "ipairs", "next", "pairs", "pcall", "xpcall", "rawequal", "rawget", "rawlen",
  "rawset", "select", "tonumber", "tostring", "type", "getmetatable", "setmetatable", "_VERSION"}

-- The sandbox environment of the real game: base functions, string (no dump), table, math, utf8, coroutine and
-- three os functions. No load, require, io, debug.
function M.sandboxEnv(wum)
  local env = {}
  for _, k in ipairs(ENV_GLOBALS) do env[k] = _G[k] end
  env.string = setmetatable({dump = nil}, {__index = string})
  for k, v in pairs(string) do if k ~= "dump" then env.string[k] = v end end
  env.table, env.math, env.utf8, env.coroutine = table, math, utf8, coroutine
  env.os = {time = os.time, clock = os.clock, date = os.date}
  env.collectgarbage = function(opt, ...)
    assert(opt == nil or opt == "collect" or opt == "count" or opt == "step", "collectgarbage option")
    return collectgarbage(opt, ...)
  end
  env.print = function(...) wum.log.info(...) end
  env.wum = wum
  env._G = env
  return env
end

-- Loads a Lua file the way the game loads a mod entry: one chunk in a sandbox environment. Returns env, ok, err
-- (the chunk's own errors are returned, not raised).
function M.load(path, wum)
  local f = assert(io.open(path, "rb"))
  local src = f:read("a")
  f:close()
  assert(src:sub(1, 3) ~= "\239\187\191", "BOM in " .. path)
  local env = M.sandboxEnv(wum)
  local fn = assert(load(src, "@" .. path, "t", env))
  local ok, err = pcall(fn)
  return env, ok, err
end

local function deepcopy(v)
  if type(v) ~= "table" then return v end
  local t = {}
  for k, x in pairs(v) do t[k] = deepcopy(x) end
  return t
end
M.deepcopy = deepcopy

-- A small JSON reader, enough for spice.json (objects, arrays, strings, numbers, booleans, null).
local function jsonDecode(s)
  local pos = 1
  local function ws() pos = s:find("%S", pos) or #s + 1 end
  local value
  local function str()
    local out, i = {}, pos + 1
    while true do
      local c = s:sub(i, i)
      if c == '"' then pos = i + 1; return table.concat(out) end
      if c == "\\" then
        local n = s:sub(i + 1, i + 1)
        local map = {n = "\n", t = "\t", r = "\r", b = "\b", f = "\f"}
        if n == "u" then out[#out + 1] = utf8.char(tonumber(s:sub(i + 2, i + 5), 16)); i = i + 6
        else out[#out + 1] = map[n] or n; i = i + 2 end
      else out[#out + 1] = c; i = i + 1 end
    end
  end
  function value()
    ws()
    local c = s:sub(pos, pos)
    if c == "{" then
      local t = {}
      pos = pos + 1
      ws()
      if s:sub(pos, pos) == "}" then pos = pos + 1; return t end
      while true do
        ws()
        local k = str()
        ws(); assert(s:sub(pos, pos) == ":", "json: expected ':'"); pos = pos + 1
        t[k] = value()
        ws()
        local d = s:sub(pos, pos); pos = pos + 1
        if d == "}" then return t end
        assert(d == ",", "json: expected ','")
      end
    elseif c == "[" then
      local t = {}
      pos = pos + 1
      ws()
      if s:sub(pos, pos) == "]" then pos = pos + 1; return t end
      while true do
        t[#t + 1] = value()
        ws()
        local d = s:sub(pos, pos); pos = pos + 1
        if d == "]" then return t end
        assert(d == ",", "json: expected ','")
      end
    elseif c == '"' then return str()
    elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
    elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
    elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil
    else
      local num = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
      assert(num and #num > 0, "json: bad value at " .. pos)
      pos = pos + #num
      return math.tointeger(tonumber(num)) or tonumber(num)
    end
  end
  return value()
end
M.jsonDecode = jsonDecode

local function readFile(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end

-- Canonical-ish classify (the real one is C++): enough for tests of the typed-link flow.
local function classify(text)
  if type(text) ~= "string" then error("bad argument #1 to 'classify' (string expected)") end
  text = text:match("^%s*(.-)%s*$")
  if #text > 4096 then return nil, "unsupported-url" end
  local hash = text:match("^magnet:%?.*xt=urn:btih:(%x+)")
  if hash and #hash == 40 then
    local dn = text:match("[?&]dn=([^&]*)")
    return {kind = "magnet", infohash = hash:lower(), name = dn, url = "magnet:?xt=urn:btih:" .. hash:lower()}
  end
  local id = text:match("^https://www%.youtube%.com/watch%?v=([%w_-]+)") or text:match("^https://youtu%.be/([%w_-]+)")
  if id and #id == 11 then
    return {kind = "youtube", id = id, playlist = nil, live = false, url = "https://www.youtube.com/watch?v=" .. id}
  end
  local pl = text:match("^https://www%.youtube%.com/playlist%?list=([%w_-]+)")
  if pl then
    return {kind = "youtube", playlist = pl, live = false, url = "https://www.youtube.com/playlist?list=" .. pl}
  end
  return nil, "unsupported-url"
end

local function hotkeyValid(keys)
  if type(keys) ~= "string" then return false end
  if keys:match("^F%d+$") then return true end
  return keys:find("Ctrl", 1, true) or keys:find("Shift", 1, true) or keys:find("Alt", 1, true)
end

function M.new(opts)
  opts = opts or {}
  local mock = {now = 0, window = {1920, 1080}, logs = {}, peerSent = {}, players = {}, torrents = {},
    instructionCount = 0, music = {requested = false}, storageData = {}, configValues = {}, installs = 0}
  local wum = {_mock = mock}
  mock.wum = wum

  ---------------------------------------------------------------- log
  wum.log = {}
  for _, level in ipairs{"debug", "info", "warn", "error"} do
    wum.log[level] = function(...)
      local parts = table.pack(...)
      for i = 1, parts.n do parts[i] = tostring(parts[i]) end
      mock.logs[#mock.logs + 1] = {level, table.concat(parts, "\t", 1, parts.n)}
      if opts.echoLog then io.stderr:write("[" .. level .. "] " .. mock.logs[#mock.logs][2] .. "\n") end
    end
  end
  function mock.logsOf(level)
    local out = {}
    for _, l in ipairs(mock.logs) do if l[1] == level then out[#out + 1] = l[2] end end
    return out
  end

  ---------------------------------------------------------------- events
  local subs, queue, nextHandle = {}, {}, 0
  wum.events = {}
  function wum.events.on(name, fn)
    nextHandle = nextHandle + 1
    subs[#subs + 1] = {h = nextHandle, name = name, fn = fn}
    return nextHandle
  end
  function wum.events.off(h)
    for i, s in ipairs(subs) do
      if s.h == h then table.remove(subs, i); return true end
    end
    return false
  end
  local function deliver(name, payload)
    local copy = {}
    for i, s in ipairs(subs) do copy[i] = s end
    for _, s in ipairs(copy) do
      if s.name == name then s.fn(deepcopy(payload) or {}, name) end
    end
  end
  function wum.events.emit(name, t)
    if name:sub(1, 9) ~= "mod.holo." then name = "mod.holo." .. name end
    queue[#queue + 1] = {name, deepcopy(t)}
  end
  function mock.emit(name, payload) queue[#queue + 1] = {name, deepcopy(payload)} end
  function mock.emitNow(name, payload) deliver(name, payload) end

  ---------------------------------------------------------------- timers
  local timers = {}
  wum.timers = {}
  function wum.timers.after(sec, fn)
    nextHandle = nextHandle + 1
    timers[#timers + 1] = {h = nextHandle, due = mock.now + sec, fn = fn}
    return nextHandle
  end
  function wum.timers.every(sec, fn)
    nextHandle = nextHandle + 1
    timers[#timers + 1] = {h = nextHandle, due = mock.now + sec, every = sec, fn = fn}
    return nextHandle
  end
  function wum.timers.cancel(h)
    for i, t in ipairs(timers) do
      if t.h == h then table.remove(timers, i); return true end
    end
    return false
  end

  ---------------------------------------------------------------- config (defaults from mod/spice.json)
  local spice = readFile(opts.spice or "mod/spice.json")
  local declared = {}
  if spice then
    for _, s in ipairs(jsonDecode(spice).settings or {}) do declared[s.key] = s end
  end
  mock.declared = declared
  wum.config = {}
  function wum.config.get(key)
    local v = mock.configValues[key]
    if v ~= nil then return v end
    local d = declared[key]
    return d and d.default
  end
  function wum.config.set(key, value)
    local d = declared[key]
    if not d then error("unknown setting '" .. tostring(key) .. "'") end
    if d.type == "int" then
      assert(math.type(value) == "integer", "setting '" .. key .. "' needs an integer")
      assert((not d.min or value >= d.min) and (not d.max or value <= d.max), "setting '" .. key .. "' out of range")
    elseif d.type == "bool" then assert(type(value) == "boolean", "setting '" .. key .. "' needs a boolean")
    elseif d.type == "enum" then
      local ok = false
      for _, o in ipairs(d.options) do ok = ok or o == value end
      assert(ok, "setting '" .. key .. "': '" .. tostring(value) .. "' is not an option")
    end
    mock.configValues[key] = value
  end

  ---------------------------------------------------------------- storage
  wum.storage = {}
  function wum.storage.get(k) return deepcopy(mock.storageData[k]) end
  function wum.storage.set(k, v) mock.storageData[k] = deepcopy(v) end
  function wum.storage.remove(k) mock.storageData[k] = nil end
  function wum.storage.keys()
    local out = {}
    for k in pairs(mock.storageData) do out[#out + 1] = k end
    table.sort(out)
    return out
  end

  ---------------------------------------------------------------- ui (only what Holo uses)
  local hotkeys = {}
  wum.ui = {}
  function wum.ui.hotkey(keys, fn)
    if not hotkeyValid(keys) then error("hotkey '" .. tostring(keys) .. "' needs Ctrl, Shift or Alt") end
    if mock.hotkeyRefuse and mock.hotkeyRefuse[keys] then error("hotkey '" .. keys .. "' is taken") end
    nextHandle = nextHandle + 1
    hotkeys[#hotkeys + 1] = {h = nextHandle, keys = keys, fn = fn}
    return nextHandle
  end
  function wum.ui.remove(h)
    for i, hk in ipairs(hotkeys) do
      if hk.h == h then table.remove(hotkeys, i); return true end
    end
    return true
  end
  function wum.ui.panel(id, title, fn, open) nextHandle = nextHandle + 1; return nextHandle end
  function wum.ui.menu(path, fn, o) nextHandle = nextHandle + 1; return nextHandle end
  function mock.hotkey(keys)
    local n = 0
    for _, hk in ipairs({table.unpack(hotkeys)}) do
      if hk.keys == keys then hk.fn(); n = n + 1 end
    end
    return n
  end
  function mock.hotkeys()
    local out = {}
    for _, hk in ipairs(hotkeys) do out[#out + 1] = hk.keys end
    return out
  end

  ---------------------------------------------------------------- render + draw
  wum.render = {windowSize = function() return mock.window[1], mock.window[2] end}

  local drawOn = {hud = {}, screen = {}, world = {}, worldLate = {}}
  local calls, lastCalls = {}, {}
  local clipDepth = 0
  local nextTex, nextFont = 100, 0
  wum.draw = {}
  local function recorder(name, check)
    wum.draw[name] = function(...)
      if check then check(...) end
      calls[#calls + 1] = {fn = name, args = table.pack(...), clip = clipDepth}
      return true
    end
  end
  for _, n in ipairs{"hudRect", "hudLine", "hudText", "hudImage", "hudImageUV", "hudNine"} do recorder(n) end
  function wum.draw.texture(rel, o)
    if mock.missingTextures and mock.missingTextures[rel] then return nil, "missing file" end
    nextTex = nextTex + 1
    mock.textures = mock.textures or {}
    mock.textures[nextTex] = {rel = rel, opts = o}
    return nextTex
  end
  function wum.draw.font(png, json)
    nextFont = nextFont + 1
    if nextFont > 4 then return nil, "too many fonts" end
    mock.fonts = mock.fonts or {}
    mock.fonts[nextFont] = {png = png, json = json}
    return nextFont
  end
  -- Roughly 0.5 em per character, one line high.
  function wum.draw.textSize(text, size, o)
    return #tostring(text) * (size or 16) * 0.5, size or 16
  end
  function wum.draw.hudClip(x0, y0, x1, y1)
    assert(clipDepth < 4, "hudClip nests 4 deep")
    clipDepth = clipDepth + 1
    calls[#calls + 1] = {fn = "hudClip", args = table.pack(x0, y0, x1, y1), clip = clipDepth}
  end
  function wum.draw.hudClipEnd()
    if clipDepth > 0 then clipDepth = clipDepth - 1 end
    calls[#calls + 1] = {fn = "hudClipEnd", args = table.pack(), clip = clipDepth}
  end
  -- Draws a player: returns the contained picture rectangle, or nil with no frame (mock.hasFrame = false).
  function wum.draw.media(player, x0, y0, x1, y1, o)
    calls[#calls + 1] = {fn = "media", args = table.pack(player, x0, y0, x1, y1, o), clip = clipDepth}
    if mock.hasFrame == false then return nil end
    local st = player and player._st
    local aspect = st and st.aspect or 16 / 9
    local w, h = x1 - x0, y1 - y0
    local pw, ph = w, w / aspect
    if ph > h then pw, ph = h * aspect, h end
    local px, py = x0 + (w - pw) / 2, y0 + (h - ph) / 2
    return px, py, px + pw, py + ph
  end
  function wum.draw.on(stage, fn)
    assert(drawOn[stage], "unknown stage " .. tostring(stage))
    nextHandle = nextHandle + 1
    table.insert(drawOn[stage], {h = nextHandle, fn = fn})
    return nextHandle
  end
  function mock.drawCalls() return lastCalls end
  -- Helpers to look at the calls: mock.drawOf("hudText") -> list.
  function mock.drawOf(name)
    local out = {}
    for _, c in ipairs(lastCalls) do if c.fn == name then out[#out + 1] = c end end
    return out
  end

  ---------------------------------------------------------------- input
  local regions, lastRegions = {}, {}
  local pointerOn, focusOn = false, false
  mock.groups = {"InGame"}
  mock.cursorPos = {0, 0}
  wum.input = {}
  function wum.input.groups() return deepcopy(mock.groups) end
  function wum.input.binding(msg) return mock.bindings and mock.bindings[msg] end
  function wum.input.region(id, x0, y0, x1, y1, o)
    assert(type(id) == "string" and #id <= 64, "region id")
    if mock.regionBusy then return false, "busy" end
    regions[#regions + 1] = {id = id, x0 = x0, y0 = y0, x1 = x1, y1 = y1, opts = o}
    return true
  end
  function wum.input.hover()
    local x, y = mock.cursorPos[1], mock.cursorPos[2]
    for i = #lastRegions, 1, -1 do
      local r = lastRegions[i]
      if x >= r.x0 and x < r.x1 and y >= r.y0 and y < r.y1 then return r.id end
    end
  end
  function wum.input.cursor()
    if mock.cursorSource then return mock.cursorPos[1], mock.cursorPos[2], mock.cursorSource end
  end
  function wum.input.pointer(on, o)
    if on and mock.pointerUnavailable then return false, "unavailable" end
    pointerOn = on and true or false
    mock.pointerOpts = o
    return true
  end
  function wum.input.pointerActive() return pointerOn end
  function wum.input.focus(on) focusOn = on and true or false; return true end
  function wum.input.setOptions() return true end
  function mock.pointerActive() return pointerOn end
  function mock.focused() return focusOn end
  function mock.regions() return lastRegions end
  -- A click is a consent for 2 s (the real rule of wum.media.install).
  local gestureUntil = -1
  function mock.gesture(on) gestureUntil = on and mock.now + 2 or -1 end
  function mock.click(x, y, button)
    mock.cursorPos = {x, y}
    for i = #lastRegions, 1, -1 do
      local r = lastRegions[i]
      if x >= r.x0 and x < r.x1 and y >= r.y0 and y < r.y1 then
        gestureUntil = mock.now + 2
        deliver("melange.input.mouse", {region = r.id, button = button or "left", down = true, x = x, y = y})
        deliver("melange.input.mouse", {region = r.id, button = button or "left", down = false, x = x, y = y})
        return r.id
      end
    end
  end

  ---------------------------------------------------------------- media
  local pack = {state = "ready", version = "1", progress = 1, downloadMB = 95, diskMB = 300, ytdlp = "2026.10.01"}
  mock.pack = pack
  wum.media = {}
  function wum.media.available()
    if mock.mediaUnavailable then return false, mock.mediaUnavailable end
    return true
  end
  function wum.media.pack() return deepcopy(pack) end
  function wum.media.install()
    if pack.state == "ready" then return nil, "ready" end
    if not (gestureUntil >= mock.now) then return nil, "gesture" end
    pack.state = "downloading"; pack.progress = 0
    mock.installs = mock.installs + 1
    return true
  end
  function wum.media.cancelInstall() pack.state = "missing"; return true end
  wum.media.classify = classify
  local resolves = {}
  mock.resolves = resolves
  function wum.media.resolve(url, fn)
    resolves[#resolves + 1] = {url = url, fn = fn}
    return #resolves
  end
  -- Completes request n (default the last) with a result table.
  function mock.resolveDone(res, n)
    local r = resolves[n or #resolves]
    r.fn(res)
  end
  function wum.media.torrent(magnet, fn)
    local c = classify(magnet)
    if not c or c.kind ~= "magnet" then return nil, "unsupported-url" end
    local t = {magnet = magnet, fn = fn, closed = false}
    function t:files() return self._files end
    function t:status() return {down = 0, up = 0, peers = 0, progress = 0, have = 0, metadata = self._files ~= nil} end
    function t:close() self.closed = true end
    mock.torrents[#mock.torrents + 1] = t
    return t
  end
  function mock.torrentFiles(files, n)
    local t = mock.torrents[n or #mock.torrents]
    t._files = files
    if t.fn then t.fn({files = files, name = "test"}) end
  end
  function wum.media.open(o)
    if mock.openRefuse then return nil, mock.openRefuse end
    local p = {_st = {time = o.start or 0, duration = 0, paused = o.paused ~= false, buffering = false, speed = o.speed or 1,
      eof = false, w = 1280, h = 720, aspect = 16 / 9, tracks = {audio = {}, sub = {}}, helper = "ready"},
      opts = deepcopy(o), calls = {}, closed = false}
    local function rec(name, fn)
      p[name] = function(self, ...)
        if self.closed then return nil, "closed" end
        self.calls[#self.calls + 1] = {name, ...}
        if fn then fn(self, ...) end
        return true
      end
    end
    rec("play", function(self) self._st.paused = false end)
    rec("pause", function(self) self._st.paused = true end)
    rec("seek", function(self, t, mode)
      if mode == "relative" then self._st.time = self._st.time + t else self._st.time = t end
    end)
    rec("speed", function(self, x) self._st.speed = x end)
    rec("volume", function(self, v) self.vol = v end)
    rec("mute", function(self, b) self.muted = b end)
    rec("track")
    rec("quality")
    rec("size", function(self, w, h) self.sized = {w, h} end)
    rec("follow", function(self, st, host) self.following = st and deepcopy(st); self.followHost = host end)
    function p:state() return deepcopy(self._st) end
    function p:close() self.closed = true end
    mock.players[#mock.players + 1] = p
    return p
  end

  ---------------------------------------------------------------- lobby + peer
  local lobby
  wum.lobby = {}
  function wum.lobby.state() return deepcopy(lobby) end
  function wum.lobby.isHost() return lobby ~= nil and lobby.isHost == true end
  function mock.setLobby(new)
    local old = lobby
    lobby = deepcopy(new)
    if new then
      new.members = new.members or {}
      lobby.members = new.members and deepcopy(new.members)
      lobby.phase = lobby.phase or "lobby"
      lobby.isHost = lobby.isHost or false
    end
    if not old and lobby then mock.emit("melange.lobby.enter", {isHost = lobby.isHost})
    elseif old and not lobby then mock.emit("melange.lobby.leave", {})
    elseif old and lobby then
      if old.owner ~= lobby.owner then mock.emit("melange.lobby.owner", {owner = lobby.owner, isHost = lobby.isHost}) end
      if old.phase ~= lobby.phase then mock.emit("melange.lobby.phase", {phase = lobby.phase}) end
      if #old.members ~= #lobby.members then mock.emit("melange.lobby.members", {}) end
    end
  end

  local channel
  wum.peer = {}
  function wum.peer.now() return mock.now * 1000 end
  function mock.peerNow() return mock.now * 1000 end
  function wum.peer.open(o)
    if mock.peerUnavailable then return nil, "unavailable" end
    if channel then return nil, "busy" end
    assert(type(o) == "table" and math.type(o.version) == "integer", "wum.peer.open{version = n}")
    local ch = {version = o.version, handlers = {}, peerHandlers = {}, reachable = {}, presenceMine = nil,
      clocks = {}, presences = {}}
    local function send(id, tbl, so)
      mock.peerSent[#mock.peerSent + 1] = {to = id, tbl = deepcopy(tbl), opts = so}
      return true
    end
    function ch:send(id, tbl, so)
      local reach = false
      for _, r in ipairs(self.reachable) do reach = reach or r == id end
      if not reach then return false, "no-peer" end
      return send(id, tbl, so)
    end
    function ch:broadcast(tbl, so)
      for _, r in ipairs(self.reachable) do send(r, tbl, so) end
      return #self.reachable
    end
    function ch:on(fn) self.handlers[#self.handlers + 1] = fn end
    function ch:onPeer(fn) self.peerHandlers[#self.peerHandlers + 1] = fn end
    function ch:peers() return deepcopy(self.reachable) end
    function ch:clock(id) return deepcopy(self.clocks[id]) end
    function ch:setPresence(t) self.presenceMine = deepcopy(t) end
    function ch:presence(id) return deepcopy(self.presences[id]) end
    function ch:close() channel = nil end
    channel = ch
    mock.channel = ch
    return ch
  end
  function mock.setPeers(ids)
    local ch = assert(channel, "no channel open")
    local old, prev = {}, ch.reachable
    for _, id in ipairs(prev) do old[id] = true end
    ch.reachable = deepcopy(ids)
    local new = {}
    for _, id in ipairs(ids) do new[id] = true end
    for _, id in ipairs(ids) do
      if not old[id] then for _, h in ipairs(ch.peerHandlers) do h(id, true) end end
    end
    for _, id in ipairs(prev) do
      if not new[id] then for _, h in ipairs(ch.peerHandlers) do h(id, false) end end
    end
  end
  function mock.peerDeliver(from, tbl, meta)
    local ch = assert(channel, "no channel open")
    meta = meta or {}
    meta.at = meta.at or mock.now * 1000
    if meta.reliable == nil then meta.reliable = true end
    for _, h in ipairs(ch.handlers) do h(from, deepcopy(tbl), meta) end
  end

  ---------------------------------------------------------------- audio
  local suppressed = false
  wum.audio = {
    ready = function() return true end,
    load = function(rel) return 1 end,
    play = function() return 1 end,
    stop = function() return true end,
    stopAll = function() return 0 end,
    music = {
      available = function() return not mock.musicUnavailable end,
      suppress = function(on, o)
        if mock.musicUnavailable then return nil, "unavailable" end
        suppressed = on and true or false
        mock.music = {requested = suppressed, fade = o and o.fade}
        return true
      end,
      suppressed = function() return suppressed, suppressed end,
    },
  }

  ---------------------------------------------------------------- game
  local turn, ui, online = nil, {}, false
  wum.game = {}
  function wum.game.online() return online end
  function wum.game.turn() return deepcopy(turn) end
  function wum.game.ui()
    return {weaponPanel = ui.weaponPanel or false, pause = ui.pause or false, readyIntro = ui.readyIntro or false,
      feCursor = ui.feCursor or false, attract = ui.attract or false}
  end
  function mock.setOnline(b) online = b and true or false end
  function mock.setTurn(t)
    turn = deepcopy(t)
    if turn then
      turn.index = turn.index or 1
      turn.phase = turn.phase or "turn"
      mock.emit("melange.turn", {index = turn.index, team = turn.team, worm = turn.worm, mine = turn.mine or false,
        ai = turn.ai or false, online = online})
    end
  end
  function mock.setUI(t)
    local changed = false
    for k, v in pairs(t) do
      if ui[k] ~= v then changed = true end
      ui[k] = v
    end
    if changed then
      mock.emit("melange.ui", {weaponPanel = ui.weaponPanel or false, pause = ui.pause or false,
        readyIntro = ui.readyIntro or false})
    end
  end

  ---------------------------------------------------------------- the frame loop
  local frameCount = 0
  local function runDue()
    local due = {}
    for _, t in ipairs(timers) do if t.due <= mock.now + 1e-9 then due[#due + 1] = t end end
    for _, t in ipairs(due) do
      if t.every then t.due = t.due + math.max(t.every, 1e-9) else wum.timers.cancel(t.h) end
      t.fn()
    end
  end

  function mock.frame(dt)
    dt = dt or 1 / 60
    mock.now = mock.now + dt
    frameCount = frameCount + 1
    local count = 0
    debug.sethook(function() count = count + 100 end, "", 100)
    local ok, err = pcall(function()
      deliver("melange.frame", {frame = frameCount})
      local q = queue
      queue = {}
      for _, e in ipairs(q) do deliver(e[1], e[2]) end
      runDue()
      regions = {}
      calls, clipDepth = {}, 0
      for _, stage in ipairs{"hud", "screen"} do
        for _, d in ipairs({table.unpack(drawOn[stage])}) do d.fn(stage) end
      end
      lastCalls, lastRegions = calls, regions
    end)
    debug.sethook()
    mock.instructionCount = count
    if not ok then error(err, 0) end
  end

  function mock.frames(n, dt) for _ = 1, n do mock.frame(dt) end end

  return wum, mock
end

return M
