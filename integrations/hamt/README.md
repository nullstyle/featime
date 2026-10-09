# featime + hamt-zig

A persistent hash array mapped trie as the timeline's document. This is a
standalone project (its own `build.zig.zon`) that depends on featime
by path and on [hamt-zig](https://github.com/nullstyle/hamt-zig) checked out
next to it (`../../../hamt-zig`, on Zig 0.17.0).

```sh
cd integrations/hamt
zig build test
zig build run -Doptimize=ReleaseFast
```

## The pattern

```zig
const Entities = hamt.AutoMap(u64, Entity);

const World = struct {
    pub const Doc = struct { entities: Entities };   // a small immutable map value
    pub const Op = union(enum) { place: ..., move: ..., remove: ... };

    pub fn apply(op: Op, doc: *Doc, ctx: *ft.ApplyContext) anyerror!void {
        // every mutation is `doc.entities = try doc.entities.put(...)`
    }
    pub fn cloneDoc(doc: *const Doc, gpa: std.mem.Allocator) anyerror!Doc {
        return doc.*;                                 // the copy is the clone
    }
    pub fn deinitDoc(doc: *Doc, gpa: std.mem.Allocator) void {}   // the arena owns every version
};
```

Every document copy the timeline makes (seed, live, checkpoints, job bases)
is a value copy that shares structure with the others. Taking a checkpoint
costs nothing. `deinitDoc` is a no-op.

The price is the arena: every version ever made lives in it until it is
reset. Two things grow it:

1. Edits: each `put` copies a path of nodes (expected).
2. **Replays**: every re-applied feature makes new nodes too. Scrubbing back
   and replaying 10k features allocates as much as committing them did.

So the application rolls the arena now and then: drop the checkpoints
(`tl.trim(.{ .checkpoints = 0 })`), re-home the seed and live documents into
a fresh arena with `Timeline.forEachDoc`, free the old arena. `rollArena` in
`src/main.zig` does exactly that. Roll when `arena.queryCapacity()` crosses
a budget, never while a background job is in flight (its base document is
not visited by `forEachDoc`).

## Numbers

ReleaseFast, Apple Silicon, 20 000 entities, 2026-10-09:

| Step | Time | Arena |
|------|-----:|------:|
| place 20 000 entities (20 000 commits) | 4.0 ms | 13.6 MiB |
| scrub to the middle (10 000 replayed puts) | 2.7 ms | |
| scrub back (snapshot) | 1.3 ms | |
| edit in the middle + 10 000-feature suffix replay | 5.3 ms | 46.7 MiB |
| roll the arena | 2.2 ms | 2.7 MiB |
| undo the edit + full replay (no checkpoints left) | 5.7 ms | |

Compare with the plain 16 KiB array document in `bench/BASELINE.md`: a
persistent `put` costs about the same as a float add plus the checkpoint
clone there, and checkpoints here are free, but the arena needs a roll
policy. For heap-heavy documents (many entities, many strings) this is the
cheaper checkpoint model; for small plain-data documents the array copy is
simpler.

## What this says about "arena-owned documents" (roadmap option 3)

This is option 3 done by the application: the arena is the document's
allocator, copies are free, and compaction is explicit. The library needed
exactly one hook for it, `forEachDoc`. Building the arena into the library
would add the roll policy (when, and what to do with in-flight jobs) to the
library's contract; keeping it in the application keeps that policy where
the document's size and churn are known.
