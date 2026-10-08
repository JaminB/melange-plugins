#!/usr/bin/env node
// Builds Bloodsand's lens splatter atlas, mod/postfx/lens/atlas.png, from the four splat shapes in mod/textures/ (the ones
// make_splats.py writes, which the HUD fallback also draws). Run from anywhere: node tools/make_lens_atlas.js
//
// The atlas is 256x256, the four shapes at 128x128 in reading order (splat1 top left, splat2 top right, splat3 bottom left,
// splat4 bottom right). Per pixel:
//   A = the shape (the splat's own alpha),
//   R = thickness, 0..1: the shape blurred wide, so it is thickest in the middle of a blot and thin at fingers and drips,
//   G, B = the way the surface leans, (x right, y up) as 128 + 127 * component: the slope of a smoother copy of the shape,
//          pointing out from the thick middle toward the rim, which lens.frag bends the view and puts its highlight by.
// Pure code on the splat alpha, nothing from the game. Node's standard library only.
'use strict';
const fs = require('fs');
const path = require('path');
const zlib = require('zlib');

const root = path.resolve(__dirname, '..');
const SRC = 256;                // the splat textures are 256x256...
const SIZE = 128;               // ...and the atlas keeps each at half that: it is blurred on screen anyway
const CELLS = 2;

function crc32(buf) {
  let c, crc = 0xffffffff;
  for (let n = 0; n < buf.length; n++) {
    c = (crc ^ buf[n]) & 0xff;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    crc = (crc >>> 8) ^ c;
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function decodePng(buf) {
  if (buf.readUInt32BE(0) !== 0x89504e47) throw new Error('not a PNG');
  let pos = 8, w = 0, h = 0, depth = 0, ctype = 0;
  const idat = [];
  while (pos < buf.length) {
    const len = buf.readUInt32BE(pos), type = buf.toString('latin1', pos + 4, pos + 8);
    const data = buf.subarray(pos + 8, pos + 8 + len);
    if (type === 'IHDR') { w = data.readUInt32BE(0); h = data.readUInt32BE(4); depth = data[8]; ctype = data[9]; if (data[12]) throw new Error('interlaced'); }
    else if (type === 'IDAT') idat.push(data);
    else if (type === 'IEND') break;
    pos += 12 + len;
  }
  if (depth !== 8) throw new Error('only 8-bit PNGs');
  const bpp = { 0: 1, 2: 3, 4: 2, 6: 4 }[ctype];
  if (!bpp) throw new Error('unsupported colour type ' + ctype);
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const stride = w * bpp, out = Buffer.alloc(h * stride);
  for (let y = 0; y < h; y++) {
    const f = raw[y * (stride + 1)], src = y * (stride + 1) + 1, dst = y * stride;
    for (let x = 0; x < stride; x++) {
      const a = x >= bpp ? out[dst + x - bpp] : 0, b = y ? out[dst - stride + x] : 0, c = x >= bpp && y ? out[dst - stride + x - bpp] : 0;
      let v = raw[src + x];
      if (f === 1) v += a; else if (f === 2) v += b; else if (f === 3) v += (a + b) >> 1;
      else if (f === 4) { const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c); v += pa <= pb && pa <= pc ? a : pb <= pc ? b : c; }
      out[dst + x] = v & 255;
    }
  }
  // Alpha, 0..1, whatever the colour type.
  const alpha = new Float32Array(w * h);
  for (let i = 0; i < w * h; i++) alpha[i] = (ctype === 6 ? out[i * 4 + 3] : ctype === 4 ? out[i * 2 + 1] : 255) / 255;
  return { w, h, alpha };
}

function encodePng(w, h, rgba) {
  const stride = w * 4, rows = [];
  let prev = Buffer.alloc(stride);
  for (let y = 0; y < h; y++) {
    const cur = rgba.subarray(y * stride, (y + 1) * stride);
    let best = null, bestSum = Infinity;
    for (let f = 0; f < 5; f++) {
      const row = Buffer.alloc(stride + 1);
      row[0] = f;
      let sum = 0;
      for (let x = 0; x < stride; x++) {
        const a = x >= 4 ? cur[x - 4] : 0, b = prev[x], c = x >= 4 ? prev[x - 4] : 0;
        let pred = 0;
        if (f === 1) pred = a; else if (f === 2) pred = b; else if (f === 3) pred = (a + b) >> 1;
        else if (f === 4) { const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c); pred = pa <= pb && pa <= pc ? a : pb <= pc ? b : c; }
        const v = (cur[x] - pred) & 255;
        row[x + 1] = v;
        sum += v < 128 ? v : 256 - v;
      }
      if (sum < bestSum) { bestSum = sum; best = row; }
    }
    rows.push(best);
    prev = cur;
  }
  const idat = zlib.deflateSync(Buffer.concat(rows), { level: 9 });
  const chunk = (type, data) => {
    const b = Buffer.alloc(12 + data.length);
    b.writeUInt32BE(data.length, 0);
    b.write(type, 4, 'latin1');
    data.copy(b, 8);
    b.writeUInt32BE(crc32(b.subarray(4, 8 + data.length)), 8 + data.length);
    return b;
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 6;
  return Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), chunk('IHDR', ihdr), chunk('IDAT', idat), chunk('IEND', Buffer.alloc(0))]);
}

// A box blur of the given radius, applied three times (close to a Gaussian), edges treated as empty.
function blur(src, w, h, radius) {
  let a = Float32Array.from(src), b = new Float32Array(w * h);
  for (let pass = 0; pass < 3; pass++) {
    for (let y = 0; y < h; y++) {
      let sum = 0;
      for (let x = -radius; x <= radius; x++) if (x >= 0 && x < w) sum += a[y * w + x];
      for (let x = 0; x < w; x++) {
        b[y * w + x] = sum / (2 * radius + 1);
        const o = x - radius, n = x + radius + 1;
        if (o >= 0) sum -= a[y * w + o];
        if (n < w) sum += a[y * w + n];
      }
    }
    for (let x = 0; x < w; x++) {
      let sum = 0;
      for (let y = -radius; y <= radius; y++) if (y >= 0 && y < h) sum += b[y * w + x];
      for (let y = 0; y < h; y++) {
        a[y * w + x] = sum / (2 * radius + 1);
        const o = y - radius, n = y + radius + 1;
        if (o >= 0) sum -= b[o * w + x];
        if (n < h) sum += b[n * w + x];
      }
    }
  }
  return a;
}

// The three smooth channels are rounded to steps of QUANT: the texture filter smooths the steps out again, and the PNG
// shrinks to a third.
const QUANT = 8;
const q = (v) => Math.min(255, Math.max(0, Math.round(v / QUANT) * QUANT));

const atlas = Buffer.alloc(CELLS * SIZE * CELLS * SIZE * 4);
for (let i = 0; i < CELLS * CELLS; i++) {
  const file = path.join(root, 'mod', 'textures', 'splat' + (i + 1) + '.png');
  const src = decodePng(fs.readFileSync(file));
  if (src.w !== SRC || src.h !== SRC) throw new Error(file + ' is not ' + SRC + 'x' + SRC);
  const w = SIZE, h = SIZE, alpha = new Float32Array(w * h);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const k = (y * 2) * SRC + x * 2;
    alpha[y * w + x] = (src.alpha[k] + src.alpha[k + 1] + src.alpha[k + SRC] + src.alpha[k + SRC + 1]) / 4;
  }
  const thick = blur(alpha, w, h, 4);
  const smooth = blur(alpha, w, h, 3);
  // The slope of the smooth copy, outward from the thick middle (minus its gradient), y up (image rows run down).
  const sx = new Float32Array(w * h), sy = new Float32Array(w * h), mags = [];
  for (let y = 1; y < h - 1; y++) {
    for (let x = 1; x < w - 1; x++) {
      const gx = (smooth[y * w + x + 1] - smooth[y * w + x - 1]) * 0.5, gy = (smooth[(y + 1) * w + x] - smooth[(y - 1) * w + x]) * 0.5;
      sx[y * w + x] = -gx;
      sy[y * w + x] = gy;                       // -(-gy): image y runs down, so up is the other way
      if (alpha[y * w + x] > 0.05) mags.push(Math.hypot(gx, gy));
    }
  }
  mags.sort((p, q) => p - q);
  const scale = 1 / Math.max(1e-4, mags[Math.floor(mags.length * 0.97)] || 1);
  const ox = (i % CELLS) * SIZE, oy = Math.floor(i / CELLS) * SIZE;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      const k = y * w + x;
      let vx = sx[k] * scale, vy = sy[k] * scale;
      const m = Math.hypot(vx, vy);
      if (m > 1) { vx /= m; vy /= m; }
      const o = ((oy + y) * CELLS * SIZE + ox + x) * 4;
      atlas[o] = q(Math.min(1, thick[k] * 1.3) * 255);
      atlas[o + 1] = q(128 + 127 * vx);
      atlas[o + 2] = q(128 + 127 * vy);
      atlas[o + 3] = Math.round(alpha[k] * 255);
    }
  }
}
const outFile = path.join(root, 'mod', 'postfx', 'lens', 'atlas.png');
fs.mkdirSync(path.dirname(outFile), { recursive: true });
const png = encodePng(CELLS * SIZE, CELLS * SIZE, atlas);
fs.writeFileSync(outFile, png);
console.log('wrote', outFile, png.length, 'bytes');
