//! Fetch BEP 9 info-dictionary blocks from explicit or HTTP-tracker peers.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const magnet = @import("magnet.zig");
const metainfo = @import("metainfo.zig");

const block_size = 16 * 1024;
const max_message = 128 * 1024;
const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(15_000), .clock = .awake } };

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

/// Fetch hash-verified metadata and retain the peer that supplied it. Both
/// owned slices must be released by the caller.
pub fn fetchWithSource(allocator: Allocator, io: Io, link: *const magnet.Result) !Fetched {
    var last_error: anyerror = error.NoReachablePeer;
    for (link.peers) |peer| {
        const bytes = fetchPeer(allocator, io, peer, link.info_hash) catch |err| {
            last_error = err;
            continue;
        };
        errdefer allocator.free(bytes);
        return .{ .info = bytes, .peer = try allocator.dupe(u8, peer) };
    }
    for (link.trackers) |tracker| {
        const parsed = std.Uri.parse(tracker) catch continue;
        const peers = discoverTrackerPeers(allocator, io, tracker, parsed, link.info_hash, 0, 1) catch |err| {
            last_error = err;
            continue;
        };
        defer {
            for (peers) |peer| allocator.free(peer);
            allocator.free(peers);
        }
        for (peers) |peer| {
            const bytes = fetchPeer(allocator, io, peer, link.info_hash) catch |err| {
                last_error = err;
                continue;
            };
            errdefer allocator.free(bytes);
            return .{ .info = bytes, .peer = try allocator.dupe(u8, peer) };
        }
    }
    return last_error;
}

/// Discover compact tracker peers for a transfer. `downloaded` counts verified
/// payload bytes; `total_bytes` comes from hash-verified torrent metadata.
/// The caller owns every returned address and the outer slice.
pub fn collectPeers(allocator: Allocator, io: Io, link: *const magnet.Result, downloaded: u64, total_bytes: u64) ![][]u8 {
    if (downloaded > total_bytes) return error.InvalidTorrentProgress;
    var peers: std.ArrayList([]u8) = .empty;
    errdefer {
        for (peers.items) |peer| allocator.free(peer);
        peers.deinit(allocator);
    }
    for (link.peers) |peer| try peers.append(allocator, try allocator.dupe(u8, peer));
    for (link.trackers) |tracker| {
        const parsed = std.Uri.parse(tracker) catch continue;
        const discovered = discoverTrackerPeers(allocator, io, tracker, parsed, link.info_hash, downloaded, total_bytes - downloaded) catch continue;
        defer allocator.free(discovered);
        for (discovered) |peer| {
            if (peers.items.len >= 80) {
                allocator.free(peer);
            } else try peers.append(allocator, peer);
        }
    }
    return peers.toOwnedSlice(allocator);
}

fn discoverTrackerPeers(allocator: Allocator, io: Io, tracker: []const u8, uri: std.Uri, info_hash: [20]u8, downloaded: u64, left: u64) ![][]u8 {
    if (std.ascii.eqlIgnoreCase(uri.scheme, "udp")) return discoverUdpPeers(allocator, io, uri, info_hash, downloaded, left);
    if (std.ascii.eqlIgnoreCase(uri.scheme, "http") or std.ascii.eqlIgnoreCase(uri.scheme, "https"))
        return discoverHttpPeers(allocator, io, tracker, info_hash, downloaded, left);
    return error.UnsupportedTrackerScheme;
}

fn discoverUdpPeers(allocator: Allocator, io: Io, uri: std.Uri, info_hash: [20]u8, downloaded: u64, left: u64) ![][]u8 {
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
    var peer_id: [20]u8 = undefined;
    try io.randomSecure(&peer_id);
    var key_bytes: [4]u8 = undefined;
    try io.randomSecure(&key_bytes);
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
        const found = discoverUdpPeersAtAddress(allocator, io, address, info_hash, downloaded, left, peer_id, key_bytes) catch |err| {
            last_error = err;
            continue;
        };
        succeeded = true;
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

fn discoverUdpPeersAtAddress(allocator: Allocator, io: Io, address: Io.net.IpAddress, info_hash: [20]u8, downloaded: u64, left: u64, peer_id: [20]u8, key_bytes: [4]u8) ![][]u8 {
    const local: Io.net.IpAddress = switch (address) {
        .ip4 => .{ .ip4 = .unspecified(0) },
        .ip6 => .{ .ip6 = .unspecified(0) },
    };
    const socket = try local.bind(io, .{ .mode = .dgram });
    defer socket.close(io);
    const udp_timeout: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(15_000), .clock = .awake } };
    var transaction_bytes: [4]u8 = undefined;
    try io.randomSecure(&transaction_bytes);
    const connect_transaction = std.mem.readInt(u32, &transaction_bytes, .big);
    var connect: [16]u8 = undefined;
    std.mem.writeInt(u64, connect[0..8], 0x41727101980, .big);
    std.mem.writeInt(u32, connect[8..12], 0, .big);
    std.mem.writeInt(u32, connect[12..16], connect_transaction, .big);
    try socket.sendTimeout(io, &address, &connect, udp_timeout);
    var response_buffer: [2048]u8 = undefined;
    const connected = try socket.receiveTimeout(io, &response_buffer, udp_timeout);
    if (connected.flags.trunc or !std.meta.eql(connected.from, address) or connected.data.len < 16 or
        std.mem.readInt(u32, connected.data[0..4], .big) != 0 or
        std.mem.readInt(u32, connected.data[4..8], .big) != connect_transaction)
        return error.InvalidTrackerResponse;
    const connection_id = std.mem.readInt(u64, connected.data[8..16], .big);

    try io.randomSecure(&transaction_bytes);
    const announce_transaction = std.mem.readInt(u32, &transaction_bytes, .big);
    var announce: [98]u8 = @splat(0);
    std.mem.writeInt(u64, announce[0..8], connection_id, .big);
    std.mem.writeInt(u32, announce[8..12], 1, .big);
    std.mem.writeInt(u32, announce[12..16], announce_transaction, .big);
    @memcpy(announce[16..36], &info_hash);
    @memcpy(announce[36..56], &peer_id);
    std.mem.writeInt(u64, announce[56..64], downloaded, .big);
    std.mem.writeInt(u64, announce[64..72], left, .big);
    std.mem.writeInt(u32, announce[80..84], 2, .big); // started
    @memcpy(announce[88..92], &key_bytes);
    std.mem.writeInt(u32, announce[92..96], 50, .big);
    try socket.sendTimeout(io, &address, &announce, udp_timeout);
    const received = try socket.receiveTimeout(io, &response_buffer, udp_timeout);
    const stride: usize = if (address == .ip4) 6 else 18;
    if (received.flags.trunc or !std.meta.eql(received.from, address) or received.data.len < 20 or
        std.mem.readInt(u32, received.data[0..4], .big) != 1 or
        std.mem.readInt(u32, received.data[4..8], .big) != announce_transaction or
        (received.data.len - 20) % stride != 0)
        return error.InvalidTrackerResponse;
    return if (address == .ip4)
        peersFromCompact(allocator, received.data[20..])
    else
        peersFromCompact6(allocator, received.data[20..]);
}

fn discoverHttpPeers(allocator: Allocator, io: Io, tracker: []const u8, info_hash: [20]u8, downloaded: u64, left: u64) ![][]u8 {
    var peer_id: [20]u8 = undefined;
    try io.randomSecure(&peer_id);
    const encoded_hash = percentEncode(&info_hash);
    const encoded_peer = percentEncode(&peer_id);
    const separator: []const u8 = if (std.mem.indexOfScalar(u8, tracker, '?') == null) "?" else "&";
    const url = try std.fmt.allocPrint(allocator, "{s}{s}info_hash={s}&peer_id={s}&port=0&uploaded=0&downloaded={d}&left={d}&compact=1&numwant=50", .{
        tracker, separator, &encoded_hash, &encoded_peer, downloaded, left,
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
    const compact = try parseTrackerPeers(bytes.items);
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

const CompactPeers = struct { ipv4: []const u8 = "", ipv6: []const u8 = "", expanded: []const u8 = "" };

fn parseTrackerPeers(bytes: []const u8) !CompactPeers {
    if (bytes.len < 2 or bytes[0] != 'd') return error.InvalidTrackerResponse;
    var cursor: usize = 1;
    var peers: CompactPeers = .{};
    while (cursor < bytes.len and bytes[cursor] != 'e') {
        const key = try parseString(bytes, &cursor);
        if (std.mem.eql(u8, key, "peers")) {
            if (cursor < bytes.len and bytes[cursor] == 'l') {
                const start = cursor;
                try skipValue(bytes, &cursor, 0);
                peers.expanded = bytes[start..cursor];
            } else peers.ipv4 = try parseString(bytes, &cursor);
        } else if (std.mem.eql(u8, key, "peers6")) {
            peers.ipv6 = try parseString(bytes, &cursor);
        } else if (std.mem.eql(u8, key, "failure reason")) {
            _ = try parseString(bytes, &cursor);
            return error.TrackerRejected;
        } else try skipValue(bytes, &cursor, 0);
    }
    if (cursor + 1 != bytes.len) return error.InvalidTrackerResponse;
    if (peers.ipv4.len == 0 and peers.ipv6.len == 0 and peers.expanded.len == 0) return error.NoTrackerPeers;
    if (peers.ipv4.len % 6 != 0 or peers.ipv6.len % 18 != 0) return error.InvalidTrackerResponse;
    return peers;
}

fn fetchPeer(allocator: Allocator, io: Io, address: []const u8, info_hash: [20]u8) ![]u8 {
    const separator = std.mem.lastIndexOfScalar(u8, address, ':') orelse return error.InvalidPeerAddress;
    const port = std.fmt.parseInt(u16, address[separator + 1 ..], 10) catch return error.InvalidPeerAddress;
    const host = address[0..separator];
    if (host.len == 0 or port == 0) return error.InvalidPeerAddress;
    const options: Io.net.IpAddress.ConnectOptions = .{
        .mode = .stream,
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(10_000), .clock = .awake } },
    };
    const stream = if (host[0] == '[') blk: {
        const ip = Io.net.IpAddress.parseIp6(host[1 .. host.len - 1], port) catch return error.InvalidPeerAddress;
        break :blk try ip.connect(io, options);
    } else blk: {
        const peer_host = Io.net.HostName.init(host) catch return error.InvalidPeerAddress;
        break :blk try peer_host.connect(io, port, options);
    };
    defer stream.close(io);
    var write_buffer: [4096]u8 = undefined;
    var wire = Wire{ .io = io, .stream = stream, .writer = stream.writer(io, &write_buffer) };

    var hello: [68]u8 = @splat(0);
    hello[0] = 19;
    @memcpy(hello[1..20], "BitTorrent protocol");
    hello[25] = 0x10;
    @memcpy(hello[28..48], &info_hash);
    try io.randomSecure(hello[48..68]);
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
    for (0..blocks) |index| {
        const request = try std.fmt.allocPrint(allocator, "d8:msg_typei0e5:piecei{d}ee", .{index});
        defer allocator.free(request);
        try wire.sendExtended(peer_extension.?, request);
        var attempts: usize = 0;
        while (true) {
            attempts += 1;
            if (attempts > 64) return error.MetadataPieceUnavailable;
            const frame = try wire.readFrame(allocator);
            defer allocator.free(frame);
            if (frame.len < 2 or frame[0] != 20 or frame[1] != 1) continue;
            const header = try parseDictionary(frame[2..]);
            if (header.piece != index or header.msg_type == null) continue;
            if (header.msg_type.? == 2) return error.MetadataPieceRejected;
            if (header.msg_type.? != 1 or header.total_size != size) return error.InvalidMetadataPiece;
            const offset = index * block_size;
            const expected = @min(block_size, size - offset);
            const payload = frame[2 + header.end ..];
            if (payload.len != expected) return error.InvalidMetadataPiece;
            @memcpy(metadata[offset .. offset + expected], payload);
            break;
        }
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
