# Holo

Client-side watch parties for Worms Ultimate Mayhem. In an online lobby the host picks YouTube videos, playlists or
magnet links; every player who has Holo sees the same video in a themed in-game player, kept in sync with the host. It
also works offline as a solo player. Needs Melange 0.12.0 or later and, for video, its media pack. With Melange 0.13.0
or later the party can also play Spotify music: each listener hears it on their own Spotify account.

## Using it

- **F6** opens the watch party panel: paste a link and press Enter, reorder or remove queue items, then Start. Peers see
  the panel read-only.
- Between your turns the player is a small corner window. During other players' turns (online) it grows to half the
  screen. It hides while you aim and fire (setting), and **F9** hides or shows it.
- The mouse is the game's in a match. Press **F7** (or open the panel) to move the mouse to the player; Esc or a click
  outside ends it, and it ends by itself when your turn starts. The corner "..." menu has previous/next, speed (host),
  audio track, quality, queue and minimise.
- The host controls play, pause, seek and speed for everyone; **Ctrl+Shift+P** plays or pauses. Everyone controls their
  own volume, mute, subtitles and audio track.
- While the host's party is running, any member can paste a YouTube link, playlist or magnet link in the setup panel to
  add it to the queue (it shows who added it) and can remove the items they added; the host can turn this off with the
  "Who can add to the queue" setting.
- Hotkeys, side, size, quality, volume and music silencing are in the plugin's settings.

## Spotify music (optional, Melange 0.13+)

The **Music** tab of the watch party panel (F6, or "Music" in the player's "..." menu) holds the party's music queue.
Anyone in the lobby who linked Spotify adds songs from their saved songs and playlists (unless the host set "Who can
add to the queue" to the host). When the host plays the queue, every member who linked **Spotify Premium** hears the
same song on **their own Spotify**, kept in step with the host.
Spotify plays it on an open Spotify app, the **device**: the desktop app on this PC, your phone or the web player. Members
without Spotify, without Premium or without an open device see what is playing (the panel says why they do not hear
it). The host does not need Spotify. A now-playing chip at the top of the screen shows the song and opens the Music tab.

Setup, once per person (or one friend registers the app and adds the others):

1. Register an app at [developer.spotify.com/dashboard](https://developer.spotify.com/dashboard) (any name).
2. Set its **Redirect URI** to `http://127.0.0.1:8780/callback`, exactly.
3. Choose the **Web API**.
4. Put the app's **Client ID** into `Melange.ini` under `[Spotify]` as `ClientId=...`.
5. While the app is in development mode, add your friends' Spotify e-mails under **User Management**. A friend can
   also use their own app.

Then click **Link Spotify** in the Music tab and allow access in your browser.

The music keeps playing when you hide (F9) or minimise the player, close the panel, a video ends or the video party
ends. It stops when the host presses Stop music, when the music queue ends, when you leave the lobby or when the host
leaves. **Mute here** (or the "Play the party's music on my Spotify" setting) stops it on your Spotify only. If you pick
something else in Spotify, Holo stops following until you press **Follow again**. While a party video plays the host's
music pauses (setting "Spotify music while a video plays"), and the game music stays silent while party music plays.

## What gets downloaded, and from where

Holo itself contains no video code. Melange core provides it, only after you press Download in the panel (it shows the
size, source and folder first):

- The **media pack** (playback helper, libmpv, deno) from `github.com/JaminB/melange` releases, over https, each file
  checked against a size and SHA-256 compiled into Melange. Stored in `Documents\Melange\media`.
- **yt-dlp**, from the same releases, updated at most daily. Not shipped in the pack so it can follow YouTube changes.
- Videos stream from YouTube or from torrent peers. Torrent data lives in `AppData\LocalLow\Melange\media-cache` and
  is deleted when the torrent closes.

`[Media] AllowDownload=0` in Melange's ini blocks all downloads. `uninstall.ps1 -Purge` and the Melange/Media overlay
panel remove everything.

## Privacy and network

- **Torrents share your IP address with the swarm**, and upload to other peers while open. Use them only if you are
  comfortable with that.
- YouTube links go to YouTube from your machine; the helper never receives anything a mod or another player sends as an
  option, only parsed video ids.
- Between players Holo sends only small playback messages (position, play state, queue) over the game's Steam
  connection, to lobby members who also run Holo. Logs exported by Melange redact links, magnets and infohashes.
- **Spotify** (only if you use it): the sign-in happens in your browser on Spotify's own page, and only after you click
  Link Spotify. Melange (not Holo) keeps the sign-in, encrypted with Windows DPAPI on this PC
  (`%LOCALAPPDATA%\Melange\spotify`), and talks only to `accounts.spotify.com` and `api.spotify.com`; Holo never sees
  it. Holo reads your saved songs and playlists only to show them to you in the panel. Other party members receive only
  the songs you add (title, artists, length and Spotify URI) and your name as the one who added them. Spotify sees which
  songs your account plays, as with any Spotify app. Unlink in the Music tab, or remove the app at
  `spotify.com/account/apps`, to end it.

## Antivirus and firewall

The first torrent may make Windows ask to allow `holo-media.exe` network access; YouTube does not need that. The helper
is signed, runs at low integrity and in a job that ends with the game. Some antivirus tools flag unfamiliar signed
helpers or downloaded executables; allow `Documents\Melange\media` if yours does.

## Credits and licences

Holo is MIT-licensed. Its panels, icons, cursor and font atlases in `mod/textures` and `mod/fonts` are generated by
the scripts in `tools/` (see `tools/README-art.md`). The fonts are **derived assets**: the atlases are baked from
Lilita One, Baloo 2 and Rubik, all under the SIL Open Font License 1.1, and renamed "Holo Display" and "Holo Body"
because Lilita One reserves its font name. The three licences are in `mod/fonts/OFL.txt`. libmpv (LGPL), yt-dlp
(Unlicense), deno (MIT) and libtorrent (BSD) are credited in Melange's media pack licences.

## Development

The Lua sources are in `src/`, one fragment per file. `python tools/build_lua.py` joins them into
`mod/client/init.lua` (committed); `python tools/tests/run_tests.py` runs the offline tests.
