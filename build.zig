//! Build graph for featime.
//!
//!   zig build                 build the terrain-editor demo (zig-out/bin/featime-demo)
//!   zig build run             run the demo
//!   zig build test            unit + differential tests (honors -Doptimize)
//!   zig build examples        run every usage example; `zig build <name>` runs one
//!   zig build bench           benchmark suite (always ReleaseFast; -Dbench-max=N caps the size)
//!   zig build docs            API reference into zig-out/docs
//!
//! Consumers import the `featime` module:
//!
//!   const dep = b.dependency("featime", .{ .target = target, .optimize = optimize });
//!   exe.root_module.addImport("featime", dep.module("featime"));
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library. `optimize` is set here so `-Doptimize=...` reaches the
    // library's own tests (below) and not just the demo.
    const mod = b.addModule("featime", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Terrain-editor demo exercising every capability end-to-end.
    const demo = b.addExecutable(.{
        .name = "featime-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "featime", .module = mod }},
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
            .imports = &.{.{ .name = "featime", .module = mod }},
        }),
    });

    // Hardening: the out-of-memory sweep and the fuzz smoke runs
    // (`zig build test --fuzz` keeps fuzzing).
    const oom_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/oom.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "featime", .module = mod }},
        }),
    });
    const fuzz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fuzz.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "featime", .module = mod }},
        }),
    });
    const session_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/session.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "featime", .module = mod }},
        }),
    });

    const test_step = b.step("test", "Run unit, differential, out-of-memory and fuzz tests");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);
    test_step.dependOn(&b.addRunArtifact(demo_tests).step);
    test_step.dependOn(&b.addRunArtifact(oracle_tests).step);
    test_step.dependOn(&b.addRunArtifact(oom_tests).step);
    test_step.dependOn(&b.addRunArtifact(fuzz_tests).step);
    test_step.dependOn(&b.addRunArtifact(session_tests).step);

    // API reference: `zig build docs`, then open zig-out/docs/index.html.
    const docs_obj = b.addObject(.{ .name = "featime", .root_module = mod });
    const docs_install = b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    b.step("docs", "Generate the API reference into zig-out/docs").dependOn(&docs_install.step);

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
        "sync_peers",
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
                .imports = &.{.{ .name = "featime", .module = mod }},
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
        .name = "featime-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "featime", .module = bench_lib },
                .{ .name = "build_options", .module = bench_options.createModule() },
            },
        }),
    });
    const run_bench = b.addRunArtifact(bench);
    b.step("bench", "Run the benchmark suite (ReleaseFast; -Dbench-max=N caps the size)").dependOn(&run_bench.step);
}
