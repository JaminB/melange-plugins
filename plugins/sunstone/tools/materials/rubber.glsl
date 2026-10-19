// @class rubber
// @default scale=1 strength=1 rough=0 wear=0.2 tint=1 a=1 b=0.3
// @param wear: dusty bloom at worn spots (0 none .. 1 a lot): matte and slightly lighter
// @param tint: albedo variation (1 = about 2% either way)
// @param a: relief: the fine moulded grain and the art's wrinkles (1 = the default; 0 = flat)
// @param b: finish (0 = matte rubber, broad dim highlight; 1 = glossy latex or oilskin, tight bright highlight)
// Gloves, seals, soles, hoses: a soft surface whose painted wrinkles become gentle folds that roll the highlight, a
// fine grain (matte) or almost none (latex), and a broad specular that never turns metallic. Colours stay as painted.
// Cost: 3 texture fetches (MatMapWorld = 2, one MatMapAt), no noise calls, no loops.
MatOut mat_rubber(MatIn m) {
    MatOut o = MatNone(m.albedo);
    float fin = clamp(m.p.w, 0.0, 1.0);
    // The art's wrinkles as soft folds (derivatives, so before the early out): 0.05 world units of height per unit of
    // luminance, slope capped at about 0.15 (low-res glove art: its texel steps must not show).
    vec2 e = m.lumD * (0.05 * m.p.z * m.scale);
    float el = length(e);
    e *= min(1.0, 0.15 * m.pxWorld / max(el, 1e-6));
    vec3 fold = MatBumpScreen(m, e);
    if (m.fade <= 0.0) return o;
    float lum = MatLum(m.albedo);
    float body = smoothstep(0.01, 0.06, lum);
    // Fine moulded grain, a tile about 4 world units; latex is almost smooth.
    vec4 g = MatMapWorld(m, MAT_MAP_GRAIN, 4.0 * m.scale, 3.0);
    float rv = MatMapVar(g) * 2.0;
    o.dn = fold + MatMapBump(m, g, 0.18 * m.p.z * (1.0 - 0.7 * fin)) * body;
    // Worn bloom: one fetch of the wear map, about 16 world units a tile, scuffs only (no chips in rubber).
    float F0, fb;
    MatOctave(m, 16.0 * m.scale, F0, fb);
    vec4 w = MatMapAt(m, MAT_MAP_WEAR, F0, vec2(0.71, 0.29));
    float kw = MatMapFade(m, F0, 4.0);
    float worn = smoothstep(1.0 - m.p.x, 1.0 - m.p.x + 0.1, w.a) * kw * body;
    // Light: matte rubber spreads and dims the highlight, latex tightens and brightens it; the grain breaks it a little.
    float gl = mix(0.45, 1.6, fin) * (1.0 - 0.25 * rv * (1.0 - fin));
    float sp = mix(0.6, 1.3, fin);
    o.gloss = mix(1.0, gl * mix(1.0, 0.6, worn), body);
    o.spec = mix(1.0, sp * mix(1.0, 0.75, worn), body);
    o.ao = 1.0 - 0.3 * max(-MatMapHeight(g), 0.0) * m.p.z * body;
    o.albedo = MatVary(m.albedo, 0.02 * m.p.y * body, rv) + (vec3(1.0) - m.albedo) * 0.03 * worn;
    return o;
}
