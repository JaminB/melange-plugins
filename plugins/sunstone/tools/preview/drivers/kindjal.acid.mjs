// What Kindjal's Lua pushes to kindjal/acid: per worm acid (0..1 level) and acidSpread (0..1); compat = 1 when the
// scenario says Sunstone runs ("sunstone": true), as Kindjal's probe of wum.postfx.list() would.
export default function drive({ scenario, worms }) {
  const p = { seed: [scenario.seed ?? 417], compat: [scenario.sunstone ? 1 : 0] };
  const lv = [[0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]];
  const sp = [[0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]];
  for (const w of worms) {
    const s = w.slot;
    if (s < 0 || s > 15 || !(w.acid > 0)) continue;
    p['worm' + s] = w.centre;
    lv[s >> 2][s & 3] = w.acid;
    sp[s >> 2][s & 3] = w.acidSpread;
  }
  for (let k = 0; k < 4; k++) { p['level' + k] = lv[k]; p['spread' + k] = sp[k]; }
  return p;
}
