// @class paper_card
// @default scale=1 strength=1 rough=0 wear=0.3 tint=1 a=1 b=0
// @param a: tooth and cockle amount (0.5 smooth coated, 1 paper, 1.6 cardboard)
// @param b: coating (0 matt, 1 glossy coated card / wrapping)
// @param wear: unused
// Paper and card: a fine isotropic tooth (soft grain, slight cavity in its pits) up close; from afar the light: a
// broad, faint cockle that breaks up the highlight, a matt sheen (dull and wide; coated card a satin one) and the soft
// whitening paper shows toward grazing angles. Blue-dominant texels (a metal clip or plastic part in a paper atlas)
// get none of it: paper and card art is warm or neutral.
// Cost: 4 textureGrad (two world-tiled pairs: tooth, cockle), no noise.
MatOut mat_paper_card(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0 || m.strength <= 0.0) return o;   // strength 0 (a texture where it cannot show): no fetches
    float amt = m.p.z, coat = clamp(m.p.w, 0.0, 1.0);
    float paper = 1.0 - smoothstep(0.0, 0.06, m.albedo.b - max(m.albedo.r, m.albedo.g));
    // tooth: fine grain, ~2.5 world unit tile of 3-texel features (no direction, no long strokes)
    vec4 g = MatMapWorld(m, MAT_MAP_GRAIN, 2.5 * m.scale, 3.0);
    // cockle: the stone layer's soft relief on a large tile, only as a gentle normal (a sheet is never quite flat)
    vec4 k = MatMapWorld(m, MAT_MAP_STONE, 18.0 * m.scale, 4.0);
    o.dn = (MatMapBump(m, g, 0.5 * amt * (1.0 - 0.5 * coat)) + MatMapBump(m, k, 0.22 * amt)) * paper;
    o.ao = 1.0 + 0.8 * min(MatMapHeight(g), 0.0) * amt * (1.0 - 0.5 * coat) * paper;
    o.albedo = MatVary(m.albedo, 0.03 * m.p.y * paper, MatMapVar(g) + 0.5 * MatMapVar(k));
    // grazing whitening of a matt sheet (a coated one keeps it in the highlight)
    float rim = 1.0 - m.ndv;
    rim *= rim * rim;
    o.albedo *= 1.0 + 0.10 * (1.0 - 0.6 * coat) * rim * paper;
    // matt: a dull, wide sheen, slightly rougher in the tooth's pits; coated: satin
    float gl = mix(0.45, 1.4, coat) * (1.0 + 0.3 * MatMapVar(g));
    float sp = mix(0.45, 1.3, coat);
    o.gloss = mix(1.0, gl, paper);
    o.spec = mix(1.0, sp, paper);
    return o;
}
