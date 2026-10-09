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
    new_mark: Mark,
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

/// One group boundary re-anchor caused by removing or moving a boundary
/// member; journaled so undo restores the exact previous span and redo
/// re-applies the exact new one.
pub const GroupFix = struct {
    group_id: GroupId,
    old_first: ft.FeatureId,
    old_last: ft.FeatureId,
    new_first: ft.FeatureId,
    new_last: ft.FeatureId,
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

    /// Move a feature's name out of the store (ownership transfers to the
    /// caller). Used by undo-of-commit, which must resurrect it on redo.
    pub fn takeName(self: *Self, id: ft.FeatureId) ?[]const u8 {
        if (self.names.fetchRemove(id)) |old| return old.value;
        return null;
    }

    /// Store an already-owned name string (ownership transfers in).
    pub fn giveName(self: *Self, id: ft.FeatureId, owned: []const u8) error{OutOfMemory}!void {
        errdefer self.gpa.free(owned);
        try self.names.ensureUnusedCapacity(self.gpa, 1);
        if (self.names.fetchRemove(id)) |old| self.gpa.free(old.value);
        self.names.putAssumeCapacity(id, owned);
    }

    /// Make room for one more name, so the next `swapName` cannot fail.
    pub fn reserveName(self: *Self) error{OutOfMemory}!void {
        try self.names.ensureUnusedCapacity(self.gpa, 1);
    }

    /// Move `incoming` in (null removes the name) and hand back whatever
    /// was there. Never allocates: the caller reserved a slot, or is
    /// restoring a name whose slot a take freed (undo/redo).
    pub fn swapName(self: *Self, id: ft.FeatureId, incoming: ?[]const u8) ?[]const u8 {
        if (incoming) |n| {
            const gop = self.names.getOrPutAssumeCapacity(id);
            const prev: ?[]const u8 = if (gop.found_existing) gop.value_ptr.* else null;
            gop.value_ptr.* = n;
            return prev;
        }
        const kv = self.names.fetchRemove(id) orelse return null;
        return kv.value;
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
        const owned = try self.gpa.dupe(u8, chapter_name);
        errdefer self.gpa.free(owned);
        try self.chapters.append(self.gpa, .{ .id = id, .name = owned, .mark = mark });
    }

    pub const TakenChapter = struct { chapter: Chapter, at: u32 };

    /// Take a chapter out (its name's ownership moves to the caller) and
    /// report the position it held. The list keeps its capacity, so the
    /// chapter can go back in without allocating.
    pub fn takeChapter(self: *Self, id: ChapterId) ?TakenChapter {
        for (self.chapters.items, 0..) |c, i| {
            if (c.id == id) return .{ .chapter = self.chapters.orderedRemove(i), .at = @intCast(i) };
        }
        return null;
    }

    /// Put a chapter (owned name) back at `at` (clamped). Needs no memory
    /// when the list kept the room a take freed; otherwise it may allocate.
    pub fn giveChapterAt(self: *Self, chapter: Chapter, at: u32) error{OutOfMemory}!void {
        errdefer self.gpa.free(chapter.name);
        const pos: usize = @min(at, self.chapters.items.len);
        if (self.chapters.items.len < self.chapters.capacity) {
            self.chapters.insertAssumeCapacity(pos, chapter);
        } else {
            try self.chapters.insert(self.gpa, pos, chapter);
        }
    }

    /// Move `incoming` in as the chapter's name and hand back the old one.
    /// Null (and `incoming` still the caller's) when the chapter is absent.
    pub fn swapChapterName(self: *Self, id: ChapterId, incoming: []const u8) ?[]const u8 {
        const c = self.mutableChapter(id) orelse return null;
        const prev = c.name;
        c.name = incoming;
        return prev;
    }

    fn mutableChapter(self: *Self, id: ChapterId) ?*Chapter {
        for (self.chapters.items) |*c| {
            if (c.id == id) return c;
        }
        return null;
    }

    /// Plan the re-anchoring of chapters whose mark sits after `removed_id`
    /// to the feature that shifts into its position (`replacement`, or
    /// end-pinned if it was the last feature). Pure: nothing changes until
    /// `applyFixesForward`. Caller owns the slice.
    pub fn planReanchorAfterRemove(self: *const Self, removed_id: ft.FeatureId, replacement: ?ft.FeatureId) error{OutOfMemory}![]ChapterFix {
        var fixes: std.ArrayList(ChapterFix) = .empty;
        errdefer fixes.deinit(self.gpa);
        for (self.chapters.items) |c| {
            const anchored_here = if (c.mark.after) |a| a == removed_id else false;
            if (anchored_here) {
                try fixes.append(self.gpa, .{ .chapter_id = c.id, .old_mark = c.mark, .new_mark = .{ .after = replacement } });
            }
        }
        return fixes.toOwnedSlice(self.gpa);
    }

    /// Restore the marks recorded by a plan (undo).
    pub fn applyFixes(self: *Self, fixes: []const ChapterFix) void {
        for (fixes) |f| {
            if (self.mutableChapter(f.chapter_id)) |c| c.mark = f.old_mark;
        }
    }

    /// Apply the marks a plan computed (do / redo).
    pub fn applyFixesForward(self: *Self, fixes: []const ChapterFix) void {
        for (fixes) |f| {
            if (self.mutableChapter(f.chapter_id)) |c| c.mark = f.new_mark;
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

    pub const TakenTag = struct { text: []const u8, at: u32 };

    /// Make room for one more tag on `id` (creating its empty list if
    /// needed), so the next `pushTag` cannot fail.
    pub fn reserveTag(self: *Self, id: ft.FeatureId) error{OutOfMemory}!void {
        const gop = try self.tags.getOrPut(self.gpa, id);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.ensureUnusedCapacity(self.gpa, 1);
    }

    /// Append an owned tag string after `reserveTag`. Returns its position.
    pub fn pushTag(self: *Self, id: ft.FeatureId, owned: []const u8) u32 {
        const list = self.tags.getPtr(id).?;
        list.appendAssumeCapacity(owned);
        return @intCast(list.items.len - 1);
    }

    /// Take a tag out by text (ownership moves to the caller). The list
    /// stays, empty or not, keeping its room for undo.
    pub fn takeTag(self: *Self, id: ft.FeatureId, tag: []const u8) ?TakenTag {
        const list = self.tags.getPtr(id) orelse return null;
        for (list.items, 0..) |t, i| {
            if (std.mem.eql(u8, t, tag)) return .{ .text = list.orderedRemove(i), .at = @intCast(i) };
        }
        return null;
    }

    /// Take the tag at position `at` out (undo of an add).
    pub fn takeTagAt(self: *Self, id: ft.FeatureId, at: u32) ?[]const u8 {
        const list = self.tags.getPtr(id) orelse return null;
        if (at >= list.items.len) return null;
        return list.orderedRemove(at);
    }

    /// Put an owned tag back at `at` (clamped). Needs no memory when the
    /// list kept the room a take freed; otherwise it may allocate.
    pub fn giveTagAt(self: *Self, id: ft.FeatureId, owned: []const u8, at: u32) error{OutOfMemory}!void {
        errdefer self.gpa.free(owned);
        const list: *std.ArrayList([]const u8) = self.tags.getPtr(id) orelse blk: {
            const gop = try self.tags.getOrPut(self.gpa, id);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            break :blk gop.value_ptr;
        };
        const pos: usize = @min(at, list.items.len);
        if (list.items.len < list.capacity) {
            list.insertAssumeCapacity(pos, owned);
        } else {
            try list.insert(self.gpa, pos, owned);
        }
    }

    /// Add a tag (no-op if already present). Returns true when added.
    pub fn addTag(self: *Self, id: ft.FeatureId, tag: []const u8) error{OutOfMemory}!bool {
        if (self.hasTag(id, tag)) return false;
        const owned = try self.gpa.dupe(u8, tag);
        errdefer self.gpa.free(owned);
        const gop = try self.tags.getOrPut(self.gpa, id);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        // A failed append leaves at most an empty list behind: harmless.
        try gop.value_ptr.append(self.gpa, owned);
        return true;
    }

    /// Take a feature's whole tag list out (ownership moves; no allocation).
    pub fn takeTagList(self: *Self, id: ft.FeatureId) std.ArrayList([]const u8) {
        const kv = self.tags.fetchRemove(id) orelse return .empty;
        return kv.value;
    }

    /// Store already-owned tag strings for a feature (ownership transfers
    /// in). Replaces any existing tags.
    pub fn giveTagList(self: *Self, id: ft.FeatureId, list: std.ArrayList([]const u8)) error{OutOfMemory}!void {
        var incoming = list;
        errdefer {
            for (incoming.items) |t| self.gpa.free(t);
            incoming.deinit(self.gpa);
        }
        // No growth when the slot was freed by `takeTagList`.
        try self.tags.ensureUnusedCapacity(self.gpa, 1);
        if (self.tags.fetchRemove(id)) |old| {
            var dead = old.value;
            for (dead.items) |t| self.gpa.free(t);
            dead.deinit(self.gpa);
        }
        self.tags.putAssumeCapacity(id, incoming);
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
        const owned = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned);
        try self.groups.append(self.gpa, .{ .id = id, .name = owned, .first = first, .last = last });
    }

    pub const TakenGroup = struct { group: Group, at: u32 };

    /// Take a group out (its name's ownership moves to the caller) and
    /// report the position it held. The list keeps its capacity.
    pub fn takeGroup(self: *Self, id: GroupId) ?TakenGroup {
        for (self.groups.items, 0..) |g, i| {
            if (g.id == id) return .{ .group = self.groups.orderedRemove(i), .at = @intCast(i) };
        }
        return null;
    }

    /// Put a group (owned name) back at `at` (clamped). Needs no memory
    /// when the list kept the room a take freed; otherwise it may allocate.
    pub fn giveGroupAt(self: *Self, group: Group, at: u32) error{OutOfMemory}!void {
        errdefer self.gpa.free(group.name);
        const pos: usize = @min(at, self.groups.items.len);
        if (self.groups.items.len < self.groups.capacity) {
            self.groups.insertAssumeCapacity(pos, group);
        } else {
            try self.groups.insert(self.gpa, pos, group);
        }
    }

    /// Move `incoming` in as the group's name and hand back the old one.
    /// Null (and `incoming` still the caller's) when the group is absent.
    pub fn swapGroupName(self: *Self, id: GroupId, incoming: []const u8) ?[]const u8 {
        const g = self.mutableGroup(id) orelse return null;
        const prev = g.name;
        g.name = incoming;
        return prev;
    }

    fn mutableGroup(self: *Self, id: GroupId) ?*Group {
        for (self.groups.items) |*g| {
            if (g.id == id) return g;
        }
        return null;
    }

    /// Restore the boundaries recorded by boundary fixups (undo).
    pub fn applyGroupFixes(self: *Self, fixes: []const GroupFix) void {
        for (fixes) |f| {
            if (self.mutableGroup(f.group_id)) |g| {
                g.first = f.old_first;
                g.last = f.old_last;
            }
        }
    }

    /// Re-apply the boundaries recorded by boundary fixups (redo).
    pub fn applyGroupFixesForward(self: *Self, fixes: []const GroupFix) void {
        for (fixes) |f| {
            if (self.mutableGroup(f.group_id)) |g| {
                g.first = f.new_first;
                g.last = f.new_last;
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
