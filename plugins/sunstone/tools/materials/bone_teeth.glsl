// @class bone_teeth
// @default scale=1 strength=1 rough=0 wear=0.3 tint=1 a=1 b=0
// @param a: pores and hairline cracks (0 none, 1 aged bone, 1.5 fossil)
// @param b: polish (0 dry matte bone, 1 glossy enamel / shell / acrylic)
// @param wear: unused
// Bone, teeth, shell, eggshell: fine pores that catch shade, hairline cracks (cavity and a thin groove in the normal),
// a faint patina in the light. b > 0 turns it into enamel: smoother, a tight sheen broken up by a faint, broad
// waviness (so the highlight is not a plastic dot), almost no pores, and a translucent edge (enamel lets light through
// at grazing angles: a warm lift toward the silhouette).
// Cost: 4 textureGrad (two world-tiled pairs: pores, cracks / waviness), no noise.
MatOut mat_bone_teeth(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0 || m.strength <= 0.0) return o;   // strength 0 (a texture where it cannot show): no fetches
    float amt = m.p.z, pol = clamp(m.p.w, 0.0, 1.0);
    // pores: ~3 world unit tile of 3-texel features
    vec4 g = MatMapWorld(m, MAT_MAP_GRAIN, 3.0 * m.scale, 3.0);
    float h = MatMapHeight(g);
    o.dn = MatMapBump(m, g, 0.9 * amt * (1.0 - 0.7 * pol));
    float pit = max(-h - 0.04, 0.0) * 4.0;
    o.ao = 1.0 - clamp(pit * 0.55 * amt, 0.0, 0.45) * (1.0 - 0.8 * pol);
    // hairline cracks: the crack network of the bark layer, thresholded thin (large tile: few, long cracks); enamel
    // (b > 0.5, where cracks are muted anyway) takes the stone layer's soft fbm relief instead, for its waviness
    bool enamel = pol > 0.5;
    vec4 c = MatMapWorld(m, enamel ? MAT_MAP_STONE : MAT_MAP_BARK, (enamel ? 24.0 : 14.0) * m.scale, 5.0);
    float crack = (1.0 - smoothstep(-0.42, -0.30, MatMapHeight(c))) * (1.0 - pol * 0.7);
    // enamel waviness: the same broad sample as a soft normal (polished surfaces only), so the tight highlight wobbles
    o.dn += MatMapBump(m, c, 0.25 * amt + 0.2 * pol);
    o.ao *= 1.0 - 0.3 * crack * amt;
    // faint patina, darker in cracks and pores
    o.albedo = MatVary(m.albedo, 0.05 * m.p.y * (1.0 - 0.6 * pol), 1.5 * MatMapVar(c) + MatMapVar(g));
    o.albedo *= 1.0 - 0.03 * crack * amt;
    // translucent edge: enamel and shell lift toward the silhouette, a touch warm (dry bone: none)
    float rim = 1.0 - m.ndv;
    rim *= rim;
    o.albedo *= 1.0 + 0.22 * pol * rim * vec3(1.04, 1.0, 0.9);
    // sheen: dry bone a dull satin (rougher in pores), enamel a tight bright highlight
    o.gloss = mix(0.8, 2.4, pol) * (1.0 - 0.6 * pit * (1.0 - pol));
    o.spec = mix(0.9, 1.25, pol) * (1.0 + 2.0 * MatMapVar(g) * (1.0 - pol));
    return o;
}
