-- Texture clarity is declared in spice.json's "graphics" block and applied by Melange itself.
--
-- The post-FX effects live under postfx/ and the lighting and water under shaders/; this script maps the "quality",
-- "look", "lighting" and "water" settings onto their enable and param calls. Each effect keeps its own ini/overlay
-- toggle, so a manual tweak in the overlay survives until the next quality or theme change.

-- Every preset starts from these values (the effect.ini defaults), so switching presets never leaves a value behind.
local BASE = {
    ssao    = { taps = 10, radius = 16, intensity = 1.5, maxDistance = 1500, nearFade = 80 },
    sky     = {},
    fog     = { maxHaze = 0.45, desaturate = 0.35, flatHaze = 1 },
    bloom   = { threshold = 0.85, intensity = 1.2 },
    grade   = { exposure = 0, strength = 0.6, contrast = 1.05, saturation = 1.1, vibrance = 0, clarity = 0,
                paleHighlights = 0, lutAmount = 0.35, vignette = 0.15 },
    smaa    = {},
    sharpen = { sharpness = 0.5 },
}

local PRESETS = {
    off = {
        shadows = { size = 0, mode = 0 },
        lighting = { light = 0, relief = 0, rim = 0, modelRim = 0, shadows = false },
        water   = { enabled = false },
    },
    low = {
        grade   = { enabled = true, lutAmount = 0.3, vignette = 0.12 },
        smaa    = { enabled = true },
        sharpen = { enabled = true, sharpness = 0.4 },
        shadows = { size = 2048, mode = 1 },
        lighting = { light = 1, relief = 0, rim = 0.2, modelRim = 0.3, shadows = true },
        water   = { enabled = true, waves = 0.3, glint = 0.8, foam = 0 },
    },
    -- The near-neutral look of Sunstone 1.5.
    subtle = {
        ssao    = { enabled = true },
        fog     = { enabled = true },
        bloom   = { enabled = true },
        grade   = { enabled = true },
        smaa    = { enabled = true },
        sharpen = { enabled = true },
        shadows = { size = 2048, mode = 2 },
        lighting = { light = 1, relief = 1, rim = 0.3, modelRim = 0.45, shadows = true },
        water   = { enabled = true, waves = 0.35, glint = 1, foam = 0.8 },
    },
    -- The remastered look: harder sun, deeper shadows and contact shading, a confident grade and bright water.
    bold = {
        ssao    = { enabled = true, taps = 12, radius = 18, intensity = 1.9, maxDistance = 2500, nearFade = 50 },
        fog     = { enabled = true, maxHaze = 0.55, desaturate = 0.3, flatHaze = 0.3 },
        bloom   = { enabled = true, threshold = 0.78, intensity = 1.5 },
        grade   = { enabled = true, exposure = 0.1, strength = 0.85, contrast = 1.14, saturation = 1.16, vibrance = 0.35,
                    clarity = 0.75, paleHighlights = 0.8, lutAmount = 0.35, vignette = 0.16 },
        smaa    = { enabled = true },
        sharpen = { enabled = true, sharpness = 0.6 },
        shadows = { size = 4096, mode = 2 },
        lighting = { light = 1, relief = 1.25, rim = 0.5, modelRim = 0.9, shadows = true, sunGain = 1.18,
                     ambientGain = 0.92, shadowAmbient = 0.3, modelSunGain = 1.12, modelAmbientGain = 0.9,
                     hemisphere = 1.4 },
        water   = { enabled = true, waves = 0.45, glint = 1.4, foam = 0.9 },
    },
}
-- Settings saved by Sunstone 1.5 and earlier.
local LEGACY = { medium = "bold", high = "bold" }

local function themeKey()
    if not (wum.game and wum.game.theme) then return nil end
    local t = wum.game.theme()
    return t and string.upper(t) or nil
end

-- The shadow-map size is a request to Melange (the manifest's 2048 until the first apply); the filter is a
-- parameter of the GLSL landscape in shaders/.
local function applyShadows(s)
    if wum.graphics then
        wum.graphics.setShadowMapSize(s.size)
    end
    if wum.shaders then
        pcall(wum.shaders.setParam, "Landscape.cg", "*FragmentMain", "sunstoneShadowMode", s.mode)
    end
end

-- Sunstone's own lighting: the GLSL replacements in shaders/ and the per-theme table they read.
local LANDSCAPE = { "LandscapeFragmentMain", "HeightMapFragmentMain" }
local MODELS = { "FFFragmentMainLit", "FFFragmentMainTexLit", "FFFragmentMainLitCol", "FFFragmentMainTexLitCol" }

-- Per theme: landscape specular reflectance and gloss, relief depth (world units), the ambient tints for surfaces
-- facing the sky and the ground (the ground tint is the bounce light off that theme's terrain), and grade offsets:
-- exposure (stops), a contrast scale, a vibrance cap and whether the warm LUT applies (themes cool or violet by
-- design skip it).
local DEFAULT_THEME = { specular = 0.04, gloss = 24, relief = 4, sky = { 1.16, 1.18, 1.26 }, ground = { 0.86, 0.82, 0.76 } }
local THEMES = {
    ARABIAN     = { specular = 0.03, gloss = 16, relief = 5, sky = { 1.14, 1.15, 1.22 }, ground = { 0.90, 0.85, 0.76 } },
    WILDWEST    = { specular = 0.03, gloss = 16, relief = 5, sky = { 1.14, 1.15, 1.22 }, ground = { 0.88, 0.81, 0.72 } },
    CAMELOT     = { specular = 0.05, gloss = 24, relief = 4, sky = { 1.14, 1.18, 1.28 }, ground = { 0.80, 0.84, 0.72 } },
    PREHISTORIC = { specular = 0.06, gloss = 20, relief = 5, sky = { 1.14, 1.18, 1.26 }, ground = { 0.78, 0.84, 0.68 } },
    BUILDING    = { specular = 0.10, gloss = 40, relief = 2.5, sky = { 1.12, 1.15, 1.22 }, ground = { 0.84, 0.82, 0.80 } },
    ARCTIC      = { specular = 0.12, gloss = 48, relief = 2.5, sky = { 1.10, 1.16, 1.28 }, ground = { 0.90, 0.92, 0.98 } },
    ENGLAND     = { specular = 0.05, gloss = 24, relief = 4, sky = { 1.14, 1.18, 1.28 }, ground = { 0.78, 0.85, 0.70 } },
    HORROR      = { specular = 0.08, gloss = 32, relief = 4, sky = { 1.18, 1.16, 1.22 }, ground = { 0.94, 0.92, 0.96 },
                    exposure = 0.15, contrast = 0.94, vibrance = 0.1, lut = false },
    LUNAR       = { specular = 0.03, gloss = 16, relief = 5, sky = { 1.08, 1.08, 1.12 }, ground = { 0.88, 0.88, 0.90 },
                    lut = false },
    PIRATE      = { specular = 0.06, gloss = 32, relief = 4, sky = { 1.16, 1.18, 1.28 }, ground = { 0.90, 0.85, 0.76 } },
    WAR         = { specular = 0.04, gloss = 20, relief = 5, sky = { 1.12, 1.15, 1.22 }, ground = { 0.80, 0.77, 0.72 } },
}

-- Scales a tint's distance from white (the hemisphere's sky/ground contrast).
local function spread(t, k)
    return 1 + (t[1] - 1) * k, 1 + (t[2] - 1) * k, 1 + (t[3] - 1) * k
end

local function landscapeParam(name, ...)
    pcall(wum.shaders.setParam, "Landscape.cg", "*FragmentMain", name, ...)
end
local function modelParam(name, ...)
    pcall(wum.shaders.setParam, "FixedFunction.cg", "FFFragmentMain*Lit*", name, ...)
end

local function applyLighting(l, m, on)
    if not wum.shaders then return end
    local lit = on and l.light or 0
    local k = l.hemisphere or 1
    landscapeParam("sunstoneLight", lit)
    landscapeParam("sunstoneSpecular", m.specular)
    landscapeParam("sunstoneGloss", m.gloss)
    landscapeParam("sunstoneRelief", m.relief * l.relief)
    landscapeParam("sunstoneRim", l.rim)
    landscapeParam("sunstoneSky", spread(m.sky, k))
    landscapeParam("sunstoneGround", spread(m.ground, k))
    landscapeParam("sunstoneSunGain", l.sunGain or 1)
    landscapeParam("sunstoneAmbientGain", l.ambientGain or 1)
    landscapeParam("sunstoneShadowAmbient", l.shadowAmbient or 0.2)
    modelParam("sunstoneLight", lit)
    modelParam("sunstoneRim", l.modelRim)
    modelParam("sunstoneSky", spread(m.sky, k))
    modelParam("sunstoneGround", spread(m.ground, k))
    modelParam("sunstoneSunGain", l.modelSunGain or 1)
    modelParam("sunstoneAmbientGain", l.modelAmbientGain or 1)
    -- With nothing of Sunstone's left to draw, the game's own programs come back.
    local landscape = l.shadows or lit > 0
    for _, e in ipairs(LANDSCAPE) do pcall(wum.shaders.enableGlsl, "Landscape.cg", e, landscape) end
    for _, e in ipairs(MODELS) do pcall(wum.shaders.enableGlsl, "FixedFunction.cg", e, lit > 0) end
end

-- Sunstone's water (shaders/); paused, the game's own water draws again.
local function applyWater(w, on)
    if not wum.shaders then return end
    local enabled = on and w.enabled
    if enabled then
        local function waterParam(name, value)
            pcall(wum.shaders.setParam, "Water.cg", "WaterFragmentMain", name, value)
        end
        waterParam("sunstoneWaterWaves", w.waves)
        waterParam("sunstoneWaterGlint", w.glint)
        waterParam("sunstoneWaterFoam", w.foam)
    end
    pcall(wum.shaders.enableGlsl, "Water.cg", "WaterFragmentMain", enabled == true)
end

local last = {}

local function apply()
    local quality = wum.config.get("quality")
    quality = LEGACY[quality] or quality
    local state = {
        quality = quality,
        look = wum.config.get("look"),
        theme = themeKey(),
        lighting = wum.config.get("lighting") ~= false,
        water = wum.config.get("water") ~= false,
    }
    local same = true
    for k, v in pairs(state) do if last[k] ~= v then same = false end end
    if same then return end
    last = state

    local preset = PRESETS[quality] or PRESETS.bold
    local theme = (state.theme and THEMES[state.theme]) or DEFAULT_THEME
    for effect, base in pairs(BASE) do
        local id = "sunstone/" .. effect
        local p = preset[effect] or {}
        wum.postfx.enable(id, p.enabled == true)
        if p.enabled then
            for name, value in pairs(base) do
                wum.postfx.setParam(id, name, p[name] == nil and value or p[name])
            end
        end
    end
    local grade = preset.grade
    if grade and grade.enabled then
        wum.postfx.setParam("sunstone/grade", "look", state.look == "dusk" and 1.0 or 0.0)
        wum.postfx.setParam("sunstone/grade", "exposure", (grade.exposure or BASE.grade.exposure) + (theme.exposure or 0))
        wum.postfx.setParam("sunstone/grade", "contrast", (grade.contrast or BASE.grade.contrast) * (theme.contrast or 1))
        if theme.vibrance then
            wum.postfx.setParam("sunstone/grade", "vibrance", math.min(grade.vibrance or 0, theme.vibrance))
        end
        if theme.lut == false then
            wum.postfx.setParam("sunstone/grade", "lutAmount", 0.0)
        end
    end
    applyShadows(preset.shadows)
    applyLighting(preset.lighting, theme, state.lighting)
    applyWater(preset.water, state.water)
end

apply()
wum.timers.every(0.5, apply)
