# FTP source status

The engine accepts anonymous `ftp://` and `ftps://` file URLs in the CLI and queued jobs.
The macOS Add Download dialog can inspect these URLs through the same IPC
probe used for HTTP. FTP is currently an initial implementation; network
interoperability has not been validated against a server matrix.

`ftps://` means explicit FTPS on port 21 by default: the client requires
`AUTH TLS`, validates the certificate against the platform trust store,
logs in over TLS, then requires `PBSZ 0` and `PROT P` before transferring
data. A server that cannot protect both channels is rejected.

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

Current limits: anonymous FTP and explicit FTPS only; no credentials,
implicit FTPS, active mode, multipart FTP, legacy non-UTF-8 path encoding,
or FTP proxy transport. A configured custom proxy fails the FTP operation
instead of bypassing it. System proxy configuration is currently applied
to HTTP and HTTPS; FTP and FTPS connect directly. Plain FTP and FTPS control
and data sockets use 30-second per-read timeouts, including TLS handshake
reads. A peer that continuously sends a trickle of bytes can still prolong a
transfer or cancellation beyond that per-read bound.
Some FTPS servers require TLS session reuse on the data connection; the Zig
TLS client has no session-reuse path here, so those servers may reject a
transfer. A temporary `421`, `425`, or
`450`–`452` reply at connection or transfer setup enters the engine's
bounded retry path. Server compatibility and recovery
after an abrupt process termination still need validation.
