//! Test root keeps HTTP modules and their shared core imports under `src/`.

test {
    _ = @import("protocols/http/download.zig");
}
