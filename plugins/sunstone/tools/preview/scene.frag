#version 300 es
// Synthetic WUM-like scene for the preview harness: a ray-marched ground plane, sky gradient, sun + ambient light and up
// to 8 cartoon worms (upright capsule body, snout, white eyes with black pupils, optional hat, optional moustache and
// hair-type headwear: afro, mohawk, mop wig). Writes the colour (rgba8)
// and Melange-style depth ([0,1], OpenGL convention, 1 = sky) to two targets. Units are game world units: a worm's body
// centre is 12 above its feet, the body is a capsule of radius 5.6 straight from -8 to +8 around the centre (the same
// numbers Bloodsand and Kindjal assume). In "fake" mode (a real frame with no depth) the colour comes from u_img and
// only the bodies' depth is produced, in front of a backdrop at u_backD.
precision highp float;
precision highp int;
in vec2 mg_uv;
layout(location = 0) out vec4 o_col;
layout(location = 1) out vec4 o_depth;

uniform vec3 u_camPos;
uniform mat3 u_camRot;      // view -> world rotation
uniform vec2 u_tan;         // tan(fovX/2), tan(fovY/2)
uniform vec2 u_nearFar;
uniform int u_nw;
uniform vec3 u_wc[8];       // body centres
uniform float u_wyaw[8];    // facing yaw (facing dir = (sin, 0, cos))
uniform vec3 u_wskin[8];
uniform int u_what[8];      // 0 none, 1 cowboy hat, 2 helmet, 3 beanie, 4 afro, 5 mohawk, 6 mop wig (4..6 = hair)
uniform vec3 u_whairCol[8]; // albedo of hair headwear (u_what 4..6)
uniform int u_wtash[8];     // moustache: 0 none, 1 walrus (two lobes under the snout), 2 handlebar (thinner, curled)
uniform vec3 u_wtashCol[8]; // moustache albedo
uniform float u_wstreak[8]; // strength of the strand streaks in the hair/moustache albedo (vanilla-like texture)
uniform float u_wrad[8];    // body radius
uniform float u_wsimple[8]; // 1 = body capsule only (fake mode)
uniform vec4 u_wmouth[8];   // mouth (opt-in): x open 0..1, y shape 0 'o' / 1 'wide' (shout) / 2 'grin', z teeth 0/1,
                            // w 1 = the worm has a mouth (0: no mouth at all, as in the older scenarios)
uniform vec3 u_wlip[8];     // lip albedo (a darker, pinker skin)
uniform float u_wvomit[8];  // Bloodsand's vomiting: blood droplets (flat sprites, no depth) from the mouth, 0..1
uniform float u_wmark[8];   // 1 = the skin (and lips) carry Sunstone's skin mark: scene alpha 245/255 (a "tone" worm)
uniform vec3 u_sunDir;
uniform vec3 u_sunCol;
uniform vec3 u_amb;
uniform vec3 u_skyTop;
uniform vec3 u_skyHor;
uniform vec3 u_groundCol;
uniform float u_groundNoise;
uniform int u_fake;
uniform sampler2D u_img;
uniform float u_backD;

float sdCapsuleY(vec3 p, float h, float r) { p.y -= clamp(p.y, -h, h); return length(p) - r; }
float sdEll(vec3 p, vec3 r) { float k0 = length(p / r), k1 = length(p / (r * r)); return k0 * (k0 - 1.0) / max(k1, 1e-6); }
float sdCylY(vec3 p, float r, float h) {
    vec2 d = abs(vec2(length(p.xz), p.y)) - vec2(r, h);
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0));
}
float smin(float a, float b, float k) { float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0); return mix(b, a, h) - k * h * (1.0 - h); }

vec3 RotX(vec3 p, float a) { float s = sin(a), c = cos(a); return vec3(p.x, c * p.y - s * p.z, s * p.y + c * p.z); }
vec3 RotZ(vec3 p, float a) { float s = sin(a), c = cos(a); return vec3(c * p.x - s * p.y, s * p.x + c * p.y, p.z); }

// Moustache in the worm frame q (mirrored in x): sits on the face under the snout (snout centre y 0.2, bottom ~-1.5),
// above Sunstone's mouth line (y -2.7), inside Bloodsand's mouth search zone (z >= 2, y -6..1). Clumpy lower edge.
float Tash(vec3 q, int t) {
    vec3 m = vec3(abs(q.x), q.y, q.z);
    float d;
    if (t == 2) {
        // handlebar: a thin bar under the nose sweeping out and curling up at the tips
        vec3 a = RotZ(m - vec3(1.9, -1.35, 5.15), -0.28);
        d = sdEll(a, vec3(2.3, 0.55, 0.75));
        vec3 tip = m - vec3(4.0, -0.75, 4.45);
        d = smin(d, sdEll(RotZ(tip, 0.9), vec3(0.9, 0.35, 0.45)), 0.5);
    } else {
        // walrus: two drooping lobes meeting at the philtrum
        vec3 a = RotZ(m - vec3(1.45, -1.55, 5.05), -0.32);
        d = sdEll(a, vec3(2.05, 0.95, 1.05));
        d = smin(d, sdEll(m - vec3(0.0, -1.2, 5.55), vec3(0.9, 0.7, 0.75)), 0.6);
        // strand clumps fraying the lower edge
        d -= 0.13 * smoothstep(-1.2, -2.2, q.y) * (0.5 + 0.5 * sin(q.x * 5.3));
    }
    return d * 0.8;
}

// Hair headwear in the worm frame (head top at y ~13.6, eyes up to y ~6.5 at the front, face front z ~5.6).
float Hair(vec3 q, int h) {
    if (h == 4) {
        // afro: big curly dome above the eyes, back of the head covered down to y ~4
        float d = sdEll(q - vec3(0.0, 11.4, -0.9), vec3(8.2, 6.9, 7.7));
        float cut = mix(3.5, 7.3, smoothstep(-2.0, 3.5, q.z));
        d = max(d, -(q.y - cut));
        d += 0.24 * sin(q.x * 1.7 + 0.6) * sin(q.y * 1.5 + 1.3) * sin(q.z * 1.6 + 2.1);
        return d * 0.6;
    }
    if (h == 5) {
        // mohawk: a spiky crest along the head's midline, shaved sides
        float spikes = 0.5 + 0.5 * cos(q.z * 1.3);
        float d = sdEll(q - vec3(0.0, 14.6, -0.6), vec3(1.5, 4.6 + 2.0 * spikes, 7.2));
        d = max(d, -(q.y - 10.0));
        return d * 0.7;
    }
    // 6: mop wig (bowl cut): covers the crown, long at the back and sides, fringe ending above the eyes
    float d = sdCapsuleY(q - vec3(0.0, 8.6, -0.25), 3.6, 6.35);
    float cut = mix(1.2, 7.1, smoothstep(0.5, 4.2, q.z));
    d = max(d, -(q.y - cut));
    d -= 0.12 * sin(atan(q.x, q.z) * 21.0) * smoothstep(cut + 2.5, cut, q.y);   // ragged tips
    return d * 0.75;
}

// Open mouth (opt-in, u_wmouth[i].w = 1), in the worm frame: under the snout (bottom ~-1.5), centred on Sunstone's mouth
// line (y ~-2.7) and Bloodsand's vomit point (9.5 above the feet = y -2.5, 6 in front). The top lip stays just under the
// snout and the jaw drops as it opens. my: the opening's centre, rx half-width, ryT/ryB half-heights above/below my, cv how
// far the corners rise (grin, >0) or drop (shout, <0) in units, zs the face's surface z there.
struct MouthD { float my, rx, ryT, ryB, cv, zs; };
float Sq1(float x) { return x * x; }
MouthD MouthDims(int i) {
    vec4 m = u_wmouth[i];
    float o = clamp(m.x, 0.0, 1.0);
    MouthD d;
    if (m.y < 0.5) {            // 'o': round, small to medium
        d.rx = 0.7 + 0.6 * o; d.ryT = 0.10 + 0.95 * o; d.ryB = d.ryT; d.cv = 0.0;
    } else if (m.y < 1.5) {     // 'wide': a shout, flatter top lip, the jaw dropped, corners a little down
        d.rx = 1.7 + 0.8 * o; d.ryT = 0.10 + 0.6 * o; d.ryB = 0.10 + 1.5 * o; d.cv = -0.35 * o;
    } else {                    // 'grin': wide and shallow, corners up
        d.rx = 2.3 + 0.4 * o; d.ryT = 0.10 + 0.25 * o; d.ryB = 0.10 + 0.75 * o; d.cv = 0.6;
    }
    d.my = -1.95 - d.ryT;
    d.zs = u_wrad[i] + 0.6 * (1.0 - smoothstep(-12.0, 2.0, d.my));
    return d;
}
// 2D elliptic coordinate of the opening (1 on its rim) and the vertical offset from the curved centre line.
float MouthE(vec3 q, MouthD d, out float yy) {
    float xn = q.x / d.rx;
    yy = q.y - d.my - d.cv * xn * xn;
    return length(vec2(xn, yy / (yy > 0.0 ? d.ryT : d.ryB)));
}
// The carved cavity (an ellipsoid reaching ~2.8 into the head) as a distance (approximate, conservative).
float MouthCav(vec3 q, MouthD d) {
    float xn = q.x / d.rx;
    float yy = q.y - d.my - d.cv * xn * xn;
    return sdEll(vec3(q.x, yy, q.z - (d.zs + 0.5)), vec3(d.rx, yy > 0.0 ? d.ryT : d.ryB, 3.3));
}
// Signed distance (units, approximate) from the rim of the opening across the face; the lips are a band round it.
float MouthRing(vec3 q, MouthD d) {
    float xn = q.x / d.rx;
    float yy = q.y - d.my - d.cv * xn * xn;
    return sdEll(vec3(q.x, yy, 0.0), vec3(d.rx, max(yy > 0.0 ? d.ryT : d.ryB, 0.45), 1.0));
}
float smax(float a, float b, float k) { return -smin(-a, -b, k); }

// Distance to worm i and its material: 1 skin, 2 eye white, 3 pupil, 4 hat, 5 moustache, 6 hair headwear, 7 mouth cavity,
// 8 tongue, 9 teeth.
vec2 Worm(vec3 pw, int i) {
    vec3 L = pw - u_wc[i];
    float s = sin(u_wyaw[i]), c = cos(u_wyaw[i]);
    // Same frame as Bloodsand's qu: x to the worm's right, y up, z forward (facing).
    vec3 q = vec3(L.x * c - L.z * s, L.y, L.x * s + L.z * c);
    float r = u_wrad[i] + 0.6 * (1.0 - smoothstep(-12.0, 2.0, q.y));
    vec2 res = vec2(sdCapsuleY(q, 8.0, r), 1.0);
    if (u_wsimple[i] > 0.5) return res;
    float sn = sdEll(q - vec3(0.0, 0.2, 4.7), vec3(2.6, 1.7, 1.7));
    res.x = smin(res.x, sn, 1.2);
    if (u_wmouth[i].w > 0.5 && q.z > 1.5 && q.y < 1.0 && q.y > -9.0) {
        MouthD md = MouthDims(i);
        float front = smoothstep(3.5, 5.0, q.z);
        // lips: a soft rolled ring round the opening (closed: a pair of lips over a seam)
        float ring = MouthRing(q, md);
        res.x -= 0.26 * exp(-Sq1(ring / 0.38)) * front;
        if (u_wmouth[i].x > 0.02) {
            float cav = MouthCav(q, md);
            float body = smax(res.x, -cav, 0.12);
            res = vec2(body, -cav > res.x - 0.02 ? 7.0 : 1.0);
            // tongue: a rounded lump on the floor of the mouth, a little back
            float yB = md.my - md.ryB;
            vec3 tq = q - vec3(0.0, yB + 0.3 + 0.25 * md.ryB, md.zs - 1.25);
            float tg = sdEll(tq, vec3(0.62 * md.rx, max(0.42 * md.ryB, 0.28), 1.35));
            tg = max(tg, cav - 0.05);
            if (tg < res.x) res = vec2(tg, 8.0);
            if (u_wmouth[i].z > 0.5) {
                // teeth: an upper row just inside the top lip, following its curve; a lower row for a wide or grinning mouth
                float xn = q.x / md.rx;
                float cy = md.my + md.cv * xn * xn;
                vec3 uq = vec3(q.x, q.y - (cy + md.ryT - 0.22), q.z - (md.zs - 0.55));
                vec3 bh = vec3(0.80 * md.rx, 0.30, 0.28);
                vec3 dq = abs(uq) - bh;
                float th = length(max(dq, 0.0)) + min(max(dq.x, max(dq.y, dq.z)), 0.0) - 0.08;
                if (u_wmouth[i].y > 0.5) {
                    vec3 lq = vec3(q.x, q.y - (cy - md.ryB + 0.2), q.z - (md.zs - 0.75));
                    vec3 dl = abs(lq) - vec3(0.62 * md.rx, 0.20, 0.26);
                    th = min(th, length(max(dl, 0.0)) + min(max(dl.x, max(dl.y, dl.z)), 0.0) - 0.07);
                }
                th = max(th, cav + 0.02);
                if (th < res.x) res = vec2(th, 9.0);
            }
        }
        res.x *= 0.85;
    }
    vec3 qe =vec3(abs(q.x), q.y, q.z) - vec3(2.3, 3.8, 4.2);
    float eye = sdEll(qe, vec3(1.9, 2.7, 1.8));
    if (eye < res.x) res = vec2(eye, 2.0);
    float pup = length(qe - vec3(-0.35, -0.3, 1.45)) - 0.8;
    if (pup < res.x) res = vec2(pup, 3.0);
    int h = u_what[i];
    float hat = 1e9;
    if (h == 1) {
        float brim = sdCylY(q - vec3(0.0, 12.4, 0.0), 8.6, 0.35) - 0.15;
        float crown = sdCylY(q - vec3(0.0, 15.2, 0.0), 4.3, 2.6) - 0.6;
        hat = min(brim, crown);
    } else if (h == 2) {
        float dome = max(length(q - vec3(0.0, 8.6, 0.0)) - 6.5, -(q.y - 8.0));
        float rim = sdCylY(q - vec3(0.0, 8.2, 0.0), 7.1, 0.3);
        hat = min(dome, rim);
    } else if (h == 3) {
        hat = max(length(q - vec3(0.0, 9.6, 0.0)) - 6.0, -(q.y - 10.0));
    }
    if (hat < res.x) res = vec2(hat, 4.0);
    if (h >= 4) {
        float hr = Hair(q, h);
        if (hr < res.x) res = vec2(hr, 6.0);
    }
    if (u_wtash[i] > 0) {
        float t = Tash(q, u_wtash[i]);
        if (t < res.x) res = vec2(t, 5.0);
    }
    return res;
}

vec3 HatCol(int h) {
    if (h == 1) return vec3(0.50, 0.36, 0.17);  // cowboy hat, hue ~36 deg, sat ~0.66 (outside SkinTone)
    if (h == 2) return vec3(0.31, 0.37, 0.22);  // olive helmet
    return vec3(0.18, 0.28, 0.66);              // blue beanie
}

// Scene distance (worms only) with the worm index and material.
vec2 Map(vec3 p, out int wi) {
    vec2 best = vec2(1e9, 0.0);
    wi = -1;
    for (int i = 0; i < 8; i++) {
        if (i >= u_nw) break;
        vec2 d = Worm(p, i);
        if (d.x < best.x) { best = d; wi = i; }
    }
    return best;
}

float MapD(vec3 p) { int wi; return Map(p, wi).x; }

vec3 Normal(vec3 p) {
    vec2 e = vec2(0.02, 0.0);
    return normalize(vec3(MapD(p + e.xyy) - MapD(p - e.xyy), MapD(p + e.yxy) - MapD(p - e.yxy), MapD(p + e.yyx) - MapD(p - e.yyx)));
}

// The normal of the hit material's own surface where the skin meets a moustache: a central difference across the crease of
// the two fields' min() mixes their gradients and lit a bright one-pixel line of skin along the moustache's upper edge, which
// the game (a moustache mesh lying on the face) does not have. Each axis takes the one-sided difference on the side whose
// sample is still the same material.
float NAxis(vec3 p, vec3 e, float d0, float mat) {
    int w;
    vec2 a = Map(p + e, w), b = Map(p - e, w);
    bool ia = abs(a.y - mat) < 0.5, ib = abs(b.y - mat) < 0.5;
    return ia == ib ? 0.5 * (a.x - b.x) : ia ? a.x - d0 : d0 - b.x;
}

vec3 NormalM(vec3 p, float mat) {
    if (abs(mat - 1.0) > 0.5 && abs(mat - 5.0) > 0.5) return Normal(p);
    float d0 = MapD(p);
    return normalize(vec3(NAxis(p, vec3(0.02, 0.0, 0.0), d0, mat), NAxis(p, vec3(0.0, 0.02, 0.0), d0, mat),
                          NAxis(p, vec3(0.0, 0.0, 0.02), d0, mat)));
}

float Shadow(vec3 ro, vec3 rd) {
    float res = 1.0, t = 0.2;
    for (int k = 0; k < 64; k++) {
        float h = MapD(ro + rd * t);
        res = min(res, 10.0 * h / t);
        t += clamp(h, 0.2, 4.0);
        if (res < 0.001 || t > 90.0) break;
    }
    return clamp(res, 0.0, 1.0);
}

float Hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float Noise(vec2 p) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(Hash(i), Hash(i + vec2(1, 0)), f.x), mix(Hash(i + vec2(0, 1)), Hash(i + vec2(1, 1)), f.x), f.y);
}

// Vanilla-like hair texture: strand streaks (multiplicative, so the colour's ratios, which the classifiers read, stay).
float Streak(vec3 q, float mat, int h) {
    float n;
    if (mat > 5.5 && h == 4) {
        n = Noise(q.xy * 1.9 + q.z * 0.7) * 0.6 + Noise(q.zy * 3.7) * 0.4;                         // curls
    } else if (mat > 5.5 && h == 5) {
        n = Noise(vec2(q.z * 2.2 + q.x * 7.0, q.y * 0.35)) * 0.7 + Noise(vec2(q.z * 6.0, q.y)) * 0.3;  // upright strands
    } else if (mat > 5.5) {
        n = Noise(vec2(atan(q.x, q.z) * 14.0, q.y * 0.4)) * 0.65 + Noise(vec2(atan(q.x, q.z) * 37.0, q.y)) * 0.35;
    } else {
        n = Noise(vec2(q.x * 3.2 + 0.9 * abs(q.y), q.y * 0.5)) * 0.65 + Noise(vec2(q.x * 8.0, q.y * 1.5)) * 0.35;
    }
    return n;
}

float DepthOf(float viewZ) {   // viewZ < 0 in front of the camera
    float n = u_nearFar.x, f = u_nearFar.y;
    float ndc = (-(f + n) / (f - n) * viewZ - 2.0 * f * n / (f - n)) / (-viewZ);
    return clamp(ndc * 0.5 + 0.5, 0.0, 1.0);
}

void main() {
    vec3 v = vec3((mg_uv.x * 2.0 - 1.0) * u_tan.x, (mg_uv.y * 2.0 - 1.0) * u_tan.y, -1.0);
    vec3 rd = normalize(u_camRot * v);
    vec3 ro = u_camPos;
    vec3 fwd = u_camRot * vec3(0.0, 0.0, -1.0);
    vec3 sun = normalize(u_sunDir);

    float tEnd = 1e6;
    float tG = -1.0;
    if (u_fake == 0 && rd.y < -1e-4) { tG = -ro.y / rd.y; tEnd = tG; }
    if (u_fake == 1) tEnd = u_backD / max(dot(rd, fwd), 1e-3);

    // Bounding spheres of the worms bound the march.
    float t0 = 1e9, t1 = -1.0;
    for (int i = 0; i < 8; i++) {
        if (i >= u_nw) break;
        vec3 oc = ro - (u_wc[i] + vec3(0.0, 3.0, 0.0));
        float b = dot(oc, rd), cc = dot(oc, oc) - 22.0 * 22.0, disc = b * b - cc;
        if (disc > 0.0) { float sq = sqrt(disc); t0 = min(t0, max(-b - sq, 0.0)); t1 = max(t1, -b + sq); }
    }
    float tHit = -1.0;
    int wi = -1;
    float mat = 0.0;
    if (t1 > 0.0) {
        float t = t0;
        float lim = min(t1, tEnd);
        for (int k = 0; k < 220; k++) {
            if (t > lim) break;
            int w;
            vec2 d = Map(ro + rd * t, w);
            if (d.x < 0.002 + 0.0002 * t) { tHit = t; wi = w; mat = d.y; break; }
            t += d.x * 0.9;
        }
    }

    vec3 col;
    float depth;
    float alpha = 1.0;
    if (tHit > 0.0) {
        if (mat < 1.5 && u_wmark[wi] > 0.5) alpha = 245.0 / 255.0;
        vec3 p = ro + rd * tHit;
        depth = DepthOf(-dot(p - ro, fwd));
        if (u_fake == 1) {
            col = texture(u_img, mg_uv).rgb;
        } else {
            vec3 n = NormalM(p, mat);
            vec3 alb = mat < 1.5 ? u_wskin[wi] : mat < 2.5 ? vec3(0.96) : mat < 3.5 ? vec3(0.03) : mat < 4.5 ? HatCol(u_what[wi])
                     : mat < 5.5 ? u_wtashCol[wi] : mat < 6.5 ? u_whairCol[wi]
                     : mat < 7.5 ? vec3(0.34, 0.09, 0.075) : mat < 8.5 ? vec3(0.86, 0.36, 0.38) : vec3(0.95, 0.93, 0.86);
            float mouthDark = 0.0;   // how deep inside the mouth (0 = not), for the occlusion below
            if (u_wmouth[wi].w > 0.5 && (mat < 1.5 || mat > 6.5)) {
                vec3 L = p - u_wc[wi];
                float s = sin(u_wyaw[wi]), c = cos(u_wyaw[wi]);
                vec3 q = vec3(L.x * c - L.z * s, L.y, L.x * s + L.z * c);
                MouthD md = MouthDims(wi);
                float yy;
                float e2 = MouthE(q, md, yy);
                float front = smoothstep(3.5, 5.0, q.z);
                if (mat < 1.5) {
                    // lips: darker, pinker skin in a band round the opening; closed, a seam between the two lips
                    float ring = MouthRing(q, md);
                    float lip = smoothstep(0.62, 0.25, ring) * front * smoothstep(1.4, 1.0, abs(q.x) / md.rx);
                    alb = mix(alb, u_wlip[wi], lip);
                    if (u_wmouth[wi].x <= 0.02)
                        alb *= 1.0 - 0.8 * exp(-Sq1(yy / 0.1)) * smoothstep(1.02, 0.9, abs(q.x) / md.rx) * front;
                } else {
                    mouthDark = clamp((md.zs + 0.1 - q.z) / 2.3, 0.0, 1.0);
                    if (mat < 7.5 && u_wmouth[wi].z > 0.5) {
                        // gums: pink-red above the upper teeth (and below the lower ones)
                        float xn = q.x / md.rx;
                        float cy = md.my + md.cv * xn * xn;
                        float g = smoothstep(cy + md.ryT - 0.5, cy + md.ryT - 0.1, q.y);
                        if (u_wmouth[wi].y > 0.5) g = max(g, smoothstep(cy - md.ryB + 0.55, cy - md.ryB + 0.15, q.y));
                        alb = mix(alb, vec3(0.80, 0.36, 0.40), g * (1.0 - mouthDark));
                    }
                    if (mat > 8.5) {
                        // gaps between the teeth
                        float tx = abs(fract(q.x / 0.62 + 0.5) - 0.5);
                        alb *= mix(0.55, 1.0, smoothstep(0.03, 0.11, tx));
                    }
                }
            }
            if (mat > 4.5) {
                vec3 L = p - u_wc[wi];
                float s = sin(u_wyaw[wi]), c = cos(u_wyaw[wi]);
                vec3 q = vec3(L.x * c - L.z * s, L.y, L.x * s + L.z * c);
                alb *= 1.0 + u_wstreak[wi] * (Streak(q, mat, u_what[wi]) - 0.5) * 2.0;
            }
            float sh = Shadow(p + n * 0.15, sun);
            float ao = clamp(0.55 + 0.45 * smoothstep(0.0, 10.0, p.y), 0.0, 1.0);
            float ndl = max(dot(n, sun), 0.0);
            vec3 light = u_amb * ao * (0.85 + 0.15 * n.y) + u_sunCol * ndl * sh;
            if (mat > 6.5) light *= mix(1.0, mat > 8.5 ? 0.45 : 0.12, mouthDark);   // little light gets into the mouth
            col = alb * light;
            if (mat > 1.5 && mat < 3.5) col += vec3(0.25) * pow(max(dot(reflect(-sun, n), -rd), 0.0), 40.0) * sh;
            if (mat > 7.5) col += vec3(0.18) * pow(max(dot(reflect(-sun, n), -rd), 0.0), 30.0) * sh * (1.0 - mouthDark);   // wet tongue, enamel
        }
    } else if (u_fake == 1) {
        col = texture(u_img, mg_uv).rgb;
        depth = DepthOf(-u_backD);
    } else if (tG > 0.0) {
        vec3 p = ro + rd * tG;
        depth = DepthOf(-dot(p - ro, fwd));
        float nz = Noise(p.xz * 0.06) * 0.6 + Noise(p.xz * 0.23) * 0.3 + Noise(p.xz * 1.1) * 0.1;
        float rip = 0.5 + 0.5 * sin(p.x * 0.35 + 3.0 * Noise(p.xz * 0.05));
        vec3 alb = u_groundCol * (1.0 + u_groundNoise * (nz - 0.5) * 2.0 + 0.04 * (rip - 0.5));
        float sh = Shadow(p + vec3(0.0, 0.1, 0.0), sun);
        float occ = clamp(0.45 + 0.55 * smoothstep(0.0, 7.0, MapD(p)), 0.0, 1.0);
        col = alb * (u_amb * occ + u_sunCol * max(sun.y, 0.0) * sh);
        // a little aerial haze toward the horizon
        float fog = 1.0 - exp(-tG * 0.0012);
        col = mix(col, u_skyHor, fog * 0.6);
    } else {
        float h = clamp(rd.y, 0.0, 1.0);
        col = mix(u_skyHor, u_skyTop, pow(h, 0.6));
        col += u_sunCol * 0.25 * pow(max(dot(rd, sun), 0.0), 200.0);
        depth = 1.0;
    }
    // Bloodsand's vomiting (opt-in, per worm): its droplets are flat sprites in the palette's droplet colour (0.62, 0.03,
    // 0.03) times 0.65..1.1, alpha 0.9, drawn after the world, tested against its depth but not written to it. Here a
    // stream of them from the mouth (spawned 6 in front, 9.5 above the feet), arcing forward and down.
    float tScene = tHit > 0.0 ? tHit : (tG > 0.0 ? tG : 1e6);
    if (u_fake == 0) {
        for (int i = 0; i < 8; i++) {
            if (i >= u_nw) break;
            float v = u_wvomit[i];
            if (v <= 0.0 || u_wmouth[i].w < 0.5) continue;
            MouthD md = MouthDims(i);
            float s = sin(u_wyaw[i]), c = cos(u_wyaw[i]);
            vec3 fw = vec3(s, 0.0, c), sd = vec3(c, 0.0, -s);
            vec3 m0 = u_wc[i] + fw * (md.zs + 0.2) + vec3(0.0, md.my - 0.3 * md.ryB, 0.0);
            for (int k = 0; k < 22; k++) {
                float fk = float(k);
                float h1 = Hash(vec2(fk, float(i) * 7.3)), h2 = Hash(vec2(fk * 1.7 + 3.1, float(i))), h3 = Hash(vec2(fk + 9.2, 4.4));
                float tt = pow((fk + h1 * 0.8) / 22.0, 1.4);
                vec3 cp = m0 + fw * (tt * 15.0 * v) + sd * ((h2 - 0.5) * 3.5 * tt) + vec3(0.0, -tt * tt * 11.0 * v - 1.2 * tt, 0.0)
                        + 0.5 * vec3(h3 - 0.5, h1 - 0.5, h2 - 0.5);
                float rad = mix(0.55, 0.28, tt) * (0.7 + 0.6 * h3) * (0.6 + 0.4 * v);
                vec3 oc = ro - cp;
                float b = dot(oc, rd), cc = dot(oc, oc) - rad * rad, disc = b * b - cc;
                if (disc > 0.0) {
                    float th = -b - sqrt(disc);
                    if (th > 0.0 && th < tScene) col = mix(col, min(vec3(0.62, 0.03, 0.03) * mix(0.65, 1.1, h2), 1.0), 0.9);
                }
            }
        }
    }
    o_col = vec4(clamp(col, 0.0, 1.0), alpha);
    o_depth = vec4(depth, 0.0, 0.0, 1.0);
}
