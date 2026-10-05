#version 120
// One level of the bloom chain on the way up: a 3x3 tent upsample of the coarser level (mg_prev) plus this level's
// downsample (SRC), weighted as level LEVEL (both set by defines). FIRST: mg_prev is the coarsest downsample.
uniform sampler2D mg_prev;
uniform sampler2D SRC;
uniform vec4 mg_resolution;
uniform vec2 mg_renderScale;
uniform float p_bloom;
uniform float p_dirt;
uniform float p_flare;
uniform float p_clarity;
varying vec2 mg_uv;

#include "bloom.glsl"

void main() {
    if (p_bloom <= 0.0 && p_dirt <= 0.0 && p_flare <= 0.0 && p_clarity <= 0.0) {
        gl_FragColor = vec4(0.0);
        return;
    }
    // One texel of the coarser level.
    vec2 o = mg_resolution.zw * 2.0;
    vec3 t = texture2D(mg_prev, mg_uv).rgb * 4.0;
    t += (texture2D(mg_prev, mg_uv + vec2(o.x, 0.0)).rgb + texture2D(mg_prev, mg_uv - vec2(o.x, 0.0)).rgb +
          texture2D(mg_prev, mg_uv + vec2(0.0, o.y)).rgb + texture2D(mg_prev, mg_uv - vec2(0.0, o.y)).rgb) * 2.0;
    t += texture2D(mg_prev, mg_uv + o).rgb + texture2D(mg_prev, mg_uv - o).rgb +
         texture2D(mg_prev, mg_uv + vec2(o.x, -o.y)).rgb + texture2D(mg_prev, mg_uv + vec2(-o.x, o.y)).rgb;
    t /= 16.0;
#ifdef FIRST
    t *= BloomWeight(LEVEL + 1.0);
#endif
    gl_FragColor = vec4(t + texture2D(SRC, mg_uv).rgb * BloomWeight(LEVEL), 1.0);
}
