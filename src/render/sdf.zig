//! Rounded rects, borders, gradients and soft shadows as signed-distance
//! quads, drawn by the SAME solid-quad pipeline as every flat quad so
//! painter's order is preserved.
//!
//! An SDF rect is twelve vertices in the ordinary `Vertex` stream:
//!
//!   * six HEADER vertices (two triangles) at the origin: degenerate, they
//!     rasterize nothing, but their `r g b a u v` fields carry the 36-float
//!     record below. The fragment shader reads the record back out of the
//!     vertex buffer (bound as a read-only storage buffer) by index.
//!   * six real vertices forming the quad (the rect grown by the shadow /
//!     antialiasing margin and trimmed to the clip), tagged `a = -1`, with
//!     `r` = the header's vertex index and `u, v` = the vertex position in
//!     pixels relative to the rect's centre (the shader's SDF coordinate).
//!
//! Plain solids are untouched (`a >= 0`), so a UI that never uses these
//! features renders pixel for pixel as before.

const std = @import("std");
const layout = @import("../layout/engine.zig");
const Rect = layout.Rect;
const clipRect = layout.clipRect;
const surface = @import("../core/surface.zig");
const vertex = @import("vertex.zig");
const Vertex = vertex.Vertex;

pub const Radii = surface.Radii;
pub const Shadow = surface.Shadow;
pub const Gradient = surface.Gradient;

/// What to draw: the fill (flat or gradient), an inside border stroke and an
/// optional blurred shadow, for one rect with per-corner radii.
pub const Spec = struct {
    rect: Rect,
    radii: Radii = .{},
    fill: [4]f32 = .{ 0, 0, 0, 0 },
    gradient: ?Gradient = null,
    border_width: f32 = 0,
    border: [4]f32 = .{ 0, 0, 0, 0 },
    shadow: ?Shadow = null,
};

/// True when a rect with these decorations needs the SDF path; false means
/// the caller keeps its plain solid-quad emission.
pub fn needed(radii: Radii, gradient: ?Gradient, shadow: ?Shadow) bool {
    return !radii.isZero() or gradient != null or shadow != null;
}

/// Record layout (floats), shared with `shaders/quad.wgsl`.
pub const rec = struct {
    pub const half_size = 0; // 2
    pub const radii = 2; // 4: tl tr br bl
    pub const border_width = 6;
    pub const border = 7; // 4
    pub const fill0 = 11; // 4
    pub const fill1 = 15; // 4
    pub const grad_kind = 19; // 0 none, 1 linear, 2 radial
    pub const grad_dir = 20; // 2
    pub const shadow_color = 22; // 4
    pub const shadow_blur = 26; // sigma = blur / 2
    pub const shadow_spread = 27;
    pub const shadow_off = 28; // 2
    pub const shadow_on = 30;
    pub const len = 36;
};

const header_vertices = 6;

/// Emit one SDF rect into `verts` (trimmed to `clip`; the SDF stays
/// anchored to the untrimmed rect, so clipping never distorts corners).
pub fn emitRect(verts: *std.ArrayList(Vertex), alloc: std.mem.Allocator, spec: Spec, clip: Rect) void {
    const r = spec.rect;
    if (r.w <= 0 or r.h <= 0) return;
    const hx = r.w * 0.5;
    const hy = r.h * 0.5;
    const cx = r.x + hx;
    const cy = r.y + hy;

    // Quad margin: antialiasing, plus everything the shadow can reach.
    var pad: f32 = 1.5;
    if (spec.shadow) |s| {
        const reach = @max(@abs(s.dx), @abs(s.dy)) + @max(s.spread, 0) + 1.5 * @max(s.blur, 0);
        pad += @ceil(reach);
    }
    const quad = clipRect(.{ .x = r.x - pad, .y = r.y - pad, .w = r.w + 2 * pad, .h = r.h + 2 * pad }, clip);
    if (quad.w <= 0 or quad.h <= 0) return;

    var d: [rec.len]f32 = @splat(0);
    d[rec.half_size] = hx;
    d[rec.half_size + 1] = hy;
    const cap = @min(hx, hy);
    d[rec.radii + 0] = std.math.clamp(spec.radii.tl, 0, cap);
    d[rec.radii + 1] = std.math.clamp(spec.radii.tr, 0, cap);
    d[rec.radii + 2] = std.math.clamp(spec.radii.br, 0, cap);
    d[rec.radii + 3] = std.math.clamp(spec.radii.bl, 0, cap);
    d[rec.border_width] = @max(spec.border_width, 0);
    @memcpy(d[rec.border..][0..4], &spec.border);
    if (spec.gradient) |g| {
        @memcpy(d[rec.fill0..][0..4], &g.from);
        @memcpy(d[rec.fill1..][0..4], &g.to);
        d[rec.grad_kind] = if (g.kind == .linear) 1 else 2;
        const dir = g.direction();
        d[rec.grad_dir] = dir[0];
        d[rec.grad_dir + 1] = dir[1];
    } else {
        @memcpy(d[rec.fill0..][0..4], &spec.fill);
        @memcpy(d[rec.fill1..][0..4], &spec.fill);
    }
    if (spec.shadow) |s| {
        @memcpy(d[rec.shadow_color..][0..4], &s.color);
        d[rec.shadow_blur] = @max(s.blur, 0) * 0.5;
        d[rec.shadow_spread] = s.spread;
        d[rec.shadow_off] = s.dx;
        d[rec.shadow_off + 1] = s.dy;
        d[rec.shadow_on] = 1;
    }

    const first: f32 = @floatFromInt(verts.items.len);
    verts.ensureUnusedCapacity(alloc, header_vertices + 6) catch return;
    for (0..header_vertices) |j| {
        const f = d[j * 6 ..][0..6];
        verts.appendAssumeCapacity(.{ .x = 0, .y = 0, .r = f[0], .g = f[1], .b = f[2], .a = f[3], .u = f[4], .v = f[5] });
    }
    const x0 = quad.x;
    const y0 = quad.y;
    const x1 = quad.x + quad.w;
    const y1 = quad.y + quad.h;
    const c = [4]Vertex{
        corner(x0, y0, cx, cy, first),
        corner(x1, y0, cx, cy, first),
        corner(x1, y1, cx, cy, first),
        corner(x0, y1, cx, cy, first),
    };
    verts.appendSliceAssumeCapacity(&.{ c[0], c[1], c[3], c[1], c[2], c[3] });
}

fn corner(x: f32, y: f32, cx: f32, cy: f32, header: f32) Vertex {
    return .{ .x = x, .y = y, .r = header, .g = 0, .b = 0, .a = -1, .u = x - cx, .v = y - cy };
}

/// Read one record float back out of the header vertices (tests, and the
/// reference for the shader's own indexing).
pub fn recordFloat(verts: []const Vertex, header: usize, k: usize) f32 {
    const v = verts[header + k / 6];
    return switch (k % 6) {
        0 => v.r,
        1 => v.g,
        2 => v.b,
        3 => v.a,
        4 => v.u,
        else => v.v,
    };
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

fn emitTest(spec: Spec, clip: Rect) !std.ArrayList(Vertex) {
    var verts: std.ArrayList(Vertex) = .empty;
    emitRect(&verts, testing.allocator, spec, clip);
    return verts;
}

const big_clip = Rect{ .x = -1000, .y = -1000, .w = 4000, .h = 4000 };





