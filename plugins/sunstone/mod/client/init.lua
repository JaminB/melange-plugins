-- Texture clarity is declared in spice.json's "graphics" block and applied by Melange itself.
--
-- The post-FX effects live under postfx/ and the lighting and water under shaders/; this script maps the "quality",
-- "look", "lighting", "water", "dof", "grain" and "lens" settings onto their enable and param calls. Each effect keeps
-- its own ini/overlay toggle, so a manual tweak in the overlay survives until the next quality or theme change.

-- Every preset starts from these values (the effect.ini defaults), so switching presets never leaves a value behind.
local BASE = {
    ssao    = { radius = 32, intensity = 1.2, bias = 0.05, maxDistance = 1500, nearFade = 80, slices = 2, steps = 4,
                sunlitFade = 0.5, sunAmount = 1, sunDir = { 0, 0.936, -0.351 }, contactStrength = 0, contactLength = 26,
                contactThickness = 10, contactSteps = 10 },
    hdr     = { foliage = 1, expandSurface = 2, expandSpec = 1, expandSky = 2.6, cloudShadow = 0.12, fogAmount = 1,
                sunTint = 0.5, sunGlow = 1, sunDisc = 0, shafts = 0.22, dof = 1, bloom = 0.1, dirt = 0.4,
                flare = 0.03, clarity = 0.4, exposure = 0.7, skyExposure = 0.45, vignette = 0.16, tsContrast = 1.15, saturation = 1,
                vibrance = 0.15, lutAmount = 0.25, look = 0, skyGrade = 0.25, hazeSaturation = 1.7, skySaturation = 1.1, dither = 1,
                hazeFallback = 1, aerial = 0.5, horizonGlow = 0.3, skyDepth = 0.3, sunDir = { 0, 0.936, -0.351 } },
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
        lite    = { enabled = true, exposure = 0.52 },
        smaa    = { enabled = true },
        sharpen = { enabled = true, sharpness = 0.4 },
        shadows = { size = 2048, mode = 1 },
        lighting = { light = 1, relief = 0, rim = 0.2, modelRim = 0.3, shadows = true, sunGain = 1.2, ambientGain = 1.2,
                     detail = 0, detailBump = 0,
                     grassWrap = 0.3, transmit = 0.15, patch = 0.05, greenSpec = 0.7, tint = 1, groundDip = 0.25,
                     meadow = 29, leaves = 22, shadeShift = 1, tuft = 0.14, sheen = 0 },
        water   = { enabled = true, waves = 0.3, glint = 0.5, foam = 0, ssr = 0, caustics = 0, crest = 0.6,
                    dispersion = 0, smooth = 6 },
    },
    -- Close to the game's own look: natural greens, light haze and AO, no lens effects.
    subtle = {
        foliage = 0.6,
        ssao    = { enabled = true },
        hdr     = { enabled = true, fogAmount = 0.5, bloom = 0.03, shafts = 0, dof = 0, sunDisc = 0, flare = 0, dirt = 0,
                    clarity = 0.2, exposure = 0.45, skyExposure = 0.4, tsContrast = 1.05, vibrance = 0.1, lutAmount = 0.2, vignette = 0.12 },
        smaa    = { enabled = true },
        sharpen = { enabled = true },
        lens    = { enabled = true, ca = 0, grain = 0 },
        shadows = { size = 2048, mode = 2 },
        lighting = { light = 1, relief = 1, rim = 0.3, modelRim = 0.45, shadows = true, sunGain = 1.2, ambientGain = 1.2,
                     detail = 0.04,
                     detailBump = 0.15, grassWrap = 0.3, transmit = 0.1, patch = 0.04, greenSpec = 0.7, tint = 0.6,
                     groundDip = 0.2, meadow = 29, leaves = 22, shadeShift = 1, tuft = 0.14, sheen = 0.05 },
        water   = { enabled = true, waves = 0.35, glint = 0.6, foam = 0.3, ssr = 1, ssrCap = 0.4, caustics = 0.4,
                    crest = 0.4, dispersion = 0.5, smooth = 6 },
    },
    -- The modern look: light in linear space with air, sun and soft highlights, AO and contact shadows, a deep sea
    -- that reflects the scenery.
    bold = {
        foliage = 1,
        ssao    = { enabled = true, slices = 3, steps = 4, radius = 40, intensity = 2.0, maxDistance = 2500,
                    nearFade = 50, contactStrength = 0.7 },
        hdr     = { enabled = true },
        smaa    = { enabled = true },
        sharpen = { enabled = true },
        lens    = { enabled = true },
        shadows = { size = 4096, mode = 2 },
        lighting = { light = 1, relief = 1.25, rim = 0.5, modelRim = 0.6, shadows = true, sunGain = 1.65,
                     ambientGain = 1.12, shadowAmbient = 0.33, modelSunGain = 1.25, modelAmbientGain = 1.2, greenWarm = 0.5,
                     hemisphere = 1.25, detail = 0.06, detailBump = 0.25, grassWrap = 0.3, transmit = 0.15,
                     patch = 0.07, patchHue = 0.9, greenSpec = 0.7, tint = 1, groundDip = 0.25, meadow = 29, leaves = 22,
                     shadeShift = 1, tuft = 0.2, sheen = 0.08 },
        water   = { enabled = true, waves = 0.2, glint = 0.8, foam = 0.35, rich = 0.25, ssr = 1, ssrCap = 0.5,
                    caustics = 0.6, crest = 0.6, dispersion = 1, smooth = 6 },
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
-- facing the sky and the ground (the ground tint is the bounce light off that theme's terrain), a scale for how much
-- darker shade is (shade-heavy maps keep more fill light), and post offsets:
-- foliage (how far the green band is pulled toward natural greens), highlight expansion, exposure (stops), a
-- contrast scale, a vibrance cap, a bloom cap, a fog scale, the haze's sun tint, whether the sun lights the AO and
-- contact shadows, and whether the warm LUT, shafts and cloud shadows apply (themes cool or violet by design skip
-- the LUT; a number scales it). sunDir is the world direction toward the theme's sun, read from the landscape's sun
-- direction view (shaders/params.ini, sunstoneDebug 4). haze = false keeps the air off while no sky is on screen
-- (night and dark skies). meadowCap = false keeps the meadow's own chroma (grass that is already yellow-green);
-- tint scales the warm sun and cool shade tints (white snow). aerial is how far distant land turns sky blue;
-- skyGlow = false keeps the sky's own gradient (no horizon glow or deeper zenith). waterDeep tints the deep sea and
-- waterReflect scales its sky reflection. sunGlow replaces the glow around the sun.
local DEFAULT_THEME = { specular = 0.04, gloss = 24, relief = 4, sky = { 1.16, 1.18, 1.26 }, ground = { 0.86, 0.82, 0.76 },
                        foliage = 1 }
-- Ambient tint inside sun shadows: cool skylight, near neutral where it would turn snow blue.
local SHADOW_TINT = { 0.85, 0.93, 1.14 }
local THEMES = {
    ARABIAN     = { specular = 0.03, gloss = 16, relief = 5, sky = { 1.14, 1.15, 1.22 }, ground = { 0.90, 0.85, 0.76 },
                    foliage = 0.5, sunTint = 0.3, lut = 0.4, shadowDip = 0.4 },
    WILDWEST    = { specular = 0.03, gloss = 16, relief = 5, sky = { 1.14, 1.15, 1.22 }, ground = { 0.88, 0.81, 0.72 },
                    foliage = 0.5, sunTint = 0.3, lut = 0.4, shadowDip = 0.4 },
    CAMELOT     = { specular = 0.05, gloss = 24, relief = 4, sky = { 1.14, 1.18, 1.28 }, ground = { 0.86, 0.84, 0.76 },
                    foliage = 1 },
    PREHISTORIC = { specular = 0.06, gloss = 20, relief = 5, sky = { 1.14, 1.18, 1.26 }, ground = { 0.86, 0.84, 0.76 },
                    foliage = 1 },
    BUILDING    = { specular = 0.10, gloss = 40, relief = 2.5, sky = { 1.12, 1.15, 1.22 }, ground = { 0.84, 0.82, 0.80 },
                    foliage = 0.8 },
    ARCTIC      = { specular = 0.12, gloss = 48, relief = 2.5, sky = { 1.12, 1.13, 1.15 }, ground = { 0.95, 0.95, 0.97 },
                    shadowTint = { 0.97, 0.98, 1.02 }, tint = 0.4, foliage = 0, haze = false, exposure = 0.2, expandSpec = 1, bloom = 0.04, hazeSaturation = 1.2,
                    skySaturation = 1, sunDir = { 0.225, 0.744, -0.629 } },
    ENGLAND     = { specular = 0.05, gloss = 24, relief = 4, sky = { 1.14, 1.18, 1.28 }, ground = { 0.86, 0.84, 0.76 },
                    foliage = 1, sunDir = { 0.302, 0.609, -0.734 } },
    HORROR      = { specular = 0.08, gloss = 32, relief = 4, sky = { 1.18, 1.16, 1.22 }, ground = { 0.94, 0.92, 0.96 },
                    foliage = 0, haze = false, exposure = 0.15, contrast = 0.94, vibrance = 0.1, lut = false, sunAmount = 0,
                    sunlitFade = 0.2, fog = 0.45, sunTint = 0, hazeSaturation = 1.1, aerial = 0, skyGlow = false, waterDeep = { 1.03, 0.97, 1 },
                    shadowTint = { 1.1, 1, 0.87 }, waterReflect = 0.2, shafts = false, sunGlow = 0,
                    sunDir = { 0.26, 0.884, -0.387 } },
    LUNAR       = { specular = 0.03, gloss = 16, relief = 5, sky = { 1.08, 1.08, 1.12 }, ground = { 0.88, 0.88, 0.90 },
                    foliage = 0, haze = false, fog = 0.2, lut = false, shafts = false, clouds = false, aerial = 0, skyGlow = false },
    PIRATE      = { specular = 0.06, gloss = 32, relief = 4, sky = { 1.16, 1.18, 1.28 }, ground = { 0.90, 0.85, 0.76 },
                    foliage = 0.28, meadowCap = false, shadowDip = 0.6, sunDir = { 0.204, 0.692, -0.692 } },
    WAR         = { specular = 0.04, gloss = 20, relief = 5, sky = { 1.12, 1.15, 1.22 }, ground = { 0.80, 0.77, 0.72 },
                    foliage = 0.8 },
}

-- Theme, setting and menu adjustments on top of a preset's values, per effect.
local ADJUST = {}

-- Shared by hdr and lite.
local function adjustLight(v, theme, preset, state)
    v.foliage = (theme.foliage or 1) * (preset.foliage or 1)
    -- With Sunstone's lighting on, the scene shaders move the greens instead (meadow and leaves apart).
    if state.lighting and preset.lighting and (preset.lighting.light or 0) > 0 then v.foliage = 0 end
    if theme.expandSurface then v.expandSurface = theme.expandSurface end
    if theme.expandSpec then v.expandSpec = theme.expandSpec end
    v.exposure = v.exposure + (theme.exposure or 0)
    if v.skyExposure then v.skyExposure = v.skyExposure + (theme.exposure or 0) end
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
    if theme.aerial then v.aerial = theme.aerial end
    if theme.skyGlow == false then
        v.horizonGlow = 0
        v.skyDepth = 0
    end
    if theme.hazeSaturation then v.hazeSaturation = theme.hazeSaturation end
    if theme.skySaturation then v.skySaturation = theme.skySaturation end
    if theme.lut == false then v.lutAmount = 0 elseif theme.lut then v.lutAmount = v.lutAmount * theme.lut end
    if theme.shafts == false then v.shafts = 0 end
    if theme.sunGlow then v.sunGlow = theme.sunGlow end
    if theme.clouds == false then v.cloudShadow = 0 end
    if theme.sunDir then v.sunDir = theme.sunDir end
    if theme.haze == false then v.hazeFallback = 0 end
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
    if theme.sunDir then v.sunDir = theme.sunDir end
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

local function applyLighting(l, m, on, foliage)
    if not wum.shaders then return end
    local lit = on and l.light or 0
    local k = l.hemisphere or 1
    local green = (m.foliage or 1) * foliage
    landscapeParam("sunstoneLight", lit)
    landscapeParam("sunstoneSpecular", m.specular)
    landscapeParam("sunstoneGloss", m.gloss)
    landscapeParam("sunstoneRelief", m.relief * l.relief)
    landscapeParam("sunstoneRim", l.rim)
    landscapeParam("sunstoneSky", spread(m.sky, k))
    landscapeParam("sunstoneGround", spread(m.ground, k))
    local st = m.shadowTint or SHADOW_TINT
    landscapeParam("sunstoneShadowTint", st[1], st[2], st[3])
    landscapeParam("sunstoneSunGain", l.sunGain or 1)
    landscapeParam("sunstoneAmbientGain", l.ambientGain or 1)
    landscapeParam("sunstoneShadowAmbient", (l.shadowAmbient or 0.2) * (m.shadowDip or 1))
    landscapeParam("sunstoneDetail", l.detail or 0)
    landscapeParam("sunstoneDetailBump", l.detailBump or 0)
    landscapeParam("sunstoneGrassWrap", l.grassWrap or 0)
    landscapeParam("sunstoneTransmit", l.transmit or 0)
    landscapeParam("sunstonePatch", l.patch or 0)
    landscapeParam("sunstonePatchHue", l.patchHue or 0)
    landscapeParam("sunstoneGreenSpec", l.greenSpec or 0)
    landscapeParam("sunstoneGreenWarm", (l.greenWarm or 0) * math.min(green, 1))
    landscapeParam("sunstoneTint", (l.tint or 0) * (m.tint or 1))
    landscapeParam("sunstoneFoliage", (l.meadow or 0) * green)
    landscapeParam("sunstoneFoliageCap", (green > 0 and m.meadowCap ~= false) and 1 or 0)
    landscapeParam("sunstoneShadeShift", l.shadeShift or 1)
    landscapeParam("sunstoneTuft", (l.tuft or 0) * math.min(green, 1))
    landscapeParam("sunstoneSheen", (l.sheen or 0) * math.min(green, 1))
    modelParam("sunstoneLight", lit)
    modelParam("sunstoneRim", l.modelRim)
    modelParam("sunstoneSky", spread(m.sky, k))
    modelParam("sunstoneGround", spread(m.ground, k))
    modelParam("sunstoneSunGain", l.modelSunGain or 1)
    modelParam("sunstoneAmbientGain", l.modelAmbientGain or 1)
    modelParam("sunstoneTint", (l.tint or 0) * (m.tint or 1))
    modelParam("sunstoneGroundDip", l.groundDip or 0)
    modelParam("sunstoneFoliage", (l.leaves or 0) * green)
    -- With nothing of Sunstone's left to draw, the game's own programs come back.
    local landscape = l.shadows or lit > 0
    for _, e in ipairs(LANDSCAPE) do pcall(wum.shaders.enableGlsl, "Landscape.cg", e, landscape) end
    for _, e in ipairs(MODELS) do pcall(wum.shaders.enableGlsl, "FixedFunction.cg", e, lit > 0) end
end

-- Sunstone's water (shaders/); paused, the game's own water draws again.
local function applyWater(w, on, theme)
    if not wum.shaders then return end
    local enabled = on and w.enabled
    if enabled then
        local function waterParam(name, value)
            pcall(wum.shaders.setParam, "Water.cg", "WaterFragmentMain", name, value)
        end
        waterParam("sunstoneWaterWaves", w.waves)
        waterParam("sunstoneWaterReflect", (w.reflect or 0.6) * (theme.waterReflect or 1))
        waterParam("sunstoneWaterGlint", w.glint)
        waterParam("sunstoneWaterFoam", w.foam)
        waterParam("sunstoneWaterRich", w.rich or 0)
        waterParam("sunstoneWaterSsr", w.ssr or 0)
        waterParam("sunstoneWaterSsrCap", w.ssrCap or 0.5)
        waterParam("sunstoneWaterCaustics", w.caustics or 0)
        waterParam("sunstoneWaterCrest", w.crest or 0)
        waterParam("sunstoneWaterDispersion", w.dispersion or 0)
        waterParam("sunstoneWaterSmooth", w.smooth or 0)
        local deep = theme.waterDeep or { 1, 1, 1 }
        pcall(wum.shaders.setParam, "Water.cg", "WaterFragmentMain", "sunstoneWaterDeep", deep[1], deep[2], deep[3])
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
    applyLighting(preset.lighting, theme, state.lighting, preset.foliage or 1)
    if wum.shaders then landscapeParam("sunstoneRenderScale", state.scale) end
    applyWater(preset.water, state.water, theme)
end

apply()
wum.timers.every(0.5, apply)
