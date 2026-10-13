//! Small native IPC client used by the headless RPC CLI.

const builtin = @import("builtin");
const std = @import("std");
const protocol = @import("root.zig");
const frame = @import("frame.zig");
const c = std.c;
const Allocator = std.mem.Allocator;

const Transport = if (builtin.os.tag == .windows) std.os.windows.HANDLE else c.fd_t;

const Error = error{
    EndpointUnavailable,
    InvalidEndpoint,
    TransportUnavailable,
    ReadFailed,
    WriteFailed,
    UnexpectedEndOfStream,
    InvalidResponse,
    RemoteError,
};

extern "kernel32" fn CreateFileW(
    name: [*:0]const u16,
    desired_access: u32,
    share_mode: u32,
    security_attributes: ?*anyopaque,
    creation_disposition: u32,
    flags_and_attributes: u32,
    template_file: ?std.os.windows.HANDLE,
) callconv(.winapi) std.os.windows.HANDLE;
extern "kernel32" fn ReadFile(
    file: std.os.windows.HANDLE,
    buffer: [*]u8,
    bytes_to_read: u32,
    bytes_read: *u32,
    overlapped: ?*anyopaque,
) callconv(.winapi) i32;
extern "kernel32" fn WriteFile(
    file: std.os.windows.HANDLE,
    buffer: [*]const u8,
    bytes_to_write: u32,
    bytes_written: *u32,
    overlapped: ?*anyopaque,
) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(handle: std.os.windows.HANDLE) callconv(.winapi) i32;
extern "kernel32" fn Sleep(milliseconds: u32) callconv(.winapi) void;

const Request = struct {
    jsonrpc: []const u8 = "2.0",
    id: u32,
    method: []const u8,
    params: std.json.Value,
};

pub fn call(allocator: Allocator, init: std.process.Init, method: []const u8, params_json: []const u8) ![]u8 {
    var parsed_params = try std.json.parseFromSlice(std.json.Value, allocator, params_json, .{});
    defer parsed_params.deinit();
    if (parsed_params.value != .object) return Error.InvalidResponse;

    const transport = try connect(allocator, init);
    defer close(transport);

    const hello = try exchange(allocator, init.io, transport, .{
        .id = 1,
        .method = "engine.hello",
        .params = try helloParams(allocator),
    });
    defer allocator.free(hello);
    try validateResult(allocator, hello, 1);

    const response = try exchange(allocator, init.io, transport, .{
        .id = 2,
        .method = method,
        .params = parsed_params.value,
    });
    errdefer allocator.free(response);
    try validateResult(allocator, response, 2);
    return response;
}

fn helloParams(allocator: Allocator) !std.json.Value {
    const json = "{\"protocol\":{\"major\":1,\"minor\":0},\"client\":{\"kind\":\"speed-download-cli\",\"version\":\"0.1.0\"},\"features\":[]}";
    return try std.json.parseFromSliceLeaky(std.json.Value, allocator, json, .{});
}

fn validateResult(allocator: Allocator, response: []const u8, expected_id: u32) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return Error.InvalidResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return Error.InvalidResponse;
    const object = parsed.value.object;
    const version = object.get("jsonrpc") orelse return Error.InvalidResponse;
    const id = object.get("id") orelse return Error.InvalidResponse;
    if (version != .string or !std.mem.eql(u8, version.string, "2.0") or id != .integer or id.integer != expected_id)
        return Error.InvalidResponse;
    if (object.contains("error")) return Error.RemoteError;
    if (!object.contains("result")) return Error.InvalidResponse;
}

fn exchange(allocator: Allocator, io: std.Io, transport: Transport, request: Request) ![]u8 {
    const payload = try std.json.Stringify.valueAlloc(allocator, request, .{});
    defer allocator.free(payload);
    const encoded = try frame.encode(allocator, payload);
    defer allocator.free(encoded);
    try writeAll(io, transport, encoded);

    var header: [frame.header_bytes]u8 = undefined;
    try readExact(io, transport, &header);
    const length = std.mem.readInt(u32, &header, .little);
    if (length == 0 or length > frame.max_payload_bytes) return Error.InvalidResponse;
    const response = try allocator.alloc(u8, length);
    errdefer allocator.free(response);
    try readExact(io, transport, response);
    return response;
}

fn connect(allocator: Allocator, init: std.process.Init) !Transport {
    if (comptime builtin.os.tag == .windows) {
        const windows_ipc = @import("windows.zig");
        const pipe_name = try windows_ipc.pipeName(allocator);
        defer allocator.free(pipe_name);
        var attempts: u16 = 0;
        while (attempts < 200) : (attempts += 1) {
            const pipe = CreateFileW(pipe_name, 0x80000000 | 0x40000000, 0, null, 3, 0, null);
            if (pipe != std.os.windows.INVALID_HANDLE_VALUE) return pipe;
            Sleep(25);
        }
        return Error.EndpointUnavailable;
    } else if (comptime builtin.os.tag == .macos or builtin.os.tag == .linux) {
        const runtime = if (builtin.os.tag == .macos)
            (init.environ_map.get("TMPDIR") orelse return Error.InvalidEndpoint)
        else
            (init.environ_map.get("XDG_RUNTIME_DIR") orelse return Error.InvalidEndpoint);
        const endpoint = try std.fs.path.join(allocator, &.{ runtime, "speed-download", "engine.sock" });
        defer allocator.free(endpoint);
        const endpoint_z = try allocator.dupeSentinel(u8, endpoint, 0);
        defer allocator.free(endpoint_z);
        if (endpoint.len >= @min(@sizeOf(c.sockaddr.un) - @offsetOf(c.sockaddr.un, "path"), if (builtin.os.tag == .macos) 104 else 108))
            return Error.InvalidEndpoint;
        const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
        if (fd < 0) return Error.EndpointUnavailable;
        var address: c.sockaddr.un = undefined;
        const address_bytes: *[@sizeOf(c.sockaddr.un)]u8 = @ptrCast(&address);
        @memset(address_bytes, 0);
        if (comptime builtin.os.tag == .macos) address.len = @sizeOf(c.sockaddr.un);
        address.family = c.AF.UNIX;
        @memcpy(address.path[0..endpoint.len], endpoint);
        address.path[endpoint.len] = 0;
        const address_len: c.socklen_t = if (builtin.os.tag == .macos)
            @intCast(@offsetOf(c.sockaddr.un, "path") + endpoint.len + 1)
        else
            @sizeOf(c.sockaddr.un);
        if (c.connect(fd, @ptrCast(&address), address_len) != 0) {
            _ = c.close(fd);
            return Error.EndpointUnavailable;
        }
        return fd;
    } else {
        return Error.TransportUnavailable;
    }
}

fn close(transport: Transport) void {
    if (comptime builtin.os.tag == .windows) {
        _ = CloseHandle(transport);
    } else {
        _ = c.close(transport);
    }
}

fn readExact(io: std.Io, transport: Transport, buffer: []u8) !void {
    _ = io;
    var offset: usize = 0;
    while (offset < buffer.len) {
        const amount: isize = if (comptime builtin.os.tag == .windows) blk: {
            var count: u32 = 0;
            if (ReadFile(transport, buffer[offset..].ptr, @intCast(@min(buffer.len - offset, std.math.maxInt(u32))), &count, null) == 0)
                return Error.ReadFailed;
            break :blk @intCast(count);
        } else blk: {
            const count = c.read(transport, buffer[offset..].ptr, buffer.len - offset);
            if (count < 0) return Error.ReadFailed;
            break :blk count;
        };
        if (amount == 0) return Error.UnexpectedEndOfStream;
        offset += @intCast(amount);
    }
}

fn writeAll(io: std.Io, transport: Transport, buffer: []const u8) !void {
    _ = io;
    var offset: usize = 0;
    while (offset < buffer.len) {
        const amount: isize = if (comptime builtin.os.tag == .windows) blk: {
            var count: u32 = 0;
            if (WriteFile(transport, buffer[offset..].ptr, @intCast(@min(buffer.len - offset, std.math.maxInt(u32))), &count, null) == 0)
                return Error.WriteFailed;
            break :blk @intCast(count);
        } else blk: {
            const count = c.write(transport, buffer[offset..].ptr, buffer.len - offset);
            if (count < 0) return Error.WriteFailed;
            break :blk count;
        };
        if (amount == 0) return Error.WriteFailed;
        offset += @intCast(amount);
    }
}
