-- setup panel (P3): the 960x640 watch-party panel (design 2.7), opened with the setup hotkey, the "Watch party" pill
-- or the queue button: a link box (focus on click, caret, selection, Ctrl+V, Enter adds, a live classify tick or
-- cross), the queue (52 px rows, only the visible ones drawn, under a clip, wheel scrolling), the torrent file picker
-- (a modal over the panel), the players list (Holo, pack, RTT), the pack consent block and the footer. Peers see the
-- same panel; they can add links while the host's party runs (and remove what they added), nothing else. Two tabs:
-- "Videos" (all of the above) and "Music" (MUI: the party's Spotify music lane and the library modal).
do
  local C = SKIN.C
  local ROW = 52
  local PICK_ROW = 44

  local link = W.newText("setup.link")
  local lastText, lastClass = nil, nil   -- classify result of the link box, recomputed only when the text changes
  local scroll = 0                       -- queue scroll in pixels at scale 1
  local status, statusKind, statusAt = nil, nil, 0
  local picks = {}                       -- pending torrent pickers {token, files, name, sel, scroll}
  local tab = "videos"                   -- "videos" | "music"

  function SETUP.tab() return tab end
  function SETUP.setTab(t)
    if t ~= "videos" and t ~= "music" then return false end
    tab = t
    if t ~= "music" then MUI.closeLibrary() end
    return true
  end

  local ADD_WHY = {
    ["unsupported-url"] = "That is not a YouTube or magnet link",
    ["not-host"] = "Only the lobby host can change the queue",
    full = "The queue is full (200 items)",
    busy = "Too many torrents are open; remove one first",
    ["first-use-in-match"] = "Add the first torrent in the menus or the lobby",
    pack = "Download the media pack first",
    dup = "That is already in the queue",
    rate = "Wait a moment before adding again",
    ["member-full"] = "You already have 50 items in the queue",
    ["host-only"] = "The host adds the videos in this party",
    ["not-running"] = "Adding opens when the host starts the party",
    ["no-answer"] = "The host did not answer",
    ["no-host"] = "The host is not reachable",
    ["old-host"] = "The host's Holo is older than 1.1; ask them to update",
    ["no-video"] = "No video file in this torrent",
    torrent = "The host could not read this torrent",
    ["torrent-slow"] = "The host found no file list for this torrent in time",
    ["host-busy"] = "The host is reading other torrents; try again in a minute",
    private = "That playlist is private",
    ytdlp = "The host has not got yt-dlp yet; try again soon",
    playlist = "Could not list that playlist",
    helper = "The host's video player could not start",
  }

  local function say(text, kind)
    status, statusKind, statusAt = text, kind or "info", U.now()
  end

  function SETUP.status() return status, statusKind end
  function SETUP.linkState() return link end
  function SETUP.picks() return picks end
  function SETUP.isOpen() return PARTY.setupOpen() end

  -- The panel rect: 960x640 at 1080p, scaled, centred, kept inside the window.
  function SETUP.rect()
    local W0, H0 = wum.render.windowSize()
    local s = SKIN.s
    local w, h = math.min(960 * s, W0 - 16), math.min(640 * s, H0 - 16)
    local x0, y0 = (W0 - w) / 2, (H0 - h) / 2
    return x0, y0, x0 + w, y0 + h
  end

  U.on("queue.pick", function(token, files, name)
    local sel = files[1] and files[1].index
    picks[#picks + 1] = {token = token, files = files, name = name or "Torrent", sel = sel, scroll = 0}
    if not PARTY.setupOpen() then PARTY.setSetup(true) end
  end)

  U.on("queue.picked", function(it)
    say("Added " .. U.trim(it.title, 60), "info")
  end)

  -- A member's add: the host answered ("party.addResult") or the pick went out ("party.addSent").
  U.on("party.addResult", function(ok, why, c, ti)
    if ok then
      say(c and c > 1 and ("Added " .. c .. " videos") or ("Added " .. (ti or "it")), "info")
    else
      say(ADD_WHY[why] or "The host could not add that", "error")
    end
  end)

  U.on("party.addSent", function(title)
    say("Sent " .. U.trim(title, 50) .. " to the host", "info")
  end)

  local function classify(text)
    if text == lastText then return lastClass end
    lastText = text
    local t = text:match("^%s*(.-)%s*$")
    if t == "" then
      lastClass = nil
    else
      local ok, c = pcall(wum.media.classify, t)
      lastClass = ok and c or false
    end
    return lastClass
  end

  local function classText(c)
    if c == nil then return "Paste a YouTube video, playlist or magnet link (Ctrl+V)", C.offText end
    if c == false then return "Not a link Holo can play", C.error end
    if c.kind == "magnet" then return "Torrent" .. (c.name and (": " .. U.trim(c.name, 60)) or ""), C.ok end
    if c.playlist and not c.id then return "YouTube playlist", C.ok end
    if c.live then return "YouTube live stream", C.ok end
    return "YouTube video", C.ok
  end

  local function submit()
    local text = link.text
    if text:match("^%s*$") then return end
    local ok, why = QUEUE.add(text)
    if ok then
      link.text, link.caret, link.anchor, link.scroll = "", 0, nil, 0
      local c = lastClass
      if why == "sent" then say("Sent to " .. PARTY.hostName() .. "...", "info")
      elseif c and c.kind == "magnet" then say("Reading the torrent's file list...", "info")
      elseif c and c.playlist and not c.id then say("Listing the playlist...", "info")
      elseif not QUEUE.haveYtdlp() then say("Added; YouTube plays once Melange has downloaded yt-dlp", "warn")
      else say("Added to the queue", "info") end
    else
      say(ADD_WHY[why] or ("Could not add that link (" .. tostring(why) .. ")"), "error")
    end
  end
  SETUP.submit = submit

  local function fmtSize(b)
    b = U.num(b) or 0
    if b >= 1073741824 then return string.format("%.1f GB", b / 1073741824) end
    return string.format("%d MB", math.floor(b / 1048576 + 0.5))
  end

  ---------------------------------------------------------------- the queue list

  local function queueList(x0, y0, x1, y1, s, canEdit, canAdd)
    local items = QUEUE.items()
    local me = NET.me()
    local rowH = ROW * s
    W.region("setup.list", x0, y0, x1, y1, "arrow")
    SKIN.nine("well", x0, y0, x1, y1)
    local ix0, iy0, ix1, iy1 = x0 + 8 * s, y0 + 8 * s, x1 - 8 * s, y1 - 8 * s
    local viewH = iy1 - iy0
    local total = #items * ROW
    local maxScroll = math.max(0, total - viewH / s)
    scroll = U.clamp(scroll - W.wheel("setup.list") * ROW * 1.5, 0, maxScroll)
    if #items == 0 then
      SKIN.text((x0 + x1) / 2, iy0 + 20 * s, canEdit and "The queue is empty: add a link above" or
        (canAdd and "The queue is empty. Paste a link above to add one" or "The host has not queued anything yet"),
        16 * s, C.offText, {align = "center"})
      return
    end
    local scrollbar = maxScroll > 0
    if scrollbar then ix1 = ix1 - 12 * s end
    local first = math.floor(scroll / ROW) + 1
    local last = math.min(#items, first + math.ceil(viewH / rowH) + 1)
    local curId = PARTY.active() and PARTY.currentId() or (QUEUE.current() and QUEUE.current().id)
    SKIN.clip(ix0, iy0, ix1, iy1)
    for i = first, last do
      local it = items[i]
      local ry0 = iy0 + (i - 1) * rowH - scroll * s
      local ry1 = ry0 + rowH
      local isCur = it.id == curId
      if isCur then SKIN.part("swash", ix0 + 2 * s, ry0 + 6 * s, ix1 - 2 * s, ry1 - 6 * s) end
      local x = ix0 + 6 * s
      SKIN.text(x + 22 * s, ry0, tostring(i), 14 * s, isCur and C.title or C.gold, {align = "right", vcenter = rowH})
      x = x + 30 * s
      SKIN.icon(isCur and "play" or (it.kind == "bt" and "magnet" or "link"), x, ry0 + (rowH - 26 * s) / 2, 26 * s)
      x = x + 32 * s
      local right = ix1 - 6 * s
      if canEdit then
        local bs = 28 * s
        local by = ry0 + (rowH - bs) / 2
        local vis = ry0 >= iy0 - 1 and ry1 <= iy1 + 1   -- only rows fully inside take clicks
        local was = W.active
        W.active = was and vis
        right = right - bs
        if W.iconButton("setup.rm." .. it.id, "cross", right, by, bs) then QUEUE.remove(it.id) end
        right = right - bs - 2 * s
        if W.iconButton("setup.dn." .. it.id, "down", right, by, bs, i < #items) then QUEUE.move(it.id, 1) end
        right = right - bs - 2 * s
        if W.iconButton("setup.up." .. it.id, "up", right, by, bs, i > 1) then QUEUE.move(it.id, -1) end
        W.active = was
        right = right - 8 * s
      elseif it.byId ~= nil and it.byId == me then
        -- a member removes what they added; the host does the removal
        local bs = 28 * s
        local vis = ry0 >= iy0 - 1 and ry1 <= iy1 + 1
        local was = W.active
        W.active = was and vis
        right = right - bs
        if W.iconButton("setup.rm." .. it.id, "cross", right, ry0 + (rowH - bs) / 2, bs) then
          local ok, why = PARTY.requestRemove(it.id)
          if not ok then say(ADD_WHY[why] or "Could not remove that", "error") end
        end
        W.active = was
        right = right - 8 * s
      end
      local d = U.num(it.duration) or 0
      local dur = it.live and "LIVE" or (d > 0 and U.fmtTime(d) or "")
      if dur ~= "" then
        SKIN.text(right, ry0, dur, 14 * s, C.cream, {align = "right", vcenter = rowH})
        right = right - SKIN.measure(dur, 14 * s, "body") - 10 * s
      end
      if it.by and it.by ~= "" then
        local by = "by " .. U.trim(it.by, 24)
        SKIN.text(right, ry0, by, 13 * s, C.offText, {align = "right", vcenter = rowH})
        right = right - SKIN.measure(by, 13 * s, "body") - 12 * s
      end
      SKIN.text(x, ry0, it.title ~= "" and it.title or it.url, 17 * s, isCur and C.title or C.cream,
        {vcenter = rowH, maxWidth = right - x})
      if i < #items then SKIN.part("divider", ix0 + 20 * s, ry1 - 3 * s, ix1 - 20 * s, ry1 + 1 * s, {a = 0.25}) end
    end
    SKIN.clipEnd()
    if scrollbar then
      local tx0 = ix1 + 4 * s
      local th = math.max(viewH * viewH / (total * s), 24 * s)
      local ty = iy0 + (viewH - th) * (scroll / maxScroll)
      SKIN.rect(tx0, iy0, tx0 + 6 * s, iy1, C.dark2)
      SKIN.rect(tx0, ty, tx0 + 6 * s, ty + th, C.light2)
    end
  end

  ---------------------------------------------------------------- players and the pack

  local PEER_TEXT = {ready = "ready", buffering = "buffering", nopack = "no media pack", noholo = "no Holo",
    error = "can't play this"}
  local PEER_ICON = {ready = "check", nopack = "download", noholo = "cross", error = "warning"}

  local function players(x0, y0, x1, s)
    local y = y0
    SKIN.text(x0, y, "Players", 20 * s, C.gold, {kind = "display"})
    y = y + 30 * s
    local rowH = 34 * s
    local rows = {}
    local pk = PARTY.pack() or {}
    local mine = pk.state == "ready" and "ready" or "nopack"
    rows[1] = {name = "You", host = NET.isHost(), state = mine}
    local ms = {}
    for _, m in ipairs(NET.members()) do ms[m.id] = m end
    for _, p in ipairs(PARTY.peers()) do
      local m = ms[p.id] or {}
      rows[#rows + 1] = {name = p.name, host = p.host, state = p.state, rtt = p.rtt,
        progress = m.pack == "downloading" and m.progress}
    end
    local maxRows = 7
    for i = 1, math.min(#rows, maxRows) do
      local r = rows[i]
      local x = x0
      if r.host then SKIN.icon("crown", x, y + (rowH - 24 * s) / 2, 24 * s) end
      x = x + 28 * s
      local icon = r.state == "buffering" and SKIN.spinner() or PEER_ICON[r.state] or "people"
      SKIN.icon(icon, x, y + (rowH - 22 * s) / 2, 22 * s, r.state == "noholo" and "off" or "normal")
      x = x + 28 * s
      local info = r.progress and ("downloading " .. r.progress .. "%") or PEER_TEXT[r.state] or ""
      if r.rtt then info = info .. ", " .. r.rtt .. " ms" end
      SKIN.text(x1, y, info, 13 * s, r.state == "ready" and C.cream or C.offText, {align = "right", vcenter = rowH})
      local iw = SKIN.measure(info, 13 * s, "body")
      SKIN.text(x, y, r.name, 16 * s, C.cream, {vcenter = rowH, maxWidth = x1 - x - iw - 10 * s})
      y = y + rowH
    end
    if #rows > maxRows then
      SKIN.text(x0, y, "and " .. (#rows - maxRows) .. " more", 13 * s, C.offText)
      y = y + 20 * s
    end
    return y
  end

  local BUSY = {downloading = true, verifying = true, installing = true, updating = true}
  local PACK_ERR = {hash = "The download did not match its hashes", ["disk-space"] = "Not enough disk space",
    network = "The download failed (network)", cancelled = "The download was cancelled",
    blocked = "Downloads are turned off in Melange.ini"}

  -- The pack consent block: what is downloaded, from where, where it goes, and the button whose click is the consent.
  local function packBlock(x0, y0, x1, y1, s)
    local pk = PARTY.pack() or {}
    if pk.state == "ready" then return end
    SKIN.nine("panel_dark", x0, y0, x1, y1)
    local ix0, ix1 = x0 + 14 * s, x1 - 14 * s
    local y = y0 + 10 * s
    SKIN.text(ix0, y, "Media pack", 18 * s, C.gold, {kind = "display"})
    y = y + 26 * s
    if pk.state == "unsupported" or pk.state == "disabled" then
      local why = pk.state == "unsupported" and "Holo needs 64-bit Windows to play videos." or
        "Media is turned off in Melange.ini ([Media] Enabled)."
      for _, ln in ipairs(SKIN.wrap(why, 14 * s, "body", ix1 - ix0, 3)) do
        SKIN.text(ix0, y, ln, 14 * s, C.cream)
        y = y + 18 * s
      end
      return
    end
    -- as many lines as fit above the button: the consent must be readable in full (at 1080p it takes 9)
    local fit = math.max(3, math.floor((y1 - 62 * s - y) / (17 * s)))
    local lines = SKIN.wrap(PARTY.consentText(), 13 * s, "body", ix1 - ix0, fit)
    for _, ln in ipairs(lines) do
      SKIN.text(ix0, y, ln, 13 * s, C.cream)
      y = y + 17 * s
    end
    y = math.max(y + 6 * s, y1 - 56 * s)
    if BUSY[pk.state] then
      local p = U.clamp(U.num(pk.progress) or 0, 0, 1)
      SKIN.nine("bar_track", ix0, y + 14 * s, ix1, y + 28 * s)
      SKIN.nine("bar_fill", ix0 + 2 * s, y + 16 * s, ix0 + 2 * s + math.max((ix1 - ix0 - 4 * s) * p, 8 * s), y + 26 * s)
      SKIN.text(ix0, y - 6 * s, (pk.state == "downloading" and "Downloading " or "Installing ") ..
        math.floor(p * 100) .. "%", 13 * s, C.cream)
      return
    end
    if pk.state == "error" then
      SKIN.text(ix0, y - 8 * s, PACK_ERR[pk.error] or "The download failed", 13 * s, C.error)
    end
    local mb = math.floor(U.num(pk.downloadMB) or 95)
    local label = (pk.state == "error" and "Try again" or "Download") .. " (" .. mb .. " MB)"
    if W.button("setup.pack", ix0, y + 4 * s, ix1, y + 46 * s, label, {icon = "download", size = 18 * s}) then
      PARTY.installPack()
    end
  end

  ---------------------------------------------------------------- the torrent file picker

  local function picker(x0, y0, x1, y1, s)
    local p = picks[1]
    local W0, H0 = x1 - x0, y1 - y0
    local w, h = math.min(640 * s, W0 - 40 * s), math.min(440 * s, H0 - 40 * s)
    local mx0, my0 = x0 + (W0 - w) / 2, y0 + (H0 - h) / 2
    local mx1, my1 = mx0 + w, my0 + h
    SKIN.rect(x0, y0, x1, y1, C.black, 0.45)
    W.region("setup.pick", mx0, my0, mx1, my1, "arrow")
    SKIN.nine("panel_dark", mx0, my0, mx1, my1)
    SKIN.text(mx0 + 20 * s, my0 + 14 * s, "Pick the video to play", 22 * s, C.title, {kind = "display"})
    SKIN.text(mx0 + 20 * s, my0 + 44 * s, p.name, 15 * s, C.gold, {maxWidth = w - 40 * s})
    local lx0, ly0, lx1, ly1 = mx0 + 16 * s, my0 + 72 * s, mx1 - 16 * s, my1 - 70 * s
    W.region("setup.picklist", lx0, ly0, lx1, ly1, "arrow")
    SKIN.nine("well", lx0, ly0, lx1, ly1)
    local rowH = PICK_ROW * s
    local viewH = ly1 - ly0 - 12 * s
    local maxScroll = math.max(0, #p.files * PICK_ROW - viewH / s)
    p.scroll = U.clamp(p.scroll - W.wheel("setup.picklist") * PICK_ROW * 1.5, 0, maxScroll)
    local first = math.floor(p.scroll / PICK_ROW) + 1
    local last = math.min(#p.files, first + math.ceil(viewH / rowH) + 1)
    SKIN.clip(lx0 + 6 * s, ly0 + 6 * s, lx1 - 6 * s, ly1 - 6 * s)
    for i = first, last do
      local f = p.files[i]
      local ry0 = ly0 + 6 * s + (i - 1) * rowH - p.scroll * s
      local rid = "setup.file." .. i
      local vis = ry0 >= ly0 and ry0 + rowH <= ly1
      local was = W.active
      W.active = was and vis
      W.region(rid, lx0 + 6 * s, ry0, lx1 - 6 * s, ry0 + rowH)
      if W.clicked(rid) then p.sel = f.index end
      W.active = was
      local on = p.sel == f.index
      if on then SKIN.part("swash", lx0 + 8 * s, ry0 + 4 * s, lx1 - 8 * s, ry0 + rowH - 4 * s) end
      local size = fmtSize(f.size)
      SKIN.text(lx1 - 16 * s, ry0, size, 14 * s, C.cream, {align = "right", vcenter = rowH})
      local name = tostring(f.path):match("([^/\\]+)$") or tostring(f.path)
      SKIN.text(lx0 + 18 * s, ry0, name, 16 * s, on and C.title or C.cream,
        {vcenter = rowH, maxWidth = lx1 - lx0 - 50 * s - SKIN.measure(size, 14 * s, "body")})
    end
    SKIN.clipEnd()
    local bw, bh = 150 * s, 46 * s
    local by = my1 - bh - 14 * s
    if W.button("setup.pickok", mx1 - 20 * s - bw, by, mx1 - 20 * s, by + bh, "Add", {enabled = p.sel ~= nil}) then
      local ok, why = QUEUE.pickFile(p.token, p.sel)
      table.remove(picks, 1)
      if not ok then say(ADD_WHY[why] or "Could not add that file", "error") end
    end
    if W.button("setup.pickno", mx1 - 30 * s - bw * 2, by, mx1 - 30 * s - bw, by + bh, "Cancel") then
      QUEUE.cancelPick(p.token)
      table.remove(picks, 1)
    end
  end

  ---------------------------------------------------------------- the panel

  local function footer(x0, y0, x1, y1, s)
    local bh = y1 - y0
    local role = PARTY.role()
    local x = x1
    local function btn(id, label, w, enabled, icon)
      x = x - w
      local hit = W.button(id, x, y0, x + w, y1, label, {enabled = enabled, icon = icon, size = 19 * s})
      x = x - 12 * s
      return hit
    end
    if btn("setup.close", "Close", 130 * s, true) then PARTY.setSetup(false) end
    local pk = PARTY.pack() or {}
    if role == "host" then
      if btn("setup.end", "End party", 170 * s, true, "close") then PARTY.stop() end
    elseif role == "peer" then
      if btn("setup.leave", "Leave party", 180 * s, true) then PARTY.stop() end
    elseif PARTY.canContinue() then
      if btn("setup.continue", "Continue party", 220 * s, true, "play") then
        local ok, why = PARTY.continueParty()
        if not ok then say("Could not continue (" .. tostring(why) .. ")", "error") end
      end
    elseif PARTY.partyRunning() then
      if btn("setup.join", "Join party", 180 * s, true, "people") then PARTY.join() end
    elseif PARTY.canControl() then
      local ready = QUEUE.count() > 0 and pk.state == "ready"
      if btn("setup.start", "Start party", 200 * s, ready, "play") then
        local ok, why = PARTY.start()
        if ok then PARTY.setSetup(false)
        else say(why == "empty" and "Add a link first" or ("Could not start (" .. tostring(why) .. ")"), "error") end
      end
    end
    -- the status line, left of the buttons
    local text, kind = status, statusKind
    if text and U.now() - statusAt > 6000 then
      status, text = nil, nil
    end
    if not text and PARTY.canControl() and role == "none" and pk.state ~= "ready" then
      text, kind = "Download the media pack to start", "warn"
    end
    if not text then
      local reading = QUEUE.reading()
      local r = reading[1]
      if r then
        local more = #reading > 1 and (" (+" .. (#reading - 1) .. " more)") or ""
        if r.peers == 0 and r.secs > 60 then
          text, kind = "No peers for " .. U.trim(r.name, 40) .. " yet; the torrent may be dead" .. more, "warn"
        else
          text, kind = string.format("Reading the file list of %s... %d peer%s%s", U.trim(r.name, 40), r.peers,
            r.peers == 1 and "" or "s", more), "info"
        end
      end
    end
    if text then
      SKIN.text(x0, y0, text, 15 * s, kind == "error" and C.error or (kind == "warn" and C.warn or C.cream),
        {vcenter = bh, maxWidth = x - x0 - 8 * s})
    end
  end

  function SETUP.draw()
    if not PARTY.setupOpen() then
      if link.focused then W.blur() end
      return
    end
    local s = SKIN.s
    local x0, y0, x1, y1 = SETUP.rect()
    local modal = picks[1] ~= nil or MUI.libOpen()
    W.region("setup.panel", x0, y0, x1, y1, "arrow")
    W.active = not modal
    SKIN.nine("panel", x0, y0, x1, y1)
    local canEdit = PARTY.canControl()
    local canAdd = PARTY.canAdd()
    local why = PARTY.addWhyNot()

    -- title tag, the host line and the close button
    local tagW = SKIN.measure("Watch party", 26 * s, "tag") + 56 * s
    SKIN.nine("tag", x0 + 22 * s, y0 + 14 * s, x0 + 22 * s + tagW, y0 + 60 * s)
    SKIN.text(x0 + 22 * s + 28 * s, y0 + 14 * s, "Watch party", 26 * s, C.ink, {kind = "tag", vcenter = 46 * s})
    -- the tabs, tag-style, right after the title; the current one is drawn pressed
    local tx = x0 + 34 * s + tagW
    if W.button("setup.tab.videos", tx, y0 + 18 * s, tx + 96 * s, y0 + 56 * s, "Videos",
      {size = 16 * s, on = tab == "videos"}) then SETUP.setTab("videos") end
    tx = tx + 102 * s
    if W.button("setup.tab.music", tx, y0 + 18 * s, tx + 96 * s, y0 + 56 * s, "Music",
      {size = 16 * s, on = tab == "music", icon = "audio"}) then SETUP.setTab("music") end
    tagW = tx + 96 * s - (x0 + 22 * s)
    if W.iconButton("setup.x", "close", x1 - 58 * s, y0 + 16 * s, 40 * s) then PARTY.setSetup(false) end
    local who
    if tab == "music" then
      local mwhy = MUSIC.addWhyNot()
      if NET.isHost() then
        who = NET.inSession() and "You host the music" or "Music on this machine only (no lobby)"
      elseif mwhy == "old-host" then
        who = PARTY.hostName() .. "'s Holo has no music lane"
      elseif mwhy == "host-only" then
        who = PARTY.hostName() .. " hosts the music and adds the songs"
      else
        who = PARTY.hostName() .. " hosts the music. You can add songs"
      end
    elseif canEdit then
      who = NET.inSession() and "You host this party" or "Playing on this machine only (no lobby)"
    elseif canAdd then
      who = PARTY.hostName() .. " hosts this party. You can add videos"
    else
      who = "Only the host (" .. PARTY.hostName() .. ") controls the party"
      if why == "old-host" then who = who .. " (their Holo is older than 1.1)"
      elseif why == "host-only" then who = who .. " and adds the videos"
      elseif why == "not-running" then who = who .. ". Adding opens when they start the party" end
    end
    SKIN.text(x0 + 40 * s + tagW, y0 + 14 * s, who, 15 * s, C.gold,
      {vcenter = 46 * s, maxWidth = x1 - 70 * s - (x0 + 40 * s + tagW)})

    local footY = y1 - 74 * s
    if tab == "music" then
      MUI.drawSetup(x0, y0 + 78 * s, x1, footY - 14 * s, s)
      footer(x0 + 28 * s, footY, x1 - 28 * s, footY + 50 * s, s)
      W.active = true
      if picks[1] then picker(x0, y0, x1, y1, s)
      elseif MUI.libOpen() then MUI.drawLibrary(x0, y0, x1, y1, s) end
      return
    end

    -- left column: the link box and the queue
    local lx0, lx1 = x0 + 28 * s, x0 + 620 * s
    local ly = y0 + 78 * s
    local boxH = 48 * s
    local addW = 110 * s
    local tick = 34 * s
    local bx1 = lx1 - addW - tick - 16 * s
    local mayAdd = canEdit or canAdd
    local placeholder = "The host adds the videos"
    if canEdit then placeholder = "Paste a YouTube or magnet link"
    elseif canAdd then placeholder = "Paste a link to add it to " .. U.trim(PARTY.hostName(), 24) .. "'s queue" end
    local r = W.textbox(link, lx0, ly, bx1, ly + boxH, {enabled = mayAdd, size = 18 * s, placeholder = placeholder})
    local c = classify(link.text)
    if c ~= nil then SKIN.icon(c and "check" or "cross", bx1 + 8 * s, ly + (boxH - tick) / 2, tick) end
    local addHit = W.button("setup.add", lx1 - addW, ly, lx1, ly + boxH, "Add",
      {enabled = mayAdd and c ~= nil and c ~= false, icon = "add", size = 19 * s})
    if mayAdd and (r == "submit" or addHit) then submit() end
    local hint, hc = classText(c)
    SKIN.text(lx0 + 6 * s, ly + boxH + 4 * s, hint, 13 * s, hc, {maxWidth = lx1 - lx0})

    local qy = ly + boxH + 30 * s
    SKIN.text(lx0, qy, "Queue (" .. QUEUE.count() .. ")", 20 * s, C.gold, {kind = "display"})
    if canEdit and PARTY.role() == "none" then
      local last = U.pref("lastQueue")
      if QUEUE.count() == 0 and type(last) == "table" and type(last.items) == "table" and #last.items > 0 then
        if W.button("setup.restore", lx1 - 220 * s, qy - 4 * s, lx1, qy + 30 * s, "Restore last queue",
          {size = 15 * s}) then
          PARTY.restoreLastQueue()
        end
      elseif QUEUE.count() > 0 then
        if W.button("setup.clear", lx1 - 120 * s, qy - 4 * s, lx1, qy + 30 * s, "Clear", {size = 15 * s}) then
          QUEUE.clear()
        end
      end
    end
    queueList(lx0, qy + 34 * s, lx1, footY - 14 * s, s, canEdit, canAdd)

    -- right column: players and the pack
    local rx0, rx1 = x0 + 650 * s, x1 - 28 * s
    local py = players(rx0, y0 + 78 * s, rx1, s)
    local pk = PARTY.pack() or {}
    if pk.state ~= "ready" then packBlock(rx0, math.max(py + 8 * s, y0 + 270 * s), rx1, footY - 14 * s, s) end

    footer(lx0, footY, rx1, footY + 50 * s, s)
    W.active = true
    if picks[1] then picker(x0, y0, x1, y1, s)
    elseif MUI.libOpen() then MUI.drawLibrary(x0, y0, x1, y1, s) end
  end

  -- A closed panel cancels its open pickers, so their torrents do not stay open.
  U.on("party.changed", function()
    if PARTY.setupOpen() or #picks == 0 then return end
    for _, p in ipairs(picks) do QUEUE.cancelPick(p.token) end
    picks = {}
  end)
end
