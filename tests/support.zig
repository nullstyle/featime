//! Shared fixture for the hardening tests (`oom.zig`, `fuzz.zig`): a small
//! parametric Domain with codecs, a populated timeline that carries every
//! kind of state a mutator can touch, and allocation-free digests of that
//! state.

const std = @import("std");
const ft = @import("featuretree_zig");

pub const Domain = struct {
    pub const Doc = struct { value: i64 = 0 };
    pub const Op = union(enum) {
        add: i64,
        scale_by_param: ft.ParamId,
    };
    pub fn apply(op: Op, doc: *Doc, ctx: *ft.ApplyContext) anyerror!void {
        switch (op) {
            .add => |n| doc.value += n,
            .scale_by_param => |pid| {
                const v = ctx.param(pid) orelse return ctx.fail("missing parameter", .{});
                doc.value = @intFromFloat(@round(@as(f64, @floatFromInt(doc.value)) * v));
            },
        }
    }
    pub fn references(op: Op, out: *ft.ParamRefCollector) void {
        switch (op) {
            .scale_by_param => |pid| out.param(pid),
            .add => {},
        }
    }
    pub fn encodeOp(op: Op, w: *std.Io.Writer) anyerror!void {
        switch (op) {
            .add => |n| {
                try w.writeAll(&[1]u8{1});
                try w.writeInt(i64, n, .little);
            },
            .scale_by_param => |pid| {
                try w.writeAll(&[1]u8{2});
                try w.writeInt(u64, pid, .little);
            },
        }
    }
    pub fn decodeOp(r: *std.Io.Reader, gpa: std.mem.Allocator) anyerror!Op {
        _ = gpa;
        return switch ((try r.take(1))[0]) {
            1 => .{ .add = try r.takeInt(i64, .little) },
            2 => .{ .scale_by_param = try r.takeInt(u64, .little) },
            else => error.Malformed,
        };
    }
    pub fn encodeDoc(doc: *const Doc, w: *std.Io.Writer) anyerror!void {
        try w.writeInt(i64, doc.value, .little);
    }
    pub fn decodeDoc(r: *std.Io.Reader, gpa: std.mem.Allocator) anyerror!Doc {
        _ = gpa;
        return .{ .value = try r.takeInt(i64, .little) };
    }
};

pub const Timeline = ft.Timeline(Domain);
pub const Envelope = ft.sync.Envelope(Domain.Op);

pub const Ids = struct {
    f: [6]ft.FeatureId,
    c1: ft.ChapterId,
    c2: ft.ChapterId,
    g1: ft.annotations.GroupId,
    p1: ft.ParamId,
};

/// Six features, a parameter one of them reads, names, tags, two chapters
/// (one anchored inside the folder, one pinned to the end) and a folder.
pub fn populate(tl: *Timeline) !Ids {
    var ids: Ids = undefined;
    for (0..6) |i| ids.f[i] = try tl.commit(.{ .add = @intCast(i + 1) });
    ids.p1 = try tl.addParam("scale", 2.0);
    try tl.edit(ids.f[5], .{ .scale_by_param = ids.p1 });
    try tl.setFeatureName(ids.f[1], "one");
    try tl.setFeatureName(ids.f[2], "two");
    try tl.addTag(ids.f[2], "alpha");
    try tl.addTag(ids.f[2], "beta");
    try tl.addTag(ids.f[3], "gamma");
    ids.c1 = try tl.addChapter("ch-two", .{ .after = ids.f[2] });
    ids.c2 = try tl.addChapter("ch-end", .{ .after = null });
    ids.g1 = try tl.addGroup("folder", ids.f[2], ids.f[4]);
    return ids;
}

/// One edit of every kind, applied to a populated timeline. Through a
/// record observer this yields one envelope of every wire entry kind.
pub fn remoteOps(tl: *Timeline, ids: *const Ids) !void {
    try tl.edit(ids.f[0], .{ .add = 100 });
    try tl.setSuppressed(ids.f[1], true);
    try tl.setFeatureName(ids.f[0], "zero");
    try tl.setFeatureName(ids.f[2], "deux");
    try tl.clearFeatureName(ids.f[1]);
    try tl.addTag(ids.f[0], "delta");
    try tl.removeTag(ids.f[2], "alpha");
    const c3 = try tl.addChapter("ch-new", .{ .after = ids.f[4] });
    try tl.renameChapter(ids.c1, "chapter two");
    try tl.removeChapter(c3);
    const g2 = try tl.addGroup("pair", ids.f[0], ids.f[1]);
    try tl.renameGroup(g2, "pair2");
    try tl.removeGroup(g2);
    const p2 = try tl.addParam("rate", 1.5);
    try tl.setParam(ids.p1, 3.0);
    try tl.renameParam(p2, "speed");
    try tl.removeParam(p2);
    try tl.move(ids.f[2], 0); // a boundary member leaves the folder
    try tl.moveGroup(ids.g1, 0); // one move entry per member
    try tl.remove(ids.f[3]); // tagged, inside the folder
    try tl.removeGroupContents(ids.g1);
    _ = try tl.commit(.{ .add = 9 });
}

/// Everything observable about the timeline's content, hashed without
/// allocating: features (id, op, flag, name, tags, provenance) in order,
/// chapters, groups, parameters, and the marker. Statuses, checkpoints and
/// generation counters are deliberately left out: a failed call may still
/// have invalidated a cached document.
pub fn contentDigest(tl: *const Timeline) u64 {
    var h = std.hash.Wyhash.init(0xC0FFEE);
    var it = tl.features();
    while (it.next()) |f| {
        h.update(std.mem.asBytes(&f.id));
        h.update(&[1]u8{@intFromBool(f.suppressed)});
        switch (f.op.*) {
            .add => |n| {
                h.update("add");
                h.update(std.mem.asBytes(&n));
            },
            .scale_by_param => |p| {
                h.update("scale");
                h.update(std.mem.asBytes(&p));
            },
        }
        if (f.name) |n| {
            h.update("name:");
            h.update(n);
        }
        for (tl.tags(f.id)) |t| {
            h.update("tag:");
            h.update(t);
        }
        if (f.meta) |m| {
            h.update("meta:");
            h.update(std.mem.asBytes(&m.author));
            h.update(std.mem.asBytes(&m.ts));
        }
    }
    for (tl.chapters()) |c| {
        h.update("chapter:");
        h.update(std.mem.asBytes(&c.id));
        h.update(c.name);
        const after: u64 = c.mark.after orelse 0;
        h.update(std.mem.asBytes(&after));
    }
    for (tl.groups()) |g| {
        h.update("group:");
        h.update(std.mem.asBytes(&g.id));
        h.update(g.name);
        h.update(std.mem.asBytes(&g.first));
        h.update(std.mem.asBytes(&g.last));
    }
    for (tl.paramsList()) |p| {
        h.update("param:");
        h.update(std.mem.asBytes(&p.id));
        h.update(p.name);
        h.update(std.mem.asBytes(&p.value));
    }
    const marker = tl.marker();
    h.update(std.mem.asBytes(&marker));
    return h.final();
}

/// The counts a failed call must not change (`Stats` without the cache
/// fields, which a failed multi-step edit may legitimately invalidate).
pub const Shape = struct {
    features: u32,
    marker: u32,
    journal_entries: u32,
    undo_units: u32,
    redo_units: u32,
    params: u32,
    chapters: u32,
    groups: u32,
};

pub fn shape(tl: *const Timeline) Shape {
    const s = tl.stats();
    return .{
        .features = s.features,
        .marker = s.marker,
        .journal_entries = s.journal_entries,
        .undo_units = s.undo_units,
        .redo_units = s.redo_units,
        .params = s.params,
        .chapters = s.chapters,
        .groups = s.groups,
    };
}

/// A record observer that keeps every envelope as wire bytes.
pub const Outbox = struct {
    gpa: std.mem.Allocator,
    blobs: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *Outbox) void {
        for (self.blobs.items) |b| self.gpa.free(b);
        self.blobs.deinit(self.gpa);
    }

    pub fn observe(ctx: ?*anyopaque, env: *const Envelope) void {
        const self: *Outbox = @ptrCast(@alignCast(ctx.?));
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        ft.sync.encode(Domain, env, self.gpa, &aw.writer) catch {
            aw.deinit();
            return;
        };
        const owned = aw.toOwnedSlice() catch return;
        self.blobs.append(self.gpa, owned) catch self.gpa.free(owned);
    }
};
