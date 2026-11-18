const std = @import("std");
const oom = @import("../core/oom.zig").oom;
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
    }) catch oom();
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
    }) catch oom();
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
