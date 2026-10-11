# Contributing

Thanks for helping build Open Download Manager. The project is in feasibility work; read [`PROJECT.md`](PROJECT.md) and [`Agent.md`](Agent.md) before proposing implementation changes. These documents define platform caveats, safety invariants, and validation expectations.

## Before changing code

1. Check the current phase and target status in the project documents.
2. Keep changes focused and do not present planned or untested behavior as implemented.
3. For toolchain, dependency, protocol, or platform decisions, record evidence and update the relevant ADR or support documentation.
4. Preserve third-party license notices and avoid adding dependencies until their license and target compatibility have been reviewed.

## Changes and verification

Describe the behavior and relevant requirement IDs in a pull request. Include exact commands and results for checks that were run, and identify platforms not tested. Never include credentials, tokens, private URLs, or user download data in a change or log.

The Zig build and test commands will be documented here once their manifests and targets are established. The current planning-only repository has no build or test target.

## License

By submitting a contribution, you agree that it is released under the repository's [MIT License](LICENSE). Contributions must be your own or submitted with permission, and must not include incompatible third-party material.
