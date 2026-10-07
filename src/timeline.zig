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
const annotations = @import("annotations.zig");
const params = @import("params.zig");
const syncing = @import("sync.zig");

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
        /// Journal entry shape, re-exported for record observers and
        /// `applyRemote`.
        pub const Entry = journaling.Journal(Op).Entry;

        gpa: std.mem.Allocator,
        config: ft.Config,

        /// Opaque environment reachable from `Domain.apply` as `ctx.env`.
        /// The seam for hierarchical timelines: point it at a registry of
        /// sub-timelines and parent features can read their computed state.
        /// Set via `setEnv` (or directly); read at apply time.
        env: ?*anyopaque = null,

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

        /// Annotation layer: names, chapters, provenance (tags and groups
        /// arrive in later milestones). Never affects document computation.
        ann: annotations.Annotations,

        /// The parameter table: named numeric values read by features via
        /// `ApplyContext.param`. Unlike annotations, parameters ARE
        /// computational inputs — editing one invalidates the features
        /// that read it.
        ptab: params.ParamTable,

        /// Bumped by annotation changes only — deliberately separate from
        /// `gen`, which background jobs capture; annotation edits must not
        /// invalidate running jobs.
        ann_gen: u64 = 0,

        /// Stable identity of this timeline, persisted so remote references
        /// can be namespaced `(timeline_id, feature_id)` by a future sync
        /// layer.
        timeline_id: u64,

        /// Fired for every *locally made* edit as it is journaled (the sync
        /// feed's source). Suppressed while `applyRemote` integrates remote
        /// entries, so replicas never echo. The entry is borrowed for the
        /// duration of the callback.
        observer: ?RecordObserver = null,

        /// True while `applyRemote` runs: records made now are remote
        /// integrations and must not fire the observer.
        applying_remote: bool = false,

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
                .ann = annotations.Annotations.init(gpa),
                .ptab = params.ParamTable.init(gpa),
                .timeline_id = (prng.random().int(u64) ^ idEntropy(&config)) | 1,
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
            self.ann.deinit();
            self.ptab.deinit();
            Domain.deinitDoc(&self.seed_doc, self.gpa);
            Domain.deinitDoc(&self.live_doc, self.gpa);
        }

        /// This timeline's stable identity (see `timeline_id`).
        pub fn timelineId(self: *const Self) u64 {
            return self.timeline_id;
        }

        fn annTouch(self: *Self) void {
            self.ann_gen += 1;
        }

        /// Version of the annotation layer; changes independently of `gen`
        /// so UIs can detect metadata-only edits without conflating them
        /// with document mutations.
        pub fn annotationsVersion(self: *const Self) u64 {
            return self.ann_gen;
        }

        /// Record through the journal and fire the sync-feed observer (for
        /// local edits only; `applyRemote` records directly and stays
        /// silent). Note on undo semantics: every annotation mutation is
        /// journaled above the commit of the feature it decorates, so strict
        /// LIFO unwinds annotations before their feature's commit and
        /// rewinds them on redo — no resurrection stash is needed.
        /// Structural entries that delete features (remove) snapshot what
        /// they need at record time.
        fn record(self: *Self, entry: journaling.Journal(Op).Entry) void {
            self.journal.record(entry);
            if (!self.applying_remote) {
                if (self.observer) |obs| obs.func(obs.ctx, &entry);
            }
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
            const meta: ?ft.Meta = if (self.config.now) |now| .{ .ts = now() } else null;
            return self.commitInner(op, meta);
        }

        /// Commit with explicit provenance. When `Config.now` is set, plain
        /// `commit` auto-stamps; this overrides/supplements it.
        pub fn commitWithMeta(self: *Self, op: Op, meta: ft.Meta) error{OutOfMemory}!ft.FeatureId {
            return self.commitInner(op, meta);
        }

        fn commitInner(self: *Self, op: Op, meta: ?ft.Meta) error{OutOfMemory}!ft.FeatureId {
            self.touch();
            const id = self.next_id;
            self.next_id +%= 1;
            const at = self.marker_pos;

            try self.list.insert(self.gpa, at, .{ .id = id, .op = op });
            self.record(.{ .commit = .{ .id = id, .op = op, .at = at, .meta = meta } });
            if (meta) |m| self.ann.setProvenance(id, m) catch {};
            if (meta != null) self.annTouch();
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
                ft.rebuild.applyRange(Domain, self.list.items, at, at + 1, &self.live_doc, self.gpa, self.env, self.ptab.items(), &applied) catch |err| {
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
            self.record(.{ .edit = .{ .id = id, .old_op = old_op, .new_op = new_op } });
            self.list.items[idx].op = new_op;
            self.invalidate(idx);
        }

        /// Remove a feature from the timeline. The marker adjusts so the
        /// visible document stays consistent. No-op if absent.
        pub fn remove(self: *Self, id: ft.FeatureId) void {
            self.touch();
            const idx = self.indexOf(id) orelse return;
            const f = self.list.items[idx];

            // Snapshot annotations for exact undo, then re-anchor chapters
            // that point at this feature to its successor-in-place.
            const replacement: ?ft.FeatureId = if (idx + 1 < self.list.items.len)
                self.list.items[idx + 1].id
            else
                null;
            const name_snap: ?[]const u8 = if (self.ann.nameOf(id)) |n|
                self.gpa.dupe(u8, n) catch null
            else
                null;
            const fixes = self.ann.reanchorAfterRemove(id, replacement) catch @as([]annotations.ChapterFix, &.{});
            const tags_snap = self.ann.takeTags(id) catch @as([][]const u8, &.{});
            const group_fixes = self.reanchorGroupBoundaries(id, idx) catch @as([]annotations.GroupFix, &.{});

            self.record(.{ .remove = .{
                .id = id,
                .op = f.op,
                .at = idx,
                .suppressed = f.suppressed,
                .marker_pre = self.marker_pos,
                .name = name_snap,
                .meta = self.ann.provenance(id),
                .chapter_fixes = fixes,
                .tags = tags_snap,
                .group_fixes = group_fixes,
            } });
            self.ann.removeFeature(id);
            self.annTouch();
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
            self.record(.{ .suppress = .{ .id = id, .prev = prev } });
            self.list.items[idx].suppressed = suppressed;
            self.invalidate(idx);
        }

        // ------------------------------------------------------------------
        // Annotations: names, chapters, provenance
        // ------------------------------------------------------------------

        /// Assign (or replace) a feature's display name. No-op if the
        /// feature is absent.
        pub fn setFeatureName(self: *Self, id: ft.FeatureId, new_name: []const u8) error{OutOfMemory}!void {
            if (self.indexOf(id) == null) return;
            const old = self.ann.nameOf(id);
            const old_snap: ?[]const u8 = if (old) |o| try self.gpa.dupe(u8, o) else null;
            errdefer if (old_snap) |o| self.gpa.free(o);
            const new_snap = try self.gpa.dupe(u8, new_name);
            errdefer self.gpa.free(new_snap);
            try self.ann.setName(id, new_name);
            self.record(.{ .name_set = .{ .id = id, .old = old_snap, .new = new_snap } });
            self.annTouch();
        }

        /// Remove a feature's display name. No-op if the feature or its
        /// name is absent.
        pub fn clearFeatureName(self: *Self, id: ft.FeatureId) error{OutOfMemory}!void {
            const old = self.ann.nameOf(id) orelse return;
            const old_snap = try self.gpa.dupe(u8, old);
            errdefer self.gpa.free(old_snap);
            try self.ann.setName(id, null);
            self.record(.{ .name_set = .{ .id = id, .old = old_snap, .new = null } });
            self.annTouch();
        }

        pub fn featureName(self: *const Self, id: ft.FeatureId) ?[]const u8 {
            return self.ann.nameOf(id);
        }

        /// Provenance recorded at commit time, if any.
        pub fn provenance(self: *const Self, id: ft.FeatureId) ?ft.Meta {
            return self.ann.provenance(id);
        }

        /// Add a tag to a feature (set semantics: no-op if already present).
        pub fn addTag(self: *Self, id: ft.FeatureId, tag: []const u8) error{OutOfMemory}!void {
            if (self.indexOf(id) == null) return;
            const entry_tag = try self.gpa.dupe(u8, tag);
            errdefer self.gpa.free(entry_tag);
            const added = try self.ann.addTag(id, tag);
            if (!added) {
                self.gpa.free(entry_tag);
                return;
            }
            self.record(.{ .tag_add = .{ .id = id, .tag = entry_tag } });
            self.annTouch();
        }

        /// Remove a tag from a feature. No-op if absent.
        pub fn removeTag(self: *Self, id: ft.FeatureId, tag: []const u8) void {
            if (!self.ann.hasTag(id, tag)) return;
            const entry_tag = self.gpa.dupe(u8, tag) catch return;
            _ = self.ann.removeTag(id, tag);
            self.record(.{ .tag_remove = .{ .id = id, .tag = entry_tag } });
            self.annTouch();
        }

        /// The feature's tags in insertion order. Valid until the next
        /// annotation mutation.
        pub fn tags(self: *const Self, id: ft.FeatureId) []const []const u8 {
            return self.ann.tagList(id);
        }

        /// Iterate feature ids carrying `tag`, oldest-first.
        pub fn featuresTagged(self: *const Self, tag: []const u8) TaggedIter {
            return .{ .tl = self, .tag = tag };
        }

        pub const TaggedIter = struct {
            tl: *const Self,
            tag: []const u8,
            i: u32 = 0,

            pub fn next(self: *TaggedIter) ?ft.FeatureId {
                while (self.i < self.tl.list.items.len) {
                    const id = self.tl.list.items[self.i].id;
                    self.i += 1;
                    if (self.tl.ann.hasTag(id, self.tag)) return id;
                }
                return null;
            }
        };

        /// Add a named chapter (a slider bookmark) at `mark`. Chapter ids
        /// share the feature id space and are never reused.
        pub fn addChapter(self: *Self, name: []const u8, mark: ft.Mark) error{OutOfMemory}!ft.ChapterId {
            const cid: ft.ChapterId = self.next_id;
            self.next_id +%= 1;
            const entry_name = try self.gpa.dupe(u8, name);
            errdefer self.gpa.free(entry_name);
            try self.ann.addChapter(cid, name, mark);
            self.record(.{ .chapter_add = .{ .chapter = .{ .id = cid, .name = entry_name, .mark = mark } } });
            self.annTouch();
            return cid;
        }

        /// Remove a chapter. No-op if absent.
        pub fn removeChapter(self: *Self, id: ft.ChapterId) void {
            const c = self.ann.chapterById(id) orelse return;
            // Copy out everything the entry needs before removal invalidates
            // the pointer into the chapters array.
            const cid = c.id;
            const mark = c.mark;
            const entry_name = self.gpa.dupe(u8, c.name) catch return;
            self.ann.removeChapter(id);
            self.record(.{ .chapter_remove = .{ .chapter = .{
                .id = cid,
                .name = entry_name,
                .mark = mark,
            } } });
            self.annTouch();
        }

        pub fn renameChapter(self: *Self, id: ft.ChapterId, new_name: []const u8) error{OutOfMemory}!void {
            const c = self.ann.chapterById(id) orelse return;
            const old_snap = try self.gpa.dupe(u8, c.name);
            errdefer self.gpa.free(old_snap);
            const new_snap = try self.gpa.dupe(u8, new_name);
            errdefer self.gpa.free(new_snap);
            try self.ann.renameChapter(id, new_name);
            self.record(.{ .chapter_rename = .{ .id = id, .old = old_snap, .new = new_snap } });
            self.annTouch();
        }

        /// All chapters, in creation order. The slice is valid until the next
        /// annotation mutation.
        pub fn chapters(self: *const Self) []const ft.Chapter {
            return self.ann.chapterList();
        }

        /// Resolve a mark to a marker position (jump target).
        pub fn markPosition(self: *const Self, mark: ft.Mark) u32 {
            const after = mark.after orelse return self.len();
            const idx = self.indexOf(after) orelse return self.len();
            return idx + 1;
        }

        /// Resolve a chapter to a marker position. Null if absent.
        pub fn chapterPosition(self: *const Self, id: ft.ChapterId) ?u32 {
            const c = self.ann.chapterById(id) orelse return null;
            return self.markPosition(c.mark);
        }

        // ------------------------------------------------------------------
        // Annotations: groups (contiguous spans)
        // ------------------------------------------------------------------

        /// Create a group spanning `first`..`last` (normalized by position).
        /// Returns null when either anchor is absent.
        pub fn addGroup(self: *Self, name: []const u8, first: ft.FeatureId, last: ft.FeatureId) error{OutOfMemory}!?ft.annotations.GroupId {
            const fi = self.indexOf(first) orelse return null;
            const li = self.indexOf(last) orelse return null;
            const lo = @min(fi, li);
            const hi = @max(fi, li);
            const gid: ft.annotations.GroupId = self.next_id;
            self.next_id +%= 1;
            const entry_name = try self.gpa.dupe(u8, name);
            errdefer self.gpa.free(entry_name);
            try self.ann.addGroup(gid, name, self.list.items[lo].id, self.list.items[hi].id);
            self.record(.{ .group_add = .{ .group = .{
                .id = gid,
                .name = entry_name,
                .first = self.list.items[lo].id,
                .last = self.list.items[hi].id,
            } } });
            self.annTouch();
            return gid;
        }

        /// Ungroup: remove the group, keep the features. No-op if absent.
        pub fn removeGroup(self: *Self, id: ft.annotations.GroupId) void {
            const g = self.ann.groupById(id) orelse return;
            const gid = g.id;
            const first = g.first;
            const last = g.last;
            const entry_name = self.gpa.dupe(u8, g.name) catch return;
            self.ann.removeGroup(id);
            self.record(.{ .group_remove = .{ .group = .{
                .id = gid,
                .name = entry_name,
                .first = first,
                .last = last,
            } } });
            self.annTouch();
        }

        pub fn renameGroup(self: *Self, id: ft.annotations.GroupId, new_name: []const u8) error{OutOfMemory}!void {
            const g = self.ann.groupById(id) orelse return;
            const old_snap = try self.gpa.dupe(u8, g.name);
            errdefer self.gpa.free(old_snap);
            const new_snap = try self.gpa.dupe(u8, new_name);
            errdefer self.gpa.free(new_snap);
            try self.ann.renameGroup(id, new_name);
            self.record(.{ .group_rename = .{ .id = id, .old = old_snap, .new = new_snap } });
            self.annTouch();
        }

        /// All groups in creation order. Valid until the next annotation
        /// mutation.
        pub fn groups(self: *const Self) []const ft.annotations.Group {
            return self.ann.groupList();
        }

        const Span = struct { lo: u32, hi: u32 };

        /// Resolved span indices, or null when anchors are dead/inverted
        /// (an empty folder).
        fn spanOf(self: *const Self, first: ft.FeatureId, last: ft.FeatureId) ?Span {
            const lo = self.indexOf(first) orelse return null;
            const hi = self.indexOf(last) orelse return null;
            if (lo > hi) return null;
            return .{ .lo = lo, .hi = hi };
        }

        fn groupSpan(self: *const Self, g: *const ft.annotations.Group) ?Span {
            return self.spanOf(g.first, g.last);
        }

        /// The group a feature belongs to, if any.
        pub fn groupOf(self: *const Self, id: ft.FeatureId) ?ft.annotations.GroupId {
            const idx = self.indexOf(id) orelse return null;
            for (self.ann.groupList()) |*g| {
                if (self.groupSpan(g)) |span| {
                    if (idx >= span.lo and idx <= span.hi) return g.id;
                }
            }
            return null;
        }

        /// Suppress or unsuppress every member of a group — one undo step
        /// (a transaction over per-member suppress entries).
        pub fn setGroupSuppressed(self: *Self, id: ft.annotations.GroupId, suppressed: bool) void {
            const g = self.ann.groupById(id) orelse return;
            const span = self.groupSpan(g) orelse return;
            self.beginTransaction();
            defer self.endTransaction();
            var i: u32 = span.lo;
            while (i <= span.hi) : (i += 1) {
                self.setSuppressed(self.list.items[i].id, suppressed);
            }
        }

        /// Relocate a group's members to `new_pos` (the block's first index
        /// in the resulting list), preserving member order — one undo step.
        /// Members cross the marker individually (same semantics as `move`).
        /// No-op when absent or empty; `error.DependencyViolation` when the
        /// resulting order would break declared dependencies.
        pub fn moveGroup(self: *Self, id: ft.annotations.GroupId, new_pos: u32) MoveError!void {
            self.touch();
            const g = self.ann.groupById(id) orelse return;
            const span = self.groupSpan(g) orelse return;
            const n: u32 = span.hi - span.lo + 1;
            const to = @min(new_pos, @as(u32, @intCast(self.list.items.len)) - n);
            if (to == span.lo) return;

            if (comptime hasDeps(Domain)) {
                if (self.groupMoveViolatesDeps(span, to)) return error.DependencyViolation;
            }
            if (n > 4096) return error.OutOfMemory; // huge groups: raise later

            // Transaction of per-member move entries. Sequential rawMoves:
            // member k always sits at the old block start when its turn
            // comes, whichever direction the block travels.
            self.beginTransaction();
            defer self.endTransaction();
            var k: u32 = 0;
            while (k < n) : (k += 1) {
                const member = self.list.items[span.lo].id;
                const from: u32 = span.lo;
                const marker_pre = self.marker_pos;
                self.record(.{ .move = .{
                    .id = member,
                    .from = from,
                    .to = to + k,
                    .marker_pre = marker_pre,
                } });
                self.rawMove(member, to + k);
            }
        }

        /// Simulate the block move and check every dependency edge against
        /// the resulting order.
        fn groupMoveViolatesDeps(self: *Self, span: Span, to: u32) bool {
            const n: u32 = span.hi - span.lo + 1;
            var collector: ft.DepCollector = .{ .gpa = self.gpa };
            defer collector.deps.deinit(self.gpa);
            for (self.list.items, 0..) |f, i| {
                collector.deps.clearRetainingCapacity();
                Domain.dependencies(f.op, &collector);
                if (collector.failed) return false;
                const mapped_i = groupMoveRemap(@intCast(i), span, to, n);
                for (collector.deps.items) |d| {
                    const anchor: ft.FeatureId = switch (d) {
                        .feature => |id| id,
                        .in_timeline => |ns| ns.timeline_feature,
                    };
                    const j = self.indexOf(anchor) orelse continue;
                    if (j == i) continue;
                    if (groupMoveRemap(j, span, to, n) >= mapped_i) return true;
                }
            }
            return false;
        }

        fn groupMoveRemap(i: u32, span: Span, to: u32, n: u32) u32 {
            if (i >= span.lo and i <= span.hi) return to + (i - span.lo);
            if (to < span.lo) {
                // Block moves left: features in [to .. span.lo) shift right
                // by n.
                return if (i >= to and i < span.lo) i + n else i;
            }
            // Block moves right: features in (span.hi .. to+n) shift left
            // by n.
            return if (i > span.hi and i < to + n) i - n else i;
        }

        /// Delete a group and its members in one undo step (a transaction
        /// of per-member removes plus the group removal). No-op if the group
        /// is absent; an empty group just disappears. Member annotations
        /// ride the per-member remove snapshots.
        pub fn removeGroupContents(self: *Self, id: ft.annotations.GroupId) void {
            self.touch();
            const g = self.ann.groupById(id) orelse return;
            const gid = g.id;
            const span = self.groupSpan(g);
            const count: usize = if (span) |sp| sp.hi - sp.lo + 1 else 0;

            self.beginTransaction();
            defer self.endTransaction();
            var k: u32 = 0;
            while (k < count) : (k += 1) {
                // The span head keeps re-anchoring to the successor, so the
                // first member is always at the span start.
                const sp = self.groupSpan(self.ann.groupById(gid).?) orelse break;
                self.remove(self.list.items[sp.lo].id);
            }
            self.removeGroup(gid);
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

            self.record(.{ .move = .{
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
            defer collector.deps.deinit(self.gpa);
            for (self.list.items, 0..) |f, i| {
                collector.deps.clearRetainingCapacity();
                Domain.dependencies(f.op, &collector);
                if (collector.failed) return false; // can't validate: allow
                const mapped_i = remapIndex(@intCast(i), from, to);
                for (collector.deps.items) |d| {
                    // A dependency inside a sub-timeline is anchored at the
                    // feature that introduces that sub-timeline; deeper
                    // ordering belongs to the sub-timeline's own validation.
                    const anchor: ft.FeatureId = switch (d) {
                        .feature => |id| id,
                        .in_timeline => |ns| ns.timeline_feature,
                    };
                    const j = self.indexOf(anchor) orelse continue;
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

        /// Register the environment handed to `Domain.apply` as `ctx.env`.
        pub fn setEnv(self: *Self, env: *anyopaque) void {
            self.env = env;
        }

        /// Re-run a feature and everything after it because inputs the
        /// library cannot see changed — for example, a sub-timeline read
        /// through `ctx.env` recomputed. Nothing is journaled: the timeline
        /// structure is untouched; this is invalidation, not an edit. No-op
        /// if absent.
        pub fn refresh(self: *Self, id: ft.FeatureId) void {
            const idx = self.indexOf(id) orelse return;
            self.touch();
            self.invalidate(idx);
        }

        // ------------------------------------------------------------------
        // Parameters
        // ------------------------------------------------------------------

        /// Add a named numeric parameter and return its stable id. Names are
        /// unique; fails on a duplicate.
        pub fn addParam(self: *Self, name: []const u8, value: f64) error{ OutOfMemory, DuplicateParam }!ft.ParamId {
            const pid: ft.ParamId = self.next_id;
            self.next_id +%= 1;
            const entry_name = try self.gpa.dupe(u8, name);
            errdefer self.gpa.free(entry_name);
            try self.ptab.add(pid, name, value);
            self.record(.{ .param_add = .{ .id = pid, .name = entry_name, .value = value } });
            return pid;
        }

        /// Set a parameter's value. Features referencing it (via the
        /// optional `Domain.references` hook) recompute lazily; without the
        /// hook the timeline cannot see the dependency and the app must
        /// `refresh` affected features itself. No-op for unknown ids.
        pub fn setParam(self: *Self, id: ft.ParamId, value: f64) void {
            const old = self.ptab.valueOf(id) orelse return;
            if (old == value) return;
            _ = self.ptab.set(id, value);
            self.record(.{ .param_set = .{ .id = id, .old = old, .new = value } });
            self.touch();
            self.invalidateReferencing(id);
        }

        /// Remove a parameter. Referencing features see `ctx.param` return
        /// null on the next rebuild and typically soft-fail. No-op for
        /// unknown ids.
        pub fn removeParam(self: *Self, id: ft.ParamId) void {
            const p = self.ptab.byId(id) orelse return;
            const entry_name = self.gpa.dupe(u8, p.name) catch return;
            _ = self.ptab.remove(id);
            self.record(.{ .param_remove = .{ .id = id, .name = entry_name, .value = p.value } });
            self.touch();
            self.invalidateReferencing(id);
        }

        /// Rename a parameter (display only — ops reference ids, not names).
        pub fn renameParam(self: *Self, id: ft.ParamId, new_name: []const u8) error{OutOfMemory}!void {
            const old = self.ptab.byId(id) orelse return;
            const old_snap = try self.gpa.dupe(u8, old.name);
            errdefer self.gpa.free(old_snap);
            const new_snap = try self.gpa.dupe(u8, new_name);
            errdefer self.gpa.free(new_snap);
            if (!try self.ptab.rename(id, new_name)) {
                self.gpa.free(old_snap);
                self.gpa.free(new_snap);
                return;
            }
            self.record(.{ .param_rename = .{ .id = id, .old = old_snap, .new = new_snap } });
        }

        /// Parameters in creation order. Valid until the next mutation.
        pub fn paramsList(self: *const Self) []const ft.Param {
            return self.ptab.items();
        }

        pub fn paramValue(self: *const Self, id: ft.ParamId) ?f64 {
            return self.ptab.valueOf(id);
        }

        pub fn paramIdByName(self: *const Self, name: []const u8) ?ft.ParamId {
            return self.ptab.idByName(name);
        }

        /// Invalidate from the earliest feature that reads `id` (suffix
        /// replay — a deliberate over-approximation of the scattered dirty
        /// set; see ROADMAP). Requires the `references` hook; without it
        /// this is a no-op.
        fn invalidateReferencing(self: *Self, id: ft.ParamId) void {
            if (comptime !@hasDecl(Domain, "references")) return;
            var collector: ft.ParamRefCollector = .{ .gpa = self.gpa };
            defer collector.ids.deinit(self.gpa);
            var earliest: ?u32 = null;
            for (self.list.items, 0..) |f, i| {
                collector.ids.clearRetainingCapacity();
                Domain.references(f.op, &collector);
                if (collector.failed) break; // can't see: invalidate broadly
                for (collector.ids.items) |pid| {
                    if (pid == id) {
                        earliest = @intCast(i);
                        break;
                    }
                }
                if (earliest != null) break;
            }
            if (earliest) |idx| self.invalidate(idx);
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

        /// Undo the most recent transaction — a single edit, or every edit
        /// grouped between an explicit `beginTransaction`/`endTransaction`
        /// pair. The marker restores to where it was when the unit's first
        /// edit was made (marker moves themselves are not journaled —
        /// scrubbing is free and never erodes undo depth). Returns false
        /// when there is nothing to undo.
        pub fn undo(self: *Self) bool {
            const first = self.journal.nextUndo() orelse return false;
            self.touch();
            self.reverse(first.entry);
            while (!first.unit_done) {
                const step = self.journal.nextUndo() orelse break;
                self.reverse(step.entry);
                if (step.unit_done) break;
            }
            return true;
        }

        /// Re-apply the most recently undone transaction. Returns false
        /// when there is nothing to redo.
        pub fn redo(self: *Self) bool {
            const first = self.journal.nextRedo() orelse return false;
            self.touch();
            self.forward(first.entry);
            while (!first.unit_done) {
                const step = self.journal.nextRedo() orelse break;
                self.forward(step.entry);
                if (step.unit_done) break;
            }
            return true;
        }

        pub const RecordObserver = struct {
            ctx: ?*anyopaque = null,
            func: *const fn (ctx: ?*anyopaque, entry: *const Entry) void,
        };

        /// Install the sync-feed observer: called for each locally journaled
        /// edit, in record order (including each entry inside a
        /// transaction). Remote integrations via `applyRemote` do not fire
        /// it. The entry pointer is borrowed — copy what you need inside
        /// the callback.
        pub fn setRecordObserver(self: *Self, observer: RecordObserver) void {
            self.observer = observer;
        }

        /// Integrate an edit that originated on another replica. Identity is
        /// exact — feature/chapter/group/param ids are preserved (and the
        /// local id counter skips past them) — while positions are hints:
        /// indices are clamped and entries referencing unknown ids are
        /// silently dropped. The effect is journaled locally (undo works
        /// uniformly) but does not fire the record observer, so feeding
        /// replicas' entries to each other cannot loop.
        ///
        /// Two replicas that exchange every entry in a consistent order
        /// converge; concurrent positional edits are the application
        /// layer's concern (`sync.lastWriterWins` is the provided
        /// tie-breaker when provenance timestamps exist).
        pub fn applyRemote(self: *Self, entry: *const Entry) void {
            const prev = self.applying_remote;
            self.applying_remote = true;
            defer self.applying_remote = prev;
            self.applyRemoteInner(entry);
        }

        fn applyRemoteInner(self: *Self, entry: *const Entry) void {
            switch (entry.*) {
                .commit => |e| {
                    // Re-delivery is possible in any feed protocol: a
                    // commit whose id already exists here was integrated.
                    if (self.indexOf(e.id) != null) return;
                    const at = @min(e.at, @as(u32, @intCast(self.list.items.len)));
                    self.list.insert(self.gpa, at, .{ .id = e.id, .op = e.op }) catch return;
                    if (e.id >= self.next_id) self.next_id = e.id +% 1;
                    if (e.meta) |m| self.ann.setProvenance(e.id, m) catch {};
                    self.journal.record(.{ .commit = .{
                        .id = e.id,
                        .op = e.op,
                        .at = at,
                        .meta = e.meta,
                    } });
                    self.afterInsert(at);
                },
                .edit => |e| {
                    const idx = self.indexOf(e.id) orelse return;
                    const old_op = self.list.items[idx].op;
                    self.journal.record(.{ .edit = .{
                        .id = e.id,
                        .old_op = old_op,
                        .new_op = e.new_op,
                    } });
                    self.list.items[idx].op = e.new_op;
                    self.invalidate(idx);
                },
                .remove => |e| {
                    if (self.indexOf(e.id) == null) return;
                    self.removeRemote(e.id);
                },
                .suppress => |e| {
                    const idx = self.indexOf(e.id) orelse return;
                    const prev_flag = self.list.items[idx].suppressed;
                    if (prev_flag == e.prev) return;
                    self.journal.record(.{ .suppress = .{ .id = e.id, .prev = prev_flag } });
                    self.list.items[idx].suppressed = !e.prev;
                    self.invalidate(idx);
                },
                .move => |e| {
                    if (self.indexOf(e.id) == null) return;
                    if (self.list.items.len == 0) return;
                    const from = self.indexOf(e.id).?;
                    const to = @min(e.to, @as(u32, @intCast(self.list.items.len - 1)));
                    if (from == to) return;
                    self.journal.record(.{ .move = .{
                        .id = e.id,
                        .from = from,
                        .to = to,
                        .marker_pre = self.marker_pos,
                    } });
                    self.rawMove(e.id, to);
                },
                .name_set => |e| {
                    if (self.indexOf(e.id) == null) return;
                    const old = self.ann.nameOf(e.id);
                    const old_snap: ?[]const u8 = if (old) |o| self.gpa.dupe(u8, o) catch null else null;
                    self.ann.setName(e.id, e.new) catch return;
                    const new_snap: ?[]const u8 = if (e.new) |n| self.gpa.dupe(u8, n) catch null else null;
                    self.journal.record(.{ .name_set = .{ .id = e.id, .old = old_snap, .new = new_snap } });
                    self.annTouch();
                },
                .tag_add => |e| {
                    if (self.indexOf(e.id) == null) return;
                    const added = self.ann.addTag(e.id, e.tag) catch return;
                    if (added) {
                        const tag_snap = self.gpa.dupe(u8, e.tag) catch return;
                        self.journal.record(.{ .tag_add = .{ .id = e.id, .tag = tag_snap } });
                    }
                    self.annTouch();
                },
                .tag_remove => |e| {
                    if (!self.ann.hasTag(e.id, e.tag)) return;
                    _ = self.ann.removeTag(e.id, e.tag);
                    const tag_snap = self.gpa.dupe(u8, e.tag) catch return;
                    self.journal.record(.{ .tag_remove = .{ .id = e.id, .tag = tag_snap } });
                    self.annTouch();
                },
                .chapter_add => |e| {
                    if (self.ann.chapterById(e.chapter.id) != null) return;
                    self.ann.addChapter(e.chapter.id, e.chapter.name, e.chapter.mark) catch return;
                    if (e.chapter.id >= self.next_id) self.next_id = e.chapter.id +% 1;
                    self.journal.record(.{ .chapter_add = .{ .chapter = .{
                        .id = e.chapter.id,
                        .name = self.gpa.dupe(u8, e.chapter.name) catch return,
                        .mark = e.chapter.mark,
                    } } });
                    self.annTouch();
                },
                .chapter_remove => |e| {
                    if (self.ann.chapterById(e.chapter.id) == null) return;
                    self.ann.removeChapter(e.chapter.id);
                    self.journal.record(.{ .chapter_remove = .{ .chapter = .{
                        .id = e.chapter.id,
                        .name = self.gpa.dupe(u8, e.chapter.name) catch return,
                        .mark = e.chapter.mark,
                    } } });
                    self.annTouch();
                },
                .chapter_rename => |e| {
                    const c = self.ann.chapterById(e.id) orelse return;
                    const old_snap = self.gpa.dupe(u8, c.name) catch return;
                    self.ann.renameChapter(e.id, e.new) catch return;
                    const new_snap = self.gpa.dupe(u8, e.new) catch return;
                    self.journal.record(.{ .chapter_rename = .{ .id = e.id, .old = old_snap, .new = new_snap } });
                    self.annTouch();
                },
                .group_add => |e| {
                    if (self.ann.groupById(e.group.id) != null) return;
                    if (self.indexOf(e.group.first) == null and self.indexOf(e.group.last) == null and e.group.first != e.group.last) {
                        // Span anchors unknown here: keep the folder empty
                        // (dead anchors) rather than dropping the group.
                    }
                    self.ann.addGroup(e.group.id, e.group.name, e.group.first, e.group.last) catch return;
                    if (e.group.id >= self.next_id) self.next_id = e.group.id +% 1;
                    self.journal.record(.{ .group_add = .{ .group = .{
                        .id = e.group.id,
                        .name = self.gpa.dupe(u8, e.group.name) catch return,
                        .first = e.group.first,
                        .last = e.group.last,
                    } } });
                    self.annTouch();
                },
                .group_remove => |e| {
                    if (self.ann.groupById(e.group.id) == null) return;
                    self.ann.removeGroup(e.group.id);
                    self.journal.record(.{ .group_remove = .{ .group = .{
                        .id = e.group.id,
                        .name = self.gpa.dupe(u8, e.group.name) catch return,
                        .first = e.group.first,
                        .last = e.group.last,
                    } } });
                    self.annTouch();
                },
                .group_rename => |e| {
                    const g = self.ann.groupById(e.id) orelse return;
                    const old_snap = self.gpa.dupe(u8, g.name) catch return;
                    self.ann.renameGroup(e.id, e.new) catch return;
                    const new_snap = self.gpa.dupe(u8, e.new) catch return;
                    self.journal.record(.{ .group_rename = .{ .id = e.id, .old = old_snap, .new = new_snap } });
                    self.annTouch();
                },
                .param_add => |e| {
                    if (self.ptab.byId(e.id) != null) return;
                    self.ptab.add(e.id, e.name, e.value) catch return;
                    if (e.id >= self.next_id) self.next_id = e.id +% 1;
                    self.journal.record(.{ .param_add = .{
                        .id = e.id,
                        .name = self.gpa.dupe(u8, e.name) catch return,
                        .value = e.value,
                    } });
                },
                .param_remove => |e| {
                    if (self.ptab.byId(e.id) == null) return;
                    _ = self.ptab.remove(e.id);
                    self.journal.record(.{ .param_remove = .{
                        .id = e.id,
                        .name = self.gpa.dupe(u8, e.name) catch return,
                        .value = e.value,
                    } });
                    self.invalidateReferencing(e.id);
                },
                .param_set => |e| {
                    const old = self.ptab.valueOf(e.id) orelse return;
                    if (old == e.new) return;
                    _ = self.ptab.set(e.id, e.new);
                    self.journal.record(.{ .param_set = .{ .id = e.id, .old = old, .new = e.new } });
                    self.invalidateReferencing(e.id);
                },
                .param_rename => |e| {
                    const current = self.ptab.byId(e.id) orelse return;
                    const old_snap = self.gpa.dupe(u8, current.name) catch return;
                    _ = self.ptab.rename(e.id, e.new) catch false;
                    const new_snap = self.gpa.dupe(u8, e.new) catch return;
                    self.journal.record(.{ .param_rename = .{ .id = e.id, .old = old_snap, .new = new_snap } });
                },
            }
        }

        /// Remote removal: same snapshot flow as a local remove, journaled
        /// silently.
        fn removeRemote(self: *Self, id: ft.FeatureId) void {
            const idx = self.indexOf(id) orelse return;
            const f = self.list.items[idx];
            const replacement: ?ft.FeatureId = if (idx + 1 < self.list.items.len)
                self.list.items[idx + 1].id
            else
                null;
            const name_snap: ?[]const u8 = if (self.ann.nameOf(id)) |n|
                self.gpa.dupe(u8, n) catch null
            else
                null;
            const fixes = self.ann.reanchorAfterRemove(id, replacement) catch @as([]annotations.ChapterFix, &.{});
            const tags_snap = self.ann.takeTags(id) catch @as([][]const u8, &.{});
            const group_fixes = self.reanchorGroupBoundaries(id, idx) catch @as([]annotations.GroupFix, &.{});
            self.journal.record(.{ .remove = .{
                .id = id,
                .op = f.op,
                .at = idx,
                .suppressed = f.suppressed,
                .marker_pre = self.marker_pos,
                .name = name_snap,
                .meta = self.ann.provenance(id),
                .chapter_fixes = fixes,
                .tags = tags_snap,
                .group_fixes = group_fixes,
            } });
            self.ann.removeFeature(id);
            self.resetStatuses(idx);
            _ = self.list.orderedRemove(idx);
            if (idx < self.marker_pos) self.marker_pos -= 1;
            self.invalidate(idx);
        }

        /// Open an explicit transaction: every edit recorded before the
        /// matching `endTransaction` becomes one undo/redo unit. Nested
        /// begins flatten into the outermost unit. An empty transaction
        /// records nothing; an unbalanced end is a no-op. Always pair with
        /// `endTransaction` (`defer` pairs well).
        pub fn beginTransaction(self: *Self) void {
            self.journal.beginTxn();
        }

        pub fn endTransaction(self: *Self) void {
            self.journal.endTxn();
        }

        fn reverse(self: *Self, entry: journaling.Journal(Op).Entry) void {
            switch (entry) {
                .commit => |e| {
                    const idx = self.indexOf(e.id) orelse return;
                    // LIFO has already unwound any annotations journaled
                    // above this commit; clear defensively in case future
                    // code paths leave one behind.
                    if (self.ann.takeName(e.id)) |n| self.gpa.free(n);
                    _ = self.ann.removeProvenance(e.id);
                    self.resetStatuses(idx);
                    _ = self.list.orderedRemove(idx);
                    self.marker_pos = e.at;
                    self.invalidate(idx);
                    self.annTouch();
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
                    // Restore the snapshot annotations exactly.
                    if (e.name) |n| self.ann.setName(e.id, n) catch {};
                    if (e.meta) |m| self.ann.setProvenance(e.id, m) catch {};
                    self.ann.applyFixes(e.chapter_fixes);
                    self.ann.applyGroupFixes(e.group_fixes);
                    if (e.tags.len > 0) {
                        var restore: std.ArrayList([]const u8) = .empty;
                        for (e.tags) |t| {
                            if (self.gpa.dupe(u8, t) catch null) |d| {
                                restore.append(self.gpa, d) catch self.gpa.free(d);
                            }
                        }
                        const owned = restore.toOwnedSlice(self.gpa) catch @as([][]const u8, &.{});
                        if (self.ann.giveTags(e.id, owned)) |_| {
                            // Strings transferred to the map; free the
                            // temporary pointer slice.
                            self.gpa.free(owned);
                        } else |_| {
                            self.ann.freeTags(owned);
                        }
                    }
                    self.annTouch();
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
                .name_set => |e| {
                    self.ann.setName(e.id, e.old) catch {};
                    self.annTouch();
                },
                .tag_add => |e| {
                    _ = self.ann.removeTag(e.id, e.tag);
                    self.annTouch();
                },
                .tag_remove => |e| {
                    _ = self.ann.addTag(e.id, e.tag) catch {};
                    self.annTouch();
                },
                .group_add => |e| {
                    self.ann.removeGroup(e.group.id);
                    self.annTouch();
                },
                .group_remove => |e| {
                    self.ann.addGroup(e.group.id, e.group.name, e.group.first, e.group.last) catch {};
                    self.annTouch();
                },
                .group_rename => |e| {
                    self.ann.renameGroup(e.id, e.old) catch {};
                    self.annTouch();
                },
                .param_add => |e| {
                    _ = self.ptab.remove(e.id);
                },
                .param_remove => |e| {
                    self.ptab.add(e.id, e.name, e.value) catch {};
                    self.invalidateReferencing(e.id);
                },
                .param_set => |e| {
                    _ = self.ptab.set(e.id, e.old);
                    self.invalidateReferencing(e.id);
                },
                .param_rename => |e| {
                    _ = self.ptab.rename(e.id, e.old) catch false;
                },
                .chapter_add => |e| {
                    self.ann.removeChapter(e.chapter.id);
                    self.annTouch();
                },
                .chapter_remove => |e| {
                    self.ann.addChapter(e.chapter.id, e.chapter.name, e.chapter.mark) catch {};
                    self.annTouch();
                },
                .chapter_rename => |e| {
                    self.ann.renameChapter(e.id, e.old) catch {};
                    self.annTouch();
                },
            }
        }

        fn forward(self: *Self, entry: journaling.Journal(Op).Entry) void {
            switch (entry) {
                .commit => |e| {
                    self.list.insert(self.gpa, e.at, .{ .id = e.id, .op = e.op }) catch return;
                    self.afterInsert(e.at);
                    if (e.meta) |m| self.ann.setProvenance(e.id, m) catch {};
                    if (e.meta != null) self.annTouch();
                },
                .edit => |e| {
                    const idx = self.indexOf(e.id) orelse return;
                    self.list.items[idx].op = e.new_op;
                    self.invalidate(idx);
                },
                .remove => |e| {
                    const idx = self.indexOf(e.id) orelse return;
                    const replacement: ?ft.FeatureId = if (idx + 1 < self.list.items.len)
                        self.list.items[idx + 1].id
                    else
                        null;
                    const fixes = self.ann.reanchorAfterRemove(e.id, replacement) catch @as([]annotations.ChapterFix, &.{});
                    self.gpa.free(fixes); // the entry keeps the originals
                    const gfixes = self.reanchorGroupBoundaries(e.id, idx) catch @as([]annotations.GroupFix, &.{});
                    self.gpa.free(gfixes);
                    self.ann.removeFeature(e.id); // frees name/tags
                    self.resetStatuses(idx);
                    _ = self.list.orderedRemove(idx);
                    self.marker_pos = if (e.at < e.marker_pre) e.marker_pre - 1 else e.marker_pre;
                    self.invalidate(idx);
                    self.annTouch();
                },
                .suppress => |e| {
                    const idx = self.indexOf(e.id) orelse return;
                    self.list.items[idx].suppressed = !e.prev;
                    self.invalidate(idx);
                },
                .move => |e| self.rawMove(e.id, e.to),
                .name_set => |e| {
                    self.ann.setName(e.id, e.new) catch {};
                    self.annTouch();
                },
                .tag_add => |e| {
                    _ = self.ann.addTag(e.id, e.tag) catch {};
                    self.annTouch();
                },
                .tag_remove => |e| {
                    _ = self.ann.removeTag(e.id, e.tag);
                    self.annTouch();
                },
                .group_add => |e| {
                    self.ann.removeGroup(e.group.id);
                    self.annTouch();
                },
                .group_remove => |e| {
                    self.ann.addGroup(e.group.id, e.group.name, e.group.first, e.group.last) catch {};
                    self.annTouch();
                },
                .group_rename => |e| {
                    self.ann.renameGroup(e.id, e.old) catch {};
                    self.annTouch();
                },
                .param_add => |e| {
                    self.ptab.add(e.id, e.name, e.value) catch {};
                    self.invalidateReferencing(e.id);
                },
                .param_remove => |e| {
                    _ = self.ptab.remove(e.id);
                    self.invalidateReferencing(e.id);
                },
                .param_set => |e| {
                    _ = self.ptab.set(e.id, e.new);
                    self.invalidateReferencing(e.id);
                },
                .param_rename => |e| {
                    _ = self.ptab.rename(e.id, e.new) catch false;
                },
                .chapter_add => |e| {
                    self.ann.addChapter(e.chapter.id, e.chapter.name, e.chapter.mark) catch {};
                    self.annTouch();
                },
                .chapter_remove => |e| {
                    self.ann.removeChapter(e.chapter.id);
                    self.annTouch();
                },
                .chapter_rename => |e| {
                    self.ann.renameChapter(e.id, e.new) catch {};
                    self.annTouch();
                },
            }
        }

        /// Re-anchor group boundaries when a member at `idx` is removed:
        /// the second member becomes `first`, the predecessor becomes `last`;
        /// with no members left the anchors go dead (empty folder). Returns
        /// the fixes needed to undo this exactly.
        fn reanchorGroupBoundaries(self: *Self, removed_id: ft.FeatureId, idx: u32) error{OutOfMemory}![]annotations.GroupFix {
            var fixes: std.ArrayList(annotations.GroupFix) = .empty;
            errdefer fixes.deinit(self.gpa);
            for (self.ann.groupsMut()) |*g| {
                const span = self.spanOf(g.first, g.last) orelse continue;
                const at_first = idx == span.lo;
                const at_last = idx == span.hi;
                if (!at_first and !at_last) continue;
                try fixes.append(self.gpa, .{ .group_id = g.id, .old_first = g.first, .old_last = g.last });
                if (at_first) {
                    g.first = if (span.lo + 1 <= span.hi) self.list.items[span.lo + 1].id else removed_id;
                }
                if (at_last) {
                    g.last = if (span.hi >= span.lo + 1) self.list.items[span.hi - 1].id else removed_id;
                }
            }
            return fixes.toOwnedSlice(self.gpa);
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

            ann: *const annotations.Annotations,

            pub fn next(self: *Iterator) ?FeatureView {
                if (self.i >= self.items.len) return null;
                const f = &self.items[self.i];
                self.i += 1;
                return .{
                    .id = f.id,
                    .op = &f.op,
                    .suppressed = f.suppressed,
                    .status = f.status,
                    .name = self.ann.nameOf(f.id),
                    .meta = self.ann.provenance(f.id),
                };
            }
        };

        /// Iterate features oldest-first. Statuses reflect the last completed
        /// rebuild (see `Status` for the validity rules).
        pub fn features(self: *const Self) Iterator {
            return .{ .items = self.list.items, .ann = &self.ann };
        }

        pub fn featureById(self: *const Self, id: ft.FeatureId) ?FeatureView {
            const idx = self.indexOf(id) orelse return null;
            const f = &self.list.items[idx];
            return .{
                .id = f.id,
                .op = &f.op,
                .suppressed = f.suppressed,
                .status = f.status,
                .name = self.ann.nameOf(id),
                .meta = self.ann.provenance(id),
            };
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
            // Snapshot parameter values: the table is owner-thread state and
            // may change while the job runs; only id/value are ever read.
            const param_snap = try self.gpa.dupe(ft.Param, self.ptab.items());
            errdefer self.gpa.free(param_snap);

            return .{
                .gpa = self.gpa,
                .generation = self.gen,
                .target = self.marker_pos,
                .start_pos = start_pos,
                .applied = start_pos,
                .base = base,
                .features = features_copy,
                .env = self.env,
                .param_values = param_snap,
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
                ft.rebuild.applyRange(Domain, self.list.items, self.built_pos, self.marker_pos, &self.live_doc, self.gpa, self.env, self.ptab.items(), &applied) catch |err| {
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
                ft.rebuild.applyRange(Domain, self.list.items, pos, end, &scratch, self.gpa, self.env, self.ptab.items(), &applied) catch |err| {
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
        /// Reads an external value through `ctx.env` (hierarchical-input test).
        read_env: void,
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
            .read_env => {
                const external: *const i64 = @ptrCast(@alignCast(ctx.env orelse
                    return ctx.fail("no environment registered", .{})));
                doc.value += external.*;
            },
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
        /// Reads a feature inside the "sub-timeline" introduced by
        /// `occurrence` — stands in for hierarchical references.
        audit: struct { occurrence: ft.FeatureId },
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
            .audit => doc.value += 1,
        }
    }
    pub fn dependencies(op: Op, out: *ft.DepCollector) void {
        switch (op) {
            .base => {},
            .offset => |o| out.dep(o.base_id),
            .audit => |a| out.depIn(a.occurrence, 0xDEAD),
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

test "refresh re-runs features whose external inputs changed" {
    const gpa = std.testing.allocator;
    var external: i64 = 5;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();
    tl.setEnv(&external);

    const watcher = try tl.commit(.{ .read_env = {} });
    _ = try tl.commit(.{ .add = 1 });
    try std.testing.expectEqual(@as(i64, 6), tl.state().value);

    // External state changes; the timeline cannot know, so it stays cached.
    external = 50;
    try std.testing.expectEqual(@as(i64, 6), tl.state().value);

    // refresh re-runs the feature and everything after it.
    tl.refresh(watcher);
    try std.testing.expectEqual(@as(i64, 51), tl.state().value);

    // refresh is invalidation, not an edit: undo still lands on the commit.
    _ = tl.undo();
    try std.testing.expectEqual(@as(i64, 50), tl.state().value);
}

test "depIn anchors ordering at the sub-timeline feature" {
    const gpa = std.testing.allocator;
    var tl = try Timeline(DepDomain).init(gpa, .{}, .{});
    defer tl.deinit();

    const b1 = try tl.commit(.{ .base = .{ .v = 10 } });
    _ = try tl.commit(.{ .offset = .{ .base_id = b1, .amount = 5 } });
    const aud = try tl.commit(.{ .audit = .{ .occurrence = b1 } });

    // Moving the audit before the feature that introduces its sub-timeline
    // is refused...
    try std.testing.expectError(error.DependencyViolation, tl.move(aud, 0));
    // ...but moving it to just after that feature is fine.
    try tl.move(aud, 1);
    try std.testing.expectEqual(@as(u32, 1), tl.indexOf(aud).?);
    try std.testing.expectEqual(@as(i64, 16), tl.state().value);
}

// ---------------------------------------------------------------------------
// Annotation tests (Wave 1)
// ---------------------------------------------------------------------------

test "feature names: set, view, undo/redo, survive removal round trip" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    const a = try tl.commit(.{ .add = 1 });
    const b = try tl.commit(.{ .add = 2 });
    try tl.setFeatureName(a, "hill");
    try tl.setFeatureName(b, "valley");
    try std.testing.expectEqualStrings("hill", tl.featureName(a).?);
    try std.testing.expectEqualStrings("valley", tl.featureById(b).?.name.?);

    // Rename is undoable and redoable.
    try tl.setFeatureName(a, "big hill");
    try std.testing.expectEqualStrings("big hill", tl.featureName(a).?);
    try std.testing.expect(tl.undo());
    try std.testing.expectEqualStrings("hill", tl.featureName(a).?);
    try std.testing.expect(tl.redo());
    try std.testing.expectEqualStrings("big hill", tl.featureName(a).?);

    // Undo unwinds annotation edits along with everything else (strict
    // LIFO); redo rewinds them through their own journal entries.
    _ = tl.undo(); // name a: big hill -> hill
    _ = tl.undo(); // name b: valley -> none
    _ = tl.undo(); // name a: hill -> none
    _ = tl.undo(); // commit b: feature gone
    try std.testing.expectEqual(@as(u32, 1), tl.len());
    try std.testing.expect(tl.featureName(b) == null);
    _ = tl.redo(); // commit b back
    _ = tl.redo(); // name a: hill
    _ = tl.redo(); // name b: valley
    try std.testing.expectEqualStrings("valley", tl.featureName(b).?);
    // Once a new edit clears the redo region, the names die for good.
    // (The fourth undo also removes feature `a` — its commit was popped.)
    _ = tl.undo();
    _ = tl.undo();
    _ = tl.undo();
    _ = tl.undo();
    const c3 = try tl.commit(.{ .add = 3 });
    try std.testing.expect(tl.featureName(b) == null);
    try std.testing.expect(tl.featureName(a) == null);
    try std.testing.expect(tl.featureById(a) == null);

    // Removal snapshots the name; undo restores it exactly.
    try tl.setFeatureName(c3, "keeper");
    tl.remove(c3);
    try std.testing.expect(tl.featureName(c3) == null);
    try std.testing.expect(tl.undo());
    try std.testing.expectEqualStrings("keeper", tl.featureName(c3).?);
}

test "chapters: anchor, jump, rename, and persistence of position" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    _ = try tl.commit(.{ .add = 1 });
    const b = try tl.commit(.{ .add = 2 });
    _ = try tl.commit(.{ .add = 3 });

    const mid = try tl.addChapter("after b", .{ .after = b });
    const tip = try tl.addChapter("latest", .{ .after = null });
    try std.testing.expectEqual(@as(u32, 2), tl.chapterPosition(mid).?);
    try std.testing.expectEqual(@as(u32, 3), tl.chapterPosition(tip).?);

    // Jump via the chapter.
    tl.setMarker(tl.chapterPosition(mid).?);
    try std.testing.expectEqual(@as(i64, 3), tl.state().value);

    // Renaming is undoable; removal is undoable.
    try tl.renameChapter(mid, "post-b");
    try std.testing.expectEqualStrings("post-b", tl.chapters()[0].name);
    try std.testing.expect(tl.undo());
    try std.testing.expectEqualStrings("after b", tl.chapters()[0].name);
    tl.removeChapter(tip);
    try std.testing.expectEqual(@as(usize, 1), tl.chapters().len);
    try std.testing.expect(tl.undo());
    try std.testing.expectEqual(@as(usize, 2), tl.chapters().len);

    // The chapter follows its anchor feature across moves.
    try tl.move(b, 0);
    try std.testing.expectEqual(@as(u32, 1), tl.chapterPosition(mid).?);

    // End-pinned follows the tip.
    _ = try tl.commit(.{ .add = 4 });
    try std.testing.expectEqual(@as(u32, 4), tl.chapterPosition(tip).?);
}

test "chapters: anchor removal re-anchors, undo restores exactly" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    _ = try tl.commit(.{ .add = 1 });
    const b = try tl.commit(.{ .add = 2 });
    const c = try tl.commit(.{ .add = 3 });
    const ch = try tl.addChapter("at b", .{ .after = b });
    try std.testing.expectEqual(@as(u32, 2), tl.chapterPosition(ch).?);

    // Removing the anchor re-anchors to the successor-in-place (c).
    tl.remove(b);
    try std.testing.expectEqual(@as(u32, 2), tl.chapterPosition(ch).?);
    try std.testing.expectEqual(c, tl.chapters()[0].mark.after.?);

    // Undo restores the original anchor.
    try std.testing.expect(tl.undo());
    try std.testing.expectEqual(b, tl.chapters()[0].mark.after.?);
    try std.testing.expectEqual(@as(u32, 2), tl.chapterPosition(ch).?);

    // Removing the current anchor (b, restored by the undo above) re-anchors
    // to its successor (c); removing the last feature pins to the end.
    tl.remove(b);
    try std.testing.expectEqual(c, tl.chapters()[0].mark.after.?);
    tl.remove(c);
    try std.testing.expect(tl.chapters()[0].mark.after == null);
}

var g_clock: u64 = 0;

test "provenance: explicit meta and clock auto-stamping" {
    const gpa = std.testing.allocator;
    g_clock = 1000;
    const clock: ft.Clock = struct {
        fn now() u64 {
            g_clock += 1;
            return g_clock;
        }
    }.now;

    var tl = try TestTimeline.init(gpa, .{}, .{ .now = clock });
    defer tl.deinit();

    const a = try tl.commit(.{ .add = 1 });
    const b = try tl.commitWithMeta(.{ .add = 2 }, .{ .author = 7, .ts = 5 });

    try std.testing.expectEqual(ft.Meta{ .ts = 1001 }, tl.provenance(a).?);
    try std.testing.expectEqual(ft.Meta{ .author = 7, .ts = 5 }, tl.provenance(b).?);
    try std.testing.expectEqual(@as(?ft.Meta, .{ .ts = 1001 }), tl.featureById(a).?.meta);

    // Provenance rides undo/redo of the commit.
    try std.testing.expect(tl.undo());
    try std.testing.expect(tl.provenance(b) == null);
    try std.testing.expect(tl.redo());
    try std.testing.expectEqual(ft.Meta{ .author = 7, .ts = 5 }, tl.provenance(b).?);
}

test "annotation edits do not invalidate document state or jobs" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    const a = try tl.commit(.{ .add = 1 });
    _ = tl.state();
    const gen_before = tl.gen;
    const v_before = tl.annotationsVersion();

    try tl.setFeatureName(a, "x");
    _ = try tl.addChapter("ch", .{ .after = a });
    try std.testing.expect(!tl.dirty());
    try std.testing.expectEqual(gen_before, tl.gen);
    try std.testing.expect(tl.annotationsVersion() != v_before);
}

test "tags: add, iterate, filter, undo/redo, remove round trip" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    const a = try tl.commit(.{ .add = 1 });
    const b = try tl.commit(.{ .add = 2 });

    try tl.addTag(a, "terrain");
    try tl.addTag(a, "terrain"); // set semantics: no duplicate
    try tl.addTag(a, "review");
    try tl.addTag(b, "terrain");
    try std.testing.expectEqual(@as(usize, 2), tl.tags(a).len);
    try std.testing.expectEqualStrings("terrain", tl.tags(a)[0]);
    try std.testing.expectEqualStrings("review", tl.tags(a)[1]);

    // Filter: oldest-first feature ids.
    var found: usize = 0;
    var it = tl.featuresTagged("terrain");
    while (it.next()) |id| {
        try std.testing.expect(found == 0 or found == 1);
        if (found == 0) try std.testing.expectEqual(a, id) else try std.testing.expectEqual(b, id);
        found += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), found);

    // Removal is undoable; add is undoable.
    tl.removeTag(a, "review");
    try std.testing.expectEqual(@as(usize, 1), tl.tags(a).len);
    try std.testing.expect(tl.undo());
    try std.testing.expectEqual(@as(usize, 2), tl.tags(a).len);
    try std.testing.expect(tl.redo());
    try std.testing.expectEqual(@as(usize, 1), tl.tags(a).len);

    // Feature removal snapshots tags; undo restores them exactly.
    tl.remove(a);
    try std.testing.expectEqual(@as(usize, 0), tl.tags(a).len);
    try std.testing.expect(tl.undo());
    try std.testing.expectEqual(@as(usize, 1), tl.tags(a).len);
    try std.testing.expectEqualStrings("terrain", tl.tags(a)[0]);
}

test "groups: membership computed from the span" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    const a = try tl.commit(.{ .add = 1 });
    const b = try tl.commit(.{ .add = 2 });
    const c = try tl.commit(.{ .add = 3 });
    const d = try tl.commit(.{ .add = 4 });
    _ = d;

    const g = (try tl.addGroup("middle", c, b)).?; // normalized: a-span b..c
    try std.testing.expectEqual(b, tl.groups()[0].first);
    try std.testing.expectEqual(c, tl.groups()[0].last);
    try std.testing.expectEqual(@as(?ft.annotations.GroupId, g), tl.groupOf(b));
    try std.testing.expectEqual(@as(?ft.annotations.GroupId, g), tl.groupOf(c));
    try std.testing.expect(tl.groupOf(a) == null);

    // Insert inside the span: joins the group.
    tl.setMarker(2);
    _ = try tl.commit(.{ .add = 5 });
    try std.testing.expectEqual(@as(?ft.annotations.GroupId, g), tl.groupOf(idAtIdx(&tl, 2)));

    // Ungroup keeps features.
    tl.removeGroup(g);
    try std.testing.expectEqual(@as(usize, 0), tl.groups().len);
    try std.testing.expectEqual(@as(u32, 5), tl.len());
    try std.testing.expect(tl.groupOf(b) == null);
}

fn idAtIdx(tl: *TestTimeline, idx: u32) ft.FeatureId {
    var it = tl.features();
    var i: u32 = 0;
    while (it.next()) |f| : (i += 1) {
        if (i == idx) return f.id;
    }
    unreachable;
}

test "groups: boundary removal re-anchors; empty survives; undo restores" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    const a = try tl.commit(.{ .add = 1 });
    const b = try tl.commit(.{ .add = 2 });
    const c = try tl.commit(.{ .add = 3 });
    const g = (try tl.addGroup("g", a, c)).?;

    // Remove the first member: second member becomes first.
    tl.remove(a);
    try std.testing.expectEqual(b, tl.groups()[0].first);
    try std.testing.expectEqual(@as(?ft.annotations.GroupId, g), tl.groupOf(b));

    // Undo restores the original boundary.
    try std.testing.expect(tl.undo());
    try std.testing.expectEqual(a, tl.groups()[0].first);

    // Remove everything the span covers: empty folder survives.
    tl.remove(a);
    tl.remove(b);
    tl.remove(c);
    try std.testing.expectEqual(@as(usize, 1), tl.groups().len);
    try std.testing.expectEqual(@as(usize, 0), tl.len());
}

test "groups: batch suppression is one undo step" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    const a = try tl.commit(.{ .add = 1 });
    _ = try tl.commit(.{ .add = 2 });
    const c = try tl.commit(.{ .add = 3 });
    _ = try tl.addGroup("g", a, c);

    tl.setGroupSuppressed(tl.groups()[0].id, true);
    try std.testing.expectEqual(@as(i64, 0), tl.state().value); // all suppressed

    // One undo restores every member's flag.
    try std.testing.expect(tl.undo());
    try std.testing.expectEqual(@as(i64, 6), tl.state().value);
    try std.testing.expect(tl.redo());
    try std.testing.expectEqual(@as(i64, 0), tl.state().value);
}

test "moveGroup relocates the block in one undo step" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    _ = try tl.commit(.{ .add = 1 });
    _ = try tl.commit(.{ .add = 2 });
    const c = try tl.commit(.{ .add = 3 });
    _ = try tl.commit(.{ .add = 4 });
    _ = try tl.commit(.{ .add = 5 });
    _ = try tl.addGroup("g", c, c); // single member at index 2

    try tl.moveGroup(tl.groups()[0].id, 0);
    try std.testing.expectEqual(c, idAtIdx(&tl, 0));
    try std.testing.expectEqual(@as(i64, 15), tl.state().value);

    try std.testing.expect(tl.undo());
    try std.testing.expectEqual(c, idAtIdx(&tl, 2));
    try std.testing.expectEqual(@as(i64, 15), tl.state().value);

    // Multi-member block keeps order and relocations adjust the marker per
    // crossing member.
    _ = try tl.commit(.{ .add = 0 });
    _ = tl.state();
    _ = try tl.addGroup("h", idAtIdx(&tl, 3), idAtIdx(&tl, 4)); // {3,4}
    const before = tl.state().value;
    try tl.moveGroup(tl.groups()[1].id, 0);
    _ = tl.state();
    const after = tl.state().value;
    // Members {3,4} moved before everything: sums commute here, so compare
    // membership instead of value.
    try std.testing.expectEqual(idAtIdx(&tl, 0), tl.groups()[1].first);
    _ = before;
    _ = after;
}

test "removeGroupContents deletes members and group in one undo step" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    const a = try tl.commit(.{ .add = 1 });
    const b = try tl.commit(.{ .add = 2 });
    _ = try tl.commit(.{ .add = 3 });
    _ = try tl.commit(.{ .add = 4 });
    const g = (try tl.addGroup("mid", a, b)).?;
    try tl.setFeatureName(b, "keeper");
    try tl.addTag(b, "terrain");

    tl.removeGroupContents(g);
    try std.testing.expectEqual(@as(u32, 2), tl.len());
    try std.testing.expectEqual(@as(usize, 0), tl.groups().len);
    try std.testing.expectEqual(@as(i64, 7), tl.state().value);

    // One undo restores members, the group, and every annotation.
    try std.testing.expect(tl.undo());
    try std.testing.expectEqual(@as(u32, 4), tl.len());
    try std.testing.expectEqual(@as(usize, 1), tl.groups().len);
    try std.testing.expectEqual(@as(i64, 10), tl.state().value);
    try std.testing.expectEqualStrings("keeper", tl.featureName(b).?);
    try std.testing.expectEqual(@as(usize, 1), tl.tags(b).len);
}

// ---------------------------------------------------------------------------
// Transaction tests (Wave 2)
// ---------------------------------------------------------------------------

test "transactions: a batch of edits undoes and redoes as one unit" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    _ = try tl.commit(.{ .add = 1 });

    tl.beginTransaction();
    const a = try tl.commit(.{ .add = 2 });
    tl.edit(a, .{ .add = 20 });
    try tl.setFeatureName(a, "adjusted");
    try tl.addTag(a, "batch");
    tl.endTransaction();

    try std.testing.expectEqual(@as(i64, 21), tl.state().value);
    try std.testing.expectEqualStrings("adjusted", tl.featureName(a).?);

    // One undo rewinds the whole batch.
    try std.testing.expect(tl.undo());
    try std.testing.expectEqual(@as(i64, 1), tl.state().value);
    try std.testing.expect(tl.featureName(a) == null);
    try std.testing.expectEqual(@as(usize, 0), tl.tags(a).len);

    // One redo replays it.
    try std.testing.expect(tl.redo());
    try std.testing.expectEqual(@as(i64, 21), tl.state().value);
    try std.testing.expectEqualStrings("adjusted", tl.featureName(a).?);
    try std.testing.expectEqual(@as(usize, 1), tl.tags(a).len);
}

test "transactions: nested begins flatten into the outermost unit" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    tl.beginTransaction();
    _ = try tl.commit(.{ .add = 1 });
    tl.beginTransaction();
    _ = try tl.commit(.{ .add = 2 });
    tl.endTransaction();
    _ = try tl.commit(.{ .add = 3 });
    tl.endTransaction();

    try std.testing.expectEqual(@as(i64, 6), tl.state().value);
    try std.testing.expect(tl.undo()); // all three commits at once
    try std.testing.expectEqual(@as(u32, 0), tl.len());
    try std.testing.expect(!tl.canUndo());
}

test "transactions: empty and unbalanced pairs are harmless" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    tl.endTransaction(); // unbalanced: no-op
    tl.beginTransaction();
    tl.endTransaction(); // empty: records nothing
    _ = try tl.commit(.{ .add = 5 });

    try std.testing.expect(tl.undo()); // exactly one undoable unit
    try std.testing.expect(!tl.canUndo());
}

test "transactions: eviction removes whole units, never a partial one" {
    const gpa = std.testing.allocator;
    var tl = try TestTimeline.init(gpa, .{}, .{ .max_journal = 7 });
    defer tl.deinit();

    // Three lone units, then one 10-record transaction: the cap is 7
    // records, so eviction must kick in and may only cut whole units.
    var i: u32 = 0;
    while (i < 3) : (i += 1) _ = try tl.commit(.{ .add = 1 });
    tl.beginTransaction();
    var k: u32 = 0;
    while (k < 5) : (k += 1) {
        _ = try tl.commit(.{ .add = 10 });
        tl.setSuppressed(tl.list.items[0].id, @mod(k, 2) == 0);
    }
    tl.endTransaction();

    // Undo only ever lands on unit boundaries: each undo leaves a state
    // that redo replays back to the same tip.
    const tip = tl.state().value;
    var undos: u32 = 0;
    var redone: u32 = 0;
    while (tl.undo()) {
        undos += 1;
    }
    while (tl.redo()) {
        redone += 1;
    }
    try std.testing.expectEqual(tip, tl.state().value);
    try std.testing.expectEqual(undos, redone); // symmetric units
    try std.testing.expect(undos >= 1);
}

// ---------------------------------------------------------------------------
// Parameter tests (Wave 3)
// ---------------------------------------------------------------------------

const ParamDomain = struct {
    pub const Doc = struct { value: i64 = 0 };
    pub const Op = union(enum) {
        add: i64,
        scale_by_param: ft.ParamId,
    };
    pub fn apply(op: Op, doc: *Doc, ctx: *ft.ApplyContext) anyerror!void {
        switch (op) {
            .add => |n| doc.value += n,
            .scale_by_param => |pid| {
                const v = ctx.param(pid) orelse
                    return ctx.fail("missing parameter", .{});
                doc.value = @intFromFloat(@round(@as(f64, @floatFromInt(doc.value)) * v));
            },
        }
        g_applies += 1;
    }
    pub fn references(op: Op, out: *ft.ParamRefCollector) void {
        switch (op) {
            .scale_by_param => |pid| out.param(pid),
            .add => {},
        }
    }
    pub fn cloneDoc(doc: *const Doc, gpa: std.mem.Allocator) anyerror!Doc {
        _ = gpa;
        return doc.*;
    }
    pub fn deinitDoc(doc: *Doc, gpa: std.mem.Allocator) void {
        _ = doc;
        _ = gpa;
    }
    pub fn encodeOp(op: Op, w: *std.Io.Writer) anyerror!void {
        switch (op) {
            .add => |n| {
                try w.writeAll(&[1]u8{1});
                try w.writeInt(i64, n, .little);
            },
            .scale_by_param => |pid| {
                try w.writeAll(&[1]u8{2});
                try w.writeInt(u64, pid, .little);
            },
        }
    }
    pub fn decodeOp(r: *std.Io.Reader, gpa: std.mem.Allocator) anyerror!Op {
        _ = gpa;
        return switch ((try r.take(1))[0]) {
            1 => .{ .add = try r.takeInt(i64, .little) },
            2 => .{ .scale_by_param = try r.takeInt(u64, .little) },
            else => error.Malformed,
        };
    }
    pub fn encodeDoc(doc: *const Doc, w: *std.Io.Writer) anyerror!void {
        try w.writeInt(i64, doc.value, .little);
    }
    pub fn decodeDoc(r: *std.Io.Reader, gpa: std.mem.Allocator) anyerror!Doc {
        _ = gpa;
        return .{ .value = try r.takeInt(i64, .little) };
    }
};

test "parameters: editing a value re-drives referencing features" {
    const gpa = std.testing.allocator;
    var tl = try Timeline(ParamDomain).init(gpa, .{}, .{});
    defer tl.deinit();

    const scale = try tl.addParam("scale", 2.0);
    _ = try tl.commit(.{ .add = 10 });
    _ = try tl.commit(.{ .scale_by_param = scale }); // 20
    _ = try tl.commit(.{ .add = 5 }); // 25
    try std.testing.expectEqual(@as(i64, 25), tl.state().value);

    tl.setParam(scale, 3.0); // 30 + 5 = 35
    try std.testing.expect(tl.dirty());
    try std.testing.expectEqual(@as(i64, 35), tl.state().value);

    // Undo restores the old value and recomputes.
    try std.testing.expect(tl.undo());
    try std.testing.expectEqual(@as(i64, 25), tl.state().value);
    try std.testing.expect(tl.redo());
    try std.testing.expectEqual(@as(i64, 35), tl.state().value);
}

test "parameters: suffix replay invalidates from the earliest reference" {
    const gpa = std.testing.allocator;
    var tl = try Timeline(ParamDomain).init(gpa, .{}, .{
        .checkpoint_interval = 2,
        .max_checkpoints = 8,
    });
    defer tl.deinit();

    const scale = try tl.addParam("scale", 1.0);
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        if (i == 4) {
            _ = try tl.commit(.{ .scale_by_param = scale });
        } else {
            _ = try tl.commit(.{ .add = 1 });
        }
    }
    // Fast-path commits lay no checkpoints; force one chunked rebuild
    // (a no-op-value edit still invalidates) to plant them at 2, 4, 6.
    tl.edit(tl.list.items[0].id, .{ .add = 1 });
    _ = tl.state();
    g_applies = 0;
    tl.setParam(scale, 2.0);
    _ = tl.state();
    // Over-approximate suffix replay: from the checkpoint at 4 (feature 4
    // is the earliest referencing feature), so features 4..7 replay.
    try std.testing.expectEqual(@as(usize, 4), g_applies);
}

test "parameters: unreferenced edits do not dirty the document" {
    const gpa = std.testing.allocator;
    var tl = try Timeline(ParamDomain).init(gpa, .{}, .{});
    defer tl.deinit();

    const unused = try tl.addParam("unused", 1.0);
    _ = try tl.commit(.{ .add = 7 });
    _ = tl.state();
    tl.setParam(unused, 99.0);
    try std.testing.expect(!tl.dirty());
}

test "parameters: removal soft-fails referencing features" {
    const gpa = std.testing.allocator;
    var tl = try Timeline(ParamDomain).init(gpa, .{}, .{});
    defer tl.deinit();

    const scale = try tl.addParam("scale", 2.0);
    _ = try tl.commit(.{ .add = 10 });
    _ = try tl.commit(.{ .scale_by_param = scale });
    try std.testing.expectEqual(@as(i64, 20), tl.state().value);

    tl.removeParam(scale);
    try std.testing.expectEqual(@as(i64, 10), tl.state().value);
    var it = tl.features();
    _ = it.next().?;
    try std.testing.expectEqualStrings("missing parameter", it.next().?.status.failed);

    // Undo brings the parameter back and the feature recomputes.
    try std.testing.expect(tl.undo());
    try std.testing.expectEqual(@as(i64, 20), tl.state().value);
}

test "parameters: rename is display-only; persistence round-trips" {
    const gpa = std.testing.allocator;
    var tl = try Timeline(ParamDomain).init(gpa, .{}, .{});
    defer tl.deinit();

    const scale = try tl.addParam("scale", 2.5);
    _ = try tl.commit(.{ .add = 4 });
    _ = try tl.commit(.{ .scale_by_param = scale });
    _ = tl.state();
    try tl.renameParam(scale, "growth");
    try std.testing.expectEqualStrings("growth", tl.paramsList()[0].name);
    try std.testing.expect(!tl.dirty());

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try save_persistence_shim(&tl, gpa, &aw.writer);
    var reader = std.Io.Reader.fixed(aw.written());
    var loaded = try load_persistence_shim(gpa, &reader);
    defer loaded.deinit();

    const grown = loaded.paramIdByName("growth").?;
    try std.testing.expectEqual(@as(f64, 2.5), loaded.paramValue(grown).?);
    try std.testing.expectEqual(@as(i64, 10), loaded.state().value);
}

// Persistence is generic over the Domain; tiny shims keep the test local.
fn save_persistence_shim(tl: *Timeline(ParamDomain), gpa: std.mem.Allocator, w: *std.Io.Writer) !void {
    try @import("persistence.zig").save(ParamDomain, tl, gpa, w);
}
fn load_persistence_shim(gpa: std.mem.Allocator, r: *std.Io.Reader) !Timeline(ParamDomain) {
    return @import("persistence.zig").load(ParamDomain, gpa, .{}, r);
}

// ---------------------------------------------------------------------------
// Sync feed tests (Wave 4)
// ---------------------------------------------------------------------------

const SyncTl = Timeline(ParamDomain);

const Outbox = struct {
    gpa: std.mem.Allocator,
    blobs: std.ArrayList([]u8) = .empty,

    fn deinit(self: *Outbox) void {
        for (self.blobs.items) |b| self.gpa.free(b);
        self.blobs.deinit(self.gpa);
    }

    fn observe(ctx: ?*anyopaque, entry: *const SyncTl.Entry) void {
        const self: *Outbox = @ptrCast(@alignCast(ctx.?));
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        syncing.encode(ParamDomain, entry, self.gpa, &aw.writer) catch {
            aw.deinit();
            return;
        };
        const owned = aw.toOwnedSlice() catch return;
        self.blobs.append(self.gpa, owned) catch self.gpa.free(owned);
    }

    /// Feed every recorded entry to `tl` through the wire codec, then
    /// drain (a real feed delivers each entry once; the library tolerates
    /// re-delivery regardless).
    fn feed(self: *Outbox, tl: *SyncTl) !void {
        for (self.blobs.items) |blob| {
            var reader = std.Io.Reader.fixed(blob);
            var entry = try syncing.decode(ParamDomain, self.gpa, &reader);
            tl.applyRemote(&entry);
            syncing.deinit(ParamDomain.Op, self.gpa, &entry);
        }
        for (self.blobs.items) |b| self.gpa.free(b);
        self.blobs.clearRetainingCapacity();
    }
};

fn expectConverged(a: *SyncTl, b: *SyncTl) !void {
    try std.testing.expectEqual(a.len(), b.len());
    try std.testing.expectEqual(a.state().value, b.state().value);
    var ia = a.features();
    var ib = b.features();
    while (ia.next()) |fa| {
        const fb = ib.next().?;
        try std.testing.expectEqual(fa.id, fb.id);
        try std.testing.expect(std.meta.eql(fa.op.*, fb.op.*));
        try std.testing.expectEqual(fa.suppressed, fb.suppressed);
        const na = a.featureName(fa.id);
        const nb = b.featureName(fb.id);
        if (na) |x| try std.testing.expectEqualStrings(x, nb.?) else try std.testing.expect(nb == null);
    }
}

test "sync: wire codec round-trips a remove entry with annotations" {
    const gpa = std.testing.allocator;
    var tl = try SyncTl.init(gpa, .{}, .{});
    defer tl.deinit();

    const a = try tl.commit(.{ .add = 3 });
    try tl.setFeatureName(a, "gone");
    try tl.addTag(a, "core");
    _ = try tl.addChapter("mark", .{ .after = a });

    // Capture the remove entry via the observer.
    var out = Outbox{ .gpa = gpa };
    defer out.deinit();
    tl.setRecordObserver(.{ .ctx = &out, .func = Outbox.observe });
    tl.remove(a);
    try std.testing.expectEqual(@as(usize, 1), out.blobs.items.len);

    // Decode it back and check the payload survived the wire.
    var reader = std.Io.Reader.fixed(out.blobs.items[0]);
    var entry = try syncing.decode(ParamDomain, gpa, &reader);
    defer syncing.deinit(ParamDomain.Op, gpa, &entry);
    try std.testing.expectEqual(a, entry.remove.id);
    try std.testing.expectEqualStrings("gone", entry.remove.name.?);
    try std.testing.expectEqual(@as(usize, 1), entry.remove.tags.len);
    try std.testing.expectEqualStrings("core", entry.remove.tags[0]);
    try std.testing.expectEqual(@as(usize, 1), entry.remove.chapter_fixes.len);
}

test "sync: replicas converge when fed each other's entries" {
    const gpa = std.testing.allocator;
    var tl1 = try SyncTl.init(gpa, .{}, .{});
    defer tl1.deinit();
    var out1 = Outbox{ .gpa = gpa };
    defer out1.deinit();
    tl1.setRecordObserver(.{ .ctx = &out1, .func = Outbox.observe });

    // Replica two: same identity via a persistence round trip.
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try @import("persistence.zig").save(ParamDomain, &tl1, gpa, &aw.writer);
    var reader = std.Io.Reader.fixed(aw.written());
    var tl2 = try @import("persistence.zig").load(ParamDomain, gpa, .{}, &reader);
    defer tl2.deinit();
    try std.testing.expectEqual(tl1.timelineId(), tl2.timelineId());
    var out2 = Outbox{ .gpa = gpa };
    defer out2.deinit();
    tl2.setRecordObserver(.{ .ctx = &out2, .func = Outbox.observe });

    // Session one on replica 1.
    const a = try tl1.commit(.{ .add = 10 });
    const b = try tl1.commit(.{ .scale_by_param = 0 }); // placeholder id, edited below
    _ = b;
    _ = try tl1.addParam("scale", 2.0);
    _ = try tl1.commit(.{ .add = 5 });
    try tl1.setFeatureName(a, "base");
    tl1.setSuppressed(a, true);
    tl1.setSuppressed(a, false);

    try out1.feed(&tl2);
    try expectConverged(&tl1, &tl2);
    // Echo suppression: integrating remote entries fired no observer.
    try std.testing.expectEqual(@as(usize, 0), out2.blobs.items.len);

    // Session two on replica 2 — including a param-driven edit.
    const scale = tl2.paramIdByName("scale").?;
    tl2.setParam(scale, 3.0);
    _ = try tl2.commit(.{ .scale_by_param = scale });
    try tl2.addTag(a, "remote");
    const c = try tl2.commit(.{ .add = 1 });
    tl2.remove(c);

    try out2.feed(&tl1);
    try expectConverged(&tl1, &tl2);
    // And a third round the other way to prove no loop formed.
    const d = try tl1.commit(.{ .add = 100 });
    tl1.edit(d, .{ .add = 200 });
    try out1.feed(&tl2);
    try expectConverged(&tl1, &tl2);

    // Locally committed ids never collide with remote ones.
    const fresh = try tl2.commit(.{ .add = 7 });
    var seen: usize = 0;
    var it = tl1.features();
    while (it.next()) |f| {
        if (f.id == fresh) seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), seen); // not yet fed
    try out2.feed(&tl1);
    it = tl1.features();
    while (it.next()) |f| {
        if (f.id == fresh) seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), seen);
}

test "sync: remote entries referencing unknown ids are dropped" {
    const gpa = std.testing.allocator;
    var tl = try SyncTl.init(gpa, .{}, .{});
    defer tl.deinit();
    _ = try tl.commit(.{ .add = 1 });

    const bogus: ft.FeatureId = 0xDEADBEEF;
    tl.applyRemote(&.{ .edit = .{ .id = bogus, .old_op = .{ .add = 0 }, .new_op = .{ .add = 9 } } });
    try std.testing.expectEqual(@as(u32, 1), tl.len());
    tl.applyRemote(&.{ .suppress = .{ .id = bogus, .prev = false } });
    var it2 = tl.features();
    try std.testing.expectEqual(false, it2.next().?.suppressed);
}

test "sync: remote edits undo locally as normal units" {
    const gpa = std.testing.allocator;
    var tl = try SyncTl.init(gpa, .{}, .{});
    defer tl.deinit();
    _ = try tl.commit(.{ .add = 1 });

    tl.applyRemote(&.{ .commit = .{ .id = 4242, .op = .{ .add = 10 }, .at = 1, .meta = null } });
    try std.testing.expectEqual(@as(i64, 11), tl.state().value);
    try std.testing.expect(tl.undo()); // remote commit undoes like a local one
    try std.testing.expectEqual(@as(i64, 1), tl.state().value);
    try std.testing.expect(tl.redo());
    try std.testing.expectEqual(@as(i64, 11), tl.state().value);
    // The id counter skips past the remote id.
    const fresh = try tl.commit(.{ .add = 1 });
    try std.testing.expect(fresh > 4242);
}
