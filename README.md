# Speed Download

<p align="center">
  <img src="Resources/logo.png" alt="Speed Download logo" width="180">
</p>

Speed Download is a free, open-source download manager in active development. Its Zig core currently provides a headless HTTP(S) CLI prototype with interruption recovery and an early local IPC protocol implementation. Native SwiftUI, WinUI 3, and GTK 4 clients are planned.

## Project status

- Product requirements and release gates: [`PROJECT.md`](PROJECT.md)
- Contributor and agent workflow: [`Agent.md`](Agent.md)
- Platform feasibility: [`docs/support-matrix.md`](docs/support-matrix.md)
- Core state rules: [`docs/download-state-machine.md`](docs/download-state-machine.md)
- Native GUI and local IPC decision: [`docs/adr/0001-native-guis-local-ipc.md`](docs/adr/0001-native-guis-local-ipc.md)
- IPC v1 contract: [`docs/protocols/ipc-v1.md`](docs/protocols/ipc-v1.md)
- License and dependency notes: [`docs/licenses.md`](docs/licenses.md)

The Zig code has bounded JSON framing, `engine.hello` feature negotiation, per-connection handshake state, and a sequential macOS/Linux Unix-domain socket adapter that checks the connecting user's UID. `speed-download engine` starts the early engine listener. Application job methods, durable jobs, Windows named pipes, and native clients remain pending. No IPC platform has runtime validation yet; see [`docs/support-matrix.md`](docs/support-matrix.md).

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

The CLI currently supports a single HTTP(S) transfer with redirects, strict response validation, safe resume for credential-free URLs when the server provides a known length and strong ETag, and optional `--sha256 <64-hex-digits>` verification before publishing the final file. It stores a versioned journal beside the `.part` file and only resumes bytes covered by a durable checkpoint. The core also has a host-aware queue selection policy, but it is not connected to durable jobs or transfer workers. The CLI does not yet provide a persistent job queue, user-directed pause/cancel, parallel ranges, or IPC integration. Follow [`Agent.md`](Agent.md) when contributing.

## License

Application source is licensed under the MIT License. Third-party components retain their own licenses; review [`docs/licenses.md`](docs/licenses.md) before adding dependencies.
