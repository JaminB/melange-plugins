// ---- _common.glsl: the material library's shared part (inputs, outputs, helpers). See tools/materials/README.md.
// Spliced into the lit textured model shaders by tools/build_materials.py, after the host's own uniforms (texture0,
// materialMatrix, view, sunstoneLight, sunstoneSplit) and GameTerms(). Every name here starts with Mat or MAT_.

// Melange's texture tag for the texture bound on unit 0: [0] = (class id, scale, strength, roughness bias),
// [1] = (wear, tint variation, class parameter a, class parameter b). All zero for an untagged texture or a Melange
// without texture tags (it then logs that the uniform "stays 0" once at link).
uniform vec4 mg_texTag[2];
uniform float sunstoneMatDetail;   // material detail amount: 0 off, 1 full (Subtle sends 0.5; set by Sunstone)
uniform float sunstoneMatSplit;    // pixels left of this x are drawn without material detail (A/B comparisons)
uniform float sunstoneMatDebug;    // 1 class colours; 2 fade; 3 normal detail; 4 cavity

// Shared material maps (mod/assets/detail/materials.png, made by tools/make_detail_maps.py): eight original tileable
// 256x256 layers in one texture array, bound by init.lua with wum.shaders.setTexture (Melange 0.10; the host shader is
// #version 130 for sampler2DArray). Every channel 0.5 = neutral, which is also what Melange's sampler reads before a
// texture is bound: R,G tangent normal xy (x along +u, y along +v), B height (0.5 the surface, below cavities), A a
// variation about 0.5 (roughness + rougher, or albedo + lighter; the wear order on MAT_MAP_WEAR). Mips are plain
// averages: the normal flattens with distance. The helpers (MatMap...) follow MatFbm; layers and scales:
// tools/materials/README.md.
uniform sampler2DArray sunstoneMat;
const float MAT_MAP_GRAIN = 0.0;    // fine grain and pores (plastic, paint, skin-like matte); A roughness
const float MAT_MAP_WOOD = 1.0;     // wood grain along u with pores; A albedo
const float MAT_MAP_BRUSHED = 2.0;  // brushed metal along u, scratches at all angles; A roughness
const float MAT_MAP_STONE = 3.0;    // stone / concrete: pits, veins, mottle; A albedo
const float MAT_MAP_WEAVE = 4.0;    // plain weave, 16 threads a tile, fibres; A albedo
const float MAT_MAP_BUMPS = 5.0;    // leather / rubber / organic pebbling with creases; A roughness
const float MAT_MAP_WEAR = 6.0;     // chips, scratches, scuffs; A the wear order (worn where A > 1 - wear)
const float MAT_MAP_BARK = 7.0;     // bark fissures along v and a crack network; A albedo
const float MAT_MAP_TEXELS = 256.0; // a layer's size

const vec3 MAT_LUMW = vec3(0.299, 0.587, 0.114);
// Beyond this distance from the camera (world units) detail is gone (and starts going at a third of it).
const float MAT_FADE_FAR = 3000.0;

// What a snippet gets. Eye space = the game's view space (camera at 0; the same units as the world).
struct MatIn {
    vec3 albedo;      // the texel's colour, 0..1 (the base albedo, before Sunstone's leaf hue shift)
    float alpha;      // the texel's alpha
    vec2 uv;          // texture coordinate (GL_REPEAT space: whole numbers are the texture's own wrap)
    vec2 uvDx;        // its screen derivatives, per pixel
    vec2 uvDy;
    float uvPx;       // texture units one pixel covers (the larger axis)
    float uvPerWorld; // texture units per world unit on this triangle (a worm's head is about 12 world units)
    float pxWorld;    // world units one pixel covers here
    float aniso;      // how far the texture is stretched on the surface (1 none; 2 twice as long one way)
    vec3 pos;         // eye-space position
    vec3 wpos;        // world position (props move: prefer uv, which sticks to the surface)
    vec3 n;           // unit normal, eye space (no detail)
    vec3 gu;          // eye-space surface gradient of u (texture units per world unit, steepest direction)
    vec3 gv;          // eye-space surface gradient of v
    vec3 tu;          // unit direction of increasing u along the surface (the cotangent frame; the mesh has none)
    vec3 tv;          // unit direction of increasing v
    vec3 v;           // unit vector toward the eye
    vec3 l;           // unit vector toward the sun
    vec3 up;          // the world's up, eye space
    float ndl;        // dot(n, l), unclamped
    float ndv;        // dot(n, v), at least 0
    float sky;        // 0 facing the ground .. 1 facing the sky
    vec2 lumD;        // screen derivatives (x, y) of the texel's luminance: the art's own edges
    float scale;      // tag: feature size multiplier (1 the snippet's own sizes; 2 twice as big)
    float strength;   // tag: strength (the dispatcher applies it to the result; read it only to shape detail)
    vec4 p;           // tag: (wear, tint variation, class parameter a, class parameter b), see the snippet's @default
    float fade;       // 0..1 distance and grazing-angle fade (the dispatcher applies it; use it to skip work)
    float seed;       // 0..1, differs between textures with different tag parameters
    float tagged;     // 1 the tag came from Melange; 0 the class was guessed from the material
};

// What a snippet returns. MatNone(m.albedo) is "no change"; start from it.
struct MatOut {
    vec3 albedo;      // new albedo (keep the art's hue and value: detail is mostly light, not paint)
    float spec;       // specular scale (1 the material's own)
    float gloss;      // gloss scale, the Blinn-Phong exponent (1 the material's own; < 1 rougher)
    vec3 dn;          // normal perturbation, eye space, added to n before normalising (from MatBumpUv / MatBumpScreen)
    float ao;         // cavity and occlusion, 0..1 (1 none): darkens ambient fully and direct light a third
};

MatOut MatNone(vec3 albedo) {
    return MatOut(albedo, 1.0, 1.0, vec3(0.0), 1.0);
}

float MatLum(vec3 c) {
    return dot(c, MAT_LUMW);
}

// ---- hashes (no sine: stable for big coordinates)
float MatHash12(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}
vec2 MatHash22(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}
vec3 MatHash32(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yxz + 33.33);
    return fract((p3.xxy + p3.yzz) * p3.zyx);
}

// ---- gradient noise on the texture's plane, with its slope: (value about -0.5..0.5, d/dp.x, d/dp.y).
// period > 0 wraps the lattice every period cells: with p = uv * F and period = F (F a whole number) the noise
// repeats with the texture, so a GL_REPEAT seam stays seamless. period 0: no wrap.
vec2 MatGrad(vec2 i, float period) {
    if (period > 0.0) i = mod(i, period);
    return MatHash22(i) * 2.0 - 1.0;
}
vec3 MatGNoise(vec2 p, float period) {
    vec2 i = floor(p), f = fract(p), e = vec2(1.0, 0.0);
    vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0), du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
    vec2 ga = MatGrad(i, period), gb = MatGrad(i + e, period), gc = MatGrad(i + e.yx, period), gd = MatGrad(i + 1.0, period);
    float va = dot(ga, f), vb = dot(gb, f - e), vc = dot(gc, f - e.yx), vd = dot(gd, f - 1.0), k = va - vb - vc + vd;
    return vec3(va + u.x * (vb - va) + u.y * (vc - va) + u.x * u.y * k,
                ga + u.x * (gb - ga) + u.y * (gc - ga) + u.x * u.y * (ga - gb - gc + gd) + du * (u.yx * k + vec2(vb, vc) - va));
}

// ---- footprint: how much of a pattern survives at this pixel. cellsPx = pattern cells per pixel: 1 below 0.25
// (four pixels a cell), 0 from 0.5 (the Nyquist limit), so nothing ever shimmers or crawls.
float MatFadeCells(float cellsPx) {
    return 1.0 - smoothstep(0.25, 0.5, cellsPx);
}
// For a pattern of freq cells per texture unit.
float MatFadeUv(MatIn m, float freq) {
    return MatFadeCells(freq * m.uvPx);
}
// For features sizeWorld world units apart.
float MatFadeWorld(MatIn m, float sizeWorld) {
    return MatFadeCells(m.pxWorld / max(sizeWorld, 1e-4));
}

// Features sizeWorld world units apart, on the texture's plane: F0 (cells per texture unit, a power of two, so the
// pattern repeats with the texture; pass it as MatGNoise's period) and the blend toward the next octave 2 * F0.
// Blend the two octaves with it so the size never jumps between triangles of different texel density.
void MatOctave(MatIn m, float sizeWorld, out float F0, out float blend) {
    float lf = clamp(-log2(max(sizeWorld * m.uvPerWorld, 1e-6)), 0.0, 13.0);
    F0 = exp2(floor(lf));
    blend = lf - floor(lf);
}

// fbm of up to 4 octaves from freq cells per texture unit (a whole number, or 0 period for no wrap), each octave faded
// by its own footprint: (value, d/duv). Lacunarity 2, gain 0.5.
vec3 MatFbm(MatIn m, vec2 uv, float freq, float octaves) {
    vec3 s = vec3(0.0);
    float a = 1.0, f = freq;
    for (int i = 0; i < 4; i++) {
        if (float(i) >= octaves) break;
        float k = MatFadeUv(m, f);
        if (k <= 0.0) break;
        vec3 g = MatGNoise(uv * f + float(i) * 17.31, f);
        s += a * k * vec3(g.x, g.yz * f);
        a *= 0.5;
        f *= 2.0;
    }
    return s;
}

// ---- normal detail. A height field h(uv) in world units with slope dh = (dh/du, dh/dv): the perturbation that tilts
// the normal by it (dh from MatGNoise is per noise cell: multiply its .yz by the frequency and by the height).
vec3 MatBumpUv(MatIn m, vec2 dh) {
    return -(dh.x * m.gu + dh.y * m.gv);
}
// A height with screen derivatives dxy (world units per pixel in x and y), e.g. m.lumD * depth.
vec3 MatBumpScreen(MatIn m, vec2 dxy) {
    vec3 dpx = dFdx(m.pos), dpy = dFdy(m.pos);
    vec3 r1 = cross(dpy, m.n), r2 = cross(m.n, dpx);
    float det = dot(dpx, r1);
    return -(dxy.x * r1 + dxy.y * r2) / (abs(det) > 1e-20 ? det : 1e-20);
}

// ---- shared material maps (sunstoneMat, above). The sample is a vec4; 0.5 in every channel is neutral.
// The raw sample of layer at uvScaled (the map's own coordinates: one tile per unit, e.g. m.uv * 8.0), the mip and
// anisotropy from the sampler. Implicit derivatives: only in uniform control flow, i.e. not after a per-fragment
// branch in a snippet (such as 'if (m.fade <= 0.0) return o;'); MatMapAt is safe anywhere.
vec4 MatMap(float layer, vec2 uvScaled) {
    return texture(sunstoneMat, vec3(uvScaled, layer));
}
// The map tiled freq times per texture unit (a whole number keeps the texture's own wrap seamless) at
// m.uv * freq + offset, with explicit derivatives (the same mip and anisotropy as MatMap, safe in any branch).
vec4 MatMapAt(MatIn m, float layer, float freq, vec2 offset) {
    return textureGrad(sunstoneMat, vec3(m.uv * freq + offset, layer), m.uvDx * freq, m.uvDy * freq);
}
// Footprint fade for a map tiled freq times per texture unit whose features are about texels map texels across:
// 1 while a feature covers four pixels or more, 0 at two (where its lighting would sparkle). The mips flatten the
// normal by themselves; this takes what a snippet derives from the sample (gloss, cavity) to neutral before it aliases.
float MatMapFade(MatIn m, float freq, float texels) {
    return MatFadeUv(m, freq * MAT_MAP_TEXELS / max(texels, 1e-3));
}
// A sample pulled toward neutral (vec4(0.5)): k 1 the sample, 0 neutral (e.g. k = MatMapFade(...)).
vec4 MatMapNeutral(vec4 s, float k) {
    return mix(vec4(0.5), s, k);
}
// A layer sized in world units: a tile about tileWorld world units across (multiply by m.scale yourself), the two
// power-of-two octaves around it blended (MatOctave) so the size never jumps between triangles, faded to neutral by
// the footprint of features texels across. Two samples.
vec4 MatMapWorld(MatIn m, float layer, float tileWorld, float texels) {
    float F0, fb;
    MatOctave(m, tileWorld, F0, fb);
    vec4 s = mix(MatMapAt(m, layer, F0, vec2(0.0)), MatMapAt(m, layer, 2.0 * F0, vec2(0.37, 0.61)), fb);
    return MatMapNeutral(s, MatMapFade(m, F0 * (1.0 + fb), texels));
}
// The eye-space normal perturbation (for MatOut.dn) of a sample's R,G; amount 1 = the map's own slopes.
vec3 MatMapBump(MatIn m, vec4 s, float amount) {
    vec2 t = (s.xy * 2.0 - 1.0) * amount;
    return t.x * m.tu + t.y * m.tv;
}
// A sample's height about the surface (-0.5..0.5, < 0 cavities) and its variation (-0.5..0.5).
float MatMapHeight(vec4 s) {
    return s.z - 0.5;
}
float MatMapVar(vec4 s) {
    return s.w - 0.5;
}

// ---- colour: a variation of up to amount in brightness with a touch of warmth, keeping the art's hue (r: -1..1).
vec3 MatVary(vec3 c, float amount, float r) {
    return c * (1.0 + amount * r * vec3(1.02, 1.0, 0.97));
}

// The inputs for this fragment. Call only in uniform control flow (MatEnabled() is uniform): it takes derivatives.
MatIn MatSetup(vec4 tex, vec2 uv) {
    MatIn m;
    m.albedo = tex.rgb;
    m.alpha = tex.a;
    m.uv = uv;
    m.uvDx = dFdx(uv);
    m.uvDy = dFdy(uv);
    m.uvPx = max(length(m.uvDx), length(m.uvDy));
    m.pos = -gl_TexCoord[1].xyz;
    m.wpos = (m.pos - view[3].xyz) * mat3(view);
    m.n = normalize(gl_TexCoord[2].xyz);
    m.v = normalize(gl_TexCoord[1].xyz);
    m.l = normalize(-gl_TexCoord[3].xyz);
    vec3 up = view[1].xyz;
    m.up = dot(up, up) > 0.25 ? normalize(up) : m.l;
    m.ndl = dot(m.n, m.l);
    m.ndv = max(dot(m.n, m.v), 0.0);
    m.sky = dot(m.n, m.up) * 0.5 + 0.5;
    float lum = MatLum(tex.rgb);
    m.lumD = vec2(dFdx(lum), dFdy(lum));
    // The cotangent frame (no tangents in the mesh): surface gradients of u and v from the screen derivatives.
    vec3 dpx = dFdx(m.pos), dpy = dFdy(m.pos);
    vec3 r1 = cross(dpy, m.n), r2 = cross(m.n, dpx);
    float det = dot(dpx, r1);
    det = abs(det) > 1e-20 ? det : 1e-20;
    m.gu = (r1 * m.uvDx.x + r2 * m.uvDy.x) / det;
    m.gv = (r1 * m.uvDx.y + r2 * m.uvDy.y) / det;
    float gu2 = dot(m.gu, m.gu), gv2 = dot(m.gv, m.gv);
    m.tu = gu2 > 1e-24 ? m.gu * inversesqrt(gu2) : normalize(cross(m.n, vec3(0.31, 0.95, 0.0)));
    m.tv = gv2 > 1e-24 ? m.gv * inversesqrt(gv2) : normalize(cross(m.tu, m.n));
    float areaW = length(cross(dpx, dpy));
    float areaUv = abs(m.uvDx.x * m.uvDy.y - m.uvDx.y * m.uvDy.x);
    m.uvPerWorld = max(sqrt(areaUv / max(areaW, 1e-24)), 1e-6);
    m.pxWorld = sqrt(areaW);
    float tt = gu2, bb = gv2, tb = dot(m.gu, m.gv), tr = tt + bb, dg = max(tt * bb - tb * tb, 1e-36);
    float sa = sqrt(max(tr * tr - 4.0 * dg, 0.0));
    m.aniso = sqrt(max((tr + sa) / max(tr - sa, 1e-30), 1.0));
    float d = length(m.pos);
    m.fade = (1.0 - smoothstep(MAT_FADE_FAR / 3.0, MAT_FADE_FAR, d)) * smoothstep(0.03, 0.2, m.ndv);
    m.scale = 1.0;
    m.strength = 1.0;
    m.p = vec4(0.0);
    m.seed = 0.0;
    m.tagged = 0.0;
    return m;
}
// ---- end _common.glsl
