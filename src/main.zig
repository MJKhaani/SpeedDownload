//! Command-line entry point for the standalone download engine prototype.

const std = @import("std");
const builtin = @import("builtin");
const download = @import("protocols/http/download.zig").download;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "engine")) {
        try runEngine(init);
        return;
    }
    if (args.len >= 3 and std.mem.eql(u8, args[1], "rpc")) {
        try runRpc(init, args);
        return;
    }
    if (args.len == 2 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) {
        std.debug.print("Usage: speed-download [engine | rpc <list|add|control> ... | [--sha256 <64-hex-digits>] <http(s)-url> <destination>]\n", .{});
        return;
    }
    var expected_sha256: ?[32]u8 = null;
    var url_index: usize = 1;
    if (args.len == 5 and std.mem.eql(u8, args[1], "--sha256")) {
        var digest: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&digest, args[2]) catch {
            std.debug.print("speed-download: --sha256 requires exactly 64 hexadecimal digits\n", .{});
            return error.InvalidChecksum;
        };
        expected_sha256 = digest;
        url_index = 3;
    } else if (args.len != 3) {
        std.debug.print("Usage: speed-download [--sha256 <64-hex-digits>] <http(s)-url> <destination>\n", .{});
        return error.InvalidArguments;
    }

    download(init.gpa, init.io, args[url_index], args[url_index + 1], expected_sha256) catch |err| {
        std.debug.print("speed-download: {s}\n", .{errorMessage(err)});
        return err;
    };
}

fn runRpc(init: std.process.Init, args: []const []const u8) !void {
    const allocator = init.gpa;
    var params: []u8 = undefined;
    var method: []const u8 = undefined;
    if (std.mem.eql(u8, args[2], "list") and args.len == 3) {
        method = "jobs.list";
        params = try allocator.dupe(u8, "{\"offset\":0,\"limit\":50}");
    } else if (std.mem.eql(u8, args[2], "add") and (args.len == 5 or args.len == 6)) {
        method = "jobs.add";
        var key_bytes: [16]u8 = undefined;
        try init.io.randomSecure(&key_bytes);
        var key_buffer: [36]u8 = undefined;
        const idempotency_key = formatUuid(&key_buffer, key_bytes);
        const name: ?[]const u8 = if (args.len == 6) args[5] else null;
        params = try std.json.Stringify.valueAlloc(allocator, .{
            .url = args[3],
            .destination = args[4],
            .name = name,
            .idempotency_key = idempotency_key,
            .priority = @as(i32, 0),
        }, .{});
    } else if (std.mem.eql(u8, args[2], "control") and args.len == 6) {
        method = "jobs.control";
        params = try std.json.Stringify.valueAlloc(allocator, .{
            .job_id = args[3],
            .action = args[4],
            .expected_revision = args[5],
        }, .{});
    } else {
        std.debug.print("Usage: speed-download rpc list\n       speed-download rpc add <http(s)-url> <destination-folder> [name]\n       speed-download rpc control <job-id> <start|pause|resume|retry|cancel> <revision>\n", .{});
        return error.InvalidRpcArguments;
    }
    defer allocator.free(params);
    const response = try @import("ipc/client.zig").call(allocator, init, method, params);
    defer allocator.free(response);
    try std.Io.File.stdout().writeStreamingAll(init.io, response);
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
}

fn runEngine(init: std.process.Init) !void {
    if (comptime builtin.os.tag == .windows) {
        const windows_ipc = @import("ipc/windows.zig");
        const JobStore = @import("core/job_store.zig").Store;
        const local_app_data = init.environ_map.get("LOCALAPPDATA") orelse return error.StateDirectoryUnavailable;
        const state_directory = if (init.environ_map.get("SPEED_DOWNLOAD_STATE_DIR")) |override|
            try init.gpa.dupe(u8, override)
        else
            try std.fs.path.join(init.gpa, &.{ local_app_data, "Speed Download" });
        defer init.gpa.free(state_directory);
        var jobs = try JobStore.open(init.gpa, init.io, state_directory);
        defer jobs.deinit();

        var instance_bytes: [16]u8 = undefined;
        try init.io.randomSecure(&instance_bytes);
        var instance_id_buffer: [36]u8 = undefined;
        const instance_id = formatUuid(&instance_id_buffer, instance_bytes);
        const features = [_][]const u8{};
        std.debug.print("Speed Download engine starting; named pipe is scoped to this user session\n", .{});
        try windows_ipc.serve(init.gpa, .{
            .jobs = &jobs,
            .server = .{
                .engine_version = "0.1.0",
                .engine_instance_id = instance_id,
                .supported_features = &features,
            },
        });
    } else if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) {
        return error.EngineTransportUnavailable;
    } else {
        const unix_ipc = @import("ipc/unix.zig");
        const JobStore = @import("core/job_store.zig").Store;
        const raw_runtime_dir = if (builtin.os.tag == .macos)
            (init.environ_map.get("TMPDIR") orelse return error.RuntimeDirectoryUnavailable)
        else
            (init.environ_map.get("XDG_RUNTIME_DIR") orelse return error.RuntimeDirectoryUnavailable);
        const trimmed_runtime_dir = std.mem.trimEnd(u8, raw_runtime_dir, "/");
        const runtime_dir = if (trimmed_runtime_dir.len == 0) "/" else trimmed_runtime_dir;

        const home = init.environ_map.get("HOME") orelse return error.HomeDirectoryUnavailable;
        const state_directory = if (init.environ_map.get("SPEED_DOWNLOAD_STATE_DIR")) |override|
            try init.gpa.dupe(u8, override)
        else if (builtin.os.tag == .macos)
            try std.fs.path.join(init.gpa, &.{ home, "Library", "Application Support", "Speed Download" })
        else if (init.environ_map.get("XDG_STATE_HOME")) |state_home|
            try std.fs.path.join(init.gpa, &.{ state_home, "speed-download" })
        else
            try std.fs.path.join(init.gpa, &.{ home, ".local", "state", "speed-download" });
        defer init.gpa.free(state_directory);
        var jobs = try JobStore.open(init.gpa, init.io, state_directory);
        defer jobs.deinit();

        var instance_bytes: [16]u8 = undefined;
        try init.io.randomSecure(&instance_bytes);
        var instance_id_buffer: [36]u8 = undefined;
        const instance_id = formatUuid(&instance_id_buffer, instance_bytes);

        const features = [_][]const u8{};
        std.debug.print("Speed Download engine starting; IPC endpoint: {s}/speed-download/engine.sock\n", .{runtime_dir});
        try unix_ipc.serve(init.gpa, .{
            .runtime_dir = runtime_dir,
            .jobs = &jobs,
            .server = .{
                .engine_version = "0.1.0",
                .engine_instance_id = instance_id,
                .supported_features = &features,
            },
        });
    }
}

fn formatUuid(uuid: *[36]u8, bytes: [16]u8) []const u8 {
    const hex = "0123456789abcdef";
    var index: usize = 0;
    for (bytes, 0..) |byte, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            uuid[index] = '-';
            index += 1;
        }
        uuid[index] = hex[byte >> 4];
        uuid[index + 1] = hex[byte & 0x0f];
        index += 2;
    }
    return uuid;
}

fn errorMessage(err: anyerror) []const u8 {
    return if (err == error.UnsupportedScheme)
        "only http:// and https:// URLs are supported"
    else if (err == error.DestinationExists)
        "destination already exists; choose a different path"
    else if (err == error.UntrustedPartial)
        "partial file has no matching trusted resume journal; move or remove the .part file to restart"
    else if (err == error.ResumeUnsafeForUrl)
        "this URL may contain private data and cannot be safely resumed; remove its .part file to restart"
    else if (err == error.RepresentationChanged)
        "the remote file changed since the saved partial; its bytes were not appended"
    else if (err == error.InvalidResponseStatus)
        "the server returned an unsuccessful HTTP status"
    else if (err == error.InvalidContentRange)
        "the server returned an inconsistent byte range"
    else if (err == error.UnsupportedContentEncoding)
        "the server returned an encoded body; only identity responses are safe"
    else if (err == error.ResponseLengthMismatch)
        "the response ended before the declared file length"
    else if (err == error.ExpectedChecksumMismatch)
        "SHA-256 mismatch; the file was not published at its destination"
    else if (err == error.InvalidResumeJournal)
        "resume metadata is invalid; move or remove the .part and .part.odm files to restart"
    else if (err == error.InvalidFullResponse)
        "the server returned partial content without a valid resume request"
    else
        @errorName(err);
}
