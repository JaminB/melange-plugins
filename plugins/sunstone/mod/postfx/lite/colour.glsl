float Luma(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }
float Max3(vec3 c) { return max(c.r, max(c.g, c.b)); }
float Min3(vec3 c) { return min(c.r, min(c.g, c.b)); }

// HSV hue in degrees, 0 for greys.
float Hue(vec3 c) {
    float mx = Max3(c), C = mx - Min3(c);
    if (C < 1e-5) return 0.0;
    float h = mx == c.r ? (c.g - c.b) / C : (mx == c.g ? 2.0 + (c.b - c.r) / C : 4.0 + (c.r - c.g) / C);
    return fract(h / 6.0) * 360.0;
}

// h in turns (0..1, wraps).
vec3 Hsv2Rgb(float h, float s, float v) {
    vec3 k = clamp(abs(fract(h + vec3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
    return v * mix(vec3(1.0), k, s);
}
