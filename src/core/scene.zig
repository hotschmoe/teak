//! Data types for 3D scene rendering: mesh geometry, camera, and the
//! per-frame `SceneDraw` record the render pass hands to the Gpu.
//!
//! Everything here is plain data (HARDLINE §3: no handles to platform
//! objects). `MeshData` is what an app uploads once through
//! `Gpu.uploadMesh`; a `Cmd.scene3d` then refers to the resulting
//! `MeshHandle` (or, with the declarative `resources` hook, to an app key
//! the run loop maps to one) and carries only a `Camera`.
//!
//! Conventions (shared by both GPU backends and `shaders/scene.wgsl`):
//!   * Right-handed world; the app supplies a column-major `view_proj` that
//!     maps to WebGPU clip space (x,y in -1..1, z in 0..1, +y up).
//!   * Depth test is `less` with a 32-bit float depth buffer.
//!   * Triangles are lit flat-shaded with one directional light plus
//!     ambient, two-sided (faces are lit as if facing the camera).
//!   * Lines are camera-facing quads of constant pixel width.

const std = @import("std");

/// Opaque backend mesh handle. 0 is "none".
pub const MeshHandle = u32;
pub const MESH_HANDLE_NONE: MeshHandle = 0;

/// 40 bytes, tightly packed — the GPU vertex layout is exactly this.
pub const MeshVertex = extern struct {
    pos: [3]f32,
    normal: [3]f32,
    color: [4]f32,
};

/// 28 bytes. Lines are consecutive pairs: `lines[2i]`, `lines[2i + 1]` are
/// the two ends of segment `i`; each end carries its own color.
pub const LineVertex = extern struct {
    pos: [3]f32,
    color: [4]f32,
};

/// Geometry for `Gpu.uploadMesh`. The slices are copied during upload;
/// they only need to live for the call.
pub const MeshData = struct {
    vertices: []const MeshVertex = &.{},
    /// Triangle list; every index must be `< vertices.len`.
    indices: []const u32 = &.{},
    /// Segment pairs (see `LineVertex`). Even length; a trailing odd vertex
    /// is ignored.
    lines: []const LineVertex = &.{},

    pub fn triangleCount(self: MeshData) usize {
        return self.indices.len / 3;
    }

    pub fn segmentCount(self: MeshData) usize {
        return self.lines.len / 2;
    }

    /// Check the invariants the GPU upload relies on.
    pub fn validate(self: MeshData) error{ IndexOutOfRange, PartialTriangle }!void {
        if (self.indices.len % 3 != 0) return error.PartialTriangle;
        for (self.indices) |i| {
            if (i >= self.vertices.len) return error.IndexOutOfRange;
        }
    }
};

pub const Camera = struct {
    /// Column-major `projection * view` (element `[col * 4 + row]`).
    view_proj: [16]f32 = .{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    },
    /// World-space eye position; used to orient two-sided lighting and the
    /// headlight.
    eye: [3]f32 = .{ 0, 0, 0 },
    /// Direction the light *travels* (from the light toward the scene).
    /// The zero vector selects a headlight that travels along the view
    /// direction (lights whatever faces the camera).
    light_dir: [3]f32 = .{ -0.4, -0.8, -0.5 },
};

/// One scene to render this frame. Emitted by the render pass for each
/// `scene3d` Cmd, in painter order; consumed by `Gpu.renderScenes`.
pub const SceneDraw = struct {
    mesh: MeshHandle,
    /// Layout rect in logical pixels.
    rect_x: f32,
    rect_y: f32,
    rect_w: f32,
    rect_h: f32,
    /// Visible region (active scroll clip), logical pixels.
    clip_x: f32,
    clip_y: f32,
    clip_w: f32,
    clip_h: f32,
    camera: Camera = .{},
    /// Background the scene target is cleared to.
    clear: [4]f32 = .{ 0, 0, 0, 1 },
    /// Multiplied into each line vertex's own color.
    edge_color: [4]f32 = .{ 1, 1, 1, 1 },
    /// Line width in logical pixels.
    edge_px: f32 = 1.5,
};

test "MeshData.validate rejects bad indices and partial triangles" {
    const v: [3]MeshVertex = @splat(.{ .pos = .{ 0, 0, 0 }, .normal = .{ 0, 0, 1 }, .color = .{ 1, 1, 1, 1 } });
    const ok = MeshData{ .vertices = &v, .indices = &.{ 0, 1, 2 } };
    try ok.validate();
    try std.testing.expectEqual(@as(usize, 1), ok.triangleCount());

    const bad_index = MeshData{ .vertices = &v, .indices = &.{ 0, 1, 3 } };
    try std.testing.expectError(error.IndexOutOfRange, bad_index.validate());

    const partial = MeshData{ .vertices = &v, .indices = &.{ 0, 1 } };
    try std.testing.expectError(error.PartialTriangle, partial.validate());
}

test "vertex layouts are tightly packed" {
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(MeshVertex));
    try std.testing.expectEqual(@as(usize, 28), @sizeOf(LineVertex));
}

// ---- teak.scene helpers (camera, picking, section): see docs/features/scene.md
pub const mat = @import("scene/mat.zig");
pub const camera = @import("scene/camera.zig");
pub const pick = @import("scene/pick.zig");
pub const section = @import("scene/section.zig");
pub const Orbit = camera.Orbit;
pub const Projection = camera.Projection;
pub const Bounds = camera.Bounds;
pub const Ray = camera.Ray;
pub const pickRay = camera.pickRay;
pub const project = camera.project;

test {
    _ = mat;
    _ = camera;
    _ = pick;
    _ = section;
}
