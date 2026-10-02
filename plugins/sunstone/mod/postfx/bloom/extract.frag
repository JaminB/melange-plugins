#version 120
// Soft-knee bright-pass on luminance, averaged over the 4x4 scene pixels under each quarter-size texel.
uniform sampler2D mg_scene;
uniform sampler2D mg_depth;
uniform mat4 mg_invProj;
uniform vec2 mg_nearFar;
uniform vec4 mg_sceneResolution;
uniform float p_threshold;
uniform float p_skyWeight;
varying vec2 mg_uv;

vec3 Bright(vec2 uv) {
    vec3 c = texture2D(mg_scene, uv).rgb;
    float m = dot(c, vec3(0.2126, 0.7152, 0.0722));
    float knee = 0.06;
    float s = clamp(m - p_threshold + knee, 0.0, 2.0 * knee);
    s = s * s / (4.0 * knee);
    float w = max(s, m - p_threshold) / max(m, 1e-4);
    float d = texture2D(mg_depth, uv).r;
    vec4 p = mg_invProj * vec4(vec3(uv, d) * 2.0 - 1.0, 1.0);
    if (d >= 1.0 || length(p.xyz / p.w) > 0.5 * mg_nearFar.y) w *= p_skyWeight;
    return c * c * w;
}

void main() {
    vec2 o = mg_sceneResolution.zw;
    vec3 s = Bright(mg_uv + vec2(-o.x, -o.y)) + Bright(mg_uv + vec2(o.x, -o.y)) + Bright(mg_uv + vec2(-o.x, o.y)) +
             Bright(mg_uv + vec2(o.x, o.y));
    gl_FragColor = vec4(s * 0.25, 1.0);
}
