//! Validation for the first JSON-RPC request on an IPC connection.
//!
//! `engine.hello` is the only application method accepted before protocol
//! negotiation. This module validates the request shape and leaves response
//! construction and connection state to the server/session layer.

const std = @import("std");
const Value = std.json.Value;

pub const protocol_major: i64 = 1;
pub const protocol_minor: i64 = 0;
const max_id_bytes = 128;
const max_text_bytes = 128;
const max_features = 64;

/// Returns success only for a well-formed v1 `engine.hello` request.
pub fn validate(allocator: std.mem.Allocator, payload: []const u8) !void {
    const parsed = try parseAndValidate(allocator, payload);
    parsed.deinit();
}

/// Creates the JSON-RPC success response after validating a hello request.
/// The daemon supplies fresh instance/session identifiers for its lifecycle.
pub fn response(
    allocator: std.mem.Allocator,
    payload: []const u8,
    engine_version: []const u8,
    engine_instance_id: []const u8,
    session_id: []const u8,
    supported_features: []const []const u8,
) ![]u8 {
    var parsed = try parseAndValidate(allocator, payload);
    defer parsed.deinit();

    const request = parsed.value.object;
    const params = request.get("params").?.object;
    const client_features = params.get("features").?.array.items;

    var selected_features: std.ArrayList([]const u8) = .empty;
    defer selected_features.deinit(allocator);
    for (client_features) |client_feature| {
        for (supported_features) |supported_feature| {
            if (std.mem.eql(u8, client_feature.string, supported_feature)) {
                try selected_features.append(allocator, supported_feature);
                break;
            }
        }
    }

    return std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = request.get("id").?,
        .result = .{
            .protocol = .{ .major = protocol_major, .minor = protocol_minor },
            .engine_version = engine_version,
            .engine_instance_id = engine_instance_id,
            .features = selected_features.items,
            .session_id = session_id,
        },
    }, .{});
}

fn parseAndValidate(allocator: std.mem.Allocator, payload: []const u8) !std.json.Parsed(Value) {
    var parsed = std.json.parseFromSlice(Value, allocator, payload, .{}) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.InvalidHello;
    };

    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidHello;
    const request = parsed.value.object;

    const version = request.get("jsonrpc") orelse return error.InvalidHello;
    if (version != .string or !std.mem.eql(u8, version.string, "2.0")) return error.InvalidHello;

    const id = request.get("id") orelse return error.InvalidHello;
    switch (id) {
        .string => |text| if (text.len == 0 or text.len > max_id_bytes) return error.InvalidHello,
        .integer => {},
        else => return error.InvalidHello,
    }

    const method = request.get("method") orelse return error.InvalidHello;
    if (method != .string or !std.mem.eql(u8, method.string, "engine.hello")) return error.InvalidHello;

    const params_value = request.get("params") orelse return error.InvalidHello;
    if (params_value != .object) return error.InvalidHello;
    const params = params_value.object;

    const protocol_value = params.get("protocol") orelse return error.InvalidHello;
    if (protocol_value != .object) return error.InvalidHello;
    const version_object = protocol_value.object;
    const major = nonNegativeInteger(version_object.get("major") orelse return error.InvalidHello) orelse return error.InvalidHello;
    _ = nonNegativeInteger(version_object.get("minor") orelse return error.InvalidHello) orelse return error.InvalidHello;
    if (major != protocol_major) return error.UnsupportedProtocolVersion;

    const client_value = params.get("client") orelse return error.InvalidHello;
    if (client_value != .object) return error.InvalidHello;
    const client = client_value.object;
    try requireShortString(client.get("kind") orelse return error.InvalidHello);
    try requireShortString(client.get("version") orelse return error.InvalidHello);

    const features_value = params.get("features") orelse return error.InvalidHello;
    if (features_value != .array or features_value.array.items.len > max_features) return error.InvalidHello;
    for (features_value.array.items) |feature| try requireShortString(feature);

    return parsed;
}

fn nonNegativeInteger(value: Value) ?i64 {
    return switch (value) {
        .integer => |number| if (number >= 0) number else null,
        else => null,
    };
}

fn requireShortString(value: Value) error{InvalidHello}!void {
    if (value != .string or value.string.len == 0 or value.string.len > max_text_bytes) return error.InvalidHello;
}
