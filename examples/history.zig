//! History introspection and memory pressure: labeled transactions, the
//! `history()` iterator for a history panel, `stats()`, and `trim()`.
//!
//! Run: zig build history

const std = @import("std");
const Io = std.Io;
const ft = @import("featuretree_zig");
const common = @import("common.zig");

var clock_now: u64 = 1_000;
fn now() u64 {
    clock_now += 1;
    return clock_now;
}

const Ledger = struct {
    pub const Doc = struct { total: i64 = 0 };
    pub const Op = union(enum) { add: i64, multiply: i64 };

    pub fn apply(op: Op, doc: *Doc, ctx: *ft.ApplyContext) anyerror!void {
        _ = ctx;
        switch (op) {
            .add => |n| doc.total += n,
            .multiply => |n| doc.total *= n,
        }
    }
};

const Tl = ft.Timeline(Ledger);

fn printHistory(out: *Io.Writer, tl: *const Tl) !void {
    var it = tl.history();
    while (it.next()) |u| {
        try out.print("  {d}: {s:<9} entries={d} ts={d} label={s}{s}\n", .{
            u.index,
            @tagName(u.kind),
            u.entries,
            u.ts,
            if (u.label) |l| l else "-",
            if (u.undone) "  (undone)" else "",
        });
    }
}

fn demo(out: *Io.Writer, arena: std.mem.Allocator) !void {
    var tl = try Tl.init(arena, .{}, .{ .now = now, .checkpoint_on_scrub = true, .max_checkpoints = 8 });
    defer tl.deinit();

    // Plain edits are one unit each; a labeled transaction is one unit with
    // a name a history panel can show ("Undo tune").
    const base = try tl.commit(.{ .add = 10 });
    _ = try tl.commit(.{ .multiply = 3 });
    try tl.beginLabeledTransaction("tune");
    try tl.edit(base, .{ .add = 12 });
    try tl.setFeatureName(base, "base value");
    tl.endTransaction();

    try out.print("history ({d} undoable, {d} redoable):\n", .{ tl.undoDepth(), tl.redoDepth() });
    try printHistory(out, &tl);

    _ = tl.undo();
    try out.print("\nafter one undo ({d} undoable, {d} redoable):\n", .{ tl.undoDepth(), tl.redoDepth() });
    try printHistory(out, &tl);

    // Scrubbing leaves snapshots behind; stats() shows what is held.
    tl.setMarker(1);
    _ = tl.state();
    tl.setMarker(2);
    _ = tl.state();
    const before = tl.stats();
    try out.print("\nstats: {d} features, {d} checkpoints, {d} journal entries, {d}/{d} undo/redo units\n", .{
        before.features, before.checkpoints, before.journal_entries, before.undo_units, before.redo_units,
    });

    // Under memory pressure: keep one checkpoint and one undo unit, drop redo.
    const trimmed = tl.trim(.{ .checkpoints = 1, .undo_units = 1, .drop_redo = true });
    const after = tl.stats();
    try out.print("trim: dropped {d} checkpoints and {d} journal entries -> {d} checkpoints, {d}/{d} units; total still {d}\n", .{
        trimmed.checkpoints, trimmed.journal_entries, after.checkpoints, after.undo_units, after.redo_units, tl.state().total,
    });
}

pub fn main(init: std.process.Init) !void {
    return common.run(init, "history: labeled transactions, history(), stats(), trim()", demo);
}
