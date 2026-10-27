# Platform Support and Feasibility Matrix

**Status date:** 2026-10-27
**Current project phase:** macOS engine/client implementation alongside Phase 1–3 work; Phase 0 native CI results remain unavailable
**Meaning:** “Not validated” means no native build/runtime evidence is available. Cross-compilation alone cannot change a target to supported.

## Current evidence

Zig 0.17.0 builds the HTTP(S) engine on the current macOS host and cross-compiles it to x86_64 Windows and Linux. The downloader uses a real one-byte range probe and, for a known-size response with a strong ETag, can write up to 32 disjoint extents concurrently when configured and supported. The macOS Connections preference exposes Off, Automatic, and Fixed parallel modes; Automatic can lower the count after server rate limits. Completed extents are synced before their cursors are atomically checkpointed; interrupted in-flight extents are fetched again on retry. Idle workers claim preplanned pending segments or take an untouched tail split from an active range at a durable checkpoint. Unsupported responses use the single-stream path. Optional SHA-256 verification is available. On macOS, system proxy mode reads static HTTP and HTTPS proxy entries with a 30-second cache and honors simple-host, exact-host, wildcard-host, and numeric IP network exceptions for each redirect destination; a static HTTP or HTTPS proxy remains usable when SOCKS is also configured, while destinations requiring SOCKS fail closed; automatic proxy scripts, SOCKS transport, and system proxy authentication are not implemented. On macOS, custom proxy credentials are read from Keychain for HTTP requests; authenticated HTTPS CONNECT is not yet supported by the transport. On Linux, system proxy mode uses `http_proxy`, `https_proxy`, or `all_proxy` (with uppercase fallbacks) and honors `no_proxy` host, domain, and port entries for each redirect destination; unsupported proxy schemes and credential-bearing proxy URLs fail closed. The engine persists jobs and per-user settings, exposes probe/add/list/control RPCs, and drains the queue through a host-aware scheduler. Bounded automatic retries for transient connection failures and HTTP 429/503 persist their attempt count and next retry time. Global and per-job download limits are enforced by the engine; the latter can change while a transfer is active. Queue and active-transfer pause/resume/cancel controls are implemented; active stop is cooperative and may wait for the current network read. The engine exposes bounded job change subscriptions with filtered initial snapshots and coalesced live job updates; the macOS client consumes the stream when available and falls back to a bounded change wait with older compatible engines. Other clients poll. Subscription runtime behavior remains unverified. At startup, persisted in-progress states are recovered; pending active stops resolve to paused/canceled and other active jobs to `retry_wait`. Job creation requires an absolute, existing writable destination directory. IPC framing and handshake logic have macOS/Linux Unix socket and Windows named-pipe adapters. Unix sockets use private directory checks and same-UID peer authentication; named pipes use a current-user/session name, private DACL and remote-client rejection. Both listeners support up to 32 client sessions. The three native client projects implement dashboard polling, controls, and reconnect attempts. Native CI has not run against the current workspace. The macOS client was exercised interactively on the user's host, but its release smoke and accessibility checks remain unrecorded. Local GTK dependencies and Windows GUI runtime are unavailable on this host.

## Target matrix

Anonymous passive FTP and explicit FTPS source code now build with the macOS
engine and are available through the CLI, IPC queue, and macOS Add Download
dialog. FTPS certificate validation and encrypted data transport compile but
have not been exercised against a live server. FTP/FTPS server interoperability
and resume after a process restart are not yet
validated. New FTP journals carry a SHA-256 integrity checksum; older
unchecked partial journals remain in place but cannot be resumed automatically.
See [FTP source status](protocols/ftp.md) for its limits.

On 2026-10-27, the x86_64 macOS 14.8.4 host passed the isolated Phase 0
engine IPC fixture using the current local `zig-out/bin/speed-download`:
handshake, listing, reconnect, live progress, a byte-verified local HTTP
transfer, and completed-job recovery after engine restart. The standalone
Swift client fixture also passed connection, reconnection to a newly restarted
engine instance, and single-loop checks against an isolated engine. The Swift fixture used the installed
macOS 14.5 SDK because this host's default 15.2 SDK is incompatible with its
Swift compiler. An ad-hoc-signed copy of the packaged app with a separate
bundle ID and isolated state/runtime directories also launched a visible
window, connected to its engine, and returned to `Engine connected` after
that engine was terminated and replaced by a new PID. Its URL and document
registrations were removed for the smoke run. A second isolated packaged-app
check used a local 32 MiB HTTP fixture: the window's accessibility tree showed
an in-progress row at 2.4 MiB of 33.6 MiB and 434 KB/s, and the transfer
subsequently completed. This remains a local Intel macOS check, not a formal
accessibility audit. Separate macOS 15 native CI evidence is recorded below.

The CLI now builds with bounded BitTorrent v1 metainfo and magnet URI
inspection. It also has source for BEP 9 metadata retrieval from explicit
`x.pe` peers, HTTP(S) tracker compact IPv4/IPv6 or dictionary peers, or UDP tracker compact IPv4/IPv6 peers, but this path has not
been exercised against a live peer. Initial v1 magnet payload
transfer source now compiles and routes through the macOS/Unix engine queue.
The macOS client registers v1 `.torrent` documents and opens a dedicated torrent review dialog for OS files, browser handoffs, and magnets. It can queue a v1 `.torrent`
for that queue. Pieces are verified and rehashed independently on resume,
but neither source path has been exercised against a live swarm. Multi-file
payloads compile, and the Add dialog permits a file subset when its bounded
dialog has loaded the full paged map. Trackers can be edited before queueing, while the verified info hash is preserved. A bounded read-only DHT lookup for public torrent payload peers now compiles; the desktop metadata preparation path can also use it to resolve public magnets. The engine now requests distinct verified pieces from up to four TCP peers concurrently and can offer verified selected pieces during those sessions. A local two-peer fixture verifies concurrent requests and assembled-file integrity. It does not listen for peers or seed after completion, and upload accounting and limits are pending. Native public-swarm behavior remains unverified.
See [BitTorrent status](protocols/torrent.md).

The macOS bundle includes an experimental Firefox native-messaging host and
the repository includes a context-menu extension. The Zig host compiles, but
Firefox registration, extension signing, and a live handoff are not verified.
See [Firefox link handoff](browser-firefox.md).

| OS | CPU | Engine/CLI | Native GUI | IPC/runtime package | Status / next evidence |
|---|---|---:|---:|---:|---|
| Windows | x86 (32-bit) | Not validated | Not implemented | Not implemented | Blocked for Phase 0; assess 32-bit support separately. |
| Windows | x86_64 | Native Zig build and isolated IPC/transfer/restart smoke pass on Server 2022 and 2025 runners | WinUI x64 self-contained publish passes; process exits with `0xC0000409` before managed `App` startup on both hosted runners | Named-pipe engine smoke passes; native GUI connection/reconnect unverified | **Blocked for GUI runtime** pending an interactive Windows desktop or a diagnosed native startup failure. [Server 2022 run 40538962170](https://github.com/MJKhaani/SpeedDownload/actions/runs/40538962170). |
| Windows | ARM64 | Native engine build and isolated IPC/transfer/restart smoke pass on Windows 11 ARM64 CI | WinUI ARM64 publish passes; process exits with `0xC0000409` before managed `App` startup on hosted runner | Named-pipe engine smoke passes; GUI runtime unverified | **Blocked for GUI runtime** pending interactive desktop verification or diagnosis. [CI run 40539936233](https://github.com/MJKhaani/SpeedDownload/actions/runs/40539936233). |
| Linux | x86 (32-bit) | Not validated | Not implemented | Not implemented | Blocked for Phase 0; assess GTK4/GLib and large-file support separately. |
| Linux | x86_64 | Native Zig build and isolated IPC/transfer/restart smoke pass on `ubuntu-latest` | GTK 4 build and Xvfb GUI runtime smoke pass | AF_UNIX GUI connection, intermediate progress, disconnect, and engine restart/reconnect pass | Experimental; installation and accessibility checks remain. [CI run 40538315654](https://github.com/MJKhaani/SpeedDownload/actions/runs/40538315654). |
| Linux | ARM64 | Not validated | GTK source; not built | AF_UNIX source; not validated | Blocked for Phase 0; assess on ARM64 runner/hardware. |
| Linux | ARM32 | Not validated | Not implemented | Not implemented | Stretch target; assess ABI, OS dependencies and runner/hardware separately. |
| macOS | x86_64 | Engine and isolated IPC transfer/restart smoke passed locally; macOS 15 CI engine/IPC smoke passed | SwiftUI bundle and isolated packaged window reconnect/progress check passed locally; macOS 15 CI package build passed | AF_UNIX and standalone Swift client restart/reconnect smoke passed locally and in [macOS CI run 40534896776](https://github.com/MJKhaani/SpeedDownload/actions/runs/40534896776) | Experimental; formal accessibility and installation checks remain. |
| macOS | ARM64 | Engine compiles; native smoke pending | SwiftUI source; native build pending | AF_UNIX source; local bind blocked by sandbox | Experimental until Apple Silicon native build/runtime and GUI connection/reconnect checks pass. |

## Core module check

Current engine API work includes `jobs.get` and filtered `jobs.list` snapshots. Source URL query strings and fragments are omitted from job snapshots; the private job store retains the original transfer URL. Native macOS and x86_64 Windows/Linux engine builds compile on the current host, but cross-builds do not establish Windows or Linux runtime behavior.

Engine work still required for the full specification includes Linux/Windows native subscription client adoption, authenticated HTTPS proxy tunneling, Windows/Linux proxy credentials, and site credentials via OS secret stores, fuller FTP authentication/proxy coverage, and BitTorrent seeding/upload controls and network capabilities beyond the current v1 transfer path. A custom proxy marked as requiring authentication reads its credentials from macOS Keychain for HTTP transfers and refuses HTTPS links until authenticated CONNECT is available. Credentials remain outside engine settings. Native protocol, recovery, and security acceptance checks remain outstanding.

Queued HTTP transfers and IPC URL probes now acquire engine-wide request permits:
64 overall and 32 per destination host, including redirects. The code builds on macOS; actual
multi-job saturation and fairness under these limits have not been measured.
Waiting requests now use FIFO order among hosts eligible for a permit; a
host at its cap does not block a different eligible host.
Queue selection now scans the active job set once and compares queued jobs
against at most 32 active hosts under the configured task limit, instead of
rescanning full history for each candidate. Large-list latency is unmeasured.
IPC HTTP probes wait at most 15 seconds for a connection permit and return a
busy message when the host remains saturated; queued downloads keep waiting.
Bandwidth waits check transfer controls and queue schedules at 100 ms intervals.
An active transfer also recalculates its pending wait when the global or
per-job speed limit changes; runtime rate-change behavior remains unverified.
Queued HTTP single-stream and multipart body reads now run as cancellable
concurrent I/O when the backend supports it. The worker checks pause, cancel,
and queue scheduling every 100 ms while a read is blocked, then joins the
canceled read before closing its response. Backends without concurrent I/O
fall back to the ordinary read. Stalled-read cancellation and throughput still
need native runtime validation.

On 2026-10-12, Zig 0.17.0 compiled the CLI and passed six state tests, three queue selector tests, three HTTP parser tests, and local HTTP integration checks on macOS 14.8.4 x86_64. Fixtures verify redirects, binary transfer, overwrite protection including concurrent destination creation, error cleanup, interrupted resume, changed-validator rejection, and matching/mismatching checksum verification. Those checks did not validate another OS/CPU target, HTTPS certificate behavior, the GUI, IPC service, or a package; later macOS evidence is recorded above. The active native GUI/IPC decision and proof gate are recorded in [ADR 0001](adr/0001-native-guis-local-ipc.md).

No target is currently supported or release-certified. For each target, record exact compiler/dependency revisions, OS version, CPU, backend, commands, native smoke-test results, accessibility checks, and packaging results before changing its status.

## Phase 0 exit work

Local macOS x86_64 evidence on 2026-10-27: `python3 tests/integration/ipc_engine.py zig-out/bin/speed-download` passed the isolated IPC/transfer/restart fixture, and `SPEED_DOWNLOAD_SWIFT_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX14.5.sdk bash tests/integration/macos_client.sh` passed the standalone Swift client restart/reconnection fixture. Neither command launches the packaged GUI or substitutes for native CI on the other targets.

- [x] Pin Zig 0.17.0; implement OS-specific engine IPC endpoints and secure per-user permissions.
- [x] Implement IPC v1 framing, handshake, `jobs.list`, job controls, and polling-based reconnect; publish a shared request schema.
- [x] Add native platform CI jobs for the engine, matching GUI build, and local transfer/progress/reconnect/restart smoke.
- [x] Get native build and engine/IPC jobs green on the current revision: [run 40604962261](https://github.com/MJKhaani/SpeedDownload/actions/runs/40604962261) passed macOS 15, Ubuntu, Windows Server 2022 x64, and Windows 11 ARM64. The IPC fixture now checks malformed-frame recovery, private Unix socket permissions, and subscription events. The run also passed GTK GUI connection, intermediate progress, disconnect, and restart/reconnect; packaged macOS GUI progress/reconnect was verified locally. Windows GUI runtime remains unverified because its process exits before managed startup on hosted Server 2022/2025 and Windows 11 ARM64 runners. The Windows GUI smoke is opt-in on the CI workflow pending [interactive desktop verification](phase0-windows-check.md).
- [ ] Launch each native GUI against its runner's engine and confirm connected status, visible progress, disconnect/reconnect, and engine restart. macOS and Linux have runtime evidence; Windows remains blocked at native process startup.
- [x] Mark only tested GUI/OS targets experimental or verified with recorded runner versions; Windows GUI runtime and untested x86/ARM targets are explicitly blocked.
- Record results in [`adr/0001-native-guis-local-ipc.md`](adr/0001-native-guis-local-ipc.md) and keep target statuses evidence-based.

## Phase 1 status

The headless engine, persistent job store, HTTP(S) downloader with safe resume, and RPC CLI (`rpc list`, `rpc probe`, `rpc add`, `rpc control`, `rpc reorder`, `rpc delete`) are implemented. The macOS client has been exercised interactively by the user, including multipart progress and resuming a partial transfer, but that observation is not a recorded release smoke test. On 2026-10-15 the Zig engine compiled with Zig 0.17.0 and the macOS app bundle built with Swift 6.0.3 on this Intel macOS host. Linux and Windows clients are deferred for the current implementation focus. Phase 1 runtime acceptance remains unverified: crash recovery, overwrite protection, pause/resume/cancel, TLS behavior, large-file handling, and restart persistence need the native integration suite.
