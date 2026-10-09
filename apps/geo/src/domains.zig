//! The two Domains of the geo editor: a region (a small height grid with
//! trees) and a globe that summarizes regions through occurrences.

const std = @import("std");
const ft = @import("featime");

pub const side: u8 = 6;
pub const cells: usize = @as(usize, side) * side;
pub const max_regions: usize = 8;

pub const Region = struct {
    pub const format_version: u32 = 1;

    pub const Doc = struct {
        heights: [cells]f32 = @splat(0),
        trees: u32 = 0,
        /// Erosion passes applied so far (display only).
        eroded: u32 = 0,
    };

    pub const Op = union(enum) {
        raise: struct { cell: u8, amount: f32 },
        plant: struct { count: u32 },
        /// Lower every cell by the parameter's value, down to 0.
        erode: struct { param: ft.ParamId },
    };

    pub fn apply(op: Op, doc: *Doc, ctx: *ft.ApplyContext) anyerror!void {
        switch (op) {
            .raise => |r| {
                if (r.cell >= cells) return ctx.fail("cell {d} is off the grid", .{r.cell});
                doc.heights[r.cell] += r.amount;
            },
            .plant => |p| {
                if (doc.trees + p.count > cells)
                    return ctx.fail("overplanted: {d} trees on {d} cells", .{ doc.trees + p.count, cells });
                doc.trees += p.count;
            },
            .erode => |e| {
                const amount = ctx.param(e.param) orelse return ctx.fail("parameter {d} is gone", .{e.param});
                const step: f32 = @floatCast(amount);
                for (&doc.heights) |*h| h.* = @max(0, h.* - step);
                doc.eroded += 1;
            },
        }
    }

    pub fn references(op: Op, out: *ft.ParamRefCollector) void {
        switch (op) {
            .erode => |e| out.param(e.param),
            else => {},
        }
    }

    pub fn encodeOp(op: Op, w: *std.Io.Writer) anyerror!void {
        switch (op) {
            .raise => |r| {
                try w.writeByte(1);
                try w.writeByte(r.cell);
                try w.writeInt(u32, @bitCast(r.amount), .little);
            },
            .plant => |p| {
                try w.writeByte(2);
                try w.writeInt(u32, p.count, .little);
            },
            .erode => |e| {
                try w.writeByte(3);
                try w.writeInt(u64, e.param, .little);
            },
        }
    }

    pub fn decodeOp(r: *std.Io.Reader, gpa: std.mem.Allocator) anyerror!Op {
        _ = gpa;
        return switch (try r.takeByte()) {
            1 => .{ .raise = .{ .cell = try r.takeByte(), .amount = @bitCast(try r.takeInt(u32, .little)) } },
            2 => .{ .plant = .{ .count = try r.takeInt(u32, .little) } },
            3 => .{ .erode = .{ .param = try r.takeInt(u64, .little) } },
            else => error.Malformed,
        };
    }

    pub fn encodeDoc(doc: *const Doc, w: *std.Io.Writer) anyerror!void {
        for (doc.heights) |h| try w.writeInt(u32, @bitCast(h), .little);
        try w.writeInt(u32, doc.trees, .little);
        try w.writeInt(u32, doc.eroded, .little);
    }

    pub fn decodeDoc(r: *std.Io.Reader, gpa: std.mem.Allocator) anyerror!Doc {
        _ = gpa;
        var doc: Doc = .{};
        for (&doc.heights) |*h| h.* = @bitCast(try r.takeInt(u32, .little));
        doc.trees = try r.takeInt(u32, .little);
        doc.eroded = try r.takeInt(u32, .little);
        return doc;
    }
};

pub const RegionTl = ft.Timeline(Region);

pub const Globe = struct {
    pub const format_version: u32 = 1;

    /// What the globe keeps of a region: a summary, not its ops.
    pub const Summary = struct {
        region: u64 = 0,
        pinned: bool = false,
        trees: u32 = 0,
        flooded: u32 = 0,
        peak: f32 = 0,
    };

    pub const Doc = struct {
        sea_level: f32 = 0,
        summaries: [max_regions]Summary = @splat(.{}),
        count: u8 = 0,
    };

    pub const Op = union(enum) {
        set_sea_level: struct { meters: f32 },
        /// A live occurrence: reads the region at the region's own marker.
        occurrence: struct { region: u64 },
        /// A pinned occurrence: reads the region right after feature
        /// `after` (null: the region's tip), whatever its marker says.
        occurrence_at: struct { region: u64, after: ?ft.FeatureId },
    };

    pub fn apply(op: Op, doc: *Doc, ctx: *ft.ApplyContext) anyerror!void {
        switch (op) {
            .set_sea_level => |s| {
                doc.sea_level = s.meters;
                // Flooding depends on the sea level: refresh every summary
                // from its stored peak is not enough, so occurrences after
                // this feature recompute; earlier ones keep their counts.
            },
            .occurrence => |o| {
                const region: *RegionTl = @ptrCast(@alignCast(ctx.link(o.region) orelse
                    return ctx.fail("region {x} is not registered, or is in a reference cycle", .{o.region})));
                try upsert(doc, o.region, false, region.state(), ctx);
            },
            .occurrence_at => |o| {
                const mark: ft.Mark = .{ .after = o.after };
                const region: *RegionTl = @ptrCast(@alignCast(ctx.linkAt(o.region, mark) orelse
                    return ctx.fail("region {x} is not registered, or the pin is a cycle", .{o.region})));
                var view = try region.viewAtMark(mark);
                defer region.freeView(&view);
                try upsert(doc, o.region, true, &view, ctx);
            },
        }
    }

    fn upsert(doc: *Doc, region: u64, pinned: bool, st: *const Region.Doc, ctx: *ft.ApplyContext) anyerror!void {
        var flooded: u32 = 0;
        var peak: f32 = 0;
        for (st.heights) |h| {
            if (h < doc.sea_level) flooded += 1;
            if (h > peak) peak = h;
        }
        const summary: Summary = .{ .region = region, .pinned = pinned, .trees = st.trees, .flooded = flooded, .peak = peak };
        for (doc.summaries[0..doc.count]) |*s| {
            if (s.region == region and s.pinned == pinned) {
                s.* = summary;
                return;
            }
        }
        if (doc.count == max_regions) return ctx.fail("the globe holds at most {d} occurrences", .{max_regions});
        doc.summaries[doc.count] = summary;
        doc.count += 1;
    }

    pub fn links(op: Op, out: *ft.LinkCollector) void {
        switch (op) {
            .occurrence => |o| out.link(o.region),
            .occurrence_at => |o| out.pin(o.region, .{ .after = o.after }),
            .set_sea_level => {},
        }
    }

    pub fn encodeOp(op: Op, w: *std.Io.Writer) anyerror!void {
        switch (op) {
            .set_sea_level => |s| {
                try w.writeByte(1);
                try w.writeInt(u32, @bitCast(s.meters), .little);
            },
            .occurrence => |o| {
                try w.writeByte(2);
                try w.writeInt(u64, o.region, .little);
            },
            .occurrence_at => |o| {
                try w.writeByte(3);
                try w.writeInt(u64, o.region, .little);
                try w.writeInt(u64, o.after orelse 0, .little);
            },
        }
    }

    pub fn decodeOp(r: *std.Io.Reader, gpa: std.mem.Allocator) anyerror!Op {
        _ = gpa;
        return switch (try r.takeByte()) {
            1 => .{ .set_sea_level = .{ .meters = @bitCast(try r.takeInt(u32, .little)) } },
            2 => .{ .occurrence = .{ .region = try r.takeInt(u64, .little) } },
            3 => blk: {
                const region = try r.takeInt(u64, .little);
                const after = try r.takeInt(u64, .little);
                break :blk .{ .occurrence_at = .{ .region = region, .after = if (after == 0) null else after } };
            },
            else => error.Malformed,
        };
    }

    pub fn encodeDoc(doc: *const Doc, w: *std.Io.Writer) anyerror!void {
        try w.writeInt(u32, @bitCast(doc.sea_level), .little);
        try w.writeByte(doc.count);
        for (doc.summaries[0..doc.count]) |s| {
            try w.writeInt(u64, s.region, .little);
            try w.writeByte(@intFromBool(s.pinned));
            try w.writeInt(u32, s.trees, .little);
            try w.writeInt(u32, s.flooded, .little);
            try w.writeInt(u32, @bitCast(s.peak), .little);
        }
    }

    pub fn decodeDoc(r: *std.Io.Reader, gpa: std.mem.Allocator) anyerror!Doc {
        _ = gpa;
        var doc: Doc = .{};
        doc.sea_level = @bitCast(try r.takeInt(u32, .little));
        const count = try r.takeByte();
        if (count > max_regions) return error.Malformed;
        doc.count = count;
        for (doc.summaries[0..count]) |*s| {
            s.region = try r.takeInt(u64, .little);
            s.pinned = (try r.takeByte()) != 0;
            s.trees = try r.takeInt(u32, .little);
            s.flooded = try r.takeInt(u32, .little);
            s.peak = @bitCast(try r.takeInt(u32, .little));
        }
        return doc;
    }
};

pub const GlobeTl = ft.Timeline(Globe);
