//! Checked half-open interval allocator for HTTP multipart transfers.
//!
//! The allocator owns disjoint, uncompleted work. Each claim is a half-open
//! interval `[start, end)` and may be subdivided only into adjacent intervals.
//! HTTP's inclusive `Range` endpoints are deliberately kept outside this type.

const std = @import("std");

pub const Interval = struct {
    start: u64,
    end: u64,

    pub fn length(self: Interval) u64 {
        return self.end - self.start;
    }

    pub fn isValid(self: Interval) bool {
        return self.start < self.end;
    }

    /// Converts this interval to RFC byte-range inclusive end syntax.
    pub fn inclusiveEnd(self: Interval) ?u64 {
        if (!self.isValid()) return null;
        return self.end - 1;
    }
};

pub const SegmentState = enum { active, complete };

pub const Segment = struct {
    id: u32,
    start: u64,
    cursor: u64,
    end: u64,
    state: SegmentState = .active,

    pub fn remaining(self: Segment) u64 {
        return self.end - self.cursor;
    }
};

pub const max_segments = 64;

/// Bounded dynamic extent map. A segment's assigned bytes are `[start, end)`;
/// its durable cursor advances monotonically within that ownership. A split
/// transfers only the tail of uncompleted work to a new segment.
pub const ExtentMap = struct {
    total: u64,
    segments: [max_segments]Segment = undefined,
    len: usize = 0,
    next_id: u32 = 1,

    pub fn init(total: u64) RangeError!ExtentMap {
        if (total == 0) return RangeError.InvalidInterval;
        var map = ExtentMap{ .total = total };
        map.segments[0] = .{ .id = 0, .start = 0, .cursor = 0, .end = total };
        map.len = 1;
        return map;
    }

    /// Split the largest still-active remainder, retaining its head under the
    /// same worker id and returning a distinct tail worker id.
    pub fn splitLargest(self: *ExtentMap, minimum_piece_size: u64) RangeError!Segment {
        if (minimum_piece_size == 0) return RangeError.InvalidInterval;
        if (self.len == max_segments or self.next_id == std.math.maxInt(u32)) return RangeError.NoSplittableInterval;

        var candidate: ?usize = null;
        for (self.segments[0..self.len], 0..) |segment, index| {
            if (segment.state != .active or segment.remaining() / 2 < minimum_piece_size) continue;
            if (candidate == null or segment.remaining() > self.segments[candidate.?].remaining()) candidate = index;
        }
        const index = candidate orelse return RangeError.NoSplittableInterval;
        const segment = self.segments[index];
        const remaining_interval = Interval{ .start = segment.cursor, .end = segment.end };
        const pieces = try splitTail(remaining_interval, minimum_piece_size);

        self.segments[index].end = pieces.head.end;
        const tail = Segment{
            .id = self.next_id,
            .start = pieces.tail.start,
            .cursor = pieces.tail.start,
            .end = pieces.tail.end,
        };
        self.next_id += 1;
        self.segments[self.len] = tail;
        self.len += 1;
        return tail;
    }

    /// Advances a worker's durable cursor. Cursors cannot move backwards or
    /// escape the segment it owns.
    pub fn advance(self: *ExtentMap, id: u32, durable_cursor: u64) RangeError!void {
        const index = self.findIndex(id) orelse return RangeError.InvalidInterval;
        const segment = &self.segments[index];
        if (segment.state != .active or durable_cursor < segment.cursor or durable_cursor > segment.end) {
            return RangeError.InvalidInterval;
        }
        segment.cursor = durable_cursor;
        if (durable_cursor == segment.end) segment.state = .complete;
    }

    pub fn completedBytes(self: *const ExtentMap) u64 {
        var completed: u64 = 0;
        for (self.segments[0..self.len]) |segment| completed += segment.cursor - segment.start;
        return completed;
    }

    pub fn validate(self: *const ExtentMap) RangeError!void {
        if (self.len == 0 or self.len > max_segments) return RangeError.InvalidInterval;
        var intervals: [max_segments]Interval = undefined;
        for (self.segments[0..self.len], 0..) |segment, index| {
            if (segment.start >= segment.cursor or segment.cursor > segment.end or segment.end > self.total) {
                // A not-yet-advanced tail has cursor == start and is valid.
                if (!(segment.start == segment.cursor and segment.cursor < segment.end and segment.end <= self.total))
                    return RangeError.InvalidInterval;
            }
            if (segment.state == .complete and segment.cursor != segment.end) return RangeError.InvalidInterval;
            intervals[index] = .{ .start = segment.start, .end = segment.end };
        }
        try validateDisjoint(intervals[0..self.len]);
    }

    fn findIndex(self: *const ExtentMap, id: u32) ?usize {
        for (self.segments[0..self.len], 0..) |segment, index| {
            if (segment.id == id) return index;
        }
        return null;
    }
};

pub const RangeError = error{
    InvalidInterval,
    SplitTooSmall,
    SplitOverflow,
    NoSplittableInterval,
    OverlappingIntervals,
};

/// Splits a work interval into a head retained by its current worker and a
/// tail assigned to a newly available worker. Both outputs are non-empty,
/// adjacent, and no longer than the source. If possible, the halves differ by
/// at most one byte. Splitting is refused when either piece would be smaller
/// than `minimum_piece_size`.
pub fn splitTail(interval: Interval, minimum_piece_size: u64) RangeError!struct { head: Interval, tail: Interval } {
    if (!interval.isValid()) return RangeError.InvalidInterval;
    if (minimum_piece_size == 0) return RangeError.InvalidInterval;

    const length = interval.length();
    if (length < minimum_piece_size or length - minimum_piece_size < minimum_piece_size) {
        return RangeError.SplitTooSmall;
    }

    const head_length = length / 2;
    const tail_length = length - head_length;
    if (head_length < minimum_piece_size or tail_length < minimum_piece_size) {
        return RangeError.SplitTooSmall;
    }
    const middle = std.math.add(u64, interval.start, head_length) catch return RangeError.SplitOverflow;
    return .{
        .head = .{ .start = interval.start, .end = middle },
        .tail = .{ .start = middle, .end = interval.end },
    };
}

/// Returns true when two valid half-open intervals share any writable byte.
pub fn overlaps(a: Interval, b: Interval) bool {
    return a.start < a.end and b.start < b.end and a.start < b.end and b.start < a.end;
}

/// Validates a set of uncompleted intervals. Adjacent intervals are allowed;
/// overlapping or empty intervals are rejected.
pub fn validateDisjoint(intervals: []const Interval) RangeError!void {
    for (intervals, 0..) |current, i| {
        if (!current.isValid()) return RangeError.InvalidInterval;
        for (intervals[0..i]) |previous| {
            if (overlaps(previous, current)) return RangeError.OverlappingIntervals;
        }
    }
}

/// Safely converts a half-open interval into an HTTP `Range` header value.
/// A finite representation length is required to ensure the end is in-bounds.
pub fn formatHeader(allocator: std.mem.Allocator, interval: Interval, total: u64) ![]u8 {
    if (!interval.isValid() or interval.end > total) return RangeError.InvalidInterval;
    return std.fmt.allocPrint(allocator, "bytes={d}-{d}", .{ interval.start, interval.end - 1 });
}

test "split retains head and assigns adjacent tail" {
    const halves = try splitTail(.{ .start = 10, .end = 1011 }, 256);
    try std.testing.expectEqual(@as(u64, 10), halves.head.start);
    try std.testing.expectEqual(@as(u64, 510), halves.head.end);
    try std.testing.expectEqual(@as(u64, 510), halves.tail.start);
    try std.testing.expectEqual(@as(u64, 1011), halves.tail.end);
    try std.testing.expect(!overlaps(halves.head, halves.tail));
}

test "split refuses to create undersized work" {
    try std.testing.expectError(RangeError.SplitTooSmall, splitTail(.{ .start = 0, .end = 511 }, 256));
    try std.testing.expectError(RangeError.SplitTooSmall, splitTail(.{ .start = 0, .end = 1 }, 2));
}

test "invalid intervals and overlaps are rejected" {
    try std.testing.expectError(RangeError.InvalidInterval, splitTail(.{ .start = 4, .end = 4 }, 1));
    try std.testing.expectError(RangeError.OverlappingIntervals, validateDisjoint(&.{
        .{ .start = 0, .end = 10 },
        .{ .start = 9, .end = 20 },
    }));
    try validateDisjoint(&.{
        .{ .start = 0, .end = 10 },
        .{ .start = 10, .end = 20 },
    });
}

test "HTTP range end conversion is checked" {
    const allocator = std.testing.allocator;
    const header = try formatHeader(allocator, .{ .start = 0, .end = 500 }, 500);
    defer allocator.free(header);
    try std.testing.expectEqualStrings("bytes=0-499", header);
    try std.testing.expectError(RangeError.InvalidInterval, formatHeader(allocator, .{ .start = 5, .end = 501 }, 500));
}

test "large offsets remain 64-bit" {
    const start = (@as(u64, 1) << 32) + 12;
    const halves = try splitTail(.{ .start = start, .end = start + 1024 }, 256);
    try std.testing.expectEqual(start + 512, halves.tail.start);
    try std.testing.expectEqual(start + 1024, halves.tail.end);
}

test "extent map splits unfinished tails and advances durable cursors" {
    var map = try ExtentMap.init(4096);
    try map.advance(0, 1024);
    const tail = try map.splitLargest(512);
    try std.testing.expectEqual(@as(u64, 2560), map.segments[0].end);
    try std.testing.expectEqual(@as(u64, 2560), tail.start);
    try std.testing.expectEqual(@as(u64, 4096), tail.end);
    try std.testing.expectEqual(@as(u64, 1024), map.completedBytes());
    try map.validate();

    try map.advance(0, 2560);
    try map.advance(tail.id, tail.end);
    try std.testing.expectEqual(@as(u64, 4096), map.completedBytes());
    try map.validate();
}

test "extent map rejects cursor regression and excessive subdivision" {
    var map = try ExtentMap.init(2048);
    try map.advance(0, 512);
    try std.testing.expectError(RangeError.InvalidInterval, map.advance(0, 256));
    _ = try map.splitLargest(256);
    try std.testing.expectError(RangeError.SplitTooSmall, map.splitLargest(512));
    try map.validate();
}
