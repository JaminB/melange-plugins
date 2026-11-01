# Holo

Client-side watch parties for Worms Ultimate Mayhem. In an online lobby the host picks YouTube videos, playlists or
magnet links; every player who has Holo sees the same video in a themed in-game player, kept in sync with the host. It
also works offline as a solo player. Needs Melange 0.12.0 or later and, for video, its media pack. With Melange 0.13.0
or later the party can also play Spotify music: each listener hears it on their own Spotify account. With Melange
0.14.0 you sign in to Spotify right in the game.

## Using it

- **F6** opens the watch party panel on its **Videos** tab: paste a link and press Enter, reorder or remove queue items,
  then Start. Members can add to the queue and remove what they added (see below); the rest is the host's.
- Between your turns the player is a small corner window. During other players' turns (online) it grows to half the
  screen. It hides while you aim and fire (setting), and **F9** hides or shows it.
- The mouse is the game's in a match. Press **F7** (or open the panel) to move the mouse to the player; Esc or a click
  outside ends it, and it ends by itself when your turn starts. The corner "..." menu has previous/next, speed (host),
  audio track, quality, queue and minimise.
- The host controls play, pause, seek and speed for everyone; **Ctrl+Shift+P** plays or pauses. Everyone controls their
  own volume, mute, subtitles and audio track.
- While the host's party is running, any member can paste a YouTube link, playlist or magnet link in the setup panel to
  add it to the queue (it shows who added it) and can remove the items they added while the party runs; the host can
  turn this off with the "Who can add to the queue" setting. An add the host's Holo asks to slow down is sent again once,
  and when the host's Holo cannot add a link (too many torrents open, no media pack) the panel says it is the host's to fix.
  The queue stored for "Restore last queue" does not keep who added what.
- Hotkeys, side, size, quality, volume and music silencing are in the plugin's settings.

## Spotify music (optional, Melange 0.13+)

The **Music** tab of the watch party panel (F6, or "Music" in the player's "..." menu) holds the party's music queue.
Anyone in the lobby who signed in to Spotify adds songs from their saved songs and playlists (unless the host set "Who
can add to the queue" to the host). When the host plays the queue, every member who signed in with **Spotify Premium**
hears the same song on **their own Spotify**, kept in step with the host.
Spotify plays it on a **device**: any Spotify app signed in to your account (the desktop app on this PC, your phone, a
speaker, a console or the web player). Members without Spotify, without Premium or without an open device see what is
playing (the panel says why they do not hear it). The host does not need Spotify. A now-playing chip at the top of the
screen shows the song and opens the Music tab.

Setup, in the game (Melange 0.14 or later):

1. In the Music tab, press **Sign in with Spotify**. Spotify's own page opens in your browser: log in and press Agree.
   The game comes back by itself and shows your account (your name; Premium or Free once Spotify has told, at the
   first song). Nothing to edit in `Melange.ini`.
2. Spotify lets the shared app that comes with Melange sign in only a few accounts. If Holo says your account is not on
   the shared app's list, press **Set up my Spotify app** and follow the three steps in the game:
   - **Open Spotify for Developers** and press Create app (any name and description).
   - Add the Redirect URI Holo shows (press **Copy**; it is `http://127.0.0.1:8780/callback` unless you changed
     `[Spotify] RedirectPort`), tick **Web API** and save.
   - Copy the app's **Client ID** from its Settings and press **Paste**, which saves it and signs you in (or press
     Ctrl+V in the box, then **Save and sign in**).

   Friends who use your app go under **User Management** in your app's dashboard (their Spotify e-mail), or they make
   their own app the same way. **Change app** on the account card sets up another app, or goes back from yours to the
   shared one (or to the one in `Melange.ini`).
3. Under **Plays on**, pick the device the party's music plays on. Holo moves the music there and remembers it (also
   when Spotify gives the web player a new id). **Cancel** while signing in does not sign you out; **Sign out** does.

Older Melange (0.13): there is no in-game setup. Register an app as in step 2, put its **Client ID** into
`Melange.ini` under `[Spotify]` as `ClientId=...`, then click **Link Spotify** in the Music tab and come back to the
game after allowing access. Cancel there signs you out. A device you pick there is used from the next song.

The music keeps playing when you hide (F9) or minimise the player, close the panel, a video ends or the video party
ends. It stops when the host presses Stop music, when the music queue ends, when you leave the lobby or when the host
leaves. **Mute here** (or the "Play the party's music on my Spotify" setting) stops it on your Spotify only. If you pick
something else in Spotify (or pause it there), Holo stops following until you press **Follow again** or the host's next
song starts, which plays on your Spotify again. To keep your own music for longer, use **Mute here**. While a party
video plays the host's music pauses (setting "Spotify music while a video plays"), and the game music stays silent while
party music plays.

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
  Sign in with Spotify. Melange (not Holo) keeps the sign-in, encrypted with Windows DPAPI on this PC
  (`%LOCALAPPDATA%\Melange\spotify`), and talks only to `accounts.spotify.com` and `api.spotify.com`; Holo never sees
  it. Holo reads your saved songs and playlists only to show them to you in the panel. Other party members receive only
  the songs you add (title, artists, length and Spotify URI) and your name as the one who added them. Spotify sees which
  songs your account plays, as with any Spotify app. Sign out in the Music tab, or remove the app at
  `spotify.com/account/apps`, to end it. The clipboard is written only when you press Copy. It is read when you
  press Paste (Holo then receives only a Client ID found there) or press Ctrl+V in a text box (Holo receives what you
  paste, as in any text box). A Client ID you set in the game is kept by Melange in
  `%LOCALAPPDATA%\Melange\spotify\client.json`; it is not a secret.

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
