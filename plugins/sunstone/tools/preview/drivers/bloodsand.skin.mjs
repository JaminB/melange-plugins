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
  return p;
}
