//! Per-user job catalogue with atomic JSON persistence.
//!
//! Engine-owned download records with atomic persistence and queue controls.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

const lstat = @extern(*const fn ([*:0]const u8, *c.Stat) callconv(.c) c_int, .{
    .name = if (builtin.os.tag == .macos) "lstat$INODE64" else "lstat",
});
const statPath = @extern(*const fn ([*:0]const u8, *c.Stat) callconv(.c) c_int, .{
    .name = if (builtin.os.tag == .macos) "stat$INODE64" else "stat",
});
extern "c" fn access(path: [*:0]const u8, mode: c_int) c_int;
extern "c" fn chmod(path: [*:0]const u8, mode: c.mode_t) c_int;

pub const State = enum { queued, scheduled, resolving, connecting, downloading, paused, retry_wait, verifying, completed, failed, canceled };

pub const Job = struct {
    id: []const u8,
    url: []const u8,
    name: ?[]const u8,
    destination: []const u8,
    idempotency_key: []const u8,
    state: State = .queued,
    revision: u64 = 1,
};

pub const AddInput = struct {
    url: []const u8,
    name: ?[]const u8,
    destination: []const u8,
    idempotency_key: []const u8,
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

    pub fn open(allocator: std.mem.Allocator, io: std.Io, directory_path: []const u8) !Store {
        if (!std.fs.path.isAbsolute(directory_path)) return error.InvalidStorePath;
        try std.Io.Dir.cwd().createDirPath(io, directory_path);
        const path_z = try allocator.dupeSentinel(u8, directory_path, 0);
        defer allocator.free(path_z);
        var directory_stat: c.Stat = undefined;
        if (lstat(path_z, &directory_stat) != 0 or directory_stat.uid != c.getuid() or
            directory_stat.mode & c.S.IFMT != c.S.IFDIR)
            return error.UnsafeStoreDirectory;
        if (chmod(path_z, 0o700) != 0) return error.UnsafeStoreDirectory;

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

    pub fn add(self: *Store, input: AddInput) !AddResult {
        try validateInput(input);
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
        });
        defer for (summaries.items) |summary| allocator.free(summary.revision);
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
        const result = try self.add(input);
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

    pub fn controlJson(self: *Store, request_id: std.json.Value, job_id: []const u8, action: Action) ![]u8 {
        const job = self.control(job_id, action) catch |err| return err;
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

    pub const Action = enum { pause, @"resume", cancel };

    pub fn control(self: *Store, job_id: []const u8, action: Action) !*const Job {
        for (self.jobs.items) |*job| {
            if (!std.mem.eql(u8, job.id, job_id)) continue;
            const next: State = switch (action) {
                .pause => switch (job.state) {
                    .queued, .scheduled => .paused,
                    else => return error.InvalidJobControl,
                },
                .@"resume" => if (job.state == .paused) .queued else return error.InvalidJobControl,
                .cancel => switch (job.state) {
                    .queued, .scheduled, .paused, .retry_wait => .canceled,
                    else => return error.InvalidJobControl,
                },
            };
            const previous = job.state;
            const previous_revision = job.revision;
            job.state = next;
            job.revision += 1;
            self.persist() catch |err| {
                job.state = previous;
                job.revision = previous_revision;
                return err;
            };
            return job;
        }
        return error.JobNotFound;
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
        };
    }

    fn freeJob(self: *Store, job: Job) void {
        self.allocator.free(job.id);
        self.allocator.free(job.url);
        if (job.name) |name| self.allocator.free(name);
        self.allocator.free(job.destination);
        self.allocator.free(job.idempotency_key);
    }

    fn load(self: *Store) !void {
        const path_z = try self.allocator.dupeSentinel(u8, self.file_path, 0);
        defer self.allocator.free(path_z);
        var existing_stat: c.Stat = undefined;
        if (lstat(path_z, &existing_stat) == 0) {
            if (existing_stat.uid != c.getuid() or existing_stat.mode & c.S.IFMT != c.S.IFREG)
                return error.UnsafeJobStoreFile;
            if (chmod(path_z, 0o600) != 0) return error.UnsafeJobStoreFile;
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
        const revision_value = object.get("revision") orelse return error.InvalidJobStore;
        if (revision_value != .integer or revision_value.integer <= 0) return error.InvalidJobStore;
        const name_value = object.get("name") orelse .null;
        const name = if (name_value == .string) try self.allocator.dupe(u8, name_value.string) else null;
        try self.jobs.append(self.allocator, .{
            .id = try self.allocator.dupe(u8, id),
            .url = try self.allocator.dupe(u8, url),
            .name = name,
            .destination = try self.allocator.dupe(u8, destination),
            .idempotency_key = try self.allocator.dupe(u8, key),
            .state = state,
            .revision = @intCast(revision_value.integer),
        });
    }

    fn persist(self: *Store) !void {
        const data = try std.json.Stringify.valueAlloc(self.allocator, .{
            .version = 1,
            .jobs = self.jobs.items,
        }, .{});
        defer self.allocator.free(data);
        var atomic = try std.Io.Dir.createFileAtomic(.cwd(), self.io, self.file_path, .{
            .permissions = std.Io.File.Permissions.fromMode(0o600),
            .make_path = true,
            .replace = true,
        });
        defer atomic.deinit(self.io);
        try atomic.file.writeStreamingAll(self.io, data);
        try atomic.replace(self.io);
    }
};

const Summary = struct {
    job_id: []const u8,
    url: []const u8,
    name: ?[]const u8,
    destination: []const u8,
    state: State,
    revision: []const u8,
};

fn validateInput(input: AddInput) !void {
    if (input.url.len == 0 or input.url.len > 8192) return error.InvalidJob;
    const uri = std.Uri.parse(input.url) catch return error.InvalidJob;
    if ((!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) or
        uri.host == null or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null)
        return error.InvalidJob;
    if (input.name) |name| if (name.len == 0 or name.len > 255 or std.mem.indexOfAny(u8, name, "/\\\x00") != null)
        return error.InvalidJob;
    if (input.destination.len == 0 or input.destination.len > 4096 or
        std.mem.indexOfScalar(u8, input.destination, 0) != null) return error.InvalidJob;
    if (!std.fs.path.isAbsolute(input.destination)) return error.InvalidDestination;
    const destination_z = try std.heap.page_allocator.dupeSentinel(u8, input.destination, 0);
    defer std.heap.page_allocator.free(destination_z);
    var destination_stat: c.Stat = undefined;
    if (statPath(destination_z, &destination_stat) != 0 or
        destination_stat.mode & c.S.IFMT != c.S.IFDIR or
        access(destination_z, c.W_OK | c.X_OK) != 0)
        return error.InvalidDestination;
    if (input.idempotency_key.len == 0 or input.idempotency_key.len > 128 or
        !std.unicode.utf8ValidateSlice(input.idempotency_key)) return error.InvalidJob;
}

fn sameInput(job: *const Job, input: AddInput) bool {
    const same_name = if (job.name) |name|
        if (input.name) |input_name| std.mem.eql(u8, name, input_name) else false
    else
        input.name == null;
    return std.mem.eql(u8, job.url, input.url) and same_name and
        std.mem.eql(u8, job.destination, input.destination);
}

fn getString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidJobStore;
    if (value != .string) return error.InvalidJobStore;
    return value.string;
}

fn redactUrl(url: []const u8) []const u8 {
    return url;
}
