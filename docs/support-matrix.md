# Platform Support and Feasibility Matrix

**Status date:** 2026-10-13
**Current project phase:** Phase 1 core MVP implementation; Phase 0 native CI results remain unavailable
**Meaning:** “Not validated” means no native build/runtime evidence is available. Cross-compilation alone cannot change a target to supported.

## Current evidence

Zig 0.17.0 builds the HTTP(S) engine on the current macOS host and cross-compiles it to x86_64 Windows. The downloader uses a real one-byte range probe and, for a known-size response with a strong ETag, can write up to four disjoint extents concurrently. Completed extents are synced before their cursors are atomically checkpointed; interrupted in-flight extents are fetched again on retry. Unsupported responses use the single-stream path. Dynamic resplitting during a transfer remains unimplemented. Optional SHA-256 verification is available. The engine persists jobs, exposes add/list/control RPCs, and drains the queue through a host-aware scheduler with four concurrent jobs globally and two per host; jobs have persisted priorities and durable progress is surfaced through snapshots polled by clients. Queue and active-transfer pause/resume/cancel controls are implemented; active stop is cooperative and may wait for the current network read. Event subscriptions are not connected. At startup, persisted in-progress states are recovered; pending active stops resolve to paused/canceled and other active jobs to `retry_wait`. Job creation requires an absolute, existing writable destination directory. IPC framing and handshake logic have macOS/Linux Unix socket and Windows named-pipe adapters. Unix sockets use private directory checks and same-UID peer authentication; named pipes use a current-user/session name, private DACL and remote-client rejection. Both listeners support up to 32 client sessions. The three native client projects implement dashboard polling, controls, and reconnect attempts. A new native CI workflow builds each engine/GUI on its OS runner and runs a local IPC + HTTP progress/restart smoke. It has not run against the current workspace yet, so no platform is verified. The macOS sandbox also prevents local socket binding (`EPERM`); local GTK dependencies and Windows GUI runtime are unavailable. No IPC platform is validated until native CI passes and GUI connection/reconnect behavior is confirmed on each OS.

## Target matrix

| OS | CPU | Engine/CLI | Native GUI | IPC/runtime package | Status / next evidence |
|---|---|---:|---:|---:|---|
| Windows | x86 (32-bit) | Not validated | Not implemented | Not implemented | Blocked for Phase 0; assess 32-bit support separately. |
| Windows | x86_64 | Engine cross-compiles; native smoke pending | WinUI source; native build pending | Named-pipe source; native smoke pending | Experimental until Windows CI build, transfer/restart smoke, and GUI connection/reconnect check pass. |
| Windows | ARM64 | Not validated | WinUI source; not built | Named-pipe source; not validated | Blocked for Phase 0; assess on ARM64 runner/hardware. |
| Linux | x86 (32-bit) | Not validated | Not implemented | Not implemented | Blocked for Phase 0; assess GTK4/GLib and large-file support separately. |
| Linux | x86_64 | Native smoke pending | GTK 4 source; native build pending | AF_UNIX source; native smoke pending | Experimental until Linux CI build, transfer/restart smoke, and GUI connection/reconnect check pass. |
| Linux | ARM64 | Not validated | GTK source; not built | AF_UNIX source; not validated | Blocked for Phase 0; assess on ARM64 runner/hardware. |
| Linux | ARM32 | Not validated | Not implemented | Not implemented | Stretch target; assess ABI, OS dependencies and runner/hardware separately. |
| macOS | x86_64 | Engine compiles; native smoke pending | SwiftUI source; native build pending | AF_UNIX source; local bind blocked by sandbox | Experimental until macOS CI build, transfer/restart smoke, and GUI connection/reconnect check pass. |
| macOS | ARM64 | Engine compiles; native smoke pending | SwiftUI source; native build pending | AF_UNIX source; local bind blocked by sandbox | Experimental until Apple Silicon native build/runtime and GUI connection/reconnect checks pass. |

## Core module check

On 2026-10-12, Zig 0.17.0 compiled the CLI and passed six state tests, three queue selector tests, three HTTP parser tests, and local HTTP integration checks on macOS 14.8.4 x86_64. Fixtures verify redirects, binary transfer, overwrite protection including concurrent destination creation, error cleanup, interrupted resume, changed-validator rejection, and matching/mismatching checksum verification. No other OS/CPU target, HTTPS certificate behavior, GUI, IPC service, or package is validated. The active native GUI/IPC decision and proof gate are recorded in [ADR 0001](adr/0001-native-guis-local-ipc.md).

No target is currently supported or release-certified. For each target, record exact compiler/dependency revisions, OS version, CPU, backend, commands, native smoke-test results, accessibility checks, and packaging results before changing its status.

## Phase 0 exit work

- [x] Pin Zig 0.17.0; implement OS-specific engine IPC endpoints and secure per-user permissions.
- [x] Implement IPC v1 framing, handshake, `jobs.list`, job controls, and polling-based reconnect; publish a shared request schema.
- [x] Add native platform CI jobs for the engine, matching GUI build, and local transfer/progress/reconnect/restart smoke.
- [ ] Get all three native CI jobs green on the current revision; the workflow has not run yet.
- [ ] Launch each native GUI against its runner's engine and confirm connected status, visible progress, disconnect/reconnect, and engine restart.
- [ ] Mark only those tested GUI/OS targets experimental or verified with recorded runner versions; x86/ARM64 targets remain blocked pending their own native evidence.
- Record results in [`adr/0001-native-guis-local-ipc.md`](adr/0001-native-guis-local-ipc.md) and keep target statuses evidence-based.

## Phase 1 status

The headless engine, persistent job store, HTTP(S) downloader with safe resume, and RPC CLI (`rpc list`, `rpc add`, `rpc control`, `rpc reorder`, `rpc delete`) are implemented. Local macOS, Linux x86_64, and Windows x86_64 compile checks have passed for recent engine revisions. Phase 1 runtime acceptance remains unverified: crash recovery, overwrite protection, pause/resume/cancel, TLS behavior, large-file handling, and restart persistence need the native integration suite. Runtime checks are deferred to the project testing pass.
