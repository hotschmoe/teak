//! Generic deep equality over plain-data types — the frame diff's compare.
//!
//! `deepEql(T, a, b)` compares the *observable content* of two values:
//! slices by length + element content (never by address — the per-frame
//! arena hands out fresh addresses each frame), floats bitwise (so NaN ==
//! NaN and a NaN payload never makes a frame look perpetually dirty; -0 vs
//! +0 reads as a change, which only costs a redundant redraw), structs /
//! unions / optionals / arrays recursively.
//!
//! Because it is derived by comptime reflection, adding a field to any
//! `Cmd` payload (or to an app's `Msg`) is automatically part of the diff —
//! there is no per-variant list to forget.
//!
//! Explicit exceptions (the only places the generic walk is overridden):
//!   * A struct/union that declares `pub fn eql(a: T, b: T) bool` is
//!     compared with that function. Used by `CanvasPrimitive`, whose big
//!     `triangles` / `lines` batches carry a revision `key` that stands in
//!     for their contents (see `core/cmd.zig`).
//!   * Single-item / many-item / C pointers compare by address (they carry
//!     no length to follow). Cmd payloads contain none; an app Msg that
//!     does gets identity semantics.

const std = @import("std");

/// True if `a` and `b` have identical observable content. See the module
/// doc for the rules.
pub fn deepEql(comptime T: type, a: T, b: T) bool {
    switch (@typeInfo(T)) {
        .void => return true,
        .float => {
            const U = @Int(.unsigned, @bitSizeOf(T));
            return @as(U, @bitCast(a)) == @as(U, @bitCast(b));
        },
        .@"struct" => |info| {
            if (info.layout == .@"packed") return a == b;
            if (@hasDecl(T, "eql")) return T.eql(a, b);
            // Padding-free plain data (styles: floats, ints, bools, enums, arrays of
            // them): bitwise equality IS memcmp, and one memcmp beats a field walk.
            if (comptime isBitwise(T)) return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
            inline for (info.field_names, info.field_types) |name, F| {
                if (!deepEql(F, @field(a, name), @field(b, name))) return false;
            }
            return true;
        },
        .@"union" => |info| {
            if (info.layout == .@"packed") return a == b;
            const Tag = info.tag_type orelse
                @compileError("deepEql: cannot compare untagged union " ++ @typeName(T));
            if (@hasDecl(T, "eql")) return T.eql(a, b);
            const ta: Tag = a;
            const tb: Tag = b;
            if (ta != tb) return false;
            switch (a) {
                inline else => |va, tag| return deepEql(@TypeOf(va), va, @field(b, @tagName(tag))),
            }
        },
        .optional => |info| {
            const va = a orelse return b == null;
            const vb = b orelse return false;
            return deepEql(info.child, va, vb);
        },
        .array => |info| {
            for (a, b) |x, y| if (!deepEql(info.child, x, y)) return false;
            return true;
        },
        .vector => return @reduce(.And, a == b),
        .pointer => |info| switch (info.size) {
            .slice => {
                if (a.len != b.len) return false;
                // Bytes-like elements (strings, padding-free integers) compare in one memcmp.
                if (comptime isPlainBytes(info.child)) {
                    return std.mem.eql(u8, std.mem.sliceAsBytes(a), std.mem.sliceAsBytes(b));
                }
                for (a, b) |x, y| if (!deepEql(info.child, x, y)) return false;
                return true;
            },
            else => return a == b,
        },
        .error_union => {
            if (a) |pa| {
                const pb = b catch return false;
                return deepEql(@TypeOf(pa), pa, pb);
            } else |ea| {
                _ = b catch |eb| return ea == eb;
                return false;
            }
        },
        else => return a == b,
    }
}

/// True if `T` is made only of integers / enums / bools with no padding, so
/// equal content <=> equal bytes. (`hasUniqueRepresentation` alone is not
/// enough: it says `true` for pointers, which would compare slices by address.)
fn isPlainBytes(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .bool, .@"enum" => true,
        .array => |i| isPlainBytes(i.child),
        .@"struct" => |info| blk: {
            if (info.layout == .@"packed") break :blk false;
            for (info.field_types) |F| if (!isPlainBytes(F)) break :blk false;
            break :blk std.meta.hasUniqueRepresentation(T);
        },
        else => false,
    };
}

/// True if `T` is padding-free plain data whose equality is exactly byte
/// equality: ints, bools, enums, floats (compared bitwise, as `deepEql` does),
/// and arrays / auto structs of those with no padding and no `eql` override.
fn isBitwise(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .int, .bool, .float => return true,
        .@"enum" => return true,
        .array => |i| return isBitwise(i.child),
        .@"struct" => |info| {
            if (info.layout == .@"packed" or @hasDecl(T, "eql")) return false;
            var sum: usize = 0;
            for (info.field_types) |F| {
                if (!isBitwise(F)) return false;
                sum += @sizeOf(F);
            }
            return sum == @sizeOf(T);
        },
        else => return false,
    }
}

const testing = std.testing;

test "deepEql: slices by content, floats bitwise, optionals, unions" {
    const U = union(enum) { none, n: u32, s: []const u8, f: f32 };
    const S = struct { u: U, o: ?[]const u8 = null, arr: [2]f32 = .{ 0, 1 } };
    var buf_a = "hello".*;
    var buf_b = "hello".*;
    const a: S = .{ .u = .{ .s = &buf_a } };
    const b: S = .{ .u = .{ .s = &buf_b } };
    try testing.expect(deepEql(S, a, b)); // different addresses, same content
    buf_b[4] = 'X';
    try testing.expect(!deepEql(S, a, b));
    try testing.expect(!deepEql(S, .{ .u = .{ .n = 1 } }, .{ .u = .{ .n = 2 } }));
    try testing.expect(!deepEql(S, .{ .u = .none }, .{ .u = .{ .n = 0 } }));
    try testing.expect(!deepEql(S, .{ .u = .none, .o = "" }, .{ .u = .none }));
    const nan = std.math.nan(f32);
    try testing.expect(deepEql(S, .{ .u = .{ .f = nan } }, .{ .u = .{ .f = nan } }));
    try testing.expect(!deepEql(f32, 0.0, -0.0));
}

test "deepEql: honours a custom eql decl" {
    const K = struct {
        key: u32,
        junk: u32,
        pub fn eql(a: @This(), b: @This()) bool {
            return a.key == b.key; // junk deliberately ignored
        }
    };
    try testing.expect(deepEql(K, .{ .key = 1, .junk = 1 }, .{ .key = 1, .junk = 2 }));
    try testing.expect(!deepEql(K, .{ .key = 1, .junk = 1 }, .{ .key = 2, .junk = 1 }));
}
