# ADR 0001 — Separate Native GUIs and Local Engine IPC

- **Status:** Accepted architecture; Windows WinUI 3 target reaffirmed on 2026-10-28
- **Date:** 2026-10-12
- **Supersedes:** Proposed Zig + Capy UI requirement in PROJECT.md v0.1

## Context

Speed Download requires a reliable, platform-native user experience on macOS, Windows, and Linux; a headless downloader with safe resume, schedules and browser integration; and coverage across multiple CPU architectures. Capy support and Zig/GUI toolchain coupling introduced risk for the macOS and Windows ARM64 targets. Three independent native frontends can respect platform-specific UI/UX APIs while sharing the Zig engine.

The UI needs request/response operations (add, pause, preferences), live progress streams (jobs, multipart ranges, peers), reconnection after GUI restart, and a secure browser-to-engine handoff. IPC must work from Zig, Swift, C#, and C without a mandatory network service.

## Decision

1. **One authoritative Zig background engine** is responsible for transfers, persistence, scheduler, safety, and the public control API. A Zig CLI is an IPC client, not a bypass around the API.
2. **Three native UI codebases:** macOS Swift + SwiftUI (AppKit as necessary), Windows C# + WinUI 3 / Windows App SDK (Fluent UI), Linux C + GTK 4/GLib (optionally libadwaita). The WPF Windows alpha client is a temporary compatibility build while the WinUI 3 startup failure is resolved.
3. **One transport-independent application protocol:** JSON-RPC 2.0 over UTF-8 JSON with 4-byte unsigned little-endian length framing. Wire schema, version negotiation, and tests are shared.
4. **Native local transports:** Windows per-user Named Pipe; macOS/Linux AF_UNIX stream socket. No TCP/HTTP/WebSocket port is exposed by default.
5. **Per-user authentication/authorization and safe lifecycle** through pipe ACLs / peer identity checks, single-instance enforcement, secure binary paths, independent engine startup, and GUI subscription/reconnect.
6. Browser native messaging is a **restricted gateway** to engine API, not an unrestricted RPC tunnel.

## Why this IPC choice

- JSON-RPC 2.0 supports requests, results, errors, and one-way notifications; Zig, Swift, .NET and GLib all support JSON parsing without a heavy runtime.
- A simple little-endian length prefix handles messages on stream transports regardless of newline or buffer chunking; matches the basic framing style of WebExtension native messaging, while keeping the two protocols logically distinct.
- NamedPipeServerStream/NamedPipeClientStream are natural in .NET/Windows; Unix domain sockets are idiomatic on macOS and Linux. Different OS transports preserve better security and packaging properties than forcing a lowest-common-denominator mechanism.
- A local socket/pipe avoids firewall, port collision, remote exposure, and browser-origin concerns of default loopback servers.
- Progress is moderate-volume and can be coalesced. Protobuf/gRPC complexity is not justified initially; if measured IPC profiling identifies a bottleneck, add an explicitly versioned binary extension without changing GUI ownership.

## Considered alternatives

| Option | Decision | Rationale |
|---|---|---|
| Capy across platforms | Rejected | Not the chosen platform-native GUI approach; couples GUI compatibility to Zig. |
| Link core as native library to each GUI | Rejected | Harder process isolation, headless lifecycle, crash containment, and compiler/ABI coordination. |
| gRPC/HTTP2 + Protocol Buffers | Deferred | Excellent when strict generated types/network services are needed; unnecessary deployment/runtime complexity for local first-party clients. |
| D-Bus as the sole IPC | Rejected | Natural on Linux but not a uniform, maintained platform service API for macOS/Windows. |
| Local TCP/WebSockets | Rejected as default | Requires port ownership and additional listener security; increases attack surface for no local-only benefit. |
| Standard input/output only | Rejected for GUI↔daemon | Good for browser native host framing but not natural for a long-lived single engine serving multiple independent clients. |
| One transport type on all OSes | Rejected | Windows named pipes and Unix sockets have different but well-supported security/lifecycle semantics. |

## Consequences

**Benefits:** independent GUI release/build chains; fully headless engine; better native HIG and accessibility; no Capy blocker; independent engine/GUI crash recovery; narrow auditable browser boundary.

**Costs:** three UI projects; protocol schema/version management; OS-specific IPC endpoint implementation; native installers/signing/runtime requirements; tests across all languages and architectures.

**Operational requirements:** support per-user engine startup, explicit stop, bounded subscriptions, persistent idempotency keys, secure credential handling, compatibility policy, and recovery after disconnection. A private IPC endpoint protects against other accounts but does not inherently isolate malicious code already executing under the same account.

## Verification gate

A phase-0 proof of concept must show each native GUI opening a window, connecting to its local Zig daemon, completing `engine.hello`, calling `jobs.list`, receiving subscription events, restarting the GUI without terminating the engine, and recovering after daemon restart. Test unauthorized clients and malformed frames. Verify Windows packaged/unpackaged deployment models with a bundled native daemon and macOS notarized-app helper execution.

## Phase 0 evidence on 2026-10-27

- [CI run 40604962261](https://github.com/MJKhaani/SpeedDownload/actions/runs/40604962261) built the Zig engine and native GUI on macOS 15, Ubuntu, Windows Server 2022 x64, and Windows 11 ARM64; isolated IPC/transfer/restart smokes passed on each runner. They also passed oversized-frame recovery and a `jobs.subscribe` change-event check; Unix runners verified private socket permissions.
- The GTK 4 window on Xvfb showed connected status and intermediate transfer progress, then disconnected and reconnected after an engine restart. A packaged SwiftUI app on Intel macOS 14 showed intermediate progress and reconnected after a separate engine restart; CI also passed its Swift client restart fixture.
- Published WinUI x64 and ARM64 binaries exit with `0xC0000409` before the managed `App` constructor on three GitHub-hosted Windows runner images. The Windows GUI runtime, installation, GUI subscription consumption, accessibility, cross-user unauthorized-client cases, and macOS notarized-helper execution remain outside the verified Phase 0 evidence. Windows GUI runtime is blocked pending an [interactive Windows desktop check](../phase0-windows-check.md) or a native startup diagnosis; the build and named-pipe engine checks are not blocked.

## Windows compatibility build and target reaffirmation on 2026-10-28

The user reproduced the same `0xC0000409` WinUI startup crash on an interactive Windows Server 2022 x64 desktop. A minimal WPF window initialized successfully on the same hosted Server 2022 runner where WinUI failed. The alpha release therefore packages a self-contained WPF compatibility client with the Zig engine for Windows x64 and ARM64. [CI run 40655450597](https://github.com/MJKhaani/SpeedDownload/actions/runs/40655450597) passed GUI launch, rendered intermediate progress, and engine restart/reconnect on Server 2022 x64 and Windows 11 ARM64. The project decision remains **WinUI 3 with Fluent UI** for the Windows release client. Diagnose and fix its startup/deployment path, then repeat these tests and an interactive desktop check before treating the WinUI gate as passed.

**Related:** [PROJECT.md](../../PROJECT.md), [IPC v1](../protocols/ipc-v1.md).
