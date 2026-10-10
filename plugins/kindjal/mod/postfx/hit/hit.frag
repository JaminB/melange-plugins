#version 120
// Kindjal hit flash: a one-pass vignette for a heavy melee or blast hit. Uniform contract (set by Kindjal's Lua with
// wum.postfx.setTransient, so the parameters are hidden; the client enables the effect only while a flash is running):
//   p_flash   float 0..1  how strong the flash is right now (0 leaves the scene unchanged)
//   p_center  vec2        screen uv of the victim (0..1, origin bottom-left); the screen is clear round it
// Built-ins used: mg_scene, mg_resolution (width, height, 1/width, 1/height).
uniform sampler2D mg_scene;
uniform vec4 mg_resolution;
uniform float p_flash;
uniform vec2 p_center;
varying vec2 mg_uv;

void main() {
    vec4 scene = texture2D(mg_scene, mg_uv);
    if (p_flash <= 0.0) {
        gl_FragColor = scene;
        return;
    }
    float f = clamp(p_flash, 0.0, 1.0);
    // Distance from the victim in screen heights, so the clear area is round and not stretched with the window.
    float r = length((mg_uv - p_center) * vec2(mg_resolution.x * mg_resolution.w, 1.0));
    float edge = smoothstep(0.3, 1.1, r);
    float lum = dot(scene.rgb, vec3(0.299, 0.587, 0.114));
    // A brief desaturation over the whole frame, then the edges pushed toward dark red (the grey scene's own brightness
    // survives as the red's, so the shapes under it stay readable).
    vec3 grey = mix(scene.rgb, vec3(lum), 0.5 * f);
    vec3 red = vec3(0.85, 0.06, 0.05) * (0.12 + 0.55 * lum);
    gl_FragColor = vec4(mix(grey, red, 0.85 * f * edge), scene.a);
}
