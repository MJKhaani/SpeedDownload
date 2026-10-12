//! Single-stream HTTP(S) download prototype.
//!
//! This driver owns one request and a temporary output file. It validates the
//! URL scheme, relies on std.http.Client's certificate validation and bounded
//! redirect handling, rejects non-2xx responses, syncs the completed `.part`
//! file, and renames only after success. It does not resume, persist job
//! metadata, checksum content, or support byte ranges; see PROJECT.md DL-02.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const http = std.http;

pub const DownloadError = error{
    UnsupportedScheme,
    DestinationExists,
    InvalidResponseStatus,
};

/// Downloads `url` into an exclusive sibling `.part` file.
///
/// The destination must not already exist. On any request, status, write, or
/// sync error, the partial file is removed. On success it is renamed into place.
/// A concurrent process could create the final path between the existence check
/// and rename; callers should serialize operations targeting the same path.
pub fn download(allocator: Allocator, io: Io, url: []const u8, destination: []const u8) !void {
    const uri = try std.Uri.parse(url);
    if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) {
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

    const file = try cwd.createFile(io, part_path, .{ .exclusive = true, .truncate = false });
    var file_open = true;
    var keep_partial = false;
    defer {
        if (file_open) file.close(io);
        if (!keep_partial) cwd.deleteFile(io, part_path) catch {};
    }

    var client: http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var file_buffer: [16 * 1024]u8 = undefined;
    var file_writer = file.writer(io, &file_buffer);
    const identity_header = http.Header{ .name = "accept-encoding", .value = "identity" };
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .extra_headers = &.{identity_header},
        .response_writer = &file_writer.interface,
    });

    if (result.status.class() != .success) return DownloadError.InvalidResponseStatus;

    try file_writer.flush();
    try file.sync(io);
    file.close(io);
    file_open = false;
    try Io.Dir.rename(cwd, part_path, cwd, destination, io);
    keep_partial = true;
}

test "rejects unsupported schemes without creating files" {
    try std.testing.expectError(
        DownloadError.UnsupportedScheme,
        download(std.testing.allocator, Io.Threaded.global_single_threaded.io(), "ftp://example.invalid/file", "unused-test-output"),
    );
}
