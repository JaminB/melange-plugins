#version 120
// Light-shaft source at quarter resolution: sky radiance, strongest toward the sun, with everything in front of the
// sky black. Off when the sun is behind the camera or the horizon is dark.
uniform sampler2D mg_pass_lin;
uniform sampler2D mg_depth;
uniform sampler2D mg_pass_horizon;
uniform mat4 mg_proj;
uniform mat4 mg_invProj;
uniform mat4 mg_view;
uniform vec2 mg_nearFar;
uniform vec4 mg_resolution;
uniform float p_shafts;
uniform vec3 p_sunDir;
varying vec2 mg_uv;

#include "colour.glsl"
#include "sun.glsl"

// Same day value as the lin pass: how bright the horizon the columns found is.
float Day() {
    vec3 total = vec3(0.0);
    float cover = 0.0;
    for (int i = 0; i < 8; ++i) {
        vec4 h = texture2D(mg_pass_horizon, vec2((float(i) + 0.5) / 8.0, 0.5));
        total += h.rgb * h.a;
        cover += h.a;
    }
    return cover > 1e-3 ? smoothstep(0.25, 0.5, Luma(total / cover)) : 0.0;
}

void main() {
    float gate = p_shafts > 0.0 ? SunScreen().z : 0.0;
    if (gate > 0.0) gate *= Day();
    if (gate <= 0.0) {
        gl_FragColor = vec4(0.0);
        return;
    }
    vec3 sunW = normalize(p_sunDir);
    vec3 sum = vec3(0.0);
    // Four taps, each on the middle of a 2x2 block of the 4x4 source pixels under this one.
    vec2 o = mg_resolution.zw * 0.25;
    for (int i = 0; i < 4; ++i) {
        vec2 uv = mg_uv + o * vec2(mod(float(i), 2.0) < 0.5 ? -1.0 : 1.0, i < 2 ? -1.0 : 1.0);
        float depth = texture2D(mg_depth, uv).r;
        vec4 vp = mg_invProj * vec4(vec3(uv, depth) * 2.0 - 1.0, 1.0);
        vec3 P = vp.xyz / vp.w;
        vec3 rayW = normalize(P * mat3(mg_view));
        if (depth >= 1.0 || length(P) > 0.55 * mg_nearFar.y) {
            float cs = max(dot(rayW, sunW), 0.0);
            sum += min(max(texture2D(mg_pass_lin, uv).rgb, vec3(0.0)), vec3(8.0)) * mix(0.2, 1.0, cs * cs * cs * cs);
        }
    }
    gl_FragColor = vec4(sum * 0.25 * gate, 1.0);
}
