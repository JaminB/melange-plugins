-- Texture clarity is declared in spice.json's "graphics" block and applied by Melange itself.
--
-- The post-FX effects live under postfx/ and the lighting under shaders/; this script maps the "quality", "look"
-- and "lighting" settings onto their enable and param calls. Each effect keeps its own ini/overlay toggle, so a manual
-- tweak in the overlay survives until the next quality or theme change.

local PRESETS = {
    off = {
        ssao    = { enabled = false },
        sky     = { enabled = false },
        fog     = { enabled = false },
        bloom   = { enabled = false },
        grade   = { enabled = false },
        smaa    = { enabled = false },
        sharpen = { enabled = false },
        shadows = { size = 0, mode = 0 },
        lighting = { light = 0, relief = 0, rim = 0, modelRim = 0, shadows = false },
    },
    low = {
        ssao    = { enabled = false },
        sky     = { enabled = false },
        fog     = { enabled = false },
        bloom   = { enabled = false },
        grade   = { enabled = true, lutAmount = 0.3, vignette = 0.12 },
        smaa    = { enabled = true },
        sharpen = { enabled = true, sharpness = 0.4 },
        shadows = { size = 2048, mode = 1 },
        lighting = { light = 1, relief = 0, rim = 0.2, modelRim = 0.3, shadows = true },
    },
    medium = {
        ssao    = { enabled = true, taps = 10, radius = 16, intensity = 1.5, maxDistance = 1500 },
        sky     = { enabled = false },
        fog     = { enabled = true, maxHaze = 0.45 },
        bloom   = { enabled = true, threshold = 0.85, intensity = 1.2 },
        grade   = { enabled = true, lutAmount = 0.35, vignette = 0.15 },
        smaa    = { enabled = true },
        sharpen = { enabled = true, sharpness = 0.5 },
        shadows = { size = 2048, mode = 2 },
        lighting = { light = 1, relief = 1, rim = 0.3, modelRim = 0.45, shadows = true },
    },
    high = {
        ssao    = { enabled = true, taps = 16, radius = 20, intensity = 1.8, maxDistance = 2500 },
        sky     = { enabled = false },
        fog     = { enabled = true, maxHaze = 0.5 },
        bloom   = { enabled = true, threshold = 0.82, intensity = 1.5 },
        grade   = { enabled = true, lutAmount = 0.45, vignette = 0.2 },
        smaa    = { enabled = true },
        sharpen = { enabled = true, sharpness = 0.6 },
        shadows = { size = 4096, mode = 2 },
        lighting = { light = 1, relief = 1.25, rim = 0.35, modelRim = 0.5, shadows = true },
    },
}

-- Themes whose palette is cool or violet by design: the warm grade is left out there.
local NEUTRAL_THEMES = { LUNAR = true, HORROR = true }

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

-- Sunstone's own lighting: the GLSL replacements in shaders/ and the per-theme material table they read.
local LANDSCAPE = { "LandscapeFragmentMain", "HeightMapFragmentMain" }
local MODELS = { "FFFragmentMainLit", "FFFragmentMainTexLit", "FFFragmentMainLitCol", "FFFragmentMainTexLitCol" }

-- Per theme: landscape specular reflectance and gloss, relief depth (world units), and the ambient tints for
-- surfaces facing the sky and the ground (the ground tint is the bounce light off that theme's terrain).
local DEFAULT_MATERIAL = { specular = 0.04, gloss = 24, relief = 4, sky = { 1.16, 1.18, 1.26 }, ground = { 0.86, 0.80, 0.72 } }
local MATERIALS = {
    ARABIAN     = { specular = 0.03, gloss = 16, relief = 5, sky = { 1.14, 1.14, 1.20 }, ground = { 0.92, 0.80, 0.66 } },
    WILDWEST    = { specular = 0.03, gloss = 16, relief = 5, sky = { 1.14, 1.14, 1.20 }, ground = { 0.90, 0.76, 0.62 } },
    CAMELOT     = { specular = 0.05, gloss = 24, relief = 4, sky = { 1.14, 1.18, 1.26 }, ground = { 0.80, 0.82, 0.70 } },
    PREHISTORIC = { specular = 0.06, gloss = 20, relief = 5, sky = { 1.14, 1.18, 1.24 }, ground = { 0.78, 0.82, 0.66 } },
    BUILDING    = { specular = 0.10, gloss = 40, relief = 2.5, sky = { 1.12, 1.14, 1.20 }, ground = { 0.84, 0.82, 0.80 } },
    ARCTIC      = { specular = 0.12, gloss = 48, relief = 2.5, sky = { 1.10, 1.16, 1.28 }, ground = { 0.90, 0.92, 0.98 } },
    ENGLAND     = { specular = 0.05, gloss = 24, relief = 4, sky = { 1.14, 1.18, 1.26 }, ground = { 0.78, 0.84, 0.68 } },
    HORROR      = { specular = 0.08, gloss = 32, relief = 4, sky = { 1.06, 1.04, 1.18 }, ground = { 0.80, 0.76, 0.86 } },
    LUNAR       = { specular = 0.03, gloss = 16, relief = 5, sky = { 1.06, 1.06, 1.10 }, ground = { 0.86, 0.86, 0.88 } },
    PIRATE      = { specular = 0.06, gloss = 32, relief = 4, sky = { 1.16, 1.18, 1.26 }, ground = { 0.90, 0.82, 0.70 } },
    WAR         = { specular = 0.04, gloss = 20, relief = 5, sky = { 1.12, 1.14, 1.20 }, ground = { 0.80, 0.76, 0.70 } },
}

local function landscapeParam(name, ...)
    pcall(wum.shaders.setParam, "Landscape.cg", "*FragmentMain", name, ...)
end
local function modelParam(name, ...)
    pcall(wum.shaders.setParam, "FixedFunction.cg", "FFFragmentMain*Lit*", name, ...)
end

local function applyLighting(l, theme, on)
    if not wum.shaders then return end
    local m = (theme and MATERIALS[theme]) or DEFAULT_MATERIAL
    local lit = on and l.light or 0
    landscapeParam("sunstoneLight", lit)
    landscapeParam("sunstoneSpecular", m.specular)
    landscapeParam("sunstoneGloss", m.gloss)
    landscapeParam("sunstoneRelief", m.relief * l.relief)
    landscapeParam("sunstoneRim", l.rim)
    landscapeParam("sunstoneSky", m.sky[1], m.sky[2], m.sky[3])
    landscapeParam("sunstoneGround", m.ground[1], m.ground[2], m.ground[3])
    modelParam("sunstoneLight", lit)
    modelParam("sunstoneRim", l.modelRim)
    modelParam("sunstoneSky", m.sky[1], m.sky[2], m.sky[3])
    modelParam("sunstoneGround", m.ground[1], m.ground[2], m.ground[3])
    -- With nothing of Sunstone's left to draw, the game's own programs come back.
    local landscape = l.shadows or lit > 0
    for _, e in ipairs(LANDSCAPE) do pcall(wum.shaders.enableGlsl, "Landscape.cg", e, landscape) end
    for _, e in ipairs(MODELS) do pcall(wum.shaders.enableGlsl, "FixedFunction.cg", e, lit > 0) end
end

local lastQuality, lastLook, lastTheme, lastLighting = nil, nil, nil, nil

local function apply()
    local quality = wum.config.get("quality")
    local look = wum.config.get("look")
    local theme = themeKey()
    local lighting = wum.config.get("lighting") ~= false
    if quality == lastQuality and look == lastLook and theme == lastTheme and lighting == lastLighting then
        return
    end
    lastQuality, lastLook, lastTheme, lastLighting = quality, look, theme, lighting

    local preset = PRESETS[quality] or PRESETS.medium
    for effect, params in pairs(preset) do
        if effect ~= "shadows" and effect ~= "lighting" then
            local id = "sunstone/" .. effect
            wum.postfx.enable(id, params.enabled)
            for name, value in pairs(params) do
                if name ~= "enabled" then
                    wum.postfx.setParam(id, name, value)
                end
            end
        end
    end
    applyShadows(preset.shadows)
    applyLighting(preset.lighting, theme, lighting)
    if preset.grade.enabled then
        wum.postfx.setParam("sunstone/grade", "look", look == "dusk" and 1.0 or 0.0)
        if theme and NEUTRAL_THEMES[theme] then
            wum.postfx.setParam("sunstone/grade", "lutAmount", 0.0)
        end
    end
end

apply()
wum.timers.every(0.5, apply)
