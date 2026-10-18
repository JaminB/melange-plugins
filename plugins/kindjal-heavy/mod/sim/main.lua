-- Kindjal Heavy, the sim side (Lua 5.0, the match VM; no "#", no "%"). Runs identically on every peer.
--
-- An add-on for Kindjal 1.2.0 or later. Melange runs every mod's sim script in load order and this mod depends on
-- kindjal, so by the time this chunk runs Kindjal has already written its knockback. Each field is read back with
-- w:get(field) (that is the value Kindjal wrote, its own KNOCKBACK / REACH / MELEE multipliers included), scaled, and
-- written again; wum.sim.weapon(name):set is last-write-wins and Melange restores the game's own numbers at match end.
-- Reading back, rather than repeating Kindjal's numbers, means this stays correct if Kindjal retunes a weapon.
--
-- Like Kindjal, this is a content mod: its sim script is in the content hash, so every player in an online match
-- must have the same Kindjal add-on enabled, or none. A sim script cannot read the Mods page (no wum.config in the
-- match VM), so the two factors are constants here; editing them gives a different mod hash and the host refuses
-- the mismatch.
KNOCKBACK = 1.4   -- every ImpulseMagnitude Kindjal set, times this (Kindjal is about vanilla x1.2, so this is about x1.7)
REACH     = 1.15  -- every ImpulseRadius Kindjal set, times this

-- Every weapon Kindjal sets knockback on, the three clones included. radius = true where Kindjal also sets
-- ImpulseRadius (the four melee weapons and the Slug Gun have only a magnitude; Kindjal's Radius on the melee weapons
-- is a hit reach, not touched here).
local WEAPONS = {
    { "kWeaponBaseballBat" }, { "kWeaponFirePunch" }, { "kWeaponProd" }, { "kWeaponNoMoreNails" },
    { "kWeaponBazooka", true }, { "kWeaponGrenade", true }, { "kWeaponDynamite", true },
    { "kWeaponHolyHandGrenade", true },
    { "kWeaponBananaBomb", true }, { "kWeaponBananette", true }, { "kWeaponClusterBomb", true },
    { "kWeaponLandmine", true }, { "kWeaponHomingMissile", true },
    { "kWeaponAirstrike", true }, { "kWeaponSuperAirstrike", true }, { "kWeaponConcreteDonkey", true },
    { "kWeaponSheep", true }, { "kWeaponSuperSheep", true }, { "kWeaponOldWoman", true },
    { "kWeaponScouser", true }, { "kWeaponFatkins", true }, { "kWeaponFatkinsFood", true },
    { "kWeaponStarburst", true },
    { "kWeaponShotgun" }, { "kWeaponSniperRifle", true }, { "kWeaponSentryGunPayload", true },
    { "kWeaponGasCanister", true },
    { "kWeaponAcidSpitter", true }, { "kWeaponAcidFlask", true }, { "kWeaponCrucible", true },
}

-- Rounded to a fixed step (0.001 for knockback, 1 unit for reach), as Kindjal does, so the number written is a plain
-- function of the number read.
local function round(v, per) return math.floor(v * per + 0.5) / per end

local applied, refused = 0, 0

local function scale(name, w, field, factor, per)
    local okGet, base = pcall(w.get, w, field)
    if not okGet or type(base) ~= "number" then
        refused = refused + 1
        wum.log.warn("kindjal-heavy:", name, field, "refused (cannot read Kindjal's value):", base)
        return
    end
    local okSet, err = pcall(w.set, w, field, round(base * factor, per))
    if okSet then
        applied = applied + 1
    else
        refused = refused + 1
        wum.log.warn("kindjal-heavy:", name, field, "refused:", err)
    end
end

for i = 1, table.getn(WEAPONS) do
    local name = WEAPONS[i][1]
    local ok, w = pcall(wum.sim.weapon, name)
    if not ok or not w then
        refused = refused + 1
        wum.log.warn("kindjal-heavy: no weapon", name, w)
    else
        scale(name, w, "ImpulseMagnitude", KNOCKBACK, 1000)
        if WEAPONS[i][2] then scale(name, w, "ImpulseRadius", REACH, 1) end
    end
end
wum.log.info(string.format("kindjal-heavy %s: %d fields applied, %d refused (knockback x%.2f, reach x%.2f)",
    tostring(wum.mod.version), applied, refused, KNOCKBACK, REACH))
