#version 130
// Sunstone landscape lighting: hemispheric sky/ground ambient, energy-conserving Blinn-Phong, a rim light, fine
// relief taken from the texture and world-space detail, with foliage-aware diffuse, over contact-hardening soft
// shadows. sunstoneLight 0 keeps the game's own terms.
uniform sampler2D texture0;
uniform sampler2DShadow shadowMap;
uniform vec3 shadowSize;
uniform vec3 globalDiffuse;
uniform vec3 globalAmbient;
uniform vec3 globalSpecular;
uniform vec3 globalFresnel;
// The vertex program's view matrix: columns 0-2 are the world's axes in eye space (column 1 is up), column 3 the
// translation.
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
uniform float sunstoneDetail;          // luminance variation of the world-space detail noise (+/- this fraction)
uniform float sunstoneDetailBump;      // micro-normal strength of the detail noise
uniform float sunstoneDetailFade;      // distance at which the detail has faded out
uniform float sunstoneGrassWrap;       // diffuse wrap on green surfaces
uniform float sunstoneTransmit;        // back-transmission through green surfaces
uniform float sunstonePatch;           // low-frequency brightness patches on green surfaces (+/- this fraction)
uniform float sunstonePatchHue;        // warm and cool patches on green surfaces
uniform float sunstoneGreenSpec;       // specular reduction on green surfaces
uniform float sunstoneGreenWarm;       // warmer sunlight and cooler shade on green surfaces
uniform float sunstoneFoliage;         // meadow hue shift toward yellow-green (degrees)
uniform float sunstoneFoliageCap;      // meadow chroma cap (0 none)
uniform vec3 sunstoneSunTint;          // tint of the direct light
uniform vec3 sunstoneShadowTint;       // tint of the ambient light inside shadows
uniform float sunstoneTint;            // how far the two tints apply (0 none)
uniform float sunstoneDebug;           // 1 world position (fract(pos / 100)); 2 detail; 3 green mask; 4 sun direction
uniform float sunstoneSplit;           // pixels left of this x keep the game's lighting and shadows (comparisons)
uniform float sunstoneRenderScale;      // the scene over the window: 2 at 2x2 supersampling (set by init.lua)

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

float Hash(vec2 p) {
    vec3 q = fract(vec3(p.xyx) * 0.1031);
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

// Value noise in x (0..1) and its derivative in yz.
vec3 NoiseD(vec2 x) {
    vec2 i = floor(x), f = fract(x);
    vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    vec2 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
    float a = Hash(i), b = Hash(i + vec2(1.0, 0.0)), c = Hash(i + vec2(0.0, 1.0)), d = Hash(i + vec2(1.0, 1.0));
    float k1 = b - a, k2 = c - a, k4 = a - b - c + d;
    return vec3(a + k1 * u.x + k2 * u.y + k4 * u.x * u.y, du * vec2(k1 + k4 * u.y, k2 + k4 * u.x));
}

// World position projected on the plane most facing the surface; ax0 and ax1 are the world axes of the plane.
vec2 Project(vec3 pw, vec3 nw, out vec3 ax0, out vec3 ax1) {
    vec3 a = abs(nw);
    if (a.y >= a.x && a.y >= a.z) {
        ax0 = vec3(1.0, 0.0, 0.0);
        ax1 = vec3(0.0, 0.0, 1.0);
    } else if (a.x >= a.z) {
        ax0 = vec3(0.0, 0.0, 1.0);
        ax1 = vec3(0.0, 1.0, 0.0);
    } else {
        ax0 = vec3(1.0, 0.0, 0.0);
        ax1 = vec3(0.0, 1.0, 0.0);
    }
    return vec2(dot(pw, ax0), dot(pw, ax1));
}

// Two octaves (periods 6 and 1.5 world units), each faded out once a pixel covers a quarter of its period so it
// never shimmers. Returns the centred value (about -1..1) in x and its gradient per world unit in yz.
vec3 DetailNoise(vec2 uv, float footprint) {
    vec3 a = NoiseD(uv / 6.0), b = NoiseD(uv / 1.5);
    float wa = 0.65 * (1.0 - smoothstep(1.5, 4.5, footprint));
    float wb = 0.35 * (1.0 - smoothstep(0.375, 1.125, footprint));
    float v = wa * a.x + wb * b.x - 0.5 * (wa + wb);
    vec2 g = wa * a.yz / 6.0 + wb * b.yz / 1.5;
    return vec3(2.0 * v, 2.0 * g);
}

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

float Hue(vec3 c, out float s) {
    float mx = max(c.r, max(c.g, c.b)), C = mx - min(c.r, min(c.g, c.b));
    s = C / max(mx, 1e-4);
    if (C < 1e-4) return 0.0;
    float h = mx == c.r ? (c.g - c.b) / C : (mx == c.g ? 2.0 + (c.b - c.r) / C : 4.0 + (c.r - c.g) / C);
    return fract(h / 6.0) * 360.0;
}

vec3 Hsv(float h, float s, float v) {
    vec3 k = clamp(abs(fract(h / 360.0 + vec3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
    return v * mix(vec3(1.0), k, s);
}

// Pulls the meadow's saturated mid greens toward yellow-green and caps their chroma; green is the texture's foliage
// weight, so painted props and water never move.
vec3 Meadow(vec3 c, float green) {
    if (sunstoneFoliage <= 0.0 || green <= 0.0) return c;
    float S, H = Hue(c, S);
    float mx = max(c.r, max(c.g, c.b));
    float w = smoothstep(0.25, 0.45, S) * smoothstep(100.0, 125.0, H) * (1.0 - smoothstep(155.0, 175.0, H)) * green;
    S = mix(S, min(S, 0.35 + (S - 0.35) * 0.4), w * sunstoneFoliageCap);
    return Hsv(H - sunstoneFoliage * w, S, mx * (1.0 - 0.08 * w * sunstoneFoliageCap));
}

vec3 GameLight(vec3 n, vec3 v, vec3 l, float lit, vec3 albedo) {
    float ndl = clamp(dot(n, l) * lit, 0.0, 1.0);
    float spec = lit * pow(clamp(dot(n, normalize(l + v)), 0.0, 1.0), 20.0);
    float rim = clamp(pow(max(1.0 - dot(v, n), 0.0), 1.5), 0.0, 1.0);
    vec3 add = globalSpecular * 0.6 * spec + (0.5 + 0.5 * lit) * vec3(0.2, 0.275, 0.175) * globalFresnel * rim;
    return (globalDiffuse * ndl + globalAmbient) * albedo + add;
}

// green is the foliage weight (0..1): wrapped diffuse and back-transmission apply to it only.
vec3 SunstoneLight(vec3 n, vec3 v, vec3 l, vec3 up, float lit, vec3 albedo, float gloss, float green) {
    float ndl = max(dot(n, l), 0.0);
    float wrap = sunstoneGrassWrap * green;
    float ndlWrapped = max((dot(n, l) + wrap) / (1.0 + wrap), 0.0);
    float warm = sunstoneGreenWarm * green;
    vec3 sun = globalDiffuse * mix(vec3(1.0), sunstoneSunTint, sunstoneTint) * sunstoneSunGain * mix(vec3(1.0), vec3(1.08, 1.0, 0.78), warm);
    vec3 shadowTint = mix(vec3(1.0), sunstoneShadowTint, sunstoneTint) * mix(vec3(1.0), vec3(0.96, 1.0, 1.08), warm);
    float f0 = sunstoneSpecular * gloss;
    float power = max(sunstoneGloss, 1.0);
    vec3 h = normalize(l + v);
    float fres = f0 * (1.0 + 3.0 * pow(1.0 - clamp(dot(l, h), 0.0, 1.0), 5.0));
    float spec = fres * (power + 8.0) / 8.0 * pow(max(dot(n, h), 0.0), power) * ndl * lit;

    float sky = dot(n, up) * 0.5 + 0.5;
    float s = sky * sky * (3.0 - 2.0 * sky);
    vec3 ambient = globalAmbient * sunstoneAmbientGain * mix(sunstoneGround, sunstoneSky, s);
    ambient *= 1.0 - sunstoneShadowAmbient * (1.0 - lit) * clamp(dot(up, l) * 2.0, 0.0, 1.0);
    ambient *= mix(vec3(1.0), shadowTint, 1.0 - lit);

    float edge = pow(max(1.0 - max(dot(n, v), 0.0), 0.0), 3.0);
    float back = clamp(0.5 - 0.5 * dot(v, l), 0.0, 1.0);
    vec3 rim = sunstoneRim * edge * back * lit * globalDiffuse;

    vec3 diffuse = sun * ndlWrapped * lit * (1.0 - f0);
    float through = pow(clamp(dot(v, -l), 0.0, 1.0), 2.0);
    vec3 transmit = sun * vec3(0.5, 0.6, 0.1) * (sunstoneTransmit * green * through * lit);
    return (diffuse + ambient + rim + transmit) * albedo + globalSpecular * spec;
}

// Brightness above the knee rolls off toward white, as film does, so bright sand and stone stay pale rather than
// clipping per channel or turning orange.
vec3 Shoulder(vec3 c) {
    float m = max(c.r, max(c.g, c.b));
    if (m <= 0.9) return c;
    float r = 0.9 + 0.1 * (1.0 - exp((0.9 - m) / 0.1));
    vec3 rolled = mix(c * (r / m), vec3(r), clamp((m - 0.9) / m * 1.5, 0.0, 1.0));
    return mix(rolled, min(c, vec3(1.0)), 0.75);
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
        if (sunstoneDebug > 3.5) return vec4(0.5 + 0.5 * (transpose(mat3(view)) * l), 1.0);
        vec3 up = view[1].xyz;
        up = dot(up, up) > 0.25 ? normalize(up) : l;
        float h0 = Luma(tex.rgb);
        vec3 p = -gl_TexCoord[1].xyz;
        float dist = length(p);
        float facing = smoothstep(0.04, 0.2, dot(n, v));
        float fade = (1.0 - smoothstep(0.25, 1.0, dist / max(sunstoneReliefFade, 1.0))) * facing;
        // Where a texel spans several pixels the relief would only emboss the texel grid, so it fades out.
        vec2 texels = vec2(textureSize(texture0, 0));
        float texelsPerPixel = max(length(dFdx(uv) * texels), length(dFdy(uv) * texels)) * max(sunstoneRenderScale, 1.0);
        fade *= smoothstep(0.5, 1.0, texelsPerPixel);
        vec3 nb = Relief(n, p, uv, h0, sunstoneRelief * fade);

        // World-space detail: independent of the texture's texels, so it only adds where the texture is magnified
        // and fades with distance.
        float green = smoothstep(0.05, 0.15, tex.g - max(tex.r, tex.b));
        // Full shift on level ground (meadows), less on steep and rounded foliage (tree canopies, bushes).
        albedo = Meadow(albedo, green * mix(0.55, 1.0, smoothstep(0.35, 0.85, dot(n, up))));
        float detail = 0.0;
        if (dot(view[1].xyz, view[1].xyz) > 0.25) {
            mat3 rot = mat3(view);
            vec3 pw = transpose(rot) * (p - view[3].xyz);
            vec3 ax0, ax1;
            vec2 wuv = Project(pw, transpose(rot) * n, ax0, ax1);
            float reach = max(sunstoneDetailFade, 1.0);
            float dw = mix(0.35, 1.0, 1.0 - smoothstep(0.5, 1.0, texelsPerPixel))
                * (1.0 - smoothstep(0.375 * reach, reach, dist)) * facing;
            vec3 dn = DetailNoise(wuv, max(fwidth(wuv.x), fwidth(wuv.y)));
            vec3 ge = rot * (dn.y * ax0 + dn.z * ax1);
            nb = normalize(nb - sunstoneDetailBump * dw * (ge - nb * dot(ge, nb)));
            albedo *= 1.0 + sunstoneDetail * dw * dn.x;
            float patch = 0.55 * NoiseD(wuv / 80.0).x + 0.45 * NoiseD(wuv / 360.0 + 3.1).x;
            albedo *= 1.0 + sunstonePatch * green * 2.0 * (patch - 0.5);
            float hp = NoiseD(wuv / 45.0 + 7.3).x;
            vec3 hueTint = mix(mix(vec3(1.0), vec3(0.94, 1.0, 1.08), 1.0 - smoothstep(0.15, 0.5, hp)), vec3(1.12, 1.03, 0.76),
                               smoothstep(0.5, 0.85, hp));
            albedo *= mix(vec3(1.0), hueTint, sunstonePatchHue * green);
            detail = dn.x * dw;
            if (sunstoneDebug > 0.5 && sunstoneDebug < 1.5) return vec4(fract(pw / 100.0), 1.0);
        }
        if (sunstoneDebug > 1.5 && sunstoneDebug < 2.5) return vec4(vec3(0.5 + 0.5 * detail), 1.0);
        if (sunstoneDebug > 2.5) return vec4(vec3(green), 1.0);
        lit = Shadow(gl_TexCoord[4], shadowMode, dot(n, l));
        float gloss = (0.5 + h0) * (1.0 - sunstoneGreenSpec * green);
        c = Shoulder(SunstoneLight(nb, v, l, up, lit, albedo, gloss, green));
    }
    if (showShadow) return vec4(vec3(lit), 1.0);
    vec4 o = vec4(clamp(c, 0.0, 1.0), tex.a);
    return useVertexColour ? o * vertexColour : vec4(o.rgb, o.a * vertexAlpha);
}

void main() { gl_FragColor = Shade(gl_Color.a, gl_Color, true); }
