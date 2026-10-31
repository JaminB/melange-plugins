## 1.1.0

- Anyone in the watch party can add videos: paste a YouTube link, playlist or magnet link in the setup panel and the host's Holo checks it and adds it to the queue, marked with who added it. Members can remove what they added. The host can keep adding to themselves with the new "Who can add to the queue" setting. Needs the host on Holo 1.1.
- Spotify music (needs Melange 0.13 and a Spotify app Client ID in Melange.ini): link your Spotify account in the new Music tab, add songs from your saved songs and playlists to the party's music queue, and everyone who linked Spotify Premium hears the same song on their own Spotify, kept in step with the host. Others see what is playing. The music keeps going when you hide or minimise the player or close the panel; it stops on Stop music, at the end of the queue, or when you or the host leave the lobby.
- Music pauses while a party video plays (host setting), and the game music stays silent while party music plays. A now-playing chip shows the song and opens the Music tab.

## 1.0.2

- While a magnet link's file list is being fetched, the setup panel says so and shows how many peers were found, and warns when none turn up after a minute. A magnet carries no file list; it comes from peers, which can take a minute or more.

## 1.0.1

- Adding a link now always says what happened: a torrent tells you when the video player could not start, and a YouTube link tells you when Melange has not downloaded yt-dlp yet.

## 1.0.0

First release. Needs Melange 0.12.0 or later.

- Watch parties: the lobby host plays YouTube videos, playlists or magnet links in a themed in-game player, synced for every player who has Holo.
- Corner player while you play, half-screen player during other players' turns (online), pill when minimised.
- Setup panel (F6): add links, queue with reorder and remove, torrent file picker, player list with pack and ping status.
- Game music is silenced during a party (setting).
- Media pack and yt-dlp download once, only after you click Download.
- Torrents share your IP address with the swarm.
