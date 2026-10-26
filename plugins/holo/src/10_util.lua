-- util (P2): small helpers every fragment uses, and the per-machine preferences kept in wum.storage.
do
  function U.clamp(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
  end

  function U.lerp(a, b, t) return a + (b - a) * t end

  function U.easeOutCubic(t)
    t = U.clamp(t, 0, 1) - 1
    return t * t * t + 1
  end

  -- A finite number, or nil (NaN and the infinities are refused). Used on every number that came off the wire.
  function U.num(v)
    if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then return nil end
    return v
  end

  -- "12:34" below an hour, "1:02:11" from an hour on; nil, NaN and negatives read as 0.
  function U.fmtTime(sec)
    sec = math.floor(U.num(sec) or 0)
    if sec < 0 then sec = 0 end
    local h, m, s = sec // 3600, (sec // 60) % 60, sec % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
  end

  -- Turns control characters into spaces, strips the outer spaces and keeps at most n characters. UTF-8 aware:
  -- the bytes of a broken sequence are dropped, never cut in half. Anything but a string gives "".
  function U.trim(s, n)
    if type(s) ~= "string" then return "" end
    s = s:gsub("%c", " ")
    if not utf8.len(s) then
      local out, i, size = {}, 1, #s
      while i <= size do
        local c, len = s:byte(i), 0
        if c < 0x80 then len = 1
        elseif c >= 0xC2 and c <= 0xDF then len = 2
        elseif c >= 0xE0 and c <= 0xEF then len = 3
        elseif c >= 0xF0 and c <= 0xF4 then len = 4 end
        local ch = len > 0 and s:sub(i, i + len - 1) or ""
        if len > 0 and #ch == len and utf8.len(ch) == 1 then
          out[#out + 1] = ch
          i = i + len
        else
          i = i + 1
        end
      end
      s = table.concat(out)
    end
    s = s:match("^%s*(.-)%s*$")
    if n and utf8.len(s) > n then s = s:sub(1, utf8.offset(s, n + 1) - 1) end
    return s
  end

  -- The peer bus clock in ms; every Holo timestamp uses it, so host and peer times compare through ch:clock().
  function U.now() return wum.peer.now() end

  function U.copy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = U.copy(x) end
    return t
  end

  -- Preferences: one storage key holding a table, read once and written at most once a second after the last change
  -- (wum.storage then saves the file within 2 s).
  local PREFS_KEY = "prefs"
  local prefs, dirtyAt

  local function loadPrefs()
    if prefs then return prefs end
    local ok, v = pcall(wum.storage.get, PREFS_KEY)
    prefs = (ok and type(v) == "table") and v or {}
    return prefs
  end

  function U.pref(key, default)
    local v = loadPrefs()[key]
    if v == nil then return default end
    return v
  end

  function U.setPref(key, value)
    local p = loadPrefs()
    if type(value) ~= "table" and p[key] == value then return end
    p[key] = U.copy(value)
    dirtyAt = U.now()
  end

  function U.flushPrefs()
    if not dirtyAt then return end
    dirtyAt = nil
    local ok, err = pcall(wum.storage.set, PREFS_KEY, prefs)
    if not ok then U.log("warn", "could not save the preferences:", err) end
  end

  wum.timers.every(0.25, U.guard("prefs", function()
    if dirtyAt and U.now() - dirtyAt >= 1000 then U.flushPrefs() end
  end))
end
