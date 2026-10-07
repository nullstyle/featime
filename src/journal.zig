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
            },
            suppress: struct { id: ft.FeatureId, prev: bool },
            move: struct { id: ft.FeatureId, from: u32, to: u32, marker_pre: u32 },
            name_set: struct { id: ft.FeatureId, old: ?[]const u8, new: ?[]const u8 },
            chapter_add: struct { chapter: annotations.Chapter },
            chapter_remove: struct { chapter: annotations.Chapter },
            chapter_rename: struct { id: annotations.ChapterId, old: []const u8, new: []const u8 },
        };

        gpa: std.mem.Allocator,
        max: u32,
        entries: std.ArrayList(Entry) = .empty,
        head: usize = 0,

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
                },
                .name_set => |n| {
                    if (n.old) |o| self.gpa.free(o);
                    if (n.new) |x| self.gpa.free(x);
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
