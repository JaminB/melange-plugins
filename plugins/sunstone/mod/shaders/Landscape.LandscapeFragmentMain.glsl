#version 120
// Sunstone soft shadows for the landscape. Same lighting terms as the game (sun diffuse and specular, ambient, a
// fresnel rim), with the shadow lookup replaced by a smooth wide PCF kernel whose width follows a blocker estimate.
uniform sampler2D texture0;
uniform sampler2DShadow shadowMap;
uniform vec3 shadowSize;
uniform vec3 globalDiffuse;
uniform vec3 globalAmbient;
uniform vec3 globalSpecular;
uniform vec3 globalFresnel;

// Tunables (shaders/params.ini). Mode 0 = the game's own 3x3 filter, 1 = soft, 2 = soft with contact hardening;
// mode + 10 shows the shadow term alone.
uniform float sunstoneShadowMode;
uniform float sunstoneShadowSoftness;  // kernel step in map texels (1-2); wider steps start to band
uniform float sunstoneShadowContact;   // blocker distance (shadow depth) at which the penumbra is at its widest
uniform float sunstoneShadowBias;      // receiver depth offset (shadow depth), grows on slopes

float Cmp(vec2 uv, float z) { return shadow2D(shadowMap, vec3(uv, z)).r; }

float EngineFilter(vec3 p, vec2 texel) {
    float s = 0.0;
    for (int y = -1; y <= 1; ++y)
        for (int x = -1; x <= 1; ++x) s += Cmp(p.xy + vec2(float(x), float(y)) * texel, p.z);
    return s / 9.0;
}

// Separable tent-like kernels built from bilinear comparison taps placed between texels, so a wide footprint
// needs few taps and has no noise. `size` is the grid the kernel runs on (the map size, or coarser to widen it).
vec2 Lattice(vec2 uv, float size, out vec2 st) {
    vec2 g = uv * size;
    vec2 b = floor(g + 0.5);
    st = g + 0.5 - b;
    return b - 0.5;
}

float Kernel3(vec3 p, float size) {
    vec2 st;
    vec2 b = Lattice(p.xy, size, st);
    vec2 w0 = 3.0 - 2.0 * st, w1 = 1.0 + 2.0 * st;
    vec2 o0 = (2.0 - st) / w0 - 1.0, o1 = st / w1 + 1.0;
    float inv = 1.0 / size, s = 0.0;
    s += w0.x * w0.y * Cmp((b + vec2(o0.x, o0.y)) * inv, p.z);
    s += w1.x * w0.y * Cmp((b + vec2(o1.x, o0.y)) * inv, p.z);
    s += w0.x * w1.y * Cmp((b + vec2(o0.x, o1.y)) * inv, p.z);
    s += w1.x * w1.y * Cmp((b + vec2(o1.x, o1.y)) * inv, p.z);
    return s / 16.0;
}

float Kernel7(vec3 p, float size) {
    vec2 st;
    vec2 b = Lattice(p.xy, size, st);
    vec2 w[4];
    vec2 o[4];
    w[0] = 5.0 * st - 6.0;
    w[1] = 11.0 * st - 28.0;
    w[2] = -(11.0 * st + 17.0);
    w[3] = -(5.0 * st + 1.0);
    o[0] = (4.0 * st - 5.0) / w[0] - 3.0;
    o[1] = (4.0 * st - 16.0) / w[1] - 1.0;
    o[2] = -(7.0 * st + 5.0) / w[2] + 1.0;
    o[3] = -st / w[3] + 3.0;
    float inv = 1.0 / size, s = 0.0;
    for (int j = 0; j < 4; ++j)
        for (int i = 0; i < 4; ++i) s += w[i].x * w[j].y * Cmp((b + vec2(o[i].x, o[j].y)) * inv, p.z);
    return s / 2704.0;
}

const vec2 kSearch[8] = vec2[8](
    vec2(-0.71, -0.39), vec2(0.17, -0.94), vec2(0.83, -0.33), vec2(0.62, 0.55),
    vec2(-0.05, 0.74), vec2(-0.86, 0.43), vec2(-0.21, -0.12), vec2(0.36, 0.18));

float Shadow(vec4 sp, float mode, float nl) {
    vec3 p = sp.xyz / sp.w;
    if (p.x < 0.0 || p.x > 1.0 || p.y < 0.0 || p.y > 1.0) return 1.0;
    vec2 texel = 1.0 / shadowSize.xy;
    if (mode < 0.5) return EngineFilter(p, texel);

    // Receivers facing away from the sun shade themselves; that also hides the depth stripes (acne) there. A
    // slope-scaled offset keeps grazing lit slopes clean.
    float facing = smoothstep(-0.02, 0.1, nl);
    if (facing <= 0.0) return 0.0;
    p.z -= sunstoneShadowBias * (1.0 + 4.0 * (1.0 - clamp(nl, 0.0, 1.0)));

    // Kernel7 spans 3.5 grid cells each side.
    float size = shadowSize.x;
    float softGrid = size / clamp(sunstoneShadowSoftness, 1.0, 2.0);
    if (mode < 1.5) return facing * Kernel7(p, softGrid);

    // Blocker estimate from comparisons alone: the share of search taps occluded by something at least t closer
    // to the light, for a few t, integrates to the mean blocker distance.
    float d = max(sunstoneShadowContact, 1e-5);
    float r = 3.5 / softGrid;
    float o0 = 0.0, o1 = 0.0, o2 = 0.0;
    for (int i = 0; i < 8; ++i) {
        vec2 uv = p.xy + kSearch[i] * r;
        o0 += 1.0 - Cmp(uv, p.z);
        o1 += 1.0 - Cmp(uv, p.z - d * 0.25);
        o2 += 1.0 - Cmp(uv, p.z - d * 0.6);
    }
    if (o0 < 0.5) return facing;
    float mean = clamp((0.125 * (o0 + o1) + 0.175 * (o1 + o2) + 0.4 * o2) / o0, 0.0, 1.0);
    float sharp = Kernel3(p, size);
    if (mean < 0.02) return facing * sharp;
    return facing * mix(sharp, Kernel7(p, softGrid), smoothstep(0.0, 1.0, mean));
}

void main() {
    bool show = sunstoneShadowMode > 9.5;
    vec3 n = normalize(gl_TexCoord[2].xyz);
    vec3 v = normalize(gl_TexCoord[1].xyz);
    vec3 l = normalize(-gl_TexCoord[3].xyz);
    float lit = Shadow(gl_TexCoord[4], show ? sunstoneShadowMode - 10.0 : sunstoneShadowMode, dot(n, l));
    float ndl = clamp(dot(n, l) * lit, 0.0, 1.0);
    float spec = lit * pow(clamp(dot(n, normalize(l + v)), 0.0, 1.0), 20.0);
    float rim = clamp(pow(max(1.0 - dot(v, n), 0.0), 1.5), 0.0, 1.0);
    vec3 base = globalDiffuse * ndl + globalAmbient;
    vec3 add = globalSpecular * 0.6 * spec + (0.5 + 0.5 * lit) * vec3(0.2, 0.275, 0.175) * globalFresnel * rim;
    vec4 tex = texture2D(texture0, gl_TexCoord[0].xy);
    gl_FragColor = show ? vec4(vec3(lit), 1.0) : vec4(clamp(base * tex.rgb + add, 0.0, 1.0), tex.a) * gl_Color;
}
