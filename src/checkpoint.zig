//! Internal seam: the checkpoint cache.
//!
//! A checkpoint is a full document plus the matching feature statuses,
//! taken at a timeline position: `doc` is the seed with `features[0..pos]`
//! applied. Checkpoints are pure optimization — every query falls back to
//! the seed — so all allocation failures degrade to "skip the checkpoint".
//!
//! Validity: a structural mutation at feature index `i` changes the replay
//! of every position after `i`, so `noteMutation(i)` drops every checkpoint
//! with `pos > i`. Surviving checkpoints are always safe to replay from.

const std = @import("std");
const ft = @import("root.zig");

pub fn Checkpoints(comptime Domain: type) type {
    const Doc = Domain.Doc;

    return struct {
        const Self = @This();

        pub const Entry = struct {
            pos: u32,
            doc: Doc,
            /// Statuses of `features[0..pos]` at snapshot time. Message
            /// memory is owned by the entry.
            statuses: []ft.Status,
        };

        gpa: std.mem.Allocator,
        max: u8,
        entries: std.ArrayList(Entry) = .empty,

        pub fn init(gpa: std.mem.Allocator, max: u8) Self {
            return .{ .gpa = gpa, .max = max };
        }

        pub fn deinit(self: *Self) void {
            for (self.entries.items) |*e| self.destroyEntry(e);
            self.entries.deinit(self.gpa);
        }

        /// Drop checkpoints invalidated by a structural mutation at `index`.
        pub fn noteMutation(self: *Self, index: u32) void {
            var i: usize = 0;
            while (i < self.entries.items.len) {
                if (self.entries.items[i].pos > index) {
                    var dead = self.entries.orderedRemove(i);
                    self.destroyEntry(&dead);
                } else i += 1;
            }
        }

        /// The closest checkpoint at or before `pos`, or null.
        pub fn bestBefore(self: *Self, pos: u32) ?*Entry {
            var best: ?*Entry = null;
            for (self.entries.items) |*e| {
                if (e.pos <= pos and (best == null or e.pos > best.?.pos)) best = e;
            }
            return best;
        }

        /// Remove and return the checkpoint exactly at `pos`, if any.
        /// Ownership of the doc and status messages transfers to the caller.
        pub fn takeExact(self: *Self, pos: u32) ?Entry {
            for (self.entries.items, 0..) |e, i| {
                if (e.pos == pos) return self.entries.orderedRemove(i);
            }
            return null;
        }

        /// Snapshot `doc` at `pos`, taking statuses from `features[0..pos]`.
        /// Best effort: silently skips on capacity 0 or allocation failure.
        /// An existing entry at the same position is replaced.
        pub fn add(self: *Self, pos: u32, doc: *const Doc, features: []const ft.Feature(Domain.Op)) void {
            if (self.max == 0) return;
            // Replace any existing entry at this position (positions stay
            // unique so `takeExact` is unambiguous).
            if (self.indexOfPos(pos)) |i| {
                var dead = self.entries.orderedRemove(i);
                self.destroyEntry(&dead);
            }
            var entry: Entry = .{
                .pos = pos,
                .doc = ft.cloneDoc(Domain, doc, self.gpa) catch return,
                .statuses = &.{},
            };
            entry.statuses = self.cloneStatuses(features[0..pos]) catch {
                var dead = entry.doc;
                ft.deinitDoc(Domain, &dead, self.gpa);
                return;
            };
            while (self.entries.items.len >= self.max) {
                var dead = self.entries.orderedRemove(0);
                self.destroyEntry(&dead);
            }
            self.entries.append(self.gpa, entry) catch {
                var full = entry;
                self.destroyEntry(&full);
            };
        }

        fn indexOfPos(self: *const Self, pos: u32) ?usize {
            for (self.entries.items, 0..) |e, i| {
                if (e.pos == pos) return i;
            }
            return null;
        }

        fn destroyEntry(self: *Self, e: *Entry) void {
            for (e.statuses) |s| switch (s) {
                .failed => |msg| self.gpa.free(msg),
                else => {},
            };
            self.gpa.free(e.statuses);
            ft.deinitDoc(Domain, &e.doc, self.gpa);
        }

        fn cloneStatuses(self: *Self, features: []const ft.Feature(Domain.Op)) ![]ft.Status {
            const out = try self.gpa.alloc(ft.Status, features.len);
            var filled: usize = 0;
            errdefer {
                for (out[0..filled]) |s| switch (s) {
                    .failed => |msg| self.gpa.free(msg),
                    else => {},
                };
                self.gpa.free(out);
            }
            for (features, 0..) |f, i| {
                out[i] = switch (f.status) {
                    .failed => |msg| .{ .failed = try self.gpa.dupe(u8, msg) },
                    else => f.status,
                };
                filled = i + 1;
            }
            return out;
        }
    };
}
