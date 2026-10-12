//! Unix-domain socket adapter for the framed IPC session protocol.
//! This module targets macOS and Linux and links against libc.

const builtin = @import("builtin");
const std = @import("std");
const frame = @import("frame.zig");
const protocol = @import("root.zig");

const c = std.c;
const SocketPath = [*:0]const u8;
const max_socket_path_bytes = if (builtin.os.tag == .macos) 104 else 108;

comptime {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux)
        @compileError("IPC Unix transport supports macOS and Linux only");
}

extern "c" fn socket(domain: c_int, socket_type: c_int, protocol_number: c_int) c_int;
const getErrno = @extern(*const fn () callconv(.c) *c_int, .{
    .name = if (builtin.os.tag == .macos) "__error" else "__errno_location",
});
const lstat = @extern(*const fn ([*:0]const u8, *c.Stat) callconv(.c) c_int, .{
    .name = if (builtin.os.tag == .macos) "lstat$INODE64" else "lstat",
});
extern "c" fn getpid() c_int;

pub const Config = struct {
    /// Private directory owned by this user, such as XDG_RUNTIME_DIR or a
    /// private directory beneath macOS TMPDIR.
    runtime_dir: []const u8,
    app_dir_name: []const u8 = "speed-download",
    socket_name: []const u8 = "engine.sock",
    server: ServerIdentity,
};

pub const ServerIdentity = struct {
    engine_version: []const u8,
    engine_instance_id: []const u8,
    supported_features: []const []const u8,
};

pub const Error = error{
    InvalidPath,
    UnsafeRuntimeDirectory,
    EndpointExists,
    UnexpectedEndOfStream,
    SystemCallFailed,
};

/// Serve clients sequentially. Each accepted connection gets a fresh protocol
/// session, and is authenticated before its first frame is processed.
pub fn serve(allocator: std.mem.Allocator, config: Config) !void {
    var paths = try makePaths(allocator, config);
    defer paths.deinit(allocator);

    try validatePrivateDirectory(config.runtime_dir);
    try ensurePrivateDirectory(paths.app_dir);
    if (pathExists(paths.socket_path)) return Error.EndpointExists;
    const listener = socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (listener < 0) return Error.SystemCallFailed;
    defer _ = c.close(listener);

    var address = try makeAddress(paths.socket_path);
    const address_len: c.socklen_t = if (builtin.os.tag == .macos)
        @intCast(@offsetOf(c.sockaddr.un, "path") + paths.socket_path.len + 1)
    else
        @sizeOf(c.sockaddr.un);
    if (c.bind(listener, @ptrCast(&address), address_len) != 0) {
        std.debug.print("speed-download: IPC bind failed (errno {d})\n", .{getErrno().*});
        return Error.SystemCallFailed;
    }
    var bound_info: c.Stat = undefined;
    if (lstat(paths.socket_z, &bound_info) != 0) return Error.SystemCallFailed;
    defer unlinkIfSame(paths.socket_z, bound_info.dev, bound_info.ino);
    if (c.chmod(paths.socket_z, 0o600) != 0) return Error.SystemCallFailed;
    if (c.listen(listener, 16) != 0) return Error.SystemCallFailed;

    while (true) {
        const client = c.accept(listener, null, null);
        if (client < 0) continue;
        handleClient(allocator, client, config.server) catch {};
    }
}

fn handleClient(allocator: std.mem.Allocator, client: c.fd_t, server: ServerIdentity) !void {
    defer _ = c.close(client);
    if (builtin.os.tag == .macos) {
        var enabled: c_int = 1;
        if (c.setsockopt(client, c.SOL.SOCKET, c.SO.NOSIGPIPE, &enabled, @sizeOf(c_int)) != 0)
            return;
    }
    if (!try peerIsCurrentUser(client)) return;
    try serveConnection(allocator, client, server);
}

fn serveConnection(allocator: std.mem.Allocator, fd: c.fd_t, server: ServerIdentity) !void {
    var session = protocol.Session{};
    var header: [4]u8 = undefined;
    const request_frame = try allocator.alloc(u8, frame.header_bytes + frame.max_payload_bytes);
    defer allocator.free(request_frame);
    var session_id_buffer: [36]u8 = undefined;
    const session_id = uuidString(&session_id_buffer);
    const server_info = protocol.ServerInfo{
        .engine_version = server.engine_version,
        .engine_instance_id = server.engine_instance_id,
        .session_id = session_id,
        .supported_features = server.supported_features,
    };
    while (true) {
        readExact(fd, &header) catch return;
        const length = std.mem.readInt(u32, &header, .little);
        if (length == 0 or length > frame.max_payload_bytes) return;

        readExact(fd, request_frame[frame.header_bytes .. frame.header_bytes + length]) catch return;
        @memcpy(request_frame[0..frame.header_bytes], &header);
        const result = protocol.handleFrame(
            allocator,
            &session,
            request_frame[0 .. frame.header_bytes + length],
            server_info,
        ) catch return;
        if (result.response_frame) |response_frame| {
            writeAll(fd, response_frame) catch {
                allocator.free(response_frame);
                return;
            };
            allocator.free(response_frame);
        }
    }
}

fn uuidString(buffer: *[36]u8) []const u8 {
    const hex = "0123456789abcdef";
    var random_bytes: [16]u8 = undefined;
    // Session IDs are descriptive identifiers, not authentication tokens.
    // Use process-local monotonic entropy here; engine instance identity is
    // generated from the OS secure random source by the daemon entry point.
    const counter = session_counter.fetchAdd(1, .monotonic);
    std.mem.writeInt(u64, random_bytes[0..8], counter, .little);
    std.mem.writeInt(u64, random_bytes[8..16], @intCast(c.getpid()), .little);
    var index: usize = 0;
    for (random_bytes, 0..) |byte, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            buffer[index] = '-';
            index += 1;
        }
        buffer[index] = hex[byte >> 4];
        buffer[index + 1] = hex[byte & 0x0f];
        index += 2;
    }
    return buffer;
}

var session_counter: std.atomic.Value(u64) = .init(0);

fn readExact(fd: c.fd_t, buffer: []u8) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        const count = c.read(fd, buffer[offset..].ptr, buffer.len - offset);
        if (count == 0) return Error.UnexpectedEndOfStream;
        if (count < 0) return Error.SystemCallFailed;
        offset += @intCast(count);
    }
}

fn writeAll(fd: c.fd_t, buffer: []const u8) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        const flags: u32 = if (builtin.os.tag == .linux) c.MSG.NOSIGNAL else 0;
        const count = c.send(fd, buffer[offset..].ptr, buffer.len - offset, flags);
        if (count <= 0) return Error.SystemCallFailed;
        offset += @intCast(count);
    }
}

fn peerIsCurrentUser(fd: c.fd_t) !bool {
    if (builtin.os.tag == .macos) {
        var uid: c.uid_t = 0;
        var gid: c.gid_t = 0;
        return getpeereid(fd, &uid, &gid) == 0 and uid == c.getuid();
    } else {
        const Ucred = extern struct { pid: c_int, uid: c_uint, gid: c_uint };
        var credentials: Ucred = undefined;
        var length: c.socklen_t = @sizeOf(Ucred);
        // Linux SO_PEERCRED is 17 at SOL_SOCKET.
        if (c.getsockopt(fd, c.SOL.SOCKET, 17, &credentials, &length) != 0)
            return Error.SystemCallFailed;
        return credentials.uid == c.getuid();
    }
}

extern "c" fn getpeereid(fd: c_int, euid: *c.uid_t, egid: *c.gid_t) c_int;

const Paths = struct {
    app_dir: [:0]u8,
    socket_path: [:0]u8,
    socket_z: SocketPath,

    fn deinit(self: *Paths, allocator: std.mem.Allocator) void {
        allocator.free(self.app_dir);
        allocator.free(self.socket_path);
    }
};

fn makePaths(allocator: std.mem.Allocator, config: Config) !Paths {
    if (!validComponent(config.app_dir_name) or !validComponent(config.socket_name))
        return Error.InvalidPath;
    if (config.runtime_dir.len == 0 or std.mem.indexOfScalar(u8, config.runtime_dir, 0) != null)
        return Error.InvalidPath;
    const app_path = try std.fs.path.join(allocator, &.{ config.runtime_dir, config.app_dir_name });
    defer allocator.free(app_path);
    const socket_rel = try std.fs.path.join(allocator, &.{ app_path, config.socket_name });
    defer allocator.free(socket_rel);
    const app_dir = try allocator.dupeSentinel(u8, app_path, 0);
    errdefer allocator.free(app_dir);
    const socket_path = try allocator.dupeSentinel(u8, socket_rel, 0);
    errdefer allocator.free(socket_path);
    return .{ .app_dir = app_dir, .socket_path = socket_path, .socket_z = socket_path };
}

fn validComponent(value: []const u8) bool {
    return value.len != 0 and value.len < 80 and
        std.mem.indexOfAny(u8, value, "/\\\x00") == null and
        !std.mem.eql(u8, value, ".") and !std.mem.eql(u8, value, "..");
}

fn validatePrivateDirectory(path: []const u8) !void {
    const path_z = std.heap.page_allocator.dupeSentinel(u8, path, 0) catch return Error.InvalidPath;
    defer std.heap.page_allocator.free(path_z);
    var base_info: c.Stat = undefined;
    if (lstat(path_z, &base_info) != 0 or base_info.uid != c.getuid() or
        base_info.mode & c.S.IFMT != c.S.IFDIR or base_info.mode & 0o077 != 0)
        return Error.UnsafeRuntimeDirectory;
}

fn ensurePrivateDirectory(path: []const u8) !void {
    const path_z = std.heap.page_allocator.dupeSentinel(u8, path, 0) catch return Error.InvalidPath;
    defer std.heap.page_allocator.free(path_z);
    if (c.mkdir(path_z, 0o700) == 0) return;
    var info: c.Stat = undefined;
    if (lstat(path_z, &info) != 0 or info.uid != c.getuid() or
        info.mode & c.S.IFMT != c.S.IFDIR or info.mode & 0o077 != 0)
        return Error.UnsafeRuntimeDirectory;
}

fn pathExists(path: []const u8) bool {
    const path_z = std.heap.page_allocator.dupeSentinel(u8, path, 0) catch return true;
    defer std.heap.page_allocator.free(path_z);
    var stat: c.Stat = undefined;
    return lstat(path_z, &stat) == 0;
}

fn unlinkIfSame(path: SocketPath, device: c.dev_t, inode: c.ino_t) void {
    var current: c.Stat = undefined;
    if (lstat(path, &current) == 0 and current.dev == device and current.ino == inode)
        _ = c.unlink(path);
}

fn makeAddress(path: []const u8) !c.sockaddr.un {
    var address: c.sockaddr.un = undefined;
    const address_bytes: *[@sizeOf(c.sockaddr.un)]u8 = @ptrCast(&address);
    @memset(address_bytes, 0);
    address.len = @sizeOf(c.sockaddr.un);
    address.family = c.AF.UNIX;
    if (path.len >= @min(address.path.len, max_socket_path_bytes)) return Error.InvalidPath;
    if (builtin.os.tag == .macos) address.len = @intCast(@offsetOf(c.sockaddr.un, "path") + path.len + 1);
    @memcpy(address.path[0..path.len], path);
    address.path[path.len] = 0;
    return address;
}
