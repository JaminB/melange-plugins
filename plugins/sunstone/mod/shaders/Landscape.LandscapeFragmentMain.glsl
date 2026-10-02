#version 130
// Sunstone landscape lighting: hemispheric sky/ground ambient, energy-conserving Blinn-Phong, a rim light and fine
// relief taken from the texture, over contact-hardening soft shadows. sunstoneLight 0 keeps the game's own terms.
uniform sampler2D texture0;
uniform sampler2DShadow shadowMap;
uniform vec3 shadowSize;
uniform vec3 globalDiffuse;
uniform vec3 globalAmbient;
uniform vec3 globalSpecular;
uniform vec3 globalFresnel;
// The vertex program's view matrix; column 1 is the world's up axis in eye space.
uniform mat4 view;

// Tunables (shaders/params.ini). Shadow mode 0 = the game's own 3x3 filter, 1 = soft, 2 = soft with contact
// hardening; mode + 10 shows the shadow term alone.
uniform float sunstoneShadowMode;
uniform float sunstoneShadowSoftness;  // kernel step in map texels (1-2); wider steps start to band
uniform float sunstoneShadowContact;   // blocker distance (shadow depth) at which the penumbra is at its widest
uniform float sunstoneShadowBias;      // receiver depth offset (shadow depth), grows on slopes
uniform float sunstoneLight;           // 0 game lighting, 1 Sunstone; + 10 shows the lighting on grey
uniform vec3 sunstoneSky;              // ambient tint for surfaces facing up
uniform vec3 sunstoneGround;           // ambient tint for surfaces facing down
uniform float sunstoneSpecular;        // specular reflectance at normal incidence
uniform float sunstoneGloss;           // Blinn-Phong exponent
uniform float sunstoneRim;             // rim light strength
uniform float sunstoneRelief;          // texture relief depth (world units)
uniform float sunstoneReliefFade;      // distance at which the relief has faded out
uniform float sunstoneSunGain;         // sun (diffuse) gain
uniform float sunstoneAmbientGain;     // ambient gain
uniform float sunstoneShadowAmbient;   // ambient dip inside sun shadows
uniform float sunstoneSplit;           // pixels left of this x keep the game's lighting and shadows (comparisons)

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

float Luma(vec3 c) { return dot(c, vec3(0.299, 0.587, 0.114)); }

// Bump from the texture's brightness: brighter texels stand proud by up to `depth` world units. The surface gradient
// is built from screen-space derivatives of the eye-space position, so no tangents are needed.
vec3 Relief(vec3 n, vec3 p, vec2 uv, float h0, float depth) {
    // Steps shorter than about a texel would only see the bilinear ramp between two texels (stair lines), so
    // magnified textures take a longer step and scale the difference back down.
    vec2 dx = dFdx(uv), dy = dFdy(uv);
    float kx = max(1.0, 0.004 / max(length(dx), 1e-6)), ky = max(1.0, 0.004 / max(length(dy), 1e-6));
    float hx = (Luma(texture2D(texture0, uv + dx * kx).rgb) - h0) / kx;
    float hy = (Luma(texture2D(texture0, uv + dy * ky).rgb) - h0) / ky;
    vec3 sx = dFdx(p), sy = dFdy(p);
    vec3 r1 = cross(sy, n), r2 = cross(n, sx);
    float det = dot(sx, r1);
    vec3 g = sign(det) * (hx * r1 + hy * r2) * depth;
    return normalize(abs(det) * n - g);
}

vec3 GameLight(vec3 n, vec3 v, vec3 l, float lit, vec3 albedo) {
    float ndl = clamp(dot(n, l) * lit, 0.0, 1.0);
    float spec = lit * pow(clamp(dot(n, normalize(l + v)), 0.0, 1.0), 20.0);
    float rim = clamp(pow(max(1.0 - dot(v, n), 0.0), 1.5), 0.0, 1.0);
    vec3 add = globalSpecular * 0.6 * spec + (0.5 + 0.5 * lit) * vec3(0.2, 0.275, 0.175) * globalFresnel * rim;
    return (globalDiffuse * ndl + globalAmbient) * albedo + add;
}

vec3 SunstoneLight(vec3 n, vec3 v, vec3 l, vec3 up, float lit, vec3 albedo, float gloss) {
    float ndl = max(dot(n, l), 0.0);
    float f0 = sunstoneSpecular * gloss;
    float power = max(sunstoneGloss, 1.0);
    vec3 h = normalize(l + v);
    float fres = f0 * (1.0 + 3.0 * pow(1.0 - clamp(dot(l, h), 0.0, 1.0), 5.0));
    float spec = fres * (power + 8.0) / 8.0 * pow(max(dot(n, h), 0.0), power) * ndl * lit;

    float sky = dot(n, up) * 0.5 + 0.5;
    float s = sky * sky * (3.0 - 2.0 * sky);
    vec3 ambient = globalAmbient * sunstoneAmbientGain * mix(sunstoneGround, sunstoneSky, s);
    ambient *= 1.0 - sunstoneShadowAmbient * (1.0 - lit) * clamp(dot(up, l) * 2.0, 0.0, 1.0);

    float edge = pow(max(1.0 - max(dot(n, v), 0.0), 0.0), 3.0);
    float back = clamp(0.5 - 0.5 * dot(v, l), 0.0, 1.0);
    vec3 rim = sunstoneRim * edge * back * lit * globalDiffuse;

    vec3 diffuse = globalDiffuse * sunstoneSunGain * ndl * lit * (1.0 - f0);
    return (diffuse + ambient + rim) * albedo + globalSpecular * spec;
}

// Brightness above the knee rolls off toward white, as film does, so bright sand and stone stay pale rather than
// clipping per channel or turning orange.
vec3 Shoulder(vec3 c) {
    float m = max(c.r, max(c.g, c.b));
    if (m <= 0.9) return c;
    float r = 0.9 + 0.1 * (1.0 - exp((0.9 - m) / 0.1));
    vec3 rolled = mix(c * (r / m), vec3(r), clamp((m - 0.9) / m * 1.5, 0.0, 1.0));
    return mix(rolled, min(c, vec3(1.0)), 0.5);
}

vec4 Shade(float vertexAlpha, vec4 vertexColour, bool useVertexColour) {
    vec3 n = normalize(gl_TexCoord[2].xyz);
    vec3 v = normalize(gl_TexCoord[1].xyz);
    vec3 l = normalize(-gl_TexCoord[3].xyz);
    vec2 uv = gl_TexCoord[0].xy;
    vec4 tex = texture2D(texture0, uv);
    bool left = gl_FragCoord.x < sunstoneSplit;
    float mode = sunstoneLight > 9.5 ? sunstoneLight - 10.0 : sunstoneLight;
    bool showShadow = sunstoneShadowMode > 9.5;
    float shadowMode = left ? 0.0 : (showShadow ? sunstoneShadowMode - 10.0 : sunstoneShadowMode);

    vec3 albedo = sunstoneLight > 9.5 ? vec3(0.5) : tex.rgb;
    vec3 c;
    float lit;
    if (left || mode < 0.5) {
        lit = Shadow(gl_TexCoord[4], shadowMode, dot(n, l));
        c = GameLight(n, v, l, lit, albedo);
    } else {
        vec3 up = view[1].xyz;
        up = dot(up, up) > 0.25 ? normalize(up) : l;
        float h0 = Luma(tex.rgb);
        vec3 p = -gl_TexCoord[1].xyz;
        float fade = 1.0 - smoothstep(0.25, 1.0, length(p) / max(sunstoneReliefFade, 1.0));
        fade *= smoothstep(0.04, 0.2, dot(n, v));
        // Where a texel spans several pixels the relief would only emboss the texel grid, so it fades out.
        vec2 texels = vec2(textureSize(texture0, 0));
        fade *= smoothstep(0.5, 1.0, max(length(dFdx(uv) * texels), length(dFdy(uv) * texels)));
        vec3 nb = Relief(n, p, uv, h0, sunstoneRelief * fade);
        lit = Shadow(gl_TexCoord[4], shadowMode, dot(n, l));
        c = Shoulder(SunstoneLight(nb, v, l, up, lit, albedo, 0.5 + h0));
    }
    if (showShadow) return vec4(vec3(lit), 1.0);
    vec4 o = vec4(clamp(c, 0.0, 1.0), tex.a);
    return useVertexColour ? o * vertexColour : vec4(o.rgb, o.a * vertexAlpha);
}

void main() { gl_FragColor = Shade(gl_Color.a, gl_Color, true); }
