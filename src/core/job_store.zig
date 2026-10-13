//! Per-user job catalogue with atomic JSON persistence.
//!
//! Engine-owned download records with atomic persistence and queue controls.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const queue_policy = @import("queue.zig");
const CoreState = @import("root.zig").State;

const lstat = @extern(*const fn ([*:0]const u8, *c.Stat) callconv(.c) c_int, .{
    .name = if (builtin.os.tag == .macos) "lstat$INODE64" else "lstat",
});
const statPath = @extern(*const fn ([*:0]const u8, *c.Stat) callconv(.c) c_int, .{
    .name = if (builtin.os.tag == .macos) "stat$INODE64" else "stat",
});
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn chmod(path: [*:0]const u8, mode: c.mode_t) c_int;

pub const State = enum { queued, scheduled, resolving, connecting, downloading, paused, retry_wait, verifying, completed, failed, canceled };
pub const StopAction = enum { pause, cancel };
pub const max_parallel_downloads = 4;
pub const max_parallel_downloads_per_host = 2;

pub const Job = struct {
    id: []const u8,
    url: []const u8,
    name: ?[]const u8,
    destination: []const u8,
    idempotency_key: []const u8,
    state: State = .queued,
    revision: u64 = 1,
    error_message: ?[]const u8 = null,
    completed_bytes: u64 = 0,
    total_bytes: ?u64 = null,
    requested_control: ?StopAction = null,
    priority: i32 = 0,
};

pub const AddInput = struct {
    url: []const u8,
    name: ?[]const u8,
    destination: []const u8,
    idempotency_key: []const u8,
    priority: i32 = 0,
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
    jobs: std.ArrayList(Job) = .empty,
    mutex: std.Io.Mutex = .init,

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
            var posix_stat: c.Stat = undefined;
            if (lstat(path_z, &posix_stat) != 0 or posix_stat.uid != c.getuid() or
                posix_stat.mode & c.S.IFMT != c.S.IFDIR or chmod(path_z, 0o700) != 0)
                return error.UnsafeStoreDirectory;
        }

        const file_path = try std.fs.path.join(allocator, &.{ directory_path, "jobs.json" });
        errdefer allocator.free(file_path);
        var store = Store{
            .allocator = allocator,
            .io = io,
            .directory_path = try allocator.dupe(u8, directory_path),
            .file_path = file_path,
        };
        errdefer store.deinit();
        try store.load();
        return store;
    }

    pub fn deinit(self: *Store) void {
        for (self.jobs.items) |job| {
            self.freeJob(job);
        }
        self.jobs.deinit(self.allocator);
        self.allocator.free(self.directory_path);
        self.allocator.free(self.file_path);
        self.* = undefined;
    }

    fn addUnlocked(self: *Store, input: AddInput) !AddResult {
        try validateInput(self.io, input);
        for (self.jobs.items) |*job| {
            if (!std.mem.eql(u8, job.idempotency_key, input.idempotency_key)) continue;
            if (sameInput(job, input)) return .{ .job = job, .duplicate = true };
            return error.IdempotencyConflict;
        }

        const job = try self.duplicateJob(input);
        self.jobs.append(self.allocator, job) catch |err| {
            self.freeJob(job);
            return err;
        };
        self.persist() catch |err| {
            self.freeJob(self.jobs.pop().?);
            return err;
        };
        return .{ .job = &self.jobs.items[self.jobs.items.len - 1], .duplicate = false };
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
            .state = job.state,
            .revision = try std.fmt.allocPrint(allocator, "{d}", .{job.revision}),
            .error_message = job.error_message,
            .completed_bytes = decimalAlloc(allocator, job.completed_bytes) catch return error.OutOfMemory,
            .total_bytes = if (job.total_bytes) |total| decimalAlloc(allocator, total) catch return error.OutOfMemory else null,
            .requested_control = job.requested_control,
            .priority = job.priority,
        });
        defer for (summaries.items) |summary| allocator.free(summary.revision);
        defer for (summaries.items) |summary| {
            allocator.free(summary.completed_bytes);
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

    pub const Action = enum { pause, @"resume", cancel, start, retry };

    fn controlUnlocked(self: *Store, job_id: []const u8, action: Action, expected_revision: u64) !*const Job {
        for (self.jobs.items) |*job| {
            if (!std.mem.eql(u8, job.id, job_id)) continue;
            if (job.revision != expected_revision) return error.StaleJobRevision;
            const next: State = switch (action) {
                .pause => switch (job.state) {
                    .queued, .scheduled => .paused,
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
            job.state = next;
            job.revision = std.math.add(u64, job.revision, 1) catch {
                job.state = previous;
                return error.RevisionOverflow;
            };
            if (action == .start) {
                job.error_message = null;
                job.completed_bytes = 0;
                job.total_bytes = null;
                job.requested_control = null;
            }
            self.persist() catch |err| {
                job.state = previous;
                job.revision = previous_revision;
                job.error_message = previous_error;
                job.completed_bytes = previous_completed;
                job.total_bytes = previous_total;
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

        pub fn deinit(self: DownloadTask, allocator: std.mem.Allocator) void {
            allocator.free(self.id);
            allocator.free(self.url);
            if (self.name) |name| allocator.free(name);
            allocator.free(self.destination);
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
            return .{ .id = id, .url = url, .name = name, .destination = destination };
        }
        return error.JobNotFound;
    }

    pub fn startNextQueued(self: *Store) !?DownloadTask {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var refs: std.ArrayList(queue_policy.JobRef) = .empty;
        defer refs.deinit(self.allocator);
        for (self.jobs.items, 0..) |job, index| {
            const uri = try std.Uri.parse(job.url);
            try refs.append(self.allocator, .{
                .id = @intCast(index),
                .host = hostString(uri) orelse "",
                .priority = job.priority,
                .sequence = @intCast(index + 1),
                .state = std.meta.stringToEnum(CoreState, @tagName(job.state)).?,
            });
        }
        const selected = queue_policy.next(refs.items, .{
            .global_active = max_parallel_downloads,
            .per_host_active = max_parallel_downloads_per_host,
        }) orelse return null;
        const job = &self.jobs.items[@intCast(refs.items[selected].id)];
        const old_state = job.state;
        const old_revision = job.revision;
        const old_error = job.error_message;
        const old_completed = job.completed_bytes;
        const old_total = job.total_bytes;
        const next_revision = try std.math.add(u64, old_revision, 1);
        const task = try self.copyTaskUnlocked(job.*);
        errdefer task.deinit(self.allocator);
        job.state = .downloading;
        job.revision = next_revision;
        job.error_message = null;
        job.completed_bytes = 0;
        job.total_bytes = null;
        job.requested_control = null;
        self.persist() catch |err| {
            job.state = old_state;
            job.revision = old_revision;
            job.error_message = old_error;
            job.completed_bytes = old_completed;
            job.total_bytes = old_total;
            return err;
        };
        if (old_error) |message| self.allocator.free(message);
        return task;
    }

    fn activeForHost(self: *Store, url: []const u8) usize {
        const target = std.Uri.parse(url) catch return max_parallel_downloads_per_host;
        const target_host = hostString(target) orelse return max_parallel_downloads_per_host;
        var active: usize = 0;
        for (self.jobs.items) |job| {
            if (job.state != .resolving and job.state != .connecting and job.state != .downloading and job.state != .verifying) continue;
            const uri = std.Uri.parse(job.url) catch continue;
            const host = hostString(uri) orelse continue;
            if (std.ascii.eqlIgnoreCase(host, target_host)) active += 1;
        }
        return active;
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
        return .{ .id = id, .url = url, .name = name, .destination = destination };
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
            const next_revision = try std.math.add(u64, job.revision, 1);
            const owned_error = if (!succeeded and error_message != null)
                try self.allocator.dupe(u8, error_message.?)
            else
                null;
            job.state = if (succeeded) .completed else .failed;
            job.revision = next_revision;
            job.error_message = owned_error;
            job.requested_control = null;
            self.persist() catch |err| {
                job.state = old_state;
                job.revision = old_revision;
                job.error_message = old_error;
                job.requested_control = old_requested_control;
                if (owned_error) |value| self.allocator.free(value);
                return err;
            };
            if (old_error) |value| self.allocator.free(value);
            return;
        }
        return error.JobNotFound;
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
            const next_revision = try std.math.add(u64, job.revision, 1);
            job.state = next_state;
            job.requested_control = null;
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
                return err;
            };
            return;
        }
        return error.JobNotFound;
    }

    pub fn updateProgress(self: *Store, job_id: []const u8, completed_bytes: u64, total_bytes: ?u64, durable: bool) !void {
        if (!durable) return;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.jobs.items) |*job| {
            if (!std.mem.eql(u8, job.id, job_id) or job.state != .downloading) continue;
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
        return .{
            .id = id,
            .url = url,
            .name = name,
            .destination = destination,
            .idempotency_key = idempotency_key,
            .priority = input.priority,
        };
    }

    fn freeJob(self: *Store, job: Job) void {
        self.allocator.free(job.id);
        self.allocator.free(job.url);
        if (job.name) |name| self.allocator.free(name);
        self.allocator.free(job.destination);
        self.allocator.free(job.idempotency_key);
        if (job.error_message) |message| self.allocator.free(message);
    }

    fn load(self: *Store) !void {
        if (comptime builtin.os.tag != .windows) {
            const path_z = try self.allocator.dupeSentinel(u8, self.file_path, 0);
            defer self.allocator.free(path_z);
            var existing_stat: c.Stat = undefined;
            if (lstat(path_z, &existing_stat) == 0) {
                if (existing_stat.uid != c.getuid() or existing_stat.mode & c.S.IFMT != c.S.IFREG)
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
        const revision_value = object.get("revision") orelse return error.InvalidJobStore;
        if (revision_value != .integer or revision_value.integer <= 0) return error.InvalidJobStore;
        const name_value = object.get("name") orelse .null;
        if (name_value != .null and name_value != .string) return error.InvalidJobStore;
        if (name_value == .string and !validName(name_value.string)) return error.InvalidJobStore;
        const name = if (name_value == .string) try self.allocator.dupe(u8, name_value.string) else null;
        try self.jobs.append(self.allocator, .{
            .id = try self.allocator.dupe(u8, id),
            .url = try self.allocator.dupe(u8, url),
            .name = name,
            .destination = try self.allocator.dupe(u8, destination),
            .idempotency_key = try self.allocator.dupe(u8, key),
            .state = state,
            .revision = @intCast(revision_value.integer),
            .error_message = error_message,
            .completed_bytes = @intCast(completed_value.integer),
            .total_bytes = total_bytes,
            .requested_control = requested_control,
            .priority = @intCast(priority_value.integer),
        });
    }

    fn persist(self: *Store) !void {
        const data = try std.json.Stringify.valueAlloc(self.allocator, .{
            .version = 1,
            .jobs = self.jobs.items,
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
    }

    fn deletePartialFiles(self: *Store, job: Job) !void {
        const destination = try self.destinationPath(job);
        defer self.allocator.free(destination);
        const part_path = try std.fmt.allocPrint(self.allocator, "{s}.part", .{destination});
        defer self.allocator.free(part_path);
        const journal_path = try std.fmt.allocPrint(self.allocator, "{s}.odm", .{part_path});
        defer self.allocator.free(journal_path);
        const cwd = std.Io.Dir.cwd();
        cwd.deleteFile(self.io, part_path) catch {};
        cwd.deleteFile(self.io, journal_path) catch {};
    }

    fn destinationPath(self: *Store, job: Job) ![]u8 {
        var filename: []const u8 = undefined;
        if (job.name) |name| {
            filename = name;
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
};

const Summary = struct {
    job_id: []const u8,
    url: []const u8,
    name: ?[]const u8,
    destination: []const u8,
    state: State,
    revision: []const u8,
    error_message: ?[]const u8,
    completed_bytes: []const u8,
    total_bytes: ?[]const u8,
    requested_control: ?StopAction,
    priority: i32,
};

fn decimalAlloc(allocator: std.mem.Allocator, value: u64) ![]u8 {
    return try std.fmt.allocPrint(allocator, "{d}", .{value});
}

fn validateInput(io: std.Io, input: AddInput) !void {
    if (input.url.len == 0 or input.url.len > 8192) return error.InvalidJob;
    if (input.priority < -100 or input.priority > 100) return error.InvalidJob;
    const uri = std.Uri.parse(input.url) catch return error.InvalidJob;
    if ((!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) or
        uri.host == null or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null)
        return error.InvalidJob;
    if (input.name) |name| if (!validName(name)) return error.InvalidJob;
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

fn sameInput(job: *const Job, input: AddInput) bool {
    const same_name = if (job.name) |name|
        if (input.name) |input_name| std.mem.eql(u8, name, input_name) else false
    else
        input.name == null;
    return std.mem.eql(u8, job.url, input.url) and same_name and
        std.mem.eql(u8, job.destination, input.destination) and job.priority == input.priority;
}

fn getString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidJobStore;
    if (value != .string) return error.InvalidJobStore;
    return value.string;
}

fn redactUrl(url: []const u8) []const u8 {
    return url;
}
