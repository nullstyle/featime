//! The annotation layer: names, tags, chapters, groups, and provenance —
//! user-authored metadata that never affects document computation but
//! participates fully in undo and persistence.
//!
//! Run: zig build annotations

const std = @import("std");
const Io = std.Io;
const ft = @import("featuretree_zig");
const common = @import("common.zig");

/// A monotonic fake clock for provenance timestamps.
var clock_now: u64 = 1_000;

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
    pub fn cloneDoc(doc: *const Doc, gpa: std.mem.Allocator) anyerror!Doc {
        _ = gpa;
        return doc.*;
    }
    pub fn deinitDoc(doc: *Doc, gpa: std.mem.Allocator) void {
        _ = doc;
        _ = gpa;
    }
};

fn printTimeline(tl: *const ft.Timeline(Ledger), out: *Io.Writer) !void {
    var it = tl.features();
    while (it.next()) |f| {
        const label = f.name orelse opLabel(f.op.*);
        try out.print("  #{d:<3} {s:<14}", .{ f.id % 1000, label });
        if (f.suppressed) try out.writeAll(" [suppressed]");
        if (f.meta) |m| {
            if (m.author != 0 and m.ts != 0) {
                try out.print(" (author {d} @ {d})", .{ m.author, m.ts });
            } else if (m.ts != 0) {
                try out.print(" (@ {d})", .{m.ts});
            }
        }
        const tags = tl.tags(f.id);
        if (tags.len > 0) {
            try out.writeAll(" tags:");
            for (tags) |t| try out.print(" {s}", .{t});
        }
        if (tl.groupOf(f.id) != null) try out.print(" [group {d}]", .{tl.groupOf(f.id).? % 1000});
        try out.writeAll("\n");
    }
}

fn opLabel(op: Ledger.Op) []const u8 {
    return switch (op) {
        .add => "add",
        .multiply => "multiply",
    };
}

fn demo(out: *Io.Writer, arena: std.mem.Allocator) !void {
    var tl = try ft.Timeline(Ledger).init(arena, .{}, .{ .now = struct {
        fn now() u64 {
            clock_now += 1;
            return clock_now;
        }
    }.now });
    defer tl.deinit();

    // -- names & provenance --------------------------------------------------
    const base = try tl.commitWithMeta(.{ .add = 10 }, .{ .author = 1 });
    try tl.setFeatureName(base, "base value");
    _ = try tl.commitWithMeta(.{ .multiply = 3 }, .{ .author = 2 });
    const bump = try tl.commit(.{ .add = 5 }); // auto-stamped by Config.now
    try tl.setFeatureName(bump, "final bump");

    try out.print("names + provenance (total {d}):\n", .{tl.state().total});
    try printTimeline(&tl, out);

    // -- tags & filtering ----------------------------------------------------
    try tl.addTag(base, "core");
    try tl.addTag(bump, "review");
    try tl.addTag(bump, "core");
    try out.print("\ntag filter 'core': ", .{});
    var tagged = tl.featuresTagged("core");
    while (tagged.next()) |id| try out.print("#{d} ", .{id % 1000});
    try out.writeAll("\n");

    // -- chapters (slider bookmarks) -----------------------------------------
    const before_bump = try tl.addChapter("before the bump", .{ .after = base });
    try out.print("\nchapter '{s}' resolves to marker {d}/{d}\n", .{ tl.chapters()[0].name, tl.chapterPosition(before_bump).?, tl.len() });
    tl.setMarker(tl.chapterPosition(before_bump).?);
    try out.print("jumped there: total = {d}\n", .{tl.state().total});
    tl.setMarker(tl.len());

    // Chapters follow their anchor across edits: inserting right after the
    // anchor lands BEFORE the chapter's position (feature-pinned semantics).
    _ = try tl.commit(.{ .add = 1 });
    try out.print("after a later commit, chapter still at {d}/{d}\n", .{ tl.chapterPosition(before_bump).?, tl.len() });

    // -- groups ----------------------------------------------------------------
    const g = (try tl.addGroup("setup phase", base, bump)).?;
    try out.print("\ngroup 'setup phase' spans {d} features\n", .{blk: {
        var n: u32 = 0;
        var it = tl.features();
        while (it.next()) |f| {
            if (tl.groupOf(f.id) != null) n += 1;
        }
        break :blk n;
    }});

    try tl.setGroupSuppressed(g, true);
    try out.print("group suppressed:   total = {d} (one undo step)\n", .{tl.state().total});
    _ = tl.undo();
    try out.print("one undo restores:  total = {d}\n", .{tl.state().total});

    // Deleting a group's contents — members, annotations and all — is also
    // a single undo step.
    try tl.removeGroupContents(g);
    try out.print("\ngroup deleted:      {d} features left, total = {d}\n", .{ tl.len(), tl.state().total });
    _ = tl.undo();
    try out.print("one undo restores:  {d} features, total = {d}, bump still named '{s}'\n", .{ tl.len(), tl.state().total, tl.featureName(bump).? });

    // -- annotation edits never dirty the document ---------------------------
    try tl.setFeatureName(base, "renamed");
    try out.print("\nannotation edits leave state clean: dirty = {}\n", .{tl.dirty()});
}

pub fn main(init: std.process.Init) !void {
    return common.run(init, "annotations: names, tags, chapters, groups, provenance", demo);
}
