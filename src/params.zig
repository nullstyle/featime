//! The parameter table: named numeric values owned by the timeline that
//! features read through `ApplyContext.param`. One parameter change can
//! re-drive every feature referencing it — Fusion's parameter table, minus
//! the expression language (apps derive values in their Domain).
//!
//! Ops reference parameters by `ParamId` (plain u64, allocated by the
//! timeline's shared id space) so op payloads stay plain data. Values are
//! numeric scalars in v1.

const std = @import("std");

pub const ParamId = u64;

pub const Param = struct {
    id: ParamId,
    /// Owned by the table.
    name: []const u8,
    value: f64,
};

pub const ParamTable = struct {
    const Self = @This();

    gpa: std.mem.Allocator,
    list: std.ArrayList(Param) = .empty,

    pub fn init(gpa: std.mem.Allocator) Self {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Self) void {
        for (self.list.items) |*p| self.gpa.free(p.name);
        self.list.deinit(self.gpa);
    }

    /// Parameters in creation order. Valid until the next mutation.
    pub fn items(self: *const Self) []const Param {
        return self.list.items;
    }

    pub fn byId(self: *const Self, id: ParamId) ?Param {
        for (self.list.items) |p| {
            if (p.id == id) return p;
        }
        return null;
    }

    pub fn valueOf(self: *const Self, id: ParamId) ?f64 {
        const p = self.byId(id) orelse return null;
        return p.value;
    }

    pub fn idByName(self: *const Self, name: []const u8) ?ParamId {
        for (self.list.items) |p| {
            if (std.mem.eql(u8, p.name, name)) return p.id;
        }
        return null;
    }

    /// Add a parameter with a caller-allocated id. Fails on a duplicate id
    /// or name.
    pub fn add(self: *Self, id: ParamId, name: []const u8, value: f64) error{ OutOfMemory, DuplicateParam }!void {
        for (self.list.items) |p| {
            if (p.id == id or std.mem.eql(u8, p.name, name)) return error.DuplicateParam;
        }
        try self.list.append(self.gpa, .{
            .id = id,
            .name = try self.gpa.dupe(u8, name),
            .value = value,
        });
    }

    /// Set a value; false when the id is unknown.
    pub fn set(self: *Self, id: ParamId, value: f64) bool {
        for (self.list.items) |*p| {
            if (p.id == id) {
                p.value = value;
                return true;
            }
        }
        return false;
    }

    /// Remove a parameter; false when the id is unknown.
    pub fn remove(self: *Self, id: ParamId) bool {
        for (self.list.items, 0..) |p, i| {
            if (p.id == id) {
                const dead = self.list.orderedRemove(i);
                self.gpa.free(dead.name);
                return true;
            }
        }
        return false;
    }

    /// Rename in place; false when the id is unknown.
    pub fn rename(self: *Self, id: ParamId, new_name: []const u8) error{OutOfMemory}!bool {
        for (self.list.items) |*p| {
            if (p.id == id) {
                const duped = try self.gpa.dupe(u8, new_name);
                self.gpa.free(p.name);
                p.name = duped;
                return true;
            }
        }
        return false;
    }
};

/// Handed to the optional `Domain.references` hook. Call `param` once per
/// parameter id the op reads; `Timeline.setParam` invalidates from the
/// earliest referencing feature.
pub const ParamRefCollector = struct {
    gpa: std.mem.Allocator,
    ids: std.ArrayList(ParamId) = .empty,
    failed: bool = false,

    pub fn param(self: *ParamRefCollector, id: ParamId) void {
        self.ids.append(self.gpa, id) catch {
            self.failed = true;
        };
    }
};
