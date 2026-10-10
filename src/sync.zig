//! The sync feed: journal entries as a wire vocabulary. The record
//! observer on `Timeline` yields every *locally made* edit as it is
//! journaled; `sync.encode` frames it for the network (ops through the
//! Domain's persistence codecs, annotations as plain framed data);
//! `sync.decode` materializes an owned copy on the receiving side, and
//! `Timeline.applyRemote` integrates it silently — locally journaled for
//! uniform undo, without re-firing the observer (no echo loops).
//!
//! Semantics boundary (see README "Sync"): applyRemote preserves identity
//! exactly (feature/chapter/group/param ids are random-anchored per
//! timeline) and treats positions as hints — indices are clamped, entries
//! referencing unknown ids are dropped. Two replicas fed each other's
//! entries in a consistent order converge; concurrent positional edits are
//! the application layer's problem. `lastWriterWins` is the provided
//! tie-breaker when provenance timestamps are available.

const std = @import("std");
const ft = @import("root.zig");
const persistence = @import("persistence.zig");
const journaling = @import("journal.zig");
const annotations = @import("annotations.zig");
const params = @import("params.zig");

/// Version byte written in front of every encoded entry. Bump it whenever
/// an entry's layout changes; `decode` rejects other versions with
/// `error.UnsupportedWireVersion` instead of misparsing them.
///
/// History: 1 — 0.6.x (implicit, no byte); 2 — 0.7.0 (version byte, move
/// entries carry group fixes, group fixes carry old and new anchors);
/// 3 — 0.8.0 (the app's `format_version` follows the version byte, so a
/// newer peer migrates older ops through `Domain.migrateOp`); 4 — 0.10
/// (envelopes: origin, per-origin sequence number and Lamport clock in
/// front of every entry; commit entries carry predecessor and order key).
pub const wire_version: u8 = 4;

/// One journal entry as it crosses the wire: the replica that emitted it,
/// its per-origin sequence number (1-based; 0 = unsequenced), and that
/// replica's Lamport clock at the time. The record observer yields these;
/// `applyRemote` consumes them.
pub fn Envelope(comptime Op: type) type {
    return struct {
        origin: u64,
        seq: u64 = 0,
        lamport: u64 = 0,
        entry: journaling.Journal(Op).Entry,
    };
}

/// True when the remote edit's provenance wins over the local one by
/// timestamp (ties favor the remote — the caller chose to deliver it).
pub fn lastWriterWins(local: ft.Meta, remote: ft.Meta) bool {
    return remote.ts >= local.ts;
}

fn writeFramed(w: *std.Io.Writer, bytes: []const u8) !void {
    try w.writeInt(u32, @intCast(bytes.len), .little);
    try w.writeAll(bytes);
}

fn writeFramedOp(
    comptime Domain: type,
    op: Domain.Op,
    gpa: std.mem.Allocator,
    w: *std.Io.Writer,
) !void {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    Domain.encodeOp(op, &aw.writer) catch |err| return persistence.scratchError(err);
    try w.writeInt(u32, @intCast(aw.written().len), .little);
    try w.writeAll(aw.written());
}

const Framed = struct {
    bytes: []u8,
    gpa: std.mem.Allocator,

    fn deinit(self: Framed) void {
        self.gpa.free(self.bytes);
    }

    fn reader(self: *const Framed) std.Io.Reader {
        return std.Io.Reader.fixed(self.bytes);
    }
};

fn readFramed(gpa: std.mem.Allocator, r: *std.Io.Reader) !Framed {
    // Bounded, chunked read: the length prefix is never trusted.
    const bytes = try persistence.readFramedAlloc(gpa, r);
    return .{ .bytes = bytes, .gpa = gpa };
}

fn readOp(
    comptime Domain: type,
    gpa: std.mem.Allocator,
    r: *std.Io.Reader,
    stored_format: u32,
) !Domain.Op {
    const framed = try readFramed(gpa, r);
    defer framed.deinit();
    var orr = framed.reader();
    return persistence.decodeOpVersioned(Domain, stored_format, &orr, gpa);
}

fn readString(gpa: std.mem.Allocator, r: *std.Io.Reader) ![]u8 {
    const framed = try readFramed(gpa, r);
    defer framed.deinit();
    return gpa.dupe(u8, framed.bytes);
}

fn writeOptString(w: *std.Io.Writer, s: ?[]const u8) !void {
    if (s) |str| {
        try w.writeAll(&[1]u8{1});
        try writeFramed(w, str);
    } else {
        try w.writeAll(&[1]u8{0});
    }
}

fn readOptString(gpa: std.mem.Allocator, r: *std.Io.Reader) !?[]u8 {
    if ((try r.take(1))[0] == 0) return null;
    return try readString(gpa, r);
}

fn writeMeta(w: *std.Io.Writer, m: ?ft.Meta) !void {
    if (m) |meta| {
        try w.writeAll(&[1]u8{1});
        try w.writeInt(u64, meta.author, .little);
        try w.writeInt(u64, meta.ts, .little);
    } else {
        try w.writeAll(&[1]u8{0});
    }
}

fn readMeta(r: *std.Io.Reader) !?ft.Meta {
    if ((try r.take(1))[0] == 0) return null;
    const author = try r.takeInt(u64, .little);
    const ts = try r.takeInt(u64, .little);
    return .{ .author = author, .ts = ts };
}

fn writeChapterFixes(w: *std.Io.Writer, fixes: []const annotations.ChapterFix) !void {
    try w.writeInt(u32, @intCast(fixes.len), .little);
    for (fixes) |f| {
        try w.writeInt(u64, f.chapter_id, .little);
        try w.writeInt(u64, f.old_mark.after orelse 0, .little);
        try w.writeInt(u64, f.new_mark.after orelse 0, .little);
    }
}

fn readChapterFixes(gpa: std.mem.Allocator, r: *std.Io.Reader) ![]annotations.ChapterFix {
    const n = try r.takeInt(u32, .little);
    const out = try gpa.alloc(annotations.ChapterFix, n);
    errdefer gpa.free(out); // plain structs: nothing to free per element
    for (out) |*f| {
        f.chapter_id = try r.takeInt(u64, .little);
        const after = try r.takeInt(u64, .little);
        f.old_mark = .{ .after = if (after == 0) null else after };
        const new_after = try r.takeInt(u64, .little);
        f.new_mark = .{ .after = if (new_after == 0) null else new_after };
    }
    return out;
}

fn writeGroupFixes(w: *std.Io.Writer, fixes: []const annotations.GroupFix) !void {
    try w.writeInt(u32, @intCast(fixes.len), .little);
    for (fixes) |f| {
        try w.writeInt(u64, f.group_id, .little);
        try w.writeInt(u64, f.old_first, .little);
        try w.writeInt(u64, f.old_last, .little);
        try w.writeInt(u64, f.new_first, .little);
        try w.writeInt(u64, f.new_last, .little);
    }
}

fn readGroupFixes(gpa: std.mem.Allocator, r: *std.Io.Reader) ![]annotations.GroupFix {
    const n = try r.takeInt(u32, .little);
    const out = try gpa.alloc(annotations.GroupFix, n);
    errdefer gpa.free(out); // plain structs: nothing to free per element
    for (out) |*f| {
        f.group_id = try r.takeInt(u64, .little);
        f.old_first = try r.takeInt(u64, .little);
        f.old_last = try r.takeInt(u64, .little);
        f.new_first = try r.takeInt(u64, .little);
        f.new_last = try r.takeInt(u64, .little);
    }
    return out;
}

fn writeTags(w: *std.Io.Writer, tags: []const []const u8) !void {
    try w.writeInt(u32, @intCast(tags.len), .little);
    for (tags) |t| try writeFramed(w, t);
}

fn readTags(gpa: std.mem.Allocator, r: *std.Io.Reader) ![][]const u8 {
    const n = try r.takeInt(u32, .little);
    const out = try gpa.alloc([]const u8, n);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |t| gpa.free(t);
        gpa.free(out);
    }
    for (out) |*slot| {
        slot.* = try readString(gpa, r);
        filled += 1;
    }
    return out;
}

/// Serialize one envelope. Requires the Domain persistence codecs.
pub fn encode(
    comptime Domain: type,
    env: *const Envelope(Domain.Op),
    gpa: std.mem.Allocator,
    w: *std.Io.Writer,
) !void {
    try w.writeAll(&[1]u8{wire_version});
    try w.writeInt(u32, persistence.formatVersion(Domain), .little);
    try w.writeInt(u64, env.origin, .little);
    try w.writeInt(u64, env.seq, .little);
    try w.writeInt(u64, env.lamport, .little);
    switch (env.entry) {
        .commit => |e| {
            try w.writeAll(&[1]u8{1});
            try w.writeInt(u64, e.id, .little);
            try writeFramedOp(Domain, e.op, gpa, w);
            try w.writeInt(u32, e.at, .little);
            try writeMeta(w, e.meta);
            try w.writeInt(u64, e.after orelse 0, .little);
            try w.writeInt(u64, e.order.lamport, .little);
            try w.writeInt(u64, e.order.origin, .little);
        },
        .edit => |e| {
            try w.writeAll(&[1]u8{2});
            try w.writeInt(u64, e.id, .little);
            try writeFramedOp(Domain, e.old_op, gpa, w);
            try writeFramedOp(Domain, e.new_op, gpa, w);
        },
        .remove => |e| {
            try w.writeAll(&[1]u8{3});
            try w.writeInt(u64, e.id, .little);
            try writeFramedOp(Domain, e.op, gpa, w);
            try w.writeInt(u32, e.at, .little);
            try w.writeAll(&[1]u8{@intFromBool(e.suppressed)});
            try w.writeInt(u32, e.marker_pre, .little);
            try writeOptString(w, e.name);
            try writeMeta(w, e.meta);
            try writeChapterFixes(w, e.chapter_fixes);
            try writeTags(w, e.tags.items);
            try writeGroupFixes(w, e.group_fixes);
        },
        .suppress => |e| {
            try w.writeAll(&[1]u8{4});
            try w.writeInt(u64, e.id, .little);
            try w.writeAll(&[1]u8{@intFromBool(e.prev)});
        },
        .move => |e| {
            try w.writeAll(&[1]u8{5});
            try w.writeInt(u64, e.id, .little);
            try w.writeInt(u32, e.from, .little);
            try w.writeInt(u32, e.to, .little);
            try w.writeInt(u32, e.marker_pre, .little);
            try writeGroupFixes(w, e.group_fixes);
        },
        .name_set => |e| {
            try w.writeAll(&[1]u8{6});
            try w.writeInt(u64, e.id, .little);
            try writeOptString(w, e.old);
            try writeOptString(w, e.new);
        },
        .tag_add => |e| {
            try w.writeAll(&[1]u8{7});
            try w.writeInt(u64, e.id, .little);
            try writeFramed(w, e.tag orelse return error.IncompleteEntry);
        },
        .tag_remove => |e| {
            try w.writeAll(&[1]u8{8});
            try w.writeInt(u64, e.id, .little);
            try writeFramed(w, e.tag orelse return error.IncompleteEntry);
        },
        .chapter_add => |e| {
            try w.writeAll(&[1]u8{9});
            try w.writeInt(u64, e.id, .little);
            try w.writeInt(u64, e.mark.after orelse 0, .little);
            try writeFramed(w, e.name orelse return error.IncompleteEntry);
        },
        .chapter_remove => |e| {
            try w.writeAll(&[1]u8{10});
            try w.writeInt(u64, e.id, .little);
            try w.writeInt(u64, e.mark.after orelse 0, .little);
            try writeFramed(w, e.name orelse return error.IncompleteEntry);
        },
        .chapter_rename => |e| {
            try w.writeAll(&[1]u8{11});
            try w.writeInt(u64, e.id, .little);
            try writeFramed(w, e.old orelse return error.IncompleteEntry);
            try writeFramed(w, e.new orelse return error.IncompleteEntry);
        },
        .group_add => |e| {
            try w.writeAll(&[1]u8{12});
            try w.writeInt(u64, e.id, .little);
            try w.writeInt(u64, e.first, .little);
            try w.writeInt(u64, e.last, .little);
            try writeFramed(w, e.name orelse return error.IncompleteEntry);
        },
        .group_remove => |e| {
            try w.writeAll(&[1]u8{13});
            try w.writeInt(u64, e.id, .little);
            try w.writeInt(u64, e.first, .little);
            try w.writeInt(u64, e.last, .little);
            try writeFramed(w, e.name orelse return error.IncompleteEntry);
        },
        .group_rename => |e| {
            try w.writeAll(&[1]u8{14});
            try w.writeInt(u64, e.id, .little);
            try writeFramed(w, e.old orelse return error.IncompleteEntry);
            try writeFramed(w, e.new orelse return error.IncompleteEntry);
        },
        .param_add => |e| {
            try w.writeAll(&[1]u8{15});
            try w.writeInt(u64, e.id, .little);
            try writeFramed(w, e.name orelse return error.IncompleteEntry);
            try w.writeInt(u64, @bitCast(e.value), .little);
        },
        .param_remove => |e| {
            try w.writeAll(&[1]u8{16});
            try w.writeInt(u64, e.id, .little);
            try writeFramed(w, e.name orelse return error.IncompleteEntry);
            try w.writeInt(u64, @bitCast(e.value), .little);
        },
        .param_set => |e| {
            try w.writeAll(&[1]u8{17});
            try w.writeInt(u64, e.id, .little);
            try w.writeInt(u64, @bitCast(e.old), .little);
            try w.writeInt(u64, @bitCast(e.new), .little);
        },
        .param_rename => |e| {
            try w.writeAll(&[1]u8{18});
            try w.writeInt(u64, e.id, .little);
            try writeFramed(w, e.old orelse return error.IncompleteEntry);
            try writeFramed(w, e.new orelse return error.IncompleteEntry);
        },
    }
}

/// Deserialize an owned envelope (strings and slices allocated from `gpa`);
/// free it with `deinit` after use. Envelopes written by another
/// `wire_version` are rejected with `error.UnsupportedWireVersion`.
pub fn decode(
    comptime Domain: type,
    gpa: std.mem.Allocator,
    r: *std.Io.Reader,
) !Envelope(Domain.Op) {
    const version = (try r.take(1))[0];
    if (version != wire_version) return error.UnsupportedWireVersion;
    const stored_format = try r.takeInt(u32, .little);
    const origin = try r.takeInt(u64, .little);
    const seq = try r.takeInt(u64, .little);
    const lamport = try r.takeInt(u64, .little);
    const tag = (try r.take(1))[0];
    const entry: journaling.Journal(Domain.Op).Entry = switch (tag) {
        1 => .{ .commit = .{
            .id = try r.takeInt(u64, .little),
            .op = try readOp(Domain, gpa, r, stored_format),
            .at = try r.takeInt(u32, .little),
            .meta = try readMeta(r),
            .after = blk: {
                const a = try r.takeInt(u64, .little);
                break :blk if (a == 0) null else a;
            },
            .order = .{
                .lamport = try r.takeInt(u64, .little),
                .origin = try r.takeInt(u64, .little),
            },
        } },
        2 => .{ .edit = .{
            .id = try r.takeInt(u64, .little),
            .old_op = try readOp(Domain, gpa, r, stored_format),
            .new_op = try readOp(Domain, gpa, r, stored_format),
        } },
        3 => blk: {
            // Several owned parts: free the earlier ones if a later read fails.
            const id = try r.takeInt(u64, .little);
            const op = try readOp(Domain, gpa, r, stored_format);
            const at = try r.takeInt(u32, .little);
            const suppressed = (try r.take(1))[0] != 0;
            const marker_pre = try r.takeInt(u32, .little);
            const name = try readOptString(gpa, r);
            errdefer if (name) |n| gpa.free(n);
            const meta = try readMeta(r);
            const chapter_fixes = try readChapterFixes(gpa, r);
            errdefer gpa.free(chapter_fixes);
            const tags = try readTags(gpa, r);
            errdefer {
                for (tags) |t| gpa.free(@constCast(t));
                gpa.free(tags);
            }
            const group_fixes = try readGroupFixes(gpa, r);
            break :blk .{ .remove = .{
                .id = id,
                .op = op,
                .at = at,
                .suppressed = suppressed,
                .marker_pre = marker_pre,
                .name = name,
                .meta = meta,
                .chapter_fixes = chapter_fixes,
                .tags = std.ArrayList([]const u8).fromOwnedSlice(tags),
                .group_fixes = group_fixes,
            } };
        },
        4 => .{ .suppress = .{
            .id = try r.takeInt(u64, .little),
            .prev = (try r.take(1))[0] != 0,
        } },
        5 => .{ .move = .{
            .id = try r.takeInt(u64, .little),
            .from = try r.takeInt(u32, .little),
            .to = try r.takeInt(u32, .little),
            .marker_pre = try r.takeInt(u32, .little),
            .group_fixes = try readGroupFixes(gpa, r),
        } },
        6 => blk: {
            const id = try r.takeInt(u64, .little);
            const old = try readOptString(gpa, r);
            errdefer if (old) |o| gpa.free(o);
            const new = try readOptString(gpa, r);
            break :blk .{ .name_set = .{ .id = id, .old = old, .new = new } };
        },
        7 => .{ .tag_add = .{
            .id = try r.takeInt(u64, .little),
            .tag = try readString(gpa, r),
        } },
        8 => .{
            .tag_remove = .{
                .id = try r.takeInt(u64, .little),
                .tag = try readString(gpa, r),
                .at = 0, // local bookkeeping; the receiver finds its own position
            },
        },
        9 => blk: {
            const c = try readChapter(gpa, r);
            break :blk .{ .chapter_add = .{ .id = c.id, .mark = c.mark, .name = c.name } };
        },
        10 => blk: {
            const c = try readChapter(gpa, r);
            break :blk .{ .chapter_remove = .{ .id = c.id, .mark = c.mark, .name = c.name } };
        },
        11 => blk: {
            const id = try r.takeInt(u64, .little);
            const old = try readString(gpa, r);
            errdefer gpa.free(old);
            const new = try readString(gpa, r);
            break :blk .{ .chapter_rename = .{ .id = id, .old = old, .new = new } };
        },
        12 => blk: {
            const g = try readGroup(gpa, r);
            break :blk .{ .group_add = .{ .id = g.id, .first = g.first, .last = g.last, .name = g.name } };
        },
        13 => blk: {
            const g = try readGroup(gpa, r);
            break :blk .{ .group_remove = .{ .id = g.id, .first = g.first, .last = g.last, .name = g.name } };
        },
        14 => blk: {
            const id = try r.takeInt(u64, .little);
            const old = try readString(gpa, r);
            errdefer gpa.free(old);
            const new = try readString(gpa, r);
            break :blk .{ .group_rename = .{ .id = id, .old = old, .new = new } };
        },
        15 => blk: {
            const id = try r.takeInt(u64, .little);
            const name = try readString(gpa, r);
            errdefer gpa.free(name);
            const value: f64 = @bitCast(try r.takeInt(u64, .little));
            break :blk .{ .param_add = .{ .id = id, .name = name, .value = value } };
        },
        16 => blk: {
            const id = try r.takeInt(u64, .little);
            const name = try readString(gpa, r);
            errdefer gpa.free(name);
            const value: f64 = @bitCast(try r.takeInt(u64, .little));
            break :blk .{ .param_remove = .{ .id = id, .name = name, .value = value } };
        },
        17 => .{ .param_set = .{
            .id = try r.takeInt(u64, .little),
            .old = @bitCast(try r.takeInt(u64, .little)),
            .new = @bitCast(try r.takeInt(u64, .little)),
        } },
        18 => blk: {
            const id = try r.takeInt(u64, .little);
            const old = try readString(gpa, r);
            errdefer gpa.free(old);
            const new = try readString(gpa, r);
            break :blk .{ .param_rename = .{ .id = id, .old = old, .new = new } };
        },
        else => return error.BadEntryTag,
    };
    return .{ .origin = origin, .seq = seq, .lamport = lamport, .entry = entry };
}

fn readChapter(gpa: std.mem.Allocator, r: *std.Io.Reader) !annotations.Chapter {
    const cid = try r.takeInt(u64, .little);
    const after = try r.takeInt(u64, .little);
    const name = try readString(gpa, r);
    return .{
        .id = cid,
        .mark = .{ .after = if (after == 0) null else after },
        .name = name,
    };
}

fn readGroup(gpa: std.mem.Allocator, r: *std.Io.Reader) !annotations.Group {
    const gid = try r.takeInt(u64, .little);
    const first = try r.takeInt(u64, .little);
    const last = try r.takeInt(u64, .little);
    const name = try readString(gpa, r);
    return .{ .id = gid, .first = first, .last = last, .name = name };
}

/// Free an envelope produced by `decode` (and any owned memory inside).
pub fn deinit(comptime Op: type, gpa: std.mem.Allocator, env: *Envelope(Op)) void {
    switch (env.entry) {
        .remove => |*e| {
            if (e.name) |n| gpa.free(n);
            gpa.free(e.chapter_fixes);
            for (e.tags.items) |t| gpa.free(@constCast(t));
            e.tags.deinit(gpa);
            gpa.free(e.group_fixes);
        },
        .move => |*e| gpa.free(e.group_fixes),
        .name_set => |*e| {
            freeOpt(gpa, e.old);
            freeOpt(gpa, e.new);
        },
        .tag_add => |*e| freeOpt(gpa, e.tag),
        .tag_remove => |*e| freeOpt(gpa, e.tag),
        .chapter_add => |*e| freeOpt(gpa, e.name),
        .chapter_remove => |*e| freeOpt(gpa, e.name),
        .chapter_rename => |*e| {
            freeOpt(gpa, e.old);
            freeOpt(gpa, e.new);
        },
        .group_add => |*e| freeOpt(gpa, e.name),
        .group_remove => |*e| freeOpt(gpa, e.name),
        .group_rename => |*e| {
            freeOpt(gpa, e.old);
            freeOpt(gpa, e.new);
        },
        .param_add => |*e| freeOpt(gpa, e.name),
        .param_remove => |*e| freeOpt(gpa, e.name),
        .param_rename => |*e| {
            freeOpt(gpa, e.old);
            freeOpt(gpa, e.new);
        },
        else => {},
    }
}

fn freeOpt(gpa: std.mem.Allocator, s: ?[]const u8) void {
    if (s) |x| gpa.free(@constCast(x));
}

// ---------------------------------------------------------------------------
// Session: one link between two replicas, over any byte transport
// ---------------------------------------------------------------------------

/// Frame tags of the session protocol. On a stream, a frame is a u32
/// little-endian length, then the tag byte, then the payload.
pub const FrameTag = enum(u8) {
    /// Who I am and what I hold: u64 replica id, u64 digest, u32 feature
    /// count, u64 Lamport clock. Sent at connect (`hello`) and after
    /// exchanges (`probe`).
    state = 1,
    /// One encoded envelope (`encode`).
    envelope = 2,
    /// Replay request: u64 origin, u64 first sequence wanted.
    want = 3,
    /// Please send your whole state.
    snapshot_request = 4,
    /// A whole state: u64 sender sequence, then a container
    /// (`persistence.save`).
    snapshot = 5,
    /// No payload; counted, so lockstep transports can mark a round.
    ping = 6,
    _,
};

/// A link between this replica and one peer. Feed it the peer's bytes with
/// `receiveStream`; send `outgoingBytes` to the peer. It encodes local edits
/// as envelopes, keeps the recent ones for replay, holds envelopes that
/// arrive early until their gap closes, asks for replays, compares digests,
/// and adopts the peer's snapshot when the two sides disagree. Snapshots
/// replace the timeline in place: set `on_replaced` to re-attach anything
/// that pointed at it (registry, environment).
/// The file-level `deinit` (free an envelope), under a name that does not
/// clash with the session's own `deinit`.
const freeEnvelope = deinit;

pub fn Session(comptime Domain: type) type {
    return struct {
        const Self = @This();
        pub const Tl = ft.Timeline(Domain);

        pub const Stats = struct {
            sent: u32 = 0,
            received: u32 = 0,
            applied: u32 = 0,
            dropped: u32 = 0,
            duplicates: u32 = 0,
            gaps: u32 = 0,
            replayed: u32 = 0,
            snapshots_sent: u32 = 0,
            snapshots_loaded: u32 = 0,
            pings: u32 = 0,
        };

        pub const Replaced = struct {
            ctx: ?*anyopaque = null,
            func: *const fn (ctx: ?*anyopaque, tl: *Tl) void,
        };

        const Retained = struct { seq: u64, bytes: []u8 };

        gpa: std.mem.Allocator,
        tl: *Tl,
        /// The peer's replica id, once it said hello.
        peer: ?u64 = null,
        outgoing: std.ArrayList(u8) = .empty,
        /// This replica's recent envelopes, by sequence, for replay.
        retained: std.ArrayList(Retained) = .empty,
        retain_max: usize = 1024,
        /// Envelopes that arrived before their predecessors.
        pending: std.ArrayList([]u8) = .empty,
        pending_max: usize = 256,
        want_outstanding: bool = false,
        on_replaced: ?Replaced = null,
        stats: Stats = .{},
        /// The digest the peer last reported (`state` frames); compare with
        /// `tl.structureDigest()` to see whether the two sides agree.
        peer_digest: ?u64 = null,

        pub fn init(gpa: std.mem.Allocator, tl: *Tl) Self {
            return .{ .gpa = gpa, .tl = tl };
        }

        pub fn deinit(self: *Self) void {
            self.tl.setRecordObserver(null);
            self.outgoing.deinit(self.gpa);
            self.clearRetained();
            self.retained.deinit(self.gpa);
            self.clearPending();
            self.pending.deinit(self.gpa);
        }

        /// Start listening to the timeline's edits. Called again by a
        /// snapshot adoption, which replaces the timeline.
        pub fn attach(self: *Self) void {
            self.tl.setRecordObserver(.{ .ctx = self, .func = &observe });
        }

        fn observe(ctx: ?*anyopaque, env: *const Tl.Envelope) void {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            var aw: std.Io.Writer.Allocating = .init(self.gpa);
            defer aw.deinit();
            encode(Domain, env, self.gpa, &aw.writer) catch return;
            self.queue(.envelope, aw.written()) catch return;
            self.retain(env.seq, aw.written()) catch return;
        }

        fn retain(self: *Self, seq: u64, bytes: []const u8) !void {
            const owned = try self.gpa.dupe(u8, bytes);
            errdefer self.gpa.free(owned);
            try self.retained.append(self.gpa, .{ .seq = seq, .bytes = owned });
            while (self.retained.items.len > self.retain_max) {
                const old = self.retained.orderedRemove(0);
                self.gpa.free(old.bytes);
            }
        }

        fn clearRetained(self: *Self) void {
            for (self.retained.items) |r| self.gpa.free(r.bytes);
            self.retained.clearRetainingCapacity();
        }

        fn clearPending(self: *Self) void {
            for (self.pending.items) |p| self.gpa.free(p);
            self.pending.clearRetainingCapacity();
        }

        fn queue(self: *Self, tag: FrameTag, payload: []const u8) !void {
            try self.outgoing.ensureUnusedCapacity(self.gpa, 5 + payload.len);
            var len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_buf, @intCast(1 + payload.len), .little);
            self.outgoing.appendSliceAssumeCapacity(&len_buf);
            self.outgoing.appendAssumeCapacity(@backingInt(tag));
            self.outgoing.appendSliceAssumeCapacity(payload);
            self.stats.sent += 1;
        }

        /// Say who we are and what we hold. Send once at connect; the peer
        /// answers with a replay request for what it misses.
        pub fn hello(self: *Self) !void {
            try self.queueState();
        }

        /// Send our state again, after an exchange. A peer whose digest
        /// differs settles it: the smaller history adopts the larger one.
        pub fn probe(self: *Self) !void {
            try self.queueState();
        }

        /// A no-op frame the peer counts (`stats.pings`): lockstep
        /// transports use it to mark the end of a round.
        pub fn ping(self: *Self) !void {
            try self.queue(.ping, &.{});
        }

        fn queueState(self: *Self) !void {
            var buf: [28]u8 = undefined;
            std.mem.writeInt(u64, buf[0..8], self.tl.replicaId(), .little);
            std.mem.writeInt(u64, buf[8..16], self.tl.structureDigest(), .little);
            std.mem.writeInt(u32, buf[16..20], self.tl.len(), .little);
            std.mem.writeInt(u64, buf[20..28], self.tl.lamport, .little);
            try self.queue(.state, &buf);
        }

        fn queueWant(self: *Self, origin: u64, from: u64) !void {
            var buf: [16]u8 = undefined;
            std.mem.writeInt(u64, buf[0..8], origin, .little);
            std.mem.writeInt(u64, buf[8..16], from, .little);
            try self.queue(.want, &buf);
        }

        /// Frames ready for the transport. Send them, then `clearOutgoing`.
        pub fn outgoingBytes(self: *const Self) []const u8 {
            return self.outgoing.items;
        }

        pub fn clearOutgoing(self: *Self) void {
            self.outgoing.clearRetainingCapacity();
        }

        /// Consume every complete frame in `bytes`. Returns how many bytes
        /// were used; a trailing partial frame is left for the caller to
        /// present again with more data.
        pub fn receiveStream(self: *Self, bytes: []const u8) !usize {
            var pos: usize = 0;
            while (bytes.len - pos >= 4) {
                const len = std.mem.readInt(u32, bytes[pos..][0..4], .little);
                if (bytes.len - pos - 4 < len) break;
                try self.receive(bytes[pos + 4 .. pos + 4 + len]);
                pos += 4 + len;
            }
            return pos;
        }

        /// One frame, without its length prefix.
        pub fn receive(self: *Self, frame: []const u8) !void {
            if (frame.len == 0) return error.Malformed;
            self.stats.received += 1;
            const tag: FrameTag = @fromBackingInt(@intCast(frame[0]));
            const payload = frame[1..];
            switch (tag) {
                .state => try self.onState(payload),
                .envelope => try self.onEnvelope(payload),
                .want => try self.onWant(payload),
                .snapshot_request => try self.sendSnapshot(),
                .snapshot => try self.onSnapshot(payload),
                .ping => self.stats.pings += 1,
                _ => return error.Malformed,
            }
        }

        fn onState(self: *Self, payload: []const u8) !void {
            if (payload.len != 28) return error.Malformed;
            const peer = std.mem.readInt(u64, payload[0..8], .little);
            const digest = std.mem.readInt(u64, payload[8..16], .little);
            const len = std.mem.readInt(u32, payload[16..20], .little);
            const lamport = std.mem.readInt(u64, payload[20..28], .little);
            if (self.peer) |known| {
                if (known != peer) {
                    // The peer adopted a snapshot and is a new replica now:
                    // what it still owed us as the old one will never come.
                    self.clearPending();
                    self.want_outstanding = false;
                }
            }
            const first = self.peer == null or self.peer.? != peer;
            self.peer = peer;
            self.peer_digest = digest;
            if (first) {
                // Catch up through replay first; digests are compared on
                // the next probe.
                try self.queueWant(peer, self.tl.expectedSeq(peer));
                return;
            }
            if (digest == self.tl.structureDigest()) return;
            // Disagreement: the larger history wins (more features, then
            // the later clock, then the smaller replica id). The loser
            // asks for a snapshot.
            const theirs_win = len > self.tl.len() or
                (len == self.tl.len() and (lamport > self.tl.lamport or
                    (lamport == self.tl.lamport and peer < self.tl.replicaId())));
            if (theirs_win) try self.queue(.snapshot_request, &.{});
        }

        fn onEnvelope(self: *Self, payload: []const u8) !void {
            var reader = std.Io.Reader.fixed(payload);
            var env = try decode(Domain, self.gpa, &reader);
            defer freeEnvelope(Domain.Op, self.gpa, &env);
            switch (self.tl.applyRemote(&env)) {
                .applied, .dropped => |r| {
                    if (r == .applied) self.stats.applied += 1 else self.stats.dropped += 1;
                    self.want_outstanding = false;
                    try self.drainPending();
                },
                .duplicate => self.stats.duplicates += 1,
                .own => {},
                .gap => {
                    self.stats.gaps += 1;
                    try self.holdPending(payload);
                    if (!self.want_outstanding) {
                        try self.queueWant(env.origin, self.tl.expectedSeq(env.origin));
                        self.want_outstanding = true;
                    }
                },
                .out_of_memory => try self.holdPending(payload),
            }
        }

        fn holdPending(self: *Self, payload: []const u8) !void {
            while (self.pending.items.len >= self.pending_max) {
                const old = self.pending.orderedRemove(0);
                self.gpa.free(old);
            }
            const owned = try self.gpa.dupe(u8, payload);
            errdefer self.gpa.free(owned);
            try self.pending.append(self.gpa, owned);
        }

        /// Retry held envelopes until a pass applies nothing more.
        fn drainPending(self: *Self) !void {
            var progress = true;
            while (progress and self.pending.items.len > 0) {
                progress = false;
                var i: usize = 0;
                while (i < self.pending.items.len) {
                    const bytes = self.pending.items[i];
                    var reader = std.Io.Reader.fixed(bytes);
                    var env = decode(Domain, self.gpa, &reader) catch {
                        self.gpa.free(bytes);
                        _ = self.pending.orderedRemove(i);
                        continue;
                    };
                    defer freeEnvelope(Domain.Op, self.gpa, &env);
                    switch (self.tl.applyRemote(&env)) {
                        .gap, .out_of_memory => i += 1,
                        else => |r| {
                            if (r == .applied) self.stats.applied += 1;
                            progress = true;
                            self.gpa.free(bytes);
                            _ = self.pending.orderedRemove(i);
                        },
                    }
                }
            }
        }

        fn onWant(self: *Self, payload: []const u8) !void {
            if (payload.len != 16) return error.Malformed;
            const origin = std.mem.readInt(u64, payload[0..8], .little);
            const from = std.mem.readInt(u64, payload[8..16], .little);
            if (origin != self.tl.replicaId()) return; // only our own envelopes are here
            if (from > self.tl.seq) return; // nothing they miss
            const oldest: ?u64 = if (self.retained.items.len > 0) self.retained.items[0].seq else null;
            if (oldest == null or oldest.? > from) {
                // Too far back to replay: send everything instead.
                try self.sendSnapshot();
                return;
            }
            for (self.retained.items) |r| {
                if (r.seq >= from) {
                    try self.queue(.envelope, r.bytes);
                    self.stats.replayed += 1;
                }
            }
        }

        fn sendSnapshot(self: *Self) !void {
            var aw: std.Io.Writer.Allocating = .init(self.gpa);
            defer aw.deinit();
            try aw.writer.writeInt(u64, self.tl.seq, .little);
            try persistence.save(Domain, self.tl, self.gpa, &aw.writer);
            try self.queue(.snapshot, aw.written());
            self.stats.snapshots_sent += 1;
        }

        /// Adopt the peer's state. Our timeline is replaced in place: local
        /// edits the peer never saw are gone. We keep our replica id and
        /// sequence, so the peer keeps tracking us, and we note where the
        /// peer's own sequence stood when it took the snapshot.
        fn onSnapshot(self: *Self, payload: []const u8) !void {
            if (payload.len < 8) return error.Malformed;
            const sender_seq = std.mem.readInt(u64, payload[0..8], .little);
            var reader = std.Io.Reader.fixed(payload[8..]);
            var loaded = try persistence.load(Domain, self.gpa, self.tl.config, &reader);
            loaded.replica_id = self.tl.replica_id;
            loaded.seq = self.tl.seq;
            if (self.peer) |peer| loaded.acknowledge(peer, sender_seq) catch {
                loaded.deinit();
                return error.OutOfMemory;
            };
            self.tl.deinit();
            self.tl.* = loaded;
            // Our old envelopes describe a state that no longer exists.
            self.clearRetained();
            self.clearPending();
            self.want_outstanding = false;
            self.attach();
            self.stats.snapshots_loaded += 1;
            if (self.on_replaced) |cb| cb.func(cb.ctx, self.tl);
            try self.queueState();
        }
    };
}
