// @class brick
// @default scale=1 strength=1 rough=0 wear=0.3 tint=1 a=1.5 b=-1
// @param wear: grime in the mortar joints (0 none, 1 heavy)
// @param tint: albedo variation of the clay (1 = about 3% either way)
// @param a: relief from the art (its luminance as height): 0 none, 1 about 0.4 world units per unit of luminance
// @param b: which way the art's relief goes: -1 the joints are paler than the bricks (they sink), +1 darker (tiles, carved)
// Brick, block and roof tile: the joints set back from the art's own lines (paler or darker by b), sandy and dull, the
// faces fired clay with pits and a faint sheen on their worn tops, edges caught by the light.

// The art's relief: the eye-space normal perturbation of a height of depth world units per unit of the texel's
// luminance. Its slope comes from the art itself at this pixel's footprint: four taps of texture0 on the diagonals, one
// texel of the mip level that fits the pixel away (a Sobel-like gradient of the filtered art), so it is continuous
// where the art is magnified (no per-texel facets, no stair-stepped emboss rims: a pixel-stepped edge becomes a soft
// bevel about two texels wide) and as smooth as the mips where it is minified (screen derivatives of the texel's
// luminance, m.lumD, would alias there). Eased to 60% as texels grow past 3 pixels, capped at a 0.3 slope, faded out at
// grazing views where the footprint is squeezed. No derivative is taken (safe after a per-fragment branch).
// rel: the art's luminance here less the taps' mean (above or below its surroundings), only where a texel covers 1.5
// to 3 pixels or more (a line detector at the pixel's own scale would alias when minified).
vec3 mat_brick_art(MatIn m, float depth, out float rel) {
    rel = 0.0;
    float det = m.uvDx.x * m.uvDy.y - m.uvDx.y * m.uvDy.x;
    if (abs(det) < 1e-14) return vec3(0.0);
    vec2 ts = vec2(textureSize(texture0, 0));
    float tp = max(m.uvPx * max(ts.x, ts.y), 1e-6);
    float lod = max(log2(tp), 0.0);
    vec2 e = exp2(lod) / ts;
    float pp = MatLum(textureLod(texture0, m.uv + e, lod).rgb), mm = MatLum(textureLod(texture0, m.uv - e, lod).rgb);
    float pm = MatLum(textureLod(texture0, m.uv + vec2(e.x, -e.y), lod).rgb), mp = MatLum(textureLod(texture0, m.uv + vec2(-e.x, e.y), lod).rgb);
    vec2 sl = 0.25 * vec2(pp + pm - mp - mm, pp + mp - pm - mm) / e;
    rel = (MatLum(textureLod(texture0, m.uv, lod).rgb) - 0.25 * (pp + pm + mp + mm)) * smoothstep(1.5, 3.0, 1.0 / tp);
    vec3 d = MatBumpUv(m, sl * (depth * (1.0 - 0.4 * smoothstep(3.0, 8.0, 1.0 / tp))));
    // (The footprint's elongation on screen: 1 face on, about 1 / cos of the view angle when grazing.)
    float el = m.uvPx * m.uvPx / abs(det);
    return d * (min(1.0, 0.3 * inversesqrt(max(dot(d, d), 1e-8))) * (1.0 - smoothstep(2.0, 3.6, el)));
}

MatOut mat_brick(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0) return o;
    vec3 c = m.albedo;
    float lum = MatLum(c), mx = max(c.r, max(c.g, c.b));
    float sat = (mx - min(c.r, min(c.g, c.b))) / max(mx, 1e-3);
    // The joint: the art's grey or pale mortar (its saturation low), not snow or white paint (very bright).
    float joint = (1.0 - smoothstep(0.16, 0.32, sat)) * (1.0 - smoothstep(0.7, 0.85, lum));
    // Snow or white paint (bright and grey): not clay, and it sits on top. It keeps the art's relief only on the + side
    // (snow higher than what it lies on) and gets no clay pits or grain.
    float snow = smoothstep(0.7, 0.85, lum) * (1.0 - smoothstep(0.1, 0.25, sat));
    // The art's relief, signed by b: the joints sink. Where the magnified art is lower than its surroundings (darker
    // with b +1, paler with b -1) it is a joint or a gap: a cavity, also where the joint is not grey.
    float sb = mix(m.p.w, abs(m.p.w), snow), rel;
    o.dn = mat_brick_art(m, (0.4 * m.p.z * sb), rel);
    float gap = clamp(-rel * sb * (5.0 * m.p.z), 0.0, 1.0);
    // Fired clay: pits and a sandy grain from the stone map, a tile about 16 world units across.
    vec4 s = MatMapWorld(m, MAT_MAP_STONE, 16.0 * m.scale, 6.0);
    float h = MatMapHeight(s), va = MatMapVar(s);
    o.dn += MatMapBump(m, s, 0.3 * (1.0 - snow));
    float pit = smoothstep(-0.2, -0.4, h) * (1.0 - snow);
    // Cavity in the joints and pits; grime in the joints by wear.
    o.ao = (1.0 - 0.12 * joint) * (1.0 - 0.3 * pit) * (1.0 - 0.25 * gap);
    o.albedo = MatVary(c, 0.03 * m.p.y * (1.0 - joint) * (1.0 - snow), 1.2 * va + 0.5 * h);
    o.albedo *= 1.0 - 0.1 * m.p.x * joint * pit;
    // Joints sandy and dull; brick faces a little sheen on their raised tops.
    o.spec = mix(0.95 + 0.5 * max(h, 0.0), 0.6, joint) * (1.0 - 0.5 * pit);
    o.gloss = mix(1.0 + 0.5 * max(h, 0.0), 0.7, joint);
    // Pay back the joints' cavity on the albedo (the mean brightness stays the art's).
    o.albedo *= 1.0 + 0.025 * joint;
    return o;
}
