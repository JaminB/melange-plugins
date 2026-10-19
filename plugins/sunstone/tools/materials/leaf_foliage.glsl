// @class leaf_foliage
// @default scale=1 strength=1 rough=0 wear=0 tint=1 a=3 b=0
// @param scale: size of the fine vein net (areoles, the cushions between the smallest veins): 1 = cushions about 0.6 world units (map tile 18)
// @param tint: albedo variation (1 = 3% either way)
// @param a: undulation of the blade, waves per texture unit (a whole number): sized to the drawn leaf, not the world
// @param b: translucency bias (-1 none, 0 the default, 1 double)
// Leaves, grass blades, petals, cacti and the odd flower or mushroom atlas. Keyed on the texel: greens (the leaves) get
// the full treatment, other colours (petals, fruit, mushroom caps, a strip of wood) a satin one.
// - The art's own drawn lines are raised in the light: a height from the texel's luminance, its slope taken by central
//   differences of four bilinear taps of the art (texture0) a texel (or a pixel's footprint) apart, so the slope is
//   continuous across texels (no stair-steps on magnified 32..128 px art) and fades once texels go below a pixel and
//   at alpha-cut outlines. Petals and caps get it about twice as deep: soft raised petals, gills and spots.
// - A faint fine vein net (normal only, from the organic map) and a slow undulation of the blade.
// - A waxy cuticle on the leaves (a tighter, slightly stronger highlight), a broad satin sheen on petals and caps.
// - Light through the leaf when the sun is behind it and the eye looks toward it: a modest brightening (at most +12%)
//   by a scalar, so hue and saturation stay exactly and Sunstone's leaf hue shift (applied after) finds the same greens.
// The undulation, the mottle, the extra gloss and the emboss go with the world footprint (gone by 0.45 world units a
// pixel, where a texture repeats many times on screen), so broad flat colour stays flat from afar.
// No derivatives (the bumps are built from m.uv's own frame), so the early return is safe.
// Cost: one gradient noise, two textureGrad of the shared maps (MatMapWorld), four textureGrad of the art, no loops.

MatOut mat_leaf_foliage(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.01) return o;
    vec3 c = m.albedo;
    float mx = max(c.r, max(c.g, c.b)), ch = mx - min(c.r, min(c.g, c.b));
    float S = ch / max(mx, 1e-3);
    // Hue in degrees (0..360), as the host's Hue().
    float H = 0.0;
    if (ch >= 1e-4) {
        float h = mx == c.r ? (c.g - c.b) / ch : (mx == c.g ? 2.0 + (c.b - c.r) / ch : 4.0 + (c.r - c.g) / ch);
        H = fract(h / 6.0) * 360.0;
    }
    // 1 a leaf green (yellow-green to blue-green, some saturation, not black); 0 a petal, fruit, cap or wood.
    float leaf = smoothstep(0.14, 0.3, S) * smoothstep(52.0, 78.0, H) * (1.0 - smoothstep(172.0, 195.0, H))
               * smoothstep(0.05, 0.14, mx);
    float amt = mix(0.35, 1.0, leaf);
    float ipw = 1.0 / max(m.uvPerWorld, 1e-6);   // world units per texture unit
    // 1 up close .. 0 from 0.45 world units a pixel (a worm's head under 30 px): what would repeat per tile goes.
    float kNear = 1.0 - smoothstep(0.2, 0.45, m.pxWorld);

    // ---- the blade's undulation: one gradient noise, a waves per texture unit (wrapping with the texture).
    float F = max(floor(m.p.z + 0.5), 1.0);
    vec3 nz = MatGNoise(m.uv * F + floor(m.seed * vec2(61.0, 37.0)), F);
    float kW = MatFadeUv(m, 4.0 * F) * kNear;
    o.dn = MatBumpUv(m, nz.yz * (0.12 * amt * kW * ipw));

    // ---- the art's drawn lines, raised: height = luminance x 6% of the texture's size on the object (lighter lines
    // up). Central differences of four bilinear taps d apart (a texel, or the pixel's footprint when minified) give a
    // slope that is continuous across texels. Faded from one to three texels a pixel (it would alias), from afar and
    // at alpha-cut outlines; the slope is limited softly (0.15 on leaves, 0.32 on petals and caps, whose raised
    // drawn shapes are their gain), so a hard drawn edge or a seam stays a soft bevel.
    vec2 ts = vec2(textureSize(texture0, 0));
    float texPx = m.uvPx * max(ts.x, ts.y);                       // texels one pixel covers
    float kEmb = (1.0 - smoothstep(1.0, 3.0, texPx)) * mix(0.25, 1.0, kNear);
    vec2 d = max(1.0 / ts, vec2(m.uvPx));
    vec4 tu0 = textureGrad(texture0, m.uv - vec2(d.x, 0.0), m.uvDx, m.uvDy);
    vec4 tu1 = textureGrad(texture0, m.uv + vec2(d.x, 0.0), m.uvDx, m.uvDy);
    vec4 tv0 = textureGrad(texture0, m.uv - vec2(0.0, d.y), m.uvDx, m.uvDy);
    vec4 tv1 = textureGrad(texture0, m.uv + vec2(0.0, d.y), m.uvDx, m.uvDy);
    vec2 dL = vec2(MatLum(tu1.rgb) - MatLum(tu0.rgb), MatLum(tv1.rgb) - MatLum(tv0.rgb)) / (2.0 * d);
    // Not across an alpha-cut outline (the cut-away texels are black: their edge is no drawn line).
    kEmb *= smoothstep(0.35, 0.9, min(min(tu0.a, tu1.a), min(tv0.a, tv1.a)));
    vec3 emb = MatBumpUv(m, dL * (mix(0.14, 0.06, leaf) * kEmb * ipw));
    o.dn += emb / (1.0 + length(emb) / mix(0.32, 0.15, leaf));

    // ---- fine vein net: the organic map's cells as a faint normal only (no cavity, no paint), so no crease lines.
    vec4 s = MatMapWorld(m, MAT_MAP_BUMPS, 12.0 * m.scale, 8.0);
    o.dn += MatMapBump(m, s, mix(0.03, 0.08, leaf));

    // ---- the cuticle: leaves waxy (tighter, a little stronger highlight), petals and caps a broad satin sheen. The
    // extra gloss goes with the world footprint (a whole leaf a speck: no glints, no per-tile sheen from afar).
    float wax = leaf * kNear;
    float satin = (1.0 - leaf) * kNear;
    o.gloss = mix(1.0, 2.2, wax) * mix(1.0, 0.7, satin);
    o.spec = mix(1.0, 1.2, wax) * mix(1.0, 1.6, satin);
    // Satin: a soft lift toward grazing, as a petal's fine hairs and cells scatter (a few percent, the hue kept).
    float graze = 1.0 - m.ndv;
    float sheen = satin * graze * graze * clamp(m.ndl * 0.5 + 0.5, 0.0, 1.0);

    // ---- colour: a faint mottle (hue kept), gone from afar.
    vec3 a = MatVary(c, 0.03 * m.p.y * kW, 2.0 * nz.x);

    // ---- light through the leaf: the sun behind it (n.l < 0) and the eye looking toward the sun, dark texels hardly.
    // A scalar gain (H, S and the leaf hue shift unchanged), at most +12%.
    float back = sqrt(clamp(-m.ndl, 0.0, 1.0));
    float fwd = clamp(-dot(m.v, m.l), 0.0, 1.0);
    float T = clamp(clamp(1.0 + m.p.w, 0.0, 2.0) * 0.5 * mix(0.5, 1.0, leaf) * smoothstep(0.08, 0.35, mx)
                    * back * (0.15 + 0.85 * fwd * fwd), 0.0, 1.0);
    o.albedo = a * (1.0 + 0.12 * T + 0.08 * sheen);
    return o;
}
