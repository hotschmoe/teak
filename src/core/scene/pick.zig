//! CPU ray picking: ray-triangle (Moller-Trumbore), ray-AABB, an optional
//! per-mesh BVH, `items` over placed mesh instances, and the corner axis
//! gizmo hit-test.
//!
//! Pure functions over plain data (HARDLINE: `update` stays a pure function
//! of (Model, Msg); the ray comes from `camera.pickRay` with the event's
//! viewport-local px). No platform imports; the only allocation is `Bvh.build`
//! through the allocator you pass.

const std = @import("std");
const mat = @import("mat.zig");
const scene = @import("../scene.zig");
const camera = @import("camera.zig");

pub const Vec3 = mat.Vec3;
pub const Affine = mat.Affine;
pub const Ray = camera.Ray;
pub const Bounds = camera.Bounds;
pub const MeshData = scene.MeshData;

/// Barycentric slack so rays through a shared edge/vertex never fall into the
/// crack between two triangles.
const bary_eps: f32 = 1e-6;

pub const TriHit = struct {
    t: f32,
    /// Barycentric weights of `b` and `c` (`a` has `1 - u - v`).
    u: f32,
    v: f32,
    /// True when the ray hit the side the winding calls the back.
    back: bool,
};

/// Moller-Trumbore. Triangles are two-sided unless `cull_back`. Counter-
/// clockwise (as seen by the viewer) is front. `t >= 0` along `ray.dir`
/// (not required to be unit). Parallel and degenerate triangles miss.
pub fn rayTriangle(ray: Ray, a: Vec3, b: Vec3, c: Vec3, cull_back: bool) ?TriHit {
    const e1 = mat.sub(b, a);
    const e2 = mat.sub(c, a);
    const p = mat.cross(ray.dir, e2);
    const det = mat.dot(e1, p);
    const scale_ref = mat.length(e1) * mat.length(e2) * mat.length(ray.dir);
    if (!(@abs(det) > 1e-7 * scale_ref)) return null; // parallel / degenerate / NaN
    const back = det < 0;
    if (back and cull_back) return null;
    const inv = 1 / det;
    const s = mat.sub(ray.origin, a);
    const u = mat.dot(s, p) * inv;
    if (u < -bary_eps or u > 1 + bary_eps) return null;
    const q = mat.cross(s, e1);
    const v = mat.dot(ray.dir, q) * inv;
    if (v < -bary_eps or u + v > 1 + bary_eps) return null;
    const t = mat.dot(e2, q) * inv;
    if (t < 0) return null;
    return .{ .t = t, .u = u, .v = v, .back = back };
}

/// Slab test. Returns the entry distance (0 when the origin is inside), or
/// null on a miss. Axis-parallel rays are handled without NaNs.
pub fn rayAabb(ray: Ray, lo: Vec3, hi: Vec3) ?f32 {
    var t0: f32 = 0;
    var t1: f32 = std.math.inf(f32);
    inline for (0..3) |i| {
        const d = ray.dir[i];
        if (d == 0) {
            if (ray.origin[i] < lo[i] or ray.origin[i] > hi[i]) return null;
        } else {
            const inv = 1 / d;
            var a = (lo[i] - ray.origin[i]) * inv;
            var b = (hi[i] - ray.origin[i]) * inv;
            if (a > b) std.mem.swap(f32, &a, &b);
            t0 = @max(t0, a);
            t1 = @min(t1, b);
            if (t0 > t1) return null;
        }
    }
    return t0;
}

/// Mesh-space query. `cut` uses the section convention: hits where
/// `dot(n, p) + d > 0` (the removed half) are ignored.
pub const Query = struct {
    ray: Ray,
    cull_back: bool = false,
    cut: ?[4]f32 = null,
    t_max: f32 = std.math.inf(f32),
};

pub const MeshHit = struct { triangle: u32, tri: TriHit };

fn triVerts(mesh: MeshData, tri: u32) [3]Vec3 {
    const i = @as(usize, tri) * 3;
    return .{
        mesh.vertices[mesh.indices[i]].pos,
        mesh.vertices[mesh.indices[i + 1]].pos,
        mesh.vertices[mesh.indices[i + 2]].pos,
    };
}

fn testTri(mesh: MeshData, tri: u32, q: Query, best_t: f32) ?TriHit {
    const v = triVerts(mesh, tri);
    const h = rayTriangle(q.ray, v[0], v[1], v[2], q.cull_back) orelse return null;
    if (!(h.t < best_t)) return null;
    if (q.cut) |pl| {
        const p = mat.add(q.ray.origin, mat.scale(q.ray.dir, h.t));
        if (mat.dot(.{ pl[0], pl[1], pl[2] }, p) + pl[3] > 0) return null;
    }
    return h;
}

/// Nearest triangle hit by testing every triangle. Reference implementation
/// for the BVH and fine for small meshes.
pub fn nearestBrute(mesh: MeshData, q: Query) ?MeshHit {
    var best: ?MeshHit = null;
    var best_t = q.t_max;
    const n: u32 = @intCast(mesh.indices.len / 3);
    var tri: u32 = 0;
    while (tri < n) : (tri += 1) {
        if (testTri(mesh, tri, q, best_t)) |h| {
            best = .{ .triangle = tri, .tri = h };
            best_t = h.t;
        }
    }
    return best;
}

/// Bounding volume hierarchy over one mesh's triangles (median split on the
/// widest centroid axis). A pure function of the mesh: build it when the mesh
/// content changes and keep it next to the mesh data in the Model.
pub const Bvh = struct {
    nodes: []Node,
    /// Triangle indices, permuted so each leaf owns a contiguous range.
    order: []u32,

    pub const leaf_size = 4;

    pub const Node = struct {
        lo: Vec3,
        hi: Vec3,
        /// Internal: index of the right child (left child is `self + 1`).
        /// Leaf: first entry in `order`.
        a: u32,
        /// Leaf: triangle count (> 0). Internal: 0.
        count: u32,
    };

    pub fn deinit(self: Bvh, gpa: std.mem.Allocator) void {
        gpa.free(self.nodes);
        gpa.free(self.order);
    }

    pub fn bounds(self: Bvh) ?Bounds {
        if (self.nodes.len == 0) return null;
        return .{ .lo = self.nodes[0].lo, .hi = self.nodes[0].hi };
    }

    pub fn build(gpa: std.mem.Allocator, mesh: MeshData) std.mem.Allocator.Error!Bvh {
        const n: u32 = @intCast(mesh.indices.len / 3);
        const order = try gpa.alloc(u32, n);
        errdefer gpa.free(order);
        for (order, 0..) |*o, i| o.* = @intCast(i);
        if (n == 0) return .{ .nodes = try gpa.alloc(Node, 0), .order = order };

        const cent = try gpa.alloc(Vec3, n);
        defer gpa.free(cent);
        for (cent, 0..) |*c, i| {
            const v = triVerts(mesh, @intCast(i));
            c.* = mat.scale(mat.add(mat.add(v[0], v[1]), v[2]), 1.0 / 3.0);
        }
        var nodes = try std.ArrayList(Node).initCapacity(gpa, 2 * @as(usize, n) / leaf_size + 2);
        errdefer nodes.deinit(gpa);
        var b = Builder{ .gpa = gpa, .mesh = mesh, .cent = cent, .order = order, .nodes = &nodes };
        try b.node(0, n);
        return .{ .nodes = try nodes.toOwnedSlice(gpa), .order = order };
    }

    const Builder = struct {
        gpa: std.mem.Allocator,
        mesh: MeshData,
        cent: []const Vec3,
        order: []u32,
        nodes: *std.ArrayList(Node),

        fn node(self: *Builder, first: u32, count: u32) std.mem.Allocator.Error!void {
            var lo: Vec3 = .{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) };
            var hi: Vec3 = .{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) };
            var clo = lo;
            var chi = hi;
            for (self.order[first .. first + count]) |tri| {
                for (triVerts(self.mesh, tri)) |p| {
                    lo = mat.minV(lo, p);
                    hi = mat.maxV(hi, p);
                }
                clo = mat.minV(clo, self.cent[tri]);
                chi = mat.maxV(chi, self.cent[tri]);
            }
            const idx = self.nodes.items.len;
            try self.nodes.append(self.gpa, .{ .lo = lo, .hi = hi, .a = first, .count = count });
            if (count <= leaf_size) return;

            const ext = mat.sub(chi, clo);
            const axis: usize = if (ext[0] >= ext[1] and ext[0] >= ext[2]) 0 else if (ext[1] >= ext[2]) 1 else 2;
            if (!(ext[axis] > 0)) return; // all centroids coincide: keep as a (large) leaf
            const Ctx = struct {
                cent: []const Vec3,
                axis: usize,
                fn less(c: @This(), x: u32, y: u32) bool {
                    return c.cent[x][c.axis] < c.cent[y][c.axis];
                }
            };
            std.mem.sort(u32, self.order[first .. first + count], Ctx{ .cent = self.cent, .axis = axis }, Ctx.less);
            const half = count / 2;
            self.nodes.items[idx].count = 0;
            try self.node(first, half);
            self.nodes.items[idx].a = @intCast(self.nodes.items.len);
            try self.node(first + half, count - half);
        }
    };

    /// Nearest triangle hit, nearest-child-first with distance pruning.
    pub fn nearest(self: Bvh, mesh: MeshData, q: Query) ?MeshHit {
        if (self.nodes.len == 0) return null;
        var best: ?MeshHit = null;
        var best_t = q.t_max;
        var stack: [96]u32 = undefined;
        var sp: usize = 0;
        stack[0] = 0;
        sp = 1;
        while (sp > 0) {
            sp -= 1;
            const nd = self.nodes[stack[sp]];
            const enter = rayAabb(q.ray, nd.lo, nd.hi) orelse continue;
            if (enter > best_t) continue;
            if (nd.count > 0) {
                for (self.order[nd.a .. nd.a + nd.count]) |tri| {
                    if (testTri(mesh, tri, q, best_t)) |h| {
                        best = .{ .triangle = tri, .tri = h };
                        best_t = h.t;
                    }
                }
            } else {
                const l = stack[sp] + 1;
                const r = nd.a;
                const tl = rayAabb(q.ray, self.nodes[l].lo, self.nodes[l].hi) orelse std.math.inf(f32);
                const tr = rayAabb(q.ray, self.nodes[r].lo, self.nodes[r].hi) orelse std.math.inf(f32);
                // push the farther child first so the nearer pops first
                if (tl <= tr) {
                    stack[sp] = r;
                    stack[sp + 1] = l;
                } else {
                    stack[sp] = l;
                    stack[sp + 1] = r;
                }
                sp += 2;
            }
        }
        return best;
    }
};

/// A mesh addressable by `Item.mesh`. `bvh`/`bounds` are optional accelerators.
pub const MeshRef = struct {
    key: u32,
    mesh: MeshData,
    bvh: ?*const Bvh = null,
    bounds: ?Bounds = null,
};

/// One placed instance, the pick-relevant subset of the scene `Item`.
pub const Item = struct {
    /// Resource key, matched against `MeshRef.key`.
    mesh: u32,
    transform: Affine = mat.identity_affine,
    /// Echoed in `Hit.id`; 0 = none.
    id: u32 = 0,
    hidden: bool = false,
    no_pick: bool = false,
};

pub const Options = struct {
    /// Ignore back faces (default: two-sided, matching the renderer).
    cull_back: bool = false,
    /// Section plane (`dot(n, p) + d <= 0` is kept): hits on the removed side are skipped.
    cut: ?[4]f32 = null,
};

pub const Hit = struct {
    id: u32,
    /// Index into the `items` slice.
    item: u32,
    triangle: u32,
    t: f32,
    /// World-space hit point.
    point: Vec3,
    /// World-space unit geometric normal, facing the ray origin.
    normal: Vec3,
};

/// Nearest hit among `list` for a world-space `ray`. Skips `hidden` and
/// `no_pick` items and items whose mesh is unknown or whose transform is
/// singular.
pub fn items(ray: Ray, list: []const Item, meshes: []const MeshRef, opt: Options) ?Hit {
    var best: ?Hit = null;
    var best_t = std.math.inf(f32);
    for (list, 0..) |it, idx| {
        if (it.hidden or it.no_pick) continue;
        const ref = for (meshes) |m| {
            if (m.key == it.mesh) break m;
        } else continue;
        const inv = mat.affineInverse(it.transform) orelse continue;
        const local = Ray{ .origin = mat.affinePoint(inv, ray.origin), .dir = mat.affineDir(inv, ray.dir) };

        var q = Query{ .ray = local, .cull_back = opt.cull_back, .t_max = best_t };
        if (opt.cut) |pl| {
            // n.(M x + t) + d == (M^T n).x + (n.t + d)
            const t = Vec3{ it.transform[3], it.transform[7], it.transform[11] };
            const n = Vec3{ pl[0], pl[1], pl[2] };
            const ln = Vec3{
                it.transform[0] * n[0] + it.transform[4] * n[1] + it.transform[8] * n[2],
                it.transform[1] * n[0] + it.transform[5] * n[1] + it.transform[9] * n[2],
                it.transform[2] * n[0] + it.transform[6] * n[1] + it.transform[10] * n[2],
            };
            q.cut = .{ ln[0], ln[1], ln[2], mat.dot(n, t) + pl[3] };
        }

        const bb: ?Bounds = if (ref.bvh) |b| b.bounds() else ref.bounds;
        if (bb) |b| {
            const enter = rayAabb(local, b.lo, b.hi) orelse continue;
            if (enter > best_t) continue;
        }
        const mh = (if (ref.bvh) |b| b.nearest(ref.mesh, q) else nearestBrute(ref.mesh, q)) orelse continue;
        if (!(mh.tri.t < best_t)) continue;
        best_t = mh.tri.t;

        const v = triVerts(ref.mesh, mh.triangle);
        const nl = mat.cross(mat.sub(v[1], v[0]), mat.sub(v[2], v[0]));
        // normal transforms by the inverse-transpose of the linear part
        var nw = Vec3{
            inv[0] * nl[0] + inv[4] * nl[1] + inv[8] * nl[2],
            inv[1] * nl[0] + inv[5] * nl[1] + inv[9] * nl[2],
            inv[2] * nl[0] + inv[6] * nl[1] + inv[10] * nl[2],
        };
        nw = mat.normalize(nw);
        if (mat.dot(nw, ray.dir) > 0) nw = mat.scale(nw, -1);
        best = .{
            .id = it.id,
            .item = @intCast(idx),
            .triangle = mh.triangle,
            .t = mh.tri.t,
            .point = mat.add(ray.origin, mat.scale(ray.dir, mh.tri.t)),
            .normal = nw,
        };
    }
    return best;
}

// ---------------------------------------------------------------- layers

pub const PlaneHit = struct {
    id: u32,
    /// Index into the `planes` slice.
    index: u32,
    t: f32,
    point: Vec3,
    /// Plane-local coordinates of the hit (the units of `Plane.content`).
    local: [2]f32,
};

/// Nearest plane hit by `ray`: ray-plane intersection then a rect test in
/// plane-local space. Skips `hidden` / `no_pick` planes and, for
/// `double_sided = false`, hits on the back.
pub fn planes(ray: Ray, list: []const scene.Plane) ?PlaneHit {
    var best: ?PlaneHit = null;
    for (list, 0..) |pl, i| {
        if (pl.flags.hidden or pl.flags.no_pick) continue;
        const n = mat.cross(pl.u, pl.v);
        const denom = mat.dot(n, ray.dir);
        const n2 = mat.dot(n, n);
        if (!(n2 > 1e-20) or @abs(denom) < 1e-9 * @sqrt(n2) * mat.length(ray.dir)) continue;
        if (!pl.double_sided and denom > 0) continue; // ray travels along the front normal: from behind
        const t = mat.dot(n, mat.sub(pl.origin, ray.origin)) / denom;
        if (t < 0 or (best != null and t >= best.?.t)) continue;
        const point = mat.add(ray.origin, mat.scale(ray.dir, t));
        const w = mat.sub(point, pl.origin);
        const x = mat.dot(mat.cross(w, pl.v), n) / n2;
        const y = mat.dot(mat.cross(pl.u, w), n) / n2;
        if (x < 0 or y < 0 or x > pl.size[0] or y > pl.size[1]) continue;
        best = .{ .id = pl.id, .index = @intCast(i), .t = t, .point = point, .local = .{ x, y } };
    }
    return best;
}

pub const SpriteHit = struct {
    id: u32,
    index: u32,
    /// NDC depth of the sprite's anchor point (smaller = nearer).
    depth: f32,
};

/// Corners of a sprite's quad in viewport px, in order bottom-left,
/// bottom-right, top-right, top-left, plus the anchor's NDC depth; null when
/// the anchor is behind the camera. `screen_px` camera-facing sprites are
/// exact rects; the other modes project their world-space quad.
pub fn spriteCorners(cam: camera.Camera, w: f32, h: f32, sp: scene.Sprite) ?struct { c: [4][2]f32, depth: f32 } {
    const a = camera.project(cam, w, h, sp.pos) orelse return null;
    const ax = sp.anchor[0];
    const ay = sp.anchor[1];
    if (sp.mode == .camera_facing and sp.size_in == .screen_px) {
        const x0 = a[0] - ax * sp.size[0];
        const y1 = a[1] + ay * sp.size[1]; // screen y is down
        return .{ .c = .{ .{ x0, y1 }, .{ x0 + sp.size[0], y1 }, .{ x0 + sp.size[0], y1 - sp.size[1] }, .{ x0, y1 - sp.size[1] } }, .depth = a[2] };
    }
    const axes = camera.viewAxes(cam);
    var right: Vec3 = axes.right;
    var up: Vec3 = axes.up;
    switch (sp.mode) {
        .camera_facing => {},
        .axis_locked_y => {
            right = mat.normalizeOr(.{ axes.right[0], 0, axes.right[2] }, .{ 1, 0, 0 });
            up = .{ 0, 1, 0 };
        },
        .fixed => {
            right = .{ 1, 0, 0 };
            up = .{ 0, 1, 0 };
        },
    }
    const corners = [4][2]f32{ .{ -ax, -ay }, .{ 1 - ax, -ay }, .{ 1 - ax, 1 - ay }, .{ -ax, 1 - ay } };
    var out: [4][2]f32 = undefined;
    for (corners, 0..) |c, i| {
        const p = mat.add(sp.pos, mat.add(mat.scale(right, c[0] * sp.size[0]), mat.scale(up, c[1] * sp.size[1])));
        const s = camera.project(cam, w, h, p) orelse return null;
        out[i] = .{ s[0], s[1] };
    }
    return .{ .c = out, .depth = a[2] };
}

/// Nearest sprite under viewport-local px `(x, y)`, by quad containment.
pub fn sprites(cam: camera.Camera, w: f32, h: f32, x: f32, y: f32, list: []const scene.Sprite) ?SpriteHit {
    var best: ?SpriteHit = null;
    for (list, 0..) |sp, i| {
        if (sp.flags.hidden or sp.flags.no_pick) continue;
        const q = spriteCorners(cam, w, h, sp) orelse continue;
        if (best != null and q.depth >= best.?.depth) continue;
        // inside a convex quad: all edge cross products share a sign
        var pos: u32 = 0;
        var neg: u32 = 0;
        for (0..4) |k| {
            const a = q.c[k];
            const b = q.c[(k + 1) % 4];
            const cr = (b[0] - a[0]) * (y - a[1]) - (b[1] - a[1]) * (x - a[0]);
            if (cr > 0) pos += 1 else if (cr < 0) neg += 1;
        }
        if (pos != 0 and neg != 0) continue;
        best = .{ .id = sp.id, .index = @intCast(i), .depth = q.depth };
    }
    return best;
}

// ---------------------------------------------------------------- gizmo

pub const Corner = enum { top_left, top_right, bottom_left, bottom_right };

/// Placement of the corner axis gizmo inside a viewport (logical px).
pub const GizmoLayout = struct {
    corner: Corner = .bottom_left,
    size_px: f32 = 72,
    margin_px: f32 = 8,
};

/// A gizmo end cap: world axis (0=x, 1=y, 2=z) and sign.
pub const GizmoAxis = struct {
    axis: u2,
    positive: bool,

    /// The camera preset that looks down this axis end (view-cube click).
    pub fn preset(self: GizmoAxis, up: @FieldType(camera.Orbit, "up")) camera.Orbit.Preset {
        const P = camera.Orbit.Preset;
        return switch (up) {
            .y => switch (self.axis) {
                0 => if (self.positive) P.right else P.left,
                1 => if (self.positive) P.top else P.bottom,
                else => if (self.positive) P.front else P.back,
            },
            .z => switch (self.axis) {
                0 => if (self.positive) P.right else P.left,
                1 => if (self.positive) P.back else P.front,
                else => if (self.positive) P.top else P.bottom,
            },
        };
    }
};

/// Gizmo square `{x, y, w, h}` in viewport px.
pub fn gizmoRect(l: GizmoLayout, w: f32, h: f32) [4]f32 {
    const x = switch (l.corner) {
        .top_left, .bottom_left => l.margin_px,
        .top_right, .bottom_right => w - l.margin_px - l.size_px,
    };
    const y = switch (l.corner) {
        .top_left, .top_right => l.margin_px,
        .bottom_left, .bottom_right => h - l.margin_px - l.size_px,
    };
    return .{ x, y, l.size_px, l.size_px };
}

pub const GizmoTip = struct {
    axis: GizmoAxis,
    /// Cap center in viewport px (also where a label anchors).
    x: f32,
    y: f32,
    /// > 0 when the cap points toward the camera.
    depth: f32,
};

/// The six end caps in `+x,-x,+y,-y,+z,-z` order, positioned by the camera's
/// current orientation (the gizmo draws the same projection).
pub fn gizmoTips(orbit: camera.Orbit, l: GizmoLayout, w: f32, h: f32) [6]GizmoTip {
    const r = gizmoRect(l, w, h);
    const cx = r[0] + r[2] * 0.5;
    const cy = r[1] + r[3] * 0.5;
    const len = r[2] * 0.5 * 0.75;
    const bs = orbit.basis();
    var out: [6]GizmoTip = undefined;
    for (0..6) |i| {
        const axis: u2 = @intCast(i / 2);
        const positive = i % 2 == 0;
        var a = Vec3{ 0, 0, 0 };
        a[axis] = if (positive) 1 else -1;
        out[i] = .{
            .axis = .{ .axis = axis, .positive = positive },
            .x = cx + mat.dot(a, bs.right) * len,
            .y = cy - mat.dot(a, bs.up) * len,
            .depth = -mat.dot(a, bs.forward),
        };
    }
    return out;
}

/// An axis letter to draw as ordinary 2D text over the 3D viewport.
pub const GizmoLabel = struct {
    text: []const u8,
    /// Centre of the letter in the coordinate space of the `origin` passed to
    /// `gizmoLabels` (window space when that is the canvas's window origin).
    x: f32,
    y: f32,
    axis: u2,
};

/// Letters for the three positive gizmo caps, pushed `gap_px` outward from the
/// gizmo centre past the arrow tip. `origin` is the viewport's top-left in the
/// space the app draws text in: the window origin delivered by the canvas
/// `layout` event, so the result can be emitted as overlay text:
///
///     for (pick.gizmoLabels(cam, layout, w, h, ox, oy, 9)) |l|
///         { cb.pushOverlay(.{ .x = l.x - 4, .y = l.y - 9, ... }); cb.text(l.text); cb.popOverlay(); }
///
/// Labels of axes pointing at the camera (their cap sits on the centre) are
/// kept at the cap, so they never fly off in a random direction.
pub fn gizmoLabels(orbit: camera.Orbit, l: GizmoLayout, w: f32, h: f32, ox: f32, oy: f32, gap_px: f32) [3]GizmoLabel {
    const r = gizmoRect(l, w, h);
    const cx = r[0] + r[2] * 0.5;
    const cy = r[1] + r[3] * 0.5;
    const tips = gizmoTips(orbit, l, w, h);
    const names = [3][]const u8{ "X", "Y", "Z" };
    var out: [3]GizmoLabel = undefined;
    for (0..3) |a| {
        const tip = tips[a * 2];
        const dx = tip.x - cx;
        const dy = tip.y - cy;
        const len = @sqrt(dx * dx + dy * dy);
        const k = if (len > 1e-3) gap_px / len else 0;
        out[a] = .{ .text = names[a], .x = ox + tip.x + dx * k, .y = oy + tip.y + dy * k, .axis = @intCast(a) };
    }
    return out;
}

/// Which gizmo cap (if any) is under viewport px `(x, y)`. Overlapping caps
/// resolve to the one nearest the camera.
pub fn gizmoHit(orbit: camera.Orbit, l: GizmoLayout, w: f32, h: f32, x: f32, y: f32) ?GizmoAxis {
    const radius = l.size_px * 0.12;
    var best: ?GizmoTip = null;
    for (gizmoTips(orbit, l, w, h)) |tip| {
        const dx = x - tip.x;
        const dy = y - tip.y;
        if (dx * dx + dy * dy > radius * radius) continue;
        if (best == null or tip.depth > best.?.depth) best = tip;
    }
    return if (best) |b| b.axis else null;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const approx = testing.expectApproxEqAbs;

fn vtx(p: Vec3) scene.MeshVertex {
    return .{ .pos = p, .normal = .{ 0, 0, 1 }, .color = .{ 1, 1, 1, 1 } };
}

/// Unit cube [0,1]^3, 12 outward-facing (CCW from outside) triangles, shared
/// 8 vertices.
const cube_verts = [8]scene.MeshVertex{
    vtx(.{ 0, 0, 0 }), vtx(.{ 1, 0, 0 }), vtx(.{ 1, 1, 0 }), vtx(.{ 0, 1, 0 }),
    vtx(.{ 0, 0, 1 }), vtx(.{ 1, 0, 1 }), vtx(.{ 1, 1, 1 }), vtx(.{ 0, 1, 1 }),
};
const cube_idx = [36]u32{
    0, 3, 2, 0, 2, 1, // -z
    4, 5, 6, 4, 6, 7, // +z
    0, 1, 5, 0, 5, 4, // -y
    3, 7, 6, 3, 6, 2, // +y
    0, 4, 7, 0, 7, 3, // -x
    1, 2, 6, 1, 6, 5, // +x
};
const cube = MeshData{ .vertices = &cube_verts, .indices = &cube_idx };

test "ray-triangle: hit, parallel, behind, back-face, edges" {
    const a = Vec3{ 0, 0, 0 };
    const b = Vec3{ 1, 0, 0 };
    const c = Vec3{ 0, 1, 0 };
    // front-facing: CCW seen from +z; ray travels -z.
    const down = Ray{ .origin = .{ 0.25, 0.25, 2 }, .dir = .{ 0, 0, -1 } };
    const h = rayTriangle(down, a, b, c, false).?;
    try approx(@as(f32, 2), h.t, 1e-6);
    try approx(@as(f32, 0.25), h.u, 1e-6);
    try approx(@as(f32, 0.25), h.v, 1e-6);
    try testing.expect(!h.back);
    // from below: back face; hit when two-sided, miss when culled
    const up = Ray{ .origin = .{ 0.25, 0.25, -2 }, .dir = .{ 0, 0, 1 } };
    try testing.expect(rayTriangle(up, a, b, c, false).?.back);
    try testing.expect(rayTriangle(up, a, b, c, true) == null);
    // parallel to the plane
    try testing.expect(rayTriangle(.{ .origin = .{ 0.2, 0.2, 1 }, .dir = .{ 1, 0, 0 } }, a, b, c, false) == null);
    // triangle behind the origin
    try testing.expect(rayTriangle(.{ .origin = .{ 0.25, 0.25, 2 }, .dir = .{ 0, 0, 1 } }, a, b, c, false) == null);
    // outside
    try testing.expect(rayTriangle(.{ .origin = .{ 0.8, 0.8, 2 }, .dir = .{ 0, 0, -1 } }, a, b, c, false) == null);
    // exactly on an edge, a vertex, and the hypotenuse
    try testing.expect(rayTriangle(.{ .origin = .{ 0.5, 0, 1 }, .dir = .{ 0, 0, -1 } }, a, b, c, false) != null);
    try testing.expect(rayTriangle(.{ .origin = .{ 0, 0, 1 }, .dir = .{ 0, 0, -1 } }, a, b, c, false) != null);
    try testing.expect(rayTriangle(.{ .origin = .{ 0.5, 0.5, 1 }, .dir = .{ 0, 0, -1 } }, a, b, c, false) != null);
    // degenerate triangle never hits
    try testing.expect(rayTriangle(down, a, a, c, false) == null);
    // unnormalized dir: t scales inversely
    const h2 = rayTriangle(.{ .origin = .{ 0.25, 0.25, 2 }, .dir = .{ 0, 0, -2 } }, a, b, c, false).?;
    try approx(@as(f32, 1), h2.t, 1e-6);
}

test "ray-aabb: hit, miss, inside, axis-parallel" {
    const lo = Vec3{ 0, 0, 0 };
    const hi = Vec3{ 1, 1, 1 };
    try approx(@as(f32, 2), rayAabb(.{ .origin = .{ 0.5, 0.5, 3 }, .dir = .{ 0, 0, -1 } }, lo, hi).?, 1e-6);
    try testing.expect(rayAabb(.{ .origin = .{ 1.5, 0.5, 3 }, .dir = .{ 0, 0, -1 } }, lo, hi) == null);
    try approx(@as(f32, 0), rayAabb(.{ .origin = .{ 0.5, 0.5, 0.5 }, .dir = .{ 1, 0, 0 } }, lo, hi).?, 0);
    try testing.expect(rayAabb(.{ .origin = .{ 0.5, 0.5, 3 }, .dir = .{ 0, 0, 1 } }, lo, hi) == null);
    try testing.expect(rayAabb(.{ .origin = .{ 0.5, 2, 0.5 }, .dir = .{ 1, 0, 0 } }, lo, hi) == null);
    try approx(@as(f32, 1.5), rayAabb(.{ .origin = .{ -1.5, 0.5, 0.5 }, .dir = .{ 1, 0, 0 } }, lo, hi).?, 1e-6);
}

test "items: nearest wins, transforms, id, hidden/no_pick, cut" {
    const meshes = [_]MeshRef{.{ .key = 7, .mesh = cube }};
    var list = [_]Item{
        .{ .mesh = 7, .id = 1 },
        .{ .mesh = 7, .id = 2, .transform = mat.translation(.{ 0, 0, 3 }) },
        .{ .mesh = 7, .id = 3, .transform = mat.translation(.{ 0, 0, -3 }) },
        .{ .mesh = 99, .id = 4 }, // unknown mesh
    };
    const ray = Ray{ .origin = .{ 0.5, 0.5, 10 }, .dir = .{ 0, 0, -1 } };
    var h = items(ray, &list, &meshes, .{}).?;
    try testing.expectEqual(@as(u32, 2), h.id); // z in [3,4] is nearest
    try approx(@as(f32, 6), h.t, 1e-5);
    try approx(@as(f32, 4), h.point[2], 1e-5);
    try approx(@as(f32, 1), h.normal[2], 1e-5); // faces the ray
    list[1].no_pick = true;
    h = items(ray, &list, &meshes, .{}).?;
    try testing.expectEqual(@as(u32, 1), h.id);
    list[0].hidden = true;
    h = items(ray, &list, &meshes, .{}).?;
    try testing.expectEqual(@as(u32, 3), h.id);
    list[2].hidden = true;
    try testing.expect(items(ray, &list, &meshes, .{}) == null);

    // Cut keeps dot(n,p)+d <= 0. Plane z = 0.75 keeping z <= 0.75: the top of item 1
    // is removed so the ray enters the interior and hits its inside (back) face at z=0.
    list[0].hidden = false;
    h = items(ray, &list, &meshes, .{ .cut = .{ 0, 0, 1, -0.75 } }).?;
    try testing.expectEqual(@as(u32, 1), h.id);
    try approx(@as(f32, 0), h.point[2], 1e-5);
    // cull_back plus cut: only the inside back face remains, so it misses
    try testing.expect(items(ray, &list, &meshes, .{ .cut = .{ 0, 0, 1, -0.75 }, .cull_back = true }) == null);
    // Cut in world space accounts for the item transform.
    list[0].transform = mat.translation(.{ 0, 0, 3 });
    h = items(ray, &list, &meshes, .{ .cut = .{ 0, 0, 1, -3.75 } }).?;
    try approx(@as(f32, 3), h.point[2], 1e-5);
}

test "items: scaled+rotated transform and normal" {
    // 90 degrees about z, scale 2 in x.  local (x,y,z) -> (-y, 2x, z) style: rows
    const xf: Affine = .{ 0, -1, 0, 0, 2, 0, 0, 0, 0, 0, 1, 0 };
    const meshes = [_]MeshRef{.{ .key = 1, .mesh = cube }};
    const list = [_]Item{.{ .mesh = 1, .id = 5, .transform = xf }};
    // world cube spans x in [-1,0], y in [0,2]. Shoot from +x down -x at y=1, z=.5.
    const h = items(.{ .origin = .{ 5, 1, 0.5 }, .dir = .{ -1, 0, 0 } }, &list, &meshes, .{}).?;
    try approx(@as(f32, 5), h.t, 1e-5);
    try approx(@as(f32, 0), h.point[0], 1e-5);
    try approx(@as(f32, 1), h.normal[0], 1e-5);
    try approx(@as(f32, 0), h.normal[1], 1e-5);
    // singular transform is skipped
    const sing = [_]Item{.{ .mesh = 1, .transform = .{ 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 } }};
    try testing.expect(items(.{ .origin = .{ 5, 1, 0.5 }, .dir = .{ -1, 0, 0 } }, &sing, &meshes, .{}) == null);
}

test "BVH equals brute force on random rays (cube grid mesh)" {
    const gpa = testing.allocator;
    // 6x6x6 field of small cubes with varying offsets -> 2592 triangles
    var verts: std.ArrayList(scene.MeshVertex) = .empty;
    defer verts.deinit(gpa);
    var idx: std.ArrayList(u32) = .empty;
    defer idx.deinit(gpa);
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const rnd = prng.random();
    for (0..216) |k| {
        const ox: f32 = @floatFromInt(k % 6);
        const oy: f32 = @floatFromInt((k / 6) % 6);
        const oz: f32 = @floatFromInt(k / 36);
        const base: u32 = @intCast(verts.items.len);
        const jitter = rnd.float(f32) * 0.2;
        for (cube_verts) |cv| try verts.append(gpa, vtx(.{ cv.pos[0] * 0.7 + ox * 1.5, cv.pos[1] * 0.7 + oy * 1.5 + jitter, cv.pos[2] * 0.7 + oz * 1.5 }));
        for (cube_idx) |i| try idx.append(gpa, base + i);
    }
    const mesh = MeshData{ .vertices = verts.items, .indices = idx.items };
    const bvh = try Bvh.build(gpa, mesh);
    defer bvh.deinit(gpa);
    try testing.expect(bvh.nodes.len > 1);

    var hits: u32 = 0;
    for (0..400) |_| {
        const o = Vec3{ rnd.float(f32) * 14 - 3, rnd.float(f32) * 14 - 3, rnd.float(f32) * 14 - 3 };
        const tgt = Vec3{ rnd.float(f32) * 9, rnd.float(f32) * 9, rnd.float(f32) * 9 };
        const q = Query{ .ray = .{ .origin = o, .dir = mat.normalize(mat.sub(tgt, o)) }, .cull_back = rnd.boolean() };
        const a = nearestBrute(mesh, q);
        const b = bvh.nearest(mesh, q);
        try testing.expectEqual(a == null, b == null);
        if (a) |ha| {
            hits += 1;
            try approx(ha.tri.t, b.?.tri.t, 1e-5);
        }
    }
    try testing.expect(hits > 50);
}

test "BVH on empty and tiny meshes" {
    const gpa = testing.allocator;
    const empty = try Bvh.build(gpa, .{});
    defer empty.deinit(gpa);
    try testing.expect(empty.nearest(.{}, .{ .ray = .{ .origin = .{ 0, 0, 0 }, .dir = .{ 0, 0, 1 } } }) == null);
    const bvh = try Bvh.build(gpa, cube);
    defer bvh.deinit(gpa);
    const meshes = [_]MeshRef{.{ .key = 1, .mesh = cube, .bvh = &bvh }};
    const list = [_]Item{.{ .mesh = 1, .id = 9 }};
    const h = items(.{ .origin = .{ 0.5, 0.5, 5 }, .dir = .{ 0, 0, -1 } }, &list, &meshes, .{}).?;
    try testing.expectEqual(@as(u32, 9), h.id);
    try approx(@as(f32, 4), h.t, 1e-5);
    try testing.expect(items(.{ .origin = .{ 2.5, 0.5, 5 }, .dir = .{ 0, 0, -1 } }, &list, &meshes, .{}) == null);
}

test "end to end: click pixel -> ray -> item" {
    var o = camera.Orbit{ .target = .{ 0.5, 0.5, 0.5 }, .dist = 6 };
    o.setPreset(.iso);
    const cam = o.camera(800, 600, null);
    const meshes = [_]MeshRef{.{ .key = 1, .mesh = cube, .bounds = .{ .lo = .{ 0, 0, 0 }, .hi = .{ 1, 1, 1 } } }};
    const list = [_]Item{.{ .mesh = 1, .id = 11 }};
    const r = camera.pickRay(cam, 800, 600, 400, 300);
    const h = items(r, &list, &meshes, .{}).?;
    try testing.expectEqual(@as(u32, 11), h.id);
    // the corner pixel misses
    const r2 = camera.pickRay(cam, 800, 600, 5, 5);
    try testing.expect(items(r2, &list, &meshes, .{}) == null);
    // hit point projects back to the clicked pixel
    const s = camera.project(cam, 800, 600, h.point).?;
    try approx(@as(f32, 400), s[0], 0.05);
    try approx(@as(f32, 300), s[1], 0.05);
}

test "planes: nearest hit, local coords, back-face and flags" {
    const none: [0]scene.Plane = .{};
    try testing.expect(planes(.{ .origin = .{ 0, 0, 5 }, .dir = .{ 0, 0, -1 } }, &none) == null);
    var list = [_]scene.Plane{
        // 4x2 sheet in the XY plane at z = 0, +z front
        .{ .origin = .{ 0, 0, 0 }, .u = .{ 1, 0, 0 }, .v = .{ 0, 1, 0 }, .size = .{ 4, 2 }, .id = 1 },
        // a nearer one at z = 1
        .{ .origin = .{ 0, 0, 1 }, .u = .{ 1, 0, 0 }, .v = .{ 0, 1, 0 }, .size = .{ 4, 2 }, .id = 2 },
    };
    const down = Ray{ .origin = .{ 3, 1.5, 10 }, .dir = .{ 0, 0, -1 } };
    const h = planes(down, &list).?;
    try testing.expectEqual(@as(u32, 2), h.id);
    try approx(@as(f32, 9), h.t, 1e-5);
    try approx(@as(f32, 3), h.local[0], 1e-5);
    try approx(@as(f32, 1.5), h.local[1], 1e-5);
    // off the sheet
    try testing.expect(planes(.{ .origin = .{ 5, 1, 10 }, .dir = .{ 0, 0, -1 } }, &list) == null);
    // hidden / no_pick: fall through to the one behind
    list[1].flags.hidden = true;
    try testing.expectEqual(@as(u32, 1), planes(down, &list).?.id);
    list[1].flags.hidden = false;
    list[1].flags.no_pick = true;
    try testing.expectEqual(@as(u32, 1), planes(down, &list).?.id);
    // one-sided: a ray from behind misses, from the front hits
    list[0].double_sided = false;
    list[1].flags.no_pick = false;
    list[1].flags.hidden = true;
    try testing.expect(planes(.{ .origin = .{ 3, 1.5, -10 }, .dir = .{ 0, 0, 1 } }, &list) == null);
    try testing.expect(planes(down, &list) != null);
    // a tilted sheet: local coordinates follow the axes
    const tilt = [_]scene.Plane{.{ .origin = .{ 0, 0, 0 }, .u = .{ 0, 0, 1 }, .v = .{ 0, 1, 0 }, .size = .{ 10, 10 } }};
    const th = planes(.{ .origin = .{ 5, 2, 3 }, .dir = .{ -1, 0, 0 } }, &tilt).?;
    try approx(@as(f32, 3), th.local[0], 1e-5);
    try approx(@as(f32, 2), th.local[1], 1e-5);
}

test "sprites: screen_px rects, anchor, nearest, billboards in world size" {
    var o = camera.Orbit{ .dist = 10 };
    o.setPreset(.front);
    const cam = o.camera(400, 400, null);
    const centre = camera.project(cam, 400, 400, .{ 0, 0, 0 }).?;
    var list = [_]scene.Sprite{
        .{ .pos = .{ 0, 0, 0 }, .image = 1, .size = .{ 40, 20 }, .id = 7 },
        // anchored at its bottom-left: extends right and up from its position
        .{ .pos = .{ 0, 0, 0 }, .image = 1, .size = .{ 40, 20 }, .anchor = .{ 0, 0 }, .id = 8 },
    };
    // inside only the first (centred): left of the anchor
    try testing.expectEqual(@as(u32, 7), sprites(cam, 400, 400, centre[0] - 15, centre[1], &list).?.id);
    // up-right of the anchor point is inside both; equal depth keeps the first found
    try testing.expect(sprites(cam, 400, 400, centre[0] + 15, centre[1] - 5, &list) != null);
    // below-right is inside neither anchored rect... (rect 2 is above the anchor)
    try testing.expectEqual(@as(u32, 7), sprites(cam, 400, 400, centre[0] + 15, centre[1] + 5, &list).?.id);
    try testing.expect(sprites(cam, 400, 400, centre[0] + 60, centre[1], &list) == null);
    // nearer sprite wins
    list[1] = .{ .pos = .{ 0, 0, 3 }, .image = 1, .size = .{ 40, 20 }, .id = 9 };
    try testing.expectEqual(@as(u32, 9), sprites(cam, 400, 400, centre[0], centre[1], &list).?.id);
    // world-size billboard: 2 units wide is wider than the 1 unit one
    const world = [_]scene.Sprite{.{ .pos = .{ 0, 0, 0 }, .image = 1, .size = .{ 2, 2 }, .size_in = .world, .id = 5 }};
    const px_per_unit = (camera.project(cam, 400, 400, .{ 1, 0, 0 }).?[0] - centre[0]);
    try testing.expectEqual(@as(u32, 5), sprites(cam, 400, 400, centre[0] + 0.9 * px_per_unit, centre[1], &world).?.id);
    try testing.expect(sprites(cam, 400, 400, centre[0] + 1.2 * px_per_unit, centre[1], &world) == null);
    // hidden and no_pick are skipped
    list[0].flags.no_pick = true;
    list[1].flags.hidden = true;
    try testing.expect(sprites(cam, 400, 400, centre[0], centre[1], &list) == null);
}

test "gizmoLabels: positive caps pushed outward and offset by the viewport origin" {
    var o = camera.Orbit{};
    o.setPreset(.front);
    const l = GizmoLayout{};
    const tips = gizmoTips(o, l, 800, 600);
    const labels = gizmoLabels(o, l, 800, 600, 100, 50, 10);
    try testing.expectEqualStrings("X", labels[0].text);
    try testing.expectEqualStrings("Z", labels[2].text);
    // +x points right: its label sits 10px further right than the cap, at the same height
    try approx(100 + tips[0].x + 10, labels[0].x, 1e-3);
    try approx(50 + tips[0].y, labels[0].y, 1e-3);
    // +y points up: label above the cap
    try approx(50 + tips[2].y - 10, labels[1].y, 1e-3);
    // +z faces the camera (cap at the centre): the label stays on the cap
    try approx(100 + tips[4].x, labels[2].x, 1e-3);
    try approx(50 + tips[4].y, labels[2].y, 1e-3);
}

test "gizmo: layout, hit and presets" {
    var o = camera.Orbit{};
    o.setPreset(.front);
    const l = GizmoLayout{};
    const r = gizmoRect(l, 800, 600);
    try approx(@as(f32, 8), r[0], 0);
    try approx(@as(f32, 600 - 8 - 72), r[1], 0);
    const tr = gizmoRect(.{ .corner = .top_right }, 800, 600);
    try approx(@as(f32, 800 - 8 - 72), tr[0], 0);
    try approx(@as(f32, 8), tr[1], 0);

    const tips = gizmoTips(o, l, 800, 600);
    // front view: +x right, +y up of the gizmo center
    const cx = r[0] + 36;
    const cy = r[1] + 36;
    try testing.expect(tips[0].x > cx and approxEq(tips[0].y, cy));
    try testing.expect(tips[2].y < cy and approxEq(tips[2].x, cx));
    // +z points at the camera (depth > 0) and sits at the center
    try testing.expect(tips[4].depth > 0.99);
    // click on +x cap
    const hit = gizmoHit(o, l, 800, 600, tips[0].x, tips[0].y).?;
    try testing.expectEqual(@as(u2, 0), hit.axis);
    try testing.expect(hit.positive);
    // +z (toward camera) and -z coincide at the center: nearest wins
    const hz = gizmoHit(o, l, 800, 600, cx, cy).?;
    try testing.expectEqual(@as(u2, 2), hz.axis);
    try testing.expect(hz.positive);
    // miss far away
    try testing.expect(gizmoHit(o, l, 800, 600, 600, 100) == null);

    try testing.expectEqual(camera.Orbit.Preset.top, (GizmoAxis{ .axis = 1, .positive = true }).preset(.y));
    try testing.expectEqual(camera.Orbit.Preset.top, (GizmoAxis{ .axis = 2, .positive = true }).preset(.z));
    try testing.expectEqual(camera.Orbit.Preset.front, (GizmoAxis{ .axis = 1, .positive = false }).preset(.z));
    try testing.expectEqual(camera.Orbit.Preset.left, (GizmoAxis{ .axis = 0, .positive = false }).preset(.y));
}

fn approxEq(a: f32, b: f32) bool {
    return @abs(a - b) < 1e-3;
}

// ---- Kerf mesh fixture (a copy of engines/zig/tests/golden/*/mesh.json)

const KerfPart = struct {
    positions: []const f32,
    indices: []const u32,
};
const KerfMesh = struct { parts: []const KerfPart };

test "Kerf mesh fixture: ray through the model center hits, outside misses" {
    const gpa = testing.allocator;
    const parsed = try std.json.parseFromSlice(KerfMesh, gpa, @embedFile("testdata/kerf_mesh_small.json"), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const parts = parsed.value.parts;
    try testing.expect(parts.len > 0);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const refs = try arena.alloc(MeshRef, parts.len);
    const its = try arena.alloc(Item, parts.len);
    var lo = Vec3{ 1e30, 1e30, 1e30 };
    var hi = Vec3{ -1e30, -1e30, -1e30 };
    for (parts, 0..) |p, i| {
        const nv = p.positions.len / 3;
        const vs = try arena.alloc(scene.MeshVertex, nv);
        for (vs, 0..) |*v, k| {
            v.* = vtx(.{ p.positions[3 * k], p.positions[3 * k + 1], p.positions[3 * k + 2] });
            lo = mat.minV(lo, v.pos);
            hi = mat.maxV(hi, v.pos);
        }
        const mesh = MeshData{ .vertices = vs, .indices = p.indices };
        try mesh.validate();
        const bvh = try arena.create(Bvh);
        bvh.* = try Bvh.build(arena, mesh);
        refs[i] = .{ .key = @intCast(i + 1), .mesh = mesh, .bvh = bvh };
        its[i] = .{ .mesh = @intCast(i + 1), .id = @intCast(i + 1) };
    }

    var o = camera.Orbit{};
    o.setPreset(.iso);
    o.frame(lo, hi, 4.0 / 3.0);
    const cam = o.camera(800, 600, .{ .lo = lo, .hi = hi });
    // Center-of-model ray: shoot from the camera at the bounds center. Every
    // Kerf assembly is solid at (or near) its center along some ray; aim at
    // the bounds center from three presets and require a hit from at least one,
    // and the hit point must lie inside the (slightly padded) bounds.
    var got: u32 = 0;
    for ([_]camera.Orbit.Preset{ .iso, .front, .top, .right }) |pr| {
        o.setPreset(pr);
        const c = o.camera(800, 600, .{ .lo = lo, .hi = hi });
        const r = camera.pickRay(c, 800, 600, 400, 300);
        if (items(r, its, refs, .{})) |h| {
            got += 1;
            for (0..3) |k| {
                try testing.expect(h.point[k] >= lo[k] - 1e-2 and h.point[k] <= hi[k] + 1e-2);
            }
            try testing.expect(h.id >= 1 and h.id <= parts.len);
        }
    }
    try testing.expect(got >= 1);
    // BVH result equals brute force for the center ray.
    const r = camera.pickRay(cam, 800, 600, 400, 300);
    var brute_best: f32 = std.math.inf(f32);
    for (refs) |ref| if (nearestBrute(ref.mesh, .{ .ray = r })) |h| {
        brute_best = @min(brute_best, h.tri.t);
    };
    if (items(r, its, refs, .{})) |h| try approx(brute_best, h.t, 1e-3);
    // A ray far outside the model misses everything.
    try testing.expect(items(.{ .origin = .{ lo[0] - 100, lo[1] - 100, lo[2] - 100 }, .dir = .{ -1, 0, 0 } }, its, refs, .{}) == null);
}
