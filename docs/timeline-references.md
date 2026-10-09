# References to other timelines — options

Status (2026-10-09): decision taken — A then B. Step 1 (A, live links) is
built; see the README section "Hierarchical timelines and links". Step 2
(B, pinned references) is next.

A *reference* is a feature in one timeline that reads another timeline.
Today the library supports one shape of it: the parent's `apply` reads a
sub-timeline's current state through `ctx.env`. This note lists what that
shape cannot do, the questions any design must answer, four options with
their costs, and a recommendation.

## 1. What exists today

| Piece | Where | What it gives |
|---|---|---|
| `ctx.env` | `Timeline.setEnv`, `ApplyContext.env` | an opaque app registry; the parent's `apply` casts it and calls `sub.state()` |
| `refresh(id)` | `Timeline.refresh` | explicit invalidation: re-run one feature and everything after it; nothing journaled |
| `DepCollector.depIn(timeline_feature, id)` | `Domain.dependencies` | ordering validation anchored at the feature that introduces the sub-timeline |
| `timeline_id` | `Timeline.timelineId`, FTZ containers | a stable 64-bit identity per timeline |
| `cherryPick`, `savePrefix` | persistence, timeline | copies between timelines of the same Domain (values, not references) |

`src/nested_demo.zig` shows the pattern end to end. Its limits:

1. **Invalidation is manual.** The parent is stale until the app calls
   `refresh`. Forgetting it shows old data with a fresh status.
2. **A reference reads the child at the child's current marker.** Scrubbing
   the region changes what the globe computes next time. That is Fusion's
   assembly skew, but there is no way to pin a reference to a version.
3. **The link is invisible to the library.** It is not journaled, not
   persisted, not on the wire. A loaded globe container does not know which
   regions it needs or in which order to load them.
4. **Background jobs are unsafe with references.** A job runs `apply` on
   another thread; `apply` calls `sub.state()`, which may rebuild the child.
   `Timeline` is single-owner, so this is a data race if the child is being
   edited meanwhile.
5. **No cycle check.** The README asks for acyclic environments; nothing
   enforces it. A cycle is unbounded recursion in `state()`.
6. **Peer references have no model.** Region A reading region B (a river
   crossing a border) is the same mechanism as globe-reads-region, but two
   regions reading each other is a cycle.

## 2. What any design must answer

| Axis | Question |
|---|---|
| Identity | how a feature names another timeline and a thing inside it |
| Reading | which *version* of the other timeline it reads: live marker, a pinned position, or a copy taken at edit time |
| Invalidation | who notices that the other timeline changed |
| Determinism | does the parent's document depend on where someone left the child's slider |
| Cycles | how A→B→A is prevented or made harmless |
| Threads | can a background job evaluate the reference |
| Persistence | what a container records about its references; can it load alone |
| Sync | what crosses the wire; what a replica must already have |
| Undo | per-timeline undo stays (Fusion rule); what an "update reference" edit looks like |
| Memory and time | replays, document clones, snapshots |

## 3. Options

### A. Live links with library-tracked staleness

Keep "read the child's current state", but make the link visible so the
library can do the invalidation.

API sketch:

```zig
// Domain hook, like `references` for parameters:
pub fn links(op: Op, out: *ft.LinkCollector) void {
    switch (op) { .region_occurrence => |o| out.link(o.region_timeline), else => {} }
}

// App-provided registry (vtable), replaces the opaque env or sits beside it:
pub const Registry = struct {
    ctx: *anyopaque,
    resolve: *const fn (ctx: *anyopaque, id: u64) ?*anyopaque, // the app casts to its Timeline type
    version: *const fn (ctx: *anyopaque, id: u64) ?u64,        // the child's change counter
};
tl.setRegistry(reg);
```

Mechanism: when a feature applies, the timeline records, per link, the
child's version at that moment. `dirty()`, `state()` and `beginRebuild`
compare recorded versions with current ones and invalidate from the
earliest changed feature, exactly like `invalidateReferencing` does for
parameters. `refresh` stays as an escape hatch. A public `version()` on
`Timeline` is needed (the `gen` counter exists, it is private).

Cycle check: the registry marks a timeline "evaluating" while its
`state()` runs; a nested resolve of a marked timeline soft-fails the
feature ("reference cycle"). Cheap, exact.

| Axis | Verdict |
|---|---|
| Reading | live (child's marker); skew stays |
| Invalidation | automatic |
| Determinism | no: depends on the child's slider |
| Cycles | detected at evaluation, soft failure |
| Threads | unchanged hazard; rule: do not edit a child while a parent job runs |
| Persistence | the container can record the link ids as a manifest (from `links`); it still needs the children present to rebuild |
| Sync | nothing new on the wire; the manifest tells a replica what to fetch |
| Memory | a few u64 per link per feature |
| Library change | small-medium: hook, registry, per-feature link versions, version compare in three places |

### B. Pinned references: read a timeline at a position

A reference names a *version* of the child: `(timeline_id, mark)` where
`mark` is a `Mark{ .after = feature_id }` (anchored, survives inserts) or
a chapter id. The parent computes the child's document at that position
without moving the child's marker.

API sketch:

```zig
// Child side: evaluate at a position into a caller-owned document.
pub fn viewAt(self: *Self, pos: u32, out: *Doc) RebuildError!void;   // from the nearest checkpoint, replay forward
pub fn pin(self: *Self, pos: u32) !PinId;   // keep a checkpoint alive at `pos`
pub fn unpin(self: *Self, pin: PinId) void;

// Parent op (plain data, so it journals, syncs and persists as it is):
region_occurrence: struct { region: u64, at: ft.Mark },
```

"Update to latest" is an ordinary `edit` of the occurrence op: journaled,
undoable, on the wire. That is Fusion's linked-component version model.

Invalidation becomes rare: only an edit *before* the pinned mark in the
child changes what the parent sees. Option A's version tracking still
tells the parent when that happens; without it, `refresh` stays manual.

Cycles: a pin that names a mark whose Lamport time is earlier than the
pinning feature's own Lamport time cannot be part of a cycle; the library
can reject other pins at commit (`error.ForwardReference`). Peer
references (A reads B, B reads A, at earlier marks) become legal and
terminate.

Cost: a view far from the child's marker replays from the seed (the
checkpoint window keeps only the last `max_checkpoints` intervals). At
100k features that is about 35 ms per view. `pin` fixes it by keeping a
checkpoint at the pinned position; the checkpoint cache gains a pinned
set that eviction skips.

| Axis | Verdict |
|---|---|
| Reading | a named version; the child's slider is irrelevant |
| Invalidation | rare; automatic with A, manual without |
| Determinism | yes |
| Cycles | impossible for backward pins; checkable at commit |
| Threads | `viewAt` reads the checkpoint cache: still owner-thread only; a job must get the view before it starts (see C) |
| Persistence | the mark is in the op; a manifest as in A |
| Sync | nothing new; an update is a normal edit |
| Memory | one pinned checkpoint (a document copy) per distinct pinned position |
| Library change | medium: `viewAt`, pins in the checkpoint cache, a forward-reference check |

### C. Snapshots: copy what the reference reads, at edit time

The parent never evaluates the child during a rebuild. When the user
adds or updates a reference, the app (on the owner thread) computes what
the feature needs from the child and the timeline stores that blob beside
the feature. `apply` reads the blob through the context.

API sketch:

```zig
pub fn setAttachment(self: *Self, id: FeatureId, bytes: []const u8) !void; // journaled: attachment_set { old, new }
// in apply:
const blob = ctx.attachment() orelse return ctx.fail("no snapshot", .{});
```

Attachments ride the container (a new FTZ section) and the wire (a new
entry kind), and undo swaps old and new blobs like names do today.

| Axis | Verdict |
|---|---|
| Reading | a copy taken when the user chose to |
| Invalidation | none needed; "Update" is an explicit edit |
| Determinism | yes |
| Cycles | impossible (no evaluation of other timelines) |
| Threads | safe: jobs read only the parent |
| Persistence | the container loads alone, children absent |
| Sync | blobs on the wire; large if the snapshot is large |
| Memory | one blob per reference, plus the old blob while undo can reach it |
| Library change | medium: attachment store, journal entry, container section, wire tag, undo swap |

This is Fusion's "break link" or a derived-copy workflow, not a live
assembly. It is the only option where a globe container is self-contained
and where background jobs stay safe without rules.

### D. Embedded sub-timelines (rejected)

Put the child timeline inside the parent document and replay its ops in
parent context. Every checkpoint of the parent would clone whole child
timelines, undo units would mix levels, and the sync shard model (one
feed per timeline) would break. The README already recommends the merge
model over this. Not pursued.

## 4. Side by side

| | A live links | B pinned | C snapshots |
|---|---|---|---|
| Automatic invalidation | yes | with A | not needed |
| Deterministic parent | no | yes | yes |
| Peer references | DAG only | yes (backward pins) | yes |
| Background jobs safe | no | no | yes |
| Container loads alone | no | no | yes |
| Wire change | none | none | new entry + blobs |
| Memory | tiny | a checkpoint per pin | a blob per reference |
| Fusion analogue | assembly with live components | linked components at a version | derived copy |
| Size of change | small-medium | medium | medium |

## 5. Recommendation

Build **A then B**, as one "link" feature in two steps:

1. **Step 1 (A):** `Domain.links` + `setRegistry` + per-feature link
   versions + automatic invalidation + the cycle check + a link manifest
   in containers. This removes the two sharpest edges today (forgotten
   `refresh`, silent cycles) and costs little. Keep `setEnv` working; the
   registry can carry the env pointer.
2. **Step 2 (B):** `viewAt` and pins, with the mark in the op. This makes
   references deterministic and makes peer references legal. Everything
   journals and syncs through existing entry kinds.

Leave **C** for the two cases that need it, if they come: a parent that
must load with its children absent, or background jobs that must run while
children are being edited. Both can be added later on top of A+B as an
attachment store; nothing in A or B blocks it.

Decisions needed before step 1:

- Live by default, or pinned by default? (A+B allows both per op; the
  Domain decides. The recommendation is pinned once B exists.)
- Must a container load without its references? (If yes now, C moves up.)
- Do background jobs need to evaluate references? (If yes now, C moves up,
  or jobs take a pre-computed view as input.)
