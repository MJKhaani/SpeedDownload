# Platform Support and Feasibility Matrix

**Status date:** 2026-10-13
**Current project phase:** Phase 0 feasibility; portable core implementation has started
**Meaning:** “Not validated” means no native build/runtime evidence is available. Cross-compilation alone cannot change a target to supported.

## Current evidence

Zig 0.17.0 builds the portable core module and HTTP(S) downloader. The downloader uses a real one-byte range probe and, for a known-size response with a strong ETag, can write up to four disjoint extents concurrently. Completed extents are synced before their cursors are atomically checkpointed; interrupted in-flight extents are fetched again on retry. Unsupported responses use the single-stream path. Dynamic resplitting during a transfer remains unimplemented. Optional SHA-256 verification is available. The engine persists jobs, exposes add/list/control RPCs, and drains the queue through a host-aware scheduler with four concurrent jobs globally and two per host; jobs have persisted priorities and durable progress is surfaced through snapshots polled by clients. Queue and active-transfer pause/resume/cancel controls are implemented; active stop is cooperative and may wait for the current network read. Event subscriptions are not connected. At startup, persisted in-progress states are recovered; pending active stops resolve to paused/canceled and other active jobs to `retry_wait`. Job creation requires an absolute, existing writable destination directory. IPC framing and handshake logic are implemented alongside a macOS/Linux Unix socket listener with up to 32 concurrent client sessions and private directory checks and same-UID peer authentication. The engine executable compiles on the current macOS host, but the sandbox denies socket bind (`EPERM`), so live worker and RPC behavior remain unverified here. Native SwiftUI source exists for macOS; local compilation remains blocked by a Swift compiler/SDK mismatch in the installed Command Line Tools. GTK 4 and WinUI 3 source now exists, but neither client has been built. The Linux client targets the implemented Unix socket transport; Windows requires a named-pipe engine adapter that is still missing. No IPC platform is validated until runtime checks cover permissions, handshake, requests, subscriptions, and reconnect behavior.

## Target matrix

| OS | CPU | Engine/CLI | Native GUI | IPC/runtime package | Status / next evidence |
|---|---|---:|---:|---:|---|
| Windows | x86 (32-bit) | Not validated | Not implemented | Not implemented | WinUI source targets x64/ARM64; first assess 32-bit support and large-file behavior. |
| Windows | x86_64 | Not validated | Source present; not built | Named-pipe server not implemented | Build WinUI app, implement pipe ACLs/server, and validate packaged and unpackaged deployment. |
| Windows | ARM64 | Not validated | Source present; not built | Named-pipe server not implemented | Build and run on ARM64 hardware; validate WinUI/Windows App SDK and pipe permissions. |
| Linux | x86 (32-bit) | Not validated | Not implemented | Not implemented | Assess GTK4/GLib and 64-bit file I/O support on a named distro. |
| Linux | x86_64 | Not validated | GTK 4 source present; not built | AF_UNIX adapter source present; runtime not validated | Build GTK4/GLib client; validate peer credentials, daemon lifecycle, accessibility, and package on named distro. |
| Linux | ARM64 | Not validated | Source present; not built | AF_UNIX adapter source present; runtime not validated | Native build/runtime and package validation required; not inferred from cross-build. |
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
