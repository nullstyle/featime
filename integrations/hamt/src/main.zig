//! A HAMT-backed document: hamt-zig's persistent map as the timeline's
//! document.
//!
//! Every document copy the timeline makes — seed, live, checkpoints, job
//! bases — is a value copy that shares structure with the others, so a
//! checkpoint costs nothing and `deinitDoc` is a no-op. The price is the
//! arena: every version lives in it until it is reset, so the application
//! rolls the arena now and then. `Timeline.forEachDoc` is the hook that
//! re-homes the timeline's documents into a fresh arena.
//!
//! Run: zig build run -Doptimize=ReleaseFast

const std = @import("std");
const Io = std.Io;
const ft = @import("featime");
const hamt = @import("hamt");

const Entity = struct { kind: u8, cell: u32 };
const Entities = hamt.AutoMap(u64, Entity);

const World = struct {
    pub const Doc = struct { entities: Entities };

    pub const Op = union(enum) {
        place: struct { id: u64, kind: u8, cell: u32 },
        move: struct { id: u64, cell: u32 },
        remove: struct { id: u64 },
    };

    pub fn apply(op: Op, doc: *Doc, ctx: *ft.ApplyContext) anyerror!void {
        switch (op) {
            .place => |p| {
                if (doc.entities.contains(p.id)) return ctx.fail("entity {d} already placed", .{p.id});
                doc.entities = try doc.entities.put(p.id, .{ .kind = p.kind, .cell = p.cell });
            },
            .move => |m| {
                const e = doc.entities.get(m.id) orelse return ctx.fail("entity {d} does not exist", .{m.id});
                doc.entities = try doc.entities.put(m.id, .{ .kind = e.kind, .cell = m.cell });
            },
            .remove => |r| {
                if (!doc.entities.contains(r.id)) return ctx.fail("entity {d} does not exist", .{r.id});
                doc.entities = try doc.entities.remove(r.id);
            },
        }
    }

    /// A persistent map is a small immutable value: the copy is the clone.
    pub fn cloneDoc(doc: *const Doc, gpa: std.mem.Allocator) anyerror!Doc {
        _ = gpa;
        return doc.*;
    }

    /// Nothing to free per copy: the arena owns every version.
    pub fn deinitDoc(doc: *Doc, gpa: std.mem.Allocator) void {
        _ = doc;
        _ = gpa;
    }
};

const Tl = ft.Timeline(World);

/// Re-home one document into `fresh` (driven by `Timeline.forEachDoc`).
fn rehome(fresh: *Entities.Arena, doc: *World.Doc) anyerror!void {
    var editor = fresh.empty().edit();
    var it = doc.entities.iterator();
    while (it.next()) |e| try editor.put(e.key_ptr.*, e.value_ptr.*);
    doc.entities = editor.commit();
}

/// Roll the arena: drop the checkpoints (each would otherwise need its own
/// full copy), move the seed and live documents into a fresh arena, free
/// the old one. Never while a background job is in flight. On
/// `OutOfMemory` midway the timeline is lost: treat it as fatal.
fn rollArena(tl: *Tl, arena: *Entities.Arena, gpa: std.mem.Allocator) !void {
    _ = tl.trim(.{ .checkpoints = 0 });
    var fresh = try Entities.Arena.init(gpa);
    try tl.forEachDoc(&fresh, rehome);
    arena.deinit();
    arena.* = fresh;
}

const Timer = struct {
    io: Io,
    start: Io.Timestamp,
    fn begin(io: Io) Timer {
        return .{ .io = io, .start = Io.Clock.now(.awake, io) };
    }
    fn ms(self: Timer) f64 {
        const end = Io.Clock.now(.awake, self.io);
        return @as(f64, @floatFromInt(@as(u64, @intCast(self.start.durationTo(end).toNanoseconds())))) / 1e6;
    }
};

fn mib(bytes: usize) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var buffer: [8192]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stdout(), io, &buffer);
    const out = &file_writer.interface;
    defer out.flush() catch {};

    var arena = try Entities.Arena.init(gpa);
    defer arena.deinit();
    var tl = try Tl.init(gpa, .{ .entities = arena.empty() }, .{
        .checkpoint_interval = 100,
        .max_checkpoints = 64,
        .checkpoint_on_scrub = true,
    });
    defer tl.deinit();

    const n: u32 = 20_000;
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();

    try out.print("== HAMT-backed document: {d} entities ==\n", .{n});

    // 1. Place n entities: each apply is one persistent put.
    var t = Timer.begin(io);
    var id: u64 = 1;
    while (id <= n) : (id += 1) {
        _ = try tl.commit(.{ .place = .{ .id = id, .kind = @intCast(id % 3), .cell = random.uintLessThan(u32, 4096) } });
    }
    try out.print("place {d} entities:            {d:>8.2} ms   arena {d:.1} MiB, {d} checkpoints\n", .{ n, t.ms(), mib(arena.queryCapacity()), tl.stats().checkpoints });

    // 2. Scrub to the middle and back: checkpoints are value copies, so
    //    taking them costs nothing; replays still run the ops.
    t = Timer.begin(io);
    tl.setMarker(n / 2);
    _ = tl.state();
    try out.print("scrub to middle:                 {d:>8.2} ms   {d} entities visible\n", .{ t.ms(), tl.state().entities.len() });
    t = Timer.begin(io);
    tl.setMarker(n);
    _ = tl.state();
    try out.print("scrub back (snapshot):           {d:>8.2} ms   {d} entities visible\n", .{ t.ms(), tl.state().entities.len() });

    // 3. A parametric edit in the middle: suffix replay from a checkpoint.
    var it = tl.features();
    var k: u32 = 0;
    var middle: ft.FeatureId = 0;
    while (it.next()) |f| : (k += 1) {
        if (k == n / 2) middle = f.id;
    }
    t = Timer.begin(io);
    try tl.edit(middle, .{ .place = .{ .id = n / 2 + 1, .kind = 9, .cell = 0 } });
    _ = tl.state();
    try out.print("edit middle + suffix replay:     {d:>8.2} ms   entity {d} now kind {d}\n", .{ t.ms(), n / 2 + 1, tl.state().entities.get(n / 2 + 1).?.kind });

    // 4. The arena holds every version ever made. Roll it: drop checkpoints,
    //    re-home seed + live, free the old arena.
    const before = arena.queryCapacity();
    t = Timer.begin(io);
    try rollArena(&tl, &arena, gpa);
    try out.print("roll arena:                      {d:>8.2} ms   {d:.1} MiB -> {d:.1} MiB, {d} checkpoints\n", .{ t.ms(), mib(before), mib(arena.queryCapacity()), tl.stats().checkpoints });
    try out.print("state after roll:                           {d} entities, entity {d} kind {d}\n", .{ tl.state().entities.len(), n / 2 + 1, tl.state().entities.get(n / 2 + 1).?.kind });

    // 5. Undo still works: the journal is independent of the arena. With
    //    the checkpoints gone, this replays from the seed.
    t = Timer.begin(io);
    _ = tl.undo();
    _ = tl.state();
    try out.print("undo the edit + full replay:     {d:>8.2} ms   entity {d} kind {d} again\n", .{ t.ms(), n / 2 + 1, tl.state().entities.get(n / 2 + 1).?.kind });
}

test "world: place, move, remove, scrub and an arena roll keep the state" {
    const gpa = std.testing.allocator;
    var arena = try Entities.Arena.init(gpa);
    defer arena.deinit();
    var tl = try Tl.init(gpa, .{ .entities = arena.empty() }, .{ .checkpoint_on_scrub = true });
    defer tl.deinit();

    const a = try tl.commit(.{ .place = .{ .id = 1, .kind = 1, .cell = 10 } });
    _ = try tl.commit(.{ .place = .{ .id = 2, .kind = 2, .cell = 20 } });
    _ = try tl.commit(.{ .move = .{ .id = 1, .cell = 11 } });
    _ = try tl.commit(.{ .place = .{ .id = 1, .kind = 1, .cell = 0 } }); // soft-fails: exists
    try std.testing.expectEqual(@as(usize, 2), tl.state().entities.len());
    try std.testing.expectEqual(@as(u32, 11), tl.state().entities.get(1).?.cell);

    tl.setMarker(1);
    try std.testing.expectEqual(@as(usize, 1), tl.state().entities.len());
    tl.setMarker(4);
    try std.testing.expectEqual(@as(usize, 2), tl.state().entities.len());
    try std.testing.expect(tl.stats().checkpoints > 0);

    try rollArena(&tl, &arena, gpa);
    try std.testing.expectEqual(@as(u32, 0), tl.stats().checkpoints);
    try std.testing.expectEqual(@as(usize, 2), tl.state().entities.len());
    try std.testing.expectEqual(@as(u32, 11), tl.state().entities.get(1).?.cell);

    // Without the first placement the move soft-fails and the duplicate
    // placement at cell 0 succeeds instead: still 2 entities, cell 0.
    try tl.remove(a);
    try std.testing.expectEqual(@as(usize, 2), tl.state().entities.len());
    try std.testing.expectEqual(@as(u32, 0), tl.state().entities.get(1).?.cell);
    try std.testing.expect(tl.undo());
    try std.testing.expectEqual(@as(u32, 11), tl.state().entities.get(1).?.cell);
}
