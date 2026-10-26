//! BitTorrent v1 transfer path. Each independently placed
//! piece matches its metainfo SHA-1; all partial pieces are rehashed on restart
//! before any byte is trusted. Multi-file payloads use a flat verified spool
//! so pieces crossing file boundaries can resume safely.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const magnet = @import("magnet.zig");
const metadata = @import("metadata.zig");
const metainfo = @import("metainfo.zig");
const http_download = @import("../http/download.zig");

pub const ProgressCallback = *const fn (*anyopaque, u64, ?u64, bool) anyerror!void;
const read_poll_timeout: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(1_000), .clock = .awake } };
const block_size: usize = 16 * 1024;
const max_in_flight_blocks: usize = 8;
const max_piece_blocks: usize = 64 * 1024 * 1024 / block_size;
const max_parallel_peers: usize = 4;
const peer_buffer_budget: usize = 64 * 1024 * 1024;

const PeerTransfer = struct {
    io: Io,
    info: metainfo.Result,
    file: Io.File,
    verified: []bool,
    needed: []const bool,
    claimed: []bool,
    remaining: usize,
    verified_bytes: u64,
    needed_bytes: u64,
    callback: ?ProgressCallback,
    context: ?*anyopaque,
    in_flight: [max_parallel_peers]u64 = @splat(0),
    mutex: Io.Mutex = .init,

    fn complete(self: *PeerTransfer) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.remaining == 0;
    }

    fn claim(self: *PeerTransfer, availability: []const u8, known: bool) ?u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.verified, self.claimed, 0..) |done, busy, index| {
            if (done or busy or (known and !pieceInBitfield(availability, @intCast(index)))) continue;
            self.claimed[index] = true;
            return @intCast(index);
        }
        return null;
    }

    fn release(self: *PeerTransfer, index: u64, slot: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.claimed[@intCast(index)] = false;
        self.in_flight[slot] = 0;
    }

    fn progress(self: *PeerTransfer, slot: usize, received: usize) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.in_flight[slot] = received;
        var total = self.verified_bytes;
        for (self.in_flight) |value| total += value;
        if (self.callback) |report| if (self.context) |ctx| try report(ctx, total, self.needed_bytes, false);
    }

    fn commit(self: *PeerTransfer, index: u64, slot: usize, size: usize) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.verified[@intCast(index)] = true;
        self.claimed[@intCast(index)] = false;
        self.in_flight[slot] = 0;
        self.verified_bytes += size;
        self.remaining -= 1;
        if (self.callback) |report| if (self.context) |ctx| try report(ctx, self.verified_bytes, self.needed_bytes, true);
    }

    fn copyBitfield(self: *PeerTransfer, output: []u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.verified, self.needed, 0..) |valid, required, index| {
            if (valid and required) output[index / 8] |= @as(u8, 0x80) >> @as(u3, @intCast(index % 8));
        }
    }

    fn mayUpload(self: *PeerTransfer, index: u32) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return index < self.verified.len and self.verified[index] and self.needed[index];
    }
};

const PeerWorker = struct {
    transfer: *PeerTransfer,
    address: []const u8,
    slot: usize,
    session: *const metadata.Session,
    control: ?metadata.CheckpointCallback,
    control_context: ?*anyopaque,
    result: ?anyerror = null,
};

fn runPeerWorker(worker: *PeerWorker) void {
    const transfer = worker.transfer;
    const piece_size: usize = @intCast(transfer.info.piece_length);
    const buffer = std.heap.page_allocator.alloc(u8, piece_size) catch {
        worker.result = error.OutOfMemory;
        return;
    };
    defer std.heap.page_allocator.free(buffer);
    transferFromPeer(transfer.io, worker.address, transfer, buffer, worker.slot, worker.session, worker.control, worker.control_context) catch |err| {
        worker.result = err;
    };
}

fn runPeerAddresses(addresses: anytype, transfer: *PeerTransfer, session: *const metadata.Session, control: ?metadata.CheckpointCallback, control_context: ?*anyopaque, last_error: *anyerror) !void {
    var offset: usize = 0;
    while (offset < addresses.len and !transfer.complete()) {
        try checkControl(control, control_context);
        const piece_size: usize = @intCast(transfer.info.piece_length);
        const memory_limited_peers = @max(@as(usize, 1), peer_buffer_budget / piece_size);
        const batch_size = @min(@min(max_parallel_peers, memory_limited_peers), addresses.len - offset);
        var workers: [max_parallel_peers]PeerWorker = undefined;
        var threads: [max_parallel_peers]std.Thread = undefined;
        var launched: usize = 0;
        while (launched < batch_size) : (launched += 1) {
            workers[launched] = .{ .transfer = transfer, .address = addresses[offset + launched], .slot = launched,
                .session = session, .control = control, .control_context = control_context };
            threads[launched] = std.Thread.spawn(.{}, runPeerWorker, .{&workers[launched]}) catch {
                for (threads[0..launched]) |thread| thread.join();
                return error.PeerWorkerSpawnFailed;
            };
        }
        for (threads[0..launched]) |thread| thread.join();
        for (workers[0..launched]) |worker| if (worker.result) |err| {
            if (!canTryAnotherPeer(err)) return err;
            last_error.* = err;
        };
        offset += batch_size;
    }
}

pub fn download(
    allocator: Allocator,
    io: Io,
    url: []const u8,
    destination: []const u8,
    expected_sha256: ?[32]u8,
    callback: ?ProgressCallback,
    context: ?*anyopaque,
) !void {
    return downloadWithControl(allocator, io, url, destination, expected_sha256, callback, context, null, null);
}

/// Download a magnet transfer with an optional metadata-stage control check.
/// The progress callback remains responsible for checks during payload work.
pub fn downloadWithControl(
    allocator: Allocator,
    io: Io,
    url: []const u8,
    destination: []const u8,
    expected_sha256: ?[32]u8,
    callback: ?ProgressCallback,
    context: ?*anyopaque,
    control: ?metadata.CheckpointCallback,
    control_context: ?*anyopaque,
) !void {
    return downloadWithStats(allocator, io, url, destination, expected_sha256, callback, context, control, control_context, null, null);
}

pub fn downloadWithStats(
    allocator: Allocator,
    io: Io,
    url: []const u8,
    destination: []const u8,
    expected_sha256: ?[32]u8,
    callback: ?ProgressCallback,
    context: ?*anyopaque,
    control: ?metadata.CheckpointCallback,
    control_context: ?*anyopaque,
    stats: ?metadata.StatsCallback,
    stats_context: ?*anyopaque,
) !void {
    var link = try magnet.inspect(allocator, url);
    defer link.deinit(allocator);
    var session = try metadata.Session.init(io);
    const fetched = try metadata.fetchWithSourceSession(allocator, io, &link, &session, control, control_context, stats, stats_context);
    defer fetched.deinit(allocator);
    if (control) |check| if (control_context) |ctx| try check(ctx);
    const wrapped = try allocator.alloc(u8, fetched.info.len + "d4:info".len + 1);
    defer allocator.free(wrapped);
    @memcpy(wrapped[0..7], "d4:info");
    @memcpy(wrapped[7 .. 7 + fetched.info.len], fetched.info);
    wrapped[wrapped.len - 1] = 'e';
    const info = try metainfo.inspect(allocator, wrapped);
    const map = try metainfo.inspectFileMap(allocator, wrapped);
    defer map.deinit(allocator);
    if (!std.mem.eql(u8, &info.info_hash, &link.info_hash)) return error.MetadataHashMismatch;
    // The metadata stage may have used an explicit x.pe address. Until the
    // client can prove tracker provenance, it must not fetch private payloads.
    if (info.is_private) return error.PrivateMagnetRequiresTorrentFile;
    link.allow_dht = !info.is_private;
    try transferValidated(allocator, io, info, map, &link, fetched.peer, destination, expected_sha256, null, callback, context, &session, control, control_context, stats, stats_context);
}

/// Download a validated v1 `.torrent` using its tracker tiers. The destination
/// is a full file path for single-file torrents or a directory for multi-file.
pub fn downloadTorrentFile(
    allocator: Allocator,
    io: Io,
    torrent_path: []const u8,
    destination: []const u8,
    expected_sha256: ?[32]u8,
    callback: ?ProgressCallback,
    context: ?*anyopaque,
) !void {
    return downloadTorrentFileWithControl(allocator, io, torrent_path, destination, expected_sha256, callback, context, null, null);
}

/// Download a local torrent with control checks during tracker and peer waits.
pub fn downloadTorrentFileWithControl(
    allocator: Allocator,
    io: Io,
    torrent_path: []const u8,
    destination: []const u8,
    expected_sha256: ?[32]u8,
    callback: ?ProgressCallback,
    context: ?*anyopaque,
    control: ?metadata.CheckpointCallback,
    control_context: ?*anyopaque,
) !void {
    return downloadTorrentFileSelectedWithControl(allocator, io, torrent_path, destination, expected_sha256, null, callback, context, control, control_context);
}

pub fn downloadTorrentFileSelectedWithControl(
    allocator: Allocator,
    io: Io,
    torrent_path: []const u8,
    destination: []const u8,
    expected_sha256: ?[32]u8,
    selected_files: ?[]const []const u8,
    callback: ?ProgressCallback,
    context: ?*anyopaque,
    control: ?metadata.CheckpointCallback,
    control_context: ?*anyopaque,
) !void {
    return downloadTorrentFileSelectedWithStats(allocator, io, torrent_path, destination, expected_sha256, selected_files, callback, context, control, control_context, null, null);
}

pub fn downloadTorrentFileSelectedWithStats(
    allocator: Allocator,
    io: Io,
    torrent_path: []const u8,
    destination: []const u8,
    expected_sha256: ?[32]u8,
    selected_files: ?[]const []const u8,
    callback: ?ProgressCallback,
    context: ?*anyopaque,
    control: ?metadata.CheckpointCallback,
    control_context: ?*anyopaque,
    stats: ?metadata.StatsCallback,
    stats_context: ?*anyopaque,
) !void {
    return downloadTorrentFileSelectedWithTransport(allocator, io, torrent_path, destination, expected_sha256, selected_files, callback, context, control, control_context, stats, stats_context, .{}, null);
}

pub fn downloadTorrentFileSelectedWithTransport(
    allocator: Allocator,
    io: Io,
    torrent_path: []const u8,
    destination: []const u8,
    expected_sha256: ?[32]u8,
    selected_files: ?[]const []const u8,
    callback: ?ProgressCallback,
    context: ?*anyopaque,
    control: ?metadata.CheckpointCallback,
    control_context: ?*anyopaque,
    stats: ?metadata.StatsCallback,
    stats_context: ?*anyopaque,
    policy: @import("../http/proxy.zig").Policy,
    budget: ?*http_download.connection_budget.Budget,
) !void {
    try checkControl(control, control_context);
    const bytes = try Io.Dir.readFileAlloc(.cwd(), io, torrent_path, allocator, .limited(metainfo.max_metainfo_bytes));
    defer allocator.free(bytes);
    const info = try metainfo.inspect(allocator, bytes);
    const map = try metainfo.inspectFileMap(allocator, bytes);
    defer map.deinit(allocator);
    const bootstrap = if (!info.is_private) try metainfo.bootstrapPeer(allocator, bytes) else null;
    const tracker_list = metainfo.trackerUrls(allocator, io, info) catch |err| blk: {
        if (err != error.NoTorrentTrackers or info.is_private) return err;
        break :blk metainfo.TrackerList{ .urls = try allocator.alloc([]u8, 0) };
    };
    const trackers = tracker_list.urls;
    const peers = allocator.alloc([]u8, if (bootstrap != null) 1 else 0) catch |err| {
        for (trackers) |tracker| allocator.free(tracker);
        allocator.free(trackers);
        return err;
    };
    if (bootstrap) |peer| {
        peers[0] = allocator.dupe(u8, peer) catch |err| {
            for (trackers) |tracker| allocator.free(tracker);
            allocator.free(trackers);
            allocator.free(peers);
            return err;
        };
    }
    var link: magnet.Result = .{ .info_hash = info.info_hash, .display_name = null, .trackers = trackers, .peers = peers, .tracker_tier_ends = tracker_list.tier_ends, .tracker_tier_count = tracker_list.tier_count, .allow_dht = !info.is_private, .is_private = info.is_private };
    defer link.deinit(allocator);
    var session = try metadata.Session.init(io);
    session.webseed_policy = policy;
    session.webseed_budget = budget;
    try transferValidated(allocator, io, info, map, &link, null, destination, expected_sha256, selected_files, callback, context, &session, control, control_context, stats, stats_context);
}

/// Queue worker entry point for a desktop-selected local torrent source URL.
pub fn downloadTorrentSource(allocator: Allocator, io: Io, url: []const u8, destination: []const u8, expected_sha256: ?[32]u8, callback: ?ProgressCallback, context: ?*anyopaque) !void {
    return downloadTorrentSourceWithControl(allocator, io, url, destination, expected_sha256, callback, context, null, null);
}

/// Queue worker entry point with control checks during tracker and peer waits.
pub fn downloadTorrentSourceWithControl(allocator: Allocator, io: Io, url: []const u8, destination: []const u8, expected_sha256: ?[32]u8, callback: ?ProgressCallback, context: ?*anyopaque, control: ?metadata.CheckpointCallback, control_context: ?*anyopaque) !void {
    return downloadTorrentSourceWithStats(allocator, io, url, destination, expected_sha256, callback, context, control, control_context, null, null);
}

pub fn downloadTorrentSourceWithStats(allocator: Allocator, io: Io, url: []const u8, destination: []const u8, expected_sha256: ?[32]u8, callback: ?ProgressCallback, context: ?*anyopaque, control: ?metadata.CheckpointCallback, control_context: ?*anyopaque, stats: ?metadata.StatsCallback, stats_context: ?*anyopaque) !void {
    const path = try @import("source.zig").pathAlloc(allocator, url);
    defer allocator.free(path);
    try downloadTorrentFileSelectedWithStats(allocator, io, path, destination, expected_sha256, null, callback, context, control, control_context, stats, stats_context);
}

fn checkControl(control: ?metadata.CheckpointCallback, context: ?*anyopaque) metadata.CheckpointError!void {
    if (control) |check| if (context) |ctx| try check(ctx);
}

fn transferValidated(
    allocator: Allocator,
    io: Io,
    info: metainfo.Result,
    map: metainfo.FileMap,
    link: *const magnet.Result,
    first_peer: ?[]const u8,
    destination: []const u8,
    expected_sha256: ?[32]u8,
    selected_files: ?[]const []const u8,
    callback: ?ProgressCallback,
    context: ?*anyopaque,
    session: *metadata.Session,
    control: ?metadata.CheckpointCallback,
    control_context: ?*anyopaque,
    stats: ?metadata.StatsCallback,
    stats_context: ?*anyopaque,
) !void {
    try checkControl(control, control_context);
    session.peer_observer = stats;
    session.peer_observer_context = stats_context;
    const cwd = Io.Dir.cwd();
    if (cwd.statFile(io, destination, .{})) |_| return error.DestinationExists else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    const part_path = try std.fmt.allocPrint(allocator, "{s}.part", .{destination});
    defer allocator.free(part_path);
    const file = cwd.openFile(io, part_path, .{ .mode = .read_write, .allow_directory = false }) catch |err| switch (err) {
        error.FileNotFound => try cwd.createFile(io, part_path, .{ .exclusive = true, .truncate = false, .read = true }),
        else => return err,
    };
    var file_open = true;
    defer if (file_open) file.close(io);
    const piece_size: usize = std.math.cast(usize, info.piece_length) orelse return error.TorrentTooLarge;
    const piece_buffer = try allocator.alloc(u8, piece_size);
    defer allocator.free(piece_buffer);
    const count = std.math.cast(usize, info.piece_count) orelse return error.TorrentTooLarge;
    if (selected_files != null and (info.single_file or expected_sha256 != null)) return error.InvalidTorrentSelection;
    const needed = try allocator.alloc(bool, count);
    defer allocator.free(needed);
    @memset(needed, selected_files == null);
    if (selected_files) |selected| {
        if (selected.len == 0) return error.InvalidTorrentSelection;
        var selected_set = std.StringHashMap(void).init(allocator);
        defer selected_set.deinit();
        for (selected) |path| {
            if (selected_set.contains(path)) return error.InvalidTorrentSelection;
            try selected_set.put(path, {});
        }
        var found_count: usize = 0;
        for (map.files) |entry| {
            if (!selected_set.contains(entry.path)) continue;
            found_count += 1;
            if (entry.length == 0) continue;
            const first: usize = @intCast(entry.offset / info.piece_length);
            const last: usize = @intCast((entry.offset + entry.length - 1) / info.piece_length);
            @memset(needed[first .. last + 1], true);
        }
        if (found_count != selected.len) return error.InvalidTorrentSelection;
    }
    var needed_bytes: u64 = 0;
    for (needed, 0..) |required, index| if (required) {
        needed_bytes += try pieceBytes(info, @intCast(index));
    };
    const verified = try allocator.alloc(bool, count);
    defer allocator.free(verified);
    for (verified, needed) |*done, required| done.* = !required;
    var verified_bytes: u64 = 0;
    var remaining = try scanVerified(io, file, info, piece_buffer, verified, needed, &verified_bytes);
    try file.setLength(io, info.total_bytes);
    if (callback) |report| if (context) |ctx| try report(ctx, verified_bytes, needed_bytes, true);

    // Public single-file web seeds can fill the verified spool without DHT.
    // Never expose a private torrent to an unconfirmed external web endpoint.
    if (remaining != 0 and info.single_file and !info.is_private) {
        const seeds = metainfo.webSeedUrls(allocator, info) catch try allocator.alloc([]const u8, 0);
        defer allocator.free(seeds);
        for (seeds) |seed| {
            try checkControl(control, control_context);
            const url = if (std.mem.endsWith(u8, seed, "/")) blk: {
                var encoded: std.Io.Writer.Allocating = .init(allocator);
                defer encoded.deinit();
                try encoded.writer.writeAll(seed);
                try (std.Uri.Component{ .raw = info.name }).formatPath(&encoded.writer);
                break :blk try allocator.dupe(u8, encoded.written());
            } else try allocator.dupe(u8, seed);
            defer allocator.free(url);
            var transfer: @import("webseed.zig").Transfer = .{
                .allocator = allocator,
                .io = io,
                .info = info,
                .file = file,
                .buffer = piece_buffer,
                .verified = verified,
                .remaining = &remaining,
                .verified_bytes = &verified_bytes,
                .callback = callback,
                .context = context,
                .control = control,
                .control_context = control_context,
                .policy = session.webseed_policy,
                .budget = session.webseed_budget,
                .stats = stats,
                .stats_context = stats_context,
            };
            transfer.run(url) catch |err| {
                if (err == error.TransferPauseRequested or err == error.TransferCancelRequested or err == error.TransferSchedulePaused or err == error.OutOfMemory) return err;
                // Network/protocol failures can use another seed or peers;
                // local I/O errors must not be hidden by discovery failures.
                if (!canTryAnotherPeer(err) and err != error.InvalidWebSeedResponse and err != error.ResponseLengthMismatch and err != error.ReadFailed and err != error.InvalidResponseStatus and err != error.ConnectionClosed and err != error.TlsInitializationFailed) return err;
            };
            if (remaining == 0) break;
        }
    }

    if (remaining != 0) {
        const claimed = try allocator.alloc(bool, count);
        defer allocator.free(claimed);
        @memset(claimed, false);
        var shared: PeerTransfer = .{ .io = io, .info = info, .file = file, .verified = verified,
            .needed = needed, .claimed = claimed, .remaining = remaining, .verified_bytes = verified_bytes,
            .needed_bytes = needed_bytes, .callback = callback, .context = context };
        var last_error: anyerror = error.NoPeerHasPieces;
        // Tracker `left` describes the full torrent, even when the user
        // selected only some files. Progress still uses needed_bytes.
        const peers: ?[][]u8 = metadata.collectPeersWithStats(allocator, io, link, verified_bytes, info.total_bytes, session, control, control_context, stats, stats_context) catch |err| blk: {
            if (first_peer == null) return err;
            break :blk null;
        };
        defer if (peers) |addresses| {
            for (addresses) |peer| allocator.free(peer);
            allocator.free(addresses);
        };
        if (peers) |addresses| {
            var ordered: std.ArrayList([]const u8) = .empty;
            defer ordered.deinit(allocator);
            if (first_peer) |first| try ordered.append(allocator, first);
            for (addresses) |peer| {
                if (first_peer) |first| if (std.mem.eql(u8, peer, first)) continue;
                try ordered.append(allocator, peer);
            }
            try runPeerAddresses(ordered.items, &shared, session, control, control_context, &last_error);
        } else if (first_peer) |first| {
            const single = [_][]const u8{first};
            try runPeerAddresses(single[0..], &shared, session, control, control_context, &last_error);
        }
        if (!shared.complete() and link.allow_dht and !link.is_private and !session.dht_attempted) {
            // A nonempty tracker response does not prove any returned peer is
            // reachable. Try public DHT before entering tracker retry wait.
            try checkControl(control, control_context);
            session.dht_attempted = true;
            const discovered = @import("dht.zig").discover(allocator, io, info.info_hash, control, control_context) catch |err| blk: {
                if (!canTryAnotherPeer(err) and err != error.DhtBootstrapUnavailable) return err;
                break :blk null;
            };
            if (discovered) |dht_peers| {
                defer {
                    for (dht_peers) |peer| allocator.free(peer);
                    allocator.free(dht_peers);
                }
                if (stats) |report| if (stats_context) |ctx| report(ctx, @intCast(dht_peers.len), .{});
                try runPeerAddresses(dht_peers, &shared, session, control, control_context, &last_error);
            }
        }
        if (!shared.complete()) return last_error;
        remaining = shared.remaining;
        verified_bytes = shared.verified_bytes;
    }
    try file.sync(io);
    if (callback) |report| if (context) |ctx| try report(ctx, needed_bytes, needed_bytes, true);
    try http_download.verifySha256(io, file, expected_sha256);
    if (callback) |report| if (context) |ctx| try report(ctx, needed_bytes, needed_bytes, true);
    if (info.single_file) {
        file.close(io);
        file_open = false;
        try http_download.publishNoReplace(cwd, io, part_path, destination);
    } else {
        try publishFileTree(allocator, io, file, map, info.info_hash, destination, selected_files, needed_bytes, callback, context);
        file.close(io);
        file_open = false;
        cwd.deleteFile(io, part_path) catch {};
    }
}

// A failed peer can be replaced; local storage and callback failures must
// reach the queue unchanged instead of being hidden by later peer attempts.
fn canTryAnotherPeer(err: anyerror) bool {
    return switch (err) {
        error.InvalidPeerAddress,
        error.PeerHandshakeMismatch,
        error.PeerClosed,
        error.PeerTransferComplete,
        error.PeerChoked,
        error.PeerMissingPieces,
        error.PeerPieceUnavailable,
        error.UnexpectedPeerPiece,
        error.InvalidPeerHave,
        error.InvalidPeerBitfield,
        error.PeerMessageTooLarge,
        error.TorrentPieceHashMismatch,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.ConnectionRefused,
        error.NetworkUnreachable,
        error.HostUnreachable,
        error.NetworkDown,
        error.SocketUnconnected,
        error.EndOfStream,
        error.BrokenPipe,
        error.Timeout,
        error.WriteFailed,
        => true,
        else => false,
    };
}

fn publishFileTree(allocator: Allocator, io: Io, spool: Io.File, map: metainfo.FileMap, info_hash: [20]u8, destination: []const u8, selected_files: ?[]const []const u8, needed_bytes: u64, callback: ?ProgressCallback, context: ?*anyopaque) !void {
    if (callback) |report| if (context) |ctx| try report(ctx, needed_bytes, needed_bytes, true);
    const cwd = Io.Dir.cwd();
    const stage = try std.fmt.allocPrint(allocator, "{s}.part-tree", .{destination});
    defer allocator.free(stage);
    // A previous interrupted materialization may be removed only when its
    // ownership marker matches this exact torrent.
    const marker = try std.fmt.allocPrint(allocator, "{s}/.speed-download-stage", .{stage});
    defer allocator.free(marker);
    if (cwd.statFile(io, stage, .{})) |_| {
        const owner = try cwd.readFileAlloc(io, marker, allocator, .limited(4096));
        defer allocator.free(owner);
        if (!std.mem.eql(u8, owner, &info_hash)) return error.ForeignStagingDirectory;
        try cwd.deleteTree(io, stage);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    const private_dir: Io.File.Permissions = if (@import("builtin").os.tag == .windows) .default_dir else .fromMode(0o700);
    const private_file: Io.File.Permissions = if (@import("builtin").os.tag == .windows) .default_file else .fromMode(0o600);
    try cwd.createDir(io, stage, private_dir);
    var stage_owned = true;
    errdefer if (stage_owned) cwd.deleteTree(io, stage) catch {};
    {
        const marker_file = try cwd.createFile(io, marker, .{ .exclusive = true, .permissions = private_file });
        defer marker_file.close(io);
        try marker_file.writeStreamingAll(io, &info_hash);
        try marker_file.sync(io);
    }
    const stage_dir = try cwd.openDir(io, stage, .{ .follow_symlinks = false });
    var stage_dir_open = true;
    defer if (stage_dir_open) stage_dir.close(io);
    // The stage is private and starts empty except for our marker. Remember
    // exact directory spellings; if mkdir finds an unrecorded existing name,
    // the filesystem folded two torrent paths onto the same directory.
    var created_dirs = std.StringHashMap(void).init(allocator);
    defer created_dirs.deinit();
    var selected_set = std.StringHashMap(void).init(allocator);
    defer selected_set.deinit();
    if (selected_files) |selected| for (selected) |path| try selected_set.put(path, {});
    var buffer: [64 * 1024]u8 = undefined;
    var bytes_since_check: usize = 0;
    var files_since_check: usize = 0;
    for (map.files) |entry| {
        if (selected_files != null and !selected_set.contains(entry.path)) continue;
        if (std.mem.eql(u8, entry.path, ".speed-download-stage") or std.mem.startsWith(u8, entry.path, ".speed-download-stage/")) return error.ReservedTorrentPath;
        var search_from: usize = 0;
        while (std.mem.indexOfScalarPos(u8, entry.path, search_from, '/')) |slash| {
            const parent = entry.path[0..slash];
            if (!created_dirs.contains(parent)) {
                stage_dir.createDir(io, parent, private_dir) catch |err| switch (err) {
                    error.PathAlreadyExists => return error.ConflictingTorrentPath,
                    else => return err,
                };
                try created_dirs.put(parent, {});
            }
            search_from = slash + 1;
        }
        const output = stage_dir.createFile(io, entry.path, .{ .exclusive = true, .permissions = private_file, .resolve_beneath = true }) catch |err| switch (err) {
            error.PathAlreadyExists => return error.ConflictingTorrentPath,
            else => return err,
        };
        errdefer output.close(io);
        var copied: u64 = 0;
        while (copied < entry.length) {
            const amount: usize = @intCast(@min(buffer.len, entry.length - copied));
            if (try spool.readPositionalAll(io, buffer[0..amount], entry.offset + copied) != amount) return error.ShortPartialFileRead;
            try output.writeStreamingAll(io, buffer[0..amount]);
            copied += amount;
            bytes_since_check += amount;
            if (bytes_since_check >= 8 * 1024 * 1024) {
                if (callback) |report| if (context) |ctx| try report(ctx, needed_bytes, needed_bytes, true);
                bytes_since_check = 0;
            }
        }
        try output.sync(io);
        output.close(io);
        files_since_check += 1;
        if (files_since_check >= 128) {
            if (callback) |report| if (context) |ctx| try report(ctx, needed_bytes, needed_bytes, true);
            files_since_check = 0;
        }
    }
    stage_dir.close(io);
    stage_dir_open = false;
    if (callback) |report| if (context) |ctx| try report(ctx, needed_bytes, needed_bytes, true);
    try Io.Dir.renamePreserve(cwd, stage, cwd, destination, io);
    stage_owned = false;
    const published_marker = try std.fmt.allocPrint(allocator, "{s}/.speed-download-stage", .{destination});
    defer allocator.free(published_marker);
    cwd.deleteFile(io, published_marker) catch {};
}

fn pieceOffset(info: metainfo.Result, index: u64) !u64 {
    return std.math.mul(u64, index, info.piece_length) catch error.TorrentSizeOverflow;
}

fn pieceBytes(info: metainfo.Result, index: u64) !usize {
    const offset = try pieceOffset(info, index);
    if (offset >= info.total_bytes) return error.InvalidTorrentPieces;
    return @intCast(@min(info.piece_length, info.total_bytes - offset));
}

fn scanVerified(io: Io, file: Io.File, info: metainfo.Result, buffer: []u8, verified: []bool, needed: []const bool, verified_bytes: *u64) !usize {
    const length = try file.length(io);
    var remaining: usize = 0;
    for (verified, 0..) |*valid, index| {
        if (!needed[index]) continue;
        remaining += 1;
        const piece: u64 = @intCast(index);
        const offset = try pieceOffset(info, piece);
        const size = try pieceBytes(info, piece);
        if (length < offset + size) continue;
        if (try file.readPositionalAll(io, buffer[0..size], offset) != size) return error.ShortPartialFileRead;
        var actual: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(buffer[0..size], &actual, .{});
        const expected = info.piece_hashes[@as(usize, @intCast(piece)) * 20 ..][0..20];
        if (!std.mem.eql(u8, &actual, expected)) continue;
        valid.* = true;
        verified_bytes.* += size;
        remaining -= 1;
    }
    return remaining;
}

fn transferFromPeer(
    io: Io,
    address: []const u8,
    transfer: *PeerTransfer,
    piece_buffer: []u8,
    slot: usize,
    session: *const metadata.Session,
    control: ?metadata.CheckpointCallback,
    control_context: ?*anyopaque,
) !void {
    try checkControl(control, control_context);
    const info = transfer.info;
    const file = transfer.file;
    const separator = std.mem.lastIndexOfScalar(u8, address, ':') orelse return error.InvalidPeerAddress;
    const port = std.fmt.parseInt(u16, address[separator + 1 ..], 10) catch return error.InvalidPeerAddress;
    const host = address[0..separator];
    if (host.len == 0 or port == 0) return error.InvalidPeerAddress;
    const stream = if (host[0] == '[') blk: {
        const ip = Io.net.IpAddress.parseIp6(host[1 .. host.len - 1], port) catch return error.InvalidPeerAddress;
        break :blk try @import("../../core/net_connect.zig").address(io, ip, 10_000);
    } else blk: {
        const name = Io.net.HostName.init(host) catch return error.InvalidPeerAddress;
        break :blk try @import("../../core/net_connect.zig").host(io, name, port, 10_000);
    };
    defer stream.close(io);
    var write_buffer: [4096]u8 = undefined;
    var socket_writer = stream.writer(io, &write_buffer);
    var hello: [68]u8 = @splat(0);
    hello[0] = 19;
    @memcpy(hello[1..20], "BitTorrent protocol");
    @memcpy(hello[28..48], &info.info_hash);
    @memcpy(hello[48..68], &session.peer_id);
    try socket_writer.interface.writeAll(&hello);
    try socket_writer.interface.flush();
    var response: [68]u8 = undefined;
    try readExact(io, stream, &response, transfer);
    try checkControl(control, control_context);
    if (response[0] != 19 or !std.mem.eql(u8, response[1..20], "BitTorrent protocol") or
        !std.mem.eql(u8, response[28..48], &info.info_hash)) return error.PeerHandshakeMismatch;
    if (session.peer_observer) |report| if (session.peer_observer_context) |ctx|
        report(ctx, 0, .{ .peer_event = true, .active_peer = address });
    defer if (session.peer_observer) |report| {
        if (session.peer_observer_context) |ctx|
            report(ctx, 0, .{ .peer_event = true });
    };
    var local_bitfield: [metainfo.max_metainfo_bytes / 20 / 8 + 1]u8 = @splat(0);
    const bitfield_len = std.math.divCeil(usize, transfer.verified.len, 8) catch return error.InvalidTorrentPieces;
    transfer.copyBitfield(local_bitfield[0..bitfield_len]);
    var bitfield_header: [5]u8 = undefined;
    std.mem.writeInt(u32, bitfield_header[0..4], @intCast(bitfield_len + 1), .big);
    bitfield_header[4] = 5;
    try socket_writer.interface.writeAll(&bitfield_header);
    try socket_writer.interface.writeAll(local_bitfield[0..bitfield_len]);
    try socket_writer.interface.writeAll(&.{ 0, 0, 0, 1, 2 }); // interested
    try socket_writer.interface.writeAll(&.{ 0, 0, 0, 1, 1 }); // unchoke
    try socket_writer.interface.flush();

    var choked = true;
    var frame_buffer: [128 * 1024]u8 = undefined;
    var availability: [metainfo.max_metainfo_bytes / 20 / 8 + 1]u8 = @splat(0);
    var bitfield_known = false;
    var peer_interested = false;
    piece_loop: while (!transfer.complete()) {
        try checkControl(control, control_context);
        const piece_index = transfer.claim(&availability, bitfield_known) orelse return error.PeerMissingPieces;
        var committed = false;
        defer if (!committed) transfer.release(piece_index, slot);
        const size = try pieceBytes(info, piece_index);
        var unchoke_messages: usize = 0;
        var has_piece: ?bool = if (pieceInBitfield(&availability, piece_index)) true else if (bitfield_known) false else null;
        if (has_piece == false) continue :piece_loop;
        while (choked) {
            try checkControl(control, control_context);
            unchoke_messages += 1;
            if (unchoke_messages > 128) return error.PeerChoked;
            const frame = try readPeerFrame(io, stream, &frame_buffer, &socket_writer.interface, transfer, &peer_interested, control, control_context);
            try updateAvailability(frame, piece_index, info.piece_count, &availability, &bitfield_known, &has_piece);
            if (has_piece == false) continue :piece_loop;
            if (frame.len == 1 and frame[0] == 1) choked = false;
        }
        const block_count = std.math.divCeil(usize, size, block_size) catch return error.InvalidTorrentPieceLength;
        if (block_count > max_piece_blocks) return error.InvalidTorrentPieceLength;
        var received: [max_piece_blocks]bool = @splat(false);
        var requested_blocks: usize = 0;
        var received_blocks: usize = 0;
        var received_bytes: usize = 0;
        var idle_messages: usize = 0;
        while (received_blocks < block_count) {
            try checkControl(control, control_context);
            while (requested_blocks < block_count and requested_blocks - received_blocks < max_in_flight_blocks) {
                const begin = requested_blocks * block_size;
                const amount = @min(block_size, size - begin);
                var request: [17]u8 = .{ 0, 0, 0, 13, 6 } ++ @as([12]u8, @splat(0));
                std.mem.writeInt(u32, request[5..9], @intCast(piece_index), .big);
                std.mem.writeInt(u32, request[9..13], @intCast(begin), .big);
                std.mem.writeInt(u32, request[13..17], @intCast(amount), .big);
                try socket_writer.interface.writeAll(&request);
                requested_blocks += 1;
            }
            try socket_writer.interface.flush();
            const frame = try readPeerFrame(io, stream, &frame_buffer, &socket_writer.interface, transfer, &peer_interested, control, control_context);
            try checkControl(control, control_context);
            if (frame.len == 1 and frame[0] == 0) return error.PeerChoked;
            try updateAvailability(frame, piece_index, info.piece_count, &availability, &bitfield_known, &has_piece);
            if (has_piece == false) return error.PeerMissingPieces;
            if (frame.len < 9 or frame[0] != 7) {
                idle_messages += 1;
                if (idle_messages > 128) return error.PeerPieceUnavailable;
                continue;
            }
            const index = std.mem.readInt(u32, frame[1..5], .big);
            const begin: usize = std.mem.readInt(u32, frame[5..9], .big);
            if (index != piece_index or begin % block_size != 0 or begin >= size) return error.UnexpectedPeerPiece;
            const block_index = begin / block_size;
            if (block_index >= requested_blocks) return error.UnexpectedPeerPiece;
            const amount = @min(block_size, size - begin);
            if (frame.len != amount + 9) return error.UnexpectedPeerPiece;
            if (received[block_index]) {
                idle_messages += 1;
                if (idle_messages > 128) return error.PeerPieceUnavailable;
                continue;
            }
            @memcpy(piece_buffer[begin .. begin + amount], frame[9..]);
            received[block_index] = true;
            received_blocks += 1;
            received_bytes += amount;
            idle_messages = 0;
            try transfer.progress(slot, received_bytes);
        }
        var digest: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(piece_buffer[0..size], &digest, .{});
        const expected = info.piece_hashes[@as(usize, @intCast(piece_index)) * 20 ..][0..20];
        if (!std.mem.eql(u8, &digest, expected)) return error.TorrentPieceHashMismatch;
        try file.writePositionalAll(io, piece_buffer[0..size], try pieceOffset(info, piece_index));
        try file.sync(io);
        try transfer.commit(piece_index, slot, size);
        committed = true;
        var have: [9]u8 = .{ 0, 0, 0, 5, 4, 0, 0, 0, 0 };
        std.mem.writeInt(u32, have[5..9], @intCast(piece_index), .big);
        try socket_writer.interface.writeAll(&have);
        try socket_writer.interface.flush();
    }
}

// Only verified, selected pieces are offered. A request cannot read a partial
// piece or a deselected file from the spool.
fn readPeerFrame(io: Io, stream: Io.net.Stream, buffer: []u8, writer: *Io.Writer, transfer: *PeerTransfer, peer_interested: *bool, control: ?metadata.CheckpointCallback, control_context: ?*anyopaque) ![]u8 {
    while (true) {
        try checkControl(control, control_context);
        const frame = try readFrame(io, stream, buffer, transfer);
        if (frame.len == 1 and frame[0] == 2) { peer_interested.* = true; continue; }
        if (frame.len == 1 and frame[0] == 3) { peer_interested.* = false; continue; }
        if (frame.len != 13 or frame[0] != 6) return frame;
        if (!peer_interested.*) continue;
        const index = std.mem.readInt(u32, frame[1..5], .big);
        const begin = std.mem.readInt(u32, frame[5..9], .big);
        const amount = std.mem.readInt(u32, frame[9..13], .big);
        if (!transfer.mayUpload(index) or amount == 0 or amount > block_size) continue;
        const size = try pieceBytes(transfer.info, index);
        if (begin > size or amount > size - begin) continue;
        var payload: [block_size]u8 = undefined;
        if (try transfer.file.readPositionalAll(io, payload[0..amount], (try pieceOffset(transfer.info, index)) + begin) != amount) return error.ShortPartialFileRead;
        var header: [13]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], amount + 9, .big);
        header[4] = 7;
        std.mem.writeInt(u32, header[5..9], index, .big);
        std.mem.writeInt(u32, header[9..13], begin, .big);
        try writer.writeAll(&header);
        try writer.writeAll(payload[0..amount]);
        try writer.flush();
    }
}

// A missing bitfield leaves availability unknown; a received bitfield is
// authoritative for the current piece until a later HAVE announces it.
fn updateAvailability(frame: []const u8, piece_index: u64, piece_count: u64, bitfield: []u8, bitfield_known: *bool, has_piece: *?bool) !void {
    if (frame.len == 0) return;
    switch (frame[0]) {
        4 => {
            if (frame.len != 5) return error.InvalidPeerHave;
            const announced = std.mem.readInt(u32, frame[1..5], .big);
            if (announced >= piece_count) return error.InvalidPeerHave;
            bitfield[@as(usize, @intCast(announced / 8))] |= @as(u8, 0x80) >> @as(u3, @intCast(announced % 8));
            if (announced == piece_index) has_piece.* = true;
        },
        5 => {
            const bitfield_len = std.math.divCeil(u64, piece_count, 8) catch return error.InvalidTorrentPieces;
            if (frame.len != bitfield_len + 1 or bitfield_len > bitfield.len or bitfield_known.*) return error.InvalidPeerBitfield;
            const spare: u3 = @intCast((8 - piece_count % 8) % 8);
            if (spare != 0 and frame[frame.len - 1] & ((@as(u8, 1) << spare) - 1) != 0) return error.InvalidPeerBitfield;
            @memcpy(bitfield[0..@intCast(bitfield_len)], frame[1..]);
            bitfield_known.* = true;
            has_piece.* = pieceInBitfield(bitfield, piece_index);
        },
        else => {},
    }
}

fn pieceInBitfield(bitfield: []const u8, piece_index: u64) bool {
    const index: usize = @intCast(piece_index / 8);
    const bit: u3 = @intCast(piece_index % 8);
    return bitfield[index] & (@as(u8, 0x80) >> bit) != 0;
}

fn readExact(io: Io, stream: Io.net.Stream, output: []u8, transfer: *PeerTransfer) !void {
    var offset: usize = 0;
    const deadline = Io.Clock.now(.awake, io).nanoseconds + 15 * std.time.ns_per_s;
    while (offset < output.len) {
        if (transfer.complete()) return error.PeerTransferComplete;
        var buffers: [1][]u8 = .{output[offset..]};
        const result = io.operateTimeout(.{ .net_read = .{ .socket_handle = stream.socket.handle, .data = &buffers } }, read_poll_timeout) catch |err| {
            if (err == error.Timeout and Io.Clock.now(.awake, io).nanoseconds < deadline) continue;
            return err;
        };
        const amount = (try result.net_read).data_len;
        if (amount == 0) return error.PeerClosed;
        offset += amount;
    }
}

fn readFrame(io: Io, stream: Io.net.Stream, buffer: []u8, transfer: *PeerTransfer) ![]u8 {
    var prefix: [4]u8 = undefined;
    try readExact(io, stream, &prefix, transfer);
    const length = std.mem.readInt(u32, &prefix, .big);
    if (length > buffer.len) return error.PeerMessageTooLarge;
    try readExact(io, stream, buffer[0..length], transfer);
    return buffer[0..length];
}
