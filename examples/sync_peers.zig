//! Two processes syncing: this program spawns itself as a child and the two
//! sides talk through the child's stdin and stdout with the session
//! protocol (`ft.sync.Session`). Concurrent commits, concurrent edits of
//! one feature, an undo, a lost frame, and a divergence repaired by a
//! snapshot — the parent logs to stdout, the child to stderr.
//!
//! Run: zig build sync_peers

const std = @import("std");
const Io = std.Io;
const ft = @import("featime");

const Ledger = struct {
    pub const Doc = struct { total: i64 = 0 };
    pub const Op = union(enum) { add: i64, multiply: i64 };

    pub fn apply(op: Op, doc: *Doc, ctx: *ft.ApplyContext) anyerror!void {
        _ = ctx;
        switch (op) {
            .add => |n| doc.total += n,
            .multiply => |n| doc.total *= n,
        }
    }
    pub fn encodeOp(op: Op, w: *Io.Writer) anyerror!void {
        switch (op) {
            .add => |n| {
                try w.writeByte(1);
                try w.writeInt(i64, n, .little);
            },
            .multiply => |n| {
                try w.writeByte(2);
                try w.writeInt(i64, n, .little);
            },
        }
    }
    pub fn decodeOp(r: *Io.Reader, gpa: std.mem.Allocator) anyerror!Op {
        _ = gpa;
        return switch (try r.takeByte()) {
            1 => .{ .add = try r.takeInt(i64, .little) },
            2 => .{ .multiply = try r.takeInt(i64, .little) },
            else => error.Malformed,
        };
    }
    pub fn encodeDoc(doc: *const Doc, w: *Io.Writer) anyerror!void {
        try w.writeInt(i64, doc.total, .little);
    }
    pub fn decodeDoc(r: *Io.Reader, gpa: std.mem.Allocator) anyerror!Doc {
        _ = gpa;
        return .{ .total = try r.takeInt(i64, .little) };
    }
};

const Tl = ft.Timeline(Ledger);
const Session = ft.sync.Session(Ledger);

/// One side of the link. The two sides run the same script in lockstep: a
/// round sends everything queued plus a ping, then reads until the peer's
/// ping arrives. Replies to what a round delivered go out with the next.
const Peer = struct {
    name: []const u8,
    gpa: std.mem.Allocator,
    tl: Tl,
    session: Session,
    reader: *Io.Reader,
    writer: *Io.Writer,
    log: *Io.Writer,

    fn create(gpa: std.mem.Allocator, name: []const u8, reader: *Io.Reader, writer: *Io.Writer, log: *Io.Writer) !*Peer {
        const p = try gpa.create(Peer);
        p.* = .{ .name = name, .gpa = gpa, .tl = undefined, .session = undefined, .reader = reader, .writer = writer, .log = log };
        p.tl = try Tl.init(gpa, .{}, .{});
        p.session = Session.init(gpa, &p.tl);
        p.session.attach();
        return p;
    }

    fn destroy(p: *Peer) void {
        p.session.deinit();
        p.tl.deinit();
        p.gpa.destroy(p);
    }

    fn round(p: *Peer) !void {
        try p.session.ping();
        try p.writer.writeAll(p.session.outgoingBytes());
        p.session.clearOutgoing();
        try p.writer.flush();
        const pings = p.session.stats.pings;
        while (p.session.stats.pings == pings) {
            const len = try p.reader.takeInt(u32, .little);
            const frame = try p.gpa.alloc(u8, len);
            defer p.gpa.free(frame);
            try p.reader.readSliceAll(frame);
            try p.session.receive(frame);
        }
    }

    fn rounds(p: *Peer, n: u32) !void {
        var i: u32 = 0;
        while (i < n) : (i += 1) try p.round();
    }

    fn report(p: *Peer, step: []const u8) !void {
        const agree: []const u8 = if (p.session.peer_digest) |d| (if (d == p.tl.structureDigest()) "same" else "DIFFERENT") else "unknown";
        try p.log.print("[{s}] {s:<34} {d} features, total {d:<6} digest {x:0>16}  peer: {s}\n", .{ p.name, step, p.tl.len(), p.tl.state().total, p.tl.structureDigest(), agree });
        try p.log.flush();
    }

    /// Lose the first queued frame on purpose (the transport "dropped it").
    fn dropFirstFrame(p: *Peer) void {
        const items = p.session.outgoing.items;
        if (items.len < 4) return;
        const len = 4 + std.mem.readInt(u32, items[0..4], .little);
        std.mem.copyForwards(u8, items[0 .. items.len - len], items[len..]);
        p.session.outgoing.shrinkRetainingCapacity(items.len - len);
    }
};

const Role = enum { parent, child };

/// The same script on both sides; only the edits differ by role. Every
/// step ends with the same number of rounds on each side.
fn script(p: *Peer, role: Role) !void {
    // 1. Connect.
    try p.session.hello();
    try p.rounds(2);
    try p.report(
        "connected",
    );

    // 2. Both commit at the same time: same order everywhere.
    if (role == .parent) {
        _ = try p.tl.commit(.{ .add = 10 });
        _ = try p.tl.commit(.{ .multiply = 3 });
    } else {
        _ = try p.tl.commit(.{ .add = 200 });
    }
    try p.rounds(2);
    try p.session.probe();
    try p.rounds(1);
    try p.report(
        "concurrent commits",
    );

    // 3. Both edit the first feature at the same time: one winner.
    const first = p.tl.featureAt(0).?.id;
    try p.tl.edit(first, .{ .add = if (role == .parent) 11 else 12 });
    try p.rounds(2);
    try p.session.probe();
    try p.rounds(1);
    try p.report(
        "same feature edited on both sides",
    );

    // 4. The parent undoes its edit; the child follows.
    if (role == .parent) _ = p.tl.undo();
    try p.rounds(2);
    try p.session.probe();
    try p.rounds(1);
    try p.report(
        "parent undid its edit",
    );

    // 5. The parent's transport loses a frame; the child asks for it.
    if (role == .parent) {
        _ = try p.tl.commit(.{ .add = 1 });
        _ = try p.tl.commit(.{ .add = 2 });
        p.dropFirstFrame();
    }
    try p.rounds(3);
    try p.session.probe();
    try p.rounds(1);
    try p.report(
        "a lost frame, replayed on request",
    );

    // 6. The child changes something behind the session's back; probes
    //    expose it and a snapshot settles it (the larger history wins).
    if (role == .child) {
        p.tl.setRecordObserver(null);
        _ = try p.tl.commit(.{ .add = 1000 });
        p.session.attach();
    }
    try p.session.probe();
    try p.rounds(3);
    try p.session.probe();
    try p.rounds(1);
    try p.report(
        "divergence settled by a snapshot",
    );
    try p.log.print("[{s}] snapshots sent {d}, loaded {d}; envelopes replayed {d}, gaps {d}\n", .{ p.name, p.session.stats.snapshots_sent, p.session.stats.snapshots_loaded, p.session.stats.replayed, p.session.stats.gaps });
    try p.log.flush();
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(gpa);
    defer args.deinit();
    const exe = args.next() orelse return error.NoProgramPath;
    if (args.next()) |role| {
        if (std.mem.eql(u8, role, "child")) return runChild(gpa, io);
    }
    return runParent(gpa, io, exe);
}

fn runParent(gpa: std.mem.Allocator, io: Io, exe: []const u8) !void {
    var log_buf: [4096]u8 = undefined;
    var log_writer: Io.File.Writer = .init(.stdout(), io, &log_buf);
    const log = &log_writer.interface;
    try log.writeAll("\n== sync_peers: two processes over pipes ==\n");
    try log.flush();

    var child = try std.process.spawn(io, .{
        .argv = &.{ exe, "child" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    });
    var in_buf: [64 << 10]u8 = undefined;
    var reader: Io.File.Reader = .init(child.stdout.?, io, &in_buf);
    var out_buf: [64 << 10]u8 = undefined;
    var writer: Io.File.Writer = .init(child.stdin.?, io, &out_buf);

    const peer = try Peer.create(gpa, "parent", &reader.interface, &writer.interface, log);
    defer peer.destroy();
    try script(peer, .parent);

    // The child runs the same number of rounds and exits by itself; `wait`
    // closes the pipes.
    const term = try child.wait(io);
    try log.print("child exited: {}\n", .{term.success()});
    try log.flush();
}

fn runChild(gpa: std.mem.Allocator, io: Io) !void {
    var log_buf: [4096]u8 = undefined;
    var log_writer: Io.File.Writer = .init(.stderr(), io, &log_buf);
    var in_buf: [64 << 10]u8 = undefined;
    var reader: Io.File.Reader = .init(.stdin(), io, &in_buf);
    var out_buf: [64 << 10]u8 = undefined;
    var writer: Io.File.Writer = .init(.stdout(), io, &out_buf);

    const peer = try Peer.create(gpa, "child ", &reader.interface, &writer.interface, &log_writer.interface);
    defer peer.destroy();
    try script(peer, .child);
}
