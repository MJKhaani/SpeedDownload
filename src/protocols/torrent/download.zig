//! BitTorrent v1 transfer path. Each independently placed
//! piece matches its metainfo SHA-1; all partial pieces are rehashed on restart
//! before any byte is trusted. Multi-file payloads use a flat verified spool
//! so pieces crossing file boundaries can resume safely.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const magnet = @import("magnet.zig");
const metadata = @import("metadata.zig");
const metainfo = @import("metainfo.zig");
const http_download = @import("../http/download.zig");

pub const ProgressCallback = *const fn (*anyopaque, u64, ?u64, bool) anyerror!void;
const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(15_000), .clock = .awake } };
const block_size: usize = 16 * 1024;
const max_in_flight_blocks: usize = 8;
const max_piece_blocks: usize = 64 * 1024 * 1024 / block_size;

pub fn download(
    allocator: Allocator,
    io: Io,
    url: []const u8,
    destination: []const u8,
    expected_sha256: ?[32]u8,
    callback: ?ProgressCallback,
    context: ?*anyopaque,
) !void {
    var link = try magnet.inspect(allocator, url);
    defer link.deinit(allocator);
    const session = try metadata.Session.init(io);
    const fetched = try metadata.fetchWithSourceSession(allocator, io, &link, &session);
    defer fetched.deinit(allocator);
    const wrapped = try allocator.alloc(u8, fetched.info.len + "d4:info".len + 1);
    defer allocator.free(wrapped);
    @memcpy(wrapped[0..7], "d4:info");
    @memcpy(wrapped[7 .. 7 + fetched.info.len], fetched.info);
    wrapped[wrapped.len - 1] = 'e';
    const info = try metainfo.inspect(allocator, wrapped);
    const map = try metainfo.inspectFileMap(allocator, wrapped);
    defer map.deinit(allocator);
    if (!std.mem.eql(u8, &info.info_hash, &link.info_hash)) return error.MetadataHashMismatch;
    try transferValidated(allocator, io, info, map, &link, fetched.peer, destination, expected_sha256, callback, context, &session);
}

/// Download a validated v1 `.torrent` using its tracker tiers. The destination
/// is a full file path for single-file torrents or a directory for multi-file.
pub fn downloadTorrentFile(
    allocator: Allocator,
    io: Io,
    torrent_path: []const u8,
    destination: []const u8,
    expected_sha256: ?[32]u8,
    callback: ?ProgressCallback,
    context: ?*anyopaque,
) !void {
    const bytes = try Io.Dir.readFileAlloc(.cwd(), io, torrent_path, allocator, .limited(metainfo.max_metainfo_bytes));
    defer allocator.free(bytes);
    const info = try metainfo.inspect(allocator, bytes);
    const map = try metainfo.inspectFileMap(allocator, bytes);
    defer map.deinit(allocator);
    const trackers = try metainfo.trackerUrls(allocator, info);
    const peers = allocator.alloc([]u8, 0) catch |err| {
        for (trackers) |tracker| allocator.free(tracker);
        allocator.free(trackers);
        return err;
    };
    var link: magnet.Result = .{ .info_hash = info.info_hash, .display_name = null, .trackers = trackers, .peers = peers };
    defer link.deinit(allocator);
    const session = try metadata.Session.init(io);
    try transferValidated(allocator, io, info, map, &link, null, destination, expected_sha256, callback, context, &session);
}

/// Queue worker entry point for a desktop-selected local torrent source URL.
pub fn downloadTorrentSource(allocator: Allocator, io: Io, url: []const u8, destination: []const u8, expected_sha256: ?[32]u8, callback: ?ProgressCallback, context: ?*anyopaque) !void {
    const path = try @import("source.zig").pathAlloc(allocator, url);
    defer allocator.free(path);
    try downloadTorrentFile(allocator, io, path, destination, expected_sha256, callback, context);
}

fn transferValidated(
    allocator: Allocator,
    io: Io,
    info: metainfo.Result,
    map: metainfo.FileMap,
    link: *const magnet.Result,
    first_peer: ?[]const u8,
    destination: []const u8,
    expected_sha256: ?[32]u8,
    callback: ?ProgressCallback,
    context: ?*anyopaque,
    session: *const metadata.Session,
) !void {
    const cwd = Io.Dir.cwd();
    if (cwd.statFile(io, destination, .{})) |_| return error.DestinationExists else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    const part_path = try std.fmt.allocPrint(allocator, "{s}.part", .{destination});
    defer allocator.free(part_path);
    const file = cwd.openFile(io, part_path, .{ .mode = .read_write, .allow_directory = false }) catch |err| switch (err) {
        error.FileNotFound => try cwd.createFile(io, part_path, .{ .exclusive = true, .truncate = false, .read = true }),
        else => return err,
    };
    var file_open = true;
    defer if (file_open) file.close(io);
    const piece_size: usize = std.math.cast(usize, info.piece_length) orelse return error.TorrentTooLarge;
    const piece_buffer = try allocator.alloc(u8, piece_size);
    defer allocator.free(piece_buffer);
    const count = std.math.cast(usize, info.piece_count) orelse return error.TorrentTooLarge;
    const verified = try allocator.alloc(bool, count);
    defer allocator.free(verified);
    @memset(verified, false);
    var verified_bytes: u64 = 0;
    var remaining = try scanVerified(io, file, info, piece_buffer, verified, &verified_bytes);
    try file.setLength(io, info.total_bytes);
    if (callback) |report| if (context) |ctx| try report(ctx, verified_bytes, info.total_bytes, true);

    if (remaining != 0) {
        var last_error: anyerror = error.NoPeerHasPieces;
        if (first_peer) |peer| {
            transferFromPeer(io, peer, info, file, piece_buffer, verified, &remaining, &verified_bytes, callback, context, session) catch |err| {
                if (err == error.TransferPauseRequested or err == error.TransferCancelRequested or err == error.TransferSchedulePaused) return err;
                last_error = err;
            };
        }
        if (remaining != 0) {
            const peers = try metadata.collectPeers(allocator, io, link, verified_bytes, info.total_bytes, session);
            defer {
                for (peers) |peer| allocator.free(peer);
                allocator.free(peers);
            }
            for (peers) |peer| {
                if (first_peer) |first| if (std.mem.eql(u8, peer, first)) continue;
                transferFromPeer(io, peer, info, file, piece_buffer, verified, &remaining, &verified_bytes, callback, context, session) catch |err| {
                    if (err == error.TransferPauseRequested or err == error.TransferCancelRequested or err == error.TransferSchedulePaused) return err;
                    last_error = err;
                    continue;
                };
                if (remaining == 0) break;
            }
        }
        if (remaining != 0) return last_error;
    }
    try file.sync(io);
    if (callback) |report| if (context) |ctx| try report(ctx, info.total_bytes, info.total_bytes, true);
    try http_download.verifySha256(io, file, expected_sha256);
    if (info.single_file) {
        file.close(io);
        file_open = false;
        try http_download.publishNoReplace(cwd, io, part_path, destination);
    } else {
        try publishFileTree(allocator, io, file, map, info.info_hash, destination);
        file.close(io);
        file_open = false;
        cwd.deleteFile(io, part_path) catch {};
    }
}

fn publishFileTree(allocator: Allocator, io: Io, spool: Io.File, map: metainfo.FileMap, info_hash: [20]u8, destination: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const stage = try std.fmt.allocPrint(allocator, "{s}.part-tree", .{destination});
    defer allocator.free(stage);
    // A previous interrupted materialization may be removed only when its
    // ownership marker matches this exact torrent.
    const marker = try std.fmt.allocPrint(allocator, "{s}/.speed-download-stage", .{stage});
    defer allocator.free(marker);
    if (cwd.statFile(io, stage, .{})) |_| {
        const owner = try cwd.readFileAlloc(io, marker, allocator, .limited(4096));
        defer allocator.free(owner);
        if (!std.mem.eql(u8, owner, &info_hash)) return error.ForeignStagingDirectory;
        try cwd.deleteTree(io, stage);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    try cwd.createDir(io, stage, Io.File.Permissions.fromMode(0o700));
    var stage_owned = true;
    errdefer if (stage_owned) cwd.deleteTree(io, stage) catch {};
    {
        const marker_file = try cwd.createFile(io, marker, .{ .exclusive = true, .permissions = Io.File.Permissions.fromMode(0o600) });
        defer marker_file.close(io);
        try marker_file.writeStreamingAll(io, &info_hash);
        try marker_file.sync(io);
    }
    var buffer: [64 * 1024]u8 = undefined;
    for (map.files) |entry| {
        if (std.mem.eql(u8, entry.path, ".speed-download-stage") or std.mem.startsWith(u8, entry.path, ".speed-download-stage/")) return error.ReservedTorrentPath;
        const relative = try std.fs.path.join(allocator, &.{ stage, entry.path });
        defer allocator.free(relative);
        if (std.fs.path.dirname(relative)) |parent| try cwd.createDirPath(io, parent);
        const output = try cwd.createFile(io, relative, .{ .exclusive = true, .permissions = Io.File.Permissions.fromMode(0o600), .resolve_beneath = true });
        errdefer output.close(io);
        var copied: u64 = 0;
        while (copied < entry.length) {
            const amount: usize = @intCast(@min(buffer.len, entry.length - copied));
            if (try spool.readPositionalAll(io, buffer[0..amount], entry.offset + copied) != amount) return error.ShortPartialFileRead;
            try output.writeStreamingAll(io, buffer[0..amount]);
            copied += amount;
        }
        try output.sync(io);
        output.close(io);
    }
    try Io.Dir.renamePreserve(cwd, stage, cwd, destination, io);
    stage_owned = false;
    const published_marker = try std.fmt.allocPrint(allocator, "{s}/.speed-download-stage", .{destination});
    defer allocator.free(published_marker);
    cwd.deleteFile(io, published_marker) catch {};
}

fn pieceOffset(info: metainfo.Result, index: u64) !u64 {
    return std.math.mul(u64, index, info.piece_length) catch error.TorrentSizeOverflow;
}

fn pieceBytes(info: metainfo.Result, index: u64) !usize {
    const offset = try pieceOffset(info, index);
    if (offset >= info.total_bytes) return error.InvalidTorrentPieces;
    return @intCast(@min(info.piece_length, info.total_bytes - offset));
}

fn scanVerified(io: Io, file: Io.File, info: metainfo.Result, buffer: []u8, verified: []bool, verified_bytes: *u64) !usize {
    const length = try file.length(io);
    var remaining = verified.len;
    for (verified, 0..) |*valid, index| {
        const piece: u64 = @intCast(index);
        const offset = try pieceOffset(info, piece);
        const size = try pieceBytes(info, piece);
        if (length < offset + size) continue;
        if (try file.readPositionalAll(io, buffer[0..size], offset) != size) return error.ShortPartialFileRead;
        var actual: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(buffer[0..size], &actual, .{});
        const expected = info.piece_hashes[@as(usize, @intCast(piece)) * 20 ..][0..20];
        if (!std.mem.eql(u8, &actual, expected)) continue;
        valid.* = true;
        verified_bytes.* += size;
        remaining -= 1;
    }
    return remaining;
}

fn transferFromPeer(
    io: Io,
    address: []const u8,
    info: metainfo.Result,
    file: Io.File,
    piece_buffer: []u8,
    verified: []bool,
    remaining: *usize,
    verified_bytes: *u64,
    callback: ?ProgressCallback,
    context: ?*anyopaque,
    session: *const metadata.Session,
) !void {
    const separator = std.mem.lastIndexOfScalar(u8, address, ':') orelse return error.InvalidPeerAddress;
    const port = std.fmt.parseInt(u16, address[separator + 1 ..], 10) catch return error.InvalidPeerAddress;
    const host = address[0..separator];
    if (host.len == 0 or port == 0) return error.InvalidPeerAddress;
    const options: Io.net.IpAddress.ConnectOptions = .{
        .mode = .stream,
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(10_000), .clock = .awake } },
    };
    const stream = if (host[0] == '[') blk: {
        const ip = Io.net.IpAddress.parseIp6(host[1 .. host.len - 1], port) catch return error.InvalidPeerAddress;
        break :blk try ip.connect(io, options);
    } else blk: {
        const name = Io.net.HostName.init(host) catch return error.InvalidPeerAddress;
        break :blk try name.connect(io, port, options);
    };
    defer stream.close(io);
    var write_buffer: [4096]u8 = undefined;
    var socket_writer = stream.writer(io, &write_buffer);
    var hello: [68]u8 = @splat(0);
    hello[0] = 19;
    @memcpy(hello[1..20], "BitTorrent protocol");
    @memcpy(hello[28..48], &info.info_hash);
    @memcpy(hello[48..68], &session.peer_id);
    try socket_writer.interface.writeAll(&hello);
    try socket_writer.interface.flush();
    var response: [68]u8 = undefined;
    try readExact(io, stream, &response);
    if (response[0] != 19 or !std.mem.eql(u8, response[1..20], "BitTorrent protocol") or
        !std.mem.eql(u8, response[28..48], &info.info_hash)) return error.PeerHandshakeMismatch;
    try socket_writer.interface.writeAll(&.{ 0, 0, 0, 1, 2 }); // interested
    try socket_writer.interface.flush();

    var choked = true;
    var frame_buffer: [128 * 1024]u8 = undefined;
    var availability: [metainfo.max_metainfo_bytes / 20 / 8 + 1]u8 = @splat(0);
    var bitfield_known = false;
    piece_loop: while (remaining.* != 0) {
        const piece_index = nextAvailablePiece(verified, &availability, bitfield_known) orelse return error.PeerMissingPieces;
        const size = try pieceBytes(info, piece_index);
        var unchoke_messages: usize = 0;
        var has_piece: ?bool = if (pieceInBitfield(&availability, piece_index)) true else if (bitfield_known) false else null;
        if (has_piece == false) continue :piece_loop;
        while (choked) {
            unchoke_messages += 1;
            if (unchoke_messages > 128) return error.PeerChoked;
            const frame = try readFrame(io, stream, &frame_buffer);
            try updateAvailability(frame, piece_index, info.piece_count, &availability, &bitfield_known, &has_piece);
            if (has_piece == false) continue :piece_loop;
            if (frame.len == 1 and frame[0] == 1) choked = false;
        }
        const block_count = std.math.divCeil(usize, size, block_size) catch return error.InvalidTorrentPieceLength;
        if (block_count > max_piece_blocks) return error.InvalidTorrentPieceLength;
        var received: [max_piece_blocks]bool = @splat(false);
        var requested_blocks: usize = 0;
        var received_blocks: usize = 0;
        var received_bytes: usize = 0;
        var idle_messages: usize = 0;
        while (received_blocks < block_count) {
            while (requested_blocks < block_count and requested_blocks - received_blocks < max_in_flight_blocks) {
                const begin = requested_blocks * block_size;
                const amount = @min(block_size, size - begin);
                var request: [17]u8 = .{ 0, 0, 0, 13, 6 } ++ @as([12]u8, @splat(0));
                std.mem.writeInt(u32, request[5..9], @intCast(piece_index), .big);
                std.mem.writeInt(u32, request[9..13], @intCast(begin), .big);
                std.mem.writeInt(u32, request[13..17], @intCast(amount), .big);
                try socket_writer.interface.writeAll(&request);
                requested_blocks += 1;
            }
            try socket_writer.interface.flush();
            const frame = try readFrame(io, stream, &frame_buffer);
            if (frame.len == 1 and frame[0] == 0) return error.PeerChoked;
            try updateAvailability(frame, piece_index, info.piece_count, &availability, &bitfield_known, &has_piece);
            if (has_piece == false) return error.PeerMissingPieces;
            if (frame.len < 9 or frame[0] != 7) {
                idle_messages += 1;
                if (idle_messages > 128) return error.PeerPieceUnavailable;
                continue;
            }
            const index = std.mem.readInt(u32, frame[1..5], .big);
            const begin: usize = std.mem.readInt(u32, frame[5..9], .big);
            if (index != piece_index or begin % block_size != 0 or begin >= size) return error.UnexpectedPeerPiece;
            const block_index = begin / block_size;
            if (block_index >= requested_blocks) return error.UnexpectedPeerPiece;
            const amount = @min(block_size, size - begin);
            if (frame.len != amount + 9) return error.UnexpectedPeerPiece;
            if (received[block_index]) {
                idle_messages += 1;
                if (idle_messages > 128) return error.PeerPieceUnavailable;
                continue;
            }
            @memcpy(piece_buffer[begin .. begin + amount], frame[9..]);
            received[block_index] = true;
            received_blocks += 1;
            received_bytes += amount;
            idle_messages = 0;
            if (callback) |report| if (context) |ctx| try report(ctx, verified_bytes.* + received_bytes, info.total_bytes, false);
        }
        var digest: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(piece_buffer[0..size], &digest, .{});
        const expected = info.piece_hashes[@as(usize, @intCast(piece_index)) * 20 ..][0..20];
        if (!std.mem.eql(u8, &digest, expected)) return error.TorrentPieceHashMismatch;
        try file.writePositionalAll(io, piece_buffer[0..size], try pieceOffset(info, piece_index));
        try file.sync(io);
        verified[@intCast(piece_index)] = true;
        verified_bytes.* += size;
        remaining.* -= 1;
        if (callback) |report| if (context) |ctx| try report(ctx, verified_bytes.*, info.total_bytes, true);
    }
}

fn nextAvailablePiece(verified: []const bool, availability: []const u8, bitfield_known: bool) ?u64 {
    for (verified, 0..) |done, index| {
        if (done) continue;
        if (bitfield_known and !pieceInBitfield(availability, index)) continue;
        return @intCast(index);
    }
    return null;
}

// A missing bitfield leaves availability unknown; a received bitfield is
// authoritative for the current piece until a later HAVE announces it.
fn updateAvailability(frame: []const u8, piece_index: u64, piece_count: u64, bitfield: []u8, bitfield_known: *bool, has_piece: *?bool) !void {
    if (frame.len == 0) return;
    switch (frame[0]) {
        4 => {
            if (frame.len != 5) return error.InvalidPeerHave;
            const announced = std.mem.readInt(u32, frame[1..5], .big);
            if (announced >= piece_count) return error.InvalidPeerHave;
            bitfield[@as(usize, @intCast(announced / 8))] |= @as(u8, 0x80) >> @as(u3, @intCast(announced % 8));
            if (announced == piece_index) has_piece.* = true;
        },
        5 => {
            const bitfield_len = std.math.divCeil(u64, piece_count, 8) catch return error.InvalidTorrentPieces;
            if (frame.len != bitfield_len + 1 or bitfield_len > bitfield.len or bitfield_known.*) return error.InvalidPeerBitfield;
            const spare: u3 = @intCast((8 - piece_count % 8) % 8);
            if (spare != 0 and frame[frame.len - 1] & ((@as(u8, 1) << spare) - 1) != 0) return error.InvalidPeerBitfield;
            @memcpy(bitfield[0..@intCast(bitfield_len)], frame[1..]);
            bitfield_known.* = true;
            has_piece.* = pieceInBitfield(bitfield, piece_index);
        },
        else => {},
    }
}

fn pieceInBitfield(bitfield: []const u8, piece_index: u64) bool {
    const index: usize = @intCast(piece_index / 8);
    const bit: u3 = @intCast(piece_index % 8);
    return bitfield[index] & (@as(u8, 0x80) >> bit) != 0;
}

fn readExact(io: Io, stream: Io.net.Stream, output: []u8) !void {
    var offset: usize = 0;
    while (offset < output.len) {
        var buffers: [1][]u8 = .{output[offset..]};
        const result = try io.operateTimeout(.{ .net_read = .{ .socket_handle = stream.socket.handle, .data = &buffers } }, timeout);
        const amount = (try result.net_read).data_len;
        if (amount == 0) return error.PeerClosed;
        offset += amount;
    }
}

fn readFrame(io: Io, stream: Io.net.Stream, buffer: []u8) ![]u8 {
    var prefix: [4]u8 = undefined;
    try readExact(io, stream, &prefix);
    const length = std.mem.readInt(u32, &prefix, .big);
    if (length > buffer.len) return error.PeerMessageTooLarge;
    try readExact(io, stream, buffer[0..length]);
    return buffer[0..length];
}
