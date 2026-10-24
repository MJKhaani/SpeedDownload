//! Unix-domain socket adapter for the framed IPC session protocol.
//! This module targets macOS and Linux and links against libc.

const builtin = @import("builtin");
const std = @import("std");
const frame = @import("frame.zig");
const protocol = @import("root.zig");
const subscription = @import("subscription.zig");
const job_store = @import("../core/job_store.zig");
const posix_stat = @import("../core/posix_stat.zig");
const http_probe = @import("../protocols/http/probe.zig");

const c = std.c;
const LocalTime = extern struct {
    tm_sec: c_int,
    tm_min: c_int,
    tm_hour: c_int,
    tm_mday: c_int,
    tm_mon: c_int,
    tm_year: c_int,
    tm_wday: c_int,
    tm_yday: c_int,
    tm_isdst: c_int,
    tm_gmtoff: c_long,
    tm_zone: ?[*:0]const u8,
};
extern "c" fn time(?*c.time_t) c.time_t;
extern "c" fn localtime_r(*const c.time_t, *LocalTime) ?*LocalTime;
const WindowsSystemTime = extern struct {
    year: u16,
    month: u16,
    day_of_week: u16,
    day: u16,
    hour: u16,
    minute: u16,
    second: u16,
    milliseconds: u16,
};
extern "kernel32" fn GetLocalTime(*WindowsSystemTime) callconv(.winapi) void;
const SocketPath = [*:0]const u8;
const max_socket_path_bytes = if (builtin.os.tag == .macos) 104 else 108;
const max_ipc_clients = 32;

extern "c" fn socket(domain: c_int, socket_type: c_int, protocol_number: c_int) c_int;
extern "c" fn kill(pid: c_int, signal: c_int) c_int;
const getErrno = @extern(*const fn () callconv(.c) *c_int, .{
    .name = if (builtin.os.tag == .macos) "__error" else "__errno_location",
});
extern "c" fn getpid() c_int;

pub const Config = struct {
    /// Private directory owned by this user, such as XDG_RUNTIME_DIR or a
    /// private directory beneath macOS TMPDIR.
    runtime_dir: []const u8,
    app_dir_name: []const u8 = "speed-download",
    socket_name: []const u8 = "engine.sock",
    server: ServerIdentity,
    jobs: *job_store.Store,
};

pub const EngineContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    jobs: *job_store.Store,
    engine_instance_id: []const u8,
    started_ns: i96,
    active_workers: std.atomic.Value(u32) = .init(0),
    http_connections: @import("../protocols/http/connection_budget.zig").Budget = .{},
    active_clients: std.atomic.Value(u32) = .init(0),
    next_subscription_id: std.atomic.Value(u64) = .init(1),
    bandwidth_mutex: std.Io.Mutex = .init,
    bandwidth_next_ns: i96 = 0,
    bandwidth_current_limit: u64 = 0,
    last_queue_window: std.atomic.Value(i8) = .init(-1),
};

pub const ServerIdentity = struct {
    engine_version: []const u8,
    engine_instance_id: []const u8,
    supported_features: []const []const u8,
};

pub const Error = error{
    InvalidPath,
    UnsafeRuntimeDirectory,
    EndpointExists,
    UnexpectedEndOfStream,
    SystemCallFailed,
};

/// Serve clients sequentially. Each accepted connection gets a fresh protocol
/// session, and is authenticated before its first frame is processed.
pub fn serve(allocator: std.mem.Allocator, config: Config) !void {
    if (comptime builtin.os.tag != .macos and builtin.os.tag != .linux) return error.TransportUnavailable;
    return serveUnix(allocator, config);
}

fn serveUnix(allocator: std.mem.Allocator, config: Config) !void {
    var engine = EngineContext{ .allocator = allocator, .io = config.jobs.io, .jobs = config.jobs, .engine_instance_id = config.server.engine_instance_id, .started_ns = std.Io.Clock.now(.awake, config.jobs.io).nanoseconds };
    var paths = try makePaths(allocator, config);
    defer paths.deinit(allocator);

    try validatePrivateDirectory(config.runtime_dir);
    try ensurePrivateDirectory(paths.app_dir);
    if (pathExists(paths.socket_path)) {
        const stale_owner = posix_stat.get(paths.socket_z, false) orelse return Error.EndpointExists;
        if (!posix_stat.isSocket(stale_owner) or stale_owner.uid != posix_stat.currentUid()) return Error.EndpointExists;
        const probe_fd = socket(c.AF.UNIX, c.SOCK.STREAM, 0);
        if (probe_fd < 0) return Error.SystemCallFailed;
        var probe_address = try makeAddress(paths.socket_path);
        const probe_len: c.socklen_t = if (builtin.os.tag == .macos)
            @intCast(@offsetOf(c.sockaddr.un, "path") + paths.socket_path.len + 1)
        else
            @sizeOf(c.sockaddr.un);
        if (c.connect(probe_fd, @ptrCast(&probe_address), probe_len) == 0) {
            _ = c.close(probe_fd);
            return Error.EndpointExists;
        }
        const connect_errno = getErrno().*;
        _ = c.close(probe_fd);
        if (connect_errno != @backingInt(c.E.CONNREFUSED) and connect_errno != @backingInt(c.E.NOENT)) return Error.EndpointExists;
        _ = c.unlink(paths.socket_z);
    }
    const listener = socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (listener < 0) return Error.SystemCallFailed;
    defer _ = c.close(listener);

    var address = try makeAddress(paths.socket_path);
    const address_len: c.socklen_t = if (builtin.os.tag == .macos)
        @intCast(@offsetOf(c.sockaddr.un, "path") + paths.socket_path.len + 1)
    else
        @sizeOf(c.sockaddr.un);
    if (c.bind(listener, @ptrCast(&address), address_len) != 0) {
        std.debug.print("speed-download: IPC bind failed (errno {d})\n", .{getErrno().*});
        return Error.SystemCallFailed;
    }
    const bound_info = posix_stat.get(paths.socket_z, false) orelse return Error.SystemCallFailed;
    defer unlinkIfSame(paths.socket_z, bound_info.device, bound_info.inode);
    if (c.chmod(paths.socket_z, 0o600) != 0) return Error.SystemCallFailed;
    if (c.listen(listener, 16) != 0) return Error.SystemCallFailed;

    scheduleTick(&engine);
    var scheduler = try std.Thread.spawn(.{}, schedulerLoop, .{&engine});
    scheduler.detach();

    while (true) {
        const client = c.accept(listener, null, null);
        if (client < 0) continue;
        if (!reserveClient(&engine)) {
            _ = c.close(client);
            continue;
        }
        var thread = std.Thread.spawn(.{}, handleClientThread, .{ allocator, client, config.server, &engine }) catch {
            _ = engine.active_clients.fetchSub(1, .release);
            _ = c.close(client);
            continue;
        };
        thread.detach();
    }
}

fn reserveClient(engine: *EngineContext) bool {
    while (true) {
        const active = engine.active_clients.load(.acquire);
        if (active >= max_ipc_clients) return false;
        if (engine.active_clients.cmpxchgWeak(active, active + 1, .acquire, .monotonic) == null) return true;
    }
}

fn handleClientThread(allocator: std.mem.Allocator, client: c.fd_t, server: ServerIdentity, engine: *EngineContext) void {
    defer _ = engine.active_clients.fetchSub(1, .release);
    handleClient(allocator, client, server, engine) catch {};
}

fn handleClient(allocator: std.mem.Allocator, client: c.fd_t, server: ServerIdentity, engine: *EngineContext) !void {
    defer _ = c.close(client);
    var timeout = c.timeval{ .sec = 30, .usec = 0 };
    if (c.setsockopt(client, c.SOL.SOCKET, c.SO.RCVTIMEO, &timeout, @sizeOf(c.timeval)) != 0 or
        c.setsockopt(client, c.SOL.SOCKET, c.SO.SNDTIMEO, &timeout, @sizeOf(c.timeval)) != 0)
        return Error.SystemCallFailed;
    if (builtin.os.tag == .macos) {
        var enabled: c_int = 1;
        if (c.setsockopt(client, c.SOL.SOCKET, c.SO.NOSIGPIPE, &enabled, @sizeOf(c_int)) != 0)
            return;
    }
    if (!try peerIsCurrentUser(client)) return;
    try serveConnection(allocator, client, server, engine);
}

fn serveConnection(allocator: std.mem.Allocator, fd: c.fd_t, server: ServerIdentity, engine: *EngineContext) !void {
    var session = protocol.Session{ .dispatch = dispatchMethod, .context = @ptrCast(engine) };
    var active_subscription: ?subscription.Started = null;
    defer if (active_subscription) |item| item.deinit(allocator);
    var event_sequence: u64 = 0;
    var header: [4]u8 = undefined;
    const request_frame = try allocator.alloc(u8, frame.header_bytes + frame.max_payload_bytes);
    defer allocator.free(request_frame);
    var session_id_buffer: [36]u8 = undefined;
    const session_id = uuidString(&session_id_buffer);
    const server_info = protocol.ServerInfo{
        .engine_version = server.engine_version,
        .engine_instance_id = server.engine_instance_id,
        .session_id = session_id,
        .supported_features = server.supported_features,
    };
    while (true) {
        if (active_subscription) |*item| {
            var descriptor = [_]c.pollfd{.{ .fd = fd, .events = @intCast(c.POLL.IN), .revents = 0 }};
            const ready = c.poll(&descriptor, 1, item.interval_ms);
            if (ready < 0) return Error.SystemCallFailed;
            if (ready == 0) {
                const cursor = engine.jobs.changeCursor();
                if (cursor == item.cursor) continue;
                event_sequence += 1;
                const notice = try subscription.eventFrame(allocator, engine.jobs, item, server.engine_instance_id, event_sequence);
                defer allocator.free(notice);
                try writeAll(fd, notice);
                item.cursor = cursor;
                continue;
            }
        }
        readExact(fd, &header) catch return;
        const length = std.mem.readInt(u32, &header, .little);
        if (length == 0 or length > frame.max_payload_bytes) return;

        readExact(fd, request_frame[frame.header_bytes .. frame.header_bytes + length]) catch return;
        @memcpy(request_frame[0..frame.header_bytes], &header);
        const result = protocol.handleFrame(
            allocator,
            &session,
            request_frame[0 .. frame.header_bytes + length],
            server_info,
        ) catch return;
        const started = subscription.started(allocator, request_frame[frame.header_bytes .. frame.header_bytes + length], result.response_frame) catch |err| {
            if (result.response_frame) |response_frame| allocator.free(response_frame);
            return err;
        };
        if (result.response_frame) |response_frame| {
            writeAll(fd, response_frame) catch {
                allocator.free(response_frame);
                if (started) |item| item.deinit(allocator);
                return;
            };
            allocator.free(response_frame);
        }
        if (active_subscription != null and session.subscription_id == null) {
            active_subscription.?.deinit(allocator);
            active_subscription = null;
        }
        if (started) |item| {
            active_subscription = item;
            session.subscription_id = item.id;
            event_sequence = 0;
        }
    }
}

pub fn dispatchMethod(
    allocator: std.mem.Allocator,
    request_id: ?std.json.Value,
    method: []const u8,
    params: ?std.json.Value,
    context: ?*anyopaque,
) anyerror!?[]u8 {
    const engine: *EngineContext = @ptrCast(@alignCast(context orelse return error.MissingDispatcherContext));
    const jobs = engine.jobs;
    jobs.logAction(loggedMethod(method), "received");
    defer jobs.logAction(loggedMethod(method), "finished");
    if (std.mem.eql(u8, method, "engine.status")) {
        const id = request_id orelse return null;
        const elapsed = std.Io.Clock.now(.awake, engine.io).nanoseconds - engine.started_ns;
        return @as(?[]u8, try jobs.statusJson(id, engine.engine_instance_id, @intCast(@max(0, @divTrunc(elapsed, std.time.ns_per_s)))));
    }
    if (std.mem.eql(u8, method, "jobs.list")) {
        const page = parseListPage(params) catch return dispatchError(allocator, request_id, -32602, "Invalid params");
        if (request_id) |id| return @as(?[]u8, try jobs.listFilteredJson(id, page.offset, page.limit, .{ .state = page.state, .search = page.search }));
        return null;
    }
    if (std.mem.eql(u8, method, "jobs.get")) {
        const id = request_id orelse return null;
        const value = params orelse return dispatchError(allocator, request_id, -32602, "Invalid params");
        if (value != .object or value.object.count() != 1) return dispatchError(allocator, request_id, -32602, "Invalid params");
        const job_id = stringField(value.object, "job_id") orelse return dispatchError(allocator, request_id, -32602, "Invalid job ID");
        if (job_id.len == 0 or job_id.len > 128) return dispatchError(allocator, request_id, -32602, "Invalid job ID");
        return jobs.getJson(id, job_id) catch |err| {
            if (err == error.JobNotFound) return dispatchError(allocator, request_id, -32012, "Download job not found");
            return err;
        };
    }
    if (std.mem.eql(u8, method, "jobs.subscribe")) {
        const id = request_id orelse return null;
        const value = params orelse return dispatchError(allocator, request_id, -32602, "Invalid params");
        if (value != .object or value.object.count() > 3) return dispatchError(allocator, request_id, -32602, "Invalid params");
        var max_rate: u16 = 5;
        if (value.object.get("max_updates_per_second")) |rate| {
            if (rate != .integer or rate.integer < 1 or rate.integer > 10) return dispatchError(allocator, request_id, -32602, "Invalid update rate");
            max_rate = @intCast(rate.integer);
        }
        var filter = job_store.Store.ListFilter{};
        if (value.object.get("state")) |state_value| {
            if (state_value != .string) return dispatchError(allocator, request_id, -32602, "Invalid state");
            filter.state = std.meta.stringToEnum(job_store.State, state_value.string) orelse return dispatchError(allocator, request_id, -32602, "Invalid state");
        }
        if (value.object.get("search")) |search_value| {
            if (search_value != .string or search_value.string.len == 0 or search_value.string.len > 128 or
                !std.unicode.utf8ValidateSlice(search_value.string)) return dispatchError(allocator, request_id, -32602, "Invalid search");
            filter.search = search_value.string;
        }
        var fields = value.object.iterator();
        while (fields.next()) |entry| {
            const key = entry.key_ptr.*;
            if (!std.mem.eql(u8, key, "max_updates_per_second") and !std.mem.eql(u8, key, "state") and
                !std.mem.eql(u8, key, "search")) return dispatchError(allocator, request_id, -32602, "Invalid params");
        }
        const number = engine.next_subscription_id.fetchAdd(1, .monotonic);
        const subscription_id = try std.fmt.allocPrint(allocator, "sub-{d}", .{number});
        defer allocator.free(subscription_id);
        return @as(?[]u8, try jobs.subscribeJson(id, subscription_id, engine.engine_instance_id, @divTrunc(1000 + max_rate - 1, max_rate), filter));
    }
    if (std.mem.eql(u8, method, "jobs.wait")) {
        const id = request_id orelse return null;
        const value = params orelse return dispatchError(allocator, request_id, -32602, "Invalid params");
        if (value != .object) return dispatchError(allocator, request_id, -32602, "Invalid params");
        const cursor_text = stringField(value.object, "cursor") orelse return dispatchError(allocator, request_id, -32602, "Invalid cursor");
        if (cursor_text.len == 0 or cursor_text.len > 20 or
            (cursor_text.len > 1 and cursor_text[0] == '0'))
            return dispatchError(allocator, request_id, -32602, "Invalid cursor");
        for (cursor_text) |digit| {
            if (digit < '0' or digit > '9') return dispatchError(allocator, request_id, -32602, "Invalid cursor");
        }
        const cursor = std.fmt.parseInt(u64, cursor_text, 10) catch return dispatchError(allocator, request_id, -32602, "Invalid cursor");
        var current = jobs.changeCursor();
        var checks: usize = 0;
        while (current == cursor and checks < 25) : (checks += 1) {
            std.Io.sleep(engine.io, std.Io.Duration.fromMilliseconds(200), .awake) catch break;
            current = jobs.changeCursor();
        }
        const next_cursor = try std.fmt.allocPrint(allocator, "{d}", .{current});
        defer allocator.free(next_cursor);
        return try std.json.Stringify.valueAlloc(allocator, .{
            .jsonrpc = "2.0",
            .id = id,
            .result = .{ .cursor = next_cursor, .changed = current != cursor },
        }, .{});
    }
    if (std.mem.eql(u8, method, "settings.get")) {
        const id = request_id orelse return null;
        return @as(?[]u8, try jobs.settingsJson(id));
    }
    if (std.mem.eql(u8, method, "settings.update")) {
        const id = request_id orelse return null;
        const value = params orelse return dispatchError(allocator, request_id, -32602, "Invalid params");
        if (value != .object) return dispatchError(allocator, request_id, -32602, "Invalid params");
        const settings_value = value.object.get("settings") orelse value;
        var parsed = std.json.parseFromValue(job_store.Settings, allocator, settings_value, .{}) catch
            return dispatchError(allocator, request_id, -32602, "Invalid settings");
        defer parsed.deinit();
        const response = jobs.updateSettingsJson(id, parsed.value) catch |err| {
            if (err == error.InvalidSettings) return dispatchError(allocator, request_id, -32602, "Invalid settings");
            return dispatchError(allocator, request_id, -32020, "Could not save settings");
        };
        jobs.logAction("settings.update", "saved");
        scheduleTick(engine);
        return response;
    }
    if (std.mem.eql(u8, method, "torrents.prepare")) {
        const id = request_id orelse return null;
        const value = params orelse return dispatchError(allocator, request_id, -32602, "Invalid params");
        if (value != .object) return dispatchError(allocator, request_id, -32602, "Invalid params");
        const url = stringField(value.object, "url") orelse return dispatchError(allocator, request_id, -32602, "Invalid params");
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var trackers: ?[]const []const u8 = null;
        if (value.object.get("trackers")) |edited| {
            if (edited != .array or edited.array.items.len > 32) return dispatchError(allocator, request_id, -32602, "Use at most 32 tracker URLs");
            const urls = try a.alloc([]const u8, edited.array.items.len);
            for (urls, edited.array.items) |*target, entry| {
                if (entry != .string) return dispatchError(allocator, request_id, -32602, "Invalid tracker URL");
                target.* = entry.string;
            }
            trackers = urls;
        }
        var offset: usize = 0;
        if (value.object.get("offset")) |entry| {
            if (entry != .integer or entry.integer < 0 or entry.integer > 10_000) return dispatchError(allocator, request_id, -32602, "Invalid file offset");
            offset = @intCast(entry.integer);
        }
        const policy = try jobs.copyProxyPolicy();
        defer policy.deinit(jobs.allocator);
        const result = @import("../protocols/torrent/prepare.zig").prepare(a, engine.io, jobs.directory_path, url, trackers, offset, .{ .mode = policy.mode, .url = policy.url, .authentication_required = policy.authentication_required }, &engine.http_connections) catch |err| {
            jobs.logAction("torrents.prepare", @errorName(err));
            const message = if (err == error.UnsupportedTorrentV2)
                "This torrent contains only BitTorrent v2 metadata. Use a v1 or v1-compatible hybrid torrent; v2-only downloads are not supported yet."
            else if (err == error.UnsupportedTorrentVersion)
                "This torrent uses an unsupported metadata version."
            else if (err == error.MetadataTimeout or err == error.Timeout)
                "Torrent discovery timed out. Check your network or trackers and retry."
            else
                try std.fmt.allocPrint(a, "Could not prepare torrent: {s}. Check the source or trackers and try again.", .{@errorName(err)});
            return dispatchError(allocator, request_id, -32021, message);
        };
        jobs.logAction("torrents.prepare", "completed");
        return try std.json.Stringify.valueAlloc(allocator, .{ .jsonrpc = "2.0", .id = id, .result = result }, .{});
    }
    if (std.mem.eql(u8, method, "jobs.probe")) {
        const id = request_id orelse return null;
        const value = params orelse return dispatchError(allocator, request_id, -32602, "Invalid params");
        if (value != .object) return dispatchError(allocator, request_id, -32602, "Invalid params");
        const url = stringField(value.object, "url") orelse return dispatchError(allocator, request_id, -32602, "Invalid params");
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const proxy_policy = jobs.copyProxyPolicy() catch return dispatchError(allocator, request_id, -32020, "Could not read proxy settings");
        defer proxy_policy.deinit(jobs.allocator);
        const probe = if (isTorrentFileUrl(url)) blk: {
            const source = @import("../protocols/torrent/source.zig");
            const torrent = @import("../protocols/torrent/metainfo.zig");
            const path = source.pathAlloc(arena.allocator(), url) catch break :blk error.InvalidTorrentSource;
            const bytes = std.Io.Dir.readFileAlloc(.cwd(), engine.io, path, arena.allocator(), .limited(torrent.max_metainfo_bytes)) catch break :blk error.InvalidTorrentSource;
            const info = torrent.inspect(arena.allocator(), bytes) catch break :blk error.InvalidTorrentSource;
            const map = torrent.inspectFileMap(arena.allocator(), bytes) catch break :blk error.InvalidTorrentSource;
            defer map.deinit(arena.allocator());
            const total = std.fmt.allocPrint(arena.allocator(), "{d}", .{info.total_bytes}) catch break :blk error.OutOfMemory;
            const hash_hex = std.fmt.bytesToHex(info.info_hash, .lower);
            const info_hash = arena.allocator().dupe(u8, &hash_hex) catch break :blk error.OutOfMemory;
            // Reserve ample room for JSON escaping and the rest of the probe
            // envelope so a valid large torrent cannot exceed the IPC frame.
            var preview_count: usize = 0;
            var preview_budget: usize = 0;
            for (map.files) |entry| {
                const cost = entry.path.len * 6 + 128;
                if (preview_count == 1_000 or preview_budget + cost > 128 * 1024) break;
                preview_budget += cost;
                preview_count += 1;
            }
            const files = arena.allocator().alloc(http_probe.Result.TorrentFile, preview_count) catch break :blk error.OutOfMemory;
            for (files, map.files[0..preview_count]) |*preview, entry| {
                preview.* = .{
                    .path = arena.allocator().dupe(u8, entry.path) catch break :blk error.OutOfMemory,
                    .length = std.fmt.allocPrint(arena.allocator(), "{d}", .{entry.length}) catch break :blk error.OutOfMemory,
                };
            }
            const result: http_probe.Result = .{ .final_url = "torrent-file:", .suggested_name = info.name, .total_bytes = total, .status_code = 0, .http_version = "BitTorrent", .content_type = "application/x-bittorrent", .range_supported = false, .resume_supported = true, .multipart_supported = false, .message = "Torrent file accepted. The engine verifies each piece and resumes verified pieces.", .torrent_file_count = @intCast(map.files.len), .torrent_files = files, .torrent_info_hash = info_hash };
            break :blk result;
        } else if (isMagnetUrl(url)) blk: {
            var link = @import("../protocols/torrent/magnet.zig").inspect(arena.allocator(), url) catch break :blk error.InvalidMagnetUri;
            defer link.deinit(arena.allocator());
            const suggested = if (link.display_name) |name| if (@import("../protocols/torrent/metainfo.zig").safeComponent(name)) name else "torrent-download" else "torrent-download";
            const result: http_probe.Result = .{ .final_url = url, .suggested_name = suggested, .total_bytes = null, .status_code = 0, .http_version = "BitTorrent", .content_type = "application/x-bittorrent", .range_supported = false, .resume_supported = true, .multipart_supported = false, .message = "Magnet link accepted. The engine will retrieve metadata and verify each piece when the download starts." };
            break :blk result;
        } else if (isFtpUrl(url)) blk: {
            if (proxy_policy.mode == .custom) break :blk error.UnsupportedFtpProxy;
            break :blk @import("../protocols/ftp/download.zig").inspect(arena.allocator(), engine.io, url);
        } else http_probe.inspectWithPolicyAndBudget(arena.allocator(), engine.io, url, .{ .mode = proxy_policy.mode, .url = proxy_policy.url, .authentication_required = proxy_policy.authentication_required }, &engine.http_connections);
        const result = probe catch |err| {
            jobs.logAction("jobs.probe", @errorName(err));
            const message: []const u8 = if (err == error.InvalidUrl or err == error.UnsupportedScheme)
                "Enter a valid HTTP, HTTPS, FTP, FTPS, or magnet link."
            else if (err == error.ServerBusy)
                "The server is temporarily busy or rate limiting requests. Wait before inspecting this link again."
            else if (err == error.ConnectionBudgetBusy)
                "Too many connections are open to this host. Try inspecting the link again shortly."
            else if (err == error.ProxyAuthenticationUnavailable)
                "Authenticated proxy transfers are not available in this engine version. Turn off proxy authentication or use an unauthenticated proxy."
            else if (err == error.ProxyCredentialsUnavailable)
                "Proxy credentials could not be read from your Keychain. Save the username and password again in Proxy settings."
            else if (err == error.AuthenticatedHttpsProxyUnsupported)
                "Authenticated proxies cannot yet inspect HTTPS links because the HTTP transport cannot authorize CONNECT requests."
            else if (err == error.InsecureHttpRedirect)
                "This link redirects from HTTPS to HTTP. Use a secure final URL or contact the source site."
            else if (err == error.HttpRedirectCredentials)
                "The redirect contains URL credentials and was rejected."
            else
                try std.fmt.allocPrint(arena.allocator(), "URL probe failed in the engine: {s}", .{@errorName(err)});
            return dispatchError(allocator, request_id, -32021, message);
        };
        jobs.logAction("jobs.probe", "completed");
        return @as(?[]u8, try std.json.Stringify.valueAlloc(allocator, .{
            .jsonrpc = "2.0",
            .id = id,
            .result = result,
        }, .{}));
    }
    if (std.mem.eql(u8, method, "jobs.control")) {
        const control = parseJobControl(params) catch return dispatchError(allocator, request_id, -32602, "Invalid params");
        const id = request_id orelse return null;
        if (control.action == .start) return startDownload(allocator, id, control, engine);
        if ((control.action == .pause or control.action == .cancel) and jobs.isDownloading(control.job_id)) {
            const stop_action: job_store.StopAction = if (control.action == .pause) .pause else .cancel;
            const response = jobs.requestStopJson(id, control.job_id, stop_action, control.expected_revision) catch |err| {
                if (err == error.JobNotFound) return dispatchError(allocator, request_id, -32012, "Download job not found");
                if (err == error.InvalidJobControl) return dispatchError(allocator, request_id, -32013, "Action is not valid for this job state");
                if (err == error.StaleJobRevision) return dispatchError(allocator, request_id, -32015, "Job revision is stale; refresh the job before retrying");
                return dispatchError(allocator, request_id, -32020, "Could not save the download request");
            };
            return @as(?[]u8, response);
        }
        const response = jobs.controlJson(id, control.job_id, control.action, control.expected_revision) catch |err| {
            if (err == error.JobNotFound) return dispatchError(allocator, request_id, -32012, "Download job not found");
            if (err == error.InvalidJobControl) return dispatchError(allocator, request_id, -32013, "Action is not valid for this job state");
            if (err == error.StaleJobRevision) return dispatchError(allocator, request_id, -32015, "Job revision is stale; refresh the job before retrying");
            return dispatchError(allocator, request_id, -32020, "Could not save the download request");
        };
        if (control.action == .retry) scheduleQueued(engine);
        return @as(?[]u8, response);
    }
    if (std.mem.eql(u8, method, "jobs.resume-queue")) {
        const id = request_id orelse return null;
        if (params) |value| {
            if (value != .object or value.object.count() != 0) return dispatchError(allocator, request_id, -32602, "Invalid params");
        }
        const response = jobs.resumeQueueJson(id) catch return dispatchError(allocator, request_id, -32020, "Could not resume the queue");
        scheduleQueued(engine);
        return response;
    }
    if (std.mem.eql(u8, method, "jobs.replace-source")) {
        const id = request_id orelse return null;
        const value = params orelse return dispatchError(allocator, request_id, -32602, "Invalid params");
        if (value != .object) return dispatchError(allocator, request_id, -32602, "Invalid params");
        const job_id = stringField(value.object, "job_id") orelse return dispatchError(allocator, request_id, -32602, "Invalid params");
        const url = stringField(value.object, "url") orelse return dispatchError(allocator, request_id, -32602, "Invalid params");
        const revision_text = stringField(value.object, "expected_revision") orelse return dispatchError(allocator, request_id, -32602, "Invalid params");
        const revision = std.fmt.parseInt(u64, revision_text, 10) catch return dispatchError(allocator, request_id, -32602, "Invalid params");
        const restart = value.object.get("restart") orelse return dispatchError(allocator, request_id, -32602, "Confirm restart before replacing a link");
        if (restart != .bool or !restart.bool) return dispatchError(allocator, request_id, -32602, "Confirm restart before replacing a link");
        const response = jobs.replaceSourceJson(id, job_id, revision, url) catch |err| {
            if (err == error.JobNotFound) return dispatchError(allocator, request_id, -32012, "Download job not found");
            if (err == error.StaleJobRevision) return dispatchError(allocator, request_id, -32015, "Job changed; review its current state before replacing the link");
            if (err == error.InvalidJobControl) return dispatchError(allocator, request_id, -32013, "Pause the HTTP download before replacing its link");
            if (err == error.DestinationReserved or err == error.DestinationExists) return dispatchError(allocator, request_id, -32020, "The destination is already present or belongs to another download");
            return dispatchError(allocator, request_id, -32020, "Could not replace the download link");
        };
        scheduleQueued(engine);
        return response;
    }
    if (std.mem.eql(u8, method, "jobs.set-bandwidth")) {
        const value = params orelse return dispatchError(allocator, request_id, -32602, "Invalid params");
        if (value != .object) return dispatchError(allocator, request_id, -32602, "Invalid params");
        const job_id = stringField(value.object, "job_id") orelse return dispatchError(allocator, request_id, -32602, "Invalid params");
        const revision_text = stringField(value.object, "expected_revision") orelse return dispatchError(allocator, request_id, -32602, "Invalid params");
        const revision = std.fmt.parseInt(u64, revision_text, 10) catch return dispatchError(allocator, request_id, -32602, "Invalid params");
        const limit_value = value.object.get("bandwidth_limit_bytes_per_second") orelse return dispatchError(allocator, request_id, -32602, "Invalid params");
        if (limit_value != .integer or limit_value.integer < 0 or limit_value.integer > 1_000_000_000_000)
            return dispatchError(allocator, request_id, -32602, "Invalid bandwidth limit");
        const id = request_id orelse return null;
        return jobs.setBandwidthLimitJson(id, job_id, revision, @intCast(limit_value.integer)) catch |err| {
            if (err == error.JobNotFound) return dispatchError(allocator, request_id, -32012, "Download job not found");
            if (err == error.StaleJobRevision) return dispatchError(allocator, request_id, -32015, "Job revision is stale; refresh the job before retrying");
            return dispatchError(allocator, request_id, -32020, "Could not save the download limit");
        };
    }
    if (std.mem.eql(u8, method, "jobs.reorder")) {
        const input = parseJobReorder(params) catch return dispatchError(allocator, request_id, -32602, "Invalid params");
        const id = request_id orelse return null;
        return jobs.reorderJson(id, input.job_id, input.position, input.expected_revision) catch |err| {
            if (err == error.JobNotFound) return dispatchError(allocator, request_id, -32012, "Download job not found");
            if (err == error.InvalidJobControl) return dispatchError(allocator, request_id, -32013, "Only queued or paused jobs can be reordered");
            if (err == error.InvalidQueuePosition) return dispatchError(allocator, request_id, -32018, "Queue position is out of range");
            if (err == error.StaleJobRevision) return dispatchError(allocator, request_id, -32015, "Job revision is stale; refresh the job before retrying");
            return dispatchError(allocator, request_id, -32020, "Could not save the download request");
        };
    }
    if (std.mem.eql(u8, method, "jobs.delete")) {
        const input = parseJobDelete(params) catch return dispatchError(allocator, request_id, -32602, "Invalid params");
        const id = request_id orelse return null;
        return jobs.deleteJson(id, input.job_id, input.expected_revision, input.delete_partial) catch |err| {
            if (err == error.JobNotFound) return dispatchError(allocator, request_id, -32012, "Download job not found");
            if (err == error.InvalidJobControl) return dispatchError(allocator, request_id, -32017, "An active job cannot be deleted");
            if (err == error.StaleJobRevision) return dispatchError(allocator, request_id, -32015, "Job revision is stale; refresh the job before retrying");
            return dispatchError(allocator, request_id, -32020, "Could not save the download request");
        };
    }
    if (!std.mem.eql(u8, method, "jobs.add")) return null;

    const input = parseAddInput(allocator, params orelse return dispatchError(allocator, request_id, -32602, "Invalid params")) catch {
        return dispatchError(allocator, request_id, -32602, "Invalid params");
    };
    defer if (input.selected_torrent_files) |files| allocator.free(files);
    const id = request_id orelse return null;
    const response = jobs.addJson(id, input) catch |err| {
        if (request_id == null) return null;
        if (err == error.InvalidJob) return dispatchError(allocator, request_id, -32010, "Invalid download request");
        if (err == error.TorrentSourceChanged) return dispatchError(allocator, request_id, -32022, "The torrent file changed since inspection. Inspect it again before adding the download");
        if (err == error.InvalidDestination) return dispatchError(allocator, request_id, -32014, "Destination must be an existing writable directory");
        if (err == error.DestinationExists) return dispatchError(allocator, request_id, -32018, "A file with this name already exists in the destination folder");
        if (err == error.DestinationReserved) return dispatchError(allocator, request_id, -32018, "Another download already uses this destination and filename");
        if (err == error.IdempotencyConflict) return dispatchError(allocator, request_id, -32011, "Idempotency key was already used for another request");
        return dispatchError(allocator, request_id, -32020, "Could not save the download request");
    };
    scheduleTick(engine);
    return response;
}

fn loggedMethod(method: []const u8) []const u8 {
    inline for (.{ "engine.status", "jobs.list", "jobs.get", "jobs.wait", "jobs.subscribe", "jobs.add", "jobs.probe", "torrents.prepare", "jobs.control", "jobs.set-bandwidth", "jobs.replace-source", "jobs.resume-queue", "jobs.reorder", "jobs.delete", "settings.get", "settings.update" }) |known| {
        if (std.mem.eql(u8, method, known)) return known;
    }
    return "unknown-method";
}

fn startDownload(allocator: std.mem.Allocator, request_id: std.json.Value, control: JobControl, engine: *EngineContext) anyerror!?[]u8 {
    if (!queueWindowOpen(engine))
        return dispatchError(allocator, request_id, -32019, "The queue is outside its scheduled hours");
    if (!reserveWorker(engine))
        return dispatchError(allocator, request_id, -32016, "Another download is already active");

    const response = engine.jobs.controlJson(request_id, control.job_id, .start, control.expected_revision) catch |err| {
        releaseWorker(engine);
        if (err == error.JobNotFound) return dispatchError(allocator, request_id, -32012, "Download job not found");
        if (err == error.InvalidJobControl) return dispatchError(allocator, request_id, -32013, "Action is not valid for this job state");
        if (err == error.HostLimitReached) return dispatchError(allocator, request_id, -32016, "This host already has the maximum number of active downloads");
        if (err == error.DestinationReserved) return dispatchError(allocator, request_id, -32018, "Another active download uses this destination and filename");
        if (err == error.StaleJobRevision) return dispatchError(allocator, request_id, -32015, "Job revision is stale; refresh the job before retrying");
        return dispatchError(allocator, request_id, -32020, "Could not save the download request");
    };
    const task = engine.jobs.copyDownloadTask(control.job_id) catch |err| {
        engine.jobs.finishDownload(control.job_id, false, "Could not prepare the download") catch {};
        releaseWorker(engine);
        allocator.free(response);
        return dispatchError(allocator, request_id, if (err == error.JobNotFound) -32012 else -32020, "Could not prepare the download");
    };
    launchWorker(engine, task) catch {
        allocator.free(response);
        return dispatchError(allocator, request_id, -32020, "Could not start the download worker");
    };
    scheduleQueued(engine);
    return response;
}

fn runDownloadWorker(engine: *EngineContext, task: job_store.Store.DownloadTask) void {
    engine.jobs.logAction("transfer", "started");
    defer task.deinit(engine.allocator);
    defer {
        releaseWorker(engine);
        scheduleQueued(engine);
    }
    const destination = buildDestination(engine.allocator, task) catch {
        engine.jobs.logAction("transfer", "invalid-destination");
        engine.jobs.finishDownload(task.id, false, "Could not create a safe destination path") catch {};
        return;
    };
    defer engine.allocator.free(destination);

    var retry_hint: @import("../protocols/http/retry_after.zig").Hint = .init(0);
    var progress = DownloadProgressContext{ .engine = engine, .job_id = task.id, .retry_hint = &retry_hint };
    if (isTorrentFileUrl(task.url) or isMagnetUrl(task.url)) engine.jobs.resetTorrentStats(task.id);
    const transfer = if (isTorrentFileUrl(task.url)) blk: {
        if (task.proxy_mode == .custom) break :blk error.UnsupportedTorrentProxy;
        break :blk downloadStoredTorrent(engine, task, destination, &progress);
    } else if (isMagnetUrl(task.url)) blk: {
        if (task.proxy_mode == .custom) break :blk error.UnsupportedTorrentProxy;
        break :blk @import("../protocols/torrent/download.zig").downloadWithStats(engine.allocator, engine.io, task.url, destination, task.expected_sha256, updateDownloadProgress, @ptrCast(&progress), checkTorrentControl, @ptrCast(&progress), updateTorrentStats, @ptrCast(&progress));
    } else if (isFtpUrl(task.url)) blk: {
        if (task.proxy_mode == .custom) break :blk error.UnsupportedFtpProxy;
        break :blk @import("../protocols/ftp/download.zig").downloadWithControl(engine.allocator, engine.io, task.url, destination, task.expected_sha256, updateDownloadProgress, @ptrCast(&progress), checkHttpControl, @ptrCast(&progress));
    } else @import("../protocols/http/download.zig").downloadWithPolicyAndBudget(engine.allocator, engine.io, task.url, destination, task.expected_sha256, updateDownloadProgress, @ptrCast(&progress), updateWorkerProgress, task.connections, .{ .mode = task.proxy_mode, .url = task.proxy_url, .authentication_required = task.proxy_authentication_required }, &retry_hint, &engine.http_connections, checkHttpControl);
    transfer catch |err| {
        if (engine.jobs.requestedControl(task.id)) |control| {
            engine.jobs.logAction("transfer", if (control == .pause) "paused" else "canceled");
            if (control == .cancel) deletePartial(engine, destination);
            engine.jobs.finishStoppedDownload(task.id, if (control == .pause) .paused else .canceled) catch {};
            return;
        }
        if (err == error.TransferSchedulePaused) {
            engine.jobs.logAction("transfer", "scheduled");
            engine.jobs.finishScheduledDownload(task.id) catch {};
            return;
        }
        if (retryableDownloadError(err)) {
            engine.jobs.logAction("transfer.retry", @errorName(err));
            if (engine.jobs.scheduleTransientRetry(task.id, @errorName(err), retry_hint.load(.acquire), if (err == error.ServerBusy or err == error.ParallelRangeRejected) task.connections else null) catch false) {
                engine.jobs.logAction("transfer", "retry-scheduled");
                return;
            }
        }
        const error_message = if (err == error.ExpectedChecksumMismatch)
            "SHA-256 checksum does not match the downloaded file"
        else if (err == error.ProxyAuthenticationUnavailable)
            "Authenticated proxy transfers are not available in this engine version"
        else if (err == error.ProxyCredentialsUnavailable)
            "Proxy credentials could not be read from Keychain. Save them again in Proxy settings."
        else if (err == error.AuthenticatedHttpsProxyUnsupported)
            "Authenticated proxies cannot yet download HTTPS links because the HTTP transport cannot authorize CONNECT requests."
        else if (err == error.FtpJournalUpgradeRequired)
            "This FTP partial uses an older journal format and cannot be resumed safely. Remove the partial and add the download again."
        else if (err == error.HttpJournalUpgradeRequired)
            "This HTTP partial uses an older journal format and cannot be resumed safely. Remove the partial and add the download again."
        else if (err == error.JournalUpgradeRequired)
            "This multipart HTTP partial uses an older journal format and cannot be resumed safely. Remove the partial and add the download again."
        else if (err == error.PartialFileLengthMismatch)
            "The multipart partial file size no longer matches the saved download. The partial was preserved; remove it and add the download again."
        else if (err == error.RepresentationChanged)
            "The server changed the file or ignored the resume range. The saved partial was preserved; remove it to start a fresh download."
        else if (err == error.InsecureHttpRedirect)
            "The source redirected from HTTPS to HTTP. The download was stopped before contacting the insecure destination."
        else if (err == error.HttpRedirectCredentials)
            "The source redirected to a URL with credentials. The download was stopped."
        else
            std.fmt.allocPrint(engine.allocator, "Download failed: {s}", .{@errorName(err)}) catch "Download failed";
        engine.jobs.logAction("transfer", @errorName(err));
        defer if (err != error.ExpectedChecksumMismatch and err != error.ProxyAuthenticationUnavailable and err != error.ProxyCredentialsUnavailable and err != error.AuthenticatedHttpsProxyUnsupported and err != error.FtpJournalUpgradeRequired and err != error.HttpJournalUpgradeRequired and err != error.JournalUpgradeRequired and err != error.PartialFileLengthMismatch and err != error.RepresentationChanged and err != error.InsecureHttpRedirect and err != error.HttpRedirectCredentials and !std.mem.eql(u8, error_message, "Download failed")) engine.allocator.free(error_message);
        engine.jobs.finishDownload(task.id, false, error_message) catch {};
        return;
    };
    engine.jobs.finishDownload(task.id, true, null) catch {};
    engine.jobs.logAction("transfer", "completed");
}

fn downloadStoredTorrent(engine: *EngineContext, task: job_store.Store.DownloadTask, destination: []const u8, progress: *DownloadProgressContext) !void {
    const snapshot = try engine.jobs.torrentSnapshotPath(engine.allocator, task.id);
    defer engine.allocator.free(snapshot);
    const exists = if (std.Io.Dir.cwd().statFile(engine.io, snapshot, .{})) |_| true else |err| switch (err) {
        error.FileNotFound => false,
        else => return err,
    };
    if (exists) {
        return @import("../protocols/torrent/download.zig").downloadTorrentFileSelectedWithStats(engine.allocator, engine.io, snapshot, destination, task.expected_sha256, task.selected_torrent_files, updateDownloadProgress, @ptrCast(progress), checkTorrentControl, @ptrCast(progress), updateTorrentStats, @ptrCast(progress));
    }
    // Jobs queued before source snapshots were introduced can still resume
    // from the original selected file when it remains available.
    if (task.selected_torrent_files != null) return error.MissingTorrentSnapshot;
    return @import("../protocols/torrent/download.zig").downloadTorrentSourceWithStats(engine.allocator, engine.io, task.url, destination, task.expected_sha256, updateDownloadProgress, @ptrCast(progress), checkTorrentControl, @ptrCast(progress), updateTorrentStats, @ptrCast(progress));
}

fn checkTorrentControl(context: *anyopaque) @import("../protocols/torrent/metadata.zig").CheckpointError!void {
    const progress: *DownloadProgressContext = @ptrCast(@alignCast(context));
    if (progress.engine.jobs.requestedControl(progress.job_id)) |control|
        return if (control == .pause) error.TransferPauseRequested else error.TransferCancelRequested;
    if (!queueWindowOpen(progress.engine)) return error.TransferSchedulePaused;
}

fn checkHttpControl(context: *anyopaque) anyerror!void {
    const progress: *DownloadProgressContext = @ptrCast(@alignCast(context));
    if (progress.engine.jobs.requestedControl(progress.job_id)) |control|
        return if (control == .pause) error.TransferPauseRequested else error.TransferCancelRequested;
    if (!queueWindowOpen(progress.engine)) return error.TransferSchedulePaused;
}

fn updateTorrentStats(context: *anyopaque, peers: u32, counts: @import("../protocols/torrent/metadata.zig").TrackerCounts) void {
    const progress: *DownloadProgressContext = @ptrCast(@alignCast(context));
    if (counts.retry_delay_seconds) |seconds| {
        const hint = progress.retry_hint orelse unreachable;
        const current = hint.load(.acquire);
        if (seconds > current) hint.store(seconds, .release);
    }
    progress.engine.jobs.updateTorrentStats(progress.job_id, peers, counts.seeders, counts.leechers);
}

fn retryableDownloadError(err: anyerror) bool {
    return switch (err) {
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.Timeout,
        error.ConnectionRefused,
        error.NetworkUnreachable,
        error.HostUnreachable,
        error.BrokenPipe,
        error.EndOfStream,
        error.ResponseLengthMismatch,
        error.SegmentLengthMismatch,
        error.FtpControlReadFailed,
        error.FtpControlReadTimedOut,
        error.FtpControlClosed,
        error.FtpDataReadFailed,
        error.FtpDataReadTimedOut,
        error.FtpsHandshakeTimedOut,
        error.FtpTransferIncomplete,
        error.FtpServerBusy,
        error.NoReachablePeer,
        error.NoTrackerPeers,
        error.TrackerRetryRequested,
        error.NoTorrentPeers,
        error.NoPeerHasPieces,
        error.PeerMissingPieces,
        error.PeerMetadataUnavailable,
        error.MetadataPieceUnavailable,
        error.PeerClosed,
        error.PeerChoked,
        error.PeerPieceUnavailable,
        error.MetadataPieceRejected,
        error.ParallelRangeRejected,
        error.ServerBusy,
        => true,
        else => false,
    };
}

fn isFtpUrl(url: []const u8) bool {
    const uri = std.Uri.parse(url) catch return false;
    return std.ascii.eqlIgnoreCase(uri.scheme, "ftp") or std.ascii.eqlIgnoreCase(uri.scheme, "ftps");
}

fn isMagnetUrl(url: []const u8) bool {
    return url.len >= 7 and std.ascii.eqlIgnoreCase(url[0..7], "magnet:");
}

fn isTorrentFileUrl(url: []const u8) bool {
    return @import("../protocols/torrent/source.zig").isLocalTorrent(url);
}

fn updateWorkerProgress(context: *anyopaque, worker_id: u32, start: u64, end: u64, downloaded: u64) anyerror!void {
    const progress: *DownloadProgressContext = @ptrCast(@alignCast(context));
    if (progress.engine.jobs.requestedControl(progress.job_id)) |control| {
        return if (control == .pause) error.TransferPauseRequested else error.TransferCancelRequested;
    }
    if (!queueWindowOpen(progress.engine)) return error.TransferSchedulePaused;
    if (worker_id >= 1 and worker_id <= progress.worker_downloaded.len) {
        progress.progress_mutex.lockUncancelable(progress.engine.io);
        const index: usize = @intCast(worker_id - 1);
        if (!progress.worker_known[index] or progress.worker_start[index] != start or progress.worker_end[index] != end) {
            progress.worker_downloaded[index] = 0;
            progress.worker_start[index] = start;
            progress.worker_end[index] = end;
            progress.worker_known[index] = true;
        }
        const delta = downloaded -| progress.worker_downloaded[index];
        progress.worker_downloaded[index] = downloaded;
        progress.worker_updates_seen = true;
        progress.progress_mutex.unlock(progress.engine.io);
        try throttleBytes(progress, delta);
    }
    progress.engine.jobs.updateWorkerProgress(progress.job_id, worker_id, start, end, downloaded);
}

fn reserveWorker(engine: *EngineContext) bool {
    while (true) {
        const active = engine.active_workers.load(.acquire);
        if (active >= engine.jobs.runtimePolicy().max_concurrent_tasks) return false;
        if (engine.active_workers.cmpxchgWeak(active, active + 1, .acquire, .monotonic) == null) return true;
    }
}

fn releaseWorker(engine: *EngineContext) void {
    _ = engine.active_workers.fetchSub(1, .release);
}

fn launchWorker(engine: *EngineContext, task: job_store.Store.DownloadTask) !void {
    var thread = std.Thread.spawn(.{}, runDownloadWorker, .{ engine, task }) catch |err| {
        engine.jobs.finishDownload(task.id, false, "Worker thread could not be started") catch {};
        task.deinit(engine.allocator);
        releaseWorker(engine);
        return err;
    };
    thread.detach();
}

fn scheduleQueued(engine: *EngineContext) void {
    if (!queueWindowOpen(engine)) return;
    while (reserveWorker(engine)) {
        const task = engine.jobs.startNextQueued() catch {
            releaseWorker(engine);
            return;
        } orelse {
            releaseWorker(engine);
            return;
        };
        launchWorker(engine, task) catch {
            // The job was failed durably before launchWorker returned.
            continue;
        };
    }
}

fn deletePartial(engine: *EngineContext, destination: []const u8) void {
    const part_path = std.fmt.allocPrint(engine.allocator, "{s}.part", .{destination}) catch return;
    defer engine.allocator.free(part_path);
    const journal_path = std.fmt.allocPrint(engine.allocator, "{s}.odm", .{part_path}) catch return;
    defer engine.allocator.free(journal_path);
    const segment_journal_path = std.fmt.allocPrint(engine.allocator, "{s}.sdr", .{part_path}) catch return;
    defer engine.allocator.free(segment_journal_path);
    const ftp_journal_path = std.fmt.allocPrint(engine.allocator, "{s}.ftpj", .{part_path}) catch return;
    defer engine.allocator.free(ftp_journal_path);
    const cwd = std.Io.Dir.cwd();
    cwd.deleteFile(engine.io, part_path) catch {};
    cwd.deleteFile(engine.io, journal_path) catch {};
    cwd.deleteFile(engine.io, segment_journal_path) catch {};
    cwd.deleteFile(engine.io, ftp_journal_path) catch {};
}

const DownloadProgressContext = struct {
    engine: *EngineContext,
    job_id: []const u8,
    retry_hint: ?*@import("../protocols/http/retry_after.zig").Hint = null,
    progress_mutex: std.Io.Mutex = .init,
    worker_updates_seen: bool = false,
    worker_downloaded: [32]u64 = @splat(0),
    worker_start: [32]u64 = @splat(0),
    worker_end: [32]u64 = @splat(0),
    worker_known: [32]bool = @splat(false),
    single_reported: ?u64 = null,
    bandwidth_current_limit: u64 = 0,
    bandwidth_next_ns: i96 = 0,
};

fn updateDownloadProgress(context: *anyopaque, completed: u64, total: ?u64, durable: bool) anyerror!void {
    const progress: *DownloadProgressContext = @ptrCast(@alignCast(context));
    if (progress.engine.jobs.requestedControl(progress.job_id)) |control| {
        if (durable) try progress.engine.jobs.updateProgress(progress.job_id, completed, total, true);
        return if (control == .pause) error.TransferPauseRequested else error.TransferCancelRequested;
    }
    if (!queueWindowOpen(progress.engine)) {
        if (durable) try progress.engine.jobs.updateProgress(progress.job_id, completed, total, true);
        return error.TransferSchedulePaused;
    }
    progress.progress_mutex.lockUncancelable(progress.engine.io);
    const single_stream = !progress.worker_updates_seen;
    const delta = if (!single_stream) @as(u64, 0) else if (progress.single_reported) |previous| completed -| previous else @as(u64, 0);
    progress.single_reported = completed;
    progress.progress_mutex.unlock(progress.engine.io);
    try throttleBytes(progress, delta);
    try progress.engine.jobs.updateProgress(progress.job_id, completed, total, durable);
    if (single_stream) if (total) |known_total| {
        progress.engine.jobs.updateWorkerProgress(progress.job_id, 1, 0, known_total, completed);
    };
}

fn throttleBytes(progress: *DownloadProgressContext, bytes: u64) !void {
    if (bytes == 0) return;
    const engine = progress.engine;
    const policy = engine.jobs.runtimePolicy();
    const slot = localWeekSlot() orelse if (policy.bandwidth_schedule_enabled) return error.LocalTimeUnavailable else 0;
    var global_limit = policy.downloadLimit(slot);
    var job_limit = engine.jobs.jobBandwidthLimit(progress.job_id);
    const now_ns = std.Io.Clock.now(.awake, engine.io).nanoseconds;
    engine.bandwidth_mutex.lockUncancelable(engine.io);
    var global_deadline = reserveBandwidth(&engine.bandwidth_next_ns, &engine.bandwidth_current_limit, global_limit, bytes, now_ns);
    engine.bandwidth_mutex.unlock(engine.io);
    progress.progress_mutex.lockUncancelable(engine.io);
    var job_deadline = reserveBandwidth(&progress.bandwidth_next_ns, &progress.bandwidth_current_limit, job_limit, bytes, now_ns);
    progress.progress_mutex.unlock(engine.io);
    // A low limit can put the deadline minutes ahead. Wake regularly so a
    // paused or canceled worker stops promptly and live limit changes apply.
    while (true) {
        try checkHttpControl(@ptrCast(progress));
        const current_ns = std.Io.Clock.now(.awake, engine.io).nanoseconds;
        const current_policy = engine.jobs.runtimePolicy();
        const current_slot = localWeekSlot() orelse if (current_policy.bandwidth_schedule_enabled) return error.LocalTimeUnavailable else 0;
        const current_global_limit = current_policy.downloadLimit(current_slot);
        if (current_global_limit != global_limit) {
            engine.bandwidth_mutex.lockUncancelable(engine.io);
            global_deadline = reserveBandwidth(&engine.bandwidth_next_ns, &engine.bandwidth_current_limit, current_global_limit, bytes, current_ns);
            engine.bandwidth_mutex.unlock(engine.io);
            global_limit = current_global_limit;
        }
        const current_job_limit = engine.jobs.jobBandwidthLimit(progress.job_id);
        if (current_job_limit != job_limit) {
            progress.progress_mutex.lockUncancelable(engine.io);
            job_deadline = reserveBandwidth(&progress.bandwidth_next_ns, &progress.bandwidth_current_limit, current_job_limit, bytes, current_ns);
            progress.progress_mutex.unlock(engine.io);
            job_limit = current_job_limit;
        }
        const deadline_ns = @max(global_deadline, job_deadline);
        if (current_ns >= deadline_ns) break;
        const next_ns = @min(deadline_ns, current_ns + 100 * std.time.ns_per_ms);
        try (std.Io.Timestamp.fromNanoseconds(next_ns).withClock(.awake)).wait(engine.io);
    }
}

fn reserveBandwidth(next_ns: *i96, current_limit: *u64, limit: u64, bytes: u64, now_ns: i96) i96 {
    if (limit == 0 or current_limit.* != limit) {
        current_limit.* = limit;
        next_ns.* = now_ns;
    }
    if (limit == 0) return now_ns;
    const start_ns = @max(now_ns, next_ns.*);
    const duration_ns = @divTrunc(@as(i96, bytes) * std.time.ns_per_s + @as(i96, limit) - 1, @as(i96, limit));
    next_ns.* = start_ns + duration_ns;
    return next_ns.*;
}

fn localWeekSlot() ?usize {
    if (comptime builtin.os.tag == .windows) {
        var local: WindowsSystemTime = undefined;
        GetLocalTime(&local);
        if (local.day_of_week > 6 or local.hour > 23) return null;
        return @as(usize, local.day_of_week) * 24 + @as(usize, local.hour);
    } else {
        var now: c.time_t = 0;
        if (time(&now) == -1) return null;
        var local: LocalTime = undefined;
        if (localtime_r(&now, &local) == null) return null;
        if (local.tm_wday < 0 or local.tm_wday > 6 or local.tm_hour < 0 or local.tm_hour > 23) return null;
        return @as(usize, @intCast(local.tm_wday)) * 24 + @as(usize, @intCast(local.tm_hour));
    }
}

fn queueWindowOpen(engine: *EngineContext) bool {
    const policy = engine.jobs.runtimePolicy();
    if (!policy.queue_schedule_enabled) return true;
    return policy.queueActive(localWeekSlot() orelse return false);
}

fn scheduleTick(engine: *EngineContext) void {
    engine.jobs.promoteDueRetries() catch return;
    const active = queueWindowOpen(engine);
    const previous = engine.last_queue_window.swap(if (active) 1 else 0, .acq_rel);
    if (previous != (if (active) @as(i8, 1) else 0))
        engine.jobs.logAction("queue-window", if (active) "active" else "off");
    engine.jobs.applyQueueWindow(active) catch return;
    if (active) scheduleQueued(engine);
}

fn schedulerLoop(engine: *EngineContext) void {
    while (true) {
        std.Io.sleep(engine.io, std.Io.Duration.fromSeconds(5), .awake) catch {};
        scheduleTick(engine);
    }
}

fn buildDestination(allocator: std.mem.Allocator, task: job_store.Store.DownloadTask) ![]u8 {
    var filename: []const u8 = undefined;
    if (task.name) |name| {
        filename = name;
    } else if (isMagnetUrl(task.url)) {
        var link = try @import("../protocols/torrent/magnet.zig").inspect(allocator, task.url);
        defer link.deinit(allocator);
        if (link.display_name) |name| {
            if (@import("../protocols/torrent/metainfo.zig").safeComponent(name)) return std.fs.path.join(allocator, &.{ task.destination, name });
        }
        var fallback: [48]u8 = undefined;
        const name = try std.fmt.bufPrint(&fallback, "torrent-{s}.download", .{task.id[0..8]});
        return std.fs.path.join(allocator, &.{ task.destination, name });
    } else {
        const uri = try std.Uri.parse(task.url);
        const raw_path = switch (uri.path) {
            .raw => |value| value,
            .percent_encoded => |value| value,
        };
        const last_slash = std.mem.lastIndexOfScalar(u8, raw_path, '/');
        const candidate = if (last_slash) |index| raw_path[index + 1 ..] else raw_path;
        if (candidate.len > 0 and !std.mem.eql(u8, candidate, ".") and !std.mem.eql(u8, candidate, "..") and
            std.mem.indexOfAny(u8, candidate, "/\\\x00") == null)
        {
            filename = candidate;
        } else {
            var fallback: [48]u8 = undefined;
            filename = try std.fmt.bufPrint(&fallback, "download-{s}.bin", .{task.id[0..8]});
        }
    }
    return std.fs.path.join(allocator, &.{ task.destination, filename });
}

const JobControl = struct { job_id: []const u8, action: job_store.Store.Action, expected_revision: u64 };

const JobReorder = struct { job_id: []const u8, position: usize, expected_revision: u64 };

fn parseJobReorder(params: ?std.json.Value) !JobReorder {
    const value = params orelse return error.InvalidParams;
    if (value != .object) return error.InvalidParams;
    const job_id = stringField(value.object, "job_id") orelse return error.InvalidParams;
    const revision_text = stringField(value.object, "expected_revision") orelse return error.InvalidParams;
    const position_value = value.object.get("position") orelse return error.InvalidParams;
    if (position_value != .integer or position_value.integer < 0) return error.InvalidParams;
    return .{
        .job_id = job_id,
        .position = std.math.cast(usize, position_value.integer) orelse return error.InvalidParams,
        .expected_revision = try std.fmt.parseInt(u64, revision_text, 10),
    };
}

const JobDelete = struct { job_id: []const u8, expected_revision: u64, delete_partial: bool = false };

fn parseJobDelete(params: ?std.json.Value) !JobDelete {
    const value = params orelse return error.InvalidParams;
    if (value != .object) return error.InvalidParams;
    const job_id = stringField(value.object, "job_id") orelse return error.InvalidParams;
    const revision_text = stringField(value.object, "expected_revision") orelse return error.InvalidParams;
    const partial_value = value.object.get("delete_partial");
    const delete_partial = if (partial_value) |flag| blk: {
        if (flag != .bool) return error.InvalidParams;
        break :blk flag.bool;
    } else false;
    return .{ .job_id = job_id, .expected_revision = try std.fmt.parseInt(u64, revision_text, 10), .delete_partial = delete_partial };
}

fn parseJobControl(params: ?std.json.Value) !JobControl {
    const value = params orelse return error.InvalidParams;
    if (value != .object) return error.InvalidParams;
    const job_id = stringField(value.object, "job_id") orelse return error.InvalidParams;
    const action_text = stringField(value.object, "action") orelse return error.InvalidParams;
    const revision_text = stringField(value.object, "expected_revision") orelse return error.InvalidParams;
    const action = std.meta.stringToEnum(job_store.Store.Action, action_text) orelse return error.InvalidParams;
    const expected_revision = try std.fmt.parseInt(u64, revision_text, 10);
    return .{ .job_id = job_id, .action = action, .expected_revision = expected_revision };
}

const ListPage = struct { offset: usize = 0, limit: usize = 50, state: ?job_store.State = null, search: ?[]const u8 = null };

fn parseListPage(params: ?std.json.Value) !ListPage {
    const value = params orelse return .{};
    if (value != .object) return error.InvalidParams;
    if (value.object.count() > 4) return error.InvalidParams;
    var page = ListPage{};
    if (value.object.get("offset")) |offset_value| {
        if (offset_value != .integer or offset_value.integer < 0) return error.InvalidParams;
        page.offset = std.math.cast(usize, offset_value.integer) orelse return error.InvalidParams;
    }
    if (value.object.get("limit")) |limit_value| {
        if (limit_value != .integer or limit_value.integer < 1 or limit_value.integer > 50)
            return error.InvalidParams;
        page.limit = @intCast(limit_value.integer);
    }
    if (value.object.get("state")) |state_value| {
        if (state_value != .string) return error.InvalidParams;
        page.state = std.meta.stringToEnum(job_store.State, state_value.string) orelse return error.InvalidParams;
    }
    if (value.object.get("search")) |search_value| {
        if (search_value != .string or search_value.string.len == 0 or search_value.string.len > 128 or
            !std.unicode.utf8ValidateSlice(search_value.string)) return error.InvalidParams;
        page.search = search_value.string;
    }
    var fields = value.object.iterator();
    while (fields.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!std.mem.eql(u8, key, "offset") and !std.mem.eql(u8, key, "limit") and
            !std.mem.eql(u8, key, "state") and !std.mem.eql(u8, key, "search")) return error.InvalidParams;
    }
    return page;
}

fn parseAddInput(allocator: std.mem.Allocator, params: std.json.Value) !job_store.AddInput {
    if (params != .object) return error.InvalidParams;
    const object = params.object;
    const url = stringField(object, "url") orelse return error.InvalidParams;
    const destination = stringField(object, "destination") orelse return error.InvalidParams;
    const key = stringField(object, "idempotency_key") orelse return error.InvalidParams;
    const reference_url = if (object.get("reference_url")) |value| switch (value) {
        .null => null,
        .string => |text| text,
        else => return error.InvalidParams,
    } else null;
    const name_value = object.get("name");
    const name = if (name_value) |value| switch (value) {
        .string => |text| text,
        .null => null,
        else => return error.InvalidParams,
    } else null;
    const digest_value = object.get("expected_sha256");
    const expected_sha256 = if (digest_value) |value| switch (value) {
        .string => |text| text,
        .null => null,
        else => return error.InvalidParams,
    } else null;
    const torrent_hash_value = object.get("torrent_info_hash");
    const torrent_info_hash = if (torrent_hash_value) |value| switch (value) {
        .string => |text| text,
        .null => null,
        else => return error.InvalidParams,
    } else null;
    const priority: i32 = if (object.get("priority")) |value| blk: {
        if (value != .integer or value.integer < -100 or value.integer > 100) return error.InvalidParams;
        break :blk @intCast(value.integer);
    } else 0;
    const bandwidth: u64 = if (object.get("bandwidth_limit_bytes_per_second")) |value| blk: {
        if (value != .integer or value.integer < 0 or value.integer > 1_000_000_000_000) return error.InvalidParams;
        break :blk @intCast(value.integer);
    } else 0;
    const selected: ?[]const []const u8 = if (object.get("selected_torrent_files")) |value| blk: {
        if (value == .null) break :blk null;
        if (value != .array or value.array.items.len == 0 or value.array.items.len > 10_000) return error.InvalidParams;
        const paths = try allocator.alloc([]const u8, value.array.items.len);
        errdefer allocator.free(paths);
        for (value.array.items, 0..) |entry, index| {
            if (entry != .string) return error.InvalidParams;
            paths[index] = entry.string;
        }
        break :blk paths;
    } else null;
    return .{ .url = url, .reference_url = reference_url, .name = name, .destination = destination, .idempotency_key = key, .priority = priority, .expected_sha256 = expected_sha256, .bandwidth_limit_bytes_per_second = bandwidth, .selected_torrent_files = selected, .torrent_info_hash = torrent_info_hash };
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn dispatchError(allocator: std.mem.Allocator, id: ?std.json.Value, code: i64, message: []const u8) !?[]u8 {
    const request_id = id orelse return null;
    return @as(?[]u8, try std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = request_id,
        .@"error" = .{ .code = code, .message = message },
    }, .{}));
}

fn uuidString(buffer: *[36]u8) []const u8 {
    const hex = "0123456789abcdef";
    var random_bytes: [16]u8 = undefined;
    // Session IDs are descriptive identifiers, not authentication tokens.
    // Use process-local monotonic entropy here; engine instance identity is
    // generated from the OS secure random source by the daemon entry point.
    const counter = session_counter.fetchAdd(1, .monotonic);
    std.mem.writeInt(u64, random_bytes[0..8], counter, .little);
    std.mem.writeInt(u64, random_bytes[8..16], @intCast(c.getpid()), .little);
    var index: usize = 0;
    for (random_bytes, 0..) |byte, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            buffer[index] = '-';
            index += 1;
        }
        buffer[index] = hex[byte >> 4];
        buffer[index + 1] = hex[byte & 0x0f];
        index += 2;
    }
    return buffer;
}

var session_counter: std.atomic.Value(u64) = .init(0);

fn readExact(fd: c.fd_t, buffer: []u8) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        const count = c.read(fd, buffer[offset..].ptr, buffer.len - offset);
        if (count == 0) return Error.UnexpectedEndOfStream;
        if (count < 0) return Error.SystemCallFailed;
        offset += @intCast(count);
    }
}

fn writeAll(fd: c.fd_t, buffer: []const u8) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        const flags: u32 = if (builtin.os.tag == .linux) c.MSG.NOSIGNAL else 0;
        const count = c.send(fd, buffer[offset..].ptr, buffer.len - offset, flags);
        if (count <= 0) return Error.SystemCallFailed;
        offset += @intCast(count);
    }
}

fn peerIsCurrentUser(fd: c.fd_t) !bool {
    if (builtin.os.tag == .macos) {
        var uid: c.uid_t = 0;
        var gid: c.gid_t = 0;
        return getpeereid(fd, &uid, &gid) == 0 and uid == c.getuid();
    } else {
        const Ucred = extern struct { pid: c_int, uid: c_uint, gid: c_uint };
        var credentials: Ucred = undefined;
        var length: c.socklen_t = @sizeOf(Ucred);
        // Linux SO_PEERCRED is 17 at SOL_SOCKET.
        if (c.getsockopt(fd, c.SOL.SOCKET, 17, &credentials, &length) != 0)
            return Error.SystemCallFailed;
        return credentials.uid == c.getuid();
    }
}

extern "c" fn getpeereid(fd: c_int, euid: *c.uid_t, egid: *c.gid_t) c_int;

const Paths = struct {
    app_dir: [:0]u8,
    socket_path: [:0]u8,
    socket_z: SocketPath,

    fn deinit(self: *Paths, allocator: std.mem.Allocator) void {
        allocator.free(self.app_dir);
        allocator.free(self.socket_path);
    }
};

fn makePaths(allocator: std.mem.Allocator, config: Config) !Paths {
    if (!validComponent(config.app_dir_name) or !validComponent(config.socket_name))
        return Error.InvalidPath;
    if (config.runtime_dir.len == 0 or std.mem.indexOfScalar(u8, config.runtime_dir, 0) != null)
        return Error.InvalidPath;
    const app_path = try std.fs.path.join(allocator, &.{ config.runtime_dir, config.app_dir_name });
    defer allocator.free(app_path);
    const socket_rel = try std.fs.path.join(allocator, &.{ app_path, config.socket_name });
    defer allocator.free(socket_rel);
    const app_dir = try allocator.dupeSentinel(u8, app_path, 0);
    errdefer allocator.free(app_dir);
    const socket_path = try allocator.dupeSentinel(u8, socket_rel, 0);
    errdefer allocator.free(socket_path);
    return .{ .app_dir = app_dir, .socket_path = socket_path, .socket_z = socket_path };
}

fn validComponent(value: []const u8) bool {
    return value.len != 0 and value.len < 80 and
        std.mem.indexOfAny(u8, value, "/\\\x00") == null and
        !std.mem.eql(u8, value, ".") and !std.mem.eql(u8, value, "..");
}

fn validatePrivateDirectory(path: []const u8) !void {
    const path_z = std.heap.page_allocator.dupeSentinel(u8, path, 0) catch return Error.InvalidPath;
    defer std.heap.page_allocator.free(path_z);
    const base_info = posix_stat.get(path_z, false) orelse return Error.UnsafeRuntimeDirectory;
    if (base_info.uid != posix_stat.currentUid() or
        !posix_stat.isDirectory(base_info) or base_info.mode & 0o077 != 0)
        return Error.UnsafeRuntimeDirectory;
}

fn ensurePrivateDirectory(path: []const u8) !void {
    const path_z = std.heap.page_allocator.dupeSentinel(u8, path, 0) catch return Error.InvalidPath;
    defer std.heap.page_allocator.free(path_z);
    if (c.mkdir(path_z, 0o700) == 0) return;
    const info = posix_stat.get(path_z, false) orelse return Error.UnsafeRuntimeDirectory;
    if (info.uid != posix_stat.currentUid() or
        !posix_stat.isDirectory(info) or info.mode & 0o077 != 0)
        return Error.UnsafeRuntimeDirectory;
}

fn pathExists(path: []const u8) bool {
    const path_z = std.heap.page_allocator.dupeSentinel(u8, path, 0) catch return true;
    defer std.heap.page_allocator.free(path_z);
    return posix_stat.get(path_z, false) != null;
}

fn unlinkIfSame(path: SocketPath, device: u64, inode: u64) void {
    if (posix_stat.get(path, false)) |current| {
        if (current.device == device and current.inode == inode) _ = c.unlink(path);
    }
}

fn makeAddress(path: []const u8) !c.sockaddr.un {
    var address: c.sockaddr.un = undefined;
    const address_bytes: *[@sizeOf(c.sockaddr.un)]u8 = @ptrCast(&address);
    @memset(address_bytes, 0);
    if (comptime builtin.os.tag == .macos) address.len = @sizeOf(c.sockaddr.un);
    address.family = c.AF.UNIX;
    if (path.len >= @min(address.path.len, max_socket_path_bytes)) return Error.InvalidPath;
    if (builtin.os.tag == .macos) address.len = @intCast(@offsetOf(c.sockaddr.un, "path") + path.len + 1);
    @memcpy(address.path[0..path.len], path);
    address.path[path.len] = 0;
    return address;
}
