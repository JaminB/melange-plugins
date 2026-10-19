// @class leather
// @default scale=1 strength=1 rough=0 wear=0.2 tint=1 a=1 b=0
// @param wear: scuffing (0 new .. 1 well worn): scuffs go matte and a touch lighter
// @param tint: albedo variation (1 = about 3% either way, from the pebble grain)
// @param a: pebble grain and crease depth (1 = the default; 0 = smooth)
// @param b: polish (0 = satin, the default; 1 = polished boot leather; -1 = suede-dull)
// Gloves, boots, straps, bags, caps: a pebbled grain whose cell tops are a little smoother than the creases between
// them, the art's own painted creases and seams turned into a slight relief, and scuffs that dull the satin sheen.
// The art's colours stay; from afar the grain fades to the plain satin surface.
// Cost: 3 texture fetches (MatMapWorld = 2, one MatMapAt), no noise calls, no loops.
MatOut mat_leather(MatIn m) {
    MatOut o = MatNone(m.albedo);
    // The art's creases and stitch lines as relief (derivatives, so before the early out): 0.06 world units of height
    // per unit of luminance, the slope capped at about 0.2 so hard decal edges do not turn into ridges.
    vec2 e = m.lumD * (0.06 * m.p.z * m.scale);
    float el = length(e);
    e *= min(1.0, 0.2 * m.pxWorld / max(el, 1e-6));
    vec3 crease = MatBumpScreen(m, e);
    if (m.fade <= 0.0) return o;
    // Bright trim (gold, lenses, white cuffs) and near-black gaps take less of the leather.
    float lum = MatLum(m.albedo);
    float hide = smoothstep(0.02, 0.08, lum) * (1.0 - 0.6 * smoothstep(0.75, 0.95, lum));
    // Pebble grain: a tile about 7 world units (cells about 0.2 across on a 12-unit worm head).
    vec4 g = MatMapWorld(m, MAT_MAP_BUMPS, 7.0 * m.scale, 8.0);
    float h = MatMapHeight(g), rv = MatMapVar(g) * 2.0;
    o.dn = crease + MatMapBump(m, g, 0.18 * m.p.z) * hide;
    // Scuffs: one fetch of the wear map, about 20 world units a tile.
    float F0, fb;
    MatOctave(m, 20.0 * m.scale, F0, fb);
    vec4 w = MatMapAt(m, MAT_MAP_WEAR, F0, vec2(0.43, 0.17));
    float kw = MatMapFade(m, F0, 4.0);
    float worn = smoothstep(1.0 - m.p.x, 1.0 - m.p.x + 0.08, w.a) * kw * hide;
    // Light: satin (a little rougher and dimmer than the game's default), smoother on the cell tops, rougher in the
    // creases, matte where scuffed; polish (b) sharpens it.
    float pol = exp2(1.2 * m.p.w);
    o.gloss = mix(1.0, 0.85 * pol * (1.0 - 0.3 * rv) * mix(1.0, 0.7, worn), hide);
    o.spec = mix(1.0, (0.95 + 0.15 * m.p.w) * (1.0 - 0.15 * rv) * mix(1.0, 0.8, worn), hide);
    // Cavity in the grain's creases.
    o.ao = 1.0 - 0.4 * max(-h, 0.0) * m.p.z * hide;
    // Colour: the grain's own mottle, scuffs a hair lighter.
    o.albedo = MatVary(m.albedo, 0.03 * m.p.y * hide, -rv) + (vec3(1.0) - m.albedo) * 0.035 * worn;
    return o;
}
