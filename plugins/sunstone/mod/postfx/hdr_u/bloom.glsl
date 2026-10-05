// Needs the mg_renderScale uniform.

// Weight of bloom level n (1 = half resolution): wider levels count less, so bloom is a glow around bright things
// rather than a veil of the whole frame's average. Above a render scale of 1 the finest levels are narrower on screen
// than intended, so they fade out. SCALE_HALVED: every level already runs at half the usual scale.
float BloomWeight(float n) {
#ifdef SCALE_HALVED
    n += 1.0;
#endif
    float s = log2(max(mg_renderScale.x, 1.0));
    return clamp(n - s, 0.0, 1.0) * pow(0.6, max(n - s - 1.0, 0.0));
}

// Total weight of levels first..6, which is what the upsample chain sums into level first.
float BloomTotal(float first) {
    float s = 0.0;
    for (int i = 1; i <= 6; ++i)
        if (float(i) >= first) s += BloomWeight(float(i));
    return max(s, 1e-3);
}
