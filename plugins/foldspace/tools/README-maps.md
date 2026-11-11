# Foldspace maps

Foldspace is one mod that carries several Erg maps. Each map is designed and built in the Melange repository (Erg and
erg-mcp, under `tools/erg-mcp/bench/<map>`), exported there as an Erg **source pack**, and copied in here with
`sync_map.py`. Nothing here is edited by hand except `mod/spice.json`'s own fields (version, description, the Melange
range), `tools/maps.json`, the README and the CHANGELOG.

## Layout

```
plugins/foldspace/
  mod/
    spice.json                                   one `levels` entry and the mesh banks of every map
    maps/<map>/<map>.ergpatch.json               the map's Erg patch (its edits against a stock base level)
    assets/meshes/<map>/foldspace.<map>.xom      the map's mesh bank: all its meshes (rocks and the like) in ONE bank
    sim/<map>.lua                                a level script, if the map has one (Caldera has none)
  tools/
    maps.json        each map's pack folder inside the Melange checkout
    maps.lock.json   written by sync_map.py: the Melange commit and branch each copy came from, and the source hashes
    sync_map.py      the copy, the --check and the --verify
```

Melange names a level `<modId>_<slug>` and requires every mesh in a bank to be named `<modId>.<something>`, so a pack
made under its own id (Caldera's pack is the mod `caldera`) can't be dropped in as it is. `sync_map.py` renames it:

| | in the pack | in Foldspace |
| --- | --- | --- |
| level stem | `caldera_caldera` | `foldspace_caldera` |
| mesh | `caldera.Boulder` | `foldspace.caldera_Boulder` |
| bank file | `assets/meshes/caldera.Rocks.xom` | `assets/meshes/caldera/foldspace.caldera.xom` |
| patch | `src/caldera.ergpatch.json` | `maps/caldera/caldera.ergpatch.json` (stem and mesh names rewritten) |

A pack ships its meshes in one bank (Caldera's `caldera.Rocks.xom` holds eight). The mesh names are read from the bank
itself (the `ResourceId` of each `XMeshDescriptor` in `xomtool unpack`'s output), not from the file name, and every
`<pack>.<Name>` becomes `foldspace.<map>_<Name>` in the bank and in the patch. The bank is renamed with `xomtool unpack`
and `xomtool pack`; that round trip is byte-exact for these banks, so only the names change. A pack still in the old
layout, one mesh per bank named after it (`caldera.Boulder.xom`), also syncs, to one
`foldspace.<map>_<Name>.xom` per mesh; a pack with several multi-mesh banks keeps them apart as
`foldspace.<map>_<what follows the pack id>.xom`. Prefer one bank.

Built level files (`assets/levels/`) are never committed or shipped: they are modified copies of game files. Melange
builds them from each player's own game, by itself, when `Melange.exe` starts and before it launches the game (Erg's
**Build** button and `xomtool level build` still work by hand). `--verify` fails if
`mod/assets/levels` exists.

## Refreshing a map from its pack

Run from the repository root, with the pack's game closed so the pack isn't being rewritten:

```
python plugins/foldspace/tools/sync_map.py caldera --melange C:\Users\you\Desktop\melange-wt-ergdetail
python plugins/foldspace/tools/sync_map.py --verify
```

`--melange` (or `FOLDSPACE_MELANGE`) is the Melange checkout; the pack's folder inside it is in `maps.json`. `--pack`
names the pack folder directly instead. xomtool is found by `--xomtool`, `FOLDSPACE_XOMTOOL`,
`<melange>/dist/tools/xomtool.exe`, then `PATH`.

The sync rewrites the map's files and its `levels`/`meshes` entries in `spice.json`, deletes files of that map the pack
no longer has, and records the source in `maps.lock.json` (commit, branch, whether the pack folder had uncommitted
changes, each source file's SHA-256). Commit the result together with a CHANGELOG entry. `--verify` refuses a copy
taken from a pack with uncommitted changes, so sync from a commit.

`sync_map.py caldera --check` rebuilds the copy in memory and exits 1 if the committed files differ (needs the
checkout and xomtool). `--verify` needs neither: it checks that `spice.json`, `maps.json`, the patches, the banks and
the lock agree, that every mesh a patch names is shipped and every mesh a bank declares is used, that the README's "Needs
Melange" line matches `melange.range`, and that the CHANGELOG section is within the Store's 2000 characters.

## The minimum Melange version

`mod/spice.json` `melange.range` is the one place it lives. `sync_map.py` never changes it, and refuses to sync a pack
whose own range asks for a newer Melange. It has to equal the first Melange release that carries the Erg work these
maps need: mesh banks named by levels, thrown mines, the scheme's sudden-death sea and the raised mesh-instance pool.
When that release's version is fixed, set the range to it and change the README's "Needs Melange" line and the
CHANGELOG to match (`--verify` compares the README line with the range).

## Adding a map

1. Build and ship the map in the Melange repo as Caldera is (its `ship.mjs` writes the source pack).
2. Add `"<slug>": {"pack": "<path of the pack in the checkout>"}` to `maps.json`. The slug is 1-24 of `a-z0-9`.
3. Run `sync_map.py <slug>` and `--verify`. Mind the limits: 32 maps per mod, and 44 mesh-bank sections shared by
   every enabled mod (each Foldspace map uses one bank; Kindjal alone uses 38). Put all of a map's meshes in one bank
   (the Melange repo's `meshes/merge.mjs` does that for Caldera).
4. Describe the map in the README, add screenshots (1920x1080 JPEG, under 1 MiB each, at most 6 in all), bump
   `spice.json`'s version and add a CHANGELOG section.
