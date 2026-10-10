//! Save/load timelines: a small versioned binary container framing
//! application-encoded payloads.
//!
//! FTZ7 layout (all integers little-endian; "framed" = u32 length + bytes):
//!
//!   magic "FTZ7"
//!   u64 timeline_id
//!   u32 format_version                (the app's `Domain.format_version`)
//!   u32 link_count    × u64 timeline_id   (timelines the features link to; `peekHeader`)
//!   framed seed document              (bytes from `Domain.encodeDoc`)
//!   u32 feature_count × { u64 id, u8 suppressed, u64 order.lamport,
//!                         u64 order.origin, u64 edit.lamport, u64 edit.origin,
//!                         framed op (`Domain.encodeOp`) }
//!   u32 marker
//!   u32 param_count   × { u64 id, u64 value (f64 bit pattern), u64 key.lamport,
//!                         u64 key.origin, framed name }
//!   u32 seen_count    × { u64 origin, u64 seq }   (sync sequence bookkeeping)
//!   --- annotation sections ---
//!   u32 name_count    × { u64 feature_id, framed name }
//!   u32 chapter_count × { u64 chapter_id, u64 after (0 = end-pinned), framed name }
//!   u32 group_count   × { u64 group_id, u64 first, u64 last, framed name }
//!   u32 tag_count     × { u64 feature_id, framed tag }
//!   u32 provenance_ct × { u64 feature_id, u64 author, u64 ts }
//!
//! Older containers still load: FTZ4 has no order keys or seen table (keys
//! are zero, nothing seen); FTZ3 has no format_version either (0 is assumed);
//! FTZ2 has no parameter section either; FTZ1 has no parameters, no
//! annotations, and no timeline_id (a fresh one is generated).
//!
//! App payload versions: a Domain may declare `pub const format_version:
//! u32` (0 when absent). The container records it; when a file's version
//! differs from the Domain's, every op and the seed document are decoded
//! through `Domain.migrateOp(from_version, reader, gpa)` and
//! `Domain.migrateDoc(from_version, reader, gpa)` instead of the regular
//! decoders. Without those hooks a foreign version is
//! `error.UnsupportedFormatVersion`.
//!
//! Frame lengths are never trusted: payloads are read in bounded chunks
//! (`readFramedAlloc`), so a corrupt or hostile length costs at most one
//! chunk of allocation beyond the bytes that actually exist.
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

pub const magic = "FTZ7";
pub const magic_v6 = "FTZ6";
pub const magic_v5 = "FTZ5";
pub const magic_v4 = "FTZ4";
pub const magic_v3 = "FTZ3";
pub const magic_v2 = "FTZ2";
pub const magic_v1 = "FTZ1";

pub const LoadError = error{ BadMagic, UnsupportedFormatVersion };

/// The Domain's payload schema version (`Domain.format_version`, 0 when
/// absent). Recorded in containers and on the sync wire.
pub fn formatVersion(comptime Domain: type) u32 {
    if (!@hasDecl(Domain, "format_version")) return 0;
    return @as(u32, Domain.format_version);
}

/// Decode an op payload written at `stored` format version: the regular
/// decoder when it matches the Domain's, `migrateOp` otherwise.
pub fn decodeOpVersioned(comptime Domain: type, stored: u32, r: *std.Io.Reader, gpa: std.mem.Allocator) anyerror!Domain.Op {
    if (stored == formatVersion(Domain)) return Domain.decodeOp(r, gpa);
    if (comptime @hasDecl(Domain, "migrateOp")) return Domain.migrateOp(stored, r, gpa);
    return error.UnsupportedFormatVersion;
}

/// Decode a document payload written at `stored` format version: the
/// regular decoder when it matches the Domain's, `migrateDoc` otherwise.
pub fn decodeDocVersioned(comptime Domain: type, stored: u32, r: *std.Io.Reader, gpa: std.mem.Allocator) anyerror!Domain.Doc {
    if (stored == formatVersion(Domain)) return Domain.decodeDoc(r, gpa);
    if (comptime @hasDecl(Domain, "migrateDoc")) return Domain.migrateDoc(stored, r, gpa);
    return error.UnsupportedFormatVersion;
}

/// Upper bound on a single allocation while reading a framed payload.
pub const frame_chunk: usize = 64 * 1024;

/// Read a u32-framed payload (length prefix + bytes) into owned memory
/// without trusting the length: bytes are pulled in `frame_chunk` steps, so
/// a length larger than the remaining input fails with `EndOfStream` after
/// allocating at most one extra chunk. Shared with the sync wire codec.
pub fn readFramedAlloc(gpa: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    const len = try reader.takeInt(u32, .little);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var remaining: usize = len;
    while (remaining > 0) {
        const step: usize = @min(remaining, frame_chunk);
        const dest = try list.addManyAsSlice(gpa, step);
        try reader.readSliceAll(dest);
        remaining -= step;
    }
    return list.toOwnedSlice(gpa);
}

fn validateCodecs(comptime Domain: type) void {
    if (!@hasDecl(Domain, "encodeOp"))
        @compileError("persistence requires `pub fn encodeOp(op: Op, w: *std.Io.Writer) anyerror!void` on the Domain");
    if (!@hasDecl(Domain, "decodeOp"))
        @compileError("persistence requires `pub fn decodeOp(r: *std.Io.Reader, gpa: std.mem.Allocator) anyerror!Op` on the Domain");
    if (!@hasDecl(Domain, "encodeDoc"))
        @compileError("persistence requires `pub fn encodeDoc(doc: *const Doc, w: *std.Io.Writer) anyerror!void` on the Domain");
    if (!@hasDecl(Domain, "decodeDoc"))
        @compileError("persistence requires `pub fn decodeDoc(r: *std.Io.Reader, gpa: std.mem.Allocator) anyerror!Doc` on the Domain");
    ft.checkHook(Domain, "encodeOp", &.{ Domain.Op, *std.Io.Writer }, void, .error_union, "fn (op: Op, w: *std.Io.Writer) anyerror!void");
    ft.checkHook(Domain, "decodeOp", &.{ *std.Io.Reader, std.mem.Allocator }, Domain.Op, .error_union, "fn (r: *std.Io.Reader, gpa: std.mem.Allocator) anyerror!Op");
    ft.checkHook(Domain, "encodeDoc", &.{ *const Domain.Doc, *std.Io.Writer }, void, .error_union, "fn (doc: *const Doc, w: *std.Io.Writer) anyerror!void");
    ft.checkHook(Domain, "decodeDoc", &.{ *std.Io.Reader, std.mem.Allocator }, Domain.Doc, .error_union, "fn (r: *std.Io.Reader, gpa: std.mem.Allocator) anyerror!Doc");
    if (@hasDecl(Domain, "migrateOp"))
        ft.checkHook(Domain, "migrateOp", &.{ u32, *std.Io.Reader, std.mem.Allocator }, Domain.Op, .error_union, "fn (from_version: u32, r: *std.Io.Reader, gpa: std.mem.Allocator) anyerror!Op");
    if (@hasDecl(Domain, "migrateDoc"))
        ft.checkHook(Domain, "migrateDoc", &.{ u32, *std.Io.Reader, std.mem.Allocator }, Domain.Doc, .error_union, "fn (from_version: u32, r: *std.Io.Reader, gpa: std.mem.Allocator) anyerror!Doc");
}

/// Options for `savePrefix`.
pub const PrefixOptions = struct {
    /// Identity written into the file; null keeps the source timeline's id.
    /// Give a scenario variant its own id so replicas never confuse the two.
    timeline_id: ?u64 = null,
};

/// Serialize the timeline (feature list, ids, suppression, marker, seed,
/// parameters, annotations). Op/doc payloads are produced by the Domain's
/// encode hooks.
pub fn save(
    comptime Domain: type,
    tl: *const ft.Timeline(Domain),
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
) anyerror!void {
    try saveUpTo(Domain, tl, gpa, writer, tl.len(), tl.timeline_id);
}

/// Serialize only `features[0..mark]` — a fork point. The marker is clamped
/// to `mark`; names, tags and provenance of dropped features go with them;
/// chapters anchored beyond the mark are dropped (end-pinned ones stay and
/// follow the new tip); groups that start inside the prefix are kept with
/// their end clamped to the last kept feature; parameters are all kept.
/// Load the result like any container to get an independent timeline — a
/// scenario variant when `opts.timeline_id` gives it a new identity.
/// `Timeline.markPosition` turns a chapter into a `mark`.
pub fn savePrefix(
    comptime Domain: type,
    tl: *const ft.Timeline(Domain),
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    mark: u32,
    opts: PrefixOptions,
) anyerror!void {
    const upto = @min(mark, tl.len());
    try saveUpTo(Domain, tl, gpa, writer, upto, opts.timeline_id orelse tl.timeline_id);
}

fn saveUpTo(
    comptime Domain: type,
    tl: *const ft.Timeline(Domain),
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    upto: u32,
    timeline_id: u64,
) anyerror!void {
    validateCodecs(Domain);
    const kept_list = tl.list.items[0..upto];
    var kept: std.AutoHashMapUnmanaged(ft.FeatureId, void) = .empty;
    defer kept.deinit(gpa);
    try kept.ensureTotalCapacity(gpa, upto);
    for (kept_list) |f| kept.putAssumeCapacity(f.id, {});

    try writer.writeAll(magic);
    try writer.writeInt(u64, timeline_id, .little);
    try writer.writeInt(u32, formatVersion(Domain), .little);

    // The manifest: which timelines the kept features link to, so a reader
    // can fetch them first (`peekHeader`).
    const linked = try linkedTimelines(Domain, kept_list, gpa);
    defer gpa.free(linked);
    try writer.writeInt(u32, @intCast(linked.len), .little);
    for (linked) |id| try writer.writeInt(u64, id, .little);

    {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        Domain.encodeDoc(&tl.seed_doc, &aw.writer) catch |err| return scratchError(err);
        try writer.writeInt(u32, @intCast(aw.written().len), .little);
        try writer.writeAll(aw.written());
    }

    try writer.writeInt(u32, upto, .little);
    for (kept_list) |*f| {
        try writer.writeInt(u64, f.id, .little);
        try writer.writeAll(&[1]u8{@intFromBool(f.suppressed)});
        try writer.writeInt(u64, f.order.lamport, .little);
        try writer.writeInt(u64, f.order.origin, .little);
        try writer.writeInt(u64, f.edit.lamport, .little);
        try writer.writeInt(u64, f.edit.origin, .little);
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        Domain.encodeOp(f.op, &aw.writer) catch |err| return scratchError(err);
        try writer.writeInt(u32, @intCast(aw.written().len), .little);
        try writer.writeAll(aw.written());
    }

    try writer.writeInt(u32, @min(tl.marker_pos, upto), .little);

    // Parameters.
    try writer.writeInt(u32, @intCast(tl.ptab.items().len), .little);
    for (tl.ptab.items()) |pm| {
        try writer.writeInt(u64, pm.id, .little);
        try writer.writeInt(u64, @bitCast(pm.value), .little);
        try writer.writeInt(u64, pm.key.lamport, .little);
        try writer.writeInt(u64, pm.key.origin, .little);
        try writeFramed(writer, pm.name);
    }

    // Sync bookkeeping: what this document has absorbed from each origin.
    try writer.writeInt(u32, @intCast(tl.seen.count()), .little);
    var seen_it = tl.seen.iterator();
    while (seen_it.next()) |e| {
        try writer.writeInt(u64, e.key_ptr.*, .little);
        try writer.writeInt(u64, e.value_ptr.*, .little);
    }

    // Annotation sections, filtered to kept features.
    var name_count: u32 = 0;
    var nit = tl.ann.names.iterator();
    while (nit.next()) |e| {
        if (kept.contains(e.key_ptr.*)) name_count += 1;
    }
    try writer.writeInt(u32, name_count, .little);
    nit = tl.ann.names.iterator();
    while (nit.next()) |e| {
        if (!kept.contains(e.key_ptr.*)) continue;
        try writer.writeInt(u64, e.key_ptr.*, .little);
        try writeFramed(writer, e.value_ptr.*);
    }

    var chapter_count: u32 = 0;
    for (tl.ann.chapters.items) |c| {
        if (c.mark.after == null or kept.contains(c.mark.after.?)) chapter_count += 1;
    }
    try writer.writeInt(u32, chapter_count, .little);
    for (tl.ann.chapters.items) |c| {
        if (c.mark.after != null and !kept.contains(c.mark.after.?)) continue;
        try writer.writeInt(u64, c.id, .little);
        try writer.writeInt(u64, c.mark.after orelse 0, .little);
        try writeFramed(writer, c.name);
    }

    var group_count: u32 = 0;
    for (tl.ann.groups.items) |g| {
        if (kept.contains(g.first)) group_count += 1;
    }
    try writer.writeInt(u32, group_count, .little);
    for (tl.ann.groups.items) |g| {
        if (!kept.contains(g.first)) continue;
        const last = if (kept.contains(g.last)) g.last else kept_list[upto - 1].id;
        try writer.writeInt(u64, g.id, .little);
        try writer.writeInt(u64, g.first, .little);
        try writer.writeInt(u64, last, .little);
        try writeFramed(writer, g.name);
    }

    var tag_count: u32 = 0;
    var tag_it = tl.ann.tags.iterator();
    while (tag_it.next()) |e| {
        if (kept.contains(e.key_ptr.*)) tag_count += @intCast(e.value_ptr.items.len);
    }
    try writer.writeInt(u32, tag_count, .little);
    tag_it = tl.ann.tags.iterator();
    while (tag_it.next()) |e| {
        if (!kept.contains(e.key_ptr.*)) continue;
        for (e.value_ptr.items) |t| {
            try writer.writeInt(u64, e.key_ptr.*, .little);
            try writeFramed(writer, t);
        }
    }

    var prov_count: u32 = 0;
    var pit = tl.ann.prov.iterator();
    while (pit.next()) |e| {
        if (kept.contains(e.key_ptr.*)) prov_count += 1;
    }
    try writer.writeInt(u32, prov_count, .little);
    pit = tl.ann.prov.iterator();
    while (pit.next()) |e| {
        if (!kept.contains(e.key_ptr.*)) continue;
        try writer.writeInt(u64, e.key_ptr.*, .little);
        try writer.writeInt(u64, e.value_ptr.author, .little);
        try writer.writeInt(u64, e.value_ptr.ts, .little);
    }
}

/// What a container says about itself before any payload: its identity,
/// the app format it was written with, and the timelines its features link
/// to (FTZ6 and later; older containers report no links). Read this first
/// to open or fetch linked timelines before loading the container itself.
pub const Header = struct {
    timeline_id: u64,
    format_version: u32,
    links: []u64,

    pub fn deinit(self: *Header, gpa: std.mem.Allocator) void {
        gpa.free(self.links);
        self.* = undefined;
    }
};

pub fn peekHeader(gpa: std.mem.Allocator, reader: *std.Io.Reader) !Header {
    const head = try reader.take(4);
    const v7 = std.mem.eql(u8, head, magic);
    const v6 = std.mem.eql(u8, head, magic_v6);
    const v5 = std.mem.eql(u8, head, magic_v5);
    const v4 = std.mem.eql(u8, head, magic_v4);
    const v3 = std.mem.eql(u8, head, magic_v3);
    const v2 = std.mem.eql(u8, head, magic_v2);
    if (!v7 and !v6 and !v5 and !v4 and !v3 and !v2 and !std.mem.eql(u8, head, magic_v1))
        return error.BadMagic;
    var h: Header = .{ .timeline_id = 0, .format_version = 0, .links = &.{} };
    if (v7 or v6 or v5 or v4 or v3 or v2) h.timeline_id = try reader.takeInt(u64, .little);
    if (v7 or v6 or v5 or v4) h.format_version = try reader.takeInt(u32, .little);
    if (v7 or v6) {
        // Grown one id at a time: a lying count stops at the end of input.
        const link_count = try reader.takeInt(u32, .little);
        var links: std.ArrayList(u64) = .empty;
        errdefer links.deinit(gpa);
        var k: u32 = 0;
        while (k < link_count) : (k += 1) try links.append(gpa, try reader.takeInt(u64, .little));
        h.links = try links.toOwnedSlice(gpa);
    }
    return h;
}

/// The ids of the timelines `features` link to (`Domain.links`), sorted,
/// without duplicates. Empty without the hook. Caller owns the slice.
pub fn linkedTimelines(comptime Domain: type, features: []const ft.Feature(Domain.Op), gpa: std.mem.Allocator) ![]u64 {
    var out: std.ArrayList(u64) = .empty;
    errdefer out.deinit(gpa);
    if (comptime @hasDecl(Domain, "links")) {
        var collector: ft.LinkCollector = .{ .gpa = gpa };
        defer collector.links.deinit(gpa);
        for (features) |f| {
            collector.links.clearRetainingCapacity();
            Domain.links(f.op, &collector);
            if (collector.failed) return error.OutOfMemory;
            for (collector.links.items) |l| {
                if (std.mem.indexOfScalar(u64, out.items, l.timeline) == null) try out.append(gpa, l.timeline);
            }
        }
        std.mem.sort(u64, out.items, {}, std.sort.asc(u64));
    }
    return out.toOwnedSlice(gpa);
}

/// An in-memory scratch writer fails only for lack of memory: report that
/// as `OutOfMemory`, so `WriteFailed` always means the caller's writer.
pub fn scratchError(err: anyerror) anyerror {
    return if (err == error.WriteFailed) error.OutOfMemory else err;
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
    const v7 = std.mem.eql(u8, head, magic);
    const v6 = std.mem.eql(u8, head, magic_v6);
    const v5 = std.mem.eql(u8, head, magic_v5);
    const v4 = std.mem.eql(u8, head, magic_v4);
    const v3 = std.mem.eql(u8, head, magic_v3);
    const v2 = std.mem.eql(u8, head, magic_v2);
    if (!v7 and !v6 and !v5 and !v4 and !v3 and !v2 and !std.mem.eql(u8, head, magic_v1))
        return error.BadMagic;
    const has_id = v7 or v6 or v5 or v4 or v3 or v2;
    const has_format = v7 or v6 or v5 or v4;
    const has_params = v7 or v6 or v5 or v4 or v3;
    const has_annotations = v7 or v6 or v5 or v4 or v3 or v2;
    const has_order = v7 or v6 or v5;
    const has_links = v7 or v6;
    const has_keys = v7;

    var timeline_id: u64 = 0;
    if (has_id) timeline_id = try reader.takeInt(u64, .little);
    const stored_format: u32 = if (has_format) try reader.takeInt(u32, .little) else 0;
    if (has_links) {
        // The manifest is for `peekHeader`; the features carry the links.
        const link_count = try reader.takeInt(u32, .little);
        var k: u32 = 0;
        while (k < link_count) : (k += 1) _ = try reader.takeInt(u64, .little);
    }

    var doc_reader = try framedReader(gpa, reader);
    defer gpa.free(doc_reader.bytes);
    const seed = try decodeDocVersioned(Domain, stored_format, &doc_reader.reader, gpa);

    var tl = try ft.Timeline(Domain).init(gpa, seed, config);
    errdefer tl.deinit();

    // Loaded ids are foreign to this timeline's fresh id counter and never
    // move it: `Timeline.allocId` skips ids already present, and the random
    // start keeps new ids disjoint from those of any other replica that
    // loads the same file (two replicas must never share a counter).
    const count = try reader.takeInt(u32, .little);
    var i: u32 = 0;
    var max_lamport: u64 = 0;
    while (i < count) : (i += 1) {
        const id = try reader.takeInt(u64, .little);
        const suppressed = (try reader.take(1))[0] != 0;
        var order: ft.OrderKey = .{};
        if (has_order) {
            order.lamport = try reader.takeInt(u64, .little);
            order.origin = try reader.takeInt(u64, .little);
            if (order.lamport > max_lamport) max_lamport = order.lamport;
        }
        var edit: ft.OrderKey = .{};
        if (has_keys) {
            edit.lamport = try reader.takeInt(u64, .little);
            edit.origin = try reader.takeInt(u64, .little);
            if (edit.lamport > max_lamport) max_lamport = edit.lamport;
        }
        var op_reader = try framedReader(gpa, reader);
        defer gpa.free(op_reader.bytes);
        const op = try decodeOpVersioned(Domain, stored_format, &op_reader.reader, gpa);
        try tl.list.append(gpa, .{ .id = id, .op = op, .suppressed = suppressed, .order = order, .edit = edit });
    }
    try tl.rebuildIndex();
    tl.lamport = max_lamport;
    tl.marker_pos = @min(try reader.takeInt(u32, .little), tl.len());
    if (has_params) {
        const param_count = try reader.takeInt(u32, .little);
        var pm: u32 = 0;
        while (pm < param_count) : (pm += 1) {
            const pid = try reader.takeInt(u64, .little);
            const value: f64 = @bitCast(try reader.takeInt(u64, .little));
            var pkey: ft.OrderKey = .{};
            if (has_keys) {
                pkey.lamport = try reader.takeInt(u64, .little);
                pkey.origin = try reader.takeInt(u64, .little);
                if (pkey.lamport > max_lamport) max_lamport = pkey.lamport;
            }
            const fr = try framedReader(gpa, reader);
            defer gpa.free(fr.bytes);
            try tl.ptab.add(pid, fr.bytes, value);
            _ = tl.ptab.setKeyed(pid, value, pkey);
        }
    }
    if (has_order) {
        const seen_count = try reader.takeInt(u32, .little);
        var sc: u32 = 0;
        while (sc < seen_count) : (sc += 1) {
            const origin = try reader.takeInt(u64, .little);
            const seq = try reader.takeInt(u64, .little);
            try tl.seen.put(gpa, origin, seq);
        }
    }

    if (has_id) tl.timeline_id = timeline_id;

    if (has_annotations) {
        const name_count = try reader.takeInt(u32, .little);
        var n: u32 = 0;
        while (n < name_count) : (n += 1) {
            const fid = try reader.takeInt(u64, .little);
            const fr = try framedReader(gpa, reader);
            defer gpa.free(fr.bytes);
            const name_bytes = try gpa.dupe(u8, fr.bytes);
            try tl.ann.giveName(fid, name_bytes); // owns the bytes, even on failure
        }

        const chapter_count = try reader.takeInt(u32, .little);
        var c: u32 = 0;
        while (c < chapter_count) : (c += 1) {
            const cid = try reader.takeInt(u64, .little);
            const after_raw = try reader.takeInt(u64, .little);
            const fr = try framedReader(gpa, reader);
            defer gpa.free(fr.bytes);
            try tl.ann.addChapter(cid, fr.bytes, .{ .after = if (after_raw == 0) null else after_raw });
        }

        const group_count = try reader.takeInt(u32, .little);
        var gr: u32 = 0;
        while (gr < group_count) : (gr += 1) {
            const gid = try reader.takeInt(u64, .little);
            const first = try reader.takeInt(u64, .little);
            const last = try reader.takeInt(u64, .little);
            const fr = try framedReader(gpa, reader);
            defer gpa.free(fr.bytes);
            try tl.ann.addGroup(gid, fr.bytes, first, last);
        }

        const tag_count = try reader.takeInt(u32, .little);
        var tg: u32 = 0;
        while (tg < tag_count) : (tg += 1) {
            const fid = try reader.takeInt(u64, .little);
            const fr = try framedReader(gpa, reader);
            defer gpa.free(fr.bytes);
            _ = try tl.ann.addTag(fid, fr.bytes);
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
    const bytes = try readFramedAlloc(gpa, reader);
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
    try tl.setSuppressed(b, true);
    try tl.edit(a, .{ .add = 20 });
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

var hostile_frame_arena: [1 << 20]u8 = undefined;

test "frame lengths are not trusted: a hostile length cannot force a huge allocation" {
    // A 20-byte file whose seed frame claims 4 GiB. With a 1 MiB bump
    // allocator this used to fail with OutOfMemory (the 4 GiB request); now
    // the read is chunked and fails honestly at end of input.
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try w.writeAll(magic);
    try w.writeInt(u64, 1, .little); // timeline_id
    try w.writeInt(u32, 0, .little); // format_version
    try w.writeInt(u32, 0xFFFF_FFFF, .little); // seed frame claims 4 GiB

    var fba = std.heap.FixedBufferAllocator.init(&hostile_frame_arena);
    var reader = std.Io.Reader.fixed(w.buffered());
    try std.testing.expectError(error.EndOfStream, load(PersistDomain, fba.allocator(), .{}, &reader));
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
    try tl.addTag(a, "terrain");
    try tl.addTag(a, "review");
    _ = try tl.addChapter("before ridge", .{ .after = null });
    _ = try tl.addChapter("after ridge", .{ .after = a });
    try tl.setSuppressed(b, true);
    const original_id = tl.timelineId();

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try save(PersistDomain, &tl, gpa, &aw.writer);

    var reader = std.Io.Reader.fixed(aw.written());
    var loaded = try load(PersistDomain, gpa, .{}, &reader);
    defer loaded.deinit();

    try std.testing.expectEqual(original_id, loaded.timelineId());
    try std.testing.expectEqualStrings("ridge", loaded.featureName(a).?);
    try std.testing.expectEqual(@as(usize, 2), loaded.tags(a).len);
    try std.testing.expectEqualStrings("terrain", loaded.tags(a)[0]);
    try std.testing.expectEqualStrings("review", loaded.tags(a)[1]);
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

test "FTZ2 files load with annotations but no parameters" {
    const gpa = std.testing.allocator;
    // Hand-craft FTZ2: magic, timeline_id, framed seed, 0 features, marker,
    // empty annotation sections (all zero counts) — no params section.
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll(magic_v2);
    try w.writeInt(u64, 777, .little); // timeline_id
    try w.writeInt(u32, 8, .little); // seed doc frame
    try w.writeInt(i64, 3, .little);
    try w.writeInt(u32, 0, .little); // feature count
    try w.writeInt(u32, 0, .little); // marker
    try w.writeInt(u32, 0, .little); // names
    try w.writeInt(u32, 0, .little); // chapters
    try w.writeInt(u32, 0, .little); // groups
    try w.writeInt(u32, 0, .little); // tags
    try w.writeInt(u32, 0, .little); // provenance

    var reader = std.Io.Reader.fixed(aw.written());
    var loaded = try load(PersistDomain, gpa, .{}, &reader);
    defer loaded.deinit();

    try std.testing.expectEqual(@as(u64, 777), loaded.timelineId());
    try std.testing.expectEqual(@as(i64, 3), loaded.state().value);
    try std.testing.expectEqual(@as(usize, 0), loaded.paramsList().len);
    const pid = try loaded.addParam("width", 2.0);
    try std.testing.expectEqual(@as(f64, 2.0), loaded.paramValue(pid).?);
}

// ---------------------------------------------------------------------------
// Forks and format migration
// ---------------------------------------------------------------------------

test "savePrefix keeps the first N features and clamps marker, chapters and groups" {
    const gpa = std.testing.allocator;
    var tl = try PersistTimeline.init(gpa, .{}, .{});
    defer tl.deinit();

    var ids: [5]ft.FeatureId = undefined;
    for (&ids, 0..) |*slot, i| slot.* = try tl.commit(.{ .add = @intCast(i + 1) });
    try tl.setFeatureName(ids[1], "second");
    try tl.setFeatureName(ids[4], "fifth");
    try tl.addTag(ids[1], "keep");
    try tl.addTag(ids[4], "drop");
    _ = try tl.addChapter("after second", .{ .after = ids[1] });
    _ = try tl.addChapter("after fifth", .{ .after = ids[4] });
    _ = try tl.addChapter("tip", .{ .after = null });
    _ = try tl.addGroup("span", ids[1], ids[4]);
    _ = try tl.addGroup("tail", ids[3], ids[4]);
    _ = try tl.addParam("p", 1.5);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try savePrefix(PersistDomain, &tl, gpa, &aw.writer, 3, .{ .timeline_id = 4242 });

    var reader = std.Io.Reader.fixed(aw.written());
    var fork = try load(PersistDomain, gpa, .{}, &reader);
    defer fork.deinit();

    try std.testing.expectEqual(@as(u32, 3), fork.len());
    try std.testing.expectEqual(@as(u32, 3), fork.marker());
    try std.testing.expectEqual(@as(i64, 6), fork.state().value);
    try std.testing.expectEqual(@as(u64, 4242), fork.timelineId());
    try std.testing.expectEqualStrings("second", fork.featureName(ids[1]).?);
    try std.testing.expect(fork.featureById(ids[4]) == null);
    try std.testing.expectEqual(@as(usize, 1), fork.tags(ids[1]).len);
    try std.testing.expectEqual(@as(usize, 2), fork.chapters().len);
    try std.testing.expectEqualStrings("after second", fork.chapters()[0].name);
    try std.testing.expectEqualStrings("tip", fork.chapters()[1].name);
    try std.testing.expectEqual(@as(u32, 3), fork.markPosition(fork.chapters()[1].mark));
    try std.testing.expectEqual(@as(usize, 1), fork.groups().len);
    try std.testing.expectEqual(ids[1], fork.groups()[0].first);
    try std.testing.expectEqual(ids[2], fork.groups()[0].last); // clamped to the last kept feature
    try std.testing.expectEqual(@as(usize, 1), fork.paramsList().len);

    // Without an explicit id the prefix keeps the source identity.
    var aw2: std.Io.Writer.Allocating = .init(gpa);
    defer aw2.deinit();
    try savePrefix(PersistDomain, &tl, gpa, &aw2.writer, 99, .{});
    var reader2 = std.Io.Reader.fixed(aw2.written());
    var same = try load(PersistDomain, gpa, .{}, &reader2);
    defer same.deinit();
    try std.testing.expectEqual(tl.timelineId(), same.timelineId());
    try std.testing.expectEqual(@as(u32, 5), same.len());
}

/// `PersistDomain` one schema generation later: op tags moved by 10 and the
/// document frame gained a leading version byte. Version-0 payloads (the
/// `PersistDomain` layout) are migrated.
const MigratingDomain = struct {
    pub const format_version: u32 = 1;
    pub const Doc = struct { value: i64 = 0 };
    pub const Op = union(enum) { add: i64, mul: i32, fail: u32 };
    pub fn apply(op: Op, doc: *Doc, ctx: *ft.ApplyContext) anyerror!void {
        switch (op) {
            .add => |n| doc.value += n,
            .mul => |n| doc.value *= n,
            .fail => |code| return ctx.fail("failure code {d}", .{code}),
        }
    }
    pub fn encodeOp(op: Op, w: *std.Io.Writer) anyerror!void {
        switch (op) {
            .add => |n| {
                try w.writeAll(&[1]u8{10});
                try w.writeInt(i64, n, .little);
            },
            .mul => |n| {
                try w.writeAll(&[1]u8{11});
                try w.writeInt(i32, n, .little);
            },
            .fail => |code| {
                try w.writeAll(&[1]u8{12});
                try w.writeInt(u32, code, .little);
            },
        }
    }
    pub fn decodeOp(r: *std.Io.Reader, gpa: std.mem.Allocator) anyerror!Op {
        _ = gpa;
        return switch ((try r.take(1))[0]) {
            10 => .{ .add = try r.takeInt(i64, .little) },
            11 => .{ .mul = try r.takeInt(i32, .little) },
            12 => .{ .fail = try r.takeInt(u32, .little) },
            else => error.Malformed,
        };
    }
    pub fn encodeDoc(doc: *const Doc, w: *std.Io.Writer) anyerror!void {
        try w.writeAll(&[1]u8{1});
        try w.writeInt(i64, doc.value, .little);
    }
    pub fn decodeDoc(r: *std.Io.Reader, gpa: std.mem.Allocator) anyerror!Doc {
        _ = gpa;
        if ((try r.take(1))[0] != 1) return error.Malformed;
        return .{ .value = try r.takeInt(i64, .little) };
    }
    pub fn migrateOp(from: u32, r: *std.Io.Reader, gpa: std.mem.Allocator) anyerror!Op {
        if (from != 0) return error.UnsupportedFormatVersion;
        return switch (try PersistDomain.decodeOp(r, gpa)) {
            .add => |n| .{ .add = n },
            .mul => |n| .{ .mul = n },
            .fail => |code| .{ .fail = code },
        };
    }
    pub fn migrateDoc(from: u32, r: *std.Io.Reader, gpa: std.mem.Allocator) anyerror!Doc {
        if (from != 0) return error.UnsupportedFormatVersion;
        const old = try PersistDomain.decodeDoc(r, gpa);
        return .{ .value = old.value };
    }
};

/// Same as `MigratingDomain` but without migration hooks.
const StrictV1Domain = struct {
    pub const format_version: u32 = 1;
    pub const Doc = MigratingDomain.Doc;
    pub const Op = MigratingDomain.Op;
    pub const apply = MigratingDomain.apply;
    pub const encodeOp = MigratingDomain.encodeOp;
    pub const decodeOp = MigratingDomain.decodeOp;
    pub const encodeDoc = MigratingDomain.encodeDoc;
    pub const decodeDoc = MigratingDomain.decodeDoc;
};

test "format version: a version-0 file loads through migrateOp/migrateDoc at version 1" {
    const gpa = std.testing.allocator;
    var old = try PersistTimeline.init(gpa, .{ .value = 7 }, .{});
    defer old.deinit();
    _ = try old.commit(.{ .add = 10 });
    const m = try old.commit(.{ .mul = 3 });
    try old.setFeatureName(m, "triple");

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try save(PersistDomain, &old, gpa, &aw.writer); // written at format version 0

    var reader = std.Io.Reader.fixed(aw.written());
    var migrated = try load(MigratingDomain, gpa, .{}, &reader);
    defer migrated.deinit();
    try std.testing.expectEqual(@as(u32, 2), migrated.len());
    try std.testing.expectEqual(@as(i64, 51), migrated.state().value);
    try std.testing.expectEqualStrings("triple", migrated.featureName(m).?);

    // Saved again, the file is at version 1 and loads with the regular decoders.
    var aw2: std.Io.Writer.Allocating = .init(gpa);
    defer aw2.deinit();
    try save(MigratingDomain, &migrated, gpa, &aw2.writer);
    var reader2 = std.Io.Reader.fixed(aw2.written());
    var again = try load(MigratingDomain, gpa, .{}, &reader2);
    defer again.deinit();
    try std.testing.expectEqual(@as(i64, 51), again.state().value);
}

test "format version: a Domain without migration hooks rejects foreign versions" {
    const gpa = std.testing.allocator;
    var old = try PersistTimeline.init(gpa, .{}, .{});
    defer old.deinit();
    _ = try old.commit(.{ .add = 1 });
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try save(PersistDomain, &old, gpa, &aw.writer);

    var reader = std.Io.Reader.fixed(aw.written());
    try std.testing.expectError(error.UnsupportedFormatVersion, load(StrictV1Domain, gpa, .{}, &reader));
}

test "sync entries carry the format version and migrate on decode" {
    const gpa = std.testing.allocator;
    const syncing = @import("sync.zig");
    const env: ft.Timeline(PersistDomain).Envelope = .{ .origin = 1, .seq = 1, .lamport = 1, .entry = .{ .commit = .{ .id = 9, .op = .{ .add = 5 }, .at = 0 } } };
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try syncing.encode(PersistDomain, &env, gpa, &aw.writer);

    var reader = std.Io.Reader.fixed(aw.written());
    var got = try syncing.decode(MigratingDomain, gpa, &reader);
    defer syncing.deinit(MigratingDomain.Op, gpa, &got);
    try std.testing.expectEqual(@as(i64, 5), got.entry.commit.op.add);

    var reader2 = std.Io.Reader.fixed(aw.written());
    try std.testing.expectError(error.UnsupportedFormatVersion, syncing.decode(StrictV1Domain, gpa, &reader2));
}

test "FTZ6 round-trips order keys and the seen table; FTZ4 files load with zero keys" {
    const gpa = std.testing.allocator;
    var tl = try PersistTimeline.init(gpa, .{}, .{});
    defer tl.deinit();
    _ = try tl.commit(.{ .add = 1 });
    _ = try tl.commit(.{ .add = 2 });
    const foreign: ft.Timeline(PersistDomain).Envelope = .{
        .origin = 77,
        .seq = 1,
        .lamport = 500,
        .entry = .{ .commit = .{ .id = 9000, .op = .{ .add = 3 }, .at = 2, .after = null, .order = .{ .lamport = 500, .origin = 77 } } },
    };
    try std.testing.expectEqual(ft.Timeline(PersistDomain).ApplyResult.applied, tl.applyRemote(&foreign));
    try std.testing.expectEqual(@as(u64, 2), tl.expectedSeq(77));

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try save(PersistDomain, &tl, gpa, &aw.writer);
    var reader = std.Io.Reader.fixed(aw.written());
    var loaded = try load(PersistDomain, gpa, .{}, &reader);
    defer loaded.deinit();

    try std.testing.expectEqual(@as(u64, 2), loaded.expectedSeq(77));
    try std.testing.expectEqual(@as(u64, 500), loaded.lamport);
    for (tl.list.items, loaded.list.items) |want, got| {
        try std.testing.expectEqual(want.id, got.id);
        try std.testing.expectEqual(want.order.lamport, got.order.lamport);
        try std.testing.expectEqual(want.order.origin, got.order.origin);
    }
    try std.testing.expect(loaded.replicaId() != tl.replicaId()); // a loaded timeline is a new replica

    // A hand-crafted FTZ4 file: no order keys, no seen table.
    var aw4: std.Io.Writer.Allocating = .init(gpa);
    defer aw4.deinit();
    const w = &aw4.writer;
    try w.writeAll(magic_v4);
    try w.writeInt(u64, 42, .little); // timeline_id
    try w.writeInt(u32, 0, .little); // format_version
    try w.writeInt(u32, 8, .little); // seed frame
    try w.writeInt(i64, 0, .little);
    try w.writeInt(u32, 1, .little); // one feature
    try w.writeInt(u64, 5, .little); // id
    try w.writeAll(&[1]u8{0}); // not suppressed
    try w.writeInt(u32, 9, .little); // op frame: tag + i64
    try w.writeAll(&[1]u8{0});
    try w.writeInt(i64, 7, .little);
    try w.writeInt(u32, 1, .little); // marker
    try w.writeInt(u32, 0, .little); // params
    try w.writeInt(u32, 0, .little); // names
    try w.writeInt(u32, 0, .little); // chapters
    try w.writeInt(u32, 0, .little); // groups
    try w.writeInt(u32, 0, .little); // tags
    try w.writeInt(u32, 0, .little); // provenance
    var reader4 = std.Io.Reader.fixed(aw4.written());
    var old = try load(PersistDomain, gpa, .{}, &reader4);
    defer old.deinit();
    try std.testing.expectEqual(@as(i64, 7), old.state().value);
    try std.testing.expectEqual(@as(u64, 0), old.list.items[0].order.lamport);
    try std.testing.expectEqual(@as(u64, 1), old.expectedSeq(77));
}

const LinkedDomain = struct {
    pub const Doc = struct { value: i64 = 0 };
    pub const Op = union(enum) { add: i64, read: u64 };
    pub fn apply(op: Op, doc: *Doc, ctx: *ft.ApplyContext) anyerror!void {
        switch (op) {
            .add => |n| doc.value += n,
            .read => |t| _ = ctx.link(t) orelse return ctx.fail("no timeline {d}", .{t}),
        }
    }
    pub fn links(op: Op, out: *ft.LinkCollector) void {
        switch (op) {
            .read => |t| out.link(t),
            .add => {},
        }
    }
    pub fn encodeOp(op: Op, w: *std.Io.Writer) anyerror!void {
        switch (op) {
            .add => |n| {
                try w.writeAll(&[1]u8{1});
                try w.writeInt(i64, n, .little);
            },
            .read => |t| {
                try w.writeAll(&[1]u8{2});
                try w.writeInt(u64, t, .little);
            },
        }
    }
    pub fn decodeOp(r: *std.Io.Reader, gpa: std.mem.Allocator) anyerror!Op {
        _ = gpa;
        return switch ((try r.take(1))[0]) {
            1 => .{ .add = try r.takeInt(i64, .little) },
            2 => .{ .read = try r.takeInt(u64, .little) },
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

test "FTZ6 header lists the linked timelines; peekHeader reads it without the Domain" {
    const gpa = std.testing.allocator;
    var tl = try ft.Timeline(LinkedDomain).init(gpa, .{}, .{});
    defer tl.deinit();
    _ = try tl.commit(.{ .read = 7 });
    _ = try tl.commit(.{ .add = 1 });
    _ = try tl.commit(.{ .read = 3 });
    _ = try tl.commit(.{ .read = 7 });

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try save(LinkedDomain, &tl, gpa, &aw.writer);

    var reader = std.Io.Reader.fixed(aw.written());
    var header = try peekHeader(gpa, &reader);
    defer header.deinit(gpa);
    try std.testing.expectEqual(tl.timelineId(), header.timeline_id);
    try std.testing.expectEqualSlices(u64, &.{ 3, 7 }, header.links);

    // The whole container still loads after the peek of a fresh reader.
    var reader2 = std.Io.Reader.fixed(aw.written());
    var loaded = try load(LinkedDomain, gpa, .{}, &reader2);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(u32, 4), loaded.len());

    // A prefix carries only the links of the kept features.
    var prefix: std.Io.Writer.Allocating = .init(gpa);
    defer prefix.deinit();
    try savePrefix(LinkedDomain, &tl, gpa, &prefix.writer, 2, .{});
    var reader3 = std.Io.Reader.fixed(prefix.written());
    var header3 = try peekHeader(gpa, &reader3);
    defer header3.deinit(gpa);
    try std.testing.expectEqualSlices(u64, &.{7}, header3.links);
}

test "FTZ7 round-trips edit keys and parameter keys" {
    const gpa = std.testing.allocator;
    var tl = try ft.Timeline(LinkedDomain).init(gpa, .{}, .{});
    defer tl.deinit();
    const a = try tl.commit(.{ .add = 1 });
    _ = try tl.commit(.{ .add = 2 });
    try tl.edit(a, .{ .add = 3 });
    try tl.setSuppressed(a, true);
    const before = tl.structureDigest();

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try save(LinkedDomain, &tl, gpa, &aw.writer);
    var reader = std.Io.Reader.fixed(aw.written());
    var loaded = try load(LinkedDomain, gpa, .{}, &reader);
    defer loaded.deinit();
    try std.testing.expectEqual(before, loaded.structureDigest());
}
