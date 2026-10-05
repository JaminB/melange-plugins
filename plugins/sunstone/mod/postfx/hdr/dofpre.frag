#version 120
// Half-resolution colour premultiplied by the distance-blur amount (lin alpha), which is kept in alpha. Near pixels
// and the sky have an amount of 0, so they never bleed into the blur.
uniform sampler2D mg_pass_lin;
uniform vec4 mg_resolution;
uniform float p_dof;
varying vec2 mg_uv;

vec4 Tap(vec2 o) {
    vec4 s = texture2D(mg_pass_lin, mg_uv + o * mg_resolution.zw);
    float coc = clamp(s.a, 0.0, 1.0);
    return vec4(max(s.rgb, vec3(0.0)) * coc, coc);
}

void main() {
    if (p_dof <= 0.0) {
        gl_FragColor = vec4(0.0);
        return;
    }
    // At half resolution each tap lands on one source pixel.
    gl_FragColor = (Tap(vec2(-0.25, -0.25)) + Tap(vec2(0.25, -0.25)) + Tap(vec2(-0.25, 0.25)) + Tap(vec2(0.25, 0.25))) * 0.25;
}
