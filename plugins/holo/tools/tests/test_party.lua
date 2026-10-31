-- PARTY (src/40_party.lua): the role and phase state machine, the host's controls, and the sync protocol of design
-- 2.5 with the N3 limits, run between two (or three) mocked machines whose channels are wired together.
local MW = require("mock_wum")

local fails = 0
local function check(cond, what)
  if not cond then
    fails = fails + 1
    io.stderr:write("  FAIL: " .. what .. "\n")
  end
end

local VID1, VID2, VID3 = "https://youtu.be/vid00000001", "https://youtu.be/vid00000002", "https://youtu.be/vid00000003"
local MAGNET = "magnet:?xt=urn:btih:" .. string.rep("ab", 20)

local function machine(id)
  local wum, mock = MW.new()
  wum._holoTest = {}
  local _, ok, err = MW.load("mod/client/init.lua", wum)
  check(ok, id .. ": init.lua runs: " .. tostring(err))
  local m = {id = id, wum = wum, mock = mock, ns = wum._holoTest.ns, sent = 0, events = {}}
  for _, name in ipairs{"party.toast", "party.joinPrompt", "party.continuePrompt"} do
    m.ns.U.on(name, function(a, b) m.events[#m.events + 1] = {name, a, b} end)
  end
  return m
end

local function lastEvent(m, name)
  for i = #m.events, 1, -1 do
    if m.events[i][1] == name then return m.events[i] end
  end
end

-- A lobby over several machines: every member advertises Holo, `owner` owns it.
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

-- One frame on every machine, then every message sent is delivered to its target (the wire), and every machine's
-- presence becomes visible to the others (the lobby member data).
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
          if o.id == r.to and (not filter or filter(m, o, r.tbl)) then
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

local function player(m) return m.mock.players[#m.mock.players] end

-- 1. a solo party (no lobby): the host's state machine and controls
do
  local A = machine("A")
  local P, Q = A.ns.PARTY, A.ns.QUEUE
  check(P.role() == "none" and P.phase() == "idle" and not P.active(), "idle")
  check(select(2, P.start()) == "empty", "start needs a queue")
  P.toggleSetup(); step({A})
  check(P.phase() == "setup", "setup panel open")
  Q.add(VID1); Q.add(VID2)
  A.mock.pack.state = "missing"
  check(select(2, P.start()) == "pack", "start needs the pack")
  A.mock.pack.state = "ready"
  check(P.start() == true and P.role() == "host" and P.active(), "started")
  check(select(2, P.start()) == "active", "start twice")
  step({A})
  local p = player(A)
  check(p and p.opts.url == "https://www.youtube.com/watch?v=vid00000001" and p.opts.paused == true, "first item open, paused")
  check(p.opts.volume == 70 and p.opts.quality == 720, "volume and quality from the settings")
  check(P.phase() == "loading", "loading")
  check(A.mock.music.requested == true and A.mock.music.fade == 0.4, "game music suppressed")
  A.mock.emit("melange.media", {type = "loaded", title = "One", duration = 100})
  step({A})
  local hs = P.hostState()
  check(hs.s == "play" and hs.a > A.wum.peer.now(), "play scheduled 300 ms ahead")
  check(p._st.paused == true, "not started before the lead")
  step({A}, 20)
  check(p._st.paused == false and P.phase() == "playing", "playing after 300 ms: " .. P.phase())
  P.togglePlay(); step({A})
  check(p._st.paused == true and P.phase() == "paused" and P.hostState().s == "pause", "paused")
  P.seek(42, "keyframes")
  check(p.calls[#p.calls][1] == "seek" and p.calls[#p.calls][3] == "keyframes", "scrub seek")
  local e0 = P.hostState().e
  P.seek(50)
  check(p._st.time == 50 and P.hostState().p == 50 and P.hostState().e == e0 + 1, "exact seek is a new epoch")
  P.skip(10)
  check(p._st.time == 60, "skip +10")
  P.setSpeed(1.4)
  check(P.hostState().r == 1.5 and p._st.speed == 1.5, "speed snaps to 1.5")
  P.setVolume(130); P.setMute(true); step({A})
  check(p.vol == 100 and p.muted == true, "volume clamped, mute")
  P.setMute(false); P.setQuality(480)
  check(p.calls[#p.calls][1] == "quality" and p.calls[#p.calls][2] == 480 and P.quality() == 480, "quality")
  check(P.setQuality(999) == nil, "bad quality")
  -- end of the item: the next one plays; past the end the party waits
  A.mock.emit("melange.media", {type = "ended", reason = "eof"}); step({A})
  local p2 = player(A)
  check(p2 ~= p and p.closed and p2.opts.url:find("vid00000002"), "auto-advance to the next item")
  check(Q.current().url:find("vid00000002"), "queue current follows")
  A.mock.emit("melange.media", {type = "ended", reason = "eof"}); step({A})
  check(P.phase() == "ended-item" and P.active(), "ended-item at the end of the queue")
  Q.add(VID3); step({A})
  check(player(A).opts.url:find("vid00000003"), "an added item plays after ended-item")
  -- a failing item is skipped after 2 s
  A.mock.emit("melange.media", {type = "error", code = "x"}); step({A})
  check(lastEvent(A, "party.toast")[3] == "error", "error toast")
  -- prev and next
  check(P.prev() == true and player(A).opts.url:find("vid00000002"), "prev")
  check(P.next() == true and player(A).opts.url:find("vid00000003"), "next")
  check(select(2, P.next()) == "end", "no next at the end")
  -- remove the playing item: the next at its place, an empty queue ends the party
  Q.remove(Q.current().id); step({A})
  check(player(A).opts.url:find("vid00000002"), "removing the playing item plays its neighbour")
  Q.remove(Q.items()[1].id); Q.remove(Q.items()[1].id); step({A})
  check(P.role() == "none" and A.mock.music.requested == false, "empty queue ends the party")
  -- stop
  Q.add(VID1); P.start(); step({A})
  check(P.stop() == true and P.role() == "none" and P.phase() == "setup" and player(A).closed, "stop")
  check(A.mock.music.requested == false, "music released")
  -- per-frame cost of the logic while a party plays
  P.toggleSetup(); P.start(); A.mock.emit("melange.media", {type = "loaded", duration = 10}); step({A}, 30)
  check(A.mock.instructionCount < 20000, "logic per frame: " .. A.mock.instructionCount .. " instructions")
  print("solo party logic per frame: " .. A.mock.instructionCount .. " instructions")
end

-- 2. host and peer: hi/ack, start, auto-join, follow, heartbeat, buf
local A, B = machine("A"), machine("B")
local ms = {A, B}
lobby(ms, "A")
step(ms)
connect(ms)
step(ms, 2)
check(#sentOf(B, "hi", "A") == 1 and sentOf(B, "hi")[1].tbl.v == 1 and sentOf(B, "hi")[1].tbl.holo == "1.1.0",
  "B says hi to the host")
check(#sentOf(A, "ack", "B") == 1 and sentOf(A, "ack")[1].tbl.party == false, "A acks: no party yet")
step(ms, 60 * 11)
check(#sentOf(B, "hi") == 1, "no more hi once acked")
check(not B.ns.PARTY.canControl() and A.ns.PARTY.canControl(), "only the owner controls")
check(select(2, B.ns.PARTY.start()) == "not-host", "a peer cannot start")
A.ns.QUEUE.add(VID1); A.ns.QUEUE.add(VID2)
check(A.ns.PARTY.start() == true, "host starts")
step(ms, 3)
check(B.ns.PARTY.role() == "peer", "B auto-joined (default Join)")
local jp = lastEvent(B, "party.joinPrompt")
check(jp and jp[2] == "NA" and jp[3] == true, "join toast with the host's name, auto-joined")
check(B.ns.QUEUE.count() == 2 and B.ns.QUEUE.items()[1].url == A.ns.QUEUE.items()[1].url, "B mirrors the queue")
check(B.mock.music.requested == true, "B silences its game music")
step(ms, 100)
local bp = player(B)
check(bp and bp.opts.url == A.ns.QUEUE.items()[1].url and bp.opts.paused == true, "B opened the item paused")
check(bp.following and bp.followHost == "A" and bp.following.s == "pause", "B follows the host")
A.mock.emit("melange.media", {type = "loaded", duration = 100})
step(ms, 2)
check(bp.following.s == "play" and bp.following.a == A.ns.PARTY.hostState().a, "B follows the scheduled play")
B.mock.emit("melange.media", {type = "loaded", duration = 100})
step(ms, 2)
local bufs = sentOf(B, "buf", "A")
check(#bufs >= 1 and bufs[#bufs].tbl.ok == true and bufs[#bufs].tbl.b == false, "B reports loaded")
-- heartbeat: unreliable st about once a second while playing
local hb0 = 0
for _, r in ipairs(sentOf(A, "st", "B")) do if r.opts and r.opts.reliable == false then hb0 = hb0 + 1 end end
step(ms, 180)
local hb1 = 0
for _, r in ipairs(sentOf(A, "st", "B")) do if r.opts and r.opts.reliable == false then hb1 = hb1 + 1 end end
check(hb1 - hb0 >= 2 and hb1 - hb0 <= 4, "heartbeat ~1 Hz: " .. (hb1 - hb0))
check(bp.following.a > A.ns.PARTY.hostState().a - 1100, "B follows the latest heartbeat")
-- a scrub (keyframes seeks while the host drags) stays local: no heartbeat carries the scrub position
local function beats()
  local n = 0
  for _, r in ipairs(sentOf(A, "st", "B")) do if r.opts and r.opts.reliable == false then n = n + 1 end end
  return n
end
local hb2 = beats()
for _ = 1, 6 do A.ns.PARTY.seek(70, "keyframes"); step(ms, 20) end
check(beats() == hb2, "no heartbeat while scrubbing: " .. (beats() - hb2))
A.ns.PARTY.seek(70)
step(ms, 120)
check(A.ns.PARTY.hostState().p >= 70 and beats() > hb2, "the exact seek ends the scrub, heartbeats resume")
-- peers list on the host: buffering, error, ready
B.mock.emit("melange.media", {type = "buffering", on = true}); step(ms, 2)
local pl = A.ns.PARTY.peers()
check(#pl == 1 and pl[1].id == "B" and pl[1].state == "buffering", "host sees B buffering")
B.mock.emit("melange.media", {type = "buffering", on = false}); step(ms, 2)
check(A.ns.PARTY.peers()[1].state == "ready", "B ready again")
-- peers cannot control
check(select(2, B.ns.PARTY.togglePlay()) == "not-host" and select(2, B.ns.PARTY.seek(3)) == "not-host",
  "peer controls refused")
check(select(2, B.ns.QUEUE.remove(1)) == "not-host" and select(2, B.ns.QUEUE.move(1, 1)) == "not-host",
  "peer cannot remove or reorder")
check(B.ns.PARTY.hostName() == "NA" and A.ns.PARTY.hostName() == "you", "host names")
-- host pause reaches B
A.ns.PARTY.togglePlay(); step(ms, 2)
check(bp.following.s == "pause", "pause reaches the peer")
-- a queue change is sent to B
A.ns.QUEUE.add(VID3); step(ms, 30)
check(B.ns.QUEUE.count() == 3, "queue change mirrored")
-- presence while hosting
check(A.mock.channel.presenceMine.party == 1 and A.mock.channel.presenceMine.n == 3, "host presence")

-- 3. message validation and the N3 limits
do
  -- st from a member that is not the owner, and malformed st, are ignored
  local before = bp.following.e
  B.mock.peerDeliver("A", {t = "st", e = 999, i = 1, s = "dance", p = 1, r = 1, a = 1})
  B.mock.peerDeliver("A", {t = "st", e = 999, i = 1, s = "play", p = 0 / 0, r = 1, a = 1})
  B.mock.peerDeliver("A", {t = "st", e = 999, i = 1, s = "play", p = 1, r = 10, a = 1})
  B.mock.peerDeliver("A", {t = "st", e = 999.5, i = 1, s = "play", p = 1, r = 1, a = 1})
  B.mock.peerDeliver("A", {t = "st", e = before - 1, i = 1, s = "play", p = 1, r = 1, a = 1e12})
  step(ms)
  check(bp.following.e == before, "bad and stale st ignored")
  local P = B.ns.PARTY
  check(P.checkSt({e = 1, i = 2, s = "play", p = 3, r = 1, a = 4}) ~= nil, "a good st passes")
  check(P.checkSt({e = -1, i = 2, s = "play", p = 3, r = 1, a = 4}) == nil, "negative epoch")
  check(P.checkSt({e = 1, i = 2, s = "play", p = -3, r = 1, a = 4}) == nil, "negative position")
  check(P.checkSt({e = 1, i = 2, s = "play", p = 3, r = 1, a = 1 / 0}) == nil, "infinite time")
  check(P.checkSt("st") == nil, "not a table")
  -- a peer's hi flood: one ack per 2 s
  local acks0 = #sentOf(A, "ack", "B")
  for _ = 1, 10 do A.mock.peerDeliver("B", {t = "hi", v = 1, pack = "ready", holo = "1.0.0"}) end
  step(ms, 5)
  check(#sentOf(A, "ack", "B") - acks0 == 1, "one hi per 2 s honoured")
  step(ms, 130)
  A.mock.peerDeliver("B", {t = "hi", v = 1})
  step(ms, 2)
  check(#sentOf(A, "ack", "B") - acks0 == 2, "a hi after 2 s is honoured")
  -- a need flood: one queue resend per 5 s
  step(ms, 320)
  local q0 = #sentOf(A, "q", "B")
  for _ = 1, 10 do A.mock.peerDeliver("B", {t = "need", qv = 0}) end
  step(ms, 60)
  local q1 = #sentOf(A, "q", "B")
  check(q1 - q0 == 1, "one need per 5 s honoured: " .. (q1 - q0))
  -- host messages from a non-owner are ignored, member messages to a non-owner too
  B.mock.peerDeliver("A", {t = "end", why = "host"})
  step(ms)
  check(B.ns.PARTY.role() == "none", "end from the owner ends it")
  B.ns.PARTY.join()
end

-- 4. peer item opens are paced and coalesced (one per 1.5 s, the latest item wins)
do
  A.ns.PARTY.togglePlay()
  step(ms, 120)
  local opens0 = #B.mock.players
  local q0 = #sentOf(A, "q", "B")
  local items = A.ns.QUEUE.items()
  A.ns.PARTY.next(); step(ms, 2)
  A.ns.PARTY.prev(); step(ms, 2)
  A.ns.PARTY.next(); step(ms, 2)
  A.ns.PARTY.next(); step(ms, 2)
  step(ms, 100)
  local opened = #B.mock.players - opens0
  check(opened <= 2, "at most one open per 1.5 s: " .. opened)
  check(player(B).opts.url == items[3].url and B.ns.PARTY.currentId() == items[3].id, "B ends on the latest item")
  check(#sentOf(A, "q", "B") == q0, "an item change does not resend the queue")
  check(B.ns.QUEUE.current().id == items[3].id, "B's current item follows st.i")
end

-- 5. decline, remembered; the next party prompts; join
do
  B.ns.PARTY.decline(); step(ms, 2)
  check(B.ns.PARTY.role() == "none" and player(B).closed and B.mock.music.requested == false, "declined")
  check(B.ns.PARTY.partyRunning() == true, "the party still runs for others")
  A.ns.PARTY.stop(); step(ms, 5)
  check(A.ns.PARTY.role() == "none" and #sentOf(A, "end") >= 1, "host ends")
  A.ns.PARTY.start(); step(ms, 5)
  local jp2 = lastEvent(B, "party.joinPrompt")
  check(B.ns.PARTY.role() == "none" and jp2[3] == false, "after a decline, a prompt and no auto-join")
  check(B.ns.PARTY.join() == true and B.ns.PARTY.role() == "peer", "join from the prompt")
  step(ms, 100)
  check(player(B) and not player(B).closed, "B plays after joining")
  check(B.ns.U.pref("autoJoin") == true, "join remembered")
end

-- 6. the host ends the party
do
  A.ns.PARTY.stop(); step(ms, 5)
  check(B.ns.PARTY.role() == "none" and B.ns.PARTY.phase() == "idle" and player(B).closed, "peer idle after end")
  check(lastEvent(B, "party.toast")[2] == "The host ended the watch party", "end toast")
end

-- 7. a late joiner gets ack, q and st and joins; a peer without the pack waits in needs-pack
do
  A.ns.PARTY.start(); A.mock.emit("melange.media", {type = "loaded", duration = 100}); step(ms, 30)
  local C = machine("C")
  C.mock.pack.state = "missing"
  local all = {A, B, C}
  lobby(all, "A")
  step(all)
  connect(all)
  step(all, 5)
  check(C.ns.PARTY.role() == "peer" and C.ns.QUEUE.count() == A.ns.QUEUE.count(), "late joiner joined with the queue")
  step(all, 100)
  check(C.ns.PARTY.phase() == "needs-pack" and #C.mock.players == 0, "needs-pack, nothing opened")
  check(C.ns.PARTY.consentText():find("95 MB"), "consent text names the size")
  check(select(2, C.ns.PARTY.installPack()) == "gesture", "install needs a click")
  C.mock.gesture(true)
  check(C.ns.PARTY.installPack() == true and C.mock.pack.state == "downloading", "install from a click")
  step(all, 40)
  check(C.mock.channel.presenceMine.pack:find("^downloading:"), "presence shows the download")
  check(A.ns.PARTY.peers()[2].state == "nopack", "host sees C without the pack")
  C.mock.pack.state = "ready"
  step(all, 130)
  check(C.ns.PARTY.phase() ~= "needs-pack" and player(C) and player(C).following, "C plays after the install")
  -- 8. the owner leaves: the party ends everywhere, the new owner may continue where it was
  A.mock.players[#A.mock.players]._st.time = 33
  B.mock.players[#B.mock.players]._st.time = 33     -- B's player is in step with the host
  step(all, 70)
  lobby({B, C}, "B")
  B.mock.setPeers({"C"}); C.mock.setPeers({"B"})
  step({B, C}, 2)
  check(B.ns.PARTY.role() == "none" and C.ns.PARTY.role() == "none", "party ended on the owner change")
  check(lastEvent(B, "party.continuePrompt") ~= nil and B.ns.PARTY.canContinue(), "the new owner may continue")
  check(not C.ns.PARTY.canContinue(), "the others may not")
  check(B.ns.PARTY.continueParty() == true and B.ns.PARTY.role() == "host", "B continues as host")
  check(B.ns.QUEUE.count() == 3, "with the queue")
  step({B, C}, 5)
  local cont = player(B)
  check(cont.opts.start and cont.opts.start > 30, "from where it was: " .. tostring(cont.opts.start))
  step({B, C}, 120)
  check(C.ns.PARTY.role() == "peer" and player(C).followHost == "B", "C follows the new host")
  -- 9. leaving the lobby closes everything
  C.mock.setLobby(nil); step({C}, 2)
  check(C.ns.PARTY.role() == "none" and player(C).closed and C.mock.music.requested == false, "left the lobby")
end

-- 10. torrents through the party: the host plays the picked file, the peer waits for the file list
do
  local H, J = machine("H"), machine("J")
  local two = {H, J}
  lobby(two, "H"); step(two); connect(two); step(two, 3)
  H.ns.QUEUE.add(MAGNET)
  H.mock.torrentFiles({{index = 0, path = "a.mkv", size = 5, video = true}, {index = 1, path = "b.mkv", size = 9, video = true}})
  local pick
  H.ns.U.on("queue.pick", function(t) pick = t end)
  H.ns.QUEUE.add(MAGNET)
  H.mock.torrentFiles({{index = 0, path = "a.mkv", size = 5, video = true}, {index = 1, path = "b.mkv", size = 9, video = true}})
  check(pick ~= nil, "picker for two files")
  H.ns.QUEUE.pickFile(pick, 1)
  check(H.ns.PARTY.start() == true, "torrent party")
  step(two, 2)
  local hp = player(H)
  check(hp and hp.opts.torrent and hp.opts.file == 1, "host opened the torrent file")
  step(two, 100)
  check(J.ns.PARTY.role() == "peer" and #J.mock.players == 0 and #J.mock.torrents == 1, "peer waits for the file list")
  J.mock.torrentFiles({{index = 0, path = "a.mkv", size = 5, video = true}, {index = 1, path = "b.mkv", size = 9, video = true}})
  step(two, 100)
  check(player(J) and player(J).opts.file == 1 and player(J).opts.torrent.magnet == J.mock.torrents[1].magnet,
    "peer opened the file")
  H.ns.PARTY.stop(); step(two, 5)
  check(J.mock.torrents[1].closed and H.mock.torrents[#H.mock.torrents].closed, "torrents closed at the end")
end

-- Members adding to the queue (Holo 1.1). A runs the party; B (and C) are members. The names are "NA", "NB", ...
local function runLobby(ids, filter)
  local ms = {}
  for _, id in ipairs(ids) do ms[#ms + 1] = machine(id) end
  lobby(ms, ids[1]); step(ms, 1, filter); connect(ms); step(ms, 6, filter)
  return ms
end

-- A starts a party with VID1 and B joins it.
local function runParty(ids, filter)
  local ms = runLobby(ids, filter)
  ms[1].ns.QUEUE.add(VID1)
  check(ms[1].ns.PARTY.start() == true, "party started")
  step(ms, 8, filter)
  return ms
end

local function addrOf(m, to, n)
  local out
  for _, r in ipairs(sentOf(m, "addr", to)) do
    if r.tbl.n == n then out = r.tbl end
  end
  return out
end

local function recordResults(m)
  local res = {}
  m.ns.U.on("party.addResult", function(ok, why, c, ti) res[#res + 1] = {ok = ok, why = why, c = c, ti = ti} end)
  return res
end

-- 11. before the party starts: cap add = false, adding is "not-running", a raw add is refused
do
  local ms = runLobby{"A", "B"}
  local A, B = ms[1], ms[2]
  local caps = sentOf(A, "cap", "B")
  check(#caps >= 1 and caps[#caps].tbl.add == false and caps[#caps].tbl.music == true, "cap add=false before the party")
  check(B.ns.PARTY.hostCaps() ~= nil and B.ns.PARTY.hostCaps().add == false and not B.ns.PARTY.canAdd(),
    "B cannot add before the party")
  check(B.ns.PARTY.addWhyNot() == "not-running" and select(2, B.ns.QUEUE.add(VID2)) == "not-running",
    "B: not-running")
  A.mock.peerDeliver("B", {t = "add", n = 1, u = VID2})
  step(ms, 5)
  local r = addrOf(A, "B", 1)
  check(r and r.ok == false and r.why == "not-running" and A.ns.QUEUE.count() == 0, "a raw add before the party is refused")
end

-- 1. a member adds a video while the party runs: attribution, mirror, the answer
do
  local ms = runParty{"A", "B"}
  local A, B = ms[1], ms[2]
  local caps = sentOf(A, "cap", "B")
  check(caps[#caps].tbl.add == true and caps[#caps].tbl.music == true, "cap add=true once the party runs")
  check(B.ns.PARTY.hostCaps().add == true and B.ns.PARTY.canAdd() and B.ns.PARTY.addWhyNot() == nil, "B can add")
  local res = recordResults(B)
  local ok, why = B.ns.QUEUE.add("https://youtu.be/vid00000002")
  check(ok == true and why == "sent", "add is sent to the host")
  step(ms, 60)
  local q = A.ns.QUEUE.items()
  check(#q == 2 and q[2].url == "https://www.youtube.com/watch?v=vid00000002" and q[2].by == "NB" and q[2].byId == "B"
    and q[1].by == nil, "A queued it, attributed to B")
  check(B.ns.QUEUE.count() == 2 and B.ns.QUEUE.items()[2].by == "NB" and B.ns.QUEUE.items()[2].byId == "B"
    and B.ns.QUEUE.items()[2].id == q[2].id, "B's mirror shows it with the adder")
  check(#res == 1 and res[1].ok == true and res[1].c == 1 and res[1].ti == "YouTube video", "B got party.addResult(true)")
  check(#A.mock.resolves >= 1 and A.mock.resolves[#A.mock.resolves].url == q[2].url, "the host resolved the title")
  local t = lastEvent(A, "party.toast")
  check(t and t[2]:find("NB added", 1, true), "the host sees who added: " .. tostring(t and t[2]))
  check(B.ns.QUEUE.count() == 2 and select(2, B.ns.QUEUE.add("https://youtu.be/vid00000002")) == "dup",
    "B sees a duplicate locally")
  check(#B.mock.logsOf("error") == 0 and #A.mock.logsOf("error") == 0, "no errors")
end

-- 2. whoAdds = host: cap add=false, B is refused, a raw add is refused
do
  local ms = runParty{"A", "B"}
  local A, B = ms[1], ms[2]
  A.wum.config.set("whoAdds", "host")
  step(ms, 60)
  local caps = sentOf(A, "cap", "B")
  check(caps[#caps].tbl.add == false, "whoAdds=host broadcasts cap add=false")
  check(B.ns.PARTY.hostCaps().add == false and not B.ns.PARTY.canAdd(), "B can no longer add")
  check(select(2, B.ns.QUEUE.add(VID2)) == "host-only", "B: host-only")
  A.mock.peerDeliver("B", {t = "add", n = 1, u = VID2})
  step(ms, 5)
  local r = addrOf(A, "B", 1)
  check(r and r.ok == false and r.why == "host-only" and A.ns.QUEUE.count() == 1, "a raw add gets host-only")
  A.wum.config.set("whoAdds", "anyone")
  step(ms, 60)
  check(B.ns.PARTY.canAdd(), "back to anyone: B can add again")
end

-- 3. rate limit: one add per member per 1.5 s
do
  local ms = runParty{"A", "B"}
  local A = ms[1]
  A.mock.peerDeliver("B", {t = "add", n = 1, u = VID2})
  A.mock.peerDeliver("B", {t = "add", n = 2, u = VID3})
  step(ms, 5)
  local r1, r2 = addrOf(A, "B", 1), addrOf(A, "B", 2)
  check(r1 and r1.ok == true and r2 and r2.ok == false and r2.why == "rate", "the second add within 1.5 s is rate limited")
  check(A.ns.QUEUE.count() == 2, "only one was queued")
  step(ms, 100)
  A.mock.peerDeliver("B", {t = "add", n = 3, u = VID3})
  step(ms, 5)
  check(addrOf(A, "B", 3).ok == true and A.ns.QUEUE.count() == 3, "accepted again after 1.5 s")
  -- malformed nonces are ignored without an answer
  local n0 = #sentOf(A, "addr", "B")
  step(ms, 100)
  A.mock.peerDeliver("B", {t = "add", n = 0, u = VID2})
  A.mock.peerDeliver("B", {t = "add", n = 1.5, u = VID2})
  A.mock.peerDeliver("B", {t = "add", n = 2 ^ 31, u = VID2})
  A.mock.peerDeliver("B", {t = "add", u = VID2})
  step(ms, 5)
  check(#sentOf(A, "addr", "B") == n0, "bad nonces get no answer")
end

-- 4. bad and duplicate urls, the per-member limit, a full queue
do
  local ms = runParty{"A", "B"}
  local A = ms[1]
  local function raw(n, tbl)
    tbl.t, tbl.n = "add", n
    A.mock.peerDeliver("B", tbl)
    step(ms, 100)
    return addrOf(A, "B", n)
  end
  check(raw(1, {u = "http://evil.example/x"}).why == "unsupported-url", "unsupported url")
  check(raw(2, {u = 42}).why == "unsupported-url", "non-string url")
  check(raw(3, {u = "https://youtu.be/" .. string.rep("a", 5000)}).why == "unsupported-url", "over-long url")
  check(raw(4, {u = VID2}).ok == true, "a good url")
  check(raw(5, {u = VID2}).why == "dup", "a duplicate")
  check(raw(6, {u = VID1}).why == "dup", "a duplicate of the host's item")
  check(A.ns.QUEUE.count() == 2, "only the good one was added")
  local classify = A.wum.media.classify
  for i = 1, 49 do
    A.ns.QUEUE.addFor(classify(string.format("https://youtu.be/vid%08d", 100 + i)), {by = "NB", byId = "B"},
      function() end)
  end
  check(A.ns.QUEUE.countBy("B") == 50, "B has 50 items")
  local r = raw(7, {u = VID3})
  check(r.ok == false and r.why == "member-full", "51st item of one member: member-full")
  for i = 1, 200 do
    if A.ns.QUEUE.count() >= 200 then break end
    A.ns.QUEUE.add(string.format("https://youtu.be/vid%08d", 500 + i))
  end
  check(A.ns.QUEUE.count() == 200, "queue filled to 200")
  r = raw(8, {u = "https://youtu.be/vid00000999"})
  check(r.ok == false and r.why == "full", "full queue: full")
end

-- 5. a playlist is resolved by the host, every item attributed, c = items added
do
  local ms = runParty{"A", "B"}
  local A, B = ms[1], ms[2]
  local res = recordResults(B)
  local ok, why = B.ns.QUEUE.add("https://www.youtube.com/playlist?list=PL123")
  check(ok == true and why == "sent", "playlist request sent")
  step(ms, 5)
  local n0 = #A.mock.resolves
  check(n0 >= 1 and A.mock.resolves[n0].url == "https://www.youtube.com/playlist?list=PL123", "the host resolves it")
  check(A.ns.QUEUE.count() == 1 and #res == 0, "nothing queued until the resolve is done")
  A.mock.resolveDone({title = "Mix", items = {
    {url = "https://youtu.be/vid00000011", title = "One", duration = 10},
    {url = "https://youtu.be/vid00000012", title = "Two", duration = 20},
    {url = "https://youtu.be/vid00000013", title = "Three", duration = 30}}})
  step(ms, 60)
  local q = A.ns.QUEUE.items()
  check(#q == 4 and q[2].by == "NB" and q[3].by == "NB" and q[4].byId == "B" and q[3].title == "Two",
    "three items, all attributed to B")
  check(#res == 1 and res[1].ok == true and res[1].c == 3, "addr c == 3")
  check(B.ns.QUEUE.count() == 4, "mirrored")
  -- a private playlist
  step(ms, 100)
  B.ns.QUEUE.add("https://www.youtube.com/playlist?list=PLprivate")
  step(ms, 5)
  A.mock.resolveDone({error = "private"})
  step(ms, 10)
  check(#res == 2 and res[2].ok == false and res[2].why == "private", "private playlist reported")
  -- the per-member limit trims a playlist
  for i = 1, 45 do
    A.ns.QUEUE.addFor(A.wum.media.classify(string.format("https://youtu.be/vid%08d", 100 + i)), {by = "NB", byId = "B"},
      function() end)
  end
  check(A.ns.QUEUE.countBy("B") == 48, "B has 48 items")
  step(ms, 100)
  B.ns.QUEUE.add("https://www.youtube.com/playlist?list=PLbig")
  step(ms, 5)
  local items = {}
  for i = 1, 6 do items[i] = {url = string.format("https://youtu.be/vid%08d", 700 + i), title = "T" .. i} end
  A.mock.resolveDone({items = items})
  step(ms, 10)
  check(A.ns.QUEUE.countBy("B") == 50 and res[3].ok == true and res[3].c == 2 and res[3].why == "member-full",
    "a playlist is trimmed to the member limit")
end

-- 6. a magnet with a file: the member reads the file list locally and sends {u, f, ti}
do
  local ms = runParty{"A", "B"}
  local A, B = ms[1], ms[2]
  local res = recordResults(B)
  local pick, sent
  B.ns.U.on("queue.pick", function(token) pick = token end)
  B.ns.U.on("party.addSent", function(title) sent = title end)
  check(B.ns.QUEUE.add(MAGNET) == true, "magnet accepted locally")
  check(#B.mock.torrents == 1, "B opened the torrent for its file list")
  B.mock.torrentFiles({{index = 0, path = "a.mkv", size = 5, video = true},
    {index = 1, path = "dir/b.mkv", size = 9, video = true}, {index = 2, path = "n.txt", size = 99, video = false}})
  check(pick ~= nil, "queue.pick on B")
  local before = #sentOf(B, "add", "A")
  local ok = B.ns.QUEUE.pickFile(pick, 0)
  check(ok == true and sent == "a", "pickFile sends it to the host")
  step(ms, 5)
  local adds = sentOf(B, "add", "A")
  check(#adds == before + 1 and adds[#adds].tbl.u == "magnet:?xt=urn:btih:" .. string.rep("ab", 20) and adds[#adds].tbl.f == 0
    and adds[#adds].tbl.ti == "a", "add{u, f, ti}")
  step(ms, 60)
  local it = A.ns.QUEUE.items()[2]
  check(it and it.kind == "bt" and it.file == 0 and it.by == "NB" and it.title == "a", "A appended a bt item with that file")
  check(#A.mock.torrents == 0, "the host opened no torrent for it")
  check(B.mock.torrents[1].closed, "B closed its local torrent")
  check(#res == 1 and res[1].ok == true, "B got the answer")
  check(B.ns.QUEUE.count() == 2 and B.ns.QUEUE.items()[2].kind == "bt", "mirrored")
end

-- 7. a magnet without a file (the member has no media pack): the host opens it and takes the largest video
do
  local ms = runParty{"A", "B"}
  local A, B = ms[1], ms[2]
  B.mock.pack.state = "missing"
  local res = recordResults(B)
  local picked
  A.ns.U.on("queue.pick", function() picked = true end)
  B.ns.U.on("queue.pick", function() picked = true end)
  local ok, why = B.ns.QUEUE.add(MAGNET)
  check(ok == true and why == "sent" and #B.mock.torrents == 0, "B sends the bare link")
  step(ms, 5)
  local adds = sentOf(B, "add", "A")
  check(#adds >= 1 and adds[#adds].tbl.f == nil, "no file in the add")
  check(#A.mock.torrents == 1 and A.ns.QUEUE.count() == 1, "the host opened the torrent and waits")
  A.mock.torrentFiles({{index = 0, path = "a.mkv", size = 5, video = true},
    {index = 1, path = "big.mkv", size = 9, video = true}, {index = 2, path = "n.txt", size = 99, video = false}})
  step(ms, 60)
  local it = A.ns.QUEUE.items()[2]
  check(it and it.kind == "bt" and it.file == 1 and it.title == "big" and it.byId == "B", "the largest video was picked")
  check(not picked, "no picker anywhere")
  check(#res == 1 and res[1].ok == true and res[1].ti == "big", "B got the title")
  -- a torrent without a video file
  step(ms, 100)
  B.ns.QUEUE.add("magnet:?xt=urn:btih:" .. string.rep("cd", 20))
  step(ms, 5)
  A.mock.torrentFiles({{index = 0, path = "n.txt", size = 99, video = false}})
  step(ms, 10)
  check(#res == 2 and res[2].ok == false and res[2].why == "no-video", "no-video reported")
  check(A.mock.torrents[#A.mock.torrents].closed, "the host closed the useless torrent")
end

-- 7b. members' magnets without a file hold at most 2 torrents on the host ("host-busy" beyond), and one whose file
-- list does not come within 40 s is refused ("torrent-slow") and closed: dead magnets cannot take the host's slots.
do
  local ms = runParty{"A", "B"}
  local A, B = ms[1], ms[2]
  B.mock.pack.state = "missing"
  local res = recordResults(B)
  local function mag(n) return "magnet:?xt=urn:btih:" .. string.rep(string.format("%02x", n), 20) end
  B.ns.QUEUE.add(mag(1))
  step(ms, 100)
  B.ns.QUEUE.add(mag(2))
  step(ms, 100)
  check(#A.mock.torrents == 2 and #res == 0, "two members' magnets wait on the host")
  B.ns.QUEUE.add(mag(3))
  step(ms, 10)
  check(#res == 1 and res[1].ok == false and res[1].why == "host-busy" and #A.mock.torrents == 2, "a third: host-busy")
  check(A.ns.QUEUE.add(mag(9)) == true and #A.mock.torrents == 3, "the host still opens its own magnet")
  step(ms, 37 * 60)
  check(#res == 1, "still waiting before 40 s")
  step(ms, 3 * 60)
  check(#res == 3 and res[2].why == "torrent-slow" and res[3].why == "torrent-slow", "refused after 40 s: "
    .. tostring(res[2] and res[2].why))
  check(A.mock.torrents[1].closed and A.mock.torrents[2].closed, "their torrents are closed")
  check(not A.mock.torrents[3].closed, "the host's own pick keeps its torrent")
  -- a file list that comes late adds nothing and answers nothing
  A.mock.torrentFiles({{index = 0, path = "late.mkv", size = 5, video = true}}, 1)
  step(ms, 10)
  check(#res == 3 and A.ns.QUEUE.count() == 1, "a late file list is ignored")
  check(#A.mock.logsOf("error") == 0, "no errors")
end

-- 8. rm: a member removes what it added, nothing else
do
  local ms = runParty{"A", "B"}
  local A, B = ms[1], ms[2]
  B.ns.QUEUE.add(VID2)
  step(ms, 60)
  local mine = B.ns.QUEUE.items()[2]
  local hosts = B.ns.QUEUE.items()[1]
  check(mine and mine.byId == "B" and hosts.byId == nil, "B sees which item is its own")
  check(select(2, B.ns.PARTY.requestRemove(hosts.id)) == "not-yours", "B cannot ask to remove the host's item")
  A.mock.peerDeliver("B", {t = "rm", id = hosts.id})
  step(ms, 5)
  check(A.ns.QUEUE.count() == 2, "a raw rm of the host's item is ignored")
  -- the item that plays is B's: removing it plays the next
  step(ms, 40)
  A.ns.PARTY.next()
  step(ms, 5)
  check(A.ns.PARTY.currentId() == mine.id, "B's item is playing")
  check(B.ns.PARTY.requestRemove(mine.id) == true, "B asks to remove its own item")
  step(ms, 60)
  check(A.ns.QUEUE.count() == 1 and A.ns.QUEUE.find(mine.id) == nil, "the host removed it")
  check(A.ns.PARTY.currentId() == hosts.id and A.ns.PARTY.role() == "host", "the next item plays")
  check(B.ns.QUEUE.count() == 1, "B's mirror is updated")
  -- a bad id is ignored
  step(ms, 40)
  A.mock.peerDeliver("B", {t = "rm", id = "x"})
  A.mock.peerDeliver("B", {t = "rm"})
  step(ms, 5)
  check(A.ns.QUEUE.count() == 1 and #A.mock.logsOf("error") == 0, "malformed rm ignored")
end

-- 9. a 1.0 host: no cap arrives, so the member never sends an add
do
  local function noCap(_, _, tbl) return tbl.t ~= "cap" end
  local ms = runParty({"A", "B"}, noCap)
  local A, B = ms[1], ms[2]
  step(ms, 5, noCap)
  check(B.ns.PARTY.role() == "peer" and B.ns.PARTY.hostCaps() == nil, "joined, no caps")
  check(not B.ns.PARTY.canAdd() and B.ns.PARTY.addWhyNot() == "old-host", "old-host")
  check(select(2, B.ns.QUEUE.add(VID2)) == "old-host" and #sentOf(B, "add") == 0, "no add is sent")
  check(select(2, B.ns.PARTY.requestRemove(1)) == "not-yours", "nothing to remove")
  check(A.ns.QUEUE.count() == 1, "the host's queue is untouched")
end

-- 10. no answer from the host for 45 s
do
  local ms = runParty{"A", "B"}
  local B = ms[2]
  local res = recordResults(B)
  check(B.ns.QUEUE.add(VID2) == true, "sent")
  -- the host never answers: advance only B's clock
  for _ = 1, 44 do B.mock.frame(1) end
  check(#res == 0, "still waiting at 44 s")
  for _ = 1, 3 do B.mock.frame(1) end
  check(#res == 1 and res[1].ok == false and res[1].why == "no-answer", "party.addResult(false, no-answer)")
  -- a late or unknown answer is ignored
  B.mock.peerDeliver("A", {t = "addr", n = 1, ok = true})
  B.mock.peerDeliver("A", {t = "addr", n = 99, ok = true})
  B.mock.frame()
  check(#res == 1, "answers for unknown requests are ignored")
  -- and a second add inside a second is rate limited on the peer
  local ok1 = B.ns.PARTY.requestAdd{u = VID3}
  local ok2, why2 = B.ns.PARTY.requestAdd{u = VID3}
  check(ok1 == true and ok2 == nil and why2 == "rate", "peer side rate limit")
end

-- music: a refused suppress (the audio hook not in yet) is retried until it takes
do
  local M = machine("M")
  M.mock.musicUnavailable = true
  M.ns.QUEUE.add(VID1)
  check(M.ns.PARTY.start() == true, "started with the music hook unavailable")
  step({M}, 2)
  check(M.mock.music == nil or M.mock.music.requested ~= true, "music not suppressed yet")
  M.mock.musicUnavailable = false
  step({M}, 200)
  check(M.mock.music and M.mock.music.requested == true, "music suppressed once the hook is in")
end

if fails > 0 then
  io.stderr:write(fails .. " check(s) failed\n")
  os.exit(1)
end
print("test_party: all checks passed")
