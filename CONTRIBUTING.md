# Contributing a plugin

A plugin here is a **store listing** (`plugins/<id>/`) for an ordinary Thumper **mod** (`plugins/<id>/mod/`, which
installs as `Mods\<id>\`). All changes go through a pull request; `CODEOWNERS` means every PR needs the maintainer's
review before it can merge.

## 1. Pick an id

- Matches the spice id pattern: lowercase letters, digits, `-` and `_`, 1-64 characters, starting and ending with a
  letter or digit (`^[a-z0-9](?:[a-z0-9_-]{0,62}[a-z0-9])?$`).
- Equal to the folder name `plugins/<id>/` and to `mod/spice.json`'s `id`. It's permanent — a rename is a new plugin.
- Not in `policy/reserved-ids.txt`, and not a twin of an existing id that differs only by `-`/`_` (e.g. `hd-water`
  and `hd_water` can't both be listed).

## 2. Lay out the plugin

```
plugins/<id>/
  store.json          store-only metadata (below) - no versions[] yet, that's added by the release workflow
  LICENSE             your plugin's licence text, non-empty
  CHANGELOG.md         "## <version>" sections, newest first
  screenshots/         optional, 1.png .. 6.png (or .jpg), 1920x1080 or smaller, 1 MiB each
  mod/                 the Thumper mod folder exactly as it installs
    spice.json          required and explicit (an implicit/inferred manifest is not accepted)
    ...
```

`store.json` holds only what `spice.json` doesn't already say:

```json
{
  "storeVersion": 1,
  "licence": "MIT",
  "homepage": "https://github.com/you/your-plugin",
  "categories": ["graphics"],
  "gameBuilds": ["1077"],
  "screenshots": [{ "file": "1.png", "caption": "Before and after" }]
}
```

- `licence`: an SPDX id from the allow-list in `schema/store-1.schema.json` (also listed in `tools/store.py`).
- `categories`: 1-3 of `graphics gameplay maps weapons audio interface tools libraries`.
- `gameBuilds`: game builds you've tested on. Only `"1077"` exists today.
- Don't add `versions[]` yourself — the release workflow writes it.

Extra requirements the store puts on `spice.json`: `melange.range` is a lower bound only (`">=0.3.0"`, never
`<0.5.0`, `^` or `~`): Melange moves a plugin out of `Mods\` as soon as the running version leaves its range, so an
upper limit would break every install on the next Melange release. `authors` needs at least one name, `description` is 1-400
characters, `defaultEnabled` must be absent or `true`, every `settings[]` entry needs a `label`, and
`permissions.network` must be absent or `false` (Melange plugins don't get direct network access).

## 3. Validate locally

```powershell
tools\validate.ps1 -Plugin your-id
```

It finds a Python (`MELANGE_PYTHON`, then a Melange checkout's portable copy, then `py`/`python`), runs the unit
tests, then every check `check.yml` runs on your PR: schema, identity, licence, layout, executables, file types,
sizes, and that `index.json` isn't stale. You can also build the exact release zip and drop it into `Mods\` to test
it in-game: `python tools/store.py pack your-id --out dist`.

## 4. Open the PR

Fill in the PR template's checklist. `check.yml` runs read-only, with no secrets, against your PR. A maintainer
reviews the mod itself (licence, game content as described below, what any requested permission is for) — automated
checks don't replace that review.

### Game content

A plugin may ship assets derived from the game, for example a copy of a vanilla model that has been reshaped and
repainted, or a texture painted into a vanilla model's UV layout. Two things are not allowed:

- **Overwriting or modifying game files in place.** A plugin never replaces, patches or writes to a file in the game
  folder (`Data\`, the executable, the language and tweak banks). Its assets are its own files, under its own names,
  loaded by Melange next to the game's (mesh banks under `<modId>.*` resource names, loose files named `<modId>.*`).
- **Shipping a stock game file unchanged.** A file that is just a copy of one of the game's own files, under its
  name or another, doesn't belong in a plugin; `policy/stock-names.txt` catches the obvious cases by name.

Say in the plugin's README which assets are derived from the game, so players and reviewers know what they are
getting.

## 5. Release (maintainer only)

After merge, a maintainer runs `release.yml` (`workflow_dispatch`, `id` + `version`), which packs the zip, publishes
it as a GitHub Release asset, verifies the uploaded hash, and opens a "Release `<id>` `<version>`" PR adding the
`versions[]` entry and regenerating `index.json`. The plugin isn't visible in the Store until that second PR merges.

## Updating an existing plugin

Bump `spice.json`'s `version` above the newest released one, add a `CHANGELOG.md` section for it, and open a PR the
same way. A plugin's `versions[]` history is immutable once merged (only a `yanked: true` flag can be added later, to
pull a broken release).
