-- Scaffold test: the generated init.lua loads in the sandbox environment against the mock, the namespaces and the
-- in-file bus behave as the contract says, and the version gate stops Holo on an old Melange.
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
  local env, ok, err = MW.load("mod/client/init.lua", wum)
  return wum, mock, wum._holoTest.ns, ok, err
end

-- 1. Loads cleanly and exposes every namespace table.
do
  local wum, mock, ns, ok, err = loadHolo()
  check(ok, "init.lua runs: " .. tostring(err))
  check(ns ~= nil, "header exposes namespaces to tests")
  for _, k in ipairs{"U", "CFG", "NET", "PARTY", "QUEUE", "SPOT", "MUSIC", "LAYOUT", "SKIN", "W", "PUI", "SETUP", "MUI",
    "MAIN"} do
    check(ns and type(ns[k]) == "table", "namespace " .. k)
  end
end

-- 1b. Holo loads with and without wum.spotify (Melange 0.13 and 0.12): the gate stays at 0.12.
do
  local FS = require("fake_spotify")
  local wum, mock, ns, ok, err = loadHolo(function(w, m) FS.install(w, m) end)
  check(ok and ns ~= nil and ns.SPOT.has() == true, "loads with wum.spotify: " .. tostring(err))
  mock.frames(130)
  check(#mock.logsOf("error") == 0 and #mock.logsOf("warn") == 0, "no errors or warnings with wum.spotify")
  local wum2, mock2, ns2, ok2 = loadHolo()
  check(ok2 and ns2 ~= nil and ns2.SPOT.has() == false, "loads without wum.spotify")
  mock2.frames(130)
  check(#mock2.logsOf("error") == 0 and #mock2.logsOf("warn") == 0, "no errors or warnings without it")
  local f = assert(io.open("mod/spice.json", "rb"))
  local spice = f:read("a")
  f:close()
  check(spice:find('"range": ">=0.12.0"', 1, true) ~= nil, "melange.range stays >=0.12.0")
  check(not spice:find('"network"', 1, true), "no network permission")
end

-- 2. The bus: synchronous, subscription order, off(), a raising listener does not stop the others.
do
  local wum, mock, ns = loadHolo()
  local U = ns.U
  local seen = {}
  local a = function(x) seen[#seen + 1] = "a" .. x end
  U.on("t", a)
  U.on("t", function() error("boom") end)
  U.on("t", function(x) seen[#seen + 1] = "c" .. x end)
  U.emit("t", 1)
  check(table.concat(seen, ",") == "a1,c1", "emit order and isolation: " .. table.concat(seen, ","))
  check(#mock.logsOf("error") == 1, "a raising listener is logged once")
  check(U.off("t", a) == true and U.off("t", a) == false, "off removes once")
  seen = {}
  U.emit("t", 2)
  check(table.concat(seen, ",") == "c2", "off took effect")
  U.emit("nobody", 1) -- no listeners: nothing happens
  -- A listener may unsubscribe itself while the event is delivered.
  local n = 0
  local self
  self = U.on("once", function() n = n + 1; U.off("once", self) end)
  U.on("once", function() n = n + 10 end)
  U.emit("once"); U.emit("once")
  check(n == 21, "self-unsubscribe during emit: " .. n)
end

-- 3. guard: three strikes in a row stop the piece; a success resets the count.
do
  local _, mock, ns = loadHolo()
  local U = ns.U
  local calls, failNow = 0, true
  local g = U.guard("piece", function(x) calls = calls + 1; if failNow then error("bad") end; return x, "second" end)
  g(); g()
  failNow = false
  local a, b = g(5)
  check(a == 5 and b == "second", "guard passes results through")
  failNow = true
  g(); g()
  check(calls == 5, "success reset the strikes (calls=" .. calls .. ")")
  g()
  check(calls == 6, "third strike still runs")
  g(); g()
  check(calls == 6, "stopped after three strikes")
  local msgs = mock.logsOf("error")
  local stopped = 0
  for _, m in ipairs(msgs) do if m:find("stopped after 3 errors", 1, true) then stopped = stopped + 1 end end
  check(stopped == 1, "the stop is logged once")
end

-- 4. The version gate: a Melange without wum.draw.hudNine (0.11) logs and stops; nothing leaks out.
do
  local wum, mock, ns, ok, err = loadHolo(function(w) w.draw.hudNine = nil end)
  check(ok, "gate returns without raising")
  check(ns == nil, "gate stops before the namespaces exist")
  check(#mock.logsOf("warn") == 1 and mock.logsOf("warn")[1]:find("0.12", 1, true), "gate logs a warning naming 0.12")
  check(#mock.drawCalls() == 0, "no draw callbacks registered")
  mock.frame()
end
do
  local _, _, ns = loadHolo(function(w) w.media = nil end)
  check(ns == nil, "gate: no wum.media")
  local _, _, ns2 = loadHolo(function(w) w.peer = nil end)
  check(ns2 == nil, "gate: no wum.peer")
end

-- 5. The stubs run under the frame loop, and the sandbox environment rejects what the game rejects.
do
  local wum, mock = loadHolo()
  mock.frames(3)
  check(mock.instructionCount >= 0, "instruction counter available")
  local env = MW.sandboxEnv(wum)
  check(env.load == nil and env.require == nil and env.io == nil and env.debug == nil, "sandbox hides load/require/io/debug")
  check(env.os.time and env.os.clock and not env.os.execute, "sandbox allows only os.time/clock/date")
end

if fails > 0 then
  io.stderr:write(fails .. " check(s) failed\n")
  os.exit(1)
end
print("test_build: all checks passed")
