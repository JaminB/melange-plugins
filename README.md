# melange-plugins

The curated plugin store for [Melange](https://github.com/JaminB/melange), the modding framework for Worms Ultimate
Mayhem. This repo holds the metadata, source and release workflow behind the **Store** page in Melange's in-game
overlay and its Oasis web panel.

## Browsing and installing

Open **Thumper > Store** in the overlay, or the **Store** panel in Oasis. Melange fetches the plugin list from this
repo's `index.json` only when you open the Store or press *Refresh* — nothing happens in the background, and offline
play is unaffected. Every release's SHA-256 hash is pinned in the index and checked before anything is installed; a
plugin asking for raw memory access (**Deep Desert**) still needs your consent in the game, separately, every time
its code changes.

You can also browse `plugins/` here directly, or read `index.json` to see exactly what Melange sees.

## What's in this repo

```
plugins/<id>/        one plugin: its metadata, licence, changelog, screenshots and mod source
schema/               JSON Schema for store.json and index.json
policy/               the executables allow-list and the reserved-ids list
tools/                the validator, packer and index generator (store.py), plus its tests
index.json            generated; what Melange actually reads
```

Each plugin's `mod/` folder is the exact Thumper mod folder it installs as `Mods\<id>\`. Release zips are attached to
GitHub Releases of this repo, not committed here; see [CONTRIBUTING.md](CONTRIBUTING.md) for how a release is built.

## Submitting a plugin

See [CONTRIBUTING.md](CONTRIBUTING.md). In short: a pull request adds `plugins/<id>/` (source, metadata, licence,
changelog); a maintainer reviews it, merges it, and then runs the release workflow that packs the zip, publishes it
as a GitHub Release, and opens a second PR adding the release to the index. Nothing is downloadable from the Store
until that second PR is merged.

## Privacy

The Store's only network traffic is HTTPS `GET`s, from GitHub, of the index and the files you choose to fetch or
install. No telemetry, no accounts, no install counts.

## Licence

The repo's own tooling and docs are MIT (see [LICENSE](LICENSE)). Each plugin carries its own licence in
`plugins/<id>/LICENSE`, named in its `store.json`.
