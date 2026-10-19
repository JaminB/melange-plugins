// @class rope_straw
// @default scale=1 strength=1 rough=0 wear=1 tint=1 a=1 b=0
// @param a: relief amount (1 default; 1.5 coarse straw)
// @param b: thread tile in world units, 0 = 4
// @param wear: weave (1 the plain-weave map: rope, woven fabric; 0 fibres only, for art that paints its own weave,
//   coils or twigs, so no map pattern is laid over the art's)
// Rope, wicker, straw: the plain-weave map gives twisted fibres and ply gaps as a normal and a cavity (gaps dark,
// crowns light), a few percent thread-to-thread albedo variation, a dull rough sheen. With the weave off, only the fine
// fibres and the sheen.
// Cost: 4 textureGrad (two world-tiled pairs) with the weave, 2 without; no noise.
MatOut mat_rope_straw(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0 || m.strength <= 0.0) return o;   // strength 0 (a texture where it cannot show): no fetches
    float amt = m.p.z, tile = (m.p.w > 0.0 ? m.p.w : 4.0) * m.scale, weave = clamp(m.p.x, 0.0, 1.0);
    // fibres: the brushed layer on a small tile (its scratches stay short, under a world unit), along u
    vec4 f = MatMapWorld(m, MAT_MAP_BRUSHED, tile * 0.75, 3.0);
    o.dn = MatMapBump(m, f, 0.3 * amt);
    o.albedo = MatVary(m.albedo, 0.07 * m.p.y, 0.6 * MatMapVar(f));
    o.gloss = 0.7;
    o.spec = 0.8 + 0.8 * MatMapVar(f);
    if (weave > 0.0) {
        vec4 w = MatMapWorld(m, MAT_MAP_WEAVE, tile, 16.0);
        float h = MatMapHeight(w);
        o.dn += MatMapBump(m, w, 1.1 * amt * weave);
        o.ao = 1.0 + 1.1 * min(h, 0.0) * amt * weave;
        o.albedo = MatVary(o.albedo, 0.07 * m.p.y * weave, 1.8 * MatMapVar(w));
        o.albedo *= 1.0 + 0.08 * weave * clamp(h, -0.3, 0.3);
        o.spec += 0.6 * weave * max(h, 0.0);
    }
    return o;
}
