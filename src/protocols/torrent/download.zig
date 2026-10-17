//! Initial BitTorrent v1 single-file transfer path. Every published piece
//! matches the SHA-1 hash in validated metainfo; partial files are rehashed
//! on restart before any byte is trusted.
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
    const fetched = try metadata.fetchWithSource(allocator, io, &link);
    defer fetched.deinit(allocator);
    const wrapped = try allocator.alloc(u8, fetched.info.len + "d4:info".len + 1);
    defer allocator.free(wrapped);
    @memcpy(wrapped[0..7], "d4:info");
    @memcpy(wrapped[7 .. 7 + fetched.info.len], fetched.info);
    wrapped[wrapped.len - 1] = 'e';
    const info = try metainfo.inspect(allocator, wrapped);
    // Even a one-entry multi-file torrent needs a directory root and path map.
    if (!info.single_file) return error.MultiFileTorrentNotYetSupported;
    if (!std.mem.eql(u8, &info.info_hash, &link.info_hash)) return error.MetadataHashMismatch;

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
    var next_piece = try verifiedPrefix(io, file, info, piece_buffer);
    var completed = try pieceOffset(info, next_piece);
    try file.setLength(io, completed);
    var write_buffer: [32 * 1024]u8 = undefined;
    var writer = file.writer(io, &write_buffer);
    try writer.seekTo(completed);
    if (callback) |report| if (context) |ctx| try report(ctx, completed, info.total_bytes, true);

    if (next_piece < info.piece_count) {
        var last_error: anyerror = error.NoPeerHasPieces;
        transferFromPeer(io, fetched.peer, info, file, &writer, piece_buffer, &next_piece, callback, context) catch |err| {
            if (err == error.TransferPauseRequested or err == error.TransferCancelRequested or err == error.TransferSchedulePaused) return err;
            last_error = err;
        };
        if (next_piece < info.piece_count) {
            const verified = @min(try pieceOffset(info, next_piece), info.total_bytes);
            const peers = try metadata.collectPeers(allocator, io, &link, verified, info.total_bytes);
            defer {
                for (peers) |peer| allocator.free(peer);
                allocator.free(peers);
            }
            for (peers) |peer| {
                if (std.mem.eql(u8, peer, fetched.peer)) continue;
                transferFromPeer(io, peer, info, file, &writer, piece_buffer, &next_piece, callback, context) catch |err| {
                    if (err == error.TransferPauseRequested or err == error.TransferCancelRequested or err == error.TransferSchedulePaused) return err;
                    last_error = err;
                    continue;
                };
                if (next_piece == info.piece_count) break;
            }
        }
        if (next_piece != info.piece_count) return last_error;
    }
    completed = info.total_bytes;
    try writer.interface.flush();
    try file.sync(io);
    if (callback) |report| if (context) |ctx| try report(ctx, completed, completed, true);
    try http_download.verifySha256(io, file, expected_sha256);
    file.close(io);
    file_open = false;
    try http_download.publishNoReplace(cwd, io, part_path, destination);
}

fn pieceOffset(info: metainfo.Result, index: u64) !u64 {
    return std.math.mul(u64, index, info.piece_length) catch error.TorrentSizeOverflow;
}

fn pieceBytes(info: metainfo.Result, index: u64) !usize {
    const offset = try pieceOffset(info, index);
    if (offset >= info.total_bytes) return error.InvalidTorrentPieces;
    return @intCast(@min(info.piece_length, info.total_bytes - offset));
}

fn verifiedPrefix(io: Io, file: Io.File, info: metainfo.Result, buffer: []u8) !u64 {
    const length = try file.length(io);
    var reader_buffer: [32 * 1024]u8 = undefined;
    var reader = file.reader(io, &reader_buffer);
    try reader.seekTo(0);
    var piece: u64 = 0;
    while (piece < info.piece_count) : (piece += 1) {
        const offset = try pieceOffset(info, piece);
        const size = try pieceBytes(info, piece);
        if (length < offset + size) break;
        try reader.interface.readSliceAll(buffer[0..size]);
        var actual: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(buffer[0..size], &actual, .{});
        const expected = info.piece_hashes[@as(usize, @intCast(piece)) * 20 ..][0..20];
        if (!std.mem.eql(u8, &actual, expected)) break;
    }
    return piece;
}

fn transferFromPeer(
    io: Io,
    address: []const u8,
    info: metainfo.Result,
    file: Io.File,
    writer: *Io.File.Writer,
    piece_buffer: []u8,
    next_piece: *u64,
    callback: ?ProgressCallback,
    context: ?*anyopaque,
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
    try io.randomSecure(hello[48..68]);
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
    while (next_piece.* < info.piece_count) {
        const piece_index = next_piece.*;
        const size = try pieceBytes(info, piece_index);
        var cursor: usize = 0;
        var unchoke_messages: usize = 0;
        while (cursor < size) {
            while (choked) {
                unchoke_messages += 1;
                if (unchoke_messages > 128) return error.PeerChoked;
                const frame = try readFrame(io, stream, &frame_buffer);
                if (frame.len == 1 and frame[0] == 1) choked = false;
            }
            const amount = @min(block_size, size - cursor);
            var request: [17]u8 = .{ 0, 0, 0, 13, 6 } ++ @as([12]u8, @splat(0));
            std.mem.writeInt(u32, request[5..9], @intCast(piece_index), .big);
            std.mem.writeInt(u32, request[9..13], @intCast(cursor), .big);
            std.mem.writeInt(u32, request[13..17], @intCast(amount), .big);
            try socket_writer.interface.writeAll(&request);
            try socket_writer.interface.flush();
            var messages: usize = 0;
            while (true) {
                messages += 1;
                if (messages > 128) return error.PeerPieceUnavailable;
                const frame = try readFrame(io, stream, &frame_buffer);
                if (frame.len == 1 and frame[0] == 0) return error.PeerChoked;
                if (frame.len != amount + 9 or frame[0] != 7) continue;
                const index = std.mem.readInt(u32, frame[1..5], .big);
                const begin = std.mem.readInt(u32, frame[5..9], .big);
                if (index != piece_index or begin != cursor) return error.UnexpectedPeerPiece;
                @memcpy(piece_buffer[cursor .. cursor + amount], frame[9..]);
                cursor += amount;
                if (callback) |report| if (context) |ctx| try report(ctx, (try pieceOffset(info, piece_index)) + cursor, info.total_bytes, false);
                break;
            }
        }
        var digest: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(piece_buffer[0..size], &digest, .{});
        const expected = info.piece_hashes[@as(usize, @intCast(piece_index)) * 20 ..][0..20];
        if (!std.mem.eql(u8, &digest, expected)) return error.TorrentPieceHashMismatch;
        try writer.interface.writeAll(piece_buffer[0..size]);
        try writer.interface.flush();
        try file.sync(io);
        next_piece.* += 1;
        if (callback) |report| if (context) |ctx| try report(ctx, @min(try pieceOffset(info, next_piece.*), info.total_bytes), info.total_bytes, true);
    }
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
