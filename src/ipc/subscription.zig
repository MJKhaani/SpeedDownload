//! Bounded invalidation notices for a dedicated job subscription connection.
const std = @import("std");
const frame = @import("frame.zig");

pub const Started = struct {
    id: []u8,
    cursor: u64,
    interval_ms: u16,

    pub fn deinit(self: Started, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
    }
};

pub fn started(allocator: std.mem.Allocator, request_payload: []const u8, response_frame: ?[]const u8) !?Started {
    const framed = response_frame orelse return null;
    var request = std.json.parseFromSlice(std.json.Value, allocator, request_payload, .{}) catch return null;
    defer request.deinit();
    if (request.value != .object) return null;
    const method = request.value.object.get("method") orelse return null;
    if (method != .string or !std.mem.eql(u8, method.string, "jobs.subscribe")) return null;
    const decoded = try frame.decodeOne(allocator, framed);
    var response = std.json.parseFromSlice(std.json.Value, allocator, decoded.payload, .{}) catch return null;
    defer response.deinit();
    if (response.value != .object) return null;
    const result = response.value.object.get("result") orelse return null;
    if (result != .object) return null;
    const id = result.object.get("subscription_id") orelse return null;
    const cursor = result.object.get("cursor") orelse return null;
    const interval = result.object.get("interval_ms") orelse return null;
    if (id != .string or cursor != .string or interval != .integer or interval.integer < 100 or interval.integer > 1000) return null;
    const cursor_value = std.fmt.parseInt(u64, cursor.string, 10) catch return null;
    return .{
        .id = try allocator.dupe(u8, id.string),
        .cursor = cursor_value,
        .interval_ms = @intCast(interval.integer),
    };
}

pub fn eventFrame(allocator: std.mem.Allocator, id: []const u8, engine_instance_id: []const u8, sequence: u64, cursor: u64) ![]u8 {
    const sequence_text = try std.fmt.allocPrint(allocator, "{d}", .{sequence});
    defer allocator.free(sequence_text);
    const cursor_text = try std.fmt.allocPrint(allocator, "{d}", .{cursor});
    defer allocator.free(cursor_text);
    const payload = try std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .method = "events.changed",
        .params = .{
            .subscription_id = id,
            .engine_instance_id = engine_instance_id,
            .seq = sequence_text,
            .cursor = cursor_text,
            .resync_required = true,
        },
    }, .{});
    defer allocator.free(payload);
    return frame.encode(allocator, payload);
}
