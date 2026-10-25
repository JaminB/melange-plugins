# Holo

Client-side watch parties for Worms Ultimate Mayhem: the lobby host plays YouTube videos and playlists or magnet links
in a themed in-game player, synced for every player who has Holo. Needs Melange 0.12.0 or later.

This README is a stub; the full text (controls, settings, network use, limits, credits) is written with the release.

The Lua sources are in `src/`, one fragment per file. `python tools/build_lua.py` joins them into
`mod/client/init.lua` (committed); `python tools/tests/run_tests.py` runs the offline tests.
