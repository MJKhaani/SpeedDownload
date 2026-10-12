# Speed Download

<p align="center">
  <img src="Resources/logo.png" alt="Speed Download logo" width="180">
</p>

Speed Download is a free, open-source download manager in active development. Its portable Zig core currently provides a headless HTTP(S) CLI prototype with interruption recovery. A native Capy desktop interface and supported platform combinations remain under feasibility review.

## Project status

- Product requirements and release gates: [`PROJECT.md`](PROJECT.md)
- Contributor and agent workflow: [`Agent.md`](Agent.md)
- Platform feasibility: [`docs/support-matrix.md`](docs/support-matrix.md)
- Core state rules: [`docs/download-state-machine.md`](docs/download-state-machine.md)
- Zig and Capy decision record: [`docs/adr/0001-zig-capy-toolchain.md`](docs/adr/0001-zig-capy-toolchain.md)
- License and dependency notes: [`docs/licenses.md`](docs/licenses.md)

The required GUI toolkit is Capy UI. [`src/ui/main.zig`](src/ui/main.zig) contains an early downloads-window layout prototype; it is not integrated into the build or connected to the downloader. A reproducible Capy build is currently blocked: Capy targets Zig 0.14.1, while the engine uses Zig 0.17.0, and the local macOS Capy dependency chain did not build. See the ADR for the compiler and backend findings. Do not treat the prototype as a working GUI release.

## Build

Build the command-line prototype and run the unit and local HTTP integration checks (Zig 0.17.0 and Python 3):

```sh
mkdir -p zig-out/bin
zig build-exe src/main.zig -femit-bin=zig-out/bin/speed-download
zig test src/core/root.zig
zig test src/core/queue.zig
zig test src/protocols/http/download.zig
python3 tests/integration/http_cli.py zig-out/bin/speed-download
zig-out/bin/speed-download --help
```

The CLI currently supports a single HTTP(S) transfer with redirects, strict response validation, safe resume for credential-free URLs when the server provides a known length and strong ETag, and optional `--sha256 <64-hex-digits>` verification before publishing the final file. It stores a versioned journal beside the `.part` file and only resumes bytes covered by a durable checkpoint. The core also has a host-aware queue selection policy, but it is not connected to durable jobs or transfer workers. The CLI does not yet provide a persistent job queue, user-directed pause/cancel, parallel ranges, or GUI. Do not treat successful cross-compilation as proof of native GUI, packaging, or runtime support. Follow [`Agent.md`](Agent.md) when contributing.

## License

Application source is licensed under the MIT License. Third-party components retain their own licenses; review [`docs/licenses.md`](docs/licenses.md) before adding dependencies.
