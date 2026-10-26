-- layout (P2): where the player sits (design 2.3 and 2.4), the view (full, pill, hidden), the auto-hide gate while
-- this machine aims and fires, and the fades. It never draws and never claims regions; P3 draws from these rects.
-- Bus events: "layout.view" (view), "layout.anchor" (anchor), "layout.size" (w, h) once an animation settles.
do
  local ANIM, CTRL_FADE, FADE = 0.35, 0.25, 0.15     -- seconds
  local FADED = 0.3                                    -- alpha under a pause menu or the weapon panel
  local MARGIN, FRAME, PANEL_PAD, TAG, BAR = 24, 9, 12, 44, 64
  -- Pixels at 1080p between the top margin and the corner player, so the wind disc and the worm health badge under
  -- it stay visible. Measured from match screenshots (1920x1080 and 1280x720, the HUD scales with the height): the
  -- disc spans y 81..213 and the badge with its team bars y 270..365 at 1080p, so the frame starts at
  -- 24 + 347 = 371 and its picture at 380. The left corner uses the same offset, which also clears the radar (y 70..260).
  local WIND_OFFSET = 347
  local SETTLE_QUIET, FLIGHT_FAILSAFE = 0.6, 8         -- the flight gate (seconds)
  -- Only first-person aiming (Q held) means "aiming": WormAiming, Fire and UtilityFire are switched on for the whole of
  -- one's own turn whenever the worm holds a weapon (measured in game: Menu, InGame, WormAiming, WormMoving,
  -- CameraSelect, Fire, CrateChuteRelease while just standing), so they would hide the player for every turn.
  -- Third-person charging is covered by the fire-held gate and the shot by the flight gate.
  local AIM_GROUPS = {WormFirstPersonAiming = true}
  LAYOUT.WIND_OFFSET = WIND_OFFSET

  -- "hidden" lasts for the session only: a launch starts shown, so a party joined later is never silent and unseen.
  local lastShown = U.pref("lastShown", "full") == "pill" and "pill" or "full"
  local view = U.pref("view", "full")
  if view ~= "full" and view ~= "pill" then view = lastShown end
  local anchor = "corner"
  local cur, from, animT = nil, nil, nil     -- displayed rect {x0, y0, x1, y1}; animation start rect and time
  local winW, winH = 0, 0
  local alpha, alphaTarget, ctrlAlpha = 1, 1, 1
  local faded, autoHidden = false, false
  local sentW, sentH = nil, nil
  -- the auto-hide gate
  local fireDown, inFlight, flightAt, boomAt = false, false, 0, nil

  local function now() return U.now() / 1000 end

  function LAYOUT.view() return view end
  function LAYOUT.anchor() return anchor end
  function LAYOUT.alpha() return alpha end
  function LAYOUT.controlsAlpha() return ctrlAlpha * alpha end
  function LAYOUT.autoHidden() return autoHidden end
  function LAYOUT.faded() return faded end
  function LAYOUT.side() return CFG.get("panelSide") == "left" and "left" or "right" end
  function LAYOUT.animating() return animT ~= nil end

  -- Interactive means P3 may claim regions: shown, not faded, not auto-hidden, and fully faded in.
  function LAYOUT.interactive()
    return view ~= "hidden" and not autoHidden and not faded and alpha >= 0.95
  end

  local function baseScale(h) return U.clamp(h / 1080, 0.6, 2.5) end
  function LAYOUT.scale()
    local _, h = wum.render.windowSize()
    return baseScale(h) * CFG.get("uiScale") / 100
  end

  function LAYOUT.setView(v)
    if v ~= "full" and v ~= "pill" and v ~= "hidden" then return false end
    if v ~= "hidden" then
      lastShown = v
      U.setPref("lastShown", v)
    end
    if v == view then return true end
    view = v
    U.setPref("view", v)
    U.emit("layout.view", v)
    return true
  end

  -- The hide hotkey: full or pill <-> hidden (back to the last shown view).
  function LAYOUT.toggleHide()
    if view == "hidden" then return LAYOUT.setView(lastShown) end
    return LAYOUT.setView("hidden")
  end

  ---------------------------------------------------------------- rects

  -- The corner video rect for a window: 22 % of min(W, H*16/9) wide (times uiScale), 16:9, inside a 9 px frame
  -- with a 24 px margin, below the wind disc.
  function LAYOUT.cornerRect(W, H, side)
    local s0 = baseScale(H)
    local k = CFG.get("uiScale") / 100
    local s = s0 * k
    local vw = 0.22 * math.min(W, H * 16 / 9) * k
    local vh = vw * 9 / 16
    local y0 = MARGIN * s + WIND_OFFSET * s0 + FRAME * s
    local x0
    if side == "left" then x0 = MARGIN * s + FRAME * s else x0 = W - MARGIN * s - FRAME * s - vw end
    return x0, y0, x0 + vw, y0 + vh
  end

  -- The half panel: video, title tag above and control bar below, vertically centred in one half of the window.
  -- Returns the video rect and the panel rect (tag and bar included).
  function LAYOUT.halfRects(W, H, side)
    local s = baseScale(H) * CFG.get("uiScale") / 100
    local m, pad, tag, bar = MARGIN * s, PANEL_PAD * s, TAG * s, BAR * s
    local px0, px1
    if side == "left" then px0, px1 = m, W / 2 - m else px0, px1 = W / 2 + m, W - m end
    local vw = (px1 - px0) - 2 * pad
    local vh = vw * 9 / 16
    local room = H - 2 * m - tag - bar
    if vh > room then
      vh = math.max(room, 1)
      vw = vh * 16 / 9
      local cx = (px0 + px1) / 2
      px0, px1 = cx - vw / 2 - pad, cx + vw / 2 + pad
    end
    local total = tag + vh + bar
    local py0 = (H - total) / 2
    local vx0 = px0 + pad
    local vy0 = py0 + tag
    return {vx0, vy0, vx0 + vw, vy0 + vh}, {px0, py0, px1, py0 + total}
  end

  local function target()
    local side = LAYOUT.side()
    if anchor == "half" then
      local v = LAYOUT.halfRects(winW, winH, side)
      return v
    end
    return {LAYOUT.cornerRect(winW, winH, side)}
  end

  function LAYOUT.rect()
    local r = cur or target()
    return r[1], r[2], r[3], r[4]
  end

  function LAYOUT.panelRect()
    local _, p = LAYOUT.halfRects(winW, winH, LAYOUT.side())
    return p[1], p[2], p[3], p[4]
  end

  -- The minimised pill, at the top of the player's side.
  function LAYOUT.pillRect()
    local s = baseScale(winH) * CFG.get("uiScale") / 100
    local w, h = 300 * s, 56 * s
    local y0 = MARGIN * s + WIND_OFFSET * baseScale(winH)
    if LAYOUT.side() == "left" then return MARGIN * s, y0, MARGIN * s + w, y0 + h end
    return winW - MARGIN * s - w, y0, winW - MARGIN * s, y0 + h
  end

  -- What the decoder should render once the rect settled: 422x238 (corner) or 960x540 (half, at most 1280x720),
  -- scaled like the layout.
  function LAYOUT.sizeHint()
    local s = baseScale(winH > 0 and winH or 1080) * CFG.get("uiScale") / 100
    if anchor == "half" then
      local w = math.min(960 * s, 1280)
      return math.floor(w + 0.5), math.floor(w * 9 / 16 + 0.5)
    end
    return math.floor(422 * s + 0.5), math.floor(238 * s + 0.5)
  end

  ---------------------------------------------------------------- the rules

  local function inMatch()
    if wum.game.inMatch then
      local ok, v = pcall(wum.game.inMatch)
      if ok and v then return true end
    end
    return NET.phase() == "match"
  end

  local function onlineMatch()
    if not inMatch() then return false end
    return NET.inSession() or wum.game.online() == true
  end

  local function turnInfo()
    local ok, t = pcall(wum.game.turn)
    return ok and type(t) == "table" and t or nil
  end

  local function uiFlags()
    local ok, u = pcall(wum.game.ui)
    return ok and type(u) == "table" and u or {}
  end

  -- The anchor the table of design 2.4 gives now, or nil to keep the last one (between turns, the Ready? intro).
  function LAYOUT.ruleAnchor()
    if not onlineMatch() then return "corner" end
    local t, u = turnInfo(), uiFlags()
    if not t or u.readyIntro or t.team == nil then return nil end
    if t.mine then return "corner" end
    return CFG.get("bigOnOthers") and "half" or "corner"
  end

  local function myTurn(t)
    return inMatch() and t ~= nil and t.mine == true and t.team ~= nil
  end

  local function aiming()
    local ok, g = pcall(wum.input.groups)
    if not ok or type(g) ~= "table" then return false end
    for _, name in ipairs(g) do
      if AIM_GROUPS[name] then return true end
    end
    return false
  end

  local function resetFlight() inFlight, boomAt = false, nil end

  -- Auto-hide: my turn and (an aiming group is active, fire is held, or a shot is in flight). Audio is never muted
  -- by it (I3).
  function LAYOUT.gate()
    if not CFG.get("autoHideAim") then return false end
    local t = turnInfo()
    if not myTurn(t) then return false end
    local n = now()
    if inFlight then
      if (boomAt and n - boomAt >= SETTLE_QUIET) or n - flightAt >= FLIGHT_FAILSAFE then resetFlight() end
    end
    return fireDown or inFlight or aiming()
  end

  local function turnStarted()
    resetFlight()
    fireDown = false
  end

  wum.events.on("Input.FirePressed", U.guard("layout.fire", function() fireDown = true end))
  wum.events.on("Input.FireReleased", U.guard("layout.fire", function() fireDown = false end))
  wum.events.on("Weapon.Fired", U.guard("layout.fired", function()
    inFlight, flightAt, boomAt, fireDown = true, now(), nil, false
  end))
  wum.events.on("Explosion", U.guard("layout.boom", function()
    if inFlight then boomAt = now() end
  end))
  wum.events.on("Timer.StartRetreatTimer", U.guard("layout.retreat", resetFlight))
  wum.events.on("melange.turn", U.guard("layout.turn", turnStarted))
  wum.events.on("GameLogic.Turn.Started", U.guard("layout.turn", turnStarted))
  wum.events.on("melange.match.end", U.guard("layout.matchEnd", turnStarted))

  ---------------------------------------------------------------- update

  local function sameRect(a, b)
    return a and b and a[1] == b[1] and a[2] == b[2] and a[3] == b[3] and a[4] == b[4]
  end

  local function approach(v, goal, rate, dt)
    if v < goal then return math.min(goal, v + rate * dt) end
    return math.max(goal, v - rate * dt)
  end

  function LAYOUT.update(dt)
    dt = U.clamp(U.num(dt) or 0, 0, 0.25)
    local W, H = wum.render.windowSize()
    local resized = W ~= winW or H ~= winH
    winW, winH = W, H

    local want = LAYOUT.ruleAnchor() or anchor
    if want ~= anchor then
      from = cur and {cur[1], cur[2], cur[3], cur[4]} or nil
      anchor = want
      animT = from and 0 or nil
      ctrlAlpha = 0
      U.emit("layout.anchor", anchor)
    end
    local to = target()
    if resized or not cur then
      cur, animT, from = to, nil, nil
    elseif animT then
      animT = animT + dt
      local k = U.easeOutCubic(animT / ANIM)
      cur = {U.lerp(from[1], to[1], k), U.lerp(from[2], to[2], k), U.lerp(from[3], to[3], k),
        U.lerp(from[4], to[4], k)}
      if animT >= ANIM then cur, animT, from = to, nil, nil end
    elseif not sameRect(cur, to) then
      -- a setting changed the target (side, scale): animate there too
      from, animT, ctrlAlpha = cur, 0, 0
    end

    if not animT then
      ctrlAlpha = approach(ctrlAlpha, 1, 1 / CTRL_FADE, dt)
      local w, h = LAYOUT.sizeHint()
      if w ~= sentW or h ~= sentH then
        sentW, sentH = w, h
        U.emit("layout.size", w, h)
      end
    end

    local t, u = turnInfo(), uiFlags()
    faded = u.pause == true or (u.weaponPanel == true and myTurn(t))
    local gate = LAYOUT.gate()
    if gate and not autoHidden then
      autoHidden = true
    elseif not gate and autoHidden then
      autoHidden = false
    end
    if view == "hidden" or autoHidden then alphaTarget = 0
    elseif faded then alphaTarget = FADED
    else alphaTarget = 1 end
    alpha = approach(alpha, alphaTarget, 1 / FADE, dt)
  end

  LAYOUT.update(0)                  -- rects are valid before the first frame
  local last = U.now()
  wum.timers.every(0, U.guard("layout", function()
    local n = U.now()
    LAYOUT.update((n - last) / 1000)
    last = n
  end))
end
