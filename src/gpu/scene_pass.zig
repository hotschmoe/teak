//! Backend-neutral plan of what a scene slot draws: the packed per-instance
//! records, the runs of items that share a mesh (one instanced draw each),
//! and the content hash that decides whether the slot must be re-rendered.
//! Pure functions over `teak` data; `wgpu_scene.zig` and `web_scene.zig`
//! only translate the plan into API calls, so native and web agree by
//! construction. See docs/features/scene.md section 4.3.

const std = @import("std");
const teak = @import("teak");

const SceneDraw = teak.SceneDraw;
const Item = teak.SceneItem;

/// One instance as the vertex stage reads it (`shaders/scene.wgsl`
/// `@location(4..8)`): three rows of the 3x4 transform, tint, id and flags.
pub const Packed = extern struct {
    m0: [4]f32,
    m1: [4]f32,
    m2: [4]f32,
    tint: [4]f32,
    id: u32,
    /// `ItemFlags` bits: 0 hidden, 1 unlit, 2 no_edges, 3 no_pick, 4 highlight.
    flags: u32,
    _pad: [2]u32 = .{ 0, 0 },
};

pub const flag_unlit: u32 = 1 << 1;
pub const flag_no_edges: u32 = 1 << 2;
pub const flag_highlight: u32 = 1 << 4;

/// Items `first .. first + count` of `Plan.insts` all use backend mesh `mesh`.
pub const Run = struct { mesh: u32, first: u32, count: u32 };

pub fn pack(it: Item) Packed {
    const t = it.transform;
    return .{
        .m0 = .{ t[0], t[1], t[2], t[3] },
        .m1 = .{ t[4], t[5], t[6], t[7] },
        .m2 = .{ t[8], t[9], t[10], t[11] },
        .tint = it.tint,
        .id = it.id,
        .flags = @as(u8, @bitCast(it.flags)),
    };
}

pub const Plan = struct {
    insts: std.ArrayList(Packed) = .empty,
    runs: std.ArrayList(Run) = .empty,
    scratch: std.ArrayList(Keyed) = .empty,

    const Keyed = struct { mesh: u32, idx: u32 };

    pub fn deinit(self: *Plan, gpa: std.mem.Allocator) void {
        self.insts.deinit(gpa);
        self.runs.deinit(gpa);
        self.scratch.deinit(gpa);
    }

    /// Rebuild the plan for `draw`. `items` is the scene's own slice
    /// (`scene_common.itemsOf`), keys already remapped to backend handles;
    /// `ctx.hasMesh(handle)` says whether a handle is resident. A scene with
    /// no items draws `draw.mesh` once, untransformed (the legacy
    /// `scene3d`). Hidden items and unknown meshes are dropped; the rest are
    /// ordered by mesh handle (ties keep their input order), so repeated
    /// parts collapse into one instanced draw.
    pub fn build(self: *Plan, gpa: std.mem.Allocator, draw: SceneDraw, items: []const Item, ctx: anytype) std.mem.Allocator.Error!void {
        self.insts.clearRetainingCapacity();
        self.runs.clearRetainingCapacity();
        self.scratch.clearRetainingCapacity();

        if (draw.item_count == 0 and items.len == 0) {
            if (draw.mesh != 0 and ctx.hasMesh(draw.mesh)) {
                try self.insts.append(gpa, pack(.{ .mesh = draw.mesh }));
                try self.runs.append(gpa, .{ .mesh = draw.mesh, .first = 0, .count = 1 });
            }
            return;
        }
        for (items, 0..) |it, i| {
            if (it.flags.hidden or it.mesh == 0 or !ctx.hasMesh(it.mesh)) continue;
            try self.scratch.append(gpa, .{ .mesh = it.mesh, .idx = @intCast(i) });
        }
        std.mem.sortUnstable(Keyed, self.scratch.items, {}, struct {
            fn less(_: void, a: Keyed, b: Keyed) bool {
                return if (a.mesh != b.mesh) a.mesh < b.mesh else a.idx < b.idx;
            }
        }.less);
        for (self.scratch.items) |k| {
            const pos: u32 = @intCast(self.insts.items.len);
            try self.insts.append(gpa, pack(items[k.idx]));
            if (self.runs.items.len > 0 and self.runs.items[self.runs.items.len - 1].mesh == k.mesh) {
                self.runs.items[self.runs.items.len - 1].count += 1;
            } else {
                try self.runs.append(gpa, .{ .mesh = k.mesh, .first = pos, .count = 1 });
            }
        }
    }

    /// Hash of everything the plan contributes to the picture: the packed
    /// instances, the run structure and each run's mesh version
    /// (`ctx.meshVersion(handle)`), so a re-upload into a reused slot
    /// re-renders.
    pub fn contentHash(self: *const Plan, ctx: anytype) u64 {
        var h = std.hash.Wyhash.init(0x5ce9e);
        h.update(std.mem.sliceAsBytes(self.insts.items));
        for (self.runs.items) |r| {
            h.update(std.mem.asBytes(&r));
            const v: u32 = ctx.meshVersion(r.mesh);
            h.update(std.mem.asBytes(&v));
        }
        return h.final();
    }
};

// ── Grid ───────────────────────────────────────────────────────────

const mat = teak.scene.mat;

/// Uniform block of `shaders/scene_grid.wgsl` (`struct GridU`). 256 bytes.
pub const GridUniform = extern struct {
    view_proj: [16]f32,
    inv_view_proj: [16]f32,
    eye: [4]f32,
    minor: [4]f32,
    major: [4]f32,
    axis_a: [4]f32,
    axis_b: [4]f32,
    /// spacing, major_every, fade distance, plane offset.
    params: [4]f32,
    /// plane id (0 xz, 1 xy, 2 yz), axis line width px, target w, h px.
    plane: [4]f32,
    /// far-plane view distance, 1 when the camera is a perspective.
    extra: [4]f32,
};

/// Uniforms for the grid pass, or null when the camera matrix is singular.
/// `fade_dist == 0` derives the fade distance from the eye's distance to the
/// plane so the grid dissolves toward the horizon at any zoom.
pub fn gridUniform(draw: SceneDraw, grid: teak.scene.Grid, target_w: u32, target_h: u32, scale: f32) ?GridUniform {
    const inv = mat.invert(draw.camera.view_proj) orelse return null;
    const axis: usize = switch (grid.plane) {
        .xz => 1,
        .xy => 2,
        .yz => 0,
    };
    const plane_dist = @abs(draw.camera.eye[axis] - grid.offset);
    // View-space distance of the far plane (`w` of a far-plane point): the
    // shader dissolves the grid before it so there is no hard edge.
    const far_w = blk: {
        var h: [4]f32 = undefined;
        for (0..4) |row| h[row] = inv[8 + row] + inv[12 + row];
        const far_pt = mat.Vec3{ h[0] / h[3], h[1] / h[3], h[2] / h[3] };
        break :blk mat.transformPoint4(draw.camera.view_proj, far_pt)[3];
    };
    const fade = if (grid.fade_dist > 0) grid.fade_dist else @max(plane_dist * 12, grid.spacing * 12);
    return .{
        .view_proj = draw.camera.view_proj,
        .inv_view_proj = inv,
        .eye = .{ draw.camera.eye[0], draw.camera.eye[1], draw.camera.eye[2], 0 },
        .minor = grid.minor,
        .major = grid.major,
        .axis_a = grid.axis_a,
        .axis_b = grid.axis_b,
        .params = .{ grid.spacing, @floatFromInt(@max(grid.major_every, 1)), fade, grid.offset },
        .plane = .{ @floatFromInt(@backingInt(grid.plane)), 1.5 * scale, @floatFromInt(target_w), @floatFromInt(target_h) },
        .extra = .{ far_w, if (draw.camera.view_proj[11] != 0) 1 else 0, 0, 0 },
    };
}

// ── Gizmo ──────────────────────────────────────────────────────────

/// View-space image of the world direction `d`, read off a camera
/// `view_proj` (perspective or orthographic): `(right, up, toward-viewer)`.
/// The projection's x/y scale and w row make this exact for both modes.
pub fn viewDir(view_proj: [16]f32, d: mat.Vec3) mat.Vec3 {
    // Rows of `P * V`: rows 0, 1 (and 2 for ortho) are the unit rows of the
    // view rotation scaled by the projection's diagonal, so dividing by their
    // length recovers the rotation; the w row of a perspective is `-V.row2`.
    const m = view_proj;
    const r0 = mat.Vec3{ m[0], m[4], m[8] };
    const r1 = mat.Vec3{ m[1], m[5], m[9] };
    const r2 = mat.Vec3{ m[2], m[6], m[10] };
    const rw = mat.Vec3{ m[3], m[7], m[11] };
    const x = mat.dot(r0, d) / @max(mat.length(r0), 1e-12);
    const y = mat.dot(r1, d) / @max(mat.length(r1), 1e-12);
    const z = if (m[11] != 0) -mat.dot(rw, d) else -mat.dot(r2, d) / @max(mat.length(r2), 1e-12);
    return .{ x, y, z };
}

/// Rect `{x, y, w, h}` of the gizmo sub-viewport in target pixels.
pub fn gizmoRect(gz: teak.scene.Gizmo, target_w: u32, target_h: u32, scale: f32) [4]f32 {
    const size = gz.size_px * scale;
    const margin = gz.margin_px * scale;
    const tw: f32 = @floatFromInt(target_w);
    const th: f32 = @floatFromInt(target_h);
    const x = switch (gz.corner) {
        .top_left, .bottom_left => margin,
        .top_right, .bottom_right => tw - margin - size,
    };
    const y = switch (gz.corner) {
        .top_left, .top_right => margin,
        .bottom_left, .bottom_right => th - margin - size,
    };
    return .{ x, y, size, size };
}

/// Half extent of the gizmo's own orthographic volume (axes have length 1).
pub const gizmo_extent: f32 = 1.3;
/// Segment pairs produced by `gizmoLines`.
pub const gizmo_segments: usize = 12;

/// Axis triad as line-segment pairs in the gizmo's view-aligned space: a
/// coloured shaft and two arrow barbs per axis, plus a faint stub toward the
/// negative end. Pure; fed to the line pipeline with `gizmoProjection`.
pub fn gizmoLines(view_proj: [16]f32, gz: teak.scene.Gizmo) [gizmo_segments * 2]teak.LineVertex {
    var out: [gizmo_segments * 2]teak.LineVertex = undefined;
    var n: usize = 0;
    for (0..3) |axis| {
        var d: mat.Vec3 = .{ 0, 0, 0 };
        d[axis] = 1;
        const v = viewDir(view_proj, d);
        const col = gz.colors[axis];
        const dim = [4]f32{ col[0], col[1], col[2], col[3] * 0.4 };
        const tip = v;
        // barbs: back from the tip along the shaft, spread across the screen perpendicular
        const len2d = @sqrt(v[0] * v[0] + v[1] * v[1]);
        const dir2: [2]f32 = if (len2d > 1e-3) .{ v[0] / len2d, v[1] / len2d } else .{ 1, 0 };
        const perp: [2]f32 = .{ -dir2[1], dir2[0] };
        const head: f32 = @min(0.22, 0.22 * len2d + 0.04);
        const wing: f32 = 0.09 * @min(1, len2d * 2 + 0.2);
        const b0: mat.Vec3 = .{ tip[0] - dir2[0] * head + perp[0] * wing, tip[1] - dir2[1] * head + perp[1] * wing, tip[2] };
        const b1: mat.Vec3 = .{ tip[0] - dir2[0] * head - perp[0] * wing, tip[1] - dir2[1] * head - perp[1] * wing, tip[2] };
        const neg: mat.Vec3 = mat.scale(v, -0.45);
        const segs = [4][2]teak.LineVertex{
            .{ .{ .pos = .{ 0, 0, 0 }, .color = col }, .{ .pos = tip, .color = col } },
            .{ .{ .pos = tip, .color = col }, .{ .pos = b0, .color = col } },
            .{ .{ .pos = tip, .color = col }, .{ .pos = b1, .color = col } },
            .{ .{ .pos = .{ 0, 0, 0 }, .color = dim }, .{ .pos = neg, .color = dim } },
        };
        for (segs) |sg| {
            out[n] = sg[0];
            out[n + 1] = sg[1];
            n += 2;
        }
    }
    return out;
}

/// `view_proj` for the gizmo pass: orthographic over `+-gizmo_extent`, depth
/// squeezed to 0.5 (the gizmo pipeline ignores the depth buffer).
pub fn gizmoProjection() [16]f32 {
    const e = gizmo_extent;
    return .{
        1 / e, 0,     0,   0,
        0,     1 / e, 0,   0,
        0,     0,     0,   0,
        0,     0,     0.5, 1,
    };
}

// ── Tests ──────────────────────────────────────────────────────────

const TestCtx = struct {
    pub fn hasMesh(_: TestCtx, h: u32) bool {
        return h != 99;
    }
    pub fn meshVersion(_: TestCtx, h: u32) u32 {
        return h * 10;
    }
};

fn draw0() SceneDraw {
    return .{ .mesh = 0, .rect_x = 0, .rect_y = 0, .rect_w = 1, .rect_h = 1, .clip_x = 0, .clip_y = 0, .clip_w = 1, .clip_h = 1 };
}

test "Packed is the 80-byte instance record" {
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(Packed));
}

test "legacy scene: one identity instance of draw.mesh; unknown mesh draws nothing" {
    const gpa = std.testing.allocator;
    var plan: Plan = .{};
    defer plan.deinit(gpa);
    var d = draw0();
    d.mesh = 3;
    try plan.build(gpa, d, &.{}, TestCtx{});
    try std.testing.expectEqual(@as(usize, 1), plan.insts.items.len);
    try std.testing.expectEqual(@as(f32, 1), plan.insts.items[0].m0[0]);
    try std.testing.expectEqual(@as(f32, 1), plan.insts.items[0].m2[2]);
    try std.testing.expectEqual(@as(u32, 3), plan.runs.items[0].mesh);
    d.mesh = 99;
    try plan.build(gpa, d, &.{}, TestCtx{});
    try std.testing.expectEqual(@as(usize, 0), plan.runs.items.len);
}

test "items are grouped by mesh in a stable order; hidden and unknown are dropped" {
    const gpa = std.testing.allocator;
    var plan: Plan = .{};
    defer plan.deinit(gpa);
    const items = [_]Item{
        .{ .mesh = 5, .id = 1 },
        .{ .mesh = 2, .id = 2 },
        .{ .mesh = 5, .id = 3, .tint = .{ 1, 0, 0, 1 } },
        .{ .mesh = 99, .id = 4 }, // not resident
        .{ .mesh = 2, .id = 5, .flags = .{ .hidden = true } },
        .{ .mesh = 0, .id = 6 }, // none
        .{ .mesh = 2, .id = 7, .flags = .{ .highlight = true, .no_edges = true } },
    };
    var d = draw0();
    d.item_count = items.len;
    try plan.build(gpa, d, &items, TestCtx{});
    try std.testing.expectEqual(@as(usize, 2), plan.runs.items.len);
    try std.testing.expectEqual(Run{ .mesh = 2, .first = 0, .count = 2 }, plan.runs.items[0]);
    try std.testing.expectEqual(Run{ .mesh = 5, .first = 2, .count = 2 }, plan.runs.items[1]);
    const ids = [_]u32{ 2, 7, 1, 3 };
    for (ids, plan.insts.items) |want, got| try std.testing.expectEqual(want, got.id);
    try std.testing.expect(plan.insts.items[1].flags & flag_highlight != 0);
    try std.testing.expect(plan.insts.items[1].flags & flag_no_edges != 0);
    try std.testing.expectEqual(@as(f32, 1), plan.insts.items[3].tint[0]);
    try std.testing.expectEqual(@as(f32, 0), plan.insts.items[3].tint[1]);
}

test "transform rows are packed row-major with the translation in .w" {
    const p = pack(.{ .mesh = 1, .transform = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 } });
    try std.testing.expectEqual([4]f32{ 1, 2, 3, 4 }, p.m0);
    try std.testing.expectEqual([4]f32{ 5, 6, 7, 8 }, p.m1);
    try std.testing.expectEqual([4]f32{ 9, 10, 11, 12 }, p.m2);
}

test "contentHash reacts to tint, transform, flags, order and mesh version" {
    const gpa = std.testing.allocator;
    var plan: Plan = .{};
    defer plan.deinit(gpa);
    var items = [_]Item{ .{ .mesh = 1, .id = 1 }, .{ .mesh = 2, .id = 2 } };
    var d = draw0();
    d.item_count = 2;
    try plan.build(gpa, d, &items, TestCtx{});
    const base = plan.contentHash(TestCtx{});
    try plan.build(gpa, d, &items, TestCtx{});
    try std.testing.expectEqual(base, plan.contentHash(TestCtx{}));

    items[0].tint[1] = 0.5;
    try plan.build(gpa, d, &items, TestCtx{});
    try std.testing.expect(base != plan.contentHash(TestCtx{}));
    items[0].tint[1] = 1;
    items[1].transform[3] = 4;
    try plan.build(gpa, d, &items, TestCtx{});
    try std.testing.expect(base != plan.contentHash(TestCtx{}));
    items[1].transform[3] = 0;
    items[1].flags.highlight = true;
    try plan.build(gpa, d, &items, TestCtx{});
    try std.testing.expect(base != plan.contentHash(TestCtx{}));

    const Other = struct {
        pub fn hasMesh(_: @This(), _: u32) bool {
            return true;
        }
        pub fn meshVersion(_: @This(), h: u32) u32 {
            return h * 10 + 1;
        }
    };
    items[1].flags.highlight = false;
    try plan.build(gpa, d, &items, TestCtx{});
    try std.testing.expectEqual(base, plan.contentHash(TestCtx{}));
    try std.testing.expect(base != plan.contentHash(Other{}));
}

test "GridUniform is 256 bytes (matches the WGSL block)" {
    try std.testing.expectEqual(@as(usize, 256), @sizeOf(GridUniform));
}

fn orbitCam(o: teak.scene.Orbit) teak.Camera {
    return o.camera(800, 600, null);
}

test "viewDir matches the orbit basis for perspective and ortho cameras" {
    var o = teak.scene.Orbit{ .yaw = 0.7, .pitch = 0.4, .dist = 12 };
    for ([_]bool{ false, true }) |ortho| {
        o.projection = if (ortho) .ortho else .{ .perspective = .{} };
        const bs = o.basis();
        const cam = orbitCam(o);
        for ([_]mat.Vec3{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } }) |d| {
            const v = viewDir(cam.view_proj, d);
            try std.testing.expectApproxEqAbs(mat.dot(d, bs.right), v[0], 1e-4);
            try std.testing.expectApproxEqAbs(mat.dot(d, bs.up), v[1], 1e-4);
            try std.testing.expectApproxEqAbs(-mat.dot(d, bs.forward), v[2], 1e-4);
        }
    }
}

test "gizmoRect honours the corner, size, margin and scale" {
    const gz = teak.scene.Gizmo{ .corner = .bottom_right, .size_px = 72, .margin_px = 8 };
    const r = gizmoRect(gz, 800, 600, 1);
    try std.testing.expectEqual([4]f32{ 800 - 8 - 72, 600 - 8 - 72, 72, 72 }, r);
    const tl = gizmoRect(.{ .corner = .top_left, .size_px = 50, .margin_px = 4 }, 400, 300, 2);
    try std.testing.expectEqual([4]f32{ 8, 8, 100, 100 }, tl);
}

test "gizmoLines: front view puts +x right, +y up and +z at the centre" {
    var o = teak.scene.Orbit{};
    o.setPreset(.front);
    const lines = gizmoLines(orbitCam(o).view_proj, .{});
    // segment 0 of each axis is the shaft (4 segments per axis, 2 verts each)
    try std.testing.expectApproxEqAbs(@as(f32, 1), lines[1].pos[0], 1e-4); // +x tip
    try std.testing.expectApproxEqAbs(@as(f32, 0), lines[1].pos[1], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 1), lines[9].pos[1], 1e-4); // +y tip
    try std.testing.expectApproxEqAbs(@as(f32, 0), lines[17].pos[0], 1e-4); // +z tip at centre
    try std.testing.expectApproxEqAbs(@as(f32, 1), lines[17].pos[2], 1e-4); // ... toward the viewer
    // negative stub is dim, shaft opaque
    try std.testing.expect(lines[7].color[3] < lines[1].color[3]);
    for (lines) |l| for (l.pos) |c| try std.testing.expect(std.math.isFinite(c));
}

test "gridUniform: plane id, fade derivation, singular camera" {
    var d = draw0();
    var o = teak.scene.Orbit{ .dist = 10 };
    d.camera = o.camera(100, 100, null);
    const g = gridUniform(d, .{ .plane = .xy, .spacing = 12, .major_every = 5 }, 200, 100, 2).?;
    try std.testing.expectEqual(@as(f32, 1), g.plane[0]);
    try std.testing.expectEqual(@as(f32, 3), g.plane[1]); // 1.5 px * scale 2
    try std.testing.expectEqual(@as(f32, 200), g.plane[2]);
    try std.testing.expectEqual(@as(f32, 5), g.params[1]);
    try std.testing.expectEqual(@as(f32, 1), g.extra[1]); // perspective
    try std.testing.expect(g.extra[0] > 10 and g.extra[0] < 1e5); // far plane distance
    try std.testing.expect(g.params[2] >= 120); // >= 10 cells
    const fixed = gridUniform(d, .{ .fade_dist = 77 }, 1, 1, 1).?;
    try std.testing.expectEqual(@as(f32, 77), fixed.params[2]);
    // inverse really inverts
    const id = mat.mul(g.view_proj, g.inv_view_proj);
    for (0..16) |i| try std.testing.expectApproxEqAbs(mat.identity4[i], id[i], 2e-4);
    d.camera.view_proj = @splat(0);
    try std.testing.expect(gridUniform(d, .{}, 1, 1, 1) == null);
    o.up = .z;
}
