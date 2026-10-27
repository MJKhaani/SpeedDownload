//! Engine-owned torrent metadata preparation; no payload transfer is started.
const std = @import("std");
const metainfo = @import("metainfo.zig");
const source = @import("source.zig");
const proxy = @import("../http/proxy.zig");
const Probe = @import("../http/probe.zig").Result;
const metadata = @import("metadata.zig");

const MetadataDeadline = struct {
    io: std.Io,
    expires: i96,
    fn check(context: *anyopaque) metadata.CheckpointError!void {
        const self: *MetadataDeadline = @ptrCast(@alignCast(context));
        if (std.Io.Clock.now(.awake, self.io).nanoseconds >= self.expires) return error.TransferCancelRequested;
    }
};

pub fn prepare(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, url: []const u8, trackers: ?[]const []const u8, offset: usize, policy: proxy.Policy, budget: *@import("../http/connection_budget.zig").Budget) !Probe {
    if (url.len == 0 or url.len > 8192) return error.InvalidTorrentSource;
    const original = if (source.isLocalTorrent(url)) blk: {
        const path = try source.pathAlloc(allocator, url);
        break :blk try std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(metainfo.max_metainfo_bytes));
    } else if (url.len >= 7 and std.ascii.eqlIgnoreCase(url[0..7], "magnet:")) blk: {
        // Peer discovery presently has no proxy transport. Never bypass a
        // custom proxy chosen by the user.
        if (policy.mode == .custom) return error.UnsupportedTorrentProxy;
        var link = try @import("magnet.zig").inspect(allocator, url);
        defer link.deinit(allocator);
        if (trackers) |edited| {
            if (edited.len > 32) return error.InvalidTorrentTrackers;
            const replacement = try allocator.alloc([]u8, edited.len);
            var count: usize = 0;
            errdefer {
                for (replacement[0..count]) |tracker| allocator.free(tracker);
                allocator.free(replacement);
            }
            for (edited) |tracker| {
                const uri = std.Uri.parse(tracker) catch return error.InvalidTorrentTrackers;
                if (tracker.len == 0 or tracker.len > 2048 or uri.host == null or uri.user != null or uri.password != null or uri.fragment != null or
                    !(std.ascii.eqlIgnoreCase(uri.scheme, "http") or std.ascii.eqlIgnoreCase(uri.scheme, "https") or std.ascii.eqlIgnoreCase(uri.scheme, "udp"))) return error.InvalidTorrentTrackers;
                for (tracker) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidTorrentTrackers;
                replacement[count] = try allocator.dupe(u8, tracker);
                count += 1;
            }
            for (link.trackers) |tracker| allocator.free(tracker);
            allocator.free(link.trackers);
            link.trackers = replacement;
        }
        // Local metadata is useful even when public discovery is unreachable.
        // Match the raw info hash and revalidate paths; never trust the name.
        if (try cachedMetadata(allocator, io, directory, link.info_hash)) |cached| {
            break :blk if (trackers != null or link.trackers.len > 0)
                try metainfo.withTrackers(allocator, cached, link.trackers)
            else
                cached;
        }
        // A magnet does not carry the private flag. Metadata discovery may use
        // DHT; a verified private result is rejected below before queueing.
        link.allow_dht = true;
        var deadline: MetadataDeadline = .{ .io = io, .expires = std.Io.Clock.now(.awake, io).nanoseconds + 45 * std.time.ns_per_s };
        var session = try metadata.Session.init(io);
        const fetched = metadata.fetchWithSourceSession(allocator, io, &link, &session, MetadataDeadline.check, &deadline, null, null) catch |err| {
            if (err == error.TransferCancelRequested) return error.MetadataTimeout;
            return err;
        };
        defer fetched.deinit(allocator);
        const wrapper = try std.fmt.allocPrint(allocator, "d4:info{s}19:speed-download-peer{d}:{s}e", .{ fetched.info, fetched.peer.len, fetched.peer });
        const info = try metainfo.inspect(allocator, wrapper);
        if (!std.mem.eql(u8, &info.info_hash, &link.info_hash)) return error.MetadataHashMismatch;
        if (info.is_private) return error.PrivateMagnetRequiresTorrentFile;
        break :blk try metainfo.withTrackers(allocator, wrapper, link.trackers);
    } else try fetchTorrent(allocator, io, url, policy, budget);
    const bytes = if (trackers) |edited| try metainfo.withTrackers(allocator, original, edited) else original;
    const info = try metainfo.inspect(allocator, bytes);
    const map = try metainfo.inspectFileMap(allocator, bytes);
    if (offset > map.files.len) return error.InvalidTorrentOffset;
    const tracker_list = metainfo.trackerUrls(allocator, io, info) catch |err| blk: {
        if (err != error.NoTorrentTrackers) return err;
        if (info.is_private) return error.NoTorrentTrackers;
        break :blk metainfo.TrackerList{ .urls = &.{}, .tier_ends = @splat(0), .tier_count = 0 };
    };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const filename = try std.fmt.allocPrint(allocator, "preview-{s}.torrent", .{std.fmt.bytesToHex(digest, .lower)});
    const path = try std.fs.path.join(allocator, &.{ directory, filename });
    const permissions: std.Io.File.Permissions = if (@import("builtin").os.tag == .windows) .default_file else .fromMode(0o600);
    var atomic = try std.Io.Dir.createFileAtomic(.cwd(), io, path, .{ .permissions = permissions });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, bytes);
    try atomic.file.sync(io);
    atomic.link(io) catch |err| if (err != error.PathAlreadyExists) return err;
    var end = offset;
    var size: usize = 0;
    while (end < map.files.len and end - offset < 200) : (end += 1) {
        const cost = map.files[end].path.len * 6 + 128;
        if (end > offset and size + cost > 128 * 1024) break;
        size += cost;
    }
    const files = try allocator.alloc(Probe.TorrentFile, end - offset);
    for (files, map.files[offset..end]) |*entry, file| entry.* = .{ .path = file.path, .length = try std.fmt.allocPrint(allocator, "{d}", .{file.length}) };
    return .{
        .final_url = try source.urlAlloc(allocator, path),
        .suggested_name = info.name,
        .total_bytes = try std.fmt.allocPrint(allocator, "{d}", .{info.total_bytes}),
        .status_code = 0,
        .http_version = "BitTorrent",
        .content_type = "application/x-bittorrent",
        .range_supported = false,
        .resume_supported = true,
        .multipart_supported = false,
        .message = "Metadata verified. Select files and review trackers before adding this torrent.",
        .torrent_file_count = @intCast(map.files.len),
        .torrent_files = files,
        .torrent_info_hash = try allocator.dupe(u8, &std.fmt.bytesToHex(info.info_hash, .lower)),
        .torrent_trackers = tracker_list.urls,
        .torrent_private = info.is_private,
        .torrent_next_offset = if (end < map.files.len) try std.fmt.allocPrint(allocator, "{d}", .{end}) else null,
    };
}

fn fetchTorrent(allocator: std.mem.Allocator, io: std.Io, url: []const u8, policy: proxy.Policy, budget: *@import("../http/connection_budget.zig").Budget) ![]u8 {
    const uri = std.Uri.parse(url) catch return error.InvalidTorrentSource;
    if (!(std.ascii.eqlIgnoreCase(uri.scheme, "http") or std.ascii.eqlIgnoreCase(uri.scheme, "https")) or uri.host == null or uri.user != null or uri.password != null or uri.fragment != null) return error.InvalidTorrentSource;
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    var state = proxy.State.initWithBudget(allocator, budget, null, null);
    state.budget_deadline_ns = std.Io.Clock.now(.awake, io).nanoseconds + 15 * std.time.ns_per_s;
    defer state.deinit();
    defer client.deinit();
    var opened = try proxy.openGet(&client, &state, policy, uri, .{ .headers = .{ .accept_encoding = .{ .override = "identity" } } });
    var complete = false;
    defer {
        if (!complete) {
            opened.request.connection.?.closing = true;
            opened.request.reader.state = .ready;
        }
        opened.deinit();
    }
    if (opened.response.head.status != .ok or opened.response.head.content_encoding != .identity) return error.TorrentRequestRejected;
    var buffer: [8192]u8 = undefined;
    var body = opened.response.reader(&buffer);
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const amount = try body.readSliceShort(&chunk);
        if (amount == 0) break;
        if (bytes.items.len + amount > metainfo.max_metainfo_bytes) return error.InvalidTorrentSize;
        try bytes.appendSlice(allocator, chunk[0..amount]);
    }
    complete = true;
    return bytes.toOwnedSlice(allocator);
}

/// Only inspect bounded engine-owned snapshots, never arbitrary user files.
fn cachedMetadata(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, hash: [20]u8) !?[]u8 {
    var dir = try std.Io.Dir.openDirAbsolute(io, directory, .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);
    var iterator = dir.iterate();
    var inspected: usize = 0;
    var read_bytes: usize = 0;
    const cache_read_limit = 32 * 1024 * 1024;
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".torrent") or
            !(std.mem.startsWith(u8, entry.name, "preview-") or std.mem.startsWith(u8, entry.name, "torrent-"))) continue;
        if (inspected == 256 or read_bytes >= cache_read_limit) break;
        inspected += 1;
        const bytes = dir.readFileAlloc(io, entry.name, allocator, .limited(@min(metainfo.max_metainfo_bytes, cache_read_limit - read_bytes))) catch continue;
        read_bytes += bytes.len;
        const info = metainfo.inspect(allocator, bytes) catch {
            allocator.free(bytes);
            continue;
        };
        if (info.is_private or !std.mem.eql(u8, &info.info_hash, &hash)) {
            allocator.free(bytes);
            continue;
        }
        const map = metainfo.inspectFileMap(allocator, bytes) catch {
            allocator.free(bytes);
            continue;
        };
        map.deinit(allocator);
        return bytes;
    }
    return null;
}
