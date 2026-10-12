const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const core = b.addModule("odm_core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const core_tests = b.addTest(.{
        .name = "odm-core-tests",
        .root_module = core,
    });
    const run_core_tests = b.addRunArtifact(core_tests);

    const http_tests = b.addTest(.{
        .name = "odm-http-tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/protocols/http/download.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_http_tests = b.addRunArtifact(http_tests);

    const test_step = b.step("test", "Run core unit tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_http_tests.step);

    const odm = b.addExecutable(.{
        .name = "odm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(odm);
}
