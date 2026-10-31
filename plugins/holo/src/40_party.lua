-- party (P2): role and phase, the host's authoritative state and the sync protocol of design 2.5 over NET.
-- Star topology: the party host is always the lobby owner; peers talk to the owner only and the owner fans out.
-- Bus events: "party.changed", "party.toast" (text, kind), "party.joinPrompt" (hostName, autoJoined),
-- "party.continuePrompt" (hostName), "party.memberHi" (id; host: a member said "hi"), "party.addResult" (ok, why,
-- count, title; peer: the host answered an add), "party.addSent" (title; peer: a pick went to the host).
-- Members add to the queue with "add" -> the host checks it (QUEUE.addFor) and answers "addr"; "cap" tells a member
-- what the host accepts, "rm" removes an item the member added. All are ignored by Holo 1.0.x.
do
  local PLAY_LEAD = 300              -- ms: play and resume are scheduled this far ahead so peers start together
  local HEARTBEAT = 1000             -- ms between unreliable "st" while playing
  local HI_EVERY = 10000             -- ms between "hi" until the host answers
  local HI_ACCEPT, NEED_ACCEPT = 2000, 5000   -- host: one "hi" per member per 2 s, one "need" per 5 s (N3)
  local OPEN_EVERY = 1500            -- peer: one item open per 1.5 s, coalesced to the latest item (N3)
  local NEED_EVERY = 3000            -- peer: how often it asks for a queue it is missing
  local SCRUB_HOLD = 2000            -- host: no heartbeat this long after a keyframes (scrub) seek, unless it ends
  local MUSIC_RETRY = 2000           -- ms between retries of a refused wum.audio.music.suppress
  local ADD_ACCEPT, RM_ACCEPT = 1500, 500   -- host: one "add" per member per 1.5 s, one "rm" per 0.5 s
  local ADD_EVERY = 1000             -- peer: one add request per second
  local ADD_WAIT = 45000             -- peer: how long it waits for the host's "addr" before giving up
  local SPEEDS = {0.5, 0.75, 1, 1.25, 1.5, 2}
  local QUALITIES = {[360] = true, [480] = true, [720] = true, [1080] = true}
  PARTY.SPEEDS = SPEEDS

  local role, phase, setupOpen = "none", "idle", false
  local player, pstate, openedId, openedUrl, loaded = nil, nil, nil, nil, false
  local hs = nil                     -- the host's state {e, i, s, p, r, a}; on a peer the last valid "st"
  local epoch = 0
  local pendingPlayAt, autoplay, ended, errorAt = nil, false, false, nil
  local lastBeat, queueDirtyAt = -1e9, nil
  local needsPack = false
  -- peer side
  local hostParty, declined, prompted, acked = false, false, false, false
  local lastHi, lastOpen, lastNeed, wantOpen = -1e9, -1e9, -1e9, nil
  local hostCaps = nil               -- the host's last "cap" {add, music, madd}; nil from a host without Holo 1.1
  local pendingAdds, nextAddN, lastAddAt = {}, 1, -1e9   -- n -> {at}: adds the host has not answered yet
  -- host side: what each member told us
  local info = {}                    -- id -> {hiAt, needAt, holo, buf, err, loaded}
  local resume, musicOn = nil, false
  local musicFailAt, musicWarned = nil, false
  local scrubAt = nil                -- host: the last keyframes seek; the scrub position stays local (design 2.5)
  local applied = {}                 -- the volume and mute last sent to the player

  ---------------------------------------------------------------- small reads

  function PARTY.role() return role end
  function PARTY.active() return role ~= "none" end
  function PARTY.player() return player end
  function PARTY.state() return pstate end
  function PARTY.hostState() return hs end
  function PARTY.currentUrl() return openedUrl end
  function PARTY.currentId() return openedId end
  function PARTY.canContinue() return resume ~= nil and role == "none" and NET.isHost() end
  -- A party the lobby owner runs that this machine has not joined (or declined).
  function PARTY.partyRunning()
    if role ~= "none" or NET.isHost() then return false end
    if hostParty then return true end
    local pr = NET.presence(NET.hostId())
    return pr ~= nil and pr.party == true
  end
  function PARTY.declined() return declined end

  -- The host controls the party; before a party, the lobby owner (or anyone without a lobby) sets it up.
  function PARTY.canControl()
    if role == "host" then return true end
    return role == "none" and NET.isHost()
  end

  function PARTY.hostCaps() return hostCaps end
  -- True once the lobby owner's Holo answered this machine's "hi" (any version).
  function PARTY.hostAcked() return acked end

  -- True if this machine may add to the video queue now: it controls the party, or the lobby owner runs a 1.1 party
  -- that accepts adds.
  function PARTY.canAdd()
    if PARTY.canControl() then return true end
    if not NET.inSession() or NET.isHost() then return false end
    return hostCaps ~= nil and hostCaps.add == true and (role == "peer" or PARTY.partyRunning())
  end

  -- Why a member cannot add: "not-running" | "old-host" | "host-only" | "no-host" | nil (it can, or no lobby).
  function PARTY.addWhyNot()
    if PARTY.canAdd() then return nil end
    if not NET.inSession() then return nil end
    if not (PARTY.partyRunning() or role == "peer") then return "not-running" end
    if not NET.reachable(NET.hostId()) then return "no-host" end
    if acked and not hostCaps then return "old-host" end
    if hostCaps and hostCaps.add == false then return "host-only" end
    return "no-host"
  end

  function PARTY.hostName()
    if not NET.inSession() or NET.isHost() then return "you" end
    return NET.name(NET.hostId())
  end

  local function toast(text, kind) U.emit("party.toast", text, kind or "info") end

  local function inSession() return NET.inSession() end

  ---------------------------------------------------------------- music, audio prefs

  local function applyMusic()
    local music = wum.audio and wum.audio.music
    if not music then return end
    -- Game music stays silent for a party and while the music lane (MUSIC, Part B) is audible. Always a boolean.
    local want = (role ~= "none" or (MUSIC ~= nil and MUSIC.audible ~= nil and MUSIC.audible() == true))
      and CFG.get("musicOff") == true
    if want == musicOn then return end
    -- A refused request ("unavailable" before the audio hook is in, "disabled") is retried from the tick.
    local now = U.now()
    if musicFailAt and now - musicFailAt < MUSIC_RETRY then return end
    local ok, res, why = pcall(music.suppress, want, {fade = 0.4})
    if ok and res then
      musicOn, musicFailAt = want, nil
      return
    end
    musicFailAt = now
    if want and ok and why == "disabled" and not musicWarned then
      musicWarned = true
      toast("The game music stays on: AllowMusicSuppress is off in Melange.ini")
    end
  end

  local function volume() return math.floor(U.clamp(U.num(U.pref("volume", CFG.get("volume"))) or 70, 0, 100)) end
  local function userMute() return U.pref("mute", false) == true end
  local function quality()
    local q = math.tointeger(U.pref("quality")) or math.tointeger(tonumber(CFG.get("quality"))) or 720
    return QUALITIES[q] and q or 720
  end
  local function lang(key)
    local l = U.pref(key)
    if type(l) == "string" and (l:match("^%l%l%l?$") or l:match("^%l%l%l?%-%w%w%w?%w?%w?%w?%w?%w?$")) then return l end
  end

  local function effectiveMute()
    if userMute() then return true end
    return CFG.get("hiddenMutes") == true and LAYOUT.view and LAYOUT.view() == "hidden"
  end

  local function applyAudio()
    if not player then return end
    local v, m = volume(), effectiveMute()
    if applied.v ~= v then applied.v = v; player:volume(v) end
    if applied.m ~= m then applied.m = m; player:mute(m) end
  end

  function PARTY.volume() return volume() end
  function PARTY.muted() return userMute() end
  function PARTY.quality() return quality() end

  function PARTY.setVolume(v)
    v = U.num(v)
    if not v then return nil, "volume" end
    U.setPref("volume", math.floor(U.clamp(v, 0, 100) + 0.5))
    applyAudio()
    return true
  end

  function PARTY.setMute(b)
    U.setPref("mute", b == true)
    applyAudio()
    return true
  end

  function PARTY.setQuality(h)
    h = math.tointeger(h) or math.tointeger(tonumber(h))
    if not QUALITIES[h] then return nil, "quality" end
    U.setPref("quality", h)
    if player then player:quality(h) end
    return true
  end

  -- Subtitles and audio are per player and not synced; the choice is remembered by language.
  function PARTY.setTrack(kind, id)
    if kind ~= "audio" and kind ~= "sub" then return nil, "kind" end
    if not player then return nil, "no-player" end
    local ok, why = player:track(kind, id)
    if not ok then return nil, why end
    local key = kind == "audio" and "audioLang" or "subLang"
    if id == false then
      U.setPref(key, false)
    else
      for _, t in ipairs(pstate and pstate.tracks and pstate.tracks[kind] or {}) do
        if t.id == id and type(t.lang) == "string" then U.setPref(key, t.lang) end
      end
    end
    return true
  end

  ---------------------------------------------------------------- the player

  -- Closes the player. openedId/openedUrl stay: they name the item this machine is on, playing or not.
  local function closePlayer()
    if player then pcall(player.close, player) end
    player, pstate, loaded = nil, nil, false
    applied = {}
  end

  -- Opens a queue item paused at `start`. Returns the player, or nil and a reason ("wait" while a torrent's file
  -- list is still coming).
  local function openItem(it, start, paused)
    closePlayer()
    local o = {start = start or 0, paused = paused ~= false, volume = volume(), mute = effectiveMute(),
      quality = quality(), speed = hs and hs.r or 1, audioLang = lang("audioLang"), subLang = lang("subLang")}
    if it.kind == "bt" then
      local e, why = QUEUE.torrentFor(it.url)
      if not e then return nil, why end
      if e.error then return nil, "torrent" end
      if not e.files then return nil, "wait" end
      o.torrent, o.file = e.t, it.file
    else
      o.url = it.url
    end
    local p, why = wum.media.open(o)
    if not p then return nil, why end
    player, openedId, openedUrl, loaded = p, it.id, it.url, false
    applied = {v = o.volume, m = o.mute}
    if it.kind == "bt" then QUEUE.keepTorrents(it.url) end
    if LAYOUT.sizeHint then
      local w, h = LAYOUT.sizeHint()
      if w then p:size(w, h) end
    end
    return p
  end

  local function curPos()
    if player then
      local ok, st = pcall(player.state, player)
      if ok and st and U.num(st.time) then return st.time end
    end
    if hs then
      local p = hs.p
      if hs.s == "play" then p = p + math.max(0, U.now() - hs.a) / 1000 * hs.r end
      return p
    end
    return 0
  end
  PARTY.position = curPos

  ---------------------------------------------------------------- host: state and fan-out

  local function stMsg(h) return {t = "st", e = h.e, i = h.i, s = h.s, p = h.p, r = h.r, a = h.a} end

  local function broadcastState(reliable)
    if role ~= "host" or not hs or not inSession() then return end
    local m = stMsg(hs)
    if reliable == false then
      for _, id in ipairs(NET.peers()) do NET.send(id, m, {reliable = false}) end
    else
      NET.postAll(m, "st")
    end
  end

  local function setState(s, p, a)
    epoch = epoch + 1
    hs = {e = epoch, i = openedId or (hs and hs.i) or 0, s = s, p = math.max(0, p), r = hs and hs.r or 1,
      a = a or U.now()}
    broadcastState(true)
  end

  local function presence()
    if role == "host" then
      local it = QUEUE.current()
      NET.setPresence{party = true, title = it and it.title or "", n = QUEUE.count()}
    else
      NET.setPresence{party = false, title = nil, n = nil}
    end
  end

  -- What the host tells members it accepts: video adds (a running party with whoAdds "anyone"), the music lane, and
  -- music adds (whoAdds "anyone", with or without a video party).
  local function capMsg()
    local anyone = CFG.get("whoAdds") == "anyone"
    return {t = "cap", add = role == "host" and anyone, music = true, madd = anyone}
  end

  local function broadcastCaps()
    if inSession() and NET.isHost() then NET.postAll(capMsg(), "cap") end
  end

  local function sendQueue(id)
    if id then NET.drop(id, "^q%d") else for _, p in ipairs(NET.peers()) do NET.drop(p, "^q%d") end end
    for _, page in ipairs(QUEUE.pages()) do
      if id then NET.post(id, page, "q" .. page.page) else NET.postAll(page, "q" .. page.page) end
    end
  end

  local function sendTorrentInfo(id)
    local it = QUEUE.current()
    if not (it and it.kind == "bt") then return end
    local c = wum.media.classify(it.url)
    local m = {t = "bt", id = it.id, ih = c and c.infohash, f = it.file}
    if id then NET.post(id, m) else NET.postAll(m) end
  end

  local function schedulePlay(pos)
    pendingPlayAt = U.now() + PLAY_LEAD
    setState("play", pos, pendingPlayAt)
  end

  local playItem

  -- The host's next item after the current one ended or failed; past the end the party waits ("ended-item").
  local function advance()
    local nxt = QUEUE.step(1)
    if nxt then
      playItem(nxt, 0)
    else
      ended = true
      pendingPlayAt = nil
      setState("pause", curPos())
    end
  end

  function playItem(it, start)
    ended, errorAt, pendingPlayAt = false, nil, nil
    QUEUE.setCurrent(it.id)
    hs = hs or {r = 1}
    local p, why = openItem(it, start, true)
    openedId, openedUrl = it.id, it.url
    hs.i = it.id
    autoplay = true
    if not p then
      if why == "wait" then
        wantOpen = it.id                -- the torrent's file list is still coming; the tick retries
      else
        toast(why == "cache-cap" and "This file is larger than the video cache" or "Can't play this item", "error")
        errorAt = U.now()
      end
    end
    setState("pause", start or 0)
    presence()
  end

  local function startAt(it, start)
    if not it then return nil, "empty" end
    local pk = wum.media.pack()
    if not (pk and pk.state == "ready") then return nil, "pack" end
    role, resume, declined = "host", nil, false
    epoch = epoch + 1
    hs = {r = 1}
    info = {}
    applyMusic()
    if inSession() then
      NET.postAll({t = "ack", party = true, qv = QUEUE.version()}, "ack")
      broadcastCaps()
      sendQueue()
    end
    playItem(it, start or 0)
    U.emit("party.changed")
    return true
  end

  -- Starts the party from the queue's current item (or its first). The lobby owner only; needs the pack.
  function PARTY.start()
    if role ~= "none" then return nil, "active" end
    if not NET.isHost() then return nil, "not-host" end
    if QUEUE.count() == 0 then return nil, "empty" end
    return startAt(QUEUE.current() or QUEUE.items()[1], 0)
  end

  local function endLocal()
    local wasHost = role == "host"
    closePlayer()
    openedId, openedUrl = nil, nil
    QUEUE.closeAllTorrents()
    role, hs, ended, needsPack, pendingPlayAt, autoplay, wantOpen, errorAt = "none", nil, false, false, nil, false,
      nil, nil
    if wasHost then broadcastCaps() end          -- add = false now
    applyMusic()
    presence()
    U.emit("party.changed")
  end

  -- Host: ends the party for everyone. Peer: leaves it (like declining).
  function PARTY.stop()
    if role == "host" then
      if inSession() then NET.postAll({t = "end", why = "host"}) end
      endLocal()
      return true
    elseif role == "peer" then
      return PARTY.decline()
    end
    return false
  end

  local function hostOnly()
    if role ~= "host" then return nil, "not-host" end
    if not player and not ended then return nil, "no-player" end
    return true
  end

  function PARTY.togglePlay()
    local ok, why = hostOnly()
    if not ok then return nil, why end
    autoplay = false                    -- the host decided; a pending load no longer starts by itself
    if hs.s == "play" then
      local pos = curPos()
      pendingPlayAt = nil
      if player then player:pause() end
      setState("pause", pos)
    else
      local pos = curPos()
      if ended or (pstate and pstate.eof) then
        ended, pos = false, 0
        if player then player:seek(0, "exact") end
      end
      schedulePlay(pos)
    end
    U.emit("party.changed")
    return true
  end

  -- mode "keyframes" while scrubbing (local only), "exact" on release (sent to the peers).
  function PARTY.seek(t, mode)
    local ok, why = hostOnly()
    if not ok then return nil, why end
    t = U.num(t)
    if not t or not player then return nil, "seek" end
    local dur = pstate and U.num(pstate.duration)
    if dur and dur > 0 then t = math.min(t, dur) end
    t = math.max(0, t)
    if mode == "keyframes" then
      player:seek(t, "keyframes")
      scrubAt = U.now()
      return true
    end
    scrubAt = nil
    player:seek(t, "exact")
    ended = false
    if pendingPlayAt then
      schedulePlay(t)                   -- the play had not started yet: keep the lead
    elseif hs.s == "play" then
      setState("play", t)
    else
      setState("pause", t)
    end
    return true
  end

  function PARTY.skip(delta)
    local d = U.num(delta)
    if not d then return nil, "seek" end
    return PARTY.seek(curPos() + d, "exact")
  end

  function PARTY.next()
    if role ~= "host" then return nil, "not-host" end
    local nxt = QUEUE.step(1)
    if not nxt then return nil, "end" end
    playItem(nxt, 0)
    return true
  end

  function PARTY.prev()
    if role ~= "host" then return nil, "not-host" end
    if player and curPos() > 5 then return PARTY.seek(0, "exact") end
    local prv = QUEUE.step(-1)
    if not prv then return PARTY.seek(0, "exact") end
    playItem(prv, 0)
    return true
  end

  -- Snaps to the nearest synced speed (0.5 to 2).
  function PARTY.setSpeed(x)
    if role ~= "host" then return nil, "not-host" end
    x = U.num(x)
    if not x then return nil, "speed" end
    local best = 1
    for _, s in ipairs(SPEEDS) do
      if math.abs(s - x) < math.abs(best - x) then best = s end
    end
    if player then player:speed(best) end
    local pos = curPos()
    hs.r = best
    setState(hs.s, pos, pendingPlayAt)
    return true
  end

  ---------------------------------------------------------------- peer side

  local function sendHost(m)
    local host = NET.hostId()
    if not host then return false end
    NET.post(host, m)
    return true
  end

  -- Peer: asks the host to add a link. f = {u, f?, ti?}: u the canonical link, f the torrent file index, ti its title.
  -- Returns true, "sent" (the answer comes as "party.addResult"), or nil and "rate" | "no-host".
  function PARTY.requestAdd(f)
    local now = U.now()
    if now - lastAddAt < ADD_EVERY then return nil, "rate" end
    local host = NET.hostId()
    if not host or not NET.reachable(host) then return nil, "no-host" end
    local n = nextAddN
    nextAddN = nextAddN + 1
    pendingAdds[n] = {at = now}
    lastAddAt = now
    NET.post(host, {t = "add", n = n, u = f.u, f = f.f, ti = f.ti and U.trim(f.ti, 120)}, "add" .. n)
    return true, "sent"
  end

  -- Peer: asks the host to remove an item this machine added. true, or nil and a reason.
  function PARTY.requestRemove(id)
    local me = NET.me()
    local it = QUEUE.find(id)
    if not it or me == nil or it.byId ~= me then return nil, "not-yours" end
    local host = NET.hostId()
    if not host or not NET.reachable(host) then return nil, "no-host" end
    if not hostCaps then return nil, "old-host" end
    NET.post(host, {t = "rm", id = id})
    return true
  end

  local function packReady()
    local pk = wum.media.pack()
    return pk ~= nil and pk.state == "ready"
  end

  local function hostNow()
    local c = NET.clock(NET.hostId())
    return U.now() + (c and U.num(c.offset) or 0)
  end

  -- Applies the latest host state: open the item when it changed (paced), else follow.
  local function applySt()
    if role ~= "peer" or not hs then return end
    if needsPack then return end
    if hs.i ~= openedId then
      if QUEUE.find(hs.i) then
        wantOpen = hs.i
      elseif U.now() - lastNeed >= NEED_EVERY then
        lastNeed = U.now()
        sendHost{t = "need", qv = QUEUE.version()}
      end
      return
    end
    if player then player:follow(hs, NET.hostId()) end
  end

  local function openWanted()
    local it = QUEUE.find(wantOpen)
    if not it then
      wantOpen = nil
      return
    end
    local start = hs.p
    if hs.s == "play" then start = start + math.max(0, hostNow() - hs.a) / 1000 * hs.r end
    local p, why = openItem(it, math.max(0, start), hs.s ~= "play")
    if not p then
      if why == "wait" then return end   -- the torrent's file list is still coming
      wantOpen = nil
      if why == "pack" then
        needsPack = true                  -- opened again once the pack is ready
      else
        openedId, openedUrl = it.id, it.url -- this item failed here; do not retry it on every "st"
        toast(why == "first-use-in-match" and "Torrent items can start only in the menus or the lobby"
          or "Can't play this item here", "error")
        sendHost{t = "buf", b = false, i = it.id, p = 0, ok = false}
      end
      U.emit("party.changed")
      return
    end
    wantOpen = nil
    QUEUE.setCurrent(it.id)
    p:follow(hs, NET.hostId())
  end

  function PARTY.join()
    if role ~= "none" then return nil, "active" end
    if NET.isHost() or not PARTY.partyRunning() then return nil, "no-party" end
    role, declined = "peer", false
    U.setPref("autoJoin", true)
    needsPack = not packReady()
    applyMusic()
    if QUEUE.count() == 0 or not hs then
      lastNeed = U.now()
      sendHost{t = "need", qv = QUEUE.version()}
    end
    applySt()
    U.emit("party.changed")
    return true
  end

  -- "Not now": leaves the running party (or refuses the prompt) and remembers it; the next party prompts again.
  function PARTY.decline()
    declined = true
    U.setPref("autoJoin", false)
    if role == "peer" then endLocal() end
    U.emit("party.changed")
    return true
  end

  local function hostRunning()
    if hostParty then return end
    hostParty = true
    if role ~= "none" or declined or prompted then return end
    prompted = true
    if U.pref("autoJoin", true) ~= false then
      PARTY.join()
      U.emit("party.joinPrompt", PARTY.hostName(), true)
    else
      U.emit("party.joinPrompt", PARTY.hostName(), false)
    end
  end

  -- A new owner that had the queue continues where the old host stopped.
  function PARTY.continueParty()
    if not PARTY.canContinue() then return nil, "nothing" end
    local snap = resume
    local cur = QUEUE.load(snap.snap)
    local it = (cur and QUEUE.find(cur)) or QUEUE.items()[1]
    if not it then
      resume = nil
      return nil, "empty"
    end
    local r = snap.rate or 1
    local ok, why = startAt(it, it.id == cur and snap.time or 0)
    if ok and r ~= 1 then PARTY.setSpeed(r) end
    return ok, why
  end

  -- Loads the queue stored by the last party this machine hosted (only while idle).
  function PARTY.restoreLastQueue()
    if role ~= "none" or not PARTY.canControl() then return nil, "active" end
    local snap = U.pref("lastQueue")
    if type(snap) ~= "table" then return nil, "nothing" end
    QUEUE.load(snap)
    return true
  end

  ---------------------------------------------------------------- message validation

  -- A "st" from the host, checked: returns the clean state or nil.
  function PARTY.checkSt(m)
    if type(m) ~= "table" then return nil end
    local e, i, p, r, a = m.e, m.i, U.num(m.p), U.num(m.r), U.num(m.a)
    if math.type(e) ~= "integer" or e < 0 or math.type(i) ~= "integer" or i < 0 then return nil end
    if m.s ~= "play" and m.s ~= "pause" then return nil end
    if not p or p < 0 or p > 1e7 or not r or r < 0.25 or r > 4 or not a then return nil end
    return {e = e, i = i, s = m.s, p = p, r = r, a = a}
  end

  local function newer(a, b)
    if not b then return true end
    if a.e ~= b.e then return a.e > b.e end
    return a.a >= b.a
  end

  local function fromHost(from, m)
    local t = m.t
    if t == "ack" then
      acked = true
      if m.party == true then
        hostRunning()
      elseif hostParty or role == "peer" then
        hostParty = false
        if role == "peer" then endLocal() end
      end
    elseif t == "q" then
      local done = QUEUE.acceptPage(m)
      if done then
        hostRunning()
        applySt()
      end
    elseif t == "st" then
      local st = PARTY.checkSt(m)
      if not st or not newer(st, hs) then return end
      hs = st
      hostRunning()
      applySt()
    elseif t == "bt" then
      local it = QUEUE.find(m.id)
      local c = it and wum.media.classify(it.url)
      if c and c.infohash == m.ih then QUEUE.setFile(m.id, m.f) end
    elseif t == "cap" then
      hostCaps = {add = m.add == true, music = m.music == true, madd = m.madd == true}
      U.emit("party.changed")
    elseif t == "addr" then
      local p = pendingAdds[m.n]
      if not p then return end
      pendingAdds[m.n] = nil
      U.emit("party.addResult", m.ok == true, type(m.why) == "string" and U.trim(m.why, 24) or nil,
        math.type(m.c) == "integer" and m.c or nil, type(m.ti) == "string" and U.trim(m.ti, 60) or nil)
    elseif t == "end" then
      local was = role == "peer"
      hostParty, declined, prompted = false, false, false
      if was then
        endLocal()
        toast("The host ended the watch party")
      end
      U.emit("party.changed")
    end
  end

  local function fromMember(from, m)
    local t = m.t
    local now = U.now()
    local mi = info[from]
    if not mi then
      mi = {hiAt = -1e9, needAt = -1e9}
      info[from] = mi
    end
    if t == "hi" then
      if now - mi.hiAt < HI_ACCEPT then return end
      mi.hiAt = now
      mi.holo = U.trim(m.holo, 16)
      NET.post(from, {t = "ack", party = role == "host", qv = QUEUE.version()}, "ack")
      NET.post(from, capMsg(), "cap")
      if role == "host" then
        sendQueue(from)
        if hs then NET.post(from, stMsg(hs), "st") end
        sendTorrentInfo(from)
      end
      U.emit("party.memberHi", from)
    elseif t == "add" then
      local n = m.n
      if math.type(n) ~= "integer" or n < 1 or n > 2147483647 then return end
      local function reply(ok, why, c, ti)
        NET.post(from, {t = "addr", n = n, ok = ok, why = why, c = c, ti = ti and U.trim(ti, 60)})
      end
      if role ~= "host" then return reply(false, "not-running") end
      if CFG.get("whoAdds") ~= "anyone" then return reply(false, "host-only") end
      if now - (mi.addAt or -1e9) < ADD_ACCEPT then return reply(false, "rate") end
      mi.addAt = now
      if type(m.u) ~= "string" or #m.u > 4096 then return reply(false, "unsupported-url") end
      local c = wum.media.classify(m.u)
      if not c then return reply(false, "unsupported-url") end
      local f = m.f
      if math.type(f) ~= "integer" or f < 0 or f > 100000 then f = nil end
      local name = U.trim(NET.name(from), 32)
      QUEUE.addFor(c, {by = name, byId = from, f = f, ti = m.ti}, function(ok, why, count, title)
        reply(ok, why, count, title)
        if ok and U.now() - (mi.toastAt or -1e9) >= 3000 then
          mi.toastAt = U.now()
          toast(name .. " added " .. (count and count > 1 and (count .. " videos") or U.trim(title or "a video", 60)))
        end
      end)
    elseif t == "rm" then
      if role ~= "host" or math.type(m.id) ~= "integer" or now - (mi.rmAt or -1e9) < RM_ACCEPT then return end
      mi.rmAt = now
      QUEUE.removeFor(m.id, from)
    elseif t == "need" then
      if role ~= "host" or now - mi.needAt < NEED_ACCEPT then return end
      mi.needAt = now
      sendQueue(from)
      if hs then NET.post(from, stMsg(hs), "st") end
    elseif t == "buf" then
      if type(m.b) ~= "boolean" then return end
      mi.buf = m.b
      mi.err = m.ok == false
      if m.ok == true then mi.loaded = true end
    end
  end

  U.on("net.msg", function(from, m)
    if from == NET.hostId() and not NET.isHost() then
      fromHost(from, m)
    elseif NET.isHost() and inSession() then
      fromMember(from, m)
    end
  end)

  U.on("net.peer", function(id, up)
    if id == NET.hostId() and not NET.isHost() then
      acked = false
      if up then lastHi = -1e9 end
    elseif info[id] and not up then
      info[id].buf = false
    end
  end)

  ---------------------------------------------------------------- lobby changes

  local function resetPeerSide()
    hostParty, declined, prompted, acked = false, false, false, false
    lastHi, wantOpen = -1e9, nil
    hostCaps, pendingAdds = nil, {}
    info = {}
    if role == "none" then hs = nil end
    -- A peer forgets the host's queue version, so the next host's pages are taken whatever their number. An owner
    -- keeps its own counter (a peer's mirror never shares it after this reset).
    if not NET.isHost() then QUEUE.resetVersion() end
  end

  -- The lobby changed hands: the party ends for everyone. Every machine keeps the queue and where it was, and a new
  -- owner with Holo is offered "Continue party".
  U.on("net.owner", function(owner, isHost)
    local had = role ~= "none" or hostParty
    if had then
      resume = {snap = QUEUE.snapshot(), time = curPos(), rate = hs and hs.r or 1}
      if role ~= "none" then endLocal() end
      toast("The host left; the watch party ended", "warn")
    end
    resetPeerSide()
    if had and isHost then
      U.emit("party.continuePrompt", PARTY.hostName())
    elseif not isHost then
      resume = nil
    end
    U.emit("party.changed")
  end)

  U.on("net.leave", function()
    if role ~= "none" then endLocal() end
    resetPeerSide()
    resume = nil
    U.emit("party.changed")
  end)

  U.on("net.enter", function()
    -- A solo party ends when this machine joins someone else's lobby; a lobby it owns keeps it.
    if role == "host" and not NET.isHost() then
      endLocal()
      toast("Your watch party ended: you joined a lobby", "info")
    end
    resetPeerSide()
  end)

  ---------------------------------------------------------------- queue and layout changes

  U.on("queue.changed", function(kind)
    if PARTY.canControl() then U.setPref("lastQueue", QUEUE.snapshot()) end
    if role ~= "host" or kind == "current" then return end   -- peers take the current item from st.i
    queueDirtyAt = queueDirtyAt or U.now()
    if ended and QUEUE.step(1) then advance() end
  end)

  -- The host removed the item that is playing: the next one at its place plays, an empty queue ends the party.
  U.on("queue.removed", function(it, index)
    if role ~= "host" or it.id ~= openedId then return end
    local items = QUEUE.items()
    if #items == 0 then
      if inSession() then NET.postAll({t = "end", why = "empty"}) end
      endLocal()
      return
    end
    local nxt = items[index] or items[#items]
    playItem(nxt, 0)
  end)

  U.on("layout.size", function(w, h)
    if player and w then player:size(w, h) end
  end)

  U.on("cfg.changed", function(key, v)
    if key == "musicOff" then
      applyMusic()
    elseif key == "whoAdds" then
      broadcastCaps()
    elseif key == "volume" then
      U.setPref("volume", v)
      applyAudio()
    elseif key == "quality" then
      PARTY.setQuality(v)
    end
  end)

  ---------------------------------------------------------------- media events

  wum.events.on("melange.media", U.guard("party.media", function(ev)
    if role == "none" or not player then return end
    local ty = ev.type
    if ty == "loaded" then
      loaded = true
      local it = QUEUE.find(openedId)
      local d = U.num(ev.duration)
      if it and d and d > 0 then it.duration = d end
      if role == "host" and autoplay then
        autoplay = false
        schedulePlay(curPos())
      elseif role == "peer" then
        sendHost{t = "buf", b = false, i = openedId, p = curPos(), ok = true}
        if hs and hs.i == openedId then player:follow(hs, NET.hostId()) end
      end
    elseif ty == "buffering" then
      if role == "peer" then sendHost{t = "buf", b = ev.on == true, i = openedId, p = curPos(), ok = true} end
    elseif ty == "ended" then
      if ev.reason == "eof" then
        if role == "host" then advance() end
      elseif ev.reason == "error" then
        if role == "host" then
          toast("Can't play this item; skipping it", "error")
          errorAt = U.now()
        else
          sendHost{t = "buf", b = false, i = openedId, p = curPos(), ok = false}
        end
      end
    elseif ty == "error" then
      if role == "peer" then
        toast("Can't play this here", "error")
        sendHost{t = "buf", b = false, i = openedId, p = curPos(), ok = false}
      else
        toast("Can't play this item; skipping it", "error")
        errorAt = U.now()
      end
    elseif ty == "helper" and ev.state == "dead" then
      toast("The video player stopped working", "error")
    end
    U.emit("party.changed")
  end))

  ---------------------------------------------------------------- setup panel state, peers list, pack

  function PARTY.setupOpen() return setupOpen end
  function PARTY.setSetup(open)
    setupOpen = open == true
    U.emit("party.changed")
  end
  function PARTY.toggleSetup() PARTY.setSetup(not setupOpen) end

  -- The other members: {{id, name, state = "ready"|"buffering"|"nopack"|"noholo"|"error", drift}}.
  function PARTY.peers()
    local out = {}
    for _, m in ipairs(NET.members()) do
      if not m.me then
        local mi = info[m.id] or {}
        local state = "ready"
        if not m.holo then state = "noholo"
        elseif m.pack and m.pack ~= "ready" then state = "nopack"
        elseif mi.err then state = "error"
        elseif mi.buf then state = "buffering" end
        out[#out + 1] = {id = m.id, name = m.name, state = state, host = m.host, rtt = m.rtt}
      end
    end
    return out
  end

  function PARTY.pack() return wum.media.pack() end

  -- Call it from the click handler of the consent button: the click is the consent (2 s window).
  function PARTY.installPack()
    local ok, why = wum.media.install()
    if not ok and why ~= "ready" then
      local text = {gesture = "Click Download again", blocked = "Downloads are turned off in Melange.ini",
        ["unsupported-os"] = "The media pack needs 64-bit Windows", disabled = "Media is turned off in Melange.ini",
        busy = "The download is already running"}
      toast(text[why] or ("Could not start the download (" .. tostring(why) .. ")"), "error")
    end
    return ok, why
  end

  function PARTY.consentText()
    local pk = wum.media.pack() or {}
    return string.format("Holo plays videos with Melange's media pack: a %d MB download (%d MB on disk) from "
      .. "Melange's GitHub releases (github.com/JaminB/melange), installed once into Documents\\Melange\\media and "
      .. "checked against hashes built into Melange. YouTube items use yt-dlp; torrent items share your IP address "
      .. "with the swarm.", math.floor(U.num(pk.downloadMB) or 95), math.floor(U.num(pk.diskMB) or 300))
  end

  ---------------------------------------------------------------- tick

  local lastPackPoll = -1e9

  local function computePhase()
    if role == "none" then return setupOpen and "setup" or "idle" end
    if needsPack then return "needs-pack" end
    if ended then return "ended-item" end
    if not player or not pstate then return "loading" end
    if pstate.eof then return "ended-item" end
    if not loaded and not (U.num(pstate.duration) and pstate.duration > 0) then return "loading" end
    if pstate.buffering then return "buffering" end
    if pendingPlayAt then return "loading" end
    if pstate.paused then return "paused" end
    return "playing"
  end

  -- The phase is computed on read, so it is right straight after a call such as stop(); the tick emits changes.
  function PARTY.phase() return computePhase() end

  function PARTY.tick()
    local now = U.now()
    if player then
      local ok, st = pcall(player.state, player)
      pstate = ok and st or nil
    else
      pstate = nil
    end

    if role == "host" then
      if pendingPlayAt and now >= pendingPlayAt then
        pendingPlayAt = nil
        if player then player:play() end
      end
      if wantOpen and not player then
        local it = QUEUE.find(wantOpen)
        if it and openItem(it, hs and hs.p or 0, true) then wantOpen = nil end
      end
      if errorAt and now - errorAt >= 2000 then
        errorAt = nil
        advance()
      end
      if scrubAt and now - scrubAt >= SCRUB_HOLD then scrubAt = nil end
      if hs and hs.s == "play" and not pendingPlayAt and loaded and not scrubAt and now - lastBeat >= HEARTBEAT then
        lastBeat = now
        hs.p, hs.a = curPos(), now
        broadcastState(false)
      end
      if queueDirtyAt and now - queueDirtyAt >= 300 then
        queueDirtyAt = nil
        if inSession() then sendQueue() end
        presence()
      end
    elseif inSession() and not NET.isHost() then
      local host = NET.hostId()
      if not acked and now - lastHi >= HI_EVERY and NET.reachable(host) then
        lastHi = now
        NET.send(host, {t = "hi", v = 1, pack = NET.myPresence().pack or "missing", holo = VERSION})
      end
      for n, p in pairs(pendingAdds) do
        if now - p.at >= ADD_WAIT then
          pendingAdds[n] = nil
          U.emit("party.addResult", false, "no-answer")
        end
      end
      if role == "peer" then
        if needsPack and now - lastPackPoll >= 500 then
          lastPackPoll = now
          if packReady() then
            needsPack = false
            applySt()
          end
        end
        if wantOpen and now - lastOpen >= OPEN_EVERY then
          lastOpen = now
          openWanted()
        end
      end
    end

    applyMusic()
    applyAudio()
    local ph = computePhase()
    if ph ~= phase then
      phase = ph
      U.emit("party.changed")
    end
  end

  presence()
  wum.timers.every(0, U.guard("party", PARTY.tick))
end
