#version 120
// The scene in linear light: foliage greens, highlight expansion, cloud shadows, height fog toward the horizon colour
// (pass.horizon) and the sky gradient and sun glow. Alpha is the distance-blur amount (0 on the sky).
uniform sampler2D mg_scene;
uniform sampler2D mg_depth;
uniform sampler2D mg_pass_horizon;
uniform sampler2D t_cloud;
uniform mat4 mg_invProj;
uniform mat4 mg_view;
uniform vec2 mg_nearFar;
uniform float mg_time;
uniform float p_foliage;
uniform float p_folShift;
uniform float p_folValue;
uniform float p_expandSurface;
uniform float p_expandSpec;
uniform float p_expandSky;
uniform float p_cloudShadow;
uniform float p_cloudScale;
uniform float p_cloudSpeed;
uniform float p_fogAmount;
uniform float p_fogStart;
uniform float p_fogDistance;
uniform float p_heightFalloff;
uniform float p_maxHaze;
uniform float p_horizonHaze;
uniform float p_desaturate;
uniform float p_flatHaze;
uniform float p_sunTint;
uniform float p_skyGradient;
uniform vec3 p_sunDir;
uniform vec3 p_sunColor;
uniform float p_sunGlow;
uniform float p_sunDisc;
uniform float p_sunSize;
uniform float p_dofStart;
uniform float p_dofEnd;
varying vec2 mg_uv;

#include "colour.glsl"
#include "foliage.glsl"

// The horizon colour near this column (alpha: how much sky the columns found) and, in day, how bright the whole
// horizon is, which gates the sun effects off on dark skies.
vec4 HorizonColour(float x, out float day) {
    vec3 sum = vec3(0.0), total = vec3(0.0);
    float wsum = 0.0, cover = 0.0;
    for (int i = 0; i < 8; ++i) {
        float u = (float(i) + 0.5) / 8.0;
        vec4 h = texture2D(mg_pass_horizon, vec2(u, 0.5));
        float w = h.a * exp(-(u - x) * (u - x) * 8.0);
        sum += h.rgb * w;
        wsum += w;
        total += h.rgb * h.a;
        cover += h.a;
    }
    day = cover > 1e-3 ? smoothstep(0.25, 0.5, Luma(total / cover)) : 0.0;
    return wsum > 1e-4 ? vec4(sum / wsum, clamp(cover / 4.0, 0.0, 1.0)) : vec4(0.0);
}

vec2 SafeNormalize(vec2 v) { return v / max(length(v), 1e-4); }

void main() {
    vec3 c = texture2D(mg_scene, mg_uv).rgb;
    float depth = texture2D(mg_depth, mg_uv).r;
    vec4 vp = mg_invProj * vec4(vec3(mg_uv, depth) * 2.0 - 1.0, 1.0);
    vec3 P = vp.xyz / vp.w;
    float dist = length(P);
    float far = mg_nearFar.y;
    // Taken before any branch, where derivatives are defined.
    vec3 Nv = cross(dFdx(P), dFdy(P));
    vec3 Nw = Nv / max(length(Nv), 1e-20) * mat3(mg_view);
    float level = smoothstep(0.92, 0.995, abs(Nw.y));
    vec3 offW = P * mat3(mg_view);
    vec3 rayW = normalize(offW);
    vec3 posW = (P - mg_view[3].xyz) * mat3(mg_view);
    vec2 drift = fract(vec2(0.8, 0.6) * (mg_time * p_cloudSpeed / p_cloudScale));
    float cloud = texture2D(t_cloud, posW.xz / p_cloudScale + drift).r;

#ifdef DEBUG_RAMP
    // Rows from the bottom: grey, grass, sand, sky (expanded as sky); black to full brightness left to right.
    if (mg_uv.y < 0.12) {
        float row = floor(mg_uv.y / 0.03);
        vec3 base = row < 0.5 ? vec3(1.0) : row < 1.5 ? vec3(0.42, 0.78, 0.2)
                  : row < 2.5 ? vec3(1.0, 0.88, 0.62) : vec3(0.55, 0.75, 1.0);
        gl_FragColor = vec4(Expand(pow(base * mg_uv.x, vec3(2.2)), step(2.5, row)), 0.0);
        return;
    }
#endif

    float sky = depth >= 1.0 || (dist > 0.5 * far && rayW.y > -0.002) ? 1.0 : 0.0;
    float day;
    vec4 hz = HorizonColour(mg_uv.x, day);
    vec3 sunW = normalize(p_sunDir);
    float cosSun = dot(rayW, sunW);
    float cs = max(cosSun, 0.0);

    // Haze colour: the horizon, warmer on the sun's side and cooler opposite it.
    float side = 0.5 + 0.5 * dot(SafeNormalize(rayW.xz), SafeNormalize(sunW.xz));
    vec3 tint = mix(vec3(0.93, 0.97, 1.05), vec3(1.0, 0.93, 0.82), side * side);
    vec3 hazeCol = Expand(pow(hz.rgb, vec3(2.2)), 1.0) * mix(vec3(1.0), tint, p_sunTint * day);
    float glowWide = pow(cs, 24.0) * 0.25 * p_sunGlow * day;

    vec3 outc;
    if (sky < 0.5) {
        c = Foliage(c, p_foliage);
        vec3 lin = Expand(pow(c, vec3(2.2)), 0.0);
        lin *= 1.0 - p_cloudShadow * smoothstep(0.4, 0.75, cloud) * day * (1.0 - smoothstep(4000.0, 8000.0, dist));

        // Exponential height fog integrated along the view ray, relative to the camera's height.
        float k = offW.y / p_heightFalloff;
        float along = abs(k) < 1e-3 ? 1.0 : min((1.0 - exp(-k)) / k, 4.0);
        float od = max(dist - p_fogStart, 0.0) / p_fogDistance * along;
        float d = dist / far;
        float maxH = mix(p_maxHaze, p_horizonHaze, smoothstep(0.15, 0.5, d));
        float haze = clamp(maxH * (1.0 - exp(-od)) * hz.a * p_fogAmount, 0.0, 1.0);
        // Level surfaces (the sea, mostly) haze less and in their own hue, so a tinted sky does not shift the sea;
        // both are released toward the horizon so the far sea meets the sky without a seam.
        float lv = level * (1.0 - smoothstep(0.2, 0.45, d));
        haze *= mix(1.0, p_flatHaze, lv);
        vec3 fc = mix(lin, vec3(Luma(lin)), haze * p_desaturate);
        vec3 target = hazeCol + p_sunColor * glowWide;
        float fy = Luma(fc);
        vec3 own = fc * (Luma(target) / max(fy, 1e-4));
        target = mix(target, fy > 1e-3 ? own : target, lv);
        outc = mix(fc, target, haze);
    } else {
        vec3 s = Expand(pow(c, vec3(2.2)), 1.0);
        s *= mix(1.0, mix(1.08, 0.88, smoothstep(0.0, 0.7, rayW.y)), p_skyGradient);
        float band = clamp(p_horizonHaze * exp(-12.0 * max(rayW.y, 0.0)) * 0.5 * p_fogAmount * hz.a, 0.0, 1.0);
        s = mix(s, hazeCol, band);
        float cosR = cos(radians(0.5 * p_sunSize));
        float disc = smoothstep(cosR - (1.0 - cosR) * 0.3, cosR, cosSun);
        float glow = glowWide + pow(cs, 600.0) * 2.0 * p_sunGlow * day;
        outc = s + p_sunColor * (glow + 30.0 * disc * p_sunDisc * day);
    }

    float coc = smoothstep(p_dofStart, p_dofEnd, dist) * (1.0 - sky);
    gl_FragColor = vec4(outc, coc);
}
