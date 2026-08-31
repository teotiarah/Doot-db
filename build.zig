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

    // ---- control-plane state (M2: accounts, API keys, credits) ----
    // Depends on the engine only for its syscall layer, checksum and clock.
    const control = b.addModule("control", .{
        .root_source_file = b.path("src/control.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "storage", .module = storage }},
    });

    // ---- request layer (M2: parsing, cursors, names, error catalogue) ----
    // Pure functions over request bytes. No sockets, so it is testable on its own.
    const api = b.addModule("api", .{
        .root_source_file = b.path("src/api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "storage", .module = storage }},
    });

    // ---- unit tests ----
    const test_step = b.step("test", "Run unit tests");

    // `has_side_effects` on each: the tests touch the filesystem, so caching a
    // pass would defeat the point of running them.
    inline for (.{
        .{ "storage-tests", storage },
        .{ "control-tests", control },
        .{ "api-tests", api },
    }) |t| {
        const unit_tests = b.addTest(.{ .name = t[0], .root_module = t[1] });
        const run_unit_tests = b.addRunArtifact(unit_tests);
        run_unit_tests.has_side_effects = true;
        test_step.dependOn(&run_unit_tests.step);
    }

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
