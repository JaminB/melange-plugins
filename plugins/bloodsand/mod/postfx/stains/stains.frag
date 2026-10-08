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
// All the integers are below 2^24 so they survive being floats. The seed (0..255) also picks the outline of the blot: how
// many lobes it has, how lumpy and how long it is, how many satellite drops and specks it throws and how thickly.
//   wN = (x, y, z, 1)            the middle of the body of worm N (slot N), 0 in w when there is no such worm;
//                                p_wn is one more than the highest worm in use. Blood does not land on a worm.
//
// The tangent frame of a normal n is T = normalize(cross(ref, n)), B = cross(n, T), with ref = (0,1,0), or (1,0,0)
// when n is nearly vertical. On a wall B is the way up the wall. Bloodsand's Lua builds the same frame.
//
// Look: blood is a bead of wet liquid with a crisp (about one pixel) silhouette, a thin dark edge line, a rounded shoulder at
// the rim that tilts the normal outward and catches the light, a domed middle, and darker clots inside. The highlights are
// tight. Drying (matte dark brown, clotted rim) is unchanged.
//
// One fluid: the decals that hold a pixel do not draw one over another. Each gives a distance to its own edge (in world
// units, positive inside) and the distances are combined with a smooth maximum, so the blood of two overlapping decals is
// one body of liquid with one outline and the rim, the edge line and the shoulder are those of the union: there are no
// borders inside it. The surface properties (thickness, how dry it is, the tilt of the surface) are mixed in the same
// proportion. Satellite drops, specks and the drips running down a wall take part in the same union, so a speck close to
// a blot runs into it with a small fillet. The shading runs once per pixel, on the combined values.
//
// Structure: one cheap test per slot (a world-space bounding sphere) collects at most three candidates, those that hold the
// pixel deepest (the squared distance to the centre over the squared radius), which does not depend on the order of the
// slots and changes smoothly across the screen, so the one that is dropped is the one fading out at its own edge. Sky,
// pixels with no candidate and pixels too close to the camera leave early. Only then is the surface normal worked out, for
// each pixel from its own four neighbours (the side with the smaller depth step in each direction), not from dFdx and dFdy,
// which a GPU takes over blocks of 2 by 2 pixels: a block normal cut every facet edge and silhouette into steps.
//
// Where it must not draw: blood lands on the surface the decal lies in, so a pixel is dropped when it is off the decal's
// plane by more than a tolerance that grows with the distance from the middle (so a splat wraps round a pillar or a
// curved rock, facet by facet, and its own outline is what ends it), when its normal turns more than about 60 degrees from
// the decal's (about 50 for a pool, which lies on ground, and not on a camera-facing puff of smoke), when a neighbour lies well behind its tangent plane (the
// edge of a silhouette, smoke or anything else thin that writes depth; a convex crease between two facets is far less than
// that), when it is a grey that floats over the plane (smoke that hangs low and flat enough to pass the tests above), and
// when it is inside a worm's volume (a worm standing or lying in a pool, hats, arms) and either faces another way than the
// decal or stands high above its plane: the curved ground a worm lies on still takes blood, and what is not ground does not,
// even where it crosses the decal's plane (a worm on a slope is cut through by the plane of a pool). A decal fades out as the
// camera comes within a few tens of units.
uniform sampler2D mg_scene;
uniform sampler2D mg_depth;
uniform mat4 mg_invProj;
uniform mat4 mg_view;
uniform vec2 mg_nearFar;
uniform vec4 mg_resolution;
uniform vec4 p_d0a, p_d1a, p_d2a, p_d3a, p_d4a, p_d5a, p_d6a, p_d7a, p_d8a, p_d9a, p_d10a, p_d11a, p_d12a, p_d13a, p_d14a, p_d15a;
uniform vec4 p_d16a, p_d17a, p_d18a, p_d19a, p_d20a, p_d21a, p_d22a, p_d23a, p_d24a, p_d25a, p_d26a, p_d27a, p_d28a, p_d29a, p_d30a, p_d31a;
uniform vec4 p_d0b, p_d1b, p_d2b, p_d3b, p_d4b, p_d5b, p_d6b, p_d7b, p_d8b, p_d9b, p_d10b, p_d11b, p_d12b, p_d13b, p_d14b, p_d15b;
uniform vec4 p_d16b, p_d17b, p_d18b, p_d19b, p_d20b, p_d21b, p_d22b, p_d23b, p_d24b, p_d25b, p_d26b, p_d27b, p_d28b, p_d29b, p_d30b, p_d31b;
uniform vec4 p_w0, p_w1, p_w2, p_w3, p_w4, p_w5, p_w6, p_w7, p_w8, p_w9, p_w10, p_w11, p_w12, p_w13, p_w14, p_w15;
uniform vec3 p_blood;
uniform float p_strength;
uniform float p_clock;
uniform float p_count;
uniform float p_wn;
uniform float p_dryTime;
uniform float p_gloss;
varying vec2 mg_uv;

const float PI = 3.14159265;
// A worm is kept clear of blood inside an ellipsoid about its middle raised by WORM_UP: this wide (it covers a worm lying
// down as well as one standing, with its tail, which is at the far end of the longest reach) and this high (a hat, a helmet
// or ears stand well above the head), and its pixels fade out between WORM_E0 and 1 (a tail that was only half kept clear
// at the edge of a wider fade showed as a pale smear on the worm).
const float WORM_RH2 = 21.0 * 21.0;
const float WORM_RV2 = 28.0 * 28.0;
const float WORM_UP = 5.0;
const float WORM_E0 = 0.9;
// The camera fades the blood out nearer than NEAR_FULL world units, entirely at NEAR_NONE (the aim camera sits about 20
// units from a rock in front of the worm; a close-up of a worm is 70 or more).
const float NEAR_NONE = 18.0;
const float NEAR_FULL = 48.0;

float H21(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

// Three hashes in one.
vec3 H23(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yxz + 33.33);
    return fract((p3.xxy + p3.yzz) * p3.zyx);
}

float VN(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(H21(i), H21(i + vec2(1.0, 0.0)), f.x), mix(H21(i + vec2(0.0, 1.0)), H21(i + vec2(1.0, 1.0)), f.x), f.y);
}

// What one blot (or the union of several) is at a pixel. F is the distance in world units from the pixel to the edge of
// the blood, positive inside it, and R the size of the blot around there; the rest are the properties of its surface.
struct Fl {
    float F;
    float R;
    float S;        // the nominal radius of the decal the blood came from (the scale of its grain)
    float dm;       // how far out from the middle on the smooth part of the outline (the dome of the blood follows this)
    float bf;       // 1, less where two decals meet and their grain does not match
    vec2 uv;        // where the pixel is in that decal's own frame (the place of its grain); not mixed, the nearer decal's is taken
    float kth;      // thickness of the blood before the shoulder and the dome are applied
    float fr;       // 1 for a satellite drop, a speck or a drip (no shoulder, a round bead), 0 for the body of a blot
    float dryT;     // how dry, 0..1 (smoothed)
    float lum;
    float pool;
    float gate;     // 1 where blood may land, 0 where it may not (off the surface, a worm)
    vec3 outw;      // the way the surface tilts, in the world, pointing outward from the edge
    vec3 nrm;       // the decal's surface normal
};

Fl FlNone() {
    Fl o;
    o.F = -1.0e4;
    o.R = 1.0;
    o.S = 1.0;
    o.uv = vec2(0.0);
    o.bf = 1.0;
    o.dm = 0.0;
    o.kth = 0.0;
    o.fr = 0.0;
    o.dryT = 0.0;
    o.lum = 0.5;
    o.pool = 0.0;
    o.gate = 0.0;
    o.outw = vec3(0.0);
    o.nrm = vec3(0.0, 1.0, 0.0);
    return o;
}

Fl FlMix(Fl a, Fl b, float t) {
    Fl o;
    o.F = a.F;
    o.R = mix(a.R, b.R, t);
    o.S = t > 0.5 ? b.S : a.S;
    o.uv = t > 0.5 ? b.uv : a.uv;
    o.bf = mix(a.bf, b.bf, t);
    o.dm = mix(a.dm, b.dm, t);
    o.kth = mix(a.kth, b.kth, t);
    o.fr = mix(a.fr, b.fr, t);
    o.dryT = mix(a.dryT, b.dryT, t);
    o.lum = mix(a.lum, b.lum, t);
    o.pool = mix(a.pool, b.pool, t);
    o.gate = mix(a.gate, b.gate, t);
    o.outw = mix(a.outw, b.outw, t);
    o.nrm = mix(a.nrm, b.nrm, t);
    return o;
}

// Unions n into acc. The distance is a smooth maximum (a polynomial one: the fillet between two edges is at most a quarter
// of k deep), and the properties are mixed by how much each blot holds the pixel, over a wider range than the fillet so
// that a difference in how dry two of them are does not show as a line.
void Merge(inout Fl acc, Fl n) {
    if (acc.F < -500.0) {
        acc = n;
        return;
    }
    float rs = min(min(acc.R, n.R), 3.0);
    float k = 0.15 + 0.5 * rs;
    float d = n.F - acc.F;
    float h = max(k - abs(d), 0.0) / k;
    float F = max(acc.F, n.F) + h * h * k * 0.25;
    float kA = 0.15 + 0.5 * min(min(acc.R, n.R), 30.0);
    // Far behind the blood already there, or far in front of it, nothing is mixed.
    if (d < -kA) return;
    if (d > kA) {
        acc = n;
        return;
    }
    float wn = smoothstep(-kA, kA, d);
    acc = FlMix(acc, n, wn);
    acc.F = F;
    acc.bf *= 1.0 - 4.0 * wn * (1.0 - wn);
}

// The smallest value of the equation of a worm's ellipsoid at Pw: under 1 is inside, and 9 when there is no worm.
#define WM(W) if (W.w > 0.0) { vec3 q_ = Pw - W.xyz; q_.y -= WORM_UP; e = min(e, dot(q_.xz, q_.xz) * (1.0 / WORM_RH2) + q_.y * q_.y * (1.0 / WORM_RV2)); }
float WormE(vec3 Pw) {
    float e = 9.0;
    if (p_wn > 0.5) {
        WM(p_w0) WM(p_w1) WM(p_w2) WM(p_w3)
    }
    if (p_wn > 4.5) {
        WM(p_w4) WM(p_w5) WM(p_w6) WM(p_w7)
    }
    if (p_wn > 8.5) {
        WM(p_w8) WM(p_w9) WM(p_w10) WM(p_w11)
    }
    if (p_wn > 12.5) {
        WM(p_w12) WM(p_w13) WM(p_w14) WM(p_w15)
    }
    return e;
}

// One decal at the pixel: Pw is the pixel in world space, nW the surface normal there (world), pxw the size of a pixel in
// world units. Adds what the decal contributes (its body, and the satellite, speck or drip nearest the pixel) to acc.
// wE is the worm test (WormE) at the pixel.
void Shape(vec3 Pw, vec3 nW, float pxw, float grey, vec4 A, vec4 B, float wE, inout Fl acc) {
    float nu = floor(B.x / 4096.0);
    float nq = B.x - nu * 4096.0;
    float az = nu / 4095.0 * 2.0 * PI - PI;
    float el = nq / 4095.0 * PI;
    float se = sin(el);
    vec3 N = vec3(se * cos(az), cos(el), se * sin(az));

    float rq = floor(B.w / 16384.0);
    float rest = B.w - rq * 16384.0;
    float tt = floor(rest / 256.0);
    float seed = rest - tt * 256.0;
    float type = floor(tt / 16.0);
    float thick = (tt - type * 16.0) / 15.0;
    float R = max(rq * 0.1, 0.1);
    float isPool = step(1.5, type);

    // The surface must be the decal's: its normal must not turn more than about 60 degrees from it (a facet of a pillar or a
    // rock next to the one the blood hit takes it too; a wall standing on the floor does not; a pool lies on ground, which
    // is not as steep as a pillar, so it takes about 50)...
    float nd = dot(nW, N);
    float ng = mix(smoothstep(0.2, 0.45, nd), smoothstep(0.6, 0.85, nd), isPool);
    if (ng <= 0.0) return;

    // ...and it must be on the decal's plane, within a tolerance that grows with the distance from the middle, as far as a
    // pillar or a rock curves away from it under a splat (a surface of radius 25 is 2 units off at 10 from the middle).
    vec3 d = Pw - A.xyz;
    float h = dot(d, N);
    float dist = length(d - N * h);
    float tolH = 1.2 + 0.2 * dist + 0.02 * R;
    float hg = 1.0 - smoothstep(0.5 * tolH, tolH, abs(h));
    // Smoke is grey, and hangs a few units over the plane, which that tolerance lets through (a wide pool on a dune needs it,
    // and a tighter one cut the pool short): a grey pixel that is off the plane at all is not ground. (Pixels on the plane
    // keep whatever their colour: the ground of a grey level is on it.)
    hg *= 1.0 - 0.9 * grey * smoothstep(0.7, 1.6, abs(h));
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
    // A pixel far outside the decal's body is dropped before the outline is worked out: the outline reaches at most 1.75 of
    // the radius, a satellite drop 2.9 (only on a splat of two units and more), and the drips of a wall decal are not
    // looked for here. (qlow is the least the across-radius can be, taking the widest the seed can make the blot.)
    float taper = 1.0 - 0.55 * smoothstep(-0.25, 1.0, s) * min(E, 1.0) * (1.0 - isPool);
    float wall = (1.0 - smoothstep(0.5, 0.78, N.y)) * smoothstep(-0.35, -0.05, N.y) * (1.0 - isPool);
    float qlow = c / (R * 1.12 * taper);
    if (wall <= 0.0 && s * s + qlow * qlow > (isPool < 0.5 && R >= 2.0 ? 8.4 : 4.0)) return;
    vec3 ph = H23(vec2(seed, 1.7)) * 2.0 * PI;
    // Per-seed character of the outline: the lobe counts, how lumpy it is, how wide for its length.
    vec3 hv = H23(vec2(seed, 13.3));
    vec3 hw = H23(vec2(seed, 57.7));
    float asp = mix(0.8, 1.12, hv.x * hv.x);
    float Rc = R * asp;
    float Rt = Rc * taper;
    float q = c / Rt;
    float ang = atan(c, a + 1e-4);
    float dryRaw = clamp(age / max(p_dryTime, 1.0), 0.0, 1.0);
    // A splat has a wobble of two or three lobe counts picked by its seed, lumps, and thin spikes (a crown) when it came
    // down steeply, which dry to blunter ones; their number and strength vary. A pool has a rounder, lumpier edge made of
    // low-frequency ripples. Only the one that applies is evaluated.
    float edge;
    float edgeLo = 1.0;
    if (isPool > 0.5) {
        edge = 1.0 + 0.16 * mix(0.6, 1.2, hw.x) * sin(ang * (2.0 + floor(hv.y * 2.0)) + ph.x)
             + 0.1 * mix(0.5, 1.2, hw.y) * sin(ang * (3.0 + floor(hv.z * 2.0)) + ph.y)
             + 0.07 * mix(0.5, 1.2, hw.z) * sin(ang * (5.0 + floor(hv.x * 2.0)) + ph.z)
             + 0.2 * mix(0.6, 1.2, hv.y) * (VN(vec2(u, v) * (2.2 / R) + seed) - 0.5);
    } else {
        float sk = 0.5 + 0.5 * sin(ang * (7.0 + floor(hw.y * 9.0)) + ph.y * 3.0);
        float sk2 = sk * sk;
        float sk4 = sk2 * sk2;
        float spikes = sk4 * sk4 * sk2 * (0.55 + 0.45 * sin(ang * 4.0 + ph.z));
        float la = mix(0.5, 1.3, hw.x);
        // The character of the seed: from a smooth, lumpy blob to a crown of spikes.
        float sa = smoothstep(0.2, 0.7, hw.z) * mix(0.7, 1.3, hv.x);
        float lump = mix(0.03, 0.15, hv.z * hv.z);
        // (edgeLo is the smooth part of the outline; the dome of the blood is measured against it, so that the fine detail of the
        // edge does not stripe the middle.)
        edgeLo = 1.0 + la * (0.08 * sin(ang * (2.0 + floor(hv.x * 2.0)) + ph.x) + 0.05 * sin(ang * (3.0 + floor(hv.y * 3.0)) + ph.y));
        edge = edgeLo + la * 0.035 * sin(ang * (5.0 + floor(hv.z * 4.0)) + ph.z)
             + lump * (0.6 * sin(ang * (8.0 + floor(hv.y * 6.0)) + ph.z * 1.7) + 0.4 * sin(ang * (11.0 + floor(hv.x * 5.0)) + ph.x * 2.3))
             + spikes * 0.26 * sa * (1.0 - 0.7 * min(E, 1.0)) * (1.0 - 0.4 * dryRaw) / (1.0 + 0.12 * R);
    }
    float r0 = sqrt(s * s + q * q);
    float r = r0 / max(edge, 0.2);
    float dm = isPool > 0.5 ? r : min(r0 / max(edgeLo, 0.3), 1.5);
    // The distance to the edge, from the first-order estimate (1 - r) / |grad r|.
    float gr = sqrt(s * s / (La * La) + q * q / (Rt * Rt)) / max(r0, 1e-3);
    float Lloc = min(edge / max(gr, 1e-4), 1.6 * max(La, Rt));
    float fB = (1.0 - r) * Lloc;

    // The tail of a long streak breaks into beads.
    float tailAmt = smoothstep(0.35, 1.0, s) * clamp(E - 0.6, 0.0, 1.0) * (1.0 - isPool);
    if (tailAmt > 0.0) fB -= (1.0 - mix(1.0, smoothstep(0.4, 0.46, VN(vec2(s * 5.0 + seed, c * 2.5 / R))), tailAmt)) * Lloc;
    float streak = 1.0 - 0.45 * smoothstep(0.0, 1.0, s) * min(E, 1.0);

    // The nearest of: satellite droplets thrown past the edge (more of them the rounder and steeper the impact, and as many
    // or as few as the seed says), a spray of tiny specks, and on a wall the drips. fF is its distance to its edge, fR its
    // size, fd the way it tilts in the surface (u, v).
    float fF = -1.0e3;
    float fR = 1.0;
    float fK = 0.65;
    vec2 fd = vec2(0.0);
    // (Not on a speck under two units: its satellites are a pixel or two.)
    if (isPool < 0.5 && R >= 2.0 && r > 0.9 && r < 1.6) {
        float cs = max(R * 0.32, 0.35);
        vec2 sq = vec2(a / (1.0 + E * 0.6), c) / cs;
        vec2 id = floor(sq);
        vec2 f = fract(sq);
        vec3 hs = vec3(H21(id + seed * 1.31), H21(id * 1.37 + seed + 17.0), H21(id * 2.11 + seed + 41.0));
        float dens = 0.5 * mix(0.15, 1.7, H21(vec2(seed, 88.0))) * smoothstep(0.92, 1.05, r) * (1.0 - smoothstep(1.05, 1.42, r));
        if (hs.x < dens) {
            float sz = (0.12 + 0.2 * hs.z) * (1.0 - 0.45 * smoothstep(1.0, 1.4, r));
            vec2 sd = f - (0.28 + 0.44 * hs.yz);
            fF = (0.9 * sz - length(sd)) * cs;
            fR = 0.9 * sz * cs;
            vec2 dd = sd / max(sz, 1e-3);
            fd = vec2(dd.x * cp - dd.y * sp, dd.x * sp + dd.y * cp);
        }
        // Tiny specks, in the numbers the seed gives, that run into the edge of the blot.
        if (R >= 2.5) {
            float cs2 = max(R * 0.1, 0.12);
            vec2 sq2 = vec2(a / (1.0 + E * 0.6), c) / cs2;
            vec2 id2 = floor(sq2);
            vec2 f2 = fract(sq2);
            vec3 h2 = vec3(H21(id2 * 0.73 + seed * 1.7 + 5.0), H21(id2 * 1.91 + seed + 23.0), H21(id2 * 2.53 + seed + 61.0));
            float hm = H21(vec2(seed, 99.0));
            float dens2 = 0.6 * hm * hm * smoothstep(0.95, 1.1, r) * (1.0 - smoothstep(1.1, 1.58, r));
            if (h2.x < dens2) {
                float sz2 = 0.16 + 0.22 * h2.z;
                vec2 sd2 = f2 - (0.3 + 0.4 * h2.yz);
                float f2d = (0.9 * sz2 - length(sd2)) * cs2;
                if (f2d > fF) {
                    fF = f2d;
                    fR = 0.9 * sz2 * cs2;
                    vec2 dd2 = sd2 / max(sz2, 1e-3);
                    fd = vec2(dd2.x * cp - dd2.y * sp, dd2.x * sp + dd2.y * cp);
                }
            }
        }
    }
    // Runs down a wall: up to three drips that lengthen as the blood ages, each ending in a bead.
    if (wall > 0.0 && R >= 1.2) {
        float grow = 1.0 - exp(-age * 0.1);
        float dn = -v;
        // The blot's lowest point (the support of its ellipse straight down) in its own u, v.
        float rootV = sqrt(La * La * sp * sp + Rc * Rc * cp * cp);
        float rootU = -(La * La - Rc * Rc) * sp * cp / max(rootV, 1e-3);
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
            // (The root runs up into the body, so that the outline of the blot, which can fall short of it, does not cut the drip off.)
            // The tube ends in a bead a little wider than itself when it is long enough, and square when it is not.
            float bead = len >= w * 3.0 ? w * 1.2 : 0.0;
            float fTube = min(w - ax, min(along + 0.35 * rootV, len - bead - along));
            float fBulb = len >= w * 3.0 ? w * 1.2 - length(vec2(ax, along - len + bead)) : -1.0e3;
            float fDr = max(fTube, fBulb) - (1.0 - wall) * 2.0 * w;
            if (fDr > fF) {
                fF = fDr;
                fR = w;
                fK = 0.8;
                fd = vec2(sign(u - ox - sway), 0.0);
            }
        }
    }
    // Nothing near enough to the edge of this decal to matter (nearer than the fillet it could make with another).
    float mg = 0.15 + 0.5 * min(R, 3.0);
    if (max(fB, fF) < -mg) return;

    // ---- where blood may not land: a worm's volume. The floor under it is still the floor, and so is curved ground that
    // faces the way the decal does; the worm's body (facing another way) or anything high above the plane (a head, a hat)
    // is not. ----
    float wAway = max(1.0 - smoothstep(0.75, 0.92, nd), smoothstep(5.0, 8.0, abs(h)));
    float wm = 1.0 - (1.0 - smoothstep(WORM_E0, 1.0, wE)) * wAway;
    float gate = ng * hg * wm;
    if (gate <= 0.0) return;

    // ---- drying: thin blood dries first, a rim of clot forms ----
    float dryT = dryRaw * dryRaw * (3.0 - 2.0 * dryRaw);
    Fl o;
    o.F = fB;
    o.R = Lloc;
    o.S = R;
    o.uv = vec2(u, v) + seed * R * vec2(1.37, 2.11);
    o.kth = (0.4 + 0.6 * thick) * streak;
    o.fr = 0.0;
    o.dm = dm;
    o.dryT = dryT;
    o.lum = 0.4 + 0.2 * H21(vec2(seed, 31.7));
    o.pool = isPool;
    o.gate = gate;
    o.nrm = N;
    // The way the surface tilts: outward at the edge of the blot (the gradient of r).
    vec2 g = vec2(s / La, q / Rt);
    g /= max(length(g), 1e-5);
    o.outw = T * (g.x * cp - g.y * sp) + Bt * (g.x * sp + g.y * cp);
    if (fB > -mg) Merge(acc, o);
    if (fF > -mg) {
        o.F = fF;
        o.R = fR;
        o.kth = fK;
        o.fr = 1.0;
        o.outw = T * fd.x + Bt * fd.y;
        Merge(acc, o);
    }
}

// Shades the combined blood a (or nothing, when its coverage is nil) over col. Pv is the pixel in view space, pxw the
// size of a pixel in world units and vis the share of it that may be covered (distance to the camera, planarity).
void Shade(vec3 Pv, float pxw, Fl a, float vis, inout vec3 col) {
    float R = max(a.R, 0.05);
    // The silhouette is crisp, wet or dry: about a pixel of antialiasing and no falloff.
    float aaW = max(0.8 * pxw, 0.003 * R);
    float cov = smoothstep(-0.5 * aaW, aaW, a.F);
    float alpha0 = cov * a.gate * vis * p_strength;
    if (alpha0 <= 0.0) return;
    float aaN = aaW / R;
    float r = clamp(1.0 - a.F / R, 0.0, 1.2);
    float fr = a.fr;

    // A drop of blood stands on the ground: it is thin right at the edge, climbs over a rounded shoulder (the meniscus, a
    // few pixels wide) to a thick plateau that domes up toward the middle. rimU is 0 at the edge and 1 from the inner side
    // of the shoulder on.
    float rimW = max(clamp(0.3 / R + 0.03, 0.03, 0.35), 4.0 * aaN);
    float rimU = clamp((1.0 - r) / rimW, 0.0, 1.0);
    float shoulder = 1.0 - (1.0 - rimU) * (1.0 - rimU);
    float th = mix(a.kth * mix(0.3, 1.0, shoulder) * (0.62 + 0.38 * (1.0 - a.dm * a.dm)), a.kth, fr);
    th = max(th, 0.0);
    float dryT = a.dryT;
    float dry = clamp(dryT * 1.35 - th * 0.35, 0.0, 1.0);
    float rim = smoothstep(0.74, 0.95, r) * (1.0 - smoothstep(0.97, 1.06, r)) * cov * (1.0 - fr);
    th = min(th + rim * 0.5 * dryT, 1.2);
    float isPool = a.pool;

    // ---- the grain of the blood: noise in the blood's own surface frame, once for the combined blood, not once for each decal
    // (the place and the scale are those of the decal that holds the pixel deepest; the frame for the tilt is that of the blended normal) ----
    vec3 N = normalize(a.nrm + vec3(0.0, 1e-5, 0.0));
    vec3 ref = abs(N.y) > 0.9 ? vec3(1.0, 0.0, 0.0) : vec3(0.0, 1.0, 0.0);
    vec3 T = normalize(cross(ref, N));
    vec3 Bt = cross(N, T);
    vec2 uv = a.uv;
    float Rn = max(a.S, 0.3 * pxw);
    // A clotted pool: clots, and cracks in the dried blood.
    float clot = 0.0;
    float crack = 0.0;
    if (isPool > 0.02 && dryT > 0.35) {
        clot = smoothstep(0.66, 0.8, VN(uv * (4.0 / Rn) + 31.3)) * dryT * isPool;
        crack = (1.0 - smoothstep(0.0, 0.03, abs(VN(uv * (5.5 / Rn) + 5.9) - 0.5))) * smoothstep(0.5, 0.9, dryT) * isPool;
        crack *= smoothstep(0.1, 0.5, th);
    }
    th = min(th + clot * 0.4, 1.2);
    // A pool is not one depth all over: broad, slow swells and shallows of the thickness, so its colour moves from a brighter
    // ruby where it is thin to near black where it is deep (a pool was one flat dark red).
    th = clamp(th + (VN(uv * (1.5 / Rn) + 3.3) - 0.5) * 0.45 * isPool * (1.0 - fr), 0.0, 1.2);
    // Slight undulation of a wet surface, so a highlight is not a perfect mirror; the broader second one also picks out
    // the places where the blood has begun to clot (only on blood in a blot big enough to show them).
    float bump = 0.0;
    float bump2 = 0.0;
    float coag = 0.0;
    if (dryT < 0.97) {
        bump = VN(uv * (7.0 / Rn) + 11.7) - 0.5;
        if (a.S >= 2.0) {
            bump2 = VN(uv.yx * (3.2 / Rn) + 23.9) - 0.5;
            coag = smoothstep(0.02, 0.36, bump2 + 0.35 * bump) * 0.8;
        }
    }

    // ---- colour ----
    vec3 tint = p_blood / max(max(p_blood.r, p_blood.g), max(p_blood.b, 1e-3));
    float lum = a.lum;
    // The light there: blood in the sun is brighter than blood in the shade of a wall (it was the same dark red in both, which
    // read as a flat shadow), and it has a red glow of its own where it is thin, as light through a film of it has.
    float sceneL = dot(col, vec3(0.299, 0.587, 0.114));
    float lightK = mix(0.62, 1.3, smoothstep(0.25, 0.8, sceneL));
    vec3 thin = col * tint * 0.55 + p_blood * (0.34 + 0.12 * lum) * lightK;
    vec3 deep = p_blood * (0.34 + 0.09 * lum) * lightK + col * tint * 0.04 + p_blood * 0.1 * (1.0 - th) * lightK;
    vec3 wetCol = mix(thin, deep, smoothstep(0.1, 0.95, th * 0.72));
    vec3 dryBase = p_blood * 0.5 + vec3(0.04, 0.025, 0.016);
    vec3 dryCol = mix(dryBase * 0.85 + col * tint * 0.2, dryBase * (0.9 + 0.3 * lum) + col * 0.03, smoothstep(0.1, 0.8, th));
    vec3 base = mix(wetCol, dryCol, dry);
    // Wet blood is a little darker where it has begun to clot, and darkest in a thin line where the film ends.
    base *= 1.0 - 0.28 * coag * (1.0 - dry);
    float lwW = max(2.5 * aaW, 0.01 * R);
    base *= 1.0 - 0.3 * (1.0 - smoothstep(0.5 * lwW, 2.0 * lwW, a.F)) * (1.0 - fr);
    base *= 1.0 - 0.45 * crack;
    base *= 1.0 - 0.25 * rim * dryT;

    // ---- gloss: wet blood is a glossy bead with a thick, domed middle and a steep rounded rim; it dulls as it dries ----
    // (Not normalised: where two blots meet the two tilts cancel, which keeps the surface smooth there.)
    vec3 outw = a.outw;
    float domeR = mix(min(a.dm, 1.0), min(r, 1.0), fr);
    float tiltK = mix(0.42, 0.9, fr);
    float rimT = mix(rimU, 1.0, fr);
    float wet = (1.0 - dry) * p_gloss;
    // (A big blot is a film, not a bead: its middle is nearly flat however wide it is, so the dome is lower on a large one
    // and a pool does not catch one round highlight in its middle like a jelly.)
    float domeK = mix(clamp(3.0 / max(a.S, 0.1), 0.2, 1.0), 1.0, fr);
    float tilt = (0.9 * (1.0 - rimT) * (1.0 - rimT) + tiltK * th * domeR * domeK) * (1.0 - 0.6 * dry);
    vec3 Nb = normalize(N + outw * tilt + (T * bump * 0.06 + Bt * bump2 * (0.12 + 0.04 * isPool)) * a.bf * (1.0 - dry));
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
        // (A power of a number under the cut-off is under 1e-4 of what it is multiplied by: the tests keep the pows, which are
        // the dearest part, to the pixels that are lit.)
        // (On a wide, nearly flat film the tight lobe covers a large patch, so it is fainter there.)
        float tightK = (0.35 + 0.65 * domeK) * wet;
        if (nh > 0.96) specAmt = pow(nh, 400.0) * 1.3 * tightK;
        if (nh2 > 0.96) specAmt += pow(nh2, 300.0) * 1.6 * tightK;
        // The shoulder catches the light on a wider lobe than the dome does, and only there, so it reads as a bright rim.
        float rimA = (1.0 - rimT) * (1.0 - rimT);
        if (rimA > 0.0) {
            if (nh > 0.8) specAmt += pow(nh, 60.0) * 0.5 * rimA * wet;
            if (nh2 > 0.8) specAmt += pow(nh2, 40.0) * 0.5 * rimA * wet;
        }
        float fv = 1.0 - max(dot(Nv, V), 0.0);
        fv *= fv;
        specAmt += fv * fv * 0.3 * wet * (0.35 + 0.65 * (1.0 - rimT));
    }
    if (dry > 0.0 && nh > 0.7) specAmt += pow(nh, 24.0) * 0.1 * dry * (1.0 - clot);
    // A broad, soft lobe on the wet blood besides the tight ones: the whole film catches the light a little.
    if (wet > 0.0 && nh > 0.55) specAmt += pow(nh, 10.0) * 0.07 * wet * (0.4 + 0.6 * th);
    specAmt = min(specAmt, 1.0);
    specAmt *= smoothstep(0.1, 0.4, th) * (1.0 - 0.7 * crack) * (1.0 - 0.5 * coag) * mix(1.0, 0.75, isPool);

    // The sky in the blood: a wet surface mirrors the sky, warm at the horizon and blue overhead, most where it is seen at a
    // low angle (Fresnel), so a pool seen along the ground has a bright sheen instead of being a dark flat. Dry blood keeps a
    // little of it (a dull shine on the clotted surface).
    vec3 Rr = reflect(-V, Nv);
    float sy = clamp(dot(Rr, Rv * vec3(0.0, 1.0, 0.0)), -0.2, 1.0);
    vec3 skyC = mix(vec3(0.98, 0.84, 0.7), vec3(0.5, 0.64, 0.98), smoothstep(0.05, 0.75, sy));
    float fres = 0.03 + 0.97 * pow(1.0 - max(dot(Nv, V), 0.0), 5.0);
    float skyAmt = fres * (wet + 0.3 * dry) * smoothstep(0.1, 0.5, th) * (1.0 - 0.6 * crack) * (1.0 - 0.4 * coag) * (0.6 + 0.4 * lightK);

    float alpha = alpha0 * clamp(0.6 + 0.8 * th + 0.6 * dry, 0.0, 1.0);
    col = mix(col, base, alpha) + vec3(1.0, 0.8, 0.78) * specAmt * alpha + skyC * skyAmt * 0.38 * alpha;
}

// A slot whose sphere holds the pixel offers itself (A, B) to the three places; the one with the highest rank (the shallowest
// hold) gives up its place if the offer is deeper. An empty place has rank 2.
#define SLOT(A, B) if (A.w > 0.0) { vec3 q_ = Pw - A.xyz; float k_ = dot(q_, q_) / (A.w * A.w); if (k_ < 1.0) { cnt += 1.0; if (k0 >= k1 && k0 >= k2) { if (k_ < k0) { k0 = k_; cA0 = A; cB0 = B; } } else if (k1 >= k2) { if (k_ < k1) { k1 = k_; cA1 = A; cB1 = B; } } else { if (k_ < k2) { k2 = k_; cA2 = A; cB2 = B; } } } }

// The distance from the camera plane (the depth in view space, as a positive number) of the pixel at uv. A perspective
// projection has a view-space z that depends on the stored depth alone, so two rows of the inverse projection do it.
float ZAt(vec2 uv) {
    float zn = texture2D(mg_depth, uv).r * 2.0 - 1.0;
    return abs((mg_invProj[2].z * zn + mg_invProj[3].z) / (mg_invProj[2].w * zn + mg_invProj[3].w));
}

// The point of the ray through uv, in view space, scaled to one unit of view depth (|z| = 1). The direction of a ray does
// not depend on the depth in a perspective projection, so any stored depth will do.
vec3 RayAt(vec2 uv, float depth) {
    vec4 v = mg_invProj * vec4(vec3(uv, depth) * 2.0 - 1.0, 1.0);
    vec3 p = v.xyz / v.w;
    return p / max(abs(p.z), 1e-6);
}

void main() {
    vec4 scene = texture2D(mg_scene, mg_uv);
    float depth = texture2D(mg_depth, mg_uv).r;
    vec4 vp = mg_invProj * vec4(vec3(mg_uv, depth) * 2.0 - 1.0, 1.0);
    vec3 P = vp.xyz / vp.w;
    float dP = length(P);
    if (p_strength <= 0.0 || depth >= 1.0 || dP > 0.5 * mg_nearFar.y) {
        gl_FragColor = scene;
        return;
    }

    // The pixel in world space. mg_view is the world-to-view matrix in column-major layout with translation, so
    // its upper 3x3 is the world-to-view rotation and v * mat3(mg_view), which is transpose(R) * v, turns a view-space
    // vector back to world axes.
    vec3 Pw = (P - mg_view[3].xyz) * mat3(mg_view);

    vec4 cA0 = vec4(0.0), cA1 = vec4(0.0), cA2 = vec4(0.0);
    vec4 cB0 = vec4(0.0), cB1 = vec4(0.0), cB2 = vec4(0.0);
    float k0 = 2.0, k1 = 2.0, k2 = 2.0;
    float cnt = 0.0;
    if (p_count > 0.5) {
        SLOT(p_d0a, p_d0b) SLOT(p_d1a, p_d1b) SLOT(p_d2a, p_d2b) SLOT(p_d3a, p_d3b)
        SLOT(p_d4a, p_d4b) SLOT(p_d5a, p_d5b) SLOT(p_d6a, p_d6b) SLOT(p_d7a, p_d7b)
    }
    if (p_count > 8.5) {
        SLOT(p_d8a, p_d8b) SLOT(p_d9a, p_d9b) SLOT(p_d10a, p_d10b) SLOT(p_d11a, p_d11b)
        SLOT(p_d12a, p_d12b) SLOT(p_d13a, p_d13b) SLOT(p_d14a, p_d14b) SLOT(p_d15a, p_d15b)
    }
    if (p_count > 16.5) {
        SLOT(p_d16a, p_d16b) SLOT(p_d17a, p_d17b) SLOT(p_d18a, p_d18b) SLOT(p_d19a, p_d19b)
        SLOT(p_d20a, p_d20b) SLOT(p_d21a, p_d21b) SLOT(p_d22a, p_d22b) SLOT(p_d23a, p_d23b)
    }
    if (p_count > 24.5) {
        SLOT(p_d24a, p_d24b) SLOT(p_d25a, p_d25b) SLOT(p_d26a, p_d26b) SLOT(p_d27a, p_d27b)
        SLOT(p_d28a, p_d28b) SLOT(p_d29a, p_d29b) SLOT(p_d30a, p_d30b) SLOT(p_d31a, p_d31b)
    }
    if (cnt < 0.5) {
        gl_FragColor = scene;
        return;
    }
    // A decal fades out as the camera comes up to it (and the near plane, if it is far, pushes that out).
    float nf = smoothstep(max(2.0 * mg_nearFar.x, NEAR_NONE), max(5.0 * mg_nearFar.x, NEAR_FULL), dP);
    if (nf <= 0.0) {
        gl_FragColor = scene;
        return;
    }

    // The surface normal from the depth of the four neighbours: in each direction the difference on the side where the depth
    // changes less, so an edge is never differenced across to what is behind it. A neighbour is at the depth ZAt gives along
    // its own ray, which is this one's plus a pixel's worth of change.
    vec2 px = mg_resolution.zw;
    vec3 rP = P / max(abs(P.z), 1e-4);
    vec3 rdx = RayAt(mg_uv + vec2(px.x, 0.0), depth) - rP;
    vec3 rdy = RayAt(mg_uv + vec2(0.0, px.y), depth) - rP;
    vec3 Pr = ZAt(mg_uv + vec2(px.x, 0.0)) * (rP + rdx);
    vec3 Pl = ZAt(mg_uv - vec2(px.x, 0.0)) * (rP - rdx);
    vec3 Pu = ZAt(mg_uv + vec2(0.0, px.y)) * (rP + rdy);
    vec3 Pd = ZAt(mg_uv - vec2(0.0, px.y)) * (rP - rdy);
    vec3 dx = abs(Pr.z - P.z) < abs(P.z - Pl.z) ? Pr - P : P - Pl;
    vec3 dy = abs(Pu.z - P.z) < abs(P.z - Pd.z) ? Pu - P : P - Pd;
    vec3 n = cross(dx, dy);
    float nl = length(n);
    if (nl < 1e-9) {
        gl_FragColor = scene;
        return;
    }
    n /= nl;
    // Face the camera, which sits at the view-space origin.
    if (dot(n, P) > 0.0) n = -n;
    vec3 nW = n * mat3(mg_view);
    float pxw = max(length(dx), 1e-5);

    // The kept ones, in no particular order: their blood is one fluid.
    Fl acc = FlNone();
    float wE = p_wn > 0.5 ? WormE(Pw) : 9.0;
    // How grey the scene is here (smoke and steam over the ground are; sand, grass and blood are not).
    float gmx = max(scene.r, max(scene.g, scene.b));
    float grey = 1.0 - smoothstep(0.07, 0.17, (gmx - min(scene.r, min(scene.g, scene.b))) / max(gmx, 1e-3));
    cnt = min(cnt, 3.0);
    for (int k = 0; k < 3; k++) {
        if (float(k) >= cnt) break;
        vec4 A = k == 0 ? cA0 : (k == 1 ? cA1 : cA2);
        vec4 B = k == 0 ? cB0 : (k == 1 ? cB1 : cB2);
        Shape(Pw, nW, pxw, grey, A, B, wE, acc);
    }
    if (acc.F < -0.5 * max(0.8 * pxw, 0.003 * acc.R)) {
        gl_FragColor = scene;
        return;
    }
    // Is this a surface, not the edge of something in front of another? A neighbour must not lie well behind the tangent
    // plane here: the edge of a silhouette (the sky included), smoke and other thin things that write depth fail this and get
    // no blood, while the ground right next to something that stands in front of it is not touched by it. A convex crease
    // between two facets puts its far neighbour behind the plane by less than a pixel's width, so the limit is a fraction of
    // the distance to the camera, far above that and far below any silhouette.
    float dev = max(max(dot(n, P - Pr), dot(n, P - Pl)), max(dot(n, P - Pu), dot(n, P - Pd)));
    float j0 = 0.008 * abs(P.z) + 2.0 * pxw + 0.1;
    float vis = nf * (1.0 - smoothstep(j0, 2.5 * j0, dev));
    vec3 col = scene.rgb;
    Shade(P, pxw, acc, vis, col);
    gl_FragColor = vec4(col, scene.a);
}
