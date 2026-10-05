-- Texture clarity is declared in spice.json's "graphics" block and applied by Melange itself.
--
-- The post-FX effects live under postfx/ and the lighting and water under shaders/; this script maps the "quality",
-- "look", "lighting", "water", "dof", "grain" and "lens" settings onto their enable and param calls. Each effect keeps
-- its own ini/overlay toggle, so a manual tweak in the overlay survives until the next quality or theme change.

-- Every preset starts from these values (the effect.ini defaults), so switching presets never leaves a value behind.
local BASE = {
    ssao    = { radius = 32, intensity = 1.2, bias = 0.05, maxDistance = 1500, nearFade = 80, slices = 2, steps = 4,
                sunlitFade = 0.5, sunAmount = 1, contactStrength = 0, contactLength = 26, contactThickness = 10,
                contactSteps = 10 },
    hdr     = { foliage = 1, expandSurface = 2, expandSpec = 2, expandSky = 2.6, cloudShadow = 0.12, fogAmount = 1,
                sunTint = 0.5, sunGlow = 1, sunDisc = 0, shafts = 0.35, dof = 1, bloom = 0.06, dirt = 0.4,
                flare = 0.03, clarity = 0.4, exposure = 0.35, vignette = 0.16, tsContrast = 1.08, saturation = 1,
                vibrance = 0.15, lutAmount = 0.25, look = 0, skyGrade = 0.25, dither = 1 },
    lite    = { foliage = 0.7, expandSurface = 2, expandSpec = 3, exposure = 0.3, vignette = 0.12, tsContrast = 1.1,
                saturation = 1, vibrance = 0.1, skyGrade = 0.25, dither = 1 },
    smaa    = {},
    sharpen = { sharpness = 0.5, nearFade = 60, floor = 0.015 },
    lens    = { ca = 1.2, grain = 0.009, dither = 1 },
}
-- Effects with an Ultra variant (postfx/<name>_u, made by tools/make_variants.py) for a render scale of 2 or more.
local VARIANTS = { ssao = true, hdr = true }

local PRESETS = {
    off = {
        shadows = { size = 0, mode = 0 },
        lighting = { light = 0, relief = 0, rim = 0, modelRim = 0, shadows = false },
        water   = { enabled = false },
    },
    low = {
        foliage = 0.7,
        lite    = { enabled = true },
        smaa    = { enabled = true },
        sharpen = { enabled = true, sharpness = 0.4 },
        shadows = { size = 2048, mode = 1 },
        lighting = { light = 1, relief = 0, rim = 0.2, modelRim = 0.3, shadows = true, detail = 0, detailBump = 0,
                     grassWrap = 0.3, transmit = 0.15, patch = 0.05, greenSpec = 0.7, tint = 1, groundDip = 0.25 },
        water   = { enabled = true, waves = 0.3, glint = 0.8, foam = 0, ssr = 0, caustics = 0, crest = 0.6,
                    dispersion = 0 },
    },
    -- Close to the game's own look: natural greens, light haze and AO, no lens effects.
    subtle = {
        foliage = 0.6,
        ssao    = { enabled = true },
        hdr     = { enabled = true, fogAmount = 0.5, bloom = 0.03, shafts = 0, dof = 0, sunDisc = 0, flare = 0, dirt = 0,
                    clarity = 0.2, exposure = 0.2, tsContrast = 1.05, vibrance = 0.1, lutAmount = 0.2, vignette = 0.12 },
        smaa    = { enabled = true },
        sharpen = { enabled = true },
        lens    = { enabled = true, ca = 0, grain = 0 },
        shadows = { size = 2048, mode = 2 },
        lighting = { light = 1, relief = 1, rim = 0.3, modelRim = 0.45, shadows = true, detail = 0.04,
                     detailBump = 0.15, grassWrap = 0.3, transmit = 0.1, patch = 0.04, greenSpec = 0.7, tint = 0.6,
                     groundDip = 0.2 },
        water   = { enabled = true, waves = 0.35, glint = 1, foam = 0.8, ssr = 1, ssrCap = 0.4, caustics = 0.4,
                    crest = 0.4, dispersion = 0.5 },
    },
    -- The modern look: light in linear space with air, sun and soft highlights, AO and contact shadows, a deep sea
    -- that reflects the scenery.
    bold = {
        foliage = 1,
        ssao    = { enabled = true, slices = 3, steps = 4, radius = 40, intensity = 1.6, maxDistance = 2500,
                    nearFade = 50, contactStrength = 0.45 },
        hdr     = { enabled = true },
        smaa    = { enabled = true },
        sharpen = { enabled = true },
        lens    = { enabled = true },
        shadows = { size = 4096, mode = 2 },
        lighting = { light = 1, relief = 1.25, rim = 0.5, modelRim = 0.9, shadows = true, sunGain = 1.35,
                     ambientGain = 1.0, shadowAmbient = 0.25, modelSunGain = 1.12, modelAmbientGain = 0.9,
                     hemisphere = 1.25, detail = 0.06, detailBump = 0.25, grassWrap = 0.3, transmit = 0.15,
                     patch = 0.05, patchHue = 0.6, greenSpec = 0.7, tint = 1, groundDip = 0.25 },
        water   = { enabled = true, waves = 0.3, glint = 0.5, foam = 0.9, rich = 0.25, ssr = 1, ssrCap = 0.5,
                    caustics = 0.6, crest = 0.6, dispersion = 1 },
    },
}
-- Bold rendered at twice the resolution each way and scaled down (2x2 supersampling): the cleanest edges and
-- textures, for a GPU with room to spare. Supersampling already smooths the edges SMAA would find; the heavier
-- effects switch to their half-scale variants.
PRESETS.ultra = setmetatable({
    supersample = 4,
    variants = true,
    smaa = {},
    ssao = setmetatable({ steps = 3, contactSteps = 8 }, { __index = PRESETS.bold.ssao }),
}, { __index = PRESETS.bold })
-- Settings saved by Sunstone 1.5 and earlier.
local LEGACY = { medium = "bold", high = "bold" }

local function themeKey()
    if not (wum.game and wum.game.theme) then return nil end
    local t = wum.game.theme()
    return t and string.upper(t) or nil
end

local function sceneName()
    if not (wum.game and wum.game.scene) then return nil end
    local ok, s = pcall(wum.game.scene)
    return ok and s or nil
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
-- facing the sky and the ground (the ground tint is the bounce light off that theme's terrain), and post offsets:
-- foliage (how far the green band is pulled toward natural greens), highlight expansion, exposure (stops), a
-- contrast scale, a vibrance cap, a bloom cap, a fog scale, the haze's sun tint, whether the sun lights the AO and
-- contact shadows, and whether the warm LUT, shafts and cloud shadows apply (themes cool or violet by design skip
-- the LUT).
local DEFAULT_THEME = { specular = 0.04, gloss = 24, relief = 4, sky = { 1.16, 1.18, 1.26 }, ground = { 0.86, 0.82, 0.76 },
                        foliage = 1 }
local THEMES = {
    ARABIAN     = { specular = 0.03, gloss = 16, relief = 5, sky = { 1.14, 1.15, 1.22 }, ground = { 0.90, 0.85, 0.76 },
                    foliage = 0.5, sunTint = 0.3 },
    WILDWEST    = { specular = 0.03, gloss = 16, relief = 5, sky = { 1.14, 1.15, 1.22 }, ground = { 0.88, 0.81, 0.72 },
                    foliage = 0.5, sunTint = 0.3 },
    CAMELOT     = { specular = 0.05, gloss = 24, relief = 4, sky = { 1.14, 1.18, 1.28 }, ground = { 0.86, 0.84, 0.76 },
                    foliage = 1 },
    PREHISTORIC = { specular = 0.06, gloss = 20, relief = 5, sky = { 1.14, 1.18, 1.26 }, ground = { 0.86, 0.84, 0.76 },
                    foliage = 1 },
    BUILDING    = { specular = 0.10, gloss = 40, relief = 2.5, sky = { 1.12, 1.15, 1.22 }, ground = { 0.84, 0.82, 0.80 },
                    foliage = 0.8 },
    ARCTIC      = { specular = 0.12, gloss = 48, relief = 2.5, sky = { 1.10, 1.16, 1.28 }, ground = { 0.90, 0.92, 0.98 },
                    foliage = 0, expandSurface = 1.4, expandSpec = 1, bloom = 0.04, exposure = -0.1 },
    ENGLAND     = { specular = 0.05, gloss = 24, relief = 4, sky = { 1.14, 1.18, 1.28 }, ground = { 0.86, 0.84, 0.76 },
                    foliage = 1 },
    HORROR      = { specular = 0.08, gloss = 32, relief = 4, sky = { 1.18, 1.16, 1.22 }, ground = { 0.94, 0.92, 0.96 },
                    foliage = 0, exposure = 0.15, contrast = 0.94, vibrance = 0.1, lut = false, sunAmount = 0,
                    sunlitFade = 0.2 },
    LUNAR       = { specular = 0.03, gloss = 16, relief = 5, sky = { 1.08, 1.08, 1.12 }, ground = { 0.88, 0.88, 0.90 },
                    foliage = 0, fog = 0.2, lut = false, shafts = false, clouds = false },
    PIRATE      = { specular = 0.06, gloss = 32, relief = 4, sky = { 1.16, 1.18, 1.28 }, ground = { 0.90, 0.85, 0.76 },
                    foliage = 1 },
    WAR         = { specular = 0.04, gloss = 20, relief = 5, sky = { 1.12, 1.15, 1.22 }, ground = { 0.80, 0.77, 0.72 },
                    foliage = 0.8 },
}

-- Theme, setting and menu adjustments on top of a preset's values, per effect.
local ADJUST = {}

-- Shared by hdr and lite.
local function adjustLight(v, theme, preset, state)
    v.foliage = (theme.foliage or 1) * (preset.foliage or 1)
    if theme.expandSurface then v.expandSurface = theme.expandSurface end
    if theme.expandSpec then v.expandSpec = theme.expandSpec end
    v.exposure = v.exposure + (theme.exposure or 0)
    v.tsContrast = v.tsContrast * (theme.contrast or 1)
    if theme.vibrance then v.vibrance = math.min(v.vibrance, theme.vibrance) end
    if state.menu then v.tsContrast = 1 end
end

ADJUST.lite = adjustLight

ADJUST.hdr = function(v, theme, preset, state)
    adjustLight(v, theme, preset, state)
    v.look = state.look == "dusk" and 1 or 0
    if theme.bloom then v.bloom = math.min(v.bloom, theme.bloom) end
    v.fogAmount = v.fogAmount * (theme.fog or 1)
    if theme.sunTint then v.sunTint = theme.sunTint end
    if theme.lut == false then v.lutAmount = 0 end
    if theme.shafts == false then v.shafts = 0 end
    if theme.clouds == false then v.cloudShadow = 0 end
    if not state.dof then v.dof = 0 end
    if not state.lens then
        v.dirt = 0
        v.flare = 0
    end
    if state.menu then
        v.fogAmount = 0
        v.shafts = 0
        v.dof = 0
    end
end

ADJUST.ssao = function(v, theme)
    if theme.sunAmount then v.sunAmount = theme.sunAmount end
    if theme.sunlitFade then v.sunlitFade = theme.sunlitFade end
end

ADJUST.lens = function(v, theme, preset, state)
    if not state.grain then v.grain = 0 end
    if not state.lens then v.ca = 0 end
end

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
    landscapeParam("sunstoneDetail", l.detail or 0)
    landscapeParam("sunstoneDetailBump", l.detailBump or 0)
    landscapeParam("sunstoneGrassWrap", l.grassWrap or 0)
    landscapeParam("sunstoneTransmit", l.transmit or 0)
    landscapeParam("sunstonePatch", l.patch or 0)
    landscapeParam("sunstonePatchHue", l.patchHue or 0)
    landscapeParam("sunstoneGreenSpec", l.greenSpec or 0)
    landscapeParam("sunstoneTint", l.tint or 0)
    modelParam("sunstoneLight", lit)
    modelParam("sunstoneRim", l.modelRim)
    modelParam("sunstoneSky", spread(m.sky, k))
    modelParam("sunstoneGround", spread(m.ground, k))
    modelParam("sunstoneSunGain", l.modelSunGain or 1)
    modelParam("sunstoneAmbientGain", l.modelAmbientGain or 1)
    modelParam("sunstoneTint", l.tint or 0)
    modelParam("sunstoneGroundDip", l.groundDip or 0)
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
        waterParam("sunstoneWaterRich", w.rich or 0)
        waterParam("sunstoneWaterSsr", w.ssr or 0)
        waterParam("sunstoneWaterSsrCap", w.ssrCap or 0.5)
        waterParam("sunstoneWaterCaustics", w.caustics or 0)
        waterParam("sunstoneWaterCrest", w.crest or 0)
        waterParam("sunstoneWaterDispersion", w.dispersion or 0)
    end
    pcall(wum.shaders.enableGlsl, "Water.cg", "WaterFragmentMain", enabled == true)
end

-- A request to Melange; one without wum.graphics.setSupersample renders Ultra as Bold.
local function applySupersample(samples)
    if wum.graphics and wum.graphics.setSupersample then
        pcall(wum.graphics.setSupersample, samples or 0)
    end
end

-- The scene's size over the window's. The landscape reads it as a parameter: declaring Melange's mg_renderScale
-- there would claim the frame's scene copy before the water, which needs depth and colour in it.
local function renderScale()
    local s = wum.graphics and wum.graphics.supersample and wum.graphics.supersample()
    return (s and not s.multisampled and s.x) or 1
end

local KEYS = { "quality", "look", "theme", "scene", "lighting", "water", "dof", "grain", "lens", "scale" }
local last = {}

local function apply()
    local quality = wum.config.get("quality")
    quality = LEGACY[quality] or quality
    local state = {
        quality = quality,
        look = wum.config.get("look"),
        theme = themeKey(),
        scene = sceneName(),
        lighting = wum.config.get("lighting") ~= false,
        water = wum.config.get("water") ~= false,
        dof = wum.config.get("dof") ~= false,
        grain = wum.config.get("grain") ~= false,
        lens = wum.config.get("lens") ~= false,
        scale = renderScale(),
    }
    local same = true
    for _, k in ipairs(KEYS) do
        if last[k] ~= state[k] then same = false end
    end
    if same then return end
    last = state
    state.menu = state.scene == "menu" or state.scene == "boot"

    local preset = PRESETS[quality] or PRESETS.bold
    local theme = (state.theme and THEMES[state.theme]) or DEFAULT_THEME
    local half = preset.variants and state.scale >= 2
    for effect, base in pairs(BASE) do
        local id = "sunstone/" .. effect
        local p = preset[effect] or {}
        if VARIANTS[effect] then
            -- Only one of the pair ever runs: the unused one goes off before the other comes on.
            pcall(wum.postfx.enable, half and id or id .. "_u", false)
            if half then id = id .. "_u" end
        end
        if p.enabled then
            local v = {}
            for name, value in pairs(base) do
                if p[name] == nil then v[name] = value else v[name] = p[name] end
            end
            if ADJUST[effect] then ADJUST[effect](v, theme, preset, state) end
            for name, value in pairs(v) do
                pcall(wum.postfx.setParam, id, name, value)
            end
        end
        pcall(wum.postfx.enable, id, p.enabled == true)
    end
    applyShadows(preset.shadows)
    applySupersample(preset.supersample)
    applyLighting(preset.lighting, theme, state.lighting)
    if wum.shaders then landscapeParam("sunstoneRenderScale", state.scale) end
    applyWater(preset.water, state.water)
end

apply()
wum.timers.every(0.5, apply)
