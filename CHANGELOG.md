# Changelog

All notable changes to featuretree-zig. The format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow semver.

## 0.7.0 — 2026-10-07

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
