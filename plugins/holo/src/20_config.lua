-- config (P2): the spice.json settings, polled every 0.5 s, and the four hotkeys they name.
do
  -- The settings of spice.json with their defaults and limits, so a hand-edited Melange.ini with a value out of range
  -- or an option that no longer exists reads as the default instead of breaking a fragment.
  local DEFS = {
    volume = {"int", 70, 0, 100},
    quality = {"enum", "720", {"360", "480", "720", "1080"}},
    hiddenMutes = {"bool", true},
    autoHideAim = {"bool", true},
    panelSide = {"enum", "right", {"right", "left"}},
    bigOnOthers = {"bool", true},
    musicOff = {"bool", true},
    uiScale = {"int", 100, 80, 130},
    keySetup = {"enum", "F6", {"F6", "Ctrl+Shift+W", "Alt+W"}},
    keyPointer = {"enum", "F7", {"F7", "Ctrl+Shift+M", "Alt+M"}},
    keyHide = {"enum", "F9", {"F9", "Ctrl+Shift+H", "Alt+H"}},
    keyPlay = {"enum", "Ctrl+Shift+P", {"Ctrl+Shift+P", "Ctrl+F9"}},
  }
  CFG.DEFS = DEFS
  -- hotkey bus name -> setting
  local HOTKEYS = {setup = "keySetup", pointer = "keyPointer", hide = "keyHide", play = "keyPlay"}
  CFG.HOTKEYS = HOTKEYS
  local KEYS, NAMES = {}, {"setup", "pointer", "hide", "play"}
  for k in pairs(DEFS) do KEYS[#KEYS + 1] = k end
  table.sort(KEYS)

  local function sanitize(key, v)
    local d = DEFS[key]
    if not d then return v end
    if d[1] == "int" then
      v = U.num(v)
      if not v then return d[2] end
      return math.floor(U.clamp(v, d[3], d[4]))
    elseif d[1] == "bool" then
      if type(v) ~= "boolean" then return d[2] end
      return v
    end
    for _, o in ipairs(d[3]) do
      if o == v then return v end
    end
    return d[2]
  end
  CFG.sanitize = sanitize

  local values = {}

  local function read(key)
    local ok, v = pcall(wum.config.get, key)
    if not ok then v = nil end
    return sanitize(key, v)
  end

  function CFG.get(key)
    local v = values[key]
    if v == nil then
      v = read(key)
      values[key] = v
    end
    return v
  end

  -- Hotkeys: the chosen key, else the setting's default, else any other option (a key another mod took raises).
  local handles, wanted, active = {}, {}, {}

  local function register(name)
    local key = CFG.get(HOTKEYS[name])
    if wanted[name] == key then return end
    wanted[name] = key
    if handles[name] then pcall(wum.ui.remove, handles[name]) end
    handles[name], active[name] = nil, nil
    local d = DEFS[HOTKEYS[name]]
    local tries = {key, d[2]}
    for _, o in ipairs(d[3]) do tries[#tries + 1] = o end
    local fire = U.guard("hotkey." .. name, function() U.emit("hotkey", name) end)
    for _, k in ipairs(tries) do
      local ok, h = pcall(wum.ui.hotkey, k, fire)
      if ok then
        handles[name], active[name] = h, k
        if k ~= key then U.log("warn", "hotkey", key, "is not available; using", k) end
        return
      end
    end
    U.log("warn", "no hotkey could be registered for", name)
  end

  -- The key actually registered for a hotkey name (it can differ from the setting after a fallback), or nil.
  function CFG.hotkeyKey(name) return active[name] end

  function CFG.poll()
    for _, key in ipairs(KEYS) do
      local v = read(key)
      if values[key] ~= v then
        local had = values[key] ~= nil
        values[key] = v
        if had then U.emit("cfg.changed", key, v) end
      end
    end
    for _, name in ipairs(NAMES) do register(name) end
  end

  CFG.poll()
  wum.timers.every(0.5, U.guard("config", CFG.poll))
end
