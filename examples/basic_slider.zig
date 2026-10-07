//! The smallest useful timeline: a running total.
//!
//! Shows the core slider semantics — commit, scrub the marker back and
//! forth, and commit *while rolled back*, which inserts a feature
//! mid-history (Fusion's rollback editing).
//!
//! Run: zig build basic_slider

const std = @import("std");
const Io = std.Io;
const ft = @import("featuretree_zig");
const common = @import("common.zig");

// ---------------------------------------------------------------------------
// A Domain is the whole integration surface: document type, feature types
// (one tagged union), and how a feature applies. Everything else the library
// needs (cloning documents for checkpoints) is two more small functions.
// ---------------------------------------------------------------------------

const Ledger = struct {
    pub const Doc = struct { total: i64 = 0 };

    pub const Op = union(enum) {
        add: i64,
        multiply: i64,
    };

    pub fn apply(op: Op, doc: *Doc, ctx: *ft.ApplyContext) anyerror!void {
        _ = ctx; // only needed for failures / env — see other examples
        switch (op) {
            .add => |n| doc.total += n,
            .multiply => |n| doc.total *= n,
        }
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

fn demo(out: *Io.Writer, arena: std.mem.Allocator) !void {
    var tl = try ft.Timeline(Ledger).init(arena, .{}, .{});
    defer tl.deinit();

    // Committing appends at the marker (which starts at the end).
    _ = try tl.commit(.{ .add = 10 });
    _ = try tl.commit(.{ .add = 5 });
    _ = try tl.commit(.{ .multiply = 3 }); // (10 + 5) * 3
    try out.print("three commits:       total = {d}   marker {d}/{d}\n", .{ tl.state().total, tl.marker(), tl.len() });

    // Scrub the slider back: the document is the features before the marker.
    tl.setMarker(2);
    try out.print("setMarker(2):        total = {d}   (multiply not applied)\n", .{tl.state().total});
    tl.setMarker(1);
    try out.print("setMarker(1):        total = {d}\n", .{tl.state().total});

    // Committing while rolled back inserts at the marker — mid-history.
    const inserted = try tl.commit(.{ .multiply = 2 }); // 10 * 2
    try out.print("commit at marker 1:  inserted at index 1, marker now {d}/{d}\n", .{ tl.marker(), tl.len() });

    // Roll to the end: only the suffix replays.
    tl.setMarker(tl.len());
    try out.print("roll to end:         total = {d}   ((10 * 2) + 5) * 3\n", .{tl.state().total});

    // Features have stable ids for UI selection / cross-references.
    try out.print("inserted feature id: {d}\n", .{inserted});
}

pub fn main(init: std.process.Init) !void {
    return common.run(init, "basic_slider: commit, scrub, mid-history insert", demo);
}
