// Needs the mg_proj, mg_view and p_sunDir uniforms.

// The sun's screen position (xy, often far off screen) and how far in front of the camera it is (z: 0 when behind
// or edge-on, 1 when well ahead).
vec3 SunScreen() {
    vec4 sc = mg_proj * vec4(mat3(mg_view) * normalize(p_sunDir), 0.0);
    return vec3(sc.xy / max(sc.w, 0.05) * 0.5 + 0.5, smoothstep(0.05, 0.30, sc.w));
}

// Interleaved gradient noise, 0..1.
float Ign(vec2 p) { return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715)))); }
