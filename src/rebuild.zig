//! The pure rebuild core: apply a range of features to a document, recording
//! per-feature status. Shared by the synchronous path (`Timeline.state()`)
//! and the background-rebuild path, which is why it touches nothing but its
//! arguments.

const std = @import("std");
const ft = @import("root.zig");

/// Applies `features[from..to]` to `doc`, writing each feature's status.
///
/// `env` is opaque to the library and reaches `Domain.apply` as
/// `ApplyContext.env` (see `Timeline.setEnv`).
///
/// Suppressed features are skipped and marked `.suppressed`. A soft failure
/// (`error.FeatureFailed` via `ApplyContext.fail`) is recorded as `.failed`
/// and the range continues — a failed feature does not stop the timeline.
/// Any other error aborts the pass (the document may be mid-mutation and is
/// untrusted); `applied.*` still reports how many features completed so the
/// caller can reason about partial progress.
///
/// `features` is mutable because feature status is stored in place; nothing
/// but `.status` is written.
pub fn applyRange(
    comptime Domain: type,
    features: []ft.Feature(Domain.Op),
    from: u32,
    to: u32,
    doc: *Domain.Doc,
    gpa: std.mem.Allocator,
    env: ?*anyopaque,
    param_values: []const ft.Param,
    applied: *u32,
) anyerror!void {
    applied.* = from;
    var i = from;
    while (i < to) : (i += 1) {
        const feature = &features[i];
        if (feature.suppressed) {
            feature.status = .suppressed;
            applied.* = i + 1;
            continue;
        }
        var ctx: ft.ApplyContext = .{
            .alloc = gpa,
            .feature_id = feature.id,
            .env = env,
            .param_values = param_values,
        };
        Domain.apply(feature.op, doc, &ctx) catch |err| switch (err) {
            error.FeatureFailed => {
                feature.status = .{ .failed = ctx.message orelse "feature failed" };
                applied.* = i + 1;
                continue;
            },
            else => return err,
        };
        feature.status = .ok;
        applied.* = i + 1;
    }
}

/// A background rebuild: a pure, self-contained computation of the document
/// at a captured marker position. `Timeline.beginRebuild` produces one (the
/// base document comes from a consumed checkpoint or a seed clone, so heavy
/// documents are not copied), `run` may execute on any thread, and
/// `Timeline.integrate` installs the result on the owner thread — rejecting
/// anything stale via the generation captured at begin time.
///
/// `cancel` is safe to call from any thread; `run` notices between features.
pub fn Job(comptime Domain: type) type {
    const Feature = ft.Feature(Domain.Op);

    return struct {
        const Self = @This();

        pub const State = enum {
            pending,
            running,
            done,
            failed,
            cancelled,
            consumed,
        };

        gpa: std.mem.Allocator,
        /// Timeline generation at begin time; a mismatch at integrate time
        /// means the plan changed and the result must be discarded.
        generation: u64,
        /// Marker position this job computes the document for.
        target: u32,
        /// Features `[0..start_pos)` are already baked into `base`.
        start_pos: u32,
        /// Working document: `base` with `[0..target)` applied on success.
        base: Domain.Doc,
        /// Private copy of the feature list with statuses zeroed; statuses in
        /// `[start_pos..target)` are produced by this job.
        features: []Feature,
        applied: u32 = 0,
        state: State = .pending,
        err: ?anyerror = null,
        cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        /// Environment captured at begin time; reaches `Domain.apply` as
        /// `ApplyContext.env`.
        env: ?*anyopaque = null,
        /// Parameter snapshot captured at begin time (owned; names are
        /// borrowed and never read by jobs).
        param_values: []ft.Param = &.{},

        /// Apply features `[start_pos..target)` to `base`. Thread-safe against
        /// `cancel`; touches nothing but this job.
        pub fn run(self: *Self) void {
            self.state = .running;
            while (self.applied < self.target) {
                if (self.cancel_requested.load(.acquire)) {
                    self.state = .cancelled;
                    return;
                }
                var applied: u32 = self.applied;
                ft.rebuild.applyRange(Domain, self.features, self.applied, self.applied + 1, &self.base, self.gpa, self.env, self.param_values, &applied) catch |err| {
                    self.state = .failed;
                    self.err = err;
                    return;
                };
                self.applied = applied;
            }
            self.state = .done;
        }

        /// Request cancellation (any thread). A running `run` stops before the
        /// next feature; a finished one is simply discarded at integrate time.
        pub fn cancel(self: *Self) void {
            self.cancel_requested.store(true, .release);
        }

        /// Free everything this job owns. After `Timeline.integrate` the job
        /// is already consumed; calling this is still safe.
        pub fn deinit(self: *Self) void {
            if (self.state == .consumed) return;
            self.gpa.free(self.param_values);
            for (self.features[@min(self.start_pos, self.features.len)..]) |*f| {
                switch (f.status) {
                    .failed => |msg| self.gpa.free(msg),
                    else => {},
                }
            }
            self.gpa.free(self.features);
            Domain.deinitDoc(&self.base, self.gpa);
            self.state = .consumed;
        }
    };
}

test "applyRange records soft failures and continues" {
    const Domain = struct {
        pub const Doc = struct { value: i64 = 0 };
        pub const Op = union(enum) {
            add: i64,
            fail: []const u8,
        };
        pub fn apply(op: Op, doc: *Doc, ctx: *ft.ApplyContext) anyerror!void {
            switch (op) {
                .add => |n| doc.value += n,
                .fail => |msg| return ctx.fail("{s}", .{msg}),
            }
        }
        pub fn cloneDoc(doc: *const Doc, gpa: std.mem.Allocator) anyerror!Doc {
            _ = gpa;
            return doc.*;
        }
        pub fn deinitDoc(doc: *Doc, gpa: std.mem.Allocator) void {
            _ = doc;
            _ = gpa;
        }
    };

    var features = [_]ft.Feature(Domain.Op){
        .{ .id = 1, .op = .{ .add = 5 } },
        .{ .id = 2, .op = .{ .fail = "no such edge" } },
        .{ .id = 3, .op = .{ .add = 7 } },
        .{ .id = 4, .op = .{ .add = 1 }, .suppressed = true },
    };

    var doc: Domain.Doc = .{};
    var applied: u32 = 0;
    try applyRange(Domain, &features, 0, 4, &doc, std.testing.allocator, null, &.{}, &applied);

    try std.testing.expectEqual(@as(i64, 12), doc.value);
    try std.testing.expectEqual(@as(u32, 4), applied);
    try std.testing.expectEqual(ft.Status.ok, features[0].status);
    try std.testing.expectEqualStrings("no such edge", features[1].status.failed);
    try std.testing.expectEqual(ft.Status.ok, features[2].status);
    try std.testing.expectEqual(ft.Status.suppressed, features[3].status);

    // Failure messages are owned by whoever owns the feature records.
    std.testing.allocator.free(features[1].status.failed);
}
