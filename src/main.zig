//! Command-line entry point for the standalone download engine prototype.

const std = @import("std");
const download = @import("protocols/http/download.zig").download;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "--help")) {
        std.debug.print("Usage: odm <http(s)-url> <destination>\n", .{});
        return;
    }
    if (args.len != 3) {
        std.debug.print("Usage: odm <http(s)-url> <destination>\n", .{});
        return error.InvalidArguments;
    }

    download(init.gpa, init.io, args[1], args[2]) catch |err| {
        std.debug.print("odm: download failed: {s}\n", .{@errorName(err)});
        return err;
    };
}
