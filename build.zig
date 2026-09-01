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

    // ---- transport (M2: io_uring loop, HTTP/1.1 framing, pooled connections) ----
    // Depends on the engine for its syscall layer and the read-slot size, and on the
    // request layer for the error catalogue. Knows nothing about endpoints: routing
    // plugs in above it through `server.Handler`.
    const server = b.addModule("server", .{
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "storage", .module = storage },
            .{ .name = "api", .module = api },
        },
    });

    // ---- data plane (M2: router, authentication, rate limiting, the endpoints) ----
    // The composition layer, and the only module that imports all four below it (D58).
    const service = b.addModule("service", .{
        .root_source_file = b.path("src/service.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "storage", .module = storage },
            .{ .name = "control", .module = control },
            .{ .name = "api", .module = api },
            .{ .name = "server", .module = server },
        },
    });

    // ---- process layer (M2: configuration, maintenance thread, signals) ----
    // What turns an environment and a signal into a running, stoppable Doot. Separate
    // from main.zig for one reason: it can be tested and a main.zig cannot (D63).
    const boot = b.addModule("boot", .{
        .root_source_file = b.path("src/boot.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "storage", .module = storage },
            .{ .name = "control", .module = control },
            .{ .name = "api", .module = api },
            .{ .name = "server", .module = server },
        },
    });

    // ---- unit tests ----
    const test_step = b.step("test", "Run unit tests");

    // `has_side_effects` on each: the tests touch the filesystem, so caching a
    // pass would defeat the point of running them.
    inline for (.{
        .{ "storage-tests", storage },
        .{ "control-tests", control },
        .{ "api-tests", api },
        .{ "server-tests", server },
        .{ "service-tests", service },
        .{ "boot-tests", boot },
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

    // ---- M2 transport harness ----
    // The real event loop behind a fixed handler, so an HTTP client we did not write
    // can judge our framing. Driven by tools/transport-check.sh.
    const transport = b.addExecutable(.{
        .name = "transport",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/transport.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "server", .module = server },
                .{ .name = "storage", .module = storage },
            },
        }),
    });
    b.installArtifact(transport);

    // ---- M2 data-plane harness ----
    // The real service over a real store, so curl can exercise the endpoints.
    const dataplane = b.addExecutable(.{
        .name = "dataplane",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/dataplane.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "storage", .module = storage },
                .{ .name = "control", .module = control },
                .{ .name = "server", .module = server },
                .{ .name = "service", .module = service },
            },
        }),
    });
    b.installArtifact(dataplane);

    // ---- the origin binary ----
    // The deployable artifact: one statically linked executable, one process, one machine
    // (05-architecture.md). A composition root over the modules above (D63).
    const doot = b.addExecutable(.{
        .name = "doot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "storage", .module = storage },
                .{ .name = "control", .module = control },
                .{ .name = "server", .module = server },
                .{ .name = "service", .module = service },
                .{ .name = "boot", .module = boot },
            },
        }),
    });
    b.installArtifact(doot);

    const verify_step = b.step("verify", "Build the exit-condition harnesses");
    verify_step.dependOn(b.getInstallStep());
}
