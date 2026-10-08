//! Demo: a miniature terrain editor with a Fusion-style feature timeline.
//!
//! The document is an 8x8 height grid with placed entities; features are
//! raises, smooths, placements, and a dependency-carrying beautify pass.
//! The scripted walkthrough exercises the slider (scrub, mid-history insert,
//! parametric edit, suppress, reorder with dependency validation, undo/redo,
//! save/load, and a background rebuild) and prints the grid and timeline at
//! every step so the semantics are visible.

const std = @import("std");
const Io = std.Io;
const ft = @import("featuretree_zig");

// ---------------------------------------------------------------------------
// The application's Domain: document, feature types, and the hooks.
// ---------------------------------------------------------------------------

const EntityKind = enum(u8) { castle = 1, tower = 2, tree = 3 };

const Entity = struct {
    cell: u8,
    kind: EntityKind,
};

const GridWorld = struct {
    pub const side: u8 = 8;
    pub const cells: usize = side * side;

    pub const Doc = struct {
        heights: [cells]f32 = @splat(0),
        entities: std.ArrayList(Entity) = .empty,
    };

    pub const Op = union(enum) {
        raise: struct { cell: u8, amount: f32 },
        smooth: struct { passes: u8 },
        place: struct { cell: u8, kind: EntityKind },
        /// Hills-and-valleys pass that conceptually builds on an earlier
        /// raise feature — used to demonstrate dependency-aware reordering.
        beautify: struct { after: ft.FeatureId },
    };

    pub fn apply(op: Op, doc: *Doc, ctx: *ft.ApplyContext) anyerror!void {
        switch (op) {
            .raise => |r| {
                if (r.cell >= cells)
                    return ctx.fail("cell {d} is outside the {d}-cell grid", .{ r.cell, cells });
                doc.heights[r.cell] += r.amount;
            },
            .smooth => |s| {
                var pass: u8 = 0;
                while (pass < s.passes) : (pass += 1) {
                    const before = doc.heights;
                    for (0..side) |row| {
                        for (0..side) |col| {
                            const i = row * side + col;
                            var sum: f32 = before[i];
                            var n: f32 = 1;
                            if (row > 0) {
                                sum += before[i - side];
                                n += 1;
                            }
                            if (row + 1 < side) {
                                sum += before[i + side];
                                n += 1;
                            }
                            if (col > 0) {
                                sum += before[i - 1];
                                n += 1;
                            }
                            if (col + 1 < side) {
                                sum += before[i + 1];
                                n += 1;
                            }
                            doc.heights[i] = sum / n;
                        }
                    }
                }
            },
            .place => |p| {
                if (p.cell >= cells)
                    return ctx.fail("cell {d} is outside the grid", .{p.cell});
                for (doc.entities.items) |e| {
                    if (e.cell == p.cell)
                        return ctx.fail("cell {d} is already occupied", .{p.cell});
                }
                try doc.entities.append(ctx.alloc, .{ .cell = p.cell, .kind = p.kind });
            },
            .beautify => |b| {
                _ = b;
                // Polishes the landmark cell; conceptually requires the
                // terrain feature it references (see `dependencies`).
                for (doc.entities.items) |e| {
                    if (e.cell == landmark_cell) {
                        doc.heights[landmark_cell] += 0.5;
                        return;
                    }
                }
                return ctx.fail("landmark cell has no entity to beautify", .{});
            },
        }
    }

    pub fn dependencies(op: Op, out: *ft.DepCollector) void {
        switch (op) {
            .beautify => |b| out.dep(b.after),
            else => {},
        }
    }

    pub fn cloneDoc(doc: *const Doc, gpa: std.mem.Allocator) anyerror!Doc {
        return .{
            .heights = doc.heights,
            .entities = try doc.entities.clone(gpa),
        };
    }

    pub fn deinitDoc(doc: *Doc, gpa: std.mem.Allocator) void {
        doc.entities.deinit(gpa);
    }

    pub fn encodeOp(op: Op, w: *Io.Writer) anyerror!void {
        switch (op) {
            .raise => |r| {
                try w.writeAll(&[2]u8{ 1, r.cell });
                try w.writeInt(u32, @bitCast(r.amount), .little);
            },
            .smooth => |s| {
                try w.writeAll(&[2]u8{ 2, s.passes });
            },
            .place => |p| {
                try w.writeAll(&[3]u8{ 3, p.cell, @backingInt(p.kind) });
            },
            .beautify => |b| {
                try w.writeAll(&[1]u8{4});
                try w.writeInt(u64, b.after, .little);
            },
        }
    }

    pub fn decodeOp(r: *Io.Reader, gpa: std.mem.Allocator) anyerror!Op {
        _ = gpa;
        const tag = (try r.take(1))[0];
        return switch (tag) {
            1 => .{ .raise = .{
                .cell = (try r.take(1))[0],
                .amount = @bitCast(try r.takeInt(u32, .little)),
            } },
            2 => .{ .smooth = .{ .passes = (try r.take(1))[0] } },
            3 => .{ .place = .{
                .cell = (try r.take(1))[0],
                .kind = @fromBackingInt(@intCast((try r.take(1))[0])),
            } },
            4 => .{ .beautify = .{ .after = try r.takeInt(u64, .little) } },
            else => error.Malformed,
        };
    }

    pub fn encodeDoc(doc: *const Doc, w: *Io.Writer) anyerror!void {
        for (doc.heights) |h| try w.writeInt(u32, @bitCast(h), .little);
        try w.writeInt(u32, @intCast(doc.entities.items.len), .little);
        for (doc.entities.items) |e| try w.writeAll(&[2]u8{ e.cell, @backingInt(e.kind) });
    }

    pub fn decodeDoc(r: *Io.Reader, gpa: std.mem.Allocator) anyerror!Doc {
        var doc: Doc = .{};
        for (&doc.heights) |*h| h.* = @bitCast(try r.takeInt(u32, .little));
        const n = try r.takeInt(u32, .little);
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const cell = (try r.take(1))[0];
            const kind: EntityKind = @fromBackingInt(@intCast((try r.take(1))[0]));
            try doc.entities.append(gpa, .{ .cell = cell, .kind = kind });
        }
        return doc;
    }
};

/// The cell `beautify` polishes. Deriving it from the referenced feature
/// would require document bookkeeping the demo doesn't need.
const landmark_cell: u8 = 9;

// ---------------------------------------------------------------------------
// Demo driver
// ---------------------------------------------------------------------------

const Timeline = ft.Timeline(GridWorld);

const App = struct {
    out: *Io.Writer,
    tl: Timeline,

    fn opLabel(op: GridWorld.Op) []const u8 {
        return switch (op) {
            .raise => "raise",
            .smooth => "smooth",
            .place => "place",
            .beautify => "beautify",
        };
    }

    fn show(self: *App, label: []const u8) !void {
        _ = self.tl.state(); // force the rebuild so statuses are fresh
        try self.out.print("\n=== {s} ===\n", .{label});

        // The grid, with entities overlaid.
        for (0..GridWorld.side) |row| {
            try self.out.writeAll("  ");
            for (0..GridWorld.side) |col| {
                const i = row * GridWorld.side + col;
                var printed = false;
                for (self.tl.state().entities.items) |e| {
                    if (e.cell == i) {
                        const glyph: u8 = switch (e.kind) {
                            .castle => 'C',
                            .tower => 'T',
                            .tree => 't',
                        };
                        try self.out.writeByte(glyph);
                        printed = true;
                        break;
                    }
                }
                if (!printed) {
                    const h = self.tl.state().heights[i];
                    const level: u8 = @intCast(@min(@as(u32, 9), @as(u32, @intFromFloat(h))));
                    try self.out.writeByte('0' + level);
                }
            }
            try self.out.writeAll("\n");
        }

        // The timeline with its marker.
        try self.out.writeAll("  timeline ");
        var it = self.tl.features();
        var idx: u32 = 0;
        while (it.next()) |f| : (idx += 1) {
            if (idx == self.tl.marker()) try self.out.writeAll("| ");
            const badge: u8 = if (f.suppressed) 's' else switch (f.status) {
                .failed => 'x',
                .pending => '.',
                else => ' ',
            };
            try self.out.print("{s}{c} ", .{ opLabel(f.op.*), badge });
        }
        if (idx == self.tl.marker()) try self.out.writeAll("|");
        try self.out.print("  (marker {d}/{d})\n", .{ self.tl.marker(), self.tl.len() });

        var it2 = self.tl.features();
        while (it2.next()) |f| {
            if (f.status == .failed)
                try self.out.print("  ! {s}: {s}\n", .{ opLabel(f.op.*), f.status.failed });
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    var app = App{
        .out = out,
        .tl = try Timeline.init(arena, .{}, .{
            .checkpoint_interval = 4,
            .max_checkpoints = 4,
            .checkpoint_on_scrub = true,
        }),
    };
    defer app.tl.deinit();

    // -- 1. Build terrain by committing features ----------------------------
    const hill = try app.tl.commit(.{ .raise = .{ .cell = 9, .amount = 9 } });
    _ = try app.tl.commit(.{ .raise = .{ .cell = 54, .amount = 6 } });
    const smooth = try app.tl.commit(.{ .smooth = .{ .passes = 1 } });
    _ = try app.tl.commit(.{ .place = .{ .cell = 9, .kind = .castle } });
    const occupied = try app.tl.commit(.{ .place = .{ .cell = 9, .kind = .tower } });
    _ = occupied; // soft-fails: cell 9 already has the castle
    try app.show("1. commit features (the second place fails softly)");

    // -- 2. Scrub the history slider -----------------------------------------
    app.tl.setMarker(3);
    try app.show("2a. scrub back to 3 (castle not placed yet)");
    app.tl.setMarker(5);
    try app.show("2b. scrub forward to 5 (cached restore: free)");
    app.tl.setMarker(0);
    try app.show("2c. scrub to 0 (empty terrain)");

    // -- 3. Roll back and insert mid-history ---------------------------------
    app.tl.setMarker(2);
    _ = try app.tl.commit(.{ .raise = .{ .cell = 14, .amount = 5 } });
    try app.show("3. rolled back to 2, committed raise@14 mid-history");
    app.tl.setMarker(app.tl.len());
    try app.show("3b. roll to the end (replays the suffix)");

    // -- 4. Edit a feature's parameters --------------------------------------
    try app.tl.edit(hill, .{ .raise = .{ .cell = 9, .amount = 3 } });
    try app.show("4. edit the hill raise: 9 -> 3, downstream recomputes");

    // -- 5. Suppress a feature -----------------------------------------------
    try app.tl.setSuppressed(hill, true);
    try app.show("5. suppress the hill raise (castle keeps its cell)");

    // -- 6. Reorder with dependency validation -------------------------------
    const beautify = try app.tl.commit(.{ .beautify = .{ .after = hill } });
    try app.show("6a. commit beautify (depends on the raise)");
    if (app.tl.move(beautify, 0)) |_| {
        unreachable;
    } else |err| {
        try out.print("6b. move beautify to the front -> refused: {t}\n", .{err});
    }
    try app.tl.move(smooth, 0);
    try app.show("6c. move the smooth to the front instead (legal, no deps)");

    // -- 7. Undo / redo -------------------------------------------------------
    _ = app.tl.undo();
    _ = app.tl.undo();
    try app.show("7. undo twice (move undone, then beautify removed)");
    _ = app.tl.redo();
    try app.show("7b. redo once (beautify back)");

    // -- 8. Save / load --------------------------------------------------------
    var saved: std.Io.Writer.Allocating = .init(arena);
    try ft.persistence.save(GridWorld, &app.tl, arena, &saved.writer);
    var reader = std.Io.Reader.fixed(saved.written());
    var loaded = try ft.persistence.load(GridWorld, arena, .{}, &reader);
    defer loaded.deinit();
    try out.print("8. saved {d} bytes, loaded back: ", .{saved.written().len});
    const grids_equal = std.mem.eql(f32, &app.tl.state().heights, &loaded.state().heights);
    try out.print("terrain identical = {}\n", .{grids_equal});

    // -- 9. Background rebuild -------------------------------------------------
    app.tl.setMarker(2);
    var job = try app.tl.beginRebuild();
    const thread = try std.Thread.spawn(.{}, ft.rebuild.Job(GridWorld).run, .{&job});
    thread.join();
    const integrated = app.tl.integrate(&job);
    try out.print("9. background rebuild to marker 2 on a worker thread: integrated = {}\n", .{integrated});

    // -- 10. Hierarchical timelines: globe + region sub-timeline ----------
    try @import("nested_demo.zig").run(out, arena);

    try out.flush();
}

// ---------------------------------------------------------------------------
// Smoke tests for the demo domain
// ---------------------------------------------------------------------------

test "demo domain: soft failure keeps the cell free" {
    const gpa = std.testing.allocator;
    var tl = try Timeline.init(gpa, .{}, .{});
    defer tl.deinit();

    _ = try tl.commit(.{ .place = .{ .cell = 9, .kind = .castle } });
    _ = try tl.commit(.{ .place = .{ .cell = 9, .kind = .tower } });
    _ = tl.state();

    var it = tl.features();
    _ = it.next().?;
    const second = it.next().?;
    try std.testing.expectEqualStrings("cell 9 is already occupied", second.status.failed);
    try std.testing.expectEqual(@as(usize, 1), tl.state().entities.items.len);
}

test "demo domain: dependency move violation is refused" {
    const gpa = std.testing.allocator;
    var tl = try Timeline.init(gpa, .{}, .{});
    defer tl.deinit();

    const hill = try tl.commit(.{ .raise = .{ .cell = 9, .amount = 9 } });
    _ = try tl.commit(.{ .place = .{ .cell = 9, .kind = .castle } });
    const beautify = try tl.commit(.{ .beautify = .{ .after = hill } });
    _ = tl.state();

    try std.testing.expectError(error.DependencyViolation, tl.move(beautify, 0));
}

// `main` is not analyzed in test builds, so the hierarchical demo's own
// tests are only reached through an explicit reference here.
test {
    _ = @import("nested_demo.zig");
}
