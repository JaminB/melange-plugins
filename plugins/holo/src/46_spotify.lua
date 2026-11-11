-- spotify (Holo 1.2): the adapter over Melange's wum.spotify. Nothing else in Holo indexes wum.spotify, and every
-- call goes through pcall, so on an older Melange (no wum.spotify) the music lane still relays and shows what the
-- party plays. Sign-in, tokens and the Web API are Melange's: Holo only sees the status, the library and the request
-- results. Playback is on the user's own Spotify device (Spotify Connect; Premium).
-- Melange 0.13 has the requests and connect / disconnect (the Client ID comes from Melange.ini). Melange 0.14 adds
-- the in-game setup surface: setup, setClientId, pasteClientId, copy, openDashboard, cancel and transfer ship
-- together, so SPOT.hasSetup() tests setup once and SPOT.hasTransfer() tests transfer.
-- Bus events: "spot.status" when the cached status changed, "spot.signedIn" (user) on a transition to connected,
-- "spot.devices" (the device model) when a device listing answered.
do
  SPOT.NEEDS = "0.13.0"
  local MAX_INFLIGHT = 4             -- Holo's own cap on waiting requests (Melange allows 8 per mod)
  local LIB_INFLIGHT = 2             -- library pages may hold at most this many, so play / pause / seek always fit
  local STALE = 30000                -- ms after which a request that never answered stops counting (Melange: 15 s)
  local LIMIT = 50

  SPOT.WHY = {
    gesture = "Click the button again",
    -- only reached on Melange 0.13: 0.14 sets the Client ID up in the game (the Music tab's setup card)
    ["no-client-id"] = "Add a Spotify Client ID to Melange.ini ([Spotify] ClientId), or update Melange to 0.14.1 to set "
      .. "Spotify up in the game",
    disabled = "Spotify is turned off in Melange.ini",
    unavailable = "Melange's Spotify module did not start; see Melange's log",
    busy = "A Spotify sign-in is already open in your browser",
    ["port-busy"] = "The sign-in port is in use: change [Spotify] RedirectPort and your app's Redirect URI",
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
    ["not-allowlisted"] = "This Spotify account is not allowed in this Spotify app",
    clipboard = "No Client ID on the clipboard: copy it from your app's Settings first",
    io = "Melange could not save the Client ID; see Melange's log",
  }

  local STATES = {disconnected = true, connecting = true, connected = true, error = true}
  local APPS = {user = true, ini = true, builtin = true}
  local status = {state = "unavailable"}
  local statusSig = "unavailable"
  local pending, npending = {}, 0    -- token -> sent at (U.now())
  local lat = 400                    -- EWMA of half the round trip, ms

  local function noop() end

  function SPOT.has() return wum.spotify ~= nil end
  -- Melange 0.14's in-game setup surface (setup, setClientId, pasteClientId, copy, openDashboard, cancel, transfer).
  function SPOT.hasSetup() return type(wum.spotify) == "table" and type(wum.spotify.setup) == "function" end
  function SPOT.hasTransfer() return type(wum.spotify) == "table" and type(wum.spotify.transfer) == "function" end

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
  -- error, why, app}; state "unavailable" (why = the available() reason) when Spotify cannot be used here. premium is
  -- true (Premium), false (Free) or nil (not known yet: Melange learns it from the first play; apps in Spotify's
  -- Development mode are no longer told the account type at sign-in). app (Melange 0.14) is the Client ID in use:
  -- "user" (set in the game), "ini" (Melange.ini) or "builtin" (the release's shared app), nil when there is none.
  local function clean(t)
    local app = type(t) == "table" and APPS[t.app] and t.app or nil
    local ok, why = SPOT.available()
    if not ok then return {state = "unavailable", why = why, linked = false, premium = false, app = app} end
    if type(t) ~= "table" or not STATES[t.state] then return {state = "disconnected", linked = false, premium = false} end
    local out = {state = t.state, linked = t.linked == true, premium = false, app = app}
    if t.state == "connected" then
      out.user = U.trim(t.user, 40)
      if t.premium == true or t.premium == false then out.premium = t.premium else out.premium = nil end
      out.linked = true
    elseif t.state == "error" then
      out.error = type(t.error) == "string" and U.trim(t.error, 24) or "exchange"
    end
    return out
  end

  local onConnected                  -- set below: what a transition to "connected" starts

  local function setStatus(st)
    local sig = st.state .. "|" .. tostring(st.user) .. "|" .. tostring(st.premium) .. "|" .. tostring(st.linked)
      .. "|" .. tostring(st.error) .. "|" .. tostring(st.why) .. "|" .. tostring(st.app)
    local prev = status
    status = st
    -- The shared app refused this account: remember it (the Music tab then offers the account's own app first, also
    -- after a restart). A sign-in that worked, or an app of the user's own, forgets it.
    if st.error == "not-allowlisted" and st.app == "builtin" then
      U.setPref("spotifyOwnApp", true)
    elseif st.state == "connected" or st.app == "user" or st.app == "ini" then
      U.setPref("spotifyOwnApp", nil)
    end
    if sig ~= statusSig then
      statusSig = sig
      U.emit("spot.status", st)
      if st.state == "connected" and prev.state ~= "connected" then onConnected(st)
      elseif st.state ~= "connected" and prev.state == "connected" then SPOT.forgetDevices() end
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
  -- Known Premium / known Free; an account that is neither is not known yet (it may play: the play tells).
  function SPOT.premium() return status.state == "connected" and status.premium == true end
  function SPOT.free() return status.state == "connected" and status.premium == false end
  function SPOT.mayPlay() return status.state == "connected" and status.premium ~= false end
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

  ---------------------------------------------------------------- the in-game setup (Melange 0.14)

  local SETUP_TTL = 1000             -- ms a setup() answer is reused (dropped on every status event and setClientId)
  local DEFAULT_URI = "http://127.0.0.1:8780/callback"
  local DASHBOARD = "https://developer.spotify.com/dashboard/create"
  local setupCache, setupAt = nil, -1e9

  function SPOT.dropSetup() setupCache = nil end

  -- A cleaned copy of wum.spotify.setup(), or nil (Melange 0.13 / 0.12, or the call failed): {app = "user" | "ini" |
  -- "builtin" | nil, appHint (the last 4 characters of the Client ID in use, or nil), builtin, ini (booleans),
  -- redirectUri (the URI to register in the user's own app), dashboardUrl}. The full Client ID is never given.
  function SPOT.setup()
    if not SPOT.hasSetup() then return nil end
    local now = U.now()
    if setupCache and now - setupAt < SETUP_TTL then return setupCache end
    local ok, t = pcall(wum.spotify.setup)
    if not ok or type(t) ~= "table" then
      setupCache = nil
      return nil
    end
    local app = APPS[t.app] and t.app or nil
    local hint = app and type(t.appHint) == "string" and U.trim(t.appHint, 4) or nil
    local uri = t.redirectUri
    if type(uri) ~= "string" or #uri > 100 or uri:sub(1, 17) ~= "http://127.0.0.1:" or uri:find("%s") then
      uri = DEFAULT_URI
    end
    setupCache = {app = app, appHint = hint ~= "" and hint or nil, builtin = t.builtin == true, ini = t.ini == true,
      redirectUri = uri, dashboardUrl = type(t.dashboardUrl) == "string" and U.trim(t.dashboardUrl, 200) or DASHBOARD}
    setupAt = now
    return setupCache
  end

  -- Calls one of the 0.14 functions that answer true / a value, or nil and a reason: the value, or nil and a reason
  -- ("old-melange" when the function is missing, "unavailable" when it raised). reread: the status may have changed.
  local function setupCall(name, reread, ...)
    local sp = wum.spotify
    local f = type(sp) == "table" and sp[name] or nil
    if type(f) ~= "function" then return nil, "old-melange" end
    local ok, r, why = pcall(f, ...)
    if reread then read() end
    if not ok then
      U.log("warn", "wum.spotify." .. name, r)
      return nil, "unavailable"
    end
    if r ~= nil and r ~= false then return r end
    return nil, type(why) == "string" and why or "unavailable"
  end

  -- Saves (id: a 32-character Client ID) or clears (nil) the Client ID set in the game. Needs a click (it does not
  -- use it up, so the same click may sign in next). true, or nil and a reason ("gesture", "invalid", "io", ...).
  function SPOT.setClientId(id)
    setupCache = nil
    local r, why = setupCall("setClientId", true, id)
    setupCache = nil
    return r, why
  end

  -- The Client ID on the clipboard (not saved), or nil and a reason ("gesture", "clipboard", ...). Needs a click.
  function SPOT.pasteClientId()
    local r, why = setupCall("pasteClientId", false)
    if r == nil then return nil, why end
    if type(r) ~= "string" or #r ~= 32 or not r:match("^%w+$") then return nil, "clipboard" end
    return r
  end

  -- Copies the Redirect URI to the clipboard (Melange writes its own fixed string). Needs a click.
  function SPOT.copyRedirect() return setupCall("copy", false, "redirectUri") end

  -- Opens Spotify's "Create app" page in the browser. Needs a click and uses it up.
  function SPOT.openDashboard() return setupCall("openDashboard", false) end

  -- Ends an open browser sign-in without signing anyone out (and clears an error). On Melange 0.13 there is no such
  -- call, so it signs out as Holo 1.1's Cancel did.
  function SPOT.cancel()
    local sp = wum.spotify
    if type(sp) == "table" and type(sp.cancel) == "function" then
      local ok, r = pcall(sp.cancel)
      read()
      return ok and r == true
    end
    return SPOT.disconnect()
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
      -- signed out (or Melange signed out an account the app does not allow): the status changed
      if res.error == "auth" or res.error == "not-allowlisted" then read() end
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

  -- Moves the user's playback to a Spotify Connect device (Melange 0.14). play = true starts it there; otherwise
  -- playing stays playing and paused stays paused. A request like play: the id, or nil and a reason.
  function SPOT.transfer(id, play, cb)
    if not SPOT.hasTransfer() then return nil, "old-melange" end
    return SPOT.call("transfer", {deviceId = id, play = play == true}, cb)
  end
  function SPOT.pause(cb) return SPOT.call("pause", cb) end
  function SPOT.seek(ms, cb) return SPOT.call("seek", math.max(0, math.floor(ms)), cb) end
  function SPOT.playback(cb) return SPOT.call("playback", cb) end

  -- The device to fall back to: the active one, else the first computer, else the first device. A restricted device
  -- takes no Web API commands, so it is never picked, active or not.
  function SPOT.pickDevice(items)
    if type(items) ~= "table" then return nil end
    local computer, any
    for _, d in ipairs(items) do
      if type(d) == "table" and type(d.id) == "string" and d.id ~= "" and d.restricted ~= true then
        if d.active == true then return d end
        if not computer and d.type == "Computer" then computer = d end
        any = any or d
      end
    end
    return computer or any
  end

  ---------------------------------------------------------------- devices

  local MAX_DEVICES = 20
  local KIND = {Computer = "computer", Smartphone = "phone", Tablet = "phone", Speaker = "speaker", AVR = "speaker",
    AudioDongle = "speaker", CastAudio = "speaker", TV = "tv", STB = "tv", CastVideo = "tv", GameConsole = "console",
    Automobile = "car"}
  local LABEL = {Computer = "Computer", Smartphone = "Phone", Tablet = "Tablet", Speaker = "Speaker", TV = "TV",
    AVR = "Receiver", STB = "TV box", AudioDongle = "Audio dongle", GameConsole = "Console", CastVideo = "Chromecast",
    CastAudio = "Cast speaker", Automobile = "Car"}

  -- The glyph family of a Spotify device type (SKIN.glyph), and its name for people.
  function SPOT.kindOf(t) return KIND[t] or "device" end
  function SPOT.typeLabel(t) return LABEL[t] or "Device" end

  -- The last device listing: {items = {{id, name, type, kind, label, active, restricted, private, volume}}, at (when it
  -- answered), loading, err (the reason of the last failed listing)}.
  local dev = {items = {}, at = 0, loading = false, err = nil, since = 0}
  function SPOT.deviceList() return dev end

  local function normDevices(list)
    local out = {}
    if type(list) ~= "table" then return out end
    for _, d in ipairs(list) do
      if #out >= MAX_DEVICES then break end
      if type(d) == "table" and type(d.id) == "string" and d.id ~= "" and #d.id <= 128 then
        local name = U.trim(d.name, 40)
        local t = type(d.type) == "string" and U.trim(d.type, 32) or "Unknown"
        out[#out + 1] = {id = d.id, name = name ~= "" and name or "Unnamed device", type = t, kind = SPOT.kindOf(t),
          label = SPOT.typeLabel(t), active = d.active == true, restricted = d.restricted == true,
          private = d.private == true, volume = U.num(d.volume)}
      end
    end
    return out
  end
  SPOT.normDevices = normDevices

  -- Lists the devices into the model; cb(dev) when the answer came (dev.err set on a failure). true while a listing
  -- is on its way (also an earlier one), false when it could not be sent (dev.err says why).
  function SPOT.refreshDevices(cb)
    if dev.loading and U.now() - dev.since < STALE then return true end
    dev.loading, dev.err, dev.since = true, nil, U.now()
    local rid, why = SPOT.devices(function(res)
      dev.loading = false
      if res.error then
        dev.err = res.error
      else
        dev.items = normDevices(res.items)
        dev.at = U.now()
      end
      U.emit("spot.devices", dev)
      if cb then cb(dev) end
    end)
    if not rid then dev.loading, dev.err = false, why end
    return rid ~= nil
  end

  function SPOT.forgetDevices()
    dev.items, dev.at, dev.err = {}, 0, nil
  end

  -- The device chosen for the party's music: id, name (prefs spotifyDevice and spotifyDeviceName), or nil.
  function SPOT.chosen()
    local id = U.pref("spotifyDevice")
    if type(id) ~= "string" or id == "" then return nil end
    local name = U.pref("spotifyDeviceName")
    return id, type(name) == "string" and name ~= "" and name or nil
  end

  -- Remembers a device ({id, name}), or forgets it (nil).
  function SPOT.choose(d)
    if type(d) ~= "table" or type(d.id) ~= "string" or d.id == "" then
      U.setPref("spotifyDevice", nil)
      U.setPref("spotifyDeviceName", nil)
      return
    end
    U.setPref("spotifyDevice", d.id)
    local name = U.trim(d.name, 40)
    U.setPref("spotifyDeviceName", name ~= "" and name or nil)
  end

  -- After a sign-in (Melange 0.14): list the devices, and when none is chosen yet and exactly one can take commands,
  -- remember it (nothing is moved). "spot.signedIn" tells the UI.
  onConnected = function(st)
    if SPOT.hasSetup() then
      SPOT.refreshDevices(function(d)
        if d.err or SPOT.chosen() ~= nil then return end
        local only, n = nil, 0
        for _, it in ipairs(d.items) do
          if not it.restricted then only, n = it, n + 1 end
        end
        if n == 1 then SPOT.choose(only) end
      end)
    end
    U.emit("spot.signedIn", st.user)
  end

  -- Plays a track at positionMs on the remembered device (pref spotifyDevice), or the active one. "no-device" (or a
  -- remembered device that is gone) lists the devices, picks one (the one with the remembered name, as Spotify may
  -- give a device a new id, else SPOT.pickDevice), remembers it and retries once,
  -- unless wanted() (optional) is false by then: cb then gets {error = "cancelled"} and nothing more is sent.
  -- The retry starts later in the song by the time the failed play and the listing took. Returns the first request
  -- id, or nil and a reason; cb gets the final result.
  function SPOT.playTrack(uri, positionMs, cb, wanted)
    cb = cb or noop
    local pos = math.max(0, math.floor(positionMs or 0))
    local sent = U.now()
    local pref, prefName = SPOT.chosen()
    return SPOT.call("play", {uri = uri, positionMs = pos, deviceId = pref}, function(res)
      if not (res.error == "no-device" or (res.error == "not-found" and pref)) then return cb(res) end
      if wanted and not wanted() then return cb({error = "cancelled"}) end
      if pref then U.setPref("spotifyDevice", nil) end
      local rid, why = SPOT.devices(function(d)
        if wanted and not wanted() then return cb({error = "cancelled"}) end
        if d.error then return cb(d) end
        local pick
        if prefName and type(d.items) == "table" then
          for _, x in ipairs(d.items) do
            if type(x) == "table" and type(x.id) == "string" and x.id ~= "" and x.restricted ~= true
              and U.trim(x.name, 40) == prefName then
              pick = x
              break
            end
          end
        end
        pick = pick or SPOT.pickDevice(d.items)
        if not pick then return cb({error = "no-device"}) end
        SPOT.choose(pick)
        local r2, why2 = SPOT.call("play", {uri = uri, positionMs = pos + math.floor(U.now() - sent),
          deviceId = pick.id}, cb)
        if not r2 then cb({error = why2}) end
      end)
      if not rid then cb({error = why}) end
    end)
  end

  ---------------------------------------------------------------- status: the event, and a 2 s re-read

  if wum.spotify then
    wum.events.on("melange.spotify", U.guard("spot.event", function(p)
      setupCache = nil                 -- the app may have changed (setClientId by any mod, an ini edit)
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
