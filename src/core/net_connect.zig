//! Bounded connects without the unimplemented ConnectOptions.timeout path in
//! Zig 0.17's Threaded backend. Cancellation is joined before stack data expires.
const std = @import("std");
const Io = std.Io;

pub fn host(io: Io, name: Io.net.HostName, port: u16, milliseconds: i64) !Io.net.Stream {
    var completed: Io.Event = .unset;
    var future = try Io.concurrent(io, connectHost, .{ io, name, port, &completed });
    return finish(io, &future, &completed, milliseconds);
}

pub fn address(io: Io, target: Io.net.IpAddress, milliseconds: i64) !Io.net.Stream {
    var completed: Io.Event = .unset;
    var future = try Io.concurrent(io, connectAddress, .{ io, target, &completed });
    return finish(io, &future, &completed, milliseconds);
}

fn finish(io: Io, future: *Io.Future(anyerror!Io.net.Stream), completed: *Io.Event, milliseconds: i64) !Io.net.Stream {
    completed.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(milliseconds), .clock = .awake } }) catch |err| {
        if (future.cancel(io)) |stream| stream.close(io) else |_| {}
        return err;
    };
    return future.await(io);
}

fn connectHost(io: Io, name: Io.net.HostName, port: u16, completed: *Io.Event) anyerror!Io.net.Stream {
    defer completed.set(io);
    return name.connect(io, port, .{ .mode = .stream });
}

fn connectAddress(io: Io, target: Io.net.IpAddress, completed: *Io.Event) anyerror!Io.net.Stream {
    defer completed.set(io);
    return target.connect(io, .{ .mode = .stream });
}
