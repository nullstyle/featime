//! Build graph for featuretree-zig.
//!
//!   zig build                 build the terrain-editor demo (zig-out/bin/featuretree-demo)
//!   zig build run             run the demo
//!   zig build test            unit + differential tests (honors -Doptimize)
//!   zig build examples        run every usage example; `zig build <name>` runs one
//!   zig build bench           benchmark suite (always ReleaseFast; -Dbench-max=N caps the size)
//!
//! Consumers import the `featuretree_zig` module:
//!
//!   const dep = b.dependency("featuretree_zig", .{ .target = target, .optimize = optimize });
//!   exe.root_module.addImport("featuretree_zig", dep.module("featuretree_zig"));
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library. `optimize` is set here so `-Doptimize=...` reaches the
    // library's own tests (below) and not just the demo.
    const mod = b.addModule("featuretree_zig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Terrain-editor demo exercising every capability end-to-end.
    const demo = b.addExecutable(.{
        .name = "featuretree-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "featuretree_zig", .module = mod }},
        }),
    });
    b.installArtifact(demo);

    const run_step = b.step("run", "Run the terrain-editor demo");
    const run_demo = b.addRunArtifact(demo);
    run_demo.step.dependOn(b.getInstallStep());
    run_demo.addPassthruArgs();
    run_step.dependOn(&run_demo.step);

    // Tests: the library's co-located unit tests, the demo's smoke tests
    // (including nested_demo.zig), and the differential oracle.
    const mod_tests = b.addTest(.{ .root_module = mod });
    const demo_tests = b.addTest(.{ .root_module = demo.root_module });
    const oracle_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oracle.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "featuretree_zig", .module = mod }},
        }),
    });

    const test_step = b.step("test", "Run unit and differential tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    test_step.dependOn(&b.addRunArtifact(demo_tests).step);
    test_step.dependOn(&b.addRunArtifact(oracle_tests).step);

    // Usage examples: small, commented programs that each teach one part of
    // the API. `zig build <name>` runs one; `zig build examples` runs all.
    const examples_step = b.step("examples", "Run all usage examples");
    const example_names = [_][]const u8{
        "basic_slider",
        "edit_undo",
        "caching",
        "persistence_roundtrip",
        "background_rebuild",
        "annotations",
        "sync",
        "history",
        "forks",
    };
    for (example_names) |name| {
        const example = b.addExecutable(.{
            .name = b.fmt("example-{s}", .{name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "featuretree_zig", .module = mod }},
            }),
        });
        const run_example = b.addRunArtifact(example);
        b.step(name, b.fmt("Run the {s} example", .{name})).dependOn(&run_example.step);
        examples_step.dependOn(&run_example.step);
    }

    // Benchmarks: a separate ReleaseFast instance of the library so numbers
    // never depend on -Doptimize.
    const bench_max = b.option(u32, "bench-max", "Largest timeline the benchmark runs (default 100000)") orelse 100_000;
    const bench_options = b.addOptions();
    bench_options.addOption(u32, "max_features", bench_max);
    const bench_lib = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const bench = b.addExecutable(.{
        .name = "featuretree-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "featuretree_zig", .module = bench_lib },
                .{ .name = "build_options", .module = bench_options.createModule() },
            },
        }),
    });
    const run_bench = b.addRunArtifact(bench);
    b.step("bench", "Run the benchmark suite (ReleaseFast; -Dbench-max=N caps the size)").dependOn(&run_bench.step);
}
