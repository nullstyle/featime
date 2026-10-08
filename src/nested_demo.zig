//! Two-level demo: a globe feature timeline referencing a region
//! sub-timeline — Fusion's assembly/component model on top of the library's
//! seams, with no special library support beyond `setEnv` and `refresh`.
//!
//! The region timeline is an ordinary `Timeline` over its own document; the
//! globe timeline's occurrence features read the region's *computed state*
//! (at the region's own marker) through the environment. When the region
//! changes, the globe is stale until the app calls `refresh` on the
//! occurrence — deliberately: the library cannot see external inputs, so
//! invalidation is explicit.

const std = @import("std");
const Io = std.Io;
const ft = @import("featuretree_zig");

const side: u8 = 4;
const cells: usize = @as(usize, side) * side;

// ---------------------------------------------------------------------------
// The region sub-timeline: an ordinary Domain.
// ---------------------------------------------------------------------------

const Region = struct {
    pub const Doc = struct {
        heights: [cells]f32 = @splat(0),
        trees: u32 = 0,
    };
    pub const Op = union(enum) {
        raise: struct { cell: u8, amount: f32 },
        plant: struct { count: u32 },
    };
    pub fn apply(op: Op, doc: *Doc, ctx: *ft.ApplyContext) anyerror!void {
        switch (op) {
            .raise => |r| {
                if (r.cell >= cells)
                    return ctx.fail("cell {d} is off this region", .{r.cell});
                doc.heights[r.cell] += r.amount;
            },
            .plant => |p| {
                if (doc.trees + p.count > cells)
                    return ctx.fail("region is overplanted", .{});
                doc.trees += p.count;
            },
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

const RegionTimeline = ft.Timeline(Region);

/// The application environment: the registry of sub-timelines the globe's
/// features read through `ctx.env`. Must be acyclic — sub-timelines never
/// point back at the globe.
const Env = struct {
    region: *RegionTimeline,
};

// ---------------------------------------------------------------------------
// The globe timeline: occurrence features merge region state.
// ---------------------------------------------------------------------------

const Globe = struct {
    pub const Doc = struct {
        sea_level: f32 = 0,
        // Computed-state merge: the globe stores what the region looked like
        // when the occurrence last applied, not the region's ops.
        region_heights: [cells]f32 = @splat(0),
        region_trees: u32 = 0,
        flooded: u32 = 0,
    };
    pub const Op = union(enum) {
        set_sea_level: struct { meters: f32 },
        /// A component occurrence, in Fusion terms.
        region_occurrence: struct { region: u8 },
    };
    pub fn apply(op: Op, doc: *Doc, ctx: *ft.ApplyContext) anyerror!void {
        switch (op) {
            .set_sea_level => |s| doc.sea_level = s.meters,
            .region_occurrence => |o| {
                if (o.region != 0)
                    return ctx.fail("unknown region {d}", .{o.region});
                const env: *Env = @ptrCast(@alignCast(ctx.env orelse
                    return ctx.fail("no environment registered", .{})));
                const region_state = env.region.state();
                doc.region_heights = region_state.heights;
                doc.region_trees = region_state.trees;
                doc.flooded = 0;
                for (doc.region_heights) |h| {
                    if (h < doc.sea_level) doc.flooded += 1;
                }
            },
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

const GlobeTimeline = ft.Timeline(Globe);

fn printRegion(out: *Io.Writer, tl: *RegionTimeline) !void {
    const st = tl.state();
    for (0..side) |row| {
        try out.writeAll("  ");
        for (0..side) |col| {
            const h = st.heights[row * side + col];
            const level: u8 = @intCast(@min(@as(u32, 9), @as(u32, @intFromFloat(h))));
            try out.writeByte('0' + level);
        }
        try out.writeAll("\n");
    }
    try out.print("  region: {d} trees, marker {d}/{d}\n", .{ st.trees, tl.marker(), tl.len() });
}

fn printGlobe(out: *Io.Writer, tl: *GlobeTimeline) !void {
    const st = tl.state();
    try out.print(
        "  globe:  sea level {d:.1}, region trees {d}, flooded cells {d}/16\n",
        .{ st.sea_level, st.region_trees, st.flooded },
    );
}

pub fn run(out: *Io.Writer, arena: std.mem.Allocator) !void {
    var region = try RegionTimeline.init(arena, .{}, .{ .checkpoint_on_scrub = true });
    defer region.deinit();
    var globe = try GlobeTimeline.init(arena, .{}, .{});
    defer globe.deinit();

    var env = Env{ .region = &region };
    globe.setEnv(&env);

    // 1. Edit the region sub-timeline on its own.
    try out.writeAll("\n-- 1. region: raise and plant -------------------------------\n");
    _ = try region.commit(.{ .raise = .{ .cell = 5, .amount = 4 } });
    _ = try region.commit(.{ .raise = .{ .cell = 6, .amount = 2 } });
    _ = try region.commit(.{ .plant = .{ .count = 9 } });
    _ = region.state();
    try printRegion(out, &region);

    // 2. The globe references the region through an occurrence feature.
    try out.writeAll("\n-- 2. globe: sea level + region occurrence ------------------\n");
    _ = try globe.commit(.{ .set_sea_level = .{ .meters = 2.0 } });
    const occurrence = try globe.commit(.{ .region_occurrence = .{ .region = 0 } });
    try printGlobe(out, &globe);

    // 3. Region edits do NOT flow automatically: the globe is stale until
    //    the app refreshes the occurrence.
    try out.writeAll("\n-- 3. region raises a hill; globe stale, then refreshed ------\n");
    _ = try region.commit(.{ .raise = .{ .cell = 0, .amount = 3 } });
    try printGlobe(out, &globe); // still the old merge: cell 0 still flooded
    try globe.refresh(occurrence);
    try printGlobe(out, &globe); // flooded drops: cell 0 is now above sea level

    // 4. Cross-timeline skew is intended Fusion semantics: scrubbing the
    //    region's marker changes what the occurrence reads.
    try out.writeAll("\n-- 4. region scrubbed back before planting; refresh ----------\n");
    region.setMarker(2);
    try printRegion(out, &region);
    try globe.refresh(occurrence);
    try printGlobe(out, &globe); // trees drop to 0

    // 5. Rolling the GLOBE back past the occurrence leaves the region
    //    timeline entirely untouched (intended skew).
    try out.writeAll("\n-- 5. globe marker back to 1: occurrence not applied --------\n");
    globe.setMarker(1);
    try printGlobe(out, &globe);
    try printRegion(out, &region);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "occurrence merges region state; refresh picks up changes" {
    const gpa = std.testing.allocator;
    var region = try RegionTimeline.init(gpa, .{}, .{});
    defer region.deinit();
    var globe = try GlobeTimeline.init(gpa, .{}, .{});
    defer globe.deinit();

    var env = Env{ .region = &region };
    globe.setEnv(&env);

    _ = try region.commit(.{ .plant = .{ .count = 3 } });
    _ = try globe.commit(.{ .set_sea_level = .{ .meters = 1.0 } });
    const occurrence = try globe.commit(.{ .region_occurrence = .{ .region = 0 } });
    try std.testing.expectEqual(@as(u32, 3), globe.state().region_trees);

    // Region changes alone leave the globe stale.
    _ = try region.commit(.{ .plant = .{ .count = 4 } });
    try std.testing.expectEqual(@as(u32, 3), globe.state().region_trees);

    // Refresh re-runs the occurrence.
    try globe.refresh(occurrence);
    try std.testing.expectEqual(@as(u32, 7), globe.state().region_trees);

    // Scrubbing the region marker changes what the occurrence reads: at
    // marker 1 only the first planting (3 trees) is applied.
    region.setMarker(1);
    try globe.refresh(occurrence);
    try std.testing.expectEqual(@as(u32, 3), globe.state().region_trees);

    // Suppressing the occurrence removes the merge entirely.
    region.setMarker(region.len());
    try globe.refresh(occurrence);
    try globe.setSuppressed(occurrence, true);
    try std.testing.expectEqual(@as(u32, 0), globe.state().region_trees);
    try std.testing.expectEqual(@as(u32, 0), globe.state().flooded);
}

test "occurrence fails softly without an environment" {
    const gpa = std.testing.allocator;
    var globe = try GlobeTimeline.init(gpa, .{}, .{});
    defer globe.deinit();

    _ = try globe.commit(.{ .region_occurrence = .{ .region = 0 } });
    _ = globe.state();
    var it = globe.features();
    const f = it.next().?;
    try std.testing.expectEqualStrings("no environment registered", f.status.failed);
}
