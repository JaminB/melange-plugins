#version 120
// One horizon colour per screen column: walks a few directions just above the horizon and averages the ones that
// land on the sky dome. Alpha is how many of them did.
uniform sampler2D mg_scene;
uniform sampler2D mg_depth;
uniform mat4 mg_proj;
uniform mat4 mg_invProj;
uniform mat4 mg_view;
uniform vec2 mg_nearFar;
varying vec2 mg_uv;

bool IsSky(vec2 uv) {
    float d = texture2D(mg_depth, uv).r;
    if (d >= 1.0) return true;
    vec4 p = mg_invProj * vec4(vec3(uv, d) * 2.0 - 1.0, 1.0);
    return length(p.xyz / p.w) > 0.5 * mg_nearFar.y;
}

void main() {
    vec4 vr = mg_invProj * vec4(mg_uv.x * 2.0 - 1.0, 0.0, 1.0, 1.0);
    vec3 w = normalize(vr.xyz / vr.w) * mat3(mg_view);
    vec2 hor = w.xz / max(length(w.xz), 1e-4);
    vec3 sum = vec3(0.0);
    float wsum = 0.0, found = 0.0, total = 0.0;
    for (int i = 0; i < 8; ++i) {
        float e = 0.01 + 0.03 * float(i);
        float wt = 1.0 / (1.0 + float(i));
        total += wt;
        vec3 dirW = normalize(vec3(hor.x, e, hor.y));
        vec4 clip = mg_proj * vec4(mat3(mg_view) * dirW, 0.0);
        if (clip.w <= 1e-4) continue;
        vec2 uv = clip.xy / clip.w * 0.5 + 0.5;
        if (any(lessThan(uv, vec2(0.002))) || any(greaterThan(uv, vec2(0.998))) || !IsSky(uv)) continue;
        sum += texture2D(mg_scene, uv).rgb * wt;
        wsum += wt;
        found += wt;
    }
    gl_FragColor = wsum > 0.0 ? vec4(sum / wsum, found / total) : vec4(0.0);
}
