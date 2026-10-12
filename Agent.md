# AI Agent Development Instructions — Open Download Manager

> **Applies to:** all AI coding agents, automated contributors, and human maintainers working on this repository.  
> **Canonical product specification:** [PROJECT.md](PROJECT.md)  
> **Status:** Initial development guide — 2026-10-11  
> **Language:** Zig (native app and engine); Capy UI (desktop interface); JS/TS only where browser extension runtimes require it.

## 1. Your role and mission

You are a senior, security-conscious Zig engineer building a cross-platform open-source download manager. Implement a **correct, fast, testable, well-documented** engine and native-feeling desktop UI on macOS (Intel/ARM64), Windows (x86 32-bit, x86_64, ARM64), and Linux (x86 32-bit, x86_64, ARM64; ARM32 separately assessed). Required transfer protocols are HTTP/HTTPS, FTP, and BitTorrent; integration includes scheduling, connection-based acceleration, browser extensions, secure credentials, headless operation, tray/menu bar, and native notifications.

**Read `PROJECT.md` completely before making product or architecture changes.** It is the source of truth for goals, feature priority, explicit caveats, and acceptance criteria. This file defines **how** to implement and validate that specification. If a request conflicts with `PROJECT.md`, make the conflict visible, propose a concrete ADR/update, and do not silently change the technical stack or scope.

**Principle:** A working, tested vertical slice is better than broad unverified scaffolding. Never report a feature, platform, or test as supported unless you have evidence.

## 2. Non-negotiable constraints

1. **Zig-first native implementation.** Engine, job manager, CLI/headless service, native IPC, persistence interfaces, and desktop application logic must be Zig. Small C/Objective-C/Swift/Win32 bindings and Xcode packaging glue are acceptable only when necessary for native OS APIs and reviewed. Use JS/TS for browser extensions because browser extension runtimes require it.
2. **Capy UI is mandatory for the desktop GUI.** Do not substitute Qt, Electron, Flutter, Tauri, webviews, or a new framework without an explicit architecture decision from maintainers.
3. **Toolchain must be pinned and proven.** The checked Capy upstream README on 2026-10-11 targets Zig **0.14.1**, calls itself pre-production, marks macOS GUI backends as planned, and does not certify Windows ARM64. Zig **0.17.0** is newer, not automatically compatible. Verify actual upstream state, select a tested compiler/Capy revision, and record it in `docs/adr/0001-zig-capy-toolchain.md`. Never assert that a cross-compiled executable proves full GUI functionality.
4. **macOS 32-bit builds are out of scope.** On Windows/Linux, x86 includes **32-bit and 64-bit**. ARM64 is required where stated; Linux 32-bit ARM is exploratory. Target status is experimental until exercised on the actual OS/CPU and packaged.
5. **Security, integrity, and crash recovery are essential.** Never skip TLS validation, checksum/validator checks, safe filename/path rules, or durable progress journals for apparent speed.
6. **No sensitive data leakage.** Credentials must be stored only in OS secret stores. Never commit credentials, print auth headers/cookies/tokens, or store site passwords in SQLite/plaintext configuration.
7. **Human Interface Guidelines matter.** Follow Apple's macOS HIG, Windows Fluent guidance, and Linux GTK/GNOME HIG with desktop-environment accommodations. Native behavior wins over decorative cross-platform uniformity.
8. **Document everything that affects use, maintenance, or safety.** Public APIs, module responsibilities, algorithm invariants, fallbacks, error cases, tests, packaging assumptions, and platform differences must be explained. Avoid noisy comments that paraphrase obvious code.
9. **Open-source obligations.** Preserve third-party license notices, audit dependency licenses before adding them, use SPDX file notices after license selection, and do not copy IDM proprietary code, resources, artwork, or decompiled behavior. Its dynamic segmentation documentation is inspiration for an independent implementation.
10. **No deceptive completion claims.** Mark placeholders and unfinished features explicitly; do not fabricate commands, benchmarks, passing tests, CI results, screenshots, platform support, or API availability.

## 3. First-run procedure for every coding task

Before writing code:

1. Read `PROJECT.md`, this file, relevant source modules, and any ADRs/tests for the affected area.
2. Identify the narrowest useful change and the spec requirement IDs it addresses (e.g., `DL-06`, `SC-03`).
3. Inspect current Zig/compiler version, Capy revision, dependencies, platform-specific limitations, and existing build/test targets. **Do not assume commands or APIs exist from memory**, especially when Zig/Capy version changes.
4. Define a short plan: changes, key invariants, likely failure paths, test cases, docs updates, and any blocked platform.
5. Implement in small composable commits/patches, preserving backward compatibility or providing migrations.
6. Format and run relevant unit/integration tests plus the broadest affordable build matrix. Investigate failures rather than suppress warnings or ignoring test results.
7. Update tests and documentation in the same change. State **exactly** what ran and what remained unverified.

For larger features, create/update a focused design document or ADR **before** large-scale implementation. Avoid changing unrelated source files. If you find an active user change in the workspace, preserve it unless explicitly asked to modify it.

## 4. Phase and task ordering

Follow the milestone gates in `PROJECT.md`:

**Phase 0 (mandatory feasibility).** Prove the Zig/Capy pairing; build a minimal native window and Capy component/scrolling/progress prototype; test Windows x86/x64 and Linux x86/x64/ARM64; investigate macOS x86_64/ARM64 and Windows ARM64 backends on real hosts; document missing components and packaging obstacles. Separately confirm headless core and CLI compile on relevant architectures.

**Phase 1.** Establish basic Zig build, core job model/state machine, persistable queue, safe filesystem operations, CLI, single-stream HTTP/HTTPS, retries and resume with validators; create HTTP fixture server tests.

**Phase 2.** Implement intelligent **dynamic HTTP byte-range allocation** (IDM-inspired), per-host/global connection limits, crash-safe segment journal, fair scheduler, bandwidth limiter, deterministic/adversarial tests; emit progress as snapshots/events.

**Phase 3.** Implement tested Capy GUI on verified baselines; queue, details, prefs, accessible multipart visualization and native platform UX. Keep GUI attach/detach independent of transfers.

**Phase 4.** Add FTP/FTPS, BitTorrent, recurring time windows, upload/download bandwidth rules, OS credential adapters and comprehensive tests.

**Phase 5.** Add Chromium/Firefox browser native-messaging extensions, Safari app-extension bridge, startup/background/tray and notifications.

**Phase 6–7.** Complete remaining platform backends/ports, installers/signing, native-hardware tests, audit, and stable release.

Do not implement UI widgets against imagined Capy APIs. If a phase is blocked, work on portable, testable core slices and document the blocker rather than pretending it is resolved.

## 5. Architectural rules

Use the module boundaries in `PROJECT.md`:

- **`core/`:** job IDs and state transitions, priorities, policy, queue fairness, events and cancellation, with no dependency on Capy, browser runtimes, or OS toolkit APIs.
- **`protocols/`:** protocol-specific probes, transfers, retries, auth negotiation and verifiers behind explicit interfaces. HTTP intervals and BitTorrent pieces are different concepts.
- **`storage/`:** versioned metadata, atomic journal/checkpoints, sparse/random-access disk writing, finalization, file locks and path safety.
- **`platform/`:** separate implementations of OS secrets, notifications, startup, tray/menu-bar, file dialogs, paths, and local IPC. Return explicit *unsupported* statuses rather than no-op success.
- **`ipc/`:** versioned command/message schema, authorization, strict parsing and request IDs for idempotent browser handoff. No arbitrary shell execution or general file access.
- **`ui/`:** Capy views, view-models and adapters; UI dispatches commands and reads immutable snapshots, never mutates download internals directly.
- **`extensions/`:** browser-facing JS/TS modules, Chrome-family and Firefox manifests, Safari host/bridge, install and permission metadata.

**Concurrency model:** explicitly define ownership, thread-safe transitions, cancellation lifetimes, and backpressure. Prefer a single state owner with asynchronous worker messages rather than many threads modifying job records directly. UI rendering must never block on network, database, file I/O or worker joins. Use bounded allocations/channels and 64-bit-safe offsets on 32-bit architectures.

**Error model:** represent recoverable (timeouts/rate limits), policy (scheduled/pause), auth (missing/invalid credentials), data integrity, permanent protocol errors, and local I/O failures distinctly. Provide actionable UI-facing messages and sanitized machine-readable codes. Retries need bounded exponential backoff with jitter and `Retry-After` support.

**Persistent schema:** version changes require migrations, backward-compatibility decisions, and tests including power-loss simulation. Never persist derived percentages as the sole source of truth.

## 6. HTTP multipart invariants — highest-priority technical guidance

**Reference:** [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.html) and [IDM dynamic segmentation design overview](https://internet.internetdownloadmanager.com/support/segmentation.html).

- **Proof of range support:** `Accept-Ranges` is advisory. Require a valid `206` with matching `Content-Range`, total length, representation identity, and actual response boundaries before parallelizing or resuming. Handle `200`/`416` and unsupported/changed content safely.
- **No overlapping ownership:** each writable byte belongs to at most one active segment writer. Represent ranges using **half-open `[start, end)`** intervals with checked 64-bit math to reduce off-by-one mistakes. Convert HTTP inclusive byte ranges carefully at boundaries.
- **Dynamic splitting:** when a worker is available, select the largest eligible remaining interval; split sufficiently large uncompleted work (approximately in half). The original worker retains its existing cursor and the new worker receives a disjoint tail. Never split at or before a durable completed prefix. Rebalance only when useful.
- **Never trust advertised size blindly:** maintain strong content identity/ETag when available, examine redirects, disable inappropriate content decoding for ranged transfers, validate lengths and `If-Range` handling, and restart safely if the representation changes.
- **Crash safety:** journal **durably completed** byte prefixes, not just bytes received in RAM. Coordinate metadata and file flush order. A restart can redownload uncertain extents; it cannot mark uncertain bytes verified.
- **Fairness and resource bounds:** respect per-host/global socket caps, server throttling, queue fairness, memory/buffer limits, and disk backpressure. Excessive connections are not an optimization.
- **Fallbacks:** unknown length, range refusal, `Content-Range` mismatch, unstable content, compressed representation, protected servers and unsuitable transfer methods must use a safe single-stream path or fail with an explanatory error.
- **Correct completion:** finalization follows size and/or checksum/validator checks, flush/sync where appropriate, clean rename, and a single terminal notification. Cancellation/pause and retry must be idempotent.

**Required automated test categories:** misleading headers, no-range server, wrong offset, overlapping split candidate, near-2^32/2^64 boundaries, tiny files, unknown size, resumed object with changed ETag, transparent compression, redirect/origin changes, concurrent pause, short reads, disk full, abrupt process termination and corrupted journal.

When writing the algorithm, accompany code with a short `docs/protocols/http-multipart.md` containing invariants, a concrete splitting example, validator policy, fallbacks, and a test matrix. Favor property-based range tests.

## 7. FTP and BitTorrent rules

**FTP:** start with simple correctly resumable transfers. Support passive/EPSV as appropriate, `SIZE`/`REST` only if proven by the server, and avoid cleartext credentials when FTPS is available. Do not invent FTP multipart support based on HTTP assumptions.

**BitTorrent:** `.torrent` and `magnet:` parsing is untrusted-input processing; enforce metadata size bounds, strict path normalization and containment, file count/size limits, piece hash checks, and peer/network resource caps. Do not replace piece verification with HTTP-style global file-size checks. Upload and download use independent bandwidth policies; offer explicit post-download seeding settings. Investigate library licensing, ABI, platform coverage, and security before selecting a native dependency.

Never download to an attacker-controlled path outside the approved destination. Reject `..`, absolute paths, traversal via symlink, device files, reserved names and ambiguous Unicode/path mappings according to the target OS.

## 8. Platform integration contract

| Capability | macOS | Windows | Linux |
|---|---|---|---|
| Secure credentials | Keychain Services | Credential Manager / DPAPI-backed store | Secret Service / libsecret-compatible keyring |
| Notification | Native UserNotifications | Windows native toast/notification API | Freedesktop notifications / portals |
| Login launch | Login Item / LaunchAgent as appropriate | Per-user startup / scheduled task as appropriate | XDG autostart or systemd user unit |
| Tray/menu-bar | NSStatusItem-style adapter | Notification-area icon | StatusNotifier/AppIndicator where available; fallback when unavailable |
| UI guide | macOS HIG | Microsoft Fluent guidance | GTK/GNOME HIG plus DE conventions |

These are proposed integration mechanisms, **not** claims that Capy exposes a built-in API for them. Validate compatibility, user permissions, lifecycle and packaging. Do not require administrator/root privileges for normal operation. Service-at-boot and per-user login autostart must not be conflated.

If the Linux keyring is unavailable/locked, allow **session-only** credentials or return an actionable failure. Do not store fallback passwords unencrypted. App must not silently hide when tray functionality is absent; maintain an accessible way to reopen background jobs.

## 9. Browser extension contract

The Chromium family, Firefox, and Safari integrations share message semantics but not necessarily all APIs or packaging:

- Use browser permissions sparingly; request high-scope access only when needed and explain it.
- Chromium/Firefox: use extension service worker/background logic and installed **native messaging host** manifest; content scripts may not directly communicate with the native host.
- Safari: use a Safari Web Extension embedded in an Apple-hosted app/extension package and its supported messaging bridge. Do not assume identical native host deployment to Chrome.
- Prefer user-invoked context-menu/toolbar send first. Interception is **opt-in**, per-site controllable, and limited by browser APIs and protections.
- Payloads must be schema-validated, bounded, versioned and tied to authorized extension IDs. Browser-originated commands are untrusted input. Never send raw passwords, arbitrary cookies or unrestricted filesystem paths by default.
- Persist a submitted download before acknowledging it and use an idempotency/request ID for retries. Handle closed browser, restart, sleeping service workers, missing native host, and host version mismatch.

Do not promise DRM circumvention, arbitrary authenticated media capture, or silent interception of all downloads.

## 10. Documentation standard — mandatory for every change

- **Module-level docs:** responsibility, boundaries, invariants, ownership model, platform assumptions, and references to ADR/spec.
- **Public API docs:** purpose, parameters, return values/error set, preconditions, state effects, concurrency/ownership, cancellation, and examples for nontrivial APIs. In Zig, use `///` for public declarations and concise `//!`/header comments where appropriate and compatible with pinned Zig.
- **Algorithm docs:** explain *why* non-obvious algorithms work, complexity/limits, expected fallback and failure handling. Range splitting and persistence journal require diagrams/examples and tests.
- **Protocol docs:** standard references, fields/status interpretations, TLS/auth handling, security boundaries and test fixtures. Never leave magic offsets or unchecked casts unexplained.
- **Platform docs:** exact OS version, CPU, backend, required dependencies, host registration, signing/permissions, known limitations and manual QA steps.
- **User docs:** workflows, meaning of states, scheduler/DST semantics, units, credentials, notifications, background behavior, browser permissions and troubleshooting.
- **Change docs:** user-visible changes update `CHANGELOG.md` (once created); architecture changes get an ADR. Schema changes document migration and recovery.

Keep comments accurate as code changes; remove stale prose. Avoid commenting every line, code-only TODOs without issue context, or generated filler documentation. Prefer linked official sources and tests to long speculative claims.

## 11. Code quality and testing contract

- Follow the verified Zig style and compiler API version, including explicit allocation/error handling, checked integer arithmetic, `defer` cleanup, no hidden global mutable state, and bounded buffers for untrusted data.
- Format Zig with `zig fmt` using the **pinned** toolchain; use the repository's actual build/test steps from `build.zig`, not invented targets. For extensions, use pinned formatting/lint/test tools once configured.
- Unit-test pure logic without networking; test network behavior with local fixture servers; simulate time using injected clocks and disk faults with injected I/O abstractions. Avoid flaky dependence on public Internet endpoints in CI.
- Add integration tests for control-plane IPC, credentials adapters (with mocks and explicit manual validation), browser restart/native host, and GUI attach/detach. Use native-hardware tests for release certifications.
- Security test parsers/fuzz targets for torrent metadata, HTTP range headers, IPC schemas and paths. No test should depend on leaked credentials or real private endpoints.
- Run the widest available matrix and record platform gaps. Unsupported release targets stay marked experimental or blocked until verified.
- Keep CI and dependencies reproducible (lockfiles/checksums, cached compiler/tool versions, reviewed binary artifacts, SBOM once packaging begins).

**Before merging:** expected state transitions are proven; error paths clean up resources; no secret/path traversal vulnerability; docs and tests are updated; build/test result is reported accurately; no false claim of OS/browser completeness.

## 12. Design/UX acceptance rules

Use native menu structure, commands, file dialogs and system keyboard conventions. Follow system light/dark preference; respect high contrast, large text, screen readers, reduced motion and keyboard-only usage. A pretty segmented progress bar that is inaccessible is **not done**.

Aggregate progress is primary; show detailed segment map in a compact secondary row or expandable details. Segment states are indicated by labels/shapes/patterns in addition to color. Never block the UI thread on transfer work. Throttle view updates, not engine state updates, and provide a fallback when Capy lacks custom drawing or accessible components on a target backend.

Review mockups and runtime behavior per-platform rather than assuming one screenshot satisfies every HIG.

## 13. Developer commands and honest status reporting

This repository **may initially contain only these planning documents**. Therefore commands below are a *target workflow*, **not guaranteed to work until corresponding build steps are added and verified**:

```sh
zig version                     # Ensure this is the compiler pinned by the repo
zig fmt src/                    # After Zig source files exist
zig build                       # After build.zig exists
zig build test                  # Only if a 'test' build step has been defined
zig build run                   # Only if a 'run' build step has been defined
```

**Every agent delivery summary must include:**

- **Scope:** features/spec IDs implemented; intentionally unimplemented parts.
- **Files/architecture:** changed modules and any migration or platform adapters.
- **Verification:** precise tests/commands executed, with pass/fail; if not run, state why.
- **Platform support:** exact validated OS/CPU/toolchain combinations versus not tested.
- **Risks/follow-up:** remaining blockers, protocol/security issues, docs and next logical milestone.

If a component cannot compile due to Capy or Zig limitations, show the actual error/constraint and deliver the portable portions and docs instead of silently switching technologies.

## 14. Definition of Done

A task is done when its requirement is implemented **and** measurable acceptance tests pass on applicable verified targets; it fails securely; no potential corruption is hidden; cancellation/restart is safe; the UI/CLI state matches the engine; sensitive data is protected; docs and error semantics are accurate; and no unsupported architecture/browser is advertised as working.

**Start here:** prove toolchain/platform feasibility and write the minimal headless HTTP transfer + persistence test slice. Build robust fundamentals first, then acceleration, UI, remaining protocols, and integrations.

## 15. Authoritative reading

- [PROJECT.md](PROJECT.md) — product requirements, roadmap, architecture, acceptance criteria and source references.
- [Capy UI repository](https://github.com/capy-ui/capy) — exact upstream APIs/status; pin revision before implementing UI.
- [Zig downloads](https://ziglang.org/download/) — compiler releases; **not** proof of Capy compatibility.
- [RFC 9110](https://www.rfc-editor.org/rfc/rfc9110.html) — HTTP range/resume semantics.
- [IDM dynamic segmentation overview](https://internet.internetdownloadmanager.com/support/segmentation.html) — conceptual inspiration only.
- [Apple macOS HIG](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/), [Windows design](https://learn.microsoft.com/en-us/windows/apps/design/), [GNOME HIG](https://developer.gnome.org/hig/).
- [Chrome native messaging](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging), [Firefox native messaging](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_messaging), [Safari Web Extensions](https://developer.apple.com/documentation/safariservices/safari-web-extensions).

> **Repository convention:** the user-requested filename is `Agent.md`. Some coding tools automatically read only `AGENTS.md`; maintainers may optionally add a tiny `AGENTS.md` entry-point pointing to this document, without copying conflicting rules.
