#version 120
// 9-tap Gaussian in 5 bilinear fetches; HORIZONTAL picks the direction.
uniform sampler2D mg_prev;
uniform vec4 mg_resolution;
uniform float p_clarityRadius;
varying vec2 mg_uv;

void main() {
#ifdef HORIZONTAL
    vec2 dir = vec2(mg_resolution.z, 0.0) * p_clarityRadius;
#else
    vec2 dir = vec2(0.0, mg_resolution.w) * p_clarityRadius;
#endif
    float s = texture2D(mg_prev, mg_uv).r * 0.2270270270;
    s += (texture2D(mg_prev, mg_uv + dir * 1.3846153846).r + texture2D(mg_prev, mg_uv - dir * 1.3846153846).r) * 0.3162162162;
    s += (texture2D(mg_prev, mg_uv + dir * 3.2307692308).r + texture2D(mg_prev, mg_uv - dir * 3.2307692308).r) * 0.0702702703;
    gl_FragColor = vec4(vec3(s), 1.0);
}
