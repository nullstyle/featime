//! The annotation layer: user-authored metadata about the timeline that
//! never affects document computation — feature names, chapters, provenance,
//! tags, and contiguous groups (spans).
//!
//! Everything is anchored to `FeatureId`s, never indices, and the layer
//! participates fully in undo (via journal entries and structural fixup
//! snapshots) and persistence. `Timeline` owns id allocation; this store
//! only owns string memory.

const std = @import("std");
const ft = @import("root.zig");

pub const ChapterId = u64;

/// Provenance: who authored a feature and when. Timestamps come from the
/// application's clock (`Config.now`) or an explicit `commitWithMeta`.
pub const Meta = struct {
    author: u64 = 0,
    ts: u64 = 0,
};

/// A position on the timeline anchored to the feature stream: the gap
/// immediately after `after`. `null` pins to the end of the timeline — the
/// mark follows the tip as features are appended.
pub const Mark = struct {
    after: ?ft.FeatureId,
};

pub const Chapter = struct {
    id: ChapterId,
    /// Owned by whoever holds the chapter (annotation store, journal entry,
    /// or the resurrection stash during an undo/redo window).
    name: []const u8,
    mark: Mark,
};

/// One chapter re-anchor caused by removing an anchor feature; journaled so
/// undo restores the exact previous mark.
pub const ChapterFix = struct {
    chapter_id: ChapterId,
    old_mark: Mark,
};

pub const GroupId = u64;

/// A contiguous named span (folder). Membership is *computed* as the
/// features between the `first` and `last` anchors, so inserts inside the
/// span join it and reordering a member out leaves it — Fusion folder
/// behavior. Dead anchors (their feature deleted with no member left to
/// re-anchor to) make the span empty; the group survives as an empty folder.
pub const Group = struct {
    id: GroupId,
    /// Owned by whoever holds the group.
    name: []const u8,
    first: ft.FeatureId,
    last: ft.FeatureId,
};

/// One group boundary re-anchor caused by removing a member; journaled so
/// undo restores the exact previous span.
pub const GroupFix = struct {
    group_id: GroupId,
    old_first: ft.FeatureId,
    old_last: ft.FeatureId,
};

pub const Annotations = struct {
    const Self = @This();

    gpa: std.mem.Allocator,

    names: std.AutoHashMapUnmanaged(ft.FeatureId, []const u8) = .empty,
    prov: std.AutoHashMapUnmanaged(ft.FeatureId, Meta) = .empty,
    chapters: std.ArrayList(Chapter) = .empty,
    /// Per-feature tags in insertion order; strings owned. Set semantics:
    /// a tag is either present or absent, never duplicated.
    tags: std.AutoHashMapUnmanaged(ft.FeatureId, std.ArrayList([]const u8)) = .empty,
    groups: std.ArrayList(Group) = .empty,

    pub fn init(gpa: std.mem.Allocator) Self {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Self) void {
        var it = self.names.iterator();
        while (it.next()) |e| self.gpa.free(e.value_ptr.*);
        self.names.deinit(self.gpa);
        self.prov.deinit(self.gpa);
        for (self.chapters.items) |*c| self.gpa.free(c.name);
        self.chapters.deinit(self.gpa);
        var tit = self.tags.iterator();
        while (tit.next()) |e| {
            for (e.value_ptr.items) |t| self.gpa.free(t);
            e.value_ptr.deinit(self.gpa);
        }
        self.tags.deinit(self.gpa);
        for (self.groups.items) |*g| self.gpa.free(g.name);
        self.groups.deinit(self.gpa);
    }

    // -- feature names ---------------------------------------------------

    pub fn nameOf(self: *const Self, id: ft.FeatureId) ?[]const u8 {
        return self.names.get(id);
    }

    pub fn setName(self: *Self, id: ft.FeatureId, new: ?[]const u8) error{OutOfMemory}!void {
        if (self.names.fetchRemove(id)) |old| self.gpa.free(old.value);
        if (new) |n| try self.names.put(self.gpa, id, try self.gpa.dupe(u8, n));
    }

    /// Move a feature's name out of the store (ownership transfers to the
    /// caller). Used by undo-of-commit, which must resurrect it on redo.
    pub fn takeName(self: *Self, id: ft.FeatureId) ?[]const u8 {
        if (self.names.fetchRemove(id)) |old| return old.value;
        return null;
    }

    /// Store an already-owned name string (ownership transfers in).
    pub fn giveName(self: *Self, id: ft.FeatureId, owned: []const u8) error{OutOfMemory}!void {
        if (self.names.fetchRemove(id)) |old| self.gpa.free(old.value);
        errdefer self.gpa.free(owned);
        try self.names.put(self.gpa, id, owned);
    }

    // -- provenance --------------------------------------------------------

    pub fn provenance(self: *const Self, id: ft.FeatureId) ?Meta {
        return self.prov.get(id);
    }

    pub fn setProvenance(self: *Self, id: ft.FeatureId, meta: Meta) error{OutOfMemory}!void {
        try self.prov.put(self.gpa, id, meta);
    }

    // -- chapters ----------------------------------------------------------

    pub fn chapterList(self: *const Self) []const Chapter {
        return self.chapters.items;
    }

    pub fn chapterById(self: *const Self, id: ChapterId) ?*const Chapter {
        for (self.chapters.items) |*c| {
            if (c.id == id) return c;
        }
        return null;
    }

    pub fn addChapter(self: *Self, id: ChapterId, chapter_name: []const u8, mark: Mark) error{OutOfMemory}!void {
        try self.chapters.append(self.gpa, .{
            .id = id,
            .name = try self.gpa.dupe(u8, chapter_name),
            .mark = mark,
        });
    }

    pub fn removeChapter(self: *Self, id: ChapterId) void {
        for (self.chapters.items, 0..) |c, i| {
            if (c.id == id) {
                const dead = self.chapters.orderedRemove(i);
                self.gpa.free(dead.name);
                return;
            }
        }
    }

    pub fn renameChapter(self: *Self, id: ChapterId, new_name: []const u8) error{OutOfMemory}!void {
        const c = self.mutableChapter(id) orelse return;
        const duped = try self.gpa.dupe(u8, new_name);
        self.gpa.free(c.name);
        c.name = duped;
    }

    fn mutableChapter(self: *Self, id: ChapterId) ?*Chapter {
        for (self.chapters.items) |*c| {
            if (c.id == id) return c;
        }
        return null;
    }

    /// Re-anchor chapters whose mark sits after `removed_id` to the feature
    /// that shifted into its position (`replacement`, or end-pinned if it was
    /// the last feature). Returns the fixes needed to undo this exactly;
    /// caller owns the slice.
    pub fn reanchorAfterRemove(self: *Self, removed_id: ft.FeatureId, replacement: ?ft.FeatureId) error{OutOfMemory}![]ChapterFix {
        var fixes: std.ArrayList(ChapterFix) = .empty;
        errdefer fixes.deinit(self.gpa);
        for (self.chapters.items) |*c| {
            const anchored_here = if (c.mark.after) |a| a == removed_id else false;
            if (anchored_here) {
                try fixes.append(self.gpa, .{ .chapter_id = c.id, .old_mark = c.mark });
                c.mark = .{ .after = replacement };
            }
        }
        return fixes.toOwnedSlice(self.gpa);
    }

    /// Restore marks recorded by `reanchorAfterRemove`.
    pub fn applyFixes(self: *Self, fixes: []const ChapterFix) void {
        for (fixes) |f| {
            if (self.mutableChapter(f.chapter_id)) |c| c.mark = f.old_mark;
        }
    }

    // -- tags ----------------------------------------------------------------

    /// The feature's tags in insertion order. Empty for absent features.
    pub fn tagList(self: *const Self, id: ft.FeatureId) []const []const u8 {
        if (self.tags.get(id)) |list| return list.items;
        return &.{};
    }

    pub fn hasTag(self: *const Self, id: ft.FeatureId, tag: []const u8) bool {
        for (self.tagList(id)) |t| {
            if (std.mem.eql(u8, t, tag)) return true;
        }
        return false;
    }

    /// Add a tag (no-op if already present). Returns true when added.
    pub fn addTag(self: *Self, id: ft.FeatureId, tag: []const u8) error{OutOfMemory}!bool {
        if (self.hasTag(id, tag)) return false;
        const gop = try self.tags.getOrPut(self.gpa, id);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(self.gpa, try self.gpa.dupe(u8, tag));
        return true;
    }

    /// Remove a tag. Returns true when a tag was removed (the caller
    /// journals the tag string it removed).
    pub fn removeTag(self: *Self, id: ft.FeatureId, tag: []const u8) bool {
        const list = self.tags.getPtr(id) orelse return false;
        for (list.items, 0..) |t, i| {
            if (std.mem.eql(u8, t, tag)) {
                const dead = list.orderedRemove(i);
                self.gpa.free(dead);
                if (list.items.len == 0) {
                    list.deinit(self.gpa);
                    _ = self.tags.remove(id);
                }
                return true;
            }
        }
        return false;
    }

    /// Move all of a feature's tags out (ownership transfers to the caller);
    /// used when deleting the feature so undo can restore them.
    pub fn takeTags(self: *Self, id: ft.FeatureId) error{OutOfMemory}![][]const u8 {
        var list = self.tags.fetchRemove(id) orelse return &.{};
        const out = try self.gpa.dupe([]const u8, list.value.items);
        errdefer self.gpa.free(out);
        list.value.deinit(self.gpa); // frees the ArrayList buffer; strings move
        return out;
    }

    /// Store already-owned tag strings for a feature (ownership transfers
    /// in). Replaces any existing tags.
    pub fn giveTags(self: *Self, id: ft.FeatureId, owned: [][]const u8) error{OutOfMemory}!void {
        var list: std.ArrayList([]const u8) = .empty;
        errdefer list.deinit(self.gpa);
        try list.appendSlice(self.gpa, owned);
        if (self.tags.getPtr(id)) |old| {
            for (old.items) |t| self.gpa.free(t);
            old.deinit(self.gpa);
        }
        try self.tags.put(self.gpa, id, list);
    }

    /// Free an owned tag array (the strings and the slice).
    pub fn freeTags(self: *Self, owned: [][]const u8) void {
        for (owned) |t| self.gpa.free(@constCast(t));
        self.gpa.free(owned);
    }

    // -- groups ----------------------------------------------------------------

    pub fn groupList(self: *const Self) []const Group {
        return self.groups.items;
    }

    /// Mutable access for boundary fixups (internal).
    pub fn groupsMut(self: *Self) []Group {
        return self.groups.items;
    }

    pub fn groupById(self: *const Self, id: GroupId) ?*const Group {
        for (self.groups.items) |*g| {
            if (g.id == id) return g;
        }
        return null;
    }

    pub fn addGroup(self: *Self, id: GroupId, name: []const u8, first: ft.FeatureId, last: ft.FeatureId) error{OutOfMemory}!void {
        try self.groups.append(self.gpa, .{
            .id = id,
            .name = try self.gpa.dupe(u8, name),
            .first = first,
            .last = last,
        });
    }

    pub fn removeGroup(self: *Self, id: GroupId) void {
        for (self.groups.items, 0..) |g, i| {
            if (g.id == id) {
                const dead = self.groups.orderedRemove(i);
                self.gpa.free(dead.name);
                return;
            }
        }
    }

    pub fn renameGroup(self: *Self, id: GroupId, new_name: []const u8) error{OutOfMemory}!void {
        const g = self.mutableGroup(id) orelse return;
        const duped = try self.gpa.dupe(u8, new_name);
        self.gpa.free(g.name);
        g.name = duped;
    }

    fn mutableGroup(self: *Self, id: GroupId) ?*Group {
        for (self.groups.items) |*g| {
            if (g.id == id) return g;
        }
        return null;
    }

    /// Restore boundaries recorded by boundary fixups.
    pub fn applyGroupFixes(self: *Self, fixes: []const GroupFix) void {
        for (fixes) |f| {
            if (self.mutableGroup(f.group_id)) |g| {
                g.first = f.old_first;
                g.last = f.old_last;
            }
        }
    }

    // -- structural hooks --------------------------------------------------

    /// Drop everything keyed to a feature that is being deleted (the caller
    /// snapshots what it needs for undo first).
    pub fn removeProvenance(self: *Self, id: ft.FeatureId) void {
        _ = self.prov.remove(id);
    }

    pub fn removeFeature(self: *Self, id: ft.FeatureId) void {
        if (self.takeName(id)) |owned| self.gpa.free(owned);
        _ = self.prov.remove(id);
    }
};
