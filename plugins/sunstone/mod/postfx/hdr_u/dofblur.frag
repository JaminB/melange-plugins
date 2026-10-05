#version 120
// Distance blur: a 9-tap disc gather over the premultiplied half-resolution colour. A tap counts only as far as its
// own blur amount reaches, so sharp pixels nearby are not smeared over. Output stays premultiplied: colour sum in
// rgb, weight in alpha.
uniform sampler2D mg_prev;
uniform vec4 mg_sceneResolution;
uniform vec2 mg_renderScale;
uniform float p_dof;
uniform float p_dofRadius;
varying vec2 mg_uv;

void main() {
    vec4 c = texture2D(mg_prev, mg_uv);
    float R = p_dofRadius * max(mg_renderScale.y, 1.0);
    if (p_dof <= 0.0 || c.a <= 0.0 || R <= 0.0) {
        gl_FragColor = vec4(0.0);
        return;
    }
    vec4 sum = c;
    for (int i = 0; i < 8; ++i) {
        float ang = float(i) * 0.785398 + 0.392699;
        float r = mod(float(i), 2.0) < 0.5 ? 1.0 : 0.55;
        vec2 o = vec2(cos(ang), sin(ang)) * r * R;
        vec4 s = texture2D(mg_prev, mg_uv + o * mg_sceneResolution.zw);
        sum += s * clamp(s.a * R - r * R + 1.0, 0.0, 1.0);
    }
    gl_FragColor = sum / 9.0;
}
