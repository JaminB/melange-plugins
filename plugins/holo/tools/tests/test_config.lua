-- CFG (src/20_config.lua): settings read and sanitised, polled every 0.5 s, and the four hotkeys.
local MW = require("mock_wum")

local fails = 0
local function check(cond, what)
  if not cond then
    fails = fails + 1
    io.stderr:write("  FAIL: " .. what .. "\n")
  end
end

local function has(list, x)
  for _, v in ipairs(list) do if v == x then return true end end
  return false
end

local wum, mock = MW.new()
wum._holoTest = {}
local _, ok, err = MW.load("mod/client/init.lua", wum)
check(ok, "init.lua runs: " .. tostring(err))
local ns = wum._holoTest.ns
local U, CFG = ns.U, ns.CFG

-- the defaults are spice.json's, and CFG knows every declared setting
check(CFG.get("volume") == 70 and CFG.get("quality") == "720" and CFG.get("keySetup") == "F6", "defaults")
for key, d in pairs(mock.declared) do
  check(CFG.DEFS[key] ~= nil, "CFG.DEFS has " .. key)
  check(CFG.get(key) == d.default, "default of " .. key)
end
for key in pairs(CFG.DEFS) do check(mock.declared[key] ~= nil, "spice.json declares " .. key) end

-- sanitise
check(CFG.sanitize("volume", 500) == 100 and CFG.sanitize("volume", -3) == 0, "int clamped")
check(CFG.sanitize("volume", 0 / 0) == 70 and CFG.sanitize("volume", "x") == 70, "bad int -> default")
check(CFG.sanitize("quality", "4320") == "720", "unknown option -> default")
check(CFG.sanitize("musicOff", "yes") == true and CFG.sanitize("musicOff", false) == false, "bool")

-- the four hotkeys are registered with their defaults
local keys = mock.hotkeys()
check(#keys == 4 and has(keys, "F6") and has(keys, "F7") and has(keys, "F9") and has(keys, "Ctrl+Shift+P"),
  "four hotkeys: " .. table.concat(keys, ","))
local fired = {}
U.on("hotkey", function(name) fired[#fired + 1] = name end)
mock.hotkey("F6"); mock.hotkey("F7"); mock.hotkey("F9"); mock.hotkey("Ctrl+Shift+P")
check(table.concat(fired, ",") == "setup,pointer,hide,play", "hotkey bus names: " .. table.concat(fired, ","))

-- a change is seen within 0.5 s, emits cfg.changed and re-registers the hotkey
local changes = {}
U.on("cfg.changed", function(k, v) changes[#changes + 1] = k .. "=" .. tostring(v) end)
wum.config.set("keySetup", "Ctrl+Shift+W")
wum.config.set("hiddenMutes", false)
mock.frames(31)
check(has(changes, "keySetup=Ctrl+Shift+W") and has(changes, "hiddenMutes=false"), "cfg.changed: "
  .. table.concat(changes, ","))
check(CFG.get("hiddenMutes") == false, "a false bool stays false")
keys = mock.hotkeys()
check(has(keys, "Ctrl+Shift+W") and not has(keys, "F6") and #keys == 4, "re-registered: " .. table.concat(keys, ","))
fired = {}
mock.hotkey("Ctrl+Shift+W")
check(fired[1] == "setup", "the new key fires setup")

-- a key that cannot be registered falls back to the default
mock.hotkeyRefuse = {["Alt+W"] = true}
wum.config.set("keySetup", "Alt+W")
mock.frames(31)
check(CFG.hotkeyKey("setup") == "F6" and has(mock.hotkeys(), "F6"), "fallback to the default")
check(#mock.logsOf("warn") >= 1, "the fallback is logged")
-- both the setting and its default refused: the remaining option
mock.hotkeyRefuse = {["Alt+H"] = true, F9 = true}
wum.config.set("keyHide", "Alt+H")
mock.frames(31)
check(CFG.hotkeyKey("hide") == "Ctrl+Shift+H", "fallback to another option: " .. tostring(CFG.hotkeyKey("hide")))

-- an out-of-range value written by hand reads as clamped, with one change event
changes = {}
mock.configValues.uiScale = 300
mock.frames(31)
check(CFG.get("uiScale") == 130 and changes[1] == "uiScale=130", "hand-edited value clamped")
mock.frames(31)
check(#changes == 1, "no repeated change event")

if fails > 0 then
  io.stderr:write(fails .. " check(s) failed\n")
  os.exit(1)
end
print("test_config: all checks passed")
