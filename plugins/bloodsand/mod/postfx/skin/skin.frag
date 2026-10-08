#version 120
// Blood, wounds, black eyes, scorching and spilled guts on the worms' skin. Each of 16 slots is the world position of the
// middle of a worm's body (wormN), its blood amount, wound level and heading (wormNb), and its eye level, gut level and gut
// azimuth (wormNc); four vec4 parameters (scorch0..3) hold each slot's scorch level. The blood amount carries one more
// number: 2 times the bin (1..32, or 0 when unknown) of the side the worm was last hit from, added to the amount (0..1), so
// that the blood can lie on that side. Everything is painted in screen space from the depth buffer wherever a pixel lies on
// the surface of the body's ellipsoid, in a pattern held in the worm's own frame so it moves and turns with it.
//
// Only skin takes any of it. Every pixel is first classified by the colour the scene has there (SkinTone): skin is a warm
// peach to orange whatever the light, so the ratios of its channels (green over red, blue over red) sit in a narrow window
// that lighting only scales, and its hue (21 to 28 degrees, more where the sun clips it) and saturation (0.45 to 0.69) stay put, while a hat, a helmet,
// glasses, a headband, a pair of ears, a moustache and the whites and pupils of the eyes are blue, green, grey, white, pink,
// yellower (a cowboy hat 34 to 40 degrees, a helmet 47 to 51), more saturated (an orange moustache, 0.76 and up) or darker
// brown, and fall outside it. The classifier gives 0..1, so the edge is soft, and every layer that is painted (blood,
// gashes, bruises, scorching, the belly) is multiplied by it: on the head and the body alike.
//
// Blood is not a uniform coat. It is soaked round the places that bleed (each open wound, and the place the worm was hit
// last), spreads further down than up, runs down the body from there in long, thinning streaks with a bead at the end, is
// smeared across the side that faces the hits and spattered over it in drops, and is thin or absent elsewhere, so the skin
// shows between. All of it is placed in the body's own shape (its ellipsoid and its unit directions), never from the depth
// buffer's facets. Wounds are up to five gashes at fixed places on the body (from the match seed and the slot, by arithmetic
// that bloodsand's Lua repeats in woundSites), which open one after another as the wound level rises. The eye level darkens
// the skin around the two eyes into purple-black bruises, one after the other: a ring that hugs each eye's white (found on the
// screen, so it follows the head wherever it bobs), darkest under the eye, with a swollen, faintly lit lip above. The gut
// level tears a wide opening in the belly (at the azimuth from the facing direction). The scorch level burns cracked, charred
// patches into the skin, fading out as it falls. The order on the skin is bruise, scorch, blood, then the openings; the
// blood and the openings stay thin over a bruise so a black eye shows through them. Sky is left alone and with every amount
// and level at 0 the output is the scene unchanged.
//
// An opening (a gash or the belly) is built in layers from the outside in: a rolled lip of torn skin that is lit from a
// smooth normal (the body ellipsoid's, with a little of the depth buffer's) and tilted by a
// profile, pink-red raw dermis, thin broken patches of pale fat on only part of
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
uniform vec4 mg_resolution;
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
const float EYE_RX = 5.4;
const float EYE_RY = 7.4;
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

// The most blue over red (v) that skin can have, given its green over red (u) and its brightness (mx). Skin's colour is a
// curve in the (u, v) plane that the light picks a point on: in the desert's shade and sun (u 0.57 to 0.75) v is 0.34 to
// 0.43; in the pale, cold light of the snow levels (u 0.75) it is 0.545 whatever the brightness; in yellow light (u 0.85 to
// 1.0) it climbs to 0.56, and sun that clips the red lifts it further. Whites, hats and metal have more blue than that.
float SkinLimit(float u, float mx) {
    return 0.585 - 0.5 * clamp(u - 0.75, 0.0, 0.25) + 0.085 * smoothstep(0.80, 0.88, mx) + 0.04 * smoothstep(0.93, 0.985, mx);
}

// How much a scene colour is a worm's skin, 0..1. Skin is a warm peach or orange; light scales all its channels, so the
// ratios of green and of blue to red (u and v) are what stay put (calibrated on the game's own frames: shade, sun, the
// desert's yellow light and the snow levels' cold light; see SkinLimit). Everything else sits outside the window: hats and
// helmets (v 0.6 and up, or blue and green above red), the eye whites (v 0.6 to 0.8, or pink with blue near green), glasses,
// headbands and ears (blue above green), a monocle (nearly no blue) and pupils (black). A moustache or tufts are a brown
// with v 0.44 to 0.50 and u 0.73 to 0.78 and mostly dark (skin of that blue is only seen brighter), which lies in a gap
// between the two kinds of skin, and is cut out as a hole.
// A greenish tint from poison passes while green stays below about 1.2 times red. The limits are soft, so the edge between
// skin and a hat is anti-aliased.
//
// Two more tests, which the (u, v) window alone cannot make because a hat and a skin of another light overlap in it: the
// hue and the saturation. Measured on the game's frames (many thousands of pixels each), skin has a hue of 21 to 28 degrees
// (up to 37 where the light clips its red) and a saturation of 0.60 to 0.69 in the desert's light (0.45 to 0.49 in the
// snow's); a cowboy hat is 34 to 40 degrees (0.59 to 0.71), a helmet 47 to 51, brown fur 31 to 36 and an orange moustache
// has the skin's hue at a saturation of 0.76 to 0.84. The hue is tested without an atan: the tangent of the hue is
// sqrt(3) (g - b) / (2 r - g - b), and the limit of 30 degrees is 0.577, soft over 3 degrees; it climbs toward 60 degrees
// (1.75) as the brightness goes from 0.85 to 0.97, because sun that clips the red turns skin yellow-cream (hue 45 to 60,
// saturation 0.45 to 0.6), and no hat, helmet or moustache is that bright (the brightest of them, a lit brim, is 0.63). strict is 0..1 where a hat or a moustache can be (above the eye line, round the mouth) and pulls both
// limits in a little.
float SkinTone(vec3 c, float strict) {
    float mx = max(c.r, max(c.g, c.b));
    float mn = min(c.r, min(c.g, c.b));
    float rr = max(c.r, 1e-3);
    float u = c.g / rr;
    float v = c.b / rr;
    float vmax = SkinLimit(u, mx);
    float hole = smoothstep(0.415, 0.44, v) * (1.0 - smoothstep(0.505, 0.525, v)) * smoothstep(0.66, 0.70, u) * (1.0 - smoothstep(0.79, 0.84, u))
               * (1.0 - smoothstep(0.78, 0.86, mx));
    float tn = 1.7320508 * (c.g - c.b) / max(2.0 * c.r - c.g - c.b, 1e-3);
    float tl = mix(0.577, 1.75, smoothstep(0.85, 0.97, mx)) - 0.02 * strict;
    float hue = 1.0 - smoothstep(tl, tl + 0.075, tn);
    float sat = 1.0 - smoothstep(0.72 - 0.02 * strict, 0.76 - 0.02 * strict, (mx - mn) / max(mx, 1e-3));
    return smoothstep(0.30, 0.40, u) * (1.0 - smoothstep(1.12, 1.30, u))
         * (1.0 - smoothstep(vmax - 0.025, vmax + 0.025, v)) * (1.0 - hole) * smoothstep(0.16, 0.26, v)
         * smoothstep(0.03, 0.09, mx) * smoothstep(0.03, 0.11, (c.g - c.b) / max(mx, 1e-3)) * hue * sat;
}

// How much a scene colour is the white of an eye, 0..1: cream or grey-pink, with more blue over red than skin has (v just
// above SkinLimit, here without its soft steps, as this runs for every tap), green over red above 0.62, and not dark.
float WhiteTone(vec3 c) {
    float mx = max(c.r, max(c.g, c.b));
    float rr = 1.0 / max(c.r, 1e-3);
    float u = c.g * rr;
    float vt = 0.605 - 0.5 * clamp(u - 0.75, 0.0, 0.25) + 0.085 * step(0.84, mx);
    return smoothstep(vt, vt + 0.06, c.b * rr) * smoothstep(0.62, 0.78, u) * step(0.3, mx);
}

// Where the eye whites are, seen from this pixel on the screen: x is how much white lies in rings around it (about 0.95 and
// 2.3 world units out times reach, five taps on each, turned by a random angle per pixel so that the rings do not show as
// bands; whatever the distance the rings are never nearer than 2 and 4.5 pixels, so that a black eye seen from across the
// level still has a ring of a few pixels), 0 far from an eye and 1 right beside one, and y is how much of that white is above
// the pixel, so 1 under an eye and 0 above it.
vec2 WhiteNear(vec3 P, float reach) {
    float ppu = 0.5 * mg_resolution.y / (abs(mg_invProj[1][1]) * max(-P.z, 1.0));
    vec2 t = mg_resolution.zw;
    float a0 = 6.2831853 * Hash(gl_FragCoord.xy);
    vec2 d1 = vec2(cos(a0), sin(a0));
    vec2 d2 = vec2(d1.x * 0.8090170 - d1.y * 0.5877853, d1.x * 0.5877853 + d1.y * 0.8090170);
    vec2 s1 = t * clamp(0.95 * reach * ppu, 2.0, 80.0);
    vec2 s2 = t * clamp(2.3 * reach * ppu, 4.5, 180.0);
    float sum = 0.0;
    float up = 0.0;
    for (int i = 0; i < 5; i++) {
        float w1 = 0.16 * WhiteTone(texture2D(mg_scene, mg_uv + d1 * s1).rgb);
        float w2 = 0.11 * WhiteTone(texture2D(mg_scene, mg_uv + d2 * s2).rgb);
        sum += w1 + w2;
        up += (d1.y > 0.25 ? w1 : 0.0) + (d2.y > 0.25 ? w2 : 0.0);
        d1 = vec2(d1.x * 0.3090170 - d1.y * 0.9510565, d1.x * 0.9510565 + d1.y * 0.3090170);
        d2 = vec2(d2.x * 0.3090170 - d2.y * 0.9510565, d2.x * 0.9510565 + d2.y * 0.3090170);
    }
    return vec2(clamp(sum, 0.0, 1.0), clamp(up / max(sum, 1e-3), 0.0, 1.0));
}

// The blood soaked round a point of the body (a wound, or where the worm was hit): a ragged patch, heavy at its middle, that
// spreads further down the body than up. dir is the pixel's unit direction from the body's centre in ellipsoid-normalised
// space, s the point's, r the patch's size in the same space (about 9 world units to 1), w how much of it there is (0..1,
// already times the worm-surface mask) and salt gives each patch its own edge.
void Soak(vec3 dir, vec3 s, float r, vec3 qu, float salt, float w, inout float cov, inout float core) {
    vec3 dv = dir - s;
    float dy = dv.y * (dv.y > 0.0 ? 2.3 : 1.0);
    float d = sqrt(dot(dv.xz, dv.xz) + dy * dy) / r;
    if (d > 1.7) return;
    d += (Noise3(qu * 1.3 + salt * 5.0) - 0.5) * 0.9;
    cov = max(cov, (1.0 - smoothstep(0.55, 1.0, d)) * w);
    core = max(core, (1.0 - smoothstep(0.15, 0.7, d)) * w);
}

// The blood on the body away from the wounds, from how much there is (amount, 0..1) and how much of the worm faces the side it
// was hit from (lobe, 0..1). hs is the place it was hit, a unit direction like dir. Four things, none of them a coat: the
// place it was hit is soaked; a few streaks run down the body, each starting at its own height, thickest at the start and
// thinning to a bead (a column's strength is noise over the circle round the body, which has no seam); a smear or two
// wipes across the hit side, thin enough that the skin shows through; and drops are spattered, more of them on the hit side
// (spheres of random size at random places in a grid, cut by the surface, so the drops come out round and of every size).
// Where there is little blood only the hit side has any.
void Splatter(vec3 qu, vec3 dir, vec3 hs, float lobe, float amount, float seed, float mask, inout float cov, inout float core) {
    vec3 q = qu + vec3(Hash(vec2(seed, 3.1)), Hash(vec2(seed, 7.7)), Hash(vec2(seed, 11.3))) * 60.0;
    Soak(dir, hs, 0.05 + 0.17 * amount, qu, 9.0, smoothstep(0.0, 0.25, amount) * mask, cov, core);

    vec2 c = qu.xz / max(length(qu.xz), 1e-3);
    float off = seed * 0.37;
    // Streaks. The noise is over the circle (c), so a streak is a narrow column; where it starts depends on a slower noise.
    float colN = Noise3(vec3(c * 4.2 + off, qu.y * 0.045));
    float srcN = Noise2(c * 2.3 + 7.0 + off);
    float dd = mix(-3.0, 9.0, srcN) - qu.y;
    float bead = smoothstep(0.55, 1.0, sin(dd * 1.9 + colN * 12.0));
    float thr = 0.84 - 0.22 * amount - 0.12 * lobe + 0.5 * clamp(dd / (3.0 + 11.0 * amount), 0.0, 1.5) - 0.07 * bead;
    float run = smoothstep(thr, thr + 0.06, colN) * smoothstep(-0.3, 0.6, dd) * smoothstep(0.0, 0.3, amount) * mask;
    cov = max(cov, run);
    core = max(core, run * 0.75);

    // A smear: wide across the body and short in height.
    if (lobe > 0.15 && amount > 0.1) {
        float warp = Noise2(vec2(c.x * 3.0 + c.y * 2.0 + 11.0 + off, qu.y * 0.3)) - 0.5;
        float smN = Noise3(vec3(c * 1.0 + 3.0 + off + warp * 0.9, qu.y * 0.5 + warp * 2.5));
        float ts = 0.84 - 0.10 * amount - 0.2 * lobe;
        cov = max(cov, 0.3 * smoothstep(ts, ts + 0.1, smN) * smoothstep(0.1, 0.4, amount) * smoothstep(0.15, 0.7, lobe) * mask);
    }

    // Spatter.
    vec3 g = q / 1.2;
    vec3 cell = floor(g);
    float present = Hash3(cell);
    if (present > 1.0 - (0.04 + 0.5 * amount) * (0.15 + 0.85 * lobe)) {
        float rad = 0.10 + 0.32 * Hash3(cell + 17.0) * Hash3(cell + 17.0);
        vec3 ctr = rad + (1.0 - 2.0 * rad) * vec3(Hash3(cell + 1.3), Hash3(cell + 7.7), Hash3(cell + 13.1));
        float drop = (1.0 - smoothstep(0.65, 1.0, length(fract(g) - ctr) / rad)) * mask;
        cov = max(cov, drop);
        core = max(core, 0.8 * drop);
    }
}

// One candidate gash, number k (0..4), of the worm with this seed. dir is the unit direction from the worm's centre in
// ellipsoid-normalised space and qu the position in the worm's rotated frame (no seed offset). The gash is open once the
// wound level passes k / 5 and grows to full size over the next fifth. Adds the blood soaked round it and running down from
// it, in beads, to cov and core, and keeps the gash the pixel is most nearly on in best (how nearly), bestK and bestO (how
// open). amount is the worm's blood amount, which sizes the soaked patch; mask is the worm-surface mask.
void WoundTrail(vec3 dir, vec3 qu, float seed, float wound, float amount, float k, float mask,
                inout float cov, inout float core, inout float best, inout float bestK, inout float bestO) {
    float o = clamp((wound - k / 5.0) * 5.0, 0.0, 1.0);
    if (o <= 0.0) return;
    float sz = mix(0.55, 1.0, o);

    vec2 ae = SiteDir(seed, k);
    vec3 s = vec3(cos(ae.x) * cos(ae.y), sin(ae.y), sin(ae.x) * cos(ae.y));
    float along = dot(dir, s);
    if (along <= 0.2) return;

    Soak(dir, s, mix(0.07, 0.19, o) * (0.55 + 0.7 * amount), qu, k, o * mask, cov, core);

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

// How much of one eye's bruise is here, 0..1, from its place on the face. side is +1 or -1 (which eye) and strength 0..1 how
// far it has darkened. qu is the position in the worm's frame, where the face looks along +Z (the facing from the game is
// (sin yaw, 0, cos yaw), and qu.z is the offset along it), so the bruise is an oval laid on the front of the head as seen
// from straight ahead, with its edge broken up by noise. nf is the surface normal's component along the facing: a surface
// that does not face forward (the back or the side of the head, when the head is turned or slumped away from the body's
// heading) never takes a bruise. The oval only says where the bruise may be; the shape inside it comes from where the eye
// white is on the screen. mask is the worm-surface mask.
void Eye(vec3 qu, float nf, float side, float strength, float mask, inout float oval) {
    if (strength <= 0.0 || qu.z <= 0.0 || nf <= 0.0) return;
    float x = (qu.x - side * EYE_X) / EYE_RX;
    float y = (qu.y - EYE_Y) / EYE_RY;
    float r = sqrt(x * x + y * y + (Noise2(qu.xy * 0.6 + side * 5.0) - 0.5) * 0.3);
    float front = smoothstep(0.0, 2.5, qu.z) * smoothstep(0.0, 0.4, nf) * strength * mask;
    oval = max(oval, (1.0 - smoothstep(0.6, 1.0, r)) * front);
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
            // (Dimmer than the lit skin around it even in strong sun: a bright yellow line here read as a seam.)
            vec3 fatCol = mix(vec3(0.84, 0.68, 0.46), vec3(0.9, 0.8, 0.64), pc) * (0.28 + 0.5 * lum);
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
// blood amount (0..1, plus 2 times the bin of the side the worm was last hit from), wound level and heading and ex the eye
// level, gut level and gut azimuth. P is the pixel's view-space
// position and n its surface normal, facing the camera. mg_view is the world-to-view matrix in column-major layout with
// translation, so d * mat3(mg_view), which is transpose(R) * d, turns a view-space offset back into world axes. slotIdx is
// the slot number as a float, which gives the worm its own seed. scorch is the slot's scorch level.
void Worm(vec3 P, vec3 n, vec3 centre, vec3 b, vec3 ex, float slotIdx, float scorch, inout vec3 col) {
    float hq = floor(b.x * 0.5 + 0.001);
    float amount = clamp(b.x - 2.0 * hq, 0.0, 1.0);
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

    // Only skin takes anything: what the scene shows here has to be the colour of a worm's skin (hue, saturation and the
    // ratios of its channels, see SkinTone). A hat, a helmet, glasses, a headband, ears, a moustache and the eyes (whites and
    // pupils) are outside it, on the head and on the body. Where a hat or a moustache can be, above the eye line and on the
    // front of the head round the mouth, the test is a little stricter (a hat is also wider than the head, and a moustache
    // sits on the face, so the front of the head under the eyes counts as the mouth).
    float strict = max(smoothstep(EYE_Y + 0.5, EYE_Y + 3.5, qu.y),
                       smoothstep(0.0, 2.0, qu.z) * Edge(EYE_Y - 1.0, EYE_Y + 1.0, qu.y) * smoothstep(EYE_Y - 12.0, EYE_Y - 8.0, qu.y));
    mask *= SkinTone(col, strict);
    if (mask <= 0.0) return;

    vec3 tint = p_blood / max(max(p_blood.r, p_blood.g), max(p_blood.b, 1e-3));
    vec3 lumW = vec3(0.299, 0.587, 0.114);
    float lum = dot(col, lumW);
    vec3 base = col;

    vec3 nWorld = n * mat3(mg_view);
    float nf = nWorld.x * sh + nWorld.z * ch;
    // The light falls on a smooth body: the depth buffer's normal is flat across each facet of the worm's mesh and jumps at
    // its edges, so a highlight or a lit lip on it alone comes out as angular shards. Shading uses almost only the body
    // ellipsoid's own normal, and the blood is placed from the body's shape too.
    vec3 nE = mat3(mg_view) * normalize(vec3(L.x / (9.5 * 9.5), L.y / (16.0 * 16.0), L.z / (9.5 * 9.5)) + vec3(0.0, 1e-6, 0.0));
    vec3 ns = normalize(mix(n, nE, 0.9));

    float cov = 0.0, core = 0.0, oval = 0.0;
    vec2 oW = vec2(9.0);
    vec2 oG = vec2(9.0);
    vec3 wA1 = vec3(1.0, 0.0, 0.0), wA2 = vec3(0.0, 1.0, 0.0), wS = vec3(0.0, 0.0, 1.0);
    float wSz = 1.0;
    float hwG = GUT_HW, hhG = GUT_HH;
    float azG = ex.z;

    vec3 en = qu / vec3(9.5, 16.0, 9.5);
    float el = length(en);
    if (el > 1e-4 && (wound > 0.0 || eyeLevel > 0.0 || gutLevel > 0.0 || amount > 0.0)) {
        vec3 dir = en / el;
        if (amount > 0.0) {
            // The side the worm was last hit from (an azimuth in the world; unknown, it comes from the seed), and where
            // on the body that hit is, in the worm's frame.
            float az = hq > 0.0 ? (hq - 0.5) * 0.19634954 : 6.2831853 * Hash(vec2(seed, 29.0));
            vec2 hw = vec2(sin(az), cos(az));
            float lobe = smoothstep(-0.4, 0.95, dot(L.xz / max(length(L.xz), 1e-3), hw));
            float he = mix(-0.1, 0.5, Hash(vec2(seed, 31.0)));
            vec2 hf = vec2(hw.x * ch - hw.y * sh, hw.x * sh + hw.y * ch);
            vec3 hs = normalize(vec3(hf.x * cos(he), sin(he), hf.y * cos(he)));
            Splatter(qu, dir, hs, lobe, amount, seed, mask, cov, core);
        }
        if (wound > 0.0) {
            float best = 0.3, bestK = -1.0, bestO = 0.0;
            for (int ki = 0; ki < 5; ki++) {
                WoundTrail(dir, qu, seed, wound, amount, float(ki), mask, cov, core, best, bestK, bestO);
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
            Eye(qu, nf, lead, first, mask, oval);
            Eye(qu, nf, -lead, second, mask, oval);
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

    // Black eyes go on the skin first. Where the oval allows a bruise, its shape is read off the screen: WhiteNear says how
    // near the pixel is to an eye white, so the bruise is a ring that hugs the white wherever the head is, and heavier
    // under the eye than above it, as a swollen lower lid is. The ring is wide and purple-black next to the white (darkest in
    // the lid under it, a crescent nearly black) and fades to a bluish-purple wash, scaled by the scene's own brightness so
    // the worm's shading survives; it is wider and darker the higher the eye level (the lower the health), and never
    // narrower than a couple of pixels, so it can be seen at the distance the game is played from. A faint highlight along
    // the outer edge above the eye reads as the swelling. The blood and the openings painted after it stay thin over the
    // bruise, so a black eye still shows on a bloodied face. Only skin pixels get here (mask), so the whites and the pupils
    // stay clean.
    float bruise = 0.0;
    if (oval > 0.04) {
        float lvl = clamp(eyeLevel, 0.0, 1.0);
        vec2 wn = WhiteNear(P, 0.85 + 0.45 * lvl);
        bruise = oval * (0.35 + 0.65 * smoothstep(0.03, 0.35, wn.x));
        float socket = clamp(oval * smoothstep(0.1, 0.55, wn.x) * mix(0.75, 1.0, wn.y) * (0.8 + 0.4 * lvl), 0.0, 1.0);
        float lid = oval * smoothstep(0.1, 0.45, wn.x) * smoothstep(0.4, 0.85, wn.y) * (0.55 + 0.45 * lvl);
        float rim = oval * smoothstep(0.02, 0.14, wn.x) * (1.0 - smoothstep(0.14, 0.38, wn.x)) * (1.0 - wn.y);
        float shade = clamp(lum * 1.15, 0.3, 1.1);
        vec3 bru = mix(vec3(0.44, 0.19, 0.50), vec3(0.045, 0.014, 0.075), socket) * shade;
        bru = mix(bru, vec3(0.02, 0.006, 0.035) * shade, lid);
        col = mix(col, bru, 0.97 * bruise);
        col += vec3(1.0, 0.86, 0.84) * rim * 0.07 * (0.3 + lum);
    }
    float keep = 0.7 * bruise;

    // Scorching: one burn, where the worm was hit (on the side it was last hit from, a little under the middle of the
    // body, the chest; when that is not known, on the front of the chest, and never on the back unless the hit came from there). It is
    // a single patch with a ragged edge in rings, as a flame leaves on skin: a reddened, singed halo; inside it skin cooked
    // to a dark leathery brown that is blistered here and there (pale, swollen bubbles); and in the middle a black crust,
    // cracked by a few fine fissures that show dull red flesh. The patch is smooth and whole (no islands of skin showing
    // through, no plates), and keeps the skin's own shading under it. Nothing glows except, in the first half second (the
    // level is still near 1), a faint ember flicker down in the fissures. As the level falls the whole mark fades out.
    if (scorch > 0.0) {
        vec3 qs = qu + vec3(Hash(vec2(seed, 5.1)), Hash(vec2(seed, 9.7)), Hash(vec2(seed, 13.3))) * 40.0;
        float grain = Noise3(qs * 2.3);
        float fade = smoothstep(0.0, 0.4, scorch) * mask;
        vec3 sc = vec3(0.0, -0.25, 1.0);
        if (hq > 0.0) {
            float saz = (hq - 0.5) * 0.19634954;
            vec2 sw = vec2(sin(saz), cos(saz));
            sc = vec3(sw.x * ch - sw.y * sh, -0.25, sw.x * sh + sw.y * ch);
        }
        // Distance from the hit, on the unit sphere of the body's directions, with a wandering edge: a slow wobble and a
        // faster one, different for each ring so that the rings are not parallel.
        float dS = length(en / max(el, 1e-4) - normalize(sc));
        float wob = Noise3(qs * 0.45) - 0.5;
        float wob2 = Noise3(qs * 1.15 + 5.0) - 0.5;
        float R = 0.55 + 0.1 * scorch;
        float halo = Edge(R * 1.1, R * 1.8, dS + 0.34 * wob + 0.1 * wob2) * fade;
        float cook = Edge(R * 0.7, R * 1.2, dS + 0.3 * wob - 0.12 * wob2) * fade;
        float crust = Edge(R * 0.4, R * 0.95, dS + 0.26 * wob2 - 0.1 * wob + (grain - 0.5) * 0.05) * fade;
        // The singed halo: the skin redder and a little darker.
        col = mix(col, col * vec3(0.74, 0.42, 0.34), 0.75 * halo);
        // Cooked: dark leathery brown, uneven.
        float leather = 0.8 + 0.4 * grain;
        col = mix(col, col * vec3(0.46, 0.27, 0.18) * leather + vec3(0.012, 0.006, 0.0), 0.88 * cook);
        // Blisters in the cooked ring: pale, swollen bubbles with a bright point.
        float bn = Noise3(qs * 2.1 + 13.0);
        float blister = smoothstep(0.7, 0.76, bn) * cook * (1.0 - crust);
        vec3 Ks = normalize(mat3(mg_view) * vec3(0.35, 0.85, 0.25));
        float bsp = pow(max(dot(normalize(ns + 0.9 * vec3(Noise3(qs * 4.0) - 0.5, Noise3(qs * 4.0 + 3.0) - 0.5, 0.0)), normalize(Ks - normalize(P))), 0.0), 40.0);
        col = mix(col, vec3(0.78, 0.5, 0.4) * (0.3 + 0.7 * lum) + vec3(1.0, 0.9, 0.85) * bsp * 0.25 * lum, 0.7 * blister);
        if (crust > 0.0) {
            // Fissures: a few wandering lines where noise crosses its middle value, only inside the crust.
            float c1 = abs(Noise3(qs * 0.55 + 21.0) - 0.5);
            float c2 = abs(Noise3(qs * 1.2 + 11.0) - 0.5);
            float crack = max(1.0 - smoothstep(0.0, 0.04, c1), 0.7 * (1.0 - smoothstep(0.0, 0.032, c2))) * smoothstep(0.5, 0.9, crust);
            vec3 black = vec3(0.06, 0.047, 0.04) * (0.5 + 0.9 * lum) * (0.8 + 0.4 * grain);
            vec3 fissure = vec3(0.24, 0.045, 0.03) * (0.4 + 0.9 * lum);
            float heat = smoothstep(0.82, 0.97, scorch);
            float flick = 0.6 + 0.4 * sin(mg_time * 11.0 + Hash3(floor(qs * 0.9)) * 40.0);
            fissure += vec3(0.7, 0.16, 0.03) * heat * flick * 0.22;
            float sheen = pow(max(dot(normalize(ns + 0.4 * vec3(grain - 0.5, bn - 0.5, 0.3)), normalize(Ks - normalize(P))), 0.0), 22.0);
            vec3 burnt = mix(black, fissure, crack * 0.9) + vec3(0.8, 0.72, 0.68) * sheen * 0.08 * (1.0 - crack) * (0.4 + lum);
            col = mix(col, burnt, 0.96 * crust);
        }
    }

    // Blood: the soaked colour multiplies the skin, darker and thicker where the blood pools (core), plus a wet sheen from
    // the surface normal and a brighter meniscus at the edge of a puddle.
    cov *= 1.0 - keep;
    core *= 1.0 - keep;
    if (cov > 0.0) {
        // Multiplying keeps the worm's shading and face: the blood stains the skin instead of covering it, and the core
        // goes darker and thicker than the rest.
        vec3 soaked = col * tint * mix(0.75, 0.38, core) + p_blood * 0.08 * (0.5 + core);
        vec3 Kv = normalize(vec3(0.35, 0.85, 0.25) * mat3(mg_view));
        vec3 Vv = normalize(-P);
        float spec = pow(max(dot(ns, normalize(Kv + Vv)), 0.0), 50.0);
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
        vec3 Nw = ns * mat3(mg_view);
        vec3 Nloc = vec3(Nw.x * ch - Nw.z * sh, Nw.y, Nw.x * sh + Nw.z * ch);
        vec3 Nf = vec3(dot(Nloc, a1), dot(Nloc, a2), dot(Nloc, sn));
        Opening(o, osz, Vf, Kf, Ff, Nf, qu, seed, useGut, lum, tint, mask * (1.0 - 0.85 * bruise), col);
    }
}

// The view-space position of the pixel at uv, from the depth buffer.
vec3 ViewPos(vec2 uv) {
    vec4 v = mg_invProj * vec4(vec3(uv, texture2D(mg_depth, uv).r) * 2.0 - 1.0, 1.0);
    return v.xyz / v.w;
}

// The surface normal at the pixel (view space, facing the camera) from the depth of its four neighbours. The screen-space
// derivatives dFdx and dFdy would do for this, but a GPU takes them over blocks of 2 by 2 pixels: one normal for the whole
// block, and a garbage one wherever the block straddles a silhouette. Here every pixel looks at its own neighbours and in
// each direction takes the difference on the side where the depth changes less, so an edge of the worm is never differenced
// across to the background. cover is 1 inside a surface and falls toward the outer silhouette, where a neighbour is much
// farther away and not part of the worm (the sky counts), by 0.45 for each such neighbour: about a pixel of anti-aliasing
// for what is painted on top. An edge inside the worm (the eyes standing out of the face, the chin over the body, a fold)
// has the worm behind it as well, so it is painted in full: lowering the cover there let the bare, lit skin show through
// as a bright line along every such edge. Cv is the worm's centre in view space.
float BodyE(vec3 Pv, vec3 Cv) {
    vec3 L = (Pv - Cv) * mat3(mg_view);
    return (L.x * L.x + L.z * L.z) / (9.5 * 9.5) + L.y * L.y / (16.0 * 16.0);
}

vec3 SurfaceNormal(vec3 P, vec3 Cv, out float cover) {
    vec2 t = mg_resolution.zw;
    vec3 Pr = ViewPos(mg_uv + vec2(t.x, 0.0));
    vec3 Pl = ViewPos(mg_uv - vec2(t.x, 0.0));
    vec3 Pu = ViewPos(mg_uv + vec2(0.0, t.y));
    vec3 Pd = ViewPos(mg_uv - vec2(0.0, t.y));
    // View space looks down -Z, so a farther neighbour has the smaller z. A jump of more than 2% of the distance (and a
    // little) between neighbouring pixels is more than any surface at a grazing angle makes: it is an edge. It is the
    // outer silhouette when the farther neighbour is outside the body, or so far behind that it cannot be the body.
    float jump = 0.02 * -P.z + 0.3;
    vec4 dz = vec4(Pr.z, Pl.z, Pu.z, Pd.z) - P.z;
    vec4 outside = max(step(0.95, vec4(BodyE(Pr, Cv), BodyE(Pl, Cv), BodyE(Pu, Cv), BodyE(Pd, Cv))), step(8.0, -dz));
    cover = clamp(1.0 - 0.45 * dot(outside, step(jump, -dz)), 0.0, 1.0);
    vec3 dx = abs(dz.x) < abs(dz.y) ? Pr - P : P - Pl;
    vec3 dy = abs(dz.z) < abs(dz.w) ? Pu - P : P - Pd;
    vec3 n = cross(dx, dy);
    float nl = length(n);
    // A sliver one pixel wide has no side to difference to: it takes the direction to the camera.
    n = (nl < 1e-9 || min(abs(dz.x), abs(dz.y)) > jump || min(abs(dz.z), abs(dz.w)) > jump) ? -normalize(P) : n / nl;
    return dot(n, P) > 0.0 ? -n : n;
}

// Chooses the worm a pixel belongs to. Worm() is long, and a shader that expands it once per slot is large enough that
// some drivers link it without an error and then draw nothing with it, so only this short test runs for every slot and
// Worm() runs once, for the slot it picks. best is the smallest value so far of the body ellipsoid's equation (below 1
// is inside the body), and the other outputs are that slot's values.
void Pick(vec3 P, vec3 centre, vec3 b, vec3 ex, float sc, float slotIdx,
          inout float best, inout vec3 wc, inout vec3 wb, inout vec3 wex, inout float wsc, inout float wslot) {
    if (b.x <= 0.0 && b.y <= 0.0 && ex.x <= 0.0 && ex.y <= 0.0 && sc <= 0.0) return;
    vec3 d = P - (mg_view * vec4(centre, 1.0)).xyz;
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
    if (p_strength <= 0.0 || depth >= 1.0 || length(P) > 0.5 * mg_nearFar.y) {
        gl_FragColor = scene;
        return;
    }

    // One worm per pixel: the one whose body the pixel is deepest inside. Most pixels are inside none and stop here, before
    // any normal is worked out. Whether the surface faces away from the worm is decided in Worm().
    float best = 1.0, wslot = 0.0, wsc = 0.0;
    vec3 wc = vec3(0.0), wb = vec3(0.0), wex = vec3(0.0);
    Pick(P, p_worm0, p_worm0b, p_worm0c, p_scorch0.x, 0.0, best, wc, wb, wex, wsc, wslot);
    Pick(P, p_worm1, p_worm1b, p_worm1c, p_scorch0.y, 1.0, best, wc, wb, wex, wsc, wslot);
    Pick(P, p_worm2, p_worm2b, p_worm2c, p_scorch0.z, 2.0, best, wc, wb, wex, wsc, wslot);
    Pick(P, p_worm3, p_worm3b, p_worm3c, p_scorch0.w, 3.0, best, wc, wb, wex, wsc, wslot);
    Pick(P, p_worm4, p_worm4b, p_worm4c, p_scorch1.x, 4.0, best, wc, wb, wex, wsc, wslot);
    Pick(P, p_worm5, p_worm5b, p_worm5c, p_scorch1.y, 5.0, best, wc, wb, wex, wsc, wslot);
    Pick(P, p_worm6, p_worm6b, p_worm6c, p_scorch1.z, 6.0, best, wc, wb, wex, wsc, wslot);
    Pick(P, p_worm7, p_worm7b, p_worm7c, p_scorch1.w, 7.0, best, wc, wb, wex, wsc, wslot);
    Pick(P, p_worm8, p_worm8b, p_worm8c, p_scorch2.x, 8.0, best, wc, wb, wex, wsc, wslot);
    Pick(P, p_worm9, p_worm9b, p_worm9c, p_scorch2.y, 9.0, best, wc, wb, wex, wsc, wslot);
    Pick(P, p_worm10, p_worm10b, p_worm10c, p_scorch2.z, 10.0, best, wc, wb, wex, wsc, wslot);
    Pick(P, p_worm11, p_worm11b, p_worm11c, p_scorch2.w, 11.0, best, wc, wb, wex, wsc, wslot);
    Pick(P, p_worm12, p_worm12b, p_worm12c, p_scorch3.x, 12.0, best, wc, wb, wex, wsc, wslot);
    Pick(P, p_worm13, p_worm13b, p_worm13c, p_scorch3.y, 13.0, best, wc, wb, wex, wsc, wslot);
    Pick(P, p_worm14, p_worm14b, p_worm14c, p_scorch3.z, 14.0, best, wc, wb, wex, wsc, wslot);
    Pick(P, p_worm15, p_worm15b, p_worm15c, p_scorch3.w, 15.0, best, wc, wb, wex, wsc, wslot);
    if (best >= 1.0) {
        gl_FragColor = scene;
        return;
    }

    float cover;
    vec3 n = SurfaceNormal(P, (mg_view * vec4(wc, 1.0)).xyz, cover);

    vec3 col = scene.rgb;
    Worm(P, n, wc, wb, wex, wslot, wsc, col);
    gl_FragColor = vec4(mix(scene.rgb, col, p_strength * cover), scene.a);
}
