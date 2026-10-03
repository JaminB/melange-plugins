#version 120
// 7-tap bilateral blur that stops at depth edges and never blends sky into ground; HORIZONTAL selects direction.
uniform sampler2D mg_prev;
uniform sampler2D mg_depth;
uniform mat4 mg_invProj;
uniform vec4 mg_resolution;
uniform vec2 mg_renderScale;
uniform vec2 mg_nearFar;
varying vec2 mg_uv;

float ViewDist(vec2 uv) {
    float d = texture2D(mg_depth, uv).r;
    vec4 p = mg_invProj * vec4(0.0, 0.0, d * 2.0 - 1.0, 1.0);
    return -p.z / p.w;
}

void main() {
#ifdef HORIZONTAL
    vec2 dir = vec2(mg_resolution.z, 0.0);
#else
    vec2 dir = vec2(0.0, mg_resolution.w);
#endif
    dir *= max(mg_renderScale, vec2(1.0));
    float sky = 0.45 * mg_nearFar.y;
    float z0 = ViewDist(mg_uv);
    if (z0 > sky) {
        gl_FragColor = vec4(1.0);
        return;
    }
    float sum = 0.0, wsum = 0.0;
    for (int i = -3; i <= 3; ++i) {
        vec2 uv = mg_uv + dir * float(i);
        float z = ViewDist(uv);
        if (z > sky) continue;
        float w = exp(-float(i * i) / 8.0) * exp(-abs(z - z0) * 16.0 / z0);
        sum += texture2D(mg_prev, uv).r * w;
        wsum += w;
    }
    float ao = wsum > 1e-5 ? sum / wsum : texture2D(mg_prev, mg_uv).r;
    gl_FragColor = vec4(ao, ao, ao, 1.0);
}
