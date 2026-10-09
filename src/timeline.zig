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

/// Process-local counter mixed into the fallback id-anchor entropy so two
/// timelines created in one process never share an id range (see
/// `Config.id_seed` for the multi-process story).
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
        /// What the record observer yields and `applyRemote` consumes.
        pub const Envelope = syncing.Envelope(Op);
        /// One undo/redo unit as reported by `history()`.
        pub const HistoryUnit = journaling.Journal(Op).Unit;
        pub const HistoryKind = journaling.Journal(Op).UnitKind;
        pub const HistoryIter = journaling.Journal(Op).UnitIter;

        gpa: std.mem.Allocator,
        config: ft.Config,

        /// Opaque environment reachable from `Domain.apply` as `ctx.env`.
        /// The seam for hierarchical timelines: point it at a registry of
        /// sub-timelines and parent features can read their computed state.
        /// Set via `setEnv` (or directly); read at apply time.
        env: ?*anyopaque = null,

        list: std.ArrayList(Feature) = .empty,

        /// Id → index, kept in sync by every list mutation (`listInsert`,
        /// `listRemove`, `rawMove`, `rebuildIndex`), so `indexOf`,
        /// `featureById` and the id-uniqueness check in `allocId` are O(1)
        /// instead of a scan of the whole feature list.
        index: std.AutoHashMapUnmanaged(ft.FeatureId, u32) = .empty,

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

        /// Next id to hand out — see `allocId`. Starts at a random 64-bit
        /// value per timeline so independently created replicas allocate
        /// from disjoint ranges; only local allocation ever advances it.
        next_id: ft.FeatureId,

        /// Generation counter: bumped by every mutation (structural edits and
        /// marker moves). Background jobs capture it at begin time;
        /// `integrate` rejects results whose generation went stale.
        gen: u64 = 0,

        /// Document checkpoint cache (internal).
        cps: checkpoint.Checkpoints(Domain),

        /// Undo/redo journal (internal).
        journal: journaling.Journal(Op),

        /// Annotation layer: names, tags, chapters, groups, provenance.
        /// Never affects document computation.
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

        /// This replica's identity in the sync feed: random per `init`, so a
        /// loaded timeline is a new replica. Stamped as `origin` into every
        /// envelope and into commit order keys.
        replica_id: u64,
        /// Lamport clock: advanced by every local edit, raised to any remote
        /// envelope's clock. Commit order keys carry it.
        lamport: u64 = 0,
        /// Sequence number of the last envelope this replica emitted.
        seq: u64 = 0,
        /// Highest sequence number integrated per remote origin.
        seen: std.AutoHashMapUnmanaged(u64, u64) = .empty,

        // ------------------------------------------------------------------
        // Lifecycle
        // ------------------------------------------------------------------

        pub fn init(gpa: std.mem.Allocator, seed_doc: Doc, config: ft.Config) !Self {
            const doc_gpa = config.doc_allocator orelse gpa;
            const live = try ft.cloneDoc(Domain, &seed_doc, doc_gpa);
            // Random id anchor: independently created timelines (other
            // peers, other processes) must allocate from disjoint id ranges,
            // and `allocId` only ever moves the counter forward from here.
            // `Config.id_seed` carries OS randomness in multi-replica
            // deployments; the fallback mixes ASLR'd addresses with a
            // process-local counter (see `idEntropy`).
            var prng = std.Random.DefaultPrng.init(config.id_seed orelse idEntropy(&live));
            return .{
                .gpa = gpa,
                .config = config,
                .seed_doc = seed_doc,
                .live_doc = live,
                .next_id = prng.random().int(ft.FeatureId) | 1,
                .cps = checkpoint.Checkpoints(Domain).init(gpa, doc_gpa, config.max_checkpoints),
                .journal = journaling.Journal(Op).init(gpa, config.max_journal, config.now),
                .ann = annotations.Annotations.init(gpa),
                .ptab = params.ParamTable.init(gpa),
                .timeline_id = prng.random().int(u64) | 1,
                .replica_id = prng.random().int(u64) | 1,
            };
        }

        /// Fallback entropy when `Config.id_seed` is null: a stack address
        /// (stack ASLR), a code address and a global's address (image
        /// slide), and a process-local counter. Always distinct within one
        /// process; across processes it relies on the OS randomizing the
        /// address space, which is likely but not guaranteed to differ.
        fn idEntropy(stack_anchor: *const anyopaque) u64 {
            const c = init_counter.fetchAdd(1, .monotonic);
            const stack: u64 = @intFromPtr(stack_anchor);
            const code: u64 = @intFromPtr(&idEntropy);
            const data: u64 = @intFromPtr(&init_counter);
            return stack ^ std.math.rotl(u64, code, 17) ^ std.math.rotl(u64, data, 41) ^ (c << 32) ^ 0x9E3779B97F4A7C15;
        }

        pub fn deinit(self: *Self) void {
            self.resetStatuses(0);
            self.list.deinit(self.gpa);
            self.index.deinit(self.gpa);
            self.seen.deinit(self.gpa);
            self.cps.deinit();
            self.journal.deinit();
            self.ann.deinit();
            self.ptab.deinit();
            ft.deinitDoc(Domain, &self.seed_doc, self.docAllocator());
            ft.deinitDoc(Domain, &self.live_doc, self.docAllocator());
        }

        /// Where document memory lives: `Config.doc_allocator` or the gpa.
        pub fn docAllocator(self: *const Self) std.mem.Allocator {
            return self.config.doc_allocator orelse self.gpa;
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
            self.recordAt(entry, self.nextLamport());
        }

        fn nextLamport(self: *Self) u64 {
            self.lamport += 1;
            return self.lamport;
        }

        /// Journal `entry` and, for a local edit, hand it to the observer in
        /// an envelope stamped with this replica's id, the next sequence
        /// number, and `lamport`.
        fn recordAt(self: *Self, entry: journaling.Journal(Op).Entry, lamport: u64) void {
            // The observer sees the whole entry before the journal takes it
            // (with `max_journal = 0` the journal frees the entry's memory
            // at once). The journal then keeps only the strings that are
            // not live in the annotations: see `stripLive`.
            if (!self.applying_remote) {
                if (self.observer) |obs| {
                    self.seq += 1;
                    obs.func(obs.ctx, &.{ .origin = self.replica_id, .seq = self.seq, .lamport = lamport, .entry = entry });
                }
            }
            var stored = entry;
            stripLive(&stored);
            self.journal.record(stored);
        }

        /// Strings that live in the annotations while an edit is applied
        /// are not the journal's to keep: undo takes them from there and
        /// redo puts them back, by position. The stored entry refers to
        /// them as null.
        fn stripLive(entry: *journaling.Journal(Op).Entry) void {
            switch (entry.*) {
                .name_set => |*e| e.new = null,
                .tag_add => |*e| e.tag = null,
                .chapter_add => |*e| e.name = null,
                .chapter_rename => |*e| e.new = null,
                .group_add => |*e| e.name = null,
                .group_rename => |*e| e.new = null,
                .param_add => |*e| e.name = null,
                .param_rename => |*e| e.new = null,
                else => {},
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
            // Allocate first, mutate second. The id and the lamport tick go
            // back on failure, so nothing observable moves.
            try self.journal.reserve(1);
            const saved_next_id = self.next_id;
            errdefer self.next_id = saved_next_id;
            const saved_lamport = self.lamport;
            errdefer self.lamport = saved_lamport;
            const id = self.allocId();
            const at = self.marker_pos;
            const after: ?ft.FeatureId = if (at > 0) self.list.items[at - 1].id else null;
            const lamport = self.nextLamport();
            const order: ft.OrderKey = .{ .lamport = lamport, .origin = self.replica_id };
            if (meta) |m| try self.ann.setProvenance(id, m);
            errdefer if (meta != null) self.ann.removeProvenance(id);
            try self.listInsert(at, .{ .id = id, .op = op, .order = order });
            self.touch();
            self.recordAt(.{ .commit = .{ .id = id, .op = op, .at = at, .meta = meta, .after = after, .order = order } }, lamport);
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
                var scratch = std.heap.ArenaAllocator.init(self.gpa);
                defer scratch.deinit();
                ft.rebuild.applyRange(Domain, self.list.items, at, at + 1, &self.live_doc, self.allocators(&scratch), self.env, self.ptab.items(), &applied) catch |err| {
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
        /// from the nearest surviving checkpoint.
        pub fn edit(self: *Self, id: ft.FeatureId, new_op: Op) error{ OutOfMemory, UnknownFeature }!void {
            const idx = self.indexOf(id) orelse return error.UnknownFeature;
            try self.journal.reserve(1);
            self.touch();
            const old_op = self.list.items[idx].op;
            self.record(.{ .edit = .{ .id = id, .old_op = old_op, .new_op = new_op } });
            self.list.items[idx].op = new_op;
            self.invalidate(idx);
        }

        /// Remove a feature from the timeline. The marker adjusts so the
        /// visible document stays consistent.
        pub fn remove(self: *Self, id: ft.FeatureId) error{ OutOfMemory, UnknownFeature }!void {
            const idx = self.indexOf(id) orelse return error.UnknownFeature;
            try self.removeAt(idx);
        }

        /// Remove the feature at a known-valid index, journaling annotation
        /// snapshots for exact undo. Shared by `remove`, `removeGroupContents`
        /// and remote integration (the observer is muted by `record` while
        /// `applying_remote` is set).
        fn removeAt(self: *Self, idx: u32) error{OutOfMemory}!void {
            try self.journal.reserve(1);
            const f = self.list.items[idx];
            const id = f.id;
            const replacement: ?ft.FeatureId = if (idx + 1 < self.list.items.len)
                self.list.items[idx + 1].id
            else
                null;

            // Every plan is allocated before anything changes, so an
            // allocation failure leaves the timeline exactly as it was. The
            // name and tags then move into the entry (no copies).
            const fixes = try self.ann.planReanchorAfterRemove(id, replacement);
            errdefer self.gpa.free(fixes);
            const group_fixes = try self.planGroupReanchor(id, idx, null);
            errdefer self.gpa.free(group_fixes);
            const name_snap = self.ann.takeName(id);
            const tags_snap = self.ann.takeTagList(id);

            self.touch();
            self.ann.applyFixesForward(fixes);
            self.ann.applyGroupFixesForward(group_fixes);
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
                .order = f.order,
                .group_fixes = group_fixes,
            } });
            self.ann.removeFeature(id);
            self.annTouch();
            self.resetStatuses(idx);
            _ = self.listRemove(idx);
            if (idx < self.marker_pos) self.marker_pos -= 1;
            self.invalidate(idx);
        }

        /// Suppress or unsuppress a feature. A suppressed feature stays on
        /// the timeline but is skipped by rebuilds. Setting the flag it
        /// already has is a no-op: nothing is journaled and in-flight
        /// background jobs stay valid.
        pub fn setSuppressed(self: *Self, id: ft.FeatureId, suppressed: bool) error{ OutOfMemory, UnknownFeature }!void {
            const idx = self.indexOf(id) orelse return error.UnknownFeature;
            if (self.list.items[idx].suppressed == suppressed) return;
            try self.journal.reserve(1);
            self.setSuppressedAt(idx, suppressed);
        }

        fn setSuppressedAt(self: *Self, idx: u32, suppressed: bool) void {
            const prev = self.list.items[idx].suppressed;
            if (prev == suppressed) return;
            self.touch();
            self.record(.{ .suppress = .{ .id = self.list.items[idx].id, .prev = prev } });
            self.list.items[idx].suppressed = suppressed;
            self.invalidate(idx);
        }

        // ------------------------------------------------------------------
        // Annotations: names, chapters, provenance
        // ------------------------------------------------------------------

        /// Assign (or replace) a feature's display name.
        pub fn setFeatureName(self: *Self, id: ft.FeatureId, new_name: []const u8) error{ OutOfMemory, UnknownFeature }!void {
            if (self.indexOf(id) == null) return error.UnknownFeature;
            try self.journal.reserve(1);
            try self.ann.reserveName();
            const owned = try self.gpa.dupe(u8, new_name);
            // The store keeps the only copy of the new name; the old name
            // moves into the journal entry.
            const old = self.ann.swapName(id, owned);
            self.record(.{ .name_set = .{ .id = id, .old = old, .new = owned } });
            self.annTouch();
        }

        /// Remove a feature's display name. No-op if it has none.
        pub fn clearFeatureName(self: *Self, id: ft.FeatureId) error{ OutOfMemory, UnknownFeature }!void {
            if (self.indexOf(id) == null) return error.UnknownFeature;
            if (self.ann.nameOf(id) == null) return;
            try self.journal.reserve(1);
            const old = self.ann.swapName(id, null);
            self.record(.{ .name_set = .{ .id = id, .old = old, .new = null } });
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
        pub fn addTag(self: *Self, id: ft.FeatureId, tag: []const u8) error{ OutOfMemory, UnknownFeature }!void {
            if (self.indexOf(id) == null) return error.UnknownFeature;
            if (self.ann.hasTag(id, tag)) return;
            try self.journal.reserve(1);
            try self.ann.reserveTag(id);
            const owned = try self.gpa.dupe(u8, tag);
            const at = self.ann.pushTag(id, owned);
            self.record(.{ .tag_add = .{ .id = id, .tag = owned, .at = at } });
            self.annTouch();
        }

        /// Remove a tag from a feature. No-op if the feature does not carry
        /// the tag.
        pub fn removeTag(self: *Self, id: ft.FeatureId, tag: []const u8) error{ OutOfMemory, UnknownFeature }!void {
            if (self.indexOf(id) == null) return error.UnknownFeature;
            if (!self.ann.hasTag(id, tag)) return;
            try self.journal.reserve(1);
            const taken = self.ann.takeTag(id, tag).?; // present: checked above
            self.record(.{ .tag_remove = .{ .id = id, .tag = taken.text, .at = taken.at } });
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
            try self.journal.reserve(1);
            const saved_next_id = self.next_id;
            errdefer self.next_id = saved_next_id;
            const cid: ft.ChapterId = self.allocId();
            try self.ann.addChapter(cid, name, mark);
            const at: u32 = @intCast(self.ann.chapterList().len - 1);
            self.record(.{ .chapter_add = .{ .id = cid, .mark = mark, .name = self.ann.chapterList()[at].name, .at = at } });
            self.annTouch();
            return cid;
        }

        /// Remove a chapter.
        pub fn removeChapter(self: *Self, id: ft.ChapterId) error{ OutOfMemory, UnknownChapter }!void {
            if (self.ann.chapterById(id) == null) return error.UnknownChapter;
            try self.journal.reserve(1);
            const taken = self.ann.takeChapter(id).?; // present: looked up above
            self.record(.{ .chapter_remove = .{ .id = taken.chapter.id, .mark = taken.chapter.mark, .name = taken.chapter.name, .at = taken.at } });
            self.annTouch();
        }

        pub fn renameChapter(self: *Self, id: ft.ChapterId, new_name: []const u8) error{ OutOfMemory, UnknownChapter }!void {
            if (self.ann.chapterById(id) == null) return error.UnknownChapter;
            try self.journal.reserve(1);
            const owned = try self.gpa.dupe(u8, new_name);
            const old = self.ann.swapChapterName(id, owned).?; // present: looked up above
            self.record(.{ .chapter_rename = .{ .id = id, .old = old, .new = owned } });
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

        /// Create a group spanning `first`..`last` (normalized by position)
        /// and return its id.
        pub fn addGroup(self: *Self, name: []const u8, first: ft.FeatureId, last: ft.FeatureId) error{ OutOfMemory, UnknownFeature }!ft.annotations.GroupId {
            const fi = self.indexOf(first) orelse return error.UnknownFeature;
            const li = self.indexOf(last) orelse return error.UnknownFeature;
            const lo = @min(fi, li);
            const hi = @max(fi, li);
            try self.journal.reserve(1);
            const saved_next_id = self.next_id;
            errdefer self.next_id = saved_next_id;
            const gid: ft.annotations.GroupId = self.allocId();
            const first_id = self.list.items[lo].id;
            const last_id = self.list.items[hi].id;
            try self.ann.addGroup(gid, name, first_id, last_id);
            const at: u32 = @intCast(self.ann.groupList().len - 1);
            self.record(.{ .group_add = .{ .id = gid, .first = first_id, .last = last_id, .name = self.ann.groupList()[at].name, .at = at } });
            self.annTouch();
            return gid;
        }

        /// Ungroup: remove the group, keep the features.
        pub fn removeGroup(self: *Self, id: ft.annotations.GroupId) error{ OutOfMemory, UnknownGroup }!void {
            if (self.ann.groupById(id) == null) return error.UnknownGroup;
            try self.journal.reserve(1);
            self.removeGroupKnown(id);
        }

        /// Remove a group that exists, with journal room reserved. Its name
        /// moves into the journal entry.
        fn removeGroupKnown(self: *Self, id: ft.annotations.GroupId) void {
            const taken = self.ann.takeGroup(id).?;
            self.record(.{ .group_remove = .{
                .id = taken.group.id,
                .first = taken.group.first,
                .last = taken.group.last,
                .name = taken.group.name,
                .at = taken.at,
            } });
            self.annTouch();
        }

        pub fn renameGroup(self: *Self, id: ft.annotations.GroupId, new_name: []const u8) error{ OutOfMemory, UnknownGroup }!void {
            if (self.ann.groupById(id) == null) return error.UnknownGroup;
            try self.journal.reserve(1);
            const owned = try self.gpa.dupe(u8, new_name);
            const old = self.ann.swapGroupName(id, owned).?; // present: looked up above
            self.record(.{ .group_rename = .{ .id = id, .old = old, .new = owned } });
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
        /// (a transaction over per-member suppress entries). An empty group
        /// is a no-op.
        pub fn setGroupSuppressed(self: *Self, id: ft.annotations.GroupId, suppressed: bool) error{ OutOfMemory, UnknownGroup }!void {
            const g = self.ann.groupById(id) orelse return error.UnknownGroup;
            const span = self.groupSpan(g) orelse return;
            try self.journal.reserve(span.hi - span.lo + 1);
            self.beginTransaction();
            defer self.endTransaction();
            var i: u32 = span.lo;
            while (i <= span.hi) : (i += 1) {
                self.setSuppressedAt(i, suppressed);
            }
        }

        /// Largest group `moveGroup` relocates: one journal entry per member
        /// rides in a single undo unit, and eviction never splits a unit.
        pub const max_group_move: u32 = 4096;

        pub const GroupMoveError = error{ DependencyViolation, UnknownGroup, GroupTooLarge, OutOfMemory };

        /// Relocate a group's members to `new_pos` (the block's first index
        /// in the resulting list), preserving member order — one undo step.
        /// Members cross the marker individually (same semantics as `move`).
        /// An empty group is a no-op; `error.DependencyViolation` when the
        /// resulting order would break declared dependencies;
        /// `error.GroupTooLarge` above `max_group_move` members.
        pub fn moveGroup(self: *Self, id: ft.annotations.GroupId, new_pos: u32) GroupMoveError!void {
            const g = self.ann.groupById(id) orelse return error.UnknownGroup;
            const span = self.groupSpan(g) orelse return;
            const n: u32 = span.hi - span.lo + 1;
            const to = @min(new_pos, @as(u32, @intCast(self.list.items.len)) - n);
            if (to == span.lo) return;
            if (n > max_group_move) return error.GroupTooLarge;
            if (comptime hasDeps(Domain)) {
                if (self.groupMoveViolatesDeps(span, to)) return error.DependencyViolation;
            }
            try self.journal.reserve(n);

            // A transaction of per-member move entries. Moving left, the
            // members not yet moved keep their original indices, so member k
            // sits at `span.lo + k` and lands at `to + k`. Moving right,
            // each removal shifts the rest of the block down to `span.lo`
            // and every member lands at the block's final end (`to + n - 1`):
            // earlier members slide left into place as later ones leave.
            const mark = self.journal.undoEntryCount();
            self.beginTransaction();
            defer self.endTransaction();
            var k: u32 = 0;
            while (k < n) : (k += 1) {
                const from: u32 = if (to < span.lo) span.lo + k else span.lo;
                const dest: u32 = if (to < span.lo) to + k else to + n - 1;
                const member = self.list.items[from].id;
                // Other folders re-anchor as members pass through them; the
                // folder being moved keeps its anchors (they travel with
                // the block). Out of memory mid-block: unwind what moved.
                const gfixes = self.planGroupReanchor(member, from, id) catch {
                    self.rollbackTo(mark);
                    return error.OutOfMemory;
                };
                self.touch();
                self.ann.applyGroupFixesForward(gfixes);
                self.record(.{ .move = .{
                    .id = member,
                    .from = from,
                    .to = dest,
                    .marker_pre = self.marker_pos,
                    .group_fixes = gfixes,
                } });
                self.rawMove(member, dest);
            }
        }

        /// A multi-step edit ran out of memory halfway: unwind the records
        /// it made since `mark`, so the caller sees an unchanged timeline.
        /// Reversing moves and suppression needs no allocation; the names
        /// and tags of an unwound removal come back on a best-effort basis.
        /// With `max_journal = 0` there is nothing to unwind. The unwound
        /// records are destroyed, never offered to `redo`.
        fn rollbackTo(self: *Self, mark: usize) void {
            while (self.journal.undoEntryCount() > mark) {
                var rec = self.journal.popNewest() orelse break;
                self.reverse(&rec.e);
                self.journal.destroyRecord(&rec);
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
        /// of per-member removes plus the group removal). An empty group
        /// just disappears. Member annotations ride the per-member remove
        /// snapshots.
        pub fn removeGroupContents(self: *Self, id: ft.annotations.GroupId) error{ OutOfMemory, UnknownGroup }!void {
            const g = self.ann.groupById(id) orelse return error.UnknownGroup;
            const gid = g.id;
            const span = self.groupSpan(g);
            const count: usize = if (span) |sp| sp.hi - sp.lo + 1 else 0;
            try self.journal.reserve(count + 1);
            const mark = self.journal.undoEntryCount();
            self.beginTransaction();
            defer self.endTransaction();
            var k: u32 = 0;
            while (k < count) : (k += 1) {
                // The span head keeps re-anchoring to the successor, so the
                // first member is always at the span start. Out of memory
                // mid-way: put back what was removed.
                const sp = self.groupSpan(self.ann.groupById(gid).?) orelse break;
                self.removeAt(sp.lo) catch {
                    self.rollbackTo(mark);
                    return error.OutOfMemory;
                };
            }
            self.removeGroupKnown(gid);
        }

        /// Reorder a feature to `new_pos` (clamped to the list; interpreted
        /// as the index in the resulting list, Fusion's drag semantics).
        ///
        /// When the Domain provides the optional `dependencies` hook, the
        /// move is validated first and `error.DependencyViolation` is
        /// returned — before any mutation — if it would place a dependency
        /// after a feature that reads it. Without the hook every move is
        /// allowed and breakage surfaces as failed features on rebuild,
        /// exactly like Fusion. Moving to the current position is a no-op.
        pub fn move(self: *Self, id: ft.FeatureId, new_pos: u32) MoveError!void {
            const from = self.indexOf(id) orelse return error.UnknownFeature;
            const to = @min(new_pos, @as(u32, @intCast(self.list.items.len - 1)));
            if (from == to) return;

            if (comptime hasDeps(Domain)) {
                if (self.depsViolated(from, to)) return error.DependencyViolation;
            }
            try self.journal.reserve(1);

            // Fusion folder semantics: a boundary member dragged out of its
            // span leaves the group, which re-anchors to the remaining
            // members (journaled for exact undo). Membership itself is
            // positional, so dragging a feature into a span joins it. The
            // plan is allocated before anything changes.
            const gfixes = try self.planGroupReanchor(id, from, null);
            self.touch();
            self.ann.applyGroupFixesForward(gfixes);
            self.record(.{ .move = .{
                .id = id,
                .from = from,
                .to = to,
                .marker_pre = self.marker_pos,
                .group_fixes = gfixes,
            } });
            self.rawMove(id, to);
        }

        pub const MoveError = error{ DependencyViolation, UnknownFeature, OutOfMemory };

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
            // Capacity is unchanged by the removal, so this cannot fail.
            self.list.insert(self.gpa, to, feature) catch unreachable;
            self.reindexRange(@min(from, to), @max(from, to));
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
        /// structure is untouched; this is invalidation, not an edit.
        pub fn refresh(self: *Self, id: ft.FeatureId) error{UnknownFeature}!void {
            const idx = self.indexOf(id) orelse return error.UnknownFeature;
            self.touch();
            self.invalidate(idx);
        }

        // ------------------------------------------------------------------
        // Parameters
        // ------------------------------------------------------------------

        /// Add a named numeric parameter and return its stable id. Names are
        /// unique; fails on a duplicate.
        pub fn addParam(self: *Self, name: []const u8, value: f64) error{ OutOfMemory, DuplicateParam }!ft.ParamId {
            try self.journal.reserve(1);
            const saved_next_id = self.next_id;
            errdefer self.next_id = saved_next_id;
            const pid: ft.ParamId = self.allocId();
            try self.ptab.add(pid, name, value);
            const at: u32 = @intCast(self.ptab.items().len - 1);
            self.record(.{ .param_add = .{ .id = pid, .name = self.ptab.items()[at].name, .value = value, .at = at } });
            return pid;
        }

        /// Set a parameter's value. Features referencing it (via the
        /// optional `Domain.references` hook) recompute lazily; without the
        /// hook the timeline cannot see the dependency and the app must
        /// `refresh` affected features itself. Setting the current value is
        /// a no-op.
        pub fn setParam(self: *Self, id: ft.ParamId, value: f64) error{ OutOfMemory, UnknownParam }!void {
            const old = self.ptab.valueOf(id) orelse return error.UnknownParam;
            if (old == value) return;
            try self.journal.reserve(1);
            _ = self.ptab.set(id, value);
            self.record(.{ .param_set = .{ .id = id, .old = old, .new = value } });
            self.touch();
            self.invalidateReferencing(id);
        }

        /// Remove a parameter. Referencing features see `ctx.param` return
        /// null on the next rebuild and typically soft-fail.
        pub fn removeParam(self: *Self, id: ft.ParamId) error{ OutOfMemory, UnknownParam }!void {
            if (self.ptab.byId(id) == null) return error.UnknownParam;
            try self.journal.reserve(1);
            const taken = self.ptab.take(id).?; // present: looked up above
            self.record(.{ .param_remove = .{ .id = id, .name = taken.param.name, .value = taken.param.value, .at = taken.at } });
            self.touch();
            self.invalidateReferencing(id);
        }

        /// Rename a parameter (display only — ops reference ids, not names).
        pub fn renameParam(self: *Self, id: ft.ParamId, new_name: []const u8) error{ OutOfMemory, UnknownParam }!void {
            if (self.ptab.byId(id) == null) return error.UnknownParam;
            try self.journal.reserve(1);
            const owned = try self.gpa.dupe(u8, new_name);
            const old = self.ptab.swapName(id, owned).?; // present: looked up above
            self.record(.{ .param_rename = .{ .id = id, .old = old, .new = owned } });
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
            func: *const fn (ctx: ?*anyopaque, env: *const Envelope) void,
        };

        /// Install the sync-feed observer: called for each locally journaled
        /// edit, in record order (including each entry inside a
        /// transaction), with an envelope carrying this replica's id, a
        /// per-replica sequence number (1, 2, 3, ...) and the Lamport clock.
        /// Remote integrations via `applyRemote` do not fire it. The
        /// envelope is borrowed — copy (or encode) what you need inside the
        /// callback.
        pub fn setRecordObserver(self: *Self, observer: RecordObserver) void {
            self.observer = observer;
        }

        /// This replica's id, as stamped into envelopes and order keys.
        pub fn replicaId(self: *const Self) u64 {
            return self.replica_id;
        }

        /// The sequence number this replica expects next from `origin`.
        pub fn expectedSeq(self: *const Self, origin: u64) u64 {
            return (self.seen.get(origin) orelse 0) + 1;
        }

        /// Declare that everything `origin` emitted up to and including
        /// `seq` is already reflected here — after a resync through a file,
        /// say — so the next envelope expected is `seq + 1`.
        pub fn acknowledge(self: *Self, origin: u64, seq: u64) error{OutOfMemory}!void {
            try self.seen.put(self.gpa, origin, seq);
        }

        pub const ApplyResult = enum {
            /// Integrated and journaled.
            applied,
            /// Nothing changed: the entry referenced ids this replica does
            /// not have, a commit already present, or a no-op.
            dropped,
            /// Sequence number at or below one already integrated from this
            /// origin: ignored (re-delivery is safe).
            duplicate,
            /// Sequence number beyond the next expected one: not applied.
            /// Fetch from `expectedSeq(origin)` first.
            gap,
            /// Emitted by this replica itself (an echo): ignored.
            own,
            /// An allocation failed before anything changed: retry later.
            out_of_memory,
        };

        /// Integrate an edit that originated on another replica.
        ///
        /// Sequencing: an envelope with `seq != 0` must be the next one from
        /// its origin — earlier ones are `.duplicate`, later ones `.gap`
        /// (not applied); `seq == 0` skips the check. Echoes of this
        /// replica's own envelopes are `.own`.
        ///
        /// Placement: a remote commit lands right after its predecessor
        /// (`after`), then past every following feature whose order key is
        /// greater — the same rule on every replica, so concurrent commits
        /// end up in the same order everywhere, whatever the delivery order.
        /// An unknown predecessor (removed, or not received yet) falls back
        /// to the positional hint. Other entries reference features by id;
        /// unknown ids are `.dropped`.
        ///
        /// Identity is exact: feature/chapter/group/param ids are preserved
        /// and never move the local id counter. The effect is journaled
        /// locally (undo is uniform) but never re-broadcast, so replicas
        /// feeding each other cannot loop. Structural entries bump the
        /// rebuild generation like local edits.
        ///
        /// Concurrent *moves* and *removes* are not reconciled: compare
        /// `structureDigest` after a sync round and resync through a file
        /// when they disagree.
        pub fn applyRemote(self: *Self, env: *const Envelope) ApplyResult {
            if (env.origin == self.replica_id) return .own;
            if (env.seq != 0) {
                const expected = self.expectedSeq(env.origin);
                if (env.seq < expected) return .duplicate;
                if (env.seq > expected) return .gap;
                self.seen.ensureUnusedCapacity(self.gpa, 1) catch return .out_of_memory;
            }
            self.journal.reserve(1) catch return .out_of_memory;
            const saved_lamport = self.lamport;
            if (env.lamport > self.lamport) self.lamport = env.lamport;
            const prev = self.applying_remote;
            self.applying_remote = true;
            defer self.applying_remote = prev;
            const result = self.applyRemoteInner(&env.entry);
            if (result == .out_of_memory) {
                // Nothing changed. The sequence stays unacknowledged, so
                // the sender can deliver the same envelope again.
                self.lamport = saved_lamport;
                return result;
            }
            if (env.seq != 0) self.seen.putAssumeCapacity(env.origin, env.seq);
            return result;
        }

        /// A hash of the feature order and suppression flags. Replicas that
        /// agree on it have the same structure; compare after a sync round
        /// to detect divergence.
        pub fn structureDigest(self: *const Self) u64 {
            var h = std.hash.Wyhash.init(0x5EED);
            for (self.list.items) |f| {
                h.update(std.mem.asBytes(&f.id));
                h.update(&[1]u8{@intFromBool(f.suppressed)});
            }
            return h.final();
        }

        /// Where a remote commit lands: right after its predecessor, then
        /// past every following feature whose order key is greater (a
        /// concurrent or later insert at the same spot that sorts first).
        /// Unknown predecessor: the positional hint, clamped.
        fn remotePosition(self: *const Self, after: ?ft.FeatureId, hint: u32, order: ft.OrderKey) u32 {
            const n: u32 = @intCast(self.list.items.len);
            var pos: u32 = 0;
            if (after) |a| pos = if (self.indexOf(a)) |i| i + 1 else @min(hint, n);
            while (pos < n and self.list.items[pos].order.greaterThan(order)) pos += 1;
            return pos;
        }

        fn applyRemoteInner(self: *Self, entry: *const Entry) ApplyResult {
            // Every arm allocates what it needs before it changes anything,
            // so `.out_of_memory` always means "nothing happened".
            switch (entry.*) {
                .commit => |e| {
                    // Re-delivery is possible in any feed protocol: a
                    // commit whose id already exists here was integrated.
                    if (self.indexOf(e.id) != null) return .dropped;
                    const at = self.remotePosition(e.after, e.at, e.order);
                    if (e.meta) |m| self.ann.setProvenance(e.id, m) catch return .out_of_memory;
                    self.listInsert(at, .{ .id = e.id, .op = e.op, .order = e.order }) catch {
                        if (e.meta != null) self.ann.removeProvenance(e.id);
                        return .out_of_memory;
                    };
                    self.touch();
                    self.journal.record(.{ .commit = .{
                        .id = e.id,
                        .op = e.op,
                        .at = at,
                        .meta = e.meta,
                        .after = e.after,
                        .order = e.order,
                    } });
                    self.afterRemoteInsert(at);
                },
                .edit => |e| {
                    const idx = self.indexOf(e.id) orelse return .dropped;
                    self.touch();
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
                    const idx = self.indexOf(e.id) orelse return .dropped;
                    self.removeAt(idx) catch return .out_of_memory;
                },
                .suppress => |e| {
                    // `prev` is the flag before the edit; a replica that
                    // already shows the new flag has nothing to do.
                    const idx = self.indexOf(e.id) orelse return .dropped;
                    const prev_flag = self.list.items[idx].suppressed;
                    if (prev_flag != e.prev) return .dropped;
                    self.touch();
                    self.journal.record(.{ .suppress = .{ .id = e.id, .prev = prev_flag } });
                    self.list.items[idx].suppressed = !e.prev;
                    self.invalidate(idx);
                },
                .move => |e| {
                    const from = self.indexOf(e.id) orelse return .dropped;
                    const to = @min(e.to, @as(u32, @intCast(self.list.items.len - 1)));
                    if (from == to) return .dropped;
                    // Boundary fixups are computed from the local state, not
                    // taken from the remote entry.
                    const gfixes = self.planGroupReanchor(e.id, from, null) catch return .out_of_memory;
                    self.touch();
                    self.ann.applyGroupFixesForward(gfixes);
                    self.journal.record(.{ .move = .{
                        .id = e.id,
                        .from = from,
                        .to = to,
                        .marker_pre = self.marker_pos,
                        .group_fixes = gfixes,
                    } });
                    self.rawMove(e.id, to);
                },
                .name_set => |e| {
                    if (self.indexOf(e.id) == null) return .dropped;
                    if (e.new == null and self.ann.nameOf(e.id) == null) return .dropped;
                    const owned: ?[]const u8 = if (e.new) |n| (self.gpa.dupe(u8, n) catch return .out_of_memory) else null;
                    self.ann.reserveName() catch {
                        if (owned) |o| self.gpa.free(o);
                        return .out_of_memory;
                    };
                    const old = self.ann.swapName(e.id, owned);
                    self.journal.record(.{ .name_set = .{ .id = e.id, .old = old, .new = null } });
                    self.annTouch();
                },
                .tag_add => |e| {
                    const text = e.tag orelse return .dropped;
                    if (self.indexOf(e.id) == null) return .dropped;
                    if (self.ann.hasTag(e.id, text)) return .dropped;
                    self.ann.reserveTag(e.id) catch return .out_of_memory;
                    const owned = self.gpa.dupe(u8, text) catch return .out_of_memory;
                    const at = self.ann.pushTag(e.id, owned);
                    self.journal.record(.{ .tag_add = .{ .id = e.id, .tag = null, .at = at } });
                    self.annTouch();
                },
                .tag_remove => |e| {
                    const text = e.tag orelse return .dropped;
                    const taken = self.ann.takeTag(e.id, text) orelse return .dropped;
                    self.journal.record(.{ .tag_remove = .{ .id = e.id, .tag = taken.text, .at = taken.at } });
                    self.annTouch();
                },
                .chapter_add => |e| {
                    const text = e.name orelse return .dropped;
                    if (self.ann.chapterById(e.id) != null) return .dropped;
                    self.ann.addChapter(e.id, text, e.mark) catch return .out_of_memory;
                    const at: u32 = @intCast(self.ann.chapterList().len - 1);
                    self.journal.record(.{ .chapter_add = .{ .id = e.id, .mark = e.mark, .name = null, .at = at } });
                    self.annTouch();
                },
                .chapter_remove => |e| {
                    const taken = self.ann.takeChapter(e.id) orelse return .dropped;
                    self.journal.record(.{ .chapter_remove = .{ .id = e.id, .mark = taken.chapter.mark, .name = taken.chapter.name, .at = taken.at } });
                    self.annTouch();
                },
                .chapter_rename => |e| {
                    const text = e.new orelse return .dropped;
                    if (self.ann.chapterById(e.id) == null) return .dropped;
                    const owned = self.gpa.dupe(u8, text) catch return .out_of_memory;
                    const old = self.ann.swapChapterName(e.id, owned).?;
                    self.journal.record(.{ .chapter_rename = .{ .id = e.id, .old = old, .new = null } });
                    self.annTouch();
                },
                .group_add => |e| {
                    const text = e.name orelse return .dropped;
                    if (self.ann.groupById(e.id) != null) return .dropped;
                    // Unknown anchors keep the folder empty (dead anchors)
                    // rather than dropping the group.
                    self.ann.addGroup(e.id, text, e.first, e.last) catch return .out_of_memory;
                    const at: u32 = @intCast(self.ann.groupList().len - 1);
                    self.journal.record(.{ .group_add = .{ .id = e.id, .first = e.first, .last = e.last, .name = null, .at = at } });
                    self.annTouch();
                },
                .group_remove => |e| {
                    const taken = self.ann.takeGroup(e.id) orelse return .dropped;
                    self.journal.record(.{ .group_remove = .{
                        .id = e.id,
                        .first = taken.group.first,
                        .last = taken.group.last,
                        .name = taken.group.name,
                        .at = taken.at,
                    } });
                    self.annTouch();
                },
                .group_rename => |e| {
                    const text = e.new orelse return .dropped;
                    if (self.ann.groupById(e.id) == null) return .dropped;
                    const owned = self.gpa.dupe(u8, text) catch return .out_of_memory;
                    const old = self.ann.swapGroupName(e.id, owned).?;
                    self.journal.record(.{ .group_rename = .{ .id = e.id, .old = old, .new = null } });
                    self.annTouch();
                },
                .param_add => |e| {
                    const text = e.name orelse return .dropped;
                    if (self.ptab.byId(e.id) != null) return .dropped;
                    self.ptab.add(e.id, text, e.value) catch |err| return if (err == error.OutOfMemory) .out_of_memory else .dropped;
                    const at: u32 = @intCast(self.ptab.items().len - 1);
                    self.journal.record(.{ .param_add = .{ .id = e.id, .name = null, .value = e.value, .at = at } });
                },
                .param_remove => |e| {
                    // Undo restores the local value, which a concurrent set
                    // may have changed since the sender looked.
                    const taken = self.ptab.take(e.id) orelse return .dropped;
                    self.touch();
                    self.journal.record(.{ .param_remove = .{ .id = e.id, .name = taken.param.name, .value = taken.param.value, .at = taken.at } });
                    self.invalidateReferencing(e.id);
                },
                .param_set => |e| {
                    const old = self.ptab.valueOf(e.id) orelse return .dropped;
                    if (old == e.new) return .dropped;
                    self.touch();
                    _ = self.ptab.set(e.id, e.new);
                    self.journal.record(.{ .param_set = .{ .id = e.id, .old = old, .new = e.new } });
                    self.invalidateReferencing(e.id);
                },
                .param_rename => |e| {
                    const text = e.new orelse return .dropped;
                    if (self.ptab.byId(e.id) == null) return .dropped;
                    const owned = self.gpa.dupe(u8, text) catch return .out_of_memory;
                    const old = self.ptab.swapName(e.id, owned).?;
                    self.journal.record(.{ .param_rename = .{ .id = e.id, .old = old, .new = null } });
                },
            }
            return .applied;
        }

        /// Bookkeeping after a *remote* feature lands at `at`. Unlike a local
        /// commit, the local marker is not moved onto the new feature: it
        /// shifts by one only when the insert happened at or before it, so
        /// the features the local user was looking at stay in view and a
        /// marker at the tip follows the tip. A remote insert in the grey
        /// future leaves the slider alone. The rebuild happens lazily.
        fn afterRemoteInsert(self: *Self, at: u32) void {
            self.cps.noteMutation(at);
            self.resetStatuses(at + 1);
            if (at <= self.marker_pos) self.marker_pos += 1;
            if (at < self.built_pos) self.live_stale = true;
        }

        /// Open an explicit transaction: every edit recorded before the
        /// matching `endTransaction` becomes one undo/redo unit. Nested
        /// begins flatten into the outermost unit. An empty transaction
        /// records nothing; an unbalanced end is a no-op. Always pair with
        /// `endTransaction` (`defer` pairs well).
        pub fn beginTransaction(self: *Self) void {
            self.journal.beginTxn();
        }

        /// `beginTransaction` with a label for history panels ("Smooth
        /// terrain"). Nested begins flatten; only the outermost label is
        /// kept. An empty transaction records nothing and drops the label.
        pub fn beginLabeledTransaction(self: *Self, label: []const u8) error{OutOfMemory}!void {
            try self.journal.beginTxnLabeled(label);
        }

        pub fn endTransaction(self: *Self) void {
            self.journal.endTxn();
        }

        // ------------------------------------------------------------------
        // Cherry-pick
        // ------------------------------------------------------------------

        pub const CherryPickOptions = struct {
            /// Copy the source feature's name, tags and provenance too.
            annotations: bool = true,
            /// Keep the source feature's suppressed flag.
            keep_suppressed: bool = true,
        };

        /// Copy one feature from another timeline of the same Domain (or
        /// from this one) and commit it at the marker as a new feature with
        /// a fresh id — one undo unit. Ops are plain data, so this is a
        /// value copy: ids inside the op are not translated; a dependent op
        /// whose dependency is absent here simply soft-fails on rebuild,
        /// like any other. Pairs with `persistence.savePrefix` for scenario
        /// variants.
        pub fn cherryPick(self: *Self, src: *const Self, id: ft.FeatureId, opts: CherryPickOptions) error{ OutOfMemory, UnknownFeature }!ft.FeatureId {
            const view = src.featureById(id) orelse return error.UnknownFeature;
            const op = view.op.*; // copy before mutating: `src` may be `self`
            const suppressed = view.suppressed;
            const meta: ?ft.Meta = if (opts.annotations and view.meta != null)
                view.meta
            else if (self.config.now) |now|
                .{ .ts = now() }
            else
                null;

            const mark = self.journal.undoEntryCount();
            const saved_next_id = self.next_id;
            self.beginTransaction();
            defer self.endTransaction();
            return self.cherryPickSteps(src, id, op, meta, suppressed, opts) catch |err| {
                self.rollbackTo(mark);
                self.next_id = saved_next_id; // the unwound feature's id is free again
                return err;
            };
        }

        fn cherryPickSteps(self: *Self, src: *const Self, id: ft.FeatureId, op: Op, meta: ?ft.Meta, suppressed: bool, opts: CherryPickOptions) error{ OutOfMemory, UnknownFeature }!ft.FeatureId {
            const new_id = try self.commitInner(op, meta);
            if (opts.annotations) {
                if (src.featureName(id)) |n| try self.setFeatureName(new_id, n);
                for (src.tags(id)) |t| try self.addTag(new_id, t);
            }
            if (opts.keep_suppressed and suppressed) try self.setSuppressed(new_id, true);
            return new_id;
        }

        // ------------------------------------------------------------------
        // History introspection
        // ------------------------------------------------------------------

        /// Iterate the journal's undo/redo units oldest-first: what each
        /// did (`kind`), how many entries it holds, its label and timestamp,
        /// and whether it is currently undone. Units are borrowed views;
        /// iterate before the next edit. Marker moves are not journaled and
        /// never appear here.
        pub fn history(self: *const Self) HistoryIter {
            return self.journal.units();
        }

        /// Units `undo` can unwind right now.
        pub fn undoDepth(self: *const Self) u32 {
            return self.journal.undoDepth();
        }

        /// Units `redo` can replay right now.
        pub fn redoDepth(self: *const Self) u32 {
            return self.journal.redoDepth();
        }

        // ------------------------------------------------------------------
        // Memory pressure
        // ------------------------------------------------------------------

        /// Counts of everything the timeline keeps alive. Documents are
        /// opaque to the library, so memory is reported as counts of document
        /// copies (seed + live + checkpoints) and journal entries.
        pub const Stats = struct {
            features: u32,
            marker: u32,
            dirty: bool,
            /// Document copies held by the checkpoint cache (plus seed and live).
            checkpoints: u32,
            journal_entries: u32,
            undo_units: u32,
            redo_units: u32,
            params: u32,
            chapters: u32,
            groups: u32,
        };

        pub fn stats(self: *const Self) Stats {
            return .{
                .features = self.len(),
                .marker = self.marker_pos,
                .dirty = self.dirty(),
                .checkpoints = self.cps.count(),
                .journal_entries = self.journal.entryCount(),
                .undo_units = self.journal.undoDepth(),
                .redo_units = self.journal.redoDepth(),
                .params = @intCast(self.ptab.items().len),
                .chapters = @intCast(self.ann.chapterList().len),
                .groups = @intCast(self.ann.groupList().len),
            };
        }

        /// Visit every document copy the timeline holds — the seed, the live
        /// document, and each checkpoint — for in-place transformations that
        /// keep the document's meaning: re-homing arena-backed documents into
        /// a fresh arena, compacting storage, accounting. Structure,
        /// statuses and the rebuild generation are untouched, so the visitor
        /// must not change what a document *represents*. Not valid while a
        /// background job is in flight (its base is not visited). An error
        /// from the visitor is returned as is; documents visited before it
        /// stay transformed.
        pub fn forEachDoc(self: *Self, ctx: anytype, comptime visit: fn (@TypeOf(ctx), *Doc) anyerror!void) anyerror!void {
            try visit(ctx, &self.seed_doc);
            try visit(ctx, &self.live_doc);
            for (self.cps.entries.items) |*e| try visit(ctx, &e.doc);
        }

        /// What `trim` may release. Null fields are left alone.
        pub const TrimBudget = struct {
            /// Keep at most this many checkpoints; the ones nearest the
            /// marker survive. The configured `max_checkpoints` is unchanged.
            checkpoints: ?u8 = null,
            /// Keep at most this many undo units; the oldest go first.
            undo_units: ?u32 = null,
            /// Drop everything redo could replay.
            drop_redo: bool = false,
        };

        pub const Trimmed = struct {
            checkpoints: u32 = 0,
            journal_entries: u32 = 0,
        };

        /// Release memory under pressure without changing the document or
        /// the structure: drop checkpoints (an optimization — scrubbing just
        /// gets slower) and old or redoable journal units (undo depth
        /// shrinks). Never touches the rebuild generation, so in-flight
        /// background jobs stay valid.
        pub fn trim(self: *Self, budget: TrimBudget) Trimmed {
            var out: Trimmed = .{};
            if (budget.checkpoints) |keep| out.checkpoints = self.cps.trimTo(keep, self.marker_pos);
            if (budget.drop_redo) out.journal_entries += self.journal.dropRedo();
            if (budget.undo_units) |keep| out.journal_entries += self.journal.trimUndo(keep);
            return out;
        }

        fn reverse(self: *Self, entry: *journaling.Journal(Op).Entry) void {
            switch (entry.*) {
                .commit => |e| {
                    const idx = self.indexOf(e.id) orelse return;
                    // LIFO has already unwound any annotations journaled
                    // above this commit; clear defensively in case future
                    // code paths leave one behind.
                    if (self.ann.takeName(e.id)) |n| self.gpa.free(n);
                    _ = self.ann.removeProvenance(e.id);
                    self.resetStatuses(idx);
                    _ = self.listRemove(idx);
                    self.marker_pos = e.at;
                    self.invalidate(idx);
                    self.annTouch();
                },
                .edit => |e| {
                    const idx = self.indexOf(e.id) orelse return;
                    self.list.items[idx].op = e.old_op;
                    self.invalidate(idx);
                },
                .remove => |*e| {
                    // Needs no memory: the removal left free slots in the
                    // list, the index, and the annotation maps.
                    self.listInsert(e.at, .{
                        .id = e.id,
                        .op = e.op,
                        .suppressed = e.suppressed,
                        .order = e.order,
                    }) catch return;
                    self.afterInsert(e.at);
                    self.marker_pos = @min(e.marker_pre, @as(u32, @intCast(self.list.items.len)));
                    // The snapshot annotations move back in; redo takes them again.
                    if (e.name) |n| {
                        e.name = null;
                        self.ann.giveName(e.id, n) catch {};
                    }
                    if (e.meta) |m| self.ann.setProvenance(e.id, m) catch {};
                    self.ann.applyFixes(e.chapter_fixes);
                    self.ann.applyGroupFixes(e.group_fixes);
                    if (e.tags.items.len > 0) {
                        const list = e.tags;
                        e.tags = .empty;
                        self.ann.giveTagList(e.id, list) catch {};
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
                    self.ann.applyGroupFixes(e.group_fixes);
                    // Restore the pre-move marker (rawMove's crossing
                    // adjustment started from the post-undo marker).
                    self.marker_pos = e.marker_pre;
                    self.annTouch();
                },
                .name_set => |*e| {
                    // Swap, no memory: the live name moves into the entry,
                    // the entry's old name moves back into the store.
                    const live = self.ann.swapName(e.id, e.old);
                    e.old = null;
                    e.new = live;
                    self.annTouch();
                },
                .tag_add => |*e| {
                    e.tag = self.ann.takeTagAt(e.id, e.at);
                    self.annTouch();
                },
                .tag_remove => |*e| {
                    if (e.tag) |text| {
                        e.tag = null;
                        self.ann.giveTagAt(e.id, text, e.at) catch {};
                    }
                    self.annTouch();
                },
                .group_add => |*e| {
                    if (self.ann.takeGroup(e.id)) |taken| {
                        e.name = taken.group.name;
                        e.first = taken.group.first;
                        e.last = taken.group.last;
                        e.at = taken.at;
                    }
                    self.annTouch();
                },
                .group_remove => |*e| {
                    if (e.name) |n| {
                        e.name = null;
                        self.ann.giveGroupAt(.{ .id = e.id, .name = n, .first = e.first, .last = e.last }, e.at) catch {};
                    }
                    self.annTouch();
                },
                .group_rename => |*e| {
                    if (e.old) |o| {
                        if (self.ann.swapGroupName(e.id, o)) |live| {
                            e.old = null;
                            e.new = live;
                        }
                    }
                    self.annTouch();
                },
                .param_add => |*e| {
                    if (self.ptab.take(e.id)) |taken| {
                        e.name = taken.param.name;
                        e.at = taken.at;
                    }
                },
                .param_remove => |*e| {
                    if (e.name) |n| {
                        e.name = null;
                        self.ptab.giveAt(.{ .id = e.id, .name = n, .value = e.value }, e.at) catch {};
                    }
                    self.invalidateReferencing(e.id);
                },
                .param_set => |e| {
                    _ = self.ptab.set(e.id, e.old);
                    self.invalidateReferencing(e.id);
                },
                .param_rename => |*e| {
                    if (e.old) |o| {
                        if (self.ptab.swapName(e.id, o)) |live| {
                            e.old = null;
                            e.new = live;
                        }
                    }
                },
                .chapter_add => |*e| {
                    if (self.ann.takeChapter(e.id)) |taken| {
                        e.name = taken.chapter.name;
                        e.mark = taken.chapter.mark;
                        e.at = taken.at;
                    }
                    self.annTouch();
                },
                .chapter_remove => |*e| {
                    if (e.name) |n| {
                        e.name = null;
                        self.ann.giveChapterAt(.{ .id = e.id, .name = n, .mark = e.mark }, e.at) catch {};
                    }
                    self.annTouch();
                },
                .chapter_rename => |*e| {
                    if (e.old) |o| {
                        if (self.ann.swapChapterName(e.id, o)) |live| {
                            e.old = null;
                            e.new = live;
                        }
                    }
                    self.annTouch();
                },
            }
        }

        fn forward(self: *Self, entry: *journaling.Journal(Op).Entry) void {
            switch (entry.*) {
                .commit => |e| {
                    self.listInsert(e.at, .{ .id = e.id, .op = e.op, .order = e.order }) catch return;
                    self.afterInsert(e.at);
                    if (e.meta) |m| self.ann.setProvenance(e.id, m) catch {};
                    if (e.meta != null) self.annTouch();
                },
                .edit => |e| {
                    const idx = self.indexOf(e.id) orelse return;
                    self.list.items[idx].op = e.new_op;
                    self.invalidate(idx);
                },
                .remove => |*e| {
                    const idx = self.indexOf(e.id) orelse return;
                    self.ann.applyFixesForward(e.chapter_fixes);
                    self.ann.applyGroupFixesForward(e.group_fixes);
                    // The name and tags return to the entry for the next undo.
                    e.name = self.ann.takeName(e.id);
                    e.tags = self.ann.takeTagList(e.id);
                    self.ann.removeFeature(e.id); // provenance
                    self.resetStatuses(idx);
                    _ = self.listRemove(idx);
                    self.marker_pos = if (e.at < e.marker_pre) e.marker_pre - 1 else e.marker_pre;
                    self.invalidate(idx);
                    self.annTouch();
                },
                .suppress => |e| {
                    const idx = self.indexOf(e.id) orelse return;
                    self.list.items[idx].suppressed = !e.prev;
                    self.invalidate(idx);
                },
                .move => |e| {
                    self.rawMove(e.id, e.to);
                    self.ann.applyGroupFixesForward(e.group_fixes);
                    self.annTouch();
                },
                .name_set => |*e| {
                    const live = self.ann.swapName(e.id, e.new);
                    e.new = null;
                    e.old = live;
                    self.annTouch();
                },
                .tag_add => |*e| {
                    if (e.tag) |text| {
                        e.tag = null;
                        self.ann.giveTagAt(e.id, text, e.at) catch {};
                    }
                    self.annTouch();
                },
                .tag_remove => |*e| {
                    e.tag = self.ann.takeTagAt(e.id, e.at);
                    self.annTouch();
                },
                .group_add => |*e| {
                    if (e.name) |n| {
                        e.name = null;
                        self.ann.giveGroupAt(.{ .id = e.id, .name = n, .first = e.first, .last = e.last }, e.at) catch {};
                    }
                    self.annTouch();
                },
                .group_remove => |*e| {
                    if (self.ann.takeGroup(e.id)) |taken| {
                        e.name = taken.group.name;
                        e.first = taken.group.first;
                        e.last = taken.group.last;
                        e.at = taken.at;
                    }
                    self.annTouch();
                },
                .group_rename => |*e| {
                    if (e.new) |n| {
                        if (self.ann.swapGroupName(e.id, n)) |live| {
                            e.new = null;
                            e.old = live;
                        }
                    }
                    self.annTouch();
                },
                .param_add => |*e| {
                    if (e.name) |n| {
                        e.name = null;
                        self.ptab.giveAt(.{ .id = e.id, .name = n, .value = e.value }, e.at) catch {};
                    }
                    self.invalidateReferencing(e.id);
                },
                .param_remove => |*e| {
                    if (self.ptab.take(e.id)) |taken| {
                        e.name = taken.param.name;
                        e.value = taken.param.value;
                        e.at = taken.at;
                    }
                    self.invalidateReferencing(e.id);
                },
                .param_set => |e| {
                    _ = self.ptab.set(e.id, e.new);
                    self.invalidateReferencing(e.id);
                },
                .param_rename => |*e| {
                    if (e.new) |n| {
                        if (self.ptab.swapName(e.id, n)) |live| {
                            e.new = null;
                            e.old = live;
                        }
                    }
                },
                .chapter_add => |*e| {
                    if (e.name) |n| {
                        e.name = null;
                        self.ann.giveChapterAt(.{ .id = e.id, .name = n, .mark = e.mark }, e.at) catch {};
                    }
                    self.annTouch();
                },
                .chapter_remove => |*e| {
                    if (self.ann.takeChapter(e.id)) |taken| {
                        e.name = taken.chapter.name;
                        e.mark = taken.chapter.mark;
                        e.at = taken.at;
                    }
                    self.annTouch();
                },
                .chapter_rename => |*e| {
                    if (e.new) |n| {
                        if (self.ann.swapChapterName(e.id, n)) |live| {
                            e.new = null;
                            e.old = live;
                        }
                    }
                    self.annTouch();
                },
            }
        }

        /// Plan the re-anchoring of group boundaries when the member at
        /// `idx` leaves its position (removed, or moved elsewhere): the
        /// second member becomes `first`, the predecessor becomes `last`. A
        /// folder whose only member leaves keeps that member as both anchors
        /// — removed, the anchors go dead (empty folder); moved, the folder
        /// travels with it. `exempt` (the folder `moveGroup` is relocating)
        /// is left alone. Pure: nothing changes until
        /// `applyGroupFixesForward`. Groups whose anchors would not change
        /// are not reported.
        fn planGroupReanchor(self: *const Self, leaving_id: ft.FeatureId, idx: u32, exempt: ?ft.annotations.GroupId) error{OutOfMemory}![]annotations.GroupFix {
            var fixes: std.ArrayList(annotations.GroupFix) = .empty;
            errdefer fixes.deinit(self.gpa);
            for (self.ann.groupList()) |g| {
                if (exempt) |x| {
                    if (g.id == x) continue;
                }
                const span = self.spanOf(g.first, g.last) orelse continue;
                const at_first = idx == span.lo;
                const at_last = idx == span.hi;
                if (!at_first and !at_last) continue;
                var new_first = g.first;
                var new_last = g.last;
                if (at_first) {
                    new_first = if (span.lo + 1 <= span.hi) self.list.items[span.lo + 1].id else leaving_id;
                }
                if (at_last) {
                    new_last = if (span.hi >= span.lo + 1) self.list.items[span.hi - 1].id else leaving_id;
                }
                if (new_first == g.first and new_last == g.last) continue;
                try fixes.append(self.gpa, .{
                    .group_id = g.id,
                    .old_first = g.first,
                    .old_last = g.last,
                    .new_first = new_first,
                    .new_last = new_last,
                });
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
            if (!have_base) base = try ft.cloneDoc(Domain, &self.seed_doc, self.docAllocator());
            errdefer ft.deinitDoc(Domain, &base, self.docAllocator());

            const features_copy = try self.gpa.dupe(ft.Feature(Op), self.list.items);
            errdefer self.gpa.free(features_copy);
            for (features_copy) |*f| f.status = .pending;
            // Snapshot parameter values: the table is owner-thread state and
            // may change while the job runs; only id/value are ever read.
            const param_snap = try self.gpa.dupe(ft.Param, self.ptab.items());
            errdefer self.gpa.free(param_snap);

            return .{
                .gpa = self.gpa,
                .doc_gpa = self.docAllocator(),
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
            if (job.generation != self.gen or !self.jobMatchesList(job)) {
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
            ft.deinitDoc(Domain, &self.live_doc, self.docAllocator());
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

        fn allocators(self: *const Self, scratch: *std.heap.ArenaAllocator) ft.rebuild.Allocators {
            return .{ .gpa = self.gpa, .doc = self.docAllocator(), .scratch = scratch };
        }

        /// Belt and braces for `integrate`: the job's private feature copy
        /// must still mirror the live list over the range it computed, or
        /// its statuses would land on the wrong features (or past the end).
        /// Every mutation path bumps the generation, which `integrate`
        /// checks first; this guard turns any future gap into a rejected
        /// job instead of corrupted state.
        fn jobMatchesList(self: *const Self, job: *const ft.rebuild.Job(Domain)) bool {
            if (job.features.len != self.list.items.len) return false;
            if (job.target > self.list.items.len) return false;
            for (job.features[0..job.target], self.list.items[0..job.target]) |jf, lf| {
                if (jf.id != lf.id) return false;
            }
            return true;
        }

        /// Hand out the next id from this timeline's random-anchored counter.
        /// Features, chapters, groups, and parameters share the space. Ids
        /// already present locally — including ones that arrived through
        /// `applyRemote` or `persistence.load` — are skipped, and 0 is
        /// reserved (chapter marks encode "end-pinned" as 0). Foreign ids
        /// never *advance* the counter: if they did, two replicas would hold
        /// identical counters after a single exchange and their next
        /// concurrent commits would collide.
        fn allocId(self: *Self) u64 {
            while (self.next_id == 0 or self.idInUse(self.next_id)) self.next_id +%= 1;
            const id = self.next_id;
            self.next_id +%= 1;
            return id;
        }

        fn idInUse(self: *const Self, id: u64) bool {
            return self.indexOf(id) != null or
                self.ann.chapterById(id) != null or
                self.ann.groupById(id) != null or
                self.ptab.byId(id) != null;
        }

        fn indexOf(self: *const Self, id: ft.FeatureId) ?u32 {
            return self.index.get(id);
        }

        /// Insert into the feature list, keeping the id index in sync. The
        /// index slot is reserved first so a failure leaves both untouched.
        fn listInsert(self: *Self, at: u32, feature: Feature) error{OutOfMemory}!void {
            try self.index.ensureUnusedCapacity(self.gpa, 1);
            try self.list.insert(self.gpa, at, feature);
            self.reindexRange(at, @intCast(self.list.items.len - 1));
        }

        /// Remove from the feature list, keeping the id index in sync.
        fn listRemove(self: *Self, idx: u32) Feature {
            const removed = self.list.orderedRemove(idx);
            _ = self.index.remove(removed.id);
            if (idx < self.list.items.len) self.reindexRange(idx, @intCast(self.list.items.len - 1));
            return removed;
        }

        /// Re-record the positions of `list[lo..=hi]`. Every id already has
        /// a slot except at most one fresh id reserved by `listInsert`.
        fn reindexRange(self: *Self, lo: u32, hi: u32) void {
            var i: u32 = lo;
            while (i <= hi) : (i += 1) {
                const id = self.list.items[i].id;
                if (self.index.getPtr(id)) |slot| {
                    slot.* = i;
                } else {
                    self.index.putAssumeCapacity(id, i);
                }
            }
        }

        /// Rebuild the id index from the feature list. Internal: used by
        /// `persistence.load`, which fills the list directly.
        pub fn rebuildIndex(self: *Self) error{OutOfMemory}!void {
            self.index.clearRetainingCapacity();
            try self.index.ensureTotalCapacity(self.gpa, @intCast(self.list.items.len));
            if (self.list.items.len > 0) self.reindexRange(0, @intCast(self.list.items.len - 1));
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
                ft.deinitDoc(Domain, &self.live_doc, self.docAllocator());
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
                var scratch = std.heap.ArenaAllocator.init(self.gpa);
                defer scratch.deinit();
                ft.rebuild.applyRange(Domain, self.list.items, self.built_pos, self.marker_pos, &self.live_doc, self.allocators(&scratch), self.env, self.ptab.items(), &applied) catch |err| {
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
            var scratch = ft.cloneDoc(Domain, base, self.docAllocator()) catch |err| {
                self.broken = err;
                return;
            };
            self.resetStatuses(start);
            var scratch_arena = std.heap.ArenaAllocator.init(self.gpa);
            defer scratch_arena.deinit();
            // Only positions still in the cache when the pass ends are worth
            // a document copy: the last `max_checkpoints` intervals before
            // the marker. Earlier ones would be evicted by later ones in this
            // very pass — a full clone each, for nothing (on a heap-heavy
            // document that was the whole cost of a rebuild).
            const interval: u64 = self.config.checkpoint_interval;
            const window: u64 = interval * @as(u64, self.config.max_checkpoints);
            const keep_from: u32 = if (interval == 0 or window >= self.marker_pos) 0 else @intCast(self.marker_pos - window);
            var pos: u32 = start;
            while (pos < self.marker_pos) {
                const end = if (self.config.checkpoint_interval > 0)
                    @min(pos + self.config.checkpoint_interval, self.marker_pos)
                else
                    self.marker_pos;
                var applied: u32 = pos;
                ft.rebuild.applyRange(Domain, self.list.items, pos, end, &scratch, self.allocators(&scratch_arena), self.env, self.ptab.items(), &applied) catch |err| {
                    ft.deinitDoc(Domain, &scratch, self.docAllocator());
                    self.broken = err;
                    return; // live_doc still holds the last good state
                };
                pos = end;
                if (end < self.marker_pos and end >= keep_from) {
                    self.cps.add(end, &scratch, self.list.items);
                }
            }
            ft.deinitDoc(Domain, &self.live_doc, self.docAllocator());
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

    try tl.setSuppressed(second, true);
    try std.testing.expectEqual(@as(i64, 4), tl.state().value);
    try std.testing.expectEqual(@as(u32, 3), tl.len());

    try tl.setSuppressed(second, false);
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

    try tl.edit(first, .{ .add = 10 });
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
    try tl.edit(ids[0], .{ .add = 100 });
    _ = tl.state();
    try std.testing.expectEqual(@as(i64, 135), tl.state().value);
    try std.testing.expectEqual(@as(usize, 8), g_applies);

    // Edit feature 5: the checkpoint at 4 survives; only features 4..7 replay.
    g_applies = 0;
    try tl.edit(ids[5], .{ .add = 50 });
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

    try tl.remove(second);
    try std.testing.expectEqual(@as(u32, 2), tl.len());
    try std.testing.expectEqual(@as(u32, 2), tl.marker());
    try std.testing.expectEqual(@as(i64, 4), tl.state().value);

    // Remove while rolled back so the removal is below the marker.
    tl.setMarker(2);
    try tl.remove(first);
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

    try tl.edit(first, .{ .add = 10 });
    try std.testing.expectEqual(@as(i64, 12), tl.state().value);
    try std.testing.expect(tl.undo());
    try std.testing.expectEqual(@as(i64, 3), tl.state().value);
    try std.testing.expect(tl.redo());
    try std.testing.expectEqual(@as(i64, 12), tl.state().value);

    try tl.setSuppressed(first, true);
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

    try tl.remove(first);
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

    try tl.remove(b1);
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
    try tl.edit(first, .{ .add = 10 });
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
    try tl.edit(first, .{ .add = 10 });

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
    try tl.edit(first, .{ .poison = {} });

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
    try tl.edit(ids[0], .{ .add = 1 }); // same value, still invalidates
    _ = tl.state();
    try tl.edit(ids[5], .{ .add = 50 });

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
    try tl.refresh(watcher);
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
    try tl.remove(c3);
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
    try tl.removeChapter(tip);
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
    try tl.remove(b);
    try std.testing.expectEqual(@as(u32, 2), tl.chapterPosition(ch).?);
    try std.testing.expectEqual(c, tl.chapters()[0].mark.after.?);

    // Undo restores the original anchor.
    try std.testing.expect(tl.undo());
    try std.testing.expectEqual(b, tl.chapters()[0].mark.after.?);
    try std.testing.expectEqual(@as(u32, 2), tl.chapterPosition(ch).?);

    // Removing the current anchor (b, restored by the undo above) re-anchors
    // to its successor (c); removing the last feature pins to the end.
    try tl.remove(b);
    try std.testing.expectEqual(c, tl.chapters()[0].mark.after.?);
    try tl.remove(c);
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
    try tl.removeTag(a, "review");
    try std.testing.expectEqual(@as(usize, 1), tl.tags(a).len);
    try std.testing.expect(tl.undo());
    try std.testing.expectEqual(@as(usize, 2), tl.tags(a).len);
    try std.testing.expect(tl.redo());
    try std.testing.expectEqual(@as(usize, 1), tl.tags(a).len);

    // Feature removal snapshots tags; undo restores them exactly.
    try tl.remove(a);
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

    const g = try tl.addGroup("middle", c, b); // normalized: a-span b..c
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
    try tl.removeGroup(g);
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
    const g = try tl.addGroup("g", a, c);

    // Remove the first member: second member becomes first.
    try tl.remove(a);
    try std.testing.expectEqual(b, tl.groups()[0].first);
    try std.testing.expectEqual(@as(?ft.annotations.GroupId, g), tl.groupOf(b));

    // Undo restores the original boundary.
    try std.testing.expect(tl.undo());
    try std.testing.expectEqual(a, tl.groups()[0].first);

    // Remove everything the span covers: empty folder survives.
    try tl.remove(a);
    try tl.remove(b);
    try tl.remove(c);
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

    try tl.setGroupSuppressed(tl.groups()[0].id, true);
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
    const g = try tl.addGroup("mid", a, b);
    try tl.setFeatureName(b, "keeper");
    try tl.addTag(b, "terrain");

    try tl.removeGroupContents(g);
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
    try tl.edit(a, .{ .add = 20 });
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
        try tl.setSuppressed(tl.list.items[0].id, @mod(k, 2) == 0);
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

    try tl.setParam(scale, 3.0); // 30 + 5 = 35
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
    try tl.edit(tl.list.items[0].id, .{ .add = 1 });
    _ = tl.state();
    g_applies = 0;
    try tl.setParam(scale, 2.0);
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
    try tl.setParam(unused, 99.0);
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

    try tl.removeParam(scale);
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

    fn observe(ctx: ?*anyopaque, env: *const SyncTl.Envelope) void {
        const self: *Outbox = @ptrCast(@alignCast(ctx.?));
        var aw: std.Io.Writer.Allocating = .init(self.gpa);
        syncing.encode(ParamDomain, env, self.gpa, &aw.writer) catch {
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
            var env = try syncing.decode(ParamDomain, self.gpa, &reader);
            _ = tl.applyRemote(&env);
            syncing.deinit(ParamDomain.Op, self.gpa, &env);
        }
        for (self.blobs.items) |b| self.gpa.free(b);
        self.blobs.clearRetainingCapacity();
    }
};

/// Envelopes from a fixed foreign replica. Its clock sits far above any
/// local Lamport value, so a commit with `after = null` lands first and
/// `after = X` lands right after X.
const foreign_origin: u64 = 0xA11CE;
var foreign_clock: u64 = 1 << 40;

fn remote(entry: SyncTl.Entry) SyncTl.Envelope {
    foreign_clock += 1;
    return .{ .origin = foreign_origin, .seq = 0, .lamport = foreign_clock, .entry = entry };
}

fn remoteCommit(id: ft.FeatureId, op: ParamDomain.Op, at: u32, after: ?ft.FeatureId) SyncTl.Envelope {
    foreign_clock += 1;
    return .{
        .origin = foreign_origin,
        .seq = 0,
        .lamport = foreign_clock,
        .entry = .{ .commit = .{
            .id = id,
            .op = op,
            .at = at,
            .meta = null,
            .after = after,
            .order = .{ .lamport = foreign_clock, .origin = foreign_origin },
        } },
    };
}

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
    try tl.remove(a);
    try std.testing.expectEqual(@as(usize, 1), out.blobs.items.len);

    // Decode it back and check the payload survived the wire.
    var reader = std.Io.Reader.fixed(out.blobs.items[0]);
    var env = try syncing.decode(ParamDomain, gpa, &reader);
    defer syncing.deinit(ParamDomain.Op, gpa, &env);
    try std.testing.expectEqual(a, env.entry.remove.id);
    try std.testing.expectEqualStrings("gone", env.entry.remove.name.?);
    try std.testing.expectEqual(@as(usize, 1), env.entry.remove.tags.items.len);
    try std.testing.expectEqualStrings("core", env.entry.remove.tags.items[0]);
    try std.testing.expectEqual(@as(usize, 1), env.entry.remove.chapter_fixes.len);
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
    try tl1.setSuppressed(a, true);
    try tl1.setSuppressed(a, false);

    try out1.feed(&tl2);
    try expectConverged(&tl1, &tl2);
    // Echo suppression: integrating remote entries fired no observer.
    try std.testing.expectEqual(@as(usize, 0), out2.blobs.items.len);

    // Session two on replica 2 — including a param-driven edit.
    const scale = tl2.paramIdByName("scale").?;
    try tl2.setParam(scale, 3.0);
    _ = try tl2.commit(.{ .scale_by_param = scale });
    try tl2.addTag(a, "remote");
    const c = try tl2.commit(.{ .add = 1 });
    try tl2.remove(c);

    try out2.feed(&tl1);
    try expectConverged(&tl1, &tl2);
    // And a third round the other way to prove no loop formed.
    const d = try tl1.commit(.{ .add = 100 });
    try tl1.edit(d, .{ .add = 200 });
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
    try std.testing.expectEqual(SyncTl.ApplyResult.dropped, tl.applyRemote(&remote(.{ .edit = .{ .id = bogus, .old_op = .{ .add = 0 }, .new_op = .{ .add = 9 } } })));
    try std.testing.expectEqual(@as(u32, 1), tl.len());
    try std.testing.expectEqual(SyncTl.ApplyResult.dropped, tl.applyRemote(&remote(.{ .suppress = .{ .id = bogus, .prev = false } })));
    var it2 = tl.features();
    try std.testing.expectEqual(false, it2.next().?.suppressed);
}

test "sync: remote edits undo locally as normal units" {
    const gpa = std.testing.allocator;
    var tl = try SyncTl.init(gpa, .{}, .{});
    defer tl.deinit();
    const first = try tl.commit(.{ .add = 1 });

    try std.testing.expectEqual(SyncTl.ApplyResult.applied, tl.applyRemote(&remoteCommit(4242, .{ .add = 10 }, 1, first)));
    try std.testing.expectEqual(@as(i64, 11), tl.state().value);
    try std.testing.expect(tl.undo()); // remote commit undoes like a local one
    try std.testing.expectEqual(@as(i64, 1), tl.state().value);
    try std.testing.expect(tl.redo());
    try std.testing.expectEqual(@as(i64, 11), tl.state().value);
    // A fresh local id never collides with the remote one, and the remote id
    // did not move the local counter (see allocId).
    const fresh = try tl.commit(.{ .add = 1 });
    try std.testing.expect(fresh != 4242);
    var seen: usize = 0;
    var it = tl.features();
    while (it.next()) |f| {
        if (f.id == fresh) seen += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), seen);
}

test "ids: local allocation skips ids already present and never re-issues a foreign id" {
    const gpa = std.testing.allocator;
    var tl = try SyncTl.init(gpa, .{}, .{});
    defer tl.deinit();

    // Park the local counter just below a foreign id, then integrate it.
    tl.next_id = 999;
    _ = tl.applyRemote(&remoteCommit(1000, .{ .add = 1 }, 0, null));
    try std.testing.expectEqual(@as(u64, 999), tl.next_id); // foreign ids do not move the counter

    const x = try tl.commit(.{ .add = 2 });
    const y = try tl.commit(.{ .add = 3 });
    try std.testing.expectEqual(@as(u64, 999), x);
    try std.testing.expectEqual(@as(u64, 1001), y); // 1000 is taken, skipped
    const chapter = try tl.addChapter("c", .{ .after = null });
    try std.testing.expectEqual(@as(u64, 1002), chapter); // one shared id space

    // 0 is reserved (chapter marks use it for "end-pinned").
    tl.next_id = 0;
    const z = try tl.commit(.{ .add = 4 });
    try std.testing.expect(z != 0);
}

test "sync: concurrent commits after a round trip get distinct ids and both survive" {
    const gpa = std.testing.allocator;
    var alice = try SyncTl.init(gpa, .{}, .{});
    defer alice.deinit();
    var bob = try SyncTl.init(gpa, .{}, .{});
    defer bob.deinit();
    var out_a = Outbox{ .gpa = gpa };
    defer out_a.deinit();
    var out_b = Outbox{ .gpa = gpa };
    defer out_b.deinit();
    alice.setRecordObserver(.{ .ctx = &out_a, .func = Outbox.observe });
    bob.setRecordObserver(.{ .ctx = &out_b, .func = Outbox.observe });

    // One round trip. (This used to leave both replicas with the same
    // id counter, so the next concurrent commits collided and were dropped
    // as duplicates — silent divergence.)
    _ = try alice.commit(.{ .add = 1 });
    try out_a.feed(&bob);
    _ = try bob.commit(.{ .add = 2 });
    try out_b.feed(&alice);
    try std.testing.expectEqual(alice.state().value, bob.state().value);

    // Both users commit before the next sync.
    const a_id = try alice.commit(.{ .add = 100 });
    const b_id = try bob.commit(.{ .add = 200 });
    try std.testing.expect(a_id != b_id);

    try out_a.feed(&bob);
    try out_b.feed(&alice);
    try std.testing.expectEqual(@as(u32, 4), alice.len());
    try std.testing.expectEqual(@as(u32, 4), bob.len());
    try std.testing.expect(alice.featureById(b_id) != null);
    try std.testing.expect(bob.featureById(a_id) != null);
    // Commutative ops: identical documents even though the two concurrent
    // inserts landed in opposite positional order (ordering concurrent
    // positional edits is the application's layer, as documented).
    try std.testing.expectEqual(@as(i64, 303), alice.state().value);
    try std.testing.expectEqual(@as(i64, 303), bob.state().value);
}

test "sync: a remote commit landing during a background job makes the job stale" {
    const gpa = std.testing.allocator;
    var tl = try SyncTl.init(gpa, .{}, .{});
    defer tl.deinit();
    const a = try tl.commit(.{ .add = 1 });
    _ = try tl.commit(.{ .add = 2 });
    try tl.edit(a, .{ .add = 5 }); // dirty: the job will compute [5, 2]
    var job = try tl.beginRebuild();
    defer job.deinit();

    _ = tl.applyRemote(&remoteCommit(4242, .{ .add = 100 }, 0, null));
    job.run();
    try std.testing.expect(!tl.integrate(&job)); // the plan changed under the job
    try std.testing.expect(tl.dirty());

    // The insert landed before the marker, so the marker shifted with its
    // features (2 -> 3) and the document is [100, 5, 2].
    try std.testing.expectEqual(@as(u32, 3), tl.marker());
    try std.testing.expectEqual(@as(i64, 107), tl.state().value);
}

test "sync: a remote remove landing during a background job is rejected, not a crash" {
    const gpa = std.testing.allocator;
    var tl = try SyncTl.init(gpa, .{}, .{});
    defer tl.deinit();
    const a = try tl.commit(.{ .add = 1 });
    const b = try tl.commit(.{ .add = 2 });
    try tl.edit(a, .{ .add = 5 });
    var job = try tl.beginRebuild(); // plan: 2 features
    defer job.deinit();

    _ = tl.applyRemote(&remote(.{ .remove = .{ .id = b, .op = .{ .add = 2 }, .at = 1, .suppressed = false, .marker_pre = 2 } }));
    try std.testing.expectEqual(@as(u32, 1), tl.len());
    job.run();
    try std.testing.expect(!tl.integrate(&job)); // used to index past the end of the list
    try std.testing.expectEqual(@as(i64, 5), tl.state().value);
}

test "integrate: the feature-list guard rejects a mismatched job even if the generation matches" {
    const gpa = std.testing.allocator;
    var tl = try SyncTl.init(gpa, .{}, .{});
    defer tl.deinit();
    const a = try tl.commit(.{ .add = 1 });
    _ = try tl.commit(.{ .add = 2 });
    try tl.edit(a, .{ .add = 5 });
    var job = try tl.beginRebuild();
    defer job.deinit();

    _ = tl.applyRemote(&remoteCommit(4242, .{ .add = 100 }, 0, null));
    tl.gen = job.generation; // simulate a mutation path that forgot to bump the generation
    job.run();
    try std.testing.expect(!tl.integrate(&job));
    try std.testing.expect(tl.dirty());
    try std.testing.expectEqual(@as(i64, 107), tl.state().value);
}

test "sync: a remote insert moves the local marker only when it lands at or before it" {
    const gpa = std.testing.allocator;
    var tl = try SyncTl.init(gpa, .{}, .{});
    defer tl.deinit();
    _ = try tl.commit(.{ .add = 1 });
    _ = try tl.commit(.{ .add = 2 });
    const third = try tl.commit(.{ .add = 3 });

    // Scrubbed back to the empty document: an insert in the grey future
    // must not yank the slider.
    tl.setMarker(0);
    _ = tl.applyRemote(&remoteCommit(7001, .{ .add = 10 }, 3, third));
    try std.testing.expectEqual(@as(u32, 0), tl.marker());
    try std.testing.expectEqual(@as(i64, 0), tl.state().value);

    // Looking at [1]: an insert before the marker keeps those features in
    // view, so the marker shifts by one and the new feature is visible.
    tl.setMarker(1);
    _ = tl.applyRemote(&remoteCommit(7002, .{ .add = 100 }, 0, null));
    try std.testing.expectEqual(@as(u32, 2), tl.marker());
    try std.testing.expectEqual(@as(i64, 101), tl.state().value);

    // At the tip: the tip follows.
    tl.setMarker(tl.len());
    _ = tl.applyRemote(&remoteCommit(7003, .{ .add = 1000 }, 5, 7001));
    try std.testing.expectEqual(tl.len(), tl.marker());
    try std.testing.expectEqual(@as(i64, 1116), tl.state().value);
}

test "groups: moving a boundary member out re-anchors the span; undo restores it exactly" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    const a = try tl.commit(.{ .add = 1 });
    const b = try tl.commit(.{ .add = 2 });
    const c = try tl.commit(.{ .add = 3 });
    const d = try tl.commit(.{ .add = 4 });
    const g = try tl.addGroup("g", a, c); // [a b c] d

    // Drag the first member below the folder: it leaves, b becomes first.
    try tl.move(a, 3); // [b c] d a
    try std.testing.expectEqual(b, tl.groups()[0].first);
    try std.testing.expectEqual(c, tl.groups()[0].last);
    try std.testing.expect(tl.groupOf(a) == null);
    try std.testing.expect(tl.groupOf(d) == null);
    try std.testing.expectEqual(@as(?ft.annotations.GroupId, g), tl.groupOf(b));
    try std.testing.expect(tl.undo()); // [a b c] d
    try std.testing.expectEqual(a, tl.groups()[0].first);
    try std.testing.expectEqual(@as(?ft.annotations.GroupId, g), tl.groupOf(a));

    // Drag the last member out past d: it leaves, b becomes last.
    try tl.move(c, 3); // [a b] d c
    try std.testing.expectEqual(b, tl.groups()[0].last);
    try std.testing.expect(tl.groupOf(c) == null);
    try std.testing.expect(tl.groupOf(d) == null);
    try std.testing.expect(tl.undo());
    try std.testing.expectEqual(c, tl.groups()[0].last);
    try std.testing.expect(tl.redo());
    try std.testing.expectEqual(b, tl.groups()[0].last);
    try std.testing.expect(tl.undo());

    // A non-member dragged inside joins; undo takes it back out.
    try tl.move(d, 1); // [a d b c]
    try std.testing.expectEqual(@as(?ft.annotations.GroupId, g), tl.groupOf(d));
    try std.testing.expect(tl.undo());
    try std.testing.expect(tl.groupOf(d) == null);

    // The only member of a one-feature folder carries the folder along.
    const h = try tl.addGroup("h", d, d);
    try tl.move(d, 0); // d [a b c]
    try std.testing.expectEqual(@as(?ft.annotations.GroupId, h), tl.groupOf(d));
    try std.testing.expectEqual(d, tl.groups()[1].first);
    try std.testing.expectEqual(@as(?ft.annotations.GroupId, g), tl.groupOf(a));
}

test "moveGroup moves multi-member blocks intact in both directions and keeps the folder" {
    const gpa = std.testing.allocator;
    var tl = try makeTimeline(gpa);
    defer tl.deinit();

    var f: [6]ft.FeatureId = undefined;
    for (&f, 0..) |*slot, i| slot.* = try tl.commit(.{ .add = @intCast(i + 1) });
    const g = try tl.addGroup("g", f[1], f[2]);

    // Right: [0 1 2 3 4 5] -> [0 3 4 5 1 2].
    try tl.moveGroup(g, 4);
    const want_right = [_]ft.FeatureId{ f[0], f[3], f[4], f[5], f[1], f[2] };
    for (want_right, 0..) |id, i| try std.testing.expectEqual(id, idAtIdx(&tl, @intCast(i)));
    try std.testing.expectEqual(f[1], tl.groups()[0].first);
    try std.testing.expectEqual(f[2], tl.groups()[0].last);
    try std.testing.expectEqual(@as(?ft.annotations.GroupId, g), tl.groupOf(f[1]));
    try std.testing.expect(tl.groupOf(f[5]) == null);
    try std.testing.expectEqual(@as(i64, 21), tl.state().value);

    try std.testing.expect(tl.undo());
    for (f, 0..) |id, i| try std.testing.expectEqual(id, idAtIdx(&tl, @intCast(i)));
    try std.testing.expectEqual(f[1], tl.groups()[0].first);

    // Left: [0 1 2 3 4 5] -> [1 2 0 3 4 5].
    try tl.moveGroup(g, 0);
    const want_left = [_]ft.FeatureId{ f[1], f[2], f[0], f[3], f[4], f[5] };
    for (want_left, 0..) |id, i| try std.testing.expectEqual(id, idAtIdx(&tl, @intCast(i)));
    try std.testing.expectEqual(@as(?ft.annotations.GroupId, g), tl.groupOf(f[2]));
    try std.testing.expect(tl.groupOf(f[0]) == null);
    try std.testing.expect(tl.undo());
    for (f, 0..) |id, i| try std.testing.expectEqual(id, idAtIdx(&tl, @intCast(i)));
    try std.testing.expect(tl.redo());
    for (want_left, 0..) |id, i| try std.testing.expectEqual(id, idAtIdx(&tl, @intCast(i)));
}

test "sync: wire codec round-trips a move entry with group fixes" {
    const gpa = std.testing.allocator;
    var tl = try SyncTl.init(gpa, .{}, .{});
    defer tl.deinit();
    const a = try tl.commit(.{ .add = 1 });
    const b = try tl.commit(.{ .add = 2 });
    const c = try tl.commit(.{ .add = 3 });
    const g = try tl.addGroup("g", a, c);

    var out = Outbox{ .gpa = gpa };
    defer out.deinit();
    tl.setRecordObserver(.{ .ctx = &out, .func = Outbox.observe });
    try tl.move(a, 2); // a leaves the folder: g re-anchors to b..c
    try std.testing.expectEqual(@as(usize, 1), out.blobs.items.len);

    var reader = std.Io.Reader.fixed(out.blobs.items[0]);
    var env = try syncing.decode(ParamDomain, gpa, &reader);
    defer syncing.deinit(ParamDomain.Op, gpa, &env);
    try std.testing.expectEqual(a, env.entry.move.id);
    try std.testing.expectEqual(@as(usize, 1), env.entry.move.group_fixes.len);
    try std.testing.expectEqual(g, env.entry.move.group_fixes[0].group_id);
    try std.testing.expectEqual(a, env.entry.move.group_fixes[0].old_first);
    try std.testing.expectEqual(b, env.entry.move.group_fixes[0].new_first);
    try std.testing.expectEqual(c, env.entry.move.group_fixes[0].new_last);
}

test "sync: entries from another wire version are rejected" {
    const gpa = std.testing.allocator;
    const bytes = [_]u8{ syncing.wire_version + 1, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    var reader = std.Io.Reader.fixed(&bytes);
    try std.testing.expectError(error.UnsupportedWireVersion, syncing.decode(ParamDomain, gpa, &reader));
}

var history_clock: u64 = 100;
fn historyNow() u64 {
    history_clock += 1;
    return history_clock;
}

test "history: units report kind, size, label, timestamp, and undone state" {
    const gpa = std.testing.allocator;
    var tl = try TestTimeline.init(gpa, .{}, .{ .now = historyNow });
    defer tl.deinit();

    const a = try tl.commit(.{ .add = 1 });
    try tl.beginLabeledTransaction("tune");
    try tl.edit(a, .{ .add = 5 });
    try tl.setFeatureName(a, "base");
    tl.endTransaction();
    try tl.setSuppressed(a, true);
    try std.testing.expectEqual(@as(u32, 3), tl.undoDepth());
    try std.testing.expectEqual(@as(u32, 0), tl.redoDepth());

    var it = tl.history();
    const unit_a = it.next().?;
    try std.testing.expectEqual(TestTimeline.HistoryKind.commit, unit_a.kind);
    try std.testing.expectEqual(@as(u32, 1), unit_a.entries);
    try std.testing.expect(unit_a.label == null);
    try std.testing.expect(unit_a.ts > 100);
    try std.testing.expect(!unit_a.undone);
    const unit_b = it.next().?;
    try std.testing.expectEqual(TestTimeline.HistoryKind.batch, unit_b.kind);
    try std.testing.expectEqual(@as(u32, 2), unit_b.entries);
    try std.testing.expectEqualStrings("tune", unit_b.label.?);
    try std.testing.expect(unit_b.ts > unit_a.ts);
    const unit_c = it.next().?;
    try std.testing.expectEqual(TestTimeline.HistoryKind.suppress, unit_c.kind);
    try std.testing.expect(it.next() == null);

    // Undo marks units as undone without dropping them.
    try std.testing.expect(tl.undo());
    try std.testing.expect(tl.undo());
    try std.testing.expectEqual(@as(u32, 1), tl.undoDepth());
    try std.testing.expectEqual(@as(u32, 2), tl.redoDepth());
    var it2 = tl.history();
    try std.testing.expect(!it2.next().?.undone);
    try std.testing.expect(it2.next().?.undone);
    try std.testing.expect(it2.next().?.undone);

    // An empty labeled transaction leaves no trace and leaks nothing.
    try tl.beginLabeledTransaction("nothing");
    tl.endTransaction();
    try std.testing.expectEqual(@as(u32, 1), tl.undoDepth());
}

test "trim: keeps checkpoints nearest the marker and the newest undo units" {
    const gpa = std.testing.allocator;
    var tl = try TestTimeline.init(gpa, .{}, .{ .checkpoint_interval = 0, .max_checkpoints = 8, .checkpoint_on_scrub = true });
    defer tl.deinit();

    var i: u32 = 0;
    while (i < 6) : (i += 1) _ = try tl.commit(.{ .add = 1 });
    // Scrub snapshots at 6, 5, 4 and 3; scrubbing back to 6 consumes the
    // exact snapshot at 6, leaving {5, 4, 3} in the cache.
    _ = tl.state();
    tl.setMarker(5);
    _ = tl.state();
    tl.setMarker(4);
    _ = tl.state();
    tl.setMarker(3);
    _ = tl.state();
    tl.setMarker(6);
    _ = tl.state();
    try std.testing.expectEqual(@as(u32, 3), tl.stats().checkpoints);
    try std.testing.expectEqual(@as(u32, 6), tl.stats().undo_units);

    const t = tl.trim(.{ .checkpoints = 2, .undo_units = 2 });
    try std.testing.expectEqual(@as(u32, 1), t.checkpoints);
    try std.testing.expectEqual(@as(u32, 4), t.journal_entries);
    const s = tl.stats();
    try std.testing.expectEqual(@as(u32, 2), s.checkpoints);
    try std.testing.expectEqual(@as(u32, 2), s.undo_units);
    // The marker is at 6: the nearest snapshots (5 and 4) survive, 3 goes.
    try std.testing.expectEqual(@as(u32, 5), tl.cps.bestBefore(6).?.pos);
    try std.testing.expectEqual(@as(u32, 4), tl.cps.bestBefore(4).?.pos);
    try std.testing.expect(tl.cps.bestBefore(3) == null);
    try std.testing.expectEqual(@as(i64, 6), tl.state().value); // document untouched

    // Undo still works for the kept units; redo can be dropped.
    try std.testing.expect(tl.undo());
    try std.testing.expectEqual(@as(u32, 1), tl.redoDepth());
    const t2 = tl.trim(.{ .drop_redo = true });
    try std.testing.expectEqual(@as(u32, 1), t2.journal_entries);
    try std.testing.expect(!tl.canRedo());
    try std.testing.expectEqual(@as(u32, 1), tl.undoDepth());
}

test "cherryPick copies a feature with its annotations as one undo unit" {
    const gpa = std.testing.allocator;
    var src = try makeTimeline(gpa);
    defer src.deinit();
    var dst = try makeTimeline(gpa);
    defer dst.deinit();

    const a = try src.commit(.{ .add = 7 });
    try src.setFeatureName(a, "seven");
    try src.addTag(a, "picked");
    try src.setSuppressed(a, true);
    const b = try src.commit(.{ .mul = 3 });
    _ = try dst.commit(.{ .add = 1 });

    const picked = try dst.cherryPick(&src, a, .{});
    try std.testing.expect(dst.featureById(picked) != null);
    try std.testing.expectEqualStrings("seven", dst.featureName(picked).?);
    try std.testing.expectEqual(@as(usize, 1), dst.tags(picked).len);
    try std.testing.expect(dst.featureById(picked).?.suppressed);
    try std.testing.expectEqual(@as(i64, 1), dst.state().value); // suppressed: no effect

    const picked2 = try dst.cherryPick(&src, b, .{ .annotations = false, .keep_suppressed = false });
    try std.testing.expect(dst.featureName(picked2) == null);
    try std.testing.expectEqual(@as(i64, 3), dst.state().value);

    // Each pick is one undo unit, annotations included.
    try std.testing.expect(dst.undo());
    try std.testing.expectEqual(@as(i64, 1), dst.state().value);
    try std.testing.expect(dst.undo());
    try std.testing.expectEqual(@as(u32, 1), dst.len());
    try std.testing.expect(dst.featureName(picked) == null);
    try std.testing.expect(dst.redo());
    try std.testing.expectEqualStrings("seven", dst.featureName(picked).?);

    // Unknown source id; and picking from the same timeline duplicates.
    try std.testing.expectError(error.UnknownFeature, dst.cherryPick(&src, 0xBAD, .{}));
    const dup = try src.cherryPick(&src, b, .{});
    try std.testing.expectEqual(@as(u32, 3), src.len());
    try std.testing.expect(std.meta.eql(src.featureById(dup).?.op.*, TestDomain.Op{ .mul = 3 }));
    // Source untouched by the copy.
    try std.testing.expectEqualStrings("seven", src.featureName(a).?);
}

/// Counts allocations and live bytes going through it; delegates to `inner`.
const CountingAllocator = struct {
    inner: std.mem.Allocator,
    allocs: usize = 0,
    live: usize = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
    const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const out = self.inner.rawAlloc(len, alignment, ret_addr);
        if (out != null) {
            self.allocs += 1;
            self.live += len;
        }
        return out;
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ok = self.inner.rawResize(memory, alignment, new_len, ret_addr);
        if (ok) self.live = self.live - memory.len + new_len;
        return ok;
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const out = self.inner.rawRemap(memory, alignment, new_len, ret_addr);
        if (out != null) self.live = self.live - memory.len + new_len;
        return out;
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.live -= memory.len;
        self.inner.rawFree(memory, alignment, ret_addr);
    }
};

/// Allocates temporaries from `ctx.scratch` without freeing them, and keeps
/// document memory on `ctx.alloc`.
const ScratchDomain = struct {
    pub const Doc = struct { items: std.ArrayList(u32) = .empty };
    pub const Op = union(enum) { push: u32, fail: void };

    pub fn apply(op: Op, doc: *Doc, ctx: *ft.ApplyContext) anyerror!void {
        switch (op) {
            .push => |v| {
                // A temporary that is never freed: the arena owns it.
                const tmp = try ctx.scratch.alloc(u32, 1024);
                tmp[0] = v;
                try doc.items.append(ctx.alloc, tmp[0]);
            },
            .fail => return ctx.fail("nope", .{}),
        }
    }
    pub fn cloneDoc(doc: *const Doc, gpa: std.mem.Allocator) anyerror!Doc {
        return .{ .items = try doc.items.clone(gpa) };
    }
    pub fn deinitDoc(doc: *Doc, gpa: std.mem.Allocator) void {
        doc.items.deinit(gpa);
    }
};

test "allocators: scratch temporaries need no free; document memory goes to doc_allocator" {
    const gpa = std.testing.allocator;
    var doc_mem = CountingAllocator{ .inner = gpa };
    var seed: ScratchDomain.Doc = .{};
    try seed.items.append(doc_mem.allocator(), 7); // the seed lives on the doc allocator too

    var tl = try Timeline(ScratchDomain).init(gpa, seed, .{ .doc_allocator = doc_mem.allocator(), .checkpoint_on_scrub = true });
    defer tl.deinit();

    _ = try tl.commit(.{ .push = 1 });
    _ = try tl.commit(.{ .push = 2 });
    _ = try tl.commit(.{ .fail = {} });
    _ = try tl.commit(.{ .push = 3 });
    try std.testing.expectEqual(@as(usize, 4), tl.state().items.items.len);
    try std.testing.expect(doc_mem.allocs > 0);

    // Scrub, checkpoint, background job: every path uses the doc allocator
    // for copies and a scratch arena for temporaries. testing.allocator
    // reports leaks, so unfreed scratch would fail this test.
    tl.setMarker(1);
    _ = tl.state();
    tl.setMarker(4);
    _ = tl.state();
    var it = tl.features();
    const first = it.next().?.id;
    try tl.edit(first, .{ .push = 10 });
    var job = try tl.beginRebuild();
    defer job.deinit();
    job.run();
    try std.testing.expect(tl.integrate(&job));
    try std.testing.expectEqual(@as(u32, 10), tl.state().items.items[1]);

    try std.testing.expect(doc_mem.live > 0);
}

test "allocators: failure messages never touch the document allocator" {
    const gpa = std.testing.allocator;
    var doc_mem = CountingAllocator{ .inner = gpa };
    var tl = try Timeline(ScratchDomain).init(gpa, .{}, .{ .doc_allocator = doc_mem.allocator() });
    defer tl.deinit();

    // An empty document clones without allocating; the only allocation a
    // failing feature causes is its message, which belongs to the gpa.
    _ = try tl.commit(.{ .fail = {} });
    _ = try tl.commit(.{ .fail = {} });
    _ = tl.state();
    var it = tl.features();
    try std.testing.expectEqualStrings("nope", it.next().?.status.failed);
    try std.testing.expectEqual(@as(usize, 0), doc_mem.allocs);
}

test "allocators: without doc_allocator everything stays on the gpa" {
    const gpa = std.testing.allocator;
    var tl = try Timeline(ScratchDomain).init(gpa, .{}, .{});
    defer tl.deinit();
    try std.testing.expectEqual(gpa.ptr, tl.docAllocator().ptr);
    _ = try tl.commit(.{ .push = 1 });
    try std.testing.expectEqual(@as(usize, 1), tl.state().items.items.len);
}

fn idAtSync(tl: *SyncTl, idx: u32) ft.FeatureId {
    var it = tl.features();
    var i: u32 = 0;
    while (it.next()) |f| : (i += 1) {
        if (i == idx) return f.id;
    }
    unreachable;
}

fn checkIndex(tl: *SyncTl) !void {
    try std.testing.expectEqual(tl.len(), tl.index.count());
    var it = tl.features();
    var i: u32 = 0;
    while (it.next()) |f| : (i += 1) {
        try std.testing.expectEqual(i, tl.indexOf(f.id).?);
    }
}

test "index: id lookups stay exact across inserts, removes, moves, undo/redo and load" {
    const gpa = std.testing.allocator;
    var tl = try SyncTl.init(gpa, .{}, .{});
    defer tl.deinit();
    var i: u32 = 0;
    while (i < 30) : (i += 1) _ = try tl.commit(.{ .add = @intCast(i) });
    try checkIndex(&tl);

    tl.setMarker(10);
    _ = try tl.commit(.{ .add = 100 }); // mid-history insert shifts the suffix
    try checkIndex(&tl);
    try tl.remove(idAtSync(&tl, 5));
    try checkIndex(&tl);
    try tl.move(idAtSync(&tl, 20), 2);
    try checkIndex(&tl);
    try tl.move(idAtSync(&tl, 3), 25);
    try checkIndex(&tl);
    const g = try tl.addGroup("g", idAtSync(&tl, 8), idAtSync(&tl, 12));
    try tl.moveGroup(g, 0);
    try checkIndex(&tl);
    try tl.removeGroupContents(g);
    try checkIndex(&tl);
    _ = tl.applyRemote(&remoteCommit(7777, .{ .add = 1 }, 3, idAtSync(&tl, 2)));
    try checkIndex(&tl);
    try std.testing.expectEqual(@as(u32, 3), tl.indexOf(7777).?);

    var k: u32 = 0;
    while (k < 7) : (k += 1) {
        try std.testing.expect(tl.undo());
        try checkIndex(&tl);
    }
    while (k > 0) : (k -= 1) {
        try std.testing.expect(tl.redo());
        try checkIndex(&tl);
    }

    // Loading rebuilds the index from the file.
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try save_persistence_shim(&tl, gpa, &aw.writer);
    var reader = std.Io.Reader.fixed(aw.written());
    var loaded = try load_persistence_shim(gpa, &reader);
    defer loaded.deinit();
    try checkIndex(&loaded);
    try std.testing.expectEqual(tl.len(), loaded.len());
}

fn shiftValue(delta: *const i64, doc: *TestDomain.Doc) anyerror!void {
    doc.value += delta.*;
}

test "forEachDoc visits the seed, the live document, and every checkpoint" {
    const gpa = std.testing.allocator;
    var tl = try TestTimeline.init(gpa, .{}, .{ .checkpoint_on_scrub = true });
    defer tl.deinit();
    _ = try tl.commit(.{ .add = 1 });
    _ = try tl.commit(.{ .add = 2 });
    _ = tl.state();
    tl.setMarker(1); // snapshots position 2
    _ = tl.state();
    try std.testing.expectEqual(@as(u32, 1), tl.stats().checkpoints);

    const delta: i64 = 1000;
    try tl.forEachDoc(&delta, shiftValue);
    // Live (position 1), the checkpoint (position 2) and the seed all moved.
    try std.testing.expectEqual(@as(i64, 1001), tl.state().value);
    tl.setMarker(2);
    try std.testing.expectEqual(@as(i64, 1003), tl.state().value); // restored from the shifted snapshot
    try tl.edit(idAtIdx(&tl, 0), .{ .add = 5 }); // full replay from the shifted seed
    try std.testing.expectEqual(@as(i64, 1007), tl.state().value);
}

fn digestsAgree(replicas: []const *SyncTl) bool {
    const first = replicas[0].structureDigest();
    for (replicas[1..]) |r| {
        if (r.structureDigest() != first) return false;
    }
    return true;
}

test "sync: concurrent commits after the same predecessor converge in the same order, either delivery order" {
    const gpa = std.testing.allocator;
    var round: u8 = 0;
    while (round < 2) : (round += 1) {
        var alice = try SyncTl.init(gpa, .{}, .{});
        defer alice.deinit();
        var bob = try SyncTl.init(gpa, .{}, .{});
        defer bob.deinit();
        var out_a = Outbox{ .gpa = gpa };
        defer out_a.deinit();
        var out_b = Outbox{ .gpa = gpa };
        defer out_b.deinit();
        alice.setRecordObserver(.{ .ctx = &out_a, .func = Outbox.observe });
        bob.setRecordObserver(.{ .ctx = &out_b, .func = Outbox.observe });

        // Shared predecessor X.
        _ = try alice.commit(.{ .add = 1 });
        try out_a.feed(&bob);

        // Both commit after X without syncing (different ops, so the order
        // is observable through `mul`).
        _ = try alice.commit(.{ .add = 10 });
        _ = try bob.commit(.{ .add = 20 });

        if (round == 0) {
            try out_a.feed(&bob);
            try out_b.feed(&alice);
        } else {
            try out_b.feed(&alice);
            try out_a.feed(&bob);
        }
        try std.testing.expectEqual(@as(u32, 3), alice.len());
        try std.testing.expect(digestsAgree(&.{ &alice, &bob }));
        try expectConverged(&alice, &bob);
    }
}

test "sync: three replicas, three concurrent commits, every delivery order converges" {
    const gpa = std.testing.allocator;
    const perms = [_][3][2]u8{
        .{ .{ 1, 2 }, .{ 2, 0 }, .{ 0, 1 } },
        .{ .{ 2, 1 }, .{ 0, 2 }, .{ 1, 0 } },
        .{ .{ 1, 2 }, .{ 0, 2 }, .{ 0, 1 } },
    };
    for (perms) |perm| {
        var replicas: [3]SyncTl = undefined;
        var outboxes: [3]Outbox = undefined;
        for (&replicas, 0..) |*r, i| {
            r.* = try SyncTl.init(gpa, .{}, .{});
            outboxes[i] = .{ .gpa = gpa };
            r.setRecordObserver(.{ .ctx = &outboxes[i], .func = Outbox.observe });
        }
        defer for (&replicas, 0..) |*r, i| {
            r.deinit();
            outboxes[i].deinit();
        };

        // Replica 0 seeds a shared predecessor; everyone receives it.
        _ = try replicas[0].commit(.{ .add = 1 });
        var it = outboxes[0].blobs.items;
        for (&replicas, 0..) |*r, i| {
            if (i == 0) continue;
            for (it) |blob| {
                var reader = std.Io.Reader.fixed(blob);
                var env = try syncing.decode(ParamDomain, gpa, &reader);
                _ = r.applyRemote(&env);
                syncing.deinit(ParamDomain.Op, gpa, &env);
            }
        }
        for (outboxes[0].blobs.items) |b| gpa.free(b);
        outboxes[0].blobs.clearRetainingCapacity();
        it = &.{};

        // Three concurrent commits after it.
        _ = try replicas[0].commit(.{ .add = 10 });
        _ = try replicas[1].commit(.{ .add = 20 });
        _ = try replicas[2].commit(.{ .add = 100 });

        // Deliver the two foreign envelopes to each replica in its own order.
        for (perm, 0..) |order, i| {
            for (order) |from| {
                for (outboxes[from].blobs.items) |blob| {
                    var reader = std.Io.Reader.fixed(blob);
                    var env = try syncing.decode(ParamDomain, gpa, &reader);
                    _ = replicas[i].applyRemote(&env);
                    syncing.deinit(ParamDomain.Op, gpa, &env);
                }
            }
        }
        try std.testing.expect(digestsAgree(&.{ &replicas[0], &replicas[1], &replicas[2] }));
        try expectConverged(&replicas[0], &replicas[1]);
        try expectConverged(&replicas[1], &replicas[2]);
    }
}

test "sync: sequence numbers detect duplicates, gaps, and own echoes" {
    const gpa = std.testing.allocator;
    var alice = try SyncTl.init(gpa, .{}, .{});
    defer alice.deinit();
    var bob = try SyncTl.init(gpa, .{}, .{});
    defer bob.deinit();
    var out_a = Outbox{ .gpa = gpa };
    defer out_a.deinit();
    alice.setRecordObserver(.{ .ctx = &out_a, .func = Outbox.observe });

    _ = try alice.commit(.{ .add = 1 });
    _ = try alice.commit(.{ .add = 2 });
    _ = try alice.commit(.{ .add = 3 });
    try std.testing.expectEqual(@as(usize, 3), out_a.blobs.items.len);

    var envs: [3]SyncTl.Envelope = undefined;
    for (out_a.blobs.items, 0..) |blob, i| {
        var reader = std.Io.Reader.fixed(blob);
        envs[i] = try syncing.decode(ParamDomain, gpa, &reader);
    }
    defer for (&envs) |*e| syncing.deinit(ParamDomain.Op, gpa, e);
    try std.testing.expectEqual(alice.replicaId(), envs[0].origin);
    try std.testing.expectEqual(@as(u64, 1), envs[0].seq);
    try std.testing.expectEqual(@as(u64, 3), envs[2].seq);

    try std.testing.expectEqual(@as(u64, 1), bob.expectedSeq(alice.replicaId()));
    try std.testing.expectEqual(SyncTl.ApplyResult.applied, bob.applyRemote(&envs[0]));
    try std.testing.expectEqual(SyncTl.ApplyResult.duplicate, bob.applyRemote(&envs[0]));
    try std.testing.expectEqual(SyncTl.ApplyResult.gap, bob.applyRemote(&envs[2])); // 3 before 2
    try std.testing.expectEqual(@as(u64, 2), bob.expectedSeq(alice.replicaId()));
    try std.testing.expectEqual(@as(u32, 1), bob.len()); // the gap was not applied
    try std.testing.expectEqual(SyncTl.ApplyResult.applied, bob.applyRemote(&envs[1]));
    try std.testing.expectEqual(SyncTl.ApplyResult.applied, bob.applyRemote(&envs[2]));
    try std.testing.expectEqual(@as(u32, 3), bob.len());
    try std.testing.expectEqual(@as(i64, 6), bob.state().value);

    // Echoes of one's own envelopes are ignored.
    try std.testing.expectEqual(SyncTl.ApplyResult.own, alice.applyRemote(&envs[0]));
    try std.testing.expectEqual(@as(u32, 3), alice.len());

    // After a resync by other means, acknowledge what is already reflected.
    try bob.acknowledge(alice.replicaId(), 10);
    try std.testing.expectEqual(@as(u64, 11), bob.expectedSeq(alice.replicaId()));
}

test "sync: envelope round-trips origin, sequence, clock, predecessor and order key" {
    const gpa = std.testing.allocator;
    const env: SyncTl.Envelope = .{
        .origin = 77,
        .seq = 9,
        .lamport = 123,
        .entry = .{ .commit = .{ .id = 5, .op = .{ .add = 2 }, .at = 1, .meta = .{ .author = 3, .ts = 4 }, .after = 4, .order = .{ .lamport = 123, .origin = 77 } } },
    };
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try syncing.encode(ParamDomain, &env, gpa, &aw.writer);
    var reader = std.Io.Reader.fixed(aw.written());
    var got = try syncing.decode(ParamDomain, gpa, &reader);
    defer syncing.deinit(ParamDomain.Op, gpa, &got);
    try std.testing.expectEqual(@as(u64, 77), got.origin);
    try std.testing.expectEqual(@as(u64, 9), got.seq);
    try std.testing.expectEqual(@as(u64, 123), got.lamport);
    try std.testing.expectEqual(@as(?ft.FeatureId, 4), got.entry.commit.after);
    try std.testing.expectEqual(@as(u64, 123), got.entry.commit.order.lamport);
    try std.testing.expectEqual(@as(u64, 77), got.entry.commit.order.origin);
    try std.testing.expectEqual(ft.Meta{ .author = 3, .ts = 4 }, got.entry.commit.meta.?);
}
