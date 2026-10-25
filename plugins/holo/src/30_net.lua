-- net (P2): the lobby as Holo sees it, the wum.peer channel (version 1), presence and a paced outbox.
-- Bus events: "lobby.changed" (members, owner, phase or someone's presence changed), "net.enter", "net.leave",
-- "net.owner" (owner, isHost), "net.msg" (from, tbl, meta) for a message from a lobby member, "net.peer" (id, up).
do
  local CHANNEL_VERSION = 1
  local PRESENCE_TITLE = 60          -- characters of the party title in the presence (the whole table is <= 256 B)
  -- Pacing per destination, below the core limits (20 msg/s, 8 KB/s, burst 10) so queue pages never hit "rate".
  local OUT_MSGS, OUT_BYTES = 8, 6000

  local ch, openTried, openWhy = nil, -1e9, nil
  local lobby, signature = nil, ""
  local presenceMine, presenceSent = {}, nil
  local outbox = {}                  -- id -> {list = {{tbl, opts, key, bytes}}, win = start ms, n, bytes}

  ---------------------------------------------------------------- lobby

  function NET.inSession() return lobby ~= nil end
  function NET.me() return lobby and lobby.me end
  function NET.phase() return lobby and lobby.phase end
  function NET.lobby() return lobby end

  -- The party host is always the lobby owner. Without a net session this machine hosts a solo party.
  function NET.isHost() return lobby == nil or lobby.owner == lobby.me end
  function NET.hostId() return lobby and lobby.owner end

  function NET.member(id)
    if not lobby then return nil end
    for _, m in ipairs(lobby.members or {}) do
      if m.id == id then return m end
    end
  end

  function NET.name(id)
    local m = NET.member(id)
    return m and type(m.name) == "string" and U.trim(m.name, 32) or "?"
  end

  -- A presence table another member published, checked field by field: {pack = "ready"|"missing"|"downloading",
  -- progress = 0..100, party = bool, title = string, n = 0..200}. Anything else is dropped; a non-table gives nil.
  function NET.parsePresence(t)
    if type(t) ~= "table" then return nil end
    local out = {}
    if type(t.pack) == "string" then
      if t.pack == "ready" or t.pack == "missing" then
        out.pack = t.pack
      else
        local pct = t.pack:match("^downloading:(%d%d?%d?)$")
        if pct and tonumber(pct) <= 100 then out.pack, out.progress = "downloading", tonumber(pct) end
      end
    end
    if t.party == 1 or t.party == true then out.party = true end
    if out.party and type(t.title) == "string" then out.title = U.trim(t.title, PRESENCE_TITLE) end
    local n = U.num(t.n)
    if out.party and n then out.n = math.floor(U.clamp(n, 0, 200)) end
    return out
  end

  function NET.presence(id)
    if not ch then return nil end
    local ok, t = pcall(ch.presence, ch, id)
    return ok and NET.parsePresence(t) or nil
  end

  function NET.clock(id)
    if not ch then return nil end
    local ok, c = pcall(ch.clock, ch, id)
    if ok and type(c) == "table" then return c end
  end

  -- {{id, name, holo, pack, progress, rtt, me, host, party}} in lobby order; empty outside a session.
  function NET.members()
    local out = {}
    if not lobby then return out end
    for _, m in ipairs(lobby.members or {}) do
      if type(m.id) == "string" then
        local pr = (not m.me) and NET.presence(m.id) or nil
        local c = (not m.me) and NET.clock(m.id) or nil
        out[#out + 1] = {id = m.id, name = U.trim(m.name, 32), me = m.me == true, host = m.id == lobby.owner,
          holo = m.me == true or m.peer == true or pr ~= nil,
          pack = m.me and presenceMine.packState or (pr and pr.pack),
          progress = pr and pr.progress, rtt = c and U.num(c.rtt) and math.floor(c.rtt + 0.5) or nil,
          party = pr and pr.party or nil}
      end
    end
    return out
  end

  local function sign()
    if not lobby then return "" end
    local parts = {tostring(lobby.owner), tostring(lobby.phase)}
    for _, m in ipairs(lobby.members or {}) do
      local pr = (not m.me) and NET.presence(m.id) or nil
      parts[#parts + 1] = tostring(m.id) .. (m.peer and "+" or "-") .. (pr and tostring(pr.pack) .. tostring(pr.party)
        .. tostring(pr.progress) .. tostring(pr.title) .. tostring(pr.n) or "")
    end
    return table.concat(parts, "|")
  end

  function NET.refresh()
    local ok, st = pcall(wum.lobby.state)
    lobby = ok and type(st) == "table" and st or nil
    if lobby and type(lobby.members) ~= "table" then lobby.members = {} end
    local s = sign()
    if s ~= signature then
      signature = s
      U.emit("lobby.changed")
    end
  end

  ---------------------------------------------------------------- channel

  function NET.channel() return ch end
  function NET.available() return ch ~= nil, openWhy end

  local function onMessage(from, tbl, meta)
    if type(from) ~= "string" or type(tbl) ~= "table" or type(tbl.t) ~= "string" then return end
    if not NET.member(from) or from == NET.me() then return end   -- the core filters too; cheap to repeat
    U.emit("net.msg", from, tbl, type(meta) == "table" and meta or {})
  end

  local function open()
    openTried = U.now()
    local c, why = wum.peer.open{version = CHANNEL_VERSION}
    if not c then
      openWhy = why
      return
    end
    ch, openWhy = c, nil
    ch:on(U.guard("net.on", onMessage))
    ch:onPeer(U.guard("net.onPeer", function(id, up)
      if not up then outbox[id] = nil end
      U.emit("net.peer", id, up)
    end))
    presenceSent = nil
  end

  function NET.peers()
    if not ch then return {} end
    local ok, p = pcall(ch.peers, ch)
    return ok and type(p) == "table" and p or {}
  end

  function NET.reachable(id)
    for _, p in ipairs(NET.peers()) do
      if p == id then return true end
    end
    return false
  end

  -- Rough size of a table on the wire (the core's tagged binary), for the outbox pacing and the page split.
  local function sizeOf(v, depth)
    local t = type(v)
    if t == "string" then return 3 + #v end
    if t == "number" then return 9 end
    if t ~= "table" then return 1 end
    if (depth or 0) > 8 then return 1 end
    local n = 3
    for k, x in pairs(v) do n = n + sizeOf(k, 9) + sizeOf(x, (depth or 0) + 1) end
    return n
  end
  NET.sizeOf = sizeOf

  -- Sends at once: true, or false and a reason ("closed" without a channel). Unreliable when opts.reliable == false.
  function NET.send(id, tbl, opts)
    if not ch then return false, "closed" end
    local ok, r, why = pcall(ch.send, ch, id, tbl, opts)
    if not ok then return false, tostring(r) end
    return r, why
  end

  -- Queues a reliable message to one member, paced per destination. A message with a key replaces a queued one with
  -- the same key (a newer state supersedes an older one that has not left yet).
  function NET.post(id, tbl, key)
    local box = outbox[id]
    if not box then
      box = {list = {}, win = U.now(), n = 0, bytes = 0}
      outbox[id] = box
    end
    if key then
      for _, m in ipairs(box.list) do
        if m.key == key then
          m.tbl, m.bytes = tbl, sizeOf(tbl)
          return
        end
      end
    end
    box.list[#box.list + 1] = {tbl = tbl, key = key, bytes = sizeOf(tbl)}
  end

  -- Drops the queued messages to `id` whose key matches a Lua pattern (an older queue's pages).
  function NET.drop(id, pattern)
    local box = outbox[id]
    if not box then return end
    for i = #box.list, 1, -1 do
      local k = box.list[i].key
      if k and k:find(pattern) then table.remove(box.list, i) end
    end
  end

  -- NET.post to every member reachable now; returns how many.
  function NET.postAll(tbl, key)
    local peers = NET.peers()
    for _, id in ipairs(peers) do NET.post(id, tbl, key) end
    return #peers
  end

  function NET.pending(id)
    local box = outbox[id]
    return box and #box.list or 0
  end

  local function drain()
    local now = U.now()
    for id, box in pairs(outbox) do
      if now - box.win >= 1000 then box.win, box.n, box.bytes = now, 0, 0 end
      while box.list[1] and box.n < OUT_MSGS and (box.bytes + box.list[1].bytes <= OUT_BYTES or box.n == 0) do
        local m = box.list[1]
        local ok, why = NET.send(id, m.tbl)
        if not ok and why == "rate" then
          box.n = OUT_MSGS                                     -- try again in the next window
          break
        end
        table.remove(box.list, 1)
        box.n, box.bytes = box.n + 1, box.bytes + m.bytes
        if not ok then U.log("debug", "send", m.tbl.t, "failed:", why) end
      end
      if not box.list[1] then outbox[id] = nil end
    end
  end

  ---------------------------------------------------------------- presence

  -- Merges fields into this machine's presence (nil removes one) and publishes it when it changed. packState is
  -- kept for NET.members() and published as the "pack" field.
  function NET.setPresence(fields)
    for k, v in pairs(fields) do presenceMine[k] = v end
    if not ch then return end
    local pub = {pack = presenceMine.pack}
    if presenceMine.party then
      pub.party = 1
      pub.title = U.trim(presenceMine.title, PRESENCE_TITLE)
      pub.n = presenceMine.n
    end
    local s = tostring(pub.pack) .. "|" .. tostring(pub.party) .. "|" .. tostring(pub.title) .. "|" .. tostring(pub.n)
    if s == presenceSent then return end
    presenceSent = s
    pcall(ch.setPresence, ch, pub)
  end

  function NET.myPresence() return presenceMine end

  -- The pack state for the presence: "ready", "missing" or "downloading:<percent>".
  function NET.packPresence(pk)
    if type(pk) ~= "table" then return "missing" end
    if pk.state == "ready" then return "ready" end
    if pk.state == "downloading" or pk.state == "verifying" or pk.state == "installing" or pk.state == "updating" then
      return "downloading:" .. math.floor(U.clamp(U.num(pk.progress) or 0, 0, 1) * 100)
    end
    return "missing"
  end

  local function updatePack()
    local ok, pk = pcall(wum.media.pack)
    local s = NET.packPresence(ok and pk or nil)
    if s ~= presenceMine.pack then
      NET.setPresence{pack = s, packState = s:match("^%a+")}
    end
  end

  ---------------------------------------------------------------- events and tick

  local function lobbyEvent(kind)
    return U.guard("net." .. kind, function()
      NET.refresh()
      if kind == "leave" then
        outbox = {}
        U.emit("net.leave")
      elseif kind == "enter" then
        presenceSent = nil
        U.emit("net.enter")
      elseif kind == "owner" then
        outbox = {}
        U.emit("net.owner", lobby and lobby.owner, NET.isHost())
      end
    end)
  end
  wum.events.on("melange.lobby.enter", lobbyEvent("enter"))
  wum.events.on("melange.lobby.leave", lobbyEvent("leave"))
  wum.events.on("melange.lobby.owner", lobbyEvent("owner"))
  wum.events.on("melange.lobby.members", lobbyEvent("members"))
  wum.events.on("melange.lobby.phase", lobbyEvent("phase"))

  local lastRefresh = -1e9
  function NET.tick()
    local now = U.now()
    if not ch and now - openTried >= 5000 then open() end
    if now - lastRefresh >= 500 then
      lastRefresh = now
      NET.refresh()
      updatePack()
    end
    drain()
  end

  open()
  NET.refresh()
  updatePack()
  wum.timers.every(0, U.guard("net", NET.tick))
end
