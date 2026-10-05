#version 120
// Blood soaked into whatever surface lies near each stain point: a decal rebuilt from the depth buffer, so it wraps
// the terrain. Eight slots, each a world position (stainN) and radius, seed and strength (stainNb). Sky is left alone,
// and so is any surface that does not face up (a worm's body, a wall).
uniform sampler2D mg_scene;
uniform sampler2D mg_depth;
uniform mat4 mg_invProj;
uniform mat4 mg_view;
uniform vec2 mg_nearFar;
uniform vec3 p_stain0, p_stain1, p_stain2, p_stain3, p_stain4, p_stain5, p_stain6, p_stain7;
uniform vec3 p_stain0b, p_stain1b, p_stain2b, p_stain3b, p_stain4b, p_stain5b, p_stain6b, p_stain7b;
uniform vec3 p_blood;
uniform float p_strength;
varying vec2 mg_uv;

float Hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// Adds one stain's coverage and core darkness to cov and core. d is the pixel's offset from the stain in view space.
// mg_view is the world-to-view matrix in column-major layout with translation (it is loaded straight into GL), so
// its upper 3x3 is the world-to-view rotation and d * mat3(mg_view), which is transpose(R) * d, turns it back to world axes.
void Stain(vec3 P, vec3 centre, vec3 b, inout float cov, inout float core) {
    if (b.z <= 0.0) return;
    vec3 d = P - (mg_view * vec4(centre, 1.0)).xyz;
    float R = b.x;
    if (dot(d, d) > 4.84 * R * R) return;
    vec3 L = d * mat3(mg_view);
    float tol = R * 0.5 + 3.0;
    float vert = 1.0 - smoothstep(tol * 0.5, tol, abs(L.y));
    if (vert <= 0.0) return;

    float r = length(L.xz);
    // The edge radius swings with the angle: a few sine lobes with phases taken from the seed, so no two blots match.
    // Whole-number frequencies keep the edge continuous where the angle wraps.
    float a = atan(L.z, L.x + 1e-4);
    vec3 ph = vec3(Hash(vec2(b.y, 1.7)), Hash(vec2(b.y, 5.3)), Hash(vec2(b.y, 9.1))) * 6.2831853;
    float edge = R * (0.8 + 0.2 * sin(a * 3.0 + ph.x) + 0.12 * sin(a * 5.0 + ph.y) + 0.07 * sin(a * 9.0 + ph.z));
    float t = r / max(edge, 1e-3);
    float body = (1.0 - smoothstep(0.82, 1.0, t)) * mix(1.0, 0.6, smoothstep(0.55, 1.0, t));
    float c = body;

    // Satellite droplets: one candidate per cell of a grid, thinning out toward 2x the radius.
    float cs = max(R * 0.25, 1.0);
    vec2 q = L.xz / cs;
    vec2 id = floor(q);
    vec2 f = fract(q);
    vec3 h = vec3(Hash(id + b.y), Hash(id * 1.37 + b.y + 17.0), Hash(id * 2.11 + b.y + 41.0));
    float dens = 0.45 * (1.0 - smoothstep(0.9, 2.0, r / R));
    if (h.x < dens && t > 0.9) {
        float size = (0.1 + 0.2 * h.z) * (1.0 - 0.5 * smoothstep(1.0, 2.0, r / R));
        float drop = 1.0 - smoothstep(size * 0.6, size, length(f - (0.25 + 0.5 * h.yz)));
        c = max(c, drop * 0.85);
    }

    c *= vert * b.z;
    cov = max(cov, c);
    core = max(core, (1.0 - smoothstep(0.15, 0.75, t)) * vert * b.z);
}

void main() {
    vec4 scene = texture2D(mg_scene, mg_uv);
    float depth = texture2D(mg_depth, mg_uv).r;
    vec4 vp = mg_invProj * vec4(vec3(mg_uv, depth) * 2.0 - 1.0, 1.0);
    vec3 P = vp.xyz / vp.w;
    // Derivatives are taken before any early return so that every pixel of a block takes part in them.
    vec3 dPx = dFdx(P);
    vec3 dPy = dFdy(P);
    if (p_strength <= 0.0 || depth >= 1.0 || length(P) > 0.5 * mg_nearFar.y) {
        gl_FragColor = scene;
        return;
    }

    // The surface normal, as in the skin pass: a pixel across a silhouette or a depth jump is left alone.
    if (length(dPx) + length(dPy) > 0.06 * length(P) + 0.5) {
        gl_FragColor = scene;
        return;
    }
    vec3 n = cross(dPx, dPy);
    float nl = length(n);
    if (nl < 1e-9) {
        gl_FragColor = scene;
        return;
    }
    n /= nl;
    // Face the camera, which sits at the view-space origin.
    if (dot(n, P) > 0.0) n = -n;
    // Stains only land on ground-like surfaces: ones that face up in the world, not a worm's sides or a wall.
    vec3 nW = n * mat3(mg_view);
    float upward = smoothstep(0.35, 0.6, nW.y);
    if (upward <= 0.0) {
        gl_FragColor = scene;
        return;
    }

    float cov = 0.0, core = 0.0;
    Stain(P, p_stain0, p_stain0b, cov, core);
    Stain(P, p_stain1, p_stain1b, cov, core);
    Stain(P, p_stain2, p_stain2b, cov, core);
    Stain(P, p_stain3, p_stain3b, cov, core);
    Stain(P, p_stain4, p_stain4b, cov, core);
    Stain(P, p_stain5, p_stain5b, cov, core);
    Stain(P, p_stain6, p_stain6b, cov, core);
    Stain(P, p_stain7, p_stain7b, cov, core);
    cov *= p_strength * upward;
    if (cov <= 0.0) {
        gl_FragColor = scene;
        return;
    }

    // Multiplying keeps the surface's own detail: the blood stains the texture instead of covering it, and the core
    // goes darker and thicker than the rim.
    vec3 tint = p_blood / max(max(p_blood.r, p_blood.g), max(p_blood.b, 1e-3));
    vec3 soaked = scene.rgb * tint * mix(0.6, 0.3, core) + p_blood * 0.3 * (0.5 + core);
    gl_FragColor = vec4(mix(scene.rgb, soaked, cov), scene.a);
}
