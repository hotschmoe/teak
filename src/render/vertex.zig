const std = @import("std");
const Rect = @import("../layout/engine.zig").Rect;

pub const Vertex = extern struct {
    x: f32,
    y: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
    u: f32,
    v: f32,
};

pub fn emitQuad(
    verts: *std.ArrayList(Vertex),
    alloc: std.mem.Allocator,
    rect: Rect,
    color: [4]f32,
) void {
    const x0 = rect.x;
    const y0 = rect.y;
    const x1 = rect.x + rect.w;
    const y1 = rect.y + rect.h;
    const r = color[0];
    const g = color[1];
    const b = color[2];
    const a = color[3];

    verts.appendSlice(alloc, &.{
        .{ .x = x0, .y = y0, .r = r, .g = g, .b = b, .a = a, .u = 0, .v = 0 },
        .{ .x = x1, .y = y0, .r = r, .g = g, .b = b, .a = a, .u = 1, .v = 0 },
        .{ .x = x0, .y = y1, .r = r, .g = g, .b = b, .a = a, .u = 0, .v = 1 },
        .{ .x = x1, .y = y0, .r = r, .g = g, .b = b, .a = a, .u = 1, .v = 0 },
        .{ .x = x1, .y = y1, .r = r, .g = g, .b = b, .a = a, .u = 1, .v = 1 },
        .{ .x = x0, .y = y1, .r = r, .g = g, .b = b, .a = a, .u = 0, .v = 1 },
    }) catch unreachable;
}

/// Emit a solid-color quad from four explicit corners winding around the
/// quad (`c0 → c1 → c2 → c3`), as two triangles `(c0,c1,c2)` and
/// `(c0,c2,c3)`. Unlike `emitQuad`, the corners need not be axis-aligned —
/// this is what lets the canvas draw arbitrary-angle polyline segments
/// (each segment is a rotated rectangle) through the same colored-quad
/// pipeline. `u`/`v` are left at 0 since the solid-quad shader ignores
/// them; only `emitQuad` (textured-capable path) sets meaningful UVs.
pub fn emitQuadCorners(
    verts: *std.ArrayList(Vertex),
    alloc: std.mem.Allocator,
    c0: [2]f32,
    c1: [2]f32,
    c2: [2]f32,
    c3: [2]f32,
    color: [4]f32,
) void {
    const r = color[0];
    const g = color[1];
    const b = color[2];
    const a = color[3];

    verts.appendSlice(alloc, &.{
        .{ .x = c0[0], .y = c0[1], .r = r, .g = g, .b = b, .a = a, .u = 0, .v = 0 },
        .{ .x = c1[0], .y = c1[1], .r = r, .g = g, .b = b, .a = a, .u = 0, .v = 0 },
        .{ .x = c2[0], .y = c2[1], .r = r, .g = g, .b = b, .a = a, .u = 0, .v = 0 },
        .{ .x = c0[0], .y = c0[1], .r = r, .g = g, .b = b, .a = a, .u = 0, .v = 0 },
        .{ .x = c2[0], .y = c2[1], .r = r, .g = g, .b = b, .a = a, .u = 0, .v = 0 },
        .{ .x = c3[0], .y = c3[1], .r = r, .g = g, .b = b, .a = a, .u = 0, .v = 0 },
    }) catch unreachable;
}

// ── Tests ──────────────────────────────────────────────────────────

test "emitQuad emits 6 vertices for a rect" {
    const testing = std.testing;
    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(testing.allocator);
    emitQuad(&verts, testing.allocator, .{ .x = 0, .y = 0, .w = 10, .h = 20 }, .{ 1, 1, 1, 1 });
    try testing.expectEqual(@as(usize, 6), verts.items.len);
}

test "emitQuadCorners places corners for a diagonal segment quad" {
    const testing = std.testing;
    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(testing.allocator);

    // A diagonal segment (0,0)->(10,10) with a normal half-width of √2
    // produces corners offset perpendicular to the segment: the "left"
    // side shifts by (-1, +1), the "right" side by (+1, -1).
    const c0 = [2]f32{ -1, 1 };
    const c1 = [2]f32{ 9, 11 };
    const c2 = [2]f32{ 11, 9 };
    const c3 = [2]f32{ 1, -1 };
    emitQuadCorners(&verts, testing.allocator, c0, c1, c2, c3, .{ 0.2, 0.4, 0.6, 1 });

    try testing.expectEqual(@as(usize, 6), verts.items.len);
    // Triangle 1 = c0,c1,c2 ; Triangle 2 = c0,c2,c3.
    try testing.expectEqual(@as(f32, -1), verts.items[0].x);
    try testing.expectEqual(@as(f32, 1), verts.items[0].y);
    try testing.expectEqual(@as(f32, 9), verts.items[1].x);
    try testing.expectEqual(@as(f32, 11), verts.items[1].y);
    try testing.expectEqual(@as(f32, 11), verts.items[2].x);
    try testing.expectEqual(@as(f32, 9), verts.items[2].y);
    // Second triangle reuses c0 + c2, then c3.
    try testing.expectEqual(@as(f32, -1), verts.items[3].x);
    try testing.expectEqual(@as(f32, 11), verts.items[4].x);
    try testing.expectEqual(@as(f32, 1), verts.items[5].x);
    try testing.expectEqual(@as(f32, -1), verts.items[5].y);
    // Color propagates to every vertex.
    for (verts.items) |v| {
        try testing.expectEqual(@as(f32, 0.2), v.r);
        try testing.expectEqual(@as(f32, 0.6), v.b);
    }
}
