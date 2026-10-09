//! featime-geo: run the tour, or a script given on the command line.

const std = @import("std");
const world = @import("world.zig");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var out_buffer: [8192]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), io, &out_buffer);
    const out = &file_writer.interface;
    defer out.flush() catch {};

    // `iterateAllocator` works on every target; plain `iterate` refuses Windows.
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    _ = args.next();
    const cwd = std.Io.Dir.cwd();
    var script: []const u8 = world.tour;
    var owned: ?[]u8 = null;
    defer if (owned) |o| gpa.free(o);
    if (args.next()) |path| {
        owned = try cwd.readFileAlloc(io, path, gpa, .limited(1 << 20));
        script = owned.?;
    }

    var w = try world.World.init(gpa, io, out, cwd);
    defer w.deinit();
    w.attach();
    try w.runScript(script);
}

test {
    _ = world;
}
