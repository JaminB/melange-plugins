#version 120
// Luminance averaged over the 4x4 scene pixels under each quarter-size texel; the sky counts as the land's grey
// so the horizon does not leave a dark halo on the islands.
uniform sampler2D mg_scene;
uniform sampler2D mg_depth;
uniform vec4 mg_sceneResolution;
uniform vec2 mg_renderScale;
varying vec2 mg_uv;

float Y(vec2 uv) {
    float y = dot(texture2D(mg_scene, uv).rgb, vec3(0.2126, 0.7152, 0.0722));
    return texture2D(mg_depth, uv).r >= 0.99999 ? min(y, 0.5) : y;
}

void main() {
    vec2 o = mg_sceneResolution.zw * max(mg_renderScale, vec2(1.0));
    float y = Y(mg_uv + vec2(-o.x, -o.y)) + Y(mg_uv + vec2(o.x, -o.y)) + Y(mg_uv + vec2(-o.x, o.y)) + Y(mg_uv + vec2(o.x, o.y));
    gl_FragColor = vec4(vec3(y * 0.25), 1.0);
}
