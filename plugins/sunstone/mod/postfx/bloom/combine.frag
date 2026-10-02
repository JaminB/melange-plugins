#version 120
uniform sampler2D mg_scene;
uniform sampler2D mg_pass_blurv;
uniform sampler2D mg_pass_blurv2;
uniform float p_intensity;
varying vec2 mg_uv;

void main() {
    vec4 c = texture2D(mg_scene, mg_uv);
    vec3 glow = (texture2D(mg_pass_blurv, mg_uv).rgb * 0.6 + texture2D(mg_pass_blurv2, mg_uv).rgb * 0.4) * p_intensity;
    glow = sqrt(clamp(glow, 0.0, 1.0));
    gl_FragColor = vec4(1.0 - (1.0 - c.rgb) * (1.0 - glow), c.a);
}
