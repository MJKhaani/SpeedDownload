# FTP source status

For the current cross-protocol implementation inventory and validation limits, see [engine feature status](../engine-feature-status.md).

The engine accepts anonymous `ftp://` and `ftps://` file URLs in the CLI and queued jobs.
The macOS Add Download dialog can inspect these URLs through the same IPC
probe used for HTTP. FTP is currently an initial implementation; network
interoperability has not been validated against a server matrix.

`ftps://` means explicit FTPS on port 21 by default: the client requires
`AUTH TLS`, validates the certificate against the platform trust store,
logs in over TLS, then requires `PBSZ 0` and `PROT P` before transferring
data. A server that cannot protect both channels is rejected.
`ftps://host:990/path` selects implicit FTPS: TLS is established and the
certificate validated before the server greeting. `AUTH TLS` is not sent on
that port. Data connections still require private `PROT P` protection.

The implementation logs in anonymously, switches to binary mode, asks for
`SIZE` and `MDTM`, and transfers over one passive data connection. It tries
`EPSV` first and falls back to `PASV`. It connects the data socket to the
control connection's host, ignoring a server-advertised PASV address. IPv6
literal URLs use `EPSV`; `PASV` is used only for DNS/IPv4 hosts. The
engine reports total bytes when `SIZE` is available, reports progress from
the data connection, supports SHA-256 verification, and publishes the final
file without replacing an existing destination.

When a server supplies `SIZE`, `MDTM`, and `REST`, the engine can checkpoint a
partial file in a `.ftpj` journal. Before resuming it checks the URL hash,
remote size, and modification time, trims bytes after the last durable
checkpoint, and requests `REST` at that offset. Size and timestamp are
weaker change detectors than a strong HTTP ETag; a server that changes bytes
without changing either value cannot be detected by these checks. The
optional SHA-256 digest provides end-to-end verification when supplied.

Current limits: anonymous FTP and FTPS only; no credentials,
active mode, multipart FTP, legacy non-UTF-8 path encoding,
or FTP proxy transport. A configured custom proxy fails the FTP operation
instead of bypassing it. System proxy configuration is currently applied
to HTTP and HTTPS; FTP and FTPS connect directly. Plain FTP and FTPS control
and data sockets use 30-second per-read timeouts, including TLS handshake
reads. Queued plain FTP control and data reads use one-second timed reads
with pause, cancel, and schedule checks between them. Queued FTPS control
and data reads use cancellable concurrent I/O where supported; without it,
the existing TLS read timeout remains the fallback. Connection setup and TLS
handshake reads can still delay a stop request. A peer that continuously sends a
trickle of bytes can prolong a transfer. Runtime stop behavior needs native
validation.
Some FTPS servers require TLS session reuse on the data connection; the Zig
TLS client has no session-reuse path here, so those servers may reject a
transfer. A temporary `421`, `425`, or
`450`–`452` reply at connection or transfer setup enters the engine's
bounded retry path. Server compatibility and recovery
after an abrupt process termination still need validation.

## FTP resume journal integrity

New FTP partials use the `SDFTP002` journal. It stores the source URL hash,
server size and modification timestamp, durable completed byte count, and a
SHA-256 checksum over those fields. A journal is atomically replaced only
after the corresponding bytes have been synced. A damaged journal is rejected
instead of trusting its cursor. The checksum detects accidental corruption; it
does not authenticate files against another process running as the same user.

Older `SDFTP001` journals did not include an integrity check. The engine leaves
their partial data in place and reports an upgrade error rather than trusting
the cursor. To restart that job, remove its `.part` and `.part.ftpj` files and
add the URL again. A matching `SIZE` and `MDTM` still cannot prove that a
remote server has kept identical content; FTP resume remains more conservative
than strong-ETag HTTP resume.
