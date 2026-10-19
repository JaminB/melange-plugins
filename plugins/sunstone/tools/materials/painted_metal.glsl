// @class painted_metal
// @default scale=1 strength=1 rough=0 wear=0.35 tint=1 a=0.5 b=7
// @param wear: chipping, scratches and rust (0 fresh paint, 0.35 used, 0.6 battered and rusting)
// @param tint: grime and paint mottle (1 = a few percent)
// @param a: paint gloss (0 flat primer .. 0.5 satin .. 1 glossy enamel)
// @param b: log2 of the texture's size in texels, 5..9 (sizes the relief taken from the art's own edges, close up)
// Painted sheet steel. From afar: a satin coat whose highlight ripples over the sheet's shallow dents and is dulled
// in soft grime blotches, worn patches showing as a cooler, sharper sheen. Close up: the art's seams and rivets pressed into the light, and wear from the shared
// wear map, gathered in patches: scuffed paint, scratches through the coat, chips showing bright steel, rust when
// battered. Two maps at two octaves each (four fetches) and two gradient noises.

// The art's luminance gradient per texel (lumD is per pixel): J^-T lumD over the texture's size.
vec2 mat_painted_metal_artSlope(MatIn m, float texels) {
    float det = m.uvDx.x * m.uvDy.y - m.uvDx.y * m.uvDy.x;
    det = abs(det) > 1e-14 ? det : 1e-14;
    vec2 g = vec2(m.uvDy.y * m.lumD.x - m.uvDx.y * m.lumD.y, m.uvDx.x * m.lumD.y - m.uvDy.x * m.lumD.x) / det;
    return g / texels;
}

// A shared map a tile about tileWorld across, as MatMapWorld but shifted by this texture's seed (both octaves by
// their own offsets), so every painted texture gets its own chips and scratches. kf: the footprint fade.
vec4 mat_painted_metal_map(MatIn m, float layer, float tileWorld, float texels, vec2 off, out float kf) {
    float F0, fb;
    MatOctave(m, tileWorld, F0, fb);
    vec4 s = mix(MatMapAt(m, layer, F0, fract(m.seed * vec2(0.37, 0.71) + off)),
                 MatMapAt(m, layer, 2.0 * F0, fract(m.seed * vec2(0.83, 0.29) + off + vec2(0.37, 0.61))), fb);
    kf = MatMapFade(m, F0 * (1.0 + fb), texels);
    return MatMapNeutral(s, kf);
}

MatOut mat_painted_metal(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0) return o;
    float lum = MatLum(m.albedo);
    // Atlases: near-black, greyish texels (tyres, holes, slots, shadows painted in) are not paint: no wear on them
    // and only half the sheen. Saturated darks (deep red, navy paint) stay paint.
    float mx = max(m.albedo.r, max(m.albedo.g, m.albedo.b));
    float sat = (mx - min(m.albedo.r, min(m.albedo.g, m.albedo.b))) / max(mx, 1e-3);
    // (A saturated dark, a deep blue-green bore or a navy hole, is paint only above about a tenth of value: chipped steel
    // would show as bright specks in it.)
    float paint = max(smoothstep(0.07, 0.2, lum), smoothstep(0.3, 0.55, sat) * smoothstep(0.08, 0.16, lum));
    float wear = clamp(m.p.x, 0.0, 1.0) * paint;

    // The sheet: a subtle ripple of shallow dents about 5 world units apart (two octaves blended so the size never jumps), 0.05 deep: any more splits a highlight on a helmet into two hot spots.
    // Their value also says where wear and grime gather.
    float F0, fb;
    MatOctave(m, 5.0 * m.scale, F0, fb);
    vec2 sd = m.seed * vec2(37.0, 71.0);
    vec3 d = mix(MatGNoise(m.uv * F0 + sd, F0) * vec3(1.0, F0, F0),
                 MatGNoise(m.uv * (2.0 * F0) + sd + 5.3, 2.0 * F0) * vec3(1.0, 2.0 * F0, 2.0 * F0), fb);
    float kd = MatFadeUv(m, F0 * (1.0 + fb));
    float clus = clamp(0.5 + 1.6 * d.x * kd, 0.0, 1.0);

    // The shared maps in world units: the wear map (chips, scratches, scuffs) a tile about 40 units across (chips
    // under a unit, shown only while one covers about six pixels), the brushed map about 16 (fine scratches at all
    // angles, and the steel's brushing inside the chips).
    // Each sampled at this texture's own offset (seeded), so no two painted textures share a chip or a scratch.
    float kw, ks;
    vec4 w = mat_painted_metal_map(m, MAT_MAP_WEAR, 40.0 * m.scale, 3.0, vec2(0.0), kw);
    vec4 s = mat_painted_metal_map(m, MAT_MAP_BRUSHED, 16.0 * m.scale, 3.0, vec2(0.53, 0.19), ks);

    // The art's own edges (seams, rivets, panel borders), per texel; only while a texel covers two pixels or more.
    float texels = exp2(clamp(m.p.w, 3.0, 11.0));
    vec2 art = mat_painted_metal_artSlope(m, texels) * MatFadeCells(m.uvPx * texels);
    art *= min(1.0, 1.0 / max(length(art), 1e-6));   // a degenerate mapping (collinear uvDx, uvDy): no wild bump
    float edge = smoothstep(0.03, 0.15, length(art));

    // Grime: a soft blotch field (the dent patches, and the wear map's quiet ground close up), more on faces turned
    // down, away from the sky.
    float mot = clamp((w.a - 0.36) * 8.0, -1.0, 1.0) * (1.0 - smoothstep(0.46, 0.5, w.a));
    float grime = clamp(0.5 - 0.25 * mot - 0.9 * d.x * kd, 0.0, 1.0) * (0.55 + 0.45 * (1.0 - m.sky)) * m.p.y;

    // Wear: worn where the order passes 1 - wear, in patches, more of it on the art's edges. Capped below the map's
    // neutral 0.5 so a faded (far) sample never reads as worn.
    float thr = max(1.0 - wear * (0.4 + 1.0 * clus) * (1.0 + 0.8 * edge), 0.53);
    float worn = smoothstep(thr, thr + 0.03, w.a);
    float hw = MatMapHeight(w);                        // < 0 in chips and scratches
    float chip = worn * (1.0 - smoothstep(-0.2, -0.06, hw));   // through the coat: steel
    float scuff = worn - chip;                         // scuffed, dulled paint
    float reach = smoothstep(thr - 0.05, thr + 0.02, w.a);  // the features' relief, a little past them
    // From afar the chips are below a pixel and the map fades to neutral: put their share of the surface back as a
    // tone (the wear map's order passes thr on about 0.55 * (0.96 - thr) of it, about two thirds of that chipped).
    float wornFar = (1.0 - kw) * 0.55 * max(0.96 - thr, 0.0);
    float chipFar = 0.65 * wornFar;
    scuff += 0.35 * wornFar;
    // Fine scratches in the coat (the brushed map's grooves), as many as the wear.
    float scr = (1.0 - smoothstep(0.2, 0.36, s.z)) * smoothstep(0.05, 0.5, wear * (0.4 + clus)) * (1.0 - chip);

    // Paint: satin to gloss, the sheen broken in soft blotches (rougher where grimy), dulled where scuffed;
    // scratches catch the light in thin broad glints.
    float gloss = mix(1.0, 2.0, m.p.z) * exp2(-0.8 * d.x * kd - 0.3 * mot - 1.1 * grime - 1.0 * scuff - 1.2 * scr);
    o.spec = mix(1.05, 1.3, m.p.z) * (1.0 - 0.3 * grime) * (1.0 + 0.8 * scr);
    gloss = mix(1.0, gloss, 0.5 + 0.5 * paint);

    // Bare steel in the chips: greyer and cooler than the paint, with small hard highlights; rusting when battered.
    float rust = smoothstep(0.4, 0.8, wear) * (0.5 + 0.5 * clus);
    // (The steel keeps about the paint's value, pulled a little toward a mid grey: the metal is in the specular.)
    vec3 steel = vec3(mix(lum, 0.45, 0.35)) * vec3(0.95, 0.98, 1.03);
    vec3 rustc = vec3(0.46, 0.25, 0.12) * (0.6 + 0.8 * lum);
    o.albedo = mix(m.albedo, mix(steel, rustc, rust), 0.7 * chip + 0.5 * chipFar);
    o.albedo = mix(o.albedo, m.albedo * vec3(1.05, 0.9, 0.78), 0.3 * rust * reach * (1.0 - chip));
    o.albedo *= 1.0 - 0.06 * (grime - 0.4) - 0.03 * scuff + 0.06 * scr;
    o.gloss = mix(gloss, 8.0 * (1.0 - 0.8 * rust), chip + 0.3 * chipFar);
    o.spec = mix(o.spec, 2.2 * (1.0 - 0.7 * rust), chip + chipFar);

    // Light: the dents, the chips' and scratches' relief, the steel's brushing in the chips, and the art's seams
    // pressed in (dark lower, light higher) a third of a texel deep. Cavity only at the chips' walls.
    o.dn = MatBumpUv(m, d.yz * (0.05 * m.scale * kd))
         + MatMapBump(m, w, 1.0) * reach
         + MatMapBump(m, s, 0.8 * chip + 0.3 * scr)
         + MatBumpUv(m, art * (0.35 / m.uvPerWorld));
    o.ao = 1.0 - 0.12 * chip;
    return o;
}
