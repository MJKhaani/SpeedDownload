# HTTP multipart range allocation

This document describes the bounded HTTP range path in the engine. Eligible
HTTP(S) downloads now probe with `Range: bytes=0-0`, then issue up to the
configured number of concurrent segment requests when the server proves range support and returns a
strong ETag. Other downloads use the existing single-stream path. Work is only
split when each new extent can retain at least 4 MiB. The segment journal
is not used when parallel downloading is Off; Automatic uses the
configured connection ceiling and can lower it after a server rate limit,
while Fixed keeps the configured count for each attempt. Single-stream
downloads can still resume when the response has a known length and strong ETag.
The single-stream `ODMHJ003` journal includes a SHA-256 checksum over its
metadata. The engine rejects damaged journals before trusting their durable
offset. Earlier `ODMHJ002` partials remain on disk but cannot be resumed
safely; remove the partial and re-add the job to download it again. The
checksum detects accidental metadata damage, while the strong ETag and
range response checks protect the remote representation identity.
For multipart transfers, the segment journal is atomically replaced after each
4 MiB of a worker's synced data, at
segment completion, and when a worker stops. A crash may redownload only the
bytes after that worker's last durable checkpoint.

The Add Download preflight uses one small GET with the same range header. It
derives the suggested name, final redirected URL, size, and range capability
from that response. If the server ignores the range and sends a full response,
the preflight closes its connection after the headers instead of reading the
file body.
HTTP probes and transfers follow at most three redirects with proxy policy
reapplied for each destination. Redirects to non-HTTP schemes, URLs containing
credentials, and HTTPS-to-HTTP downgrades are rejected before contacting the
redirected address. URL fragments are discarded. This also applies to
multipart workers.

## Interval invariants

The planner stores all offsets as checked 64-bit half-open intervals
`[start, end)`. The HTTP wire format uses inclusive ends, so `[0, 500)` becomes
`Range: bytes=0-499`. Empty intervals and ranges extending beyond the known
representation length are rejected. Adjacent intervals are valid; overlapping
intervals are not.

An `ExtentMap` starts with one worker owning `[0, total)`. As more workers become
available, `splitLargest` selects the active segment with the largest remaining
tail and divides only its not-yet-durable bytes. The current worker retains the
head and the new worker receives the adjacent tail. Neither piece may be smaller
than the configured minimum. The map caps ownership at 64 segments.

For example, with `[0, 4096)` and a 512-byte minimum, a worker that has durably
reached offset 1024 can split the remaining `[1024, 4096)` into `[1024, 2560)`
and `[2560, 4096)`. The original worker keeps its existing id and the new worker
gets the tail id; no already-completed bytes are reassigned.

Each worker advances a durable cursor monotonically inside its assigned
interval. Aggregate completed bytes are the sum of durable prefixes. The
versioned codec in `src/protocols/http/segment_journal.zig` records
representation identity, interval ownership, and cursors, and rejects gaps,
overlaps, invalid validators, and malformed state. `SDRANGE2` adds a SHA-256
checksum over the journal metadata, so damaged cursors cannot be trusted on
restart. Older `SDRANGE1` partials remain on disk but cannot resume safely;
remove the partial and add the download again. This checksum detects accidental
metadata damage; it does not authenticate a malicious local edit. The driver syncs the part
file before advancing a segment cursor and atomically replaces the journal.
Checkpoints occur during segments and at pause, schedule stop, or transfer
error when the worker can sync its buffered data. If a server changes the
representation or returns an invalid range after a partial exists, the engine
preserves the partial and reports the error instead of silently restarting a
single-stream download. A partial file whose length no longer matches the
journal is also preserved and rejected; the user can remove it and start a
fresh download. The engine checks the file length before replacing the journal.
The worker count follows the per-task setting (up to
32). Before requests start, the engine partitions at most twice as many
pending segments as concurrent workers, bounded by 64 segments and the 4 MiB
minimum piece size. An idle worker claims the next pending segment without
waiting for the other workers. A failed worker stops new claims; other workers
retain durably synced prefixes before the transfer exits. When every preplanned
segment is claimed and a worker becomes idle, an active worker can divide its
remaining range at a durable checkpoint. The original request is closed after
its shortened head is synced; the idle worker requests only the new tail.
If an HTTP range probe or worker receives 429 or 503, the engine saves a
retry delay and halves that job's next-attempt connection cap, down to one.
Automatic retries apply 75–125% jitter to their short exponential backoff so
jobs failing together do not reconnect at the same instant. A valid
`Retry-After` delay remains a minimum, capped at one hour; jitter never
shortens that server-requested wait.
If a worker receives 403 after the range probe succeeded, Automatic mode also
uses a bounded retry with fewer connections. Fixed mode retains the configured
count.
The cap is persisted with the job so an engine restart cannot restore the
aggressive count during the wait. A manual retry after terminal failure
restores the configured default connection count.

## Required integration policy

Before issuing parallel requests, the HTTP driver must prove range support with
an actual `206 Partial Content` response whose `Content-Range` start, end, and
total match the requested probe. It must pin a stable representation using a
strong ETag or another explicitly supported validator, send
`Accept-Encoding: identity`, and reject encoded or mismatched bodies. The
`Accept-Ranges` header alone is not proof. Unsupported or ambiguous responses
must use the existing safe single-stream path.

Each segment response must be independently checked for status, exact content
range, total, validator, content encoding, and body length before its bytes are
accepted. Two workers must never own the same writable byte. A journal must
only advance a segment cursor after the corresponding file bytes are synced;
recovery must discard any range whose ownership or representation cannot be
validated.

An invalid or interrupted segment response closes its connection without
draining the body. This matters when a server ignores a range and sends a full
`200 OK` response: cleanup must return promptly instead of reading the entire
unwanted file.

## Adversarial validation matrix

The completed implementation needs automated coverage for no range support,
lying `Accept-Ranges`, ignored ranges returning 200, wrong 206 offsets and
totals, 416, strong and weak ETags, representation changes, unknown length,
compressed responses, redirect changes, short bodies, disconnects, concurrent
pause/cancel, journal corruption, out-of-space, abrupt termination, and offsets
above 2^32. These cases are recorded here as requirements; this work has not
run the test suite.
