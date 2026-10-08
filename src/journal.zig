//! Internal seam: the undo/redo journal.
//!
//! Records timeline edits (not marker moves — scrubbing is free and doesn't
//! erode undo depth) grouped into **transactions**: the undo unit. A record
//! carrying `txn_start` opens a unit; undo unwinds a whole unit, redo
//! replays one. Outside an explicit `beginTxn`, every recorded edit is its
//! own unit ("public ops are implicitly transactional").
//!
//! One list, two regions: `entries[0..head]` are undoable, `entries[head..]`
//! are redoable. The redo region always begins at a transaction boundary;
//! recording truncates it (standard editor semantics) and eviction below
//! `max` removes whole units only, preserving that invariant.
//!
//! Entries carry owned strings (annotation names, tags); the journal owns
//! them for the entry's lifetime and frees them at truncation, eviction,
//! and deinit. Handlers receive entries by value and treat string fields as
//! borrowed reads they may duplicate from, never free.
//!
//! Nested `beginTxn` calls flatten into the outermost unit — there is one
//! undo unit per outermost begin/end pair. Entries are deliberately flat so
//! a future multiuser sync layer can serialize this vocabulary directly.

const std = @import("std");
const ft = @import("root.zig");

const annotations = @import("annotations.zig");
const params = @import("params.zig");

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
            move: struct {
                id: ft.FeatureId,
                from: u32,
                to: u32,
                marker_pre: u32,
                /// Group boundaries this move re-anchored (a boundary member
                /// leaving its span); owned slice, exact undo/redo.
                group_fixes: []annotations.GroupFix = &.{},
            },
            name_set: struct { id: ft.FeatureId, old: ?[]const u8, new: ?[]const u8 },
            tag_add: struct { id: ft.FeatureId, tag: []const u8 },
            tag_remove: struct { id: ft.FeatureId, tag: []const u8 },
            chapter_add: struct { chapter: annotations.Chapter },
            chapter_remove: struct { chapter: annotations.Chapter },
            chapter_rename: struct { id: annotations.ChapterId, old: []const u8, new: []const u8 },
            group_add: struct { group: annotations.Group },
            group_remove: struct { group: annotations.Group },
            group_rename: struct { id: annotations.GroupId, old: []const u8, new: []const u8 },
            param_add: struct { id: params.ParamId, name: []const u8, value: f64 },
            param_remove: struct { id: params.ParamId, name: []const u8, value: f64 },
            param_set: struct { id: params.ParamId, old: f64, new: f64 },
            param_rename: struct { id: params.ParamId, old: []const u8, new: []const u8 },
        };

        pub const Record = struct {
            e: Entry,
            /// True when this record opens a transaction (undo unit).
            txn_start: bool = false,
        };

        /// One yielded entry of an undo or redo unit; `unit_done` marks the
        /// last entry of the unit.
        pub const UndoStep = struct { entry: Entry, unit_done: bool };
        pub const RedoStep = struct { entry: Entry, unit_done: bool };

        gpa: std.mem.Allocator,
        max: u32,
        entries: std.ArrayList(Record) = .empty,
        head: usize = 0,

        /// Open explicit-transaction depth. The first record after the
        /// outermost `beginTxn` carries the boundary flag.
        txn_depth: u32 = 0,
        txn_pending: bool = false,

        pub fn init(gpa: std.mem.Allocator, max: u32) Self {
            return .{ .gpa = gpa, .max = max };
        }

        pub fn deinit(self: *Self) void {
            for (self.entries.items) |*r| self.deinitEntry(&r.e);
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
                .move => |m| self.gpa.free(m.group_fixes),
                .name_set => |n| {
                    if (n.old) |o| self.gpa.free(o);
                    if (n.new) |x| self.gpa.free(x);
                },
                .tag_add => |t| self.gpa.free(t.tag),
                .tag_remove => |t| self.gpa.free(t.tag),
                .chapter_add => |c| self.gpa.free(c.chapter.name),
                .chapter_remove => |c| self.gpa.free(c.chapter.name),
                .chapter_rename => |c| {
                    self.gpa.free(c.old);
                    self.gpa.free(c.new);
                },
                .group_add => |g| self.gpa.free(g.group.name),
                .group_remove => |g| self.gpa.free(g.group.name),
                .group_rename => |g| {
                    self.gpa.free(g.old);
                    self.gpa.free(g.new);
                },
                .param_add => |p| self.gpa.free(p.name),
                .param_remove => |p| self.gpa.free(p.name),
                .param_rename => |p| {
                    self.gpa.free(p.old);
                    self.gpa.free(p.new);
                },
                else => {},
            }
        }

        // -- transactions ------------------------------------------------------

        /// Open a transaction: edits recorded before the matching `endTxn`
        /// undo and redo as one unit. Nested begins flatten into the
        /// outermost unit. An unbalanced `endTxn` is a no-op; an empty
        /// transaction records nothing.
        pub fn beginTxn(self: *Self) void {
            if (self.txn_depth == 0) self.txn_pending = true;
            self.txn_depth += 1;
        }

        pub fn endTxn(self: *Self) void {
            if (self.txn_depth == 0) return;
            self.txn_depth -= 1;
            if (self.txn_depth == 0) self.txn_pending = false;
        }

        pub fn inTxn(self: *const Self) bool {
            return self.txn_depth > 0;
        }

        // -- recording -----------------------------------------------------------

        pub fn record(self: *Self, entry: Entry) void {
            // Outside an explicit transaction every edit is its own unit;
            // inside one, only the first record after begin carries the
            // boundary.
            const starts_unit = if (self.txn_depth > 0) self.txn_pending else true;
            if (self.max == 0) {
                // The entry was never stored: its owned memory must die here.
                var dead = entry;
                self.deinitEntry(&dead);
                return;
            }
            self.txn_pending = false; // the boundary rides on the first record

            for (self.entries.items[self.head..]) |*r| self.deinitEntry(&r.e);
            self.entries.shrinkRetainingCapacity(self.head);
            self.entries.append(self.gpa, .{ .e = entry, .txn_start = starts_unit }) catch {
                // Out of memory: drop history rather than keep a journal
                // that lies about the timeline's past.
                var dead = entry;
                self.deinitEntry(&dead);
                for (self.entries.items) |*r| self.deinitEntry(&r.e);
                self.entries.clearRetainingCapacity();
                self.head = 0;
                return;
            };
            self.head += 1;
            self.evictWholeUnits();
        }

        /// Evict from the front, whole units only, until within `max` (a
        /// single unit larger than `max` is kept intact). This preserves the
        /// invariant that `head` (and index 0, when non-empty) always sit on
        /// a transaction boundary.
        fn evictWholeUnits(self: *Self) void {
            var cut: usize = 0;
            while (self.entries.items.len - cut > self.max) {
                var next = cut + 1;
                while (next < self.entries.items.len and !self.entries.items[next].txn_start) next += 1;
                if (next >= self.entries.items.len) break; // one giant unit
                for (self.entries.items[cut..next]) |*r| self.deinitEntry(&r.e);
                cut = next;
            }
            if (cut == 0) return;
            self.entries.replaceRange(self.gpa, 0, cut, &.{}) catch return;
            self.head -|= cut;
        }

        // -- undo / redo ------------------------------------------------------

        pub fn canUndo(self: *const Self) bool {
            return self.head > 0;
        }

        pub fn canRedo(self: *const Self) bool {
            return self.head < self.entries.items.len;
        }

        /// Yield the next entry of the undoable unit, newest-first. The
        /// undo region shrinks by whole units; `unit_done` flags the unit's
        /// oldest entry.
        pub fn nextUndo(self: *Self) ?UndoStep {
            if (self.head == 0) return null;
            self.head -= 1;
            const rec = self.entries.items[self.head];
            return .{ .entry = rec.e, .unit_done = rec.txn_start };
        }

        /// Yield the next entry of the redoable unit, oldest-first. The
        /// redo region always begins on a boundary; `unit_done` flags the
        /// unit's newest entry.
        pub fn nextRedo(self: *Self) ?RedoStep {
            if (self.head >= self.entries.items.len) return null;
            const rec = self.entries.items[self.head];
            self.head += 1;
            const done = self.head >= self.entries.items.len or
                self.entries.items[self.head].txn_start;
            return .{ .entry = rec.e, .unit_done = done };
        }
    };
}
