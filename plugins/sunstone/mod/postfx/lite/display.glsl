// Needs colour.glsl and the p_tsShoulder, p_whitePoint, p_whiteStart, p_whiteAmount, p_saturation, p_vibrance and
// p_foliage uniforms.

// Tone curve on the brightest channel, so hue is kept; pinned at 0.18 -> 0.18 and whitePoint -> 1, with contrast a.
// Highlights then blend toward white.
vec3 Display(vec3 hdr, float a) {
    float peak = Max3(hdr);
    if (peak < 1e-5) return vec3(0.0);
    float d = p_tsShoulder, W = p_whitePoint, mi = 0.18;
    float wa = pow(W, a), wad = pow(W, a * d), ma = pow(mi, a), mad = pow(mi, a * d);
    float den = (wad - mad) * mi;
    float B = (wa * mi - ma) / den;
    float C = (wad * ma - wa * mad * mi) / den;
    float z = pow(peak, a);
    float ts = clamp(z / (pow(z, d) * B + C), 0.0, 1.0);
    float white = pow(smoothstep(p_whiteStart, 1.0, ts), 1.6) * p_whiteAmount;
    return mix(hdr / peak, vec3(1.0), white) * ts;
}

// Saturation, plus vibrance on muted colours only and not on the foliage band, which is already set. amount fades
// both toward no change.
vec3 Saturation(vec3 c, float amount) {
    float luma = Luma(c);
    float hi = Max3(c);
    float chroma = (hi - Min3(c)) / max(hi, 1e-3);
    float h = Hue(c);
    float green = smoothstep(0.15, 0.3, chroma) * smoothstep(64.0, 84.0, h) * (1.0 - smoothstep(150.0, 168.0, h));
    green *= p_foliage;
    float sat = p_saturation + p_vibrance * (1.0 - smoothstep(0.25, 0.35, chroma)) * (1.0 - green);
    return clamp(mix(vec3(luma), c, mix(1.0, sat, amount)), 0.0, 1.0);
}
