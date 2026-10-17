//! Certificate-validated TLS transport for explicit FTPS control/data sockets.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const TlsClient = std.crypto.tls.Client;
const Bundle = std.crypto.Certificate.Bundle;
const read_timeout: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(30_000), .clock = .awake } };

const TimedReader = struct {
    io: Io,
    stream: Io.net.Stream,
    interface: Io.Reader,
    last_error: ?anyerror = null,

    fn init(io: Io, stream: Io.net.Stream, buffer: []u8) TimedReader {
        return .{
            .io = io,
            .stream = stream,
            .interface = .{
                .vtable = &.{ .stream = streamImpl, .readVec = readVec },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
        };
    }

    fn streamImpl(reader: *Io.Reader, writer: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const dest = limit.slice(try writer.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const count = try readVec(reader, &data);
        writer.advance(count);
        return count;
    }

    fn readVec(reader: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const self: *TimedReader = @alignCast(@fieldParentPtr("interface", reader));
        var vectors: [8][]u8 = undefined;
        const destination_count, const requested_size = try reader.writableVector(&vectors, data);
        const result = self.io.operateTimeout(.{ .net_read = .{
            .socket_handle = self.stream.socket.handle,
            .data = vectors[0..destination_count],
        } }, read_timeout) catch |err| {
            self.last_error = err;
            return error.ReadFailed;
        };
        const received = result.net_read catch |err| {
            self.last_error = err;
            return error.ReadFailed;
        };
        if (received.data_len == 0) return error.EndOfStream;
        if (received.data_len > requested_size) {
            reader.end += received.data_len - requested_size;
            return requested_size;
        }
        return received.data_len;
    }
};

pub const Trust = struct {
    bundle: Bundle = .empty,
    lock: Io.RwLock = .init,
    now: Io.Timestamp,

    pub fn init(allocator: Allocator, io: Io) !Trust {
        var trust: Trust = .{ .now = Io.Clock.real.now(io) };
        try trust.bundle.rescan(allocator, io, trust.now);
        return trust;
    }

    pub fn deinit(self: *Trust, allocator: Allocator) void {
        self.bundle.deinit(allocator);
    }
};

pub const Transport = struct {
    socket_reader: TimedReader,
    socket_writer: Io.net.Stream.Writer,
    client: TlsClient,
    socket_read_buffer: [TlsClient.min_buffer_len]u8 = undefined,
    socket_write_buffer: [TlsClient.min_buffer_len]u8 = undefined,
    tls_read_buffer: [TlsClient.min_buffer_len]u8 = undefined,
    tls_write_buffer: [TlsClient.min_buffer_len]u8 = undefined,

    pub fn create(
        allocator: Allocator,
        io: Io,
        stream: Io.net.Stream,
        host: []const u8,
        trust: *Trust,
        allow_truncation: bool,
    ) !*Transport {
        const result = try allocator.create(Transport);
        errdefer allocator.destroy(result);
        result.socket_reader = TimedReader.init(io, stream, &result.socket_read_buffer);
        result.socket_writer = stream.writer(io, &result.socket_write_buffer);
        var entropy: [TlsClient.Options.entropy_len]u8 = undefined;
        io.random(&entropy);
        result.client = TlsClient.init(&result.socket_reader.interface, &result.socket_writer.interface, .{
            .host = .{ .explicit = host },
            .ca = .{ .bundle = .{ .gpa = allocator, .io = io, .lock = &trust.lock, .bundle = &trust.bundle } },
            .read_buffer = &result.tls_read_buffer,
            .write_buffer = &result.tls_write_buffer,
            .entropy = &entropy,
            .realtime_now = trust.now,
            .allow_truncation_attacks = allow_truncation,
        }) catch |err| {
            if (result.socket_reader.last_error) |read_err| {
                if (read_err == error.Timeout) return error.FtpsHandshakeTimedOut;
            }
            return err;
        };
        return result;
    }

    pub fn destroy(self: *Transport, allocator: Allocator) void {
        allocator.destroy(self);
    }

    pub fn readTimedOut(self: *Transport) bool {
        if (self.socket_reader.last_error) |read_err| return read_err == error.Timeout;
        return false;
    }
};
