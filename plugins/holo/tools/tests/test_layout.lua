-- LAYOUT (src/50_layout.lua): the anchor table of design 2.4, the rects, the animation, the view, the fades and the
-- auto-hide gate (I3: auto-hide never mutes, the user's own hide does with hiddenMutes).
local MW = require("mock_wum")

local fails = 0
local function check(cond, what)
  if not cond then
    fails = fails + 1
    io.stderr:write("  FAIL: " .. what .. "\n")
  end
end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 0.01) end

-- The mock has no wum.game.inMatch; this test adds it, switched by `state.inMatch`.
local function loadHolo(mutate)
  local wum, mock = MW.new()
  local state = {inMatch = false}
  wum.game.inMatch = function() return state.inMatch end
  wum._holoTest = {}
  if mutate then mutate(wum, mock) end
  local _, ok, err = MW.load("mod/client/init.lua", wum)
  check(ok, "init.lua runs: " .. tostring(err))
  mock.frame()
  return wum, mock, wum._holoTest.ns, state
end

local LOBBY = {lobby = "L", me = "A", owner = "B", isHost = false, phase = "lobby", members = {
  {id = "A", name = "A", me = true, peer = true}, {id = "B", name = "B", host = true, peer = true}}}

local function onlineMatch(mock, state)
  local l = MW.deepcopy(LOBBY)
  l.phase = "match"
  mock.setLobby(l)
  mock.setOnline(true)
  state.inMatch = true
  mock.frame()
end

-- 1. the anchor table
do
  local wum, mock, ns, state = loadHolo()
  local L = ns.LAYOUT
  check(L.anchor() == "corner" and L.ruleAnchor() == "corner", "frontend: corner")
  mock.setLobby(LOBBY); mock.frame()
  check(L.ruleAnchor() == "corner", "lobby: corner")
  onlineMatch(mock, state)
  mock.setTurn{team = 1, worm = 1, mine = true}; mock.frames(2)
  check(L.anchor() == "corner", "online, my turn: corner")
  mock.setTurn{team = 2, worm = 1, mine = false}; mock.frames(2)
  check(L.anchor() == "half", "online, another player's turn: half")
  mock.setTurn{mine = false}; mock.frames(2)
  check(L.ruleAnchor() == nil and L.anchor() == "half", "between turns: keep the last anchor")
  mock.setTurn{team = 1, worm = 1, mine = true}; mock.setUI{readyIntro = true}; mock.frames(2)
  check(L.anchor() == "half", "Ready? intro: keep the last anchor")
  mock.setUI{readyIntro = false}; mock.frames(2)
  check(L.anchor() == "corner", "after the intro: corner on my turn")
  wum.config.set("bigOnOthers", false); mock.frames(31)
  mock.setTurn{team = 2, worm = 1, mine = false}; mock.frames(2)
  check(L.anchor() == "corner", "bigOnOthers off: corner")
  -- a local match: always corner
  local w2, m2, ns2, s2 = loadHolo()
  s2.inMatch = true
  m2.setTurn{team = 2, worm = 1, mine = false}; m2.frames(2)
  check(ns2.LAYOUT.anchor() == "corner", "local match: corner")
  -- results and loading of an online session: not a match, corner
  local l = MW.deepcopy(LOBBY)
  l.phase = "results"
  mock.setLobby(l); state.inMatch = false; mock.frames(2)
  check(L.ruleAnchor() == "corner", "results: corner")
end

-- 2. rects at 1080p, both sides, scaled
do
  local wum, mock, ns, state = loadHolo()
  local L = ns.LAYOUT
  local x0, y0, x1, y1 = L.rect()
  check(near(x1 - x0, 422.4) and near(y1 - y0, 237.6), "corner 422x238: " .. (x1 - x0) .. "x" .. (y1 - y0))
  check(near(x1, 1920 - 24 - 9) and near(y0, 24 + 9 + L.WIND_OFFSET), "corner top-right with margin and frame")
  local v, p = L.halfRects(1920, 1080, "right")
  check(near(v[3] - v[1], 888) and near(v[4] - v[2], 499.5), "half video 888x500")
  check(near(p[1], 984) and near(p[3], 1896) and near(p[4] - p[2], 44 + 499.5 + 64), "half panel with tag and bar")
  check(near((p[2] + p[4]) / 2, 540), "half panel centred")
  local lv = L.halfRects(1920, 1080, "left")
  check(near(lv[1], 36) and near(lv[3], 924), "left half")
  check(near(select(1, L.cornerRect(1920, 1080, "left")), 33), "left corner")
  wum.config.set("panelSide", "left"); mock.frames(31); mock.frames(30)
  check(L.side() == "left" and near(select(1, L.rect()), 33), "the side setting moves the player")
  -- 4K and a small window
  local a0, _, a1 = L.cornerRect(3840, 2160, "right")
  check(near(a1 - a0, 844.8), "4K corner")
  check(near(L.scale(), 1), "scale at 1080p")
  mock.window = {1024, 600}; mock.frame()
  check(near(L.scale(), 0.6), "scale clamps at 0.6")
  local sv = L.halfRects(1024, 600, "right")
  check(sv[4] - sv[2] <= 600 - 2 * 24 * 0.6 - (44 + 64) * 0.6 + 0.01, "half panel fits a short window")
  -- 4:3 (no 16:9 width): 22 % of the width
  local b0, _, b1 = L.cornerRect(1024, 768, "right")
  check(near(b1 - b0, 0.22 * 1024), "4:3 corner")
  wum.config.set("uiScale", 130); mock.frames(31)
  mock.window = {1920, 1080}; mock.frames(30)
  local c0, _, c1 = L.rect()
  check(near(c1 - c0, 422.4 * 1.3), "uiScale 130")
  local w, h = L.sizeHint()
  check(w == 549 and h == 309, "size hint scales: " .. w .. "x" .. h)
end

-- 3. animation between anchors: 0.35 s ease-out, the size hint once settled, controls fade back in
do
  local wum, mock, ns, state = loadHolo()
  local L, U = ns.LAYOUT, ns.U
  local sizes = {}
  U.on("layout.size", function(w, h) sizes[#sizes + 1] = w .. "x" .. h end)
  mock.frames(5)
  onlineMatch(mock, state)
  local c = {L.rect()}
  mock.setTurn{team = 2, worm = 1, mine = false}
  mock.frame()            -- event delivered, the animation starts
  check(L.anchor() == "half" and L.animating(), "animating")
  check(L.controlsAlpha() == 0, "controls hidden while animating")
  mock.frames(6)          -- 0.1 s
  local m = {L.rect()}
  local v = L.halfRects(1920, 1080, "right")
  check(m[1] < c[1] and m[1] > v[1], "midway")
  local k = (c[1] - m[1]) / (c[1] - v[1])
  check(k > 0.1 / 0.35, "ease-out runs ahead of linear: " .. k)
  check(#sizes == 0 or sizes[#sizes] == "422x238", "no new size while animating")
  mock.frames(20)
  check(not L.animating() and near(select(1, L.rect()), v[1]), "settled on the half rect")
  check(sizes[#sizes] == "960x540", "size hint after settling: " .. tostring(sizes[#sizes]))
  mock.frames(20)
  check(near(L.controlsAlpha(), 1), "controls faded back in")
  -- a resize snaps (no animation)
  mock.window = {1280, 720}; mock.frame()
  check(not L.animating() and near(L.rect(), L.halfRects(1280, 720, "right")[1]), "resize snaps")
end

-- 4. views
do
  local wum, mock, ns = loadHolo()
  local L, U = ns.LAYOUT, ns.U
  local views = {}
  U.on("layout.view", function(v) views[#views + 1] = v end)
  check(L.view() == "full", "default view")
  L.toggleHide(); check(L.view() == "hidden", "hide")
  L.toggleHide(); check(L.view() == "full", "show again")
  L.setView("pill"); L.toggleHide(); L.toggleHide()
  check(L.view() == "pill", "pill -> hidden -> pill")
  check(table.concat(views, ",") == "hidden,full,pill,hidden,pill", "view events: " .. table.concat(views, ","))
  check(L.setView("bogus") == false, "bad view refused")
  mock.frames(100)
  check(mock.storageData.prefs.view == "pill", "view remembered")
  L.setView("hidden"); mock.frames(20)
  check(L.alpha() == 0 and not L.interactive(), "hidden: nothing drawn, no regions")
  L.setView("full"); mock.frames(20)
  check(L.alpha() == 1 and L.interactive(), "shown again")
end

-- 5. fades: pause menu anywhere, weapon panel on my turn
do
  local wum, mock, ns, state = loadHolo()
  local L = ns.LAYOUT
  mock.setUI{pause = true}; mock.frames(15)
  check(near(L.alpha(), 0.3) and not L.interactive() and L.faded(), "pause: 30 %, no regions")
  mock.setUI{pause = false}; mock.frames(15)
  check(L.alpha() == 1 and L.interactive(), "pause closed")
  state.inMatch = true
  mock.setTurn{team = 1, worm = 1, mine = true}
  mock.setUI{weaponPanel = true}; mock.frames(15)
  check(near(L.alpha(), 0.3) and not L.interactive(), "weapon panel on my turn: 30 %")
  mock.setTurn{team = 2, worm = 1, mine = false}; mock.frames(15)
  check(L.alpha() == 1, "weapon panel flag on another's turn does not fade")
end

-- 6. the auto-hide gate
do
  local wum, mock, ns, state = loadHolo()
  local L = ns.LAYOUT
  state.inMatch = true
  mock.setTurn{team = 1, worm = 1, mine = true}; mock.frame()
  check(not L.autoHidden(), "my turn, walking: shown")
  mock.groups = {"InGame", "WormAiming"}; mock.frame()
  check(L.autoHidden() and not L.interactive(), "aiming group: auto-hidden")
  mock.frames(9)
  check(L.alpha() == 0, "faded out within 0.15 s")
  mock.groups = {"InGame", "WormFirstPersonAiming"}; mock.frame()
  check(L.autoHidden(), "first-person aiming")
  mock.groups = {"InGame", "UtilityFire"}; mock.frame()
  check(L.autoHidden(), "utility fire")
  mock.groups = {"InGame"}; mock.frame()
  check(not L.autoHidden(), "aim ended")
  mock.frames(10)
  check(L.alpha() == 1, "faded back in")
  -- fire held between pressed and released
  mock.emit("Input.FirePressed", {}); mock.frame()
  check(L.autoHidden(), "fire held")
  mock.emit("Input.FireReleased", {}); mock.frame()
  check(not L.autoHidden(), "fire released")
  -- the flight gate: Weapon.Fired until the explosions settle 0.6 s
  mock.emit("Weapon.Fired", {}); mock.frame()
  check(L.autoHidden(), "in flight")
  mock.frames(60)
  mock.emit("Explosion", {}); mock.frames(20)
  check(L.autoHidden(), "explosion: still settling")
  mock.emit("Explosion", {}); mock.frames(30)
  check(L.autoHidden(), "a second explosion restarts the quiet time")
  mock.frames(10)
  check(not L.autoHidden(), "settled 0.6 s after the last explosion")
  -- the retreat timer ends it
  mock.emit("Weapon.Fired", {}); mock.frame()
  mock.emit("Timer.StartRetreatTimer", {}); mock.frame()
  check(not L.autoHidden(), "retreat timer")
  -- the next turn ends it
  mock.emit("Weapon.Fired", {}); mock.frame()
  mock.setTurn{team = 1, worm = 2, mine = true}; mock.frame()
  check(not L.autoHidden(), "next turn")
  -- the 8 s failsafe
  mock.emit("Weapon.Fired", {}); mock.frame()
  mock.frames(60 * 7)
  check(L.autoHidden(), "still in flight at 7 s")
  mock.frames(70)
  check(not L.autoHidden(), "failsafe at 8 s")
  -- never on another player's turn, never with the setting off
  mock.setTurn{team = 2, worm = 1, mine = false}
  mock.groups = {"WormAiming"}; mock.frame()
  check(not L.autoHidden(), "not my turn: no auto-hide")
  mock.setTurn{team = 1, worm = 1, mine = true}; mock.frame()
  check(L.autoHidden(), "my turn again")
  wum.config.set("autoHideAim", false); mock.frames(31)
  check(not L.autoHidden(), "autoHideAim off")
  -- outside a match nothing auto-hides
  wum.config.set("autoHideAim", true); state.inMatch = false; mock.frames(31)
  check(not L.autoHidden(), "frontend: no auto-hide")
end

-- 7. I3: auto-hide never mutes; the user's own hide mutes with hiddenMutes and restores the mute after
do
  local wum, mock, ns, state = loadHolo()
  local L, P, Q = ns.LAYOUT, ns.PARTY, ns.QUEUE
  Q.add("https://youtu.be/dQw4w9WgXcQ")
  check(P.start() == true, "solo party")
  mock.frames(2)
  local p = mock.players[#mock.players]
  check(p and not p.muted, "playing, not muted")
  state.inMatch = true
  mock.setTurn{team = 1, worm = 1, mine = true}
  mock.groups = {"WormAiming"}; mock.frames(3)
  check(L.autoHidden() and not p.muted, "auto-hidden but not muted")
  mock.groups = {"InGame"}; mock.frames(3)
  L.toggleHide(); mock.frames(2)
  check(p.muted == true, "own hide mutes (hiddenMutes)")
  L.toggleHide(); mock.frames(2)
  check(p.muted == false, "shown again: mute restored")
  P.setMute(true); L.toggleHide(); mock.frames(2); L.toggleHide(); mock.frames(2)
  check(p.muted == true, "the user's own mute survives a hide and show")
  P.setMute(false)
  wum.config.set("hiddenMutes", false); mock.frames(31)
  L.toggleHide(); mock.frames(2)
  check(p.muted == false, "hiddenMutes off: hide keeps the sound")
end

if fails > 0 then
  io.stderr:write(fails .. " check(s) failed\n")
  os.exit(1)
end
print("test_layout: all checks passed")
