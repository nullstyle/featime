//! featuretree-zig: design feature history for Zig applications.
//!
//! This library gives applications an Autodesk Fusion-style feature timeline:
//! an ordered list of parametric operations ("features") that transform an
//! application-defined document, plus the machinery Fusion users know:
//!
//!   * a scrubable marker (the history slider) — the visible document is the
//!     state after applying every feature before the marker,
//!   * committing while rolled back inserts mid-history at the marker,
//!   * editing, suppressing, removing, and reordering features with
//!     incremental downstream recompute,
//!   * per-feature status (ok / suppressed / failed-with-message) where a
//!     failed feature does not stop the timeline,
//!   * undo/redo of timeline edits, independent of marker position,
//!   * checkpoint caching so scrubbing back and forth is cheap, and
//!   * background (worker-thread) rebuilds for heavy documents.
//!
//! ## The Domain convention
//!
//! An application uses the library by writing a *Domain*: a struct type that
//! names its document type, its feature types, and how features apply.
//! `Timeline(Domain)` is then fully type-checked at compile time.
//!
//! ```zig
//! const MyApp = struct {
//!     pub const Doc = struct { ... };              // the document
//!     pub const Op = union(enum) { ... };          // the feature types
//!
//!     // Required. Applies one feature to the document.
//!     pub fn apply(op: Op, doc: *Doc, ctx: *ApplyContext) anyerror!void { ... }
//!
//!     // Only when Doc owns heap memory (pointers or slices anywhere inside
//!     // it): deep-copy and destroy documents (seed + checkpoints). A plain-
//!     // data document is copied bitwise and needs neither.
//!     pub fn cloneDoc(doc: *const Doc, gpa: std.mem.Allocator) anyerror!Doc { ... }
//!     pub fn deinitDoc(doc: *Doc, gpa: std.mem.Allocator) void { ... }
//! };
//!
//! var tl = try Timeline(MyApp).init(gpa, seed_doc, .{});
//! defer tl.deinit();
//! ```
//!
//! ## Contracts
//!
//! * **Op must be plain data.** Op payloads must not own heap memory and must
//!   not contain pointers into the document. Reference earlier features or
//!   document entities by `FeatureId` instead. (This is what makes ops
//!   serializable and replayable in any order the timeline allows.)
//! * **Soft failure.** `return ctx.fail("edge {d} no longer exists", .{e})`
//!   reports a failed feature: the status is recorded and the rebuild
//!   continues with later features (Fusion shows an error badge and keeps
//!   going). On this path `apply` must leave `doc` untouched — validate
//!   first, mutate second.
//! * **Hard failure.** Returning any other error (in practice OutOfMemory)
//!   aborts the rebuild. The timeline is flagged broken; `state()` keeps
//!   serving the last good document, and the next rebuild attempt starts
//!   fresh from a checkpoint or the seed.
//! * **Thread safety.** `Timeline` is single-owner and not thread-safe. The
//!   rebuild core is a pure function so rebuilds can run on a worker thread
//!   via the background-rebuild API.

const std = @import("std");

pub const timeline = @import("timeline.zig");
pub const rebuild = @import("rebuild.zig");
pub const persistence = @import("persistence.zig");
pub const annotations = @import("annotations.zig");
pub const params = @import("params.zig");
pub const sync = @import("sync.zig");

pub const Timeline = timeline.Timeline;
pub const Mark = annotations.Mark;
pub const Param = params.Param;
pub const ParamId = params.ParamId;
pub const ParamRefCollector = params.ParamRefCollector;
pub const Meta = annotations.Meta;
pub const Chapter = annotations.Chapter;
pub const ChapterId = annotations.ChapterId;

/// Stable identifier for a feature on a timeline.
///
/// Ids are assigned when a feature is committed, never change, and are not
/// reused. External references to features (dependencies, journal entries,
/// persistence, UI selection) use ids; array indices are an internal detail
/// that shifts on every insert/remove/reorder.
pub const FeatureId = u64;

/// Outcome of a feature as of the most recent rebuild at the current marker.
///
/// Valid only for features before the marker; features at or after the marker
/// report `.pending` (they are "not computed", exactly like features to the
/// right of Fusion's timeline marker).
pub const Status = union(enum) {
    /// Not applied: feature is at/after the marker, or a rebuild has not
    /// reached it yet.
    pending,
    /// Applied successfully.
    ok,
    /// Present but suppressed; skipped during rebuild.
    suppressed,
    /// Applied and failed. The message is owned by the timeline and stays
    /// valid until the next rebuild that touches this feature.
    failed: []const u8,
};

/// A feature's key in the replicated order: the Lamport clock value of the
/// replica that committed it, with that replica's id as the tie-breaker.
/// `Timeline.applyRemote` places a remote commit right after its predecessor
/// and then past every following feature whose key is greater, so
/// concurrent commits land in the same order on every replica.
pub const OrderKey = struct {
    lamport: u64 = 0,
    origin: u64 = 0,

    pub fn greaterThan(a: OrderKey, b: OrderKey) bool {
        if (a.lamport != b.lamport) return a.lamport > b.lamport;
        return a.origin > b.origin;
    }
};

/// Stored representation of one feature on the timeline.
pub fn Feature(comptime Op: type) type {
    return struct {
        id: FeatureId,
        op: Op,
        suppressed: bool = false,
        status: Status = .pending,
        /// Replicated order key (see `OrderKey`); zero on features that
        /// predate 0.10 files.
        order: OrderKey = .{},
    };
}

/// A read-only view of a feature, as returned by `Timeline.features()`.
pub fn FeatureView(comptime Op: type) type {
    return struct {
        id: FeatureId,
        op: *const Op,
        suppressed: bool,
        status: Status,
        /// User-assigned display name, if any (annotation layer).
        name: ?[]const u8 = null,
        /// Authorship/timestamp recorded at commit, if any (annotation layer).
        meta: ?Meta = null,
    };
}

/// Handed to `Domain.apply` for every feature application.
pub const ApplyContext = struct {
    /// The document allocator: `Config.doc_allocator`, or the timeline's
    /// `gpa` when none is set. Use it for memory the document keeps — the
    /// demos append to document lists with it. `cloneDoc` and `deinitDoc`
    /// receive the same allocator, and the seed passed to `Timeline.init`
    /// must come from it.
    alloc: std.mem.Allocator,

    /// Scratch memory for this `apply` call only: an arena the timeline
    /// resets as soon as the feature returns. Allocate temporaries here and
    /// never free them. Never store a scratch pointer in the document.
    scratch: std.mem.Allocator,

    /// The timeline's general allocator (`fail` messages, bookkeeping).
    gpa: std.mem.Allocator,

    /// Id of the feature being applied. Ops that create named entities in
    /// the document (Fusion-style "the body this extrude produced") can
    /// stamp this id into the document so later ops can reference it.
    feature_id: FeatureId = 0,

    /// Opaque per-timeline environment set via `Timeline.setEnv`, or null.
    /// The primary use is hierarchical timelines: an environment holding a
    /// sub-timeline registry lets a parent feature's `apply` read their
    /// computed state. Environments must be acyclic — see the README section
    /// on hierarchical timelines.
    env: ?*anyopaque = null,

    /// The timeline's parameter values (`addParam`/`setParam`), visible to
    /// `apply` as `ctx.param(id)`. Background jobs snapshot the slice.
    param_values: []const params.Param = &.{},

    message: ?[]const u8 = null,

    /// Read a parameter value by id, or null when absent (features
    /// typically soft-fail on a missing parameter).
    pub fn param(self: *const ApplyContext, id: ParamId) ?f64 {
        for (self.param_values) |p| {
            if (p.id == id) return p.value;
        }
        return null;
    }

    /// Record a soft failure for the feature being applied and return
    /// `error.FeatureFailed`. The message is owned by the timeline and
    /// remains valid until the next rebuild that reaches this feature.
    ///
    /// `apply` must leave the document unmodified on this path.
    pub fn fail(self: *ApplyContext, comptime fmt: []const u8, args: anytype) error{FeatureFailed} {
        self.message = std.fmt.allocPrint(self.gpa, fmt, args) catch "feature failed";
        return error.FeatureFailed;
    }
};

/// One dependency edge declared through the optional `Domain.dependencies`
/// hook. `Timeline.move` refuses reorders that would place a dependency
/// after its dependent.
pub const Dep = union(enum) {
    /// A dependency on another feature of the same timeline.
    feature: FeatureId,
    /// A dependency on a feature *inside* a sub-timeline. Ordering at this
    /// timeline's level is anchored at `timeline_feature` — the feature that
    /// introduces the sub-timeline; deeper ordering belongs to the
    /// sub-timeline's own validation.
    in_timeline: struct { timeline_feature: FeatureId, feature: FeatureId },
};

/// Handed to the optional `Domain.dependencies` hook.
pub const DepCollector = struct {
    gpa: std.mem.Allocator,
    deps: std.ArrayList(Dep) = .empty,
    failed: bool = false,

    /// Declare a dependency on another feature of this timeline.
    pub fn dep(self: *DepCollector, id: FeatureId) void {
        self.deps.append(self.gpa, .{ .feature = id }) catch {
            self.failed = true;
        };
    }

    /// Declare a dependency on a feature inside the sub-timeline introduced
    /// by `timeline_feature` (hierarchical references).
    pub fn depIn(self: *DepCollector, timeline_feature: FeatureId, id: FeatureId) void {
        self.deps.append(self.gpa, .{ .in_timeline = .{
            .timeline_feature = timeline_feature,
            .feature = id,
        } }) catch {
            self.failed = true;
        };
    }
};

/// Optional wall-clock source for provenance timestamps. The library itself
/// is time-source-free; when set, plain `commit` auto-stamps features.
pub const Clock = *const fn () u64;

/// Tuning knobs for a timeline. The defaults favor correctness and cheap
/// scrubbing on small documents; applications with huge documents (the
/// globe-scale case) lower `max_checkpoints` and raise `checkpoint_interval`.
pub const Config = struct {
    /// Wall clock used to stamp provenance on plain commits (see `Clock`).
    now: ?Clock = null,
    /// Where document memory lives: the seed you pass to `init`, every copy
    /// `cloneDoc` makes (live document, checkpoints, job bases), and what
    /// `apply` allocates through `ctx.alloc`. Null means the timeline's
    /// `gpa`. A dedicated pool or budgeted allocator here keeps document
    /// memory accountable separately from the library's own bookkeeping
    /// (journal, checkpoints' status copies, failure messages), which
    /// always uses the `gpa`.
    doc_allocator: ?std.mem.Allocator = null,
    /// Entropy for this timeline's random id anchor: the start of the shared
    /// feature/chapter/group/param id counter and the `timeline_id`.
    /// Replicas must allocate ids from disjoint ranges, so in multi-process
    /// or multi-machine deployments pass fresh OS randomness per timeline
    /// (for example 8 bytes from `Io.random`). When null the library mixes
    /// ASLR'd addresses with a process-local counter: always distinct within
    /// one process, likely but not guaranteed distinct across processes.
    id_seed: ?u64 = null,
    /// Write an extra checkpoint every N applied features during a rebuild.
    /// 0 disables interval checkpoints.
    checkpoint_interval: u32 = 256,
    /// Maximum number of document checkpoints kept. Memory use is roughly
    /// `max_checkpoints` document copies. 0 keeps only the seed.
    max_checkpoints: u8 = 4,
    /// Snapshot the current state when the marker leaves a position, making
    /// back-and-forth slider scrubbing free.
    checkpoint_on_scrub: bool = true,
    /// Maximum undo/redo entries retained. 0 disables the journal.
    max_journal: u32 = 1024,
};

/// Compile-time check that a Domain satisfies the conventions above, with a
/// readable message instead of a compiler traceback from deep inside the
/// library.
pub fn validateDomain(comptime Domain: type) void {
    if (@typeInfo(Domain) != .@"struct")
        @compileError("Timeline expects a Domain struct type, got " ++ @typeName(Domain));
    if (!@hasDecl(Domain, "Doc"))
        @compileError("Domain must declare `pub const Doc: type` (the document features transform)");
    if (!@hasDecl(Domain, "Op"))
        @compileError("Domain must declare `pub const Op: type` (a tagged union of feature payloads)");
    if (@typeInfo(Domain.Op) != .@"union")
        @compileError("Domain.Op must be a tagged union of feature payloads, got " ++ @typeName(Domain.Op));
    if (!@hasDecl(Domain, "apply"))
        @compileError("Domain must declare `pub fn apply(op: Op, doc: *Doc, ctx: *ApplyContext) anyerror!void`");
    // Documents that own references need the copy/destroy pair; plain-data
    // documents (no pointers or slices anywhere inside) are copied bitwise.
    if (!@hasDecl(Domain, "cloneDoc") and !isPlainData(Domain.Doc))
        @compileError("Domain.Doc contains pointers or slices, so Domain must declare `pub fn cloneDoc(doc: *const Doc, gpa: std.mem.Allocator) anyerror!Doc` (a deep copy, for the seed and checkpoints)");
    if (!@hasDecl(Domain, "deinitDoc") and !isPlainData(Domain.Doc))
        @compileError("Domain.Doc contains pointers or slices, so Domain must declare `pub fn deinitDoc(doc: *Doc, gpa: std.mem.Allocator) void` (frees what cloneDoc allocated)");

    // Shapes, not just names: a wrong signature fails here, in one message,
    // instead of deep inside the library's call sites.
    checkHook(Domain, "apply", &.{ Domain.Op, *Domain.Doc, *ApplyContext }, void, .error_union, "fn (op: Op, doc: *Doc, ctx: *ApplyContext) anyerror!void");
    if (@hasDecl(Domain, "cloneDoc"))
        checkHook(Domain, "cloneDoc", &.{ *const Domain.Doc, std.mem.Allocator }, Domain.Doc, .error_union, "fn (doc: *const Doc, gpa: std.mem.Allocator) anyerror!Doc");
    if (@hasDecl(Domain, "deinitDoc"))
        checkHook(Domain, "deinitDoc", &.{ *Domain.Doc, std.mem.Allocator }, void, .exact, "fn (doc: *Doc, gpa: std.mem.Allocator) void");
    if (@hasDecl(Domain, "dependencies"))
        checkHook(Domain, "dependencies", &.{ Domain.Op, *DepCollector }, void, .exact, "fn (op: Op, out: *DepCollector) void");
    if (@hasDecl(Domain, "references"))
        checkHook(Domain, "references", &.{ Domain.Op, *ParamRefCollector }, void, .exact, "fn (op: Op, out: *ParamRefCollector) void");
}

/// True when a value of `T` can be duplicated with `=` and needs no cleanup:
/// no pointers, slices, or other references anywhere inside it. Documents of
/// such types get `cloneDoc` and `deinitDoc` for free.
pub fn isPlainData(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .float, .bool, .void, .@"enum", .enum_literal, .error_set => true,
        .array => |a| isPlainData(a.child),
        .vector => |v| isPlainData(v.child),
        .optional => |o| isPlainData(o.child),
        .@"struct" => |s| allPlainData(s.field_types),
        .@"union" => |u| allPlainData(u.field_types),
        else => false,
    };
}

fn allPlainData(comptime types: []const type) bool {
    inline for (types) |t| {
        if (!isPlainData(t)) return false;
    }
    return true;
}

/// Deep-copy a document through the Domain's `cloneDoc`, or bitwise for a
/// plain-data document that declares none.
pub fn cloneDoc(comptime Domain: type, doc: *const Domain.Doc, gpa: std.mem.Allocator) anyerror!Domain.Doc {
    if (comptime @hasDecl(Domain, "cloneDoc")) {
        return Domain.cloneDoc(doc, gpa);
    } else {
        return doc.*;
    }
}

/// Destroy a document through the Domain's `deinitDoc`; nothing to do for a
/// plain-data document that declares none.
pub fn deinitDoc(comptime Domain: type, doc: *Domain.Doc, gpa: std.mem.Allocator) void {
    if (comptime @hasDecl(Domain, "deinitDoc")) Domain.deinitDoc(doc, gpa);
}

pub const ReturnShape = enum { exact, error_union };

/// Compile-time shape check for one Domain hook: parameter count and types
/// must match exactly; the return type must be `payload` (`.exact`) or an
/// error union whose payload is `payload` (`.error_union`, any error set).
/// Used by `validateDomain` and by `persistence` for the codec hooks.
pub fn checkHook(
    comptime Domain: type,
    comptime name: []const u8,
    comptime param_types: []const type,
    comptime payload: type,
    comptime ret_shape: ReturnShape,
    comptime shape: []const u8,
) void {
    const F = @TypeOf(@field(Domain, name));
    const info = @typeInfo(F);
    if (info != .@"fn")
        @compileError("Domain." ++ name ++ " must be a function of the shape `" ++ shape ++ "`, found " ++ @typeName(F));
    const f = info.@"fn";
    if (f.param_types.len != param_types.len)
        @compileError(std.fmt.comptimePrint("Domain.{s} takes {d} parameter(s); the library calls it as `{s}`", .{ name, f.param_types.len, shape }));
    inline for (f.param_types, param_types, 0..) |have, want, i| {
        const have_t = have orelse
            @compileError(std.fmt.comptimePrint("Domain.{s}: parameter {d} must be `{s}`, not `anytype` (shape: `{s}`)", .{ name, i, @typeName(want), shape }));
        if (have_t != want)
            @compileError(std.fmt.comptimePrint("Domain.{s}: parameter {d} has type `{s}`, expected `{s}` (shape: `{s}`)", .{ name, i, @typeName(have_t), @typeName(want), shape }));
    }
    const ret = f.return_type orelse
        @compileError("Domain." ++ name ++ " must declare its return type: `" ++ shape ++ "`");
    switch (ret_shape) {
        .exact => if (ret != payload)
            @compileError(std.fmt.comptimePrint("Domain.{s} must return `{s}` (shape: `{s}`), found `{s}`", .{ name, @typeName(payload), shape, @typeName(ret) })),
        .error_union => {
            const ri = @typeInfo(ret);
            if (ri != .error_union or ri.error_union.payload != payload)
                @compileError(std.fmt.comptimePrint("Domain.{s} must return an error union of `{s}` (shape: `{s}`), found `{s}`", .{ name, @typeName(payload), shape, @typeName(ret) }));
        },
    }
}

test {
    _ = timeline;
    _ = rebuild;
    _ = persistence;
    _ = annotations;
    _ = params;
    _ = sync;
}
