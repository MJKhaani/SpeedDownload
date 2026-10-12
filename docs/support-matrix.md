# Platform Support and Feasibility Matrix

**Status date:** 2026-10-12
**Current project phase:** Phase 0 feasibility; portable core implementation has started
**Meaning:** “Not validated” means no native build/runtime evidence is available. Cross-compilation alone cannot change a target to supported.

## Current evidence

Zig 0.17.0 builds the portable core module and a single-stream HTTP(S) CLI with checkpointed resume and optional SHA-256 verification. Automated local fixtures cover redirects, destination races, status/encoding rejection, interrupted transfer recovery, changed ETags, redirect-target changes, and matching/mismatching checksums. The Capy UI is blocked pending a compatible production-ready toolkit release: the current upstream README says Capy is not production-ready and targets Zig 0.14.1, while this core uses Zig 0.17.0. Upstream lists macOS M1/x86_64 as planned and does not list Windows ARM64. No Capy checkout or GUI build manifest is present.

## Target matrix

| OS | CPU | Engine/CLI | Capy GUI | Native runtime/package | Status / next evidence |
|---|---|---:|---:|---:|---|
| Windows | x86 (32-bit) | Not validated | Not validated | Not validated | Build and run core; prototype GUI, accessibility and package on native host. |
| Windows | x86_64 | Not validated | Not validated | Not validated | Build and run core; GUI component and package smoke tests. |
| Windows | ARM64 | Not validated | Not validated | Not validated | Must be prototyped and run on validated ARM64 hardware/runner; backend status open. |
| Linux | x86 (32-bit) | Not validated | Not validated | Not validated | Verify ABI, GTK4/runtime dependencies, 64-bit file offsets, package and native run. |
| Linux | x86_64 | Not validated | Not validated | Not validated | Verify GTK4 dependencies, Capy components, accessibility and package on named distro. |
| Linux | ARM64 | Not validated | Not validated | Not validated | Native build/runtime and package validation required; not inferred from cross-build. |
| Linux | ARM32 | Not validated | Not validated | Not validated | Stretch target; assess ABI, OS dependencies and runner/hardware separately. |
| macOS | x86_64 | Not validated | Blocked pending backend validation | Not validated | Capy backend was listed as planned in project source review; verify on Intel host. |
| macOS | ARM64 | Not validated | Blocked pending backend validation | Not validated | Capy backend was listed as planned in project source review; verify on Apple Silicon host. |

## Core module check

On 2026-10-12, Zig 0.17.0 compiled the CLI and passed six core state tests, three HTTP parser tests, and local HTTP integration checks on macOS 14.8.4 x86_64. Fixtures verify redirects, binary transfer, overwrite protection including concurrent destination creation, error cleanup, interrupted resume, changed-validator rejection, and matching/mismatching checksum verification. No other OS/CPU target, HTTPS certificate behavior, GUI, or package is validated. Current Capy limitations are documented in [ADR 0001](adr/0001-zig-capy-toolchain.md) and the [upstream README](https://github.com/capy-ui/capy#readme).

No target is currently supported or release-certified. For each target, record exact compiler/dependency revisions, OS version, CPU, backend, commands, native smoke-test results, accessibility checks, and packaging results before changing its status.

## Phase 0 exit work

- Select a Zig version and exact Capy commit only after the pair builds reproducibly.
- Prototype window creation, native events, text/list/scrolling, progress drawing, keyboard access, theme and DPI behavior, and packaging.
- Validate Windows x86/x64 and Linux x86/x64/ARM64; investigate macOS x64/ARM64 and Windows ARM64 on actual hosts.
- Separately compile and exercise the headless core/CLI on relevant targets.
- Record blockers and backend/widget gaps in [`adr/0001-zig-capy-toolchain.md`](adr/0001-zig-capy-toolchain.md).
