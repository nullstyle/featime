//! `Timeline(Domain)` — the feature history engine.
//!
//! Owns the ordered feature list, the marker (history slider position), the
//! visible document state, and the rebuild bookkeeping. Callers mutate the
//! timeline through commits/edits and read `state()` — caching and
//! incremental replay are implementation details behind that small surface.

const std = @import("std");
const ft = @import("root.zig");
const checkpoint = @import("checkpoint.zig");
const journaling = @import("journal.zig");

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
        /// The visible document: the seed with `features[0..built_pos]`
        /// applied (when `!live_stale and broken == null`), or the last good
        /// state if a rebuild is pending or failed.
        live_doc: Doc,

        /// Marker position: the document is the state after applying
        /// `features[0..marker]`. This is Fusion's timeline marker.
        marker_pos: u32 = 0,

        /// Number of features applied to `live_doc`. While `!live_stale`,
        /// moving the marker forward can extend this incrementally.
        built_pos: u32 = 0,

        /// True when a structural change touched a feature below `built_pos`:
        /// the old suffix effects are baked into `live_doc` and it cannot be
        /// extended; a checkpoint/seed rebuild is required.
        live_stale: bool = false,

        /// Set when a rebuild aborted with a hard error. The live document
        /// may be mid-mutation and untrusted; the next rebuild attempt starts
        /// fresh. `state()` keeps returning the live document pointer.
        broken: ?anyerror = null,

        next_id: ft.FeatureId,

        /// Generation counter: bumped by every mutation (structural edits and
        /// marker moves). Background jobs capture it at begin time;
        /// `integrate` rejects results whose generation went stale.
        gen: u64 = 0,

        /// Document checkpoint cache (internal).
        cps: checkpoint.Checkpoints(Domain),

        /// Undo/redo journal (internal).
        journal: journaling.Journal(Op),

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
                .cps = checkpoint.Checkpoints(Domain).init(gpa, config.max_checkpoints),
                .journal = journaling.Journal(Op).init(gpa, config.max_journal),
            };
        }

        fn idEntropy(anchor: *const anyopaque) u64 {
            const c = init_counter.fetchAdd(1, .monotonic);
            return @as(u64, @intFromPtr(anchor)) ^ (c << 32) ^ 0x9E3779B97F4A7C15;
        }

        pub fn deinit(self: *Self) void {
            self.resetStatuses(0);
            self.list.deinit(self.gpa);
            self.cps.deinit();
            self.journal.deinit();
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
        /// on the next `state()`. When leaving a clean position, the current
        /// state is snapshotted so scrubbing back to it costs nothing.
        pub fn setMarker(self: *Self, pos: u32) void {
            const target = @min(pos, self.list.items.len);
            if (target == self.marker_pos) return;
            self.touch();
            if (self.config.checkpoint_on_scrub and !self.dirty()) {
                self.cps.add(self.marker_pos, &self.live_doc, self.list.items);
            }
            self.marker_pos = target;
        }

        /// True when the visible document does not reflect `features[0..marker]`
        /// — i.e. `state()` has rebuild work to do. Also true while broken,
        /// so a broken timeline keeps retrying.
        pub fn dirty(self: *const Self) bool {
            return self.broken != null or
                self.live_stale or
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
            self.touch();
            const id = self.next_id;
            self.next_id +%= 1;
            const at = self.marker_pos;

            try self.list.insert(self.gpa, at, .{ .id = id, .op = op });
            self.journal.record(.{ .commit = .{ .id = id, .op = op, .at = at } });
            self.afterInsert(at);
            return id;
        }

        /// Bookkeeping after a feature lands at `at` (shared by commit and
        /// journal redo).
        fn afterInsert(self: *Self, at: u32) void {
            self.cps.noteMutation(at);
            // The inserted feature is `.pending` by default and the shifted
            // features now sit at/after the advanced marker; their old
            // statuses are meaningless. Free any failure messages they held.
            self.resetStatuses(at + 1);
            self.marker_pos = at + 1;
            if (at < self.built_pos) self.live_stale = true;

            if (self.broken == null and !self.live_stale and self.built_pos == at) {
                var applied: u32 = at;
                ft.rebuild.applyRange(Domain, self.list.items, at, at + 1, &self.live_doc, self.gpa, &applied) catch |err| {
                    // Hard failure: features before `at` are still good on the
                    // live doc, but this op may have partially mutated it.
                    // Flag broken so nothing touches it before a full rebuild.
                    self.broken = err;
                    return;
                };
                self.built_pos = at + 1;
            }
        }

        /// Replace a feature's parameters (Fusion's "edit feature"). The
        /// feature keeps its id and position; the document recomputes lazily
        /// from the nearest surviving checkpoint. No-op if absent.
        pub fn edit(self: *Self, id: ft.FeatureId, new_op: Op) void {
            self.touch();
            const idx = self.indexOf(id) orelse return;
            const old_op = self.list.items[idx].op;
            self.journal.record(.{ .edit = .{ .id = id, .old_op = old_op, .new_op = new_op } });
            self.list.items[idx].op = new_op;
            self.invalidate(idx);
        }

        /// Remove a feature from the timeline. The marker adjusts so the
        /// visible document stays consistent. No-op if absent.
        pub fn remove(self: *Self, id: ft.FeatureId) void {
            self.touch();
            const idx = self.indexOf(id) orelse return;
            const f = self.list.items[idx];
            self.journal.record(.{ .remove = .{
                .id = id,
                .op = f.op,
                .at = idx,
                .suppressed = f.suppressed,
                .marker_pre = self.marker_pos,
            } });
            self.resetStatuses(idx);
            _ = self.list.orderedRemove(idx);
            if (idx < self.marker_pos) self.marker_pos -= 1;
            self.invalidate(idx);
        }

        /// Suppress or unsuppress a feature. A suppressed feature stays on
        /// the timeline but is skipped by rebuilds. No-op if absent or
        /// already in the requested state.
        pub fn setSuppressed(self: *Self, id: ft.FeatureId, suppressed: bool) void {
            self.touch();
            const idx = self.indexOf(id) orelse return;
            const prev = self.list.items[idx].suppressed;
            if (prev == suppressed) return;
            self.journal.record(.{ .suppress = .{ .id = id, .prev = prev } });
            self.list.items[idx].suppressed = suppressed;
            self.invalidate(idx);
        }

        /// Reorder a feature to `new_pos` (clamped to the list; interpreted
        /// as the index in the resulting list, Fusion's drag semantics).
        ///
        /// When the Domain provides the optional `dependencies` hook, the
        /// move is validated first and `error.DependencyViolation` is
        /// returned — before any mutation — if it would place a dependency
        /// after a feature that reads it. Without the hook every move is
        /// allowed and breakage surfaces as failed features on rebuild,
        /// exactly like Fusion. No-op if absent or already in position.
        pub fn move(self: *Self, id: ft.FeatureId, new_pos: u32) MoveError!void {
            self.touch();
            const from = self.indexOf(id) orelse return;
            const to = @min(new_pos, @as(u32, @intCast(self.list.items.len - 1)));
            if (from == to) return;

            if (comptime hasDeps(Domain)) {
                if (self.depsViolated(from, to)) return error.DependencyViolation;
            }

            self.journal.record(.{ .move = .{
                .id = id,
                .from = from,
                .to = to,
                .marker_pre = self.marker_pos,
            } });
            self.rawMove(id, to);
        }

        pub const MoveError = error{ DependencyViolation, OutOfMemory };

        fn hasDeps(comptime D: type) bool {
            return @hasDecl(D, "dependencies");
        }

        /// Would moving `from -> to` put any feature after one of its
        /// dependencies? Simulates the reorder with an index remap.
        fn depsViolated(self: *Self, from: u32, to: u32) bool {
            var collector: ft.DepCollector = .{ .gpa = self.gpa };
            defer collector.ids.deinit(self.gpa);
            for (self.list.items, 0..) |f, i| {
                collector.ids.clearRetainingCapacity();
                Domain.dependencies(f.op, &collector);
                if (collector.failed) return false; // can't validate: allow
                const mapped_i = remapIndex(@intCast(i), from, to);
                for (collector.ids.items) |dep_id| {
                    const j = self.indexOf(dep_id) orelse continue;
                    if (j == i) continue; // self-reference is not ordering
                    if (remapIndex(j, from, to) >= mapped_i) return true;
                }
            }
            return false;
        }

        fn remapIndex(i: u32, from: u32, to: u32) u32 {
            if (i == from) return to;
            if (from < to) return if (i > from and i <= to) i - 1 else i;
            return if (i >= to and i < from) i + 1 else i;
        }

        /// Reorder without validation or journaling (also used by undo/redo).
        fn rawMove(self: *Self, id: ft.FeatureId, to: u32) void {
            const from = self.indexOf(id) orelse return;
            if (from == to) return;
            const lo = @min(from, to);
            self.resetStatuses(lo);
            const feature = self.list.orderedRemove(from);
            self.list.insert(self.gpa, to, feature) catch {
                // Out of memory re-inserting: restore it where it was.
                self.list.insert(self.gpa, from, feature) catch unreachable;
                return;
            };
            // The marker counts applied features: adjust when the feature
            // crosses the applied/unapplied boundary.
            if (from < self.marker_pos and to >= self.marker_pos) {
                self.marker_pos -= 1;
            } else if (from >= self.marker_pos and to < self.marker_pos) {
                self.marker_pos += 1;
            }
            self.cps.noteMutation(lo);
            if (lo < self.built_pos) self.live_stale = true;
        }

        // ------------------------------------------------------------------
        // Undo / redo
        // ------------------------------------------------------------------

        pub fn canUndo(self: *const Self) bool {
            return self.journal.canUndo();
        }

        pub fn canRedo(self: *const Self) bool {
            return self.journal.canRedo();
        }

        /// Undo the most recent timeline edit. The marker restores to where
        /// it was when that edit was made (marker moves themselves are not
        /// journaled — scrubbing is free and never erodes undo depth).
        /// Returns false when there is nothing to undo.
        pub fn undo(self: *Self) bool {
            const entry = self.journal.nextUndo() orelse return false;
            self.touch();
            self.reverse(entry);
            return true;
        }

        /// Re-apply the most recently undone edit. Returns false when there
        /// is nothing to redo.
        pub fn redo(self: *Self) bool {
            const entry = self.journal.nextRedo() orelse return false;
            self.touch();
            self.forward(entry);
            return true;
        }

        fn reverse(self: *Self, entry: journaling.Journal(Op).Entry) void {
            switch (entry) {
                .commit => |e| {
                    const idx = self.indexOf(e.id) orelse return;
                    self.resetStatuses(idx);
                    _ = self.list.orderedRemove(idx);
                    self.marker_pos = e.at;
                    self.invalidate(idx);
                },
                .edit => |e| {
                    const idx = self.indexOf(e.id) orelse return;
                    self.list.items[idx].op = e.old_op;
                    self.invalidate(idx);
                },
                .remove => |e| {
                    self.list.insert(self.gpa, e.at, .{
                        .id = e.id,
                        .op = e.op,
                        .suppressed = e.suppressed,
                    }) catch return;
                    self.afterInsert(e.at);
                    self.marker_pos = @min(e.marker_pre, @as(u32, @intCast(self.list.items.len)));
                },
                .suppress => |e| {
                    const idx = self.indexOf(e.id) orelse return;
                    self.list.items[idx].suppressed = e.prev;
                    self.invalidate(idx);
                },
                .move => |e| {
                    self.rawMove(e.id, e.from);
                    // Restore the pre-move marker (rawMove's crossing
                    // adjustment started from the post-undo marker).
                    self.marker_pos = e.marker_pre;
                },
            }
        }

        fn forward(self: *Self, entry: journaling.Journal(Op).Entry) void {
            switch (entry) {
                .commit => |e| {
                    self.list.insert(self.gpa, e.at, .{ .id = e.id, .op = e.op }) catch return;
                    self.afterInsert(e.at);
                },
                .edit => |e| {
                    const idx = self.indexOf(e.id) orelse return;
                    self.list.items[idx].op = e.new_op;
                    self.invalidate(idx);
                },
                .remove => |e| {
                    const idx = self.indexOf(e.id) orelse return;
                    self.resetStatuses(idx);
                    _ = self.list.orderedRemove(idx);
                    self.marker_pos = if (e.at < e.marker_pre) e.marker_pre - 1 else e.marker_pre;
                    self.invalidate(idx);
                },
                .suppress => |e| {
                    const idx = self.indexOf(e.id) orelse return;
                    self.list.items[idx].suppressed = !e.prev;
                    self.invalidate(idx);
                },
                .move => |e| self.rawMove(e.id, e.to),
            }
        }

        /// Shared tail for structural mutations at `idx`: statuses from `idx`
        /// on are stale, checkpoints past `idx` are invalid, and the live
        /// document is stale if the mutation sits below the applied region
        /// (its old suffix effects are baked in and cannot be un-applied).
        fn invalidate(self: *Self, idx: u32) void {
            self.resetStatuses(idx);
            self.cps.noteMutation(idx);
            if (idx < self.built_pos) self.live_stale = true;
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
        // Background rebuild
        // ------------------------------------------------------------------

        /// Capture the current rebuild as a pure job (heavy documents: the
        /// base comes from a consumed checkpoint, not a copy). `run()` it on
        /// any thread, then `integrate()` here. The timeline stays dirty until
        /// integration; the synchronous `state()` remains available as a
        /// fallback and produces identical results.
        pub fn beginRebuild(self: *Self) anyerror!ft.rebuild.Job(Domain) {
            var start_pos: u32 = 0;
            var base: Domain.Doc = undefined;
            var have_base = false;
            if (self.cps.bestBefore(self.marker_pos)) |e| {
                if (e.pos > 0) {
                    const taken = self.cps.takeExact(e.pos).?;
                    // The checkpoint's doc transfers to the job; its status
                    // copies are simply dropped.
                    for (taken.statuses) |st| switch (st) {
                        .failed => |msg| self.gpa.free(msg),
                        else => {},
                    };
                    self.gpa.free(taken.statuses);
                    base = taken.doc;
                    start_pos = taken.pos;
                    have_base = true;
                }
            }
            if (!have_base) base = try Domain.cloneDoc(&self.seed_doc, self.gpa);
            errdefer Domain.deinitDoc(&base, self.gpa);

            const features_copy = try self.gpa.dupe(ft.Feature(Op), self.list.items);
            errdefer self.gpa.free(features_copy);
            for (features_copy) |*f| f.status = .pending;

            return .{
                .gpa = self.gpa,
                .generation = self.gen,
                .target = self.marker_pos,
                .start_pos = start_pos,
                .applied = start_pos,
                .base = base,
                .features = features_copy,
            };
        }

        /// Install a finished job's result (owner thread only). The job is
        /// consumed either way. True when installed; false when stale,
        /// cancelled, or failed — a failed-but-fresh job marks the timeline
        /// broken, exactly like a synchronous rebuild.
        pub fn integrate(self: *Self, job: *ft.rebuild.Job(Domain)) bool {
            if (job.generation != self.gen) {
                job.deinit();
                return false;
            }
            switch (job.state) {
                .done => {},
                .failed => {
                    self.broken = job.err;
                    job.deinit();
                    return false;
                },
                else => {
                    job.deinit();
                    return false;
                },
            }
            Domain.deinitDoc(&self.live_doc, self.gpa);
            self.live_doc = job.base;
            self.resetStatuses(job.start_pos);
            var i: u32 = job.start_pos;
            while (i < job.target) : (i += 1) {
                // Status message ownership transfers to the timeline.
                self.list.items[i].status = job.features[i].status;
            }
            self.gpa.free(job.features);
            job.features = &.{};
            job.state = .consumed;
            self.built_pos = self.marker_pos;
            self.live_stale = false;
            self.broken = null;
            return true;
        }

        // ------------------------------------------------------------------
        // Rebuild internals
        // ------------------------------------------------------------------

        fn touch(self: *Self) void {
            self.gen += 1;
        }

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
            if (!self.dirty()) return; // clean

            // 1. Exact checkpoint restore — the slider fast path. Scrubbing
            //    back to a snapshotted position costs zero applies.
            if (self.cps.takeExact(self.marker_pos)) |taken| {
                Domain.deinitDoc(&self.live_doc, self.gpa);
                self.live_doc = taken.doc;
                self.resetStatuses(0);
                for (taken.statuses, 0..) |s, i| self.list.items[i].status = s;
                self.gpa.free(taken.statuses);
                self.built_pos = self.marker_pos;
                self.live_stale = false;
                self.broken = null;
                return;
            }

            // 2. Incremental forward pass on the live document: the prefix
            //    is valid, just apply the new suffix.
            if (self.broken == null and !self.live_stale and self.built_pos < self.marker_pos) {
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

            // 3. Rebuild into a scratch document from the best checkpoint (or
            //    the seed), so a hard failure leaves the live document (last
            //    good state) untouched. Interval checkpoints taken along the
            //    way keep future dirty-range replays short.
            var start: u32 = 0;
            var base: *const Doc = &self.seed_doc;
            if (self.cps.bestBefore(self.marker_pos)) |e| {
                if (e.pos > start) {
                    start = e.pos;
                    base = &e.doc;
                }
            }
            var scratch = Domain.cloneDoc(base, self.gpa) catch |err| {
                self.broken = err;
                return;
            };
            self.resetStatuses(start);
            var pos: u32 = start;
            while (pos < self.marker_pos) {
                const end = if (self.config.checkpoint_interval > 0)
                    @min(pos + self.config.checkpoint_interval, self.marker_pos)
                else
                    self.marker_pos;
                var applied: u32 = pos;
                ft.rebuild.applyRange(Domain, self.list.items, pos, end, &scratch, self.gpa, &applied) catch |err| {
                    Domain.deinitDoc(&scratch, self.gpa);
                    self.broken = err;
                    return; // live_doc still holds the last good state
                };
                pos = end;
                if (end < self.marker_pos) {
                    self.cps.add(end, &scratch, self.list.items);
                }
            }
            Domain.deinitDoc(&self.live_doc, self.gpa);
            self.live_doc = scratch;
            self.built_pos = self.marker_pos;
            self.live_stale = false;
            self.broken = null;
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Global count of successful feature applications, for asserting that the
/// checkpoint cache avoids replay work.
var g_applies: usize = 0;

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
                g_applies += 1;
                try doc.steps.append(ctx.alloc, '+');
            },
            .mul => |n| {
                const product = std.math.mul(i64, doc.value, n) catch
                    return ctx.fail("mul would overflow", .{});
                doc.value = product;
                g_applies += 1;
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

test "edit recomputes downstream, keeping id and position" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    const first = try tl.commit(.{ .add = 1 });
    _ = try tl.commit(.{ .add = 2 });
    _ = try tl.commit(.{ .add = 3 });
    try std.testing.expectEqual(@as(i64, 6), tl.state().value);

    tl.edit(first, .{ .add = 10 });
    try std.testing.expectEqual(@as(i64, 15), tl.state().value);

    const f = tl.featureById(first).?;
    try std.testing.expectEqual(TestDomain.Op{ .add = 10 }, f.op.*);
}

test "edit replays only the dirty suffix from a checkpoint" {
    const gpa = std.testing.allocator;
    var tl = try TestTimeline.init(gpa, .{}, .{
        .checkpoint_interval = 2,
        .max_checkpoints = 8,
        .checkpoint_on_scrub = true,
    });
    defer tl.deinit();

    var ids: [8]ft.FeatureId = undefined;
    for (&ids, 0..) |*slot, i| {
        slot.* = try tl.commit(.{ .add = @intCast(i + 1) });
    }
    try std.testing.expectEqual(@as(i64, 36), tl.state().value);
    g_applies = 0;

    // Edit feature 0: nothing below any checkpoint survives, so the rebuild
    // replays all 8 — and lays down interval checkpoints at 2, 4, 6.
    tl.edit(ids[0], .{ .add = 100 });
    _ = tl.state();
    try std.testing.expectEqual(@as(i64, 135), tl.state().value);
    try std.testing.expectEqual(@as(usize, 8), g_applies);

    // Edit feature 5: the checkpoint at 4 survives; only features 4..7 replay.
    g_applies = 0;
    tl.edit(ids[5], .{ .add = 50 });
    _ = tl.state();
    try std.testing.expectEqual(@as(usize, 4), g_applies);

    // Scrub back to 6: an exact checkpoint exists (taken at 6) — zero applies.
    g_applies = 0;
    tl.setMarker(6);
    _ = tl.state();
    try std.testing.expectEqual(@as(usize, 0), g_applies);

    // And forward to 8: the snapshot at 8 restores instantly.
    g_applies = 0;
    tl.setMarker(8);
    _ = tl.state();
    try std.testing.expectEqual(@as(usize, 0), g_applies);
}

test "remove adjusts marker and state" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    const first = try tl.commit(.{ .add = 1 });
    const second = try tl.commit(.{ .add = 2 });
    _ = try tl.commit(.{ .add = 3 });
    try std.testing.expectEqual(@as(i64, 6), tl.state().value);

    tl.remove(second);
    try std.testing.expectEqual(@as(u32, 2), tl.len());
    try std.testing.expectEqual(@as(u32, 2), tl.marker());
    try std.testing.expectEqual(@as(i64, 4), tl.state().value);

    // Remove while rolled back so the removal is below the marker.
    tl.setMarker(2);
    tl.remove(first);
    try std.testing.expectEqual(@as(u32, 1), tl.len());
    try std.testing.expectEqual(@as(u32, 1), tl.marker());
    try std.testing.expectEqual(@as(i64, 3), tl.state().value);

    try std.testing.expect(tl.featureById(first) == null);
}

test "scrub ping-pong is free after the snapshot" {
    const gpa = std.testing.allocator;
    var tl = try TestTimeline.init(gpa, .{}, .{ .checkpoint_on_scrub = true, .max_checkpoints = 4 });
    defer tl.deinit();

    _ = try tl.commit(.{ .add = 1 });
    _ = try tl.commit(.{ .add = 2 });
    _ = try tl.commit(.{ .add = 3 });
    _ = tl.state();

    g_applies = 0;
    tl.setMarker(1);
    _ = tl.state(); // backward to an unsnapshotted position: replays from seed
    try std.testing.expectEqual(@as(usize, 1), g_applies);

    g_applies = 0;
    tl.setMarker(3); // snapshot at 3 was taken when leaving it: exact restore
    _ = tl.state();
    try std.testing.expectEqual(@as(usize, 0), g_applies);

    g_applies = 0;
    tl.setMarker(1); // and back to 1: exact restore again — ping-pong is free
    _ = tl.state();
    try std.testing.expectEqual(@as(usize, 0), g_applies);
    tl.setMarker(3);
    _ = tl.state();
    try std.testing.expectEqual(@as(usize, 0), g_applies);
}

test "undo/redo commits" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    _ = try tl.commit(.{ .add = 1 });
    _ = try tl.commit(.{ .add = 2 });
    _ = try tl.commit(.{ .add = 3 });
    try std.testing.expectEqual(@as(i64, 6), tl.state().value);

    try std.testing.expect(tl.undo());
    try std.testing.expectEqual(@as(u32, 2), tl.len());
    try std.testing.expectEqual(@as(i64, 3), tl.state().value);
    try std.testing.expect(tl.undo());
    try std.testing.expectEqual(@as(i64, 1), tl.state().value);
    try std.testing.expect(tl.undo());
    try std.testing.expectEqual(@as(u32, 0), tl.len());
    try std.testing.expectEqual(@as(i64, 0), tl.state().value);
    try std.testing.expect(!tl.undo());

    try std.testing.expect(tl.redo());
    try std.testing.expectEqual(@as(i64, 1), tl.state().value);
    try std.testing.expect(tl.redo());
    try std.testing.expectEqual(@as(i64, 3), tl.state().value);
    try std.testing.expect(tl.redo());
    try std.testing.expectEqual(@as(i64, 6), tl.state().value);
    try std.testing.expect(!tl.redo());
}

test "new edit clears the redo stack" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    _ = try tl.commit(.{ .add = 1 });
    _ = try tl.commit(.{ .add = 2 });
    _ = tl.undo();
    try std.testing.expect(tl.canRedo());
    _ = try tl.commit(.{ .mul = 10 });
    try std.testing.expect(!tl.canRedo());
    try std.testing.expectEqual(@as(u32, 2), tl.len());
    try std.testing.expectEqual(@as(i64, 10), tl.state().value);
}

test "undo/redo edit and suppress" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    const first = try tl.commit(.{ .add = 1 });
    _ = try tl.commit(.{ .add = 2 });

    tl.edit(first, .{ .add = 10 });
    try std.testing.expectEqual(@as(i64, 12), tl.state().value);
    try std.testing.expect(tl.undo());
    try std.testing.expectEqual(@as(i64, 3), tl.state().value);
    try std.testing.expect(tl.redo());
    try std.testing.expectEqual(@as(i64, 12), tl.state().value);

    tl.setSuppressed(first, true);
    try std.testing.expectEqual(@as(i64, 2), tl.state().value);
    try std.testing.expect(tl.undo());
    try std.testing.expectEqual(@as(i64, 12), tl.state().value);
    try std.testing.expect(tl.redo());
    try std.testing.expectEqual(@as(i64, 2), tl.state().value);
}

test "undo remove restores feature id and marker" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    const first = try tl.commit(.{ .add = 1 });
    _ = try tl.commit(.{ .add = 2 });
    _ = try tl.commit(.{ .add = 3 });
    tl.setMarker(1);
    try std.testing.expectEqual(@as(i64, 1), tl.state().value);

    tl.remove(first);
    try std.testing.expectEqual(@as(u32, 2), tl.len());
    try std.testing.expectEqual(@as(u32, 0), tl.marker());

    try std.testing.expect(tl.undo());
    try std.testing.expectEqual(@as(u32, 3), tl.len());
    try std.testing.expectEqual(@as(u32, 1), tl.marker());
    const restored = tl.featureById(first).?;
    try std.testing.expectEqual(TestDomain.Op{ .add = 1 }, restored.op.*);
    try std.testing.expectEqual(@as(i64, 1), tl.state().value);

    try std.testing.expect(tl.redo());
    try std.testing.expectEqual(@as(u32, 2), tl.len());
    try std.testing.expectEqual(@as(u32, 0), tl.marker());
}

test "undo commit restores marker position" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    _ = try tl.commit(.{ .add = 1 });
    _ = try tl.commit(.{ .add = 2 });
    _ = try tl.commit(.{ .add = 3 });
    tl.setMarker(1);
    _ = tl.state();

    _ = try tl.commit(.{ .mul = 10 });
    try std.testing.expectEqual(@as(u32, 2), tl.marker());
    try std.testing.expectEqual(@as(i64, 10), tl.state().value);

    try std.testing.expect(tl.undo());
    try std.testing.expectEqual(@as(u32, 1), tl.marker());
    try std.testing.expectEqual(@as(i64, 1), tl.state().value);

    try std.testing.expect(tl.redo());
    try std.testing.expectEqual(@as(u32, 2), tl.marker());
    try std.testing.expectEqual(@as(i64, 10), tl.state().value);
}

test "journal depth cap" {
    const gpa = std.testing.allocator;
    var tl = try TestTimeline.init(gpa, .{}, .{ .max_journal = 2 });
    defer tl.deinit();

    _ = try tl.commit(.{ .add = 1 });
    _ = try tl.commit(.{ .add = 2 });
    _ = try tl.commit(.{ .add = 3 });

    try std.testing.expect(tl.undo());
    try std.testing.expectEqual(@as(i64, 3), tl.state().value);
    try std.testing.expect(tl.undo());
    try std.testing.expectEqual(@as(i64, 1), tl.state().value);
    try std.testing.expect(!tl.undo());
}

test "journal disabled" {
    const gpa = std.testing.allocator;
    var tl = try TestTimeline.init(gpa, .{}, .{ .max_journal = 0 });
    defer tl.deinit();

    _ = try tl.commit(.{ .add = 1 });
    try std.testing.expect(!tl.canUndo());
    try std.testing.expect(!tl.undo());
}

// ---------------------------------------------------------------------------
// Dependency-aware domain for move validation tests
// ---------------------------------------------------------------------------

const DepDomain = struct {
    pub const Doc = struct {
        value: i64 = 0,
        bases: std.ArrayList(ft.FeatureId) = .empty,
    };
    pub const Op = union(enum) {
        base: struct { v: i64 },
        offset: struct { base_id: ft.FeatureId, amount: i64 },
    };
    pub fn apply(op: Op, doc: *Doc, ctx: *ft.ApplyContext) anyerror!void {
        switch (op) {
            .base => |b| {
                doc.value += b.v;
                try doc.bases.append(ctx.alloc, ctx.feature_id);
            },
            .offset => |o| {
                for (doc.bases.items) |id| {
                    if (id == o.base_id) {
                        doc.value += o.amount;
                        return;
                    }
                }
                return ctx.fail("base feature is not applied before this offset", .{});
            },
        }
    }
    pub fn dependencies(op: Op, out: *ft.DepCollector) void {
        switch (op) {
            .base => {},
            .offset => |o| out.dep(o.base_id),
        }
    }
    pub fn cloneDoc(doc: *const Doc, gpa: std.mem.Allocator) anyerror!Doc {
        return .{ .value = doc.value, .bases = try doc.bases.clone(gpa) };
    }
    pub fn deinitDoc(doc: *Doc, gpa: std.mem.Allocator) void {
        doc.bases.deinit(gpa);
    }
};

test "move reorders and recomputes" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    _ = try tl.commit(.{ .add = 5 });
    _ = try tl.commit(.{ .mul = 2 });
    const last = try tl.commit(.{ .add = 1 });
    try std.testing.expectEqual(@as(i64, 11), tl.state().value);

    try tl.move(last, 0);
    try std.testing.expectEqual(@as(i64, 12), tl.state().value);
    try std.testing.expectEqual(@as(u32, 3), tl.len());

    // Undo restores order and marker; redo re-moves.
    try std.testing.expect(tl.undo());
    try std.testing.expectEqual(@as(i64, 11), tl.state().value);
    try std.testing.expect(tl.redo());
    try std.testing.expectEqual(@as(i64, 12), tl.state().value);
}

test "move across the marker adjusts the marker" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    _ = try tl.commit(.{ .add = 1 });
    const second = try tl.commit(.{ .add = 2 });
    _ = try tl.commit(.{ .add = 3 });
    tl.setMarker(2);
    try std.testing.expectEqual(@as(i64, 3), tl.state().value);

    // Move the applied `second` past the marker: applied count drops.
    try tl.move(second, 2);
    try std.testing.expectEqual(@as(u32, 1), tl.marker());
    try std.testing.expectEqual(@as(i64, 1), tl.state().value);

    // Undo restores the marker to its pre-move position.
    try std.testing.expect(tl.undo());
    try std.testing.expectEqual(@as(u32, 2), tl.marker());
    try std.testing.expectEqual(@as(i64, 3), tl.state().value);
}

test "move refuses dependency violations before mutating" {
    const gpa = std.testing.allocator;
    var tl = try Timeline(DepDomain).init(gpa, .{}, .{});
    defer tl.deinit();

    const b1 = try tl.commit(.{ .base = .{ .v = 10 } });
    _ = try tl.commit(.{ .base = .{ .v = 100 } });
    const off = try tl.commit(.{ .offset = .{ .base_id = b1, .amount = 5 } });
    try std.testing.expectEqual(@as(i64, 115), tl.state().value);

    try std.testing.expectError(error.DependencyViolation, tl.move(off, 0));
    try std.testing.expectEqual(@as(u32, 3), tl.len());
    try std.testing.expectEqual(@as(u32, 2), tl.indexOf(off).?);

    // Moving a base later (after its dependent is not allowed either).
    try std.testing.expectError(error.DependencyViolation, tl.move(b1, 2));

    // Moving something with no dependency relation is fine.
    try tl.move(off, 1);
    try std.testing.expectEqual(@as(u32, 1), tl.indexOf(off).?);
    try std.testing.expectEqual(@as(i64, 115), tl.state().value);
}

test "dependent feature fails when its dependency is removed" {
    const gpa = std.testing.allocator;
    var tl = try Timeline(DepDomain).init(gpa, .{}, .{});
    defer tl.deinit();

    const b1 = try tl.commit(.{ .base = .{ .v = 10 } });
    _ = try tl.commit(.{ .base = .{ .v = 100 } });
    _ = try tl.commit(.{ .offset = .{ .base_id = b1, .amount = 5 } });

    tl.remove(b1);
    try std.testing.expectEqual(@as(i64, 100), tl.state().value);

    // b1 removed: remaining features are the second base and the offset.
    var it = tl.features();
    _ = it.next().?;
    const offset_status = it.next().?.status;
    try std.testing.expectEqualStrings(
        "base feature is not applied before this offset",
        offset_status.failed,
    );
}

test "background rebuild matches the synchronous path" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    const first = try tl.commit(.{ .add = 1 });
    _ = try tl.commit(.{ .add = 2 });
    _ = try tl.commit(.{ .add = 3 });
    tl.setMarker(1);
    _ = tl.state();
    tl.edit(first, .{ .add = 10 });
    try std.testing.expect(tl.dirty());

    var job = try tl.beginRebuild();
    job.run();
    try std.testing.expect(tl.integrate(&job));
    try std.testing.expect(!tl.dirty());
    try std.testing.expectEqual(@as(i64, 10), tl.state().value);
    try std.testing.expectEqual(ft.Status.ok, tl.featureById(first).?.status);
}

test "stale background jobs are rejected" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    const first = try tl.commit(.{ .add = 1 });
    _ = try tl.commit(.{ .add = 2 });
    tl.setMarker(1);
    _ = tl.state();
    tl.edit(first, .{ .add = 10 });

    var job = try tl.beginRebuild();
    _ = try tl.commit(.{ .add = 100 }); // plan changed under the job
    try std.testing.expect(!tl.integrate(&job));
    // The synchronous path still resolves the state.
    try std.testing.expectEqual(@as(i64, 110), tl.state().value);
}

test "cancelled background jobs are rejected" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    _ = try tl.commit(.{ .add = 1 });
    _ = try tl.commit(.{ .add = 2 });
    tl.setMarker(1);

    var job = try tl.beginRebuild();
    job.cancel();
    job.run();
    try std.testing.expect(!tl.integrate(&job));
    try std.testing.expect(tl.dirty());
    try std.testing.expectEqual(@as(i64, 1), tl.state().value);
}

test "hard failure in a background job breaks the timeline, keeps last good" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    const first = try tl.commit(.{ .add = 5 });
    _ = try tl.commit(.{ .add = 1 });
    tl.setMarker(1);
    _ = tl.state();
    tl.edit(first, .{ .poison = {} });

    var job = try tl.beginRebuild();
    defer job.deinit();
    job.run();
    try std.testing.expect(!tl.integrate(&job));
    try std.testing.expect(tl.broken != null);
    // Last good state: the document at marker 1 before the poisoned edit.
    try std.testing.expectEqual(@as(i64, 5), tl.state().value);
}

test "background rebuild replays only the dirty suffix from a checkpoint" {
    const gpa = std.testing.allocator;
    var tl = try TestTimeline.init(gpa, .{}, .{
        .checkpoint_interval = 2,
        .max_checkpoints = 8,
        .checkpoint_on_scrub = true,
    });
    defer tl.deinit();

    var ids: [8]ft.FeatureId = undefined;
    for (&ids, 0..) |*slot, i| {
        slot.* = try tl.commit(.{ .add = @intCast(i + 1) });
    }
    // Force one chunked full rebuild to lay down interval checkpoints at
    // 2, 4, 6 (fast-path commits never create them).
    tl.edit(ids[0], .{ .add = 1 }); // same value, still invalidates
    _ = tl.state();
    tl.edit(ids[5], .{ .add = 50 });

    g_applies = 0;
    var job = try tl.beginRebuild(); // consumes the checkpoint at 4
    defer job.deinit();
    job.run();
    try std.testing.expectEqual(@as(usize, 4), g_applies);
    try std.testing.expect(tl.integrate(&job));
    try std.testing.expectEqual(@as(i64, 1 + 2 + 3 + 4 + 5 + 50 + 7 + 8), tl.state().value);
}

test "background rebuild runs on a real worker thread" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    _ = try tl.commit(.{ .add = 2 });
    _ = try tl.commit(.{ .mul = 21 });
    tl.setMarker(1);

    var job = try tl.beginRebuild();
    const thread = try std.Thread.spawn(.{}, ft.rebuild.Job(TestDomain).run, .{&job});
    thread.join();
    try std.testing.expect(tl.integrate(&job));
    try std.testing.expectEqual(@as(i64, 2), tl.state().value);
    try std.testing.expect(!tl.dirty());
}
