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
    if (args.len == 2 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) {
        std.debug.print("Usage: speed-download [engine | [--sha256 <64-hex-digits>] <http(s)-url> <destination>]\n", .{});
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

fn runEngine(init: std.process.Init) !void {
    if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) {
        return error.EngineTransportUnavailable;
    } else {
        const unix_ipc = @import("ipc/unix.zig");
        const raw_runtime_dir = if (builtin.os.tag == .macos)
            (init.environ_map.get("TMPDIR") orelse return error.RuntimeDirectoryUnavailable)
        else
            (init.environ_map.get("XDG_RUNTIME_DIR") orelse return error.RuntimeDirectoryUnavailable);
        const trimmed_runtime_dir = std.mem.trimEnd(u8, raw_runtime_dir, "/");
        const runtime_dir = if (trimmed_runtime_dir.len == 0) "/" else trimmed_runtime_dir;

        var instance_bytes: [16]u8 = undefined;
        try init.io.randomSecure(&instance_bytes);
        var instance_id_buffer: [36]u8 = undefined;
        const instance_id = formatUuid(&instance_id_buffer, instance_bytes);

        const features = [_][]const u8{};
        std.debug.print("Speed Download engine starting; IPC endpoint: {s}/speed-download/engine.sock\n", .{runtime_dir});
        try unix_ipc.serve(init.gpa, .{
            .runtime_dir = runtime_dir,
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
