# Platform Support and Feasibility Matrix

**Status date:** 2026-10-11  
**Current project phase:** 0 — feasibility  
**Meaning:** “Not validated” means no native build/runtime evidence is available. Cross-compilation alone cannot change a target to supported.

## Current evidence

The workspace has no Zig executable (`zig version` returned `command not found`), no `build.zig`, and no Capy dependency checkout. Network access was unavailable during this assessment, so upstream state could not be re-queried. The project specification and `Agent.md` record the 2026-10-11 upstream review: Capy identifies Zig 0.14.1, describes itself as pre-production, lists macOS backends as planned, and does not certify Windows ARM64. This is dated source context, not a fresh verification or a proven toolchain pair.

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

No target is currently supported or release-certified. For each target, record exact compiler/dependency revisions, OS version, CPU, backend, commands, native smoke-test results, accessibility checks, and packaging results before changing its status.

## Phase 0 exit work

- Select a Zig version and exact Capy commit only after the pair builds reproducibly.
- Prototype window creation, native events, text/list/scrolling, progress drawing, keyboard access, theme and DPI behavior, and packaging.
- Validate Windows x86/x64 and Linux x86/x64/ARM64; investigate macOS x64/ARM64 and Windows ARM64 on actual hosts.
- Separately compile and exercise the headless core/CLI on relevant targets.
- Record blockers and backend/widget gaps in [`adr/0001-zig-capy-toolchain.md`](adr/0001-zig-capy-toolchain.md).
