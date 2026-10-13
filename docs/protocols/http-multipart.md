# HTTP multipart range allocation

This document describes the bounded HTTP range path in the engine. Eligible
HTTP(S) downloads now probe with `Range: bytes=0-0`, then issue up to four
concurrent segment requests when the server proves range support and returns a
strong ETag. Other downloads use the existing single-stream path. Work is only
split when each new extent can retain at least 4 MiB. The segment
journal is atomically replaced after a whole extent has been synced; a crash
mid-extent causes that extent to be fetched again.

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
overlaps, invalid validators, and malformed state. The driver syncs the part
file before advancing a segment cursor and atomically replaces the journal.
Checkpoints currently occur at segment completion, so in-flight segment bytes
are safely redownloaded after interruption. The worker count is fixed at four
or fewer for each transfer; splitting is performed before requests start, and
dynamic work stealing or subdivision during a transfer remains future work.

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

## Adversarial validation matrix

The completed implementation needs automated coverage for no range support,
lying `Accept-Ranges`, ignored ranges returning 200, wrong 206 offsets and
totals, 416, strong and weak ETags, representation changes, unknown length,
compressed responses, redirect changes, short bodies, disconnects, concurrent
pause/cancel, journal corruption, out-of-space, abrupt termination, and offsets
above 2^32. These cases are recorded here as requirements; this work has not
run the test suite.
