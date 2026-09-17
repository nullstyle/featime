//! M1 demo: a scripted walk through the feature-history slider semantics on
//! a trivial document (a running total). Exercises commit, marker scrubbing,
//! mid-history insertion, suppression, and soft failure — printing the
//! timeline and state at each step.

const std = @import("std");
const Io = std.Io;
const ft = @import("featuretree_zig");

const Ledger = struct {
    pub const Doc = struct {
        value: i64 = 0,
    };
    pub const Op = union(enum) {
        add: i64,
        mul: i64,
        fail: []const u8,
    };
    pub fn apply(op: Op, doc: *Doc, ctx: *ft.ApplyContext) anyerror!void {
        switch (op) {
            .add => |n| doc.value += n,
            .mul => |n| doc.value *= n,
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

const App = struct {
    out: *Io.Writer,
    tl: ft.Timeline(Ledger),

    fn show(self: *App, label: []const u8) !void {
        _ = self.tl.state(); // force the rebuild so statuses are fresh
        try self.out.print("{s:<24} ", .{label});

        // The slider: [op][op]|op][op]  — features left of | are applied.
        var it = self.tl.features();
        var idx: u32 = 0;
        try self.out.writeAll("[");
        while (it.next()) |f| : (idx += 1) {
            if (idx > 0) try self.out.writeAll(" ");
            const applied = idx < self.tl.marker();
            const badge: u8 = switch (f.status) {
                .ok => if (f.suppressed) 's' else switch (f.op.*) {
                    .add => '+',
                    .mul => '*',
                    .fail => '!',
                },
                .suppressed => 's',
                .failed => 'x',
                .pending => '.',
            };
            _ = applied;
            try self.out.writeByte(if (idx == self.tl.marker()) '|' else badge);
        }
        if (idx == self.tl.marker()) try self.out.writeAll("|");
        try self.out.print("]  value={d}", .{self.tl.state().value});

        var it2 = self.tl.features();
        while (it2.next()) |f| {
            if (f.status == .failed) try self.out.print("  (failed: {s})", .{f.status.failed});
        }
        try self.out.writeAll("\n");
    }
};

pub fn main(init: std.process.Init) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    var app = App{
        .out = out,
        .tl = try ft.Timeline(Ledger).init(arena, .{}, .{}),
    };
    defer app.tl.deinit();

    try app.show("seed");
    _ = try app.tl.commit(.{ .add = 10 });
    try app.show("commit add(10)");
    const scale = try app.tl.commit(.{ .mul = 2 });
    try app.show("commit mul(2)");
    const bad = try app.tl.commit(.{ .fail = "edge 7 no longer exists" });
    try app.show("commit fail");
    _ = try app.tl.commit(.{ .add = 5 });
    try app.show("commit add(5)");

    try out.writeAll("\n-- scrub the history slider --\n");
    app.tl.setMarker(2);
    try app.show("setMarker(2)");
    app.tl.setMarker(1);
    try app.show("setMarker(1)");

    try out.writeAll("\n-- rolled back: commits insert mid-history --\n");
    _ = try app.tl.commit(.{ .mul = 3 });
    try app.show("commit mul(3) at 1");
    app.tl.setMarker(app.tl.len());
    try app.show("roll to end");

    try out.writeAll("\n-- suppress the mul(2) feature --\n");
    app.tl.setSuppressed(scale, true);
    try app.show("suppress mul(2)");
    app.tl.setSuppressed(bad, true);
    try app.show("suppress fail too");

    try out.flush();
}

test "demo smoke: mid-history insert changes the final state" {
    const gpa = std.testing.allocator;
    var tl = try ft.Timeline(Ledger).init(gpa, .{}, .{});
    defer tl.deinit();

    _ = try tl.commit(.{ .add = 10 });
    _ = try tl.commit(.{ .mul = 2 });
    tl.setMarker(1);
    _ = try tl.commit(.{ .mul = 3 });
    tl.setMarker(tl.len());
    try std.testing.expectEqual(@as(i64, (10 * 3) * 2), tl.state().value);
}
