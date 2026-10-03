#version 120
// Contrast Adaptive Sharpening, the no-scaling path of CasFilter() in ffx_cas.h, ported to GLSL 1.20, with a fade near
// the camera and a floor below which faint steps are left alone (both Sunstone additions).
//
// Copyright (c) 2017-2019 Advanced Micro Devices, Inc. All rights reserved.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated
// documentation files (the "Software"), to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
// permit persons to whom the Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all copies or substantial portions of
// the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE
// WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
// OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

uniform sampler2D mg_scene;
uniform vec4 mg_resolution;
uniform vec2 mg_renderScale;
uniform float p_sharpness;
uniform float p_nearFade;
uniform float p_floor;
uniform sampler2D mg_depth;
uniform mat4 mg_invProj;
varying vec2 mg_uv;

vec3 Load(vec2 o) { return texture2D(mg_scene, mg_uv + o * mg_resolution.zw * max(mg_renderScale, vec2(1.0))).rgb; }

void main() {
    // a b c
    // d e f
    // g h i
    vec3 a = Load(vec2(-1.0, -1.0));
    vec3 b = Load(vec2( 0.0, -1.0));
    vec3 c = Load(vec2( 1.0, -1.0));
    vec3 d = Load(vec2(-1.0,  0.0));
    vec4 e4 = texture2D(mg_scene, mg_uv);
    vec3 e = e4.rgb;
    vec3 f = Load(vec2( 1.0,  0.0));
    vec3 g = Load(vec2(-1.0,  1.0));
    vec3 h = Load(vec2( 0.0,  1.0));
    vec3 i = Load(vec2( 1.0,  1.0));

    // Soft min and max over the cross plus the diagonals (CAS_BETTER_DIAGONALS); 2x bigger, factored out.
    vec3 mn = min(min(min(d, e), min(f, b)), h);
    vec3 mn2 = min(min(min(mn, a), min(c, g)), i);
    mn = mn + mn2;
    vec3 mx = max(max(max(d, e), max(f, b)), h);
    vec3 mx2 = max(max(max(mx, a), max(c, g)), i);
    mx = mx + mx2;

    // Smooth minimum distance to the signal limit divided by the smooth maximum, then shaped.
    vec3 amp = clamp(min(mn, 2.0 - mx) / max(mx, vec3(1.0 / 65536.0)), 0.0, 1.0);
    amp = sqrt(amp);

    // Filter shape:  0 w 0 / w 1 w / 0 w 0
    float peak = -1.0 / mix(8.0, 5.0, clamp(p_sharpness, 0.0, 1.0));
    // Magnified textures right in front of the camera, and the faint steps between their texels, stay unsharpened.
    float depth = texture2D(mg_depth, mg_uv).r;
    vec4 vp = mg_invProj * vec4(vec3(mg_uv, depth) * 2.0 - 1.0, 1.0);
    float near = p_nearFade > 0.0 ? smoothstep(p_nearFade * 0.3, p_nearFade, length(vp.xyz / vp.w)) : 1.0;
    float edge = abs(dot(b + d + f + h - 4.0 * e, vec3(0.2126, 0.7152, 0.0722)));
    float strong = p_floor > 0.0 ? smoothstep(p_floor, p_floor * 3.0, edge) : 1.0;
    vec3 w = amp * peak * near * strong;
    vec3 rcpWeight = 1.0 / (1.0 + 4.0 * w);
    vec3 pix = clamp((b * w + d * w + f * w + h * w + e) * rcpWeight, 0.0, 1.0);
    gl_FragColor = vec4(pix, e4.a);
}
