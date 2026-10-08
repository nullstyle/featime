//! Differential testing: the real `Timeline` (checkpoint cache, incremental
//! forward replay, exact restores, lazy rebuilds, id-anchored annotations)
//! versus a naive reference that re-clones the seed and replays from scratch
//! after every step.
//!
//! Random operation sequences (deterministic seeds, varying configs) must
//! produce identical documents, markers, per-feature statuses, names, tags,
//! chapters, groups, and parameters after every single step. This is the
//! primary regression net for invalidation and journal bugs.
//!
//! The naive model mirrors the library's *semantics* with the dumbest
//! possible representation: annotations anchored by index and shifted by
//! hand on every structural change, an independent undo log, and a full
//! replay from the seed for every document read.

const std = @import("std");
const ft = @import("featuretree_zig");

const Domain = struct {
    pub const Doc = struct {
        value: i64 = 0,
        trace: std.ArrayList(u8) = .empty,
    };
    pub const Op = union(enum) {
        add: i32,
        mul: i32,
        fail: i32,
        scale_by_param: ft.ParamId,
    };
    pub fn apply(op: Op, doc: *Doc, ctx: *ft.ApplyContext) anyerror!void {
        switch (op) {
            .add => |n| {
                doc.value = std.math.add(i64, doc.value, n) catch
                    return ctx.fail("overflow", .{});
                try doc.trace.append(ctx.alloc, '+');
            },
            .mul => |n| {
                doc.value = std.math.mul(i64, doc.value, n) catch
                    return ctx.fail("overflow", .{});
                try doc.trace.append(ctx.alloc, '*');
            },
            .fail => |n| return ctx.fail("fail {d}", .{n}),
            .scale_by_param => |pid| {
                const v = ctx.param(pid) orelse
                    return ctx.fail("missing parameter", .{});
                const scaled = @round(@as(f64, @floatFromInt(doc.value)) * v);
                doc.value = @intFromFloat(scaled);
                try doc.trace.append(ctx.alloc, 's');
            },
        }
    }
    pub fn references(op: Op, out: *ft.ParamRefCollector) void {
        switch (op) {
            .scale_by_param => |pid| out.param(pid),
            else => {},
        }
    }

    pub fn cloneDoc(doc: *const Doc, gpa: std.mem.Allocator) anyerror!Doc {
        return .{ .value = doc.value, .trace = try doc.trace.clone(gpa) };
    }
    pub fn deinitDoc(doc: *Doc, gpa: std.mem.Allocator) void {
        doc.trace.deinit(gpa);
    }
};

const Timeline = ft.Timeline(Domain);
const NaiveFeature = ft.Feature(Domain.Op);

/// One chapter re-anchor caused by removing its anchor feature.
const NChapterFix = struct { pos: usize, old_after: ?u32 };

/// One group boundary change caused by a member leaving (remove or move).
const NGroupFix = struct {
    pos: usize,
    old_first: ?u32,
    old_last: ?u32,
    new_first: ?u32,
    new_last: ?u32,
};

/// The naive model's own undo log — an independent reimplementation of the
/// journal semantics (insert-at-marker, marker restore, redo truncation,
/// exact annotation restores).
const NaiveEntry = union(enum) {
    commit: struct { idx: u32, op: Domain.Op },
    edit: struct { idx: u32, old: Domain.Op, new: Domain.Op },
    remove: struct {
        idx: u32,
        op: Domain.Op,
        suppressed: bool,
        marker_pre: u32,
        name: ?[]u8,
        tags: [][]u8,
        chapter_fixes: []NChapterFix,
        group_fixes: []NGroupFix,
    },
    tag_add: struct { idx: u32, tag: []u8 },
    tag_remove: struct { idx: u32, tag: []u8 },
    param_add: struct { id: u64, name: []const u8, value: f64 },
    param_remove: struct { id: u64, name: []const u8, value: f64 },
    param_set: struct { id: u64, old: f64, new: f64 },
    group_add: struct { pos: usize, name: []u8, first: ?u32, last: ?u32 },
    group_remove: struct { pos: usize, name: []u8, first: ?u32, last: ?u32 },
    group_rename: struct { pos: usize, old: []u8, new: []u8 },
    suppress: struct { idx: u32, prev: bool },
    move: struct { idx: u32, to: u32, marker_pre: u32, group_fixes: []NGroupFix },
    name_set: struct { idx: u32, old: ?[]u8, new: ?[]u8 },
    chapter_add: struct { pos: usize, name: []u8, after: ?u32 },
    chapter_remove: struct { pos: usize, name: []u8, after: ?u32 },
    chapter_rename: struct { pos: usize, old: []u8, new: []u8 },
};

const NaiveChapter = struct {
    name: []u8,
    /// Index of the anchor feature; null = end-pinned.
    after: ?u32,
};

const NaiveGroup = struct {
    name: []u8,
    /// Anchor indices; null = dead anchor (empty folder).
    first: ?u32,
    last: ?u32,
};

/// The reference model: no caching, no incremental anything. Mirrors the
/// timeline's structural semantics (insert-at-marker, marker/mutation index
/// adjustments, positional folders) and recomputes by replay from the seed.
const Naive = struct {
    const NaiveRecord = struct {
        e: NaiveEntry,
        txn_start: bool = false,
    };

    gpa: std.mem.Allocator,
    features: std.ArrayList(NaiveFeature) = .empty,
    marker: u32 = 0,
    log: std.ArrayList(NaiveRecord) = .empty,
    log_head: usize = 0,
    journal_max: u32,
    txn_depth: u32 = 0,
    txn_pending: bool = false,
    unit_done: bool = false,
    /// Per-index display names (index-mirrored; strings owned).
    names: std.ArrayList(?[]u8) = .empty,
    chapters: std.ArrayList(NaiveChapter) = .empty,
    /// Per-index tags (index-mirrored; strings owned).
    tag_lists: std.ArrayList(std.ArrayList([]u8)) = .empty,
    /// Parameter mirror (same ids as the real timeline; names borrowed
    /// from static driver strings).
    param_mirror: std.ArrayList(ft.Param) = .empty,
    groups: std.ArrayList(NaiveGroup) = .empty,

    fn deinit(self: *Naive) void {
        for (self.features.items) |*f| self.freeStatus(f);
        self.features.deinit(self.gpa);
        for (self.log.items) |*r| self.deinitEntry(&r.e);
        self.log.deinit(self.gpa);
        for (self.names.items) |n| {
            if (n) |owned| self.gpa.free(owned);
        }
        self.names.deinit(self.gpa);
        for (self.tag_lists.items) |*list| {
            for (list.items) |t| self.gpa.free(t);
            list.deinit(self.gpa);
        }
        self.tag_lists.deinit(self.gpa);
        self.param_mirror.deinit(self.gpa);
        for (self.groups.items) |*g| self.gpa.free(g.name);
        self.groups.deinit(self.gpa);
        for (self.chapters.items) |*c| self.gpa.free(c.name);
        self.chapters.deinit(self.gpa);
    }

    fn freeStatus(self: *Naive, f: *NaiveFeature) void {
        switch (f.status) {
            .failed => |msg| self.gpa.free(msg),
            else => {},
        }
        f.status = .pending;
    }

    fn deinitEntry(self: *Naive, e: *NaiveEntry) void {
        switch (e.*) {
            .name_set => |n| {
                if (n.old) |o| self.gpa.free(o);
                if (n.new) |x| self.gpa.free(x);
            },
            .chapter_add => |c| self.gpa.free(c.name),
            .chapter_remove => |c| self.gpa.free(c.name),
            .chapter_rename => |c| {
                self.gpa.free(c.old);
                self.gpa.free(c.new);
            },
            .remove => |r| {
                if (r.name) |n| self.gpa.free(n);
                for (r.tags) |t| self.gpa.free(t);
                self.gpa.free(r.tags);
                self.gpa.free(r.chapter_fixes);
                self.gpa.free(r.group_fixes);
            },
            .move => |m| self.gpa.free(m.group_fixes),
            .tag_add => |t| self.gpa.free(t.tag),
            .tag_remove => |t| self.gpa.free(t.tag),
            .group_add => |g| self.gpa.free(g.name),
            .group_remove => |g| self.gpa.free(g.name),
            .group_rename => |g| {
                self.gpa.free(g.old);
                self.gpa.free(g.new);
            },
            .param_add, .param_remove, .param_set => {},
            .commit, .edit, .suppress => {},
        }
    }

    // -- structural edits ----------------------------------------------------

    fn commit(self: *Naive, op: Domain.Op) !void {
        try self.features.insert(self.gpa, self.marker, .{ .id = 0, .op = op });
        try self.names.insert(self.gpa, self.marker, null);
        try self.tag_lists.insert(self.gpa, self.marker, .empty);
        self.shiftChapterAnchors(.insert, self.marker);
        self.shiftGroupAnchors(.insert, self.marker);
        for (self.features.items[self.marker + 1 ..]) |*f| self.freeStatus(f);
        self.record(.{ .commit = .{ .idx = self.marker, .op = op } });
        self.marker += 1;
    }

    fn setMarker(self: *Naive, pos: u32) void {
        self.marker = @min(pos, self.features.items.len);
    }

    fn edit(self: *Naive, idx: u32, op: Domain.Op) void {
        const old = self.features.items[idx].op;
        self.features.items[idx].op = op;
        for (self.features.items[idx..]) |*f| self.freeStatus(f);
        self.record(.{ .edit = .{ .idx = idx, .old = old, .new = op } });
    }

    fn freeTagListAt(self: *Naive, idx: u32) void {
        const list = &self.tag_lists.items[idx];
        for (list.items) |t| self.gpa.free(t);
        list.clearRetainingCapacity();
        list.deinit(self.gpa);
    }

    fn remove(self: *Naive, idx: u32) !void {
        const f = self.features.items[idx];
        const owned_name = self.names.orderedRemove(idx); // moves to the entry
        const owned_tags: [][]u8 = self.tag_lists.items[idx].toOwnedSlice(self.gpa) catch &.{};
        _ = self.tag_lists.orderedRemove(idx); // keep index-aligned with features
        const chapter_fixes = try self.removeChapterAnchors(idx);
        errdefer self.gpa.free(chapter_fixes);
        const group_fixes = try self.leaveGroupAnchors(idx, null);
        self.record(.{ .remove = .{
            .idx = idx,
            .op = f.op,
            .suppressed = f.suppressed,
            .marker_pre = self.marker,
            .name = owned_name,
            .tags = owned_tags,
            .chapter_fixes = chapter_fixes,
            .group_fixes = group_fixes,
        } });
        for (self.features.items[idx..]) |*f2| self.freeStatus(f2);
        _ = self.features.orderedRemove(idx);
        if (idx < self.marker) self.marker -= 1;
    }

    fn toggleSuppress(self: *Naive, idx: u32) void {
        const prev = self.features.items[idx].suppressed;
        self.features.items[idx].suppressed = !prev;
        for (self.features.items[idx..]) |*f| self.freeStatus(f);
        self.record(.{ .suppress = .{ .idx = idx, .prev = prev } });
    }

    fn move(self: *Naive, idx: u32, to: u32) !void {
        const to_c = @min(to, @as(u32, @intCast(self.features.items.len - 1)));
        if (idx == to_c) return;
        const marker_pre = self.marker;
        const fixes = try self.moveFeature(idx, to_c, null);
        self.record(.{ .move = .{ .idx = idx, .to = to_c, .marker_pre = marker_pre, .group_fixes = fixes } });
    }

    // -- index bookkeeping for anchors ---------------------------------------

    const ShiftKind = enum { insert, remove };

    /// Where index `i` (not the moved element) lands after the element at
    /// `idx` is taken out and re-inserted at `to_c`.
    fn shiftIndex(i: u32, idx: u32, to_c: u32) u32 {
        var j = i;
        if (i > idx) j -= 1;
        if (j >= to_c) j += 1;
        return j;
    }

    /// Mirror feature-pinned marks across an insert: an anchor at or after
    /// the insertion point moves right.
    fn shiftChapterAnchors(self: *Naive, kind: ShiftKind, at: u32) void {
        std.debug.assert(kind == .insert);
        for (self.chapters.items) |*c| {
            const i = c.after orelse continue; // end-pinned tracks the tip
            if (at <= i) c.after = i + 1;
        }
    }

    /// Remove-time chapter rule: a mark anchored at the removed feature
    /// re-anchors to the successor-in-place (or end-pins when it was last);
    /// later anchors shift left. Returns the exact-undo snapshots.
    fn removeChapterAnchors(self: *Naive, at: u32) ![]NChapterFix {
        var fixes: std.ArrayList(NChapterFix) = .empty;
        errdefer fixes.deinit(self.gpa);
        const new_len: u32 = @intCast(self.features.items.len - 1);
        for (self.chapters.items, 0..) |*c, pos| {
            const i = c.after orelse continue;
            if (i == at) {
                try fixes.append(self.gpa, .{ .pos = pos, .old_after = i });
                c.after = if (at < new_len) at else null;
            } else if (i > at) {
                c.after = i - 1;
            }
        }
        return fixes.toOwnedSlice(self.gpa);
    }

    fn shiftGroupAnchors(self: *Naive, kind: ShiftKind, at: u32) void {
        std.debug.assert(kind == .insert);
        for (self.groups.items) |*g| {
            const f = g.first orelse continue;
            const l = g.last orelse continue;
            if (at <= f) g.first = f + 1;
            if (at <= l) g.last = l + 1;
        }
    }

    /// Boundary rule when the member at `idx` leaves (removed, or about to be
    /// moved): the second member becomes first, the predecessor becomes
    /// last; a one-member folder's anchors go dead on removal (null) and
    /// follow the member on a move (handled by `rawMoveFeature`). `exempt`
    /// is the folder `moveGroupAt` is relocating. Other anchors after `idx`
    /// shift left only for a removal (`removing`). Returns exact snapshots
    /// of every boundary that changed.
    fn leaveGroupAnchors(self: *Naive, idx: u32, exempt: ?usize) ![]NGroupFix {
        return self.leaveGroupAnchorsInner(idx, exempt, true, 0);
    }

    fn leaveGroupAnchorsInner(self: *Naive, idx: u32, exempt: ?usize, removing: bool, to_c: u32) ![]NGroupFix {
        var fixes: std.ArrayList(NGroupFix) = .empty;
        errdefer fixes.deinit(self.gpa);
        for (self.groups.items, 0..) |*g, pos| {
            if (exempt != null and exempt.? == pos) continue;
            const f = g.first orelse continue;
            const l = g.last orelse continue;
            if (f > l) continue;
            const touches = f == idx or l == idx;
            if (!touches) {
                if (removing) {
                    if (f > idx) g.first = f - 1;
                    if (l > idx) g.last = l - 1;
                }
                continue;
            }
            if (f == l) {
                // One-member folder: dead on removal, travels on a move.
                if (removing) {
                    try fixes.append(self.gpa, .{ .pos = pos, .old_first = f, .old_last = l, .new_first = null, .new_last = null });
                    g.first = null;
                    g.last = null;
                }
                continue;
            }
            var new_first: u32 = f;
            var new_last: u32 = l;
            if (removing) {
                if (f == idx) new_first = f; // successor slides into f
                if (l == idx) new_last = l - 1; // predecessor stays put
                if (f != idx and f > idx) new_first = f - 1;
                if (l != idx and l > idx) new_last = l - 1;
            } else {
                new_first = if (f == idx) shiftIndex(idx + 1, idx, to_c) else shiftIndex(f, idx, to_c);
                new_last = if (l == idx) shiftIndex(idx - 1, idx, to_c) else shiftIndex(l, idx, to_c);
            }
            try fixes.append(self.gpa, .{ .pos = pos, .old_first = f, .old_last = l, .new_first = new_first, .new_last = new_last });
            if (removing) {
                g.first = new_first;
                g.last = new_last;
            }
        }
        return fixes.toOwnedSlice(self.gpa);
    }

    const Which = enum { old, new };

    fn applyGroupFixes(self: *Naive, fixes: []const NGroupFix, which: Which) void {
        for (fixes) |fx| {
            const g = &self.groups.items[fx.pos];
            switch (which) {
                .old => {
                    g.first = fx.old_first;
                    g.last = fx.old_last;
                },
                .new => {
                    g.first = fx.new_first;
                    g.last = fx.new_last;
                },
            }
        }
    }

    /// Pure positional relocation: lists move, chapters anchored to the
    /// moved feature follow it, group anchors on it follow it, everything
    /// else shifts by index. Mirrors the real model's id-anchored `rawMove`.
    fn rawMoveFeature(self: *Naive, idx: u32, to_c: u32) void {
        if (idx == to_c) return;
        const lo = @min(idx, to_c);
        for (self.features.items[lo..]) |*f| self.freeStatus(f);
        const f = self.features.orderedRemove(idx);
        self.features.insert(self.gpa, to_c, f) catch unreachable;
        const n = self.names.orderedRemove(idx);
        self.names.insert(self.gpa, to_c, n) catch unreachable;
        const tags_moved = self.tag_lists.orderedRemove(idx);
        self.tag_lists.insert(self.gpa, to_c, tags_moved) catch unreachable;
        for (self.chapters.items) |*c| {
            const i = c.after orelse continue;
            c.after = if (i == idx) to_c else shiftIndex(i, idx, to_c);
        }
        for (self.groups.items) |*g| {
            if (g.first) |gf| g.first = if (gf == idx) to_c else shiftIndex(gf, idx, to_c);
            if (g.last) |gl| g.last = if (gl == idx) to_c else shiftIndex(gl, idx, to_c);
        }
        if (idx < self.marker and to_c >= self.marker) {
            self.marker -= 1;
        } else if (idx >= self.marker and to_c < self.marker) {
            self.marker += 1;
        }
    }

    /// A user-level move: boundary members leaving a folder re-anchor it
    /// (except the `exempt` folder being relocated as a block), then the
    /// raw relocation. Returns the snapshots for exact undo/redo.
    fn moveFeature(self: *Naive, idx: u32, to_c: u32, exempt: ?usize) ![]NGroupFix {
        const fixes = try self.leaveGroupAnchorsInner(idx, exempt, false, to_c);
        self.rawMoveFeature(idx, to_c);
        self.applyGroupFixes(fixes, .new);
        return fixes;
    }

    // -- names, tags ------------------------------------------------------------

    fn addTagRaw(self: *Naive, idx: u32, tag: []const u8) void {
        const list = &self.tag_lists.items[idx];
        for (list.items) |t| {
            if (std.mem.eql(u8, t, tag)) return;
        }
        const stored = self.gpa.dupe(u8, tag) catch return;
        list.append(self.gpa, stored) catch self.gpa.free(stored);
    }

    fn removeTagRaw(self: *Naive, idx: u32, tag: []const u8) void {
        const list = &self.tag_lists.items[idx];
        for (list.items, 0..) |t, i| {
            if (std.mem.eql(u8, t, tag)) {
                const dead = list.orderedRemove(i);
                self.gpa.free(dead);
                return;
            }
        }
    }

    /// Set a name by index without journaling (journal handlers).
    fn setNameRaw(self: *Naive, idx: u32, new: ?[]const u8) void {
        if (self.names.items[idx]) |owned| self.gpa.free(owned);
        self.names.items[idx] = if (new) |n| (self.gpa.dupe(u8, n) catch null) else null;
    }

    fn setName(self: *Naive, idx: u32, new: ?[]const u8) !void {
        // Storage and journal entry each own their own copy.
        const stored: ?[]u8 = if (new) |n| try self.gpa.dupe(u8, n) else null;
        errdefer if (stored) |x| self.gpa.free(x);
        const old = self.names.items[idx];
        const old_copy: ?[]u8 = if (old) |o| try self.gpa.dupe(u8, o) else null;
        errdefer if (old_copy) |o| self.gpa.free(o);
        const new_copy: ?[]u8 = if (new) |n| try self.gpa.dupe(u8, n) else null;
        errdefer if (new_copy) |n| self.gpa.free(n);
        if (old) |o| self.gpa.free(o);
        self.names.items[idx] = stored;
        self.record(.{ .name_set = .{ .idx = idx, .old = old_copy, .new = new_copy } });
    }

    fn addTag(self: *Naive, idx: u32, tag: []const u8) !void {
        const list = &self.tag_lists.items[idx];
        for (list.items) |t| {
            if (std.mem.eql(u8, t, tag)) return; // set semantics
        }
        const stored = try self.gpa.dupe(u8, tag);
        errdefer self.gpa.free(stored);
        const entry_tag = try self.gpa.dupe(u8, tag);
        errdefer self.gpa.free(entry_tag);
        try list.append(self.gpa, stored);
        self.record(.{ .tag_add = .{ .idx = idx, .tag = entry_tag } });
    }

    fn removeTag(self: *Naive, idx: u32, tag: []const u8) void {
        const list = &self.tag_lists.items[idx];
        for (list.items, 0..) |t, i| {
            if (std.mem.eql(u8, t, tag)) {
                const dead = list.orderedRemove(i);
                const entry_tag = self.gpa.dupe(u8, dead) catch {
                    self.gpa.free(dead);
                    return;
                };
                self.gpa.free(dead);
                self.record(.{ .tag_remove = .{ .idx = idx, .tag = entry_tag } });
                return;
            }
        }
    }

    // -- chapters ---------------------------------------------------------------

    fn addChapter(self: *Naive, name: []const u8, after: ?u32) !void {
        const owned = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned);
        try self.chapters.append(self.gpa, .{ .name = owned, .after = after });
        self.record(.{ .chapter_add = .{
            .pos = self.chapters.items.len - 1,
            .name = try self.gpa.dupe(u8, name),
            .after = after,
        } });
    }

    fn removeChapterAt(self: *Naive, pos: usize) void {
        const dead = self.chapters.orderedRemove(pos);
        self.record(.{ .chapter_remove = .{
            .pos = pos,
            .name = dead.name,
            .after = dead.after,
        } });
    }

    fn renameChapterAt(self: *Naive, pos: usize, new: []const u8) !void {
        const c = &self.chapters.items[pos];
        const stored = try self.gpa.dupe(u8, new);
        errdefer self.gpa.free(stored);
        const old_copy = try self.gpa.dupe(u8, c.name);
        errdefer self.gpa.free(old_copy);
        const new_copy = try self.gpa.dupe(u8, new);
        errdefer self.gpa.free(new_copy);
        self.gpa.free(c.name);
        c.name = stored;
        self.record(.{ .chapter_rename = .{ .pos = pos, .old = old_copy, .new = new_copy } });
    }

    // -- groups -------------------------------------------------------------------

    fn addGroup(self: *Naive, name: []const u8, first: ?u32, last: ?u32) !void {
        const owned = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned);
        const entry_name = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(entry_name);
        try self.groups.append(self.gpa, .{ .name = owned, .first = first, .last = last });
        self.record(.{ .group_add = .{
            .pos = self.groups.items.len - 1,
            .name = entry_name,
            .first = first,
            .last = last,
        } });
    }

    fn removeGroupAt(self: *Naive, pos: usize) void {
        const dead = self.groups.orderedRemove(pos);
        self.record(.{ .group_remove = .{
            .pos = pos,
            .name = dead.name,
            .first = dead.first,
            .last = dead.last,
        } });
    }

    fn renameGroupAt(self: *Naive, pos: usize, new: []const u8) !void {
        const g = &self.groups.items[pos];
        const stored = try self.gpa.dupe(u8, new);
        errdefer self.gpa.free(stored);
        const old_copy = try self.gpa.dupe(u8, g.name);
        errdefer self.gpa.free(old_copy);
        const new_copy = try self.gpa.dupe(u8, new);
        errdefer self.gpa.free(new_copy);
        self.gpa.free(g.name);
        g.name = stored;
        self.record(.{ .group_rename = .{ .pos = pos, .old = old_copy, .new = new_copy } });
    }

    const Span = struct { lo: u32, hi: u32 };

    fn groupSpanLive(self: *const Naive, pos: usize) ?Span {
        const g = self.groups.items[pos];
        const f = g.first orelse return null;
        const l = g.last orelse return null;
        if (f > l) return null;
        return .{ .lo = f, .hi = l };
    }

    fn groupOrdinalAt(self: *const Naive, i: u32) ?usize {
        for (self.groups.items, 0..) |_, gi| {
            const span = self.groupSpanLive(gi) orelse continue;
            if (i >= span.lo and i <= span.hi) return gi;
        }
        return null;
    }

    fn setGroupSuppressedAt(self: *Naive, pos: usize, target: bool) void {
        const span = self.groupSpanLive(pos) orelse return;
        self.beginTxn();
        defer self.endTxn();
        var i = span.lo;
        while (i <= span.hi) : (i += 1) {
            const f = self.features.items[i];
            if (f.suppressed != target) {
                self.record(.{ .suppress = .{ .idx = i, .prev = f.suppressed } });
                self.features.items[i].suppressed = target;
                for (self.features.items[i..]) |*f2| self.freeStatus(f2);
            }
        }
    }

    /// Mirror of `Timeline.moveGroup`: members relocate one by one inside a
    /// transaction; the folder itself is exempt from boundary re-anchoring
    /// (its anchors travel with the block). Moving left, member k sits at
    /// `lo + k` and lands at `to + k`; moving right, each member sits at
    /// `lo` and lands at the block's final end.
    fn moveGroupAt(self: *Naive, pos: usize, new_pos: u32) !void {
        const span = self.groupSpanLive(pos) orelse return;
        const n: u32 = span.hi - span.lo + 1;
        const to = @min(new_pos, @as(u32, @intCast(self.features.items.len)) - n);
        if (to == span.lo) return;
        self.beginTxn();
        defer self.endTxn();
        var k: u32 = 0;
        while (k < n) : (k += 1) {
            const from: u32 = if (to < span.lo) span.lo + k else span.lo;
            const dest: u32 = if (to < span.lo) to + k else to + n - 1;
            const marker_pre = self.marker;
            const fixes = try self.moveFeature(from, dest, pos);
            self.record(.{ .move = .{ .idx = from, .to = dest, .marker_pre = marker_pre, .group_fixes = fixes } });
        }
    }

    /// Mirror of `Timeline.removeGroupContents`: remove members from the
    /// span head until the folder is empty, then remove the folder.
    fn removeGroupContentsAt(self: *Naive, pos: usize) !void {
        self.beginTxn();
        defer self.endTxn();
        while (self.groupSpanLive(pos)) |span| {
            try self.remove(span.lo);
        }
        self.removeGroupAt(pos);
    }

    // -- parameters -----------------------------------------------------------------

    fn addParamMirror(self: *Naive, id: u64, name: []const u8, value: f64) !void {
        try self.param_mirror.append(self.gpa, .{ .id = id, .name = name, .value = value });
        self.record(.{ .param_add = .{ .id = id, .name = name, .value = value } });
    }

    fn removeParamMirror(self: *Naive, id: u64) void {
        for (self.param_mirror.items, 0..) |p, i| {
            if (p.id == id) {
                const dead = self.param_mirror.orderedRemove(i);
                self.record(.{ .param_remove = .{ .id = dead.id, .name = dead.name, .value = dead.value } });
                self.invalidateParam(id);
                return;
            }
        }
    }

    fn setParamMirror(self: *Naive, id: u64, value: f64) void {
        for (self.param_mirror.items) |*p| {
            if (p.id == id) {
                if (p.value == value) return;
                const old = p.value;
                p.value = value;
                self.record(.{ .param_set = .{ .id = id, .old = old, .new = value } });
                self.invalidateParam(id);
                return;
            }
        }
    }

    /// Statuses are recomputed from scratch anyway; nothing to do beyond
    /// keeping the hook explicit for symmetry with the real model.
    fn invalidateParam(self: *Naive, id: u64) void {
        _ = self;
        _ = id;
    }

    // -- transactions -------------------------------------------------------------

    fn beginTxn(self: *Naive) void {
        if (self.txn_depth == 0) self.txn_pending = true;
        self.txn_depth += 1;
    }

    fn endTxn(self: *Naive) void {
        if (self.txn_depth == 0) return;
        self.txn_depth -= 1;
        if (self.txn_depth == 0) self.txn_pending = false;
    }

    fn record(self: *Naive, e: NaiveEntry) void {
        const starts_unit = if (self.txn_depth > 0) self.txn_pending else true;
        if (self.journal_max == 0) {
            var dead = e;
            self.deinitEntry(&dead);
            return;
        }
        self.txn_pending = false;
        for (self.log.items[self.log_head..]) |*t| self.deinitEntry(&t.e);
        self.log.shrinkRetainingCapacity(self.log_head);
        self.log.append(self.gpa, .{ .e = e, .txn_start = starts_unit }) catch {
            var dead = e;
            self.deinitEntry(&dead);
            return;
        };
        self.log_head += 1;
        self.evictWholeUnits();
    }

    fn evictWholeUnits(self: *Naive) void {
        var cut: usize = 0;
        while (self.log.items.len - cut > self.journal_max) {
            var next = cut + 1;
            while (next < self.log.items.len and !self.log.items[next].txn_start) next += 1;
            if (next >= self.log.items.len) break;
            for (self.log.items[cut..next]) |*r| self.deinitEntry(&r.e);
            cut = next;
        }
        if (cut == 0) return;
        self.log.replaceRange(self.gpa, 0, cut, &.{}) catch return;
        self.log_head -|= cut;
    }

    // -- undo / redo ----------------------------------------------------------------

    fn canUndo(self: *const Naive) bool {
        return self.log_head > 0;
    }

    fn canRedo(self: *const Naive) bool {
        return self.log_head < self.log.items.len;
    }

    fn undo(self: *Naive) bool {
        if (self.log_head == 0) return false;
        const first = self.nextUndoEntry() orelse return false;
        if (!self.undoEntry(first)) return false;
        while (!self.unit_done) {
            const e = self.nextUndoEntry() orelse break;
            if (!self.undoEntry(e)) break;
            if (self.unit_done) break;
        }
        return true;
    }

    fn nextUndoEntry(self: *Naive) ?NaiveEntry {
        if (self.log_head == 0) return null;
        self.log_head -= 1;
        const rec = self.log.items[self.log_head];
        self.unit_done = rec.txn_start;
        return rec.e;
    }

    fn undoEntry(self: *Naive, e: NaiveEntry) bool {
        switch (e) {
            .commit => |c| {
                for (self.features.items[c.idx..]) |*f| self.freeStatus(f);
                if (self.names.items[c.idx]) |owned| self.gpa.free(owned);
                _ = self.names.orderedRemove(c.idx);
                self.freeTagListAt(c.idx);
                _ = self.tag_lists.orderedRemove(c.idx);
                // No annotation can still be anchored at the un-committed
                // feature (strict LIFO), so plain index shifts suffice. The
                // rules read the pre-removal length: run them first.
                const fixes_c = self.removeChapterAnchors(c.idx) catch &.{};
                self.gpa.free(fixes_c);
                const fixes_g = self.leaveGroupAnchors(c.idx, null) catch &.{};
                self.gpa.free(fixes_g);
                _ = self.features.orderedRemove(c.idx);
                self.marker = c.idx;
            },
            .edit => |ed| {
                self.features.items[ed.idx].op = ed.old;
                for (self.features.items[ed.idx..]) |*f| self.freeStatus(f);
            },
            .remove => |r| {
                self.features.insert(self.gpa, r.idx, .{
                    .id = 0,
                    .op = r.op,
                    .suppressed = r.suppressed,
                }) catch return false;
                const restored: ?[]u8 = if (r.name) |n| (self.gpa.dupe(u8, n) catch return false) else null;
                self.names.insert(self.gpa, r.idx, restored) catch return false;
                var restored_tags: std.ArrayList([]u8) = .empty;
                for (r.tags) |t| {
                    const dt = self.gpa.dupe(u8, t) catch {
                        for (restored_tags.items) |x| self.gpa.free(x);
                        restored_tags.deinit(self.gpa);
                        return false;
                    };
                    restored_tags.append(self.gpa, dt) catch {
                        self.gpa.free(dt);
                        continue;
                    };
                }
                self.tag_lists.insert(self.gpa, r.idx, restored_tags) catch {
                    for (restored_tags.items) |x| self.gpa.free(x);
                    restored_tags.deinit(self.gpa);
                    return false;
                };
                for (self.features.items[r.idx..]) |*f| self.freeStatus(f);
                self.marker = r.marker_pre;
                // Undoing a removal shifts anchors like an insert at r.idx,
                // then the exact snapshots restore what the removal moved.
                self.shiftChapterAnchors(.insert, r.idx);
                self.shiftGroupAnchors(.insert, r.idx);
                for (r.chapter_fixes) |fx| self.chapters.items[fx.pos].after = fx.old_after;
                self.applyGroupFixes(r.group_fixes, .old);
            },
            .suppress => |s| {
                self.features.items[s.idx].suppressed = s.prev;
                for (self.features.items[s.idx..]) |*f| self.freeStatus(f);
            },
            .move => |m| {
                self.rawMoveFeature(m.to, m.idx);
                self.applyGroupFixes(m.group_fixes, .old);
                self.marker = m.marker_pre;
            },
            .name_set => |n| self.setNameRaw(n.idx, n.old),
            .tag_add => |t| self.removeTagRaw(t.idx, t.tag),
            .tag_remove => |t| self.addTagRaw(t.idx, t.tag),
            .param_add => |p| {
                for (self.param_mirror.items, 0..) |pm, i| {
                    if (pm.id == p.id) {
                        _ = self.param_mirror.orderedRemove(i);
                        break;
                    }
                }
            },
            .param_remove => |p| {
                self.param_mirror.append(self.gpa, .{ .id = p.id, .name = p.name, .value = p.value }) catch return false;
            },
            .param_set => |p| {
                for (self.param_mirror.items) |*pm| {
                    if (pm.id == p.id) pm.value = p.old;
                }
            },
            .group_add => |g| {
                const dead = self.groups.orderedRemove(g.pos);
                self.gpa.free(dead.name);
            },
            .group_remove => |g| {
                self.groups.insert(self.gpa, g.pos, .{
                    .name = self.gpa.dupe(u8, g.name) catch return false,
                    .first = g.first,
                    .last = g.last,
                }) catch return false;
            },
            .group_rename => |g| {
                const target = &self.groups.items[g.pos];
                const duped = self.gpa.dupe(u8, g.old) catch return false;
                self.gpa.free(target.name);
                target.name = duped;
            },
            .chapter_add => |c| {
                const dead = self.chapters.orderedRemove(c.pos);
                self.gpa.free(dead.name);
            },
            .chapter_remove => |c| {
                self.chapters.insert(self.gpa, c.pos, .{
                    .name = self.gpa.dupe(u8, c.name) catch return false,
                    .after = c.after,
                }) catch return false;
            },
            .chapter_rename => |c| {
                const ch = &self.chapters.items[c.pos];
                const duped = self.gpa.dupe(u8, c.old) catch return false;
                self.gpa.free(ch.name);
                ch.name = duped;
            },
        }
        return true;
    }

    fn redo(self: *Naive) bool {
        if (self.log_head >= self.log.items.len) return false;
        const first = self.nextRedoEntry() orelse return false;
        if (!self.redoEntry(first)) return false;
        while (!self.unit_done) {
            const e = self.nextRedoEntry() orelse break;
            if (!self.redoEntry(e)) break;
            if (self.unit_done) break;
        }
        return true;
    }

    fn nextRedoEntry(self: *Naive) ?NaiveEntry {
        if (self.log_head >= self.log.items.len) return null;
        const rec = self.log.items[self.log_head];
        self.log_head += 1;
        const done = self.log_head >= self.log.items.len or
            self.log.items[self.log_head].txn_start;
        self.unit_done = done;
        return rec.e;
    }

    fn redoEntry(self: *Naive, e: NaiveEntry) bool {
        switch (e) {
            .commit => |c| {
                self.features.insert(self.gpa, c.idx, .{ .id = 0, .op = c.op }) catch return false;
                self.names.insert(self.gpa, c.idx, null) catch return false;
                self.tag_lists.insert(self.gpa, c.idx, .empty) catch return false;
                self.shiftChapterAnchors(.insert, c.idx);
                self.shiftGroupAnchors(.insert, c.idx);
                for (self.features.items[c.idx + 1 ..]) |*f| self.freeStatus(f);
                self.marker = c.idx + 1;
            },
            .edit => |ed| {
                self.features.items[ed.idx].op = ed.new;
                for (self.features.items[ed.idx..]) |*f| self.freeStatus(f);
            },
            .remove => |r| {
                for (self.features.items[r.idx..]) |*f| self.freeStatus(f);
                if (self.names.items[r.idx]) |owned| self.gpa.free(owned);
                _ = self.names.orderedRemove(r.idx);
                self.freeTagListAt(r.idx);
                _ = self.tag_lists.orderedRemove(r.idx);
                // Re-run the removal rules (deterministic, same state by LIFO)
                // and then pin the recorded outcome, like the real model.
                const fixes_c = self.removeChapterAnchors(r.idx) catch &.{};
                self.gpa.free(fixes_c);
                const fixes_g = self.leaveGroupAnchors(r.idx, null) catch &.{};
                self.gpa.free(fixes_g);
                self.applyGroupFixes(r.group_fixes, .new);
                _ = self.features.orderedRemove(r.idx);
                self.marker = if (r.idx < r.marker_pre) r.marker_pre - 1 else r.marker_pre;
            },
            .suppress => |s| {
                self.features.items[s.idx].suppressed = !s.prev;
                for (self.features.items[s.idx..]) |*f| self.freeStatus(f);
            },
            .move => |m| {
                self.rawMoveFeature(m.idx, m.to);
                self.applyGroupFixes(m.group_fixes, .new);
            },
            .name_set => |n| self.setNameRaw(n.idx, n.new),
            .tag_add => |t| self.addTagRaw(t.idx, t.tag),
            .tag_remove => |t| self.removeTagRaw(t.idx, t.tag),
            .param_add => |p| {
                self.param_mirror.append(self.gpa, .{ .id = p.id, .name = p.name, .value = p.value }) catch return false;
            },
            .param_remove => |p| {
                for (self.param_mirror.items, 0..) |pm, i| {
                    if (pm.id == p.id) {
                        _ = self.param_mirror.orderedRemove(i);
                        break;
                    }
                }
            },
            .param_set => |p| {
                for (self.param_mirror.items) |*pm| {
                    if (pm.id == p.id) pm.value = p.new;
                }
            },
            .group_add => |g| {
                self.groups.insert(self.gpa, g.pos, .{
                    .name = self.gpa.dupe(u8, g.name) catch return false,
                    .first = g.first,
                    .last = g.last,
                }) catch return false;
            },
            .group_remove => |g| {
                const dead = self.groups.orderedRemove(g.pos);
                self.gpa.free(dead.name);
            },
            .group_rename => |g| {
                const target = &self.groups.items[g.pos];
                const duped = self.gpa.dupe(u8, g.new) catch return false;
                self.gpa.free(target.name);
                target.name = duped;
            },
            .chapter_add => |c| {
                self.chapters.insert(self.gpa, c.pos, .{
                    .name = self.gpa.dupe(u8, c.name) catch return false,
                    .after = c.after,
                }) catch return false;
            },
            .chapter_remove => |c| {
                const dead = self.chapters.orderedRemove(c.pos);
                self.gpa.free(dead.name);
            },
            .chapter_rename => |c| {
                const ch = &self.chapters.items[c.pos];
                const duped = self.gpa.dupe(u8, c.new) catch return false;
                self.gpa.free(ch.name);
                ch.name = duped;
            },
        }
        return true;
    }

    /// Recompute from scratch. Uses the library's own pure apply core — the
    /// code under test here is the caching, not the application loop.
    fn recompute(self: *Naive) !struct { value: i64, trace: []const u8 } {
        for (self.features.items) |*f| self.freeStatus(f);
        var doc: Domain.Doc = .{};
        var applied: u32 = 0;
        try ft.rebuild.applyRange(Domain, self.features.items, 0, self.marker, &doc, self.gpa, null, self.param_mirror.items, &applied);
        return .{ .value = doc.value, .trace = try doc.trace.toOwnedSlice(self.gpa) };
    }
};

// ---------------------------------------------------------------------------
// Driver
// ---------------------------------------------------------------------------

const chapter_names = [_][]const u8{ "intro", "mid", "end", "x" };
const group_names = [_][]const u8{ "g1", "g2", "g3" };
const param_names = [_][]const u8{ "pa", "pb", "pc" };
const param_values = [_]f64{ 0.5, 1.0, 2.0, 3.0 };
const feature_names = [_][]const u8{ "alpha", "beta", "gamma", "delta", "epsilon" };
const tag_names = [_][]const u8{ "tA", "tB", "tC", "tD" };

/// A random op; with live parameters, sometimes one that reads a parameter
/// (occasionally a stale id, which must soft-fail identically on both sides).
fn randomOp(random: std.Random, live_params: []const ft.Param) Domain.Op {
    if (live_params.len > 0 and random.uintLessThan(u8, 4) == 0) {
        if (random.uintLessThan(u8, 10) == 0) return .{ .scale_by_param = 0xDEAD_BEEF };
        return .{ .scale_by_param = live_params[random.uintLessThan(usize, live_params.len)].id };
    }
    return switch (random.uintAtMost(u3, 7)) {
        0...2 => .{ .add = @as(i32, random.uintAtMost(u8, 6)) - 3 },
        3...5 => .{ .mul = @intCast(random.uintAtMost(u8, 3)) },
        6 => .{ .fail = @intCast(random.uintAtMost(u8, 3)) },
        7 => .{ .add = @as(i32, random.uintAtMost(u8, 6)) - 3 },
    };
}

fn randomConfig(random: std.Random) ft.Config {
    return .{
        .checkpoint_interval = switch (random.uintLessThan(u2, 3)) {
            0 => 0,
            1 => 1,
            else => 3,
        },
        .max_checkpoints = switch (random.uintAtMost(u2, 3)) {
            0 => 0,
            1 => 1,
            2 => 2,
            else => 8,
        },
        .checkpoint_on_scrub = random.boolean(),
        .max_journal = switch (random.uintAtMost(u2, 3)) {
            0 => 0,
            1 => 3,
            2...3 => 1000,
        },
    };
}

/// Id of the feature at `idx`, via the public iterator.
fn idAt(tl: *Timeline, idx: u32) ft.FeatureId {
    var it = tl.features();
    var i: u32 = 0;
    while (it.next()) |f| : (i += 1) {
        if (i == idx) return f.id;
    }
    unreachable;
}

fn compare(tl: *Timeline, naive: *Naive, gpa: std.mem.Allocator) !void {
    const expect = std.testing.expect;
    const expectEqual = std.testing.expectEqual;

    try expectEqual(naive.features.items.len, tl.len());
    try expectEqual(naive.marker, tl.marker());
    try expectEqual(naive.canUndo(), tl.canUndo());
    try expectEqual(naive.canRedo(), tl.canRedo());

    const got_state = tl.state();
    const want = try naive.recompute();
    defer gpa.free(want.trace);
    try expectEqual(want.value, got_state.value);
    try std.testing.expectEqualSlices(u8, want.trace, got_state.trace.items);

    // Per-feature comparison: ops, suppression, names, tags, group
    // membership, statuses below the marker, pending at/after it.
    var it = tl.features();
    var i: u32 = 0;
    while (it.next()) |got| : (i += 1) {
        const want_f = naive.features.items[i];
        try expect(std.meta.eql(want_f.op, got.op.*));
        try expectEqual(want_f.suppressed, got.suppressed);
        const want_name = naive.names.items[i];
        if (want_name) |wn| {
            try std.testing.expectEqualStrings(wn, got.name orelse "(missing name)");
        } else {
            try expect(got.name == null);
        }
        if (naive.groupOrdinalAt(i)) |want_ordinal| {
            const gid = tl.groupOf(got.id) orelse return error.MissingGroupMembership;
            var got_ordinal: ?usize = null;
            for (tl.groups(), 0..) |g2, gi2| {
                if (g2.id == gid) got_ordinal = gi2;
            }
            try expectEqual(want_ordinal, got_ordinal.?);
        } else {
            try expect(tl.groupOf(got.id) == null);
        }
        const want_tags = naive.tag_lists.items[i].items;
        const got_tags = tl.tags(got.id);
        try expectEqual(want_tags.len, got_tags.len);
        for (want_tags, got_tags) |wt, gt| {
            try std.testing.expectEqualStrings(wt, gt);
        }
        if (i < naive.marker) {
            try expectEqual(std.meta.activeTag(want_f.status), std.meta.activeTag(got.status));
            switch (want_f.status) {
                .failed => |msg| try std.testing.expectEqualStrings(msg, got.status.failed),
                else => {},
            }
        } else {
            try expectEqual(ft.Status.pending, got.status);
        }
    }

    // Parameters: same set, order, and values.
    try expectEqual(naive.param_mirror.items.len, tl.paramsList().len);
    for (tl.paramsList(), 0..) |gp, gi| {
        const np = naive.param_mirror.items[gi];
        try expectEqual(np.id, gp.id);
        try expectEqual(np.value, gp.value);
        try std.testing.expectEqualStrings(np.name, gp.name);
    }

    // Groups: same order, names, and anchors (live spans resolve to the same
    // features; dead or empty folders on both sides).
    try expectEqual(naive.groups.items.len, tl.groups().len);
    for (naive.groups.items, 0..) |want_g, gi| {
        const got_g = tl.groups()[gi];
        try std.testing.expectEqualStrings(want_g.name, got_g.name);
        if (naive.groupSpanLive(gi)) |span| {
            try expectEqual(idAt(tl, span.lo), got_g.first);
            try expectEqual(idAt(tl, span.hi), got_g.last);
        } else {
            // Dead on the naive side: the real span must not resolve either.
            var k: u32 = 0;
            while (k < tl.len()) : (k += 1) {
                if (tl.groupOf(idAt(tl, k))) |owner| try expect(owner != got_g.id);
            }
        }
    }

    // Chapters: same order, names, and resolved positions.
    const want_chapters = naive.chapters.items;
    try expectEqual(want_chapters.len, tl.chapters().len);
    for (want_chapters, 0..) |want_c, ci| {
        const got_c = tl.chapters()[ci];
        try std.testing.expectEqualStrings(want_c.name, got_c.name);
        const want_pos: u32 = if (want_c.after) |a| a + 1 else naive_len(naive);
        try expectEqual(want_pos, tl.markPosition(got_c.mark));
        try expectEqual(want_pos, tl.chapterPosition(got_c.id).?);
    }
}

fn naive_len(naive: *const Naive) u32 {
    return @intCast(naive.features.items.len);
}

fn runSequence(seed: u64, steps: u16) !void {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var step: u16 = 0;
    var last_action: u8 = 0;
    errdefer std.debug.print("FAIL seed={d} step={d} action={d}\n", .{ seed, step, last_action });
    _ = &last_action;

    var tl = try Timeline.init(gpa, .{}, randomConfig(random));
    defer tl.deinit();
    var naive = Naive{ .gpa = gpa, .journal_max = tl.config.max_journal };
    defer naive.deinit();

    while (step < steps) : (step += 1) {
        try stepAction(&tl, &naive, random, &last_action);
        try compare(&tl, &naive, gpa);
    }
}

fn stepAction(
    tl: *Timeline,
    naive: *Naive,
    random: std.Random,
    last_action: *u8,
) !void {
    const len: u32 = @intCast(naive.features.items.len);
    // Roll an action; fall back to commit when the timeline is too short
    // for index-based ones.
    const action = if (len == 0) 0 else random.uintLessThan(u8, 120);
    last_action.* = action;
    switch (action) {
        0...29 => {
            const op = randomOp(random, tl.paramsList());
            _ = try tl.commit(op);
            try naive.commit(op);
        },
        30...33 => {
            const idx = random.uintAtMost(u32, len - 1);
            const name = feature_names[random.uintAtMost(u3, 4)];
            try tl.setFeatureName(idAt(tl, idx), name);
            try naive.setName(idx, name);
        },
        34...35 => {
            const idx = random.uintAtMost(u32, len - 1);
            if (naive.names.items[idx] != null) {
                try tl.clearFeatureName(idAt(tl, idx));
                try naive.setName(idx, null);
            }
        },
        36...37 => {
            const idx = random.uintAtMost(u32, len - 1);
            const tag = tag_names[random.uintAtMost(u2, 3)];
            try tl.addTag(idAt(tl, idx), tag);
            try naive.addTag(idx, tag);
        },
        38...39 => {
            const idx = random.uintAtMost(u32, len - 1);
            if (naive.tag_lists.items[idx].items.len > 0) {
                const pick = random.uintAtMost(usize, naive.tag_lists.items[idx].items.len - 1);
                const tag = naive.tag_lists.items[idx].items[pick];
                try tl.removeTag(idAt(tl, idx), tag);
                naive.removeTag(idx, tag);
            }
        },
        40...49 => {
            const pos = random.uintAtMost(u32, len);
            tl.setMarker(pos);
            naive.setMarker(pos);
        },
        55...64 => {
            const idx = random.uintAtMost(u32, len - 1);
            try tl.setSuppressed(idAt(tl, idx), !naive.features.items[idx].suppressed);
            naive.toggleSuppress(idx);
        },
        65...74 => {
            const idx = random.uintAtMost(u32, len - 1);
            const op = randomOp(random, tl.paramsList());
            try tl.edit(idAt(tl, idx), op);
            naive.edit(idx, op);
        },
        75...79 => {
            const idx = random.uintAtMost(u32, len - 1);
            try tl.remove(idAt(tl, idx));
            try naive.remove(idx);
        },
        80...83 => {
            try std.testing.expectEqual(naive.undo(), tl.undo());
        },
        84 => {
            // Explicit transaction: 2-4 random journaled edits grouped
            // into one undo unit on both sides.
            tl.beginTransaction();
            naive.beginTxn();
            const sub_count: u32 = 2 + @as(u32, random.uintAtMost(u2, 2));
            var sub: u32 = 0;
            while (sub < sub_count) : (sub += 1) {
                try stepAction(tl, naive, random, last_action);
            }
            tl.endTransaction();
            naive.endTxn();
        },
        85...88 => {
            try std.testing.expectEqual(naive.redo(), tl.redo());
        },
        // -- chapters ---------------------------------------------------------
        100...101 => {
            const name = chapter_names[random.uintAtMost(u2, 3)];
            if (random.uintLessThan(u8, 10) < 3) {
                _ = try tl.addChapter(name, .{ .after = null });
                try naive.addChapter(name, null);
            } else {
                const idx = random.uintAtMost(u32, len - 1);
                _ = try tl.addChapter(name, .{ .after = idAt(tl, idx) });
                try naive.addChapter(name, idx);
            }
        },
        102 => {
            if (naive.chapters.items.len > 0) {
                const pos = random.uintAtMost(usize, naive.chapters.items.len - 1);
                try tl.removeChapter(tl.chapters()[pos].id);
                naive.removeChapterAt(pos);
            }
        },
        103 => {
            if (naive.chapters.items.len > 0) {
                const pos = random.uintAtMost(usize, naive.chapters.items.len - 1);
                const name = chapter_names[random.uintAtMost(u2, 3)];
                try tl.renameChapter(tl.chapters()[pos].id, name);
                try naive.renameChapterAt(pos, name);
            }
        },
        // -- groups -----------------------------------------------------------
        104...105 => {
            const name = group_names[random.uintAtMost(u2, 2)];
            const i = random.uintAtMost(u32, len - 1);
            const j = random.uintAtMost(u32, len - 1);
            _ = try tl.addGroup(name, idAt(tl, i), idAt(tl, j));
            try naive.addGroup(name, @min(i, j), @max(i, j));
        },
        106 => {
            if (naive.groups.items.len > 0) {
                const pos = random.uintAtMost(usize, naive.groups.items.len - 1);
                try tl.removeGroup(tl.groups()[pos].id);
                naive.removeGroupAt(pos);
            }
        },
        107 => {
            if (naive.groups.items.len > 0) {
                const pos = random.uintAtMost(usize, naive.groups.items.len - 1);
                const name = group_names[random.uintAtMost(u2, 2)];
                try tl.renameGroup(tl.groups()[pos].id, name);
                try naive.renameGroupAt(pos, name);
            }
        },
        108 => {
            if (naive.groups.items.len > 0) {
                const pos = random.uintAtMost(usize, naive.groups.items.len - 1);
                const target = random.boolean();
                try tl.setGroupSuppressed(tl.groups()[pos].id, target);
                naive.setGroupSuppressedAt(pos, target);
            }
        },
        109...110 => {
            if (naive.groups.items.len > 0) {
                const pos = random.uintAtMost(usize, naive.groups.items.len - 1);
                const new_pos = random.uintAtMost(u32, len);
                try tl.moveGroup(tl.groups()[pos].id, new_pos);
                try naive.moveGroupAt(pos, new_pos);
            }
        },
        111 => {
            if (naive.groups.items.len > 0) {
                const pos = random.uintAtMost(usize, naive.groups.items.len - 1);
                try tl.removeGroupContents(tl.groups()[pos].id);
                try naive.removeGroupContentsAt(pos);
            }
        },
        // -- parameters -------------------------------------------------------
        112...113 => {
            const name = param_names[random.uintAtMost(u2, 2)];
            if (tl.paramIdByName(name) == null) {
                const value = param_values[random.uintAtMost(u2, 3)];
                const pid = try tl.addParam(name, value);
                try naive.addParamMirror(pid, name, value);
            }
        },
        114...115 => {
            if (tl.paramsList().len > 0) {
                const p = tl.paramsList()[random.uintLessThan(usize, tl.paramsList().len)];
                const value = param_values[random.uintAtMost(u2, 3)];
                try tl.setParam(p.id, value);
                naive.setParamMirror(p.id, value);
            }
        },
        116 => {
            if (tl.paramsList().len > 0) {
                const p = tl.paramsList()[random.uintLessThan(usize, tl.paramsList().len)];
                try tl.removeParam(p.id);
                naive.removeParamMirror(p.id);
            }
        },
        117...119 => {
            // A parameter-driven feature at the marker (or a plain one when
            // there are no parameters yet).
            const op: Domain.Op = if (tl.paramsList().len > 0)
                .{ .scale_by_param = tl.paramsList()[random.uintLessThan(usize, tl.paramsList().len)].id }
            else
                .{ .add = 1 };
            _ = try tl.commit(op);
            try naive.commit(op);
        },
        else => {
            const idx = random.uintAtMost(u32, len - 1);
            const to = random.uintAtMost(u32, len - 1);
            try tl.move(idAt(tl, idx), to);
            try naive.move(idx, to);
        },
    }
}

test "differential: cached timeline matches naive replay (many seeds)" {
    var seed: u64 = 0;
    const total: u64 = 40;
    while (seed < total) : (seed += 1) {
        try runSequence(0x9E3779B97F4A7C15 *% (seed + 1), 120);
    }
}

test "differential: single seed, long sequence" {
    try runSequence(0xDEADBEEF, 600);
}
