//! Length-prefixed JSON payload framing for the local engine IPC transport.
//!
//! This module owns byte-level framing only. It does not perform socket reads or
//! writes, choose an OS endpoint, or authorize a peer. Callers may pass a buffer
//! containing a partial frame or multiple consecutive frames to `decodeOne`.

const std = @import("std");

pub const max_payload_bytes: usize = 1_048_576;
pub const header_bytes: usize = 4;

pub const Frame = struct {
    payload: []const u8,
    consumed: usize,
};

pub const DecodeError = error{
    IncompleteFrame,
    EmptyFrame,
    FrameTooLarge,
    InvalidUtf8,
    InvalidJson,
};

/// Encodes one JSON payload with an unsigned little-endian 32-bit byte length.
pub fn encode(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    if (payload.len == 0) return error.EmptyFrame;
    if (payload.len > max_payload_bytes) return error.FrameTooLarge;
    try validatePayload(allocator, payload);

    const frame = try allocator.alloc(u8, header_bytes + payload.len);
    const length: u32 = @intCast(payload.len);
    std.mem.writeInt(u32, frame[0..header_bytes], length, .little);
    @memcpy(frame[header_bytes..], payload);
    return frame;
}

/// Decodes the first complete frame, leaving any following bytes to the caller.
pub fn decodeOne(allocator: std.mem.Allocator, input: []const u8) (DecodeError || std.mem.Allocator.Error)!Frame {
    if (input.len < header_bytes) return error.IncompleteFrame;

    const length = std.mem.readInt(u32, input[0..header_bytes], .little);
    if (length == 0) return error.EmptyFrame;
    if (length > max_payload_bytes) return error.FrameTooLarge;

    const payload_len: usize = length;
    const frame_len = header_bytes + payload_len;
    if (input.len < frame_len) return error.IncompleteFrame;

    const payload = input[header_bytes..frame_len];
    try validatePayload(allocator, payload);
    return .{ .payload = payload, .consumed = frame_len };
}

fn validatePayload(allocator: std.mem.Allocator, payload: []const u8) (DecodeError || std.mem.Allocator.Error)!void {
    if (!std.unicode.utf8ValidateSlice(payload)) return error.InvalidUtf8;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.InvalidJson;
    };
    parsed.deinit();
}
