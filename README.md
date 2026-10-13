# Speed Download

<p align="center">
  <img src="Resources/logo.png" alt="Speed Download logo" width="180">
</p>

Speed Download is a free, open-source download manager in active development. Its Zig core provides a headless HTTP(S) downloader with interruption recovery, validated parallel ranges, and a local IPC engine. Native SwiftUI (macOS), GTK 4 (Linux), and WinUI 3 (Windows) client source is present; the Linux and Windows clients and all platform runtime integrations still need builds and validation.

## Project status

- Product requirements and release gates: [`PROJECT.md`](PROJECT.md)
- Contributor and agent workflow: [`Agent.md`](Agent.md)
- Platform feasibility: [`docs/support-matrix.md`](docs/support-matrix.md)
- Core state rules: [`docs/download-state-machine.md`](docs/download-state-machine.md)
- Native GUI and local IPC decision: [`docs/adr/0001-native-guis-local-ipc.md`](docs/adr/0001-native-guis-local-ipc.md)
- Linux GTK 4 client: [`linux/SpeedDownload/README.md`](linux/SpeedDownload/README.md)
- Windows WinUI 3 client: [`windows/SpeedDownload/README.md`](windows/SpeedDownload/README.md)
- IPC v1 contract: [`docs/protocols/ipc-v1.md`](docs/protocols/ipc-v1.md)
- License and dependency notes: [`docs/licenses.md`](docs/licenses.md)

The Zig code has bounded JSON framing, `engine.hello` feature negotiation, per-connection handshake state, a macOS/Linux Unix-domain socket adapter that authenticates the connecting user's UID and serves up to 32 concurrent client sessions, and persistent job RPCs. `speed-download engine` starts the engine listener. Starting a queued HTTP(S) job drains the queue through a host-aware scheduler with up to four jobs globally and two per host; range-capable jobs may use up to four validated HTTP requests each. The HTTP driver uses redirect and representation checks, strong-ETag range resume, synced segment checkpoints, and atomic no-replace publication. Native SwiftUI, GTK 4, and WinUI 3 client source now covers job listing, add, controls, and progress snapshots. The macOS client connects to the current engine; Linux uses the current Unix socket contract. The Windows named-pipe server is not implemented, so its client cannot connect yet. Dynamic reallocation during a transfer and live event subscriptions are not implemented; all clients still poll for updates. See [`docs/support-matrix.md`](docs/support-matrix.md).

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

Start the Unix IPC engine on macOS or Linux with `zig build-exe src/main.zig -lc -femit-bin=zig-out/bin/speed-download && zig-out/bin/speed-download engine`. It listens at `$TMPDIR/speed-download/engine.sock` on macOS or `$XDG_RUNTIME_DIR/speed-download/engine.sock` on Linux. The runtime base must be a private directory owned by the current user.

Job records are saved atomically under `~/Library/Application Support/Speed Download/jobs.json` on macOS, or `$XDG_STATE_HOME/speed-download/jobs.json` (falling back to `~/.local/state/speed-download/jobs.json`) on Linux. Set `SPEED_DOWNLOAD_STATE_DIR` to override the state directory.

Build the macOS SwiftUI client from `macos/SpeedDownload` with `swift build -c release`. Run the `SpeedDownload` executable after starting the engine.

The HTTP(S) transfer routine validates redirects and responses, resumes with strong validators, and publishes the final file without replacing an existing destination. Eligible servers receive a real range probe followed by up to four concurrent, non-overlapping HTTP range requests; completed extents are synced and recorded in an atomic segment journal. Unsupported or unsuitable responses use the single-stream path. The CLI supports optional `--sha256 <64-hex-digits>` verification. The engine runs multiple jobs concurrently through a host-aware scheduler, with cooperative pause/cancel and durable progress checkpoints. Range subdivision currently happens before requests start, and an interrupted in-flight segment is fetched again on resume. CLI job controls and Windows/Linux GUI clients remain pending. Follow [`Agent.md`](Agent.md) when contributing.

## License

Application source is licensed under the MIT License. Third-party components retain their own licenses; review [`docs/licenses.md`](docs/licenses.md) before adding dependencies.
