# Platform Support and Feasibility Matrix

**Status date:** 2026-10-12
**Current project phase:** Phase 0 feasibility; portable core implementation has started
**Meaning:** “Not validated” means no native build/runtime evidence is available. Cross-compilation alone cannot change a target to supported.

## Current evidence

Zig 0.17.0 builds the portable core module and a single-stream HTTP(S) downloader with checkpointed resume and optional SHA-256 verification. The engine persists jobs, exposes add/list/control RPCs, and runs one HTTP(S) worker at a time; progress is surfaced through snapshots polled by the macOS client. The host-aware multi-job scheduler is not connected. Queue pause/resume/cancel work, while active-transfer controls and event subscriptions are not implemented. At startup, persisted in-progress states are recovered to `retry_wait` for explicit user retry. Job creation requires an absolute, existing writable destination directory. IPC framing and handshake logic are implemented alongside a sequential macOS/Linux Unix socket request listener with private directory checks and same-UID peer authentication. The engine executable compiles on the current macOS host, but the sandbox denies socket bind (`EPERM`), so live worker and RPC behavior remain unverified here. The native SwiftUI macOS client implements handshake, connection status, persisted job listing, job creation, start/retry controls, byte-progress display, queue controls, and periodic reconnect after engine loss; local compilation remains blocked by a Swift compiler/SDK mismatch in the installed Command Line Tools. Windows and Linux clients remain unimplemented. No IPC platform is validated until runtime checks cover permissions, handshake, requests, subscriptions, and reconnect behavior.

## Target matrix

| OS | CPU | Engine/CLI | Native GUI | IPC/runtime package | Status / next evidence |
|---|---|---:|---:|---:|---|
| Windows | x86 (32-bit) | Not validated | Not implemented | Not implemented | Verify Zig ABI/large-file behavior; build and validate WinUI/Named Pipe lifecycle on a supported host. |
| Windows | x86_64 | Not validated | Not implemented | Not implemented | Validate Zig engine, WinUI app, pipe ACLs, packaged and unpackaged deployment. |
| Windows | ARM64 | Not validated | Not implemented | Not implemented | Build and run on ARM64 hardware; validate WinUI/Windows App SDK and Named Pipe permissions. |
| Linux | x86 (32-bit) | Not validated | Not implemented | Not implemented | Verify ABI/large-file behavior; validate GTK4/GLib and Unix socket credentials on named distro. |
| Linux | x86_64 | Not validated | Not implemented | Adapter not validated | Validate GTK4/GLib, AF_UNIX peer credentials, daemon lifecycle, accessibility and package on named distro. |
| Linux | ARM64 | Not validated | Not implemented | Not implemented | Native build/runtime and package validation required; not inferred from cross-build. |
| Linux | ARM32 | Not validated | Not implemented | Not implemented | Stretch target; assess ABI, OS dependencies and runner/hardware separately. |
| macOS | x86_64 | Engine source compiles; transfer/runtime unverified | SwiftUI source; build/runtime unverified | Engine executable compiles; socket runtime blocked by sandbox | Build with matching Xcode toolchain; validate SwiftUI, AF_UNIX peer identity, worker lifecycle, signed helper launch and packaging on Intel host. |
| macOS | ARM64 | Engine source compiles; transfer/runtime unverified | SwiftUI source; build/runtime unverified | Engine executable compiles; socket runtime blocked by sandbox | Build with matching Xcode toolchain; validate SwiftUI, AF_UNIX peer identity, worker lifecycle, signed helper launch and packaging on Apple Silicon host. |

## Core module check

On 2026-10-12, Zig 0.17.0 compiled the CLI and passed six state tests, three queue selector tests, three HTTP parser tests, and local HTTP integration checks on macOS 14.8.4 x86_64. Fixtures verify redirects, binary transfer, overwrite protection including concurrent destination creation, error cleanup, interrupted resume, changed-validator rejection, and matching/mismatching checksum verification. No other OS/CPU target, HTTPS certificate behavior, GUI, IPC service, or package is validated. The active native GUI/IPC decision and proof gate are recorded in [ADR 0001](adr/0001-native-guis-local-ipc.md).

No target is currently supported or release-certified. For each target, record exact compiler/dependency revisions, OS version, CPU, backend, commands, native smoke-test results, accessibility checks, and packaging results before changing its status.

## Phase 0 exit work

- Pin the Zig version and establish a daemon lifecycle with a secure per-user IPC endpoint.
- Implement IPC v1 framing, handshake, permissions, `jobs.list`, subscriptions and reconnect; add cross-platform golden frame tests.
- Prove a native window and IPC client on each OS, then verify job listing, progress events, disconnect/reconnect and engine restart.
- Validate Windows x86/x64/ARM64 and Linux x86/x64/ARM64; investigate macOS x64/ARM64 on actual hosts.
- Record results in [`adr/0001-native-guis-local-ipc.md`](adr/0001-native-guis-local-ipc.md) and keep target statuses evidence-based.
