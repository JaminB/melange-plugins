-- main (P3): the "screen" draw callback that runs every surface (player, setup panel, toasts, popovers) each under
-- its own guard, the four hotkeys of the bus ("hotkey", name from CFG), pointer mode for a match, the toasts and the
-- join / continue prompts. The pointer is Melange's: Holo asks for it with its themed cursor and the default
-- release on a click outside its regions; Esc, the hotkey again or a turn of this machine's player also end it.
do
  local C = SKIN.C
  local TOAST_MS, MAX_TOASTS = 3000, 3

  local toasts = {}            -- {id, text, kind, at, until (ms or nil = while keep() holds), actions, keep}
  local pointerForSetup = false
  local lastPhase = PARTY.phase()
  local lastSetup = PARTY.setupOpen()

  local function toast(t)
    t.at = U.now()
    for i, o in ipairs(toasts) do
      if (t.id and o.id == t.id) or (not t.id and o.text == t.text) then
        toasts[i] = t
        return t
      end
    end
    toasts[#toasts + 1] = t
    while #toasts > 6 do table.remove(toasts, 1) end
    return t
  end
  function MAIN.toast(text, kind, ms)
    return toast{text = U.trim(text, 140), kind = kind or "info", life = ms or TOAST_MS}
  end
  function MAIN.toasts() return toasts end

  U.on("party.toast", function(text, kind) MAIN.toast(text, kind) end)

  -- Auto-joined: say so and offer "Not now". After a decline: ask (Join / Not now) while the party runs.
  U.on("party.joinPrompt", function(hostName, autoJoined)
    local host = U.trim(hostName, 32)
    if autoJoined then
      toast{id = "join", text = "Joined " .. host .. "'s watch party", kind = "info", life = 8000,
        actions = {{"Not now", function() PARTY.decline() end}}}
    else
      toast{id = "join", text = host .. "'s watch party is running", kind = "info",
        keep = function() return PARTY.partyRunning() end,
        actions = {{"Join", function() PARTY.join() end}, {"Not now", function() end}}}
    end
  end)

  U.on("party.continuePrompt", function()
    toast{id = "continue", text = "The party host left. You can continue the party.", kind = "info", life = 20000,
      keep = function() return PARTY.canContinue() end,
      actions = {{"Continue party", function() PARTY.continueParty() end}}}
  end)

  -- While the player is hidden, a short toast tells what changed.
  local PHASE_TOAST = {playing = "Holo: playing", paused = "Holo: paused", ["ended-item"] = "Holo: video finished",
    ["needs-pack"] = "Holo needs the media pack: open the player (F9) to download it"}

  local function pointerOn()
    local o = {release = "click-outside"}
    local cur = SKIN.texture("cursor")
    if cur then
      o.cursor = cur
      -- the arrow's tip is not the PNG's corner: Melange puts this pixel on the pointer, so clicks land at the tip
      local a = SKIN.atlas and SKIN.atlas.cursor
      if a and a.hot then o.hot = {x = a.hot.x, y = a.hot.y} end
    end
    local ok, got, why = pcall(wum.input.pointer, true, o)
    if ok and got then return true end
    return false, ok and why or got
  end

  local function pointerOff()
    pcall(wum.input.pointer, false)
  end

  local function pointerActive()
    local ok, on = pcall(wum.input.pointerActive)
    return ok and on == true
  end

  -- The pointer hotkey: toggles pointer mode in a match (outside a match the game's own cursor already works).
  function MAIN.togglePointer()
    if pointerActive() then
      pointerOff()
      pointerForSetup = false
      return false
    end
    local ok, why = pointerOn()
    if not ok and why ~= "unavailable" then MAIN.toast("The mouse is busy (" .. tostring(why) .. ")", "warn") end
    return ok
  end

  U.on("hotkey", function(name)
    if name == "hide" then
      LAYOUT.toggleHide()
    elseif name == "play" then
      if PARTY.role() == "host" then PARTY.togglePlay()
      elseif PARTY.role() == "peer" then MAIN.toast("Only the host (" .. PARTY.hostName() .. ") can pause", "info") end
    elseif name == "setup" then
      PARTY.toggleSetup()
    elseif name == "pointer" then
      MAIN.togglePointer()
    end
  end)

  U.on("party.changed", function()
    local open = PARTY.setupOpen()
    if open ~= lastSetup then
      lastSetup = open
      if open then
        -- in a match there is no cursor: the panel brings the pointer with it, and closes when it goes
        local ok, x = pcall(wum.input.cursor)
        if not (ok and x) and not pointerActive() and pointerOn() then pointerForSetup = true end
      else
        if pointerForSetup and pointerActive() then pointerOff() end
        pointerForSetup = false
      end
    end
    local ph = PARTY.phase()
    if ph ~= lastPhase then
      lastPhase = ph
      if LAYOUT.view() == "hidden" and PHASE_TOAST[ph] then MAIN.toast(PHASE_TOAST[ph], "info") end
    end
  end)

  ---------------------------------------------------------------- toasts

  local function drawToasts()
    local now = U.now()
    for i = #toasts, 1, -1 do
      local t = toasts[i]
      local alive
      if t.keep then alive = t.keep() and (not t.life or now - t.at < t.life)
      else alive = now - t.at < (t.life or TOAST_MS) end
      if not alive then table.remove(toasts, i) end
    end
    local s = SKIN.s
    local ww = select(1, wum.render.windowSize())
    local y = 20 * s
    local h, size = 46 * s, 17 * s
    for i = 1, math.min(#toasts, MAX_TOASTS) do
      local t = toasts[i]
      local life = t.life or TOAST_MS
      local left = t.keep and math.huge or (life - (now - t.at))
      local a = U.clamp(left / 300, 0, 1) * U.clamp((now - t.at) / 150, 0, 1)
      local base = SKIN.alpha
      SKIN.alpha = base * a
      local tw = math.min(SKIN.measure(t.text, size, "display"), ww * 0.5)
      local bws = {}
      local bw = 0
      for j, act in ipairs(t.actions or {}) do
        bws[j] = SKIN.measure(act[1], 15 * s, "display") + 36 * s
        bw = bw + bws[j] + 8 * s
      end
      local icon = (t.kind == "warn" or t.kind == "error") and "warning" or nil
      local iw = icon and 30 * s or 0
      local w = tw + iw + bw + 40 * s
      local x0 = (ww - w) / 2
      W.active = t.actions ~= nil and left > 300
      if t.actions then W.region("main.toast." .. i, x0, y, x0 + w, y + h, "arrow") end
      SKIN.nine("tooltip", x0, y, x0 + w, y + h)
      local x = x0 + 18 * s
      if icon then
        SKIN.icon(icon, x, y + (h - 26 * s) / 2, 26 * s)
        x = x + iw
      end
      SKIN.text(x, y, t.text, size, t.kind == "error" and C.error or C.cream,
        {kind = "display", vcenter = h, maxWidth = tw + 1})
      x = x + tw + 12 * s
      for j, act in ipairs(t.actions or {}) do
        local bid = "main.toast." .. i .. "." .. j
        if W.button(bid, x, y + 6 * s, x + bws[j], y + h - 6 * s, act[1], {size = 15 * s}) then
          for k, o in ipairs(toasts) do if o == t then table.remove(toasts, k) break end end
          local ok, err = pcall(act[2])
          if not ok then U.log("error", "toast action", err) end
        end
        x = x + bws[j] + 8 * s
      end
      SKIN.alpha = base
      W.active = true
      y = y + h + 8 * s
    end
  end

  ---------------------------------------------------------------- the frame

  local pieces = {
    {"draw.player", function() PUI.draw() end},
    {"draw.setup", function() SETUP.draw() end},
    {"draw.toasts", drawToasts},
    {"draw.popover", function() W.drawPopover() end},
  }
  for _, p in ipairs(pieces) do p[2] = U.guard(p[1], p[2]) end

  function MAIN.draw()
    SKIN.ensure()
    SKIN.s = LAYOUT.scale()
    W.beginFrame()
    for _, p in ipairs(pieces) do
      SKIN.alpha, W.active = 1, true
      p[2]()
    end
    SKIN.alpha, W.active = 1, true
    W.endFrame()
    -- the pointer the panel brought ended (a click outside, Esc, my turn): the panel goes with it
    if pointerForSetup and not pointerActive() then
      pointerForSetup = false
      if PARTY.setupOpen() then PARTY.setSetup(false) end
    end
  end

  wum.draw.on("screen", U.guard("draw", MAIN.draw))
end
