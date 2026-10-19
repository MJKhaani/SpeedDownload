//! HTTP(S) download with validated multipart and single-stream paths.
//!
//! This driver owns one request, an incomplete file, and a compact resume journal.
//! Resume is enabled only for credential-free URLs with a known length and
//! strong ETag. Durable byte counts advance only after the partial
//! file is synced. The journal stores a SHA-256 URL fingerprint, never the URL.
//! See PROJECT.md DL-02 and storage invariants in section 5.3.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const http = std.http;

/// Range-planning primitives used by the multipart HTTP driver.
pub const range_allocator = @import("ranges.zig");

/// Versioned segment snapshot codec. The filesystem layer must sync segment
/// data before atomically replacing a journal encoded by this module.
pub const segment_journal = @import("segment_journal.zig");

pub const DownloadError = error{
    UnsupportedScheme,
    DestinationExists,
    InvalidResponseStatus,
    InvalidFullResponse,
    UnsupportedContentEncoding,
    UntrustedPartial,
    InvalidResumeJournal,
    HttpJournalUpgradeRequired,
    RepresentationChanged,
    InvalidContentRange,
    ResumeUnsafeForUrl,
    ResponseLengthMismatch,
    ExpectedChecksumMismatch,
};

/// Describes an HTTP byte range. `end_inclusive` follows RFC 9110 wire syntax.
pub const ContentRange = struct {
    start: u64,
    end_inclusive: u64,
    total: ?u64,
};

/// Parses a `Content-Range: bytes first-last/length` value, including `*` total.
pub fn parseContentRange(value: []const u8) ?ContentRange {
    if (!std.mem.startsWith(u8, value, "bytes ")) return null;
    var slash = std.mem.splitScalar(u8, value[6..], '/');
    const range = slash.next() orelse return null;
    const total_text = slash.next() orelse return null;
    if (slash.next() != null) return null;

    var dash = std.mem.splitScalar(u8, range, '-');
    const start_text = dash.next() orelse return null;
    const end_text = dash.next() orelse return null;
    if (dash.next() != null) return null;

    const start = std.fmt.parseInt(u64, start_text, 10) catch return null;
    const end = std.fmt.parseInt(u64, end_text, 10) catch return null;
    if (start > end) return null;
    const total = if (std.mem.eql(u8, total_text, "*")) null else std.fmt.parseInt(u64, total_text, 10) catch return null;
    if (total) |length| if (end >= length) return null;
    return .{ .start = start, .end_inclusive = end, .total = total };
}

/// Returns whether an entity tag is a syntactically valid strong validator.
pub fn isStrongETag(value: []const u8) bool {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return false;
    for (value[1 .. value.len - 1]) |byte| {
        if (byte == '"' or byte < 0x21 or byte == 0x7f) return false;
    }
    return true;
}

const Journal = struct {
    source_hash: [32]u8,
    target_hash: [32]u8,
    total: u64,
    completed: u64,
    etag: []const u8,
};

const journal_magic = "ODMHJ003";
const legacy_journal_magic = "ODMHJ002";
const journal_checksum_len = 32;
const max_etag_len = 1024;
const checkpoint_interval = 1024 * 1024;
const progress_interval = 256 * 1024;

pub const ProgressCallback = *const fn (context: *anyopaque, completed: u64, total: ?u64, durable: bool) anyerror!void;
pub const WorkerProgressCallback = *const fn (context: *anyopaque, worker_id: u32, start: u64, end: u64, downloaded: u64) anyerror!void;

/// Downloads `url` into a sibling `.part` file and safely resumes a prior run.
///
/// A pre-existing destination is never overwritten. A partial is resumed only
/// when its versioned journal matches the URL fingerprint, strong ETag, total
/// size, and durably synced byte prefix. If a server ignores `If-Range` and
/// returns a full 200, the old partial is truncated before the new body is used.
/// A concurrent process could still create the final path while this download
/// runs; final publication uses an atomic no-replace rename to protect it.
pub fn download(allocator: Allocator, io: Io, url: []const u8, destination: []const u8, expected_sha256: ?[32]u8) !void {
    return downloadWithProgress(allocator, io, url, destination, expected_sha256, null, null, null);
}

pub fn downloadWithProgress(
    allocator: Allocator,
    io: Io,
    url: []const u8,
    destination: []const u8,
    expected_sha256: ?[32]u8,
    progress_callback: ?ProgressCallback,
    progress_context: ?*anyopaque,
    worker_callback: ?WorkerProgressCallback,
) !void {
    return downloadWithSettings(allocator, io, url, destination, expected_sha256, progress_callback, progress_context, worker_callback, 4);
}

pub fn downloadWithSettings(
    allocator: Allocator,
    io: Io,
    url: []const u8,
    destination: []const u8,
    expected_sha256: ?[32]u8,
    progress_callback: ?ProgressCallback,
    progress_context: ?*anyopaque,
    worker_callback: ?WorkerProgressCallback,
    requested_connections: u8,
) !void {
    return downloadWithPolicy(allocator, io, url, destination, expected_sha256, progress_callback, progress_context, worker_callback, requested_connections, .{}, null);
}

pub fn downloadWithPolicy(
    allocator: Allocator,
    io: Io,
    url: []const u8,
    destination: []const u8,
    expected_sha256: ?[32]u8,
    progress_callback: ?ProgressCallback,
    progress_context: ?*anyopaque,
    worker_callback: ?WorkerProgressCallback,
    requested_connections: u8,
    proxy_policy: @import("proxy.zig").Policy,
    retry_hint: ?*@import("retry_after.zig").Hint,
) !void {
    const ranged = @import("ranged_download.zig");
    const range_completed = if (requested_connections == 0) false else try ranged.downloadIfSupported(
        allocator,
        io,
        url,
        destination,
        expected_sha256,
        progress_callback,
        progress_context,
        worker_callback,
        progress_context,
        requested_connections,
        proxy_policy,
        retry_hint,
    );
    if (range_completed) return;
    return downloadSingleStreamWithProgress(allocator, io, url, destination, expected_sha256, progress_callback, progress_context, proxy_policy, retry_hint);
}

fn downloadSingleStreamWithProgress(
    allocator: Allocator,
    io: Io,
    url: []const u8,
    destination: []const u8,
    expected_sha256: ?[32]u8,
    progress_callback: ?ProgressCallback,
    progress_context: ?*anyopaque,
    proxy_policy: @import("proxy.zig").Policy,
    retry_hint: ?*@import("retry_after.zig").Hint,
) !void {
    var uri = try std.Uri.parse(url);
    if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) uri.scheme = "http" else if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) uri.scheme = "https" else {
        return DownloadError.UnsupportedScheme;
    }

    const cwd = Io.Dir.cwd();
    if (cwd.statFile(io, destination, .{})) |_| {
        return DownloadError.DestinationExists;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    const part_path = try std.fmt.allocPrint(allocator, "{s}.part", .{destination});
    defer allocator.free(part_path);
    const journal_path = try std.fmt.allocPrint(allocator, "{s}.odm", .{part_path});
    defer allocator.free(journal_path);

    var source_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(url, &source_hash, .{});

    var journal: ?Journal = null;
    defer if (journal) |saved| allocator.free(saved.etag);
    var offset: u64 = 0;
    const part_exists = if (cwd.statFile(io, part_path, .{})) |_| true else |err| switch (err) {
        error.FileNotFound => false,
        else => return err,
    };

    if (part_exists) {
        if (!resumeSafe(uri)) return DownloadError.ResumeUnsafeForUrl;
        journal = try loadJournal(allocator, io, journal_path) orelse return DownloadError.UntrustedPartial;
        const saved = journal.?;
        if (!std.mem.eql(u8, &saved.source_hash, &source_hash) or
            !isStrongETag(saved.etag) or saved.completed > saved.total)
        {
            return DownloadError.UntrustedPartial;
        }
        offset = saved.completed;
    } else {
        if (cwd.statFile(io, journal_path, .{})) |_| {
            cwd.deleteFile(io, journal_path) catch {};
        } else |_| {}
    }

    const file = if (part_exists)
        try cwd.openFile(io, part_path, .{ .mode = .read_write, .allow_directory = false })
    else
        try cwd.createFile(io, part_path, .{ .exclusive = true, .truncate = false, .read = true });
    var file_open = true;
    var completed_successfully = false;
    var preserve_partial = part_exists;
    defer {
        if (file_open) file.close(io);
        if (!completed_successfully and !preserve_partial) {
            cwd.deleteFile(io, part_path) catch {};
            cwd.deleteFile(io, journal_path) catch {};
        }
    }

    if (part_exists) {
        const existing_length = try file.length(io);
        if (existing_length < offset) return DownloadError.InvalidResumeJournal;
        if (existing_length != offset) try file.setLength(io, offset);
    }

    var file_buffer: [16 * 1024]u8 = undefined;
    var file_writer = file.writer(io, &file_buffer);
    try file_writer.seekTo(offset);

    var client: http.Client = .{ .allocator = allocator, .io = io };
    var proxy_state = @import("proxy.zig").State.init(allocator);
    defer proxy_state.deinit();
    defer client.deinit();

    var extra_headers: [2]http.Header = undefined;
    var extra_header_count: usize = 0;
    var range_value: ?[]u8 = null;
    defer if (range_value) |value| allocator.free(value);
    if (offset > 0) {
        const range_start = if (offset == journal.?.total) 0 else offset;
        const range_end = if (offset == journal.?.total) "0-0" else "-";
        range_value = if (offset == journal.?.total)
            try allocator.dupe(u8, "bytes=0-0")
        else
            try std.fmt.allocPrint(allocator, "bytes={d}{s}", .{ range_start, range_end });
        extra_headers[extra_header_count] = .{ .name = "range", .value = range_value.? };
        extra_header_count += 1;
        extra_headers[extra_header_count] = .{ .name = "if-range", .value = journal.?.etag };
        extra_header_count += 1;
    }

    var opened = try @import("proxy.zig").openGet(&client, &proxy_state, proxy_policy, uri, .{
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
        .extra_headers = extra_headers[0..extra_header_count],
    });
    const request = opened.request;
    var response_started = false;
    var body_consumed = false;
    defer {
        if (response_started and !body_consumed) {
            // On pause, cancellation, or an invalid response, do not drain a
            // potentially large body before releasing this connection.
            request.connection.?.closing = true;
            request.reader.state = .ready;
        }
        opened.deinit();
    }
    var response = opened.response;
    response_started = true;
    if (response.head.status == .too_many_requests or response.head.status == .service_unavailable) {
        const retry_after = @import("retry_after.zig");
        retry_after.record(retry_hint, responseHeader(response.head.bytes, "retry-after"), @intCast(@divTrunc(std.Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_s)));
        return error.ServerBusy;
    }
    const target_hash = try uriHash(allocator, request.uri);
    if (response.head.content_encoding != .identity) return DownloadError.UnsupportedContentEncoding;

    if (offset > 0 and response.head.status == .ok) {
        // If-Range failed or the server ignored Range. This is a complete new
        // representation, so discard old bytes before accepting its body.
        try file.setLength(io, 0);
        try file_writer.seekTo(0);
        if (journal) |saved| allocator.free(saved.etag);
        journal = null;
        offset = 0;
        preserve_partial = false;
        cwd.deleteFile(io, journal_path) catch {};
    } else if (offset > 0 and response.head.status == .partial_content) {
        if (!resumeSafe(request.uri)) return DownloadError.ResumeUnsafeForUrl;
        const range_text = responseHeader(response.head.bytes, "content-range") orelse return DownloadError.InvalidContentRange;
        const range = parseContentRange(range_text) orelse return DownloadError.InvalidContentRange;
        const saved = journal.?;
        if (!std.mem.eql(u8, &saved.target_hash, &target_hash)) return DownloadError.RepresentationChanged;
        const expected_start: u64 = if (saved.completed == saved.total) 0 else saved.completed;
        const expected_end: u64 = if (saved.completed == saved.total) 0 else saved.total - 1;
        if (range.start != expected_start or range.end_inclusive != expected_end or range.total != saved.total) {
            return DownloadError.InvalidContentRange;
        }
        if (response.head.content_length) |length| {
            if (length != range.end_inclusive - range.start + 1) return DownloadError.InvalidContentRange;
        }
        const response_etag = responseHeader(response.head.bytes, "etag") orelse return DownloadError.RepresentationChanged;
        if (!isStrongETag(response_etag) or !std.mem.eql(u8, response_etag, saved.etag)) {
            return DownloadError.RepresentationChanged;
        }
        if (saved.completed == saved.total) {
            try verifySha256(io, file, expected_sha256);
            try file.sync(io);
            file.close(io);
            file_open = false;
            try publishNoReplace(cwd, io, part_path, destination);
            completed_successfully = true;
            cwd.deleteFile(io, journal_path) catch {};
            return;
        }
    } else if (response.head.status != .ok) {
        return DownloadError.InvalidResponseStatus;
    }

    if (response.head.status != .ok and response.head.status != .partial_content) {
        return DownloadError.InvalidResponseStatus;
    }
    if (response.head.status == .partial_content and offset == 0) {
        return DownloadError.InvalidFullResponse;
    }
    if (offset == 0 and journal != null) {
        // A zero-byte journal has no verified prefix to preserve. Treat this
        // response as a fresh transfer and bind metadata to its validator.
        if (journal) |saved| allocator.free(saved.etag);
        journal = null;
        preserve_partial = false;
        cwd.deleteFile(io, journal_path) catch {};
    }
    if (!resumeSafe(uri) or !resumeSafe(request.uri)) {
        // User-info and fragments are excluded. The full source URL, including
        // its query, is fingerprinted in the journal without storing the URL.
        if (part_exists) return DownloadError.ResumeUnsafeForUrl;
    }

    var response_total: ?u64 = if (response.head.status == .ok) response.head.content_length else null;
    const response_etag = responseHeader(response.head.bytes, "etag");
    if (response.head.status == .partial_content) {
        const range_text = responseHeader(response.head.bytes, "content-range") orelse return DownloadError.InvalidContentRange;
        const range = parseContentRange(range_text) orelse return DownloadError.InvalidContentRange;
        if (range.start != offset or range.total == null or range.end_inclusive != range.total.? - 1) {
            return DownloadError.InvalidContentRange;
        }
        response_total = range.total;
        if (journal) |saved| {
            if (saved.total != response_total.? or response_etag == null or
                !std.mem.eql(u8, saved.etag, response_etag.?))
            {
                return DownloadError.RepresentationChanged;
            }
        }
    }

    const can_resume = resumeSafe(uri) and resumeSafe(request.uri) and
        response_total != null and response_etag != null and isStrongETag(response_etag.?) and
        response_etag.?.len <= max_etag_len;
    if (can_resume and journal == null) {
        const etag_copy = try allocator.dupe(u8, response_etag.?);
        journal = .{ .source_hash = source_hash, .target_hash = target_hash, .total = response_total.?, .completed = offset, .etag = etag_copy };
        try saveJournal(allocator, io, journal_path, journal.?);
        preserve_partial = true;
    }

    var transfer_buffer: [16 * 1024]u8 = undefined;
    const body_reader = response.reader(&transfer_buffer);
    var sink: CheckpointWriter = .{
        .allocator = allocator,
        .io = io,
        .file = file,
        .file_writer = &file_writer,
        .journal_path = journal_path,
        .journal = if (journal != null) &journal.? else null,
        .total_bytes = response_total,
        .progress_callback = progress_callback,
        .progress_context = progress_context,
        .last_reported_bytes = offset,
        .writer = undefined,
    };
    try sink.reportProgress(true, journal != null);
    sink.writer = .{ .vtable = &.{ .drain = CheckpointWriter.drain, .flush = CheckpointWriter.flush }, .buffer = &sink.buffer };
    _ = body_reader.streamRemaining(&sink.writer) catch |err| switch (err) {
        error.ReadFailed => return response.bodyErr().?,
        error.WriteFailed => return sink.last_error orelse error.WriteFailed,
    };
    body_consumed = true;

    sink.writer.flush() catch return sink.last_error orelse error.WriteFailed;
    try file_writer.flush();
    try file.sync(io);
    try sink.reportProgress(true, true);
    if (response_total) |total| {
        if (file_writer.pos != total) return DownloadError.ResponseLengthMismatch;
    }
    try verifySha256(io, file, expected_sha256);
    file.close(io);
    file_open = false;
    try publishNoReplace(cwd, io, part_path, destination);
    completed_successfully = true;
    cwd.deleteFile(io, journal_path) catch {};
}

pub fn verifySha256(io: Io, file: Io.File, expected: ?[32]u8) !void {
    const wanted = expected orelse return;
    var buffer: [32 * 1024]u8 = undefined;
    var reader = file.reader(io, &buffer);
    try reader.seekTo(0);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var chunk: [32 * 1024]u8 = undefined;
    while (true) {
        const count = try reader.interface.readSliceShort(&chunk);
        if (count == 0) break;
        hasher.update(chunk[0..count]);
    }
    var actual: [32]u8 = undefined;
    hasher.final(&actual);
    if (!std.mem.eql(u8, &actual, &wanted)) return DownloadError.ExpectedChecksumMismatch;
}

pub fn publishNoReplace(dir: Io.Dir, io: Io, part_path: []const u8, destination: []const u8) !void {
    Io.Dir.renamePreserve(dir, part_path, dir, destination, io) catch |err| return switch (err) {
        error.PathAlreadyExists => DownloadError.DestinationExists,
        else => err,
    };
}

fn resumeSafe(uri: std.Uri) bool {
    return uri.user == null and uri.password == null and uri.fragment == null;
}

fn uriHash(allocator: Allocator, uri: std.Uri) ![32]u8 {
    var formatted = Io.Writer.Allocating.init(allocator);
    defer formatted.deinit();
    try uri.format(&formatted.writer);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(formatted.writer.buffered(), &hash, .{});
    return hash;
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

fn loadJournal(allocator: Allocator, io: Io, path: []const u8) !?Journal {
    const data = cwdReadFileAlloc(io, path, allocator) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(data);
    const fixed_len = journal_magic.len + 32 + 32 + 8 + 8 + 2;
    if (data.len >= legacy_journal_magic.len and std.mem.eql(u8, data[0..legacy_journal_magic.len], legacy_journal_magic)) {
        return DownloadError.HttpJournalUpgradeRequired;
    }
    if (data.len < fixed_len + journal_checksum_len or !std.mem.eql(u8, data[0..journal_magic.len], journal_magic)) {
        return DownloadError.InvalidResumeJournal;
    }
    var actual_checksum: [journal_checksum_len]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data[0 .. data.len - journal_checksum_len], &actual_checksum, .{});
    if (!std.mem.eql(u8, &actual_checksum, data[data.len - journal_checksum_len ..])) return DownloadError.InvalidResumeJournal;
    var cursor = journal_magic.len;
    var source_hash: [32]u8 = undefined;
    @memcpy(&source_hash, data[cursor..][0..source_hash.len]);
    cursor += source_hash.len;
    var target_hash: [32]u8 = undefined;
    @memcpy(&target_hash, data[cursor..][0..target_hash.len]);
    cursor += target_hash.len;
    const total = std.mem.readInt(u64, data[cursor..][0..8], .big);
    cursor += 8;
    const completed = std.mem.readInt(u64, data[cursor..][0..8], .big);
    cursor += 8;
    const etag_len = std.mem.readInt(u16, data[cursor..][0..2], .big);
    cursor += 2;
    if (etag_len == 0 or etag_len > max_etag_len or data.len != cursor + etag_len + journal_checksum_len) {
        return DownloadError.InvalidResumeJournal;
    }
    const etag = try allocator.dupe(u8, data[cursor .. cursor + etag_len]);
    if (!isStrongETag(etag) or completed > total) {
        allocator.free(etag);
        return DownloadError.InvalidResumeJournal;
    }
    return .{ .source_hash = source_hash, .target_hash = target_hash, .total = total, .completed = completed, .etag = etag };
}

fn cwdReadFileAlloc(io: Io, path: []const u8, allocator: Allocator) ![]u8 {
    return Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(journal_magic.len + 32 + 32 + 8 + 8 + 2 + max_etag_len + journal_checksum_len));
}

fn saveJournal(allocator: Allocator, io: Io, path: []const u8, journal: Journal) !void {
    if (journal.etag.len == 0 or journal.etag.len > max_etag_len or journal.etag.len > std.math.maxInt(u16)) {
        return DownloadError.InvalidResumeJournal;
    }
    const fixed_len = journal_magic.len + 32 + 32 + 8 + 8 + 2;
    const encoded = try allocator.alloc(u8, fixed_len + journal.etag.len + journal_checksum_len);
    defer allocator.free(encoded);
    var cursor: usize = 0;
    @memcpy(encoded[cursor..][0..journal_magic.len], journal_magic);
    cursor += journal_magic.len;
    @memcpy(encoded[cursor..][0..journal.source_hash.len], &journal.source_hash);
    cursor += journal.source_hash.len;
    @memcpy(encoded[cursor..][0..journal.target_hash.len], &journal.target_hash);
    cursor += journal.target_hash.len;
    std.mem.writeInt(u64, encoded[cursor..][0..8], journal.total, .big);
    cursor += 8;
    std.mem.writeInt(u64, encoded[cursor..][0..8], journal.completed, .big);
    cursor += 8;
    std.mem.writeInt(u16, encoded[cursor..][0..2], @intCast(journal.etag.len), .big);
    cursor += 2;
    @memcpy(encoded[cursor..][0..journal.etag.len], journal.etag);
    cursor += journal.etag.len;
    var checksum: [journal_checksum_len]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(encoded[0..cursor], &checksum, .{});
    @memcpy(encoded[cursor..][0..journal_checksum_len], &checksum);

    const temp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(temp_path);
    const cwd = Io.Dir.cwd();
    cwd.deleteFile(io, temp_path) catch {};
    const temp_file = try cwd.createFile(io, temp_path, .{ .exclusive = true, .truncate = false });
    var is_open = true;
    defer {
        if (is_open) temp_file.close(io);
        cwd.deleteFile(io, temp_path) catch {};
    }
    var buffer: [256]u8 = undefined;
    var writer = temp_file.writer(io, &buffer);
    try writer.interface.writeAll(encoded);
    try writer.flush();
    try temp_file.sync(io);
    temp_file.close(io);
    is_open = false;
    try Io.Dir.rename(cwd, temp_path, cwd, path, io);
}

const CheckpointWriter = struct {
    writer: Io.Writer,
    buffer: [16 * 1024]u8 = undefined,
    allocator: Allocator,
    io: Io,
    file: Io.File,
    file_writer: *Io.File.Writer,
    journal_path: []const u8,
    journal: ?*Journal,
    pending_bytes: u64 = 0,
    total_bytes: ?u64,
    progress_callback: ?ProgressCallback,
    progress_context: ?*anyopaque,
    last_reported_bytes: u64,
    last_error: ?anyerror = null,

    fn drain(writer: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const self: *CheckpointWriter = @alignCast(@fieldParentPtr("writer", writer));
        const buffered = writer.buffered();
        self.writeAll(buffered) catch return error.WriteFailed;
        _ = writer.consume(buffered.len);
        for (data[0 .. data.len - 1]) |slice| self.writeAll(slice) catch return error.WriteFailed;
        for (0..splat) |_| self.writeAll(data[data.len - 1]) catch return error.WriteFailed;
        const count = Io.Writer.countSplat(data, splat);
        self.pending_bytes += buffered.len + count;
        self.reportProgress(false, false) catch |err| {
            self.last_error = err;
            return error.WriteFailed;
        };
        if (self.journal != null and self.pending_bytes >= checkpoint_interval) {
            self.checkpoint() catch |err| {
                self.last_error = err;
                return error.WriteFailed;
            };
        }
        return count;
    }

    fn writeAll(self: *CheckpointWriter, bytes: []const u8) Io.Writer.Error!void {
        self.file_writer.interface.writeAll(bytes) catch |err| {
            self.last_error = err;
            return error.WriteFailed;
        };
    }

    fn flush(writer: *Io.Writer) Io.Writer.Error!void {
        const self: *CheckpointWriter = @alignCast(@fieldParentPtr("writer", writer));
        const buffered = writer.buffered();
        self.writeAll(buffered) catch return error.WriteFailed;
        _ = writer.consume(buffered.len);
        self.file_writer.flush() catch |err| {
            self.last_error = err;
            return error.WriteFailed;
        };
        if (self.journal) |_| self.checkpoint() catch |err| {
            self.last_error = err;
            return error.WriteFailed;
        };
        self.reportProgress(true, false) catch |err| {
            self.last_error = err;
            return error.WriteFailed;
        };
    }

    fn reportProgress(self: *CheckpointWriter, force: bool, durable: bool) anyerror!void {
        const callback = self.progress_callback orelse return;
        const context = self.progress_context orelse return;
        const completed = self.file_writer.pos;
        if (!force and completed -| self.last_reported_bytes < progress_interval) return;
        try callback(context, completed, self.total_bytes, durable);
        self.last_reported_bytes = completed;
    }

    fn checkpoint(self: *CheckpointWriter) !void {
        try self.file_writer.flush();
        try self.file.sync(self.io);
        if (self.journal) |saved| {
            saved.completed = self.file_writer.pos;
            try saveJournal(self.allocator, self.io, self.journal_path, saved.*);
            try self.reportProgress(true, true);
        }
        self.pending_bytes = 0;
    }
};

test "rejects unsupported schemes without creating files" {
    try std.testing.expectError(
        DownloadError.UnsupportedScheme,
        download(std.testing.allocator, Io.Threaded.global_single_threaded.io(), "ftp://example.invalid/file", "unused-test-output", null),
    );
}

test "parses valid content range forms and rejects invalid boundaries" {
    try std.testing.expectEqual(
        ContentRange{ .start = 0, .end_inclusive = 9, .total = 10 },
        parseContentRange("bytes 0-9/10").?,
    );
    try std.testing.expectEqual(
        ContentRange{ .start = 9, .end_inclusive = 19, .total = null },
        parseContentRange("bytes 9-19/*").?,
    );
    try std.testing.expect(parseContentRange("bytes 10-9/20") == null);
    try std.testing.expect(parseContentRange("bytes 0-10/10") == null);
    try std.testing.expect(parseContentRange("items 0-9/10") == null);
}

test "accepts strong entity tags and rejects weak or malformed tags" {
    try std.testing.expect(isStrongETag("\"abc-123\""));
    try std.testing.expect(isStrongETag("\"\""));
    try std.testing.expect(!isStrongETag("W/\"abc\""));
    try std.testing.expect(!isStrongETag("abc"));
    try std.testing.expect(!isStrongETag("\"bad\"tag\""));
}
