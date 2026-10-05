#version 120
// Joint-bilateral upsample of the reduced-resolution AO and contact terms, then applied in linear light: AO with a
// multi-bounce lift from the scene colour (bright surfaces lose less), eased on sunlit pixels; contact shadow with a
// slightly cool tint. AO_SCALE is the resolution scale of the ao and blur passes.
uniform sampler2D mg_scene;
uniform sampler2D mg_depth;
uniform sampler2D mg_pass_blurv;
uniform mat4 mg_invProj;
uniform vec4 mg_resolution;
uniform vec2 mg_nearFar;
uniform float p_sunlitFade;
uniform float p_contactStrength;
uniform vec3 p_contactTint;
uniform int p_debug;
varying vec2 mg_uv;

float ViewDist(vec2 uv) {
    float d = texture2D(mg_depth, uv).r;
    vec4 p = mg_invProj * vec4(0.0, 0.0, d * 2.0 - 1.0, 1.0);
    return -p.z / p.w;
}

void main() {
    vec4 scene = texture2D(mg_scene, mg_uv);
    float sky = 0.45 * mg_nearFar.y;
    float z0 = ViewDist(mg_uv);
    if (z0 > sky) {
        gl_FragColor = p_debug > 0 ? vec4(1.0) : scene;
        return;
    }

    vec2 lowRes = floor(mg_resolution.xy * AO_SCALE + 0.5);
    vec2 pos = mg_uv * lowRes - 0.5;
    vec2 base = floor(pos);
    vec2 f = pos - base;
    vec2 sum = vec2(0.0);
    float wsum = 0.0;
    vec2 nearest = vec2(1.0);
    float nearestDz = 1e30;
    for (int i = 0; i < 4; ++i) {
        vec2 o = vec2(float(i - (i / 2) * 2), float(i / 2));
        vec2 uv = (base + o + 0.5) / lowRes;
        vec2 v = texture2D(mg_pass_blurv, uv).rg;
        float dz = abs(ViewDist(uv) - z0);
        vec2 b = mix(1.0 - f, f, o);
        float w = b.x * b.y * exp(-dz * 16.0 / z0);
        sum += v * w;
        wsum += w;
        if (dz < nearestDz) {
            nearestDz = dz;
            nearest = v;
        }
    }
    vec2 v = wsum > 1e-4 ? sum / wsum : nearest;
    float ao = v.r, occ = 1.0 - v.g;

    if (p_debug == 1) {
        gl_FragColor = vec4(vec3(ao), 1.0);
        return;
    }
    if (p_debug == 2) {
        gl_FragColor = vec4(vec3(1.0 - occ), 1.0);
        return;
    }
    if (p_debug == 3) {
        gl_FragColor = vec4(ao, ao * (1.0 - occ), ao * (1.0 - occ), 1.0);
        return;
    }
    if (ao > 0.999 && occ < 0.001) {
        gl_FragColor = scene;
        return;
    }

    vec3 lin = pow(scene.rgb, vec3(2.2));
    vec3 a = 2.0404 * lin - 0.3324, b = -4.7951 * lin + 0.6417, c = 2.7552 * lin + 0.6903;
    vec3 vis = max(vec3(ao), ((ao * a + b) * ao + c) * ao);
    float luma = dot(scene.rgb, vec3(0.2126, 0.7152, 0.0722));
    vis = mix(vis, vec3(1.0), p_sunlitFade * smoothstep(0.5, 0.9, luma));
    vec3 shade = mix(vec3(1.0), (1.0 - p_contactStrength) * p_contactTint, occ);
    lin *= vis * shade;
    gl_FragColor = vec4(pow(clamp(lin, 0.0, 1.0), vec3(1.0 / 2.2)), scene.a);
}
