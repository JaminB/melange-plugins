#version 120
// Blood, wounds, black eyes, scorching and spilled guts on the worms' skin. Each of 16 slots is the world position of the
// middle of a worm's body (wormN), its blood amount, wound level and heading (wormNb), and its eye level, gut level and gut
// azimuth (wormNc); four vec4 parameters (scorch0..3) hold each slot's scorch level. Everything is painted in screen space
// from the depth buffer wherever a pixel lies on the surface of the body's ellipsoid, in a pattern held in the worm's own
// frame so it moves and turns with it. Wounds are up to five gashes at fixed places on the body (from the match seed and the
// slot, by arithmetic that bloodsand's Lua repeats in woundSites), which open one after another as the wound
// level rises. The eye level darkens the skin around the two eyes into purple-black bruises, one after the other. The gut
// level tears a wide opening in the belly (at the azimuth from the facing direction). The order on the skin is bruise,
// scorch, blood, then the openings. Sky is left alone and with every amount and level at 0 the output is the scene
// unchanged.
//
// An opening (a gash or the belly) is built in layers from the outside in: a rolled lip of torn skin that is lit from the
// depth buffer's own normal and tilted by a profile, pink-red raw dermis, thin broken patches of pale fat on only part of
// the torn edge (no continuous band), dark wet muscle with fibres running across it, and a cavity that gets darker with
// depth, with a film of blood over all of it. The layer boundaries wander on their own noise. The cavity is seen with parallax: the view direction, taken into the
// opening's frame, shifts where the floor is seen, so the walls show on the near side and the floor slides as the camera
// moves. In a gash the floor is clotted blood; in the belly it is coils of intestine in the same colours as the
// bloodsand/guts effect that draws the loops hanging out of it. Blood on the skin has a wet sheen from the same normal.
//
// The long code runs once per pixel: only a short test runs for every slot, to find the worm the pixel belongs to, and one
// worm's gashes are only tested for their blood trails while the single nearest one is shaded in full. A shader that
// expands this much code once per slot can link and then draw nothing on some drivers.
uniform sampler2D mg_scene;
uniform sampler2D mg_depth;
uniform mat4 mg_invProj;
uniform mat4 mg_view;
uniform vec2 mg_nearFar;
uniform float mg_time;
uniform vec3 p_worm0, p_worm1, p_worm2, p_worm3, p_worm4, p_worm5, p_worm6, p_worm7, p_worm8, p_worm9, p_worm10, p_worm11, p_worm12, p_worm13, p_worm14, p_worm15;
uniform vec3 p_worm0b, p_worm1b, p_worm2b, p_worm3b, p_worm4b, p_worm5b, p_worm6b, p_worm7b, p_worm8b, p_worm9b, p_worm10b, p_worm11b, p_worm12b, p_worm13b, p_worm14b, p_worm15b;
uniform vec3 p_worm0c, p_worm1c, p_worm2c, p_worm3c, p_worm4c, p_worm5c, p_worm6c, p_worm7c, p_worm8c, p_worm9c, p_worm10c, p_worm11c, p_worm12c, p_worm13c, p_worm14c, p_worm15c;
uniform vec4 p_scorch0, p_scorch1, p_scorch2, p_scorch3;
uniform vec3 p_blood;
uniform float p_strength;
uniform float p_seed;
varying vec2 mg_uv;

// Where the eyes and the gut sit on the body, measured in game against the worm model. The eyes are placed on the face as
// seen from straight ahead, in world units from the middle of the body: EYE_X sideways and EYE_Y up, and EYE_RX and
// EYE_RY are the bruise's half-sizes. The bruise is larger than the eye and sits low on it: most hats cover the top of
// the eyes, a worm's head bobs and slumps by a few units as it moves, and the cheek under the eye is what shows. The belly
// opening is GUT_Y above the middle of the body (so below it) on a body GUT_R in radius there, and GUT_HW and GUT_HH are
// its half-width and half-height when fully open. Bloodsand's Lua roots the loop of intestine at the same height. A gash
// is WOUND_HW by WOUND_HH half-sizes in the unit of the body's own direction space (one unit is BODY_R world units).
const float EYE_X = 2.3;
const float EYE_Y = 2.0;
const float EYE_RX = 3.6;
const float EYE_RY = 5.2;
const float GUT_Y = -6.5;
const float GUT_R = 5.5;
const float GUT_HW = 3.6;
const float GUT_HH = 2.2;
const float WOUND_HW = 0.60;
const float WOUND_HH = 0.20;
const float BODY_R = 5.6;

float Hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float Hash3(vec3 p) {
    return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453);
}

// Where gash k sits on the body: azimuth (x) and elevation (y). Each worm has an offset and a step for each, so the five sites
// of a worm are spread out along the azimuth and the height and no two worms match. There is a single multiplication and
// fract() in each term, so that bloodsand's Lua can compute the same in doubles (woundSites) and a float32 GPU agrees to
// about 1e-3. A hash built on sin() or on products of products would not agree.
vec2 SiteDir(float seed, float k) {
    float a0 = fract(seed * 0.7548777);
    float b0 = fract(seed * 0.5698403);
    float sa = 0.55 + 0.2 * fract(seed * 0.1234567 + 0.3);
    float sb = 0.30 + 0.2 * fract(seed * 0.2718282 + 0.6);
    return vec2(6.2831853 * fract(a0 + k * sa), mix(-0.35, 0.75, fract(b0 + k * sb)));
}

// Trilinear value noise, 0..1.
float Noise3(vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = mix(Hash3(i), Hash3(i + vec3(1.0, 0.0, 0.0)), f.x);
    float b = mix(Hash3(i + vec3(0.0, 1.0, 0.0)), Hash3(i + vec3(1.0, 1.0, 0.0)), f.x);
    float c = mix(Hash3(i + vec3(0.0, 0.0, 1.0)), Hash3(i + vec3(1.0, 0.0, 1.0)), f.x);
    float d = mix(Hash3(i + vec3(0.0, 1.0, 1.0)), Hash3(i + vec3(1.0, 1.0, 1.0)), f.x);
    return mix(mix(a, b, f.y), mix(c, d, f.y), f.z);
}

// Bilinear value noise, 0..1, for the flat layers of an opening (half the hashes of Noise3).
float Noise2(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(Hash(i), Hash(i + vec2(1.0, 0.0)), f.x), mix(Hash(i + vec2(0.0, 1.0)), Hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

// 1 below a and 0 above b (the reverse of smoothstep, which is undefined when its edges are the wrong way round).
float Edge(float a, float b, float x) {
    return 1.0 - smoothstep(a, b, x);
}

// The gut's colour from 0 (pale pink-grey) through a dusky red to 1 (deep purple-red); the same ramp is in guts.frag.
vec3 GutRamp(float m) {
    vec3 pale = vec3(0.88, 0.68, 0.63);
    vec3 mid = vec3(0.70, 0.34, 0.38);
    vec3 deep = vec3(0.38, 0.10, 0.19);
    return mix(mix(pale, mid, smoothstep(0.0, 0.5, m)), deep, smoothstep(0.45, 1.0, m));
}

// Coils seen into the belly: two sets of fat tubes crossing at an angle. In each, a band coordinate warped by slow sines
// and noise (so the tubes meander and loop, and differently for each worm) is turned into a round profile: 1 along the
// middle of a tube and 0 at the crease between neighbours. Where they overlap the higher one wins. w is in world units.
float GutTubes(vec2 w, float seed) {
    w = w / 1.4;
    float ph1 = 6.2831853 * Hash(vec2(seed, 41.0));
    float ph2 = 6.2831853 * Hash(vec2(seed, 43.0));
    float ph3 = 6.2831853 * Hash(vec2(seed, 47.0));
    float nz1 = Noise3(vec3(w * 0.7, Hash(vec2(seed, 53.0)) * 20.0));
    float nz2 = Noise3(vec3(w * 0.6 + 9.0, Hash(vec2(seed, 59.0)) * 20.0));
    float u1 = w.y * 1.6 + 0.55 * sin(w.x * 1.7 + ph1) + 0.3 * sin(w.x * 3.1 + w.y * 1.3 + ph2) + (nz1 - 0.5) * 1.4;
    float u2 = w.x * 1.1 + w.y * 1.3 + 0.6 * sin(w.y * 2.1 + ph3) + (nz2 - 0.5) * 1.6;
    float f1 = fract(u1) * 2.0 - 1.0;
    float f2 = fract(u2) * 2.0 - 1.0;
    return max(sqrt(max(1.0 - f1 * f1, 0.0)), sqrt(max(1.0 - f2 * f2, 0.0)) * 0.92);
}

// One candidate gash, number k (0..4), of the worm with this seed. dir is the unit direction from the worm's centre in
// ellipsoid-normalised space and qu the position in the worm's rotated frame (no seed offset). The gash is open once the
// wound level passes k / 5 and grows to full size over the next fifth. Adds the blood running down from it, in beads, to cov
// and core, and keeps the gash the pixel is most nearly on in best (how nearly), bestK and bestO (how open). mask is the
// worm-surface mask.
void WoundTrail(vec3 dir, vec3 qu, float seed, float wound, float k, float mask,
                inout float cov, inout float core, inout float best, inout float bestK, inout float bestO) {
    float o = clamp((wound - k / 5.0) * 5.0, 0.0, 1.0);
    if (o <= 0.0) return;
    float sz = mix(0.55, 1.0, o);

    vec2 ae = SiteDir(seed, k);
    vec3 s = vec3(cos(ae.x) * cos(ae.y), sin(ae.y), sin(ae.x) * cos(ae.y));
    float along = dot(dir, s);
    if (along <= 0.2) return;

    // Blood running down from the gash: below it, close to it sideways, fading with distance and broken up by noise, in
    // beads that swell where a drop is running.
    float below = s.y - dir.y;
    if (below > 0.0) {
        float side = length(dir.xz - s.xz);
        float nz = Noise3(vec3(qu.x * 0.8, qu.y * 0.25, qu.z * 0.8) + k * 3.1);
        float bead = smoothstep(0.55, 1.0, sin(below * 26.0 / sz + nz * 9.0 + k * 2.0));
        float width = (1.0 - smoothstep(0.03, 0.11, side * (1.0 - 0.45 * bead) + (nz - 0.5) * 0.08)) * smoothstep(0.0, 0.08, below);
        float runLen = 1.0 - smoothstep(0.1 * sz, 1.0 * sz, below);
        float run = width * runLen * smoothstep(0.22, 0.5, nz + 0.25 * runLen) * o * mask;
        cov = max(cov, run);
        core = max(core, run * (0.5 + 0.3 * bead));
    }
    if (along > best) {
        best = along;
        bestK = k;
        bestO = o;
    }
}

// One eye's bruise. side is +1 or -1 (which eye) and strength 0..1 how far it has darkened. qu is the position in the
// worm's frame, where the face looks along +Z, so the bruise is an oval laid on the front of the head as seen from
// straight ahead, with its edge broken up by noise. Adds the bruise to bruise and its darkest part to socket: a ring
// around the eye that is heavier underneath it, as a black eye is. mask is the worm-surface mask.
void Eye(vec3 qu, float side, float strength, float mask, inout float bruise, inout float socket) {
    if (strength <= 0.0 || qu.z <= 0.0) return;
    float x = (qu.x - side * EYE_X) / EYE_RX;
    float y = (qu.y - EYE_Y) / EYE_RY;
    float r2 = x * x + y * y + (Noise3(qu * 0.6 + side * 5.0) - 0.5) * 0.35;
    float r = sqrt(max(r2, 0.0));
    float front = smoothstep(0.0, 2.5, qu.z) * strength * mask;
    float ring = smoothstep(0.3, 0.6, r) * (1.0 - smoothstep(0.72, 1.0, r));
    bruise = max(bruise, (1.0 - smoothstep(0.65, 1.0, r)) * front);
    socket = max(socket, ring * mix(1.0, 0.6, smoothstep(-0.4, 0.3, y)) * front);
}

// Paints one torn opening, the gash or the belly, into col, which holds the skin colour there on the way in (bruised,
// scorched and bloodied already). o is the position in the opening's own plane (x along it, y across it) scaled so that its
// nominal edge is at length 1, and osz its half-size in world units. Vf, Kf and Ff are the directions to the camera, to the
// key light and to the fill, in the opening's frame (z straight out of the skin), and Nf the depth buffer's surface normal in
// that frame, which tilts the lip and the flesh with the real skin underneath. qu is the position in the worm's frame, for
// noise. isGut says the cavity holds coils instead of clotted blood. lum is the scene's brightness here and tint the blood
// colour scaled to a maximum of 1. mask is the worm-surface mask. Returns the coverage, 0..1.
float Opening(vec2 o, vec2 osz, vec3 Vf, vec3 Kf, vec3 Ff, vec3 Nf, vec3 qu, float seed, float isGut, float lum, vec3 tint,
              float mask, inout vec3 col) {
    float n1 = Noise3(qu * 0.9 + seed * 0.37) - 0.5;
    float n2 = Noise3(qu * 2.7 + seed * 1.1) - 0.5;
    float len = length(o);
    float phi = atan(o.y, o.x);
    // The edge is torn: noise moves it in and out, and a couple of tongues of skin hang into the opening.
    float lobes = smoothstep(0.55, 1.0, sin(phi * 3.0 + seed * 5.0));
    float shape = (1.0 - 0.3 * lobes) * (1.0 + 0.5 * n1 + 0.18 * n2);
    float q = len / shape;
    if (q > 1.34) return 0.0;
    float cover = Edge(1.16, 1.34, q) * mask;
    vec2 rdir = o / max(len, 1e-4);
    float expo = 0.35 + 1.0 * lum;
    vec3 Hk = normalize(Kf + Vf);
    vec3 Hf = normalize(Ff + Vf);

    // The rolled lip: a ridge in the profile at q = 1.07, its slope tilting the normal toward or away from the opening,
    // lit against the flat skin's own shading. The torn edge of the skin shows pink where it meets the flesh.
    float lipX = (q - 1.07) / 0.09;
    float lipH = exp(-lipX * lipX);
    float dh = -2.0 * lipX / 0.09 * lipH;
    vec3 Nb = normalize(mix(vec3(0.0, 0.0, 1.0), Nf, 0.6));
    vec3 Nl = normalize(Nb + vec3(-rdir * dh * 0.04, 0.0));
    float lipLight = dot(Nl, Kf) - dot(Nb, Kf);
    float lipSpec = pow(max(dot(Nl, Hk), 0.0), 50.0);
    float pink = Edge(1.02, 1.16, q);
    vec3 lipCol = col * (1.0 + 1.1 * lipLight) * mix(0.85, 1.0, Edge(1.05, 1.2, q));
    lipCol = mix(lipCol, vec3(0.80, 0.40, 0.38) * (0.35 + 0.9 * lum), 0.7 * pink);
    lipCol *= mix(vec3(1.0), tint * 0.75, 0.4 * pink);
    lipCol += vec3(1.0, 0.92, 0.9) * lipSpec * 0.35 * lum * pink;

    // The layers are not tidy rings. Each boundary wanders on its own noise (in world units on the skin, so a layer's
    // wander does not follow the opening's shape), the fat is only there on part of the edge, and a film of blood is over
    // all of it. A layer is only worked out where it can show: the muscle and the cavity inside, the fat in a band.
    vec2 wp = o * osz;
    float pa = Noise2(wp * 0.75 + seed * 0.61);
    float pb = Noise2(wp * 2.1 + seed * 1.37 + 7.0);
    float pc = Noise2(wp * 5.6 + seed * 0.43 + 19.0);
    float qd = q + 0.16 * (pa - 0.5) + 0.07 * (pb - 0.5);
    float wMus = Edge(0.78, 0.88, qd);
    float wCav = Edge(0.5, 0.6, q + 0.05 * (pc - 0.5));

    // Dermis, raw and pink-red, with a mottle of paler and redder.
    vec3 dermCol = mix(vec3(0.78, 0.38, 0.35), vec3(0.58, 0.17, 0.17), smoothstep(0.25, 0.75, pb * 0.6 + pc * 0.4)) * (0.3 + 0.85 * lum);
    dermCol *= mix(vec3(1.0), tint * 0.9, 0.35);
    vec3 c = mix(lipCol, dermCol, Edge(1.0, 1.1, q + 0.07 * (pb - 0.5)));

    // Muscle: dark red fibres running across the opening, sloping down into it, with wet glints.
    // Fibres run along the opening, stretched noise rather than rays.
    float fib = 0.0;
    vec3 mHi = clamp(p_blood * 1.6 + 0.04, 0.0, 1.0);
    vec3 mLo = p_blood * 0.3;
    if (wMus > 0.0 || wCav > 0.0) {
        fib = 0.55 * Noise3(vec3(o.x * 1.6, o.y * 7.0, seed)) + 0.45 * Noise3(vec3(o.x * 4.0 + 5.0, o.y * 16.0, seed + 3.0));
        fib = smoothstep(0.2, 0.8, fib);
    }
    if (wMus > 0.0) {
        vec3 Nm = normalize(Nb + vec3(-rdir * 0.5 * (0.9 - q) + vec2(n1, n2) * 0.9, 0.0));
        float mDiff = clamp(dot(Nm, Kf) * 0.7 + 0.45, 0.15, 1.0);
        vec3 muscleCol = mix(mLo, mHi, 0.25 + 0.75 * fib) * mDiff * expo * (1.0 - 0.45 * Edge(0.5, 0.86, q));
        muscleCol += vec3(1.0, 0.9, 0.88) * pow(max(dot(Nm, Hk), 0.0), 45.0) * 0.5 * lum;
        muscleCol += vec3(0.8, 0.85, 1.0) * pow(max(dot(Nm, Hf), 0.0), 30.0) * 0.12 * lum;
        c = mix(c, muscleCol, wMus);
    }

    // Fat: thin, broken patches of pale cream-yellow on part of the torn edge only. Where a patch is, it sits just inside
    // the dermis; its width varies along the edge and is nil in places, and a fine noise nibbles its borders.
    float fatM = 0.0;
    if (qd > 0.6 && qd < 1.2) {
        float fatPres = smoothstep(0.34, 0.6, Noise2(wp * 1.15 + seed * 2.3 + 31.0));
        float fatCen = 0.9 + 0.1 * (pa - 0.5);
        float fatHw = 0.1 * fatPres * (0.5 + 1.1 * pb);
        float qf = qd - fatCen + 0.05 * (pc - 0.5);
        fatM = smoothstep(0.0, 0.05, fatHw - abs(qf));
        if (fatM > 0.0) {
            fatM *= smoothstep(0.3, 0.55, Noise2(vec2(phi * 2.6 + seed, qd * 11.0)) + 0.25 * (pc - 0.5)) * (0.4 + 0.6 * smoothstep(0.3, 0.6, pc));
            vec3 fatCol = mix(vec3(0.88, 0.72, 0.42), vec3(0.95, 0.86, 0.64), pc) * (0.34 + 0.7 * lum);
            fatCol *= mix(vec3(1.0), tint * 0.9, 0.25);
            fatCol += vec3(1.0, 0.95, 0.8) * pow(max(dot(normalize(vec3((pb - 0.5) * 2.2, (pc - 0.5) * 2.2, 1.0)), Hk), 0.0), 40.0) * 0.3 * lum;
            c = mix(c, fatCol, fatM * 0.8);
        }
    }

    // The cavity. depth is 0 at its edge and 1 in the middle; the view ray shifts sideways on its way down by the camera's
    // direction in the opening's frame, so it meets the floor in a different place, or the wall.
    if (wCav > 0.0) {
        float dep = 1.0 - smoothstep(0.0, 0.58, q);
        float Dp = mix(1.3, 2.6, isGut);
        vec2 o2 = o - Vf.xy / max(Vf.z, 0.3) * (dep * Dp) / osz;
        float q2 = length(o2) / shape;
        float wall = smoothstep(0.5, 0.68, q2);
        // Light has to come in through the opening as well: the floor is lit where the key light's own ray down is clear.
        vec2 o3 = o2 + Kf.xy / max(Kf.z, 0.3) * (dep * Dp) / osz;
        float lit = Edge(0.38, 0.62, length(o3) / shape);
        vec3 floorCol;
        if (isGut > 0.5) {
            // Coils: tubes with a normal from the height's own slope, in the same wet colours as the guts effect.
            vec2 w = o2 * osz;
            float h0 = GutTubes(w, seed);
            float hx = GutTubes(w + vec2(0.14, 0.0), seed) - GutTubes(w - vec2(0.14, 0.0), seed);
            float hy = GutTubes(w + vec2(0.0, 0.14), seed) - GutTubes(w - vec2(0.0, 0.14), seed);
            vec3 Ng = normalize(vec3(-hx * 2.2, -hy * 2.2, 1.0));
            float m = clamp(0.1 + 0.6 * Noise3(qu * 0.9 + seed * 2.0) + 0.5 * (1.0 - h0) * (1.0 - h0), 0.0, 1.0);
            vec3 gc = GutRamp(m);
            gc = mix(gc, tint * dot(gc, vec3(0.299, 0.587, 0.114)) * 1.8, 0.1);
            float gd = clamp((dot(Ng, Kf) + 0.4) / 1.4, 0.0, 1.0);
            floorCol = gc * (0.5 * expo + gd * gd * lit * 0.8 * expo) * (0.35 + 0.65 * h0);
            floorCol += vec3(1.0, 0.95, 0.92) * pow(max(dot(Ng, Hk), 0.0), 120.0) * 1.6 * lit * lum;
            floorCol += vec3(1.0, 0.86, 0.86) * pow(max(dot(Ng, Hf), 0.0), 60.0) * 0.4 * lum;
        } else {
            // Clotted blood, nearly black, with a few wet glints.
            float cn = Noise3(vec3(o2 * 4.0, seed));
            vec3 Nc = normalize(vec3((cn - 0.5) * 1.6, (Noise3(vec3(o2 * 4.0 + 7.0, seed)) - 0.5) * 1.6, 1.0));
            floorCol = mix(p_blood * 0.55, p_blood * 0.12, cn) * (0.25 + 0.9 * lit) * expo;
            floorCol += vec3(1.0, 0.9, 0.9) * pow(max(dot(Nc, Hk), 0.0), 70.0) * 0.7 * lit * lum;
        }
        // The wall is lit from the far side: its normal points toward the middle of the opening.
        vec3 Nw = normalize(vec3(-normalize(o2 + 1e-4) * 0.9, 0.35));
        vec3 wallCol = mix(mLo, mHi, 0.2 + 0.6 * fib) * (0.12 + 0.55 * clamp(dot(Nw, Kf) + 0.2, 0.0, 1.0)) * expo;
        vec3 cavCol = mix(floorCol, wallCol, wall) * (1.0 - 0.4 * dep * dep);
        c = mix(c, cavCol, wCav);
    }
    // The film of blood over everything: heaviest toward the middle, broken by noise, glinting where it is wet.
    float film = clamp(0.2 + 0.55 * (1.0 - q) + 0.5 * (pa - 0.5) - 0.1 * fatM, 0.0, 0.8) * Edge(1.02, 1.12, q);
    c = mix(c, c * tint * 0.6 + p_blood * 0.05, film);
    c += vec3(1.0, 0.92, 0.9) * pow(max(dot(normalize(vec3((pb - 0.5) * 1.6, (pc - 0.5) * 1.6, 1.0)), Hk), 0.0), 60.0) * 0.45 * lum * film;
    col = mix(col, c, cover);
    return cover;
}

// Paints one worm's blood, bruises, scorching and openings into col, which holds the scene's colour on the way in. b is the
// blood amount, wound level and heading and ex the eye level, gut level and gut azimuth. P is the pixel's view-space
// position and n its surface normal, facing the camera. mg_view is the world-to-view matrix in column-major layout with
// translation, so d * mat3(mg_view), which is transpose(R) * d, turns a view-space offset back into world axes. slotIdx is
// the slot number as a float, which gives the worm its own seed. scorch is the slot's scorch level.
void Worm(vec3 P, vec3 n, vec3 centre, vec3 b, vec3 ex, float slotIdx, float scorch, inout vec3 col) {
    float amount = b.x;
    float wound = b.y;
    float eyeLevel = ex.x;
    float gutLevel = ex.y;
    if (amount <= 0.0 && wound <= 0.0 && eyeLevel <= 0.0 && gutLevel <= 0.0 && scorch <= 0.0) return;
    vec3 d = P - (mg_view * vec4(centre, 1.0)).xyz;
    if (dot(d, d) > 17.0 * 17.0) return;
    vec3 L = d * mat3(mg_view);

    // The body is roughly an upright ellipsoid, and the outer 15% fades out.
    float e = (L.x * L.x + L.z * L.z) / (9.5 * 9.5) + L.y * L.y / (16.0 * 16.0);
    float mask = 1.0 - smoothstep(0.85, 1.0, e);
    if (mask <= 0.0) return;

    // Only the worm's own surface takes blood: it faces away from the worm's centre, while the ground under the worm
    // and a wall beside it face toward the centre and fail this.
    float dl = length(d);
    if (dl < 1e-4) return;
    float facing = dot(n, d / dl);
    mask *= smoothstep(0.2, 0.45, facing);
    if (mask <= 0.0) return;

    // The pattern is rotated about +Y by -heading so it turns with the worm, and offset by the seed so no two worms match.
    float seed = p_seed + slotIdx * 37.0;
    float ch = cos(b.z), sh = sin(b.z);
    vec3 qu = vec3(L.x * ch - L.z * sh, L.y, L.x * sh + L.z * ch);

    vec3 tint = p_blood / max(max(p_blood.r, p_blood.g), max(p_blood.b, 1e-3));
    vec3 lumW = vec3(0.299, 0.587, 0.114);
    float lum = dot(col, lumW);
    vec3 base = col;

    float cov = 0.0, core = 0.0, bruise = 0.0, socket = 0.0;
    vec2 oW = vec2(9.0);
    vec2 oG = vec2(9.0);
    vec3 wA1 = vec3(1.0, 0.0, 0.0), wA2 = vec3(0.0, 1.0, 0.0), wS = vec3(0.0, 0.0, 1.0);
    float wSz = 1.0;
    float hwG = GUT_HW, hhG = GUT_HH;
    float azG = ex.z;

    vec3 en = qu / vec3(9.5, 16.0, 9.5);
    float el = length(en);
    if (el > 1e-4 && (wound > 0.0 || eyeLevel > 0.0 || gutLevel > 0.0)) {
        vec3 dir = en / el;
        if (wound > 0.0) {
            float best = 0.3, bestK = -1.0, bestO = 0.0;
            for (int ki = 0; ki < 5; ki++) {
                WoundTrail(dir, qu, seed, wound, float(ki), mask, cov, core, best, bestK, bestO);
            }
            if (bestK >= 0.0) {
                // The nearest gash, in full: its place, its frame (a slash in the tangent plane, slanted by a per-site
                // angle) and the position in it.
                float k = bestK;
                vec2 ae = SiteDir(seed, k);
                vec3 s = vec3(cos(ae.x) * cos(ae.y), sin(ae.y), sin(ae.x) * cos(ae.y));
                vec3 t1 = normalize(cross(s, vec3(0.0, 1.0, 0.0)));
                vec3 t2 = cross(s, t1);
                float ang = 3.1415927 * Hash(vec2(seed, k * 7.3 + 3.0));
                wA1 = t1 * cos(ang) + t2 * sin(ang);
                wA2 = t2 * cos(ang) - t1 * sin(ang);
                wS = s;
                wSz = mix(0.55, 1.0, bestO);
                vec3 v = dir - s;
                oW = vec2(dot(v, wA1) / (WOUND_HW * wSz), dot(v, wA2) / (WOUND_HH * wSz) + (Noise3(qu * 0.9 + k) - 0.5) * 0.5);
            }
        }
        if (eyeLevel > 0.0) {
            // One eye goes first (which one depends on the worm), the other follows as the level passes 0.3.
            float first = clamp(eyeLevel / 0.5, 0.0, 1.0);
            float second = clamp((eyeLevel - 0.3) / 0.7, 0.0, 1.0);
            float lead = Hash(vec2(seed, 91.0)) < 0.5 ? 1.0 : -1.0;
            Eye(qu, lead, first, mask, bruise, socket);
            Eye(qu, -lead, second, mask, bruise, socket);
        }
        if (gutLevel > 0.0) {
            // The belly opening lies on the body as on an upright cylinder: x is the distance round the body from the
            // opening's middle and y the height above it, in world units. Blood runs down from it as under a gash.
            float ang = atan(qu.x, qu.z) - azG;
            ang = mod(ang + 3.1415927, 6.2831853) - 3.1415927;
            if (abs(ang) < 1.5) {
                float x = ang * GUT_R;
                float y = qu.y - GUT_Y;
                float sz = mix(0.55, 1.0, gutLevel);
                hwG = GUT_HW * sz;
                hhG = GUT_HH * sz;
                oG = vec2(x / hwG, y / hhG);
                if (y < 0.0) {
                    float nz = Noise3(vec3(qu.x * 0.8, qu.y * 0.25, qu.z * 0.8) + 17.0);
                    float bead = smoothstep(0.55, 1.0, sin(-y * 3.2 / sz + nz * 9.0));
                    float width = (1.0 - smoothstep(0.3 * hwG, 0.8 * hwG, abs(x) * (1.0 - 0.4 * bead) + (nz - 0.5) * 0.8)) * smoothstep(0.0, 0.5, -y);
                    float runLen = 1.0 - smoothstep(1.0 * sz, 7.0 * sz, -y);
                    float run = width * runLen * smoothstep(0.22, 0.5, nz + 0.25 * runLen) * mask;
                    cov = max(cov, run);
                    core = max(core, run * (0.6 + 0.3 * bead));
                }
            }
        }
    }

    // Black eyes go on the skin first, so everything else sits on top of them. The bruise multiplies the scene toward
    // purple-black, darker toward the socket, so the worm's shading and the eye's shape survive. Two kinds of pixel are
    // mostly left alone. One is near-white (bright and unsaturated): the eye white, which keeps the eye reading as an eye.
    // The other is anything not the colour of a worm's skin (red over green over blue, moderately saturated): the oval is
    // laid on whatever is in front of the face, and a helmet or a cap should not look bruised.
    if (bruise > 0.0) {
        float mx = max(col.r, max(col.g, col.b));
        float mn = min(col.r, min(col.g, col.b));
        float white = smoothstep(0.6, 0.85, mn) * (1.0 - smoothstep(0.1, 0.3, mx - mn));
        float rg = (col.r - col.g) / max(mx, 1e-3);
        float gb = (col.g - col.b) / max(mx, 1e-3);
        float skinTone = smoothstep(0.03, 0.1, rg) * (1.0 - smoothstep(0.38, 0.5, rg))
                       * smoothstep(0.0, 0.06, gb) * (1.0 - smoothstep(0.38, 0.55, gb));
        vec3 skin = col * mix(vec3(0.62, 0.46, 0.66), vec3(0.16, 0.10, 0.20), socket);
        col = mix(col, skin, bruise * (1.0 - 0.7 * white) * mix(0.2, 1.0, skinTone));
    }

    // Scorching: soot-black patches with a heat-glow edge and glowing embers, fading out with the level. The patch is a
    // noise field in the worm's frame whose threshold falls as the level rises.
    if (scorch > 0.0) {
        vec3 qs = qu + vec3(Hash(vec2(seed, 5.1)), Hash(vec2(seed, 9.7)), Hash(vec2(seed, 13.3))) * 40.0;
        float f = 0.6 * Noise3(qs / 3.6) + 0.4 * Noise3(qs / 1.6 + 3.0) + 0.1 * clamp(L.y / 16.0, -1.0, 1.0);
        float thr = 0.84 - 0.5 * scorch;
        float charAmt = smoothstep(thr, thr + 0.1, f) * mask;
        float glowEdge = smoothstep(thr - 0.07, thr + 0.02, f) * (1.0 - smoothstep(thr + 0.02, thr + 0.1, f)) * mask;
        vec3 cell = floor(qs * 1.7);
        vec3 fc = fract(qs * 1.7) - 0.5;
        float spark = step(0.7, Hash3(cell)) * (1.0 - smoothstep(0.12, 0.42, length(fc)));
        float flick = 0.65 + 0.35 * sin(mg_time * 9.0 + Hash3(cell + 3.0) * 40.0);
        float hot = smoothstep(0.2, 0.7, scorch);
        vec3 soot = vec3(0.07, 0.06, 0.055) * (0.4 + 0.8 * lum) * (0.75 + 0.5 * Noise3(qs * 2.1));
        col = mix(col, soot, 0.93 * charAmt);
        col += vec3(1.0, 0.42, 0.08) * spark * charAmt * hot * flick * 1.5;
        col += vec3(1.0, 0.25, 0.04) * glowEdge * hot * (0.6 + 0.4 * flick) * 0.55;
    }

    // Blood: the soaked colour multiplies the skin, darker and thicker where the blood pools (core), plus a wet sheen from
    // the surface normal and a brighter meniscus at the edge of a puddle.
    if (amount > 0.0) {
        vec3 q = qu + vec3(Hash(vec2(seed, 3.1)), Hash(vec2(seed, 7.7)), Hash(vec2(seed, 11.3))) * 60.0;
        // Splotches a few units across, and runs: the same noise with Y squashed so its features stretch downward.
        float splotch = 0.65 * Noise3(q / 3.5) + 0.35 * Noise3(q / 1.8 + 7.0);
        float runs = 0.65 * Noise3(vec3(q.x, q.y * 0.3, q.z) / 2.6) + 0.35 * Noise3(vec3(q.x, q.y * 0.3, q.z) / 1.4 + 13.0);
        float field = max(splotch, runs - 0.04);
        // Wounds bleed downward, so there is a little more on the upper half and less toward the base.
        field += 0.14 * clamp(L.y / 16.0, -1.0, 1.0);
        float thr = 0.80 - 0.36 * amount;
        cov = max(cov, smoothstep(thr, thr + 0.08, field) * mask);
        core = max(core, smoothstep(thr + 0.15, thr + 0.3, field) * mask);
    }
    if (cov > 0.0) {
        // Multiplying keeps the worm's shading and face: the blood stains the skin instead of covering it, and the core
        // goes darker and thicker than the rest.
        vec3 soaked = col * tint * mix(0.75, 0.38, core) + p_blood * 0.08 * (0.5 + core);
        vec3 Kv = normalize(vec3(0.35, 0.85, 0.25) * mat3(mg_view));
        vec3 Vv = normalize(-P);
        float spec = pow(max(dot(n, normalize(Kv + Vv)), 0.0), 70.0);
        float edge = cov * (1.0 - cov) * 4.0;
        float wet = (0.25 + 0.75 * core) * cov;
        soaked += vec3(1.0, 0.92, 0.9) * (spec * 0.7 * wet + edge * 0.06 * spec) * (0.4 + lum);
        soaked += p_blood * 0.15 * edge * (1.0 - core);
        col = mix(col, soaked, cov);
    }

    // The openings go over the skin and its blood. The one nearer the pixel, the belly or the nearest gash, is shaded.
    float useGut = length(oG) < length(oW) ? 1.0 : 0.0;
    vec2 o = mix(oW, oG, useGut);
    if (length(o) < 1.5) {
        float ga = cos(azG), gs = sin(azG);
        vec3 a1 = mix(wA1, vec3(ga, 0.0, -gs), useGut);
        vec3 a2 = mix(wA2, vec3(0.0, 1.0, 0.0), useGut);
        vec3 sn = mix(wS, vec3(gs, 0.0, ga), useGut);
        vec2 osz = mix(vec2(WOUND_HW, WOUND_HH) * wSz * BODY_R, vec2(hwG, hhG), useGut);
        // The camera, the key light and the fill, from view space into the worm's frame and then the opening's frame.
        vec3 Vw = normalize(-P) * mat3(mg_view);
        vec3 Kw = normalize(vec3(0.35, 0.85, 0.25));
        vec3 Fw = normalize(vec3(-0.55, 0.25, 0.8) * mat3(mg_view));
        vec3 Vl = vec3(Vw.x * ch - Vw.z * sh, Vw.y, Vw.x * sh + Vw.z * ch);
        vec3 Kl = vec3(Kw.x * ch - Kw.z * sh, Kw.y, Kw.x * sh + Kw.z * ch);
        vec3 Fl = vec3(Fw.x * ch - Fw.z * sh, Fw.y, Fw.x * sh + Fw.z * ch);
        vec3 Vf = vec3(dot(Vl, a1), dot(Vl, a2), dot(Vl, sn));
        vec3 Kf = vec3(dot(Kl, a1), dot(Kl, a2), dot(Kl, sn));
        vec3 Ff = vec3(dot(Fl, a1), dot(Fl, a2), dot(Fl, sn));
        vec3 Nw = n * mat3(mg_view);
        vec3 Nloc = vec3(Nw.x * ch - Nw.z * sh, Nw.y, Nw.x * sh + Nw.z * ch);
        vec3 Nf = vec3(dot(Nloc, a1), dot(Nloc, a2), dot(Nloc, sn));
        Opening(o, osz, Vf, Kf, Ff, Nf, qu, seed, useGut, lum, tint, mask, col);
    }
}

// Chooses the worm a pixel belongs to. Worm() is long, and a shader that expands it once per slot is large enough that
// some drivers link it without an error and then draw nothing with it, so only this short test runs for every slot and
// Worm() runs once, for the slot it picks. best is the smallest value so far of the body ellipsoid's equation (below 1
// is inside the body), and the other outputs are that slot's values. n is the pixel's surface normal.
void Pick(vec3 P, vec3 n, vec3 centre, vec3 b, vec3 ex, float sc, float slotIdx,
          inout float best, inout vec3 wc, inout vec3 wb, inout vec3 wex, inout float wsc, inout float wslot) {
    if (b.x <= 0.0 && b.y <= 0.0 && ex.x <= 0.0 && ex.y <= 0.0 && sc <= 0.0) return;
    vec3 d = P - (mg_view * vec4(centre, 1.0)).xyz;
    // The same facing test as in Worm(): a surface that Worm() would reject must not win the pixel from another worm.
    if (dot(n, d) <= 0.2 * length(d)) return;
    vec3 L = d * mat3(mg_view);
    float e = (L.x * L.x + L.z * L.z) / (9.5 * 9.5) + L.y * L.y / (16.0 * 16.0);
    if (e < best) {
        best = e;
        wc = centre;
        wb = b;
        wex = ex;
        wsc = sc;
        wslot = slotIdx;
    }
}

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

    // Derivatives across a silhouette or a depth jump are garbage, so a pixel whose neighbours are implausibly far
    // away for a surface at this distance (6% of the distance plus a little) is left alone.
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

    // One worm per pixel: the one whose body the pixel is deepest inside.
    float best = 1.0, wslot = 0.0, wsc = 0.0;
    vec3 wc = vec3(0.0), wb = vec3(0.0), wex = vec3(0.0);
    Pick(P, n, p_worm0, p_worm0b, p_worm0c, p_scorch0.x, 0.0, best, wc, wb, wex, wsc, wslot);
    Pick(P, n, p_worm1, p_worm1b, p_worm1c, p_scorch0.y, 1.0, best, wc, wb, wex, wsc, wslot);
    Pick(P, n, p_worm2, p_worm2b, p_worm2c, p_scorch0.z, 2.0, best, wc, wb, wex, wsc, wslot);
    Pick(P, n, p_worm3, p_worm3b, p_worm3c, p_scorch0.w, 3.0, best, wc, wb, wex, wsc, wslot);
    Pick(P, n, p_worm4, p_worm4b, p_worm4c, p_scorch1.x, 4.0, best, wc, wb, wex, wsc, wslot);
    Pick(P, n, p_worm5, p_worm5b, p_worm5c, p_scorch1.y, 5.0, best, wc, wb, wex, wsc, wslot);
    Pick(P, n, p_worm6, p_worm6b, p_worm6c, p_scorch1.z, 6.0, best, wc, wb, wex, wsc, wslot);
    Pick(P, n, p_worm7, p_worm7b, p_worm7c, p_scorch1.w, 7.0, best, wc, wb, wex, wsc, wslot);
    Pick(P, n, p_worm8, p_worm8b, p_worm8c, p_scorch2.x, 8.0, best, wc, wb, wex, wsc, wslot);
    Pick(P, n, p_worm9, p_worm9b, p_worm9c, p_scorch2.y, 9.0, best, wc, wb, wex, wsc, wslot);
    Pick(P, n, p_worm10, p_worm10b, p_worm10c, p_scorch2.z, 10.0, best, wc, wb, wex, wsc, wslot);
    Pick(P, n, p_worm11, p_worm11b, p_worm11c, p_scorch2.w, 11.0, best, wc, wb, wex, wsc, wslot);
    Pick(P, n, p_worm12, p_worm12b, p_worm12c, p_scorch3.x, 12.0, best, wc, wb, wex, wsc, wslot);
    Pick(P, n, p_worm13, p_worm13b, p_worm13c, p_scorch3.y, 13.0, best, wc, wb, wex, wsc, wslot);
    Pick(P, n, p_worm14, p_worm14b, p_worm14c, p_scorch3.z, 14.0, best, wc, wb, wex, wsc, wslot);
    Pick(P, n, p_worm15, p_worm15b, p_worm15c, p_scorch3.w, 15.0, best, wc, wb, wex, wsc, wslot);
    if (best >= 1.0) {
        gl_FragColor = scene;
        return;
    }

    vec3 col = scene.rgb;
    Worm(P, n, wc, wb, wex, wslot, wsc, col);
    gl_FragColor = vec4(mix(scene.rgb, col, p_strength), scene.a);
}
