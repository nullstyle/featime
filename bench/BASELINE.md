# Benchmark baseline

`zig build bench`, ReleaseFast, single thread, Apple Silicon laptop
(`uname -m` arm64), Zig 0.17.0. Document: 64x64 f32 heightmap (16 KiB,
plain data). Default `Config` (checkpoint interval 256, 4 checkpoints,
journal 1024).

## 0.10.0 (2026-10-09): checkpoint window, heap-heavy document

Interval checkpoints are now taken only at the last `max_checkpoints`
intervals before the marker: positions that would be evicted later in the
same pass are no longer cloned. Each clone also copied every feature status
below it, so on the plain document a full replay at 100k features spent
nearly all its time in 390 checkpoints that were thrown away.

### Part 1: plain-data document (same workload as before)

| Operation | 1k | 10k | 100k |
|-----------|---:|----:|-----:|
| commit at tip (per feature) | 80 ns | 44 ns | 45 ns |
| edit first + full replay | 0.016 ms | 0.11 ms | 1.3 ms |
| edit middle + suffix replay | 0.007 ms | 0.08 ms | 0.9 ms |
| scrub to middle | 0.009 ms | 0.07 ms | 1.0 ms |
| scrub back to tip (snapshot) | 0.006 ms | 0.02 ms | 0.2 ms |
| featureById (per lookup) | 6 ns | 7 ns | 24 ns |
| undo middle edit + replay | 0.005 ms | 0.08 ms | 0.7 ms |
| remove middle + replay | 0.010 ms | 0.14 ms | 1.5 ms |
| commit mid-history | 0.003 ms | 0.04 ms | 0.6 ms |
| save / load (lazy) | 0.05 / 0.04 ms | 0.34 / 0.38 ms | 4.0 / 4.1 ms |
| peak live memory | 0.5 MiB | 3.1 MiB | 21.3 MiB |

Replays at 100k went from 33–45 ms to about 1 ms. Files grew (3.6 MB at
100k, was 2.1 MB) because FTZ5 stores a 16-byte order key per feature.

### Part 2: heap-heavy document

An entity list with one owned string per entity; the document grows with
the timeline, so each checkpoint deep-copies everything so far.

| Operation | 1k | 10k | 100k | 100k before the fix |
|-----------|---:|----:|-----:|-----:|
| spawn (commit at tip, per feature) | 90 ns | 96 ns | 96 ns | 98 ns |
| edit first + full replay | 0.05 ms | 0.9 ms | 14 ms | 431 ms |
| edit middle + suffix replay | 0.04 ms | 1.0 ms | 16 ms | 415 ms |
| scrub to middle | 0.02 ms | 0.8 ms | 9 ms | 82 ms |
| scrub back to tip (snapshot) | 0.01 ms | 0.3 ms | 2.9 ms | 3.1 ms |
| cloneDoc of the full document | 0.008 ms | 0.08 ms | 0.8 ms | 2.0 ms |
| undo middle edit + replay | 0.03 ms | 0.8 ms | 8 ms | 230 ms |
| allocations during the run | 10.6k | 208k | 2.1M | 59M |
| peak live memory | 0.6 MiB | 6.0 MiB | 55 MiB | 60 MiB |

What this says: with the window fix a checkpoint of a 100k-entity document
costs under 1 ms and a full replay about 14 ms, almost all of it the
replay itself. Arena-owned documents (roadmap option 3) would remove the
clone cost entirely but it is no longer the bottleneck; the persistent-map
integration (`integrations/hamt/`) remains the answer for documents whose
copies are too big to clone at all.

## 0.9.1 (2026-10-09): id-to-index map, journal as a deque

| Operation | 1k | 10k | 100k |
|-----------|---:|----:|-----:|
| commit at tip (per feature) | 179 ns | 85 ns | 67 ns |
| edit first + full replay | 0.02 ms | 0.7 ms | 45 ms |
| edit middle + suffix replay | 0.01 ms | 0.7 ms | 33 ms |
| scrub to middle | 0.01 ms | 0.24 ms | 8.7 ms |
| scrub back to tip (snapshot) | 0.01 ms | 0.03 ms | 0.2 ms |
| featureById (per lookup) | 9 ns | 17 ns | 29 ns |
| undo middle edit + replay | 0.008 ms | 0.46 ms | 24 ms |
| remove middle + replay | 0.014 ms | 0.67 ms | 33 ms |
| commit mid-history | 0.006 ms | 0.05 ms | 0.8 ms |
| save / load (lazy) | 0.08 / 0.07 ms | 0.49 / 0.46 ms | 3.8 / 3.6 ms |
| peak live memory | 0.5 MiB | 2.6 MiB | 18.4 MiB |

Commits and lookups no longer scale with the feature count: 100k commits
take 6.7 ms instead of 2.2 s. The index costs about 2 MiB at 100k
features. Replays are unchanged.

## 0.9.0 (2026-10-09): before

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
