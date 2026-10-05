#version 120
// Sunstone lighting for lit, textured and vertex-coloured models: hemispheric sky/ground ambient, wrapped
// diffuse, energy-conserving Blinn-Phong on the material's own specular, and a sun-side rim light.
// sunstoneLight 0 keeps the game's terms.
uniform sampler2D texture0;
uniform vec3 lightDiffuseCol;
uniform vec3 lightAmbientCol;
uniform vec3 lightSpecularCol;
uniform mat4 materialMatrix;   // columns: specular colour, emissive colour, rim colour, (rim power, gloss)
// The vertex program's view matrix; column 1 is the world's up axis in eye space.
uniform mat4 view;

uniform float sunstoneLight;        // 0 game lighting, 1 Sunstone; + 10 shows the lighting on grey
uniform vec3 sunstoneSky;           // ambient tint for surfaces facing up
uniform vec3 sunstoneGround;        // ambient tint for surfaces facing down
uniform float sunstoneWrap;         // light wrap past the terminator (soft, rounded shading)
uniform float sunstoneSpecular;     // scale of the material's specular
uniform float sunstoneRim;          // rim light strength
uniform float sunstoneSunGain;      // sun (diffuse) gain
uniform float sunstoneAmbientGain;  // ambient gain
uniform vec3 sunstoneSunTint;       // tint of the direct light
uniform vec3 sunstoneShadowTint;    // tint of the ambient light
uniform float sunstoneTint;         // how far the two tints apply (0 none)
uniform float sunstoneGroundDip;    // ambient dip on surfaces facing down (0 none)
uniform float sunstoneFoliage;      // leaf hue shift toward yellow-green (degrees)
uniform float sunstoneSplit;        // pixels left of this x keep the game's lighting (comparisons)

bool GameTerms() {
    return gl_FragCoord.x < sunstoneSplit || sunstoneLight < 0.5 || (sunstoneLight > 9.5 && sunstoneLight < 10.5);
}

// Brightness above the knee rolls off toward white, as film does, so bright sand and stone stay pale rather than
// clipping per channel or turning orange.
vec3 Shoulder(vec3 c) {
    if (GameTerms()) return c;
    float m = max(c.r, max(c.g, c.b));
    if (m <= 0.9) return c;
    float r = 0.9 + 0.1 * (1.0 - exp((0.9 - m) / 0.1));
    vec3 rolled = mix(c * (r / m), vec3(r), clamp((m - 0.9) / m * 1.5, 0.0, 1.0));
    return mix(rolled, min(c, vec3(1.0)), 0.5);
}

float Hue(vec3 c, out float s) {
    float mx = max(c.r, max(c.g, c.b)), C = mx - min(c.r, min(c.g, c.b));
    s = C / max(mx, 1e-4);
    if (C < 1e-4) return 0.0;
    float h = mx == c.r ? (c.g - c.b) / C : (mx == c.g ? 2.0 + (c.b - c.r) / C : 4.0 + (c.r - c.g) / C);
    return fract(h / 6.0) * 360.0;
}

vec3 Hsv(float h, float s, float v) {
    vec3 k = clamp(abs(fract(h / 360.0 + vec3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
    return v * mix(vec3(1.0), k, s);
}

// A gentler pull of leaf greens toward yellow-green, with no chroma cap; very saturated greens (painted drums) keep
// their colour.
vec3 Foliage(vec3 c) {
    if (sunstoneFoliage <= 0.0 || GameTerms()) return c;
    float S, H = Hue(c, S);
    float w = smoothstep(0.2, 0.4, S) * smoothstep(95.0, 120.0, H) * (1.0 - smoothstep(155.0, 175.0, H));
    w *= 1.0 - smoothstep(0.55, 0.65, S) * (1.0 - smoothstep(120.0, 130.0, H));
    // Glossy materials are painted props, not leaves.
    w *= 1.0 - smoothstep(0.15, 0.4, dot(materialMatrix[0].xyz, vec3(0.333)));
    return Hsv(H - sunstoneFoliage * w, S, max(c.r, max(c.g, c.b)));
}

// The rim light, kept apart so it can take on the surface's colour.
vec3 rimLight = vec3(0.0);

void Light(out vec3 base, out vec3 add) {
    vec3 n = normalize(gl_TexCoord[2].xyz);
    vec3 v = normalize(gl_TexCoord[1].xyz);
    vec3 l = normalize(-gl_TexCoord[3].xyz);
    vec3 h = normalize(l + v);
    vec3 specCol = materialMatrix[0].xyz;
    vec3 emissive = materialMatrix[1].xyz;
    vec3 rimCol = materialMatrix[2].xyz;
    float rimPower = materialMatrix[3].x;
    float power = materialMatrix[3].y;
    float ndl = dot(n, l), ndh = max(dot(n, h), 0.0), ndv = max(dot(n, v), 0.0);
    float gameRim = clamp(pow(1.0 - dot(v, n), rimPower), 0.0, 1.0);

    if (GameTerms()) {
        float spec = power > 0.0 ? pow(ndh, power) : 1.0;
        base = lightDiffuseCol * clamp(ndl, 0.0, 1.0) + lightAmbientCol + emissive;
        add = lightSpecularCol * specCol * spec + rimCol * gameRim;
        return;
    }

    vec3 up = view[1].xyz;
    up = dot(up, up) > 0.25 ? normalize(up) : l;
    float w = sunstoneWrap;
    float diffuse = clamp((ndl + w) / (1.0 + w), 0.0, 1.0);
    float sky = dot(n, up) * 0.5 + 0.5;
    vec3 ambient = lightAmbientCol * sunstoneAmbientGain * mix(sunstoneGround, sunstoneSky, sky)
        * mix(vec3(1.0), sunstoneShadowTint, sunstoneTint) * mix(1.0 - sunstoneGroundDip, 1.0, sky);

    float p = max(power, 1.0);
    float shine = power > 0.0 ? (p + 8.0) / 8.0 * pow(ndh, p) * max(ndl, 0.0) : 0.0;
    float f = 1.0 + 3.0 * pow(1.0 - clamp(dot(l, h), 0.0, 1.0), 5.0);
    vec3 spec = lightSpecularCol * specCol * sunstoneSpecular * f * shine;

    float edge = pow(1.0 - ndv, 2.5);
    float back = clamp(0.35 - 0.65 * dot(v, l), 0.0, 1.0);
    vec3 rim = sunstoneRim * edge * (lightAmbientCol * sunstoneSky * 0.6 + lightDiffuseCol * (0.2 + back)) * (0.4 + 0.6 * sky);

    float keep = 1.0 - clamp(dot(specCol, vec3(0.333)) * sunstoneSpecular * 0.5, 0.0, 0.5);
    base = lightDiffuseCol * mix(vec3(1.0), sunstoneSunTint, sunstoneTint) * sunstoneSunGain * diffuse * keep + ambient + emissive;
    add = spec + rimCol * gameRim * 0.5;
    // Weaker on surfaces facing up, which only meet the rim at grazing angles (lids, tops).
    rimLight = rim * mix(1.0, 0.35, smoothstep(0.7, 1.0, sky));
}

void main() {
    vec3 base, add;
    Light(base, add);
    vec3 albedo = sunstoneLight > 9.5 ? vec3(0.5) : Foliage(gl_Color.rgb * texture2D(texture0, gl_TexCoord[0].xy).rgb);
    gl_FragColor = vec4(clamp(Shoulder(base * albedo + add + rimLight * mix(vec3(1.0), albedo / max(max(albedo.r, max(albedo.g, albedo.b)), 1e-3), 0.6)), 0.0, 1.0), gl_Color.a);
}
