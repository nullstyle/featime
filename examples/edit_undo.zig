//! Editing the timeline: parametric edits, removal, suppression, and
//! undo/redo — including how undo restores the marker to where it was when
//! the edit was made.
//!
//! Run: zig build edit_undo

const std = @import("std");
const Io = std.Io;
const ft = @import("featuretree_zig");
const common = @import("common.zig");

const Stage = struct {
    pub const Doc = struct { brightness: f64 = 0 };

    pub const Op = union(enum) {
        set: struct { level: f64 },
        scale: struct { factor: f64 },
    };

    pub fn apply(op: Op, doc: *Doc, ctx: *ft.ApplyContext) anyerror!void {
        switch (op) {
            .set => |s| doc.brightness = s.level,
            .scale => |f| {
                const scaled = doc.brightness * f.factor;
                if (scaled > 100.0 or scaled < 0.0)
                    return ctx.fail("brightness {d} out of range", .{scaled});
                doc.brightness = scaled;
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
};

fn demo(out: *Io.Writer, arena: std.mem.Allocator) !void {
    var tl = try ft.Timeline(Stage).init(arena, .{}, .{});
    defer tl.deinit();

    const preset = try tl.commit(.{ .set = .{ .level = 40 } });
    const boost = try tl.commit(.{ .scale = .{ .factor = 1.5 } }); // 60
    _ = try tl.commit(.{ .scale = .{ .factor = 0.5 } }); // 30
    try out.print("built:               brightness = {d:.1}\n", .{tl.state().brightness});

    // Parametric edit: change a past feature's parameters; downstream
    // features recompute automatically.
    try tl.edit(boost, .{ .scale = .{ .factor = 2.0 } }); // 40 * 2 * 0.5
    try out.print("edit boost x2.0:     brightness = {d:.1}\n", .{tl.state().brightness});

    // Suppress: the feature stays on the timeline but is skipped.
    try tl.setSuppressed(boost, true); // 40 * 0.5
    try out.print("suppress boost:      brightness = {d:.1}\n", .{tl.state().brightness});

    // Remove: gone from the timeline; the marker adjusts.
    try tl.remove(boost); // 40 * 0.5, len 2
    try out.print("remove boost:        brightness = {d:.1}   len {d}\n", .{ tl.state().brightness, tl.len() });

    // Undo walks the edits back in reverse; ids survive undo/redo.
    _ = tl.undo(); // undo the removal
    try out.print("undo remove:         brightness = {d:.1}   boost back: {}\n", .{ tl.state().brightness, tl.featureById(boost) != null });
    _ = tl.undo(); // undo the suppression
    try out.print("undo suppress:       brightness = {d:.1}\n", .{tl.state().brightness});
    _ = tl.redo();
    try out.print("redo suppress:       brightness = {d:.1}\n", .{tl.state().brightness});

    // Undo restores the marker to where it was when the edit happened: roll
    // back, commit mid-history, then undo.
    tl.setMarker(1);
    _ = tl.state();
    _ = try tl.commit(.{ .set = .{ .level = 80 } }); // marker 1 -> 2
    try out.print("mid-history commit:  marker {d}\n", .{tl.marker()});
    _ = tl.undo();
    try out.print("undo that commit:    marker {d} (restored)\n", .{tl.marker()});

    // A new edit clears the redo stack, as in any editor.
    try tl.edit(preset, .{ .set = .{ .level = 10 } });
    try out.print("new edit:            canRedo = {}   brightness = {d:.1}\n", .{ tl.canRedo(), tl.state().brightness });
}

pub fn main(init: std.process.Init) !void {
    return common.run(init, "edit_undo: parametric edit, suppress, remove, undo/redo", demo);
}
