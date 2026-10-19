// @class gold_brass
// @default scale=1 strength=1 rough=0 wear=0.4 tint=1 a=0.5 b=0.3
// @param wear: tarnish and patina in the darker, recessed gold (0 bright polish everywhere .. 1 old brass)
// @param tint: the reflection of sky and ground in the gold (1 = up to about 12% either way)
// @param a: hammering: soft dents breaking the highlight (0 smooth cast or plated .. 1 hand-beaten)
// @param b: anisotropy of a light brushing along u (0 none .. 1 long streaks)
// Gold, gilding, brass and bronze. The art paints gold as bright yellow with darker engraved or recessed detail; this
// polishes the bright gold (a tight, warm highlight broken by soft hammer dents, the sky reflected), and dulls the
// recesses with tarnish (rougher, a touch darker and greener, a little cavity). Atlas texels that are not gold keep a
// plain response: gems and enamel (saturated other hues) a glassy gloss, grey or white parts a light polish, cloth and
// near black unchanged.

// Gold weight: yellow to orange-brown with some saturation; and how bright it is within the gold family.
float mat_gold_brass_key(vec3 c) {
    float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
    float sat = (mx - mn) / max(mx, 1e-3);
    float gr = c.g / max(c.r, 1e-3);
    return smoothstep(0.22, 0.38, sat) * smoothstep(0.34, 0.46, gr) * (1.0 - smoothstep(1.02, 1.12, gr))
         * step(c.b, c.g) * smoothstep(0.08, 0.2, mx);
}

// One octave of the hammer dents at F cells per texture unit, (value, d/duv). The lattice offset depends only on F, so
// the octave at 2 * F0 (blended in as the density falls) is the same field as the next F0 octave: no seam where F0
// doubles.
vec3 mat_gold_brass_dent(MatIn m, float F) {
    vec2 off = vec2(m.seed * 29.0) + fract(F * vec2(0.6180340, 0.4142136)) * 23.0;
    return MatGNoise(m.uv * F + off, F) * vec3(1.0, F, F);
}
// A shared map sized in world units, the two octaves blended (MatOctave) at offsets that depend only on the frequency,
// faded to neutral by the footprint of features texels across.
vec4 mat_gold_brass_map(MatIn m, float layer, float tileWorld, float texels) {
    float F0, fb;
    MatOctave(m, tileWorld, F0, fb);
    vec2 o0 = fract(F0 * vec2(0.7548777, 0.5698403)), o1 = fract(2.0 * F0 * vec2(0.7548777, 0.5698403));
    vec4 s = mix(MatMapAt(m, layer, F0, o0), MatMapAt(m, layer, 2.0 * F0, o1), fb);
    return MatMapNeutral(s, MatMapFade(m, F0 * (1.0 + fb), texels));
}

MatOut mat_gold_brass(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0) return o;
    vec3 c = m.albedo;
    float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
    float sat = (mx - mn) / max(mx, 1e-3);
    float gold = mat_gold_brass_key(c);
    // Other texels: gems and enamel (saturated), grey or white trim (unsaturated), the rest left alone.
    float gem = (1.0 - gold) * smoothstep(0.5, 0.7, sat) * smoothstep(0.1, 0.25, mx);
    float grey = (1.0 - gold) * (1.0 - smoothstep(0.12, 0.25, sat)) * smoothstep(0.25, 0.45, mx);
    float rest = 1.0 - gold - gem - grey;
    // Tarnish in the recesses: the darker gold (the art draws engraving and hollows darker), from wear.
    float tarn = gold * (1.0 - smoothstep(0.28, 0.6, mx)) * clamp(m.p.x * 1.5, 0.0, 1.0);

    // Hammer dents: smooth gradient noise, cells about 2.5 world units, two octaves blended.
    float D0, db;
    MatOctave(m, 2.5 * m.scale, D0, db);
    vec3 g = mix(mat_gold_brass_dent(m, D0), mat_gold_brass_dent(m, 2.0 * D0), db);
    float gk = MatFadeUv(m, D0 * (1.0 + db));
    // Fine polishing marks and scratches along u, a tile about 10 world units.
    vec4 s = mat_gold_brass_map(m, MAT_MAP_BRUSHED, 10.0 * m.scale, 3.0);
    // Tarnish mottle: the stone layer's variation, a tile about 30 world units.
    vec4 t = mat_gold_brass_map(m, MAT_MAP_STONE, 30.0 * m.scale, 4.0);

    o.dn = gold * (MatBumpUv(m, g.yz * ((0.04 + 0.22 * clamp(m.p.z, 0.0, 1.5)) * m.scale * gk)) + MatMapBump(m, s, 0.25))
         + tarn * MatMapBump(m, t, 0.4);
    float polish = 1.0 - clamp(0.6 * max(MatMapVar(s), 0.0) + 0.5 * g.x * gk, 0.0, 0.5);
    o.gloss = gold * mix(2.6 * polish, 0.9, tarn) + gem * 2.4 + grey * 1.8 + rest;
    o.spec = gold * mix(1.05, 0.7, tarn) + gem * 1.1 + grey + rest;

    // Anisotropy of the brushing (Ashikhmin-Shirley's exponent): only the gloss changes, never the diffuse light.
    vec3 n2 = normalize(m.n + o.dn);
    vec3 h = normalize(m.l + m.v);
    float hu = dot(h, m.tu), hv = dot(h, m.tv);
    float r = 1.0 - 0.85 * gold * clamp(m.p.w, 0.0, 1.0);
    o.gloss *= (hu * hu + r * hv * hv + 1e-4) / (hu * hu + hv * hv + 1e-4);

    // Cavity in the tarnished recesses; tarnish a little darker and toward olive (the hue barely moves), mottled.
    o.ao = 1.0 - 0.2 * tarn * (0.6 + 2.0 * max(-MatMapVar(t), 0.0));
    vec3 tarnished = c * vec3(0.96, 0.98, 0.93) * (1.0 + 0.1 * MatMapVar(t));
    // The sky and ground in the polished gold (brighter facing the sky, a dark horizon line), more at grazing angles.
    float ry = dot(reflect(-m.v, n2), m.up);
    float env = (0.6 * ry - 0.35 * exp(-ry * ry * 30.0) + 0.2) * (0.7 + 0.6 * (1.0 - m.ndv));
    o.albedo = mix(c, tarnished, tarn) * (1.0 + 0.25 * m.p.y * (gold - tarn + 0.5 * grey) * env);
    return o;
}
