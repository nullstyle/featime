//! The pure rebuild core: apply a range of features to a document, recording
//! per-feature status. Shared by the synchronous path (`Timeline.state()`)
//! and the background-rebuild path, which is why it touches nothing but its
//! arguments.

const std = @import("std");
const ft = @import("root.zig");

/// Applies `features[from..to]` to `doc`, writing each feature's status.
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
        var ctx: ft.ApplyContext = .{ .alloc = gpa, .feature_id = feature.id };
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
    try applyRange(Domain, &features, 0, 4, &doc, std.testing.allocator, &applied);

    try std.testing.expectEqual(@as(i64, 12), doc.value);
    try std.testing.expectEqual(@as(u32, 4), applied);
    try std.testing.expectEqual(ft.Status.ok, features[0].status);
    try std.testing.expectEqualStrings("no such edge", features[1].status.failed);
    try std.testing.expectEqual(ft.Status.ok, features[2].status);
    try std.testing.expectEqual(ft.Status.suppressed, features[3].status);

    // Failure messages are owned by whoever owns the feature records.
    std.testing.allocator.free(features[1].status.failed);
}
