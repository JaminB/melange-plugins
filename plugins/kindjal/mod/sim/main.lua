-- Kindjal, the sim side (Lua 5.0, the match VM; no "#", no "%"). Runs identically on every peer.
--
-- Everything here happens in this top-level chunk at match Init: wum.sim.weapon(name):set is only allowed then, and
-- a value written here is the same number on every machine, so there is nothing for Wormsign to disagree on. The
-- clone handlers below post one engine message per acid burst (the client paints the acid from it) and queue the
-- Acid Flask's two side bursts; both are deterministic by construction (same tick, same offsets, no randomness).
--
-- Values are absolute, chosen by the user weapon by weapon (see the README's table), not multipliers of what is
-- read back, so a reviewer can see the exact number a match plays with.

-- name -> { field = value }. Field types come from the engine's own schema: numbers for F32/I32/U8/U32, true/false
-- for Bool, strings for String. NumBomblets is U32 and needs Melange 0.9; on an older build the set fails and the
-- banana keeps five.
STATS = {
    -- melee (MeleeWeaponPropertiesContainer)
    -- The held mesh is the plugin's own (assets/meshes/kindjal.NailBat.xom, declared in spice.json "meshes").
    kWeaponBaseballBat = { WormDamageMagnitude = 45, ImpulseMagnitude = 0.60, Radius = 24,
                           WormCollisionFX = "WXP_ShotgunBlast", WeaponGraphicsResourceID = "kindjal.NailBat" },
    kWeaponFirePunch   = { WormDamageMagnitude = 40, ImpulseMagnitude = 0.50, Radius = 18,
                           WormCollisionFX = "WXP_Explosion_Small" },
    kWeaponProd        = { WormDamageMagnitude = 10, ImpulseMagnitude = 0.30, Radius = 6,
                           WormCollisionFX = "WXP_ShotgunHit" },
    kWeaponNoMoreNails = { WormDamageMagnitude = 30, ImpulseMagnitude = 0.20, Radius = 22 },

    -- launchers and thrown
    kWeaponBazooka         = { WormDamageMagnitude = 65, WormDamageRadius = 95, LandDamageRadius = 75,
                               ImpulseMagnitude = 0.64, ImpulseRadius = 155, DetonationFx = "WXP_ExplosionX_Large" },
    kWeaponGrenade         = { WormDamageMagnitude = 85, WormDamageRadius = 85, LandDamageRadius = 60,
                               ImpulseMagnitude = 0.45, ImpulseRadius = 110 },
    kWeaponDynamite        = { WormDamageMagnitude = 80, WormDamageRadius = 150, LandDamageRadius = 120,
                               ImpulseMagnitude = 0.90, ImpulseRadius = 200 },
    kWeaponHolyHandGrenade = { WormDamageMagnitude = 100, WormDamageRadius = 200, LandDamageRadius = 150,
                               ImpulseMagnitude = 0.80, ImpulseRadius = 200 },

    -- clusters, mines, homing
    kWeaponBananaBomb      = { NumBomblets = 7, ImpulseMagnitude = 0.70, ImpulseRadius = 150 },
    kWeaponBananette       = { ImpulseMagnitude = 0.70, ImpulseRadius = 160 },
    kWeaponClusterGrenade  = { WormDamageMagnitude = 25 },
    kWeaponClusterBomb     = { WormDamageMagnitude = 30, ImpulseMagnitude = 0.30, ImpulseRadius = 110,
                               DetonationFx = "WXP_ExplosionX_Med" },
    kWeaponLandmine        = { WormDamageMagnitude = 55, WormDamageRadius = 85, LandDamageRadius = 65,
                               ImpulseMagnitude = 0.60, ImpulseRadius = 140 },
    kWeaponHomingMissile   = { WormDamageMagnitude = 45, ImpulseMagnitude = 0.85, ImpulseRadius = 160 },

    -- air strikes, animals, specials
    kWeaponAirstrike       = { WormDamageMagnitude = 35, WormDamageRadius = 80, LandDamageRadius = 72,
                               ImpulseMagnitude = 0.50, ImpulseRadius = 150 },
    kWeaponSuperAirstrike  = { WormDamageMagnitude = 100, WormDamageRadius = 145, LandDamageRadius = 105,
                               ImpulseMagnitude = 0.70, ImpulseRadius = 180 },
    kWeaponConcreteDonkey  = { LandDamageRadius = 180, ImpulseMagnitude = 1.30, ImpulseRadius = 280 },
    kWeaponSheep           = { WormDamageMagnitude = 95, WormDamageRadius = 130, LandDamageRadius = 105,
                               ImpulseMagnitude = 0.70, ImpulseRadius = 170 },
    kWeaponSuperSheep      = { WormDamageMagnitude = 95, WormDamageRadius = 130, LandDamageRadius = 105,
                               ImpulseMagnitude = 0.70, ImpulseRadius = 170 },
    kWeaponOldWoman        = { WormDamageMagnitude = 82, ImpulseMagnitude = 0.90, ImpulseRadius = 170 },
    kWeaponScouser         = { WormDamageMagnitude = 44, ImpulseMagnitude = 0.50, ImpulseRadius = 90 },
    kWeaponFatkins         = { WormDamageMagnitude = 82, ImpulseMagnitude = 1.80, ImpulseRadius = 260 },
    kWeaponFatkinsFood     = { WormDamageMagnitude = 72, ImpulseMagnitude = 1.00, ImpulseRadius = 180 },
    kWeaponStarburst       = { WormDamageMagnitude = 110, ImpulseMagnitude = 1.60, ImpulseRadius = 220 },

    -- guns, arrow, gas
    kWeaponShotgun         = { WormDamageMagnitude = 50, LandDamageMagnitude = 35, ImpulseMagnitude = 0.20,
                               Accuracy = 0.97 },
    kWeaponSniperRifle     = { WormDamageMagnitude = 45, ImpulseMagnitude = 0.80, ImpulseRadius = 90 },
    -- The sentry's shots: the payload container carries no numbers of its own in WEAPTWK, so these may be refused
    -- or ignored by the engine; the log says which.
    kWeaponSentryGunPayload = { WormDamageMagnitude = 80, WormDamageRadius = 95, LandDamageRadius = 70,
                                ImpulseMagnitude = 0.50, ImpulseRadius = 130 },
    kWeaponPoisonArrow     = { WormImpactDamage = 45 },
    -- A canister has no blast in vanilla; whether the engine honours damage on it is unverified (see README).
    kWeaponGasCanister     = { WormDamageMagnitude = 20, WormDamageRadius = 60, LandDamageRadius = 40,
                               ImpulseMagnitude = 0.30, ImpulseRadius = 90 },
}

-- Applies every entry; a refused field is logged and skipped so one bad name never takes the rest down with it.
local applied, refused = 0, 0
for name, fields in pairs(STATS) do
    local ok, w = pcall(wum.sim.weapon, name)
    if not ok or not w then
        wum.log.warn("kindjal: no weapon", name, w)
    else
        for field, value in pairs(fields) do
            local okSet, err = pcall(w.set, w, field, value)
            if okSet then
                applied = applied + 1
            else
                refused = refused + 1
                wum.log.warn("kindjal:", name, field, "refused:", err)
            end
        end
    end
end
wum.log.info(string.format("kindjal %s: %d fields applied, %d refused", tostring(wum.mod.version), applied, refused))

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
