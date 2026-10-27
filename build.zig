const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core = b.addModule("speed_download_core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const core_tests = b.addTest(.{
        .name = "speed-download-core-tests",
        .root_module = core,
    });
    if (target.result.os.tag == .macos) core_tests.root_module.addCSourceFile(.{ .file = b.path("src/core/posix_stat_macos.c"), .flags = &.{} });
    const run_core_tests = b.addRunArtifact(core_tests);

    const queue_tests = b.addTest(.{
        .name = "speed-download-queue-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/core/queue.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_queue_tests = b.addRunArtifact(queue_tests);

    const http_tests = b.addTest(.{
        .name = "speed-download-http-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_http.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (target.result.os.tag == .macos) {
        http_tests.root_module.linkFramework("Security", .{});
        http_tests.root_module.addCSourceFile(.{ .file = b.path("src/core/posix_stat_macos.c"), .flags = &.{} });
    }
    const run_http_tests = b.addRunArtifact(http_tests);

    const test_step = b.step("test", "Run core and HTTP unit tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_queue_tests.step);
    test_step.dependOn(&run_http_tests.step);

    const speed_download = b.addExecutable(.{
        .name = "speed-download",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = target.result.os.tag == .macos or target.result.os.tag == .linux,
        }),
    });
    if (target.result.os.tag == .macos) {
        speed_download.root_module.linkFramework("Security", .{});
        speed_download.root_module.addCSourceFile(.{ .file = b.path("src/core/posix_stat_macos.c"), .flags = &.{} });
    }
    b.installArtifact(speed_download);

    const browser_host = b.addExecutable(.{
        .name = "speed-download-browser-host",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/browser_host.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = target.result.os.tag == .macos or target.result.os.tag == .linux,
        }),
    });
    b.installArtifact(browser_host);

    const ipc_primitives = b.addObject(.{
        .name = "speed-download-ipc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ipc/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const ipc_step = b.step("ipc", "Compile the local IPC protocol primitives");
    ipc_step.dependOn(&ipc_primitives.step);

    const ipc_unix = b.addObject(.{
        .name = "speed-download-ipc-unix",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ipc_unix_build.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    if (target.result.os.tag == .macos) ipc_unix.root_module.addCSourceFile(.{ .file = b.path("src/core/posix_stat_macos.c"), .flags = &.{} });
    const ipc_unix_step = b.step("ipc-unix", "Compile Unix-domain IPC transport for macOS or Linux");
    ipc_unix_step.dependOn(&ipc_unix.step);
}
