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
const CanvasPoint = cmd_types.CanvasPoint;
const CanvasTransform = cmd_types.CanvasTransform;
const sdf = @import("sdf.zig");
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

/// How a canvas lowers its primitives: the world -> canvas-local transform,
/// antialiased edges, and whether circles may use the SDF quad (2D pass only:
/// the 3D plane layers draw the plain vertex stream with another shader).
pub const Opts = struct {
    xf: CanvasTransform = .{},
    aa: bool = false,
    sdf_circles: bool = false,
};

/// Translate one canvas-local primitive to window space and emit it, with
/// the identity transform and hard edges (the historical behaviour; the 3D
/// plane layers use this).
pub fn emitCanvasPrimitive(
    verts: *std.ArrayList(Vertex),
    alloc: std.mem.Allocator,
    canvas: Rect,
    prim: CanvasPrimitive,
    clip: Rect,
) void {
    emitCanvasPrimitiveOpts(verts, alloc, canvas, prim, clip, .{});
}

/// World point -> window space.
inline fn wp(canvas: Rect, xf: CanvasTransform, x: f32, y: f32) [2]f32 {
    return .{ canvas.x + x * xf.sx + xf.tx, canvas.y + y * xf.sy + xf.ty };
}

/// Emit one primitive under `o` (transform, antialiasing). Axis-aligned
/// prims go through `emit` (rect-clipped); strokes are clipped in data
/// space (Liang–Barsky) and drawn as rotated quads; fills are triangles,
/// clipped by Sutherland–Hodgman only where they straddle the clip.
pub fn emitCanvasPrimitiveOpts(
    verts: *std.ArrayList(Vertex),
    alloc: std.mem.Allocator,
    canvas: Rect,
    prim: CanvasPrimitive,
    clip: Rect,
    o: Opts,
) void {
    const xf = o.xf;
    switch (prim) {
        .filled_rect => |fr| {
            const p0 = wp(canvas, xf, fr.x, fr.y);
            const p1 = wp(canvas, xf, fr.x + fr.w, fr.y + fr.h);
            emit(verts, alloc, .{
                .x = @min(p0[0], p1[0]),
                .y = @min(p0[1], p1[1]),
                .w = @abs(p1[0] - p0[0]),
                .h = @abs(p1[1] - p0[1]),
            }, fr.color, clip);
        },
        .hline => |h| {
            const half = h.thickness * 0.5;
            emit(verts, alloc, .{
                .x = canvas.x,
                .y = canvas.y + h.y * xf.sy + xf.ty - half,
                .w = canvas.w,
                .h = h.thickness,
            }, h.color, clip);
        },
        .vline => |v| {
            const half = v.thickness * 0.5;
            emit(verts, alloc, .{
                .x = canvas.x + v.x * xf.sx + xf.tx - half,
                .y = canvas.y,
                .w = v.thickness,
                .h = canvas.h,
            }, v.color, clip);
        },
        .marker => |mk| {
            const half = mk.size * 0.5;
            const c = wp(canvas, xf, mk.x, mk.y);
            emit(verts, alloc, .{
                .x = c[0] - half,
                .y = c[1] - half,
                .w = mk.size,
                .h = mk.size,
            }, mk.color, clip);
        },
        .text => {}, // drawn by the caller (needs the text list and the measurer)
        .triangles => |tr| emitTrianglesXf(verts, alloc, canvas, xf, tr.verts, clip),
        .lines => |ln| {
            verts.ensureUnusedCapacity(alloc, ln.segs.len * 6) catch return;
            for (ln.segs) |sg| {
                const a = wp(canvas, xf, sg[0], sg[1]);
                const b = wp(canvas, xf, sg[2], sg[3]);
                strokeSegment(verts, alloc, a, b, ln.thickness, ln.color, 0, 0, o.aa, clip);
            }
        },
        .polyline => |pl| {
            if (pl.points.len < 2) return;
            if (!o.aa) {
                // Historical hard-edged path: independent quads, no joins.
                var i: usize = 1;
                while (i < pl.points.len) : (i += 1) {
                    const a = wp(canvas, xf, pl.points[i - 1].x, pl.points[i - 1].y);
                    const b = wp(canvas, xf, pl.points[i].x, pl.points[i].y);
                    strokeSegment(verts, alloc, a, b, pl.thickness, pl.color, 0, 0, false, clip);
                }
                return;
            }
            strokePoints(verts, alloc, canvas, xf, pl.points, false, pl.thickness, pl.color, true, clip);
        },
        .circle => |c| emitCircle(verts, alloc, canvas, c, clip, o),
        .arc => |ar| {
            const ctr = wp(canvas, xf, ar.x, ar.y);
            const rx = if (ar.screen_radius) ar.radius else ar.radius * @abs(xf.sx);
            const ry = if (ar.screen_radius) ar.radius else ar.radius * @abs(xf.sy);
            if (!(rx > 0 and ry > 0)) return;
            const full = @abs(ar.sweep) >= 2 * std.math.pi;
            const sweep = if (full) 2 * std.math.pi else ar.sweep;
            var buf: [MAX_ARC_POINTS + 1][2]f32 = undefined;
            const pts = arcPoints(&buf, ctr, rx, ry, std.math.sign(xf.sx), std.math.sign(xf.sy), ar.start, sweep, full);
            strokeWindowPath(verts, alloc, pts, full, ar.thickness, ar.color, o.aa, clip);
        },
        .polygon => |pg| emitPolygon(verts, alloc, canvas, pg, clip, o),
    }
}

const MAX_ARC_POINTS = 512;

/// Segments for an arc of radius `r` px through `sweep` radians so the chord
/// error stays under a quarter pixel.
fn arcSegments(r: f32, sweep: f32) usize {
    const tol: f32 = 0.25;
    const ratio = std.math.clamp(1 - tol / @max(r, tol), -1, 1);
    const step = @max(2 * std.math.acos(ratio), 0.02);
    const n: usize = @intFromFloat(@min(@ceil(@abs(sweep) / step), MAX_ARC_POINTS));
    return @max(n, 3);
}

/// Window-space points along an arc. `fx` / `fy` are the transform's axis
/// signs, so angles stay in world orientation under a y-up transform. A full
/// circle returns `n` points (closed by the caller), an open arc `n + 1`.
fn arcPoints(buf: *[MAX_ARC_POINTS + 1][2]f32, ctr: [2]f32, rx: f32, ry: f32, fx: f32, fy: f32, start: f32, sweep: f32, full: bool) [][2]f32 {
    const n = arcSegments(@max(rx, ry), sweep);
    const count = if (full) n else n + 1;
    const nf: f32 = @floatFromInt(n);
    for (0..count) |i| {
        const t = start + sweep * @as(f32, @floatFromInt(i)) / nf;
        buf[i] = .{ ctr[0] + @cos(t) * rx * fx, ctr[1] + @sin(t) * ry * fy };
    }
    return buf[0..count];
}

fn emitCircle(verts: *std.ArrayList(Vertex), alloc: std.mem.Allocator, canvas: Rect, c: CanvasPrimitive.Circle, clip: Rect, o: Opts) void {
    const ctr = wp(canvas, o.xf, c.x, c.y);
    const rx = if (c.screen_radius) c.radius else c.radius * @abs(o.xf.sx);
    const ry = if (c.screen_radius) c.radius else c.radius * @abs(o.xf.sy);
    if (!(rx > 0 and ry > 0) or !std.math.isFinite(ctr[0]) or !std.math.isFinite(ctr[1])) return;
    const reach = @max(rx, ry) + (if (c.stroke != null) c.thickness * 0.5 else 0) + 1.5;
    if (ctr[0] + reach < clip.x or ctr[1] + reach < clip.y or
        ctr[0] - reach > clip.x + clip.w or ctr[1] - reach > clip.y + clip.h) return;

    if (o.sdf_circles and rx == ry) {
        // One SDF quad: an exact antialiased disc / ring at any size.
        const outer = if (c.stroke != null) rx + c.thickness * 0.5 else rx;
        sdf.emitRect(verts, alloc, .{
            .rect = .{ .x = ctr[0] - outer, .y = ctr[1] - outer, .w = 2 * outer, .h = 2 * outer },
            .radii = sdf.Radii.all(outer),
            .fill = c.fill orelse .{ 0, 0, 0, 0 },
            .border_width = if (c.stroke != null) @min(c.thickness, outer) else 0,
            .border = c.stroke orelse .{ 0, 0, 0, 0 },
        }, clip);
        return;
    }

    var buf: [MAX_ARC_POINTS + 1][2]f32 = undefined;
    const pts = arcPoints(&buf, ctr, rx, ry, 1, 1, 0, 2 * std.math.pi, true);
    if (c.fill) |fill| fillWindowPolygon(verts, alloc, pts, fill, o.aa, clip, true);
    if (c.stroke) |stroke| strokeWindowPath(verts, alloc, pts, true, c.thickness, stroke, o.aa, clip);
}

fn emitPolygon(verts: *std.ArrayList(Vertex), alloc: std.mem.Allocator, canvas: Rect, pg: CanvasPrimitive.Polygon, clip: Rect, o: Opts) void {
    if (pg.points.len < 3) return;
    const pts = alloc.alloc([2]f32, pg.points.len) catch return;
    defer alloc.free(pts);
    for (pg.points, pts) |p, *q| {
        q.* = wp(canvas, o.xf, p.x, p.y);
        if (!std.math.isFinite(q[0]) or !std.math.isFinite(q[1])) return;
    }
    if (pg.fill) |fill| fillWindowPolygon(verts, alloc, pts, fill, o.aa, clip, false);
    if (pg.stroke) |stroke| strokeWindowPath(verts, alloc, pts, true, pg.thickness, stroke, o.aa, clip);
}

/// Stroke world-space points (transformed first) with joins.
fn strokePoints(verts: *std.ArrayList(Vertex), alloc: std.mem.Allocator, canvas: Rect, xf: CanvasTransform, points: []const CanvasPoint, closed: bool, thickness: f32, color: [4]f32, aa: bool, clip: Rect) void {
    const pts = alloc.alloc([2]f32, points.len) catch return;
    defer alloc.free(pts);
    for (points, pts) |p, *q| q.* = wp(canvas, xf, p.x, p.y);
    strokeWindowPath(verts, alloc, pts, closed, thickness, color, aa, clip);
}

/// How far to extend a segment end into a join so the two quads meeting
/// there leave no notch: half the width times tan(turn / 2), capped at half
/// the width (a square cap at sharp turns).
fn joinExt(hw: f32, ax: f32, ay: f32, bx: f32, by: f32, cx: f32, cy: f32) f32 {
    const d1x = bx - ax;
    const d1y = by - ay;
    const d2x = cx - bx;
    const d2y = cy - by;
    const l1 = @sqrt(d1x * d1x + d1y * d1y);
    const l2 = @sqrt(d2x * d2x + d2y * d2y);
    if (!(l1 > 0 and l2 > 0)) return 0;
    const cosv = std.math.clamp((d1x * d2x + d1y * d2y) / (l1 * l2), -1, 1);
    if (cosv <= 0) return hw;
    return @min(hw, hw * @sqrt((1 - cosv) / (1 + cosv)));
}

/// Stroke a window-space path (open or closed) segment by segment, with
/// join extensions.
fn strokeWindowPath(verts: *std.ArrayList(Vertex), alloc: std.mem.Allocator, pts: []const [2]f32, closed: bool, thickness: f32, color: [4]f32, aa: bool, clip: Rect) void {
    const n = pts.len;
    if (n < 2) return;
    const hw = @max(thickness, 1) * 0.5;
    const segs = if (closed) n else n - 1;
    verts.ensureUnusedCapacity(alloc, segs * 6) catch return;
    for (0..segs) |i| {
        const a = pts[i];
        const b = pts[(i + 1) % n];
        var e0: f32 = 0;
        var e1: f32 = 0;
        if (closed or i > 0) {
            const p = pts[(i + n - 1) % n];
            e0 = joinExt(hw, p[0], p[1], a[0], a[1], b[0], b[1]);
        }
        if (closed or i + 2 < n) {
            const q = pts[(i + 2) % n];
            e1 = joinExt(hw, a[0], a[1], b[0], b[1], q[0], q[1]);
        }
        strokeSegment(verts, alloc, a, b, thickness, color, e0, e1, aa, clip);
    }
}

/// One stroked segment in window space, clipped to `clip`, its ends
/// extended by `e0` / `e1` px along the segment (joins). Hard-edged: the
/// historical `thickness`-wide quad. Antialiased: `emitAaSegment`.
fn strokeSegment(verts: *std.ArrayList(Vertex), alloc: std.mem.Allocator, a: [2]f32, b: [2]f32, thickness: f32, color: [4]f32, e0: f32, e1: f32, aa: bool, clip: Rect) void {
    var x0 = a[0];
    var y0 = a[1];
    var x1 = b[0];
    var y1 = b[1];
    // Fully-outside segments are rejected; partially-outside ones are
    // trimmed to the clip rect at the data level. The thick quad may still
    // bulge by up to thickness/2 past the boundary at a trimmed endpoint —
    // negligible and bounded.
    if (!clipSegment(&x0, &y0, &x1, &y1, clip)) return;
    if (!aa) {
        if (e0 == 0 and e1 == 0) {
            emitSegmentQuad(verts, alloc, x0, y0, x1, y1, thickness, color);
            return;
        }
        const dx = x1 - x0;
        const dy = y1 - y0;
        const len = @sqrt(dx * dx + dy * dy);
        if (!(len > 0)) return;
        const ux = dx / len;
        const uy = dy / len;
        emitSegmentQuad(verts, alloc, x0 - ux * e0, y0 - uy * e0, x1 + ux * e1, y1 + uy * e1, thickness, color);
        return;
    }
    // A trimmed end sits on the clip edge: push its soft cap outside the clip.
    const pad = thickness * 0.5 + 1;
    const t0 = if (x0 != a[0] or y0 != a[1]) pad else e0;
    const t1 = if (x1 != b[0] or y1 != b[1]) pad else e1;
    emitAaSegment(verts, alloc, x0, y0, x1, y1, thickness, color, t0, t1);
}

/// An antialiased segment: one quad grown by a pixel of margin all round,
/// whose `u` / `v` carry the across / along position normalised so the
/// stroke's edge is at |u| = 1 and its (extended) ends at |v| = 1; the
/// shader turns that into per-pixel coverage (`shaders/quad.wgsl`, mode
/// `a <= -1.5`, alpha = -2 - a). Strokes thinner than a pixel draw one
/// pixel wide at proportionally lower alpha.
pub fn emitAaSegment(verts: *std.ArrayList(Vertex), alloc: std.mem.Allocator, x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, color: [4]f32, e0: f32, e1: f32) void {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const len = @sqrt(dx * dx + dy * dy);
    if (!(len > 0)) return;
    const alpha = color[3] * std.math.clamp(thickness, 0, 1);
    if (!(alpha > 0)) return;
    const hw = @max(thickness, 1) * 0.5;
    const ux = dx / len;
    const uy = dy / len;
    const nx = -uy;
    const ny = ux;
    const hl = (len + e0 + e1) * 0.5; // half length of the visible stroke
    const off = (e1 - e0) * 0.5; // its centre, relative to the segment's
    const mx = (x0 + x1) * 0.5 + ux * off;
    const my = (y0 + y1) * 0.5 + uy * off;
    const m: f32 = 1; // margin, px
    const au = (hw + m) / hw;
    const av = (hl + m) / hl;
    const ax = ux * (hl + m);
    const ay = uy * (hl + m);
    const bx = nx * (hw + m);
    const by = ny * (hw + m);
    const tag = -2 - alpha;
    const c = [4][4]f32{
        .{ mx - ax + bx, my - ay + by, au, -av },
        .{ mx + ax + bx, my + ay + by, au, av },
        .{ mx + ax - bx, my + ay - by, -au, av },
        .{ mx - ax - bx, my - ay - by, -au, -av },
    };
    var q: [6]Vertex = undefined;
    for ([6]usize{ 0, 1, 2, 0, 2, 3 }, &q) |k, *v| {
        v.* = .{ .x = c[k][0], .y = c[k][1], .r = color[0], .g = color[1], .b = color[2], .a = tag, .u = c[k][2], .v = c[k][3] };
    }
    verts.appendSlice(alloc, &q) catch return;
}

/// The outer antialiasing fringe of a filled edge a -> b: a one-pixel band
/// on the side (`nx`, `ny`) (unit, outward) whose coverage falls from 1/2
/// at the edge to 0 half a pixel out. Inside the edge the plain fill draws,
/// so translucent fills are not blended twice.
fn emitAaFringe(verts: *std.ArrayList(Vertex), alloc: std.mem.Allocator, a: [2]f32, b: [2]f32, nx: f32, ny: f32, color: [4]f32) void {
    const tag = -2 - color[3];
    const c = [4][3]f32{
        .{ a[0], a[1], 1 },
        .{ b[0], b[1], 1 },
        .{ b[0] + nx, b[1] + ny, 2 },
        .{ a[0] + nx, a[1] + ny, 2 },
    };
    var q: [6]Vertex = undefined;
    for ([6]usize{ 0, 1, 2, 0, 2, 3 }, &q) |k, *v| {
        v.* = .{ .x = c[k][0], .y = c[k][1], .r = color[0], .g = color[1], .b = color[2], .a = tag, .u = c[k][2], .v = 0 };
    }
    verts.appendSlice(alloc, &q) catch return;
}

fn plainVertex(p: [2]f32, color: [4]f32) Vertex {
    return .{ .x = p[0], .y = p[1], .r = color[0], .g = color[1], .b = color[2], .a = color[3], .u = 0, .v = 0 };
}

fn putTriangle(verts: *std.ArrayList(Vertex), alloc: std.mem.Allocator, a: [2]f32, b: [2]f32, c: [2]f32, color: [4]f32, clip: Rect, inside: bool) void {
    const t = [3]Vertex{ plainVertex(a, color), plainVertex(b, color), plainVertex(c, color) };
    if (inside) verts.appendSlice(alloc, &t) catch return else clipTriangle(verts, alloc, t, clip);
}

/// Fill a window-space simple polygon: ear clipping (`convex` takes a fan
/// instead), triangles clipped to `clip` only when the polygon straddles
/// it, plus an outer antialiasing fringe per edge when `aa`.
fn fillWindowPolygon(verts: *std.ArrayList(Vertex), alloc: std.mem.Allocator, pts: []const [2]f32, color: [4]f32, aa: bool, clip: Rect, convex: bool) void {
    const n = pts.len;
    if (n < 3) return;
    var min_x = pts[0][0];
    var min_y = pts[0][1];
    var max_x = min_x;
    var max_y = min_y;
    var area2: f32 = 0;
    for (pts, 0..) |p, i| {
        min_x = @min(min_x, p[0]);
        min_y = @min(min_y, p[1]);
        max_x = @max(max_x, p[0]);
        max_y = @max(max_y, p[1]);
        const q = pts[(i + 1) % n];
        area2 += p[0] * q[1] - q[0] * p[1];
    }
    if (max_x + 1 < clip.x or max_y + 1 < clip.y or min_x - 1 > clip.x + clip.w or min_y - 1 > clip.y + clip.h) return;
    if (area2 == 0) return;
    const inside = min_x >= clip.x and min_y >= clip.y and max_x <= clip.x + clip.w and max_y <= clip.y + clip.h;

    verts.ensureUnusedCapacity(alloc, (n - 2) * 3) catch return;
    if (convex) {
        for (1..n - 1) |k| putTriangle(verts, alloc, pts[0], pts[k], pts[k + 1], color, clip, inside);
    } else {
        // Ear clipping over an index ring, O(n^2) worst case. A ring that
        // stops yielding ears (self-intersection, collinear runs) is closed
        // with a fan so something sensible still fills.
        const idx = alloc.alloc(u32, n) catch return;
        defer alloc.free(idx);
        for (idx, 0..) |*v, i| v.* = @intCast(i);
        const sign: f32 = if (area2 > 0) 1 else -1;
        var m = n;
        var misses: usize = 0;
        var i: usize = 0;
        while (m > 3 and misses < m) {
            const ia = idx[(i + m - 1) % m];
            const ib = idx[i];
            const ic = idx[(i + 1) % m];
            if (isEar(pts, idx[0..m], ia, ib, ic, sign)) {
                putTriangle(verts, alloc, pts[ia], pts[ib], pts[ic], color, clip, inside);
                std.mem.copyForwards(u32, idx[i .. m - 1], idx[i + 1 .. m]);
                m -= 1;
                misses = 0;
                if (i >= m) i = 0;
            } else {
                i = (i + 1) % m;
                misses += 1;
            }
        }
        for (1..m - 1) |k| putTriangle(verts, alloc, pts[idx[0]], pts[idx[k]], pts[idx[k + 1]], color, clip, inside);
    }

    if (!aa) return;
    verts.ensureUnusedCapacity(alloc, n * 6) catch return;
    // With y down, area2 > 0 is a clockwise ring on screen; its outside is
    // to the left of each edge.
    const s: f32 = if (area2 > 0) 1 else -1;
    for (0..n) |k| {
        const a = pts[k];
        const b = pts[(k + 1) % n];
        const dx = b[0] - a[0];
        const dy = b[1] - a[1];
        const len = @sqrt(dx * dx + dy * dy);
        if (!(len > 0)) continue;
        const nx = dy / len * s;
        const ny = -dx / len * s;
        if (inside) {
            emitAaFringe(verts, alloc, a, b, nx, ny, color);
        } else {
            var x0 = a[0];
            var y0 = a[1];
            var x1 = b[0];
            var y1 = b[1];
            if (clipSegment(&x0, &y0, &x1, &y1, clip)) emitAaFringe(verts, alloc, .{ x0, y0 }, .{ x1, y1 }, nx, ny, color);
        }
    }
}

fn cross(o: [2]f32, a: [2]f32, b: [2]f32) f32 {
    return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
}

fn isEar(pts: []const [2]f32, ring: []const u32, ia: u32, ib: u32, ic: u32, sign: f32) bool {
    const a = pts[ia];
    const b = pts[ib];
    const c = pts[ic];
    if (cross(a, b, c) * sign <= 0) return false; // reflex or degenerate
    for (ring) |j| {
        if (j == ia or j == ib or j == ic) continue;
        const p = pts[j];
        if (cross(a, b, p) * sign >= 0 and cross(b, c, p) * sign >= 0 and cross(c, a, p) * sign >= 0) return false;
    }
    return true;
}

// ── Triangle list emission ─────────────────────────────────────────

const TriVertex = CanvasPrimitive.TriVertex;

fn toVertex(canvas: Rect, xf: CanvasTransform, v: TriVertex) Vertex {
    return .{ .x = canvas.x + v.x * xf.sx + xf.tx, .y = canvas.y + v.y * xf.sy + xf.ty, .r = v.r, .g = v.g, .b = v.b, .a = v.a, .u = 0, .v = 0 };
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
    emitTrianglesXf(verts, alloc, canvas, .{}, list, clip);
}

/// `emitTriangles` with the vertices mapped through `xf` first.
pub fn emitTrianglesXf(
    verts: *std.ArrayList(Vertex),
    alloc: std.mem.Allocator,
    canvas: Rect,
    xf: CanvasTransform,
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
    if (all_finite and boundsInside(canvas, xf, min_x, min_y, max_x, max_y, clip)) {
        const out = verts.addManyAsSlice(alloc, n) catch return;
        for (tris, out) |v, *o| o.* = toVertex(canvas, xf, v);
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
        if (boundsInside(canvas, xf, tx0, ty0, tx1, ty1, clip)) {
            // Tier 2.
            verts.appendSlice(alloc, &.{ toVertex(canvas, xf, t[0]), toVertex(canvas, xf, t[1]), toVertex(canvas, xf, t[2]) }) catch return;
        } else if (boundsOverlap(canvas, xf, tx0, ty0, tx1, ty1, clip)) {
            // Tier 3.
            clipTriangle(verts, alloc, .{ toVertex(canvas, xf, t[0]), toVertex(canvas, xf, t[1]), toVertex(canvas, xf, t[2]) }, clip);
        }
    }
}

/// A world-space box through `xf`, as window-space min/max (a negative
/// scale swaps the ends).
fn xfBox(canvas: Rect, xf: CanvasTransform, x0: f32, y0: f32, x1: f32, y1: f32) [4]f32 {
    const a = wp(canvas, xf, x0, y0);
    const b = wp(canvas, xf, x1, y1);
    return .{ @min(a[0], b[0]), @min(a[1], b[1]), @max(a[0], b[0]), @max(a[1], b[1]) };
}

fn boundsInside(canvas: Rect, xf: CanvasTransform, x0: f32, y0: f32, x1: f32, y1: f32, clip: Rect) bool {
    const r = xfBox(canvas, xf, x0, y0, x1, y1);
    return r[0] >= clip.x and r[1] >= clip.y and r[2] <= clip.x + clip.w and r[3] <= clip.y + clip.h;
}

fn boundsOverlap(canvas: Rect, xf: CanvasTransform, x0: f32, y0: f32, x1: f32, y1: f32, clip: Rect) bool {
    const r = xfBox(canvas, xf, x0, y0, x1, y1);
    return r[2] > clip.x and r[3] > clip.y and r[0] < clip.x + clip.w and r[1] < clip.y + clip.h;
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

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;
const big: Rect = .{ .x = 0, .y = 0, .w = 1000, .h = 1000 };

fn lower(prims: []const CanvasPrimitive, clip: Rect, o: Opts) !std.ArrayList(Vertex) {
    var v: std.ArrayList(Vertex) = .empty;
    for (prims) |p| emitCanvasPrimitiveOpts(&v, testing.allocator, big, p, clip, o);
    return v;
}

/// Sum of triangle areas of plain (a >= 0) vertices.
fn plainArea(v: []const Vertex) f32 {
    var area: f32 = 0;
    var i: usize = 0;
    while (i + 3 <= v.len) : (i += 3) {
        if (v[i].a < 0) continue;
        area += @abs((v[i + 1].x - v[i].x) * (v[i + 2].y - v[i].y) - (v[i + 2].x - v[i].x) * (v[i + 1].y - v[i].y)) * 0.5;
    }
    return area;
}

test "CanvasTransform: apply / invert round-trip, zoomAt keeps the pivot, fit centres" {
    const t: CanvasTransform = .{ .sx = 2, .sy = -3, .tx = 10, .ty = 400 };
    const p = t.invert(t.apply(.{ .x = 7, .y = -5 }));
    try testing.expectApproxEqAbs(@as(f32, 7), p.x, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -5), p.y, 1e-4);
    const z = t.zoomAt(50, 60, 4);
    const before = t.invert(.{ .x = 50, .y = 60 });
    const after = z.apply(before);
    try testing.expectApproxEqAbs(@as(f32, 50), after.x, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 60), after.y, 1e-3);
    const f = CanvasTransform.fit(0, 0, 10, 5, 220, 220, 10, true);
    try testing.expectApproxEqAbs(@as(f32, 20), f.sx, 1e-4);
    try testing.expectApproxEqAbs(@as(f32, -20), f.sy, 1e-4);
    const mid = f.apply(.{ .x = 5, .y = 2.5 });
    try testing.expectApproxEqAbs(@as(f32, 110), mid.x, 1e-3);
    try testing.expectApproxEqAbs(@as(f32, 110), mid.y, 1e-3);
    const top = f.apply(.{ .x = 0, .y = 5 }); // y-up: larger y is higher
    try testing.expect(top.y < mid.y);
    try testing.expect((CanvasTransform{}).isIdentity());
}

test "transform maps lines, rects and triangles; hard edges unchanged at identity" {
    const seg = [_][4]f32{.{ 0, 0, 10, 0 }};
    var v = try lower(&.{.{ .lines = .{ .segs = &seg, .thickness = 2 } }}, big, .{ .xf = .{ .sx = 2, .sy = 2, .tx = 5, .ty = 7 } });
    defer v.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 6), v.items.len);
    for (v.items) |q| {
        try testing.expect(q.x >= 5 - 1e-4 and q.x <= 25 + 1e-4);
        try testing.expect(q.y >= 6 - 1e-4 and q.y <= 8 + 1e-4);
        try testing.expect(q.a == 1);
    }
    var r = try lower(&.{.{ .filled_rect = .{ .x = 1, .y = 1, .w = 2, .h = 2 } }}, big, .{ .xf = .{ .sx = 10, .sy = -10, .tx = 0, .ty = 100 } });
    defer r.deinit(testing.allocator);
    try testing.expectApproxEqAbs(@as(f32, 400), plainArea(r.items), 1e-2);
}

test "antialiased segment: one tagged quad, alpha recoverable, normalised edge coordinates" {
    const seg = [_][4]f32{.{ 10, 10, 50, 10 }};
    var v = try lower(&.{.{ .lines = .{ .segs = &seg, .thickness = 4, .color = .{ 1, 0, 0, 0.5 } } }}, big, .{ .aa = true });
    defer v.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 6), v.items.len);
    for (v.items) |q| {
        try testing.expectApproxEqAbs(@as(f32, 0.5), -2 - q.a, 1e-6);
        try testing.expectApproxEqAbs(@as(f32, 1.5), @abs(q.u), 1e-5); // (hw + 1) / hw, hw = 2
        try testing.expect(q.y >= 7 - 1e-4 and q.y <= 13 + 1e-4); // grown by the 1 px margin
    }
    // Hairline: drawn 1 px wide at a quarter of the alpha.
    var h = try lower(&.{.{ .lines = .{ .segs = &seg, .thickness = 0.25, .color = .{ 1, 1, 1, 1 } } }}, big, .{ .aa = true });
    defer h.deinit(testing.allocator);
    try testing.expectApproxEqAbs(@as(f32, 0.25), -2 - h.items[0].a, 1e-6);
}

test "circle: one SDF quad in the 2D pass, a tessellated fan (+ fringe) otherwise" {
    const c: CanvasPrimitive = .{ .circle = .{ .x = 100, .y = 100, .radius = 20, .fill = .{ 1, 1, 1, 1 } } };
    var s = try lower(&.{c}, big, .{ .sdf_circles = true });
    defer s.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 12), s.items.len);

    var t = try lower(&.{c}, big, .{});
    defer t.deinit(testing.allocator);
    try testing.expect(t.items.len >= 3 * 10);
    // A polygon inscribed in r = 20 under a quarter-pixel chord error.
    const area = plainArea(t.items);
    try testing.expect(area > std.math.pi * 19.5 * 19.5 and area <= std.math.pi * 20 * 20);

    var aa = try lower(&.{c}, big, .{ .aa = true });
    defer aa.deinit(testing.allocator);
    try testing.expect(aa.items.len > t.items.len);

    // screen_radius ignores the zoom; a world radius follows it.
    const xf: CanvasTransform = .{ .sx = 3, .sy = 3 };
    var w = try lower(&.{.{ .circle = .{ .x = 10, .y = 10, .radius = 5, .fill = .{ 1, 1, 1, 1 } } }}, big, .{ .xf = xf });
    defer w.deinit(testing.allocator);
    var px = try lower(&.{.{ .circle = .{ .x = 10, .y = 10, .radius = 5, .fill = .{ 1, 1, 1, 1 }, .screen_radius = true } }}, big, .{ .xf = xf });
    defer px.deinit(testing.allocator);
    try testing.expect(plainArea(w.items) > 8 * plainArea(px.items));
}

test "circle and polygon fully outside the clip emit nothing" {
    const clip: Rect = .{ .x = 0, .y = 0, .w = 50, .h = 50 };
    const sq = [_]CanvasPoint{ .{ .x = 200, .y = 200 }, .{ .x = 300, .y = 200 }, .{ .x = 300, .y = 300 } };
    var v = try lower(&.{
        .{ .circle = .{ .x = 500, .y = 500, .radius = 10, .stroke = .{ 1, 1, 1, 1 } } },
        .{ .polygon = .{ .points = &sq, .stroke = .{ 1, 1, 1, 1 } } },
    }, clip, .{ .aa = true, .sdf_circles = true });
    defer v.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), v.items.len);
}

test "polygon: concave ear clipping covers exactly the polygon, either winding" {
    // An L: 30x30 square minus its 15x15 top-right quarter -> area 675.
    const l = [_]CanvasPoint{
        .{ .x = 0, .y = 0 },   .{ .x = 15, .y = 0 },  .{ .x = 15, .y = 15 },
        .{ .x = 30, .y = 15 }, .{ .x = 30, .y = 30 }, .{ .x = 0, .y = 30 },
    };
    var rev: [6]CanvasPoint = undefined;
    for (l, 0..) |p, i| rev[5 - i] = p;
    const rings = [_][]const CanvasPoint{ &l, &rev };
    for (rings) |pts| {
        var v = try lower(&.{.{ .polygon = .{ .points = pts, .fill = .{ 1, 1, 1, 1 } } }}, big, .{});
        defer v.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 12), v.items.len); // n - 2 triangles
        try testing.expectApproxEqAbs(@as(f32, 675), plainArea(v.items), 1e-2);

        // Antialiased: the fill plus one outward fringe quad per edge, never inside.
        var a = try lower(&.{.{ .polygon = .{ .points = pts, .fill = .{ 1, 1, 1, 1 } } }}, big, .{ .aa = true });
        defer a.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 12 + 6 * 6), a.items.len);
        var k: usize = 12;
        while (k < a.items.len) : (k += 6) {
            // Midpoint of the quad's outer side (u = 2): vertices 2 and 5.
            const o0 = a.items[k + 2];
            const o1 = a.items[k + 5];
            try testing.expectEqual(@as(f32, 2), o0.u);
            const mx = (o0.x + o1.x) * 0.5;
            const my = (o0.y + o1.y) * 0.5;
            const inside_l = mx > 0 and mx < 30 and my > 0 and my < 30 and !(mx > 15 and my < 15);
            try testing.expect(!inside_l);
        }
    }
}

test "polygon straddling the clip is cut to it" {
    const tri = [_]CanvasPoint{ .{ .x = 0, .y = 0 }, .{ .x = 100, .y = 0 }, .{ .x = 0, .y = 100 } };
    const clip: Rect = .{ .x = 0, .y = 0, .w = 50, .h = 50 };
    var v = try lower(&.{.{ .polygon = .{ .points = &tri, .fill = .{ 1, 1, 1, 1 } } }}, clip, .{});
    defer v.deinit(testing.allocator);
    // The whole 50x50 corner lies inside the triangle.
    try testing.expectApproxEqAbs(@as(f32, 2500), plainArea(v.items), 1e-1);
    for (v.items) |q| try testing.expect(q.x <= 50.001 and q.y <= 50.001);
}

test "arc: a quarter turns from +x toward +y; a y-up transform mirrors it" {
    var v = try lower(&.{.{ .arc = .{ .x = 100, .y = 100, .radius = 30, .start = 0, .sweep = std.math.pi / 2.0, .thickness = 2 } }}, big, .{});
    defer v.deinit(testing.allocator);
    try testing.expect(v.items.len >= 6 * 3);
    for (v.items) |q| try testing.expect(q.y >= 98.9 and q.x >= 98.9);
    var up = try lower(&.{.{ .arc = .{ .x = 100, .y = -100, .radius = 30, .start = 0, .sweep = std.math.pi / 2.0, .thickness = 2 } }}, big, .{ .xf = .{ .sy = -1 } });
    defer up.deinit(testing.allocator);
    for (up.items) |q| try testing.expect(q.y <= 101.1);
}

test "perf: 80k antialiased segments through a zoomed transform, culled by the clip" {
    const n: usize = 80_000;
    const segs = try testing.allocator.alloc([4]f32, n);
    defer testing.allocator.free(segs);
    for (segs, 0..) |*sg, i| {
        const x: f32 = @floatFromInt(i % 400);
        const y: f32 = @floatFromInt(i / 400);
        sg.* = .{ x, y, x + 1, y + 0.5 };
    }
    const t0 = std.Io.Clock.awake.now(testing.io).nanoseconds;
    var all = try lower(&.{.{ .lines = .{ .segs = segs } }}, big, .{ .aa = true, .xf = .{ .sx = 2, .sy = 2 } });
    defer all.deinit(testing.allocator);
    try testing.expectEqual(n * 6, all.items.len);
    // Zoomed 8x: most of the field is off the clip and culled.
    var zoomed = try lower(&.{.{ .lines = .{ .segs = segs } }}, big, .{ .aa = true, .xf = .{ .sx = 8, .sy = 8 } });
    defer zoomed.deinit(testing.allocator);
    try testing.expect(zoomed.items.len < n * 6 / 4);
    const ms = @divTrunc(std.Io.Clock.awake.now(testing.io).nanoseconds - t0, std.time.ns_per_ms);
    try testing.expect(ms < 3000);
}

test "polygon: self-intersecting and degenerate rings still terminate inside their bounds" {
    const bowtie = [_]CanvasPoint{ .{ .x = 0, .y = 0 }, .{ .x = 40, .y = 40 }, .{ .x = 40, .y = 0 }, .{ .x = 0, .y = 40 } };
    const flat = [_]CanvasPoint{ .{ .x = 0, .y = 0 }, .{ .x = 10, .y = 0 }, .{ .x = 20, .y = 0 } };
    var v = try lower(&.{
        .{ .polygon = .{ .points = &bowtie, .stroke = .{ 1, 1, 1, 1 } } },
        .{ .polygon = .{ .points = &flat } },
    }, big, .{ .aa = true });
    defer v.deinit(testing.allocator);
    try testing.expect(v.items.len > 0);
    for (v.items) |q| try testing.expect(q.x >= -3 and q.x <= 43 and q.y >= -3 and q.y <= 43);
}
