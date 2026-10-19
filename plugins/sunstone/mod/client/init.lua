-- Texture clarity is declared in spice.json's "graphics" block and applied by Melange itself.
--
-- The post-FX effects live under postfx/ and the lighting, water and the worms' skin and hair under shaders/; this script
-- maps the "quality", "look", "lighting", "water", "dof", "grain", "lens", "materials", "skin", "hair" and "wigs" settings
-- onto their enable and param calls (Mixed skin or hair also takes the worms' positions, see "human skin and hair" below). Each
-- effect keeps its own ini/overlay toggle, so a manual tweak in the overlay survives until the next quality or theme
-- change. A value is only sent when it differs from what was sent before: Melange writes every wum.postfx.setParam to
-- Melange.ini and logs it, and re-sending all of them stalled a settings change for some 300 ms.

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
                     detail = 0, detailBump = 0, matDetail = 0,
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
                     detail = 0.04, matDetail = 0.5,
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
                     hemisphere = 1.25, detail = 0.06, detailBump = 0.25, matDetail = 1, grassWrap = 0.3, transmit = 0.15,
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

-- A shader parameter, sent only when it changed since this script last sent it (each call costs Melange about 0.1 ms: it
-- re-applies every program's bindings).
local SHADER_SENT = {}
local function shaderParam(file, entry, name, a, b, c, d)
    local key = file .. "|" .. entry .. "|" .. name
    local old = SHADER_SENT[key]
    if old and old[1] == a and old[2] == b and old[3] == c and old[4] == d then return end
    local ok
    if d ~= nil then ok = pcall(wum.shaders.setParam, file, entry, name, a, b, c, d)
    elseif c ~= nil then ok = pcall(wum.shaders.setParam, file, entry, name, a, b, c)
    elseif b ~= nil then ok = pcall(wum.shaders.setParam, file, entry, name, a, b)
    else ok = pcall(wum.shaders.setParam, file, entry, name, a) end
    if ok then SHADER_SENT[key] = { a, b, c, d } end
end
-- The shadow-map size is a request to Melange (the manifest's 2048 until the first apply); the filter is a
-- parameter of the GLSL landscape in shaders/.
local function applyShadows(s)
    if wum.graphics then
        wum.graphics.setShadowMapSize(s.size)
    end
    if wum.shaders then
        shaderParam("Landscape.cg", "*FragmentMain", "sunstoneShadowMode", s.mode)
    end
end

-- Sunstone's own lighting: the GLSL replacements in shaders/ and the per-theme table they read.
local LANDSCAPE = { "LandscapeFragmentMain", "HeightMapFragmentMain" }
local MODELS = { "FFFragmentMainLit", "FFFragmentMainTexLit", "FFFragmentMainLitCol", "FFFragmentMainTexLitCol" }

-- Material detail's shared maps: eight original tileable layers in one texture array (assets/detail/materials.png, made
-- by tools/make_detail_maps.py), read by the lit textured model shaders' "uniform sampler2DArray sunstoneMat".
-- SUNSTONE 2.3 NEEDS THE NEW MELANGE (0.10, spice.json's melange.range; TODO: 0.10 is a placeholder until Melange's
-- version with shader textures is known, fix it here, in spice.json and the README): wum.draw.texture with options and
-- wum.shaders.setTexture. On an older Melange that sampler2DArray would share unit 0 with texture0 and every draw of
-- those programs would fail, so the range keeps such a Melange from loading Sunstone at all and nothing is paused
-- here. Should the functions still be missing, material detail stays off (logged once). A texture that fails to load
-- leaves the sampler on Melange's neutral texture (0.502, which the maps treat as "no change"): the procedural detail
-- still draws.
local MAT = { supported = false, tex = nil, bound = false, warned = false }
local function matWarn(msg)
    if MAT.warned then return end
    MAT.warned = true
    if wum.log and wum.log.warn then wum.log.warn("Sunstone: " .. msg) end
end
local function loadMaterialMaps()
    if not (wum.shaders and wum.shaders.setTexture and wum.draw and wum.draw.texture) then
        matWarn("material detail needs Melange 0.10 or later (wum.shaders.setTexture); it stays off")
        return
    end
    MAT.supported = true
    local ok, tex, err = pcall(wum.draw.texture, "assets/detail/materials.png", { wrap = "repeat", layers = 8 })
    if ok and tex then
        MAT.tex = tex
    else
        matWarn("material maps not loaded (" .. tostring(ok and err or tex) .. "); material detail is procedural only")
    end
end
-- Binds the maps to both lit textured model shaders; retried from apply() while GLSL replacements are off (false).
local function bindMaterialMaps()
    if MAT.bound or not MAT.tex then return end
    local ok, r = pcall(wum.shaders.setTexture, "FixedFunction.cg", "FFFragmentMain*TexLit*", "sunstoneMat", MAT.tex)
    if not ok then
        MAT.tex = nil
        matWarn("material maps not bound (" .. tostring(r) .. "); material detail is procedural only")
        return
    end
    MAT.bound = r == true
end

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
-- skinChroma (how much of the light's own colour the human Worm skin takes), skinAmbient (a tint of the ambient light on
-- it), skinShade (a scale of a darker tone's lift in shade) and skinVivid (the skin's colour against its grey, ahead of a
-- grade that greys the frame) keep the tones apart and warm under a theme's light and grade (see applySkin).
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
                    sunDir = { 0.26, 0.884, -0.387 }, skinVivid = 1.1 },
    LUNAR       = { specular = 0.03, gloss = 16, relief = 5, sky = { 1.08, 1.08, 1.12 }, ground = { 0.88, 0.88, 0.90 },
                    foliage = 0, haze = false, fog = 0.2, lut = false, shafts = false, clouds = false, aerial = 0, skyGlow = false,
                    sunGlow = 0, tint = 0, shadeChroma = 0, shadowDip = 0.5, sunDir = { 0.250, 0.363, -0.898 } },
    PIRATE      = { specular = 0.06, gloss = 32, relief = 4, sky = { 1.16, 1.18, 1.28 }, ground = { 0.90, 0.85, 0.76 },
                    foliage = 0.15, meadowCap = false, shadeChroma = 0, shadowDip = 0.6, sunDir = { 0.204, 0.692, -0.692 } },
    WAR         = { specular = 0.04, gloss = 20, relief = 5, sky = { 1.14, 1.16, 1.12 }, ground = { 0.80, 0.77, 0.72 },
                    foliage = 0.8, sunColour = { 1, 1.02, 0.94 }, shadowTint = { 1, 1.03, 0.92 }, shadeChroma = 0,
                    fog = 0.5, sunGlow = 0, shafts = false, sunDir = { 0.049, 0.213, -0.975 },
                    skinChroma = 0.4, skinAmbient = { 1.05, 1, 0.82 }, skinShade = 1.8, skinVivid = 1.15 },
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

-- A post-FX parameter, set only when it differs from the effect's current value.
local function sameParam(id, name, value)
    if not wum.postfx.getParam then return false end
    local n = type(value) == "table" and #value or 1
    local ok, a, b, c, d = pcall(wum.postfx.getParam, id, name, n)
    if not ok or a == nil then return false end
    local cur = { a, b, c, d }
    for i = 1, n do
        local want = type(value) == "table" and value[i] or value
        local have = cur[i]
        if type(want) ~= "number" or type(have) ~= "number" then return false end
        if math.abs(have - want) > 1e-4 * math.max(1, math.abs(want)) then return false end
    end
    return true
end

local function postfxParam(id, name, value)
    if sameParam(id, name, value) then return end
    pcall(wum.postfx.setParam, id, name, value)
end

local function landscapeParam(name, ...)
    shaderParam("Landscape.cg", "*FragmentMain", name, ...)
end
local function modelParam(name, ...)
    shaderParam("FixedFunction.cg", "FFFragmentMain*Lit*", name, ...)
end

-- Returns whether the lit textured models are drawn by Sunstone's shader (which then also marks the worms' skin).
-- materials: the Material detail setting (the preset's matDetail: Subtle light, Bold and Ultra full).
local function applyLighting(l, m, on, foliage, people, materials)
    if not wum.shaders then return false end
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
    modelParam("sunstoneMatDetail", materials and MAT.supported and (l.matDetail or 0) or 0)
    -- With nothing of Sunstone's left to draw, the game's own programs come back.
    local landscape = l.shadows or lit > 0
    for _, e in ipairs(LANDSCAPE) do pcall(wum.shaders.enableGlsl, "Landscape.cg", e, landscape) end
    -- The textured one also draws the worms' skin and hair, with the game's lighting while Sunstone's is off.
    for _, e in ipairs(MODELS) do
        pcall(wum.shaders.enableGlsl, "FixedFunction.cg", e, lit > 0 or (people and e == "FFFragmentMainTexLit"))
    end
    return lit > 0 or people == true
end

-- Sunstone's water (shaders/); paused, the game's own water draws again.
local function applyWater(w, on, theme)
    if not wum.shaders then return end
    local enabled = on and w.enabled
    if enabled then
        local function waterParam(name, value)
            shaderParam("Water.cg", "WaterFragmentMain", name, value)
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
        shaderParam("Water.cg", "WaterFragmentMain", "sunstoneWaterDeep", deep[1], deep[2], deep[3])
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

-- ---------------------------------------------------------------- human skin and hair
-- The worms' skin and hair are drawn by Sunstone's lit-model shader (shaders/FixedFunction.FFFragmentMainTexLit.glsl),
-- where each fragment's unlit colour is the texture's own: the worm's own material with a texel of the skin's colour is
-- skin, and what a worm wears (a glove with bare skin in it, a moustache, a hair hat) is told by its texture. Natural hair
-- alone is a handful of parameters set when a setting changes. A re-toned skin (any tone) and Mixed hair also need each
-- worm where it is: 16 sunstoneWormN parameters (the body's middle, CENTRE_Y above the position the game reports, with
-- the worm's tone, seed, facing and hair colour packed into w: the shader places the face and gives each worm its own
-- detail by them), sent only when a worm has moved more than MOVE units, turned or changed, at most SENDS a frame (each
-- call costs Melange about 0.1 ms); the worms are read every frame only while one moves (see skinFrame). The skin (the game's
-- peach too, whenever the shader runs) marks itself in the scene's alpha, which shaders/PostProcess.RecombineWorms.glsl
-- carries through the game's composition of the frame, so Bloodsand and Kindjal find it exactly instead of by its colour;
-- the tone's brightness against the game's peach goes to them as the event mod.sunstone.skin ({ on, hair, marks, lum =
-- { slot 0 .. 15 } }), so their wounds and acid keep their own brightness on a dark skin. A settings change only sets
-- parameters: nothing is re-linked and nothing is logged (Melange flushes its log to disk on every line, on the game's
-- thread). All of it is off with Quality Off (the game's own rendering).
local SKIN = { tone = nil, hair = 0, wigs = 0, mixed = false, marks = false, byName = {}, sent = {}, live = false,
               slots = 16, CENTRE_Y = 12, MOVE = 0.4, SENDS = 3, next = 0, lum = {}, lumSent = nil, emitAt = 0,
               want = {}, frame = 0, idle = 0, IDLE_POLL = 8, YAW_STEPS = 64,
               EMIT_EVERY = 5, PEACH_LUM = 0.703, warned = {}, outdated = {}, recombine = nil, NOTICE_SECS = 20,
               ambLum = 1,
               noticeUntil = 0, bootClock = os.clock() }
-- Skin albedos (the unlit colour, in the texture's terms; the game's peach is 0.953, 0.620, 0.475), very fair to deep,
-- the setting's tones first. Mixed draws every worm from all seven by its name, so a worm keeps its tone from match to
-- match. Each differs from its neighbours in undertone as well as lightness (CIE Lab of the albedo, L a b): Fair a pink
-- ivory (84 8 13), Light a golden beige (77 3 34), Medium a warm tan (53 15 21), Olive a muted green-brown, its red held
-- back (51 1 18), Tan a golden brown (44 9 34), Brown (32 13 18) and Deep (22 10 12) red-browns; every pair at least 12 apart,
-- and from the peach (73 28 32). The light and the grade roughly halve these distances on screen (and lighten the dark
-- tones), so they are wider than a photograph's and spread in lightness, which a grade that greys the colour keeps. The shader keeps the same table (TONES, by SKIN.INDEX) and shades
-- them so that they stay warm and apart in shade and under a theme's light (see applySkin).
SKIN.TONES = {
    fair   = { 0.92, 0.8, 0.73 },
    light  = { 0.85, 0.73, 0.5 },
    medium = { 0.64, 0.46, 0.36 },
    olive  = { 0.53, 0.47, 0.355 },
    tan    = { 0.52, 0.38, 0.18 },
    brown  = { 0.4, 0.26, 0.185 },
    deep   = { 0.28, 0.18, 0.135 },
}
SKIN.INDEX = { fair = 1, light = 2, medium = 3, olive = 4, tan = 5, brown = 6, deep = 7 }
SKIN.MIXED = { "fair", "light", "medium", "olive", "tan", "brown", "deep" }
-- Hair (the Hair setting): Natural draws each moustache (and, with Hair hats on, each hair hat) as real hair in its own
-- colour family, Mixed gives every worm's moustache a natural colour of its own, by its name. The shader's palette, by
-- index (HairAlbedo): 1 black, 2 dark brown, 3 brown, 4 light brown, 5 dark blonde, 6 blonde, 7 auburn, 8 ginger, 9 grey,
-- 10 white. The weights follow the worm's skin tone, as hair colour does in life (black and dark brown on every tone and
-- most of all on deep ones, blond and red mostly on light ones); with the game's peach skin the light tones' weights are
-- used. A hat is never recoloured: Mixed only changes moustaches.
SKIN.HAIR_MODES = { game = 0, natural = 1, mixed = 2 }
SKIN.HAIR_WEIGHTS = {
    light = { 1.0, 2.0, 2.0, 2.0, 1.5, 1.5, 1.0, 1.0, 0.6 },
    mid   = { 3.0, 3.0, 2.0, 1.0, 0.4, 0.2, 0.4, 0.2, 0.6 },
    deep  = { 5.0, 3.0, 1.0, 0.2, 0.0, 0.0, 0.1, 0.0, 0.6 },
}
SKIN.HAIR_GROUP = { fair = "light", light = "light", medium = "mid", olive = "mid", tan = "mid", brown = "deep", deep = "deep" }
SKIN.NAMES = {}
for i = 0, SKIN.slots - 1 do SKIN.NAMES[i] = "sunstoneWorm" .. i end

-- A small, stable hash of a string to 0..1 (a polynomial mod a prime, exact in doubles), so a name gives the same tone and
-- hair on every client and in every match.
local function hash01(s)
    local h = 7
    for i = 1, #s do
        h = (h * 131 + string.byte(s, i)) % 2147483647
    end
    -- (Three rounds: one multiply by 48271 only moves the result by 48271/2^31 per step of the last character, so
    -- "Worm 1" and "Worm 2" got the same tone, seed and hair; three spread neighbouring names across the whole range.)
    for _ = 1, 3 do h = (h * 48271) % 2147483647 end
    return h / 2147483647
end

-- A tone's brightness against the game's peach as the shader draws it in the light: its albedo's, times the theme's
-- ambient tint's own brightness.
local function toneLum(rgb)
    return (0.299 * rgb[1] + 0.587 * rgb[2] + 0.114 * rgb[3]) / SKIN.PEACH_LUM * SKIN.ambLum
end

-- A worm's look, by its name (cached; byName is cleared when the settings change): its tone (the setting's, or for Mixed
-- one of all seven), a seed (the shader gives each worm a few percent of its own tone, its own pores and blotches and, on
-- some fair ones, freckles), its hair colour for Mixed hair (0 otherwise), as the code the shader unpacks less the facing
-- (see the shader's sunstoneWormN; skinFrame adds the facing), and its brightness against the game's peach.
local function wormLook(name, slot)
    local key = (name and name ~= "") and name or ("slot" .. slot)
    local look = SKIN.byName[key]
    if look then return look end
    local h = hash01(key)
    local toneName = SKIN.tone
    if toneName == "mixed" then toneName = SKIN.MIXED[math.floor(h * #SKIN.MIXED) % #SKIN.MIXED + 1] end
    local t = SKIN.TONES[toneName]
    local seed = math.floor(hash01(key .. "#v") * 64) % 64
    local hair = 0
    if SKIN.hair == 2 then
        local w = SKIN.HAIR_WEIGHTS[SKIN.HAIR_GROUP[toneName] or "light"]
        local total = 0
        for i = 1, #w do total = total + w[i] end
        local x = hash01(key .. "#hair") * total
        hair = #w
        for i = 1, #w do
            x = x - w[i]
            if x < 0 then
                hair = i
                break
            end
        end
    end
    look = { code = 1 + hair * 32768 + (t and SKIN.INDEX[toneName] or 0) * 4096 + seed * 64, lum = t and toneLum(t) or 1 }
    SKIN.byName[key] = look
    return look
end

-- One worm slot's parameter, remembered so it is only sent again when the worm moved or its colours changed.
local function wormSend(slot, x, y, z, code)
    local ok = pcall(wum.shaders.setParam, "FixedFunction.cg", "FFFragmentMain*Lit*", SKIN.NAMES[slot], x, y, z, code)
    if ok then
        local s = SKIN.sent[slot]
        if not s then
            s = {}
            SKIN.sent[slot] = s
        end
        s[1], s[2], s[3], s[4] = x, y, z, code
    end
    return ok
end

local function wormZeroAll()
    for i = 0, SKIN.slots - 1 do
        local s = SKIN.sent[i]
        if s == nil or s[4] ~= 0 then wormSend(i, 0, 0, 0, 0) end
    end
end

-- Tells Bloodsand and Kindjal how bright each worm's skin is against the game's peach (1 with the skin off), whether the
-- skin is re-toned (on), whether Sunstone draws the hair (hair) and whether the skin is marked in the scene's alpha at all
-- (marks: with Sunstone's lit-model shader running, the game's peach included), when that changes and every EMIT_EVERY
-- seconds (for a mod loaded or reloaded later). With marks they find the skin by the mark as well as by their colour
-- tests (which stay, so the peach is still found should this shader not run).
-- (skinFrame calls it every frame it runs: the comparison with what was sent last allocates nothing.)
local function emitLum(force)
    if not (wum.events and wum.events.emit) then return end
    local on, hair, marks = SKIN.tone ~= nil, SKIN.hair > 0, SKIN.marks == true
    local last = SKIN.lumSent
    if not force and last and os.clock() < SKIN.emitAt and last.on == on and last.hair == hair and last.marks == marks then
        local same = true
        for i = 1, SKIN.slots do
            if math.abs((on and SKIN.lum[i] or 1) - last.lum[i]) > 5e-4 then
                same = false
                break
            end
        end
        if same then return end
    end
    SKIN.emitAt = os.clock() + SKIN.EMIT_EVERY
    local lum = {}
    for i = 1, SKIN.slots do lum[i] = on and (SKIN.lum[i] or 1) or 1 end
    SKIN.lumSent = { on = on, hair = hair, marks = marks, lum = lum }
    pcall(wum.events.emit, "skin", { on = on, hair = hair, marks = marks, lum = lum })
end

-- Per frame, while the skin is re-toned or the hair is Mixed: each worm's centre, look and facing, sent when it moved,
-- turned or changed, a few a frame. The worms are read every frame while any of them moves, else every IDLE_POLL frames.
local function skinFrame()
    if not SKIN.mixed then return end
    if SKIN.idle > 0 then
        SKIN.idle = SKIN.idle - 1
        return
    end
    local ok, inMatch = pcall(wum.game.inMatch)
    if not (ok and inMatch) then
        if SKIN.live then
            wormZeroAll()
            SKIN.live = false
        end
        return
    end
    SKIN.live = true
    local okw, worms = pcall(wum.game.worms)
    if not (okw and type(worms) == "table") then return end
    -- (The slots' tables are kept from frame to frame; a slot counts only when stamped with this frame.)
    local want, frame = SKIN.want, SKIN.frame + 1
    SKIN.frame = frame
    local moving = false
    for i = 1, #worms do
        local w = worms[i]
        local slot = type(w) == "table" and tonumber(w.slot)
        local pos = slot and w.pos
        if slot and slot >= 0 and slot < SKIN.slots and w.alive == true and type(pos) == "table"
            and tonumber(pos.x) and tonumber(pos.y) and tonumber(pos.z) then
            local look = wormLook(w.name, slot)
            local t = want[slot]
            if not t then
                t = {}
                want[slot] = t
            end
            local yaw = tonumber(w.yaw)
            local yq = (yaw and yaw - yaw == 0) and math.floor(yaw / (2 * math.pi) * SKIN.YAW_STEPS + 0.5) % SKIN.YAW_STEPS or 0
            t[1], t[2], t[3], t[4], t[5] = pos.x, pos.y + SKIN.CENTRE_Y, pos.z, look.code + yq, frame
            SKIN.lum[slot + 1] = look.lum
            local vel = w.vel
            if type(vel) == "table" and math.abs(tonumber(vel.x) or 0) + math.abs(tonumber(vel.y) or 0)
                + math.abs(tonumber(vel.z) or 0) > 0.5 then
                moving = true
            end
        end
    end
    -- Round robin from where the last frame stopped, so no slot waits behind a busy one.
    local sends = 0
    for k = 0, SKIN.slots - 1 do
        local i = (SKIN.next + k) % SKIN.slots
        local w, s = want[i], SKIN.sent[i]
        if w and w[5] ~= frame then w = nil end
        local due
        if w then
            due = not s or s[4] ~= w[4] or (w[1] - s[1]) ^ 2 + (w[2] - s[2]) ^ 2 + (w[3] - s[3]) ^ 2 > SKIN.MOVE * SKIN.MOVE
        else
            due = s == nil or s[4] ~= 0
            SKIN.lum[i + 1] = nil
        end
        if due then
            if sends >= SKIN.SENDS then
                SKIN.next = i
                break
            end
            sends = sends + 1
            if w then wormSend(i, w[1], w[2], w[3], w[4]) else wormSend(i, 0, 0, 0, 0) end
        end
    end
    -- (Sends left over for the next frame count as movement.)
    if not moving and sends < SKIN.SENDS then SKIN.idle = SKIN.IDLE_POLL - 1 end
    emitLum(false)
end

-- A notice on the screen for NOTICE_SECS, on a dark band a little below the game's own banner (the log alone goes unseen).
local function notify(lines)
    if not (wum.draw and wum.draw.on and wum.draw.hudText) then return end
    SKIN.notice, SKIN.noticeUntil = lines, os.clock() + SKIN.NOTICE_SECS
    if SKIN.noticeHandle then return end
    local ok, h = pcall(wum.draw.on, "hud", function()
        if os.clock() > SKIN.noticeUntil then
            if SKIN.noticeHandle then pcall(wum.draw.off, SKIN.noticeHandle) end
            SKIN.noticeHandle = nil
            return
        end
        local okw, w, hh = pcall(wum.render.windowSize)
        w, hh = okw and tonumber(w) or 1920, okw and tonumber(hh) or 1080
        local size = math.max(16, math.floor(hh / 40))
        local x0, y0 = math.floor(w * 0.12), math.floor(hh * 0.2)
        local n = #SKIN.notice
        if wum.draw.hudRect then
            wum.draw.hudRect(x0 - 12, y0 - 8, math.floor(w * 0.88) + 12, y0 + n * (size + 6) + 6, "#000000B0", true)
        end
        for i, line in ipairs(SKIN.notice) do
            wum.draw.hudText(x0, y0 + (i - 1) * (size + 6), line, i == 1 and "#FFD27AFF" or "#FFFFFFFF", size)
        end
    end)
    if ok then SKIN.noticeHandle = h end
end

-- A Bloodsand or Kindjal too old to read the skin's mark paints its wounds and acid only on skin of the game's colour (and
-- takes Sunstone's hair for skin), so the log and, once a session, the screen say to update it.
local function checkPartners()
    if not ((SKIN.tone or SKIN.hair > 0) and wum.postfx and wum.postfx.getParam) then return end
    local found = false
    for _, p in ipairs({ { "bloodsand/skin", "Bloodsand 1.4.0" }, { "kindjal/acid", "Kindjal 1.2.0" } }) do
        if not SKIN.warned[p[1]] then
            local ok, v = pcall(wum.postfx.getParam, p[1], "seed")
            local okt, t = pcall(wum.postfx.getParam, p[1], "tone0", 4)
            if ok and v ~= nil and okt and t == nil then
                SKIN.warned[p[1]] = true
                SKIN.outdated[#SKIN.outdated + 1] = p[2]
                found = true
            end
        end
    end
    if not found then return end
    local who = table.concat(SKIN.outdated, " and ")
    local msg = "Sunstone: Worm skin and hair need " .. who .. " or later"
    local msg2 = "for wounds and acid on the new skin. Update " .. (#SKIN.outdated > 1 and "them" or "it") .. " on the Plugins page (Mods)."
    if wum.log and wum.log.warn then wum.log.warn(msg .. " " .. msg2) end
    SKIN.noticeLines = { msg, msg2 }
    -- Found while the game starts up (a setting kept from the last session), it waits for the first match.
    local okm, inMatch = pcall(wum.game.inMatch)
    if (okm and inMatch) or os.clock() > SKIN.bootClock + 30 then notify(SKIN.noticeLines) else SKIN.noticePending = true end
end

-- The settings and what they depend on, from apply(). Returns whether the lit-model shader is needed for skin or hair.
-- A theme's light and grade pull the tones together (a coloured light tints them all alike, a dim grade crushes the dark
-- ones), so per theme the skin takes less of the light's own colour (skinChroma), its ambient light can be tinted
-- (skinAmbient), a darker tone's lift in shade scaled (skinShade) and its colour made richer ahead of a grade that greys
-- the frame (skinVivid: Horror's sepia).
local function applySkin(state, theme)
    local tone = state.skin
    if tone ~= "mixed" and not SKIN.TONES[tone] then tone = nil end
    local hair = SKIN.HAIR_MODES[state.hair] or 0
    if state.quality == "off" or not wum.shaders then
        tone, hair = nil, 0
    end
    local wigs = (hair > 0 and state.wigs) and 1 or 0
    local amb = theme.skinAmbient or { 1, 1, 1 }
    local ambLum = 0.299 * amb[1] + 0.587 * amb[2] + 0.114 * amb[3]
    if tone ~= SKIN.tone or hair ~= SKIN.hair or wigs ~= SKIN.wigs or ambLum ~= SKIN.ambLum then
        SKIN.tone, SKIN.hair, SKIN.wigs = tone, hair, wigs
        SKIN.byName = {}
        SKIN.lum = {}
    end
    SKIN.ambLum = ambLum
    -- Every worm's centre and facing go to the shader whenever the skin is re-toned (its face and seed), and for Mixed
    -- hair: SKIN.mixed.
    SKIN.mixed = tone ~= nil or hair == 2
    SKIN.idle = 0
    if not wum.shaders then return false end
    local t = tone and (SKIN.TONES[tone] or SKIN.TONES.medium)
    modelParam("sunstoneSkin", t and 1 or 0)
    if t then modelParam("sunstoneSkinTone", t[1], t[2], t[3]) end
    modelParam("sunstoneSkinMixed", SKIN.mixed and 1 or 0)
    modelParam("sunstoneHair", hair)
    modelParam("sunstoneWigs", wigs)
    modelParam("sunstoneSkinChroma", theme.skinChroma or 0.35)
    modelParam("sunstoneSkinShade", theme.skinShade or 1)
    modelParam("sunstoneSkinAmbient", amb[1], amb[2], amb[3])
    modelParam("sunstoneSkinVivid", theme.skinVivid or 1)
    -- One tone: every slot has that tone's brightness for Bloodsand and Kindjal.
    if t and tone ~= "mixed" then
        local l = toneLum(t)
        for i = 1, SKIN.slots do SKIN.lum[i] = l end
    end
    if not SKIN.mixed and SKIN.live then
        wormZeroAll()
        SKIN.live = false
    end
    return t ~= nil or hair > 0
end

-- After the lighting: whether the skin is marked (Sunstone's lit-model shader runs), and the composition pass that carries
-- the mark with it (RecombineWorms). It follows the shader only, never the skin or hair setting: re-linking it on a
-- settings change (and the log lines that go with it) could stall the frame. Silhouette_PC, the ghost of the turn's worm
-- behind a ledge, which keeps a trace of the worm and its skin's mark under it, changes how that ghost looks, so it runs
-- only while the skin is re-toned or Sunstone draws the hair (people): with both off the game looks as it did. Switching
-- it re-links it (a stall of up to a third of a second in testing), so that happens only between scenes (the menu, or a
-- match loading: switch is true); a change in the middle of a match takes effect from the next one.
local function applyMarks(marks, people, switch)
    SKIN.marks = marks == true
    if wum.shaders and SKIN.marks ~= SKIN.recombine
        and pcall(wum.shaders.enableGlsl, "PostProcess.cg", "RecombineWorms", SKIN.marks) then
        SKIN.recombine = SKIN.marks
    end
    local ghost = SKIN.marks and people == true
    if wum.shaders and ghost ~= SKIN.ghost and (switch or SKIN.ghost == nil)
        and pcall(wum.shaders.enableGlsl, "PostProcess.cg", "Silhouette_PC", ghost) then
        SKIN.ghost = ghost
    end
    emitLum(true)
    checkPartners()
end

local KEYS = { "quality", "look", "theme", "scene", "lighting", "water", "dof", "grain", "lens", "scale", "skin", "hair", "wigs",
               "materials" }
local last = {}

local function apply()
    bindMaterialMaps()
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
        hair = wum.config.get("hair") or "game",
        wigs = wum.config.get("wigs") == true,
        materials = wum.config.get("materials") ~= false,
    }
    local same = true
    for _, k in ipairs(KEYS) do
        if last[k] ~= state[k] then same = false end
    end
    if same then return end
    local sceneChanged = last.scene ~= state.scene
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
                postfxParam(id, name, value)
            end
        end
        pcall(wum.postfx.enable, id, p.enabled == true)
    end
    applyShadows(preset.shadows)
    applySupersample(preset.supersample)
    local people = applySkin(state, theme)
    applyMarks(applyLighting(preset.lighting, theme, state.lighting, preset.foliage or 1, people, state.materials), people,
        state.menu or sceneChanged)
    if wum.shaders then landscapeParam("sunstoneRenderScale", state.scale) end
    applyWater(preset.water, state.water, theme)
end

-- Effects from Sunstone 1.7 and earlier, which an upgraded install may still have enabled, and the post-FX skin of 2.1.
for _, name in ipairs({ "fog", "sky", "bloom", "grade", "skin", "skin_u" }) do
    pcall(wum.postfx.enable, "sunstone/" .. name, false)
end

loadMaterialMaps()
apply()
wum.timers.every(0.5, apply)
-- The skin's event again every EMIT_EVERY seconds (emitLum sends only then or on a change), for a Bloodsand or Kindjal
-- loaded or reloaded later; Mixed also checks it every frame (skinFrame).
wum.timers.every(SKIN.EMIT_EVERY, function() pcall(emitLum, false) end)
if wum.draw and wum.draw.on and wum.game and wum.game.worms then
    wum.draw.on("world", function()
        local ok, err = pcall(skinFrame)
        if not ok and wum.log and not SKIN.failed then
            SKIN.failed = true
            wum.log.warn("Sunstone: worm skin: " .. tostring(err))
        end
    end)
end
if wum.events and wum.events.on then
    -- The world callback may not run at all outside a match, so the match's end frees the worm slots as well.
    wum.events.on("melange.match.end", function()
        pcall(function()
            if SKIN.live then wormZeroAll() end
            SKIN.live = false
            SKIN.byName = {}
        end)
    end)
    -- Bloodsand and Kindjal hear the skin's brightness at once when a match starts (and every few seconds anyway).
    -- A mod switched on or off: Bloodsand and Kindjal go back to their colour tests then, so they hear the skin again.
    wum.events.on("melange.mods.changed", function() pcall(emitLum, true) end)
    wum.events.on("melange.match.start", function()
        pcall(emitLum, true)
        pcall(checkPartners)
        if SKIN.noticePending and SKIN.noticeLines then
            SKIN.noticePending = false
            pcall(notify, SKIN.noticeLines)
        end
    end)
end
