#version 120
uniform sampler2D mg_scene;
uniform sampler2D t_golden;
uniform sampler2D t_dusk;
uniform float p_exposure;
uniform float p_strength;
uniform float p_contrast;
uniform float p_saturation;
uniform float p_lutAmount;
uniform float p_look;
uniform float p_vignette;
uniform float p_huePreserve;
varying vec2 mg_uv;

vec3 Filmic(vec3 x) {
    const float A = 0.15, B = 0.50, C = 0.10, D = 0.20, E = 0.02, F = 0.30;
    return ((x * (A * x + C * B) + D * E) / (x * (A * x + B) + D * F)) - E / F;
}

vec3 SampleLut(sampler2D lut, vec3 c) {
    float b = c.b * 15.0;
    float s0 = floor(b);
    float s1 = min(s0 + 1.0, 15.0);
    vec2 uv = vec2((c.r * 15.0 + 0.5) / 256.0, (c.g * 15.0 + 0.5) / 16.0);
    vec3 lo = texture2D(lut, uv + vec2(s0 / 16.0, 0.0)).rgb;
    vec3 hi = texture2D(lut, uv + vec2(s1 / 16.0, 0.0)).rgb;
    return mix(lo, hi, b - s0);
}

// 1 for blue, violet and purple pixels (sky, sea, the Lunar set) and for bright near-white ones (clouds), 0 for
// warm and mid-tone neutral ones.
float Cool(vec3 c) {
    float hi = max(max(c.r, c.g), c.b), lo = min(min(c.r, c.g), c.b);
    float s = (hi - lo) / max(hi, 1e-3);
    float sat = smoothstep(0.02, 0.12, s);
    float cloud = smoothstep(0.7, 0.9, hi) * (1.0 - smoothstep(0.1, 0.25, s));
    float blue = smoothstep(-0.03, 0.06, c.b - max(c.r, c.g));
    float purple = smoothstep(0.03, 0.12, min(c.r, c.b) - c.g) * step(c.r, c.b * 1.6);
    return max(max(blue, purple) * sat, cloud);
}

void main() {
    vec4 src = texture2D(mg_scene, mg_uv);
    vec3 lin = pow(src.rgb, vec3(2.2)) * exp2(p_exposure);
    // The curve runs on luminance and scales RGB, so it shapes contrast without washing out saturated colours.
    float y = max(dot(lin, vec3(0.2126, 0.7152, 0.0722)), 1e-4);
    float fy = Filmic(vec3(y * 2.0)).x / Filmic(vec3(2.0)).x;
    lin *= mix(1.0, fy / y, p_strength);
    vec3 c = pow(clamp(lin, 0.0, 1.0), vec3(1.0 / 2.2));
    c = (c - 0.5) * p_contrast + 0.5;
    float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
    c = clamp(mix(vec3(luma), c, p_saturation), 0.0, 1.0);

    vec3 graded = mix(SampleLut(t_golden, c), SampleLut(t_dusk, c), clamp(p_look, 0.0, 1.0));
    c = mix(c, graded, p_lutAmount * (1.0 - p_huePreserve * Cool(c)));

    vec2 v = mg_uv * 2.0 - 1.0;
    c *= clamp(1.0 - p_vignette * dot(v, v) * 0.5, 0.0, 1.0);

    gl_FragColor = vec4(c, src.a);
}
