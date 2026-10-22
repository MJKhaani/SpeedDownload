//! Fetch BEP 9 info-dictionary blocks from explicit or HTTP-tracker peers.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const magnet = @import("magnet.zig");
const metainfo = @import("metainfo.zig");
const control_contract = @import("control.zig");

const block_size = 16 * 1024;
const max_in_flight_blocks = 8;
const max_metadata_blocks = metainfo.max_metainfo_bytes / block_size;
const max_message = 128 * 1024;
const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(15_000), .clock = .awake } };

/// Control outcomes that must leave metadata discovery immediately instead of
/// falling through to another peer or tracker.
pub const CheckpointError = control_contract.CheckpointError;
/// Called on the worker thread; the context remains owned by the caller.
pub const CheckpointCallback = control_contract.CheckpointCallback;

fn checkpoint(callback: ?CheckpointCallback, context: ?*anyopaque) CheckpointError!void {
    try control_contract.checkpoint(callback, context);
}

fn isCheckpointError(err: anyerror) bool {
    return err == error.TransferPauseRequested or err == error.TransferCancelRequested or err == error.TransferSchedulePaused;
}

pub const Session = struct {
    peer_id: [20]u8,
    key: [4]u8,
    announced_trackers: [32][]const u8 = undefined,
    announced_count: usize = 0,
    dht_attempted: bool = false,

    pub fn init(io: Io) !Session {
        var result: Session = .{ .peer_id = undefined, .key = undefined };
        try io.randomSecure(&result.peer_id);
        try io.randomSecure(&result.key);
        return result;
    }

    fn hasAnnounced(self: *const Session, tracker: []const u8) bool {
        for (self.announced_trackers[0..self.announced_count]) |announced| {
            if (std.mem.eql(u8, announced, tracker)) return true;
        }
        return false;
    }

    fn markAnnounced(self: *Session, tracker: []const u8) void {
        for (self.announced_trackers[0..self.announced_count], 0..) |announced, index| {
            if (!std.mem.eql(u8, announced, tracker)) continue;
            // Keep the most recently successful tracker last. Later announce
            // passes can promote it within its original BEP 12 tier.
            var position = index;
            while (position + 1 < self.announced_count) : (position += 1)
                self.announced_trackers[position] = self.announced_trackers[position + 1];
            self.announced_trackers[self.announced_count - 1] = tracker;
            return;
        }
        if (self.announced_count == self.announced_trackers.len) return;
        self.announced_trackers[self.announced_count] = tracker;
        self.announced_count += 1;
    }
};

fn trackerOrder(link: *const magnet.Result, session: *const Session) [32]u8 {
    var order: [32]u8 = @splat(0);
    var next: usize = 0;
    var start: usize = 0;
    const tier_count: usize = if (link.tracker_tier_count == 0) 1 else link.tracker_tier_count;
    for (0..tier_count) |tier| {
        const end: usize = if (link.tracker_tier_count == 0) link.trackers.len else link.tracker_tier_ends[tier];
        var preferred: ?usize = null;
        var recent = session.announced_count;
        while (recent > 0 and preferred == null) {
            recent -= 1;
            for (start..end) |index| {
                if (std.mem.eql(u8, link.trackers[index], session.announced_trackers[recent])) {
                    preferred = index;
                    break;
                }
            }
        }
        if (preferred) |index| {
            order[next] = @intCast(index);
            next += 1;
        }
        for (start..end) |index| {
            if (preferred != null and preferred.? == index) continue;
            order[next] = @intCast(index);
            next += 1;
        }
        start = end;
    }
    return order;
}

pub fn fetch(allocator: Allocator, io: Io, link: *const magnet.Result) ![]u8 {
    const found = try fetchWithSource(allocator, io, link);
    allocator.free(found.peer);
    return found.info;
}

pub const Fetched = struct {
    info: []u8,
    peer: []u8,

    pub fn deinit(self: Fetched, allocator: Allocator) void {
        allocator.free(self.info);
        allocator.free(self.peer);
    }
};

pub const TrackerCounts = struct {
    seeders: ?u32 = null,
    leechers: ?u32 = null,
    retry_delay_seconds: ?u32 = null,
};

pub const StatsCallback = *const fn (*anyopaque, u32, TrackerCounts) void;

/// Fetch hash-verified metadata and retain the peer that supplied it. Both
/// owned slices must be released by the caller.
pub fn fetchWithSource(allocator: Allocator, io: Io, link: *const magnet.Result) !Fetched {
    var session = try Session.init(io);
    return fetchWithSourceSession(allocator, io, link, &session, null, null, null, null);
}

/// Fetch metadata while allowing an engine worker to stop between network
/// attempts and peer frames. Pass both callback and context to enable checks;
/// callback errors are returned unchanged. The returned buffers are caller-owned.
pub fn fetchWithSourceSession(allocator: Allocator, io: Io, link: *const magnet.Result, session: *Session, control: ?CheckpointCallback, control_context: ?*anyopaque, stats: ?StatsCallback, stats_context: ?*anyopaque) !Fetched {
    var last_error: anyerror = error.NoReachablePeer;
    var attempted = std.StringHashMap(void).init(allocator);
    defer {
        var keys = attempted.keyIterator();
        while (keys.next()) |key| allocator.free(key.*);
        attempted.deinit();
    }
    for (link.peers) |peer| {
        try checkpoint(control, control_context);
        if (!try markPeerAttempted(allocator, &attempted, peer)) continue;
        const bytes = fetchPeer(allocator, io, peer, link.info_hash, session, control, control_context) catch |err| {
            if (isCheckpointError(err)) return err;
            if (err == error.OutOfMemory) return err;
            last_error = err;
            continue;
        };
        errdefer allocator.free(bytes);
        return .{ .info = bytes, .peer = try allocator.dupe(u8, peer) };
    }
    const order = trackerOrder(link, session);
    for (order[0..link.trackers.len]) |index| {
        const tracker = link.trackers[index];
        try checkpoint(control, control_context);
        const parsed = std.Uri.parse(tracker) catch continue;
        var counts: TrackerCounts = .{};
        const peers = discoverTrackerPeers(allocator, io, tracker, parsed, link.info_hash, 0, 1, session, &counts) catch |err| {
            if (err == error.OutOfMemory) return err;
            if (counts.retry_delay_seconds != null) if (stats) |report| if (stats_context) |ctx| report(ctx, 0, counts);
            if (err == error.TrackerRetryRequested or last_error != error.TrackerRetryRequested) last_error = err;
            continue;
        };
        defer {
            for (peers) |peer| allocator.free(peer);
            allocator.free(peers);
        }
        if (stats) |report| if (stats_context) |ctx| report(ctx, @intCast(peers.len), counts);
        for (peers) |peer| {
            try checkpoint(control, control_context);
            if (!try markPeerAttempted(allocator, &attempted, peer)) continue;
            const bytes = fetchPeer(allocator, io, peer, link.info_hash, session, control, control_context) catch |err| {
                if (isCheckpointError(err)) return err;
                if (err == error.OutOfMemory) return err;
                last_error = err;
                continue;
            };
            errdefer allocator.free(bytes);
            return .{ .info = bytes, .peer = try allocator.dupe(u8, peer) };
        }
    }
    if (link.allow_dht) {
        const discovered = @import("dht.zig").discover(allocator, io, link.info_hash, control, control_context) catch |err| blk: {
            if (isCheckpointError(err) or err == error.OutOfMemory) return err;
            break :blk null;
        };
        if (discovered) |peers| {
            defer {
                for (peers) |peer| allocator.free(peer);
                allocator.free(peers);
            }
            for (peers) |peer| {
                try checkpoint(control, control_context);
                if (!try markPeerAttempted(allocator, &attempted, peer)) continue;
                const bytes = fetchPeer(allocator, io, peer, link.info_hash, session, control, control_context) catch |err| {
                    if (isCheckpointError(err) or err == error.OutOfMemory) return err;
                    last_error = err;
                    continue;
                };
                errdefer allocator.free(bytes);
                return .{ .info = bytes, .peer = try allocator.dupe(u8, peer) };
            }
        }
    }
    return last_error;
}

fn markPeerAttempted(allocator: Allocator, attempted: *std.StringHashMap(void), peer: []const u8) !bool {
    if (attempted.contains(peer)) return false;
    const owned = try allocator.dupe(u8, peer);
    errdefer allocator.free(owned);
    try attempted.put(owned, {});
    return true;
}

/// Discover compact tracker peers for a transfer. `downloaded` counts verified
/// payload bytes; `total_bytes` comes from hash-verified torrent metadata.
/// The caller owns every returned address and the outer slice. Pass both
/// control and context to stop between tracker requests.
pub fn collectPeers(allocator: Allocator, io: Io, link: *const magnet.Result, downloaded: u64, total_bytes: u64, session: *Session, control: ?CheckpointCallback, control_context: ?*anyopaque) ![][]u8 {
    return collectPeersWithStats(allocator, io, link, downloaded, total_bytes, session, control, control_context, null, null);
}

pub fn collectPeersWithStats(allocator: Allocator, io: Io, link: *const magnet.Result, downloaded: u64, total_bytes: u64, session: *Session, control: ?CheckpointCallback, control_context: ?*anyopaque, stats: ?StatsCallback, stats_context: ?*anyopaque) ![][]u8 {
    if (downloaded > total_bytes) return error.InvalidTorrentProgress;
    const max_peers = 80;
    var peers: std.ArrayList([]u8) = .empty;
    errdefer {
        for (peers.items) |peer| allocator.free(peer);
        peers.deinit(allocator);
    }
    for (link.peers) |peer| {
        if (peers.items.len == max_peers) break;
        if (containsPeer(peers.items, peer)) continue;
        const owned = try allocator.dupe(u8, peer);
        peers.append(allocator, owned) catch |err| {
            allocator.free(owned);
            return err;
        };
    }
    if (stats) |report| if (stats_context) |ctx| report(ctx, @intCast(peers.items.len), .{});
    var last_tracker_error: ?anyerror = null;
    var tracker_responded = false;
    var latest_counts: TrackerCounts = .{};
    const order = trackerOrder(link, session);
    for (order[0..link.trackers.len]) |index| {
        const tracker = link.trackers[index];
        try checkpoint(control, control_context);
        if (peers.items.len == max_peers) break;
        const parsed = std.Uri.parse(tracker) catch continue;
        var counts: TrackerCounts = .{};
        const discovered = discoverTrackerPeers(allocator, io, tracker, parsed, link.info_hash, downloaded, total_bytes - downloaded, session, &counts) catch |err| {
            if (err == error.OutOfMemory) return err;
            if (counts.retry_delay_seconds != null) if (stats) |report| if (stats_context) |ctx| report(ctx, @intCast(peers.items.len), counts);
            if (err == error.TrackerRetryRequested or last_tracker_error == null or last_tracker_error.? != error.TrackerRetryRequested) last_tracker_error = err;
            continue;
        };
        tracker_responded = true;
        latest_counts = counts;
        defer allocator.free(discovered);
        peers.ensureUnusedCapacity(allocator, @min(discovered.len, max_peers - peers.items.len)) catch |err| {
            for (discovered) |peer| allocator.free(peer);
            return err;
        };
        for (discovered) |peer| {
            if (peers.items.len == max_peers or containsPeer(peers.items, peer)) {
                allocator.free(peer);
            } else {
                peers.appendAssumeCapacity(peer);
            }
        }
        if (stats) |report| if (stats_context) |ctx| report(ctx, @intCast(peers.items.len), counts);
        // BEP 27 keeps a private transfer with one successful tracker.
        if (link.is_private) break;
    }
    if (link.allow_dht and !session.dht_attempted and peers.items.len == 0) {
        try checkpoint(control, control_context);
        session.dht_attempted = true;
        const discovered = @import("dht.zig").discover(allocator, io, link.info_hash, control, control_context) catch |err| blk: {
            if (isCheckpointError(err)) return err;
            if (err == error.OutOfMemory) return err;
            break :blk null;
        };
        if (discovered) |found| {
            defer allocator.free(found);
            peers.ensureUnusedCapacity(allocator, @min(found.len, max_peers - peers.items.len)) catch |err| {
                for (found) |peer| allocator.free(peer);
                return err;
            };
            for (found) |peer| {
                if (peers.items.len == max_peers or containsPeer(peers.items, peer)) allocator.free(peer) else peers.appendAssumeCapacity(peer);
            }
            if (stats) |report| if (stats_context) |ctx| report(ctx, @intCast(peers.items.len), latest_counts);
        }
        try checkpoint(control, control_context);
    }
    if (peers.items.len == 0 and !tracker_responded) return last_tracker_error orelse error.NoTorrentPeers;
    return peers.toOwnedSlice(allocator);
}

fn containsPeer(peers: []const []u8, candidate: []const u8) bool {
    for (peers) |peer| if (std.mem.eql(u8, peer, candidate)) return true;
    return false;
}

fn discoverTrackerPeers(allocator: Allocator, io: Io, tracker: []const u8, uri: std.Uri, info_hash: [20]u8, downloaded: u64, left: u64, session: *Session, counts: *TrackerCounts) ![][]u8 {
    if (std.ascii.eqlIgnoreCase(uri.scheme, "udp")) return discoverUdpPeers(allocator, io, tracker, uri, info_hash, downloaded, left, session, counts);
    if (std.ascii.eqlIgnoreCase(uri.scheme, "http") or std.ascii.eqlIgnoreCase(uri.scheme, "https"))
        return discoverHttpPeers(allocator, io, tracker, info_hash, downloaded, left, session, counts);
    return error.UnsupportedTrackerScheme;
}

fn discoverUdpPeers(allocator: Allocator, io: Io, tracker: []const u8, uri: std.Uri, info_hash: [20]u8, downloaded: u64, left: u64, session: *Session, counts: *TrackerCounts) ![][]u8 {
    if (uri.user != null or uri.password != null or uri.fragment != null) return error.InvalidTracker;
    const port = uri.port orelse return error.InvalidTracker;
    if (port == 0) return error.InvalidTracker;
    const host_component = uri.host orelse return error.InvalidTracker;
    const host = switch (host_component) {
        .raw, .percent_encoded => |value| value,
    };
    if (host.len == 0) return error.InvalidTracker;
    var ipv4: ?Io.net.IpAddress = null;
    var ipv6: ?Io.net.IpAddress = null;
    if (host[0] == '[') {
        if (host.len < 3 or host[host.len - 1] != ']') return error.InvalidTracker;
        ipv6 = Io.net.IpAddress.parseIp6(host[1 .. host.len - 1], port) catch return error.InvalidTracker;
    } else if (Io.net.IpAddress.parseIp4(host, port)) |address| {
        ipv4 = address;
    } else |_| {
        const name = Io.net.HostName.init(host) catch return error.InvalidTracker;
        var results_buffer: [16]Io.net.HostName.LookupResult = undefined;
        var results: Io.Queue(Io.net.HostName.LookupResult) = .init(&results_buffer);
        try name.lookup(io, &results, .{ .port = port });
        while (results.getOne(io)) |result| {
            switch (result) {
                .address => |candidate| switch (candidate) {
                    .ip4 => if (ipv4 == null) {
                        ipv4 = candidate;
                    },
                    .ip6 => if (ipv6 == null) {
                        ipv6 = candidate;
                    },
                },
                .canonical_name => {},
            }
        } else |_| {}
    }
    if (ipv4 == null and ipv6 == null) return error.TrackerAddressUnavailable;
    var peers: std.ArrayList([]u8) = .empty;
    errdefer {
        for (peers.items) |peer| allocator.free(peer);
        peers.deinit(allocator);
    }
    var last_error: anyerror = error.TrackerAddressUnavailable;
    var succeeded = false;
    const addresses: [2]?Io.net.IpAddress = .{ ipv4, ipv6 };
    for (addresses) |maybe_address| {
        const address = maybe_address orelse continue;
        const found = discoverUdpPeersAtAddress(allocator, io, address, info_hash, downloaded, left, session, !session.hasAnnounced(tracker), counts) catch |err| {
            if (err == error.OutOfMemory) return err;
            last_error = err;
            continue;
        };
        succeeded = true;
        session.markAnnounced(tracker);
        defer allocator.free(found);
        const take = @min(found.len, 80 - peers.items.len);
        peers.ensureUnusedCapacity(allocator, take) catch |err| {
            for (found) |peer| allocator.free(peer);
            return err;
        };
        for (found[0..take]) |peer| peers.appendAssumeCapacity(peer);
        for (found[take..]) |peer| {
            allocator.free(peer);
        }
    }
    if (!succeeded) return last_error;
    return peers.toOwnedSlice(allocator);
}

fn discoverUdpPeersAtAddress(allocator: Allocator, io: Io, address: Io.net.IpAddress, info_hash: [20]u8, downloaded: u64, left: u64, session: *const Session, started: bool, counts: *TrackerCounts) ![][]u8 {
    const local: Io.net.IpAddress = switch (address) {
        .ip4 => .{ .ip4 = .unspecified(0) },
        .ip6 => .{ .ip6 = .unspecified(0) },
    };
    const socket = try local.bind(io, .{ .mode = .dgram });
    defer socket.close(io);
    var transaction_bytes: [4]u8 = undefined;
    try io.randomSecure(&transaction_bytes);
    const connect_transaction = std.mem.readInt(u32, &transaction_bytes, .big);
    var connect: [16]u8 = undefined;
    std.mem.writeInt(u64, connect[0..8], 0x41727101980, .big);
    std.mem.writeInt(u32, connect[8..12], 0, .big);
    std.mem.writeInt(u32, connect[12..16], connect_transaction, .big);
    var response_buffer: [2048]u8 = undefined;
    const connected = try udpTrackerExchange(&socket, io, &address, &connect, 0, connect_transaction, &response_buffer);
    if (connected.len < 16) return error.InvalidTrackerResponse;
    const connection_id = std.mem.readInt(u64, connected[8..16], .big);

    try io.randomSecure(&transaction_bytes);
    const announce_transaction = std.mem.readInt(u32, &transaction_bytes, .big);
    var announce: [98]u8 = @splat(0);
    std.mem.writeInt(u64, announce[0..8], connection_id, .big);
    std.mem.writeInt(u32, announce[8..12], 1, .big);
    std.mem.writeInt(u32, announce[12..16], announce_transaction, .big);
    @memcpy(announce[16..36], &info_hash);
    @memcpy(announce[36..56], &session.peer_id);
    std.mem.writeInt(u64, announce[56..64], downloaded, .big);
    std.mem.writeInt(u64, announce[64..72], left, .big);
    std.mem.writeInt(u32, announce[80..84], if (started) 2 else 0, .big);
    @memcpy(announce[88..92], &session.key);
    std.mem.writeInt(u32, announce[92..96], 50, .big);
    const received = try udpTrackerExchange(&socket, io, &address, &announce, 1, announce_transaction, &response_buffer);
    const stride: usize = if (address == .ip4) 6 else 18;
    if (received.len < 20 or (received.len - 20) % stride != 0)
        return error.InvalidTrackerResponse;
    counts.leechers = std.mem.readInt(u32, received[12..16], .big);
    counts.seeders = std.mem.readInt(u32, received[16..20], .big);
    counts.retry_delay_seconds = @min(std.mem.readInt(u32, received[8..12], .big), 3600);
    return if (address == .ip4)
        peersFromCompact(allocator, received[20..])
    else
        peersFromCompact6(allocator, received[20..]);
}

fn udpTrackerExchange(socket: *const Io.net.Socket, io: Io, address: *const Io.net.IpAddress, request: []const u8, action: u32, transaction: u32, buffer: []u8) ![]const u8 {
    const delays_ms = [_]i64{ 5_000, 10_000 };
    for (delays_ms) |delay_ms| {
        const wait: Io.Timeout = (Io.Timeout{ .duration = .{ .raw = .fromMilliseconds(delay_ms), .clock = .awake } }).toDeadline(io);
        try socket.sendTimeout(io, address, request, wait);
        var ignored: usize = 0;
        while (ignored < 4) : (ignored += 1) {
            const packet = socket.receiveTimeout(io, buffer, wait) catch |err| switch (err) {
                error.Timeout => break,
                else => return err,
            };
            if (packet.flags.trunc or !std.meta.eql(packet.from, address.*) or packet.data.len < 8) continue;
            if (std.mem.readInt(u32, packet.data[4..8], .big) != transaction) continue;
            const response_action = std.mem.readInt(u32, packet.data[0..4], .big);
            if (response_action == 3) return error.TrackerRejected;
            if (response_action != action) return error.InvalidTrackerResponse;
            return packet.data;
        }
    }
    return error.Timeout;
}

fn discoverHttpPeers(allocator: Allocator, io: Io, tracker: []const u8, info_hash: [20]u8, downloaded: u64, left: u64, session: *Session, counts: *TrackerCounts) ![][]u8 {
    const encoded_hash = percentEncode(&info_hash);
    const encoded_peer = percentEncode(&session.peer_id);
    const separator: []const u8 = if (std.mem.indexOfScalar(u8, tracker, '?') == null) "?" else "&";
    const url = try std.fmt.allocPrint(allocator, "{s}{s}info_hash={s}&peer_id={s}&key={d}&port=0&uploaded=0&downloaded={d}&left={d}&compact=1&numwant=50{s}", .{
        tracker,                                                                      separator, &encoded_hash, &encoded_peer, std.mem.readInt(u32, &session.key, .big), downloaded, left,
        if (session.hasAnnounced(tracker)) @as([]const u8, "") else "&event=started",
    });
    defer allocator.free(url);
    const uri = std.Uri.parse(url) catch return error.InvalidTracker;
    if (uri.user != null or uri.password != null or uri.fragment != null) return error.InvalidTracker;
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    var request = try client.request(.GET, uri, .{ .headers = .{ .accept_encoding = .{ .override = "identity" } } });
    var response_started = false;
    var complete = false;
    defer {
        if (response_started and !complete) {
            request.connection.?.closing = true;
            request.reader.state = .ready;
        }
        request.deinit();
    }
    try request.sendBodiless();
    var head_buffer: [8192]u8 = undefined;
    var response = try request.receiveHead(&head_buffer);
    response_started = true;
    if (response.head.status != .ok or response.head.content_encoding != .identity) return error.TrackerRejected;
    var body_buffer: [8192]u8 = undefined;
    var body = response.reader(&body_buffer);
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const amount = try body.readSliceShort(&chunk);
        if (amount == 0) break;
        if (bytes.items.len + amount > 256 * 1024) return error.TrackerResponseTooLarge;
        try bytes.appendSlice(allocator, chunk[0..amount]);
    }
    complete = true;
    const compact = try parseTrackerPeers(bytes.items, &counts.retry_delay_seconds);
    session.markAnnounced(tracker);
    counts.* = compact.counts;
    var peers = try peersFromCompact(allocator, compact.ipv4);
    errdefer {
        for (peers) |peer| allocator.free(peer);
        allocator.free(peers);
    }
    const ipv6 = try peersFromCompact6(allocator, compact.ipv6);
    defer allocator.free(ipv6);
    errdefer for (ipv6) |peer| allocator.free(peer);
    const expanded = try peersFromExpanded(allocator, compact.expanded);
    defer allocator.free(expanded);
    errdefer for (expanded) |peer| allocator.free(peer);
    const ipv4_count = @min(peers.len, 80);
    const ipv6_count = @min(ipv6.len, 80 - ipv4_count);
    const expanded_count = @min(expanded.len, 80 - ipv4_count - ipv6_count);
    const combined = try allocator.alloc([]u8, ipv4_count + ipv6_count + expanded_count);
    @memcpy(combined[0..ipv4_count], peers[0..ipv4_count]);
    @memcpy(combined[ipv4_count..][0..ipv6_count], ipv6[0..ipv6_count]);
    @memcpy(combined[ipv4_count + ipv6_count ..], expanded[0..expanded_count]);
    for (peers[ipv4_count..]) |peer| allocator.free(peer);
    for (ipv6[ipv6_count..]) |peer| allocator.free(peer);
    for (expanded[expanded_count..]) |peer| allocator.free(peer);
    allocator.free(peers);
    peers = &.{};
    return combined;
}

fn peersFromCompact(allocator: Allocator, compact: []const u8) ![][]u8 {
    if (compact.len % 6 != 0) return error.InvalidTrackerResponse;
    var peers: std.ArrayList([]u8) = .empty;
    errdefer {
        for (peers.items) |peer| allocator.free(peer);
        peers.deinit(allocator);
    }
    for (0..@min(compact.len / 6, 64)) |index| {
        const entry = compact[index * 6 ..][0..6];
        const port = std.mem.readInt(u16, entry[4..6], .big);
        if (port == 0) continue;
        const address = try std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}:{d}", .{ entry[0], entry[1], entry[2], entry[3], port });
        try peers.append(allocator, address);
    }
    return peers.toOwnedSlice(allocator);
}

fn peersFromCompact6(allocator: Allocator, compact: []const u8) ![][]u8 {
    if (compact.len % 18 != 0) return error.InvalidTrackerResponse;
    var peers: std.ArrayList([]u8) = .empty;
    errdefer {
        for (peers.items) |peer| allocator.free(peer);
        peers.deinit(allocator);
    }
    for (0..@min(compact.len / 18, 64)) |index| {
        const entry = compact[index * 18 ..][0..18];
        const port = std.mem.readInt(u16, entry[16..18], .big);
        if (port == 0) continue;
        const address = try std.fmt.allocPrint(allocator, "[{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}]:{d}", .{
            entry[0], entry[1], entry[2],  entry[3],  entry[4],  entry[5],  entry[6],  entry[7],
            entry[8], entry[9], entry[10], entry[11], entry[12], entry[13], entry[14], entry[15],
            port,
        });
        try peers.append(allocator, address);
    }
    return peers.toOwnedSlice(allocator);
}

fn peersFromExpanded(allocator: Allocator, encoded: []const u8) ![][]u8 {
    var peers: std.ArrayList([]u8) = .empty;
    errdefer {
        for (peers.items) |peer| allocator.free(peer);
        peers.deinit(allocator);
    }
    if (encoded.len == 0) return peers.toOwnedSlice(allocator);
    if (encoded[0] != 'l') return error.InvalidTrackerResponse;
    var cursor: usize = 1;
    while (cursor < encoded.len and encoded[cursor] != 'e') {
        if (cursor >= encoded.len or encoded[cursor] != 'd') return error.InvalidTrackerResponse;
        cursor += 1;
        var host: ?[]const u8 = null;
        var port: ?u16 = null;
        while (cursor < encoded.len and encoded[cursor] != 'e') {
            const key = try parseString(encoded, &cursor);
            if (std.mem.eql(u8, key, "ip")) {
                if (host != null) return error.InvalidTrackerResponse;
                host = try parseString(encoded, &cursor);
            } else if (std.mem.eql(u8, key, "port")) {
                if (port != null) return error.InvalidTrackerResponse;
                const value = try parseUnsigned(encoded, &cursor);
                if (value == 0 or value > 65535) return error.InvalidTrackerResponse;
                port = @intCast(value);
            } else try skipValue(encoded, &cursor, 0);
        }
        if (cursor >= encoded.len) return error.InvalidTrackerResponse;
        cursor += 1;
        const address = host orelse return error.InvalidTrackerResponse;
        const peer_port = port orelse return error.InvalidTrackerResponse;
        if (address.len == 0 or address.len > 253 or !std.unicode.utf8ValidateSlice(address)) return error.InvalidTrackerResponse;
        for (address) |byte| if (byte < 0x21 or byte > 0x7e or byte == '/' or byte == '@' or byte == '[' or byte == ']') return error.InvalidTrackerResponse;
        const ipv6 = std.mem.indexOfScalar(u8, address, ':') != null;
        if (ipv6) {
            _ = Io.net.IpAddress.parseIp6(address, peer_port) catch return error.InvalidTrackerResponse;
        } else {
            _ = Io.net.HostName.init(address) catch return error.InvalidTrackerResponse;
        }
        if (peers.items.len < 64) {
            const value = if (ipv6)
                try std.fmt.allocPrint(allocator, "[{s}]:{d}", .{ address, peer_port })
            else
                try std.fmt.allocPrint(allocator, "{s}:{d}", .{ address, peer_port });
            errdefer allocator.free(value);
            try peers.append(allocator, value);
        }
    }
    if (cursor + 1 != encoded.len) return error.InvalidTrackerResponse;
    return peers.toOwnedSlice(allocator);
}

fn percentEncode(bytes: []const u8) [60]u8 {
    var output: [60]u8 = undefined;
    const alphabet = "0123456789ABCDEF";
    for (bytes, 0..) |byte, index| {
        output[index * 3] = '%';
        output[index * 3 + 1] = alphabet[byte >> 4];
        output[index * 3 + 2] = alphabet[byte & 0x0f];
    }
    return output;
}

const CompactPeers = struct { ipv4: []const u8 = "", ipv6: []const u8 = "", expanded: []const u8 = "", has_peers: bool = false, counts: TrackerCounts = .{} };

fn parseTrackerPeers(bytes: []const u8, retry_delay_seconds: *?u32) !CompactPeers {
    if (bytes.len < 2 or bytes[0] != 'd') return error.InvalidTrackerResponse;
    var cursor: usize = 1;
    var peers: CompactPeers = .{};
    var failed = false;
    var retry_never = false;
    while (cursor < bytes.len and bytes[cursor] != 'e') {
        const key = try parseString(bytes, &cursor);
        if (std.mem.eql(u8, key, "peers")) {
            peers.has_peers = true;
            if (cursor < bytes.len and bytes[cursor] == 'l') {
                const start = cursor;
                try skipValue(bytes, &cursor, 0);
                peers.expanded = bytes[start..cursor];
            } else peers.ipv4 = try parseString(bytes, &cursor);
        } else if (std.mem.eql(u8, key, "peers6")) {
            peers.has_peers = true;
            peers.ipv6 = try parseString(bytes, &cursor);
        } else if (std.mem.eql(u8, key, "interval") or std.mem.eql(u8, key, "min interval")) {
            const seconds = @min(try parseUnsigned(bytes, &cursor), 3600);
            peers.counts.retry_delay_seconds = @max(peers.counts.retry_delay_seconds orelse 0, @as(u32, @intCast(seconds)));
        } else if (std.mem.eql(u8, key, "complete")) {
            peers.counts.seeders = std.math.cast(u32, try parseUnsigned(bytes, &cursor)) orelse return error.InvalidTrackerResponse;
        } else if (std.mem.eql(u8, key, "incomplete")) {
            peers.counts.leechers = std.math.cast(u32, try parseUnsigned(bytes, &cursor)) orelse return error.InvalidTrackerResponse;
        } else if (std.mem.eql(u8, key, "failure reason")) {
            _ = try parseString(bytes, &cursor);
            failed = true;
        } else if (std.mem.eql(u8, key, "retry in")) {
            if (cursor < bytes.len and bytes[cursor] == 'i') {
                const minutes = @min(try parseUnsigned(bytes, &cursor), 60);
                retry_delay_seconds.* = @max(@as(u32, 1), @as(u32, @intCast(minutes)) * 60);
            } else {
                const value = try parseString(bytes, &cursor);
                if (std.mem.eql(u8, value, "never")) {
                    retry_never = true;
                } else {
                    if (value.len == 0) return error.InvalidTrackerResponse;
                    var minutes: u32 = 0;
                    for (value) |digit| {
                        if (!std.ascii.isDigit(digit)) return error.InvalidTrackerResponse;
                        minutes = @min(minutes *| 10 +| (digit - '0'), 60);
                    }
                    retry_delay_seconds.* = @max(@as(u32, 1), minutes * 60);
                }
            }
        } else try skipValue(bytes, &cursor, 0);
    }
    if (cursor + 1 != bytes.len) return error.InvalidTrackerResponse;
    if (failed) {
        if (retry_never) {
            retry_delay_seconds.* = null;
            return error.TrackerRejected;
        }
        if (retry_delay_seconds.* != null) return error.TrackerRetryRequested;
        return error.TrackerRejected;
    }
    retry_delay_seconds.* = null;
    if (!peers.has_peers) return error.NoTrackerPeers;
    if (peers.ipv4.len % 6 != 0 or peers.ipv6.len % 18 != 0) return error.InvalidTrackerResponse;
    return peers;
}

fn fetchPeer(allocator: Allocator, io: Io, address: []const u8, info_hash: [20]u8, session: *const Session, control: ?CheckpointCallback, control_context: ?*anyopaque) ![]u8 {
    const separator = std.mem.lastIndexOfScalar(u8, address, ':') orelse return error.InvalidPeerAddress;
    const port = std.fmt.parseInt(u16, address[separator + 1 ..], 10) catch return error.InvalidPeerAddress;
    const host = address[0..separator];
    if (host.len == 0 or port == 0) return error.InvalidPeerAddress;
    const stream = if (host[0] == '[') blk: {
        const ip = Io.net.IpAddress.parseIp6(host[1 .. host.len - 1], port) catch return error.InvalidPeerAddress;
        break :blk try @import("../../core/net_connect.zig").address(io, ip, 10_000);
    } else blk: {
        const peer_host = Io.net.HostName.init(host) catch return error.InvalidPeerAddress;
        break :blk try @import("../../core/net_connect.zig").host(io, peer_host, port, 10_000);
    };
    defer stream.close(io);
    var write_buffer: [4096]u8 = undefined;
    var wire = Wire{ .io = io, .stream = stream, .writer = stream.writer(io, &write_buffer) };

    var hello: [68]u8 = @splat(0);
    hello[0] = 19;
    @memcpy(hello[1..20], "BitTorrent protocol");
    hello[25] = 0x10;
    @memcpy(hello[28..48], &info_hash);
    @memcpy(hello[48..68], &session.peer_id);
    try wire.send(&hello);
    var response: [68]u8 = undefined;
    try wire.readExact(&response);
    if (response[0] != 19 or !std.mem.eql(u8, response[1..20], "BitTorrent protocol") or
        !std.mem.eql(u8, response[28..48], &info_hash) or response[25] & 0x10 == 0)
        return error.PeerHandshakeMismatch;

    try wire.sendExtended(0, "d1:md11:ut_metadatai1eee");
    var peer_extension: ?u8 = null;
    var metadata_size: ?usize = null;
    var messages: usize = 0;
    while (peer_extension == null or metadata_size == null) {
        try checkpoint(control, control_context);
        messages += 1;
        if (messages > 64) return error.PeerMetadataUnavailable;
        const frame = try wire.readFrame(allocator);
        defer allocator.free(frame);
        if (frame.len < 2 or frame[0] != 20 or frame[1] != 0) continue;
        const header = try parseDictionary(frame[2..]);
        if (header.metadata_size) |size| {
            if (size == 0 or size > metainfo.max_metainfo_bytes) return error.MetadataTooLarge;
            metadata_size = size;
        }
        if (header.ut_metadata) |extension| {
            if (extension == 0) return error.PeerMetadataUnavailable;
            peer_extension = extension;
        }
    }
    const size = metadata_size.?;
    const metadata = try allocator.alloc(u8, size);
    errdefer allocator.free(metadata);
    const blocks = (size + block_size - 1) / block_size;
    if (blocks > max_metadata_blocks) return error.MetadataTooLarge;
    var received: [max_metadata_blocks]bool = @splat(false);
    var requested_blocks: usize = 0;
    var received_blocks: usize = 0;
    var idle_messages: usize = 0;
    while (received_blocks < blocks) {
        try checkpoint(control, control_context);
        while (requested_blocks < blocks and requested_blocks - received_blocks < max_in_flight_blocks) {
            const request = try std.fmt.allocPrint(allocator, "d8:msg_typei0e5:piecei{d}ee", .{requested_blocks});
            defer allocator.free(request);
            try wire.sendExtended(peer_extension.?, request);
            requested_blocks += 1;
        }
        const frame = try wire.readFrame(allocator);
        defer allocator.free(frame);
        if (frame.len < 2 or frame[0] != 20 or frame[1] != 1) {
            idle_messages += 1;
            if (idle_messages > 64) return error.MetadataPieceUnavailable;
            continue;
        }
        const header = try parseDictionary(frame[2..]);
        const index = header.piece orelse return error.InvalidMetadataPiece;
        if (index >= requested_blocks or header.msg_type == null) return error.InvalidMetadataPiece;
        if (header.msg_type.? == 2) return error.MetadataPieceRejected;
        if (header.msg_type.? != 1) {
            idle_messages += 1;
            if (idle_messages > 64) return error.MetadataPieceUnavailable;
            continue;
        }
        if (header.total_size != size) return error.InvalidMetadataPiece;
        const offset = index * block_size;
        const expected = @min(block_size, size - offset);
        const payload = frame[2 + header.end ..];
        if (payload.len != expected) return error.InvalidMetadataPiece;
        if (received[index]) {
            idle_messages += 1;
            if (idle_messages > 64) return error.MetadataPieceUnavailable;
            continue;
        }
        @memcpy(metadata[offset .. offset + expected], payload);
        received[index] = true;
        received_blocks += 1;
        idle_messages = 0;
    }
    var digest: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(metadata, &digest, .{});
    if (!std.mem.eql(u8, &digest, &info_hash)) return error.MetadataHashMismatch;
    return metadata;
}

const Wire = struct {
    io: Io,
    stream: Io.net.Stream,
    writer: Io.net.Stream.Writer,

    fn send(self: *Wire, bytes: []const u8) !void {
        try self.writer.interface.writeAll(bytes);
        try self.writer.interface.flush();
    }

    fn sendExtended(self: *Wire, extension: u8, payload: []const u8) !void {
        const length: u32 = @intCast(payload.len + 2);
        const prefix = [6]u8{ @intCast(length >> 24), @intCast((length >> 16) & 0xff), @intCast((length >> 8) & 0xff), @intCast(length & 0xff), 20, extension };
        try self.writer.interface.writeAll(&prefix);
        try self.send(payload);
    }

    fn readExact(self: *Wire, output: []u8) !void {
        var offset: usize = 0;
        while (offset < output.len) {
            var buffers: [1][]u8 = .{output[offset..]};
            const result = try self.io.operateTimeout(.{ .net_read = .{ .socket_handle = self.stream.socket.handle, .data = &buffers } }, timeout);
            const amount = (try result.net_read).data_len;
            if (amount == 0) return error.PeerClosed;
            offset += amount;
        }
    }

    fn readFrame(self: *Wire, allocator: Allocator) ![]u8 {
        var prefix: [4]u8 = undefined;
        try self.readExact(&prefix);
        const length = std.mem.readInt(u32, &prefix, .big);
        if (length == 0) return allocator.alloc(u8, 0);
        if (length > max_message) return error.PeerMessageTooLarge;
        const frame = try allocator.alloc(u8, length);
        errdefer allocator.free(frame);
        try self.readExact(frame);
        return frame;
    }
};

const Header = struct {
    end: usize = 0,
    metadata_size: ?usize = null,
    ut_metadata: ?u8 = null,
    msg_type: ?usize = null,
    piece: ?usize = null,
    total_size: ?usize = null,
};

fn parseDictionary(bytes: []const u8) !Header {
    if (bytes.len < 2 or bytes[0] != 'd') return error.InvalidPeerMessage;
    var cursor: usize = 1;
    var result: Header = .{};
    while (cursor < bytes.len and bytes[cursor] != 'e') {
        const key = try parseString(bytes, &cursor);
        if (std.mem.eql(u8, key, "m")) {
            if (cursor >= bytes.len or bytes[cursor] != 'd') return error.InvalidPeerMessage;
            cursor += 1;
            while (cursor < bytes.len and bytes[cursor] != 'e') {
                const extension_name = try parseString(bytes, &cursor);
                if (std.mem.eql(u8, extension_name, "ut_metadata")) {
                    const number = try parseUnsigned(bytes, &cursor);
                    if (number > 255) return error.InvalidPeerMessage;
                    result.ut_metadata = @intCast(number);
                } else try skipValue(bytes, &cursor, 0);
            }
            if (cursor >= bytes.len) return error.InvalidPeerMessage;
            cursor += 1;
        } else if (std.mem.eql(u8, key, "metadata_size")) {
            result.metadata_size = try parseUnsigned(bytes, &cursor);
        } else if (std.mem.eql(u8, key, "msg_type")) {
            result.msg_type = try parseUnsigned(bytes, &cursor);
        } else if (std.mem.eql(u8, key, "piece")) {
            result.piece = try parseUnsigned(bytes, &cursor);
        } else if (std.mem.eql(u8, key, "total_size")) {
            result.total_size = try parseUnsigned(bytes, &cursor);
        } else try skipValue(bytes, &cursor, 0);
    }
    if (cursor >= bytes.len) return error.InvalidPeerMessage;
    result.end = cursor + 1;
    return result;
}

fn parseString(bytes: []const u8, cursor: *usize) ![]const u8 {
    const start = cursor.*;
    while (cursor.* < bytes.len and std.ascii.isDigit(bytes[cursor.*])) cursor.* += 1;
    if (start == cursor.* or cursor.* >= bytes.len or bytes[cursor.*] != ':') return error.InvalidPeerMessage;
    const length = std.fmt.parseInt(usize, bytes[start..cursor.*], 10) catch return error.InvalidPeerMessage;
    cursor.* += 1;
    if (length > bytes.len - cursor.*) return error.InvalidPeerMessage;
    const value = bytes[cursor.* .. cursor.* + length];
    cursor.* += length;
    return value;
}

fn parseUnsigned(bytes: []const u8, cursor: *usize) !usize {
    if (cursor.* >= bytes.len or bytes[cursor.*] != 'i') return error.InvalidPeerMessage;
    cursor.* += 1;
    const start = cursor.*;
    while (cursor.* < bytes.len and std.ascii.isDigit(bytes[cursor.*])) cursor.* += 1;
    if (start == cursor.* or cursor.* >= bytes.len or bytes[cursor.*] != 'e') return error.InvalidPeerMessage;
    const value = std.fmt.parseInt(usize, bytes[start..cursor.*], 10) catch return error.InvalidPeerMessage;
    cursor.* += 1;
    return value;
}

fn skipValue(bytes: []const u8, cursor: *usize, depth: usize) !void {
    if (depth > 8 or cursor.* >= bytes.len) return error.InvalidPeerMessage;
    switch (bytes[cursor.*]) {
        '0'...'9' => _ = try parseString(bytes, cursor),
        'i' => _ = try parseUnsigned(bytes, cursor),
        'l', 'd' => |marker| {
            cursor.* += 1;
            while (cursor.* < bytes.len and bytes[cursor.*] != 'e') {
                if (marker == 'd') _ = try parseString(bytes, cursor);
                try skipValue(bytes, cursor, depth + 1);
            }
            if (cursor.* >= bytes.len) return error.InvalidPeerMessage;
            cursor.* += 1;
        },
        else => return error.InvalidPeerMessage,
    }
}
