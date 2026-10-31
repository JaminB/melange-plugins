-- queue (P2): the host's play queue, its wire pages, the peers' mirror of it, and the torrents its items need.
-- Items are {id, kind = "yt"|"bt", url (canonical), file (torrent file index), title, duration, live}.
-- Bus events: "queue.changed" (with "current" when only the current item changed: no new version, nothing to send),
-- "queue.pick" (token, files, name) for the torrent file picker, "queue.picked" (item), "queue.removed" (item, index).
-- A member's add is an item with `by` (display name) and `byId` (SteamID string); the host checks and appends it
-- (QUEUE.addFor), the members' own picks go to the host through PARTY.requestAdd.
do
  local MAX_ITEMS = 200
  local TITLE = 120
  local PAGE_BYTES = 7000            -- a reliable message is at most 8 KB
  local MAX_PAGES = 64
  local MAX_TORRENTS = 3             -- the core allows 4 per mod; one stays free for a new magnet's file list
  local MEMBER_MAX = 50              -- items one member may have in the queue at a time
  local HOST_WAIT = 40000            -- host: a member's magnet gets its file list within this (the member waits 45 s)
  local HOST_WAITS = 2               -- host: members' magnets waiting for a file list at once (one torrent slot stays)
  QUEUE.MEMBER_MAX = MEMBER_MAX

  local items, cur, qv, nextId = {}, nil, 0, 1
  local picks, nextToken = {}, 1
  local torrents = {}                -- canonical magnet -> {t = handle, files = list|nil, waiting = {fn...}}
  local partial = nil                -- the peer's pages being assembled: {qv, pages, got = {page -> items}, n, cur}
  local hostWaits = {}               -- host: magnet url -> {at, fns} while members' adds wait for the file list

  local function changed()
    qv = qv + 1
    U.emit("queue.changed")
  end

  function QUEUE.items() return items end
  function QUEUE.version() return qv end
  function QUEUE.count() return #items end

  function QUEUE.indexOf(id)
    for i, it in ipairs(items) do
      if it.id == id then return i end
    end
  end

  function QUEUE.find(id)
    local i = QUEUE.indexOf(id)
    return i and items[i]
  end

  -- The number of items added by the member with this SteamID string.
  function QUEUE.countBy(id)
    local n = 0
    if id == nil then return 0 end
    for _, it in ipairs(items) do
      if it.byId == id then n = n + 1 end
    end
    return n
  end

  -- True if an item has this url and file (file is nil for a YouTube item).
  function QUEUE.has(url, file)
    for _, it in ipairs(items) do
      if it.url == url and it.file == file then return true end
    end
    return false
  end

  function QUEUE.current() return cur and QUEUE.find(cur) or nil end
  function QUEUE.currentIndex() return cur and QUEUE.indexOf(cur) or nil end

  -- Sets the current item. It is not a new queue version: the peers follow the host's st.i, so a new item never
  -- resends the whole queue.
  function QUEUE.setCurrent(id)
    if id ~= nil and not QUEUE.find(id) then return false end
    if cur ~= id then
      cur = id
      U.emit("queue.changed", "current")
    end
    return true
  end

  -- The item delta steps from the current one (1 = next, -1 = previous), or nil past either end. Without a current
  -- item, next is the first.
  function QUEUE.step(delta)
    local i = QUEUE.currentIndex()
    if not i then return delta > 0 and items[1] or nil end
    return items[i + delta]
  end

  local function canEdit()
    if not PARTY.canControl() then return false end
    return true
  end

  local function append(it)
    if #items >= MAX_ITEMS then return nil, "full" end
    it.id = nextId
    nextId = nextId + 1
    items[#items + 1] = it
    return it
  end

  ---------------------------------------------------------------- torrents

  local function countTorrents()
    local n = 0
    for _ in pairs(torrents) do n = n + 1 end
    return n
  end

  local function openTorrent(url)
    local e = torrents[url]
    if e and not e.closed then return e end
    if countTorrents() >= MAX_TORRENTS then QUEUE.keepTorrents(PARTY.currentUrl()) end
    e = {waiting = {}}
    local t, why = wum.media.torrent(url, U.guard("queue.torrent", function(res)
      if type(res) ~= "table" then return end
      if type(res.files) == "table" then e.files, e.name = res.files, res.name end
      if res.error then e.error = tostring(res.error) end
      local w = e.waiting
      e.waiting = {}
      for _, fn in ipairs(w) do fn(e) end
    end))
    if not t then return nil, why end
    e.t = t
    torrents[url] = e
    return e
  end

  -- The open torrent for a magnet (opened if needed): entry {t, files, name, error}, or nil, reason.
  function QUEUE.torrentFor(url) return openTorrent(url) end

  function QUEUE.closeTorrent(url)
    local e = torrents[url]
    if not e then return end
    torrents[url] = nil
    e.closed = true
    if e.t then pcall(e.t.close, e.t) end
  end

  -- Closes every torrent except the one of `keepUrl` and those still waiting for a file pick.
  function QUEUE.keepTorrents(keepUrl)
    local busy = {}
    for _, p in pairs(picks) do busy[p.url] = true end
    for url in pairs(hostWaits) do busy[url] = true end
    for url in pairs(torrents) do
      if url ~= keepUrl and not busy[url] then QUEUE.closeTorrent(url) end
    end
  end

  function QUEUE.closeAllTorrents()
    for token in pairs(picks) do picks[token] = nil end
    for url in pairs(hostWaits) do hostWaits[url] = nil end
    for url in pairs(torrents) do QUEUE.closeTorrent(url) end
  end

  -- The video files of a torrent, largest first (the picker lists nothing else, design S3).
  function QUEUE.videoFiles(files)
    local out = {}
    for _, f in ipairs(type(files) == "table" and files or {}) do
      if type(f) == "table" and f.video == true and math.type(f.index) == "integer" then
        out[#out + 1] = {index = f.index, path = U.trim(f.path, 240), size = U.num(f.size) or 0}
      end
    end
    table.sort(out, function(a, b)
      if a.size ~= b.size then return a.size > b.size end
      return a.index < b.index
    end)
    return out
  end

  local function baseName(path)
    local name = (tostring(path):match("([^/\\]+)$") or tostring(path)):gsub("%.%w+$", "")
    return name
  end

  -- attrib (optional): {by, byId} of the member who added it.
  local function addTorrentItem(url, file, title, attrib)
    local it, why = append{kind = "bt", url = url, file = file, title = U.trim(title, TITLE), duration = 0,
      by = attrib and attrib.by, byId = attrib and attrib.byId}
    if not it then return nil, why end
    changed()
    -- Keep the file list of the newest magnet for a quick start, but never hold more than the cap.
    if countTorrents() > MAX_TORRENTS - 1 and url ~= PARTY.currentUrl() then QUEUE.closeTorrent(url) end
    return it
  end

  function QUEUE.pickFile(token, index)
    local p = picks[token]
    if not p then return nil, "unknown" end
    for _, f in ipairs(p.files) do
      if f.index == index then
        picks[token] = nil
        if p.forHost then
          -- A member's pick: the host adds it. The local torrent was only for the file list.
          local title = baseName(f.path)
          local ok, why = PARTY.requestAdd{u = p.url, f = index, ti = title}
          if PARTY.currentUrl() ~= p.url then QUEUE.closeTorrent(p.url) end
          if ok then U.emit("party.addSent", title) end
          return ok, why
        end
        local it, why = addTorrentItem(p.url, index, baseName(f.path))
        if it then U.emit("queue.picked", it) end
        return it ~= nil, why
      end
    end
    return nil, "file"
  end

  -- Magnets still waiting for their file list, oldest first: {{name, peers, secs}}. A magnet carries no file list; it
  -- comes from peers, which can take a minute or more.
  function QUEUE.reading()
    local out = {}
    for _, p in pairs(picks) do
      if #p.files == 0 then
        local e, peers = torrents[p.url], 0
        if e and e.t then
          local ok, st = pcall(e.t.status, e.t)
          if ok and type(st) == "table" then peers = U.num(st.peers) or 0 end
        end
        out[#out + 1] = {name = p.name, peers = peers, secs = (U.now() - (p.since or U.now())) / 1000}
      end
    end
    table.sort(out, function(a, b) return a.secs > b.secs end)
    return out
  end

  -- Closes the torrent of a magnet when no item, no playing video, no open pick and no member's add needs it.
  local function releaseTorrent(url)
    local used = PARTY.currentUrl() == url or hostWaits[url] ~= nil
    for _, it in ipairs(items) do used = used or it.url == url end
    for _, p in pairs(picks) do used = used or p.url == url end
    if not used then QUEUE.closeTorrent(url) end
  end

  function QUEUE.cancelPick(token)
    local p = picks[token]
    if not p then return false end
    picks[token] = nil
    releaseTorrent(p.url)
    return true
  end

  local function onTorrentFiles(token, e)
    local p = picks[token]
    if not p then return end
    if e.error or not e.files then
      picks[token] = nil
      QUEUE.closeTorrent(p.url)
      U.emit("party.toast", e.error == "helper" and "The video player could not start (see Melange.log)" or
        "This torrent could not be read", "error")
      return
    end
    local vids = QUEUE.videoFiles(e.files)
    if #vids == 0 then
      picks[token] = nil
      QUEUE.closeTorrent(p.url)
      U.emit("party.toast", "No video file in this torrent", "warn")
      return
    end
    p.files, p.name = vids, U.trim(e.name or p.name, TITLE)
    if #vids == 1 then
      QUEUE.pickFile(token, vids[1].index)
    else
      U.emit("queue.pick", token, vids, p.name)
    end
  end

  ---------------------------------------------------------------- adding

  local function fillTitle(url, res)
    if type(res) ~= "table" or type(res.items) ~= "table" or type(res.items[1]) ~= "table" then return end
    local r = res.items[1]
    for _, it in ipairs(items) do
      if it.url == url and it.untitled then
        it.untitled = nil
        it.title = U.trim(r.title, TITLE)
        if it.title == "" then it.title = "YouTube video" end
        it.duration = U.num(r.duration) and math.max(0, r.duration) or 0
        changed()
      end
    end
  end

  -- True once Melange has installed yt-dlp, which every YouTube link needs (it arrives a moment after the pack).
  function QUEUE.haveYtdlp()
    local ok, pk = pcall(wum.media.pack)
    return ok and type(pk) == "table" and type(pk.ytdlp) == "string" and pk.ytdlp ~= ""
  end

  local PLAYLIST_MSG = {
    private = "That playlist is private",
    ytdlp = "YouTube needs yt-dlp, which Melange has not downloaded yet; try again soon",
    playlist = "Could not list that playlist",
  }

  -- The result of wum.media.resolve for a playlist. The host's own add (no attrib) toasts; a member's add (attrib =
  -- {by, byId}) adds at most `room` items and reports through done(ok, why, count) instead.
  local function addPlaylist(res, attrib, room, done)
    local function fail(why)
      if done then done(false, why, 0) else U.emit("party.toast", PLAYLIST_MSG[why], "error") end
    end
    if type(res) ~= "table" then return fail("playlist") end
    if res.error then
      if res.error == "private" then return fail("private") end
      return fail(QUEUE.haveYtdlp() and "playlist" or "ytdlp")
    end
    if attrib then room = math.min(room or MEMBER_MAX, MEMBER_MAX - QUEUE.countBy(attrib.byId)) end
    local n, limit = 0, nil
    for _, r in ipairs(type(res.items) == "table" and res.items or {}) do
      local c = type(r) == "table" and type(r.url) == "string" and wum.media.classify(r.url)
      if c and c.kind == "youtube" and c.id then
        if room and n >= room then
          limit = "member-full"
          break
        end
        local it = append{kind = "yt", url = c.url, title = U.trim(r.title, TITLE),
          duration = U.num(r.duration) and math.max(0, r.duration) or 0, live = c.live or nil,
          by = attrib and attrib.by, byId = attrib and attrib.byId}
        if not it then
          limit = "full"
          break
        end
        if it.title == "" then it.title = "YouTube video" end
        n = n + 1
      end
    end
    if n > 0 then changed() end
    if done then
      done(n > 0, n == 0 and (limit or "playlist") or limit, n)
    else
      U.emit("party.toast", n > 0 and ("Added " .. n .. " videos") or "That playlist has no playable videos",
        n > 0 and "info" or "warn")
    end
  end

  local function packReady()
    local ok, pk = pcall(wum.media.pack)
    return ok and type(pk) == "table" and pk.state == "ready"
  end

  -- Host: adds a classified link for a member (bypasses canEdit, never the checks). attrib = {by, byId, f, ti}.
  -- done(ok, why, count, title) is called exactly once (possibly later: playlist, title-less torrent).
  function QUEUE.addFor(c, attrib, done)
    local by, byId = attrib.by, attrib.byId
    local mine = {by = by, byId = byId}
    local isMagnet = c.kind == "magnet"
    local f = isMagnet and math.type(attrib.f) == "integer" and attrib.f >= 0 and attrib.f <= 100000 and attrib.f or nil
    if #items >= MAX_ITEMS then return done(false, "full") end
    if QUEUE.has(c.url, f) then return done(false, "dup") end
    local room = MEMBER_MAX - QUEUE.countBy(byId)
    if room <= 0 then return done(false, "member-full") end
    if isMagnet then
      if f then
        local title = U.trim(attrib.ti, TITLE)
        if title == "" then title = c.name or "Torrent" end
        local it, why = addTorrentItem(c.url, f, title, mine)
        if not it then return done(false, why) end
        return done(true, nil, 1, it.title)
      end
      -- No file chosen (the member has no media pack): the host reads the file list and takes the largest video.
      -- Members' magnets never hold every torrent slot, and give up after HOST_WAIT (a dead magnet would else keep
      -- its slot for the whole party).
      local url = c.url
      if not hostWaits[url] then
        local n = 0
        for _ in pairs(hostWaits) do n = n + 1 end
        if n >= HOST_WAITS then return done(false, "host-busy") end
      end
      local e, why = openTorrent(url)
      if not e then return done(false, why) end
      local answered = false
      local function filesIn(x)
        if answered then return end
        answered = true
        local w = hostWaits[url]
        if w then
          for i = #w.fns, 1, -1 do if w.fns[i] == filesIn then table.remove(w.fns, i) end end
          if #w.fns == 0 then hostWaits[url] = nil end
        end
        local function refuse(reason)
          releaseTorrent(url)
          return done(false, reason)
        end
        if x.error then return refuse(x.error == "slow" and "torrent-slow" or "torrent") end
        local vids = QUEUE.videoFiles(x.files)
        if #vids == 0 then return refuse("no-video") end
        if QUEUE.has(url, vids[1].index) then return refuse("dup") end
        if MEMBER_MAX - QUEUE.countBy(byId) <= 0 then return refuse("member-full") end
        local it, why2 = addTorrentItem(url, vids[1].index, baseName(vids[1].path), mine)
        if not it then return refuse(why2) end
        return done(true, nil, 1, it.title)
      end
      if e.files or e.error then
        filesIn(e)
      else
        local w = hostWaits[url] or {at = U.now(), fns = {}}
        hostWaits[url] = w
        w.fns[#w.fns + 1] = filesIn
        e.waiting[#e.waiting + 1] = U.guard("queue.addFor", filesIn)
      end
      return
    end
    if c.id then
      local it = append{kind = "yt", url = c.url, title = "YouTube video", duration = 0, untitled = true,
        live = c.live or nil, by = by, byId = byId}
      changed()
      local url = it.url
      wum.media.resolve(url, U.guard("queue.title", function(res) fillTitle(url, res) end))
      return done(true, nil, 1, "YouTube video")
    end
    local id, why = wum.media.resolve(c.url, U.guard("queue.playlist", function(res)
      addPlaylist(res, mine, room, done)
    end))
    if not id then return done(false, why) end
  end

  -- A member's add: a YouTube link or a magnet link goes to the host (PARTY.requestAdd). A magnet is first read
  -- locally when the media pack is ready, so the member picks the file; otherwise the host picks the largest video.
  local function addAsMember(c)
    if #items >= MAX_ITEMS then return nil, "full" end
    if QUEUE.countBy(NET.me()) >= MEMBER_MAX then return nil, "member-full" end
    if c.kind == "youtube" and c.id and QUEUE.has(c.url, nil) then return nil, "dup" end
    if c.kind == "magnet" and packReady() then
      local e = openTorrent(c.url)
      if e then
        local token = nextToken
        nextToken = nextToken + 1
        picks[token] = {url = c.url, name = c.name or "Torrent", files = {}, since = U.now(), forHost = true}
        if e.files or e.error then
          onTorrentFiles(token, e)
        else
          e.waiting[#e.waiting + 1] = function(x) onTorrentFiles(token, x) end
        end
        return true
      end
    end
    return PARTY.requestAdd{u = c.url}
  end

  -- Adds what the user typed or pasted: true (a playlist or a torrent finishes later), or nil and a reason:
  -- "unsupported-url", "not-host", "full", or a wum.media reason ("busy", "first-use-in-match", ...). A member
  -- (PARTY.canAdd) gets true, "sent" when the request went to the host, or the PARTY.addWhyNot reason.
  function QUEUE.add(text)
    if type(text) ~= "string" then return nil, "unsupported-url" end
    local c = wum.media.classify(text)
    if not c then return nil, "unsupported-url" end
    if not canEdit() then
      if not PARTY.canAdd() then return nil, PARTY.addWhyNot() or "not-host" end
      return addAsMember(c)
    end
    if #items >= MAX_ITEMS then return nil, "full" end
    if c.kind == "magnet" then
      local e, why = openTorrent(c.url)
      if not e then return nil, why end
      local token = nextToken
      nextToken = nextToken + 1
      picks[token] = {url = c.url, name = c.name or "Torrent", files = {}, since = U.now()}
      if e.files or e.error then
        onTorrentFiles(token, e)
      else
        e.waiting[#e.waiting + 1] = function(x) onTorrentFiles(token, x) end
      end
      return true
    end
    if c.id then
      local it = append{kind = "yt", url = c.url, title = "YouTube video", duration = 0, untitled = true,
        live = c.live or nil}
      changed()
      local url = it.url
      wum.media.resolve(url, U.guard("queue.title", function(res) fillTitle(url, res) end))
      return true
    end
    local id, why = wum.media.resolve(c.url, U.guard("queue.playlist", function(res) addPlaylist(res) end))
    if not id then return nil, why end
    return true
  end

  local function removeAt(i)
    local it = table.remove(items, i)
    local id = it.id
    if cur == id then cur = nil end
    if it.kind == "bt" then
      local used = false
      for _, x in ipairs(items) do used = used or x.url == it.url end
      if not used and PARTY.currentUrl() ~= it.url then QUEUE.closeTorrent(it.url) end
    end
    U.emit("queue.removed", it, i)
    changed()
    return true
  end

  function QUEUE.remove(id)
    if not canEdit() then return nil, "not-host" end
    local i = QUEUE.indexOf(id)
    if not i then return nil, "unknown" end
    return removeAt(i)
  end

  -- Host: removes an item for the member who added it (byId is the member's SteamID string); nothing else.
  function QUEUE.removeFor(id, byId)
    local i = QUEUE.indexOf(id)
    if not i then return nil, "unknown" end
    if byId == nil or items[i].byId ~= byId then return nil, "not-yours" end
    return removeAt(i)
  end

  function QUEUE.move(id, delta)
    if not canEdit() then return nil, "not-host" end
    local i = QUEUE.indexOf(id)
    if not i then return nil, "unknown" end
    local j = U.clamp(i + delta, 1, #items)
    if j == i then return false end
    local it = table.remove(items, i)
    table.insert(items, j, it)
    changed()
    return true
  end

  function QUEUE.clear()
    items, cur = {}, nil
    changed()
  end

  ---------------------------------------------------------------- snapshots (resume) and wire pages

  function QUEUE.snapshot() return {items = U.copy(items), cur = cur} end

  -- Loads a snapshot as this machine's own queue (a new host continuing, or the stored last queue). Items are
  -- checked again like wire items and get new ids; returns the new id of the snapshot's current item.
  function QUEUE.load(snap)
    items, cur = {}, nil
    local newCur
    for _, it in ipairs(type(snap) == "table" and type(snap.items) == "table" and snap.items or {}) do
      local w = QUEUE.checkWire({id = 1, k = it.kind, u = it.url, f = it.file, ti = it.title, d = it.duration,
        b = it.by, bi = it.byId})
      if w then
        local n = append(w)
        if not n then break end
        if it.id == snap.cur then newCur = n.id end
      end
    end
    cur = newCur
    changed()
    return newCur
  end

  local function toWire(it)
    return {id = it.id, k = it.kind, u = it.url, f = it.file, ti = it.title, d = it.duration, b = it.by,
      bi = it.byId}
  end

  -- The queue as "q" messages: {{t = "q", qv, page, pages, items, cur}, ...}, each under PAGE_BYTES. An empty queue
  -- is one page with no items.
  function QUEUE.pages()
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
      out[i] = {t = "q", qv = qv, page = i, pages = #pages, items = p, cur = cur}
    end
    return out
  end

  -- One wire item, checked: the url is classified again and must match the kind, the title is trimmed, a torrent
  -- item needs a file index. Returns a queue item (without an id) or nil.
  function QUEUE.checkWire(w)
    if type(w) ~= "table" or math.type(w.id) ~= "integer" or w.id < 1 then return nil end
    if type(w.u) ~= "string" or #w.u > 4096 then return nil end
    local c = wum.media.classify(w.u)
    if not c then return nil end
    local it = {kind = w.k, url = c.url, title = U.trim(w.ti, TITLE), duration = 0}
    local d = U.num(w.d)
    if d and d > 0 then it.duration = math.min(d, 1e7) end
    if w.k == "yt" then
      if c.kind ~= "youtube" or not c.id then return nil end
      it.live = c.live or nil
    elseif w.k == "bt" then
      if c.kind ~= "magnet" or math.type(w.f) ~= "integer" or w.f < 0 or w.f > 100000 then return nil end
      it.file = w.f
    else
      return nil
    end
    if it.title == "" then it.title = it.kind == "bt" and "Torrent" or "YouTube video" end
    -- Who added it (members' adds): a display name and a SteamID string, both optional.
    local by = U.trim(w.b, 32)
    if by ~= "" then it.by = by end
    if type(w.bi) == "string" and w.bi ~= "" and #w.bi <= 32 then it.byId = w.bi end
    return it
  end

  -- A "q" page from the host (the peer's mirror). Returns true once every page of that version arrived and the
  -- mirror was replaced, false while pages are missing, nil for a malformed or stale page.
  function QUEUE.acceptPage(m)
    local v, page, pages = m.qv, m.page, m.pages
    if math.type(v) ~= "integer" or math.type(page) ~= "integer" or math.type(pages) ~= "integer" then return nil end
    if pages < 1 or pages > MAX_PAGES or page < 1 or page > pages or type(m.items) ~= "table" then return nil end
    if v == qv and not partial then return nil end      -- already have it
    if not partial or partial.qv ~= v or partial.pages ~= pages then
      partial = {qv = v, pages = pages, got = {}, n = 0}
    end
    if not partial.got[page] then
      local list = {}
      for _, w in ipairs(m.items) do
        local it = QUEUE.checkWire(w)
        if it then
          it.id = w.id
          list[#list + 1] = it
        end
        if #list >= MAX_ITEMS then break end
      end
      partial.got[page], partial.n = list, partial.n + 1
    end
    if page == pages or math.type(m.cur) == "integer" then partial.cur = m.cur end
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
    items, qv = new, v
    cur = (math.type(partial.cur) == "integer" and seen[partial.cur]) and partial.cur or nil
    partial = nil
    U.emit("queue.changed")
    return true
  end

  -- The peer side: forget the host's version so the next host's pages are taken whatever their number.
  function QUEUE.resetVersion()
    partial = nil
    qv = -1
  end

  -- Sets a mirrored item's file (the host's "bt" message).
  function QUEUE.setFile(id, file)
    local it = QUEUE.find(id)
    if not it or it.kind ~= "bt" or math.type(file) ~= "integer" or file < 0 then return false end
    if it.file ~= file then
      it.file = file
      U.emit("queue.changed")
    end
    return true
  end

  -- Host: members' magnets whose file list did not come in time are refused ("torrent-slow") and their torrent closed.
  wum.timers.every(1, U.guard("queue.waits", function()
    local now, late = U.now(), {}
    for url, w in pairs(hostWaits) do
      if now - w.at >= HOST_WAIT then late[#late + 1] = url end
    end
    for _, url in ipairs(late) do
      local w = hostWaits[url]
      hostWaits[url] = nil
      for _, fn in ipairs(w.fns) do fn({error = "slow"}) end
    end
  end))
end
