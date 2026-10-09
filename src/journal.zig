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
//! Storage is a deque on an array list: evicted records are retired by
//! advancing `start` (O(1)) and the dead prefix is compacted away only once
//! it reaches half the array, so a full journal costs amortized O(1) per
//! record instead of a memmove of the whole journal.
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
                /// Predecessor at the origin (null: inserted first) and the
                /// replicated order key — what `applyRemote` places by.
                after: ?ft.FeatureId = null,
                order: ft.OrderKey = .{},
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
            /// Wall-clock stamp from the timeline's `Config.now` at record
            /// time; 0 without a clock.
            ts: u64 = 0,
            /// User label of the unit (`beginLabeledTransaction`); owned,
            /// carried by the unit's first record only.
            label: ?[]const u8 = null,
        };

        /// What a history unit did, for history panels. Multi-entry units
        /// (explicit transactions, group operations) report `.batch`.
        pub const UnitKind = enum { commit, edit, remove, suppress, move, name, tag, chapter, group, parameter, batch };

        /// One undo/redo unit as seen by `units()`.
        pub const Unit = struct {
            /// Position in the journal, oldest first.
            index: u32,
            /// Number of journal entries in the unit.
            entries: u32,
            kind: UnitKind,
            /// Label given at `beginLabeledTransaction`, if any. Borrowed:
            /// valid until the next journal mutation.
            label: ?[]const u8,
            /// Timestamp of the unit's first entry (0 without a clock).
            ts: u64,
            /// True when the unit has been undone (it sits in the redo region).
            undone: bool,
        };

        pub const UnitIter = struct {
            j: *const Self,
            i: usize = 0,
            n: u32 = 0,

            pub fn next(it: *UnitIter) ?Unit {
                const items = it.j.live();
                if (it.i >= items.len) return null;
                const start = it.i;
                var end = start + 1;
                while (end < items.len and !items[end].txn_start) end += 1;
                const first = items[start];
                const count: u32 = @intCast(end - start);
                const unit: Unit = .{
                    .index = it.n,
                    .entries = count,
                    .kind = if (count == 1) kindOf(first.e) else .batch,
                    .label = first.label,
                    .ts = first.ts,
                    .undone = start >= it.j.head,
                };
                it.i = end;
                it.n += 1;
                return unit;
            }
        };

        fn kindOf(e: Entry) UnitKind {
            return switch (e) {
                .commit => .commit,
                .edit => .edit,
                .remove => .remove,
                .suppress => .suppress,
                .move => .move,
                .name_set => .name,
                .tag_add, .tag_remove => .tag,
                .chapter_add, .chapter_remove, .chapter_rename => .chapter,
                .group_add, .group_remove, .group_rename => .group,
                .param_add, .param_remove, .param_set, .param_rename => .parameter,
            };
        }

        /// One yielded entry of an undo or redo unit; `unit_done` marks the
        /// last entry of the unit.
        pub const UndoStep = struct { entry: Entry, unit_done: bool };
        pub const RedoStep = struct { entry: Entry, unit_done: bool };

        gpa: std.mem.Allocator,
        max: u32,
        /// Stamps records; null leaves `ts` at 0.
        clock: ?ft.Clock = null,
        entries: std.ArrayList(Record) = .empty,
        /// Physical index of logical record 0 (retired records sit before it
        /// until the next compaction).
        start: usize = 0,
        /// Logical index: `live()[0..head]` undoable, `live()[head..]` redoable.
        head: usize = 0,

        /// Open explicit-transaction depth. The first record after the
        /// outermost `beginTxn` carries the boundary flag.
        txn_depth: u32 = 0,
        txn_pending: bool = false,
        /// Owned label waiting for the unit's first record.
        txn_label: ?[]const u8 = null,

        pub fn init(gpa: std.mem.Allocator, max: u32, clock: ?ft.Clock) Self {
            return .{ .gpa = gpa, .max = max, .clock = clock };
        }

        pub fn deinit(self: *Self) void {
            for (self.live()) |*r| self.deinitRecord(r);
            self.entries.deinit(self.gpa);
            if (self.txn_label) |l| self.gpa.free(l);
        }

        /// The logical journal: every record not yet retired.
        fn live(self: *const Self) []Record {
            return self.entries.items[self.start..];
        }

        /// Retire `n` records from the front (already deinitialized) and
        /// compact the array once the dead prefix reaches half of it.
        fn retireFront(self: *Self, n: usize) void {
            self.start += n;
            self.head -= n;
            if (self.start >= 32 and self.start * 2 >= self.entries.items.len) {
                self.entries.replaceRange(self.gpa, 0, self.start, &.{}) catch return;
                self.start = 0;
            }
        }

        fn deinitRecord(self: *Self, r: *const Record) void {
            self.deinitEntry(&r.e);
            if (r.label) |l| self.gpa.free(l);
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

        /// `beginTxn` with a user label for history panels. Only the
        /// outermost begin's label is kept (nested begins flatten).
        pub fn beginTxnLabeled(self: *Self, label: []const u8) error{OutOfMemory}!void {
            if (self.txn_depth == 0) {
                const owned = try self.gpa.dupe(u8, label);
                if (self.txn_label) |l| self.gpa.free(l);
                self.txn_label = owned;
            }
            self.beginTxn();
        }

        pub fn endTxn(self: *Self) void {
            if (self.txn_depth == 0) return;
            self.txn_depth -= 1;
            if (self.txn_depth == 0) {
                self.txn_pending = false;
                // An empty labeled transaction recorded nothing: drop the label.
                if (self.txn_label) |l| self.gpa.free(l);
                self.txn_label = null;
            }
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
            // The label rides on the unit's first record (ownership moves).
            const label: ?[]const u8 = if (starts_unit and self.txn_depth > 0) self.txn_label else null;
            if (starts_unit and self.txn_depth > 0) self.txn_label = null;
            if (self.max == 0) {
                // The entry was never stored: its owned memory must die here.
                var dead = entry;
                self.deinitEntry(&dead);
                if (label) |l| self.gpa.free(l);
                return;
            }
            self.txn_pending = false; // the boundary rides on the first record

            for (self.live()[self.head..]) |*r| self.deinitRecord(r);
            self.entries.shrinkRetainingCapacity(self.start + self.head);
            const ts: u64 = if (self.clock) |now| now() else 0;
            self.entries.append(self.gpa, .{ .e = entry, .txn_start = starts_unit, .ts = ts, .label = label }) catch {
                // Out of memory: drop history rather than keep a journal
                // that lies about the timeline's past.
                var dead = entry;
                self.deinitEntry(&dead);
                if (label) |l| self.gpa.free(l);
                for (self.live()) |*r| self.deinitRecord(r);
                self.entries.clearRetainingCapacity();
                self.start = 0;
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
            const items = self.live();
            var cut: usize = 0;
            while (items.len - cut > self.max) {
                var next = cut + 1;
                while (next < items.len and !items[next].txn_start) next += 1;
                if (next >= items.len) break; // one giant unit
                for (items[cut..next]) |*r| self.deinitRecord(r);
                cut = next;
            }
            if (cut == 0) return;
            self.retireFront(cut);
        }

        // -- introspection / memory pressure -----------------------------------

        /// Iterate undo/redo units oldest-first.
        pub fn units(self: *const Self) UnitIter {
            return .{ .j = self };
        }

        pub fn entryCount(self: *const Self) u32 {
            return @intCast(self.live().len);
        }

        /// Number of units that `undo` can unwind.
        pub fn undoDepth(self: *const Self) u32 {
            var n: u32 = 0;
            for (self.live()[0..self.head]) |r| {
                if (r.txn_start) n += 1;
            }
            return n;
        }

        /// Number of units that `redo` can replay.
        pub fn redoDepth(self: *const Self) u32 {
            var n: u32 = 0;
            for (self.live()[self.head..]) |r| {
                if (r.txn_start) n += 1;
            }
            return n;
        }

        /// Evict the oldest undo units until at most `keep` remain. Whole
        /// units only. Returns the number of entries dropped.
        pub fn trimUndo(self: *Self, keep: u32) u32 {
            var dropped: u32 = 0;
            while (self.undoDepth() > keep) {
                const items = self.live();
                var next: usize = 1;
                while (next < self.head and !items[next].txn_start) next += 1;
                for (items[0..next]) |*r| self.deinitRecord(r);
                self.retireFront(next);
                dropped += @intCast(next);
            }
            return dropped;
        }

        /// Drop everything that `redo` could replay. Returns entries dropped.
        pub fn dropRedo(self: *Self) u32 {
            const items = self.live();
            const n: u32 = @intCast(items.len - self.head);
            for (items[self.head..]) |*r| self.deinitRecord(r);
            self.entries.shrinkRetainingCapacity(self.start + self.head);
            return n;
        }

        // -- undo / redo ------------------------------------------------------

        pub fn canUndo(self: *const Self) bool {
            return self.head > 0;
        }

        pub fn canRedo(self: *const Self) bool {
            return self.head < self.live().len;
        }

        /// Yield the next entry of the undoable unit, newest-first. The
        /// undo region shrinks by whole units; `unit_done` flags the unit's
        /// oldest entry.
        pub fn nextUndo(self: *Self) ?UndoStep {
            if (self.head == 0) return null;
            self.head -= 1;
            const rec = self.live()[self.head];
            return .{ .entry = rec.e, .unit_done = rec.txn_start };
        }

        /// Yield the next entry of the redoable unit, oldest-first. The
        /// redo region always begins on a boundary; `unit_done` flags the
        /// unit's newest entry.
        pub fn nextRedo(self: *Self) ?RedoStep {
            const items = self.live();
            if (self.head >= items.len) return null;
            const rec = items[self.head];
            self.head += 1;
            const done = self.head >= items.len or items[self.head].txn_start;
            return .{ .entry = rec.e, .unit_done = done };
        }
    };
}
