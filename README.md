# Speed Download

<p align="center">
  <img src="Resources/logo.png" alt="Speed Download logo" width="180">
</p>

Speed Download is a free, open-source download manager in active development. Its Zig core provides a headless HTTP(S) downloader with interruption recovery, validated parallel ranges, and a local IPC engine. Native SwiftUI (macOS), GTK 4 (Linux), and WinUI 3 (Windows) client source is present; the Linux and Windows clients and all platform runtime integrations still need builds and validation.

## macOS client

![Speed Download macOS client showing transfers and the inspector](Resources/macos-client.png)

## Project status

- Product requirements and release gates: [`PROJECT.md`](PROJECT.md)
- Contributor and agent workflow: [`Agent.md`](Agent.md)
- Platform feasibility: [`docs/support-matrix.md`](docs/support-matrix.md)
- Phase 0 native CI workflow: [`.github/workflows/phase0.yml`](.github/workflows/phase0.yml)
- Core state rules: [`docs/download-state-machine.md`](docs/download-state-machine.md)
- Native GUI and local IPC decision: [`docs/adr/0001-native-guis-local-ipc.md`](docs/adr/0001-native-guis-local-ipc.md)
- Linux GTK 4 client: [`linux/SpeedDownload/README.md`](linux/SpeedDownload/README.md)
- Windows WinUI 3 client: [`windows/SpeedDownload/README.md`](windows/SpeedDownload/README.md)
- IPC v1 contract: [`docs/protocols/ipc-v1.md`](docs/protocols/ipc-v1.md)
- IPC request schema: [`docs/protocols/ipc-v1.schema.json`](docs/protocols/ipc-v1.schema.json)
- License and dependency notes: [`docs/licenses.md`](docs/licenses.md)

The Zig code has bounded JSON framing, `engine.hello` feature negotiation, per-connection handshake state, and persistent job RPCs. The macOS/Linux Unix-domain socket adapter authenticates the connecting user's UID; the Windows named-pipe adapter scopes the pipe to the current user/session, applies a private DACL, and rejects remote clients. Each listener supports up to 32 concurrent client sessions. `speed-download engine` starts the engine listener. Starting a queued HTTP(S) job drains the queue through a host-aware scheduler with configurable global concurrency and two jobs per host; range-capable jobs may use up to 32 validated HTTP requests each when configured. The HTTP driver uses redirect and representation checks, strong-ETag range resume, synced segment checkpoints, and atomic no-replace publication. Native SwiftUI, GTK 4, and WinUI 3 client source covers job listing, add, controls, and progress snapshots. The Windows engine and client now compile for x86_64 targets, but Windows native runtime behavior and WinUI packaging have not been validated. The macOS client waits for engine change signals before refreshing its snapshot. Dynamic reallocation during a transfer and full live event subscriptions remain unimplemented. See [`docs/support-matrix.md`](docs/support-matrix.md).

## Build

Build the command-line prototype and run the unit and local HTTP integration checks (Zig 0.17.0 and Python 3):

```sh
mkdir -p zig-out/bin
zig build-exe src/main.zig -femit-bin=zig-out/bin/speed-download
zig test src/core/root.zig
zig test src/core/queue.zig
zig test src/protocols/http/download.zig
zig build ipc
zig build ipc-unix
python3 tests/integration/http_cli.py zig-out/bin/speed-download
zig-out/bin/speed-download --help
```

Start the IPC engine with `zig build-exe src/main.zig -lc -femit-bin=zig-out/bin/speed-download && zig-out/bin/speed-download engine` on macOS/Linux, or `zig build-exe src/main.zig -femit-bin=zig-out/bin/speed-download.exe && zig-out/bin/speed-download.exe engine` on Windows. macOS listens under `$TMPDIR/speed-download/engine.sock`; Linux listens under `$XDG_RUNTIME_DIR/speed-download/engine.sock`; Windows creates a current-user/session named pipe. Unix runtime directories must be private and owned by the current user.

Job records are saved atomically under `~/Library/Application Support/Speed Download/jobs.json` on macOS, or `$XDG_STATE_HOME/speed-download/jobs.json` (falling back to `~/.local/state/speed-download/jobs.json`) on Linux. Set `SPEED_DOWNLOAD_STATE_DIR` to override the state directory.

Use the engine RPC CLI while the engine is running:

```sh
speed-download rpc list
speed-download rpc add https://example.com/archive.zip "$HOME/Downloads" "archive.zip"
speed-download rpc add https://example.com/archive.zip "$HOME/Downloads" --sha256 <64-hex-digits>
speed-download rpc control <job-id> start <revision>
speed-download rpc control <job-id> pause <revision>
speed-download rpc reorder <job-id> <zero-based-position> <revision>
speed-download rpc delete <job-id> <revision> [--delete-partial]
```

`rpc list` prints one JSON-RPC response containing up to 50 jobs. `rpc add` accepts an existing destination folder, an optional filename, and an optional SHA-256 digest for completion verification. `rpc control`, `rpc reorder`, and `rpc delete` require the current job revision shown by `rpc list`; refresh the list after a stale-revision error. Reordering applies to queued, paused, or retry-wait jobs. Deleting removes the job record and leaves completed downloads untouched. `--delete-partial` also removes partial data for an inactive job.

The engine automatically retries transient network failures and HTTP 429 or 503 responses up to three times. It honors a server `Retry-After` delay up to one hour; queued retries remain visible and can be paused or resumed immediately.
After a 429 or 503 response, each automatic retry opens fewer connections for that job, down to one.
Each download can have its own speed cap through its macOS transfer actions. This cap is saved with the job and can be changed while it is downloading. The global and scheduled caps still apply.

Build a runnable macOS app bundle, including its engine helper, with `bash macos/SpeedDownload/package-app.sh`. Open `dist/Speed Download.app`; the GUI starts the bundled engine when it cannot connect to an existing one. Linux and Windows clients follow the same connect-first, launch-if-needed behavior. Set `SPEED_DOWNLOAD_ENGINE_PATH` to override helper discovery.

The macOS client can show native completion and failure notifications while it is running. Enable each category in Settings → General; macOS will ask for notification permission. The same pane offers a native launch at login control managed by macOS Login Items. The engine reads macOS static HTTP and HTTPS proxy settings, including simple-host and exact or wildcard host exceptions, and applies custom unauthenticated HTTP and HTTPS proxy endpoints to link inspection and downloads. Automatic proxy scripts, SOCKS5, CIDR exceptions, and authenticated proxy transfers are still pending; unsupported system configurations fail rather than silently connecting directly. Proxy exception matching currently uses the original request host when the server redirects.

On macOS, `speeddownload://add?url=<percent-encoded-download-URL>` opens the Add Download dialog with the URL filled in. HTTP, HTTPS, anonymous FTP, and anonymous explicit FTPS links are accepted. The link is inspected by the engine and requires the user to choose **Add to Queue**; opening the app link never starts a transfer by itself. Browser extensions and native-messaging hosts are still future work.

You can also drop an HTTP, HTTPS, FTP, or FTPS link onto the macOS window to open the same Add Download dialog. The transfer starts only after you confirm it.
Use File → Add Download from Clipboard (⇧⌘V) to inspect a copied link, or File → New Download (⌘N) to open an empty dialog.
The macOS list can be sorted by queue order, name, size, or status; queue order is the default and sorting does not change the engine's scheduling order.

The HTTP(S) transfer routine validates redirects and responses, resumes with strong validators, and publishes the final file without replacing an existing destination. Eligible servers receive a real range probe followed by concurrent, non-overlapping HTTP range requests; completed extents are synced and recorded in an atomic segment journal. Idle workers can divide the untouched tail of an active range at a durable checkpoint. Unsupported or unsuitable responses use the single-stream path. The CLI supports direct `--sha256 <64-hex-digits>` downloads, and the macOS Add Download dialog accepts an optional SHA-256 checksum for queued jobs. The engine verifies that digest before publishing the completed file. The engine runs multiple jobs concurrently through a host-aware scheduler, with cooperative pause/cancel and durable progress checkpoints. Transient connection failures use up to three persisted automatic retries with 2, 4, and 8 second backoff. An interrupted in-flight segment is fetched again from its last checkpoint on resume. Live event subscriptions remain outstanding.

Anonymous passive FTP and explicit FTPS are available as initial engine sources for direct downloads and queued jobs. FTPS uses `AUTH TLS` on port 21 by default, verifies the server certificate against the system trust store, and requires encrypted data transfer with `PBSZ 0` and `PROT P`. The driver probes `SIZE`, `MDTM`, and `REST`, uses `EPSV` or `PASV`, checkpoints partial bytes, and checks remote metadata before resuming. FTP currently uses one data connection per job. Authenticated FTP, implicit FTPS, and FTP through a proxy are not implemented; see [FTP protocol status](docs/protocols/ftp.md). Follow [`Agent.md`](Agent.md) when contributing.

BitTorrent v1 metainfo inspection is available with `speed-download torrent-info <file.torrent>`. It validates bencoding, paths, file sizes, and piece counts, then prints JSON including the raw v1 info hash. It does not start a torrent transfer. See [BitTorrent status](docs/protocols/torrent.md).
Magnet URI inspection is available with `speed-download magnet-info '<magnet-uri>'`. It decodes the v1 info hash, display name, and trackers; torrent metadata retrieval and transfers remain in progress.
For magnets containing an explicit `x.pe` peer or an HTTP(S) or UDP tracker, `speed-download magnet-metadata '<magnet-uri>' output.torrent` can retrieve and verify torrent metadata. The macOS Add Download dialog and engine queue now accept v1 magnets for initial single-file downloads with piece verification and verified-piece resume. This path has not been exercised against a live swarm; DHT, multi-file torrents, and seeding are not yet implemented.

## License

Application source is licensed under the MIT License. Third-party components retain their own licenses; review [`docs/licenses.md`](docs/licenses.md) before adding dependencies.
