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
            .root_source_file = b.path("src/protocols/http/download.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
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
    b.installArtifact(speed_download);

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
            .root_source_file = b.path("src/ipc/unix.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    const ipc_unix_step = b.step("ipc-unix", "Compile Unix-domain IPC transport for macOS or Linux");
    ipc_unix_step.dependOn(&ipc_unix.step);
}
