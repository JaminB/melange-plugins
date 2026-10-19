// @class grass_turf
// @default scale=1 strength=1 rough=0 wear=0 tint=1 a=0.5 b=1
// @param tint: albedo tonal variation (1 = about 1.5% either way)
// @param a: blade spacing in world units
// @param b: blade relief amount (1 normal)
// Grass and turf: a suggestion of blades (thin strands along the texture's v: stretched value noise, no map) with a
// soft clump relief (the bumps map, tile about 14 units). Mostly light: the cavity and the mottle are small and zero-mean
// where they can be, so pale grass keeps its value, and both step back on the art's own edges (m.lumD) so drawn
// outlines stay clean. The blades blend their two octaves and fade by their anisotropic footprint (a blade cell covers
// 8 pixels on both screen axes for full, 4 for none), so they never turn into pixel dashes at grazing.
// 2 map fetches + 2 stretched value noises (8 hashes).
float mat_grass_turf_vn(vec2 p, vec2 period, out vec2 d) {
    vec2 i = floor(p), f = fract(p);
    vec2 u = f * f * (3.0 - 2.0 * f), du = 6.0 * f * (1.0 - f);
    float a = MatHash12(mod(i, period)), b = MatHash12(mod(i + vec2(1.0, 0.0), period));
    float c = MatHash12(mod(i + vec2(0.0, 1.0), period)), e = MatHash12(mod(i + 1.0, period));
    float k = a - b - c + e;
    d = du * vec2((b - a) + k * u.y, (c - a) + k * u.x);
    return a + (b - a) * u.x + (c - a) * u.y + k * u.x * u.y;
}
// One octave of blades, fx cells per texture unit across, a quarter of that along: (height about 0, d/du, d/dv),
// already faded by the cell's footprint along both screen axes. One offset for every octave, so the pattern stays the
// same where MatOctave's floor() flips per pixel (a texel density on a power of two).
vec3 mat_grass_turf_blades(MatIn m, float fx) {
    vec2 f = vec2(fx, max(fx / 4.0, 1.0));
    float k = MatFadeCells(2.0 * max(length(m.uvDx * f), length(m.uvDy * f)));
    vec2 d;
    float h = mat_grass_turf_vn(m.uv * f + 5.0, f, d) - 0.5;
    return k * vec3(h, d * f);
}
// A layer about tileWorld units a tile, both octaves blended with one offset (MatMapWorld's two offsets make a pixel
// maze where the texel density sits on a power of two).
vec4 mat_grass_turf_map(MatIn m, float layer, float tileWorld, float texels) {
    float F0, fb;
    MatOctave(m, tileWorld, F0, fb);
    vec4 s = mix(MatMapAt(m, layer, F0, vec2(0.0)), MatMapAt(m, layer, 2.0 * F0, vec2(0.0)), fb);
    return MatMapNeutral(s, MatMapFade(m, F0 * (1.0 + fb), texels));
}
MatOut mat_grass_turf(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0) return o;
    // The art's own edges (drawn outlines, leaf shapes): detail steps back there.
    float keep = 1.0 - smoothstep(0.01, 0.05, length(m.lumD));
    float fx, fb;
    MatOctave(m, max(m.p.z, 0.05) * m.scale, fx, fb);   // blade spacing along u
    vec3 bl = mix(mat_grass_turf_blades(m, fx), mat_grass_turf_blades(m, 2.0 * fx), fb) * keep;
    float h = bl.x;
    o.dn = MatBumpUv(m, bl.yz * (0.06 * m.scale * m.p.w));
    vec4 c = mat_grass_turf_map(m, MAT_MAP_BUMPS, 14.0 * m.scale, 8.0);
    o.dn += MatMapBump(m, c, 0.3 * (0.5 + 0.5 * keep));
    o.ao = 1.0 + (0.08 * min(h, 0.0) + 0.06 * min(MatMapHeight(c), 0.0)) * keep;
    o.albedo = MatVary(m.albedo, 0.015 * m.p.y * keep, h * 2.0 + MatMapVar(c));
    o.spec = 0.95 + 0.5 * max(h, 0.0);
    o.gloss = 0.6;
    return o;
}
