// Needs colour.glsl and the p_folShift, p_folValue, p_expandSurface, p_expandSpec and p_expandSky uniforms.

// Pulls saturated mid greens toward yellow-green and caps their chroma; gas, barrels, water and sky fall outside the
// band or below its saturation gate.
vec3 Foliage(vec3 c, float amt) {
    float mx = Max3(c), C = mx - Min3(c);
    if (C < 1e-4 || amt <= 0.0) return c;
    float S = C / mx;
    float H = Hue(c);
    float sg = smoothstep(0.30, 0.50, S) * amt;
    // Painted props (oil drums) are more saturated and yellower than any meadow; they keep their colour.
    sg *= 1.0 - smoothstep(0.55, 0.65, S) * (1.0 - smoothstep(120.0, 130.0, H));
    // Ramps in up to the meadow's hue, so yellower greens (tree canopies) move less than the grass.
    float wH = smoothstep(110.0, 133.0, H) * (1.0 - smoothstep(150.0, 170.0, H)) * sg;
    float wC = smoothstep(114.0, 133.0, H) * (1.0 - smoothstep(148.0, 165.0, H)) * sg;
    H -= p_folShift * wH;
    S = mix(S, min(S, 0.42 + (S - 0.42) * 0.5), wC);
    return Hsv2Rgb(H / 360.0, S, mx * (1.0 - p_folValue * wC));
}

// Stretches the top of the 8-bit range back out: white clouds most, white glints more than lit surfaces. Saturated
// sky keeps the surface range so it stays blue through the display transform.
vec3 Expand(vec3 lin, float sky) {
    float m = Max3(lin), sat = (m - Min3(lin)) / max(m, 1e-3);
    float white = 1.0 - smoothstep(0.05, 0.25, sat);
    float spec = smoothstep(0.85, 1.0, m) * white;
    // On the sky the range opens gradually with brightness and whiteness, so painted cloud rims stay soft.
    float W = mix(p_expandSurface + p_expandSpec * spec, p_expandSky,
                  sky * (1.0 - smoothstep(0.0, 0.45, sat)));
    float v = sky > 0.5 ? smoothstep(0.35, 1.0, m) : clamp((m - 0.55) / 0.45, 0.0, 1.0);
    return lin * (1.0 + (W - 1.0) * v * v);
}
