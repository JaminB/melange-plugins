#version 120
// Blood on the camera lens, seen through: up to six splats, each two vec4s fed by Bloodsand's Lua (an empty slot has size 0):
//   lNa = (x, y, size, shape)   the centre as fractions of the window (y up), the size as a fraction of the window height and
//                               which of the atlas's four shapes, 0..3
//   lNb = (birth, life, seed, 0) when the splat landed and how long it lasts, in p_clock's seconds, and a random 0..99
// The atlas (atlas.png, see tools/make_lens_atlas.js) has per pixel: A the shape, R how thick the blood is there, G and B which
// way the surface leans (x, y up, as 0.5 + slope / 2).
//
// Look: where a splat is, the scene is bent by the lean of the surface (the way a wet droplet bends what is behind it), blurred a
// little, tinted by the blood and darkened by its thickness; a dark meniscus runs along the edge with a pale highlight where the
// surface leans toward the light; and from the bottom of the splat drips run down, a few of them, slowly lengthening. The whole
// splat slides down a little and fades over its last part.
//
// Cost: one cheap test per slot; a splat that holds the pixel reads the atlas up to three times, and the scene is read five times
// once, however many splats there are, and not at all where there is none.
uniform sampler2D mg_scene;
uniform sampler2D t_atlas;
uniform vec4 mg_resolution;
uniform vec4 p_l0a, p_l1a, p_l2a, p_l3a, p_l4a, p_l5a;
uniform vec4 p_l0b, p_l1b, p_l2b, p_l3b, p_l4b, p_l5b;
uniform vec3 p_blood;
uniform float p_strength;
uniform float p_clock;
varying vec2 mg_uv;

const float DRIP = 0.38;        // the longest drip, in splat sizes
const float CREEP = 0.010;      // how far a splat slides down, in window heights a second
const float BEND = 0.11;        // how far the surface's lean bends the view, in splat sizes

float H11(float x) {
    return fract(sin(x * 127.1) * 43758.5453);
}

float N1(float x) {
    float i = floor(x);
    float f = fract(x);
    f = f * f * (3.0 - 2.0 * f);
    return mix(H11(i), H11(i + 1.0), f);
}

// The atlas at p (0..1 across the splat's square, y up) in the shape's cell.
vec4 at(vec2 cell, vec2 p) {
    p = clamp(p, 0.004, 0.996);
    return texture2D(t_atlas, cell + vec2(p.x, 1.0 - p.y) * 0.5);
}

// Adds one splat to acc: x, y the lean (weighted by coverage, in splat sizes), z the coverage, w the thickness.
void splat(vec4 a, vec4 b, vec2 uv, float aspect, inout vec4 acc) {
    if (a.z <= 0.0) return;
    float age = p_clock - b.x;
    float t = age / b.y;
    if (t < 0.0 || t >= 1.0) return;
    vec2 c = vec2(a.x, a.y - age * CREEP);
    vec2 p = (uv - c) * vec2(aspect, 1.0) / a.z + 0.5;
    if (p.x < 0.0 || p.x > 1.0 || p.y < -DRIP || p.y > 1.0) return;
    vec2 cell = vec2(mod(a.w, 2.0), floor(a.w * 0.5)) * 0.5;
    float fade = min(1.0, age * 12.0) * (1.0 - smoothstep(0.55, 1.0, t));
    float m = 0.0;
    vec2 lean = vec2(0.0);
    float thick = 0.0;
    if (p.y >= 0.0) {
        vec4 s = at(cell, p);
        m = s.a;
        thick = s.r;
        lean = (s.gb - 0.5) * 2.0;
    }
    // Drips: a few columns where the blood runs down from the bottom of the splat, longer as it ages. The pixel looks up the
    // shape at two points above it, so a column of blood is stretched downward.
    float col = N1(p.x * 6.0 + b.z * 7.0);
    float dl = smoothstep(0.5, 0.85, col) * DRIP * min(1.0, age * 0.45);
    if (dl > 0.01) {
        float y1 = p.y + dl * 0.5;
        float y2 = p.y + dl;
        vec4 s1 = at(cell, vec2(p.x, y1));
        vec4 s2 = at(cell, vec2(p.x, y2));
        // only the thick body of the blot runs, not its fingers and specks
        float d = max(s1.a * smoothstep(0.3, 0.6, s1.r) * step(0.0, y1) * step(y1, 1.0),
                      s2.a * smoothstep(0.3, 0.6, s2.r) * step(0.0, y2) * step(y2, 1.0));
        d *= smoothstep(0.45, 0.7, col) * 0.9;
        if (d > m) {
            m = d;
            thick = max(thick, 0.45);
            lean = vec2(0.0);
        }
    }
    float cov = m * fade;
    acc.xy += lean * cov;
    acc.w = max(acc.w, thick * cov);
    acc.z = 1.0 - (1.0 - acc.z) * (1.0 - cov);
}

void main() {
    vec2 uv = mg_uv;
    float aspect = mg_resolution.x / mg_resolution.y;
    vec4 acc = vec4(0.0);
    splat(p_l0a, p_l0b, uv, aspect, acc);
    splat(p_l1a, p_l1b, uv, aspect, acc);
    splat(p_l2a, p_l2b, uv, aspect, acc);
    splat(p_l3a, p_l3b, uv, aspect, acc);
    splat(p_l4a, p_l4b, uv, aspect, acc);
    splat(p_l5a, p_l5b, uv, aspect, acc);
    vec3 scene = texture2D(mg_scene, uv).rgb;
    float cov = acc.z * p_strength;
    if (cov < 0.004) {
        gl_FragColor = vec4(scene, 1.0);
        return;
    }
    // The view through the blood: bent by the lean, then blurred a little.
    vec2 lean = acc.xy / max(acc.z, 0.001);
    vec2 off = lean * BEND * 0.3 * vec2(1.0 / aspect, 1.0);
    vec2 px = mg_resolution.zw * 3.0;
    vec3 c0 = texture2D(mg_scene, uv + off).rgb;
    vec3 blur = (c0 * 2.0 + texture2D(mg_scene, uv + off + vec2(px.x, 0.0)).rgb + texture2D(mg_scene, uv + off - vec2(px.x, 0.0)).rgb
                 + texture2D(mg_scene, uv + off + vec2(0.0, px.y)).rgb + texture2D(mg_scene, uv + off - vec2(0.0, px.y)).rgb) / 6.0;
    // Tint and darkening: translucent where thin, nearly opaque in the thick middle.
    float th = acc.w / max(acc.z, 0.001);
    vec3 tint = p_blood * 1.15 + 0.10;
    vec3 thru = blur * mix(vec3(1.0), tint, 0.85) * (1.0 - 0.45 * th);
    thru = mix(thru, p_blood * 0.55, th * th * 0.45);
    vec3 col = mix(scene, thru, min(1.0, cov * 1.05));
    // The edge: a dark meniscus, and a pale highlight where the surface leans toward the light (up and to the left).
    float lm = min(1.0, length(lean));
    vec3 n = normalize(vec3(lean * 0.9, 0.6));
    vec3 h = normalize(normalize(vec3(-0.5, 0.6, 0.65)) + vec3(0.0, 0.0, 1.0));
    float spec = pow(max(dot(n, h), 0.0), 36.0);
    col *= 1.0 - (0.30 * smoothstep(0.35, 0.9, lm) + 0.5 * cov * (1.0 - cov)) ;
    col += vec3(1.0, 0.92, 0.9) * spec * 0.85 * cov * smoothstep(0.1, 0.5, lm);
    gl_FragColor = vec4(col, 1.0);
}
