-- queue (P2): the host's play queue, its wire pages, the peers' mirror of it, and the torrents its items need.
-- Items are {id, kind = "yt"|"bt", url (canonical), file (torrent file index), title, duration, live}.
-- Bus events: "queue.changed" (with "current" when only the current item changed: no new version, nothing to send),
-- "queue.pick" (token, files, name) for the torrent file picker, "queue.picked" (item), "queue.removed" (item, index).
do
  local MAX_ITEMS = 200
  local TITLE = 120
  local PAGE_BYTES = 7000            -- a reliable message is at most 8 KB
  local MAX_PAGES = 64
  local MAX_TORRENTS = 3             -- the core allows 4 per mod; one stays free for a new magnet's file list

  local items, cur, qv, nextId = {}, nil, 0, 1
  local picks, nextToken = {}, 1
  local torrents = {}                -- canonical magnet -> {t = handle, files = list|nil, waiting = {fn...}}
  local partial = nil                -- the peer's pages being assembled: {qv, pages, got = {page -> items}, n, cur}

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
    for url in pairs(torrents) do
      if url ~= keepUrl and not busy[url] then QUEUE.closeTorrent(url) end
    end
  end

  function QUEUE.closeAllTorrents()
    for token in pairs(picks) do picks[token] = nil end
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
    return (tostring(path):match("([^/\\]+)$") or tostring(path)):gsub("%.%w+$", "")
  end

  local function addTorrentItem(url, file, title)
    local it, why = append{kind = "bt", url = url, file = file, title = U.trim(title, TITLE), duration = 0}
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
        local it, why = addTorrentItem(p.url, index, baseName(f.path))
        if it then U.emit("queue.picked", it) end
        return it ~= nil, why
      end
    end
    return nil, "file"
  end

  function QUEUE.cancelPick(token)
    local p = picks[token]
    if not p then return false end
    picks[token] = nil
    local used = PARTY.currentUrl() == p.url
    for _, it in ipairs(items) do used = used or it.url == p.url end
    if not used then QUEUE.closeTorrent(p.url) end
    return true
  end

  local function onTorrentFiles(token, e)
    local p = picks[token]
    if not p then return end
    if e.error or not e.files then
      picks[token] = nil
      QUEUE.closeTorrent(p.url)
      U.emit("party.toast", "This torrent could not be read", "error")
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

  local function addPlaylist(res)
    if type(res) ~= "table" then return end
    if res.error then
      U.emit("party.toast", res.error == "private" and "That playlist is private" or "Could not list that playlist",
        "error")
      return
    end
    local n = 0
    for _, r in ipairs(type(res.items) == "table" and res.items or {}) do
      local c = type(r) == "table" and type(r.url) == "string" and wum.media.classify(r.url)
      if c and c.kind == "youtube" and c.id then
        local it = append{kind = "yt", url = c.url, title = U.trim(r.title, TITLE),
          duration = U.num(r.duration) and math.max(0, r.duration) or 0, live = c.live or nil}
        if not it then break end
        if it.title == "" then it.title = "YouTube video" end
        n = n + 1
      end
    end
    if n > 0 then changed() end
    U.emit("party.toast", n > 0 and ("Added " .. n .. " videos") or "That playlist has no playable videos",
      n > 0 and "info" or "warn")
  end

  -- Adds what the user typed or pasted: true (a playlist or a torrent finishes later), or nil and a reason:
  -- "unsupported-url", "not-host", "full", or a wum.media reason ("busy", "first-use-in-match", ...).
  function QUEUE.add(text)
    if type(text) ~= "string" then return nil, "unsupported-url" end
    local c = wum.media.classify(text)
    if not c then return nil, "unsupported-url" end
    if not canEdit() then return nil, "not-host" end
    if #items >= MAX_ITEMS then return nil, "full" end
    if c.kind == "magnet" then
      local e, why = openTorrent(c.url)
      if not e then return nil, why end
      local token = nextToken
      nextToken = nextToken + 1
      picks[token] = {url = c.url, name = c.name or "Torrent", files = {}}
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
    local id, why = wum.media.resolve(c.url, U.guard("queue.playlist", addPlaylist))
    if not id then return nil, why end
    return true
  end

  function QUEUE.remove(id)
    if not canEdit() then return nil, "not-host" end
    local i = QUEUE.indexOf(id)
    if not i then return nil, "unknown" end
    local it = table.remove(items, i)
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
      local w = QUEUE.checkWire({id = 1, k = it.kind, u = it.url, f = it.file, ti = it.title, d = it.duration})
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
    return {id = it.id, k = it.kind, u = it.url, f = it.file, ti = it.title, d = it.duration}
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
end
