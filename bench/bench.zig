//! Benchmark suite: `zig build bench` (always ReleaseFast; `-Dbench-max=N`
//! caps the largest timeline).
//!
//! Measures the hot paths at 1k / 10k / 100k features on a 64x64 heightmap
//! document (16 KiB, plain data): commits at the tip, parametric edits
//! (suffix replay vs full replay), scrubbing, id lookups, undo/redo,
//! removal, mid-history insert, save/load. Single-threaded wall clock.
//! Peak live bytes come from a counting allocator wrapped around the gpa.

const std = @import("std");
const ft = @import("featime");
const build_options = @import("build_options");

const cells: u32 = 64 * 64;

const Terrain = struct {
    pub const Doc = struct { heights: [cells]f32 = @splat(0) };
    pub const Op = union(enum) { raise: struct { cell: u32, amount: f32 } };

    pub fn apply(op: Op, doc: *Doc, ctx: *ft.ApplyContext) anyerror!void {
        _ = ctx;
        switch (op) {
            .raise => |r| doc.heights[r.cell] += r.amount,
        }
    }
    pub fn encodeOp(op: Op, w: *std.Io.Writer) anyerror!void {
        switch (op) {
            .raise => |r| {
                try w.writeInt(u32, r.cell, .little);
                try w.writeInt(u32, @bitCast(r.amount), .little);
            },
        }
    }
    pub fn decodeOp(r: *std.Io.Reader, gpa: std.mem.Allocator) anyerror!Op {
        _ = gpa;
        const cell = try r.takeInt(u32, .little);
        const amount: f32 = @bitCast(try r.takeInt(u32, .little));
        return .{ .raise = .{ .cell = cell, .amount = amount } };
    }
    pub fn encodeDoc(doc: *const Doc, w: *std.Io.Writer) anyerror!void {
        for (doc.heights) |h| try w.writeInt(u32, @bitCast(h), .little);
    }
    pub fn decodeDoc(r: *std.Io.Reader, gpa: std.mem.Allocator) anyerror!Doc {
        _ = gpa;
        var doc: Doc = .{};
        for (&doc.heights) |*h| h.* = @bitCast(try r.takeInt(u32, .little));
        return doc;
    }
};

const Tl = ft.Timeline(Terrain);

/// Tracks live and peak bytes going through it; delegates to `inner`.
const PeakAllocator = struct {
    inner: std.mem.Allocator,
    live: usize = 0,
    peak: usize = 0,
    allocs: usize = 0,

    fn allocator(self: *PeakAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
    fn bump(self: *PeakAllocator, delta_old: usize, delta_new: usize) void {
        self.live = self.live - delta_old + delta_new;
        if (self.live > self.peak) self.peak = self.live;
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *PeakAllocator = @ptrCast(@alignCast(ctx));
        const out = self.inner.rawAlloc(len, alignment, ret_addr);
        if (out != null) {
            self.allocs += 1;
            self.bump(0, len);
        }
        return out;
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *PeakAllocator = @ptrCast(@alignCast(ctx));
        const ok = self.inner.rawResize(memory, alignment, new_len, ret_addr);
        if (ok) self.bump(memory.len, new_len);
        return ok;
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *PeakAllocator = @ptrCast(@alignCast(ctx));
        const out = self.inner.rawRemap(memory, alignment, new_len, ret_addr);
        if (out != null) self.bump(memory.len, new_len);
        return out;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *PeakAllocator = @ptrCast(@alignCast(ctx));
        self.bump(memory.len, 0);
        self.inner.rawFree(memory, alignment, ret_addr);
    }
};

const Timer = struct {
    io: std.Io,
    start: std.Io.Timestamp,

    fn begin(io: std.Io) Timer {
        return .{ .io = io, .start = std.Io.Clock.now(.awake, io) };
    }
    fn ns(self: Timer) u64 {
        const end = std.Io.Clock.now(.awake, self.io);
        return @intCast(self.start.durationTo(end).toNanoseconds());
    }
};

fn row(out: *std.Io.Writer, name: []const u8, ns: u64, per: u64) !void {
    const ms = @as(f64, @floatFromInt(ns)) / 1e6;
    const per_ns = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(@max(per, 1)));
    if (per > 1) {
        try out.print("  {s:<36} {d:>10.3} ms   {d:>12.1} ns/op  (x{d})\n", .{ name, ms, per_ns, per });
    } else {
        try out.print("  {s:<36} {d:>10.3} ms\n", .{ name, ms });
    }
}

fn randomOp(random: std.Random) Terrain.Op {
    return .{ .raise = .{ .cell = random.uintLessThan(u32, cells), .amount = 1 } };
}

fn benchSize(io: std.Io, base_gpa: std.mem.Allocator, out: *std.Io.Writer, n: u32) !void {
    var peak = PeakAllocator{ .inner = base_gpa };
    const gpa = peak.allocator();
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    try out.print("\n== {d} features ==\n", .{n});
    var tl = try Tl.init(gpa, .{}, .{});
    defer tl.deinit();
    const ids = try base_gpa.alloc(ft.FeatureId, n);
    defer base_gpa.free(ids);

    // 1. Commits at the tip: the fast path applies each feature immediately.
    var t = Timer.begin(io);
    for (ids) |*slot| slot.* = try tl.commit(randomOp(random));
    try row(out, "commit at tip", t.ns(), n);

    // 2. Edit feature 0: everything after it replays (interval checkpoints
    //    are laid down along the way).
    t = Timer.begin(io);
    try tl.edit(ids[0], .{ .raise = .{ .cell = 0, .amount = 2 } });
    _ = tl.state();
    try row(out, "edit first + full replay", t.ns(), 1);

    // 3. Edit the middle: suffix replay from the nearest checkpoint.
    t = Timer.begin(io);
    try tl.edit(ids[n / 2], .{ .raise = .{ .cell = 1, .amount = 2 } });
    _ = tl.state();
    try row(out, "edit middle + suffix replay", t.ns(), 1);

    // 4. Scrub to the middle: replay from the best checkpoint at or before it.
    t = Timer.begin(io);
    tl.setMarker(n / 2);
    _ = tl.state();
    try row(out, "scrub to middle", t.ns(), 1);

    // 5. Scrub back to the tip: the snapshot taken when the marker left it.
    t = Timer.begin(io);
    tl.setMarker(n);
    _ = tl.state();
    try row(out, "scrub back to tip (snapshot)", t.ns(), 1);

    // 6. Random id lookups (a linear scan today).
    const lookups: u32 = 1000;
    t = Timer.begin(io);
    var found: u32 = 0;
    var i: u32 = 0;
    while (i < lookups) : (i += 1) {
        if (tl.featureById(ids[random.uintLessThan(u32, n)]) != null) found += 1;
    }
    try row(out, "featureById (random)", t.ns(), lookups);
    if (found != lookups) return error.LookupMissed;

    // 7. Undo and redo of the middle edit (each replays the suffix).
    t = Timer.begin(io);
    _ = tl.undo();
    _ = tl.state();
    try row(out, "undo middle edit + replay", t.ns(), 1);
    t = Timer.begin(io);
    _ = tl.redo();
    _ = tl.state();
    try row(out, "redo + replay", t.ns(), 1);

    // 8. Remove a middle feature.
    t = Timer.begin(io);
    try tl.remove(ids[n / 2 + 1]);
    _ = tl.state();
    try row(out, "remove middle + replay", t.ns(), 1);

    // 9. Commit while rolled back to the middle: memmove + suffix handling.
    tl.setMarker(n / 2);
    _ = tl.state();
    t = Timer.begin(io);
    _ = try tl.commit(randomOp(random));
    _ = tl.state();
    try row(out, "commit mid-history", t.ns(), 1);
    tl.setMarker(tl.len());
    _ = tl.state();

    // 10. Save, load, and the first state() after loading (lazy full replay).
    var file: std.Io.Writer.Allocating = .init(base_gpa);
    defer file.deinit();
    t = Timer.begin(io);
    try ft.persistence.save(Terrain, &tl, gpa, &file.writer);
    try row(out, "save", t.ns(), 1);
    var reader = std.Io.Reader.fixed(file.written());
    t = Timer.begin(io);
    var loaded = try ft.persistence.load(Terrain, gpa, .{}, &reader);
    defer loaded.deinit();
    try row(out, "load (lazy)", t.ns(), 1);
    t = Timer.begin(io);
    _ = loaded.state();
    try row(out, "first state() after load", t.ns(), 1);

    const s = tl.stats();
    try out.print("  memory: peak {d:.1} MiB live, {d} allocations; {d} checkpoints, {d} journal entries; file {d:.1} KiB\n", .{
        @as(f64, @floatFromInt(peak.peak)) / (1024.0 * 1024.0),
        peak.allocs,
        s.checkpoints,
        s.journal_entries,
        @as(f64, @floatFromInt(file.written().len)) / 1024.0,
    });
}

// ---------------------------------------------------------------------------
// A heap-heavy document: a growing list of entities with owned name strings.
// Every checkpoint deep-copies the whole document, so the clone cost grows
// with the number of entities — the case the plain heightmap cannot show.
// ---------------------------------------------------------------------------

const Entity = struct { id: u64, cell: u32, name: []u8 };

const Scene = struct {
    pub const Doc = struct { entities: std.ArrayList(Entity) = .empty };
    pub const Op = union(enum) {
        spawn: struct { id: u64, cell: u32 },
        move: struct { id: u64, cell: u32 },
    };

    pub fn apply(op: Op, doc: *Doc, ctx: *ft.ApplyContext) anyerror!void {
        switch (op) {
            .spawn => |sp| {
                // A short owned name per entity: the typical "strings in the
                // document" shape.
                const name = try std.fmt.allocPrint(ctx.alloc, "entity-{d}", .{sp.id});
                errdefer ctx.alloc.free(name);
                try doc.entities.append(ctx.alloc, .{ .id = sp.id, .cell = sp.cell, .name = name });
            },
            .move => |mv| {
                for (doc.entities.items) |*e| {
                    if (e.id == mv.id) {
                        e.cell = mv.cell;
                        return;
                    }
                }
                return ctx.fail("entity {d} does not exist", .{mv.id});
            },
        }
    }

    pub fn cloneDoc(doc: *const Doc, gpa: std.mem.Allocator) anyerror!Doc {
        var out: Doc = .{};
        errdefer deinitDoc(&out, gpa);
        try out.entities.ensureTotalCapacity(gpa, doc.entities.items.len);
        for (doc.entities.items) |e| {
            const name = try gpa.dupe(u8, e.name);
            out.entities.appendAssumeCapacity(.{ .id = e.id, .cell = e.cell, .name = name });
        }
        return out;
    }

    pub fn deinitDoc(doc: *Doc, gpa: std.mem.Allocator) void {
        for (doc.entities.items) |e| gpa.free(e.name);
        doc.entities.deinit(gpa);
    }
};

const SceneTl = ft.Timeline(Scene);

fn benchHeapDoc(io: std.Io, base_gpa: std.mem.Allocator, out: *std.Io.Writer, n: u32) !void {
    var peak = PeakAllocator{ .inner = base_gpa };
    const gpa = peak.allocator();
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    try out.print("\n== heap-heavy document: {d} entities ==\n", .{n});
    var tl = try SceneTl.init(gpa, .{}, .{});
    defer tl.deinit();
    const ids = try base_gpa.alloc(ft.FeatureId, n);
    defer base_gpa.free(ids);

    var t = Timer.begin(io);
    for (ids, 1..) |*slot, i| slot.* = try tl.commit(.{ .spawn = .{ .id = i, .cell = random.uintLessThan(u32, 4096) } });
    try row(out, "spawn (commit at tip)", t.ns(), n);

    t = Timer.begin(io);
    try tl.edit(ids[0], .{ .spawn = .{ .id = 1, .cell = 7 } });
    _ = tl.state();
    try row(out, "edit first + full replay", t.ns(), 1);

    t = Timer.begin(io);
    try tl.edit(ids[n / 2], .{ .spawn = .{ .id = n / 2 + 1, .cell = 7 } });
    _ = tl.state();
    try row(out, "edit middle + suffix replay", t.ns(), 1);

    t = Timer.begin(io);
    tl.setMarker(n / 2);
    _ = tl.state();
    try row(out, "scrub to middle", t.ns(), 1);
    t = Timer.begin(io);
    tl.setMarker(n);
    _ = tl.state();
    try row(out, "scrub back to tip (snapshot)", t.ns(), 1);

    // One checkpoint of the full document, in isolation.
    t = Timer.begin(io);
    var copy = try Scene.cloneDoc(tl.state(), gpa);
    const clone_ns = t.ns();
    Scene.deinitDoc(&copy, gpa);
    try row(out, "cloneDoc of the full document", clone_ns, 1);

    t = Timer.begin(io);
    _ = tl.undo();
    _ = tl.state();
    try row(out, "undo middle edit + replay", t.ns(), 1);

    const s = tl.stats();
    try out.print("  memory: peak {d:.1} MiB live, {d} allocations; {d} checkpoints, {d} journal entries\n", .{
        @as(f64, @floatFromInt(peak.peak)) / (1024.0 * 1024.0),
        peak.allocs,
        s.checkpoints,
        s.journal_entries,
    });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buffer: [8192]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), io, &buffer);
    const out = &file_writer.interface;

    try out.print("featime benchmarks (ReleaseFast, single thread)\n", .{});
    try out.print("part 1: plain-data document (64x64 f32 heightmap, 16 KiB)\n", .{});
    const sizes = [_]u32{ 1_000, 10_000, 100_000 };
    for (sizes) |n| {
        if (n > build_options.max_features) break;
        try benchSize(io, init.gpa, out, n);
        try out.flush();
    }
    try out.print("\npart 2: heap-heavy document (entity list with owned strings; grows with the timeline)\n", .{});
    for (sizes) |n| {
        if (n > build_options.max_features) break;
        try benchHeapDoc(io, init.gpa, out, n);
        try out.flush();
    }
    try out.flush();
}
