// @class generic
// @default scale=1 strength=1 rough=0 wear=0 tint=1 a=0 b=0
// @param tint: albedo variation (1 = 2% either way)
// @param a: unused
// @param b: unused
// The default for any class without its own snippet, and for an untagged matte texture: a barely-there surface, a
// fine grain in the light (the normal and the sheen) and a faint mottle in the paint. It must stay small: it lands on
// everything, cartoon art included.
MatOut mat_generic(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0) return o;
    // Grain about 1.2 world units across (a worm's head is about 12), two octaves blended so it never jumps in size.
    float F0, fb;
    MatOctave(m, 1.2 * m.scale, F0, fb);
    vec3 g = mix(MatGNoise(m.uv * F0, F0) * vec3(1.0, F0, F0), MatGNoise(m.uv * (2.0 * F0) + 7.0, 2.0 * F0) * vec3(1.0, 2.0 * F0, 2.0 * F0), fb);
    float k = MatFadeUv(m, F0 * (1.0 + fb));
    // Height 0.05 world units: slopes of a few degrees at most.
    o.dn = MatBumpUv(m, g.yz * (0.05 * m.scale * k));
    // A mottle ten times bigger, 2% either way (tint), and the sheen broken a little by the grain.
    float F1, fb1;
    MatOctave(m, 12.0 * m.scale, F1, fb1);
    float mot = mix(MatGNoise(m.uv * F1 + 3.0, F1).x, MatGNoise(m.uv * (2.0 * F1) + 11.0, 2.0 * F1).x, fb1);
    o.albedo = MatVary(m.albedo, 0.04 * m.p.y * MatFadeUv(m, F1), mot);
    o.spec = 1.0 + 0.25 * g.x * k;
    return o;
}
