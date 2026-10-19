// @class cartoon_flat
// @default scale=1 strength=0.8 rough=0 wear=0 tint=0.4 a=0.45 b=0.4
// @param tint: mottle of the enamel in the albedo (1 = about 3% either way)
// @param a: enamel sheen (0 matte .. 1 glossy lacquer)
// @param b: relief of the art's own edges (0 none .. 1 embossed)
// Flat comic art, stickers, UI planes, sprites: the colours stay as drawn. The surface reads as a painted enamel: a
// soft orange-peel ripple (the GRAIN map at a 22-unit tile, features about a quarter of a world unit, so it still
// shows at the game's distance and fades out by its footprint beyond), a sheen where the colour is saturated, broken
// by that ripple so it is never a flat plastic gloss, and, from the art's own luminance edges, a faint emboss so
// outlines read as a pressed or moulded edge. Gold-ish texels (red >= green >= blue, saturated, bright; graded, no
// hard switch) get a metallic leaning sheen (atlases with fittings).
MatOut mat_cartoon_flat(MatIn m) {
    MatOut o = MatNone(m.albedo);
    // The art's edges as a very low relief (no fetch). Slope capped so it can never become a bevel.
    vec3 e = MatBumpScreen(m, m.lumD * (0.18 * m.scale));
    e *= min(1.0, 0.25 / max(length(e), 1e-5));
    if (m.fade <= 0.0) return o;
    vec3 c = m.albedo;
    float mx = max(max(c.r, c.g), c.b), mn = min(min(c.r, c.g), c.b), sat = (mx - mn) / max(mx, 1e-3), lum = MatLum(c);
    float gold = smoothstep(0.45, 0.7, sat) * smoothstep(0.35, 0.6, lum)
               * smoothstep(0.02, 0.08, c.r - c.g) * smoothstep(0.02, 0.08, c.g - c.b);
    float ink = smoothstep(0.1, 0.45, sat) * smoothstep(0.08, 0.2, lum);   // coloured paint (not black, not grey)
    vec4 g = MatMapWorld(m, MAT_MAP_GRAIN, 22.0 * m.scale, 3.0);
    float var = MatMapVar(g);
    o.dn = e * (m.p.w * 1.2) + MatMapBump(m, g, 0.3);
    o.albedo = MatVary(c, 0.08 * m.p.y, 2.0 * MatMapHeight(g));
    float sh = m.p.z * ink;
    o.spec = 1.0 + 1.1 * sh + 0.8 * gold - 0.6 * var * (sh + 0.3);
    o.gloss = 1.0 + 1.2 * sh - 2.0 * var * sh + 1.0 * gold;
    return o;
}
