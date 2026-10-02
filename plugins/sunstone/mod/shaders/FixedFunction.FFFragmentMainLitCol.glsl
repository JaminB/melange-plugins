#version 120
// Sunstone lighting for lit vertex-coloured models: hemispheric sky/ground ambient, wrapped diffuse, energy-conserving
// Blinn-Phong on the material's own specular, and a sun-side rim light. sunstoneLight 0 keeps the game's terms.
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
uniform float sunstoneSplit;        // pixels left of this x keep the game's lighting (comparisons)

bool GameTerms() {
    return gl_FragCoord.x < sunstoneSplit || sunstoneLight < 0.5 || (sunstoneLight > 9.5 && sunstoneLight < 10.5);
}

// Brightness above the knee rolls off instead of clipping per channel, so bright colours keep some of their hue
// (mostly the game's plain clip, with a share of hue-preserving roll-off).
vec3 Shoulder(vec3 c) {
    if (GameTerms()) return c;
    float m = max(c.r, max(c.g, c.b));
    if (m <= 0.9) return c;
    vec3 rolled = c * ((0.9 + 0.1 * (1.0 - exp((0.9 - m) / 0.1))) / m);
    return mix(rolled, min(c, vec3(1.0)), 0.65);
}

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
    vec3 ambient = lightAmbientCol * sunstoneAmbientGain * mix(sunstoneGround, sunstoneSky, sky);

    float p = max(power, 1.0);
    float shine = power > 0.0 ? (p + 8.0) / 8.0 * pow(ndh, p) * max(ndl, 0.0) : 0.0;
    float f = 1.0 + 3.0 * pow(1.0 - clamp(dot(l, h), 0.0, 1.0), 5.0);
    vec3 spec = lightSpecularCol * specCol * sunstoneSpecular * f * shine;

    float edge = pow(1.0 - ndv, 3.0);
    float back = clamp(0.35 - 0.65 * dot(v, l), 0.0, 1.0);
    vec3 rim = sunstoneRim * edge * (lightAmbientCol * sunstoneSky * 0.5 + lightDiffuseCol * back) * (0.4 + 0.6 * sky);

    float keep = 1.0 - clamp(dot(specCol, vec3(0.333)) * sunstoneSpecular * 0.5, 0.0, 0.5);
    base = lightDiffuseCol * sunstoneSunGain * diffuse * keep + ambient + emissive;
    add = spec + rim + rimCol * gameRim * 0.5;
}

void main() {
    vec3 base, add;
    Light(base, add);
    vec3 albedo = sunstoneLight > 9.5 ? vec3(0.5) : gl_Color.rgb;
    gl_FragColor = vec4(clamp(Shoulder(base * albedo + add), 0.0, 1.0), gl_Color.a);
}
