#version 120
// Assembly in linear light: distance blur, local contrast, light shafts, bloom, lens dirt and flare, then exposure,
// vignette and the display transform back to the 8-bit scene, saturation, the colour-grading LUT and a blue-noise
// dither. The sky keeps its own contrast and most of its own colour (skyGrade).
uniform sampler2D mg_pass_lin;
uniform sampler2D mg_pass_dofblur;
uniform sampler2D mg_pass_u1;
uniform sampler2D mg_pass_u2;
uniform sampler2D mg_pass_u3;
uniform sampler2D mg_pass_shaftB;
uniform sampler2D mg_depth;
uniform sampler2D t_dirt;
uniform sampler2D t_golden;
uniform sampler2D t_dusk;
uniform sampler2D t_bluenoise;
uniform mat4 mg_invProj;
uniform vec2 mg_nearFar;
uniform vec4 mg_resolution;
uniform vec2 mg_renderScale;
uniform float mg_frame;
uniform float p_foliage;
uniform float p_dof;
uniform float p_clarity;
uniform float p_shafts;
uniform vec3 p_sunColor;
uniform float p_bloom;
uniform float p_dirt;
uniform float p_flare;
uniform float p_expandSky;
uniform float p_exposure;
uniform float p_vignette;
uniform float p_tsContrast;
uniform float p_tsShoulder;
uniform float p_whitePoint;
uniform float p_whiteStart;
uniform float p_whiteAmount;
uniform float p_saturation;
uniform float p_skySaturation;
uniform float p_vibrance;
uniform float p_lutAmount;
uniform float p_look;
uniform float p_huePreserve;
uniform float p_skyGrade;
uniform float p_dither;
varying vec2 mg_uv;

#include "colour.glsl"
#include "display.glsl"
#include "bloom.glsl"

const float BLUE_NOISE_SIZE = 64.0;

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
    float hi = Max3(c), lo = Min3(c);
    float s = (hi - lo) / max(hi, 1e-3);
    float sat = smoothstep(0.02, 0.12, s);
    float cloud = smoothstep(0.7, 0.9, hi) * (1.0 - smoothstep(0.1, 0.25, s));
    float blue = smoothstep(-0.03, 0.06, c.b - max(c.r, c.g));
    float purple = smoothstep(0.03, 0.12, min(c.r, c.b) - c.g) * step(c.r, c.b * 1.6);
    return max(max(blue, purple) * sat, cloud);
}

// What of the wide bloom level lies above the brightest clouds (the sun and its glow), at uv, faded toward the
// screen edge.
vec3 Ghost(vec2 uv, float norm) {
    float edge = 1.0 - smoothstep(0.35, 0.5, length(uv - 0.5));
    return max(texture2D(mg_pass_u3, uv).rgb / norm - (p_expandSky + 0.5), vec3(0.0)) * edge;
}

void main() {
    vec4 L = texture2D(mg_pass_lin, mg_uv);
    vec3 hdr = max(L.rgb, vec3(0.0));
    float coc = clamp(L.a, 0.0, 1.0);
    float depth = texture2D(mg_depth, mg_uv).r;
    vec4 vp = mg_invProj * vec4(vec3(mg_uv, depth) * 2.0 - 1.0, 1.0);
    float dist = length(vp.xyz / vp.w);
    // The sky dome sits at about 0.63 of the far plane; the far sea ends before half of it.
    float sky = depth >= 1.0 ? 1.0 : smoothstep(0.5, 0.6, dist / mg_nearFar.y);
    float ramp = 0.0;
#ifdef DEBUG_RAMP
    if (mg_uv.y < 0.12) {
        ramp = 1.0;
        sky = step(0.09, mg_uv.y);
        coc = 0.0;
    }
#endif
    float fx = 1.0 - ramp;

    if (p_dof > 0.0 && coc > 0.0) {
        vec4 b = texture2D(mg_pass_dofblur, mg_uv);
        if (b.a > 1e-4) hdr = mix(hdr, b.rgb / b.a, coc * p_dof * smoothstep(0.0, 0.02, b.a));
    }

    // Local contrast against the quarter-resolution bloom level; not on the sky, the blurred distance or the
    // magnified textures right in front of the camera.
    if (p_clarity > 0.0) {
        float yb = Luma(texture2D(mg_pass_u2, mg_uv).rgb / BloomTotal(2.0));
        float k = p_clarity * 0.5 * (1.0 - sky) * (1.0 - coc * p_dof) * smoothstep(18.0, 60.0, dist) * fx;
        hdr *= pow(clamp((Luma(hdr) + 1e-4) / (yb + 1e-4), 0.5, 2.0), k);
    }

    if (p_shafts > 0.0) {
        vec3 s = texture2D(mg_pass_shaftB, mg_uv).rgb;
        hdr += s * p_shafts * p_sunColor * clamp(dist / 600.0, 0.0, 1.0) * mix(1.0, 0.2, sky) * fx;
    }

    if (p_bloom > 0.0) hdr = mix(hdr, texture2D(mg_pass_u1, mg_uv).rgb / BloomTotal(1.0), p_bloom * fx);

    if (p_dirt > 0.0 || p_flare > 0.0) {
        float n3 = BloomTotal(3.0);
        vec3 lens = max(texture2D(mg_pass_u3, mg_uv).rgb / n3 - 1.0, vec3(0.0)) * texture2D(t_dirt, mg_uv).r * p_dirt;
        if (p_flare > 0.0) {
            // Two ghosts mirrored through the centre and a halo ring.
            vec2 aspect = vec2(mg_resolution.x / mg_resolution.y, 1.0);
            vec2 toC = 0.5 - mg_uv;
            vec2 halo = mg_uv + normalize((toC + vec2(1e-5, 0.0)) * aspect) / aspect * 0.35;
            vec3 f = Ghost(0.5 + toC, n3) * vec3(1.0, 0.85, 0.65);
            f += Ghost(0.5 + toC * 0.45, n3) * vec3(0.65, 0.85, 1.0);
            f += Ghost(halo, n3) * vec3(0.85, 0.9, 1.0) * 0.5;
            lens += f * p_flare;
        }
        hdr += lens * fx;
    }

    vec2 v = mg_uv * 2.0 - 1.0;
    float vig = mix(1.0, clamp(1.0 - p_vignette * dot(v, v) * 0.5, 0.0, 1.0), fx);
    hdr *= exp2(p_exposure) * vig;
    vec3 c = pow(Display(hdr, mix(p_tsContrast, 1.0, sky)), vec3(1.0 / 2.2));

    float grade = mix(1.0, p_skyGrade, sky);
    c = Saturation(c, grade);
    c = clamp(mix(vec3(Luma(c)), c, mix(1.0, p_skySaturation, sky)), 0.0, 1.0);

    vec3 graded = mix(SampleLut(t_golden, c), SampleLut(t_dusk, c), clamp(p_look, 0.0, 1.0));
    c = mix(c, graded, p_lutAmount * grade * (1.0 - p_huePreserve * Cool(c)));

    // Triangular dither from the blue-noise tile, one cell per window pixel, moved along every frame.
    vec2 cell = floor(gl_FragCoord.xy / max(mg_renderScale, vec2(1.0)));
    float n = fract(texture2D(t_bluenoise, (cell + 0.5) / BLUE_NOISE_SIZE).r + mod(mg_frame, 64.0) * 0.6180339887);
    float r = n * 2.0 - 1.0;
    float tri = sign(r) * (1.0 - sqrt(1.0 - abs(r)));
    c += tri * p_dither * fx / 255.0;

    gl_FragColor = vec4(c, 1.0);
}
