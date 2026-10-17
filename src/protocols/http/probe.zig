//! HTTP preflight used by native clients before a URL is added to the queue.
//! Range support is reported only after a valid one-byte 206 response.

const std = @import("std");
const http = std.http;

pub const Result = struct {
    final_url: []const u8,
    suggested_name: []const u8,
    total_bytes: ?[]const u8,
    status_code: u16,
    http_version: []const u8,
    content_type: ?[]const u8,
    range_supported: bool,
    resume_supported: bool,
    multipart_supported: bool,
    message: []const u8,
};

pub fn inspect(allocator: std.mem.Allocator, io: std.Io, url: []const u8) !Result {
    return inspectWithPolicy(allocator, io, url, .{});
}

pub fn inspectWithPolicy(allocator: std.mem.Allocator, io: std.Io, url: []const u8, proxy_policy: @import("proxy.zig").Policy) !Result {
    var original_uri = std.Uri.parse(url) catch return error.InvalidUrl;
    if (std.ascii.eqlIgnoreCase(original_uri.scheme, "http")) original_uri.scheme = "http" else if (std.ascii.eqlIgnoreCase(original_uri.scheme, "https")) original_uri.scheme = "https" else return error.UnsupportedScheme;

    var client: http.Client = .{ .allocator = allocator, .io = io };
    var proxy_state = @import("proxy.zig").State.init(allocator);
    defer proxy_state.deinit();
    defer client.deinit();
    try proxy_state.apply(&client, proxy_policy, original_uri);

    const range_header = [_]http.Header{.{ .name = "range", .value = "bytes=0-0" }};
    var get_request = try client.request(.GET, original_uri, .{
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
        .extra_headers = &range_header,
    });
    var abandon_body = false;
    defer {
        if (abandon_body) {
            // Some servers ignore Range and begin sending an entire file.
            // A preflight must not wait for Request.deinit to drain it.
            get_request.connection.?.closing = true;
            get_request.reader.state = .ready;
        }
        get_request.deinit();
    }
    try get_request.sendBodiless();
    var redirect_buffer: [8 * 1024]u8 = undefined;
    var response = try get_request.receiveHead(&redirect_buffer);
    abandon_body = true;
    if (response.head.status == .too_many_requests or response.head.status == .service_unavailable)
        return error.ServerBusy;
    const status_code: u16 = @backingInt(response.head.status);
    const version = try allocator.dupe(u8, @tagName(response.head.version));
    errdefer allocator.free(version);
    const content_type: ?[]u8 = if (response.head.content_type) |value| try allocator.dupe(u8, value) else null;
    errdefer if (content_type) |value| allocator.free(value);
    const suggested_name = try nameFromResponseOrUri(allocator, response.head.content_disposition, get_request.uri);
    errdefer allocator.free(suggested_name);

    var range_supported = false;
    var total: ?u64 = if (response.head.status == .partial_content) null else response.head.content_length;
    const strong_validator = if (responseHeader(response.head.bytes, "etag")) |etag|
        isStrongETag(etag)
    else
        false;
    if (response.head.status == .partial_content and response.head.content_encoding == .identity) {
        if (responseHeader(response.head.bytes, "content-range")) |value| {
            if (parseContentRange(value)) |content_range| {
                if (content_range.start == 0 and content_range.end_inclusive == 0 and content_range.total != null and
                    response.head.content_length == 1)
                {
                    var body_buffer: [1]u8 = undefined;
                    var body = response.reader(&body_buffer);
                    const received = body.readSliceShort(&body_buffer) catch 0;
                    if (received == 1) {
                        range_supported = true;
                        total = content_range.total;
                        abandon_body = false;
                    }
                }
            }
        }
    }
    const final_url = try uriString(allocator, get_request.uri);
    errdefer allocator.free(final_url);
    const total_text = if (total) |value| try std.fmt.allocPrint(allocator, "{d}", .{value}) else null;
    errdefer if (total_text) |value| allocator.free(value);
    const safe_for_resume = original_uri.user == null and original_uri.password == null and original_uri.fragment == null and
        get_request.uri.user == null and get_request.uri.password == null and get_request.uri.fragment == null;
    const resume_supported = range_supported and strong_validator and safe_for_resume;
    const multipart_supported = resume_supported and (total orelse 0) >= 8 * 1024 * 1024;
    const message: []const u8 = if (multipart_supported)
        "Verified byte ranges; parallel download and safe resume are available."
    else if (range_supported and resume_supported)
        "Verified byte ranges; safe resume is available, but the file is below the multipart threshold."
    else if (range_supported)
        "Verified byte ranges, but no safe strong-validator resume was confirmed."
    else if (response.head.status.class() == .success)
        "The server did not confirm byte ranges; a single-stream download may still work."
    else
        "The server returned an error for the preflight request; the URL can still be queued.";

    return .{
        .final_url = final_url,
        .suggested_name = suggested_name,
        .total_bytes = total_text,
        .status_code = status_code,
        .http_version = version,
        .content_type = content_type,
        .range_supported = range_supported,
        .resume_supported = resume_supported,
        .multipart_supported = multipart_supported,
        .message = message,
    };
}

fn uriString(allocator: std.mem.Allocator, uri: std.Uri) ![]u8 {
    var output = std.Io.Writer.Allocating.init(allocator);
    defer output.deinit();
    try uri.format(&output.writer);
    return allocator.dupe(u8, output.written());
}

fn nameFromResponseOrUri(allocator: std.mem.Allocator, disposition: ?[]const u8, uri: std.Uri) ![]u8 {
    if (disposition) |value| if (extendedFilenameParameter(value)) |encoded| {
        // RFC 5987 uses charset'language'percent-encoded-value. Only UTF-8
        // is accepted; an unknown charset falls back to filename or the URL.
        const first_quote = std.mem.indexOfScalar(u8, encoded, '\'') orelse 0;
        const second_quote = if (first_quote > 0)
            std.mem.indexOfScalarPos(u8, encoded, first_quote + 1, '\'') orelse 0
        else
            0;
        if (second_quote > first_quote and std.ascii.eqlIgnoreCase(encoded[0..first_quote], "UTF-8")) {
            const payload = encoded[second_quote + 1 ..];
            const decoded_buffer = try allocator.alloc(u8, payload.len);
            defer allocator.free(decoded_buffer);
            const decoded = std.Uri.percentDecodeBackwards(decoded_buffer, payload);
            if (std.unicode.utf8ValidateSlice(decoded) and safeFilename(decoded))
                return allocator.dupe(u8, decoded);
        }
    };
    if (disposition) |value| if (filenameParameter(value)) |filename| {
        if (safeFilename(filename)) {
            const decoded_buffer = try allocator.alloc(u8, filename.len);
            defer allocator.free(decoded_buffer);
            const decoded = std.Uri.percentDecodeBackwards(decoded_buffer, filename);
            if (std.unicode.utf8ValidateSlice(decoded) and safeFilename(decoded))
                return allocator.dupe(u8, decoded);
            return allocator.dupe(u8, filename);
        }
    };
    const path = switch (uri.path) {
        .raw, .percent_encoded => |value| value,
    };
    const leaf = if (std.mem.lastIndexOfScalar(u8, path, '/')) |index| path[index + 1 ..] else path;
    if (uri.path == .percent_encoded) {
        const decoded_buffer = try allocator.alloc(u8, leaf.len);
        defer allocator.free(decoded_buffer);
        const decoded = std.Uri.percentDecodeBackwards(decoded_buffer, leaf);
        if (std.unicode.utf8ValidateSlice(decoded) and safeFilename(decoded))
            return allocator.dupe(u8, decoded);
    }
    if (safeFilename(leaf)) return allocator.dupe(u8, leaf);
    const host = uri.host orelse return allocator.dupe(u8, "download");
    return allocator.dupe(u8, switch (host) {
        .raw, .percent_encoded => |value| value,
    });
}

fn filenameParameter(value: []const u8) ?[]const u8 {
    return dispositionParameter(value, "filename");
}

fn extendedFilenameParameter(value: []const u8) ?[]const u8 {
    return dispositionParameter(value, "filename*");
}

fn dispositionParameter(value: []const u8, name: []const u8) ?[]const u8 {
    var parameters = std.mem.splitScalar(u8, value, ';');
    while (parameters.next()) |parameter| {
        const trimmed = std.mem.trim(u8, parameter, " \t\"");
        const equals = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, trimmed[0..equals], " \t"), name)) continue;
        return std.mem.trim(u8, trimmed[equals + 1 ..], " \t\"");
    }
    return null;
}

fn safeFilename(value: []const u8) bool {
    return value.len > 0 and !std.mem.eql(u8, value, ".") and !std.mem.eql(u8, value, "..") and
        std.mem.indexOfAny(u8, value, "/\\\x00") == null;
}

fn responseHeader(bytes: []const u8, name: []const u8) ?[]const u8 {
    if (bytes.len < 2) return null;
    const status_end = std.mem.indexOf(u8, bytes, "\r\n") orelse return null;
    var cursor = status_end + 2;
    var result: ?[]const u8 = null;
    while (cursor + 2 <= bytes.len) {
        const relative_end = std.mem.indexOfPos(u8, bytes, cursor, "\r\n") orelse return null;
        if (relative_end == cursor) return result;
        const line = bytes[cursor..relative_end];
        cursor = relative_end + 2;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) continue;
        if (result != null) return null;
        result = std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return result;
}

const ContentRange = struct { start: u64, end_inclusive: u64, total: ?u64 };

fn parseContentRange(value: []const u8) ?ContentRange {
    if (!std.mem.startsWith(u8, value, "bytes ")) return null;
    var slash = std.mem.splitScalar(u8, value[6..], '/');
    const span = slash.next() orelse return null;
    const total_text = slash.next() orelse return null;
    if (slash.next() != null) return null;
    var dash = std.mem.splitScalar(u8, span, '-');
    const start = std.fmt.parseInt(u64, dash.next() orelse return null, 10) catch return null;
    const end = std.fmt.parseInt(u64, dash.next() orelse return null, 10) catch return null;
    if (dash.next() != null or start > end) return null;
    const total = std.fmt.parseInt(u64, total_text, 10) catch return null;
    if (end >= total) return null;
    return .{ .start = start, .end_inclusive = end, .total = total };
}

fn isStrongETag(value: []const u8) bool {
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return false;
    for (value[1 .. value.len - 1]) |byte| if (byte == '"' or byte < 0x21 or byte == 0x7f) return false;
    return true;
}
