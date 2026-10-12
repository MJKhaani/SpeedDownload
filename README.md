# Open Download Manager

<p align="center">
  <img src="Resources/logo.png" alt="Open Download Manager logo" width="180">
</p>

Open Download Manager (ODM) is a planned free, open-source desktop download manager with a standalone transfer engine. The project is completing **Phase 0: feasibility** and starting the portable core foundation. No end-user download features or platform combinations are currently advertised as working.

## Project status

- Product requirements and release gates: [`PROJECT.md`](PROJECT.md)
- Contributor and agent workflow: [`Agent.md`](Agent.md)
- Platform feasibility: [`docs/support-matrix.md`](docs/support-matrix.md)
- Zig and Capy decision record: [`docs/adr/0001-zig-capy-toolchain.md`](docs/adr/0001-zig-capy-toolchain.md)
- License and dependency notes: [`docs/licenses.md`](docs/licenses.md)

The required GUI toolkit is Capy UI. Its compatibility with a pinned Zig compiler and every target platform must be demonstrated before UI implementation is treated as supported. See the ADR for current blockers. Zig 0.17.0 is available locally and is being evaluated for portable core work; Capy compatibility and the project-wide toolchain pin remain unresolved. The first core milestone is now under implementation.

## Build

Build the command-line prototype and run the unit tests:

```sh
mkdir -p zig-out/bin
zig build-exe src/main.zig -femit-bin=zig-out/bin/odm
zig test src/core/root.zig
zig test src/protocols/http/download.zig
python3 tests/integration/http_cli.py zig-out/bin/odm
```

The CLI currently supports a single HTTP(S) transfer. It writes an exclusive `.part` file and publishes it after a successful response; pause/resume, persistence, checksums, parallel ranges, and GUI are not implemented. The build uses Zig 0.17.0 for independent core evaluation. Do not treat successful cross-compilation as proof of native GUI, packaging, or runtime support. Follow [`Agent.md`](Agent.md) when contributing.

## License

Application source is licensed under the MIT License. Third-party components retain their own licenses; review [`docs/licenses.md`](docs/licenses.md) before adding dependencies.
