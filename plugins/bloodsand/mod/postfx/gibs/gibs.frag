#version 120
// Gibs, ray-marched. Bloodsand's Lua throws meat chunks, bone shards and organs out of a worm that dies or takes a very big
// hit, simulates them (flight, bounces, rolling, rest) and sends each live one as four vec4 uniforms: up to 16 slots at a
// time. Here each is a signed distance field in its own local frame, marched inside its bounding sphere: irregular meat
// chunks (a rounded box eaten away by noise and sometimes sliced by a torn plane, with red muscle fibres, fat marbling and
// silverskin), bone shards (a tapered shaft with a jagged, hollow break and a spongy end, sometimes a knob), a kidney, a
// liver lobe, a heart with its vessels and an eyeball with its stump of nerve. A pixel finds which slot's bounding sphere the
// view ray enters first (a short test per slot), copies that slot's four vec4 into globals and marches it once, so the long
// code is never expanded per slot. The hit is lit with a key light from above, a camera-relative fill, wrap lighting with a
// red subsurface term, a wet specular lobe that fades as the gib dries and darkens (p_clock against the gib's birth), fresnel
// reflection and rim, ambient taken from the scene around the pixel and ambient occlusion from the field itself. Pixels that
// miss but sit close to a gib get a contact shadow, a cast shadow and a smear of blood. Nothing is written over the scene
// except where a gib is in front of the scene's depth.
//
// Per slot k (0..15), all hidden and set by Bloodsand: gka = bounding sphere (centre xyz, radius; radius 0 = slot unused),
// gkb = orientation as a unit quaternion (x, y, z, w) of local space to world, gkc = half extents in local space (xyz) and
// the type (w: 0 meat, 1 bone, 2 kidney, 3 liver lobe, 4 heart, 5 eye), gkd = seed, birth (p_clock when it was thrown),
// starting wetness 0..1 and bloodiness 0..1. Everything is in world units. p_count is one more than the highest slot in use
// (nothing runs at 0), p_clock is Bloodsand's own clock and p_dryTime the seconds a gib takes to dry.
//
// The loops below have constant bounds and the field is called from one place per stage (march, normal, occlusion, shadow,
// contact), so the compiler has to expand it only a handful of times.
uniform sampler2D mg_scene;
uniform sampler2D mg_depth;
uniform mat4 mg_invProj;
uniform mat4 mg_proj;
uniform mat4 mg_view;
uniform vec4 mg_resolution;
uniform vec4 p_g0a, p_g0b, p_g0c, p_g0d, p_g1a, p_g1b, p_g1c, p_g1d, p_g2a, p_g2b, p_g2c, p_g2d, p_g3a, p_g3b, p_g3c, p_g3d;
uniform vec4 p_g4a, p_g4b, p_g4c, p_g4d, p_g5a, p_g5b, p_g5c, p_g5d, p_g6a, p_g6b, p_g6c, p_g6d, p_g7a, p_g7b, p_g7c, p_g7d;
uniform vec4 p_g8a, p_g8b, p_g8c, p_g8d, p_g9a, p_g9b, p_g9c, p_g9d, p_g10a, p_g10b, p_g10c, p_g10d, p_g11a, p_g11b, p_g11c, p_g11d;
uniform vec4 p_g12a, p_g12b, p_g12c, p_g12d, p_g13a, p_g13b, p_g13c, p_g13d, p_g14a, p_g14b, p_g14c, p_g14d, p_g15a, p_g15b, p_g15c, p_g15d;
uniform vec3 p_blood;
uniform float p_strength;
uniform float p_clock;
uniform float p_count;
uniform float p_dryTime;
varying vec2 mg_uv;

const float RECV = 2.6;         // how far beyond a gib's own sphere its bounding sphere reaches: what it darkens and stains

// The gib of the slot this pixel belongs to.
vec3 GC;                        // centre
mat3 GM;                        // local to world
vec4 GH;                        // half extents, type
vec4 GD;                        // seed, birth, wetness, bloodiness
float GB;                       // bounding radius
vec3 GN1;                       // a meat chunk's two tear planes' normals, or a bone's break plane's (made once per pixel by Prep)
vec3 GN2;
vec4 GF;                        // whether the first and second tear are there, whether the bone has a knob, the zigzag's frequency

float Hash3(vec3 p) {
    return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453);
}

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

mat3 QuatMat(vec4 q) {
    float xx = q.x * q.x;
    float yy = q.y * q.y;
    float zz = q.z * q.z;
    float xy = q.x * q.y;
    float xz = q.x * q.z;
    float yz = q.y * q.z;
    float wx = q.w * q.x;
    float wy = q.w * q.y;
    float wz = q.w * q.z;
    return mat3(1.0 - 2.0 * (yy + zz), 2.0 * (xy + wz), 2.0 * (xz - wy),
                2.0 * (xy - wz), 1.0 - 2.0 * (xx + zz), 2.0 * (yz + wx),
                2.0 * (xz + wy), 2.0 * (yz - wx), 1.0 - 2.0 * (xx + yy));
}

// How dry the current gib is (0 just thrown, 1 dried out) and how wet (its starting wetness, gone as it dries).
float Dry() {
    float d = clamp(max(p_clock - GD.y, 0.0) / max(p_dryTime, 1.0), 0.0, 1.0);
    return d * d * (3.0 - 2.0 * d);
}

// A direction picked by the seed: the normal of a tear plane through a meat chunk.
vec3 CutN(float sd, float j) {
    return normalize(vec3(sin(sd * 12.9 + j * 4.1), cos(sd * 7.3 + j * 2.2) * 0.6, sin(sd * 5.1 + j * 7.7)));
}

float SdBox(vec3 p, vec3 b) {
    vec3 q = abs(p) - b;
    return length(max(q, 0.0)) + min(max(q.x, max(q.y, q.z)), 0.0);
}

float SdEllipsoid(vec3 p, vec3 r) {
    float k0 = length(p / r);
    float k1 = length(p / (r * r));
    return k0 * (k0 - 1.0) / max(k1, 1e-4);
}

float SdCapsule(vec3 p, vec3 a, vec3 b, float r) {
    vec3 pa = p - a;
    vec3 ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-5), 0.0, 1.0);
    return length(pa - ba * h) - r;
}

float SMin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}

float SMax(float a, float b, float k) {
    return -SMin(-a, -b, k);
}

// The distance to the gib in its own frame. One body of code for all six kinds, picked by the type, so the compiler sees it
// once. The sizes come from the half extents: a meat chunk is a rounded box, a bone's x is half its length and y and z the
// radii of its two ends, an organ an ellipsoid with the additions of its kind, an eye a sphere of radius x.
float Shape(vec3 p) {
    vec3 h = GH.xyz;
    float ty = GH.w;
    float sd = GD.x;
    float mn = min(h.x, min(h.y, h.z));
    float d = 1e5;
    if (ty < 0.5) {
        // Meat: a box with its corners rounded, eaten by two octaves of noise and sliced by up to two ragged planes (cuts and
        // tears), so it comes out as an irregular angular chunk.
        float rr = mn * 0.28;
        // (bent and pinched a little first, so that it is not a cube, and part ellipsoid, so that its corners are not sharp)
        vec3 q = p;
        q.xz += 0.3 * mn * vec2(sin(p.y / mn * 1.2 + sd), cos(p.z / mn * 1.1 + sd * 1.7));
        q.y *= 1.0 + 0.25 * sin(p.x / h.x * 1.5 + sd * 2.0);
        d = mix(SdBox(q, max(h - rr, vec3(0.05))) - rr, SdEllipsoid(q, h * 0.98), 0.35);
        float k = 1.3 / mn;
        float n1 = Noise3(p * k + sd);
        float n2 = Noise3(p * k * 2.9 + sd * 1.9);
        d += (n1 - 0.5) * mn * 0.7 + (n2 - 0.5) * mn * 0.2;
        if (GF.x > 0.5) d = SMax(d, dot(p, GN1) - 0.58 * dot(abs(GN1), h) + (n2 - 0.5) * mn * 0.35, mn * 0.1);
        if (GF.y > 0.5) d = SMax(d, dot(p, GN2) - 0.72 * dot(abs(GN2), h) + (n1 - 0.5) * mn * 0.4, mn * 0.1);
    } else if (ty < 1.5) {
        // Bone: a shaft tapering from radius y at -x to z at +x, a knob at the thick end on some, a break at the thin end
        // whose edge zigzags into splinters, hollowed into the marrow.
        float L = h.x;
        float t = clamp((p.x + L) / (2.0 * L), 0.0, 1.0);
        float r = mix(h.y, h.z, t);
        d = length(p - vec3(clamp(p.x, -L, L), 0.0, 0.0)) - r;
        if (GF.z > 0.5) d = SMin(d, length(p - vec3(-L, 0.0, 0.0)) - h.y * 1.45, h.y * 0.7);
        float ang = atan(p.z, p.y);
        float zig = (abs(fract(ang * 0.4775 * GF.w + sd) * 2.0 - 1.0) - 0.4) * h.z * 3.4;
        d = max(d, dot(p - vec3(L * 0.93, 0.0, 0.0), GN1) - zig);
        float cav = max(length(p.yz) - h.z * 0.55, (L - h.z * 3.0) - p.x);
        d = max(d, -cav);
        d += (Noise3(p * (1.6 / h.y) + sd) - 0.5) * h.y * 0.1;
    } else if (ty < 2.5) {
        // Kidney: a bean, a sphere taken out of its side, the ureter coming out of the notch.
        d = SdEllipsoid(p, h);
        d = SMax(d, -(length(p - vec3(0.12 * h.x, 0.0, h.z * 1.08)) - h.z * 0.72), h.z * 0.28);
        d = SMin(d, SdCapsule(p, vec3(0.1 * h.x, 0.0, h.z * 0.5), vec3(0.28 * h.x, -0.15 * h.y, h.z * 1.7), h.z * 0.14), h.z * 0.18);
        d += (Noise3(p * (1.2 / mn) + sd) - 0.5) * mn * 0.12;
    } else if (ty < 3.5) {
        // Liver lobe: a flat wedge, thinner towards +x, bent, with a second small lobe and a cleft.
        vec3 q = p;
        q.x += 0.3 * h.x * sin(p.z / h.z * 1.3 + sd);
        float thick = h.y * (1.0 - 0.5 * clamp(p.x / h.x, -1.0, 1.0));
        d = SdEllipsoid(q, vec3(h.x, thick, h.z));
        float d2 = SdEllipsoid(p - vec3(-0.45 * h.x, 0.0, 0.55 * h.z), vec3(0.55 * h.x, h.y * 0.9, 0.5 * h.z));
        d = SMin(d, d2, h.y * 0.5);
        d = SMax(d, -(length(vec2(p.x - 0.1 * h.x, p.y - h.y)) - h.y * 0.6) , h.y * 0.3);
        d += (Noise3(p * (1.0 / mn) + sd) - 0.5) * mn * 0.14;
    } else if (ty < 4.5) {
        // Heart: an ellipsoid tapering to an apex at -y, two vessel stubs and grooves.
        float s = mix(0.4, 1.0, clamp(p.y / h.y * 0.5 + 0.55, 0.0, 1.0));
        d = SdEllipsoid(vec3(p.x / s, p.y, p.z / s), h) * min(s, 1.0);
        d = SMin(d, SdCapsule(p, vec3(0.25 * h.x, 0.7 * h.y, 0.0), vec3(0.4 * h.x, 1.45 * h.y, 0.15 * h.z), h.x * 0.24), h.x * 0.2);
        d = SMin(d, SdCapsule(p, vec3(-0.3 * h.x, 0.7 * h.y, 0.1 * h.z), vec3(-0.5 * h.x, 1.3 * h.y, -0.2 * h.z), h.x * 0.17), h.x * 0.2);
        d += 0.045 * h.x * sin(p.y * 5.0 / h.y + p.x * 2.5 / h.x + sd) + (Noise3(p * (1.4 / mn) + sd) - 0.5) * mn * 0.1;
    } else {
        // Eye: the globe, the bulge of the cornea and a stump of nerve.
        d = length(p) - h.x;
        d = SMin(d, length(p - vec3(h.x * 0.5, 0.0, 0.0)) - h.x * 0.58, h.x * 0.25);
        d = SMin(d, SdCapsule(p, vec3(-h.x * 0.8, 0.0, 0.0), vec3(-h.x * 1.7, h.x * 0.25, h.x * 0.1), h.x * 0.24), h.x * 0.25);
    }
    return d * 0.72;
}

// The distance to the gib of the current slot, in world space.
float Map(vec3 pw) {
    return Shape((pw - GC) * GM);
}

// Half extents of a box (in the gib's frame) that holds the whole of it, what sticks out of a plain rounded box included (a bone's
// knob, a kidney's ureter, a heart's vessels, an eye's nerve).
vec3 BoxExt() {
    vec3 h = GH.xyz;
    float ty = GH.w;
    if (ty < 0.5) return h * 1.15 + 0.6;
    if (ty < 1.5) return vec3(h.x + 1.5 * h.y + 0.5, h.y * 1.5 + 0.5, h.y * 1.5 + 0.5);
    if (ty < 2.5) return vec3(h.x * 1.1 + 0.5, h.y * 1.1 + 0.5, h.z * 1.9 + 0.5);
    if (ty < 3.5) return h * 1.15 + 0.5;
    if (ty < 4.5) return vec3(h.x * 1.3 + 0.5, h.y * 1.75 + 0.5, h.z * 1.2 + 0.5);
    return vec3(h.x * 1.8 + 0.5, h.x * 1.2 + 0.3, h.x * 1.2 + 0.3);
}

// A cheap stand-in for the gib, an ellipsoid of its extents: what darkens and stains the ground around it is judged against this, so
// that the pixels of a bounding sphere that miss the gib do not pay for the real field.
float Proxy(vec3 pw) {
    return SdEllipsoid((pw - GC) * GM, GH.xyz * (GH.w < 1.5 && GH.w > 0.5 ? vec3(1.0, 1.3, 1.3) : vec3(0.9)));
}

// Copies slot sel's four vec4 out of the uniforms and builds the frame.
void Load(float sel) {
    vec4 A = vec4(0.0);
    vec4 B = vec4(0.0, 0.0, 0.0, 1.0);
    if (sel < 0.5) {
        A = p_g0a; B = p_g0b; GH = p_g0c; GD = p_g0d;
    } else if (sel < 1.5) {
        A = p_g1a; B = p_g1b; GH = p_g1c; GD = p_g1d;
    } else if (sel < 2.5) {
        A = p_g2a; B = p_g2b; GH = p_g2c; GD = p_g2d;
    } else if (sel < 3.5) {
        A = p_g3a; B = p_g3b; GH = p_g3c; GD = p_g3d;
    } else if (sel < 4.5) {
        A = p_g4a; B = p_g4b; GH = p_g4c; GD = p_g4d;
    } else if (sel < 5.5) {
        A = p_g5a; B = p_g5b; GH = p_g5c; GD = p_g5d;
    } else if (sel < 6.5) {
        A = p_g6a; B = p_g6b; GH = p_g6c; GD = p_g6d;
    } else if (sel < 7.5) {
        A = p_g7a; B = p_g7b; GH = p_g7c; GD = p_g7d;
    } else if (sel < 8.5) {
        A = p_g8a; B = p_g8b; GH = p_g8c; GD = p_g8d;
    } else if (sel < 9.5) {
        A = p_g9a; B = p_g9b; GH = p_g9c; GD = p_g9d;
    } else if (sel < 10.5) {
        A = p_g10a; B = p_g10b; GH = p_g10c; GD = p_g10d;
    } else if (sel < 11.5) {
        A = p_g11a; B = p_g11b; GH = p_g11c; GD = p_g11d;
    } else if (sel < 12.5) {
        A = p_g12a; B = p_g12b; GH = p_g12c; GD = p_g12d;
    } else if (sel < 13.5) {
        A = p_g13a; B = p_g13b; GH = p_g13c; GD = p_g13d;
    } else if (sel < 14.5) {
        A = p_g14a; B = p_g14b; GH = p_g14c; GD = p_g14d;
    } else {
        A = p_g15a; B = p_g15b; GH = p_g15c; GD = p_g15d;
    }
    GC = A.xyz;
    GB = A.w;
    GM = QuatMat(B);
    // What Shape needs of the seed, once here and not at every step of the march.
    float sd = GD.x;
    GN1 = CutN(sd, 0.0);
    GN2 = CutN(sd, 1.0);
    GF = vec4(Hash3(vec3(sd, 3.0, 7.0)) > 0.3 ? 1.0 : 0.0, Hash3(vec3(sd, 8.0, 1.0)) > 0.35 ? 1.0 : 0.0,
              Hash3(vec3(sd, 11.0, 2.0)) > 0.45 ? 1.0 : 0.0, 2.0 + floor(Hash3(vec3(sd, 5.0, 1.0)) * 3.0));
    if (GH.w > 0.5 && GH.w < 1.5) GN1 = normalize(vec3(1.0, 0.8 * sin(sd * 3.1), 0.8 * cos(sd * 5.7)));
}

// Tests the view ray against slot k's bounding sphere and keeps the three spheres that are entered first, each as
// (where the ray enters, where it leaves, the slot): f is the first, g the second and h the third. Where spheres overlap the ray
// may reach any of them, so main() looks into all three.
void Bound(vec4 s, float k, vec3 ro, vec3 rd, inout vec3 f, inout vec3 g, inout vec3 e) {
    if (s.w <= 0.0) return;
    vec3 oc = ro - s.xyz;
    float b = dot(oc, rd);
    float q = b * b - (dot(oc, oc) - s.w * s.w);
    if (q < 0.0) return;
    q = sqrt(q);
    float t0 = -b - q;
    float t1 = -b + q;
    if (t1 < 0.0) return;
    if (t0 < f.x) {
        e = g;
        g = f;
        f = vec3(t0, t1, k);
    } else if (t0 < g.x) {
        e = g;
        g = vec3(t0, t1, k);
    } else if (t0 < e.x) {
        e = vec3(t0, t1, k);
    }
}

void main() {
    vec4 scene = texture2D(mg_scene, mg_uv);
    gl_FragColor = scene;
    if (p_strength <= 0.0 || p_count < 0.5) return;

    // The view ray in world space.
    vec4 pf = mg_invProj * vec4(mg_uv * 2.0 - 1.0, 0.0, 1.0);
    vec3 dirW = normalize(pf.xyz / pf.w) * mat3(mg_view);
    vec3 camW = -(mg_view[3].xyz * mat3(mg_view));

    // The two bounding spheres the ray enters first. Most pixels meet none, and leave here, before the depth is read.
    float tScene = 1e5;
    vec3 sph0 = vec3(1e5, 0.0, -1.0);
    vec3 sph1 = vec3(1e5, 0.0, -1.0);
    vec3 sph2 = vec3(1e5, 0.0, -1.0);
    if (p_count > 0.5) Bound(p_g0a, 0.0, camW, dirW, sph0, sph1, sph2);
    if (p_count > 1.5) Bound(p_g1a, 1.0, camW, dirW, sph0, sph1, sph2);
    if (p_count > 2.5) Bound(p_g2a, 2.0, camW, dirW, sph0, sph1, sph2);
    if (p_count > 3.5) Bound(p_g3a, 3.0, camW, dirW, sph0, sph1, sph2);
    if (p_count > 4.5) Bound(p_g4a, 4.0, camW, dirW, sph0, sph1, sph2);
    if (p_count > 5.5) Bound(p_g5a, 5.0, camW, dirW, sph0, sph1, sph2);
    if (p_count > 6.5) Bound(p_g6a, 6.0, camW, dirW, sph0, sph1, sph2);
    if (p_count > 7.5) Bound(p_g7a, 7.0, camW, dirW, sph0, sph1, sph2);
    if (p_count > 8.5) Bound(p_g8a, 8.0, camW, dirW, sph0, sph1, sph2);
    if (p_count > 9.5) Bound(p_g9a, 9.0, camW, dirW, sph0, sph1, sph2);
    if (p_count > 10.5) Bound(p_g10a, 10.0, camW, dirW, sph0, sph1, sph2);
    if (p_count > 11.5) Bound(p_g11a, 11.0, camW, dirW, sph0, sph1, sph2);
    if (p_count > 12.5) Bound(p_g12a, 12.0, camW, dirW, sph0, sph1, sph2);
    if (p_count > 13.5) Bound(p_g13a, 13.0, camW, dirW, sph0, sph1, sph2);
    if (p_count > 14.5) Bound(p_g14a, 14.0, camW, dirW, sph0, sph1, sph2);
    if (p_count > 15.5) Bound(p_g15a, 15.0, camW, dirW, sph0, sph1, sph2);
    if (sph0.z < 0.0) return;
    float depth = texture2D(mg_depth, mg_uv).r;
    if (depth < 1.0) {
        vec4 vp = mg_invProj * vec4(vec3(mg_uv, depth) * 2.0 - 1.0, 1.0);
        tScene = length(vp.xyz / vp.w);
    }
    // (a sphere that begins behind what the scene shows is of no use, and the spheres are in the order they begin in)
    if (sph0.x > tScene + 1.0) return;
    if (sph1.x > tScene + 1.0) sph1.z = -1.0;
    if (sph2.x > tScene + 1.0) sph2.z = -1.0;

    // Up to three slots are looked into, the first sphere the ray enters and the next two (only where spheres overlap), by
    // the same code in a loop, so the long code is expanded once. The nearer gib wins.
    float pix = 2.0 / (mg_proj[1][1] * mg_resolution.y);
    float bSel = -1.0;      // the slot of the best candidate so far, and what it found
    float bCover = 0.0;
    float bT = 0.0;
    float bD = 1e5;
    float loaded = -1.0;    // the slot whose gib is in the globals
    // What a gib does to the ground next to it, kept over the (up to three) gibs the ray looks into: how much it darkens it and
    // how much blood it smears there.
    vec3 Pw = camW + dirW * tScene;
    vec3 tint = p_blood / max(max(p_blood.r, p_blood.g), max(p_blood.b, 1e-3));
    vec3 Lk = normalize(vec3(0.35, 0.85, 0.25));
    float darkAcc = 0.0;
    float smearAcc = 0.0;
    for (int pass = 0; pass < 3; pass++) {
        vec3 sph = pass == 0 ? sph0 : (pass == 1 ? sph1 : sph2);
        if (sph.z < 0.0) break;
        Load(sph.z);
        loaded = sph.z;
        float fade = depth < 1.0 ? 1.0 - smoothstep(GB - 3.2, GB - 0.4, length(Pw - GC)) : 0.0;
        if (fade > 0.01) {
            float dg = Proxy(Pw + Lk * 0.8);
            float contact = exp(-max(dg, 0.0) * 0.9);
            float castSh = 1.0 - smoothstep(0.0, 2.4, Proxy(Pw + Lk * 2.4));
            float dk = fade * (0.45 * contact + 0.27 * castSh * (1.0 - contact));
            darkAcc = 1.0 - (1.0 - darkAcc) * (1.0 - dk);
            smearAcc = max(smearAcc, (1.0 - smoothstep(0.1, 1.2, dg)) * GD.w * fade * (0.5 + 0.5 * (1.0 - Dry())));
        }
        // March from where the ray enters the sphere. A step is 0.85 of the distance (the field is not exact), and a hit is
        // within a third of a pixel; a ray that gets within a pixel of a gib without touching it keeps that closest point
        // for the soft edge.
        // (only a ray that meets a box that holds the gib is marched, from where it enters it to where it leaves: the bounding
        // sphere is wider by what the contact shadow needs and round, which most of the pixels in it do not need.)
        vec3 bo = (camW - GC) * GM;
        vec3 bd = dirW * GM;
        vec3 bx = BoxExt();
        vec3 bi = 1.0 / (abs(bd) + 1e-6) * sign(bd + 1e-9);
        vec3 b1 = -bi * bo - abs(bi) * bx;
        vec3 b2 = -bi * bo + abs(bi) * bx;
        float tN = max(max(b1.x, b1.y), max(b1.z, 0.0));
        float tF = min(min(b2.x, b2.y), b2.z);
        float t = tN;
        float tEnd = tF > tN ? min(tF, tScene + 0.5) : -1.0;
        float tBest = t;
        float dBest = 1e5;
        float hit = 0.0;
        for (int i = 0; i < 26; i++) {
            if (t > tEnd) break;
            float d = Map(camW + dirW * t);
            if (d < dBest) {
                dBest = d;
                tBest = t;
            }
            if (d < 0.33 * pix * t + 0.004) {
                hit = 1.0;
                break;
            }
            t += d * 0.85;
            if (t > tEnd) break;
        }
        float cov = hit;
        if (hit < 0.5) cov = 1.0 - smoothstep(0.0, pix * tBest + 1e-4, dBest);
        if (tBest > tScene + 0.4) cov = 0.0;
        if (bSel < 0.0 || (cov > 0.0 && (bCover <= 0.0 || tBest < bT)) || (cov <= 0.0 && bCover <= 0.0 && dBest < bD)) {
            bSel = sph.z;
            bCover = cov;
            bT = tBest;
            bD = dBest;
        }
    }
    if (bSel < 0.0) return;
    if (loaded != bSel) Load(bSel);
    float tBest = bT;
    float cover = bCover;

    vec3 lumW = vec3(0.299, 0.587, 0.114);
    float seed = GD.x;
    float dry = Dry();
    float wet = clamp(GD.z, 0.0, 1.0) * (1.0 - dry);

    // Not covered: the gib still darkens the ground it lies on, casts a soft shadow away from the light and stains it.
    vec3 base = scene.rgb * (1.0 - darkAcc);
    base = mix(base, base * tint * 0.55, 0.45 * smearAcc);
    if (cover <= 0.0) {
        gl_FragColor = vec4(mix(scene.rgb, base, p_strength), scene.a);
        return;
    }

    // ---- shading -----------------------------------------------------------------------------------------------
    vec3 p = camW + dirW * tBest;
    vec3 V = -dirW;
    float ty = GH.w;
    vec3 h = GH.xyz;
    float mn = min(h.x, min(h.y, h.z));

    // The normal from four taps of the field, then a fine bump from noise on the surface only.
    vec3 n = vec3(0.0);
    for (int k = 0; k < 4; k++) {
        vec3 e = vec3((k == 0 || k == 3) ? 1.0 : -1.0, (k == 2 || k == 3) ? 1.0 : -1.0, (k == 1 || k == 3) ? 1.0 : -1.0);
        n += e * Map(p + e * 0.02);
    }
    float nlen = length(n);
    n = nlen > 1e-8 ? n / nlen : vec3(0.0, 1.0, 0.0);
    vec3 pl = (p - GC) * GM;
    // How much detail is worth drawing: a gib that is only a few pixels across has no use for a bump, an occlusion or a shadow of
    // its own (0 under 6 pixels across its thinnest, 1 over 14).
    float detail = clamp((mn / (pix * tBest) - 3.0) / 4.0, 0.0, 1.0);
    if (detail > 0.0) {
        float bk = ty < 1.5 ? 3.0 / h.y : 2.6 / mn;
        vec3 q = pl * bk + seed;
        float b0 = Noise3(q);
        vec3 g = vec3(Noise3(q + vec3(0.4, 0.0, 0.0)), Noise3(q + vec3(0.0, 0.4, 0.0)), Noise3(q + vec3(0.0, 0.0, 0.4))) - b0;
        float bump = (ty < 0.5 ? 0.9 : (ty < 1.5 ? 0.5 : 0.28)) * detail;
        vec3 gw = GM * g;          // the bump is made in the local frame and turned into the world's
        n = normalize(n + bump * (gw - dot(gw, n) * n));
    }
    float nv = clamp(dot(n, V), 0.0, 1.0);

    // Ambient occlusion from the field along the normal, darker underneath (where it lies on the ground).
    float ao = 1.0;
    // The key light's shadow on the gib itself: a short march.
    float shade = 1.0;
    if (detail > 0.0) {
        float hk = 0.35 + 0.1 * mn;
        ao = mix(1.0, clamp(1.0 - 1.1 * (hk - Map(p + n * hk)) / max(mn * 0.5, 0.5), 0.0, 1.0), detail);
        float st = 0.2;
        for (int k = 0; k < 2; k++) {
            float hs = Map(p + n * 0.05 + Lk * st);
            shade = min(shade, 6.0 * hs / st);
            st += clamp(hs, 0.3, 1.4);
        }
        shade = mix(1.0, clamp(shade, 0.0, 1.0), detail);
    }
    ao *= mix(0.45, 1.0, clamp(n.y * 0.5 + 0.6, 0.0, 1.0));

    // ---- material: the colour, the gloss and how much light goes through, by kind ---------------------------------------
    vec3 albedo = vec3(0.5, 0.1, 0.1);
    float gloss = 0.8;
    float sssK = 1.0;
    float fine = Noise3(pl * (7.0 / mn) + seed * 2.0);
    float mott = Noise3(pl * (1.1 / mn) + seed * 3.1);
    if (ty < 0.5) {
        // Muscle: dark red with lighter streaks along the fibres (x), fat marbling, silverskin and pale, fibrous tear faces.
        float fib = Noise3(vec3(pl.x * 0.3, pl.y * 4.5, pl.z * 4.5) / mn + seed);
        albedo = mix(vec3(0.2, 0.014, 0.022), vec3(0.5, 0.055, 0.05), clamp(0.15 + 0.75 * fib + 0.5 * (mott - 0.5), 0.0, 1.0));
        float marb = smoothstep(0.66, 0.78, Noise3(vec3(pl.x * 0.5, pl.y * 2.2, pl.z * 2.2) / mn * 1.7 + seed * 3.0));
        albedo = mix(albedo, vec3(0.93, 0.80, 0.58), marb * 0.85);
        float sil = smoothstep(0.64, 0.8, Noise3(pl * (0.8 / mn) + seed * 5.0));
        albedo = mix(albedo, vec3(0.86, 0.64, 0.6), sil * 0.6);
        float tear = GF.x > 0.5 ? 1.0 - smoothstep(0.0, 0.3 * mn, abs(dot(pl, GN1) - 0.58 * dot(abs(GN1), h))) : 0.0;
        tear = max(tear, GF.y > 0.5 ? 1.0 - smoothstep(0.0, 0.3 * mn, abs(dot(pl, GN2) - 0.72 * dot(abs(GN2), h))) : 0.0);
        float strand = Noise3(vec3(pl.x * 0.12, pl.y * 9.0, pl.z * 9.0) / mn + seed * 7.0);
        albedo = mix(albedo, mix(vec3(0.55, 0.11, 0.1), vec3(0.88, 0.38, 0.32), strand), tear * 0.75);
        albedo *= 0.9 + 0.2 * fine;
        albedo = mix(albedo, tint * dot(albedo, lumW) * 1.8, 0.2);
        gloss = 0.7;
        sssK = 0.7;
    } else if (ty < 1.5) {
        // Bone: ivory, stained, porous and marrow red at the break, pale where the knob is.
        float L = h.x;
        albedo = mix(vec3(0.93, 0.89, 0.76), vec3(0.80, 0.72, 0.56), mott);
        albedo *= 0.92 + 0.16 * fine;
        float endAmt = smoothstep(L * 0.7, L * 0.97, pl.x);
        float pore = smoothstep(0.35, 0.6, Noise3(pl * (5.0 / h.z) + seed));
        vec3 spongy = mix(vec3(0.95, 0.82, 0.7), vec3(0.42, 0.14, 0.12), pore);
        albedo = mix(albedo, spongy, endAmt);
        float cavity = 1.0 - smoothstep(0.35, 0.55, length(pl.yz) / h.z);
        albedo = mix(albedo, vec3(0.5, 0.06, 0.06), endAmt * cavity * 0.8);
        albedo = mix(albedo, p_blood * 1.3, 0.55 * GD.w * smoothstep(0.35, 0.8, Noise3(pl * (1.0 / h.y) + seed * 4.0)));
        gloss = 0.4;
        sssK = 0.25;
    } else if (ty < 2.5) {
        // Kidney: smooth red-brown with a fatty cream at the notch and a pale ureter.
        albedo = mix(vec3(0.32, 0.07, 0.07), vec3(0.52, 0.13, 0.11), mott);
        float notch = smoothstep(0.3, 1.0, pl.z / h.z);
        float fat = smoothstep(0.4, 0.7, Noise3(pl * (2.0 / mn) + seed)) * notch;
        albedo = mix(albedo, vec3(0.9, 0.75, 0.5), fat * 0.8);
        albedo = mix(albedo, vec3(0.8, 0.55, 0.52), smoothstep(1.15, 1.6, pl.z / h.z));
        albedo = mix(albedo, tint * dot(albedo, lumW) * 1.8, 0.2);
        gloss = 1.0;
        sssK = 1.0;
    } else if (ty < 3.5) {
        // Liver: dark, smooth, brown-red, with a faint lobular mottling.
        albedo = mix(vec3(0.27, 0.055, 0.05), vec3(0.44, 0.10, 0.07), mott);
        albedo *= 0.9 + 0.2 * fine;
        albedo = mix(albedo, tint * dot(albedo, lumW) * 1.8, 0.2);
        gloss = 1.0;
        sssK = 0.9;
    } else if (ty < 4.5) {
        // Heart: red muscle, yellow fat over the top and a bluish-pale vessel at the stubs.
        albedo = mix(vec3(0.46, 0.07, 0.08), vec3(0.64, 0.14, 0.12), mott);
        float topY = pl.y / h.y;
        float fat = smoothstep(0.1, 0.9, topY) * smoothstep(0.3, 0.65, Noise3(pl * (2.2 / mn) + seed));
        albedo = mix(albedo, vec3(0.93, 0.8, 0.52), fat * 0.85);
        albedo = mix(albedo, vec3(0.62, 0.42, 0.5), smoothstep(1.0, 1.25, topY) * 0.9);
        albedo = mix(albedo, tint * dot(albedo, lumW) * 1.8, 0.2);
        gloss = 0.95;
        sssK = 1.1;
    } else {
        // Eye: bloodshot white, an iris and a black pupil on the +x side, pink at the nerve.
        float r = length(pl.yz) / h.x;
        float front = pl.x / h.x;
        albedo = vec3(0.93, 0.89, 0.84);
        float vein = 1.0 - smoothstep(0.0, 0.08, abs(Noise3(pl * (3.2 / h.x) + seed) - 0.5));
        albedo = mix(albedo, vec3(0.75, 0.12, 0.12), vein * 0.7 * (0.4 + 0.6 * (1.0 - front)));
        float hs = Hash3(vec3(seed, 9.0, 4.0));
        vec3 iris = hs < 0.4 ? vec3(0.2, 0.45, 0.8) : (hs < 0.7 ? vec3(0.25, 0.6, 0.3) : vec3(0.45, 0.25, 0.08));
        float irisM = (1.0 - smoothstep(0.4, 0.46, r)) * smoothstep(0.5, 0.65, front);
        iris *= 0.7 + 0.6 * Noise3(vec3(atan(pl.z, pl.y) * 3.0, r * 9.0, seed));
        albedo = mix(albedo, iris, irisM);
        albedo = mix(albedo, vec3(0.01), (1.0 - smoothstep(0.16, 0.19, r)) * smoothstep(0.55, 0.7, front));
        albedo = mix(albedo, vec3(0.7, 0.3, 0.3), smoothstep(-0.65, -1.0, front) * 0.9);
        albedo = mix(albedo, p_blood * 1.2, 0.5 * GD.w * smoothstep(0.55, 0.85, Noise3(pl * (1.0 / h.x) + seed * 2.0)) * (1.0 - 0.8 * irisM));
        gloss = 1.0;
        sssK = 0.6;
    }
    // A film of blood on everything that is wet, thicker in the low spots.
    float film = smoothstep(0.62, 0.92, Noise3(p * 0.8 + seed * 5.0) + 0.3 * (1.0 - n.y) + 0.3 * GD.w) * wet;
    albedo = mix(albedo, p_blood * 1.1, 0.55 * film);
    // Drying: darker and browner, then dull.
    albedo = mix(albedo, albedo * vec3(0.52, 0.42, 0.38) + vec3(0.02, 0.01, 0.005), dry * 0.85);
    gloss *= 0.18 + 0.82 * wet + 0.35 * film;

    // Scene light around the pixel: the same for the whole gib, so it dims in shadow and warms in sun.
    vec2 px = mg_resolution.zw * 7.0;
    vec3 around = (texture2D(mg_scene, mg_uv + vec2(px.x, 0.0)).rgb + texture2D(mg_scene, mg_uv - vec2(px.x, 0.0)).rgb
                 + texture2D(mg_scene, mg_uv + vec2(0.0, px.y)).rgb + texture2D(mg_scene, mg_uv - vec2(0.0, px.y)).rgb) * 0.25;
    float expo = clamp(0.55 + 1.0 * dot(around, lumW), 0.5, 1.35);

    // The fill comes from the side of the camera, a little above it.
    vec3 Lf = normalize(vec3(-0.55, 0.25, 0.8) * mat3(mg_view));
    float ndl = dot(n, Lk);
    float wrap = clamp((ndl + 0.45) / 1.45, 0.0, 1.0);
    vec3 keyCol = vec3(1.0, 0.95, 0.88) * 1.1;
    vec3 fillCol = vec3(0.45, 0.5, 0.62) * 0.5;
    vec3 sssCol = vec3(1.0, 0.22, 0.12);
    float dfill = clamp(dot(n, Lf) * 0.5 + 0.5, 0.0, 1.0);
    vec3 col = albedo * (keyCol * wrap * wrap * shade + fillCol * dfill * ao + around * 0.9 * ao) * expo;
    // Light through the thin flesh: red at the terminator on the lit side, and glowing at the edge against the light.
    float sss = clamp(1.0 - abs(ndl) * 1.7, 0.0, 1.0) * clamp(ndl + 0.6, 0.0, 1.0);
    float back = pow(clamp(dot(V, -Lk), 0.0, 1.0), 2.0) * (0.3 + 0.7 * (1.0 - nv));
    col += albedo * sssCol * (0.3 * sss * (0.4 + 0.6 * shade) + 0.25 * back * shade) * sssK * (1.0 - 0.6 * dry) * expo * (0.5 + 0.5 * ao);

    // Wet: a tight glint and a broader sheen from the key, a small glint from the fill, fresnel reflection of a dull sky and
    // a rim. The cornea of the eye is glassier still.
    float gl = clamp(gloss * (0.7 + 0.5 * Noise3(p * 0.45 + seed)), 0.0, 1.2);
    vec3 H = normalize(Lk + V);
    float nh = max(dot(n, H), 0.0);
    float fres = pow(1.0 - nv, 5.0);
    float spec = pow(nh, 220.0) * 2.4 + pow(nh, 38.0) * 0.3;
    vec3 H2 = normalize(Lf + V);
    float spec2 = pow(max(dot(n, H2), 0.0), 90.0) * 0.5;
    col += keyCol * spec * gl * (0.4 + 0.6 * fres) * shade * (0.5 + 0.5 * ao);
    col += fillCol * 2.0 * spec2 * gl * ao;
    vec3 R = reflect(-V, n);
    vec3 sky = mix(vec3(0.16, 0.14, 0.15), vec3(0.72, 0.8, 0.95), clamp(R.y * 0.5 + 0.5, 0.0, 1.0));
    col += sky * (0.05 + 0.5 * fres) * gl * ao * expo;
    col += pow(1.0 - nv, 3.0) * 0.2 * vec3(0.95, 0.42, 0.42) * gl * (0.4 + 0.6 * shade) * expo;

    vec3 outc = mix(base, col, cover);
    gl_FragColor = vec4(mix(scene.rgb, outc, p_strength), scene.a);
}
