-- L1 (texture clarity) is declared entirely in spice.json's "graphics" block and applied by Melange's
-- MirageTextures framework component; nothing to do here for it.
--
-- L2/L3 are Mirage Post-FX effects under postfx/; this script only maps the "quality" and "look" settings onto
-- their per-effect enable/param calls. Each effect keeps its own ini/overlay toggle, so a manual tweak in the
-- overlay survives until the next quality change.

local PRESETS = {
    off = {
        ssao    = { enabled = false },
        sky     = { enabled = false },
        fog     = { enabled = false },
        bloom   = { enabled = false },
        grade   = { enabled = false },
        smaa    = { enabled = false },
        sharpen = { enabled = false },
    },
    low = {
        ssao    = { enabled = false },
        sky     = { enabled = true, glowIntensity = 0.6 },
        fog     = { enabled = true, inscatterStrength = 0.5 },
        bloom   = { enabled = false },
        grade   = { enabled = true, lutAmount = 0.45, vignette = 0.2, grain = 0.01 },
        smaa    = { enabled = true },
        sharpen = { enabled = true, sharpness = 0.4 },
    },
    medium = {
        ssao    = { enabled = true, taps = 8, radius = 1.0, intensity = 1.0, maxDistance = 60 },
        sky     = { enabled = true, glowIntensity = 0.6 },
        fog     = { enabled = true, inscatterStrength = 0.5 },
        bloom   = { enabled = true, threshold = 0.65, intensity = 0.6 },
        grade   = { enabled = true, lutAmount = 0.6, vignette = 0.25, grain = 0.015 },
        smaa    = { enabled = true },
        sharpen = { enabled = true, sharpness = 0.5 },
    },
    high = {
        ssao    = { enabled = true, taps = 16, radius = 1.3, intensity = 1.2, maxDistance = 90 },
        sky     = { enabled = true, glowIntensity = 0.8 },
        fog     = { enabled = true, inscatterStrength = 0.65 },
        bloom   = { enabled = true, threshold = 0.6, intensity = 0.8 },
        grade   = { enabled = true, lutAmount = 0.7, vignette = 0.3, grain = 0.018 },
        smaa    = { enabled = true },
        sharpen = { enabled = true, sharpness = 0.6 },
    },
}

local lastQuality, lastLook = nil, nil

local function apply()
    local quality = wum.config.get("quality")
    local look = wum.config.get("look")
    if quality == lastQuality and look == lastLook then
        return
    end
    lastQuality, lastLook = quality, look

    local preset = PRESETS[quality] or PRESETS.medium
    for effect, params in pairs(preset) do
        local id = "sunstone/" .. effect
        wum.postfx.enable(id, params.enabled)
        for name, value in pairs(params) do
            if name ~= "enabled" then
                wum.postfx.setParam(id, name, value)
            end
        end
    end
    if preset.grade.enabled then
        wum.postfx.setParam("sunstone/grade", "look", look == "dusk" and 1.0 or 0.0)
    end
end

apply()
wum.timers.every(0.5, apply)
