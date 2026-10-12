//! Shared protocol primitives for Speed Download's local engine IPC.
//!
//! OS transports must use this decoder before dispatching messages. Peer
//! authentication and transport lifecycle belong in platform adapters.

const std = @import("std");
const frame = @import("frame.zig");
const hello = @import("hello.zig");

pub const max_payload_bytes = frame.max_payload_bytes;

pub const FirstMessage = struct {
    hello_payload: []const u8,
    remaining: []const u8,
};

pub const Handshake = struct {
    response_frame: []u8,
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
