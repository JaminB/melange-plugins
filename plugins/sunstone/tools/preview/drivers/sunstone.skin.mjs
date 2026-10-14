// What Sunstone's Lua pushes to sunstone/skin. Scenario worm field "tone": a name below or [r,g,b] (default medium).
// Scenario "sunstone": true => compat 1.
const TONES = { fair: [.94,.80,.71], light: [.88,.70,.58], medium: [.78,.57,.42], olive: [.70,.53,.36], tan: [.62,.44,.30], brown: [.45,.30,.20], deep: [.30,.19,.13] };
export default function drive({ scenario, worms }) {
  const p = { compat: [scenario.sunstone === false ? 0 : 1] };
  // The theme's sun, as the Lua sends it (here the scenario's, or the harness default).
  const sd = (scenario.lighting && scenario.lighting.sunDir) || [-0.45, 0.75, 0.5];
  const sl = Math.hypot(sd[0], sd[1], sd[2]) || 1;
  p.sunDir = [sd[0] / sl, sd[1] / sl, sd[2] / sl];
  for (const w of worms) {
    const s = w.slot; if (s < 0 || s > 15) continue;
    let t = Array.isArray(w.tone) ? w.tone : (TONES[w.tone] || TONES.medium);
    p['worm' + s] = w.centre; p['worm' + s + 'b'] = t;
    p['worm' + s + 'c'] = [w.heading, (s * 137 + 11) % 997, 0];
  }
  return p;
}
