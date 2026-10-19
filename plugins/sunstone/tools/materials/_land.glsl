// ---- _land.glsl: the landscape's material detail, the light tier (owned by the library, not by a class worker).
// The models' snippets cost 0.3 to 0.9 ms more than the landscape's own shading on a 4K screen of landscape (2x2
// supersampled Ultra; GL timer queries on an RX 7800 XT), several times the 0.2 ms the landscape may take of the 0.5 ms
// Ultra budget: their gradient noises and art taps are sized for a prop that covers part of the screen, while the
// landscape covers most of it. So the landscape draws each class from what its model snippet is mostly made of, the
// shared material maps, at the same world sizes: one map sample a class (painted metal two: its wear), one octave (the
// landscape's texel density is the same over a whole surface, so no size can jump between triangles), the relief, the
// cavity, a little albedo variation, and the class's sheen. The art's own carving is the landscape's texture relief.
//
// The tag's fields: scale (feature size), strength, rough, wear (painted and rusted metal: chips; stone: grime in the
// pits), tint (albedo variation); a and b as the class snippet reads them where noted (wood: b's grain direction; sand:
// a clods; painted metal: a its gloss; stone: a < 0 polished).
// @classes stone_rock=6 brick=25 concrete_plaster=22 sand_dirt=20 wood_planks=7 grass_turf=24 leaf_foliage=4 snow_ice=23 rusted_metal=16 painted_metal=1

// One shared-map sample with features about tileWorld world units a tile, its power of two nearest the size (a whole
// number of map tiles per texture repeat keeps the landscape's tiling seamless), faded to neutral by its footprint.
// swap: the layer's direction (wood and brushed run along u) along v instead.
vec4 MatLandMap(MatIn m, float layer, float tileWorld, float texels, vec2 offset, bool swap) {
    float F = exp2(floor(clamp(-log2(max(tileWorld * m.uvPerWorld, 1e-6)), 0.0, 13.0) + 0.5));
    vec2 uv = swap ? m.uv.yx : m.uv, dx = swap ? m.uvDx.yx : m.uvDx, dy = swap ? m.uvDy.yx : m.uvDy;
    vec4 s = textureGrad(sunstoneMat, vec3(uv * F + offset, layer), dx * F, dy * F);
    return MatMapNeutral(s, MatMapFade(m, F, texels));
}

// MatMapBump for a sample taken with swap: its x runs along v.
vec3 MatLandBump(MatIn m, vec4 s, float amount, bool swap) {
    vec2 t = (s.xy * 2.0 - 1.0) * amount;
    return swap ? t.x * m.tv + t.y * m.tu : t.x * m.tu + t.y * m.tv;
}

MatOut mat_land(MatIn m, int c) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.0) return o;
    // Per class (a uniform chain): the map, its tile (world units) and feature size (texels), relief, cavity, albedo
    // variation, specular and gloss. Defaults: stone and rock (the stone map, about 28 units: pits, veins, mottle).
    float layer = MAT_MAP_STONE, tile = 28.0, texels = 6.0, bump = 0.35, cav = 0.25, vary = 0.03, spec = 1.0, gloss = 1.0;
    bool swap = false, metal = false;
    if (c == 25) {                                  // brick, tile: fired clay, pits and sandy grain
        tile = 16.0; bump = 0.3; cav = 0.3;
    } else if (c == 22) {                           // concrete and plaster: pores, very matte
        tile = 18.0; bump = 0.3; cav = 0.2; vary = 0.025; spec = 0.85; gloss = 0.8;
    } else if (c == 20) {                           // sand and dirt: clods and pebbles, matte
        tile = 24.0; texels = 4.0; bump = 1.1 * m.p.z; cav = 0.3 * m.p.z; vary = 0.08; spec = 0.8; gloss = 0.7;
    } else if (c == 7) {                            // wood: grain along the art's grain, latewood sheen
        layer = MAT_MAP_WOOD; tile = 14.0; bump = 0.3; cav = 0.25; vary = 0.045; swap = mod(m.p.w, 2.0) >= 0.5;
    } else if (c == 24) {                           // grass: soft clumps
        layer = MAT_MAP_BUMPS; tile = 14.0; texels = 8.0; bump = 0.3; cav = 0.06; vary = 0.015; spec = 0.95; gloss = 0.6;
    } else if (c == 4) {                            // leaves: pebbled, a waxy sheen
        layer = MAT_MAP_BUMPS; tile = 12.0; texels = 8.0; bump = 0.25; cav = 0.1; vary = 0.03; spec = 1.1; gloss = 1.4;
    } else if (c == 23) {                           // snow and ice: fine grain, a sparkle of gloss
        layer = MAT_MAP_GRAIN; tile = 4.0; texels = 3.0; bump = 0.3; cav = 0.08; vary = 0.02; spec = 1.4; gloss = 1.6;
    } else if (c == 16) {                           // rusted metal: pitted, flaking, rough
        tile = 24.0; texels = 4.0; bump = 0.45; cav = 0.3; vary = 0.06; spec = 0.75; gloss = 0.5;
    } else if (c == 1) {                            // painted metal: fine paint grain; chips below
        layer = MAT_MAP_GRAIN; tile = 6.0; texels = 3.0; bump = 0.12; cav = 0.0; vary = 0.02;
        spec = mix(1.05, 1.3, clamp(m.p.z, 0.0, 1.0)); gloss = mix(1.0, 2.0, clamp(m.p.z, 0.0, 1.0)); metal = true;
    }
    vec4 s = MatLandMap(m, layer, tile * m.scale, texels, vec2(0.0), swap);
    float h = MatMapHeight(s), v = MatMapVar(s);
    float pit = smoothstep(-0.2, -0.42, h);
    o.dn = MatLandBump(m, s, bump, swap);
    o.ao = 1.0 - cav * pit;
    o.albedo = MatVary(m.albedo, vary * m.p.y, 2.0 * v);
    o.spec = spec * (1.0 - 0.5 * pit + 0.4 * max(h, 0.0));
    o.gloss = gloss * (1.0 - 0.3 * pit + 0.5 * max(h, 0.0));
    if (c == 6) {
        // Stone: grime (moss where the pits face the sky) by wear; polished (a < 0): a glassy sheen, no pits.
        float pol = clamp(-m.p.z, 0.0, 1.0);
        o.albedo *= mix(vec3(1.0), mix(vec3(0.85), vec3(0.84, 0.95, 0.78), smoothstep(0.55, 0.9, m.sky)), pit * m.p.x * 0.35);
        o.dn *= 1.0 - 0.75 * pol;
        o.gloss *= 1.0 + 1.5 * pol;
        o.spec *= 1.0 + 0.6 * pol;
    } else if (c == 7) {
        // Wood: latewood (darker bands) denser and a faint sheen, open pores rough.
        o.spec = 1.0 + 0.7 * -v + 0.35 * h;
        o.gloss = 1.0 + 0.6 * -v;
    }
    if (metal && m.p.x > 0.0) {
        // Painted metal: the wear map (a uniform branch on the tag), worn where its order passes 1 - wear: scuffed
        // paint, chips through the coat to steel.
        vec4 w = MatLandMap(m, MAT_MAP_WEAR, 40.0 * m.scale, 3.0, fract(m.seed * vec2(0.37, 0.71)), false);
        float thr = max(1.0 - 0.7 * m.p.x, 0.53);
        float worn = smoothstep(thr, thr + 0.03, w.a);
        float chip = worn * (1.0 - smoothstep(-0.2, -0.06, MatMapHeight(w)));
        float lum = MatLum(m.albedo);
        o.albedo = mix(o.albedo, vec3(mix(lum, 0.45, 0.35)) * vec3(0.95, 0.98, 1.03), 0.7 * chip);
        o.gloss = mix(o.gloss * (1.0 - 0.5 * (worn - chip)), 8.0, chip);
        o.spec = mix(o.spec, 2.2, chip);
        o.dn += MatMapBump(m, w, 1.0) * smoothstep(thr - 0.05, thr + 0.02, w.a);
        o.ao = 1.0 - 0.12 * chip;
    }
    return o;
}
// ---- end _land.glsl
