// ---- _evaluate.glsl: the tag, the switches and the blend of a snippet's result (after the generated MatDispatch).

// For the debug views: the class drawn (0 generic), whether it was tagged, and the snippet's own fade, normal detail
// and cavity before the mask.
int matClass = -1;
float matTagged = 0.0;
float matDbgFade = 0.0;
vec3 matDbgDn = vec3(0.0);
float matDbgAo = 1.0;

// Uniform: whether any fragment of this draw gets material detail (Sunstone's lighting on, not its grey view).
bool MatEnabled() {
    return sunstoneMatDetail > 0.0 && sunstoneLight > 0.5 && !(sunstoneLight > 9.5 && sunstoneLight < 10.5);
}

// Per fragment: 0 left of the A/B split or where the game's lighting is kept.
float MatMask() {
    return gl_FragCoord.x < sunstoneMatSplit || GameTerms() ? 0.0 : 1.0;
}

// The class and parameters for this draw (Melange's tag, else a guess from the material), the snippet's result, and
// that result scaled by the detail amount, the tag's strength and the fade, with the tag's roughness bias.
MatOut MatEvaluate(MatIn m) {
    vec4 t0 = mg_texTag[0], t1 = mg_texTag[1];
    int c = int(floor(t0.x + 0.5));
    if (c < 1 || c > MAT_CLASSES) {
        // Untagged (or an older Melange): the material's specular and gloss tell metal from the standard matte.
        bool metal = materialMatrix[3].y >= 30.0 && dot(materialMatrix[0].xyz, vec3(0.333)) >= 0.5;
        c = metal ? MAT_FALLBACK_METAL : MAT_FALLBACK_MATTE;
        MatDefaults(c, t0, t1);
        m.tagged = 0.0;
    } else {
        m.tagged = 1.0;
    }
    m.scale = t0.y > 0.0 ? t0.y : 1.0;
    m.strength = max(t0.z, 0.0);
    m.p = t1;
    m.seed = MatHash12(vec2(t0.y * 13.1 + t1.x * 7.7 + t1.z * 3.3 + float(c), t0.z * 5.3 + t1.y * 11.9 + t1.w * 2.9));
    MatOut o = MatDispatch(c, m);
    // A tilt of more than about 35 degrees is never wanted (a snippet's division by a degenerate density or gradient).
    o.dn *= min(1.0, 0.7 / max(length(o.dn), 1e-6));
    float k = clamp(sunstoneMatDetail * m.strength * m.fade, 0.0, 2.0);
    o.gloss *= exp2(-2.0 * t0.w);
    o.spec *= exp2(-t0.w);
    MatOut r;
    r.albedo = clamp(mix(m.albedo, o.albedo, k), 0.0, 1.0);
    r.spec = max(mix(1.0, o.spec, k), 0.0);
    r.gloss = max(mix(1.0, o.gloss, k), 0.05);
    r.dn = o.dn * k;
    r.ao = clamp(mix(1.0, o.ao, k), 0.0, 1.0);
    matClass = c;
    matTagged = m.tagged;
    matDbgFade = k;
    matDbgDn = r.dn;
    matDbgAo = r.ao;
    return r;
}

// The lighting's material terms for Light(): specular scale, gloss scale, cavity; vec3(1.0) none.
vec3 MatLightTerms(MatOut o, float w) {
    return vec3(mix(1.0, o.spec, w), mix(1.0, o.gloss, w), mix(1.0, o.ao, w));
}

// The debug views (sunstoneMatDebug), by the lit colour's brightness. 1: a colour per class (generic grey; untagged
// striped; no detail, e.g. the worm's own material, skin and hair, near black). 2: the detail amount after fade.
// 3: the normal detail. 4: the cavity.
vec3 MatDebug(vec3 col, float w) {
    if (sunstoneMatDebug < 0.5 || matClass < 0) return col;
    float sh = 0.35 + 0.65 * clamp(MatLum(col) * 1.6, 0.0, 1.0);
    if (sunstoneMatDebug > 3.5) return vec3(matDbgAo) * w;
    if (sunstoneMatDebug > 2.5) return (matDbgDn * 4.0 + 0.5) * w;
    if (sunstoneMatDebug > 1.5) return vec3(matDbgFade * w, 0.3 * (1.0 - w), 0.0) + 0.15 * sh;
    if (w <= 0.0) return vec3(0.08) * sh;
    // (Hues 7/26 of a turn apart by id, every other id darker: neighbouring ids never look alike.)
    float id = float(matClass);
    vec3 c = matClass == 0 ? vec3(0.6) : (0.5 + 0.5 * cos(6.2831 * (fract(id * 7.0 / 26.0) + vec3(0.0, 0.33, 0.67))))
                                         * (mod(id, 2.0) < 0.5 ? 0.6 : 1.0);
    if (matTagged < 0.5 && fract((gl_FragCoord.x + gl_FragCoord.y) / 12.0) < 0.5) c *= 0.45;
    return c * sh;
}
// ---- end _evaluate.glsl
