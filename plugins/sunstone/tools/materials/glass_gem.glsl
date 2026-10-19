// @class glass_gem
// @default scale=1 strength=1 rough=0 wear=0 tint=1 a=0 b=0.1
// @param wear: (no wear on glass) the art mask of an atlas: 0 every texel is glass; 1 gold, brown and unsaturated
// texels (bezels, corks, labels) keep their own look
// @param tint: a gem's inner variation of colour (1 = 3% either way); smooth glass and eyes have none
// @param a: facets per texture unit (0 = smooth glass, eyes, lenses: only the wet highlight)
// @param b: facet tilt (radians): how far each facet bends the highlight
// Gems, glass, eyes and lenses. Smooth glass: a tighter, wet highlight where the surface faces the eye. Gems: irregular
// facets (a Voronoi of the texture, so they wrap with it) that each tilt the highlight their own way, edges blended over
// a pixel, and a few facets that catch it hard (glints). The specular scale stays the material's own (the lighting is
// energy-conserving: a higher gloss is a smaller, brighter highlight at the same mean), so nothing darkens or blows out.
MatOut mat_glass_gem(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0) return o;
    vec3 c = m.albedo;
    // The art mask (uniform when wear is 0): gold and brown (red over green and blue) and grey texels are not glass.
    float glass = 1.0;
    if (m.p.x > 0.0) {
        float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b));
        float sat = (mx - mn) / max(mx, 0.02);
        float warm = smoothstep(0.02, 0.1, min(c.r - c.b, c.r - c.g + 0.15));
        glass = mix(1.0, (1.0 - warm) * smoothstep(0.15, 0.35, sat), m.p.x);
    }
    if (m.p.z <= 0.0) {
        // Smooth: a wet highlight, tight only where the surface faces the eye (no glare at the rim).
        o.gloss = 1.0 + 5.0 * glass * smoothstep(0.35, 0.75, m.ndv);
        return o;
    }
    o.gloss = 1.0 + 1.0 * glass;
    // Facets: the nearest and second-nearest of jittered points, a whole number of cells per texture unit (wraps).
    float Fc = max(floor(m.p.z + 0.5), 1.0);
    float k = MatFadeUv(m, Fc) * glass;
    if (k <= 0.0) return o;
    vec2 p = m.uv * Fc, ip = floor(p), fp = p - ip;
    float d1 = 9.0, d2 = 9.0;
    vec2 h1 = vec2(0.0), h2 = vec2(0.0);
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            vec2 e = vec2(float(i), float(j));
            vec2 r = MatHash22(mod(ip + e, Fc) + 17.0 * m.seed);
            vec2 q = e + 0.15 + 0.7 * r - fp;
            float d = dot(q, q);
            if (d < d1) {
                d2 = d1; h2 = h1; d1 = d; h1 = r;
            } else if (d < d2) {
                d2 = d; h2 = r;
            }
        }
    }
    d1 = sqrt(d1);
    d2 = sqrt(d2);
    // Each facet's tilt (x, y in -1..1) and whether it is a glint facet (one in five): from its hash, re-mixed.
    vec2 t1 = fract(h1 * 37.17 + h1.yx * 11.31), t2 = fract(h2 * 37.17 + h2.yx * 11.31);
    // Across the edge between two facets (half the distance difference, in cells) the tilt blends over one pixel.
    float px = max(Fc * m.uvPx, 1e-4);
    float w = 0.5 + 0.5 * smoothstep(0.0, 1.0, 0.5 * (d2 - d1) / px);
    vec2 t = mix(t2, t1, w) * 2.0 - 1.0;
    o.dn = (t.x * m.tu + t.y * m.tv) * (m.p.w * k);
    // Glints: one facet in five is cut toward the light. It turns to the half vector, and much glossier, once the face
    // is within its own random angle of it (0 to about 45 degrees): a few facets spark on a face turned to the light,
    // more near the highlight, none on a face turned away; each switches on over a few degrees as the gem turns.
    vec3 hv = normalize(m.l + m.v);
    float ndh = dot(m.n, hv);
    float r1 = fract(h1.x * 53.7), r2 = fract(h2.x * 53.7);
    float g1 = step(0.8, r1) * smoothstep(0.7 + 1.5 * (r1 - 0.8), 0.74 + 1.5 * (r1 - 0.8), ndh);
    float g2 = step(0.8, r2) * smoothstep(0.7 + 1.5 * (r2 - 0.8), 0.74 + 1.5 * (r2 - 0.8), ndh);
    float g = k * mix(g2, g1, w) * smoothstep(0.0, 0.15, m.ndl);
    o.dn = mix(o.dn, hv - m.n * ndh, 0.9 * g);
    o.gloss *= 1.0 + 3.0 * g;
    // A faint inner variation of the colour, per facet (a gem's depth), 3% either way at tint 1.
    o.albedo = MatVary(c, 0.03 * m.p.y * k, mix(t2.x, t1.x, w) * 2.0 - 1.0);
    return o;
}
