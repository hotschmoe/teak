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

/// The six vertices of an image-style quad covering `rect`, trimmed to
/// `clip` with UVs adjusted so the texture is cropped, not squashed. `null`
/// when nothing is visible. Both GPU backends build image and scene
/// composite quads through this so their clip rules cannot drift.
pub fn clippedTexturedQuad(rect: Rect, clip: Rect, tint: [4]f32) ?[6]Vertex {
    if (rect.w <= 0 or rect.h <= 0) return null;
    const x0 = @max(rect.x, clip.x);
    const y0 = @max(rect.y, clip.y);
    const x1 = @min(rect.x + rect.w, clip.x + clip.w);
    const y1 = @min(rect.y + rect.h, clip.y + clip.h);
    if (x1 <= x0 or y1 <= y0) return null;

    const uv_u0 = (x0 - rect.x) / rect.w;
    const uv_v0 = (y0 - rect.y) / rect.h;
    const uv_u1 = (x1 - rect.x) / rect.w;
    const uv_v1 = (y1 - rect.y) / rect.h;
    const r, const g, const b, const a = tint;
    return .{
        .{ .x = x0, .y = y0, .r = r, .g = g, .b = b, .a = a, .u = uv_u0, .v = uv_v0 },
        .{ .x = x1, .y = y0, .r = r, .g = g, .b = b, .a = a, .u = uv_u1, .v = uv_v0 },
        .{ .x = x0, .y = y1, .r = r, .g = g, .b = b, .a = a, .u = uv_u0, .v = uv_v1 },
        .{ .x = x1, .y = y0, .r = r, .g = g, .b = b, .a = a, .u = uv_u1, .v = uv_v0 },
        .{ .x = x1, .y = y1, .r = r, .g = g, .b = b, .a = a, .u = uv_u1, .v = uv_v1 },
        .{ .x = x0, .y = y1, .r = r, .g = g, .b = b, .a = a, .u = uv_u0, .v = uv_v1 },
    };
}

// ── Tests ──────────────────────────────────────────────────────────

test "clippedTexturedQuad crops UVs to the visible region" {
    const rect: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 50 };
    const clip: Rect = .{ .x = 25, .y = 0, .w = 50, .h = 50 };
    const q = clippedTexturedQuad(rect, clip, .{ 1, 1, 1, 1 }).?;
    try std.testing.expectEqual(@as(f32, 25), q[0].x);
    try std.testing.expectEqual(@as(f32, 75), q[1].x);
    try std.testing.expectEqual(@as(f32, 0.25), q[0].u);
    try std.testing.expectEqual(@as(f32, 0.75), q[1].u);
    try std.testing.expectEqual(@as(f32, 1), q[4].v);
}

test "clippedTexturedQuad is null when fully clipped or empty" {
    const rect: Rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    try std.testing.expect(clippedTexturedQuad(rect, .{ .x = 20, .y = 0, .w = 5, .h = 5 }, .{ 1, 1, 1, 1 }) == null);
    try std.testing.expect(clippedTexturedQuad(.{ .x = 0, .y = 0, .w = 0, .h = 4 }, rect, .{ 1, 1, 1, 1 }) == null);
}

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
