-- music UI (Holo 1.1): the setup panel's Music tab (now playing, seek, the music queue, the Spotify block with the
-- consent text and the Link button), the library modal (saved songs, playlists, their songs, paged by 50) and the
-- now-playing chip at the top of the player's side. The chip shows while party music plays or is paused, with or
-- without a video party; F9 hides it with the other surfaces and never stops the music.
do
  local C = SKIN.C
  local ROW, LIB_ROW = 52, 44
  local MAX_ROWS = 500               -- loaded library rows kept

  local scroll = 0
  local status, statusKind, statusAt = nil, nil, 0
  local seekDrag = nil
  -- the library modal
  local lib = {open = false, view = "tracks", id = nil, name = nil, rows = {}, next = false, nextOffset = 0,
    loading = false, err = nil, scroll = 0, req = 0}

  local WHY = {
    full = "The music queue is full (200 songs)",
    ["member-full"] = "You already have 50 songs in the music queue",
    dup = "That song is already in the music queue",
    rate = "Wait a moment before adding again",
    ["host-only"] = "The host adds the music in this party",
    ["old-host"] = "The host's Holo is older than 1.1, so music is off in this party.",
    ["no-host"] = "The host is not reachable",
    ["no-answer"] = "The host did not answer",
    invalid = "Holo cannot use that song",
    ["too-many"] = "Too many songs at once",
    ["not-host"] = "Only the host controls the music",
    ["not-yours"] = "You can remove only the songs you added",
    busy = "Spotify is still answering; try again in a moment",
  }
  MUI.WHY = WHY

  local function say(text, kind)
    status, statusKind, statusAt = text, kind or "info", U.now()
  end
  function MUI.status() return status, statusKind end

  local function whyText(why)
    return WHY[why] or SPOT.WHY[why] or ("Could not do that (" .. tostring(why) .. ")")
  end

  U.on("music.addResult", function(ok, why, c)
    if ok then
      say(c and c > 1 and ("Added " .. c .. " songs") or "Added to the music queue", "info")
      if why == "member-full" or why == "full" then say(WHY[why], "warn") end
    else
      say(whyText(why), "error")
    end
  end)

  local function fmtMs(ms) return U.fmtTime((U.num(ms) or 0) / 1000) end

  ---------------------------------------------------------------- the library modal

  function MUI.libOpen() return lib.open end
  function MUI.library() return lib end

  local function load(view, id, name, offset)
    lib.req = lib.req + 1
    local token = lib.req
    if offset == 0 then
      lib.view, lib.id, lib.name, lib.rows, lib.scroll, lib.next = view, id, name, {}, 0, false
    end
    lib.loading, lib.err = true, nil
    local kind = view == "lists" and "playlists" or (view == "playlist" and "playlist" or "tracks")
    local rid, why = SPOT.library(kind, id, offset, function(res)
      if token ~= lib.req then return end
      lib.loading = false
      if res.error then
        lib.err = res.error
        return
      end
      for _, x in ipairs(type(res.items) == "table" and res.items or {}) do
        if #lib.rows >= MAX_ROWS then break end
        if type(x) == "table" then
          if kind == "playlists" then
            if type(x.id) == "string" and #x.id == 22 then
              lib.rows[#lib.rows + 1] = {id = x.id, name = U.trim(x.name, 80), owner = U.trim(x.owner, 40),
                tracks = math.tointeger(x.tracks)}
            end
          elseif MUSIC.validUri(x.uri) and U.num(x.durationMs) then
            lib.rows[#lib.rows + 1] = {uri = x.uri, name = U.trim(x.name, 80), artists = U.trim(x.artists, 80),
              durationMs = math.floor(x.durationMs), playable = x.playable ~= false}
          end
        end
      end
      lib.next = res.next == true and #lib.rows < MAX_ROWS
      lib.nextOffset = offset + (math.tointeger(res.limit) or 50)
    end)
    if not rid then
      lib.loading, lib.err = false, why
    end
  end

  function MUI.openLibrary()
    lib.open = true
    load("tracks", nil, nil, 0)
  end

  function MUI.closeLibrary()
    lib.open = false
    lib.req = lib.req + 1             -- an answer still on its way is dropped
    lib.loading = false
  end

  local function addRows(rows)
    local list = {}
    for _, r in ipairs(rows) do
      if r.uri and r.playable then list[#list + 1] = {uri = r.uri, name = r.name, artists = r.artists,
        durationMs = r.durationMs} end
    end
    if #list == 0 then return say("Nothing to add here", "warn") end
    local ok, why = MUSIC.add(list)
    if ok == true and why == "sent" then
      say("Sent " .. (#list > 1 and (#list .. " songs") or U.trim(list[1].name, 50)) .. " to "
        .. U.trim(PARTY.hostName(), 24), "info")
    elseif ok then
      say(ok > 1 and ("Added " .. ok .. " songs") or ("Added " .. U.trim(list[1].name, 50)), "info")
      if why == "full" or why == "dup" then say(WHY[why], "warn") end
    else
      say(whyText(why), "error")
    end
  end
  MUI.addRows = addRows

  function MUI.drawLibrary(x0, y0, x1, y1, s)
    local W0, H0 = x1 - x0, y1 - y0
    local w, h = math.min(760 * s, W0 - 40 * s), math.min(540 * s, H0 - 40 * s)
    local mx0, my0 = x0 + (W0 - w) / 2, y0 + (H0 - h) / 2
    local mx1, my1 = mx0 + w, my0 + h
    SKIN.rect(x0, y0, x1, y1, C.black, 0.45)
    W.region("music.lib", mx0, my0, mx1, my1, "arrow")
    SKIN.nine("panel_dark", mx0, my0, mx1, my1)
    SKIN.text(mx0 + 20 * s, my0 + 14 * s, "Your Spotify library", 22 * s, C.title, {kind = "display"})
    if W.iconButton("music.lib.close", "close", mx1 - 52 * s, my0 + 12 * s, 36 * s) then
      MUI.closeLibrary()
      return
    end
    -- header chips
    local cy0, cy1 = my0 + 50 * s, my0 + 84 * s
    local x = mx0 + 20 * s
    if lib.view == "playlist" then
      if W.button("music.lib.back", x, cy0, x + 100 * s, cy1, "Back", {size = 15 * s, icon = "prev"}) then
        load("lists", nil, nil, 0)
      end
      x = x + 108 * s
      local any = false
      for _, r in ipairs(lib.rows) do any = any or r.playable == true end
      if W.button("music.lib.all", x, cy0, x + 170 * s, cy1, "Add all loaded", {size = 15 * s, enabled = any}) then
        addRows(lib.rows)
      end
      x = x + 180 * s
      SKIN.text(x, cy0, lib.name or "", 15 * s, C.gold, {vcenter = cy1 - cy0, maxWidth = mx1 - 20 * s - x})
    else
      if W.button("music.lib.liked", x, cy0, x + 140 * s, cy1, "Liked songs",
        {size = 15 * s, on = lib.view == "tracks"}) then
        load("tracks", nil, nil, 0)
      end
      x = x + 148 * s
      if W.button("music.lib.lists", x, cy0, x + 140 * s, cy1, "Playlists", {size = 15 * s, on = lib.view == "lists"}) then
        load("lists", nil, nil, 0)
      end
    end
    -- the list
    local lx0, ly0, lx1, ly1 = mx0 + 16 * s, my0 + 96 * s, mx1 - 16 * s, my1 - 64 * s
    W.region("music.lib.list", lx0, ly0, lx1, ly1, "arrow")
    SKIN.nine("well", lx0, ly0, lx1, ly1)
    local rowH = LIB_ROW * s
    local viewH = ly1 - ly0 - 12 * s
    local rows = lib.rows
    local maxScroll = math.max(0, #rows * LIB_ROW - viewH / s)
    lib.scroll = U.clamp(lib.scroll - W.wheel("music.lib.list") * LIB_ROW * 1.5, 0, maxScroll)
    if #rows == 0 then
      local text = lib.loading and "Loading..." or (lib.err and "" or
        (lib.view == "lists" and "No playlists" or "No songs here"))
      if lib.loading then SKIN.icon(SKIN.spinner(), (lx0 + lx1) / 2 - 16 * s, ly0 + 40 * s, 32 * s) end
      SKIN.text((lx0 + lx1) / 2, ly0 + 14 * s, text, 16 * s, C.offText, {align = "center"})
    else
      local first = math.floor(lib.scroll / LIB_ROW) + 1
      local last = math.min(#rows, first + math.ceil(viewH / rowH) + 1)
      SKIN.clip(lx0 + 6 * s, ly0 + 6 * s, lx1 - 6 * s, ly1 - 6 * s)
      for i = first, last do
        local r = rows[i]
        local ry0 = ly0 + 6 * s + (i - 1) * rowH - lib.scroll * s
        local ry1 = ry0 + rowH
        local vis = ry0 >= ly0 and ry1 <= ly1
        local was = W.active
        W.active = was and vis
        local right = lx1 - 16 * s
        if r.uri then
          local bs = 30 * s
          right = right - bs
          if W.iconButton("music.lib.add." .. i, "add", right, ry0 + (rowH - bs) / 2, bs, r.playable) then
            addRows({r})
          end
          right = right - 10 * s
          local d = fmtMs(r.durationMs)
          SKIN.text(right, ry0, d, 14 * s, C.cream, {align = "right", vcenter = rowH})
          right = right - SKIN.measure(d, 14 * s, "body") - 10 * s
          local label = r.artists ~= "" and (r.name .. " — " .. r.artists) or r.name
          SKIN.text(lx0 + 18 * s, ry0, label, 16 * s, r.playable and C.cream or C.offText,
            {vcenter = rowH, maxWidth = right - lx0 - 18 * s})
        else
          local rid = "music.lib.open." .. i
          W.region(rid, lx0 + 6 * s, ry0, lx1 - 6 * s, ry1)
          local hit = W.clicked(rid)
          if W.inside(lx0 + 6 * s, ry0, lx1 - 6 * s, ry1) and W.active then
            SKIN.part("swash", lx0 + 8 * s, ry0 + 4 * s, lx1 - 8 * s, ry1 - 4 * s, {a = 0.5})
          end
          local info = (r.tracks and (r.tracks .. " songs") or "") .. (r.owner ~= "" and (", by " .. r.owner) or "")
          SKIN.text(right, ry0, info, 13 * s, C.offText, {align = "right", vcenter = rowH})
          right = right - SKIN.measure(info, 13 * s, "body") - 12 * s
          SKIN.text(lx0 + 18 * s, ry0, r.name, 16 * s, C.cream, {vcenter = rowH, maxWidth = right - lx0 - 18 * s})
          if hit then
            W.active = was
            SKIN.clipEnd()
            load("playlist", r.id, r.name, 0)
            return
          end
        end
        W.active = was
        if i < #rows then SKIN.part("divider", lx0 + 20 * s, ry1 - 3 * s, lx1 - 20 * s, ry1 + 1 * s, {a = 0.25}) end
      end
      SKIN.clipEnd()
    end
    -- footer: the status line and "Load more"
    local by0, by1 = my1 - 54 * s, my1 - 14 * s
    if lib.next and not lib.loading then
      if W.button("music.lib.more", mx1 - 20 * s - 150 * s, by0, mx1 - 20 * s, by1, "Load more", {size = 15 * s}) then
        load(lib.view, lib.id, lib.name, lib.nextOffset)
      end
    elseif lib.loading and #rows > 0 then
      SKIN.icon(SKIN.spinner(), mx1 - 56 * s, by0 + 4 * s, 32 * s)
    end
    local text, kind = status, statusKind
    if text and U.now() - statusAt > 6000 then text = nil end
    if lib.err then
      text, kind = lib.err == "not-found" and "Spotify does not let apps read this playlist" or whyText(lib.err), "error"
    end
    if text then
      SKIN.text(mx0 + 20 * s, by0, text, 15 * s, kind == "error" and C.error or (kind == "warn" and C.warn or C.cream),
        {vcenter = by1 - by0, maxWidth = w - 200 * s})
    end
  end

  ---------------------------------------------------------------- the Music tab

  local ERROR_TEXT = {denied = "You did not allow access", timeout = "The sign-in timed out; try again",
    ["invalid-client"] = "Check [Spotify] ClientId and the app's Redirect URI", network = "Could not reach Spotify",
    revoked = "Spotify signed Holo out; link again", exchange = "The Spotify sign-in failed; try again"}

  local CONSENT = "Link your Spotify account to add songs from your library and to listen with the party on your own "
    .. "Spotify (Premium). Your browser opens Spotify's sign-in page. Melange keeps the sign-in encrypted on this PC; "
    .. "Holo never sees it, and other players see only the songs you add."
  MUI.CONSENT = CONSENT

  local function lines(text, x, y, size, rgb, width, maxLines)
    for _, ln in ipairs(SKIN.wrap(text, size, "body", width, maxLines)) do
      SKIN.text(x, y, ln, size, rgb)
      y = y + size * 1.3
    end
    return y
  end

  -- The click is the consent: SPOT.connect() runs inside this click handler (Melange's 2 s gesture window).
  local function linkButton(id, x0, y, x1, s, label)
    if W.button(id, x0, y, x1, y + 44 * s, label, {size = 17 * s}) then
      local ok, why = SPOT.connect()
      if not ok then say(SPOT.WHY[why] or ("Could not link Spotify (" .. tostring(why) .. ")"), "error") end
    end
    return y + 52 * s
  end

  local function listenButton(id, x0, y0, x1, y1, s)
    local on = MUSIC.listening()
    if W.button(id, x0, y0, x1, y1, on and "Mute here" or "Listen", {size = 15 * s, icon = on and "vol2" or "mute"}) then
      MUSIC.setListen(not on)
    end
  end

  local function spotifyBlock(x0, y0, x1, y1, s)
    SKIN.nine("panel_dark", x0, y0, x1, y1)
    local ix0, ix1 = x0 + 14 * s, x1 - 14 * s
    local iw = ix1 - ix0
    local y = y0 + 10 * s
    SKIN.text(ix0, y, "Spotify", 18 * s, C.gold, {kind = "display"})
    y = y + 28 * s
    local host = NET.isHost()
    if not host and MUSIC.oldHost() then
      y = lines(WHY["old-host"], ix0, y, 13 * s, C.warn, iw, 3) + 6 * s
    end
    if not SPOT.has() then
      y = lines("Spotify music needs Melange " .. SPOT.NEEDS .. " or later. You can still see what the party plays.",
        ix0, y, 14 * s, C.cream, iw, 4)
    else
      local st = SPOT.status()
      local ok, why = SPOT.available()
      if not ok then
        y = lines(SPOT.WHY[why] or ("Spotify is not available (" .. tostring(why) .. ")"), ix0, y, 14 * s, C.cream, iw, 4)
      elseif st.state == "connecting" then
        SKIN.icon(SKIN.spinner(), ix0, y, 26 * s)
        SKIN.text(ix0 + 34 * s, y, "Finish signing in in your browser", 15 * s, C.cream,
          {vcenter = 26 * s, maxWidth = iw - 34 * s})
        y = y + 38 * s
        if W.button("music.cancel", ix0, y, ix0 + 120 * s, y + 40 * s, "Cancel", {size = 15 * s}) then
          SPOT.disconnect()
        end
        y = y + 48 * s
      elseif st.state == "connected" then
        SKIN.text(ix0, y, "Spotify: " .. (st.user ~= "" and st.user or "linked"), 16 * s, C.cream, {maxWidth = iw})
        y = y + 22 * s
        local free = not st.premium or MUSIC.notPremium()
        y = lines(free and "Free account: you see what plays but cannot play it here" or "Premium", ix0, y, 13 * s,
          free and C.warn or C.offText, iw, 2)
        local pb = MUSIC.playback()
        local dev = pb and pb.active and pb.device and pb.device.name
        local devText = (dev and dev ~= "") and ("Device: " .. dev) or "No device: open Spotify on this PC or your phone"
        if MUSIC.lastError() == "no-device" then devText = "No device: open Spotify on this PC or your phone" end
        y = lines(devText, ix0, y + 2 * s, 13 * s, C.offText, iw, 2)
        if MUSIC.detached() then
          y = lines("You changed the music in Spotify; Holo stopped following.", ix0, y + 2 * s, 13 * s, C.warn, iw, 2)
          if W.button("music.follow", ix0, y + 2 * s, ix0 + 160 * s, y + 38 * s, "Follow again", {size = 14 * s}) then
            MUSIC.followAgain()
          end
          y = y + 44 * s
        end
        y = y + 8 * s
        if W.button("music.browse", ix0, y, ix1, y + 44 * s, "Add from my library",
          {size = 17 * s, icon = "add", enabled = MUSIC.canAdd()}) then
          MUI.openLibrary()
        end
        y = y + 52 * s
        if host then listenButton("music.listen", ix0, y, ix0 + 150 * s, y + 36 * s, s) end
        if W.button("music.unlink", ix1 - 100 * s, y, ix1, y + 36 * s, "Unlink", {size = 14 * s}) then
          SPOT.disconnect()
        end
        y = y + 44 * s
      else
        if st.state == "error" then
          y = lines(ERROR_TEXT[st.error] or SPOT.WHY[st.error] or "The Spotify sign-in failed", ix0, y, 14 * s, C.error,
            iw, 2)
          y = y + 4 * s
        end
        local fit = math.max(3, math.floor((y1 - 70 * s - y) / (17 * s)))
        y = lines(CONSENT, ix0, y, 13 * s, C.cream, iw, fit)
        y = math.max(y + 6 * s, y1 - 60 * s)
        linkButton("music.link", ix0, y, ix1, s, st.linked and "Use my Spotify in Holo" or "Link Spotify")
        y = y1
      end
    end
    return y
  end

  local function nowPlaying(x0, y0, x1, s)
    local h = 48 * s
    local host = NET.isHost()
    local st = MUSIC.state()
    local it = MUSIC.current()
    SKIN.icon("audio", x0, y0 + (h - 34 * s) / 2, 34 * s)
    local right = x1
    if host then
      local bs = 36 * s
      local by = y0 + (h - bs) / 2
      right = right - bs
      if W.iconButton("music.stop", "close", right, by, bs, st.s ~= "stop") then MUSIC.stop() end
      right = right - bs - 4 * s
      if W.iconButton("music.next", "next", right, by, bs, MUSIC.count() > 0) then MUSIC.next() end
      right = right - bs - 4 * s
      if W.iconButton("music.play", st.s == "play" and "pause" or "play", right, by, bs, MUSIC.count() > 0) then
        MUSIC.toggle()
      end
      right = right - bs - 4 * s
      if W.iconButton("music.prev", "prev", right, by, bs, it ~= nil) then MUSIC.prev() end
      right = right - 10 * s
    else
      right = right - 140 * s
      listenButton("music.listen", right, y0 + 6 * s, x1, y0 + h - 6 * s, s)
      right = right - 10 * s
    end
    local tx = x0 + 44 * s
    if it and st.s ~= "stop" then
      local title = it.artists ~= "" and (it.title .. " — " .. it.artists) or it.title
      SKIN.text(tx, y0 + 2 * s, title, 18 * s, C.cream, {maxWidth = right - tx})
      local sub = it.by and ("added by " .. it.by) or (st.s == "pause" and "Paused" or "")
      if st.s == "pause" and it.by then sub = "Paused, added by " .. it.by end
      SKIN.text(tx, y0 + 26 * s, sub, 13 * s, C.offText, {maxWidth = right - tx})
    else
      SKIN.text(tx, y0, "Nothing playing", 18 * s, C.offText, {vcenter = h, maxWidth = right - tx})
    end
    -- seek row
    local sy = y0 + h + 8 * s
    local dur = it and it.durationMs or 0
    local pos = (it and st.s ~= "stop") and MUSIC.position() or 0
    local v = dur > 0 and pos / dur or 0
    local sx0, sx1 = x0 + 56 * s, x1 - 56 * s
    local nv, changed, released = W.slider("music.seek", sx0, sy, sx1, sy + 12 * s, seekDrag or v,
      {enabled = it ~= nil and st.s ~= "stop", readonly = not host, grab = 6 * s})
    if host and changed then seekDrag = nv end
    if host and released then
      seekDrag = nil
      MUSIC.seek(nv * dur)
    elseif not W.held("music.seek") then
      seekDrag = nil
    end
    local shown = seekDrag and seekDrag * dur or pos
    SKIN.text(sx0 - 8 * s, sy - 3 * s, fmtMs(shown), 13 * s, C.cream, {align = "right"})
    SKIN.text(sx1 + 8 * s, sy - 3 * s, fmtMs(dur), 13 * s, C.cream)
    return sy + 24 * s
  end

  local function musicList(x0, y0, x1, y1, s, host)
    local items = MUSIC.items()
    local me = NET.me()
    local rowH = ROW * s
    W.region("music.list", x0, y0, x1, y1, "arrow")
    SKIN.nine("well", x0, y0, x1, y1)
    local ix0, iy0, ix1, iy1 = x0 + 8 * s, y0 + 8 * s, x1 - 8 * s, y1 - 8 * s
    local viewH = iy1 - iy0
    local total = #items * ROW
    local maxScroll = math.max(0, total - viewH / s)
    scroll = U.clamp(scroll - W.wheel("music.list") * ROW * 1.5, 0, maxScroll)
    if #items == 0 then
      SKIN.text((x0 + x1) / 2, iy0 + 20 * s, SPOT.connected() and "Add songs from your Spotify library on the right"
        or "The music queue is empty", 16 * s, C.offText, {align = "center"})
      return
    end
    local scrollbar = maxScroll > 0
    if scrollbar then ix1 = ix1 - 12 * s end
    local first = math.floor(scroll / ROW) + 1
    local last = math.min(#items, first + math.ceil(viewH / rowH) + 1)
    local st = MUSIC.state()
    local curId = st.s ~= "stop" and st.i or nil
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
      local right = ix1 - 6 * s
      local bs = 28 * s
      local by = ry0 + (rowH - bs) / 2
      local vis = ry0 >= iy0 - 1 and ry1 <= iy1 + 1
      local was = W.active
      W.active = was and vis
      if host then
        right = right - bs
        if W.iconButton("music.rm." .. it.id, "cross", right, by, bs) then MUSIC.remove(it.id) end
        right = right - bs - 2 * s
        if W.iconButton("music.dn." .. it.id, "down", right, by, bs, i < #items) then MUSIC.move(it.id, 1) end
        right = right - bs - 2 * s
        if W.iconButton("music.up." .. it.id, "up", right, by, bs, i > 1) then MUSIC.move(it.id, -1) end
        right = right - 8 * s
      elseif it.byId ~= nil and it.byId == me then
        right = right - bs
        if W.iconButton("music.rm." .. it.id, "cross", right, by, bs) then
          local ok, why = MUSIC.requestRemove(it.id)
          if not ok then say(whyText(why), "error") end
        end
        right = right - 8 * s
      end
      if host then
        if W.iconButton("music.go." .. it.id, "play", x, by, bs) then MUSIC.playItem(it.id, 0) end
      else
        SKIN.icon(isCur and "play" or "audio", x, ry0 + (rowH - 26 * s) / 2, 26 * s)
      end
      W.active = was
      x = x + 32 * s
      local d = fmtMs(it.durationMs)
      SKIN.text(right, ry0, d, 14 * s, C.cream, {align = "right", vcenter = rowH})
      right = right - SKIN.measure(d, 14 * s, "body") - 10 * s
      if it.by then
        local by2 = "by " .. U.trim(it.by, 24)
        SKIN.text(right, ry0, by2, 13 * s, C.offText, {align = "right", vcenter = rowH})
        right = right - SKIN.measure(by2, 13 * s, "body") - 12 * s
      end
      local label = it.artists ~= "" and (it.title .. " — " .. it.artists) or it.title
      SKIN.text(x, ry0, label, 17 * s, isCur and C.title or C.cream, {vcenter = rowH, maxWidth = right - x})
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

  -- The Music tab's content: x0, x1 the panel's sides, y0..y1 the area between the tabs and the footer.
  function MUI.drawSetup(x0, y0, x1, y1, s)
    local host = NET.isHost()
    local lx0, lx1 = x0 + 28 * s, x0 + 620 * s
    local y = nowPlaying(lx0, y0, lx1, s)
    SKIN.text(lx0, y + 4 * s, "Music queue (" .. MUSIC.count() .. ")", 20 * s, C.gold, {kind = "display"})
    if host and MUSIC.count() > 0 then
      if W.button("music.clear", lx1 - 120 * s, y, lx1, y + 34 * s, "Clear", {size = 15 * s}) then MUSIC.clear() end
    end
    musicList(lx0, y + 40 * s, lx1, y1, s, host)
    local rx0, rx1 = x0 + 650 * s, x1 - 28 * s
    local by = spotifyBlock(rx0, y0, rx1, y1 - 40 * s, s)
    local text, kind = status, statusKind
    if text and U.now() - statusAt > 6000 then
      status, text = nil, nil
    end
    if text then
      SKIN.text(rx0, y1 - 34 * s, text, 14 * s, kind == "error" and C.error or (kind == "warn" and C.warn or C.cream),
        {maxWidth = rx1 - rx0})
    end
    return by
  end

  ---------------------------------------------------------------- the now-playing chip

  local function chipLine(it, st)
    if st.s == "pause" then return "Paused" end
    if not SPOT.connected() then
      return "Link Spotify in the watch party panel (" .. (CFG.hotkeyKey("setup") or "F6") .. ") to listen"
    end
    if MUSIC.audible() then
      local pb = MUSIC.playback()
      local dev = pb and pb.device and pb.device.name
      if dev and dev ~= "" then return (it.artists ~= "" and (it.artists .. " · ") or "") .. "on " .. dev end
      return it.artists
    end
    if not SPOT.premium() or MUSIC.notPremium() then return "Free account: playing needs Premium" end
    if not MUSIC.listening() then return "Muted here" end
    if MUSIC.detached() then return "Not following: you changed the music in Spotify" end
    if MUSIC.lastError() == "no-device" then return "No device: open Spotify on this PC or your phone" end
    return "Not following"
  end

  function MUI.chipRect()
    local s = SKIN.s
    local ww = wum.render.windowSize()
    local w, h = 340 * s, 52 * s
    local y0 = 16 * s
    local x0 = LAYOUT.side() == "left" and 16 * s or ww - 16 * s - w
    return x0, y0, x0 + w, y0 + h
  end

  -- Drawn by MAIN after the player: while party music plays or is paused (setting musicChip), even without a video
  -- party. Faded with the player (pause menu); hidden with it (F9).
  function MUI.drawChip()
    if CFG.get("musicChip") ~= true then return end
    local st = MUSIC.state()
    if st.s == "stop" then return end
    local it = MUSIC.current()
    if not it or LAYOUT.view() == "hidden" then return end
    local s = SKIN.s
    local x0, y0, x1, y1 = MUI.chipRect()
    local h = y1 - y0
    local faded = LAYOUT.faded()
    SKIN.alpha = faded and 0.3 or 1
    W.active = not faded
    local host = NET.isHost()
    local hover = W.inside(x0, y0, x1, y1)
    W.region("music.chip", x0, y0, x1, y1)
    SKIN.nine("pill", x0, y0, x1, y1)
    SKIN.icon("audio", x0 + 12 * s, y0 + (h - 30 * s) / 2, 30 * s)
    local tx, right = x0 + 50 * s, x1 - 16 * s
    if host and hover and W.active then
      local bs = 30 * s
      local by = y0 + (h - bs) / 2
      right = right - bs
      if W.iconButton("music.chip.next", "next", right, by, bs) then MUSIC.next() end
      right = right - bs - 4 * s
      if W.iconButton("music.chip.play", st.s == "play" and "pause" or "play", right, by, bs) then MUSIC.toggle() end
      right = right - 8 * s
    end
    SKIN.text(tx, y0 + 7 * s, it.title, 15 * s, C.cream, {maxWidth = right - tx})
    SKIN.text(tx, y0 + 28 * s, chipLine(it, st), 13 * s, C.offText, {maxWidth = right - tx})
    if W.clicked("music.chip") then
      PARTY.setSetup(true)
      SETUP.setTab("music")
    end
  end

  -- A closed panel closes the library.
  U.on("party.changed", function()
    if not PARTY.setupOpen() and lib.open then MUI.closeLibrary() end
  end)
end
