#!/usr/bin/env node
// Builds Bloodsand's particle sprite textures, mod/textures/bs_*.png, for Melange's wum.draw.sprite (soft textured world
// sprites). Run from anywhere: node tools/make_blood_sprites.js            (add --preview to also write a contact sheet)
//
//   bs_drop1.png, bs_drop2.png   64x128   a wet droplet, for a sprite stretched along its velocity: tail at v = 0 (the first row of the
//                                         image), head at v = 1, a rounded head, a tapering tail, a dark meniscus rim, a baked glint.
//                                         drop1 is the fat teardrop (short streaks), drop2 the slim one (long streaks).
//   bs_jet.png                   32x128   one piece of a pressurised jet of blood (the arterial spurts): a straight tube of an even width, a
//                                         soft tail that fades in so that overlapping pieces join into one stream, a rounded head, dark
//                                         edges, a faint wet sheen along it and no glint. Many of them, spaced closer than their length,
//                                         are the stream.
//   bs_clot1..4.png              64x64    round, lumpy clots with irregular outlines, lit like a wet gel (diffuse, rim, two speculars)
//   bs_mist1..3.png              128x128  a soft round puff of fine mist: radial fall-off broken up by noise
//   bs_steam1..2.png             128x128  a billowing puff for steam and smoke: lit from above left, so it has volume
//   bs_char1..2.png              64x64    a dry, ragged flake of char or ash
//   bs_bit1..3.png               64x64    a small torn fragment of flesh for the gibs: ragged straight-edged outline, fibre ridges, wet glint
//   bs_glint.png                 32x32    a small round white spark for an additive highlight on big droplets
//
// All are straight-alpha RGBA, 8 bit. The colour is NEUTRAL (grey, a touch warm): the sprite's tint multiplies it, so the
// plugin shifts it to red, green or brown blood, soot or steam. The colour of a texel with no alpha continues the colour next
// to it, so bilinear filtering and mip-maps never pull a dark or white fringe in. The texture is a lit height field of its own
// shape (light from the upper left), not a flat decal. Pure code, node's standard library only; the noise is seeded, so the
// output is the same on every run.
'use strict';
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const OUT = path.resolve(__dirname, '..', 'mod', 'textures');

// v = 0 is the first row of the image (the usual image and Direct3D convention), so the tail is the TOP of the file and the
// head the bottom. Set to false if Melange's sprites turn out to put v = 0 at the bottom row.
const TAIL_AT_TOP = true;

// ---------------------------------------------------------------- helpers
const clamp = (x, a, b) => (x < a ? a : x > b ? b : x);
const smooth = (a, b, x) => { const t = clamp((x - a) / (b - a), 0, 1); return t * t * (3 - 2 * t); };
const mix = (a, b, t) => a + (b - a) * t;

function hash2(x, y, seed) {
  let h = (Math.imul(x, 374761393) + Math.imul(y, 668265263) + Math.imul(seed, 1442695041)) | 0;
  h = Math.imul(h ^ (h >>> 13), 1274126177);
  h ^= h >>> 16;
  return (h >>> 0) / 4294967296;
}
function vnoise(x, y, seed) {
  const xi = Math.floor(x), yi = Math.floor(y), xf = x - xi, yf = y - yi;
  const u = xf * xf * (3 - 2 * xf), v = yf * yf * (3 - 2 * yf);
  return mix(mix(hash2(xi, yi, seed), hash2(xi + 1, yi, seed), u), mix(hash2(xi, yi + 1, seed), hash2(xi + 1, yi + 1, seed), u), v);
}
function fbm(x, y, seed, oct) {
  let s = 0, a = 0.5, f = 1, n = 0;
  for (let i = 0; i < oct; i++) { s += a * vnoise(x * f, y * f, seed + i * 17); n += a; a *= 0.5; f *= 2; }
  return s / n;
}
// A tiny seeded generator for the shapes.
function rng(seed) {
  let s = seed >>> 0 || 1;
  return () => { s ^= s << 13; s >>>= 0; s ^= s >>> 17; s ^= s << 5; s >>>= 0; return s / 4294967296; };
}

// ---------------------------------------------------------------- PNG
function crc32(buf) {
  let crc = 0xffffffff;
  for (let n = 0; n < buf.length; n++) {
    let c = (crc ^ buf[n]) & 0xff;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    crc = (crc >>> 8) ^ c;
  }
  return (crc ^ 0xffffffff) >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type, 'latin1'), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}
function encodePng(w, h, rgba) {
  const stride = w * 4, raw = Buffer.alloc(h * (stride + 1));
  for (let y = 0; y < h; y++) {
    raw[y * (stride + 1)] = 0;
    rgba.copy(raw, y * (stride + 1) + 1, y * stride, (y + 1) * stride);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 6;
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw, { level: 9 })), chunk('IEND', Buffer.alloc(0))]);
}

// A float image: r, g, b, a in 0..1 per texel. paint(u, v, px, py) returns [value, alpha] or [r, g, b, alpha]; u across and v
// along in 0..1 (v = 0 at the tail). The image is written with v = 0 on the first row when TAIL_AT_TOP.
function render(w, h, paint, tail) {
  const f = new Float32Array(w * h * 4);
  for (let py = 0; py < h; py++) {
    for (let px = 0; px < w; px++) {
      const u = (px + 0.5) / w, v = (py + 0.5) / h;
      const o = paint(u, tail === false ? 1 - v : v, px, py);
      const i = (py * w + px) * 4;
      if (o.length === 2) { f[i] = o[0] * 1.0; f[i + 1] = o[0] * 0.965; f[i + 2] = o[0] * 0.955; f[i + 3] = o[1]; }
      else { f[i] = o[0]; f[i + 1] = o[1]; f[i + 2] = o[2]; f[i + 3] = o[3]; }
    }
  }
  return { w, h, f };
}
function toBuffer(img) {
  const b = Buffer.alloc(img.w * img.h * 4);
  for (let i = 0; i < img.f.length; i++) b[i] = Math.round(clamp(img.f[i], 0, 1) * 255);
  return b;
}
function save(name, img) {
  fs.writeFileSync(path.join(OUT, name), encodePng(img.w, img.h, toBuffer(img)));
}

// ---------------------------------------------------------------- lighting
// A height field's shading. hx, hy are the height's slopes per texel (+x right, +y DOWN the image) scaled by `k`, light comes from
// the upper left and a little toward the viewer. Returns the value (a grey), with diffuse, a soft fill and a sharp specular.
const LIGHT = (() => { const l = Math.hypot(-0.55, -0.62, 0.56); return [-0.55 / l, -0.62 / l, 0.56 / l]; })();
const HALF = (() => { const x = LIGHT[0], y = LIGHT[1], z = LIGHT[2] + 1; const l = Math.hypot(x, y, z); return [x / l, y / l, z / l]; })();
function shade(hx, hy, spec, specPow) {
  const l = Math.hypot(hx, hy, 1), nx = -hx / l, ny = -hy / l, nz = 1 / l;
  const d = Math.max(0, nx * LIGHT[0] + ny * LIGHT[1] + nz * LIGHT[2]);
  const s = Math.pow(Math.max(0, nx * HALF[0] + ny * HALF[1] + nz * HALF[2]), specPow);
  return { diffuse: d, spec: s * spec, nz };
}

// A height function sampled in a 3x3 neighbourhood gives its slopes.
function slopes(hf, x, y) {
  const e = 0.75;
  return [(hf(x + e, y) - hf(x - e, y)) / (2 * e), (hf(x, y + e) - hf(x, y - e)) / (2 * e)];
}

// ---------------------------------------------------------------- droplets
// A teardrop's half width (0..1 of the half width of the texture, from the centre line) at s along it (0 tail, 1 head). The head
// is a half ellipse centred at hc, the tail tapers from there to a point at s0 along a power curve. wmax is the widest point.
function dropWidth(s, p) {
  const { s0, hc, s1, wmax, pw } = p;
  if (s <= s0 || s >= s1) return 0;
  if (s >= hc) { const t = (s - hc) / (s1 - hc); return wmax * Math.sqrt(Math.max(0, 1 - t * t)); }
  const t = (s - s0) / (hc - s0);
  return wmax * Math.pow(Math.sin(t * Math.PI / 2), pw);
}

function makeDrop(p) {
  const W = 64, H = 128;
  const half = W / 2;
  // signed distance (texels, > 0 inside) to the outline, from the profile and its slope along s.
  const dist = (x, y) => {
    const s = y / H, c = Math.abs(x - half) / half;
    const w = dropWidth(s, p);
    // slope of the edge in texel units: dw/ds * half / H texels across per texel along
    const e = 0.004, dw = (dropWidth(s + e, p) - dropWidth(s - e, p)) / (2 * e) * half / H;
    let d = (w * half - Math.abs(x - half)) / Math.sqrt(1 + dw * dw);
    if (w === 0) {
      // outside the profile's length: distance to the tip
      const tipY = (s <= p.s0 ? p.s0 : p.s1) * H;
      d = -Math.hypot(Math.abs(x - half), y - tipY);
    }
    return d;
  };
  const hf = (x, y) => {
    const s = y / H;
    const w = dropWidth(s, p) * half;
    const d = dist(x, y);
    if (d <= 0) return 0;
    const R = Math.max(w, 2);
    const t = 1 - Math.min(d / R, 1);
    return R * 0.85 * Math.sqrt(Math.max(0, 1 - t * t));
  };
  return render(W, H, (u, v, px, py) => {
    const x = px + 0.5, y = py + 0.5;
    // Each texture's row y is s = v; (the paint function gets v already flipped when TAIL_AT_TOP is false, and the geometry
    // below is in v, so use v for s and px for x.)
    const s = v;
    const yy = s * H;
    const d = dist(x, yy);
    const alpha = smooth(-0.9, 1.1, d);
    const [gx, gy] = slopes((a, b) => hf(a, b), x, yy);
    // the y slope is along v, which is image-down when the tail is at the top: it is the light's frame that matters, so flip when not
    const sl = shade(gx / 5.5, (TAIL_AT_TOP ? gy : -gy) / 5.5, 1.0, 60);
    const w = dropWidth(s, p) * half;
    const dd = Math.max(d, 0);
    // dense core, thinner and lighter toward the edge and the tail, a dark meniscus a couple of texels in from the edge
    const rim = Math.exp(-dd / 2.6) * 0.42;
    let val = 0.46 + 0.5 * sl.diffuse + 0.06 * (1 - rim * 2) - rim * 0.55 * (w > 0 ? 1 : 0);
    val = val * (0.9 + 0.1 * smooth(0.0, 0.5, s));
    // a baked glint: an ellipse near the head on the lit side, and a faint reflected edge on the other side
    const gu = (x - half) / half, gs = s;
    const gl = Math.exp(-(Math.pow((gu + 0.32) / 0.2, 2) + Math.pow((gs - p.glint) / 0.055, 2)));
    const gl2 = 0.22 * Math.exp(-(Math.pow((gu - 0.38) / 0.16, 2) + Math.pow((gs - (p.glint + 0.08)) / 0.07, 2)));
    val = val + sl.spec * 0.35 + gl * 1.25 + gl2;
    // the tail is thin liquid: less opaque
    let a = alpha * (0.58 + 0.42 * smooth(0.04, 0.45, s)) * 0.97;
    return [clamp(val, 0, 1.15), a];
  }, TAIL_AT_TOP);
}

// ---------------------------------------------------------------- jet
// A piece of a stream: tail at v = 0, head at v = 1. The width is even from 0.16 to 0.9 along it, so that pieces laid end over
// end make a tube; the tail thins and fades in (alpha under a half until 0.25), the head is a half ellipse.
function makeJet() {
  const W = 32, H = 128, half = W / 2;
  const wAt = (s) => {
    if (s <= 0.02 || s >= 0.985) return 0;
    if (s > 0.9) { const t = (s - 0.9) / 0.085; return 0.86 * Math.sqrt(Math.max(0, 1 - t * t)); }
    if (s < 0.2) return 0.86 * (0.72 + 0.28 * smooth(0.02, 0.2, s));
    return 0.86;
  };
  return render(W, H, (u, v, px, py) => {
    const x = px + 0.5, s = v;
    const w = wAt(s) * half;
    const dx = Math.abs(x - half);
    // distance inside the outline in texels (the edge slope is small except at the head, which the ellipse covers)
    let d = w - dx;
    if (w === 0) d = -1;
    if (s > 0.9) d = Math.min(d, (0.985 - s) * H * 0.7);
    const alpha = smooth(-0.8, 1.0, d);
    const t = w > 0 ? clamp((x - half) / w, -1, 1) : 0;       // across the tube, -1 left .. 1 right
    const nz = Math.sqrt(Math.max(0, 1 - t * t));
    // a cylinder lit from the upper left, darker toward the edges (the meniscus), a little lighter in the middle
    const diff = 0.52 + 0.30 * nz + 0.16 * Math.max(0, -t * 0.65 + nz * 0.45);
    const edge = Math.exp(-Math.max(d, 0) / 2.2) * 0.34;
    const sheen = 0.10 * Math.exp(-Math.pow((t + 0.38) / 0.16, 2));
    let val = diff - edge + sheen;
    // thin, see-through tail
    const a = alpha * (0.34 + 0.66 * smooth(0.02, 0.28, s));
    return [clamp(val * 0.92, 0, 1), a];
  }, TAIL_AT_TOP);
}

// ---------------------------------------------------------------- clots
function makeClot(seed) {
  const N = 64, R = rng(seed * 9973 + 7);
  // the outline: a base radius with a few low harmonics and a lobe or two
  const harm = [];
  for (let k = 2; k <= 6; k++) harm.push({ k, a: (0.16 / Math.pow(k - 1, 0.7)) * (0.5 + R()), ph: R() * 6.283 });
  const lobes = [];
  for (let i = 0; i < 1 + Math.floor(R() * 2.5); i++) lobes.push({ at: R() * 6.283, w: 0.25 + R() * 0.3, a: 0.08 + R() * 0.12 });
  const base = 0.62 + R() * 0.06, sx = 1 + (R() - 0.5) * 0.25, rot = R() * 6.283;
  const rad = (th) => {
    let r = 1;
    for (const h of harm) r += h.a * Math.cos(h.k * th + h.ph);
    for (const l of lobes) { let d = Math.abs(((th - l.at + Math.PI) % (2 * Math.PI) + 2 * Math.PI) % (2 * Math.PI) - Math.PI); r += l.a * Math.exp(-(d * d) / (l.w * l.w)); }
    return r * base;
  };
  const cx = N / 2, cy = N / 2;
  const edge = (x, y) => {
    // distance inside (texels), >0 inside, from the polar outline (approximate: radial)
    const dx = (x - cx) / sx, dy = y - cy;
    const th = Math.atan2(dy, dx) + rot;
    const rr = rad(th) * N / 2;
    const r = Math.hypot(dx, dy);
    // small high-frequency wobble
    const wob = (fbm(x * 0.35, y * 0.35, seed * 31, 3) - 0.5) * 2.2;
    return rr - r + wob;
  };
  const hf = (x, y) => {
    const d = edge(x, y);
    if (d <= 0) return 0;
    const Rr = N * 0.26;
    const t = 1 - Math.min(d / Rr, 1);
    // dome plus lumps
    return Rr * 0.9 * Math.sqrt(Math.max(0, 1 - t * t)) + 2.2 * (fbm(x * 0.12, y * 0.12, seed * 13, 3) - 0.5) * Math.min(1, d / 5);
  };
  // two specular spots: the main one on the lit side of the dome and a smaller one
  const spot = (u, v, x0, y0, s0) => Math.exp(-((u - x0) * (u - x0) + (v - y0) * (v - y0)) / (s0 * s0));
  const sp1 = { x: 0.37 + (R() - 0.5) * 0.08, y: 0.34 + (R() - 0.5) * 0.08 };
  const sp2 = { x: 0.62 + (R() - 0.5) * 0.1, y: 0.66 + (R() - 0.5) * 0.1 };
  return render(N, N, (u, v, px, py) => {
    const x = px + 0.5, y = py + 0.5;
    const d = edge(x, y);
    const alpha = smooth(-0.8, 1.2, d);
    const [gx, gy] = slopes(hf, x, y);
    const sl = shade(gx / 4, gy / 4, 1, 44);
    const dd = Math.max(d, 0);
    const lump = fbm(x * 0.2, y * 0.2, seed * 7 + 3, 4);
    const rim = Math.exp(-dd / 2.4) * 0.3;
    let val = 0.30 + 0.62 * sl.diffuse + (lump - 0.5) * 0.28 - rim;
    // wet speculars
    val += sl.spec * 0.55 + spot(u, v, sp1.x, sp1.y, 0.045) * 0.9 + spot(u, v, sp2.x, sp2.y, 0.03) * 0.28 * (dd > 3 ? 1 : 0);
    // thin edges are lighter and see-through: a little less alpha at the very rim
    const a = alpha * (0.78 + 0.22 * smooth(0, 4, dd));
    return [clamp(val, 0, 1.1), a];
  });
}

// ---------------------------------------------------------------- mist and steam
function makeMist(seed) {
  const N = 128, R = rng(seed * 4099 + 11);
  const ox = R() * 50, oy = R() * 50;
  // a few soft sub-puffs placed round the middle, so that the shape is not a plain disc
  const subs = [];
  const ns = 6 + Math.floor(R() * 3);
  for (let i = 0; i < ns; i++) { const a = R() * 6.283, r = R() * 0.38; subs.push({ x: Math.cos(a) * r, y: Math.sin(a) * r, s: 0.38 + R() * 0.25, w: 0.6 + R() * 0.5 }); }
  return render(N, N, (u, v, px, py) => {
    const x = u * 2 - 1, y = v * 2 - 1;
    // warp the domain for wispy edges
    const wx = (fbm(u * 2.5 + ox, v * 2.5 + oy, seed, 3) - 0.5) * 0.4, wy = (fbm(u * 2.5 + oy, v * 2.5 + ox, seed + 5, 3) - 0.5) * 0.4;
    const X = x + wx, Y = y + wy;
    let dens = 0;
    for (const s of subs) { const d = Math.hypot(X - s.x, Y - s.y) / s.s; dens += s.w * Math.exp(-d * d * 1.4); }
    dens = dens / (ns * 0.5);
    const r = Math.hypot(x, y);
    const fine = fbm(u * 7 + ox, v * 7 + oy, seed + 40, 3);
    let a = (dens * (0.8 + 0.4 * fine)) * smooth(1.0, 0.3, r);
    a = clamp(a * 0.95, 0, 0.9) * smooth(1.0, 0.8, r);
    // a fine mist of droplets is a little denser (darker) in the middle
    const val = 0.93 - 0.2 * clamp(dens, 0, 1) * (0.7 + 0.3 * fine) - 0.04 * (1 - fine);
    return [val, a];
  });
}

function makeSteam(seed) {
  const N = 128, R = rng(seed * 7919 + 3);
  const ox = R() * 80, oy = R() * 80;
  // billows: overlapping soft spheres of different sizes
  const bl = [];
  const nb = 8 + Math.floor(R() * 3);
  for (let i = 0; i < nb; i++) {
    const a = R() * 6.283, r = Math.sqrt(R()) * 0.4;
    bl.push({ x: Math.cos(a) * r, y: Math.sin(a) * r * 0.9 + 0.04, r: 0.26 + R() * 0.24 });
  }
  const field = (X, Y) => {
    let f = 0, hx = 0, hy = 0;
    for (const b of bl) {
      const dx = X - b.x, dy = Y - b.y, d2 = (dx * dx + dy * dy) / (b.r * b.r);
      if (d2 < 1) { const k = (1 - d2); f += k * k * k; hx += -dx / (b.r * b.r) * 6 * k * k; hy += -dy / (b.r * b.r) * 6 * k * k; }
    }
    return [f, hx, hy];
  };
  return render(N, N, (u, v) => {
    const x = u * 2 - 1, y = v * 2 - 1;
    const wx = (fbm(u * 3 + ox, v * 3 + oy, seed, 3) - 0.5) * 0.22, wy = (fbm(u * 3 + oy, v * 3 + ox, seed + 9, 3) - 0.5) * 0.22;
    const [f, gx, gy] = field(x + wx, y + wy);
    const r = Math.hypot(x, y);
    const fine = fbm(u * 6 + ox, v * 6 + oy, seed + 30, 3);
    const a = clamp(smooth(0.0, 0.9, f) * (0.85 + 0.25 * fine), 0, 0.88) * smooth(1.0, 0.75, r);
    // lit from the upper left: the density's own slope shades the billows, gently
    const sl = shade(-gx * 0.09, -gy * 0.09, 0, 1);
    const val = clamp(0.8 + 0.2 * sl.diffuse + (fine - 0.5) * 0.1 - 0.06 * smooth(0.4, 1.6, f), 0.6, 1.0);
    return [val, a];
  });
}

// ---------------------------------------------------------------- char
function makeChar(seed) {
  const N = 64, R = rng(seed * 6007 + 5);
  const nv = 6 + Math.floor(R() * 3), rot = R() * 6.283, el = 0.7 + R() * 0.25;
  const vr = [];
  for (let i = 0; i < nv; i++) vr.push(0.55 + R() * 0.45);
  const rad = (th) => {
    const t = ((th + rot) / (2 * Math.PI) % 1 + 1) % 1 * nv, i = Math.floor(t), f = t - i;
    const a = vr[i % nv], b = vr[(i + 1) % nv];
    return mix(a, b, f * f * (3 - 2 * f) * 0.35 + f * 0.65);   // mostly straight edges between the corners
  };
  return render(N, N, (u, v, px, py) => {
    const x = (px + 0.5 - N / 2), y = (py + 0.5 - N / 2);
    const th = Math.atan2(y, x / el);
    const r = Math.hypot(x / el, y);
    const rr = rad(th) * N * 0.4;
    const wob = (fbm(px * 0.45, py * 0.45, seed * 5, 3) - 0.5) * 3.2;
    const d = rr - r + wob;
    const alpha = smooth(-0.7, 1.0, d);
    const dd = Math.max(d, 0);
    const grain = fbm(px * 0.7, py * 0.7, seed * 3 + 1, 4);
    const crack = Math.abs(fbm(px * 0.22, py * 0.22, seed * 9, 3) - 0.5) < 0.035 ? 0.25 : 0;
    // a dry, uneven surface: mottled, with a lighter, ashy rim and darker fissures
    const val = clamp(0.55 + (grain - 0.5) * 0.45 + 0.22 * Math.exp(-dd / 2.0) - crack, 0.12, 1.0);
    const sl = shade((grain - fbm(px * 0.7 + 1, py * 0.7, seed * 3 + 1, 4)) * 4, (grain - fbm(px * 0.7, py * 0.7 + 1, seed * 3 + 1, 4)) * 4, 0, 1);
    return [clamp(val * (0.78 + 0.35 * sl.diffuse), 0, 1), alpha];
  });
}

// ---------------------------------------------------------------- meat bits
// A small torn fragment of flesh for the gibs: a ragged outline of straight-ish edges (5 to 7 corners), a flat-topped lump with
// fibre ridges running along it, a lighter, rougher torn rim and a wet glint or two. Grey: the sprite's colour makes it muscle,
// fat or a pink scrap.
function makeBit(seed) {
  const N = 64, R = rng(seed * 8191 + 13);
  const nv = 5 + Math.floor(R() * 3), rot = R() * 6.283, el = 0.62 + R() * 0.3, ang = R() * 3.1416;
  const vr = [];
  for (let i = 0; i < nv; i++) vr.push(0.5 + R() * 0.5);
  const rad = (th) => {
    const t = ((th + rot) / (2 * Math.PI) % 1 + 1) % 1 * nv, i = Math.floor(t), f = t - i;
    return mix(vr[i % nv], vr[(i + 1) % nv], f);          // straight edges between the corners
  };
  const ca = Math.cos(ang), sa = Math.sin(ang);
  const shape = (px, py) => {
    const X = px + 0.5 - N / 2, Y = py + 0.5 - N / 2;
    const x = X * ca + Y * sa, y = -X * sa + Y * ca;      // along the fibre: x
    const r = Math.hypot(x / el, y);
    const rr = rad(Math.atan2(y, x / el)) * N * 0.42;
    const wob = (fbm(px * 0.4, py * 0.4, seed * 5, 3) - 0.5) * 3.6;
    return { d: rr - r + wob, x, y };
  };
  const hf = (px, py) => {
    const o = shape(px, py);
    if (o.d <= 0) return 0;
    const t = Math.min(o.d / 9, 1);
    const fibre = fbm(o.x * 0.08 + 3, o.y * 0.55, seed * 11, 3) - 0.5;
    return 5.5 * Math.pow(t, 0.55) + fibre * 3.2 * Math.min(1, o.d / 6);
  };
  return render(N, N, (u, v, px, py) => {
    const o = shape(px, py);
    const alpha = smooth(-0.8, 1.1, o.d);
    const [gx, gy] = slopes(hf, px + 0.5, py + 0.5);
    const sl = shade(gx / 2.4, gy / 2.4, 1, 30);
    const dd = Math.max(o.d, 0);
    const streak = fbm(o.x * 0.1 + 7, o.y * 0.7, seed * 17, 3);
    const rim = Math.exp(-dd / 2.2);
    let val = 0.34 + 0.55 * sl.diffuse + (streak - 0.5) * 0.4 + 0.12 * rim - 0.1 * (1 - smooth(0, 6, dd));
    val += sl.spec * 0.5 + Math.exp(-(Math.pow((u - 0.38) / 0.1, 2) + Math.pow((v - 0.36) / 0.07, 2))) * 0.55;
    return [clamp(val, 0.1, 1.1), alpha];
  });
}

// ---------------------------------------------------------------- glint
function makeGlint() {
  const N = 32;
  return render(N, N, (u, v) => {
    const x = u * 2 - 1, y = v * 2 - 1, r = Math.hypot(x, y);
    const core = Math.exp(-r * r * 9), halo = Math.exp(-r * r * 3) * 0.35;
    const star = (Math.exp(-(x * x) * 90) * Math.exp(-Math.abs(y) * 3.2) + Math.exp(-(y * y) * 90) * Math.exp(-Math.abs(x) * 3.2)) * 0.5;
    const a = clamp(core + halo + star, 0, 1) * smooth(1.0, 0.75, r);
    return [1, a];
  });
}

// ---------------------------------------------------------------- run
const files = {
  'bs_drop1.png': () => makeDrop({ s0: 0.03, hc: 0.66, s1: 0.975, wmax: 0.84, pw: 1.35, glint: 0.8 }),
  'bs_drop2.png': () => makeDrop({ s0: 0.02, hc: 0.78, s1: 0.98, wmax: 0.56, pw: 1.1, glint: 0.88 }),
  'bs_jet.png': () => makeJet(),
  'bs_clot1.png': () => makeClot(1),
  'bs_clot2.png': () => makeClot(2),
  'bs_clot3.png': () => makeClot(3),
  'bs_clot4.png': () => makeClot(4),
  'bs_mist1.png': () => makeMist(1),
  'bs_mist2.png': () => makeMist(2),
  'bs_mist3.png': () => makeMist(3),
  'bs_steam1.png': () => makeSteam(1),
  'bs_steam2.png': () => makeSteam(2),
  'bs_char1.png': () => makeChar(1),
  'bs_char2.png': () => makeChar(2),
  'bs_bit1.png': () => makeBit(1),
  'bs_bit2.png': () => makeBit(2),
  'bs_bit3.png': () => makeBit(3),
  'bs_glint.png': () => makeGlint(),
};

if (require.main === module) {
  fs.mkdirSync(OUT, { recursive: true });
  let total = 0;
  const made = {};
  for (const [name, fn] of Object.entries(files)) {
    const img = fn();
    made[name] = img;
    save(name, img);
    total += fs.statSync(path.join(OUT, name)).size;
    console.log(name, img.w + 'x' + img.h, fs.statSync(path.join(OUT, name)).size + ' bytes');
  }
  console.log('total', total, 'bytes');
  if (process.argv.includes('--preview')) {
    // A contact sheet, each texture tinted dark red on a sand background, at 3x for a look.
    const S = 3, bgc = [0.82, 0.68, 0.38];
    const cellW = 280, cellH = 280, per = 5, rows = Math.ceil(Object.keys(made).length / per);
    const sw = cellW * per * 1, sh = cellH * rows;
    const out = new Float32Array(sw * sh * 3);
    for (let i = 0; i < sw * sh; i++) { out[i * 3] = bgc[0]; out[i * 3 + 1] = bgc[1]; out[i * 3 + 2] = bgc[2]; }
    let k = 0;
    for (const [name, img] of Object.entries(made)) {
      const cx = (k % per) * cellW, cy = Math.floor(k / per) * cellH;
      const tint = name.includes('steam') ? [0.85, 0.85, 0.88] : name.includes('char') ? [0.3, 0.26, 0.24] : name.includes('glint') ? [1, 1, 1] : name.includes('bit') ? [0.62, 0.09, 0.07] : [0.62, 0.03, 0.03];
      const sc = Math.min(3.2, (cellW - 8) / Math.max(img.w, img.h));
      for (let y = 0; y < cellH; y++) for (let x = 0; x < cellW; x++) {
        const ix = (x - cellW / 2) / sc + img.w / 2, iy = (y - cellH / 2) / sc + img.h / 2;
        if (ix < 0 || iy < 0 || ix >= img.w - 1 || iy >= img.h - 1) continue;
        const x0 = Math.floor(ix), y0 = Math.floor(iy), fx = ix - x0, fy = iy - y0;
        const px = [0, 0, 0, 0];
        for (let c = 0; c < 4; c++) {
          const g = (xx, yy) => img.f[(yy * img.w + xx) * 4 + c];
          px[c] = mix(mix(g(x0, y0), g(x0 + 1, y0), fx), mix(g(x0, y0 + 1), g(x0 + 1, y0 + 1), fx), fy);
        }
        const o = ((cy + y) * sw + cx + x) * 3, a = px[3];
        for (let c = 0; c < 3; c++) out[o + c] = out[o + c] * (1 - a) + clamp(px[c] * tint[c], 0, 1) * a;
      }
      k++;
    }
    const buf = Buffer.alloc(sw * sh * 4);
    for (let i = 0; i < sw * sh; i++) { buf[i * 4] = clamp(out[i * 3], 0, 1) * 255; buf[i * 4 + 1] = clamp(out[i * 3 + 1], 0, 1) * 255; buf[i * 4 + 2] = clamp(out[i * 3 + 2], 0, 1) * 255; buf[i * 4 + 3] = 255; }
    const pv = process.env.SHEET || path.join(OUT, '..', '..', 'sprites_sheet.png');
    fs.writeFileSync(pv, encodePng(sw, sh, buf));
    console.log('sheet', pv);
  }
}
module.exports = { files, TAIL_AT_TOP };
