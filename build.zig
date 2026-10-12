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
    const test_step = b.step("test", "Run core unit tests");
    test_step.dependOn(&run_core_tests.step);
}
