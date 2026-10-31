-- player UI (P3): the video in its frame at the LAYOUT rect (corner or half panel), the control bar of design 2.7,
-- the minimised pill and the small idle pills (Watch party, Join, Continue party). The picture comes from
-- wum.draw.media(PARTY.player(), ...) and the frame hugs the rect it returns. Controls show 100 ms after the cursor
-- enters the player and hide 1.5 s after it stops moving; their rects are claimed only while they show and only
-- while LAYOUT.interactive() (not faded, not auto-hidden). Peers get the same bar read-only for the shared controls
-- (play, seek, skip, speed) and their own volume, subtitles, audio track and quality.
do
  local C = SKIN.C
  local SHOW_AFTER, HIDE_AFTER, FADE = 100, 1500, 0.25   -- ms, ms, s
  local SCRUB_EVERY = 150                                 -- ms between keyframe seeks while dragging
  local QUALITIES = {360, 480, 720, 1080}

  local hoverSince = nil
  local ctrlA, lastT = 0, nil
  local lastScrub = -1e9
  local shown = false            -- the controls show this frame (and their regions are claimed)
  local idleDismissed = {}       -- "continue" -> true once the user closed that pill
  local lastView = "full"        -- the view a hide fades out from

  function PUI.controlsShown() return shown end

  ---------------------------------------------------------------- reads

  local function pstate() return PARTY.state() end

  local function isLive(st)
    local it = QUEUE.current()
    if it and it.live then return true end
    return st ~= nil and not (U.num(st.duration) and st.duration > 0) and PARTY.phase() == "playing"
  end

  -- The host's position now, from its last st (peers: through the bus clock offset), or nil.
  function PUI.hostPos()
    local hs = PARTY.hostState()
    if type(hs) ~= "table" or not U.num(hs.p) then return nil end
    local p = hs.p
    if hs.s == "play" and U.num(hs.a) then
      local off = 0
      local c = NET.hostId() and NET.clock(NET.hostId())
      if c and U.num(c.offset) then off = c.offset end
      p = p + math.max(0, (U.now() + off) - hs.a) / 1000 * (U.num(hs.r) or 1)
    end
    return math.max(0, p)
  end

  local function speedNow()
    local hs = PARTY.hostState()
    local st = pstate()
    return (hs and U.num(hs.r)) or (st and U.num(st.speed)) or 1
  end

  local function fmtSpeed(x)
    local s = string.format("%.2f", x):gsub("0+$", ""):gsub("%.$", "")
    return s .. "x"
  end

  local function title()
    local it = QUEUE.current()
    local st = pstate()
    local t = (it and it.title) or (st and st.title) or ""
    if t == "" then t = "Watch party" end
    return t
  end

  local function volIcon()
    if PARTY.muted() then return "mute" end
    local v = PARTY.volume()
    if v <= 0 then return "vol0" elseif v < 50 then return "vol1" end
    return "vol2"
  end

  ---------------------------------------------------------------- popovers

  local function trackItems(kind)
    local st = pstate()
    local list = st and st.tracks and st.tracks[kind] or {}
    local items = {}
    if kind == "sub" then
      local any = false
      for _, t in ipairs(list) do any = any or t.selected end
      items[1] = {label = "Off", value = false, on = not any}
    end
    for i, t in ipairs(list) do
      local label = U.trim(t.title, 40)
      if label == "" then label = type(t.lang) == "string" and t.lang or ("Track " .. i) end
      if type(t.lang) == "string" and t.title and t.title ~= "" then label = label .. " (" .. t.lang .. ")" end
      items[#items + 1] = {label = label, value = t.id, on = t.selected == true}
    end
    if #items == 0 then items[1] = {label = "No tracks", value = nil, enabled = false} end
    return items
  end

  local openers = {}

  function openers.speed(x0, y0, x1, y1, owner)
    local items, cur, host = {}, speedNow(), PARTY.role() == "host"
    for _, s in ipairs(PARTY.SPEEDS) do
      items[#items + 1] = {label = fmtSpeed(s), value = s, on = math.abs(s - cur) < 0.01, enabled = host}
    end
    W.togglePopover("pui.speed", x0, y0, x1, y1, items, function(v) PARTY.setSpeed(v) end,
      host and "Speed (everyone)" or "Speed (set by the host)", owner)
  end

  function openers.cc(x0, y0, x1, y1, owner)
    W.togglePopover("pui.cc", x0, y0, x1, y1, trackItems("sub"), function(v)
      if v ~= nil then PARTY.setTrack("sub", v) end
    end, "Subtitles", owner)
  end

  function openers.audio(x0, y0, x1, y1, owner)
    W.togglePopover("pui.audio", x0, y0, x1, y1, trackItems("audio"), function(v)
      if v ~= nil then PARTY.setTrack("audio", v) end
    end, "Audio track", owner)
  end

  function openers.quality(x0, y0, x1, y1, owner)
    local items, q = {}, PARTY.quality()
    for _, h in ipairs(QUALITIES) do items[#items + 1] = {label = h .. "p", value = h, on = q == h} end
    W.togglePopover("pui.quality", x0, y0, x1, y1, items, function(v) PARTY.setQuality(v) end, "Max quality",
      owner)
  end

  -- The corner's "..." popover holds what the collapsed bar leaves out.
  function openers.more(x0, y0, x1, y1)
    local host = PARTY.role() == "host"
    local items = {
      {label = "Previous", value = "prev", enabled = host},
      {label = "Next", value = "next", enabled = host},
      {label = "Speed: " .. fmtSpeed(speedNow()), value = "speed"},
      {label = "Audio track", value = "audio"},
      {label = "Quality: " .. PARTY.quality() .. "p", value = "quality"},
      {label = "Queue and players", value = "setup"},
      {label = "Music", value = "music"},
      {label = "Minimise", value = "pill"},
      {label = "Hide", value = "hide"},
    }
    W.togglePopover("pui.more", x0, y0, x1, y1, items, function(v)
      if v == "prev" then PARTY.prev()
      elseif v == "next" then PARTY.next()
      elseif v == "setup" then PARTY.setSetup(true)
      elseif v == "music" then
        PARTY.setSetup(true)
        SETUP.setTab("music")
      elseif v == "pill" then LAYOUT.setView("pill")
      elseif v == "hide" then LAYOUT.setView("hidden")
      elseif openers[v] then openers[v](x0, y0, x1, y1, "pui.more") end
    end)
  end
  PUI.openers = openers

  -- An icon button that opens a popover; drawn pressed while its popover is open.
  local function popButton(name, icon, x, y, size)
    local id = "pui." .. name
    local open = W.isOpen(id)
    if W.iconButton(id, icon, x, y, size, true, open) then openers[name](x, y, x + size, y + size) end
  end

  -- A small text chip (speed, quality, "...") that opens a popover.
  local function popChip(name, label, x, y, w, h)
    local id = "pui." .. name
    local open = W.isOpen(id)
    if W.button(id, x, y, x + w, y + h, label, {on = open, kind = "display"}) then openers[name](x, y, x + w, y + h) end
  end

  ---------------------------------------------------------------- shared pieces

  -- The seek bar: the host drags it (keyframe seeks while dragging, an exact seek on release); peers see it
  -- read-only with a white host marker.
  local function seekBar(id, x0, y0, x1, y1)
    local st = pstate()
    local dur = st and U.num(st.duration) or 0
    local t = st and U.num(st.time) or 0
    if isLive(st) then
      SKIN.nine("bar_track", x0, y0, x1, y1)
      return
    end
    local host = PARTY.role() == "host" and PARTY.player() ~= nil and dur > 0
    local frac = dur > 0 and t / dur or 0
    local buffered = dur > 0 and st and U.num(st.cacheAhead) and (t + st.cacheAhead) / dur or nil
    local marker
    if PARTY.role() == "peer" and dur > 0 then
      local hp = PUI.hostPos()
      if hp then marker = hp / dur end
    end
    local v, changed, released = W.slider(id, x0, y0, x1, y1, frac, {readonly = not (host and shown), buffered = buffered,
      marker = marker, grab = (y1 - y0) * 0.6})
    if host and changed then
      local now = U.now()
      if released then
        PARTY.seek(v * dur, "exact")
      elseif now - lastScrub >= SCRUB_EVERY then
        lastScrub = now
        PARTY.seek(v * dur, "keyframes")
      end
    end
  end

  local function timeText(st)
    if isLive(st) then return "LIVE" end
    local t, d = st and U.num(st.time) or 0, st and U.num(st.duration) or 0
    return U.fmtTime(t) .. " / " .. U.fmtTime(d)
  end

  local function driftText(st)
    if PARTY.role() ~= "peer" or not st or isLive(st) then return nil end
    local d = U.num(st.drift)
    if not d then return nil end
    return string.format("%+.2f s", d)
  end

  local PHASE_TEXT = {loading = "Loading...", buffering = "Buffering...", ["ended-item"] = "Finished",
    ["needs-pack"] = "This machine needs the media pack"}

  -- The status over the picture: spinner and text while loading, the pack download while it is missing.
  local function overlay(vx0, vy0, vx1, vy1, s, big)
    local ph = PARTY.phase()
    local cx, cy = (vx0 + vx1) / 2, (vy0 + vy1) / 2
    if ph == "needs-pack" then
      local pk = PARTY.pack() or {}
      local size = (big and 22 or 16) * s
      if pk.state == "downloading" or pk.state == "verifying" or pk.state == "installing" or pk.state == "updating" then
        local p = U.clamp(U.num(pk.progress) or 0, 0, 1)
        SKIN.text(cx, cy - 34 * s, "Downloading the media pack " .. math.floor(p * 100) .. "%", size, C.cream,
          {align = "center", maxWidth = vx1 - vx0 - 24 * s})
        local w = (vx1 - vx0) * 0.6
        SKIN.nine("bar_track", cx - w / 2, cy, cx + w / 2, cy + 12 * s)
        SKIN.nine("bar_fill", cx - w / 2 + 2 * s, cy + 2 * s, cx - w / 2 + 2 * s + math.max((w - 4 * s) * p, 8 * s),
          cy + 10 * s)
        return
      end
      SKIN.text(cx, vy0 + 14 * s, PHASE_TEXT[ph], size, C.title, {align = "center", kind = "display",
        maxWidth = vx1 - vx0 - 24 * s})
      local mb = math.floor(U.num(pk.downloadMB) or 95)
      local bw, bh = math.min(320 * s, vx1 - vx0 - 24 * s), 44 * s
      local by = cy - bh / 2
      if W.button("pui.pack", cx - bw / 2, by, cx + bw / 2, by + bh, "Download media pack (" .. mb .. " MB)",
        {icon = "download", size = (big and 20 or 16) * s}) then
        PARTY.installPack()
      end
      local note = big and PARTY.consentText() or ("From Melange's GitHub releases into Documents\\Melange\\media")
      local lines = SKIN.wrap(note, 14 * s, "body", vx1 - vx0 - 32 * s, big and 5 or 2)
      for i, ln in ipairs(lines) do
        SKIN.text(cx, by + bh + 8 * s + (i - 1) * 18 * s, ln, 14 * s, C.cream, {align = "center"})
      end
      return
    end
    local text = PHASE_TEXT[ph]
    if ph == "paused" and PARTY.role() == "peer" then text = "Paused by the host" end
    if ph == "loading" or ph == "buffering" then
      local is = (big and 56 or 40) * s
      SKIN.icon(SKIN.spinner(), cx - is / 2, cy - is / 2 - 10 * s, is)
      SKIN.text(cx, cy + is / 2 - 4 * s, text, (big and 20 or 16) * s, C.cream, {align = "center", kind = "display"})
    elseif text then
      SKIN.text(cx, cy - 12 * s, text, (big and 22 or 16) * s, C.cream, {align = "center", kind = "display"})
    end
  end

  -- The peers' status icons (ready, buffering, no pack, no Holo, error), right to left from x1.
  local PEER_ICON = {ready = "check", nopack = "download", noholo = "cross", error = "warning"}
  local function peerIcons(x1, y, size, max)
    local peers = PARTY.peers()
    local x = x1
    for i = 1, math.min(#peers, max) do
      local p = peers[i]
      local icon = p.state == "buffering" and SKIN.spinner() or PEER_ICON[p.state] or "people"
      x = x - size
      SKIN.icon(icon, x, y, size, p.state == "noholo" and "off" or "normal")
      x = x - size * 0.15
    end
    return x
  end

  ---------------------------------------------------------------- the control bars

  local function controlsVisible(hx0, hy0, hx1, hy1, interactive)
    local now = U.now()
    local inside = interactive and W.inside(hx0, hy0, hx1, hy1)
    if inside then hoverSince = hoverSince or now else hoverSince = nil end
    local want = inside and now - hoverSince >= SHOW_AFTER and now - W.lastMove < HIDE_AFTER
    -- an open popover, a drag or the pointer over a control keeps them up
    want = want or (interactive and (W.popoverOpen() or W.held("pui.seek") or W.held("pui.vol")))
    -- In match pointer mode the player brought the mouse here to use the controls: a resting pointer keeps them up,
    -- or a click on a control after 1.5 s would land outside every region and end pointer mode instead.
    if not want and inside and now - hoverSince >= SHOW_AFTER then
      local ok, on = pcall(wum.input.pointerActive)
      want = ok and on == true
    end
    return want
  end

  -- The corner's collapsed bar inside the bottom of the picture: play, -10, +10, volume, CC, "...", minimise.
  local function cornerBar(vx0, vy0, vx1, vy1, s)
    local host = PARTY.role() == "host"
    local barH = 56 * s
    local by0 = vy1 - barH
    SKIN.part("scrim", vx0, vy1 - barH * 1.8, vx1, vy1, {a = 0.85})
    W.region("pui.bar", vx0, by0, vx1, vy1, "arrow")
    seekBar("pui.seek", vx0 + 10 * s, by0 + 2 * s, vx1 - 10 * s, by0 + 12 * s)
    local is, gap = 32 * s, 4 * s
    local x, y = vx0 + 8 * s, vy1 - is - 6 * s
    local playing = PARTY.phase() == "playing" or (PARTY.hostState() or {}).s == "play"
    if W.iconButton("pui.play", playing and "pause" or "play", x, y, is, host) then PARTY.togglePlay() end
    x = x + is + gap
    if W.iconButton("pui.back10", "back10", x, y, is, host) then PARTY.skip(-10) end
    x = x + is + gap
    if W.iconButton("pui.fwd10", "fwd10", x, y, is, host) then PARTY.skip(10) end
    x = x + is + gap
    if W.iconButton("pui.mute", volIcon(), x, y, is) then PARTY.setMute(not PARTY.muted()) end
    x = x + is + gap
    popButton("cc", "cc", x, y, is)
    x = x + is + gap
    local rx = vx1 - 8 * s - is
    if W.iconButton("pui.min", "minimise", rx, y, is) then LAYOUT.setView("pill") end
    rx = rx - gap - 44 * s
    popChip("more", "...", rx, y, 44 * s, is)
    local tx = x + 4 * s
    if rx - tx > 60 * s then
      SKIN.text(tx, y, timeText(pstate()), 14 * s, C.cream, {vcenter = is, maxWidth = rx - tx - 4 * s})
    end
  end

  -- The half panel's full bar under the picture.
  local function halfBar(x0, y0, x1, y1, s, interactive)
    local host = PARTY.role() == "host"
    local st = pstate()
    seekBar("pui.seek", x0 + 6 * s, y0 + 6 * s, x1 - 6 * s, y0 + 18 * s)
    local is, gap = 34 * s, 5 * s
    local y = y0 + 24 * s
    local x = x0 + 4 * s
    local playing = PARTY.phase() == "playing" or (PARTY.hostState() or {}).s == "play"
    W.active = interactive
    if W.iconButton("pui.prev", "prev", x, y, is, host) then PARTY.prev() end
    x = x + is + gap
    if W.iconButton("pui.back10", "back10", x, y, is, host) then PARTY.skip(-10) end
    x = x + is + gap
    if W.iconButton("pui.play", playing and "pause" or "play", x, y, is, host) then PARTY.togglePlay() end
    x = x + is + gap
    if W.iconButton("pui.fwd10", "fwd10", x, y, is, host) then PARTY.skip(10) end
    x = x + is + gap
    if W.iconButton("pui.next", "next", x, y, is, host) then PARTY.next() end
    x = x + is + gap * 2
    -- right side, from the edge inwards
    local rx = x1 - 4 * s - is
    if W.iconButton("pui.hide", "hide", rx, y, is) then LAYOUT.setView("hidden") end
    rx = rx - gap - is
    if W.iconButton("pui.min", "minimise", rx, y, is) then LAYOUT.setView("pill") end
    rx = rx - gap - is
    if W.iconButton("pui.queue", "queue", rx, y, is, true, PARTY.setupOpen()) then PARTY.toggleSetup() end
    rx = rx - gap - 64 * s
    popChip("quality", PARTY.quality() .. "p", rx, y, 64 * s, is)
    rx = rx - gap - is
    popButton("audio", "audio", rx, y, is)
    rx = rx - gap - is
    popButton("cc", "cc", rx, y, is)
    rx = rx - gap - 60 * s
    popChip("speed", fmtSpeed(speedNow()), rx, y, 60 * s, is)
    local sw = 90 * s
    rx = rx - gap * 2 - sw
    local v, changed = W.slider("pui.vol", rx, y + is * 0.36, rx + sw, y + is * 0.64, PARTY.volume() / 100,
      {grab = 8 * s})
    if changed then
      PARTY.setVolume(v * 100)
      if PARTY.muted() and v > 0 then PARTY.setMute(false) end
    end
    rx = rx - gap - is
    if W.iconButton("pui.mute", volIcon(), rx, y, is) then PARTY.setMute(not PARTY.muted()) end
    -- time (and the peer's drift) between the transport and the right group
    local text = timeText(st)
    local drift = driftText(st)
    if drift then text = text .. "   " .. drift end
    if rx - x > 40 * s then
      SKIN.text(x, y, text, 16 * s, C.cream, {vcenter = is, maxWidth = rx - x - 6 * s})
    end
  end

  ---------------------------------------------------------------- views

  local function drawFull(s, now, dt)
    local vx0, vy0, vx1, vy1 = LAYOUT.rect()
    local half = LAYOUT.anchor() == "half"
    local interactive = LAYOUT.interactive()
    local pad, tagH, barH = 12 * s, 44 * s, 64 * s
    local px0, py0, px1, py1 = vx0 - pad, vy0 - tagH, vx1 + pad, vy1 + barH
    local hx0, hy0, hx1, hy1 = vx0, vy0, vx1, vy1
    if half then hx0, hy0, hx1, hy1 = px0, py0, px1, py1 end

    W.active = interactive
    shown = controlsVisible(hx0, hy0, hx1, hy1, interactive)
    ctrlA = U.clamp(ctrlA + (shown and 1 or -1) * dt / FADE, 0, 1)
    local baseA = SKIN.alpha
    -- In match pointer mode the game gets no mouse at all, so the whole player is claimed: a click on the picture
    -- before the bar has shown (100 ms) or after it faded would land outside every region and end pointer mode, and
    -- the next click would then go to the game. Claimed first, so the bar's controls stay on top of it.
    if interactive then
      local ok, on = pcall(wum.input.pointerActive)
      if ok and on == true then W.region("pui.area", hx0, hy0, hx1, hy1, "arrow") end
    end

    if half then
      SKIN.nine("panel", px0, py0, px1, py1)
      if shown then
        W.active = interactive
        W.region("pui.panel", px0, py0, px1, py1, "arrow")
      end
      -- the title tag, and the peers' status at its right
      local tagW = math.min((px1 - px0) * 0.62, SKIN.measure(title(), 20 * s, "tag") + 48 * s)
      SKIN.nine("tag", px0 + 14 * s, py0 + 6 * s, px0 + 14 * s + tagW, py0 + tagH - 4 * s)
      SKIN.text(px0 + 14 * s + 20 * s, py0 + 6 * s, title(), 20 * s, C.ink,
        {kind = "tag", vcenter = tagH - 10 * s, maxWidth = tagW - 36 * s})
      peerIcons(px1 - 14 * s, py0 + 10 * s, 24 * s, 8)
    end

    -- the picture, then the frame hugging the rect it took
    local p = PARTY.player()
    local qx0, qy0, qx1, qy1
    if p and wum.draw.media then
      local ok, a, b, c, d = pcall(wum.draw.media, p, vx0, vy0, vx1, vy1, {fit = "contain", alpha = SKIN.alpha})
      if ok and type(a) == "number" then qx0, qy0, qx1, qy1 = a, b, c, d end
    end
    if not qx0 then
      qx0, qy0, qx1, qy1 = vx0, vy0, vx1, vy1
      SKIN.rect(qx0, qy0, qx1, qy1, C.dark, 0.92)
    end
    SKIN.frameAround(half and "frame_video" or "frame_corner", qx0, qy0, qx1, qy1)
    overlay(vx0, vy0, vx1, vy1, s, half)

    if half then
      W.active = shown and interactive
      halfBar(px0 + pad * 0.5, vy1 + 2 * s, px1 - pad * 0.5, py1 - 4 * s, s, shown and interactive)
    elseif ctrlA > 0 then
      SKIN.alpha = baseA * ctrlA
      W.active = shown and interactive
      cornerBar(vx0, vy0, vx1, vy1, s)
      SKIN.alpha = baseA
    end
    W.active = true
  end

  -- The pill: state, title, time and an expand button.
  local function drawPill(s)
    local x0, y0, x1, y1 = LAYOUT.pillRect()
    local h = y1 - y0
    W.active = LAYOUT.interactive()
    W.region("pui.pill", x0, y0, x1, y1, "arrow")
    SKIN.nine("pill", x0, y0, x1, y1)
    local is = h * 0.62
    local iy = y0 + (h - is) / 2
    local ph = PARTY.phase()
    local host = PARTY.role() == "host"
    local x = x0 + h * 0.3
    if ph == "loading" or ph == "buffering" then
      SKIN.icon(SKIN.spinner(), x, iy, is)
    elseif ph == "needs-pack" then
      if W.iconButton("pui.pillpack", "download", x, iy, is) then PARTY.installPack() end
    else
      local playing = ph == "playing"
      if W.iconButton("pui.pillplay", playing and "pause" or "play", x, iy, is, host) then PARTY.togglePlay() end
    end
    x = x + is + 6 * s
    local ex = x1 - h * 0.3 - is
    if W.iconButton("pui.expand", "expand", ex, iy, is) then LAYOUT.setView("full") end
    local label = ph == "needs-pack" and "Download media pack" or title()
    SKIN.text(x, y0 + h * 0.12, label, 15 * s, C.cream, {kind = "display", maxWidth = ex - x - 6 * s})
    SKIN.text(x, y0 + h * 0.5, ph == "needs-pack" and "Click the arrow to download" or timeText(pstate()), 12 * s,
      C.gold, {maxWidth = ex - x - 6 * s})
    W.active = true
  end

  -- Idle: a "Continue party" pill for a new lobby owner, "Join" for a declined running party, and a "Watch party"
  -- pill in the lobby. Returns true if it drew one.
  local function drawIdle(s)
    if LAYOUT.view() == "hidden" or LAYOUT.autoHidden() then return false end
    local label, action, icon, dismiss
    if PARTY.canContinue() and not idleDismissed.continue then
      label, icon, dismiss = "Continue party", "play", "continue"
      action = function() PARTY.continueParty() end
    elseif PARTY.partyRunning() then
      label, icon = "Join " .. PARTY.hostName() .. "'s watch party", "people"
      action = function() PARTY.join() end
    elseif NET.inSession() and NET.phase() == "lobby" and not PARTY.setupOpen() then
      label, icon = "Watch party", "people"
      action = function() PARTY.setSetup(true) end
    else
      return false
    end
    local x0, y0, x1, y1 = LAYOUT.pillRect()
    local h = y1 - y0
    local w = math.min(SKIN.measure(label, 17 * s, "display") + h * 1.6 + (dismiss and h or 0), x1 - x0 + 120 * s)
    if LAYOUT.side() == "right" then x0 = x1 - w else x1 = x0 + w end
    W.active = LAYOUT.interactive()
    local bx1 = dismiss and x1 - h * 0.9 or x1
    if W.button("pui.idle", x0, y0, bx1, y1, label, {icon = icon, size = 17 * s}) then action() end
    if dismiss and W.iconButton("pui.idlex", "close", bx1 + h * 0.08, y0 + h * 0.14, h * 0.72) then
      idleDismissed[dismiss] = true
    end
    W.active = true
    return true
  end

  -- A new owner change offers Continue again.
  U.on("party.continuePrompt", function() idleDismissed.continue = nil end)

  function PUI.draw()
    local s = SKIN.s
    local now = U.now()
    local dt = lastT and U.clamp((now - lastT) / 1000, 0, 0.25) or 0
    lastT = now
    shown = false
    if not PARTY.active() then
      hoverSince, ctrlA = nil, 0
      drawIdle(s)
      return
    end
    local alpha = LAYOUT.alpha()
    if alpha <= 0.01 then
      hoverSince, ctrlA = nil, 0
      return
    end
    local base = SKIN.alpha
    SKIN.alpha = base * alpha
    local view = LAYOUT.view()
    if view == "hidden" then view = lastView else lastView = view end
    if view == "pill" then
      drawPill(s)
    elseif view == "full" then
      drawFull(s, now, dt)
    end
    SKIN.alpha = base
  end
end
