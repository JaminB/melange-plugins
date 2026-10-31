-- music (Holo 1.1): the party's Spotify music lane. Its host is the lobby owner (or this machine without a lobby),
-- with or without a video party. The host keeps the music queue and an abstract clock ms = {e, i, s, p, a} (epoch,
-- item id, "play"|"pause"|"stop", position ms, the host's U.now() at which p holds) and needs no Spotify itself.
-- Every machine that listens, the host included, follows that clock on its OWN Spotify device (SPOT); the others see
-- what plays. Hiding or minimising the player, closing the panel, a video ending or a video party ending never stop
-- the music: only Stop, the end of the music queue, leaving the lobby or the lobby changing hands do (nothing here
-- listens to PARTY's end, LAYOUT or the setup panel).
-- Wire (all ignored by Holo 1.0.x): "mq" queue pages and "ms" state (host -> all), "madd" / "mrm" / "mneed"
-- (member -> host), "maddr" (host -> member). Bus events: "music.changed", "music.addResult" (ok, why, count),
-- "music.detached" (the user took over in Spotify; offer "Follow again").
do
  local MAX_ITEMS, MEMBER_MAX = 200, 50
  local TITLE, ARTISTS, BY = 80, 80, 32
  local MAX_DUR, MIN_DUR = 7200000, 1000
  local PAGE_BYTES, MAX_PAGES = 7000, 64
  local ADD_CHUNK = 20
  local HEARTBEAT = 5000             -- host: unreliable "ms" while playing
  local MQ_DEBOUNCE = 300
  local MADD_ACCEPT, MRM_ACCEPT, MNEED_ACCEPT = 500, 500, 5000   -- host, per member
  local ADD_TOAST_EVERY = 3000
  local NEED_EVERY = 3000            -- peer: "mneed" at most this often
  local ADD_EVERY = 1000             -- peer: one MUSIC.add per second
  local CHUNK_EVERY = 600            -- peer: one "madd" chunk per 0.6 s (the host takes one per 0.5 s)
  local ADD_WAIT = 45000
  local POLL_PLAY, POLL_PAUSE = 3000, 10000
  local DRIFT_MAX, SEEK_HOLD = 1500, 8000
  local OVERRIDE_GRACE = 4000        -- ms after Holo's own action before a different playback counts as the user's
  local END_SLACK = 250
  local RESUME_AFTER = 1000          -- host: the video must be off this long before auto-paused music resumes
  local PLAY_TRIES = 3               -- follower: plays of one song that failed for a passing reason, then it waits
  local PAUSE_RETRY, PAUSE_GIVEUP = 1500, 15000   -- follower: a pause that did not go through is sent again
  -- Request errors that pass: the request is worth sending again later ("busy" also when Holo's own cap is full).
  local PASSING = {busy = true, rate = true, network = true, timeout = true, server = true}
  MUSIC.MAX_ITEMS, MUSIC.MEMBER_MAX, MUSIC.ADD_CHUNK = MAX_ITEMS, MEMBER_MAX, ADD_CHUNK

  local items, mv, nextId = {}, 0, 1
  local partial = nil
  local epoch = 0
  local ms = {e = 0, i = 0, s = "stop", p = 0, a = U.now()}
  local dirtyAt, lastBeat = nil, -1e9
  local members = {}                 -- host: id -> {addAt, rmAt, needAt, toastAt}
  local autoPaused, override, vidWas, vidOffAt = false, nil, false, nil
  -- peer
  local lastNeed, lastAdd = -1e9, -1e9
  local pendingAdds, nextAddN, chunks, lastChunk = {}, 1, {}, -1e9
  -- follower
  local owned = nil                  -- {uri, e, at, playing}: the track Holo started on this machine's device
  local issued = nil                 -- {e, uri}: the state Holo last acted on (no retry within one epoch)
  local lastPb, lastPoll, polling = nil, -1e9, false
  local lastSeek, lastAction = -1e9, -1e9
  local detached, notPremium, lastError, backoffUntil = false, false, nil, -1e9
  local playTry = nil                -- {e, uri, n, at}: the last play failed for a passing reason; again at `at`
  local wantPause = nil              -- {since, next}: a pause of Holo's track that has not gone through yet
  local wasFollow = false

  local function toast(text, kind) U.emit("party.toast", text, kind or "info") end
  local function changed() U.emit("music.changed") end

  ---------------------------------------------------------------- reads

  function MUSIC.items() return items end
  function MUSIC.count() return #items end
  function MUSIC.version() return mv end
  function MUSIC.state() return ms end
  function MUSIC.isHost() return NET.isHost() end

  function MUSIC.indexOf(id)
    for i, it in ipairs(items) do
      if it.id == id then return i end
    end
  end

  function MUSIC.find(id)
    local i = MUSIC.indexOf(id)
    return i and items[i]
  end

  -- The item of ms.i, or nil. Cached per (items table, version, id): the follower, the chip and the game-music check
  -- read it every frame.
  local curItems, curMv, curI, curIt = nil, nil, nil, nil
  function MUSIC.current()
    if ms.i == 0 then return nil end
    if curItems ~= items or curMv ~= mv or curI ~= ms.i then
      curItems, curMv, curI, curIt = items, mv, ms.i, MUSIC.find(ms.i)
    end
    return curIt
  end

  -- Position of a state in ms at this machine's now; hostOffset turns this machine's clock into the host's.
  function MUSIC.pos(st, hostOffset)
    if st.s == "play" then return st.p + (U.now() + (hostOffset or 0) - st.a) end
    return st.p
  end

  local function hostOffset()
    if NET.isHost() then return 0 end
    local c = NET.clock(NET.hostId())
    return c and U.num(c.offset) or 0
  end

  -- The current position in ms, inside the current item.
  function MUSIC.position()
    local it = MUSIC.current()
    local p = MUSIC.pos(ms, hostOffset())
    if it then p = math.min(p, it.durationMs) end
    return math.max(0, p)
  end

  ---------------------------------------------------------------- items and their wire form

  -- A Spotify track URI: "spotify:track:" and a 22-character base-62 id.
  function MUSIC.validUri(u)
    return type(u) == "string" and #u == 36 and u:match("^spotify:track:[0-9A-Za-z]+$") ~= nil
  end

  -- A checked item {uri, title, artists, durationMs} or nil.
  function MUSIC.checkItem(u, ti, ar, d)
    if not MUSIC.validUri(u) then return nil end
    if math.type(d) ~= "integer" or d < MIN_DUR or d > MAX_DUR then return nil end
    local title = U.trim(ti, TITLE)
    if title == "" then title = "Spotify track" end
    return {uri = u, title = title, artists = U.trim(ar, ARTISTS), durationMs = d}
  end

  local function toWire(it)
    return {id = it.id, u = it.uri, ti = it.title, ar = it.artists, d = it.durationMs, b = it.by, bi = it.byId}
  end

  function MUSIC.checkWire(w)
    if type(w) ~= "table" or math.type(w.id) ~= "integer" or w.id < 1 then return nil end
    local it = MUSIC.checkItem(w.u, w.ti, w.ar, w.d)
    if not it then return nil end
    it.id = w.id
    local b = U.trim(w.b, BY)
    if b ~= "" then it.by = b end
    if type(w.bi) == "string" and #w.bi > 0 and #w.bi <= 32 then it.byId = w.bi end
    return it
  end

  local function countBy(id)
    local n = 0
    for _, it in ipairs(items) do
      if it.byId == id then n = n + 1 end
    end
    return n
  end

  local function hasUri(uri)
    for _, it in ipairs(items) do
      if it.uri == uri then return true end
    end
    return false
  end

  local function queueChanged()
    mv = mv + 1
    dirtyAt = dirtyAt or U.now()
    changed()
  end

  function MUSIC.pages()
    local pages, page, bytes = {}, {}, 0
    for _, it in ipairs(items) do
      local w = toWire(it)
      local b = NET.sizeOf(w)
      if #page > 0 and (bytes + b > PAGE_BYTES or #page >= 100) then
        pages[#pages + 1] = page
        page, bytes = {}, 0
      end
      page[#page + 1] = w
      bytes = bytes + b
    end
    pages[#pages + 1] = page
    local out = {}
    for i, p in ipairs(pages) do
      out[i] = {t = "mq", mv = mv, page = i, pages = #pages, items = p, cur = ms.i}
    end
    return out
  end

  -- Peer: one "mq" page; true once a whole version arrived (the mirror is swapped), false while pages are missing,
  -- nil for a bad or stale page.
  function MUSIC.acceptPage(m)
    local v, page, pages = m.mv, m.page, m.pages
    if math.type(v) ~= "integer" or math.type(page) ~= "integer" or math.type(pages) ~= "integer" then return nil end
    if pages < 1 or pages > MAX_PAGES or page < 1 or page > pages or type(m.items) ~= "table" then return nil end
    if v == mv and not partial then return nil end
    if not partial or partial.mv ~= v or partial.pages ~= pages then
      partial = {mv = v, pages = pages, got = {}, n = 0}
    end
    if not partial.got[page] then
      local list = {}
      for _, w in ipairs(m.items) do
        local it = MUSIC.checkWire(w)
        if it then list[#list + 1] = it end
        if #list >= MAX_ITEMS then break end
      end
      partial.got[page], partial.n = list, partial.n + 1
    end
    if partial.n < pages then return false end
    local new, seen = {}, {}
    for p = 1, pages do
      for _, it in ipairs(partial.got[p]) do
        if #new < MAX_ITEMS and not seen[it.id] then
          seen[it.id] = true
          new[#new + 1] = it
        end
      end
    end
    items, mv, partial = new, v, nil
    changed()
    return true
  end

  ---------------------------------------------------------------- state messages

  local function msMsg(st) return {t = "ms", e = st.e, i = st.i, s = st.s, p = st.p, a = st.a} end

  local STATES = {play = true, pause = true, stop = true}
  function MUSIC.checkMs(m)
    if type(m) ~= "table" then return nil end
    local e, i, p, a = m.e, m.i, U.num(m.p), U.num(m.a)
    if math.type(e) ~= "integer" or e < 0 or math.type(i) ~= "integer" or i < 0 then return nil end
    if not STATES[m.s] or not p or p < 0 or p > 86400000 or not a then return nil end
    return {e = e, i = i, s = m.s, p = p, a = a}
  end

  local function newer(a, b)
    if not b then return true end
    if a.e ~= b.e then return a.e > b.e end
    return a.a >= b.a
  end

  local function sendQueue(id)
    if id then NET.drop(id, "^mq%d") else for _, p in ipairs(NET.peers()) do NET.drop(p, "^mq%d") end end
    for _, page in ipairs(MUSIC.pages()) do
      if id then NET.post(id, page, "mq" .. page.page) else NET.postAll(page, "mq" .. page.page) end
    end
  end

  local function sendAll(id)
    sendQueue(id)
    NET.post(id, msMsg(ms), "ms")
  end

  ---------------------------------------------------------------- the follower (every machine, the host too)

  local function listenPref() return U.pref("musicListen", CFG.get("musicFollow")) ~= false end

  function MUSIC.listening() return listenPref() end
  function MUSIC.detached() return detached end
  function MUSIC.notPremium() return notPremium end
  function MUSIC.lastError() return lastError end
  function MUSIC.playback() return lastPb end
  function MUSIC.owned() return owned end

  local function following()
    return SPOT.premium() and not notPremium and listenPref() and not detached and MUSIC.current() ~= nil
  end
  MUSIC.following = following

  -- True while this machine follows and its device plays the party's track (the game music then stays silent).
  function MUSIC.audible()
    if owned == nil or ms.s ~= "play" or not following() then return false end
    if lastPb and lastPb.at >= owned.at and lastPb.playing ~= true then return false end
    return true
  end

  -- Sends the pause of wantPause; a passing failure (Holo's request cap full, rate, network...) is sent again from
  -- the tick, so Stop, Mute and leaving never leave the music playing.
  local function sendPause()
    local w = wantPause
    if not w then return end
    w.next = math.huge                                           -- waiting for the answer
    local rid, why = SPOT.pause(function(res)
      if wantPause ~= w then return end
      if res.error and PASSING[res.error] then
        w.next = U.now() + (res.error == "rate" and (U.num(res.retryAfter) or 5) * 1000 or PAUSE_RETRY)
      else
        wantPause = nil
      end
    end)
    if not rid then
      if PASSING[why] then w.next = U.now() + PAUSE_RETRY else wantPause = nil end
    end
  end

  local function pauseOwned()
    if owned and owned.playing then
      owned.playing = false
      local now = U.now()
      lastAction = now
      wantPause = {since = now, next = now}
      sendPause()
    end
  end

  -- Stops following on this machine: pauses what Holo started, forgets it.
  local function release()
    pauseOwned()
    owned, issued = nil, nil
  end

  local function playNow(it)
    local target = MUSIC.pos(ms, hostOffset()) + SPOT.latency()
    if target >= it.durationMs - END_SLACK then return end      -- it is about to end: the next state plays the next
    local e, uri, now = ms.e, it.uri, U.now()
    issued = {e = e, uri = uri}
    owned = {uri = uri, e = e, at = now, playing = true}
    wantPause = nil                                               -- playing again: an older pause is moot
    lastSeek, lastAction = now, now
    local rid, why = SPOT.playTrack(uri, math.max(0, math.floor(target)), function(res)
      if not res.error then
        lastError = nil
        if playTry and playTry.e == e then playTry = nil end
        changed()
        return
      end
      if owned and owned.e == e and owned.uri == uri then owned = nil end
      if res.error == "premium" then
        notPremium = true
      elseif res.error == "rate" then
        backoffUntil = U.now() + (U.num(res.retryAfter) or 5) * 1000
      end
      -- a passing failure plays the same song again a little later (a few times), not only at the next song
      if PASSING[res.error] and issued and issued.e == e and issued.uri == uri then
        local n = (playTry and playTry.e == e and playTry.uri == uri) and playTry.n + 1 or 1
        if n <= PLAY_TRIES then
          local wait = res.error == "rate" and (U.num(res.retryAfter) or 5) * 1000 or 2000 * n
          playTry = {e = e, uri = uri, n = n, at = U.now() + wait}
          issued = nil
        end
      end
      lastError = res.error
      changed()
    end)
    if not rid then
      owned = nil
      lastError = why
      if why == "busy" then issued = nil end                     -- try again next frame
    end
  end

  -- React to the state: a new epoch plays, pauses or stops this machine's device.
  local function onState()
    if not following() then return end
    local it = MUSIC.current()
    if ms.s == "play" and it then
      if issued and issued.e == ms.e and issued.uri == it.uri then return end   -- this epoch: drift only
      if playTry and playTry.e == ms.e and playTry.uri == it.uri and U.now() < playTry.at then return end
      playNow(it)
    elseif ms.s == "pause" then
      issued = {e = ms.e}
      pauseOwned()
    else
      issued = {e = ms.e}
      release()
    end
  end

  local function setDetached()
    detached = true
    owned, issued = nil, nil
    changed()
    U.emit("music.detached")
  end

  -- Clears "detached" and plays along again (the "Follow again" action, or Listen pressed).
  function MUSIC.followAgain()
    detached, issued, lastError = false, nil, nil
    onState()
    changed()
  end

  -- Listen / Mute here: this machine plays the party's music on its Spotify, or not (off pauses what Holo started).
  function MUSIC.setListen(on)
    on = on == true
    U.setPref("musicListen", on)
    if on then
      MUSIC.followAgain()
    else
      release()
      changed()
    end
  end

  local function onPlayback(res)
    polling = false
    if res.error then
      if res.error == "rate" then backoffUntil = U.now() + (U.num(res.retryAfter) or 5) * 1000 end
      return
    end
    local at = U.num(res.at) or U.now()
    lastPb = {active = res.active == true, playing = res.playing == true, uri = res.uri, at = at,
      positionMs = U.num(res.positionMs) or 0,
      device = type(res.device) == "table" and {name = U.trim(res.device.name, 40)} or nil}
    if not following() or not owned or ms.s ~= "play" then return end
    if lastPb.at < owned.at then return end
    local now = U.now()
    if not lastPb.active then
      -- the device went away: show the device hint; the next epoch (or Listen) tries again
      owned, lastError = nil, "no-device"
      changed()
      return
    end
    local want = MUSIC.pos(ms, hostOffset())
    local it = MUSIC.current()
    -- around the end of a song the device stops (or moves on) before the host's next state arrives: not the user
    if not it or want >= it.durationMs - 5000 then return end
    if lastPb.uri ~= owned.uri or not lastPb.playing then
      if now - lastAction > OVERRIDE_GRACE then setDetached() end
      return
    end
    lastError = nil
    local drift = (lastPb.positionMs + (now - lastPb.at)) - want
    if math.abs(drift) > DRIFT_MAX and now - lastSeek > SEEK_HOLD then
      lastSeek, lastAction = now, now
      SPOT.seek(math.floor(want + SPOT.latency()))
    end
  end

  local function followTick(now)
    local f = following()
    if f ~= wasFollow then
      wasFollow = f
      if f then onState() end
    end
    if not f then return end
    if ms.s == "play" and issued == nil then onState() end
    if polling and now - lastPoll > 20000 then polling = false end   -- an answer that never came
    if polling or now < backoffUntil or ms.s == "stop" then return end
    local every = ms.s == "play" and POLL_PLAY or POLL_PAUSE
    if now - lastPoll < every then return end
    lastPoll = now
    if SPOT.playback(onPlayback) then polling = true end
  end

  ---------------------------------------------------------------- host: state changes

  local function setMs(s, i, p)
    epoch = math.max(epoch, ms.e) + 1
    local now = U.now()
    if i ~= ms.i then detached = false end
    ms = {e = epoch, i = i or 0, s = s, p = math.max(0, math.floor(p or 0)), a = now}
    lastBeat = now
    if NET.inSession() then NET.postAll(msMsg(ms), "ms") end
    onState()
    changed()
  end

  local function hostOnly()
    if not NET.isHost() then return nil, "not-host" end
    return true
  end

  local function vidNow() return PARTY.role() ~= "none" and PARTY.phase() == "playing" end

  -- Host: appends checked items {uri, title, artists, durationMs, by?, byId?}; returns how many and a reason for
  -- the ones left out ("full", "member-full", "dup").
  local function append(list, by, byId)
    local c, why = 0, nil
    for _, x in ipairs(list) do
      if #items >= MAX_ITEMS then
        why = "full"
        break
      end
      if byId and countBy(byId) >= MEMBER_MAX then
        why = "member-full"
        break
      end
      if hasUri(x.uri) then
        why = why or "dup"
      else
        items[#items + 1] = {id = nextId, uri = x.uri, title = x.title, artists = x.artists,
          durationMs = x.durationMs, by = by, byId = byId}
        nextId = nextId + 1
        c = c + 1
      end
    end
    if c > 0 then queueChanged() end
    return c, why
  end

  -- A library song {uri, name, artists, durationMs} as an item, or nil.
  local function fromLibrary(x)
    if type(x) ~= "table" then return nil end
    local d = U.num(x.durationMs)
    return MUSIC.checkItem(x.uri, x.name or x.title, x.artists, d and math.tointeger(math.floor(d)))
  end

  -- Host: adds library songs straight to the queue (no "by").
  function MUSIC.addLocal(list)
    local ok, why = hostOnly()
    if not ok then return nil, why end
    local clean = {}
    for _, x in ipairs(list) do clean[#clean + 1] = fromLibrary(x) end
    local c, w = append(clean)
    if c == 0 then return nil, w or "invalid" end
    return c, w
  end

  function MUSIC.playItem(id, posMs)
    local ok, why = hostOnly()
    if not ok then return nil, why end
    local it = MUSIC.find(id)
    if not it then return nil, "unknown" end
    autoPaused = false
    if vidNow() then override = PARTY.currentId() end
    setMs("play", it.id, U.clamp(U.num(posMs) or 0, 0, it.durationMs - 1000))
    return true
  end

  function MUSIC.toggle()
    local ok, why = hostOnly()
    if not ok then return nil, why end
    if ms.s == "play" then
      autoPaused = false
      setMs("pause", ms.i, MUSIC.position())
    elseif ms.s == "pause" and MUSIC.current() then
      autoPaused = false
      if vidNow() then override = PARTY.currentId() end
      setMs("play", ms.i, ms.p)
    else
      local it = MUSIC.current() or items[1]
      if not it then return nil, "empty" end
      return MUSIC.playItem(it.id, 0)
    end
    return true
  end

  function MUSIC.stop()
    local ok, why = hostOnly()
    if not ok then return nil, why end
    autoPaused = false
    setMs("stop", ms.i, 0)
    return true
  end

  function MUSIC.next()
    local ok, why = hostOnly()
    if not ok then return nil, why end
    local i = MUSIC.indexOf(ms.i)
    local nxt = i and items[i + 1] or (not i and items[1]) or nil
    if not nxt then
      autoPaused = false
      setMs("stop", ms.i, 0)
      toast("The music queue finished")
      return true
    end
    return MUSIC.playItem(nxt.id, 0)
  end

  function MUSIC.prev()
    local ok, why = hostOnly()
    if not ok then return nil, why end
    local i = MUSIC.indexOf(ms.i)
    if not i then return MUSIC.toggle() end
    if MUSIC.position() > 3000 or i == 1 then
      if ms.s == "stop" then return MUSIC.playItem(ms.i, 0) end
      setMs(ms.s, ms.i, 0)
      return true
    end
    return MUSIC.playItem(items[i - 1].id, 0)
  end

  function MUSIC.seek(posMs)
    local ok, why = hostOnly()
    if not ok then return nil, why end
    local it = MUSIC.current()
    posMs = U.num(posMs)
    if not it or ms.s == "stop" or not posMs then return nil, "seek" end
    setMs(ms.s, ms.i, U.clamp(posMs, 0, it.durationMs - 1000))
    return true
  end

  local function removeAt(i)
    local it = table.remove(items, i)
    queueChanged()
    if it.id == ms.i then
      local nxt = items[i]
      if nxt and ms.s ~= "stop" then
        setMs(ms.s == "pause" and "pause" or "play", nxt.id, 0)
      else
        setMs("stop", 0, 0)
      end
    end
    return true
  end

  function MUSIC.remove(id)
    local ok, why = hostOnly()
    if not ok then return nil, why end
    local i = MUSIC.indexOf(id)
    if not i then return nil, "unknown" end
    return removeAt(i)
  end

  function MUSIC.move(id, delta)
    local ok, why = hostOnly()
    if not ok then return nil, why end
    local i = MUSIC.indexOf(id)
    if not i then return nil, "unknown" end
    local j = U.clamp(i + delta, 1, #items)
    if j == i then return false end
    table.insert(items, j, table.remove(items, i))
    queueChanged()
    return true
  end

  function MUSIC.clear()
    local ok, why = hostOnly()
    if not ok then return nil, why end
    if #items == 0 then return true end
    items = {}
    queueChanged()
    if ms.s ~= "stop" or ms.i ~= 0 then setMs("stop", 0, 0) end
    return true
  end

  ---------------------------------------------------------------- members add and remove

  -- True if this machine may add songs now: it hosts the lane, or the lobby owner's Holo 1.1 accepts music adds.
  function MUSIC.canAdd()
    if NET.isHost() then return true end
    local caps = PARTY.hostCaps()
    return caps ~= nil and caps.music == true and caps.madd == true and NET.reachable(NET.hostId())
  end

  -- Why a member cannot add: "no-host" | "old-host" | "host-only" | nil.
  function MUSIC.addWhyNot()
    if MUSIC.canAdd() then return nil end
    if not NET.inSession() then return nil end
    if not NET.reachable(NET.hostId()) then return "no-host" end
    local caps = PARTY.hostCaps()
    if not caps then return PARTY.hostAcked() and "old-host" or "no-host" end
    if caps.music ~= true then return "old-host" end
    if caps.madd ~= true then return "host-only" end
    return "no-host"
  end

  -- True if the lobby owner runs a Holo without the music lane.
  function MUSIC.oldHost() return MUSIC.addWhyNot() == "old-host" end

  -- Adds library songs {uri, name, artists, durationMs}: straight to the queue on the host, else sent to the host in
  -- chunks of 20 (the answers come as "music.addResult"). Returns a count (host) or "sent", or nil and a reason.
  function MUSIC.add(list)
    if type(list) ~= "table" or #list == 0 then return nil, "invalid" end
    if NET.isHost() then return MUSIC.addLocal(list) end
    if not MUSIC.canAdd() then return nil, MUSIC.addWhyNot() or "no-host" end
    local now = U.now()
    if now - lastAdd < ADD_EVERY then return nil, "rate" end
    local wire = {}
    for _, x in ipairs(list) do
      local it = fromLibrary(x)
      if it then wire[#wire + 1] = {u = it.uri, ti = it.title, ar = it.artists, d = it.durationMs} end
    end
    if #wire == 0 then return nil, "invalid" end
    lastAdd = now
    for i = 1, #wire, ADD_CHUNK do
      local chunk = {}
      for j = i, math.min(#wire, i + ADD_CHUNK - 1) do chunk[#chunk + 1] = wire[j] end
      chunks[#chunks + 1] = chunk
    end
    return true, "sent"
  end

  -- Member: asks the host to remove a song this machine added.
  function MUSIC.requestRemove(id)
    if NET.isHost() then return MUSIC.remove(id) end
    local it = MUSIC.find(id)
    if not it or it.byId == nil or it.byId ~= NET.me() then return nil, "not-yours" end
    if not MUSIC.canAdd() then return nil, MUSIC.addWhyNot() or "no-host" end
    NET.post(NET.hostId(), {t = "mrm", id = id})
    return true
  end

  local function member(id)
    local m = members[id]
    if not m then
      m = {addAt = -1e9, rmAt = -1e9, needAt = -1e9, toastAt = -1e9}
      members[id] = m
    end
    return m
  end

  local function fromMember(from, m)
    local t = m.t
    local now = U.now()
    if t == "madd" then
      local n = m.n
      if math.type(n) ~= "integer" or n < 1 or n > 2147483647 then return end
      local function reply(ok, why, c) NET.post(from, {t = "maddr", n = n, ok = ok, why = why, c = c}) end
      local mi = member(from)
      if CFG.get("whoAdds") ~= "anyone" then return reply(false, "host-only") end
      if now - mi.addAt < MADD_ACCEPT then return reply(false, "rate") end
      mi.addAt = now
      if type(m.items) ~= "table" or #m.items < 1 then return reply(false, "invalid") end
      if #m.items > ADD_CHUNK then return reply(false, "too-many") end
      local clean, bad = {}, 0
      for k = 1, #m.items do
        local w = m.items[k]
        local it = type(w) == "table" and MUSIC.checkItem(w.u, w.ti, w.ar, w.d) or nil
        if it then clean[#clean + 1] = it else bad = bad + 1 end
      end
      if #clean == 0 then return reply(false, "invalid") end
      local name = U.trim(NET.name(from), BY)
      local c, why = append(clean, name, from)
      if c == 0 and not why and bad > 0 then why = "invalid" end
      reply(c > 0, why, c)
      if c > 0 and now - mi.toastAt >= ADD_TOAST_EVERY then
        mi.toastAt = now
        toast(name .. " added " .. (c > 1 and (c .. " songs") or U.trim(clean[1].title, 60)))
      end
    elseif t == "mrm" then
      local mi = member(from)
      if math.type(m.id) ~= "integer" or now - mi.rmAt < MRM_ACCEPT then return end
      mi.rmAt = now
      local i = MUSIC.indexOf(m.id)
      if i and items[i].byId == from then removeAt(i) end
    elseif t == "mneed" then
      local mi = member(from)
      if now - mi.needAt < MNEED_ACCEPT then return end
      mi.needAt = now
      sendAll(from)
    end
  end

  local function needQueue()
    if ms.i == 0 or MUSIC.find(ms.i) then return end
    local now = U.now()
    if now - lastNeed < NEED_EVERY then return end
    lastNeed = now
    NET.post(NET.hostId(), {t = "mneed", mv = mv})
  end

  local function fromHost(from, m)
    local t = m.t
    if t == "mq" then
      if MUSIC.acceptPage(m) then
        onState()
        needQueue()
      end
    elseif t == "ms" then
      local st = MUSIC.checkMs(m)
      if not st or not newer(st, ms) then return end
      local newItem = st.i ~= ms.i
      ms = st
      if newItem and st.e > 0 then detached = false end
      needQueue()
      onState()
      changed()
    elseif t == "maddr" then
      local p = pendingAdds[m.n]
      if not p then return end
      pendingAdds[m.n] = nil
      U.emit("music.addResult", m.ok == true, type(m.why) == "string" and U.trim(m.why, 24) or nil,
        math.type(m.c) == "integer" and m.c or nil)
    end
  end

  U.on("net.msg", function(from, m)
    if from == NET.hostId() and not NET.isHost() then
      fromHost(from, m)
    elseif NET.isHost() and NET.inSession() then
      fromMember(from, m)
    end
  end)

  -- A member said hi (Holo 1.1 sends the caps then): it gets the music queue and state if there is any.
  local function greet(id)
    if not (NET.isHost() and NET.inSession()) then return end
    if #items > 0 or ms.s ~= "stop" then sendAll(id) end
  end
  U.on("party.memberHi", greet)
  U.on("net.peer", function(id, up)
    if up and NET.isHost() then greet(id) end
  end)

  ---------------------------------------------------------------- lobby lifecycle

  local wasHost = NET.isHost()       -- whether this machine hosted the lane before the last lobby event

  -- Forgets the mirror (a member) or everything (keep = false). mv = -1 so the next host's pages are taken whatever
  -- their number.
  local function resetMirror()
    items, partial, mv = {}, nil, -1
    ms = {e = 0, i = 0, s = "stop", p = 0, a = U.now()}
    pendingAdds, chunks, members = {}, {}, {}
    lastPb, polling, autoPaused, override = nil, false, false, nil
    detached = false
  end

  -- This machine left the lobby: what Holo started on its device pauses. A host keeps its songs, stopped.
  U.on("net.leave", function()
    release()
    if wasHost then
      if ms.s ~= "stop" then setMs("stop", ms.i, 0) end
      members, chunks, pendingAdds = {}, {}, {}
    else
      resetMirror()
    end
    wasHost = true
    changed()
  end)

  U.on("net.owner", function(owner, isHost)
    if owned then
      release()
      toast("The host left; the party music stopped", "warn")
    end
    owned, issued = nil, nil
    local old, e = items, ms.e
    resetMirror()
    if isHost then
      -- the new owner adopts the songs (new ids, attribution kept), stopped; it does not play them by itself
      for _, it in ipairs(old) do
        items[#items + 1] = {id = nextId, uri = it.uri, title = it.title, artists = it.artists,
          durationMs = it.durationMs, by = it.by, byId = it.byId}
        nextId = nextId + 1
      end
      epoch = math.max(epoch, e) + 1
      ms = {e = epoch, i = 0, s = "stop", p = 0, a = U.now()}
      mv = math.max(mv, 0) + 1
    end
    wasHost = isHost == true
    changed()
  end)

  U.on("net.enter", function()
    wasHost = NET.isHost()
    if wasHost then return end
    -- a solo lane ends when this machine joins someone else's lobby
    local had = #items > 0 or ms.s ~= "stop"
    release()
    resetMirror()
    if had then toast("Your party music ended: you joined a lobby") end
    changed()
  end)

  -- The "Play the party's music on my Spotify" setting: it replaces what Listen / Mute here remembered, and acts now.
  U.on("cfg.changed", function(key, v)
    if key ~= "musicFollow" then return end
    U.setPref("musicListen", nil)
    if v == false then
      release()
      changed()
    else
      MUSIC.followAgain()
    end
  end)

  U.on("spot.status", function()
    if not SPOT.connected() then notPremium = false end
    changed()
  end)

  ---------------------------------------------------------------- tick

  local function hostTick(now)
    local it = MUSIC.current()
    -- (a) the song ended: the next one
    if ms.s == "play" and it and MUSIC.pos(ms, 0) >= it.durationMs - END_SLACK then
      MUSIC.next()
    elseif ms.s ~= "stop" and ms.i ~= 0 and not it then
      setMs("stop", 0, 0)
    end
    if NET.inSession() then
      -- (b) heartbeat
      if ms.s == "play" and now - lastBeat >= HEARTBEAT then
        lastBeat = now
        local m = msMsg(ms)
        for _, id in ipairs(NET.peers()) do NET.send(id, m, {reliable = false}) end
      end
      -- (c) the queue, debounced
      if dirtyAt and now - dirtyAt >= MQ_DEBOUNCE then
        dirtyAt = nil
        sendQueue()
      end
    else
      dirtyAt = nil
    end
    -- (d) a party video plays: pause the music (setting), resume once the video stops
    local ph = PARTY.role() ~= "none" and PARTY.phase() or "idle"
    local vid = ph == "playing" or ph == "buffering" or (vidWas and ph == "loading")
    vidWas = vid
    if CFG.get("musicDuringVideo") ~= "pause" then
      autoPaused = false
      return
    end
    if vid then
      vidOffAt = nil
      if ms.s == "play" and override ~= PARTY.currentId() then
        setMs("pause", ms.i, MUSIC.position())
        autoPaused = true
      end
    elseif autoPaused then
      vidOffAt = vidOffAt or now
      if ms.s ~= "pause" then
        autoPaused = false
      elseif now - vidOffAt >= RESUME_AFTER then
        autoPaused, vidOffAt = false, nil
        setMs("play", ms.i, ms.p)
      end
    end
  end

  local function peerTick(now)
    local host = NET.hostId()
    if chunks[1] and now - lastChunk >= CHUNK_EVERY then
      lastChunk = now
      local n = nextAddN
      nextAddN = nextAddN + 1
      pendingAdds[n] = {at = now}
      NET.post(host, {t = "madd", n = n, items = table.remove(chunks, 1)}, "madd" .. n)
    end
    for n, p in pairs(pendingAdds) do
      if now - p.at >= ADD_WAIT then
        pendingAdds[n] = nil
        U.emit("music.addResult", false, "no-answer")
      end
    end
  end

  function MUSIC.tick()
    local now = U.now()
    if wantPause then
      if now - wantPause.since > PAUSE_GIVEUP then
        wantPause = nil
      elseif now >= wantPause.next then
        sendPause()
      end
    end
    if NET.isHost() then
      hostTick(now)
    elseif NET.inSession() then
      peerTick(now)
    end
    followTick(now)
  end

  -- Test hook: the host's internal flags.
  function MUSIC.debug()
    return {autoPaused = autoPaused, override = override, epoch = epoch, issued = issued, playTry = playTry,
      wantPause = wantPause}
  end

  wum.timers.every(0, U.guard("music", MUSIC.tick))
end
