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
zig build test   # unit + differential tests
zig build run    # terrain-editor demo exercising every capability
```

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

    // Required: deep-copy / destroy documents (seed + checkpoints).
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

tl.edit(hill, .{ .raise = .{ .cell = 42, .amount = 3 } }); // parametric edit
tl.setSuppressed(hill, true);
_ = tl.undo(); _ = tl.redo();

const doc = tl.state();             // document at the marker
for (tl.features()) |f| {
    if (f.status == .failed) warn(f.id, f.status.failed); // error badges
}
```

## Contracts

- **Ops are plain data.** Op payloads must not own heap memory or hold
  pointers into the document. Reference earlier features or document entities
  by `FeatureId` (available in `ApplyContext.feature_id` when your op
  applies). This is what makes ops replayable in any timeline order and
  serializable.
- **Feature ids are stable.** Assigned at commit, never reused; safe handles
  for UI selection, dependencies, and persistence.
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
   .max_journal         = 1024 } // undo depth; 0 disables
```

Globe-sized documents: raise the interval, lower `max_checkpoints`. The
cache is an optimization — a checkpoint-free timeline still works (backward
scrubs replay from the seed).

## Persistence

`persistence.save(Domain, &tl, gpa, writer)` / `load(Domain, gpa, config, reader)`:
a small versioned binary container framing app-encoded op and seed payloads
(length-framed, so future readers can skip unknown op kinds). Ids, order,
suppression, and the marker round-trip; statuses, checkpoints, and the undo
journal intentionally do not — they recompute, like a Fusion document
reopening.

## Hierarchical timelines

Fusion's assembly/component model maps directly onto the library: parent
features *reference* sub-timelines rather than embedding them. Each
subresource (a region of the globe) gets its own ordinary `Timeline` over
its own Domain; the parent timeline holds **occurrence features** whose ops
name the subresource by id.

```zig
var region_tl = try ft.Timeline(Region).init(gpa, region_seed, .{});
var globe_tl = try ft.Timeline(Globe).init(gpa, globe_seed, .{});

const env = Env{ .region = &region_tl };      // app-owned registry
globe_tl.setEnv(&env);                        // reaches apply as ctx.env

// Globe Domain:
//   .region_occurrence => |o| read env.region.state(), merge into the doc
const occurrence = try globe_tl.commit(.{ .region_occurrence = .{ .region = 0 } });
```

The rules of the model:

- **Computed-state merge** (recommended over replaying sub-ops in parent
  context): the parent's `apply` reads the sub-timeline's `state()` through
  `ctx.env` and copies what it needs into the parent document. Sub rebuilds
  stay region-sized; the globe document holds summaries, not raw region ops.
- **Invalidation is explicit.** The library cannot see external inputs, so
  when a sub-timeline changes, the app calls `parent.refresh(occurrence_id)`
  to re-run that feature and everything after it. Refresh journals nothing —
  the parent's structure didn't change.
- **Cross-timeline skew is intended.** Scrubbing the *region* marker changes
  what the occurrence reads (after refresh); rolling the *globe* back past
  an occurrence leaves the region's own history untouched — exactly how
  Fusion assemblies treat component occurrences.
- **Environments must be acyclic.** A parent `apply` may call
  `sub.state()`, which may lazily rebuild the sub-timeline; sub-timelines
  must therefore never reference back, directly or transitively.
- **Cross-level dependencies** are declared with
  `DepCollector.depIn(timeline_feature, id)`; parent-level reorder
  validation anchors them at the feature that introduces the sub-timeline.
- **Ids remain per-timeline.** A reference from a parent is always
  `(parent feature id naming the sub-timeline, feature id within it)`.

For a multiuser editor this shape doubles as the future sync/merge unit:
each sub-timeline (with its stable ids and flat journal) is an independent
shard. `src/nested_demo.zig` (part of `zig build run`) walks the whole
pattern: region edits, a stale globe, `refresh`, region-marker scrubbing,
and globe rollback leaving the region untouched.

## Testing

- Unit tests cover each behavior (co-located `test` blocks).
- `tests/oracle.zig` is a differential harness: randomized operation
  sequences across randomized configs run against a naive replay-everything
  reference model, asserting identical documents, statuses, and undo
  capabilities after *every* step. This is the primary net for
  cache-invalidation and journal bugs.
- `src/main.zig` is a terrain-editor demo that exercises every capability
  end-to-end (`zig build run`).

## Layout

```
src/root.zig       public vocabulary: Timeline re-export, Status, ApplyContext,
                   DepCollector, Config, Domain conventions
src/timeline.zig   the Timeline(Domain) engine: marker, edits, invalidation
src/rebuild.zig    pure replay core + background Job
src/checkpoint.zig checkpoint cache (internal)
src/journal.zig    undo/redo journal (internal)
src/persistence.zig save/load container format
src/nested_demo.zig two-level globe/region demo (hierarchical timelines)
src/main.zig       terrain-editor demo
tests/oracle.zig   differential tests vs a naive reference model
```

## Status & non-goals

v0.2.0. Designed for (and shaped by) a multiuser globe-scale GIS/game editor:
feature ids are random-anchored and journal entries are flat and serializable
so a future sync/merge layer can build on them — but multiuser merge, OT, and
CRDT behavior, branching timelines, and partial-order feature DAGs are
explicitly out of scope for this version.
