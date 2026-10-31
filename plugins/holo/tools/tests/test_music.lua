-- MUSIC (src/47_music.lua) and its UI (src/87_music_ui.lua): the party's Spotify music lane between mocked machines,
-- each with the fake wum.spotify of fake_spotify.lua: member adds, the host's clock and every listener following it
-- on their own device, drift correction, the user taking over, what stops the music and (above all) what does not,
-- the video interplay, game-music suppression, validation, mixed versions, free accounts and the frame cost.
local MW = require("mock_wum")
local FS = require("fake_spotify")

local fails = 0
local function check(cond, what)
  if not cond then
    fails = fails + 1
    io.stderr:write("  FAIL: " .. what .. "\n")
  end
end

local VID1 = "https://youtu.be/vid00000001"

-- spotify: nil (not linked), "premium" or "free"
local function machine(id, spotify)
  local wum, mock = MW.new()
  local fs = FS.install(wum, mock)
  if spotify then
    fs.account = {user = "U" .. id, premium = spotify == "premium"}
    fs.status = {state = "connected", linked = true, user = "U" .. id, premium = spotify == "premium"}
  end
  wum._holoTest = {}
  local _, ok, err = MW.load("mod/client/init.lua", wum)
  check(ok, id .. ": init.lua runs: " .. tostring(err))
  local m = {id = id, wum = wum, mock = mock, fs = fs, ns = wum._holoTest.ns, sent = 0, events = {}}
  for _, name in ipairs{"party.toast", "music.addResult", "music.detached"} do
    m.ns.U.on(name, function(a, b, c) m.events[#m.events + 1] = {name, a, b, c} end)
  end
  return m
end

local function lastEvent(m, name)
  for i = #m.events, 1, -1 do
    if m.events[i][1] == name then return m.events[i] end
  end
end

local function lobby(ms, owner, phase)
  local members = {}
  for _, m in ipairs(ms) do members[#members + 1] = {id = m.id, name = "N" .. m.id, peer = true} end
  for _, m in ipairs(ms) do
    local mem = MW.deepcopy(members)
    for _, x in ipairs(mem) do
      x.me = x.id == m.id
      x.host = x.id == owner
    end
    m.mock.setLobby{lobby = "L", me = m.id, owner = owner, isHost = m.id == owner, phase = phase or "lobby",
      members = mem}
  end
end

local function connect(ms)
  for _, m in ipairs(ms) do
    local others = {}
    for _, o in ipairs(ms) do if o ~= m then others[#others + 1] = o.id end end
    m.mock.setPeers(others)
    for _, o in ipairs(ms) do
      if o ~= m then m.mock.channel.clocks[o.id] = {offset = 0, rtt = 20, samples = 5} end
    end
  end
end

local function step(ms, n, filter)
  for _ = 1, n or 1 do
    for _, m in ipairs(ms) do m.mock.frame() end
    for _, m in ipairs(ms) do
      for _, o in ipairs(ms) do
        if o ~= m and m.mock.channel then o.mock.channel.presences[m.id] = MW.deepcopy(m.mock.channel.presenceMine) end
      end
    end
    for _, m in ipairs(ms) do
      while m.sent < #m.mock.peerSent do
        m.sent = m.sent + 1
        local r = m.mock.peerSent[m.sent]
        for _, o in ipairs(ms) do
          if o.id == r.to and o.mock.channel and (not filter or filter(m, o, r.tbl)) then
            o.mock.peerDeliver(m.id, MW.deepcopy(r.tbl), {reliable = not (r.opts and r.opts.reliable == false)})
          end
        end
      end
    end
  end
end

local function sentOf(m, t, to)
  local out = {}
  for _, r in ipairs(m.mock.peerSent) do
    if r.tbl.t == t and (not to or r.to == to) then out[#out + 1] = r end
  end
  return out
end

local function songs(from, to, o)
  local out = {}
  for n = from, to do out[#out + 1] = FS.song(n, o) end
  return out
end

local function count(m, name) return #m.fs.callsOf(name) end

local function lastPlay(m)
  local p = m.fs.callsOf("play")
  return p[#p]
end

-- A lobby owned by A with members; every machine said hi and has the caps.
local function party(specs)
  local ms = {}
  for _, s in ipairs(specs) do ms[#ms + 1] = machine(s[1], s[2]) end
  lobby(ms, ms[1].id)
  connect(ms)
  step(ms, 10)
  return ms
end

local function errors(ms)
  local out = {}
  for _, m in ipairs(ms) do
    for _, e in ipairs(m.mock.logsOf("error")) do out[#out + 1] = m.id .. ": " .. e end
  end
  return out
end

-- 0. The lane never listens to the video party's end, the layout or the setup panel (dismissing is not stopping).
do
  local f = assert(io.open("src/47_music.lua", "rb"))
  local src = f:read("a")
  f:close()
  check(not src:find('U.on("party.', 1, true) or src:find('U.on("party.memberHi"', 1, true), "music: only memberHi")
  for _, bad in ipairs{'U.on("party.changed"', 'U.on("layout.', "LAYOUT.", "setupOpen", "PARTY.stop", "PARTY.setSetup"} do
    check(not src:find(bad, 1, true), "47_music.lua does not use " .. bad)
  end
  check(not src:find("wum.spotify", 1, true), "47_music.lua never indexes wum.spotify")
  local f2 = assert(io.open("mod/client/init.lua", "rb"))
  local all = f2:read("a")
  f2:close()
  local n = 0
  for _ in all:gmatch("wum%.spotify") do n = n + 1 end
  local f3 = assert(io.open("src/46_spotify.lua", "rb"))
  local spot = f3:read("a")
  f3:close()
  local k = 0
  for _ in spot:gmatch("wum%.spotify") do k = k + 1 end
  check(n == k, "wum.spotify appears only in 46_spotify.lua (" .. n .. " vs " .. k .. ")")
end

-- 1-3. Host A without Spotify; B linked with Premium adds three songs from the library; A plays them; B follows on
-- its own device; drift is corrected, at most once per 8 s.
do
  local ms = party{{"A"}, {"B", "premium"}}
  local A, B = ms[1], ms[2]
  local caps = B.ns.PARTY.hostCaps()
  check(caps and caps.music == true and caps.madd == true, "B has A's caps (music, madd)")
  check(B.ns.MUSIC.canAdd() and B.ns.MUSIC.addWhyNot() == nil, "B may add music without a video party")
  check(not A.ns.SPOT.connected() and B.ns.SPOT.premium(), "A has no Spotify, B has Premium")

  -- (1) B adds three songs
  local ok, why = B.ns.MUSIC.add(songs(1, 3))
  check(ok == true and why == "sent", "B's add is sent")
  check(select(2, B.ns.MUSIC.add(songs(4, 4))) == "rate", "one add per second")
  step(ms, 40)
  local items = A.ns.MUSIC.items()
  check(#items == 3 and items[1].by == "NB" and items[1].byId == "B" and items[3].uri == FS.uri(3), "A's queue has them")
  check(#sentOf(B, "madd", "A") == 1 and #sentOf(B, "madd")[1].tbl.items == 3, "one madd with 3 items")
  local r = lastEvent(B, "music.addResult")
  check(r and r[2] == true and r[4] == 3, "B: added 3")
  check(lastEvent(A, "party.toast") and lastEvent(A, "party.toast")[2] == "NB added 3 songs", "host toast")
  check(B.ns.MUSIC.count() == 3 and B.ns.MUSIC.items()[2].by == "NB", "the mq pages reach B")
  check(count(B, "play") == 0 and count(B, "playback") == 0, "nothing plays or polls while stopped")

  -- (2) A plays: B plays the same song on its own account, ahead by its latency
  check(A.ns.MUSIC.toggle() == true and A.ns.MUSIC.state().s == "play", "A plays")
  check(A.ns.MUSIC.state().i == items[1].id, "the first song")
  step(ms, 1)
  local p = lastPlay(B)
  check(p and p.args[1].uri == FS.uri(1), "B plays song 1 on Spotify")
  check(p and p.args[1].positionMs >= 350 and p.args[1].positionMs <= 700, "position ~ pos + latency: "
    .. tostring(p and p.args[1].positionMs))
  check(p and p.args[1].deviceId == nil, "on the active device")
  step(ms, 5)
  check(B.fs.player and B.fs.player.playing and B.fs.player.uri == FS.uri(1), "B's device plays")
  check(B.ns.MUSIC.audible(), "B is audible")
  check(count(A, "play") == 0, "A (no Spotify) does not play")
  -- the 5 s heartbeat does not re-issue the play
  step(ms, 400)
  check(count(B, "play") == 1, "one play per epoch: " .. count(B, "play"))
  check(#sentOf(A, "ms", "B") >= 2, "heartbeats")
  local polls = count(B, "playback")
  check(polls >= 2 and polls <= 3, "B polls every 3 s while playing: " .. polls)
  check(count(B, "seek") == 0, "no drift, no seek")

  -- (3) drift: the device is 3 s ahead
  B.fs.respond.playback = function(c)
    local res = B.fs.default(c)
    if res.active then res.positionMs = res.positionMs + 3000 end
    return res
  end
  step(ms, 200)
  check(count(B, "seek") == 1, "a 3 s drift seeks once: " .. count(B, "seek"))
  local sk = B.fs.callsOf("seek")[1]
  local want = A.ns.MUSIC.position()
  check(sk and math.abs(sk.args[1] - want) < 3000, "seeks to the host's position")
  step(ms, 300)                           -- 5 s more: two more drifting polls
  check(count(B, "seek") == 1, "no second seek within 8 s")
  step(ms, 360)
  check(count(B, "seek") == 2, "another after 8 s: " .. count(B, "seek"))
  B.fs.respond.playback = nil
  check(#errors(ms) == 0, "no errors: " .. table.concat(errors(ms), "; "))
end

-- 4. Dismissing never stops the music: hide, minimise, panel closed, a video party starting, ending, stopping.
do
  local ms = party{{"A", "premium"}, {"B", "premium"}}
  local A, B = ms[1], ms[2]
  A.wum.config.set("musicDuringVideo", "play")   -- this part checks the video's own events, not the auto-pause
  A.ns.MUSIC.add(songs(1, 3))
  A.ns.MUSIC.toggle()
  step(ms, 40)
  check(count(A, "play") == 1 and count(B, "play") == 1, "both follow")
  local e = A.ns.MUSIC.state().e
  local function quiet(what)
    check(count(A, "pause") == 0 and count(B, "pause") == 0, what .. ": no pause")
    check(A.ns.MUSIC.state().e == e and A.ns.MUSIC.state().s == "play", what .. ": the state did not change")
    check(B.ns.MUSIC.audible() and A.ns.MUSIC.audible(), what .. ": still audible")
  end
  for _, m in ipairs(ms) do m.ns.LAYOUT.setView("hidden") end
  step(ms, 30)
  quiet("hidden")
  for _, m in ipairs(ms) do m.ns.LAYOUT.setView("pill") end
  step(ms, 30)
  quiet("minimised")
  for _, m in ipairs(ms) do m.ns.PARTY.setSetup(true) end
  step(ms, 5)
  for _, m in ipairs(ms) do m.ns.PARTY.setSetup(false) end
  step(ms, 30)
  quiet("panel closed")
  -- a video party: start, load, play, end of the video, end of the party
  A.ns.QUEUE.add(VID1)
  check(A.ns.PARTY.start() == true, "A starts a video party")
  step(ms, 10)
  A.mock.emit("melange.media", {type = "loaded", duration = 120})
  step(ms, 40)
  check(A.ns.PARTY.phase() == "playing", "the video plays: " .. A.ns.PARTY.phase())
  quiet("video playing (setting: play)")
  A.mock.emit("melange.media", {type = "ended", reason = "eof"})
  step(ms, 30)
  quiet("video ended")
  A.ns.PARTY.stop()
  step(ms, 30)
  check(A.ns.PARTY.role() == "none" and B.ns.PARTY.role() == "none", "the video party ended")
  quiet("End party")
  B.ns.PARTY.setSetup(false)
  step(ms, 200)
  quiet("later")
  -- the game music stays silent for the music alone
  check(A.mock.music.requested == true and B.mock.music.requested == true, "game music silent after End party")
  check(#errors(ms) == 0, "no errors: " .. table.concat(errors(ms), "; "))
end

-- 5. What stops it: the host's Stop, a listener's "Mute here", leaving the lobby (only if Holo started the track).
do
  local ms = party{{"A"}, {"B", "premium"}, {"C", "premium"}}
  local A, B, C = ms[1], ms[2], ms[3]
  A.ns.MUSIC.addLocal(songs(1, 2))
  A.ns.MUSIC.toggle()
  step(ms, 40)
  check(count(B, "play") == 1 and count(C, "play") == 1, "B and C play")
  A.ns.MUSIC.stop()
  step(ms, 10)
  check(count(B, "pause") == 1 and count(C, "pause") == 1, "host Stop pauses everyone")
  check(B.ns.MUSIC.owned() == nil and not B.ns.MUSIC.audible(), "nothing owned after stop")
  check(B.mock.music.requested == false, "game music back after stop")
  A.ns.MUSIC.toggle()
  step(ms, 10)
  check(count(B, "play") == 2 and count(C, "play") == 2, "play again")
  -- pause is a pause on everyone's device, resume plays from the paused position
  A.ns.MUSIC.toggle()
  step(ms, 10)
  check(count(B, "pause") == 2 and A.ns.MUSIC.state().s == "pause", "host Pause pauses B")
  A.ns.MUSIC.toggle()
  step(ms, 10)
  check(count(B, "play") == 3, "host Play resumes B")
  -- B: Mute here
  B.ns.MUSIC.setListen(false)
  check(count(B, "pause") == 3, "Mute here pauses B's device")
  step(ms, 30)
  check(count(B, "play") == 3 and not B.ns.MUSIC.following(), "B stays muted")
  local bPlays = count(B, "play")
  A.ns.MUSIC.next()
  step(ms, 10)
  check(count(B, "play") == bPlays, "a muted listener does not follow")
  -- leaving: C owns its track and pauses it, B (muted) touches nothing
  local bPauses, cPauses = count(B, "pause"), count(C, "pause")
  B.mock.setLobby(nil)
  C.mock.setLobby(nil)
  step(ms, 5)
  check(count(C, "pause") == cPauses + 1, "C left: its device pauses")
  check(count(B, "pause") == bPauses, "B left without a Holo track: no pause")
  check(C.ns.MUSIC.count() == 0 and C.ns.MUSIC.state().s == "stop", "C's mirror is gone")
  check(A.ns.MUSIC.state().s == "play", "the host's music goes on")
  B.ns.MUSIC.setListen(true)
  check(B.ns.U.pref("musicListen") == true, "Listen remembered")
  check(#errors(ms) == 0, "no errors: " .. table.concat(errors(ms), "; "))
end

-- 6. The lobby changes hands: followers pause; the new owner adopts the songs, stopped.
do
  local ms = party{{"A"}, {"B", "premium"}, {"C", "premium"}}
  local A, B, C = ms[1], ms[2], ms[3]
  B.ns.MUSIC.add(songs(1, 2))
  step(ms, 40)
  A.ns.MUSIC.addLocal(songs(3, 3))
  A.ns.MUSIC.toggle()
  step(ms, 40)
  check(B.ns.MUSIC.count() == 3 and C.ns.MUSIC.count() == 3, "mirrors")
  check(count(B, "play") == 1 and count(C, "play") == 1, "both play")
  lobby(ms, "B")
  step(ms, 5)
  check(count(B, "pause") == 1 and count(C, "pause") == 1, "both pause")
  check(lastEvent(C, "party.toast") and lastEvent(C, "party.toast")[2] == "The host left; the party music stopped",
    "C is told")
  check(B.ns.MUSIC.isHost() and B.ns.MUSIC.count() == 3 and B.ns.MUSIC.state().s == "stop", "B adopts, stopped")
  local its = B.ns.MUSIC.items()
  check(its[1].by == "NB" and its[1].byId == "B" and its[3].by == nil, "attribution kept")
  step(ms, 60)
  check(count(B, "play") == 0 + 1 and count(C, "play") == 1, "no autoplay")
  check(C.ns.MUSIC.count() == 3, "C gets B's queue")
  check(B.ns.MUSIC.toggle() == true, "the new owner can play")
  step(ms, 10)
  check(count(C, "play") == 2 and lastPlay(C).args[1].uri == its[1].uri, "C follows the new owner")
  check(#errors(ms) == 0, "no errors: " .. table.concat(errors(ms), "; "))
end

-- 7. musicDuringVideo: "pause" pauses the music while a party video plays and resumes it after; "play" does not.
do
  local ms = party{{"A"}, {"B", "premium"}}
  local A, B = ms[1], ms[2]
  A.ns.MUSIC.addLocal(songs(1, 2))
  A.ns.MUSIC.toggle()
  step(ms, 20)
  A.ns.QUEUE.add(VID1)
  A.ns.PARTY.start()
  step(ms, 10)
  check(A.ns.MUSIC.state().s == "play", "loading the video does not pause the music yet")
  A.mock.emit("melange.media", {type = "loaded", duration = 120})
  step(ms, 40)
  check(A.ns.PARTY.phase() == "playing", "the video plays")
  check(A.ns.MUSIC.state().s == "pause" and A.ns.MUSIC.debug().autoPaused, "the music auto-paused")
  check(count(B, "pause") >= 1, "B's device paused")
  A.ns.PARTY.togglePlay()
  step(ms, 30)
  check(A.ns.PARTY.phase() == "paused" and A.ns.MUSIC.state().s == "pause", "not at once")
  step(ms, 50)
  check(A.ns.MUSIC.state().s == "play" and not A.ns.MUSIC.debug().autoPaused, "the video paused: music resumes")
  -- the host's manual Play overrides the auto-pause for this video
  A.ns.PARTY.togglePlay()
  step(ms, 60)
  check(A.ns.MUSIC.state().s == "pause", "paused again with the video")
  A.ns.MUSIC.toggle()
  step(ms, 60)
  check(A.ns.MUSIC.state().s == "play" and A.ns.MUSIC.debug().override == A.ns.PARTY.currentId(), "override")
  -- a manual Pause is not undone when the video stops
  A.ns.MUSIC.toggle()
  A.ns.PARTY.stop()
  step(ms, 120)
  check(A.ns.MUSIC.state().s == "pause", "a host pause stays")
  -- "play": the video changes nothing
  A.wum.config.set("musicDuringVideo", "play")
  step(ms, 40)
  A.ns.MUSIC.toggle()
  A.ns.PARTY.start()
  step(ms, 10)
  A.mock.emit("melange.media", {type = "loaded", duration = 120})
  step(ms, 60)
  check(A.ns.PARTY.phase() == "playing" and A.ns.MUSIC.state().s == "play", "'play': the music goes on")
  check(#errors(ms) == 0, "no errors: " .. table.concat(errors(ms), "; "))
end

-- 8. Game music: silent while B follows and plays, even with no video party (role "none"); back after Stop.
do
  local ms = party{{"A"}, {"B", "premium"}}
  local A, B = ms[1], ms[2]
  check(B.mock.music.requested == false, "game music on")
  A.ns.MUSIC.addLocal(songs(1, 1))
  A.ns.MUSIC.toggle()
  step(ms, 20)
  check(B.ns.PARTY.role() == "none" and B.mock.music.requested == true, "silent while B plays the party music")
  check(A.mock.music.requested == false, "A hears nothing from Spotify: game music stays")
  B.wum.config.set("musicOff", false)
  step(ms, 40)
  check(B.mock.music.requested == false, "the musicOff setting is honoured")
  B.wum.config.set("musicOff", true)
  step(ms, 40)
  check(B.mock.music.requested == true, "silent again")
  A.ns.MUSIC.stop()
  step(ms, 10)
  check(B.mock.music.requested == false, "back after stop")
end

-- 9. The host checks every madd: whoAdds, the rate, the URI, the length, 20 per message, 50 per member, duplicates.
do
  local ms = party{{"A"}, {"B", "premium"}}
  local A, B = ms[1], ms[2]
  local n = 100
  local function wire(k, o)
    o = o or {}
    return {u = o.u or FS.uri(k), ti = o.ti or ("T" .. k), ar = "Ar", d = o.d or 200000}
  end
  -- a raw madd from B; the host answers from NET.post's outbox (one frame drains it), then waits out the rate limit
  local function madd(list)
    n = n + 1
    A.mock.peerDeliver("B", {t = "madd", n = n, items = list})
    A.mock.frame()
    local r = sentOf(A, "maddr", "B")
    r = r[#r]
    A.mock.frames(40)
    return r and r.tbl.n == n and r.tbl or {}
  end
  local r = madd({wire(1, {u = "spotify:track:short"})})
  check(r.ok == false and r.why == "invalid", "bad uri: " .. tostring(r.why))
  r = madd({wire(1, {u = "spotify:episode:" .. string.rep("a", 22)})})
  check(r.ok == false and r.why == "invalid", "not a track")
  r = madd({wire(1, {d = 500})})
  check(r.ok == false and r.why == "invalid", "too short")
  r = madd({wire(1, {d = 7200001})})
  check(r.ok == false and r.why == "invalid", "too long")
  r = madd({wire(1, {d = 1.5e5 + 0.5})})
  check(r.ok == false, "not an integer")
  local many = {}
  for k = 1, 21 do many[k] = wire(k) end
  r = madd(many)
  check(r.ok == false and r.why == "too-many", "21 items: " .. tostring(r.why))
  check(A.ns.MUSIC.count() == 0, "nothing added yet")
  r = madd({wire(1, {ti = "   "}), wire(2)})
  check(r.ok == true and r.c == 2 and A.ns.MUSIC.items()[1].title == "Spotify track", "two added, empty title fixed")
  r = madd({wire(1), wire(3)})
  check(r.ok == true and r.c == 1 and r.why == "dup", "duplicate skipped")
  r = madd({wire(1)})
  check(r.ok == false and r.why == "dup", "only a duplicate")
  -- rate: two at once
  n = n + 1
  A.mock.peerDeliver("B", {t = "madd", n = n, items = {wire(10)}})
  n = n + 1
  A.mock.peerDeliver("B", {t = "madd", n = n, items = {wire(11)}})
  A.mock.frame()
  local rs = sentOf(A, "maddr", "B")
  check(rs[#rs].tbl.why == "rate" and rs[#rs - 1].tbl.ok == true, "one madd per 500 ms")
  A.mock.frames(40)
  -- the member cap: B has 4, so 46 more fit
  for k = 0, 1 do
    local list = {}
    for j = 1, 20 do list[j] = wire(100 + k * 20 + j) end
    r = madd(list)
    check(r.ok == true and r.c == 20, "batch " .. k)
  end
  local list = {}
  for j = 1, 20 do list[j] = wire(200 + j) end
  r = madd(list)
  check(r.ok == true and r.c == 6 and r.why == "member-full", "member cap 50: " .. tostring(r.c) .. tostring(r.why))
  check(A.ns.MUSIC.count() == 50, "50 songs")
  -- the host itself is not capped per member
  check(A.ns.MUSIC.addLocal(songs(300, 310)) == 11, "the host adds more")
  -- whoAdds = host
  A.wum.config.set("whoAdds", "host")
  step(ms, 40)
  check(B.ns.PARTY.hostCaps().madd == false and B.ns.MUSIC.addWhyNot() == "host-only", "caps tell B")
  check(select(2, B.ns.MUSIC.add(songs(400, 400))) == "host-only", "B's add refused locally")
  r = madd({wire(500)})
  check(r.ok == false and r.why == "host-only", "a raw madd refused")
  -- mrm: only the member's own songs
  A.wum.config.set("whoAdds", "anyone")
  step(ms, 40)
  local mine, hosts = nil, nil
  for _, it in ipairs(A.ns.MUSIC.items()) do
    if it.byId == "B" and not mine then mine = it end
    if it.byId == nil and not hosts then hosts = it end
  end
  check(B.ns.MUSIC.requestRemove(hosts.id) == nil, "B cannot remove the host's song")
  check(B.ns.MUSIC.requestRemove(mine.id) == true, "B removes its own")
  step(ms, 40)
  A.mock.peerDeliver("B", {t = "mrm", id = hosts.id})
  step(ms, 40)
  check(A.ns.MUSIC.find(mine.id) == nil and A.ns.MUSIC.find(hosts.id) ~= nil, "only B's song went")
  -- a bad ms or mq from the host is dropped
  B.mock.peerDeliver("A", {t = "ms", e = 1.5, i = 1, s = "play", p = 0, a = 0})
  B.mock.peerDeliver("A", {t = "ms", e = 999, i = 1, s = "loud", p = 0, a = 0})
  B.mock.peerDeliver("A", {t = "ms", e = 999, i = 1, s = "play", p = -1, a = 0})
  B.mock.peerDeliver("A", {t = "mq", mv = 9999, page = 2, pages = 1, items = {}})
  check(B.ns.MUSIC.state().e < 999 and B.ns.MUSIC.version() < 9999, "bad messages dropped")
  -- a non-owner cannot send state
  check(#errors(ms) == 0, "no errors: " .. table.concat(errors(ms), "; "))
end

-- 10. Mixed versions: no "cap" from the owner (Holo 1.0) -> a member's add says "old-host"; the panel says so.
do
  local ms = {machine("A"), machine("B", "premium")}
  local A, B = ms[1], ms[2]
  lobby(ms, "A")
  connect(ms)
  step(ms, 10, function(_, _, tbl) return tbl.t ~= "cap" end)
  check(B.ns.PARTY.hostAcked() and B.ns.PARTY.hostCaps() == nil, "acked without caps")
  local ok, why = B.ns.MUSIC.add(songs(1, 1))
  check(ok == nil and why == "old-host", "old host: " .. tostring(why))
  B.mock.cursorSource = "frontend"
  B.ns.PARTY.setSetup(true)
  B.ns.SETUP.setTab("music")
  B.mock.frames(3)
  local t = {}
  for _, c in ipairs(B.mock.drawOf("hudText")) do t[#t + 1] = tostring(c.args[3]) end
  t = table.concat(t, " ")
  check(t:find("older than 1.1, so music is off", 1, true) ~= nil, "the panel says the host is old")
  -- an old peer: the host's mq/ms reach a Holo that ignores them (here: unknown types are ignored by PARTY)
  A.ns.MUSIC.addLocal(songs(1, 1))
  A.ns.MUSIC.toggle()
  step(ms, 20)
  check(#errors(ms) == 0, "no errors: " .. table.concat(errors(ms), "; "))
end

-- 11. A free account: sees what plays, never plays; the panel says Free.
do
  local ms = party{{"A"}, {"B", "free"}}
  local A, B = ms[1], ms[2]
  A.ns.MUSIC.addLocal(songs(1, 2))
  A.ns.MUSIC.toggle()
  step(ms, 300)
  check(count(B, "play") == 0 and count(B, "playback") == 0, "no play calls, no polls")
  check(B.ns.MUSIC.current() and B.ns.MUSIC.current().uri == FS.uri(1), "B sees the song")
  check(not B.ns.MUSIC.audible() and B.mock.music.requested == false, "not audible")
  B.mock.cursorSource = "frontend"
  B.ns.PARTY.setSetup(true)
  B.ns.SETUP.setTab("music")
  B.mock.frames(3)
  local t = {}
  for _, c in ipairs(B.mock.drawOf("hudText")) do t[#t + 1] = tostring(c.args[3]) end
  t = table.concat(t, " ")
  check(t:find("Free account", 1, true) ~= nil, "the panel says Free account")
  check(t:find("Free account: playing needs Premium", 1, true) ~= nil, "the chip says why too")
  check(t:find("Song 1", 1, true) ~= nil, "now playing shows the song")
  -- Premium says so only when Spotify refuses: the follower marks it
  local C = machine("C", "premium")
  C.fs.status.premium = true
  C.fs.respond.play = function() return {error = "premium"} end
  table.insert(ms, C)
  lobby(ms, "A")
  connect(ms)
  step(ms, 30)
  check(count(C, "play") == 1 and C.ns.MUSIC.notPremium(), "a refused play marks not-Premium")
  step(ms, 400)
  check(count(C, "play") == 1, "no retries")
  check(#errors(ms) == 0, "no errors: " .. table.concat(errors(ms), "; "))
end

-- 12. The user takes over in Spotify: Holo stops following until "Follow again" or the host's next song.
do
  local ms = party{{"A"}, {"B", "premium"}}
  local A, B = ms[1], ms[2]
  A.ns.MUSIC.addLocal(songs(1, 3))
  A.ns.MUSIC.toggle()
  step(ms, 400)
  check(count(B, "play") == 1 and not B.ns.MUSIC.detached(), "following")
  B.fs.player.uri = FS.uri(99)            -- the user picked something else in Spotify
  step(ms, 200)
  check(B.ns.MUSIC.detached(), "detached")
  check(lastEvent(B, "music.detached") ~= nil, "the follow-again toast is offered")
  local toasts = B.ns.MAIN.toasts()
  check(toasts[#toasts] and toasts[#toasts].actions and toasts[#toasts].actions[1][1] == "Follow again", "toast action")
  check(not B.ns.MUSIC.audible(), "not audible (the game music may play)")
  -- the host seeks (a new epoch, the same song): still detached, no play
  A.ns.MUSIC.seek(100000)
  step(ms, 200)
  check(count(B, "play") == 1 and count(B, "pause") == 0, "no further plays while detached")
  -- Follow again
  B.ns.MUSIC.followAgain()
  step(ms, 5)
  check(count(B, "play") == 2 and not B.ns.MUSIC.detached(), "Follow again plays")
  -- detach again, then the host's next song clears it
  step(ms, 300)
  B.fs.player.playing = false             -- the user paused in Spotify
  step(ms, 200)
  check(B.ns.MUSIC.detached(), "a pause in Spotify detaches too")
  A.ns.MUSIC.next()
  step(ms, 5)
  check(not B.ns.MUSIC.detached() and count(B, "play") == 3 and lastPlay(B).args[1].uri == FS.uri(2), "next song")
  -- a song ending is not a takeover: the device stops a moment before the host's next state
  step(ms, 300)
  local plays = count(B, "play")
  A.ns.MUSIC.seek(600000 - 4000)
  step(ms, 2)
  B.fs.player.playing = false
  step(ms, 300)
  -- the seek re-plays at the new position (a new epoch), then the next song plays: no detach in between
  check(not B.ns.MUSIC.detached() and count(B, "play") == plays + 2 and lastPlay(B).args[1].uri == FS.uri(3),
    "the end of a song does not detach")
  check(#errors(ms) == 0, "no errors: " .. table.concat(errors(ms), "; "))
end

-- 13. The queue end, removes, reorder, prev, and the chip.
do
  local ms = party{{"A"}, {"B", "premium"}}
  local A, B = ms[1], ms[2]
  local M = A.ns.MUSIC
  M.addLocal(songs(1, 3, {durationMs = 5000}))
  M.toggle()
  step(ms, 20)
  check(M.state().i == M.items()[1].id, "song 1")
  step(ms, 300)                           -- 5 s songs: auto-advance
  check(M.state().i == M.items()[2].id and M.state().s == "play", "auto-advance to song 2")
  check(lastPlay(B).args[1].uri == FS.uri(2), "B follows the advance")
  M.move(M.items()[3].id, -1)
  check(M.items()[2].uri == FS.uri(3), "reorder")
  check(M.position() < 3000, "song 2 just started")
  M.prev()
  check(M.current().uri == FS.uri(3), "prev: the song before it (after the reorder)")
  M.remove(M.state().i)
  check(M.state().s == "play" and M.current().uri == FS.uri(2), "removing the playing song plays the next one")
  step(ms, 700)
  check(M.state().s == "stop", "the queue ran out")
  check(lastEvent(A, "party.toast")[2] == "The music queue finished", "told")
  step(ms, 10)
  check(B.ns.MUSIC.owned() == nil and B.mock.music.requested == false, "B stopped")
  -- the chip
  for _, m in ipairs(ms) do
    m.mock.cursorSource = "frontend"
    m.mock.cursorPos = {5, 500}
  end
  M.addLocal(songs(10, 10))
  M.playItem(M.items()[#M.items()].id, 0)
  step(ms, 10)
  local function chipText(m)
    local t = {}
    for _, c in ipairs(m.mock.drawOf("hudText")) do t[#t + 1] = tostring(c.args[3]) end
    return table.concat(t, " ")
  end
  check(chipText(A):find("Song 10", 1, true) ~= nil, "the host's chip shows the song")
  check(chipText(B):find("on DESKTOP", 1, true) ~= nil, "B's chip shows the device: " .. chipText(B))
  local rs = {}
  for _, r in ipairs(B.mock.regions()) do rs[r.id] = r end
  check(rs["music.chip"] ~= nil and rs["music.chip"].x1 == 1920 - 16, "the chip is on the right side")
  B.mock.click(rs["music.chip"].x0 + 20, rs["music.chip"].y0 + 10)
  step(ms, 2)
  check(B.ns.PARTY.setupOpen() and B.ns.SETUP.tab() == "music", "the chip opens the Music tab")
  B.ns.PARTY.setSetup(false)
  step(ms, 2)
  check(chipText(B):find("Song 10", 1, true) ~= nil, "the chip with the panel closed")
  B.ns.LAYOUT.setView("hidden")
  step(ms, 2)
  check(chipText(B):find("Song 10", 1, true) == nil, "F9 hides the chip")
  check(B.ns.MUSIC.audible(), "and the music plays on")
  B.ns.LAYOUT.setView("pill")
  -- frame cost: the chip and the lane tick with music playing
  B.ns.PARTY.setSetup(false)
  step(ms, 30)
  local worst = 0
  for _ = 1, 30 do
    B.mock.frame()
    worst = math.max(worst, B.mock.instructionCount)
  end
  print(string.format("music lane + chip per frame (member): worst %d instructions", worst))
  check(worst < 15000, "the music lane is cheap per frame: " .. worst)
  check(#errors(ms) == 0, "no errors: " .. table.concat(errors(ms), "; "))
end

-- 15. A pause that does not go through (Holo's request cap full, or a passing error) is sent again until it does:
-- Stop must never leave the music playing on a listener's device.
do
  local ms = party{{"A"}, {"B", "premium"}}
  local A, B = ms[1], ms[2]
  A.ns.MUSIC.addLocal(songs(1, 2))
  A.ns.MUSIC.toggle()
  step(ms, 20)
  check(B.fs.player and B.fs.player.playing, "B plays")
  -- Spotify is slow: nothing answers, and B's cap fills with waiting requests
  B.fs.manual = true
  for _ = 1, 4 do B.ns.SPOT.devices(function() end) end
  check(B.ns.SPOT.inflight() == 4, "B's cap is full")
  local pauses = count(B, "pause")
  A.ns.MUSIC.stop()
  step(ms, 5)
  check(count(B, "pause") == pauses and B.ns.MUSIC.debug().wantPause ~= nil, "the pause waits for room")
  check(B.fs.player.playing, "still playing on the device")
  for _, c in ipairs(B.fs.calls) do if not c.answered then B.fs.answerNow(c.i) end end
  B.fs.manual = false
  step(ms, 120)
  check(count(B, "pause") == pauses + 1 and not B.fs.player.playing, "the pause went through once there was room")
  check(B.ns.MUSIC.debug().wantPause == nil, "nothing left to pause")
  -- a pause that fails with "network" is sent again
  A.ns.MUSIC.toggle()
  step(ms, 20)
  check(B.fs.player.playing, "B plays again")
  local fail = 1
  B.fs.respond.pause = function()
    if fail > 0 then
      fail = fail - 1
      return {error = "network", message = "x"}
    end
  end
  pauses = count(B, "pause")
  A.ns.MUSIC.stop()
  step(ms, 10)
  check(count(B, "pause") == pauses + 1 and B.fs.player.playing, "the first pause failed")
  step(ms, 120)
  check(count(B, "pause") == pauses + 2 and not B.fs.player.playing, "sent again: paused")
  step(ms, 300)
  check(count(B, "pause") == pauses + 2, "and not again")
  B.fs.respond.pause = nil
  check(#errors(ms) == 0, "no errors: " .. table.concat(errors(ms), "; "))
end

-- 16. A play that fails for a passing reason (network, server, timeout, rate, busy) is tried again on the same
-- song, a few times with a growing wait; other errors wait for the next song.
do
  local ms = party{{"A"}, {"B", "premium"}}
  local A, B = ms[1], ms[2]
  A.ns.MUSIC.addLocal(songs(1, 2))
  local fail = 1
  B.fs.respond.play = function()
    if fail > 0 then
      fail = fail - 1
      return {error = "network", message = "x"}
    end
  end
  A.ns.MUSIC.toggle()
  step(ms, 20)
  check(count(B, "play") == 1 and not (B.fs.player and B.fs.player.playing), "the first play failed")
  step(ms, 60)
  check(count(B, "play") == 1, "no retry before the wait")
  step(ms, 120)
  check(count(B, "play") == 2 and B.fs.player and B.fs.player.playing and B.fs.player.uri == FS.uri(1),
    "tried again: song 1 plays")
  check(B.ns.MUSIC.audible() and B.ns.MUSIC.lastError() == nil, "audible, no error shown")
  -- a server that keeps failing: three more tries, then it waits for the next song
  A.ns.MUSIC.next()
  B.fs.respond.play = function() return {error = "server", message = "x"} end
  local before = count(B, "play")
  step(ms, 1200)
  check(count(B, "play") == before + 4, "one play and three tries: " .. (count(B, "play") - before))
  check(B.ns.MUSIC.lastError() == "server", "the error shows")
  -- a refusal that will not pass ("restricted") is not retried
  A.ns.MUSIC.prev()
  B.fs.respond.play = function() return {error = "restricted", message = "x"} end
  before = count(B, "play")
  step(ms, 600)
  check(count(B, "play") == before + 1, "restricted: no retry")
  B.fs.respond.play = nil
  check(#errors(ms) == 0, "no errors: " .. table.concat(errors(ms), "; "))
end

-- 17. The "Play the party's music on my Spotify" setting takes effect at once, even after Listen / Mute here.
do
  local ms = party{{"A"}, {"B", "premium"}}
  local A, B = ms[1], ms[2]
  A.ns.MUSIC.addLocal(songs(1, 2))
  A.ns.MUSIC.toggle()
  step(ms, 20)
  B.ns.MUSIC.setListen(false)
  B.ns.MUSIC.setListen(true)
  step(ms, 20)
  check(B.ns.U.pref("musicListen") == true and B.fs.player.playing, "Listen pressed: B plays")
  local pauses = count(B, "pause")
  B.wum.config.set("musicFollow", false)
  step(ms, 60)
  check(not B.ns.MUSIC.listening() and not B.ns.MUSIC.following(), "the setting off: not listening")
  check(count(B, "pause") == pauses + 1 and not B.fs.player.playing, "and B's device paused")
  check(B.ns.U.pref("musicListen") == nil, "the setting replaced Listen")
  B.wum.config.set("musicFollow", true)
  step(ms, 60)
  check(B.ns.MUSIC.following() and B.fs.player.playing, "the setting on: B follows again")
  check(#errors(ms) == 0, "no errors: " .. table.concat(errors(ms), "; "))
end

if fails > 0 then
  io.stderr:write(fails .. " check(s) failed\n")
  os.exit(1)
end
print("test_music: all checks passed")
