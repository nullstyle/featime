//! Save/load timelines: a small versioned binary container framing
//! application-encoded payloads.
//!
//! Layout (all integers little-endian):
//!
//!   magic "FTZ1"
//!   u32 seed_doc_len   + bytes from `Domain.encodeDoc`
//!   u32 feature_count
//!   feature_count × { u64 id, u8 suppressed, u32 op_len + bytes from
//!                     `Domain.encodeOp` }
//!   u32 marker
//!
//! Features are the source of truth (this is parametric history, not a
//! snapshot): loading replays lazily exactly like a fresh edit session. Ids,
//! suppression, and the marker round-trip; statuses, checkpoints, and the
//! undo journal do not (they are recomputed / start empty), matching Fusion
//! document semantics.
//!
//! Op and doc payloads are length-framed so the container can bound decode
//! work and stay forward-compatible with new op kinds (unknown frames can be
//! skipped by future readers).

const std = @import("std");
const ft = @import("root.zig");

pub const magic = "FTZ1";

pub const LoadError = error{BadMagic};

fn validateCodecs(comptime Domain: type) void {
    if (!@hasDecl(Domain, "encodeOp"))
        @compileError("persistence requires `pub fn encodeOp(op: Op, w: *std.Io.Writer) anyerror!void` on the Domain");
    if (!@hasDecl(Domain, "decodeOp"))
        @compileError("persistence requires `pub fn decodeOp(r: *std.Io.Reader, gpa: std.mem.Allocator) anyerror!Op` on the Domain");
    if (!@hasDecl(Domain, "encodeDoc"))
        @compileError("persistence requires `pub fn encodeDoc(doc: *const Doc, w: *std.Io.Writer) anyerror!void` on the Domain");
    if (!@hasDecl(Domain, "decodeDoc"))
        @compileError("persistence requires `pub fn decodeDoc(r: *std.Io.Reader, gpa: std.mem.Allocator) anyerror!Doc` on the Domain");
}

/// Serialize the timeline (feature list, ids, suppression, marker, seed).
/// Op/doc payloads are produced by the Domain's encode hooks.
pub fn save(
    comptime Domain: type,
    tl: *const ft.Timeline(Domain),
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
) anyerror!void {
    validateCodecs(Domain);
    try writer.writeAll(magic);

    {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try Domain.encodeDoc(&tl.seed_doc, &aw.writer);
        try writer.writeInt(u32, @intCast(aw.written().len), .little);
        try writer.writeAll(aw.written());
    }

    try writer.writeInt(u32, tl.len(), .little);
    for (tl.list.items) |*f| {
        try writer.writeInt(u64, f.id, .little);
        try writer.writeAll(&[1]u8{@intFromBool(f.suppressed)});
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        try Domain.encodeOp(f.op, &aw.writer);
        try writer.writeInt(u32, @intCast(aw.written().len), .little);
        try writer.writeAll(aw.written());
    }

    try writer.writeInt(u32, tl.marker_pos, .little);
}

/// Deserialize a timeline written by `save`. Uses `config` for the loaded
/// timeline's cache/journal knobs. The state is dirty on return: call
/// `state()` to force the initial rebuild.
pub fn load(
    comptime Domain: type,
    gpa: std.mem.Allocator,
    config: ft.Config,
    reader: *std.Io.Reader,
) anyerror!ft.Timeline(Domain) {
    validateCodecs(Domain);
    if (!std.mem.eql(u8, try reader.take(magic.len), magic))
        return error.BadMagic;

    var doc_reader = try framedReader(gpa, reader);
    defer gpa.free(doc_reader.bytes);
    const seed = try Domain.decodeDoc(&doc_reader.reader, gpa);

    var tl = try ft.Timeline(Domain).init(gpa, seed, config);
    errdefer tl.deinit();

    const count = try reader.takeInt(u32, .little);
    var max_id: ft.FeatureId = 0;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const id = try reader.takeInt(u64, .little);
        const suppressed = (try reader.take(1))[0] != 0;
        var op_reader = try framedReader(gpa, reader);
        defer gpa.free(op_reader.bytes);
        const op = try Domain.decodeOp(&op_reader.reader, gpa);
        try tl.list.append(gpa, .{ .id = id, .op = op, .suppressed = suppressed });
        if (id > max_id) max_id = id;
    }
    tl.marker_pos = @min(try reader.takeInt(u32, .little), tl.len());
    if (max_id >= tl.next_id) tl.next_id = max_id +% 1;
    return tl;
}

const FramedReader = struct {
    reader: std.Io.Reader,
    bytes: []u8,
};

fn framedReader(gpa: std.mem.Allocator, reader: *std.Io.Reader) !FramedReader {
    const len = try reader.takeInt(u32, .little);
    const bytes = try reader.readAlloc(gpa, len);
    return .{ .reader = std.Io.Reader.fixed(bytes), .bytes = bytes };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const PersistDomain = struct {
    pub const Doc = struct { value: i64 = 0 };
    pub const Op = union(enum) {
        add: i64,
        mul: i32,
        fail: u32,
    };
    pub fn apply(op: Op, doc: *Doc, ctx: *ft.ApplyContext) anyerror!void {
        switch (op) {
            .add => |n| doc.value += n,
            .mul => |n| doc.value *= n,
            .fail => |code| return ctx.fail("failure code {d}", .{code}),
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
    pub fn encodeOp(op: Op, w: *std.Io.Writer) anyerror!void {
        switch (op) {
            .add => |n| {
                try w.writeAll(&[1]u8{0});
                try w.writeInt(i64, n, .little);
            },
            .mul => |n| {
                try w.writeAll(&[1]u8{1});
                try w.writeInt(i32, n, .little);
            },
            .fail => |code| {
                try w.writeAll(&[1]u8{2});
                try w.writeInt(u32, code, .little);
            },
        }
    }
    pub fn decodeOp(r: *std.Io.Reader, gpa: std.mem.Allocator) anyerror!Op {
        _ = gpa;
        const tag = (try r.take(1))[0];
        return switch (tag) {
            0 => .{ .add = try r.takeInt(i64, .little) },
            1 => .{ .mul = try r.takeInt(i32, .little) },
            2 => .{ .fail = try r.takeInt(u32, .little) },
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

const PersistTimeline = ft.Timeline(PersistDomain);

test "round trip preserves ids, order, suppression, marker, and state" {
    const gpa = std.testing.allocator;

    var tl = try PersistTimeline.init(gpa, .{ .value = 7 }, .{});
    defer tl.deinit();
    const a = try tl.commit(.{ .add = 10 });
    const b = try tl.commit(.{ .mul = 3 });
    const c = try tl.commit(.{ .fail = 12 });
    _ = try tl.commit(.{ .add = 5 });
    tl.setSuppressed(b, true);
    tl.edit(a, .{ .add = 20 });
    tl.setMarker(3); // rolled partway back: marker round-trips
    _ = tl.state();

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try save(PersistDomain, &tl, gpa, &aw.writer);

    var reader = std.Io.Reader.fixed(aw.written());
    var loaded = try load(PersistDomain, gpa, .{}, &reader);
    defer loaded.deinit();

    try std.testing.expectEqual(tl.len(), loaded.len());
    try std.testing.expectEqual(tl.marker(), loaded.marker());
    try std.testing.expectEqual(tl.state().value, loaded.state().value);

    var want_it = tl.features();
    var got_it = loaded.features();
    while (want_it.next()) |want| {
        const got = got_it.next().?;
        try std.testing.expectEqual(want.id, got.id);
        try std.testing.expect(std.meta.eql(want.op.*, got.op.*));
        try std.testing.expectEqual(want.suppressed, got.suppressed);
    }
    // Statuses recompute after load: the failing feature fails again.
    _ = loaded.state();
    try std.testing.expectEqualStrings(
        "failure code 12",
        loaded.featureById(c).?.status.failed,
    );

    // Ids stay collision-free: a committed feature gets a fresh id.
    const fresh = try loaded.commit(.{ .add = 1 });
    var seen: usize = 0;
    var it = loaded.features();
    while (it.next()) |f| {
        if (f.id == fresh) seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), seen);
}

test "bad magic is rejected" {
    const gpa = std.testing.allocator;
    var reader = std.Io.Reader.fixed("XXXX");
    try std.testing.expectError(error.BadMagic, load(PersistDomain, gpa, .{}, &reader));
}

test "truncated input errors instead of looping" {
    const gpa = std.testing.allocator;
    var tl = try PersistTimeline.init(gpa, .{}, .{});
    defer tl.deinit();
    _ = try tl.commit(.{ .add = 1 });

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try save(PersistDomain, &tl, gpa, &aw.writer);

    const full = aw.written();
    var i: usize = 1;
    while (i < full.len) : (i += 1) {
        var reader = std.Io.Reader.fixed(full[0..i]);
        var loaded = load(PersistDomain, gpa, .{}, &reader) catch continue;
        loaded.deinit();
        return error.TruncatedLoadShouldHaveFailed;
    }
}
