//! The sync feed: replicas of one timeline converging by exchanging
//! envelopes — the library's multiuser stopping point. Shows the record
//! observer, the wire codec, `applyRemote` results, concurrent commits
//! landing in the same order everywhere, duplicate and gap detection, and
//! undo of a remote unit.
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

/// A minimal wire: the observer encodes every envelope; `deliver` decodes
/// them into another replica and reports what `applyRemote` said.
const Outbox = struct {
    gpa: std.mem.Allocator,
    blobs: std.ArrayList([]u8) = .empty,

    fn observe(ctx: ?*anyopaque, env: *const Tl.Envelope) void {
        const self: *Outbox = @ptrCast(@alignCast(ctx.?));
        var aw: Io.Writer.Allocating = .init(self.gpa);
        ft.sync.encode(Ledger, env, self.gpa, &aw.writer) catch {
            aw.deinit();
            return;
        };
        const owned = aw.toOwnedSlice() catch return;
        self.blobs.append(self.gpa, owned) catch self.gpa.free(owned);
    }

    const Tally = struct { applied: u32 = 0, duplicate: u32 = 0, gap: u32 = 0, other: u32 = 0 };

    /// Deliver every pending envelope (then forget it unless `keep`).
    fn deliver(self: *Outbox, to: *Tl, keep: bool) !Tally {
        var tally: Tally = .{};
        for (self.blobs.items) |blob| {
            var reader = Io.Reader.fixed(blob);
            var env = try ft.sync.decode(Ledger, self.gpa, &reader);
            defer ft.sync.deinit(Ledger.Op, self.gpa, &env);
            switch (to.applyRemote(&env)) {
                .applied => tally.applied += 1,
                .duplicate => tally.duplicate += 1,
                .gap => tally.gap += 1,
                else => tally.other += 1,
            }
        }
        if (!keep) {
            for (self.blobs.items) |b| self.gpa.free(b);
            self.blobs.clearRetainingCapacity();
        }
        return tally;
    }
};

fn report(out: *Io.Writer, label: []const u8, a: *Tl, b: *Tl) !void {
    const same = a.structureDigest() == b.structureDigest() and a.state().total == b.state().total;
    try out.print("{s:<40} alice {d} features total {d:<5} bob {d} features total {d:<5} same order+state = {}\n", .{
        label, a.len(), a.state().total, b.len(), b.state().total, same,
    });
}

fn demo(out: *Io.Writer, arena: std.mem.Allocator) !void {
    var alice = try Tl.init(arena, .{}, .{});
    defer alice.deinit();
    var out_a = Outbox{ .gpa = arena };
    alice.setRecordObserver(.{ .ctx = &out_a, .func = Outbox.observe });

    // Bob is a replica of Alice's document (same timeline identity, his own
    // replica id).
    var saved: Io.Writer.Allocating = .init(arena);
    try ft.persistence.save(Ledger, &alice, arena, &saved.writer);
    var reader = Io.Reader.fixed(saved.written());
    var bob = try ft.persistence.load(Ledger, arena, .{}, &reader);
    defer bob.deinit();
    var out_b = Outbox{ .gpa = arena };
    bob.setRecordObserver(.{ .ctx = &out_b, .func = Outbox.observe });
    try out.print("replicas share the timeline id: {}, have different replica ids: {}\n", .{
        alice.timelineId() == bob.timelineId(), alice.replicaId() != bob.replicaId(),
    });

    // 1. Alice works; her envelopes ship to Bob.
    _ = try alice.commit(.{ .add = 10 });
    _ = try alice.commit(.{ .multiply = 3 });
    var first_it = alice.features();
    try alice.setFeatureName(first_it.next().?.id, "base");
    _ = try out_a.deliver(&bob, false);
    try report(out, "alice's session delivered to bob", &alice, &bob);

    // 2. Both commit at the same time, before syncing. Each commit carries
    //    its predecessor and an order key, so both replicas place the two
    //    new features in the same order whichever envelope arrives first.
    _ = try alice.commit(.{ .add = 100 });
    _ = try bob.commit(.{ .add = 200 });
    _ = try out_b.deliver(&alice, true); // bob's first, on alice
    _ = try out_a.deliver(&bob, false); // alice's first, on bob
    try report(out, "concurrent commits exchanged", &alice, &bob);

    // 3. Sequence numbers: re-delivering bob's envelope is a duplicate; an
    //    envelope that skips ahead is a gap and is not applied.
    const again = try out_b.deliver(&alice, false);
    _ = try bob.commit(.{ .add = 1 });
    _ = try bob.commit(.{ .add = 2 });
    // Drop the first of the two pending envelopes to simulate a lost message.
    arena.free(out_b.blobs.orderedRemove(0));
    const skipped = try out_b.deliver(&alice, false);
    try out.print("re-delivery: {d} duplicate; after a lost message: {d} gap, alice expects seq {d} from bob\n", .{
        again.duplicate, skipped.gap, alice.expectedSeq(bob.replicaId()),
    });

    // 4. Undo is uniform: alice undoes the remote unit she received from bob.
    _ = alice.undo();
    try out.print("alice undoes one remote unit: total {d} (bob still {d}); digests differ = {}\n", .{
        alice.state().total, bob.state().total, alice.structureDigest() != bob.structureDigest(),
    });
}

pub fn main(init: std.process.Init) !void {
    return common.run(init, "sync: replicas converging on envelopes", demo);
}
