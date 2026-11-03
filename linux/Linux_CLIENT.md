# Linux client UI specification

This document defines the intended appearance and interaction of Speed Download for **C, GTK 4, GLib/GIO, and libadwaita**. It is a design contract, not an implementation or platform-support claim.

[PROJECT.md](../PROJECT.md) owns product scope and architecture; [CLIENT.md](../CLIENT.md) owns shared behavior and requirement IDs. All shared requirements apply. P0 is release-blocking core, P1 the first complete release, and P2 a later enhancement. Exact runtime versions, architectures, desktop environments, and packaging remain validation decisions in the [support matrix](../docs/support-matrix.md).

## Design authority and approved direction

Follow the [GNOME Human Interface Guidelines](https://developer.gnome.org/hig/), including its [navigation](https://developer.gnome.org/hig/guidelines/navigation.html), [header bars](https://developer.gnome.org/hig/patterns/containers/header-bars/), [menus](https://developer.gnome.org/hig/patterns/controls/menus.html), and [dialogs](https://developer.gnome.org/hig/patterns/feedback/dialogs.html) guidance. Use libadwaita's [adaptive layout patterns](https://gnome.pages.gitlab.gnome.org/libadwaita/doc/main/adaptive-layouts.html). The layouts, labels, and workflow choices below are product decisions applying that guidance, not additional GNOME mandates.

The approved direction is GNOME-first, including on other Linux desktops: rich download rows, a locations/queues sidebar, on-demand adaptive details, explicit batch selection, focused intake dialogs, and searchable Preferences. Use Adwaita styling rather than imitating Windows or building a custom theme. libadwaita is an explicit dependency of this intended design; shipping configurations must validate its availability. Do not silently drop supported desktops or architectures to adopt it.

## Visual foundations — P0

Use standard Adwaita surfaces, typography, spacing, symbolic icons, focus rings, and control states. Branding belongs in the app icon and name. Avoid custom title-bar decorations, dense toolbars, decorative gradients, boxed cells, and a dashboard of unrelated cards. Keep header bars sparse, with actions near the content they affect and window controls following desktop configuration.

Use normal body text for filenames and controls, secondary text for metadata, and headings for meaningful groups. Text remains readable with large fonts; do not force essential metadata into tiny fixed-size text. Use consistent native spacing, generous group separation, and restrained separators. Long filenames wrap or ellipsize without losing access to the full safe name in details. Never make hover the only way to obtain information.

System appearance is the default; Preferences offers System, Light, and Dark. Follow supported system accent, high-contrast, font, and reduced-motion settings. Retain usable native fallback styling where desktop preferences are unavailable. Progress and status use labels or patterns as well as color. Avoid continuously animated speed counters and row movement as progress changes.

## Main window and navigation — P0; named queues P1

Reuse one main application window. Restore useful window geometry without reopening off-screen or forcing a fixed minimum that makes smaller displays unusable.

```text
Sidebar header                    Content header
Speed Download · primary menu     Add Download · view title · Search · view menu
─────────────────────────────────────────────────────────────────────────────
All Downloads                     Filename                 Pause/Resume · ⋮
Active                            State · verified progress
Completed                         Size · speed · ETA
Failed                            Source · destination · queue (secondary)

Queues                            Further download rows       Details, when open
  main                                                        Summary / progress
  Personal                                                    Expandable diagnostics
─────────────────────────────────────────────────────────────────────────────
                                  Engine status · aggregate rate · effective cap
```

This sketch describes content hierarchy, not fixed pixel positions. Put the primary menu above the navigation sidebar. It contains Preferences, Keyboard Shortcuts, About, and the explicit Stop Engine action. Keep per-view sorting, grouping, selection, and filtering in the content view menu. The primary Add action opens ordinary URL review; offer separate Open Torrent and applicable media intake actions without embedding a torrent picker in Add Download.

All Downloads is the default location. Active includes all nonterminal work, including queued, scheduled, paused, retrying, and verifying jobs; explicit state labels prevent confusion with currently transferring jobs. Completed and Failed filter the same underlying collection. Canceled jobs remain discoverable in All Downloads and state filters. Queue locations contain all jobs belonging to that queue. Counts have clear scope. Preserve search, sort, and scroll position per location where practical.

At narrow widths, collapse navigation behind an accessible sidebar button. On-demand details become a navigated page with Back; return to the same row and scroll position. At wide widths, details appear alongside the list and have a close action. Start with details closed. Never squeeze sidebar, list, and details into three unreadable columns. Choose breakpoints from content needs, translation, and font scaling, not device names. Standard keyboard, mouse, and touch operation must work in every arrangement.

Implementation candidates include AdwApplicationWindow, AdwToolbarView, AdwHeaderBar, AdwOverlaySplitView for locations, and AdwNavigationView/AdwNavigationSplitView for list/details. Validate availability against the chosen runtime before implementation; class names here do not claim that dependencies are already installed.

## Download collection and actions — P0; advanced collection tools P1

Use a model-backed, virtualized GtkListView with rich rows. A row has a file-type icon, filename, textual phase, verified progress, known total, current speed, meaningful ETA, and safe secondary source, destination, and queue information. On narrow windows secondary metadata can wrap or move into the activated details view; all required fields remain accessible. Unknown totals say Unknown; do not invent a percentage or ETA. Completed is reserved for verified, finalized work.

Distinguish queued, scheduled, resolving, connecting, downloading, paused, retry wait, verifying, completed, failed, and canceled. Waiting rows explain their current blocker, such as a queue schedule, global limit, host limit, or paused queue. Show fallback reasons when multipart cannot be used. Never imply that additional connections guarantee more speed.

Activating a row opens details. Provide the relevant pause/resume control and an overflow menu with valid start/resume, pause, cancel, retry, reorder, delete, reveal, and open actions. Opening a completed file is a separate deliberate action. Disable or omit invalid actions with an understandable reason where needed. Pause preserves partial data. Distinguish Cancel Download, Remove from History, and Delete Files in wording; deletion review states whether partial data or the completed file is affected and defaults to a safe choice.

P1 adds scoped search, state filters, sort options, grouping, and batch operations. Enter selection mode explicitly; show checkboxes, selected count, scope, and a contextual action bar. Row activation toggles selection in this mode. Select All applies to the stated filtered collection, not silently to hidden jobs. Changing scope clears selection with an understandable update. Enable a batch command only for a clearly described eligible set; report partial failures per job. Escape exits selection before dismissing the surrounding view. Keyboard reordering must be available alongside any drag gesture; manual ordering applies to scheduler order, not arbitrary sorted views.

## Download details and recovery — P0; integrity and link replacement P1

The details surface begins with filename, state, verified progress, usable file actions, and any actionable error. Follow with grouped source/destination/queue, size and rate, current phase, activity timeline, transfer health, safe response/header metadata, and retry reason. Redact URL secrets and authentication metadata in display, copying, accessibility, and export. Keep routine progress prominent and diagnostics expandable.

Show a range timeline separately from overall verified-byte progress. Completed, active, pending, and failed/retry spans have patterns or text equivalents. An expandable connections section shows active count and per-connection rate; focusing a segment exposes offsets, downloaded bytes, worker, rate, and retry state when available. Supply a simple progress-only presentation and a keyboard/screen-reader equivalent. Do not draw HTTP byte ranges for torrent pieces or other protocols with different work units.

Recovery after interruption shows resumed, rechecking, or failed status accurately. Changed source identity or untrusted partial data prompts a clear restart/discard decision before incompatible bytes are reused. P1 adds expected checksum entry/import, verification result, source identity, and finalization status. A checksum mismatch is a failure with investigation and safe restart options.

Expired-link recovery exposes the safe reference page and an Open Reference Page action. Review the replacement URL before submission. Explain whether the engine can safely reuse partial data; matching name or size alone is insufficient. Discarding partial data or restarting requires explicit consent.

## Intake and protocol-specific review

### Add Download — P0; FTP/FTPS P1

URL entry, paste, and drag/drop open the same review. Show URL, editable safe filename, native destination chooser, queue, and transfer method. Offer the saved default folder; expose main as the fixed queue before named queues ship. Validate input and access before submission. Show probing progress, cancel, and actionable errors without creating a job. A pending Add submission cannot be repeated into duplicate jobs; preserve review input after failure and show the accepted outcome only after engine acknowledgement.

Put advanced connection overrides and applicable integrity/authentication controls in an expandable group. Passwords use secret entry controls and the credential flow. Use native GTK dialogs/portals for folders and files. FTP review explains clear-text exposure, certificate failures, server limitations, and resume availability. Do not imply HTTP multipart semantics for FTP.

### Add Torrent and torrent details — P1

Opening a .torrent document or magnet link enters a dedicated native review, including cold launch. Wait for validated metadata, showing progress and cancel/error states. Present a file tree with selection and priorities, destination, queue, and editable trackers before adding. Unsafe paths and invalid metadata block submission with specific errors.

Details show per-file progress, verified piece state where useful, peers/seeds when known, trackers, download/upload rates and caps, and seeding state. Make post-completion seeding an explicit configurable choice, with download completion distinct from active seeding.

### Browser batch and media review — P1/P2

P1 browser handoff identifies its origin and safe metadata. A single link opens Add Download; multiple links open a checkbox review with filtering, All/None, and a visible selected count. Only confirmed entries become jobs. Deduplicate repeated delivery, including during reconnect or cold activation. Browser requests cannot configure shell finish actions.

P2 media pages show probing followed by title, filename, quality, audio-only options, container/codec, and approximate size where known. Playlists include title/count, per-entry selection, All/None, formats as needed, and queue. Clearly explain unsupported, expired, private, live, and DRM-protected cases without implying bypass. Site support and limits remain separate product validation decisions.

P2 organization adds mirror URLs, categories, and job-list import/export to relevant details and collection actions. Imports have review and entry-specific errors; exports sanitize sensitive data. Failed entries do not corrupt or silently replace existing jobs.

## Queues, scheduling, and bandwidth — P0 basics; P1 editors

P0 exposes global active-task limits, relevant host limits, and validated default connections/multipart mode. Changes update the running view without app restart. The engine owns scheduling and limits.

P1 queue navigation includes permanent main and user queues. Queue details provide rename/delete, active count, concurrency, effective schedule, and pause/resume/start controls. Resume Queue starts waiting and resumes paused jobs under scheduler policy; global and host limits still apply. Move waiting jobs through a queue chooser. Deleting a user queue offers moving jobs to main or canceling the deletion; never discard jobs or partial files silently. main cannot be renamed or deleted.

A separate, deliberately enabled finish-action editor accepts a user-entered shell command. Explain the per-user execution identity, all-jobs-complete trigger, and shell execution risk. Display failures and never accept this setting from browser intake.

Schedule editors support one-time and recurring job/queue timing, named time zone, start/end windows, and priority where available. Preview upcoming behavior and explain missed windows, sleep/wake, zone changes, and daylight-saving ambiguity. Queue weekly schedules use a seven-day hourly Active/Off grid with an effective-state summary. Provide an equivalent day/time-range editor backed by the same data, including keyboard operation and announced day/hour/state. Both presentations remain usable at narrow widths and large text sizes.

Bandwidth settings provide a global download cap with explicit units and 0 meaning Unlimited, the weekly limited-speed grid with the same accessible editing alternative, and an effective-cap preview. Applicable job/protocol caps belong in details; torrent upload is separate. Where protocol support differs, explain unavailable controls rather than pretending they work. Saved schedules remain effective after the GUI closes. P2 environment rules show detected network/battery/metered conditions, expected effects, and override.

## Preferences and credentials — P0/P1; optional P2 controls

Open a searchable, adaptive Preferences surface from the primary menu and Ctrl+Comma. Prefer AdwPreferencesDialog with search explicitly enabled, using AdwPreferencesPage/Group and native entry, switch, combo, and action rows. It behaves as a parented preferences window/dialog on desktop and adapts to narrow space. Do not place ten cramped tabs in the main window. Use readable page navigation and shallow subpages for complex editors. See the [libadwaita API reference](https://gnome.pages.gitlab.gnome.org/libadwaita/doc/main/) and HIG [boxed-list guidance](https://developer.gnome.org/hig/patterns/containers/boxed-lists.html).

| Section | Controls and intended presentation |
|---|---|
| General | Independent launch-on-login, start-minimized, engine-in-background, supported status-area behavior, and manual GUI-launch preferences; explain desktop integration availability and window-close consequences. |
| Downloads | Default folder with native chooser and access feedback; global concurrent-task count; relevant default transfer and torrent seeding choices. |
| Connections & Segments | Default connections per task, multipart Off/Auto/Fixed, validated bounds, fallback explanations, and simple-progress preference. P1 proxy selection uses system/custom policy with credential references and effective-policy summary. |
| Bandwidth | Global download cap and units, Unlimited state, weekly limited-speed editor, effective cap; applicable protocol defaults with separate torrent upload controls. |
| Schedule | Shared scheduling defaults and access to scheduling editors; named time zone and behavioral previews. Queue schedules and one-time job timing remain editable at their owning queue/job. |
| Browser Integration | Browser-specific availability/status, setup and troubleshooting; clearly state interception limitations. Optional future authenticated-header consent must be narrow and ephemeral, not a broad capture toggle. |
| Privacy & Credentials | Site/proxy credential metadata and add/update/remove actions; consent and redaction explanations. No telemetry enabled by default. |
| Notifications | Completion/failure category toggles, permission/availability status, and privacy-safe behavior. |
| Appearance | System/Light/Dark; explain inherited system accessibility preferences without duplicating OS controls unnecessarily. |
| Advanced | Debug mode off by default with bounded per-user log explanation and safe inspect/export; P2 environment rules and MCP subpages as applicable. |

P0 controls ship at P0; P1/P2 page content is labeled as later scope in this specification, not presented as working in a partial release. Search should find settings by user-facing labels and useful synonyms, including controls in subpages. Search results navigate to the owning control.

Load settings from the engine. Validate bounds and input locally, submit through IPC, and display pending, saved, and failed outcomes. Simple settings may apply immediately after validation; multi-field schedules, proxies, credential edits, and shell commands use explicit Save/Apply. Do not send incomplete values on every keystroke. Preserve edits after failure and offer retry. Reflect changes from other clients; if a remote change conflicts with an unsaved edit, show the conflict and let the user reload or deliberately resubmit. Never write engine settings files directly.

Credentials show protocol, host, realm/account, port, and optional path, never secret text in lists. Use Secret Service/compatible keyring; reveal requires explicit OS-backed authorization where practical. Locked or missing stores offer supported session-only use or an actionable error, never plaintext fallback. Deletion explains the affected scope. Exclude secrets from notifications, tooltips, labels, logs, diagnostics, and application-generated screenshots.

P2 MCP is disabled by default. Its Advanced subpage shows loopback address/port, credential management, read-only/mutation permissions, connection instructions, and failures such as port conflict. Disabling visibly ends access. Do not present unrestricted filesystem, shell, cookie, or proxy-secret access. Exact protocol/transport, rotation UX, and permission granularity remain shared open product decisions.

## Lifecycle, integration, and failure states

At launch, start only the trusted installed engine if needed, then connect through versioned private per-user IPC. Show connecting, startup failure, incompatible version, and safe retry. Engine loss produces a persistent banner; mark live values stale and disable commands that cannot be delivered. A fresh snapshot and resumed events restore the view without duplicate submissions. Coalesce live updates, keep IPC and disk work off the UI thread, and keep at least 100 queued/active jobs responsive.

Closing the window leaves transfers running by default. Explain this on first close without repeatedly interrupting normal use. Reopening from the launcher reattaches. Keep explicit background preferences independent; if a chosen preference would stop active work, explain consequences and obtain confirmation before stopping it. Stop Engine… always describes effects on active work and requires confirmation when active work would be interrupted. Quitting the GUI must not masquerade as stopping the engine.

Use XDG activation and desktop-file/MIME registration for ordinary launch, torrent files, magnet links, browser requests, and notification clicks. Route cold and warm activations to the correct review/details surface, preserving request type and origin. Launch-on-login uses validated XDG autostart or systemd user integration; surface failures in General. Start minimized must have a recoverable supported path and never strand an invisible app.

A status-area item is optional only where supported, with open, aggregate activity, pause/resume, and explicit quit/stop consequences. Do not require a GNOME shell extension or fabricate a tray. Launcher, notification where available, and CLI remain recovery paths. Completion/failure notifications use native Freedesktop/portal mechanisms with useful click actions, private lock-screen content, and clear denied/unavailable states.

| Situation | Presentation and recovery |
|---|---|
| First run / empty collection | Native status page explaining Add Download; no fabricated jobs. |
| No search results | Explain current scope and offer clear search/filters. |
| Probing / connecting | Labeled progress; cancel when applicable; retain user input. |
| Engine disconnected / incompatible | Persistent banner or blocking initial status, stale marker, actionable retry/version guidance. |
| Invalid input / unsupported protocol | Error adjacent to affected input, clear correction, no created job. |
| Permission denied / missing folder | Explain access problem; reopen native chooser or retry. |
| Disk full | Identify the affected job and safe destination/capacity recovery; no false completion. |
| Verification / source mismatch | Persistent failed/rechecking state, reason, safe restart review. |
| Integration unavailable | Explain the unsupported capability in its settings page and provide an available alternative. |

Use toasts for brief noncritical confirmations, banners for persistent conditions, field errors for invalid input, and parented dialogs for decisions. Do not hide actionable failures in transient toasts or stack multiple modal dialogs. Restore focus to the invoking control after dismissal.

## Keyboard, accessibility, and localization — P0

All essential actions must be operable without pointer gestures, including queue reordering, batch actions, file trees, weekly grids, and segment inspection. Follow [GNOME keyboard conventions](https://developer.gnome.org/hig/guidelines/keyboard.html), expose shortcuts in a native shortcuts surface, and preserve editing shortcuts within text fields. Suggested app bindings: Ctrl+N Add Download, Ctrl+F search current collection, Ctrl+Comma Preferences, Ctrl+W close window, Alt+Left Back, and Escape dismiss the current transient mode/container. Ctrl+A in list selection mode selects its stated scope; inside text entry it selects text. Do not bind an unconfirmed destructive operation to a single key.

Provide meaningful accessible names, roles, values, states, focus order, and error associations. Announce important phase changes and command outcomes without announcing every progress tick. Preserve focused rows across updates. Give range maps equivalent text navigation; each schedule cell exposes day, time, and state. Respect high contrast, reduced motion, large text, translated labels, and RTL layout. Externalize strings; format dates, times, numbers, sizes, and rates by locale with unambiguous units. No additional shipped language is promised here.

## Shared requirement coverage and acceptance

Each row maps one checklist item in CLIENT.md. These are acceptance conditions for future implementation, not checked-off evidence. The corresponding sections above define presentation and interaction.

| Shared requirement (priority / IDs) | Linux surface | Acceptance condition |
|---|---|---|
| P0 · Native application | Design authority | Uses C/GTK 4, GLib/GIO and validated libadwaita with native focus and controls. |
| P0 · Authoritative engine | Lifecycle | Commands use versioned engine IPC; GUI performs no transfers or direct database/settings writes. |
| P0 · Connection lifecycle | Lifecycle | Cold launch, startup failure, incompatible version, engine loss and retry produce distinct truthful states. |
| P0 · Independent lifecycle | Lifecycle | Closing/crashing the GUI preserves active transfers; relaunch reattaches; stop consequences are explicit. |
| P0 · Responsiveness | Lifecycle | At least 100 queued/active jobs remain usable while progress is coalesced off blocking I/O. |
| P0 · Truthful state | Collection / Preferences | Pending, accepted and failed commands remain distinguishable; stale and unverified data never appear final. |
| P0 · Add download (DL-01, DL-14) | Add Download | Entry, paste and drop require validated filename/source/destination/method review before adding. |
| P0 · Download list (DL-03) | Collection / details | Every required field and phase is available; unknown values are explicit. |
| P0 · Job actions (DL-03) | Collection actions | Valid actions work by keyboard; destructive review distinguishes history, partial data and completed files. |
| P0 · Queue basics (DL-04, DL-12) | Queues | Global/host limits and waiting reasons are visible; changes and reordering apply without restart. |
| P0 · Connection settings (DL-06, DL-13) | Connections & Segments | Validated connections and Off/Auto/Fixed modes expose fallback reasons. |
| P0 · Recovery (DL-02, DL-05) | Details and recovery | Restart/network/power recovery reports rechecking or failure; incompatible partial data requires a decision. |
| P1 · Named queues (DL-17) | Queues | main is permanent; create/rename/delete/move preserve jobs and partial files. |
| P1 · Queue controls (DL-18, SC-07) | Queues | Counts, caps, schedules and Resume Queue obey queue/global/host policy without changing other queues. |
| P1 · Queue finish action (DL-18) | Queue finish action | Shell identity, trigger and risk require deliberate enablement; browser intake cannot set it; failures are visible. |
| P1 · Find and batch work (DL-09) | Collection selection | Scoped search/filter/sort/group/batch operations show count and destructive scope, including partial failures. |
| P1 · Integrity controls (DL-10) | Details integrity | Expected checksum entry/import and verification progress/result expose mismatches as failure. |
| P1 · Expired-link recovery (DL-16) | Link replacement | Reference page and replacement review require consent for discard/restart; name/size alone do not authorize reuse. |
| P2 · Organization and portability (DL-11) | Organization and portability | Mirrors/categories/import/export have input review, per-entry errors and sanitized output. |
| P0 · Details | Details | Phase, timeline, health, safe metadata and diagnostics are available; file actions require a usable file. |
| P0 · Progress map (DL-06) | Details progress map | Verified overall progress and patterned/labeled spans remain distinct; protocol-specific units are respected. |
| P0 · Segment inspection | Details connections | Expandable connection and segment metrics have keyboard/text equivalents and simple-progress mode. |
| P1 · File verification | Details integrity | Checksum/source/finalization appear without secret queries/headers; failed verification offers safe recovery. |
| P1 · FTP/FTPS (DL-07) | FTP/FTPS review | Authentication and destination review explain clear text, certificates, server limits and resume. |
| P1 · Torrent intake (DL-08) | Add Torrent | Dedicated review waits for validated metadata and exposes tree/priority/trackers/queue/destination. |
| P1 · Torrent details | Torrent details | File/piece/peer/tracker/rate/cap/seeding states are truthful and unsafe metadata produces actionable errors. |
| P2 · Media page review (MED-01–MED-04) | Media review | Probe results, format choices and playlist selections require confirmation; unsupported cases are explicit. |
| P1 · Schedule editor (SC-01, SC-02, SC-05) | Schedule editors | Timing/time zone/priority and upcoming behavior explain missed windows, sleep/wake and DST. |
| P1 · Queue weekly grid (DL-18, SC-07) | Queue weekly schedule | Seven-day hourly grid and equivalent range editor save live and remain effective after GUI close. |
| P1 · Bandwidth controls (SC-03, SC-04) | Bandwidth | Explicit units, zero-as-unlimited, effective cap, weekly grid and separate torrent upload are testable. |
| P2 · Environment rules (SC-06) | Environment rules | Detected condition, resulting policy and override are visible. |
| P0/P1 · Preferences | Preferences | All ten searchable sections validate and submit through engine IPC, show failures and reflect external changes. |
| P0 · Basic defaults (DL-12–DL-14) | Downloads / Connections | Task count, connection defaults and native folder selection persist per user and expose access errors. |
| P1 · Proxy (DL-15) | Proxy preferences | System/custom policy and credential entry expose effective policy without storing plaintext passwords. |
| P1 · Advanced diagnostics | Advanced diagnostics | Debug is initially off; bounded per-user logs and inspection/export redact secrets. |
| P1 · Browser handoff | Browser review | Origin is visible; single/batch requests require confirmation and repeated delivery is deduplicated. |
| P1 · Browser settings | Browser Integration | Availability and browser-specific setup/troubleshooting describe actual interception limitations. |
| P1 · OS activation | Activation | Cold/warm file/link/browser/notification/manual entry routes correctly without losing source/type. |
| P1 · Background preferences | General / lifecycle | Independent startup/background choices explain close behavior and never strand an invisible app. |
| P1 · Status area | Status area | Supported desktops expose accurate actions; absent tray still permits launcher/notification/CLI recovery. |
| P1 · Notifications | Notifications | Category toggles, safe lock-screen content, click actions and permission failures behave correctly. |
| P1 · Credential management | Privacy & Credentials | Scoped metadata CRUD uses OS secret store; locked/missing store never falls back to plaintext. |
| P1 · Consent and redaction | Privacy / intake | Safe browser metadata, narrow future consent and redacted outputs preserve privacy with telemetry off by default. |
| P2 · MCP settings (MCP-01–MCP-03) | Advanced MCP | Disabled default, loopback access, credentials/permissions, errors and revocation are explicit; no unrestricted access. |
| P0 · Native visual behavior | Visual foundations | Native styling and System/Light/Dark respond to contrast, theme and reduced-motion preferences. |
| P0 · Full keyboard access | Keyboard | Every essential workflow is keyboard-operable with discoverable shortcuts and safe destructive defaults. |
| P0 · Assistive technology | Accessibility | Screen reader, large text and non-color equivalents retain all essential information and controls. |
| P0 · Clear empty/loading/error states | Failure states | Distinct empty/loading/error conditions offer recovery without duplicate jobs. |
| P0 · Locale readiness | Localization | Externalized strings, locale formatting, RTL and expanded text preserve layout and unambiguous units. |
| P0 · Privacy in the interface | Privacy | Default UI, notifications, accessibility, diagnostics and app-generated captures exclude sensitive values. |

## Validation and remaining product decisions

Validate the implemented design on packaged Linux builds, including supported desktop environments with and without status-area support, X11/Wayland as applicable, native dialogs/portals, notifications, keyring failure, and startup integration. Check keyboard-only and screen-reader flows, high contrast, large text, RTL, narrow/wide transitions, at least 100 jobs, engine restart/reconnect, duplicate intake, and conflicting external settings changes. Verify every coverage row against its assigned priority before claiming completion.

This document does not choose additional shipped translations, runtime/package/architecture support, a media-site matrix, browser versions, authenticated-header rollout, exact protocol cap/scheduling parity, or the MCP protocol/rotation model. Those remain the shared open decisions in CLIENT.md and the support matrix. They must not silently reduce this UI contract or appear as implemented capabilities.
