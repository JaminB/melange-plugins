#version 120
// Human skin on the worms. The game paints every worm in one flat cartoon peach; this re-renders the pixels that are a
// worm's skin as a real human skin tone, keeping the light the game (and Sunstone's lighting) put on them, and adds what
// makes skin read as skin in a photograph: a measured albedo, lower in saturation than the peach; light scattered under the
// skin (a softer, red-orange terminator, warm, saturated shade, never grey, and a red glow at a backlit silhouette); a soft
// sheen, oilier on the forehead and the nose, broken by the pores; broad melanin blotches, a finer mottle and freckles;
// a fine relief of skin lines and pores, lit from the sun as a bump, at the scale it is seen at; and blood under the skin,
// flushing the cheeks, the nose and the lips. All of it sits on the worm.
// Uniform contract (all hidden, set by Sunstone's Lua with wum.postfx.setTransient):
//   p_worm0..p_worm15     vec3  world position of the middle of each worm's body (12 above the reported position, as in
//                               Bloodsand and Kindjal); (0,0,0) = slot unused
//   p_worm0b..p_worm15b   vec3  that worm's skin albedo, a display colour 0..1 (the tone, or one of the mixed tones)
//   p_worm0c..p_worm15c   vec3  x heading (radians about +Y, facing (sin, 0, cos)), y a seed for its own pattern, z slack:
//                               how far (world units) the body can be from the reported centre, from its speed
//   p_sunDir              vec3  world direction toward the theme's sun (the one the grade's sun glow uses)
//   p_compat              float 0..1 Sunstone's lighting on the scene: widens the skin test the way Kindjal's acid does
//   p_strength, p_lightKeep, p_subsurface, p_sheen, p_pores, p_mottle: the look (overlay sliders)
// Built-ins used: mg_scene, mg_depth, mg_invProj, mg_view, mg_nearFar, mg_resolution.
//
// It runs at order 55, after Bloodsand's skin (51), guts (52) and gibs (53) and Kindjal's acid (54): both of those find the
// skin by its peach colour, so they classify and paint the vanilla skin exactly as without this, and this then changes only
// what is still skin. The body is found the same way they find it: the same body ellipsoid (9.5 by 16 units) round the
// same centre, the same capsule shell, the same upright and facing tests and the same depth-gap test against the
// background (see Worm()), so the three effects agree on which pixels are a worm's surface.
//
// The skin itself is found by colour with the same classifier, SkinTone: Bloodsand's measured window (hue 21 to 28 degrees,
// saturation 0.45 to 0.69, the ratios green/red and blue/red), with Kindjal's lower hue limit (6 to 12 degrees) that cuts
// blood and raw dermis, and with Kindjal's compat widening while Sunstone's lighting tints the shade cold. A hat, a helmet,
// glasses, the eyes and a moustache fall outside it as they do for Bloodsand (more strictly above the eye line and round
// the mouth; above the eye line, where a hat is, without Kindjal's widening of the hue and saturation, which a sunlit
// cowboy hat's brown reaches into). Charred crust, which the widened window lets through in shade, is cut out. It gives a soft likelihood, never a hard mask, and that is what keeps the blood right:
//   - Blood Bloodsand painted fully over the skin (green/red far below 0.3, hue 0 to 4) is not skin and is left alone.
//   - A thin wipe or the soft edge of a stain is a blend of red and peach. The remap below is a continuous function of the
//     colour (in effect a gain per channel, the new albedo over the peach), so the red part of a blend stays red, only
//     darker or lighter with the tone, and the blend is weighted by the likelihood that falls off along the same ramps
//     (u 0.30 to 0.40, the lower hue limit) as the blood takes over. A wipe reads as blood on human skin, not on peach.
//   - Where a pixel has skin round it but is itself only loosely skin-coloured (the 1-pixel rim of a stain, a bruise, a
//     scorch mark or the acid), it takes the remap up to the skin around it (Feather()), so no peach halo is left between
//     the new skin and the paint. A pixel that is red, pink, purple, green or black does not pass the loose test either.
// The other plugins' paint sits outside the window. What Bloodsand would have painted differently on a human skin is
// redone as it would have come out (see Worm()): its scorch halo and cooked leather multiply the skin, so they take the
// skin's gain per channel (the charred crust's dark brown-black is left as it is). Its black eye (a purple-black wash with
// hard, swirled edges) is read as where and how heavy a bruise is, and the skin is drawn again under it as a bruise on this
// tone: a filter from a yellow fringe through red-purple to a deep blue-purple, softened into the skin round it. Pure blood,
// raw flesh, the guts and the acid keep their colours; blood and acid take a wet highlight, and the acid's pattern is
// smoothed a little.
//
// The remap works out the light on each pixel as if it were bare vanilla skin (the colour over the peach albedo, per
// channel), keeps most of its colour (lightKeep: Sunstone's warm sun and cold shade, a cave's dim, a blend's red) and
// lights the new albedo with it. Its brightness follows the albedo's, softened (a deep tone in shade would read as a hole
// at full contrast). Shading, the game's skin texture and Bloodsand's shading of a wound lip all come through it.
//
// Cost: like Kindjal's acid, a pixel away from every worm is two fetches, one unprojection and a sphere test per used
// slot. A pixel on a worm's shell runs SkinTone, the depth normal (four depth fetches), the gap test (two) and, only on a
// skin edge, four more scene fetches; then the long code once (Pick() chooses the worm), with four evaluations of the
// relief where it is drawn, and sixteen scene and depth taps inside the bruise's oval round the eyes and eight on the acid.
uniform sampler2D mg_scene;
uniform sampler2D mg_depth;
uniform mat4 mg_invProj;
uniform mat4 mg_view;
uniform vec2 mg_nearFar;
uniform vec4 mg_resolution;
uniform vec3 p_worm0, p_worm1, p_worm2, p_worm3, p_worm4, p_worm5, p_worm6, p_worm7, p_worm8, p_worm9, p_worm10, p_worm11, p_worm12, p_worm13, p_worm14, p_worm15;
uniform vec3 p_worm0b, p_worm1b, p_worm2b, p_worm3b, p_worm4b, p_worm5b, p_worm6b, p_worm7b, p_worm8b, p_worm9b, p_worm10b, p_worm11b, p_worm12b, p_worm13b, p_worm14b, p_worm15b;
uniform vec3 p_worm0c, p_worm1c, p_worm2c, p_worm3c, p_worm4c, p_worm5c, p_worm6c, p_worm7c, p_worm8c, p_worm9c, p_worm10c, p_worm11c, p_worm12c, p_worm13c, p_worm14c, p_worm15c;
uniform vec3 p_sunDir;
uniform float p_compat;
uniform float p_strength;
uniform float p_lightKeep;
uniform float p_subsurface;
uniform float p_sheen;
uniform float p_pores;
uniform float p_mottle;
varying vec2 mg_uv;

// Bloodsand's face constants (world units from the middle of the body, in the worm's own frame, +z forward): the eyes are
// EYE_X to the side and EYE_Y up.
const float EYE_X = 2.3;
const float EYE_Y = 2.0;

// The game's skin albedo, as the colour vanilla skin shows in white light with red at 1: hue 25 degrees, saturation 0.61,
// green/red 0.66 and blue/red 0.39, the middle of Bloodsand's measurements. Every pixel's light is read against it.
const vec3 PEACH = vec3(1.0, 0.66, 0.39);
const vec3 LUMW = vec3(0.299, 0.587, 0.114);

float Hash3(vec3 p) {
    return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453);
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

// x squared (pow() is undefined for a negative x).
float Sq(float x) {
    return x * x;
}

// 1 below a and 0 above b (the reverse of smoothstep, which is undefined when its edges are the wrong way round).
float Edge(float a, float b, float x) {
    return 1.0 - smoothstep(a, b, x);
}

// The most blue over red (v) that skin can have, given its green over red (u) and its brightness (mx); Bloodsand's,
// calibrated on the game's own frames (desert shade and sun, yellow light, the cold light of the snow levels).
float SkinLimit(float u, float mx) {
    return 0.585 - 0.5 * clamp(u - 0.75, 0.0, 0.25) + 0.085 * smoothstep(0.80, 0.88, mx) + 0.04 * smoothstep(0.93, 0.985, mx);
}

// How much a scene colour is a worm's skin, 0..1. This is Kindjal's acid SkinTone (Bloodsand's window with the lower hue
// limit that cuts blood and the pink of a wound, and compat for Sunstone's tinted shade: blue limit +0.11 in shade, hue
// limit 30 -> 33 degrees, saturation edges +0.03, dark floor down to mx 0.01..0.04) with Bloodsand's strict term (0..1
// above the eye line and round the mouth, where a hat or a moustache can be: both limits pulled in a little). loose 0..1
// widens it for Feather(): the ramps on u, on the lower hue and on blue move out, so a blend of skin and paint passes that
// the strict window lets fall away, while pure blood, pink dermis, a bruise's purple, acid green and black still fail.
float SkinTone(vec3 c, float strict, float compat, float loose, float qy) {
    float mx = max(c.r, max(c.g, c.b));
    float mn = min(c.r, min(c.g, c.b));
    float rr = max(c.r, 1e-3);
    float u = c.g / rr;
    float v = c.b / rr;
    float vmax = SkinLimit(u, mx) + compat * 0.11 * (1.0 - smoothstep(0.35, 0.8, mx)) + 0.06 * loose;
    float hole = smoothstep(0.415, 0.44, v) * (1.0 - smoothstep(0.505, 0.525, v)) * smoothstep(0.66, 0.70, u) * (1.0 - smoothstep(0.79, 0.84, u))
               * (1.0 - smoothstep(0.78, 0.86, mx));
    // The hue's tangent, sqrt(3) (g - b) / (2 r - g - b), against a limit of 30 degrees (33 with Sunstone's lighting) that
    // climbs toward 60 as sun clips the red; the lower limit (6 to 12 degrees) leaves blood and raw dermis out.
    float tn = 1.7320508 * (c.g - c.b) / max(2.0 * c.r - c.g - c.b, 1e-3);
    // (Above the eye line, where a hat is, the hue and saturation limits are Bloodsand's own, without Kindjal's widening:
    // a cowboy hat's brown, warmed by the sun, reaches into the widened window. Below it the skin keeps the widening.)
    float hc = compat * (1.0 - smoothstep(EYE_Y + 0.5, EYE_Y + 3.5, qy));
    float tl = mix(0.577, 1.75, smoothstep(0.74, 0.9, mx)) + 0.08 * hc - 0.02 * strict;
    float hue = (1.0 - smoothstep(tl, tl + 0.075, tn)) * smoothstep(0.10 - 0.05 * loose, 0.22 - 0.08 * loose, tn);
    // (Loose also lets a little more saturation through: blood is fully saturated, so a blend of it with skin climbs past
    // the window's edge well before it stops being mostly skin. Not round the mouth, where the orange moustache starts.)
    float s0 = 0.72 + 0.03 * hc - 0.02 * strict + 0.07 * loose * (1.0 - strict);
    float sa = (mx - mn) / max(mx, 1e-3);
    float sat = 1.0 - smoothstep(s0, s0 + 0.04, sa);
    // Sunstone's own cut: Bloodsand's charred crust (a fixed dark brown-black, saturation 0.33, never brighter than about
    // 0.1) passes the widened window in shade. It is let through as Bloodsand painted it: dark and greyer than any skin
    // that is still lit enough to see.
    sat *= 1.0 - Edge(0.09, 0.15, mx) * Edge(0.36, 0.43, sa);
    return smoothstep(0.30 - 0.12 * loose, 0.40 - 0.10 * loose, u) * (1.0 - smoothstep(1.12, 1.30, u))
         * (1.0 - smoothstep(vmax - 0.025, vmax + 0.025, v)) * (1.0 - hole) * smoothstep(0.16, 0.26, v)
         * smoothstep(0.03 - 0.02 * compat, 0.09 - 0.05 * compat, mx) * smoothstep(0.03, 0.11, (c.g - c.b) / max(mx, 1e-3)) * hue * sat;
}

// The view-space position of the pixel at uv, from the depth buffer.
vec3 ViewPos(vec2 uv) {
    vec4 v = mg_invProj * vec4(vec3(uv, texture2D(mg_depth, uv).r) * 2.0 - 1.0, 1.0);
    return v.xyz / v.w;
}

// The body ellipsoid's equation at a view-space point (below 1 is inside), for a body whose centre is Cv in view space and
// whose ellipsoid is grown by slack units (a fast worm).
float BodyE(vec3 Pv, vec3 Cv, float slack) {
    vec3 L = (Pv - Cv) * mat3(mg_view);
    float rh = 9.5 + slack, rv = 16.0 + slack;
    return (L.x * L.x + L.z * L.z) / (rh * rh) + L.y * L.y / (rv * rv);
}

// The surface normal at the pixel (view space, facing the camera) from the depth of its four neighbours, Bloodsand's way:
// in each direction the difference is taken on the side where the depth changes less, so a silhouette is never
// differenced across (screen derivatives work over 2x2 blocks and are garbage there). cover falls toward 0 at the outer
// silhouette, by 0.45 for each neighbour far behind and outside the body: about a pixel of anti-aliasing.
vec3 SurfaceNormal(vec3 P, vec3 Cv, float slack, out float cover) {
    vec2 t = mg_resolution.zw;
    vec3 Pr = ViewPos(mg_uv + vec2(t.x, 0.0));
    vec3 Pl = ViewPos(mg_uv - vec2(t.x, 0.0));
    vec3 Pu = ViewPos(mg_uv + vec2(0.0, t.y));
    vec3 Pd = ViewPos(mg_uv - vec2(0.0, t.y));
    float jump = 0.02 * -P.z + 0.3;
    vec4 dz = vec4(Pr.z, Pl.z, Pu.z, Pd.z) - P.z;
    vec4 outside = max(step(0.95, vec4(BodyE(Pr, Cv, slack), BodyE(Pl, Cv, slack), BodyE(Pu, Cv, slack), BodyE(Pd, Cv, slack))), step(8.0, -dz));
    cover = clamp(1.0 - 0.45 * dot(outside, step(jump, -dz)), 0.0, 1.0);
    vec3 dx = abs(dz.x) < abs(dz.y) ? Pr - P : P - Pl;
    vec3 dy = abs(dz.z) < abs(dz.w) ? Pu - P : P - Pd;
    vec3 n = cross(dx, dy);
    float nl = length(n);
    n = (nl < 1e-9 || min(abs(dz.x), abs(dz.y)) > jump || min(abs(dz.z), abs(dz.w)) > jump) ? -normalize(P) : n / nl;
    return dot(n, P) > 0.0 ? -n : n;
}

// The remap's weight on a pixel that is only partly skin by its own colour: the most skin among its four neighbours (one
// scene pixel away), capped by how loosely skin-coloured the pixel itself is. Only called where the strict likelihood k is
// between 0 and 1, i.e. on the rim of a stain, a bruise, a scorch, the acid or a hat, so a full-skin or a clearly non-skin
// pixel pays nothing for it.
float Feather(vec3 col, float k, float strict, float compat, float qy) {
    vec2 t = mg_resolution.zw;
    float kn = max(max(SkinTone(texture2D(mg_scene, mg_uv + vec2(t.x, 0.0)).rgb, strict, compat, 0.0, qy),
                       SkinTone(texture2D(mg_scene, mg_uv - vec2(t.x, 0.0)).rgb, strict, compat, 0.0, qy)),
                   max(SkinTone(texture2D(mg_scene, mg_uv + vec2(0.0, t.y)).rgb, strict, compat, 0.0, qy),
                       SkinTone(texture2D(mg_scene, mg_uv - vec2(0.0, t.y)).rgb, strict, compat, 0.0, qy)));
    return max(k, min(kn, SkinTone(col, strict, compat, 1.0, qy)));
}

// Bloodsand's mouth zone, 0..1: the front of the head under the eye line, where a moustache can be (with the part above
// the eye line, where a hat can be, it is where its skin test is stricter).
float Mouth(vec3 qu) {
    return smoothstep(0.0, 2.0, qu.z) * Edge(EYE_Y - 1.0, EYE_Y + 1.0, qu.y) * smoothstep(EYE_Y - 12.0, EYE_Y - 8.0, qu.y);
}

// How much a scene colour is Bloodsand's black eye (its purple wash, its near-black socket and their blends with the skin),
// 0..1: red over green, blue over red above the skin's (0.40 to 0.48), a hue below the skin's lower limit (where k gives
// up, so the two overlap and no blend of skin and bruise is left out of both), and some saturation. Eye whites (grey or
// pink, unsaturated), pupils (neutral black), blood (no blue) and a blue beanie (green over red) are not; Bloodsand's
// near-black lid (purple at a brightness of 0.02 or so) is. Only used inside the bruise oval (see Worm()).
float BruiseTone(vec3 c) {
    float mx = max(c.r, max(c.g, c.b));
    float mn = min(c.r, min(c.g, c.b));
    float rr = max(c.r, 1e-3);
    float tn = 1.7320508 * (c.g - c.b) / max(2.0 * c.r - c.g - c.b, 1e-3);
    return Edge(0.10, 0.26, tn) * smoothstep(0.40, 0.48, c.b / rr) * Edge(2.0, 2.6, c.b / rr)
         * smoothstep(0.04, 0.12, (c.r - c.g) / max(mx, 1e-3)) * smoothstep(0.25, 0.35, (mx - mn) / max(mx, 1e-3))
         * smoothstep(0.005, 0.014, mx);
}

// How much a scene colour is Bloodsand's scorching that multiplies the skin (the reddened halo, the cooked brown leather and
// their blends with the skin) or a blend of the skin with blood at the soft edge of a stain, 0..1: orange-red, hue 5 to
// about 21 degrees, green over red 0.24 to 0.6. Pure blood and raw flesh (green over red lower, hue near 0), pink dermis
// and the guts (hue near 0, more blue), hats (34 degrees and up) and the char's black are not. The skin (21 to 28 degrees)
// overlaps the top of the range, which is harmless (it takes the same gain); round the mouth (mouth 0..1), where an orange
// moustache has the skin's hue at a saturation above it, the top is held below the moustache's 21 degrees. The char's
// crust (dark, saturation about 0.33) is cut out as in SkinTone, so it passes through as painted, not recoloured.
float ScorchTone(vec3 c, float mouth) {
    float mx = max(c.r, max(c.g, c.b));
    float u = c.g / max(c.r, 1e-3);
    float tn = 1.7320508 * (c.g - c.b) / max(2.0 * c.r - c.g - c.b, 1e-3);
    float sa = (mx - min(c.r, min(c.g, c.b))) / max(mx, 1e-3);
    return smoothstep(0.09, 0.15, tn) * Edge(0.36 - 0.02 * mouth, 0.41 - 0.04 * mouth, tn)
         * smoothstep(0.24, 0.32, u) * Edge(0.56, 0.64, u) * smoothstep(0.02, 0.06, mx)
         * (1.0 - Edge(0.09, 0.15, mx) * Edge(0.36, 0.43, sa));
}

// A pore at p (in pore cells): one soft dot of about a third of the cell, at a random place in it (never across its edge),
// in about two cells of three. 0..1.
float Pore(vec3 p) {
    vec3 i = floor(p);
    vec3 o = vec3(Hash3(i), Hash3(i + 31.7), Hash3(i + 63.1));
    float d = length(fract(p) - 0.5 - 0.36 * (o - 0.5));
    return (1.0 - smoothstep(0.09, 0.23, d)) * step(0.3, fract(o.x * 7.13 + o.y));
}

// Fractal value noise, two octaves, -0.5..0.5 (about -0.35..0.35 in practice).
float Fbm(vec3 p) {
    return 0.65 * Noise3(p) + 0.35 * Noise3(p * 2.03 + 17.3) - 0.5;
}

// A thin line where the noise crosses its middle, 0..1 (1 on the line): ridged noise sharpened, for the lines of the skin.
float Line(vec3 p) {
    float r = 1.0 - abs(2.0 * Noise3(p) - 1.0);
    r *= r;
    return r * r;
}

// The skin's fine relief at q (the worm's frame, world units), about 0 on the surface and negative in the hollows: shallow
// lines running round the body (stretched along it, as on a forehead or a neck) at about half a unit, a finer crosshatch
// turned against them (qr is q turned), the pores' pits and a faint grain. l1 and l2 fade the coarse and the fine bands in
// with the screen size, so nothing finer than a few pixels is drawn (it would shimmer).
float Relief(vec3 q, vec3 qr, float l1, float l2, float po) {
    float h = -0.16 * l1 * Line(q * vec3(0.45, 1.6, 0.45) + 5.0);
    h -= 0.12 * l2 * Line(qr * 2.6 + 9.0);
    h -= 0.22 * l2 * po * max(Pore(q * 4.0 + 23.0), Pore(qr * 4.6 + 5.0));
    h += 0.22 * l2 * (Noise3(q * 6.5 + 41.0) - 0.5) + 0.16 * l1 * (Noise3(q * 1.7 + 61.0) - 0.5);
    return h;
}

// Wet paint on the body, 0..1: Bloodsand's blood and the wet red of an opening (hue near 0, green over red under 0.35,
// saturated) and Kindjal's acid (green-yellow: green at or over red, blue under 0.36 to 0.48 of green, where the army
// helmet's olive drab, 0.57 and up, is not). They take a wet highlight from the sun on the body's smooth normal, as skin
// takes its sheen; x is blood, y acid.
vec2 WetTone(vec3 c) {
    float mx = max(c.r, max(c.g, c.b));
    float mn = min(c.r, min(c.g, c.b));
    float sa = (mx - mn) / max(mx, 1e-3);
    float blood = Edge(0.28, 0.38, c.g / max(c.r, 1e-3)) * Edge(0.30, 0.45, c.b / max(c.r, 1e-3)) * smoothstep(0.55, 0.7, sa)
                * smoothstep(0.02, 0.06, mx);
    float acid = smoothstep(0.85, 0.95, c.g / max(c.r, 1e-3)) * Edge(1.6, 2.2, c.g / max(c.r, 1e-3))
               * Edge(0.36, 0.48, c.b / max(c.g, 1e-3)) * smoothstep(0.05, 0.1, mx);
    return vec2(blood, acid);
}

// The colour a bruise lends the skin over it, a filter on the albedo for a bruise of t 0..1: a yellow-green fringe where it is
// faint, then a dusky red-purple, then a deep blue-purple at its heaviest. A filter, so it takes the skin's own depth: on a
// deep tone it is a dark brown-purple, never the near-black of a painted ring.
vec3 BruiseFilter(float t) {
    vec3 f = mix(vec3(1.0), vec3(0.99, 0.97, 0.88), smoothstep(0.0, 0.2, t));
    f = mix(f, vec3(0.72, 0.52, 0.66), smoothstep(0.12, 0.45, t));
    f = mix(f, vec3(0.48, 0.35, 0.56), smoothstep(0.4, 0.75, t));
    return mix(f, vec3(0.33, 0.23, 0.42), smoothstep(0.75, 1.0, t));
}

// One worm's skin at this pixel. P is the view-space position, n the depth normal (view space, facing the camera), centre
// the body centre (world), alb the skin albedo, hs = (heading, seed, slack). k is the strict skin likelihood of col (the
// scene here). Returns the colour this pixel takes on the worm and writes the worm-surface weight (0..1) to w: the new skin
// where the pixel is skin, and where it is the other plugins' paint, that paint as it would have come out on the new skin.
vec3 Worm(vec3 P, vec3 n, vec3 centre, vec3 alb, vec3 hs, vec3 col, float k, float strict, float compat, out float w) {
    w = 0.0;
    float slack = hs.z;
    vec3 L = (P - (mg_view * vec4(centre, 1.0)).xyz) * mat3(mg_view);
    float rh = 9.5 + slack, rvt = 16.0 + slack;
    float e = (L.x * L.x + L.z * L.z) / (rh * rh) + L.y * L.y / (rvt * rvt);
    float mask = 1.0 - smoothstep(0.85, 1.0, e);

    // Bloodsand's surface tests, so the same pixels are a worm's surface for all three effects: a shell round the vertical
    // axis (the body is a capsule 5.6 in radius, straight for 8 units up and down), upright along the straight part, facing
    // away from the axis. Sunlit sand in the ellipsoid (a ridge in front, a dune behind) has the colour of skin and fails
    // these. The shell grows with the slack so a worm flying between two reports keeps its skin.
    vec3 rv = vec3(L.x, L.y - clamp(L.y, -8.0 - slack, 8.0 + slack), L.z);
    float rl = max(length(rv), 1e-4);
    vec3 nWorld = n * mat3(mg_view);
    float shell = smoothstep(max(2.4 - slack, 0.0), max(3.6 - slack, 0.5), rl) * (1.0 - smoothstep(6.9 + slack, 8.1 + slack, rl));
    float upright = 1.0 - smoothstep(0.55, 0.85, abs(nWorld.y)) * (1.0 - smoothstep(0.0, 2.0, abs(rv.y)));
    mask *= shell * upright * smoothstep(0.1, 0.5, dot(nWorld, rv / rl));
    if (mask <= 0.0) return col;
    // A worm stands clear of what is behind it: about a body's width to either side the depth falls away. A face of ground
    // in front of a worm goes on at its own depth to both sides. (The offset is 7.6 units, more than the body's radius, at
    // any size: capped at a few hundred pixels only, as a fixed cap of 160 left both taps on the body of a worm that fills
    // the screen, and the middle of it, where both fall least, failed as a thin vertical line.)
    float ppx = 0.5 * mg_resolution.y / (abs(mg_invProj[1][1]) * max(-P.z, 1.0));
    float sxo = clamp(7.6 * ppx, 4.0, max(160.0, 0.45 * mg_resolution.x)) * mg_resolution.z;
    float gapL = P.z - ViewPos(mg_uv - vec2(sxo, 0.0)).z;
    float gapR = P.z - ViewPos(mg_uv + vec2(sxo, 0.0)).z;
    mask *= max(smoothstep(1.2, 3.5, gapL), smoothstep(1.2, 3.5, gapR));
    if (mask <= 0.0) return col;
    w = mask;

    // The worm's own frame, as Bloodsand's: rotated about +Y by -heading, so +z is the way it faces and the pattern turns and
    // moves with it (nothing swims across the screen), and a seed per worm so no two have the same pores.
    float ch = cos(hs.x), sh = sin(hs.x);
    vec3 qu = vec3(L.x * ch - L.z * sh, L.y, L.x * sh + L.z * ch);
    // (The seed's offset is kept within 40 units: the hash takes sin() of its input, which loses precision on some GPUs
    // far from 0, so a seed of several hundred units would turn the pores into a visible pattern.)
    vec3 qs = qu + 40.0 * fract(hs.y * vec3(0.0731, 0.0317, 0.0519));

    // The smooth body normal (the depth buffer's is faceted by the mesh; Bloodsand shades from the ellipsoid's the same way)
    // and the theme's sun, for the terminator, the relief and the sheen.
    vec3 nE = mat3(mg_view) * normalize(vec3(L.x / (rh * rh), L.y / (rvt * rvt), L.z / (rh * rh)) + vec3(0.0, 1e-6, 0.0));
    vec3 ns = normalize(mix(n, nE, 0.8));
    vec3 V = -normalize(P);
    vec3 Ls = normalize(mat3(mg_view) * p_sunDir);
    float nv = max(dot(ns, V), 0.0);
    float ndl = dot(ns, Ls);

    // The remap's weight: the strict likelihood, raised on a rim to the skin round it (Feather), so no peach is left at the
    // edge of the paint.
    float kw = k < 0.98 ? Feather(col, k, strict, compat, qu.y) : k;

    float lumP = dot(PEACH, LUMW);
    float lumA0 = max(dot(alb, LUMW), 1e-3);
    // The paint, as Bloodsand would have put it on this skin. Its scorch halo and cooked leather (and the skin-and-blood
    // blend at a stain's edge) multiply the skin, so they take the skin's gain per channel (the new albedo over the peach,
    // at the remap's brightness). Pure blood, raw flesh, the guts, the char's crust, the eyes and hats are neither and are
    // left alone.
    float front0 = smoothstep(-2.0, 1.0, qu.z);
    float gainY = pow(lumA0 / lumP, 0.75);
    vec3 gainC = (alb / PEACH) * (gainY * lumP / lumA0);
    vec3 painted = col * mix(vec3(1.0), gainC, ScorchTone(col, Mouth(qu)));

    // Bloodsand's black eye is not kept as painted (a purple-black wash with the hard, swirled edges of its rings): it is
    // read as where and how heavy the bruise is, and the skin is drawn again under it as a bruise on this skin. Inside an
    // oval round the eyes (Bloodsand's, a little larger), the bruise is the share of its colour in a disc of about a unit
    // (sixteen taps on two rings, which softens its edges into the skin round it), and its weight how dark those taps are;
    // the light on a bruised pixel is the skin's round it (the taps that are skin), or, in the middle of a large bruise,
    // the body's shape lit as the game lights it. The pixel itself is redrawn only if it is skin or bruise, so the eye
    // whites, pupils and blood beside it are untouched.
    vec2 bo = vec2((abs(qu.x) - EYE_X) / 6.6, (qu.y - EYE_Y) / (qu.y < EYE_Y ? 6.6 : 11.0));
    float zone = front0 * Edge(1.0, 1.4, length(bo));
    float bzc = zone * BruiseTone(col);
    float bru = 0.0;
    vec3 colL = col;
    if (zone > 0.0) {
        vec2 t = mg_resolution.zw;
        float rr = clamp(1.5 * ppx, 2.0, 72.0);
        vec2 d1 = vec2(1.0, 0.0);
        vec2 d2 = vec2(0.9238795, 0.3826834);
        float bs = BruiseTone(col);
        float bl = bs * dot(col, LUMW);
        vec3 sc = vec3(0.0);
        float ws = 0.0;
        for (int i = 0; i < 8; i++) {
            vec2 u1 = mg_uv + d1 * rr * t, u2 = mg_uv + d2 * 0.5 * rr * t;
            vec3 c1 = texture2D(mg_scene, u1).rgb;
            vec3 c2 = texture2D(mg_scene, u2).rgb;
            // (Only taps on this body count: the sand beside a worm has the colour of skin.)
            float o1 = Edge(1.5, 3.0, abs(ViewPos(u1).z - P.z)), o2 = Edge(1.5, 3.0, abs(ViewPos(u2).z - P.z));
            float b1 = BruiseTone(c1) * o1, b2 = BruiseTone(c2) * o2;
            bs += b1 + b2;
            bl += b1 * dot(c1, LUMW) + b2 * dot(c2, LUMW);
            float k1 = SkinTone(c1, strict, compat, 0.0, qu.y) * o1, k2 = SkinTone(c2, strict, compat, 0.0, qu.y) * o2;
            sc += c1 * k1 + c2 * k2;
            ws += k1 + k2;
            d1 = vec2(d1.x * 0.7071068 - d1.y * 0.7071068, d1.x * 0.7071068 + d1.y * 0.7071068);
            d2 = vec2(d2.x * 0.7071068 - d2.y * 0.7071068, d2.x * 0.7071068 + d2.y * 0.7071068);
        }
        // The light under the bruise: the skin round it, else the shape lit by sun and sky as vanilla skin.
        vec3 shapeCol = PEACH * (0.32 + 0.6 * clamp(ndl, 0.0, 1.0));
        vec3 skinCol = ws > 1e-3 ? sc / ws : shapeCol;
        vec3 under = mix(shapeCol, skinCol, smoothstep(0.5, 3.0, ws));
        // How heavy: the share of bruise round the pixel, times how much darker than that skin the bruise was painted
        // (Bloodsand's wash is about a third of the skin's brightness, its socket and lid nearly black).
        float cov = bs / 17.0;
        float dark = 1.0 - (bl / max(bs, 1e-3)) / max(dot(under, LUMW), 0.02);
        // (Heavier from across the level, as Bloodsand's own is, so a black eye still reads at the distance the game is played.)
        bru = zone * clamp(mix(1.6, 1.25, smoothstep(4.0, 12.0, ppx)) * cov * smoothstep(0.15, 0.85, dark), 0.0, 1.0);
        colL = mix(col, under, smoothstep(0.02, 0.2, bzc));
        kw = max(kw, smoothstep(0.02, 0.2, bzc));
    }
    if (kw <= 0.0) {
        // Paint that is not skin: blood and Kindjal's acid. The acid's pattern is value noise whose lattice shows as soft
        // squares on a worm seen close; it is smoothed over about two thirds of a unit (eight taps, only of acid on this
        // body), so it reads as a wet chemical burn and not a camouflage print. Both then take a wet highlight from the sun
        // on the body's smooth normal, sharper and brighter than the skin's sheen, broken by a slow noise into wet and
        // drier patches.
        vec2 wet = WetTone(col);
        float wt = max(wet.x, wet.y);
        if (wt > 0.0) {
            if (wet.y > 0.0) {
                vec2 t = mg_resolution.zw;
                float ra = clamp(0.65 * ppx, 1.0, 40.0);
                vec2 d1 = vec2(0.9238795, 0.3826834);
                vec3 sa = col;
                float wa = 1.0;
                for (int i = 0; i < 8; i++) {
                    vec2 u1 = mg_uv + d1 * ra * t;
                    vec3 c1 = texture2D(mg_scene, u1).rgb;
                    float a1 = WetTone(c1).y * Edge(1.5, 3.0, abs(ViewPos(u1).z - P.z));
                    sa += c1 * a1;
                    wa += a1;
                    d1 = vec2(d1.x * 0.7071068 - d1.y * 0.7071068, d1.x * 0.7071068 + d1.y * 0.7071068);
                }
                painted = mix(painted, sa / wa, 0.7 * wet.y);
            }
            vec3 H0 = normalize(V + Ls);
            float nh0 = max(dot(ns, H0), 0.0);
            float lum0 = dot(painted, LUMW);
            float near0 = smoothstep(2.0, 12.0, ppx);
            float glint = (0.45 * pow(nh0, mix(30.0, 80.0, near0)) + 0.08 * pow(nh0, 10.0)) * smoothstep(-0.05, 0.3, ndl)
                        * (0.55 + 0.9 * Noise3(qs * 1.9 + 7.0)) * clamp(p_sheen, 0.0, 1.0) * 1.6;
            painted += vec3(1.0, 0.97, 0.92) * glint * wt * (0.5 + lum0);
        }
        return painted;
    }

    // The light on this pixel, read as if it were bare vanilla skin: per channel the colour over the peach. Its luminance
    // (eY, about 0.9 in full sun, 0.3 to 0.5 in Sunstone's shade) is the shading, its chromaticity (tint) the colour of the
    // light, or of the paint where the pixel is a blend. A pure skin pixel (k near 1) gives up part of its light's colour
    // (lightKeep): a real face in cold shade stays warmer than a peach in the same light, as light scatters under the skin.
    // A blend (k lower) keeps all of it, so the red of a wipe is not pulled toward skin.
    float kl = max(k, smoothstep(0.02, 0.2, bzc));
    float Y = dot(colL, LUMW);
    float eY = Y / lumP;
    vec3 tint = (colL / PEACH) / max(eY, 1e-4);
    // (Only where there is light enough to read: a dark pixel, such as a blend of the skin with Bloodsand's charred crust,
    // keeps its own colour, so char stays brown-black and is not turned a neutral grey.)
    tint = mix(vec3(1.0), tint, mix(1.0, clamp(p_lightKeep, 0.0, 1.0), kl * smoothstep(0.1, 0.25, eY)));
    // Where the sun clips the red the ratios no longer measure the light (a clipped peach reads as green-yellow light), so
    // the tint goes toward white as the red reaches 1.
    tint = mix(tint, vec3(1.0), smoothstep(0.93, 1.0, colL.r) * kl);

    // The face, in the worm's frame (Bloodsand's eye place): the eyes, the cheeks under and outside them, the nose (the
    // snout between and below them), the mouth under it, the forehead (the oily T with the nose), the belly.
    float front = smoothstep(1.0, 4.0, qu.z);
    float eye = front * exp(-Sq((abs(qu.x) - EYE_X) / 2.2) - Sq((qu.y - EYE_Y) / 2.6));
    float cheek = front * exp(-Sq((abs(qu.x) - (EYE_X + 1.8)) / 2.3) - Sq((qu.y - (EYE_Y - 3.2)) / 2.4));
    float nose = front * exp(-Sq(qu.x / 2.0) - Sq((qu.y - (EYE_Y - 1.7)) / 1.6));
    float mouth = front * exp(-Sq(qu.x / 2.8) - Sq((qu.y - (EYE_Y - 4.7)) / 0.8));
    float brow = front * smoothstep(EYE_Y + 2.0, EYE_Y + 4.5, qu.y) * Edge(EYE_Y + 7.0, EYE_Y + 10.0, qu.y) * exp(-Sq(qu.x / 4.0));
    float belly = front * Edge(-10.0, -2.0, qu.y);

    // Detail that shows at the scale it is seen at: each band fades in only where the screen gives it a few pixels a cycle
    // (it never shimmers), so from across the level the blotches and the mottling read, and close up the fine lines,
    // freckles and pores come in as well.
    float lod0 = smoothstep(2.0, 4.0, ppx / 0.8);
    float lod1 = smoothstep(2.5, 5.0, ppx / 2.2);
    float lod2 = smoothstep(2.5, 5.0, ppx / 4.4);
    float mo = clamp(p_mottle, 0.0, 1.0);
    float po = clamp(p_pores, 0.0, 1.0);
    // Melanin, as an absorber (more of it takes more blue than green than red, so the skin goes browner and darker, never
    // green): broad soft blotches (about 6 units), a mottle of about a unit, and small freckles where the finer noise peaks.
    float mel = 0.8 * Fbm(qs * 0.17) + 0.1 + 0.65 * (Noise3(qs * 0.9 + 11.0) - 0.5) * lod0;
    float frk = smoothstep(0.66, 0.8, Noise3(qs * 2.4 + 29.0)) * lod1 * (0.6 + 0.6 * max(cheek, max(nose, brow)));
    mel += 0.45 * frk;
    // Blood under the skin (haemoglobin takes green, then blue): patches of a couple of units, redder, gathered on the
    // cheeks, the nose, the lips and the belly; never much less red than the albedo, which would turn the skin sallow.
    float hb = max(0.65 * (Noise3(qs.zxy * 0.45 + 3.1) - 0.4), -0.05) + 0.6 * cheek + 0.5 * nose + 0.9 * mouth + 0.1 * belly
             + 0.35 * (Noise3(qs * 1.3 + 51.0) - 0.5) * lod0;
    vec3 a = alb * exp(-mo * (mel * vec3(0.24, 0.36, 0.50) + hb * vec3(-0.05, 0.14, 0.10)));
    // (The lips are a little darker as well as redder.)
    a *= 1.0 - 0.12 * mo * mouth;

    // The fine relief: lines, crosshatch, pores, as a height in the worm's frame, differenced along its three axes for a
    // bump on the smooth normal. Its hollows (the lines and the pores) are a little darker and warmer, as a crease is.
    vec3 qr = mat3(0.00, 0.80, 0.60, -0.80, 0.36, -0.48, -0.60, -0.48, 0.64) * qs;
    float poe = po * (1.0 - eye);
    vec3 nb = ns;
    float hc = 0.0;
    if (lod1 > 0.0) {
        const float EPS = 0.035;
        mat3 R = mat3(0.00, 0.80, 0.60, -0.80, 0.36, -0.48, -0.60, -0.48, 0.64);
        hc = Relief(qs, qr, lod1, lod2, poe);
        vec3 g = vec3(Relief(qs + vec3(EPS, 0.0, 0.0), qr + R * vec3(EPS, 0.0, 0.0), lod1, lod2, poe),
                      Relief(qs + vec3(0.0, EPS, 0.0), qr + R * vec3(0.0, EPS, 0.0), lod1, lod2, poe),
                      Relief(qs + vec3(0.0, 0.0, EPS), qr + R * vec3(0.0, 0.0, EPS), lod1, lod2, poe)) - hc;
        g /= EPS;
        // From the worm's frame back to the world (the turn about +Y undone), then to view space; only its part along the
        // surface tilts the normal.
        vec3 gw = vec3(g.x * ch + g.z * sh, g.y, -g.x * sh + g.z * ch);
        vec3 gv = mat3(mg_view) * gw;
        gv -= dot(gv, ns) * ns;
        nb = normalize(ns - 0.035 * (0.5 + po) * gv);
    }
    float cav = clamp(-hc, 0.0, 1.0);
    a *= 1.0 - cav * vec3(0.10, 0.16, 0.18);
    a = max(a * BruiseFilter(bru), vec3(0.0));
    float lumA = max(dot(a, LUMW), 1e-3);

    // The new skin: the light read above on the new albedo. Its brightness follows the albedo's over the peach's, raised to
    // 0.75, so a deep tone is darker than the peach but still has its shading where the scene is dim.
    float yOut = Y * pow(lumA / lumP, 0.75);
    vec3 skin = (a / lumA) * tint * yOut;

    // The relief's shading: how much more or less light the bumped normal takes than the smooth one, from the sun where it
    // is lit and from the sky above where it is not. Light under the skin blurs the relief in the red far more than in the
    // blue, so the lines and pores are soft and warm, not grey scratches.
    float lit = smoothstep(0.35, 0.75, eY) * smoothstep(-0.1, 0.3, ndl);
    vec3 Lm = normalize(mix(mat3(mg_view) * vec3(0.0, 1.0, 0.0), Ls, lit));
    float bsh = clamp((max(dot(nb, Lm), 0.0) + 0.3) / (max(dot(ns, Lm), 0.0) + 0.3), 0.6, 1.25);
    skin *= vec3(1.0) + (bsh - 1.0) * vec3(0.55, 0.85, 1.0);

    // Subsurface scattering: light that enters the skin comes out redder and further on, which is what shade and the
    // terminator (the band where the surface turns away from the sun) show most. There the falloff is softened (the band
    // is lifted), the colour turns red-orange and deeper (shade on skin is a saturated warm brown, never grey), at about
    // the same luminance. It fades in the deepest dark, where there is nothing to scatter. The band is found from the
    // body's shape; the shade from the light read off the pixel (a cast shadow too), except round the eyes, where a black
    // eye darkens the skin as much as shade does and would be read as shade: there only the shape counts. And where the
    // sun is behind the worm, its thin silhouette glows red-orange, as an ear does against the light.
    float ssw = clamp(p_subsurface, 0.0, 1.0) * smoothstep(0.02, 0.1, eY);
    float shade = mix(1.0 - smoothstep(0.25, 0.85, eY), 1.0 - smoothstep(-0.1, 0.5, ndl), zone);
    float band = smoothstep(-0.35, 0.0, ndl) * Edge(0.1, 0.5, ndl) * smoothstep(0.05, 0.2, eY);
    float ys = dot(skin, LUMW);
    skin = max(vec3(ys) + (skin - vec3(ys)) * (1.0 + ssw * (0.35 * shade + 0.25 * band)), vec3(0.0));
    vec3 warm = vec3(1.26, 0.93, 0.74);
    warm /= dot(warm, LUMW);
    skin *= mix(vec3(1.0), warm, ssw * (0.35 * shade + 0.45 * band)) * (1.0 + 0.18 * ssw * band);
    float back = pow(clamp(dot(-V, Ls), 0.0, 1.0), 3.0) * Sq(1.0 - nv);
    skin += ssw * 0.35 * back * a * vec3(1.0, 0.38, 0.18) * max(eY, 0.3) * tint;

    // Sheen: skin is rough and a little oily, so its highlight is soft and broad, with a tighter, brighter core where it is
    // oiliest (the forehead and the nose, then the cheeks) that the pores and lines break up; on the bumped normal, toward
    // the sun, only where the pixel is lit, in the light's colour; the same on every tone, so it reads best on a deep one,
    // as it does in a photograph. Plus a soft grazing sheen (the fine hairs and the oil) toward the silhouette.
    vec3 H = normalize(V + Ls);
    float nh = max(dot(nb, H), 0.0);
    float oil = 0.55 + 0.9 * max(brow, nose) + 0.35 * cheek - 0.3 * eye;
    float broken = clamp(1.0 + 2.0 * hc, 0.15, 1.2);
    float fres = 0.04 + 0.96 * pow(clamp(1.0 - dot(V, H), 0.0, 1.0), 5.0);
    // (Seen from afar the pores and lines are under a pixel and the oily core spreads into the broad lobe, as it does on film.)
    float near = smoothstep(2.0, 12.0, ppx);
    float spec = (0.15 * pow(nh, 7.0) + mix(0.25, 0.6, near) * oil * pow(nh, mix(18.0, 36.0, near)) * broken) * (0.8 + 2.0 * fres) * lit;
    float graze = pow(clamp(1.0 - nv, 0.0, 1.0), 3.0) * smoothstep(0.2, 0.7, eY) * (0.5 + 0.5 * max(ndl, 0.0));
    float shine = clamp(p_sheen, 0.0, 1.0) * (spec + 0.07 * graze) * (1.0 - bru * 0.5);
    skin += shine * mix(vec3(1.0), tint, 0.6) * min(eY, 1.2);

    // Bright skin rolls toward white rather than clipping one channel to a yellow or pink flat: above 0.8 the largest
    // channel is compressed into the last 0.2 and the colour eases toward white, as on film.
    float smx = max(skin.r, max(skin.g, skin.b));
    if (smx > 0.8) {
        float top = 0.8 + 0.2 * (1.0 - exp(-(smx - 0.8) * 5.0));
        skin *= top / smx;
        skin = mix(skin, vec3(top), 0.4 * smoothstep(0.8, 1.6, smx));
    }
    return mix(painted, clamp(skin, 0.0, 1.0), kw);
}

// Chooses the worm a pixel belongs to: the slot with the smallest body-ellipsoid value whose capsule shell the pixel lies on
// (Kindjal's test, which settles two overlapping worms better than the ellipsoid alone). Worm() is long, so it runs once,
// for the slot picked here, and not once per slot (a program that large can link and then draw nothing on some drivers).
void Pick(vec3 P, vec3 centre, vec3 alb, vec3 hs, inout float best, inout vec3 wc, inout vec3 wa, inout vec3 wh) {
    if (dot(centre, centre) < 1e-6) return;
    vec3 d = P - (mg_view * vec4(centre, 1.0)).xyz;
    float slack = hs.z;
    float reach = 17.0 + slack;
    if (dot(d, d) > reach * reach) return;
    vec3 L = d * mat3(mg_view);
    vec3 rv = vec3(L.x, L.y - clamp(L.y, -8.0 - slack, 8.0 + slack), L.z);
    float rl2 = dot(rv, rv);
    float r0 = max(2.4 - slack, 0.0), r1 = 8.1 + slack;
    if (rl2 < r0 * r0 || rl2 > r1 * r1) return;
    float rh = 9.5 + slack, rvt = 16.0 + slack;
    float e = (L.x * L.x + L.z * L.z) / (rh * rh) + L.y * L.y / (rvt * rvt);
    if (e < best) {
        best = e;
        wc = centre;
        wa = alb;
        wh = hs;
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
    float best = 1.0;
    vec3 wc = vec3(0.0), wa = vec3(0.0), wh = vec3(0.0);
    Pick(P, p_worm0, p_worm0b, p_worm0c, best, wc, wa, wh);
    Pick(P, p_worm1, p_worm1b, p_worm1c, best, wc, wa, wh);
    Pick(P, p_worm2, p_worm2b, p_worm2c, best, wc, wa, wh);
    Pick(P, p_worm3, p_worm3b, p_worm3c, best, wc, wa, wh);
    Pick(P, p_worm4, p_worm4b, p_worm4c, best, wc, wa, wh);
    Pick(P, p_worm5, p_worm5b, p_worm5c, best, wc, wa, wh);
    Pick(P, p_worm6, p_worm6b, p_worm6c, best, wc, wa, wh);
    Pick(P, p_worm7, p_worm7b, p_worm7c, best, wc, wa, wh);
    Pick(P, p_worm8, p_worm8b, p_worm8c, best, wc, wa, wh);
    Pick(P, p_worm9, p_worm9b, p_worm9c, best, wc, wa, wh);
    Pick(P, p_worm10, p_worm10b, p_worm10c, best, wc, wa, wh);
    Pick(P, p_worm11, p_worm11b, p_worm11c, best, wc, wa, wh);
    Pick(P, p_worm12, p_worm12b, p_worm12c, best, wc, wa, wh);
    Pick(P, p_worm13, p_worm13b, p_worm13c, best, wc, wa, wh);
    Pick(P, p_worm14, p_worm14b, p_worm14c, best, wc, wa, wh);
    Pick(P, p_worm15, p_worm15b, p_worm15c, best, wc, wa, wh);
    if (best >= 1.0) {
        gl_FragColor = scene;
        return;
    }

    // The cheap colour test before the dear normal: on a worm's shell, a hat, the eyes, blood and the other plugins' paint
    // mostly leave here. A pixel just outside the window but beside skin (a rim) goes on for Feather(), found by a loose test.
    float compat = clamp(p_compat, 0.0, 1.0);
    vec3 L = (P - (mg_view * vec4(wc, 1.0)).xyz) * mat3(mg_view);
    float ch = cos(wh.x), sh = sin(wh.x);
    vec3 qu = vec3(L.x * ch - L.z * sh, L.y, L.x * sh + L.z * ch);
    float strict = max(smoothstep(EYE_Y + 0.5, EYE_Y + 3.5, qu.y), Mouth(qu));
    float k = SkinTone(scene.rgb, strict, compat, 0.0, qu.y);
    vec2 wet = WetTone(scene.rgb);
    if (k < 0.01 && SkinTone(scene.rgb, strict, compat, 1.0, qu.y) < 0.01 && ScorchTone(scene.rgb, Mouth(qu)) < 0.01 && BruiseTone(scene.rgb) < 0.01
        && max(wet.x, wet.y) < 0.01) {
        gl_FragColor = scene;
        return;
    }

    float cover;
    vec3 n = SurfaceNormal(P, (mg_view * vec4(wc, 1.0)).xyz, wh.z, cover);
    float w;
    vec3 col = Worm(P, n, wc, wa, wh, scene.rgb, k, strict, compat, w);
    gl_FragColor = vec4(mix(scene.rgb, col, clamp(p_strength, 0.0, 1.0) * w * cover), scene.a);
}
