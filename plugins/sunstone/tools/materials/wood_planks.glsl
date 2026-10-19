// @class wood_planks
// @default scale=1 strength=1 rough=0 wear=0.25 tint=1 a=0.3 b=1
// @param wear: scuffs and scratches (0 none .. 1 battered): rougher, a touch lighter, dented
// @param tint: grain albedo variation (1 = about 4% either way along the latewood)
// @param a: relief from the art itself, world units of depth per unit of the texel's luminance (dark seams, gaps and
// @param a: grain lines sink, light boards rise); 0 off
// @param b: grain direction 0 along u, 1 along v; add 2 for pale weathered (grey) wood: low saturation is then wood,
// @param b: and only dark greys count as metal
// Planks, crates, fences, barrels, handles. The cartoon art already paints its grain, knots and seams: the snippet
// lifts them into relief (the art's own luminance as a height), lays a fine fibre and pore grain along the art's grain
// (the shared wood map, stretched across), gives latewood a faint sheen, and dents and scuffs the surface with the
// wear map. In atlases the texel decides: wood hues get everything; greys get metal (smooth, brighter, tighter
// highlight, no grain); other paint keeps a weaker grain. Hue and value stay; albedo moves a few percent at most.

// The art's luminance slope (per texture unit) from three bilinear samples of texture0 on a circle a texel across
// (wider when minified), fitted with a plane. Unlike the screen derivative of the bilinear sample (constant within a
// texel, so seams light up as texel-grid stairs) it is continuous across texels. Also returns texels per pixel.
vec2 mat_wood_planks_art(MatIn m, out float texPx) {
    vec2 ts = vec2(textureSize(texture0, 0));
    texPx = m.uvPx * max(ts.x, ts.y);
    vec2 h = max(1.0 / ts, vec2(m.uvPx));
    vec2 d1 = vec2(1.0, 0.0), d2 = vec2(-0.5, 0.8660254), d3 = vec2(-0.5, -0.8660254);
    float l1 = MatLum(textureGrad(texture0, m.uv + h * d1, m.uvDx, m.uvDy).rgb);
    float l2 = MatLum(textureGrad(texture0, m.uv + h * d2, m.uvDx, m.uvDy).rgb);
    float l3 = MatLum(textureGrad(texture0, m.uv + h * d3, m.uvDx, m.uvDy).rgb);
    return (2.0 / 3.0) * (l1 * d1 + l2 * d2 + l3 * d3) / h;
}

// The shared wood map along the texture's grain (swap: the grain runs along v), sized in world units like MatMapWorld,
// squeezed twice across the grain for long fibres: (sample, fade). Two textureGrad fetches.
vec4 mat_wood_planks_grain(MatIn m, float tileWorld, bool swap, out float k) {
    float F0, fb;
    MatOctave(m, tileWorld, F0, fb);
    vec2 uv = swap ? m.uv.yx : m.uv, dx = swap ? m.uvDx.yx : m.uvDx, dy = swap ? m.uvDy.yx : m.uvDy;
    vec2 f = vec2(F0, 2.0 * F0);
    vec4 s = mix(textureGrad(sunstoneMat, vec3(uv * f, MAT_MAP_WOOD), dx * f, dy * f),
                 textureGrad(sunstoneMat, vec3(uv * 2.0 * f + vec2(0.37, 0.61), MAT_MAP_WOOD), dx * 2.0 * f, dy * 2.0 * f), fb);
    k = MatMapFade(m, 2.0 * F0 * (1.0 + fb), 6.0);
    return MatMapNeutral(s, k);
}

MatOut mat_wood_planks(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.01) return o;
    float bp = m.p.w;
    bool swap = mod(bp, 2.0) >= 0.5;
    bool pale = bp >= 1.5;
    vec3 ta = swap ? m.tv : m.tu, tc = swap ? m.tu : m.tv;   // along and across the grain

    // What the texel is: wood (warm hues, or any low saturation on pale wood), metal (greys), or other paint.
    vec3 c = m.albedo;
    float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
    float sat = (mx - mn) / max(mx, 1e-3), lum = MatLum(c);
    // Hue as the angle of (r - g, g - b), 0 red; wood lies from red-orange to yellow, around 30 degrees.
    // (Guarded: atan(0, 0) is undefined, and every pure grey or black texel has it.)
    float hy = sqrt(3.0) * (c.g - c.b), hx = 2.0 * c.r - c.g - c.b;
    float hue = degrees(atan(hy, hx + (abs(hx) + abs(hy) < 1e-5 ? 1e-5 : 0.0)));
    float warm = 1.0 - smoothstep(32.0, 46.0, abs(hue - 28.0));
    float grey = 1.0 - smoothstep(0.12, 0.24, sat);
    // (Near-white is paint or whitewash, not metal: bright fittings are rare, white boards common.)
    float metal = grey * (pale ? 1.0 - smoothstep(0.38, 0.5, mx) : smoothstep(0.1, 0.22, mx) * (1.0 - smoothstep(0.7, 0.8, mx)));
    float wood = pale ? 1.0 - metal : warm * smoothstep(0.16, 0.3, sat);
    float paint = max(1.0 - wood - metal, 0.0);

    // Relief from the art: its luminance as a height (dL/du, dL/dv). Softer where one texel spans many pixels (big soft
    // bilinear bumps) and where many texels share a pixel (it would sparkle).
    float texPx;
    vec2 dL = mat_wood_planks_art(m, texPx);
    float artK = m.p.z * m.scale * mix(0.3, 1.0, smoothstep(0.12, 0.45, texPx)) * (1.0 - 0.75 * smoothstep(1.0, 3.0, texPx));
    vec3 s = MatBumpUv(m, dL * artK);
    o.dn = s * inversesqrt(1.0 + dot(s, s)) * (1.0 - 0.5 * metal);   // a seam tilts the normal 45 degrees at most

    // Fibres, pores and latewood: a wood tile about 14 world units along the grain (planks of a 20-unit crate get a few
    // growth lines each, under the art's own bigger ones).
    float k;
    vec4 g = mat_wood_planks_grain(m, 14.0 * m.scale, swap, k);
    float gv = MatMapVar(g), gh = MatMapHeight(g);
    float grain = wood + 0.45 * paint;
    vec2 t = (g.xy * 2.0 - 1.0) * vec2(0.2, 0.35) * grain;
    o.dn += t.x * ta + t.y * tc;
    o.albedo = MatVary(c, 0.045 * m.p.y * grain, 2.0 * gv);
    // Latewood (darker bands) is denser and takes a faint sheen; open pores are rough and shaded.
    o.spec = 1.0 + (0.7 * -gv + 0.35 * gh) * grain;
    o.gloss = 1.0 + 0.6 * -gv * grain;
    o.ao = 1.0 - 1.6 * max(-gh - 0.12, 0.0) * grain;   // only the deep pores and ring cracks

    // Wear: scuffs, scratches and dents where the wear order passes 1 - wear. One fetch at the wear tile's octave.
    float Fw, fw;
    MatOctave(m, 22.0 * m.scale, Fw, fw);
    Fw *= fw > 0.5 ? 2.0 : 1.0;
    vec4 w = MatMapAt(m, MAT_MAP_WEAR, Fw, vec2(0.21, 0.47));
    float kw = MatMapFade(m, Fw, 4.0);
    float worn = smoothstep(1.0 - m.p.x, 1.0 - m.p.x + 0.08, w.a) * kw;
    o.dn += MatMapBump(m, w, (0.15 + 0.2 * wood) * worn);
    // (Metal's brighter highlight takes from its diffuse in Light(): a few percent of albedo back keeps its mean.)
    // Only bare wood scuffs lighter: on paint and metal a light scratch reads as a hairline drawn over the art.
    o.albedo *= 1.0 + 0.04 * worn * wood + 0.05 * metal;

    // Metal: smooth, a tight bright highlight; scratches dull it. Wood scuffs are rough.
    o.spec = mix(o.spec * (1.0 - 0.25 * worn), 1.6 * (1.0 - 0.3 * worn), metal);
    o.gloss = mix(o.gloss * (1.0 - 0.35 * worn), 3.0 * (1.0 - 0.4 * worn), metal);
    return o;
}
