//! Local torrent source URLs used only by the trusted desktop IPC client.
//! The decoded path is bounded and never included in public job summaries.
const std = @import("std");

pub fn isLocalTorrent(url: []const u8) bool {
    return url.len >= 13 and std.ascii.eqlIgnoreCase(url[0..13], "torrent-file:");
}

/// Decode `torrent-file:///absolute/path.torrent`; caller owns the path.
pub fn pathAlloc(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
    return pathAllocForPlatform(allocator, url, @import("builtin").os.tag == .windows);
}

fn pathAllocForPlatform(allocator: std.mem.Allocator, url: []const u8, windows: bool) ![]u8 {
    if (!isLocalTorrent(url) or url.len > 8192) return error.InvalidTorrentSource;
    const uri = std.Uri.parse(url) catch return error.InvalidTorrentSource;
    if (uri.user != null or uri.password != null or uri.port != null or uri.query != null or uri.fragment != null) return error.InvalidTorrentSource;
    if (uri.host) |host| {
        const value = switch (host) {
            .raw, .percent_encoded => |text| text,
        };
        if (value.len != 0) return error.InvalidTorrentSource;
    }
    const raw_path = switch (uri.path) {
        .raw, .percent_encoded => |text| text,
    };
    if (raw_path.len == 0 or raw_path.len > 4096) return error.InvalidTorrentSource;
    var index: usize = 0;
    while (index < raw_path.len) : (index += 1) {
        if (raw_path[index] != '%') continue;
        if (index + 2 >= raw_path.len or !std.ascii.isHex(raw_path[index + 1]) or !std.ascii.isHex(raw_path[index + 2])) return error.InvalidTorrentSource;
        index += 2;
    }
    const buffer = try allocator.dupe(u8, raw_path);
    const raw_decoded = std.Uri.percentDecodeInPlace(buffer);
    // File URLs carry a leading slash before a Windows drive letter.
    const decoded = if (windows and raw_decoded.len >= 3 and
        raw_decoded[0] == '/' and std.ascii.isAlphabetic(raw_decoded[1]) and raw_decoded[2] == ':')
        raw_decoded[1..]
    else
        raw_decoded;
    const absolute = if (windows) std.fs.path.isAbsoluteWindows(decoded) else std.fs.path.isAbsolutePosix(decoded);
    const basename = if (windows) std.fs.path.basenameWindows(decoded) else std.fs.path.basenamePosix(decoded);
    if (decoded.len == 0 or decoded.len > 4096 or !absolute or
        std.mem.indexOfScalar(u8, decoded, 0) != null or
        !std.ascii.eqlIgnoreCase(std.fs.path.extension(basename), ".torrent"))
    {
        allocator.free(buffer);
        return error.InvalidTorrentSource;
    }
    @memmove(buffer[0..decoded.len], decoded);
    return allocator.realloc(buffer, decoded.len);
}

pub fn urlAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return urlAllocForPlatform(allocator, path, @import("builtin").os.tag == .windows);
}

fn urlAllocForPlatform(allocator: std.mem.Allocator, path: []const u8, windows: bool) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "torrent-file://");
    if (windows and path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':')
        try output.append(allocator, '/');
    for (path) |byte| {
        if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "/-._~", byte) != null) {
            try output.append(allocator, byte);
        } else {
            const hex = "0123456789ABCDEF";
            try output.appendSlice(allocator, &.{ '%', hex[byte >> 4], hex[byte & 15] });
        }
    }
    return output.toOwnedSlice(allocator);
}


test "local torrent source round trip" {
    const allocator = std.testing.allocator;
    const path = if (@import("builtin").os.tag == .windows) "C:\\Users\\Test User\\file.torrent" else "/tmp/Test User/file.torrent";
    const url = try urlAlloc(allocator, path);
    defer allocator.free(url);
    const decoded = try pathAlloc(allocator, url);
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings(path, decoded);
}


test "Windows torrent URLs preserve drive paths and reject unsafe inputs" {
    const allocator = std.testing.allocator;
    const path = "C:\\Users\\Test User\\file.torrent";
    const encoded = try urlAllocForPlatform(allocator, path, true);
    defer allocator.free(encoded);
    const from_encoded = try pathAllocForPlatform(allocator, encoded, true);
    defer allocator.free(from_encoded);
    try std.testing.expectEqualStrings(path, from_encoded);
    const from_file_uri = try pathAllocForPlatform(allocator, "torrent-file:///C:/Users/Test%20User/file.torrent", true);
    defer allocator.free(from_file_uri);
    try std.testing.expectEqualStrings("C:/Users/Test User/file.torrent", from_file_uri);
    try std.testing.expectError(error.InvalidTorrentSource, pathAllocForPlatform(allocator, "torrent-file:///C:/a%00b.torrent", true));
    try std.testing.expectError(error.InvalidTorrentSource, pathAllocForPlatform(allocator, "torrent-file://remote/share/file.torrent", true));
    try std.testing.expectError(error.InvalidTorrentSource, pathAllocForPlatform(allocator, "torrent-file:///C:/a.torrent?private=1", true));
    try std.testing.expectError(error.InvalidTorrentSource, pathAllocForPlatform(allocator, "torrent-file:///C:/folder.torrent/not-a-torrent", true));
}
