// @class fur_hair
// @default scale=1 strength=1 rough=0 wear=0 tint=1 a=0.35 b=0
// @param scale: strand and lock size (1: strands about 0.1 world units apart, about 12 locks across the texture)
// @param wear: which parts of an animal atlas are not hair (they get no strands): 0 none; otherwise strong art edges
//   (eyes, outlines) and saturated reds, blues and greens, and by step: 1 also pink skin, near-black and near-white;
//   0.75 pink and near-white (black fur); 0.5 pink and near-black (white or cream fur); 0.25 near-black and all but
//   light, unsaturated texels (wool: a sheep's skin, mouth and cape are not hair)
// @param tint: albedo variation strand to strand and lock to lock (1 = about 4% either way)
// @param a: flow, how far the strands wander from direction b (0 straight, 0.35 combed, 1 wavy fur, 2 curls; above
//   1.2 the locks go soft so the art's own painted curls lead)
// @param b: strand direction in turns from the texture's +v (0 along v, 0.25 along u; other values lose the wrap)
// Hair, fur and feathers that the Worm hair path leaves alone: strands along a direction field (b, bent by a periodic
// warp of strength a), bundled in locks of uneven width. The light does the work: a fine fibre normal across the
// strands, locks that roll and shade their partings, and in place of the material's round Blinn highlight a
// strand-shaped one, two Kajiya-Kay bands across the strands (a tight one shifted toward the tip, a broad one toward
// the root), sparkling per strand up close. The colour moves only a few percent.

// Gradient noise with its own period per axis (the strands are stretched along one axis): (value, d/dp).
vec3 mat_fur_hair_noise(vec2 p, vec2 period) {
    vec2 i = floor(p), f = fract(p), e = vec2(1.0, 0.0);
    vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0), du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
    vec2 ga = MatHash22(mod(i, period)) * 2.0 - 1.0, gb = MatHash22(mod(i + e, period)) * 2.0 - 1.0;
    vec2 gc = MatHash22(mod(i + e.yx, period)) * 2.0 - 1.0, gd = MatHash22(mod(i + 1.0, period)) * 2.0 - 1.0;
    float va = dot(ga, f), vb = dot(gb, f - e), vc = dot(gc, f - e.yx), vd = dot(gd, f - 1.0), k = va - vb - vc + vd;
    return vec3(va + u.x * (vb - va) + u.y * (vc - va) + u.x * u.y * k,
                ga + u.x * (gb - ga) + u.y * (gc - ga) + u.x * u.y * (ga - gb - gc + gd) + du * (u.yx * k + vec2(vb, vc) - va));
}

// One-dimensional gradient noise of period `period`: (value about -0.5..0.5, d/dp).
vec2 mat_fur_hair_noise1(float p, float period) {
    float i = floor(p), f = p - i;
    float g0 = MatHash12(vec2(mod(i, period), 17.0)) * 2.0 - 1.0, g1 = MatHash12(vec2(mod(i + 1.0, period), 17.0)) * 2.0 - 1.0;
    float u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0), du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
    float v0 = g0 * f, v1 = g1 * (f - 1.0);
    return vec2(v0 + u * (v1 - v0), g0 + u * (g1 - g0) + du * (v1 - v0));
}

// What of an animal's atlas is not hair (0 hair .. 1 not), keyed on the texel; wear picks the keys (see @param).
float mat_fur_hair_bare(MatIn m) {
    vec3 c = m.albedo;
    float mx = max(c.r, max(c.g, c.b)), mn = min(c.r, min(c.g, c.b)), d = max(mx - mn, 1e-4);
    float sat = (mx - mn) / max(mx, 1e-3), lum = MatLum(c);
    float hue = (mx == c.r ? mod((c.g - c.b) / d, 6.0) : (mx == c.g ? (c.b - c.r) / d + 2.0 : (c.r - c.g) / d + 4.0)) / 6.0;
    float w4 = floor(m.p.x * 4.0 + 0.5);
    float kP = w4 > 1.5 ? 1.0 : 0.0, kW = w4 > 2.5 ? 1.0 : 0.0, kB = abs(w4 - 3.0) > 0.5 ? 1.0 : 0.0;
    float kWool = w4 < 1.5 ? 1.0 : 0.0;
    // Pink skin, noses, inner ears (blue at most about 0.05 below green; cream fur, far less blue, stays hair).
    float pink = smoothstep(0.55, 0.75, mx) * smoothstep(0.12, 0.25, sat) * (1.0 - smoothstep(0.65, 0.8, sat))
               * smoothstep(0.0, 0.08, c.r - c.g) * smoothstep(-0.09, -0.03, c.b - c.g);
    // Saturated colours away from the hair hues (orange to yellow, about 0.1 turns): bombs, fuses, bands, red eyes.
    // (Reds, which no fur has, from a lower saturation: glowing eyes, combs, blood.)
    float red = 1.0 - smoothstep(0.02, 0.045, abs(fract(hue + 0.5) - 0.5));
    float paint = smoothstep(0.25, 0.4, mx) * max(smoothstep(0.7, 0.85, sat) * smoothstep(0.07, 0.11, abs(fract(hue - 0.6) - 0.5)),
                                                  smoothstep(0.4, 0.55, sat) * red);
    // Near-white and the cream of eyes and teeth.
    float white = smoothstep(0.8, 0.9, lum) * (1.0 - smoothstep(0.18, 0.26, sat));
    // Near-black, and dark greys and slates (pupils and irises), not dark browns.
    float dark = 1.0 - smoothstep(0.25, 0.33, lum), grey = 1.0 - smoothstep(0.35, 0.5, sat);
    float black = max(1.0 - smoothstep(0.08, 0.15, lum), dark * grey);
    float wool = smoothstep(0.72, 0.82, mx) * (1.0 - smoothstep(0.3, 0.4, sat));
    // The art's strong edges (pupils, outlines, teeth): the luminance step per texel of a 128-texel texture.
    float edge = smoothstep(0.08, 0.2, length(m.lumD) / max(m.uvPx * 128.0, 1e-6));
    return max(max(max(kP * pink, paint), max(kW * white, kB * black)), max(kWool * (1.0 - wool), edge));
}

MatOut mat_fur_hair(MatIn m) {
    MatOut o = MatNone(m.albedo);
    if (m.fade <= 0.01) return o;
    // The strand frame on the texture: dir along the strands, per across them (b in turns from +v).
    float ang = 6.2831853 * m.p.w;
    vec2 dir = vec2(sin(ang), cos(ang)), per = vec2(dir.y, -dir.x);
    // The flow: a periodic warp of the across coordinate c, 4 waves per texture unit (an art-sized feature, fixed to
    // the texture); its slope bends the strands, and strong it curls them.
    // Curls (a toward 2): tighter waves, and shorter strands and locks below.
    float curl = clamp(m.p.z * 0.5, 0.0, 1.0);
    float Fw = curl > 0.6 ? 8.0 : 4.0, A = m.p.z * 0.35;
    vec3 w = A > 0.0 ? mat_fur_hair_noise(m.uv * Fw, vec2(Fw)) : vec3(0.0);
    float c = dot(m.uv, per) + A * w.x / Fw, s = dot(m.uv, dir);
    vec2 gc = per + A * w.yz, gs = dir;               // d c / d uv, d s / d uv
    // The warp packs the strands closer where it bends them: the across frequency grows by |gc| (up to about 2.4 at
    // a = 2), so every footprint fade below takes that stretch.
    float stretch = max(length(gc), 1.0);
    float hairy = m.p.x > 0.0 ? 1.0 - mat_fur_hair_bare(m) : 1.0;

    // Locks: stretched gradient noise, about 12 across a texture unit and a quarter as many along. Fixed to the
    // texture: a lock is the art's feature (its painted clumps are that size). Their width varies (the across
    // coordinate warped by a 1D noise 4 waves a unit, widths 0.5 to 1.5 times), so the partings never run as even
    // meridians. Curls: the art paints its own curls, so the locks only soften them.
    float FL = max(floor(12.0 / m.scale + 0.5), 1.0), FLs = max(floor(FL / mix(4.0, 1.5, curl) + 0.5), 1.0);
    vec2 lw = mat_fur_hair_noise1(c * 4.0, 4.0);
    float lws = 1.0 + 0.33 * lw.y;                    // d(lock coordinate) / d(c FL)
    vec3 lk = mat_fur_hair_noise(vec2(FL * (c + 0.0825 * lw.x + 0.04 * w.x), s * FLs), vec2(FL, FLs));
    vec2 gl = lws * gc + (0.04 * Fw) * w.yz;          // d(lock coordinate) / d uv, over FL
    vec2 glk = lk.y * FL * gl + lk.z * FLs * gs;      // d lk / d uv
    // (Faded from six pixels a lock: the partings and the rolls are sharper than one noise cell.)
    float kL = MatFadeUv(m, 1.5 * FL * max(length(gl), 1.0)) * hairy * (curl > 0.6 ? 0.4 : 1.0);
    // Strands about 0.1 world units apart and eight times as long, irregular (stretched gradient noise), two octaves
    // blended so the size never jumps.
    float F1, fb1;
    MatOctave(m, 0.1 * m.scale, F1, fb1);
    float F1s = max(F1 * exp2(-floor(mix(3.0, 1.0, curl) + 0.5)), 1.0);
    vec3 s0 = mat_fur_hair_noise(vec2(c * F1, s * F1s), vec2(F1, F1s)) * vec3(1.0, F1, F1s);
    vec3 s1 = mat_fur_hair_noise(vec2(c * F1 * 2.0 + 0.5, s * F1s * 2.0 + 0.3), vec2(F1, F1s) * 2.0)
            * vec3(1.0, 2.0 * F1, 2.0 * F1s);
    vec3 st = mix(s0, s1, fb1);
    float kS = MatFadeUv(m, F1 * (1.0 + fb1) * stretch) * hairy;

    // The normal from the heights in world units (locks a soft roll 0.07 high, strands 0.02): their slopes per
    // texture unit along c and s, carried to u, v.
    vec2 dh = (0.07 * kL) * glk + (0.02 * kS) * (st.y * gc + st.z * gs);
    o.dn = MatBumpUv(m, dh * m.scale);

    // Cavity: partings between locks and the grooves between strands.
    o.ao = (1.0 - 0.06 * kL * smoothstep(-0.05, 0.4, -lk.x)) * (1.0 - 0.08 * kS * smoothstep(0.0, 0.35, -st.x));
    // Colour: a strand a little lighter or darker, a lock a little; the mean stays.
    o.albedo = MatVary(m.albedo, m.p.y, 0.08 * kS * st.x + 0.03 * kL * lk.x);

    // The highlight along the strands: the strand's tangent in eye space (perpendicular to grad c on the surface).
    vec3 gcE = gc.x * m.gu + gc.y * m.gv;
    vec3 T = cross(m.n, gcE);
    T = dot(T, T) > 1e-20 ? normalize(T) : m.tv;
    vec3 h = normalize(m.l + m.v);
    float sh = 0.08 * lk.x * kL;                      // the bands wander with the locks
    vec3 t1 = normalize(T + m.n * (0.12 + sh)), t2 = normalize(T - m.n * (0.22 - sh));
    float d1 = dot(t1, h), d2 = dot(t2, h);
    float e1 = mix(12.0, 36.0, kS);
    float b1 = pow(max(1.0 - d1 * d1, 0.0), e1) * sqrt(e1 / 36.0), b2 = pow(max(1.0 - d2 * d2, 0.0), 8.0);
    float glint = mix(1.0, clamp(1.0 + 2.2 * st.x, 0.2, 2.0), kS) * (1.0 + 0.5 * lk.x * kL);
    float band = (1.2 * b1 + 0.45 * b2) * glint;
    // Off the bands the round highlight goes; the bands carry it, broad in the Blinn lobe (gloss down). Dark hair:
    // the same highlight is a bigger share of what it reflects, so less gain keeps its mean.
    // (Without the strands' cavities, far away, a little less, so the mean stays at every distance.)
    float gain = mix(0.8, 2.0, smoothstep(0.08, 0.5, MatLum(m.albedo))) * mix(0.85, 1.0, kS);
    o.spec = mix(1.0, 0.3 + gain * band, hairy);
    // What is not hair keeps the material's own highlight.
    o.gloss = mix(1.0, 0.45, hairy);
    return o;
}
