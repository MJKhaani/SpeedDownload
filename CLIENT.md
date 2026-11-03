# Native client feature contract

This document specifies the **intended product experience** for the macOS, Windows, and Linux desktop clients. It is a feature contract, not a claim that any feature is implemented. [PROJECT.md](PROJECT.md) remains the canonical product and architecture specification; its requirement IDs and P0/P1/P2 priorities apply here. Current implementation evidence belongs in [docs/engine-feature-status.md](docs/engine-feature-status.md), platform READMEs, tests, and release notes.

The shared checklist applies to **each** native client unless the platform section records an exception. P0 means release-blocking core, P1 means first complete release, and P2 means a later enhancement. An unchecked item means a required behavior, not a current failure or status report. The CLI and browser extensions are covered only at the points where a native client receives, reviews, or displays their work.

## Client boundary and common behavior

- [ ] **P0 · Native application:** macOS uses Swift/SwiftUI with AppKit adapters where needed; Windows uses C#/WinUI 3 and Windows App SDK; Linux uses C/GTK 4 and GLib/GIO. Each is a separate executable with native menus, dialogs, focus behavior, and accessibility. The Windows WPF compatibility build does not satisfy the WinUI 3 requirement.
- [ ] **P0 · Authoritative engine:** The client starts or attaches to the per-user Zig engine through the versioned local IPC protocol. It does not transfer bytes, implement scheduling, write the engine database/settings, or connect to the engine through browser-facing bridges.
- [ ] **P0 · Connection lifecycle:** Cold launch starts only the trusted installed engine when necessary, shows connection progress, handles startup failure and incompatible protocol versions, and offers a safe retry. Engine loss makes live values visibly stale. Reconnection loads a fresh snapshot and resumes events without duplicating submitted jobs.
- [ ] **P0 · Independent lifecycle:** Closing or crashing a window does not silently stop active transfers. A surviving engine can be reattached by the same client, CLI, or a new client process. An explicit stop-engine action explains its effect on active work.
- [ ] **P0 · Responsiveness:** Lists, dialogs, and controls remain usable with at least 100 queued/active jobs on representative hardware; IPC and disk/network work do not block the UI thread. Live progress is coalesced rather than repainted for every engine event.
- [ ] **P0 · Truthful state:** Commands show pending, accepted, and failed outcomes; a client never portrays unverified bytes as complete, stale progress as live, or an unacknowledged command as durable.

## Downloads and queues

- [ ] **P0 · Add download (DL-01, DL-14):** A user can add an HTTP(S) URL by entry, paste, and drag/drop; review a safe file name, source, destination, and transfer method; edit the name and destination; then explicitly add/start it. Invalid or unsafe input produces an actionable error without creating a job. The saved default folder is offered.
- [ ] **P0 · Download list (DL-03):** Each job shows name/type, source, state, verified progress, total size when known, current speed, ETA when meaningful, destination, and queue. Unknown values are labeled as unknown rather than guessed. The list distinguishes queued, scheduled, resolving, connecting, downloading, paused, retry wait, verifying, completed, failed, and canceled states.
- [ ] **P0 · Job actions (DL-03):** Start/resume, pause, cancel, retry, reorder, delete, reveal in file manager, and open a completed file are available when valid for that state. Destructive choices explicitly say whether partial data or the finished file will be removed; ordinary pause preserves resumable data.
- [ ] **P0 · Queue basics (DL-04, DL-12):** The client shows global active-task limits and per-host limits where relevant, allows changing the global concurrent-task limit, and explains why a waiting job is not starting. Reordering or a limit change is reflected without restarting the app.
- [ ] **P0 · Connection settings (DL-06, DL-13):** The client exposes default connections per task and multipart mode (`off`, `auto`, `fixed`) with validated bounds. It reports when multipart cannot be used and does not imply that more connections guarantee more speed.
- [ ] **P0 · Recovery (DL-02, DL-05):** After network loss, engine restart, or power loss, the client shows resumed, rechecking, or failed state accurately. If source identity changes or partial data cannot be trusted, the user sees the reason and any restart/discard decision before incompatible bytes are used.
- [ ] **P1 · Named queues (DL-17):** A permanent `main` queue and user-created queues appear in a native queue list. Users can create, rename, and delete user queues; choose a queue in Add; and move waiting jobs between queues. Deleting a queue offers to move its jobs to `main` or cancel and never silently discards jobs or partial files.
- [ ] **P1 · Queue controls (DL-18, SC-07):** Each queue exposes active count, concurrency limit, current schedule state, and pause/resume or start controls. Changing one queue does not change another; global/per-host caps still apply. A toolbar Resume Queue action starts waiting jobs and resumes paused jobs under scheduler policy.
- [ ] **P1 · Queue finish action (DL-18):** A queue can optionally run a user-provided shell command after all its jobs complete. The client makes the execution identity, trigger, and risk clear, requires deliberate entry/enablement, and reports failures; no browser request can set this action.
- [ ] **P1 · Find and batch work (DL-09):** Search, filters, sorting, grouping, and valid batch actions work across queue/history lists with large job counts. The selected count and scope of a batch operation are clear before destructive actions.
- [ ] **P1 · Integrity controls (DL-10):** A user can enter/import an expected checksum, see verification progress and result, and investigate mismatches. A mismatch never appears as a successful completion.
- [ ] **P1 · Expired-link recovery (DL-16):** A browser-provided or manually entered reference page is visible. The client can reopen that page, review a replacement URL, and obtain explicit consent before discarding partial data or restarting; matching file names/sizes alone never justify reuse.
- [ ] **P2 · Organization and portability (DL-11):** Mirror URLs, categories, and job-list import/export have reviewable input and sanitized output. Import errors identify affected entries without exposing secrets or corrupting existing jobs.

## Download details and transfer health

- [ ] **P0 · Details:** A selected job has a details view with source and destination, current phase, timeline/activity, transfer health, safe header/response metadata, retry reason, and redacted diagnostics. File actions reflect whether a usable file exists.
- [ ] **P0 · Progress map (DL-06):** Overall progress measures verified bytes. A separate range timeline distinguishes completed, active, pending, and failed/retry spans by pattern or label as well as color. It shows the reason for sequential fallback and does not show HTTP ranges for protocols that use different units of work.
- [ ] **P0 · Segment inspection:** A collapsible view shows active connection count, per-connection speed, and, for a focused segment, offset range, downloaded bytes, worker, rate, and retry state when available. Keyboard and screen-reader users receive equivalent summaries; a simple progress-only presentation is available.
- [ ] **P1 · File verification:** Checksum, source identity, and finalization status are visible without exposing secret URL queries or authentication headers. A failed verification offers a safe retry/restart path.

## Protocol-specific flows

- [ ] **P1 · FTP/FTPS (DL-07):** FTP/FTPS URLs enter the Add flow with authentication and destination review. The client explains insecure clear-text FTP, certificate failures, server limitations, and whether resume is available. It does not promise HTTP-style multipart behavior.
- [ ] **P1 · Torrent intake (DL-08):** Opening a `.torrent` document or `magnet:` link launches a dedicated native Add Torrent dialog. It waits for validated metadata, then shows file tree, destination, queue, file selection/priorities, and editable trackers before queueing. The ordinary Add Download dialog has no torrent picker.
- [ ] **P1 · Torrent details:** Per-file progress, verified piece state where useful, peer/seed counts when available, trackers, download/upload rates and caps, and seeding status are visible. Post-completion seeding is an explicit configurable choice; errors involving unsafe paths or invalid metadata are actionable.
- [ ] **P2 · Media page review (MED-01–MED-04):** Supported media-page URLs open a native Add Media dialog after engine probing. The user reviews title, file name, quality, audio-only choices, container/codec, and approximate size when known. For playlists, the user sees title/count, can select all/none or individual entries, choose formats as needed, and submits only confirmed items to a chosen queue. Unsupported, expired, private, live, or DRM-protected cases show clear limitations without claiming bypass.

## Scheduling, bandwidth, and settings

- [ ] **P1 · Schedule editor (SC-01, SC-02, SC-05):** A user can set one-time and recurring job/queue timing, named time zone, start/end windows, and priority where supported. The UI previews upcoming behavior and explains sleep/wake, missed windows, time-zone changes, and daylight-saving ambiguity.
- [ ] **P1 · Queue weekly grid (DL-18, SC-07):** Each queue has a seven-day, hourly Active/Off grid with a visible effective state. Edits take effect while the engine runs and remain in force when the GUI closes.
- [ ] **P1 · Bandwidth controls (SC-03, SC-04):** The client exposes global download cap, applicable per-job/protocol controls, and a weekly limited-speed grid; a zero global limit means unlimited. It displays units explicitly, previews the effective cap, and shows torrent upload separately from download.
- [ ] **P2 · Environment rules (SC-06):** Optional network, battery, and metered-connection constraints state the detected condition, expected effect, and user override.
- [ ] **P0/P1 · Preferences:** Native settings cover General, Downloads, Connections & Segments, Bandwidth, Schedule, Browser Integration, Privacy & Credentials, Notifications, Appearance, and Advanced as relevant. Settings load from the engine, validate before submission, display save errors, and reflect changes from other clients.
- [ ] **P0 · Basic defaults (DL-12–DL-14):** Global task count, default connections per task, and default folder are editable and persist for the OS user. Folder selection uses native file dialogs/portals and makes access failures actionable.
- [ ] **P1 · Proxy (DL-15):** System/custom proxy selection and credential entry are available. The client shows the effective policy without displaying or storing passwords in ordinary settings.
- [ ] **P1 · Advanced diagnostics:** Engine debug mode is off by default, can be toggled in preferences, states that a size-bounded per-user log will be written, and allows safe inspection/export with secrets redacted.

## Browser, OS, and background integration

- [ ] **P1 · Browser handoff:** A browser-originated request opens the native client for review, identifies its origin, and shows the safe URL/metadata. One link opens Add Download; a multiple-link request opens a checkbox review with filtering and All/None controls. Only confirmed selections become jobs. Repeated delivery of the same request does not create duplicates.
- [ ] **P1 · Browser settings:** The client shows integration availability/status and a clear path to browser-specific setup or troubleshooting. It does not claim interception where a browser, authentication context, streaming method, or site restriction prevents it.
- [ ] **P1 · OS activation:** File association, `.torrent`, `magnet:`, browser handoff, notification click, and manual launch reach the correct window/dialog on cold and warm launch without losing request source or type.
- [ ] **P1 · Background preferences:** Launch on login, start minimized, run engine in background, minimize to tray/status area where supported, and launch GUI when manually invoked are independent explicit settings. Closing a window follows the chosen behavior and prompts when stopping active work would be ambiguous.
- [ ] **P1 · Status area:** Where the OS supports it, the status item shows aggregate activity and offers open window, pause/resume, and quit/stop actions with accurate consequences. Where unsupported, the app remains recoverable from launcher, notification, and CLI.
- [ ] **P1 · Notifications:** Native completion/failure notifications have per-category toggles and useful click actions where supported. Lock-screen content omits credentials, private query strings, and sensitive paths; denied notification permission has an understandable in-app state.

## Credentials, privacy, and optional agent access

- [ ] **P1 · Credential management:** The client lets users add, inspect non-secret metadata, update, and remove site/proxy credentials scoped by protocol, host, realm/account, port, and optional path. Secrets go only through the OS secret-store path; password reveal requires explicit OS-backed authorization where practical. A locked or missing store yields a session-only choice where supported or a clear error, never plaintext fallback.
- [ ] **P1 · Consent and redaction:** Browser handoff carries safe metadata by default. Any future cookie/header forwarding requires narrow, ephemeral user consent. URL queries, headers, logs, diagnostics, and snapshots redact secrets; no analytics/telemetry is enabled by default.
- [ ] **P2 · MCP settings (MCP-01–MCP-03):** An Advanced panel shows the engine-hosted MCP server disabled by default, its loopback address/port, credential and read-only/mutation permission management, connection instructions, and errors such as port conflicts. Disabling it visibly ends access. The client never presents it as an unrestricted filesystem, shell, browser-cookie, or proxy-secret interface.

## Presentation, accessibility, and failure states

- [ ] **P0 · Native visual behavior:** Use restrained typography, system accent and theme, comfortable spacing, clear focus, accessible contrast, and native title bars/menus. Support system/light/dark appearance and reduced motion.
- [ ] **P0 · Full keyboard access:** Every essential action, dialog, queue, schedule grid, list, and progress detail is reachable and operable by keyboard. Native shortcuts and focus order are documented or discoverable; destructive actions have safe defaults.
- [ ] **P0 · Assistive technology:** Lists, states, progress, segment map, errors, and controls have meaningful accessible names and status announcements. Large text/scaling and screen readers do not hide essential controls; information is not conveyed by color alone.
- [ ] **P0 · Clear empty/loading/error states:** First run, no downloads, no search results, probing, engine disconnected, permission denied, disk full, unsupported protocol, invalid input, and unavailable integration have distinct, actionable presentations. Repeated retries do not silently create duplicate jobs.
- [ ] **P0 · Locale readiness:** User-facing strings are externalized; dates, times, numbers, sizes, rates, and time zones follow locale preferences while units remain unambiguous. Layout allows translated text and right-to-left locales. No specific shipped translation is committed here.
- [ ] **P0 · Privacy in the interface:** Sensitive values do not appear in default notifications, tooltips, accessibility labels, copied diagnostics, crash reports, or screenshots generated by the app. Explicit export/reveal actions state what they contain.

## Platform-specific implementation and exceptions

| Capability | macOS | Windows | Linux |
|---|---|---|---|
| Native framework | SwiftUI; AppKit adapters only as needed | WinUI 3 / Windows App SDK | GTK 4 / GLib/GIO + libadwaita; validate support viability |
| Main window and menus | One reusable main window, system menu bar, Settings scene, Dock/menu-bar integration | Fluent navigation, native window activation, taskbar/notification area | GTK application lifecycle, desktop menus/shortcuts, XDG integration |
| Files and links | Native open/save panels, Finder reveal, `.torrent`/`magnet:` registration | Native picker, Explorer reveal, file/protocol activation | GTK native dialogs or portals, file-manager reveal, desktop-file/MIME registration |
| Secret store | Keychain Services | Credential Manager / DPAPI-backed per-user store | Secret Service / compatible keyring; session-only or clear error when unavailable |
| Background and notifications | Login Item/LaunchAgent as appropriate, status item, native notifications | Per-user startup/task, notification-area icon, native notifications | XDG autostart or systemd user unit, Freedesktop/portal notifications; status area only where supported |
| Local IPC | Private per-user Unix socket with peer-UID check | Per-user Named Pipe with scoped ACL and remote rejection | Private Unix socket under XDG runtime with peer-UID check |
| Browser bridge | Safari Web Extension bridge plus applicable native messaging hosts | Browser-specific native messaging hosts | Browser-specific native messaging hosts |

The Linux status area is a **conditional capability**, not a requirement to fake a tray on desktops that do not provide one. A visible launcher/notification/CLI recovery path is mandatory. OS integration failures should be surfaced in the relevant client without changing the shared engine-owned rules. Minimum OS/runtime versions, CPU/package combinations, and exact notification/startup mechanisms remain validation decisions recorded in [docs/support-matrix.md](docs/support-matrix.md).

## Open product decisions

These points need explicit decisions before their acceptance checks can be made more specific; this document does not choose defaults beyond [PROJECT.md](PROJECT.md).

1. Which languages, if any, ship beyond the source language, and in which release?
2. Exact supported OS versions, desktop environments, architectures, and package formats for each release.
3. Exact behavior and wording when closing the GUI with active work under each background preference, including the stop-engine confirmation threshold. The Windows default and explicit quit/stop behavior are resolved in [Windows client UI specification](windows/WINDOWS_CLIENT.md#activation-background-operation-and-notifications--p0-lifecycle-p1-integration); the Linux default keeps transfers running after window close, with explicit stop-engine consequences, as specified in [Linux client UI specification](linux/Linux_CLIENT.md#lifecycle-integration-and-failure-states). macOS remains open.
4. Whether per-job/per-protocol bandwidth caps and one-time scheduling expose the same controls on all protocols from the first complete release.
5. The supported media-site matrix, format/merge capabilities, and playlist limits for P2 media review.
6. The supported browser/version matrix and whether optional authenticated-header handoff will ever ship.
7. The MCP protocol revision/transport, credential rotation UX, and permission granularity for the P2 panel.

When a decision is resolved, update [PROJECT.md](PROJECT.md) first if it changes product scope or architecture, then sharpen the corresponding client acceptance check here. Do not mark platform support or checklist completion without native, packaged, real-platform evidence.
