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
        /// Where document copies live (`Config.doc_allocator` or `gpa`);
        /// status copies stay on `gpa`.
        doc_gpa: std.mem.Allocator,
        max: u8,
        entries: std.ArrayList(Entry) = .empty,
        /// Positions whose checkpoints eviction and `trimTo` must keep, and
        /// that do not count against `max`. The timeline sets them from its
        /// pins before any operation that may evict (`Timeline.syncPins`).
        pinned: std.ArrayList(u32) = .empty,

        pub fn init(gpa: std.mem.Allocator, doc_gpa: std.mem.Allocator, max: u8) Self {
            return .{ .gpa = gpa, .doc_gpa = doc_gpa, .max = max };
        }

        pub fn deinit(self: *Self) void {
            for (self.entries.items) |*e| self.destroyEntry(e);
            self.entries.deinit(self.gpa);
            self.pinned.deinit(self.gpa);
        }

        pub fn isPinned(self: *const Self, pos: u32) bool {
            return std.mem.indexOfScalar(u32, self.pinned.items, pos) != null;
        }

        fn unpinnedCount(self: *const Self) usize {
            var n: usize = 0;
            for (self.entries.items) |e| {
                if (!self.isPinned(e.pos)) n += 1;
            }
            return n;
        }

        /// Make room for one more unpinned entry: evict the oldest unpinned
        /// ones while the unpinned count is at `max`.
        fn makeRoom(self: *Self) void {
            while (self.unpinnedCount() >= self.max) {
                var victim: ?usize = null;
                for (self.entries.items, 0..) |e, i| {
                    if (!self.isPinned(e.pos)) {
                        victim = i;
                        break;
                    }
                }
                const i = victim orelse return;
                var dead = self.entries.orderedRemove(i);
                self.destroyEntry(&dead);
            }
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

        pub fn count(self: *const Self) u32 {
            return @intCast(self.entries.items.len);
        }

        /// Keep at most `keep` checkpoints, preferring the ones nearest
        /// `marker` (ties drop the older position). Returns how many were
        /// dropped. The configured `max` is unchanged; this is a one-off
        /// release of memory.
        pub fn trimTo(self: *Self, keep: u8, marker: u32) u32 {
            var dropped: u32 = 0;
            while (self.unpinnedCount() > keep) {
                var worst: ?usize = null;
                var worst_d: u64 = 0;
                for (self.entries.items, 0..) |e, i| {
                    if (self.isPinned(e.pos)) continue;
                    const d: u64 = if (e.pos > marker) e.pos - marker else marker - e.pos;
                    const further = d > worst_d or (d == worst_d and e.pos < self.entries.items[worst.?].pos);
                    if (worst == null or further) {
                        worst = i;
                        worst_d = d;
                    }
                }
                var dead = self.entries.orderedRemove(worst.?);
                self.destroyEntry(&dead);
                dropped += 1;
            }
            return dropped;
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
                .doc = ft.cloneDoc(Domain, doc, self.doc_gpa) catch return,
                .statuses = &.{},
            };
            entry.statuses = self.cloneStatuses(features[0..pos]) catch {
                var dead = entry.doc;
                ft.deinitDoc(Domain, &dead, self.doc_gpa);
                return;
            };
            self.makeRoom();
            self.entries.append(self.gpa, entry) catch {
                var full = entry;
                self.destroyEntry(&full);
            };
        }

        /// Store an already-owned document and status array as the
        /// checkpoint at `pos` (ownership moves in, even on failure). An
        /// existing entry at the position is replaced.
        pub fn addOwned(self: *Self, pos: u32, doc: Doc, statuses: []ft.Status) void {
            var entry: Entry = .{ .pos = pos, .doc = doc, .statuses = statuses };
            if (self.max == 0) {
                self.destroyEntry(&entry);
                return;
            }
            if (self.indexOfPos(pos)) |i| {
                var dead = self.entries.orderedRemove(i);
                self.destroyEntry(&dead);
            }
            self.makeRoom();
            self.entries.append(self.gpa, entry) catch {
                self.destroyEntry(&entry);
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
            ft.deinitDoc(Domain, &e.doc, self.doc_gpa);
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
