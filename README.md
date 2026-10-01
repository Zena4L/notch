# Notch

A native Dynamic Island for the MacBook notch. Notch turns the camera housing into a live,
interactive island: music, timers, downloads, meetings, system stats and more, without
getting in your way.

Built with SwiftUI and AppKit. Event-driven and lightweight: about **21 MB** of memory and
**~0% CPU** while you work.

## Features

| | |
|---|---|
| **Now Playing** | Album art, a waveform tinted by the artwork, a progress bar you can scrub, and playback controls. Works with Music, Spotify, browsers and Podcasts. |
| **Lyrics** | Synced lyrics that follow the song (click a line to jump to it), from [LRCLIB](https://lrclib.net). Open them with the 💬 button in the player. |
| **Timers** | Countdown and stopwatch, with a split bubble when two things are running at once. |
| **Downloads** | Paste a link from X, YouTube or 1,000+ other sites to save the video or audio (via yt-dlp). Drag files out, AirDrop or share them. |
| **Dashboard** | Widgets for CPU, memory, storage, network, battery, weather, today's events and clipboard history. |
| **Calendar** | A reminder before meetings, with a **Join** button for Zoom, Google Meet and Teams links. |
| **Volume & brightness** | Replaces the system overlay with one from the notch (optional). |
| **Battery** | Peeks when you plug in, unplug or run low. |
| **Settings** | Almost everything is configurable, including the island's look, which activities show, shortcuts and `notch://` links. |

## Download

Get the latest **Notch-x.y.z.dmg** from the [Releases page](https://github.com/Zena4L/notch/releases/latest).

1. Open the DMG and drag **Notch** into **Applications**.
2. Open Notch. macOS will say it can't verify the developer. Click **Done**.
3. Open **System Settings › Privacy & Security**, scroll down, and click **Open Anyway** next to Notch.

You only need step 3 once. It's required because Notch isn't signed with a paid Apple
Developer ID yet. If you'd rather use Terminal, run this instead:

```sh
xattr -dr com.apple.quarantine /Applications/Notch.app
```

To update, download the new DMG and replace the app in Applications.

## Requirements

- A Mac with a notch (MacBook Pro 14″/16″ 2021 or later, MacBook Air 2022 or later).
  On other displays the island slides down from the menu bar instead.
- macOS 14 Sonoma or later. Liquid Glass materials need macOS 26 or later.
- Xcode 27 or later to build.
- [Homebrew](https://brew.sh), used for XcodeGen and, optionally, the download tools.

## Building from source

1. **Install XcodeGen.** It generates the Xcode project from `project.yml`.

   ```sh
   brew install xcodegen
   ```

2. **Clone the repo and generate the project.**

   ```sh
   git clone https://github.com/Zena4L/notch.git
   cd notch
   xcodegen
   ```

3. **Open the project in Xcode.**

   ```sh
   open Notch.xcodeproj
   ```

4. **Run it.** Choose the **Notch** scheme and **My Mac**, then press **⌘R**.
   The island appears over the notch and an icon appears in the menu bar. Notch has no
   Dock icon.

5. **Optional: set a signing team.** Without one, macOS treats every build as a new app and
   asks for Accessibility, Calendar and Location access again after each rebuild.
   - In Xcode › Settings › Accounts, add your Apple ID. A free account is enough.
   - Select the Notch target › Signing & Capabilities › Team, and choose your Personal Team.

> Run `xcodegen` again whenever you add or remove source files. Edits to existing files
> only need ⌘R.

### Download tools (optional)

The Downloads tab needs [yt-dlp](https://github.com/yt-dlp/yt-dlp) and
[FFmpeg](https://ffmpeg.org). Install them from the app (**Settings › Activities ›
Downloads › Install with Homebrew**) or yourself:

```sh
brew install yt-dlp ffmpeg
```

Only download videos you have the right to keep. Some sites' terms, including YouTube's,
restrict downloading.

## Using Notch

- **Hover** the notch to expand the island. Move away, or press **Esc**, to close it.
- **Click** the menu bar icon for Settings and Quit.

### Keyboard shortcuts

You can change these in **Settings › Shortcuts**.

| Shortcut | Action |
|---|---|
| ⌥⌘N | Open or close the island |
| ⌥⌘I | Show the dashboard |
| ⌥⌘T | Start a quick timer (5 minutes by default) |
| ⌥⌘P | Play / pause |
| ⌥⌘D | Show downloads |

### Links

Use these from the Shortcuts app ("Open URL") or Terminal (`open "notch://…"`):

```
notch://timer?minutes=25        notch://stopwatch
notch://play-pause              notch://next            notch://previous
notch://toggle                  notch://dashboard       notch://downloads
notch://download?url=<link>&quality=best|p1080|p720|audio
notch://settings
```

## Permissions

Everything that needs a permission is **off until you turn it on** in Settings, and asks
in place.

| Feature | Permission | Why |
|---|---|---|
| Calendar reminders, Today widget | Calendars | To read upcoming events |
| Volume & brightness overlay | Accessibility | To catch the media keys |
| Weather from your location | Location | Rounded to about 1 km; you can type a city instead |
| Clipboard history | Pasteboard | macOS may ask whether Notch can read what other apps copy |

## Privacy

- No analytics and no account.
- **Network** requests happen only for features you use:
  - lyrics: the song title and artist go to lrclib.net, when you open lyrics;
  - weather: the city or rounded location goes to Open-Meteo, when the dashboard opens;
  - downloads: yt-dlp contacts the video's site.
- **Clipboard history** is kept in memory only, and skips passwords from password managers.

## Development

```sh
xcodebuild -project Notch.xcodeproj -scheme Notch test
```

| Folder | What's inside |
|---|---|
| `Notch/App` | App entry point, menu bar, shortcuts, `notch://` links |
| `Notch/Island` | The island's views and the state model (`IslandState`, `IslandCoordinator`) |
| `Notch/Services` | Now Playing, timers, battery, calendar, downloads, lyrics, weather, stats, HUD |
| `Notch/Settings` | The Settings window and `SettingsStore` |
| `Notch/Window` | The notch panel, hover zones, multi-display and full-screen handling |
| `NotchTests` | Unit tests |
| `.github/workflows` | CI (tests on every push) and Release (DMG on every version tag) |
| `Vendor/MediaRemoteAdapter` | Prebuilt helper for reading Now Playing on macOS 15.4+ |
| `scripts/` | `release.sh` (builds the DMG), `make-icon.swift` (draws the app icon), `build-mediaremote-adapter.sh` (rebuilds the helper) |

Since macOS 15.4, only Apple-entitled processes can read Now Playing information directly.
Notch runs the bundled helper through the system's `/usr/bin/perl`, which is allowed to.
A small watchdog makes sure the helper stops whenever Notch does.

### Releasing

GitHub Actions builds and tests every push to `main`. To publish a release, push a version tag:

```sh
git tag v1.2.0
git push origin v1.2.0
```

The [Release workflow](.github/workflows/release.yml) runs the tests, builds
`Notch-1.2.0.dmg` with `scripts/release.sh`, and publishes it on the Releases page with
install notes. To build the DMG locally instead, run `scripts/release.sh 1.2.0`.

## Acknowledgements

- [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter): BSD 3-Clause, © Jonas van den Berg
- [yt-dlp](https://github.com/yt-dlp/yt-dlp): Unlicense
- [FFmpeg](https://ffmpeg.org): GPL
- [LRCLIB](https://lrclib.net) for lyrics, and [Open-Meteo](https://open-meteo.com) for weather

## License

[GPL-3.0](LICENSE)
