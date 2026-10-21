//! Engine-wide bounds for concurrent HTTP requests.
//! A permit is held for the lifetime of a response, including its body.
const std = @import("std");
const Io = std.Io;

pub const global_limit = 64;
pub const per_host_limit = 32;
pub const ControlCallback = *const fn (*anyopaque) anyerror!void;

pub const Budget = struct {
    mutex: Io.Mutex = .init,
    hosts: [global_limit][32]u8 = undefined,
    count: usize = 0,
    waiting_head: ?*Waiter = null,
    waiting_tail: ?*Waiter = null,

    const Waiter = struct {
        host_hash: [32]u8,
        next: ?*Waiter = null,
    };

    pub const Permit = struct {
        budget: *Budget,
        io: Io,
        host_hash: [32]u8,

        pub fn release(self: *Permit) void {
            self.budget.mutex.lockUncancelable(self.io);
            defer self.budget.mutex.unlock(self.io);
            for (self.budget.hosts[0..self.budget.count], 0..) |existing, index| {
                if (!std.mem.eql(u8, &existing, &self.host_hash)) continue;
                self.budget.count -= 1;
                self.budget.hosts[index] = self.budget.hosts[self.budget.count];
                return;
            }
            unreachable;
        }
    };

    pub fn acquire(self: *Budget, io: Io, uri: std.Uri, control: ?ControlCallback, context: ?*anyopaque) !Permit {
        return self.acquireUntil(io, uri, control, context, null);
    }

    pub fn acquireUntil(self: *Budget, io: Io, uri: std.Uri, control: ?ControlCallback, context: ?*anyopaque, deadline_ns: ?i96) !Permit {
        const host_hash = hashHost(uri);
        var waiter = Waiter{ .host_hash = host_hash };
        var queued = false;
        errdefer if (queued) {
            self.mutex.lockUncancelable(io);
            self.removeWaiterLocked(&waiter);
            self.mutex.unlock(io);
        };
        while (true) {
            if (control) |check| if (context) |ctx| try check(ctx);
            if (deadline_ns) |deadline| if (Io.Clock.now(.awake, io).nanoseconds >= deadline) return error.ConnectionBudgetBusy;
            self.mutex.lockUncancelable(io);
            const first_eligible = self.firstEligibleWaiterLocked();
            const turn = if (queued) first_eligible == &waiter else first_eligible == null;
            if (turn and self.count < global_limit and self.countForHostLocked(host_hash) < per_host_limit) {
                if (queued) {
                    self.removeWaiterLocked(&waiter);
                    queued = false;
                }
                self.hosts[self.count] = host_hash;
                self.count += 1;
                self.mutex.unlock(io);
                return .{ .budget = self, .io = io, .host_hash = host_hash };
            }
            if (!queued) {
                if (self.waiting_tail) |tail| tail.next = &waiter else self.waiting_head = &waiter;
                self.waiting_tail = &waiter;
                queued = true;
            }
            self.mutex.unlock(io);
            try Io.sleep(io, Io.Duration.fromMilliseconds(50), .awake);
        }
    }

    fn countForHostLocked(self: *Budget, host_hash: [32]u8) usize {
        var count: usize = 0;
        for (self.hosts[0..self.count]) |existing| {
            if (std.mem.eql(u8, &existing, &host_hash)) count += 1;
        }
        return count;
    }

    fn firstEligibleWaiterLocked(self: *Budget) ?*Waiter {
        if (self.count >= global_limit) return null;
        var current = self.waiting_head;
        while (current) |waiter| : (current = waiter.next) {
            if (self.countForHostLocked(waiter.host_hash) < per_host_limit) return waiter;
        }
        return null;
    }

    fn removeWaiterLocked(self: *Budget, target: *Waiter) void {
        var previous: ?*Waiter = null;
        var current = self.waiting_head;
        while (current) |waiter| : (current = waiter.next) {
            if (waiter != target) {
                previous = waiter;
                continue;
            }
            if (previous) |prior| prior.next = waiter.next else self.waiting_head = waiter.next;
            if (self.waiting_tail == waiter) self.waiting_tail = previous;
            waiter.next = null;
            return;
        }
        unreachable;
    }
};

fn hashHost(uri: std.Uri) [32]u8 {
    const host = uri.host orelse return @splat(0);
    const bytes = switch (host) {
        .raw, .percent_encoded => |value| value,
    };
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (bytes) |byte| {
        const lower = [_]u8{std.ascii.toLower(byte)};
        hasher.update(&lower);
    }
    var result: [32]u8 = undefined;
    hasher.final(&result);
    return result;
}
