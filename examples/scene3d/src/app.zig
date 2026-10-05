//! scene3d: a depth-tested, lit stud-wall mesh with feature lines (a
//! `scene3d` Cmd), next to a vector canvas drawn from pre-tessellated,
//! alpha-feathered triangles and a batched hatch (`CanvasPrimitive.triangles`
//! / `.lines`). The camera orbits from a `Sub` tick; every control is a Msg.
//!
//! The mesh is declared through the `resources()` hook (HARDLINE hatch 8):
//! the app lists data under a key + revision and the run loop owns the GPU
//! upload. Toggling the edges swaps to a mesh with a different `rev`.

const std = @import("std");
const teak = @import("teak");
const math = @import("math.zig");
const mesh = @import("mesh.zig");

pub const mesh_key: u32 = 1;

pub const Msg = union(enum) {
    tick,
    toggle_orbit,
    toggle_edges,
    zoom_in,
    zoom_out,
    raise,
    lower,
};

pub const Model = struct {
    /// Azimuth of the camera around the wall, radians.
    azimuth: f32 = 0.6,
    elevation: f32 = 0.35,
    distance: f32 = 8.5,
    orbiting: bool = true,
    edges: bool = true,
    /// Animation counter, advanced by `tick`; also the canvas revision.
    frame: u32 = 0,
};

pub fn update(m: *Model, msg: Msg) void {
    switch (msg) {
        .tick => {
            m.frame +%= 1;
            if (m.orbiting) m.azimuth += 0.012;
        },
        .toggle_orbit => m.orbiting = !m.orbiting,
        .toggle_edges => m.edges = !m.edges,
        .zoom_in => m.distance = @max(3, m.distance - 0.8),
        .zoom_out => m.distance = @min(20, m.distance + 0.8),
        .raise => m.elevation = @min(1.4, m.elevation + 0.1),
        .lower => m.elevation = @max(-0.2, m.elevation - 0.1),
    }
}

/// ~60 Hz animation tick (the web loop sends `.tick` itself, per frame).
pub fn subscribe(_: *const Model) []const teak.Sub(Msg) {
    return &.{.{ .every = .{ .interval_ms = 16, .msg = .tick } }};
}

// ── Resources ──────────────────────────────────────────────────────

const mesh_with_edges = [_]teak.Resource{.{ .mesh = .{ .key = mesh_key, .rev = 1, .data = mesh.with_edges } }};
const mesh_without_edges = [_]teak.Resource{.{ .mesh = .{ .key = mesh_key, .rev = 2, .data = mesh.without_edges } }};

pub fn resources(m: *const Model) []const teak.Resource {
    return if (m.edges) &mesh_with_edges else &mesh_without_edges;
}

// ── Camera ─────────────────────────────────────────────────────────

pub const scene_w: f32 = 520;
pub const scene_h: f32 = 380;
const target: math.Vec3 = .{ 2.2, 1.4, 0 };

pub fn camera(m: *const Model) teak.Camera {
    const eye: math.Vec3 = .{
        target[0] + m.distance * @cos(m.elevation) * @sin(m.azimuth),
        target[1] + m.distance * @sin(m.elevation),
        target[2] + m.distance * @cos(m.elevation) * @cos(m.azimuth),
    };
    const proj = math.perspective(0.8, scene_w / scene_h, 0.5, 60);
    const look = math.lookAt(eye, target, .{ 0, 1, 0 });
    return .{
        .view_proj = math.mul(proj, look),
        .eye = eye,
        .light_dir = .{ -0.5, -1, -0.6 },
    };
}

// ── View ───────────────────────────────────────────────────────────

const canvas_size: f32 = 240;

pub fn view(m: *const Model, cb: anytype) void {
    const a = cb.arena.allocator();

    cb.pushGroup(.{ .direction = .vertical, .padding = 12, .gap = 10 });
    cb.text("scene3d - depth-tested mesh + feature lines, and a vector canvas");

    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 12 });
    cb.scene3d(.{
        .style = .{ .width = scene_w, .height = scene_h },
        .mesh = mesh_key,
        .camera = camera(m),
        .clear = .{ 0.11, 0.12, 0.15, 1 },
        .edge_color = .{ 1, 1, 1, 1 },
        .edge_px = 1.5,
        .key = if (m.edges) 1 else 2,
        .label = "stud wall detail",
    });

    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 8 });
    cb.canvasLabeled(
        .{ .width = canvas_size, .height = canvas_size, .bg = .{ 0.16, 0.17, 0.21, 1 } },
        canvasPrimitives(a, m),
        "vector canvas: feathered triangles and hatch",
    );
    cb.button(.toggle_orbit, if (m.orbiting) "Pause orbit" else "Resume orbit");
    cb.button(.toggle_edges, if (m.edges) "Hide edges" else "Show edges");
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 6 });
    cb.button(.zoom_in, "Zoom +");
    cb.button(.zoom_out, "Zoom -");
    cb.popGroup();
    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 6 });
    cb.button(.raise, "Up");
    cb.button(.lower, "Down");
    cb.popGroup();
    cb.text(std.fmt.allocPrint(a, "azimuth {d:.2}  elevation {d:.2}", .{ m.azimuth, m.elevation }) catch "");
    cb.popGroup();

    cb.popGroup();
    cb.popGroup();
}

// ── Canvas content ─────────────────────────────────────────────────

const ring_segments = 48;
const TV = teak.CanvasPrimitive.TriVertex;

/// A filled disc with a 1.5 px alpha feather (the antialiasing trick for
/// plain triangle lists) wobbling over a hatched field. The hatch is a
/// static batch (key 1), the disc is rebuilt every tick (key = frame).
fn canvasPrimitives(arena: std.mem.Allocator, m: *const Model) []const teak.CanvasPrimitive {
    const hatch_count = 24;
    const segs = arena.alloc([4]f32, hatch_count) catch return &.{};
    for (segs, 0..) |*s, i| {
        const d: f32 = @as(f32, @floatFromInt(i)) * 20 - 40;
        s.* = .{ d, 0, d + canvas_size, canvas_size }; // 45 degree strokes, clipped by the canvas
    }

    const tris = arena.alloc(TV, ring_segments * 9) catch return &.{};
    const t: f32 = @floatFromInt(m.frame);
    const cx = canvas_size / 2 + 20 * @sin(t * 0.03);
    const cy = canvas_size / 2 + 10 * @cos(t * 0.021);
    const r_in: f32 = 70 + 6 * @sin(t * 0.05);
    const r_out = r_in + 1.5;
    const fill = [3]f32{ 0.95, 0.72, 0.25 };
    for (0..ring_segments) |i| {
        const a0 = @as(f32, @floatFromInt(i)) * std.math.tau / ring_segments;
        const a1 = @as(f32, @floatFromInt(i + 1)) * std.math.tau / ring_segments;
        const p0 = [2]f32{ cx + r_in * @cos(a0), cy + r_in * @sin(a0) };
        const p1 = [2]f32{ cx + r_in * @cos(a1), cy + r_in * @sin(a1) };
        const q0 = [2]f32{ cx + r_out * @cos(a0), cy + r_out * @sin(a0) };
        const q1 = [2]f32{ cx + r_out * @cos(a1), cy + r_out * @sin(a1) };
        const o = i * 9;
        tris[o + 0] = vtx(cx, cy, fill, 1);
        tris[o + 1] = vtx(p0[0], p0[1], fill, 1);
        tris[o + 2] = vtx(p1[0], p1[1], fill, 1);
        // Feather band: opaque inner edge -> transparent outer edge.
        tris[o + 3] = vtx(p0[0], p0[1], fill, 1);
        tris[o + 4] = vtx(q0[0], q0[1], fill, 0);
        tris[o + 5] = vtx(q1[0], q1[1], fill, 0);
        tris[o + 6] = vtx(p0[0], p0[1], fill, 1);
        tris[o + 7] = vtx(q1[0], q1[1], fill, 0);
        tris[o + 8] = vtx(p1[0], p1[1], fill, 1);
    }

    const prims = arena.alloc(teak.CanvasPrimitive, 2) catch return &.{};
    prims[0] = .{ .lines = .{ .segs = segs, .color = .{ 0.35, 0.38, 0.45, 1 }, .thickness = 1, .key = 1 } };
    prims[1] = .{ .triangles = .{ .verts = tris, .key = @as(u64, m.frame) + 2 } };
    return prims;
}

fn vtx(x: f32, y: f32, rgb: [3]f32, alpha: f32) TV {
    return .{ .x = x, .y = y, .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = alpha };
}

test "update: orbit advances only while orbiting; zoom is clamped" {
    var m: Model = .{};
    const az = m.azimuth;
    update(&m, .tick);
    try std.testing.expect(m.azimuth > az);
    update(&m, .toggle_orbit);
    const az2 = m.azimuth;
    update(&m, .tick);
    try std.testing.expectEqual(az2, m.azimuth);
    for (0..50) |_| update(&m, .zoom_in);
    try std.testing.expectEqual(@as(f32, 3), m.distance);
}

test "resources: the edges toggle bumps the mesh revision" {
    var m: Model = .{};
    const a = resources(&m)[0].mesh;
    update(&m, .toggle_edges);
    const b = resources(&m)[0].mesh;
    try std.testing.expectEqual(a.key, b.key);
    try std.testing.expect(a.rev != b.rev);
    try std.testing.expect(a.data.lines.len > b.data.lines.len);
}

test "view: scene, canvas with a keyed batch, and buttons lay out" {
    var cb = teak.CmdBuffer(Msg).init(std.testing.allocator);
    defer cb.deinit();
    const m: Model = .{};
    view(&m, &cb);
    var scenes: usize = 0;
    var canvases: usize = 0;
    for (cb.cmds.items) |c| switch (c) {
        .scene3d => |s| {
            scenes += 1;
            try std.testing.expectEqual(mesh_key, s.mesh);
        },
        .canvas => |cv| {
            canvases += 1;
            try std.testing.expectEqual(@as(usize, 2), cv.primitives.len);
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), scenes);
    try std.testing.expectEqual(@as(usize, 1), canvases);
    try std.testing.expect(teak.validateBalance(cb.cmds.items) == null);
}
