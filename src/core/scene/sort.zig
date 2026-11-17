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

