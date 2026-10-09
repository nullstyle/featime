# Changelog

All notable changes to featuretree-zig. The format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow semver.

## Unreleased

### Changed (breaking)
- Containers are FTZ6: the header lists the ids of the timelines the
  features link to (FTZ1–FTZ5 still load). `rebuild.applyRange` takes a
  `registry` argument after `env`. The nested demo names its region by
  timeline id and uses the registry instead of `setEnv`.
- Out-of-memory policy: every mutator allocates everything it needs before
  it changes anything, so `error.OutOfMemory` always means "nothing
  happened". The journal reserves its slot first (it no longer drops the
  whole history when it cannot grow). `edit`, `setSuppressed`,
  `setGroupSuppressed`, `setParam`, `remove`, `move` and `moveGroup` can
  now return `error.OutOfMemory`. The library's multi-step edits
  (`moveGroup`, `removeGroupContents`, `cherryPick`) unwind what they had
  done; the unwinding needs no memory. `applyRemote` answers a new
  `ApplyResult.out_of_memory` with nothing applied and the sequence left
  unacknowledged, so the same envelope can be delivered again.
- Undo and redo never allocate. Every string a journal entry carries (a
  feature's name and tags, chapter, group and parameter names, the old and
  new names of a rename) lives in exactly one place: in the live store
  while the edit is applied, in the entry while it is undone. Undo and
  redo swap them; the removal entry keeps a feature's tags as a list and
  its order key. Chapter and group entries are flat (`id`, `mark` or
  `first`/`last`, `name`), live strings are null in the stored entry, and
  the record observer still sees complete entries. `removeTag`,
  `removeChapter`, `removeGroup` and `removeParam` no longer allocate at
  all. Chapter fixes carry the new mark on the wire (wire version 4 is
  still unreleased).

- Sync envelopes. The record observer yields `Timeline.Envelope`
  `{ origin, seq, lamport, entry }` instead of a bare entry; `applyRemote`
  takes an envelope and returns `ApplyResult` (`.applied`, `.dropped`,
  `.duplicate`, `.gap`, `.own`); `sync.encode` / `decode` / `deinit` work
  on envelopes. Wire version 4. Containers are FTZ5 (order keys and the
  per-origin sequence table); FTZ1–FTZ4 still load.

- Interval checkpoints are taken only at the last `max_checkpoints`
  intervals before the marker; positions that the same pass would evict
  are no longer cloned (each clone also copied every feature status below
  it). Full replays at 100k features: 45 ms → 1.3 ms on a 16 KiB document,
  431 ms → 14 ms on a 100k-entity heap document; allocations 59M → 2.1M.

### Fixed
- Remote suppress entries were dropped by an inverted check, so a
  suppression never reached other replicas.
- Redo of a group add, remove or rename did the opposite (removed the
  added group, re-added the removed one, restored the old name).
- Undo of a tag, chapter, group or parameter removal appended the item at
  the end instead of putting it back where it was.
- Undo of a feature removal lost the feature's sync order key.
- With `max_journal = 0` and a record observer, the observer saw memory
  the journal had already freed.
- `sync.decode` leaked the parts it had already decoded when a later read
  failed; `persistence.load` freed a name twice on failure and silently
  dropped tags when memory ran out.
- `persistence.save` and `sync.encode` report exhaustion of their scratch
  memory as `error.OutOfMemory` instead of `error.WriteFailed`.

### Added
- Links to other timelines, step 1 of `docs/timeline-references.md`. The
  optional `Domain.links(op, out: *LinkCollector)` hook names the timelines
  an op reads; `Timeline.setRegistry` installs an app-owned `Registry`
  (timeline id → `LinkHandle`, made by `Timeline.linkHandle()`); `apply`
  resolves one with `ctx.link(id)`. After a feature runs, the library
  remembers each linked timeline's `version()` and re-runs the reading
  features when it changes, through any depth of links; `dirty()` reflects
  it, so `refresh` is only for inputs the library cannot see. A read of a
  timeline being evaluated (a cycle) gets null and soft-fails. Background
  jobs carry the registry and are rejected at `integrate` when a linked
  timeline changed meanwhile. Also `Timeline.version()`,
  `Timeline.linkedTimelines(gpa)` and `persistence.peekHeader(gpa, reader)`.
- `tests/oom.zig`: an out-of-memory sweep over every local mutator, every
  remote entry kind, `load` and `save`. Each call is run once per
  allocation index with that allocation failing; afterwards the state must
  be unchanged, the retried call must match a clean run, and undo and redo
  must work with every allocation failing. It found every bug listed under
  Fixed.
- `tests/fuzz.zig`: `persistence.load` and `sync.decode` + `applyRemote`
  on arbitrary bytes (`zig build test` runs the corpus; `zig build test
  --fuzz` keeps going).
- `zig build docs` generates the API reference into `zig-out/docs`.
- CI runs on Windows too; the mise action is pinned by commit.
- Benchmark part 2: a heap-heavy document (entity list with owned strings);
  `bench/BASELINE.md` records before and after.
- Deterministic order for concurrent commits: each commit carries its
  predecessor and an order key (Lamport clock + origin). Remote commits are
  placed after their predecessor and past any sibling with a greater key,
  so every replica ends up with the same order whatever the delivery order.
- Per-replica sequence numbers with duplicate and gap detection;
  `expectedSeq(origin)`, `acknowledge(origin, seq)`, `replicaId()`;
  `structureDigest()` to compare replicas after a sync round.
- `Timeline.forEachDoc(ctx, visit)`: visit the seed, the live document and
  every checkpoint for in-place transformations (arena rolls, compaction,
  accounting).
- `integrations/hamt/`: a standalone project with hamt-zig's persistent map
  as the document — free checkpoints, an explicit arena roll, measured
  numbers and the finding that replays grow the arena as much as edits do.

## 0.9.1 — 2026-10-09

### Changed
- Id lookups are O(1): an id-to-index map is kept in sync by every feature
  list mutation, so `featureById`, dependency validation and the
  id-uniqueness check in every `commit` no longer scan the feature list. At
  100k features a commit at the tip went from 22 µs to 67 ns and a lookup
  from 19.5 µs to 29 ns.
- The undo journal is a lazily compacted deque: evicting old units when the
  journal is full no longer shifts the whole array on every record.
- `Timeline.rebuildIndex()` is public for `persistence.load` (internal).

### Added
- Benchmark suite: `zig build bench` (always ReleaseFast; `-Dbench-max=N`)
  measures commits, replays, scrubbing, lookups, undo/redo, removal and
  save/load at 1k / 10k / 100k features; `bench/BASELINE.md` records the
  numbers before and after. CI runs it at 10k as a smoke test.

## 0.9.0 — 2026-10-09

### Added
- `ApplyContext.scratch`: an arena the timeline resets after every feature.
  Temporaries in `apply` need no `free`.
- `Config.doc_allocator`: where document memory lives — the seed, the live
  document, checkpoints, job bases, and what `apply` allocates through
  `ctx.alloc`. Defaults to the gpa; the library's own bookkeeping always
  stays on the gpa. `Timeline.docAllocator()` reports it; `ApplyContext.gpa`
  exposes the general allocator.

### Changed (breaking for direct users of the replay core)
- `rebuild.applyRange` takes `rebuild.Allocators { gpa, doc, scratch }`
  instead of one allocator; `rebuild.Job` and the checkpoint cache carry the
  document allocator.
- `ApplyContext.alloc` is now the document allocator (identical to before
  unless `doc_allocator` is set); `fail` messages are allocated from the gpa.

## 0.8.0 — 2026-10-09

### Added
- History introspection: `history()` iterates undo/redo units with kind,
  entry count, label, timestamp and undone state; `undoDepth()` /
  `redoDepth()`; `beginLabeledTransaction(label)` names a unit for history
  panels.
- Memory pressure: `stats()` counts what the timeline holds; `trim(budget)`
  releases checkpoints (the ones nearest the marker survive), old undo units
  and the redo region without touching the document or in-flight jobs.
- Format versions: `Domain.format_version` is recorded in containers and on
  the sync wire; payloads from another version decode through
  `Domain.migrateOp` / `Domain.migrateDoc`, or fail with
  `error.UnsupportedFormatVersion`.
- Forks: `persistence.savePrefix(…, mark, .{ .timeline_id })` writes the
  first `mark` features as an independent container (marker clamped,
  dropped features' annotations dropped, chapters beyond the mark dropped,
  groups clamped, parameters kept).
- Cherry-pick: `Timeline.cherryPick(src, id, opts)` copies one feature
  between timelines (or within one) with its annotations, as one undo unit.
- Examples `history` and `forks`.

### Changed
- Container magic is FTZ4 (header gains `format_version`); FTZ1–FTZ3 files
  still load.
- Sync `wire_version` is 3: the app's format version follows the version
  byte.

## 0.7.0 — 2026-10-09

### Changed (breaking)
- Unknown ids are errors instead of silent no-ops. `edit`, `remove`,
  `setSuppressed`, `refresh`, `setFeatureName`, `clearFeatureName`,
  `addTag`, `removeTag` and `move` return `error.UnknownFeature`; chapter,
  group and parameter mutators return `error.UnknownChapter`,
  `error.UnknownGroup` and `error.UnknownParam`. Mutators that were `void`
  now return error unions: add `try`.
- `addGroup` returns `GroupId` (was `?GroupId`); an unknown anchor is
  `error.UnknownFeature`.
- `moveGroup` returns `GroupMoveError`: `error.GroupTooLarge` above
  `max_group_move` (4096) members instead of a misleading `OutOfMemory`.
  `MoveError` is `{ DependencyViolation, UnknownFeature }` (a move cannot run
  out of memory).
- `validateDomain` checks every hook's parameter types and return shape, so
  a wrong signature fails with one message at `Timeline(Domain)` instead of
  inside the library. Persistence checks its codec hooks the same way.
- Sync wire format: every encoded entry now starts with a version byte
  (`sync.wire_version`, 2); `decode` returns `error.UnsupportedWireVersion`
  for anything else. Move entries carry the group boundary fixups they
  caused, and `GroupFix` carries old and new anchors.
- The demo binary is `zig-out/bin/featuretree-demo`.

### Fixed
- Dragging a group's first or last member out of its span inverted the span
  and the folder appeared empty. The folder now re-anchors to its remaining
  members and undo restores it exactly; a folder's only member carries the
  folder along; `moveGroup` keeps the moved block as the folder.
- `moveGroup` relocated the wrong features for multi-member blocks (it
  always took the feature at the old block start); blocks now move intact in
  both directions.
- No-op edits (an unknown id, suppressing to the current flag, moving to the
  current index, a refused move) no longer bump the rebuild generation, so
  they no longer discard in-flight background jobs.
- Persistence and sync no longer trust frame lengths from the input:
  payloads are read in 64 KiB chunks, so a corrupt or hostile length cannot
  force a multi-gigabyte allocation.
- `zig build test -Doptimize=<mode>` now applies the mode to the library and
  oracle tests, not only to the demo.
- README quick start compiles again (`features()` is an iterator); the
  layout section lists every module; `ApplyContext.alloc` docs match how the
  library itself uses it; `persistence.zig` documents the FTZ3 layout.

### Changed
- `build.zig` rewritten without the `zig init` tutorial comments; the demo
  binary is now `zig-out/bin/featuretree-demo`.

### Added
- MIT license (`LICENSE`, shipped in the package).
- `cloneDoc` and `deinitDoc` are optional for plain-data documents (no
  pointers or slices anywhere inside `Doc`): a bitwise copy is a deep copy.
  `isPlainData(T)`, `cloneDoc(Domain, ...)` and `deinitDoc(Domain, ...)` are
  public. Documents that own references still must declare both; the error
  says so in one sentence.
- The differential oracle now exercises chapters, groups (including
  `moveGroup` and `removeGroupContents`) and parameters, and compares
  anchors and resolved positions after every step.
- GitHub Actions CI: fmt check, tests in Debug/ReleaseSafe/ReleaseFast, the
  examples and the demo, on Linux and macOS.
- This changelog.

## 0.6.1 — 2026-10-07

### Fixed
- Sync: remote and loaded ids no longer advance the local id counter, so
  replicas keep disjoint id ranges and concurrent commits no longer collide.
  New `Config.id_seed` seeds the id anchor from OS randomness.
- Sync: structural remote entries bump the rebuild generation, and
  `integrate` verifies the job still mirrors the feature list — a remote
  entry landing during a background job is rejected instead of installing a
  wrong document or indexing out of bounds.
- A remote insert shifts the local marker only when it lands at or before
  it (the tip follows the tip).
- `nested_demo.zig` tests are now part of `zig build test`; their wrong
  expectation was corrected.

## 0.6.0 — 2026-10-06
- Sync feed: record observer, wire codec, `applyRemote`.

## 0.5.0 — 2026-10-06
- Parameters: named values driving features.

## 0.4.0 — 2026-10-06
- Journal transactions.

## 0.3.0 — 2026-10-06
- Annotations: names, tags, chapters, groups, provenance.

## 0.2.0 — 2026-09-17
- Hierarchical timelines via the reference model.

## 0.1.0 — 2026-09-17
- Core timeline, checkpoint cache, undo/redo journal, dependency-aware
  moves, persistence, background rebuilds, terrain-editor demo.
