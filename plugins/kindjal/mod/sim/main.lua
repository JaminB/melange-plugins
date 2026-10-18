-- Kindjal, the sim side (Lua 5.0, the match VM; no "#", no "%"). Runs identically on every peer.
--
-- Everything here happens in this top-level chunk at match Init: wum.sim.weapon(name):set is only allowed then, and
-- a value written here is the same number on every machine, so there is nothing for Wormsign to disagree on. The
-- clone handlers below post one engine message per acid burst (the client paints the acid from it) and queue the
-- Acid Flask's two side bursts; both are deterministic by construction (same tick, same offsets, no randomness).
--
-- Values are absolute, chosen weapon by weapon (see the README's table), not multipliers of what is read back, so a
-- reviewer can see the exact number a match plays with. The exceptions are the few weapons whose vanilla knockback
-- the README has no figure for: those are written as vanilla(f), which reads the game's own value at Init and
-- multiplies it by f (the same vanilla number on every peer, so the result is too).
--
-- Knockback tuning. ImpulseMagnitude (how hard a hit throws a worm) and ImpulseRadius (how far from the blast it still
-- throws) default to roughly vanilla x1.2 and x1.1. The three multipliers below scale every one of them, the three new
-- weapons included. They are constants in this file and not Mods-page settings on purpose: a sim script cannot read
-- the Mods-page settings (there is no wum.config in the match VM), and those are per machine anyway. This file is part
-- of the content hash, so a player who edits a multiplier has a different Kindjal from everyone else and the host
-- refuses the match until all players have the same file; a mismatch can never reach a match unnoticed. They are also
-- globals, so Wormsign's mod.kindjal.env digest covers them.
KNOCKBACK = 1.0   -- every ImpulseMagnitude; 0.5 is half the throw, 2.0 is double
REACH     = 1.0   -- every ImpulseRadius
MELEE     = 1.0   -- the four melee weapons' ImpulseMagnitude, on top of KNOCKBACK

local function vanilla(f) return { vanilla = f } end

-- name -> { field = value }. Field types come from the engine's own schema: numbers for F32/I32/U8/U32, true/false
-- for Bool, strings for String. NumBomblets is U32 and needs Melange 0.9; on an older build the set fails and the
-- banana keeps five.
STATS = {
    -- melee (MeleeWeaponPropertiesContainer)
    -- The held mesh is the plugin's own (assets/meshes/kindjal.NailBat.xom, declared in spice.json "meshes").
    kWeaponBaseballBat = { WormDamageMagnitude = 45, ImpulseMagnitude = 0.30, Radius = 24,
                           WormCollisionFX = "WXP_ShotgunBlast" },
    kWeaponFirePunch   = { WormDamageMagnitude = 40, ImpulseMagnitude = 0.27, Radius = 18,
                           WormCollisionFX = "WXP_Explosion_Small" },
    kWeaponProd        = { WormDamageMagnitude = 10, ImpulseMagnitude = 0.15, Radius = 6,
                           WormCollisionFX = "WXP_ShotgunHit" },
    kWeaponNoMoreNails = { WormDamageMagnitude = 30, ImpulseMagnitude = 0.08, Radius = 22 },  -- vanilla has none

    -- launchers and thrown
    kWeaponBazooka         = { WormDamageMagnitude = 65, WormDamageRadius = 95, LandDamageRadius = 75,
                               ImpulseMagnitude = 0.35, ImpulseRadius = 120, DetonationFx = "WXP_ExplosionX_Large" },
    kWeaponGrenade         = { WormDamageMagnitude = 85, WormDamageRadius = 85, LandDamageRadius = 60,
                               ImpulseMagnitude = 0.34, ImpulseRadius = 120 },
    kWeaponDynamite        = { WormDamageMagnitude = 80, WormDamageRadius = 150, LandDamageRadius = 120,
                               ImpulseMagnitude = 0.43, ImpulseRadius = 145 },
    kWeaponHolyHandGrenade = { WormDamageMagnitude = 100, WormDamageRadius = 200, LandDamageRadius = 150,
                               ImpulseMagnitude = 0.55, ImpulseRadius = 165 },

    -- clusters, mines, homing
    kWeaponBananaBomb      = { NumBomblets = 7, ImpulseMagnitude = 0.48, ImpulseRadius = 140 },
    kWeaponBananette       = { ImpulseMagnitude = vanilla(1.2), ImpulseRadius = vanilla(1.1) },
    kWeaponClusterGrenade  = { WormDamageMagnitude = 25 },
    kWeaponClusterBomb     = { WormDamageMagnitude = 30, ImpulseMagnitude = 0.06, ImpulseRadius = vanilla(1.1),
                               DetonationFx = "WXP_ExplosionX_Med" },
    kWeaponLandmine        = { WormDamageMagnitude = 55, WormDamageRadius = 85, LandDamageRadius = 65,
                               ImpulseMagnitude = 0.30, ImpulseRadius = 110 },
    kWeaponHomingMissile   = { WormDamageMagnitude = 45, ImpulseMagnitude = 0.27, ImpulseRadius = 110 },

    -- air strikes, animals, specials
    kWeaponAirstrike       = { WormDamageMagnitude = 35, WormDamageRadius = 80, LandDamageRadius = 72,
                               ImpulseMagnitude = 0.27, ImpulseRadius = 120 },
    kWeaponSuperAirstrike  = { WormDamageMagnitude = 100, WormDamageRadius = 145, LandDamageRadius = 105,
                               ImpulseMagnitude = 0.36, ImpulseRadius = 145 },
    kWeaponConcreteDonkey  = { LandDamageRadius = 180, ImpulseMagnitude = 0.56, ImpulseRadius = 185 },
    -- The Buddy Bomb (the sheep's slot): a bigger blast than the Plague Ram, short of the Dead Star's throw. The client
    -- knows its explosion by WormDamageRadius 160 (client/init.lua BUDDY.radius), so keep the two the same.
    -- He is a dog, so the sheep's bleats go: LaunchSfx and BigJumpSfx are weapons/SheepBaa and HoldLoopSfx is
    -- weapons/SheepHeld (the same SheepBaa.wav). An empty name plays nothing; the client barks instead. Only this
    -- container is written, so the Plague Ram (kWeaponSuperSheep) and the Dead Star keep their own sounds.
    kWeaponSheep           = { WormDamageMagnitude = 115, WormDamageRadius = 160, LandDamageRadius = 130,
                               ImpulseMagnitude = 0.50, ImpulseRadius = 175, DetonationFx = "WXP_ExplosionX_Large",
                               LaunchSfx = "", BigJumpSfx = "", HoldLoopSfx = "" },
    kWeaponSuperSheep      = { WormDamageMagnitude = 95, WormDamageRadius = 130, LandDamageRadius = 105,
                               ImpulseMagnitude = 0.39, ImpulseRadius = 145 },
    kWeaponOldWoman        = { WormDamageMagnitude = 82, ImpulseMagnitude = 0.38, ImpulseRadius = 120 },
    kWeaponScouser         = { WormDamageMagnitude = 44, ImpulseMagnitude = 0.12, ImpulseRadius = 80 },  -- vanilla has none
    kWeaponFatkins         = { WormDamageMagnitude = 82, ImpulseMagnitude = 0.72, ImpulseRadius = 220 },
    kWeaponFatkinsFood     = { WormDamageMagnitude = 72, ImpulseMagnitude = vanilla(1.2), ImpulseRadius = vanilla(1.1) },
    kWeaponStarburst       = { WormDamageMagnitude = 110, ImpulseMagnitude = 0.90, ImpulseRadius = 165 },

    -- guns, arrow, gas
    kWeaponShotgun         = { WormDamageMagnitude = 50, LandDamageMagnitude = 35, ImpulseMagnitude = 0.16,
                               Accuracy = 0.97 },
    kWeaponSniperRifle     = { WormDamageMagnitude = 45, ImpulseMagnitude = 0.12, ImpulseRadius = 45 },
    -- The sentry's shots: the payload container carries no numbers of its own in WEAPTWK, so these may be refused
    -- or ignored by the engine; the log says which.
    kWeaponSentryGunPayload = { WormDamageMagnitude = 80, WormDamageRadius = 95, LandDamageRadius = 70,
                                ImpulseMagnitude = 0.35, ImpulseRadius = 120 },
    kWeaponPoisonArrow     = { WormImpactDamage = 45 },
    -- A canister has no blast in vanilla; whether the engine honours damage on it is unverified (see README).
    kWeaponGasCanister     = { WormDamageMagnitude = 20, WormDamageRadius = 60, LandDamageRadius = 40,
                               ImpulseMagnitude = 0.15, ImpulseRadius = 65 },  -- vanilla has no blast

    -- the three new weapons (spice.json "weapons"): their manifest "set" holds the same knockback, and setting it again
    -- here, by the clone's name, is what lets the multipliers above reach them
    kWeaponAcidSpitter     = { ImpulseMagnitude = 0.28, ImpulseRadius = 110 },
    kWeaponAcidFlask       = { ImpulseMagnitude = 0.22, ImpulseRadius = 100 },
    kWeaponCrucible        = { ImpulseMagnitude = 0.62, ImpulseRadius = 185 },
}

-- Each re-skinned weapon's own models (assets/meshes/*.xom, declared in spice.json "meshes"): W = held,
-- P = in flight, P2 = second payload, F = flying. Merged into STATS below, so they apply at Init like the numbers.
MESHES = {
    kWeaponBaseballBat     = { W = "kindjal.NailBat" },
    kWeaponProd            = { W = "kindjal.Shiv" },
    kWeaponFirePunch       = { W = "kindjal.Gauntlet" },
    kWeaponNoMoreNails     = { W = "kindjal.Railspike" },
    kWeaponBazooka         = { W = "kindjal.RipperLauncher", P = "kindjal.RipperRocket" },
    kWeaponGrenade         = { W = "kindjal.PipeBomb", P = "kindjal.PipeBomb" },
    kWeaponDynamite        = { W = "kindjal.BlastKeg", P = "kindjal.BlastKeg" },
    kWeaponHolyHandGrenade = { W = "kindjal.ProfaneGrenade", P = "kindjal.ProfaneGrenade" },
    kWeaponBananaBomb      = { W = "kindjal.Plantains", P = "kindjal.Plantains" },
    kWeaponBananette       = { P = "kindjal.Plantains" },
    kWeaponClusterGrenade  = { W = "kindjal.NailCluster", P = "kindjal.NailCluster" },
    kWeaponClusterBomb     = { P = "kindjal.NailClusterPiece" },
    kWeaponLandmine        = { W = "kindjal.BearTrap", P = "kindjal.BearTrap" },
    kWeaponHomingMissile   = { W = "kindjal.HarpoonGun", P = "kindjal.Harpoon" },
    kWeaponAirstrike       = { W = "kindjal.FieldRadio", P = "kindjal.CarpetShell" },
    kWeaponSuperAirstrike  = { W = "kindjal.FieldRadio", P = "kindjal.Carcass" },
    kWeaponConcreteDonkey  = { W = "kindjal.FieldRadio", P = "kindjal.StoneDonkey" },
    kWeaponSheep           = { W = "kindjal.BuddyBomb", P = "kindjal.BuddyBomb" },
    kWeaponSuperSheep      = { W = "kindjal.RabidSheep", P = "kindjal.RabidSheep", F = "kindjal.PlagueRam" },
    kWeaponStarburst       = { W = "kindjal.RabidSheep", P = "kindjal.RabidSheep", F = "kindjal.DeadStar" },
    kWeaponOldWoman        = { W = "kindjal.Hangwoman", P = "kindjal.Hangwoman" },
    kWeaponScouser         = { W = "kindjal.Knifeman", P = "kindjal.Knifeman", P2 = "kindjal.InflatedKnifeman" },
    kWeaponFatkins         = { W = "kindjal.FieldRadio", P = "kindjal.Gorger" },
    kWeaponShotgun         = { W = "kindjal.SlugGun" },
    kWeaponSniperRifle     = { W = "kindjal.ElephantGun" },
    kWeaponSentryGun       = { W = "kindjal.GibbetTurret" },
    kWeaponPoisonArrow     = { W = "kindjal.PlagueBow", P = "kindjal.PlagueArrow" },
    kWeaponGasCanister     = { W = "kindjal.RustCanister", P = "kindjal.RustCanister" },
}
local MESH_FIELD = { W = "WeaponGraphicsResourceID", P = "PayloadGraphicsResourceID",
                     P2 = "Payload2ndGraphicsResourceID", F = "FlyingGraphicsResourceID" }
for name, m in pairs(MESHES) do
    STATS[name] = STATS[name] or {}
    for k, v in pairs(m) do STATS[name][MESH_FIELD[k]] = v end
end

-- The knockback multipliers, kept inside a sane range (a typo should not launch worms off the map).
local function sane(v, lo, hi, what)
    if type(v) ~= "number" or v ~= v then
        wum.log.warn("kindjal:", what, "is not a number, using 1.0")
        return 1.0
    end
    if v < lo or v > hi then
        local c = lo
        if v > hi then c = hi end
        wum.log.warn("kindjal:", what, v, "is outside", lo, "to", hi, "- using", c)
        return c
    end
    return v
end
KNOCKBACK = sane(KNOCKBACK, 0, 3, "KNOCKBACK")
REACH     = sane(REACH, 0, 3, "REACH")
MELEE     = sane(MELEE, 0, 3, "MELEE")

local MELEE_WEAPONS = { kWeaponBaseballBat = true, kWeaponFirePunch = true, kWeaponProd = true,
                        kWeaponNoMoreNails = true }

-- Rounded to a fixed step (0.001 for knockback, 1 unit for reach) so the number written is a plain function of the
-- inputs, with no string formatting in between.
local function round(v, per) return math.floor(v * per + 0.5) / per end

-- The value a field is set to: vanilla(f) resolved against the game's own number, then the multipliers.
local function resolve(w, name, field, value)
    if type(value) == "table" then
        local okGet, base = pcall(w.get, w, field)
        if not okGet or type(base) ~= "number" then return nil, base end
        value = base * value.vanilla
    end
    if field == "ImpulseMagnitude" then
        local f = KNOCKBACK
        if MELEE_WEAPONS[name] then f = f * MELEE end
        return round(value * f, 1000)
    elseif field == "ImpulseRadius" then
        return round(value * REACH, 1)
    end
    return value
end

-- Applies every entry; a refused field is logged and skipped so one bad name never takes the rest down with it.
local applied, refused = 0, 0
for name, fields in pairs(STATS) do
    local ok, w = pcall(wum.sim.weapon, name)
    if not ok or not w then
        wum.log.warn("kindjal: no weapon", name, w)
    else
        for field, raw in pairs(fields) do
            local value, why = resolve(w, name, field, raw)
            local okSet, err = false, why
            if value ~= nil then okSet, err = pcall(w.set, w, field, value) end
            if okSet then
                applied = applied + 1
            else
                refused = refused + 1
                wum.log.warn("kindjal:", name, field, "refused:", err)
            end
        end
    end
end
wum.log.info(string.format("kindjal %s: %d fields applied, %d refused (knockback x%.2f, reach x%.2f, melee x%.2f)",
    tostring(wum.mod.version), applied, refused, KNOCKBACK, REACH, MELEE))

-- Acid bursts: tell the client where the acid landed. One string carries everything; the client parses it.
-- kind 0 = Acid Spitter, 1 = Acid Flask, 2 = Crucible (no acid, but the client plays the heavy impact).
local function burst(x, y, z, radius, kind)
    local ok, why = wum.sim.sendString("Kindjal.Burst", string.format("%.1f,%.1f,%.1f,%d,%d", x, y, z, radius, kind))
    if not ok then wum.log.warn("kindjal: Kindjal.Burst not sent:", why) end
end

wum.sim.weapons.on("explosion", "kWeaponAcidSpitter", function(event, name, tick, x, y, z)
    burst(x, y, z, 70, 0)
end)

-- The flask shatters: two more acid bursts 40 units to each side, same tick (<= [Weapons] ExtraPerExplosion).
local FLASK_SIDES = { { 40, 0, 0 }, { -40, 0, 0 } }
wum.sim.weapons.on("explosion", "kWeaponAcidFlask", function(event, name, tick, x, y, z)
    for i = 1, table.getn(FLASK_SIDES) do
        local d = FLASK_SIDES[i]
        local ok, why = wum.sim.weapons.explode(d[1], d[2], d[3])
        if not ok then wum.log.warn("kindjal: flask side burst failed:", why) end
    end
    burst(x, y, z, 100, 1)
end)

wum.sim.weapons.on("explosion", "kWeaponCrucible", function(event, name, tick, x, y, z)
    burst(x, y, z, 243, 2)
end)
