# Platform Support and Feasibility Matrix

**Status date:** 2026-10-28
**Current project phase:** Engine and native clients are in active development. The current Windows alpha uses WPF temporarily; WinUI 3/Fluent UI is the required Windows client target.
**Meaning:** “Not validated” means no native build/runtime evidence is available. Cross-compilation alone cannot change a target to supported.

The [engine feature status](engine-feature-status.md) is the current implementation inventory. The detailed notes below also preserve earlier dated observations; an earlier source build does not override a later native CI result. [Run 40655450597](https://github.com/MJKhaani/SpeedDownload/actions/runs/40655450597) passed native engine/IPC and client GUI smoke on macOS 15, Ubuntu, Windows Server 2022 x64, and Windows 11 ARM64. [Tag run 40655895412](https://github.com/MJKhaani/SpeedDownload/actions/runs/40655895412) packaged all five `v0.0.1-alpha.2` platform artifacts with their engines and checksums.

## Current evidence

The Zig engine implements the capabilities and limitations listed in the [engine feature status](engine-feature-status.md). Native CI on 2026-10-28 passed the isolated engine/IPC fixture on macOS 15, Ubuntu, Windows Server 2022 x64, and Windows 11 ARM64. Current SwiftUI, GTK 4, and temporary WPF clients passed their platform GUI connection, intermediate progress, and engine restart/reconnect smoke checks. These tests use local fixtures; they do not certify public-server compatibility, torrent swarms, accessibility, installers, or the required WinUI 3 client. The `v0.0.1-alpha.2` tag workflow packaged two macOS DMGs, two Windows ZIPs, and one Linux tarball with their engines and SHA-256 checksums.

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
| Windows | x86_64 | Native Zig build and isolated IPC/transfer/restart smoke pass on Server 2022 CI | WPF compatibility client opens, renders intermediate progress, and reconnects after engine restart; required WinUI 3 client still crashes before managed startup | Bundled WPF client and named-pipe engine pass GUI smoke on Server 2022 | **Experimental compatibility build**; WinUI 3/Fluent UI gate open. [CI run 40655450597](https://github.com/MJKhaani/SpeedDownload/actions/runs/40655450597). |
| Windows | ARM64 | Native engine build and isolated IPC/transfer/restart smoke pass on Windows 11 ARM64 CI | WPF compatibility client opens, renders intermediate progress, and reconnects after engine restart; required WinUI 3 client still crashes before managed startup | Bundled WPF client and named-pipe engine pass GUI smoke on Windows 11 ARM64 CI | **Experimental compatibility build**; WinUI 3/Fluent UI gate open. [CI run 40655450597](https://github.com/MJKhaani/SpeedDownload/actions/runs/40655450597). |
| Linux | x86 (32-bit) | Not validated | Not implemented | Not implemented | Blocked for Phase 0; assess GTK4/GLib and large-file support separately. |
| Linux | x86_64 | Native Zig build and isolated IPC/transfer/restart smoke pass on `ubuntu-latest` | GTK 4 build and Xvfb GUI runtime smoke pass | AF_UNIX GUI connection, intermediate progress, disconnect, and engine restart/reconnect pass | Experimental; installation and accessibility checks remain. [CI run 40538315654](https://github.com/MJKhaani/SpeedDownload/actions/runs/40538315654). |
| Linux | ARM64 | Not validated | GTK source; not built | AF_UNIX source; not validated | Blocked for Phase 0; assess on ARM64 runner/hardware. |
| Linux | ARM32 | Not validated | Not implemented | Not implemented | Stretch target; assess ABI, OS dependencies and runner/hardware separately. |
| macOS | x86_64 | Engine and isolated IPC transfer/restart smoke passed locally; macOS 15 CI engine/IPC smoke passed | SwiftUI bundle and isolated packaged window reconnect/progress check passed locally; macOS 15 CI package build passed | AF_UNIX and standalone Swift client restart/reconnect smoke passed locally and in [macOS CI run 40534896776](https://github.com/MJKhaani/SpeedDownload/actions/runs/40534896776) | Experimental; formal accessibility and installation checks remain. |
| macOS | ARM64 | Engine and isolated IPC fixture pass on macOS 15 CI | SwiftUI app package and client reconnect fixture pass on macOS 15 CI | AF_UNIX and bundled engine package pass CI; interactive Apple Silicon check pending | Experimental pending interactive hardware, accessibility, signing and installer checks. [Tag run 40655895412](https://github.com/MJKhaani/SpeedDownload/actions/runs/40655895412). |

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
- [x] Get native build and engine/IPC jobs green on the earlier compatibility revision: [run 40647057144](https://github.com/MJKhaani/SpeedDownload/actions/runs/40647057144) passed macOS 15, Ubuntu, Windows Server 2022 x64, and Windows 11 ARM64. The IPC fixture checks malformed-frame recovery, private Unix socket permissions, and subscription events. GTK, macOS, and the replacement WPF Windows client passed GUI connection, intermediate progress, and engine restart/reconnect smoke tests. The workflow now builds and smoke-tests the WinUI 3 client on Windows pushes; its result and [interactive desktop verification](phase0-windows-check.md) are still needed.
- [x] Launch the current packaged GUI on each CI OS against its runner's engine and confirm connected status, visible progress, disconnect/reconnect, and engine restart. The Windows result applies to the temporary WPF compatibility client only.
- [ ] Repeat native Windows GUI startup, progress, and reconnect tests with the required WinUI 3/Fluent UI client after resolving its startup failure.
- [x] Mark tested GUI/OS targets experimental and record runner evidence; untested architectures and interactive/HIG release gates remain open.
- Record results in [`adr/0001-native-guis-local-ipc.md`](adr/0001-native-guis-local-ipc.md) and keep target statuses evidence-based.

## Phase 1 status

The headless engine, persistent job store, HTTP(S) downloader with safe resume, and RPC CLI (`rpc list`, `rpc probe`, `rpc add`, `rpc control`, `rpc reorder`, `rpc delete`) are implemented. The fuller current capability list is in [engine feature status](engine-feature-status.md). The macOS client has been exercised interactively by the user, including multipart progress and resuming a partial transfer. On 2026-10-15 the Zig engine compiled with Zig 0.17.0 and the macOS app bundle built with Swift 6.0.3 on this Intel macOS host; later native CI evidence is recorded above for Linux and Windows compatibility builds too. Phase 1 release acceptance remains open for broader TLS, large-file, fault, public-server, and platform-specific validation.
