# Speed Download Engine IPC — Protocol v1 (Draft)

- **Status:** Draft contract with a substantial implemented subset. See the [engine feature status](../engine-feature-status.md) and the dispatcher in `src/ipc/unix.zig` for the current method set. Native engine/IPC smoke passed on macOS, Linux, Windows Server 2022 x64, and Windows 11 ARM64 in [CI run 40655450597](https://github.com/MJKhaani/SpeedDownload/actions/runs/40655450597). The Windows alpha uses a WPF compatibility client; WinUI 3/Fluent UI remains the client target and has a startup blocker.
- **Date:** 2026-10-12
- **Owner:** Zig engine/API, with Swift/C#/C client contract tests
- **Applies to:** Native GUIs, Zig CLI, and the narrow trusted browser native-host bridge

## 1. Contract overview

The current Zig implementation lives in `src/ipc/`: `frame.zig` encodes and decodes bounded JSON frames, `hello.zig` validates `engine.hello` and builds the negotiated response, `session.zig` enforces per-connection handshake state and dispatches application methods, and `root.zig` composes framed message handling. The shared client-request schema is [`ipc-v1.schema.json`](ipc-v1.schema.json). `unix.zig` provides an AF_UNIX listener for macOS/Linux, validates private runtime-directory ownership/mode, restricts the socket to 0600, checks peer UID, refuses an existing endpoint, handles up to 32 client sessions concurrently, and applies 30-second socket read/write timeouts. `windows.zig` provides a byte-stream named pipe scoped to the current user SID and session, with a private user/SYSTEM DACL, `PIPE_REJECT_REMOTE_CLIENTS`, and first-instance ownership to prevent a second engine from sharing the endpoint. Transfer workers run independently from the listener, with a four-worker global cap and two-worker per-host cap. `core/job_store.zig` persists jobs atomically and exposes list, control, and progress snapshots; mutations are acknowledged only after persistence. The job store rejects URLs with user info or fragments. Query strings are retained in the private job store when present and must be treated as sensitive. The native CI smoke in `tests/integration/ipc_engine.py` exercises handshake, list, reconnect, live progress, transfer, and persistence after engine restart on each OS runner. Successful compilation or configured CI does not demonstrate validated OS behavior until its native job passes.

The engine is an **independent single-instance per-user daemon**. Client processes make duplex requests and subscriptions to it; the engine has the only writable copy of download history, jobs, and transfer workers.

**Protocol:** JSON-RPC 2.0, UTF-8. Top-level application requests/responses/notifications are valid JSON-RPC objects with the required `"jsonrpc":"2.0"`. No batch requests in v1 unless deliberately implemented and tested. Method names beginning with `rpc.` remain reserved per the JSON-RPC specification. The JSON Schema documents request shapes; runtime validation remains authoritative.

**Framing:** a 4-byte **unsigned little-endian** payload length `N` (not including the prefix), followed by `N` bytes of UTF-8 JSON. Receiver reads exactly four bytes, rejects invalid lengths, reads exactly N bytes (allowing partial reads), validates UTF-8 and JSON, then parses the object. Initial maximum `N = 1_048_576` (1 MiB); reject N=0 or N>max. Outbound messages obey the same format. Enforce per-connection budgets, nesting depth, and timeouts for incomplete frames. Named pipes must use byte-stream mode, not assume message boundaries.

**Byte-level example:** A complete message can be constructed as `uint32_le(utf8_byte_count(json_text)) || utf8(json_text)`. The `||` symbol denotes concatenation; it is not a literal character on the wire. Do not use `Content-Length` textual headers or newline-delimited JSON on this internal transport.

**Transport matrix:**

| OS | Local stream | Example endpoint | Identity/permissions |
|---|---|---|---|
| Windows | Named Pipe (byte stream) | `\\.\pipe\SpeedDownload-<user-SID>-<session-id>` | Explicit user/SYSTEM DACL and `PIPE_REJECT_REMOTE_CLIENTS`; native engine/IPC smoke passed on Server 2022 x64 and Windows 11 ARM64 CI. |
| macOS | `AF_UNIX / SOCK_STREAM` | private short runtime path `<private-runtime>/engine.sock` | Check runtime directory ownership/mode; UID via `getpeereid`; keep under `sun_path` limit. |
| Linux | `AF_UNIX / SOCK_STREAM` | `$XDG_RUNTIME_DIR/speed-download/engine.sock` | `0700` directory, `0600` socket where effective, `SO_PEERCRED` UID check. |

Do not open a TCP listener by default. Client apps find the endpoint only via a known trusted per-user path/identifier and may launch the matching installed daemon as that user if necessary. Never trust a socket/pipe merely because a pathname exists. Handle single-instance contention and stale endpoint cleanup safely.

## 2. Versioning and handshake

The first request on each connection **MUST** be `engine.hello`. Until successful negotiation, reject other methods except protocol-format errors. The client announces protocol major/minor, application build, type and features; the engine replies with its supported version and identity. Matching major version is required. Minor features are additive, named, and negotiated.

Example request (`id` correlates only request and response):

```json
{"jsonrpc":"2.0","id":"hello-1","method":"engine.hello","params":{"protocol":{"major":1,"minor":0},"client":{"kind":"macos-gui","version":"0.1.0"},"features":["jobs.change-stream-v1"]}}
```

Example response:

```json
{"jsonrpc":"2.0","id":"hello-1","result":{"protocol":{"major":1,"minor":0},"engine_version":"0.1.0","engine_instance_id":"5ee6f1e7-5ab9-472f-a0a3-55662422c91e","features":["jobs.change-stream-v1"],"session_id":"a89d9a74-94d3-459a-8248-7ea8caa449bc"}}
```

IDs are opaque JSON-RPC string or integral identifiers. `engine_instance_id` changes on every daemon start; `session_id` is one connection session and is not an authentication token. API implementations must not use version strings or client-supplied `kind` as a basis for authorization.

## 3. Common data rules

- **64-bit integers** for file sizes, offsets, job revisions, event sequence numbers and cumulative bytes: base-10 strings such as `"10485760"` to preserve precision through JavaScript and cross-language tooling. Parsers reject negatives, leading `+`, whitespace, and out-of-range numbers unless the schema explicitly allows signed values.
- **Timestamps:** RFC 3339 / ISO-8601 UTC e.g. `"2026-10-12T08:30:00Z"`; use monotonic elapsed times internally in Zig, not wall-clock subtraction for progress.
- **Speeds:** explicit `bytes_per_second` (normally a numeric finite nonnegative estimate; its precision semantics defined in schema) rather than ambiguous `MB/s`.
- **Job IDs:** UUID text; other opaque IDs and idempotency keys are limited-length UTF-8 strings.
- **Input:** validate size, URI scheme, permitted destination and file name, state transitions, fields, enum values, overflow, torrent path traversal, and authentication boundaries. No raw OS pointer, credential handle, or arbitrary file write API is part of v1. The explicit per-queue completion action in validated settings can contain a user command; clients must present that as an OS-affecting action for user review.
- **Unknown fields:** clients may ignore documented additive response fields; server rejects unexpected security-sensitive input fields. Publish explicit JSON schemas under `ipc-schema/`.

## 4. API surface (implemented methods and proposals)

The engine currently dispatches the methods listed in the [implementation inventory](../engine-feature-status.md#ipc-methods-and-cli). Rows below for `jobs.start`, `jobs.pause`, `jobs.resume`, `jobs.retry`, `jobs.cancel`, `schedule.set`, and `torrents.selectFiles` are **proposals**, not separate implemented RPCs. Use `jobs.control`, `settings.update`, and `torrents.prepare`/`jobs.add` for their implemented equivalents.

| Method | Client→server | Response | Security / semantics |
|---|---|---|---|
| `engine.hello` | Version + client capabilities | Negotiated version + engine ID | First method on every connection |
| `engine.status` | `{}` | Engine instance ID, uptime in seconds, and total/active/waiting/paused job counts | No job URLs or credentials; available through `speed-download rpc status` |
| `jobs.list` | Pagination, optional exact `state`, optional text `search` | Authoritative job summaries + revision | Bounded page size; search matches names and query-redacted source URLs, case-insensitively for ASCII text; `total` and `next_offset` count filtered matches |
| `jobs.wait` | In-memory change cursor | New cursor + changed flag, within 5 seconds | Bounded long poll; client fetches a fresh `jobs.list` snapshot when changed |
| `jobs.get` | `job_id` | One job summary with worker progress, using the same fields as `jobs.list` | Redacted URL query/fragment; returns job-not-found for an unknown ID; available through `speed-download rpc get <job-id>` |
| `jobs.probe` | URL | Redirected source, suggested name, size/capabilities or torrent metadata | Engine performs bounded inspection before the client asks to queue |
| `jobs.add` | URL, optional `reference_url`/name/priority/`expected_sha256`/`bandwidth_limit_bytes_per_second`/`selected_torrent_files`, destination, `idempotency_key` | Stable `job_id` after persisted enqueue | Priority is an integer from -100 to 100 (default 0); `expected_sha256` is an optional 64-character hexadecimal digest checked before completion; bandwidth zero means no per-job cap; require an absolute existing writable destination directory; validate URL and idempotent retries |
| `jobs.control` | `job_id`, action (`start`, `pause`, `resume`, `cancel`, `retry`), `expected_revision` | Updated job state/revision | Start fills scheduler slots; retry moves a failed job back to the queue; active pause/cancel persists `requested_control` and returns the still-downloading job; worker applies it at its next progress callback; reject stale revisions and per-host cap violations |
| `jobs.set-bandwidth` | `job_id`, `expected_revision`, `bandwidth_limit_bytes_per_second` | Updated revision and limit | Persists a per-job cap and applies it to active workers at their next progress callback; zero removes the per-job cap while the global cap still applies |
| `jobs.reorder` | `job_id`, zero-based `position`, `expected_revision` | Updated position and revision | Only queued, scheduled, paused, or retry-wait jobs; persist order atomically; reject out-of-range position and stale revision |
| `jobs.move-queue` | `job_id`, destination queue ID, expected revision | Updated job and queue membership | Queue must exist; preserve partial transfer data |
| `jobs.resume-queue` | `{}` | Eligible paused jobs resumed | Applies to the current queue of eligible jobs; engine still enforces schedules and caps |
| `jobs.replace-source` | `job_id`, `url`, `expected_revision`, `restart: true` | Updated source/revision | Explicitly discards incompatible partial progress; does not infer identity from a matching filename |
| `jobs.delete` | `job_id`, `expected_revision`, optional `delete_partial` | Deleted job identifier | Reject active jobs and stale revisions; preserve completed destination files; partial file cleanup is opt-in |
| `jobs.start` / `jobs.pause` / `jobs.resume` / `jobs.retry` | `job_id`, key, optional `expected_revision` | Updated job state/revision | Valid state transitions, idempotent operations |
| `jobs.cancel` | `job_id`, explicit partial-file policy | Final state | Never conflate pause with deleting partial data |
| `jobs.subscribe` | Optional `max_updates_per_second` (1–10), exact `state`, text `search` | `subscription_id`, first 20 matching job summaries, filtered total, next offset, and cursor | Dedicated connection; atomic filtered first page and cursor; bounded change notices |
| `jobs.unsubscribe` | `subscription_id` | Confirmation | Must be sent on the same connection; closing it also unsubscribes |
| `torrents.prepare` | Torrent or magnet URL, optional trackers and pagination | Pinned info hash, file list, trackers, source metadata | Preparation only; does not queue a payload |
| `settings.get` | `{}` | Complete versioned settings document | Credentials are never stored in settings |
| `settings.update` | Complete settings document under `params.settings` | Persisted settings | Validated and atomically saved before acknowledgment |
| `schedule.set` | Rule, key, expected revision | Stored rule/revision | Time-zone and DST rules apply |
| `torrents.selectFiles` | Torrent ID/file IDs, key | Updated selection | Validate IDs/paths and prevent traversal |

Final argument/result JSON Schemas must be committed and unit-tested before method implementations are treated as stable. Client-specific visual design is not part of this protocol.

### 4.1 Persisted user settings

`settings.get` returns the complete versioned engine-owned settings document. `settings.update` accepts the complete validated document under `params.settings`; updates are atomically persisted before acknowledgment. Schema version 3 adds `queues`, each with a stable ID, unique name, `max_active`, `schedule_enabled`, 168 Boolean `schedule_slots`, and `finish_action` (`none`, `quit_app`, `power_off`, or `custom_app`); current settings also have optional `user_command`. The `main` queue is required. Jobs carry `queue_id`; `jobs.move-queue` changes it using the job ID and expected revision. Settings also carry `browser_grab_extensions`, `stop_seeding_after_minutes`, and `language`. The seeding time setting is inert until seeding is implemented. Older settings migrate their global queue schedule and concurrency limit to `main`; older jobs join `main`.

`bandwidth_schedule_slots` remains a 168-element Sunday-first array of `global_limit | limited`. Index is `day * 24 + hour`; each cell applies to the hour beginning at that hour in the user's current local time zone. `bandwidth_schedule_enabled` controls that grid. Bandwidth values are decimal bytes per second; zero means unlimited.

`debug_log_enabled` is a Boolean settings field, default `false`. When enabled, the engine writes redacted action and outcome records to `engine-debug.log` in the same per-user state directory as `settings.json`. The log is capped at approximately 4 MiB and is not created while debug mode is disabled.
The settings file uses schema version 3. Startup upgrades older supported versions atomically
after validating its fields. A newer or otherwise unknown version stops engine
startup with `UnsupportedSettingsVersion`, preserving the file for a compatible
engine instead of silently interpreting it as version 3.

For HTTP probes and downloads, a custom `http://` or `https://` proxy endpoint is applied to every request, including range probes and multipart workers. Proxy URLs containing credentials are rejected by settings validation. `proxy_authentication_required` records the user's requirement without storing a password in settings or IPC snapshots. On macOS, custom HTTP proxy credentials can be read from Keychain; authenticated HTTPS CONNECT remains unsupported. Unsupported proxy schemes fail closed rather than silently making a direct request. On macOS, `system` mode reads static HTTP and HTTPS proxy servers from `scutil --proxy` and honors simple-host, exact-host, wildcard-host, and numeric IP network exceptions for each request destination, including redirect hops. The lookup is cached for 30 seconds. PAC, auto-discovery, and SOCKS transport remain pending; unsupported automatic configurations fail closed.

`jobs.probe` and `jobs.add` also accept anonymous `ftp://` and explicit
`ftps://` file URLs. FTPS requires certificate-validated `AUTH TLS` and
encrypted `PROT P` data. FTP probe
results use `http_version: "FTP"` or `"FTPS"` as the existing protocol display field and
report `range_supported: false` and `multipart_supported: false`. FTP resume
is reported only when the server provides `SIZE`, `MDTM`, and `REST`. The FTP
transfer uses one passive data connection. A configured custom proxy fails
FTP operations; system proxy mode currently leaves FTP and FTPS direct.
Authenticated FTP and FTP proxy transport are not available yet. `ftps://` uses explicit TLS by default; port 990 selects implicit TLS before the server greeting.

The `torrents.magnet-v1-single-file` feature indicates that `jobs.probe` and
`jobs.add` accept v1 `magnet:` links on the Unix engine. The probe returns
`http_version: "BitTorrent"`, `status_code: 0`, an optional safe display name,
and an unknown size until metadata arrives. A queued magnet resolves metadata
from explicit peers, HTTP(S) tracker compact IPv4/IPv6 or dictionary peer lists, or UDP tracker compact IPv4/IPv6 peer lists, then transfers
one file with per-piece SHA-1 verification. `completed_bytes` counts synced,
verified pieces; `received_bytes` may include the current unverified piece.
The daemon rehashes all `.part` pieces before resume. Multi-file v1 transfers and bounded read-only DHT metadata/payload discovery are implemented separately from this original single-file feature name; seeding remains unavailable. After verified metainfo arrives, public torrents may use a bounded read-only DHT lookup for payload peers. Custom proxy mode rejects
magnet transfers rather than bypassing the configured proxy.

The Unix engine also advertises `torrents.local-file-v1-single-file`.
The macOS Add Download file picker submits a `torrent-file:///` URL with an
absolute, percent-encoded `.torrent` path. `jobs.probe` reads at most 8 MiB,
validates the metainfo, and returns the root name and total size. For local
`.torrent` sources it also returns `torrent_file_count` and `torrent_files`,
an ordered preview of at most 1,000 `{path, length}` entries, further bounded
to a conservative 128 KiB escaped-response budget. `length` is a
decimal byte-count string; `path` is relative to the torrent root. A missing
preview means the protocol does not have a local file map at probe time.
The probe also returns `torrent_info_hash` as 40 lowercase hexadecimal
characters. The Add dialog returns it with `jobs.add`; the engine compares it
with the metainfo it actually saves in its private snapshot and rejects a
changed source, so a preview cannot silently apply to a different torrent.
For multi-file local torrents, `jobs.add` accepts `selected_torrent_files` as
a nonempty array of distinct relative paths returned by the probe. The
`torrents.file-selection-v1` handshake feature must be present before a client
sends it. A selective add requires `torrent_info_hash`; omission of
`selected_torrent_files` includes all files. Selection is persisted with the job;
the worker verifies only pieces overlapping selected files and publishes only
those files. A boundary piece may contain bytes from an unselected file and
is still needed for SHA-1 verification. Progress measures all required piece
bytes, including such boundary bytes. Whole-download `expected_sha256` is not
accepted with a subset. The macOS Add dialog offers selection when the
preview contains the complete file map; torrents that exceed the bounded
preview currently include all files through that dialog.
`jobs.add`
requires a safe output name and validates the selected torrent again. The
engine stores the local source URL privately, redacts its path from job
summaries, and saves a private metainfo snapshot before acknowledging the job.
The original file can then be moved or removed. Jobs added before snapshots
were introduced still require their original source file for resume. On
startup, the engine removes snapshot files that no longer have a matching
local torrent job; a cleanup error leaves the file in place and does not
prevent the engine from starting. This URL type is
for trusted local clients and must not be accepted by browser handoff bridges.

`jobs.list` keeps `completed_bytes` as the durable resume checkpoint. While a transfer is active, it also exposes `received_bytes` for live UI progress and may expose a `total_bytes` learned from response headers before a durable checkpoint exists. These live fields are not persisted as completed data. The `workers` array includes a single connection for sequential HTTP transfers when the total size is known; its progress is also live and clears when the transfer stops. Clients should label received bytes as transfer progress rather than verified or resumable bytes.

For active torrent jobs, `jobs.list` may expose ephemeral `torrent_peer_count`,
`torrent_seeder_count`, and `torrent_leecher_count` integers. Peer count is
the deduplicated discovered address list, capped at 80; seed and leecher
counts come from the most recent tracker that supplied them. Null means
unknown. These values are not persisted and do not claim active connections
or an accurate global swarm census.

Transient connection and truncated-response errors may put a job in `retry_wait`. The summary then includes `retry_attempts` (0–3) and `retry_at_unix_ms` (a decimal millisecond timestamp string, or `null`). These fields are persisted with the job. The scheduler promotes due retries to `queued` before selecting work. Manual pause, cancel, and immediate retry remain available while waiting; integrity and destination errors do not retry automatically.

The engine reevaluates the queue window every five seconds and immediately after settings changes or a new job. Outside an active window, queued jobs become scheduled and active HTTP transfers stop at the next progress callback, retaining their partial data. They resume through the normal queue when the window opens. The global download bandwidth setting is shared across HTTP workers and jobs, with the scheduled limit selected by the current local hour. A job's own cap is applied independently; both caps remain effective. A changed connection default applies when a job starts; resumed segmented transfers run no more than that many workers concurrently.

`jobs.wait` remains an interim change signal used by the macOS client. The client sends a decimal-string `cursor`; the engine waits up to five seconds and returns `{ "cursor": "...", "changed": true|false }`. A cursor of `"0"` returns the current cursor immediately. Change detection is in memory and includes live received-byte and worker updates; it does not replace persisted job revisions. The client must reset its cursor after reconnecting to a new engine instance, then fetch authoritative pages with `jobs.list`. Wait checks are coalesced to 200 ms. The 30-second IPC socket timeout bounds a stalled client separately.

## 5. Example: idempotent download creation

```json
{"jsonrpc":"2.0","id":"add-193","method":"jobs.add","params":{"url":"https://example.org/releases/archive.zip","destination":"/home/alice/Downloads","idempotency_key":"84f21a5e-0db3-4d39-a0d9-a530403540d8"}}
```

```json
{"jsonrpc":"2.0","id":"add-193","result":{"job_id":"83b16cf2-6dba-4c3f-8511-3c365b89a4d0","state":"queued","revision":"1"}}
```

The server persists the job and deduplication key before returning success. Replaying the same key and identical parameters after a network/IPC failure returns the same logical outcome rather than adding a second job; reusing a key with different parameters is an error. Duplicate suppression must survive engine restart for the specified retention window. JSON-RPC `id` itself is only for response matching.

## 6. Example: subscriptions and event delivery

**Subscription request:**

```json
{"jsonrpc":"2.0","id":"sub-1","method":"jobs.subscribe","params":{"max_updates_per_second":5}}
```

**Server response:**

```json
{"jsonrpc":"2.0","id":"sub-1","result":{"subscription_id":"sub-41","engine_instance_id":"5ee6f1e7-5ab9-472f-a0a3-55662422c91e","cursor":"1","interval_ms":200,"snapshot":{"jobs":[],"total":"0","next_offset":null}}}
```

**Event notification:**

```json
{"jsonrpc":"2.0","method":"events.changed","params":{"subscription_id":"sub-41","engine_instance_id":"5ee6f1e7-5ab9-472f-a0a3-55662422c91e","seq":"1","cursor":"2","resync_required":true,"jobs":[]}}
```

The engine atomically captures the first 20 matching job summaries and cursor. `state` and `search` use the same matching rules as `jobs.list`; clients fetch additional filtered pages with `jobs.list` on a separate connection. The subscription connection sends notices at no more than the requested rate. Each notice has a contiguous emitted-event sequence and latest cursor. For bounded live progress changes, `resync_required` is `false` and `jobs` contains the current matching summaries of changed jobs; clients may apply these by `job_id`. Durable changes, a missed history window, or more than 20 changed jobs set `resync_required` to `true` and send an empty `jobs` array; clients must fetch authoritative filtered pages then. Clients should also fetch pages after reconnecting. Send `jobs.unsubscribe` on the same connection or close it to unsubscribe. The transport has a bounded write timeout and disconnects a slow subscriber; transfer workers never write to clients.

## 7. Errors

Use the standard JSON-RPC `error` object with `code`, short `message` (safe for display), and bounded structured `data`. Do not expose secrets, raw headers, private paths or internal exception dumps.

```json
{"jsonrpc":"2.0","id":"pause-4","error":{"code":-32010,"message":"Job state conflict","data":{"kind":"state_conflict","job_id":"83b16cf2-6dba-4c3f-8511-3c365b89a4d0","current_revision":"10"}}}
```

The initial session implementation uses standard `-32700` for parse errors, `-32600` for invalid requests, and `-32601` for methods not yet registered. It uses provisional application errors `-32001` for a missing handshake and `-32002` for an unsupported protocol major. These application codes require final registry review before v1 release.

Future error classes include permission denied; validation/invalid URI; not found; revision/state conflict; duplicate key with different arguments; unavailable engine/dependency; too many requests; resync required; and temporary storage failure. Standard JSON-RPC parse/method/params error codes remain reserved. Publish stable application error codes before v1 release.

## 8. Security and browser boundary

- Per-user pipe/socket access control is **mandatory**, not a substitute for input validation. Same-user malware remains a threat outside the guarantees of OS peer-ID mechanisms.
- The engine is non-elevated and rejects attempts to access non-owned state or privileged OS operations. Fail closed if endpoint ownership or peer credentials cannot be checked.
- The browser **native messaging host** is a separate transport adapter and **never forwards arbitrary RPC methods** from extensions/web pages. It admits only carefully validated, user-approved operations such as `jobs.add`. Browser native messaging has its own 4-byte length framing and permissions but is not interchangeable with the engine's trust model.
- Avoid forwarding site cookies/Authorization headers. If later needed, use a dedicated consent-bound ephemeral design with explicit origin limits.
- Use secure fixed install paths; minimize the lifetime and permissions of IPC-related files. Do not publish TCP/HTTP endpoints, debug ports or custom URL schemes with unrestricted actions.

## 9. Lifecycle/compatibility

A GUI connects to the secure endpoint; if unavailable, starts the **trusted installed** daemon without elevation and retries with bounded backoff. GUI closure and crashes do not interrupt active downloads. A daemon instance accepts multiple clients. GUI reconnect must repeat `engine.hello`, resubscribe and refresh snapshot. Major protocol changes require a controlled migration or a supported compatibility adapter, not silent guessing.

An explicit stop/shutdown operation (to be defined) must honor running jobs, flush checkpoints and return a predictable outcome. GUI launch/engine startup and upgrades differ across MSIX, installer-based Windows deployment, signed macOS app bundles, and Linux distro/Flatpak packaging; all are release gates, not assumptions.

## 10. Conformance tests

- Golden byte-frame decoding in Zig, Swift, C#, C, TypeScript; verify endianness, partial reads, UTF-8, a zero/oversized frame and multiple consecutive frames.
- JSON-RPC handshake acceptance/rejection, matching IDs, no reply to notifications, concurrent requests and structured errors.
- Full parsing fuzz, nesting limits, integer-string overflow and malformed command rejection.
- IPC ACL/peer-credential tests, endpoint squatting and stale-socket protection, concurrent startup, no remote Windows named-pipe access.
- Atomic snapshot/subscribe ordering, sequence gaps and restart resync; slow client throttling and bounded queues.
- Persisted idempotency keys and revision conflicts across disconnects and daemon restarts.
- GUI crash/reconnect; CLI and GUI simultaneous control; engine progress with no GUI attached.
- Browser bridge method allowlist and permission tests with forged origins and hostile inputs.
- Native packaging: launch and connect to the bundled engine on each OS/architecture advertised.

## 11. References

- [JSON-RPC 2.0](https://www.jsonrpc.org/specification)
- [Named Pipe security](https://learn.microsoft.com/en-us/windows/win32/ipc/named-pipe-security-and-access-rights)
- [Linux Unix sockets and SO_PEERCRED](https://man7.org/linux/man-pages/man7/unix.7.html)
- [macOS getpeereid](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/getpeereid.3.html)
- [PROJECT.md](../../PROJECT.md)

### Torrent review preparation

`torrents.prepare` (feature `torrents.prepare-v1`) accepts `url`, optional `trackers`
(up to 32 HTTP(S)/UDP URLs), and optional nonnegative `offset`. It retrieves and
verifies magnet metadata, reads a local `torrent-file:` source, or fetches bounded
HTTP(S) metainfo using the engine proxy policy. It never queues a payload.
The probe-shaped response includes an engine-owned `final_url`, pinned
`torrent_info_hash`, `torrent_file_count`, `torrent_files`, `torrent_trackers`,
`torrent_private`, and optional `torrent_next_offset`. Request subsequent pages
using the returned source and offset. Submit that source to `jobs.add` with the
pinned hash and optional `selected_torrent_files` only after user confirmation.
Tracker edits produce a separate prepared source and never change the info hash.

## Browser reference pages and replacement links

The Unix engine advertises `jobs.reference-page-v1`, `jobs.source-refresh-v1`, and `jobs.queue-resume-v1`.
`jobs.add` accepts an optional `reference_url`: an HTTP(S) page of at most 8192
UTF-8 bytes, without credentials, control characters, or a fragment. It is stored
in the private job record and returned to the local client as `reference_url`.
It is not logged or sent as an HTTP Referer header. Reference pages can contain
query parameters, so clients must treat them as private data.

`jobs.replace-source` takes `job_id`, decimal-string `expected_revision`, a new
HTTP(S) `url`, and explicit `restart: true` confirmation. Only inactive HTTP(S)
jobs can be replaced. The engine removes the old partial files, clears progress
and retry state, preserves the destination/name/checksum/priority/reference page,
persists the replacement, and queues it under normal scheduling rules. The reply
contains `job_id` and `state`. A stale revision or active job is rejected.
This operation restarts the payload; it does not treat two different URLs as
proof of the same representation. In particular, matching file names or sizes
alone cannot authorize reuse of partial bytes.

The engine acquires an exclusive, nonblocking profile file lock before loading
or recovering persisted state. The lock remains held for the store's lifetime;
OS process exit releases it without deleting the lock file.

`jobs.resume-queue` takes empty params and returns `{ "resumed": <count> }`.
It atomically moves paused and retry-wait jobs to queued state, preserving their
partial progress, and wakes normal scheduling. It neither retries failed jobs
nor bypasses global concurrency, host limits, or queue schedules. Existing queued
jobs are also considered by that scheduler wakeup.

### Connected torrent peers

Job snapshots expose `torrent_active_peer_count` for active TCP peer or web
seed connections and optional `torrent_active_peer` (address and port) when
exactly one source is connected. These fields are transient, copied under the
job-store lock, cleared on disconnect, and never written to persistent job
state or debug logs. Up to four TCP peers can transfer distinct pieces at once.
Neither field is a seeder count: a connected peer may hold only some pieces.
Tracker swarm counts remain separate from actual connections. Verified pieces
may be uploaded during an active TCP download, but upload counts, rates and
ratios are not reported yet. Incoming peers and post-completion seeding are
not implemented.
