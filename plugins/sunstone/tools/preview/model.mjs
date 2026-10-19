#!/usr/bin/env node
// Offline preview of Sunstone's lit-model shader (dev tool, not packed): renders a game texture from the texture
// inventory on a box, sphere or plane in headless Chromium (WebGL2 on SwiftShader via Playwright), lit with a theme's
// light and a Quality preset's parameters (read from mod/shaders/params.ini and mod/client/init.lua), side by side:
//   game       the game's lighting (sunstoneLight 0)
//   sunstone   Sunstone's lighting without material detail (the baseline shader, sunstoneMatDetail 0)
//   candidate  the shader built now from tools/materials (python tools/build_materials.py --out <tmp>), with detail
// The texture's tag comes from the tag table built now (python tools/make_tag_table.py), so snippet defaults and
// overrides take effect at once. Nothing is written into the plugin. See tools/preview/README.md.
//
//   node tools/preview/model.mjs --id ee3d95 --shape box --theme ENGLAND --out /tmp/crate.png
//   node tools/preview/model.mjs --sheet ee3d95,548ff2,944413 --out /tmp/sheet.png
//   node tools/preview/model.mjs --sheet class:wood_planks --limit 12 --out /tmp/wood.png
//   node tools/preview/model.mjs --id ee3d95 --baseline /tmp/old.glsl --check-identical
// The shared material maps (mod/assets/detail/materials.png, or --maps f.png; --no-maps leaves the sampler neutral, as
// an unbound Melange sampler) are bound as a TEXTURE_2D_ARRAY on unit 8 to every sampler2DArray, as Melange does.
import { createRequire } from 'module';
import { execFileSync } from 'child_process';
import fs from 'fs';
import os from 'os';
import path from 'path';
import { fileURLToPath } from 'url';

const require = createRequire(import.meta.url);
const HERE = path.dirname(fileURLToPath(import.meta.url));
const PLUGIN = path.resolve(HERE, '..', '..');
const SHADERS = {
  texlit: path.join(PLUGIN, 'mod', 'shaders', 'FixedFunction.FFFragmentMainTexLit.glsl'),
  texlitcol: path.join(PLUGIN, 'mod', 'shaders', 'FixedFunction.FFFragmentMainTexLitCol.glsl'),
};

// ---------------------------------------------------------------- arguments
const argv = process.argv.slice(2);
const FLAGS = new Set(['check-identical', 'expect-untouched', 'untagged', 'time', 'help', 'no-labels', 'no-maps']);
const opt = {};
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (!a.startsWith('--')) { console.error(`unexpected argument ${a}`); process.exit(2); }
  const k = a.slice(2);
  if (FLAGS.has(k)) opt[k] = true;
  else if (k === 'set' || k === 'set-candidate') (opt[k] = opt[k] || []).push(argv[++i]);
  else opt[k] = argv[++i];
}
if (opt.help || (!opt.id && !opt.sheet)) {
  console.log(fs.readFileSync(fileURLToPath(import.meta.url), 'utf8').split('\n').filter((l) => l.startsWith('//')).slice(0, 17).join('\n')
    .replace(/^\/\/ ?/gm, '') + '\n\nOptions: see tools/preview/README.md ("Model preview").');
  process.exit(opt.help ? 0 : 2);
}
const num = (v, d) => (v === undefined ? d : +v);
const vec = (s) => s.split(',').map(Number);
const inventoryDir = opt.inventory || process.env.SUNSTONE_INVENTORY;
if (!inventoryDir) { console.error('pass --inventory <dir> or set SUNSTONE_INVENTORY (the folder with inventory.json and cache/)'); process.exit(2); }
const python = process.env.PYTHON || 'python';
const shaderKind = opt.shader || 'texlit';
if (!SHADERS[shaderKind]) { console.error('--shader is texlit or texlitcol'); process.exit(2); }

// ---------------------------------------------------------------- inventory
const inventory = JSON.parse(fs.readFileSync(path.join(inventoryDir, 'inventory.json'), 'utf8'));
const byId = new Map(inventory.map((e) => [e.id, e]));
function resolveId(p) {
  const hits = inventory.filter((e) => e.id.startsWith(p.toLowerCase()));
  if (hits.length !== 1) { console.error(`id ${p}: ${hits.length ? 'ambiguous (' + hits.map((h) => h.id).join(', ') + ')' : 'not in the inventory'}`); process.exit(2); }
  return hits[0].id;
}

// ---------------------------------------------------------------- params.ini and init.lua
function iniParams(section) {
  const out = {};
  let inSec = false;
  for (const raw of fs.readFileSync(path.join(PLUGIN, 'mod', 'shaders', 'params.ini'), 'utf8').split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith(';')) continue;
    if (line.startsWith('[')) { inSec = line === `[${section}]`; continue; }
    if (!inSec) continue;
    const m = line.match(/^(\w+)=(\w+),([^,]*),/);
    if (!m) continue;
    const vals = m[3].trim().split(/\s+/).map(Number);
    out[m[1]] = vals.length === 1 ? vals[0] : vals;
  }
  return out;
}

// A Lua table constructor (numbers, strings, booleans, nested tables) -> JS (array when it has only positional fields).
function luaTable(src, name) {
  const at = src.search(new RegExp(`local\\s+${name}\\s*=\\s*\\{`));
  if (at < 0) throw new Error(`init.lua: no table ${name}`);
  let i = src.indexOf('{', at);
  const skip = () => {
    for (;;) {
      while (i < src.length && /\s/.test(src[i])) i++;
      if (src.startsWith('--[[', i)) { i = src.indexOf(']]', i) + 2; continue; }
      if (src.startsWith('--', i)) { while (i < src.length && src[i] !== '\n') i++; continue; }
      return;
    }
  };
  const value = () => {
    skip();
    if (src[i] === '{') return table();
    if (src[i] === '"' || src[i] === "'") { const q = src[i]; const j = src.indexOf(q, i + 1); const s = src.slice(i + 1, j); i = j + 1; return s; }
    const m = /^(-?[0-9.]+(?:e-?\d+)?|true|false|nil)/.exec(src.slice(i, i + 40));
    if (!m) throw new Error(`init.lua ${name}: cannot read value at ${src.slice(i, i + 30)}`);
    i += m[0].length;
    return m[0] === 'true' ? true : m[0] === 'false' ? false : m[0] === 'nil' ? null : Number(m[0]);
  };
  const table = () => {
    i++; // {
    const arr = [], obj = {};
    let keyed = false;
    for (;;) {
      skip();
      if (src[i] === '}') { i++; break; }
      const km = /^([A-Za-z_]\w*)\s*=(?!=)/.exec(src.slice(i, i + 80));
      if (km) { i += km[0].length; obj[km[1]] = value(); keyed = true; } else arr.push(value());
      skip();
      if (src[i] === ',' || src[i] === ';') i++;
    }
    if (!keyed) return arr;
    arr.forEach((v, k) => { obj[k + 1] = v; });
    return obj;
  };
  return table();
}

const lua = fs.readFileSync(path.join(PLUGIN, 'mod', 'client', 'init.lua'), 'utf8');
const PRESETS = luaTable(lua, 'PRESETS');
PRESETS.ultra = PRESETS.bold; // init.lua: Ultra is Bold supersampled (its lighting is Bold's)
const THEMES = luaTable(lua, 'THEMES');
const DEFAULT_THEME = luaTable(lua, 'DEFAULT_THEME');
const BASE = luaTable(lua, 'BASE');

const quality = (opt.quality || 'bold').toLowerCase();
const preset = PRESETS[quality];
if (!preset) { console.error(`--quality: one of ${Object.keys(PRESETS).join(', ')}`); process.exit(2); }
const themeName = opt.theme ? opt.theme.toUpperCase() : null;
if (themeName && !THEMES[themeName]) { console.error(`--theme: one of ${Object.keys(THEMES).join(', ')}`); process.exit(2); }
const theme = themeName ? THEMES[themeName] : DEFAULT_THEME;

// The model parameters as applyLighting / applySkin in init.lua send them (the rest are params.ini's defaults).
function modelParams() {
  const p = iniParams('FixedFunction.cg:FFFragmentMain*Lit*');
  const l = preset.lighting || {};
  const k = l.hemisphere || 1;
  const spread = (t) => t.map((x) => 1 + (x - 1) * k);
  const green = (theme.foliage ?? 1) * (preset.foliage ?? 1);
  Object.assign(p, {
    sunstoneLight: l.light || 0,
    sunstoneRim: l.modelRim || 0,
    sunstoneSky: spread(theme.sky),
    sunstoneGround: spread(theme.ground),
    sunstoneSunGain: l.modelSunGain || 1,
    sunstoneAmbientGain: l.modelAmbientGain || 1,
    sunstoneTint: (l.tint || 0) * (theme.tint ?? 1),
    sunstoneGroundDip: l.groundDip || 0,
    sunstoneFoliage: (l.leaves || 0) * green,
    sunstoneMatDetail: opt.materials === 'off' ? 0 : (l.matDetail || 0),
    sunstoneSkin: 0, sunstoneHair: 0, sunstoneSkinMixed: 0,
    sunstoneSkinChroma: theme.skinChroma ?? 0.35,
    sunstoneSkinShade: theme.skinShade ?? 1,
    sunstoneSkinAmbient: theme.skinAmbient || [1, 1, 1],
    sunstoneSkinVivid: theme.skinVivid ?? 1,
  });
  return p;
}
const sets = (list) => Object.fromEntries((list || []).flatMap((s) => s.split(';')).filter(Boolean).map((kv) => {
  const [k, v] = kv.split('=');
  const vs = v.split(/[ ,]+/).map(Number);
  return [k.trim(), vs.length === 1 ? vs[0] : vs];
}));

// ---------------------------------------------------------------- shaders and tags (built now, in a temp folder)
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'sunstone-model-'));
function py(args) {
  try {
    return execFileSync(python, args, { cwd: PLUGIN, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
  } catch (e) {
    console.error(`${python} ${args.join(' ')} failed:\n${e.stderr || e.message}`);
    process.exit(1);
  }
}
let candidatePath = opt.candidate;
const tablePath = path.join(tmp, 'classes.json');
if (!candidatePath) {
  candidatePath = path.join(tmp, 'candidate.glsl');
  py([path.join('tools', 'build_materials.py'), shaderKind === 'texlit' ? '--out' : '--out-col', candidatePath, '--table', tablePath]);
} else {
  py([path.join('tools', 'build_materials.py'), '--out', path.join(tmp, 'unused.glsl'), '--table', tablePath]);
}
const classTable = JSON.parse(fs.readFileSync(tablePath, 'utf8'));
// The shared material maps: a vertical strip of square layers (layer 0 at the top) as raw RGBA, decoded by Pillow so
// no browser colour handling or alpha premultiplication touches the data. Melange uploads the PNG's top row at v = 0.
const MAP_UNIT = 8;
let maps = null;
if (!opt['no-maps']) {
  const mapsPng = path.resolve(opt.maps || path.join(PLUGIN, 'mod', 'assets', 'detail', 'materials.png'));
  if (fs.existsSync(mapsPng)) {
    const raw = path.join(tmp, 'maps.rgba');
    const dims = py(['-c', 'import sys; from PIL import Image; im = Image.open(sys.argv[1]).convert("RGBA"); '
      + 'open(sys.argv[2], "wb").write(im.tobytes()); print(im.width, im.height)', mapsPng, raw]).trim().split(/\s+/).map(Number);
    const layers = Math.round(dims[1] / dims[0]);
    maps = { w: dims[0], h: dims[1] / layers, layers, b64: fs.readFileSync(raw).toString('base64') };
  } else console.error(`no material maps at ${mapsPng}: the sampler stays neutral`);
}
const classByName = new Map(classTable.classes.map((c) => [c.name, c]));
const baselinePath = opt.baseline || SHADERS[shaderKind];
let tagsById = {};
if (!opt.untagged && !opt.tags) {
  const byIdPath = path.join(tmp, 'tags-by-id.json');
  py([path.join('tools', 'make_tag_table.py'), '--inventory', inventoryDir, '--out', path.join(tmp, 'texture_tags.json'), '--by-id', byIdPath, '--quiet']);
  tagsById = JSON.parse(fs.readFileSync(byIdPath, 'utf8'));
} else if (opt.tags) {
  tagsById = JSON.parse(fs.readFileSync(opt.tags, 'utf8'));
}
function tagFor(id) {
  // mg_texTag as Melange would send it: [class, scale, strength, rough], [wear, tint, a, b]; zero = untagged.
  let row = null, src = 'untagged';
  if (opt.tag) { row = vec(opt.tag); src = 'tag'; }
  else if (opt.class) {
    const c = classByName.get(opt.class);
    if (!c || c.id === 0) { console.error(`--class: one of ${classTable.classes.slice(1).map((x) => x.name).join(', ')}`); process.exit(2); }
    row = [c.id, ...classTable.params.map((k) => c.defaults[k])]; src = `class ${c.name} (defaults)`;
  } else if (!opt.untagged && tagsById[id]) { row = tagsById[id].tag; src = tagsById[id].cls; }
  const t = row ? row.concat(Array(8).fill(0)).slice(0, 8) : Array(8).fill(0);
  return { t, src };
}

// GLSL 1.20 (Melange's replacements) -> GLSL ES 3.00; #line keeps error lines those of the source.
function toEs(src) {
  const body = src.replace(/^#version.*$/m, '')
    .replace(/\btexture2D\b/g, 'texture')
    .replace(/\bgl_FragColor\b/g, 'mg_FragColor')
    .replace(/\bgl_TexCoord\b/g, 'v_tc')
    .replace(/\bgl_Color\b/g, 'v_col');
  return '#version 300 es\nprecision highp float;\nprecision highp int;\nprecision highp sampler2DArray;\nin vec4 v_tc[4];\nin vec4 v_col;\nout vec4 mg_FragColor;\n#line 1\n' + body;
}
const VS = `#version 300 es
in vec3 aPos; in vec3 aNrm; in vec2 aUv;
uniform mat4 view, proj; uniform vec3 toSunEye;
out vec4 v_tc[4]; out vec4 v_col;
void main() {
  vec4 e = view * vec4(aPos, 1.0);
  v_tc[0] = vec4(aUv, 0.0, 1.0); v_tc[1] = vec4(-e.xyz, 1.0); v_tc[2] = vec4(mat3(view) * aNrm, 0.0);
  v_tc[3] = vec4(-toSunEye, 0.0); v_col = vec4(1.0);
  gl_Position = proj * e;
}`;

// ---------------------------------------------------------------- rows and panels
let ids;
if (opt.sheet) {
  if (opt.sheet.startsWith('class:')) {
    const want = opt.sheet.slice(6);
    ids = Object.keys(tagsById).filter((k) => tagsById[k].cls === want).sort();
    if (!ids.length) { console.error(`no texture of class ${want} in the tag table`); process.exit(2); }
  } else if (opt.sheet.startsWith('@')) {
    ids = fs.readFileSync(opt.sheet.slice(1), 'utf8').split(/[\s,]+/).filter(Boolean).map(resolveId);
  } else ids = opt.sheet.split(',').filter(Boolean).map(resolveId);
  if (opt.limit) ids = ids.slice(0, +opt.limit);
} else ids = [resolveId(opt.id)];

const base = modelParams();
const common = sets(opt.set);
const candSet = sets(opt['set-candidate']);
const detailOn = opt.detail !== undefined ? +opt.detail : (base.sunstoneMatDetail || 1);
let panels;
if (opt['check-identical']) {
  // Detail off must give exactly the baseline: off by the switch, off by the split, and the game's lighting.
  panels = [
    { name: 'baseline sunstone', shader: 'baseline', set: { sunstoneMatDetail: 0 } },
    { name: 'candidate detail 0', shader: 'candidate', set: { sunstoneMatDetail: 0 }, ref: 0 },
    { name: 'candidate split', shader: 'candidate', set: { sunstoneMatDetail: detailOn, sunstoneMatSplit: 100000 }, ref: 0 },
    { name: 'baseline game', shader: 'baseline', set: { sunstoneLight: 0 } },
    { name: 'candidate game', shader: 'candidate', set: { sunstoneLight: 0, sunstoneMatDetail: detailOn }, ref: 3 },
  ];
  // --expect-untouched: detail on must leave these textures alone too (the worm's own material, skin, hair).
  if (opt['expect-untouched']) panels.push({ name: 'candidate detail on', shader: 'candidate', set: { sunstoneMatDetail: detailOn }, ref: 0 });
} else {
  const all = {
    game: { name: 'game lighting', shader: 'baseline', set: { sunstoneLight: 0 } },
    sunstone: { name: 'Sunstone (no detail)', shader: 'baseline', set: { sunstoneMatDetail: 0 } },
    candidate: { name: `candidate (detail ${detailOn})`, shader: 'candidate', set: { sunstoneMatDetail: detailOn, ...candSet } },
  };
  panels = (opt.panels || 'game,sunstone,candidate').split(',').map((k) => {
    if (!all[k]) { console.error('--panels: game, sunstone, candidate'); process.exit(2); }
    return all[k];
  });
}

const rows = ids.map((id) => {
  const e = byId.get(id);
  const tag = tagFor(id);
  const m = e.material;
  return {
    id, name: e.name, size: e.size, tag: tag.t, tagSrc: tag.src,
    png: 'data:image/png;base64,' + fs.readFileSync(path.join(inventoryDir, 'cache', id + '.png')).toString('base64'),
    material: [...m.specular, 0, ...m.emissive, 0, ...m.rim, 0, m.rim_power, m.gloss, 0, 0],
  };
});

const scene = {
  shape: opt.shape || 'box',
  world: num(opt.world, 20),               // object size, world units (a crate is about 20; a worm's head 12)
  density: opt.density ? +opt.density : null, // texels per world unit (default: the texture once per face)
  dist: opt.dist ? +opt.dist : null,       // camera distance, world units (default 2.6 x size)
  yaw: num(opt.yaw, 32), pitch: num(opt.pitch, 22), fov: num(opt.fov, 40),
  px: num(opt.px, 320),
  sun: opt.sun ? vec(opt.sun) : (theme.sunDir || BASE.hdr.sunDir),
  diffuse: opt.diffuse ? vec(opt.diffuse) : [0.85, 0.82, 0.75],
  ambient: opt.ambient ? vec(opt.ambient) : [0.42, 0.42, 0.46],
  specular: opt.specular ? vec(opt.specular) : [1, 1, 1],
  labels: !opt['no-labels'],
  time: !!opt.time || !!opt['check-identical'],
  check: !!opt['check-identical'],
};

// ---------------------------------------------------------------- render
let playwright;
for (const p of [process.env.PLAYWRIGHT, 'playwright', '/opt/node-tools/node_modules/playwright', '/opt/node22/lib/node_modules/playwright'].filter(Boolean)) {
  try { playwright = require(p); break; } catch { /* next */ }
}
if (!playwright) { console.error('playwright not found (npm i playwright, or set PLAYWRIGHT to its package folder)'); process.exit(2); }
const launchArgs = ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'];
let browser;
try { browser = await playwright.chromium.launch({ args: launchArgs }); } catch (e) {
  browser = await playwright.chromium.launch({ args: launchArgs, executablePath: process.env.PREVIEW_CHROMIUM });
}
const page = await browser.newPage();
await page.setContent('<canvas id=g></canvas><canvas id=s></canvas>');
const shaders = { baseline: toEs(fs.readFileSync(baselinePath, 'utf8')), candidate: toEs(fs.readFileSync(candidatePath, 'utf8')) };
const res = await page.evaluate(async ({ VS, shaders, rows, panels, base, common, scene, maps, MAP_UNIT }) => {
  const S = scene.px;
  const gc = document.getElementById('g');
  gc.width = S; gc.height = S;
  const gl = gc.getContext('webgl2', { preserveDrawingBuffer: true, antialias: false });
  const aniso = gl.getExtension('EXT_texture_filter_anisotropic');
  const compile = (type, src, label) => {
    const o = gl.createShader(type); gl.shaderSource(o, src); gl.compileShader(o);
    if (!gl.getShaderParameter(o, gl.COMPILE_STATUS)) throw new Error(`${label}: ${gl.getShaderInfoLog(o)}`);
    return o;
  };
  const progs = {};
  for (const [k, src] of Object.entries(shaders)) {
    const p = gl.createProgram();
    gl.attachShader(p, compile(gl.VERTEX_SHADER, VS, 'vertex'));
    gl.attachShader(p, compile(gl.FRAGMENT_SHADER, src, k + ' shader'));
    gl.bindAttribLocation(p, 0, 'aPos'); gl.bindAttribLocation(p, 1, 'aNrm'); gl.bindAttribLocation(p, 2, 'aUv');
    gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(`${k} link: ${gl.getProgramInfoLog(p)}`);
    const uniforms = [];
    for (let i = 0, n = gl.getProgramParameter(p, gl.ACTIVE_UNIFORMS); i < n; i++) {
      const u = gl.getActiveUniform(p, i);
      uniforms.push({ name: u.name.replace(/\[0\]$/, ''), type: u.type, size: u.size, loc: gl.getUniformLocation(p, u.name) });
    }
    progs[k] = { p, uniforms };
  }

  // Geometry: P, N, UV for a texture of tw texels across at scene.density texels per world unit.
  const geometry = (tw) => {
    const P = [], N = [], U = [], I = [], W = scene.world, h = W / 2;
    const rep = scene.density ? W * scene.density / tw : 1;
    if (scene.shape === 'sphere') {
      const SL = 64, R = 32, ru = Math.max(1, Math.round(rep * Math.PI)), rv = rep * Math.PI / 2;
      for (let i = 0; i <= R; i++) for (let j = 0; j <= SL; j++) {
        const th = Math.PI * i / R, ph = 2 * Math.PI * j / SL;
        const x = Math.sin(th) * Math.cos(ph), y = Math.cos(th), z = Math.sin(th) * Math.sin(ph);
        P.push(x * h, y * h, z * h); N.push(x, y, z); U.push(j / SL * ru, (1 - i / R) * rv);
      }
      for (let i = 0; i < R; i++) for (let j = 0; j < SL; j++) { const a = i * (SL + 1) + j, b = a + SL + 1; I.push(a, b, a + 1, b, b + 1, a + 1); }
    } else {
      const faces = scene.shape === 'plane' ? [[0, 0, 1]] : [[0, 0, 1], [0, 0, -1], [1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0]];
      for (const n of faces) {
        const up = Math.abs(n[1]) > 0.5 ? [0, 0, -n[1]] : [0, 1, 0];
        const t = [up[1] * n[2] - up[2] * n[1], up[2] * n[0] - up[0] * n[2], up[0] * n[1] - up[1] * n[0]];
        const b0 = P.length / 3, d = scene.shape === 'plane' ? 0 : h;
        for (const [s, r] of [[-1, -1], [1, -1], [1, 1], [-1, 1]]) {
          P.push(n[0] * d + (s * t[0] + r * up[0]) * h, n[1] * d + (s * t[1] + r * up[1]) * h, n[2] * d + (s * t[2] + r * up[2]) * h);
          N.push(...n); U.push((s + 1) / 2 * rep, (r + 1) / 2 * rep);
        }
        I.push(b0, b0 + 1, b0 + 2, b0, b0 + 2, b0 + 3);
      }
    }
    return { P, N, U, I };
  };
  const vao = gl.createVertexArray();
  gl.bindVertexArray(vao);
  const bufs = [gl.createBuffer(), gl.createBuffer(), gl.createBuffer()], ib = gl.createBuffer();
  const upload = (g) => {
    [[g.P, 3], [g.N, 3], [g.U, 2]].forEach(([data, n], k) => {
      gl.bindBuffer(gl.ARRAY_BUFFER, bufs[k]); gl.bufferData(gl.ARRAY_BUFFER, new Float32Array(data), gl.STATIC_DRAW);
      gl.enableVertexAttribArray(k); gl.vertexAttribPointer(k, n, gl.FLOAT, false, 0, 0);
    });
    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, ib); gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, new Uint16Array(g.I), gl.STATIC_DRAW);
    return g.I.length;
  };

  // Camera: yaw/pitch around the object, looking at its centre; view = world -> eye, as the game's.
  const norm = (v) => { const l = Math.hypot(...v); return v.map((x) => x / l); };
  const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
  const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
  const D = scene.dist || scene.world * 2.6, ya = scene.yaw * Math.PI / 180, pa = scene.pitch * Math.PI / 180;
  const eye = [D * Math.sin(ya) * Math.cos(pa), D * Math.sin(pa), D * Math.cos(ya) * Math.cos(pa)];
  const f = norm(eye.map((x) => -x)), s = norm(cross(f, [0, 1, 0])), u = cross(s, f);
  const view = [s[0], u[0], -f[0], 0, s[1], u[1], -f[1], 0, s[2], u[2], -f[2], 0, -dot(s, eye), -dot(u, eye), dot(f, eye), 1];
  const fy = 1 / Math.tan(scene.fov * Math.PI / 360), zn = 1, zf = D * 4;
  const proj = [fy, 0, 0, 0, 0, fy, 0, 0, 0, 0, (zf + zn) / (zn - zf), -1, 0, 0, 2 * zf * zn / (zn - zf), 0];
  const sw = norm(scene.sun);
  const toSunEye = [s, u, f.map((x) => -x)].map((r) => dot(r, sw));

  // The material maps on unit MAP_UNIT: a TEXTURE_2D_ARRAY with Melange's mips (plain 2x2 averages of the bytes,
  // rounded), trilinear, repeat, anisotropy 16; without maps a neutral 1x1 (0.502), as Melange's unbound sampler.
  {
    const mt = gl.createTexture();
    gl.activeTexture(gl.TEXTURE0 + MAP_UNIT);
    gl.bindTexture(gl.TEXTURE_2D_ARRAY, mt);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
    if (maps) {
      const bin = atob(maps.b64);
      let lv = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) lv[i] = bin.charCodeAt(i);
      let w = maps.w, h = maps.h, level = 0;
      for (;;) {
        gl.texImage3D(gl.TEXTURE_2D_ARRAY, level, gl.RGBA8, w, h, maps.layers, 0, gl.RGBA, gl.UNSIGNED_BYTE, lv);
        if (w === 1 && h === 1) break;
        const nw = Math.max(1, w >> 1), nh = Math.max(1, h >> 1), nx = new Uint8Array(nw * nh * maps.layers * 4);
        const at = (l, xx, yy, c) => lv[((l * h + yy) * w + xx) * 4 + c];
        for (let l = 0; l < maps.layers; l++) for (let y = 0; y < nh; y++) for (let x = 0; x < nw; x++) {
          const x0 = Math.min(2 * x, w - 1), x1 = Math.min(2 * x + 1, w - 1), y0 = Math.min(2 * y, h - 1), y1 = Math.min(2 * y + 1, h - 1);
          for (let c = 0; c < 4; c++) {
            nx[((l * nh + y) * nw + x) * 4 + c] = Math.floor((at(l, x0, y0, c) + at(l, x1, y0, c) + at(l, x0, y1, c) + at(l, x1, y1, c)) / 4 + 0.5);
          }
        }
        lv = nx; w = nw; h = nh; level++;
      }
      gl.texParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
      if (aniso) gl.texParameterf(gl.TEXTURE_2D_ARRAY, aniso.TEXTURE_MAX_ANISOTROPY_EXT, 16);
    } else {
      gl.texImage3D(gl.TEXTURE_2D_ARRAY, 0, gl.RGBA8, 1, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array([128, 128, 128, 128]));
      gl.texParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    }
    gl.texParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_WRAP_S, gl.REPEAT);
    gl.texParameteri(gl.TEXTURE_2D_ARRAY, gl.TEXTURE_WRAP_T, gl.REPEAT);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 4);
    gl.activeTexture(gl.TEXTURE0);
  }

  const setUniforms = (prog, values) => {
    for (const un of prog.uniforms) {
      let v = values[un.name];
      if (un.type === gl.SAMPLER_2D) { gl.uniform1i(un.loc, 0); continue; }
      if (un.type === gl.SAMPLER_2D_ARRAY) { gl.uniform1i(un.loc, MAP_UNIT); continue; }
      if (v === undefined) continue; // as in Melange: an unknown uniform stays 0
      if (!Array.isArray(v)) v = [v];
      switch (un.type) {
        case gl.FLOAT: gl.uniform1fv(un.loc, v.slice(0, un.size)); break;
        case gl.FLOAT_VEC2: gl.uniform2fv(un.loc, v.slice(0, 2 * un.size)); break;
        case gl.FLOAT_VEC3: gl.uniform3fv(un.loc, v.slice(0, 3 * un.size)); break;
        case gl.FLOAT_VEC4: gl.uniform4fv(un.loc, v.concat(Array(4 * un.size).fill(0)).slice(0, 4 * un.size)); break;
        case gl.FLOAT_MAT3: gl.uniformMatrix3fv(un.loc, false, v); break;
        case gl.FLOAT_MAT4: gl.uniformMatrix4fv(un.loc, false, v); break;
        case gl.INT: case gl.BOOL: gl.uniform1i(un.loc, v[0]); break;
        default: break;
      }
    }
  };

  const LH = scene.labels ? 34 : 0, TH = scene.labels ? 18 : 0;
  const sheet = document.getElementById('s');
  sheet.width = S * panels.length; sheet.height = TH + rows.length * (S + LH);
  const ctx = sheet.getContext('2d');
  ctx.fillStyle = '#1b1d22'; ctx.fillRect(0, 0, sheet.width, sheet.height);
  ctx.font = '12px sans-serif'; ctx.fillStyle = '#e8e8e8';
  if (scene.labels) panels.forEach((p, k) => ctx.fillText(p.name, k * S + 6, 13));
  const stats = [];
  const tex = gl.createTexture();
  for (let r = 0; r < rows.length; r++) {
    const row = rows[r];
    const img = new Image(); img.src = row.png; await img.decode();
    gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, tex);
    // The engine uploads the XImage's first row at v = 0; the cache PNG is stored top row first.
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, img);
    gl.generateMipmap(gl.TEXTURE_2D);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT); gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT);
    if (aniso) gl.texParameterf(gl.TEXTURE_2D, aniso.TEXTURE_MAX_ANISOTROPY_EXT, 16);
    const count = upload(geometry(row.size[0]));
    const pixels = [];
    for (let k = 0; k < panels.length; k++) {
      const pn = panels[k], prog = progs[pn.shader];
      gl.useProgram(prog.p);
      setUniforms(prog, {
        ...base, ...common, ...pn.set, view, proj, toSunEye, materialMatrix: row.material, mg_texTag: row.tag,
        lightDiffuseCol: scene.diffuse, lightAmbientCol: scene.ambient, lightSpecularCol: scene.specular,
      });
      gl.enable(gl.DEPTH_TEST); gl.viewport(0, 0, S, S);
      gl.clearColor(0.24, 0.27, 0.31, 1);
      const draw = () => { gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT); gl.drawElements(gl.TRIANGLES, count, gl.UNSIGNED_SHORT, 0); };
      draw();
      const px = new Uint8Array(S * S * 4);
      let ms = null;
      if (scene.time) {
        gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array(4));
        const t0 = performance.now();
        for (let n = 0; n < 4; n++) draw();
        gl.readPixels(0, 0, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array(4));
        ms = (performance.now() - t0) / 4;
      }
      gl.readPixels(0, 0, S, S, gl.RGBA, gl.UNSIGNED_BYTE, px);
      pixels.push(px);
      const st = { row: row.id, panel: pn.name, ms, err: gl.getError() };
      if (scene.check && pn.ref !== undefined) {
        const a = pixels[pn.ref];
        let max = 0, diff = 0;
        for (let i = 0; i < px.length; i++) { const d = Math.abs(px[i] - a[i]); if (d) { diff++; if (d > max) max = d; } }
        st.maxDiff = max; st.diffValues = diff; st.ref = panels[pn.ref].name;
      }
      stats.push(st);
      ctx.drawImage(gc, k * S, TH + r * (S + LH));
    }
    if (scene.labels) {
      const y = TH + r * (S + LH) + S;
      ctx.fillStyle = '#e8e8e8';
      ctx.fillText(`${row.id}  ${row.name}`.slice(0, Math.floor(sheet.width / 6.5)), 6, y + 14);
      ctx.fillStyle = '#9aa0aa';
      ctx.fillText(`${row.size[0]}x${row.size[1]}  tag ${row.tagSrc}: [${row.tag.map((x) => +x.toFixed(3)).join(', ')}]`, 6, y + 28);
    }
  }
  return { png: sheet.toDataURL('image/png'), stats };
}, { VS, shaders, rows, panels, base, common, scene, maps, MAP_UNIT }).catch((e) => ({ error: String(e) }));
await browser.close();
fs.rmSync(tmp, { recursive: true, force: true });
if (res.error) {
  console.error(res.error.slice(0, 4000));
  process.exit(1);
}
const out = opt.out || path.join(os.tmpdir(), 'sunstone-model.png');
fs.mkdirSync(path.dirname(path.resolve(out)), { recursive: true });
fs.writeFileSync(out, Buffer.from(res.png.split(',')[1], 'base64'));
console.log(`wrote ${out} (${rows.length} texture${rows.length > 1 ? 's' : ''} x ${panels.length} panels; quality ${quality}, theme ${themeName || 'default'})`);
let bad = 0;
for (const s of res.stats) {
  const parts = [`${s.row} ${s.panel}`];
  if (s.ms !== null) parts.push(`${s.ms.toFixed(1)} ms/draw on SwiftShader (CPU, relative only)`);
  if (s.maxDiff !== undefined) {
    parts.push(s.maxDiff ? `DIFFERS from ${s.ref}: ${s.diffValues} values, up to ${s.maxDiff}/255` : `identical to ${s.ref}`);
    if (s.maxDiff) bad++;
  }
  if (s.err) parts.push(`glError ${s.err}`);
  if (parts.length > 1) console.log('  ' + parts.join('; '));
}
if (scene.check) {
  console.log(bad ? `check-identical: ${bad} panel(s) differ` : 'check-identical: all identical');
  process.exit(bad ? 1 : 0);
}
