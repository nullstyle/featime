# featuretree-zig

Design feature history for Zig applications: an Autodesk Fusion-style
feature timeline — an ordered list of parametric operations that transform an
application-defined document, with the machinery Fusion users know: the
history slider, mid-history editing, cached incremental rebuilds, per-feature
error badges, undo/redo, dependency-aware reordering, persistence, and
background rebuilds.

Applications bring their own document and feature types; the library is a
single comptime generic, `Timeline(Domain)`, fully type-checked at compile
time.

```sh
zig build test   # unit, differential, out-of-memory and fuzz tests
zig build run    # terrain-editor demo exercising every capability
zig build docs   # API reference into zig-out/docs
```

CI runs the same on Linux, macOS and Windows (`.github/workflows/ci.yml`):
fmt check, tests in Debug / ReleaseSafe / ReleaseFast, the examples, the
demo, the benchmark and the docs.

Requires Zig `0.17.0` (pinned via `mise`).

## Fusion capability → library facility

| Fusion capability | Library facility |
|---|---|
| Drag the timeline marker (rollback / playback) | `setMarker(pos)`; `state()` rebuilds lazily and incrementally |
| Insert a feature while rolled back | `commit(op)` — always inserts at the marker, then advances past it |
| Edit feature parameters → recompute downstream | `edit(id, new_op)`; replays only the dirty suffix from the nearest surviving checkpoint |
| Suppress / unsuppress | `setSuppressed(id, bool)` |
| Delete a feature | `remove(id)` |
| Reorder (drag) | `move(id, new_pos)`; validated against dependencies before mutating |
| Error badges; timeline continues past failures | per-feature `Status` (`ok` / `suppressed` / `failed` + message); rebuilds continue after soft failures |
| Compute caching / fast scrubbing | checkpoint cache; snapshot-on-scrub makes back-and-forth scrubbing free |
| Undo/redo, independent of the marker | built-in undo/redo journal |
| Save / open a document | `persistence.save` / `load` |
| Recompute off the UI thread | `beginRebuild()` / `job.run()` / `integrate()` |
| Assemblies with component timelines | one `Timeline` per subresource + `setEnv` / `refresh` (see below) |
| History panel ("Undo Smooth terrain") | `history()` units with kind, label, timestamp; `beginLabeledTransaction` |
| Save a copy / branch a design | `persistence.savePrefix` + `cherryPick` |
| Open a file from an older version | `Domain.format_version` + `migrateOp` / `migrateDoc` |

## Quick start

Write a Domain: name your document type, your feature types (one tagged
union), and how features apply.

```zig
const featuretree = @import("featuretree_zig");

const MyApp = struct {
    pub const Doc = struct { heights: []f32, entities: std.ArrayList(Entity) };
    pub const Op = union(enum) {
        raise: struct { cell: u32, amount: f32 },
        place: struct { cell: u32, entity: Entity },
        smooth: struct { passes: u8 },
    };

    // Required: apply one feature. Validate first, mutate second.
    pub fn apply(op: Op, doc: *Doc, ctx: *featuretree.ApplyContext) anyerror!void {
        switch (op) {
            .raise => |r| {
                if (r.cell >= doc.heights.len)
                    return ctx.fail("cell {d} is off the grid", .{r.cell});
                doc.heights[r.cell] += r.amount;
            },
            .place => ..., .smooth => ...,
        }
    }

    // Only because this Doc owns heap memory (`entities`): deep-copy /
    // destroy documents (seed + checkpoints). A plain-data Doc — no pointers
    // or slices anywhere inside — needs neither; it is copied bitwise.
    pub fn cloneDoc(doc: *const Doc, gpa: std.mem.Allocator) anyerror!Doc { ... }
    pub fn deinitDoc(doc: *Doc, gpa: std.mem.Allocator) void { ... }

    // Optional: enables reorder validation.
    pub fn dependencies(op: Op, out: *featuretree.DepCollector) void { ... }

    // Optional: enables persistence.
    pub fn encodeOp(op: Op, w: *std.Io.Writer) anyerror!void { ... }
    pub fn decodeOp(r: *std.Io.Reader, gpa: std.mem.Allocator) anyerror!Op { ... }
    pub fn encodeDoc(doc: *const Doc, w: *std.Io.Writer) anyerror!void { ... }
    pub fn decodeDoc(r: *std.Io.Reader, gpa: std.mem.Allocator) anyerror!Doc { ... }
};
```

Then drive the timeline:

```zig
var tl = try featuretree.Timeline(MyApp).init(gpa, seed_doc, .{});
defer tl.deinit();

const hill = try tl.commit(.{ .raise = .{ .cell = 42, .amount = 9 } });
tl.setMarker(0);                    // roll all the way back
_ = try tl.commit(.{ .smooth = .{ .passes = 2 } }); // inserts at 0!
tl.setMarker(tl.len());             // roll to the end (incremental replay)

try tl.edit(hill, .{ .raise = .{ .cell = 42, .amount = 3 } }); // parametric edit
try tl.setSuppressed(hill, true);
_ = tl.undo(); _ = tl.redo();

const doc = tl.state();             // document at the marker
var it = tl.features();             // iterator of FeatureView, oldest first
while (it.next()) |f| {
    if (f.status == .failed) warn(f.id, f.status.failed); // error badges
}
```

## Examples

`examples/` holds small, commented programs that each teach one part of the
interface — every one is a complete application with its own Domain:

```sh
zig build basic_slider          # commit, scrub the slider, mid-history insert
zig build edit_undo             # parametric edit, suppress, remove, undo/redo
zig build caching               # apply-counted tour of the checkpoint cache
zig build persistence_roundtrip # save/load with app-written codecs
zig build background_rebuild    # worker-thread jobs, cancellation, staleness
zig build annotations           # names, tags, chapters, groups, provenance
zig build sync                  # two replicas converging on journal entries
zig build history               # labeled transactions, history(), stats(), trim()
zig build forks                 # savePrefix variants, cherryPick, format migration
zig build examples              # all of the above
```

`zig build run` remains the full terrain-editor demo (including the
hierarchical globe/region walkthrough from the previous section).

`integrations/hamt/` is a standalone project showing a persistent map
([hamt-zig](https://github.com/nullstyle/hamt-zig)) as the document: free
checkpoints, an explicit arena roll through `forEachDoc`, and measured
numbers. It expects hamt-zig checked out next to this repository.

## Annotations: names, tags, chapters, groups, provenance

User-authored metadata that never affects document computation (no
`dirty()`, no rebuild-generation impact) but participates fully in undo and
persistence, anchored to feature ids so it survives structural edits:

- **Names** — `setFeatureName(id, "ridge spine")`, surfaced on `FeatureView`.
- **Tags** — set-semantics labels with `featuresTagged("quest-27")` filters.
- **Chapters** — slider bookmarks: `Mark{ .after = X }` is the gap after
  feature X (null pins to the tip); `markPosition` resolves a jump target.
  Removing the anchor re-anchors to the successor, exactly reversed by undo.
- **Groups** — contiguous `{first, last}` spans with computed membership:
  inserts inside join, member moves out leave (Fusion folders). Dragging a
  boundary member out re-anchors the folder to its remaining members (undo
  restores it exactly); a folder's only member carries the folder along;
  `moveGroup` relocates the whole folder intact. Batch operations are
  single undo steps: `setGroupSuppressed`, `moveGroup`
  (dependency-validated), `removeGroupContents`.
- **Provenance** — `commitWithMeta(op, .{ .author, .ts })`; plain `commit`
  auto-stamps when `Config.now` supplies a clock.

Annotation changes are reported by `annotationsVersion()`, separate from the
rebuild generation so background jobs stay valid. `timelineId()` exposes the
persistent random identity written into the FTZ2 container (FTZ1 files load
with no annotations) — groundwork for `(timeline_id, feature_id)` global
references in the future sync layer.

## Parameters

Fusion's parameter table, minus the expression language: named numeric
values owned by the timeline, read by features, so one parameter edit
re-drives everything referencing it.

```zig
const scale = try tl.addParam("scale", 2.0);
_ = try tl.commit(.{ .scale_by_param = scale }); // op payload is a plain id

// Domain side:
//   .scale_by_param => |pid| {
//       const v = ctx.param(pid) orelse return ctx.fail("missing parameter", .{});
//       doc.value = @intFromFloat(@round(@as(f64, @floatFromInt(doc.value)) * v));
//   },
//   pub fn references(op: Op, out: *ParamRefCollector) void {
//       switch (op) { .scale_by_param => |pid| out.param(pid), else => {} }
//   },

try tl.setParam(scale, 3.0); // referencing features recompute lazily
```

Ops reference parameters by `ParamId` (plain u64 — op payloads stay plain
data); `Domain.references` declares what an op reads, and `setParam`/
`removeParam` invalidate from the earliest referencing feature. That
invalidation is suffix replay — a deliberate over-approximation of the
scattered dirty set (replaying unreferenced features in between is correct
by determinism, just extra work); scattered dirty-set tracking is a
documented future optimization. Without the `references` hook the timeline
cannot see the dependency — parameter edits don't dirty anything and the
app must `refresh` affected features itself. Derived values (Fusion's
expressions) are deliberately out of scope: compute them in your Domain.
Background jobs snapshot parameter values at begin time. The container is
now FTZ3 (parameters section); FTZ1 and FTZ2 files load with what they
have.

## Sync

The multiuser stopping point: journal entries as a wire vocabulary. The
library ships the feed, deterministic placement of concurrent commits, and
per-replica sequence bookkeeping; merge semantics beyond that (concurrent
moves and removes, conflict policy) belong to the application.

```zig
// Producer side: every local edit, in record order, as an envelope
// { origin: replica id, seq: 1, 2, 3, ..., lamport, entry }.
tl.setRecordObserver(.{ .ctx = &outbox, .func = Outbox.observe });

// Consumer side: envelopes cross the wire via the Domain codecs...
var env = try ft.sync.decode(MyApp, gpa, &reader);
switch (tl.applyRemote(&env)) {      // journaled locally; observer NOT fired
    .applied, .dropped, .duplicate, .own => {},
    .gap => request(env.origin, tl.expectedSeq(env.origin)),
}
ft.sync.deinit(MyApp.Op, gpa, &env);
```

Every encoded envelope starts with `sync.wire_version` (4) and the app's
`format_version`; `decode` rejects other wire versions with
`error.UnsupportedWireVersion` instead of misparsing them.

**Identity.** Feature/chapter/group/param ids are random-anchored per
timeline (seed the anchor from OS randomness with `Config.id_seed` when
replicas live in different processes). Replicas share a `timelineId`; each
has its own `replicaId` (a loaded file is a new replica). Remote ids never
move the local id counter, so two users committing concurrently get
distinct ids.

**Order.** Every commit carries its predecessor and an order key (the
origin's Lamport clock, origin id as tie-breaker). `applyRemote` places a
remote commit right after its predecessor and then past every following
feature whose key is greater — the same rule on every replica — so
concurrent commits land in the same order everywhere, whatever the
delivery order. An unknown predecessor (removed, or not received yet)
falls back to the positional hint. Concurrent *moves* and *removes* are
not reconciled: compare `structureDigest()` after a sync round and resync
through a file when replicas disagree.

**Sequencing.** `applyRemote` answers `.applied`, `.dropped` (unknown ids,
a no-op, or a commit already present), `.duplicate`, `.gap` (not applied:
fetch from `expectedSeq(origin)` first), `.own` (an echo of this replica's
envelope) or `.out_of_memory` (nothing applied, the sequence still
expected: deliver the same envelope again later). `seq == 0` skips the check; `acknowledge(origin, seq)`
resets expectations after a resync by other means. Containers persist the
per-origin bookkeeping and the order keys.

**Marker and jobs.** A remote insert at or before your marker shifts it by
one so the features you were looking at stay in view (a marker at the tip
follows the tip); a remote insert in the grey future leaves your slider
alone. Remote integrations are journaled like local edits so undo is
uniform, but never re-broadcast: replicas feeding each other cannot loop.
Structural remote entries bump the rebuild generation like local edits, so
a background job that was in flight is rejected at `integrate` instead of
being installed over a changed plan. `sync.lastWriterWins(local_meta,
remote_meta)` remains the provided tie-breaker for application-level
conflicts when provenance timestamps exist.

## Transactions

Every journaled edit is an undo unit by itself; group edits into one unit
with an explicit transaction:

```zig
tl.beginTransaction();
defer tl.endTransaction();

_ = try tl.commit(.{ .raise = .{ .cell = 42, .amount = 9 } });
try tl.edit(hill, .{ .raise = .{ .cell = 42, .amount = 12 } });
try tl.setFeatureName(hill, "steeper");
tl.endTransaction(); // deferred end is fine

_ = tl.undo(); // the whole batch rewinds in one step
```

Nested begins flatten into the outermost unit; an empty transaction records
nothing; an unbalanced `endTransaction` is a no-op. The library's own group
operations (batch suppression, `moveGroup`, `removeGroupContents`) are built
as transactions over simple entries — there are no special compound journal
kinds. Journal eviction below `max_journal` removes whole units only, so
undo boundaries survive memory pressure. If a call inside your own
transaction fails, the calls before it stay applied; one `undo` rewinds
them.

## History

The journal is inspectable, for a history panel:

```zig
try tl.beginLabeledTransaction("Smooth terrain");
_ = try tl.commit(.{ .smooth = .{ .passes = 2 } });
try tl.setFeatureName(hill, "ridge");
tl.endTransaction();

var it = tl.history();                 // units, oldest first
while (it.next()) |u| {
    // u.kind (.commit, .edit, ..., .batch), u.entries, u.label ("Smooth terrain"),
    // u.ts (from Config.now), u.undone (sits in the redo region)
}
tl.undoDepth(); tl.redoDepth();
```

Marker moves are not journaled and never appear. Units are borrowed views:
iterate before the next edit.

## Contracts

- **Ops are plain data.** Op payloads must not own heap memory or hold
  pointers into the document. Reference earlier features or document entities
  by `FeatureId` (available in `ApplyContext.feature_id` when your op
  applies). This is what makes ops replayable in any timeline order and
  serializable.
- **Feature ids are stable.** Assigned at commit, never reused; safe handles
  for UI selection, dependencies, and persistence.
- **Allocators.** Document memory comes from `ctx.alloc`, temporaries from
  `ctx.scratch` (freed for you after each feature), nothing else — see
  Configuration → Allocators.
- **Unknown ids are errors.** Every mutator that takes an id returns
  `error.UnknownFeature` / `UnknownChapter` / `UnknownGroup` / `UnknownParam`
  when the id is not on this timeline, so a stale handle (say, after a
  teammate removed the feature) surfaces instead of silently doing nothing.
  Setting a flag or value to what it already is remains a no-op that
  journals nothing and leaves in-flight background jobs valid.
- **Out of memory leaves the timeline as it was.** Every mutator allocates
  what it needs before it changes anything (the journal reserves its slot
  first), so `error.OutOfMemory` means nothing happened; call again later.
  The multi-step edits (`moveGroup`, `removeGroupContents`, `cherryPick`)
  unwind what they had done, and the unwinding needs no memory. `undo` and
  `redo` never fail and never allocate: names, tags and the other strings
  move between the journal and the live stores instead of being copied,
  so exhausted memory cannot lose them. Two limits: with `max_journal = 0`
  there is no journal to unwind a multi-step edit, so it stays partially
  applied (the error still reports it); and if a record observer is
  attached, the steps already emitted stay on the feed, like an `undo` —
  `structureDigest` shows the divergence. `tests/oom.zig` checks all of
  this with an allocator that fails at every possible point.
- **Soft failure.** `return ctx.fail("edge {d} gone", .{e})` records a failed
  status and the rebuild *continues* — a failed fillet doesn't hide the
  extrudes after it. `apply` must leave the document unmodified on this path.
- **Hard failure.** Any other returned error aborts the rebuild. The timeline
  is flagged `broken`, `state()` keeps serving the last good document, and
  the next rebuild attempt starts fresh from a checkpoint or the seed.
- **Statuses** describe the last completed rebuild and are meaningful for
  features before the marker; features at/after the marker report `.pending`
  (exactly Fusion's greyed-out future features).
- **Threading.** `Timeline` is single-owner and not thread-safe. Rebuild jobs
  are pure values: `beginRebuild()`, run `job.run()` on any thread (cancellable),
  then `integrate()` on the owner thread. Stale results are rejected by a
  generation counter. `state()` stays available and produces identical
  results synchronously.

## Configuration

```zig
.{ .checkpoint_interval = 256,  // extra checkpoints every N applied features
   .max_checkpoints     = 4,    // document copies kept (memory knob)
   .checkpoint_on_scrub = true, // snapshot when the marker leaves a position
   .max_journal         = 1024, // undo depth; 0 disables
   .doc_allocator       = null, // where document memory lives (default: the gpa)
   .id_seed             = null } // OS randomness for the id anchor (multi-replica apps)
```

Globe-sized documents: raise the interval, lower `max_checkpoints`. The
cache is an optimization — a checkpoint-free timeline still works (backward
scrubs replay from the seed).

### Allocators

`apply` sees three allocators on its context:

- `ctx.alloc` — the document allocator: `Config.doc_allocator`, or the gpa
  when none is set. Memory the document keeps comes from here. `cloneDoc`
  and `deinitDoc` receive the same allocator, and so must the seed you pass
  to `init`.
- `ctx.scratch` — an arena the timeline resets after every feature.
  Temporaries need no `free`; never store a scratch pointer in the document.
- `ctx.gpa` — the timeline's general allocator (failure messages,
  bookkeeping).

Point `doc_allocator` at a pool or a budgeted allocator and document memory
becomes accountable on its own: everything the library allocates for
itself (journal, status copies, failure messages) stays on the gpa.

## Memory pressure

`stats()` counts what the timeline keeps alive (features, checkpoints,
journal entries and units, parameters, chapters, groups). `trim()` releases
memory on demand without touching the document, the structure, or in-flight
background jobs:

```zig
_ = tl.trim(.{
    .checkpoints = 1,   // keep the checkpoint nearest the marker
    .undo_units = 20,   // keep the newest 20 undo units
    .drop_redo = true,  // forget what redo could replay
});
```

Dropping checkpoints only makes scrubbing slower; dropping journal units
shrinks undo depth. The configured `max_checkpoints` / `max_journal` are
unchanged — `trim` is a one-off release, called from your memory-pressure
handler.

`forEachDoc(ctx, visit)` visits every document copy the timeline holds —
seed, live, each checkpoint — for in-place transformations that keep the
document's meaning: re-homing arena-backed documents into a fresh arena,
compacting storage, accounting. Not while a background job is in flight.
`integrations/hamt/` uses it to roll a persistent map's arena.

## Persistence

`persistence.save(Domain, &tl, gpa, writer)` / `load(Domain, gpa, config, reader)`:
a small versioned binary container framing app-encoded op and seed payloads
(length-framed, so future readers can skip unknown op kinds). Ids, order,
suppression, and the marker round-trip; statuses, checkpoints, and the undo
journal intentionally do not — they recompute, like a Fusion document
reopening. The header carries the timeline's id, the app format, and the
ids of the timelines its features link to: `persistence.peekHeader(gpa,
reader)` reads just that, so an app can open or fetch linked timelines
before loading the container itself.

### Format versions

Op and document encodings evolve. Declare the app's payload schema version
and the library records it in every container and on the sync wire:

```zig
pub const format_version: u32 = 2;   // 0 when absent

// Called instead of decodeOp / decodeDoc when a file or entry carries a
// different version. Decode the old layout here and return today's types.
pub fn migrateOp(from: u32, r: *std.Io.Reader, gpa: std.mem.Allocator) anyerror!Op { ... }
pub fn migrateDoc(from: u32, r: *std.Io.Reader, gpa: std.mem.Allocator) anyerror!Doc { ... }
```

Without the hooks, a foreign version is `error.UnsupportedFormatVersion`.
Files written before 0.8.0 are version 0. See `examples/forks.zig`.

### Forks and cherry-picks

`persistence.savePrefix(Domain, &tl, gpa, writer, mark, .{ .timeline_id = new_id })`
writes `features[0..mark]` as an independent container: a scenario variant
when it gets its own identity. The marker is clamped; names, tags and
provenance of dropped features go with them; chapters anchored beyond the
mark are dropped (end-pinned ones follow the new tip); groups that start
inside the prefix are kept with their end clamped; parameters are all kept.
`markPosition(chapter.mark)` turns a chapter into a fork point.

`try variant.cherryPick(&tl, feature_id, .{})` copies one feature from
another timeline of the same Domain (or from the same one) and commits it at
the marker with a fresh id, as one undo unit — name, tags, provenance and
the suppressed flag included unless the options say otherwise. Ops are plain
data, so ids inside the op are not translated: a dependent op whose
dependency is absent in the target simply soft-fails on rebuild.

## Hierarchical timelines and links

Fusion's assembly/component model maps directly onto the library: parent
features *reference* sub-timelines rather than embedding them. Each
subresource (a region of the globe) gets its own ordinary `Timeline` over
its own Domain; the parent timeline holds **occurrence features** whose ops
name the subresource by its `timelineId()`.

```zig
var region_tl = try ft.Timeline(Region).init(gpa, region_seed, .{});
var globe_tl = try ft.Timeline(Globe).init(gpa, globe_seed, .{});

// App-owned registry: timeline id -> handle.
const Registry = struct {
    region: *ft.Timeline(Region),
    fn resolve(ctx: ?*anyopaque, id: u64) ?ft.LinkHandle {
        const self: *Registry = @ptrCast(@alignCast(ctx.?));
        return if (id == self.region.timelineId()) self.region.linkHandle() else null;
    }
};
var registry = Registry{ .region = &region_tl };
globe_tl.setRegistry(.{ .ctx = &registry, .resolve = &Registry.resolve });

// Globe Domain:
//   pub fn links(op: Op, out: *ft.LinkCollector) void   -> out.link(o.region) for an occurrence
//   apply: const region: *ft.Timeline(Region) = @ptrCast(@alignCast(
//              ctx.link(o.region) orelse return ctx.fail("region {d} missing", .{o.region})));
//          read region.state(), merge into the doc
const occurrence = try globe_tl.commit(.{ .region_occurrence = .{ .region = region_tl.timelineId() } });
```

The rules of the model:

- **Computed-state merge** (recommended over replaying sub-ops in parent
  context): the parent's `apply` reads the sub-timeline's `state()` through
  `ctx.link(id)` and copies what it needs into the parent document. Sub
  rebuilds stay region-sized; the globe document holds summaries, not raw
  region ops.
- **Invalidation is automatic.** `Domain.links` names the timelines an op
  reads. After a feature runs, the library remembers each linked timeline's
  `version()`; `dirty()` and `state()` compare, and the features that read
  a changed timeline re-run — through any depth of links, so a change in a
  grandchild reaches the parent. `refresh(id)` stays for inputs the library
  cannot see (anything read through `ctx.env`).
- **Cross-timeline skew is intended.** Scrubbing the *region* marker is a
  change the globe follows; rolling the *globe* back past an occurrence
  leaves the region's own history untouched — exactly how Fusion
  assemblies treat component occurrences.
- **Cycles fail softly.** `ctx.link` returns null for a timeline that is
  being evaluated right now, so the read that closes a cycle soft-fails
  instead of recursing. Which read that is depends on evaluation order, and
  a cyclic link graph never settles: treat a cycle as an error. Pinned
  references (planned; `docs/timeline-references.md`) will make backward
  references legal.
- **Background jobs** carry the registry and read linked timelines while
  they run, so do not edit a linked timeline during a parent's job. If one
  changes between `beginRebuild` and `integrate`, the job is rejected like
  any stale job.
- **Cross-level dependencies** are declared with
  `DepCollector.depIn(timeline_feature, id)`; parent-level reorder
  validation anchors them at the feature that introduces the sub-timeline.
- **Ids remain per-timeline.** A reference from a parent is always
  `(timeline id, feature id within it)`. `linkedTimelines(gpa)` lists the
  ids a timeline reads, and a container's header records them
  (`persistence.peekHeader`), so an app can open them first.

For a multiuser editor this shape doubles as the sync/merge unit: each
sub-timeline (with its stable ids and flat journal) is an independent
shard. `src/nested_demo.zig` (part of `zig build run`) walks the whole
pattern: region edits, the globe following them, region-marker scrubbing,
and globe rollback leaving the region untouched.

## Testing

- Unit tests cover each behavior (co-located `test` blocks).
- `tests/oracle.zig` is a differential harness: randomized operation
  sequences (commits, edits, removes, moves, suppression, names, tags,
  chapters, groups including `moveGroup` and `removeGroupContents`,
  parameters, transactions, undo/redo) across randomized configs run against
  a naive replay-everything reference model, asserting identical documents,
  statuses, annotations, parameters, and undo/redo availability after
  *every* step. This is the primary net for cache-invalidation, anchor, and
  journal bugs.
- `tests/oom.zig` is an out-of-memory sweep: every local mutator, every
  remote entry kind, `load` and `save` run once per allocation index with
  that allocation failing (`std.testing.FailingAllocator`). After a failure
  the state must be unchanged, the retried call must match a clean run,
  and undo and redo must work with every allocation failing.
- `tests/fuzz.zig` feeds arbitrary bytes to `persistence.load` and to
  `sync.decode` + `applyRemote`. `zig build test` runs the corpus once;
  `zig build test --fuzz` keeps generating inputs.
- `src/main.zig` is a terrain-editor demo that exercises every capability
  end-to-end (`zig build run`).
- `zig build bench` runs the benchmark suite (always ReleaseFast) at 1k,
  10k and 100k features; `-Dbench-max=N` caps the size. `bench/BASELINE.md`
  records the current numbers and what they mean.

## Layout

```
src/root.zig       public vocabulary: Timeline re-export, Status, ApplyContext,
                   DepCollector, Config, Domain conventions
src/timeline.zig   the Timeline(Domain) engine: marker, edits, invalidation
src/rebuild.zig    pure replay core + background Job
src/checkpoint.zig checkpoint cache (internal)
src/journal.zig    undo/redo journal (internal)
src/annotations.zig names, tags, chapters, groups, provenance store (internal)
src/params.zig     parameter table (internal)
src/sync.zig       journal entries as a wire format: encode / decode
src/persistence.zig save/load container format (FTZ6; FTZ1–5 still load)
src/nested_demo.zig two-level globe/region demo (hierarchical timelines)
src/main.zig       terrain-editor demo
examples/          focused usage examples (zig build examples)
tests/oracle.zig   differential tests vs a naive reference model
tests/oom.zig      out-of-memory sweep (every call, every allocation)
tests/fuzz.zig     fuzz tests for the decoders (zig build test --fuzz)
tests/support.zig  shared fixture for the hardening tests
bench/bench.zig    benchmark suite (zig build bench); BASELINE.md has the numbers
```

## Status & non-goals

v0.9.1 — all four roadmap waves plus the deferred tail delivered (minus disk-backed checkpoints); see [ROADMAP.md](ROADMAP.md) for the deferred tail. Designed for (and shaped by) a multiuser globe-scale GIS/game editor:
feature ids are random-anchored and journal entries are flat and serializable
so a future sync/merge layer can build on them — but multiuser merge, OT, and
CRDT behavior, branching timelines, and partial-order feature DAGs are
explicitly out of scope for this version.

## License

MIT — see [LICENSE](LICENSE).
