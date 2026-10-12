//! Shared protocol primitives for Speed Download's local engine IPC.
//!
//! OS transports must use this decoder before dispatching messages. Peer
//! authentication and transport lifecycle belong in platform adapters.

const std = @import("std");
const frame = @import("frame.zig");
const hello = @import("hello.zig");

pub const max_payload_bytes = frame.max_payload_bytes;
pub const Session = @import("session.zig").Session;

pub const ServerInfo = struct {
    engine_version: []const u8,
    engine_instance_id: []const u8,
    session_id: []const u8,
    supported_features: []const []const u8,
};

pub const FirstMessage = struct {
    hello_payload: []const u8,
    remaining: []const u8,
};

pub const Handshake = struct {
    response_frame: []u8,
    remaining: []const u8,
};

pub const MessageResult = struct {
    response_frame: ?[]u8,
    remaining: []const u8,
};

/// Decodes and validates the required first `engine.hello` request.
pub fn decodeFirstMessage(allocator: std.mem.Allocator, input: []const u8) !FirstMessage {
    const decoded = try frame.decodeOne(allocator, input);
    try hello.validate(allocator, decoded.payload);
    return .{
        .hello_payload = decoded.payload,
        .remaining = input[decoded.consumed..],
    };
}

/// Validates the first request and returns its framed negotiated response.
pub fn acceptFirstMessage(
    allocator: std.mem.Allocator,
    input: []const u8,
    engine_version: []const u8,
    engine_instance_id: []const u8,
    session_id: []const u8,
    supported_features: []const []const u8,
) !Handshake {
    const decoded = try decodeFirstMessage(allocator, input);
    const response_json = try hello.response(
        allocator,
        decoded.hello_payload,
        engine_version,
        engine_instance_id,
        session_id,
        supported_features,
    );
    defer allocator.free(response_json);

    return .{
        .response_frame = try frame.encode(allocator, response_json),
        .remaining = decoded.remaining,
    };
}

/// Handles one framed request on a negotiated connection and frames any reply.
pub fn handleFrame(
    allocator: std.mem.Allocator,
    session: *Session,
    input: []const u8,
    server: ServerInfo,
) !MessageResult {
    const decoded = try frame.decodeOne(allocator, input);
    const response_json = try session.handle(
        allocator,
        decoded.payload,
        server.engine_version,
        server.engine_instance_id,
        server.session_id,
        server.supported_features,
    );

    if (response_json) |json| {
        defer allocator.free(json);
        return .{
            .response_frame = try frame.encode(allocator, json),
            .remaining = input[decoded.consumed..],
        };
    }

    return .{
        .response_frame = null,
        .remaining = input[decoded.consumed..],
    };
}
