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
  // Sunstone's Worm skin: each slot's skin brightness against the game's peach (a worm's "tone"), as Sunstone's event gives it.
  const tone = [[1, 1, 1, 1], [1, 1, 1, 1], [1, 1, 1, 1], [1, 1, 1, 1]];
  for (const w of worms) if (w.slot >= 0 && w.slot <= 15) tone[w.slot >> 2][w.slot & 3] = w.toneLum ?? 1;
  for (let k = 0; k < 4; k++) p['tone' + k] = tone[k];
  // What Sunstone draws (Kindjal's sunskin; the colour test or the mark): 2 a re-toned skin when any worm has a tone, else 0; a scenario can set it.
  p.sunskin = [scenario.sunskinAcid ?? (worms.some((w) => w.mark) ? 2 : 0)];
  return p;
}
