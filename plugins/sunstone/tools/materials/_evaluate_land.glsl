// ---- _evaluate_land.glsl: material detail on the landscape (after the generated MatDispatchLand). The landscape's
// counterpart of _evaluate.glsl: spliced with _common.glsl and the landscape's classes only (build_materials.py
// LANDSCAPE_CLASSES) into mod/shaders/Landscape.LandscapeFragmentMain.glsl and Landscape.HeightMapFragmentMain.glsl.
//
// The landscape draws its chunks one theme tile at a time (top, side and blend layers are separate draws, the blends
// alpha-blended over), so Melange's mg_texTag of a draw is that tile's tag. Its UVs are planar projections on the world
// axes, one tile 40 to 150 world units across, so the snippets' world-unit sizes hold as they do on models. A tile with
// no tag, or of a class not in LANDSCAPE_CLASSES, keeps Sunstone's World detail alone.

uniform float sunstoneMatFade;     // landscape: distance (world units) at which material detail has faded out

// For the debug views: the class drawn (0 none), its weight, normal detail and cavity.
int matClass = 0;
float matDbgFade = 0.0;
vec3 matDbgDn = vec3(0.0);
float matDbgAo = 1.0;

// Uniform: whether material detail runs at all (Sunstone's lighting on, not its grey view).
bool MatEnabled() {
    return sunstoneMatDetail > 0.0 && sunstoneLight > 0.5 && !(sunstoneLight > 9.5 && sunstoneLight < 10.5);
}

// Uniform: this draw's landscape class, 0 when its tile has none.
int MatLandClass() {
    int c = int(floor(mg_texTag[0].x + 0.5));
    return MatLandHas(c) ? c : 0;
}

// The inputs for this fragment, as MatSetup gives them but only what the landscape's detail reads (lumD, aniso, pxWorld
// and wpos stay 0): its planar UVs never degenerate, so the fade is the distance (full to a third of sunstoneMatFade),
// the grazing angle and the A/B split. Call only in uniform control flow: it takes derivatives.
MatIn MatSetupLand(vec4 tex, vec2 uv) {
    MatIn m;
    m.albedo = tex.rgb;
    m.alpha = tex.a;
    m.uv = uv;
    m.uvDx = dFdx(uv);
    m.uvDy = dFdy(uv);
    m.uvPx = max(length(m.uvDx), length(m.uvDy));
    m.pos = -gl_TexCoord[1].xyz;
    m.wpos = vec3(0.0);
    m.n = normalize(gl_TexCoord[2].xyz);
    m.v = normalize(gl_TexCoord[1].xyz);
    m.l = normalize(-gl_TexCoord[3].xyz);
    vec3 up = view[1].xyz;
    m.up = dot(up, up) > 0.25 ? normalize(up) : m.l;
    m.ndl = dot(m.n, m.l);
    m.ndv = max(dot(m.n, m.v), 0.0);
    m.sky = dot(m.n, m.up) * 0.5 + 0.5;
    m.lumD = vec2(0.0);
    vec3 dpx = dFdx(m.pos), dpy = dFdy(m.pos);
    vec3 r1 = cross(dpy, m.n), r2 = cross(m.n, dpx);
    float det = dot(dpx, r1);
    det = abs(det) > 1e-20 ? det : 1e-20;
    m.gu = (r1 * m.uvDx.x + r2 * m.uvDy.x) / det;
    m.gv = (r1 * m.uvDx.y + r2 * m.uvDy.y) / det;
    float gu2 = dot(m.gu, m.gu), gv2 = dot(m.gv, m.gv);
    m.tu = gu2 > 1e-24 ? m.gu * inversesqrt(gu2) : normalize(cross(m.n, vec3(0.31, 0.95, 0.0)));
    m.tv = gv2 > 1e-24 ? m.gv * inversesqrt(gv2) : normalize(cross(m.tu, m.n));
    float areaW = length(cross(dpx, dpy));
    float areaUv = abs(m.uvDx.x * m.uvDy.y - m.uvDx.y * m.uvDy.x);
    m.uvPerWorld = max(sqrt(areaUv / max(areaW, 1e-24)), 1e-6);
    m.pxWorld = 0.0;
    m.aniso = 1.0;
    float reach = max(sunstoneMatFade, 1.0);
    m.fade = (1.0 - smoothstep(reach / 3.0, reach, length(m.pos))) * smoothstep(0.03, 0.2, m.ndv)
           * (gl_FragCoord.x < sunstoneMatSplit ? 0.0 : 1.0);
    m.scale = 1.0;
    m.strength = 1.0;
    m.p = vec4(0.0);
    m.seed = 0.0;
    m.tagged = 0.0;
    return m;
}

// The tag's class and parameters, the snippet's result, and that result scaled by the detail amount, the tag's
// strength and the fade, with the tag's roughness bias.
MatOut MatEvaluateLand(MatIn m, int c) {
    vec4 t0 = mg_texTag[0], t1 = mg_texTag[1];
    m.tagged = 1.0;
    m.scale = t0.y > 0.0 ? t0.y : 1.0;
    m.strength = max(t0.z, 0.0);
    m.p = t1;
    m.seed = MatHash12(vec2(t0.y * 13.1 + t1.x * 7.7 + t1.z * 3.3 + float(c), t0.z * 5.3 + t1.y * 11.9 + t1.w * 2.9));
    MatOut o = MatDispatchLand(c, m);
    o.dn *= min(1.0, 0.7 / max(length(o.dn), 1e-6));
    float k = clamp(sunstoneMatDetail * m.strength * m.fade, 0.0, 2.0);
    o.gloss *= exp2(-2.0 * t0.w);
    o.spec *= exp2(-t0.w);
    MatOut r;
    r.albedo = clamp(mix(m.albedo, o.albedo, k), 0.0, 1.0);
    r.spec = max(mix(1.0, o.spec, k), 0.0);
    r.gloss = max(mix(1.0, o.gloss, k), 0.05);
    r.dn = o.dn * k;
    r.ao = clamp(mix(1.0, o.ao, k), 0.0, 1.0);
    matClass = c;
    matDbgFade = k;
    matDbgDn = r.dn;
    matDbgAo = r.ao;
    return r;
}

// The debug views (sunstoneMatDebug), by the lit colour's brightness: 1 a colour per class (striped dark grey: the World
// detail alone); 2 the detail amount; 3 the normal detail; 4 the cavity.
vec3 MatDebugLand(vec3 col) {
    if (sunstoneMatDebug < 0.5) return col;
    float sh = 0.35 + 0.65 * clamp(MatLum(col) * 1.6, 0.0, 1.0);
    if (sunstoneMatDebug > 3.5) return vec3(matDbgAo);
    if (sunstoneMatDebug > 2.5) return matDbgDn * 4.0 + 0.5;
    if (sunstoneMatDebug > 1.5) return vec3(matDbgFade, 0.0, 0.0) + 0.15 * sh;
    if (matClass <= 0) return vec3(fract((gl_FragCoord.x + gl_FragCoord.y) / 12.0) < 0.5 ? 0.12 : 0.05) * sh;
    float id = float(matClass);
    vec3 c = (0.5 + 0.5 * cos(6.2831 * (fract(id * 7.0 / 26.0) + vec3(0.0, 0.33, 0.67)))) * (mod(id, 2.0) < 0.5 ? 0.6 : 1.0);
    return c * sh;
}
// ---- end _evaluate_land.glsl
