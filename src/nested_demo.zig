//! Two-level demo: a globe feature timeline referencing a region
//! sub-timeline — Fusion's assembly/component model on top of the library's
//! link support (`Domain.links`, `setRegistry`, `ctx.link`).
//!
//! The region timeline is an ordinary `Timeline` over its own document; the
//! globe timeline's occurrence features read the region's *computed state*
//! (at the region's own marker) through the registry. The library records
//! which version of the region each occurrence read, so when the region
//! changes the globe re-runs the occurrence by itself on its next `state()`.

const std = @import("std");
const Io = std.Io;
const ft = @import("featime");

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
};

const RegionTimeline = ft.Timeline(Region);

/// The application's registry: which timelines exist, by id. The globe's
/// occurrences name the region by its `timelineId()`; the library asks the
/// registry for a handle and tracks the region's version by itself.
const Registry = struct {
    region: *RegionTimeline,

    fn resolve(ctx: ?*anyopaque, id: u64) ?ft.LinkHandle {
        const self: *Registry = @ptrCast(@alignCast(ctx.?));
        if (id == self.region.timelineId()) return self.region.linkHandle();
        return null;
    }

    fn registry(self: *Registry) ft.Registry {
        return .{ .ctx = self, .resolve = &resolve };
    }
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
        /// A component occurrence, in Fusion terms: `region` is the region
        /// timeline's id. Reads the region at the region's own marker.
        region_occurrence: struct { region: u64 },
        /// A pinned occurrence: reads the region as it is right after the
        /// feature `after` (a mark), whatever the region's marker says.
        region_at: struct { region: u64, after: ?ft.FeatureId },
    };
    pub fn apply(op: Op, doc: *Doc, ctx: *ft.ApplyContext) anyerror!void {
        switch (op) {
            .set_sea_level => |s| doc.sea_level = s.meters,
            .region_occurrence => |o| {
                const region: *RegionTimeline = @ptrCast(@alignCast(ctx.link(o.region) orelse
                    return ctx.fail("region {d} is not registered, or is in a reference cycle", .{o.region})));
                mergeRegion(doc, region.state());
            },
            .region_at => |o| {
                const region: *RegionTimeline = @ptrCast(@alignCast(ctx.linkAt(o.region, .{ .after = o.after }) orelse
                    return ctx.fail("region {d} is not registered, or is in a reference cycle", .{o.region})));
                var view = try region.viewAtMark(.{ .after = o.after });
                defer region.freeView(&view);
                mergeRegion(doc, &view);
            },
        }
    }
    fn mergeRegion(doc: *Doc, region_state: *const Region.Doc) void {
        doc.region_heights = region_state.heights;
        doc.region_trees = region_state.trees;
        doc.flooded = 0;
        for (doc.region_heights) |h| {
            if (h < doc.sea_level) doc.flooded += 1;
        }
    }
    /// Which timelines an op reads: the library re-runs the feature when
    /// one of them changes. A pinned read ignores the region's marker.
    pub fn links(op: Op, out: *ft.LinkCollector) void {
        switch (op) {
            .region_occurrence => |o| out.link(o.region),
            .region_at => |o| out.pin(o.region, .{ .after = o.after }),
            .set_sea_level => {},
        }
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

    var registry = Registry{ .region = &region };
    globe.setRegistry(registry.registry());

    // 1. Edit the region sub-timeline on its own.
    try out.writeAll("\n-- 1. region: raise and plant -------------------------------\n");
    _ = try region.commit(.{ .raise = .{ .cell = 5, .amount = 4 } });
    _ = try region.commit(.{ .raise = .{ .cell = 6, .amount = 2 } });
    const planted = try region.commit(.{ .plant = .{ .count = 9 } });
    _ = region.state();
    try printRegion(out, &region);

    // 2. The globe references the region through an occurrence feature.
    try out.writeAll("\n-- 2. globe: sea level + region occurrence ------------------\n");
    _ = try globe.commit(.{ .set_sea_level = .{ .meters = 2.0 } });
    const occurrence = try globe.commit(.{ .region_occurrence = .{ .region = region.timelineId() } });
    try printGlobe(out, &globe);

    // 3. Region edits flow on their own: the globe sees that the region's
    //    version moved and re-runs the occurrence on its next state().
    try out.writeAll("\n-- 3. region raises a hill; globe follows -------------------\n");
    _ = try region.commit(.{ .raise = .{ .cell = 0, .amount = 3 } });
    try out.print("  globe dirty: {}\n", .{globe.dirty()});
    try printGlobe(out, &globe); // flooded drops: cell 0 is now above sea level

    // 4. Cross-timeline skew is intended Fusion semantics: scrubbing the
    //    region's marker changes what the occurrence reads.
    try out.writeAll("\n-- 4. region scrubbed back before planting; globe follows ----\n");
    region.setMarker(2);
    try printRegion(out, &region);
    try printGlobe(out, &globe); // trees drop to 0

    // 5. Rolling the GLOBE back past the occurrence leaves the region
    //    timeline entirely untouched (intended skew).
    try out.writeAll("\n-- 5. globe marker back to 1: occurrence not applied --------\n");
    globe.setMarker(1);
    try printGlobe(out, &globe);
    try printRegion(out, &region);

    // 6. A pinned occurrence reads the region as it was right after the
    //    planting, whatever the region's marker says: the region is scrubbed
    //    back to 2 right now, and the globe is not even dirty when it moves.
    try out.writeAll("\n-- 6. pinned occurrence: the region right after planting ----\n");
    globe.setMarker(globe.len());
    try globe.setSuppressed(occurrence, true);
    _ = try globe.commit(.{ .region_at = .{ .region = region.timelineId(), .after = planted } });
    try printGlobe(out, &globe); // 9 trees although the region's marker is at 2
    region.setMarker(1);
    try out.print("  globe dirty after a region scrub: {}\n", .{globe.dirty()});
    try printGlobe(out, &globe);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "occurrence follows region edits and scrubs without refresh" {
    const gpa = std.testing.allocator;
    var region = try RegionTimeline.init(gpa, .{}, .{});
    defer region.deinit();
    var globe = try GlobeTimeline.init(gpa, .{}, .{});
    defer globe.deinit();

    var registry = Registry{ .region = &region };
    globe.setRegistry(registry.registry());

    _ = try region.commit(.{ .plant = .{ .count = 3 } });
    _ = try globe.commit(.{ .set_sea_level = .{ .meters = 1.0 } });
    const occurrence = try globe.commit(.{ .region_occurrence = .{ .region = region.timelineId() } });
    try std.testing.expectEqual(@as(u32, 3), globe.state().region_trees);
    try std.testing.expect(!globe.dirty());

    // A region change makes the globe dirty; its next state() re-runs the occurrence.
    _ = try region.commit(.{ .plant = .{ .count = 4 } });
    try std.testing.expect(globe.dirty());
    try std.testing.expectEqual(@as(u32, 7), globe.state().region_trees);

    // Scrubbing the region marker changes what the occurrence reads: at
    // marker 1 only the first planting (3 trees) is applied.
    region.setMarker(1);
    try std.testing.expectEqual(@as(u32, 3), globe.state().region_trees);

    // Suppressing the occurrence removes the merge entirely.
    region.setMarker(region.len());
    try std.testing.expectEqual(@as(u32, 7), globe.state().region_trees);
    try globe.setSuppressed(occurrence, true);
    try std.testing.expectEqual(@as(u32, 0), globe.state().region_trees);
    try std.testing.expectEqual(@as(u32, 0), globe.state().flooded);
}

test "occurrence fails softly without a registry" {
    const gpa = std.testing.allocator;
    var globe = try GlobeTimeline.init(gpa, .{}, .{});
    defer globe.deinit();

    _ = try globe.commit(.{ .region_occurrence = .{ .region = 42 } });
    _ = globe.state();
    var it = globe.features();
    const f = it.next().?;
    try std.testing.expectEqualStrings("region 42 is not registered, or is in a reference cycle", f.status.failed);
}

test "a pinned occurrence ignores the region's marker and follows its edits" {
    const gpa = std.testing.allocator;
    var region = try RegionTimeline.init(gpa, .{}, .{});
    defer region.deinit();
    var globe = try GlobeTimeline.init(gpa, .{}, .{});
    defer globe.deinit();
    var registry = Registry{ .region = &region };
    globe.setRegistry(registry.registry());

    const planted = try region.commit(.{ .plant = .{ .count = 3 } });
    const live = try globe.commit(.{ .region_occurrence = .{ .region = region.timelineId() } });
    _ = try globe.commit(.{ .region_at = .{ .region = region.timelineId(), .after = planted } });
    try std.testing.expectEqual(@as(u32, 3), globe.state().region_trees);

    // With the live occurrence suppressed, only the pinned one reads the region.
    try globe.setSuppressed(live, true);
    try std.testing.expectEqual(@as(u32, 3), globe.state().region_trees);
    region.setMarker(0);
    try std.testing.expect(!globe.dirty());
    try std.testing.expectEqual(@as(u32, 3), globe.state().region_trees);

    // A planting inserted before the mark's feature is part of the view.
    _ = try region.commit(.{ .plant = .{ .count = 2 } });
    try std.testing.expect(globe.dirty());
    try std.testing.expectEqual(@as(u32, 5), globe.state().region_trees);
}
