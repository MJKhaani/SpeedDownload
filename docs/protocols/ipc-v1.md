# Speed Download Engine IPC — Protocol v1 (Draft)

- **Status:** Draft normative contract; frame decoding, the `engine.hello` handshake, per-connection negotiation state, and base JSON-RPC errors are implemented, while OS transports and application method dispatch remain pending
- **Date:** 2026-10-12
- **Owner:** Zig engine/API, with Swift/C#/C client contract tests
- **Applies to:** Native GUIs, Zig CLI, and the narrow trusted browser native-host bridge

## 1. Contract overview

The current Zig implementation lives in `src/ipc/`: `frame.zig` encodes and decodes bounded JSON frames, `hello.zig` validates `engine.hello` and builds the negotiated response, `session.zig` enforces the per-connection handshake requirement and standard pre-dispatch errors, and `root.zig` composes them into framed message handling. These primitives do not open sockets or named pipes, authenticate peers, or implement application methods. The repository exposes `zig build ipc` for compiling this module.

The engine is an **independent single-instance per-user daemon**. Client processes make duplex requests and subscriptions to it; the engine has the only writable copy of download history, jobs, and transfer workers.

**Protocol:** JSON-RPC 2.0, UTF-8. Top-level application requests/responses/notifications are valid JSON-RPC objects with the required `"jsonrpc":"2.0"`. No batch requests in v1 unless deliberately implemented and tested. Method names beginning with `rpc.` remain reserved per the JSON-RPC specification.

**Framing:** a 4-byte **unsigned little-endian** payload length `N` (not including the prefix), followed by `N` bytes of UTF-8 JSON. Receiver reads exactly four bytes, rejects invalid lengths, reads exactly N bytes (allowing partial reads), validates UTF-8 and JSON, then parses the object. Initial maximum `N = 1_048_576` (1 MiB); reject N=0 or N>max. Outbound messages obey the same format. Enforce per-connection budgets, nesting depth, and timeouts for incomplete frames. Named pipes must use byte-stream mode, not assume message boundaries.

**Byte-level example:** A complete message can be constructed as `uint32_le(utf8_byte_count(json_text)) || utf8(json_text)`. The `||` symbol denotes concatenation; it is not a literal character on the wire. Do not use `Content-Length` textual headers or newline-delimited JSON on this internal transport.

**Transport matrix:**

| OS | Local stream | Example endpoint | Identity/permissions |
|---|---|---|---|
| Windows | Named Pipe (`PIPE_TYPE_BYTE` / `PIPE_READMODE_BYTE`) | `\\.\pipe\SpeedDownload-<private-user-scope>` | Explicit private DACL, no Everyone/anonymous, `PIPE_REJECT_REMOTE_CLIENTS`, user/session scope and no untrusted pre-creation. |
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
| `jobs.get` | `job_id` | Detailed state/segments | Redacted sensitive URL metadata |
| `jobs.add` | URL, optional name/destination, `idempotency_key` | Stable `job_id` after persisted enqueue | Validate URL, approved destination and idempotent retries |
| `jobs.start` / `jobs.pause` / `jobs.resume` / `jobs.retry` | `job_id`, key, optional `expected_revision` | Updated job state/revision | Valid state transitions, idempotent operations |
| `jobs.cancel` | `job_id`, explicit partial-file policy | Final state | Never conflate pause with deleting partial data |
| `jobs.subscribe` | Optional filters, refresh/coalescing hints | `subscription_id`, initial snapshot and cursor | Atomic snapshot-to-event boundary, bounded resources |
| `jobs.unsubscribe` | `subscription_id` | Confirmation | Clean subscriber state |
| `settings.get` | Scopes | Redacted public settings | No credentials in snapshots |
| `settings.update` | Changed fields, key and expected revision | New revision | Validate settings and authorize sensitive changes |
| `schedule.set` | Rule, key, expected revision | Stored rule/revision | Time-zone and DST rules apply |
| `torrents.selectFiles` | Torrent ID/file IDs, key | Updated selection | Validate IDs/paths and prevent traversal |

Final argument/result JSON Schemas must be committed and unit-tested before method implementations are treated as stable. Client-specific visual design is not part of this protocol.

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
