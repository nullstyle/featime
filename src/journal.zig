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

const std = @import("std");
const ft = @import("root.zig");

pub fn Journal(comptime Op: type) type {
    return struct {
        const Self = @This();

        pub const Entry = union(enum) {
            commit: struct { id: ft.FeatureId, op: Op, at: u32 },
            edit: struct { id: ft.FeatureId, old_op: Op, new_op: Op },
            remove: struct { id: ft.FeatureId, op: Op, at: u32, suppressed: bool, marker_pre: u32 },
            suppress: struct { id: ft.FeatureId, prev: bool },
        };

        gpa: std.mem.Allocator,
        max: u32,
        entries: std.ArrayList(Entry) = .empty,
        head: usize = 0,

        pub fn init(gpa: std.mem.Allocator, max: u32) Self {
            return .{ .gpa = gpa, .max = max };
        }

        pub fn deinit(self: *Self) void {
            self.entries.deinit(self.gpa);
        }

        pub fn record(self: *Self, entry: Entry) void {
            if (self.max == 0) return;
            self.entries.shrinkRetainingCapacity(self.head);
            self.entries.append(self.gpa, entry) catch {
                // Out of memory: drop history rather than keep a journal
                // that lies about the timeline's past.
                self.entries.clearRetainingCapacity();
                self.head = 0;
                return;
            };
            self.head += 1;
            if (self.entries.items.len > self.max) {
                _ = self.entries.orderedRemove(0);
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
