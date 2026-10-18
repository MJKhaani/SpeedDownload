//! Windows named-pipe transport for the shared framed IPC session protocol.
//!
//! Pipe names are scoped to the current user's SID and logon session. The
//! kernel DACL grants access only to that SID and LocalSystem, and remote pipe
//! clients are rejected. Byte mode and bounded length-prefixed frames match
//! the macOS/Linux client protocol.

const std = @import("std");
const windows = std.os.windows;
const protocol = @import("root.zig");
const frame = @import("frame.zig");
const job_store = @import("../core/job_store.zig");
const unix_service = @import("unix.zig");
const Allocator = std.mem.Allocator;

comptime {
    if (@import("builtin").os.tag != .windows) @compileError("Windows named-pipe transport requires a Windows target");
}

const max_pipe_clients = 32;
const pipe_access_duplex: u32 = 0x00000003;
const pipe_nowait: u32 = 0x00000001;
const pipe_reject_remote_clients: u32 = 0x00000008;
const file_flag_first_pipe_instance: u32 = 0x00080000;
const error_pipe_connected: u32 = 535;
const error_pipe_listening: u32 = 536;
const error_no_data: u32 = 232;
const error_access_denied: u32 = 5;
const token_query: u32 = 0x0008;
const token_user_class: u32 = 1;
const sddl_revision_1: u32 = 1;
const io_timeout_ms: u64 = 30_000;

pub const Error = error{
    IdentityUnavailable,
    SecurityDescriptorFailed,
    PipeCreateFailed,
    EndpointExists,
    PipeConnectFailed,
    PipeReadFailed,
    PipeWriteFailed,
    PipeTimeout,
    TooManyClients,
};

pub const Config = struct {
    server: unix_service.ServerIdentity,
    jobs: *job_store.Store,
};

const SecurityAttributes = extern struct {
    length: u32,
    descriptor: ?*anyopaque,
    inherit_handle: i32,
};

const SidAndAttributes = extern struct {
    sid: ?*anyopaque,
    attributes: u32,
};

const TokenUser = extern struct { user: SidAndAttributes };

extern "kernel32" fn GetCurrentProcess() callconv(.winapi) windows.HANDLE;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(handle: windows.HANDLE) callconv(.winapi) i32;
extern "kernel32" fn LocalFree(memory: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn Sleep(milliseconds: u32) callconv(.winapi) void;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn ProcessIdToSessionId(process_id: u32, session_id: *u32) callconv(.winapi) i32;
extern "kernel32" fn CreateNamedPipeW(
    name: [*:0]const u16,
    open_mode: u32,
    pipe_mode: u32,
    max_instances: u32,
    output_buffer_size: u32,
    input_buffer_size: u32,
    default_timeout: u32,
    security_attributes: ?*SecurityAttributes,
) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn ConnectNamedPipe(pipe: windows.HANDLE, overlapped: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn DisconnectNamedPipe(pipe: windows.HANDLE) callconv(.winapi) i32;
extern "kernel32" fn ReadFile(
    file: windows.HANDLE,
    buffer: [*]u8,
    bytes_to_read: u32,
    bytes_read: *u32,
    overlapped: ?*anyopaque,
) callconv(.winapi) i32;
extern "kernel32" fn WriteFile(
    file: windows.HANDLE,
    buffer: [*]const u8,
    bytes_to_write: u32,
    bytes_written: *u32,
    overlapped: ?*anyopaque,
) callconv(.winapi) i32;
extern "advapi32" fn OpenProcessToken(process: windows.HANDLE, access: u32, token: *windows.HANDLE) callconv(.winapi) i32;
extern "advapi32" fn GetTokenInformation(
    token: windows.HANDLE,
    information_class: u32,
    information: *anyopaque,
    information_length: u32,
    return_length: *u32,
) callconv(.winapi) i32;
extern "advapi32" fn ConvertSidToStringSidW(sid: *anyopaque, string_sid: *?[*:0]const u16) callconv(.winapi) i32;
extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW(
    descriptor_string: [*:0]const u16,
    revision: u32,
    descriptor: *?*anyopaque,
    descriptor_size: ?*u32,
) callconv(.winapi) i32;

pub fn pipeName(allocator: Allocator) ![:0]u16 {
    const identity = try currentIdentity(allocator);
    defer allocator.free(identity.sid);
    const utf8 = try std.fmt.allocPrint(allocator, "\\\\.\\pipe\\SpeedDownload-{s}-{d}", .{ identity.sid, identity.session_id });
    defer allocator.free(utf8);
    return try std.unicode.utf8ToUtf16LeAllocZ(allocator, utf8);
}

pub fn serve(allocator: Allocator, config: Config) !void {
    var engine = unix_service.EngineContext{ .allocator = allocator, .io = config.jobs.io, .jobs = config.jobs, .engine_instance_id = config.server.engine_instance_id, .started_ns = std.Io.Clock.now(.awake, config.jobs.io).nanoseconds };
    const identity = try currentIdentity(allocator);
    defer allocator.free(identity.sid);
    const pipe_name_utf8 = try std.fmt.allocPrint(allocator, "\\\\.\\pipe\\SpeedDownload-{s}-{d}", .{ identity.sid, identity.session_id });
    defer allocator.free(pipe_name_utf8);
    const pipe_name_utf16 = try std.unicode.utf8ToUtf16LeAllocZ(allocator, pipe_name_utf8);
    defer allocator.free(pipe_name_utf16);

    const sddl = try std.fmt.allocPrint(allocator, "D:P(A;;GA;;;{s})(A;;GA;;;SY)", .{identity.sid});
    defer allocator.free(sddl);
    const sddl_utf16 = try std.unicode.utf8ToUtf16LeAllocZ(allocator, sddl);
    defer allocator.free(sddl_utf16);
    var security_descriptor: ?*anyopaque = null;
    if (ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl_utf16, sddl_revision_1, &security_descriptor, null) == 0)
        return Error.SecurityDescriptorFailed;
    defer _ = LocalFree(security_descriptor);
    var security = SecurityAttributes{
        .length = @sizeOf(SecurityAttributes),
        .descriptor = security_descriptor,
        .inherit_handle = 0,
    };

    var first_pipe_instance = true;
    while (true) {
        const pipe = CreateNamedPipeW(
            pipe_name_utf16,
            pipe_access_duplex | (if (first_pipe_instance) file_flag_first_pipe_instance else 0),
            pipe_nowait | pipe_reject_remote_clients,
            max_pipe_clients,
            frame.max_payload_bytes + frame.header_bytes,
            frame.max_payload_bytes + frame.header_bytes,
            @intCast(io_timeout_ms),
            &security,
        );
        if (pipe == windows.INVALID_HANDLE_VALUE) {
            if (first_pipe_instance and GetLastError() == error_access_denied) return Error.EndpointExists;
            return Error.PipeCreateFailed;
        }
        first_pipe_instance = false;
        waitForClient(pipe) catch {
            _ = CloseHandle(pipe);
            continue;
        };
        if (!reserveClient(&engine)) {
            _ = DisconnectNamedPipe(pipe);
            _ = CloseHandle(pipe);
            continue;
        }
        const thread = std.Thread.spawn(.{}, handleClientThread, .{ allocator, pipe, config.server, &engine }) catch {
            _ = engine.active_clients.fetchSub(1, .release);
            _ = DisconnectNamedPipe(pipe);
            _ = CloseHandle(pipe);
            continue;
        };
        thread.detach();
    }
}

fn currentIdentity(allocator: Allocator) !struct { sid: []u8, session_id: u32 } {
    var token: windows.HANDLE = undefined;
    if (OpenProcessToken(GetCurrentProcess(), token_query, &token) == 0) return Error.IdentityUnavailable;
    defer _ = CloseHandle(token);

    var token_buffer: [1024]u8 align(@alignOf(usize)) = undefined;
    var required: u32 = 0;
    if (GetTokenInformation(token, token_user_class, &token_buffer, token_buffer.len, &required) == 0)
        return Error.IdentityUnavailable;
    const token_user: *const TokenUser = @ptrCast(@alignCast(&token_buffer));
    const sid = token_user.user.sid orelse return Error.IdentityUnavailable;
    var sid_string: ?[*:0]const u16 = null;
    if (ConvertSidToStringSidW(sid, &sid_string) == 0) return Error.IdentityUnavailable;
    defer _ = LocalFree(@constCast(sid_string));
    const sid_utf16 = sid_string.?[0..std.mem.len(sid_string.?)];
    const sid_utf8 = try std.unicode.utf16LeToUtf8Alloc(allocator, sid_utf16);
    errdefer allocator.free(sid_utf8);

    var session_id: u32 = 0;
    if (ProcessIdToSessionId(GetCurrentProcessId(), &session_id) == 0) return Error.IdentityUnavailable;
    return .{ .sid = sid_utf8, .session_id = session_id };
}

fn waitForClient(pipe: windows.HANDLE) Error!void {
    while (true) {
        if (ConnectNamedPipe(pipe, null) != 0) return;
        switch (GetLastError()) {
            error_pipe_connected => return,
            error_pipe_listening => {
                Sleep(10);
            },
            else => return Error.PipeConnectFailed,
        }
    }
}

fn reserveClient(engine: *unix_service.EngineContext) bool {
    while (true) {
        const active = engine.active_clients.load(.acquire);
        if (active >= max_pipe_clients) return false;
        if (engine.active_clients.cmpxchgWeak(active, active + 1, .acquire, .monotonic) == null) return true;
    }
}

fn handleClientThread(allocator: Allocator, pipe: windows.HANDLE, server: unix_service.ServerIdentity, engine: *unix_service.EngineContext) void {
    defer _ = engine.active_clients.fetchSub(1, .release);
    defer _ = DisconnectNamedPipe(pipe);
    defer _ = CloseHandle(pipe);
    serveConnection(allocator, pipe, server, engine) catch {};
}

fn serveConnection(allocator: Allocator, pipe: windows.HANDLE, server: unix_service.ServerIdentity, engine: *unix_service.EngineContext) !void {
    var session = protocol.Session{ .dispatch = unix_service.dispatchMethod, .context = @ptrCast(engine) };
    var request_frame = try allocator.alloc(u8, frame.header_bytes + frame.max_payload_bytes);
    defer allocator.free(request_frame);
    var header: [frame.header_bytes]u8 = undefined;
    var session_id: [36]u8 = undefined;
    try randomUuid(engine.io, &session_id);
    const server_info = protocol.ServerInfo{
        .engine_version = server.engine_version,
        .engine_instance_id = server.engine_instance_id,
        .session_id = &session_id,
        .supported_features = server.supported_features,
    };

    while (true) {
        try readExact(pipe, &header);
        const length = std.mem.readInt(u32, &header, .little);
        if (length == 0 or length > frame.max_payload_bytes) return;
        try readExact(pipe, request_frame[frame.header_bytes .. frame.header_bytes + length]);
        @memcpy(request_frame[0..frame.header_bytes], &header);
        const result = try protocol.handleFrame(
            allocator,
            &session,
            request_frame[0 .. frame.header_bytes + length],
            server_info,
        );
        if (result.response_frame) |response| {
            defer allocator.free(response);
            try writeAll(pipe, response);
        }
    }
}

fn readExact(pipe: windows.HANDLE, buffer: []u8) Error!void {
    var offset: usize = 0;
    const start = GetTickCount64();
    while (offset < buffer.len) {
        var count: u32 = 0;
        const amount: u32 = @intCast(@min(buffer.len - offset, std.math.maxInt(u32)));
        if (ReadFile(pipe, buffer[offset..].ptr, amount, &count, null) != 0 and count > 0) {
            offset += count;
            continue;
        }
        const last_error = GetLastError();
        if (last_error != error_no_data and last_error != 0) return Error.PipeReadFailed;
        if (GetTickCount64() - start >= io_timeout_ms) return Error.PipeTimeout;
        Sleep(10);
    }
}

fn writeAll(pipe: windows.HANDLE, buffer: []const u8) Error!void {
    var offset: usize = 0;
    const start = GetTickCount64();
    while (offset < buffer.len) {
        var count: u32 = 0;
        const amount: u32 = @intCast(@min(buffer.len - offset, std.math.maxInt(u32)));
        if (WriteFile(pipe, buffer[offset..].ptr, amount, &count, null) != 0 and count > 0) {
            offset += count;
            continue;
        }
        const last_error = GetLastError();
        if (last_error != error_no_data and last_error != 0) return Error.PipeWriteFailed;
        if (GetTickCount64() - start >= io_timeout_ms) return Error.PipeTimeout;
        Sleep(10);
    }
}

fn randomUuid(io: std.Io, buffer: *[36]u8) !void {
    var bytes: [16]u8 = undefined;
    try io.randomSecure(&bytes);
    const hex = "0123456789abcdef";
    var index: usize = 0;
    for (bytes, 0..) |byte, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            buffer[index] = '-';
            index += 1;
        }
        buffer[index] = hex[byte >> 4];
        buffer[index + 1] = hex[byte & 0x0f];
        index += 2;
    }
}
