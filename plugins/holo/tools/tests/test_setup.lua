-- SETUP (src/85_setup.lua): the watch-party panel: the link box (focus, paste, Enter, the classify tick or cross),
-- the virtualised queue list and its row buttons, the torrent file picker modal, the players list, the pack consent
-- block, the footer, the read-only panel of a peer, and the pointer the panel brings into a match.
local MW = require("mock_wum")

local fails = 0
local function check(cond, what)
  if not cond then
    fails = fails + 1
    io.stderr:write("  FAIL: " .. what .. "\n")
  end
end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 0.5) end

local VID1 = "https://youtu.be/vid00000001"
local MAGNET = "magnet:?xt=urn:btih:" .. string.rep("cd", 20) .. "&dn=Show"

local function machine(id)
  local wum, mock = MW.new()
  wum._holoTest = {}
  local _, ok, err = MW.load("mod/client/init.lua", wum)
  check(ok, id .. ": init.lua runs: " .. tostring(err))
  mock.cursorSource = "frontend"
  mock.cursorPos = {2, 2}
  return {id = id, wum = wum, mock = mock, ns = wum._holoTest.ns, sent = 0}
end

local function lobby(ms, owner, extra)
  local members = {}
  for _, m in ipairs(ms) do members[#members + 1] = {id = m.id, name = "N" .. m.id, peer = true} end
  for _, x in ipairs(extra or {}) do members[#members + 1] = x end
  for _, m in ipairs(ms) do
    local mem = MW.deepcopy(members)
    for _, x in ipairs(mem) do
      x.me = x.id == m.id
      x.host = x.id == owner
    end
    m.mock.setLobby{lobby = "L", me = m.id, owner = owner, isHost = m.id == owner, phase = "lobby", members = mem}
  end
end

local function connect(ms)
  for _, m in ipairs(ms) do
    local others = {}
    for _, o in ipairs(ms) do if o ~= m then others[#others + 1] = o.id end end
    m.mock.setPeers(others)
    for _, o in ipairs(ms) do
      if o ~= m then m.mock.channel.clocks[o.id] = {offset = 0, rtt = 42, samples = 5} end
    end
  end
end

local function step(ms, n)
  for _ = 1, n or 1 do
    for _, m in ipairs(ms) do m.mock.frame() end
    for _, m in ipairs(ms) do
      for _, o in ipairs(ms) do
        if o ~= m and m.mock.channel then o.mock.channel.presences[m.id] = MW.deepcopy(m.mock.channel.presenceMine) end
      end
    end
    for _, m in ipairs(ms) do
      while m.sent < #m.mock.peerSent do
        m.sent = m.sent + 1
        local r = m.mock.peerSent[m.sent]
        for _, o in ipairs(ms) do
          if o.id == r.to then o.mock.peerDeliver(m.id, MW.deepcopy(r.tbl), {reliable = true}) end
        end
      end
    end
  end
end

local function regions(m)
  local out = {}
  for _, r in ipairs(m.mock.regions()) do out[r.id] = r end
  return out
end

local function clickRegion(m, id)
  local r = regions(m)[id]
  if not r then return nil end
  local hit = m.mock.click((r.x0 + r.x1) / 2, (r.y0 + r.y1) / 2)
  m.mock.frame()
  return hit
end

local function texts(m)
  local out = {}
  for _, c in ipairs(m.mock.drawOf("hudText")) do out[#out + 1] = tostring(c.args[3]) end
  return out
end

local function hasText(m, needle)
  for _, t in ipairs(texts(m)) do if t:find(needle, 1, true) then return true end end
  return false
end

local function exactText(m, s)
  for _, t in ipairs(texts(m)) do if t == s then return true end end
  return false
end

local function key(m, k, mods)
  local e = {key = k, down = true, ["repeat"] = false}
  for a, v in pairs(mods or {}) do e[a] = v end
  m.mock.emitNow("melange.input.key", e)
end

local function iconDrawn(m, name)
  local ic = m.ns.SKIN.atlas.icons.rects[name][1]
  for _, c in ipairs(m.mock.drawOf("hudImageUV")) do
    if near(c.args[6], ic.x / 888, 0.0005) and near(c.args[7], ic.y / 962, 0.0005) then return true end
  end
  return false
end

-- 1. the panel opens with the hotkey, centred, 960x640 at 1080p; the link box adds a link with Enter
do
  local A = machine("A")
  A.mock.frame()
  A.mock.hotkey("F6")
  A.mock.frame()
  check(A.ns.PARTY.setupOpen(), "F6 opens the panel")
  local rs = regions(A)
  local p = rs["setup.panel"]
  check(p and near(p.x1 - p.x0, 960) and near(p.y1 - p.y0, 640) and near(p.x0, 480) and near(p.y0, 220),
    "960x640 centred")
  check(rs["setup.link"] and rs["setup.link"].opts.cursor == "ibeam", "link box")
  check(hasText(A, "Paste a YouTube"), "placeholder and hint")
  clickRegion(A, "setup.link")
  check(A.mock.focused(), "focus on click")
  A.mock.emitNow("melange.input.paste", {text = "not a link"})
  A.mock.frame()
  check(iconDrawn(A, "cross") and hasText(A, "Not a link Holo can play"), "classify cross")
  key(A, "A", {ctrl = true})
  A.mock.emitNow("melange.input.paste", {text = VID1})
  A.mock.frame()
  check(iconDrawn(A, "check") and hasText(A, "YouTube video"), "classify tick")
  key(A, "RETURN")
  A.mock.frame()
  check(A.ns.QUEUE.count() == 1 and A.ns.SETUP.linkState().text == "", "Enter adds and clears the box")
  A.mock.frame()
  check(hasText(A, "Added to the queue"), "status line")
  -- the Add button too; and a bad link is refused with a reason
  A.ns.SETUP.linkState().text = "https://example.com/x"
  A.mock.frame()
  key(A, "RETURN")
  A.mock.frame()
  A.mock.frame()
  check(A.ns.QUEUE.count() == 1 and hasText(A, "That is not a YouTube or magnet link"), "refused with a reason")
  -- Close
  clickRegion(A, "setup.close")
  check(not A.ns.PARTY.setupOpen() and not A.mock.focused(), "Close closes and drops the focus")
  local errs = A.mock.logsOf("error")
  check(#errs == 0, "no errors: " .. tostring(errs[1]))
end

-- 2. the queue list: 200 items, only the visible rows drawn, wheel scrolling, row buttons
do
  local A = machine("A")
  for i = 1, 200 do
    local it = A.ns.QUEUE.add(string.format("https://youtu.be/v%010d", i))
    check(it, "add " .. i)
  end
  for i, it in ipairs(A.ns.QUEUE.items()) do it.title, it.untitled = "Video " .. i, nil end
  check(A.ns.QUEUE.count() == 200, "200 queued")
  A.ns.PARTY.setSetup(true)
  A.mock.frames(2)
  local rows = 0
  for _, t in ipairs(texts(A)) do if t:match("^Video %d+$") then rows = rows + 1 end end
  check(rows > 3 and rows <= 12, "only the visible rows are drawn: " .. rows)
  check(hasText(A, "Queue (200)"), "count in the header")
  local clipOk = false
  for _, c in ipairs(A.mock.drawCalls()) do if c.fn == "hudClip" then clipOk = true end end
  check(clipOk, "the list is clipped")
  check(exactText(A, "Video 1") and not exactText(A, "Video 50"), "row 50 not drawn at the top")
  A.mock.emitNow("melange.input.wheel", {region = "setup.list", delta = -20, x = 700, y = 600})
  A.mock.frames(2)
  check(exactText(A, "Video 31") and not exactText(A, "Video 1"), "scrolled down 30 rows")
  A.mock.emitNow("melange.input.wheel", {region = "setup.list", delta = 100, x = 700, y = 600})
  A.mock.frames(2)
  check(exactText(A, "Video 1"), "scrolled back to the top")
  local first = A.ns.QUEUE.items()[1]
  clickRegion(A, "setup.dn." .. first.id)
  check(A.ns.QUEUE.items()[2] == first, "move down")
  A.mock.frame()
  clickRegion(A, "setup.up." .. first.id)
  check(A.ns.QUEUE.items()[1] == first, "move up")
  A.mock.frame()
  clickRegion(A, "setup.rm." .. first.id)
  check(A.ns.QUEUE.count() == 199 and A.ns.QUEUE.items()[1] ~= first, "remove")
  local errs = A.mock.logsOf("error")
  check(#errs == 0, "no errors: " .. tostring(errs[1]))
end

-- 3. the torrent file picker: video files only, largest preselected, pick another, Add
do
  local A = machine("A")
  A.ns.PARTY.setSetup(true)
  A.mock.frame()
  A.ns.SETUP.linkState().text = MAGNET
  A.mock.frame()
  check(hasText(A, "Torrent: Show"), "magnet classified")
  clickRegion(A, "setup.add")
  check(#A.mock.torrents == 1, "torrent opened for its file list")
  A.mock.torrentFiles({
    {index = 0, path = "Show/readme.txt", size = 10, video = false},
    {index = 1, path = "Show/ep1.mkv", size = 700 * 1048576, video = true},
    {index = 2, path = "Show/ep2.mkv", size = 1500 * 1048576, video = true},
    {index = 3, path = "Show/ep3.mp4", size = 300 * 1048576, video = true},
  })
  A.mock.frame()
  local rs = regions(A)
  check(rs["setup.pick"] and rs["setup.file.1"] and rs["setup.file.3"] and not rs["setup.file.4"], "picker: 3 videos")
  check(rs["setup.panel"] and not rs["setup.add"], "the panel under the modal takes no clicks")
  check(hasText(A, "ep2") and hasText(A, "1.5 GB") and not hasText(A, "readme"), "names and sizes, videos only")
  check(A.ns.SETUP.picks()[1].sel == 2, "the largest is preselected")
  clickRegion(A, "setup.file.3")
  check(A.ns.SETUP.picks()[1].sel == 3, "pick ep3")
  clickRegion(A, "setup.pickok")
  local it = A.ns.QUEUE.items()[1]
  check(it and it.kind == "bt" and it.file == 3 and it.title == "ep3", "added the picked file")
  check(#A.ns.SETUP.picks() == 0, "picker closed")
  -- cancel closes the torrent
  A.ns.SETUP.linkState().text = "magnet:?xt=urn:btih:" .. string.rep("ef", 20)
  A.mock.frame()
  clickRegion(A, "setup.add")
  A.mock.torrentFiles({{index = 0, path = "a.mkv", size = 5, video = true}, {index = 1, path = "b.mkv", size = 9,
    video = true}})
  A.mock.frame()
  clickRegion(A, "setup.pickno")
  check(#A.ns.SETUP.picks() == 0 and A.mock.torrents[#A.mock.torrents].closed, "cancel closes the torrent")
  -- the picker opens the panel if it was closed
  A.ns.PARTY.setSetup(false)
  A.ns.QUEUE.add("magnet:?xt=urn:btih:" .. string.rep("12", 20))
  A.mock.torrentFiles({{index = 0, path = "a.mkv", size = 5, video = true}, {index = 1, path = "b.mkv", size = 9,
    video = true}})
  A.mock.frame()
  check(A.ns.PARTY.setupOpen() and regions(A)["setup.pick"], "a pick opens the panel")
  -- closing the panel cancels the pending pick
  A.ns.PARTY.setSetup(false)
  check(#A.ns.SETUP.picks() == 0 and A.mock.torrents[#A.mock.torrents].closed, "closing cancels the pick")
end

-- 4. lobby: players list, pack consent, Start; the peer's read-only panel
do
  local A, B = machine("A"), machine("B")
  local ms = {A, B}
  A.mock.pack.state = "missing"
  lobby(ms, "A", {{id = "C", name = "Carol"}})
  step(ms)
  connect(ms)
  step(ms, 3)
  A.ns.PARTY.setSetup(true)
  B.ns.PARTY.setSetup(true)
  step(ms, 2)
  check(hasText(A, "Players") and hasText(A, "You") and hasText(A, "NB") and hasText(A, "Carol"), "players listed")
  check(hasText(A, "no Holo") and hasText(A, "42 ms"), "Holo state and RTT")
  check(iconDrawn(A, "crown"), "the host's crown")
  check(hasText(A, "Media pack") and hasText(A, "GitHub") and hasText(A, "Documents"), "consent text")
  check(hasText(A, "swarm.") and not hasText(A, " ..."), "the consent text is shown in full (its last word, no ellipsis)")
  local r = regions(A)["setup.pack"]
  check(r and (r.x1 - r.x0) * (r.y1 - r.y0) < 1920 * 1080 / 4, "Download button, under a quarter of the window")
  A.ns.QUEUE.add(VID1)
  step(ms, 2)
  local st = regions(A)["setup.start"]
  clickRegion(A, "setup.start")
  check(st and A.ns.PARTY.role() == "none", "Start is disabled without the pack")
  clickRegion(A, "setup.pack")
  check(A.mock.installs == 1, "Download starts the install from the click")
  step(ms, 2)
  check(hasText(A, "Downloading"), "progress")
  A.mock.pack.state = "ready"
  step(ms, 2)
  check(not regions(A)["setup.pack"], "no consent block once ready")
  -- B, the peer
  check(hasText(B, "Only the host (NA) controls the party"), "peer read-only line")
  check(not regions(B)["setup.link"] and not regions(B)["setup.start"], "peer: no link box, no Start")
  clickRegion(A, "setup.start")
  check(A.ns.PARTY.role() == "host" and not A.ns.PARTY.setupOpen(), "Start starts and closes the panel")
  step(ms, 4)
  check(B.ns.PARTY.role() == "peer", "B joined")
  step(ms, 2)
  check(regions(B)["setup.leave"], "peer: Leave party")
  A.ns.PARTY.setSetup(true)
  step(ms, 2)
  check(regions(A)["setup.end"], "host: End party")
  clickRegion(A, "setup.end")
  check(A.ns.PARTY.role() == "none", "ended")
end

-- 6. a member's panel while the host's party runs: it can add, sees who added what, removes only its own items
do
  local A, B = machine("A"), machine("B")
  local ms = {A, B}
  lobby(ms, "A")
  step(ms)
  connect(ms)
  step(ms, 6)
  A.ns.PARTY.setSetup(true)
  B.ns.PARTY.setSetup(true)
  step(ms, 2)
  check(hasText(B, "Adding opens when they start the party"), "before the party: adding opens when the host starts")
  check(not regions(B)["setup.link"], "before the party: the link box is disabled")
  A.ns.QUEUE.add(VID1)
  check(A.ns.PARTY.start() == true, "party started")
  A.ns.PARTY.setSetup(true)
  step(ms, 10)
  check(B.ns.PARTY.role() == "peer" and B.ns.PARTY.canAdd(), "B joined and may add")
  check(hasText(B, "NA hosts this party. You can add videos") and not hasText(B, "Only the host"), "member header")
  check(hasText(B, "Paste a link to add it to NA's queue"), "placeholder names the host")
  check(regions(B)["setup.link"] ~= nil, "the link box is enabled")
  -- type a link and press Add
  B.ns.SETUP.linkState().text = "https://youtu.be/vid00000002"
  step(ms, 2)
  check(regions(B)["setup.add"] ~= nil, "Add is enabled for a valid link")
  local adds0 = 0
  for _, r in ipairs(B.mock.peerSent) do if r.tbl.t == "add" then adds0 = adds0 + 1 end end
  clickRegion(B, "setup.add")
  step(ms, 2)
  local adds1 = 0
  for _, r in ipairs(B.mock.peerSent) do if r.tbl.t == "add" then adds1 = adds1 + 1 end end
  check(adds1 == adds0 + 1 and B.ns.SETUP.linkState().text == "", "Add sends the link to the host and clears the box")
  step(ms, 60)
  check(select(1, B.ns.SETUP.status()) == "Added YouTube video", "status after the host's answer: " ..
    tostring(B.ns.SETUP.status()))
  check(A.ns.QUEUE.count() == 2 and B.ns.QUEUE.count() == 2, "both queues have the item")
  step(ms, 2)
  check(hasText(B, "by NB") and hasText(A, "by NB"), "the row shows who added it")
  local items = B.ns.QUEUE.items()
  check(items[2].byId == "B", "item 2 is B's")
  check(regions(B)["setup.rm." .. items[2].id] ~= nil, "B gets a remove button on its own item")
  check(regions(B)["setup.rm." .. items[1].id] == nil, "no remove button on the host's item")
  check(regions(B)["setup.up." .. items[2].id] == nil and regions(B)["setup.dn." .. items[2].id] == nil,
    "no reorder buttons for a member")
  check(regions(A)["setup.rm." .. items[1].id] ~= nil and regions(A)["setup.up." .. items[2].id] ~= nil,
    "the host keeps all its buttons")
  clickRegion(B, "setup.rm." .. items[2].id)
  step(ms, 60)
  check(A.ns.QUEUE.count() == 1 and B.ns.QUEUE.count() == 1, "the member's remove button removes its item")
  check(#A.mock.logsOf("error") == 0 and #B.mock.logsOf("error") == 0, "no errors")
end

-- 5. in a match: the panel brings the pointer, and closes when the pointer goes
do
  local A = machine("A")
  A.mock.cursorSource = nil
  A.mock.frame()
  A.mock.hotkey("F6")
  A.mock.frame()
  check(A.ns.PARTY.setupOpen() and A.mock.pointerActive(), "pointer on with the panel")
  check(next(regions(A)) == nil, "no regions before the pointer's cursor shows (the mouse sits at the centre)")
  A.mock.cursorSource = "pointer"
  A.mock.frame()
  A.wum.input.pointer(false)        -- a click outside / Esc / my turn ended it
  A.mock.frame()
  check(not A.ns.PARTY.setupOpen(), "the panel closes with the pointer")
  A.mock.hotkey("F6")
  A.mock.frame()
  A.mock.hotkey("F6")
  A.mock.frame()
  check(not A.ns.PARTY.setupOpen() and not A.mock.pointerActive(), "closing the panel releases the pointer")
end

-- 7. the Videos / Music tabs, the Music tab, and the library modal over the panel (Holo 1.1, with wum.spotify)
do
  local FS = require("fake_spotify")
  local function machineFS(id)
    local wum, mock = MW.new()
    local fs = FS.install(wum, mock)
    fs.account = {user = "U" .. id, premium = true}
    fs.status = {state = "connected", linked = true, user = "U" .. id, premium = true}
    fs.library.tracks = {FS.song(1), FS.song(2), FS.song(3, {playable = false})}
    fs.library.playlists = {{id = string.rep("p", 22), uri = "spotify:playlist:" .. string.rep("p", 22),
      name = "Road trip", owner = "Bee", tracks = 60}}
    local list = {}
    for n = 1, 60 do list[n] = FS.song(100 + n) end
    fs.library["playlist:" .. string.rep("p", 22)] = list
    wum._holoTest = {}
    local _, ok, err = MW.load("mod/client/init.lua", wum)
    check(ok, id .. ": init.lua runs: " .. tostring(err))
    mock.cursorSource = "frontend"
    mock.cursorPos = {2, 2}
    return {id = id, wum = wum, mock = mock, ns = wum._holoTest.ns, sent = 0, fs = fs}
  end

  local A = machineFS("A")
  A.ns.PARTY.setSetup(true)
  step({A}, 2)
  check(regions(A)["setup.tab.videos"] ~= nil and regions(A)["setup.tab.music"] ~= nil, "two tab buttons")
  check(A.ns.SETUP.tab() == "videos" and regions(A)["setup.link"] ~= nil, "Videos first: the link box")
  clickRegion(A, "setup.tab.music")
  step({A}, 2)
  check(A.ns.SETUP.tab() == "music", "Music tab")
  check(regions(A)["setup.link"] == nil and regions(A)["setup.list"] == nil, "no link box or video queue")
  check(hasText(A, "Music queue (0)") and hasText(A, "Nothing playing"), "the Music tab draws")
  check(regions(A)["music.browse"] ~= nil and regions(A)["music.play"] ~= nil, "browse and the host's buttons")
  check(regions(A)["setup.close"] ~= nil, "the footer is still there")
  -- the library modal
  clickRegion(A, "music.browse")
  check(A.ns.MUI.libOpen(), "the library opens")
  step({A}, 10)
  check(#A.fs.callsOf("library") == 1 and A.fs.callsOf("library")[1].args[1].kind == "tracks", "liked songs asked")
  check(regions(A)["music.lib.add.1"] ~= nil and regions(A)["music.lib.add.3"] ~= nil, "song rows")
  check(regions(A)["music.browse"] == nil and regions(A)["setup.tab.videos"] == nil and regions(A)["setup.close"] == nil,
    "the base panel takes no clicks under the modal (W.active false)")
  check(regions(A)["setup.panel"] ~= nil, "the panel still covers the game")
  clickRegion(A, "music.lib.add.1")
  check(A.ns.MUSIC.count() == 1 and A.ns.MUSIC.items()[1].uri == FS.uri(1), "music.lib.add.1 adds the song")
  clickRegion(A, "music.lib.add.3")
  check(A.ns.MUSIC.count() == 1, "an unplayable song is not added")
  -- playlists, a playlist, paging, "Add all loaded"
  clickRegion(A, "music.lib.lists")
  step({A}, 10)
  check(hasText(A, "Road trip") and regions(A)["music.lib.open.1"] ~= nil, "playlists")
  clickRegion(A, "music.lib.open.1")
  step({A}, 10)
  local lib = A.ns.MUI.library()
  check(lib.view == "playlist" and #lib.rows == 50 and lib.next == true, "first page of 50")
  check(regions(A)["music.lib.more"] ~= nil and regions(A)["music.lib.back"] ~= nil, "Load more and Back")
  clickRegion(A, "music.lib.more")
  step({A}, 10)
  check(#lib.rows == 60 and lib.next == false, "second page")
  local calls = A.fs.callsOf("library")
  check(calls[#calls].args[1].offset == 50 and calls[#calls].args[1].id == string.rep("p", 22), "offset 50")
  clickRegion(A, "music.lib.all")
  check(A.ns.MUSIC.count() == 61, "Add all loaded: " .. A.ns.MUSIC.count())
  -- a playlist Spotify does not let apps read
  A.fs.library["playlist:" .. string.rep("p", 22)] = nil
  clickRegion(A, "music.lib.back")
  step({A}, 10)
  clickRegion(A, "music.lib.open.1")
  step({A}, 10)
  check(hasText(A, "Spotify does not let apps read this playlist"), "not-found explained")
  -- closing the panel closes the library
  A.ns.PARTY.setSetup(false)
  step({A}, 2)
  check(not A.ns.MUI.libOpen(), "a closed panel closes the library")
  A.ns.SETUP.setTab("videos")
  check(#A.mock.logsOf("error") == 0, "no errors: " .. table.concat(A.mock.logsOf("error"), "; "))
  -- a member adds through the library: it goes to the host
  local H, B = machineFS("H"), machineFS("B")
  H.fs.status = {state = "disconnected", linked = false}
  lobby({H, B}, "H")
  connect({H, B})
  step({H, B}, 10)
  B.ns.PARTY.setSetup(true)
  B.ns.SETUP.setTab("music")
  step({H, B}, 2)
  check(hasText(B, "NH hosts the music. You can add songs"), "member header on the Music tab")
  check(regions(B)["music.play"] == nil and regions(B)["music.listen"] ~= nil, "a member: Listen, no transport")
  clickRegion(B, "music.browse")
  step({H, B}, 10)
  clickRegion(B, "music.lib.add.2")
  step({H, B}, 60)
  check(H.ns.MUSIC.count() == 1 and H.ns.MUSIC.items()[1].by == "NB", "the host got B's song")
  check(B.ns.MUSIC.count() == 1, "B's mirror")
  B.ns.MUI.closeLibrary()
  step({H, B}, 2)
  local id = B.ns.MUSIC.items()[1].id
  check(regions(B)["music.rm." .. id] ~= nil and regions(B)["music.up." .. id] == nil, "B removes only its own")
  check(H.ns.SETUP.tab() == "videos", "tabs are per machine")
  check(#B.mock.logsOf("error") == 0 and #H.mock.logsOf("error") == 0, "no errors")
end

if fails > 0 then
  io.stderr:write("test_setup: " .. fails .. " failure(s)\n")
  os.exit(1)
end
print("test_setup: all checks passed")
