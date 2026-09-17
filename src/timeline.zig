//! `Timeline(Domain)` — the feature history engine.
//!
//! Owns the ordered feature list, the marker (history slider position), the
//! visible document state, and the rebuild bookkeeping. Callers mutate the
//! timeline through commits/edits and read `state()` — caching and
//! incremental replay are implementation details behind that small surface.

const std = @import("std");
const ft = @import("root.zig");

/// Mixes into feature-id salts so separately created timelines (including in
/// different processes / peers) are unlikely to assign colliding ids.
var init_counter = std.atomic.Value(u64).init(0);

pub fn Timeline(comptime Domain: type) type {
    ft.validateDomain(Domain);
    const Feature = ft.Feature(Domain.Op);

    return struct {
        const Self = @This();

        pub const Doc = Domain.Doc;
        pub const Op = Domain.Op;
        pub const FeatureView = ft.FeatureView(Domain.Op);

        gpa: std.mem.Allocator,
        config: ft.Config,

        list: std.ArrayList(Feature) = .empty,

        /// Pristine seed document (position 0, before any feature).
        seed_doc: Doc,
        /// The visible document. Reflects `built_pos` features as of
        /// `built_version` (see `dirty`), or the last good state if broken.
        live_doc: Doc,

        /// Marker position: the document is the state after applying
        /// `features[0..marker]`. This is Fusion's timeline marker.
        marker_pos: u32 = 0,

        /// Bumped on every structural change (commit/edit/remove/suppress/
        /// reorder). Cached state records the version it was built at.
        version: u64 = 0,
        built_version: u64 = 0,
        /// Number of features applied to `live_doc` when `built_version` was
        /// current. While `broken == null` and versions match, a forward move
        /// of the marker can extend this incrementally; anything else
        /// rebuilds from a checkpoint or the seed.
        built_pos: u32 = 0,

        /// Set when a rebuild aborted with a hard error. The live document
        /// may be mid-mutation and untrusted; the next rebuild attempt starts
        /// fresh. `state()` keeps returning the live document pointer.
        broken: ?anyerror = null,

        next_id: ft.FeatureId,

        // ------------------------------------------------------------------
        // Lifecycle
        // ------------------------------------------------------------------

        pub fn init(gpa: std.mem.Allocator, seed_doc: Doc, config: ft.Config) !Self {
            const live = try Domain.cloneDoc(&seed_doc, gpa);
            // Random-looking id start so ids from independently created
            // timelines (e.g. different peers) are unlikely to collide.
            var prng = std.Random.DefaultPrng.init(idEntropy(&live));
            return .{
                .gpa = gpa,
                .config = config,
                .seed_doc = seed_doc,
                .live_doc = live,
                .next_id = prng.random().int(ft.FeatureId) | 1,
            };
        }

        fn idEntropy(anchor: *const anyopaque) u64 {
            const c = init_counter.fetchAdd(1, .monotonic);
            return @as(u64, @intFromPtr(anchor)) ^ (c << 32) ^ 0x9E3779B97F4A7C15;
        }

        pub fn deinit(self: *Self) void {
            self.resetStatuses(0);
            self.list.deinit(self.gpa);
            Domain.deinitDoc(&self.seed_doc, self.gpa);
            Domain.deinitDoc(&self.live_doc, self.gpa);
        }

        // ------------------------------------------------------------------
        // Playback (the slider)
        // ------------------------------------------------------------------

        /// Number of features on the timeline.
        pub fn len(self: *const Self) u32 {
            return @intCast(self.list.items.len);
        }

        /// Current marker position. The document is the state after applying
        /// `features[0..marker]`.
        pub fn marker(self: *const Self) u32 {
            return self.marker_pos;
        }

        /// Move the marker (clamped to `[0, len]`). Rebuilding happens lazily
        /// on the next `state()`.
        pub fn setMarker(self: *Self, pos: u32) void {
            self.marker_pos = @min(pos, self.list.items.len);
        }

        /// True when the visible document does not reflect `features[0..marker]`
        /// at the current version — i.e. `state()` has rebuild work to do.
        /// Also true while broken, so a broken timeline keeps retrying.
        pub fn dirty(self: *const Self) bool {
            return self.broken != null or
                self.built_version != self.version or
                self.built_pos != self.marker_pos;
        }

        /// The document at the marker: `features[0..marker]` applied to the
        /// seed. Rebuilds lazily and incrementally; the returned pointer is
        /// stable until the next rebuild.
        pub fn state(self: *Self) *const Doc {
            self.ensureRebuilt();
            return &self.live_doc;
        }

        // ------------------------------------------------------------------
        // Editing
        // ------------------------------------------------------------------

        /// Commit a feature at the marker, then advance the marker past it —
        /// Fusion semantics: committing while rolled back inserts the feature
        /// mid-history. Returns the new feature's stable id.
        ///
        /// If the timeline is exactly at a clean state, the feature is applied
        /// immediately; otherwise (or if a hard error occurs) the work is
        /// deferred to the next `state()`.
        pub fn commit(self: *Self, op: Op) error{OutOfMemory}!ft.FeatureId {
            const id = self.next_id;
            self.next_id +%= 1;
            const at = self.marker_pos;

            try self.list.insert(self.gpa, at, .{ .id = id, .op = op });

            // The inserted feature is `.pending` by default and the shifted
            // features now sit at/after the advanced marker; their old
            // statuses are meaningless. Free any failure messages they held.
            self.resetStatuses(at + 1);

            const prev_version = self.version;
            self.version += 1;
            self.marker_pos = at + 1;

            if (self.broken == null and self.built_version == prev_version and self.built_pos == at) {
                var applied: u32 = at;
                ft.rebuild.applyRange(Domain, self.list.items, at, at + 1, &self.live_doc, self.gpa, &applied) catch |err| {
                    // Hard failure: features before `at` are still good on the
                    // live doc, but this op may have partially mutated it.
                    // Flag broken so nothing touches it before a full rebuild.
                    self.broken = err;
                    return id;
                };
                self.built_pos = at + 1;
                self.built_version = self.version;
            }
            return id;
        }

        /// Suppress or unsuppress a feature. A suppressed feature stays on
        /// the timeline but is skipped by rebuilds. No-op if absent or
        /// already in the requested state.
        pub fn setSuppressed(self: *Self, id: ft.FeatureId, suppressed: bool) void {
            const idx = self.indexOf(id) orelse return;
            if (self.list.items[idx].suppressed == suppressed) return;
            self.list.items[idx].suppressed = suppressed;
            self.version += 1;
        }

        // ------------------------------------------------------------------
        // Inspection
        // ------------------------------------------------------------------

        pub const Iterator = struct {
            items: []const Feature,
            i: u32 = 0,

            pub fn next(self: *Iterator) ?FeatureView {
                if (self.i >= self.items.len) return null;
                const f = &self.items[self.i];
                self.i += 1;
                return .{
                    .id = f.id,
                    .op = &f.op,
                    .suppressed = f.suppressed,
                    .status = f.status,
                };
            }
        };

        /// Iterate features oldest-first. Statuses reflect the last completed
        /// rebuild (see `Status` for the validity rules).
        pub fn features(self: *const Self) Iterator {
            return .{ .items = self.list.items };
        }

        pub fn featureById(self: *const Self, id: ft.FeatureId) ?FeatureView {
            const idx = self.indexOf(id) orelse return null;
            const f = &self.list.items[idx];
            return .{ .id = f.id, .op = &f.op, .suppressed = f.suppressed, .status = f.status };
        }

        // ------------------------------------------------------------------
        // Rebuild internals
        // ------------------------------------------------------------------

        fn indexOf(self: *const Self, id: ft.FeatureId) ?u32 {
            for (self.list.items, 0..) |f, i| {
                if (f.id == id) return @intCast(i);
            }
            return null;
        }

        /// Drop recorded statuses (freeing failure messages) for features from
        /// `from` onward and mark them pending.
        fn resetStatuses(self: *Self, from: u32) void {
            for (self.list.items[@min(from, self.list.items.len)..]) |*f| {
                switch (f.status) {
                    .failed => |msg| self.gpa.free(msg),
                    else => {},
                }
                f.status = .pending;
            }
        }

        fn ensureRebuilt(self: *Self) void {
            if (self.broken == null and self.built_version == self.version and self.built_pos == self.marker_pos)
                return; // clean

            if (self.broken == null and self.built_version == self.version and self.built_pos < self.marker_pos) {
                // Incremental forward pass on the live document: the prefix
                // is valid, just apply the new suffix.
                self.resetStatuses(self.built_pos);
                var applied: u32 = self.built_pos;
                ft.rebuild.applyRange(Domain, self.list.items, self.built_pos, self.marker_pos, &self.live_doc, self.gpa, &applied) catch |err| {
                    self.broken = err;
                    self.built_pos = applied;
                    return;
                };
                self.built_pos = self.marker_pos;
                return;
            }

            // Full rebuild into a scratch document so a hard failure leaves
            // the live document (last good state) untouched.
            var scratch = Domain.cloneDoc(&self.seed_doc, self.gpa) catch |err| {
                self.broken = err;
                return;
            };
            self.resetStatuses(0);
            var applied: u32 = 0;
            ft.rebuild.applyRange(Domain, self.list.items, 0, self.marker_pos, &scratch, self.gpa, &applied) catch |err| {
                Domain.deinitDoc(&scratch, self.gpa);
                self.broken = err;
                return; // live_doc still holds the last good state
            };
            Domain.deinitDoc(&self.live_doc, self.gpa);
            self.live_doc = scratch;
            self.built_pos = self.marker_pos;
            self.built_version = self.version;
            self.broken = null;
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestDomain = struct {
    pub const Doc = struct {
        value: i64 = 0,
        steps: std.ArrayList(u8) = .empty,
    };
    pub const Op = union(enum) {
        add: i64,
        mul: i64,
        /// Soft-failing feature with a message.
        fail: []const u8,
        /// Hard-failing feature (simulates OutOfMemory-class trouble).
        poison: void,
    };
    pub fn apply(op: Op, doc: *Doc, ctx: *ft.ApplyContext) anyerror!void {
        switch (op) {
            .add => |n| {
                const sum = std.math.add(i64, doc.value, n) catch
                    return ctx.fail("add would overflow", .{});
                doc.value = sum;
                try doc.steps.append(ctx.alloc, '+');
            },
            .mul => |n| {
                const product = std.math.mul(i64, doc.value, n) catch
                    return ctx.fail("mul would overflow", .{});
                doc.value = product;
                try doc.steps.append(ctx.alloc, '*');
            },
            .fail => |msg| return ctx.fail("{s}", .{msg}),
            .poison => return error.Poison,
        }
    }
    pub fn cloneDoc(doc: *const Doc, gpa: std.mem.Allocator) anyerror!Doc {
        return .{
            .value = doc.value,
            .steps = try doc.steps.clone(gpa),
        };
    }
    pub fn deinitDoc(doc: *Doc, gpa: std.mem.Allocator) void {
        doc.steps.deinit(gpa);
    }
};

const TestTimeline = Timeline(TestDomain);

fn makeTimeline(gpa: std.mem.Allocator) !TestTimeline {
    return TestTimeline.init(gpa, .{}, .{});
}

test "empty timeline serves the seed document" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    try std.testing.expectEqual(@as(u32, 0), tl.len());
    try std.testing.expectEqual(@as(u32, 0), tl.marker());
    try std.testing.expect(!tl.dirty());
    try std.testing.expectEqual(@as(i64, 0), tl.state().value);
}

test "commit and scrub the marker" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    _ = try tl.commit(.{ .add = 1 });
    _ = try tl.commit(.{ .add = 2 });
    _ = try tl.commit(.{ .add = 3 });
    try std.testing.expectEqual(@as(u32, 3), tl.marker());

    try std.testing.expectEqual(@as(i64, 6), tl.state().value);

    tl.setMarker(1);
    try std.testing.expectEqual(@as(i64, 1), tl.state().value);

    tl.setMarker(2);
    try std.testing.expectEqual(@as(i64, 3), tl.state().value);

    tl.setMarker(3);
    try std.testing.expectEqual(@as(i64, 6), tl.state().value);

    tl.setMarker(999); // clamped
    try std.testing.expectEqual(@as(u32, 3), tl.marker());
}

test "commit while rolled back inserts at the marker" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    _ = try tl.commit(.{ .add = 1 });
    _ = try tl.commit(.{ .add = 2 });
    _ = try tl.commit(.{ .add = 3 });

    tl.setMarker(1);
    const inserted = try tl.commit(.{ .mul = 10 }); // inserts at index 1
    try std.testing.expectEqual(@as(u32, 2), tl.marker());

    tl.setMarker(tl.len());
    try std.testing.expectEqual(@as(i64, (1 * 10) + 2 + 3), tl.state().value);

    const f = tl.featureById(inserted).?;
    try std.testing.expectEqual(TestDomain.Op{ .mul = 10 }, f.op.*);
}

test "suppress skips a feature but keeps it on the timeline" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    _ = try tl.commit(.{ .add = 1 });
    const second = try tl.commit(.{ .add = 2 });
    _ = try tl.commit(.{ .add = 3 });
    try std.testing.expectEqual(@as(i64, 6), tl.state().value);

    tl.setSuppressed(second, true);
    try std.testing.expectEqual(@as(i64, 4), tl.state().value);
    try std.testing.expectEqual(@as(u32, 3), tl.len());

    tl.setSuppressed(second, false);
    try std.testing.expectEqual(@as(i64, 6), tl.state().value);
}

test "soft failure records status and the timeline continues" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    _ = try tl.commit(.{ .add = 1 });
    _ = try tl.commit(.{ .fail = "edge 12 no longer exists" });
    _ = try tl.commit(.{ .add = 3 });

    try std.testing.expectEqual(@as(i64, 4), tl.state().value);

    var statuses: [3]ft.Status = undefined;
    var it = tl.features();
    for (&statuses) |*s| s.* = it.next().?.status;
    try std.testing.expectEqual(ft.Status.ok, statuses[0]);
    try std.testing.expectEqualStrings("edge 12 no longer exists", statuses[1].failed);
    try std.testing.expectEqual(ft.Status.ok, statuses[2]);
}

test "soft failure keeps the failed feature's mutation out of the doc" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    _ = try tl.commit(.{ .add = 5 });
    _ = try tl.commit(.{ .add = std.math.maxInt(i64) }); // overflows: soft-fails, value unchanged
    _ = try tl.commit(.{ .add = 2 });

    try std.testing.expectEqual(@as(i64, 7), tl.state().value);
}

test "hard failure breaks the timeline but keeps the last good state" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    _ = try tl.commit(.{ .add = 5 });
    _ = try tl.commit(.{ .poison = {} });

    try std.testing.expectEqual(@as(i64, 5), tl.state().value);
    try std.testing.expect(tl.broken != null);
    try std.testing.expect(tl.dirty());

    // Recovery: moving the marker retries the rebuild from scratch.
    tl.setMarker(1);
    try std.testing.expectEqual(@as(i64, 5), tl.state().value);
    try std.testing.expect(tl.broken == null);
    try std.testing.expect(!tl.dirty());
}

test "statuses beyond the marker are pending" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    _ = try tl.commit(.{ .add = 1 });
    _ = try tl.commit(.{ .add = 2 });
    _ = try tl.commit(.{ .add = 3 });
    _ = tl.state();

    tl.setMarker(1);
    _ = tl.state();

    var it = tl.features();
    _ = it.next().?; // feature 0: applied
    try std.testing.expectEqual(ft.Status.pending, it.next().?.status);
    try std.testing.expectEqual(ft.Status.pending, it.next().?.status);
}

test "dirty transitions" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    try std.testing.expect(!tl.dirty());
    _ = try tl.commit(.{ .add = 1 });
    try std.testing.expect(!tl.dirty()); // fast path applied it immediately
    tl.setMarker(0);
    try std.testing.expect(tl.dirty());
    _ = tl.state();
    try std.testing.expect(!tl.dirty());
}
