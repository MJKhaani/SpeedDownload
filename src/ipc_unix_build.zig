//! Build root for the Unix IPC adapter. Keeping the root at `src/` lets the
//! adapter import core and protocol modules through its existing relative paths.
pub const serve = @import("ipc/unix.zig").serve;
