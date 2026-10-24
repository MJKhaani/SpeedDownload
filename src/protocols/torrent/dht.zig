//! Bounded, read-only BEP 5 get_peers lookup for public v1 torrents.
//! No listener, routing table, or announce_peer is exposed by this module.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const control_contract = @import("control.zig");

const max_nodes = 96;
const max_queries = 32;
const max_peers = 64;
const packet_limit = 2048;

const Node = struct { id: ?[20]u8, address: Io.net.IpAddress };
const Response = struct { id: ?[20]u8 = null, nodes: []const u8 = "", nodes6: []const u8 = "", values: [64][]const u8 = undefined, values_len: usize = 0 };

pub fn discover(allocator: Allocator, io: Io, info_hash: [20]u8, control: ?control_contract.CheckpointCallback, context: ?*anyopaque) ![][]u8 {
    var nodes: [max_nodes]Node = undefined;
    var node_count: usize = 0;
    for ([_][]const u8{ "router.bittorrent.com", "router.utorrent.com" }) |host| {
        const name = Io.net.HostName.init(host) catch continue;
        var buffer: [8]Io.net.HostName.LookupResult = undefined;
        var results: Io.Queue(Io.net.HostName.LookupResult) = .init(&buffer);
        name.lookup(io, &results, .{ .port = 6881 }) catch continue;
        while (results.getOne(io)) |entry| {
            if (entry != .address) continue;
            addNode(&nodes, &node_count, .{ .id = null, .address = entry.address });
            break;
        } else |_| {}
    }
    if (node_count == 0) return error.DhtBootstrapUnavailable;

    var own_id: [20]u8 = undefined;
    try io.randomSecure(&own_id);
    var peers: std.ArrayList([]u8) = .empty;
    errdefer {
        for (peers.items) |peer| allocator.free(peer);
        peers.deinit(allocator);
    }
    var queried: [max_nodes]bool = @splat(false);
    var query_count: usize = 0;
    while (query_count < max_queries and peers.items.len < max_peers) : (query_count += 1) {
        try control_contract.checkpoint(control, context);
        const next = closestUnqueried(&nodes, node_count, &queried, info_hash) orelse break;
        queried[next] = true;
        const node = nodes[next];
        const response = query(allocator, io, node.address, own_id, info_hash) catch continue;
        defer allocator.free(response);
        const decoded = parseResponse(response) catch continue;
        nodes[next].id = decoded.id;
        for (decoded.values[0..decoded.values_len]) |compact| {
            if (peers.items.len == max_peers) break;
            const address = compactAddress(compact) orelse continue;
            const peer = try addressText(allocator, address);
            var duplicate = false;
            for (peers.items) |existing| if (std.mem.eql(u8, existing, peer)) {
                duplicate = true;
                break;
            };
            if (duplicate) allocator.free(peer) else peers.append(allocator, peer) catch |err| {
                allocator.free(peer);
                return err;
            };
        }
        appendNodes(&nodes, &node_count, &queried, info_hash, decoded.nodes, false);
        appendNodes(&nodes, &node_count, &queried, info_hash, decoded.nodes6, true);
    }
    try control_contract.checkpoint(control, context);
    return peers.toOwnedSlice(allocator);
}

/// Query bootstrap contacts first, then the unqueried contact with the
/// smallest BEP 5 XOR distance to the target hash. The set is bounded, so a
/// linear scan avoids maintaining a second heap or unbounded routing table.
fn closestUnqueried(nodes: *const [max_nodes]Node, count: usize, queried: *const [max_nodes]bool, target: [20]u8) ?usize {
    var best: ?usize = null;
    for (nodes[0..count], 0..) |node, index| {
        if (queried[index]) continue;
        if (best == null) {
            best = index;
            continue;
        }
        const previous = nodes[best.?];
        if (node.id == null) {
            continue;
        }
        if (previous.id == null) {
            best = index;
            continue;
        }
        if (closer(node.id.?, previous.id.?, target)) best = index;
    }
    return best;
}

fn addNode(nodes: *[max_nodes]Node, count: *usize, node: Node) void {
    switch (node.address) {
        .ip4 => |ip| if (!publicIp4(ip.bytes)) return,
        .ip6 => |ip| if (!publicIp6(ip.bytes)) return,
    }
    for (nodes[0..count.*]) |*existing| if (std.meta.eql(existing.address, node.address)) {
        if (existing.id == null) existing.id = node.id;
        return;
    };
    if (count.* == max_nodes) return;
    nodes[count.*] = node;
    count.* += 1;
}

fn closer(candidate: [20]u8, previous: [20]u8, target: [20]u8) bool {
    for (0..20) |index| {
        const candidate_distance = candidate[index] ^ target[index];
        const previous_distance = previous[index] ^ target[index];
        if (candidate_distance != previous_distance) return candidate_distance < previous_distance;
    }
    return false;
}

/// Retain the closest unqueried contacts when a response exceeds the fixed
/// contact capacity. Queried contacts and bootstrap contacts with unknown IDs
/// stay in place; replacing them would lose query history or fallback paths.
fn addDiscoveredNode(nodes: *[max_nodes]Node, count: *usize, queried: *[max_nodes]bool, target: [20]u8, node: Node) void {
    for (nodes[0..count.*]) |*existing| if (std.meta.eql(existing.address, node.address)) {
        if (existing.id == null) existing.id = node.id;
        return;
    };
    if (count.* < max_nodes) {
        addNode(nodes, count, node);
        return;
    }
    const candidate_id = node.id orelse return;
    var farthest: ?usize = null;
    for (nodes[0..count.*], 0..) |existing, index| {
        if (queried[index] or existing.id == null) continue;
        if (farthest == null or closer(nodes[farthest.?].id.?, existing.id.?, target)) farthest = index;
    }
    if (farthest) |index| {
        if (closer(candidate_id, nodes[index].id.?, target)) nodes[index] = node;
    }
}

fn appendNodes(nodes: *[max_nodes]Node, count: *usize, queried: *[max_nodes]bool, target: [20]u8, compact: []const u8, ipv6: bool) void {
    const stride: usize = if (ipv6) 38 else 26;
    if (compact.len % stride != 0) return;
    for (0..compact.len / stride) |index| {
        const entry = compact[index * stride ..][0..stride];
        const address = compactAddress(entry[20..]) orelse continue;
        addDiscoveredNode(nodes, count, queried, target, .{ .id = entry[0..20].*, .address = address });
    }
}

fn compactAddress(bytes: []const u8) ?Io.net.IpAddress {
    if (bytes.len == 6) {
        const port = std.mem.readInt(u16, bytes[4..6], .big);
        if (port == 0 or !publicIp4(bytes[0..4].*)) return null;
        return .{ .ip4 = .{ .bytes = bytes[0..4].*, .port = port } };
    }
    if (bytes.len == 18) {
        const port = std.mem.readInt(u16, bytes[16..18], .big);
        if (port == 0 or !publicIp6(bytes[0..16].*)) return null;
        return .{ .ip6 = .{ .bytes = bytes[0..16].*, .port = port } };
    }
    return null;
}

fn publicIp4(ip: [4]u8) bool {
    if (ip[0] == 0 or ip[0] == 10 or ip[0] == 127 or ip[0] >= 224 or
        (ip[0] == 100 and ip[1] >= 64 and ip[1] <= 127) or
        (ip[0] == 169 and ip[1] == 254) or
        (ip[0] == 172 and ip[1] >= 16 and ip[1] <= 31) or
        (ip[0] == 192 and (ip[1] == 168 or ip[1] == 0)) or
        (ip[0] == 198 and (ip[1] == 18 or ip[1] == 19))) return false;
    return true;
}

fn publicIp6(ip: [16]u8) bool {
    if (std.mem.eql(u8, ip[0..12], &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff }))
        return publicIp4(ip[12..16].*);
    if (ip[0] == 0xff or (ip[0] & 0xfe) == 0xfc or
        (ip[0] == 0xfe and (ip[1] & 0xc0) == 0x80)) return false;
    var all_zero = true;
    for (ip[0..15]) |byte| if (byte != 0) {
        all_zero = false;
        break;
    };
    if (all_zero) return false; // unspecified and loopback
    return true;
}

fn addressText(allocator: Allocator, address: Io.net.IpAddress) ![]u8 {
    return switch (address) {
        .ip4 => |ip| std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}:{d}", .{ ip.bytes[0], ip.bytes[1], ip.bytes[2], ip.bytes[3], ip.port }),
        .ip6 => |ip| std.fmt.allocPrint(allocator, "[{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}:{x:0>2}{x:0>2}]:{d}", .{
            ip.bytes[0], ip.bytes[1], ip.bytes[2],  ip.bytes[3],  ip.bytes[4],  ip.bytes[5],  ip.bytes[6],  ip.bytes[7],
            ip.bytes[8], ip.bytes[9], ip.bytes[10], ip.bytes[11], ip.bytes[12], ip.bytes[13], ip.bytes[14], ip.bytes[15],
            ip.port,
        }),
    };
}

fn query(allocator: Allocator, io: Io, address: Io.net.IpAddress, own_id: [20]u8, hash: [20]u8) ![]u8 {
    const local: Io.net.IpAddress = switch (address) {
        .ip4 => .{ .ip4 = .unspecified(0) },
        .ip6 => .{ .ip6 = .unspecified(0) },
    };
    const socket = try local.bind(io, .{ .mode = .dgram });
    defer socket.close(io);
    var transaction: [2]u8 = undefined;
    try io.randomSecure(&transaction);
    var request: std.ArrayList(u8) = .empty;
    defer request.deinit(allocator);
    try request.appendSlice(allocator, "d1:ad2:id20:");
    try request.appendSlice(allocator, &own_id);
    try request.appendSlice(allocator, "9:info_hash20:");
    try request.appendSlice(allocator, &hash);
    try request.appendSlice(allocator, "e1:q9:get_peers1:t2:");
    try request.appendSlice(allocator, &transaction);
    try request.appendSlice(allocator, "1:y1:qe");
    const deadline: Io.Timeout = (Io.Timeout{ .duration = .{ .raw = .fromMilliseconds(1000), .clock = .awake } }).toDeadline(io);
    try socket.sendTimeout(io, &address, request.items, deadline);
    var buffer: [packet_limit]u8 = undefined;
    for (0..4) |_| {
        const packet = try socket.receiveTimeout(io, &buffer, deadline);
        if (packet.flags.trunc or !std.meta.eql(packet.from, address) or packet.data.len > packet_limit) continue;
        if (!responseTransaction(packet.data, &transaction)) continue;
        return allocator.dupe(u8, packet.data);
    }
    return error.DhtNoResponse;
}

fn responseTransaction(bytes: []const u8, transaction: *const [2]u8) bool {
    if (bytes.len < 4 or bytes[0] != 'd') return false;
    var cursor: usize = 1;
    while (cursor < bytes.len and bytes[cursor] != 'e') {
        const key = parseString(bytes, &cursor) catch return false;
        if (std.mem.eql(u8, key, "t")) {
            const value = parseString(bytes, &cursor) catch return false;
            return std.mem.eql(u8, value, transaction);
        }
        skip(bytes, &cursor, 0) catch return false;
    }
    return false;
}

fn parseResponse(bytes: []const u8) !Response {
    if (bytes.len < 4 or bytes[0] != 'd') return error.InvalidDhtResponse;
    var cursor: usize = 1;
    var result: Response = .{};
    var success = false;
    while (cursor < bytes.len and bytes[cursor] != 'e') {
        const key = try parseString(bytes, &cursor);
        if (std.mem.eql(u8, key, "y")) {
            success = std.mem.eql(u8, try parseString(bytes, &cursor), "r");
        } else if (std.mem.eql(u8, key, "r")) {
            try parseResult(bytes, &cursor, &result);
        } else try skip(bytes, &cursor, 0);
    }
    if (cursor + 1 != bytes.len or !success) return error.InvalidDhtResponse;
    return result;
}

fn parseResult(bytes: []const u8, cursor: *usize, result: *Response) !void {
    if (cursor.* >= bytes.len or bytes[cursor.*] != 'd') return error.InvalidDhtResponse;
    cursor.* += 1;
    while (cursor.* < bytes.len and bytes[cursor.*] != 'e') {
        const key = try parseString(bytes, cursor);
        if (std.mem.eql(u8, key, "id")) {
            const id = try parseString(bytes, cursor);
            if (id.len != 20) return error.InvalidDhtResponse;
            result.id = id[0..20].*;
        } else if (std.mem.eql(u8, key, "nodes")) {
            result.nodes = try parseString(bytes, cursor);
        } else if (std.mem.eql(u8, key, "nodes6")) {
            result.nodes6 = try parseString(bytes, cursor);
        } else if (std.mem.eql(u8, key, "values")) {
            if (cursor.* >= bytes.len or bytes[cursor.*] != 'l') return error.InvalidDhtResponse;
            cursor.* += 1;
            while (cursor.* < bytes.len and bytes[cursor.*] != 'e') {
                const value = try parseString(bytes, cursor);
                if (result.values_len < result.values.len) {
                    result.values[result.values_len] = value;
                    result.values_len += 1;
                }
            }
            if (cursor.* >= bytes.len) return error.InvalidDhtResponse;
            cursor.* += 1;
        } else try skip(bytes, cursor, 0);
    }
    if (cursor.* >= bytes.len or result.id == null) return error.InvalidDhtResponse;
    cursor.* += 1;
}

fn parseString(bytes: []const u8, cursor: *usize) ![]const u8 {
    const start = cursor.*;
    while (cursor.* < bytes.len and std.ascii.isDigit(bytes[cursor.*])) cursor.* += 1;
    if (cursor.* == start or cursor.* >= bytes.len or bytes[cursor.*] != ':' or cursor.* - start > 5) return error.InvalidDhtResponse;
    const len = std.fmt.parseInt(usize, bytes[start..cursor.*], 10) catch return error.InvalidDhtResponse;
    cursor.* += 1;
    if (len > bytes.len - cursor.*) return error.InvalidDhtResponse;
    const value = bytes[cursor.* .. cursor.* + len];
    cursor.* += len;
    return value;
}

fn skip(bytes: []const u8, cursor: *usize, depth: usize) !void {
    if (depth > 8 or cursor.* >= bytes.len) return error.InvalidDhtResponse;
    switch (bytes[cursor.*]) {
        '0'...'9' => _ = try parseString(bytes, cursor),
        'i' => {
            cursor.* += 1;
            while (cursor.* < bytes.len and bytes[cursor.*] != 'e') cursor.* += 1;
            if (cursor.* >= bytes.len) return error.InvalidDhtResponse;
            cursor.* += 1;
        },
        'l', 'd' => |kind| {
            cursor.* += 1;
            while (cursor.* < bytes.len and bytes[cursor.*] != 'e') {
                if (kind == 'd') _ = try parseString(bytes, cursor);
                try skip(bytes, cursor, depth + 1);
            }
            if (cursor.* >= bytes.len) return error.InvalidDhtResponse;
            cursor.* += 1;
        },
        else => return error.InvalidDhtResponse,
    }
}
