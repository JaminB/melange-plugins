-- PUI (src/80_player_ui.lua): the picture and its frame at the LAYOUT rect, the controls' show/hide timing and
-- their regions (never the corner's passive video area, nothing while faded), the corner and half-panel bars, the
-- popovers, the pill, the idle pills, and the read-only bar and pack button of a peer.
local MW = require("mock_wum")

local fails = 0
local function check(cond, what)
  if not cond then
    fails = fails + 1
    io.stderr:write("  FAIL: " .. what .. "\n")
  end
end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 0.5) end

local VID1, VID2 = "https://youtu.be/vid00000001", "https://youtu.be/vid00000002"

local function machine(id)
  local wum, mock = MW.new()
  wum._holoTest = {}
  local _, ok, err = MW.load("mod/client/init.lua", wum)
  check(ok, id .. ": init.lua runs: " .. tostring(err))
  return {id = id, wum = wum, mock = mock, ns = wum._holoTest.ns, sent = 0}
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

local function step(ms, n)
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
          if o.id == r.to then
            o.mock.peerDeliver(m.id, MW.deepcopy(r.tbl), {reliable = not (r.opts and r.opts.reliable == false)})
          end
        end
      end
    end
  end
end

local function regions(m)
  local out = {}
  for _, r in ipairs(m.mock.regions()) do out[r.id] = r end
  return out
end

local function center(r) return (r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2 end

local function clickRegion(m, id)
  local r = regions(m)[id]
  if not r then return nil end
  local x, y = center(r)
  local hit = m.mock.click(x, y)
  m.mock.frame()
  return hit
end

local function player(m) return m.mock.players[#m.mock.players] end

-- A solo party playing its first item (duration 100 s).
local function soloPlaying()
  local A = machine("A")
  A.ns.QUEUE.add(VID1)
  A.ns.QUEUE.add(VID2)
  A.ns.PARTY.start()
  A.mock.frame()
  local p = player(A)
  p._st.duration = 100
  A.mock.emit("melange.media", {type = "loaded", title = "One", duration = 100})
  A.mock.frames(30)
  return A, p
end

local function errorsOf(m)
  local e = m.mock.logsOf("error")
  return #e == 0, e[1]
end

-- 1. the picture at the corner rect, the frame after it, nothing claimed without a cursor
do
  local A, p = soloPlaying()
  check(A.ns.PARTY.phase() == "playing", "playing")
  local calls = A.mock.drawCalls()
  local mi, fi
  for i, c in ipairs(calls) do
    if c.fn == "media" and not mi then mi = i end
    if c.fn == "hudNine" and mi and not fi then fi = i end
  end
  check(mi ~= nil, "the player is drawn")
  local vx0, vy0, vx1, vy1 = A.ns.LAYOUT.rect()
  local m = calls[mi]
  check(m and m.args[1] == p and near(m.args[2], vx0) and near(m.args[5], vy1), "media at the LAYOUT rect")
  check(m and m.args[6].fit == "contain", "fit contain")
  check(fi and fi > mi, "the frame is drawn after the picture (its corners cover it)")
  check(next(regions(A)) == nil, "no regions without a cursor")
  -- a 4:3 picture: the frame hugs the returned rect
  p._st.aspect = 4 / 3
  A.mock.frame()
  local nine
  for _, c in ipairs(A.mock.drawCalls()) do if c.fn == "hudNine" then nine = c; break end end
  local px0 = vx0 + ((vx1 - vx0) - (vy1 - vy0) * 4 / 3) / 2
  check(nine and nine.args[1] < px0 and nine.args[1] > vx0 - 40, "the frame hugs a letterboxed picture")
  p._st.aspect = 16 / 9
  local ok, e = errorsOf(A)
  check(ok, "no errors: " .. tostring(e))
end

-- 2. controls: shown 100 ms after the cursor enters, hidden 1.5 s after it stops; only the bar is claimed
do
  local A, p = soloPlaying()
  local vx0, vy0, vx1, vy1 = A.ns.LAYOUT.rect()
  A.mock.cursorSource = "frontend"
  A.mock.cursorPos = {(vx0 + vx1) / 2, (vy0 + vy1) / 2}
  A.mock.frame(0.05)
  check(not regions(A)["pui.play"], "not yet after 50 ms")
  A.mock.frames(4, 0.03)
  local rs = regions(A)
  check(rs["pui.play"] and rs["pui.bar"], "controls after 100 ms")
  check(A.ns.PUI.controlsShown(), "controls shown")
  for id, r in pairs(rs) do
    check(r.y0 >= vy1 - 60, "corner: only the bar is claimed (" .. id .. " at " .. r.y0 .. ")")
  end
  -- play/pause
  check(clickRegion(A, "pui.play") == "pui.play", "click play")
  check(A.ns.PARTY.hostState().s == "pause", "paused by the bar")
  A.mock.frames(2)
  clickRegion(A, "pui.play")
  check(A.ns.PARTY.hostState().s == "play", "playing again")
  -- skip
  local t0 = p._st.time
  clickRegion(A, "pui.fwd10")
  check(near(p._st.time, t0 + 10, 1.5), "+10 s: " .. p._st.time)
  -- mute
  clickRegion(A, "pui.mute")
  check(A.ns.PARTY.muted() and p.muted == true, "muted")
  clickRegion(A, "pui.mute")
  check(not A.ns.PARTY.muted(), "unmuted")
  -- minimise to the pill
  clickRegion(A, "pui.min")
  check(A.ns.LAYOUT.view() == "pill", "minimised")
  A.mock.frames(2)
  check(regions(A)["pui.expand"], "the pill has an expand button")
  local pill = false
  for _, c in ipairs(A.mock.drawOf("hudNine")) do
    local r = A.ns.SKIN.atlas.panels.rects.pill
    if near(c.args[10].uv[1], r.x / 1024, 0.001) and near(c.args[10].uv[2], r.y / 600, 0.001) then pill = true end
  end
  check(pill, "the pill is drawn with the pill slice")
  -- the cursor sits on the pill's expand button
  local ex = regions(A)["pui.expand"]
  A.mock.cursorPos = {center(ex)}
  clickRegion(A, "pui.expand")
  check(A.ns.LAYOUT.view() == "full", "expanded")
  -- no motion for 1.5 s: hidden
  A.mock.cursorPos = {(vx0 + vx1) / 2, (vy0 + vy1) / 2}
  A.mock.frames(10, 0.03)
  check(regions(A)["pui.play"], "shown again")
  A.mock.frames(60, 0.03)
  check(not regions(A)["pui.play"] and not A.ns.PUI.controlsShown(), "hidden after 1.5 s without motion")
  A.mock.cursorPos = {(vx0 + vx1) / 2 + 3, (vy0 + vy1) / 2}
  A.mock.frames(5, 0.03)
  check(regions(A)["pui.play"], "a motion shows them again")
  -- faded under a pause menu: no regions
  A.mock.setUI{pause = true}
  A.mock.frames(30, 0.03)
  check(A.ns.LAYOUT.faded() and next(regions(A)) == nil, "faded: nothing claimed")
  A.mock.setUI{pause = false}
  A.mock.frames(20, 0.03)
  A.mock.cursorPos = {(vx0 + vx1) / 2, (vy0 + vy1) / 2 + 2}
  A.mock.frames(6, 0.03)
  check(regions(A)["pui.play"], "back after the pause menu")
  -- hidden by the hotkey: nothing drawn once faded out, and back
  A.mock.hotkey("F9")
  A.mock.frames(20, 0.03)
  check(#A.mock.drawOf("media") == 0 and next(regions(A)) == nil, "hidden: nothing drawn")
  check(p.muted == true, "hidden mutes (hiddenMutes)")
  A.mock.hotkey("F9")
  A.mock.frames(20, 0.03)
  check(#A.mock.drawOf("media") == 1 and p.muted == false, "shown again and unmuted")
end

-- 3. popovers from the corner: CC lists the tracks, "..." opens the rest
do
  local A, p = soloPlaying()
  p._st.tracks = {audio = {{id = 1, lang = "en", selected = true}, {id = 2, lang = "de"}},
    sub = {{id = 5, lang = "en", title = "English"}}}
  A.mock.frames(2)
  local vx0, vy0, vx1, vy1 = A.ns.LAYOUT.rect()
  A.mock.cursorSource = "frontend"
  A.mock.cursorPos = {(vx0 + vx1) / 2, (vy0 + vy1) / 2}
  A.mock.frames(6, 0.03)
  clickRegion(A, "pui.cc")
  A.mock.frame()
  local rs = regions(A)
  check(rs["pui.cc#1"] and rs["pui.cc#2"], "subtitle popover: Off and one track")
  A.mock.frames(60, 0.03)
  check(A.ns.W.popoverOpen() and regions(A)["pui.cc#2"], "an open popover keeps the controls up")
  clickRegion(A, "pui.cc#2")
  local last = p.calls[#p.calls]
  check(last and last[1] == "track" and last[2] == "sub" and last[3] == 5, "subtitle track picked")
  check(A.ns.U.pref("subLang") == "en", "remembered by language")
  A.mock.cursorPos = {(vx0 + vx1) / 2 + 1, (vy0 + vy1) / 2}
  A.mock.frames(6, 0.03)
  clickRegion(A, "pui.more")
  A.mock.frame()
  check(regions(A)["pui.more#3"], "more popover")
  clickRegion(A, "pui.more#3")   -- Speed: opens the speed list
  A.mock.frame()
  check(regions(A)["pui.speed#5"], "speed list")
  clickRegion(A, "pui.speed#5")
  check(A.ns.PARTY.hostState().r == 1.5 and p._st.speed == 1.5, "speed 1.5 for everyone")
  local ok, e = errorsOf(A)
  check(ok, "no errors: " .. tostring(e))
end

-- 4. host and peer in an online match: the half panel on another player's turn, the read-only bar
do
  local A, B = machine("A"), machine("B")
  local ms = {A, B}
  lobby(ms, "A")
  step(ms)
  connect(ms)
  step(ms, 2)
  A.ns.QUEUE.add(VID1)
  A.ns.PARTY.start()
  step(ms, 3)
  player(A)._st.duration = 100
  A.mock.emit("melange.media", {type = "loaded", duration = 100})
  step(ms, 40)
  check(B.ns.PARTY.role() == "peer", "B joined")
  local bp = player(B)
  bp._st.duration = 100
  bp._st.drift = 0.12
  B.mock.emit("melange.media", {type = "loaded", duration = 100})
  lobby(ms, "A", "match")
  for _, m in ipairs(ms) do m.mock.setOnline(true) end
  A.mock.setTurn{team = 2, worm = 1, mine = false}
  B.mock.setTurn{team = 2, worm = 1, mine = true}
  step(ms, 40)
  check(A.ns.LAYOUT.anchor() == "half" and B.ns.LAYOUT.anchor() == "corner", "half for A, corner for B")
  -- A: the panel and its bar; no cursor in a match until the pointer
  check(next(regions(A)) == nil, "no regions in a match without the pointer")
  A.mock.hotkey("F7")
  check(A.mock.pointerActive() and A.mock.pointerOpts.release == "click-outside", "pointer hotkey")
  check(A.mock.pointerOpts.cursor ~= nil, "the themed cursor")
  A.mock.cursorSource = "pointer"
  local px0, py0, px1, py1 = A.ns.LAYOUT.panelRect()
  A.mock.cursorPos = {(px0 + px1) / 2, (py0 + py1) / 2}
  step(ms, 8)
  local rs = regions(A)
  check(rs["pui.panel"] and rs["pui.seek"] and rs["pui.speed"] and rs["pui.queue"], "half panel claimed with its bar")
  local tags = 0
  for _, c in ipairs(A.mock.drawOf("hudText")) do if c.args[3] == "YouTube video" then tags = tags + 1 end end
  check(tags >= 1, "the title tag")
  -- seek on the bar: exact on release
  local sk = rs["pui.seek"]
  local grab = (sk.y1 - sk.y0) / 2.2 * 0.6
  local x = sk.x0 + grab + (sk.x1 - sk.x0 - 2 * grab) * 0.5
  A.mock.click(x, (sk.y0 + sk.y1) / 2)
  step(ms, 1)
  local pa = player(A)
  local seekCall
  for _, c in ipairs(pa.calls) do if c[1] == "seek" then seekCall = c end end
  check(seekCall and seekCall[3] == "exact" and near(seekCall[2], 50, 3), "seek to the middle: " ..
    tostring(seekCall and seekCall[2]))
  step(ms, 3)
  check(near(bp.following.p, 50, 3), "the peer follows the seek")
  -- B, the peer: read-only shared controls
  B.mock.hotkey("F7")
  B.mock.cursorSource = "pointer"
  local vx0, vy0, vx1, vy1 = B.ns.LAYOUT.rect()
  B.mock.cursorPos = {(vx0 + vx1) / 2, (vy0 + vy1) / 2}
  step(ms, 8)
  local brs = regions(B)
  check(brs["pui.play"] and not brs["pui.seek"], "peer: play shown (disabled), the seek bar is not claimed")
  local before = A.ns.PARTY.hostState().s
  clickRegion(B, "pui.play")
  step(ms, 2)
  check(A.ns.PARTY.hostState().s == before, "a peer's play click does nothing")
  clickRegion(B, "pui.mute")
  check(B.ns.PARTY.muted() and not A.ns.PARTY.muted(), "the peer's own mute")
  -- the peer's half panel shows the drift
  B.mock.setTurn{team = 2, worm = 1, mine = false}
  step(ms, 40)
  local drift = false
  for _, c in ipairs(B.mock.drawOf("hudText")) do
    if tostring(c.args[3]):find("+0.12 s", 1, true) then drift = true end
  end
  check(B.ns.LAYOUT.anchor() == "half" and drift, "drift shown to the peer")
  local marker = 0
  for _, c in ipairs(B.mock.drawOf("hudRect")) do if c.args[5] == 0xFFFFFFFF then marker = marker + 1 end end
  check(marker >= 1, "host marker on the peer's seek bar")
  local ok, e = errorsOf(B)
  check(ok, "no errors on B: " .. tostring(e))
  ok, e = errorsOf(A)
  check(ok, "no errors on A: " .. tostring(e))
end

-- 5. a peer without the media pack: the Download button installs it (the click is the consent)
do
  local A, B = machine("A"), machine("B")
  local ms = {A, B}
  B.mock.pack.state = "missing"
  lobby(ms, "A")
  step(ms)
  connect(ms)
  step(ms, 2)
  A.ns.QUEUE.add(VID1)
  A.ns.PARTY.start()
  step(ms, 40)
  check(B.ns.PARTY.phase() == "needs-pack", "peer needs the pack")
  B.mock.cursorSource = "frontend"
  local vx0, vy0, vx1, vy1 = B.ns.LAYOUT.rect()
  B.mock.cursorPos = {(vx0 + vx1) / 2, (vy0 + vy1) / 2}
  step(ms, 2)
  check(regions(B)["pui.pack"], "Download button")
  local r = regions(B)["pui.pack"]
  check((r.x1 - r.x0) * (r.y1 - r.y0) < 1920 * 1080 / 4, "the consent region is under a quarter of the window")
  local texts = {}
  for _, c in ipairs(B.mock.drawOf("hudText")) do texts[#texts + 1] = c.args[3] end
  local all = table.concat(texts, "\n")
  check(all:find("95 MB", 1, true) and all:find("GitHub", 1, true) and all:find("Documents", 1, true),
    "size, source and folder next to the button")
  clickRegion(B, "pui.pack")
  check(B.mock.installs == 1 and B.mock.pack.state == "downloading", "install started from the click")
  step(ms, 2)
  local dl = false
  for _, c in ipairs(B.mock.drawOf("hudText")) do
    if tostring(c.args[3]):find("Downloading", 1, true) then dl = true end
  end
  check(dl, "download progress shown")
end

-- 6. idle pills: Watch party in the lobby, Continue party for a new owner
do
  local A, B = machine("A"), machine("B")
  local ms = {A, B}
  lobby(ms, "A")
  step(ms)
  connect(ms)
  step(ms, 2)
  A.mock.cursorSource = "frontend"
  A.mock.cursorPos = {5, 5}
  step(ms, 2)
  check(regions(A)["pui.idle"], "Watch party pill in the lobby")
  clickRegion(A, "pui.idle")
  check(A.ns.PARTY.setupOpen(), "it opens the setup panel")
  A.ns.PARTY.setSetup(false)
  A.ns.QUEUE.add(VID1)
  A.ns.PARTY.start()
  step(ms, 20)
  -- the owner leaves: B becomes the owner and may continue
  local members = {{id = "B", name = "NB", me = true, host = true, peer = true}}
  B.mock.setLobby{lobby = "L", me = "B", owner = "B", isHost = true, phase = "lobby", members = members}
  step({B}, 5)
  check(B.ns.PARTY.canContinue(), "B can continue")
  B.mock.cursorSource = "frontend"
  B.mock.cursorPos = {5, 5}
  step({B}, 2)
  check(regions(B)["pui.idle"] and regions(B)["pui.idlex"], "Continue party pill with a close button")
  clickRegion(B, "pui.idle")
  check(B.ns.PARTY.role() == "host", "continued")
end

if fails > 0 then
  io.stderr:write("test_player_ui: " .. fails .. " failure(s)\n")
  os.exit(1)
end
print("test_player_ui: all checks passed")
