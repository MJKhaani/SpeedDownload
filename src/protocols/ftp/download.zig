//! Conservative passive-mode FTP download. Partial bytes are resumed only
//! when SIZE and MDTM still match the durable journal.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const http_download = @import("../http/download.zig");
const tls = @import("tls.zig");

pub const ProgressCallback = *const fn (*anyopaque, u64, ?u64, bool) anyerror!void;
pub const ProbeResult = @import("../http/probe.zig").Result;
const magic = "SDFTP001";
const journal_len = magic.len + 32 + 8 + 8 + 14;
const checkpoint_interval: u64 = 1024 * 1024;
const read_timeout: Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(30_000), .clock = .awake } };

const Metadata = struct { size: ?u64 = null, modified: ?[14]u8 = null };
const Journal = struct { source_hash: [32]u8, size: u64, completed: u64, modified: [14]u8 };

const FtpHost = union(enum) {
    name: Io.net.HostName,
    address: Io.net.IpAddress,

    fn fromUri(uri: std.Uri, buffer: *[Io.net.HostName.max_len]u8) !FtpHost {
        const component = uri.host orelse return error.InvalidFtpUrl;
        const raw = switch (component) { .raw, .percent_encoded => |value| value };
        if (raw.len >= 2 and raw[0] == '[' and raw[raw.len - 1] == ']')
            return .{ .address = Io.net.IpAddress.parseIp6(raw[1 .. raw.len - 1], uri.port orelse 21) catch return error.InvalidFtpUrl };
        return .{ .name = Io.net.HostName.fromUri(uri, buffer) catch return error.InvalidFtpUrl };
    }

    fn connect(self: FtpHost, io: Io, port: u16) !Io.net.Stream {
        const options: Io.net.IpAddress.ConnectOptions = .{
            .mode = .stream,
            .timeout = .{ .duration = .{ .raw = .fromMilliseconds(15_000), .clock = .awake } },
        };
        return switch (self) {
            .name => |name| name.connect(io, port, options),
            .address => |address| blk: {
                var target = address;
                target.ip6.port = port;
                break :blk target.connect(io, options);
            },
        };
    }

    fn requiresEpsv(self: FtpHost) bool {
        return switch (self) { .name => false, .address => true };
    }
};

const Reply = struct { code: u16, text: []const u8 };

const Control = struct {
    io: Io,
    stream: Io.net.Stream,
    writer: Io.net.Stream.Writer,
    secure: ?*tls.Transport = null,
    read_buffer: [4096]u8 = undefined,
    read_position: usize = 0,
    read_end: usize = 0,
    line_buffer: [4096]u8 = undefined,
    write_buffer: [512]u8 = undefined,

    fn init(self: *Control, io: Io, stream: Io.net.Stream) void {
        self.io = io;
        self.stream = stream;
        self.writer = stream.writer(io, &self.write_buffer);
    }

    fn close(self: *Control, allocator: Allocator) void {
        if (self.secure) |transport| transport.destroy(allocator);
        self.stream.close(self.io);
    }

    fn enableTls(self: *Control, allocator: Allocator, host: []const u8, trust: *tls.Trust) !void {
        if (self.read_position != self.read_end) return error.UnexpectedFtpPipelining;
        self.secure = try tls.Transport.create(allocator, self.io, self.stream, host, trust, false);
        self.read_position = 0;
        self.read_end = 0;
    }

    fn line(self: *Control) ![]const u8 {
        var length: usize = 0;
        while (length < self.line_buffer.len) {
            if (self.read_position == self.read_end) {
                self.read_end = if (self.secure) |transport|
                    transport.client.reader.readSliceShort(&self.read_buffer) catch
                        return if (transport.readTimedOut()) error.FtpControlReadTimedOut else error.FtpTlsReadFailed
                else
                    try readWithTimeout(self.io, self.stream, &self.read_buffer);
                self.read_position = 0;
                if (self.read_end == 0) return error.FtpControlClosed;
            }
            const byte = self.read_buffer[self.read_position];
            self.read_position += 1;
            if (byte == '\n') return std.mem.trimEnd(u8, self.line_buffer[0..length], "\r");
            self.line_buffer[length] = byte;
            length += 1;
        }
        return error.FtpReplyTooLong;
    }

    fn reply(self: *Control) !Reply {
        var expected: ?u16 = null;
        for (0..64) |_| {
            const text = self.line() catch |err| switch (err) {
                error.Timeout => return error.FtpControlReadTimedOut,
                error.FtpControlClosed, error.FtpReplyTooLong => return err,
                else => return error.FtpControlReadFailed,
            };
            if (text.len < 4 or !std.ascii.isDigit(text[0]) or !std.ascii.isDigit(text[1]) or !std.ascii.isDigit(text[2])) {
                if (expected != null) continue;
                return error.InvalidFtpReply;
            }
            const code = std.fmt.parseInt(u16, text[0..3], 10) catch return error.InvalidFtpReply;
            if (expected) |value| {
                if (code == value and text[3] == ' ') return .{ .code = code, .text = text[4..] };
            } else switch (text[3]) {
                ' ' => return .{ .code = code, .text = text[4..] },
                '-' => expected = code,
                else => return error.InvalidFtpReply,
            }
        }
        return error.FtpReplyTooLong;
    }

    fn command(self: *Control, verb: []const u8, argument: ?[]const u8) !Reply {
        if (argument) |value| if (value.len == 0 or value.len > 2048 or std.mem.indexOfAny(u8, value, "\r\n\x00") != null)
            return error.InvalidFtpPath;
        const output: *Io.Writer = if (self.secure) |transport| &transport.client.writer else &self.writer.interface;
        if (argument) |value| {
            try output.print("{s} {s}\r\n", .{ verb, value });
        } else {
            try output.print("{s}\r\n", .{verb});
        }
        try output.flush();
        const response = try self.reply();
        if (response.code == 421) return error.FtpServerBusy;
        return response;
    }
};

fn welcomeReply(control: *Control) !void {
    var welcome = try control.reply();
    // RFC 959 permits a preliminary 120 before the service-ready 220.
    if (welcome.code == 120) welcome = try control.reply();
    if (welcome.code == 421) return error.FtpServerBusy;
    if (welcome.code != 220) return error.FtpServerUnavailable;
}

fn temporarilyUnavailable(code: u16) bool {
    return code == 421 or code == 425 or code == 450 or code == 451 or code == 452;
}

fn isFtps(uri: std.Uri) bool {
    return std.ascii.eqlIgnoreCase(uri.scheme, "ftps");
}

fn tlsHost(uri: std.Uri, host: FtpHost) []const u8 {
    return switch (host) {
        .name => |name| name.bytes,
        .address => blk: {
            const component = uri.host.?;
            const raw = switch (component) { .raw, .percent_encoded => |value| value };
            break :blk raw[1 .. raw.len - 1];
        },
    };
}

fn secureControl(control: *Control, allocator: Allocator, uri: std.Uri, host: FtpHost, trust: *tls.Trust) !void {
    const auth = try control.command("AUTH", "TLS");
    if (auth.code != 234) return error.FtpsUnavailable;
    try control.enableTls(allocator, tlsHost(uri, host), trust);
}

fn protectData(control: *Control) !void {
    const pbsz = try control.command("PBSZ", "0");
    if (pbsz.code != 200) return error.FtpsDataProtectionUnavailable;
    const prot = try control.command("PROT", "P");
    if (prot.code != 200) return error.FtpsDataProtectionUnavailable;
}

pub fn download(
    allocator: Allocator,
    io: Io,
    url: []const u8,
    destination: []const u8,
    expected_sha256: ?[32]u8,
    callback: ?ProgressCallback,
    context: ?*anyopaque,
) !void {
    const uri = std.Uri.parse(url) catch return error.InvalidFtpUrl;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "ftp") and !isFtps(uri)) return error.UnsupportedScheme;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null)
        return error.UnsupportedFtpCredentials;
    var host_buffer: [Io.net.HostName.max_len]u8 = undefined;
    const host = try FtpHost.fromUri(uri, &host_buffer);
    const path = try ftpPath(allocator, uri);
    defer allocator.free(path);
    var trust: ?tls.Trust = if (isFtps(uri)) try tls.Trust.init(allocator, io) else null;
    defer if (trust) |*value| value.deinit(allocator);
    const control_stream = try host.connect(io, uri.port orelse 21);
    var control: Control = undefined;
    control.init(io, control_stream);
    defer control.close(allocator);
    try welcomeReply(&control);
    if (trust) |*value| try secureControl(&control, allocator, uri, host, value);
    try login(&control);
    if (trust != null) try protectData(&control);

    const metadata = try inspectMetadata(&control, path);
    const cwd = Io.Dir.cwd();
    if (cwd.statFile(io, destination, .{})) |_| return error.DestinationExists else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    const part_path = try std.fmt.allocPrint(allocator, "{s}.part", .{destination});
    defer allocator.free(part_path);
    const journal_path = try std.fmt.allocPrint(allocator, "{s}.ftpj", .{part_path});
    defer allocator.free(journal_path);
    var source_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(url, &source_hash, .{});

    const part_exists = try fileExists(io, part_path);
    const rest_supported = if (metadata.size != null and metadata.modified != null and !part_exists) blk: {
        const reply = try control.command("REST", "0");
        break :blk reply.code == 350;
    } else false;
    var offset: u64 = 0;
    if (part_exists) {
        const prior = (try readJournal(io, journal_path)) orelse return error.UntrustedFtpPartial;
        if (!std.mem.eql(u8, &prior.source_hash, &source_hash) or metadata.size == null or metadata.modified == null or
            prior.size != metadata.size.? or !std.mem.eql(u8, &prior.modified, &metadata.modified.?))
            return error.FtpRepresentationChanged;
        offset = prior.completed;
    } else if (try fileExists(io, journal_path)) {
        cwd.deleteFile(io, journal_path) catch {};
    }
    const file = if (part_exists)
        try cwd.openFile(io, part_path, .{ .mode = .read_write, .allow_directory = false })
    else
        try cwd.createFile(io, part_path, .{ .exclusive = true, .truncate = false, .read = true });
    var file_open = true;
    var published = false;
    defer {
        if (file_open) file.close(io);
        if (!published and !part_exists and !rest_supported) {
            cwd.deleteFile(io, part_path) catch {};
            cwd.deleteFile(io, journal_path) catch {};
        }
    }
    if (part_exists) {
        const length = try file.length(io);
        if (length < offset) return error.InvalidFtpJournal;
        if (length != offset) try file.setLength(io, offset);
    }
    var file_buffer: [32 * 1024]u8 = undefined;
    var file_writer = file.writer(io, &file_buffer);
    try file_writer.seekTo(offset);
    if (rest_supported and !part_exists) {
        try saveJournal(io, journal_path, .{ .source_hash = source_hash, .size = metadata.size.?, .completed = 0, .modified = metadata.modified.? });
    }
    if (callback) |report| if (context) |ctx| try report(ctx, offset, metadata.size, true);
    if (metadata.size) |size| if (part_exists and offset == size) {
        try http_download.verifySha256(io, file, expected_sha256);
        try file.sync(io);
        file.close(io);
        file_open = false;
        try http_download.publishNoReplace(cwd, io, part_path, destination);
        published = true;
        cwd.deleteFile(io, journal_path) catch {};
        return;
    };
    if (offset > 0) {
        const rest_text = try std.fmt.allocPrint(allocator, "{d}", .{offset});
        defer allocator.free(rest_text);
        const rest = try control.command("REST", rest_text);
        if (rest.code != 350) return error.FtpRestUnsupported;
    }

    const data_port = try passivePort(&control, host.requiresEpsv());
    const data_stream = try host.connect(io, data_port);
    var data_open = true;
    var data_tls: ?*tls.Transport = null;
    defer {
        if (data_tls) |transport| transport.destroy(allocator);
        if (data_open) data_stream.close(io);
    }
    const opening = try control.command("RETR", path);
    if (temporarilyUnavailable(opening.code)) return error.FtpServerBusy;
    if (opening.code != 125 and opening.code != 150) return error.FtpRetrFailed;
    if (trust) |*value|
        data_tls = try tls.Transport.create(allocator, io, data_stream, tlsHost(uri, host), value, metadata.size != null);

    var chunk: [32 * 1024]u8 = undefined;
    var completed = offset;
    var checkpointed = offset;
    errdefer {
        if (completed > checkpointed) {
            const synced = blk: {
                file_writer.flush() catch break :blk false;
                file.sync(io) catch break :blk false;
                break :blk true;
            };
            if (synced and (part_exists or rest_supported))
                saveJournal(io, journal_path, .{ .source_hash = source_hash, .size = metadata.size.?, .completed = completed, .modified = metadata.modified.? }) catch {};
        }
    }
    while (true) {
        if (callback) |report| if (context) |ctx| try report(ctx, completed, metadata.size, false);
        const count = (if (data_tls) |transport|
            transport.client.reader.readSliceShort(&chunk)
        else
            readWithTimeout(io, data_stream, &chunk)) catch |err| switch (err) {
            error.Timeout => return error.FtpDataReadTimedOut,
            else => return if (data_tls) |transport|
                if (transport.readTimedOut()) error.FtpDataReadTimedOut else error.FtpDataReadFailed
            else
                error.FtpDataReadFailed,
        };
        if (count == 0) break;
        try file_writer.interface.writeAll(chunk[0..count]);
        completed += count;
        if (metadata.size) |size| if (completed > size) return error.FtpSizeMismatch;
        if (completed - checkpointed >= checkpoint_interval) {
            try file_writer.flush();
            try file.sync(io);
            if (part_exists or rest_supported)
                try saveJournal(io, journal_path, .{ .source_hash = source_hash, .size = metadata.size.?, .completed = completed, .modified = metadata.modified.? });
            checkpointed = completed;
            if (callback) |report| if (context) |ctx| try report(ctx, completed, metadata.size, true);
        }
    }
    if (data_tls) |transport| {
        transport.destroy(allocator);
        data_tls = null;
    }
    data_stream.close(io);
    data_open = false;
    const finished = try control.reply();
    if (temporarilyUnavailable(finished.code)) return error.FtpServerBusy;
    if (finished.code != 226 and finished.code != 250) return error.FtpTransferIncomplete;
    // A server may replace the file while its data connection is open. Keep
    // the partial for diagnosis, but never publish it as a complete download
    // when the available representation identity changed during transfer.
    if (metadata.size != null or metadata.modified != null) {
        const current = try inspectMetadata(&control, path);
        if (metadata.size != current.size or
            (metadata.modified != null and (current.modified == null or
                !std.mem.eql(u8, &metadata.modified.?, &current.modified.?))))
            return error.FtpRepresentationChanged;
    }
    try file_writer.flush();
    try file.sync(io);
    if (metadata.size) |size| if (completed != size) return error.FtpSizeMismatch;
    if (callback) |report| if (context) |ctx| try report(ctx, completed, metadata.size, true);
    try http_download.verifySha256(io, file, expected_sha256);
    file.close(io);
    file_open = false;
    try http_download.publishNoReplace(cwd, io, part_path, destination);
    published = true;
    cwd.deleteFile(io, journal_path) catch {};
}

fn readWithTimeout(io: Io, stream: Io.net.Stream, buffer: []u8) !usize {
    var data: [1][]u8 = .{buffer};
    const result = try io.operateTimeout(.{ .net_read = .{
        .socket_handle = stream.socket.handle,
        .data = &data,
    } }, read_timeout);
    return (try result.net_read).data_len;
}

pub fn inspect(allocator: Allocator, io: Io, url: []const u8) !ProbeResult {
    const uri = std.Uri.parse(url) catch return error.InvalidFtpUrl;
    if ((!std.ascii.eqlIgnoreCase(uri.scheme, "ftp") and !isFtps(uri)) or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null)
        return error.InvalidFtpUrl;
    var host_buffer: [Io.net.HostName.max_len]u8 = undefined;
    const host = try FtpHost.fromUri(uri, &host_buffer);
    const path = try ftpPath(allocator, uri);
    defer allocator.free(path);
    var trust: ?tls.Trust = if (isFtps(uri)) try tls.Trust.init(allocator, io) else null;
    defer if (trust) |*value| value.deinit(allocator);
    const stream = try host.connect(io, uri.port orelse 21);
    var control: Control = undefined;
    control.init(io, stream);
    defer control.close(allocator);
    try welcomeReply(&control);
    if (trust) |*value| try secureControl(&control, allocator, uri, host, value);
    try login(&control);
    if (trust != null) try protectData(&control);
    const metadata = try inspectMetadata(&control, path);
    const rest = if (metadata.size != null and metadata.modified != null)
        try control.command("REST", "0")
    else
        Reply{ .code = 0, .text = "" };
    const resumable = rest.code == 350;
    const leaf = std.fs.path.basename(path);
    const suggested_name = try allocator.dupe(u8, if (validSuggestedName(leaf)) leaf else "download");
    errdefer allocator.free(suggested_name);
    const total = if (metadata.size) |size| try std.fmt.allocPrint(allocator, "{d}", .{size}) else null;
    errdefer if (total) |value| allocator.free(value);
    const final_url = try allocator.dupe(u8, url);
    errdefer allocator.free(final_url);
    return .{
        .final_url = final_url,
        .suggested_name = suggested_name,
        .total_bytes = total,
        .status_code = 200,
        .http_version = try allocator.dupe(u8, if (isFtps(uri)) "FTPS" else "FTP"),
        .content_type = null,
        .range_supported = false,
        .resume_supported = resumable,
        .multipart_supported = false,
        .message = if (isFtps(uri))
            if (resumable)
                "Encrypted passive FTPS transfer; SIZE, MDTM, and REST support resume."
            else
                "Encrypted passive FTPS transfer; resume is unavailable on this server."
        else if (resumable)
            "Passive FTP transfer; SIZE, MDTM, and REST support resumable downloads."
        else
            "Passive FTP transfer; safe resume is unavailable on this server.",
    };
}

fn login(control: *Control) !void {
    const user = try control.command("USER", "anonymous");
    if (user.code == 331) {
        const pass = try control.command("PASS", "speed-download@");
        if (pass.code != 230) return error.FtpLoginFailed;
    } else if (user.code != 230) return error.FtpLoginFailed;
    const binary = try control.command("TYPE", "I");
    if (binary.code != 200) return error.FtpBinaryModeUnavailable;
}

fn inspectMetadata(control: *Control, path: []const u8) !Metadata {
    var result: Metadata = .{};
    const size = try control.command("SIZE", path);
    if (size.code == 213) result.size = std.fmt.parseInt(u64, std.mem.trim(u8, size.text, " \t"), 10) catch null;
    const mdtm = try control.command("MDTM", path);
    if (mdtm.code == 213 and mdtm.text.len >= 14) {
        var value: [14]u8 = undefined;
        @memcpy(&value, mdtm.text[0..14]);
        var valid = true;
        for (value) |byte| if (!std.ascii.isDigit(byte)) { valid = false; break; };
        if (valid) result.modified = value;
    }
    return result;
}

fn passivePort(control: *Control, require_epsv: bool) !u16 {
    const epsv = try control.command("EPSV", null);
    if (epsv.code == 229) {
        const open = std.mem.indexOfScalar(u8, epsv.text, '(') orelse return error.InvalidFtpPassiveReply;
        const close = std.mem.indexOfPos(u8, epsv.text, open + 1, ")") orelse return error.InvalidFtpPassiveReply;
        const payload = epsv.text[open + 1 .. close];
        if (payload.len < 5) return error.InvalidFtpPassiveReply;
        const delimiter = payload[0];
        if (payload[1] != delimiter or payload[2] != delimiter or payload[payload.len - 1] != delimiter)
            return error.InvalidFtpPassiveReply;
        const port = std.fmt.parseInt(u16, payload[3 .. payload.len - 1], 10) catch return error.InvalidFtpPassiveReply;
        if (port == 0) return error.InvalidFtpPassiveReply;
        return port;
    }
    if (temporarilyUnavailable(epsv.code)) return error.FtpServerBusy;
    if (require_epsv) return error.FtpPassiveUnavailable;
    const pasv = try control.command("PASV", null);
    if (temporarilyUnavailable(pasv.code)) return error.FtpServerBusy;
    if (pasv.code != 227) return error.FtpPassiveUnavailable;
    const open = std.mem.indexOfScalar(u8, pasv.text, '(') orelse return error.InvalidFtpPassiveReply;
    const close = std.mem.indexOfPos(u8, pasv.text, open + 1, ")") orelse return error.InvalidFtpPassiveReply;
    var numbers: [6]u8 = undefined;
    var fields = std.mem.splitScalar(u8, pasv.text[open + 1 .. close], ',');
    for (&numbers) |*number| {
        number.* = std.fmt.parseInt(u8, std.mem.trim(u8, fields.next() orelse return error.InvalidFtpPassiveReply, " "), 10) catch return error.InvalidFtpPassiveReply;
    }
    if (fields.next() != null) return error.InvalidFtpPassiveReply;
    const port = @as(u16, numbers[4]) * 256 + numbers[5];
    if (port == 0) return error.InvalidFtpPassiveReply;
    // The advertised PASV address may be private, stale, or malicious. Connect
    // to the control host instead, preventing a third-party FTP bounce.
    return port;
}

fn ftpPath(allocator: Allocator, uri: std.Uri) ![]u8 {
    const raw = switch (uri.path) { .raw, .percent_encoded => |value| value };
    if (raw.len < 2 or raw[0] != '/' or raw.len > 2048) return error.InvalidFtpPath;
    const buffer = try allocator.alloc(u8, raw.len);
    defer allocator.free(buffer);
    const decoded = if (uri.path == .percent_encoded) std.Uri.percentDecodeBackwards(buffer, raw) else raw;
    if (std.mem.indexOfAny(u8, decoded, "\r\n\x00") != null) return error.InvalidFtpPath;
    if (!std.unicode.utf8ValidateSlice(decoded)) return error.UnsupportedFtpFilenameEncoding;
    return allocator.dupe(u8, decoded);
}

fn validSuggestedName(name: []const u8) bool {
    return name.len > 0 and name.len <= 255 and
        !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..") and
        std.mem.indexOfAny(u8, name, "/\\\x00") == null;
}

fn fileExists(io: Io, path: []const u8) !bool {
    return if (Io.Dir.cwd().statFile(io, path, .{})) |_| true else |err| switch (err) {
        error.FileNotFound => false,
        else => err,
    };
}

fn readJournal(io: Io, path: []const u8) !?Journal {
    const file = Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only, .allow_directory = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);
    if (try file.length(io) != journal_len) return error.InvalidFtpJournal;
    var buffer: [journal_len]u8 = undefined;
    if (try file.readPositionalAll(io, &buffer, 0) != buffer.len) return error.InvalidFtpJournal;
    if (!std.mem.eql(u8, buffer[0..magic.len], magic)) return error.InvalidFtpJournal;
    var result: Journal = undefined;
    var cursor: usize = magic.len;
    @memcpy(&result.source_hash, buffer[cursor..][0..32]);
    cursor += 32;
    result.size = std.mem.readInt(u64, buffer[cursor..][0..8], .big);
    cursor += 8;
    result.completed = std.mem.readInt(u64, buffer[cursor..][0..8], .big);
    cursor += 8;
    @memcpy(&result.modified, buffer[cursor..][0..14]);
    if (result.completed > result.size) return error.InvalidFtpJournal;
    return result;
}

fn saveJournal(io: Io, path: []const u8, value: Journal) !void {
    var buffer: [journal_len]u8 = undefined;
    var cursor: usize = 0;
    @memcpy(buffer[cursor..][0..magic.len], magic);
    cursor += magic.len;
    @memcpy(buffer[cursor..][0..32], &value.source_hash);
    cursor += 32;
    std.mem.writeInt(u64, buffer[cursor..][0..8], value.size, .big);
    cursor += 8;
    std.mem.writeInt(u64, buffer[cursor..][0..8], value.completed, .big);
    cursor += 8;
    @memcpy(buffer[cursor..][0..14], &value.modified);
    var atomic = try Io.Dir.createFileAtomic(.cwd(), io, path, .{ .make_path = true, .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, &buffer);
    try atomic.replace(io);
}
