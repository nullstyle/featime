//! The checkpoint cache, made visible: the Domain counts how many times it
//! actually applied a feature, so the output shows which work the library
//! avoided.
//!
//! Run: zig build caching

const std = @import("std");
const Io = std.Io;
const ft = @import("featuretree_zig");
const common = @import("common.zig");

/// Total successful feature applications — the library never sees this; it
/// exists so the example can *prove* the cache behavior.
var applies: usize = 0;

const Accumulator = struct {
    pub const Doc = struct { value: i64 = 0 };

    pub const Op = union(enum) {
        add: i64,
        multiply: i64,
    };

    pub fn apply(op: Op, doc: *Doc, ctx: *ft.ApplyContext) anyerror!void {
        _ = ctx;
        switch (op) {
            .add => |n| doc.value += n,
            .multiply => |n| doc.value *= n,
        }
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

fn report(out: *Io.Writer, tl: *ft.Timeline(Accumulator), label: []const u8) !void {
    try out.print("{s:<28} value = {d:<8} applies so far = {d}\n", .{ label, tl.state().value, applies });
}

fn demo(out: *Io.Writer, arena: std.mem.Allocator) !void {
    // Config knobs are the memory/latency tradeoff for big documents:
    // checkpoint_interval (extra checkpoints per N applied features during a
    // rebuild), max_checkpoints (document copies kept), checkpoint_on_scrub
    // (snapshot when the marker leaves a position).
    var tl = try ft.Timeline(Accumulator).init(arena, .{}, .{
        .checkpoint_interval = 4,
        .max_checkpoints = 8,
        .checkpoint_on_scrub = true,
    });
    defer tl.deinit();

    var ids: [12]ft.FeatureId = undefined;
    for (&ids, 0..) |*slot, i| {
        slot.* = try tl.commit(.{ .add = @intCast(i + 1) });
    }
    try report(out, &tl, "12 commits (fast path)"); // 12 applies, no checkpoints yet

    // An edit below every checkpoint forces one full chunked replay — and
    // lays down checkpoints at 4, 8 along the way.
    try tl.edit(ids[0], .{ .add = 100 });
    try report(out, &tl, "edit feature 0"); // +12 applies

    // An edit in the middle: only the dirty suffix replays (features 8..11).
    try tl.edit(ids[8], .{ .multiply = -1 });
    try report(out, &tl, "edit feature 8"); // +4 applies, from the checkpoint at 8

    // Scrub back to 9: exact snapshot taken when the marker left positions.
    tl.setMarker(9);
    try report(out, &tl, "scrub back to 9"); // +0 applies

    // ...and forward again — the snapshot at 12 restores instantly.
    tl.setMarker(12);
    try report(out, &tl, "scrub forward to 12"); // +0 applies

    // Scrub the whole way back: position 0 is the seed itself, so even
    // this costs nothing.
    tl.setMarker(0);
    try report(out, &tl, "scrub to 0"); // +0 applies

    try out.print(
        "\ntotal: {d} applications for a session that touched ~{d} feature-steps —\n" ++
            "the rest were served by checkpoints and dirty-range tracking.\n",
        .{ applies, 12 * 6 },
    );
}

pub fn main(init: std.process.Init) !void {
    return common.run(init, "caching: apply counting shows what the cache saves", demo);
}
