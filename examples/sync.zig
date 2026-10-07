//! The sync feed: two replicas of one timeline converging by exchanging
//! journal entries — the library's multiuser stopping point.
//!
//! Run: zig build sync

const std = @import("std");
const Io = std.Io;
const ft = @import("featuretree_zig");
const common = @import("common.zig");

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

const Tl = ft.Timeline(Ledger);

const Outbox = struct {
    gpa: std.mem.Allocator,
    blobs: std.ArrayList([]u8) = .empty,

    fn observe(ctx: ?*anyopaque, entry: *const Tl.Entry) void {
        const self: *Outbox = @ptrCast(@alignCast(ctx.?));
        var aw: Io.Writer.Allocating = .init(self.gpa);
        ft.sync.encode(Ledger, entry, self.gpa, &aw.writer) catch {
            aw.deinit();
            return;
        };
        const owned = aw.toOwnedSlice() catch return;
        self.blobs.append(self.gpa, owned) catch self.gpa.free(owned);
    }

    fn deliver(self: *Outbox, to: *Tl) !void {
        for (self.blobs.items) |blob| {
            var reader = Io.Reader.fixed(blob);
            var entry = try ft.sync.decode(Ledger, self.gpa, &reader);
            to.applyRemote(&entry);
            ft.sync.deinit(Ledger.Op, self.gpa, &entry);
        }
        for (self.blobs.items) |b| self.gpa.free(b);
        self.blobs.clearRetainingCapacity();
    }
};

fn report(out: *Io.Writer, label: []const u8, a: *Tl, b: *Tl) !void {
    _ = a.state();
    _ = b.state();
    const converged = a.len() == b.len() and a.state().total == b.state().total;
    try out.print("{s:<34} alice: {d} features, total {d:<6} bob: {d} features, total {d:<6} converged = {}\n", .{
        label, a.len(), a.state().total, b.len(), b.state().total, converged,
    });
}

fn demo(out: *Io.Writer, arena: std.mem.Allocator) !void {
    var alice = try Tl.init(arena, .{}, .{});
    defer alice.deinit();
    var out_a = Outbox{ .gpa = arena };
    alice.setRecordObserver(.{ .ctx = &out_a, .func = Outbox.observe });

    // Bob is a replica of Alice's document (same timeline identity).
    var saved: Io.Writer.Allocating = .init(arena);
    try ft.persistence.save(Ledger, &alice, arena, &saved.writer);
    var reader = Io.Reader.fixed(saved.written());
    var bob = try ft.persistence.load(Ledger, arena, .{}, &reader);
    defer bob.deinit();
    try out.print("replicas share timeline id: {}\n", .{alice.timelineId() == bob.timelineId()});
    var out_b = Outbox{ .gpa = arena };
    bob.setRecordObserver(.{ .ctx = &out_b, .func = Outbox.observe });

    // Alice works; her entries ship to Bob through the wire codec.
    _ = try alice.commit(.{ .add = 10 });
    _ = try alice.commit(.{ .multiply = 3 });
    var first_it = alice.features();
    const first_id = first_it.next().?.id;
    try alice.setFeatureName(first_id, "base");
    try out_a.deliver(&bob);
    try report(out, "alice's session delivered to bob", &alice, &bob);

    // Bob works; his entries ship back. Remote integration is journaled
    // (undo works) but never re-broadcast — no echo loop.
    _ = try bob.commit(.{ .add = 5 });
    var bob_it = bob.features();
    try bob.setFeatureName(bob_it.next().?.id, "bob's edit");
    try out_b.deliver(&alice);
    try report(out, "bob's session delivered to alice", &alice, &bob);

    // Alice undoes a *remote* unit she received — undo is uniform. Each
    // remotely applied entry is its own undo unit (wrap feeds in
    // transactions if you want whole sessions per undo).
    _ = alice.undo();
    try report(out, "alice undoes one remote unit (the rename)", &alice, &bob);

    // Re-delivery is tolerated (at-most-once is the app's job, not a
    // requirement): duplicate commits are dropped by id.
    try out_b.deliver(&alice);
    try report(out, "bob's entries re-delivered (idempotent)", &alice, &alice);
}

pub fn main(init: std.process.Init) !void {
    return common.run(init, "sync: replicas converging on journal entries", demo);
}
