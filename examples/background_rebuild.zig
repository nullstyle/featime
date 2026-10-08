//! Background rebuilds: capture the rebuild plan as a pure job, run it on a
//! worker thread, and integrate the result on the owner thread. Also shows
//! the two rejection paths — cancellation and staleness.
//!
//! Run: zig build background_rebuild

const std = @import("std");
const Io = std.Io;
const ft = @import("featuretree_zig");
const common = @import("common.zig");

/// Simulates an expensive feature: each apply does real (if pointless) work,
/// so doing it off the UI thread matters.
var applies: usize = 0;

const Renderer = struct {
    pub const Doc = struct { frame: u64 = 0 };

    pub const Op = union(enum) {
        pass: struct { iterations: u32 },
    };

    pub fn apply(op: Op, doc: *Doc, ctx: *ft.ApplyContext) anyerror!void {
        _ = ctx;
        var acc: u64 = doc.frame;
        var i: u32 = 0;
        while (i < op.pass.iterations) : (i += 1) {
            acc = acc *% 6364136223846793005 +% 1442695040888963407;
        }
        doc.frame = acc;
        applies += 1;
    }

    pub fn cloneDoc(doc: *const Doc, gpa: std.mem.Allocator) anyerror!Doc {
        _ = gpa;
        return doc.*;
    }

    pub fn deinitDoc(doc: *Doc, gpa: std.mem.Allocator) void {
        _ = doc;
        _ = gpa;
    }
};

const Timeline = ft.Timeline(Renderer);

fn demo(out: *Io.Writer, arena: std.mem.Allocator) !void {
    var tl = try Timeline.init(arena, .{}, .{});
    defer tl.deinit();

    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        _ = try tl.commit(.{ .pass = .{ .iterations = 1_000_000 } });
    }
    _ = tl.state();
    const baseline = tl.state().frame;
    try out.print("8 expensive passes applied:  frame = {d}  (applies: {d})\n", .{ baseline, applies });

    // Make the timeline dirty: scrub back, then edit a feature so a real
    // rebuild (not just a suffix extension) is needed.
    tl.setMarker(8);
    var first: ft.FeatureId = 0;
    var it = tl.features();
    if (it.next()) |f| first = f.id;
    try tl.edit(first, .{ .pass = .{ .iterations = 2_000_000 } });
    if (!tl.dirty()) return error.ExpectedDirty;
    try out.print("edited feature 0:            dirty = {}\n", .{tl.dirty()});

    // 1. Cancellation: the UI thread changes its mind mid-frame.
    {
        var job = try tl.beginRebuild();
        defer job.deinit();
        job.cancel();
        job.run(); // notices the flag before the first feature
        const integrated = tl.integrate(&job);
        try out.print("cancelled job:               integrated = {}  dirty = {}\n", .{ integrated, tl.dirty() });
    }

    // 2. Staleness: the plan changes while the job is in flight. Here the
    //    mutation happens deterministically between begin and run.
    {
        var job = try tl.beginRebuild();
        defer job.deinit();
        _ = try tl.commit(.{ .pass = .{ .iterations = 1 } }); // bumps generation
        job.run();
        const integrated = tl.integrate(&job);
        try out.print("stale job:                   integrated = {}\n", .{integrated});
    }

    // 3. The real thing: run on a worker thread while the "UI" stays free.
    {
        applies = 0;
        var job = try tl.beginRebuild();
        const thread = try std.Thread.spawn(.{}, ft.rebuild.Job(Renderer).run, .{&job});
        // ...the UI thread could render, poll input, etc. here...
        thread.join();
        const integrated = tl.integrate(&job);
        try out.print("worker-thread job:           integrated = {}  dirty = {}\n", .{ integrated, tl.dirty() });
        try out.print("recomputed on the worker:    applies during job = {d}\n", .{applies});
    }

    // A successful integrate leaves the timeline clean; state() remains the
    // synchronous fallback and agrees with the job.
    if (tl.dirty()) return error.ExpectedDirty;
    try out.print("final frame:                 {d} (changed from {d})\n", .{ tl.state().frame, baseline });
}

pub fn main(init: std.process.Init) !void {
    return common.run(init, "background_rebuild: jobs, cancellation, staleness", demo);
}
