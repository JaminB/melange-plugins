#version 120
// One level of the bloom chain: a 13-tap downsample of SRC (set by defines). KARIS weights each 2x2 group by its
// brightness so single hot pixels do not flicker into the chain.
uniform sampler2D SRC;
uniform vec4 mg_resolution;
uniform float p_bloom;
uniform float p_dirt;
uniform float p_flare;
uniform float p_clarity;
varying vec2 mg_uv;

#include "colour.glsl"

vec3 Tap(vec2 o) { return max(texture2D(SRC, mg_uv + o * mg_resolution.zw).rgb, vec3(0.0)); }

vec3 Group(vec3 a, vec3 b, vec3 c, vec3 d, float w, inout float wsum) {
    vec3 m = (a + b + c + d) * 0.25;
#ifdef KARIS
    w /= 1.0 + Luma(m);
#endif
    wsum += w;
    return m * w;
}

void main() {
    if (p_bloom <= 0.0 && p_dirt <= 0.0 && p_flare <= 0.0 && p_clarity <= 0.0) {
        gl_FragColor = vec4(0.0);
        return;
    }
    // Offsets in output texels: one output texel is two source texels.
    vec3 a = Tap(vec2(-1.0, -1.0)), b = Tap(vec2(0.0, -1.0)), c = Tap(vec2(1.0, -1.0));
    vec3 d = Tap(vec2(-0.5, -0.5)), e = Tap(vec2(0.5, -0.5));
    vec3 f = Tap(vec2(-1.0, 0.0)), g = Tap(vec2(0.0, 0.0)), h = Tap(vec2(1.0, 0.0));
    vec3 i = Tap(vec2(-0.5, 0.5)), j = Tap(vec2(0.5, 0.5));
    vec3 k = Tap(vec2(-1.0, 1.0)), l = Tap(vec2(0.0, 1.0)), m = Tap(vec2(1.0, 1.0));
    float wsum = 0.0;
    vec3 sum = Group(d, e, i, j, 0.5, wsum);
    sum += Group(a, b, f, g, 0.125, wsum);
    sum += Group(b, c, g, h, 0.125, wsum);
    sum += Group(f, g, k, l, 0.125, wsum);
    sum += Group(g, h, l, m, 0.125, wsum);
    gl_FragColor = vec4(sum / wsum, 1.0);
}
