# Speed Download Engine IPC — Protocol v1 (Draft)

- **Status:** Draft normative contract; framing, `engine.hello`, per-connection negotiation, base JSON-RPC errors, macOS/Linux Unix transport with same-UID checks, Windows named-pipe source with a user/session DACL, and persistent `jobs.add`/`jobs.list`/`jobs.control`/`jobs.set-bandwidth`/`jobs.reorder`/`jobs.delete` RPCs are implemented. The listener is reachable via `speed-download engine`; `jobs.control` starts, pauses, resumes, retries, and cancels jobs. `jobs.set-bandwidth` changes a saved per-job speed cap while a transfer is active; `jobs.reorder` changes the persisted FIFO position of inactive jobs; `jobs.delete` removes an inactive job record and optionally its partial data, without deleting a completed destination file. Linux GTK and Windows WinUI client source is present. Windows engine cross-compiles for x86_64; Windows runtime and native client validation remain pending. Event subscriptions are not implemented.
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
| Windows | Named Pipe (byte stream) | `\\.\pipe\SpeedDownload-<user-SID>-<session-id>` | Explicit user/SYSTEM DACL and `PIPE_REJECT_REMOTE_CLIENTS`; client connects to this current-user/session endpoint. Server source present; native runtime validation pending. |
| macOS | `AF_UNIX / SOCK_STREAM` | private short runtime path `<private-runtime>/engine.sock` | Check runtime directory ownership/mode; UID via `getpeereid`; keep under `sun_path` limit. |
| Linux | `AF_UNIX / SOCK_STREAM` | `$XDG_RUNTIME_DIR/speed-download/engine.sock` | `0700` directory, `0600` socket where effective, `SO_PEERCRED` UID check. |

Do not open a TCP listener by default. Client apps find the endpoint only via a known trusted per-user path/identifier and may launch the matching installed daemon as that user if necessary. Never trust a socket/pipe merely because a pathname exists. Handle single-instance contention and stale endpoint cleanup safely.

## 2. Versioning and handshake

The first request on each connection **MUST** be `engine.hello`. Until successful negotiation, reject other methods except protocol-format errors. The client announces protocol major/minor, application build, type and features; the engine replies with its supported version and identity. Matching major version is required. Minor features are additive, named, and negotiated.

Example request (`id` correlates only request and response):

```json
{"jsonrpc":"2.0","id":"hello-1","method":"engine.hello","params":{"protocol":{"major":1,"minor":0},"client":{"kind":"macos-gui","version":"0.1.0"},"features":["jobs.subscribe"]}}
```

Example response:

```json
{"jsonrpc":"2.0","id":"hello-1","result":{"protocol":{"major":1,"minor":0},"engine_version":"0.1.0","engine_instance_id":"5ee6f1e7-5ab9-472f-a0a3-55662422c91e","features":["jobs.subscribe"],"session_id":"a89d9a74-94d3-459a-8248-7ea8caa449bc"}}
```

IDs are opaque JSON-RPC string or integral identifiers. `engine_instance_id` changes on every daemon start; `session_id` is one connection session and is not an authentication token. API implementations must not use version strings or client-supplied `kind` as a basis for authorization.

## 3. Common data rules

- **64-bit integers** for file sizes, offsets, job revisions, event sequence numbers and cumulative bytes: base-10 strings such as `"10485760"` to preserve precision through JavaScript and cross-language tooling. Parsers reject negatives, leading `+`, whitespace, and out-of-range numbers unless the schema explicitly allows signed values.
- **Timestamps:** RFC 3339 / ISO-8601 UTC e.g. `"2026-10-12T08:30:00Z"`; use monotonic elapsed times internally in Zig, not wall-clock subtraction for progress.
- **Speeds:** explicit `bytes_per_second` (normally a numeric finite nonnegative estimate; its precision semantics defined in schema) rather than ambiguous `MB/s`.
- **Job IDs:** UUID text; other opaque IDs and idempotency keys are limited-length UTF-8 strings.
- **Input:** validate size, URI scheme, permitted destination and file name, state transitions, fields, enum values, overflow, torrent path traversal, and authentication boundaries. No raw OS pointer, credential handle, shell command, arbitrary file write API, or privileged action is part of v1.
- **Unknown fields:** clients may ignore documented additive response fields; server rejects unexpected security-sensitive input fields. Publish explicit JSON schemas under `ipc-schema/`.

## 4. Initial API surface (proposal)

| Method | Client→server | Response | Security / semantics |
|---|---|---|---|
| `engine.hello` | Version + client capabilities | Negotiated version + engine ID | First method on every connection |
| `engine.status` | `{}` | Engine uptime/capabilities/state | No secrets, never leaks credentials |
| `jobs.list` | Pagination/safe filters | Authoritative job summaries + revision | Bounded page size |
| `jobs.wait` | In-memory change cursor | New cursor + changed flag, within 5 seconds | Bounded long poll; client fetches a fresh `jobs.list` snapshot when changed |
| `jobs.get` | `job_id` | Detailed state/segments | Redacted sensitive URL metadata |
| `jobs.add` | URL, optional name/priority/`expected_sha256`/`bandwidth_limit_bytes_per_second`, destination, `idempotency_key` | Stable `job_id` after persisted enqueue | Priority is an integer from -100 to 100 (default 0); `expected_sha256` is an optional 64-character hexadecimal digest checked before completion; bandwidth zero means no per-job cap; require an absolute existing writable destination directory; validate URL and idempotent retries |
| `jobs.control` | `job_id`, action (`start`, `pause`, `resume`, `cancel`, `retry`), `expected_revision` | Updated job state/revision | Start fills scheduler slots; retry moves a failed job back to the queue; active pause/cancel persists `requested_control` and returns the still-downloading job; worker applies it at its next progress callback; reject stale revisions and per-host cap violations |
| `jobs.set-bandwidth` | `job_id`, `expected_revision`, `bandwidth_limit_bytes_per_second` | Updated revision and limit | Persists a per-job cap and applies it to active workers at their next progress callback; zero removes the per-job cap while the global cap still applies |
| `jobs.reorder` | `job_id`, zero-based `position`, `expected_revision` | Updated position and revision | Only queued, scheduled, paused, or retry-wait jobs; persist order atomically; reject out-of-range position and stale revision |
| `jobs.delete` | `job_id`, `expected_revision`, optional `delete_partial` | Deleted job identifier | Reject active jobs and stale revisions; preserve completed destination files; partial file cleanup is opt-in |
| `jobs.start` / `jobs.pause` / `jobs.resume` / `jobs.retry` | `job_id`, key, optional `expected_revision` | Updated job state/revision | Valid state transitions, idempotent operations |
| `jobs.cancel` | `job_id`, explicit partial-file policy | Final state | Never conflate pause with deleting partial data |
| `jobs.subscribe` | Optional filters, refresh/coalescing hints | `subscription_id`, initial snapshot and cursor | Atomic snapshot-to-event boundary, bounded resources |
| `jobs.unsubscribe` | `subscription_id` | Confirmation | Clean subscriber state |
| `settings.get` | Scopes | Redacted public settings | No credentials in snapshots |
| `settings.update` | Changed fields, key and expected revision | New revision | Validate settings and authorize sensitive changes |
| `schedule.set` | Rule, key, expected revision | Stored rule/revision | Time-zone and DST rules apply |
| `torrents.selectFiles` | Torrent ID/file IDs, key | Updated selection | Validate IDs/paths and prevent traversal |

Final argument/result JSON Schemas must be committed and unit-tested before method implementations are treated as stable. Client-specific visual design is not part of this protocol.

### 4.1 Persisted user settings

`settings.get` returns the complete versioned engine-owned settings document. `settings.update` accepts the complete validated document under `params.settings`; updates are atomically persisted before acknowledgment. Schema version 2 includes `queue_schedule_slots`, a 168-element Sunday-first Boolean array, and `bandwidth_schedule_slots`, a 168-element Sunday-first array of `global_limit | limited`. Index is `day * 24 + hour`; each cell applies to the hour beginning at that hour in the user's current local time zone. `queue_schedule_enabled` and `bandwidth_schedule_enabled` determine whether the respective grid is active. The global and scheduled limited bandwidth values are decimal bytes per second; zero means unlimited. Version 1 documents migrate by retaining shared fields and filling queue cells as active and bandwidth cells as global-limit.

`debug_log_enabled` is a Boolean settings field, default `false`. When enabled, the engine writes redacted action and outcome records to `engine-debug.log` in the same per-user state directory as `settings.json`. The log is capped at approximately 4 MiB and is not created while debug mode is disabled.

For HTTP probes and downloads, a custom `http://` or `https://` proxy endpoint is applied to every request, including range probes and multipart workers. Proxy URLs containing credentials are rejected by settings validation. Unsupported proxy schemes fail closed rather than silently making a direct request. On macOS, `system` mode reads static HTTP and HTTPS proxy servers from `scutil --proxy` and honors simple-host, exact-host, and wildcard-host exceptions for the original request host. The lookup is cached for 30 seconds. PAC, auto-discovery, SOCKS, CIDR exceptions, redirected-host reevaluation, and headless Keychain proxy authentication remain pending; unsupported automatic configurations fail closed.

`jobs.probe` and `jobs.add` also accept anonymous `ftp://` and explicit
`ftps://` file URLs. FTPS requires certificate-validated `AUTH TLS` and
encrypted `PROT P` data. FTP probe
results use `http_version: "FTP"` or `"FTPS"` as the existing protocol display field and
report `range_supported: false` and `multipart_supported: false`. FTP resume
is reported only when the server provides `SIZE`, `MDTM`, and `REST`. The FTP
transfer uses one passive data connection. A configured custom proxy fails
FTP operations; system proxy mode currently leaves FTP and FTPS direct.
Authenticated FTP, implicit FTPS, and FTP proxy transport are not available yet.

The `torrents.magnet-v1-single-file` feature indicates that `jobs.probe` and
`jobs.add` accept v1 `magnet:` links on the Unix engine. The probe returns
`http_version: "BitTorrent"`, `status_code: 0`, an optional safe display name,
and an unknown size until metadata arrives. A queued magnet resolves metadata
from explicit peers, HTTP(S) tracker compact IPv4/IPv6 or dictionary peer lists, or UDP tracker compact IPv4/IPv6 peer lists, then transfers
one file with per-piece SHA-1 verification. `completed_bytes` counts synced,
verified pieces; `received_bytes` may include the current unverified piece.
The daemon rehashes all `.part` pieces before resume. Multi-file torrents,
DHT, and seeding are outside this feature. Custom proxy mode rejects
magnet transfers rather than bypassing the configured proxy.

The Unix engine also advertises `torrents.local-file-v1-single-file`.
The macOS Add Download file picker submits a `torrent-file:///` URL with an
absolute, percent-encoded `.torrent` path. `jobs.probe` reads at most 8 MiB,
validates the metainfo, and returns the root name and total size. For local
`.torrent` sources it also returns `torrent_file_count` and `torrent_files`,
an ordered preview of at most 20 `{path, length}` entries. `length` is a
decimal byte-count string; `path` is relative to the torrent root. A missing
preview means the protocol does not have a local file map at probe time.
The preview is read-only: the current queue worker still downloads all files.
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

Transient connection and truncated-response errors may put a job in `retry_wait`. The summary then includes `retry_attempts` (0–3) and `retry_at_unix_ms` (a decimal millisecond timestamp string, or `null`). These fields are persisted with the job. The scheduler promotes due retries to `queued` before selecting work. Manual pause, cancel, and immediate retry remain available while waiting; integrity and destination errors do not retry automatically.

The engine reevaluates the queue window every five seconds and immediately after settings changes or a new job. Outside an active window, queued jobs become scheduled and active HTTP transfers stop at the next progress callback, retaining their partial data. They resume through the normal queue when the window opens. The global download bandwidth setting is shared across HTTP workers and jobs, with the scheduled limit selected by the current local hour. A job's own cap is applied independently; both caps remain effective. A changed connection default applies when a job starts; resumed segmented transfers run no more than that many workers concurrently.

`jobs.wait` is an interim change signal used by the macOS client while full `jobs.subscribe` notifications are pending. The client sends a decimal-string `cursor`; the engine waits up to five seconds and returns `{ "cursor": "...", "changed": true|false }`. A cursor of `"0"` returns the current cursor immediately. Change detection is in memory and includes live received-byte and worker updates; it does not replace persisted job revisions. The client must reset its cursor after reconnecting to a new engine instance, then fetch authoritative pages with `jobs.list`. Wait checks are coalesced to 200 ms. The 30-second IPC socket timeout bounds a stalled client separately.

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
{"jsonrpc":"2.0","id":"sub-1","method":"jobs.subscribe","params":{"filters":{"states":["downloading","verifying"]},"max_updates_per_second":5}}
```

**Server response:**

```json
{"jsonrpc":"2.0","id":"sub-1","result":{"subscription_id":"sub-41","engine_instance_id":"5ee6f1e7-5ab9-472f-a0a3-55662422c91e","cursor":"1","snapshot":{"jobs":[{"job_id":"83b16cf2-6dba-4c3f-8511-3c365b89a4d0","state":"downloading","bytes_done":"4194304","total_bytes":"10485760","revision":"9"}]}}}
```

**Event notification:**

```json
{"jsonrpc":"2.0","method":"events.changed","params":{"subscription_id":"sub-41","engine_instance_id":"5ee6f1e7-5ab9-472f-a0a3-55662422c91e","seq":"2","changes":[{"job_id":"83b16cf2-6dba-4c3f-8511-3c365b89a4d0","revision":"10","bytes_done":"5242880","bytes_per_second":734003.2}]}}
```

The server must atomically establish the subscription cursor and snapshot. On that connection, serialize the initial response **before** subscription event notifications, then produce contiguous sequence numbers for *emitted* events (sequence count increments after event coalescing, not for every internal progress sample). If a gap, daemon ID change, protocol mismatch, or buffer-overflow resync condition occurs, the client replaces its cache using a new `jobs.subscribe` snapshot. UI rendering should normally be 5–10 Hz or slower for busy lists. Disconnecting a slow subscriber may be preferable to unbounded buffering; never block transfer workers.

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
