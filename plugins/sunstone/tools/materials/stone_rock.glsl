// @class stone_rock
// @default scale=1 strength=1 rough=0 wear=0.25 tint=1 a=0.5 b=0
// @param wear: grime and moss in the pits and cracks (0 none, 1 heavy)
// @param tint: albedo variation (1 = mottle and veins about 3% either way)
// @param a: relief carved from the art (its luminance as height): 0 none, 1 about 0.4 world units per unit of luminance;
//   negative: polished, glassy stone (obsidian, polished marble) by -a: no art relief, pits or grain, a sharp sheen
// @param b: hairline cracks (a procedural network, no direction): 0 none, 1 strong
// Rock, carved and cut stone: the art's own carving lit as relief, broad hewn undulation, a pitted grain from the stone
// map sized in world units, cavity and dull sheen in the pits, faint veins and mottle, optional cracks and grime.
// Atlases: very saturated texels (a red glove, crate paint, flesh, glowing magma) are not stone and keep only a little
// of the art's relief.

// The art's relief: the eye-space normal perturbation of a height of depth world units per unit of the texel's
// luminance. Its slope comes from the art itself at this pixel's footprint: four taps of texture0 on the diagonals, one
// texel of the mip level that fits the pixel away (a Sobel-like gradient of the filtered art), so it is continuous
// where the art is magnified (no per-texel facets, no stair-stepped emboss rims: a pixel-stepped edge becomes a soft
// bevel about two texels wide) and as smooth as the mips where it is minified (screen derivatives of the texel's
// luminance, m.lumD, would alias there). Eased to 60% as texels grow past 3 pixels, capped at a 0.3 slope, faded out at
// grazing views where the footprint is squeezed. No derivative is taken (safe after a per-fragment branch).
vec3 mat_stone_rock_art(MatIn m, float depth) {
    float det = m.uvDx.x * m.uvDy.y - m.uvDx.y * m.uvDy.x;
    if (abs(det) < 1e-14) return vec3(0.0);
    vec2 ts = vec2(textureSize(texture0, 0));
    float tp = max(m.uvPx * max(ts.x, ts.y), 1e-6);
    float lod = max(log2(tp), 0.0);
    vec2 e = exp2(lod) / ts;
    float pp = MatLum(textureLod(texture0, m.uv + e, lod).rgb), mm = MatLum(textureLod(texture0, m.uv - e, lod).rgb);
    float pm = MatLum(textureLod(texture0, m.uv + vec2(e.x, -e.y), lod).rgb), mp = MatLum(textureLod(texture0, m.uv + vec2(-e.x, e.y), lod).rgb);
    vec2 sl = 0.25 * vec2(pp + pm - mp - mm, pp + mp - pm - mm) / e;
    vec3 d = MatBumpUv(m, sl * (depth * (1.0 - 0.4 * smoothstep(3.0, 8.0, 1.0 / tp))));
    // (The footprint's elongation on screen: 1 face on, about 1 / cos of the view angle when grazing.)
    float el = m.uvPx * m.uvPx / abs(det);
    return d * (min(1.0, 0.3 * inversesqrt(max(dot(d, d), 1e-8))) * (1.0 - smoothstep(2.0, 3.6, el)));
}

// Hairline cracks: where gradient noise crosses zero, a closed network with no direction, cells about sizeWorld apart
// (the two octaves blended as MatOctave does, from one lattice offset so the blend is continuous across octaves).
// jag (a fine height, e.g. the pores') makes the lines ragged instead of smooth loops; its own slope is left out.
// Returns (crack 0..1, d crack / duv); a crack's line is about w of a cell wide, faded out before it is under 2 pixels.
vec3 mat_stone_rock_crack(MatIn m, float sizeWorld, float w, float jag) {
    float F0, fb;
    MatOctave(m, sizeWorld, F0, fb);
    vec3 r = vec3(0.0);
    for (int i = 0; i < 2; i++) {
        float f = F0 * (1.0 + float(i));
        vec3 n = MatGNoise(m.uv * f + (3.7 + 9.0 * m.seed), f);
        float t = clamp(abs(n.x + jag) / w, 0.0, 1.0);
        vec3 k = vec3(1.0 - t * t * (3.0 - 2.0 * t), (-6.0 * t * (1.0 - t) / w * sign(n.x + jag) * f) * n.yz);
        r += k * (i == 0 ? 1.0 - fb : fb) * MatFadeUv(m, f / (2.0 * w));
    }
    return r;
}

MatOut mat_stone_rock(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0) return o;
    vec3 c = m.albedo;
    float lum = MatLum(c), mx = max(c.r, max(c.g, c.b));
    float st = 1.0 - smoothstep(0.74, 0.86, (mx - min(c.r, min(c.g, c.b))) / max(mx, 1e-3));
    // Polish (a < 0): the pits and grain ground away, the undulation mostly, a glassy sheen.
    float pol = clamp(-m.p.z, 0.0, 1.0), rgh = 1.0 - pol;
    // The art's relief: brighter is higher.
    o.dn = mat_stone_rock_art(m, (0.4 * max(m.p.z, 0.0) * (0.4 + 0.6 * st)));
    // Hewn undulation about 5 world units across, 0.2 deep: flat faces stop looking flat. Both octaves from one
    // lattice offset, so the 2 * F0 octave at blend 1 is the next F0 octave at blend 0 (no switch between patterns).
    float F0, fb;
    MatOctave(m, 5.0 * m.scale, F0, fb);
    vec3 g = mix(MatGNoise(m.uv * F0 + 5.3, F0) * vec3(1.0, F0, F0), MatGNoise(m.uv * (2.0 * F0) + 5.3, 2.0 * F0) * vec3(1.0, 2.0 * F0, 2.0 * F0), fb);
    o.dn += MatBumpUv(m, g.yz * (0.2 * m.scale * st * (1.0 - 0.75 * pol) * MatFadeUv(m, F0 * (1.0 + fb))));
    // Pitted grain and veins: the stone map, a tile about 28 world units across.
    vec4 s = MatMapWorld(m, MAT_MAP_STONE, 28.0 * m.scale, 6.0);
    float h = MatMapHeight(s) * (st * rgh), va = MatMapVar(s) * st;
    o.dn += MatMapBump(m, s, 0.35 * st * rgh);
    float pit = smoothstep(-0.22, -0.42, h);
    // Hairline cracks, cells about 7 world units across, 0.12 deep (a uniform branch on the parameter).
    if (m.p.w > 0.0) {
        vec3 k = mat_stone_rock_crack(m, 7.0 * m.scale, 0.04, 0.08 * MatMapHeight(s)) * (m.p.w * st);
        o.dn += MatBumpUv(m, k.yz * (-0.12 * m.scale));
        pit = max(pit, k.x);
        va -= 0.25 * k.x;
    }
    // Cavity in the pits and cracks; grime there (moss where they face the sky) by wear.
    o.ao = 1.0 - 0.35 * pit;
    o.albedo = MatVary(c, 0.03 * m.p.y, 1.5 * min(va + 0.1 * st, 0.0) + 0.5 * h + 0.4 * st * g.x);
    float grime = pit * m.p.x * 0.35;
    o.albedo *= mix(vec3(1.0), mix(vec3(0.85), vec3(0.84, 0.95, 0.78), smoothstep(0.55, 0.9, m.sky)), grime);
    // Dull in the pits and on dark art, a faint polish on raised grain and pale worn faces; glassy when polished.
    o.spec = mix(1.0, 0.8 + 0.45 * lum, st) * (1.0 - 0.6 * pit + 0.4 * max(h, 0.0)) * (1.0 + 0.6 * pol);
    o.gloss = (1.0 + st * (0.6 * max(h, 0.0) - 0.1) - 0.3 * pit) * (1.0 + 1.5 * pol);
    return o;
}
