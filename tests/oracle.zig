//! Differential testing: the real `Timeline` (checkpoint cache, incremental
//! forward replay, exact restores, lazy rebuilds) versus a naive reference
//! that re-clones the seed and replays from scratch after every step.
//!
//! Random operation sequences (deterministic seeds, varying configs) must
//! produce identical documents, markers, and per-feature statuses after every
//! single step. This is the primary regression net for invalidation bugs.

const std = @import("std");
const ft = @import("featuretree_zig");

const Domain = struct {
    pub const Doc = struct {
        value: i64 = 0,
        trace: std.ArrayList(u8) = .empty,
    };
    pub const Op = union(enum) {
        add: i32,
        mul: i32,
        fail: i32,
    };
    pub fn apply(op: Op, doc: *Doc, ctx: *ft.ApplyContext) anyerror!void {
        switch (op) {
            .add => |n| {
                doc.value = std.math.add(i64, doc.value, n) catch
                    return ctx.fail("overflow", .{});
                try doc.trace.append(ctx.alloc, '+');
            },
            .mul => |n| {
                doc.value = std.math.mul(i64, doc.value, n) catch
                    return ctx.fail("overflow", .{});
                try doc.trace.append(ctx.alloc, '*');
            },
            .fail => |n| return ctx.fail("fail {d}", .{n}),
        }
    }
    pub fn cloneDoc(doc: *const Doc, gpa: std.mem.Allocator) anyerror!Doc {
        return .{ .value = doc.value, .trace = try doc.trace.clone(gpa) };
    }
    pub fn deinitDoc(doc: *Doc, gpa: std.mem.Allocator) void {
        doc.trace.deinit(gpa);
    }
};

const Timeline = ft.Timeline(Domain);
const NaiveFeature = ft.Feature(Domain.Op);

/// The naive model's own undo log — an independent reimplementation of the
/// journal semantics (insert-at-marker, marker restore, redo truncation).
const NaiveEntry = union(enum) {
    commit: struct { idx: u32, op: Domain.Op },
    edit: struct { idx: u32, old: Domain.Op, new: Domain.Op },
    remove: struct { idx: u32, op: Domain.Op, suppressed: bool, marker_pre: u32 },
    suppress: struct { idx: u32, prev: bool },
    move: struct { idx: u32, to: u32, marker_pre: u32 },
};

/// The reference model: no caching, no incremental anything. Mirrors the
/// timeline's structural semantics (insert-at-marker, marker/mutation index
/// adjustments) and recomputes by replay from the seed.
const Naive = struct {
    gpa: std.mem.Allocator,
    features: std.ArrayList(NaiveFeature) = .empty,
    marker: u32 = 0,
    log: std.ArrayList(NaiveEntry) = .empty,
    log_head: usize = 0,
    journal_max: u32,

    fn deinit(self: *Naive) void {
        for (self.features.items) |*f| self.freeStatus(f);
        self.features.deinit(self.gpa);
        self.log.deinit(self.gpa);
    }

    fn freeStatus(self: *Naive, f: *NaiveFeature) void {
        switch (f.status) {
            .failed => |msg| self.gpa.free(msg),
            else => {},
        }
        f.status = .pending;
    }

    fn commit(self: *Naive, op: Domain.Op) !void {
        try self.features.insert(self.gpa, self.marker, .{ .id = 0, .op = op });
        for (self.features.items[self.marker + 1 ..]) |*f| self.freeStatus(f);
        self.record(.{ .commit = .{ .idx = self.marker, .op = op } });
        self.marker += 1;
    }

    fn setMarker(self: *Naive, pos: u32) void {
        self.marker = @min(pos, self.features.items.len);
    }

    fn edit(self: *Naive, idx: u32, op: Domain.Op) void {
        const old = self.features.items[idx].op;
        self.features.items[idx].op = op;
        for (self.features.items[idx..]) |*f| self.freeStatus(f);
        self.record(.{ .edit = .{ .idx = idx, .old = old, .new = op } });
    }

    fn remove(self: *Naive, idx: u32) void {
        const f = self.features.items[idx];
        self.record(.{ .remove = .{
            .idx = idx,
            .op = f.op,
            .suppressed = f.suppressed,
            .marker_pre = self.marker,
        } });
        for (self.features.items[idx..]) |*f2| self.freeStatus(f2);
        _ = self.features.orderedRemove(idx);
        if (idx < self.marker) self.marker -= 1;
    }

    fn toggleSuppress(self: *Naive, idx: u32) void {
        const prev = self.features.items[idx].suppressed;
        self.features.items[idx].suppressed = !prev;
        for (self.features.items[idx..]) |*f| self.freeStatus(f);
        self.record(.{ .suppress = .{ .idx = idx, .prev = prev } });
    }

    fn record(self: *Naive, e: NaiveEntry) void {
        if (self.journal_max == 0) return;
        self.log.shrinkRetainingCapacity(self.log_head);
        self.log.append(self.gpa, e) catch return;
        self.log_head += 1;
        if (self.log.items.len > self.journal_max) {
            _ = self.log.orderedRemove(0);
            self.log_head -= 1;
        }
    }

    fn moveFeature(self: *Naive, idx: u32, to: u32) void {
        const to_c = @min(to, @as(u32, @intCast(self.features.items.len - 1)));
        if (idx == to_c) return;
        const lo = @min(idx, to_c);
        for (self.features.items[lo..]) |*f| self.freeStatus(f);
        const f = self.features.orderedRemove(idx);
        self.features.insert(self.gpa, to_c, f) catch unreachable;
        if (idx < self.marker and to_c >= self.marker) {
            self.marker -= 1;
        } else if (idx >= self.marker and to_c < self.marker) {
            self.marker += 1;
        }
    }

    fn move(self: *Naive, idx: u32, to: u32) void {
        const to_c = @min(to, @as(u32, @intCast(self.features.items.len - 1)));
        if (idx == to_c) return;
        self.record(.{ .move = .{ .idx = idx, .to = to_c, .marker_pre = self.marker } });
        self.moveFeature(idx, to_c);
    }

    fn canUndo(self: *const Naive) bool {
        return self.log_head > 0;
    }

    fn canRedo(self: *const Naive) bool {
        return self.log_head < self.log.items.len;
    }

    fn undo(self: *Naive) bool {
        if (self.log_head == 0) return false;
        self.log_head -= 1;
        const e = self.log.items[self.log_head];
        switch (e) {
            .commit => |c| {
                for (self.features.items[c.idx..]) |*f| self.freeStatus(f);
                _ = self.features.orderedRemove(c.idx);
                self.marker = c.idx;
            },
            .edit => |ed| {
                self.features.items[ed.idx].op = ed.old;
                for (self.features.items[ed.idx..]) |*f| self.freeStatus(f);
            },
            .remove => |r| {
                self.features.insert(self.gpa, r.idx, .{
                    .id = 0,
                    .op = r.op,
                    .suppressed = r.suppressed,
                }) catch return false;
                for (self.features.items[r.idx..]) |*f| self.freeStatus(f);
                self.marker = r.marker_pre;
            },
            .suppress => |s| {
                self.features.items[s.idx].suppressed = s.prev;
                for (self.features.items[s.idx..]) |*f| self.freeStatus(f);
            },
            .move => |m| {
                self.moveFeature(m.to, m.idx);
                self.marker = m.marker_pre;
            },
        }
        return true;
    }

    fn redo(self: *Naive) bool {
        if (self.log_head >= self.log.items.len) return false;
        const e = self.log.items[self.log_head];
        self.log_head += 1;
        switch (e) {
            .commit => |c| {
                self.features.insert(self.gpa, c.idx, .{ .id = 0, .op = c.op }) catch return false;
                for (self.features.items[c.idx + 1 ..]) |*f| self.freeStatus(f);
                self.marker = c.idx + 1;
            },
            .edit => |ed| {
                self.features.items[ed.idx].op = ed.new;
                for (self.features.items[ed.idx..]) |*f| self.freeStatus(f);
            },
            .remove => |r| {
                for (self.features.items[r.idx..]) |*f| self.freeStatus(f);
                _ = self.features.orderedRemove(r.idx);
                self.marker = if (r.idx < r.marker_pre) r.marker_pre - 1 else r.marker_pre;
            },
            .suppress => |s| {
                self.features.items[s.idx].suppressed = !s.prev;
                for (self.features.items[s.idx..]) |*f| self.freeStatus(f);
            },
            .move => |m| self.moveFeature(m.idx, m.to),
        }
        return true;
    }

    /// Recompute from scratch. Uses the library's own pure apply core — the
    /// code under test here is the caching, not the application loop.
    fn recompute(self: *Naive) !struct { value: i64, trace: []const u8 } {
        for (self.features.items) |*f| self.freeStatus(f);
        var doc: Domain.Doc = .{};
        var applied: u32 = 0;
        try ft.rebuild.applyRange(Domain, self.features.items, 0, self.marker, &doc, self.gpa, null, &applied);
        return .{ .value = doc.value, .trace = try doc.trace.toOwnedSlice(self.gpa) };
    }
};

fn randomOp(random: std.Random) Domain.Op {
    return switch (random.uintAtMost(u3, 7)) {
        0...2 => .{ .add = @as(i32, random.uintAtMost(u8, 6)) - 3 },
        3...5 => .{ .mul = @intCast(random.uintAtMost(u8, 3)) },
        6 => .{ .fail = @intCast(random.uintAtMost(u8, 3)) },
        7 => .{ .add = @as(i32, random.uintAtMost(u8, 6)) - 3 },
    };
}

fn randomConfig(random: std.Random) ft.Config {
    return .{
        .checkpoint_interval = switch (random.uintLessThan(u2, 3)) {
            0 => 0,
            1 => 1,
            else => 3,
        },
        .max_checkpoints = switch (random.uintAtMost(u2, 3)) {
            0 => 0,
            1 => 1,
            2 => 2,
            else => 8,
        },
        .checkpoint_on_scrub = random.boolean(),
        .max_journal = switch (random.uintAtMost(u2, 3)) {
            0 => 0,
            1 => 3,
            2...3 => 1000,
        },
    };
}

/// Id of the feature at `idx`, via the public iterator.
fn idAt(tl: *Timeline, idx: u32) ft.FeatureId {
    var it = tl.features();
    var i: u32 = 0;
    while (it.next()) |f| : (i += 1) {
        if (i == idx) return f.id;
    }
    unreachable;
}

fn compare(tl: *Timeline, naive: *Naive, gpa: std.mem.Allocator) !void {
    const expect = std.testing.expect;
    const expectEqual = std.testing.expectEqual;

    try expectEqual(naive.features.items.len, tl.len());
    try expectEqual(naive.marker, tl.marker());
    try expectEqual(naive.canUndo(), tl.canUndo());
    try expectEqual(naive.canRedo(), tl.canRedo());

    const got_state = tl.state();
    const want = try naive.recompute();
    defer gpa.free(want.trace);
    try expectEqual(want.value, got_state.value);
    try std.testing.expectEqualSlices(u8, want.trace, got_state.trace.items);

    // Per-feature comparison: ops, suppression, statuses below the marker,
    // pending at/after it.
    var it = tl.features();
    var i: u32 = 0;
    while (it.next()) |got| : (i += 1) {
        const want_f = naive.features.items[i];
        try expect(std.meta.eql(want_f.op, got.op.*));
        try expectEqual(want_f.suppressed, got.suppressed);
        if (i < naive.marker) {
            try expectEqual(std.meta.activeTag(want_f.status), std.meta.activeTag(got.status));
            switch (want_f.status) {
                .failed => |msg| try std.testing.expectEqualStrings(msg, got.status.failed),
                else => {},
            }
        } else {
            try expectEqual(ft.Status.pending, got.status);
        }
    }
}

fn runSequence(seed: u64, steps: u16) !void {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var tl = try Timeline.init(gpa, .{}, randomConfig(random));
    defer tl.deinit();
    var naive = Naive{ .gpa = gpa, .journal_max = tl.config.max_journal };
    defer naive.deinit();

    var step: u16 = 0;
    while (step < steps) : (step += 1) {
        const len: u32 = @intCast(naive.features.items.len);
        // Roll a structural action; fall back to commit when the timeline is
        // too short for index-based ones.
        const action = if (len == 0) 0 else random.uintLessThan(u7, 100);
        switch (action) {
            0...34 => {
                const op = randomOp(random);
                _ = try tl.commit(op);
                try naive.commit(op);
            },
            35...49 => {
                const pos = random.uintAtMost(u32, len);
                tl.setMarker(pos);
                naive.setMarker(pos);
            },
            55...64 => {
                const idx = random.uintAtMost(u32, len - 1);
                tl.setSuppressed(idAt(&tl, idx), !naive.features.items[idx].suppressed);
                naive.toggleSuppress(idx);
            },
            65...74 => {
                const idx = random.uintAtMost(u32, len - 1);
                const op = randomOp(random);
                tl.edit(idAt(&tl, idx), op);
                naive.edit(idx, op);
            },
            75...79 => {
                const idx = random.uintAtMost(u32, len - 1);
                tl.remove(idAt(&tl, idx));
                naive.remove(idx);
            },
            80...86 => {
                try std.testing.expectEqual(naive.undo(), tl.undo());
            },
            87...92 => {
                try std.testing.expectEqual(naive.redo(), tl.redo());
            },
            else => {
                const idx = random.uintAtMost(u32, len - 1);
                const to = random.uintAtMost(u32, len - 1);
                tl.move(idAt(&tl, idx), to) catch unreachable;
                naive.move(idx, to);
            },
        }
        try compare(&tl, &naive, gpa);
    }
}

test "differential: cached timeline matches naive replay (many seeds)" {
    var seed: u64 = 0;
    const total: u64 = 40;
    while (seed < total) : (seed += 1) {
        try runSequence(0x9E3779B97F4A7C15 *% (seed + 1), 120);
    }
}

test "differential: single seed, long sequence" {
    try runSequence(0xDEADBEEF, 600);
}
