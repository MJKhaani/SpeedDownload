# Speed Download

<p align="center">
  <img src="Resources/logo.png" alt="Speed Download logo" width="160">
</p>

A free, open-source download manager with a Zig engine and native desktop clients.
Speed Download is in active development, with macOS as the current focus.

![Speed Download on macOS](Resources/macos-client.png)

## Features

- **Parallel downloads:** multiple connections per HTTP(S) download, with automatic fallback when the server does not support byte ranges.
- **Pause and resume:** persistent queues and download checkpoints, with checks to avoid resuming changed content.
- **Queue controls:** priorities, concurrent download limits, and a weekly start/stop schedule.
- **Bandwidth controls:** global and per-download limits, plus scheduled limits for times such as office hours.
- **Transfer details:** total download speed, per-task progress, and an inspector showing individual worker progress.
- **Torrent and magnet review:** choose files, edit trackers, and select a destination before queueing a BitTorrent v1 download.
- **Browser integration:** send a link or links from a selected area of a page to the client; optionally intercept browser downloads.
- **Native macOS integration:** menu bar controls, notifications, launch at login, file icons, and `.torrent` and `magnet:` registration.

The GUI starts the bundled engine when needed. Transfers are managed by the engine,
so closing a client window does not stop them.

## Current availability

| Component | Status |
| --- | --- |
| macOS client | Runnable SwiftUI app; requires macOS 14 or later. |
| Windows and Linux clients | Source included; further client work and native runtime validation are deferred. |
| Engine and CLI | HTTP(S), initial anonymous FTP/FTPS support, and experimental BitTorrent v1 transfers. |
| Browser extensions | Experimental Chrome and Firefox extensions for the macOS client. |

FTP/FTPS interoperability and BitTorrent transfers against live swarms still need
validation. BitTorrent seeding and v2 torrents are not implemented. Browser
extensions are development builds; live-browser validation and store distribution
remain outstanding. See the [support matrix](docs/support-matrix.md) for detailed
platform and feature limitations.

## Build and run

### macOS app

Prerequisites: **Zig 0.17.0**, **Swift 6**, and the macOS SDK supplied by Xcode or
its Command Line Tools.

```sh
git clone https://github.com/MJKhaani/SpeedDownload.git
cd SpeedDownload
bash macos/SpeedDownload/package-app.sh
open "dist/Speed Download.app"
```

The bundle includes the engine and browser native-messaging helper. Add a download
with **⌘N**, paste a link with **⇧⌘V**, or drop a link onto the window. Open a
`.torrent` file or magnet link to review its files and trackers before downloading.
Configure the download folder, connections, proxy, bandwidth, and schedules in
**Speed Download → Settings…**.

### Engine and CLI

From the repository root:

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/speed-download --help
./zig-out/bin/speed-download engine
```

The engine runs locally and saves queue state and settings for the current user.
On macOS, its state is stored in `~/Library/Application Support/Speed Download`.
Set `SPEED_DOWNLOAD_STATE_DIR` to use a different state directory.

### Browser extensions

Follow the setup instructions for [Chrome](docs/browser-chrome.md) or
[Firefox](docs/browser-firefox.md). A single link opens the client's Add dialog;
multiple links open a review dialog with checkboxes. Torrent links open the torrent
review dialog. Downloads start after confirmation in the client.

The extension communicates with the **client**, which communicates with the engine.
Automatic browser download interception is off by default.

## Development

The engine owns transfers, scheduling, and persistence. Native clients communicate
with it through local IPC: SwiftUI on macOS, WinUI 3 on Windows, and GTK 4 on Linux.

- [Project plan and requirements](PROJECT.md)
- [Contribution workflow](Agent.md)
- [Architecture decision](docs/adr/0001-native-guis-local-ipc.md)
- [IPC protocol](docs/protocols/ipc-v1.md) and [download state model](docs/download-state-machine.md)
- [FTP/FTPS details](docs/protocols/ftp.md) and [BitTorrent details](docs/protocols/torrent.md)
- [Windows client](windows/SpeedDownload/README.md) and [Linux client](linux/SpeedDownload/README.md)

GitHub Actions includes [platform checks](.github/workflows/phase0.yml) and a
[tag build workflow](.github/workflows/tag-build.yml) that builds CLI and native
client artifacts for tags matching `v*`.

## License

Speed Download is licensed under the [MIT License](LICENSE).
Third-party components retain their own licenses; see [dependency notices](docs/licenses.md).
