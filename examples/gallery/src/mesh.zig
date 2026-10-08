//! A stud-wall detail built at comptime: a bottom plate, a double top plate
//! and studs at 16" (0.4 unit) centres, each a box with flat-lit faces and
//! 12 feature edges, over a ground grid. Everything is a `const`, so the
//! `MeshData` the App hands to `resources()` is static data.

const std = @import("std");
const teak = @import("teak");

const Box = struct { min: [3]f32, max: [3]f32, color: [3]f32 };

const wood: [3]f32 = .{ 0.80, 0.62, 0.38 };
const wood_dark: [3]f32 = .{ 0.66, 0.50, 0.30 };
const stud_count = 11;

const boxes: [stud_count + 3]Box = blk: {
    var out: [stud_count + 3]Box = undefined;
    out[0] = .{ .min = .{ 0, 0, 0 }, .max = .{ 4.4, 0.15, 0.35 }, .color = wood_dark }; // bottom plate
    out[1] = .{ .min = .{ 0, 2.55, 0 }, .max = .{ 4.4, 2.70, 0.35 }, .color = wood_dark }; // top plate 1
    out[2] = .{ .min = .{ 0, 2.70, 0 }, .max = .{ 4.4, 2.85, 0.35 }, .color = wood_dark }; // top plate 2
    for (0..stud_count) |i| {
        const x: f32 = 0.4 * @as(f32, @floatFromInt(i));
        out[3 + i] = .{ .min = .{ x, 0.15, 0 }, .max = .{ x + 0.15, 2.55, 0.35 }, .color = wood };
    }
    break :blk out;
};

const faces = [6]struct { n: [3]f32, u: [3]f32, v: [3]f32 }{
    .{ .n = .{ 1, 0, 0 }, .u = .{ 0, 1, 0 }, .v = .{ 0, 0, 1 } },
    .{ .n = .{ -1, 0, 0 }, .u = .{ 0, 0, 1 }, .v = .{ 0, 1, 0 } },
    .{ .n = .{ 0, 1, 0 }, .u = .{ 0, 0, 1 }, .v = .{ 1, 0, 0 } },
    .{ .n = .{ 0, -1, 0 }, .u = .{ 1, 0, 0 }, .v = .{ 0, 0, 1 } },
    .{ .n = .{ 0, 0, 1 }, .u = .{ 1, 0, 0 }, .v = .{ 0, 1, 0 } },
    .{ .n = .{ 0, 0, -1 }, .u = .{ 0, 1, 0 }, .v = .{ 1, 0, 0 } },
};

const grid_half = 6;
const grid_segments = (2 * grid_half + 1) * 2;

pub const vertices: [boxes.len * 24]teak.MeshVertex = blk: {
    @setEvalBranchQuota(200_000);
    var out: [boxes.len * 24]teak.MeshVertex = undefined;
    const signs = [4][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } };
    for (boxes, 0..) |b, bi| {
        var centre: [3]f32 = undefined;
        var half: [3]f32 = undefined;
        for (0..3) |k| {
            centre[k] = (b.min[k] + b.max[k]) * 0.5;
            half[k] = (b.max[k] - b.min[k]) * 0.5;
        }
        for (faces, 0..) |f, fi| {
            for (signs, 0..) |s, ci| {
                var p: [3]f32 = undefined;
                for (0..3) |k| p[k] = centre[k] + half[k] * (f.n[k] + s[0] * f.u[k] + s[1] * f.v[k]);
                out[bi * 24 + fi * 4 + ci] = .{ .pos = p, .normal = f.n, .color = .{ b.color[0], b.color[1], b.color[2], 1 } };
            }
        }
    }
    break :blk out;
};

pub const indices: [boxes.len * 36]u32 = blk: {
    var out: [boxes.len * 36]u32 = undefined;
    for (0..boxes.len * 6) |face| {
        const base: u32 = @intCast(face * 4);
        const quad = [6]u32{ 0, 1, 2, 0, 2, 3 };
        for (quad, 0..) |q, i| out[face * 6 + i] = base + q;
    }
    break :blk out;
};

fn line(a: [3]f32, b: [3]f32, c: [4]f32) [2]teak.LineVertex {
    return .{ .{ .pos = a, .color = c }, .{ .pos = b, .color = c } };
}

fn edgeLines(comptime edges: bool) [(if (edges) boxes.len * 12 else 0) * 2 + grid_segments * 2]teak.LineVertex {
    @setEvalBranchQuota(200_000);
    const n_edges = if (edges) boxes.len * 12 else 0;
    var out: [n_edges * 2 + grid_segments * 2]teak.LineVertex = undefined;
    var n: usize = 0;
    if (edges) {
        const ink = [4]f32{ 0.10, 0.08, 0.06, 1 };
        for (boxes) |b| {
            for (0..8) |i| {
                for (0..3) |axis| {
                    if (i & (@as(usize, 1) << @intCast(axis)) != 0) continue;
                    var a: [3]f32 = undefined;
                    for (0..3) |k| a[k] = if (i & (@as(usize, 1) << @intCast(k)) != 0) b.max[k] else b.min[k];
                    var e = a;
                    e[axis] = b.max[axis];
                    a[axis] = b.min[axis];
                    out[n..][0..2].* = line(a, e, ink);
                    n += 2;
                }
            }
        }
    }
    // Ground grid at y = 0, centred under the wall (x 0..4.4, z -2..2).
    const grid = [4]f32{ 0.45, 0.47, 0.50, 0.55 };
    const extent: f32 = grid_half;
    var g: i32 = -grid_half;
    while (g <= grid_half) : (g += 1) {
        const t: f32 = @floatFromInt(g);
        out[n..][0..2].* = line(.{ 2.2 + t, 0, -extent }, .{ 2.2 + t, 0, extent }, grid);
        n += 2;
        out[n..][0..2].* = line(.{ 2.2 - extent, 0, t }, .{ 2.2 + extent, 0, t }, grid);
        n += 2;
    }
    return out;
}

const lines_with = edgeLines(true);
const lines_without = edgeLines(false);

pub const with_edges: teak.MeshData = .{ .vertices = &vertices, .indices = &indices, .lines = &lines_with };
pub const without_edges: teak.MeshData = .{ .vertices = &vertices, .indices = &indices, .lines = &lines_without };

test "mesh is valid and has the expected counts" {
    try with_edges.validate();
    try without_edges.validate();
    try std.testing.expectEqual(@as(usize, 14 * 12), (with_edges.segmentCount() - without_edges.segmentCount()));
    try std.testing.expectEqual(@as(usize, 14 * 12), with_edges.triangleCount());
}
