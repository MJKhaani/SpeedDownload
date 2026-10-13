//! Narrow POSIX path metadata helper for owner, mode, and inode checks.

const builtin = @import("builtin");
const std = @import("std");
const c = std.c;

pub const Info = struct {
    uid: u32,
    mode: u32,
    device: u64,
    inode: u64,
};

pub fn get(path: [*:0]const u8, follow_symlinks: bool) ?Info {
    if (comptime builtin.os.tag == .linux) {
        const linux = std.os.linux;
        var stat: linux.Statx = undefined;
        const flags: u32 = if (follow_symlinks) 0 else linux.AT.SYMLINK_NOFOLLOW;
        const result = linux.statx(linux.AT.FDCWD, path, flags, linux.STATX.BASIC_STATS, &stat);
        if (linux.errno(result) != .SUCCESS) return null;
        return .{
            .uid = stat.uid,
            .mode = stat.mode,
            .device = (@as(u64, stat.dev_major) << 32) | stat.dev_minor,
            .inode = stat.ino,
        };
    } else if (comptime builtin.os.tag == .macos) {
        const macos_stat = @import("posix_stat_macos.zig");
        var stat: c.Stat = undefined;
        const result = if (follow_symlinks) macos_stat.stat(path, &stat) else macos_stat.lstat(path, &stat);
        if (result != 0) return null;
        return .{
            .uid = stat.uid,
            .mode = stat.mode,
            .device = @intCast(stat.dev),
            .inode = @intCast(stat.ino),
        };
    } else {
        return null;
    }
}

pub fn currentUid() u32 {
    return @intCast(c.getuid());
}

pub fn isDirectory(info: Info) bool {
    return info.mode & 0o170000 == 0o040000;
}

pub fn isRegularFile(info: Info) bool {
    return info.mode & 0o170000 == 0o100000;
}
