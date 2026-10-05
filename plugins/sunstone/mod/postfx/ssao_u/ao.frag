#version 120
// Horizon-based ambient occlusion (R) and sun contact shadows (G) at reduced resolution. R is the AO multiplier,
// G is 1 minus the contact occlusion (tint and strength are applied in apply.frag).
uniform sampler2D mg_depth;
uniform mat4 mg_proj;
uniform mat4 mg_invProj;
uniform mat4 mg_view;
uniform vec4 mg_resolution;
uniform vec2 mg_nearFar;
uniform float p_radius;
uniform float p_intensity;
uniform float p_bias;
uniform float p_maxDistance;
uniform float p_nearFade;
uniform int p_slices;
uniform int p_steps;
uniform vec3 p_sunDir;
uniform float p_sunAmount;
uniform float p_contactStrength;
uniform float p_contactLength;
uniform float p_contactThickness;
uniform int p_contactSteps;
varying vec2 mg_uv;

const int kMaxSlices = 4;
const int kMaxSteps = 8;
const int kMaxContactSteps = 16;
const float kPi = 3.14159265;
const float kHalfPi = 1.57079633;

vec3 ViewPos(vec2 uv) {
    float d = texture2D(mg_depth, uv).r;
    vec4 p = mg_invProj * vec4(vec3(uv, d) * 2.0 - 1.0, 1.0);
    return p.xyz / p.w;
}

bool Sky(vec3 p) { return -p.z > 0.45 * mg_nearFar.y; }

bool OnScreen(vec2 uv) { return all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0))); }

float Ign(vec2 xy) { return fract(52.9829189 * fract(dot(xy, vec2(0.06711056, 0.00583715)))); }

// Cosine of the highest horizon found along one side, relaxed toward lowCos as the sample leaves the radius.
float Horizon(vec3 P, vec3 V, vec2 uv, float lowCos, float rad, float hc) {
    if (!OnScreen(uv)) return hc;
    vec3 d = ViewPos(uv) - P;
    float len = length(d);
    float c = dot(d, V) / max(len, 1e-4) - p_bias;
    return max(hc, mix(c, lowCos, smoothstep(0.6 * rad, rad, len)));
}

void main() {
    vec3 P = ViewPos(mg_uv);
    float dist = -P.z;
    // Close to the camera the depth-derived normals are too coarse for a full radius: the radius shrinks to what
    // fits on screen and the term fades out, so steep sand under a low camera does not smear dark.
    float fade = (1.0 - smoothstep(p_maxDistance * 0.6, p_maxDistance, dist)) * smoothstep(p_nearFade * 0.4, p_nearFade, dist);
    if (Sky(P) || fade <= 0.0) {
        gl_FragColor = vec4(1.0);
        return;
    }

    // Normal from the neighbour with the smaller depth step on each axis, so silhouettes don't bend it.
    vec2 px = mg_resolution.zw;
    vec3 r = ViewPos(mg_uv + vec2(px.x, 0.0)) - P, l = P - ViewPos(mg_uv - vec2(px.x, 0.0));
    vec3 u = ViewPos(mg_uv + vec2(0.0, px.y)) - P, dn = P - ViewPos(mg_uv - vec2(0.0, px.y));
    vec3 hx = abs(r.z) < abs(l.z) ? r : l;
    vec3 hy = abs(u.z) < abs(dn.z) ? u : dn;
    vec3 N = normalize(cross(hx, hy));
    if (dot(N, P) > 0.0) N = -N;
    vec3 V = normalize(-P);

    float noise = Ign(gl_FragCoord.xy);
    float jitter = Ign(gl_FragCoord.xy + vec2(37.0, 17.0));

    // View-space radius projected to uv per axis.
    float rad = min(p_radius, 0.24 * dist / max(mg_proj[0][0], mg_proj[1][1]));
    vec2 ruv = rad * 0.5 * vec2(mg_proj[0][0], mg_proj[1][1]) / dist;
    int slices = p_slices < 1 ? 1 : p_slices > kMaxSlices ? kMaxSlices : p_slices;
    int steps = p_steps < 1 ? 1 : p_steps > kMaxSteps ? kMaxSteps : p_steps;

    float vis = 0.0;
    for (int s = 0; s < kMaxSlices; ++s) {
        if (s >= slices) break;
        float phi = (float(s) + noise) * kPi / float(slices);
        vec2 om = vec2(cos(phi), sin(phi));
        vec3 dirV = vec3(om, 0.0);
        vec3 ortho = dirV - dot(dirV, V) * V;
        vec3 axis = normalize(cross(dirV, V));
        vec3 pn = N - axis * dot(N, axis);
        float pl = length(pn);
        float n = sign(dot(ortho, pn)) * acos(clamp(dot(pn, V) / max(pl, 1e-4), -1.0, 1.0));
        // x: the +om side, y: the -om side.
        vec2 low = vec2(-sin(n), sin(n));
        vec2 hc = low;
        vec2 stepUv = om * ruv;
        float minT = 1.0 / max(length(stepUv * mg_resolution.xy), 1e-3);
        for (int j = 0; j < kMaxSteps; ++j) {
            if (j >= steps) break;
            float t = (float(j) + jitter) / float(steps);
            t = min(max(t * t, minT * float(j + 1)), 1.0);
            vec2 o = stepUv * t;
            hc.x = Horizon(P, V, mg_uv + o, low.x, rad, hc.x);
            hc.y = Horizon(P, V, mg_uv - o, low.y, rad, hc.y);
        }
        float h0 = n + clamp(-acos(clamp(hc.y, -1.0, 1.0)) - n, -kHalfPi, kHalfPi);
        float h1 = n + clamp(acos(clamp(hc.x, -1.0, 1.0)) - n, -kHalfPi, kHalfPi);
        vis += pl * (2.0 * cos(n) + 2.0 * (h0 + h1) * sin(n) - cos(2.0 * h0 - n) - cos(2.0 * h1 - n)) * 0.25;
    }
    vis = clamp(vis / float(slices), 1e-3, 1.0);
    float ao = mix(1.0, pow(vis, p_intensity), fade);

    float contact = 1.0;
    if (p_sunAmount * p_contactStrength > 0.0) {
        vec3 L = normalize(mat3(mg_view) * p_sunDir);
        float facing = smoothstep(-0.1, 0.2, dot(N, L));
        if (facing > 0.0) {
            int cs = p_contactSteps < 1 ? 1 : p_contactSteps > kMaxContactSteps ? kMaxContactSteps : p_contactSteps;
            float len = min(p_contactLength, 0.25 * dist);
            vec3 o = P + N * (0.004 * dist + 0.3);
            float occ = 0.0;
            for (int i = 0; i < kMaxContactSteps; ++i) {
                if (i >= cs) break;
                float t = (float(i) + jitter) / float(cs);
                vec3 q = o + L * (len * t);
                vec4 c = mg_proj * vec4(q, 1.0);
                if (c.w <= 0.0) break;
                vec2 uv = c.xy / c.w * 0.5 + 0.5;
                if (!OnScreen(uv)) break;
                // > 0: the scene is in front of the ray point.
                float dz = ViewPos(uv).z - q.z;
                float minDz = 0.02 * -q.z + 0.2;
                occ = max(occ, step(minDz, dz) * step(dz, minDz + p_contactThickness) * (1.0 - t * t));
            }
            contact = 1.0 - occ * facing * fade * clamp(p_sunAmount, 0.0, 1.0);
        }
    }
    gl_FragColor = vec4(ao, contact, 1.0, 1.0);
}
