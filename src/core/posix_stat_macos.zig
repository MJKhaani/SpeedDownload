//! macOS libc stat entry points; Linux uses the statx syscall instead.

const std = @import("std");
const c = std.c;

pub const stat = @extern(*const fn ([*:0]const u8, *c.Stat) callconv(.c) c_int, .{ .name = "stat$INODE64" });
pub const lstat = @extern(*const fn ([*:0]const u8, *c.Stat) callconv(.c) c_int, .{ .name = "lstat$INODE64" });
