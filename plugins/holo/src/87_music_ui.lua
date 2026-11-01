-- music UI (Holo 1.2): the setup panel's Music tab (now playing, seek, the music queue and the Spotify card: sign in,
-- set up an app of your own, waiting for the browser, or the account with its device), its modals (one at a time:
-- the library of saved songs and playlists paged by 50, the setup guide, the device picker) and the now-playing chip
-- at the top of the player's side. On Melange 0.13 the card keeps Holo 1.1's Link block (no guide, no transfer). The
-- chip shows while party music plays or is paused, with or without a video party; F9 hides it with the other
-- surfaces and never stops the music.
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
  local LIB_WHY = {
    ["not-found"] = "Spotify does not let apps read this playlist",
    rate = "Spotify asks to slow down; open this again in a moment",
  }

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
    MUI.closeGuide()
    MUI.closeDevices()
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
      -- the library's own reasons (WHY.rate is about adding songs, and the library is not retried by itself)
      text, kind = LIB_WHY[lib.err] or whyText(lib.err), "error"
    end
    if text then
      SKIN.text(mx0 + 20 * s, by0, text, 15 * s, kind == "error" and C.error or (kind == "warn" and C.warn or C.cream),
        {vcenter = by1 - by0, maxWidth = w - 200 * s})
    end
  end

  ---------------------------------------------------------------- the Music tab: the Spotify card

  local ERROR_TEXT = {denied = "You did not allow access", timeout = "The sign-in timed out; try again",
    ["invalid-client"] = "Check [Spotify] ClientId and the app's Redirect URI", network = "Could not reach Spotify",
    revoked = "Spotify signed Holo out; link again", exchange = "The Spotify sign-in failed; try again"}

  -- The text of a status error. "not-allowlisted" depends on the app: the shared app is closed to this account (set
  -- up an app of your own), or the user's own app has not added this account yet (User Management).
  local function errorText(st)
    local e = st.error
    if e == "not-allowlisted" then
      if st.app ~= "builtin" then
        return "Your Spotify app does not allow this account yet: add it under User Management in the dashboard, "
          .. "then sign in again"
      end
      return SPOT.WHY["not-allowlisted"]
    end
    if e == "invalid-client" and SPOT.hasSetup() and st.app == "user" then
      return "Spotify refused your app's Client ID or Redirect URI; check the setup"
    end
    -- the shared app is Melange's: nothing in Melange.ini to check
    if e == "invalid-client" and SPOT.hasSetup() and st.app == "builtin" then
      return "Spotify refused the shared app's sign-in; use your own Spotify app"
    end
    return ERROR_TEXT[e] or SPOT.WHY[e] or "The Spotify sign-in failed"
  end
  MUI.errorText = errorText

  -- Sign-in and setup answers: SPOT.WHY first (MUI's own WHY speaks of songs and requests). "port-busy" with the
  -- shared app: Melange tried 8780, 8781 and 8782 and ignores [Spotify] RedirectPort for it.
  local PORTS_BUSY = "Ports 8780 to 8782 are all in use by other programs; close one and try again"
  local function spotWhy(why)
    if why == "port-busy" and SPOT.hasSetup() and (SPOT.setup() or {}).app == "builtin" then return PORTS_BUSY end
    return SPOT.WHY[why] or ("Could not do that (" .. tostring(why) .. ")")
  end
  MUI.spotWhy = spotWhy

  -- Device listing and transfer answers: MUI's WHY speaks of adding songs ("rate", "invalid"), SPOT.WHY's "rate"
  -- promises a retry a move does not make.
  local DEV_WHY = {
    rate = "Spotify asks to slow down; try again in a moment",
    invalid = "Spotify cannot use that device",
    ["not-found"] = "That device went away; press Refresh",
    restricted = "That device does not take commands from apps",
    busy = "Spotify is still answering; try again in a moment",
  }
  local function devWhy(why)
    return DEV_WHY[why] or SPOT.WHY[why] or ("Could not do that (" .. tostring(why) .. ")")
  end
  MUI.devWhy = devWhy

  local CONSENT = "Link your Spotify account to add songs from your library and to listen with the party on your own "
    .. "Spotify (Premium). Your browser opens Spotify's sign-in page. Melange keeps the sign-in encrypted on this PC; "
    .. "Holo never sees it, and other players see only the songs you add."
  MUI.CONSENT = CONSENT

  local WAIT_MS = 180000             -- Melange's sign-in deadline
  local HELP_AFTER = 15000           -- ms of waiting before the "Spotify shows an error?" help shows
  local lastState, lastErr, connectingSince = nil, nil, nil

  -- Wrapped text from x, y; returns the y under the last line. kind "display" for headings.
  local function lines(text, x, y, size, rgb, width, maxLines, kind)
    local lh = size * (kind == "display" and 1.25 or 1.3)
    for _, ln in ipairs(SKIN.wrap(text, size, kind or "body", width, maxLines)) do
      SKIN.text(x, y, ln, size, rgb, {kind = kind})
      y = y + lh
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

  -- Which Spotify card the Music tab shows: "old" (Melange 0.12), "unavailable", "signin", "setup" (no app, or the
  -- shared app refused this account), "waiting" (the browser sign-in is open) or "account".
  function MUI.spotifyCard()
    if not SPOT.has() then return "old" end
    local st = SPOT.status()
    if st.state == "connecting" then return "waiting" end
    if st.state == "connected" then return "account" end
    local ok, why = SPOT.available()
    if not SPOT.hasSetup() then return ok and "signin" or "unavailable" end
    if not ok and why ~= "no-client-id" then return "unavailable" end
    local su = SPOT.setup()
    if not su or su.app == nil then return "setup" end
    if su.app == "builtin" and (st.error == "not-allowlisted" or U.pref("spotifyOwnApp") == true) then return "setup" end
    return "signin"
  end

  local function signinCard(ix0, ix1, y, y1, s, st)
    local iw = ix1 - ix0
    if st.state == "error" then y = lines(errorText(st), ix0, y, 14 * s, C.error, iw, 4) + 6 * s end
    if not SPOT.hasSetup() then
      -- Melange 0.13: Holo 1.1's block (the Client ID is in Melange.ini)
      local fit = math.max(3, math.floor((y1 - 70 * s - y) / (17 * s)))
      y = lines(CONSENT, ix0, y, 13 * s, C.cream, iw, fit)
      y = math.max(y + 6 * s, y1 - 60 * s)
      linkButton("music.link", ix0, y, ix1, s, st.linked and "Use my Spotify in Holo" or "Link Spotify")
      return y1
    end
    local su = SPOT.setup() or {}
    y = lines("Play music with the party", ix0, y + 4 * s, 17 * s, C.cream, iw, 2, "display") + 4 * s
    y = lines("Sign in to add songs from your library and to hear the party's music on your own Spotify (Premium).",
      ix0, y, 13 * s, C.cream, iw, 4)
    if (su.app == "user" or su.app == "ini") and su.appHint then
      y = lines("Using your own Spotify app, ID ending " .. su.appHint, ix0, y + 4 * s, 13 * s, C.offText, iw, 2)
    end
    y = math.max(y + 8 * s, y1 - 150 * s)
    if W.button("music.link", ix0, y, ix1, y + 48 * s, st.linked and "Use my Spotify in Holo" or "Sign in with Spotify",
      {size = 17 * s, icon = "link"}) then
      local ok, why = SPOT.connect()
      if not ok then say(spotWhy(why), "error") end
    end
    lines("Spotify's page opens in your browser. Melange keeps the sign-in encrypted on this PC; Holo never sees it.",
      ix0, y + 56 * s, 12 * s, C.offText, iw, 3)
    if W.link("music.ownapp", ix0, y1 - 30 * s, su.app == "builtin" and "Use my own Spotify app" or "Change app",
      14 * s) then
      MUI.openGuide()
    end
    return y1
  end

  local function setupCard(ix0, ix1, y, y1, s, st)
    local iw = ix1 - ix0
    local su = SPOT.setup() or {}
    local refused = st.error == "not-allowlisted" or U.pref("spotifyOwnApp") == true
    if refused then
      y = lines("Your Spotify account is not on the shared app's list.", ix0, y, 14 * s, C.warn, iw, 2) + 6 * s
    elseif st.state == "error" then
      y = lines(errorText(st), ix0, y, 14 * s, C.error, iw, 2) + 6 * s
    end
    y = lines("Set up Spotify", ix0, y + 4 * s, 17 * s, C.cream, iw, 1, "display") + 4 * s
    y = lines("Spotify needs a free app of your own before Holo can play your music. It takes about two minutes, "
      .. "right from here.", ix0, y, 13 * s, C.cream, iw, 5)
    local shared = su.builtin == true and refused
    y = math.max(y + 10 * s, y1 - (shared and 92 or 64) * s)
    if W.button("music.setupapp", ix0, y, ix1, y + 48 * s, "Set up my Spotify app", {size = 17 * s, icon = "add"}) then
      MUI.openGuide()
    end
    if shared and W.link("music.shared", ix0, y1 - 30 * s, "Try the shared app again", 14 * s) then
      U.setPref("spotifyOwnApp", nil)
      SPOT.cancel()                    -- clears the "not-allowlisted" error
    end
    return y1
  end

  local function waitingCard(ix0, ix1, y, y1, s)
    local iw = ix1 - ix0
    local setup = SPOT.hasSetup()
    local now = U.now()
    connectingSince = connectingSince or now
    local since = connectingSince          -- a click below may end the sign-in (and clear connectingSince)
    local is = 40 * s
    SKIN.icon(SKIN.spinner(), ix0, y, is)
    local size = 17 * s
    local tl = SKIN.wrap("Finish signing in in your browser", size, "display", iw - is - 12 * s, 2)
    local lh = size * 1.25
    local ty = y + math.max(0, (is - #tl * lh) / 2)
    for _, ln in ipairs(tl) do
      SKIN.text(ix0 + is + 12 * s, ty, ln, size, C.cream, {kind = "display"})
      ty = ty + lh
    end
    y = math.max(y + is, ty) + 10 * s
    -- Melange 0.14 brings the game back to the front after the sign-in; 0.13 does not
    y = lines(setup and "Log in on Spotify's page and press Agree. The game comes back here by itself."
      or "Log in on Spotify's page and press Agree, then come back to the game.", ix0, y, 13 * s, C.cream, iw, 3)
    local left = math.ceil((WAIT_MS - (now - since)) / 1000)
    if left > 0 then
      SKIN.text(ix0, y + 4 * s, "Waiting for Spotify, " .. U.fmtTime(left) .. " left", 13 * s, C.offText,
        {maxWidth = iw})
    end
    y = y + 30 * s
    if setup then
      if W.button("music.reopen", ix0, y, ix1, y + 40 * s, "Open the page again", {size = 15 * s, icon = "link"}) then
        local ok, why = SPOT.connect()     -- re-opens the same Spotify page (the deadline is not extended)
        if not ok then say(spotWhy(why), "error") end
      end
      y = y + 48 * s
    end
    if W.button("music.cancel", ix0, y, ix0 + 120 * s, y + 40 * s, "Cancel", {size = 15 * s}) then
      SPOT.cancel()
    end
    if setup and now - since >= HELP_AFTER then
      local su = SPOT.setup() or {}
      local builtin = su.app == "builtin"
      SKIN.text(ix0, y1 - 50 * s, builtin and "Spotify shows an error?" or "Spotify says the redirect URI is wrong?",
        13 * s, C.offText, {maxWidth = iw})
      if W.link("music.wait.help", ix0, y1 - 30 * s, builtin and "Use your own app" or "Check the setup", 13 * s) then
        SPOT.cancel()
        MUI.openGuide()
      end
    end
    return y1
  end

  -- The "Plays on" button: the chosen device (or what plays now), opening the device picker.
  local function deviceButton(x0, y0, x1, s)
    local id = "music.device"
    local y1 = y0 + 44 * s
    W.region(id, x0, y0, x1, y1)
    local st = W.state(id, x0, y0, x1, y1, true)
    SKIN.nine(st == "press" and "btn_press" or (st == "hover" and "btn_hover" or "well"), x0, y0, x1, y1)
    local cid, name = SPOT.chosen()
    local kind
    for _, d in ipairs(SPOT.deviceList().items) do
      if cid and d.id == cid then
        kind, name = d.kind, name or d.name
        break
      end
    end
    if not name then
      local pb = MUSIC.playback()
      if pb and pb.device and pb.device.name and pb.device.name ~= "" then
        name, kind = pb.device.name, SPOT.kindOf(pb.device.type)
      end
    end
    local tx = x0 + 44 * s
    SKIN.glyph(kind or "device", x0 + 12 * s, y0 + 10 * s, 24 * s, name and C.cream or C.offText)
    SKIN.text(tx, y0, name or "Choose a device", 15 * s, name and C.cream or C.warn,
      {vcenter = y1 - y0, maxWidth = x1 - 40 * s - tx})
    SKIN.icon("down", x1 - 34 * s, y0 + 11 * s, 22 * s, st == "hover" and "hover" or "normal")
    if W.clicked(id) then MUI.openDevices() end
    return y1
  end

  local function accountCard(ix0, ix1, y, y1, s, st, host)
    local iw = ix1 - ix0
    local setup = SPOT.hasSetup()
    -- who: avatar, name over the plan, and Sign out at the end of the plan line (the column is too narrow for a
    -- button beside the name: the name gets the whole width)
    local d = 44 * s
    SKIN.avatar(st.user, ix0, y, d)
    local nx = ix0 + d + 10 * s
    SKIN.text(nx, y + 1 * s, (st.user and st.user ~= "") and st.user or "Spotify account", 18 * s, C.cream,
      {kind = "display", maxWidth = ix1 - nx})
    local ow = SKIN.measure("Sign out", 13 * s, "body")
    if W.link("music.unlink", ix1, y + 27 * s, "Sign out", 13 * s, {align = "right"}) then SPOT.disconnect() end
    if st.premium == true then
      SKIN.badge(nx, y + 25 * s, "Premium", 12 * s, C.ok)
    elseif st.premium == false or MUSIC.notPremium() then
      SKIN.badge(nx, y + 25 * s, "Free", 12 * s, C.warn)
    else
      SKIN.text(nx, y + 27 * s, "Plan not known yet", 12 * s, C.offText, {maxWidth = ix1 - ow - 10 * s - nx})
    end
    y = y + d + 12 * s
    if setup then
      local app = st.app or (SPOT.setup() or {}).app
      local label = (app == "builtin" and "Shared Spotify app") or (app == "user" and "Your own Spotify app")
        or (app == "ini" and "Spotify app from Melange.ini") or "Spotify app"
      local lw = SKIN.measure("Change app", 12 * s, "body")
      SKIN.text(ix0, y, label, 12 * s, C.offText, {maxWidth = iw - lw - 10 * s})
      if W.link("music.changeapp", ix1, y, "Change app", 12 * s, {align = "right"}) then MUI.openGuide() end
      y = y + 22 * s
    end
    SKIN.text(ix0, y, "Plays on", 13 * s, C.offText)
    y = deviceButton(ix0, y + 18 * s, ix1, s) + 8 * s
    if MUSIC.lastError() == "no-device" then
      y = lines("No device: open Spotify on this PC or your phone", ix0, y - 2 * s, 12 * s, C.warn, iw, 2) + 4 * s
    end
    if st.premium == false or MUSIC.notPremium() then
      y = lines("Free account: you see what plays but cannot play it here", ix0, y, 13 * s, C.warn, iw, 2) + 4 * s
    end
    if MUSIC.detached() then
      y = lines("You changed the music in Spotify; Holo stopped following until the host's next song. "
        .. "To keep your own music, use Mute here.", ix0, y, 13 * s, C.warn, iw, 3)
      if W.button("music.follow", ix0, y + 2 * s, ix0 + 160 * s, y + 38 * s, "Follow again", {size = 14 * s}) then
        MUSIC.followAgain()
      end
      y = y + 44 * s
    end
    y = y + 4 * s
    if W.button("music.browse", ix0, y, ix1, y + 44 * s, "Add from my library",
      {size = 17 * s, icon = "add", enabled = MUSIC.canAdd()}) then
      MUI.openLibrary()
    end
    y = y + 52 * s
    if host then
      listenButton("music.listen", ix0, y, ix0 + 150 * s, y + 36 * s, s)
      y = y + 44 * s
    end
    return y
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
    local card = MUI.spotifyCard()
    if card == "old" then
      return lines("Spotify music needs Melange " .. SPOT.NEEDS .. " or later. You can still see what the party plays.",
        ix0, y, 14 * s, C.cream, iw, 4)
    elseif card == "unavailable" then
      local _, why = SPOT.available()
      return lines(SPOT.WHY[why] or ("Spotify is not available (" .. tostring(why) .. ")"), ix0, y, 14 * s, C.cream,
        iw, 4)
    end
    local st = SPOT.status()
    if card == "waiting" then return waitingCard(ix0, ix1, y, y1 - 10 * s, s) end
    if card == "account" then return accountCard(ix0, ix1, y, y1 - 10 * s, s, st, host) end
    if card == "setup" then return setupCard(ix0, ix1, y, y1 - 10 * s, s, st) end
    return signinCard(ix0, ix1, y, y1 - 10 * s, s, st)
  end

  -- Sign-in transitions: the countdown starts with "connecting"; a finished sign-in says who and closes the guide; the
  -- shared app refusing this account opens the guide while the Music tab shows.
  U.on("spot.status", function(st)
    if st.state == "connecting" and lastState ~= "connecting" then connectingSince = U.now() end
    if st.state ~= "connecting" then connectingSince = nil end
    if st.state == "connected" and lastState == "connecting" then
      say("Signed in as " .. ((st.user and st.user ~= "") and st.user or "your Spotify account"), "info")
      MUI.closeGuide()
    end
    if st.error == "not-allowlisted" and st.app == "builtin" and lastErr ~= "not-allowlisted"
      and PARTY.setupOpen() and SETUP.tab() == "music" then
      if MUI.openGuide() then MUI.guideNote("Your Spotify account is not on the shared app's list.") end
    end
    -- signed out (Sign out, revoked, not allowlisted): the device picker has nothing left to list or move
    if st.state ~= "connected" and MUI.devicesOpen() then MUI.closeDevices() end
    lastState, lastErr = st.state, st.error
  end)

  ---------------------------------------------------------------- the setup guide (Melange 0.14)

  -- Three steps to an app of the user's own: open Spotify's dashboard, copy the Redirect URI, paste the Client ID.
  -- Every button is a click Melange checks (open, copy, paste, save need one; save then signs in with the same click).
  local guide = {open = false, box = W.newText("music.guide.id"), copiedAt = -1e9, copiedEver = false, openedAt = nil,
    err = nil, note = nil}
  local ID_TEXT = "A Client ID has 32 letters and digits"

  function MUI.guideOpen() return guide.open end
  function MUI.guide() return guide end
  function MUI.guideNote(text) guide.note = text end

  -- Opens the guide (only on Melange 0.14; a no-op otherwise). true when it is open.
  function MUI.openGuide()
    if not SPOT.hasSetup() then return false end
    if not guide.open then
      MUI.closeLibrary()
      MUI.closeDevices()
      guide.open = true
      guide.box.text, guide.box.caret, guide.box.anchor, guide.box.scroll = "", 0, nil, 0
      guide.copiedAt, guide.copiedEver, guide.openedAt, guide.err, guide.note = -1e9, false, nil, nil, nil
      SPOT.dropSetup()
    end
    return true
  end

  function MUI.closeGuide()
    if guide.box.focused then W.blur() end
    guide.open = false
  end

  local function validId(t) return #t == 32 and t:match("^%w+$") ~= nil end

  -- The Client ID in the box: the trimmed text when it is one, or else the one run of exactly 32 letters and digits in
  -- it (the rule Melange's Paste uses, for text pasted with Ctrl+V such as "Client ID 0a1b..."), or nil.
  local function idIn(text)
    local t = U.trim(text)
    if validId(t) then return t end
    local found, n = nil, 0
    for run in t:gmatch("%w+") do
      if #run == 32 then found, n = run, n + 1 end
    end
    return n == 1 and found or nil
  end
  MUI.idIn = idIn

  -- Save and sign in: saves the Client ID (Melange signs out a sign-in made with another app), then opens Spotify's
  -- page with the same click. fromKey: Enter in the box (no click: Melange may ask for one).
  local function guideSave(fromKey)
    local t = idIn(guide.box.text)
    if not t then
      guide.err = ID_TEXT
      return
    end
    local ok, why = SPOT.setClientId(t)
    if not ok then
      if why == "invalid" then guide.err = ID_TEXT
      elseif why == "gesture" and fromKey then guide.err = "Click Save and sign in to finish"
      else guide.err = spotWhy(why) end
      return
    end
    U.setPref("spotifyOwnApp", nil)
    local c, why2 = SPOT.connect()
    MUI.closeGuide()
    if not c then say(spotWhy(why2), "error") end
  end

  local function modalFrame(id, x0, y0, x1, y1, s, mw, mh, title)
    local W0, H0 = x1 - x0, y1 - y0
    local w, h = math.min(mw * s, W0 - 40 * s), math.min(mh * s, H0 - 40 * s)
    local mx0, my0 = x0 + (W0 - w) / 2, y0 + (H0 - h) / 2
    SKIN.rect(x0, y0, x1, y1, C.black, 0.45)
    W.region(id, mx0, my0, mx0 + w, my0 + h, "arrow")
    SKIN.nine("panel_dark", mx0, my0, mx0 + w, my0 + h)
    SKIN.text(mx0 + 20 * s, my0 + 14 * s, title, 22 * s, C.title, {kind = "display", maxWidth = w - 90 * s})
    return mx0, my0, mx0 + w, my0 + h
  end

  local function msgColour(kind) return kind == "error" and C.error or (kind == "warn" and C.warn or C.offText) end

  function MUI.drawGuide(x0, y0, x1, y1, s)
    local mx0, my0, mx1, my1 = modalFrame("music.guide", x0, y0, x1, y1, s, 720, 560, "Use your own Spotify app")
    if W.iconButton("music.guide.close", "close", mx1 - 52 * s, my0 + 12 * s, 36 * s) then
      MUI.closeGuide()
      return
    end
    local su = SPOT.setup() or {redirectUri = "http://127.0.0.1:8780/callback"}
    local w = mx1 - mx0
    lines("Spotify lets every free developer app play music for you and a few friends you add. Three steps:",
      mx0 + 20 * s, my0 + 50 * s, 14 * s, C.cream, w - 40 * s, 2)
    local sx = mx0 + 20 * s
    local ax = sx + 46 * s
    local tw = mx1 - 20 * s - ax
    local now = U.now()
    local function step(i, title, body, done)
      local sy = my0 + 96 * s + (i - 1) * 118 * s
      local b = 32 * s
      SKIN.nine("pill", sx, sy, sx + b, sy + b, {tint = C.btn})
      if done then
        SKIN.icon("check", sx + 5 * s, sy + 5 * s, b - 10 * s)
      else
        SKIN.text(sx + b / 2, sy, tostring(i), 18 * s, C.title, {kind = "display", align = "center", vcenter = b})
      end
      SKIN.text(ax, sy, title, 17 * s, C.gold, {kind = "display", vcenter = b, maxWidth = tw})
      lines(body, ax, sy + 32 * s, 13 * s, C.cream, tw, 2)
      return sy + 62 * s
    end

    -- 1. create the app
    local ay = step(1, "Create a free app",
      "Log in to Spotify for Developers and press Create app. Any name and description will do.", guide.openedAt ~= nil)
    local bh = 40 * s
    if W.button("music.guide.open", ax, ay, ax + 290 * s, ay + bh, "Open Spotify for Developers",
      {size = 15 * s, icon = "link"}) then
      local ok, why = SPOT.openDashboard()
      if ok then guide.openedAt, guide.err = U.now(), nil else guide.err = spotWhy(why) end
    end
    if guide.openedAt then
      SKIN.icon("check", ax + 302 * s, ay + 7 * s, 26 * s)
      SKIN.text(ax + 334 * s, ay, "Opened in your browser", 13 * s, C.offText,
        {vcenter = bh, maxWidth = mx1 - 20 * s - (ax + 334 * s)})
    end

    -- 2. the Redirect URI
    ay = step(2, "Add this Redirect URI", "Paste it under Redirect URIs and press Add. Tick Web API, then Save.",
      guide.copiedEver)
    local wx1 = mx1 - 150 * s
    SKIN.nine("well", ax, ay, wx1, ay + bh)
    SKIN.text(ax + 14 * s, ay, su.redirectUri, 17 * s, C.title, {vcenter = bh, maxWidth = wx1 - ax - 28 * s})
    local copied = now - guide.copiedAt < 2000
    if W.button("music.guide.copy", mx1 - 140 * s, ay, mx1 - 20 * s, ay + bh, copied and "Copied" or "Copy",
      {size = 15 * s, icon = copied and "check" or nil}) then
      local ok, why = SPOT.copyRedirect()
      if ok then
        guide.copiedAt, guide.copiedEver, guide.err = U.now(), true, nil
      else
        guide.err = why == "gesture" and SPOT.WHY.gesture or "Could not copy to the clipboard; try again"
      end
    end

    -- 3. the Client ID: typed or pasted (Ctrl+V in the box, or the Paste button: Melange reads only an ID from the
    -- clipboard); Paste saves and signs in at once, like Save
    ay = step(3, "Paste your Client ID", "Open your app's Settings and copy the Client ID.",
      idIn(guide.box.text) ~= nil)
    local ph = "32 letters and digits"
    if su.app == "user" and su.appHint then ph = "32 letters and digits (yours ends " .. su.appHint .. ")" end
    local r = W.textbox(guide.box, ax, ay, wx1, ay + bh, {size = 16 * s, placeholder = ph})
    if r == "changed" then guide.err = nil end
    local valid = idIn(guide.box.text) ~= nil
    if U.trim(guide.box.text) ~= "" then SKIN.icon(valid and "check" or "cross", wx1 + 4 * s, ay + 5 * s, 30 * s) end
    if W.button("music.guide.paste", mx1 - 110 * s, ay, mx1 - 20 * s, ay + bh, "Paste", {size = 15 * s}) then
      local id, why = SPOT.pasteClientId()
      if id then
        guide.box.text, guide.box.caret, guide.box.anchor, guide.err = id, #id, nil, nil
        guideSave(false)
        if not guide.open then return end
      else
        guide.err = spotWhy(why)
      end
    end
    lines("Friends who use your app: add their Spotify e-mail under User Management.", ax, ay + bh + 6 * s, 12 * s,
      C.offText, tw, 1)
    if r == "submit" then
      guideSave(true)
      if not guide.open then return end
    end

    -- footer: the shared app (when this build has one and another app is in use), messages, Save and sign in
    local by0, by1 = my1 - 60 * s, my1 - 16 * s
    local msg, kind = guide.err, "error"
    if not msg and guide.note then msg, kind = guide.note, "warn" end
    -- Clearing the in-game Client ID falls back to Melange.ini's, then to the shared app: offered only when the
    -- in-game one is in use and there is something to fall back to (an ini app cannot be cleared from the game).
    local fallback = su.app == "user" and (su.ini == true and "ini" or (su.builtin == true and "builtin")) or nil
    local shared = fallback ~= nil
    local above, aboveKind
    if SPOT.connected() then above, aboveKind = "Saving a different app signs you out of Spotify here.", "warn" end
    if shared and msg then above, aboveKind = msg, kind end     -- the footer's left holds the shared-app link
    if above then
      SKIN.text(mx0 + 20 * s, by0 - 24 * s, above, 13 * s, msgColour(aboveKind), {maxWidth = w - 40 * s})
    end
    local fw = mx1 - 272 * s - (mx0 + 20 * s)
    if shared then
      local label = fallback == "ini" and "Use the app from Melange.ini" or "Use the shared app instead"
      local _, lh = SKIN.measure(label, 14 * s, "body")
      if W.link("music.guide.shared", mx0 + 20 * s, by0 + (by1 - by0 - lh) / 2, label, 14 * s) then
        local ok, why = SPOT.setClientId(nil)
        if ok then
          MUI.closeGuide()
          local now = (SPOT.setup() or {}).app
          say(now == "ini" and "Using the Spotify app from Melange.ini" or (now == "builtin"
            and "Using the shared Spotify app" or "Your Client ID is removed"), "info")
          return
        end
        guide.err = spotWhy(why)
      end
    elseif msg then
      local ls = SKIN.wrap(msg, 13 * s, "body", fw, 2)
      local yy = by0 + (by1 - by0 - #ls * 13 * s * 1.3) / 2
      for _, ln in ipairs(ls) do
        SKIN.text(mx0 + 20 * s, yy, ln, 13 * s, msgColour(kind))
        yy = yy + 13 * s * 1.3
      end
    end
    if W.button("music.guide.save", mx1 - 260 * s, by0, mx1 - 20 * s, by1, "Save and sign in",
      {size = 17 * s, enabled = valid}) then
      guideSave(false)
    end
  end

  ---------------------------------------------------------------- the device picker

  -- Every Spotify Connect device of the account (desktop app, phone, speaker, console, web player); a pick moves the
  -- music there (Melange 0.14: transfer) and is remembered (Melange 0.13: remembered, used from the next song).
  local DEV_ROW = 56
  local DEV_REFRESH = 10000          -- ms between listings while the picker is open
  local devs = {open = false, scroll = 0, pending = nil, lastTry = -1e9}

  function MUI.devicesOpen() return devs.open end
  function MUI.devicesState() return devs end

  function MUI.openDevices()
    MUI.closeLibrary()
    MUI.closeGuide()
    local now, dev = U.now(), SPOT.deviceList()
    devs.open, devs.scroll = true, 0
    -- a listing younger than 3 s is shown as it is (opening and closing the picker does not spend requests)
    if dev.err or dev.at <= 0 or now - dev.at >= 3000 then
      devs.lastTry = now
      SPOT.refreshDevices()
    else
      devs.lastTry = dev.at              -- the 10 s refresh counts from that listing
    end
  end

  -- A device row's region id: the device's own id (cut to the 64 bytes a region id may have), so a listing that
  -- arrives between the press and the release cannot turn the click into a click on another device.
  function MUI.deviceRowId(d) return "music.dev.r." .. d.id:sub(1, 52) end

  function MUI.closeDevices() devs.open = false end

  local function refreshLater()
    wum.timers.after(1.5, U.guard("mui.devices", function()
      if SPOT.connected() then SPOT.refreshDevices() end
    end))
  end

  function MUI.pickDevice(d)
    if type(d) ~= "table" or d.restricted then return end
    if not SPOT.hasTransfer() then
      SPOT.choose(d)
      MUSIC.deviceChanged()
      say("The party's music will play on " .. d.name .. " from the next song", "info")
      return
    end
    if devs.pending then return end
    local play = MUSIC.audible()
    devs.pending = d.id
    local rid, why = SPOT.transfer(d.id, play, function(res)
      devs.pending = nil
      local e = res.error
      if not e then
        SPOT.choose(d)
        MUSIC.deviceChanged()
        say(play and ("Now playing on " .. d.name) or ("The party's music will play on " .. d.name), "info")
        refreshLater()
      elseif e == "premium" then
        SPOT.choose(d)
        say("Moving the music needs Spotify Premium", "warn")
      else
        say(devWhy(e), "error")
        if e == "not-found" then SPOT.refreshDevices() end
      end
    end)
    if not rid then
      devs.pending = nil
      say(devWhy(why), "error")
    end
  end

  local function centred(text, cx, y, size, rgb, width, maxLines)
    for _, ln in ipairs(SKIN.wrap(text, size, "body", width, maxLines)) do
      SKIN.text(cx, y, ln, size, rgb, {align = "center"})
      y = y + size * 1.3
    end
    return y
  end

  function MUI.drawDevices(x0, y0, x1, y1, s)
    local mx0, my0, mx1, my1 = modalFrame("music.dev", x0, y0, x1, y1, s, 560, 500, "Play music on")
    if W.iconButton("music.dev.close", "close", mx1 - 52 * s, my0 + 12 * s, 36 * s) then
      MUI.closeDevices()
      return
    end
    local w = mx1 - mx0
    local st = SPOT.status()
    local who = (st.user and st.user ~= "") and ("signed in as " .. st.user) or "signed in to your account"
    lines("Any Spotify app " .. who .. ": this PC, a phone, a speaker, a console or the web player.", mx0 + 20 * s,
      my0 + 50 * s, 13 * s, C.offText, w - 40 * s, 2)
    local dev = SPOT.deviceList()
    local now = U.now()
    if not dev.loading and now - devs.lastTry >= DEV_REFRESH then
      devs.lastTry = now
      SPOT.refreshDevices()
    end
    -- the list
    local lx0, ly0, lx1, ly1 = mx0 + 16 * s, my0 + 96 * s, mx1 - 16 * s, my1 - 64 * s
    W.region("music.dev.list", lx0, ly0, lx1, ly1, "arrow")
    SKIN.nine("well", lx0, ly0, lx1, ly1)
    local items = dev.items
    local rowH = DEV_ROW * s
    local viewH = ly1 - ly0 - 12 * s
    local maxScroll = math.max(0, #items * DEV_ROW - viewH / s)
    devs.scroll = U.clamp(devs.scroll - W.wheel("music.dev.list") * DEV_ROW, 0, maxScroll)
    local cx = (lx0 + lx1) / 2
    if #items == 0 then
      if dev.loading then
        SKIN.icon(SKIN.spinner(), cx - 16 * s, ly0 + 40 * s, 32 * s)
        SKIN.text(cx, ly0 + 82 * s, "Looking for your devices...", 15 * s, C.offText, {align = "center"})
      elseif dev.err then
        centred(devWhy(dev.err), cx, ly0 + 40 * s, 14 * s, C.error, lx1 - lx0 - 60 * s, 3)
      else
        SKIN.glyph("speaker", cx - 18 * s, ly0 + 30 * s, 36 * s, C.offText)
        SKIN.text(cx, ly0 + 78 * s, "No devices found", 18 * s, C.cream, {kind = "display", align = "center"})
        centred("Open Spotify on any phone, speaker or computer signed in to your account, then press Refresh.", cx,
          ly0 + 108 * s, 14 * s, C.offText, lx1 - lx0 - 80 * s, 3)
      end
    else
      local cid = SPOT.chosen()
      local first = math.floor(devs.scroll / DEV_ROW) + 1
      local last = math.min(#items, first + math.ceil(viewH / rowH) + 1)
      SKIN.clip(lx0 + 6 * s, ly0 + 6 * s, lx1 - 6 * s, ly1 - 6 * s)
      for i = first, last do
        local d = items[i]
        local ry0 = ly0 + 6 * s + (i - 1) * rowH - devs.scroll * s
        local ry1 = ry0 + rowH
        local rx0, rx1 = lx0 + 6 * s, lx1 - 6 * s
        -- a row half in view still takes clicks, on its visible part only
        local vy0, vy1 = math.max(ry0, ly0 + 6 * s), math.min(ry1, ly1 - 6 * s)
        local vis = vy1 - vy0 >= rowH * 0.5
        local rid = MUI.deviceRowId(d)
        local stt = "normal"
        if not d.restricted and vis then
          W.region(rid, rx0, vy0, rx1, vy1)
          stt = W.state(rid, rx0, vy0, rx1, vy1, true)
        end
        local chosen = cid ~= nil and d.id == cid
        if chosen then
          SKIN.part("swash", rx0 + 2 * s, ry0 + 4 * s, rx1 - 2 * s, ry1 - 4 * s)
        elseif stt == "hover" or stt == "press" then
          SKIN.part("swash", rx0 + 2 * s, ry0 + 4 * s, rx1 - 2 * s, ry1 - 4 * s, {a = stt == "press" and 0.8 or 0.45})
        end
        local fg = d.restricted and C.offText or (chosen and C.title or C.cream)
        SKIN.glyph(d.kind, rx0 + 12 * s, ry0 + 13 * s, 30 * s, d.restricted and C.offText or C.cream)
        local right = rx1 - 14 * s
        if devs.pending == d.id then
          SKIN.icon(SKIN.spinner(), right - 26 * s, ry0 + 15 * s, 26 * s)
          right = right - 36 * s
        elseif chosen then
          SKIN.icon("check", right - 26 * s, ry0 + 15 * s, 26 * s)
          right = right - 36 * s
        end
        if d.active then
          local dy = ry0 + (rowH - 10 * s) / 2
          SKIN.nine("bar_fill", right - 10 * s, dy, right, dy + 10 * s, {tint = C.ok})
          right = right - 20 * s
        end
        local tx = rx0 + 54 * s
        SKIN.text(tx, ry0 + 8 * s, d.name, 17 * s, fg, {maxWidth = right - tx})
        local sub
        if d.restricted then
          sub = "Spotify does not let apps control this device"
        else
          sub = d.label .. (d.active and " · Playing now" or "") .. (d.private and " · Private session" or "")
        end
        SKIN.text(tx, ry0 + 31 * s, sub, 13 * s, C.offText, {maxWidth = right - tx})
        if i < #items then SKIN.part("divider", lx0 + 20 * s, ry1 - 3 * s, lx1 - 20 * s, ry1 + 1 * s, {a = 0.25}) end
        if not d.restricted and vis and W.clicked(rid) then MUI.pickDevice(d) end
      end
      SKIN.clipEnd()
    end
    -- footer: messages and Refresh
    local by0, by1 = my1 - 54 * s, my1 - 14 * s
    if W.button("music.dev.refresh", mx1 - 150 * s, by0, mx1 - 20 * s, by1, "Refresh",
      {size = 15 * s, enabled = not dev.loading}) then
      devs.lastTry = U.now()
      SPOT.refreshDevices()
    end
    local text, kind = status, statusKind
    if text and U.now() - statusAt > 6000 then text = nil end
    if not text and dev.err and #items > 0 then text, kind = devWhy(dev.err), "error" end
    if not text and dev.loading and #items > 0 then
      SKIN.icon(SKIN.spinner(), mx0 + 20 * s, by0 + 6 * s, 28 * s)
    elseif text then
      SKIN.text(mx0 + 20 * s, by0, text, 14 * s, kind == "error" and C.error or (kind == "warn" and C.warn or C.cream),
        {vcenter = by1 - by0, maxWidth = w - 200 * s})
    end
  end

  ---------------------------------------------------------------- one modal at a time

  function MUI.modalOpen() return lib.open or guide.open or devs.open end

  function MUI.closeModals()
    MUI.closeLibrary()
    MUI.closeGuide()
    MUI.closeDevices()
  end

  function MUI.drawModal(x0, y0, x1, y1, s)
    if lib.open then MUI.drawLibrary(x0, y0, x1, y1, s)
    elseif guide.open then MUI.drawGuide(x0, y0, x1, y1, s)
    elseif devs.open then MUI.drawDevices(x0, y0, x1, y1, s) end
  end

  ---------------------------------------------------------------- the Music tab

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
      if not it then break end                -- a remove in this loop shortened the list
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
      -- the Spotify column is narrow: a reason that does not fit one line (a sign-in failure says what to do) takes
      -- two smaller lines instead of being cut
      local rgb = kind == "error" and C.error or (kind == "warn" and C.warn or C.cream)
      if SKIN.measure(text, 14 * s, "body") <= rx1 - rx0 then
        SKIN.text(rx0, y1 - 34 * s, text, 14 * s, rgb)
      else
        lines(text, rx0, y1 - 37 * s, 12 * s, rgb, rx1 - rx0, 2)
      end
    end
    return by
  end

  ---------------------------------------------------------------- the now-playing chip

  local function chipLine(it, st)
    if st.s == "pause" then return "Paused" end
    if not SPOT.has() then return "Listening needs Melange " .. SPOT.NEEDS .. " or later" end
    if not SPOT.connected() then
      return (SPOT.hasSetup() and "Sign in to Spotify" or "Link Spotify") .. " in the watch party panel ("
        .. (CFG.hotkeyKey("setup") or "F6") .. ") to listen"
    end
    if MUSIC.audible() then
      local pb = MUSIC.playback()
      local dev = pb and pb.device and pb.device.name
      if dev and dev ~= "" then return (it.artists ~= "" and (it.artists .. " · ") or "") .. "on " .. dev end
      return it.artists
    end
    if SPOT.free() or MUSIC.notPremium() then return "Free account: playing needs Premium" end
    if not MUSIC.listening() then return "Muted here" end
    if MUSIC.detached() then return "Not following until the next song: you changed the music in Spotify" end
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

  -- A closed panel closes the open modal (library, setup guide or device picker).
  U.on("party.changed", function()
    if not PARTY.setupOpen() and MUI.modalOpen() then MUI.closeModals() end
  end)
end
