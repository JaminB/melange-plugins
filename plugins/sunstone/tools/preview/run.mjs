#!/usr/bin/env node
// Offline preview of Melange post-FX effects: renders a scenario (a synthetic WUM-like scene, or a real frame with faked
// depth) in headless Chromium/WebGL2 and runs real effect folders from the repo on it, in Melange's order.
// See README.md in this folder.
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SUNSTONE = path.resolve(HERE, '..', '..');
const PLUGINS = path.resolve(SUNSTONE, '..');

// ---------- CLI ----------
function usage(msg) {
  if (msg) console.error('error: ' + msg);
  console.error(`usage: node run.mjs --scenario <file.json> [--effects <dir>[,<dir>...]] --out <file.png>
  --effects       effect folders (…/mod/postfx/<effect>), comma-separated; relative to the cwd, plugins/sunstone or plugins/
  --out           output PNG (the frame after all effects)
  --stages        also write <out>.scene.png, <out>.depth.png and one PNG after each effect (and each full-size pass)
  --diff          also write <out>.diff.png: changed pixels amplified (x --gain, default 4), unchanged pixels dark grey
  --compare       also write <out>.compare.png: input | output side by side
  --param id:name=v1,v2,…   override a parameter after the scenario and the driver (repeatable)
  --size WxH      override the scenario's size
  --keep-order    run effects in the order given instead of Melange's (stage, order, id)
  --probe x,y     print input/output RGB at a pixel (top-left origin, repeatable)`);
  process.exit(2);
}
const argv = process.argv.slice(2);
const opt = { effects: [], params: [], probes: [] };
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  const next = () => { if (i + 1 >= argv.length) usage(a + ' needs a value'); return argv[++i]; };
  if (a === '--scenario') opt.scenario = next();
  else if (a === '--effects') opt.effects.push(...next().split(',').map((s) => s.trim()).filter(Boolean));
  else if (a === '--out') opt.out = next();
  else if (a === '--stages') opt.stages = true;
  else if (a === '--diff') opt.diff = true;
  else if (a === '--gain') opt.gain = parseFloat(next());
  else if (a === '--compare') opt.compare = true;
  else if (a === '--keep-order') opt.keepOrder = true;
  else if (a === '--param') opt.params.push(next());
  else if (a === '--size') opt.size = next().split('x').map(Number);
  else if (a === '--probe') opt.probes.push(next().split(',').map(Number));
  else if (a === '-h' || a === '--help') usage();
  else usage('unknown argument ' + a);
}
if (!opt.scenario || !opt.out) usage('--scenario and --out are required');

// ---------- ini ----------
function parseIni(text) {
  const sections = [];
  let cur = null;
  for (let raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith(';') || line.startsWith('#')) continue;
    const m = line.match(/^\[(.+)\]\s*(;.*)?$/);
    if (m) { cur = { name: m[1].trim(), kv: {} }; sections.push(cur); continue; }
    const eq = line.indexOf('=');
    if (eq < 0 || !cur) continue;
    const k = line.slice(0, eq).trim();
    const v = line.slice(eq + 1).replace(/\s+;.*$/, '').trim();
    cur.kv[k] = v;
  }
  return sections;
}
const nums = (s) => String(s ?? '').split(/[,\s]+/).filter(Boolean).map((x) => (x === 'true' ? 1 : x === 'false' ? 0 : Number(x)));

// ---------- GLSL: Melange 1.20/1.30 -> GLSL ES 3.00 ----------
// Returns { source, mapError } where mapError rewrites "ERROR: 0:<line>" to the original file:line.
function expandIncludes(file, dir, seen = new Set()) {
  if (seen.has(file)) throw new Error('recursive #include of ' + file);
  seen.add(file);
  const lines = fs.readFileSync(file, 'utf8').split(/\r?\n/);
  const out = [];
  lines.forEach((l, i) => {
    const m = l.match(/^\s*#\s*include\s+"([^"]+)"/);
    if (m) {
      const inc = path.join(dir, m[1]);
      if (!fs.existsSync(inc)) throw new Error(`${path.basename(file)}:${i + 1}: #include "${m[1]}" not found in the effect folder`);
      out.push(...expandIncludes(inc, dir, new Set(seen)));
    } else out.push({ text: l, file: path.basename(file), line: i + 1 });
  });
  return out;
}
function translate(file, dir, defines) {
  const lines = expandIncludes(file, dir);
  let version = 120;
  const vi = lines.findIndex((l) => /^\s*#\s*version\b/.test(l.text));
  if (vi >= 0) { version = parseInt(lines[vi].text.match(/#\s*version\s+(\d+)/)[1], 10); lines.splice(vi, 1); }
  const head = [
    '#version 300 es',
    'precision highp float;',
    'precision highp int;',
    'precision highp sampler2D;',
    ...defines.map((d) => '#define ' + d.replace('=', ' ')),
  ];
  let body = lines.map((l) => l.text).join('\n');
  const usesFragColor = /\bgl_FragColor\b/.test(body);
  const usesFragData = /\bgl_FragData\s*\[\s*0\s*\]/.test(body);
  body = body
    .replace(/\b(varying|in)\s+(highp\s+|mediump\s+)?vec2\s+mg_uv\s*;/g, 'in vec2 mg_uv;')
    .replace(/\btexture2DLod\b/g, 'textureLod')
    .replace(/\btexture2DProj\b/g, 'textureProj')
    .replace(/\btexture2DGrad(ARB|EXT)?\b/g, 'textureGrad')
    .replace(/\btexture2D\b/g, 'texture')
    .replace(/\bgl_FragData\s*\[\s*0\s*\]/g, 'mg_FragColor')
    .replace(/\bgl_FragColor\b/g, 'mg_FragColor');
  if (usesFragColor || usesFragData) head.push('out vec4 mg_FragColor;');
  // 1.30+ shaders declare their own 'out vec4 x;' and that works as is in ES 3.00.
  const map = [...head.map(() => ({ file: '(preamble)', line: 0 })), ...lines];
  const source = head.join('\n') + '\n' + body;
  const mapError = (msg) => msg.replace(/(ERROR|WARNING): 0:(\d+)/g, (_, kind, n) => {
    const m = map[parseInt(n, 10) - 1];
    return m ? `${kind}: ${m.file}:${m.line}` : `${kind}: line ${n}`;
  });
  return { source, mapError, version };
}

// ---------- effects ----------
function resolveEffectDir(p) {
  for (const base of [process.cwd(), SUNSTONE, PLUGINS]) {
    const d = path.resolve(base, p);
    if (fs.existsSync(path.join(d, 'effect.ini'))) return d;
  }
  return null;
}
function modIdOf(effectDir) {
  const modDir = path.resolve(effectDir, '..', '..');
  try {
    const j = JSON.parse(fs.readFileSync(path.join(modDir, 'spice.json'), 'utf8'));
    if (j.id) return j.id;
  } catch { /* no manifest */ }
  return path.basename(path.basename(modDir) === 'mod' ? path.dirname(modDir) : modDir);
}
function loadEffect(dir) {
  const sections = parseIni(fs.readFileSync(path.join(dir, 'effect.ini'), 'utf8'));
  const effName = path.basename(dir);
  const id = modIdOf(dir) + '/' + effName;
  const eff = sections.find((s) => s.name === 'effect')?.kv || {};
  const params = {}, paramTypes = {}, textures = {}, passes = [];
  for (const s of sections) {
    if (s.name.startsWith('param.')) {
      const n = s.name.slice(6);
      paramTypes[n] = s.kv.type || 'float';
      params[n] = nums(s.kv.default);
      if (!params[n].length) params[n] = [0];
    } else if (s.name.startsWith('texture.')) {
      const n = s.name.slice(8);
      const f = path.join(dir, s.kv.file || '');
      if (!fs.existsSync(f)) throw new Error(`${id}: texture ${n} file ${s.kv.file} missing`);
      textures[n] = { data: 'data:image/png;base64,' + fs.readFileSync(f).toString('base64'), filter: s.kv.filter || 'linear', wrap: s.kv.wrap || 'clamp' };
    } else if (s.name.startsWith('pass.')) {
      const n = s.name.slice(5);
      const defines = (s.kv.defines || '').split(/[,\s]+/).filter(Boolean);
      const shaderFile = path.join(dir, s.kv.shader || '');
      if (!fs.existsSync(shaderFile)) throw new Error(`${id}: pass ${n} shader ${s.kv.shader} missing`);
      const t = translate(shaderFile, dir, defines);
      passes.push({
        name: n, shader: s.kv.shader, scale: s.kv.scale ? parseFloat(s.kv.scale) : 1, format: s.kv.format || 'rgba8',
        inputs: (s.kv.inputs || '').split(/[,\s]+/).filter(Boolean), source: t.source, mapErrorSrc: t.mapError,
      });
    }
  }
  if (!passes.length) throw new Error(`${id}: no [pass.*] sections`);
  return {
    id, dir, effName, title: eff.title || id, stage: eff.stage || 'PostWorld', order: parseFloat(eff.order || '0'),
    params, paramTypes, textures, passes,
  };
}

// ---------- scenario ----------
const scenarioPath = path.resolve(opt.scenario);
const scenario = JSON.parse(fs.readFileSync(scenarioPath, 'utf8'));
const mode = scenario.image ? 'image' : 'scene';
let [W, H] = opt.size || scenario.size || [960, 540];
if (![W, H].every((n) => Number.isInteger(n) && n > 0)) usage('size must be two positive integers, got ' + JSON.stringify([W, H]));
const renderScale = scenario.renderScale || 1;
W = Math.round(W * renderScale); H = Math.round(H * renderScale);
const CENTRE_Y = 12;      // body centre above the reported worm position (Bloodsand/Kindjal CENTRE_Y)
const SKINS = {           // a few vanilla-peach variations inside the range SkinTone() was measured on
  peach: [0.98, 0.64, 0.36], warm: [1.0, 0.6, 0.33], pale: [0.97, 0.68, 0.42],
};
// Sunstone's Worm skin tones (mod/client/init.lua SKIN.TONES, keep in step): a worm's "tone" draws its skin in that albedo
// and marks it in the scene's alpha (245/255) as Sunstone's model shader does, for Bloodsand and Kindjal to find; their
// drivers send the tone's brightness against the game's peach (0.703) as tone0..3.
const TONES = {
  fair: [0.92, 0.80, 0.73], light: [0.85, 0.73, 0.50], medium: [0.64, 0.46, 0.36], olive: [0.53, 0.47, 0.355],
  tan: [0.52, 0.38, 0.18], brown: [0.40, 0.26, 0.185], deep: [0.28, 0.18, 0.135],
};
const HATS = { none: 0, cowboy: 1, helmet: 2, beanie: 3, afro: 4, mohawk: 5, wig: 6 };   // 4..6 are hair (u_whairCol)
// Moustache colours. orange and brown are placed in the windows Bloodsand's MoustTone() was measured on, after the
// harness light (sun (0.72,0.69,0.64) + ambient 0.40 makes lit g/r ~0.97x and b/r ~0.94x of the albedo's):
//   orange: hue ~25 deg, saturation 0.80 (shade) .. 0.81 (sun); skin hue, above SkinTone's 0.76 limit.
//   brown:  g/r 0.775 (shade) .. 0.754 (sun), b/r 0.50 .. 0.47, dark (max 0.42 albedo): SkinTone's 'hole'.
//   black/grey/blond: not classified by Bloodsand (black fails the dark floor; blond lands inside SkinTone).
const HAIR_COLS = {
  orange: [0.85, 0.453, 0.17], brown: [0.42, 0.3255, 0.21], black: [0.075, 0.06, 0.05], darkbrown: [0.24, 0.155, 0.09],
  blond: [0.86, 0.70, 0.42], ginger: [0.80, 0.40, 0.15], auburn: [0.52, 0.22, 0.10], grey: [0.56, 0.55, 0.53],
};
const TASHES = { none: 0, walrus: 1, handlebar: 2 };
const HAIR_DEFAULT = { afro: 'black', mohawk: 'ginger', wig: 'blond' };
const colOf = (c, def) => Array.isArray(c) ? c : (HAIR_COLS[c] || HAIR_COLS[def]);
const wrapPi = (a) => { a = ((a + Math.PI) % (2 * Math.PI) + 2 * Math.PI) % (2 * Math.PI) - Math.PI; return a; };

const cam = Object.assign({ pos: [0, 40, 150], target: [0, 14, 0], fov: 40, near: 2, far: 4000 }, scenario.camera || {});
const lighting = Object.assign({
  sunDir: [-0.45, 0.75, 0.5], sunCol: [0.72, 0.69, 0.64], ambient: [0.40, 0.40, 0.41],
  skyTop: [0.32, 0.52, 0.85], skyHorizon: [0.80, 0.85, 0.90],
  groundColour: scenario.ground === 'grass' ? [0.36, 0.56, 0.22] : [0.86, 0.72, 0.50], groundNoise: 0.12,
}, scenario.lighting || {});

let backD = 0;
const worms = (scenario.worms || []).map((w, i) => {
  const o = Object.assign({ slot: i, alive: true, yaw: 0, hat: 'none', blood: 0, wound: 0, eye: 0, gut: 0, gutAz: 0, scorch: 0, acid: 0, acidSpread: 1 }, w);
  o.yaw = (o.yawDeg !== undefined ? o.yawDeg * Math.PI / 180 : o.yaw);
  o.heading = wrapPi(o.yaw);
  o.skinRGB = Array.isArray(o.skin) ? o.skin : SKINS[o.skin || 'peach'];
  const tone = Array.isArray(o.tone) ? o.tone : TONES[o.tone];
  o.mark = tone ? 1 : 0;
  o.toneLum = tone ? (0.299 * tone[0] + 0.587 * tone[1] + 0.114 * tone[2]) / 0.703 : 1;
  if (tone) o.skinRGB = tone;
  o.radius = o.radius || 5.6;
  if (o.hitFromDeg !== undefined && o.hitBin === undefined) {
    // Bloodsand: hitQ = 1 + floor((atan2(-dx,-dz) mod 2pi) / 2pi * 32) % 32 with (dx,dz) the hit's travel direction.
    const a = o.hitFromDeg * Math.PI / 180;
    o.hitBin = 1 + Math.floor((((a % (2 * Math.PI)) + 2 * Math.PI) % (2 * Math.PI)) / (2 * Math.PI) * 32) % 32;
  }
  o.hitBin = o.hitBin || 0;
  // Facial hair / hair headwear. tash: "orange" | "brown" | "black" | [r,g,b] (colour) with tashShape walrus|handlebar,
  // hairColour: a HAIR_COLS name or [r,g,b] for hat afro|mohawk|wig; hairStreak: strand texture strength (0..1).
  o.tash = o.tash || 'none';
  o.tashShape = o.tash === 'none' ? 'none' : (o.tashShape || 'walrus');
  o.tashRGB = o.tash === 'none' ? [0, 0, 0] : colOf(o.tash, 'brown');
  o.hairColour = HATS[o.hat] >= 4 ? (o.hairColour || HAIR_DEFAULT[o.hat]) : (o.hairColour || 'none');
  o.hairRGB = HATS[o.hat] >= 4 ? colOf(o.hairColour, HAIR_DEFAULT[o.hat]) : [0, 0, 0];
  o.hairStreak = o.hairStreak ?? 0.3;
  // Mouth (opt-in): "mouth": { "open": 0..1, "shape": "o" | "wide" | "grin", "teeth": bool, "lip": [r,g,b] }; open 0 is
  // a closed mouth (lips and a seam); no "mouth" field is the old face with no mouth. "vomit": 0..1 adds Bloodsand's
  // vomit droplets (scene-colour sprites) from the mouth; it needs a mouth.
  if (o.mouth) {
    const m = o.mouth === true ? {} : o.mouth;
    const shape = { o: 0, wide: 1, shout: 1, grin: 2 }[m.shape || 'o'] ?? 0;
    const lip = Array.isArray(m.lip) ? m.lip : o.skinRGB.map((v, k) => v * [0.90, 0.74, 0.92][k]);
    o.mouthV = [Math.max(0, Math.min(1, m.open ?? 0.6)), shape, m.teeth ? 1 : 0, 1];
    o.lipRGB = lip;
  }
  return o;
});
if (mode === 'image') {
  // A real frame: camera at the origin looking down -Z (view = identity). Each worm needs box: [x0,y0,x1,y1] in image
  // pixels (top-left origin); the body is put at the distance where WORM_H world units fill the box's height.
  const WORM_H = 30;
  const tanY = Math.tan(cam.fov * Math.PI / 360), aspect = W / H;
  for (const w of worms) {
    if (!w.box) throw new Error('image scenarios need a box per worm');
    const b = w.box.map((v) => v * renderScale);
    const hN = (b[3] - b[1]) / H * 2;
    const D = WORM_H / (hN * tanY);
    const cx = ((b[0] + b[2]) / 2 / W) * 2 - 1, cy = 1 - ((b[1] + b[3]) / 2 / H) * 2;
    const c = [cx * tanY * aspect * D, cy * tanY * D, -D];
    const wN = (b[2] - b[0]) / W * 2 * tanY * aspect * D;
    w.radius = Math.max(4, Math.min(7.5, wN * 0.45));
    w.centre = c;
    w.pos = [c[0], c[1] - CENTRE_Y, c[2]];
    backD = Math.max(backD, D + 80);
  }
  cam.far = Math.max(cam.far, backD * 3);
} else {
  for (const w of worms) w.centre = [w.pos[0], w.pos[1] + CENTRE_Y, w.pos[2]];
}

// ---------- effects + drivers ----------
const warnings = [];
let effects = [];
for (const e of opt.effects) {
  const dir = resolveEffectDir(e);
  if (!dir) { warnings.push(`WARN effect ${e} not found (no effect.ini): skipped`); continue; }
  try { effects.push(loadEffect(dir)); } catch (err) { warnings.push(`WARN ${e}: ${err.message}: skipped`); }
}
const STAGES = { PostWorld: 0, Final: 1 };
if (!opt.keepOrder) {
  effects.sort((a, b) => (STAGES[a.stage] ?? 0) - (STAGES[b.stage] ?? 0) || a.order - b.order || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
}

const ctxBase = { scenario, worms: worms.filter((w) => w.alive !== false), allWorms: worms, mode, wrapPi, CENTRE_Y };
for (const fx of effects) {
  const base = fx.effName.replace(/_u$/, '');
  const modid = fx.id.split('/')[0];
  const cands = [`${modid}.${fx.effName}.mjs`, `${modid}.${base}.mjs`].map((f) => path.join(HERE, 'drivers', f));
  const drvFile = cands.find((f) => fs.existsSync(f));
  let set = {};
  if (drvFile) {
    const mod = await import(pathToFileURL(drvFile).href);
    set = mod.default({ ...ctxBase, effect: fx, params: fx.params }) || {};
  } else if (fx.params.worm0 !== undefined) {
    warnings.push(`WARN no driver for ${fx.id} (tools/preview/drivers/${modid}.${base}.mjs): generic driver sets wormN = body centre of every living worm`);
    for (const w of ctxBase.worms) if (w.slot >= 0 && w.slot < 16) set['worm' + w.slot] = w.centre;
  }
  const over = Object.assign({}, (scenario.params || {})[fx.id] || {});
  for (const p of opt.params) {
    const m = p.match(/^([^:]+):([^=]+)=(.*)$/);
    if (!m) usage('bad --param ' + p);
    if (m[1] === fx.id) over[m[2]] = nums(m[3]);
  }
  for (const [k, v] of Object.entries({ ...set, ...over })) {
    if (fx.params[k] === undefined) { warnings.push(`WARN ${fx.id}: driver/scenario sets ${k}, which effect.ini does not declare (ignored, as Melange would)`); continue; }
    fx.params[k] = Array.isArray(v) ? v.map(Number) : typeof v === 'boolean' ? [v ? 1 : 0] : [Number(v)];
  }
}

// ---------- run ----------
const require = createRequire(import.meta.url);
let playwright;
for (const p of ['playwright', '/opt/node-tools/node_modules/playwright', '/opt/node22/lib/node_modules/playwright']) {
  try { playwright = require(p); break; } catch { /* next */ }
}
if (!playwright) { console.error('playwright not found (npm i playwright, or set NODE_PATH)'); process.exit(2); }
const launchArgs = ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--ignore-gpu-blocklist'];
let browser;
try { browser = await playwright.chromium.launch({ args: launchArgs }); } catch (e) {
  const exe = process.env.PREVIEW_CHROMIUM || '/opt/pw-browsers/chromium/chrome-linux/chrome';
  browser = await playwright.chromium.launch({ args: launchArgs, executablePath: exe });
}
const page = await browser.newPage();
await page.setContent('<!doctype html><html><body style="margin:0;background:#000"></body></html>');
await page.addScriptTag({ content: fs.readFileSync(path.join(HERE, 'page.js'), 'utf8') });

const job = {
  mode, width: W, height: H, camera: cam, lighting, backD, renderScale,
  time: scenario.time || 0, frame: scenario.frame || 0,
  sceneShader: fs.readFileSync(path.join(HERE, 'scene.frag'), 'utf8'),
  image: mode === 'image' ? 'data:image/png;base64,' + fs.readFileSync(path.resolve(path.dirname(scenarioPath), scenario.image)).toString('base64') : null,
  sceneWorms: worms.filter((w) => w.alive !== false).map((w) => ({
    centre: w.centre, yaw: w.yaw, skin: w.skinRGB, hat: HATS[w.hat] ?? 0, radius: w.radius, simple: mode === 'image',
    hairCol: w.hairRGB, tash: TASHES[w.tashShape] ?? 1, tashCol: w.tashRGB, streak: w.hairStreak,
    mouth: w.mouthV, lip: w.lipRGB, vomit: w.mouthV ? (w.vomit || 0) : 0, mark: w.mark,
  })),
  effects: effects.map((fx) => ({
    id: fx.id, params: fx.params, textures: fx.textures,
    passes: fx.passes.map((p) => ({ name: p.name, scale: p.scale, format: p.format, inputs: p.inputs, source: p.source })),
  })),
  stages: !!opt.stages, diff: !!opt.diff, diffGain: opt.gain || 4, compare: !!opt.compare, probes: opt.probes,
};
// mapError can't cross into the page: errors come back with ES line numbers, mapped here.
const mapByFx = Object.fromEntries(effects.map((fx) => [fx.id, Object.fromEntries(fx.passes.map((p) => [p.name, p.mapErrorSrc]))]));
const res = await page.evaluate(async (j) => {
  j.effects.forEach((fx) => fx.passes.forEach((p) => { p.mapError = (m) => m; }));
  return window.runJob(j);
}, job);
await browser.close();

for (const w of warnings) console.log(w);
let failed = false;
for (let l of res.log) {
  const m = l.match(/^FAIL (\S+): pass (\S+?): /);
  if (m && mapByFx[m[1]] && mapByFx[m[1]][m[2]]) l = mapByFx[m[1]][m[2]](l);
  if (l.startsWith('FAIL')) failed = true;
  console.log(l);
}
const outPath = path.resolve(opt.out);
fs.mkdirSync(path.dirname(outPath), { recursive: true });
const stem = outPath.replace(/\.png$/i, '');
const write = (file, url) => { fs.writeFileSync(file, Buffer.from(url.split(',')[1], 'base64')); console.log('wrote ' + file); };
for (const [name, url] of Object.entries(res.images)) {
  if (name === 'out') write(outPath, url);
  else write(`${stem}.${name.replace(/[\/\\]/g, '_')}.png`, url);
}
process.exit(failed ? 1 : 0);
