# Notch

A native Dynamic Island for the MacBook notch. Notch turns the camera housing into a live,
interactive island: music, timers, downloads, notifications, meetings, system stats and
more, without getting in your way.

Built with SwiftUI and AppKit. Event-driven and lightweight: about **21 MB** of memory and
**~0% CPU** while you work.

## What's new in 1.2.0

- **Notifications in the notch.** WhatsApp, Slack, Teams, Mail and more drop down from the
  notch. Reply right there, use the app's own buttons (Mark as Read, Archive…), open or
  dismiss them, and find recent ones in the new Notifications tab. [More](#notifications)
- **One-click setup for video downloads.** No Homebrew or Terminal: **Set Up** downloads
  yt-dlp, FFmpeg and Deno, checks each against its checksum, and keeps yt-dlp up to date.
  With Deno, YouTube downloads get every format. [More](#download-tools)
- **Fixes:** the island no longer freezes while macOS asks for access to your Downloads
  folder. Dropped downloads now resume where they stopped.

## What's new in 1.1.0

- **Browser downloads in the notch.** Downloads from Safari, Chrome, Brave, Edge and Arc show
  their progress in the island, with no extension or setup. Cancel them from the notch, and
  find the finished file in the Downloads tab. [More](#browser-downloads)
- **Optional: Notch does the downloading.** A browser extension for Chrome-based browsers and
  Firefox hands downloads over to Notch, with a choice of which file types it takes.
- **Any file, not just videos.** Paste a link to a PDF, image, zip or DMG and Notch downloads it
  directly, without yt-dlp. Files get type icons, Quick Look previews and **Open With**.
- **Cancel button** on every download that's running or waiting.

See the [releases page](https://github.com/Zena4L/notch/releases) for details.

## Features

| | |
|---|---|
| **Now Playing** | Album art, a waveform tinted by the artwork, a progress bar you can scrub, and playback controls. Works with Music, Spotify, browsers and Podcasts. |
| **Lyrics** | Synced lyrics that follow the song (click a line to jump to it), from [LRCLIB](https://lrclib.net). Open them with the 💬 button in the player. |
| **Timers** | Countdown and stopwatch, with a split bubble when two things are running at once. |
| **Downloads** | Paste a link from X, YouTube or 1,000+ other sites to save the video or audio (via yt-dlp, set up with one click), or a link to any file. Downloads from Safari, Chrome, Brave, Edge and Arc show their progress in the notch automatically, and you can cancel them there. With the optional [browser extension](Extension/README.md), Notch does the downloading itself. Drag files out, AirDrop or share them. |
| **Dashboard** | Widgets for CPU, memory, storage, network, battery, weather, today's events and clipboard history. |
| **Notifications** | WhatsApp, Slack, Teams, Mail and more show under the notch. Reply, use the app's own buttons (Mark as Read, Archive…) or dismiss them without opening the app, and find recent ones in the Notifications tab. Optional, needs Accessibility. |
| **Calendar** | A reminder before meetings, with a **Join** button for Zoom, Google Meet and Teams links. |
| **Volume & brightness** | Replaces the system overlay with one from the notch (optional). |
| **Battery** | Peeks when you plug in, unplug or run low. |
| **Settings** | Almost everything is configurable, including the island's look, which activities show, shortcuts and `notch://` links. |

## Download

### Quick install (recommended)

Paste this into **Terminal**:

```sh
curl -fsSL https://raw.githubusercontent.com/Zena4L/notch/HEAD/scripts/install.sh | bash
```

The [installer](scripts/install.sh) downloads the latest release, checks it against its
SHA-256 checksum, installs Notch into Applications and opens it. Run the same command again
to update; it quits the running Notch first.

Files downloaded with `curl` aren't marked as coming from the internet, so macOS opens
Notch straight away, without the "could not verify" warning.

You can set these options before `bash`:

| Option | Example | Effect |
|---|---|---|
| `NOTCH_VERSION` | `NOTCH_VERSION=1.0.0` | Install a specific version |
| `NOTCH_INSTALL_DIR` | `NOTCH_INSTALL_DIR=~/Applications` | Install somewhere else (the installer falls back to `~/Applications` by itself if it can't write to `/Applications`) |
| `NOTCH_NO_OPEN` | `NOTCH_NO_OPEN=1` | Don't open Notch after installing |

For example: `curl -fsSL https://raw.githubusercontent.com/Zena4L/notch/HEAD/scripts/install.sh | NOTCH_VERSION=1.0.0 bash`

### Download the DMG

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
- [Homebrew](https://brew.sh), to install XcodeGen (building only; the app itself doesn't need it).

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

## Using Notch

- **Hover** the notch to expand the island. Move away, or press **Esc**, to close it.
- **Click** the menu bar icon for Settings and Quit.

### Download tools

Video downloads need three free tools: [yt-dlp](https://github.com/yt-dlp/yt-dlp),
[FFmpeg](https://ffmpeg.org) and [Deno](https://deno.com). Deno lets yt-dlp get every YouTube
format. Click **Set Up** in the Downloads tab (or **Settings › Activities › Downloads**) and
Notch handles the rest. It downloads about 150 MB, checks each file against its SHA-256
checksum, and installs everything into `~/Library/Application Support/Notch/Tools`. There's
no Homebrew and no Terminal involved, and Notch keeps yt-dlp up to date by itself.

FFmpeg ([martin-riedl.de](https://ffmpeg.martin-riedl.de) static builds) and Deno are pinned to
the versions tested with each Notch release. yt-dlp follows its latest release, checked
against the checksums published with it. **Remove** in Settings deletes them again.

If you already have yt-dlp and FFmpeg from Homebrew, Notch uses those. **Use Notch's Own** in
Settings switches to Notch's set, which includes Deno.

Only download videos you have the right to keep. Some sites' terms, including YouTube's,
restrict downloading. Links straight to a file (a PDF, a zip, a DMG…) don't need these tools.

### Browser downloads

There's nothing to set up. When you download something in Safari, Chrome, Brave, Edge or Arc,
it shows in the notch: live progress (with ✕ to cancel it), then a peek and the finished file
in the Downloads tab, ready to drag, AirDrop or share. Browsers publish their download progress
to macOS, and Notch follows it for your Downloads folder. Small files that finish in about a
second (Chrome-based browsers don't report progress for those) appear as soon as they're done.
You can turn this off in **Settings › Activities › Browser downloads**.

**Optional: let Notch do the downloading.** With the Notch extension, Chrome, Edge, Brave, Arc
or Firefox hand downloads over to Notch, which saves them itself:

1. Turn on **Settings › Activities › Browser downloads › Let Notch do the downloading**, and
   choose which file types Notch should take (documents, images, archives, apps and disk
   images, video and audio, everything else).
2. Click **Show Extension Folder** and load it as an unpacked extension (`chrome://extensions` ›
   Developer mode › Load unpacked; in Firefox, `about:debugging` › Load Temporary Add-on). It's
   also attached to each release as `Notch-Extension-x.y.z.zip`.

If Notch isn't running, or can't fetch a file, the browser downloads it as usual. Notch
listens on `127.0.0.1:47821` only, and accepts downloads only from the extension. Files are
marked as downloaded from the internet, so macOS still checks apps and disk images.
The extension doesn't work in Safari. See [Extension/README.md](Extension/README.md).

### Notifications

Turn on **Settings › Activities › Notifications** and give Notch Accessibility access. When
a message arrives from WhatsApp, Slack, Teams, Mail, Messages, Outlook, Discord, Telegram or
Signal (or from any app, if you choose), it drops down from the notch:

- **Reply** opens a text field right in the island. Press ↩ to send; the reply goes through
  the app's own inline reply, as if you'd used the macOS banner.
- **The app's own buttons**, like Mark as Read or Archive, work from the island too.
- **Open** (or a click on the message) takes you to the conversation; ✕ dismisses it.
- The **Notifications tab** (🔔) keeps the last 30, with the same buttons.

Notch closes the macOS banner once it's in the notch. Banners with Reply or other buttons stay
until you use them, because macOS only accepts those buttons while the banner is on screen.
For the same reason, Reply works best within a few seconds of the notification arriving.
After that, Notch opens the app with your reply copied, ready to paste.

To see it without waiting for a message, use **Settings › General › Try it › Notification**.
If a notification doesn't show up, **Copy Diagnostics** in the same settings copies what your
banners look like to Notch, for a bug report.

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
| Notifications | Accessibility | To read notification banners and press their buttons (macOS has no other way for apps to see each other's notifications) |
| Weather from your location | Location | Rounded to about 1 km; you can type a city instead |
| Clipboard history | Pasteboard | macOS may ask whether Notch can read what other apps copy |

## Privacy

- No analytics and no account.
- **Network** requests happen only for features you use:
  - lyrics: the song title and artist go to lrclib.net, when you open lyrics;
  - weather: the city or rounded location goes to Open-Meteo, when the dashboard opens;
  - downloads: yt-dlp contacts the video's site; files go straight to the site they came from;
  - download tools: setting them up fetches yt-dlp from GitHub, FFmpeg from martin-riedl.de and
    Deno from dl.deno.land, and Notch checks GitHub once a day for a newer yt-dlp.
- **Browser downloads**: the extension sends the file's link, name and your cookies for that
  site to Notch on your own Mac (`127.0.0.1`). The cookies are kept in memory only.
- **Clipboard history** is kept in memory only, and skips passwords from password managers.
- **Notifications** are read from the banners on screen, kept in memory only (the last 30),
  and forgotten when Notch quits. Replies go through each app's own inline reply.

## Development

```sh
xcodebuild -project Notch.xcodeproj -scheme Notch test
```

| Folder | What's inside |
|---|---|
| `Notch/App` | App entry point, menu bar, shortcuts, `notch://` links |
| `Notch/Island` | The island's views and the state model (`IslandState`, `IslandCoordinator`) |
| `Notch/Services` | Now Playing, timers, battery, calendar, downloads (and the tool installer, browser watcher and extension bridge), notifications, lyrics, weather, stats, HUD |
| `Notch/Settings` | The Settings window and `SettingsStore` |
| `Notch/Window` | The notch panel, hover zones, multi-display and full-screen handling |
| `NotchTests` | Unit tests |
| `Extension` | The browser extension that hands downloads over to Notch (Chromium and Firefox) |
| `.github/workflows` | CI (tests on every push) and Release (DMG on every version tag) |
| `Vendor/MediaRemoteAdapter` | Prebuilt helper for reading Now Playing on macOS 15.4+ |
| `scripts/` | `install.sh` (the one-line installer), `release.sh` (builds the DMG), `make-icon.swift` (draws the app icon), `build-mediaremote-adapter.sh` (rebuilds the helper) |

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
`Notch-1.2.0.dmg` and `Notch-Extension-1.2.0.zip` with `scripts/release.sh`, and publishes
them on the Releases page with install notes. If the release already exists (say, the tag
was pushed again), it replaces the files instead. To build locally, run
`scripts/release.sh 1.2.0`.

The tools Notch sets up for video downloads are pinned in `ToolInstaller.standardAssets`
(FFmpeg and Deno, with their SHA-256 checksums). yt-dlp always follows its latest release.

## Acknowledgements

- [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter): BSD 3-Clause, © Jonas van den Berg
- [yt-dlp](https://github.com/yt-dlp/yt-dlp): Unlicense
- [FFmpeg](https://ffmpeg.org): GPL
- [LRCLIB](https://lrclib.net) for lyrics, and [Open-Meteo](https://open-meteo.com) for weather

## License

[GPL-3.0](LICENSE)
