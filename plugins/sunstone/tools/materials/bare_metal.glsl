// @class bare_metal
// @default scale=1 strength=1 rough=0 wear=0.3 tint=1 a=0.6 b=0
// @param wear: scratches and scuffs breaking the polish (0 none .. 1 a well used tool)
// @param tint: the reflection of sky and ground in the metal (1 = up to about 10% either way)
// @param a: anisotropy: how far the highlight is drawn out across the brushing (0 round .. 1 long streaks)
// @param b: brushing direction: 0 along the texture's u, 1 along v
// Steel, iron, chrome, tin. The art paints the metal's shading; this adds what it cannot: a tight highlight drawn out
// across the brushing, the sky and ground reflected in the metal (moves with the view), soft dents and smudges that
// break the polish, and brushed streaks and scratches close up. Atlas texels that are not metal (paint, gems, lamps,
// black holes) keep a plain painted response.
// Shared by every untagged glossy material (the fallback for metal), so it stays calm.

// How metallic a texel looks: greys and golds 1, saturated paint 0, near-black 0.
float mat_bare_metal_key(vec3 c) {
    float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
    float sat = (mx - mn) / max(mx, 1e-3);
    float gr = c.g / max(c.r, 1e-3);
    float gold = smoothstep(0.62, 0.75, gr) * (1.0 - smoothstep(1.0, 1.1, gr)) * step(c.b, c.g);
    return max(1.0 - smoothstep(0.16, 0.36, sat), gold) * smoothstep(0.05, 0.16, mx);
}

// One octave of the dents at F cells per texture unit, (value, d/duv). The lattice offset depends only on F, so the
// octave at 2 * F0 (blended in as the density falls) is the same field as the next F0 octave: no seam where F0 doubles.
vec3 mat_bare_metal_dent(MatIn m, float F) {
    vec2 off = vec2(m.seed * 31.0) + fract(F * vec2(0.6180340, 0.4142136)) * 23.0;
    return MatGNoise(m.uv * F + off, F) * vec3(1.0, F, F);
}
// The brushed map tiled F times per texture unit along the brushing (uvb and its derivatives swapped for b = 1), at an
// offset that depends only on F (as above).
vec4 mat_bare_metal_brush(vec2 uvb, vec2 dxb, vec2 dyb, float F) {
    vec2 off = fract(F * vec2(0.7548777, 0.5698403));
    return textureGrad(sunstoneMat, vec3(uvb * F + off, MAT_MAP_BRUSHED), dxb * F, dyb * F);
}

MatOut mat_bare_metal(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0) return o;
    float metal = mat_bare_metal_key(m.albedo);
    bool alongV = m.p.w > 0.5;
    vec3 T = alongV ? m.tv : m.tu;   // the brushing
    vec3 B = alongV ? m.tu : m.tv;   // across it
    vec2 uvb = alongV ? m.uv.yx : m.uv, dxb = alongV ? m.uvDx.yx : m.uvDx, dyb = alongV ? m.uvDy.yx : m.uvDy;

    // Dents and smudges: smooth gradient noise, cells about 5 world units (soft, wide undulations, as a pressed or
    // forged surface has), two octaves blended so the size never jumps between triangles.
    float D0, db;
    MatOctave(m, 5.0 * m.scale, D0, db);
    vec3 g = mix(mat_bare_metal_dent(m, D0), mat_bare_metal_dent(m, 2.0 * D0), db);
    float gk = MatFadeUv(m, D0 * (1.0 + db));
    // Brushed streaks and scratches along the brushing, a tile about 14 world units, two octaves blended (so the tile
    // never doubles between triangles).
    float F0, fb;
    MatOctave(m, 14.0 * m.scale, F0, fb);
    vec4 s = mix(mat_bare_metal_brush(uvb, dxb, dyb, F0), mat_bare_metal_brush(uvb, dxb, dyb, 2.0 * F0), fb);
    s = MatMapNeutral(s, MatMapFade(m, F0 * (1.0 + fb), 3.0));
    vec2 sn = s.xy * 2.0 - 1.0;
    vec3 dnB = sn.x * T + sn.y * B;   // (the swapped sample's x runs along the brushing either way)

    // Height 0.14 world units over a 5-unit cell: tilts of a few degrees, a subtle ripple that bends a tight highlight
    // without splitting it into several hot spots (0.35 did, on a helmet).
    o.dn = metal * (MatBumpUv(m, g.yz * (0.14 * m.scale * gk)) + 0.35 * dnB);
    // Polish: smudges (the noise) and, with wear, scratches (brushed A) rougher; dents a little darker in the hollows.
    float rough = clamp(0.8 * g.x * gk + (0.6 + 0.8 * m.p.x) * max(MatMapVar(s), 0.0), -0.5, 0.6);
    o.gloss = mix(1.4, 2.8 * (1.0 - 0.9 * rough), metal);
    o.spec = mix(1.0, 1.05 - 0.3 * rough, metal);
    o.ao = 1.0 + 0.6 * metal * min(MatMapHeight(s), 0.0);

    // Anisotropy (as Ashikhmin-Shirley's exponent): the gloss falls for a half vector leaning across the brushing, so
    // the highlight is drawn out in a streak across the grain. Only the exponent changes: the diffuse light is untouched.
    vec3 n2 = normalize(m.n + o.dn);
    vec3 h = normalize(m.l + m.v);
    float hu = dot(h, T), hv = dot(h, B);
    float r = 1.0 - 0.88 * metal * clamp(m.p.z, 0.0, 1.0);
    o.gloss *= (hu * hu + r * hv * hv + 1e-4) / (hu * hu + hv * hv + 1e-4);

    // The sky and ground in the metal: brighter where it reflects the sky, a dark horizon line, darker below; stronger
    // at grazing angles.
    float ry = dot(reflect(-m.v, n2), m.up);
    float env = 0.6 * ry - 0.35 * exp(-ry * ry * 30.0) + 0.1;
    o.albedo = m.albedo * (1.0 + 0.2 * m.p.y * metal * (0.7 + 0.6 * (1.0 - m.ndv)) * env);
    return o;
}
