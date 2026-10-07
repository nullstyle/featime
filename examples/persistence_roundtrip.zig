//! Persistence: the Domain writes the bytes for its own ops and seed
//! document; the library frames them in a small versioned container that
//! round-trips ids, order, suppression, and the marker.
//!
//! Run: zig build persistence_roundtrip

const std = @import("std");
const Io = std.Io;
const ft = @import("featuretree_zig");
const common = @import("common.zig");

const Ledger = struct {
    pub const Doc = struct { total: i64 = 0 };

    pub const Op = union(enum) {
        add: i64,
        multiply: i64,
        /// Fails whenever the total would go negative — shows that statuses
        /// (error badges) recompute after loading instead of persisting.
        clamp_positive: void,
    };

    pub fn apply(op: Op, doc: *Doc, ctx: *ft.ApplyContext) anyerror!void {
        switch (op) {
            .add => |n| doc.total += n,
            .multiply => |n| doc.total *= n,
            .clamp_positive => {
                if (doc.total < 0) return ctx.fail("total {d} is negative", .{doc.total});
            },
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

    // -- codecs: the app owns its op/seed byte formats ---------------------

    pub fn encodeOp(op: Op, w: *Io.Writer) anyerror!void {
        switch (op) {
            .add => |n| {
                try w.writeAll(&[1]u8{1});
                try w.writeInt(i64, n, .little);
            },
            .multiply => |n| {
                try w.writeAll(&[1]u8{2});
                try w.writeInt(i64, n, .little);
            },
            .clamp_positive => try w.writeAll(&[1]u8{3}),
        }
    }

    pub fn decodeOp(r: *Io.Reader, gpa: std.mem.Allocator) anyerror!Op {
        _ = gpa;
        return switch ((try r.take(1))[0]) {
            1 => .{ .add = try r.takeInt(i64, .little) },
            2 => .{ .multiply = try r.takeInt(i64, .little) },
            3 => .{ .clamp_positive = {} },
            else => error.Malformed,
        };
    }

    pub fn encodeDoc(doc: *const Doc, w: *Io.Writer) anyerror!void {
        try w.writeInt(i64, doc.total, .little);
    }

    pub fn decodeDoc(r: *Io.Reader, gpa: std.mem.Allocator) anyerror!Doc {
        _ = gpa;
        return .{ .total = try r.takeInt(i64, .little) };
    }
};

fn demo(out: *Io.Writer, arena: std.mem.Allocator) !void {
    var tl = try ft.Timeline(Ledger).init(arena, .{ .total = 7 }, .{});
    defer tl.deinit();

    const a = try tl.commit(.{ .add = 10 });
    const b = try tl.commit(.{ .multiply = 2 });
    _ = try tl.commit(.{ .add = -40 });
    _ = try tl.commit(.{ .clamp_positive = {} }); // fails: total is negative
    tl.setSuppressed(b, true);
    tl.setMarker(3); // rolled partway back: add(10), multiply(suppressed), add(-40)
    _ = tl.state();
    try out.print("saved state:         total = {d}   marker {d}/{d}\n", .{ tl.state().total, tl.marker(), tl.len() });

    // Serialize into memory (a file works identically — any Writer).
    var buffer: std.Io.Writer.Allocating = .init(arena);
    try ft.persistence.save(Ledger, &tl, arena, &buffer.writer);
    try out.print("container:           {d} bytes\n", .{buffer.written().len});

    // Load into a fresh timeline with its own config.
    var reader = std.Io.Reader.fixed(buffer.written());
    var loaded = try ft.persistence.load(Ledger, arena, .{}, &reader);
    defer loaded.deinit();

    try out.print("loaded:              total = {d}   marker {d}/{d}\n", .{ loaded.state().total, loaded.marker(), loaded.len() });
    try out.print("ids stable:          {}\n", .{loaded.featureById(a) != null});

    // Suppression survived; statuses recomputed.
    try out.print("suppression kept:    multiply suppressed = {}\n", .{loaded.featureById(b).?.suppressed});

    // Rolling to the end re-runs clamp_positive on a negative total: the
    // error badge is *recomputed*, not stored.
    loaded.setMarker(loaded.len());
    _ = loaded.state();
    var last_id: ft.FeatureId = 0;
    var it = loaded.features();
    while (it.next()) |f| last_id = f.id;
    try out.print("rolled to end:       total = {d}   last feature failed: \"{s}\"\n", .{
        loaded.state().total,
        loaded.featureById(last_id).?.status.failed,
    });
}

pub fn main(init: std.process.Init) !void {
    return common.run(init, "persistence_roundtrip: save/load with app codecs", demo);
}
