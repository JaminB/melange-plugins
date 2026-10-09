-- Kanly client script: control fixes (camera / aim invert, sensitivity) and an unobtrusive control-hint HUD.
--
-- Control options go through wum.input.setOptions (Melange 0.8.0 and later). They change the input on this machine
-- before it is sent, so other players see the same result and the simulation is unaffected. Mouse smoothing is a
-- Melange setting ([Controls] SmoothMouse) and is not touched here.
--
-- The HUD only reads game state and draws. It shows at most three prompts, bottom centre, for a human player's own
-- turn on this machine, fades after a few seconds without a context change, and hides while a projectile is in flight.
--
-- Hints are never shown on other players' turns or to spectators.
--
-- Engine messages used (all exact strings from the game's message table):
--   Turn / weapon state:  GameLogic.Turn.Started, GameLogic.Turn.Ended, Weapon.Fired, Explosion
--   Learning counters:    Input.JumpPressed, Input.MoveLeftPressed, Input.MoveRightPressed, Input.OpenPanelPressed,
--                         Input.FirePressed, Input.FireReleased, Input.FirstPersonPressed, Input.FirstPersonReleased,
--                         Input.FireUtilPressed, Input.Jetpack.ForwardPressed, Input.Jetpack.BackPressed,
--                         Input.Jetpack.LeftPressed, Input.Jetpack.RightPressed
--   Key labels (wum.input.binding): the "Pressed" names above and Input.BlimpViewPressed (legend), with the fallbacks
--                         in the PROMPTS and LEGEND_ROWS tables. Fuse prompts are not shown because the game does not
--                         expose whether the weapon has a fuse.
-- High-rate messages (Camera.MouseMoved, Input.AimMouse) are never subscribed to; "aim", "look" and "zoom" are
-- learned from time spent in the context instead.

if not (wum and wum.draw and wum.draw.on and wum.game and wum.config) then return end

local function log(msg)
    if wum.log and wum.log.warn then pcall(wum.log.warn, msg) end
end

local function clock() return os.clock() end   -- wall time on Windows

local function clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi end return v end

local function cfg(key, default)
    local ok, v = pcall(wum.config.get, key)
    if ok and v ~= nil then return v end
    return default
end

-------------------------------------------------------------------------------------------------------------------
-- 1. Control options
-------------------------------------------------------------------------------------------------------------------

local OPT = { sig = nil, ok = false }

local function applyOptions()
    if not (wum.input and wum.input.setOptions) then return end
    local t = {
        cameraInvertY = cfg("cameraInvertY", "standard"),
        aimInvertY = cfg("aimInvertY", "game"),
        blimpInvert = cfg("blimpInvert", true) ~= false,
    }
    local cs = tonumber(cfg("cameraSensitivity", 1.0)) or 1.0
    local as = tonumber(cfg("aimSensitivity", 1.0)) or 1.0
    cs, as = clamp(cs, 0.25, 3.0), clamp(as, 0.25, 3.0)
    if math.abs(cs - 1.0) > 1e-6 then t.cameraSensitivity = cs end
    if math.abs(as - 1.0) > 1e-6 then t.aimSensitivity = as end
    local sig = table.concat({
        tostring(t.cameraInvertY), tostring(t.aimInvertY), tostring(t.blimpInvert),
        tostring(t.cameraSensitivity), tostring(t.aimSensitivity),
    }, "|")
    if sig == OPT.sig then return end
    local ok, err = pcall(wum.input.setOptions, t)
    OPT.sig, OPT.ok = sig, ok   -- a rejected value is not retried every half second
    if not ok then log("kanly: wum.input.setOptions failed: " .. tostring(err)) end
end

-------------------------------------------------------------------------------------------------------------------
-- 2. Hint HUD
-------------------------------------------------------------------------------------------------------------------

local COL = {
    outline = 0x2A1A0E, cream = 0xF6EAD0, gold = 0xFFCC33, accent = 0xFFB81C,
}
local L = {                       -- layout in pixels at 1080p; everything is scaled by window height / 1080
    marginBottom = 96, chipH = 44, glyphH = 32, pad = 8, gap = 8, labelSize = 19, charW = 0.52,
    minScale = 0.85, maxAlpha = 0.85, fadeIn = 0.25, fadeOut = 0.6, holdSecs = 8, introSecs = 8,
    -- ringSecs: the bazooka reaches full power and fires itself 2.0 s after the press (measured in game).
    retireAfter = 3, dwellSecs = 6, ringSecs = 2.0, flightFailsafe = 8, flightSettle = 1.5,
}
local MAX_PROMPTS = 3

-- bind = {engine message, fallback key label}; glyph = fixed glyph; msgs = messages that count as "used".
local PROMPTS = {
    move    = { id = "move", glyph = { tex = "key_wide", text = "WASD" }, label = "Move",
                msgs = { "Input.MoveLeftPressed", "Input.MoveRightPressed" } },
    jump    = { id = "jump", bind = { "Input.JumpPressed", "Space" }, label = "Jump", msgs = { "Input.JumpPressed" } },
    weapons = { id = "weapons", bind = { "Input.OpenPanelPressed", "RMB" }, label = "Weapons",
                msgs = { "Input.OpenPanelPressed" } },
    aim     = { id = "aim", glyph = { tex = "mouse_move" }, label = "Aim", dwell = true },
    power   = { id = "power", bind = { "Input.FirePressed", "LMB" }, label = "Hold: power",
                msgs = { "Input.FireReleased" } },
    -- First-person aiming lasts while the key is held (measured in game), so both prompts say so.
    fp      = { id = "fp", bind = { "Input.FirstPersonPressed", "Q" }, label = "Hold: first person",
                msgs = { "Input.FirstPersonPressed" } },
    fire    = { id = "fire", bind = { "Input.FirePressed", "LMB" }, label = "Fire", msgs = { "Input.FirePressed" } },
    back    = { id = "back", bind = { "Input.FirstPersonPressed", "Q" }, label = "Release: back",
                msgs = { "Input.FirstPersonReleased" } },
    swing   = { id = "swing", glyph = { tex = "key_wide", text = "A D" }, label = "Swing", dwell = true },
    climb   = { id = "climb", glyph = { tex = "key_wide", text = "W S" }, label = "Climb", dwell = true },
    letgo   = { id = "letgo", bind = { "Input.JumpPressed", "Space" }, label = "Let go", msgs = { "Input.JumpPressed" } },
    fly     = { id = "fly", glyph = { tex = "key_wide", text = "WASD" }, label = "Fly",
                msgs = { "Input.Jetpack.ForwardPressed", "Input.Jetpack.BackPressed", "Input.Jetpack.LeftPressed",
                         "Input.Jetpack.RightPressed" } },
    place   = { id = "place", bind = { "Input.FireUtilPressed", "LMB" }, label = "Place", msgs = { "Input.FireUtilPressed" } },
    cursor  = { id = "cursor", glyph = { tex = "mouse_move" }, label = "Position", dwell = true },
}
local CONTEXTS = {
    move      = { PROMPTS.move, PROMPTS.jump, PROMPTS.weapons },
    aim       = { PROMPTS.aim, PROMPTS.power, PROMPTS.fp },
    fp        = { PROMPTS.aim, PROMPTS.fire, PROMPTS.back },
    rope      = { PROMPTS.swing, PROMPTS.climb, PROMPTS.letgo },
    fly       = { PROMPTS.fly },
    girder    = { PROMPTS.cursor, PROMPTS.place },
}

local LEGEND_ROWS = {
    { glyph = { tex = "key_wide", text = "WASD" }, label = "Walk, aim up and down" },
    { bind = { "Input.JumpPressed", "Space" }, label = "Jump" },
    { bind = { "Input.OpenPanelPressed", "RMB" }, label = "Weapons panel" },
    { glyph = { tex = "mouse_move" }, label = "Aim / look around" },
    { bind = { "Input.FirePressed", "LMB" }, label = "Fire (hold for power)" },
    { glyph = { tex = "key_wide", text = "1-5" }, label = "Set fuse" },
    { bind = { "Input.FirstPersonPressed", "Q" }, label = "First-person aiming (hold)" },
    { bind = { "Input.BlimpViewPressed", "E" }, label = "Blimp view" },
    { glyph = { tex = "mouse_wheel" }, label = "Zoom camera" },
}

local S = {
    tex = {}, texFail = {}, faults = 0, disabled = false, scale = 1, mode = "learning",
    ctx = nil, prevCtx = nil, ctxAt = 0, shownAt = 0, lastNow = nil,
    gate = 0, lastPrompts = nil,
    inFlight = false, flightAt = 0, explodedAt = nil,
    fireDown = false, fireAt = 0,
    local_ = false, localAt = -1, localTurn = false,
    learned = nil, dirty = false, dwell = {},
    legendOn = false, legendHandle = nil, legendKey = nil, wantKey = nil,
    introUntil = 0, introChecked = false, introAlpha = 0,
    bindCache = {}, bindAt = 0, groups = nil, groupsAt = -1,
}

local function loadLearned()
    if S.learned then return S.learned end
    local t
    if wum.storage and wum.storage.get then
        local ok, v = pcall(wum.storage.get, "learned")
        if ok and type(v) == "table" then t = v end
    end
    S.learned = t or {}
    return S.learned
end

local function saveLearned()
    if not S.dirty then return end
    S.dirty = false
    if wum.storage and wum.storage.set then pcall(wum.storage.set, "learned", S.learned) end
end

local function bump(id)
    local l = loadLearned()
    l[id] = (tonumber(l[id]) or 0) + 1
    S.dirty = true
end

local function retired(id, mode)
    if mode ~= "learning" then return false end
    return (tonumber(loadLearned()[id]) or 0) >= L.retireAfter
end

local function tex(name)
    local t = S.tex[name]
    if t then return t end
    if S.texFail[name] then return nil end
    local ok, id = pcall(wum.draw.texture, "textures/" .. name .. ".png")
    if ok and id then
        S.tex[name] = id
        return id
    end
    S.texFail[name] = true
    return nil
end

local function color(rgb, a)
    return rgb * 256 + math.floor(clamp(a, 0, 1) * 255 + 0.5)
end

local function image(x0, y0, x1, y1, name, a)
    local t = tex(name)
    if t then pcall(wum.draw.hudImage, x0, y0, x1, y1, t, color(0xFFFFFF, a)) end
end

local function text(x, y, s, rgb, size, a)
    pcall(wum.draw.hudText, x, y, s, color(rgb, a), size)
end

local function textWidth(s, size) return #s * size * L.charW end

local function binding(msg, fallback)
    local now = clock()
    if now - S.bindAt > 3 then S.bindCache, S.bindAt = {}, now end
    local c = S.bindCache[msg]
    if c == nil then
        c = false
        if wum.input and wum.input.binding then
            local ok, v = pcall(wum.input.binding, msg)
            if ok and type(v) == "string" and v ~= "" then c = v end
        end
        S.bindCache[msg] = c
    end
    return c or fallback
end

-- Resolves a prompt's glyph: {tex = sprite name, text = label drawn on a keycap or nil}.
local function glyphOf(p)
    if p.glyph then return p.glyph end
    local label = binding(p.bind[1], p.bind[2])
    if label == "LMB" then return { tex = "mouse_lmb" } end
    if label == "RMB" then return { tex = "mouse_rmb" } end
    if label == "MMB" or label == "Wheel" then return { tex = "mouse_wheel" } end
    if #label <= 2 then return { tex = "key", text = label } end
    return { tex = "key_wide", text = label }
end

-- Draws a glyph with its left edge at x and its vertical centre at cy; returns its width.
local function drawGlyph(g, x, cy, s, a, ringN)
    local h = L.glyphH * s
    local w, name = h, g.tex
    if ringN then name = string.format("ring_%02d", ringN) end
    if name == "key_wide" then w = h * 2.5
    elseif name:sub(1, 5) == "mouse" then w = h * 0.8 end
    image(x, cy - h / 2, x + w, cy + h / 2, name, a)
    if g.text and not ringN then
        local size = h * 0.58
        local tw = textWidth(g.text, size)
        if tw > w * 0.8 then size = size * (w * 0.8) / tw; tw = w * 0.8 end
        text(x + (w - tw) / 2, cy - size * 0.55, g.text, COL.outline, size, a)
    end
    return w
end

local function glyphWidth(s, g, ring)
    return (ring and 1 or g.tex == "key_wide" and 2.5 or (g.tex:sub(1, 5) == "mouse" and 0.8 or 1)) * L.glyphH * s
end

local function chipWidth(s, p, ring)
    return (L.pad * 2 + L.gap) * s + glyphWidth(s, glyphOf(p), ring) + textWidth(p.label, L.labelSize * s)
end

local function drawChip(x, bottom, s, a, p, ringN)
    local g = glyphOf(p)
    local h = L.chipH * s
    local size = L.labelSize * s
    local gw = glyphWidth(s, g, ringN)
    local w = chipWidth(s, p, ringN)
    local cy = bottom - h / 2
    image(x, bottom - h, x + w, bottom, "chip", a)
    drawGlyph(g, x + L.pad * s, cy, s, a, ringN)
    text(x + (L.pad + L.gap) * s + gw, cy - size * 0.55, p.label, COL.cream, size, a)
    return w
end

-- Draws a one-line note centred on cx (the bottom corners belong to the game's HUD).
local function drawLine(cx, bottom, s, a, label)
    local h = L.chipH * s
    local size = L.labelSize * s
    local w = L.pad * 3 * s + textWidth(label, size)
    local x = cx - w / 2
    image(x, bottom - h, x + w, bottom, "chip", a)
    text(x + L.pad * 1.5 * s, bottom - h / 2 - size * 0.55, label, COL.gold, size, a)
    return w
end

local function refreshLocal(now)
    if now - S.localAt < 0.1 then return end
    S.localAt = now
    S.localTurn = false
    local worms, teams, active
    if wum.game.activeWorm then local ok, v = pcall(wum.game.activeWorm); if ok then active = v end end
    if active == nil then return end
    if wum.game.worms then local ok, v = pcall(wum.game.worms); if ok then worms = v end end
    if wum.game.teams then local ok, v = pcall(wum.game.teams); if ok then teams = v end end
    if type(worms) ~= "table" or type(teams) ~= "table" then return end
    S.weapon = nil
    for _, w in ipairs(worms) do
        if w.slot == active then
            S.weapon = w.weapon
            for _, t in ipairs(teams) do
                -- "local" means simulated on this machine, which includes CPU teams: hints are for human players.
                if t.slot == w.team and t["local"] == true and not t.ai then S.localTurn = true end
            end
            break
        end
    end
end

local function refreshGroups(now)
    if now - S.groupsAt < 0.1 then return end
    S.groupsAt = now
    S.groups = nil
    if not (wum.input and wum.input.groups) then return end
    local ok, g = pcall(wum.input.groups)
    if not ok or type(g) ~= "table" or #g == 0 then return end
    local set = {}
    for _, name in ipairs(g) do set[name] = true end
    S.groups = set
end

local function contextNow()
    local g = S.groups
    if not S.localTurn then return nil end
    if g then
        if g.WormFirstPersonAiming then return "fp" end
        if g.WormRoping then return "rope" end
        if g.Flying then return "fly" end
        if g.UtilityGirder then return "girder" end
        if g.WormAiming then return "aim" end
        if g.InGame or g.WormMoving then return S.weapon and "aim" or "move" end
        return nil
    end
    return S.weapon and "aim" or "move"
end

local function now_inMatch()
    local ok, v = pcall(wum.game.inMatch)
    return ok and v == true
end

local function resetFlight()
    S.inFlight, S.explodedAt = false, nil
end

local function drawHints()
    local now = clock()
    local dt = S.lastNow and clamp(now - S.lastNow, 0, 0.1) or 0
    S.lastNow = now
    local mode = S.mode
    local inMatch = now_inMatch()
    local w, h = 1920, 1080
    if wum.render and wum.render.windowSize then
        local ok, ww, hh = pcall(wum.render.windowSize)
        if ok and ww and hh and hh > 0 then w, h = ww, hh end
    end
    local s = math.max(h / 1080, L.minScale)  -- small windows: keep the text readable
    local bottom = h - L.marginBottom * s

    -- inMatch() is also true for the menu's attract demo, which is not a match for the hints, legend or first-match note.
    if inMatch then
        refreshGroups(now)
        if S.groups and S.groups.AttractMode then inMatch = false end
    end
    if not inMatch then
        S.legendOn, S.ctx, S.gate, S.lastPrompts, S.introChecked = false, nil, 0, nil, false
        resetFlight()
        S.fireDown = false
        return
    end
    refreshLocal(now)

    -- Flight gate: Weapon.Fired until the explosions have settled, the next turn, or a failsafe.
    if S.inFlight then
        if S.explodedAt and now - S.explodedAt > L.flightSettle then resetFlight()
        elseif now - S.flightAt > L.flightFailsafe then resetFlight() end
    end

    -- Context and hold timer.
    local ctx = contextNow()
    if ctx ~= S.ctx then
        S.prevCtx, S.ctx, S.ctxAt = S.ctx, ctx, now
        -- Leaving every context keeps the age, so the last prompts fade out through the gate instead of vanishing.
        if ctx then S.shownAt = now end
    end
    if S.fireDown and (ctx == "aim" or ctx == "fp") then
        -- Hold the prompts (and the power ring) at full age; resetting shownAt to now would make them invisible.
        local age = now - S.shownAt
        if age > L.holdSecs then S.shownAt = now
        elseif age > L.fadeIn then S.shownAt = now - L.fadeIn end
    end

    local list
    if mode ~= "off" and ctx then
        list = {}
        for _, p in ipairs(CONTEXTS[ctx]) do
            if not retired(p.id, mode) then
                list[#list + 1] = p
                if #list >= MAX_PROMPTS then break end
            end
        end
        if #list == 0 then list = nil end
    end

    -- The rope, jetpack and girder are controlled after they are fired, so the flight gate does not hide their prompts.
    local gated = S.inFlight and not (ctx == "rope" or ctx == "fly" or ctx == "girder")
    local want = (list ~= nil and not gated) and 1 or 0
    if S.gate < want then S.gate = math.min(want, S.gate + dt / L.fadeIn)
    elseif S.gate > want then S.gate = math.max(want, S.gate - dt / L.fadeOut) end
    if list then S.lastPrompts = list end

    -- Age fade: in over fadeIn, out after holdSecs without a context change.
    local age = now - S.shownAt
    local ageA = clamp(age / L.fadeIn, 0, 1)
    if age > L.holdSecs then ageA = ageA * clamp(1 - (age - L.holdSecs) / L.fadeOut, 0, 1) end
    local alpha = L.maxAlpha * S.gate * ageA

    -- Learning by dwell time: only while the prompt is actually visible.
    if mode == "learning" and list and alpha > 0.3 then
        for _, p in ipairs(list) do
            if p.dwell then
                S.dwell[p.id] = (S.dwell[p.id] or 0) + dt
                if S.dwell[p.id] >= L.dwellSecs then S.dwell[p.id] = 0; bump(p.id) end
            end
        end
    end

    -- First-match note about the camera default.
    if mode ~= "off" and not S.introChecked then
        S.introChecked = true
        local shown = false
        if wum.storage and wum.storage.get then
            local ok, v = pcall(wum.storage.get, "introShown")
            shown = ok and v == true
        end
        -- Only claim the camera was set when setOptions took it and Melange's Controls module is on ([Controls]
        -- Enabled=0 accepts setOptions but ignores it, and groups() then returns nil).
        local active = false
        if OPT.ok and wum.input and wum.input.groups then
            local ok, v = pcall(wum.input.groups)
            active = ok and v ~= nil
        end
        if not shown and active and cfg("cameraInvertY", "standard") == "standard" then
            S.introUntil = now + L.introSecs
            if wum.storage and wum.storage.set then pcall(wum.storage.set, "introShown", true) end
        end
    end

    local row = bottom
    if S.lastPrompts and alpha > 0.01 then
        -- Centred: the game's own HUD fills the bottom corners (power gauge left, turn clock right).
        local total = 0
        for i, p in ipairs(S.lastPrompts) do
            total = total + chipWidth(s, p, p.id == "power" and S.fireDown) + (i > 1 and L.gap * s or 0)
        end
        local x = (w - total) / 2
        for _, p in ipairs(S.lastPrompts) do
            local ringN
            if p.id == "power" and S.fireDown then
                ringN = clamp(math.floor((now - S.fireAt) / L.ringSecs * 16 + 0.5), 0, 16)
            end
            x = x + drawChip(x, bottom, s, alpha, p, ringN) + L.gap * s
        end
        row = bottom - (L.chipH + L.gap) * s
    end

    if mode ~= "off" and now < S.introUntil then
        local left = S.introUntil - now
        local a = clamp((L.introSecs - left) / L.fadeIn, 0, 1) * clamp(left / L.fadeOut, 0, 1)
        drawLine(w / 2, row, s, a * 0.75, "Camera Y set to standard - change in Melange > Mods > Kanly")
    end

    -- Legend card.
    if S.legendOn then
        local rowH, pad = 38 * s, 20 * s
        local cw = 360 * s
        local ch = pad * 2 + 44 * s + #LEGEND_ROWS * rowH
        local cx = 24 * s
        local cy = (h - ch) / 2
        image(cx, cy, cx + cw, cy + ch, "card", 0.95)
        text(cx + pad, cy + pad - 2 * s, "Controls", COL.gold, 24 * s, 1)
        local hint = "[" .. tostring(S.legendKey or "F1") .. "] close"
        text(cx + cw - pad - textWidth(hint, 14 * s), cy + pad + 4 * s, hint, COL.cream, 14 * s, 0.7)
        local y = cy + pad + 44 * s
        for _, r in ipairs(LEGEND_ROWS) do
            local g = glyphOf(r)
            local gcy = y + rowH / 2
            drawGlyph(g, cx + pad, gcy, s * 0.85, 1)
            text(cx + pad + 82 * s, gcy - 9 * s, r.label, COL.cream, 18 * s, 1)
            y = y + rowH
        end
    end
end

local function onDraw()
    if S.disabled then return end
    local ok, err = pcall(drawHints)
    if not ok then
        S.faults = S.faults + 1
        if S.faults >= 3 then
            S.disabled = true
            log("kanly: hint HUD disabled after 3 errors, last: " .. tostring(err))
        end
    end
end

-------------------------------------------------------------------------------------------------------------------
-- 3. Events (learning counters, flight gate)
-------------------------------------------------------------------------------------------------------------------

local function countMessage(msg)
    if S.mode ~= "learning" then return end
    if not now_inMatch() then return end
    local now = clock()
    refreshLocal(now)
    for ctxName, list in pairs(CONTEXTS) do
        if ctxName == S.ctx or (ctxName == S.prevCtx and now - S.ctxAt < 0.5) then
            if S.localTurn then
                for _, p in ipairs(list) do
                    if p.msgs then
                        for _, m in ipairs(p.msgs) do
                            if m == msg then bump(p.id) end
                        end
                    end
                end
            end
        end
    end
end

local function subscribe(name, fn)
    if wum.events and wum.events.on then pcall(wum.events.on, name, fn) end
end

local function setupEvents()
    local counted = {}
    for _, p in pairs(PROMPTS) do
        for _, m in ipairs(p.msgs or {}) do counted[m] = true end
    end
    for m in pairs(counted) do
        subscribe(m, function() pcall(countMessage, m) end)
    end
    subscribe("Input.FirePressed", function() S.fireDown, S.fireAt = true, clock() end)
    subscribe("Input.FireReleased", function() S.fireDown = false end)
    subscribe("Weapon.Fired", function()
        S.inFlight, S.flightAt, S.explodedAt, S.fireDown = true, clock(), nil, false
    end)
    subscribe("Explosion", function()
        if S.inFlight then S.explodedAt = clock() end
    end)
    local function turn()
        resetFlight()
        S.fireDown = false
        S.shownAt = clock()
    end
    subscribe("GameLogic.Turn.Started", turn)
    subscribe("GameLogic.Turn.Ended", function() resetFlight(); S.fireDown = false end)
    subscribe("melange.match.start", function() turn(); S.introChecked = false; S.legendOn = false end)
    subscribe("melange.match.end", function() S.legendOn = false; resetFlight() end)
end

-------------------------------------------------------------------------------------------------------------------
-- 4. Legend hotkey and settings
-------------------------------------------------------------------------------------------------------------------

local function toggleLegend()
    if S.legendOn then S.legendOn = false; return end
    if now_inMatch() then S.legendOn = true end
end

local function applyLegendKey()
    if not (wum.ui and wum.ui.hotkey) then return end
    local key = cfg("legendKey", "F1")
    if key ~= "F1" and key ~= "Ctrl+H" then key = "F1" end
    if key == S.wantKey then return end   -- compare with the setting, not the fallback actually registered
    S.wantKey = key
    if S.legendHandle and wum.ui.remove then pcall(wum.ui.remove, S.legendHandle) end
    S.legendHandle = nil
    local ok, h = pcall(wum.ui.hotkey, key, toggleLegend)
    if not ok and key ~= "Ctrl+H" then
        key = "Ctrl+H"
        ok, h = pcall(wum.ui.hotkey, key, toggleLegend)
    end
    if ok then S.legendHandle = h end
    S.legendKey = key
end

local function applySettings()
    S.mode = cfg("hints", "learning")   -- read here, not every frame and input message
    pcall(applyOptions)
    pcall(applyLegendKey)
    pcall(saveLearned)
end

setupEvents()
if wum.draw.hudImage and wum.draw.hudText then wum.draw.on("hud", onDraw) end
applySettings()
if wum.timers and wum.timers.every then wum.timers.every(0.5, applySettings) end
