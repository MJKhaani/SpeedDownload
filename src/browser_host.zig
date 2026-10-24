//! Restricted browser-to-client bridge. It never imports or calls engine IPC.
const std = @import("std");
const builtin = @import("builtin");
const posix_stat = @import("core/posix_stat.zig");
extern "c" fn chmod(path: [*:0]const u8, mode: std.c.mode_t) c_int;
const extension_id = "speed-download@mjkhaani.github";
const chrome_origin = "chrome-extension://fcjiipabggcamlocakedfideaamdgknn/";
const max_message_bytes = 256 * 1024;

pub fn main(init: std.process.Init) !void {
    if (comptime builtin.os.tag != .macos) return error.UnsupportedPlatform;
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and (std.mem.eql(u8, args[1], "--print-firefox-manifest") or std.mem.eql(u8, args[1], "--print-chrome-manifest"))) {
        const executable = try std.process.executablePathAlloc(init.io, allocator);
        defer allocator.free(executable);
        const manifest = if (std.mem.eql(u8, args[1], "--print-firefox-manifest"))
            try std.json.Stringify.valueAlloc(allocator, .{ .name = "com.mjkhaani.speeddownload", .description = "Speed Download client handoff", .path = executable, .type = "stdio", .allowed_extensions = &.{extension_id} }, .{})
        else
            try std.json.Stringify.valueAlloc(allocator, .{ .name = "com.mjkhaani.speeddownload", .description = "Speed Download client handoff", .path = executable, .type = "stdio", .allowed_origins = &.{chrome_origin} }, .{});
        defer allocator.free(manifest);
        try std.Io.File.stdout().writeStreamingAll(init.io, manifest);
        try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
        return;
    }
    const firefox = args.len == 3 and std.mem.eql(u8, args[2], extension_id);
    const chrome = args.len == 2 and std.mem.eql(u8, args[1], chrome_origin);
    if (!firefox and !chrome) return reply(allocator, init.io, .{ .ok = false, .error_message = "Extension is not authorized" });
    const message = readMessage(allocator, init.io) catch return reply(allocator, init.io, .{ .ok = false, .error_message = "Invalid native message" });
    defer allocator.free(message);
    const request = parseRequest(allocator, message) catch return reply(allocator, init.io, .{ .ok = false, .error_message = "Invalid client handoff" });
    defer request.parsed.deinit();
    const app = appPath(allocator, init.io) catch return reply(allocator, init.io, .{ .ok = false, .error_message = "The Speed Download client was not found" });
    defer allocator.free(app);
    if (request.status) return reply(allocator, init.io, .{ .ok = true, .client_available = true });
    sendToClient(allocator, init, app, message, request.key.?) catch return reply(allocator, init.io, .{ .ok = false, .error_message = "Could not open the Speed Download client" });
    try reply(allocator, init.io, .{ .ok = true, .dialog_opened = true });
}

const Request = struct { parsed: std.json.Parsed(std.json.Value), status: bool = false, key: ?[]const u8 = null };
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
        return .{ .parsed = parsed, .status = true };
    }
    const reference = object.get("reference_url");
    if (object.count() != (if (reference != null) @as(usize, 5) else 4)) return error.InvalidRequest;
    if (reference) |value| {
        if (value != .string or !validURL(value.string) or
            !(std.mem.startsWith(u8, value.string, "https://") or std.mem.startsWith(u8, value.string, "http://"))) return error.InvalidRequest;
    }
    const key = object.get("idempotency_key") orelse return error.InvalidRequest;
    if (key != .string or !validUuid(key.string)) return error.InvalidRequest;
    if (std.mem.eql(u8, action.string, "batch")) {
        const urls = object.get("urls") orelse return error.InvalidRequest;
        if (urls != .array or urls.array.items.len == 0 or urls.array.items.len > 100) return error.InvalidRequest;
        var total: usize = 0;
        for (urls.array.items) |url| {
            if (url != .string or !validURL(url.string)) return error.InvalidRequest;
            total += url.string.len;
        }
        if (total > 128 * 1024) return error.InvalidRequest;
    } else if (std.mem.eql(u8, action.string, "add") or std.mem.eql(u8, action.string, "torrent")) {
        const url = object.get("url") orelse return error.InvalidRequest;
        if (url != .string or !validURL(url.string)) return error.InvalidRequest;
    } else return error.InvalidRequest;
    return .{ .parsed = parsed, .key = key.string };
}

fn validURL(url: []const u8) bool {
    if (url.len == 0 or url.len > 8192 or !std.unicode.utf8ValidateSlice(url)) return false;
    for (url) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    if (url.len >= 7 and std.ascii.eqlIgnoreCase(url[0..7], "magnet:")) return std.mem.indexOf(u8, url, "xt=") != null;
    const uri = std.Uri.parse(url) catch return false;
    return (std.ascii.eqlIgnoreCase(uri.scheme, "http") or std.ascii.eqlIgnoreCase(uri.scheme, "https")) and
        uri.host != null and uri.user == null and uri.password == null and uri.fragment == null;
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

fn appPath(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const host = try std.process.executablePathAlloc(io, allocator);
    defer allocator.free(host);
    const helpers = std.fs.path.dirname(host) orelse return error.InvalidHostPath;
    const contents = std.fs.path.dirname(helpers) orelse return error.InvalidHostPath;
    const app = std.fs.path.dirname(contents) orelse return error.InvalidHostPath;
    if (!std.mem.endsWith(u8, app, ".app")) return error.InvalidHostPath;
    return allocator.dupe(u8, app);
}

fn sendToClient(allocator: std.mem.Allocator, init: std.process.Init, app: []const u8, message: []const u8, key: []const u8) !void {
    const home_directory = init.environ_map.get("HOME") orelse return error.HomeUnavailable;
    if (!std.fs.path.isAbsolute(home_directory)) return error.HomeUnavailable;
    const inbox = try std.fs.path.join(allocator, &.{ home_directory, "Library", "Application Support", "Speed Download", "BrowserInbox" });
    defer allocator.free(inbox);
    try std.Io.Dir.cwd().createDirPath(init.io, inbox);
    const inbox_z = try allocator.dupeSentinel(u8, inbox, 0);
    defer allocator.free(inbox_z);
    const info = posix_stat.get(inbox_z, false) orelse return error.InvalidInbox;
    if (!posix_stat.isDirectory(info) or info.uid != posix_stat.currentUid() or chmod(inbox_z, 0o700) != 0) return error.InvalidInbox;
    const filename = try std.fmt.allocPrint(allocator, "{s}.json", .{key});
    defer allocator.free(filename);
    const path = try std.fs.path.join(allocator, &.{ inbox, filename });
    defer allocator.free(path);
    var atomic = try std.Io.Dir.createFileAtomic(.cwd(), init.io, path, .{ .permissions = .fromMode(0o600) });
    defer atomic.deinit(init.io);
    try atomic.file.writeStreamingAll(init.io, message);
    try atomic.file.sync(init.io);
    atomic.link(init.io) catch |err| if (err != error.PathAlreadyExists) return err;
    const handoff = try std.fmt.allocPrint(allocator, "speeddownload://browser?request={s}", .{key});
    defer allocator.free(handoff);
    var child = try std.process.spawn(init.io, .{ .argv = &.{ "/usr/bin/open", "-a", app, handoff }, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
    const term = try child.wait(init.io);
    if (!term.success()) return error.ClientLaunchFailed;
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
    version: u8 = 1,
    ok: bool,
    client_available: ?bool = null,
    dialog_opened: ?bool = null,
    error_message: ?[]const u8 = null,
};
fn reply(allocator: std.mem.Allocator, io: std.Io, value: Reply) !void {
    const payload = try std.json.Stringify.valueAlloc(allocator, value, .{ .emit_null_optional_fields = false });
    defer allocator.free(payload);
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(payload.len), .little);
    try std.Io.File.stdout().writeStreamingAll(io, &header);
    try std.Io.File.stdout().writeStreamingAll(io, payload);
}
