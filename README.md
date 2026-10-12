# Open Download Manager

<p align="center">
  <img src="Resources/logo.png" alt="Open Download Manager logo" width="180">
</p>

Open Download Manager (ODM) is a free, open-source download manager in active development. Its portable Zig core currently provides a headless HTTP(S) CLI prototype with interruption recovery. The Capy desktop interface and supported platform combinations remain under feasibility review.

## Project status

- Product requirements and release gates: [`PROJECT.md`](PROJECT.md)
- Contributor and agent workflow: [`Agent.md`](Agent.md)
- Platform feasibility: [`docs/support-matrix.md`](docs/support-matrix.md)
- Core state rules: [`docs/download-state-machine.md`](docs/download-state-machine.md)
- Zig and Capy decision record: [`docs/adr/0001-zig-capy-toolchain.md`](docs/adr/0001-zig-capy-toolchain.md)
- License and dependency notes: [`docs/licenses.md`](docs/licenses.md)

The required GUI toolkit is Capy UI. Its compatibility with a pinned Zig compiler and every target platform must be demonstrated before UI implementation is treated as supported. See the ADR for current blockers. Zig 0.17.0 builds the independent core and is not yet approved as the Capy toolchain.

## Build

Build the command-line prototype and run the unit and local HTTP integration checks (Zig 0.17.0 and Python 3):

```sh
mkdir -p zig-out/bin
zig build-exe src/main.zig -femit-bin=zig-out/bin/odm
zig test src/core/root.zig
zig test src/protocols/http/download.zig
python3 tests/integration/http_cli.py zig-out/bin/odm
zig-out/bin/odm --help
```

The CLI currently supports a single HTTP(S) transfer with redirects, strict response validation, and safe resume for credential-free URLs when the server provides a known length and strong ETag. It stores a versioned journal beside the `.part` file and only resumes bytes covered by a durable checkpoint. It does not yet provide a persistent job queue, user-directed pause/cancel, checksums, parallel ranges, or GUI. Do not treat successful cross-compilation as proof of native GUI, packaging, or runtime support. Follow [`Agent.md`](Agent.md) when contributing.

## License

Application source is licensed under the MIT License. Third-party components retain their own licenses; review [`docs/licenses.md`](docs/licenses.md) before adding dependencies.
