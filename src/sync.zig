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
/// newer peer migrates older ops through `Domain.migrateOp`).
pub const wire_version: u8 = 3;

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
    try Domain.encodeOp(op, &aw.writer);
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
    }
}

fn readChapterFixes(gpa: std.mem.Allocator, r: *std.Io.Reader) ![]annotations.ChapterFix {
    const n = try r.takeInt(u32, .little);
    const out = try gpa.alloc(annotations.ChapterFix, n);
    var filled: usize = 0;
    errdefer {
        gpa.free(out[0..filled]);
        gpa.free(out);
    }
    for (out) |*f| {
        f.chapter_id = try r.takeInt(u64, .little);
        const after = try r.takeInt(u64, .little);
        f.old_mark = .{ .after = if (after == 0) null else after };
        filled += 1;
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
    var filled: usize = 0;
    errdefer {
        gpa.free(out[0..filled]);
        gpa.free(out);
    }
    for (out) |*f| {
        f.group_id = try r.takeInt(u64, .little);
        f.old_first = try r.takeInt(u64, .little);
        f.old_last = try r.takeInt(u64, .little);
        f.new_first = try r.takeInt(u64, .little);
        f.new_last = try r.takeInt(u64, .little);
        filled += 1;
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

/// Serialize one journal entry. Requires the Domain persistence codecs.
pub fn encode(
    comptime Domain: type,
    entry: *const journaling.Journal(Domain.Op).Entry,
    gpa: std.mem.Allocator,
    w: *std.Io.Writer,
) !void {
    try w.writeAll(&[1]u8{wire_version});
    try w.writeInt(u32, persistence.formatVersion(Domain), .little);
    switch (entry.*) {
        .commit => |e| {
            try w.writeAll(&[1]u8{1});
            try w.writeInt(u64, e.id, .little);
            try writeFramedOp(Domain, e.op, gpa, w);
            try w.writeInt(u32, e.at, .little);
            try writeMeta(w, e.meta);
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
            try writeTags(w, e.tags);
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
            try writeFramed(w, e.tag);
        },
        .tag_remove => |e| {
            try w.writeAll(&[1]u8{8});
            try w.writeInt(u64, e.id, .little);
            try writeFramed(w, e.tag);
        },
        .chapter_add => |e| {
            try w.writeAll(&[1]u8{9});
            try w.writeInt(u64, e.chapter.id, .little);
            try w.writeInt(u64, e.chapter.mark.after orelse 0, .little);
            try writeFramed(w, e.chapter.name);
        },
        .chapter_remove => |e| {
            try w.writeAll(&[1]u8{10});
            try w.writeInt(u64, e.chapter.id, .little);
            try w.writeInt(u64, e.chapter.mark.after orelse 0, .little);
            try writeFramed(w, e.chapter.name);
        },
        .chapter_rename => |e| {
            try w.writeAll(&[1]u8{11});
            try w.writeInt(u64, e.id, .little);
            try writeFramed(w, e.old);
            try writeFramed(w, e.new);
        },
        .group_add => |e| {
            try w.writeAll(&[1]u8{12});
            try w.writeInt(u64, e.group.id, .little);
            try w.writeInt(u64, e.group.first, .little);
            try w.writeInt(u64, e.group.last, .little);
            try writeFramed(w, e.group.name);
        },
        .group_remove => |e| {
            try w.writeAll(&[1]u8{13});
            try w.writeInt(u64, e.group.id, .little);
            try w.writeInt(u64, e.group.first, .little);
            try w.writeInt(u64, e.group.last, .little);
            try writeFramed(w, e.group.name);
        },
        .group_rename => |e| {
            try w.writeAll(&[1]u8{14});
            try w.writeInt(u64, e.id, .little);
            try writeFramed(w, e.old);
            try writeFramed(w, e.new);
        },
        .param_add => |e| {
            try w.writeAll(&[1]u8{15});
            try w.writeInt(u64, e.id, .little);
            try writeFramed(w, e.name);
            try w.writeInt(u64, @bitCast(e.value), .little);
        },
        .param_remove => |e| {
            try w.writeAll(&[1]u8{16});
            try w.writeInt(u64, e.id, .little);
            try writeFramed(w, e.name);
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
            try writeFramed(w, e.old);
            try writeFramed(w, e.new);
        },
    }
}

/// Deserialize an owned entry (strings and slices allocated from `gpa`);
/// free it with `deinit` after use. Entries written by another
/// `wire_version` are rejected with `error.UnsupportedWireVersion`.
pub fn decode(
    comptime Domain: type,
    gpa: std.mem.Allocator,
    r: *std.Io.Reader,
) !journaling.Journal(Domain.Op).Entry {
    const version = (try r.take(1))[0];
    if (version != wire_version) return error.UnsupportedWireVersion;
    const stored_format = try r.takeInt(u32, .little);
    const tag = (try r.take(1))[0];
    switch (tag) {
        1 => return .{ .commit = .{
            .id = try r.takeInt(u64, .little),
            .op = try readOp(Domain, gpa, r, stored_format),
            .at = try r.takeInt(u32, .little),
            .meta = try readMeta(r),
        } },
        2 => return .{ .edit = .{
            .id = try r.takeInt(u64, .little),
            .old_op = try readOp(Domain, gpa, r, stored_format),
            .new_op = try readOp(Domain, gpa, r, stored_format),
        } },
        3 => return .{ .remove = .{
            .id = try r.takeInt(u64, .little),
            .op = try readOp(Domain, gpa, r, stored_format),
            .at = try r.takeInt(u32, .little),
            .suppressed = (try r.take(1))[0] != 0,
            .marker_pre = try r.takeInt(u32, .little),
            .name = try readOptString(gpa, r),
            .meta = try readMeta(r),
            .chapter_fixes = try readChapterFixes(gpa, r),
            .tags = try readTags(gpa, r),
            .group_fixes = try readGroupFixes(gpa, r),
        } },
        4 => return .{ .suppress = .{
            .id = try r.takeInt(u64, .little),
            .prev = (try r.take(1))[0] != 0,
        } },
        5 => return .{ .move = .{
            .id = try r.takeInt(u64, .little),
            .from = try r.takeInt(u32, .little),
            .to = try r.takeInt(u32, .little),
            .marker_pre = try r.takeInt(u32, .little),
            .group_fixes = try readGroupFixes(gpa, r),
        } },
        6 => return .{ .name_set = .{
            .id = try r.takeInt(u64, .little),
            .old = try readOptString(gpa, r),
            .new = try readOptString(gpa, r),
        } },
        7 => return .{ .tag_add = .{
            .id = try r.takeInt(u64, .little),
            .tag = try readString(gpa, r),
        } },
        8 => return .{ .tag_remove = .{
            .id = try r.takeInt(u64, .little),
            .tag = try readString(gpa, r),
        } },
        9 => return .{ .chapter_add = .{
            .chapter = try readChapter(gpa, r),
        } },
        10 => return .{ .chapter_remove = .{
            .chapter = try readChapter(gpa, r),
        } },
        11 => return .{ .chapter_rename = .{
            .id = try r.takeInt(u64, .little),
            .old = try readString(gpa, r),
            .new = try readString(gpa, r),
        } },
        12 => return .{ .group_add = .{
            .group = try readGroup(gpa, r),
        } },
        13 => return .{ .group_remove = .{
            .group = try readGroup(gpa, r),
        } },
        14 => return .{ .group_rename = .{
            .id = try r.takeInt(u64, .little),
            .old = try readString(gpa, r),
            .new = try readString(gpa, r),
        } },
        15 => return .{ .param_add = .{
            .id = try r.takeInt(u64, .little),
            .name = try readString(gpa, r),
            .value = @bitCast(try r.takeInt(u64, .little)),
        } },
        16 => return .{ .param_remove = .{
            .id = try r.takeInt(u64, .little),
            .name = try readString(gpa, r),
            .value = @bitCast(try r.takeInt(u64, .little)),
        } },
        17 => return .{ .param_set = .{
            .id = try r.takeInt(u64, .little),
            .old = @bitCast(try r.takeInt(u64, .little)),
            .new = @bitCast(try r.takeInt(u64, .little)),
        } },
        18 => return .{ .param_rename = .{
            .id = try r.takeInt(u64, .little),
            .old = try readString(gpa, r),
            .new = try readString(gpa, r),
        } },
        else => return error.BadEntryTag,
    }
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

/// Free an entry produced by `decode` (and any owned memory inside).
pub fn deinit(comptime Op: type, gpa: std.mem.Allocator, entry: *journaling.Journal(Op).Entry) void {
    switch (entry.*) {
        .remove => |*e| {
            if (e.name) |n| gpa.free(n);
            gpa.free(e.chapter_fixes);
            for (e.tags) |t| gpa.free(@constCast(t));
            gpa.free(e.tags);
            gpa.free(e.group_fixes);
        },
        .move => |*e| gpa.free(e.group_fixes),
        .name_set => |*e| {
            if (e.old) |o| gpa.free(o);
            if (e.new) |n| gpa.free(n);
        },
        .tag_add => |*e| gpa.free(e.tag),
        .tag_remove => |*e| gpa.free(e.tag),
        .chapter_add => |*e| gpa.free(e.chapter.name),
        .chapter_remove => |*e| gpa.free(e.chapter.name),
        .chapter_rename => |*e| {
            gpa.free(e.old);
            gpa.free(e.new);
        },
        .group_add => |*e| gpa.free(e.group.name),
        .group_remove => |*e| gpa.free(e.group.name),
        .group_rename => |*e| {
            gpa.free(e.old);
            gpa.free(e.new);
        },
        .param_add => |*e| gpa.free(e.name),
        .param_remove => |*e| gpa.free(e.name),
        .param_rename => |*e| {
            gpa.free(e.old);
            gpa.free(e.new);
        },
        else => {},
    }
}
