//! `zig build bench-cmdsize` — prototype for docs/features/cmd-size.md.
//!
//! Builds, on a COPY of the type (cmd.zig is untouched), a "slim" Cmd where
//! every variant payload larger than SLIM_INLINE bytes lives out-of-line in
//! the per-frame arena and the union holds a pointer. Then times the passes
//! that stream the whole buffer (emit, tag walk like hit-test, frame diff)
//! on the real 240-byte Cmd vs the slim one over the same widget mix.

const std = @import("std");
const teak = @import("teak");

const Msg = union(enum) { click: u32, noop };
const Fat = teak.Cmd(Msg);
const SLIM_INLINE = 64;

fn Slim(comptime C: type) type {
    const info = @typeInfo(C).@"union";
    comptime var types: [info.field_types.len]type = undefined;
    comptime var attrs: [info.field_types.len]std.builtin.Type.Union.FieldAttributes = undefined;
    for (info.field_types, 0..) |T, i| {
        types[i] = if (@sizeOf(T) > SLIM_INLINE) *const T else T;
        attrs[i] = .{};
    }
    return @Union(.auto, info.tag_type.?, info.field_names, &types, &attrs);
}
const Lean = Slim(Fat);

fn nowNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

/// Deep equality that follows the out-of-line pointers like inline data
/// (field-by-field; the real `deepEql` additionally memcmp's plain structs,
/// so this is conservative for the slim side).
fn eql(comptime T: type, a: T, b: T) bool {
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.size == .one) return eql(p.child, a.*, b.*);
            if (a.len != b.len) return false;
            for (a, b) |x, y| if (!eql(p.child, x, y)) return false;
            return true;
        },
        .@"union" => {
            if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
            switch (a) {
                inline else => |va, tag| return eql(@TypeOf(va), va, @field(b, @tagName(tag))),
            }
        },
        .@"struct" => |info| {
            inline for (info.field_names, info.field_types) |n, F| {
                if (!eql(F, @field(a, n), @field(b, n))) return false;
            }
            return true;
        },
        .optional => |o| {
            const x = a orelse return b == null;
            const y = b orelse return false;
            return eql(o.child, x, y);
        },
        .array => |arr| {
            for (a, b) |x, y| if (!eql(arr.child, x, y)) return false;
            return true;
        },
        .float => return @as(@Int(.unsigned, @bitSizeOf(T)), @bitCast(a)) == @as(@Int(.unsigned, @bitSizeOf(T)), @bitCast(b)),
        else => return a == b,
    }
}

fn buildFat(list: *std.ArrayList(Fat), gpa: std.mem.Allocator, n: usize) !void {
    list.clearRetainingCapacity();
    for (0..n) |i| {
        try list.append(gpa, .{ .push_group = .{} });
        try list.append(gpa, .{ .text = .{ .content = "row", .font = .{}, .color = .{ 1, 1, 1, 1 } } });
        try list.append(gpa, .{ .button = .{ .msg = .{ .click = @intCast(i) }, .label = "Edit" } });
        try list.append(gpa, .pop_group);
    }
}

fn buildLean(list: *std.ArrayList(Lean), arena: std.mem.Allocator, gpa: std.mem.Allocator, n: usize) !void {
    list.clearRetainingCapacity();
    for (0..n) |i| {
        const g = try arena.create(@typeInfo(Fat).@"union".field_types[0]);
        g.* = .{};
        try list.append(gpa, .{ .push_group = g });
        try list.append(gpa, .{ .text = .{ .content = "row", .font = .{}, .color = .{ 1, 1, 1, 1 } } });
        const btn = try arena.create(@typeInfo(Fat).@"union".field_types[11]);
        btn.* = .{ .msg = .{ .click = @intCast(i) }, .label = "Edit" };
        try list.append(gpa, .{ .button = btn });
        try list.append(gpa, .pop_group);
    }
}

fn walk(cmds: anytype) u32 {
    var depth: u32 = 0;
    var acc: u32 = 0;
    for (cmds) |c| switch (c) {
        .push_group => depth += 1,
        .pop_group => depth -= 1,
        .text => acc += 1,
        .button => acc += 2,
        else => {},
    };
    return acc +% depth;
}

fn same(cmds_a: anytype, cmds_b: anytype) bool {
    if (cmds_a.len != cmds_b.len) return false;
    for (cmds_a, cmds_b) |x, y| if (!eql(@TypeOf(x), x, y)) return false;
    return true;
}

pub fn main() !void {
    var gpa_impl: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    std.debug.print("sizeOf Cmd: fat={d} B, slim={d} B (inline <= {d} B)\n", .{ @sizeOf(Fat), @sizeOf(Lean), SLIM_INLINE });
    std.debug.print("{s:>8} {s:>10} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9} {s:>9}\n", .{ "rows", "cmds", "emitFat", "emitSlim", "walkFat", "walkSlim", "eqFat", "eqSlim" });
    const iters = 20;
    for ([_]usize{ 1_000, 10_000, 50_000 }) |n| {
        var fat_a: std.ArrayList(Fat) = .empty;
        defer fat_a.deinit(gpa);
        var fat_b: std.ArrayList(Fat) = .empty;
        defer fat_b.deinit(gpa);
        var lean_a: std.ArrayList(Lean) = .empty;
        defer lean_a.deinit(gpa);
        var lean_b: std.ArrayList(Lean) = .empty;
        defer lean_b.deinit(gpa);
        try buildFat(&fat_b, gpa, n);
        try buildLean(&lean_b, arena, gpa, n);

        var t: [6]u64 = @splat(0);
        for (0..iters) |_| {
            var a = nowNs();
            try buildFat(&fat_a, gpa, n);
            t[0] += nowNs() - a;
            a = nowNs();
            try buildLean(&lean_a, arena, gpa, n);
            t[1] += nowNs() - a;
            a = nowNs();
            std.mem.doNotOptimizeAway(walk(fat_a.items));
            t[2] += nowNs() - a;
            a = nowNs();
            std.mem.doNotOptimizeAway(walk(lean_a.items));
            t[3] += nowNs() - a;
            a = nowNs();
            std.mem.doNotOptimizeAway(teak.runtime.cmdsEqual(Msg, fat_a.items, fat_b.items));
            t[4] += nowNs() - a;
            a = nowNs();
            std.mem.doNotOptimizeAway(same(lean_a.items, lean_b.items));
            t[5] += nowNs() - a;
            _ = arena_state.reset(.retain_capacity);
            try buildLean(&lean_b, arena, gpa, n); // keep lean_b's pointers valid
        }
        const f = struct {
            fn ms(x: u64) f64 {
                return @as(f64, @floatFromInt(x)) / iters / 1e6;
            }
        }.ms;
        std.debug.print("{d:>8} {d:>10} {d:>9.3} {d:>9.3} {d:>9.3} {d:>9.3} {d:>9.3} {d:>9.3}\n", .{ n, n * 4, f(t[0]), f(t[1]), f(t[2]), f(t[3]), f(t[4]), f(t[5]) });
    }
}
