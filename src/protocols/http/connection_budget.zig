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
        const host_hash = hashHost(uri);
        while (true) {
            if (control) |check| if (context) |ctx| try check(ctx);
            self.mutex.lockUncancelable(io);
            var same_host: usize = 0;
            for (self.hosts[0..self.count]) |existing| {
                if (std.mem.eql(u8, &existing, &host_hash)) same_host += 1;
            }
            if (self.count < global_limit and same_host < per_host_limit) {
                self.hosts[self.count] = host_hash;
                self.count += 1;
                self.mutex.unlock(io);
                return .{ .budget = self, .io = io, .host_hash = host_hash };
            }
            self.mutex.unlock(io);
            try Io.sleep(io, Io.Duration.fromMilliseconds(50), .awake);
        }
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
