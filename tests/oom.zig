//! Out-of-memory sweep. Every mutator either completes or leaves the
//! timeline exactly as it was: no half-applied edit, no lost history, no
//! leak. Each scenario runs once per allocation index, with
//! `std.testing.FailingAllocator` failing that single allocation, until an
//! index is reached at which nothing fails any more (the allocator keeps
//! failing from that index on, so a call that swallows failures shows up
//! too). After a failure the allocator is restored, the same call is
//! retried on the same timeline and must then produce what a clean run
//! produces, and `undo` must bring the earlier state back.

const std = @import("std");
const ft = @import("featuretree_zig");
const support = @import("support.zig");

const Domain = support.Domain;
const Timeline = support.Timeline;
const Ids = support.Ids;
const FailingAllocator = std.testing.FailingAllocator;

// ---------------------------------------------------------------------------
// Local mutators
// ---------------------------------------------------------------------------

const LocalOp = enum {
    commit,
    commit_with_meta,
    edit,
    remove,
    suppress,
    set_name,
    clear_name,
    add_tag,
    remove_tag,
    add_chapter,
    remove_chapter,
    rename_chapter,
    add_group,
    remove_group,
    rename_group,
    suppress_group,
    move_group_left,
    move_group_right,
    remove_group_contents,
    move_out_of_group,
    add_param,
    set_param,
    remove_param,
    rename_param,
    cherry_pick,
    caller_transaction,

    /// The library promises atomicity per call. A caller's own transaction
    /// is the caller's to unwind (one `undo`).
    fn atomic(op: LocalOp) bool {
        return op != .caller_transaction;
    }
};

fn runLocal(op: LocalOp, tl: *Timeline, ids: *const Ids, src: *const Timeline, src_ids: *const Ids) !void {
    switch (op) {
        .commit => _ = try tl.commit(.{ .add = 7 }),
        .commit_with_meta => _ = try tl.commitWithMeta(.{ .add = 7 }, .{ .author = 4, .ts = 99 }),
        .edit => try tl.edit(ids.f[0], .{ .add = 100 }),
        .remove => try tl.remove(ids.f[2]), // named, tagged, chapter anchor, folder head
        .suppress => try tl.setSuppressed(ids.f[1], true),
        .set_name => try tl.setFeatureName(ids.f[2], "deux"),
        .clear_name => try tl.clearFeatureName(ids.f[2]),
        .add_tag => try tl.addTag(ids.f[0], "delta"),
        .remove_tag => try tl.removeTag(ids.f[2], "alpha"),
        .add_chapter => _ = try tl.addChapter("ch-new", .{ .after = ids.f[4] }),
        .remove_chapter => try tl.removeChapter(ids.c1),
        .rename_chapter => try tl.renameChapter(ids.c1, "chapter two"),
        .add_group => _ = try tl.addGroup("pair", ids.f[0], ids.f[1]),
        .remove_group => try tl.removeGroup(ids.g1),
        .rename_group => try tl.renameGroup(ids.g1, "folder2"),
        .suppress_group => try tl.setGroupSuppressed(ids.g1, true),
        .move_group_left => try tl.moveGroup(ids.g1, 0),
        .move_group_right => try tl.moveGroup(ids.g1, 3),
        .remove_group_contents => try tl.removeGroupContents(ids.g1),
        .move_out_of_group => try tl.move(ids.f[2], 0),
        .add_param => _ = try tl.addParam("rate", 1.5),
        .set_param => try tl.setParam(ids.p1, 3.0),
        .remove_param => try tl.removeParam(ids.p1),
        .rename_param => try tl.renameParam(ids.p1, "zoom"),
        .cherry_pick => _ = try tl.cherryPick(src, src_ids.f[2], .{}),
        .caller_transaction => {
            try tl.beginLabeledTransaction("batch");
            defer tl.endTransaction();
            _ = try tl.commit(.{ .add = 1 });
            try tl.setFeatureName(ids.f[0], "zero");
            _ = try tl.commit(.{ .add = 2 });
        },
    }
}

/// The timeline under test is built through the failing allocator too, so
/// the sweep starts past the fixture's own allocations.
const Fixture = struct {
    tl: Timeline,
    ids: Ids,

    fn build(gpa: std.mem.Allocator) !Fixture {
        var tl = try Timeline.init(gpa, .{}, .{ .id_seed = 11 });
        errdefer tl.deinit();
        const ids = try support.populate(&tl);
        return .{ .tl = tl, .ids = ids };
    }

    fn deinit(self: *Fixture) void {
        self.tl.deinit();
    }
};

fn sweepLocal(op: LocalOp, src: *const Timeline, src_ids: *const Ids) !void {
    // What a clean run yields.
    var clean = try Fixture.build(std.testing.allocator);
    defer clean.deinit();
    try runLocal(op, &clean.tl, &clean.ids, src, src_ids);
    const clean_after = support.contentDigest(&clean.tl);

    // Fail the k-th allocation the call itself makes. The index is set
    // after the fixture is built: its own allocation count is not stable
    // (a failed in-place resize falls back to a counted allocation).
    var k: usize = 0;
    while (true) : (k += 1) {
        var failing = FailingAllocator.init(std.testing.allocator, .{});
        var fx = try Fixture.build(failing.allocator());
        defer fx.deinit();
        const before = support.contentDigest(&fx.tl);
        const before_shape = support.shape(&fx.tl);
        failing.fail_index = failing.alloc_index + k;
        errdefer std.debug.print("local op {t}, allocation {d}\n", .{ op, k });

        var done = false;
        if (runLocal(op, &fx.tl, &fx.ids, src, src_ids)) |_| {
            // Completed, with or without a failure absorbed by a cache path.
            try std.testing.expectEqual(clean_after, support.contentDigest(&fx.tl));
            done = !failing.has_induced_failure; // nothing left to fail
        } else |err| {
            if (err != error.OutOfMemory) return err;
            try std.testing.expect(failing.has_induced_failure);
            if (op.atomic()) {
                try std.testing.expectEqual(before, support.contentDigest(&fx.tl));
                try std.testing.expectEqual(before_shape, support.shape(&fx.tl));
            } else {
                // The caller's transaction kept what went through; one undo rewinds it.
                if (fx.tl.undoDepth() > before_shape.undo_units) try std.testing.expect(fx.tl.undo());
                try std.testing.expectEqual(before, support.contentDigest(&fx.tl));
            }
            // Memory is back: the same call goes through now.
            failing.fail_index = std.math.maxInt(usize);
            try runLocal(op, &fx.tl, &fx.ids, src, src_ids);
            if (op.atomic()) try std.testing.expectEqual(clean_after, support.contentDigest(&fx.tl));
        }
        // Undo and redo need no memory at all: every allocation fails here.
        failing.fail_index = failing.alloc_index;
        try std.testing.expect(fx.tl.undo());
        try std.testing.expectEqual(before, support.contentDigest(&fx.tl));
        try std.testing.expect(fx.tl.redo());
        if (op.atomic()) try std.testing.expectEqual(clean_after, support.contentDigest(&fx.tl));
        failing.fail_index = std.math.maxInt(usize);
        if (done) break;
    }
}

test "oom: every local mutator is atomic" {
    const gpa = std.testing.allocator;
    var src = try Timeline.init(gpa, .{}, .{ .id_seed = 99 });
    defer src.deinit();
    const src_ids = try support.populate(&src);

    for (std.enums.values(LocalOp)) |op| try sweepLocal(op, &src, &src_ids);
}

// ---------------------------------------------------------------------------
// Remote integration: decode + applyRemote
// ---------------------------------------------------------------------------

fn applyBlobs(tl: *Timeline, gpa: std.mem.Allocator, blobs: []const []u8) !void {
    for (blobs) |blob| {
        var reader = std.Io.Reader.fixed(blob);
        var env = try ft.sync.decode(Domain, gpa, &reader);
        defer ft.sync.deinit(Domain.Op, gpa, &env);
        const res = tl.applyRemote(&env);
        if (res != .applied) {
            std.debug.print("expected .applied, got {t} for {t}\n", .{ res, env.entry });
            return error.NotApplied;
        }
    }
}

fn sweepRemote(blobs: []const []u8, j: usize) !void {
    var clean = try Timeline.init(std.testing.allocator, .{}, .{ .id_seed = 12 });
    defer clean.deinit();
    try applyBlobs(&clean, std.testing.allocator, blobs[0 .. j + 1]);
    const clean_after = support.contentDigest(&clean);

    var k: usize = 0;
    while (true) : (k += 1) {
        var failing = FailingAllocator.init(std.testing.allocator, .{});
        const gpa = failing.allocator();
        var tl = try Timeline.init(gpa, .{}, .{ .id_seed = 12 });
        defer tl.deinit();
        try applyBlobs(&tl, gpa, blobs[0..j]);
        const before = support.contentDigest(&tl);
        const before_shape = support.shape(&tl);
        failing.fail_index = failing.alloc_index + k; // the k-th allocation of decode + apply
        errdefer std.debug.print("remote blob {d}, allocation {d}\n", .{ j, k });

        var reader = std.Io.Reader.fixed(blobs[j]);
        var env = ft.sync.decode(Domain, gpa, &reader) catch |err| {
            // The decoder ran out of memory: nothing to apply, and the test
            // allocator checks that nothing leaked.
            if (err != error.OutOfMemory) return err;
            try std.testing.expect(failing.has_induced_failure);
            continue;
        };
        defer ft.sync.deinit(Domain.Op, gpa, &env);

        switch (tl.applyRemote(&env)) {
            .applied => {
                try std.testing.expectEqual(clean_after, support.contentDigest(&tl));
                const done = !failing.has_induced_failure;
                // Remote units undo and redo like local ones, without memory.
                failing.fail_index = failing.alloc_index;
                try std.testing.expect(tl.undo());
                try std.testing.expectEqual(before, support.contentDigest(&tl));
                try std.testing.expect(tl.redo());
                try std.testing.expectEqual(clean_after, support.contentDigest(&tl));
                failing.fail_index = std.math.maxInt(usize);
                if (done) break;
            },
            .out_of_memory => {
                try std.testing.expect(failing.has_induced_failure);
                try std.testing.expectEqual(before, support.contentDigest(&tl));
                try std.testing.expectEqual(before_shape, support.shape(&tl));
                // Not acknowledged: the same envelope goes through on retry.
                failing.fail_index = std.math.maxInt(usize);
                try std.testing.expectEqual(Timeline.ApplyResult.applied, tl.applyRemote(&env));
                try std.testing.expectEqual(clean_after, support.contentDigest(&tl));
            },
            else => |r| {
                std.debug.print("unexpected result {t}\n", .{r});
                return error.UnexpectedResult;
            },
        }
    }
}

test "oom: remote integration is atomic and retryable" {
    const gpa = std.testing.allocator;
    var outbox: support.Outbox = .{ .gpa = gpa };
    defer outbox.deinit();
    var rem = try Timeline.init(gpa, .{}, .{ .id_seed = 5 });
    defer rem.deinit();
    rem.setRecordObserver(.{ .ctx = &outbox, .func = support.Outbox.observe });
    const ids = try support.populate(&rem);
    const fixture_count = outbox.blobs.items.len;
    try support.remoteOps(&rem, &ids);

    var j: usize = fixture_count;
    while (j < outbox.blobs.items.len) : (j += 1) try sweepRemote(outbox.blobs.items, j);
}

// ---------------------------------------------------------------------------
// Persistence
// ---------------------------------------------------------------------------

test "oom: load either succeeds completely or fails cleanly" {
    const gpa = std.testing.allocator;
    var tl = try Timeline.init(gpa, .{}, .{ .id_seed = 21 });
    defer tl.deinit();
    _ = try support.populate(&tl);
    tl.setMarker(3);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try ft.persistence.save(Domain, &tl, gpa, &aw.writer);
    const blob = aw.written();
    const expected = support.contentDigest(&tl);

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        errdefer std.debug.print("load, fail_index {d}\n", .{fail_index});
        var reader = std.Io.Reader.fixed(blob);
        if (ft.persistence.load(Domain, failing.allocator(), .{ .id_seed = 21 }, &reader)) |loaded_value| {
            var loaded = loaded_value;
            defer loaded.deinit();
            try std.testing.expectEqual(expected, support.contentDigest(&loaded));
            if (!failing.has_induced_failure) break;
        } else |err| {
            if (err != error.OutOfMemory) return err;
            try std.testing.expect(failing.has_induced_failure);
        }
    }
}

test "oom: save either writes everything or fails cleanly" {
    const gpa = std.testing.allocator;
    var tl = try Timeline.init(gpa, .{}, .{ .id_seed = 22 });
    defer tl.deinit();
    _ = try support.populate(&tl);
    var reference: std.Io.Writer.Allocating = .init(gpa);
    defer reference.deinit();
    try ft.persistence.save(Domain, &tl, gpa, &reference.writer);

    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        errdefer std.debug.print("save, fail_index {d}\n", .{fail_index});
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        if (ft.persistence.save(Domain, &tl, failing.allocator(), &aw.writer)) |_| {
            try std.testing.expectEqualSlices(u8, reference.written(), aw.written());
            if (!failing.has_induced_failure) break;
        } else |err| {
            if (err != error.OutOfMemory) return err;
            try std.testing.expect(failing.has_induced_failure);
        }
    }
}
