-- MAIN (src/90_main.lua): the screen callback and its guarded surfaces, the hotkeys, the pointer, the toasts and the
-- join / continue prompts, and the I4 budget: a frame with a 200-item queue, the setup panel open and the player's
-- controls up stays far under the core's 500k instructions per call.
local MW = require("mock_wum")

local fails = 0
local function check(cond, what)
  if not cond then
    fails = fails + 1
    io.stderr:write("  FAIL: " .. what .. "\n")
  end
end

local VID1, VID2 = "https://youtu.be/vid00000001", "https://youtu.be/vid00000002"

local function machine(id)
  local wum, mock = MW.new()
  wum._holoTest = {}
  local _, ok, err = MW.load("mod/client/init.lua", wum)
  check(ok, id .. ": init.lua runs: " .. tostring(err))
  return {id = id, wum = wum, mock = mock, ns = wum._holoTest.ns, sent = 0}
end

local function lobby(ms, owner)
  local members = {}
  for _, m in ipairs(ms) do members[#members + 1] = {id = m.id, name = "N" .. m.id, peer = true} end
  for _, m in ipairs(ms) do
    local mem = MW.deepcopy(members)
    for _, x in ipairs(mem) do
      x.me = x.id == m.id
      x.host = x.id == owner
    end
    m.mock.setLobby{lobby = "L", me = m.id, owner = owner, isHost = m.id == owner, phase = "lobby", members = mem}
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
          if o.id == r.to then o.mock.peerDeliver(m.id, MW.deepcopy(r.tbl), {reliable = true}) end
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

local function clickRegion(m, id)
  local r = regions(m)[id]
  if not r then return nil end
  local hit = m.mock.click((r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2)
  m.mock.frame()
  return hit
end

local function hasText(m, needle)
  for _, c in ipairs(m.mock.drawOf("hudText")) do
    if tostring(c.args[3]):find(needle, 1, true) then return true end
  end
  return false
end

local function player(m) return m.mock.players[#m.mock.players] end

-- 1. the screen stage callback and the hotkeys
do
  local A = machine("A")
  A.mock.frame()
  A.ns.QUEUE.add(VID1)
  A.ns.QUEUE.add(VID2)
  A.ns.PARTY.start()
  A.mock.emit("melange.media", {type = "loaded", duration = 100})
  A.mock.frames(30)
  check(#A.mock.drawOf("media") == 1, "drawn at the screen stage")
  A.mock.hotkey("F9")
  check(A.ns.LAYOUT.view() == "hidden", "F9 hides")
  A.mock.hotkey("F9")
  check(A.ns.LAYOUT.view() == "full", "F9 shows")
  A.mock.hotkey("Ctrl+Shift+P")
  check(A.ns.PARTY.hostState().s == "pause", "Ctrl+Shift+P pauses (host)")
  A.mock.hotkey("Ctrl+Shift+P")
  check(A.ns.PARTY.hostState().s == "play", "and plays")
  A.mock.hotkey("F6")
  check(A.ns.PARTY.setupOpen(), "F6 opens the setup panel")
  A.mock.hotkey("F6")
  check(not A.ns.PARTY.setupOpen(), "and closes it")
  A.mock.hotkey("F7")
  check(A.mock.pointerActive() and A.mock.pointerOpts.release == "click-outside", "F7: pointer on")
  A.mock.hotkey("F7")
  check(not A.mock.pointerActive(), "F7 again: off")
  -- the pause menu owns the mouse: F7 does nothing over it, and opening it ends pointer mode (X1-NET)
  A.mock.setUI{pause = true}
  A.mock.hotkey("F7")
  check(not A.mock.pointerActive(), "F7 over the pause menu: no pointer")
  A.mock.setUI{pause = false}
  A.mock.hotkey("F7")
  check(A.mock.pointerActive(), "F7 after the pause menu closed: on")
  A.mock.setUI{pause = true}
  A.mock.frame()
  check(not A.mock.pointerActive(), "the pause menu opening ends pointer mode")
  A.mock.setUI{pause = false}
  A.mock.frame()
  A.mock.pointerUnavailable = true
  A.mock.hotkey("F7")
  A.mock.frame()
  check(#A.ns.MAIN.toasts() == 0, "outside a match the pointer quietly does nothing")
  -- a hotkey picked in the settings
  A.wum.config.set("keyHide", "Alt+H")
  A.mock.frames(40)
  A.mock.hotkey("Alt+H")
  check(A.ns.LAYOUT.view() == "hidden", "re-registered hide hotkey")
  -- while hidden, a phase change toasts
  A.mock.frames(15)
  A.mock.hotkey("Ctrl+Shift+P")
  A.mock.frames(3)
  check(hasText(A, "Holo: paused"), "a toast while hidden")
  check(#A.mock.drawOf("media") == 0, "but no player")
end

-- 2. toasts: shown, stacked, gone after 3 s; prompts with buttons
do
  local A = machine("A")
  A.mock.frame()
  A.ns.U.emit("party.toast", "Something went wrong", "error")
  A.ns.U.emit("party.toast", "Note", "info")
  A.mock.frames(10)
  check(hasText(A, "Something went wrong") and hasText(A, "Note"), "two toasts")
  A.ns.U.emit("party.toast", "Note", "info")
  check(#A.ns.MAIN.toasts() == 2, "the same text is not stacked twice")
  A.mock.frames(200)
  check(not hasText(A, "Something went wrong") and #A.ns.MAIN.toasts() == 0, "gone after 3 s")
end

-- 3. join prompts: auto-joined with "Not now"; after a decline, "Join"
do
  local A, B = machine("A"), machine("B")
  local ms = {A, B}
  lobby(ms, "A")
  step(ms)
  connect(ms)
  step(ms, 3)
  A.ns.QUEUE.add(VID1)
  A.ns.PARTY.start()
  step(ms, 4)
  check(B.ns.PARTY.role() == "peer", "B auto-joined")
  check(hasText(B, "Joined NA's watch party"), "auto-join toast")
  B.mock.cursorSource = "frontend"
  B.mock.cursorPos = {1, 1}
  step(ms, 2)
  check(regions(B)["main.toast.1.1"], "Not now button")
  clickRegion(B, "main.toast.1.1")
  check(B.ns.PARTY.role() == "none" and B.ns.PARTY.declined(), "Not now leaves the party")
  -- the host ends and starts again: B is asked
  A.ns.PARTY.stop()
  step(ms, 3)
  A.ns.PARTY.start()
  step(ms, 4)
  check(B.ns.PARTY.role() == "none" and hasText(B, "NA's watch party is running"), "prompt after a decline")
  step(ms, 400)
  check(hasText(B, "NA's watch party is running"), "the prompt stays while the party runs")
  clickRegion(B, "main.toast.1.1")
  step(ms, 2)
  check(B.ns.PARTY.role() == "peer", "Join from the prompt")
  local errs = B.mock.logsOf("error")
  check(#errs == 0, "no errors: " .. tostring(errs[1]))
end

-- 4. a surface that keeps failing stops alone; the rest still draws
do
  local A = machine("A")
  A.ns.PUI.draw = function() error("boom") end
  A.ns.U.emit("party.toast", "Still here", "info")
  A.mock.frames(5)
  check(hasText(A, "Still here"), "toasts draw while the player surface fails")
  local stopped = false
  for _, l in ipairs(A.mock.logsOf("error")) do
    if l:find("draw.player", 1, true) and l:find("stopped", 1, true) then stopped = true end
  end
  check(stopped, "the failing surface stopped after 3 errors")
  A.mock.cursorSource = "frontend"
  A.ns.PARTY.setSetup(true)
  A.mock.frame()
  check(regions(A)["setup.panel"], "the setup panel still works")
end

-- 5. I4: the per-frame budget with a 200-item queue, the setup panel and the controls up
do
  local A = machine("A")
  for i = 1, 200 do A.ns.QUEUE.add(string.format("https://youtu.be/v%010d", i)) end
  for i, it in ipairs(A.ns.QUEUE.items()) do
    it.title, it.untitled = "A fairly long video title that needs cutting with an ellipsis, number " .. i, nil
    it.duration = 60 * i
  end
  A.ns.PARTY.start()
  A.mock.emit("melange.media", {type = "loaded", duration = 3600})
  A.mock.frames(30)
  player(A)._st.duration = 3600
  player(A)._st.tracks = {audio = {{id = 1, lang = "en", selected = true}}, sub = {{id = 2, lang = "en"}}}
  A.ns.PARTY.setSetup(true)
  A.mock.cursorSource = "frontend"
  local vx0, vy0, vx1, vy1 = A.ns.LAYOUT.rect()
  A.mock.cursorPos = {(vx0 + vx1) / 2, (vy0 + vy1) / 2}
  local worst, cold = 0, 0
  for f = 1, 40 do
    if f % 8 == 0 then
      A.mock.cursorPos = {(vx0 + vx1) / 2 + f % 3, (vy0 + vy1) / 2}
      A.mock.emitNow("melange.input.wheel", {region = "setup.list", delta = -3, x = 700, y = 600})
    end
    A.mock.frame(0.03)
    if f == 1 then cold = A.mock.instructionCount end
    if f > 1 then worst = math.max(worst, A.mock.instructionCount) end
  end
  check(A.ns.PUI.controlsShown(), "the controls are up")
  check(regions(A)["setup.list"], "the queue panel is open")
  print("frame with a 200-item queue and the panel: cold " .. cold .. ", worst warm " .. worst .. " instructions")
  check(cold < 400000, "cold frame under budget: " .. cold)
  check(worst < 150000, "warm frames well under the 500k budget: " .. worst)
  local errs = A.mock.logsOf("error")
  check(#errs == 0, "no errors: " .. tostring(errs[1]))
end

if fails > 0 then
  io.stderr:write("test_main: " .. fails .. " failure(s)\n")
  os.exit(1)
end
print("test_main: all checks passed")
