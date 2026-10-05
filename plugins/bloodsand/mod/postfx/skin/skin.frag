#version 120
// Blood, wounds, black eyes and spilled guts on the worms' skin. Each of 16 slots is the world position of the middle of
// a worm's body (wormN), its blood amount, wound level and heading (wormNb), and its eye level, gut level and gut azimuth
// (wormNc). Everything is painted in screen space from the depth buffer wherever a pixel lies on the surface of the
// body's ellipsoid, in a pattern held in the worm's own frame so it moves and turns with it. Wounds are up to five gashes
// at fixed places on the body (from the match seed and the slot), which open one after another as the wound level rises.
// The eye level darkens the skin around the two eyes into purple-black bruises, one after the other, and leaves the eye
// whites alone. The gut level tears a wide opening in the belly (at the azimuth from the facing direction) and lets
// coiled intestines spill out of it. The bruise goes on the skin first, then the blood, then the wounds and last the
// guts. Sky is left alone and with every amount and level at 0 the output is the scene unchanged.
uniform sampler2D mg_scene;
uniform sampler2D mg_depth;
uniform mat4 mg_invProj;
uniform mat4 mg_view;
uniform vec2 mg_nearFar;
uniform vec3 p_worm0, p_worm1, p_worm2, p_worm3, p_worm4, p_worm5, p_worm6, p_worm7, p_worm8, p_worm9, p_worm10, p_worm11, p_worm12, p_worm13, p_worm14, p_worm15;
uniform vec3 p_worm0b, p_worm1b, p_worm2b, p_worm3b, p_worm4b, p_worm5b, p_worm6b, p_worm7b, p_worm8b, p_worm9b, p_worm10b, p_worm11b, p_worm12b, p_worm13b, p_worm14b, p_worm15b;
uniform vec3 p_worm0c, p_worm1c, p_worm2c, p_worm3c, p_worm4c, p_worm5c, p_worm6c, p_worm7c, p_worm8c, p_worm9c, p_worm10c, p_worm11c, p_worm12c, p_worm13c, p_worm14c, p_worm15c;
uniform vec3 p_blood;
uniform float p_strength;
uniform float p_seed;
varying vec2 mg_uv;

// Where the eyes and the gut sit on the body, measured in game against the worm model. The eyes are placed on the face as
// seen from straight ahead, in world units from the middle of the body: EYE_X sideways and EYE_Y up, and EYE_RX and
// EYE_RY are the bruise's half-sizes. The bruise is larger than the eye and sits low on it: most hats cover the top of
// the eyes, a worm's head bobs and slumps by a few units as it moves, and the cheek under the eye is what shows. The gut opening is GUT_Y above the middle of the
// body (so below it) on a body GUT_R in radius there, and GUT_HW and GUT_HH are its half-width and half-height when fully
// open. Bloodsand's Lua hangs the loop of intestine from the same height and radius.
const float EYE_X = 2.3;
const float EYE_Y = 2.0;
const float EYE_RX = 3.6;
const float EYE_RY = 5.2;
const float GUT_Y = -6.0;
const float GUT_R = 5.5;
const float GUT_HW = 2.8;
const float GUT_HH = 1.3;

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

// One eye's bruise. side is +1 or -1 (which eye) and strength 0..1 how far it has darkened. qu is the position in the
// worm's frame, where the face looks along +Z, so the bruise is an oval laid on the front of the head as seen from
// straight ahead, with its edge broken up by noise. Adds the bruise to bruise and its darkest part to socket: a ring
// around the eye that is heavier underneath it, as a black eye is. mask is the worm-surface mask.
void Eye(vec3 qu, float side, float strength, float mask, inout float bruise, inout float socket) {
    if (strength <= 0.0 || qu.z <= 0.0) return;
    float x = (qu.x - side * EYE_X) / EYE_RX;
    float y = (qu.y - EYE_Y) / EYE_RY;
    float r2 = x * x + y * y + (Noise3(qu * 0.6 + side * 5.0) - 0.5) * 0.35;
    float r = sqrt(max(r2, 0.0));
    float front = smoothstep(0.0, 2.5, qu.z) * strength * mask;
    float ring = smoothstep(0.3, 0.6, r) * (1.0 - smoothstep(0.72, 1.0, r));
    bruise = max(bruise, (1.0 - smoothstep(0.65, 1.0, r)) * front);
    socket = max(socket, ring * mix(1.0, 0.6, smoothstep(-0.4, 0.3, y)) * front);
}

// The worm's intestines, spilling from a torn opening in the belly. qu is the position in the worm's frame, G the gut
// level (above 0) and az the azimuth of the opening from the facing direction. The opening is laid on the body as on an
// upright cylinder: x is the distance round the body from the opening's middle and y the height above it, both in world
// units. Adds the blood running down from it to cov and core, the opening's interior, dark middle and torn rim to wnd,
// deep and rim, and the coiled intestines inside it and bulging out below it to gutCov (coverage) and gutShade (0 in a
// crease between tubes, 1 on a lit crest). mask is the worm-surface mask.
void Gut(vec3 qu, float seed, float G, float az, float mask,
         inout float cov, inout float core, inout float wnd, inout float deep, inout float rim,
         inout float gutCov, inout float gutShade) {
    float ang = atan(qu.x, qu.z) - az;
    ang = mod(ang + 3.1415927, 6.2831853) - 3.1415927;
    if (abs(ang) > 1.5) return;
    float x = ang * GUT_R;
    float y = qu.y - GUT_Y;
    float sz = mix(0.55, 1.0, G);
    float hw = GUT_HW * sz;
    float hh = GUT_HH * sz;

    // Blood running down from the opening, as under a gash: below it, close to it sideways, fading with distance and
    // broken up by noise.
    if (y < 0.0) {
        float nz = Noise3(vec3(qu.x * 0.8, qu.y * 0.25, qu.z * 0.8) + 17.0);
        float width = (1.0 - smoothstep(0.3 * hw, 0.8 * hw, abs(x) + (nz - 0.5) * 0.8)) * smoothstep(0.0, 0.5, -y);
        float runLen = 1.0 - smoothstep(1.0 * sz, 6.0 * sz, -y);
        float run = width * runLen * smoothstep(0.22, 0.5, nz + 0.25 * runLen) * mask;
        cov = max(cov, run);
        core = max(core, run * 0.7);
    }

    // The opening is a wide oval with a torn, noisy edge.
    float nx = Noise3(qu * 0.9 + 21.0) - 0.5;
    float ny = Noise3(qu * 0.9 + 33.0) - 0.5;
    float ox = x / hw + nx * 0.3;
    float oy = y / hh + ny * 0.5;
    float r2 = ox * ox + oy * oy;
    float inside = 1.0 - smoothstep(0.75, 1.0, r2);
    float dp = 1.0 - smoothstep(0.0, 0.55, r2);
    float rm = smoothstep(0.55, 0.85, r2) * (1.0 - smoothstep(1.0, 1.6, r2));
    wnd = max(wnd, inside * mask);
    deep = max(deep, dp * mask);
    rim = max(rim, rm * mask);

    // The guts fill the opening, leaving a dark edge, and bulge out below its lower edge in a blob that grows with G.
    float bd = 2.0 * hh * (0.25 + 0.75 * G);
    float cy = -(0.7 * hh + 0.5 * bd);
    float semiY = 0.3 * hh + 0.5 * bd;
    float semiX = hw * 0.8 * (0.6 + 0.4 * G);
    float bx = x / semiX + nx * 0.4;
    float by = (y - cy) / semiY + ny * 0.5;
    float rr = bx * bx + by * by;
    float covO = 1.0 - smoothstep(0.3, 0.75, r2);
    float covB = 1.0 - smoothstep(0.6, 1.0, rr);
    float gc = max(covO, covB) * mask;
    if (gc <= gutCov) return;

    // Two sets of fat tubes crossing at an angle. In each, a band coordinate warped by slow sines and noise (so the tubes
    // meander and loop, and differently for each worm) is turned into a round profile: 1 along the middle of a tube
    // and 0 at the crease between neighbours. Where they overlap the higher one wins, which reads as one over the other.
    vec2 w = vec2(x, y) / (0.44 * GUT_HW);
    float ph1 = 6.2831853 * Hash(vec2(seed, 41.0));
    float ph2 = 6.2831853 * Hash(vec2(seed, 43.0));
    float ph3 = 6.2831853 * Hash(vec2(seed, 47.0));
    float nz1 = Noise3(vec3(w * 0.7, Hash(vec2(seed, 53.0)) * 20.0));
    float nz2 = Noise3(vec3(w * 0.6 + 9.0, Hash(vec2(seed, 59.0)) * 20.0));
    float u1 = w.y * 1.6 + 0.55 * sin(w.x * 1.7 + ph1) + 0.3 * sin(w.x * 3.1 + w.y * 1.3 + ph2) + (nz1 - 0.5) * 1.4;
    float u2 = w.x * 1.1 + w.y * 1.3 + 0.6 * sin(w.y * 2.1 + ph3) + (nz2 - 0.5) * 1.6;
    float f1 = fract(u1) * 2.0 - 1.0;
    float f2 = fract(u2) * 2.0 - 1.0;
    float tubeA = sqrt(max(1.0 - f1 * f1, 0.0));
    float tubeB = sqrt(max(1.0 - f2 * f2, 0.0)) * 0.92;
    gutCov = gc;
    gutShade = max(tubeA, tubeB);
}

// Adds one worm's blood coverage and core darkness to cov and core, its wounds to wnd, deep and rim, its black eyes to
// bruise and socket and its intestines to gutCov and gutShade. b is the blood amount, wound level and heading and ex the
// eye level, gut level and gut azimuth. P is the pixel's view-space position and n its surface normal, facing the camera.
// mg_view is the world-to-view matrix in column-major layout with translation, so d * mat3(mg_view), which is
// transpose(R) * d, turns a view-space offset back into world axes. slotIdx is the slot number as a float, which gives
// the worm its own seed.
void Worm(vec3 P, vec3 n, vec3 centre, vec3 b, vec3 ex, float slotIdx,
          inout float cov, inout float core, inout float wnd, inout float deep, inout float rim,
          inout float bruise, inout float socket, inout float gutCov, inout float gutShade) {
    float amount = b.x;
    float wound = b.y;
    float eyeLevel = ex.x;
    float gutLevel = ex.y;
    if (amount <= 0.0 && wound <= 0.0 && eyeLevel <= 0.0 && gutLevel <= 0.0) return;
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

    if (wound > 0.0 || eyeLevel > 0.0 || gutLevel > 0.0) {
        vec3 en = qu / vec3(9.5, 16.0, 9.5);
        float el = length(en);
        if (el > 1e-4) {
            vec3 dir = en / el;
            if (wound > 0.0) {
                Site(dir, qu, seed, wound, 0.0, mask, cov, core, wnd, deep, rim);
                Site(dir, qu, seed, wound, 1.0, mask, cov, core, wnd, deep, rim);
                Site(dir, qu, seed, wound, 2.0, mask, cov, core, wnd, deep, rim);
                Site(dir, qu, seed, wound, 3.0, mask, cov, core, wnd, deep, rim);
                Site(dir, qu, seed, wound, 4.0, mask, cov, core, wnd, deep, rim);
            }
            if (eyeLevel > 0.0) {
                // One eye goes first (which one depends on the worm), the other follows as the level passes 0.3.
                float first = clamp(eyeLevel / 0.5, 0.0, 1.0);
                float second = clamp((eyeLevel - 0.3) / 0.7, 0.0, 1.0);
                float lead = Hash(vec2(seed, 91.0)) < 0.5 ? 1.0 : -1.0;
                Eye(qu, lead, first, mask, bruise, socket);
                Eye(qu, -lead, second, mask, bruise, socket);
            }
            if (gutLevel > 0.0) {
                Gut(qu, seed, gutLevel, ex.z, mask, cov, core, wnd, deep, rim, gutCov, gutShade);
            }
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
    float bruise = 0.0, socket = 0.0, gutCov = 0.0, gutShade = 0.0;
    Worm(P, n, p_worm0, p_worm0b, p_worm0c, 0.0, cov, core, wnd, deep, rim, bruise, socket, gutCov, gutShade);
    Worm(P, n, p_worm1, p_worm1b, p_worm1c, 1.0, cov, core, wnd, deep, rim, bruise, socket, gutCov, gutShade);
    Worm(P, n, p_worm2, p_worm2b, p_worm2c, 2.0, cov, core, wnd, deep, rim, bruise, socket, gutCov, gutShade);
    Worm(P, n, p_worm3, p_worm3b, p_worm3c, 3.0, cov, core, wnd, deep, rim, bruise, socket, gutCov, gutShade);
    Worm(P, n, p_worm4, p_worm4b, p_worm4c, 4.0, cov, core, wnd, deep, rim, bruise, socket, gutCov, gutShade);
    Worm(P, n, p_worm5, p_worm5b, p_worm5c, 5.0, cov, core, wnd, deep, rim, bruise, socket, gutCov, gutShade);
    Worm(P, n, p_worm6, p_worm6b, p_worm6c, 6.0, cov, core, wnd, deep, rim, bruise, socket, gutCov, gutShade);
    Worm(P, n, p_worm7, p_worm7b, p_worm7c, 7.0, cov, core, wnd, deep, rim, bruise, socket, gutCov, gutShade);
    Worm(P, n, p_worm8, p_worm8b, p_worm8c, 8.0, cov, core, wnd, deep, rim, bruise, socket, gutCov, gutShade);
    Worm(P, n, p_worm9, p_worm9b, p_worm9c, 9.0, cov, core, wnd, deep, rim, bruise, socket, gutCov, gutShade);
    Worm(P, n, p_worm10, p_worm10b, p_worm10c, 10.0, cov, core, wnd, deep, rim, bruise, socket, gutCov, gutShade);
    Worm(P, n, p_worm11, p_worm11b, p_worm11c, 11.0, cov, core, wnd, deep, rim, bruise, socket, gutCov, gutShade);
    Worm(P, n, p_worm12, p_worm12b, p_worm12c, 12.0, cov, core, wnd, deep, rim, bruise, socket, gutCov, gutShade);
    Worm(P, n, p_worm13, p_worm13b, p_worm13c, 13.0, cov, core, wnd, deep, rim, bruise, socket, gutCov, gutShade);
    Worm(P, n, p_worm14, p_worm14b, p_worm14c, 14.0, cov, core, wnd, deep, rim, bruise, socket, gutCov, gutShade);
    Worm(P, n, p_worm15, p_worm15b, p_worm15c, 15.0, cov, core, wnd, deep, rim, bruise, socket, gutCov, gutShade);
    cov *= p_strength;
    wnd *= p_strength;
    rim *= p_strength;
    bruise *= p_strength;
    socket *= p_strength;
    gutCov *= p_strength;
    if (cov <= 0.0 && wnd <= 0.0 && rim <= 0.0 && bruise <= 0.0 && gutCov <= 0.0) {
        gl_FragColor = scene;
        return;
    }

    vec3 tint = p_blood / max(max(p_blood.r, p_blood.g), max(p_blood.b, 1e-3));
    float lum = dot(scene.rgb, vec3(0.299, 0.587, 0.114));
    vec3 base = scene.rgb;

    // Black eyes go on the skin first, so the blood, wounds and guts all sit on top of them. The bruise multiplies the
    // scene toward purple-black, darker toward the socket, so the worm's shading and the eye's shape survive. Two kinds
    // of pixel are mostly left alone. One is near-white (bright and unsaturated): the eye white, which keeps the eye
    // reading as an eye. The other is anything not the colour of a worm's skin (red over green over blue, moderately
    // saturated): the oval is laid on whatever is in front of the face, and a helmet or a cap should not look bruised.
    if (bruise > 0.0) {
        float mx = max(scene.r, max(scene.g, scene.b));
        float mn = min(scene.r, min(scene.g, scene.b));
        float white = smoothstep(0.6, 0.85, mn) * (1.0 - smoothstep(0.1, 0.3, mx - mn));
        float rg = (scene.r - scene.g) / max(mx, 1e-3);
        float gb = (scene.g - scene.b) / max(mx, 1e-3);
        float skinTone = smoothstep(0.03, 0.1, rg) * (1.0 - smoothstep(0.38, 0.5, rg))
                       * smoothstep(0.0, 0.06, gb) * (1.0 - smoothstep(0.38, 0.55, gb));
        vec3 skin = base * mix(vec3(0.62, 0.46, 0.66), vec3(0.16, 0.10, 0.20), socket);
        base = mix(base, skin, bruise * (1.0 - 0.7 * white) * mix(0.2, 1.0, skinTone));
    }

    // Multiplying keeps the worm's shading and face: the blood stains the skin instead of covering it, and the core
    // goes darker and thicker than the rest.
    vec3 soaked = base * tint * mix(0.75, 0.4, core) + p_blood * 0.08 * (0.5 + core);
    vec3 col = mix(base, soaked, cov);

    // Wounds. The scene's luminance is kept in both layers so a lit wound is not flat.
    // The torn rim: raw flesh, the blood tint brightened and a little pink.
    vec3 raw = min(tint * 0.85 + vec3(0.2, 0.1, 0.12), vec3(1.0));
    col = mix(col, raw * (0.35 + 0.9 * lum), 0.75 * rim);
    // The wound itself: deep red at its edge, nearly black-red in the middle.
    vec3 clot = mix(p_blood * 0.9, p_blood * 0.15, deep);
    col = mix(col, clot * (0.6 + 0.8 * lum), 0.95 * wnd);

    // Intestines go on last, over the wound's interior: wet pink on the crest of each tube falling to dark red-brown in the
    // creases, nudged toward the blood tint so green blood gives sickly guts, lit like the worm but never fully black, with
    // a small highlight on the crests.
    if (gutCov > 0.0) {
        vec3 gc = mix(vec3(0.30, 0.08, 0.10), vec3(0.86, 0.50, 0.52), gutShade);
        gc = mix(gc, tint * dot(gc, vec3(0.299, 0.587, 0.114)) * 1.8, 0.2);
        gc *= 0.4 + 0.8 * lum;
        gc += vec3(0.9, 0.85, 0.85) * smoothstep(0.82, 1.0, gutShade) * 0.3 * (0.4 + lum);
        col = mix(col, gc, min(gutCov, 1.0));
    }
    gl_FragColor = vec4(col, scene.a);
}
