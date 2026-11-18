-- Kindjal, the sim side (Lua 5.0, the match VM; no "#", no "%"). Runs identically on every peer.
-- Needs Melange 0.16 (spice.json range): the Grave Spade at the end uses wum.sim.melee, carve and worm:kill.
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
    -- The Grave Spade (the Bat's slot, see the end of this file). Its own numbers are the Shiv's, so a strike the spade
    -- code does not see still lands as the Shiv would; every hit it does see is set from the Shiv's live numbers. Radius
    -- is the swing's reach (a spade is longer than a knife). RetreatTimeOverride 0: a strike ends the turn at once.
    -- MinAimAngle/MaxAimAngle open the aim to nearly straight down and up, so the spade can dig in any direction.
    kWeaponBaseballBat = { WormDamageMagnitude = 10, ImpulseMagnitude = 0.15, Radius = 20,
                           WormCollisionFX = "WXP_ShotgunHit", RetreatTimeOverride = 0,
                           MinAimAngle = -85, MaxAimAngle = 85 },
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
    -- The engine's held spade is an invisible speck: the client draws the real one in the worm's (posed) hands.
    kWeaponBaseballBat     = { W = "kindjal.GraveSpadeHidden" },
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

-- ================================================================ the Grave Spade
-- The Bat's slot is the Grave Spade, a tool first. Melange 0.16's wum.sim.melee gate takes the fire button: a press with
-- no worm in the swing is swallowed (no swing, no ammo, no Weapon.Fired, the turn goes on) and digs instead; a press with
-- a worm in the swing is the engine's own swing, which ends the turn. So:
--   tap   one scoop along the aim: a short carveLine from the worm's middle out to SPADE.REACH;
--   hold  another scoop every SPADE.STROKE ticks for as long as fire is held. A scoop that finds nothing left to take,
--         or the SPADE.SAME-th along one line, reaches SPADE.STEP further (up to SPADE.MAX), so holding still keeps
--         digging forward into the face. Walk into the hole and hold again to go deeper.
-- Voxel land and buildings open into a cave. The heightmap ground some maps stand on is a height field: the engine can
-- only lower it, so there the spade digs a pit or a trench (aim down to go deeper), never a roof over the worm.
-- A held dig that reaches a worm stays a dig (the gate decides at the press): a strike is always a fresh press.
-- A carve never touches water (the sea is a plane, not voxels): dig below the waterline and it is open sea, and a worm that
-- walks in drowns as usual.
--
-- The first spade hit on a worm in the whole match is an execution: the hit is cancelled in the hit handler (nothing that
-- calls the engine is allowed there), and from the next tick the sim holds the next turn start, pins both worms, tells the
-- clients (Kindjal.Spade "x,...") and kills the victim SPADE.CHOP ticks later through the engine's own death (no
-- explosion; the gravestone stays). The clients play the cinematic over that fixed timeline; everything they draw is
-- theirs alone. After the execution a spade hit does exactly what the Shiv does: its damage and knockback, read from the
-- Shiv's container once every mod's top-level chunk has run (so Kindjal Heavy's or Brutal's Shiv is the one copied).
--
-- All state is in wum.sim.storage.spade (hashed by Wormsign every tick the script runs). Times are sim ticks (50 a
-- second), the same on every machine; nothing here reads a clock, a random number or anything a machine keeps alone.
SPADE = {
    WEAPON = "kWeaponBaseballBat",
    CENTRE = 12,        -- the worm's middle above its feet
    NEAR = 8,           -- a scoop starts this far out along the aim
    REACH = 36,         -- and reaches this far at first
    STEP = 16,          -- a scoop that took nothing reaches this much further next time
    SAME = 3,           -- and so does the scoop after SAME scoops along one line, whatever they took
    MAX = 84,           -- the furthest a scoop reaches (8 spheres at RADIUS / 2 spacing)
    RADIUS = 22,        -- each sphere's radius: a worm's height across, two thirds of a voxel
    STROKE = 18,        -- ticks between scoops while fire is held (0.36 s; 83 in a 30 s turn, inside the 900-sphere budget)
    HOLD = 800,         -- the turn-start hold armed for the execution (released at END)
    CHOP = 270,         -- ticks after the execution starts: the blade comes down
    -- The victim's throes after the chop: its body is drawn this long (3 s), lying where the clients laid it, with its
    -- neck cut to a stump, and their copy of its head (wum.render.wormCopy) is drawn from it while it flies. A constant:
    -- no client choice reaches the sim. A client without poses hides the upright body under the chop's burst.
    THROES = 150,
    END = 520,          -- the cinematic is over: pins released, the next turn may start
    CONFIRM = 30,       -- a kill not confirmed by then (the victim still alive) aborts the execution
    SHIV_D = 10,        -- the Shiv's numbers if its container cannot be read (Kindjal's own)
    SHIV_I = 0.15,
}

local STORE = wum.sim.storage
STORE.spade = STORE.spade or {}
local G = STORE.spade         -- exec: true once the match's execution is used; ex: the running one; dig: the held dig
local digTimer = nil

local function spadeSend(text)
    local ok, why = wum.sim.sendString("Kindjal.Spade", text)
    if not ok then wum.log.warn("kindjal: Kindjal.Spade not sent:", why) end
end

-- The Shiv's live numbers, read one tick in (after every mod's chunk set its own).
local function readShiv()
    local d, i = SPADE.SHIV_D, round(SPADE.SHIV_I * KNOCKBACK * MELEE, 1000)
    local ok, w = pcall(wum.sim.weapon, "kWeaponProd")
    if ok and w then
        local okD, vd = pcall(w.get, w, "WormDamageMagnitude")
        local okI, vi = pcall(w.get, w, "ImpulseMagnitude")
        if okD and type(vd) == "number" then d = vd end
        if okI and type(vi) == "number" then i = round(vi, 1000) end
    end
    G.shivD, G.shivI = d, i
end

-- One scoop by the worm in `slot` along its aim; tells the clients where it dug and how much it took.
local function scoop(slot, tick)
    local w = wum.sim.worm(slot)
    if not w or not w:alive() then return end
    -- Only a worm standing on something digs (state 0). A worm that slides, jumps, flies or falls (a scoop can cut the
    -- ground from under it) takes nothing, and its held dig does not reach further in mid-air.
    if w:state() ~= 0 then return "airborne" end
    local x, y, z = w:pos()
    local pitch, yaw, dx, dy, dz = w:aim()
    if not dx then return end
    local d = G.dig
    if d and d.slot ~= slot then d = nil end
    local reach = (d and d.reach) or SPADE.REACH
    local cy = y + SPADE.CENTRE
    local x0, y0, z0 = x + dx * SPADE.NEAR, cy + dy * SPADE.NEAR, z + dz * SPADE.NEAR
    local x1, y1, z1 = x + dx * reach, cy + dy * reach, z + dz * reach
    local removed, n = wum.sim.carveLine(x0, y0, z0, x1, y1, z1, SPADE.RADIUS)
    local took = -1
    if removed == nil then
        if n ~= "budget" then wum.log.warn("kindjal: spade carve refused:", n) end
    else
        took = removed
        if d then
            -- Reach further once this line is dug out: a scoop that took nothing, or SPADE.SAME scoops along the same line
            -- (a voxel whose centre sits just outside every sphere, or a heightmap pit still settling, keeps answering a
            -- little; Melange counts only what really went, so a 0 is reliable, but a held dig must still move on).
            d.same = (d.same or 0) + 1
            if removed == 0 or d.same >= SPADE.SAME then
                d.reach = reach + SPADE.STEP
                if d.reach > SPADE.MAX then d.reach = SPADE.MAX end
                d.same = 0
            end
            d.n = d.n + 1
        end
    end
    -- d,slot,tick,x0,y0,z0,x1,y1,z1,removed (-1: refused, the turn's carve budget is spent)
    spadeSend(string.format("d,%d,%d,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%d", slot, tick, x0, y0, z0, x1, y1, z1, took))
end

local function digStop()
    if digTimer then wum.sim.cancel(digTimer) end
    digTimer = nil
    G.dig = nil
end

local function digTick()
    local d = G.dig
    if not d then return digStop() end
    if wum.sim.melee.held(SPADE.WEAPON) ~= d.slot then return digStop() end
    local w = wum.sim.worm(d.slot)
    local st = w and w:state()
    -- jump (1) or flying (2): the dig is over (fire must be pressed again on the ground); a slide (3) only pauses it
    if st == 1 or st == 2 or st == 7 or st == 8 then
        spadeSend(string.format("r,%d,%d,%d", d.slot, wum.sim.tick(), d.n))
        return digStop()
    end
    scoop(d.slot, wum.sim.tick())
end

-- ---------------------------------------------------------------- the execution
local function unpin(slot)
    local w = wum.sim.worm(slot)
    if w and w:anchored() then w:anchor(false) end
end

local function exAbort(why)
    local e = G.ex
    if not e then return end
    wum.log.info("kindjal: execution aborted:", why)
    unpin(e.a)
    unpin(e.v)
    wum.sim.releaseTurn()
    spadeSend(string.format("a,%d,%d,%d", e.a, e.v, wum.sim.tick()))
    G.ex = nil
    if not e.chopped then G.exec = nil end       -- nobody lost a head: the next strike may still execute
end

local function exFinish()
    local e = G.ex
    if not e then return end
    unpin(e.a)
    unpin(e.v)
    wum.sim.releaseTurn()
    spadeSend(string.format("e,%d,%d,%d", e.a, e.v, wum.sim.tick()))
    G.ex = nil
end

local function exConfirm()
    local e = G.ex
    if not e then return end
    local w = wum.sim.worm(e.v)
    if w and w:alive() then exAbort("the kill was not confirmed") end
end

local function exChop()
    local e = G.ex
    if not e then return end
    local w = wum.sim.worm(e.v)
    if not w or not w:alive() then return exAbort("the victim died first") end
    local ok, why = w:kill({ explode = false, grave = true, throes = SPADE.THROES })
    if not ok then return exAbort(why) end
    e.chopped = true
    spadeSend(string.format("c,%d,%d,%d", e.a, e.v, wum.sim.tick()))
    wum.sim.after(SPADE.CONFIRM, exConfirm)
end

-- Pins a worm that stands (state 0) or lies still (6); a worm in the air stays free (a pin in mid-air would hold it there).
local function pinIfStill(slot)
    local w = wum.sim.worm(slot)
    if not w or not w:alive() then return end
    local st = w:state()
    if st == 0 or st == 6 then w:anchor(true) end
end

local function exStart()
    local e = G.ex
    if not e then return end
    local v = wum.sim.worm(e.v)
    local a = wum.sim.worm(e.a)
    if not v or not a or not v:alive() or v:state() == 8 then return exAbort("the victim is gone") end
    local t0 = wum.sim.tick()
    e.t0 = t0
    local ok, why = wum.sim.holdTurn(SPADE.HOLD)
    if not ok then wum.log.warn("kindjal: execution hold refused:", why) end
    pinIfStill(e.a)
    pinIfStill(e.v)
    local ax, ay, az = a:pos()
    local vx, vy, vz = v:pos()
    -- x,attacker,victim,t0,chop,throes,end,ax,ay,az,vx,vy,vz
    spadeSend(string.format("x,%d,%d,%d,%d,%d,%d,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f", e.a, e.v, t0, SPADE.CHOP, SPADE.THROES,
        SPADE.END, ax, ay, az, vx, vy, vz))
    wum.sim.after(SPADE.CHOP, exChop)
    wum.sim.after(SPADE.END, exFinish)
end

-- ---------------------------------------------------------------- the claim and the events
local melee = wum.sim.melee
if not (melee and wum.sim.carveLine and wum.sim.holdTurn) then
    wum.log.warn("kindjal: this Melange has no wum.sim.melee/carveLine: the Grave Spade is a plain Shiv-strength swing")
else
    local okClaim, whyClaim = melee.claim(SPADE.WEAPON, { dig = true, mode = "auto" })
    if not okClaim then
        wum.log.warn("kindjal: the Grave Spade could not claim", SPADE.WEAPON, whyClaim)
    else
        wum.sim.after(1, readShiv)

        melee.on("press", SPADE.WEAPON, function(ev, w, tick, slot, mode)
            if mode == "dig" then
                digStop()
                G.dig = { slot = slot, reach = SPADE.REACH, n = 0 }
                scoop(slot, tick)
                digTimer = wum.sim.every(SPADE.STROKE, digTick)
            else
                spadeSend(string.format("w,%d,%d", slot, tick))          -- a swing: the clients start the strike
            end
        end)

        melee.on("release", SPADE.WEAPON, function(ev, w, tick, slot, heldTicks, mode)
            local d = G.dig
            if d and d.slot == slot then
                spadeSend(string.format("r,%d,%d,%d", slot, tick, d.n))
                digStop()
            end
        end)

        -- Inside the engine's strike: decide only (result), and do the rest from the next tick.
        melee.on("hit", SPADE.WEAPON, function(ev, w, tick, attacker, victim, x, y, z, damage, impulse)
            local vw = wum.sim.worm(victim)
            if not G.exec and not G.ex and attacker ~= victim and vw and vw:alive() and vw:state() ~= 8 then
                G.exec = true
                G.ex = { a = attacker, v = victim, hit = tick }
                melee.result({ cancel = true })
                wum.sim.after(1, exStart)
                return
            end
            -- level: the Bat's knockback follows its aim, so a Shiv-sized impulse aimed up lofted the victim into the sea;
            -- along the ground it is the Shiv's shove (Melange 0.16 drops the vertical part for this hit)
            melee.result({ damage = G.shivD or SPADE.SHIV_D, impulse = G.shivI or SPADE.SHIV_I, level = true })
            wum.sim.after(1, function() spadeSend(string.format("h,%d,%d,%d", attacker, victim, tick)) end)
        end)

        -- A new turn: whatever dig was held is over (the release normally said so already).
        wum.events.on("sim.turnStarted", function() digStop() end)
    end
end
