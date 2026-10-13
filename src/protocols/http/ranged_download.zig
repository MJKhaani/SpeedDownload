//! Bounded, validator-checked HTTP range downloader.
//!
//! It probes actual 206 behavior before creating files, writes disjoint
//! preallocated extents concurrently, syncs each extent before advancing the
//! atomic segment journal, and resumes only against the same representation.

const std = @import("std");
const http = std.http;
const ranges = @import("ranges.zig");
const segment_journal = @import("segment_journal.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const ProgressCallback = *const fn (context: *anyopaque, completed: u64, total: ?u64, durable: bool) anyerror!void;
const max_workers = 4;
const minimum_segment_size: u64 = 4 * 1024 * 1024;
const parallel_threshold: u64 = 2 * minimum_segment_size;
const checkpoint_suffix = ".sdr";

pub const Error = error{
    InvalidProbe,
    RepresentationChanged,
    InvalidSegmentResponse,
    SegmentLengthMismatch,
    InvalidSegmentJournal,
    PartialFileLengthMismatch,
    WorkerSpawnFailed,
};

const Probe = struct {
    total: u64,
    etag: []u8,
    target_hash: [32]u8,
};

/// Returns true when a range transfer completed, or false when a fresh
/// download must use the existing single-stream path. Once a segment journal
/// exists, any lost range capability is an error rather than a destructive
/// fallback.
pub fn downloadIfSupported(
    allocator: Allocator,
    io: Io,
    url: []const u8,
    destination: []const u8,
    expected_sha256: ?[32]u8,
    progress_callback: ?ProgressCallback,
    progress_context: ?*anyopaque,
) !bool {
    const uri = std.Uri.parse(url) catch return false;
    if ((!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) or !resumeSafe(uri)) return false;

    const cwd = Io.Dir.cwd();
    if (cwd.statFile(io, destination, .{})) |_| return error.DestinationExists else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const part_path = try std.fmt.allocPrint(allocator, "{s}.part", .{destination});
    defer allocator.free(part_path);
    const journal_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ part_path, checkpoint_suffix });
    defer allocator.free(journal_path);

    const part_exists = fileExists(io, part_path) catch |err| return err;
    const journal_exists = fileExists(io, journal_path) catch |err| return err;
    if (part_exists and !journal_exists) return false;
    if (!part_exists and journal_exists) cwd.deleteFile(io, journal_path) catch {};
    const is_resume = part_exists and journal_exists;

    var prior: ?segment_journal.Snapshot = null;
    defer if (prior) |snapshot| allocator.free(snapshot.etag);
    if (is_resume) {
        prior = try segment_journal.load(allocator, io, journal_path) orelse return Error.InvalidSegmentJournal;
        var source_hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(url, &source_hash, .{});
        if (!std.mem.eql(u8, &source_hash, &prior.?.source_hash)) return Error.InvalidSegmentJournal;
    }

    var probe = probeRanges(allocator, io, uri) catch |err| switch (err) {
        Error.InvalidProbe => {
            if (is_resume) return Error.RepresentationChanged;
            return false;
        },
        else => return err,
    };
    defer allocator.free(probe.etag);
    if (probe.total < parallel_threshold) {
        if (is_resume) return Error.RepresentationChanged;
        return false;
    }
    if (prior) |snapshot| {
        if (snapshot.map.total != probe.total or
            !std.mem.eql(u8, snapshot.etag, probe.etag) or
            !std.mem.eql(u8, &snapshot.target_hash, &probe.target_hash))
        {
            return Error.RepresentationChanged;
        }
    }

    var source_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(url, &source_hash, .{});
    var map = if (prior) |snapshot| snapshot.map else try ranges.ExtentMap.init(probe.total);
    if (prior == null) {
        while (map.len < max_workers) {
            _ = map.splitLargest(minimum_segment_size) catch break;
        }
        try segment_journal.saveAtomic(allocator, io, journal_path, .{
            .source_hash = source_hash,
            .target_hash = probe.target_hash,
            .etag = probe.etag,
            .map = map,
        });
    }

    const part_file = if (part_exists)
        try cwd.openFile(io, part_path, .{ .mode = .read_write, .allow_directory = false })
    else
        try cwd.createFile(io, part_path, .{ .exclusive = true, .truncate = false, .read = true });
    var part_file_open = true;
    defer if (part_file_open) part_file.close(io);
    if (part_exists) {
        if (try part_file.length(io) != probe.total) {
            part_file.close(io);
            part_file_open = false;
            cwd.deleteFile(io, part_path) catch {};
            cwd.deleteFile(io, journal_path) catch {};
            return Error.PartialFileLengthMismatch;
        }
    } else {
        part_file.setLength(io, probe.total) catch |err| {
            part_file.close(io);
            part_file_open = false;
            cwd.deleteFile(io, part_path) catch {};
            cwd.deleteFile(io, journal_path) catch {};
            return err;
        };
        part_file.sync(io) catch |err| {
            part_file.close(io);
            part_file_open = false;
            cwd.deleteFile(io, part_path) catch {};
            cwd.deleteFile(io, journal_path) catch {};
            return err;
        };
    }
    part_file.close(io);
    part_file_open = false;

    var shared = Shared{
        .allocator = allocator,
        .io = io,
        .url = url,
        .part_path = part_path,
        .journal_path = journal_path,
        .source_hash = source_hash,
        .target_hash = probe.target_hash,
        .etag = probe.etag,
        .total = probe.total,
        .map = map,
        .callback = progress_callback,
        .callback_context = progress_context,
    };

    var contexts: [max_workers]WorkerContext = undefined;
    var threads: [max_workers]std.Thread = undefined;
    var thread_count: usize = 0;
    var spawn_failed = false;
    for (shared.map.segments[0..shared.map.len]) |*segment| {
        if (segment.state == .complete) continue;
        contexts[thread_count] = .{ .shared = &shared, .segment = segment.*, .slot = thread_count };
        threads[thread_count] = std.Thread.spawn(.{}, runWorker, .{&contexts[thread_count]}) catch {
            shared.results[thread_count] = Error.WorkerSpawnFailed;
            spawn_failed = true;
            break;
        };
        thread_count += 1;
    }
    for (threads[0..thread_count]) |thread| thread.join();
    if (spawn_failed) return Error.WorkerSpawnFailed;
    for (shared.results[0..thread_count]) |result| if (result) |err| return err;

    if (shared.map.completedBytes() != shared.total) return Error.InvalidSegmentJournal;
    const verify_file = try cwd.openFile(io, part_path, .{ .mode = .read_only, .allow_directory = false });
    defer verify_file.close(io);
    try @import("download.zig").verifySha256(io, verify_file, expected_sha256);

    const publish_file = try cwd.openFile(io, part_path, .{ .mode = .read_write, .allow_directory = false });
    defer publish_file.close(io);
    try publish_file.sync(io);
    try @import("download.zig").publishNoReplace(cwd, io, part_path, destination);
    cwd.deleteFile(io, journal_path) catch {};
    return true;
}

const Shared = struct {
    allocator: Allocator,
    io: Io,
    url: []const u8,
    part_path: []const u8,
    journal_path: []const u8,
    source_hash: [32]u8,
    target_hash: [32]u8,
    etag: []const u8,
    total: u64,
    map: ranges.ExtentMap,
    callback: ?ProgressCallback,
    callback_context: ?*anyopaque,
    mutex: Io.Mutex = .init,
    results: [max_workers]?anyerror = .{ null, null, null, null },
    in_flight: [max_workers]std.atomic.Value(u64) = .{ .init(0), .init(0), .init(0), .init(0) },

    fn report(self: *Shared, durable: bool) !void {
        const callback = self.callback orelse return;
        const callback_context = self.callback_context orelse return;
        self.mutex.lockUncancelable(self.io);
        var completed = self.map.completedBytes();
        for (&self.in_flight) |*bytes| completed += bytes.load(.acquire);
        self.mutex.unlock(self.io);
        try callback(callback_context, completed, self.total, durable);
    }

    fn completeSegment(self: *Shared, slot: usize, segment_id: u32, end: u64) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.map.advance(segment_id, end);
        self.in_flight[slot].store(0, .release);
        try segment_journal.saveAtomic(self.allocator, self.io, self.journal_path, .{
            .source_hash = self.source_hash,
            .target_hash = self.target_hash,
            .etag = self.etag,
            .map = self.map,
        });
        if (self.callback) |callback| {
            if (self.callback_context) |callback_context| {
                try callback(callback_context, self.map.completedBytes(), self.total, true);
            }
        }
    }
};

const WorkerContext = struct {
    shared: *Shared,
    segment: ranges.Segment,
    slot: usize,
};

fn runWorker(context: *WorkerContext) void {
    runSegment(context.shared, context) catch |err| {
        context.shared.results[context.slot] = err;
    };
}

fn runSegment(self: *Shared, context: *WorkerContext) !void {
    const worker = context.segment;
    const header_value = try ranges.formatHeader(self.allocator, .{ .start = worker.cursor, .end = worker.end }, self.total);
    defer self.allocator.free(header_value);
    var client: http.Client = .{ .allocator = self.allocator, .io = self.io };
    defer client.deinit();
    const uri = try std.Uri.parse(self.url);
    const headers = [_]http.Header{
        .{ .name = "range", .value = header_value },
        .{ .name = "if-range", .value = self.etag },
    };
    var request = try client.request(.GET, uri, .{
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
        .extra_headers = &headers,
    });
    defer request.deinit();
    try request.sendBodiless();
    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    if (response.head.status != .partial_content or response.head.content_encoding != .identity) return Error.InvalidSegmentResponse;
    const content_range_text = responseHeader(response.head.bytes, "content-range") orelse return Error.InvalidSegmentResponse;
    const content_range = parseContentRange(content_range_text) orelse return Error.InvalidSegmentResponse;
    if (content_range.start != worker.cursor or content_range.end_inclusive != worker.end - 1 or content_range.total != self.total) return Error.InvalidSegmentResponse;
    if (response.head.content_length == null or response.head.content_length.? != worker.end - worker.cursor) return Error.SegmentLengthMismatch;
    const etag = responseHeader(response.head.bytes, "etag") orelse return Error.RepresentationChanged;
    if (!isStrongETag(etag) or !std.mem.eql(u8, etag, self.etag)) return Error.RepresentationChanged;
    const target_hash = try uriHash(self.allocator, request.uri);
    if (!std.mem.eql(u8, &target_hash, &self.target_hash)) return Error.RepresentationChanged;

    const file = try Io.Dir.cwd().openFile(self.io, self.part_path, .{ .mode = .read_write, .allow_directory = false });
    defer file.close(self.io);
    var file_buffer: [32 * 1024]u8 = undefined;
    var file_writer = file.writer(self.io, &file_buffer);
    try file_writer.seekTo(worker.cursor);
    var reader_buffer: [16 * 1024]u8 = undefined;
    var chunk_buffer: [32 * 1024]u8 = undefined;
    var body = response.reader(&reader_buffer);
    var remaining = worker.end - worker.cursor;
    var downloaded: u64 = 0;
    while (remaining > 0) {
        if (self.callback != null) try self.report(false);
        const amount: usize = @intCast(@min(remaining, chunk_buffer.len));
        const count = body.readSliceShort(chunk_buffer[0..amount]) catch return response.bodyErr().?;
        if (count == 0) return Error.SegmentLengthMismatch;
        try file_writer.interface.writeAll(chunk_buffer[0..count]);
        remaining -= count;
        downloaded += count;
        self.in_flight[context.slot].store(downloaded, .release);
    }
    try file_writer.flush();
    try file.sync(self.io);
    try self.completeSegment(context.slot, worker.id, worker.end);
}

fn probeRanges(allocator: Allocator, io: Io, uri: std.Uri) !Probe {
    var client: http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    const headers = [_]http.Header{.{ .name = "range", .value = "bytes=0-0" }};
    var request = try client.request(.GET, uri, .{
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
        .extra_headers = &headers,
    });
    defer request.deinit();
    try request.sendBodiless();
    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    if (response.head.status != .partial_content or response.head.content_encoding != .identity or response.head.content_length != 1) return Error.InvalidProbe;
    const range_text = responseHeader(response.head.bytes, "content-range") orelse return Error.InvalidProbe;
    const content_range = parseContentRange(range_text) orelse return Error.InvalidProbe;
    if (content_range.start != 0 or content_range.end_inclusive != 0 or content_range.total == null) return Error.InvalidProbe;
    const etag = responseHeader(response.head.bytes, "etag") orelse return Error.InvalidProbe;
    if (!isStrongETag(etag) or etag.len > 1024) return Error.InvalidProbe;
    var body_buffer: [1]u8 = undefined;
    var body = response.reader(&body_buffer);
    const count = body.readSliceShort(&body_buffer) catch return response.bodyErr().?;
    if (count != 1) return Error.InvalidProbe;
    const etag_copy = try allocator.dupe(u8, etag);
    errdefer allocator.free(etag_copy);
    return .{ .total = content_range.total.?, .etag = etag_copy, .target_hash = try uriHash(allocator, request.uri) };
}

fn fileExists(io: Io, path: []const u8) !bool {
    return if (Io.Dir.cwd().statFile(io, path, .{})) |_| true else |err| switch (err) {
        error.FileNotFound => false,
        else => err,
    };
}

fn resumeSafe(uri: std.Uri) bool {
    return uri.user == null and uri.password == null and uri.query == null and uri.fragment == null;
}

fn isStrongETag(value: []const u8) bool {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return false;
    for (value[1 .. value.len - 1]) |byte| if (byte == '"' or byte < 0x21 or byte == 0x7f) return false;
    return true;
}

const ContentRange = struct { start: u64, end_inclusive: u64, total: ?u64 };

fn parseContentRange(value: []const u8) ?ContentRange {
    if (!std.mem.startsWith(u8, value, "bytes ")) return null;
    var slash = std.mem.splitScalar(u8, value[6..], '/');
    const span = slash.next() orelse return null;
    const total_text = slash.next() orelse return null;
    if (slash.next() != null) return null;
    var dash = std.mem.splitScalar(u8, span, '-');
    const start = std.fmt.parseInt(u64, dash.next() orelse return null, 10) catch return null;
    const end = std.fmt.parseInt(u64, dash.next() orelse return null, 10) catch return null;
    if (dash.next() != null or start > end) return null;
    const total = if (std.mem.eql(u8, total_text, "*")) null else std.fmt.parseInt(u64, total_text, 10) catch return null;
    if (total) |size| if (end >= size) return null;
    return .{ .start = start, .end_inclusive = end, .total = total };
}

fn responseHeader(bytes: []const u8, name: []const u8) ?[]const u8 {
    var iter = http.HeaderIterator.init(bytes);
    var found: ?[]const u8 = null;
    while (iter.next()) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, name)) continue;
        if (found != null) return null;
        found = header.value;
    }
    return found;
}

fn uriHash(allocator: Allocator, uri: std.Uri) ![32]u8 {
    var formatted = Io.Writer.Allocating.init(allocator);
    defer formatted.deinit();
    try uri.format(&formatted.writer);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(formatted.writer.buffered(), &hash, .{});
    return hash;
}
