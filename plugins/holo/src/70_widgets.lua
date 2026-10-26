-- widgets (P3): immediate-mode controls drawn with SKIN. Every control claims its rect with wum.input.region in the
-- frame it is drawn (so its clicks never reach the game) and reads the melange.input.* events Melange delivers to
-- Holo only: a click is a press and a release in the same region, consumed by the control drawn with that id in a
-- later frame. Text boxes take keyboard focus (wum.input.focus) on a click and edit with a caret and a selection.
-- W.active = false draws controls without regions, hover or clicks (a surface that is faded, or under a modal).
do
  local C = SKIN.C
  local CLICK_TTL = 500            -- ms an unconsumed click waits for its control
  local POPOVER_AWAY = 1500        -- ms the cursor may be off all of Holo's regions before an open popover closes
  local MAX_TEXT = 4096            -- bytes in a text box (a link: classify refuses more)

  W.active = true
  W.mx, W.my, W.src = nil, nil, nil
  W.lastMove = -1e9                -- U.now() of the last cursor motion

  local pressed = {}               -- region id -> U.now() of the press we took, until its release
  local clicks = {}                -- region id -> {at, x, y}
  local wheel = {}                 -- region id -> notches
  local claimed = {}               -- region ids claimed this frame
  local focusBox = nil             -- the text box state that has the keyboard
  local keyq = {}                  -- key, char and paste events for it
  local popover = nil              -- {id, x0, y0, x1, y1, items, pick, seen}
  local lastX, lastY = nil, nil

  local function now() return U.now() end

  function W.blur()
    if not focusBox then return end
    focusBox.focused = false
    focusBox = nil
    keyq = {}
    pcall(wum.input.focus, false)
  end

  function W.closePopover() popover = nil end

  wum.events.on("melange.input.mouse", U.guard("w.mouse", function(p)
    local r = type(p.region) == "string" and p.region or nil
    if not r or (p.button ~= nil and p.button ~= "left") then return end
    if p.down then
      pressed[r] = now()
      if focusBox and focusBox.id ~= r then W.blur() end
      if popover and r:sub(1, #popover.id) ~= popover.id and r ~= popover.opener then popover = nil end
    else
      if pressed[r] then clicks[r] = {at = now(), x = U.num(p.x), y = U.num(p.y)} end
      pressed = {}
    end
  end))

  wum.events.on("melange.input.wheel", U.guard("w.wheel", function(p)
    local r, d = type(p.region) == "string" and p.region, U.num(p.delta)
    if r and d then wheel[r] = (wheel[r] or 0) + d end
  end))

  for _, name in ipairs{"key", "char", "paste"} do
    wum.events.on("melange.input." .. name, U.guard("w." .. name, function(p)
      if focusBox and #keyq < 64 then
        p.kind = name
        keyq[#keyq + 1] = p
      end
    end))
  end

  ---------------------------------------------------------------- frame

  function W.beginFrame()
    local ok, x, y, src = pcall(wum.input.cursor)
    if ok and type(x) == "number" and type(y) == "number" then
      W.mx, W.my, W.src = x, y, src
      if x ~= lastX or y ~= lastY then
        lastX, lastY = x, y
        W.lastMove = now()
      end
    else
      W.mx, W.my, W.src = nil, nil, nil
      lastX, lastY = nil, nil
    end
    claimed = {}
    W.active = true
    local n = now()
    for id, c in pairs(clicks) do
      if n - c.at > CLICK_TTL then clicks[id] = nil end
    end
    if popover then popover.seen = false end
  end

  function W.endFrame()
    -- a held press whose control is gone (the panel closed under the mouse) is dropped
    for id in pairs(pressed) do
      if not claimed[id] then pressed[id] = nil end
    end
    wheel = {}
    if focusBox and not focusBox.drawn then W.blur() end
    if focusBox then focusBox.drawn = false end
  end

  function W.inside(x0, y0, x1, y1)
    local x, y = W.mx, W.my
    return x ~= nil and x >= x0 and x < x1 and y >= y0 and y < y1
  end

  -- Claims a rect for this frame (it must be renewed every frame while it shows). false while inactive, and while
  -- there is no cursor: in a match without pointer mode the game keeps the mouse at the centre of the window, so a
  -- region there (the setup panel) would take the fire button.
  function W.region(id, x0, y0, x1, y1, cursor)
    if not W.active or W.mx == nil or x1 <= x0 or y1 <= y0 then return false end
    claimed[id] = true
    local ok, got = pcall(wum.input.region, id, x0, y0, x1, y1, {cursor = cursor or "hand"})
    return ok and got == true
  end

  -- Consumes a click on a region: the click table {x, y} or nil.
  function W.clicked(id)
    local c = clicks[id]
    if not c then return nil end
    clicks[id] = nil
    if not W.active then return nil end
    return c
  end

  function W.held(id) return W.active and pressed[id] ~= nil end

  function W.wheel(id)
    local d = wheel[id]
    wheel[id] = nil
    return d or 0
  end

  -- "off", "press", "hover" or "normal" for a control at a rect.
  function W.state(id, x0, y0, x1, y1, enabled)
    if enabled == false then return "off" end
    if not W.active then return "normal" end
    if pressed[id] then return "press" end
    if W.inside(x0, y0, x1, y1) then return "hover" end
    return "normal"
  end

  ---------------------------------------------------------------- buttons

  local NINE = {normal = "btn", hover = "btn_hover", press = "btn_press", off = "btn_off"}

  -- A pill button with a label and an optional icon. o: {icon, enabled, size (text px), kind = "display"|"body",
  -- on (drawn pressed, a toggled chip)}. Returns true when clicked (and enabled).
  function W.button(id, x0, y0, x1, y1, label, o)
    local enabled = not (o and o.enabled == false)
    W.region(id, x0, y0, x1, y1)
    local st = W.state(id, x0, y0, x1, y1, enabled)
    if o and o.on and st == "normal" then st = "press" end
    SKIN.nine(NINE[st], x0, y0, x1, y1)
    local h = y1 - y0
    local size = o and o.size or math.floor(h * 0.42 + 0.5)
    local tx, maxW = (x0 + x1) / 2, (x1 - x0) - h * 0.5
    local icon = o and o.icon
    if icon then
      local is = h * 0.62
      if label and label ~= "" then
        local tw = math.min(SKIN.measure(label, size, o.kind or "display"), maxW - is)
        local left = (x0 + x1) / 2 - (is + tw + h * 0.08) / 2
        SKIN.icon(icon, left, y0 + (h - is) / 2 - h * 0.04, is, enabled and "normal" or "off")
        tx, maxW = left + is + h * 0.08 + tw / 2, tw + 1
      else
        SKIN.icon(icon, (x0 + x1 - is) / 2, y0 + (h - is) / 2 - h * 0.04, is, enabled and "normal" or "off")
      end
    end
    if label and label ~= "" then
      SKIN.text(tx, y0 - h * 0.05, label, size, enabled and C.cream or C.offText,
        {kind = o and o.kind or "display", align = "center", maxWidth = maxW, vcenter = h})
    end
    local c = W.clicked(id)
    return enabled and c ~= nil
  end

  -- A bare atlas icon as a button, `size` square at x, y. Returns true when clicked (and enabled).
  function W.iconButton(id, icon, x, y, size, enabled, on)
    enabled = enabled ~= false
    W.region(id, x, y, x + size, y + size)
    local st = W.state(id, x, y, x + size, y + size, enabled)
    if on and st == "normal" then st = "press" end
    SKIN.icon(icon, x, y, size, st)
    local c = W.clicked(id)
    return enabled and c ~= nil
  end

  ---------------------------------------------------------------- sliders

  -- A horizontal bar (the volume): returns value (0..1), changed, released. Drag while held; a click sets it.
  -- o: {enabled, readonly (drawn as enabled, takes no input), buffered (0..1, drawn under the fill), marker (0..1, a
  -- thin host marker), grab (extra px around)}.
  function W.slider(id, x0, y0, x1, y1, value, o)
    local enabled = not (o and o.enabled == false)
    local input = enabled and not (o and o.readonly)
    local grab = o and o.grab or 0
    if input then W.region(id, x0 - grab, y0 - grab, x1 + grab, y1 + grab) end
    local v, changed, released = U.clamp(U.num(value) or 0, 0, 1), false, false
    local w = math.max(x1 - x0, 1)
    if input then
      local c = W.clicked(id)
      if c and c.x then
        v, changed, released = U.clamp((c.x - x0) / w, 0, 1), true, true
      elseif W.held(id) and W.mx then
        v, changed = U.clamp((W.mx - x0) / w, 0, 1), true
      end
    end
    local h = y1 - y0
    SKIN.nine("bar_track", x0, y0, x1, y1)
    local inset = h * 0.2
    local fx0, fy0, fx1, fy1 = x0 + inset, y0 + inset, x1 - inset, y1 - inset
    local fw = fx1 - fx0
    local b = o and U.num(o.buffered)
    if b and b > v then SKIN.rect(fx0, fy0, fx0 + fw * U.clamp(b, 0, 1), fy1, C.buffered) end
    if v > 0 then SKIN.nine("bar_fill", fx0, fy0, fx0 + math.max(fw * v, fy1 - fy0), fy1,
      {tint = enabled and 0xFFFFFF or C.offText}) end
    local m = o and U.num(o.marker)
    if m then
      local mx = fx0 + fw * U.clamp(m, 0, 1)
      SKIN.rect(mx - h * 0.08, y0 - h * 0.3, mx + h * 0.08, y1 + h * 0.3, C.white)
    end
    if input and (W.held(id) or W.state(id, x0, y0, x1, y1, true) == "hover") then
      local k = h * 1.6
      local kx = fx0 + fw * v
      SKIN.part("knob", kx - k / 2, (y0 + y1 - k) / 2, kx + k / 2, (y0 + y1 + k) / 2)
    end
    return v, changed, released
  end

  ---------------------------------------------------------------- popovers

  -- A list that opens above (or below) an anchor rect; items {{label, value, on, enabled}}, pick(value) on a click.
  -- Opening the same id again closes it. The control that opened it (or `owner`, the control of a parent popover)
  -- calls W.isOpen(id) every frame it shows, or the popover closes (its owner went away).
  function W.togglePopover(id, x0, y0, x1, y1, items, pick, title, owner)
    if popover and popover.id == id then
      popover = nil
      return
    end
    popover = {id = id, opener = owner or id, x0 = x0, y0 = y0, x1 = x1, y1 = y1, items = items, pick = pick,
      title = title, seen = true}
  end

  function W.isOpen(id)
    if popover and (popover.id == id or popover.opener == id) then
      popover.seen = true
      return popover.id == id or popover.opener == id
    end
    return false
  end

  function W.popoverOpen() return popover ~= nil end

  -- Draws the open popover last (on top, its regions above everything else of Holo's).
  function W.drawPopover()
    local p = popover
    if not p then return end
    if not p.seen then
      popover = nil
      return
    end
    -- Clicks on the game and Esc in the frontend never reach Holo, so a popover left open while the player went
    -- back to the game's menus closes once the cursor has been away from Holo's controls for a moment.
    local okH, hv = pcall(wum.input.hover)
    if okH and hv == nil and W.mx ~= nil then
      local n = now()
      p.awaySince = p.awaySince or n
      if n - p.awaySince >= POPOVER_AWAY then
        popover = nil
        return
      end
    else
      p.awaySince = nil
    end
    local s = SKIN.s
    local rowH, padX = 34 * s, 14 * s
    local size = 18 * s
    local w = 0
    for _, it in ipairs(p.items) do w = math.max(w, SKIN.measure(it.label, size, "body")) end
    if p.title then w = math.max(w, SKIN.measure(p.title, size * 0.9, "display")) end
    w = math.max(w + padX * 2 + 24 * s, 120 * s)
    local h = #p.items * rowH + (p.title and rowH or 0) + 16 * s
    local ww = select(1, wum.render.windowSize())
    local x0 = U.clamp((p.x0 + p.x1) / 2 - w / 2, 8 * s, ww - w - 8 * s)
    local y1 = p.y0 - 8 * s
    local y0 = y1 - h
    if y0 < 8 * s then
      y0 = p.y1 + 8 * s
      y1 = y0 + h
    end
    W.region(p.id .. "#", x0, y0, x0 + w, y1, "arrow")
    SKIN.nine("tooltip", x0, y0, x0 + w, y1)
    local y = y0 + 8 * s
    if p.title then
      SKIN.text(x0 + padX, y, p.title, size * 0.9, C.gold, {kind = "display", vcenter = rowH})
      y = y + rowH
    end
    for i, it in ipairs(p.items) do
      local rid = p.id .. "#" .. i
      local enabled = it.enabled ~= false
      W.region(rid, x0 + 4 * s, y, x0 + w - 4 * s, y + rowH)
      local st = W.state(rid, x0, y, x0 + w, y + rowH, enabled)
      if it.on or st == "hover" or st == "press" then
        SKIN.part("swash", x0 + 6 * s, y + 2 * s, x0 + w - 6 * s, y + rowH - 2 * s, {a = it.on and 1 or 0.6})
      end
      if it.on then SKIN.icon("check", x0 + padX * 0.5, y + (rowH - 22 * s) / 2, 22 * s) end
      SKIN.text(x0 + padX + 18 * s, y, it.label, size, enabled and (it.on and C.title or C.cream) or C.offText,
        {vcenter = rowH, maxWidth = w - padX * 2 - 18 * s})
      if W.clicked(rid) and enabled then
        popover = nil
        local ok, err = pcall(p.pick, it.value)
        if not ok then U.log("error", "popover", err) end
        return
      end
      y = y + rowH
    end
  end

  ---------------------------------------------------------------- text box

  -- UTF-8 steps over a byte caret (0 = before the first byte).
  local function prevChar(s, i)
    if i <= 0 then return 0 end
    i = i - 1
    while i > 0 do
      local b = s:byte(i + 1)
      if b < 0x80 or b >= 0xC0 then break end
      i = i - 1
    end
    return i
  end
  local function nextChar(s, i)
    if i >= #s then return #s end
    i = i + 1
    while i < #s do
      local b = s:byte(i + 1)
      if b < 0x80 or b >= 0xC0 then break end
      i = i + 1
    end
    return i
  end
  W.prevChar, W.nextChar = prevChar, nextChar

  local KEYS = {RETURN = "enter", ENTER = "enter", NUMPADENTER = "enter", BACK = "backspace", BACKSPACE = "backspace",
    DELETE = "delete", DEL = "delete", LEFT = "left", RIGHT = "right", HOME = "home", END = "end",
    ESCAPE = "esc", ESC = "esc", A = "a", TAB = "tab"}

  -- Key names come as the core's keys.h names ("RETURN", "BACK", "LEFT"); labels such as "Enter" read the same.
  local function keyName(k)
    if type(k) ~= "string" then return nil end
    return KEYS[k:upper()]
  end

  -- A text box state: {id, text, caret, anchor (selection start or nil), focused, scroll}.
  function W.newText(id, text)
    return {id = id, text = text or "", caret = #(text or ""), anchor = nil, focused = false, scroll = 0}
  end

  local function selRange(st)
    if not st.anchor or st.anchor == st.caret then return nil end
    return math.min(st.anchor, st.caret), math.max(st.anchor, st.caret)
  end

  local function replaceSel(st, ins)
    local a, b = selRange(st)
    if not a then a, b = st.caret, st.caret end
    ins = ins:gsub("[%c]", " ")
    local room = MAX_TEXT - (#st.text - (b - a))
    if #ins > room then
      ins = ins:sub(1, math.max(room, 0))
      while #ins > 0 and not utf8.len(ins) do ins = ins:sub(1, -2) end
    end
    st.text = st.text:sub(1, a) .. ins .. st.text:sub(b + 1)
    st.caret, st.anchor = a + #ins, nil
  end

  local function move(st, to, shift)
    if shift then
      if not st.anchor then st.anchor = st.caret end
    else
      st.anchor = nil
    end
    st.caret = U.clamp(to, 0, #st.text)
  end

  -- Applies one key, char or paste event. Returns "submit", "changed" or nil.
  function W.textKey(st, e)
    if e.kind == "char" and type(e.text) == "string" then
      replaceSel(st, e.text)
      return "changed"
    elseif e.kind == "paste" and type(e.text) == "string" then
      replaceSel(st, e.text:gsub("[\r\n\t]+", " "))
      return "changed"
    elseif e.kind ~= "key" or not e.down then
      return nil
    end
    local k = keyName(e.key)
    local a, b = selRange(st)
    if k == "enter" then return "submit"
    elseif k == "esc" then W.blur()
    elseif k == "backspace" then
      if a then replaceSel(st, "") elseif st.caret > 0 then
        local p = prevChar(st.text, st.caret)
        st.text = st.text:sub(1, p) .. st.text:sub(st.caret + 1)
        st.caret = p
      end
      return "changed"
    elseif k == "delete" then
      if a then replaceSel(st, "") elseif st.caret < #st.text then
        st.text = st.text:sub(1, st.caret) .. st.text:sub(nextChar(st.text, st.caret) + 1)
      end
      return "changed"
    elseif k == "left" then
      if a and not e.shift then move(st, a, false) else move(st, prevChar(st.text, st.caret), e.shift) end
    elseif k == "right" then
      if a and not e.shift then move(st, b, false) else move(st, nextChar(st.text, st.caret), e.shift) end
    elseif k == "home" then move(st, 0, e.shift)
    elseif k == "end" then move(st, #st.text, e.shift)
    elseif k == "a" and e.ctrl then
      st.anchor, st.caret = 0, #st.text
    end
    return nil
  end

  -- The byte caret nearest to a pixel offset into the text.
  local function caretAt(st, px, size)
    local best, bestD, i = 0, math.abs(px), 0
    while i < #st.text do
      i = nextChar(st.text, i)
      local d = math.abs(SKIN.measure(st.text:sub(1, i), size, "body") - px)
      if d < bestD then best, bestD = i, d end
    end
    return best
  end

  -- Draws and runs a text box. Returns "submit" (Enter), "changed" or nil. o: {placeholder, size, enabled}.
  function W.textbox(st, x0, y0, x1, y1, o)
    local id = st.id
    local enabled = not (o and o.enabled == false)
    local h = y1 - y0
    local size = o and o.size or math.floor(h * 0.45 + 0.5)
    local padX = h * 0.35
    if enabled then W.region(id, x0, y0, x1, y1, "ibeam") end
    SKIN.nine("well", x0, y0, x1, y1)
    local result
    local c = enabled and W.clicked(id)
    if c then
      if not st.focused then
        local ok, got = pcall(wum.input.focus, true)
        if ok and got then
          if focusBox and focusBox ~= st then W.blur() end
          focusBox, st.focused, keyq = st, true, {}
        end
      end
      if c.x then move(st, caretAt(st, c.x - (x0 + padX) + st.scroll, size), false) end
    end
    if not enabled and st.focused then W.blur() end
    if st.focused then
      st.drawn = true
      local q = keyq
      keyq = {}
      for _, e in ipairs(q) do
        local r = W.textKey(st, e)
        if r == "submit" then result = "submit" elseif r == "changed" and result == nil then result = "changed" end
        if not st.focused then break end
      end
    end
    -- keep the caret in view
    local inner = (x1 - x0) - padX * 2
    local cx = SKIN.measure(st.text:sub(1, st.caret), size, "body")
    if cx - st.scroll > inner then st.scroll = cx - inner end
    if cx - st.scroll < 0 then st.scroll = cx end
    if st.scroll < 0 then st.scroll = 0 end
    SKIN.clip(x0 + padX * 0.5, y0, x1 - padX * 0.5, y1)
    local tx = x0 + padX - st.scroll
    if st.text == "" and not st.focused then
      SKIN.text(x0 + padX, y0, o and o.placeholder or "", size, C.offText, {vcenter = h, maxWidth = inner})
    else
      local a, b = selRange(st)
      if a and st.focused then
        local sx0 = tx + SKIN.measure(st.text:sub(1, a), size, "body")
        local sx1 = tx + SKIN.measure(st.text:sub(1, b), size, "body")
        SKIN.rect(sx0, y0 + h * 0.2, sx1, y1 - h * 0.2, C.btnHover, 0.9)
      end
      SKIN.text(tx, y0, st.text, size, C.cream, {vcenter = h})
      if st.focused and math.floor(U.now() / 530) % 2 == 0 then
        SKIN.rect(tx + cx, y0 + h * 0.22, tx + cx + math.max(2, 2 * SKIN.s), y1 - h * 0.22, C.title)
      end
    end
    SKIN.clipEnd()
    return result
  end

  function W.focused() return focusBox end
end
