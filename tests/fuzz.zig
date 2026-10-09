//! Fuzz tests: the decoders and the remote integration must never crash,
//! hang or leak on arbitrary bytes. `zig build test` runs the corpus once
//! (the smoke run); `zig build test --fuzz` keeps generating inputs.

const std = @import("std");
const ft = @import("featime");
const support = @import("support.zig");

const Domain = support.Domain;
const Timeline = support.Timeline;

/// `Smith.slice` reads a 4-byte little-endian length before the bytes
/// when it replays a corpus entry; wrap a blob that way.
fn corpusEntry(gpa: std.mem.Allocator, blob: []const u8) ![]u8 {
    const entry = try gpa.alloc(u8, 4 + blob.len);
    std.mem.writeInt(u32, entry[0..4], @intCast(blob.len), .little);
    @memcpy(entry[4..], blob);
    return entry;
}

fn fuzzLoad(_: void, smith: *std.testing.Smith) anyerror!void {
    var buf: [8192]u8 = undefined;
    const len = smith.slice(&buf);
    var reader = std.Io.Reader.fixed(buf[0..len]);
    var tl = ft.persistence.load(Domain, std.testing.allocator, .{ .id_seed = 3 }, &reader) catch return;
    defer tl.deinit();
    // Whatever loaded must be a working timeline.
    _ = tl.state();
    _ = tl.structureDigest();
}

test "fuzz: persistence.load survives arbitrary bytes" {
    const gpa = std.testing.allocator;
    var tl = try Timeline.init(gpa, .{}, .{ .id_seed = 3 });
    defer tl.deinit();
    _ = try support.populate(&tl);
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try ft.persistence.save(Domain, &tl, gpa, &aw.writer);
    const seed = try corpusEntry(gpa, aw.written());
    defer gpa.free(seed);

    try std.testing.fuzz({}, fuzzLoad, .{ .corpus = &.{seed} });
}

fn fuzzEnvelope(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var buf: [4096]u8 = undefined;
    const len = smith.slice(&buf);
    var reader = std.Io.Reader.fixed(buf[0..len]);
    var env = ft.sync.decode(Domain, gpa, &reader) catch return;
    defer ft.sync.deinit(Domain.Op, gpa, &env);

    // A follower with real state: ids in the envelope may or may not exist.
    var tl = try Timeline.init(gpa, .{}, .{ .id_seed = 8 });
    defer tl.deinit();
    _ = try support.populate(&tl);
    _ = tl.applyRemote(&env);
    _ = tl.applyRemote(&env); // re-delivery
    _ = tl.state();
    while (tl.undo()) {}
}

test "fuzz: sync.decode and applyRemote survive arbitrary bytes" {
    const gpa = std.testing.allocator;
    var outbox: support.Outbox = .{ .gpa = gpa };
    defer outbox.deinit();
    var rem = try Timeline.init(gpa, .{}, .{ .id_seed = 5 });
    defer rem.deinit();
    rem.setRecordObserver(.{ .ctx = &outbox, .func = support.Outbox.observe });
    const ids = try support.populate(&rem);
    try support.remoteOps(&rem, &ids);

    var corpus: std.ArrayList([]const u8) = .empty;
    defer {
        for (corpus.items) |c| gpa.free(c);
        corpus.deinit(gpa);
    }
    for (outbox.blobs.items) |blob| try corpus.append(gpa, try corpusEntry(gpa, blob));

    try std.testing.fuzz({}, fuzzEnvelope, .{ .corpus = corpus.items });
}
