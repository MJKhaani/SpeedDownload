# Contributing

Thanks for helping build Speed Download. The project is in early implementation; read [`PROJECT.md`](PROJECT.md) and [`Agent.md`](Agent.md) before proposing implementation changes. These documents define platform caveats, safety invariants, and validation expectations.

## Before changing code

1. Check the current phase and target status in the project documents.
2. Keep changes focused and do not present planned or untested behavior as implemented.
3. For toolchain, dependency, protocol, or platform decisions, record evidence and update the relevant ADR or support documentation.
4. Preserve third-party license notices and avoid adding dependencies until their license and target compatibility have been reviewed.

## Changes and verification

Describe the behavior and relevant requirement IDs in a pull request. Include exact commands and results for checks that were run, and identify platforms not tested. Never include credentials, tokens, private URLs, or user download data in a change or log.

The current core is evaluated with Zig 0.17.0. Build and check the headless prototype with:

```sh
mkdir -p zig-out/bin
zig build-exe src/main.zig -femit-bin=zig-out/bin/speed-download
zig test src/core/root.zig
zig test src/core/queue.zig
zig test src/protocols/http/download.zig
python3 tests/integration/http_cli.py zig-out/bin/speed-download
```

The integration fixture uses loopback networking only. Platform support remains unvalidated outside the development host.

## License

By submitting a contribution, you agree that it is released under the repository's [MIT License](LICENSE). Contributions must be your own or submitted with permission, and must not include incompatible third-party material.
