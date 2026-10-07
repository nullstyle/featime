//! Save/load timelines: a small versioned binary container framing
//! application-encoded payloads.
//!
//! FTZ2 layout (all integers little-endian):
//!
//!   magic "FTZ2"
//!   u64 timeline_id
//!   u32 seed_doc_len   + bytes from `Domain.encodeDoc`
//!   u32 feature_count
//!   feature_count × { u64 id, u8 suppressed, u32 op_len + bytes from
//!                     `Domain.encodeOp` }
//!   u32 marker
//!   --- annotation sections ---
//!   u32 name_count     × { u64 feature_id, framed name }
//!   u32 chapter_count  × { u64 chapter_id, u64 after (0 = end-pinned),
//!                          framed name }
//!   u32 provenance_ct  × { u64 feature_id, u64 author, u64 ts }
//!
//! FTZ1 files load as timelines with no annotations (and a fresh
//! timeline_id); the versioned-container promise, exercised.
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

pub const magic = "FTZ2";
pub const magic_v1 = "FTZ1";

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
    try writer.writeInt(u64, tl.timeline_id, .little);

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

    // Annotation sections.
    var name_count: u32 = 0;
    var nit = tl.ann.names.iterator();
    while (nit.next()) |_| name_count += 1;
    try writer.writeInt(u32, name_count, .little);
    nit = tl.ann.names.iterator();
    while (nit.next()) |e| {
        try writer.writeInt(u64, e.key_ptr.*, .little);
        try writeFramed(writer, e.value_ptr.*);
    }

    try writer.writeInt(u32, @intCast(tl.ann.chapters.items.len), .little);
    for (tl.ann.chapters.items) |c| {
        try writer.writeInt(u64, c.id, .little);
        try writer.writeInt(u64, c.mark.after orelse 0, .little);
        try writeFramed(writer, c.name);
    }

    var prov_count: u32 = 0;
    var pit = tl.ann.prov.iterator();
    while (pit.next()) |_| prov_count += 1;
    try writer.writeInt(u32, prov_count, .little);
    pit = tl.ann.prov.iterator();
    while (pit.next()) |e| {
        try writer.writeInt(u64, e.key_ptr.*, .little);
        try writer.writeInt(u64, e.value_ptr.author, .little);
        try writer.writeInt(u64, e.value_ptr.ts, .little);
    }
}

fn writeFramed(writer: *std.Io.Writer, bytes: []const u8) !void {
    try writer.writeInt(u32, @intCast(bytes.len), .little);
    try writer.writeAll(bytes);
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
    const head = try reader.take(4);
    const v2 = std.mem.eql(u8, head, magic);
    if (!v2 and !std.mem.eql(u8, head, magic_v1))
        return error.BadMagic;

    var timeline_id: u64 = 0;
    if (v2) timeline_id = try reader.takeInt(u64, .little);

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
    if (v2) tl.timeline_id = timeline_id;

    if (v2) {
        const name_count = try reader.takeInt(u32, .little);
        var n: u32 = 0;
        while (n < name_count) : (n += 1) {
            const fid = try reader.takeInt(u64, .little);
            const fr = try framedReader(gpa, reader);
            defer gpa.free(fr.bytes);
            const name_bytes = try gpa.dupe(u8, fr.bytes);
            errdefer gpa.free(name_bytes);
            try tl.ann.giveName(fid, name_bytes);
        }

        const chapter_count = try reader.takeInt(u32, .little);
        var c: u32 = 0;
        while (c < chapter_count) : (c += 1) {
            const cid = try reader.takeInt(u64, .little);
            const after_raw = try reader.takeInt(u64, .little);
            const fr = try framedReader(gpa, reader);
            defer gpa.free(fr.bytes);
            try tl.ann.addChapter(cid, fr.bytes, .{ .after = if (after_raw == 0) null else after_raw });
            if (cid >= tl.next_id) tl.next_id = cid +% 1;
        }

        const prov_count = try reader.takeInt(u32, .little);
        var pv: u32 = 0;
        while (pv < prov_count) : (pv += 1) {
            const fid = try reader.takeInt(u64, .little);
            const author = try reader.takeInt(u64, .little);
            const ts = try reader.takeInt(u64, .little);
            try tl.ann.setProvenance(fid, .{ .author = author, .ts = ts });
        }
    }
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

test "round trip preserves annotations and timeline identity" {
    const gpa = std.testing.allocator;

    var tl = try PersistTimeline.init(gpa, .{}, .{});
    defer tl.deinit();
    const a = try tl.commitWithMeta(.{ .add = 1 }, .{ .author = 7, .ts = 42 });
    const b = try tl.commit(.{ .add = 2 });
    try tl.setFeatureName(a, "ridge");
    _ = try tl.addChapter("before ridge", .{ .after = null });
    _ = try tl.addChapter("after ridge", .{ .after = a });
    tl.setSuppressed(b, true);
    const original_id = tl.timelineId();

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try save(PersistDomain, &tl, gpa, &aw.writer);

    var reader = std.Io.Reader.fixed(aw.written());
    var loaded = try load(PersistDomain, gpa, .{}, &reader);
    defer loaded.deinit();

    try std.testing.expectEqual(original_id, loaded.timelineId());
    try std.testing.expectEqualStrings("ridge", loaded.featureName(a).?);
    try std.testing.expectEqual(ft.Meta{ .author = 7, .ts = 42 }, loaded.provenance(a).?);
    try std.testing.expectEqual(@as(usize, 2), loaded.chapters().len);
    try std.testing.expectEqualStrings("before ridge", loaded.chapters()[0].name);
    try std.testing.expect(loaded.chapters()[0].mark.after == null);
    try std.testing.expectEqual(a, loaded.chapters()[1].mark.after.?);
    try std.testing.expectEqual(@as(u32, 1), loaded.markPosition(loaded.chapters()[1].mark));
    // Id space continues past loaded chapter ids.
    _ = try loaded.commit(.{ .add = 3 });
}

test "FTZ1 files load with no annotations and a fresh identity" {
    const gpa = std.testing.allocator;
    // Hand-craft an FTZ1 container: magic, framed seed, count, features, marker.
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll(magic_v1);
    try w.writeInt(u32, 8, .little); // seed doc frame (i64)
    try w.writeInt(i64, 7, .little);
    try w.writeInt(u32, 1, .little); // one feature
    try w.writeInt(u64, 1234, .little); // id
    try w.writeAll(&[1]u8{0}); // not suppressed
    try w.writeInt(u32, 9, .little); // op frame: tag byte + i64
    try w.writeAll(&[1]u8{0});
    try w.writeInt(i64, 5, .little);
    try w.writeInt(u32, 1, .little); // marker

    var reader = std.Io.Reader.fixed(aw.written());
    var loaded = try load(PersistDomain, gpa, .{}, &reader);
    defer loaded.deinit();

    try std.testing.expectEqual(@as(u32, 1), loaded.len());
    try std.testing.expectEqual(@as(i64, 12), loaded.state().value);
    try std.testing.expectEqual(@as(usize, 0), loaded.chapters().len);
    try std.testing.expect(loaded.featureName(1234) == null);
}
