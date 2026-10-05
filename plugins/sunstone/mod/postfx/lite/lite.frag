#version 120
// Single-pass version of the light and grade effect: foliage greens, highlights expanded into linear light,
// exposure, vignette, the same hue-preserving display transform, saturation and a dither. The sky keeps its own
// contrast and most of its own colour (skyGrade).
uniform sampler2D mg_scene;
uniform sampler2D mg_depth;
uniform mat4 mg_invProj;
uniform vec2 mg_nearFar;
uniform vec2 mg_renderScale;
uniform float mg_frame;
uniform float p_foliage;
uniform float p_folShift;
uniform float p_folValue;
uniform float p_expandSurface;
uniform float p_expandSpec;
uniform float p_expandSky;
uniform float p_exposure;
uniform float p_vignette;
uniform float p_tsContrast;
uniform float p_tsShoulder;
uniform float p_whitePoint;
uniform float p_whiteStart;
uniform float p_whiteAmount;
uniform float p_saturation;
uniform float p_vibrance;
uniform float p_skyGrade;
uniform float p_dither;
varying vec2 mg_uv;

#include "colour.glsl"
#include "foliage.glsl"
#include "display.glsl"

float Ign(vec2 p) { return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715)))); }

void main() {
    vec3 c = texture2D(mg_scene, mg_uv).rgb;
    float depth = texture2D(mg_depth, mg_uv).r;
    vec4 vp = mg_invProj * vec4(vec3(mg_uv, depth) * 2.0 - 1.0, 1.0);
    float dist = length(vp.xyz / vp.w);
    // The sky dome sits beyond half the far plane.
    float sky = depth >= 1.0 ? 1.0 : smoothstep(0.3, 0.5, dist / mg_nearFar.y);

    c = mix(Foliage(c, p_foliage), c, sky);
    vec3 hdr = Expand(pow(c, vec3(2.2)), sky);

    vec2 v = mg_uv * 2.0 - 1.0;
    hdr *= exp2(p_exposure) * clamp(1.0 - p_vignette * dot(v, v) * 0.5, 0.0, 1.0);
    c = pow(Display(hdr, mix(p_tsContrast, 1.0, sky)), vec3(1.0 / 2.2));
    c = Saturation(c, mix(1.0, p_skyGrade, sky));

    // Triangular dither, one cell per window pixel, moved along every frame.
    vec2 cell = floor(gl_FragCoord.xy / max(mg_renderScale, vec2(1.0)));
    float r = fract(Ign(cell) + mod(mg_frame, 64.0) * 0.6180339887) * 2.0 - 1.0;
    c += sign(r) * (1.0 - sqrt(1.0 - abs(r))) * p_dither / 255.0;

    gl_FragColor = vec4(c, 1.0);
}
