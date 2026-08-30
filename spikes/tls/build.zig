const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tls = b.dependency("tls", .{ .target = target, .optimize = optimize });

    inline for (.{ "tlsserver", "nonblock" }) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(name ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "tls", .module = tls.module("tls") }},
            }),
        });
        b.installArtifact(exe);
    }
}
