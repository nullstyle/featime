# featuretree-zig development roadmap

Consolidated plan for the library's next four waves plus a deferred tail.
Background on the library's design (Domain contract, seams, threading model)
lives in README.md; this document only plans forward work.

Current state: v0.2.x — core timeline, checkpoint cache, undo/redo journal,
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

## Wave 4 — Sync feed (→ 0.6.0)

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

## Deferred tail (post-0.6; pull when real usage demands)

- **Journal introspection** — iterate the undo stack with labels/timestamps
  for a history panel. Cheap anytime once the Wave 1 clock hook exists;
  fold opportunistically into any wave.
- **Persistence migration hooks** — `migrateOp(from_version, bytes)` for
  evolving op schemas; becomes non-optional the moment real external
  documents exist.
- **Fork & cherry-pick** — `savePrefix(mark)` + load for scenario variants;
  cherry-pick copies an op between timelines and lets it recompute. Pairs
  naturally with chapters. Merge stays out of scope.
- **Memory pressure API** — `trim()` to drop checkpoints/journal under
  budget for long sessions.
- **Disk-backed checkpoints** — session restore without replay.
- **Selective replay** (`touches(op, region)` filters) — parked: the
  hierarchical region-timeline partition is the better answer at the app
  level, and filters would fight the whole-document checkpoint model.

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
