// @class plastic
// @default scale=1 strength=1 rough=0 wear=0.15 tint=1 a=1 b=1
// @param wear: how scuffed the shell is (0 factory fresh .. 1 well used); scuffs change only the sheen
// @param tint: albedo variation (1 = about 1.5% either way)
// @param a: moulding micro-texture amount (1 = the default; 0 = a smooth shell: lenses, film, card)
// @param b: clear-coat gloss multiplier (1 = a little glossier than the game's; 0.5 = satin)
// Moulded toys, shells, casings: a fine orange-peel micro-texture of the moulding and soft scuffs that dull the gloss
// (a hair lighter, never dented or darkened). Clean and glossy-ish: the colours stay, the sheen gets a little sharper
// and breaks up a little. No bevel from the art's edges: the bilinear texel luminance shows its grid when magnified,
// halos light shapes, and there is no window where it is both smooth and free of shimmer.
// Cost: 3 texture fetches, no noise calls, no derivatives of its own.
MatOut mat_plastic(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0) return o;
    // Nearly black texels (lenses, trim, gaps) take less of the paint-like detail.
    float paint = smoothstep(0.03, 0.12, MatLum(m.albedo));
    // The moulding micro-texture: grain tile about 5 world units (a worm's head is 12).
    vec4 g = MatMapWorld(m, MAT_MAP_GRAIN, 5.0 * m.scale, 3.0);
    o.dn = MatMapBump(m, g, 0.15 * m.p.z) * paint;
    // Scuffs: the wear map about 16 world units a tile, two octaves blended (no size jump at UV-island seams) and
    // faded to neutral by the footprint; the wear order past 1 - wear is scuffed. Sheen only: no bump, no cavity.
    vec4 w = MatMapWorld(m, MAT_MAP_WEAR, 16.0 * m.scale, 4.0);
    float worn = smoothstep(1.0 - m.p.x, 1.0 - m.p.x + 0.16, w.a) * paint;
    // Light: a clear coat a little sharper than the game's, rougher where scuffed and by the grain's own variation.
    float rg = MatMapVar(g) * 2.0 * m.p.z;   // a = 0 (lenses): an unbroken sheen
    o.gloss = mix(1.0, (1.0 + 0.35 * m.p.w) * mix(1.0, 0.65, worn) * (1.0 - 0.2 * rg), paint);
    o.spec = mix(1.0, (1.05 + 0.1 * m.p.w) * mix(1.0, 0.75, worn) * (1.0 + 0.2 * rg), paint);
    // A faint mottle and a hair (1%) of lightening where scuffed.
    o.albedo = MatVary(m.albedo, 0.03 * m.p.y * paint, rg) + (vec3(1.0) - m.albedo) * 0.01 * worn;
    return o;
}
