const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ---- storage engine module (M1: no HTTP, no networking) ----
    const storage = b.addModule("storage", .{
        .root_source_file = b.path("src/storage.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ---- unit tests ----
    const unit_tests = b.addTest(.{
        .name = "storage-tests",
        .root_module = storage,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    run_unit_tests.has_side_effects = true;

    const test_step = b.step("test", "Run storage engine unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // ---- M1 verification harness ----
    // Proves the exit conditions in docs/08-roadmap.md M1. Separate binaries
    // because the crash harness re-executes itself as a child process.
    inline for (.{ "m1", "crashchild" }) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/" ++ name ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "storage", .module = storage }},
            }),
        });
        b.installArtifact(exe);
    }

    const verify_step = b.step("verify", "Build the M1 exit-condition harness");
    verify_step.dependOn(b.getInstallStep());
}
