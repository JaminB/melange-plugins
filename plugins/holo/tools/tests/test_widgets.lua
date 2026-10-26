-- SKIN and W (src/60_skin.lua, src/70_widgets.lua): the atlases and fonts load without mips, nine-slices keep their
-- shadow margin outside the rect, text measures are cached, and the widgets claim regions, take clicks, drag, edit
-- text with focus, caret, selection and paste, and run popovers.
local MW = require("mock_wum")

local fails = 0
local function check(cond, what)
  if not cond then
    fails = fails + 1
    io.stderr:write("  FAIL: " .. what .. "\n")
  end
end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 0.01) end

-- Loads Holo with the cursor on (as in the menus) and puts `ui(ns)` in place of the player UI, so the widgets run
-- inside MAIN's frame (between W.beginFrame and W.endFrame) like the real surfaces.
local function loadHolo(ui)
  local wum, mock = MW.new()
  wum._holoTest = {}
  local _, ok, err = MW.load("mod/client/init.lua", wum)
  check(ok, "init.lua runs: " .. tostring(err))
  local ns = wum._holoTest.ns
  mock.cursorSource = "frontend"
  mock.cursorPos = {5, 5}
  if ui then ns.PUI.draw = function() ui(ns) end end
  mock.frame()
  return wum, mock, ns
end

local function regionIds(mock)
  local out = {}
  for _, r in ipairs(mock.regions()) do out[r.id] = r end
  return out
end

local function errors(mock)
  local e = mock.logsOf("error")
  return #e == 0, e[1]
end

-- 1. the skin loads every atlas without mips and the four fonts
do
  local wum, mock, ns = loadHolo()
  local files = {}
  for _, t in pairs(mock.textures or {}) do files[t.rel] = t.opts end
  for _, f in ipairs{"textures/ui/panels.png", "textures/ui/icons.png", "textures/ui/cursor.png"} do
    check(files[f] and files[f].mips == false, f .. " loaded with mips = false")
  end
  check(mock.fonts and #mock.fonts == 4, "four fonts loaded")
  check(ns.SKIN.font("display_s") and ns.SKIN.font("body_s") and ns.SKIN.font("tag"), "font ids kept")
  check(ns.SKIN.col(0x123456, 1) == 0x123456FF and ns.SKIN.col(0xFFFFFF, 0) == 0xFFFFFF00, "colour packing")
  local ok, e = errors(mock)
  check(ok, "no errors: " .. tostring(e))
end

-- 2. nine-slices: the visible shape covers the rect, the shadow margin is outside it; icons take their state's uv
do
  local wum, mock, ns = loadHolo(function(ns)
    ns.SKIN.s = 1
    ns.SKIN.nine("panel", 100, 100, 500, 400)
    ns.SKIN.icon("play", 10, 10, 36, "hover")
  end)
  mock.frame()
  local nine = mock.drawOf("hudNine")[1]
  local r = ns.SKIN.atlas.panels.rects.panel
  check(nine ~= nil, "hudNine drawn")
  if nine then
    local a = nine.args
    check(near(a[1], 100 - r.pad.l * 0.5) and near(a[3], 500 + r.pad.r * 0.5), "pad outside horizontally")
    check(near(a[2], 100 - r.pad.t * 0.5) and near(a[4], 400 + r.pad.b * 0.5), "pad outside vertically")
    check(a[6] == r.l and a[9] == r.b and near(a[10].scale, 0.5), "insets and the 2x scale")
    check(near(a[10].uv[1], r.x / 1024) and near(a[10].uv[4], (r.y + r.h) / 600), "uv of the atlas rect")
  end
  local uv = mock.drawOf("hudImageUV")[1]
  local ic = ns.SKIN.atlas.icons.rects.play[2]
  check(uv and near(uv.args[6], ic.x / 888) and near(uv.args[7], ic.y / 962), "icon hover state uv")
  -- a small button rect shrinks the slice scale so the corners fit
  ns.PUI.draw = function() ns.SKIN.s = 1; ns.SKIN.nine("btn", 0, 0, 200, 24) end
  mock.frame()
  local b = mock.drawOf("hudNine")[1]
  local br = ns.SKIN.atlas.panels.rects.btn
  check(b and near(b.args[10].scale, 24 / ((br.t - br.pad.t) + (br.b - br.pad.b))), "slice scale shrinks to fit")
  -- a missing atlas falls back to plain rects, no error
  local w3, m3 = MW.new()
  m3.missingTextures = {["textures/ui/panels.png"] = true}
  w3._holoTest = {}
  local _, ok3 = MW.load("mod/client/init.lua", w3)
  local ns3 = w3._holoTest.ns
  ns3.PUI.draw = function() ns3.SKIN.nine("panel", 0, 0, 100, 100) end
  m3.frame()
  check(ok3 and #m3.drawOf("hudNine") == 0 and #m3.drawOf("hudRect") >= 1, "fallback without the atlas")
end

-- 3. text: measures are cached, wrap splits on width
do
  local calls = 0
  local wum, mock, ns = loadHolo(function(ns)
    for _ = 1, 5 do ns.SKIN.measure("Hello there", 20, "body") end
    ns.SKIN.text(10, 10, "Hello there", 20, ns.SKIN.C.cream, {maxWidth = 50})
  end)
  local real = wum.draw.textSize
  wum.draw.textSize = function(...) calls = calls + 1; return real(...) end
  mock.frames(3)
  check(calls <= 1, "one textSize for the same string over frames: " .. calls)
  local t = mock.drawOf("hudText")[1]
  check(t and t.args[6].font == ns.SKIN.font("body") and t.args[6].maxWidth == 50 and t.args[6].ellipsis, "text opts")
  local lines = ns.SKIN.wrap("one two three four five six", 10, "body", 60)
  check(#lines >= 3, "wrap splits: " .. #lines)
  local cut = ns.SKIN.wrap("one two three four five six seven eight", 10, "body", 40, 2)
  check(#cut == 2 and cut[2]:sub(-3) == "...", "wrap caps the lines")
end

-- 4. buttons: a region per frame, a click once, nothing when disabled or inactive
do
  local hits, offHits, inactiveHits = 0, 0, 0
  local wum, mock, ns = loadHolo(function(ns)
    if ns.W.button("t.ok", 100, 100, 300, 148, "OK") then hits = hits + 1 end
    if ns.W.button("t.off", 100, 200, 300, 248, "Off", {enabled = false}) then offHits = offHits + 1 end
    ns.W.active = false
    if ns.W.button("t.in", 100, 300, 300, 348, "In") then inactiveHits = inactiveHits + 1 end
    ns.W.active = true
  end)
  local ids = regionIds(mock)
  check(ids["t.ok"] and ids["t.off"] and not ids["t.in"], "regions: enabled and disabled claim, inactive does not")
  check(ids["t.ok"] and ids["t.ok"].opts.cursor == "hand", "hand cursor")
  check(mock.click(150, 120) == "t.ok", "click hits the button")
  mock.frame()
  check(hits == 1, "clicked once")
  mock.frames(3)
  check(hits == 1, "a click is consumed once")
  mock.click(150, 220); mock.frame()
  check(offHits == 0, "disabled button ignores the click")
  -- a press that moves off the button before release is not a click
  mock.emitNow("melange.input.mouse", {region = "t.ok", button = "left", down = true, x = 150, y = 120})
  mock.emitNow("melange.input.mouse", {region = "t.off", button = "left", down = false, x = 150, y = 220})
  mock.frame()
  check(hits == 1, "press here, release there: no click")
  -- right clicks do nothing
  mock.click(150, 120, "right"); mock.frame()
  check(hits == 1, "right click ignored")
end

-- 5. slider: a click sets the value, a held press drags it with the cursor
do
  local val, changedN, releasedN = 0.5, 0, 0
  local wum, mock, ns = loadHolo(function(ns)
    local v, ch, rel = ns.W.slider("t.sl", 100, 100, 300, 110, val)
    if ch then val = v; changedN = changedN + 1 end
    if rel then releasedN = releasedN + 1 end
  end)
  mock.click(250, 105); mock.frame()
  check(near(val, 0.75) and releasedN == 1, "click at 75 %: " .. val)
  mock.emitNow("melange.input.mouse", {region = "t.sl", button = "left", down = true, x = 150, y = 105})
  mock.cursorPos = {150, 105}; mock.frame()
  check(near(val, 0.25) and releasedN == 1, "drag to 25 %: " .. val)
  mock.cursorPos = {400, 105}; mock.frame()
  check(near(val, 1), "drag clamps to 1")
  mock.emitNow("melange.input.mouse", {region = "t.sl", button = "left", down = false, x = 400, y = 105})
  mock.frame()
  check(releasedN == 2, "release ends the drag")
  local n = changedN
  mock.cursorPos = {120, 105}; mock.frame()
  check(changedN == n, "no change after the release")
end

-- 6. text box: focus on click, typing, paste, caret, selection, UTF-8, Enter, Esc
do
  local st, submits
  local wum, mock, ns = loadHolo(function(ns)
    st = st or ns.W.newText("t.box")
    local r = ns.W.textbox(st, 100, 100, 600, 148, {placeholder = "Paste"})
    if r == "submit" then submits = (submits or 0) + 1 end
  end)
  check(regionIds(mock)["t.box"].opts.cursor == "ibeam", "text cursor")
  check(not mock.focused(), "not focused yet")
  mock.emitNow("melange.input.char", {text = "x"}); mock.frame()
  check(st.text == "", "typing without focus does nothing")
  mock.click(120, 120); mock.frame()
  check(mock.focused() and st.focused, "focused by a click")
  local function key(k, mods)
    local e = {key = k, down = true, ["repeat"] = false}
    for m, v in pairs(mods or {}) do e[m] = v end
    mock.emitNow("melange.input.key", e)
  end
  for c in ("abc"):gmatch(".") do mock.emitNow("melange.input.char", {text = c}) end
  mock.frame()
  check(st.text == "abc" and st.caret == 3, "typed abc")
  key("LEFT"); key("BACK"); mock.frame()
  check(st.text == "ac" and st.caret == 1, "left + backspace: " .. st.text)
  key("END"); key("LEFT", {shift = true}); mock.emitNow("melange.input.char", {text = "Z"}); mock.frame()
  check(st.text == "aZ", "selection replaced: " .. st.text)
  key("A", {ctrl = true}); mock.emitNow("melange.input.paste", {text = "https://youtu.be/abc\n"}); mock.frame()
  check(st.text == "https://youtu.be/abc " and st.anchor == nil, "select all + paste: '" .. st.text .. "'")
  key("HOME"); key("DELETE"); mock.frame()
  check(st.text:sub(1, 4) == "ttps", "delete at home")
  st.text, st.caret = "é", 2
  key("BACK"); mock.frame()
  check(st.text == "" and st.caret == 0, "backspace removes a whole UTF-8 character")
  mock.emitNow("melange.input.char", {text = "ü"}); mock.emitNow("melange.input.char", {text = "x"})
  key("LEFT"); key("LEFT"); mock.frame()
  check(st.caret == 0, "left steps over UTF-8: " .. st.caret)
  key("RETURN"); mock.frame()
  check(submits == 1 and st.focused, "Enter submits and keeps focus")
  key("Enter"); mock.frame()
  check(submits == 2, "label-style key names work too")
  key("ESCAPE"); mock.frame()
  check(not st.focused and not mock.focused(), "Esc ends the focus")
  -- a click elsewhere also ends it
  mock.click(120, 120); mock.frame()
  check(mock.focused(), "focused again")
  ns.PUI.draw = function()
    ns.W.textbox(st, 100, 100, 600, 148)
    ns.W.button("t.other", 100, 300, 300, 348, "Other")
  end
  mock.frame()
  mock.click(150, 320); mock.frame()
  check(not mock.focused(), "a click on another control blurs")
  -- the box going away blurs too
  mock.click(120, 120); mock.frame()
  ns.PUI.draw = function() end
  mock.frame()
  check(not mock.focused(), "a box that is no longer drawn loses the focus")
  -- a cap on its length
  st.text, st.caret = string.rep("a", 4090), 4090
  ns.PUI.draw = function() ns.W.textbox(st, 100, 100, 600, 148) end
  mock.frame(); mock.click(120, 120); mock.frame()
  st.caret = #st.text
  mock.emitNow("melange.input.paste", {text = string.rep("b", 100)}); mock.frame()
  check(#st.text == 4096, "text capped at 4096 bytes: " .. #st.text)
end

-- 7. popovers: open, pick, close; the opener must keep drawing or it closes
do
  local picked
  local draw = true
  local wum, mock, ns = loadHolo(function(ns)
    if not draw then return end
    ns.W.isOpen("t.pop")
    if ns.W.button("t.pop", 800, 800, 900, 840, "Open") then
      local items = {{label = "One", value = 1}, {label = "Two", value = 2, on = true}}
      ns.W.togglePopover("t.pop", 800, 800, 900, 840, items, function(v) picked = v end, "Pick")
    end
  end)
  mock.click(850, 820); mock.frame()
  check(ns.W.popoverOpen(), "opened")
  mock.frame()
  local ids = regionIds(mock)
  check(ids["t.pop#1"] and ids["t.pop#2"] and ids["t.pop#"], "row regions")
  local r = ids["t.pop#1"]
  mock.click((r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2); mock.frame()
  check(picked == 1 and not ns.W.popoverOpen(), "picked and closed")
  mock.click(850, 820); mock.frame()
  check(ns.W.popoverOpen(), "open again")
  mock.click(850, 820); mock.frame()
  check(not ns.W.popoverOpen(), "the opener toggles it closed")
  mock.click(850, 820); mock.frame()
  draw = false
  mock.frames(2)
  check(not ns.W.popoverOpen(), "closes when its owner is gone")
  -- the cursor away from all of Holo's regions (back on the game's menus, where Esc and clicks never reach Holo)
  draw = true
  mock.frame()
  mock.click(850, 820); mock.frame()
  check(ns.W.popoverOpen(), "open for the away test")
  mock.cursorPos = {10, 10}
  mock.frames(10, 0.1)
  check(ns.W.popoverOpen(), "still open 1 s after the cursor left")
  mock.frames(8, 0.1)
  check(not ns.W.popoverOpen(), "closed once the cursor stayed away 1.5 s")
  mock.click(850, 820); mock.frame()
  mock.cursorPos = {10, 10}
  mock.frames(10, 0.1)
  local r2 = regionIds(mock)["t.pop#2"]
  mock.cursorPos = {(r2.x0 + r2.x1) / 2, (r2.y0 + r2.y1) / 2}
  mock.frames(10, 0.1)
  check(ns.W.popoverOpen(), "coming back over the popover keeps it open")
end

-- 8. wheel: delivered to its region once
do
  local got = 0
  local wum, mock, ns = loadHolo(function(ns)
    ns.W.region("t.list", 0, 0, 100, 100)
    got = got + ns.W.wheel("t.list")
  end)
  mock.emitNow("melange.input.wheel", {region = "t.list", delta = -2, x = 10, y = 10})
  mock.frame(); mock.frame()
  check(got == -2, "wheel notches: " .. got)
  local ok, e = errors(mock)
  check(ok, "no errors: " .. tostring(e))
end

if fails > 0 then
  io.stderr:write("test_widgets: " .. fails .. " failure(s)\n")
  os.exit(1)
end
print("test_widgets: all checks passed")
