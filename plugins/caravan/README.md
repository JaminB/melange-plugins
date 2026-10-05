# Caravan

Brings the maps of [Renewation HD](https://mod.worms.pro/) 0.2A2 into Melange, imported onto your own PC. **Caravan
contains no maps itself** — it ships only an import recipe (`mod/import.json`) that tells Melange's built-in local
content importer where to get the official zip, how to verify it, and which maps to bring in.

## What it does

On the Plugins page, "Import maps" downloads `RenewationHD_0.2A2.zip` from `mod.worms.pro` (or lets you pick a copy
you already have) and checks its exact size and SHA-256 **before reading anything from it**. A file that doesn't
match is refused untouched. Melange then reads only the map files it needs from the zip — never Renewation's own
loader, CRC patch, textures, scripts or Tweak files — and builds map packs under your game's `Mods` folder.

Of the 174 maps:

- **Plays as designed** (130: the Mega Map Pack, the Worms 3D ports, and 11 maps from your own game's files given
  new multiplayer keys) — a plain deathmatch and a Survivor copy, as Renewation itself plays them.
- **Deathmatch only** (17 Renewation maps) — Renewation's own ruleset is dropped; the map loads as a plain
  deathmatch.
- **Mode not supported** (27 maps built for a Renewation game mode: races, sieges, boss fights and the rest) — the
  mode can't run in Melange, so these load as a plain deathmatch too. They're hidden from your map list by default;
  show them on the Import page if you still want them.

Every map uses the game's own standard textures — Renewation's HD texture packs are never imported, so nothing
changes for maps or weapons you didn't ask to change. Imported maps stay on your PC; Caravan never uploads or
shares anything. Players who imported the same zip with the same Caravan version get identical map packs, so they
can play them together online.

## Removing it

The Import page has "Remove imported maps" (deletes the generated packs, keeps or deletes the downloaded zip, your
choice) and "Delete downloaded zip" on its own. Removing Caravan from the Store removes its imported packs with it.

## Provenance

Renewation HD is a fan-made compilation maintained by the mod.worms.pro community, building on
[W4Tweaks](https://mod.worms.pro/). The maps it collects were made by their own authors over many years; Renewation
publishes them for personal, non-commercial play, and Caravan imports them under those same terms — free to use,
not for commercial purposes, maps credited to their authors. Caravan does not change that: it is a download helper,
not a rights holder, and it includes none of Renewation's files in this plugin or anywhere in this repository.

Melange and Caravan are not made by, affiliated with, or endorsed by mod.worms.pro, W4Tweaks, the maps' individual
authors, or Team17. All trademarks and third-party names that appear in map titles belong to their own owners.

## Licence

The recipe and the text in this plugin (`mod/import.json`, `mod/spice.json`, `store.json`, this README,
`CHANGELOG.md`) are MIT — see `LICENSE`. That licence does not extend to anything Caravan downloads: the Renewation
maps remain under their own authors' and mod.worms.pro's terms.
