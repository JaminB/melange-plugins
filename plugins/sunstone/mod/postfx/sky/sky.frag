#version 120
// Sky pixels only (depth >= kSkyDepth): a soft vertical gradient tint over the game's own sky dome, plus an
// analytic sun disc and glow built from the view ray and a fixed world-space sun direction. The dome texture
// itself is never replaced or sampled into anything shipped; this only tints and adds light on top of it.
uniform sampler2D mg_scene;
uniform sampler2D mg_depth;
uniform mat4 mg_invProj;
uniform mat4 mg_view;
uniform vec3 p_sunDir;
uniform vec3 p_sunColor;
uniform float p_sunSize;
uniform float p_glowSharpness;
uniform float p_glowIntensity;
uniform vec3 p_horizonColor;
uniform vec3 p_zenithColor;
uniform float p_gradientStrength;
varying vec2 mg_uv;

const float kSkyDepth = 0.9999;

vec3 ViewRay(vec2 uv) {
    vec4 p = mg_invProj * vec4(uv * 2.0 - 1.0, 1.0, 1.0);
    return normalize(p.xyz / p.w);
}

void main() {
    vec4 scene = texture2D(mg_scene, mg_uv);
    float depth = texture2D(mg_depth, mg_uv).r;
    if (depth < kSkyDepth) {
        gl_FragColor = scene;
        return;
    }

    vec3 viewRay = ViewRay(mg_uv);
    vec3 worldRay = normalize(viewRay * mat3(mg_view));
    vec3 sunDir = normalize(p_sunDir);
    vec3 sunView = normalize((mg_view * vec4(sunDir, 0.0)).xyz);

    float h = clamp(worldRay.y * 0.5 + 0.5, 0.0, 1.0);
    vec3 grad = mix(p_horizonColor, p_zenithColor, smoothstep(0.0, 0.6, h));

    float cosA = clamp(dot(viewRay, sunView), -1.0, 1.0);
    float cosDisc = cos(radians(p_sunSize));
    float disc = smoothstep(cosDisc - 0.002, cosDisc, cosA);
    float glow = pow(max(cosA, 0.0), p_glowSharpness) * p_glowIntensity;

    vec3 c = scene.rgb * mix(vec3(1.0), grad, p_gradientStrength);
    c += p_sunColor * (glow + disc);
    gl_FragColor = vec4(c, scene.a);
}
