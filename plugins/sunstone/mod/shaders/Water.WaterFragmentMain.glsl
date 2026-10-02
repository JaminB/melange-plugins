#version 130
// Sunstone water: refraction of the scene below with depth-based absorption, a Fresnel blend toward a sky-tinted
// reflection, a sun glint and broken foam where the water is shallow. Reads copies of the scene taken just before
// the water draws.
uniform sampler2D texture0;   // the theme's water colour ramp
uniform sampler2D texture1;   // wave normals
uniform float pausedTime;
uniform mat4 mg_view;
uniform mat4 mg_proj;
uniform sampler2D mg_depth;
uniform sampler2D mg_scene;
uniform vec2 mg_nearFar;
// The landscape's sun (eye space) and colour, fed from the landscape programs.
uniform vec3 globalLightDir;
uniform vec3 globalDiffuse;

uniform float sunstoneWater;          // 1 Sunstone; 10 shows the water depth, 11 the foam, 12 glint and flecks
uniform vec3 sunstoneWaterDeep;       // deep-water tint, multiplied by the theme's own water colour
uniform vec3 sunstoneWaterShallow;    // tint of the light that crosses shallow water
uniform float sunstoneWaterClarity;   // distance (world units) over which the light is absorbed
uniform float sunstoneWaterReflect;   // reflection strength
uniform float sunstoneWaterWaves;     // wave normal strength
uniform float sunstoneWaterRefract;   // refraction offset (fraction of the screen)
uniform float sunstoneWaterGlint;     // sun glint strength
uniform float sunstoneWaterFoam;      // shore foam strength
uniform float sunstoneWaterFoamWidth; // water depth (world units) the foam reaches

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

void main() {
    vec3 eye = gl_TexCoord[1].xyz;
    float dist = length(eye);
    vec3 v = -eye / dist;
    float t = pausedTime;

    // Swell and fine ripples. Each layer fades out where its texels shrink below a pixel, where it would only
    // shimmer; distant water also calms down.
    vec2 uv0 = gl_TexCoord[0].xy;
    float texels = length(fwidth(uv0)) * 256.0;
    float far = smoothstep(800.0, 6000.0, dist);
    float detail = 1.0 - smoothstep(2.0, 8.0, texels * 3.1);
    float broad = 1.0 - smoothstep(3.0, 12.0, texels * 0.5);
    vec2 swell = Slope(uv0 * 0.5 + t * vec2(0.021, 0.013)) + Slope(uv0 * -1.1 + t * vec2(-0.017, 0.029)) * 0.6;
    vec2 ripple = Slope(uv0 * 3.1 + t * vec2(0.05, -0.035)) + Slope(uv0 * -5.3 + t * vec2(-0.04, -0.06)) * 0.5;
    vec2 chop = Slope(uv0 * 1.4 + t * vec2(-0.03, 0.04));
    float mid = 1.0 - smoothstep(2.0, 8.0, texels * 1.4);
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
    if (Linear(rraw) < zWater) ruv = uv;  // never refract something in front of the water
    vec3 below = texture2D(mg_scene, ruv).rgb;

    // The theme's own water colour (the ramp's average) keeps each theme's character.
    vec3 themeCol = texture2D(texture0, vec2(0.125), 8.0).rgb;
    vec3 deep = themeCol * sunstoneWaterDeep;
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
    vec3 col = mix(body, sky * mix(vec3(1.0), themeCol * 1.6, 0.35), clamp(fres * sunstoneWaterReflect, 0.0, 0.5));

    // Scenes without landscape (the menu) have no sun; a high one stands in.
    vec3 l = dot(globalLightDir, globalLightDir) > 0.01 ? normalize(transpose(mat3(mg_view)) * globalLightDir)
                                                        : normalize(vec3(0.3, 0.6, 0.5));
    // Facets facing the sun read a little lighter, so the swell keeps its shape seen from above.
    col *= 1.0 + clamp(dot(n.xz, l.xz) * 0.5, -0.07, 0.07) * (1.0 - far);
    vec3 h = normalize(l + v);
    float nh = max(dot(n, h), 0.0);
    float glint = (pow(nh, 600.0) * 6.0 + pow(nh, 80.0) * 0.25) * fres * 4.0 * step(0.0, l.y);
    col += globalDiffuse * glint * sunstoneWaterGlint * (1.0 - far * 0.6);
    // Ripple crests tilted toward the camera catch the sky as small bright flecks.
    float crest = dot(chop * 0.8 + ripple * 0.6 * detail, normalize(v.xz + l.xz + vec2(1e-4)));
    float patchy = smoothstep(0.35, 0.7, Fbm(uv0 * 0.6 + t * vec2(0.013, -0.009)));
    // Glancing views only, where the ripples are small on screen; from above they smear into pale streaks.
    float fleck = smoothstep(0.35, 0.6, crest) * patchy * mid * (0.7 + fres) * smoothstep(0.85, 0.45, v.y) * smoothstep(0.4, 1.0, texels);
    col += mix(sky, vec3(1.0), 0.75) * fleck * 0.8 * sunstoneWaterGlint;

    vec2 wp = gl_TexCoord[0].xy;
    float shore = 1.0 - smoothstep(0.0, sunstoneWaterFoamWidth, depth);
    float lace = Fbm(wp * 4.0 + vec2(t * 0.05, -t * 0.03));
    float band = 0.5 + 0.5 * sin(depth / sunstoneWaterFoamWidth * 12.0 - t * 1.5 + lace * 4.0);
    float foam = smoothstep(0.5, 0.72, lace * 0.8 + band * 0.35 * shore + shore * 0.2) * sqrt(shore);
    foam = max(foam, smoothstep(0.4, 1.0, shore) * (0.55 + 0.45 * lace)) * (1.0 - far);
    col = mix(col, vec3(0.95) * (0.6 + 0.4 * globalDiffuse), clamp(foam * sunstoneWaterFoam, 0.0, 0.9));

    if (sunstoneWater > 11.5) col = vec3(glint, fleck, 0.0);
    else if (sunstoneWater > 10.5) col = vec3(foam);
    else if (sunstoneWater > 9.5) col = vec3(clamp(depth / 100.0, 0.0, 1.0));
    gl_FragColor = vec4(col, 1.0);
}
