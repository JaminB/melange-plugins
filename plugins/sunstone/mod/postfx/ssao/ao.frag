#version 120
uniform sampler2D mg_depth;
uniform mat4 mg_proj;
uniform mat4 mg_invProj;
uniform vec4 mg_resolution;
uniform float p_radius;
uniform float p_intensity;
uniform float p_bias;
uniform float p_maxDistance;
uniform int p_taps;
varying vec2 mg_uv;

const float kSkyDepth = 0.9999;
const int kMaxTaps = 16;

vec3 ViewPos(vec2 uv, float depth) {
    vec4 p = mg_invProj * vec4(vec3(uv, depth) * 2.0 - 1.0, 1.0);
    return p.xyz / p.w;
}

void main() {
    float depth = texture2D(mg_depth, mg_uv).r;
    if (depth >= kSkyDepth) {
        gl_FragColor = vec4(1.0);
        return;
    }

    vec3 P = ViewPos(mg_uv, depth);
    float dist = -P.z;
    float farFade = 1.0 - smoothstep(p_maxDistance * 0.7, p_maxDistance, dist);
    if (farFade <= 0.0) {
        gl_FragColor = vec4(1.0);
        return;
    }

    // Normals from depth: a forward/backward difference per axis, each dropped if it lands on the sky, so the
    // horizon silhouette never pollutes the estimate (the source of mirage-samples' sky chevrons).
    vec2 px = mg_resolution.zw;
    float dr = texture2D(mg_depth, mg_uv + vec2(px.x, 0.0)).r;
    float dl = texture2D(mg_depth, mg_uv - vec2(px.x, 0.0)).r;
    float du = texture2D(mg_depth, mg_uv + vec2(0.0, px.y)).r;
    float dd = texture2D(mg_depth, mg_uv - vec2(0.0, px.y)).r;
    bool okR = dr < kSkyDepth, okL = dl < kSkyDepth, okU = du < kSkyDepth, okD = dd < kSkyDepth;
    if (!(okR || okL) || !(okU || okD)) {
        gl_FragColor = vec4(1.0);
        return;
    }
    vec3 r = okR ? ViewPos(mg_uv + vec2(px.x, 0.0), dr) - P : vec3(0.0);
    vec3 l = okL ? P - ViewPos(mg_uv - vec2(px.x, 0.0), dl) : vec3(0.0);
    vec3 u = okU ? ViewPos(mg_uv + vec2(0.0, px.y), du) - P : vec3(0.0);
    vec3 d = okD ? P - ViewPos(mg_uv - vec2(0.0, px.y), dd) : vec3(0.0);
    vec3 hx = (okR && okL) ? (abs(r.z) < abs(l.z) ? r : l) : (okR ? r : l);
    vec3 hy = (okU && okD) ? (abs(u.z) < abs(d.z) ? u : d) : (okU ? u : d);
    vec3 N = normalize(cross(hx, hy));

    vec2 ruv = min(p_radius * 0.5 * vec2(mg_proj[0][0], mg_proj[1][1]) / max(dist, 1e-3), vec2(0.15));
    float noise = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))));
    float angle = noise * 6.2831853;
    float r2 = p_radius * p_radius;
    int taps = clamp(p_taps, 4, kMaxTaps);
    float occ = 0.0;
    for (int i = 0; i < taps; ++i) {
        float t = (float(i) + noise) / float(taps);
        float a = angle + float(i) * 2.3999632;
        vec2 suv = mg_uv + vec2(cos(a), sin(a)) * t * ruv;
        float sd = texture2D(mg_depth, suv).r;
        if (sd >= kSkyDepth) continue;
        vec3 v = ViewPos(suv, sd) - P;
        float vv = dot(v, v);
        float falloff = 1.0 - clamp(vv / r2, 0.0, 1.0);
        occ += max(0.0, dot(v, N) - p_bias * p_radius) / (vv + 0.01 * r2) * falloff;
    }
    float ao = clamp(1.0 - p_intensity * 2.0 * p_radius * occ / float(taps), 0.0, 1.0);
    ao = mix(1.0, ao, farFade);
    gl_FragColor = vec4(ao, ao, ao, 1.0);
}
