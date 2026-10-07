//! Shared boilerplate for the usage examples: stdout setup and a banner.
//! Each example keeps its `demo` function focused on timeline logic.

const std = @import("std");
const Io = std.Io;

pub fn run(
    init: std.process.Init,
    comptime title: []const u8,
    comptime demo: *const fn (*Io.Writer, std.mem.Allocator) anyerror!void,
) !void {
    const arena: std.mem.Allocator = init.arena.allocator();
    var buffer: [8192]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const out = &file_writer.interface;

    try out.print("\n== {s} ==\n", .{title});
    try demo(out, arena);
    try out.flush();
}
