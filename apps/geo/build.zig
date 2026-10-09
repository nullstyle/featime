//! geo: a small terminal editor over a globe timeline and region
//! timelines — featime's first real consumer. It drives links (live and
//! pinned), parameters, chapters, labeled transactions, the history
//! panel, background rebuilds and persistence from one command script.
//!
//!   zig build run                       walk through scenarios/tour.txt
//!   zig build run -- path/to/script     run another script
//!   zig build test                      the editor's own tests
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ft_dep = b.dependency("featime", .{ .target = target, .optimize = optimize });
    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "featime", .module = ft_dep.module("featime") }},
    });

    const exe = b.addExecutable(.{ .name = "featime-geo", .root_module = root });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    run.setCwd(b.path("."));
    b.step("run", "Run the tour, or a script given as an argument").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = root });
    b.step("test", "Run the editor's tests").dependOn(&b.addRunArtifact(tests).step);
}
