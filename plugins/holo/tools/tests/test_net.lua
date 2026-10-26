-- NET (src/30_net.lua): the lobby view, presence parse, the channel, the message filter and the paced outbox.
local MW = require("mock_wum")

local fails = 0
local function check(cond, what)
  if not cond then
    fails = fails + 1
    io.stderr:write("  FAIL: " .. what .. "\n")
  end
end

local function loadHolo(mutate)
  local wum, mock = MW.new()
  wum._holoTest = {}
  if mutate then mutate(wum, mock) end
  local _, ok, err = MW.load("mod/client/init.lua", wum)
  check(ok, "init.lua runs: " .. tostring(err))
  return wum, mock, wum._holoTest.ns
end

local LOBBY = {lobby = "L", me = "A", owner = "A", isHost = true, members = {
  {id = "A", name = "Alice", me = true, host = true, melange = "0.12.0", peer = true},
  {id = "B", name = "Bob", melange = "0.12.0", peer = true},
  {id = "C", name = "Carol", melange = "0.12.0", peer = false},
  {id = "D", name = "Dan"}}}

-- 1. presence parse
do
  local _, _, ns = loadHolo()
  local P = ns.NET.parsePresence
  check(P(nil) == nil and P("x") == nil, "non-table presence")
  check(P({pack = "ready"}).pack == "ready" and P({pack = "missing"}).pack == "missing", "pack states")
  local d = P({pack = "downloading:42"})
  check(d.pack == "downloading" and d.progress == 42, "downloading percent")
  check(P({pack = "downloading:420"}).pack == nil and P({pack = "downloading:x"}).pack == nil, "bad percent")
  check(P({pack = "hacked"}).pack == nil and P({pack = 5}).pack == nil, "unknown pack")
  local h = P({party = 1, title = "  A\nvery long title " .. string.rep("x", 200), n = 999})
  check(h.party == true and utf8.len(h.title) == 60 and h.title:sub(1, 2) == "A " and h.n == 200, "host presence")
  check(P({title = "t", n = 3}).title == nil, "title only with a party")
  check(P({party = 1, n = 0 / 0}).n == nil, "NaN count dropped")
  check(ns.NET.packPresence({state = "ready"}) == "ready", "packPresence ready")
  check(ns.NET.packPresence({state = "downloading", progress = 0.426}) == "downloading:42", "packPresence pct")
  check(ns.NET.packPresence({state = "error"}) == "missing" and ns.NET.packPresence(nil) == "missing",
    "packPresence missing")
end

-- 2. lobby view, members, host rules
do
  local wum, mock, ns = loadHolo()
  local NET, U = ns.NET, ns.U
  check(NET.isHost() and NET.hostId() == nil and not NET.inSession(), "no session: solo host")
  check(#NET.members() == 0, "no members outside a session")
  -- this machine publishes its pack state
  check(mock.channel.presenceMine and mock.channel.presenceMine.pack == "ready", "own presence published")
  local changed = 0
  U.on("lobby.changed", function() changed = changed + 1 end)
  local entered = 0
  U.on("net.enter", function() entered = entered + 1 end)
  mock.setLobby(LOBBY)
  mock.frame()
  check(entered == 1 and changed >= 1 and NET.inSession() and NET.isHost() and NET.hostId() == "A", "entered")
  mock.channel.presences.B = {pack = "downloading:10"}
  mock.channel.clocks.B = {offset = 5, rtt = 31.6, samples = 4}
  mock.channel.presences.C = {pack = "ready"}
  mock.frames(40)
  local ms = NET.members()
  check(#ms == 4, "four members")
  local byId = {}
  for _, m in ipairs(ms) do byId[m.id] = m end
  check(byId.A.me and byId.A.host and byId.A.holo and byId.A.pack == "ready", "me")
  check(byId.B.holo and byId.B.pack == "downloading" and byId.B.progress == 10 and byId.B.rtt == 32, "B")
  check(byId.C.holo and byId.C.pack == "ready", "C has Holo (presence) without the channel open")
  check(not byId.D.holo and byId.D.pack == nil, "D has no Holo")
  check(NET.name("B") == "Bob" and NET.name("Z") == "?", "names")
  local before = changed
  mock.channel.presences.B = {pack = "ready"}
  mock.frames(40)
  check(changed == before + 1, "a presence change emits lobby.changed once")
  -- owner change and leave
  local owners = {}
  U.on("net.owner", function(o, isHost) owners[#owners + 1] = tostring(o) .. tostring(isHost) end)
  local l2 = MW.deepcopy(LOBBY)
  l2.owner, l2.isHost = "B", false
  mock.setLobby(l2)
  mock.frame()
  check(owners[1] == "Bfalse" and not NET.isHost() and NET.hostId() == "B", "owner change")
  local left = 0
  U.on("net.leave", function() left = left + 1 end)
  mock.setLobby(nil)
  mock.frame()
  check(left == 1 and not NET.inSession() and NET.isHost(), "leave")
end

-- 3. host presence fields
do
  local _, mock, ns = loadHolo()
  ns.NET.setPresence{party = true, title = string.rep("t", 100), n = 3}
  local p = mock.channel.presenceMine
  check(p.party == 1 and #p.title == 60 and p.n == 3 and p.pack == "ready", "party presence")
  ns.NET.setPresence{party = false}
  p = mock.channel.presenceMine
  check(p.party == nil and p.title == nil and p.pack == "ready", "party presence cleared")
end

-- 4. message filter: only lobby members, never myself, only tables with a string t
do
  local _, mock, ns = loadHolo()
  local got = {}
  ns.U.on("net.msg", function(from, m) got[#got + 1] = from .. ":" .. m.t end)
  mock.setLobby(LOBBY)
  mock.frame()
  mock.peerDeliver("B", {t = "hi"})
  mock.peerDeliver("Z", {t = "hi"})        -- not a member
  mock.peerDeliver("A", {t = "hi"})        -- myself
  mock.peerDeliver("B", {x = 1})           -- no type
  mock.peerDeliver("B", {t = 5})
  check(table.concat(got, ",") == "B:hi", "filter: " .. table.concat(got, ","))
end

-- 5. the outbox: paced per destination, keyed messages coalesce, rate refusals are retried, drop by key
do
  local _, mock, ns = loadHolo()
  local NET = ns.NET
  mock.setLobby(LOBBY)
  mock.frame()
  mock.setPeers({"B", "C"})
  local base = #mock.peerSent
  for i = 1, 30 do NET.post("B", {t = "x", n = i}) end
  mock.frame()
  check(#mock.peerSent - base == 8, "8 messages in the first second: " .. (#mock.peerSent - base))
  mock.frames(30)
  check(#mock.peerSent - base == 8, "still 8 within the second")
  mock.frames(35)
  check(#mock.peerSent - base == 16, "8 more in the next second: " .. (#mock.peerSent - base))
  mock.frames(200)
  check(#mock.peerSent - base == 30 and NET.pending("B") == 0, "all sent, in order")
  local inOrder = true
  for i = 1, 30 do inOrder = inOrder and mock.peerSent[base + i].tbl.n == i end
  check(inOrder, "order kept")
  -- byte pacing: big pages leave at most ~6000 B a second
  base = #mock.peerSent
  for i = 1, 4 do NET.post("B", {t = "q", page = i, blob = string.rep("z", 3000)}, "q" .. i) end
  mock.frame()
  check(#mock.peerSent - base == 1, "byte budget: " .. (#mock.peerSent - base))
  mock.frames(250)
  check(#mock.peerSent - base == 4, "big pages drain")
  -- coalescing: a newer keyed message replaces the queued one
  base = #mock.peerSent
  for i = 1, 12 do NET.post("C", {t = "pad", n = i}) end
  NET.post("C", {t = "st", e = 1}, "st")
  NET.post("C", {t = "st", e = 2}, "st")
  mock.frames(200)
  local sts = {}
  for i = base + 1, #mock.peerSent do
    local r = mock.peerSent[i]
    if r.tbl.t == "st" then sts[#sts + 1] = r.tbl.e end
  end
  check(#sts == 1 and sts[1] == 2, "keyed st coalesced: " .. table.concat(sts, ","))
  -- drop by key pattern
  for i = 1, 12 do NET.post("C", {t = "pad"}) end
  NET.post("C", {t = "q", page = 1}, "q1")
  NET.post("C", {t = "q", page = 2}, "q2")
  NET.drop("C", "^q%d")
  base = #mock.peerSent
  mock.frames(200)
  local qs = 0
  for i = base + 1, #mock.peerSent do if mock.peerSent[i].tbl.t == "q" then qs = qs + 1 end end
  check(qs == 0, "dropped pages never leave")
  -- "rate" refusals stay queued and go later
  local realSend = mock.channel.send
  local refuse = 3
  mock.channel.send = function(self, id, tbl, o)
    if refuse > 0 then refuse = refuse - 1; return false, "rate" end
    return realSend(self, id, tbl, o)
  end
  base = #mock.peerSent
  NET.post("B", {t = "late"})
  mock.frames(5)
  check(#mock.peerSent == base and refuse == 2, "refused, then left alone until the next window")
  mock.frames(200)
  check(#mock.peerSent == base + 1 and mock.peerSent[base + 1].tbl.t == "late", "sent after the refusals")
  mock.channel.send = realSend
  -- a member that goes away loses its queue
  for i = 1, 20 do NET.post("C", {t = "pad"}) end
  mock.setPeers({"B"})
  check(NET.pending("C") == 0, "queue dropped when the peer goes down")
  -- postAll reaches every reachable member
  check(NET.postAll({t = "all"}) == 1, "postAll count")
end

-- 6. sizeOf is an over-estimate of the payload, so a page under 7000 fits the 8 KB reliable cap
do
  local _, _, ns = loadHolo()
  local s = ns.NET.sizeOf({t = "q", items = {{u = string.rep("m", 1024), ti = string.rep("t", 480)}}})
  check(s > 1024 + 480 and s < 1700, "sizeOf: " .. s)
end

-- 7. the channel opens later when wum.peer was unavailable at load
do
  local wum, mock, ns = loadHolo(function(_, m) m.peerUnavailable = true end)
  check(ns.NET.channel() == nil and select(2, ns.NET.available()) == "unavailable", "no channel at load")
  mock.peerUnavailable = false
  mock.frames(320)
  check(ns.NET.channel() ~= nil, "opened on a retry")
end

if fails > 0 then
  io.stderr:write(fails .. " check(s) failed\n")
  os.exit(1)
end
print("test_net: all checks passed")
