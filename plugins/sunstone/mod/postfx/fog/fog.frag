#version 120
// Exponential height haze integrated along the view ray, relative to the camera's height, toward the horizon
// colour of the sky (pass.horizon). Sky pixels are left alone; labels and the HUD come after PostWorld.
uniform sampler2D mg_scene;
uniform sampler2D mg_depth;
uniform sampler2D mg_pass_horizon;
uniform mat4 mg_invProj;
uniform mat4 mg_view;
uniform vec2 mg_nearFar;
uniform float p_distance;
uniform float p_heightFalloff;
uniform float p_maxHaze;
uniform float p_desaturate;
varying vec2 mg_uv;

vec4 HorizonColour(float x) {
    vec3 sum = vec3(0.0);
    float wsum = 0.0, cover = 0.0;
    for (int i = 0; i < 8; ++i) {
        float u = (float(i) + 0.5) / 8.0;
        vec4 h = texture2D(mg_pass_horizon, vec2(u, 0.5));
        float w = h.a * exp(-(u - x) * (u - x) * 8.0);
        sum += h.rgb * w;
        wsum += w;
        cover += h.a;
    }
    return wsum > 1e-4 ? vec4(sum / wsum, clamp(cover / 4.0, 0.0, 1.0)) : vec4(0.0);
}

void main() {
    vec4 scene = texture2D(mg_scene, mg_uv);
    float depth = texture2D(mg_depth, mg_uv).r;
    vec4 vp = mg_invProj * vec4(vec3(mg_uv, depth) * 2.0 - 1.0, 1.0);
    vec3 P = vp.xyz / vp.w;
    float dist = length(P);
    if (depth >= 1.0 || dist > 0.5 * mg_nearFar.y) {
        gl_FragColor = scene;
        return;
    }
    vec4 horizon = HorizonColour(mg_uv.x);
    float rise = (P * mat3(mg_view)).y;
    float k = rise / p_heightFalloff;
    float along = abs(k) < 1e-3 ? 1.0 : min((1.0 - exp(-k)) / k, 4.0);
    float od = dist / p_distance * along;
    float haze = p_maxHaze * (1.0 - exp(-od)) * horizon.a;
    float luma = dot(scene.rgb, vec3(0.2126, 0.7152, 0.0722));
    vec3 c = mix(scene.rgb, vec3(luma), haze * p_desaturate);
    gl_FragColor = vec4(mix(c, horizon.rgb, haze), scene.a);
}
