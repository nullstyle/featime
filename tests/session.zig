//! The session protocol between two replicas: in-memory transports that
//! deliver frames in order, lose one, split them across reads, or carry a
//! divergence that only a snapshot can repair.

const std = @import("std");
const ft = @import("featime");
const support = @import("support.zig");

const Domain = support.Domain;
const Timeline = support.Timeline;
const Session = ft.sync.Session(Domain);

const Pair = struct {
    a_tl: Timeline,
    b_tl: Timeline,
    a: Session,
    b: Session,

    fn init(gpa: std.mem.Allocator) !*Pair {
        const p = try gpa.create(Pair);
        p.a_tl = try Timeline.init(gpa, .{}, .{ .id_seed = 11 });
        p.b_tl = try Timeline.init(gpa, .{}, .{ .id_seed = 22 });
        p.a = Session.init(gpa, &p.a_tl);
        p.b = Session.init(gpa, &p.b_tl);
        p.a.attach();
        p.b.attach();
        return p;
    }

    fn deinit(p: *Pair, gpa: std.mem.Allocator) void {
        p.a.deinit();
        p.b.deinit();
        p.a_tl.deinit();
        p.b_tl.deinit();
        gpa.destroy(p);
    }

    /// Carry frames both ways until both sides are quiet.
    fn pump(p: *Pair, gpa: std.mem.Allocator) !void {
        var rounds: u32 = 0;
        while (rounds < 16) : (rounds += 1) {
            const ab = try gpa.dupe(u8, p.a.outgoingBytes());
            defer gpa.free(ab);
            p.a.clearOutgoing();
            const ba = try gpa.dupe(u8, p.b.outgoingBytes());
            defer gpa.free(ba);
            p.b.clearOutgoing();
            if (ab.len == 0 and ba.len == 0) return;
            try std.testing.expectEqual(ab.len, try p.b.receiveStream(ab));
            try std.testing.expectEqual(ba.len, try p.a.receiveStream(ba));
        }
        return error.NeverQuiet;
    }

    fn agree(p: *Pair) bool {
        return p.a_tl.structureDigest() == p.b_tl.structureDigest() and p.a_tl.state().value == p.b_tl.state().value;
    }
};

test "session: two replicas converge over frames, with catch-up at connect" {
    const gpa = std.testing.allocator;
    var p = try Pair.init(gpa);
    defer p.deinit(gpa);

    // A works alone first; B connects later and catches up by replay.
    _ = try p.a_tl.commit(.{ .add = 1 });
    _ = try p.a_tl.commit(.{ .add = 2 });
    p.a.clearOutgoing(); // these frames were "sent" before B existed
    try p.a.hello();
    try p.b.hello();
    try p.pump(gpa);
    try std.testing.expect(p.agree());
    try std.testing.expectEqual(@as(u32, 2), p.a.stats.replayed);

    // Concurrent work on both sides, including the same feature.
    const f = p.a_tl.featureAt(0).?.id;
    try p.a_tl.edit(f, .{ .add = 10 });
    try p.b_tl.edit(f, .{ .add = 20 });
    _ = try p.b_tl.commit(.{ .add = 100 });
    try p.pump(gpa);
    try std.testing.expect(p.agree());

    // Undo travels too.
    try std.testing.expect(p.b_tl.undo());
    try p.pump(gpa);
    try std.testing.expect(p.agree());

    // A probe with equal digests asks for nothing.
    try p.a.probe();
    try p.b.probe();
    try p.pump(gpa);
    try std.testing.expectEqual(@as(u32, 0), p.a.stats.snapshots_loaded + p.b.stats.snapshots_loaded);
}

test "session: a lost frame is held, asked for, and replayed" {
    const gpa = std.testing.allocator;
    var p = try Pair.init(gpa);
    defer p.deinit(gpa);
    try p.a.hello();
    try p.b.hello();
    try p.pump(gpa);

    _ = try p.a_tl.commit(.{ .add = 1 });
    _ = try p.a_tl.commit(.{ .add = 2 });
    _ = try p.a_tl.commit(.{ .add = 3 });
    // Lose the first frame on the way to B.
    const all = try gpa.dupe(u8, p.a.outgoingBytes());
    defer gpa.free(all);
    p.a.clearOutgoing();
    const first_len = 4 + std.mem.readInt(u32, all[0..4], .little);
    try std.testing.expectEqual(all.len - first_len, try p.b.receiveStream(all[first_len..]));
    try std.testing.expectEqual(@as(u32, 2), p.b.stats.gaps);
    try std.testing.expectEqual(@as(u32, 0), p.b_tl.len());

    // B's replay request goes back; A replays; B applies the held ones too.
    try p.pump(gpa);
    try std.testing.expect(p.agree());
    try std.testing.expectEqual(@as(u32, 3), p.b_tl.len());
    try std.testing.expect(p.a.stats.replayed >= 1);
}

test "session: a divergence is settled by a snapshot" {
    const gpa = std.testing.allocator;
    var p = try Pair.init(gpa);
    defer p.deinit(gpa);
    try p.a.hello();
    try p.b.hello();
    _ = try p.a_tl.commit(.{ .add = 1 });
    _ = try p.a_tl.commit(.{ .add = 2 });
    try p.pump(gpa);
    try std.testing.expect(p.agree());

    // B changes something behind the session's back.
    p.b_tl.setRecordObserver(null);
    _ = try p.b_tl.commit(.{ .add = 1000 });
    p.b.attach();
    try std.testing.expect(!p.agree());

    // The probe exposes it; the larger history (B, three features) wins and
    // A adopts B's state, keeping its own identity.
    const a_before = p.a_tl.replicaId();
    try p.a.probe();
    try p.b.probe();
    try p.pump(gpa);
    try std.testing.expect(p.agree());
    try std.testing.expectEqual(@as(u32, 1), p.a.stats.snapshots_loaded);
    try std.testing.expectEqual(@as(u32, 1), p.b.stats.snapshots_sent);
    try std.testing.expectEqual(a_before, p.a_tl.replicaId());

    // Life goes on in both directions after the adoption.
    _ = try p.a_tl.commit(.{ .add = 5 });
    _ = try p.b_tl.commit(.{ .add = 6 });
    try p.pump(gpa);
    try std.testing.expect(p.agree());
}

test "session: frames split across reads are reassembled by the caller" {
    const gpa = std.testing.allocator;
    var p = try Pair.init(gpa);
    defer p.deinit(gpa);
    try p.a.hello();
    try p.b.hello();
    try p.pump(gpa);
    _ = try p.a_tl.commit(.{ .add = 1 });
    _ = try p.a_tl.commit(.{ .add = 2 });

    // Deliver A's bytes to B three bytes at a time, keeping the unconsumed tail.
    const all = try gpa.dupe(u8, p.a.outgoingBytes());
    defer gpa.free(all);
    p.a.clearOutgoing();
    var buffer: std.ArrayList(u8) = .empty;
    defer buffer.deinit(gpa);
    var pos: usize = 0;
    while (pos < all.len) {
        const end = @min(pos + 3, all.len);
        try buffer.appendSlice(gpa, all[pos..end]);
        pos = end;
        const used = try p.b.receiveStream(buffer.items);
        std.mem.copyForwards(u8, buffer.items[0 .. buffer.items.len - used], buffer.items[used..]);
        buffer.shrinkRetainingCapacity(buffer.items.len - used);
    }
    try std.testing.expectEqual(@as(usize, 0), buffer.items.len);
    try p.pump(gpa);
    try std.testing.expect(p.agree());
}
