//! Per-user job catalogue with atomic JSON persistence.
//!
//! Engine-owned download records with atomic persistence and queue controls.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix_stat = @import("posix_stat.zig");
const queue_policy = @import("queue.zig");
const CoreState = @import("root.zig").State;

extern "c" fn chmod(path: [*:0]const u8, mode: c.mode_t) c_int;

pub const State = enum { queued, scheduled, resolving, connecting, downloading, paused, retry_wait, verifying, completed, failed, canceled };
pub const StopAction = enum { pause, cancel };
pub const default_max_parallel_downloads = 4;
pub const default_max_parallel_downloads_per_host = 2;
pub const max_parallel_downloads_per_host = default_max_parallel_downloads_per_host;
pub const hours_per_week = 7 * 24;
pub const BandwidthScheduleMode = enum { global_limit, limited };
pub const MultipartMode = enum { off, auto, fixed };
pub const QueueFinishAction = enum { none, quit_app, power_off, custom_app, user_command };
pub const QueueCompletion = struct {
    action: QueueFinishAction,
    custom_app: ?[]u8 = null,
    user_command: ?[]u8 = null,

    pub fn deinit(self: QueueCompletion, allocator: std.mem.Allocator) void {
        if (self.custom_app) |path| allocator.free(path);
        if (self.user_command) |command| allocator.free(command);
    }
};
pub const QueueConfig = struct {
    id: []const u8 = "main",
    name: []const u8 = "main",
    max_active: u8 = default_max_parallel_downloads,
    schedule_enabled: bool = false,
    schedule_slots: [hours_per_week]bool = @splat(true),
    finish_action: QueueFinishAction = .none,
    custom_app: ?[]const u8 = null,
    user_command: ?[]const u8 = null,
};
const default_queues = [_]QueueConfig{.{}};

pub const Settings = struct {
    schema_version: u32 = 3,
    max_concurrent_tasks: u8 = default_max_parallel_downloads,
    default_connections_per_task: u8 = 4,
    multipart_mode: MultipartMode = .auto,
    default_download_folder: []const u8 = "",
    proxy_mode: ProxyMode = .system,
    proxy_url: ?[]const u8 = null,
    proxy_authentication_required: bool = false,
    bandwidth_limit_bytes_per_second: u64 = 0,
    queue_schedule_enabled: bool = false,
    queue_schedule_slots: [hours_per_week]bool = @splat(true),
    bandwidth_schedule_enabled: bool = false,
    scheduled_bandwidth_limit_bytes_per_second: u64 = 0,
    bandwidth_schedule_slots: [hours_per_week]BandwidthScheduleMode = @splat(.global_limit),
    debug_log_enabled: bool = false,
    queues: []const QueueConfig = &default_queues,
    browser_grab_extensions: []const u8 = "zip,rar,7z,dmg,pkg,exe,msi,iso,pdf,mp4,mp3,torrent",
    stop_seeding_after_minutes: u32 = 0,
    language: []const u8 = "system",
};

pub const RuntimePolicy = struct {
    max_concurrent_tasks: u8,
    queue_schedule_enabled: bool,
    queue_schedule_slots: [hours_per_week]bool,
    bandwidth_limit_bytes_per_second: u64,
    bandwidth_schedule_enabled: bool,
    scheduled_bandwidth_limit_bytes_per_second: u64,
    bandwidth_schedule_slots: [hours_per_week]BandwidthScheduleMode,

    pub fn queueActive(self: RuntimePolicy, slot: usize) bool {
        return !self.queue_schedule_enabled or self.queue_schedule_slots[slot];
    }

    pub fn downloadLimit(self: RuntimePolicy, slot: usize) u64 {
        if (self.bandwidth_schedule_enabled and self.bandwidth_schedule_slots[slot] == .limited)
            return self.scheduled_bandwidth_limit_bytes_per_second;
        return self.bandwidth_limit_bytes_per_second;
    }
};

pub const ProxyMode = enum { system, custom, disabled };

pub const WorkerProgress = struct {
    worker_id: u32 = 0,
    start: u64 = 0,
    end: u64 = 0,
    downloaded: u64 = 0,
};

pub const Job = struct {
    id: []const u8,
    queue_id: []const u8 = "main",
    url: []const u8,
    reference_url: ?[]const u8 = null,
    name: ?[]const u8,
    destination: []const u8,
    idempotency_key: []const u8,
    expected_sha256: ?[]const u8 = null,
    selected_torrent_files: ?[]const []const u8 = null,
    state: State = .queued,
    revision: u64 = 1,
    error_message: ?[]const u8 = null,
    retry_attempts: u8 = 0,
    retry_at_unix_ms: ?i64 = null,
    adaptive_connections: ?u8 = null,
    completed_bytes: u64 = 0,
    total_bytes: ?u64 = null,
    live_received_bytes: ?u64 = null,
    live_total_bytes: ?u64 = null,
    requested_control: ?StopAction = null,
    completion_trigger: bool = false,
    priority: i32 = 0,
    bandwidth_limit_bytes_per_second: u64 = 0,
    workers: [32]WorkerProgress = @splat(.{}),
    worker_count: usize = 0,
    torrent_active_peer: [256]u8 = @splat(0),
    torrent_active_peer_len: usize = 0,
    torrent_active_peer_count: u32 = 0,
    torrent_peer_count: ?u32 = null,
    torrent_seeder_count: ?u32 = null,
    torrent_leecher_count: ?u32 = null,
};

pub const AddInput = struct {
    url: []const u8,
    queue_id: []const u8 = "main",
    reference_url: ?[]const u8 = null,
    name: ?[]const u8,
    destination: []const u8,
    idempotency_key: []const u8,
    priority: i32 = 0,
    bandwidth_limit_bytes_per_second: u64 = 0,
    expected_sha256: ?[]const u8 = null,
    selected_torrent_files: ?[]const []const u8 = null,
    torrent_info_hash: ?[]const u8 = null,
};

pub const AddResult = struct {
    job: *const Job,
    duplicate: bool,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    directory_path: []const u8,
    file_path: []const u8,
    settings_path: []const u8,
    instance_lock: ?std.Io.File = null,
    settings: Settings = .{},
    settings_owned: bool = false,
    jobs: std.ArrayList(Job) = .empty,
    priority_bypass_count: u8 = 0,
    mutex: std.Io.Mutex = .init,
    log_mutex: std.Io.Mutex = .init,
    change_sequence: std.atomic.Value(u64) = .init(1),
    change_records: [256]ChangeRecord = undefined,
    change_record_count: usize = 0,

    const ChangeRecord = struct { cursor: u64, job_id: ?[36]u8 };

    // Called with the store lock held. A null ID invalidates the whole list.
    fn recordChange(self: *Store, job_id: ?[]const u8) void {
        const cursor = self.change_sequence.fetchAdd(1, .release) + 1;
        const id: ?[36]u8 = if (job_id) |value| if (value.len == 36) value[0..36].* else null else null;
        self.change_records[@intCast((cursor - 2) % self.change_records.len)] = .{ .cursor = cursor, .job_id = id };
        self.change_record_count = @min(self.change_record_count + 1, self.change_records.len);
    }

    /// Serialize a bounded notification while holding the same lock as job updates.
    /// Durable mutations use a full refresh because they may change list order or membership.
    pub fn changeEventJson(self: *Store, subscription_id: []const u8, engine_instance_id: []const u8, sequence: u64, after_cursor: u64, filter: ListFilter) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const current = self.change_sequence.load(.acquire);
        var resync = after_cursor > current or current -| after_cursor > self.change_record_count;
        var ids: [20][36]u8 = undefined;
        var count: usize = 0;
        if (!resync) {
            var cursor = after_cursor + 1;
            while (cursor <= current) : (cursor += 1) {
                const record = self.change_records[@intCast((cursor - 2) % self.change_records.len)];
                if (record.cursor != cursor or record.job_id == null) {
                    resync = true;
                    break;
                }
                const id = record.job_id.?;
                var seen = false;
                for (ids[0..count]) |existing| if (std.mem.eql(u8, &existing, &id)) {
                    seen = true;
                    break;
                };
                if (!seen) {
                    if (count == ids.len) {
                        resync = true;
                        break;
                    }
                    ids[count] = id;
                    count += 1;
                }
            }
        }
        var summaries: std.ArrayList(Summary) = .empty;
        defer summaries.deinit(self.allocator);
        defer for (summaries.items) |summary| freeSummary(self.allocator, summary);
        if (!resync) {
            for (ids[0..count]) |id| {
                var found = false;
                for (self.jobs.items) |*job| {
                    if (!std.mem.eql(u8, job.id, &id)) continue;
                    if (matchesFilter(job, filter)) try summaries.append(self.allocator, try makeSummary(self.allocator, job));
                    found = true;
                    break;
                }
                if (!found) {
                    resync = true;
                    break;
                }
            }
        }
        const cursor_text = try std.fmt.allocPrint(self.allocator, "{d}", .{current});
        defer self.allocator.free(cursor_text);
        const sequence_text = try std.fmt.allocPrint(self.allocator, "{d}", .{sequence});
        defer self.allocator.free(sequence_text);
        return std.json.Stringify.valueAlloc(self.allocator, .{
            .jsonrpc = "2.0",
            .method = "events.changed",
            .params = .{ .subscription_id = subscription_id, .engine_instance_id = engine_instance_id, .seq = sequence_text, .cursor = cursor_text, .resync_required = resync, .jobs = if (resync) summaries.items[0..0] else summaries.items },
        }, .{});
    }

    /// In-memory cursor for bounded change waits. Clients must discard it
    /// after an engine restart; it is not a durable job revision.
    pub fn changeCursor(self: *const Store) u64 {
        return self.change_sequence.load(.acquire);
    }

    /// Debug records intentionally omit URLs, paths, headers, and credentials.
    pub fn logAction(self: *Store, event: []const u8, outcome: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        const enabled = self.settings.debug_log_enabled;
        self.mutex.unlock(self.io);
        if (!enabled) return;
        self.log_mutex.lockUncancelable(self.io);
        defer self.log_mutex.unlock(self.io);
        const path = std.fs.path.join(self.allocator, &.{ self.directory_path, "engine-debug.log" }) catch return;
        defer self.allocator.free(path);
        const permissions: std.Io.File.Permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600);
        const file = std.Io.Dir.createFileAbsolute(self.io, path, .{
            .truncate = false,
            .exclusive = true,
            .permissions = permissions,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => std.Io.Dir.openFileAbsolute(self.io, path, .{ .mode = .read_write, .follow_symlinks = false }) catch return,
            else => return,
        };
        defer file.close(self.io);
        if (comptime builtin.os.tag != .windows) {
            const path_z = self.allocator.dupeSentinel(u8, path, 0) catch return;
            defer self.allocator.free(path_z);
            const info = posix_stat.get(path_z, false) orelse return;
            if (!posix_stat.isRegularFile(info) or info.uid != posix_stat.currentUid() or chmod(path_z, 0o600) != 0) return;
        }
        var length = file.length(self.io) catch return;
        if (length > 4 * 1024 * 1024) {
            file.setLength(self.io, 0) catch return;
            length = 0;
        }
        const seconds = @divTrunc(std.Io.Clock.now(.real, self.io).nanoseconds, std.time.ns_per_s);
        const line = std.fmt.allocPrint(self.allocator, "{d} {s} {s}\n", .{ seconds, event, outcome }) catch return;
        defer self.allocator.free(line);
        file.writePositionalAll(self.io, line, length) catch {};
    }

    pub fn open(allocator: std.mem.Allocator, io: std.Io, directory_path: []const u8) !Store {
        if (!std.fs.path.isAbsolute(directory_path)) return error.InvalidStorePath;
        try std.Io.Dir.cwd().createDirPath(io, directory_path);
        var directory = try std.Io.Dir.openDirAbsolute(io, directory_path, .{});
        defer directory.close(io);
        const directory_stat = try directory.stat(io);
        if (directory_stat.kind != .directory) return error.UnsafeStoreDirectory;
        if (comptime builtin.os.tag != .windows) {
            const path_z = try allocator.dupeSentinel(u8, directory_path, 0);
            defer allocator.free(path_z);
            const directory_info = posix_stat.get(path_z, false) orelse return error.UnsafeStoreDirectory;
            if (directory_info.uid != posix_stat.currentUid() or !posix_stat.isDirectory(directory_info) or
                chmod(path_z, 0o700) != 0)
                return error.UnsafeStoreDirectory;
        }

        // Hold the profile lock before loading or recovering any persisted job.
        const lock_file = directory.createFile(io, "engine.lock", .{
            .exclusive = true,
            .truncate = false,
            .permissions = if (builtin.os.tag == .windows) .default_file else .fromMode(0o600),
            .lock = .exclusive,
            .lock_nonblocking = true,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => try directory.openFile(io, "engine.lock", .{
                .mode = .read_write,
                .follow_symlinks = false,
                .lock = .exclusive,
                .lock_nonblocking = true,
            }),
            else => return err,
        };
        errdefer lock_file.close(io);

        const file_path = try std.fs.path.join(allocator, &.{ directory_path, "jobs.json" });
        errdefer allocator.free(file_path);
        const settings_path = try std.fs.path.join(allocator, &.{ directory_path, "settings.json" });
        errdefer allocator.free(settings_path);
        var store = Store{
            .allocator = allocator,
            .io = io,
            .directory_path = try allocator.dupe(u8, directory_path),
            .file_path = file_path,
            .settings_path = settings_path,
        };
        errdefer store.deinit();
        try store.load();
        try store.loadSettings();
        store.cleanupTorrentSnapshots() catch {};
        store.instance_lock = lock_file;
        return store;
    }

    pub fn deinit(self: *Store) void {
        if (self.instance_lock) |file| file.close(self.io);
        for (self.jobs.items) |job| {
            self.freeJob(job);
        }
        self.jobs.deinit(self.allocator);
        self.allocator.free(self.directory_path);
        self.allocator.free(self.file_path);
        if (self.settings_owned) self.freeSettings(self.settings);
        self.allocator.free(self.settings_path);
        self.* = undefined;
    }

    pub fn settingsJson(self: *Store, request_id: std.json.Value) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return std.json.Stringify.valueAlloc(self.allocator, .{ .jsonrpc = "2.0", .id = request_id, .result = self.settings }, .{});
    }

    pub fn runtimePolicy(self: *Store) RuntimePolicy {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{
            .max_concurrent_tasks = self.settings.max_concurrent_tasks,
            .queue_schedule_enabled = self.settings.queue_schedule_enabled,
            .queue_schedule_slots = self.settings.queue_schedule_slots,
            .bandwidth_limit_bytes_per_second = self.settings.bandwidth_limit_bytes_per_second,
            .bandwidth_schedule_enabled = self.settings.bandwidth_schedule_enabled,
            .scheduled_bandwidth_limit_bytes_per_second = self.settings.scheduled_bandwidth_limit_bytes_per_second,
            .bandwidth_schedule_slots = self.settings.bandwidth_schedule_slots,
        };
    }

    fn queueByID(self: *Store, id: []const u8) ?QueueConfig {
        for (self.settings.queues) |queue| if (std.mem.eql(u8, queue.id, id)) return queue;
        return null;
    }

    pub fn queueActiveForJob(self: *Store, job_id: []const u8, slot: usize) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.jobs.items) |job| if (std.mem.eql(u8, job.id, job_id)) {
            const queue = self.queueByID(job.queue_id) orelse return false;
            return !queue.schedule_enabled or queue.schedule_slots[slot];
        };
        return false;
    }

    pub const OwnedProxyPolicy = struct {
        mode: ProxyMode,
        url: ?[]u8,
        authentication_required: bool,

        pub fn deinit(self: OwnedProxyPolicy, allocator: std.mem.Allocator) void {
            if (self.url) |url| allocator.free(url);
        }
    };

    /// Snapshot the current endpoint for a probe without holding the store
    /// lock across network I/O. A running transfer retains its own snapshot.
    pub fn copyProxyPolicy(self: *Store) !OwnedProxyPolicy {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{
            .mode = self.settings.proxy_mode,
            .url = if (self.settings.proxy_url) |url| try self.allocator.dupe(u8, url) else null,
            .authentication_required = self.settings.proxy_authentication_required,
        };
    }

    /// Switches only queue-controlled jobs. User-paused jobs remain paused.
    pub fn applyQueueWindow(self: *Store, slot: usize) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var changed: std.ArrayList(usize) = .empty;
        defer changed.deinit(self.allocator);
        for (self.jobs.items, 0..) |job, index| {
            const queue = self.queueByID(job.queue_id) orelse continue;
            const active = !queue.schedule_enabled or queue.schedule_slots[slot];
            if ((active and job.state == .scheduled) or (!active and job.state == .queued)) {
                if (job.revision == std.math.maxInt(u64)) return error.RevisionOverflow;
                try changed.append(self.allocator, index);
            }
        }
        if (changed.items.len == 0) return;
        for (changed.items) |index| {
            const queue = self.queueByID(self.jobs.items[index].queue_id).?;
            const active = !queue.schedule_enabled or queue.schedule_slots[slot];
            self.jobs.items[index].state = if (active) .queued else .scheduled;
            self.jobs.items[index].revision += 1;
        }
        self.persist() catch |err| {
            for (changed.items) |index| {
                const queue = self.queueByID(self.jobs.items[index].queue_id).?;
                const active = !queue.schedule_enabled or queue.schedule_slots[slot];
                self.jobs.items[index].state = if (active) .scheduled else .queued;
                self.jobs.items[index].revision -= 1;
            }
            return err;
        };
    }

    pub fn updateSettingsJson(self: *Store, request_id: std.json.Value, value: Settings) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try validateSettings(value);
        for (self.jobs.items) |job| {
            var found = false;
            for (value.queues) |queue| if (std.mem.eql(u8, job.queue_id, queue.id)) {
                found = true;
                break;
            };
            if (!found) return error.QueueHasJobs;
        }
        const replacement = try self.duplicateSettings(value);
        const old = self.settings;
        self.settings = replacement;
        self.persistSettings() catch |err| {
            self.settings = old;
            self.freeSettings(replacement);
            return err;
        };
        self.freeSettings(old);
        return std.json.Stringify.valueAlloc(self.allocator, .{ .jsonrpc = "2.0", .id = request_id, .result = self.settings }, .{});
    }

    fn duplicateSettings(self: *Store, value: Settings) !Settings {
        const queues = try self.allocator.alloc(QueueConfig, value.queues.len);
        var copied: usize = 0;
        errdefer {
            for (queues[0..copied]) |queue| {
                self.allocator.free(queue.id);
                self.allocator.free(queue.name);
                if (queue.custom_app) |path| self.allocator.free(path);
                if (queue.user_command) |command| self.allocator.free(command);
            }
            self.allocator.free(queues);
        }
        for (value.queues, 0..) |queue, index| {
            queues[index] = .{
                .id = try self.allocator.dupe(u8, queue.id),
                .name = try self.allocator.dupe(u8, queue.name),
                .max_active = queue.max_active,
                .schedule_enabled = queue.schedule_enabled,
                .schedule_slots = queue.schedule_slots,
                .finish_action = queue.finish_action,
                .custom_app = if (queue.custom_app) |path| try self.allocator.dupe(u8, path) else null,
                .user_command = if (queue.user_command) |command| try self.allocator.dupe(u8, command) else null,
            };
            copied += 1;
        }
        return .{
            .schema_version = 3,
            .max_concurrent_tasks = value.max_concurrent_tasks,
            .default_connections_per_task = value.default_connections_per_task,
            .multipart_mode = value.multipart_mode,
            .default_download_folder = try self.allocator.dupe(u8, value.default_download_folder),
            .proxy_mode = value.proxy_mode,
            .proxy_url = if (value.proxy_url) |url| try self.allocator.dupe(u8, url) else null,
            .proxy_authentication_required = value.proxy_authentication_required,
            .bandwidth_limit_bytes_per_second = value.bandwidth_limit_bytes_per_second,
            .queue_schedule_enabled = value.queue_schedule_enabled,
            .queue_schedule_slots = value.queue_schedule_slots,
            .bandwidth_schedule_enabled = value.bandwidth_schedule_enabled,
            .scheduled_bandwidth_limit_bytes_per_second = value.scheduled_bandwidth_limit_bytes_per_second,
            .bandwidth_schedule_slots = value.bandwidth_schedule_slots,
            .debug_log_enabled = value.debug_log_enabled,
            .queues = queues,
            .browser_grab_extensions = try self.allocator.dupe(u8, value.browser_grab_extensions),
            .stop_seeding_after_minutes = value.stop_seeding_after_minutes,
            .language = try self.allocator.dupe(u8, value.language),
        };
    }

    fn freeSettings(self: *Store, value: Settings) void {
        self.allocator.free(value.default_download_folder);
        if (value.proxy_url) |url| self.allocator.free(url);
        for (value.queues) |queue| {
            self.allocator.free(queue.id);
            self.allocator.free(queue.name);
            if (queue.custom_app) |path| self.allocator.free(path);
            if (queue.user_command) |command| self.allocator.free(command);
        }
        self.allocator.free(value.queues);
        self.allocator.free(value.browser_grab_extensions);
        self.allocator.free(value.language);
    }

    fn addUnlocked(self: *Store, input: AddInput) !AddResult {
        for (self.jobs.items) |*job| {
            if (!std.mem.eql(u8, job.idempotency_key, input.idempotency_key)) continue;
            if (sameInput(job, input)) return .{ .job = job, .duplicate = true };
            return error.IdempotencyConflict;
        }
        try validateInput(self.allocator, self.io, input);
        if (self.queueByID(input.queue_id) == null) return error.QueueNotFound;

        const job = try self.duplicateJob(input);
        const occupied = self.destinationOccupied(job, false) catch |err| {
            self.freeJob(job);
            return err;
        };
        if (occupied) {
            self.freeJob(job);
            return error.DestinationReserved;
        }
        const source_snapshot = if (@import("../protocols/torrent/source.zig").isLocalTorrent(input.url))
            self.snapshotTorrentSource(job.id, input.url, input.torrent_info_hash) catch |err| {
                self.freeJob(job);
                return err;
            }
        else
            null;
        defer if (source_snapshot) |path| self.allocator.free(path);
        self.jobs.append(self.allocator, job) catch |err| {
            if (source_snapshot) |path| std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
            self.freeJob(job);
            return err;
        };
        self.persist() catch |err| {
            if (source_snapshot) |path| std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
            self.freeJob(self.jobs.pop().?);
            return err;
        };
        return .{ .job = &self.jobs.items[self.jobs.items.len - 1], .duplicate = false };
    }

    /// Private immutable metainfo copy. Job IDs are generated before this is
    /// called; linking atomically avoids exposing a partially written source.
    fn snapshotTorrentSource(self: *Store, job_id: []const u8, url: []const u8, expected_info_hash: ?[]const u8) ![]u8 {
        const source = @import("../protocols/torrent/source.zig");
        const torrent = @import("../protocols/torrent/metainfo.zig");
        const original = try source.pathAlloc(self.allocator, url);
        defer self.allocator.free(original);
        const bytes = try std.Io.Dir.readFileAlloc(.cwd(), self.io, original, self.allocator, .limited(torrent.max_metainfo_bytes));
        defer self.allocator.free(bytes);
        if (expected_info_hash) |expected| {
            const info = try torrent.inspect(self.allocator, bytes);
            const hex = std.fmt.bytesToHex(info.info_hash, .lower);
            if (!std.ascii.eqlIgnoreCase(expected, &hex)) return error.TorrentSourceChanged;
        }
        const map = try torrent.inspectFileMap(self.allocator, bytes);
        defer map.deinit(self.allocator);
        const path = try self.torrentSnapshotPath(self.allocator, job_id);
        errdefer self.allocator.free(path);
        var atomic = try std.Io.Dir.createFileAtomic(.cwd(), self.io, path, .{
            .permissions = if (builtin.os.tag == .windows) .default_file else std.Io.File.Permissions.fromMode(0o600),
        });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, bytes);
        try atomic.file.sync(self.io);
        try atomic.link(self.io);
        return path;
    }

    pub fn torrentSnapshotPath(self: *const Store, allocator: std.mem.Allocator, job_id: []const u8) ![]u8 {
        if (!validJobId(job_id)) return error.InvalidJobId;
        const filename = try std.fmt.allocPrint(allocator, "torrent-{s}.torrent", .{job_id});
        defer allocator.free(filename);
        return std.fs.path.join(allocator, &.{ self.directory_path, filename });
    }

    /// A crash between snapshot publication and jobs.json persistence may
    /// leave an unreferenced metainfo file. Only this app's exact filename
    /// pattern is eligible for startup cleanup.
    fn cleanupTorrentSnapshots(self: *Store) !void {
        const source = @import("../protocols/torrent/source.zig");
        var directory = try std.Io.Dir.openDirAbsolute(self.io, self.directory_path, .{ .iterate = true, .follow_symlinks = false });
        defer directory.close(self.io);
        var iterator = directory.iterate();
        while (try iterator.next(self.io)) |entry| {
            if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, "torrent-") or
                !std.mem.endsWith(u8, entry.name, ".torrent") or entry.name.len != 8 + 36 + 8) continue;
            const job_id = entry.name[8 .. 8 + 36];
            if (!validJobId(job_id)) continue;
            var referenced = false;
            for (self.jobs.items) |job| {
                if (std.mem.eql(u8, job.id, job_id) and source.isLocalTorrent(job.url)) {
                    referenced = true;
                    break;
                }
            }
            if (!referenced) directory.deleteFile(self.io, entry.name) catch {};
        }
    }

    pub const ListFilter = struct { state: ?State = null, search: ?[]const u8 = null };

    fn matchesFilter(job: *const Job, filter: ListFilter) bool {
        if (filter.state) |state| if (job.state != state) return false;
        if (filter.search) |search| {
            const name = job.name orelse "";
            if (std.ascii.findIgnoreCase(name, search) == null and
                std.ascii.findIgnoreCase(redactUrl(job.url), search) == null) return false;
        }
        return true;
    }

    pub fn listJson(self: *Store, request_id: std.json.Value, offset: usize, limit: usize) ![]u8 {
        return self.listFilteredJson(request_id, offset, limit, .{});
    }

    pub fn listFilteredJson(self: *Store, request_id: std.json.Value, offset: usize, limit: usize, filter: ListFilter) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const allocator = self.allocator;
        var summaries: std.ArrayList(Summary) = .empty;
        defer summaries.deinit(allocator);
        defer for (summaries.items) |summary| freeSummary(allocator, summary);
        var matching: usize = 0;
        for (self.jobs.items) |*job| {
            if (!matchesFilter(job, filter)) continue;
            if (matching >= offset and summaries.items.len < limit)
                try summaries.append(allocator, try makeSummary(allocator, job));
            matching += 1;
        }
        const total = try std.fmt.allocPrint(allocator, "{d}", .{matching});
        defer allocator.free(total);
        const next_offset = if (offset +| summaries.items.len < matching)
            try std.fmt.allocPrint(allocator, "{d}", .{offset +| summaries.items.len})
        else
            null;
        defer if (next_offset) |value| allocator.free(value);
        return std.json.Stringify.valueAlloc(allocator, .{
            .jsonrpc = "2.0",
            .id = request_id,
            .result = .{
                .jobs = summaries.items,
                .total = total,
                .next_offset = next_offset,
            },
        }, .{});
    }

    pub fn getJson(self: *Store, request_id: std.json.Value, job_id: []const u8) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.jobs.items) |*job| {
            if (!std.mem.eql(u8, job.id, job_id)) continue;
            const summary = try makeSummary(self.allocator, job);
            defer freeSummary(self.allocator, summary);
            return std.json.Stringify.valueAlloc(self.allocator, .{
                .jsonrpc = "2.0",
                .id = request_id,
                .result = .{ .job = summary },
            }, .{});
        }
        return error.JobNotFound;
    }

    pub fn subscribeJson(self: *Store, request_id: std.json.Value, subscription_id: []const u8, engine_instance_id: []const u8, interval_ms: u16, filter: ListFilter) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var summaries: std.ArrayList(Summary) = .empty;
        defer summaries.deinit(self.allocator);
        defer for (summaries.items) |summary| freeSummary(self.allocator, summary);
        var matching: usize = 0;
        for (self.jobs.items) |*job| {
            if (!matchesFilter(job, filter)) continue;
            if (summaries.items.len < 20) try summaries.append(self.allocator, try makeSummary(self.allocator, job));
            matching += 1;
        }
        const cursor = try std.fmt.allocPrint(self.allocator, "{d}", .{self.change_sequence.load(.acquire)});
        defer self.allocator.free(cursor);
        const total = try std.fmt.allocPrint(self.allocator, "{d}", .{matching});
        defer self.allocator.free(total);
        const next_offset: ?[]const u8 = if (summaries.items.len < matching) "20" else null;
        return std.json.Stringify.valueAlloc(self.allocator, .{
            .jsonrpc = "2.0",
            .id = request_id,
            .result = .{
                .subscription_id = subscription_id,
                .engine_instance_id = engine_instance_id,
                .cursor = cursor,
                .interval_ms = interval_ms,
                .snapshot = .{ .jobs = summaries.items, .total = total, .next_offset = next_offset },
            },
        }, .{});
    }

    pub fn statusJson(self: *Store, request_id: std.json.Value, engine_instance_id: []const u8, uptime_seconds: u64) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var active: usize = 0;
        var waiting: usize = 0;
        var paused: usize = 0;
        for (self.jobs.items) |job| switch (job.state) {
            .resolving, .connecting, .downloading, .verifying => active += 1,
            .queued, .scheduled, .retry_wait => waiting += 1,
            .paused => paused += 1,
            else => {},
        };
        return std.json.Stringify.valueAlloc(self.allocator, .{
            .jsonrpc = "2.0",
            .id = request_id,
            .result = .{
                .engine_instance_id = engine_instance_id,
                .uptime_seconds = uptime_seconds,
                .jobs = .{ .total = self.jobs.items.len, .active = active, .waiting = waiting, .paused = paused },
            },
        }, .{});
    }

    pub fn addJson(self: *Store, request_id: std.json.Value, input: AddInput) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const result = try self.addUnlocked(input);
        return std.json.Stringify.valueAlloc(self.allocator, .{
            .jsonrpc = "2.0",
            .id = request_id,
            .result = .{
                .job_id = result.job.id,
                .state = result.job.state,
                .revision = "1",
                .duplicate = result.duplicate,
            },
        }, .{});
    }

    pub fn resumeQueueJson(self: *Store, request_id: std.json.Value) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const previous = try self.allocator.dupe(Job, self.jobs.items);
        defer self.allocator.free(previous);
        var count: usize = 0;
        for (self.jobs.items) |*job| {
            if (job.state != .paused and job.state != .retry_wait) continue;
            job.state = .queued;
            job.requested_control = null;
            job.retry_at_unix_ms = null;
            job.revision += 1;
            count += 1;
        }
        if (count > 0) {
            self.persist() catch |err| {
                @memcpy(self.jobs.items, previous);
                return err;
            };
            self.recordChange(null);
        }
        return std.json.Stringify.valueAlloc(self.allocator, .{
            .jsonrpc = "2.0",
            .id = request_id,
            .result = .{ .resumed = count },
        }, .{});
    }

    /// Replacing an expiring URL is an explicit restart: old partial bytes are
    /// never combined with a representation fetched from another resource.
    pub fn replaceSourceJson(self: *Store, request_id: std.json.Value, job_id: []const u8, expected_revision: u64, url: []const u8) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (!validReferenceURL(url)) return error.InvalidJob;
        for (self.jobs.items) |*job| {
            if (!std.mem.eql(u8, job.id, job_id)) continue;
            if (job.revision != expected_revision) return error.StaleJobRevision;
            if (!(job.state == .paused or job.state == .failed or job.state == .queued or job.state == .scheduled or job.state == .retry_wait)) return error.InvalidJobControl;
            if (!(std.mem.startsWith(u8, job.url, "http://") or std.mem.startsWith(u8, job.url, "https://"))) return error.InvalidJobControl;
            const replacement = try self.allocator.dupe(u8, url);
            var replacement_owned = true;
            errdefer if (replacement_owned) self.allocator.free(replacement);
            if (try self.destinationOccupied(job.*, false)) return error.DestinationReserved;
            const old_path = try self.destinationPath(job.*);
            defer self.allocator.free(old_path);
            const retained_name = job.name orelse try self.allocator.dupe(u8, std.fs.path.basename(old_path));
            errdefer if (replacement_owned and job.name == null) self.allocator.free(retained_name);
            // Explicit confirmation is required by the RPC before this call.
            try self.deletePartialFilesStrict(job.*);
            const previous = job.*;
            job.url = replacement;
            job.name = retained_name;
            job.state = .queued;
            job.revision += 1;
            job.completed_bytes = 0;
            job.total_bytes = null;
            job.live_received_bytes = null;
            job.live_total_bytes = null;
            job.error_message = null;
            job.requested_control = null;
            job.retry_attempts = 0;
            job.retry_at_unix_ms = null;
            job.adaptive_connections = null;
            job.worker_count = 0;
            self.persist() catch |err| {
                job.* = previous;
                return err;
            };
            replacement_owned = false;
            self.allocator.free(previous.url);
            if (previous.error_message) |message| self.allocator.free(message);
            self.recordChange(job.id);
            return std.json.Stringify.valueAlloc(self.allocator, .{
                .jsonrpc = "2.0",
                .id = request_id,
                .result = .{ .job_id = job.id, .state = job.state },
            }, .{});
        }
        return error.JobNotFound;
    }

    pub fn controlJson(self: *Store, request_id: std.json.Value, job_id: []const u8, action: Action, expected_revision: u64) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const job = self.controlUnlocked(job_id, action, expected_revision) catch |err| return err;
        const revision = try std.fmt.allocPrint(self.allocator, "{d}", .{job.revision});
        defer self.allocator.free(revision);
        return std.json.Stringify.valueAlloc(self.allocator, .{
            .jsonrpc = "2.0",
            .id = request_id,
            .result = .{
                .job_id = job.id,
                .state = job.state,
                .revision = revision,
                .duplicate = false,
            },
        }, .{});
    }

    pub fn setBandwidthLimitJson(self: *Store, request_id: std.json.Value, job_id: []const u8, expected_revision: u64, limit: u64) ![]u8 {
        if (limit > 1_000_000_000_000) return error.InvalidJob;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.jobs.items) |*job| {
            if (!std.mem.eql(u8, job.id, job_id)) continue;
            if (job.revision != expected_revision) return error.StaleJobRevision;
            const previous_limit = job.bandwidth_limit_bytes_per_second;
            const previous_revision = job.revision;
            job.bandwidth_limit_bytes_per_second = limit;
            job.revision = std.math.add(u64, job.revision, 1) catch return error.RevisionOverflow;
            self.persist() catch |err| {
                job.bandwidth_limit_bytes_per_second = previous_limit;
                job.revision = previous_revision;
                return err;
            };
            const revision = try std.fmt.allocPrint(self.allocator, "{d}", .{job.revision});
            defer self.allocator.free(revision);
            return std.json.Stringify.valueAlloc(self.allocator, .{ .jsonrpc = "2.0", .id = request_id, .result = .{
                .job_id = job.id,
                .revision = revision,
                .bandwidth_limit_bytes_per_second = limit,
            } }, .{});
        }
        return error.JobNotFound;
    }

    pub fn jobBandwidthLimit(self: *Store, job_id: []const u8) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.jobs.items) |job| if (std.mem.eql(u8, job.id, job_id)) return job.bandwidth_limit_bytes_per_second;
        return 0;
    }

    pub fn reorderJson(self: *Store, request_id: std.json.Value, job_id: []const u8, position: usize, expected_revision: u64) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var old_index: ?usize = null;
        for (self.jobs.items, 0..) |*job, index| {
            if (std.mem.eql(u8, job.id, job_id)) {
                old_index = index;
                if (job.revision != expected_revision) return error.StaleJobRevision;
                switch (job.state) {
                    .queued, .scheduled, .paused, .retry_wait => {},
                    else => return error.InvalidJobControl,
                }
                break;
            }
        }
        const from = old_index orelse return error.JobNotFound;
        if (position >= self.jobs.items.len) return error.InvalidQueuePosition;
        if (from != position) {
            const job = self.jobs.orderedRemove(from);
            try self.jobs.insert(self.allocator, position, job);
        }
        const job = &self.jobs.items[position];
        const previous_revision = job.revision;
        job.revision = std.math.add(u64, job.revision, 1) catch {
            if (from != position) {
                const moved = self.jobs.orderedRemove(position);
                self.jobs.insert(self.allocator, from, moved) catch unreachable;
            }
            return error.RevisionOverflow;
        };
        self.persist() catch |err| {
            job.revision = previous_revision;
            if (from != position) {
                const moved = self.jobs.orderedRemove(position);
                self.jobs.insert(self.allocator, from, moved) catch unreachable;
            }
            return err;
        };
        const revision = try std.fmt.allocPrint(self.allocator, "{d}", .{job.revision});
        defer self.allocator.free(revision);
        return std.json.Stringify.valueAlloc(self.allocator, .{ .jsonrpc = "2.0", .id = request_id, .result = .{
            .job_id = job.id,
            .position = position,
            .revision = revision,
        } }, .{});
    }

    pub fn moveQueueJson(self: *Store, request_id: std.json.Value, job_id: []const u8, queue_id: []const u8, expected_revision: u64) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.queueByID(queue_id) == null) return error.QueueNotFound;
        for (self.jobs.items) |*job| {
            if (!std.mem.eql(u8, job.id, job_id)) continue;
            if (job.revision != expected_revision) return error.StaleJobRevision;
            const new_id = try self.allocator.dupe(u8, queue_id);
            const old_id = job.queue_id;
            job.queue_id = new_id;
            job.revision = std.math.add(u64, job.revision, 1) catch {
                job.queue_id = old_id;
                self.allocator.free(new_id);
                return error.RevisionOverflow;
            };
            self.persist() catch |err| {
                job.queue_id = old_id;
                job.revision -= 1;
                self.allocator.free(new_id);
                return err;
            };
            self.allocator.free(old_id);
            const revision = try std.fmt.allocPrint(self.allocator, "{d}", .{job.revision});
            defer self.allocator.free(revision);
            return std.json.Stringify.valueAlloc(self.allocator, .{ .jsonrpc = "2.0", .id = request_id, .result = .{
                .job_id = job.id, .queue_id = job.queue_id, .revision = revision,
            } }, .{});
        }
        return error.JobNotFound;
    }

    pub fn deleteJson(self: *Store, request_id: std.json.Value, job_id: []const u8, expected_revision: u64, delete_partial: bool) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var index: ?usize = null;
        for (self.jobs.items, 0..) |job, i| {
            if (!std.mem.eql(u8, job.id, job_id)) continue;
            if (job.revision != expected_revision) return error.StaleJobRevision;
            switch (job.state) {
                .resolving, .connecting, .downloading, .verifying => return error.InvalidJobControl,
                else => {},
            }
            if (delete_partial) try self.deletePartialFilesStrict(job);
            index = i;
            break;
        }
        const remove_at = index orelse return error.JobNotFound;
        const removed = self.jobs.orderedRemove(remove_at);
        self.persist() catch |err| {
            self.jobs.insert(self.allocator, remove_at, removed) catch unreachable;
            return err;
        };
        if (@import("../protocols/torrent/source.zig").isLocalTorrent(removed.url)) {
            const snapshot = self.torrentSnapshotPath(self.allocator, removed.id) catch null;
            if (snapshot) |path| {
                defer self.allocator.free(path);
                std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
            }
        }
        self.freeJob(removed);
        return std.json.Stringify.valueAlloc(self.allocator, .{ .jsonrpc = "2.0", .id = request_id, .result = .{
            .job_id = job_id,
            .deleted = true,
            .partial_files_deleted = delete_partial,
        } }, .{});
    }

    pub const Action = enum { pause, @"resume", cancel, start, retry };

    fn controlUnlocked(self: *Store, job_id: []const u8, action: Action, expected_revision: u64) !*const Job {
        for (self.jobs.items) |*job| {
            if (!std.mem.eql(u8, job.id, job_id)) continue;
            if (job.revision != expected_revision) return error.StaleJobRevision;
            const next: State = switch (action) {
                .pause => switch (job.state) {
                    .queued, .scheduled, .retry_wait => .paused,
                    else => return error.InvalidJobControl,
                },
                .@"resume" => switch (job.state) {
                    .paused, .retry_wait => .queued,
                    else => return error.InvalidJobControl,
                },
                .cancel => switch (job.state) {
                    .queued, .scheduled, .paused, .retry_wait => .canceled,
                    else => return error.InvalidJobControl,
                },
                .start => switch (job.state) {
                    .queued, .retry_wait => blk: {
                        if (self.activeForHost(job.url) >= max_parallel_downloads_per_host) return error.HostLimitReached;
                        if (try self.destinationOccupied(job.*, true)) return error.DestinationReserved;
                        break :blk .downloading;
                    },
                    else => return error.InvalidJobControl,
                },
                .retry => switch (job.state) {
                    .failed => .queued,
                    else => return error.InvalidJobControl,
                },
            };
            const previous = job.state;
            const previous_revision = job.revision;
            const previous_error = job.error_message;
            const previous_completed = job.completed_bytes;
            const previous_total = job.total_bytes;
            const previous_retry_attempts = job.retry_attempts;
            const previous_retry_at = job.retry_at_unix_ms;
            const previous_adaptive_connections = job.adaptive_connections;
            const previous_live_received = job.live_received_bytes;
            const previous_live_total = job.live_total_bytes;
            const previous_worker_count = job.worker_count;
            const previous_requested_control = job.requested_control;
            job.state = next;
            job.revision = std.math.add(u64, job.revision, 1) catch {
                job.state = previous;
                return error.RevisionOverflow;
            };
            if (action == .start) {
                job.error_message = null;
                // Keep the last durable count visible until the downloader
                // validates its journal and reports the resumed position.
                job.live_received_bytes = null;
                job.live_total_bytes = null;
                job.worker_count = 0;
                job.requested_control = null;
            }
            if (action == .retry or action == .@"resume") job.retry_attempts = 0;
            if (action == .retry) job.adaptive_connections = null;
            if (next != .retry_wait) job.retry_at_unix_ms = null;
            self.persist() catch |err| {
                job.state = previous;
                job.revision = previous_revision;
                job.error_message = previous_error;
                job.completed_bytes = previous_completed;
                job.total_bytes = previous_total;
                job.retry_attempts = previous_retry_attempts;
                job.retry_at_unix_ms = previous_retry_at;
                job.adaptive_connections = previous_adaptive_connections;
                job.live_received_bytes = previous_live_received;
                job.live_total_bytes = previous_live_total;
                job.worker_count = previous_worker_count;
                job.requested_control = previous_requested_control;
                return err;
            };
            if (action == .start) if (previous_error) |value| self.allocator.free(value);
            return job;
        }
        return error.JobNotFound;
    }

    pub const DownloadTask = struct {
        id: []u8,
        url: []u8,
        name: ?[]u8,
        destination: []u8,
        connections: u8,
        proxy_mode: ProxyMode,
        proxy_url: ?[]u8,
        proxy_authentication_required: bool,
        expected_sha256: ?[32]u8,
        selected_torrent_files: ?[]const []const u8,

        pub fn deinit(self: DownloadTask, allocator: std.mem.Allocator) void {
            allocator.free(self.id);
            allocator.free(self.url);
            if (self.name) |name| allocator.free(name);
            allocator.free(self.destination);
            if (self.proxy_url) |url| allocator.free(url);
            freeSelectedFiles(allocator, self.selected_torrent_files);
        }
    };

    pub fn copyDownloadTask(self: *Store, job_id: []const u8) !DownloadTask {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.jobs.items) |job| {
            if (!std.mem.eql(u8, job.id, job_id)) continue;
            if (job.state != .downloading) return error.InvalidJobControl;
            const id = try self.allocator.dupe(u8, job.id);
            errdefer self.allocator.free(id);
            const url = try self.allocator.dupe(u8, job.url);
            errdefer self.allocator.free(url);
            const name = if (job.name) |value| try self.allocator.dupe(u8, value) else null;
            errdefer if (name) |value| self.allocator.free(value);
            const destination = try self.allocator.dupe(u8, job.destination);
            errdefer self.allocator.free(destination);
            const proxy_url = if (self.settings.proxy_url) |value| try self.allocator.dupe(u8, value) else null;
            errdefer if (proxy_url) |value| self.allocator.free(value);
            const selected = try duplicateSelectedFiles(self.allocator, job.selected_torrent_files);
            return .{ .id = id, .url = url, .name = name, .destination = destination, .connections = self.connectionsForJob(job), .proxy_mode = self.settings.proxy_mode, .proxy_url = proxy_url, .proxy_authentication_required = self.settings.proxy_authentication_required, .expected_sha256 = decodeSha256(job.expected_sha256), .selected_torrent_files = selected };
        }
        return error.JobNotFound;
    }

    pub fn startNextQueued(self: *Store) !?DownloadTask {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var refs: std.ArrayList(queue_policy.JobRef) = .empty;
        defer refs.deinit(self.allocator);
        for (self.jobs.items, 0..) |job, index| {
            const queue = self.queueByID(job.queue_id) orelse continue;
            var active_in_queue: usize = 0;
            for (self.jobs.items) |candidate| if (candidate.state == .downloading and std.mem.eql(u8, candidate.queue_id, queue.id)) {
                active_in_queue += 1;
            };
            try refs.append(self.allocator, .{
                .id = @intCast(index),
                .host = sourceHost(job.url),
                .priority = job.priority,
                .sequence = @intCast(index),
                .state = if (job.state == .queued and active_in_queue >= queue.max_active) .paused else std.meta.stringToEnum(CoreState, @tagName(job.state)).?,
            });
        }
        const limits: queue_policy.Limits = .{
            .global_active = self.settings.max_concurrent_tasks,
            .per_host_active = max_parallel_downloads_per_host,
        };
        var choice = queue_policy.choose(refs.items, limits, self.priority_bypass_count >= 8) orelse return null;
        var selected = choice.selected;
        while (try self.destinationOccupied(self.jobs.items[@intCast(refs.items[selected].id)], true)) {
            refs.items[selected].state = .paused;
            choice = queue_policy.choose(refs.items, limits, self.priority_bypass_count >= 8) orelse return null;
            selected = choice.selected;
        }
        const job = &self.jobs.items[@intCast(refs.items[selected].id)];
        const old_state = job.state;
        const old_revision = job.revision;
        const old_error = job.error_message;
        const old_completed = job.completed_bytes;
        const old_total = job.total_bytes;
        const old_retry_at = job.retry_at_unix_ms;
        const old_live_received = job.live_received_bytes;
        const old_live_total = job.live_total_bytes;
        const old_worker_count = job.worker_count;
        const old_requested_control = job.requested_control;
        const next_revision = try std.math.add(u64, old_revision, 1);
        const task = try self.copyTaskUnlocked(job.*);
        errdefer task.deinit(self.allocator);
        job.state = .downloading;
        job.revision = next_revision;
        job.error_message = null;
        // Preserve the durable prefix while the worker revalidates its
        // partial file. Its first report will correct stale metadata.
        job.retry_at_unix_ms = null;
        job.live_received_bytes = null;
        job.live_total_bytes = null;
        job.worker_count = 0;
        job.requested_control = null;
        self.persist() catch |err| {
            job.state = old_state;
            job.revision = old_revision;
            job.error_message = old_error;
            job.completed_bytes = old_completed;
            job.total_bytes = old_total;
            job.retry_at_unix_ms = old_retry_at;
            job.live_received_bytes = old_live_received;
            job.live_total_bytes = old_live_total;
            job.worker_count = old_worker_count;
            job.requested_control = old_requested_control;
            return err;
        };
        if (selected == choice.oldest) {
            self.priority_bypass_count = 0;
        } else if (self.priority_bypass_count < 8) {
            self.priority_bypass_count += 1;
        }
        if (old_error) |message| self.allocator.free(message);
        return task;
    }

    fn activeForHost(self: *Store, url: []const u8) usize {
        const target_host = sourceHost(url);
        if (target_host.len == 0) return max_parallel_downloads_per_host;
        var active: usize = 0;
        for (self.jobs.items) |job| {
            if (job.state != .resolving and job.state != .connecting and job.state != .downloading and job.state != .verifying) continue;
            const host = sourceHost(job.url);
            if (std.ascii.eqlIgnoreCase(host, target_host)) active += 1;
        }
        return active;
    }

    fn sourceHost(url: []const u8) []const u8 {
        if (url.len >= 7 and std.ascii.eqlIgnoreCase(url[0..7], "magnet:")) return "bittorrent";
        if (@import("../protocols/torrent/source.zig").isLocalTorrent(url)) return "local-torrent";
        const uri = std.Uri.parse(url) catch return "";
        return hostString(uri) orelse "";
    }

    fn hostString(uri: std.Uri) ?[]const u8 {
        const host = uri.host orelse return null;
        return switch (host) {
            .raw => |value| value,
            .percent_encoded => |value| value,
        };
    }

    fn copyTaskUnlocked(self: *Store, job: Job) !DownloadTask {
        const id = try self.allocator.dupe(u8, job.id);
        errdefer self.allocator.free(id);
        const url = try self.allocator.dupe(u8, job.url);
        errdefer self.allocator.free(url);
        const name = if (job.name) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (name) |value| self.allocator.free(value);
        const destination = try self.allocator.dupe(u8, job.destination);
        errdefer self.allocator.free(destination);
        const proxy_url = if (self.settings.proxy_url) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (proxy_url) |value| self.allocator.free(value);
        const selected = try duplicateSelectedFiles(self.allocator, job.selected_torrent_files);
        return .{ .id = id, .url = url, .name = name, .destination = destination, .connections = self.connectionsForJob(job), .proxy_mode = self.settings.proxy_mode, .proxy_url = proxy_url, .proxy_authentication_required = self.settings.proxy_authentication_required, .expected_sha256 = decodeSha256(job.expected_sha256), .selected_torrent_files = selected };
    }

    fn connectionsForJob(self: *const Store, job: Job) u8 {
        return switch (self.settings.multipart_mode) {
            .off => 0,
            .fixed => self.settings.default_connections_per_task,
            .auto => @min(self.settings.default_connections_per_task, job.adaptive_connections orelse self.settings.default_connections_per_task),
        };
    }

    pub fn finishDownload(self: *Store, job_id: []const u8, succeeded: bool, error_message: ?[]const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.jobs.items) |*job| {
            if (!std.mem.eql(u8, job.id, job_id)) continue;
            if (job.state != .downloading) return error.InvalidJobControl;
            const old_state = job.state;
            const old_revision = job.revision;
            const old_error = job.error_message;
            const old_requested_control = job.requested_control;
            const old_worker_count = job.worker_count;
            const old_retry_attempts = job.retry_attempts;
            const old_retry_at = job.retry_at_unix_ms;
            const next_revision = try std.math.add(u64, job.revision, 1);
            const owned_error = if (!succeeded and error_message != null)
                try self.allocator.dupe(u8, error_message.?)
            else
                null;
            job.state = if (succeeded) .completed else .failed;
            job.revision = next_revision;
            job.error_message = owned_error;
            job.requested_control = null;
            job.worker_count = 0;
            if (succeeded) job.retry_attempts = 0;
            job.retry_at_unix_ms = null;
            job.live_received_bytes = null;
            job.live_total_bytes = null;
            if (succeeded) {
                const queue = self.queueByID(job.queue_id);
                if (queue != null and queue.?.finish_action != .none) {
                    job.completion_trigger = true;
                    for (self.jobs.items) |other| {
                        if (std.mem.eql(u8, other.queue_id, job.queue_id) and other.state != .completed) {
                            job.completion_trigger = false;
                            break;
                        }
                    }
                }
            }
            self.persist() catch |err| {
                job.state = old_state;
                job.revision = old_revision;
                job.error_message = old_error;
                job.requested_control = old_requested_control;
                job.worker_count = old_worker_count;
                job.retry_attempts = old_retry_attempts;
                job.retry_at_unix_ms = old_retry_at;
                job.completion_trigger = false;
                if (owned_error) |value| self.allocator.free(value);
                return err;
            };
            if (old_error) |value| self.allocator.free(value);
            return;
        }
        return error.JobNotFound;
    }

    /// Called only after a successful transition to completed. It does not
    /// persist an action flag: the transition is the one-shot trigger.
    pub fn completedQueueAction(self: *Store, job_id: []const u8) !?QueueCompletion {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const completed = for (self.jobs.items) |*job| {
            if (std.mem.eql(u8, job.id, job_id)) break job;
        } else return null;
        if (completed.state != .completed or !completed.completion_trigger) return null;
        completed.completion_trigger = false;
        const queue = self.queueByID(completed.queue_id) orelse return null;
        if (queue.finish_action == .none) return null;
        for (self.jobs.items) |job| {
            if (std.mem.eql(u8, job.queue_id, queue.id) and job.state != .completed) return null;
        }
        return .{
            .action = queue.finish_action,
            .custom_app = if (queue.custom_app) |path| try self.allocator.dupe(u8, path) else null,
            .user_command = if (queue.user_command) |command| try self.allocator.dupe(u8, command) else null,
        };
    }

    /// Persist a bounded retry before releasing the worker slot. A later
    /// scheduler tick promotes the job only after its deadline has passed.
    pub fn scheduleTransientRetry(self: *Store, job_id: []const u8, failure: []const u8, minimum_delay_seconds: u32, rate_limited_connections: ?u8) !bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.jobs.items) |*job| {
            if (!std.mem.eql(u8, job.id, job_id)) continue;
            if (job.state != .downloading or job.requested_control != null or job.retry_attempts >= 3) return false;
            const attempt = job.retry_attempts + 1;
            const backoff_seconds: i64 = @as(i64, 1) << @intCast(attempt);
            var random_bytes: [2]u8 = undefined;
            const jitter_permille: i64 = if (self.io.randomSecure(&random_bytes)) |_|
                750 + @as(i64, std.mem.readInt(u16, &random_bytes, .little) % 501)
            else |_|
                1000;
            const jittered_backoff = @max(@as(i64, 1), @divTrunc(backoff_seconds * jitter_permille + 999, 1000));
            const delay_seconds: i64 = @max(jittered_backoff, @min(@as(i64, minimum_delay_seconds), 3600));
            const now_ms: i64 = @intCast(@divTrunc(std.Io.Clock.now(.real, self.io).nanoseconds, std.time.ns_per_ms));
            const next_ms = std.math.add(i64, now_ms, delay_seconds * 1000) catch return error.RetryTimeOverflow;
            const new_connections: ?u8 = if (rate_limited_connections) |count| @max(@as(u8, 1), count / 2) else job.adaptive_connections;
            const message = if (rate_limited_connections != null)
                try std.fmt.allocPrint(self.allocator, "Server limited parallel transfer; retrying in {d}s with {d} connection(s) ({d}/3)", .{ delay_seconds, new_connections.?, attempt })
            else
                try std.fmt.allocPrint(self.allocator, "Temporary transfer error ({s}); retrying in {d}s ({d}/3)", .{ failure, delay_seconds, attempt });
            const old_state = job.state;
            const old_revision = job.revision;
            const old_error = job.error_message;
            const old_worker_count = job.worker_count;
            const old_attempts = job.retry_attempts;
            const old_retry_at = job.retry_at_unix_ms;
            const old_adaptive_connections = job.adaptive_connections;
            const old_live_received = job.live_received_bytes;
            const old_live_total = job.live_total_bytes;
            job.state = .retry_wait;
            job.revision = std.math.add(u64, job.revision, 1) catch {
                self.allocator.free(message);
                return error.RevisionOverflow;
            };
            job.error_message = message;
            job.retry_attempts = attempt;
            job.retry_at_unix_ms = next_ms;
            job.adaptive_connections = new_connections;
            job.worker_count = 0;
            job.live_received_bytes = null;
            job.live_total_bytes = null;
            self.persist() catch |err| {
                job.state = old_state;
                job.revision = old_revision;
                job.error_message = old_error;
                job.retry_attempts = old_attempts;
                job.retry_at_unix_ms = old_retry_at;
                job.adaptive_connections = old_adaptive_connections;
                job.worker_count = old_worker_count;
                job.live_received_bytes = old_live_received;
                job.live_total_bytes = old_live_total;
                self.allocator.free(message);
                return err;
            };
            if (old_error) |value| self.allocator.free(value);
            return true;
        }
        return error.JobNotFound;
    }

    pub fn promoteDueRetries(self: *Store) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const now_ms: i64 = @intCast(@divTrunc(std.Io.Clock.now(.real, self.io).nanoseconds, std.time.ns_per_ms));
        for (self.jobs.items) |*job| {
            if (job.state != .retry_wait or (job.retry_at_unix_ms orelse 0) > now_ms) continue;
            const old_revision = job.revision;
            const old_retry_at = job.retry_at_unix_ms;
            job.revision = try std.math.add(u64, job.revision, 1);
            job.state = .queued;
            job.retry_at_unix_ms = null;
            self.persist() catch |err| {
                job.revision = old_revision;
                job.state = .retry_wait;
                job.retry_at_unix_ms = old_retry_at;
                return err;
            };
        }
    }

    pub fn requestStopJson(self: *Store, request_id: std.json.Value, job_id: []const u8, action: StopAction, expected_revision: u64) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.jobs.items) |*job| {
            if (!std.mem.eql(u8, job.id, job_id)) continue;
            if (job.revision != expected_revision) return error.StaleJobRevision;
            if (job.state != .downloading or job.requested_control != null) return error.InvalidJobControl;
            const previous_revision = job.revision;
            const next_revision = try std.math.add(u64, job.revision, 1);
            job.revision = next_revision;
            job.requested_control = action;
            self.persist() catch |err| {
                job.revision = previous_revision;
                job.requested_control = null;
                return err;
            };
            const revision = try std.fmt.allocPrint(self.allocator, "{d}", .{job.revision});
            defer self.allocator.free(revision);
            return std.json.Stringify.valueAlloc(self.allocator, .{
                .jsonrpc = "2.0",
                .id = request_id,
                .result = .{ .job_id = job.id, .state = job.state, .revision = revision, .duplicate = false },
            }, .{});
        }
        return error.JobNotFound;
    }

    pub fn requestedControl(self: *Store, job_id: []const u8) ?StopAction {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.jobs.items) |job| {
            if (std.mem.eql(u8, job.id, job_id) and job.state == .downloading) return job.requested_control;
        }
        return null;
    }

    pub fn isDownloading(self: *Store, job_id: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.jobs.items) |job| {
            if (std.mem.eql(u8, job.id, job_id)) return job.state == .downloading;
        }
        return false;
    }

    pub fn finishStoppedDownload(self: *Store, job_id: []const u8, next_state: State) !void {
        if (next_state != .paused and next_state != .canceled) return error.InvalidJobControl;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.jobs.items) |*job| {
            if (!std.mem.eql(u8, job.id, job_id)) continue;
            if (job.state != .downloading or job.requested_control == null) return error.InvalidJobControl;
            const old_state = job.state;
            const old_revision = job.revision;
            const old_requested = job.requested_control;
            const old_completed = job.completed_bytes;
            const old_total = job.total_bytes;
            const old_worker_count = job.worker_count;
            const next_revision = try std.math.add(u64, job.revision, 1);
            job.state = next_state;
            job.requested_control = null;
            job.worker_count = 0;
            job.live_received_bytes = null;
            job.live_total_bytes = null;
            if (next_state == .canceled) {
                job.completed_bytes = 0;
                job.total_bytes = null;
            }
            job.revision = next_revision;
            self.persist() catch |err| {
                job.state = old_state;
                job.revision = old_revision;
                job.requested_control = old_requested;
                job.completed_bytes = old_completed;
                job.total_bytes = old_total;
                job.worker_count = old_worker_count;
                return err;
            };
            return;
        }
        return error.JobNotFound;
    }

    pub fn finishScheduledDownload(self: *Store, job_id: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.jobs.items) |*job| {
            if (!std.mem.eql(u8, job.id, job_id)) continue;
            if (job.state != .downloading or job.requested_control != null) return error.InvalidJobControl;
            const previous_worker_count = job.worker_count;
            const next_revision = try std.math.add(u64, job.revision, 1);
            job.state = .scheduled;
            job.revision = next_revision;
            job.worker_count = 0;
            job.live_received_bytes = null;
            job.live_total_bytes = null;
            self.persist() catch |err| {
                job.state = .downloading;
                job.revision -= 1;
                job.worker_count = previous_worker_count;
                return err;
            };
            return;
        }
        return error.JobNotFound;
    }

    pub fn updateProgress(self: *Store, job_id: []const u8, completed_bytes: u64, total_bytes: ?u64, durable: bool) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.jobs.items) |*job| {
            if (!std.mem.eql(u8, job.id, job_id) or job.state != .downloading) continue;
            job.live_received_bytes = completed_bytes;
            job.live_total_bytes = total_bytes;
            if (!durable) {
                self.recordChange(job.id);
                return;
            }
            const previous_completed = job.completed_bytes;
            const previous_total = job.total_bytes;
            job.completed_bytes = completed_bytes;
            job.total_bytes = total_bytes;
            self.persist() catch |err| {
                job.completed_bytes = previous_completed;
                job.total_bytes = previous_total;
                return err;
            };
            return;
        }
    }

    pub fn updateWorkerProgress(self: *Store, job_id: []const u8, worker_id: u32, start: u64, end: u64, downloaded: u64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.jobs.items) |*job| {
            if (!std.mem.eql(u8, job.id, job_id) or job.state != .downloading) continue;
            var slot: ?usize = null;
            for (job.workers[0..job.worker_count], 0..) |worker, index| {
                if (worker.worker_id == worker_id) {
                    slot = index;
                    break;
                }
            }
            const index = slot orelse blk: {
                if (job.worker_count == job.workers.len) return;
                const next = job.worker_count;
                job.worker_count += 1;
                break :blk next;
            };
            job.workers[index] = .{ .worker_id = worker_id, .start = start, .end = end, .downloaded = downloaded };
            self.recordChange(job.id);
            return;
        }
    }

    pub fn resetTorrentStats(self: *Store, job_id: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.jobs.items) |*job| {
            if (!std.mem.eql(u8, job.id, job_id)) continue;
            job.torrent_active_peer_len = 0;
            job.torrent_active_peer_count = 0;
            job.torrent_peer_count = null;
            job.torrent_seeder_count = null;
            job.torrent_leecher_count = null;
            self.recordChange(job.id);
            return;
        }
    }

    pub fn updateTorrentPeer(self: *Store, job_id: []const u8, address: ?[]const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.jobs.items) |*job| {
            if (!std.mem.eql(u8, job.id, job_id) or job.state != .downloading) continue;
            if (address) |value| {
                job.torrent_active_peer_count +|= 1;
                job.torrent_active_peer_len = 0;
                if (job.torrent_active_peer_count == 1 and value.len <= job.torrent_active_peer.len) {
                    @memcpy(job.torrent_active_peer[0..value.len], value);
                    job.torrent_active_peer_len = value.len;
                }
            } else {
                job.torrent_active_peer_count -|= 1;
                job.torrent_active_peer_len = 0;
            }
            self.recordChange(job.id);
            return;
        }
    }

    pub fn updateTorrentStats(self: *Store, job_id: []const u8, peers: u32, seeders: ?u32, leechers: ?u32) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.jobs.items) |*job| {
            if (!std.mem.eql(u8, job.id, job_id) or job.state != .downloading) continue;
            job.torrent_peer_count = peers;
            if (seeders) |count| job.torrent_seeder_count = count;
            if (leechers) |count| job.torrent_leecher_count = count;
            self.recordChange(job.id);
            return;
        }
    }

    fn newId(self: *Store) ![]u8 {
        var bytes: [16]u8 = undefined;
        try self.io.randomSecure(&bytes);
        const hex = "0123456789abcdef";
        const id = try self.allocator.alloc(u8, 36);
        var index: usize = 0;
        for (bytes, 0..) |byte, i| {
            if (i == 4 or i == 6 or i == 8 or i == 10) {
                id[index] = '-';
                index += 1;
            }
            id[index] = hex[byte >> 4];
            id[index + 1] = hex[byte & 0x0f];
            index += 2;
        }
        return id;
    }

    fn duplicateJob(self: *Store, input: AddInput) !Job {
        const id = try self.newId();
        errdefer self.allocator.free(id);
        const url = try self.allocator.dupe(u8, input.url);
        errdefer self.allocator.free(url);
        const reference_url = if (input.reference_url) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (reference_url) |value| self.allocator.free(value);
        const name = if (input.name) |text| try self.allocator.dupe(u8, text) else null;
        errdefer if (name) |text| self.allocator.free(text);
        const destination = try self.allocator.dupe(u8, input.destination);
        errdefer self.allocator.free(destination);
        const idempotency_key = try self.allocator.dupe(u8, input.idempotency_key);
        errdefer self.allocator.free(idempotency_key);
        const queue_id = try self.allocator.dupe(u8, input.queue_id);
        errdefer self.allocator.free(queue_id);
        const expected_sha256 = if (input.expected_sha256) |digest| try self.allocator.dupe(u8, digest) else null;
        errdefer if (expected_sha256) |digest| self.allocator.free(digest);
        const selected_torrent_files = try duplicateSelectedFiles(self.allocator, input.selected_torrent_files);
        errdefer freeSelectedFiles(self.allocator, selected_torrent_files);
        return .{
            .id = id,
            .queue_id = queue_id,
            .url = url,
            .reference_url = reference_url,
            .name = name,
            .destination = destination,
            .idempotency_key = idempotency_key,
            .expected_sha256 = expected_sha256,
            .selected_torrent_files = selected_torrent_files,
            .priority = input.priority,
            .bandwidth_limit_bytes_per_second = input.bandwidth_limit_bytes_per_second,
        };
    }

    fn freeJob(self: *Store, job: Job) void {
        self.allocator.free(job.id);
        self.allocator.free(job.queue_id);
        self.allocator.free(job.url);
        if (job.reference_url) |value| self.allocator.free(value);
        if (job.name) |name| self.allocator.free(name);
        self.allocator.free(job.destination);
        self.allocator.free(job.idempotency_key);
        if (job.expected_sha256) |digest| self.allocator.free(digest);
        freeSelectedFiles(self.allocator, job.selected_torrent_files);
        if (job.error_message) |message| self.allocator.free(message);
    }

    fn load(self: *Store) !void {
        if (comptime builtin.os.tag != .windows) {
            const path_z = try self.allocator.dupeSentinel(u8, self.file_path, 0);
            defer self.allocator.free(path_z);
            if (posix_stat.get(path_z, false)) |existing_stat| {
                if (existing_stat.uid != posix_stat.currentUid() or !posix_stat.isRegularFile(existing_stat))
                    return error.UnsafeJobStoreFile;
                if (chmod(path_z, 0o600) != 0) return error.UnsafeJobStoreFile;
            }
        }
        var file = std.Io.Dir.openFileAbsolute(self.io, self.file_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close(self.io);
        const stat = try file.stat(self.io);
        if (stat.size > 16 * 1024 * 1024) return error.JobStoreTooLarge;
        var buffer: [4096]u8 = undefined;
        var reader = file.reader(self.io, &buffer);
        const bytes = try reader.interface.allocRemaining(self.allocator, .limited(stat.size));
        defer self.allocator.free(bytes);
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, bytes, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidJobStore;
        const version = parsed.value.object.get("version") orelse return error.InvalidJobStore;
        if (version != .integer or version.integer != 1) return error.InvalidJobStore;
        const jobs_value = parsed.value.object.get("jobs") orelse return error.InvalidJobStore;
        if (jobs_value != .array) return error.InvalidJobStore;
        for (jobs_value.array.items) |value| try self.loadJob(value);

        var recovered = false;
        for (self.jobs.items) |*job| {
            switch (job.state) {
                .resolving, .connecting, .downloading, .verifying => {
                    const was_canceling = job.state == .downloading and job.requested_control == .cancel;
                    job.state = if (job.state == .downloading and job.requested_control != null)
                        if (job.requested_control.? == .pause) .paused else .canceled
                    else
                        .retry_wait;
                    job.requested_control = null;
                    if (was_canceling) {
                        self.deletePartialFiles(job.*) catch {};
                        job.completed_bytes = 0;
                        job.total_bytes = null;
                    }
                    job.revision = try std.math.add(u64, job.revision, 1);
                    recovered = true;
                },
                else => {},
            }
        }
        if (recovered) try self.persist();
    }

    fn loadJob(self: *Store, value: std.json.Value) !void {
        if (value != .object) return error.InvalidJobStore;
        const object = value.object;
        const id = try getString(object, "id");
        const queue_id = if (object.get("queue_id")) |field| if (field == .string) field.string else return error.InvalidJobStore else "main";
        const url = try getString(object, "url");
        const reference_value = object.get("reference_url") orelse .null;
        if (reference_value != .null and reference_value != .string) return error.InvalidJobStore;
        const reference_url = if (reference_value == .string) reference_value.string else null;
        if (reference_url) |reference| if (!validReferenceURL(reference)) return error.InvalidJobStore;
        const destination = try getString(object, "destination");
        const key = try getString(object, "idempotency_key");
        const state_value = object.get("state") orelse return error.InvalidJobStore;
        if (state_value != .string) return error.InvalidJobStore;
        const state = std.meta.stringToEnum(State, state_value.string) orelse return error.InvalidJobStore;
        const error_value = object.get("error_message") orelse .null;
        if (error_value != .null and error_value != .string) return error.InvalidJobStore;
        const error_message = if (error_value == .string) try self.allocator.dupe(u8, error_value.string) else null;
        const completed_value = object.get("completed_bytes") orelse std.json.Value{ .integer = 0 };
        if (completed_value != .integer or completed_value.integer < 0) return error.InvalidJobStore;
        const total_value = object.get("total_bytes") orelse .null;
        if (total_value != .null and (total_value != .integer or total_value.integer < 0)) return error.InvalidJobStore;
        const total_bytes = if (total_value == .integer and total_value.integer >= 0) @as(?u64, @intCast(total_value.integer)) else null;
        const requested_value = object.get("requested_control") orelse .null;
        const requested_control: ?StopAction = if (requested_value == .string)
            std.meta.stringToEnum(StopAction, requested_value.string) orelse return error.InvalidJobStore
        else if (requested_value == .null)
            null
        else
            return error.InvalidJobStore;
        const priority_value = object.get("priority") orelse std.json.Value{ .integer = 0 };
        if (priority_value != .integer or priority_value.integer < -100 or priority_value.integer > 100)
            return error.InvalidJobStore;
        const bandwidth_value = object.get("bandwidth_limit_bytes_per_second") orelse std.json.Value{ .integer = 0 };
        if (bandwidth_value != .integer or bandwidth_value.integer < 0 or bandwidth_value.integer > 1_000_000_000_000)
            return error.InvalidJobStore;
        const revision_value = object.get("revision") orelse return error.InvalidJobStore;
        if (revision_value != .integer or revision_value.integer <= 0) return error.InvalidJobStore;
        const name_value = object.get("name") orelse .null;
        if (name_value != .null and name_value != .string) return error.InvalidJobStore;
        if (name_value == .string and !validName(name_value.string)) return error.InvalidJobStore;
        const name = if (name_value == .string) try self.allocator.dupe(u8, name_value.string) else null;
        const digest_value = object.get("expected_sha256") orelse .null;
        if (digest_value != .null and (digest_value != .string or !validSha256(digest_value.string))) return error.InvalidJobStore;
        const expected_sha256 = if (digest_value == .string) try self.allocator.dupe(u8, digest_value.string) else null;
        const selected_value = object.get("selected_torrent_files") orelse .null;
        const selected_torrent_files = if (selected_value == .array) blk: {
            if (selected_value.array.items.len == 0 or selected_value.array.items.len > 10_000) return error.InvalidJobStore;
            const paths = try self.allocator.alloc([]const u8, selected_value.array.items.len);
            var count: usize = 0;
            var total_path_bytes: usize = 0;
            errdefer {
                for (paths[0..count]) |path| self.allocator.free(path);
                self.allocator.free(paths);
            }
            for (selected_value.array.items) |item| {
                if (item != .string or item.string.len == 0 or item.string.len > 16_384) return error.InvalidJobStore;
                total_path_bytes += item.string.len;
                if (total_path_bytes > 1024 * 1024) return error.InvalidJobStore;
                paths[count] = try self.allocator.dupe(u8, item.string);
                count += 1;
            }
            break :blk paths;
        } else if (selected_value == .null) null else return error.InvalidJobStore;
        const attempts_value = object.get("retry_attempts") orelse std.json.Value{ .integer = 0 };
        if (attempts_value != .integer or attempts_value.integer < 0 or attempts_value.integer > 3) return error.InvalidJobStore;
        const retry_at_value = object.get("retry_at_unix_ms") orelse .null;
        if (retry_at_value != .null and (retry_at_value != .integer or retry_at_value.integer < 0)) return error.InvalidJobStore;
        const adaptive_value = object.get("adaptive_connections") orelse .null;
        if (adaptive_value != .null and (adaptive_value != .integer or adaptive_value.integer < 1 or adaptive_value.integer > 32)) return error.InvalidJobStore;
        try self.jobs.append(self.allocator, .{
            .id = try self.allocator.dupe(u8, id),
            .queue_id = try self.allocator.dupe(u8, queue_id),
            .url = try self.allocator.dupe(u8, url),
            .reference_url = if (reference_url) |reference| try self.allocator.dupe(u8, reference) else null,
            .name = name,
            .destination = try self.allocator.dupe(u8, destination),
            .idempotency_key = try self.allocator.dupe(u8, key),
            .expected_sha256 = expected_sha256,
            .selected_torrent_files = selected_torrent_files,
            .state = state,
            .revision = @intCast(revision_value.integer),
            .error_message = error_message,
            .retry_attempts = @intCast(attempts_value.integer),
            .retry_at_unix_ms = if (retry_at_value == .integer) retry_at_value.integer else null,
            .adaptive_connections = if (adaptive_value == .integer) @intCast(adaptive_value.integer) else null,
            .completed_bytes = @intCast(completed_value.integer),
            .total_bytes = total_bytes,
            .requested_control = requested_control,
            .priority = @intCast(priority_value.integer),
            .bandwidth_limit_bytes_per_second = @intCast(bandwidth_value.integer),
        });
    }

    fn persist(self: *Store) !void {
        var persisted_jobs: std.ArrayList(PersistedJob) = .empty;
        defer persisted_jobs.deinit(self.allocator);
        for (self.jobs.items) |job| try persisted_jobs.append(self.allocator, .{
            .id = job.id,
            .queue_id = job.queue_id,
            .url = job.url,
            .reference_url = job.reference_url,
            .name = job.name,
            .destination = job.destination,
            .idempotency_key = job.idempotency_key,
            .expected_sha256 = job.expected_sha256,
            .selected_torrent_files = job.selected_torrent_files,
            .state = job.state,
            .revision = job.revision,
            .error_message = job.error_message,
            .retry_attempts = job.retry_attempts,
            .retry_at_unix_ms = job.retry_at_unix_ms,
            .adaptive_connections = job.adaptive_connections,
            .completed_bytes = job.completed_bytes,
            .total_bytes = job.total_bytes,
            .requested_control = job.requested_control,
            .priority = job.priority,
            .bandwidth_limit_bytes_per_second = job.bandwidth_limit_bytes_per_second,
        });
        const data = try std.json.Stringify.valueAlloc(self.allocator, .{
            .version = 1,
            .jobs = persisted_jobs.items,
        }, .{});
        defer self.allocator.free(data);
        var atomic = try std.Io.Dir.createFileAtomic(.cwd(), self.io, self.file_path, .{
            .permissions = if (builtin.os.tag == .windows) .default_file else std.Io.File.Permissions.fromMode(0o600),
            .make_path = true,
            .replace = true,
        });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, data);
        try atomic.replace(self.io);
        self.recordChange(null);
    }

    fn loadSettings(self: *Store) !void {
        if (comptime builtin.os.tag != .windows) {
            const path_z = try self.allocator.dupeSentinel(u8, self.settings_path, 0);
            defer self.allocator.free(path_z);
            if (posix_stat.get(path_z, false)) |existing| {
                if (existing.uid != posix_stat.currentUid() or !posix_stat.isRegularFile(existing)) return error.UnsafeSettingsFile;
                if (chmod(path_z, 0o600) != 0) return error.UnsafeSettingsFile;
            }
        }
        var file = std.Io.Dir.openFileAbsolute(self.io, self.settings_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
            error.FileNotFound => {
                self.settings = try self.duplicateSettings(.{});
                self.settings_owned = true;
                try self.persistSettings();
                return;
            },
            else => return err,
        };
        var file_open = true;
        defer if (file_open) file.close(self.io);
        const stat = try file.stat(self.io);
        if (stat.size > 1024 * 1024) return error.SettingsTooLarge;
        var buffer: [4096]u8 = undefined;
        var reader = file.reader(self.io, &buffer);
        const bytes = try reader.interface.allocRemaining(self.allocator, .limited(stat.size));
        defer self.allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(Settings, self.allocator, bytes, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        var migrated = parsed.value;
        const needs_migration = switch (migrated.schema_version) {
            1 => true,
            2 => true,
            3 => false,
            else => return error.UnsupportedSettingsVersion,
        };
        if (migrated.schema_version < 3) {
            var main_queue = default_queues;
            main_queue[0].schedule_enabled = migrated.queue_schedule_enabled;
            main_queue[0].schedule_slots = migrated.queue_schedule_slots;
            main_queue[0].max_active = migrated.max_concurrent_tasks;
            migrated.queues = &main_queue;
            migrated.schema_version = 3;
            try validateSettings(migrated);
            self.settings = try self.duplicateSettings(migrated);
            self.settings_owned = true;
            file.close(self.io);
            file_open = false;
            try self.persistSettings();
            return;
        }
        try validateSettings(migrated);
        self.settings = try self.duplicateSettings(migrated);
        self.settings_owned = true;
        if (needs_migration) {
            file.close(self.io);
            file_open = false;
            try self.persistSettings();
        }
    }

    fn persistSettings(self: *Store) !void {
        const data = try std.json.Stringify.valueAlloc(self.allocator, self.settings, .{});
        defer self.allocator.free(data);
        var atomic = try std.Io.Dir.createFileAtomic(.cwd(), self.io, self.settings_path, .{
            .permissions = if (builtin.os.tag == .windows) .default_file else std.Io.File.Permissions.fromMode(0o600),
            .make_path = true,
            .replace = true,
        });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, data);
        try atomic.replace(self.io);
    }

    fn validateSettings(value: Settings) !void {
        if (value.schema_version != 3 or value.max_concurrent_tasks == 0 or value.max_concurrent_tasks > 32 or
            value.default_connections_per_task == 0 or value.default_connections_per_task > 32 or
            value.default_download_folder.len > 4096) return error.InvalidSettings;
        if (value.queues.len == 0 or value.queues.len > 64 or
            value.browser_grab_extensions.len > 4096 or value.language.len == 0 or value.language.len > 64 or
            value.stop_seeding_after_minutes > 525_600) return error.InvalidSettings;
        var found_main = false;
        for (value.queues, 0..) |queue, index| {
            if (queue.id.len == 0 or queue.id.len > 64 or queue.name.len == 0 or queue.name.len > 80 or
                queue.max_active == 0 or queue.max_active > 32 or !std.unicode.utf8ValidateSlice(queue.name)) return error.InvalidSettings;
            if (std.mem.eql(u8, queue.id, "main")) {
                found_main = true;
                if (!std.mem.eql(u8, queue.name, "main")) return error.InvalidSettings;
            }
            if (queue.finish_action == .custom_app and (queue.custom_app == null or !std.fs.path.isAbsolute(queue.custom_app.?))) return error.InvalidSettings;
            if (queue.finish_action == .user_command and (queue.user_command == null or queue.user_command.?.len == 0 or queue.user_command.?.len > 4096 or std.mem.indexOfScalar(u8, queue.user_command.?, 0) != null)) return error.InvalidSettings;
            for (value.queues[0..index]) |previous| {
                if (std.mem.eql(u8, previous.id, queue.id) or std.ascii.eqlIgnoreCase(previous.name, queue.name)) return error.InvalidSettings;
            }
        }
        if (!found_main) return error.InvalidSettings;
        if (value.proxy_mode == .custom) {
            const endpoint = value.proxy_url orelse return error.InvalidSettings;
            if (endpoint.len == 0 or endpoint.len > 2048) return error.InvalidSettings;
            const uri = std.Uri.parse(endpoint) catch return error.InvalidSettings;
            if (uri.host == null or uri.port == null or uri.port.? == 0 or uri.user != null or uri.password != null or
                uri.query != null or uri.fragment != null) return error.InvalidSettings;
            if (!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https") and
                !std.mem.eql(u8, uri.scheme, "socks5")) return error.InvalidSettings;
        }
        if (value.bandwidth_limit_bytes_per_second > 1_000_000_000_000 or value.scheduled_bandwidth_limit_bytes_per_second > 1_000_000_000_000) return error.InvalidSettings;
    }

    fn deletePartialFiles(self: *Store, job: Job) !void {
        const destination = try self.destinationPath(job);
        defer self.allocator.free(destination);
        const part_path = try std.fmt.allocPrint(self.allocator, "{s}.part", .{destination});
        defer self.allocator.free(part_path);
        const journal_path = try std.fmt.allocPrint(self.allocator, "{s}.odm", .{part_path});
        defer self.allocator.free(journal_path);
        const segment_journal = try std.fmt.allocPrint(self.allocator, "{s}.sdr", .{part_path});
        defer self.allocator.free(segment_journal);
        const ftp_journal = try std.fmt.allocPrint(self.allocator, "{s}.ftpj", .{part_path});
        defer self.allocator.free(ftp_journal);
        const cwd = std.Io.Dir.cwd();
        cwd.deleteFile(self.io, part_path) catch {};
        cwd.deleteFile(self.io, journal_path) catch {};
        cwd.deleteFile(self.io, segment_journal) catch {};
        cwd.deleteFile(self.io, ftp_journal) catch {};
    }

    fn deletePartialFilesStrict(self: *Store, job: Job) !void {
        const destination = try self.destinationPath(job);
        defer self.allocator.free(destination);
        const part_path = try std.fmt.allocPrint(self.allocator, "{s}.part", .{destination});
        defer self.allocator.free(part_path);
        const journal_path = try std.fmt.allocPrint(self.allocator, "{s}.odm", .{part_path});
        defer self.allocator.free(journal_path);
        const segment_journal = try std.fmt.allocPrint(self.allocator, "{s}.sdr", .{part_path});
        defer self.allocator.free(segment_journal);
        const ftp_journal = try std.fmt.allocPrint(self.allocator, "{s}.ftpj", .{part_path});
        defer self.allocator.free(ftp_journal);
        const cwd = std.Io.Dir.cwd();
        try deleteFileIfPresent(cwd, self.io, part_path);
        try deleteFileIfPresent(cwd, self.io, journal_path);
        try deleteFileIfPresent(cwd, self.io, segment_journal);
        try deleteFileIfPresent(cwd, self.io, ftp_journal);
    }

    fn destinationPath(self: *Store, job: Job) ![]u8 {
        var filename: []const u8 = undefined;
        if (job.name) |name| {
            filename = name;
        } else if (job.url.len >= 7 and std.ascii.eqlIgnoreCase(job.url[0..7], "magnet:")) {
            var link = try @import("../protocols/torrent/magnet.zig").inspect(self.allocator, job.url);
            defer link.deinit(self.allocator);
            if (link.display_name) |name| {
                if (@import("../protocols/torrent/metainfo.zig").safeComponent(name)) return std.fs.path.join(self.allocator, &.{ job.destination, name });
            }
            var fallback: [48]u8 = undefined;
            const name = try std.fmt.bufPrint(&fallback, "torrent-{s}.download", .{job.id[0..8]});
            return std.fs.path.join(self.allocator, &.{ job.destination, name });
        } else {
            const uri = try std.Uri.parse(job.url);
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
                filename = try std.fmt.bufPrint(&fallback, "download-{s}.bin", .{job.id[0..8]});
            }
        }
        return std.fs.path.join(self.allocator, &.{ job.destination, filename });
    }

    /// Existing records can predate destination reservations. Active records
    /// always own their partial path; failed/canceled records own it only while
    /// their partial file is still present.
    fn destinationOccupied(self: *Store, candidate: Job, active_only: bool) !bool {
        const target = try self.destinationPath(candidate);
        defer self.allocator.free(target);
        if (!active_only) {
            if (try self.ioStatExists(target)) return error.DestinationExists;
        }
        for (self.jobs.items) |other| {
            if (std.mem.eql(u8, other.id, candidate.id) or other.state == .completed) continue;
            const active = other.state == .resolving or other.state == .connecting or
                other.state == .downloading or other.state == .verifying;
            if (active_only and !active) continue;
            const existing = try self.destinationPath(other);
            defer self.allocator.free(existing);
            if (!std.mem.eql(u8, target, existing)) continue;
            if (other.state == .failed or other.state == .canceled) {
                const partial = try std.fmt.allocPrint(self.allocator, "{s}.part", .{existing});
                defer self.allocator.free(partial);
                if (!try self.ioStatExists(partial)) continue;
            }
            return true;
        }
        return false;
    }

    fn ioStatExists(self: *Store, path: []const u8) !bool {
        return if (std.Io.Dir.cwd().statFile(self.io, path, .{})) |_| true else |err| switch (err) {
            error.FileNotFound => false,
            else => return err,
        };
    }
};

const Summary = struct {
    job_id: []const u8,
    queue_id: []const u8,
    url: []const u8,
    reference_url: ?[]const u8 = null,
    name: ?[]const u8,
    destination: []const u8,
    expected_sha256: ?[]const u8,
    state: State,
    revision: []const u8,
    error_message: ?[]const u8,
    retry_attempts: u8,
    retry_at_unix_ms: ?[]const u8,
    completed_bytes: []const u8,
    received_bytes: ?[]const u8,
    total_bytes: ?[]const u8,
    requested_control: ?StopAction,
    priority: i32,
    bandwidth_limit_bytes_per_second: u64,
    workers: []const WorkerProgress,
    torrent_active_peer: ?[]const u8,
    torrent_active_peer_count: u32,
    torrent_peer_count: ?u32,
    torrent_seeder_count: ?u32,
    torrent_leecher_count: ?u32,
};

fn makeSummary(allocator: std.mem.Allocator, job: *const Job) !Summary {
    const revision = try std.fmt.allocPrint(allocator, "{d}", .{job.revision});
    errdefer allocator.free(revision);
    const retry_at: ?[]const u8 = if (job.retry_at_unix_ms) |value| try std.fmt.allocPrint(allocator, "{d}", .{value}) else null;
    errdefer if (retry_at) |value| allocator.free(value);
    const completed = try decimalAlloc(allocator, job.completed_bytes);
    errdefer allocator.free(completed);
    const received: ?[]const u8 = if (job.live_received_bytes) |value| try decimalAlloc(allocator, value) else null;
    errdefer if (received) |value| allocator.free(value);
    const total: ?[]const u8 = if (job.live_total_bytes orelse job.total_bytes) |value| try decimalAlloc(allocator, value) else null;
    errdefer if (total) |value| allocator.free(value);
    return .{
        .job_id = job.id,
        .queue_id = job.queue_id,
        .url = redactUrl(job.url),
        .reference_url = job.reference_url,
        .name = job.name,
        .destination = job.destination,
        .expected_sha256 = job.expected_sha256,
        .state = job.state,
        .revision = revision,
        .error_message = job.error_message,
        .retry_attempts = job.retry_attempts,
        .retry_at_unix_ms = retry_at,
        .completed_bytes = completed,
        .received_bytes = received,
        .total_bytes = total,
        .requested_control = job.requested_control,
        .priority = job.priority,
        .bandwidth_limit_bytes_per_second = job.bandwidth_limit_bytes_per_second,
        .workers = job.workers[0..job.worker_count],
        .torrent_active_peer = if (job.state == .downloading and job.torrent_active_peer_len > 0) job.torrent_active_peer[0..job.torrent_active_peer_len] else null,
        .torrent_active_peer_count = if (job.state == .downloading) job.torrent_active_peer_count else 0,
        .torrent_peer_count = job.torrent_peer_count,
        .torrent_seeder_count = job.torrent_seeder_count,
        .torrent_leecher_count = job.torrent_leecher_count,
    };
}

fn freeSummary(allocator: std.mem.Allocator, summary: Summary) void {
    allocator.free(summary.revision);
    if (summary.retry_at_unix_ms) |value| allocator.free(value);
    allocator.free(summary.completed_bytes);
    if (summary.received_bytes) |value| allocator.free(value);
    if (summary.total_bytes) |value| allocator.free(value);
}

const PersistedJob = struct {
    id: []const u8,
    queue_id: []const u8,
    url: []const u8,
    reference_url: ?[]const u8 = null,
    name: ?[]const u8,
    destination: []const u8,
    idempotency_key: []const u8,
    expected_sha256: ?[]const u8,
    selected_torrent_files: ?[]const []const u8,
    state: State,
    revision: u64,
    error_message: ?[]const u8,
    retry_attempts: u8,
    retry_at_unix_ms: ?i64,
    adaptive_connections: ?u8,
    completed_bytes: u64,
    total_bytes: ?u64,
    requested_control: ?StopAction,
    priority: i32,
    bandwidth_limit_bytes_per_second: u64,
};

fn duplicateSelectedFiles(allocator: std.mem.Allocator, selected: ?[]const []const u8) !?[]const []const u8 {
    const files = selected orelse return null;
    const copy = try allocator.alloc([]const u8, files.len);
    var count: usize = 0;
    errdefer {
        for (copy[0..count]) |path| allocator.free(path);
        allocator.free(copy);
    }
    for (files) |path| {
        copy[count] = try allocator.dupe(u8, path);
        count += 1;
    }
    return copy;
}

fn freeSelectedFiles(allocator: std.mem.Allocator, selected: ?[]const []const u8) void {
    if (selected) |files| {
        for (files) |path| allocator.free(path);
        allocator.free(files);
    }
}

fn decimalAlloc(allocator: std.mem.Allocator, value: u64) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{d}", .{value});
}

fn validReferenceURL(value: []const u8) bool {
    if (value.len == 0 or value.len > 8192 or !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    const uri = std.Uri.parse(value) catch return false;
    return (std.ascii.eqlIgnoreCase(uri.scheme, "http") or std.ascii.eqlIgnoreCase(uri.scheme, "https")) and
        uri.host != null and uri.user == null and uri.password == null and uri.fragment == null;
}

fn validateInput(allocator: std.mem.Allocator, io: std.Io, input: AddInput) !void {
    if (input.reference_url) |value| if (!validReferenceURL(value)) return error.InvalidJob;
    if (input.expected_sha256) |digest| if (!validSha256(digest)) return error.InvalidJob;
    if (input.url.len == 0 or input.url.len > 8192) return error.InvalidJob;
    if (input.priority < -100 or input.priority > 100) return error.InvalidJob;
    if (input.bandwidth_limit_bytes_per_second > 1_000_000_000_000) return error.InvalidJob;
    if (input.torrent_info_hash) |hash| {
        if (hash.len != 40) return error.InvalidJob;
        for (hash) |digit| if (!std.ascii.isHex(digit)) return error.InvalidJob;
    }
    if (input.url.len >= 7 and std.ascii.eqlIgnoreCase(input.url[0..7], "magnet:")) {
        if (input.selected_torrent_files != null or input.torrent_info_hash != null) return error.InvalidJob;
        var link = @import("../protocols/torrent/magnet.zig").inspect(allocator, input.url) catch return error.InvalidJob;
        defer link.deinit(allocator);
    } else if (@import("../protocols/torrent/source.zig").isLocalTorrent(input.url)) {
        const path = @import("../protocols/torrent/source.zig").pathAlloc(allocator, input.url) catch return error.InvalidJob;
        defer allocator.free(path);
        const torrent = @import("../protocols/torrent/metainfo.zig");
        const bytes = std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(torrent.max_metainfo_bytes)) catch return error.InvalidJob;
        defer allocator.free(bytes);
        const map = torrent.inspectFileMap(allocator, bytes) catch return error.InvalidJob;
        defer map.deinit(allocator);
        if (input.selected_torrent_files) |selected| {
            if (selected.len == 0 or selected.len > map.files.len or map.files.len <= 1 or input.expected_sha256 != null or input.torrent_info_hash == null) return error.InvalidJob;
            var available = std.StringHashMap(void).init(allocator);
            defer available.deinit();
            for (map.files) |file| try available.put(file.path, {});
            var seen = std.StringHashMap(void).init(allocator);
            defer seen.deinit();
            var total_path_bytes: usize = 0;
            for (selected) |selected_path| {
                if (selected_path.len == 0 or selected_path.len > 16_384) return error.InvalidJob;
                total_path_bytes += selected_path.len;
                if (total_path_bytes > 1024 * 1024) return error.InvalidJob;
                if (!available.contains(selected_path) or seen.contains(selected_path)) return error.InvalidJob;
                try seen.put(selected_path, {});
            }
        }
        if (input.name == null) return error.InvalidJob;
    } else {
        if (input.selected_torrent_files != null or input.torrent_info_hash != null) return error.InvalidJob;
        const uri = std.Uri.parse(input.url) catch return error.InvalidJob;
        if ((!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https") and
            !std.ascii.eqlIgnoreCase(uri.scheme, "ftp") and !std.ascii.eqlIgnoreCase(uri.scheme, "ftps")) or
            uri.host == null or uri.user != null or uri.password != null or uri.fragment != null)
            return error.InvalidJob;
        if ((std.ascii.eqlIgnoreCase(uri.scheme, "ftp") or std.ascii.eqlIgnoreCase(uri.scheme, "ftps")) and uri.query != null) return error.InvalidJob;
    }
    if (input.name) |name| {
        if (!validName(name)) return error.InvalidJob;
        if ((input.url.len >= 7 and std.ascii.eqlIgnoreCase(input.url[0..7], "magnet:") or
            @import("../protocols/torrent/source.zig").isLocalTorrent(input.url)) and
            !@import("../protocols/torrent/metainfo.zig").safeComponent(name)) return error.InvalidJob;
    }
    if (input.destination.len == 0 or input.destination.len > 4096 or
        std.mem.indexOfScalar(u8, input.destination, 0) != null) return error.InvalidJob;
    if (!std.fs.path.isAbsolute(input.destination)) return error.InvalidDestination;
    const destination_stat = std.Io.Dir.cwd().statFile(io, input.destination, .{}) catch
        return error.InvalidDestination;
    if (destination_stat.kind != .directory) return error.InvalidDestination;
    std.Io.Dir.accessAbsolute(io, input.destination, .{ .write = true, .execute = true }) catch
        return error.InvalidDestination;
    if (input.idempotency_key.len == 0 or input.idempotency_key.len > 128 or
        !std.unicode.utf8ValidateSlice(input.idempotency_key)) return error.InvalidJob;
}

fn validName(name: []const u8) bool {
    return name.len > 0 and name.len <= 255 and !std.mem.eql(u8, name, ".") and
        !std.mem.eql(u8, name, "..") and std.mem.indexOfAny(u8, name, "/\\\x00") == null;
}

fn validSha256(digest: []const u8) bool {
    if (digest.len != 64) return false;
    for (digest) |character| {
        if (!std.ascii.isHex(character)) return false;
    }
    return true;
}

fn decodeSha256(value: ?[]const u8) ?[32]u8 {
    const digest = value orelse return null;
    var bytes: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, digest) catch unreachable;
    return bytes;
}

fn sameInput(job: *const Job, input: AddInput) bool {
    if (!std.meta.eql(job.reference_url == null, input.reference_url == null)) return false;
    if (job.reference_url) |reference| if (!std.mem.eql(u8, reference, input.reference_url.?)) return false;
    const same_name = if (job.name) |name|
        if (input.name) |input_name| std.mem.eql(u8, name, input_name) else false
    else
        input.name == null;
    const same_digest = if (job.expected_sha256) |digest|
        if (input.expected_sha256) |other| std.ascii.eqlIgnoreCase(digest, other) else false
    else
        input.expected_sha256 == null;
    const same_selected = if (job.selected_torrent_files) |files| blk: {
        const other = input.selected_torrent_files orelse break :blk false;
        if (files.len != other.len) break :blk false;
        for (files, other) |left, right| if (!std.mem.eql(u8, left, right)) break :blk false;
        break :blk true;
    } else input.selected_torrent_files == null;
    return same_digest and same_selected and std.mem.eql(u8, job.url, input.url) and same_name and
        std.mem.eql(u8, job.queue_id, input.queue_id) and
        std.mem.eql(u8, job.destination, input.destination) and job.priority == input.priority and
        job.bandwidth_limit_bytes_per_second == input.bandwidth_limit_bytes_per_second;
}

fn getString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidJobStore;
    if (value != .string) return error.InvalidJobStore;
    return value.string;
}

fn redactUrl(url: []const u8) []const u8 {
    if (url.len >= 7 and std.ascii.eqlIgnoreCase(url[0..7], "magnet:")) return "magnet:";
    if (@import("../protocols/torrent/source.zig").isLocalTorrent(url)) return "torrent-file:";
    const query = std.mem.indexOfScalar(u8, url, '?') orelse url.len;
    const fragment = std.mem.indexOfScalar(u8, url, '#') orelse url.len;
    return url[0..@min(query, fragment)];
}

fn deleteFileIfPresent(dir: std.Io.Dir, io: std.Io, path: []const u8) !void {
    dir.deleteFile(io, path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
}

fn validJobId(job_id: []const u8) bool {
    if (job_id.len != 36) return false;
    for (job_id, 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (byte != '-') return false;
        } else if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}
