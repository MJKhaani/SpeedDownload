//! Command-line entry point for the standalone download engine prototype.

const std = @import("std");
const builtin = @import("builtin");
const http_download = @import("protocols/http/download.zig").download;
const ftp_download = @import("protocols/ftp/download.zig").download;
const torrent_metainfo = @import("protocols/torrent/metainfo.zig");
const torrent_magnet = @import("protocols/torrent/magnet.zig");
const torrent_metadata = @import("protocols/torrent/metadata.zig");
const torrent_download = @import("protocols/torrent/download.zig").download;

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
    if (args.len == 3 and std.mem.eql(u8, args[1], "torrent-info")) {
        try runTorrentInfo(init, args[2]);
        return;
    }
    if (args.len == 3 and std.mem.eql(u8, args[1], "magnet-info")) {
        try runMagnetInfo(init, args[2]);
        return;
    }
    if (args.len == 4 and std.mem.eql(u8, args[1], "magnet-metadata")) {
        try runMagnetMetadata(init, args[2], args[3]);
        return;
    }
    if (args.len == 4 and std.mem.eql(u8, args[1], "magnet-download")) {
        try torrent_download(init.gpa, init.io, args[2], args[3], null, null, null);
        return;
    }
    if (args.len == 4 and std.mem.eql(u8, args[1], "torrent-download")) {
        try @import("protocols/torrent/download.zig").downloadTorrentFile(init.gpa, init.io, args[2], args[3], null, null, null);
        return;
    }
    if (args.len == 2 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) {
        std.debug.print("Usage: speed-download [engine | torrent-info <file.torrent> | torrent-download <file.torrent> <destination-file> | magnet-info <magnet-uri> | magnet-metadata <magnet-uri> <output.torrent> | magnet-download <magnet-uri> <destination-file> | rpc <list|probe|add|control|reorder|delete> ... | [--sha256 <64-hex-digits>] <download-url> <destination>]\n", .{});
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
        std.debug.print("Usage: speed-download [--sha256 <64-hex-digits>] <download-url> <destination>\n", .{});
        return error.InvalidArguments;
    }

    const transfer = if (isFtpUrl(args[url_index]))
        ftp_download(init.gpa, init.io, args[url_index], args[url_index + 1], expected_sha256, null, null)
    else
        http_download(init.gpa, init.io, args[url_index], args[url_index + 1], expected_sha256);
    transfer catch |err| {
        std.debug.print("speed-download: {s}\n", .{errorMessage(err)});
        return err;
    };
}

fn runTorrentInfo(init: std.process.Init, path: []const u8) !void {
    const bytes = try std.Io.Dir.readFileAlloc(.cwd(), init.io, path, init.gpa, .limited(torrent_metainfo.max_metainfo_bytes));
    defer init.gpa.free(bytes);
    const info = try torrent_metainfo.inspect(init.gpa, bytes);
    const file_map = try torrent_metainfo.inspectFileMap(init.gpa, bytes);
    defer file_map.deinit(init.gpa);
    var hash_hex: [40]u8 = undefined;
    const alphabet = "0123456789abcdef";
    for (info.info_hash, 0..) |byte, index| {
        hash_hex[index * 2] = alphabet[byte >> 4];
        hash_hex[index * 2 + 1] = alphabet[byte & 0x0f];
    }
    const json = try std.json.Stringify.valueAlloc(init.gpa, .{
        .name = info.name,
        .announce = info.announce,
        .total_bytes = info.total_bytes,
        .file_count = info.file_count,
        .files = file_map.files,
        .piece_length = info.piece_length,
        .piece_count = info.piece_count,
        .info_hash = &hash_hex,
    }, .{});
    defer init.gpa.free(json);
    try std.Io.File.stdout().writeStreamingAll(init.io, json);
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
}

fn runMagnetInfo(init: std.process.Init, uri: []const u8) !void {
    var info = try torrent_magnet.inspect(init.gpa, uri);
    defer info.deinit(init.gpa);
    var hash_hex: [40]u8 = undefined;
    const alphabet = "0123456789abcdef";
    for (info.info_hash, 0..) |byte, index| {
        hash_hex[index * 2] = alphabet[byte >> 4];
        hash_hex[index * 2 + 1] = alphabet[byte & 0x0f];
    }
    const json = try std.json.Stringify.valueAlloc(init.gpa, .{
        .info_hash = &hash_hex,
        .display_name = info.display_name,
        .trackers = info.trackers,
        .peers = info.peers,
        .status = "metadata_required",
    }, .{});
    defer init.gpa.free(json);
    try std.Io.File.stdout().writeStreamingAll(init.io, json);
    try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
}

fn runMagnetMetadata(init: std.process.Init, uri: []const u8, output_path: []const u8) !void {
    var link = try torrent_magnet.inspect(init.gpa, uri);
    defer link.deinit(init.gpa);
    const raw_info = try torrent_metadata.fetch(init.gpa, init.io, &link);
    defer init.gpa.free(raw_info);
    var metainfo_bytes: std.ArrayList(u8) = .empty;
    defer metainfo_bytes.deinit(init.gpa);
    try metainfo_bytes.appendSlice(init.gpa, "d");
    if (link.trackers.len > 0) {
        const announce = link.trackers[0];
        const prefix = try std.fmt.allocPrint(init.gpa, "8:announce{d}:", .{announce.len});
        defer init.gpa.free(prefix);
        try metainfo_bytes.appendSlice(init.gpa, prefix);
        try metainfo_bytes.appendSlice(init.gpa, announce);
        try metainfo_bytes.appendSlice(init.gpa, "13:announce-listl");
        for (link.trackers) |tracker| {
            try metainfo_bytes.appendSlice(init.gpa, "l");
            const tracker_prefix = try std.fmt.allocPrint(init.gpa, "{d}:", .{tracker.len});
            defer init.gpa.free(tracker_prefix);
            try metainfo_bytes.appendSlice(init.gpa, tracker_prefix);
            try metainfo_bytes.appendSlice(init.gpa, tracker);
            try metainfo_bytes.appendSlice(init.gpa, "e");
        }
        try metainfo_bytes.appendSlice(init.gpa, "e");
    }
    try metainfo_bytes.appendSlice(init.gpa, "4:info");
    try metainfo_bytes.appendSlice(init.gpa, raw_info);
    try metainfo_bytes.appendSlice(init.gpa, "e");
    _ = try torrent_metainfo.inspect(init.gpa, metainfo_bytes.items);
    var suffix: [16]u8 = undefined;
    try init.io.randomSecure(&suffix);
    var suffix_hex: [32]u8 = undefined;
    const alphabet = "0123456789abcdef";
    for (suffix, 0..) |byte, index| {
        suffix_hex[index * 2] = alphabet[byte >> 4];
        suffix_hex[index * 2 + 1] = alphabet[byte & 0x0f];
    }
    const temporary_path = try std.fmt.allocPrint(init.gpa, "{s}.tmp-{s}", .{ output_path, &suffix_hex });
    defer init.gpa.free(temporary_path);
    const cwd = std.Io.Dir.cwd();
    const file = try cwd.createFile(init.io, temporary_path, .{ .exclusive = true, .truncate = false });
    var file_open = true;
    defer if (file_open) file.close(init.io);
    defer cwd.deleteFile(init.io, temporary_path) catch {};
    try file.writeStreamingAll(init.io, metainfo_bytes.items);
    try file.sync(init.io);
    file.close(init.io);
    file_open = false;
    try @import("protocols/http/download.zig").publishNoReplace(cwd, init.io, temporary_path, output_path);
    try std.Io.File.stdout().writeStreamingAll(init.io, "Verified torrent metadata saved.\n");
}

fn runRpc(init: std.process.Init, args: []const []const u8) !void {
    const allocator = init.gpa;
    var params: []u8 = undefined;
    var method: []const u8 = undefined;
    if (std.mem.eql(u8, args[2], "list") and args.len == 3) {
        method = "jobs.list";
        params = try allocator.dupe(u8, "{\"offset\":0,\"limit\":50}");
    } else if (std.mem.eql(u8, args[2], "probe") and args.len == 4) {
        method = "jobs.probe";
        params = try std.json.Stringify.valueAlloc(allocator, .{ .url = args[3] }, .{});
    } else if (std.mem.eql(u8, args[2], "add") and (args.len == 5 or args.len == 6 or args.len == 7 or args.len == 8)) {
        method = "jobs.add";
        const has_checksum = args.len >= 7;
        if (has_checksum and !std.mem.eql(u8, args[args.len - 2], "--sha256")) return error.InvalidRpcArguments;
        const checksum: ?[]const u8 = if (has_checksum) args[args.len - 1] else null;
        if (checksum) |digest| {
            var bytes: [32]u8 = undefined;
            _ = std.fmt.hexToBytes(&bytes, digest) catch return error.InvalidChecksum;
        }
        var key_bytes: [16]u8 = undefined;
        try init.io.randomSecure(&key_bytes);
        var key_buffer: [36]u8 = undefined;
        const idempotency_key = formatUuid(&key_buffer, key_bytes);
        const name: ?[]const u8 = if (args.len == 6 or args.len == 8) args[5] else null;
        params = try std.json.Stringify.valueAlloc(allocator, .{
            .url = args[3],
            .destination = args[4],
            .name = name,
            .idempotency_key = idempotency_key,
            .priority = @as(i32, 0),
            .expected_sha256 = checksum,
        }, .{});
    } else if (std.mem.eql(u8, args[2], "control") and args.len == 6) {
        method = "jobs.control";
        params = try std.json.Stringify.valueAlloc(allocator, .{
            .job_id = args[3],
            .action = args[4],
            .expected_revision = args[5],
        }, .{});
    } else if (std.mem.eql(u8, args[2], "reorder") and args.len == 6) {
        method = "jobs.reorder";
        const position = try std.fmt.parseInt(i64, args[4], 10);
        if (position < 0) return error.InvalidRpcArguments;
        params = try std.json.Stringify.valueAlloc(allocator, .{
            .job_id = args[3],
            .position = position,
            .expected_revision = args[5],
        }, .{});
    } else if (std.mem.eql(u8, args[2], "delete") and (args.len == 5 or args.len == 6)) {
        method = "jobs.delete";
        const delete_partial = args.len == 6 and std.mem.eql(u8, args[5], "--delete-partial");
        if (args.len == 6 and !delete_partial) return error.InvalidRpcArguments;
        params = try std.json.Stringify.valueAlloc(allocator, .{
            .job_id = args[3],
            .expected_revision = args[4],
            .delete_partial = delete_partial,
        }, .{});
    } else {
        std.debug.print("Usage: speed-download rpc list\n       speed-download rpc probe <download-url>\n       speed-download rpc add <download-url> <destination-folder> [name] [--sha256 <64-hex-digits>]\n       speed-download rpc control <job-id> <start|pause|resume|retry|cancel> <revision>\n       speed-download rpc reorder <job-id> <position> <revision>\n       speed-download rpc delete <job-id> <revision> [--delete-partial]\n", .{});
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
        jobs.logAction("engine", "started");

        var instance_bytes: [16]u8 = undefined;
        try init.io.randomSecure(&instance_bytes);
        var instance_id_buffer: [36]u8 = undefined;
        const instance_id = formatUuid(&instance_id_buffer, instance_bytes);
        const features = [_][]const u8{ "jobs.probe", "jobs.worker-progress", "jobs.probe-filename-decoding", "jobs.change-wait", "jobs.per-job-bandwidth", "settings.persisted-v2", "settings.weekly-schedules", "torrents.magnet-v1-single-file" };
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
        jobs.logAction("engine", "started");

        var instance_bytes: [16]u8 = undefined;
        try init.io.randomSecure(&instance_bytes);
        var instance_id_buffer: [36]u8 = undefined;
        const instance_id = formatUuid(&instance_id_buffer, instance_bytes);

        const features = [_][]const u8{ "jobs.probe", "jobs.worker-progress", "jobs.probe-filename-decoding", "jobs.change-wait", "jobs.per-job-bandwidth", "settings.persisted-v2", "settings.weekly-schedules", "torrents.magnet-v1-single-file", "torrents.local-file-v1-single-file" };
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

fn isFtpUrl(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    return std.ascii.eqlIgnoreCase(uri.scheme, "ftp") or std.ascii.eqlIgnoreCase(uri.scheme, "ftps");
}

fn errorMessage(err: anyerror) []const u8 {
    return if (err == error.UnsupportedScheme)
        "only http://, https://, ftp://, and ftps:// URLs are supported"
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
