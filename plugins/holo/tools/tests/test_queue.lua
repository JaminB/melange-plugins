-- QUEUE (src/45_queue.lua): adding links, playlists and torrents, editing, the wire pages and their checks.
local MW = require("mock_wum")

local fails = 0
local function check(cond, what)
  if not cond then
    fails = fails + 1
    io.stderr:write("  FAIL: " .. what .. "\n")
  end
end

local function loadHolo(mutate)
  local wum, mock = MW.new()
  wum._holoTest = {}
  if mutate then mutate(wum, mock) end
  local _, ok, err = MW.load("mod/client/init.lua", wum)
  check(ok, "init.lua runs: " .. tostring(err))
  return wum, mock, wum._holoTest.ns
end

local function yt(i) return string.format("https://youtu.be/vid%08d", i) end
local function magnet(i, extra) return "magnet:?xt=urn:btih:" .. string.format("%040x", i) .. (extra or "") end

-- 1. a YouTube video: added at once, its title filled by resolve
do
  local wum, mock, ns = loadHolo()
  local Q, U = ns.QUEUE, ns.U
  local changes = 0
  U.on("queue.changed", function() changes = changes + 1 end)
  local v0 = Q.version()
  check(Q.add("  https://youtu.be/dQw4w9WgXcQ  ") == true, "add video")
  check(Q.count() == 1 and Q.items()[1].kind == "yt" and Q.items()[1].url == "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
    "canonical url stored")
  check(Q.items()[1].title == "YouTube video" and Q.version() > v0 and changes == 1, "placeholder title, new version")
  check(#mock.resolves == 1 and mock.resolves[1].url == Q.items()[1].url, "title resolve asked")
  mock.resolveDone({items = {{url = Q.items()[1].url, id = "dQw4w9WgXcQ", title = "Never\nGonna " .. string.rep("x", 300),
    duration = 212}}})
  check(utf8.len(Q.items()[1].title) == 120 and Q.items()[1].title:sub(1, 11) == "Never Gonna" and Q.items()[1].duration == 212,
    "title and duration filled, trimmed to 120")
  check(select(2, Q.add("http://evil.example/x")) == "unsupported-url", "refused url")
  check(select(2, Q.add(42)) == "unsupported-url", "non-string refused")
end

-- 2. a playlist: resolved, every playable item appended, bad ones skipped
do
  local wum, mock, ns = loadHolo()
  local Q, U = ns.QUEUE, ns.U
  local toasts = {}
  U.on("party.toast", function(t, k) toasts[#toasts + 1] = k .. ":" .. t end)
  check(Q.add("https://www.youtube.com/playlist?list=PL123") == true and Q.count() == 0, "playlist pending")
  mock.resolveDone({title = "Mix", items = {
    {url = yt(1), title = "One", duration = 10},
    {url = "https://evil.example/2", title = "Bad"},
    {url = yt(3), title = "", duration = 0 / 0},
    "junk"}})
  check(Q.count() == 2 and Q.items()[1].title == "One" and Q.items()[2].title == "YouTube video", "two appended")
  check(Q.items()[2].duration == 0, "NaN duration dropped")
  check(toasts[#toasts] == "info:Added 2 videos", "toast: " .. tostring(toasts[#toasts]))
  Q.add("https://www.youtube.com/playlist?list=PLx")
  mock.resolveDone({error = "private"})
  check(toasts[#toasts] == "error:That playlist is private", "private playlist toast")
end

-- 3. magnets: the picker lists video files only, largest first; one video is picked by itself
do
  local wum, mock, ns = loadHolo()
  local Q, U = ns.QUEUE, ns.U
  local picks = {}
  U.on("queue.pick", function(token, files, name) picks[#picks + 1] = {token, files, name} end)
  check(Q.add(magnet(1, "&dn=Show")) == true and #mock.torrents == 1, "torrent started for the file list")
  mock.torrentFiles({{index = 0, path = "Show/readme.txt", size = 5, video = false},
    {index = 1, path = "Show/ep1.mkv", size = 700, video = true},
    {index = 2, path = "Show/ep2.mkv", size = 900, video = true},
    {index = 3, path = "Show/list.m3u", size = 1, video = false}})
  check(#picks == 1 and #picks[1][2] == 2 and picks[1][2][1].index == 2 and picks[1][2][2].index == 1,
    "picker: videos only, largest first")
  check(Q.count() == 0, "nothing added before the pick")
  check(Q.pickFile(picks[1][1], 3) == nil, "a non-video index is refused")
  check(Q.pickFile(picks[1][1], 1) == true and Q.count() == 1, "picked")
  local it = Q.items()[1]
  check(it.kind == "bt" and it.file == 1 and it.title == "ep1" and it.url == magnet(1):lower(), "torrent item")
  check(Q.pickFile(picks[1][1], 1) == nil, "a token is used once")
  -- one video file: no picker
  Q.add(magnet(2))
  mock.torrentFiles({{index = 4, path = "movie.mp4", size = 10, video = true}})
  check(#picks == 1 and Q.count() == 2 and Q.items()[2].file == 4, "single video picked by itself")
  -- no video: a warning, the torrent closed
  local toasts = {}
  U.on("party.toast", function(t) toasts[#toasts + 1] = t end)
  Q.add(magnet(3))
  local t3 = mock.torrents[#mock.torrents]
  mock.torrentFiles({{index = 0, path = "a.txt", size = 1, video = false}})
  check(toasts[1] == "No video file in this torrent" and t3.closed and Q.count() == 2, "no video")
  -- cancel closes an unused torrent
  Q.add(magnet(4))
  local t4 = mock.torrents[#mock.torrents]
  mock.torrentFiles({{index = 0, path = "a.mkv", size = 1, video = true}, {index = 1, path = "b.mkv", size = 2, video = true}})
  check(Q.cancelPick(picks[#picks][1]) == true and t4.closed and Q.count() == 2, "cancelPick")
  -- refused by the core (first use in a match)
  wum.media.torrent = function() return nil, "first-use-in-match" end
  check(select(2, Q.add(magnet(5))) == "first-use-in-match", "core reason passed on")
end

-- 4. remove, move, current, step, the cap
do
  local wum, mock, ns = loadHolo()
  local Q = ns.QUEUE
  for i = 1, 4 do Q.add(yt(i)) end
  local ids = {}
  for i, it in ipairs(Q.items()) do ids[i] = it.id end
  check(Q.move(ids[1], 2) == true and Q.items()[3].id == ids[1], "move down 2")
  check(Q.move(ids[1], -10) == true and Q.items()[1].id == ids[1], "move clamps at the top")
  check(Q.move(ids[1], -1) == false, "no move past the top")
  check(Q.setCurrent(ids[2]) and Q.current().id == ids[2] and Q.currentIndex() == 2, "current")
  check(Q.step(1).id == ids[3] and Q.step(-1).id == ids[1], "step")
  check(Q.remove(ids[2]) == true and Q.current() == nil and Q.count() == 3, "remove the current item")
  check(select(2, Q.remove(999)) == "unknown", "remove unknown")
  check(Q.setCurrent(12345) == false, "setCurrent unknown")
  for i = 5, 250 do Q.add(yt(i)) end
  check(Q.count() == 200 and select(2, Q.add(yt(999))) == "full", "capped at 200")
end

-- 5. only the host edits: a peer (lobby owned by someone else) is refused
do
  local wum, mock, ns = loadHolo()
  mock.setLobby{lobby = "L", me = "B", owner = "A", isHost = false,
    members = {{id = "A", name = "A", host = true}, {id = "B", name = "B", me = true}}}
  mock.frame()
  check(select(2, ns.QUEUE.add(yt(1))) == "not-host", "a peer cannot add")
  check(select(2, ns.QUEUE.remove(1)) == "not-host", "a peer cannot remove")
end

-- 6. pages: a big queue of long magnets splits under the reliable cap and round-trips through a peer's mirror
do
  local wum, mock, ns = loadHolo()
  local Q, NET = ns.QUEUE, ns.NET
  local longTitle = string.rep("\208\150", 200)
  for i = 1, 60 do
    Q.add(magnet(i, "&dn=" .. string.rep("n", 150) .. "&tr=udp://tracker.example:1337/" .. string.rep("a", 600)))
    mock.torrentFiles({{index = 7, path = longTitle .. ".mkv", size = 1, video = true}})
  end
  Q.add(yt(1))
  Q.setCurrent(Q.items()[30].id)
  local pages = Q.pages()
  check(#pages > 1, "split into pages: " .. #pages)
  local total = 0
  for _, p in ipairs(pages) do
    check(NET.sizeOf(p) < 8192, "page under 8 KB: " .. NET.sizeOf(p))
    check(p.t == "q" and p.qv == Q.version() and p.pages == #pages and p.cur == Q.items()[30].id, "page header")
    total = total + #p.items
  end
  check(total == 61, "every item on a page")

  local w2, m2, ns2 = loadHolo()
  local Q2 = ns2.QUEUE
  Q2.resetVersion()
  local order = {}
  for i = #pages, 1, -1 do order[#order + 1] = pages[i] end   -- out of order
  for i, p in ipairs(order) do
    local r = Q2.acceptPage(MW.deepcopy(p))
    if i < #order then check(r == false, "incomplete until the last page") else check(r == true, "complete") end
  end
  check(Q2.count() == 61 and Q2.version() == Q.version(), "mirror replaced")
  check(Q2.current() and Q2.current().id == Q.items()[30].id, "mirror current")
  check(Q2.items()[1].url == Q.items()[1].url and Q2.items()[1].file == 7 and utf8.len(Q2.items()[1].title) == 120,
    "items intact")
  check(Q2.acceptPage(MW.deepcopy(pages[1])) == nil, "the same version again is ignored")
  -- an empty queue is one page with no items
  local w3, m3, ns3 = loadHolo()
  local ep = ns3.QUEUE.pages()
  check(#ep == 1 and #ep[1].items == 0, "empty queue page")
end

-- 7. wire checks on received items and pages
do
  local wum, mock, ns = loadHolo()
  local Q = ns.QUEUE
  local C = Q.checkWire
  check(C({id = 1, k = "yt", u = "https://youtu.be/dQw4w9WgXcQ", ti = "a"}).url == "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
    "a video is re-classified to the canonical url")
  check(C({id = 1, k = "yt", u = "http://evil.example/"}) == nil, "bad url")
  check(C({id = 1, k = "yt", u = magnet(1)}) == nil, "kind mismatch yt/magnet")
  check(C({id = 1, k = "bt", u = magnet(1)}) == nil, "a torrent item needs a file")
  check(C({id = 1, k = "bt", u = magnet(1), f = -1}) == nil and C({id = 1, k = "bt", u = magnet(1), f = 1.5}) == nil,
    "bad file index")
  check(C({id = 1, k = "bt", u = magnet(1), f = 2}).file == 2, "torrent item")
  check(C({id = 0, k = "yt", u = yt(1)}) == nil and C({id = "1", k = "yt", u = yt(1)}) == nil, "bad id")
  check(C({id = 1, k = "zz", u = yt(1)}) == nil, "unknown kind")
  check(C({id = 1, k = "yt", u = yt(1), ti = string.rep("y", 500), d = 1 / 0}).duration == 0, "infinite duration")
  check(#C({id = 1, k = "yt", u = yt(1), ti = string.rep("y", 500)}).title == 120, "title trimmed")
  -- pages: malformed headers are refused, bad items are dropped from a good page, at most 200 items
  Q.resetVersion()
  check(Q.acceptPage({t = "q", qv = 1, page = 2, pages = 1, items = {}}) == nil, "page > pages")
  check(Q.acceptPage({t = "q", qv = 1, page = 1, pages = 100, items = {}}) == nil, "too many pages")
  check(Q.acceptPage({t = "q", qv = 1.5, page = 1, pages = 1, items = {}}) == nil, "float version")
  local many = {}
  for i = 1, 250 do many[i] = {id = i, k = "yt", u = yt(i), ti = "t"} end
  many[3] = {id = 3, k = "yt", u = "javascript:alert(1)"}
  check(Q.acceptPage({t = "q", qv = 7, page = 1, pages = 1, items = many, cur = 3}) == true, "accepted")
  check(Q.count() == 200 and Q.find(3) == nil and Q.current() == nil, "bad item dropped, capped, cur unknown")
  -- a new version restarts the assembly
  check(Q.acceptPage({t = "q", qv = 8, page = 1, pages = 2, items = {many[1]}}) == false, "v8 part 1")
  check(Q.acceptPage({t = "q", qv = 9, page = 1, pages = 1, items = {many[2]}}) == true and Q.count() == 1, "v9 wins")
  check(Q.setFile(2, 5) == false, "setFile only on torrent items")
end

-- 8. snapshot and load (continue party, last queue)
do
  local wum, mock, ns = loadHolo()
  local Q = ns.QUEUE
  for i = 1, 3 do Q.add(yt(i)) end
  Q.setCurrent(Q.items()[2].id)
  local snap = Q.snapshot()
  local w2, m2, ns2 = loadHolo()
  snap.items[3].url = "http://evil.example/"
  local cur = ns2.QUEUE.load(snap)
  check(ns2.QUEUE.count() == 2, "load re-checks the items")
  check(cur and ns2.QUEUE.find(cur).url == Q.items()[2].url and ns2.QUEUE.current().id == cur, "current kept")
end

if fails > 0 then
  io.stderr:write(fails .. " check(s) failed\n")
  os.exit(1)
end
print("test_queue: all checks passed")
