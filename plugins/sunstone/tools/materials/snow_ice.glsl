// @class snow_ice
// @default scale=1 strength=1 rough=0 wear=0 tint=1 a=1 b=1
// @param tint: unused
// @param a: sparkle amount (1 normal, 0 none)
// @param b: relief amount (1 normal)
// Snow and ice: soft lumps in the light up close (full while a lump covers 32 pixels on the worse screen axis, gone at
// 16, so flat snow stays flat from afar and at grazing), a fine grain, and static sparkle: small soft facets at hashed
// points on the surface that flash only where they mirror the sun to the eye, and change nothing otherwise. Saturated
// cold texels read as ice (glossy, smooth); dark or warm texels in an atlas (rock, wood, coal) get none of the sparkle
// and a little rocky grain. Lumps, grain and sparkle blend their two octaves (MatOctave, one offset or seed for both,
// so the pattern is continuous where floor() flips) and sizes never jump between triangles.
// 2 map fetches, 2 noise calls, 2 hashes.

// A layer about tileWorld units a tile, both octaves blended with one offset (MatMapWorld's two
// offsets make a pixel maze where the texel density sits on a power of two).
vec4 mat_snow_ice_map(MatIn m, float layer, float tileWorld, float texels, vec2 off) {
    float F0, fb;
    MatOctave(m, tileWorld, F0, fb);
    vec4 s = mix(MatMapAt(m, layer, F0, off), MatMapAt(m, layer, 2.0 * F0, off), fb);
    return MatMapNeutral(s, MatMapFade(m, F0 * (1.0 + fb), texels));
}

// One octave of sparkle at F cells per texture unit: in one cell of three a facet, a dot of radius r cells at a hashed
// point, soft-edged and 0 at the cell's border, tilted by a hashed slope up to about 30 degrees. It flashes only while
// its facet mirrors the sun to the eye (within about 10 degrees of the half vector), so nothing changes off the flash
// (a raised specular alone would cost the dot diffuse light, see Light()'s keep, and leave it darker than the snow).
// Faded until the dot covers 4 pixels on the worse screen axis (0 at 2). (flash 0..1, the facet's normal tilt while it flashes).
vec4 mat_snow_ice_glint(MatIn m, float F, float r) {
    vec2 q = m.uv * F;
    vec3 h = MatHash32(mod(floor(q), F) + 11.0);
    vec2 ctr = vec2(r + 0.05) + h.xy * (1.0 - 2.0 * r - 0.1);
    float dot1 = 1.0 - smoothstep(0.3 * r, r, length(fract(q) - ctr));
    vec2 t = (fract(h.yx * 7.31 + h.z * 3.7) - 0.5) * 1.1;
    vec3 tilt = t.x * m.tu + t.y * m.tv;
    float al = dot(normalize(m.n + tilt), normalize(m.l + m.v));
    float k = dot1 * step(0.67, h.z) * MatFadeCells(F * m.uvPx * 0.5 / r);
    float fl = k * smoothstep(0.982, 0.996, al);
    return vec4(fl, fl * tilt);
}

MatOut mat_snow_ice(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0) return o;
    float lum = MatLum(m.albedo);
    float mx = max(m.albedo.r, max(m.albedo.g, m.albedo.b)), mn = min(m.albedo.r, min(m.albedo.g, m.albedo.b));
    float sat = (mx - mn) / max(mx, 1e-3);
    float cold = step(m.albedo.r, m.albedo.b + 0.02);
    float snow = smoothstep(0.45, 0.7, lum) * (1.0 - smoothstep(0.25, 0.5, sat) * (1.0 - cold));
    float ice = smoothstep(0.12, 0.3, sat) * cold * smoothstep(0.35, 0.6, lum);
    float rock = 1.0 - max(snow, ice);
    // Soft lumps about 5 units across: light only (bump and a 2% mottle, no cavity), each octave faded while a lump
    // still covers 32 pixels on the worse screen axis (m.uvPx), long before it could turn into a blotch pattern.
    float F0, fb;
    MatOctave(m, 5.0 * m.scale, F0, fb);
    float k0 = MatFadeCells(8.0 * F0 * m.uvPx) * (1.0 - fb);
    float k1 = MatFadeCells(16.0 * F0 * m.uvPx) * fb;
    vec3 n0 = MatGNoise(m.uv * F0 + 3.1, F0), n1 = MatGNoise(m.uv * (2.0 * F0) + 3.1, 2.0 * F0);
    vec3 nl = vec3(k0 * n0.x + k1 * n1.x, k0 * F0 * n0.yz + k1 * 2.0 * F0 * n1.yz);
    o.dn = MatBumpUv(m, nl.yz * (0.45 * m.scale * m.p.w) * (1.0 - 0.5 * ice));
    o.albedo = MatVary(m.albedo, 0.02, nl.x * 2.0);
    // Fine grain (the grain map, tile about 4 units, octaves blended and faded).
    vec4 g = mat_snow_ice_map(m, MAT_MAP_GRAIN, 4.0 * m.scale, 3.0, vec2(0.31, 0.77));
    o.dn += MatMapBump(m, g, (0.2 + 0.5 * rock) * (1.0 - 0.7 * ice));
    o.ao = 1.0 + 0.15 * min(MatMapHeight(g), 0.0);
    // Sparkle: cells about 0.6 units, one in three with a facet dot of radius 0.22 cells; only on snow and ice.
    float Fs, bs;
    MatOctave(m, 0.6 * m.scale, Fs, bs);
    vec4 gl = mix(mat_snow_ice_glint(m, Fs, 0.22), mat_snow_ice_glint(m, 2.0 * Fs, 0.22), bs) * ((1.0 - rock) * m.p.z);
    float glint = gl.x;
    o.dn += gl.yzw;
    o.spec = 1.0 + (0.8 + 5.0 * glint) * (0.4 + 0.6 * snow) - 0.4 * rock + 1.2 * ice;
    o.gloss = 1.0 + 3.0 * glint + 1.5 * ice - 0.5 * rock;
    return o;
}
