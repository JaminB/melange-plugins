-- Grave Spade FX: every dirt, dust, spark and gore particle of the spade, plus a camera-shake helper.
--
-- Client only (Lua 5.4 sandbox), so nothing here can desync: it reads the camera and casts land rays, and draws sprites.
-- Mods have no `require`, so this file is a chunk that ends in `return M`. Use it from init.lua by pasting it inside
--     local SpadeFX = (function() ... this file ... end)()
-- (one function scope, so it adds one local to init.lua's 200 limit), or by building init.lua from the two files.
-- It brings its own particle pool, its own world callback (drawn at "worldLate") and its own timing, and it loads its
-- textures itself (textures/kj_dirt1..4, kj_dust1..2, kj_stonechip, kj_bloodmist, kj_gore_chunk, kj_spark, kj_glint).
-- Everything is a no-op if wum.draw.sprite or a texture is missing; a bad call never raises.
--
-- Units are world units (a worm is about 20 high). Directions (dx, dy, dz) need not be unit length. Colours are
-- 0xRRGGBB. `material` is "soil", "sand", "stone" or "building" (anything else is soil).
--
--   M.scoop(x, y, z, dx, dy, dz, material, power)   one scoop: clods, dust, chips and sparks. (dx,dy,dz) is the blade's
--                                                   travel; power 0.3..2, default 1
--   M.dig(id, x, y, z, dx, dy, dz, material, power) call every frame while fire is held: a continuous spray. `id` is any
--                                                   string or number (one stream per worm); stops by itself 0.15 s after
--                                                   the last call, with a final settle puff
--   M.digStop(id)                                   end a stream now
--   M.settle(x, y, z, radius, material)             dust that hangs over a fresh cut, spreads along the floor, and
--                                                   thins out over several seconds, with fine grains falling through it
--   M.sparks(x, y, z, dx, dy, dz, n, material)      blade sparks (stone and building) with a glint; (dx,dy,dz) is the
--                                                   direction the sparks fly, n defaults to 10
--   M.headOff(x, y, z, dx, dz, opts)                the decapitation without Bloodsand: a shock ring of dust, a sand and
--                                                   dust fountain from the neck, and flung grit. opts: {blood = true}
--                                                   adds mist and gore chunks (only when Bloodsand is off and you still
--                                                   want a red result), {scale = 1}
--   M.shake(amount, seconds)                        start or add to a camera shake (amount in world units, 0.5..6)
--   M.shakeOffset()                                 -> ox, oy, oz for this frame (0,0,0 when still)
--   M.shakeCam(spec)                                adds the shake to a wum.render.cameraOverride spec ({pos,target,...},
--                                                   tables {x,y,z} or {x=,y=,z=}) and returns it
--   M.clear()  M.count()  M.setQuality(0..1)  M.ready()  M.preview(x, y, z)

local M = {}

local floor, sqrt, sin, cos, exp, abs, max, min = math.floor, math.sqrt, math.sin, math.cos, math.exp, math.abs, math.max, math.min
local random = math.random

-- ---------------------------------------------------------------- tunables
local CFG = {
    maxParticles = 700,
    gravity = 360,            -- world units a second squared for clods
    rayCap = 20,              -- land rays this module casts a frame (Melange's 256 is shared by every mod)
    quality = 1.0,            -- scales particle counts; see M.setQuality
    streamRate = 46,          -- clods a second while digging, at power 1 (dust and sparks follow it)
    streamTimeout = 0.15,
    maxDt = 1 / 15,
}

-- tint colours (0xRRGGBB) per material: clods, dust, and the grit that the sparks come from
local MAT = {
    soil     = { clod = { 0x6b4a2c, 0x5a3d24, 0x7c5733, 0x4e3620 }, dust = 0x9a7a55, chip = 0x7a5a3a, sparks = 0 },
    sand     = { clod = { 0xc8a868, 0xb89858, 0xd4b878, 0xa88c50 }, dust = 0xd8c08a, chip = 0xc8a868, sparks = 0 },
    stone    = { clod = { 0x8a8a86, 0x75756f, 0x9c9a92, 0x66665f }, dust = 0xa29e94, chip = 0x9a988f, sparks = 1 },
    building = { clod = { 0x9a7e6a, 0x866a58, 0xa8907c, 0x6e5848 }, dust = 0xb8a898, chip = 0xa89684, sparks = 1 },
}
M.MATERIAL = MAT          -- a plugin may tweak the tints (or add a material table with the same fields)

local function mat(name)
    return MAT[name] or MAT.soil
end

-- ---------------------------------------------------------------- state
local TEX = { dirt = {}, dust = {} }
local loaded, loadFailAt = false, 0
local installed = false
local lastClock = nil
local rayUsed = 0
local rayFn = nil
local rayOffUntil = 0

local K_CLOD, K_DUST, K_SPARK, K_GLINT, K_GRAIN, K_MIST, K_RING = 1, 2, 3, 4, 5, 6, 7
local N = 0
local P = { x = {}, y = {}, z = {}, vx = {}, vy = {}, vz = {}, s0 = {}, s1 = {}, age = {}, life = {}, kind = {}, tex = {},
            rgb = {}, a = {}, drag = {}, grav = {}, rot = {}, spin = {}, bounce = {}, add = {}, bias = {} }
local PARTS = {}
for _, arr in pairs(P) do PARTS[#PARTS + 1] = arr end

local STREAM = {}             -- id -> { x,y,z,dx,dy,dz, material, power, last, acc }
local LATER = {}              -- delayed calls: { at = clock, fn = function }
local RUN = {}                -- per-frame calls until a time: { to = clock, fn = function }
local SHAKE = { amp = 0, t = 0, dur = 0.01, seed = 0, ox = 0, oy = 0, oz = 0, at = -1 }
local CAM = { ok = false, rx = 1, ry = 0, rz = 0, ux = 0, uy = 1, uz = 0, fx = 0, fy = 0, fz = 1 }
local nextId = 0

-- ---------------------------------------------------------------- helpers
local function clamp(v, a, b) return v < a and a or (v > b and b or v) end

local function now()
    local ok, c = pcall(os.clock)
    return ok and c or 0
end

local function norm(x, y, z)
    local l = sqrt(x * x + y * y + z * z)
    if l < 1e-6 then return 0, 1, 0, 0 end
    return x / l, y / l, z / l, l
end

local function vec(v)
    if type(v) ~= "table" then return nil end
    local x, y, z = tonumber(v.x or v[1]), tonumber(v.y or v[2]), tonumber(v.z or v[3])
    if x and y and z then return x, y, z end
end

-- 0xRRGGBB and an alpha 0..1 -> 0xRRGGBBAA (an integer)
local function rgba(c, a)
    return ((c & 0xffffff) << 8) | floor(clamp(a, 0, 1) * 255 + 0.5)
end

local function rnd(a, b) return a + (b - a) * random() end

local function pick(t) return t[random(1, #t)] end

local function scaled(n)
    local v = n * CFG.quality
    local w = floor(v)
    if random() < v - w then w = w + 1 end
    return w
end

local function varyColor(c, amt)
    local k = 1 + (random() * 2 - 1) * amt
    local r, g, b = ((c >> 16) & 255) * k, ((c >> 8) & 255) * k, (c & 255) * k
    return (floor(clamp(r, 0, 255)) << 16) | (floor(clamp(g, 0, 255)) << 8) | floor(clamp(b, 0, 255))
end

-- ---------------------------------------------------------------- textures
local function loadTextures()
    if loaded then return true end
    if not (wum and wum.draw and wum.draw.texture and wum.draw.sprite) then return false end
    if now() < loadFailAt then return false end
    local function tex(name)
        local ok, id = pcall(wum.draw.texture, "textures/kj_" .. name .. ".png")
        if ok and type(id) == "number" then return id end
        return nil
    end
    for i = 1, 4 do TEX.dirt[i] = tex("dirt" .. i) end
    for i = 1, 2 do TEX.dust[i] = tex("dust" .. i) end
    TEX.chip, TEX.mist, TEX.gore = tex("stonechip"), tex("bloodmist"), tex("gore_chunk")
    TEX.spark, TEX.glint = tex("spark"), tex("glint")
    -- Usable if the core ones came up; anything else missing just drops that effect.
    if TEX.dirt[1] and TEX.dust[1] then
        for i = 2, 4 do TEX.dirt[i] = TEX.dirt[i] or TEX.dirt[1] end
        TEX.dust[2] = TEX.dust[2] or TEX.dust[1]
        loaded = true
        return true
    end
    loadFailAt = now() + 10
    return false
end

-- ---------------------------------------------------------------- camera and rays
local function readCamera()
    CAM.ok = false
    if not (wum.render and wum.render.camera) then return end
    local ok, c = pcall(wum.render.camera)
    if not ok or type(c) ~= "table" then return end
    local fx, fy, fz = vec(c.fwd)
    local ux, uy, uz = vec(c.up)
    if not (fx and ux) then return end
    fx, fy, fz = norm(fx, fy, fz)
    local rx, ry, rz = fy * uz - fz * uy, fz * ux - fx * uz, fx * uy - fy * ux
    local l = sqrt(rx * rx + ry * ry + rz * rz)
    if l < 1e-6 then return end
    rx, ry, rz = rx / l, ry / l, rz / l
    ux, uy, uz = ry * fz - rz * fy, rz * fx - rx * fz, rx * fy - ry * fx
    CAM.rx, CAM.ry, CAM.rz, CAM.ux, CAM.uy, CAM.uz, CAM.fx, CAM.fy, CAM.fz = rx, ry, rz, ux, uy, uz, fx, fy, fz
    CAM.ok = true
end

-- t, nx, ny, nz or nil (miss, no ray left, or unavailable). Failure turns rays off for ten seconds.
local function ray(x0, y0, z0, x1, y1, z1)
    if rayUsed >= CFG.rayCap then return nil end
    if rayFn == nil then
        rayFn = (wum.game and wum.game.landRay) or false
    end
    if not rayFn or now() < rayOffUntil then return nil end
    rayUsed = rayUsed + 1
    local ok, t, nx, ny, nz = pcall(rayFn, x0, y0, z0, x1, y1, z1)
    if not ok then
        rayOffUntil = now() + 10
        return nil
    end
    if type(t) ~= "number" or type(nx) ~= "number" or type(ny) ~= "number" or type(nz) ~= "number" then
        if nx == "unavailable" then rayOffUntil = now() + 10 end
        return nil
    end
    local a, b, c = norm(nx, ny, nz)
    return t, a, b, c
end

-- ---------------------------------------------------------------- particles
local function spawn(kind, tex, add, x, y, z, vx, vy, vz, s0, s1, life, color, a, drag, grav, rot, spin, bounce, delay)
    if not tex or N >= CFG.maxParticles then return false end
    N = N + 1
    local i = N
    nextId = nextId + 1
    P.x[i], P.y[i], P.z[i], P.vx[i], P.vy[i], P.vz[i] = x, y, z, vx, vy, vz
    P.s0[i], P.s1[i], P.age[i], P.life[i], P.kind[i], P.tex[i] = s0, s1, -(delay or 0), life, kind, tex
    P.add[i], P.rgb[i], P.a[i], P.drag[i], P.grav[i], P.rot[i], P.spin[i] = add, color, a, drag, grav, rot or 0, spin or 0
    P.bounce[i] = bounce or 0
    P.bias[i] = 0.2 + ((nextId * 0.6180339887) % 1) * 0.5      -- toward the camera, so overlapping sprites never z-fight
    return i
end

local function remove(i)
    for k = 1, #PARTS do
        local arr = PARTS[k]
        arr[i] = arr[N]
    end
    N = N - 1
end

local function envelope(age, life, tin, fout)
    local e = 1
    if age < tin then
        local u = age / tin
        e = u * u * (3 - 2 * u)
    end
    local v = (age / life - (1 - fout)) / fout
    if v > 0 then
        if v >= 1 then return 0 end
        e = e * (1 - v * v * (3 - 2 * v))
    end
    return e
end

-- A direction inside a cone of half angle `spread` (radians) around (dx,dy,dz), unit result.
local function cone(dx, dy, dz, spread)
    dx, dy, dz = norm(dx, dy, dz)
    local ax, ay, az = 0, 1, 0
    if abs(dy) > 0.9 then ax, ay, az = 1, 0, 0 end
    local px, py, pz = norm(dy * az - dz * ay, dz * ax - dx * az, dx * ay - dy * ax)
    local qx, qy, qz = dy * pz - dz * py, dz * px - dx * pz, dx * py - dy * px
    local ang = random() * 6.2831853
    local r = sin(spread * sqrt(random()))
    local c = sqrt(max(0, 1 - r * r))
    local ca, sa = cos(ang) * r, sin(ang) * r
    return dx * c + px * ca + qx * sa, dy * c + py * ca + qy * sa, dz * c + pz * ca + qz * sa
end

local function step(dt)
    local sprite = wum.draw.sprite
    local rx, ry, rz, ux, uy, uz = CAM.rx, CAM.ry, CAM.rz, CAM.ux, CAM.uy, CAM.uz
    local fx, fy, fz = CAM.fx, CAM.fy, CAM.fz
    local camOk = CAM.ok
    for i = N, 1, -1 do
        local age = P.age[i] + dt
        local life = P.life[i]
        if age >= life then
            remove(i)
        elseif age <= 0 then
            P.age[i] = age
        else
            P.age[i] = age
            local h = dt
            if age < h then h = age end
            local kind = P.kind[i]
            local x, y, z = P.x[i], P.y[i], P.z[i]
            local vx, vy, vz = P.vx[i], P.vy[i], P.vz[i]
            local dr, gr = P.drag[i], P.grav[i]
            if dr > 1e-4 then
                -- velocity under drag with gravity gr (positive pulls down): v' = -d v - g, exact over the step
                local e = exp(-dr * h)
                local f = (1 - e) / dr
                local vt = -gr / dr
                y = y + vt * h + (vy - vt) * f
                vy = (vy - vt) * e + vt
                x, z = x + vx * f, z + vz * f
                vx, vz = vx * e, vz * e
            else
                x, z = x + vx * h, z + vz * h
                y = y + vy * h - 0.5 * gr * h * h
                vy = vy - gr * h
            end
            -- Clods and sparks hit the land: one ray along the step, a bounce with friction, then they rest and fade.
            if (kind == K_CLOD or kind == K_SPARK or kind == K_GRAIN) and P.bounce[i] > 0 and vy < 0 then
                local ox, oy, oz = P.x[i], P.y[i], P.z[i]
                local t, nx, ny, nz = ray(ox, oy, oz, x, y, z)
                if t then
                    local hx, hy, hz = ox + (x - ox) * t + nx * 0.4, oy + (y - oy) * t + ny * 0.4, oz + (z - oz) * t + nz * 0.4
                    local vn = vx * nx + vy * ny + vz * nz
                    local e = P.bounce[i]
                    vx, vy, vz = (vx - nx * vn * (1 + e)) * 0.7, (vy - ny * vn * (1 + e)) * 0.7, (vz - nz * vn * (1 + e)) * 0.7
                    x, y, z = hx, hy, hz
                    P.bounce[i] = e * 0.45
                    if P.bounce[i] < 0.08 or (vx * vx + vy * vy + vz * vz) < 120 then
                        P.bounce[i] = 0
                        vx, vy, vz = 0, 0, 0
                        P.grav[i] = 0
                        P.drag[i] = 0
                        P.spin[i] = 0
                        if P.life[i] - age > 0.9 then P.life[i] = age + 0.9 end     -- a resting clod fades out
                    end
                end
            end
            P.x[i], P.y[i], P.z[i], P.vx[i], P.vy[i], P.vz[i] = x, y, z, vx, vy, vz

            life = P.life[i]
            local t = age / life
            local s0, s1 = P.s0[i], P.s1[i]
            local s = s0 + (s1 - s0) * t * (2 - t)
            local a = P.a[i]
            local ax, ay, az, hl, hw = 0, 0, 0, 0, nil
            if kind == K_CLOD or kind == K_GRAIN then
                a = a * envelope(age, life, 0.02, 0.35)
                local rot = P.rot[i] + P.spin[i] * h
                P.rot[i] = rot
                if camOk then
                    local c, sn = cos(rot), sin(rot)
                    ax, ay, az, hl = rx * c + ux * sn, ry * c + uy * sn, rz * c + uz * sn, s
                end
            elseif kind == K_DUST or kind == K_MIST then
                -- expands quickly, then drifts; the alpha eases in and out, so nothing pops
                s = s0 + (s1 - s0) * sqrt(t)
                a = a * envelope(age, life, 0.12, 0.8)
                local rot = P.rot[i] + P.spin[i] * h
                P.rot[i] = rot
                if camOk then
                    local c, sn = cos(rot), sin(rot)
                    ax, ay, az, hl = rx * c + ux * sn, ry * c + uy * sn, rz * c + uz * sn, s
                end
            elseif kind == K_RING then
                -- the shock ring: dust racing outward along the ground, a puff stretched sideways
                s = s0 + (s1 - s0) * (1 - (1 - t) * (1 - t))
                a = a * envelope(age, life, 0.04, 0.7)
                if camOk then ax, ay, az, hl = rx, ry, rz, s * 0.55 end
                hw = s
            elseif kind == K_SPARK then
                a = a * envelope(age, life, 0.02, 1)
                local sp = sqrt(vx * vx + vy * vy + vz * vz)
                -- kj_spark.png is a lens along u, so the axis is turned a quarter turn from the velocity on screen
                hw, hl = 1.0 + 9.0 * (1 - exp(-sp * 0.004)), s * 2
                ax, ay, az = ux, uy, uz
                if camOk and sp > 1e-3 then
                    local qx, qy, qz = fy * vz - fz * vy, fz * vx - fx * vz, fx * vy - fy * vx
                    local ql = sqrt(qx * qx + qy * qy + qz * qz)
                    if ql > sp * 0.05 then ax, ay, az = qx / ql, qy / ql, qz / ql end
                end
            else -- K_GLINT
                a = a * envelope(age, life, life * 0.25, 0.75)
                local rot = P.rot[i] + P.spin[i] * h
                P.rot[i] = rot
                if camOk then
                    local c, sn = cos(rot), sin(rot)
                    ax, ay, az, hl = rx * c + ux * sn, ry * c + uy * sn, rz * c + uz * sn, s
                end
            end
            local a8 = floor(a * 255 + 0.5)
            if a8 > 0 and s > 0 then
                if a8 > 255 then a8 = 255 end
                local b = P.bias[i]
                local c = (P.rgb[i] & 0xffffff00) | a8
                local mode = P.add[i] and "additive" or "alpha"
                if camOk then
                    pcall(sprite, P.tex[i], x - fx * b, y - fy * b, z - fz * b, hw or s, hl, ax, ay, az, c, mode)
                else
                    pcall(sprite, P.tex[i], x, y, z, hw or s, 0, 0, 0, 0, c, mode)
                end
            end
        end
    end
end

-- ---------------------------------------------------------------- effects
local function clodTex() return TEX.dirt[random(1, 4)] end
local function dustTex() return TEX.dust[random(1, 2)] end

-- A clod thrown from (x,y,z) around (dx,dy,dz).
local function throwClod(x, y, z, dx, dy, dz, spread, speed, m, size)
    local vx, vy, vz = cone(dx, dy, dz, spread)
    local sp = speed * rnd(0.55, 1.15)
    local rock = (m.sparks == 1) and random() < 0.55
    local tex = rock and TEX.chip or clodTex()
    local col = rock and varyColor(m.chip, 0.18) or varyColor(pick(m.clod), 0.12)
    local s = size * rnd(0.6, 1.25)
    spawn(K_CLOD, tex or clodTex(), false, x, y, z, vx * sp, vy * sp, vz * sp, s, s * 0.85, rnd(0.9, 1.7), rgba(col, 1), 0.98,
          0.25, CFG.gravity, rnd(0, 6.28), rnd(-9, 9), 0.42)
end

local function puff(x, y, z, vx, vy, vz, s0, s1, life, color, alpha)
    spawn(K_DUST, dustTex(), false, x, y, z, vx, vy, vz, s0, s1, life, rgba(color, 1), alpha, 1.8, -6, rnd(0, 6.28),
          rnd(-0.6, 0.6), 0)
end

local function glint(x, y, z, size, color)
    if TEX.glint then
        spawn(K_GLINT, TEX.glint, true, x, y, z, 0, 0, 0, size, size * 0.5, rnd(0.08, 0.16), rgba(color or 0xffe2b0, 1), 1, 0, 0,
              rnd(0, 6.28), rnd(-6, 6), 0)
    end
end

function M.sparks(x, y, z, dx, dy, dz, n, material)
    if not loadTextures() or not TEX.spark then return end
    M.install()
    n = scaled(n or 10)
    for _ = 1, n do
        local vx, vy, vz = cone(dx, dy, dz, 0.7)
        local sp = rnd(120, 340)
        local hot = random()
        local col = hot > 0.6 and 0xfff0c8 or (hot > 0.25 and 0xffc060 or 0xff8a30)
        spawn(K_SPARK, TEX.spark, true, x, y, z, vx * sp, vy * sp + 30, vz * sp, 0.55, 0.3, rnd(0.18, 0.5), rgba(col, 1), 1, 0.6,
              CFG.gravity * 0.8, 0, 0, 0.3)
    end
    glint(x, y, z, rnd(5, 8))
    if random() < 0.5 then glint(x + rnd(-1.5, 1.5), y + rnd(-1.5, 1.5), z + rnd(-1.5, 1.5), rnd(2.5, 4.5), 0xfff4d8) end
end

function M.settle(x, y, z, radius, material)
    if not loadTextures() then return end
    M.install()
    local m = mat(material)
    radius = clamp(tonumber(radius) or 10, 3, 60)
    -- low flat puffs spreading along the floor, long lived and thin
    for _ = 1, scaled(7) do
        local a = random() * 6.2831853
        local d = radius * rnd(0.1, 0.8)
        puff(x + cos(a) * d, y + rnd(-0.5, 3), z + sin(a) * d, cos(a) * rnd(4, 14), rnd(1, 5), sin(a) * rnd(4, 14),
             radius * rnd(0.35, 0.55), radius * rnd(0.9, 1.4), rnd(2.4, 4.2), m.dust, rnd(0.18, 0.3))
    end
    -- grains sifting down through it
    for _ = 1, scaled(10) do
        local a = random() * 6.2831853
        local d = radius * rnd(0, 0.9)
        spawn(K_GRAIN, TEX.chip or clodTex(), false, x + cos(a) * d, y + rnd(2, radius * 0.9), z + sin(a) * d, rnd(-3, 3),
              rnd(-4, 0), rnd(-3, 3), 0.28, 0.25, rnd(0.8, 1.8), rgba(varyColor(m.dust, 0.15), 1), 0.7, 1.2, 40, rnd(0, 6.28),
              rnd(-3, 3), 0, rnd(0, 0.5))
    end
end

function M.scoop(x, y, z, dx, dy, dz, material, power)
    if not loadTextures() then return end
    M.install()
    local m = mat(material)
    power = clamp(tonumber(power) or 1, 0.3, 2)
    local bx, by, bz = norm(dx, dy, dz)
    -- debris is thrown back out of the cut and up: against the blade's travel, lifted
    local ox, oy, oz = norm(-bx * 0.7, 0.75 + max(0, -by) * 0.2, -bz * 0.7)
    for _ = 1, scaled(9 * power) do
        throwClod(x, y, z, ox, oy, oz, 0.75, 120 * power, m, 1.3 + 0.7 * power)
    end
    -- a few that fly along the blade, past the cut
    for _ = 1, scaled(3 * power) do
        throwClod(x, y, z, bx, by + 0.4, bz, 0.5, 90 * power, m, 1.0)
    end
    puff(x, y + 1, z, ox * 12, oy * 14, oz * 12, 4 * power, 11 * power, rnd(0.9, 1.5), m.dust, 0.5)
    for _ = 1, scaled(3 * power) do
        local vx, vy, vz = cone(ox, oy, oz, 0.9)
        puff(x, y + 1, z, vx * 30, vy * 30, vz * 30, 2.5 * power, 8 * power, rnd(0.7, 1.4), m.dust, rnd(0.25, 0.4))
    end
    if m.sparks == 1 then
        M.sparks(x, y, z, ox, oy + 0.2, oz, 7 * power, material)
    end
    local r = 9 * power
    LATER[#LATER + 1] = { at = now() + 0.35, fn = function() M.settle(x, y, z, r, material) end }
end

function M.dig(id, x, y, z, dx, dy, dz, material, power)
    if id == nil then return end
    local s = STREAM[id]
    if not s then
        s = { acc = 0, accDust = 0, accSpark = 0 }
        STREAM[id] = s
    end
    s.x, s.y, s.z, s.dx, s.dy, s.dz = x, y, z, dx, dy, dz
    s.material, s.power, s.last = material, clamp(tonumber(power) or 1, 0.3, 2), now()
    M.install()
end

function M.digStop(id)
    local s = STREAM[id]
    if s then
        STREAM[id] = nil
        M.settle(s.x, s.y, s.z, 10 * s.power, s.material)
    end
end

local function streamTick(dt, t)
    for id, s in pairs(STREAM) do
        if t - s.last > CFG.streamTimeout then
            M.digStop(id)
        else
            local m = mat(s.material)
            local rate = CFG.streamRate * s.power
            local bx, by, bz = norm(s.dx, s.dy, s.dz)
            local ox, oy, oz = norm(-bx * 0.7, 0.7, -bz * 0.7)
            s.acc = s.acc + rate * dt
            while s.acc >= 1 do
                s.acc = s.acc - 1
                if random() < CFG.quality then
                    -- a start point spread back along the frame's travel hides the frame-sized clumps
                    local j = random() - 1
                    throwClod(s.x + j * bx * 3, s.y, s.z + j * bz * 3, ox, oy, oz, 0.6, rnd(60, 130) * s.power, m,
                              1.0 + 0.5 * s.power)
                end
            end
            s.accDust = s.accDust + rate * 0.35 * dt
            while s.accDust >= 1 do
                s.accDust = s.accDust - 1
                if random() < CFG.quality then
                    local vx, vy, vz = cone(ox, oy, oz, 0.8)
                    puff(s.x, s.y + 1, s.z, vx * 22, vy * 22, vz * 22, 2.5, 7.5 * s.power, rnd(0.8, 1.5), m.dust, rnd(0.25, 0.42))
                end
            end
            if m.sparks == 1 then
                s.accSpark = s.accSpark + rate * 0.25 * dt
                while s.accSpark >= 1 do
                    s.accSpark = s.accSpark - 1
                    M.sparks(s.x, s.y, s.z, ox, oy + 0.3, oz, 3, s.material)
                end
            end
        end
    end
    local i = 1
    while i <= #LATER do
        local q = LATER[i]
        if t >= q.at then
            table.remove(LATER, i)
            pcall(q.fn)
        else
            i = i + 1
        end
    end
    i = 1
    while i <= #RUN do
        local q = RUN[i]
        if t >= q.to then
            table.remove(RUN, i)
        else
            pcall(q.fn)
            i = i + 1
        end
    end
end

function M.headOff(x, y, z, dx, dz, opts)
    if not loadTextures() then return end
    M.install()
    opts = type(opts) == "table" and opts or {}
    local k = clamp(tonumber(opts.scale) or 1, 0.4, 2.5)
    local m = MAT.sand
    local fx, _, fz = norm(dx or 0, 0, dz or 0)
    -- 1. the shock ring: dust racing out along the ground from the body
    spawn(K_RING, dustTex(), false, x, y - 4, z, 0, 0, 0, 4 * k, 26 * k, 0.55, rgba(m.dust, 1), 0.55, 0, 0, 0, 0, 0)
    -- 2. a dust column up from the neck, with the sand fountain inside it
    for _ = 1, scaled(8 * k) do
        local vx, vy, vz = cone(0, 1, 0, 0.45)
        puff(x, y, z, vx * rnd(25, 60), vy * rnd(25, 60), vz * rnd(25, 60), 3 * k, rnd(9, 15) * k, rnd(1.0, 1.9), m.dust,
             rnd(0.4, 0.6))
    end
    for _ = 1, scaled(26 * k) do
        local vx, vy, vz = cone(fx * 0.5, 1, fz * 0.5, 0.5)
        local sp = rnd(70, 190) * k
        spawn(K_GRAIN, TEX.chip or clodTex(), false, x, y, z, vx * sp, vy * sp, vz * sp, rnd(0.35, 0.7), 0.3, rnd(0.8, 1.6),
              rgba(varyColor(m.clod[1], 0.15), 1), 0.95, 0.2, CFG.gravity, rnd(0, 6.28), rnd(-12, 12), 0.35)
    end
    -- 3. flung grit along the facing, so the cut has a direction
    for _ = 1, scaled(10 * k) do
        throwClod(x, y, z, fx, 0.5, fz, 0.5, rnd(90, 170), m, 1.1)
    end
    glint(x, y, z, 9 * k, 0xfff0d0)
    if opts.blood and TEX.mist then
        for _ = 1, scaled(7 * k) do
            local vx, vy, vz = cone(0, 1, 0, 0.6)
            local sp = rnd(30, 90)
            spawn(K_MIST, TEX.mist, false, x, y, z, vx * sp, vy * sp, vz * sp, 4 * k, rnd(11, 18) * k, rnd(0.7, 1.4),
                  rgba(0x6a0a10, 1), rnd(0.5, 0.8), 1.4, 120, rnd(0, 6.28), rnd(-1, 1), 0)
        end
        if TEX.gore then
            for _ = 1, scaled(8 * k) do
                local vx, vy, vz = cone(0, 1, 0, 0.6)
                local sp = rnd(70, 180)
                spawn(K_CLOD, TEX.gore, false, x, y, z, vx * sp, vy * sp, vz * sp, rnd(1.0, 2.1), 1.5, rnd(1.0, 1.8),
                      rgba(0x7c0f16, 1), 1, 0.1, CFG.gravity, rnd(0, 6.28), rnd(-10, 10), 0.3)
            end
        end
    end
    M.settle(x, y - 3, z, 16 * k, "sand")
    M.shake(3.2 * k, 0.45)
end

-- ---------------------------------------------------------------- camera shake
-- Decaying noise: a sum of incommensurate sines, so there is no visible repetition and no per-frame random jitter.
function M.shake(amount, seconds)
    amount = clamp(tonumber(amount) or 1, 0, 6)
    seconds = clamp(tonumber(seconds) or 0.4, 0.05, 3)
    local left = max(0, SHAKE.dur - SHAKE.t)
    local cur = SHAKE.amp * (left / SHAKE.dur) ^ 2
    if amount >= cur then
        SHAKE.amp, SHAKE.dur, SHAKE.t, SHAKE.seed = amount, seconds, 0, random() * 100
    else
        SHAKE.amp = cur + amount * 0.3
        SHAKE.dur, SHAKE.t = max(seconds, left), 0
    end
end

function M.shakeOffset()
    local t = now()
    if SHAKE.at == t then return SHAKE.ox, SHAKE.oy, SHAKE.oz end
    local dt = SHAKE.at < 0 and 0 or min(t - SHAKE.at, CFG.maxDt)
    SHAKE.at = t
    SHAKE.t = SHAKE.t + dt
    if SHAKE.t >= SHAKE.dur or SHAKE.amp <= 0 then
        SHAKE.amp, SHAKE.ox, SHAKE.oy, SHAKE.oz = 0, 0, 0, 0
        return 0, 0, 0
    end
    local u = 1 - SHAKE.t / SHAKE.dur
    local a = SHAKE.amp * u * u                                    -- quadratic decay: sharp hit, soft tail
    local s, w = SHAKE.seed, SHAKE.t
    SHAKE.ox = a * (sin(w * 41 + s) * 0.6 + sin(w * 67 + s * 2) * 0.4)
    SHAKE.oy = a * (sin(w * 53 + s * 3) * 0.6 + sin(w * 79 + s) * 0.4) * 0.8
    SHAKE.oz = a * (sin(w * 47 + s * 5) * 0.6 + sin(w * 71 + s * 4) * 0.4)
    return SHAKE.ox, SHAKE.oy, SHAKE.oz
end

local function addTo(v, ox, oy, oz, k)
    if type(v) ~= "table" then return end
    if v.x ~= nil then
        v.x, v.y, v.z = v.x + ox * k, v.y + oy * k, v.z + oz * k
    elseif v[1] ~= nil then
        v[1], v[2], v[3] = v[1] + ox * k, v[2] + oy * k, v[3] + oz * k
    end
end

function M.shakeCam(spec)
    if type(spec) ~= "table" then return spec end
    local ox, oy, oz = M.shakeOffset()
    if ox ~= 0 or oy ~= 0 or oz ~= 0 then
        addTo(spec.pos, ox, oy, oz, 1)
        addTo(spec.target, ox, oy, oz, 0.35)          -- the target moves less than the eye: a turn of the view, not a slide
    end
    return spec
end

-- ---------------------------------------------------------------- driver
local function onWorld()
    local t = now()
    local dt = lastClock and (t - lastClock) or 0
    lastClock = t
    if dt <= 0 then return end
    if dt > CFG.maxDt then dt = CFG.maxDt end
    rayUsed = 0
    if not loaded and not loadTextures() then return end
    readCamera()
    streamTick(dt, t)
    if N > 0 then step(dt) end
end

function M.install()
    if installed then return true end
    if not (wum and wum.draw and wum.draw.on and wum.draw.sprite) then return false end
    local ok = pcall(wum.draw.on, "worldLate", function()
        local good, err = pcall(onWorld)
        if not good and wum.log then pcall(wum.log, "spade_fx: " .. tostring(err)) end
    end)
    installed = ok
    return ok
end

function M.ready() return loaded end
function M.count() return N end

function M.clear()
    N = 0
    for k in pairs(STREAM) do STREAM[k] = nil end
    for i = #LATER, 1, -1 do LATER[i] = nil end
    for i = #RUN, 1, -1 do RUN[i] = nil end
    SHAKE.amp, SHAKE.ox, SHAKE.oy, SHAKE.oz = 0, 0, 0, 0
end

-- 0 turns the module off (no particles are born), 1 is full. The pool size follows it.
function M.setQuality(q)
    q = clamp(tonumber(q) or 1, 0, 1)
    CFG.quality = q
    CFG.maxParticles = floor(120 + 580 * q)
end

-- Every effect once, a little apart, for the Preview menu: a soil scoop, a stone dig with sparks, then the head-off.
function M.preview(x, y, z)
    M.install()
    local t = now()
    M.scoop(x, y, z, 1, -0.2, 0, "soil", 1)
    RUN[#RUN + 1] = { to = t + 3.2, fn = function()
        if now() > t + 1.0 then M.dig("preview", x + 14, y, z, 1, 0, 0, "stone", 1) end
    end }
    LATER[#LATER + 1] = { at = t + 3.4, fn = function() M.headOff(x + 28, y + 8, z, 1, 0, {}) end }
end

return M
