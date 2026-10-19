// @class skin
// @default scale=1 strength=1 rough=0 wear=0 tint=0.6 a=0.5 b=0.5
// @param tint: albedo mottle (1 = a few percent)
// @param a: wet sheen (0 dry .. 1 slick)
// @param b: pore and wrinkle relief (0 none .. 1 strong)
// Non-worm skin: creatures, faces, hands, hides. Fine pores and mottle (the GRAIN map at a 5-unit tile, features well
// under a tenth of a world unit, so no cell network: up close a soft stipple in the sheen, from afar only a slightly
// broken gloss), the art's own wrinkles and stitch lines as relief (luminance as a very low height), a soft sheen on
// fleshy texels, slick where it is dark (eyes, mouths, seams) and calmer where the texel is white or grey (sleeves,
// teeth, sclera: cloth and enamel in atlases). Textures on the worm's own material (specular 0.2/0.18/0.1, gloss 5,
// e.g. the Boggy eyes) never get material detail: the shader's worm skin path draws them.
MatOut mat_skin(MatIn m) {
    MatOut o = MatNone(m.albedo);
    vec3 e = MatBumpScreen(m, m.lumD * (0.22 * m.scale));
    e *= min(1.0, 0.3 / max(length(e), 1e-5));
    if (m.fade <= 0.0) return o;
    vec3 c = m.albedo;
    float mx = max(max(c.r, c.g), c.b), mn = min(min(c.r, c.g), c.b), sat = (mx - mn) / max(mx, 1e-3), lum = MatLum(c);
    float flesh = smoothstep(0.08, 0.28, sat) * smoothstep(0.05, 0.16, lum) * (1.0 - smoothstep(0.88, 0.97, lum));
    float dark = 1.0 - smoothstep(0.04, 0.16, lum);
    vec4 g = MatMapWorld(m, MAT_MAP_GRAIN, 5.0 * m.scale, 3.0);
    float h = MatMapHeight(g), var = MatMapVar(g);
    float k = mix(1.0, 0.45, (1.0 - flesh) * (1.0 - dark));
    o.dn = (MatMapBump(m, g, 0.35 * m.p.w) + e * (1.5 * m.p.w)) * k;
    o.ao = 1.0 + 0.3 * m.p.w * min(h, 0.0) * flesh;
    o.albedo = MatVary(c, 0.04 * m.p.y * flesh, 2.0 * h);
    float wet = m.p.z;
    o.spec = 1.0 + wet * (0.9 * flesh + 1.2 * dark) - 0.3 * var * wet * flesh;
    o.gloss = 1.0 + wet * (1.4 * flesh + 2.0 * dark) - 2.0 * var * wet * flesh;
    return o;
}
