# Benchmark baseline

`zig build bench`, 2026-10-09, version 0.9.0, ReleaseFast, single thread,
Apple Silicon laptop (`uname -m` arm64), Zig 0.17.0. Document: 64x64 f32
heightmap (16 KiB, plain data). Default `Config` (checkpoint interval 256,
4 checkpoints, journal 1024).

| Operation | 1k | 10k | 100k |
|-----------|---:|----:|-----:|
| commit at tip (per feature) | 200 ns | 3.7 µs | 21.7 µs |
| edit first + full replay | 0.02 ms | 0.5 ms | 42 ms |
| edit middle + suffix replay | 0.007 ms | 0.4 ms | 35 ms |
| scrub to middle | 0.006 ms | 0.14 ms | 8.9 ms |
| scrub back to tip (snapshot) | 0.006 ms | 0.02 ms | 0.2 ms |
| featureById (per lookup) | 124 ns | 1.6 µs | 19.5 µs |
| undo middle edit + replay | 0.005 ms | 0.26 ms | 25 ms |
| remove middle + replay | 0.004 ms | 0.4 ms | 32 ms |
| commit mid-history | 0.002 ms | 0.01 ms | 0.1 ms |
| save / load (lazy) | 0.06 / 0.04 ms | 0.36 / 0.25 ms | 3.5 / 2.4 ms |
| peak live memory | 0.4 MiB | 2.0 MiB | 16.5 MiB |

## What the numbers say

- **Id lookup is a linear scan.** `featureById` and the id-uniqueness check
  inside every `commit` both scale with the feature count: a commit at the
  tip costs 200 ns at 1k features and 22 µs at 100k. Committing 100k
  features takes 2.2 s, almost all of it in that scan. An id-to-index map
  would make both O(1); it is the first optimization to try.
- **Replays are linear in the replayed range, ~350 ns per feature** on this
  document, including the 16 KiB checkpoint clone every 256 features.
  With only 4 checkpoints kept (the latest ones), an edit in the middle of
  100k features replays from the seed. Raising `max_checkpoints` (or
  keeping checkpoints spread along the timeline instead of the latest
  ones) would cut mid-history edits; measure before changing the policy.
- **Snapshot scrubbing is free**, as designed: scrubbing back to a
  snapshotted position is a document swap.
- **Memory is small** for a plain-data document: 16.5 MiB at 100k features
  is mostly the feature list and the journal; checkpoints are 4 x 16 KiB.
  The arena-owned-documents idea only matters for heap-heavy documents,
  which this benchmark does not model yet.
