// @class emissive_light
// @default scale=1 strength=1 rough=0 wear=0 tint=1 a=0 b=0
// @param tint: strength of the glow's inner variation (1 = about 6% either way, bright texels only; 0 for flat glows)
// @param a: pixel grid cells per texture unit (LED screens; 0 none)
// @param b: scanlines, in fours per texture unit (b=8: 32 lines; displays; 0 none)
// Light sources, glows, screens, sparks: stays unlit-looking, so no normal detail on a glow and the material's own
// specular (never less: a glow must not get darker). Only the colour moves, never down on average: a slow variation
// inside the bright part of the glow (zero mean), the hot core a little brighter, and optional LED grid / scanlines
// (zero mean). A black screen has no colour to move: its LED grid is in the light (each pixel domed, the gaps matte).
MatOut mat_emissive_light(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0) return o;
    float lum = MatLum(m.albedo);
    vec3 c = m.albedo;
    if (m.p.y > 0.0) {
        float F0, fb;
        MatOctave(m, 3.0 * m.scale, F0, fb);
        float k = MatFadeUv(m, F0 * (1.0 + fb));
        float n = mix(MatGNoise(m.uv * F0, F0).x, MatGNoise(m.uv * (2.0 * F0) + 5.0, 2.0 * F0).x, fb);
        // Bright texels vary the most (the hot core flickers), dark ones stay put, and a saturated channel (which
        // would clip the upper half and darken on average) not at all.
        float mx = max(c.r, max(c.g, c.b));
        c *= 1.0 + 0.12 * m.p.y * k * smoothstep(0.1, 0.6, lum) * (1.0 - smoothstep(0.85, 0.98, mx)) * n;
    }
    // Hot core: a little brighter and a touch toward white.
    float hot = smoothstep(0.6, 1.0, lum);
    c *= 1.0 + 0.07 * hot;
    c = mix(c, vec3(max(c.r, max(c.g, c.b))), 0.06 * hot);
    float pat = 1.0;
    if (m.p.z > 0.0) {
        // Cells with gaps of about an eighth of a cell; the gap term's mean over a cell is 0.231, so the pattern
        // (and the specular one) averages to exactly 1. Faded by the gap's own frequency, not the cell's.
        vec2 f = fract(m.uv * m.p.z) - 0.5;
        float line = smoothstep(0.75, 1.0, 2.0 * max(abs(f.x), abs(f.y)));
        float kk = MatFadeUv(m, 5.0 * m.p.z);
        pat *= 1.0 + 0.3 * kk * (0.231 - line);
        o.spec = 1.0 + 0.8 * kk * (0.231 - line);
        o.gloss = 1.0 + 1.5 * kk;
        // Each LED a shallow dome (the slope grows from the centre), the gaps flat.
        o.dn = MatBumpUv(m, -f * (1.0 - line) * (0.5 * kk / m.uvPerWorld));
    }
    if (m.p.w > 0.0) {
        float sl = 4.0 * m.p.w, kk = MatFadeUv(m, 2.0 * sl);
        pat *= 1.0 + 0.16 * kk * cos(6.2831853 * m.uv.y * sl);
    }
    o.albedo = c * pat;
    return o;
}
