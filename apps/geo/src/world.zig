//! The editor's state and commands: one globe timeline over any number of
//! region timelines, an app-owned registry so the globe can read regions,
//! a line-oriented command language, and save/load of the whole world.

const std = @import("std");
const ft = @import("featime");
const domains = @import("domains.zig");

pub const Region = domains.Region;
pub const Globe = domains.Globe;
pub const RegionTl = domains.RegionTl;
pub const GlobeTl = domains.GlobeTl;

pub const World = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    /// Where `save DIR` / `load DIR` resolve `DIR` (the cwd, or a temp dir).
    base_dir: std.Io.Dir,
    globe: GlobeTl,
    regions: std.ArrayList(Entry) = .empty,

    const Entry = struct {
        name: []u8,
        /// Heap-allocated: the registry hands out pointers to it.
        tl: *RegionTl,
    };

    pub fn init(gpa: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, base_dir: std.Io.Dir) !World {
        return .{
            .gpa = gpa,
            .io = io,
            .out = out,
            .base_dir = base_dir,
            .globe = try GlobeTl.init(gpa, .{}, .{}),
        };
    }

    /// Point the globe at this world's regions. Call once the World sits at
    /// its final address; `load` calls it again for the new globe.
    pub fn attach(self: *World) void {
        self.globe.setRegistry(.{ .ctx = self, .resolve = &resolve });
    }

    pub fn deinit(self: *World) void {
        self.dropRegions();
        self.regions.deinit(self.gpa);
        self.globe.deinit();
    }

    fn dropRegions(self: *World) void {
        for (self.regions.items) |r| {
            r.tl.deinit();
            self.gpa.destroy(r.tl);
            self.gpa.free(r.name);
        }
        self.regions.clearRetainingCapacity();
    }

    fn resolve(ctx: ?*anyopaque, id: u64) ?ft.LinkHandle {
        const self: *World = @ptrCast(@alignCast(ctx.?));
        for (self.regions.items) |r| {
            if (r.tl.timelineId() == id) return r.tl.linkHandle();
        }
        return null;
    }

    pub fn region(self: *World, name: []const u8) ?*RegionTl {
        for (self.regions.items) |r| {
            if (std.mem.eql(u8, r.name, name)) return r.tl;
        }
        return null;
    }

    fn regionName(self: *const World, id: u64) []const u8 {
        for (self.regions.items) |r| {
            if (r.tl.timelineId() == id) return r.name;
        }
        return "?";
    }

    // ------------------------------------------------------------------
    // Commands
    // ------------------------------------------------------------------

    pub const Error = error{
        UnknownCommand,
        MissingArgument,
        UnknownRegion,
        DuplicateRegion,
        UnknownChapter,
        NoErosionParameter,
        MarkerAtStart,
    };

    /// Run a script: one command per line; blank lines and `#` comments
    /// are skipped; a failing command prints `error: ...` and the script
    /// goes on.
    pub fn runScript(self: *World, text: []const u8) !void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') {
                if (line.len > 1) try self.out.print("{s}\n", .{line});
                continue;
            }
            try self.out.print("> {s}\n", .{line});
            self.command(line) catch |err| try self.out.print("error: {t}\n", .{err});
        }
    }

    pub fn command(self: *World, line: []const u8) !void {
        var it = std.mem.tokenizeScalar(u8, line, ' ');
        const head = it.next() orelse return;
        if (std.mem.eql(u8, head, "region")) return self.regionCommand(&it);
        if (std.mem.eql(u8, head, "globe")) return self.globeCommand(&it);
        if (std.mem.eql(u8, head, "show")) return self.showAll();
        if (std.mem.eql(u8, head, "status")) return self.statusAll();
        if (std.mem.eql(u8, head, "save")) return self.save(it.next() orelse return Error.MissingArgument);
        if (std.mem.eql(u8, head, "load")) return self.load(it.next() orelse return Error.MissingArgument);
        return Error.UnknownCommand;
    }

    const Tokens = std.mem.TokenIterator(u8, .scalar);

    fn regionCommand(self: *World, it: *Tokens) !void {
        const name = it.next() orelse return Error.MissingArgument;
        if (std.mem.eql(u8, name, "new")) return self.newRegion(it.next() orelse return Error.MissingArgument);
        const tl = self.region(name) orelse return Error.UnknownRegion;
        const verb = it.next() orelse return Error.MissingArgument;
        if (std.mem.eql(u8, verb, "raise")) {
            const cell = try std.fmt.parseInt(u8, it.next() orelse return Error.MissingArgument, 10);
            const amount = try std.fmt.parseFloat(f32, it.next() orelse return Error.MissingArgument);
            _ = try tl.commit(.{ .raise = .{ .cell = cell, .amount = amount } });
            try self.out.print("region {s}: raised cell {d} by {d:.1} (feature {d} of {d})\n", .{ name, cell, amount, tl.marker(), tl.len() });
        } else if (std.mem.eql(u8, verb, "plant")) {
            const count = try std.fmt.parseInt(u32, it.next() orelse return Error.MissingArgument, 10);
            _ = try tl.commit(.{ .plant = .{ .count = count } });
            try self.out.print("region {s}: planted {d} (feature {d} of {d})\n", .{ name, count, tl.marker(), tl.len() });
        } else if (std.mem.eql(u8, verb, "erode")) {
            const pid = tl.paramIdByName("erosion") orelse return Error.NoErosionParameter;
            _ = try tl.commit(.{ .erode = .{ .param = pid } });
            try self.out.print("region {s}: erosion pass (feature {d} of {d})\n", .{ name, tl.marker(), tl.len() });
        } else if (std.mem.eql(u8, verb, "param")) {
            const pname = it.next() orelse return Error.MissingArgument;
            const value = try std.fmt.parseFloat(f64, it.next() orelse return Error.MissingArgument);
            if (tl.paramIdByName(pname)) |pid| {
                try tl.setParam(pid, value);
                try self.out.print("region {s}: parameter {s} = {d:.2}\n", .{ name, pname, value });
            } else {
                _ = try tl.addParam(pname, value);
                try self.out.print("region {s}: new parameter {s} = {d:.2}\n", .{ name, pname, value });
            }
        } else if (std.mem.eql(u8, verb, "marker")) {
            const pos = try std.fmt.parseInt(u32, it.next() orelse return Error.MissingArgument, 10);
            tl.setMarker(pos);
            try self.out.print("region {s}: marker at {d} of {d}\n", .{ name, tl.marker(), tl.len() });
        } else if (std.mem.eql(u8, verb, "chapter")) {
            const cname = it.next() orelse return Error.MissingArgument;
            // A chapter marks the gap after the feature before the marker.
            if (tl.marker() == 0) return Error.MarkerAtStart;
            const after = tl.featureAt(tl.marker() - 1).?.id;
            _ = try tl.addChapter(cname, .{ .after = after });
            try self.out.print("region {s}: chapter \"{s}\" after feature {d}\n", .{ name, cname, tl.marker() });
        } else if (std.mem.eql(u8, verb, "terraform")) {
            try tl.beginLabeledTransaction("terraform");
            defer tl.endTransaction();
            _ = try tl.commit(.{ .raise = .{ .cell = 14, .amount = 5 } });
            _ = try tl.commit(.{ .raise = .{ .cell = 15, .amount = 3 } });
            _ = try tl.commit(.{ .raise = .{ .cell = 21, .amount = 2 } });
            _ = try tl.commit(.{ .plant = .{ .count = 2 } });
            try self.out.print("region {s}: terraformed (one undo step, 4 features)\n", .{name});
        } else if (std.mem.eql(u8, verb, "undo")) {
            try self.out.print("region {s}: undo -> {}\n", .{ name, tl.undo() });
        } else if (std.mem.eql(u8, verb, "redo")) {
            try self.out.print("region {s}: redo -> {}\n", .{ name, tl.redo() });
        } else if (std.mem.eql(u8, verb, "history")) {
            try self.showHistory(RegionTl, tl, name);
        } else if (std.mem.eql(u8, verb, "show")) {
            try self.showRegion(name, tl);
        } else if (std.mem.eql(u8, verb, "status")) {
            try self.showStatus(RegionTl, tl, name);
        } else return Error.UnknownCommand;
    }

    fn newRegion(self: *World, name: []const u8) !void {
        if (self.region(name) != null) return Error.DuplicateRegion;
        const tl = try self.gpa.create(RegionTl);
        errdefer self.gpa.destroy(tl);
        tl.* = try RegionTl.init(self.gpa, .{}, .{});
        errdefer tl.deinit();
        const owned = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned);
        try self.regions.append(self.gpa, .{ .name = owned, .tl = tl });
        try self.out.print("region {s}: new timeline {x}\n", .{ name, tl.timelineId() });
    }

    fn globeCommand(self: *World, it: *Tokens) !void {
        const verb = it.next() orelse return Error.MissingArgument;
        const g = &self.globe;
        if (std.mem.eql(u8, verb, "sea")) {
            const meters = try std.fmt.parseFloat(f32, it.next() orelse return Error.MissingArgument);
            _ = try g.commit(.{ .set_sea_level = .{ .meters = meters } });
            try self.out.print("globe: sea level {d:.1} m (feature {d} of {d})\n", .{ meters, g.marker(), g.len() });
        } else if (std.mem.eql(u8, verb, "occur")) {
            const name = it.next() orelse return Error.MissingArgument;
            const tl = self.region(name) orelse return Error.UnknownRegion;
            _ = try g.commit(.{ .occurrence = .{ .region = tl.timelineId() } });
            try self.out.print("globe: live occurrence of {s} (feature {d} of {d})\n", .{ name, g.marker(), g.len() });
        } else if (std.mem.eql(u8, verb, "pin")) {
            const name = it.next() orelse return Error.MissingArgument;
            const tl = self.region(name) orelse return Error.UnknownRegion;
            var after: ?ft.FeatureId = null;
            if (it.next()) |cname| {
                after = (chapterMark(tl, cname) orelse return Error.UnknownChapter).after;
            }
            _ = try g.commit(.{ .occurrence_at = .{ .region = tl.timelineId(), .after = after } });
            try self.out.print("globe: pinned occurrence of {s} at position {d} (feature {d} of {d})\n", .{ name, tl.markPosition(.{ .after = after }), g.marker(), g.len() });
        } else if (std.mem.eql(u8, verb, "marker")) {
            const pos = try std.fmt.parseInt(u32, it.next() orelse return Error.MissingArgument, 10);
            g.setMarker(pos);
            try self.out.print("globe: marker at {d} of {d}\n", .{ g.marker(), g.len() });
        } else if (std.mem.eql(u8, verb, "rebuild")) {
            const mode = it.next() orelse "bg";
            try self.rebuildBackground(std.mem.eql(u8, mode, "bg-stale"));
        } else if (std.mem.eql(u8, verb, "undo")) {
            try self.out.print("globe: undo -> {}\n", .{g.undo()});
        } else if (std.mem.eql(u8, verb, "redo")) {
            try self.out.print("globe: redo -> {}\n", .{g.redo()});
        } else if (std.mem.eql(u8, verb, "history")) {
            try self.showHistory(GlobeTl, g, "globe");
        } else if (std.mem.eql(u8, verb, "show")) {
            try self.showGlobe();
        } else if (std.mem.eql(u8, verb, "status")) {
            try self.showStatus(GlobeTl, g, "globe");
        } else return Error.UnknownCommand;
    }

    /// Rebuild the globe on another thread, then install the result. With
    /// `stale`, a region changes before the result is installed, so the
    /// job is rejected and the next `state()` recomputes.
    fn rebuildBackground(self: *World, stale: bool) !void {
        try self.out.print("globe: dirty before = {}\n", .{self.globe.dirty()});
        var job = try self.globe.beginRebuild();
        const thread = try std.Thread.spawn(.{}, ft.rebuild.Job(Globe).run, .{&job});
        thread.join();
        if (stale and self.regions.items.len > 0) {
            const last = self.regions.items[self.regions.items.len - 1];
            _ = try last.tl.commit(.{ .plant = .{ .count = 1 } });
            try self.out.print("globe: meanwhile region {s} planted 1\n", .{last.name});
        }
        const installed = self.globe.integrate(&job);
        try self.out.print("globe: background rebuild {s}; dirty after = {}\n", .{ if (installed) "installed" else "rejected (a linked timeline moved)", self.globe.dirty() });
    }

    // ------------------------------------------------------------------
    // Display
    // ------------------------------------------------------------------

    fn showAll(self: *World) !void {
        try self.showGlobe();
        for (self.regions.items) |r| try self.showRegion(r.name, r.tl);
    }

    fn showGlobe(self: *World) !void {
        const st = self.globe.state();
        try self.out.print("globe: sea level {d:.1} m, marker {d} of {d}, {d} occurrence(s)\n", .{ st.sea_level, self.globe.marker(), self.globe.len(), st.count });
        for (st.summaries[0..st.count]) |s| {
            try self.out.print("  {s} ({s}): {d} trees, {d}/{d} flooded, peak {d:.1}\n", .{ self.regionName(s.region), if (s.pinned) "pinned" else "live", s.trees, s.flooded, domains.cells, s.peak });
        }
        try self.showFailures(GlobeTl, &self.globe);
    }

    fn showRegion(self: *World, name: []const u8, tl: *RegionTl) !void {
        const st = tl.state();
        try self.out.print("region {s}: marker {d} of {d}, {d} trees, eroded {d}x\n", .{ name, tl.marker(), tl.len(), st.trees, st.eroded });
        for (0..domains.side) |row| {
            try self.out.writeAll("  ");
            for (0..domains.side) |col| {
                const h = st.heights[row * domains.side + col];
                const level: u8 = @intCast(@min(@as(u32, 9), @as(u32, @intFromFloat(h))));
                try self.out.writeByte('0' + level);
            }
            try self.out.writeAll("\n");
        }
        try self.showFailures(RegionTl, tl);
    }

    fn showFailures(self: *World, comptime Tl: type, tl: *const Tl) !void {
        var it = tl.features();
        var failed: u32 = 0;
        var first: ?[]const u8 = null;
        while (it.next()) |f| {
            if (f.status == .failed) {
                failed += 1;
                if (first == null) first = f.status.failed;
            }
        }
        if (failed > 0) try self.out.print("  ! {d} feature(s) failed; first: {s}\n", .{ failed, first.? });
    }

    fn showHistory(self: *World, comptime Tl: type, tl: *const Tl, name: []const u8) !void {
        try self.out.print("{s} history: {d} to undo, {d} to redo\n", .{ name, tl.undoDepth(), tl.redoDepth() });
        var it = tl.history();
        while (it.next()) |u| {
            try self.out.print("  {d}: {t} x{d}", .{ u.index, u.kind, u.entries });
            if (tl.featureById(u.subject)) |f| {
                try self.out.print(" (feature {d}: {t})", .{ positionOf(Tl, tl, f.id), std.meta.activeTag(f.op.*) });
            }
            if (u.label) |l| try self.out.print(" \"{s}\"", .{l});
            if (u.undone) try self.out.writeAll(" (undone)");
            try self.out.writeAll("\n");
        }
    }

    fn showStatus(self: *World, comptime Tl: type, tl: *const Tl, name: []const u8) !void {
        const s = tl.stats();
        try self.out.print("  {s}: dirty={} features={d} marker={d} checkpoints={d} journal={d} undo={d} redo={d} params={d} chapters={d} pins={d}\n", .{ name, tl.dirty(), s.features, s.marker, s.checkpoints, s.journal_entries, s.undo_units, s.redo_units, s.params, s.chapters, s.pins });
    }

    fn statusAll(self: *World) !void {
        try self.out.writeAll("status:\n");
        try self.showStatus(GlobeTl, &self.globe, "globe");
        for (self.regions.items) |r| try self.showStatus(RegionTl, r.tl, r.name);
    }

    // ------------------------------------------------------------------
    // Persistence: one container per timeline, plus a name list
    // ------------------------------------------------------------------

    pub fn save(self: *World, dir_name: []const u8) !void {
        var dir = try self.base_dir.createDirPathOpen(self.io, dir_name, .{});
        defer dir.close(self.io);

        var names: std.Io.Writer.Allocating = .init(self.gpa);
        defer names.deinit();
        for (self.regions.items) |r| try names.writer.print("{s}\n", .{r.name});
        try dir.writeFile(self.io, .{ .sub_path = "world.txt", .data = names.written() });

        for (self.regions.items) |r| {
            const file_name = try std.fmt.allocPrint(self.gpa, "region-{s}.ftz", .{r.name});
            defer self.gpa.free(file_name);
            try self.saveTimeline(Region, r.tl, dir, file_name);
        }
        try self.saveTimeline(Globe, &self.globe, dir, "globe.ftz");
        try self.out.print("saved {d} region(s) and the globe to {s}/\n", .{ self.regions.items.len, dir_name });
    }

    fn saveTimeline(self: *World, comptime D: type, tl: *const ft.Timeline(D), dir: std.Io.Dir, file_name: []const u8) !void {
        var bytes: std.Io.Writer.Allocating = .init(self.gpa);
        defer bytes.deinit();
        try ft.persistence.save(D, tl, self.gpa, &bytes.writer);
        try dir.writeFile(self.io, .{ .sub_path = file_name, .data = bytes.written() });
    }

    /// Replace the world with the one in `dir_name`. The globe's container
    /// header says which regions it needs; they are loaded first, and a
    /// missing one is reported (its occurrences then fail softly).
    pub fn load(self: *World, dir_name: []const u8) !void {
        var dir = try self.base_dir.openDir(self.io, dir_name, .{});
        defer dir.close(self.io);

        const list = try dir.readFileAlloc(self.io, "world.txt", self.gpa, .limited(1 << 16));
        defer self.gpa.free(list);

        var fresh: std.ArrayList(Entry) = .empty;
        errdefer {
            for (fresh.items) |r| {
                r.tl.deinit();
                self.gpa.destroy(r.tl);
                self.gpa.free(r.name);
            }
            fresh.deinit(self.gpa);
        }
        var lines = std.mem.splitScalar(u8, list, '\n');
        while (lines.next()) |raw| {
            const name = std.mem.trim(u8, raw, " \t\r");
            if (name.len == 0) continue;
            const file_name = try std.fmt.allocPrint(self.gpa, "region-{s}.ftz", .{name});
            defer self.gpa.free(file_name);
            const bytes = try dir.readFileAlloc(self.io, file_name, self.gpa, .limited(64 << 20));
            defer self.gpa.free(bytes);
            var reader = std.Io.Reader.fixed(bytes);
            const tl = try self.gpa.create(RegionTl);
            errdefer self.gpa.destroy(tl);
            tl.* = try ft.persistence.load(Region, self.gpa, .{}, &reader);
            errdefer tl.deinit();
            const owned = try self.gpa.dupe(u8, name);
            errdefer self.gpa.free(owned);
            try fresh.append(self.gpa, .{ .name = owned, .tl = tl });
        }

        const globe_bytes = try dir.readFileAlloc(self.io, "globe.ftz", self.gpa, .limited(64 << 20));
        defer self.gpa.free(globe_bytes);
        var head_reader = std.Io.Reader.fixed(globe_bytes);
        var header = try ft.persistence.peekHeader(self.gpa, &head_reader);
        defer header.deinit(self.gpa);
        for (header.links) |id| {
            var found = false;
            for (fresh.items) |r| {
                if (r.tl.timelineId() == id) found = true;
            }
            try self.out.print("globe needs region {x}: {s}\n", .{ id, if (found) "found" else "missing" });
        }
        var reader = std.Io.Reader.fixed(globe_bytes);
        var globe = try ft.persistence.load(Globe, self.gpa, .{}, &reader);
        errdefer globe.deinit();

        // Everything loaded: swap the world.
        self.dropRegions();
        self.regions.deinit(self.gpa);
        self.regions = fresh;
        self.globe.deinit();
        self.globe = globe;
        self.attach();
        try self.out.print("loaded {d} region(s) and the globe from {s}/\n", .{ self.regions.items.len, dir_name });
    }
};

/// 1-based position of a feature, for display.
fn positionOf(comptime Tl: type, tl: *const Tl, id: ft.FeatureId) u32 {
    var it = tl.features();
    var i: u32 = 1;
    while (it.next()) |f| : (i += 1) {
        if (f.id == id) return i;
    }
    return 0;
}

fn chapterMark(tl: *const RegionTl, name: []const u8) ?ft.Mark {
    for (tl.chapters()) |c| {
        if (std.mem.eql(u8, c.name, name)) return c.mark;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

pub const tour = @embedFile("tour.txt");

fn summary(world: *World, name: []const u8, pinned: bool) ?Globe.Summary {
    const id = (world.region(name) orelse return null).timelineId();
    const st = world.globe.state();
    for (st.summaries[0..st.count]) |s| {
        if (s.region == id and s.pinned == pinned) return s;
    }
    return null;
}

test "the tour runs without errors and ends in the expected state" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var world = try World.init(gpa, std.testing.io, &aw.writer, tmp.dir);
    defer world.deinit();
    world.attach();

    try world.runScript(tour);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\nerror:") == null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "rejected (a linked timeline moved)") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "background rebuild installed") != null);

    // The pinned occurrence of north stays at the chapter: 9 trees. The
    // live one follows the region: 12 trees after the later planting.
    try std.testing.expectEqual(@as(u32, 9), summary(&world, "north", true).?.trees);
    try std.testing.expectEqual(@as(u32, 12), summary(&world, "north", false).?.trees);
    try std.testing.expect(!world.globe.dirty());
    try std.testing.expectEqual(@as(usize, 2), world.regions.items.len);
}

test "save and load reproduce the world" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var world = try World.init(gpa, std.testing.io, &aw.writer, tmp.dir);
    defer world.deinit();
    world.attach();

    try world.runScript(
        \\region new west
        \\region west raise 1 3
        \\region west plant 4
        \\region west chapter base
        \\region west raise 2 2
        \\globe sea 1.0
        \\globe occur west
        \\globe pin west base
        \\save w
    );
    const before_live = summary(&world, "west", false).?;
    const before_pinned = summary(&world, "west", true).?;

    try world.runScript("load w");
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), ": found") != null);
    try std.testing.expect(std.mem.indexOf(u8, aw.written(), "\nerror:") == null);
    const after_live = summary(&world, "west", false).?;
    const after_pinned = summary(&world, "west", true).?;
    try std.testing.expectEqual(before_live.trees, after_live.trees);
    try std.testing.expectEqual(before_live.flooded, after_live.flooded);
    try std.testing.expectEqual(before_pinned.trees, after_pinned.trees);
    try std.testing.expectEqual(before_pinned.peak, after_pinned.peak);

    // The loaded world keeps working: a region edit reaches the live occurrence.
    try world.runScript("region west plant 1");
    try std.testing.expectEqual(before_live.trees + 1, summary(&world, "west", false).?.trees);
    try std.testing.expectEqual(before_pinned.trees, summary(&world, "west", true).?.trees);
}
