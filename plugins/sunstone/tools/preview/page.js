// Runs inside headless Chromium (WebGL2). Emulates Melange's post-FX runner: renders the synthetic scene (or loads a real
// frame and fakes its depth), then runs each effect's passes in order with Melange's samplers and built-in uniforms.
// Entry point: window.runJob(job) -> { log: [...], images: { name: dataURL } }. run.mjs builds the job.
(function () {
  'use strict';

  // ---- small matrix helpers (column-major, like GL) ----
  function perspective(fovY, aspect, n, f) {
    const t = 1 / Math.tan(fovY / 2);
    return [t / aspect, 0, 0, 0, 0, t, 0, 0, 0, 0, -(f + n) / (f - n), -1, 0, 0, -2 * f * n / (f - n), 0];
  }
  function sub(a, b) { return [a[0] - b[0], a[1] - b[1], a[2] - b[2]]; }
  function cross(a, b) { return [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]]; }
  function norm(a) { const l = Math.hypot(a[0], a[1], a[2]) || 1; return [a[0] / l, a[1] / l, a[2] / l]; }
  function dot(a, b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
  function lookAt(eye, target, up) {
    const z = norm(sub(eye, target)), x = norm(cross(up, z)), y = cross(z, x);
    return [x[0], y[0], z[0], 0, x[1], y[1], z[1], 0, x[2], y[2], z[2], 0, -dot(x, eye), -dot(y, eye), -dot(z, eye), 1];
  }
  function invert(m) {
    const inv = new Array(16);
    inv[0] = m[5] * m[10] * m[15] - m[5] * m[11] * m[14] - m[9] * m[6] * m[15] + m[9] * m[7] * m[14] + m[13] * m[6] * m[11] - m[13] * m[7] * m[10];
    inv[4] = -m[4] * m[10] * m[15] + m[4] * m[11] * m[14] + m[8] * m[6] * m[15] - m[8] * m[7] * m[14] - m[12] * m[6] * m[11] + m[12] * m[7] * m[10];
    inv[8] = m[4] * m[9] * m[15] - m[4] * m[11] * m[13] - m[8] * m[5] * m[15] + m[8] * m[7] * m[13] + m[12] * m[5] * m[11] - m[12] * m[7] * m[9];
    inv[12] = -m[4] * m[9] * m[14] + m[4] * m[10] * m[13] + m[8] * m[5] * m[14] - m[8] * m[6] * m[13] - m[12] * m[5] * m[10] + m[12] * m[6] * m[9];
    inv[1] = -m[1] * m[10] * m[15] + m[1] * m[11] * m[14] + m[9] * m[2] * m[15] - m[9] * m[3] * m[14] - m[13] * m[2] * m[11] + m[13] * m[3] * m[10];
    inv[5] = m[0] * m[10] * m[15] - m[0] * m[11] * m[14] - m[8] * m[2] * m[15] + m[8] * m[3] * m[14] + m[12] * m[2] * m[11] - m[12] * m[3] * m[10];
    inv[9] = -m[0] * m[9] * m[15] + m[0] * m[11] * m[13] + m[8] * m[1] * m[15] - m[8] * m[3] * m[13] - m[12] * m[1] * m[11] + m[12] * m[3] * m[9];
    inv[13] = m[0] * m[9] * m[14] - m[0] * m[10] * m[13] - m[8] * m[1] * m[14] + m[8] * m[2] * m[13] + m[12] * m[1] * m[10] - m[12] * m[2] * m[9];
    inv[2] = m[1] * m[6] * m[15] - m[1] * m[7] * m[14] - m[5] * m[2] * m[15] + m[5] * m[3] * m[14] + m[13] * m[2] * m[7] - m[13] * m[3] * m[6];
    inv[6] = -m[0] * m[6] * m[15] + m[0] * m[7] * m[14] + m[4] * m[2] * m[15] - m[4] * m[3] * m[14] - m[12] * m[2] * m[7] + m[12] * m[3] * m[6];
    inv[10] = m[0] * m[5] * m[15] - m[0] * m[7] * m[13] - m[4] * m[1] * m[15] + m[4] * m[3] * m[13] + m[12] * m[1] * m[7] - m[12] * m[3] * m[5];
    inv[14] = -m[0] * m[5] * m[14] + m[0] * m[6] * m[13] + m[4] * m[1] * m[14] - m[4] * m[2] * m[13] - m[12] * m[1] * m[6] + m[12] * m[2] * m[5];
    inv[3] = -m[1] * m[6] * m[11] + m[1] * m[7] * m[10] + m[5] * m[2] * m[11] - m[5] * m[3] * m[10] - m[9] * m[2] * m[7] + m[9] * m[3] * m[6];
    inv[7] = m[0] * m[6] * m[11] - m[0] * m[7] * m[10] - m[4] * m[2] * m[11] + m[4] * m[3] * m[10] + m[8] * m[2] * m[7] - m[8] * m[3] * m[6];
    inv[11] = -m[0] * m[5] * m[11] + m[0] * m[7] * m[9] + m[4] * m[1] * m[11] - m[4] * m[3] * m[9] - m[8] * m[1] * m[7] + m[8] * m[3] * m[5];
    inv[15] = m[0] * m[5] * m[10] - m[0] * m[6] * m[9] - m[4] * m[1] * m[10] + m[4] * m[2] * m[9] + m[8] * m[1] * m[6] - m[8] * m[2] * m[5];
    let det = m[0] * inv[0] + m[1] * inv[4] + m[2] * inv[8] + m[3] * inv[12];
    det = 1 / det;
    return inv.map((v) => v * det);
  }

  const FS_VERT = `#version 300 es
in vec2 a_pos;
out vec2 mg_uv;
void main() { mg_uv = a_pos * 0.5 + 0.5; gl_Position = vec4(a_pos, 0.0, 1.0); }`;

  const BLIT = `#version 300 es
precision highp float;
in vec2 mg_uv;
uniform sampler2D u_src;
uniform sampler2D u_ref;
uniform int u_mode;   // 0 copy, 1 diff vs u_ref (x u_gain), 2 depth view
uniform float u_gain;
out vec4 o;
void main() {
  vec3 c = texture(u_src, mg_uv).rgb;
  if (u_mode == 1) {
    vec3 r = texture(u_ref, mg_uv).rgb;
    vec3 d = abs(c - r) * u_gain;
    float any = step(1.5 / 255.0, max(max(abs(c - r).r, abs(c - r).g), abs(c - r).b));
    c = mix(vec3(0.12) + 0.15 * dot(r, vec3(0.299, 0.587, 0.114)), clamp(d + 0.15, 0.0, 1.0), any);
  } else if (u_mode == 2) {
    float z = texture(u_src, mg_uv).r;
    c = vec3(z >= 1.0 ? 0.0 : pow(1.0 - z, 0.25));
  }
  o = vec4(c, 1.0);
}`;

  window.runJob = async function (job) {
    const log = [];
    const images = {};
    const say = (s) => log.push(s);
    const sceneW = job.width, sceneH = job.height;
    const canvas = document.createElement('canvas');
    canvas.width = sceneW; canvas.height = sceneH;
    document.body.appendChild(canvas);
    const gl = canvas.getContext('webgl2', { preserveDrawingBuffer: true, antialias: false, alpha: false, premultipliedAlpha: false });
    if (!gl) throw new Error('no WebGL2');
    if (!gl.getExtension('EXT_color_buffer_float')) say('WARN EXT_color_buffer_float missing: rgba16f passes will fail');
    gl.getExtension('OES_texture_float_linear');
    gl.pixelStorei(gl.UNPACK_COLORSPACE_CONVERSION_WEBGL, gl.NONE);
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);

    const vbo = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);

    function compile(type, src) {
      const s = gl.createShader(type);
      gl.shaderSource(s, src);
      gl.compileShader(s);
      if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) {
        const e = gl.getShaderInfoLog(s);
        gl.deleteShader(s);
        throw new Error(e);
      }
      const w = gl.getShaderInfoLog(s);
      if (w && w.trim()) say('shader warning: ' + w.trim());
      return s;
    }
    const vs = compile(gl.VERTEX_SHADER, FS_VERT);
    function program(fsrc) {
      const fs = compile(gl.FRAGMENT_SHADER, fsrc);
      const p = gl.createProgram();
      gl.attachShader(p, vs); gl.attachShader(p, fs);
      gl.bindAttribLocation(p, 0, 'a_pos');
      gl.linkProgram(p);
      if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error('link: ' + gl.getProgramInfoLog(p));
      return p;
    }
    const FORMATS = {
      rgba8: [gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE, true],
      rgba16f: [gl.RGBA16F, gl.RGBA, gl.HALF_FLOAT, true],
      r8: [gl.R8, gl.RED, gl.UNSIGNED_BYTE, true],
      rg8: [gl.RG8, gl.RG, gl.UNSIGNED_BYTE, true],
      r32f: [gl.R32F, gl.RED, gl.FLOAT, false],
    };
    function makeTex(w, h, fmt, filter) {
      const f = FORMATS[fmt] || FORMATS.rgba8;
      const t = gl.createTexture();
      gl.activeTexture(gl.TEXTURE15);   // scratch unit, so a new target is never left on a unit a sampler reads
      gl.bindTexture(gl.TEXTURE_2D, t);
      gl.texImage2D(gl.TEXTURE_2D, 0, f[0], w, h, 0, f[1], f[2], null);
      const flt = filter === 'nearest' || !f[3] ? gl.NEAREST : gl.LINEAR;
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, flt);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, flt);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      return { tex: t, w, h, fmt };
    }
    function makeFbo(texs) {
      const fb = gl.createFramebuffer();
      gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
      texs.forEach((t, i) => gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0 + i, gl.TEXTURE_2D, t.tex, 0));
      gl.drawBuffers(texs.map((_, i) => gl.COLOR_ATTACHMENT0 + i));
      const st = gl.checkFramebufferStatus(gl.FRAMEBUFFER);
      if (st !== gl.FRAMEBUFFER_COMPLETE) throw new Error('framebuffer incomplete ' + st + ' for ' + texs.map((t) => t.fmt));
      return fb;
    }
    async function loadImage(dataUrl) {
      const img = new Image();
      img.src = dataUrl;
      await img.decode();
      return img;
    }
    function imageTex(img, flipY, filter, wrap) {
      const t = gl.createTexture();
      gl.activeTexture(gl.TEXTURE15);
      gl.bindTexture(gl.TEXTURE_2D, t);
      gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, flipY);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, gl.RGBA, gl.UNSIGNED_BYTE, img);
      gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, false);
      const flt = filter === 'nearest' ? gl.NEAREST : gl.LINEAR;
      const wr = wrap === 'repeat' ? gl.REPEAT : gl.CLAMP_TO_EDGE;
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, flt);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, flt);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, wr);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, wr);
      return { tex: t, w: img.width, h: img.height, fmt: 'rgba8' };
    }
    function draw(prog, fb, w, h) {
      gl.bindFramebuffer(gl.FRAMEBUFFER, fb);
      gl.viewport(0, 0, w, h);
      gl.useProgram(prog);
      gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
      gl.enableVertexAttribArray(0);
      gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
      gl.disable(gl.BLEND); gl.disable(gl.DEPTH_TEST);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
    }
    function setU(prog, name, type, vals) {
      const loc = gl.getUniformLocation(prog, name);
      if (!loc) return;
      const v = vals;
      switch (type) {
        case gl.FLOAT: gl.uniform1f(loc, v[0] || 0); break;
        case gl.FLOAT_VEC2: gl.uniform2f(loc, v[0] || 0, v[1] || 0); break;
        case gl.FLOAT_VEC3: gl.uniform3f(loc, v[0] || 0, v[1] || 0, v[2] || 0); break;
        case gl.FLOAT_VEC4: gl.uniform4f(loc, v[0] || 0, v[1] || 0, v[2] || 0, v[3] === undefined ? (v.length === 3 ? 1 : 0) : v[3]); break;
        case gl.INT: case gl.BOOL: gl.uniform1i(loc, Math.round(v[0] || 0)); break;
        case gl.INT_VEC2: case gl.BOOL_VEC2: gl.uniform2i(loc, v[0] | 0, v[1] | 0); break;
        case gl.INT_VEC3: case gl.BOOL_VEC3: gl.uniform3i(loc, v[0] | 0, v[1] | 0, v[2] | 0); break;
        case gl.INT_VEC4: case gl.BOOL_VEC4: gl.uniform4i(loc, v[0] | 0, v[1] | 0, v[2] | 0, v[3] | 0); break;
        case gl.FLOAT_MAT4: gl.uniformMatrix4fv(loc, false, v); break;
        case gl.FLOAT_MAT3: gl.uniformMatrix3fv(loc, false, v); break;
        default: say('WARN uniform ' + name + ' has an unsupported type ' + type);
      }
    }

    // ---- camera ----
    const W = sceneW, H = sceneH, aspect = W / H;
    let view, proj, near, far, camPos, camRot;
    const cam = job.camera;
    near = cam.near; far = cam.far;
    proj = perspective(cam.fov * Math.PI / 180, aspect, near, far);
    if (job.mode === 'image') {
      view = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
      camPos = [0, 0, 0];
    } else {
      view = lookAt(cam.pos, cam.target, [0, 1, 0]);
      camPos = cam.pos;
    }
    // view -> world rotation = transpose of view's 3x3 (as a column-major mat3: rows of view become columns)
    camRot = [view[0], view[4], view[8], view[1], view[5], view[9], view[2], view[6], view[10]];
    const invProj = invert(proj);
    const tanY = Math.tan(cam.fov * Math.PI / 360);

    // ---- scene ----
    const sceneTex = makeTex(W, H, 'rgba8');
    const depthTex = makeTex(W, H, 'r32f');
    const sceneFb = makeFbo([sceneTex, depthTex]);
    const sp = program(job.sceneShader);
    gl.useProgram(sp);
    const L = job.lighting;
    const set = (n, t, v) => setU(sp, n, t, v);
    set('u_camPos', gl.FLOAT_VEC3, camPos);
    gl.uniformMatrix3fv(gl.getUniformLocation(sp, 'u_camRot'), false, camRot);
    set('u_tan', gl.FLOAT_VEC2, [tanY * aspect, tanY]);
    set('u_nearFar', gl.FLOAT_VEC2, [near, far]);
    set('u_sunDir', gl.FLOAT_VEC3, L.sunDir);
    set('u_sunCol', gl.FLOAT_VEC3, L.sunCol);
    set('u_amb', gl.FLOAT_VEC3, L.ambient);
    set('u_skyTop', gl.FLOAT_VEC3, L.skyTop);
    set('u_skyHor', gl.FLOAT_VEC3, L.skyHorizon);
    set('u_groundCol', gl.FLOAT_VEC3, L.groundColour);
    set('u_groundNoise', gl.FLOAT, [L.groundNoise]);
    set('u_fake', gl.INT, [job.mode === 'image' ? 1 : 0]);
    set('u_backD', gl.FLOAT, [job.backD || 0]);
    const ws = job.sceneWorms.slice(0, 8);
    set('u_nw', gl.INT, [ws.length]);
    ws.forEach((w, i) => {
      set(`u_wc[${i}]`, gl.FLOAT_VEC3, w.centre);
      set(`u_wyaw[${i}]`, gl.FLOAT, [w.yaw]);
      set(`u_wskin[${i}]`, gl.FLOAT_VEC3, w.skin);
      set(`u_what[${i}]`, gl.INT, [w.hat]);
      set(`u_wrad[${i}]`, gl.FLOAT, [w.radius]);
      set(`u_wsimple[${i}]`, gl.FLOAT, [w.simple ? 1 : 0]);
    });
    let imgTex = null;
    const dummy = makeTex(1, 1, 'rgba8');
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, dummy.tex);
    if (job.mode === 'image') {
      const img = await loadImage(job.image);
      imgTex = imageTex(img, true, 'linear', 'clamp');
      gl.activeTexture(gl.TEXTURE0);
      gl.bindTexture(gl.TEXTURE_2D, imgTex.tex);
      set('u_img', gl.INT, [0]);
    }
    const chk = (where) => { const e = gl.getError(); if (e) say(`WARN GL error ${e} at ${where}`); };
    chk('scene setup');
    draw(sp, sceneFb, W, H);
    chk('scene draw');

    // ---- blit helper (to the canvas) ----
    const bp = program(BLIT);
    function snapshot(src, mode, ref, gain) {
      canvas.width = W; canvas.height = H;
      gl.useProgram(bp);
      gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, src.tex);
      gl.uniform1i(gl.getUniformLocation(bp, 'u_src'), 0);
      gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, (ref || src).tex);
      gl.uniform1i(gl.getUniformLocation(bp, 'u_ref'), 1);
      gl.uniform1i(gl.getUniformLocation(bp, 'u_mode'), mode || 0);
      gl.uniform1f(gl.getUniformLocation(bp, 'u_gain'), gain || 4);
      draw(bp, null, W, H);
      return canvas.toDataURL('image/png');
    }
    function compare(a, b) {
      canvas.width = W * 2; canvas.height = H;
      gl.useProgram(bp);
      gl.uniform1i(gl.getUniformLocation(bp, 'u_mode'), 0);
      gl.uniform1i(gl.getUniformLocation(bp, 'u_src'), 0);
      gl.uniform1i(gl.getUniformLocation(bp, 'u_ref'), 1);
      [a, b].forEach((t, i) => {
        gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, t.tex);
        gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, t.tex);
        gl.bindFramebuffer(gl.FRAMEBUFFER, null);
        gl.viewport(i * W, 0, W, H);
        gl.useProgram(bp);
        gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
        gl.enableVertexAttribArray(0);
        gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
        gl.drawArrays(gl.TRIANGLES, 0, 3);
      });
      const url = canvas.toDataURL('image/png');
      canvas.width = W; canvas.height = H;
      return url;
    }

    if (job.stages) {
      images['scene'] = snapshot(sceneTex, 0);
      images['depth'] = snapshot(depthTex, 2);
    }

    // ---- effects ----
    let current = sceneTex;
    const input = sceneTex;
    const builtins = {
      mg_invProj: invProj, mg_proj: proj, mg_view: view,
      mg_nearFar: [near, far],
      mg_sceneResolution: [W, H, 1 / W, 1 / H],
      mg_renderScale: [job.renderScale, job.renderScale],
      mg_time: [job.time], mg_frame: [job.frame],
    };
    for (let ei = 0; ei < job.effects.length; ei++) {
      const fx = job.effects[ei];
      const t0 = performance.now();
      try {
        // textures
        const ftex = {};
        for (const [name, t] of Object.entries(fx.textures)) {
          const img = await loadImage(t.data);
          ftex[name] = imageTex(img, false, t.filter, t.wrap);
        }
        const passTex = {};
        let prev = current;
        let out = null;
        for (let pi = 0; pi < fx.passes.length; pi++) {
          const ps = fx.passes[pi];
          const last = pi === fx.passes.length - 1;
          const scale = last ? 1 : ps.scale;
          const pw = Math.max(1, Math.round(W * scale)), ph = Math.max(1, Math.round(H * scale));
          const target = makeTex(pw, ph, last ? 'rgba8' : ps.format);
          const fb = makeFbo([target]);
          let prog;
          try { prog = program(ps.source); } catch (e) {
            throw new Error(`pass ${ps.name}: ${ps.mapError(String(e.message || e))}`);
          }
          gl.useProgram(prog);
          // samplers
          const n = gl.getProgramParameter(prog, gl.ACTIVE_UNIFORMS);
          let unit = 0;
          const used = new Set();
          for (let k = 0; k < n; k++) {
            const u = gl.getActiveUniform(prog, k);
            const name = u.name.replace(/\[0\]$/, '');
            if (u.type === gl.SAMPLER_2D) {
              let tex = null, need = null;
              if (name === 'mg_scene') { tex = current; need = 'scene'; }
              else if (name === 'mg_depth') { tex = depthTex; need = 'depth'; }
              else if (name === 'mg_prev') { tex = prev; need = 'prev'; }
              else if (name.startsWith('mg_pass_')) { tex = passTex[name.slice(8)]; need = 'pass.' + name.slice(8); }
              else if (name.startsWith('t_')) { tex = ftex[name.slice(2)]; need = 'texture.' + name.slice(2); }
              if (!tex) { say(`WARN ${fx.id} pass ${ps.name}: sampler ${name} has nothing bound`); continue; }
              if (!ps.inputs.includes(need)) say(`WARN ${fx.id} pass ${ps.name}: sampler ${name} is used but '${need}' is not in inputs= (Melange would not bind it)`);
              gl.activeTexture(gl.TEXTURE0 + unit);
              gl.bindTexture(gl.TEXTURE_2D, tex.tex);
              gl.uniform1i(gl.getUniformLocation(prog, u.name), unit);
              unit++;
            } else if (name.startsWith('p_')) {
              const pn = name.slice(2);
              const val = fx.params[pn];
              if (val === undefined) { say(`WARN ${fx.id}: uniform ${name} has no [param.${pn}] in effect.ini`); continue; }
              used.add(pn);
              setU(prog, u.name, u.type, val);
            } else if (name === 'mg_resolution') {
              setU(prog, name, u.type, [pw, ph, 1 / pw, 1 / ph]);
            } else if (builtins[name]) {
              setU(prog, name, u.type, builtins[name]);
            } else if (name.startsWith('mg_')) {
              say(`WARN ${fx.id}: unknown built-in ${name} (not provided by Melange)`);
            }
          }
          draw(prog, fb, pw, ph);
          passTex[ps.name] = target;
          prev = target;
          out = target;
          if (job.stages && fx.passes.length > 1 && !last && (target.fmt === 'rgba8' || target.fmt === 'rgba16f') && pw === W && ph === H) {
            images[`${ei + 1}-${fx.id}-pass-${ps.name}`] = snapshot(target, 0);
          }
        }
        const err = gl.getError();
        if (err) say(`WARN ${fx.id}: GL error ${err}`);
        current = out;
        say(`ran ${fx.id} (${fx.passes.length} pass${fx.passes.length > 1 ? 'es' : ''}, ${(performance.now() - t0).toFixed(0)} ms in SwiftShader)`);
        if (job.stages) images[`${ei + 1}-${fx.id}`] = snapshot(current, 0);
      } catch (e) {
        say(`FAIL ${fx.id}: ${e.message || e}`);
        say(`(Melange keeps running the other effects; ${fx.id} is skipped)`);
      }
    }
    images['out'] = snapshot(current, 0);
    if (job.diff) images['diff'] = snapshot(current, 1, input, job.diffGain);
    if (job.compare) images['compare'] = compare(input, current);
    // a few probe pixels, if asked
    if (job.probes && job.probes.length) {
      const fb = makeFbo([current]);
      const fb0 = makeFbo([input]);
      for (const p of job.probes) {
        const a = new Uint8Array(4), b = new Uint8Array(4);
        const x = p[0], y = H - 1 - p[1];
        gl.bindFramebuffer(gl.FRAMEBUFFER, fb0); gl.readPixels(x, y, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, b);
        gl.bindFramebuffer(gl.FRAMEBUFFER, fb); gl.readPixels(x, y, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, a);
        say(`probe ${p[0]},${p[1]}: in ${Array.from(b.slice(0, 3))} out ${Array.from(a.slice(0, 3))}`);
      }
    }
    return { log, images };
  };
})();
