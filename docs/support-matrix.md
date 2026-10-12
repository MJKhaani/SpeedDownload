# Platform Support and Feasibility Matrix

**Status date:** 2026-10-12
**Current project phase:** Phase 0 feasibility; portable core implementation has started
**Meaning:** “Not validated” means no native build/runtime evidence is available. Cross-compilation alone cannot change a target to supported.

## Current evidence

Zig 0.17.0 is installed and can be used with a workspace-local cache. The project now has a Zig build manifest, portable core module, and single-stream HTTP(S) CLI prototype, but no Capy checkout or GUI build manifest. Network access was unavailable during this assessment, so upstream state could not be re-queried. The project specification and `Agent.md` record the 2026-10-11 upstream review: Capy identifies Zig 0.14.1, describes itself as pre-production, lists macOS backends as planned, and does not certify Windows ARM64. Zig 0.17.0 has not been proven compatible with Capy and is only under evaluation for independent core code.

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

On 2026-10-12, direct Zig 0.17.0 commands compiled the CLI and passed five core state tests plus one HTTP scheme test on macOS 14.8.4 x86_64. A local HTTP fixture verified redirect handling, binary transfer, preservation of an existing destination, and partial-file removal on 404. `zig build` itself stalled in the build-runner in this workspace, so the tag workflow uses the verified direct compiler/test commands. This host result does not validate other OS/CPU targets, HTTPS certificate behavior, GUI, or packaging.

No target is currently supported or release-certified. For each target, record exact compiler/dependency revisions, OS version, CPU, backend, commands, native smoke-test results, accessibility checks, and packaging results before changing its status.

## Phase 0 exit work

- Select a Zig version and exact Capy commit only after the pair builds reproducibly.
- Prototype window creation, native events, text/list/scrolling, progress drawing, keyboard access, theme and DPI behavior, and packaging.
- Validate Windows x86/x64 and Linux x86/x64/ARM64; investigate macOS x64/ARM64 and Windows ARM64 on actual hosts.
- Separately compile and exercise the headless core/CLI on relevant targets.
- Record blockers and backend/widget gaps in [`adr/0001-zig-capy-toolchain.md`](adr/0001-zig-capy-toolchain.md).
