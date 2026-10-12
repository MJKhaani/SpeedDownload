//! Per-connection JSON-RPC handshake state and conservative method dispatch.
//!
//! The session owns protocol negotiation state only. Application methods are
//! dispatched by the future engine service after the IPC transport authenticates
//! the peer. Unknown methods receive the standard JSON-RPC method-not-found error.

const std = @import("std");
const hello = @import("hello.zig");
const Value = std.json.Value;

pub const DispatchFn = *const fn (
    allocator: std.mem.Allocator,
    id: ?Value,
    method: []const u8,
    params: ?Value,
    context: ?*anyopaque,
) anyerror!?[]u8;

pub const Session = struct {
    negotiated: bool = false,
    dispatch: ?DispatchFn = null,
    context: ?*anyopaque = null,

    /// Processes one decoded JSON payload. The caller owns and frees a response.
    /// Notifications with no `id` return null unless the JSON itself is invalid.
    pub fn handle(
        self: *Session,
        allocator: std.mem.Allocator,
        payload: []const u8,
        engine_version: []const u8,
        engine_instance_id: []const u8,
        session_id: []const u8,
        supported_features: []const []const u8,
    ) !?[]u8 {
        var parsed = std.json.parseFromSlice(Value, allocator, payload, .{}) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return try errorResponse(allocator, .null, -32700, "Parse error");
        };
        defer parsed.deinit();

        if (parsed.value != .object) return try errorResponse(allocator, .null, -32600, "Invalid Request");
        const request = parsed.value.object;
        const id = request.get("id");
        const has_id = id != null;

        const version = request.get("jsonrpc") orelse return invalidRequest(allocator, id);
        if (version != .string or !std.mem.eql(u8, version.string, "2.0")) return invalidRequest(allocator, id);
        const method = request.get("method") orelse return invalidRequest(allocator, id);
        if (method != .string or method.string.len == 0) return invalidRequest(allocator, id);
        if (id) |request_id| if (!validId(request_id)) return invalidRequest(allocator, null);

        if (!self.negotiated) {
            if (!std.mem.eql(u8, method.string, "engine.hello")) {
                if (!has_id) return null;
                return try errorResponse(allocator, id.?, -32001, "Handshake required");
            }

            hello.validate(allocator, payload) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                if (!has_id) return null;
                if (err == error.UnsupportedProtocolVersion) {
                    return try errorResponse(allocator, id.?, -32002, "Unsupported protocol version");
                }
                return try errorResponse(allocator, id.?, -32600, "Invalid Request");
            };

            const response = try hello.response(
                allocator,
                payload,
                engine_version,
                engine_instance_id,
                session_id,
                supported_features,
            );
            self.negotiated = true;
            return response;
        }

        if (std.mem.eql(u8, method.string, "engine.hello")) return invalidRequest(allocator, id);
        if (self.dispatch) |dispatch| {
            const response = try dispatch(allocator, id, method.string, request.get("params"), self.context);
            if (!has_id) {
                if (response) |payload_result| allocator.free(payload_result);
                return null;
            }
            if (response) |payload_result| return payload_result;
        }
        if (!has_id) return null;
        return try errorResponse(allocator, id.?, -32601, "Method not found");
    }
};

fn validId(id: Value) bool {
    return switch (id) {
        .string => |text| text.len > 0 and text.len <= 128,
        .integer => true,
        else => false,
    };
}

fn invalidRequest(allocator: std.mem.Allocator, id: ?Value) !?[]u8 {
    return try errorResponse(allocator, id orelse .null, -32600, "Invalid Request");
}

fn errorResponse(allocator: std.mem.Allocator, id: Value, code: i64, message: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = id,
        .@"error" = .{ .code = code, .message = message },
    }, .{});
}
