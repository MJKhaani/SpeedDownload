# Engine feature status

This is the implementation inventory for the Zig engine at `src/` as of 2026-10-28. “Implemented” means the behavior exists in source; it does not imply interoperability with every server, torrent swarm, OS, or client. The [support matrix](support-matrix.md) records runtime evidence, while [PROJECT.md](../PROJECT.md) records the full product requirements.

## Core, storage, and control

| Area | Implemented in the engine | Limits and remaining work |
|---|---|---|
| Process and IPC | Headless `engine` mode; one engine per user profile; per-user Unix sockets on macOS/Linux and named pipes on Windows; framed JSON-RPC 2.0 handshake; bounded client sessions; request validation; CLI RPC client. | The optional MCP server is not implemented. GUI startup and UI support differ by platform. |
| Jobs | Persisted jobs with stable IDs, revisions, idempotent add, priority/order, search/filter/pagination, per-job bandwidth, optional SHA-256, reference page, and replacement source. Start, pause, resume, retry, cancel, delete, move queue, reorder, and resume queue are exposed over IPC. | Replacement source is a user-confirmed operation; the engine cannot automatically recapture an authenticated browser link. |
| State and recovery | Persistent state machine; partial data and metadata journals; restart recovery; bounded retry for temporary failures and HTTP `Retry-After`; no-replace final publication. | Recovery cannot make weak remote validators strong. Older unsupported journal formats can require a fresh download. |
| Progress | Aggregate received/total bytes, HTTP worker ranges, torrent peer counts where known, change cursor, bounded subscriptions and `jobs.wait`. | Client rendering varies; Windows/Linux clients currently poll. |
| Named queues | Required `main` queue, user queues with IDs/names, per-queue active limit and 168-hour schedule, job movement, queue completion action, and settings migration. | Completion actions can affect the OS; they require careful client review and platform validation. |
| Settings and diagnostics | Per-user schema-versioned `settings.json`, validation, atomic updates, proxy and bandwidth policy, default folder/connections, browser extension list, language, and opt-in bounded redacted debug log. | `stop_seeding_after_minutes` is stored but has no effect until seeding exists. `language` and browser extension list are settings for clients/extensions. |

## Transfers

| Protocol | Implemented in the engine | Limits and remaining work |
|---|---|---|
| HTTP/HTTPS | Redirect-aware probe with filename, final URL, size and verified range capability; TLS-checked single-stream download; strong-validator resume; dynamic non-overlapping multipart ranges; durable segment checkpoints; SHA-256; global/per-host request budgets; global and per-job download caps, scheduled cap, and queue-aware pause/cancel. | Ranges require a valid `206` and compatible representation; otherwise the safe single-stream path applies. Server/proxy interoperability and large-file fault testing remain release gates. See [HTTP details](protocols/http-multipart.md). |
| FTP/FTPS | Anonymous passive/EPSV transfers, explicit FTPS and implicit FTPS on port 990, TLS certificate checking, `SIZE`/`MDTM`, guarded `REST` resume, journal checksum, progress and optional SHA-256. | No login credentials, FTP proxy, multipart FTP, or TLS session reuse for FTPS data channels. See [FTP details](protocols/ftp.md). |
| BitTorrent v1 | Local `.torrent`, HTTP(S) metainfo and `magnet:` preparation; bounded metadata exchange via explicit peers, HTTP/UDP trackers and limited read-only DHT; file selection and tracker review data; single/multi-file piece download; SHA-1 piece verification and restart rehash; concurrent TCP peers; public single-file HTTP(S) web seeds; peer/seed counts when known. | No v2-only payload, post-completion seeding/listener, upload accounting or upload cap, PEX, µTP, or general encryption compatibility. Private magnets are rejected after metadata inspection; use a `.torrent` file. Live swarm coverage remains experimental. See [BitTorrent details](protocols/torrent.md). |

## IPC methods and CLI

The engine currently dispatches `engine.status`; `jobs.list`, `jobs.get`, `jobs.wait`, `jobs.subscribe`, `jobs.add`, `jobs.probe`, `jobs.control`, `jobs.set-bandwidth`, `jobs.replace-source`, `jobs.resume-queue`, `jobs.reorder`, `jobs.move-queue`, `jobs.delete`; `torrents.prepare`; and `settings.get`/`settings.update`. The platform feature handshake differs: the Windows build advertises a smaller subset than the Unix build. See the [IPC contract](protocols/ipc-v1.md) and `src/main.zig` for the exact advertised sets.

The CLI provides `engine`, direct HTTP(S)/FTP(S) download, torrent/magnet inspect and download commands, and `rpc` commands for status, list, get, probe, add, control, reorder, and delete. CLI help is the authority for exact arguments.

## Planned, not implemented

The built-in authenticated MCP server and Zig media-site extraction (including YouTube quality/format/playlist review) are requirements in [PROJECT.md](../PROJECT.md), not current engine capabilities. Torrent seeding and its stored time limit are likewise not active. Windows WinUI 3/Fluent UI is the target client architecture; the current release ZIP contains the WPF compatibility client while WinUI startup and deployment are repaired.
