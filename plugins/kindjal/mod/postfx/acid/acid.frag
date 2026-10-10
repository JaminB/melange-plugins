#version 120
// Kindjal acid: corrosion that eats into a worm's skin. Uniform contract (all set by Kindjal's Lua with
// wum.postfx.setTransient, so the parameters are hidden):
//   p_worm0..p_worm15    vec3  world position of the middle of each worm's body; (0,0,0) = slot unused
//   p_level0..p_level3   vec4  acid level 0..1 of slots 4k+0..3 (x, y, z, w); 0 = clean. Continuous (the client eases it and
//                              sends it in steps of 1/256), and the whole effect is scaled by it, see Worm()
//   p_spread0..p_spread3 vec4  how far the eaten pattern has grown, 0..1, of slots 4k+0..3 (spots at 0, a coat at 1)
//   p_seed               float match seed, so no two matches or worms look alike
//   p_strength           float 0..1 overall opacity; 0 or all levels 0 leaves the scene unchanged
//   p_compat             float 0..1 how much of Sunstone's lighting and grade is on the scene (0 = the game's own look, 1 = Sunstone
//                        running); it only widens SkinTone, see there
// Built-ins used: mg_scene, mg_depth, mg_invProj, mg_view, mg_nearFar, mg_resolution, mg_time.
//
// The body is found the way Bloodsand's skin effect finds it (same capsule shell, same skin classifier, same depth-buffer
// normal), because this runs after it (order 54, behind skin 51, guts 52 and gibs 53). SkinTone only passes warm peach to
// yellow skin: blood paints a pixel red (green over red far below 0.3), so Bloodsand's blood, wounds and gibs are left as
// they are and the acid only eats what is still skin. Only a short test runs for every slot, to pick the one worm a pixel
// belongs to, and Worm() runs once: a shader that expands the long routine once per slot can link and draw nothing.
//
// Cost (an estimate from counting operations, not a measurement: read gpuMs in the Mirage/Post-FX panel). The client switches the
// pass on only while a coated worm is near the screen. Then a pixel away from every coated worm costs two fetches, one
// unprojection and one sphere test per coated slot (an unused slot is one uniform branch), which is bandwidth-bound: about
// 0.1 ms at 1080p, and about 0.3 to 0.4 ms at Sunstone's Ultra 2x2 supersampling (over the 0.3 ms aimed for there, unmeasured). Only a pixel on a coated worm's capsule shell goes
// on, SkinTone runs for it first, and the normal (four more depth fetches) and the long Worm() code run only for the few that are
// skin, so the long code adds well under 0.05 ms for four coated worms.
uniform sampler2D mg_scene;
uniform sampler2D mg_depth;
uniform mat4 mg_invProj;
uniform mat4 mg_view;
uniform vec2 mg_nearFar;
uniform vec4 mg_resolution;
uniform float mg_time;
uniform vec3 p_worm0, p_worm1, p_worm2, p_worm3, p_worm4, p_worm5, p_worm6, p_worm7, p_worm8, p_worm9, p_worm10, p_worm11, p_worm12, p_worm13, p_worm14, p_worm15;
uniform vec4 p_level0, p_level1, p_level2, p_level3;
uniform vec4 p_spread0, p_spread1, p_spread2, p_spread3;
uniform float p_seed;
uniform float p_strength;
uniform float p_compat;
varying vec2 mg_uv;

float Hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float Hash3(vec3 p) {
    return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453);
}

// Trilinear value noise, 0..1.
float Noise3(vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = mix(Hash3(i), Hash3(i + vec3(1.0, 0.0, 0.0)), f.x);
    float b = mix(Hash3(i + vec3(0.0, 1.0, 0.0)), Hash3(i + vec3(1.0, 1.0, 0.0)), f.x);
    float c = mix(Hash3(i + vec3(0.0, 0.0, 1.0)), Hash3(i + vec3(1.0, 0.0, 1.0)), f.x);
    float d = mix(Hash3(i + vec3(0.0, 1.0, 1.0)), Hash3(i + vec3(1.0, 1.0, 1.0)), f.x);
    return mix(mix(a, b, f.y), mix(c, d, f.y), f.z);
}

// 1 below a and 0 above b (the reverse of smoothstep, which is undefined when its edges are the wrong way round).
float Edge(float a, float b, float x) {
    return 1.0 - smoothstep(a, b, x);
}

// The most blue over red (v) that skin can have, given its green over red (u) and its brightness (mx); calibrated on the
// game's own frames in Bloodsand (desert shade and sun, yellow light, the cold light of the snow levels).
float SkinLimit(float u, float mx) {
    return 0.585 - 0.5 * clamp(u - 0.75, 0.0, 0.25) + 0.085 * smoothstep(0.80, 0.88, mx) + 0.04 * smoothstep(0.93, 0.985, mx);
}

// How much a scene colour is a worm's skin, 0..1: a warm peach to yellow whose channel ratios light only scales. Hats,
// helmets, glasses, eye whites and pupils fall outside the window, and so does blood: green over red below 0.3 is cut by the
// first factor, and a hue below about 6 degrees (red, raw dermis, the pink of a wound) by the lower hue limit, so a pixel
// Bloodsand has painted is not skin here. Bloodsand's green blood has green well above red and is cut by the upper limit on u.
// A poisoned worm's yellow skin passes (green below about 1.2 times red). The limits are soft, so the edge is anti-aliased.
//
// compat (0..1) is Sunstone. Its model lighting (shaders/FixedFunction.*Lit*.glsl) tints the sun side warm (1.06, 1, 0.9) and
// the ambient side cold (0.85, 0.93, 1.14 against the sky and ground tints), so skin in shade gains up to about half again
// as much blue over red as the game gives it (v 0.34 to 0.43 becomes 0.5 to 0.6), loses a little hue in the cold light
// (about 15 degrees where the game's is 21 to 28), and gets darker in caves and under overhangs. Every limit below is a ratio
// or relative to the pixel's own brightness mx, so the grade's exposure does not matter, and compat moves these:
//   blue limit   +0.11 in shade, fading to nothing by mx 0.8 (the sun side is already inside the window)
//   hue limit    30 degrees -> 33 (tangent 0.577 -> 0.657); sunlit skin in the warm tint reaches 24 to 29 degrees
//   saturation   edges 0.72..0.76 -> 0.75..0.79 (the warm tint raises skin to about 0.62; an orange moustache starts at 0.76)
//   dark floor   mx 0.03..0.09 -> 0.01..0.04, so a cave's skin is still classified
// With compat 0 these four are Bloodsand's own limits exactly. The lower hue limit (tangent 0.10..0.22, 6 to 12 degrees) is new
// and applies at both settings: by the tint arithmetic above skin stays at 15 degrees and up even in the coldest shade, while
// blood and raw dermis (the pink of a wound) sit at 0 to 4 degrees, so it cuts them without touching skin. The tonemap that
// Sunstone applies afterwards (order 300) keeps hue and saturation, so nothing here needs to undo it; see the README.
float SkinTone(vec3 c, float compat) {
    float mx = max(c.r, max(c.g, c.b));
    float mn = min(c.r, min(c.g, c.b));
    float rr = max(c.r, 1e-3);
    float u = c.g / rr;
    float v = c.b / rr;
    float vmax = SkinLimit(u, mx) + compat * 0.11 * (1.0 - smoothstep(0.35, 0.8, mx));
    float hole = smoothstep(0.415, 0.44, v) * (1.0 - smoothstep(0.505, 0.525, v)) * smoothstep(0.66, 0.70, u) * (1.0 - smoothstep(0.79, 0.84, u))
               * (1.0 - smoothstep(0.78, 0.86, mx));
    // The hue's tangent against a limit of 30 degrees that climbs toward 60 as sun clips the red (poison turns skin yellow).
    float tn = 1.7320508 * (c.g - c.b) / max(2.0 * c.r - c.g - c.b, 1e-3);
    float tl = mix(0.577, 1.75, smoothstep(0.74, 0.9, mx)) + 0.08 * compat;
    float hue = (1.0 - smoothstep(tl, tl + 0.075, tn)) * smoothstep(0.10, 0.22, tn);
    float sat = 1.0 - smoothstep(0.72 + 0.03 * compat, 0.76 + 0.03 * compat, (mx - mn) / max(mx, 1e-3));
    return smoothstep(0.30, 0.40, u) * (1.0 - smoothstep(1.12, 1.30, u))
         * (1.0 - smoothstep(vmax - 0.025, vmax + 0.025, v)) * (1.0 - hole) * smoothstep(0.16, 0.26, v)
         * smoothstep(0.03 - 0.02 * compat, 0.09 - 0.05 * compat, mx) * smoothstep(0.03, 0.11, (c.g - c.b) / max(mx, 1e-3)) * hue * sat;
}

// The view-space position of the pixel at uv, from the depth buffer.
vec3 ViewPos(vec2 uv) {
    vec4 v = mg_invProj * vec4(vec3(uv, texture2D(mg_depth, uv).r) * 2.0 - 1.0, 1.0);
    return v.xyz / v.w;
}

// The body ellipsoid's equation at a view-space point (below 1 is inside), for a body whose centre is Cv in view space.
float BodyE(vec3 Pv, vec3 Cv) {
    vec3 L = (Pv - Cv) * mat3(mg_view);
    return (L.x * L.x + L.z * L.z) / (9.5 * 9.5) + L.y * L.y / (16.0 * 16.0);
}

// The surface normal at the pixel (view space, facing the camera) from the depth of its four neighbours, taking in each
// direction the difference on the side where the depth changes less so a silhouette is never differenced across (screen
// derivatives work over 2x2 blocks and are garbage there). cover falls toward 0 at the outer silhouette, where a neighbour
// is far behind and not part of the body, for a pixel of anti-aliasing.
vec3 SurfaceNormal(vec3 P, vec3 Cv, out float cover) {
    vec2 t = mg_resolution.zw;
    vec3 Pr = ViewPos(mg_uv + vec2(t.x, 0.0));
    vec3 Pl = ViewPos(mg_uv - vec2(t.x, 0.0));
    vec3 Pu = ViewPos(mg_uv + vec2(0.0, t.y));
    vec3 Pd = ViewPos(mg_uv - vec2(0.0, t.y));
    float jump = 0.02 * -P.z + 0.3;
    vec4 dz = vec4(Pr.z, Pl.z, Pu.z, Pd.z) - P.z;
    vec4 outside = max(step(0.95, vec4(BodyE(Pr, Cv), BodyE(Pl, Cv), BodyE(Pu, Cv), BodyE(Pd, Cv))), step(8.0, -dz));
    cover = clamp(1.0 - 0.45 * dot(outside, step(jump, -dz)), 0.0, 1.0);
    vec3 dx = abs(dz.x) < abs(dz.y) ? Pr - P : P - Pl;
    vec3 dy = abs(dz.z) < abs(dz.w) ? Pu - P : P - Pd;
    vec3 n = cross(dx, dy);
    float nl = length(n);
    n = (nl < 1e-9 || min(abs(dz.x), abs(dz.y)) > jump || min(abs(dz.z), abs(dz.w)) > jump) ? -normalize(P) : n / nl;
    return dot(n, P) > 0.0 ? -n : n;
}

// Eats one worm's skin into col, which holds the scene's colour on the way in. P is the pixel's view-space position, n its
// surface normal, lv the acid level and sp the spread (0..1). mg_view is the world-to-view matrix, so d * mat3(mg_view)
// turns a view-space offset back into world axes (L, the pixel's offset from the body's middle, which moves with the worm).
void Worm(vec3 P, vec3 n, vec3 centre, float lv, float sp, float slotIdx, float skin, inout vec3 col) {
    vec3 d = P - (mg_view * vec4(centre, 1.0)).xyz;
    vec3 L = d * mat3(mg_view);
    // The body is an upright ellipsoid, and the outer 15% fades out.
    float e = (L.x * L.x + L.z * L.z) / (9.5 * 9.5) + L.y * L.y / (16.0 * 16.0);
    float mask = 1.0 - smoothstep(0.85, 1.0, e);
    if (mask <= 0.0) return;
    // Only the worm's own surface: a thin shell round the vertical axis (a capsule 5.6 units in radius), facing away from
    // the axis and upright along its straight part, so sunlit sand inside the ellipsoid does not take the acid.
    vec3 rv = vec3(L.x, L.y - clamp(L.y, -8.0, 8.0), L.z);
    float rl = length(rv);
    if (rl < 1e-4) return;
    vec3 nWorld = n * mat3(mg_view);
    float shell = smoothstep(2.4, 3.6, rl) * (1.0 - smoothstep(6.9, 8.1, rl));
    float upright = 1.0 - smoothstep(0.55, 0.85, abs(nWorld.y)) * (1.0 - smoothstep(0.0, 2.0, abs(rv.y)));
    mask *= shell * upright * smoothstep(0.1, 0.5, dot(nWorld, rv / rl));
    if (mask <= 0.0) return;
    // Only skin, and not blood: main() has already run the colour test (before the normal was worked out) and passes it in.
    mask *= skin;
    if (mask <= 0.0) return;
    // A worm stands clear of what is behind it: the depth falls away to one side of it by more than a couple of units.
    float ppx = 0.5 * mg_resolution.y / (abs(mg_invProj[1][1]) * max(-P.z, 1.0));
    float sxo = clamp(7.6 * ppx, 4.0, 160.0) * mg_resolution.z;
    float gapL = P.z - ViewPos(mg_uv - vec2(sxo, 0.0)).z;
    float gapR = P.z - ViewPos(mg_uv + vec2(sxo, 0.0)).z;
    mask *= max(smoothstep(1.2, 3.5, gapL), smoothstep(1.2, 3.5, gapR));
    if (mask <= 0.0) return;

    // The eaten pattern: two octaves of noise held in the worm's own offset L (so it travels with the worm, and the seed
    // and slot give each worm its own), thresholded against the spread so that a few spots at 0 join into a coat at 1.
    float seed = p_seed + slotIdx * 37.0;
    vec3 so = vec3(Hash(vec2(seed, 3.1)), Hash(vec2(seed, 7.7)), Hash(vec2(seed, 11.3))) * 60.0;
    float n1 = Noise3(L * 0.42 + so);
    float n2 = Noise3(L * 1.15 + so + 7.3);
    float f = 0.62 * n1 + 0.38 * n2;
    // The coat does not just dim as it fades: its pattern draws back toward the first few spots as the level falls (spe is the
    // spread the pattern is drawn with), and the level scales everything on top of that. So a fading coat shrinks and thins
    // together and ends as nothing, with no step on the way (every term is a smooth function of lv and sp).
    float spe = sp * (0.5 + 0.5 * smoothstep(0.0, 0.8, lv));
    float thr = mix(0.78, 0.2, spe);
    float inner = clamp((f - thr) / max(1.0 - thr, 0.05), 0.0, 1.0);
    float eaten = max(smoothstep(thr, thr + 0.05, f), smoothstep(0.7, 1.0, spe));
    float cov = eaten * lv * mask;
    if (cov <= 0.0) return;

    // Colour: a sickly green-yellow that keeps the skin's own shading (lum), darkening toward the middle of each eaten spot.
    float lum = dot(col, vec3(0.299, 0.587, 0.114));
    vec3 acid = mix(vec3(0.55, 0.75, 0.15), vec3(0.78, 0.82, 0.2), n1 * 0.6);
    acid = mix(acid, vec3(0.10, 0.14, 0.02), 0.85 * smoothstep(0.1, 0.8, inner));
    acid *= clamp(0.35 + 0.9 * lum, 0.3, 1.15);

    // Bubbling: blisters where a third noise is high, pulsing slowly, each with a sparse bright rim. The blisters drift through
    // the noise on a slow circle and breathe on a 3 s pulse. Both come from one phase that wraps every 36 s (the circle goes
    // round twice and the pulse twelve times in that), so the animation is seamless through the wrap and never loses precision
    // however long the game has been running (mg_time itself grows without limit).
    float ph = fract(mg_time * (1.0 / 36.0)) * 6.2831853;
    vec3 drift = vec3(0.9 * cos(2.0 * ph), 0.6 * sin(2.0 * ph + 1.3), 0.9 * sin(2.0 * ph));
    float n3 = Noise3(L * 2.6 + so + drift);
    float pulse = sin(12.0 * ph + n3 * 6.0);
    float rim = Edge(0.0, 0.035, abs(n3 - 0.68 - 0.012 * pulse)) * smoothstep(0.3, 0.9, pulse + 0.4);
    acid *= 1.0 + 0.12 * pulse * smoothstep(0.62, 0.7, n3);
    acid = mix(acid, vec3(0.9, 1.0, 0.45), 0.7 * rim);

    // Gloss: a fake specular on the body's smooth normal (the depth buffer's is flat across each facet and jumps at its
    // edges, so it alone gives angular shards) from the key light, plus a faint rim light where the body turns away.
    vec3 nE = mat3(mg_view) * normalize(vec3(L.x / (9.5 * 9.5), L.y / (16.0 * 16.0), L.z / (9.5 * 9.5)) + vec3(0.0, 1e-6, 0.0));
    vec3 ns = normalize(mix(n, nE, 0.85));
    vec3 Kv = normalize(mat3(mg_view) * vec3(0.35, 0.85, 0.25));
    vec3 Vv = normalize(-P);
    float spec = pow(max(dot(ns, normalize(Kv + Vv)), 0.0), 36.0);
    float fres = pow(1.0 - max(dot(ns, Vv), 0.0), 3.0);
    float wet = 0.35 + 0.65 * smoothstep(0.0, 0.5, inner) + 0.4 * rim;
    acid += vec3(1.0, 1.0, 0.8) * spec * 0.8 * wet * (0.4 + lum) + vec3(0.5, 0.7, 0.1) * fres * 0.15;

    col = mix(col, acid, clamp(cov * (0.55 + 0.45 * smoothstep(0.0, 0.5, inner + spe)), 0.0, 1.0));
}

// Chooses the worm a pixel belongs to (see the top). best is the smallest value so far of the body ellipsoid's equation
// (below 1 is inside); the other outputs are that slot's values. A slot with no level or no position is skipped.
void Pick(vec3 P, vec3 centre, float lv, float sp, float slotIdx, inout float best, inout vec3 wc, inout float wlv, inout float wsp, inout float wslot) {
    if (lv <= 0.0 || dot(centre, centre) < 1e-6) return;
    vec3 d = P - (mg_view * vec4(centre, 1.0)).xyz;
    // Early outs, in order of cost: farther than the ellipsoid's longest semi-axis (16, with a margin) can never be on this
    // worm; and a pixel off the capsule shell (2.4 to 8.1 units from the vertical axis, the same range Worm() fades to
    // nothing outside) can take no acid, so it must not claim the pixel from a worm whose surface it is on.
    if (dot(d, d) > 17.0 * 17.0) return;
    vec3 L = d * mat3(mg_view);
    vec3 rv = vec3(L.x, L.y - clamp(L.y, -8.0, 8.0), L.z);
    float rl2 = dot(rv, rv);
    if (rl2 < 2.4 * 2.4 || rl2 > 8.1 * 8.1) return;
    float e = (L.x * L.x + L.z * L.z) / (9.5 * 9.5) + L.y * L.y / (16.0 * 16.0);
    if (e < best) {
        best = e;
        wc = centre;
        wlv = lv;
        wsp = sp;
        wslot = slotIdx;
    }
}

void main() {
    vec4 scene = texture2D(mg_scene, mg_uv);
    float depth = texture2D(mg_depth, mg_uv).r;
    vec4 vp = mg_invProj * vec4(vec3(mg_uv, depth) * 2.0 - 1.0, 1.0);
    vec3 P = vp.xyz / vp.w;
    if (p_strength <= 0.0 || depth >= 1.0 || length(P) > 0.5 * mg_nearFar.y) {
        gl_FragColor = scene;
        return;
    }
    float best = 1.0, wlv = 0.0, wsp = 0.0, wslot = 0.0;
    vec3 wc = vec3(0.0);
    Pick(P, p_worm0, p_level0.x, p_spread0.x, 0.0, best, wc, wlv, wsp, wslot);
    Pick(P, p_worm1, p_level0.y, p_spread0.y, 1.0, best, wc, wlv, wsp, wslot);
    Pick(P, p_worm2, p_level0.z, p_spread0.z, 2.0, best, wc, wlv, wsp, wslot);
    Pick(P, p_worm3, p_level0.w, p_spread0.w, 3.0, best, wc, wlv, wsp, wslot);
    Pick(P, p_worm4, p_level1.x, p_spread1.x, 4.0, best, wc, wlv, wsp, wslot);
    Pick(P, p_worm5, p_level1.y, p_spread1.y, 5.0, best, wc, wlv, wsp, wslot);
    Pick(P, p_worm6, p_level1.z, p_spread1.z, 6.0, best, wc, wlv, wsp, wslot);
    Pick(P, p_worm7, p_level1.w, p_spread1.w, 7.0, best, wc, wlv, wsp, wslot);
    Pick(P, p_worm8, p_level2.x, p_spread2.x, 8.0, best, wc, wlv, wsp, wslot);
    Pick(P, p_worm9, p_level2.y, p_spread2.y, 9.0, best, wc, wlv, wsp, wslot);
    Pick(P, p_worm10, p_level2.z, p_spread2.z, 10.0, best, wc, wlv, wsp, wslot);
    Pick(P, p_worm11, p_level2.w, p_spread2.w, 11.0, best, wc, wlv, wsp, wslot);
    Pick(P, p_worm12, p_level3.x, p_spread3.x, 12.0, best, wc, wlv, wsp, wslot);
    Pick(P, p_worm13, p_level3.y, p_spread3.y, 13.0, best, wc, wlv, wsp, wslot);
    Pick(P, p_worm14, p_level3.z, p_spread3.z, 14.0, best, wc, wlv, wsp, wslot);
    Pick(P, p_worm15, p_level3.w, p_spread3.w, 15.0, best, wc, wlv, wsp, wslot);
    if (best >= 1.0) {
        gl_FragColor = scene;
        return;
    }
    // The cheap colour test before the dear normal: most pixels on a worm's shell are not skin (hat, eyes, blood, Bloodsand's
    // gore) and leave here.
    float skin = SkinTone(scene.rgb, clamp(p_compat, 0.0, 1.0));
    if (skin < 0.01) {
        gl_FragColor = scene;
        return;
    }
    float cover;
    vec3 n = SurfaceNormal(P, (mg_view * vec4(wc, 1.0)).xyz, cover);
    vec3 col = scene.rgb;
    Worm(P, n, wc, clamp(wlv, 0.0, 1.0), clamp(wsp, 0.0, 1.0), wslot, skin, col);
    gl_FragColor = vec4(mix(scene.rgb, col, p_strength * cover), scene.a);
}
