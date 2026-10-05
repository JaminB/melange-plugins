// Needs colour.glsl and the p_folShift, p_folValue, p_expandSurface, p_expandSpec and p_expandSky uniforms.

// Pulls saturated mid greens toward yellow-green and caps their chroma; gas, barrels, water and sky fall outside the
// band or below its saturation gate.
vec3 Foliage(vec3 c, float amt) {
    float mx = Max3(c), C = mx - Min3(c);
    if (C < 1e-4 || amt <= 0.0) return c;
    float S = C / mx;
    float H = Hue(c);
    float sg = smoothstep(0.30, 0.50, S) * amt;
    float wH = smoothstep(84.0, 116.0, H) * (1.0 - smoothstep(140.0, 168.0, H)) * sg;
    float wC = smoothstep(100.0, 116.0, H) * (1.0 - smoothstep(140.0, 160.0, H)) * sg;
    H -= p_folShift * wH;
    S = mix(S, min(S, 0.42 + (S - 0.42) * 0.5), wC);
    return Hsv2Rgb(H / 360.0, S, mx * (1.0 - p_folValue * wC));
}

// Stretches the top of the 8-bit range back out: the sky most, white glints more than lit surfaces.
vec3 Expand(vec3 lin, float sky) {
    float m = Max3(lin), sat = (m - Min3(lin)) / max(m, 1e-3);
    float spec = smoothstep(0.85, 1.0, m) * (1.0 - smoothstep(0.05, 0.25, sat));
    float W = mix(p_expandSurface + p_expandSpec * spec, p_expandSky, sky);
    float v = clamp((m - 0.55) / 0.45, 0.0, 1.0);
    return lin * (1.0 + (W - 1.0) * v * v);
}
