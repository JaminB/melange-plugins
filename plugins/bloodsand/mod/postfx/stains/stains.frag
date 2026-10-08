#version 120
// Blood decals rebuilt from the depth buffer, so they wrap the terrain: 32 slots, each a splat or a pool that lies on a
// surface of any orientation (floor, wall, overhang). A slot is two vec4s fed by Bloodsand's Lua:
//   dNa = (x, y, z, bound)       the decal's centre in world units and the radius of a sphere around everything it may
//                                draw; 0 means the slot is empty
//   p_count is one more than the highest slot in use; the slots above it are skipped without being looked at.
//   dNb = (nPack, flowPack, birth, tsPack)
//         nPack    = nu * 4096 + nv      the surface normal as two 12-bit angles (azimuth, polar)
//         flowPack = phi * 4096 + e      the direction the blood ran, an angle in the tangent frame, and how stretched
//                                        the splat is (0..4), both 12 bits
//         birth                          p_clock when the blood landed (the decal dries as p_clock moves on)
//         tsPack   = r * 16384 + (type * 16 + thick) * 256 + seed   radius in tenths, 1 splat or 2 pool, thickness 0..15
// All the integers are below 2^24 so they survive being floats.
//
// The tangent frame of a normal n is T = normalize(cross(ref, n)), B = cross(n, T), with ref = (0,1,0), or (1,0,0)
// when n is nearly vertical. On a wall B is the way up the wall. Bloodsand's Lua builds the same frame.
//
// Look: a decal is a bead of wet blood with a crisp (about one pixel) silhouette, a thin dark edge line, a rounded shoulder at
// the rim that tilts the normal outward and catches the light, a domed middle, and darker clots inside. The highlights are
// tight. Drying (matte dark brown, clotted rim) is unchanged.
//
// Structure: one cheap test per slot (a world-space bounding sphere) collects at most four candidates; the long
// shading runs once per candidate, in a loop of four. Sky, silhouettes and pixels with no candidate leave early.
//
// When more than four spheres hold a pixel, the four that hold it deepest (squared distance to the centre over the squared
// radius) are kept. That rank does not depend on the order of the slots and changes smoothly across the screen, so the one
// that is dropped is the one fading out at its own edge, not a whole decal cut off along some other sphere's circle. The four
// are then drawn in slot order, as they always were: the highest slot first, the lowest on top.
uniform sampler2D mg_scene;
uniform sampler2D mg_depth;
uniform mat4 mg_invProj;
uniform mat4 mg_view;
uniform vec2 mg_nearFar;
uniform vec4 p_d0a, p_d1a, p_d2a, p_d3a, p_d4a, p_d5a, p_d6a, p_d7a, p_d8a, p_d9a, p_d10a, p_d11a, p_d12a, p_d13a, p_d14a, p_d15a;
uniform vec4 p_d16a, p_d17a, p_d18a, p_d19a, p_d20a, p_d21a, p_d22a, p_d23a, p_d24a, p_d25a, p_d26a, p_d27a, p_d28a, p_d29a, p_d30a, p_d31a;
uniform vec4 p_d0b, p_d1b, p_d2b, p_d3b, p_d4b, p_d5b, p_d6b, p_d7b, p_d8b, p_d9b, p_d10b, p_d11b, p_d12b, p_d13b, p_d14b, p_d15b;
uniform vec4 p_d16b, p_d17b, p_d18b, p_d19b, p_d20b, p_d21b, p_d22b, p_d23b, p_d24b, p_d25b, p_d26b, p_d27b, p_d28b, p_d29b, p_d30b, p_d31b;
uniform vec3 p_blood;
uniform float p_strength;
uniform float p_clock;
uniform float p_count;
uniform float p_dryTime;
uniform float p_gloss;
varying vec2 mg_uv;

const float PI = 3.14159265;

float H21(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float VN(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(H21(i), H21(i + vec2(1.0, 0.0)), f.x), mix(H21(i + vec2(0.0, 1.0)), H21(i + vec2(1.0, 1.0)), f.x), f.y);
}

// Shades one decal over col. Pw is the pixel in world space, Pv in view space, nW the surface normal there (world), pxw
// the size of a pixel in world units.
void Decal(vec3 Pw, vec3 Pv, vec3 nW, float pxw, vec4 A, vec4 B, inout vec3 col) {
    float nu = floor(B.x / 4096.0);
    float nq = B.x - nu * 4096.0;
    float az = nu / 4095.0 * 2.0 * PI - PI;
    float el = nq / 4095.0 * PI;
    float se = sin(el);
    vec3 N = vec3(se * cos(az), cos(el), se * sin(az));

    float ng = smoothstep(0.35, 0.8, dot(nW, N));
    if (ng <= 0.0) return;

    float rq = floor(B.w / 16384.0);
    float rest = B.w - rq * 16384.0;
    float tt = floor(rest / 256.0);
    float seed = rest - tt * 256.0;
    float type = floor(tt / 16.0);
    float thick = (tt - type * 16.0) / 15.0;
    float R = max(rq * 0.1, 0.1);
    float isPool = step(1.5, type);

    // Distance off the decal's plane, tolerant enough to follow a curved surface.
    vec3 d = Pw - A.xyz;
    float h = dot(d, N);
    float dist = length(d - N * h);
    float tolH = 1.5 + 0.2 * R + 0.2 * dist;
    float hg = 1.0 - smoothstep(0.6 * tolH, tolH, abs(h));
    if (hg <= 0.0) return;

    vec3 ref = abs(N.y) > 0.9 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0);
    vec3 T = normalize(cross(ref, N));
    vec3 Bt = cross(N, T);
    float u = dot(d, T);
    float v = dot(d, Bt);

    float fp = floor(B.y / 4096.0);
    float eq = B.y - fp * 4096.0;
    float phi = fp / 4095.0 * 2.0 * PI;
    float E = eq / 4095.0 * 4.0;
    float cp = cos(phi);
    float sp = sin(phi);
    float a = u * cp + v * sp;       // along the flow, the tail is at +a
    float c = -u * sp + v * cp;      // across it
    float age = max(p_clock - B.z, 0.0);

    // ---- shape ----
    float La = R * (1.0 + E);
    float s = a / La;
    float taper = 1.0 - 0.55 * smoothstep(-0.25, 1.0, s) * min(E, 1.0) * (1.0 - isPool);
    float ang = atan(c, a + 1e-4);
    vec3 ph = vec3(H21(vec2(seed, 1.7)), H21(vec2(seed, 5.3)), H21(vec2(seed, 9.1))) * 2.0 * PI;
    float dryEarly = clamp(age / max(p_dryTime, 1.0), 0.0, 1.0);
    // A splat has a gentle wobble, plus thin spikes (a crown) when it came down steeply, which dry to blunter ones. A pool has
    // a rounder, lumpier edge made of low-frequency ripples. Only the one that applies is evaluated.
    float edge;
    if (isPool > 0.5) {
        edge = 1.0 + 0.16 * sin(ang * 2.0 + ph.x) + 0.1 * sin(ang * 3.0 + ph.y) + 0.07 * sin(ang * 5.0 + ph.z)
             + 0.2 * (VN(vec2(u, v) * (2.2 / R) + seed) - 0.5);
    } else {
        float sk = 0.5 + 0.5 * sin(ang * 11.0 + ph.y * 3.0);
        float sk2 = sk * sk;
        float sk4 = sk2 * sk2;
        float spikes = sk4 * sk4 * sk2 * (0.55 + 0.45 * sin(ang * 4.0 + ph.z));
        edge = 1.0 + 0.09 * sin(ang * 3.0 + ph.x) + 0.06 * sin(ang * 5.0 + ph.y) + 0.04 * sin(ang * 7.0 + ph.z)
             + spikes * 0.26 * (1.0 - 0.7 * min(E, 1.0)) * (1.0 - 0.4 * dryEarly) / (1.0 + 0.12 * R);
    }
    float r = sqrt(s * s + (c * c) / (R * R * taper * taper)) / max(edge, 0.2);
    // The silhouette is crisp, wet or dry: about a pixel of antialiasing and no falloff.
    float aa = clamp(0.8 * pxw / max(R, 0.5), 0.003, 0.35);
    float body = 1.0 - smoothstep(1.0 - aa, 1.0 + aa * 0.5, r);

    // The tail of a long streak breaks into beads.
    float tailAmt = smoothstep(0.35, 1.0, s) * clamp(E - 0.6, 0.0, 1.0) * (1.0 - isPool);
    if (tailAmt > 0.0) body *= mix(1.0, smoothstep(0.4, 0.46, VN(vec2(s * 5.0 + seed, c * 2.5 / R))), tailAmt);

    // A drop of blood stands on the ground: it is thin right at the edge, climbs over a rounded shoulder (the meniscus, a
    // few pixels wide) to a thick plateau that domes up toward the middle. rimU is 0 at the edge and 1 from the inner side
    // of the shoulder on.
    float rimW = max(clamp(0.3 / R + 0.03, 0.03, 0.35), 4.0 * aa);
    float rimU = clamp((1.0 - r) / rimW, 0.0, 1.0);
    float shoulder = 1.0 - (1.0 - rimU) * (1.0 - rimU);
    float tk = 0.4 + 0.6 * thick;
    float th = tk * mix(0.3, 1.0, shoulder) * (0.62 + 0.38 * (1.0 - r * r)) * (1.0 - 0.45 * smoothstep(0.0, 1.0, s) * min(E, 1.0));
    th = max(th, 0.0);
    float cov = body;

    // Satellite droplets thrown past the edge; more of them the rounder and steeper the impact.
    // (Not on a speck under two units: its satellites are a pixel or two.)
    float sat = 0.0;
    float isSat = 0.0;
    vec2 satD = vec2(0.0);
    if (isPool < 0.5 && R >= 2.0) {
        vec2 sq = vec2(a / (1.0 + E * 0.6), c) / max(R * 0.32, 0.35);
        vec2 id = floor(sq);
        vec2 f = fract(sq);
        vec3 hs = vec3(H21(id + seed * 1.31), H21(id * 1.37 + seed + 17.0), H21(id * 2.11 + seed + 41.0));
        float dens = 0.5 * smoothstep(0.92, 1.05, r) * (1.0 - smoothstep(1.05, 1.42, r));
        if (hs.x < dens) {
            float sz = (0.12 + 0.2 * hs.z) * (1.0 - 0.45 * smoothstep(1.0, 1.4, r));
            satD = (f - (0.28 + 0.44 * hs.yz)) / max(sz, 1e-3);
            sat = 1.0 - smoothstep(sz * 0.8, sz, length(f - (0.28 + 0.44 * hs.yz)));
        }
    }
    if (sat > cov) {
        cov = sat;
        th = 0.65;
        isSat = 1.0;
    }

    float dripSide = 0.0;
    float isDrip = 0.0;
    // Runs down a wall: up to three drips that lengthen as the blood ages, each ending in a bead.
    float wall = (1.0 - smoothstep(0.5, 0.78, N.y)) * smoothstep(-0.35, -0.05, N.y) * (1.0 - isPool);
    if (wall > 0.0 && R >= 1.2) {
        float grow = 1.0 - exp(-age * 0.1);
        float dn = -v;
        float dripCov = 0.0;
        float side = 0.0;
        // The blot's lowest point (the support of its ellipse straight down) in its own u, v.
        float rootV = sqrt(La * La * sp * sp + R * R * cp * cp);
        float rootU = -(La * La - R * R) * sp * cp / max(rootV, 1e-3);
        for (int k = 0; k < 3; k++) {
            float fk = float(k);
            float hx = H21(vec2(seed + fk * 7.7, 3.3));
            float hy = H21(vec2(seed * 0.7 + fk * 3.1, 9.1));
            float hz = H21(vec2(fk + seed * 1.9, 5.5));
            // They hang from the lowest part of the blot: the root is inside the body near its lowest point, so what
            // shows is the part below its edge.
            float ox = rootU * 0.7 + (hx - 0.5) * R * 0.6;
            float d0 = rootV * (0.55 + 0.25 * hy);
            float len = R * (0.8 + 2.0 * hz) * grow + rootV * 0.3;
            float w = R * (0.07 + 0.07 * hy);
            float sway = sin(dn / R * 3.0 + fk * 2.0) * 0.06 * R;
            float ax = abs(u - ox - sway);
            float along = dn - d0;
            float tube = (1.0 - smoothstep(w * 0.8, w, ax)) * step(0.0, along) * (1.0 - smoothstep(len - w * 1.5, len, along));
            float bulb = (1.0 - smoothstep(w, w * 1.25, length(vec2(ax, along - len + w * 1.2)))) * step(w * 3.0, len);
            float dc = max(tube, bulb) * wall;
            if (dc > dripCov) {
                dripCov = dc;
                side = clamp((u - ox - sway) / w, -1.0, 1.0);
            }
        }
        if (dripCov > cov) {
            cov = dripCov;
            th = 0.8;
            dripSide = side;
            isDrip = 1.0;
        }
    }
    if (cov <= 0.0) return;

    // ---- drying: thin blood dries first, a rim of clot forms ----
    float dryT = clamp(age / max(p_dryTime, 1.0), 0.0, 1.0);
    dryT = dryT * dryT * (3.0 - 2.0 * dryT);
    float dry = clamp(dryT * 1.35 - th * 0.35, 0.0, 1.0);
    float rim = smoothstep(0.74, 0.95, r) * (1.0 - smoothstep(0.97, 1.06, r)) * body;
    th = min(th + rim * 0.5 * dryT, 1.2);
    float clot = 0.0;
    float crack = 0.0;
    if (isPool > 0.5 && dryT > 0.35) {
        float n1 = VN(vec2(u, v) * (4.0 / R) + seed * 3.0);
        clot = smoothstep(0.66, 0.8, n1) * dryT;
        crack = (1.0 - smoothstep(0.0, 0.03, abs(VN(vec2(u, v) * (5.5 / R) + seed) - 0.5))) * smoothstep(0.5, 0.9, dryT) * smoothstep(0.1, 0.5, th);
    }
    th = min(th + clot * 0.4, 1.2);

    // Slight undulation of a wet surface, so a highlight is not a perfect mirror; the broader second one also picks out
    // the places where the blood has begun to clot (only on a decal big enough to show them).
    float bump = 0.0;
    float bump2 = 0.0;
    float coag = 0.0;
    if (dry < 0.98) {
        bump = VN(vec2(u, v) * (7.0 / R) + seed * 1.7) - 0.5;
        if (R >= 2.0) {
            bump2 = VN(vec2(v, u) * (3.2 / R) + seed * 2.9 + 11.0) - 0.5;
            coag = smoothstep(0.02, 0.36, bump2 + 0.35 * bump) * 0.8;
        }
    }

    // ---- colour ----
    vec3 tint = p_blood / max(max(p_blood.r, p_blood.g), max(p_blood.b, 1e-3));
    float lum = 0.4 + 0.2 * H21(vec2(seed, 31.7));
    vec3 thin = col * tint * 0.5 + p_blood * (0.3 + 0.12 * lum);
    vec3 deep = p_blood * (0.26 + 0.07 * lum) + col * tint * 0.04;
    vec3 wetCol = mix(thin, deep, smoothstep(0.1, 0.95, th * 0.72));
    vec3 dryBase = p_blood * 0.5 + vec3(0.04, 0.025, 0.016);
    vec3 dryCol = mix(dryBase * 0.85 + col * tint * 0.2, dryBase * (0.9 + 0.3 * lum) + col * 0.03, smoothstep(0.1, 0.8, th));
    vec3 base = mix(wetCol, dryCol, dry);
    // Wet blood is a little darker where it has begun to clot, and darkest in a thin line where the film ends.
    base *= 1.0 - 0.28 * coag * (1.0 - dry);
    float lw = max(2.5 * aa, 0.01);
    base *= 1.0 - 0.3 * smoothstep(1.0 - 2.0 * lw, 1.0 - 0.5 * lw, r) * (1.0 - isDrip) * (1.0 - isSat);
    base *= 1.0 - 0.45 * crack;
    base *= 1.0 - 0.25 * rim * dryT;

    // ---- gloss: wet blood is a glossy bead with a thick, domed middle and a steep rounded rim; it dulls as it dries ----
    // The way the surface tilts: outward at the edge of the blot (the gradient of r), and across a drip or a droplet.
    vec2 g = vec2(s / La, c / (R * R * taper * taper));
    g /= max(length(g), 1e-5);
    vec3 outw = T * (g.x * cp - g.y * sp) + Bt * (g.x * sp + g.y * cp);
    float domeR = min(r, 1.0);
    float tiltK = 0.42;
    float rimT = rimU;
    if (isSat > 0.5) {
        outw = T * (satD.x * cp - satD.y * sp) + Bt * (satD.x * sp + satD.y * cp);
        domeR = min(length(satD), 1.0);
        tiltK = 0.9;
        rimT = 1.0;
    }
    if (isDrip > 0.5) {
        outw = T * sign(dripSide);
        domeR = abs(dripSide);
        tiltK = 0.9;
        rimT = 1.0;
    }
    float wet = (1.0 - dry) * p_gloss;
    float tilt = (0.9 * (1.0 - rimT) * (1.0 - rimT) + tiltK * th * domeR) * (1.0 - 0.6 * dry);
    vec3 Nb = normalize(N + outw * tilt + (T * bump * 0.06 + Bt * bump2 * (0.12 + 0.04 * isPool)) * (1.0 - dry));
    mat3 Rv = mat3(mg_view);
    vec3 Nv = Rv * Nb;
    vec3 V = normalize(-Pv);
    // Two lights fixed in view space: one overhead, which a flat floor seen from the usual camera angles mirrors, and
    // one up and to the left of the camera, which catches walls. The highlights are tight: the middle of the blot is
    // nearly flat, so they sit on the dome and the shoulder.
    vec3 H = normalize(normalize(vec3(-0.2, 0.97, -0.1)) + V);
    vec3 H2 = normalize(normalize(vec3(-0.3, 0.45, 0.85)) + V);
    float nh = max(dot(Nv, H), 0.0);
    float nh2 = max(dot(Nv, H2), 0.0);
    float specAmt = 0.0;
    if (wet > 0.0) {
        specAmt = (pow(nh, 400.0) * 1.3 + pow(nh2, 300.0) * 1.6) * wet;
        // The shoulder catches the light on a wider lobe than the dome does, and only there, so it reads as a bright rim.
        float rimA = (1.0 - rimT) * (1.0 - rimT);
        if (rimA > 0.0) specAmt += (pow(nh, 60.0) * 0.5 + pow(nh2, 40.0) * 0.5) * rimA * wet;
        float fv = 1.0 - max(dot(Nv, V), 0.0);
        fv *= fv;
        specAmt += fv * fv * 0.3 * wet * (0.35 + 0.65 * (1.0 - rimT));
    }
    if (dry > 0.0) specAmt += pow(nh, 30.0) * 0.05 * dry * (1.0 - clot);
    specAmt = min(specAmt, 1.0);
    specAmt *= smoothstep(0.1, 0.4, th) * (1.0 - 0.7 * crack) * (1.0 - 0.5 * coag) * mix(1.0, 0.75, isPool);

    float alpha = cov * ng * hg * p_strength * clamp(0.6 + 0.8 * th + 0.6 * dry, 0.0, 1.0);
    col = mix(col, base, alpha) + vec3(1.0, 0.8, 0.78) * specAmt * alpha;
}

// A slot whose sphere holds the pixel offers itself (A, B, its number I) to the four places; the one with the highest rank
// (the shallowest hold) gives up its place if the offer is deeper. An empty place has rank 2.
#define SLOT(A, B, I) if (A.w > 0.0) { vec3 q_ = Pw - A.xyz; float k_ = dot(q_, q_) / (A.w * A.w); if (k_ < 1.0) { cnt += 1.0; if (k0 >= k1 && k0 >= k2 && k0 >= k3) { if (k_ < k0) { k0 = k_; cA0 = A; cB0 = B; cI0 = I; } } else if (k1 >= k2 && k1 >= k3) { if (k_ < k1) { k1 = k_; cA1 = A; cB1 = B; cI1 = I; } } else if (k2 >= k3) { if (k_ < k2) { k2 = k_; cA2 = A; cB2 = B; cI2 = I; } } else { if (k_ < k3) { k3 = k_; cA3 = A; cB3 = B; cI3 = I; } } } }

// Puts the higher slot number first.
#define CAS(IA, AA, BA, IB, AB, BB) if (IA < IB) { float ti_ = IA; IA = IB; IB = ti_; vec4 ta_ = AA; AA = AB; AB = ta_; vec4 tb_ = BA; BA = BB; BB = tb_; }

void main() {
    vec4 scene = texture2D(mg_scene, mg_uv);
    float depth = texture2D(mg_depth, mg_uv).r;
    vec4 vp = mg_invProj * vec4(vec3(mg_uv, depth) * 2.0 - 1.0, 1.0);
    vec3 P = vp.xyz / vp.w;
    // Derivatives are taken before any early return so that every pixel of a block takes part in them.
    vec3 dPx = dFdx(P);
    vec3 dPy = dFdy(P);
    if (p_strength <= 0.0 || depth >= 1.0 || length(P) > 0.5 * mg_nearFar.y) {
        gl_FragColor = scene;
        return;
    }

    // The surface normal from the depth: a pixel across a silhouette or a depth jump is left alone.
    if (length(dPx) + length(dPy) > 0.06 * length(P) + 0.5) {
        gl_FragColor = scene;
        return;
    }
    vec3 n = cross(dPx, dPy);
    float nl = length(n);
    if (nl < 1e-9) {
        gl_FragColor = scene;
        return;
    }
    n /= nl;
    // Face the camera, which sits at the view-space origin.
    if (dot(n, P) > 0.0) n = -n;

    // The pixel in world space. mg_view is the world-to-view matrix in column-major layout with translation, so
    // its upper 3x3 is the world-to-view rotation and v * mat3(mg_view), which is transpose(R) * v, turns a view-space
    // vector back to world axes.
    vec3 Pw = (P - mg_view[3].xyz) * mat3(mg_view);
    vec3 nW = n * mat3(mg_view);

    vec4 cA0 = vec4(0.0), cA1 = vec4(0.0), cA2 = vec4(0.0), cA3 = vec4(0.0);
    vec4 cB0 = vec4(0.0), cB1 = vec4(0.0), cB2 = vec4(0.0), cB3 = vec4(0.0);
    float k0 = 2.0, k1 = 2.0, k2 = 2.0, k3 = 2.0;
    float cI0 = -1.0, cI1 = -1.0, cI2 = -1.0, cI3 = -1.0;
    float cnt = 0.0;
    if (p_count > 0.5) {
        SLOT(p_d0a, p_d0b, 0.0) SLOT(p_d1a, p_d1b, 1.0) SLOT(p_d2a, p_d2b, 2.0) SLOT(p_d3a, p_d3b, 3.0)
        SLOT(p_d4a, p_d4b, 4.0) SLOT(p_d5a, p_d5b, 5.0) SLOT(p_d6a, p_d6b, 6.0) SLOT(p_d7a, p_d7b, 7.0)
    }
    if (p_count > 8.5) {
        SLOT(p_d8a, p_d8b, 8.0) SLOT(p_d9a, p_d9b, 9.0) SLOT(p_d10a, p_d10b, 10.0) SLOT(p_d11a, p_d11b, 11.0)
        SLOT(p_d12a, p_d12b, 12.0) SLOT(p_d13a, p_d13b, 13.0) SLOT(p_d14a, p_d14b, 14.0) SLOT(p_d15a, p_d15b, 15.0)
    }
    if (p_count > 16.5) {
        SLOT(p_d16a, p_d16b, 16.0) SLOT(p_d17a, p_d17b, 17.0) SLOT(p_d18a, p_d18b, 18.0) SLOT(p_d19a, p_d19b, 19.0)
        SLOT(p_d20a, p_d20b, 20.0) SLOT(p_d21a, p_d21b, 21.0) SLOT(p_d22a, p_d22b, 22.0) SLOT(p_d23a, p_d23b, 23.0)
    }
    if (p_count > 24.5) {
        SLOT(p_d24a, p_d24b, 24.0) SLOT(p_d25a, p_d25b, 25.0) SLOT(p_d26a, p_d26b, 26.0) SLOT(p_d27a, p_d27b, 27.0)
        SLOT(p_d28a, p_d28b, 28.0) SLOT(p_d29a, p_d29b, 29.0) SLOT(p_d30a, p_d30b, 30.0) SLOT(p_d31a, p_d31b, 31.0)
    }
    if (cnt < 0.5) {
        gl_FragColor = scene;
        return;
    }

    // The kept ones in slot order: a sorting network, the highest slot first.
    if (cnt > 1.5) {
        CAS(cI0, cA0, cB0, cI1, cA1, cB1)
        CAS(cI2, cA2, cB2, cI3, cA3, cB3)
        CAS(cI0, cA0, cB0, cI2, cA2, cB2)
        CAS(cI1, cA1, cB1, cI3, cA3, cB3)
        CAS(cI1, cA1, cB1, cI2, cA2, cB2)
    }
    cnt = min(cnt, 4.0);
    float pxw = length(dPx);
    vec3 col = scene.rgb;
    for (int k = 0; k < 4; k++) {
        if (float(k) >= cnt) break;
        vec4 A = k == 0 ? cA0 : (k == 1 ? cA1 : (k == 2 ? cA2 : cA3));
        vec4 B = k == 0 ? cB0 : (k == 1 ? cB1 : (k == 2 ? cB2 : cB3));
        Decal(Pw, P, nW, pxw, A, B, col);
    }
    gl_FragColor = vec4(col, scene.a);
}
