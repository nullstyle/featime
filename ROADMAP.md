# featime development roadmap

Consolidated plan for the library's next four waves plus a deferred tail.
Background on the library's design (Domain contract, seams, threading model)
lives in README.md; this document only plans forward work.

Current state: v0.9.1 — all four waves below are delivered, on top of the core timeline, checkpoint cache, undo/redo journal,
dependency-aware moves, persistence, background rebuilds, hierarchical
timelines via the reference model.

Sequencing rationale: Waves are ordered by dependency, not just value.
Wave 1 batches every persistence-format change into a single bump (FTZ2) and
lands provenance + timeline identity early, because the sync feed (Wave 4)
depends on both being settled — global identity is the one decision in this
roadmap that is expensive to revisit.

---

## Wave 1 — Annotations & metadata (→ 0.3.0) — DELIVERED

One subsystem: user-authored metadata about the timeline that never affects
document computation (no `apply` involvement, no `dirty()` impact, no Domain
hooks), but participates fully in undo, persistence, and structural fixups.

Kinds: **feature names** (`setFeatureName`), **tags** (plain strings per
feature), **chapters** (named positions), **groups** (contiguous named
spans), **provenance** (author + timestamp per feature).

### M1 — Annotation core: names, chapters, provenance

- Storage layer with string ownership and its own id allocation
  (`ChapterId`, `GroupId` from the random-anchored space).
- Feature names: `setFeatureName(id, name)` / `featureName(id)`.
- Chapters:
  - `Mark = { after: ?FeatureId }` — the gap after a feature; null pins to
    the end of the timeline (follows the tip).
  - `addChapter(name, mark)`, `removeChapter`, `renameChapter`, `chapters()`,
    `markPosition(id)` for slider jumps.
  - Fixup: removing an anchor feature re-anchors to the feature that shifted
    into its index; the remove journal entry snapshots the old anchor so
    undo restores it exactly.
- Provenance: `commitWithMeta(op, .{ .author: u64, .ts: u64 })`; timestamps
  from an optional injected clock (`Config.now: ?*const fn () u64`).
- Identity groundwork: persistent random `timeline_id: u64` written into the
  container header now, so the sync feed never forces another format bump.
- Persistence: container becomes **FTZ2** (header gains `timeline_id`;
  sections for annotations + provenance). Loader accepts FTZ1 as "no
  annotations".
- Change notification: annotation edits bump a counter separate from the
  rebuild generation (which must not be touched — it would spuriously
  invalidate running background jobs); exposed as `annotationsVersion()`.
- Journal: new entry kinds; structural entries gain bounded fixup snapshots
  (a `remove` records the removed feature's tags/names/provenance and any
  chapter re-anchors it caused).
- Oracle: the differential harness gains annotation actions (names,
  chapters) verified against the naive model after every step.

**Acceptance**: names/chapters/provenance survive insert/remove/move and
undo-of-remove at and around their anchors; FTZ1 files load; oracle green.

### M2 — Tags

- `addTag(id, tag)` / `removeTag` / `tags(id)` / `featuresTagged(tag)`.
- Journal + persistence; plain strings (interning is the documented scaling
  path if tag filtering over ~100k-feature timelines gets hot).
- Oracle gains tag actions.

**Acceptance**: undo-of-remove restores the feature *with* its tags (the
app-side-table drift bug, made impossible).

### M3 — Groups

- `{id, name, first: FeatureId, last: FeatureId}`; membership computed as
  the span between anchors (insert-inside joins; move-out leaves, matching
  Fusion folders; boundary deletion re-anchors; empty groups survive).
- `addGroup`, `renameGroup`, `removeGroup` (ungroup — features stay),
  `groupOf`, span queries, `setGroupSuppressed` (batch).
- Span maintenance under every structural op; persistence; oracle actions.

**Acceptance**: membership correct under randomized insert/remove/move in
the oracle.

### M4 — Group move & contents removal

- `moveGroup(group, new_pos)` and `removeGroupContents(group)` as single
  compound journal entries (member ids + parameters stored) — one undo step.
- If compound entries feel cramped, extract general transactions here and
  pull Wave 2 forward.

**Acceptance**: one undo restores members, order, annotations, and marker —
verified against the naive model.

### M5 — Polish

- `annotations` example joining `examples/`; README section; tag **0.3.0**.

---

## Wave 2 — Journal transactions (→ 0.4.0) — DELIVERED

- `journal` grouping: begin/commit/rollback; undo and redo pop whole
  transactions; public ops implicitly transactional; re-express Wave 1's
  compound entries on top.
- Enables app-level macros and any future multi-step atomic edits.

**Acceptance**: group ops re-implemented as transactions with identical
oracle behavior; nested-transaction rules documented and tested.

---

## Wave 3 — Parameters (→ 0.5.0) — DELIVERED

The Fusion parameter table: named values that features reference, so one
parameter edit re-drives every referencing feature.

- Timeline-owned named scalar values (numeric only in v1); journal +
  persistence; UI iteration API.
- Optional `Domain.references(op, collector)` hook declaring which
  parameters an op reads (same shape as `dependencies`).
- Reverse index (parameter → features); editing a parameter invalidates from
  the earliest referencing feature.
- Invalidation note: v1 uses suffix replay as a deliberate over-
  approximation — dirty features may be scattered, but replaying from the
  earliest is correct by determinism. Scattered dirty-set tracking is a
  documented future optimization, not v1 scope.
- Expression language explicitly deferred: apps compute derived values in
  their Domain; revisit only if real usage misses it.

**Acceptance**: editing a parameter recomputes exactly the features that
read it (and their dependents); oracle gains parameter actions.

---

## Wave 4 — Sync feed (→ 0.6.0) — DELIVERED

The multiuser gateway — the honest stopping point for the library; merge and
conflict semantics belong to the application.

- Record observer: callback fired as journal entries are recorded, yielding
  serializable entries (ops already have codecs; annotations and provenance
  are plain data).
- `applyRemote(entry)`: integrate a remote journal entry locally.
- Identity model (decided): `FeatureId` stays a per-timeline u64; global
  identity is `(timeline_id, feature_id)`; remote references are namespaced
  pairs. No 128-bit ids, no breaking change to the plain-data op contract.
- Conflict policy: default last-writer-wins helper; anything richer is the
  app's layer.

**Acceptance**: two timelines in one process converge when fed each other's
entries in a single-threaded interleave; the conflict boundary is
documented with tests on its edges.

---

## Sprint 2 — the deferred tail (→ 0.8.0) — DELIVERED

- **Journal introspection** — `history()` units with kind, size, label,
  timestamp, undone state; `beginLabeledTransaction`; `undoDepth` /
  `redoDepth`.
- **Persistence migration hooks** — `Domain.format_version` recorded in
  containers (FTZ4) and on the wire (v3); `migrateOp` / `migrateDoc` decode
  foreign versions; `error.UnsupportedFormatVersion` without them.
- **Fork & cherry-pick** — `persistence.savePrefix(mark, opts)` and
  `Timeline.cherryPick(src, id, opts)`. Merge stays out of scope.
- **Memory pressure API** — `stats()` and `trim(budget)`.

## Hardening — DELIVERED (0.10.0)

- **Out-of-memory policy** — allocate first, then mutate: every mutator
  either completes or returns `error.OutOfMemory` with nothing changed;
  the journal reserves its slot before any change; multi-step edits unwind
  without allocating; `applyRemote` leaves the sequence unacknowledged on
  `.out_of_memory` so the envelope can be re-delivered. Undo/redo move
  every string between the journal and the live stores instead of copying,
  so they never allocate.
- **Sweep and fuzz** — `tests/oom.zig` (every call × every allocation
  index, then retry, undo, redo) and `tests/fuzz.zig` (decoders on
  arbitrary bytes). The sweep found an inverted remote suppress check,
  inverted group redo, undo losing list positions and order keys, a
  use-after-free with `max_journal = 0`, decoder leaks and a load double
  free.
- **CI** — Windows added; the mise action pinned by commit; `zig build
  docs` generates the API reference.

Undo and redo are allocation-free everywhere: every string a journal
entry carries lives either in the live store (edit applied) or in the
entry (edit undone), and undo/redo swap them. `tests/oom.zig` runs undo
and redo with every allocation failing.

## Checkpoint placement (partly done)

The benchmark showed that interval checkpoints were cloned at every
interval and then evicted by the same pass; they are now taken only in the
last `max_checkpoints` intervals before the marker (full replays at 100k:
45 ms → 1.3 ms). Still open: keeping checkpoints *spread* along the
timeline (so a mid-history edit on a 100k timeline replays from a nearby
checkpoint instead of the seed) and letting the Domain hint document size
for byte budgets. Pull when real usage shows mid-history edits dominating.

## Still parked

- **Disk-backed checkpoints** — session restore without replay. Parked on
  purpose: the implications (who owns the files, how checkpoints stay valid
  across edits, what a half-written checkpoint means on crash) are being
  thought through before any code.
- **Selective replay** (`touches(op, region)` filters) — parked: the
  hierarchical region-timeline partition is the better answer at the app
  level, and filters would fight the whole-document checkpoint model.

## Allocation helpers for integrators (decided; 1 and 2 shipped in 0.9.0)

1. **Scratch arena per feature** — DELIVERED: `ctx.scratch`, an arena the
   timeline resets after every feature. Temporaries in `apply` need no
   `free`.
2. **A dedicated document allocator** — DELIVERED: `Config.doc_allocator`
   (defaults to the gpa) reaches `apply` as `ctx.alloc` and is what
   `cloneDoc` / `deinitDoc` receive; the library's bookkeeping stays on
   the gpa, so document memory is accountable on its own.
3. **Arena-owned documents** — PARKED, now with data: `integrations/hamt/`
   is option 3 done by the application with a persistent map (hamt-zig):
   copies are free and `deinitDoc` is a no-op; the only library hook it
   needed is `forEachDoc` (delivered). Measured: replays grow the arena as
   much as edits do (20k entities: 14 MiB after the commits, 47 MiB after
   two scrubs and an edit, 2.7 MiB after a roll), so the roll policy is the
   whole question — and it belongs where document size and churn are known,
   in the application. Building the arena into the library stays parked.

## References to other timelines — DELIVERED (0.10.0)

`docs/timeline-references.md` compares four options (live links with
library-tracked staleness, pinned references with `viewAt`, snapshots
stored beside the feature, embedded sub-timelines — rejected). Decision:
live links first, then pins.

- **Step 1, live links — DELIVERED:** `Domain.links`, `setRegistry` /
  `Registry` / `LinkHandle`, `ctx.link`, per-timeline versions recorded
  after each run and compared by `dirty()` / `state()` / `beginRebuild`,
  transitive through `version()`, cycle guard (soft failure), job
  rejection when a linked timeline moved, FTZ6 header manifest with
  `persistence.peekHeader`, `linkedTimelines`.
- **Step 2, pinned references — DELIVERED:** `viewAt` / `viewAtMark`
  read a timeline at a position without moving its marker; `pin` / `unpin`
  keep a checkpoint there (spared by eviction and `trim`); pinned links
  (`LinkCollector.pin`) compare `structureVersion()`, so marker moves in
  the other timeline do not re-run the reader; the mark rides in the op,
  so "update reference" is an ordinary edit.
- Follow-ups, also in 0.10.0: `prefixVersion(pos)` (an edit after a
  pinned mark no longer re-runs the reader), `ctx.linkAt` (backward
  references into a timeline being evaluated), and the commit-time
  forward-reference check (`error.ForwardReference`).
- Snapshots (option C) stay in reserve for containers that must load
  alone or jobs that must run while children are edited.

## Open after apps/geo

- **A mark at the start.** `Mark{ .after = null }` is the tip, so nothing
  can anchor before the first feature (a chapter at position 0, a pin
  that excludes everything). A three-way mark (start / after X / tip)
  changes chapters on the wire and in containers; do it together with the
  next format bump.
- **Timeline names.** Containers carry an id, not a name; apps keep their
  own index (`apps/geo` writes `world.txt`). A name in the header would
  remove that boilerplate; same format bump.

## Standing non-goals

Merge/OT/CRDT, branching timelines with merge semantics, parallel feature
application, open plugin registries (the closed comptime union is
load-bearing), and anything UI-shaped — the library stays headless.

## Decision log

- Groups flat in v1; nesting in a fast-follow (span representation doesn't
  preclude it).
- Chapters keep end-pinned marks (`after = null` follows the tip).
- `removeGroupContents` deletes the group and its contents in one undo step.
- Tags are plain strings in v1; no interning, no key:value convention.
- `FeatureId` stays 64-bit; global identity is `(timeline_id, feature_id)`.
- `timeline_id` ships in the FTZ2 header (Wave 1) so the sync feed (Wave 4)
  never forces FTZ3.
- Parameter edits use suffix replay as a correct over-approximation in v1.
- Timestamps come only from an injected clock hook; the library itself
  remains time-source-free.
- Groups keep Fusion folder semantics under moves (0.7.0): a boundary member
  dragged out re-anchors the folder to the remaining members, a folder's only
  member carries it along, `moveGroup` relocates the folder as a block; the
  fixups ride the move's journal entry so undo and redo are exact.
- Unknown ids are errors, never silent no-ops (0.7.0).
- Out of memory never leaves a half-applied edit: allocate first, then
  mutate; the journal slot is reserved before the change (0.10.0).
- Sync order model (0.10): a commit carries its predecessor and an order key
  (Lamport clock, origin id); remote placement is RGA-style — after the
  predecessor, past greater keys — so concurrent commits converge. Moves and
  removes stay positional and application-reconciled; `structureDigest`
  detects divergence. Each `Timeline.init` is a new replica (`replicaId`);
  envelopes carry per-replica sequence numbers; a loaded file is a new
  replica with the file's per-origin bookkeeping.
