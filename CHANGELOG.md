# Changelog

All notable changes to featuretree-zig. The format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow semver.

## Unreleased

### Fixed
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
