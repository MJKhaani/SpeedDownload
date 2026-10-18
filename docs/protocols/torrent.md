# BitTorrent status

The engine can inspect a local BitTorrent v1 `.torrent` file with
`speed-download torrent-info <file.torrent>`. The command prints its name,
tracker, total bytes, validated relative file paths with lengths and byte
offsets, file and piece counts, piece length, and SHA-1 info
hash as JSON. It does not add a transfer, contact a tracker or peer, or write
downloaded files.

For a v1 torrent with HTTP(S) or UDP trackers in `announce`
or `announce-list`, the CLI can transfer its payload with
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
file order; within-tier shuffling and successful-tracker promotion are not
implemented. Multi-file downloads assemble the verified flat piece spool into
a private staging directory, then publish the complete tree without replacing
an existing destination. A piece that crosses file boundaries is copied into
both files only after its SHA-1 hash is verified. A stale staging directory is
removed on retry only when its ownership marker matches the torrent info hash.
The publisher creates each parent directory explicitly and rejects a name that
the filesystem reports as already present under a different spelling. File
creation is exclusive, so case or Unicode normalization collisions fail before
the staged tree is published.
Inspection
rejects a file layout where one file path is also a parent directory of another.

The engine also inspects BitTorrent v1 magnet URIs with
`speed-download magnet-info 'magnet:?xt=urn:btih:…&dn=…&tr=…&x.pe=host:port'`.
It decodes 40-character hexadecimal or 32-character Base32 info hashes,
the optional display name, up to 32 HTTP, HTTPS, or UDP tracker URLs, and up
to 16 explicit peer addresses.
Output is JSON with `status: "metadata_required"`. URI length, parameter
count, decoded values, and percent escapes are bounded and checked.

For a magnet with an `x.pe` direct peer address, an HTTP(S) tracker returning
compact IPv4/IPv6 or dictionary peers, or a UDP tracker returning compact IPv4/IPv6 peers,
the CLI can request the info dictionary using
BEP 10/BEP 9 metadata exchange:

```sh
speed-download magnet-metadata 'magnet:?xt=urn:btih:<hash>&tr=https%3A%2F%2Ftracker.example%2Fannounce' output.torrent
```

The engine caps each peer message and the resulting metadata, requests 16 KiB
blocks sequentially, verifies the complete SHA-1 info hash, then validates
the same paths, sizes, and piece hashes as `.torrent` inspection before
creating `output.torrent`. All magnet trackers are retained in its
`announce-list`. An existing output file is never replaced. The command
contacts an explicit peer first, then HTTP(S) and UDP trackers in magnet order.
HTTP(S) trackers may return compact IPv4 `peers`, IPv6 `peers6`, or BEP 3
`peers` dictionaries with an IP/hostname and port. UDP tracker discovery
accepts IPv4 and IPv6 responses according to the tracker socket's address
family. For dual-stack hostnames, it announces to one address of each family
with the same peer ID and key, and keeps peers from either successful response.
Each transfer attempt also reuses that peer ID and key across metadata
discovery, HTTP(S)/UDP tracker announces, and TCP peer handshakes. A new
attempt after pause or restart creates a new session identity.
DHT is not supported. It does not
download payload pieces or seed.

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
For each TCP peer, BITFIELD and HAVE messages record which pieces it reports;
the engine chooses any unverified piece available from that peer. A peer that
sends no bitfield leaves availability unknown until a piece request succeeds
or fails. It keeps up to eight 16 KiB requests in flight for one piece and
accepts out-of-order responses only for requested block offsets and lengths.
Completed pieces are SHA-1 verified before they enter the partial file. Pieces
and peers are still handled sequentially rather than concurrently.

This is an early compatibility slice. It does not upload or seed. File selection, DHT,
peer encryption, uTP, and BitTorrent v2 are unsupported.
Many ordinary magnets depend on one of those discovery methods and will not
start. The peer transfer path compiles but has not been exercised against a
live swarm; it is not release-ready.

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
symlink attributes. It rejects v2/hybrid metainfo until BEP 52 file trees
and piece layers are implemented.

The read-only inspector does not access the destination filesystem and cannot
report its case or Unicode normalization behavior. The transfer publisher
checks for those collisions while constructing its private staging tree.

Broader tracker/DHT discovery, file selection,
seeding, upload accounting, and swarm interoperability remain incomplete.
