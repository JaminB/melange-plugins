-- Texture clarity is declared in spice.json's "graphics" block and applied by Melange itself.
--
-- The post-FX effects live under postfx/; this script maps the "quality" and "look" settings onto their enable and
-- param calls. Each effect keeps its own ini/overlay toggle, so a manual tweak in the overlay survives until the next
-- quality or theme change.

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

local lastQuality, lastLook, lastTheme = nil, nil, nil

local function apply()
    local quality = wum.config.get("quality")
    local look = wum.config.get("look")
    local theme = themeKey()
    if quality == lastQuality and look == lastLook and theme == lastTheme then
        return
    end
    lastQuality, lastLook, lastTheme = quality, look, theme

    local preset = PRESETS[quality] or PRESETS.medium
    for effect, params in pairs(preset) do
        if effect ~= "shadows" then
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
    if preset.grade.enabled then
        wum.postfx.setParam("sunstone/grade", "look", look == "dusk" and 1.0 or 0.0)
        if theme and NEUTRAL_THEMES[theme] then
            wum.postfx.setParam("sunstone/grade", "lutAmount", 0.0)
        end
    end
end

apply()
wum.timers.every(0.5, apply)
