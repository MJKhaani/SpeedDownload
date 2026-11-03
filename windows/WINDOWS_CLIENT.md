# Windows client UI specification

This document defines the intended appearance and interaction of Speed Download for **C# / WinUI 3 with Windows App SDK**. It is a design specification, not an implementation or platform-support claim. The WPF compatibility application does not satisfy this specification.

[PROJECT.md](../PROJECT.md) owns product scope and architecture. [CLIENT.md](../CLIENT.md) owns the shared feature contract and requirement IDs. This document specializes that contract for Windows; P0 is release-blocking core, P1 is the first complete release, and P2 is a later enhancement. Unsupported features must not appear to work. OS versions, architectures, packaging, and runtime validation remain in the [support matrix](../docs/support-matrix.md).

## Design authority and approved direction

Follow Microsoft's [Windows app design guidance](https://learn.microsoft.com/en-us/windows/apps/design/) and [design basics](https://learn.microsoft.com/en-us/windows/apps/design/basics/), using Fluent and native WinUI behavior. These are the Windows equivalent of the requested HIG. The product choices below specialize that guidance; dimensions and interaction choices in this document are Speed Download decisions, not claims of Microsoft requirements.

Preserve the existing navigation/list/details concept while allowing its implementation to change. Use a compact, aligned download list with sortable headers, **no boxed cells and no vertical gridlines**. It must feel like a modern Windows collection, not an old spreadsheet. Keep branding to the app name and icon; use the user's system accent and familiar Windows controls.

## Visual foundations — P0

- Support System (default), Light, and Dark appearance. Use theme resources for surfaces, text, borders, focus, selection, and state colors; react to changes while running.
- Use Mica as the window's base backdrop where supported, with a quiet content surface above it. Do not apply translucent effects to every row. Use the platform's solid-color fallback for unavailable effects, disabled transparency, and contrast themes. See [Mica guidance](https://learn.microsoft.com/en-us/windows/apps/design/style/mica).
- Use WinUI's standard text styles and system font. Page titles establish hierarchy; filenames and controls use normal body text; metadata uses secondary text without becoming tiny. Do not inherit hardcoded 10–12px essential text from the prototype.
- Use a 4-effective-pixel spacing rhythm, usually 8 between related controls, 16 between groups, and 24 at spacious page edges. Narrow layouts may reduce margins. These are starting values; text scaling and usable hit targets take precedence.
- Use native icon resources or coherent vector icons with accessible names. Do not use emoji or text characters as action icons. File-type icons support filenames rather than replacing them.
- Preserve native corner radii, control states, focus outlines, and caption buttons. Avoid gratuitous cards, thick outlines, gradients, and shadows around each download.
- Use subtle hover and selection fills. Thin horizontal separators are optional when needed for readability; vertical rules, cell borders, and heavy alternating row stripes are prohibited.
- Motion is brief and purposeful. Respect reduced-motion settings; do not animate throughput or reposition focused rows on every progress update.

## Main window and navigation — P0, named queues P1

Use one reusable main window with a native title bar or a supported integrated title bar. Preserve dragging, system menu, minimize/maximize/close, Snap behavior, and accessible caption controls. Keep interactive content out of drag regions.

The wide-window composition is:

```text
Title bar: app icon and Speed Download                  Window controls
Navigation       Page title and search
                 Add download · selection commands · Sort · Details
All downloads    Filename           Status/progress    Size   Speed   ETA
In progress      Download rows, aligned without cell borders   | Details
Completed                                                     | when opened
Failed                                                        |
Queues (P1)
Settings         Engine connection · aggregate rate · effective cap
```

Use an adaptive `NavigationView`: full labels with enough room, compact navigation when space is constrained, and an overlay pane at narrow widths. All downloads is the default destination. In progress includes nonterminal waiting, paused, and verification work; the row's explicit state remains visible. Completed and Failed are filters, not independent copies of jobs. Canceled jobs remain discoverable in All downloads and state filters.

P1 adds the permanent `main` queue and named queues beneath a Queues heading. Keep Settings at the conventional bottom navigation position. Navigation changes preserve the previous view's search, sort, and scroll position where practical. Counts describe the current filter or queue and never suggest work has disappeared.

The toolbar has a labeled Add download primary action. Secondary actions operate on the selection; queue-wide actions explicitly name the queue. Search remains discoverable, with overflow for lower-frequency commands. Use a `CommandBar` or equivalent native command surface, not a ribbon.

The bottom status area shows engine connectivity, aggregate download rate, and effective bandwidth cap. P1 torrent upload is separately labeled. Connection loss is also an actionable in-content `InfoBar`; a tiny footer indicator alone is insufficient.

## Download collection — P0; search, sorting, grouping and batch actions P1

### Appearance and information

The wide presentation aligns Name, Status/progress, Size, Speed, and ETA under quiet sortable headers. Name receives the most width. Each item is one selectable row, not a series of editable cells. Start around 56 effective pixels per row to allow filename plus secondary context; expand for text scaling instead of clipping. Avoid a fixed height that prevents accessibility.

Show a file icon, filename, safe source host, labeled state, and verified progress. Place queue and destination in secondary metadata or the details view rather than forcing every field into a column. All fields required by CLIENT.md must remain available for each job. Right-align numeric values where appropriate and keep units explicit.

Use a small determinate `ProgressBar` for known verified totals, paired with text. Unknown size or ETA is labeled Unknown or Not available; a tooltip explains why when useful. Connecting/probing may use indeterminate activity, but must not imply measured byte progress. Never report completion before engine verification/finalization succeeds.

For true multi-column semantics, select a maintained WinUI-compatible collection control with column-header sorting and UI Automation support. Microsoft distinguishes text-oriented lists from tabular collections in its [collection guidance](https://learn.microsoft.com/en-us/windows/apps/develop/ui/controls/listview-and-gridview). A table-capable control is acceptable **with gridlines removed and row-based interaction**. Do not adopt a preview dependency solely for appearance or fake accessible table semantics with painted text. Record the concrete control choice during implementation against the pinned SDK.

### Selection, ordering and commands

Click selects; Ctrl-click toggles selection and Shift-click extends it at P1. Right-click and Shift+F10 expose the same context menu. Selection and keyboard focus remain visually distinct. Enter opens Details; Open file is an explicit command for a completed usable file.

On hover, keyboard focus within the row, or selection, reveal the relevant pause/resume/retry action and an overflow menu. Reserve their space so metadata does not jump. Touch selection reveals the same controls. Icons have tooltips and accessible action names. Every inline action is also reachable through the toolbar or context menu; hover is never required.

P1 headers toggle ascending/descending order and announce direction. A Sort menu provides equivalent access when headers collapse. Default to queue order in a queue view and newest added in All downloads. Rapidly changing speed/progress sorts must not continuously move a focused or selected row during interaction. Reorder is available in queue order; explain how to switch from another sort. Provide Move up/down commands as an alternative to drag-and-drop.

P1 batch selection displays the selected count and operation scope. Only offer valid operations, or explain which selected jobs are ineligible. Select all applies to the filtered view and says so. Removing a filter must not silently broaden a pending destructive operation.

| Engine state | Visible presentation | Typical valid action, subject to engine capability |
|---|---|---|
| Queued / scheduled | Waiting reason or next eligible time | Start if allowed, reorder, cancel |
| Resolving / connecting | Phase label and indeterminate activity | Cancel; pause when supported |
| Downloading | Verified bytes, rate, meaningful ETA | Pause, cancel |
| Paused | Paused label; preserved verified progress | Resume, cancel |
| Retry wait | Reason and next attempt | Retry now when supported, cancel |
| Verifying | Verification label and separate progress | Cancel when supported |
| Completed | Completion label and verified size | Open, reveal in Explorer |
| Failed | Concise cause and recoverability | Retry or review recovery |
| Canceled | Canceled label and retained-data status | Remove entry; restart if supported |

Pending commands show local activity without changing the authoritative state prematurely. Rejected commands retain the real state and expose an actionable error. Disconnects disable mutations that cannot be safely submitted; reconnect reconciles a fresh snapshot without duplicate jobs.

### Adaptive behavior

Use available content width, not device labels, to choose the layout. Suggested starting points are a full navigation/list/details composition above roughly 1200 effective pixels, compact navigation and a list below that, and stacked rows with overlay navigation below roughly 800. Validate these thresholds with translated and enlarged text.

Collapse ETA, then speed and size into labeled row metadata as width decreases. Keep filename, state, progress, and action access visible. Do not require horizontal scrolling for essential tasks. At narrow widths the Details command navigates to a dedicated page with Back, preserving selection and scroll on return.

## Download details — P0, verification extensions P1

Details opens a collapsible right pane on wide windows; it is not permanently forced open. Include a filename heading, state, appropriate job commands, and a labeled Close details action. Selecting another item updates an open pane. Multiple selection shows a selection summary and batch commands instead of arbitrary single-job data.

Group content into Overview, Transfer, and Activity, with secondary sections collapsible:

- Overview: safe source, destination with Explorer reveal, queue, verified bytes/total, rate, ETA, timestamps, and current phase.
- Transfer: method, active connections, sequential-fallback reason, transfer health, and range timeline for HTTP range-based work.
- Activity: meaningful state transitions, retries and safe response/header metadata, with redacted diagnostic copy/export.
- P1 verification: expected/actual checksum, source identity, verification and finalization result. A mismatch is a failure with a safe recovery action.

Keep overall progress primary. The secondary range map distinguishes completed, active, pending, and failed/retry spans through labels/patterns as well as color. Focusing a segment exposes offset range, downloaded bytes, worker, rate, and retry state when available. Provide a text summary and simple progress-only presentation. Do not show HTTP byte-range semantics for FTP or torrents; torrent details use verified piece/per-file information.

## Add and recovery flows

### Add Download — P0, FTP/FTPS P1

Entry, paste, and drag/drop open a native review surface; they never start unreviewed work. Use a `ContentDialog` for a short form, growing or moving to a dedicated page when content cannot fit accessibly. Avoid nested dialogs.

Show URL, safe source, editable filename, destination plus native folder picker, and transfer method. Offer the saved default folder. P1 adds queue choice and protocol-specific authentication. Keep connections/multipart controls in an expandable advanced section. Validate fields inline and focus the first invalid field on submission.

The primary action states the outcome: Start download or Add to queue. Cancel closes without creating a job. During submission prevent repeat sends, show pending status, and close only after acknowledgment. Preserve entered data on failure. FTP warns about clear-text transport, certificate failures, and resume limitations without promising HTTP multipart behavior.

For source changes or untrusted partial data, show why continuation is unsafe and separate Restart download from Cancel. Explain whether partial data will be discarded before consent. P1 expired-link recovery exposes the reference page, Open reference page, and review of a replacement URL; matching names/sizes alone never authorize reuse.

### Add Torrent — P1 (DL-08)

`.torrent` and `magnet:` activation open a dedicated Add Torrent flow, not a torrent picker inside Add Download. Show metadata loading and cancel/error states before the validated file tree. Review destination, queue, file selection/priorities, and editable trackers before adding. Large trees use a dedicated page or appropriately sized native window.

Details show per-file progress, peer/seed counts when available, trackers, download/upload rates and caps, verified pieces where useful, and explicit seeding status. Post-completion seeding is a configurable choice. Unsafe paths and invalid metadata block submission with specific errors.

### Add Media and portability — P2

After engine probing, Add Media reviews title, filename, quality, audio-only choice, container/codec, and approximate size when known. Playlists show title/count, All/None and individual selection, per-item format choices as applicable, and destination queue. Only confirmed items are submitted. Unsupported/private/expired/live/DRM cases have truthful limitations.

Mirror URLs, categories, and job-list import/export use reviewable forms. Import previews affected entries and individual errors before submission; export explains its sanitized contents. Do not expose secret URLs or credentials in exported lists.

## Queues, schedules and bandwidth — P0/P1/P2

P0 exposes global concurrency, relevant per-host limits, default connections, multipart mode (`off`, `auto`, `fixed`), and why a job is waiting. Validate bounds against engine capabilities and never claim that more connections guarantee speed.

P1 queue pages show active count, concurrency, effective schedule state, and clearly scoped pause/resume/start commands. Resume Queue includes waiting and paused work subject to scheduler policy. Creating/renaming queues uses short native forms. Deleting a user queue offers Move jobs to main or Cancel; `main` cannot be deleted. Never silently discard jobs or files.

A queue's optional completion shell command is off until deliberately entered and enabled. Show execution identity, exact trigger, and consequences; report failures in queue activity. Browser input cannot configure it.

P1 schedule editing covers one-time/recurring timing, named time zone, start/end windows, and supported priority. Preview upcoming runs and explain sleep/wake, missed windows, time-zone changes, and daylight-saving ambiguity. Queue weekly schedules use a seven-day hourly Active/Off grid; bandwidth has a separate limited-speed grid. Both offer keyboard cell movement, labeled states, and an equivalent day/time form for assistive technology. Edits show pending/saved/error status and remain effective with the GUI closed.

Bandwidth controls show global download cap, supported job/protocol caps, units, and the effective limit after applicable policies. Zero global cap means Unlimited and is presented with that label. Torrent upload remains separate. Do not imply unsupported protocol parity; defer unresolved capabilities to CLIENT.md. P2 network/battery/metered rules expose detected conditions, effects, and an explicit override.

## Settings

Settings is a native page with labeled groups and standard inputs (`ToggleSwitch`, `ComboBox`, `NumberBox`, password input, folder picker). Use a section list when needed rather than a wall of unrelated controls. Explain settings near their controls and show save failures inline. Load engine-owned preferences from the engine, validate before submission, and reflect changes from other clients; appearance/window preferences may remain client-owned.

| Section | Content and priority |
|---|---|
| General | P1 independent login launch, start minimized, background engine, close/minimize behavior, manual GUI launch |
| Downloads | P0 default folder and global task count; P1 queue defaults and integrity options |
| Connections & Segments | P0 connection count and multipart mode; P1 system/custom proxy and credential reference |
| Bandwidth | P1 global/effective caps, supported protocol caps, weekly limited-speed rules |
| Schedule | P1 timing, time zones and previews; P2 environment rules |
| Browser Integration | P1 browser-specific availability, setup and troubleshooting; truthful interception limitations |
| Privacy & Credentials | P1 scoped credential metadata, add/update/remove; consent and redaction; no telemetry by default |
| Notifications | P1 completion/failure toggles, privacy and unavailable/denied state |
| Appearance | P0 System/Light/Dark; follow system accent, contrast, text scale and reduced motion |
| Advanced | P1 debug mode off by default, bounded per-user log notice, safe inspect/export; P2 MCP |

Credentials show protocol/host/account/realm/port/path metadata without plaintext secrets. Use the Windows secret-store path; reveal requires explicit authorization where practical. Locked/unavailable storage offers supported session-only use or an actionable error, never plaintext fallback. Optional cookie/header handoff requires narrow, ephemeral consent.

P2 MCP settings remain disabled by default and expose loopback address/port, credentials, read-only/mutation permissions, connection instructions, and port errors. Disabling visibly ends access. Do not portray MCP as unrestricted filesystem, shell, cookie, or proxy-secret access.

## Activation, background operation and notifications — P0 lifecycle, P1 integration

Reuse or activate the main window for manual launch and route file/protocol/browser/notification activation to the correct job or review flow on cold and warm launch. Retain request origin/type. One browser link opens Add Download; multiple links open a checkbox review with filter and All/None. Deduplicate repeated delivery without automatically accepting it.

The approved Windows close policy is:

| Action | Result |
|---|---|
| Close / Alt+F4, default | Hide the window; active engine work continues. Keep notification-area access when available. |
| First close with active work | Explain “Downloads will continue in the background. Reopen Speed Download from the notification area or Start.” Offer Continue in background and Cancel, plus a path to General settings. |
| Quit Speed Download | Exit the client and its notification-area icon; engine work continues. State “Downloads continue in the background” in the command description. |
| Quit and stop engine | Explicit graceful stop. If active or scheduled work exists, show its scope and require confirmation; Cancel is the safe default. Explain resumable-data preservation and that schedules will not run while stopped. |
| Engine stop failure | Keep the failure visible and offer retry; never claim the engine stopped. |

General settings can change closing to exit the client, or to ask about stopping the engine. No close preference silently terminates active work. Keep login launch, start minimized, background engine, and minimize-to-notification-area settings independent. If notification-area integration is unavailable, explain reopening from Start; manual launch must reliably reconnect. P0 lifecycle correctness does not depend on P1 tray integration shipping.

The notification-area menu offers Open Speed Download, explicitly scoped pause/resume, Quit Speed Download, and Quit and stop engine. Native completion/failure notifications honor per-category preferences and open the relevant job. Lock-screen text omits sensitive paths and private URL data. Taskbar progress reflects meaningful aggregate verified progress; unavailable totals must not produce invented percentages.

## Failure states, privacy and accessibility — P0

| Situation | Required presentation and recovery |
|---|---|
| First run / empty collection | Brief explanation and Add download action |
| No search results | Keep query visible; offer Clear filters |
| Engine starting | Connection activity with bounded failure/retry path |
| Engine disconnected | Persistent InfoBar, stale-data label, safe reconnect; no live-looking speed/ETA |
| Incompatible engine | Explain mismatch and supported recovery; no mutation attempts |
| Probing / metadata loading | Labeled activity, cancel, and recoverable failure |
| Invalid URL / unsupported protocol | Field-specific explanation; no job created |
| Permission denied / disk full | Affected destination, safe actionable recovery; preserve input and verified data |
| Integration unavailable | Browser/notification-specific status and setup/troubleshooting path |
| Mutation/save rejected | Preserve actual values, show failure near the initiating control, allow safe retry |

Use inline feedback or an `InfoBar` for recoverable failures; reserve modal confirmation for consequential decisions. Removing history and deleting files are distinct choices. Destructive dialogs name the affected count, distinguish partial from completed data, and default to preserving files. Ordinary pause never deletes resumable data.

Follow Microsoft's [accessibility guidance](https://learn.microsoft.com/en-us/windows/apps/design/accessibility/accessibility-overview). Provide meaningful UI Automation roles, names, state and progress summaries, including custom collection headers and segment maps. Announce significant transitions rather than every speed update. Support Narrator, contrast themes, visible focus, keyboard-only operation, large text, and mixed-DPI displays. State, progress, selection and errors must remain understandable without color.

Use standard Tab/Shift+Tab focus traversal, arrow-key collection navigation, Space for selection/toggles, Shift+F10 for context actions, Enter for the focused primary action, and Escape to dismiss a transient surface. Suggested app shortcuts: Ctrl+N Add download, Ctrl+F Search (P1), Ctrl+A select filtered items (P1), Alt+Left Back from narrow Details. Show shortcuts in menus/tooltips. Do not override text-field editing shortcuts or make Delete immediately erase files. Restore focus to the invoking control after dialogs and details close.

Externalize strings and allow expansion. Format dates, numbers, sizes, rates, and time zones for locale with unambiguous units. Mirror navigation/layout for RTL while preserving correct URL/path rendering. Do not hardcode English width assumptions. Redact secrets in notifications, tooltips, accessibility labels, diagnostic copies, logs, and app-generated screenshots. Explicit sensitive reveal/export actions explain their contents.

## Implementation review and acceptance

This specification does not authorize claims that its features are implemented. Keep status in platform READMEs and the [engine feature status](../docs/engine-feature-status.md). Validate the actual WinUI application on the combinations declared in the support matrix; WPF screenshots or a cross-platform build are not Windows UI evidence.

- P0: inspect light/dark/contrast themes and Mica fallback; confirm borderless aligned rows, clear hover/selection/focus, and native title-bar behavior.
- P0: exercise narrow/wide windows, mixed DPI, enlarged text and RTL; essential actions remain available without clipped controls.
- P0: add, pause/resume, cancel, recover and inspect a download with keyboard and Narrator; verify unknown totals, verification failure, stale connection, denied paths and disk-full handling.
- P0: exercise at least 100 queued/active jobs on representative hardware; preserve virtualization, selection/focus, coalesced progress, and responsive dialogs. UI/IPC work must not transfer bytes or own scheduling.
- P0: close/relaunch and reconnect without stopping engine work or duplicating jobs; verify command acknowledgment and graceful-stop failures.
- P1: validate sortable headers, filtered batch scope, reorder alternatives, queue independence, credentials, notifications, activation and browser deduplication.
- P1: check schedule grids with keyboard/Narrator and form alternatives; exercise sleep/wake and daylight-saving cases, FTP failures, torrent metadata/file selection, and explicit seeding.
- P2: validate media/playlist review and limitations, sanitized import/export, environment rules, and disabled-by-default MCP permissions and errors.

For each release, record tested OS/CPU/package/SDK, accessibility evidence, limitations, and failures in the appropriate platform documentation. Recheck upstream guidance and control availability before selecting dependencies; this document is a visual and interaction contract, not a dependency-version pin.
