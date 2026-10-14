-- Texture clarity is declared in spice.json's "graphics" block and applied by Melange itself.
--
-- The post-FX effects live under postfx/ and the lighting and water under shaders/; this script maps the "quality",
-- "look", "lighting", "water", "dof", "grain", "lens" and "skin" settings onto their enable and param calls (the skin
-- effect also takes the worms' positions every frame, see "human skin" below). Each effect keeps
-- its own ini/overlay toggle, so a manual tweak in the overlay survives until the next quality or theme change.

-- Every preset starts from these values (the effect.ini defaults), so switching presets never leaves a value behind.
local BASE = {
    ssao    = { radius = 32, intensity = 1.2, bias = 0.05, maxDistance = 1500, nearFade = 80, slices = 2, steps = 4,
                sunlitFade = 0.5, sunAmount = 1, sunDir = { 0, 0.936, -0.351 }, contactStrength = 0, contactLength = 26,
                contactThickness = 10, contactSteps = 10 },
    hdr     = { foliage = 1, expandSurface = 2, expandSpec = 1, expandSky = 2.6, cloudShadow = 0.12, fogAmount = 1,
                sunTint = 0.5, sunGlow = 1, sunDisc = 0, shafts = 0.22, dof = 1, bloom = 0.1, dirt = 0.4,
                flare = 0.03, clarity = 0.4, exposure = 0.7, skyExposure = 0.45, vignette = 0.16, tsContrast = 1.15, saturation = 1,
                vibrance = 0.15, lutAmount = 0.25, look = 0, whitePoint = 4, whiteAmount = 0.5, skyGrade = 0.25, hazeSaturation = 1.7, skySaturation = 1.1, dither = 1,
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
-- skyGlow = false keeps the sky's own gradient (no horizon glow or deeper zenith). waterDeep tints the deep sea,
-- waterReflect scales its sky reflection and waterClarity is how deep the sea floor shows (world units).
-- sunGlow replaces the glow around the sun, whitePoint and whiteAmount keep bright sand below white, and
-- shadeChroma is how much colour shade keeps. sunColour and shadowTint replace the warm sun and cool shade tints.
local DEFAULT_THEME = { specular = 0.04, gloss = 24, relief = 4, sky = { 1.16, 1.18, 1.26 }, ground = { 0.86, 0.82, 0.76 },
                        foliage = 1 }
-- Landscape sun tint and the ambient tint inside sun shadows: warm sun, cool skylight.
local SUN_TINT = { 1.06, 1, 0.9 }
local SHADOW_TINT = { 0.85, 0.93, 1.14 }
local THEMES = {
    ARABIAN     = { specular = 0.03, gloss = 16, relief = 5, sky = { 1.14, 1.15, 1.22 }, ground = { 0.90, 0.85, 0.76 },
                    foliage = 0.5, sunTint = 0.3, lut = 0.4, shadowDip = 0.4, whitePoint = 9, whiteAmount = 0.3 },
    WILDWEST    = { specular = 0.03, gloss = 16, relief = 5, sky = { 1.14, 1.15, 1.22 }, ground = { 0.88, 0.81, 0.72 },
                    foliage = 0.5, sunTint = 0.3, lut = 0.4, shadowDip = 0.4, tint = 0, shadeChroma = 0, whitePoint = 9,
                    whiteAmount = 0.3, sunDir = { -0.012, 0.742, -0.670 } },
    CAMELOT     = { specular = 0.05, gloss = 24, relief = 4, sky = { 1.12, 1.12, 1.12 }, ground = { 0.86, 0.84, 0.76 },
                    foliage = 1, tint = 0, shadeChroma = 0.25, sunDir = { 0, 0.742, -0.670 } },
    PREHISTORIC = { specular = 0.06, gloss = 20, relief = 5, sky = { 1.14, 1.18, 1.26 }, ground = { 0.86, 0.84, 0.76 },
                    foliage = 1, tint = 0, shadeChroma = 0, sunDir = { 0.060, 0.492, -0.869 } },
    BUILDING    = { specular = 0.10, gloss = 40, relief = 0.8, sky = { 1.14, 1.16, 1.12 }, ground = { 0.84, 0.82, 0.80 },
                    foliage = 0.8, lut = false, fog = 0.15, hazeSaturation = 1.2, whitePoint = 9, whiteAmount = 0.3, sunColour = { 0.96, 1.04, 0.92 }, shadowTint = { 0.98, 1.02, 0.97 }, shadeChroma = 0,
                    sunDir = { 0, 0.678, -0.734 } },
    ARCTIC      = { specular = 0.12, gloss = 48, relief = 2.5, sky = { 1.12, 1.13, 1.15 }, ground = { 0.95, 0.95, 0.97 },
                    shadowTint = { 0.85, 0.94, 1.2 }, shadeChroma = 0, lut = false, waterClarity = 6, tint = 0.4, foliage = 0, haze = false, exposure = 0.2, expandSpec = 1, bloom = 0.04, hazeSaturation = 1.2,
                    skySaturation = 1, sunDir = { 0.225, 0.744, -0.629 } },
    ENGLAND     = { specular = 0.05, gloss = 24, relief = 4, sky = { 1.14, 1.18, 1.28 }, ground = { 0.86, 0.84, 0.76 },
                    foliage = 1, sunDir = { 0.302, 0.609, -0.734 } },
    HORROR      = { specular = 0.08, gloss = 32, relief = 4, sky = { 1.18, 1.16, 1.22 }, ground = { 0.94, 0.92, 0.96 },
                    foliage = 0, haze = false, exposure = 0.15, contrast = 0.94, vibrance = 0.1, lut = false, sunAmount = 0,
                    sunlitFade = 0.2, fog = 0.45, sunTint = 0, hazeSaturation = 1.1, aerial = 0, skyGlow = false, waterDeep = { 1.03, 0.97, 1 },
                    shadowTint = { 1.1, 1, 0.87 }, waterReflect = 0.2, shafts = false, sunGlow = 0,
                    sunDir = { 0.26, 0.884, -0.387 } },
    LUNAR       = { specular = 0.03, gloss = 16, relief = 5, sky = { 1.08, 1.08, 1.12 }, ground = { 0.88, 0.88, 0.90 },
                    foliage = 0, haze = false, fog = 0.2, lut = false, shafts = false, clouds = false, aerial = 0, skyGlow = false,
                    sunGlow = 0, tint = 0, shadeChroma = 0, shadowDip = 0.5, sunDir = { 0.250, 0.363, -0.898 } },
    PIRATE      = { specular = 0.06, gloss = 32, relief = 4, sky = { 1.16, 1.18, 1.28 }, ground = { 0.90, 0.85, 0.76 },
                    foliage = 0.15, meadowCap = false, shadeChroma = 0, shadowDip = 0.6, sunDir = { 0.204, 0.692, -0.692 } },
    WAR         = { specular = 0.04, gloss = 20, relief = 5, sky = { 1.14, 1.16, 1.12 }, ground = { 0.80, 0.77, 0.72 },
                    foliage = 0.8, sunColour = { 1, 1.02, 0.94 }, shadowTint = { 1, 1.03, 0.92 }, shadeChroma = 0,
                    fog = 0.5, sunGlow = 0, shafts = false, sunDir = { 0.049, 0.213, -0.975 } },
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
    if theme.whitePoint then v.whitePoint = theme.whitePoint end
    if theme.whiteAmount then v.whiteAmount = theme.whiteAmount end
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
    local su = m.sunColour or SUN_TINT
    landscapeParam("sunstoneSunTint", su[1], su[2], su[3])
    local st = m.shadowTint or SHADOW_TINT
    landscapeParam("sunstoneShadowTint", st[1], st[2], st[3])
    landscapeParam("sunstoneSunGain", l.sunGain or 1)
    landscapeParam("sunstoneAmbientGain", l.ambientGain or 1)
    landscapeParam("sunstoneShadowAmbient", (l.shadowAmbient or 0.2) * (m.shadowDip or 1))
    landscapeParam("sunstoneShadeChroma", m.shadeChroma or 0.5)
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
        waterParam("sunstoneWaterClarity", theme.waterClarity or 15)
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

-- ---------------------------------------------------------------- human skin
-- postfx/skin re-renders the worms' skin as human skin (see skin.frag). It runs at order 55, after Bloodsand's skin (51),
-- guts (52) and gibs (53) and Kindjal's acid (54), which go on finding and painting the vanilla peach unchanged, and
-- before Sunstone's occlusion (100) and grade (300). The shader finds each worm's body round a centre this script sends
-- every frame, as Bloodsand and Kindjal do: 16 slots, slot n in wormN (the body centre, CENTRE_Y above the position the
-- game reports, the same 12 units both of them use), wormNb (the skin albedo) and wormNc (heading, a seed for the worm's
-- own pores and mottling, and slack: how far the body can be from that centre, from the worm's speed, since the game
-- reports a position 50 times a second and a flying worm moves several units between two). Every living worm is sent,
-- blood or not (Bloodsand only sends the worms it paints). Values go out with wum.postfx.setTransient (not saved, not
-- logged) and only when they changed; the whole set is sent again every RESEND seconds in case Melange reloaded the
-- effect. The effect is on only in a match with the Worm skin setting on a tone and Quality not Off: Off is the game's
-- own rendering, and Kindjal reads any enabled sunstone/* effect as Sunstone being on (its acid then allows for
-- Sunstone's tinted shade), which with Quality Off would be wrong.
local SKIN = { id = "sunstone/skin", tone = nil, compat = 1, sunDir = { 0, 0.936, -0.351 }, cache = {}, enabled = nil,
               resendAt = 0, live = false }
local SKIN_SLOTS = 16
local CENTRE_Y = 12
local RESEND = 3
-- Skin albedos as display colours (sRGB), from measured human skin reflectance (very fair to deep), the setting's tones
-- first: richer and redder than the sand at every depth (olive is the yellowest, still well short of the sand's hue).
-- Mixed draws every worm from all of them by its name, so a worm keeps its tone from match to match.
local TONES = {
    fair   = { 0.94, 0.80, 0.71 },
    light  = { 0.88, 0.70, 0.58 },
    medium = { 0.78, 0.57, 0.42 },
    olive  = { 0.70, 0.53, 0.36 },
    tan    = { 0.62, 0.44, 0.30 },
    brown  = { 0.45, 0.30, 0.20 },
    deep   = { 0.30, 0.19, 0.13 },
}
local MIXED = { "fair", "light", "medium", "olive", "tan", "brown", "deep" }
local hasTransient = wum.postfx and wum.postfx.setTransient and wum.postfx.enable and true or false

local SKIN_A, SKIN_B, SKIN_C = {}, {}, {}
for i = 0, SKIN_SLOTS - 1 do
    SKIN_A[i], SKIN_B[i], SKIN_C[i] = "worm" .. i, "worm" .. i .. "b", "worm" .. i .. "c"
end

-- A small, stable hash of a string to 0..1 (a polynomial mod a prime, exact in doubles), so a name gives the same tone and
-- pattern on every client and in every match.
local function hash01(s)
    local h = 7
    for i = 1, #s do
        h = (h * 131 + string.byte(s, i)) % 2147483647
    end
    h = (h * 48271) % 2147483647
    return h / 2147483647
end

-- Sends one parameter when it differs from the last value sent by more than eps. The cache only takes a value Melange
-- accepted, so a refused call is tried again next frame.
local function skinSend(name, a, b, c, eps)
    local old = SKIN.cache[name]
    if old and math.abs(old[1] - a) <= eps and math.abs(old[2] - b) <= eps and math.abs(old[3] - c) <= eps then return end
    local ok, res = pcall(wum.postfx.setTransient, SKIN.id, name, a, b, c)
    if not ok or res == false then return end
    SKIN.cache[name] = { a, b, c }
end

local function skinEnable(on)
    if SKIN.enabled == on or not (wum.postfx and wum.postfx.enable) then return end
    local ok, res = pcall(wum.postfx.enable, SKIN.id, on)
    if ok and res ~= false then SKIN.enabled = on end
end

-- The albedo of a worm: the setting's tone, or for Mixed one of all seven by name; with a few percent of its own
-- variation either way, so a team of one tone is not one flat colour.
local function wormAlbedo(name, slot)
    local key = (name and name ~= "") and name or ("slot" .. slot)
    local h = hash01(key)
    local t = TONES[SKIN.tone]
    if SKIN.tone == "mixed" then t = TONES[MIXED[math.floor(h * #MIXED) % #MIXED + 1]] end
    t = t or TONES.medium
    local v = 1 + 0.06 * (hash01(key .. "#v") - 0.5)
    local r = 1 + 0.04 * (hash01(key .. "#r") - 0.5)
    return t[1] * v * r, t[2] * v, t[3] * v / r, h
end

local function skinZeroAll()
    for i = 0, SKIN_SLOTS - 1 do skinSend(SKIN_A[i], 0, 0, 0, 0) end
end

local function skinFrame()
    local ok, inMatch = pcall(wum.game.inMatch)
    if not (SKIN.tone and hasTransient and ok and inMatch) then
        if SKIN.live then
            skinZeroAll()
            SKIN.live = false
        end
        skinEnable(false)
        return
    end
    if not SKIN.live or os.clock() >= SKIN.resendAt then
        SKIN.cache = {}
        SKIN.resendAt = os.clock() + RESEND
        local d = SKIN.sunDir
        skinSend("sunDir", d[1], d[2], d[3], 0)
        SKIN.compatSent = nil
    end
    SKIN.live = true
    -- Cached like skinSend: only an accepted call is remembered, so a refusal is retried every frame, and the value
    -- is sent again only when SKIN.compat changes (or the resend block above cleared it).
    if SKIN.compatSent ~= SKIN.compat then
        local okc, resc = pcall(wum.postfx.setTransient, SKIN.id, "compat", SKIN.compat)
        if okc and resc ~= false then SKIN.compatSent = SKIN.compat end
    end
    local okw, worms = pcall(wum.game.worms)
    local used = {}
    if okw and type(worms) == "table" then
        for i = 1, #worms do
            local w = worms[i]
            local slot = type(w) == "table" and tonumber(w.slot)
            local pos = slot and w.pos
            if slot and slot >= 0 and slot < SKIN_SLOTS and w.alive == true and type(pos) == "table"
                and tonumber(pos.x) and tonumber(pos.y) and tonumber(pos.z) then
                used[slot] = true
                local yaw = tonumber(w.yaw) or 0
                if yaw - yaw ~= 0 then yaw = 0 end
                yaw = (yaw + math.pi) % (2 * math.pi) - math.pi
                local v = type(w.vel) == "table" and w.vel or {}
                local vx, vy, vz = tonumber(v.x) or 0, tonumber(v.y) or 0, tonumber(v.z) or 0
                -- One tick of movement (and a little more) either way, up to 10 units.
                local slack = math.min(10, math.sqrt(vx * vx + vy * vy + vz * vz) * 0.03)
                local r, g, b, h = wormAlbedo(w.name, slot)
                skinSend(SKIN_A[slot], pos.x, pos.y + CENTRE_Y, pos.z, 0.02)
                skinSend(SKIN_B[slot], r, g, b, 1e-4)
                skinSend(SKIN_C[slot], yaw, math.floor(h * 997), slack, 0.01)
            end
        end
    end
    for i = 0, SKIN_SLOTS - 1 do
        if not used[i] then skinSend(SKIN_A[i], 0, 0, 0, 0) end
    end
    -- On for the whole match, so it compiles at the start and not when the first worm appears.
    skinEnable(true)
end

-- The setting and what it depends on, from apply().
local function applySkin(state, preset, theme)
    local tone = state.skin
    if tone ~= "mixed" and not TONES[tone] then tone = nil end
    if state.quality == "off" then tone = nil end
    if tone ~= SKIN.tone then
        SKIN.tone = tone
        SKIN.cache = {}
    end
    -- The skin test allows for Sunstone's tinted shade while its lighting is on, as Kindjal's acid does.
    local lit = state.lighting and preset.lighting and (preset.lighting.light or 0) > 0
    SKIN.compat = lit and 1 or 0
    SKIN.sunDir = theme.sunDir or BASE.hdr.sunDir
    SKIN.resendAt = 0
    if not tone then skinEnable(false) end
end

local KEYS = { "quality", "look", "theme", "scene", "lighting", "water", "dof", "grain", "lens", "scale", "skin" }
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
        skin = wum.config.get("skin") or "game",
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
    applySkin(state, preset, theme)
end

-- Effects from Sunstone 1.7 and earlier, which an upgraded install may still have enabled.
for _, name in ipairs({ "fog", "sky", "bloom", "grade" }) do
    pcall(wum.postfx.enable, "sunstone/" .. name, false)
end

apply()
wum.timers.every(0.5, apply)
if wum.draw and wum.draw.on and wum.game and wum.game.worms then
    wum.draw.on("world", function()
        local ok, err = pcall(skinFrame)
        if not ok and wum.log then wum.log.warn("Sunstone: worm skin: " .. tostring(err)) end
    end)
else
    skinEnable(false)
end
-- The world callback may not run at all outside a match, so the match's end clears and switches the skin off as well.
if wum.events and wum.events.on then
    wum.events.on("melange.match.end", function()
        pcall(function()
            if SKIN.live then skinZeroAll() end
            SKIN.live = false
            skinEnable(false)
        end)
    end)
end
