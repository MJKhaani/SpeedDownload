//! Local torrent source URLs used only by the trusted desktop IPC client.
//! The decoded path is bounded and never included in public job summaries.
const std = @import("std");

pub fn isLocalTorrent(url: []const u8) bool {
    return url.len >= 13 and std.ascii.eqlIgnoreCase(url[0..13], "torrent-file:");
}

/// Decode `torrent-file:///absolute/path.torrent`; caller owns the path.
pub fn pathAlloc(allocator: std.mem.Allocator, url: []const u8) ![]u8 {
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
    const decoded = std.Uri.percentDecodeInPlace(buffer);
    if (decoded.len == 0 or decoded.len > 4096 or !std.fs.path.isAbsolute(decoded) or
        std.mem.indexOfScalar(u8, decoded, 0) != null or
        !std.ascii.eqlIgnoreCase(std.fs.path.extension(decoded), ".torrent"))
    {
        allocator.free(buffer);
        return error.InvalidTorrentSource;
    }
    @memmove(buffer[0..decoded.len], decoded);
    return allocator.realloc(buffer, decoded.len);
}
