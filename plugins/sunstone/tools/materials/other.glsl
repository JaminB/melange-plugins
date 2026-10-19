// @class other
// @default scale=1 strength=0.8 rough=0 wear=0 tint=0.5 a=0.4 b=0.4
// @param tint: albedo mottle (1 = a few percent)
// @param a: sheen / wetness (0 dry .. 1 glazed or wet); above about 0.6 white and grey texels get a glaze as well
// @param b: surface relief (0 smooth .. 1 lumpy); up to 0.6 a fine calm grain, above it organic lumps
// The leftovers: foods, mushrooms, fruit, ceramics, odd props. Smooth things (cheese, bread, glaze, eggs, fruit: b up
// to 0.6) get a calm fine grain and mottle (the GRAIN map at a 12-unit tile, low relief), lumpy things (b above 0.6,
// e.g. the dog turds) the pebbled BUMPS map; the choice is per texture (uniform), one map either way. The texel decides
// the light: saturated colour is the body (a sheen scaled by `a`), dark stays glossy, and with a high `a` near-white
// and grey texels get a hard glaze too (porcelain, lacquer, egg white). The art's own edges (seams, seeds, sprinkles,
// rind lines) become a faint relief.
MatOut mat_other(MatIn m) {
    MatOut o = MatNone(m.albedo);
    vec3 e = MatBumpScreen(m, m.lumD * (0.2 * m.scale));
    e *= min(1.0, 0.28 / max(length(e), 1e-5));
    if (m.fade <= 0.0) return o;
    vec3 c = m.albedo;
    float mx = max(max(c.r, c.g), c.b), mn = min(min(c.r, c.g), c.b), sat = (mx - mn) / max(mx, 1e-3), lum = MatLum(c);
    float body = smoothstep(0.06, 0.3, sat) * smoothstep(0.05, 0.15, lum);
    float dark = 1.0 - smoothstep(0.04, 0.16, lum);
    float glaze = smoothstep(0.55, 0.85, m.p.z) * smoothstep(0.45, 0.7, lum) * (1.0 - body);
    bool lumpy = m.p.w > 0.6;   // per texture: the same for every fragment of a draw
    vec4 g = lumpy ? MatMapWorld(m, MAT_MAP_BUMPS, 18.0 * m.scale, 8.0) : MatMapWorld(m, MAT_MAP_GRAIN, 12.0 * m.scale, 3.0);
    float h = MatMapHeight(g), var = MatMapVar(g);
    float k = mix(0.5, 1.0, body);
    float relief = lumpy ? 0.45 : 0.3;
    o.dn = (MatMapBump(m, g, relief * m.p.w) + e * (1.4 * m.p.w)) * k;
    o.ao = 1.0 + (lumpy ? 0.5 : 0.25) * m.p.w * min(h, 0.0);
    o.albedo = MatVary(c, 0.04 * m.p.y * body, 2.0 * h);
    o.spec = 1.0 + m.p.z * (0.85 * body + 1.0 * dark) + 1.6 * glaze - 0.3 * var * m.p.z;
    o.gloss = 1.0 + m.p.z * (1.5 * body + 2.0 * dark) + 3.0 * glaze - 2.0 * var * m.p.z * (body + 0.5 * glaze);
    return o;
}
