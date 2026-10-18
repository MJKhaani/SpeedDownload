//! Bounded BEP 9 magnet URI inspection.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Result = struct {
    info_hash: [20]u8,
    display_name: ?[]u8,
    trackers: [][]u8,
    peers: [][]u8,

    pub fn deinit(self: *Result, allocator: Allocator) void {
        if (self.display_name) |name| allocator.free(name);
        for (self.trackers) |tracker| allocator.free(tracker);
        allocator.free(self.trackers);
        for (self.peers) |peer| allocator.free(peer);
        allocator.free(self.peers);
    }
};

pub fn inspect(allocator: Allocator, uri: []const u8) !Result {
    if (uri.len > 16 * 1024) return error.MagnetTooLong;
    if (uri.len < 8 or !std.ascii.eqlIgnoreCase(uri[0..7], "magnet:") or uri[7] != '?') return error.InvalidMagnetUri;
    if (std.mem.indexOfScalar(u8, uri, '#') != null) return error.InvalidMagnetUri;
    var hash: ?[20]u8 = null;
    var name: ?[]u8 = null;
    errdefer if (name) |value| allocator.free(value);
    var trackers: std.ArrayList([]u8) = .empty;
    errdefer {
        for (trackers.items) |tracker| allocator.free(tracker);
        trackers.deinit(allocator);
    }
    var peers: std.ArrayList([]u8) = .empty;
    errdefer {
        for (peers.items) |peer| allocator.free(peer);
        peers.deinit(allocator);
    }
    var saw_v2 = false;
    var count: usize = 0;
    var parts = std.mem.splitScalar(u8, uri[8..], '&');
    while (parts.next()) |part| {
        count += 1;
        if (count > 128) return error.MagnetTooComplex;
        const equal = std.mem.indexOfScalar(u8, part, '=') orelse return error.InvalidMagnetUri;
        const key = part[0..equal];
        const value = try percentDecode(allocator, part[equal + 1 ..]);
        defer allocator.free(value);
        if (std.mem.eql(u8, key, "xt")) {
            if (value.len >= 9 and std.ascii.eqlIgnoreCase(value[0..9], "urn:btih:")) {
                const candidate = try decodeHash(value[9..]);
                if (hash) |existing| {
                    if (!std.mem.eql(u8, &existing, &candidate)) return error.ConflictingInfoHash;
                } else hash = candidate;
            } else if (value.len >= 9 and std.ascii.eqlIgnoreCase(value[0..9], "urn:btmh:")) {
                saw_v2 = true;
            }
        } else if (std.mem.eql(u8, key, "dn")) {
            if (name != null or value.len == 0 or value.len > 255 or !std.unicode.utf8ValidateSlice(value) or hasControl(value)) return error.InvalidDisplayName;
            name = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, key, "tr")) {
            if (value.len == 0 or value.len > 2048 or hasControl(value)) return error.InvalidTracker;
            const parsed = std.Uri.parse(value) catch return error.InvalidTracker;
            if (parsed.host == null or parsed.user != null or parsed.password != null or parsed.fragment != null or
                !(std.ascii.eqlIgnoreCase(parsed.scheme, "http") or std.ascii.eqlIgnoreCase(parsed.scheme, "https") or std.ascii.eqlIgnoreCase(parsed.scheme, "udp"))) return error.InvalidTracker;
            var duplicate = false;
            for (trackers.items) |tracker| {
                if (std.mem.eql(u8, tracker, value)) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;
            if (trackers.items.len >= 32) return error.InvalidTracker;
            try trackers.append(allocator, try allocator.dupe(u8, value));
        } else if (std.mem.eql(u8, key, "x.pe")) {
            if (peers.items.len >= 16 or value.len == 0 or value.len > 255 or hasControl(value)) return error.InvalidPeerAddress;
            const separator = std.mem.lastIndexOfScalar(u8, value, ':') orelse return error.InvalidPeerAddress;
            const host = value[0..separator];
            const port = std.fmt.parseInt(u16, value[separator + 1 ..], 10) catch return error.InvalidPeerAddress;
            if (host.len == 0 or port == 0 or std.mem.indexOfAny(u8, host, "/?#@") != null) return error.InvalidPeerAddress;
            if (host[0] == '[' and (host[host.len - 1] != ']' or host.len < 3)) return error.InvalidPeerAddress;
            try peers.append(allocator, try allocator.dupe(u8, value));
        }
    }
    const info_hash = hash orelse return if (saw_v2) error.UnsupportedMagnetV2 else error.MissingInfoHash;
    const owned_trackers = try trackers.toOwnedSlice(allocator);
    errdefer {
        for (owned_trackers) |tracker| allocator.free(tracker);
        allocator.free(owned_trackers);
    }
    return .{ .info_hash = info_hash, .display_name = name, .trackers = owned_trackers, .peers = try peers.toOwnedSlice(allocator) };
}

fn hasControl(value: []const u8) bool {
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return true;
    return false;
}

fn percentDecode(allocator: Allocator, value: []const u8) ![]u8 {
    const result = try allocator.alloc(u8, value.len);
    errdefer allocator.free(result);
    var source: usize = 0;
    var target: usize = 0;
    while (source < value.len) {
        if (value[source] == '%') {
            if (source + 2 >= value.len) return error.InvalidPercentEncoding;
            const high = std.fmt.charToDigit(value[source + 1], 16) catch return error.InvalidPercentEncoding;
            const low = std.fmt.charToDigit(value[source + 2], 16) catch return error.InvalidPercentEncoding;
            result[target] = high * 16 + low;
            source += 3;
        } else {
            result[target] = value[source];
            source += 1;
        }
        target += 1;
    }
    return allocator.realloc(result, target);
}

fn decodeHash(value: []const u8) ![20]u8 {
    var result: [20]u8 = undefined;
    if (value.len == 40) {
        _ = std.fmt.hexToBytes(&result, value) catch return error.InvalidInfoHash;
        return result;
    }
    if (value.len != 32) return error.InvalidInfoHash;
    var bits: u16 = 0;
    var bit_count: u8 = 0;
    var output: usize = 0;
    for (value) |char| {
        const upper = std.ascii.toUpper(char);
        const digit: u8 = if (upper >= 'A' and upper <= 'Z') upper - 'A' else if (upper >= '2' and upper <= '7') upper - '2' + 26 else return error.InvalidInfoHash;
        bits = (bits << 5) | digit;
        bit_count += 5;
        if (bit_count >= 8) {
            bit_count -= 8;
            result[output] = @intCast((bits >> @intCast(bit_count)) & 0xff);
            output += 1;
            bits &= (@as(u16, 1) << @intCast(bit_count)) - 1;
        }
    }
    return result;
}
