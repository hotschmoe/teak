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
pub const flag_no_cap: u32 = 1 << 5;

/// Items `first .. first + count` of `Plan.insts` all use backend mesh `mesh`.
pub const Run = struct { mesh: u32, first: u32, count: u32 };

/// The 3x4 transform of a packed instance.
pub fn affineOf(p: Packed) mat.Affine {
    return .{ p.m0[0], p.m0[1], p.m0[2], p.m0[3], p.m1[0], p.m1[1], p.m1[2], p.m1[3], p.m2[0], p.m2[1], p.m2[2], p.m2[3] };
}

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
    /// Per-instance section-cap colour, parallel to `insts` (alpha 0 = use the cut's colour).
    caps: std.ArrayList([4]f32) = .empty,
    scratch: std.ArrayList(Keyed) = .empty,

    const Keyed = struct { mesh: u32, idx: u32 };

    pub fn deinit(self: *Plan, gpa: std.mem.Allocator) void {
        self.insts.deinit(gpa);
        self.runs.deinit(gpa);
        self.caps.deinit(gpa);
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
        self.caps.clearRetainingCapacity();
        self.scratch.clearRetainingCapacity();

        if (draw.item_count == 0 and items.len == 0) {
            if (draw.mesh != 0 and ctx.hasMesh(draw.mesh)) {
                try self.insts.append(gpa, pack(.{ .mesh = draw.mesh }));
                try self.caps.append(gpa, .{ 0, 0, 0, 0 });
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
            try self.caps.append(gpa, items[k.idx].cap_color);
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
        h.update(std.mem.sliceAsBytes(self.caps.items));
        for (self.runs.items) |r| {
            h.update(std.mem.asBytes(&r));
            const v: u32 = ctx.meshVersion(r.mesh);
            h.update(std.mem.asBytes(&v));
        }
        return h.final();
    }
};

// ── Plane and sprite layers ────────────────────────────────────────

/// One plane's placement as the `vs_plane` instance stream reads it: the
/// plane frame as a 3x4 transform (columns `u`, `v`, `u x v`, origin), the
/// opacity in `tint.a`, and the depth-bias layer. 80 bytes.
pub const LayerInst = extern struct {
    m0: [4]f32,
    m1: [4]f32,
    m2: [4]f32,
    tint: [4]f32,
    id: u32,
    flags: u32,
    layer: i32,
    _pad: u32 = 0,
};

/// One sprite as the `vs_sprite` instance stream reads it (five vec4s):
/// `pos.xyz` + mode, `size.xy` + anchor, uv rect, tint, and `extra`
/// (layer, 1 for `screen_px`, id, 0). 80 bytes.
pub const SpriteInst = extern struct {
    pos_mode: [4]f32,
    size_anchor: [4]f32,
    uv: [4]f32,
    tint: [4]f32,
    extra: [4]f32,
};

/// A plane's range in `Layers.plane_verts` and its instance.
pub const PlaneDraw = struct { first_vertex: u32, vertex_count: u32, inst: u32 };

/// What one blended draw is, in back-to-front order.
pub const Blended = struct {
    kind: enum { plane, sprite },
    /// Index into `plane_draws` or `sprites`.
    index: u32,
};

/// Everything the layer passes draw for one scene: tessellated plane
/// geometry (plane-local, shared with the 2D canvas tessellator), per-plane
/// and per-sprite records, the opaque planes (depth-written, drawn first)
/// and the blended draws sorted back to front. Pure; rebuilt per render.
pub const Layers = struct {
    plane_verts: std.ArrayList(teak.Vertex) = .empty,
    plane_draws: std.ArrayList(PlaneDraw) = .empty,
    plane_insts: std.ArrayList(LayerInst) = .empty,
    sprites: std.ArrayList(SpriteInst) = .empty,
    /// Backend image handle per entry of `sprites`.
    sprite_images: std.ArrayList(u32) = .empty,
    /// Indices into `plane_draws` of opaque planes.
    opaque_planes: std.ArrayList(u32) = .empty,
    blended: std.ArrayList(Blended) = .empty,
    centers: std.ArrayList(mat.Vec3) = .empty,
    order: std.ArrayList(u32) = .empty,
    scratch: std.ArrayList(Blended) = .empty,

    pub fn deinit(self: *Layers, gpa: std.mem.Allocator) void {
        inline for (.{ "plane_verts", "plane_draws", "plane_insts", "sprites", "sprite_images", "opaque_planes", "blended", "centers", "order", "scratch" }) |f| @field(self, f).deinit(gpa);
    }

    fn clear(self: *Layers) void {
        inline for (.{ "plane_verts", "plane_draws", "plane_insts", "sprites", "sprite_images", "opaque_planes", "blended", "centers", "order", "scratch" }) |f| @field(self, f).clearRetainingCapacity();
    }

    pub fn isEmpty(self: *const Layers) bool {
        return self.plane_draws.items.len == 0 and self.sprites.items.len == 0;
    }

    /// Rebuild for `draw`. `sprite_list` is the scene's sprites (image keys
    /// already remapped to handles); `images.hasImage(handle)` says which are
    /// resident. Hidden planes, empty planes, back-facing one-sided planes
    /// and sprites without an image are dropped.
    pub fn build(self: *Layers, gpa: std.mem.Allocator, draw: SceneDraw, sprite_list: []const teak.SceneSprite, images: anytype) std.mem.Allocator.Error!void {
        self.clear();
        const eye = mat.Vec3{ draw.camera.eye[0], draw.camera.eye[1], draw.camera.eye[2] };
        const tess = teak.render.canvas_tess;

        for (draw.planes) |pl| {
            if (pl.flags.hidden or !(pl.size[0] > 0 and pl.size[1] > 0)) continue;
            const n = mat.cross(pl.u, pl.v);
            if (!pl.double_sided and mat.dot(mat.sub(eye, pl.origin), n) < 0) continue;
            const first: u32 = @intCast(self.plane_verts.items.len);
            const rect = teak.Rect{ .x = 0, .y = 0, .w = pl.size[0], .h = pl.size[1] };
            if (pl.background) |bg| tess.emit(&self.plane_verts, gpa, rect, bg, rect);
            for (pl.content) |prim| tess.emitCanvasPrimitive(&self.plane_verts, gpa, rect, prim, rect);
            const count: u32 = @as(u32, @intCast(self.plane_verts.items.len)) - first;
            if (count == 0) continue;
            const inst: u32 = @intCast(self.plane_insts.items.len);
            try self.plane_insts.append(gpa, .{
                .m0 = .{ pl.u[0], pl.v[0], n[0], pl.origin[0] },
                .m1 = .{ pl.u[1], pl.v[1], n[1], pl.origin[1] },
                .m2 = .{ pl.u[2], pl.v[2], n[2], pl.origin[2] },
                .tint = .{ 1, 1, 1, std.math.clamp(pl.opacity, 0, 1) },
                .id = pl.id,
                .flags = @as(u8, @bitCast(pl.flags)),
                .layer = pl.layer,
            });
            const di: u32 = @intCast(self.plane_draws.items.len);
            try self.plane_draws.append(gpa, .{ .first_vertex = first, .vertex_count = count, .inst = inst });
            const opaque_plane = pl.opacity >= 1 and pl.background != null and pl.background.?[3] >= 1;
            if (opaque_plane) {
                try self.opaque_planes.append(gpa, di);
            } else {
                try self.scratch.append(gpa, .{ .kind = .plane, .index = di });
                const half_u = mat.scale(pl.u, pl.size[0] * 0.5);
                const half_v = mat.scale(pl.v, pl.size[1] * 0.5);
                try self.centers.append(gpa, mat.add(pl.origin, mat.add(half_u, half_v)));
            }
        }

        for (sprite_list) |sp| {
            if (sp.flags.hidden or sp.image == 0 or !images.hasImage(sp.image)) continue;
            const si: u32 = @intCast(self.sprites.items.len);
            try self.sprites.append(gpa, .{
                .pos_mode = .{ sp.pos[0], sp.pos[1], sp.pos[2], @floatFromInt(@backingInt(sp.mode)) },
                .size_anchor = .{ sp.size[0], sp.size[1], sp.anchor[0], sp.anchor[1] },
                .uv = sp.uv,
                .tint = sp.tint,
                .extra = .{ @floatFromInt(sp.layer), if (sp.size_in == .screen_px) 1 else 0, @floatFromInt(sp.id), 0 },
            });
            try self.sprite_images.append(gpa, sp.image);
            try self.scratch.append(gpa, .{ .kind = .sprite, .index = si });
            try self.centers.append(gpa, sp.pos);
        }

        try self.order.resize(gpa, self.centers.items.len);
        teak.scene.sort.byDepth(eye, self.centers.items, self.order.items);
        for (self.order.items) |o| try self.blended.append(gpa, self.scratch.items[o]);
    }

    pub fn contentHash(self: *const Layers) u64 {
        var h = std.hash.Wyhash.init(0x1a7e5);
        h.update(std.mem.sliceAsBytes(self.plane_verts.items));
        h.update(std.mem.sliceAsBytes(self.plane_insts.items));
        h.update(std.mem.sliceAsBytes(self.sprites.items));
        h.update(std.mem.sliceAsBytes(self.sprite_images.items));
        for (self.blended.items) |b| h.update(std.mem.asBytes(&b.index));
        return h.final();
    }
};

// ── Section cap ────────────────────────────────────────────────────

/// Corners of a quad lying in the cut plane that covers the world-space
/// bounds of an item (`lo`/`hi` of its mesh under `xf`), or null when the
/// whole box is on one side of the plane (nothing to cap). The plane keeps
/// `dot(n, p) + d <= 0`; `n` need not be exactly unit.
pub fn capQuad(plane: [4]f32, lo: mat.Vec3, hi: mat.Vec3, xf: mat.Affine) ?[4]mat.Vec3 {
    const n = mat.normalizeOr(.{ plane[0], plane[1], plane[2] }, .{ 0, 1, 0 });
    const d = plane[3] / @max(mat.length(.{ plane[0], plane[1], plane[2] }), 1e-12);
    // plane basis
    const helper: mat.Vec3 = if (@abs(n[1]) < 0.9) .{ 0, 1, 0 } else .{ 1, 0, 0 };
    const u = mat.normalize(mat.cross(helper, n));
    const v = mat.cross(n, u);
    var min_d: f32 = std.math.inf(f32);
    var max_d: f32 = -std.math.inf(f32);
    var lo_u: f32 = std.math.inf(f32);
    var hi_u: f32 = -std.math.inf(f32);
    var lo_v: f32 = std.math.inf(f32);
    var hi_v: f32 = -std.math.inf(f32);
    for (0..8) |i| {
        const c = mat.Vec3{
            if (i & 1 == 0) lo[0] else hi[0],
            if (i & 2 == 0) lo[1] else hi[1],
            if (i & 4 == 0) lo[2] else hi[2],
        };
        const w = mat.affinePoint(xf, c);
        const sd = mat.dot(n, w) + d;
        min_d = @min(min_d, sd);
        max_d = @max(max_d, sd);
        lo_u = @min(lo_u, mat.dot(u, w));
        hi_u = @max(hi_u, mat.dot(u, w));
        lo_v = @min(lo_v, mat.dot(v, w));
        hi_v = @max(hi_v, mat.dot(v, w));
    }
    if (min_d > 0 or max_d < 0) return null;
    const origin = mat.scale(n, -d); // a point on the plane
    const pad = 0.01 * @max(hi_u - lo_u, hi_v - lo_v) + 1e-4;
    const corners = [4][2]f32{ .{ lo_u - pad, lo_v - pad }, .{ hi_u + pad, lo_v - pad }, .{ hi_u + pad, hi_v + pad }, .{ lo_u - pad, hi_v + pad } };
    var out: [4]mat.Vec3 = undefined;
    for (corners, 0..) |c, i| {
        // origin has zero u,v components along n only; add the in-plane offsets
        out[i] = mat.add(origin, mat.add(mat.scale(u, c[0] - mat.dot(u, origin)), mat.scale(v, c[1] - mat.dot(v, origin))));
    }
    return out;
}

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

test "capQuad: spans the item on the plane, skipped when the box is on one side" {
    const lo = mat.Vec3{ 0, 0, 0 };
    const hi = mat.Vec3{ 2, 1, 4 };
    // keep y <= 0.5: n = +y, d = -0.5
    const q = capQuad(.{ 0, 1, 0, -0.5 }, lo, hi, mat.identity_affine).?;
    for (q) |p| try std.testing.expectApproxEqAbs(@as(f32, 0.5), p[1], 1e-5);
    var min_x: f32 = 99;
    var max_x: f32 = -99;
    var min_z: f32 = 99;
    var max_z: f32 = -99;
    for (q) |p| {
        min_x = @min(min_x, p[0]);
        max_x = @max(max_x, p[0]);
        min_z = @min(min_z, p[2]);
        max_z = @max(max_z, p[2]);
    }
    try std.testing.expect(min_x <= 0 and max_x >= 2 and min_z <= 0 and max_z >= 4);
    try std.testing.expect(capQuad(.{ 0, 1, 0, -2 }, lo, hi, mat.identity_affine) == null); // plane above: all kept
    try std.testing.expect(capQuad(.{ 0, 1, 0, 1 }, lo, hi, mat.identity_affine) == null); // plane below: all cut away
    // the item's transform moves the box through the plane
    const moved = capQuad(.{ 0, 1, 0, -5 }, lo, hi, mat.translation(.{ 0, 4.5, 0 }));
    try std.testing.expect(moved != null);
    // a slanted, non-unit plane still yields a planar quad
    const slanted = capQuad(.{ 2, 2, 0, -3 }, lo, hi, mat.identity_affine).?;
    for (slanted) |p| try std.testing.expectApproxEqAbs(@as(f32, 0), 2 * p[0] + 2 * p[1] - 3, 1e-4);
}

test "no_cap flag packs into bit 5 and caps stay parallel to instances" {
    const gpa = std.testing.allocator;
    var plan: Plan = .{};
    defer plan.deinit(gpa);
    const items = [_]Item{
        .{ .mesh = 2, .id = 1, .flags = .{ .no_cap = true } },
        .{ .mesh = 1, .id = 2, .cap_color = .{ 1, 0, 0, 1 } },
    };
    var d = draw0();
    d.item_count = 2;
    try plan.build(gpa, d, &items, TestCtx{});
    try std.testing.expectEqual(@as(usize, plan.insts.items.len), plan.caps.items.len);
    try std.testing.expectEqual(@as(u32, 2), plan.insts.items[0].id); // mesh 1 first
    try std.testing.expectEqual(@as(f32, 1), plan.caps.items[0][0]);
    try std.testing.expect(plan.insts.items[1].flags & flag_no_cap != 0);
    const h1 = plan.contentHash(TestCtx{});
    var items2 = items;
    items2[1].cap_color = .{ 0, 1, 0, 1 };
    try plan.build(gpa, d, &items2, TestCtx{});
    try std.testing.expect(h1 != plan.contentHash(TestCtx{}));
}

const LayerCtx = struct {
    pub fn hasImage(_: LayerCtx, h: u32) bool {
        return h != 99;
    }
};

test "Layers: LayerInst / SpriteInst are 80-byte records" {
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(LayerInst));
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(SpriteInst));
}

test "Layers: planes tessellate, opaque vs blended, culling, depth order" {
    const gpa = std.testing.allocator;
    var layers: Layers = .{};
    defer layers.deinit(gpa);
    const prims = [_]teak.CanvasPrimitive{
        .{ .filled_rect = .{ .x = 1, .y = 1, .w = 2, .h = 2 } },
        .{ .polyline = .{ .points = &.{ .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 3 } }, .thickness = 1 } },
    };
    const planes = [_]teak.ScenePlane{
        // opaque: background + rect + polyline = 3 quads
        .{ .origin = .{ 0, 0, 0 }, .u = .{ 1, 0, 0 }, .v = .{ 0, 1, 0 }, .size = .{ 4, 3 }, .content = &prims, .background = .{ 1, 1, 1, 1 }, .id = 1 },
        // translucent (no background): far
        .{ .origin = .{ 0, 0, -10 }, .u = .{ 1, 0, 0 }, .v = .{ 0, 1, 0 }, .size = .{ 4, 3 }, .content = &prims, .id = 2 },
        // translucent: near, layer 3
        .{ .origin = .{ 0, 0, 5 }, .u = .{ 1, 0, 0 }, .v = .{ 0, 1, 0 }, .size = .{ 4, 3 }, .content = &prims, .id = 3, .layer = 3, .opacity = 0.5 },
        // hidden, empty, and a one-sided sheet seen from behind
        .{ .origin = .{ 0, 0, 0 }, .u = .{ 1, 0, 0 }, .v = .{ 0, 1, 0 }, .size = .{ 4, 3 }, .content = &prims, .flags = .{ .hidden = true } },
        .{ .origin = .{ 0, 0, 0 }, .u = .{ 1, 0, 0 }, .v = .{ 0, 1, 0 }, .size = .{ 4, 3 } },
        .{ .origin = .{ 0, 0, 0 }, .u = .{ 1, 0, 0 }, .v = .{ 0, 1, 0 }, .size = .{ 4, 3 }, .content = &prims, .double_sided = false, .id = 9 },
    };
    var d = draw0();
    d.camera.eye = .{ 0, 0, -20 }; // behind every sheet: the one-sided sheet is back-facing
    d.planes = &planes;
    const sprites = [_]teak.SceneSprite{
        .{ .pos = .{ 0, 0, -5 }, .image = 4, .size = .{ 8, 8 }, .id = 20 },
        .{ .pos = .{ 0, 0, 0 }, .image = 99, .size = .{ 8, 8 } }, // not resident
        .{ .pos = .{ 0, 0, 0 }, .image = 0, .size = .{ 8, 8 } }, // no image
    };
    try layers.build(gpa, d, &sprites, LayerCtx{});

    try std.testing.expectEqual(@as(usize, 3), layers.plane_draws.items.len);
    try std.testing.expectEqual(@as(u32, 18), layers.plane_draws.items[0].vertex_count); // 3 quads x 6
    try std.testing.expectEqual(@as(usize, 1), layers.opaque_planes.items.len);
    try std.testing.expectEqual(@as(u32, 1), layers.plane_insts.items[0].id);
    try std.testing.expectEqual(@as(i32, 3), layers.plane_insts.items[2].layer);
    try std.testing.expectEqual(@as(f32, 0.5), layers.plane_insts.items[2].tint[3]);
    try std.testing.expectEqual(@as(usize, 1), layers.sprites.items.len);
    try std.testing.expectEqual(@as(u32, 4), layers.sprite_images.items[0]);

    // blended: far plane (z=-10 centre), sprite (z=-5), near plane (z=5): eye at z=-20,
    // so back-to-front = farthest from the eye first = the near plane (z=5), then the sprite, then z=-10
    try std.testing.expectEqual(@as(usize, 3), layers.blended.items.len);
    try std.testing.expect(layers.blended.items[0].kind == .plane and layers.plane_insts.items[layers.plane_draws.items[layers.blended.items[0].index].inst].id == 3);
    try std.testing.expect(layers.blended.items[1].kind == .sprite);
    try std.testing.expect(layers.blended.items[2].kind == .plane);
    // the plane frame is the transform: u in column 0, v in column 1, translation in .w
    try std.testing.expectEqual([4]f32{ 1, 0, 0, 0 }, layers.plane_insts.items[0].m0);
    // from the front the one-sided sheet appears
    d.camera.eye = .{ 0, 0, 20 };
    try layers.build(gpa, d, &sprites, LayerCtx{});
    try std.testing.expectEqual(@as(usize, 4), layers.plane_draws.items.len);
    const h1 = layers.contentHash();
    try layers.build(gpa, d, &sprites, LayerCtx{});
    try std.testing.expectEqual(h1, layers.contentHash());
    try layers.build(gpa, d, sprites[0..0], LayerCtx{});
    try std.testing.expect(h1 != layers.contentHash());
}
