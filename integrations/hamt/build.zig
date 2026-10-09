//! featuretree-zig + hamt-zig: a persistent map as the timeline's document.
//!
//!   zig build run -Doptimize=ReleaseFast   demo with timings and arena sizes
//!   zig build test                          the demo's own tests
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ft_dep = b.dependency("featuretree_zig", .{ .target = target, .optimize = optimize });
    const hamt_dep = b.dependency("hamt", .{ .target = target, .optimize = optimize });

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "featuretree_zig", .module = ft_dep.module("featuretree_zig") },
            .{ .name = "hamt", .module = hamt_dep.module("hamt") },
        },
    });

    const exe = b.addExecutable(.{ .name = "featuretree-hamt", .root_module = root });
    b.installArtifact(exe);
    b.step("run", "Run the HAMT-backed document demo").dependOn(&b.addRunArtifact(exe).step);

    const tests = b.addTest(.{ .root_module = root });
    b.step("test", "Run the demo's tests").dependOn(&b.addRunArtifact(tests).step);
}
