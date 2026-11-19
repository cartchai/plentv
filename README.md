<h1>
  <img src="assets/plezy.png" alt="PlezTV logo" height="24" style="vertical-align: middle;" />
  PlezTV
</h1>

A fork of [Plezy](https://github.com/edde746/plezy) that adds IPTV: M3U playlists and Xtream Codes accounts, with live TV in the Live TV section and on-demand movies and series in the Library.

PlezTV is beta. 1.1 is the functioning update — TV, movies and live TV all play and search — with lots left to do.

<p>
  <a href="#plezy-upstream">Plezy (upstream)</a> ·
  <a href="#what-pleztv-adds">What PlezTV adds</a> ·
  <a href="#install">Install</a> ·
  <a href="CONTRIBUTING.md">Contributing</a> ·
  <a href="LICENSE">License</a>
</p>

## What PlezTV adds

Everything in Plezy, plus IPTV.

### Shipped in 1.1

- **M3U and Xtream Codes import** — Add connection → M3U or Xtream Codes. Each library is given a name when you add it, and labelled by its source (M3U or Xtream Codes).
- **Live TV from IPTV in the Live TV tab** — IPTV channels appear in Live TV, not as a library. A source picker above the guide switches between live TV sources (All sources, or one server at a time).
- **On-demand in the Library** — movies and series from an Xtream account appear as Movies and Series libraries, with Recommended and Browse.
- **Search** — as-you-type search reads the local/cached catalog only; online search happens only after Enter. The catalog syncs weekly, plus a manual refresh; cache size is in Settings → IPTV.
- **EPG** — xmltv.php is the primary Xtream EPG source, per-channel short EPG is the fallback. The guide parses the XMLTV feed as a stream, so a cold guide open has no big memory spike. The day picker covers the requested day.
- **Resume / Continue Watching** — playback positions save after 5 s, finished items clear at 90%, all local.
- **Weekly background sync** — the catalog refreshes in the background, never while playing.
- **Country/region filter** — turn whole categories (countries and regions) on or off per connection, from the connection's edit screen. Hidden groups filter at read time, so turning a group back on brings its titles back immediately.
- **IPTV settings** — Settings → Connections → IPTV: your IPTV connections, Manage groups with Show all / Hide all, Refresh playlists, and a Show catch-up badge toggle.
- **Live-channel favourites** — favourite live channels from the channel menu.
- **Catch-up badge** — guide channels that offer catch-up show a badge, so you can see it at a glance. Catch-up itself is gated on the channel offering an archive.
- **In-app updater** — new versions are offered in the app and install over the top. The updater compares version names.
- **Version scheme** — our version first, then upstream's: `1.5.0-2.26.0` means PlezTV 1.5.0 on Plezy 2.26.0.

## Plezy (upstream)

Plezy is a modern client for Plex, Jellyfin, and Emby on desktop, mobile, and TV, built with Flutter. It is a separate project by [edde746](https://github.com/edde746) and contributors — PlezTV is based on Plezy 2.26.0.

- Upstream repo: https://github.com/edde746/plezy
- Upstream releases and updates: https://github.com/edde746/plezy/releases
- The full Plezy feature list (playback, DVR, Explore, Watch Together, and more) lives in the [upstream README](https://github.com/edde746/plezy#readme). Anything listed there is Plezy's work, not PlezTV's.

## Install

PlezTV is **not on any app store** — no Google Play, App Store, F-Droid, or Amazon listing exists, and there is nothing to download from a store.

- **Android:** APKs are published as [GitHub Releases](https://github.com/cartchai/pleztv/releases). The in-app updater offers new versions and installs them over the top.
- PlezTV installs alongside the original Plezy (package `com.pleztv.app`), so your Plezy install is untouched.

## Building

Prerequisites: Flutter SDK 3.47.9, and Java 17 for the Android build. Releases are built by GitHub Actions (`.github/workflows/android-release.yml`) — push a tag like `v1.5-2.26.0` and the workflow builds the APK and creates the release. Codemagic is the backup builder — see [codemagic.yaml](codemagic.yaml).

```bash
git clone https://github.com/cartchai/pleztv.git
cd pleztv
flutter pub get
scripts/codegen.sh
flutter build apk --debug
```

After modifying model classes or other generated sources, re-run `scripts/codegen.sh`. After modifying translations, run `dart run slang`.

## Features

### <img src="assets/readme_icons/browse.svg" height="20" alt="" align="center" /> Browse & Discover
- Libraries, collections, and playlists — video and audio
- Shuffle a whole movie or TV library
- Discover hub — Continue Watching, Next Up, trending, and recommendations
- Continue Watching shows a title held in several libraries or on several servers once, and asks which copy to play
- Cross-server search across every connected Plex, Jellyfin, and Emby server, including actors and directors
- Filtering, sorting, and alphabetical jump navigation
- Folder browsing and folder playback — home-video libraries open in folder view
- Resolution, HDR/Dolby Vision, and audio-format badges on cards and detail pages
- Favorites and unwatched library filters[^mb]
- Extras — trailers, deleted scenes, behind-the-scenes

### <img src="assets/readme_icons/explore.svg" height="20" alt="" align="center" /> Explore & Requests
- Explore tab — watchlist, trending, popular, and recommendation rows from Plex Discover[^plex], Trakt, MyAnimeList, AniList, Simkl, and Seerr[^connect]
- Search any connected catalog source
- Catalog titles matched back to your own libraries by external ID
- Seerr — request movies and shows with per-season, 4K, and advanced destination options, and see request status inline
- Watchlist sync — add and remove titles on Plex, Trakt, MyAnimeList, AniList, and Simkl from anywhere in the app

### <img src="assets/readme_icons/playback.svg" height="20" alt="" align="center" /> Playback
- Wide codec support (HEVC, AV1, VP9, and more)
- HDR and Dolby Vision[^hdr]
- Direct play, or transcode presets from 240p/320 kbps to 1080p/20 Mbps
- Multi-version switching with per-version file details
- Full ASS/SSA subtitles with customizable styling
- Online subtitle search & download[^plex]
- Audio & subtitle choices remembered per title, or follow the server's per-episode selections
- Progress sync and resume
- Auto-play next episode with skip intro / skip credits
- Chapter navigation with thumbnail scrub previews
- Playback speed from 0.25x to 8x, audio sync offset, sleep timer (fixed durations or end of video)
- Video zoom 50-200% with pinch, presets, and hotkeys
- Audio passthrough[^pass], output channel limit (5.1 or stereo, with center-channel boost), and loudness normalization
- File Info sheet — every version, file, and stream the server reports
- Ambient lighting and GLSL shader presets[^mpv]
- Picture-in-Picture[^pip]
- Refresh-rate matching[^rrm]
- External player launch (VLC, MX Player, etc.) with progress sync back[^android]

### <img src="assets/readme_icons/music.svg" height="20" alt="" align="center" /> Music
- Music libraries — artist, album, and track browsing with square artwork
- Album and artist screens with play, shuffle, and Instant Mix
- Gapless playback with a full play queue — reorder, remove, play next, add to queue
- Now Playing with synced lyrics[^lyrics], persistent mini-player, and sleep timer
- Background playback with lock-screen, media-key, and notification controls[^bgaudio]
- Offline playback of downloaded albums and tracks
- Streaming quality presets — Original, 320, 192, or 128 kbps

### <img src="assets/readme_icons/live-tv.svg" height="20" alt="" align="center" /> Live TV & DVR
- Live TV channel browsing, tuning, and favorites
- EPG guide with What's On and per-show schedules
- DVR recording rules, scheduled recordings, and a rememberable recording target library[^plex]
- Multi-server Live TV support where available

### <img src="assets/readme_icons/downloads.svg" height="20" alt="" align="center" /> Downloads & Offline
- Download movies, shows, and music for offline playback[^dl]
- Background queue with pause / resume
- Sync rules for automatic downloads, with per-show "Include Specials"
- Offline browsing with watch state sync-back on reconnect

### <img src="assets/readme_icons/watch-together.svg" height="20" alt="" align="center" /> Watch Together
- Rooms on [Open Watch Party](https://openwatch.party) — share a six-character code; friends join from Plezy or another Open Watch Party app
- Everyone plays their own copy from their own server — Plex, Jellyfin, or Emby — matched by catalogue IDs, with a picker when several copies fit
- Synchronized play / pause / seek, host or shared control, room lock, and host handoff
- Public relays by default, or point Plezy at your own self-hosted relay

### <img src="assets/readme_icons/integrations.svg" height="20" alt="" align="center" /> Integrations
- Discord Rich Presence[^desktop]
- Trakt, MyAnimeList, AniList, and Simkl — ratings, watched sync, and real-time scrobbling[^rt]
- Scores from connected trackers on detail pages — Trakt, Simkl, MyAnimeList, and AniList, plus Rotten Tomatoes, Metacritic, Letterboxd, IMDb, and TMDB through MDBList
- Plezy Remote — control desktop and TV from mobile
- Watch Next row and tvOS Top Shelf[^shelf]
- [`plezy://` links](#plezy-links) to open a profile, play a title, or tune a channel from Home Assistant, launchers, or an NFC tag; any movie, show, or episode menu shows its link[^links]

### <img src="assets/readme_icons/customization.svg" height="20" alt="" align="center" /> Platform & Customization
- Desktop, mobile, and TV — full D-pad, keyboard, and gamepad support
- Multiple servers at once — Plex, Jellyfin, and Emby side by side
- Profiles with per-profile downloads, watch state, and settings; Plex Home switching with PIN
- Jellyfin and Emby local-server discovery and multiple URLs per server; Quick Connect sign-in[^jf]
- TV layout options — corner spotlight backdrop, full-card artwork, and Force TV mode on desktop
- Customizable keyboard shortcuts[^desktop]
- Metadata and artwork editing
- Settings import/export
- Localized in English plus 21 translations

[^jf]: Jellyfin only.
[^mb]: Jellyfin and Emby only.
[^plex]: Plex only.
[^connect]: Requires connecting the service under Settings > Services.
[^hdr]: In-app HDR toggle on Windows, macOS, iOS, tvOS, and Linux — Linux needs a colour-managed Wayland compositor. Dolby Vision on Android, macOS, and Apple TV.
[^pass]: Desktop, Android TV, and Apple TV.
[^mpv]: Requires the mpv player backend — Android defaults to ExoPlayer. Not applied to Dolby Vision on Apple platforms.
[^pip]: Android, iOS, and macOS — not on Android TV or Apple TV.
[^rrm]: Windows, Android, and tvOS.
[^android]: Progress sync on Android.
[^lyrics]: Where your server provides lyrics.
[^bgaudio]: tvOS pauses music when the app is backgrounded.
[^dl]: Not available on tvOS.
[^desktop]: Desktop only.
[^rt]: Real-time scrobbling on Trakt and Simkl; MyAnimeList and AniList update on completion.
[^shelf]: Android TV / Fire TV and tvOS.
[^links]: Android, iOS, macOS, and tvOS.


## plezy:// links

Links start Plezy from outside the app. Any link may add `profile=<profile>`: a profile id, a Plex Home user UUID, or a display name (ignoring case; it must match one profile). Plezy switches to that profile first, and a protected profile still asks for its PIN. A link replaces whatever is playing.

| Link | Does |
|---|---|
| `plezy://open` | Opens Plezy |
| `plezy://play?server=<server>&id=<item>` | Plays one item on one server, any backend |
| `plezy://play?type=movie\|show&tmdb=<n>` | Plays a title from whichever server has it. Use `tmdb`, `tvdb`, `imdb=tt<n>`, or `plex=<hash>` (the Plex GUID without `plex://movie/`) |
| `plezy://live?channel=<channel>` | Tunes a Live TV channel by key, number, or call sign. Optional `server=<server>` and `start=beginning\|live` |

For a show, `mode=next` (the default) plays the next episode to watch, and `mode=shuffle` plays the show shuffled. The menu of any movie, show, or episode has **Show link**, and each profile's menu in **Switch Profile** has **Show profile link**. Both show the link as text and a QR code.

```sh
# Android / Android TV, over adb (Home Assistant: remote.turn_on with activity: plezy://...)
adb shell am start -a android.intent.action.VIEW -d "plezy://play?type=show\&tvdb=81189\&profile=Kids"
# macOS
open "plezy://play?type=movie&tmdb=603"
```

On iOS, use the Open URLs action in Shortcuts.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development workflow, formatting, tests, and translation guidelines.

## License

PlezTV is licensed under [GPL-3.0](LICENSE), the same as upstream Plezy. This fork stays GPL-3.0. The license covers the code, not the Plezy name or logo; forks distributed beyond personal use must follow [TRADEMARKS.md](TRADEMARKS.md).

## Acknowledgments

- Based on [Plezy](https://github.com/edde746/plezy) by edde746 and contributors.
- Built with [Flutter](https://flutter.dev). Playback powered by [mpv](https://mpv.io), Android [ExoPlayer](https://developer.android.com/media/media3/exoplayer), and [libass](https://github.com/peerless2012/libass-android).
