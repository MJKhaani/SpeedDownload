//! Bounded, canonical BitTorrent v1 metainfo inspection. No peer traffic or
//! filesystem writes are performed here.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const max_metainfo_bytes = 8 * 1024 * 1024;
const max_depth = 32;
const max_values = 100_000;
const max_files = 10_000;

pub const Result = struct {
    name: []const u8,
    announce: ?[]const u8,
    announce_list: ?[]const u8,
    total_bytes: u64,
    file_count: u32,
    single_file: bool,
    piece_length: u64,
    piece_count: u64,
    piece_hashes: []const u8,
    info_hash: [20]u8,
};

const Cursor = struct {
    bytes: []const u8,
    position: usize = 0,
    values: usize = 0,

    fn take(self: *Cursor, byte: u8) !void {
        if (self.position >= self.bytes.len or self.bytes[self.position] != byte) return error.InvalidBencode;
        self.position += 1;
    }

    fn count(self: *Cursor) !void {
        self.values += 1;
        if (self.values > max_values) return error.TorrentTooComplex;
    }

    fn string(self: *Cursor) ![]const u8 {
        try self.count();
        const start = self.position;
        while (self.position < self.bytes.len and std.ascii.isDigit(self.bytes[self.position])) self.position += 1;
        if (self.position == start or self.position >= self.bytes.len or self.bytes[self.position] != ':') return error.InvalidBencode;
        if (self.position - start > 1 and self.bytes[start] == '0') return error.NonCanonicalBencode;
        const length = std.fmt.parseInt(usize, self.bytes[start..self.position], 10) catch return error.InvalidBencode;
        self.position += 1;
        if (length > self.bytes.len - self.position) return error.InvalidBencode;
        const value = self.bytes[self.position .. self.position + length];
        self.position += length;
        return value;
    }

    fn integer(self: *Cursor) !i64 {
        try self.count();
        try self.take('i');
        const start = self.position;
        while (self.position < self.bytes.len and self.bytes[self.position] != 'e') self.position += 1;
        if (self.position >= self.bytes.len or self.position == start) return error.InvalidBencode;
        const text = self.bytes[start..self.position];
        if (text[0] == '+' or (text.len > 1 and text[0] == '0') or
            (text.len > 1 and text[0] == '-' and text[1] == '0')) return error.NonCanonicalBencode;
        const value = std.fmt.parseInt(i64, text, 10) catch return error.InvalidBencode;
        self.position += 1;
        return value;
    }

    fn skip(self: *Cursor, depth: usize) !void {
        if (depth > max_depth or self.position >= self.bytes.len) return error.TorrentTooComplex;
        switch (self.bytes[self.position]) {
            '0'...'9' => _ = try self.string(),
            'i' => _ = try self.integer(),
            'l' => {
                try self.count();
                self.position += 1;
                while (self.position < self.bytes.len and self.bytes[self.position] != 'e') try self.skip(depth + 1);
                try self.take('e');
            },
            'd' => {
                try self.count();
                self.position += 1;
                var previous: ?[]const u8 = null;
                while (self.position < self.bytes.len and self.bytes[self.position] != 'e') {
                    const key = try self.string();
                    try ordered(previous, key);
                    previous = key;
                    try self.skip(depth + 1);
                }
                try self.take('e');
            },
            else => return error.InvalidBencode,
        }
    }
};

fn ordered(previous: ?[]const u8, current: []const u8) !void {
    if (previous) |key| if (std.mem.order(u8, key, current) != .lt) return error.NonCanonicalBencode;
}

pub fn safeComponent(value: []const u8) bool {
    if (value.len == 0 or value.len > 255 or !std.unicode.utf8ValidateSlice(value) or
        std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..") or
        std.mem.indexOfAny(u8, value, "/\\:\x00") != null or
        value[value.len - 1] == '.' or value[value.len - 1] == ' ') return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    const stem = if (std.mem.indexOfScalar(u8, value, '.')) |dot| value[0..dot] else value;
    inline for (.{ "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9" }) |reserved| {
        if (std.ascii.eqlIgnoreCase(stem, reserved)) return false;
    }
    return true;
}

const Files = struct { total: u64 = 0, count: u32 = 0 };

fn parsePath(cursor: *Cursor, seen: *std.AutoHashMap([32]u8, void)) !void {
    try cursor.count();
    try cursor.take('l');
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var depth: usize = 0;
    while (cursor.position < cursor.bytes.len and cursor.bytes[cursor.position] != 'e') {
        if (depth == 64) return error.TorrentPathTooDeep;
        const component = try cursor.string();
        if (!safeComponent(component)) return error.UnsafeTorrentPath;
        var length: [2]u8 = undefined;
        std.mem.writeInt(u16, &length, @intCast(component.len), .big);
        hash.update(&length);
        hash.update(component);
        depth += 1;
    }
    try cursor.take('e');
    if (depth == 0) return error.UnsafeTorrentPath;
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    if (seen.contains(digest)) return error.DuplicateTorrentPath;
    try seen.put(digest, {});
}

fn parseFiles(allocator: Allocator, cursor: *Cursor) !Files {
    try cursor.count();
    try cursor.take('l');
    var seen = std.AutoHashMap([32]u8, void).init(allocator);
    defer seen.deinit();
    var result: Files = .{};
    while (cursor.position < cursor.bytes.len and cursor.bytes[cursor.position] != 'e') {
        if (result.count >= max_files) return error.TorrentTooManyFiles;
        try cursor.count();
        try cursor.take('d');
        var previous: ?[]const u8 = null;
        var length: ?u64 = null;
        var has_path = false;
        while (cursor.position < cursor.bytes.len and cursor.bytes[cursor.position] != 'e') {
            const key = try cursor.string();
            try ordered(previous, key);
            previous = key;
            if (std.mem.eql(u8, key, "length")) {
                const number = try cursor.integer();
                if (number < 0) return error.InvalidTorrentLength;
                length = @intCast(number);
            } else if (std.mem.eql(u8, key, "path")) {
                try parsePath(cursor, &seen);
                has_path = true;
            } else if (std.mem.eql(u8, key, "attr")) {
                const attrs = try cursor.string();
                if (std.mem.indexOfScalar(u8, attrs, 'l') != null) return error.UnsupportedTorrentSymlink;
            } else try cursor.skip(2);
        }
        try cursor.take('e');
        if (length == null or !has_path) return error.InvalidTorrentFile;
        result.total = std.math.add(u64, result.total, length.?) catch return error.TorrentSizeOverflow;
        result.count += 1;
    }
    try cursor.take('e');
    if (result.count == 0) return error.InvalidTorrentFile;
    return result;
}

fn parseInfo(allocator: Allocator, cursor: *Cursor) !struct { name: []const u8, files: Files, single_file: bool, piece_length: u64, pieces: []const u8 } {
    try cursor.count();
    try cursor.take('d');
    var previous: ?[]const u8 = null;
    var name: ?[]const u8 = null;
    var file_length: ?u64 = null;
    var files: ?Files = null;
    var piece_length: ?u64 = null;
    var pieces: ?[]const u8 = null;
    while (cursor.position < cursor.bytes.len and cursor.bytes[cursor.position] != 'e') {
        const key = try cursor.string();
        try ordered(previous, key);
        previous = key;
        if (std.mem.eql(u8, key, "name")) {
            const value = try cursor.string();
            if (!safeComponent(value)) return error.UnsafeTorrentPath;
            name = value;
        } else if (std.mem.eql(u8, key, "length")) {
            const value = try cursor.integer();
            if (value < 0) return error.InvalidTorrentLength;
            file_length = @intCast(value);
        } else if (std.mem.eql(u8, key, "files")) {
            files = try parseFiles(allocator, cursor);
        } else if (std.mem.eql(u8, key, "piece length")) {
            const value = try cursor.integer();
            if (value <= 0 or value > 64 * 1024 * 1024) return error.InvalidTorrentPieceLength;
            piece_length = @intCast(value);
        } else if (std.mem.eql(u8, key, "pieces")) {
            pieces = try cursor.string();
        } else if (std.mem.eql(u8, key, "meta version")) {
            return error.UnsupportedTorrentV2;
        } else try cursor.skip(1);
    }
    try cursor.take('e');
    if (name == null or piece_length == null or pieces == null or (file_length == null and files == null) or
        (file_length != null and files != null)) return error.InvalidTorrentInfo;
    return .{
        .name = name.?,
        .files = files orelse .{ .total = file_length.?, .count = 1 },
        .single_file = file_length != null,
        .piece_length = piece_length.?,
        .pieces = pieces.?,
    };
}

pub fn inspect(allocator: Allocator, bytes: []const u8) !Result {
    if (bytes.len == 0 or bytes.len > max_metainfo_bytes) return error.InvalidTorrentSize;
    var cursor: Cursor = .{ .bytes = bytes };
    try cursor.count();
    try cursor.take('d');
    var previous: ?[]const u8 = null;
    var announce: ?[]const u8 = null;
    var announce_list: ?[]const u8 = null;
    var info_name: ?[]const u8 = null;
    var info_files: Files = .{};
    var single_file = false;
    var piece_length: u64 = 0;
    var piece_count: u64 = 0;
    var piece_hashes: []const u8 = "";
    var info_hash: [20]u8 = undefined;
    while (cursor.position < bytes.len and bytes[cursor.position] != 'e') {
        const key = try cursor.string();
        try ordered(previous, key);
        previous = key;
        if (std.mem.eql(u8, key, "announce")) {
            const value = try cursor.string();
            if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidTorrentTracker;
            announce = value;
        } else if (std.mem.eql(u8, key, "announce-list")) {
            const start = cursor.position;
            try cursor.skip(1);
            announce_list = bytes[start..cursor.position];
        } else if (std.mem.eql(u8, key, "info")) {
            const start = cursor.position;
            const info = try parseInfo(allocator, &cursor);
            std.crypto.hash.Sha1.hash(bytes[start..cursor.position], &info_hash, .{});
            info_name = info.name;
            info_files = info.files;
            single_file = info.single_file;
            piece_length = info.piece_length;
            if (info.pieces.len % 20 != 0) return error.InvalidTorrentPieces;
            piece_count = @intCast(info.pieces.len / 20);
            piece_hashes = info.pieces;
        } else try cursor.skip(1);
    }
    try cursor.take('e');
    if (cursor.position != bytes.len or info_name == null) return error.InvalidTorrentMetainfo;
    const expected_count = if (info_files.total == 0) @as(u64, 0) else (info_files.total - 1) / piece_length + 1;
    if (piece_count != expected_count) return error.InvalidTorrentPieces;
    return .{
        .name = info_name.?,
        .announce = announce,
        .announce_list = announce_list,
        .total_bytes = info_files.total,
        .file_count = info_files.count,
        .single_file = single_file,
        .piece_length = piece_length,
        .piece_count = piece_count,
        .piece_hashes = piece_hashes,
        .info_hash = info_hash,
    };
}

/// Return owned tracker URLs from BEP 12 tiers, or the primary announce URL
/// when no tier list exists. The caller frees each URL and the outer slice.
pub fn trackerUrls(allocator: Allocator, info: Result) ![][]u8 {
    var urls: std.ArrayList([]u8) = .empty;
    errdefer {
        for (urls.items) |url| allocator.free(url);
        urls.deinit(allocator);
    }
    if (info.announce_list) |encoded| {
        var cursor: Cursor = .{ .bytes = encoded };
        try cursor.count();
        try cursor.take('l');
        while (cursor.position < encoded.len and encoded[cursor.position] != 'e') {
            try cursor.count();
            try cursor.take('l');
            while (cursor.position < encoded.len and encoded[cursor.position] != 'e') {
                const value = try cursor.string();
                try appendTracker(allocator, &urls, value);
            }
            try cursor.take('e');
        }
        try cursor.take('e');
        if (cursor.position != encoded.len) return error.InvalidTorrentTrackers;
    } else if (info.announce) |primary| {
        try appendTracker(allocator, &urls, primary);
    }
    if (urls.items.len == 0) return error.NoTorrentTrackers;
    return urls.toOwnedSlice(allocator);
}

fn appendTracker(allocator: Allocator, urls: *std.ArrayList([]u8), value: []const u8) !void {
    if (urls.items.len >= 32 or value.len == 0 or value.len > 2048 or !std.unicode.utf8ValidateSlice(value)) return;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return;
    const uri = std.Uri.parse(value) catch return;
    if (uri.host == null or uri.user != null or uri.password != null or uri.fragment != null or
        !(std.ascii.eqlIgnoreCase(uri.scheme, "http") or std.ascii.eqlIgnoreCase(uri.scheme, "https") or std.ascii.eqlIgnoreCase(uri.scheme, "udp"))) return;
    for (urls.items) |existing| if (std.mem.eql(u8, existing, value)) return;
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    try urls.append(allocator, owned);
}
