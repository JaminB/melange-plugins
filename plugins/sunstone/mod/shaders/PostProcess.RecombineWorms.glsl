#version 120
// The game's RecombineWorms (PostProcess.cg), which lays the turn's worm, drawn on its own, over the rest of the scene,
// with one change: where the model shaders marked human skin (FixedFunction.FFFragmentMainTexLit.glsl: the colour on the
// 8-bit grid and the alpha a hash of it, SkinMark), the scene's alpha carries the mark on, so post-FX (Bloodsand, Kindjal)
// can find the skin exactly: alpha 245/255 on skin, 1 everywhere else, as the game leaves it. A pixel of the rest of the
// scene counts only when two of its four neighbours do as well, so a stray match on a cut-out's edge is dropped. The game
// writes alpha 1 and blends this quad (source alpha) over a target cleared to (0, 0, 0, 1), so skin is written as
// (colour / SKIN_A, SKIN_A): the colour lands unchanged and the alpha as SKIN_A^2 - SKIN_A + 1 = 245/255. (Known limit: a
// skin channel above SKIN_A, about 0.96, clips there, so the brightest 4% of a highlight on skin is lost.)
// Where the turn's worm is behind something (a ledge between it and the camera: the game shows it through), its skin gets
// 244/255 instead (SKIN_B): the depth there is the ledge's, so Bloodsand and Kindjal find that worm's body along the view
// ray instead of at the depth, and paint its wounds and acid through the ledge as well, where they used to stop in a hard
// line at the ledge's edge. Where the game drew its ghost over the hidden worm (PostProcess.Silhouette_PC.glsl, Sunstone's
// copy, leaves the worm's skin there at alpha 169..188 of 255 and anything else at 194), that counts as hidden skin too.
// The turn's worm counts while the game shows it at more than a quarter of its opacity (it fades it as the camera comes
// close): below that it is mostly the scene behind it, and a wound painted in full would float on the scene.
// The game draws this quad with glBegin/glEnd, and Melange uploads params.ini values only before glDrawElements and
// glDrawArrays, so this program takes no parameters. It runs whenever Sunstone's lit-model shader does (which marks the
// skin, the game's peach included), and Sunstone's Lua pauses it (wum.shaders.enableGlsl) only together with that shader,
// so a change of the skin or hair setting never re-links it (a re-link and its log lines could stall the frame).
uniform sampler2D texture0;   // the scene without the turn's worm: colour
uniform sampler2D texture1;   // ...and depth
uniform sampler2D texture2;   // the turn's worm: colour
uniform sampler2D texture3;   // ...and depth

const float SKIN_A = 0.95915;
const float SKIN_B = 0.954822;

// Keep the same as in FixedFunction.FFFragmentMainTexLit.glsl.
float SkinMark(vec3 q) {
    return 192.0 + mod(q.r * 37.0 + q.g * 101.0 + q.b * 13.0, 49.0);
}

float Marked(vec4 c) {
    float a = floor(c.a * 255.0 + 0.5);
    return a >= 192.0 && a <= 240.0 && a == SkinMark(floor(c.rgb * 255.0 + 0.5)) ? 1.0 : 0.0;
}

void main() {
    vec2 uv = gl_TexCoord[0].xy;
    vec2 px = vec2(dFdx(uv.x), dFdy(uv.y));
    float wormDepth = texture2D(texture3, uv).r;
    float sceneDepth = texture2D(texture1, uv).r;
    vec4 scene = texture2D(texture0, uv);
    vec3 c = scene.rgb;
    float skin = Marked(scene), behind = 0.0;
    if (skin > 0.0) {
        skin = step(2.0, Marked(texture2D(texture0, uv + vec2(px.x, 0.0))) + Marked(texture2D(texture0, uv - vec2(px.x, 0.0)))
                       + Marked(texture2D(texture0, uv + vec2(0.0, px.y))) + Marked(texture2D(texture0, uv - vec2(0.0, px.y))));
    }
    gl_FragDepth = sceneDepth;
    if (wormDepth < 1.0) {
        vec4 worm = texture2D(texture2, uv);
        c = mix(scene.rgb, worm.rgb, gl_Color.a);
        // The turn's worm is drawn alone, on a cleared target: no neighbours needed.
        if (gl_Color.a > 0.25) {
            behind = sceneDepth < wormDepth ? 1.0 : 0.0;
            float wa = floor(worm.a * 255.0 + 0.5);
            skin = max(Marked(worm), behind * step(166.5, wa) * step(wa, 190.5));
        }
        behind *= skin;
        gl_FragDepth = min(sceneDepth, wormDepth);
    }
    float a = behind > 0.0 ? SKIN_B : SKIN_A;
    gl_FragColor = skin > 0.0 ? vec4(c / a, a) : vec4(c, 1.0);
}
