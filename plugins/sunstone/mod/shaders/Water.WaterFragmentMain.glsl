#version 130
// Sunstone water, built on the game's own water terms: refraction of the scene below with depth-based absorption,
// a Fresnel blend toward a sky-tinted reflection, the game's glints with a sun sparkle, and broken foam where the
// water is shallow. Reads copies of the scene taken just before the water draws.
uniform sampler2D texture0;   // the theme's water colour ramp
uniform sampler2D texture1;   // wave normals
uniform sampler2D texture2;   // the theme's environment map
uniform mat4 combinedWaterParams;
uniform float pausedTime;
uniform mat4 mg_view;
uniform mat4 mg_proj;
uniform sampler2D mg_depth;
uniform sampler2D mg_scene;
uniform vec2 mg_nearFar;
uniform vec2 mg_renderScale;
// The landscape's sun (eye space) and colour, fed from the landscape programs.
uniform vec3 globalLightDir;
uniform vec3 globalDiffuse;

uniform float sunstoneWater;          // 1 Sunstone; 10 water depth, 11 foam, 12 glint and flecks, 13 reflections, 14 caustics
uniform vec3 sunstoneWaterDeep;       // deep-water tint, multiplied by the theme's own water colour
uniform vec3 sunstoneWaterShallow;    // tint of the light that crosses shallow water
uniform float sunstoneWaterClarity;   // distance (world units) over which the light is absorbed
uniform float sunstoneWaterReflect;   // reflection strength
uniform float sunstoneWaterWaves;     // wave normal strength
uniform float sunstoneWaterRefract;   // refraction offset (fraction of the screen)
uniform float sunstoneWaterGlint;     // sun glint strength
uniform float sunstoneWaterFoam;      // shore foam strength
uniform float sunstoneWaterFoamWidth; // water depth (world units) the foam reaches
uniform float sunstoneWaterRich;      // 0 the game's own brightness; 1 a deeper, more saturated sea with white glints
uniform float sunstoneWaterLift;      // how far deep water takes the brightness of the game's blended water
uniform float sunstoneSplit;          // pixels left of this x draw the game's own water (comparisons)
uniform float sunstoneWaterSsr;          // strength of the screen-space reflection of the scenery
uniform float sunstoneWaterSsrCap;       // most the scenery reflection may cover the sea
uniform float sunstoneWaterSsrRange;     // longest reflected ray (world units)
uniform float sunstoneWaterSsrThickness; // depth (fraction of the distance) a surface is assumed to have
uniform float sunstoneWaterCaustics;     // caustic light on the sea floor in the shallows
uniform float sunstoneWaterCausticScale; // caustic cells per water texture repeat
uniform float sunstoneWaterCrest;        // turquoise lift on crests facing the sun
uniform float sunstoneWaterDispersion;   // red/blue split of the refraction (pixels)
uniform float sunstoneWaterSmooth;       // blur of the colour ramp lookup (ramp texels), against contour lines

float Hash(vec2 p) {
    p = fract(p * vec2(0.1031, 0.1030));
    p += dot(p, p.yx + 33.33);
    return fract((p.x + p.y) * p.x);
}

float Noise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(Hash(i), Hash(i + vec2(1, 0)), u.x), mix(Hash(i + vec2(0, 1)), Hash(i + vec2(1, 1)), u.x), u.y);
}

float Fbm(vec2 p) {
    float s = 0.0, a = 0.5;
    for (int i = 0; i < 4; ++i) {
        s += a * Noise(p);
        p = mat2(1.6, 1.2, -1.2, 1.6) * p;
        a *= 0.5;
    }
    return s;
}

float Linear(float d) {
    float n = mg_nearFar.x, f = mg_nearFar.y;
    return 2.0 * n * f / (f + n - (d * 2.0 - 1.0) * (f - n));
}

// Where a world direction (infinitely far away) lands on screen; off-screen when behind the camera.
vec2 ScreenOf(vec3 dir) {
    vec4 c = mg_proj * vec4(mat3(mg_view) * dir, 0.0);
    return c.w > 0.0 ? c.xy / c.w * 0.5 + 0.5 : vec2(-1.0);
}

// 1 where the scene at uv is the sky (far away), fading out toward the screen edges.
float SkyWeight(vec2 uv) {
    vec2 e = min(uv, 1.0 - uv);
    if (min(e.x, e.y) <= 0.0) return 0.0;
    float sky = step(mg_nearFar.y * 0.4, Linear(texture2D(mg_depth, uv).r));
    return sky * smoothstep(0.0, 0.04, min(e.x, e.y));
}

vec2 Slope(vec2 uv) {
    vec3 s = texture2D(texture1, uv).xyz * 2.0 - 1.0;
    return s.xy / max(s.z, 0.2);
}

// The game's own water, as its Cg program draws it: the colour ramp under its normals, the environment
// reflection and the white glints.
vec3 MapNormal(vec2 uv) { return normalize(texture2D(texture1, uv).rgb * 2.0 - 1.0); }

vec3 Env(vec3 c) {
    c = normalize(c);
    float m = max(max(c.x, c.y), c.z);
    vec2 f = m == c.x ? c.yz : (m == c.y ? c.xz : c.xy);
    return texture2D(texture2, f * 0.5 + 0.5).rgb;
}

// Glints are reflected light: on a rich sea they cover the colour below instead of adding to it, so they stay white
// over sandy shallows rather than turning cream.
vec3 Glint(vec3 col, vec3 add) {
    float cover = clamp(max(max(add.r, add.g), add.b), 0.0, 1.0) * sunstoneWaterRich;
    return col * (1.0 - cover) + add;
}

// c with the hue of ref: c's luma and chroma, ref's chroma direction. Near-grey refs have no hue to keep.
vec3 KeepHue(vec3 c, vec3 ref) {
    const vec3 w = vec3(0.299, 0.587, 0.114);
    vec3 dr = ref - dot(ref, w);
    float lr = length(dr);
    vec3 kept = max(dot(c, w) + dr * (length(c - dot(c, w)) / max(lr, 1e-4)), 0.0);
    return mix(c, kept, smoothstep(0.004, 0.02, lr));
}

// Eye-space position of the screen point uv at linear depth z.
vec3 ViewAt(vec2 uv, float z) {
    return vec3((uv * 2.0 - 1.0 + vec2(mg_proj[2][0], mg_proj[2][1])) * z / vec2(mg_proj[0][0], mg_proj[1][1]), -z);
}

// The scenery drawn before the sea, seen along the eye-space ray p + d * s: 14 even steps across the screen, then
// 4 bisections. Rays fade out toward the screen edges and the end of their range; hits on the sky, on anything below
// the water plane (the sea floor) and behind a surface thicker than assumed are dropped. Weight in w.
vec4 Reflection(vec3 p, vec3 d, vec3 up) {
    float len = sunstoneWaterSsrRange;
    if (d.z > 0.0) len = min(len, (-p.z - 2.0 * mg_nearFar.x) / d.z);
    if (len <= 1.0) return vec4(0.0);
    vec4 c0 = mg_proj * vec4(p, 1.0);
    vec4 c1 = mg_proj * vec4(p + d * len, 1.0);
    float k0 = 1.0 / c0.w, k1 = 1.0 / c1.w;
    vec2 s0 = c0.xy * k0 * 0.5 + 0.5;
    vec2 ds = c1.xy * k1 * 0.5 + 0.5 - s0;
    float end = 1.0;
    if (abs(ds.x) > 1e-6) end = min(end, ((ds.x > 0.0 ? 1.0 : 0.0) - s0.x) / ds.x);
    if (abs(ds.y) > 1e-6) end = min(end, ((ds.y > 0.0 ? 1.0 : 0.0) - s0.y) / ds.y);
    if (end <= 0.0) return vec4(0.0);

    float lo = 0.0, hi = -1.0, thick = 0.0;
    float prevZ = c0.w;
    for (int i = 1; i <= 14; ++i) {
        float s = end * float(i) / 14.0;
        float rz = 1.0 / mix(k0, k1, s);
        float sz = Linear(textureLod(mg_depth, s0 + ds * s, 0.0).r);
        thick = abs(rz - prevZ) + rz * sunstoneWaterSsrThickness;
        if (rz > sz && rz - sz < thick) {
            hi = s;
            break;
        }
        lo = s;
        prevZ = rz;
    }
    if (hi < 0.0) return vec4(0.0);
    for (int i = 0; i < 4; ++i) {
        float m = 0.5 * (lo + hi);
        if (1.0 / mix(k0, k1, m) > Linear(textureLod(mg_depth, s0 + ds * m, 0.0).r)) hi = m;
        else lo = m;
    }

    vec2 uv = s0 + ds * hi;
    float rz = 1.0 / mix(k0, k1, hi);
    float sz = Linear(textureLod(mg_depth, uv, 0.0).r);
    vec2 e = min(uv, 1.0 - uv);
    float w = smoothstep(0.0, 0.06, min(e.x, e.y));
    // Fraction of the ray's eye-space length travelled.
    w *= 1.0 - smoothstep(0.6, 1.0, hi * k1 / mix(k0, k1, hi));
    w *= 1.0 - smoothstep(0.5, 1.0, abs(rz - sz) / max(thick, 1e-3));
    w *= step(sz, mg_nearFar.y * 0.4);
    w *= smoothstep(0.5, 3.0, dot(ViewAt(uv, sz) - p, up));
    // Rays turning back toward the camera meet the backs of things the depth copy does not have.
    w *= 1.0 - smoothstep(0.2, 0.6, d.z);
    return vec4(textureLod(mg_scene, uv, 0.0).rgb, w);
}

// Light focused by the waves onto the sea floor: the edges of drifting cells, bright where neighbouring cells meet.
float Caustic(vec2 p, float t) {
    p += vec2(Noise(p * 0.5 + t * 0.07), Noise(p * 0.5 - t * 0.05 + 19.1)) * 0.6;
    vec2 i = floor(p), f = fract(p);
    float d1 = 8.0, d2 = 8.0;
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            vec2 g = vec2(float(x), float(y));
            vec2 h = vec2(Hash(i + g), Hash(i + g + 17.3));
            vec2 o = g + 0.5 + 0.35 * sin(t * 0.6 + 6.2831853 * h) - f;
            float d = dot(o, o);
            if (d < d1) {
                d2 = d1;
                d1 = d;
            } else if (d < d2) {
                d2 = d;
            }
        }
    }
    float edge = 1.0 - smoothstep(0.0, 0.22, sqrt(d2) - sqrt(d1));
    return edge * edge;
}

// The colour ramp at c, blurred along its diagonal over r texels.
vec3 Ramp(vec2 c, float r) {
    if (r <= 0.0) return texture2D(texture0, c).rgb;
    vec2 o = vec2(r) / vec2(textureSize(texture0, 0));
    return (texture2D(texture0, c - o).rgb + texture2D(texture0, c - 0.5 * o).rgb + texture2D(texture0, c).rgb +
            texture2D(texture0, c + 0.5 * o).rgb + texture2D(texture0, c + o).rgb) * 0.2;
}

vec3 GameWater(vec2 uv, float t, float r, out float spec) {
    float st = t * 0.5;
    vec3 nm = normalize(MapNormal(uv * 5.0 + st * vec2(-0.3, 0.6)) * vec3(0.2, 0.2, 0.0) +
                        MapNormal(uv * -0.2 + st * vec2(0.0, 0.2)) + MapNormal(uv * -0.75 + st * vec2(-0.1, -0.2)));
    mat4 p = combinedWaterParams;
    vec3 diffuse = Ramp(nm.gg * 0.25, r) - Ramp(nm.bb * 2.0, r).rrr * p[3].w;
    vec3 refl = pow(Env(nm * p[2].xyz), vec3(p[0].x)) * p[0].y;
    spec = clamp(pow(Env(nm * p[1].xyz).r, p[0].z) * p[3].x, 0.0, 1.0);
    return diffuse + refl;
}

void main() {
    vec3 eye = gl_TexCoord[1].xyz;
    float dist = length(eye);
    vec3 v = -eye / dist;
    float t = pausedTime;
    if (gl_FragCoord.x < sunstoneSplit) {
        float s;
        gl_FragColor = vec4(GameWater(gl_TexCoord[0].xy, t, 0.0, s) + s, combinedWaterParams[3].z);
        return;
    }

    // Swell and fine ripples. Each layer fades out where its texels shrink below a pixel, where it would only
    // shimmer; distant water also calms down.
    vec2 uv0 = gl_TexCoord[0].xy;
    float texels = length(fwidth(uv0)) * 256.0 * max(mg_renderScale.x, 1.0);
    float far = smoothstep(800.0, 6000.0, dist);
    float detail = 1.0 - smoothstep(2.0, 8.0, texels * 3.1);
    float broad = 1.0 - smoothstep(3.0, 12.0, texels * 0.5);
    vec2 swell = Slope(uv0 * 0.5 + t * vec2(0.021, 0.013)) + Slope(uv0 * -1.1 + t * vec2(-0.017, 0.029)) * 0.6;
    vec2 ripple = Slope(uv0 * 3.1 + t * vec2(0.05, -0.035)) + Slope(uv0 * -5.3 + t * vec2(-0.04, -0.06)) * 0.5;
    vec2 chop = Slope(uv0 * 1.4 + t * vec2(-0.03, 0.04));
    float mid = 1.0 - smoothstep(2.0, 8.0, texels * 1.4);
    // A slow, rotated long swell and a noise that varies the wave height across the sea, so the far water does
    // not show the normal map's repeat.
    float macro = Fbm(uv0 * 0.045 + t * vec2(0.0021, -0.0017));
    vec2 lazy = Slope(mat2(0.8, -0.6, 0.6, 0.8) * uv0 * 0.17 + t * vec2(0.006, 0.009));
    swell = swell * (0.45 + 1.1 * macro) + lazy * 0.6;
    vec2 slope = (swell * mix(0.25, 1.0, broad) + chop * 0.35 * mid + ripple * 0.45 * detail) * sunstoneWaterWaves;
    vec3 n = normalize(vec3(slope.x, 1.0, slope.y));

    vec2 size = vec2(textureSize(mg_scene, 0));
    vec2 uv = gl_FragCoord.xy / size;
    float zWater = Linear(gl_FragCoord.z);
    float raw = texture2D(mg_depth, uv).r;
    // Distance the view ray travels through the water before it hits the ground; past the sky dome it is open sea.
    float sceneZ = Linear(raw);
    float through = (raw >= 0.99999 || raw <= 0.0 || sceneZ > mg_nearFar.y * 0.4) ? 1e5 : max(sceneZ - zWater, 0.0) * dist / zWater;
    float depth = through * max(v.y, 0.08);

    vec2 offset = n.xz * sunstoneWaterRefract * clamp(through / 40.0, 0.0, 1.0) * (1.0 - far);
    vec2 ruv = uv + offset;
    float rraw = texture2D(mg_depth, ruv).r;
    bool front = Linear(rraw) < zWater;
    if (front) ruv = uv;  // never refract something in front of the water
    // Red and blue bend a little less and more than green, along the refraction.
    float olen = length(offset);
    vec2 split = front || olen < 1e-6 ? vec2(0.0) : offset / olen * sunstoneWaterDispersion * max(mg_renderScale.x, 1.0) / size *
                 clamp(olen * size.x * 0.25, 0.0, 1.0);
    vec3 below = vec3(texture2D(mg_scene, ruv - split).r, texture2D(mg_scene, ruv).g, texture2D(mg_scene, ruv + split).b);

    // Scenes without landscape (the menu) have no sun; a high one stands in.
    vec3 l = dot(globalLightDir, globalLightDir) > 0.01 ? normalize(transpose(mat3(mg_view)) * globalLightDir)
                                                        : normalize(vec3(0.3, 0.6, 0.5));
    float sunY = clamp(dot(globalDiffuse, vec3(0.299, 0.587, 0.114)), 0.0, 1.0);

    // Caustics on the floor seen through shallow water, placed where the view ray meets the floor so they stay put
    // on it as the camera moves. The world-to-texture mapping of the water plane comes from the screen derivatives.
    vec2 ex = dFdx(eye.xz), ey = dFdy(eye.xz), ux = dFdx(uv0), uy = dFdy(uv0);
    float edet = ex.x * ey.y - ey.x * ex.y;
    mat2 toUv = mat2(ux, uy) * mat2(ey.y, -ex.y, -ey.x, ex.x) / (abs(edet) > 1e-12 ? edet : 1e-12);
    vec2 floorUv = (uv0 + toUv * (-v.xz * min(through, sunstoneWaterClarity * 3.0))) * sunstoneWaterCausticScale;
    float caustW = sunstoneWaterCaustics * (1.0 - far) * step(0.0, l.y) * step(through, 1e4) *
                   smoothstep(0.2, 1.5, depth) * (1.0 - smoothstep(sunstoneWaterClarity * 0.4, sunstoneWaterClarity * 1.2, depth)) *
                   (1.0 - smoothstep(0.15, 0.4, length(fwidth(floorUv)) * max(mg_renderScale.x, 1.0)));
    float caust = 0.0;
    if (caustW > 0.001) caust = Caustic(floorUv, t);
    below *= 1.0 + caust * caustW * (0.4 + 0.6 * sunY) * mix(globalDiffuse, vec3(1.0), 0.5);

    // The theme's own water colour (the ramp's average) keeps each theme's character.
    vec3 themeCol = texture2D(texture0, vec2(0.125), 8.0).rgb;
    float gameSpec;
    vec3 game = max(GameWater(uv0, t, sunstoneWaterSmooth, gameSpec), 0.0);
    // The game blends its water over what lies behind it; the deep colour takes that brightness in its own hue.
    vec3 gameHere = mix(texture2D(mg_scene, uv).rgb, game, combinedWaterParams[3].z);
    // The blended colour itself, so the ramp's dark contour lines stay as faint as the game draws them.
    vec3 deep = mix(game, gameHere, sunstoneWaterLift) * mix(sunstoneWaterDeep, vec3(1.0), sunstoneWaterRich);
    // A rich sea is a deeper, more saturated version of the same hue; seas that are already vivid gain less.
    float deepHi = max(max(deep.r, deep.g), deep.b);
    float deepSat = (deepHi - min(min(deep.r, deep.g), deep.b)) / max(deepHi, 1e-3);
    float deepY = dot(deep, vec3(0.299, 0.587, 0.114));
    deep = max(mix(vec3(deepY), deep, 1.0 + 0.3 * (1.0 - deepSat) * sunstoneWaterRich) * (1.0 - 0.4 * sunstoneWaterRich), 0.0);
    vec3 absorb = (1.0 - clamp(themeCol, 0.05, 0.95)) * 1.5 + 0.4;
    vec3 trans = exp(-absorb * through / sunstoneWaterClarity) * (1.0 - smoothstep(sunstoneWaterClarity * 0.5, sunstoneWaterClarity * 1.5, depth));
    vec3 body = mix(deep, below * sunstoneWaterShallow, trans);

    // Sky-tinted reflection: the game's own sky where the reflected ray meets it on screen, else the sky at the
    // horizon above this pixel, else the theme's water colour lifted toward white.
    vec3 r = reflect(-v, n);
    r.y = max(r.y, 0.02);
    vec3 sky = mix(themeCol, vec3(1.0), 0.45);
    vec2 hor = ScreenOf(normalize(vec3(r.x, 0.04, r.z)));
    sky = mix(sky, texture2D(mg_scene, hor).rgb, SkyWeight(hor));
    vec2 mir = ScreenOf(r);
    sky = mix(sky, texture2D(mg_scene, mir).rgb, SkyWeight(mir) * (1.0 - far * 0.5));
    float fres = 0.02 + 0.98 * pow(1.0 - max(dot(n, v), 0.0), 5.0);
    // The reflected sky takes on the water's own hue, so a pale horizon does not turn the sea cyan.
    vec3 hue = clamp(deep / max(dot(deep, vec3(0.299, 0.587, 0.114)), 0.05), 0.0, 2.0);
    vec3 col = mix(body, sky * mix(vec3(1.0), hue, 0.5 + 0.35 * sunstoneWaterRich),
                   clamp(fres * sunstoneWaterReflect, 0.0, (0.35 - 0.12 * far) * (1.0 - 0.3 * sunstoneWaterRich)));

    // Facets facing the sun read a little lighter, so the swell keeps its shape seen from above.
    col *= 1.0 + clamp(dot(n.xz, l.xz) * 0.5, -0.07, 0.07) * (1.0 - far);
    // The shallow tint, the sky and the seabed would pull an olive or violet sea off its hue; a rich sea keeps the
    // hue of the game's own water here and only deepens it.
    col = mix(col, KeepHue(col, gameHere), sunstoneWaterRich);

    // Crests tilted toward the sun pass a little light through: a greener shade of the sea's own hue.
    float toSun = dot(n.xz, normalize(l.xz + vec2(1e-4)));
    vec3 lift = clamp(hue * vec3(0.55, 1.15, 1.0), 0.0, 2.0);
    col += lift * 0.06 * smoothstep(0.04, 0.16, toSun) * step(0.0, l.y) * (0.4 + 0.6 * sunY) * (1.0 - far) * sunstoneWaterCrest;

    // The scenery mirrored in the sea, kept below a cap so the sea keeps its own colour.
    vec4 ssr = vec4(0.0);
    float ssrMax = fres * 0.6 * sunstoneWaterSsr;
    if (ssrMax > 0.002 && sunstoneWaterSsrCap > 0.0) {
        vec3 pv = ViewAt(uv, zWater);
        ssr = Reflection(pv, normalize(mat3(mg_view) * r), mg_view[1].xyz);
    }
    float ssrW = clamp(ssrMax * ssr.w, 0.0, sunstoneWaterSsrCap);
    col = mix(col, ssr.rgb * mix(vec3(1.0), hue, 0.3), ssrW);

    vec3 h = normalize(l + v);
    float nh = max(dot(n, h), 0.0);
    // A sharp sun sparkle on every facet that catches the sun, over a broader sheen along the sun path.
    // The broad sheen is what reads as a milky glare on a rich sea; the sparkle stays.
    float sheen = pow(nh, 120.0) * 0.15 * (1.0 - 0.7 * sunstoneWaterRich);
    float above = mix(1.0, 0.75, smoothstep(0.55, 0.9, v.y));
    float glint = (pow(nh, 700.0) * 14.0 + sheen) * (0.3 + 3.0 * fres) * step(0.0, l.y) * above;
    // Glints read as a cool white rather than the sun's warmth, which turns cream after grading.
    vec3 glintCol = vec3(0.9, 0.95, 1.0);
    // The sun's own sparkle is kept smaller than the game's glints, so calm water never shows a broad glare patch.
    col = Glint(col, glintCol * min(glint, 1.5) * sunstoneWaterGlint * 0.4 * (1.0 - far * 0.6));
    // Ripple crests tilted toward the camera catch the sky as small white flecks. Each comes from the finest
    // layer that is still above a pixel, so they stay small at every distance, and they are rarer on pale water
    // where they would read as blotches.
    vec2 fine = ripple * detail + chop * 0.7 * (mid - detail);
    float crest = dot(fine, normalize(v.xz + l.xz + vec2(1e-4)));
    float patchy = smoothstep(0.3, 0.65, Fbm(uv0 * 1.3 + t * vec2(0.013, -0.009)));
    float pale = smoothstep(0.45, 0.8, dot(game, vec3(0.299, 0.587, 0.114)));
    // Mostly glancing views; from straight above they would smear into pale streaks.
    float fleck = smoothstep(0.45 + 0.15 * pale, 0.7 + 0.1 * pale, crest) * patchy * mid * (0.8 + fres) *
                  smoothstep(0.95, 0.5, v.y) * smoothstep(0.3, 0.9, texels) * (1.0 - 0.5 * pale);
    col = Glint(col, mix(sky, vec3(1.0), 0.85) * fleck * 0.35 * sunstoneWaterGlint);
    // The game's own glints: on a rich sea they get a crisp edge; seen from above, where they would stretch into
    // broad pale streaks, they fade.
    gameSpec = mix(gameSpec, smoothstep(0.25, 0.75, gameSpec), sunstoneWaterRich);
    gameSpec = min(gameSpec * above, 0.85);
    vec3 gameGlint = glintCol * gameSpec * sunstoneWaterGlint * 0.8 * (1.0 - 0.5 * pale * (1.0 - sunstoneWaterRich)) * (1.0 - far * 0.5);
    col = Glint(col, gameGlint);

    vec2 wp = gl_TexCoord[0].xy;
    float shore = 1.0 - smoothstep(0.0, sunstoneWaterFoamWidth, depth);
    float lace = Fbm(wp * 4.0 + vec2(t * 0.05, -t * 0.03));
    float band = 0.5 + 0.5 * sin(depth / sunstoneWaterFoamWidth * 12.0 - t * 1.5 + lace * 4.0);
    float foam = smoothstep(0.5, 0.72, lace * 0.8 + band * 0.35 * shore + shore * 0.2) * sqrt(shore);
    // The solid band at the waterline fades out at mid distance, where it would draw a white outline around islands.
    foam = max(foam, smoothstep(0.55, 1.0, shore) * (0.2 + 0.35 * lace) * (1.0 - smoothstep(300.0, 1500.0, dist))) * (1.0 - far);
    col = mix(col, vec3(0.95) * (0.6 + 0.4 * globalDiffuse), clamp(foam * sunstoneWaterFoam, 0.0, 0.9));

    if (sunstoneWater > 13.5) col = vec3(caust * caustW);
    else if (sunstoneWater > 12.5) col = vec3(ssr.w, ssrW * 2.0, 0.0);
    else if (sunstoneWater > 11.5) col = vec3(glint, fleck, 0.0);
    else if (sunstoneWater > 10.5) col = vec3(foam);
    else if (sunstoneWater > 9.5) col = vec3(clamp(depth / 100.0, 0.0, 1.0));
    gl_FragColor = vec4(col, 1.0);
}
