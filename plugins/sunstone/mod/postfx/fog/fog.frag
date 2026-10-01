#version 120
// Height and distance fog with sun-tinted in-scatter. Sky pixels are left to the sky effect; this only shades
// world geometry, so labels and the HUD (drawn after PostWorld) are never touched.
uniform sampler2D mg_scene;
uniform sampler2D mg_depth;
uniform mat4 mg_invProj;
uniform mat4 mg_view;
uniform float p_density;
uniform float p_fogHeight;
uniform float p_heightFalloff;
uniform float p_maxFog;
uniform vec3 p_fogColor;
uniform vec3 p_sunColor;
uniform vec3 p_sunDir;
uniform float p_inscatterStrength;
uniform float p_inscatterSharpness;
varying vec2 mg_uv;

const float kSkyDepth = 0.9999;

void main() {
    vec4 scene = texture2D(mg_scene, mg_uv);
    float depth = texture2D(mg_depth, mg_uv).r;
    if (depth >= kSkyDepth) {
        gl_FragColor = scene;
        return;
    }

    vec4 clip = vec4(mg_uv * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
    vec4 viewP = mg_invProj * clip;
    vec3 P = viewP.xyz / viewP.w;
    float dist = length(P);
    vec3 worldPos = (P - mg_view[3].xyz) * mat3(mg_view);

    float distFog = 1.0 - exp(-dist * p_density);
    float heightAtten = exp(-max(worldPos.y - p_fogHeight, 0.0) * p_heightFalloff);
    float fogAmount = clamp(distFog * heightAtten, 0.0, p_maxFog);

    vec3 viewRay = normalize(P);
    vec3 sunView = normalize((mg_view * vec4(normalize(p_sunDir), 0.0)).xyz);
    float sunAlign = clamp(dot(viewRay, sunView), 0.0, 1.0);
    vec3 fogColor = mix(p_fogColor, p_sunColor, pow(sunAlign, p_inscatterSharpness) * p_inscatterStrength);

    gl_FragColor = vec4(mix(scene.rgb, fogColor, fogAmount), scene.a);
}
