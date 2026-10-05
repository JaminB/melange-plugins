#version 120
// Blood and wounds on the worms' skin. Each of 16 slots is the world position of the middle of a worm's body (wormN) and
// its blood amount, wound level and heading (wormNb). The blood and the wounds are painted in screen space from the depth
// buffer wherever a pixel lies on the surface of the body's ellipsoid, in a pattern held in the worm's own frame so it
// moves and turns with it. Wounds are up to five gashes at fixed places on the body (from the match seed and the slot),
// which open one after another as the wound level rises. Sky is left alone and with every amount and wound level at 0 the
// output is the scene unchanged.
uniform sampler2D mg_scene;
uniform sampler2D mg_depth;
uniform mat4 mg_invProj;
uniform mat4 mg_view;
uniform vec2 mg_nearFar;
uniform vec3 p_worm0, p_worm1, p_worm2, p_worm3, p_worm4, p_worm5, p_worm6, p_worm7, p_worm8, p_worm9, p_worm10, p_worm11, p_worm12, p_worm13, p_worm14, p_worm15;
uniform vec3 p_worm0b, p_worm1b, p_worm2b, p_worm3b, p_worm4b, p_worm5b, p_worm6b, p_worm7b, p_worm8b, p_worm9b, p_worm10b, p_worm11b, p_worm12b, p_worm13b, p_worm14b, p_worm15b;
uniform vec3 p_blood;
uniform float p_strength;
uniform float p_seed;
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

// One candidate gash, number k (0..4), of the worm with this seed. dir is the unit direction from the worm's centre in
// ellipsoid-normalised space and qu the position in the worm's rotated frame (no seed offset). The gash is open once the
// wound level passes k / 5 and grows to full size over the next fifth. Adds the blood running down from it to cov and
// core, and its interior, dark middle and torn rim to wnd, deep and rim. mask is the worm-surface mask.
void Site(vec3 dir, vec3 qu, float seed, float wound, float k, float mask,
          inout float cov, inout float core, inout float wnd, inout float deep, inout float rim) {
    float o = clamp((wound - k / 5.0) * 5.0, 0.0, 1.0);
    if (o <= 0.0) return;
    float sz = mix(0.5, 1.0, o);

    float az = 6.2831853 * Hash(vec2(seed, k * 3.7 + 1.0));
    float elev = mix(-0.35, 0.75, Hash(vec2(seed, k * 5.1 + 2.0)));
    vec3 s = vec3(cos(az) * cos(elev), sin(elev), sin(az) * cos(elev));
    float along = dot(dir, s);
    if (along <= 0.2) return;

    // Blood running down from the gash: below it, close to it sideways, fading with distance and broken up by noise.
    float below = s.y - dir.y;
    if (below > 0.0) {
        float side = length(dir.xz - s.xz);
        float nz = Noise3(vec3(qu.x * 0.8, qu.y * 0.25, qu.z * 0.8) + k * 3.1);
        float width = (1.0 - smoothstep(0.03, 0.11, side + (nz - 0.5) * 0.08)) * smoothstep(0.0, 0.08, below);
        float runLen = 1.0 - smoothstep(0.1 * sz, 0.85 * sz, below);
        float run = width * runLen * smoothstep(0.22, 0.5, nz + 0.25 * runLen) * o * mask;
        cov = max(cov, run);
        core = max(core, run * 0.6);
    }

    if (along <= 0.3) return;

    // The gash is a slash in the tangent plane at the site, slanted by a per-site angle.
    vec3 t1 = normalize(cross(s, vec3(0.0, 1.0, 0.0)));
    vec3 t2 = cross(s, t1);
    float ang = 3.1415927 * Hash(vec2(seed, k * 7.3 + 3.0));
    vec3 a1 = t1 * cos(ang) + t2 * sin(ang);
    vec3 a2 = t2 * cos(ang) - t1 * sin(ang);
    vec3 v = dir - s;
    float x = dot(v, a1) / (0.42 * sz);
    float y = dot(v, a2) / (0.15 * sz);
    y += (Noise3(qu * 0.9 + k) - 0.5) * 0.5;
    float r2 = x * x + y * y;

    float inside = 1.0 - smoothstep(0.75, 1.0, r2);
    float dp = 1.0 - smoothstep(0.0, 0.55, r2);
    float rm = smoothstep(0.55, 0.85, r2) * (1.0 - smoothstep(1.0, 1.6, r2));
    wnd = max(wnd, inside * mask);
    deep = max(deep, dp * mask);
    rim = max(rim, rm * mask);
}

// Adds one worm's blood coverage and core darkness to cov and core, and its wounds to wnd, deep and rim. P is the pixel's
// view-space position and n its surface normal, facing the camera. mg_view is the world-to-view matrix in column-major
// layout with translation, so d * mat3(mg_view), which is transpose(R) * d, turns a view-space offset back into world
// axes. slotIdx is the slot number as a float, which gives the worm its own seed.
void Worm(vec3 P, vec3 n, vec3 centre, vec3 b, float slotIdx,
          inout float cov, inout float core, inout float wnd, inout float deep, inout float rim) {
    float amount = b.x;
    float wound = b.y;
    if (amount <= 0.0 && wound <= 0.0) return;
    vec3 d = P - (mg_view * vec4(centre, 1.0)).xyz;
    if (dot(d, d) > 17.0 * 17.0) return;
    vec3 L = d * mat3(mg_view);

    // The body is roughly an upright ellipsoid, and the outer 15% fades out.
    float e = (L.x * L.x + L.z * L.z) / (9.5 * 9.5) + L.y * L.y / (16.0 * 16.0);
    float mask = 1.0 - smoothstep(0.85, 1.0, e);
    if (mask <= 0.0) return;

    // Only the worm's own surface takes blood: it faces away from the worm's centre, while the ground under the worm
    // and a wall beside it face toward the centre and fail this.
    float dl = length(d);
    if (dl < 1e-4) return;
    float facing = dot(n, d / dl);
    mask *= smoothstep(0.2, 0.45, facing);
    if (mask <= 0.0) return;

    // The pattern is rotated about +Y by -heading so it turns with the worm, and offset by the seed so no two worms match.
    float seed = p_seed + slotIdx * 37.0;
    float ch = cos(b.z), sh = sin(b.z);
    vec3 qu = vec3(L.x * ch - L.z * sh, L.y, L.x * sh + L.z * ch);

    if (wound > 0.0) {
        vec3 en = qu / vec3(9.5, 16.0, 9.5);
        float el = length(en);
        if (el > 1e-4) {
            vec3 dir = en / el;
            Site(dir, qu, seed, wound, 0.0, mask, cov, core, wnd, deep, rim);
            Site(dir, qu, seed, wound, 1.0, mask, cov, core, wnd, deep, rim);
            Site(dir, qu, seed, wound, 2.0, mask, cov, core, wnd, deep, rim);
            Site(dir, qu, seed, wound, 3.0, mask, cov, core, wnd, deep, rim);
            Site(dir, qu, seed, wound, 4.0, mask, cov, core, wnd, deep, rim);
        }
    }

    if (amount <= 0.0) return;
    vec3 q = qu + vec3(Hash(vec2(seed, 3.1)), Hash(vec2(seed, 7.7)), Hash(vec2(seed, 11.3))) * 60.0;

    // Splotches a few units across, and runs: the same noise with Y squashed so its features stretch downward.
    float splotch = 0.65 * Noise3(q / 3.5) + 0.35 * Noise3(q / 1.8 + 7.0);
    float runs = 0.65 * Noise3(vec3(q.x, q.y * 0.3, q.z) / 2.6) + 0.35 * Noise3(vec3(q.x, q.y * 0.3, q.z) / 1.4 + 13.0);
    float field = max(splotch, runs - 0.04);
    // Wounds bleed downward, so there is a little more on the upper half and less toward the base.
    field += 0.14 * clamp(L.y / 16.0, -1.0, 1.0);

    float thr = 0.82 - 0.26 * amount;
    float c = smoothstep(thr, thr + 0.08, field) * mask;
    cov = max(cov, c);
    core = max(core, smoothstep(thr + 0.15, thr + 0.3, field) * mask);
}

void main() {
    vec4 scene = texture2D(mg_scene, mg_uv);
    float depth = texture2D(mg_depth, mg_uv).r;
    vec4 vp = mg_invProj * vec4(vec3(mg_uv, depth) * 2.0 - 1.0, 1.0);
    vec3 P = vp.xyz / vp.w;
    // Derivatives are taken before any early return so that every pixel of a block takes part in them.
    vec3 dPx = dFdx(P);
    vec3 dPy = dFdy(P);
    if (p_strength <= 0.0 || depth >= 1.0 || length(P) > 0.5 * mg_nearFar.y) {
        gl_FragColor = scene;
        return;
    }

    // Derivatives across a silhouette or a depth jump are garbage, so a pixel whose neighbours are implausibly far
    // away for a surface at this distance (6% of the distance plus a little) is left alone.
    if (length(dPx) + length(dPy) > 0.06 * length(P) + 0.5) {
        gl_FragColor = scene;
        return;
    }
    vec3 n = cross(dPx, dPy);
    float nl = length(n);
    if (nl < 1e-9) {
        gl_FragColor = scene;
        return;
    }
    n /= nl;
    // Face the camera, which sits at the view-space origin.
    if (dot(n, P) > 0.0) n = -n;

    float cov = 0.0, core = 0.0, wnd = 0.0, deep = 0.0, rim = 0.0;
    Worm(P, n, p_worm0, p_worm0b, 0.0, cov, core, wnd, deep, rim);
    Worm(P, n, p_worm1, p_worm1b, 1.0, cov, core, wnd, deep, rim);
    Worm(P, n, p_worm2, p_worm2b, 2.0, cov, core, wnd, deep, rim);
    Worm(P, n, p_worm3, p_worm3b, 3.0, cov, core, wnd, deep, rim);
    Worm(P, n, p_worm4, p_worm4b, 4.0, cov, core, wnd, deep, rim);
    Worm(P, n, p_worm5, p_worm5b, 5.0, cov, core, wnd, deep, rim);
    Worm(P, n, p_worm6, p_worm6b, 6.0, cov, core, wnd, deep, rim);
    Worm(P, n, p_worm7, p_worm7b, 7.0, cov, core, wnd, deep, rim);
    Worm(P, n, p_worm8, p_worm8b, 8.0, cov, core, wnd, deep, rim);
    Worm(P, n, p_worm9, p_worm9b, 9.0, cov, core, wnd, deep, rim);
    Worm(P, n, p_worm10, p_worm10b, 10.0, cov, core, wnd, deep, rim);
    Worm(P, n, p_worm11, p_worm11b, 11.0, cov, core, wnd, deep, rim);
    Worm(P, n, p_worm12, p_worm12b, 12.0, cov, core, wnd, deep, rim);
    Worm(P, n, p_worm13, p_worm13b, 13.0, cov, core, wnd, deep, rim);
    Worm(P, n, p_worm14, p_worm14b, 14.0, cov, core, wnd, deep, rim);
    Worm(P, n, p_worm15, p_worm15b, 15.0, cov, core, wnd, deep, rim);
    cov *= p_strength;
    wnd *= p_strength;
    rim *= p_strength;
    if (cov <= 0.0 && wnd <= 0.0 && rim <= 0.0) {
        gl_FragColor = scene;
        return;
    }

    // Multiplying keeps the worm's shading and face: the blood stains the skin instead of covering it, and the core
    // goes darker and thicker than the rest.
    vec3 tint = p_blood / max(max(p_blood.r, p_blood.g), max(p_blood.b, 1e-3));
    vec3 soaked = scene.rgb * tint * mix(0.75, 0.4, core) + p_blood * 0.08 * (0.5 + core);
    vec3 col = mix(scene.rgb, soaked, cov);

    // Wounds. The scene's luminance is kept in both layers so a lit wound is not flat.
    float lum = dot(scene.rgb, vec3(0.299, 0.587, 0.114));
    // The torn rim: raw flesh, the blood tint brightened and a little pink.
    vec3 raw = min(tint * 0.85 + vec3(0.2, 0.1, 0.12), vec3(1.0));
    col = mix(col, raw * (0.35 + 0.9 * lum), 0.75 * rim);
    // The wound itself: deep red at its edge, nearly black-red in the middle.
    vec3 clot = mix(p_blood * 0.9, p_blood * 0.15, deep);
    col = mix(col, clot * (0.6 + 0.8 * lum), 0.95 * wnd);
    gl_FragColor = vec4(col, scene.a);
}
