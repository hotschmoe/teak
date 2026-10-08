//! Canvas-primitive tessellation: `CanvasPrimitive` -> `Vertex` triangles,
//! clipped to a rect. Pure functions over data; shared by the 2D render pass
//! (`build.zig`, window space) and by the 3D scene's plane layers (plane-local
//! space), which tessellate the same primitives and transform them in the
//! vertex stage.

const std = @import("std");
const layout = @import("../layout/engine.zig");
const Rect = layout.Rect;
const clipRect = layout.clipRect;
const cmd_types = @import("../core/cmd.zig");
const CanvasPrimitive = cmd_types.CanvasPrimitive;
const vertex = @import("vertex.zig");
const Vertex = vertex.Vertex;
const emitQuad = vertex.emitQuad;
const emitQuadCorners = vertex.emitQuadCorners;

pub fn emit(verts: *std.ArrayList(Vertex), alloc: std.mem.Allocator, r: Rect, color: [4]f32, clip: Rect) void {
    const cr = clipRect(r, clip);
    if (cr.w <= 0 or cr.h <= 0) return;
    emitQuad(verts, alloc, cr, color);
}

// ── Canvas primitive emission ──────────────────────────────────────

/// Translate one canvas-local primitive to window space and emit it.
/// Axis-aligned prims go through `emit` (rect-clipped). Polyline segments
/// are clipped in data space then drawn as rotated quads via
/// `emitQuadCorners`.
pub fn emitCanvasPrimitive(
    verts: *std.ArrayList(Vertex),
    alloc: std.mem.Allocator,
    canvas: Rect,
    prim: CanvasPrimitive,
    clip: Rect,
) void {
    switch (prim) {
        .filled_rect => |fr| {
            emit(verts, alloc, .{
                .x = canvas.x + fr.x,
                .y = canvas.y + fr.y,
                .w = fr.w,
                .h = fr.h,
            }, fr.color, clip);
        },
        .hline => |h| {
            const half = h.thickness * 0.5;
            emit(verts, alloc, .{
                .x = canvas.x,
                .y = canvas.y + h.y - half,
                .w = canvas.w,
                .h = h.thickness,
            }, h.color, clip);
        },
        .vline => |v| {
            const half = v.thickness * 0.5;
            emit(verts, alloc, .{
                .x = canvas.x + v.x - half,
                .y = canvas.y,
                .w = v.thickness,
                .h = canvas.h,
            }, v.color, clip);
        },
        .marker => |mk| {
            const half = mk.size * 0.5;
            emit(verts, alloc, .{
                .x = canvas.x + mk.x - half,
                .y = canvas.y + mk.y - half,
                .w = mk.size,
                .h = mk.size,
            }, mk.color, clip);
        },
        .text => {}, // drawn by the caller (needs the text list and the measurer)
        .triangles => |tr| emitTriangles(verts, alloc, canvas, tr.verts, clip),
        .lines => |ln| {
            verts.ensureUnusedCapacity(alloc, ln.segs.len * 6) catch return;
            for (ln.segs) |sg| {
                var x0 = canvas.x + sg[0];
                var y0 = canvas.y + sg[1];
                var x1 = canvas.x + sg[2];
                var y1 = canvas.y + sg[3];
                if (clipSegment(&x0, &y0, &x1, &y1, clip)) {
                    emitSegmentQuad(verts, alloc, x0, y0, x1, y1, ln.thickness, ln.color);
                }
            }
        },
        .polyline => |pl| {
            if (pl.points.len < 2) return;
            var i: usize = 1;
            while (i < pl.points.len) : (i += 1) {
                const a = pl.points[i - 1];
                const b = pl.points[i];
                var x0 = canvas.x + a.x;
                var y0 = canvas.y + a.y;
                var x1 = canvas.x + b.x;
                var y1 = canvas.y + b.y;
                // Fully-outside segments are rejected; partially-outside
                // ones are trimmed to the clip rect at the data level. The
                // thick quad may still bulge by up to thickness/2 past the
                // boundary at a trimmed endpoint — negligible and bounded.
                if (clipSegment(&x0, &y0, &x1, &y1, clip)) {
                    emitSegmentQuad(verts, alloc, x0, y0, x1, y1, pl.thickness, pl.color);
                }
            }
        },
    }
}

// ── Triangle list emission ─────────────────────────────────────────

const TriVertex = CanvasPrimitive.TriVertex;

fn toVertex(canvas: Rect, v: TriVertex) Vertex {
    return .{ .x = canvas.x + v.x, .y = canvas.y + v.y, .r = v.r, .g = v.g, .b = v.b, .a = v.a, .u = 0, .v = 0 };
}

fn finiteVertex(v: TriVertex) bool {
    return std.math.isFinite(v.x) and std.math.isFinite(v.y);
}

/// Emit a canvas-local triangle list, clipped to `clip` (window space).
/// Three tiers, cheapest first: (1) the whole list's bounds sit inside the
/// clip — convert the vertices in one pass; (2) a triangle's own bounds do —
/// copy it; (3) otherwise Sutherland–Hodgman against the clip rect,
/// interpolating color, fan-triangulating the result. Triangles with a
/// non-finite position are dropped; a trailing partial triangle is ignored.
pub fn emitTriangles(
    verts: *std.ArrayList(Vertex),
    alloc: std.mem.Allocator,
    canvas: Rect,
    list: []const TriVertex,
    clip: Rect,
) void {
    const n = list.len - list.len % 3;
    if (n == 0) return;
    const tris = list[0..n];

    // Tier 1: bounds of everything (and finiteness) in one linear scan.
    var min_x = std.math.inf(f32);
    var min_y = std.math.inf(f32);
    var max_x = -std.math.inf(f32);
    var max_y = -std.math.inf(f32);
    var all_finite = true;
    for (tris) |v| {
        if (!finiteVertex(v)) {
            all_finite = false;
            break;
        }
        min_x = @min(min_x, v.x);
        min_y = @min(min_y, v.y);
        max_x = @max(max_x, v.x);
        max_y = @max(max_y, v.y);
    }
    if (all_finite and boundsInside(canvas, min_x, min_y, max_x, max_y, clip)) {
        const out = verts.addManyAsSlice(alloc, n) catch return;
        for (tris, out) |v, *o| o.* = toVertex(canvas, v);
        return;
    }

    var i: usize = 0;
    while (i < n) : (i += 3) {
        const t = tris[i..][0..3];
        if (!(finiteVertex(t[0]) and finiteVertex(t[1]) and finiteVertex(t[2]))) continue;
        const tx0 = @min(t[0].x, @min(t[1].x, t[2].x));
        const ty0 = @min(t[0].y, @min(t[1].y, t[2].y));
        const tx1 = @max(t[0].x, @max(t[1].x, t[2].x));
        const ty1 = @max(t[0].y, @max(t[1].y, t[2].y));
        if (boundsInside(canvas, tx0, ty0, tx1, ty1, clip)) {
            // Tier 2.
            verts.appendSlice(alloc, &.{ toVertex(canvas, t[0]), toVertex(canvas, t[1]), toVertex(canvas, t[2]) }) catch return;
        } else if (boundsOverlap(canvas, tx0, ty0, tx1, ty1, clip)) {
            // Tier 3.
            clipTriangle(verts, alloc, .{ toVertex(canvas, t[0]), toVertex(canvas, t[1]), toVertex(canvas, t[2]) }, clip);
        }
    }
}

fn boundsInside(canvas: Rect, x0: f32, y0: f32, x1: f32, y1: f32, clip: Rect) bool {
    return canvas.x + x0 >= clip.x and canvas.y + y0 >= clip.y and
        canvas.x + x1 <= clip.x + clip.w and canvas.y + y1 <= clip.y + clip.h;
}

fn boundsOverlap(canvas: Rect, x0: f32, y0: f32, x1: f32, y1: f32, clip: Rect) bool {
    return canvas.x + x1 > clip.x and canvas.y + y1 > clip.y and
        canvas.x + x0 < clip.x + clip.w and canvas.y + y0 < clip.y + clip.h;
}

fn lerpVertex(a: Vertex, b: Vertex, t: f32) Vertex {
    return .{
        .x = a.x + (b.x - a.x) * t,
        .y = a.y + (b.y - a.y) * t,
        .r = a.r + (b.r - a.r) * t,
        .g = a.g + (b.g - a.g) * t,
        .b = a.b + (b.b - a.b) * t,
        .a = a.a + (b.a - a.a) * t,
        .u = 0,
        .v = 0,
    };
}

/// A triangle clipped by four half-planes has at most 3 + 4 = 7 vertices.
const MAX_CLIP_POLY = 8;

/// Sutherland–Hodgman: clip one window-space triangle to `clip` and emit
/// the resulting convex polygon as a triangle fan.
fn clipTriangle(verts: *std.ArrayList(Vertex), alloc: std.mem.Allocator, tri: [3]Vertex, clip: Rect) void {
    // Ping-pong between two scratch polygons, one pass per clip edge.
    var buf_a: [MAX_CLIP_POLY]Vertex = undefined;
    var buf_b: [MAX_CLIP_POLY]Vertex = undefined;
    buf_a[0..3].* = tri;
    var src: []Vertex = buf_a[0..3];
    var dst: *[MAX_CLIP_POLY]Vertex = &buf_b;
    var spare: *[MAX_CLIP_POLY]Vertex = &buf_a;

    // Four edges: x >= left, x <= right, y >= top, y <= bottom.
    const Edge = struct { axis_y: bool, bound: f32, keep_greater: bool };
    const edges = [4]Edge{
        .{ .axis_y = false, .bound = clip.x, .keep_greater = true },
        .{ .axis_y = false, .bound = clip.x + clip.w, .keep_greater = false },
        .{ .axis_y = true, .bound = clip.y, .keep_greater = true },
        .{ .axis_y = true, .bound = clip.y + clip.h, .keep_greater = false },
    };
    for (edges) |e| {
        var out_len: usize = 0;
        for (src, 0..) |cur, i| {
            const prev = src[(i + src.len - 1) % src.len];
            const cur_c = if (e.axis_y) cur.y else cur.x;
            const prev_c = if (e.axis_y) prev.y else prev.x;
            const cur_in = if (e.keep_greater) cur_c >= e.bound else cur_c <= e.bound;
            const prev_in = if (e.keep_greater) prev_c >= e.bound else prev_c <= e.bound;
            if (cur_in != prev_in) {
                dst[out_len] = lerpVertex(prev, cur, (e.bound - prev_c) / (cur_c - prev_c));
                out_len += 1;
            }
            if (cur_in) {
                dst[out_len] = cur;
                out_len += 1;
            }
        }
        if (out_len < 3) return;
        src = dst[0..out_len];
        std.mem.swap(*[MAX_CLIP_POLY]Vertex, &dst, &spare);
    }

    verts.ensureUnusedCapacity(alloc, (src.len - 2) * 3) catch return;
    var k: usize = 1;
    while (k + 1 < src.len) : (k += 1) {
        verts.appendSliceAssumeCapacity(&.{ src[0], src[k], src[k + 1] });
    }
}

/// Build the 4 corners of a `thickness`-wide quad along segment
/// (x0,y0)→(x1,y1) and emit it. Zero-length segments draw nothing.
fn emitSegmentQuad(
    verts: *std.ArrayList(Vertex),
    alloc: std.mem.Allocator,
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    thickness: f32,
    color: [4]f32,
) void {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const len = @sqrt(dx * dx + dy * dy);
    if (len <= 0) return;
    const half = thickness * 0.5;
    // Unit normal (perpendicular to the segment) scaled by half-thickness.
    const nx = -dy / len * half;
    const ny = dx / len * half;
    emitQuadCorners(
        verts,
        alloc,
        .{ x0 + nx, y0 + ny },
        .{ x1 + nx, y1 + ny },
        .{ x1 - nx, y1 - ny },
        .{ x0 - nx, y0 - ny },
        color,
    );
}

/// Liang–Barsky segment clip against an axis-aligned rect. Mutates the
/// endpoints to the visible sub-segment and returns true if any part is
/// visible; returns false (endpoints untouched-but-ignored) if fully out.
pub fn clipSegment(x0: *f32, y0: *f32, x1: *f32, y1: *f32, clip: Rect) bool {
    // Reject a segment with any NaN endpoint outright. Every Liang–Barsky
    // t-comparison against a NaN is false, so a NaN segment would otherwise
    // sail through "accepted" and `emitSegmentQuad`'s `len <= 0` guard is also
    // false for a NaN length — the net result being six NaN vertices in the
    // buffer. Drop it here instead.
    if (std.math.isNan(x0.*) or std.math.isNan(y0.*) or
        std.math.isNan(x1.*) or std.math.isNan(y1.*)) return false;

    const dx = x1.* - x0.*;
    const dy = y1.* - y0.*;
    const xmin = clip.x;
    const xmax = clip.x + clip.w;
    const ymin = clip.y;
    const ymax = clip.y + clip.h;

    const p = [_]f32{ -dx, dx, -dy, dy };
    const q = [_]f32{ x0.* - xmin, xmax - x0.*, y0.* - ymin, ymax - y0.* };

    var t0: f32 = 0;
    var t1: f32 = 1;
    for (p, q) |pk, qk| {
        if (pk == 0) {
            // Segment parallel to this edge: reject if it starts outside.
            if (qk < 0) return false;
        } else {
            const t = qk / pk;
            if (pk < 0) {
                if (t > t1) return false;
                if (t > t0) t0 = t;
            } else {
                if (t < t0) return false;
                if (t < t1) t1 = t;
            }
        }
    }

    const nx0 = x0.* + t0 * dx;
    const ny0 = y0.* + t0 * dy;
    const nx1 = x0.* + t1 * dx;
    const ny1 = y0.* + t1 * dy;
    x0.* = nx0;
    y0.* = ny0;
    x1.* = nx1;
    y1.* = ny1;
    return true;
}
