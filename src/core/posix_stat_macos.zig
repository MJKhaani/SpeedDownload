//! The tiny C adapter uses the selected Darwin SDK's stat alias and layout.
//! Zig's hardcoded x86_64 `stat$INODE64` alias is absent from some SDK stubs.

pub extern "c" fn speed_download_macos_stat(
    path: [*:0]const u8,
    follow_symlinks: c_int,
    uid: *u32,
    mode: *u32,
    device: *u64,
    inode: *u64,
) c_int;
