// @class rusted_metal
// @default scale=1 strength=1 rough=0 wear=0.5 tint=1 a=1.5 b=0.6
// @param wear: scratches and chips on the steel and paint (0 none .. 1 battered)
// @param tint: mottling of the rust's colour (1 = about 5% either way)
// @param a: relief of the rust: flakes and pits raised from the art's own speckle (0 flat .. 2 heavy)
// @param b: polish of the bare steel between the rust (0 dull .. 1 bright scratched steel)
// Rusty iron and steel, usually with paint: the texel says which. Rust (orange to dark brown, and speckled: the art
// paints it with a busy texture) turns matte and rough, pitted, the pits darker, and far away its painted speckle is
// raised a little; bare steel (grey) catches a tight scratched highlight; paint (any other colour, and flat orange or
// brown too: hazard yellow, red, green, orange) keeps a satin sheen with chips and scratches.

// Rust weight of a texel: orange to brown, from dark to bright.
float mat_rusted_metal_rust(vec3 c) {
    float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
    float sat = (mx - mn) / max(mx, 1e-3);
    float gr = c.g / max(c.r, 1e-3);
    return smoothstep(0.3, 0.5, sat) * smoothstep(0.18, 0.3, gr) * (1.0 - smoothstep(0.62, 0.74, gr))
         * step(c.b, c.g) * step(c.g, c.r) * smoothstep(0.06, 0.14, mx);
}

// A shared map sized in world units, the two octaves blended (MatOctave) at offsets that depend only on the frequency
// (so the octave at 2 * F0 is the same map as the next F0 one: no seam where F0 doubles between triangles), faded to
// neutral by the footprint of features texels across.
vec4 mat_rusted_metal_map(MatIn m, float layer, float tileWorld, float texels) {
    float F0, fb;
    MatOctave(m, tileWorld, F0, fb);
    vec2 o0 = fract(F0 * vec2(0.7548777, 0.5698403)), o1 = fract(2.0 * F0 * vec2(0.7548777, 0.5698403));
    vec4 s = mix(MatMapAt(m, layer, F0, o0), MatMapAt(m, layer, 2.0 * F0, o1), fb);
    return MatMapNeutral(s, MatMapFade(m, F0 * (1.0 + fb), texels));
}

MatOut mat_rusted_metal(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0) return o;
    vec3 c = m.albedo;
    float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));

    // The art's luminance slope, solved from screen to texture space (no derivative is taken after the early out
    // above; the same as MatBumpScreen(m, m.lumD * k)), and how many of the texture's texels a pixel covers.
    float jd = m.uvDx.x * m.uvDy.y - m.uvDx.y * m.uvDy.x;
    vec2 dLuv = vec2(m.lumD.x * m.uvDy.y - m.lumD.y * m.uvDx.y, m.uvDx.x * m.lumD.y - m.uvDy.x * m.lumD.x)
              / (abs(jd) > 1e-20 ? jd : 1e-20);
    vec2 tsz = vec2(textureSize(texture0, 0));
    float texPx = m.uvPx * max(tsz.x, tsz.y);
    // Speckle: the luminance change from one texel to the next (far away the mips average the speckle out, about
    // as 1 / texels per pixel, which the second factor undoes). Rust is painted busy (a few percent a texel and
    // more); flat paint, orange or not, barely changes (under 1%).
    float speck = length(dLuv) / max(tsz.x, tsz.y) * max(texPx, 1.0);
    float rust = mat_rusted_metal_rust(c) * smoothstep(0.008, 0.03, speck);
    float steel = (1.0 - rust) * (1.0 - smoothstep(0.14, 0.3, (mx - mn) / max(mx, 1e-3))) * smoothstep(0.05, 0.15, mx);
    float paint = (1.0 - rust) * (1.0 - steel) * smoothstep(0.05, 0.15, mx);
    float dark = 1.0 - rust - steel - paint;   // near black (holes, gaps): left as it is

    // Pits, craters and fbm relief of the stone layer, a tile about 24 world units (pits about 0.4 units).
    vec4 st = mat_rusted_metal_map(m, MAT_MAP_STONE, 24.0 * m.scale, 4.0);
    // Chips and scratches, a tile about 20 world units.
    vec4 w = mat_rusted_metal_map(m, MAT_MAP_WEAR, 20.0 * m.scale, 4.0);
    float worn = smoothstep(1.0 - m.p.x, 1.05 - m.p.x, w.a) * step(0.01, m.p.x);

    // Rust relief: the map's pits close up; and, where a texel is about a pixel or smaller, the art's own speckle
    // raised (darker = deeper, 0.6 world units per unit of luminance). Magnified, the bilinear texture is faceted per
    // texel, so its slope would light every texel's staircase: faded out by two pixels a texel. The art's slope is
    // filtered by the texture's mips, so it stays calm far away.
    float relief = clamp(m.p.z, 0.0, 2.0);
    vec3 dnRust = MatBumpUv(m, dLuv * (0.6 * relief * m.scale)) * smoothstep(0.5, 1.0, texPx);
    // (Capped low: at grazing angles a pixel spans a long stretch of surface and the screen slope would blow up.)
    dnRust = dnRust * min(1.0, 0.2 / max(length(dnRust), 1e-4)) + 0.5 * relief * MatMapBump(m, st, 1.0);
    vec3 dnHard = MatMapBump(m, w, 0.5);
    o.dn = rust * dnRust + (steel + paint) * (dnHard + 0.15 * MatMapBump(m, st, 1.0));

    // Matte rust; steel tight and bright where polished, rougher in scratches; paint satin, chips rougher.
    float scratch = max(MatMapVar(w), 0.0) * smoothstep(0.5, 0.62, w.a);
    o.gloss = rust * (0.5 + 0.3 * MatMapVar(st))
            + steel * mix(1.2, 1.9, m.p.w) * (1.0 - 0.8 * scratch)
            + paint * mix(1.5, 0.8, worn) + dark;
    o.spec = rust * 0.75 + steel * mix(1.0, 1.1, m.p.w) + paint * mix(1.05, 0.85, worn) + dark;
    // Pits a little darker (cavity), rust mottled a few percent; the cavity and the weaker specular keep the rust's
    // mean value where the art has it.
    float pit = min(MatMapHeight(st), 0.0);
    o.ao = 1.0 + rust * min(relief, 1.0) * 0.5 * pit + (steel + paint) * 0.5 * min(MatMapHeight(w), 0.0);
    // Steel reflects the sky and ground a little (brighter facing the sky, a dark horizon line), more at grazing angles.
    float ry = dot(reflect(-m.v, normalize(m.n + o.dn)), m.up);
    float env = (0.6 * ry - 0.35 * exp(-ry * ry * 30.0) + 0.1) * (0.7 + 0.6 * (1.0 - m.ndv));
    o.albedo = c * (1.0 + rust * 0.1 * m.p.y * MatMapVar(st) + steel * m.p.w * 0.15 * env);
    return o;
}
