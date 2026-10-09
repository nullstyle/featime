//! Forks, cherry-picks, and format migration.
//!
//! `persistence.savePrefix` writes the first N features as an independent
//! container (a scenario variant with its own identity); `cherryPick`
//! copies one feature between timelines; a Domain that bumps its
//! `format_version` loads older files through `migrateOp` / `migrateDoc`.
//!
//! Run: zig build forks

const std = @import("std");
const Io = std.Io;
const ft = @import("featuretree_zig");
const common = @import("common.zig");

/// The app as it shipped last year: format version 0 (implicit).
const LedgerV0 = struct {
    pub const Doc = struct { total: i64 = 0 };
    pub const Op = union(enum) { add: i64, multiply: i64 };

    pub fn apply(op: Op, doc: *Doc, ctx: *ft.ApplyContext) anyerror!void {
        _ = ctx;
        switch (op) {
            .add => |n| doc.total += n,
            .multiply => |n| doc.total *= n,
        }
    }
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
        }
    }
    pub fn decodeOp(r: *Io.Reader, gpa: std.mem.Allocator) anyerror!Op {
        _ = gpa;
        return switch ((try r.take(1))[0]) {
            1 => .{ .add = try r.takeInt(i64, .little) },
            2 => .{ .multiply = try r.takeInt(i64, .little) },
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

/// The app today: `multiply` grew a `rounding` flag, so the op encoding
/// changed and `format_version` is 1. Old files still open: the migrate
/// hooks decode version-0 payloads with the old layout.
const Ledger = struct {
    pub const format_version: u32 = 1;
    pub const Doc = struct { total: i64 = 0 };
    pub const Op = union(enum) {
        add: i64,
        multiply: struct { by: i64, round_up: bool },
    };

    pub fn apply(op: Op, doc: *Doc, ctx: *ft.ApplyContext) anyerror!void {
        _ = ctx;
        switch (op) {
            .add => |n| doc.total += n,
            .multiply => |m| doc.total = doc.total * m.by + @as(i64, if (m.round_up) 1 else 0),
        }
    }
    pub fn encodeOp(op: Op, w: *Io.Writer) anyerror!void {
        switch (op) {
            .add => |n| {
                try w.writeAll(&[1]u8{1});
                try w.writeInt(i64, n, .little);
            },
            .multiply => |m| {
                try w.writeAll(&[2]u8{ 2, @intFromBool(m.round_up) });
                try w.writeInt(i64, m.by, .little);
            },
        }
    }
    pub fn decodeOp(r: *Io.Reader, gpa: std.mem.Allocator) anyerror!Op {
        _ = gpa;
        return switch ((try r.take(1))[0]) {
            1 => .{ .add = try r.takeInt(i64, .little) },
            2 => blk: {
                const round_up = (try r.take(1))[0] != 0;
                break :blk .{ .multiply = .{ .by = try r.takeInt(i64, .little), .round_up = round_up } };
            },
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

    // -- migration from version 0 ----------------------------------------
    pub fn migrateOp(from: u32, r: *Io.Reader, gpa: std.mem.Allocator) anyerror!Op {
        if (from != 0) return error.UnsupportedFormatVersion;
        return switch (try LedgerV0.decodeOp(r, gpa)) {
            .add => |n| .{ .add = n },
            .multiply => |n| .{ .multiply = .{ .by = n, .round_up = false } },
        };
    }
    pub fn migrateDoc(from: u32, r: *Io.Reader, gpa: std.mem.Allocator) anyerror!Doc {
        if (from != 0) return error.UnsupportedFormatVersion;
        return .{ .total = (try LedgerV0.decodeDoc(r, gpa)).total };
    }
};

fn demo(out: *Io.Writer, arena: std.mem.Allocator) !void {
    // 1. A file written by last year's app.
    var old = try ft.Timeline(LedgerV0).init(arena, .{}, .{});
    defer old.deinit();
    _ = try old.commit(.{ .add = 10 });
    _ = try old.commit(.{ .multiply = 3 });
    _ = try old.commit(.{ .add = 5 });
    var old_file: Io.Writer.Allocating = .init(arena);
    try ft.persistence.save(LedgerV0, &old, arena, &old_file.writer);
    try out.print("old app saved {d} features (format 0): total = {d}\n", .{ old.len(), old.state().total });

    // 2. Today's app opens it: ops migrate through the hooks.
    var reader = Io.Reader.fixed(old_file.written());
    var tl = try ft.persistence.load(Ledger, arena, .{}, &reader);
    defer tl.deinit();
    try out.print("new app loaded it (format 1):   total = {d}\n", .{tl.state().total});
    var it = tl.features();
    _ = it.next();
    const second = it.next().?;
    try out.print("migrated op: multiply by {d}, round_up = {}\n", .{ second.op.multiply.by, second.op.multiply.round_up });
    const third = it.next().?.id;

    // 3. Fork at a chapter: the prefix becomes an independent variant.
    const chapter = try tl.addChapter("before the bonus", .{ .after = second.id });
    var fork_file: Io.Writer.Allocating = .init(arena);
    try ft.persistence.savePrefix(Ledger, &tl, arena, &fork_file.writer, tl.chapterPosition(chapter).?, .{ .timeline_id = 0xF0F0 });
    var fork_reader = Io.Reader.fixed(fork_file.written());
    var variant = try ft.persistence.load(Ledger, arena, .{}, &fork_reader);
    defer variant.deinit();
    try out.print("\nvariant forked at '{s}': {d} features, total = {d}, own id = {}\n", .{
        tl.chapters()[0].name, variant.len(), variant.state().total, variant.timelineId() != tl.timelineId(),
    });

    // 4. Cherry-pick the feature the fork left behind, then diverge.
    const picked = try variant.cherryPick(&tl, third, .{});
    _ = try variant.commit(.{ .multiply = .{ .by = 2, .round_up = true } });
    try out.print("variant after cherry-pick + a new edit: total = {d} (picked id lives here: {})\n", .{
        variant.state().total, variant.featureById(picked) != null,
    });
    try out.print("original untouched:                     total = {d}\n", .{tl.state().total});
}

pub fn main(init: std.process.Init) !void {
    return common.run(init, "forks: savePrefix, cherryPick, format migration", demo);
}
