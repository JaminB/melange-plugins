-- Kindjal Brutal, the sim side (Lua 5.0, the match VM; no "#", no "%"). Runs identically on every peer.
--
-- An add-on for Kindjal 1.2.0 or later. It restores the knockback Kindjal 1.0.0 shipped with, two to three times the
-- game's own. Melange runs every mod's sim script in load order and this mod depends on kindjal, so this chunk runs
-- after Kindjal's and its values win (wum.sim.weapon(name):set is last-write-wins; Melange restores the game's own
-- numbers at match end).
--
-- The values are absolute, copied from Kindjal 1.0.0's sim script and manifest, so they do not move with Kindjal's own
-- KNOCKBACK / REACH / MELEE constants. Where 1.0.0 set no ImpulseRadius (the melee weapons, the Slug Gun, the Acid
-- Spitter and the Acid Flask) none is set here and Kindjal 1.1.0's stays. The one value that is not 1.0.0's is the
-- Buddy Bomb's (the sheep's slot, a weapon 1.0.0 did not have): its blast is bigger than the Plague Ram's, so it throws
-- harder than the Plague Ram's 0.70 / 170 here too.
--
-- A content mod: its sim script is in the content hash, so every player in an online match must have the same Kindjal
-- add-on enabled, or none.
-- name -> { ImpulseMagnitude, ImpulseRadius or nil }
local KNOCKBACK = {
    -- melee
    kWeaponBaseballBat = { 0.60 },
    kWeaponFirePunch   = { 0.50 },
    kWeaponProd        = { 0.30 },
    kWeaponNoMoreNails = { 0.20 },

    -- launchers and thrown
    kWeaponBazooka         = { 0.64, 155 },
    kWeaponGrenade         = { 0.45, 110 },
    kWeaponDynamite        = { 0.90, 200 },
    kWeaponHolyHandGrenade = { 0.80, 200 },

    -- clusters, mines, homing
    kWeaponBananaBomb    = { 0.70, 150 },
    kWeaponBananette     = { 0.70, 160 },
    kWeaponClusterBomb   = { 0.30, 110 },
    kWeaponLandmine      = { 0.60, 140 },
    kWeaponHomingMissile = { 0.85, 160 },

    -- air strikes, animals, specials
    kWeaponAirstrike      = { 0.50, 150 },
    kWeaponSuperAirstrike = { 0.70, 180 },
    kWeaponConcreteDonkey = { 1.30, 280 },
    kWeaponSheep          = { 0.85, 200 },   -- the Buddy Bomb; not a 1.0.0 number (see above)
    kWeaponSuperSheep     = { 0.70, 170 },
    kWeaponOldWoman       = { 0.90, 170 },
    kWeaponScouser        = { 0.50, 90 },
    kWeaponFatkins        = { 1.80, 260 },
    kWeaponFatkinsFood    = { 1.00, 180 },
    kWeaponStarburst      = { 1.60, 220 },

    -- guns, gas
    kWeaponShotgun          = { 0.20 },
    kWeaponSniperRifle      = { 0.80, 90 },
    kWeaponSentryGunPayload = { 0.50, 130 },
    kWeaponGasCanister      = { 0.30, 90 },

    -- the three new weapons
    kWeaponAcidSpitter = { 0.25 },
    kWeaponAcidFlask   = { 0.15 },
    kWeaponCrucible    = { 1.35, 195 },
}

local applied, refused = 0, 0

local function put(name, w, field, value)
    local okSet, err = pcall(w.set, w, field, value)
    if okSet then
        applied = applied + 1
    else
        refused = refused + 1
        wum.log.warn("kindjal-brutal:", name, field, "refused:", err)
    end
end

for name, v in pairs(KNOCKBACK) do
    local ok, w = pcall(wum.sim.weapon, name)
    if not ok or not w then
        refused = refused + 1
        wum.log.warn("kindjal-brutal: no weapon", name, w)
    else
        put(name, w, "ImpulseMagnitude", v[1])
        if v[2] then put(name, w, "ImpulseRadius", v[2]) end
    end
end
wum.log.info(string.format("kindjal-brutal %s: %d fields applied, %d refused", tostring(wum.mod.version), applied, refused))
