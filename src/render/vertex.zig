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
