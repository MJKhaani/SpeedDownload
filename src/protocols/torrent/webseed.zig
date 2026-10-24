//! BEP 19 single-file HTTP(S) gap filling. Only SHA-1 verified pieces reach disk.
const std = @import("std");
const Io = std.Io;
const metainfo = @import("metainfo.zig");
const http_download = @import("../http/download.zig");
const proxy = @import("../http/proxy.zig");
const metadata = @import("metadata.zig");

pub const Transfer = struct {
    allocator: std.mem.Allocator,
    io: Io,
    info: metainfo.Result,
    file: Io.File,
    buffer: []u8,
    verified: []bool,
    remaining: *usize,
    verified_bytes: *u64,
    callback: ?http_download.ProgressCallback,
    context: ?*anyopaque,
    control: ?metadata.CheckpointCallback,
    control_context: ?*anyopaque,
    policy: proxy.Policy,
    budget: ?*http_download.connection_budget.Budget,
    stats: ?metadata.StatsCallback,
    stats_context: ?*anyopaque,
    activity: std.atomic.Value(i64) = .init(0),

    fn tick(self: *Transfer) void {
        self.activity.store(@intCast(@divTrunc(Io.Clock.now(.awake, self.io).nanoseconds, std.time.ns_per_ms)), .release);
    }

    /// Join cancellation before returning: all slices and progress pointers
    /// remain caller-owned. An idle server cannot strand a queue worker.
    pub fn run(self: *Transfer, url: []const u8) !void {
        var complete: Io.Event = .unset;
        self.tick();
        var future = try Io.concurrent(self.io, task, .{ self, url, &complete });
        var joined = false;
        defer if (!joined) {
            future.cancel(self.io) catch {};
        };
        while (true) {
            if (self.control) |check| if (self.control_context) |ctx| try check(ctx);
            complete.waitTimeout(self.io, .{ .duration = .{ .raw = .fromMilliseconds(250), .clock = .awake } }) catch |err| {
                if (err != error.Timeout) return err;
                const now = @divTrunc(Io.Clock.now(.awake, self.io).nanoseconds, std.time.ns_per_ms);
                if (now - self.activity.load(.acquire) > 15_000) return error.Timeout;
                continue;
            };
            joined = true;
            return future.await(self.io);
        }
    }

    fn reportProgress(self: *Transfer, completed: u64, durable: bool) !void {
        if (self.callback) |report| if (self.context) |ctx| {
            report(ctx, completed, self.info.total_bytes, durable) catch |err| {
                if (err == error.TransferPauseRequested or err == error.TransferCancelRequested or err == error.TransferSchedulePaused) return err;
                // Do not mistake a job-store failure for a replaceable seed.
                return error.WebSeedProgressFailed;
            };
        };
    }

    fn task(self: *Transfer, url: []const u8, complete: *Io.Event) anyerror!void {
        defer complete.set(self.io);
        var client: std.http.Client = .{ .allocator = self.allocator, .io = self.io };
        var state = proxy.State.initWithBudget(self.allocator, self.budget, self.control, self.control_context);
        defer state.deinit();
        defer client.deinit();
        const uri = try std.Uri.parse(url);
        while (self.remaining.* > 0) {
            var first: usize = 0;
            while (first < self.verified.len and self.verified[first]) : (first += 1) {}
            if (first == self.verified.len) return;
            var last = first + 1;
            // Request contiguous gaps, not one HTTP request per torrent piece.
            while (last < self.verified.len and !self.verified[last] and
                (last - first) * self.info.piece_length < 64 * 1024 * 1024) : (last += 1)
            {}
            const start = first * self.info.piece_length;
            const end = @min(@as(u64, @intCast(last)) * self.info.piece_length, self.info.total_bytes);
            const range = try std.fmt.allocPrint(self.allocator, "bytes={d}-{d}", .{ start, end - 1 });
            defer self.allocator.free(range);
            const headers = [_]std.http.Header{.{ .name = "range", .value = range }};
            var opened = try proxy.openGet(&client, &state, self.policy, uri, .{
                .headers = .{ .accept_encoding = .{ .override = "identity" } },
                .extra_headers = &headers,
            });
            var consumed = false;
            defer {
                if (!consumed) {
                    opened.request.connection.?.closing = true;
                    opened.request.reader.state = .ready;
                }
                opened.deinit();
            }
            self.tick();
            if (self.stats) |report| if (self.stats_context) |ctx| {
                const host = switch (uri.host.?) {
                    .raw, .percent_encoded => |text| text,
                };
                const label = try std.fmt.allocPrint(self.allocator, "Web seed: {s}", .{host});
                defer self.allocator.free(label);
                report(ctx, 0, .{ .peer_event = true, .active_peer = label });
            };
            defer if (self.stats) |report| {
                if (self.stats_context) |ctx| report(ctx, 0, .{ .peer_event = true });
            };
            if (opened.response.head.content_encoding != .identity) return error.InvalidWebSeedResponse;
            if (opened.response.head.status == .partial_content) {
                const text = responseHeader(opened.response.head.bytes, "content-range") orelse return error.InvalidWebSeedResponse;
                const parsed = http_download.parseContentRange(text) orelse return error.InvalidWebSeedResponse;
                if (parsed.start != start or parsed.end_inclusive != end - 1 or parsed.total != self.info.total_bytes)
                    return error.InvalidWebSeedResponse;
            } else if (opened.response.head.status != .ok or start != 0 or end != self.info.total_bytes) return error.InvalidWebSeedResponse;
            if (opened.response.head.content_length) |length| if (length != end - start) return error.InvalidWebSeedResponse;
            var body_buffer: [16 * 1024]u8 = undefined;
            var body = opened.response.reader(&body_buffer);
            for (first..last) |index| {
                const offset = index * self.info.piece_length;
                const length: usize = @intCast(@min(self.info.piece_length, self.info.total_bytes - offset));
                var read: usize = 0;
                while (read < length) {
                    const amount = try body.readSliceShort(self.buffer[read..@min(length, read + 16 * 1024)]);
                    if (amount == 0) return error.ResponseLengthMismatch;
                    read += amount;
                    self.tick();
                    try self.reportProgress(self.verified_bytes.* + read, false);
                }
                var hash: [20]u8 = undefined;
                std.crypto.hash.Sha1.hash(self.buffer[0..length], &hash, .{});
                if (!std.mem.eql(u8, &hash, self.info.piece_hashes[index * 20 ..][0..20])) return error.TorrentPieceHashMismatch;
                self.file.writePositionalAll(self.io, self.buffer[0..length], offset) catch return error.WebSeedStorageFailed;
                self.file.sync(self.io) catch return error.WebSeedStorageFailed;
                self.verified[index] = true;
                self.verified_bytes.* += length;
                self.remaining.* -= 1;
                self.tick();
                try self.reportProgress(self.verified_bytes.*, true);
            }
            var extra: [1]u8 = undefined;
            if (try body.readSliceShort(&extra) != 0) return error.ResponseLengthMismatch;
            consumed = true;
        }
    }
};

fn responseHeader(bytes: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, bytes, "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..colon], name)) return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}
