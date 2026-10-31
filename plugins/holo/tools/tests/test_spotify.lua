-- SPOT (src/46_spotify.lua): the adapter over wum.spotify (Melange 0.13), against the fake in fake_spotify.lua:
-- feature detection on an older Melange, the status cache, Link only from a click, the cap of 4 waiting requests, the
-- latency estimate, the play fallback to a listed device, and a text for every reason the contract names.
local MW = require("mock_wum")
local FS = require("fake_spotify")

local fails = 0
local function check(cond, what)
  if not cond then
    fails = fails + 1
    io.stderr:write("  FAIL: " .. what .. "\n")
  end
end

local function machine(withSpotify, opts)
  local wum, mock = MW.new()
  local fs = withSpotify and FS.install(wum, mock, opts) or nil
  wum._holoTest = {}
  local _, ok, err = MW.load("mod/client/init.lua", wum)
  check(ok, "init.lua runs: " .. tostring(err))
  mock.cursorSource = "frontend"
  mock.cursorPos = {2, 2}
  return {wum = wum, mock = mock, fs = fs, ns = wum._holoTest.ns}
end

local function regions(m)
  local out = {}
  for _, r in ipairs(m.mock.regions()) do out[r.id] = r end
  return out
end

local function clickRegion(m, id)
  local r = regions(m)[id]
  if not r then return nil end
  return m.mock.click((r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2)
end

local function texts(m)
  local out = {}
  for _, c in ipairs(m.mock.drawOf("hudText")) do out[#out + 1] = tostring(c.args[3]) end
  return table.concat(out, " ")       -- wrapped lines join back with a space
end

local function openMusicTab(m)
  m.ns.PARTY.setSetup(true)
  m.ns.SETUP.setTab("music")
  m.mock.frames(40)                      -- regions exist for more than half a second
end

-- 1. An older Melange (no wum.spotify): Holo runs, SPOT says why, the Music tab names the version.
do
  local m = machine(false)
  local SPOT = m.ns.SPOT
  check(SPOT.has() == false, "no wum.spotify")
  local ok, why = SPOT.available()
  check(ok == false and why == "old-melange", "available: old-melange")
  check(SPOT.status().state == "unavailable" and not SPOT.connected() and not SPOT.premium(), "status unavailable")
  check(SPOT.call("playback", function() end) == nil and select(2, SPOT.call("pause")) == "old-melange",
    "calls refused with old-melange")
  check(select(2, SPOT.connect()) == "old-melange", "connect: old-melange")
  openMusicTab(m)
  local t = texts(m)
  check(t:find("Melange 0.13.0 or later", 1, true) ~= nil, "the Music tab names Melange 0.13.0")
  check(t:find("Music queue (0)", 1, true) ~= nil, "the Music tab draws its queue")
  check(regions(m)["music.link"] == nil, "no Link button without wum.spotify")
  check(#m.mock.logsOf("error") == 0, "no errors: " .. table.concat(m.mock.logsOf("error"), "; "))
  -- the music lane still works for the host
  local MUSIC = m.ns.MUSIC
  check(MUSIC.add({FS.song(1)}) == 1 and MUSIC.toggle() and MUSIC.state().s == "play", "the lane runs without Spotify")
  m.mock.frames(10)
  check(#m.mock.logsOf("error") == 0, "still no errors")
end

-- 2. available() reasons and the status cache: the event updates it at the next frame, "spot.status" fires once.
do
  local m = machine(true, {why = "no-client-id"})
  local SPOT, U = m.ns.SPOT, m.ns.U
  local ok, why = SPOT.available()
  check(ok == false and why == "no-client-id", "available: no-client-id")
  check(SPOT.status().state == "unavailable" and SPOT.status().why == "no-client-id", "status unavailable, why kept")
  openMusicTab(m)
  check(texts(m):find("ClientId", 1, true) ~= nil, "the tab explains the Client ID")
  check(regions(m)["music.link"] == nil, "no Link button while unavailable")

  m.fs.why = nil
  m.mock.frames(130)                     -- the 2 s re-read
  check(SPOT.status().state == "disconnected", "re-read: disconnected")
  local seen = 0
  U.on("spot.status", function() seen = seen + 1 end)
  m.fs.link(true, "Bee")
  check(SPOT.status().state == "disconnected", "not before the event is delivered")
  m.mock.frame()
  local st = SPOT.status()
  check(st.state == "connected" and st.user == "Bee" and st.premium == true and st.linked == true, "connected, cached")
  check(SPOT.connected() and SPOT.premium(), "connected and premium")
  check(seen == 1, "spot.status once: " .. seen)
  m.mock.frames(130)
  check(seen == 1, "an unchanged re-read emits nothing")
  m.fs.setStatus{premium = false}
  m.mock.frame()
  check(SPOT.connected() and not SPOT.premium() and seen == 2, "a free account")
  m.fs.setStatus{state = "error", error = "revoked", linked = false}
  m.mock.frame()
  check(SPOT.status().state == "error" and SPOT.status().error == "revoked", "error state kept")
  openMusicTab(m)
  check(texts(m):find("Spotify signed Holo out", 1, true) ~= nil, "the error is explained")
end

-- 3. Link only from a click on Holo's Link button; the click is the consent.
do
  local m = machine(true)
  local SPOT = m.ns.SPOT
  local ok, why = SPOT.connect()
  check(ok == nil and why == "gesture", "connect without a click: gesture")
  check(SPOT.WHY.gesture == "Click Link Spotify again", "gesture text")
  check(m.fs.status.state == "disconnected", "no sign-in started")
  openMusicTab(m)
  local t = texts(m)
  check(t:find("Link your Spotify account", 1, true) ~= nil and t:find("Holo never sees it", 1, true) ~= nil,
    "the consent text shows")
  local r = regions(m)["music.link"]
  check(r ~= nil, "Link button")
  check(r and (r.x1 - r.x0) * (r.y1 - r.y0) <= 1920 * 1080 / 4, "the Link button is at most a quarter of the window")
  check(clickRegion(m, "music.link") == "music.link", "click Link")
  m.mock.frame()                         -- the control consumes the click and calls connect
  check(m.fs.connects == 2, "connect called from the click: " .. m.fs.connects)
  check(m.fs.status.state == "connecting", "the browser sign-in started")
  m.mock.frame()
  check(SPOT.status().state == "connecting", "status: connecting")
  m.mock.frame()
  check(texts(m):find("Finish signing in in your browser", 1, true) ~= nil, "connecting text")
  check(regions(m)["music.cancel"] ~= nil, "a Cancel button")
  -- connect after the click window has passed: refused again
  m.mock.frames(150)
  check(select(2, SPOT.connect()) ~= nil and m.fs.status.state == "connecting", "no second sign-in")
  clickRegion(m, "music.cancel")
  m.mock.frames(2)
  check(SPOT.status().state == "disconnected", "Cancel signs out")
  -- a linked account (another mod linked it): the button grants it at once
  m.fs.account = {user = "Bee", premium = true}
  m.fs.setStatus{linked = true}
  m.mock.frames(40)
  check(texts(m):find("Use my Spotify in Holo", 1, true) ~= nil, "linked: 'Use my Spotify in Holo'")
  clickRegion(m, "music.link")
  m.mock.frames(2)
  check(SPOT.connected() and SPOT.status().user == "Bee", "granted without the browser")
  m.mock.frames(2)
  check(regions(m)["music.browse"] ~= nil and regions(m)["music.unlink"] ~= nil, "connected: browse and unlink")
  check(texts(m):find("Spotify: Bee", 1, true) ~= nil and texts(m):find("Premium", 1, true) ~= nil, "who and Premium")
  -- a refused connect shows its reason
  m.fs.setStatus{state = "disconnected", linked = false}
  m.mock.frames(40)
  m.fs.connectWhy = "port-busy"
  clickRegion(m, "music.link")
  m.mock.frames(2)
  check(m.ns.MUI.status() == m.ns.SPOT.WHY["port-busy"], "port-busy explained: " .. tostring(m.ns.MUI.status()))
end

-- 4. At most 4 Holo requests wait at once; every answer frees one and feeds the latency estimate.
do
  local m = machine(true, {manual = true})
  local SPOT = m.ns.SPOT
  m.fs.link(true)
  m.mock.frame()
  check(SPOT.latency() == 400, "latency starts at 400 ms")
  local got = {}
  for i = 1, 2 do
    check(SPOT.library("tracks", nil, 0, function(res) got[#got + 1] = res end) ~= nil, "request " .. i)
  end
  -- library pages hold at most 2 of the 4, so play / pause / seek always have room (a lost pause = music left on)
  local lr, lwhy = SPOT.library("tracks", nil, 50, function() end)
  check(lr == nil and lwhy == "busy" and #m.fs.calls == 2, "a third library page is busy")
  m.ns.MUI.openLibrary()
  check(m.ns.MUI.library().err == "busy" and m.ns.MUI.WHY.busy ~= nil and not m.ns.MUI.WHY.busy:find("sign"),
    "a busy library says so, not 'a sign-in is open'")
  m.ns.MUI.closeLibrary()
  for i = 3, 4 do
    check(SPOT.devices(function(res) got[#got + 1] = res end) ~= nil, "request " .. i)
  end
  check(SPOT.inflight() == 4, "4 waiting")
  local rid, why = SPOT.playback(function() end)
  check(rid == nil and why == "busy", "the fifth is busy")
  check(#m.fs.calls == 4, "the fifth never reached Melange")
  m.mock.frames(60)                      -- 1 s round trip
  m.fs.answerNow(1)
  check(#got == 1 and type(got[1].items) == "table", "the answer arrives")
  check(SPOT.inflight() == 3, "one freed")
  check(SPOT.latency() > 400 and SPOT.latency() < 500, "latency EWMA: " .. SPOT.latency())
  check(SPOT.playback(function() end) ~= nil, "room again")
  -- library pages are 50
  check(m.fs.calls[1].args[1].limit == 50 and m.fs.calls[1].args[1].kind == "tracks", "library limit 50")
  -- a request Melange refuses (bad arguments) does not count
  local before = SPOT.inflight()
  for i = 2, 5 do m.fs.answerNow(i) end
  check(SPOT.inflight() == 0, "all answered")
  check(select(2, SPOT.call("seek", -5, nil)) == "invalid", "Melange's 'invalid' comes back")
  check(SPOT.inflight() == 0 and before == 4, "a refused request does not count")
  -- disconnect: waiting requests answer "auth"
  local res
  SPOT.playback(function(r) res = r end)
  SPOT.disconnect()
  m.mock.frames(2)
  check(res and res.error == "auth", "disconnect answers auth")
  check(SPOT.inflight() == 0, "and frees the slot")
end

-- 5. playTrack: "no-device" lists the devices, picks the active one, else a computer, remembers it, retries once.
do
  local m = machine(true)
  local SPOT, U = m.ns.SPOT, m.ns.U
  m.fs.link(true)
  m.mock.frame()
  local uri = FS.uri(7)
  -- no active device; a phone, a restricted speaker and a computer
  m.fs.devices = {
    {id = "ph", name = "Phone", type = "Smartphone", active = false, restricted = false},
    {id = "sp", name = "Speaker", type = "Speaker", active = false, restricted = true},
    {id = "pc", name = "PC", type = "Computer", active = false, restricted = false},
  }
  local res
  check(SPOT.playTrack(uri, 1234, function(r) res = r end) ~= nil, "play sent")
  m.mock.frames(20)
  check(res and res.ok == true, "played after the fallback: " .. tostring(res and res.error))
  local plays = m.fs.callsOf("play")
  check(#plays == 2 and plays[1].args[1].deviceId == nil and plays[2].args[1].deviceId == "pc", "retried on the computer")
  check(#m.fs.callsOf("devices") == 1, "devices listed once")
  check(plays[2].args[1].positionMs >= 1234 and plays[1].args[1].uri == uri, "the same track and position")
  check(U.pref("spotifyDevice") == "pc", "the device is remembered")
  -- the remembered device is gone: not-found, the pref is cleared, the active device is picked
  m.fs.devices = {
    {id = "pc2", name = "Laptop", type = "Computer", active = false, restricted = false},
    {id = "ph", name = "Phone", type = "Smartphone", active = true, restricted = false},
  }
  res = nil
  SPOT.playTrack(uri, 0, function(r) res = r end)
  m.mock.frames(20)
  plays = m.fs.callsOf("play")
  check(#plays == 4 and plays[3].args[1].deviceId == "pc" and plays[4].args[1].deviceId == "ph", "active one wins")
  check(res and res.ok and U.pref("spotifyDevice") == "ph", "remembered the phone")
  -- no device at all: one retry at most, then no-device
  m.fs.devices = {}
  U.setPref("spotifyDevice", nil)
  res = nil
  SPOT.playTrack(uri, 0, function(r) res = r end)
  m.mock.frames(20)
  check(res and res.error == "no-device", "no device: no-device")
  check(#m.fs.callsOf("play") == 5, "no retry without a device")
  -- not premium: no fallback
  m.fs.devices = {{id = "pc", name = "PC", type = "Computer", active = true}}
  m.fs.status.premium = false
  res = nil
  SPOT.playTrack(uri, 0, function(r) res = r end)
  m.mock.frames(20)
  check(res and res.error == "premium" and #m.fs.callsOf("devices") == 3, "premium: no device listing")
  check(SPOT.pickDevice({{id = "a", type = "Computer", restricted = true}, {id = "b", type = "TV"}}).id == "b",
    "pickDevice skips restricted devices")
end

-- 6. SPOT.WHY has a text for every reason in the contract.
do
  local m = machine(true)
  local WHY = m.ns.SPOT.WHY
  local reasons = {"old-melange", "disabled", "unavailable", "no-client-id", "gesture", "busy", "port-busy", "browser",
    "auth", "invalid", "premium", "no-device", "restricted", "not-found", "bad-request", "rate", "network", "timeout",
    "server", "bad-response", "denied", "invalid-client", "exchange", "revoked"}
  for _, r in ipairs(reasons) do
    check(type(WHY[r]) == "string" and #WHY[r] > 5, "SPOT.WHY[" .. r .. "]")
  end
  check(WHY["no-client-id"]:find("[Spotify] ClientId", 1, true) ~= nil, "no-client-id names the ini key")
  check(WHY["old-melange"]:find("0.13.0", 1, true) ~= nil, "old-melange names the version")
end

if fails > 0 then
  io.stderr:write(fails .. " check(s) failed\n")
  os.exit(1)
end
print("test_spotify: all checks passed")
