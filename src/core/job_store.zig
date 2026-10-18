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

pub const Settings = struct {
    schema_version: u32 = 2,
    max_concurrent_tasks: u8 = default_max_parallel_downloads,
    default_connections_per_task: u8 = 4,
    multipart_mode: MultipartMode = .auto,
    default_download_folder: []const u8 = "",
    proxy_mode: ProxyMode = .system,
    proxy_url: ?[]const u8 = null,
    bandwidth_limit_bytes_per_second: u64 = 0,
    queue_schedule_enabled: bool = false,
    queue_schedule_slots: [hours_per_week]bool = @splat(true),
    bandwidth_schedule_enabled: bool = false,
    scheduled_bandwidth_limit_bytes_per_second: u64 = 0,
    bandwidth_schedule_slots: [hours_per_week]BandwidthScheduleMode = @splat(.global_limit),
    debug_log_enabled: bool = false,
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
    url: []const u8,
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
    priority: i32 = 0,
    bandwidth_limit_bytes_per_second: u64 = 0,
    workers: [32]WorkerProgress = @splat(.{}),
    worker_count: usize = 0,
};

pub const AddInput = struct {
    url: []const u8,
    name: ?[]const u8,
    destination: []const u8,
    idempotency_key: []const u8,
    priority: i32 = 0,
    bandwidth_limit_bytes_per_second: u64 = 0,
    expected_sha256: ?[]const u8 = null,
    selected_torrent_files: ?[]const []const u8 = null,
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
    settings: Settings = .{},
    jobs: std.ArrayList(Job) = .empty,
    mutex: std.Io.Mutex = .init,
    log_mutex: std.Io.Mutex = .init,
    change_sequence: std.atomic.Value(u64) = .init(1),

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
        return store;
    }

    pub fn deinit(self: *Store) void {
        for (self.jobs.items) |job| {
            self.freeJob(job);
        }
        self.jobs.deinit(self.allocator);
        self.allocator.free(self.directory_path);
        self.allocator.free(self.file_path);
        self.freeSettings(self.settings);
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

    pub const OwnedProxyPolicy = struct {
        mode: ProxyMode,
        url: ?[]u8,

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
        };
    }

    /// Switches only queue-controlled jobs. User-paused jobs remain paused.
    pub fn applyQueueWindow(self: *Store, active: bool) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var changed: std.ArrayList(usize) = .empty;
        defer changed.deinit(self.allocator);
        for (self.jobs.items, 0..) |job, index| {
            if ((active and job.state == .scheduled) or (!active and job.state == .queued)) {
                if (job.revision == std.math.maxInt(u64)) return error.RevisionOverflow;
                try changed.append(self.allocator, index);
            }
        }
        if (changed.items.len == 0) return;
        for (changed.items) |index| {
            self.jobs.items[index].state = if (active) .queued else .scheduled;
            self.jobs.items[index].revision += 1;
        }
        self.persist() catch |err| {
            for (changed.items) |index| {
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
        return .{
            .schema_version = 2,
            .max_concurrent_tasks = value.max_concurrent_tasks,
            .default_connections_per_task = value.default_connections_per_task,
            .multipart_mode = value.multipart_mode,
            .default_download_folder = try self.allocator.dupe(u8, value.default_download_folder),
            .proxy_mode = value.proxy_mode,
            .proxy_url = if (value.proxy_url) |url| try self.allocator.dupe(u8, url) else null,
            .bandwidth_limit_bytes_per_second = value.bandwidth_limit_bytes_per_second,
            .queue_schedule_enabled = value.queue_schedule_enabled,
            .queue_schedule_slots = value.queue_schedule_slots,
            .bandwidth_schedule_enabled = value.bandwidth_schedule_enabled,
            .scheduled_bandwidth_limit_bytes_per_second = value.scheduled_bandwidth_limit_bytes_per_second,
            .bandwidth_schedule_slots = value.bandwidth_schedule_slots,
            .debug_log_enabled = value.debug_log_enabled,
        };
    }

    fn freeSettings(self: *Store, value: Settings) void {
        self.allocator.free(value.default_download_folder);
        if (value.proxy_url) |url| self.allocator.free(url);
    }

    fn addUnlocked(self: *Store, input: AddInput) !AddResult {
        for (self.jobs.items) |*job| {
            if (!std.mem.eql(u8, job.idempotency_key, input.idempotency_key)) continue;
            if (sameInput(job, input)) return .{ .job = job, .duplicate = true };
            return error.IdempotencyConflict;
        }
        try validateInput(self.allocator, self.io, input);

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
            self.snapshotTorrentSource(job.id, input.url) catch |err| {
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
    fn snapshotTorrentSource(self: *Store, job_id: []const u8, url: []const u8) ![]u8 {
        const source = @import("../protocols/torrent/source.zig");
        const torrent = @import("../protocols/torrent/metainfo.zig");
        const original = try source.pathAlloc(self.allocator, url);
        defer self.allocator.free(original);
        const bytes = try std.Io.Dir.readFileAlloc(.cwd(), self.io, original, self.allocator, .limited(torrent.max_metainfo_bytes));
        defer self.allocator.free(bytes);
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

    pub fn listJson(self: *Store, request_id: std.json.Value, offset: usize, limit: usize) ![]u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const allocator = self.allocator;
        var summaries: std.ArrayList(Summary) = .empty;
        defer summaries.deinit(allocator);
        const start = @min(offset, self.jobs.items.len);
        const end = @min(self.jobs.items.len, start +| limit);
        for (self.jobs.items[start..end]) |job| try summaries.append(allocator, .{
            .job_id = job.id,
            .url = redactUrl(job.url),
            .name = job.name,
            .destination = job.destination,
            .expected_sha256 = job.expected_sha256,
            .state = job.state,
            .revision = try std.fmt.allocPrint(allocator, "{d}", .{job.revision}),
            .error_message = job.error_message,
            .retry_attempts = job.retry_attempts,
            .retry_at_unix_ms = if (job.retry_at_unix_ms) |value| try std.fmt.allocPrint(allocator, "{d}", .{value}) else null,
            .completed_bytes = decimalAlloc(allocator, job.completed_bytes) catch return error.OutOfMemory,
            .received_bytes = if (job.live_received_bytes) |received| decimalAlloc(allocator, received) catch return error.OutOfMemory else null,
            .total_bytes = if (job.live_total_bytes orelse job.total_bytes) |total| decimalAlloc(allocator, total) catch return error.OutOfMemory else null,
            .requested_control = job.requested_control,
            .priority = job.priority,
            .bandwidth_limit_bytes_per_second = job.bandwidth_limit_bytes_per_second,
            .workers = job.workers[0..job.worker_count],
        });
        defer for (summaries.items) |summary| allocator.free(summary.revision);
        defer for (summaries.items) |summary| {
            allocator.free(summary.completed_bytes);
            if (summary.retry_at_unix_ms) |value| allocator.free(value);
            if (summary.received_bytes) |received| allocator.free(received);
            if (summary.total_bytes) |total| allocator.free(total);
        };
        const total = try std.fmt.allocPrint(allocator, "{d}", .{self.jobs.items.len});
        defer allocator.free(total);
        const next_offset = if (end < self.jobs.items.len)
            try std.fmt.allocPrint(allocator, "{d}", .{end})
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
            return .{ .id = id, .url = url, .name = name, .destination = destination, .connections = self.connectionsForJob(job), .proxy_mode = self.settings.proxy_mode, .proxy_url = proxy_url, .expected_sha256 = decodeSha256(job.expected_sha256), .selected_torrent_files = selected };
        }
        return error.JobNotFound;
    }

    pub fn startNextQueued(self: *Store) !?DownloadTask {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var refs: std.ArrayList(queue_policy.JobRef) = .empty;
        defer refs.deinit(self.allocator);
        for (self.jobs.items, 0..) |job, index| {
            try refs.append(self.allocator, .{
                .id = @intCast(index),
                .host = sourceHost(job.url),
                .priority = job.priority,
                .sequence = @intCast(index),
                .state = std.meta.stringToEnum(CoreState, @tagName(job.state)).?,
            });
        }
        const limits: queue_policy.Limits = .{
            .global_active = self.settings.max_concurrent_tasks,
            .per_host_active = max_parallel_downloads_per_host,
        };
        var selected = queue_policy.next(refs.items, limits) orelse return null;
        while (try self.destinationOccupied(self.jobs.items[@intCast(refs.items[selected].id)], true)) {
            refs.items[selected].state = .paused;
            selected = queue_policy.next(refs.items, limits) orelse return null;
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
        return .{ .id = id, .url = url, .name = name, .destination = destination, .connections = self.connectionsForJob(job), .proxy_mode = self.settings.proxy_mode, .proxy_url = proxy_url, .expected_sha256 = decodeSha256(job.expected_sha256), .selected_torrent_files = selected };
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
            self.persist() catch |err| {
                job.state = old_state;
                job.revision = old_revision;
                job.error_message = old_error;
                job.requested_control = old_requested_control;
                job.worker_count = old_worker_count;
                job.retry_attempts = old_retry_attempts;
                job.retry_at_unix_ms = old_retry_at;
                if (owned_error) |value| self.allocator.free(value);
                return err;
            };
            if (old_error) |value| self.allocator.free(value);
            return;
        }
        return error.JobNotFound;
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
            const delay_seconds: i64 = @max(@as(i64, 1) << @intCast(attempt), @min(@as(i64, minimum_delay_seconds), 3600));
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
                _ = self.change_sequence.fetchAdd(1, .release);
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
            _ = self.change_sequence.fetchAdd(1, .release);
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
        const name = if (input.name) |text| try self.allocator.dupe(u8, text) else null;
        errdefer if (name) |text| self.allocator.free(text);
        const destination = try self.allocator.dupe(u8, input.destination);
        errdefer self.allocator.free(destination);
        const idempotency_key = try self.allocator.dupe(u8, input.idempotency_key);
        errdefer self.allocator.free(idempotency_key);
        const expected_sha256 = if (input.expected_sha256) |digest| try self.allocator.dupe(u8, digest) else null;
        errdefer if (expected_sha256) |digest| self.allocator.free(digest);
        const selected_torrent_files = try duplicateSelectedFiles(self.allocator, input.selected_torrent_files);
        errdefer freeSelectedFiles(self.allocator, selected_torrent_files);
        return .{
            .id = id,
            .url = url,
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
        self.allocator.free(job.url);
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
        const url = try getString(object, "url");
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
            .url = try self.allocator.dupe(u8, url),
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
            .url = job.url,
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
        _ = self.change_sequence.fetchAdd(1, .release);
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
                try self.persistSettings();
                return;
            },
            else => return err,
        };
        defer file.close(self.io);
        const stat = try file.stat(self.io);
        if (stat.size > 1024 * 1024) return error.SettingsTooLarge;
        var buffer: [4096]u8 = undefined;
        var reader = file.reader(self.io, &buffer);
        const bytes = try reader.interface.allocRemaining(self.allocator, .limited(stat.size));
        defer self.allocator.free(bytes);
        const parsed = try std.json.parseFromSlice(Settings, self.allocator, bytes, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        var migrated = parsed.value;
        migrated.schema_version = 2;
        try validateSettings(migrated);
        self.settings = try self.duplicateSettings(migrated);
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
        if (value.schema_version != 2 or value.max_concurrent_tasks == 0 or value.max_concurrent_tasks > 32 or
            value.default_connections_per_task == 0 or value.default_connections_per_task > 32 or
            value.default_download_folder.len > 4096) return error.InvalidSettings;
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
    url: []const u8,
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
};

const PersistedJob = struct {
    id: []const u8,
    url: []const u8,
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

fn validateInput(allocator: std.mem.Allocator, io: std.Io, input: AddInput) !void {
    if (input.expected_sha256) |digest| if (!validSha256(digest)) return error.InvalidJob;
    if (input.url.len == 0 or input.url.len > 8192) return error.InvalidJob;
    if (input.priority < -100 or input.priority > 100) return error.InvalidJob;
    if (input.bandwidth_limit_bytes_per_second > 1_000_000_000_000) return error.InvalidJob;
    if (input.url.len >= 7 and std.ascii.eqlIgnoreCase(input.url[0..7], "magnet:")) {
        if (input.selected_torrent_files != null) return error.InvalidJob;
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
            if (selected.len == 0 or selected.len > map.files.len or map.files.len <= 1 or input.expected_sha256 != null) return error.InvalidJob;
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
        if (input.selected_torrent_files != null) return error.InvalidJob;
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
    return url;
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
