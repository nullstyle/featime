//! Internal seam: the undo/redo journal.
//!
//! Records timeline edits (not marker moves — scrubbing is free and doesn't
//! erode undo depth). Each entry stores enough plain data to reverse and
//! re-apply itself; entries are deliberately flat so a future multiuser sync
//! layer can serialize this vocabulary directly.
//!
//! One list, two regions: `entries[0..head]` are undoable, `entries[head..]`
//! are redoable. Recording truncates the redo region (standard editor
//! semantics) and evicts oldest-first past `max`.
//!
//! Annotation entries carry owned strings (names, tags): the journal owns
//! them for the entry's lifetime in the list and frees them at truncation,
//! eviction, and deinit. Handlers receive entries by value and treat string
//! fields as borrowed reads they may duplicate from, never free.

const std = @import("std");
const ft = @import("root.zig");

const annotations = @import("annotations.zig");

pub fn Journal(comptime Op: type) type {
    return struct {
        const Self = @This();

        pub const Entry = union(enum) {
            commit: struct {
                id: ft.FeatureId,
                op: Op,
                at: u32,
                /// Provenance recorded at commit time; restored on redo.
                meta: ?annotations.Meta = null,
            },
            edit: struct { id: ft.FeatureId, old_op: Op, new_op: Op },
            remove: struct {
                id: ft.FeatureId,
                op: Op,
                at: u32,
                suppressed: bool,
                marker_pre: u32,
                /// Annotation snapshots for exact undo restoration.
                name: ?[]const u8 = null, // owned by this entry
                meta: ?annotations.Meta = null,
                chapter_fixes: []annotations.ChapterFix = &.{}, // owned slice
                tags: [][]const u8 = &.{}, // owned strings + owned slice
                group_fixes: []annotations.GroupFix = &.{}, // owned slice
            },
            suppress: struct { id: ft.FeatureId, prev: bool },
            move: struct { id: ft.FeatureId, from: u32, to: u32, marker_pre: u32 },
            name_set: struct { id: ft.FeatureId, old: ?[]const u8, new: ?[]const u8 },
            tag_add: struct { id: ft.FeatureId, tag: []const u8 },
            tag_remove: struct { id: ft.FeatureId, tag: []const u8 },
            group_add: struct { group: annotations.Group },
            group_remove: struct { group: annotations.Group },
            group_rename: struct { id: annotations.GroupId, old: []const u8, new: []const u8 },
            /// Compound: batch suppression of a group's members in one
            /// undo step. `prev` is each member's pre-change value; redo
            /// sets every changed member to `!prev`.
            group_suppress: struct { changes: []SuppressChange },
            /// Compound: relocate a group's members keeping order (M4).
            group_move: struct {
                ids: []ft.FeatureId, // member order before the move
                from: u32, // block start before the move
                to: u32, // block start after the move
                marker_pre: u32,
            },
            /// Compound: delete a group and its members in one undo step.
            group_delete: struct {
                group: annotations.Group, // snapshot (owns name)
                members: []RemovedMember, // original list order
                marker_pre: u32,
            },
            chapter_add: struct { chapter: annotations.Chapter },
            chapter_remove: struct { chapter: annotations.Chapter },
            chapter_rename: struct { id: annotations.ChapterId, old: []const u8, new: []const u8 },
        };

        gpa: std.mem.Allocator,
        max: u32,
        entries: std.ArrayList(Entry) = .empty,
        head: usize = 0,

        pub const SuppressChange = struct { id: ft.FeatureId, prev: bool };
        pub const RemovedMember = struct {
            at: u32,
            id: ft.FeatureId,
            op: Op,
            suppressed: bool,
            // Annotation snapshots for exact undo (all owned by the entry).
            name: ?[]const u8 = null,
            tags: [][]const u8 = &.{},
            meta: ?annotations.Meta = null,
            chapter_fixes: []annotations.ChapterFix = &.{},
            group_fixes: []annotations.GroupFix = &.{},
        };

        pub fn init(gpa: std.mem.Allocator, max: u32) Self {
            return .{ .gpa = gpa, .max = max };
        }

        pub fn deinit(self: *Self) void {
            for (self.entries.items) |*e| self.deinitEntry(e);
            self.entries.deinit(self.gpa);
        }

        fn deinitEntry(self: *Self, e: *const Entry) void {
            switch (e.*) {
                .remove => |r| {
                    if (r.name) |n| self.gpa.free(n);
                    self.gpa.free(r.chapter_fixes);
                    for (r.tags) |t| self.gpa.free(t);
                    self.gpa.free(r.tags);
                    self.gpa.free(r.group_fixes);
                },
                .name_set => |n| {
                    if (n.old) |o| self.gpa.free(o);
                    if (n.new) |x| self.gpa.free(x);
                },
                .tag_add => |t| self.gpa.free(t.tag),
                .tag_remove => |t| self.gpa.free(t.tag),
                .group_add => |g| self.gpa.free(g.group.name),
                .group_remove => |g| self.gpa.free(g.group.name),
                .group_rename => |g| {
                    self.gpa.free(g.old);
                    self.gpa.free(g.new);
                },
                .group_suppress => |g| self.gpa.free(g.changes),
                .group_move => |g| self.gpa.free(g.ids),
                .group_delete => |g| {
                    self.gpa.free(g.group.name);
                    for (g.members) |m| {
                        if (m.name) |n| self.gpa.free(n);
                        for (m.tags) |t| self.gpa.free(t);
                        self.gpa.free(m.tags);
                        self.gpa.free(m.chapter_fixes);
                        self.gpa.free(m.group_fixes);
                    }
                    self.gpa.free(g.members);
                },
                .chapter_add => |c| self.gpa.free(c.chapter.name),
                .chapter_remove => |c| self.gpa.free(c.chapter.name),
                .chapter_rename => |c| {
                    self.gpa.free(c.old);
                    self.gpa.free(c.new);
                },
                else => {},
            }
        }

        pub fn record(self: *Self, entry: Entry) void {
            if (self.max == 0) {
                // The entry was never stored: its owned memory must die here.
                var dead = entry;
                self.deinitEntry(&dead);
                return;
            }
            for (self.entries.items[self.head..]) |*e| self.deinitEntry(e);
            self.entries.shrinkRetainingCapacity(self.head);
            self.entries.append(self.gpa, entry) catch {
                // Out of memory: drop history rather than keep a journal
                // that lies about the timeline's past.
                var dead = entry;
                self.deinitEntry(&dead);
                for (self.entries.items) |*e| self.deinitEntry(e);
                self.entries.clearRetainingCapacity();
                self.head = 0;
                return;
            };
            self.head += 1;
            if (self.entries.items.len > self.max) {
                var dead = self.entries.orderedRemove(0);
                self.deinitEntry(&dead);
                self.head -= 1;
            }
        }

        pub fn canUndo(self: *const Self) bool {
            return self.head > 0;
        }

        pub fn canRedo(self: *const Self) bool {
            return self.head < self.entries.items.len;
        }

        /// Pop the newest undoable entry (it becomes redoable).
        pub fn nextUndo(self: *Self) ?Entry {
            if (self.head == 0) return null;
            self.head -= 1;
            return self.entries.items[self.head];
        }

        /// Take the oldest redoable entry (it becomes undoable again).
        pub fn nextRedo(self: *Self) ?Entry {
            if (self.head >= self.entries.items.len) return null;
            const e = self.entries.items[self.head];
            self.head += 1;
            return e;
        }
    };
}
