-- spotify (Holo 1.1): the adapter over Melange 0.13's wum.spotify. Nothing else in Holo indexes wum.spotify, and
-- every call goes through pcall, so on an older Melange (no wum.spotify) the music lane still relays and shows what
-- the party plays. Sign-in, tokens and the Web API are Melange's: Holo only sees the status, the library and the
-- request results. Playback is on the user's own Spotify device (Spotify Connect; Premium).
-- Bus event: "spot.status" when the cached status changed.
do
  SPOT.NEEDS = "0.13.0"
  local MAX_INFLIGHT = 4             -- Holo's own cap on waiting requests (Melange allows 8 per mod)
  local LIB_INFLIGHT = 2             -- library pages may hold at most this many, so play / pause / seek always fit
  local STALE = 30000                -- ms after which a request that never answered stops counting (Melange: 15 s)
  local LIMIT = 50

  SPOT.WHY = {
    gesture = "Click Link Spotify again",
    ["no-client-id"] = "Add your Spotify app's Client ID to Melange.ini ([Spotify] ClientId); see Holo's README",
    disabled = "Spotify is turned off in Melange.ini",
    unavailable = "Melange's Spotify module did not start; see Melange's log",
    busy = "A Spotify sign-in is already open in your browser",
    ["port-busy"] = "Melange's Spotify sign-in port is in use: change [Spotify] RedirectPort and your app's Redirect URI",
    browser = "Could not open your browser",
    premium = "Playing needs Spotify Premium",
    ["no-device"] = "Open Spotify on this PC or your phone, then try again",
    rate = "Spotify asks to slow down; trying again soon",
    auth = "Spotify is not linked",
    ["old-melange"] = "Spotify music needs Melange 0.13.0 or later",
    invalid = "Spotify refused that request",
    restricted = "Your Spotify device refused that",
    ["not-found"] = "Spotify does not let apps read this playlist",
    ["bad-request"] = "Spotify refused that request",
    network = "Could not reach Spotify (network)",
    timeout = "Spotify did not answer in time",
    server = "Spotify had a problem; try again soon",
    ["bad-response"] = "Spotify sent an answer Holo could not read",
    denied = "You did not allow access",
    ["invalid-client"] = "Check [Spotify] ClientId and the app's Redirect URI",
    exchange = "The Spotify sign-in failed; try again",
    revoked = "Spotify signed Holo out; link again",
  }

  local STATES = {disconnected = true, connecting = true, connected = true, error = true}
  local status = {state = "unavailable"}
  local statusSig = "unavailable"
  local pending, npending = {}, 0    -- token -> sent at (U.now())
  local lat = 400                    -- EWMA of half the round trip, ms

  local function noop() end

  function SPOT.has() return wum.spotify ~= nil end

  -- true, or false and a reason: "old-melange" or one of wum.spotify.available()'s.
  function SPOT.available()
    local sp = wum.spotify
    if not sp then return false, "old-melange" end
    local ok, a, why = pcall(sp.available)
    if not ok then return false, "unavailable" end
    if a == true then return true end
    return false, type(why) == "string" and why or "unavailable"
  end

  -- Cleans a status table (wum.spotify.status() or the melange.spotify event) into {state, user, premium, linked,
  -- error, why}; state "unavailable" (why = the available() reason) when Spotify cannot be used here.
  local function clean(t)
    local ok, why = SPOT.available()
    if not ok then return {state = "unavailable", why = why, linked = false, premium = false} end
    if type(t) ~= "table" or not STATES[t.state] then return {state = "disconnected", linked = false, premium = false} end
    local out = {state = t.state, linked = t.linked == true, premium = false}
    if t.state == "connected" then
      out.user = U.trim(t.user, 40)
      out.premium = t.premium == true
      out.linked = true
    elseif t.state == "error" then
      out.error = type(t.error) == "string" and U.trim(t.error, 24) or "exchange"
    end
    return out
  end

  local function setStatus(st)
    local sig = st.state .. "|" .. tostring(st.user) .. "|" .. tostring(st.premium) .. "|" .. tostring(st.linked)
      .. "|" .. tostring(st.error) .. "|" .. tostring(st.why)
    status = st
    if sig ~= statusSig then
      statusSig = sig
      U.emit("spot.status", st)
    end
  end

  local function read()
    local sp = wum.spotify
    local t
    if sp then
      local ok, v = pcall(sp.status)
      t = ok and v or nil
    end
    setStatus(clean(t))
  end
  SPOT.refresh = read

  function SPOT.status() return status end
  function SPOT.connected() return status.state == "connected" end
  function SPOT.premium() return status.state == "connected" and status.premium == true end
  function SPOT.latency() return lat end
  function SPOT.inflight() return npending end

  -- Links Spotify for Holo. Call it ONLY from a click handler: Melange opens the sign-in page only within 2 s of a
  -- click on one of Holo's regions. true, or nil and a reason (SPOT.WHY).
  function SPOT.connect()
    local sp = wum.spotify
    if not sp then return nil, "old-melange" end
    local ok, r, why = pcall(sp.connect)
    read()
    if not ok then return nil, "unavailable" end
    if r then return true end
    return nil, type(why) == "string" and why or "unavailable"
  end

  -- Signs Melange out of Spotify (every mod). It does not stop the music.
  function SPOT.disconnect()
    local sp = wum.spotify
    if not sp then return nil, "old-melange" end
    local ok, r = pcall(sp.disconnect)
    read()
    return ok and r == true or nil
  end

  -- Calls wum.spotify[name](...) under pcall. The last argument is the callback slot (nil is fine): it is always
  -- passed, wrapped, so every request answers once and counts against the cap. Returns the request id, or nil and a
  -- reason ("old-melange", "busy" with 4 requests waiting (2 for library pages), "invalid", or Melange's).
  function SPOT.call(name, ...)
    local sp = wum.spotify
    if not sp then return nil, "old-melange" end
    local f = sp[name]
    if type(f) ~= "function" then return nil, "old-melange" end
    if npending >= MAX_INFLIGHT or (name == "library" and npending >= LIB_INFLIGHT) then return nil, "busy" end
    local args = table.pack(...)
    if args.n == 0 then args.n = 1 end
    local cb = args[args.n]
    if type(cb) ~= "function" then cb = noop end
    local token = {}
    local sent = U.now()
    args[args.n] = U.guard("spot." .. name, function(res)
      if pending[token] then
        pending[token] = nil
        npending = npending - 1
        local half = (U.now() - sent) / 2
        lat = U.clamp(lat * 0.7 + half * 0.3, 150, 1500)
      end
      if type(res) ~= "table" then res = {error = "bad-response"} end
      if res.error == "auth" then read() end
      cb(res)
    end)
    pending[token] = sent
    npending = npending + 1
    local ok, rid, why = pcall(f, table.unpack(args, 1, args.n))
    if ok and rid then return rid end
    if pending[token] then
      pending[token] = nil
      npending = npending - 1
    end
    if not ok then
      U.log("warn", "wum.spotify." .. name, rid)
      return nil, "invalid"
    end
    return nil, type(why) == "string" and why or "unavailable"
  end

  -- kind "tracks" | "playlists" | "playlist" (id = a 22-character playlist id); 50 per page.
  function SPOT.library(kind, id, offset, cb)
    return SPOT.call("library", {kind = kind, id = id, offset = math.max(0, math.floor(offset or 0)), limit = LIMIT}, cb)
  end

  function SPOT.devices(cb) return SPOT.call("devices", cb) end
  function SPOT.pause(cb) return SPOT.call("pause", cb) end
  function SPOT.seek(ms, cb) return SPOT.call("seek", math.max(0, math.floor(ms)), cb) end
  function SPOT.playback(cb) return SPOT.call("playback", cb) end

  -- The device to fall back to: the active one, else the first usable computer, else the first usable device.
  function SPOT.pickDevice(items)
    if type(items) ~= "table" then return nil end
    local computer, any
    for _, d in ipairs(items) do
      if type(d) == "table" and type(d.id) == "string" and d.id ~= "" then
        if d.active == true then return d end
        if d.restricted ~= true then
          if not computer and d.type == "Computer" then computer = d end
          any = any or d
        end
      end
    end
    return computer or any
  end

  -- Plays a track at positionMs on the remembered device (pref spotifyDevice), or the active one. "no-device" (or a
  -- remembered device that is gone) lists the devices, picks one (SPOT.pickDevice), remembers it and retries once.
  -- Returns the first request id, or nil and a reason; cb gets the final result.
  function SPOT.playTrack(uri, positionMs, cb)
    cb = cb or noop
    local pos = math.max(0, math.floor(positionMs or 0))
    local pref = U.pref("spotifyDevice")
    if type(pref) ~= "string" or pref == "" then pref = nil end
    return SPOT.call("play", {uri = uri, positionMs = pos, deviceId = pref}, function(res)
      if not (res.error == "no-device" or (res.error == "not-found" and pref)) then return cb(res) end
      if pref then U.setPref("spotifyDevice", nil) end
      local rid, why = SPOT.devices(function(d)
        if d.error then return cb(d) end
        local dev = SPOT.pickDevice(d.items)
        if not dev then return cb({error = "no-device"}) end
        U.setPref("spotifyDevice", dev.id)
        local r2, why2 = SPOT.call("play", {uri = uri, positionMs = pos + math.floor(SPOT.latency()),
          deviceId = dev.id}, cb)
        if not r2 then cb({error = why2}) end
      end)
      if not rid then cb({error = why}) end
    end)
  end

  ---------------------------------------------------------------- status: the event, and a 2 s re-read

  if wum.spotify then
    wum.events.on("melange.spotify", U.guard("spot.event", function(p)
      if type(p) == "table" and (p.type == nil or p.type == "status") then setStatus(clean(p)) end
    end))
    wum.timers.every(2, U.guard("spot.poll", function()
      read()
      local now = U.now()
      for token, at in pairs(pending) do
        if now - at > STALE then
          pending[token] = nil
          npending = npending - 1
        end
      end
    end))
  end
  read()
end
