//! Versioned binary representation of crash-safe HTTP range progress.
//!
//! The caller must sync segment bytes before encoding a journal with the
//! advanced cursor, then atomically replace the previous journal. This module
//! validates metadata and ownership; it does not perform filesystem I/O.

const std = @import("std");
const ranges = @import("ranges.zig");
const Io = std.Io;

pub const Error = error{
    InvalidJournal,
    JournalUpgradeRequired,
    InvalidRepresentation,
    InvalidExtentMap,
    SizeOverflow,
};

pub const Snapshot = struct {
    source_hash: [32]u8,
    target_hash: [32]u8,
    etag: []const u8,
    map: ranges.ExtentMap,
};

const magic = "SDRANGE2";
const legacy_magic = "SDRANGE1";
const checksum_size = 32;
const fixed_size = magic.len + 32 + 32 + 8 + 2 + 2 + 4;
const segment_size = 4 + 8 + 8 + 8 + 1;
const max_etag_length = 1024;
const max_encoded_size = fixed_size + max_etag_length + ranges.max_segments * segment_size + checksum_size;

/// Encodes a representation-bound snapshot in a deterministic format.
pub fn encode(allocator: std.mem.Allocator, snapshot: Snapshot) ![]u8 {
    try validate(snapshot);
    const entries_size = std.math.mul(usize, snapshot.map.len, segment_size) catch return Error.SizeOverflow;
    const data_size = std.math.add(usize, fixed_size + snapshot.etag.len, entries_size) catch return Error.SizeOverflow;
    const total_size = std.math.add(usize, data_size, checksum_size) catch return Error.SizeOverflow;
    const output = try allocator.alloc(u8, total_size);
    errdefer allocator.free(output);

    var cursor: usize = 0;
    @memcpy(output[cursor..][0..magic.len], magic);
    cursor += magic.len;
    @memcpy(output[cursor..][0..32], &snapshot.source_hash);
    cursor += 32;
    @memcpy(output[cursor..][0..32], &snapshot.target_hash);
    cursor += 32;
    std.mem.writeInt(u64, output[cursor..][0..8], snapshot.map.total, .big);
    cursor += 8;
    std.mem.writeInt(u16, output[cursor..][0..2], @intCast(snapshot.map.len), .big);
    cursor += 2;
    std.mem.writeInt(u16, output[cursor..][0..2], @intCast(snapshot.etag.len), .big);
    cursor += 2;
    std.mem.writeInt(u32, output[cursor..][0..4], snapshot.map.next_id, .big);
    cursor += 4;
    @memcpy(output[cursor..][0..snapshot.etag.len], snapshot.etag);
    cursor += snapshot.etag.len;
    for (snapshot.map.segments[0..snapshot.map.len]) |segment| {
        std.mem.writeInt(u32, output[cursor..][0..4], segment.id, .big);
        cursor += 4;
        std.mem.writeInt(u64, output[cursor..][0..8], segment.start, .big);
        cursor += 8;
        std.mem.writeInt(u64, output[cursor..][0..8], segment.cursor, .big);
        cursor += 8;
        std.mem.writeInt(u64, output[cursor..][0..8], segment.end, .big);
        cursor += 8;
        output[cursor] = if (segment.state == .complete) 1 else 0;
        cursor += 1;
    }
    var checksum: [checksum_size]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(output[0..cursor], &checksum, .{});
    @memcpy(output[cursor..][0..checksum_size], &checksum);
    return output;
}

/// Decodes and fully validates a snapshot. The returned ETag is owned by the
/// caller and must be freed with the same allocator.
pub fn decode(allocator: std.mem.Allocator, input: []const u8) !Snapshot {
    if (input.len >= legacy_magic.len and std.mem.eql(u8, input[0..legacy_magic.len], legacy_magic)) return Error.JournalUpgradeRequired;
    if (input.len < fixed_size + checksum_size or !std.mem.eql(u8, input[0..magic.len], magic)) return Error.InvalidJournal;
    var actual_checksum: [checksum_size]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(input[0 .. input.len - checksum_size], &actual_checksum, .{});
    if (!std.mem.eql(u8, &actual_checksum, input[input.len - checksum_size ..])) return Error.InvalidJournal;
    var cursor = magic.len;
    var source_hash: [32]u8 = undefined;
    @memcpy(&source_hash, input[cursor..][0..32]);
    cursor += 32;
    var target_hash: [32]u8 = undefined;
    @memcpy(&target_hash, input[cursor..][0..32]);
    cursor += 32;
    const total = std.mem.readInt(u64, input[cursor..][0..8], .big);
    cursor += 8;
    const count = std.mem.readInt(u16, input[cursor..][0..2], .big);
    cursor += 2;
    const etag_length = std.mem.readInt(u16, input[cursor..][0..2], .big);
    cursor += 2;
    const next_id = std.mem.readInt(u32, input[cursor..][0..4], .big);
    cursor += 4;

    if (total == 0 or count == 0 or count > ranges.max_segments or etag_length < 2 or etag_length > max_etag_length) {
        return Error.InvalidJournal;
    }
    const entry_bytes = std.math.mul(usize, count, segment_size) catch return Error.InvalidJournal;
    const data_length = std.math.add(usize, fixed_size + etag_length, entry_bytes) catch return Error.InvalidJournal;
    const expected_length = std.math.add(usize, data_length, checksum_size) catch return Error.InvalidJournal;
    if (input.len != expected_length) return Error.InvalidJournal;

    const etag = try allocator.dupe(u8, input[cursor..][0..etag_length]);
    errdefer allocator.free(etag);
    cursor += etag_length;
    var map = ranges.ExtentMap{ .total = total, .len = count, .next_id = next_id };
    for (map.segments[0..map.len]) |*segment| {
        segment.id = std.mem.readInt(u32, input[cursor..][0..4], .big);
        cursor += 4;
        segment.start = std.mem.readInt(u64, input[cursor..][0..8], .big);
        cursor += 8;
        segment.cursor = std.mem.readInt(u64, input[cursor..][0..8], .big);
        cursor += 8;
        segment.end = std.mem.readInt(u64, input[cursor..][0..8], .big);
        cursor += 8;
        const state = input[cursor];
        cursor += 1;
        if (state > 1) return Error.InvalidJournal;
        segment.state = if (state == 1) .complete else .active;
    }
    const snapshot = Snapshot{ .source_hash = source_hash, .target_hash = target_hash, .etag = etag, .map = map };
    validate(snapshot) catch return Error.InvalidJournal;
    return snapshot;
}

/// Atomically saves a snapshot. The encoded file is flushed and synced before
/// rename; callers must sync corresponding segment data before calling this.
pub fn saveAtomic(allocator: std.mem.Allocator, io: Io, path: []const u8, snapshot: Snapshot) !void {
    const encoded = try encode(allocator, snapshot);
    defer allocator.free(encoded);

    const temp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(temp_path);
    const cwd = Io.Dir.cwd();
    cwd.deleteFile(io, temp_path) catch {};
    const file = try cwd.createFile(io, temp_path, .{ .exclusive = true, .truncate = false });
    var is_open = true;
    defer {
        if (is_open) file.close(io);
        cwd.deleteFile(io, temp_path) catch {};
    }

    var buffer: [1024]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(encoded);
    try writer.flush();
    try file.sync(io);
    file.close(io);
    is_open = false;
    try Io.Dir.rename(cwd, temp_path, cwd, path, io);
}

/// Loads an optional snapshot while bounding memory use and validating every
/// field. The returned ETag is owned by the caller.
pub fn load(allocator: std.mem.Allocator, io: Io, path: []const u8) !?Snapshot {
    const bytes = Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(max_encoded_size)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);
    return try decode(allocator, bytes);
}

fn validate(snapshot: Snapshot) Error!void {
    if (snapshot.map.total == 0 or snapshot.map.len == 0 or snapshot.map.len > ranges.max_segments) {
        return Error.InvalidExtentMap;
    }
    if (!isStrongETag(snapshot.etag) or snapshot.etag.len > max_etag_length) return Error.InvalidRepresentation;
    snapshot.map.validate() catch return Error.InvalidExtentMap;

    // The serialized intervals must cover the complete representation exactly
    // once, including bytes not yet downloaded. Sorting a bounded stack copy
    // keeps validation allocation-free and makes gaps detectable.
    var ordered: [ranges.max_segments]ranges.Segment = undefined;
    @memcpy(ordered[0..snapshot.map.len], snapshot.map.segments[0..snapshot.map.len]);
    std.mem.sort(ranges.Segment, ordered[0..snapshot.map.len], {}, struct {
        fn lessThan(_: void, lhs: ranges.Segment, rhs: ranges.Segment) bool {
            return lhs.start < rhs.start;
        }
    }.lessThan);
    if (ordered[0].start != 0) return Error.InvalidExtentMap;
    var expected_start: u64 = 0;
    var max_id: u32 = 0;
    for (ordered[0..snapshot.map.len], 0..) |segment, index| {
        if (segment.start != expected_start or segment.cursor < segment.start or segment.cursor > segment.end or segment.end > snapshot.map.total) {
            return Error.InvalidExtentMap;
        }
        if ((segment.state == .complete) != (segment.cursor == segment.end)) return Error.InvalidExtentMap;
        for (ordered[0..index]) |previous| if (previous.id == segment.id) return Error.InvalidExtentMap;
        expected_start = segment.end;
        max_id = @max(max_id, segment.id);
    }
    if (expected_start != snapshot.map.total or snapshot.map.next_id <= max_id) return Error.InvalidExtentMap;
}

fn isStrongETag(value: []const u8) bool {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return false;
    for (value[1 .. value.len - 1]) |byte| {
        if (byte == '"' or byte < 0x21 or byte == 0x7f) return false;
    }
    return true;
}

test "segment journal round trips a split map" {
    const allocator = std.testing.allocator;
    var map = try ranges.ExtentMap.init(4096);
    try map.advance(0, 1024);
    _ = try map.splitLargest(512);
    const source: [32]u8 = @splat(1);
    const target: [32]u8 = @splat(2);
    const encoded = try encode(allocator, .{ .source_hash = source, .target_hash = target, .etag = "\"stable\"", .map = map });
    defer allocator.free(encoded);
    const decoded = try decode(allocator, encoded);
    defer allocator.free(decoded.etag);
    try std.testing.expectEqual(@as(u64, 4096), decoded.map.total);
    try std.testing.expectEqual(@as(u64, 1024), decoded.map.completedBytes());
    try std.testing.expectEqualStrings("\"stable\"", decoded.etag);
}

test "segment journal rejects malformed and gap-bearing maps" {
    const allocator = std.testing.allocator;
    var map = try ranges.ExtentMap.init(100);
    _ = try map.splitLargest(25);
    map.segments[1].start += 1;
    const source: [32]u8 = @splat(0);
    try std.testing.expectError(Error.InvalidExtentMap, validate(.{
        .source_hash = source,
        .target_hash = source,
        .etag = "\"tag\"",
        .map = map,
    }));
    try std.testing.expectError(Error.InvalidJournal, decode(allocator, "bad"));
}
