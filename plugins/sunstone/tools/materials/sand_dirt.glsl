// @class sand_dirt
// @default scale=1 strength=1 rough=0 wear=0 tint=1 a=1 b=1
// @param tint: albedo mottle (1 = about 3% either way)
// @param a: pebble/clod relief amount (1 normal, 0 none)
// @param b: fine grain amount (1 normal, 0 none)
// Sand, dry earth, sandstone, soil: clods and pebbles (the stone map, tile about 24 units) and fine grain (the grain map,
// tile about 5 units) in the light, matte, with a shallow cavity (never below 0.8, so pits read as relief, not stains).
// Both maps blend the two octaves around their size (MatOctave), so the size never jumps between triangles of different
// texel density. 4 map fetches, no noise.

// A layer about tileWorld units a tile, as MatMapWorld but with one offset for both octaves: where the texel density
// sits on a power of two, floor() in MatOctave flips per pixel between (F, blend 0) and (F/2, blend 1), and both must
// then sample the same pattern (MatMapWorld's two offsets turn that into a pixel-scale maze).
vec4 mat_sand_dirt_map(MatIn m, float layer, float tileWorld, float texels, vec2 off) {
    float F0, fb;
    MatOctave(m, tileWorld, F0, fb);
    vec4 s = mix(MatMapAt(m, layer, F0, off), MatMapAt(m, layer, 2.0 * F0, off), fb);
    return MatMapNeutral(s, MatMapFade(m, F0 * (1.0 + fb), texels));
}

MatOut mat_sand_dirt(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0) return o;
    // Green texels (grass rims on craters) keep little.
    float green = clamp((m.albedo.g - max(m.albedo.r, m.albedo.b)) * 8.0, 0.0, 1.0);
    float k = (1.0 - 0.7 * green) * m.p.z;
    vec4 s = mat_sand_dirt_map(m, MAT_MAP_STONE, 24.0 * m.scale, 4.0, vec2(0.0));
    o.dn = MatMapBump(m, s, 1.1 * k);
    o.ao = 1.0 + 0.4 * k * min(MatMapHeight(s), 0.0);
    o.albedo = MatVary(m.albedo, 0.08 * m.p.y, MatMapVar(s) * 2.0 * (1.0 - 0.5 * green));
    vec4 g = mat_sand_dirt_map(m, MAT_MAP_GRAIN, 5.0 * m.scale, 3.0, vec2(0.17, 0.43));
    o.dn += MatMapBump(m, g, 0.5 * m.p.w);
    o.spec = 0.8 + 0.5 * MatMapVar(g);
    o.gloss = 0.7;
    return o;
}
