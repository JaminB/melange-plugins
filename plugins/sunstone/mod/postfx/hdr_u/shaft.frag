#version 120
// Radial blur of the shaft source toward the sun's screen position, which is usually off screen. The first stage
// takes 12 jittered steps over shaftLength (in screen heights); FINE takes 12 over a twelfth of that, filling the gaps.
// Taps beyond the screen edge reuse the edge and fade out.
uniform sampler2D mg_prev;
uniform mat4 mg_proj;
uniform mat4 mg_view;
uniform vec4 mg_resolution;
uniform float p_shafts;
uniform float p_shaftLength;
uniform vec3 p_sunDir;
varying vec2 mg_uv;

#include "sun.glsl"

void main() {
    vec3 sun = p_shafts > 0.0 ? SunScreen() : vec3(0.0);
    if (sun.z <= 0.0) {
        gl_FragColor = vec4(0.0);
        return;
    }
    vec2 aspect = vec2(mg_resolution.x / mg_resolution.y, 1.0);
    vec2 d = (sun.xy - mg_uv) * aspect;
    float len = length(d);
    float span = min(p_shaftLength, len);
#ifdef FINE
    span /= 12.0;
#endif
    vec2 stepUv = d / max(len, 1e-4) * (span / 12.0) / aspect;
#ifdef FINE
    float j = Ign(gl_FragCoord.yx + 17.0);
#else
    float j = Ign(gl_FragCoord.xy);
#endif
    vec3 sum = vec3(0.0);
    float wsum = 0.0;
    for (int i = 0; i < 12; ++i) {
        float t = float(i) + j;
        vec2 uv = mg_uv + stepUv * t;
        vec2 off = max(max(-uv, uv - 1.0), vec2(0.0));
#ifdef FINE
        float w = 1.0;
#else
        float w = 1.0 - t / 24.0;
#endif
        sum += texture2D(mg_prev, uv).rgb * w * exp(-4.0 * length(off));
        wsum += w;
    }
    gl_FragColor = vec4(sum / wsum, 1.0);
}
