#version 120
uniform sampler2D mg_depth;
uniform mat4 mg_proj;
uniform mat4 mg_invProj;
uniform vec4 mg_resolution;
uniform vec2 mg_nearFar;
uniform float p_radius;
uniform float p_intensity;
uniform float p_bias;
uniform float p_maxDistance;
uniform int p_taps;
varying vec2 mg_uv;

const int kMaxTaps = 16;

vec3 ViewPos(vec2 uv) {
    float d = texture2D(mg_depth, uv).r;
    vec4 p = mg_invProj * vec4(vec3(uv, d) * 2.0 - 1.0, 1.0);
    return p.xyz / p.w;
}

bool Sky(vec3 p) { return -p.z > 0.45 * mg_nearFar.y; }

void main() {
    vec3 P = ViewPos(mg_uv);
    float dist = -P.z;
    float farFade = 1.0 - smoothstep(p_maxDistance * 0.6, p_maxDistance, dist);
    if (Sky(P) || farFade <= 0.0) {
        gl_FragColor = vec4(1.0);
        return;
    }

    // Normal from the neighbour with the smaller depth step on each axis, so silhouettes don't bend it.
    vec2 px = mg_resolution.zw;
    vec3 r = ViewPos(mg_uv + vec2(px.x, 0.0)) - P, l = P - ViewPos(mg_uv - vec2(px.x, 0.0));
    vec3 u = ViewPos(mg_uv + vec2(0.0, px.y)) - P, d = P - ViewPos(mg_uv - vec2(0.0, px.y));
    vec3 hx = abs(r.z) < abs(l.z) ? r : l;
    vec3 hy = abs(u.z) < abs(d.z) ? u : d;
    vec3 N = normalize(cross(hx, hy));
    if (dot(N, P) > 0.0) N = -N;

    vec2 ruv = p_radius * 0.5 * vec2(mg_proj[0][0], mg_proj[1][1]) / dist;
    ruv = min(ruv, vec2(0.12));
    float noise = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));
    int taps = p_taps < 4 ? 4 : p_taps > kMaxTaps ? kMaxTaps : p_taps;
    float r2 = p_radius * p_radius;
    float occ = 0.0;
    for (int i = 0; i < kMaxTaps; ++i) {
        if (i >= taps) break;
        float t = (float(i) + noise) / float(taps);
        float a = noise * 6.2831853 + float(i) * 2.3999632;
        vec2 suv = mg_uv + vec2(cos(a), sin(a)) * sqrt(t) * ruv;
        vec3 v = ViewPos(suv) - P;
        float vv = dot(v, v);
        float range = 1.0 - smoothstep(r2, 4.0 * r2, vv);
        occ += max(0.0, dot(v, N) * inversesqrt(vv + 1e-4) - p_bias) * range;
    }
    float ao = clamp(1.0 - p_intensity * 1.5 * occ / float(taps), 0.0, 1.0);
    gl_FragColor = vec4(vec3(mix(1.0, ao, farFade)), 1.0);
}
