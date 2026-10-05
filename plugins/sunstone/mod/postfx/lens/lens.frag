#version 120
uniform sampler2D mg_scene;
uniform sampler2D t_bluenoise;
uniform vec4 mg_resolution;
uniform vec2 mg_renderScale;
uniform float mg_frame;
uniform float p_ca;
uniform float p_grain;
uniform float p_dither;
varying vec2 mg_uv;

const float TILE = 64.0;

float Noise(vec2 cell, vec2 shift) {
    return texture2D(t_bluenoise, (mod(cell + shift, TILE) + 0.5) / TILE).r;
}

void main() {
    vec4 s = texture2D(mg_scene, mg_uv);
    vec3 c = s.rgb;

    // Red moves outward and blue inward, in window pixels.
    if (p_ca > 0.0) {
        vec2 d = mg_uv - 0.5;
        float r2 = dot(d, d) * 2.0;
        float k = p_ca * max(mg_renderScale.x, 1.0) * smoothstep(0.35, 1.0, r2);
        if (k > 0.0) {
            vec2 dp = d * mg_resolution.xy;
            vec2 o = dp / max(length(dp), 1e-4) * k * mg_resolution.zw;
            c.r = texture2D(mg_scene, mg_uv + o).r;
            c.b = texture2D(mg_scene, mg_uv - o).b;
        }
    }

    if (p_grain > 0.0 || p_dither > 0.0) {
        vec2 cell = floor(gl_FragCoord.xy / max(mg_renderScale, vec2(1.0)));
        float f = mod(mg_frame, TILE);
        vec2 shift = vec2(mod(f * 37.0, TILE), mod(f * 23.0, TILE));
        if (p_grain > 0.0) {
            float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
            float w = max(4.0 * luma * (1.0 - luma), 0.2);
            c += (Noise(cell, shift) - 0.5) * 2.0 * p_grain * w;
        }
        if (p_dither > 0.0) {
            float tri = Noise(cell, shift + vec2(29.0, 41.0)) + Noise(cell, shift + vec2(11.0, 53.0)) - 1.0;
            c += tri * p_dither / 255.0;
        }
    }

    gl_FragColor = vec4(clamp(c, 0.0, 1.0), s.a);
}
