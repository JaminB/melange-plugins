-- Self-test of the mock itself, so later tests can trust its knobs.
local MW = require("mock_wum")
local wum, mock = MW.new()

local fails = 0
local function check(cond, what)
  if not cond then
    fails = fails + 1
    io.stderr:write("  FAIL: " .. what .. "\n")
  end
end

-- events are delivered at the next frame, in subscription order
local order = {}
wum.events.on("x", function(p) order[#order + 1] = "1:" .. p.v end)
wum.events.on("x", function(p) order[#order + 1] = "2:" .. p.v end)
mock.emit("x", {v = 7})
check(#order == 0, "emit is queued")
mock.frame()
check(table.concat(order, ",") == "1:7,2:7", "delivered in order at the next frame")
wum.events.emit("hello", {a = 1})
local got
wum.events.on("mod.holo.hello", function(p) got = p.a end)
mock.frame()
check(got == 1, "wum.events.emit prefixes mod.holo.")

-- timers on virtual time
local n = 0
wum.timers.every(0.5, function() n = n + 1 end)
local once = 0
wum.timers.after(1, function() once = once + 1 end)
mock.frames(120, 1 / 60) -- 2 s
check(n == 4, "every(0.5) fired 4 times in 2 s: " .. n)
check(once == 1, "after(1) fired once")

-- config defaults come from spice.json; set validates
check(wum.config.get("volume") == 70 and wum.config.get("keySetup") == "F6", "config defaults from spice.json")
check(not pcall(wum.config.set, "volume", 101), "config.set range")
check(not pcall(wum.config.set, "nope", 1), "config.set undeclared")
wum.config.set("volume", 40)
check(wum.config.get("volume") == 40, "config.set stores")

-- storage copies
local t = {a = {1, 2}}
wum.storage.set("k", t)
t.a[1] = 99
check(wum.storage.get("k").a[1] == 1, "storage copies on set")

-- hotkeys follow the real rule
check(not pcall(wum.ui.hotkey, "W", function() end), "bare letter hotkey refused")
local fired = 0
wum.ui.hotkey("F6", function() fired = fired + 1 end)
wum.ui.hotkey("Ctrl+Shift+P", function() fired = fired + 10 end)
mock.hotkey("F6"); mock.hotkey("Ctrl+Shift+P")
check(fired == 11, "hotkeys fire")

-- draw callbacks, recorders, regions, clicks
local clicked
wum.events.on("melange.input.mouse", function(p) if not p.down then clicked = p.region end end)
wum.draw.on("hud", function()
  wum.draw.hudRect(10, 10, 110, 60, 0xffffffff, true)
  wum.input.region("btn", 10, 10, 110, 60)
  wum.draw.hudClip(0, 0, 50, 50)
  wum.draw.hudText(0, 0, "hi", 0xff000000, 16)
  wum.draw.hudClipEnd()
end)
mock.frame()
check(#mock.drawCalls() == 4, "drawCalls records the frame: " .. #mock.drawCalls())
check(mock.drawOf("hudText")[1].clip == 1, "clip depth recorded")
check(mock.click(20, 20) == "btn" and clicked == "btn", "click hits the region and fires melange.input.mouse")
check(mock.click(500, 500) == nil, "click outside hits nothing")
check(wum.input.hover() == nil, "hover outside")
mock.cursorPos = {20, 20}
check(wum.input.hover() == "btn", "hover inside")
check(mock.instructionCount > 0, "instruction count measured")

-- media: install needs a gesture, classify, a player records calls and follow
mock.pack.state = "missing"
mock.frames(150) -- the click consent above has expired
check(select(2, wum.media.install()) == "gesture", "install needs a click")
mock.gesture(true)
check(wum.media.install() == true and wum.media.pack().state == "downloading", "install with a gesture")
check(wum.media.classify("https://youtu.be/dQw4w9WgXcQ").url == "https://www.youtube.com/watch?v=dQw4w9WgXcQ", "classify youtube")
check(select(2, wum.media.classify("http://evil.example/")) == "unsupported-url", "classify refuses")
local p = wum.media.open{url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"}
p:follow({e = 1, i = 1, s = "play", p = 3, r = 1, a = 0}, "111")
check(p.following.e == 1 and p.followHost == "111", "follow recorded")
p:close()
check(select(2, p:play()) == "closed", "closed player returns nil, closed")
local x0, y0, x1, y1 = wum.draw.media(p, 0, 0, 400, 400)
check(x0 == 0 and x1 == 400 and math.abs((y1 - y0) - 225) < 1e-6, "draw.media contain rect")

-- peer channel and lobby
check(wum.lobby.state() == nil and wum.lobby.isHost() == false, "no lobby")
local ch = wum.peer.open{version = 1}
check(ch ~= nil and select(2, wum.peer.open{version = 1}) == "busy", "one channel per mod")
local rx, ups = {}, {}
ch:on(function(from, tbl, meta) rx[#rx + 1] = {from, tbl, meta} end)
ch:onPeer(function(id, up) ups[#ups + 1] = id .. (up and "+" or "-") end)
check(select(2, ch:send("A", {x = 1})) == "no-peer", "send to unreachable")
mock.setPeers({"A", "B"})
check(ch:broadcast({m = 1}) == 2 and #mock.peerSent == 2, "broadcast reaches both")
mock.setPeers({"B"})
check(table.concat(ups, ",") == "A+,B+,A-", "onPeer: " .. table.concat(ups, ","))
mock.peerDeliver("B", {hello = true})
check(rx[1][1] == "B" and rx[1][2].hello and rx[1][3].reliable == true, "peerDeliver")
check(wum.peer.now() == mock.peerNow() and wum.peer.now() > 0, "peer clock follows virtual time")
local lobbyEv = {}
for _, n in ipairs{"enter", "leave", "owner", "phase"} do
  wum.events.on("melange.lobby." .. n, function() lobbyEv[#lobbyEv + 1] = n end)
end
mock.setLobby{lobby = "L", me = "A", owner = "A", isHost = true, members = {{id = "A", me = true, host = true}}}
mock.frame()
check(wum.lobby.isHost() and wum.lobby.state().phase == "lobby", "lobby state")
mock.setLobby{lobby = "L", me = "A", owner = "B", isHost = false, phase = "match", members = {{id = "A", me = true}}}
mock.setLobby(nil)
mock.frame()
check(table.concat(lobbyEv, ",") == "enter,owner,phase,leave",
  "lobby events: " .. table.concat(lobbyEv, ","))

-- game state and music
mock.setOnline(true)
mock.setTurn{team = 1, worm = 2, mine = true}
check(wum.game.online() and wum.game.turn().mine and wum.game.turn().index == 1, "turn state")
check(wum.game.ui().pause == false, "ui defaults")
check(wum.audio.music.suppress(true, {fade = 0.4}) == true and mock.music.requested and wum.audio.music.suppressed(), "music suppress")

if fails > 0 then
  io.stderr:write(fails .. " check(s) failed\n")
  os.exit(1)
end
print("test_mock: all checks passed")
