# Open Download Manager

Open Download Manager (ODM) is a planned free, open-source desktop download manager with a standalone transfer engine. The project is currently in **Phase 0: feasibility**. No application features or platform combinations are currently advertised as working.

## Project status

- Product requirements and release gates: [`PROJECT.md`](PROJECT.md)
- Contributor and agent workflow: [`Agent.md`](Agent.md)
- Platform feasibility: [`docs/support-matrix.md`](docs/support-matrix.md)
- Zig and Capy decision record: [`docs/adr/0001-zig-capy-toolchain.md`](docs/adr/0001-zig-capy-toolchain.md)
- License and dependency notes: [`docs/licenses.md`](docs/licenses.md)

The required GUI toolkit is Capy UI. Its compatibility with a pinned Zig compiler and every target platform must be demonstrated before UI implementation is treated as supported. See the ADR for current blockers. Zig is not currently pinned as a working toolchain, and this repository does not yet contain a build manifest or executable.

## Build

The project has no buildable application target yet. Once a Zig toolchain and a `build.zig` have been verified, the intended build command is:

```sh
zig build
```

Do not treat successful cross-compilation as proof of native GUI, packaging, or runtime support. Follow [`Agent.md`](Agent.md) when contributing.

## License

Application source is licensed under the MIT License. Third-party components retain their own licenses; review [`docs/licenses.md`](docs/licenses.md) before adding dependencies.
