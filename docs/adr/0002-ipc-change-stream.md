# ADR 0002: Bounded job change streams

## Context

`jobs.wait` provides a bounded change wait but makes each client issue another
request after every response. The engine needs server-pushed progress without
letting a slow client block a transfer worker or build an unbounded event queue.

## Decision

`jobs.subscribe` uses a dedicated authenticated IPC connection. Its response
contains an atomic first page of job summaries and a change cursor. Further
`events.changed` notifications are coalesced to at most five per second by
default. Each notification contains a contiguous emitted-event sequence and
the latest change cursor; clients fetch an authoritative snapshot on notice.
The first page is capped at 20 jobs to stay under the IPC frame limit; the
client fetches further pages through `jobs.list` on another connection.

The transport writes notices from its existing per-client thread, with a
bounded socket or pipe write timeout. No transfer worker writes to a client.
One connection has at most one subscription. Closing it or sending
`jobs.unsubscribe` with its subscription ID unsubscribes.

## Limits

This first stream sends invalidation notices rather than per-job deltas. The
cursor is local to one engine instance and clients must re-snapshot after a
reconnect. Native runtime and slow-subscriber behavior still need validation.
