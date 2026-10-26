# BitTorrent status

The engine can inspect a local BitTorrent v1 `.torrent` file with
`speed-download torrent-info <file.torrent>`. The command prints its name,
tracker, total bytes, validated relative file paths with lengths and byte
offsets, file and piece counts, piece length, and SHA-1 info
hash plus the private flag as JSON. It does not add a transfer, contact a tracker or peer, or write
downloaded files.

For a v1 torrent, the CLI can transfer its payload with
`speed-download torrent-download <file.torrent> <destination>`. A multi-file
destination is a directory named by the caller. It uses
the same SHA-1 piece verification, out-of-order placement, restart rehashing,
and no-replace publication as `magnet-download`. It reads the `.torrent` from
the local filesystem. On macOS, Add Download can choose a `.torrent` file
and submit it through the engine queue for normal progress and resume. The
engine copies metainfo into its private job state before accepting the job,
so the selected file can subsequently be moved or removed. Older queued
jobs created before this behavior still need the original file for resume.
The engine removes unreferenced snapshot files during startup and after a
job is deleted.
The parser accepts up to 32 distinct usable tracker URLs and ignores the
primary `announce` when an `announce-list` is present, following
[BEP 12](https://www.bittorrent.org/beps/bep_0012.html). It visits tiers in
file order and shuffles usable URLs within each tier on each transfer attempt.
Tier boundaries remain available to the tracker session; a tracker that
responds successfully is tried first within its original tier on the next
announce in that transfer attempt. Multi-file downloads assemble the verified flat piece spool into
a private staging directory, then publish the complete tree without replacing
an existing destination. A piece that crosses file boundaries is copied into
both files only after its SHA-1 hash is verified. A stale staging directory is
removed on retry only when its ownership marker matches the torrent info hash.
The publisher creates each parent directory explicitly and rejects a name that
the filesystem reports as already present under a different spelling. File
creation is exclusive, so case or Unicode normalization collisions fail before
the staged tree is published. Inspection rejects a file layout where one file
path is also a parent directory of another.
During assembly, the engine checks queue schedule, pause, and cancel requests
after 8 MiB of copied data or 128 files, and again before publication. If interrupted,
it discards the private staging tree; the verified flat spool remains available
for pause or scheduled resume, and cancel removes it through the queue worker.

The engine also inspects BitTorrent v1 magnet URIs with
`speed-download magnet-info 'magnet:?xt=urn:btih:…&dn=…&tr=…&x.pe=host:port'`.
It decodes 40-character hexadecimal or 32-character Base32 info hashes,
the optional display name, up to 32 HTTP, HTTPS, or UDP tracker URLs, and up
to 16 explicit peer addresses.
Output is JSON with `status: "metadata_required"`. URI length, parameter
count, decoded values, and percent escapes are bounded and checked.
Magnet tracker URLs reject embedded credentials and fragments. Duplicate
tracker URLs are ignored while preserving their first occurrence.

For a magnet with an `x.pe` direct peer address, an HTTP(S) tracker returning
compact IPv4/IPv6 or dictionary peers, or a UDP tracker returning compact IPv4/IPv6 peers,
the CLI can request the info dictionary using
BEP 10/BEP 9 metadata exchange:

```sh
speed-download magnet-metadata 'magnet:?xt=urn:btih:<hash>&tr=https%3A%2F%2Ftracker.example%2Fannounce' output.torrent
```

The engine caps each peer message and the resulting metadata, keeps up to eight
16 KiB metadata block requests in flight, accepts only requested blocks with
the expected length, and verifies the complete SHA-1 info hash before validating
the same paths, sizes, and piece hashes as `.torrent` inspection before
creating `output.torrent`. All magnet trackers are retained in its
`announce-list`. An existing output file is never replaced. The command
contacts an explicit peer first, then HTTP(S) and UDP trackers in magnet order.
An address returned by multiple trackers is contacted once per metadata attempt.
HTTP(S) trackers may return compact IPv4 `peers`, IPv6 `peers6`, or BEP 3
`peers` dictionaries with an IP/hostname and port. UDP tracker discovery
accepts IPv4 and IPv6 responses according to the tracker socket's address
family. For dual-stack hostnames, it announces to one address of each family
with the same peer ID and key, and keeps peers from either successful response.
UDP tracker connect and announce requests are retried once after a timeout;
replies from another sender or transaction are ignored. A tracker error reply
is reported as a rejection rather than a malformed response. If both attempts
time out, the queued job treats the timeout as a retryable network failure.
Successful HTTP(S) and UDP tracker responses also supply a bounded interval
hint to the queue. If the transfer later fails transiently, its next attempt
waits at least as long as the largest interval received (up to one hour).
An HTTP(S) tracker failure with the BEP 31 `retry in` value schedules a
bounded retry after the specified minutes; `retry in=never` stays a permanent
rejection. Other tracker URLs can still be tried in the current attempt.
Each transfer attempt also reuses that peer ID and key across metadata
discovery, HTTP(S)/UDP tracker announces, and TCP peer handshakes. A new
attempt after pause or restart creates a new session identity.
The session sends `started` on its first successful HTTP(S) or UDP announce
to each tracker. Later announces to that tracker use the ordinary event. A
failed request leaves the tracker eligible for a `started` retry.
Queued magnet and local `.torrent` workers check pause, cancel, and queue
schedule state between tracker and peer attempts, during metadata retrieval,
and while waiting for payload peer messages. A blocked socket read can still
take up to its 15-second timeout before the worker observes a new request.
The desktop torrent metadata preparation path can fall back to read-only DHT peer discovery when trackers and explicit peers cannot supply metadata. A magnet does not establish the private flag, so this can disclose its info hash to DHT nodes before metadata is known. Verified private magnet results are rejected before payload queueing; open the original `.torrent` file for private torrents. The CLI metadata path retains its tracker/explicit-peer behavior. After metainfo is hash-verified, a public torrent may query up to 32 DHT nodes for payload peers; private torrents never enter this path. This bounded lookup has no listener, routing table, or announce, and it does not seed.
The `private=1` flag is read from the hashed `info` dictionary. Private local `.torrent` transfers use peers from one successful tracker at a time and never use DHT. A private magnet is rejected after metadata inspection because this client cannot guarantee that its metadata peer came from the private tracker; use the local `.torrent` source for that case. This follows the tracker-only peer rule in [BEP 27](https://www.bittorrent.org/beps/bep_0027.html).
The lookup follows the compact contact and `get_peers` formats in [BEP 5](https://www.bittorrent.org/beps/bep_0005.html) and accepts IPv6 contacts from [BEP 32](https://www.bittorrent.org/beps/bep_0032.html). It queries bootstrap contacts first, then prefers unqueried contacts with known node IDs by XOR distance to the info hash within its 96-contact/32-query bounds. A valid response records the queried contact's node ID; a discovered contact can also fill in an unknown ID for an existing address. If the contact set fills, a newly learned contact replaces the most distant unqueried contact only when it is closer to the target. Queried contacts and bootstrap contacts with unknown IDs remain available. It rejects private, loopback, link-local, and multicast addresses learned from DHT responses. This source has only compile validation so far; interoperability and UDP behavior need a native swarm check.

The transfer path accepts a v1 magnet URI through the
macOS Add Download dialog or `jobs.add` IPC. The CLI can also use
`speed-download magnet-download '<magnet-uri>' <destination-file>`. The engine
retrieves metadata, accepts single- and multi-file v1 torrents, discovers peers from
`x.pe`, HTTP(S) compact IPv4/IPv6 or dictionary tracker replies, or UDP compact IPv4/IPv6
tracker replies, and requests 16 KiB blocks
from TCP peers. It verifies each complete piece against the metainfo SHA-1
hash before writing it at the correct offset in a `.part` file and syncing.
On restart, it rehashes every complete piece independently; a valid piece
after a missing or damaged piece can still be reused. The completed file is
published without replacing an existing file. The queue,
pause/cancel controls, progress, and optional whole-file SHA-256 check apply.
The engine first requests payload pieces from the peer that supplied the
metadata. If that peer cannot continue, it announces the verified downloaded
byte count and remaining size to trackers and tries other discovered peers.
The transfer list removes duplicate addresses and stops asking trackers once
it has 80 distinct peers.
If every tracker request fails and there is no explicit peer, the transfer
reports the last tracker error so the engine can retry transient network
failures. A valid empty tracker response still means no peers are currently
available. Peers from successful trackers remain usable when another tracker
fails.
While a transfer is active, the engine reports the number of distinct
discovered peer addresses (capped at 80). HTTP and UDP tracker responses may
also supply seeder and leecher counts; these are the most recent successful
tracker's reported values, not a global swarm census or active connection
count. Missing values remain unknown. The macOS inspector displays them only
for an active torrent.
For each TCP peer, BITFIELD and HAVE messages record which pieces it reports;
the engine chooses an unverified, unclaimed piece available from that peer. A peer that
sends no bitfield leaves availability unknown until a piece request succeeds
or fails. It keeps up to eight 16 KiB requests in flight for one piece and
accepts out-of-order responses only for requested block offsets and lengths.
Completed pieces are SHA-1 verified before they enter the partial file. Up to
four TCP peers request distinct pieces concurrently. A shared claim table keeps
peers from fetching the same piece, and each peer has its own piece buffer.
Progress and verified-piece publication are serialized; the spool is synced
before a piece becomes available for resume or upload.
If one peer disconnects, lacks needed pieces, or sends a bad piece, the engine
tries other discovered peers. Storage, allocation, and progress callback
failures stop the attempt immediately. If the available peers lack needed
pieces, the queue can retry later so newly discovered peers may complete it.

The dedicated macOS Add Torrent dialog uses `torrents.prepare` to load local
`.torrent` files, HTTP(S) torrent sources, and magnet metadata without starting
payload transfers. It displays Files and Trackers tabs, permits file selection,
and lets users edit HTTP(S)/UDP tracker URLs before confirming. The RPC returns
at most 200 files per page within a conservative 128 KiB escaped-response budget;
`offset` loads further pages from the prepared source, so the full supported file
map remains selectable. Engine-owned metainfo previews have private permissions.
Tracker edits change only top-level fields and preserve the exact hashed `info`
dictionary and unrelated extensions. A public magnet preview retains its metadata
peer outside `info` so queueing does not lose its initial peer. Private torrent
payloads ignore this bootstrap field. The engine snapshots the confirmed metainfo
and persists selected paths when the user queues it.

A piece crossing into an unselected file is still fetched and verified in full,
and progress includes its bytes. Tracker announces still report bytes remaining
against the full torrent size. During an active TCP peer session, the engine
advertises only selected pieces whose hashes have been verified and may answer
16 KiB block requests for those pieces. It sends HAVE after each newly verified
piece. It does not listen for incoming peers or seed after completion. There is
no upload accounting or configurable upload limit yet, so upload throughput is
currently limited only by the connected peer and transport. Peer encryption,
uTP, and BitTorrent v2 are unsupported. Live swarm interoperability remains unverified.

The parser accepts at most 8 MiB of metainfo, 100,000 bencoded values,
32 levels of nested unknown values, 10,000 files, and 64 path components
per file. It requires canonical integer and string lengths, sorted unique
dictionary keys, a single `length` or `files` form, nonnegative sizes,
valid piece hashes and counts, and a bounded piece length. It computes the
v1 info hash from the exact encoded `info` slice in the input file, following
[BEP 3](https://www.bittorrent.org/beps/bep_0003.html).

File names must be valid UTF-8 and safe as portable path components. The
parser rejects traversal components, separators, control characters,
Windows device names, trailing dots or spaces, byte-identical duplicate file paths, and
symlink attributes. It accepts v1-compatible hybrid metainfo using only its validated v1 file map
and SHA-1 piece hashes. V2-only metainfo is rejected; v2 file trees and Merkle
piece layers are not used for downloading.

The read-only inspector does not access the destination filesystem and cannot
report its case or Unicode normalization behavior. The transfer publisher
checks for those collisions while constructing its private staging tree.

Persistent DHT participation, DHT metadata discovery, broader tracker discovery, selection in larger torrents and magnets,
post-completion seeding, upload accounting and limits, and swarm interoperability remain incomplete.

The macOS torrent review loads paged file lists from the frozen metadata source.
Every page must retain the same info hash, file count, and total size; offsets
must exactly follow the files already received. Queueing stays disabled until
all files arrive with unique paths and valid sizes. Tracker edits are checked
against the reviewed info hash and file count before submitting the job.

## Hybrid magnets and discovery deadlines

Magnets carrying both `btih` and `btmh` can use the v1 swarm when their metadata
contains a complete, valid v1 `pieces` and `length`/`files` projection. The v1
info hash is still checked against the exact raw info dictionary. The presence
of `meta version: 2` alone no longer rejects such hybrids. This is v1 fallback,
not v2 transfer support, as permitted by the
[BEP 52 upgrade path](https://www.bittorrent.org/beps/bep_0052.html#upgrade-path).

Each tracker discovery operation has a 15-second overall deadline, including
connection, TLS, headers, and response body. Pause/cancel/schedule checks run
between 250 ms waits; canceled work is joined before its session or allocator
can leave scope. Public transfers stop collecting once a tracker returns peers;
when trackers yield none, the existing bounded DHT fallback can run. Network or
tracker outages can still prevent discovery. The macOS client displays
**Finding peers…** when the engine reports zero torrent peers. Debug logging
records the underlying retry error without recording URLs or peer addresses.

Public torrent payloads also try DHT after exhausting unusable tracker peers,
rather than waiting for the next tracker announce simply because its response
was nonempty. The read-only DHT lookup keeps at most 96 contacts and issues at
most 32 one-second queries, checking pause/cancel between queries. Private
torrents never use this fallback. Tracker announce intervals remain respected.

### Recorded live diagnostic (2026-10-24)

The desktop engine retrieved and verified the AerynOS hybrid magnet with v1
info hash `4d2ecd5a735023482beb9c620eee1c800799efd0`, returning its ISO name and
one file through `torrents.prepare`. The existing Ubuntu job retained 1 MiB of
verified data across the engine reload. Its tracker requests and direct DHT
bootstrap probes timed out intermittently; one tracker returned a peer that
closed its connection. Continued Ubuntu payload progress was not established
by this diagnostic. These observations do not establish full swarm acceptance.

### Metadata reuse and native inspector

Magnet preparation first inspects up to 256 engine-owned metainfo snapshots in
the private profile. It revalidates the raw info hash and file map, rejects
private metadata for magnet reuse, and preserves cached trackers when a magnet
has none. Explicit tracker edits override the cached list. This permits an
already imported public torrent's magnet to open even if DHT is unreachable;
it does not manufacture peers or make an unavailable swarm downloadable.

DHT bootstrap uses all resolved addresses for three bootstrap hosts and sends
the BEP 43 read-only flag. Lookup contact/query bounds still apply. The macOS
torrent inspector separates tracker-reported swarm counts, the actual connected
connected source count and aggregate download rate and progress. Upload traffic
during those sessions is not yet reported by the inspector. Peer
addresses exist only in local IPC snapshots, not persistent state or logs.

The Arch torrent reported `NoTorrentPeers` with 7 MiB verified; its info hash
matches the user's trackerless magnet. The old magnet preparation returned
`NoReachablePeer` in a live IPC reproduction. No verified data was discarded.

### Single-file web seeds (BEP 19)

Public single-file torrents can fill missing pieces from up to 32 HTTP(S)
`url-list` entries. Directory URLs append the percent-encoded torrent name.
Requests cover contiguous gaps of at most 64 MiB; the response must match the
requested Content-Range and torrent size. Each piece is SHA-1 checked before
positional write, sync, and durable progress. A bad seed is abandoned without
trusting unverified bytes; verified pieces remain available to later seeds or
peers. Resume rehashes the same spool, so no separate HTTP representation or
journal can override torrent piece identity. Private and multi-file web seeds,
FTP web seeds, and magnet `ws` parameters remain unsupported.

Web seed requests use the queue task's proxy policy, shared HTTP connection
budget, global/per-job progress-based bandwidth limits, and pause/cancel
checks. A 15-second inactivity watchdog cancels and joins blocked HTTP work
before its buffers leave scope. The inspector identifies a web seed by host;
URL queries are not exposed as peer addresses or logged.

Live confirmation on 2026-10-24: the exact Arch magnet returned one file with
matching info hash in 6–7 ms using the cached metainfo. The existing Arch job
resumed via `mirror.aarnet.edu.au`, increasing verified progress from 7,340,032
to 14,155,776 bytes before a requested diagnostic pause. No partial reset was
performed. This confirms partial web-seed resume, not completion of the ISO or
general DHT reachability.
