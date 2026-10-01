#version 120
// 7-tap bilateral blur that stops at depth edges and never blends across the horizon; HORIZONTAL selects direction.
uniform sampler2D mg_prev;
uniform sampler2D mg_depth;
uniform mat4 mg_invProj;
uniform vec4 mg_resolution;
varying vec2 mg_uv;

const float kSkyDepth = 0.9999;

float ViewZ(float depth) {
    vec4 p = mg_invProj * vec4(0.0, 0.0, depth * 2.0 - 1.0, 1.0);
    return p.z / p.w;
}

void main() {
#ifdef HORIZONTAL
    vec2 dir = vec2(mg_resolution.z, 0.0);
#else
    vec2 dir = vec2(0.0, mg_resolution.w);
#endif
    float d0 = texture2D(mg_depth, mg_uv).r;
    if (d0 >= kSkyDepth) {
        gl_FragColor = vec4(1.0);
        return;
    }
    float z0 = ViewZ(d0);
    float sum = 0.0, wsum = 0.0;
    for (int i = -3; i <= 3; ++i) {
        vec2 uv = mg_uv + dir * float(i);
        float d = texture2D(mg_depth, uv).r;
        if (d >= kSkyDepth) continue;
        float z = ViewZ(d);
        float w = exp(-float(i * i) / 8.0) * exp(-abs(z - z0) * 8.0 / max(abs(z0), 1e-3));
        sum += texture2D(mg_prev, uv).r * w;
        wsum += w;
    }
    float ao = wsum > 1e-5 ? sum / wsum : texture2D(mg_prev, mg_uv).r;
    gl_FragColor = vec4(ao, ao, ao, 1.0);
}
