// What Bloodsand's Lua (client/init.lua driveSkin/updateSkin) pushes to bloodsand/skin for a scenario.
// Per worm: blood (0..1), hitBin (1..32, 0 unknown) or hitFromDeg, wound (0..1), eye (0..1), gut (0..1), gutAz (rad),
// scorch (0..1). Like the Lua, a worm with none of these is not driven (its slot stays zero).
export default function drive({ scenario, worms }) {
  const p = { seed: [scenario.seed ?? 417] };
  const scorch = [[0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]];
  for (const w of worms) {
    const s = w.slot;
    if (s < 0 || s > 15) continue;
    if (!(w.blood > 0 || w.wound > 0 || w.eye > 0 || w.gut > 0 || w.scorch > 0)) continue;
    p['worm' + s] = w.centre;
    const gore = w.blood > 0 ? w.blood + 2 * w.hitBin : 0;
    p['worm' + s + 'b'] = [gore, w.wound, w.heading];
    p['worm' + s + 'c'] = [w.eye, w.gut, w.gutAz];
    scorch[s >> 2][s & 3] = w.scorch;
  }
  scorch.forEach((v, k) => { p['scorch' + k] = v; });
  // Sunstone's Worm skin: each slot's skin brightness against the game's peach (a worm's "tone"), as Sunstone's event gives it.
  const tone = [[1, 1, 1, 1], [1, 1, 1, 1], [1, 1, 1, 1], [1, 1, 1, 1]];
  for (const w of worms) if (w.slot >= 0 && w.slot <= 15) tone[w.slot >> 2][w.slot & 3] = w.toneLum ?? 1;
  tone.forEach((v, k) => { p['tone' + k] = v; });
  // What Sunstone draws (Bloodsand's sunskin, from Sunstone's event; the colour test or the mark): 3 a re-toned skin when any worm has
  // a tone, else 0 (the colour test); a scenario can set it.
  p.sunskin = [scenario.sunskin ?? (worms.some((w) => w.mark) ? 3 : 0)];
  return p;
}
