-- U (src/10_util.lua): the math and text helpers and the debounced preferences.
local MW = require("mock_wum")

local fails = 0
local function check(cond, what)
  if not cond then
    fails = fails + 1
    io.stderr:write("  FAIL: " .. what .. "\n")
  end
end

local wum, mock = MW.new()
wum._holoTest = {}
local _, ok, err = MW.load("mod/client/init.lua", wum)
check(ok, "init.lua runs: " .. tostring(err))
local U = wum._holoTest.ns.U

-- math
check(U.clamp(5, 0, 3) == 3 and U.clamp(-1, 0, 3) == 0 and U.clamp(2, 0, 3) == 2, "clamp")
check(U.lerp(10, 20, 0.25) == 12.5, "lerp")
check(U.easeOutCubic(0) == 0 and U.easeOutCubic(1) == 1 and math.abs(U.easeOutCubic(0.5) - 0.875) < 1e-9,
  "easeOutCubic")
check(U.easeOutCubic(2) == 1 and U.easeOutCubic(-1) == 0, "easeOutCubic clamps")
check(U.num(1.5) == 1.5 and U.num(0 / 0) == nil and U.num(math.huge) == nil and U.num("3") == nil, "num")

-- fmtTime
check(U.fmtTime(0) == "0:00", "fmtTime 0")
check(U.fmtTime(754) == "12:34", "fmtTime 12:34: " .. U.fmtTime(754))
check(U.fmtTime(3731) == "1:02:11", "fmtTime 1:02:11: " .. U.fmtTime(3731))
check(U.fmtTime(59.9) == "0:59", "fmtTime floors")
check(U.fmtTime(nil) == "0:00" and U.fmtTime(-5) == "0:00" and U.fmtTime(0 / 0) == "0:00", "fmtTime bad input")

-- trim
check(U.trim("  hello  ") == "hello", "trim spaces")
check(U.trim("a\nb\tc") == "a b c", "control characters become spaces")
check(U.trim("abcdef", 3) == "abc", "trim to n")
check(U.trim("h\195\169llo", 2) == "h\195\169", "trim counts characters, not bytes")
check(U.trim("\255ab\128c") == "abc", "broken UTF-8 bytes are dropped")
check(U.trim(nil) == "" and U.trim(42) == "", "non-strings give an empty string")
local long = string.rep("\208\150", 200)   -- 200 Cyrillic characters
check(utf8.len(U.trim(long, 120)) == 120, "trim 120 characters of a 2-byte script")

-- copy
local a = {x = {1, 2}}
local b = U.copy(a)
b.x[1] = 9
check(a.x[1] == 1, "copy is deep")

-- now follows the peer clock
check(U.now() == wum.peer.now(), "now is wum.peer.now()")

-- prefs: default, set, debounced save (1 s after the last change)
check(U.pref("nothing", 7) == 7, "pref default")
U.setPref("volume", 33)
check(U.pref("volume") == 33, "pref reads back at once")
mock.frames(30)                      -- 0.5 s
check(mock.storageData.prefs == nil, "not saved before 1 s")
U.setPref("mute", true)              -- a second change restarts the wait
mock.frames(42)                      -- 0.7 s after the second change
check(mock.storageData.prefs == nil, "the wait restarts with each change")
mock.frames(45)                      -- the save check runs every 0.25 s
check(mock.storageData.prefs and mock.storageData.prefs.volume == 33 and mock.storageData.prefs.mute == true,
  "saved once quiet for 1 s")
U.setPref("list", {1, 2})
U.flushPrefs()
check(mock.storageData.prefs.list[2] == 2, "flushPrefs saves at once")

-- prefs survive a reload (read from storage)
do
  local w2, m2 = MW.new()
  m2.storageData.prefs = {volume = 12}
  w2._holoTest = {}
  MW.load("mod/client/init.lua", w2)
  check(w2._holoTest.ns.U.pref("volume") == 12, "prefs load from storage")
end

if fails > 0 then
  io.stderr:write(fails .. " check(s) failed\n")
  os.exit(1)
end
print("test_util: all checks passed")
