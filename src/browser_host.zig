//! Restricted Firefox native-messaging bridge. It accepts one explicit link
//! handoff and never exposes arbitrary engine methods or filesystem paths.
const std = @import("std");
const builtin = @import("builtin");
const client = @import("ipc/client.zig");

const extension_id = "speed-download@mjkhaani.github";
const chrome_extension_id = "fcjiipabggcamlocakedfideaamdgknn";
const chrome_origin = "chrome-extension://" ++ chrome_extension_id ++ "/";
const max_message_bytes = 16 * 1024;

pub fn main(init: std.process.Init) !void {
    if (comptime builtin.os.tag != .macos) return error.UnsupportedPlatform;
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "--print-firefox-manifest")) {
        const executable = try std.process.executablePathAlloc(init.io, allocator);
        defer allocator.free(executable);
        const manifest = try std.json.Stringify.valueAlloc(allocator, .{
            .name = "com.mjkhaani.speeddownload",
            .description = "Speed Download Firefox link handoff",
            .path = executable,
            .type = "stdio",
            .allowed_extensions = &.{extension_id},
        }, .{});
        defer allocator.free(manifest);
        try std.Io.File.stdout().writeStreamingAll(init.io, manifest);
        try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
        return;
    }
    if (args.len == 2 and std.mem.eql(u8, args[1], "--print-chrome-manifest")) {
        const executable = try std.process.executablePathAlloc(init.io, allocator);
        defer allocator.free(executable);
        const manifest = try std.json.Stringify.valueAlloc(allocator, .{
            .name = "com.mjkhaani.speeddownload",
            .description = "Speed Download Chrome handoff",
            .path = executable,
            .type = "stdio",
            .allowed_origins = &.{chrome_origin},
        }, .{});
        defer allocator.free(manifest);
        try std.Io.File.stdout().writeStreamingAll(init.io, manifest);
        try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
        return;
    }
    const firefox_caller = args.len == 3 and std.mem.eql(u8, args[2], extension_id);
    const chrome_caller = args.len == 2 and std.mem.eql(u8, args[1], chrome_origin);
    if (!firefox_caller and !chrome_caller) {
        try reply(allocator, init.io, .{ .version = 1, .ok = false, .error_message = "Extension is not authorized" });
        return;
    }
    const message = readMessage(allocator, init.io) catch {
        try reply(allocator, init.io, .{ .version = 1, .ok = false, .error_message = "Invalid native message" });
        return;
    };
    defer allocator.free(message);
    const request = parseRequest(allocator, message) catch {
        try reply(allocator, init.io, .{ .version = 1, .ok = false, .error_message = "Invalid native request" });
        return;
    };
    defer request.parsed.deinit();
    if (request.action == .status) {
        const current = client.call(allocator, init, "settings.get", "{}") catch |err| {
            if (err == error.EndpointUnavailable) {
                try reply(allocator, init.io, .{ .version = 1, .ok = true, .engine_running = false });
            } else {
                try reply(allocator, init.io, .{ .version = 1, .ok = false, .error_message = "Could not contact the engine" });
            }
            return;
        };
        defer allocator.free(current);
        try reply(allocator, init.io, .{ .version = 1, .ok = true, .engine_running = true });
        return;
    }

    const settings = settingsWithEngineStart(allocator, init) catch {
        try reply(allocator, init.io, .{ .version = 1, .ok = false, .error_message = "Speed Download engine is unavailable" });
        return;
    };
    defer allocator.free(settings);
    const destination = defaultFolder(allocator, settings) catch {
        try reply(allocator, init.io, .{ .version = 1, .ok = false, .error_message = "Set a default download folder in Speed Download" });
        return;
    };
    defer destination.parsed.deinit();

    const params = try std.json.Stringify.valueAlloc(allocator, .{
        .url = request.url.?,
        .destination = destination.folder,
        .idempotency_key = request.key.?,
        .priority = @as(i32, 0),
    }, .{});
    defer allocator.free(params);
    const added = client.call(allocator, init, "jobs.add", params) catch {
        try reply(allocator, init.io, .{ .version = 1, .ok = false, .error_message = "The engine rejected this download" });
        return;
    };
    defer allocator.free(added);
    const job_id = addedJobId(allocator, added) catch {
        try reply(allocator, init.io, .{ .version = 1, .ok = false, .error_message = "Invalid engine response" });
        return;
    };
    defer job_id.parsed.deinit();
    try reply(allocator, init.io, .{ .version = 1, .ok = true, .job_id = job_id.id });
}

fn settingsWithEngineStart(allocator: std.mem.Allocator, init: std.process.Init) ![]u8 {
    return client.call(allocator, init, "settings.get", "{}") catch |err| {
        if (err != error.EndpointUnavailable) return err;
        const host_path = try std.process.executablePathAlloc(init.io, allocator);
        defer allocator.free(host_path);
        const helper_path = try std.fs.path.join(allocator, &.{ std.fs.path.dirname(host_path) orelse return error.InvalidHostPath, "speed-download" });
        defer allocator.free(helper_path);
        // Native messaging can only wake the engine shipped beside this host.
        // Never resolve an engine through PATH or browser-controlled input.
        _ = try std.process.spawn(init.io, .{
            .argv = &.{ helper_path, "engine" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
            // Firefox may tear down the native host's process group when its
            // one-message connection closes. The engine must survive it.
            .pgid = 0,
        });
        for (0..80) |_| {
            std.Io.sleep(init.io, .fromMilliseconds(50), .awake) catch {};
            if (client.call(allocator, init, "settings.get", "{}")) |settings| return settings else |retry_err| {
                if (retry_err != error.EndpointUnavailable) return retry_err;
            }
        }
        return error.EndpointUnavailable;
    };
}

const Request = struct {
    parsed: std.json.Parsed(std.json.Value),
    action: enum { add, status },
    url: ?[]const u8 = null,
    key: ?[]const u8 = null,
};

fn parseRequest(allocator: std.mem.Allocator, message: []const u8) !Request {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, message, .{});
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRequest;
    const object = parsed.value.object;
    const version = object.get("version") orelse return error.InvalidRequest;
    const action = object.get("action") orelse return error.InvalidRequest;
    if (version != .integer or version.integer != 1 or action != .string) return error.InvalidRequest;
    if (std.mem.eql(u8, action.string, "status")) {
        if (object.count() != 2) return error.InvalidRequest;
        return .{ .parsed = parsed, .action = .status };
    }
    if (!std.mem.eql(u8, action.string, "add") or object.count() != 4) return error.InvalidRequest;
    const url = object.get("url") orelse return error.InvalidRequest;
    const key = object.get("idempotency_key") orelse return error.InvalidRequest;
    if (url != .string or key != .string)
        return error.InvalidRequest;
    if (url.string.len == 0 or url.string.len > 8192 or !validUuid(key.string)) return error.InvalidRequest;
    if (std.mem.startsWith(u8, url.string, "magnet:")) {
        var magnet = @import("protocols/torrent/magnet.zig").inspect(allocator, url.string) catch return error.InvalidRequest;
        defer magnet.deinit(allocator);
        return .{ .parsed = parsed, .action = .add, .url = url.string, .key = key.string };
    }
    const uri = std.Uri.parse(url.string) catch return error.InvalidRequest;
    if (!(std.ascii.eqlIgnoreCase(uri.scheme, "http") or std.ascii.eqlIgnoreCase(uri.scheme, "https")) or
        uri.host == null or uri.user != null or uri.password != null or uri.fragment != null)
        return error.InvalidRequest;
    return .{ .parsed = parsed, .action = .add, .url = url.string, .key = key.string };
}

fn validUuid(value: []const u8) bool {
    if (value.len != 36) return false;
    for (value, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (byte != '-') return false;
        } else if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

const Folder = struct { parsed: std.json.Parsed(std.json.Value), folder: []const u8 };

fn defaultFolder(allocator: std.mem.Allocator, response: []const u8) !Folder {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSettings;
    const result = parsed.value.object.get("result") orelse return error.InvalidSettings;
    if (result != .object) return error.InvalidSettings;
    const folder = result.object.get("default_download_folder") orelse return error.InvalidSettings;
    if (folder != .string or folder.string.len == 0 or folder.string[0] != '/') return error.InvalidSettings;
    return .{ .parsed = parsed, .folder = folder.string };
}

const Added = struct { parsed: std.json.Parsed(std.json.Value), id: []const u8 };

fn addedJobId(allocator: std.mem.Allocator, response: []const u8) !Added {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidResponse;
    const result = parsed.value.object.get("result") orelse return error.InvalidResponse;
    if (result != .object) return error.InvalidResponse;
    const id = result.object.get("job_id") orelse return error.InvalidResponse;
    if (id != .string or id.string.len == 0 or id.string.len > 128) return error.InvalidResponse;
    return .{ .parsed = parsed, .id = id.string };
}

fn readExact(io: std.Io, output: []u8) !void {
    var offset: usize = 0;
    while (offset < output.len) {
        const chunks: [1][]u8 = .{output[offset..]};
        const amount = try std.Io.File.stdin().readStreaming(io, &chunks);
        if (amount == 0) return error.EndOfStream;
        offset += amount;
    }
}

fn readMessage(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    var header: [4]u8 = undefined;
    try readExact(io, &header);
    const length = std.mem.readInt(u32, &header, .little);
    if (length == 0 or length > max_message_bytes) return error.InvalidMessageLength;
    const payload = try allocator.alloc(u8, length);
    errdefer allocator.free(payload);
    try readExact(io, payload);
    return payload;
}

const Reply = struct {
    version: u8,
    ok: bool,
    job_id: ?[]const u8 = null,
    engine_running: ?bool = null,
    error_message: ?[]const u8 = null,
};

fn reply(allocator: std.mem.Allocator, io: std.Io, value: Reply) !void {
    const payload = try std.json.Stringify.valueAlloc(allocator, value, .{ .emit_null_optional_fields = false });
    defer allocator.free(payload);
    const length: u32 = @intCast(payload.len);
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, length, .little);
    try std.Io.File.stdout().writeStreamingAll(io, &header);
    try std.Io.File.stdout().writeStreamingAll(io, payload);
}
