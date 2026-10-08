//! Depth ordering for blended scene layers (translucent planes, sprites).
//! Pure: ordering is a function of the camera position and the layer
//! centres, deterministic for equal distances (input order breaks ties).

const std = @import("std");
const mat = @import("mat.zig");

/// Fill `out_order` with the indices `0..centers.len` sorted back to front:
/// farthest from `eye` first, so drawing in this order with alpha blending
/// composites correctly. Equal distances keep their input order (stable).
/// `out_order.len` must equal `centers.len`. Intersecting translucent
/// layers cannot be ordered by centre alone; that is a known limitation
/// (no order-independent transparency).
pub fn byDepth(eye: mat.Vec3, centers: []const mat.Vec3, out_order: []u32) void {
    std.debug.assert(out_order.len == centers.len);
    for (out_order, 0..) |*o, i| o.* = @intCast(i);
    const Ctx = struct {
        eye: mat.Vec3,
        centers: []const mat.Vec3,
        fn dist2(c: @This(), i: u32) f32 {
            const d = mat.sub(c.centers[i], c.eye);
            return mat.dot(d, d);
        }
        fn farther(c: @This(), a: u32, b: u32) bool {
            const da = c.dist2(a);
            const db = c.dist2(b);
            return if (da != db) da > db else a < b;
        }
    };
    std.mem.sortUnstable(u32, out_order, Ctx{ .eye = eye, .centers = centers }, Ctx.farther);
}

test "byDepth orders far to near and is stable for ties" {
    const centers = [_]mat.Vec3{ .{ 0, 0, 1 }, .{ 0, 0, 5 }, .{ 0, 0, 3 }, .{ 0, 0, -3 }, .{ 0, 0, 5 } };
    var order: [5]u32 = undefined;
    byDepth(.{ 0, 0, 0 }, &centers, &order);
    // distances 1, 5, 3, 3, 5: far = idx 1 and 4 (tie keeps 1 before 4), then 2 and 3 (tie), then 0
    try std.testing.expectEqualSlices(u32, &.{ 1, 4, 2, 3, 0 }, &order);
    // moving the eye reverses the nearest/farthest roles
    byDepth(.{ 0, 0, 10 }, &centers, &order);
    try std.testing.expectEqual(@as(u32, 3), order[0]); // z = -3 is now the farthest
    try std.testing.expectEqualSlices(u32, &.{ 3, 0, 2, 1, 4 }, &order); // the z = 5 pair is nearest, in input order
    byDepth(.{ 0, 0, 0 }, centers[0..0], order[0..0]); // empty is fine
}
