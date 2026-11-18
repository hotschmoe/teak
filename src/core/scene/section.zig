//! Section cuts on the CPU: plane x triangle-mesh intersection as line
//! segments, chaining of those segments into loops, and a watertightness
//! check. Pure; variable-size outputs go through the allocator you pass
//! (a frame arena is the intended one).
//!
//! The plane convention is the scene `Cut`'s: `[nx, ny, nz, d]` with unit
//! `n`; points with `dot(n, p) + d <= 0` are kept, the rest is cut away.

const std = @import("std");
const mat = @import("mat.zig");
const scene = @import("../scene.zig");

pub const Vec3 = mat.Vec3;
pub const Affine = mat.Affine;
pub const MeshData = scene.MeshData;
pub const Plane = [4]f32;

pub const Segment = struct { a: Vec3, b: Vec3 };

/// Signed distance of `p` from the plane (positive = cut-away side).
pub fn signedDistance(plane: Plane, p: Vec3) f32 {
    return plane[0] * p[0] + plane[1] * p[1] + plane[2] * p[2] + plane[3];
}

/// Exact intersection of `plane` with the triangle mesh placed by
/// `transform`, appended to `out` as world-space segments.
///
/// A vertex lying exactly on the plane counts as the kept side, so a mesh
/// that is closed and welded by position yields a closed outline with no
/// duplicate or missing segments; triangles lying entirely in the plane
/// produce nothing. Crossing points are computed from a position-ordered
/// edge, so coincident vertices (flat-shaded meshes duplicate them per face)
/// give bit-identical points and chain exactly. Segments are oriented consistently
/// by the triangle winding (they run kept->over at the up-crossing edge), so
/// a closed outward-wound mesh chains into consistently oriented loops.
pub fn outline(gpa: std.mem.Allocator, mesh: MeshData, transform: Affine, plane: Plane, out: *std.ArrayList(Segment)) std.mem.Allocator.Error!void {
    const Src = struct {
        mesh: MeshData,
        fn vertex(self: @This(), i: u32) Vec3 {
            return self.mesh.vertices[i].pos;
        }
    };
    return outlineFrom(gpa, Src{ .mesh = mesh }, mesh.indices, transform, plane, out);
}

/// `outline` over bare positions (`positions[i]` for index `i`): what a Gpu
/// keeps of an uploaded mesh to compute cut outlines without the full
/// vertex data.
pub fn outlinePositions(gpa: std.mem.Allocator, positions: []const Vec3, indices: []const u32, transform: Affine, plane: Plane, out: *std.ArrayList(Segment)) std.mem.Allocator.Error!void {
    const Src = struct {
        pos: []const Vec3,
        fn vertex(self: @This(), i: u32) Vec3 {
            return self.pos[i];
        }
    };
    return outlineFrom(gpa, Src{ .pos = positions }, indices, transform, plane, out);
}

fn outlineFrom(gpa: std.mem.Allocator, src: anytype, indices: []const u32, transform: Affine, plane: Plane, out: *std.ArrayList(Segment)) std.mem.Allocator.Error!void {
    const n_tri = indices.len / 3;
    for (0..n_tri) |t| {
        var p: [3]Vec3 = undefined;
        var d: [3]f32 = undefined;
        for (0..3) |k| {
            p[k] = mat.affinePoint(transform, src.vertex(indices[t * 3 + k]));
            d[k] = signedDistance(plane, p[k]);
        }
        const over = [3]bool{ d[0] > 0, d[1] > 0, d[2] > 0 };
        if (over[0] == over[1] and over[1] == over[2]) continue;
        var down: ?Vec3 = null; // crossing where the winding walks over -> kept
        var up: ?Vec3 = null; // crossing where it walks kept -> over
        for (0..3) |k| {
            const j = (k + 1) % 3;
            if (over[k] == over[j]) continue;
            const x = edgeCrossing(p[k], d[k], p[j], d[j]);
            if (over[k]) down = x else up = x;
        }
        try out.append(gpa, .{ .a = down.?, .b = up.? });
    }
}

/// Crossing point on edge (p0,p1), computed from the lexicographically
/// smaller endpoint first so the result does not depend on edge direction.
fn edgeCrossing(p0: Vec3, d0: f32, p1: Vec3, d1: f32) Vec3 {
    const swap = lexLess(p1, p0);
    const a = if (swap) p1 else p0;
    const b = if (swap) p0 else p1;
    const da = if (swap) d1 else d0;
    const db = if (swap) d0 else d1;
    const t = da / (da - db);
    var r = mat.lerp(a, b, t);
    // normalize -0.0 so bitwise hashing treats it like 0.0
    for (&r) |*c| c.* += 0;
    return r;
}

fn lexLess(a: Vec3, b: Vec3) bool {
    for (0..3) |i| {
        if (a[i] < b[i]) return true;
        if (a[i] > b[i]) return false;
    }
    return false;
}

/// One chained polyline inside `Loops.points`.
pub const Loop = struct {
    start: u32,
    len: u32,
    /// True when the chain returned to its first point. A closed loop does
    /// not repeat the first point at the end.
    closed: bool,
};

pub const Loops = struct {
    points: []Vec3,
    loops: []Loop,

    pub fn deinit(self: Loops, gpa: std.mem.Allocator) void {
        gpa.free(self.points);
        gpa.free(self.loops);
    }

    pub fn pointsOf(self: Loops, l: Loop) []const Vec3 {
        return self.points[l.start..][0..l.len];
    }

    /// True when at least one loop exists and every loop is closed.
    pub fn allClosed(self: Loops) bool {
        if (self.loops.len == 0) return false;
        for (self.loops) |l| if (!l.closed) return false;
        return true;
    }
};

const Key = [3]u32;
fn keyOf(p: Vec3) Key {
    return .{ @bitCast(p[0]), @bitCast(p[1]), @bitCast(p[2]) };
}

/// Chain segments (end of one == start of the next, exact match) into loops
/// and open polylines. Chains that don't close (open meshes, a plane grazing
/// geometry) come back with `closed = false`. Deterministic: input order.
pub fn chain(gpa: std.mem.Allocator, segs: []const Segment) std.mem.Allocator.Error!Loops {
    const n = segs.len;
    var by_start: std.AutoHashMapUnmanaged(Key, u32) = .empty; // key -> first segment index
    defer by_start.deinit(gpa);
    var ends: std.AutoHashMapUnmanaged(Key, void) = .empty;
    defer ends.deinit(gpa);
    const next_same = try gpa.alloc(u32, n); // linked list of segments sharing a start
    defer gpa.free(next_same);
    const used = try gpa.alloc(bool, n);
    defer gpa.free(used);
    @memset(used, false);
    try by_start.ensureTotalCapacity(gpa, @intCast(n));
    try ends.ensureTotalCapacity(gpa, @intCast(n));

    const none = std.math.maxInt(u32);
    var i = n;
    while (i > 0) { // reverse so each list is in ascending order
        i -= 1;
        const e = try by_start.getOrPut(gpa, keyOf(segs[i].a));
        next_same[i] = if (e.found_existing) e.value_ptr.* else none;
        e.value_ptr.* = @intCast(i);
        ends.putAssumeCapacity(keyOf(segs[i].b), {});
    }

    var points: std.ArrayList(Vec3) = .empty;
    errdefer points.deinit(gpa);
    var loops: std.ArrayList(Loop) = .empty;
    errdefer loops.deinit(gpa);

    for ([2]bool{ true, false }) |heads_pass| {
        for (0..n) |s0| {
            if (used[s0]) continue;
            if (heads_pass and ends.contains(keyOf(segs[s0].a))) continue;
            const start_key = keyOf(segs[s0].a);
            const first: u32 = @intCast(points.items.len);
            try points.append(gpa, segs[s0].a);
            used[s0] = true;
            var cur = segs[s0].b;
            var closed = false;
            while (true) {
                if (std.mem.eql(u32, &keyOf(cur), &start_key)) {
                    closed = true;
                    break;
                }
                try points.append(gpa, cur);
                var cand = by_start.get(keyOf(cur)) orelse none;
                while (cand != none and used[cand]) cand = next_same[cand];
                if (cand == none) break;
                used[cand] = true;
                cur = segs[cand].b;
            }
            if (!closed) try points.append(gpa, cur);
            try loops.append(gpa, .{ .start = first, .len = @as(u32, @intCast(points.items.len)) - first, .closed = closed });
        }
    }
    return .{ .points = try points.toOwnedSlice(gpa), .loops = try loops.toOwnedSlice(gpa) };
}

/// Watertight in the sense the stencil cap needs: every edge (vertices welded
/// by exact position) is shared by an even, non-zero number of triangles, so
/// ray parity in/out is well defined. Degenerate triangles are ignored.
/// False for an empty mesh. `gpa` is only used for scratch.
pub fn isClosed(gpa: std.mem.Allocator, mesh: MeshData) std.mem.Allocator.Error!bool {
    const n_tri = mesh.indices.len / 3;
    if (n_tri == 0) return false;
    var ids: std.AutoHashMapUnmanaged(Key, u32) = .empty;
    defer ids.deinit(gpa);
    const weld = try gpa.alloc(u32, mesh.vertices.len);
    defer gpa.free(weld);
    for (mesh.vertices, 0..) |v, i| {
        const e = try ids.getOrPut(gpa, keyOf(.{ v.pos[0] + 0, v.pos[1] + 0, v.pos[2] + 0 }));
        if (!e.found_existing) e.value_ptr.* = @intCast(ids.count() - 1);
        weld[i] = e.value_ptr.*;
    }
    var edges: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer edges.deinit(gpa);
    var any = false;
    for (0..n_tri) |t| {
        const w = [3]u32{ weld[mesh.indices[t * 3]], weld[mesh.indices[t * 3 + 1]], weld[mesh.indices[t * 3 + 2]] };
        if (w[0] == w[1] or w[1] == w[2] or w[0] == w[2]) continue;
        any = true;
        for (0..3) |k| {
            const a = w[k];
            const b = w[(k + 1) % 3];
            const lo = @min(a, b);
            const hi = @max(a, b);
            const e = try edges.getOrPut(gpa, (@as(u64, lo) << 32) | hi);
            if (e.found_existing) e.value_ptr.* += 1 else e.value_ptr.* = 1;
        }
    }
    if (!any) return false;
    var it = edges.valueIterator();
    while (it.next()) |c| if (c.* % 2 != 0) return false;
    return true;
}


const testing = std.testing;
const approx = testing.expectApproxEqAbs;

fn vtx(p: Vec3) scene.MeshVertex {
    return .{ .pos = p, .normal = .{ 0, 0, 1 }, .color = .{ 1, 1, 1, 1 } };
}

const cube_verts = [8]scene.MeshVertex{
    vtx(.{ 0, 0, 0 }), vtx(.{ 1, 0, 0 }), vtx(.{ 1, 1, 0 }), vtx(.{ 0, 1, 0 }),
    vtx(.{ 0, 0, 1 }), vtx(.{ 1, 0, 1 }), vtx(.{ 1, 1, 1 }), vtx(.{ 0, 1, 1 }),
};
const cube_idx = [36]u32{
    0, 3, 2, 0, 2, 1, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4,
    3, 7, 6, 3, 6, 2, 0, 4, 7, 0, 7, 3, 1, 2, 6, 1, 6, 5,
};
const cube = MeshData{ .vertices = &cube_verts, .indices = &cube_idx };

fn loopArea(pts: []const Vec3, axis: usize) f32 {
    const u = (axis + 1) % 3;
    const v = (axis + 2) % 3;
    var s: f32 = 0;
    for (pts, 0..) |p, i| {
        const q = pts[(i + 1) % pts.len];
        s += p[u] * q[v] - q[u] * p[v];
    }
    return s * 0.5;
}










const KerfPart = struct {
    positions: []const f32,
    indices: []const u32,
};
const KerfMesh = struct { parts: []const KerfPart };

