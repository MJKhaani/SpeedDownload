//! Host-aware selection policy for queued transfer jobs.
//!
//! This is a pure scheduling primitive; it does not launch workers or persist
//! jobs. A single state owner should call `next` and transition the chosen job
//! before dispatching its protocol worker.

const std = @import("std");
const State = @import("root.zig").State;

pub const JobRef = struct {
    id: u64,
    host: []const u8,
    priority: i32 = 0,
    sequence: u64,
    state: State = .queued,
};

pub const Limits = struct {
    global_active: usize,
    per_host_active: usize,
};

pub const Choice = struct { selected: usize, oldest: usize };

/// Selects an eligible job and also identifies the oldest eligible job.
/// A caller can periodically force the oldest choice to bound priority starvation.
pub fn choose(jobs: []const JobRef, limits: Limits, force_oldest: bool) ?Choice {
    if (limits.global_active == 0 or limits.per_host_active == 0) return null;

    // Settings allow at most 32 active tasks. Keep their hosts on the stack so
    // each queued candidate compares only with active work, not full history.
    var active_hosts: [32][]const u8 = undefined;
    var active_total: usize = 0;
    for (jobs) |job| if (isActive(job.state)) {
        if (active_total < active_hosts.len) active_hosts[active_total] = job.host;
        active_total += 1;
    };
    if (active_total >= limits.global_active) return null;

    var best: ?usize = null;
    var oldest: ?usize = null;
    var best_host_active: usize = 0;
    for (jobs, 0..) |candidate, index| {
        if (candidate.state != .queued) continue;
        const host_active = if (active_total <= active_hosts.len)
            countHost(active_hosts[0..active_total], candidate.host)
        else
            countActiveForHost(jobs, candidate.host);
        if (host_active >= limits.per_host_active) continue;

        if (oldest) |oldest_index| {
            if (candidate.sequence < jobs[oldest_index].sequence) oldest = index;
        } else oldest = index;

        const current_index = best orelse {
            best = index;
            best_host_active = host_active;
            continue;
        };
        const current = jobs[current_index];
        if (candidate.priority > current.priority or
            (candidate.priority == current.priority and host_active < best_host_active) or
            (candidate.priority == current.priority and host_active == best_host_active and candidate.sequence < current.sequence))
        {
            best = index;
            best_host_active = host_active;
        }
    }
    const preferred = best orelse return null;
    const oldest_index = oldest.?;
    return .{ .selected = if (force_oldest) oldest_index else preferred, .oldest = oldest_index };
}

/// Returns the next queued job by priority, host load, then FIFO sequence.
pub fn next(jobs: []const JobRef, limits: Limits) ?usize {
    return if (choose(jobs, limits, false)) |choice| choice.selected else null;
}

fn countHost(active_hosts: []const []const u8, host: []const u8) usize {
    var count: usize = 0;
    for (active_hosts) |active_host| {
        if (std.ascii.eqlIgnoreCase(active_host, host)) count += 1;
    }
    return count;
}

fn isActive(state: State) bool {
    return state == .resolving or state == .connecting or state == .downloading or state == .verifying;
}

fn countActiveForHost(jobs: []const JobRef, host: []const u8) usize {
    var count: usize = 0;
    for (jobs) |job| {
        if (isActive(job.state) and std.ascii.eqlIgnoreCase(job.host, host)) count += 1;
    }
    return count;
}

test "global and per-host caps keep work on eligible hosts" {
    const jobs = [_]JobRef{
        .{ .id = 1, .host = "example.com", .sequence = 1, .state = .downloading },
        .{ .id = 2, .host = "EXAMPLE.com", .sequence = 2, .state = .connecting },
        .{ .id = 3, .host = "example.com", .sequence = 3 },
        .{ .id = 4, .host = "other.example", .sequence = 4 },
    };
    try std.testing.expectEqual(@as(?usize, 3), next(&jobs, .{ .global_active = 3, .per_host_active = 2 }));
    try std.testing.expect(next(&jobs, .{ .global_active = 2, .per_host_active = 2 }) == null);
}

test "priority then least-loaded host then FIFO chooses next job" {
    const jobs = [_]JobRef{
        .{ .id = 1, .host = "busy.example", .sequence = 1, .state = .downloading },
        .{ .id = 2, .host = "busy.example", .sequence = 2, .priority = 9 },
        .{ .id = 3, .host = "free.example", .sequence = 3 },
        .{ .id = 4, .host = "free.example", .sequence = 4, .priority = 9 },
    };
    try std.testing.expectEqual(@as(?usize, 3), next(&jobs, .{ .global_active = 3, .per_host_active = 2 }));
}

test "non-queued jobs and zero limits are not dispatched" {
    const jobs = [_]JobRef{
        .{ .id = 1, .host = "one.example", .sequence = 1, .state = .paused },
        .{ .id = 2, .host = "two.example", .sequence = 2, .state = .scheduled },
    };
    try std.testing.expect(next(&jobs, .{ .global_active = 2, .per_host_active = 1 }) == null);
    try std.testing.expect(next(&jobs, .{ .global_active = 0, .per_host_active = 1 }) == null);
}
