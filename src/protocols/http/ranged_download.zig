//! Bounded, validator-checked HTTP range downloader.
//!
//! It probes actual 206 behavior before creating files, writes disjoint
//! preallocated extents concurrently, syncs each extent before advancing the
//! atomic segment journal, and resumes only against the same representation.

const std = @import("std");
const http = std.http;
const ranges = @import("ranges.zig");
const segment_journal = @import("segment_journal.zig");
const proxy = @import("proxy.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const ProgressCallback = *const fn (context: *anyopaque, completed: u64, total: ?u64, durable: bool) anyerror!void;
pub const WorkerProgressCallback = *const fn (context: *anyopaque, worker_id: u32, start: u64, end: u64, downloaded: u64) anyerror!void;
const max_workers = 32;
const minimum_segment_size: u64 = 4 * 1024 * 1024;
const checkpoint_interval: u64 = 4 * 1024 * 1024;
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
    worker_callback: ?WorkerProgressCallback,
    worker_context: ?*anyopaque,
    requested_connections: u8,
    proxy_policy: proxy.Policy,
    retry_hint: ?*@import("retry_after.zig").Hint,
) !bool {
    var uri = std.Uri.parse(url) catch return false;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) uri.scheme = "http" else if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) uri.scheme = "https" else return false;
    if (!resumeSafe(uri)) return false;

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

    var probe = probeRanges(allocator, io, uri, proxy_policy, retry_hint) catch |err| switch (err) {
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
    const connection_limit = @min(max_workers, @as(usize, @max(requested_connections, 1)));
    const target_segments = @min(ranges.max_segments, connection_limit * 2);
    var map_changed = prior == null;
    while (map.len < target_segments) {
        _ = map.splitLargest(minimum_segment_size) catch break;
        map_changed = true;
    }
    if (map_changed) {
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
        .worker_callback = worker_callback,
        .worker_context = worker_context,
        .proxy_policy = proxy_policy,
        .retry_hint = retry_hint,
        .connection_limit = connection_limit,
    };

    var contexts: [max_workers]WorkerContext = undefined;
    var threads: [max_workers]std.Thread = undefined;
    var thread_count: usize = 0;
    var spawn_failed = false;
    const incomplete_count = blk: {
        var count: usize = 0;
        for (shared.map.segments[0..shared.map.len]) |segment| if (segment.state == .active) {
            count += 1;
        };
        break :blk count;
    };
    while (thread_count < (if (incomplete_count == 0) @as(usize, 0) else connection_limit)) : (thread_count += 1) {
        contexts[thread_count] = .{ .shared = &shared, .slot = thread_count };
        threads[thread_count] = std.Thread.spawn(.{}, runWorker, .{&contexts[thread_count]}) catch {
            spawn_failed = true;
            shared.failed.store(true, .release);
            break;
        };
    }
    for (threads[0..thread_count]) |thread| thread.join();
    if (spawn_failed) return Error.WorkerSpawnFailed;
    for (shared.results[0..thread_count]) |result| if (result) |err| {
        if (err == error.ServerBusy) return error.ServerBusy;
    };
    for (shared.results[0..thread_count]) |result| if (result) |err| {
        if (err != error.PeerWorkerFailed) return err;
    };
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
    worker_callback: ?WorkerProgressCallback,
    worker_context: ?*anyopaque,
    proxy_policy: proxy.Policy,
    retry_hint: ?*@import("retry_after.zig").Hint,
    connection_limit: usize,
    mutex: Io.Mutex = .init,
    next_segment_index: usize = 0,
    active_count: usize = 0,
    failed: std.atomic.Value(bool) = .init(false),
    results: [max_workers]?anyerror = @splat(null),
    in_flight: [max_workers]std.atomic.Value(u64) = @splat(.init(0)),

    fn report(self: *Shared, durable: bool) !void {
        const callback = self.callback orelse return;
        const callback_context = self.callback_context orelse return;
        self.mutex.lockUncancelable(self.io);
        var completed = self.map.completedBytes();
        for (&self.in_flight) |*bytes| completed += bytes.load(.acquire);
        self.mutex.unlock(self.io);
        try callback(callback_context, completed, self.total, durable);
    }

    fn checkpointSegment(self: *Shared, slot: usize, segment_id: u32, durable_cursor: u64) !void {
        const completed = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            try self.map.advance(segment_id, durable_cursor);
            self.in_flight[slot].store(0, .release);
            try segment_journal.saveAtomic(self.allocator, self.io, self.journal_path, .{
                .source_hash = self.source_hash,
                .target_hash = self.target_hash,
                .etag = self.etag,
                .map = self.map,
            });
            break :blk self.map.completedBytes();
        };
        if (self.callback) |callback| {
            if (self.callback_context) |callback_context| {
                try callback(callback_context, completed, self.total, true);
            }
        }
    }

    const Claim = union(enum) { segment: ranges.Segment, wait, done };

    fn claimSegment(self: *Shared) Claim {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.failed.load(.acquire)) return .done;
        while (self.next_segment_index < self.map.len) {
            const segment = self.map.segments[self.next_segment_index];
            self.next_segment_index += 1;
            if (segment.state == .active) {
                self.active_count += 1;
                return .{ .segment = segment };
            }
        }
        return if (self.active_count == 0) .done else .wait;
    }

    fn finishSegment(self: *Shared) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.active_count -= 1;
    }

    fn splitIfIdle(self: *Shared, segment_id: u32) !u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const current_end = try self.map.segmentEnd(segment_id);
        if (self.failed.load(.acquire) or self.active_count >= self.connection_limit or
            self.next_segment_index < self.map.len) return current_end;
        const previous_map = self.map;
        _ = self.map.splitAtCheckpoint(segment_id, minimum_segment_size) catch return current_end;
        segment_journal.saveAtomic(self.allocator, self.io, self.journal_path, .{
            .source_hash = self.source_hash,
            .target_hash = self.target_hash,
            .etag = self.etag,
            .map = self.map,
        }) catch |err| {
            self.map = previous_map;
            return err;
        };
        return self.map.segmentEnd(segment_id);
    }
};

const WorkerContext = struct {
    shared: *Shared,
    slot: usize,
};

fn runWorker(context: *WorkerContext) void {
    while (true) {
        switch (context.shared.claimSegment()) {
        .segment => |segment| {
            runSegment(context.shared, context, segment) catch |err| {
                context.shared.results[context.slot] = err;
                context.shared.failed.store(true, .release);
                context.shared.finishSegment();
                return;
            };
            context.shared.finishSegment();
        },
        .wait => std.Io.sleep(context.shared.io, std.Io.Duration.fromMilliseconds(50), .awake) catch return,
        .done => return,
        }
    }
}

fn runSegment(self: *Shared, context: *WorkerContext, worker: ranges.Segment) !void {
    const header_value = try ranges.formatHeader(self.allocator, .{ .start = worker.cursor, .end = worker.end }, self.total);
    defer self.allocator.free(header_value);
    var client: http.Client = .{ .allocator = self.allocator, .io = self.io };
    var proxy_state = proxy.State.init(self.allocator);
    defer proxy_state.deinit();
    defer client.deinit();
    var uri = try std.Uri.parse(self.url);
    uri.scheme = if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) "https" else "http";
    try proxy_state.apply(&client, self.proxy_policy, uri);
    const headers = [_]http.Header{
        .{ .name = "range", .value = header_value },
        .{ .name = "if-range", .value = self.etag },
    };
    var request = try client.request(.GET, uri, .{
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
        .extra_headers = &headers,
    });
    var response_truncated = false;
    defer {
        if (response_truncated) {
            // A live split shortens our ownership while the server still
            // sends the original range. Close without draining its tail.
            request.connection.?.closing = true;
            request.reader.state = .ready;
        }
        request.deinit();
    }
    try request.sendBodiless();
    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    // Until the exact requested body has been consumed, deinit must close
    // rather than drain a response that may be a full 200 or an endless body.
    response_truncated = true;
    if (response.head.status == .too_many_requests or response.head.status == .service_unavailable) {
        const retry_after = @import("retry_after.zig");
        retry_after.record(self.retry_hint, responseHeader(response.head.bytes, "retry-after"), @intCast(@divTrunc(std.Io.Clock.now(.real, self.io).nanoseconds, std.time.ns_per_s)));
        return error.ServerBusy;
    }
    if (response.head.status == .forbidden) return error.ParallelRangeRejected;
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
    var current_end = worker.end;
    var downloaded: u64 = 0;
    var checkpointed: u64 = 0;
    errdefer {
        // A pause, schedule stop, network error, or worker callback failure
        // must leave a synced cursor for every byte we can safely retain.
        if (downloaded > checkpointed) {
            const synced = blk: {
                file_writer.flush() catch break :blk false;
                file.sync(self.io) catch break :blk false;
                break :blk true;
            };
            if (synced) self.checkpointSegment(context.slot, worker.id, worker.cursor + downloaded) catch {};
        }
    }
    while (remaining > 0) {
        if (self.failed.load(.acquire)) return error.PeerWorkerFailed;
        if (self.callback != null) try self.report(false);
        const amount: usize = @intCast(@min(remaining, chunk_buffer.len));
        const count = body.readSliceShort(chunk_buffer[0..amount]) catch return response.bodyErr().?;
        if (count == 0) return Error.SegmentLengthMismatch;
        try file_writer.interface.writeAll(chunk_buffer[0..count]);
        remaining -= count;
        downloaded += count;
        self.in_flight[context.slot].store(downloaded - checkpointed, .release);
        if (downloaded - checkpointed >= checkpoint_interval) {
            try file_writer.flush();
            try file.sync(self.io);
            try self.checkpointSegment(context.slot, worker.id, worker.cursor + downloaded);
            checkpointed = downloaded;
            current_end = try self.splitIfIdle(worker.id);
            remaining = current_end - (worker.cursor + downloaded);
        }
        if (self.worker_callback) |callback| {
            if (self.worker_context) |callback_context|
                try callback(callback_context, @intCast(context.slot + 1), worker.cursor, current_end, downloaded);
        }
    }
    try file_writer.flush();
    try file.sync(self.io);
    try self.checkpointSegment(context.slot, worker.id, worker.cursor + downloaded);
    response_truncated = current_end < worker.end;
}

fn probeRanges(allocator: Allocator, io: Io, uri: std.Uri, proxy_policy: proxy.Policy, retry_hint: ?*@import("retry_after.zig").Hint) !Probe {
    var client: http.Client = .{ .allocator = allocator, .io = io };
    var proxy_state = proxy.State.init(allocator);
    defer proxy_state.deinit();
    defer client.deinit();
    try proxy_state.apply(&client, proxy_policy, uri);
    const headers = [_]http.Header{.{ .name = "range", .value = "bytes=0-0" }};
    var request = try client.request(.GET, uri, .{
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
        .extra_headers = &headers,
    });
    var abandon_body = false;
    defer {
        if (abandon_body) {
            request.connection.?.closing = true;
            request.reader.state = .ready;
        }
        request.deinit();
    }
    try request.sendBodiless();
    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try request.receiveHead(&redirect_buffer);
    abandon_body = true;
    if (response.head.status == .too_many_requests or response.head.status == .service_unavailable) {
        const retry_after = @import("retry_after.zig");
        retry_after.record(retry_hint, responseHeader(response.head.bytes, "retry-after"), @intCast(@divTrunc(std.Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s)));
        return error.ServerBusy;
    }
    if (response.head.status != .partial_content or response.head.content_encoding != .identity or response.head.content_length != 1) return Error.InvalidProbe;
    const range_text = responseHeader(response.head.bytes, "content-range") orelse return Error.InvalidProbe;
    const content_range = parseContentRange(range_text) orelse return Error.InvalidProbe;
    if (content_range.start != 0 or content_range.end_inclusive != 0 or content_range.total == null) return Error.InvalidProbe;
    const etag = responseHeader(response.head.bytes, "etag") orelse return Error.InvalidProbe;
    if (!isStrongETag(etag) or etag.len > 1024) return Error.InvalidProbe;
    const etag_copy = try allocator.dupe(u8, etag);
    errdefer allocator.free(etag_copy);
    var body_buffer: [1]u8 = undefined;
    var body = response.reader(&body_buffer);
    const count = body.readSliceShort(&body_buffer) catch return response.bodyErr().?;
    if (count != 1) return Error.InvalidProbe;
    abandon_body = false;
    return .{ .total = content_range.total.?, .etag = etag_copy, .target_hash = try uriHash(allocator, request.uri) };
}

fn fileExists(io: Io, path: []const u8) !bool {
    return if (Io.Dir.cwd().statFile(io, path, .{})) |_| true else |err| switch (err) {
        error.FileNotFound => false,
        else => err,
    };
}

fn resumeSafe(uri: std.Uri) bool {
    // The journal binds the exact source URL (including its query) to a strong
    // ETag. A query string therefore does not make a verified range unsafe.
    return uri.user == null and uri.password == null and uri.fragment == null;
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
    if (bytes.len < 2) return null;
    const status_end = std.mem.indexOf(u8, bytes, "\r\n") orelse return null;
    var cursor = status_end + 2;
    var found: ?[]const u8 = null;
    while (cursor + 2 <= bytes.len) {
        const relative_end = std.mem.indexOfPos(u8, bytes, cursor, "\r\n") orelse return null;
        if (relative_end == cursor) return found;
        const line = bytes[cursor..relative_end];
        cursor = relative_end + 2;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) continue;
        if (found != null) return null;
        found = std.mem.trim(u8, line[colon + 1 ..], " \t");
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
