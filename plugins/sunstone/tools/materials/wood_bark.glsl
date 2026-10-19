// @class wood_bark
// @default scale=1 strength=1 rough=0 wear=0 tint=1 a=0.45 b=0
// @param tint: albedo variation along the fissures (1 = about 5% either way)
// @param a: relief from the art itself, world units of depth per unit of the texel's luminance (dark furrows sink,
// @param a: light ridges rise); 0 off
// @param b: fissure direction 0 along v (a trunk's texture standing up), 1 along u; add 2 for pale (silvered or
// @param b: bleached) bark: bright greys are then bark, not snow
// Bark, logs, posts, stumps, branches, husk. The art paints its furrows and knots: the snippet lifts them into relief
// (the art's own luminance as a height), cuts the shared bark map's fissures and crack network into the ridges, adds
// a fine fibre along the fissures (the wood map turned) and shades only the deep fissures. Ridges keep a faint dry
// sheen, fissures none. The texel decides in atlases: brown (warm, not too vivid) and green moss get the bark; snow
// and ice (bright, grey-blue) stay smooth with a crisp highlight; vivid paint (yellow, orange, cyan) and plain greys
// (cloth, stone) keep only a quarter of the map, no cavity and their own sheen. Pale bark gets a lighter map. Hue and
// value stay; albedo moves a few percent at most.

// The art's luminance slope (per texture unit) from three bilinear samples of texture0 on a circle a texel across
// (wider when minified), fitted with a plane: continuous across texels, unlike the screen derivative of the bilinear
// sample, which steps at every texel (seams then light up as stairs). Also returns texels per pixel.
vec2 mat_wood_bark_art(MatIn m, out float texPx) {
    vec2 ts = vec2(textureSize(texture0, 0));
    texPx = m.uvPx * max(ts.x, ts.y);
    vec2 h = max(1.0 / ts, vec2(m.uvPx));
    vec2 d1 = vec2(1.0, 0.0), d2 = vec2(-0.5, 0.8660254), d3 = vec2(-0.5, -0.8660254);
    float l1 = MatLum(textureGrad(texture0, m.uv + h * d1, m.uvDx, m.uvDy).rgb);
    float l2 = MatLum(textureGrad(texture0, m.uv + h * d2, m.uvDx, m.uvDy).rgb);
    float l3 = MatLum(textureGrad(texture0, m.uv + h * d3, m.uvDx, m.uvDy).rgb);
    return (2.0 / 3.0) * (l1 * d1 + l2 * d2 + l3 * d3) / h;
}

MatOut mat_wood_bark(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.01) return o;
    bool swap = mod(m.p.w, 2.0) >= 0.5;
    bool pale = m.p.w >= 1.5;
    vec3 tc = swap ? m.tv : m.tu;   // across the fissures

    // What the texel is: bark, snow or ice (bright and nearly grey or bluish), moss (green).
    vec3 c = m.albedo;
    float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
    float sat = (mx - mn) / max(mx, 1e-3);
    // (Guarded: atan(0, 0) is undefined, and every pure grey or black texel has it.)
    float hy = sqrt(3.0) * (c.g - c.b), hx = 2.0 * c.r - c.g - c.b;
    float hue = degrees(atan(hy, hx + (abs(hx) + abs(hy) < 1e-5 ? 1e-5 : 0.0)));
    float snow = smoothstep(0.62, 0.78, mx) * (1.0 - smoothstep(0.12, 0.3, sat)) + smoothstep(0.55, 0.7, mx) * smoothstep(95.0, 115.0, -hue) * (1.0 - smoothstep(0.55, 0.7, sat));
    snow = pale ? 0.0 : clamp(snow, 0.0, 1.0);
    float moss = smoothstep(70.0, 85.0, hue) * (1.0 - smoothstep(165.0, 180.0, hue)) * smoothstep(0.2, 0.35, sat);
    // Brown: a red-brown to ochre hue that is not vivid (chroma mx - mn up to about 0.38; painted yellow and orange
    // run 0.5 to 0.8). Plain greys are cloth or stone unless the bark is pale. The rest keeps a quarter of the map.
    float brown = (1.0 - smoothstep(40.0, 60.0, abs(hue - 25.0))) * (1.0 - smoothstep(0.38, 0.5, mx - mn))
                * (pale ? 1.0 : smoothstep(0.04, 0.12, sat));
    float key = pale ? 1.0 : max(0.25, max(brown, moss));
    float bark = (1.0 - snow) * (1.0 - 0.45 * moss) * key;
    float cav = bark * key * (pale ? 0.4 : 1.0);   // cavity: none on paint, light on pale bark
    float mapK = bark * (pale ? 0.4 : 1.0);        // the bark map's normal

    // Relief from the art: its luminance as a height (dL/du, dL/dv); softer where one texel spans many pixels (big
    // soft bilinear bumps), where many texels share a pixel (it would sparkle), and on paint and cloth (key).
    float texPx;
    vec2 dL = mat_wood_bark_art(m, texPx);
    float artK = m.p.z * m.scale * mix(0.3, 1.0, smoothstep(0.12, 0.45, texPx)) * (1.0 - 0.75 * smoothstep(1.0, 3.0, texPx));
    vec3 s = MatBumpUv(m, dL * artK * mix(0.25, 1.0, key));
    o.dn = s * inversesqrt(1.0 + dot(s, s)) * (1.0 - 0.6 * snow);

    // Fissures and cracks: the bark map about 22 world units a tile (two octaves, faded by footprint).
    float F0, fb;
    MatOctave(m, 22.0 * m.scale, F0, fb);
    vec2 uv = swap ? m.uv.yx : m.uv, dx = swap ? m.uvDx.yx : m.uvDx, dy = swap ? m.uvDy.yx : m.uvDy;
    vec4 g = mix(textureGrad(sunstoneMat, vec3(uv * F0, MAT_MAP_BARK), dx * F0, dy * F0),
                 textureGrad(sunstoneMat, vec3(uv * 2.0 * F0 + vec2(0.37, 0.61), MAT_MAP_BARK), dx * 2.0 * F0, dy * 2.0 * F0), fb);
    g = MatMapNeutral(g, MatMapFade(m, F0 * (1.0 + fb), 5.0));
    float gh = MatMapHeight(g), gv = MatMapVar(g);
    vec2 t = (g.xy * 2.0 - 1.0) * 0.6 * mapK;
    o.dn += t.x * (swap ? m.tv : m.tu) + t.y * (swap ? m.tu : m.tv);

    // Fibre along the fissures: the wood map turned, a tile about 6 world units, one octave, faded early.
    float Ff, ff;
    MatOctave(m, 6.0 * m.scale, Ff, ff);
    Ff *= ff > 0.5 ? 2.0 : 1.0;
    vec2 fr = vec2(Ff, 2.0 * Ff);
    vec2 uf = swap ? m.uv : m.uv.yx, fdx = swap ? m.uvDx : m.uvDx.yx, fdy = swap ? m.uvDy : m.uvDy.yx;
    vec4 f = textureGrad(sunstoneMat, vec3(uf * fr + vec2(0.13, 0.71), MAT_MAP_WOOD), fdx * fr, fdy * fr);
    f = MatMapNeutral(f, MatMapFade(m, 2.0 * Ff, 6.0));
    o.dn += (f.y * 2.0 - 1.0) * 0.3 * bark * tc;

    // Deep fissures shaded, ridges with a faint dry sheen, a small variation in the paint (mean kept).
    o.ao = 1.0 - 1.4 * max(-gh - 0.1, 0.0) * cav;
    o.albedo = MatVary(c, 0.05 * m.p.y * cav, 2.0 * (gv + 0.03));
    o.spec = mix(mix(1.0, 0.85 + 0.8 * clamp(gh, -0.3, 0.3), key), 1.6, snow);
    o.gloss = mix(mix(1.0, 0.75, key), 2.5, snow);
    return o;
}
