// @class fabric_cloth
// @default scale=1 strength=1 rough=0 wear=0 tint=1 a=0.25 b=0
// @param tint: thread-to-thread and band colour variation (1 = about 3% either way)
// @param wear: faded, pilled spots (0 none, 0.5 well used)
// @param a: thread spacing in world units (0.25 cotton twill; 0.4 canvas, burlap; 0.15 silk, satin ribbon)
// @param b: finish: -1 felt, wool or velvet nap (fuzz, no weave); 0 woven cotton or canvas; 1 satin or silk (sheen)
// Cloth: the painted folds get real relief from the art's own shading, the threads of the shared weave map (felt: a
// fine fuzz instead) come in close up, bands of slightly thicker and thinner threads stay from mid distance, and the
// game's plastic-like highlight becomes a broad, dim cloth sheen with a light lift at grazing angles (satin: a
// tighter, brighter one). Atlas parts that are not cloth keep the game's material: skin-like peach texels and dense
// art detail (chains, badges, rivets, lens rims: texels far from their blurred surroundings).
// Reads texture0 (the host's bound texture, declared before the materials block) for the blurred relief taps.

// The 1D value noise of whole cells along x (period P cells, seamless with the texture), -0.5..0.5.
float mat_fabric_cloth_band(float x, float P, float salt) {
    float i = floor(x), f = fract(x);
    float h0 = MatHash12(vec2(mod(i, P), salt)), h1 = MatHash12(vec2(mod(i + 1.0, P), salt));
    return mix(h0, h1, f * f * (3.0 - 2.0 * f)) - 0.5;
}

// Bands of 4 threads along u and along v at the weave's octave F (threads 16 a tile): (u bands, v bands).
vec2 mat_fabric_cloth_bands(MatIn m, float F) {
    float P = 4.0 * F;
    return vec2(mat_fabric_cloth_band(m.uv.y * P, P, 3.7 + m.seed), mat_fabric_cloth_band(m.uv.x * P, P, 9.1 + m.seed));
}

MatOut mat_fabric_cloth(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0) return o;
    vec3 c = m.albedo;
    float b = clamp(m.p.w, -1.0, 1.0), felt = max(-b, 0.0), satin = max(b, 0.0);
    float tint = m.p.y;

    // ---- atlas key: 1 cloth, 0 keep the game's material. Peach skin (hands, faces in the glove and hat atlases) here,
    // dense art detail (busy, below) once the blurred taps are in.
    float r = max(c.r, 1e-3);
    float skin = step(c.g, c.r) * step(c.b, c.g) * smoothstep(0.5, 0.62, c.r)
               * (1.0 - smoothstep(0.07, 0.12, abs(c.g / r - 0.65))) * (1.0 - smoothstep(0.1, 0.16, abs(c.b / r - 0.42)));
    // ---- folds: the art's painted shading as soft relief (bright = raised). Three taps of the art blurred a mip or
    // two above the pixel's own (stipple and texel steps gone, the painted folds kept), a few texels apart.
    vec2 tsz = vec2(textureSize(texture0, 0));
    float lod = max(log2(max(m.uvPx * max(tsz.x, tsz.y), 1e-6)), 0.0) + 1.5;
    vec2 e = exp2(lod) / tsz;
    vec2 tc = m.uv - 0.5 * e;
    vec3 t0 = textureLod(texture0, tc, lod).rgb;
    vec3 su = textureLod(texture0, tc + vec2(e.x, 0.0), lod).rgb;
    vec3 sv = textureLod(texture0, tc + vec2(0.0, e.y), lod).rgb;
    float l0 = MatLum(t0), lu = MatLum(su), lv = MatLum(sv);
    // Printed colour boundaries (stripes, panels, logos, a band in another colour) are flat, not folds. A print border
    // is a sharp step in the art that also changes chromaticity (rgb over its sum: hue and saturation); painted
    // shading is a smooth ramp (the texel close to its blurred surroundings), and a painted crease keeps its hue.
    // Where both hold, the step gets no relief. (Measured on the class: shading's chromaticity step is under a tenth
    // of its relative value step on most textures, up to a half on the cushion's red-to-purple ramps, so the hue test
    // alone cannot tell them apart; the sharpness does.)
    vec3 q0 = t0 / max(dot(t0, vec3(1.0)), 0.08);
    float dq = max(length(su / max(dot(su, vec3(1.0)), 0.08) - q0), length(sv / max(dot(sv, vec3(1.0)), 0.08) - q0));
    float dl = max(abs(lu - l0), abs(lv - l0)) / max(l0, 0.05);
    float sharp = length(c - (t0 + su + sv) / 3.0) / (length(su - t0) + length(sv - t0) + 0.02);
    float print = smoothstep(0.1, 0.2, dq / (dl + 0.03)) * smoothstep(0.12, 0.3, sharp);
    // Dense detail (a chain, rivets, a badge's rim): the texel far from its blurred surroundings.
    float busy = smoothstep(0.1, 0.25, abs(MatLum(c) - (l0 + lu + lv) / 3.0));
    float cloth = (1.0 - skin) * (1.0 - 0.85 * busy);
    // Relief 2.2 world units per unit of luminance (scaled), slopes capped at 0.25.
    vec3 fold = MatBumpUv(m, vec2(lu - l0, lv - l0) / e * (2.2 * m.scale));
    // Toward the shadow side a third of it: there tilts toward the sun add light and tilts away clamp at zero, which
    // would brighten the whole surface.
    // Glossy game materials (eyepatches, the bishop's mitre, gloss 20 to 40): the folds and threads would break their
    // tight highlight into crinkled streaks; there the folds are a third, the threads a seventh, the threads' crowns
    // leave the highlight alone, and the lobe broadens (below).
    float glossy = smoothstep(12.0, 36.0, materialMatrix[3].y);
    float calm = 1.0 - 0.7 * glossy;
    fold *= min(1.0, 0.25 / max(length(fold), 1e-5)) * (1.0 - skin) * (1.0 - print) * mix(0.3, 1.0, smoothstep(-0.1, 0.35, m.ndl));
    o.dn += fold * mix(1.0, 0.6, satin) * calm;

    // ---- threads: the weave map, 16 threads a tile, two octaves blended. Felt: the grain map as a nap of fibre
    // clumps (a tile 10 world units across, clumps about 0.12 apart), with a faint mottle in the paint.
    float F0, fb;
    MatOctave(m, felt > 0.5 ? 10.0 * m.scale : 16.0 * max(m.p.z, 0.02) * m.scale, F0, fb);
    float texels = felt > 0.5 ? 3.0 : 8.0;  // (fully in at 4 px a feature: 8 px a thread, 4 px a clump; gone at half)
    float kw = MatMapFade(m, F0 * (1.0 + fb), texels);
    float h = 0.0, v = 0.0;
    if (kw > 0.0) {
        float layer = felt > 0.5 ? MAT_MAP_GRAIN : MAT_MAP_WEAVE;
        vec4 s = mix(MatMapAt(m, layer, F0, vec2(0.0)), MatMapAt(m, layer, 2.0 * F0, vec2(0.37, 0.61)), fb);
        s = MatMapNeutral(s, kw * cloth);
        o.dn += MatMapBump(m, s, (felt > 0.5 ? 0.7 : 0.5 - 0.2 * satin - 0.32 * felt) * (1.0 - 0.85 * glossy));
        h = MatMapHeight(s);
        v = MatMapVar(s);
        o.ao *= 1.0 + 0.8 * min(h, 0.0);
    }

    // ---- bands of thicker and thinner threads, four threads wide: they outlast the threads (in at 8 px a band).
    float kb = felt > 0.5 ? 0.0 : MatFadeUv(m, 2.0 * F0 * (1.0 + fb)) * cloth * (1.0 - felt);
    float band = 0.0;
    if (kb > 0.0) {
        vec2 bd = mix(mat_fabric_cloth_bands(m, F0), mat_fabric_cloth_bands(m, 2.0 * F0), fb);
        band = (bd.x + bd.y) * kb;
    }

    // ---- colour: per thread and per band, a few percent, the hue kept.
    o.albedo = MatVary(c, 0.05 * tint, 1.2 * v * (felt > 0.5 ? -0.7 : 1.0 - felt) + 1.2 * band);

    // ---- sheen: cloth scatters toward grazing angles (fibres standing off the surface); about mean-neutral.
    float graze = 1.0 - m.ndv;
    graze *= graze * graze;
    o.albedo *= 1.0 + cloth * mix(0.14, 0.32, felt) * (1.0 - 0.5 * satin) * (graze - 0.12);

    // ---- highlight: matte cloth broad and dim, felt dimmer, satin tighter and brighter; threads' crowns catch it.
    // Glossy materials: a soft, broad lobe (a third of the exponent) instead of the tight one; the lighting's
    // normalised lobe keeps its energy, but the tight hot spot clipped at white and the broad one does not: the
    // specular comes down by almost half to keep the surface's brightness.
    float sp = mix(mix(0.7, 0.65, felt), 1.35, satin) * (1.0 + (0.8 * h + 0.6 * band) * (1.0 - glossy)) * (1.0 - 0.45 * glossy);
    float gl = mix(mix(mix(0.6, 0.55, felt), 2.2, satin), 0.35, glossy) * (1.0 - 0.4 * band);
    o.spec = mix(1.0, sp, cloth);
    // The lighting takes the sun's diffuse down by half the specular (energy kept): a lower specular lifts the paint,
    // which on a glossy white (70cb8e) outweighs the dimmer lobe. Give back about a third of that on the glossy
    // materials (all of it overshoots: the paint scale also reaches the ambient); measured, they then stay within 4%
    // of Sunstone without detail.
    float sk = dot(materialMatrix[0].xyz, vec3(0.333)) * sunstoneSpecular * 0.5;
    o.albedo *= 1.0 + 0.3 * glossy * ((1.0 - min(sk, 0.5)) / (1.0 - min(sk * o.spec, 0.5)) - 1.0) * smoothstep(-0.1, 0.35, m.ndl);
    o.gloss = mix(1.0, gl, cloth);

    // ---- wear (uniform): faded, pilled patches, a little lighter and greyer, threads flattened, rougher.
    if (m.p.x > 0.0) {
        vec4 w = MatMapWorld(m, MAT_MAP_WEAR, 24.0 * m.scale, 4.0);
        float worn = smoothstep(1.0 - m.p.x, 1.0 - m.p.x + 0.08, w.a) * cloth;
        float l = MatLum(o.albedo);
        o.albedo = mix(o.albedo, mix(vec3(l), o.albedo, 0.8) * 1.06, 0.6 * worn);
        o.gloss *= 1.0 - 0.4 * worn;
        o.dn *= 1.0 - 0.5 * worn;
    }

    // ---- energy: a tilted sunlit normal loses 1 - 1/sqrt(1 + slope^2) of the sun whichever way it tilts, which
    // would darken the cloth as a whole; give that back in the paint where the sun reaches.
    o.albedo *= 1.0 + (sqrt(1.0 + dot(o.dn, o.dn)) - 1.0) * smoothstep(-0.1, 0.35, m.ndl);
    return o;
}
