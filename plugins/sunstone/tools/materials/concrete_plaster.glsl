// @class concrete_plaster
// @default scale=1 strength=1 rough=0 wear=0.2 tint=1 a=0.3 b=0.3
// @param wear: grime in the pores and cracks (0 none, 1 heavy)
// @param tint: albedo variation, broad stains (1 = about 2.5% either way)
// @param a: relief from the art (its luminance as height): 0 none, 1 about 0.4 world units per unit of luminance
// @param b: hairline cracks (a procedural network, no direction): 0 none, 1 strong
// Plaster, render and cast concrete: a hand-trowelled waviness at two sizes, fine pores from the stone map, hairline
// cracks, broad faint stains, very matte; the art's own carving or engraving lit as relief.

// The art's relief: the eye-space normal perturbation of a height of depth world units per unit of the texel's
// luminance. Its slope comes from the art itself at this pixel's footprint: four taps of texture0 on the diagonals, one
// texel of the mip level that fits the pixel away (a Sobel-like gradient of the filtered art), so it is continuous
// where the art is magnified (no per-texel facets, no stair-stepped emboss rims: a pixel-stepped edge becomes a soft
// bevel about two texels wide) and as smooth as the mips where it is minified (screen derivatives of the texel's
// luminance, m.lumD, would alias there). Eased to 60% as texels grow past 3 pixels, capped at a 0.3 slope, faded out at
// grazing views where the footprint is squeezed. No derivative is taken (safe after a per-fragment branch).
vec3 mat_concrete_plaster_art(MatIn m, float depth) {
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
vec3 mat_concrete_plaster_crack(MatIn m, float sizeWorld, float w, float jag) {
    float F0, fb;
    MatOctave(m, sizeWorld, F0, fb);
    vec3 r = vec3(0.0);
    for (int i = 0; i < 2; i++) {
        float f = F0 * (1.0 + float(i));
        vec3 n = MatGNoise(m.uv * f + (6.1 + 9.0 * m.seed), f);
        float t = clamp(abs(n.x + jag) / w, 0.0, 1.0);
        vec3 k = vec3(1.0 - t * t * (3.0 - 2.0 * t), (-6.0 * t * (1.0 - t) / w * sign(n.x + jag) * f) * n.yz);
        r += k * (i == 0 ? 1.0 - fb : fb) * MatFadeUv(m, f / (2.0 * w));
    }
    return r;
}

// One octave-blended gradient noise for features sizeWorld apart: (value, d/duv), faded by its footprint (gone at
// 2 * strict pixels a cell). Both octaves from one lattice offset, so the 2 * F0 octave at blend 1 is the next F0
// octave at blend 0 (no switch of pattern).
vec3 mat_concrete_plaster_wave(MatIn m, float sizeWorld, float offset, float strict) {
    float F0, fb;
    MatOctave(m, sizeWorld, F0, fb);
    vec3 g = mix(MatGNoise(m.uv * F0 + offset, F0) * vec3(1.0, F0, F0), MatGNoise(m.uv * (2.0 * F0) + offset, 2.0 * F0) * vec3(1.0, 2.0 * F0, 2.0 * F0), fb);
    return g * MatFadeUv(m, F0 * (1.0 + fb) * strict);
}

MatOut mat_concrete_plaster(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0) return o;
    o.dn = mat_concrete_plaster_art(m, (0.4 * m.p.z));
    // Trowelled render: broad waves about 9 world units across, 0.7 deep, and trowel strokes about 5 across, 0.15 deep,
    // each gone before a cell is under 4 pixels (what survives at the game's distance is the broad waves' light);
    // broad stains with the waves.
    vec3 g = mat_concrete_plaster_wave(m, 9.0 * m.scale, 2.9, 2.0);
    vec3 t = mat_concrete_plaster_wave(m, 5.0 * m.scale, 11.3, 2.0);
    o.dn += MatBumpUv(m, (g.yz * 0.7 + t.yz * 0.15) * m.scale);
    // Pores: the stone map, a tile about 18 world units across.
    vec4 s = MatMapWorld(m, MAT_MAP_STONE, 18.0 * m.scale, 6.0);
    float h = MatMapHeight(s);
    o.dn += MatMapBump(m, s, 0.3);
    float pit = smoothstep(-0.28, -0.45, h);
    // Hairline cracks, cells about 10 world units across, 0.08 deep (a uniform branch on the parameter).
    if (m.p.w > 0.0) {
        vec3 k = mat_concrete_plaster_crack(m, 10.0 * m.scale, 0.03, 0.08 * h) * m.p.w;
        o.dn += MatBumpUv(m, k.yz * (-0.08 * m.scale));
        pit = max(pit, k.x);
    }
    o.ao = 1.0 - 0.2 * pit;
    o.albedo = MatVary(m.albedo, 0.025 * m.p.y, 1.6 * g.x + 0.4 * h);
    o.albedo *= 1.0 - 0.08 * m.p.x * pit;
    // Very matte, duller still in the pores and cracks.
    o.spec = 0.85 * (1.0 - 0.5 * pit);
    o.gloss = 0.8;
    return o;
}
