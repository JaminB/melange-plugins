#version 300 es
// Synthetic WUM-like scene for the preview harness: a ray-marched ground plane, sky gradient, sun + ambient light and up
// to 8 cartoon worms (upright capsule body, snout, white eyes with black pupils, optional hat). Writes the colour (rgba8)
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
uniform int u_what[8];      // 0 none, 1 cowboy hat, 2 helmet, 3 beanie
uniform float u_wrad[8];    // body radius
uniform float u_wsimple[8]; // 1 = body capsule only (fake mode)
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

// Distance to worm i and its material: 1 skin, 2 eye white, 3 pupil, 4 hat.
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
    vec3 qe = vec3(abs(q.x), q.y, q.z) - vec3(2.3, 3.8, 4.2);
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
    if (tHit > 0.0) {
        vec3 p = ro + rd * tHit;
        depth = DepthOf(-dot(p - ro, fwd));
        if (u_fake == 1) {
            col = texture(u_img, mg_uv).rgb;
        } else {
            vec3 n = Normal(p);
            vec3 alb = mat < 1.5 ? u_wskin[wi] : mat < 2.5 ? vec3(0.96) : mat < 3.5 ? vec3(0.03) : HatCol(u_what[wi]);
            float sh = Shadow(p + n * 0.15, sun);
            float ao = clamp(0.55 + 0.45 * smoothstep(0.0, 10.0, p.y), 0.0, 1.0);
            float ndl = max(dot(n, sun), 0.0);
            vec3 light = u_amb * ao * (0.85 + 0.15 * n.y) + u_sunCol * ndl * sh;
            col = alb * light;
            if (mat > 1.5 && mat < 3.5) col += vec3(0.25) * pow(max(dot(reflect(-sun, n), -rd), 0.0), 40.0) * sh;
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
    o_col = vec4(clamp(col, 0.0, 1.0), 1.0);
    o_depth = vec4(depth, 0.0, 0.0, 1.0);
}
