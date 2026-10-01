## What is this

<!-- New plugin, or an update to an existing one. Link any related issue. -->

## Checklist

- [ ] `plugins/<id>/mod/` is the exact Thumper mod folder (`spice.json` is explicit, not implicit)
- [ ] `plugins/<id>/LICENSE` is present and its SPDX id is in `store.json`'s `licence` (from the allow-list)
- [ ] `plugins/<id>/store.json` has no fields that `spice.json` already provides
- [ ] This is my own work, or I have the right to submit it under the stated licence
- [ ] No game files, and nothing extracted or derived from them, are included
- [ ] For an update: `spice.json` `version` is higher than the newest released version, and `CHANGELOG.md` has a
      section for it
- [ ] `tools/validate.ps1` (or `python tools/store.py validate plugins/<id>`) passes locally
- [ ] Any `permissions.unsafe` or filesystem access is explained below

## Permissions

<!-- If the mod asks for Deep Desert (permissions.unsafe) or filesystem access, say why. Leave blank otherwise. -->
