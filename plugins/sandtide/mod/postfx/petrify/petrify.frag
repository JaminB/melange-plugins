#version 120
// Sandtide petrify: a cursed worm's tail turns to sand, the cast creeping up from the feet to the waist. Uniform contract (all
// set by Sandtide's Lua, client/petrify.lua, with wum.postfx.setTransient, so the parameters are hidden):
//   p_worm0..p_worm15        vec3  world position of the middle of each worm's body (12 above its feet); (0,0,0) = slot unused
//   p_level0..p_level3       vec4  petrify level 0..1 of slots 4k+0..3 (x, y, z, w): 0 none, 1 the front at the waist
//   p_seed0..p_seed3         vec4  each slot's seed (any value): its own grain, cracks, specks and the shape of the front
//   p_dissolve0..p_dissolve3 vec4  0..1, how much of the cast has washed away under water (0 whole, 1 gone)
//   p_waist                  float height above the feet the front reaches at level 1 (world units)
//   p_strength               float 0..1 overall opacity; 0 or all levels 0 leaves the scene unchanged
//   p_compat, p_tone0..3, p_sunskin  Sunstone, exactly as in Kindjal's acid (see kindjal/mod/postfx/acid/acid.frag):
//                            compat widens the skin colour test for Sunstone's tints, tone is each slot's skin brightness
//                            against the game's peach (the sand is lit by the light read off the skin divided by it), and
//                            the skin Sunstone marks in the scene's alpha (245; 244 seen through a ledge) counts as skin.
// Built-ins used: mg_scene, mg_depth, mg_invProj, mg_view, mg_nearFar, mg_resolution, mg_time.
//
// What counts as the worm: the body is found the way Bloodsand and Kindjal find it (the same capsule shell round the worm's
// vertical axis, the same depth-buffer normal), and a pixel there is the worm when its colour is skin, Sunstone's skin mark,
// blood (Bloodsand paints before this, order 51 to 53) or Kindjal's acid (54). The cast covers all of those below the front,
// so a cursed worm's tail reads as one block of sand whatever happened to it before. Without Sunstone the colour test finds
// the game's peach; with it the mark finds any tone. The sand itself is lit by the light the scene shows on the skin (so it
// takes the level's light, shade and caves), mixed with a key light on the body's smooth shape for form, and Sunstone's
// occlusion and grade (100, 300) then treat it like the rest of the frame.
//
// The look, in the worm's own space (L, the offset from its body centre in world axes, so it never swims):
//   * a grainy tan coat: three octaves of value noise (mottling, clumps, grain) and faint strata;
//   * the creep front: a wobbly line (low noise round the body plus a finer ripple) with a band of darker wet sand just below it;
//   * loose grains: round specks of sand stuck to the skin just above the front, thinning out over about two units;
//   * cracks: the edges of 3D cells (F2 - F1), growing in where a slow noise passes a threshold that falls with the level, so
//     they spread over the cast as it sets; dark lines with a lighter lip, at least a pixel wide at any zoom;
//   * quartz: sparse specks with their own random facet normal that glint toward the camera and twinkle slowly;
//   * dissolve: under water the cast breaks up along a noise threshold, with a dark wet rim on what is left.
// Only a short test runs for every slot to pick the one worm a pixel belongs to, and Worm() runs once (a shader that expands
// a long routine 8 or more times can link and draw nothing on some drivers).
//
// Cost: the client switches the pass on only while a petrified worm is near the screen. A pixel away from every such worm costs
// two fetches, one unprojection and one sphere test per active slot. Only a pixel on a cast worm's shell below its front goes
// on to the normal (four depth fetches) and the cell search (27 cells), a few thousand pixels at normal zoom.
//
// Texture: sand_detail.png (see USE_SAND_TEX below). The crack mask in mod/textures is not used: its cracks are far finer
// than a worm needs and could not spread with the level; the cells here do both.
#define USE_SAND_TEX 1      // 0 = procedural only (then drop texture.sand from effect.ini)
uniform sampler2D mg_scene;
uniform sampler2D mg_depth;
uniform mat4 mg_invProj;
uniform mat4 mg_view;
uniform vec2 mg_nearFar;
uniform vec4 mg_resolution;
uniform float mg_time;
uniform vec3 p_worm0, p_worm1, p_worm2, p_worm3, p_worm4, p_worm5, p_worm6, p_worm7, p_worm8, p_worm9, p_worm10, p_worm11, p_worm12, p_worm13, p_worm14, p_worm15;
uniform vec4 p_level0, p_level1, p_level2, p_level3;
uniform vec4 p_seed0, p_seed1, p_seed2, p_seed3;
uniform vec4 p_dissolve0, p_dissolve1, p_dissolve2, p_dissolve3;
uniform vec4 p_tone0, p_tone1, p_tone2, p_tone3;
uniform float p_sunskin;
uniform float p_compat;
uniform float p_waist;
uniform float p_strength;
#if USE_SAND_TEX
uniform sampler2D t_sand;
#endif
varying vec2 mg_uv;

const float CENTRE_Y = 12.0;      // the body centre's height above the feet
const vec3 BODY = vec3(6.0, 14.0, 6.0);
const float BEHIND_PAINT = 0.7;

float Hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float Hash3(vec3 p) {
    return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453);
}

vec3 Hash33(vec3 p) {
    return fract(sin(vec3(dot(p, vec3(127.1, 311.7, 74.7)), dot(p, vec3(269.5, 183.3, 246.1)), dot(p, vec3(113.5, 271.9, 124.6)))) * 43758.5453);
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

// Kindjal's skin colour test (acid.frag, calibrated in Bloodsand on the game's own frames, compat for Sunstone's tints).
float SkinLimit(float u, float mx) {
    return 0.585 - 0.5 * clamp(u - 0.75, 0.0, 0.25) + 0.085 * smoothstep(0.80, 0.88, mx) + 0.04 * smoothstep(0.93, 0.985, mx);
}

float SkinTone(vec3 c, float compat) {
    float mx = max(c.r, max(c.g, c.b));
    float mn = min(c.r, min(c.g, c.b));
    float rr = max(c.r, 1e-3);
    float u = c.g / rr;
    float v = c.b / rr;
    float vmax = SkinLimit(u, mx) + compat * 0.11 * (1.0 - smoothstep(0.35, 0.8, mx));
    float hole = smoothstep(0.415, 0.44, v) * (1.0 - smoothstep(0.505, 0.525, v)) * smoothstep(0.66, 0.70, u) * (1.0 - smoothstep(0.79, 0.84, u))
               * (1.0 - smoothstep(0.78, 0.86, mx));
    float tn = 1.7320508 * (c.g - c.b) / max(2.0 * c.r - c.g - c.b, 1e-3);
    float tl = mix(0.577, 1.75, smoothstep(0.74, 0.9, mx)) + 0.08 * compat;
    float hue = (1.0 - smoothstep(tl, tl + 0.075, tn)) * smoothstep(0.10, 0.22, tn);
    float sat = 1.0 - smoothstep(0.72 + 0.03 * compat, 0.76 + 0.03 * compat, (mx - mn) / max(mx, 1e-3));
    return smoothstep(0.30, 0.40, u) * (1.0 - smoothstep(1.12, 1.30, u))
         * (1.0 - smoothstep(vmax - 0.025, vmax + 0.025, v)) * (1.0 - hole) * smoothstep(0.16, 0.26, v)
         * smoothstep(0.03 - 0.02 * compat, 0.09 - 0.05 * compat, mx) * smoothstep(0.03, 0.11, (c.g - c.b) / max(mx, 1e-3)) * hue * sat;
}

// On the body shell (which the shape tests already pin to the worm) the strict tone above misses skins that are not the
// game's peach: a pinker grade (Sunstone 2.0, a level's light) has blue near green, past SkinLimit. There a loose test is
// enough: red the strongest channel, some colour, not dark. Eyes and teeth (grey), the sky and grass (blue, green) and
// metal fail it; a brown hat brim passes, but it sits above the front.
float LooseSkin(vec3 c) {
    float mx = max(c.r, max(c.g, c.b));
    float mn = min(c.r, min(c.g, c.b));
    float sat = (mx - mn) / max(mx, 1e-3);
    return smoothstep(0.08, 0.14, mx) * smoothstep(0.10, 0.18, sat) * smoothstep(0.0, 0.04, c.r - c.g) * smoothstep(0.0, 0.04, c.r - c.b);
}

// Bloodsand's blood and wounds (red: green and blue both well under red) and Kindjal's acid (yellow-green with almost no blue).
float Gore(vec3 c) {
    float rr = max(c.r, 1e-3);
    return smoothstep(0.05, 0.11, c.r) * (1.0 - smoothstep(0.32, 0.46, c.g / rr)) * (1.0 - smoothstep(0.38, 0.56, c.b / rr));
}

float AcidCol(vec3 c) {
    float u = c.g / max(c.r, 1e-3);
    return smoothstep(0.96, 1.04, u) * (1.0 - smoothstep(1.65, 1.85, u)) * (1.0 - smoothstep(0.30, 0.40, c.b / max(c.g, 1e-3)))
         * smoothstep(0.03, 0.07, c.g);
}

vec3 ViewPos(vec2 uv) {
    vec4 v = mg_invProj * vec4(vec3(uv, texture2D(mg_depth, uv).r) * 2.0 - 1.0, 1.0);
    return v.xyz / v.w;
}

float BodyE(vec3 Pv, vec3 Cv) {
    vec3 L = (Pv - Cv) * mat3(mg_view);
    return (L.x * L.x + L.z * L.z) / (9.5 * 9.5) + L.y * L.y / (16.0 * 16.0);
}

// The surface normal from the depth of the four neighbours (Kindjal's acid.frag, see there), with cover for the silhouette.
vec3 SurfaceNormal(vec3 P, vec3 Cv, out float cover) {
    vec2 t = mg_resolution.zw;
    vec3 Pr = ViewPos(mg_uv + vec2(t.x, 0.0));
    vec3 Pl = ViewPos(mg_uv - vec2(t.x, 0.0));
    vec3 Pu = ViewPos(mg_uv + vec2(0.0, t.y));
    vec3 Pd = ViewPos(mg_uv - vec2(0.0, t.y));
    float jump = 0.02 * -P.z + 0.3;
    vec4 dz = vec4(Pr.z, Pl.z, Pu.z, Pd.z) - P.z;
    vec4 outside = max(step(0.95, vec4(BodyE(Pr, Cv), BodyE(Pl, Cv), BodyE(Pu, Cv), BodyE(Pd, Cv))), step(8.0, -dz));
    cover = clamp(1.0 - 0.45 * dot(outside, step(jump, -dz)), 0.0, 1.0);
    vec3 dx = abs(dz.x) < abs(dz.y) ? Pr - P : P - Pl;
    vec3 dy = abs(dz.z) < abs(dz.w) ? Pu - P : P - Pd;
    vec3 n = cross(dx, dy);
    float nl = length(n);
    n = (nl < 1e-9 || min(abs(dz.x), abs(dz.y)) > jump || min(abs(dz.z), abs(dz.w)) > jump) ? -normalize(P) : n / nl;
    return dot(n, P) > 0.0 ? -n : n;
}

// Component k (0..3) of a vec4 and slot i's value from four packed vec4s.
float Lane(vec4 t, float k) {
    return k < 0.5 ? t.x : (k < 1.5 ? t.y : (k < 2.5 ? t.z : t.w));
}

float SlotVal(vec4 a, vec4 b, vec4 c, vec4 d, float i) {
    vec4 t = i < 3.5 ? a : (i < 7.5 ? b : (i < 11.5 ? c : d));
    return Lane(t, i - 4.0 * floor(i / 4.0 + 0.01));
}

float sunSkin = 0.0;
float behind = 0.0;
float rayT = 1e9;
float tailWorm = 0.0;      // the colour test for the tail where Sunstone marks the skin (mark, blood, acid), set by main()
float slotTone = 1.0;       // the picked slot's skin brightness against the peach where Sunstone marks the skin, else 1

// The cell edge distance (F2 - F1) of 3D cells at q: 0 on an edge between two cells.
float CellEdge(vec3 q) {
    vec3 i = floor(q);
    vec3 f = fract(q);
    float f1 = 8.0, f2 = 8.0;
    for (int z = -1; z <= 1; z++) {
        for (int y = -1; y <= 1; y++) {
            for (int x = -1; x <= 1; x++) {
                vec3 g = vec3(float(x), float(y), float(z));
                vec3 r = g + Hash33(i + g) * 0.85 + 0.075 - f;
                float dd = dot(r, r);
                if (dd < f1) {
                    f2 = f1;
                    f1 = dd;
                } else if (dd < f2) {
                    f2 = dd;
                }
            }
        }
    }
    return sqrt(f2) - sqrt(f1);
}

// Turns one worm's tail to sand in col. P is the pixel's view-space position, n its surface normal, lv the level, sd the seed,
// dz the dissolve, worm how much the pixel's colour is the worm (skin, mark, blood or acid).
void Worm(vec3 P, vec3 n, vec3 centre, float lv, float sd, float dz, float worm, float bodyWorm, inout vec3 col) {
    vec3 d = P - (mg_view * vec4(centre, 1.0)).xyz;
    vec3 L = d * mat3(mg_view);
    float hy = L.y + CENTRE_Y;
    float waist = clamp(p_waist, 4.0, 20.0);
    float H = lv * (waist + 1.2) - 1.2;
    if (hy > H + 3.0) return;
    vec3 nWorld = n * mat3(mg_view);
    // Pixels per world unit at this depth, for lines and specks that stay at least a pixel wide.
    float ppx = 0.5 * mg_resolution.y / (abs(mg_invProj[1][1]) * max(-P.z, 1.0));
    // The body: the upright ellipsoid, its capsule shell, facing away from the axis (Kindjal's tests), and the worm standing
    // clear of what is behind it (Kindjal's test, more lenient: the feet stand on the ground, where the depth beside them
    // hardly falls away, and the facing test already keeps the ground out).
    float body = 0.0;
    float e = (L.x * L.x + L.z * L.z) / (9.5 * 9.5) + L.y * L.y / (16.0 * 16.0);
    vec3 rv = vec3(L.x, L.y - clamp(L.y, -8.0, 8.0), L.z);
    float rl = length(rv);
    if (e < 1.0 && rl > 1e-4) {
        float shell = smoothstep(2.4, 3.6, rl) * (1.0 - smoothstep(6.9, 8.1, rl));
        float upright = 1.0 - smoothstep(0.55, 0.85, abs(nWorld.y)) * (1.0 - smoothstep(0.0, 2.0, abs(rv.y)));
        body = (1.0 - smoothstep(0.85, 1.0, e)) * shell * upright * smoothstep(0.1, 0.5, dot(nWorld, rv / rl));
        // Not what stands behind the worm: a wall or slope there lies past the body's far side. (Kindjal's test, the
        // depth 7.6 units to either side, failed on a cursed worm: the mound, a fat torso or a barrel beside it kept
        // the step from showing, and the cast never reached the body.)
        if (behind < 0.5) body *= 1.0 - smoothstep(8.0, 11.0, -d.z);
    }
    // The tail: the game's worm rests on a fat tail that curls out to one side of the body, well past the capsule (measured up
    // to about 18 units from the reported position in some idle poses, about 7 high). Low down round the feet, the colour alone says what is the worm; the ground there
    // is kept out by its height (ground facing up must be at least about 2 units above the feet to count, which only the top of
    // the tail is). Where Sunstone marks the skin, only the mark, blood and acid count there (sand on the ground can pass the
    // colour test).
    float rh = length(L.xz);
    float tail = (1.0 - smoothstep(19.0, 22.0, rh)) * (1.0 - smoothstep(7.0, 9.0, hy)) * smoothstep(-0.2, 0.3, hy - 2.2 * smoothstep(0.35, 0.8, nWorld.y))
               * (p_sunskin > 0.5 ? tailWorm : bodyWorm);
    float mask = max(body * bodyWorm, tail);
    if (mask <= 0.0) return;

    vec3 so = vec3(Hash(vec2(sd, 3.1)), Hash(vec2(sd, 7.7)), Hash(vec2(sd, 11.3))) * 61.0;
    // The creep front: a slow wobble round the body and a finer ripple, about +-1.4 units in all.
    float wf = Noise3(vec3(L.x * 0.3, hy * 0.04, L.z * 0.3) + so);
    float wr = Noise3(L * 1.25 + so + 3.7);
    float t = H + 2.2 * (wf - 0.5) + 0.7 * (wr - 0.5) - hy;       // how deep under the front, in units (negative above it)
    float cover = smoothstep(-0.1, 0.18, t);
    // Under water the cast washes away along a noise threshold; dz 0 keeps it all, 1 none.
    float nd = 0.7 * Noise3(L * 0.55 + so + 11.0) + 0.3 * wr;
    float dd = dz * 1.25 - 0.12;
    float keep = smoothstep(dd - 0.035, dd + 0.035, nd);
    float dedge = dz > 0.001 ? keep * (1.0 - smoothstep(0.0, 0.12, nd - dd)) : 0.0;
    // Loose grains stuck to the skin above the front.
    vec3 gq = L * 1.9 + so + 7.0;
    vec3 gc = floor(gq);
    float dens = (1.0 - smoothstep(0.0, 2.4, -t)) * step(t, 0.0) * smoothstep(0.0, 0.12, lv);
    vec3 gp = fract(gq) - 0.5 - (Hash33(gc + 0.7) - 0.5) * 0.5;
    float grain = step(1.0 - 0.6 * dens, Hash3(gc)) * (1.0 - smoothstep(0.17, 0.17 + 1.9 / ppx, length(gp))) * keep;
    if (cover * keep <= 0.0 && grain <= 0.0) return;

    // Albedo: mottled tan, clumps, fine grain, faint strata.
    float n1 = Noise3(L * 0.45 + so);
    float n2 = Noise3(L * 1.7 + so + 1.9);
    float n3 = Noise3(L * 4.6 + so + 4.1);
    vec3 sand = mix(vec3(0.76, 0.55, 0.31), vec3(1.0, 0.83, 0.55), smoothstep(0.2, 0.8, n1));
    sand *= 0.82 + 0.2 * n2 + 0.2 * n3 + 0.12 * (Noise3(L * 9.0 + so) - 0.5);
    // Dark mineral grains here and there.
    vec3 mq = L * 3.4 + so + 17.0;
    float mh = Hash3(floor(mq));
    sand *= 1.0 - 0.3 * step(0.9, mh) * (1.0 - smoothstep(0.12, 0.12 + 3.4 / ppx, length(fract(mq) - 0.5)));
    sand *= 1.0 + 0.05 * sin(hy * 2.4 + n1 * 4.0);
#if USE_SAND_TEX
    // Wind-rippled sand from the texture (sand_detail.png, made by tools/make_petrify_tex.py from mod/textures/sand_albedo.png,
    // mean luminance 0.5), wrapped three times round the worm's axis and once per 12 units of height, as a brightness detail.
    // Post-FX textures have no mipmaps, so it fades in only where a texel is about a pixel or more (close shots, the tour).
    vec3 tx = texture2D(t_sand, vec2(atan(L.z, L.x) * (3.0 / 6.2831853), hy * (1.0 / 12.0)) + so.xy).rgb * 2.0;
    sand *= mix(vec3(1.0), tx, 0.6 * smoothstep(6.0, 12.0, ppx));
#endif

    // Light: what the scene shows on the skin (divided by the skin's own brightness, so the sand keeps the level's light), mixed
    // with a key light on the body's smooth shape, darker where the tail meets the ground.
    vec3 nE = mat3(mg_view) * normalize(vec3(L.x / (9.5 * 9.5), L.y / (16.0 * 16.0), L.z / (9.5 * 9.5)) + vec3(0.0, 1e-6, 0.0));
    vec3 ns = normalize(mix(n, nE, 0.8));
    vec3 Kv = normalize(mat3(mg_view) * vec3(0.35, 0.85, 0.25));
    vec3 Vv = normalize(-P);
    vec3 Hv = normalize(Kv + Vv);
    float mx = max(col.r, max(col.g, col.b));
    float lamb = 0.42 + 0.7 * max(dot(ns, Kv), 0.0);
    float light = mix(clamp(mx / (0.86 * slotTone), 0.22, 1.4), lamb, 0.35);
    light *= mix(0.7, 1.0, smoothstep(0.0, 2.5, hy));

    // The wet band just under the front (and on the rim of what the water leaves), darker and glossy.
    float wet = max(cover * (1.0 - smoothstep(0.1, 1.3, t)), dedge);
    sand = mix(sand, sand * vec3(0.6, 0.5, 0.4), 0.8 * wet);

    // Cracks: cell edges where a slow noise passes a threshold that falls as the level rises.
    float line = 0.0, lip = 0.0;
    float crackAmt = smoothstep(0.25, 1.0, lv) * smoothstep(0.8, 3.0, t);
    if (crackAmt > 0.0 && cover > 0.0) {
        float on = smoothstep(-0.06, 0.06, Noise3(L * 0.22 + so + 21.0) - mix(0.86, 0.42, crackAmt));
        if (on > 0.0) {
            float edge = CellEdge(L * 0.3 + so);
            float wpx = 0.3 / ppx;
            float w = max(0.012 + 0.025 * crackAmt, 0.5 * wpx);
            // Some cell edges stay shut, so the lines run and branch like a fracture instead of closing every cell.
            on *= smoothstep(0.38, 0.52, Noise3(L * 0.8 + so + 31.0));
            line = (1.0 - smoothstep(w, w + wpx + 0.01, edge)) * on;
            lip = max((1.0 - smoothstep(w + wpx, w + 2.5 * wpx + 0.04, edge)) * on - line, 0.0);
        }
    }
    sand *= 1.0 + 0.18 * lip;
    sand = mix(sand, sand * vec3(0.34, 0.27, 0.2), line);

    vec3 lit = sand * light;
    lit += vec3(1.0, 0.95, 0.85) * pow(max(dot(ns, Hv), 0.0), 40.0) * 0.3 * wet * light;

    // Quartz: sparse specks on the dry sand with their own facet normal, glinting toward the camera and twinkling slowly
    // (the phase wraps every 36 s, so mg_time's size never matters).
    vec3 qq = L * 2.2 + so + 13.0;
    vec3 qc = floor(qq);
    float qh = Hash3(qc);
    if (qh > 0.95) {
        vec3 qr = Hash33(qc + 1.3);
        float sp = 1.0 - smoothstep(0.1, 0.1 + 0.9 * 2.2 / ppx, length(fract(qq) - 0.2 - 0.6 * qr));
        vec3 nq = normalize(ns + (Hash33(qc + 4.7) - 0.5) * 1.6);
        float g = pow(max(dot(nq, Hv), 0.0), 28.0);
        float tw = 0.55 + 0.45 * sin(fract(mg_time * (1.0 / 36.0)) * 6.2831853 * 24.0 + qh * 90.0);
        lit += vec3(1.0, 0.96, 0.88) * sp * (0.22 * light + 2.0 * g * tw) * (1.0 - wet) * (1.0 - line);
    }

    float a = cover * keep;
    vec3 outc = mix(col, lit, a);
    outc = mix(outc, sand * light * 0.92, grain * (1.0 - a) * 0.9);
    col = mix(col, outc, mask);
}

// Chooses the worm a pixel belongs to (as in Kindjal's acid). A slot with no level or no position is skipped.
void Pick(vec3 P, vec3 centre, float lv, float slotIdx, inout float best, inout vec3 wc, inout float wslot) {
    if (lv <= 0.0 || dot(centre, centre) < 1e-6) return;
    vec3 Cv = (mg_view * vec4(centre, 1.0)).xyz;
    if (behind > 0.5) {
        vec3 o = (-Cv * mat3(mg_view)) / BODY;
        vec3 v = (normalize(P) * mat3(mg_view)) / BODY;
        float qa = dot(v, v), qb = dot(o, v), disc = qb * qb - qa * (dot(o, o) - 1.0);
        float s = sqrt(max(disc, 0.0)), lp = length(P);
        float t = max((-qb - s) / qa, lp);
        if (disc <= 0.0 || (-qb + s) / qa < lp || t >= rayT) return;
        rayT = t;
        best = 0.0;
        wc = centre;
        wslot = slotIdx;
        return;
    }
    vec3 d = P - Cv;
    // Early outs, in order of cost: too far from the body and its tail; then on neither the capsule shell (2.4 to 8.1 units
    // from the vertical axis) nor the tail's low disc round the feet (see Worm). A pixel on the shell ranks by the body
    // ellipsoid's equation, one only on the tail after every shell (0.98).
    if (dot(d, d) > 25.5 * 25.5) return;
    vec3 L = d * mat3(mg_view);
    vec3 rv = vec3(L.x, L.y - clamp(L.y, -8.0, 8.0), L.z);
    float rl2 = dot(rv, rv);
    float e = (L.x * L.x + L.z * L.z) / (9.5 * 9.5) + L.y * L.y / (16.0 * 16.0);
    bool onBody = rl2 >= 2.4 * 2.4 && rl2 <= 8.1 * 8.1 && e < 1.0;
    float hy = L.y + CENTRE_Y;
    bool onTail = hy > -1.0 && hy < 9.0 && dot(L.xz, L.xz) < 22.0 * 22.0;
    if (!onBody && !onTail) return;
    if (!onBody) e = 0.98;
    if (e < best) {
        best = e;
        wc = centre;
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
    float best = 1.0, wslot = 0.0;
    vec3 wc = vec3(0.0);
    behind = abs(scene.a * 255.0 - 244.0) < 0.5 ? 1.0 : 0.0;
    Pick(P, p_worm0, p_level0.x, 0.0, best, wc, wslot);
    Pick(P, p_worm1, p_level0.y, 1.0, best, wc, wslot);
    Pick(P, p_worm2, p_level0.z, 2.0, best, wc, wslot);
    Pick(P, p_worm3, p_level0.w, 3.0, best, wc, wslot);
    Pick(P, p_worm4, p_level1.x, 4.0, best, wc, wslot);
    Pick(P, p_worm5, p_level1.y, 5.0, best, wc, wslot);
    Pick(P, p_worm6, p_level1.z, 6.0, best, wc, wslot);
    Pick(P, p_worm7, p_level1.w, 7.0, best, wc, wslot);
    Pick(P, p_worm8, p_level2.x, 8.0, best, wc, wslot);
    Pick(P, p_worm9, p_level2.y, 9.0, best, wc, wslot);
    Pick(P, p_worm10, p_level2.z, 10.0, best, wc, wslot);
    Pick(P, p_worm11, p_level2.w, 11.0, best, wc, wslot);
    Pick(P, p_worm12, p_level3.x, 12.0, best, wc, wslot);
    Pick(P, p_worm13, p_level3.y, 13.0, best, wc, wslot);
    Pick(P, p_worm14, p_level3.z, 14.0, best, wc, wslot);
    Pick(P, p_worm15, p_level3.w, 15.0, best, wc, wslot);
    if (best >= 1.0) {
        gl_FragColor = scene;
        return;
    }
    // The cheap colour test before the dear normal: hats, eyes, weapons and the like leave here.
    sunSkin = abs(scene.a * 255.0 - 245.0) < 0.5 || behind > 0.5 ? smoothstep(0.30, 0.40, scene.g / max(scene.r, 1e-3)) : 0.0;
    float gore = max(Gore(scene.rgb), AcidCol(scene.rgb));
    tailWorm = max(sunSkin, gore);
    float worm = max(SkinTone(scene.rgb, clamp(p_compat, 0.0, 1.0)), tailWorm);
    float bodyWorm = max(worm, LooseSkin(scene.rgb));
    if (bodyWorm < 0.01) {
        gl_FragColor = scene;
        return;
    }
    float cover = BEHIND_PAINT;
    vec3 n;
    if (behind > 0.5) {
        P = normalize(P) * rayT;
        vec3 L = (P - (mg_view * vec4(wc, 1.0)).xyz) * mat3(mg_view);
        n = normalize(mat3(mg_view) * (L / (BODY * BODY)));
    } else {
        n = SurfaceNormal(P, (mg_view * vec4(wc, 1.0)).xyz, cover);
    }
    float tv = SlotVal(p_tone0, p_tone1, p_tone2, p_tone3, wslot);
    slotTone = mix(1.0, tv > 0.02 ? tv : 1.0, sunSkin);
    vec3 col = scene.rgb;
    Worm(P, n, wc, clamp(SlotVal(p_level0, p_level1, p_level2, p_level3, wslot), 0.0, 1.0),
         SlotVal(p_seed0, p_seed1, p_seed2, p_seed3, wslot) + wslot * 37.0,
         clamp(SlotVal(p_dissolve0, p_dissolve1, p_dissolve2, p_dissolve3, wslot), 0.0, 1.0), worm, bodyWorm, col);
    gl_FragColor = vec4(mix(scene.rgb, col, p_strength * cover), scene.a);
}
