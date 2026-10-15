// What Sunstone's Lua pushes to sunstone/skin. Scenario worm field "tone": a name below or [r,g,b] (default medium).
// Scenario "sunstone": true => compat 1.
//
// Hair (optional, only sent when effect.ini declares the parameter, so it works before and after the shader has a
// hair branch):
// - scenario "hair": "game" | "natural" | "mixed" (or a number) -> p_hair and/or p_hairMode, whichever is
//   declared, as 0 / 1 / 2 (the Lua setting).
// - scenario "hairParams": { name: value } -> any other global p_* (always sent: the harness warns
//   when effect.ini does not declare it).
// - per worm "hairD": [a, b, c] -> wormNd if the shader adds a 4th per-worm vec3; without it, wormNd gets
//   [0, 0, 0] when the scenario gives none (update this when the Lua defines what wormNd carries).
const TONES = { fair: [.94,.80,.71], light: [.88,.70,.58], medium: [.78,.57,.42], olive: [.70,.53,.36], tan: [.62,.44,.30], brown: [.45,.30,.20], deep: [.30,.19,.13] };
const HAIR_MODES = { game: 0, natural: 1, mixed: 2 };
export default function drive({ scenario, worms, params }) {
  const p = { compat: [scenario.sunstone === false ? 0 : 1] };
  // The theme's sun, as the Lua sends it (here the scenario's, or the harness default).
  const sd = (scenario.lighting && scenario.lighting.sunDir) || [-0.45, 0.75, 0.5];
  const sl = Math.hypot(sd[0], sd[1], sd[2]) || 1;
  p.sunDir = [sd[0] / sl, sd[1] / sl, sd[2] / sl];
  if (scenario.hair !== undefined) {
    const m = typeof scenario.hair === 'number' ? scenario.hair : (HAIR_MODES[scenario.hair] ?? 0);
    for (const k of ['hair', 'hairMode']) if (params && params[k] !== undefined) p[k] = [m];
  }
  for (const [k, v] of Object.entries(scenario.hairParams || {})) p[k] = Array.isArray(v) ? v : [v];
  for (const w of worms) {
    const s = w.slot; if (s < 0 || s > 15) continue;
    let t = Array.isArray(w.tone) ? w.tone : (TONES[w.tone] || TONES.medium);
    p['worm' + s] = w.centre; p['worm' + s + 'b'] = t;
    const mixed = scenario.hair === 'mixed' || scenario.hair === 2;
    const idx = w.hairIdx !== undefined ? w.hairIdx : (mixed ? 1 + ((s * 4 + 1) % 9) : 0);
    p['worm' + s + 'c'] = [w.heading, (s * 137 + 11) % 997 + 1000 * idx, 0];
    if (params && params['worm' + s + 'd'] !== undefined) p['worm' + s + 'd'] = Array.isArray(w.hairD) ? w.hairD : [0, 0, 0];
  }
  return p;
}
