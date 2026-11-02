//! World-space tessellation of canvas primitives into a retained buffer.
//!
//! The run loop does this once per `.canvas_geometry` resource (hatch 8).
//! Pan and zoom do not come back through here: the vertex shader expands
//! strokes under the canvas transform. What is stored, per kind:
//!
//! ```
//! kind 0 segment        ax,ay = world start, bx,by = world end,
//!                       cx = thickness px, cy = 1 if antialiased else 0,
//!                       e0,e1 = screen-px join extensions, rgba = colour
//! kind 1 triangle       ax,ay = world position, rgba = per-vertex colour
//! kind 2 circle         ax,ay = world centre, bx = world radius (0 if
//!                       screen_radius), by = 1 if screen_radius,
//!                       cx = screen radius px, cy = stroke thickness px,
//!                       dx/dy = fill/stroke present, rgba = fill, srgba = stroke
//! kind 3 fringe         ax,ay -> bx,by = world edge, cx = world shoelace
//!                       sign (+1 / -1), rgba = fill. The shader rebuilds the
//!                       one-pixel outward band after the transform.
//! kind 4 marker         ax,ay = world centre, bx = size px, rgba = colour
//! kind 5 screen segment ax,ay = world centre, bx,by = start offset px,
//!                       cx,cy = end offset px (both BEFORE axis signs),
//!                       dx = thickness px, dy = antialias flag, e0,e1 as kind 0
//! ```
//!
//! Six vertices (corners 0,1,2, 0,2,3) cover a quad. A triangle is three
//! vertices. `shadeSegment` is the CPU twin of the segment expansion; the
//! shader must match it, and it must match `emitAaSegment`.
//!
//! Skipped, because they are canvas-span or need the shaper: `hline`,
//! `vline`, `text`, and a nested `.geometry`. Joins are computed from the
//! stored point directions, so they are exact for a uniform scale (including
//! a y-flip) and only approximate when `|sx| != |sy|`. World arcs are
//! tessellated once at `arc_ref_px` pixels per world unit (chord error
//! 0.25 px at that scale). A denser mesh sits closer to the true arc than
//! the immediate path, which retessellates per frame, and that misses the
//! vector-canvas goldens.

const std = @import("std");
const cmd = @import("../core/cmd.zig");
const CanvasPrimitive = cmd.CanvasPrimitive;
const CanvasPoint = cmd.CanvasPoint;
const vertex = @import("vertex.zig");

const Allocator = std.mem.Allocator;

pub const kind_segment: f32 = 0;
pub const kind_triangle: f32 = 1;
pub const kind_circle: f32 = 2;
pub const kind_fringe: f32 = 3;
pub const kind_marker: f32 = 4;
pub const kind_screen_segment: f32 = 5;

/// Pixels per world unit used to pick a world arc's chord count. 44 matches
/// the immediate tessellator on `vector_canvas`'s 0.35 m release arcs at the
/// golden zoom (~43.7 px/m, chord error 0.25 px). Denser than that (the
/// previous 512) draws a truer arc and fails those pictures. Past this
/// scale the retained chords grow; the immediate path would retessellate.
pub const arc_ref_px: f32 = 44;

const max_arc_points: usize = 512;
const quad_corners = [6]f32{ 0, 1, 2, 0, 2, 3 };

/// One retained vertex. 20 floats, 80 bytes. The shader binds these as
/// ten `vec2` attributes (8-byte aligned): (kind, corner), (ax, ay),
/// (bx, by), (cx, cy), (dx, dy), (r, g), (b, a), (sr, sg), (sb, sa),
/// (e0, e1). `shaders/canvas_geom.wgsl` expands them.
pub const GeomVertex = extern struct {
    kind: f32,
    corner: f32,
    ax: f32,
    ay: f32,
    bx: f32,
    by: f32,
    cx: f32,
    cy: f32,
    dx: f32,
    dy: f32,
    r: f32,
    g: f32,
    b: f32,
    a: f32,
    sr: f32,
    sg: f32,
    sb: f32,
    sa: f32,
    e0: f32,
    e1: f32,
};

comptime {
    if (@sizeOf(GeomVertex) != 80) @compileError("GeomVertex is the shader's 20-float vertex");
}

/// Bytes between per-draw uniforms. WebGPU's minimum uniform-buffer
/// offset alignment; native uses it as a dynamic offset, web as the
/// bind-group buffer offset.
pub const draw_uniform_align: u32 = 256;

/// Per-draw uniform (`shaders/canvas_geom.wgsl` `Draw`). `tx` / `ty`
/// already include the canvas origin.
pub const DrawUniform = extern struct {
    sx: f32,
    sy: f32,
    tx: f32,
    ty: f32,
    clip_x: f32,
    clip_y: f32,
    clip_w: f32,
    clip_h: f32,
};

/// Shared screen uniform (`Screen` in the shader): logical size and
/// device pixels per logical pixel. The fragment clip test divides
/// the framebuffer coordinate by `scale`.
pub const ScreenUniform = extern struct {
    screen_x: f32,
    screen_y: f32,
    scale: f32,
    pad: f32 = 0,
};

comptime {
    if (@sizeOf(DrawUniform) != 32) @compileError("DrawUniform is the shader's 32-byte draw uniform");
    if (@sizeOf(ScreenUniform) != 16) @compileError("ScreenUniform is the shader's 16-byte screen uniform");
}

const List = std.ArrayList(GeomVertex);

/// Tessellate `prims` in world space. `aa` is baked: toggling it is a new
/// resource revision, not a per-frame argument. Caller frees the slice.
pub fn tessellate(alloc: Allocator, prims: []const CanvasPrimitive, aa: bool) ![]GeomVertex {
    var out: List = .empty;
    errdefer out.deinit(alloc);
    for (prims) |prim| try emitPrim(&out, alloc, prim, aa);
    return try out.toOwnedSlice(alloc);
}

fn emitPrim(out: *List, alloc: Allocator, prim: CanvasPrimitive, aa: bool) !void {
    switch (prim) {
        .hline, .vline, .text, .geometry => {},
        .filled_rect => |fr| try emitFilledRect(out, alloc, fr),
        .marker => |mk| try emitMarker(out, alloc, mk),
        .triangles => |tr| try emitTriangles(out, alloc, tr.verts),
        .lines => |ln| try emitLines(out, alloc, ln, aa),
        .polyline => |pl| try strokeCanvas(out, alloc, pl.points, false, pl.thickness, pl.color, aa),
        .circle => |c| try emitCircle(out, alloc, c),
        .arc => |ar| try emitArc(out, alloc, ar, aa),
        .polygon => |pg| try emitPolygon(out, alloc, pg, aa),
    }
}

fn gv(
    kind: f32,
    corner: f32,
    a: [2]f32,
    b: [2]f32,
    c: [2]f32,
    d: [2]f32,
    rgba: [4]f32,
    srgba: [4]f32,
    e0: f32,
    e1: f32,
) GeomVertex {
    return .{
        .kind = kind,
        .corner = corner,
        .ax = a[0],
        .ay = a[1],
        .bx = b[0],
        .by = b[1],
        .cx = c[0],
        .cy = c[1],
        .dx = d[0],
        .dy = d[1],
        .r = rgba[0],
        .g = rgba[1],
        .b = rgba[2],
        .a = rgba[3],
        .sr = srgba[0],
        .sg = srgba[1],
        .sb = srgba[2],
        .sa = srgba[3],
        .e0 = e0,
        .e1 = e1,
    };
}

fn finite2(p: [2]f32) bool {
    return std.math.isFinite(p[0]) and std.math.isFinite(p[1]);
}

fn appendQuad(out: *List, alloc: Allocator, kind: f32, a: [2]f32, b: [2]f32, c: [2]f32, d: [2]f32, rgba: [4]f32, srgba: [4]f32, e0: f32, e1: f32) !void {
    try out.ensureUnusedCapacity(alloc, 6);
    for (quad_corners) |corner| {
        out.appendAssumeCapacity(gv(kind, corner, a, b, c, d, rgba, srgba, e0, e1));
    }
}

fn emitFilledRect(out: *List, alloc: Allocator, fr: CanvasPrimitive.FilledRect) !void {
    if (!(fr.w != 0 and fr.h != 0)) return;
    const p = [4][2]f32{
        .{ fr.x, fr.y },
        .{ fr.x + fr.w, fr.y },
        .{ fr.x + fr.w, fr.y + fr.h },
        .{ fr.x, fr.y + fr.h },
    };
    for (p) |q| if (!finite2(q)) return;
    try appendTriangle(out, alloc, p[0], p[1], p[2], fr.color, fr.color, fr.color);
    try appendTriangle(out, alloc, p[0], p[2], p[3], fr.color, fr.color, fr.color);
}

fn emitMarker(out: *List, alloc: Allocator, mk: CanvasPrimitive.Marker) !void {
    if (!(mk.size > 0) or !std.math.isFinite(mk.x) or !std.math.isFinite(mk.y)) return;
    try appendQuad(out, alloc, kind_marker, .{ mk.x, mk.y }, .{ mk.size, 0 }, .{ 0, 0 }, .{ 0, 0 }, mk.color, .{ 0, 0, 0, 0 }, 0, 0);
}

fn appendTriangle(out: *List, alloc: Allocator, a: [2]f32, b: [2]f32, c: [2]f32, ca: [4]f32, cb: [4]f32, cc: [4]f32) !void {
    try out.ensureUnusedCapacity(alloc, 3);
    out.appendAssumeCapacity(gv(kind_triangle, 0, a, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, ca, .{ 0, 0, 0, 0 }, 0, 0));
    out.appendAssumeCapacity(gv(kind_triangle, 0, b, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, cb, .{ 0, 0, 0, 0 }, 0, 0));
    out.appendAssumeCapacity(gv(kind_triangle, 0, c, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 }, cc, .{ 0, 0, 0, 0 }, 0, 0));
}

fn emitTriangles(out: *List, alloc: Allocator, verts: []const CanvasPrimitive.TriVertex) !void {
    const n = verts.len - verts.len % 3;
    var i: usize = 0;
    while (i < n) : (i += 3) {
        const t = verts[i..][0..3];
        var ok = true;
        for (t) |v| if (!std.math.isFinite(v.x) or !std.math.isFinite(v.y)) {
            ok = false;
        };
        if (!ok) continue;
        try appendTriangle(
            out,
            alloc,
            .{ t[0].x, t[0].y },
            .{ t[1].x, t[1].y },
            .{ t[2].x, t[2].y },
            .{ t[0].r, t[0].g, t[0].b, t[0].a },
            .{ t[1].r, t[1].g, t[1].b, t[1].a },
            .{ t[2].r, t[2].g, t[2].b, t[2].a },
        );
    }
}

fn emitLines(out: *List, alloc: Allocator, ln: CanvasPrimitive.Lines, aa: bool) !void {
    for (ln.segs) |sg| {
        try appendSegment(out, alloc, .{ sg[0], sg[1] }, .{ sg[2], sg[3] }, ln.thickness, ln.color, 0, 0, aa, false, .{ 0, 0 });
    }
}

fn emitCircle(out: *List, alloc: Allocator, c: CanvasPrimitive.Circle) !void {
    if (!(c.radius > 0) or !std.math.isFinite(c.x) or !std.math.isFinite(c.y) or !std.math.isFinite(c.radius)) return;
    if (c.fill == null and c.stroke == null) return;
    const fill = c.fill orelse .{ 0, 0, 0, 0 };
    const stroke = c.stroke orelse .{ 0, 0, 0, 0 };
    const world_r: f32 = if (c.screen_radius) 0 else c.radius;
    const screen_r: f32 = if (c.screen_radius) c.radius else 0;
    try appendQuad(
        out,
        alloc,
        kind_circle,
        .{ c.x, c.y },
        .{ world_r, if (c.screen_radius) 1 else 0 },
        .{ screen_r, c.thickness },
        .{ if (c.fill != null) 1 else 0, if (c.stroke != null) 1 else 0 },
        fill,
        stroke,
        0,
        0,
    );
}

fn emitArc(out: *List, alloc: Allocator, ar: CanvasPrimitive.Arc, aa: bool) !void {
    if (!(ar.radius > 0) or !std.math.isFinite(ar.x) or !std.math.isFinite(ar.y)) return;
    const full = @abs(ar.sweep) >= 2 * std.math.pi;
    const sweep = if (full) 2 * std.math.pi else ar.sweep;
    const r_px = if (ar.screen_radius) ar.radius else ar.radius * arc_ref_px;
    var buf: [max_arc_points + 1][2]f32 = undefined;
    const pts = arcPoints(&buf, ar.radius, ar.start, sweep, full, r_px);
    if (ar.screen_radius) {
        try strokePts(out, alloc, pts, full, ar.thickness, ar.color, aa, true, .{ ar.x, ar.y });
    } else {
        // Points are offsets from the centre; shift them into world space.
        var world: [max_arc_points + 1][2]f32 = undefined;
        for (pts, 0..) |p, i| world[i] = .{ ar.x + p[0], ar.y + p[1] };
        try strokePts(out, alloc, world[0..pts.len], full, ar.thickness, ar.color, aa, false, .{ 0, 0 });
    }
}

fn arcPointCount(r_px: f32, sweep: f32) usize {
    const tol: f32 = 0.25;
    const ratio = std.math.clamp(1 - tol / @max(r_px, tol), -1, 1);
    const step = @max(2 * std.math.acos(ratio), 0.02);
    const n: usize = @intFromFloat(@min(@ceil(@abs(sweep) / step), max_arc_points));
    return @max(n, 3);
}

/// Points along an arc centred at the origin, angles in world orientation
/// (0 = +x, positive toward +y). A full circle returns `n` points.
fn arcPoints(buf: *[max_arc_points + 1][2]f32, radius: f32, start: f32, sweep: f32, full: bool, r_px: f32) [][2]f32 {
    const n = arcPointCount(r_px, sweep);
    const count = if (full) n else n + 1;
    const nf: f32 = @floatFromInt(n);
    for (0..count) |i| {
        const t = start + sweep * @as(f32, @floatFromInt(i)) / nf;
        buf[i] = .{ @cos(t) * radius, @sin(t) * radius };
    }
    return buf[0..count];
}

fn emitPolygon(out: *List, alloc: Allocator, pg: CanvasPrimitive.Polygon, aa: bool) !void {
    if (pg.points.len < 3) return;
    const pts = try alloc.alloc([2]f32, pg.points.len);
    defer alloc.free(pts);
    for (pg.points, pts) |p, *q| {
        q.* = .{ p.x, p.y };
        if (!finite2(q.*)) return;
    }
    if (pg.fill) |fill| try fillPolygon(out, alloc, pts, fill, aa);
    if (pg.stroke) |stroke| try strokePts(out, alloc, pts, true, pg.thickness, stroke, aa, false, .{ 0, 0 });
}

fn fillPolygon(out: *List, alloc: Allocator, pts: []const [2]f32, color: [4]f32, aa: bool) !void {
    const n = pts.len;
    if (n < 3) return;
    var area2: f32 = 0;
    for (pts, 0..) |p, i| {
        const q = pts[(i + 1) % n];
        area2 += p[0] * q[1] - q[0] * p[1];
    }
    if (area2 == 0) return;
    const sign: f32 = if (area2 > 0) 1 else -1;

    const idx = try alloc.alloc(u32, n);
    defer alloc.free(idx);
    for (idx, 0..) |*v, i| v.* = @intCast(i);
    var m = n;
    var misses: usize = 0;
    var i: usize = 0;
    while (m > 3 and misses < m) {
        const ia = idx[(i + m - 1) % m];
        const ib = idx[i];
        const ic = idx[(i + 1) % m];
        if (isEar(pts, idx[0..m], ia, ib, ic, sign)) {
            try appendTriangle(out, alloc, pts[ia], pts[ib], pts[ic], color, color, color);
            std.mem.copyForwards(u32, idx[i .. m - 1], idx[i + 1 .. m]);
            m -= 1;
            misses = 0;
            if (i >= m) i = 0;
        } else {
            i = (i + 1) % m;
            misses += 1;
        }
    }
    for (1..m - 1) |k| {
        try appendTriangle(out, alloc, pts[idx[0]], pts[idx[k]], pts[idx[k + 1]], color, color, color);
    }

    if (!aa) return;
    for (0..n) |k| {
        const a = pts[k];
        const b = pts[(k + 1) % n];
        const dx = b[0] - a[0];
        const dy = b[1] - a[1];
        if (!(@sqrt(dx * dx + dy * dy) > 0)) continue;
        try appendQuad(out, alloc, kind_fringe, a, b, .{ sign, 0 }, .{ 0, 0 }, color, .{ 0, 0, 0, 0 }, 0, 0);
    }
}

fn cross(o: [2]f32, a: [2]f32, b: [2]f32) f32 {
    return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
}

fn isEar(pts: []const [2]f32, ring: []const u32, ia: u32, ib: u32, ic: u32, sign: f32) bool {
    const a = pts[ia];
    const b = pts[ib];
    const c = pts[ic];
    if (cross(a, b, c) * sign <= 0) return false;
    for (ring) |j| {
        if (j == ia or j == ib or j == ic) continue;
        const p = pts[j];
        if (cross(a, b, p) * sign >= 0 and cross(b, c, p) * sign >= 0 and cross(c, a, p) * sign >= 0) return false;
    }
    return true;
}

fn strokeCanvas(
    out: *List,
    alloc: Allocator,
    points: []const CanvasPoint,
    closed: bool,
    thickness: f32,
    color: [4]f32,
    aa: bool,
) !void {
    if (points.len < 2) return;
    const pts = try alloc.alloc([2]f32, points.len);
    defer alloc.free(pts);
    for (points, pts) |p, *q| q.* = .{ p.x, p.y };
    try strokePts(out, alloc, pts, closed, thickness, color, aa, false, .{ 0, 0 });
}

fn strokePts(
    out: *List,
    alloc: Allocator,
    pts: []const [2]f32,
    closed: bool,
    thickness: f32,
    color: [4]f32,
    aa: bool,
    screen: bool,
    center: [2]f32,
) !void {
    const n = pts.len;
    if (n < 2) return;
    const hw = @max(thickness, 1) * 0.5;
    const segs = if (closed) n else n - 1;
    // Joins for every stroked path except a hard polyline. Callers pass
    // `aa` for an open polyline and `true` (via `closed`, or aa) otherwise:
    // a closed outline joins even when the edges are hard, matching
    // `strokeWindowPath`. An open hard polyline does not.
    const joins = closed or aa;
    for (0..segs) |i| {
        const a = pts[i];
        const b = pts[(i + 1) % n];
        var e0: f32 = 0;
        var e1: f32 = 0;
        if (joins and (closed or i > 0)) {
            const p = pts[(i + n - 1) % n];
            e0 = joinExt(hw, p[0], p[1], a[0], a[1], b[0], b[1]);
        }
        if (joins and (closed or i + 2 < n)) {
            const q = pts[(i + 2) % n];
            e1 = joinExt(hw, a[0], a[1], b[0], b[1], q[0], q[1]);
        }
        try appendSegment(out, alloc, a, b, thickness, color, e0, e1, aa, screen, center);
    }
}

/// How far to extend a segment end into a join, in the same units as `hw`
/// (screen px). The angle comes from the stored points; under a uniform
/// scale that is the screen angle too.
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

fn appendSegment(
    out: *List,
    alloc: Allocator,
    a: [2]f32,
    b: [2]f32,
    thickness: f32,
    color: [4]f32,
    e0: f32,
    e1: f32,
    aa: bool,
    screen: bool,
    center: [2]f32,
) !void {
    if (!finite2(a) or !finite2(b)) return;
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    if (!(@sqrt(dx * dx + dy * dy) > 0)) return;
    if (aa) {
        const alpha = color[3] * std.math.clamp(thickness, 0, 1);
        if (!(alpha > 0)) return;
    }
    if (screen) {
        if (!finite2(center)) return;
        try appendQuad(out, alloc, kind_screen_segment, center, a, b, .{ thickness, if (aa) 1 else 0 }, color, .{ 0, 0, 0, 0 }, e0, e1);
    } else {
        try appendQuad(out, alloc, kind_segment, a, b, .{ thickness, if (aa) 1 else 0 }, .{ 0, 0 }, color, .{ 0, 0, 0, 0 }, e0, e1);
    }
}

/// One expanded corner: window px, the across/along uv, and the
/// pre-coverage alpha (`emitAaSegment`'s `-2 - a`).
pub const Shaded = struct { x: f32, y: f32, u: f32, v: f32, a: f32 };

/// Expand one retained segment the way the vertex shader does. `tx` / `ty`
/// already include the canvas origin. Null when the stroke is degenerate
/// or (antialiased) fully transparent.
pub fn shadeSegment(v: GeomVertex, sx: f32, sy: f32, tx: f32, ty: f32) ?[6]Shaded {
    var x0: f32 = undefined;
    var y0: f32 = undefined;
    var x1: f32 = undefined;
    var y1: f32 = undefined;
    var thickness: f32 = undefined;
    var aa = false;
    if (v.kind == kind_segment) {
        x0 = tx + v.ax * sx;
        y0 = ty + v.ay * sy;
        x1 = tx + v.bx * sx;
        y1 = ty + v.by * sy;
        thickness = v.cx;
        aa = v.cy > 0.5;
    } else if (v.kind == kind_screen_segment) {
        const sgx = std.math.sign(sx);
        const sgy = std.math.sign(sy);
        const cxs = tx + v.ax * sx;
        const cys = ty + v.ay * sy;
        x0 = cxs + v.bx * sgx;
        y0 = cys + v.by * sgy;
        x1 = cxs + v.cx * sgx;
        y1 = cys + v.cy * sgy;
        thickness = v.dx;
        aa = v.dy > 0.5;
    } else return null;

    if (aa) return expandAa(x0, y0, x1, y1, thickness, v.a, v.e0, v.e1);
    return expandHard(x0, y0, x1, y1, thickness, v.a, v.e0, v.e1);
}

fn expandAa(x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, alpha_in: f32, e0: f32, e1: f32) ?[6]Shaded {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const len = @sqrt(dx * dx + dy * dy);
    if (!(len > 0)) return null;
    const alpha = alpha_in * std.math.clamp(thickness, 0, 1);
    if (!(alpha > 0)) return null;
    const hw = @max(thickness, 1) * 0.5;
    const ux = dx / len;
    const uy = dy / len;
    const nx = -uy;
    const ny = ux;
    const hl = (len + e0 + e1) * 0.5;
    const off = (e1 - e0) * 0.5;
    const mx = (x0 + x1) * 0.5 + ux * off;
    const my = (y0 + y1) * 0.5 + uy * off;
    const m: f32 = 1;
    const au = (hw + m) / hw;
    const av = (hl + m) / hl;
    const ax = ux * (hl + m);
    const ay = uy * (hl + m);
    const bx = nx * (hw + m);
    const by = ny * (hw + m);
    const c = [4][4]f32{
        .{ mx - ax + bx, my - ay + by, au, -av },
        .{ mx + ax + bx, my + ay + by, au, av },
        .{ mx + ax - bx, my + ay - by, -au, av },
        .{ mx - ax - bx, my - ay - by, -au, -av },
    };
    var o: [6]Shaded = undefined;
    for ([6]usize{ 0, 1, 2, 0, 2, 3 }, 0..) |k, i| {
        o[i] = .{ .x = c[k][0], .y = c[k][1], .u = c[k][2], .v = c[k][3], .a = alpha };
    }
    return o;
}

fn expandHard(x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, alpha: f32, e0: f32, e1: f32) ?[6]Shaded {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const len = @sqrt(dx * dx + dy * dy);
    if (!(len > 0)) return null;
    const ux = dx / len;
    const uy = dy / len;
    const sx0 = x0 - ux * e0;
    const sy0 = y0 - uy * e0;
    const sx1 = x1 + ux * e1;
    const sy1 = y1 + uy * e1;
    const half = thickness * 0.5;
    const nx = -uy * half;
    const ny = ux * half;
    const c = [4][2]f32{
        .{ sx0 + nx, sy0 + ny },
        .{ sx1 + nx, sy1 + ny },
        .{ sx1 - nx, sy1 - ny },
        .{ sx0 - nx, sy0 - ny },
    };
    var o: [6]Shaded = undefined;
    for ([6]usize{ 0, 1, 2, 0, 2, 3 }, 0..) |k, i| {
        o[i] = .{ .x = c[k][0], .y = c[k][1], .u = 0, .v = 0, .a = alpha };
    }
    return o;
}

// ── Tests ──────────────────────────────────────────────────────────

const Vertex = vertex.Vertex;

fn expectShaded(shaded: [6]Shaded, cpu: []const Vertex) !void {
    try std.testing.expectEqual(shaded.len, cpu.len);
    for (shaded, cpu) |s, q| {
        try std.testing.expectEqual(q.x, s.x);
        try std.testing.expectEqual(q.y, s.y);
        try std.testing.expectEqual(q.u, s.u);
        try std.testing.expectEqual(q.v, s.v);
        // The CPU path stores alpha as `-2 - a`; decoding it is not
        // bit-exact for every f32 (0.8 round-trips as 0.79999995).
        try std.testing.expectApproxEqAbs(-2 - q.a, s.a, 1e-5);
    }
}

test "shadeSegment matches emitAaSegment for a world segment" {
    const canvas_tess = @import("canvas_tess.zig");
    const alloc = std.testing.allocator;
    const color = [4]f32{ 0.2, 0.4, 0.6, 0.8 };
    const cases = [_]struct { sx: f32, sy: f32, tx: f32, ty: f32, thickness: f32, e0: f32, e1: f32 }{
        .{ .sx = 1, .sy = 1, .tx = 0, .ty = 0, .thickness = 2.5, .e0 = 0.5, .e1 = 1.25 },
        .{ .sx = 2, .sy = -2, .tx = 5, .ty = 80, .thickness = 2.5, .e0 = 0, .e1 = 0 },
        .{ .sx = 1, .sy = 1, .tx = 3, .ty = 4, .thickness = 0.4, .e0 = 0, .e1 = 0 },
    };
    const x0: f32 = 1;
    const y0: f32 = 2;
    const x1: f32 = 4;
    const y1: f32 = -1;
    for (cases) |c| {
        var cpu: std.ArrayList(Vertex) = .empty;
        defer cpu.deinit(alloc);
        const p0x = c.tx + x0 * c.sx;
        const p0y = c.ty + y0 * c.sy;
        const p1x = c.tx + x1 * c.sx;
        const p1y = c.ty + y1 * c.sy;
        canvas_tess.emitAaSegment(&cpu, alloc, p0x, p0y, p1x, p1y, c.thickness, color, c.e0, c.e1);
        const v = gv(kind_segment, 0, .{ x0, y0 }, .{ x1, y1 }, .{ c.thickness, 1 }, .{ 0, 0 }, color, .{ 0, 0, 0, 0 }, c.e0, c.e1);
        try expectShaded(shadeSegment(v, c.sx, c.sy, c.tx, c.ty).?, cpu.items);
    }
}

test "shadeSegment matches emitAaSegment for a screen-px arc segment" {
    const canvas_tess = @import("canvas_tess.zig");
    const alloc = std.testing.allocator;
    const color = [4]f32{ 0.1, 0.2, 0.3, 1 };
    const thickness: f32 = 1.5;
    const sx: f32 = -2;
    const sy: f32 = -3;
    const tx: f32 = 1;
    const ty: f32 = 2;
    const center = [2]f32{ 10, 20 };
    const a = [2]f32{ 3, 0 };
    const b = [2]f32{ 0, 4 };
    const v = gv(kind_screen_segment, 0, center, a, b, .{ thickness, 1 }, color, .{ 0, 0, 0, 0 }, 0.25, 0.5);
    const sgx = std.math.sign(sx);
    const sgy = std.math.sign(sy);
    const cxs = tx + center[0] * sx;
    const cys = ty + center[1] * sy;
    var cpu: std.ArrayList(Vertex) = .empty;
    defer cpu.deinit(alloc);
    canvas_tess.emitAaSegment(&cpu, alloc, cxs + a[0] * sgx, cys + a[1] * sgy, cxs + b[0] * sgx, cys + b[1] * sgy, thickness, color, 0.25, 0.5);
    try expectShaded(shadeSegment(v, sx, sy, tx, ty).?, cpu.items);
}

test "a tessellated line round-trips through shadeSegment, joins included" {
    const canvas_tess = @import("canvas_tess.zig");
    const alloc = std.testing.allocator;
    const color = [4]f32{ 0.9, 0.1, 0.2, 1 };
    const thickness: f32 = 2;
    const pts = [_]CanvasPoint{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 0 },
        .{ .x = 1, .y = 1 },
    };
    const prim = CanvasPrimitive{ .polyline = .{ .points = &pts, .color = color, .thickness = thickness } };
    const verts = try tessellate(alloc, &.{prim}, true);
    defer alloc.free(verts);
    try std.testing.expectEqual(@as(usize, 12), verts.len);
    // 90-degree corner: the extension is hw = 1 screen px. The open polyline's
    // second segment has that join at its start and none at its end.
    try std.testing.expectEqual(kind_segment, verts[6].kind);
    try std.testing.expectEqual(@as(f32, 1), verts[6].e0);
    try std.testing.expectEqual(@as(f32, 0), verts[6].e1);

    const sx: f32 = 2;
    const sy: f32 = -2;
    var cpu: std.ArrayList(Vertex) = .empty;
    defer cpu.deinit(alloc);
    canvas_tess.emitAaSegment(&cpu, alloc, 2, 0, 2, -2, thickness, color, 1, 0);
    try expectShaded(shadeSegment(verts[6], sx, sy, 0, 0).?, cpu.items);
}

test "lines keep six vertices per finite segment and drop the rest" {
    const alloc = std.testing.allocator;
    const segs = [_][4]f32{
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 0 },
        .{ std.math.nan(f32), 0, 1, 0 },
        .{ 2, 2, 5, 2 },
    };
    const prim = CanvasPrimitive{ .lines = .{ .segs = &segs, .thickness = 1, .color = .{ 1, 1, 1, 1 } } };
    const aa = try tessellate(alloc, &.{prim}, true);
    defer alloc.free(aa);
    const hard = try tessellate(alloc, &.{prim}, false);
    defer alloc.free(hard);
    try std.testing.expectEqual(@as(usize, 12), aa.len);
    try std.testing.expectEqual(@as(usize, 12), hard.len);
    try std.testing.expectEqual(@as(f32, 1), aa[0].cy);
    try std.testing.expectEqual(@as(f32, 0), hard[0].cy);
    try std.testing.expectEqual(@as(f32, 0), aa[0].e0);
}

test "a circle stays analytic and a marker stays a screen-px square" {
    const alloc = std.testing.allocator;
    const prims = [_]CanvasPrimitive{
        .{ .circle = .{ .x = 3, .y = 4, .radius = 2.5, .screen_radius = true, .fill = .{ 1, 0, 0, 1 }, .stroke = .{ 0, 1, 0, 1 }, .thickness = 1.5 } },
        .{ .marker = .{ .x = 8, .y = 9, .size = 4, .color = .{ 0, 0, 1, 1 } } },
        .{ .hline = .{ .y = 1 } },
        .{ .text = .{ .x = 0, .y = 0, .content = "no" } },
        .{ .geometry = .{ .key = 3 } },
    };
    const verts = try tessellate(alloc, &prims, true);
    defer alloc.free(verts);
    try std.testing.expectEqual(@as(usize, 12), verts.len);
    try std.testing.expectEqual(kind_circle, verts[0].kind);
    try std.testing.expectEqual(@as(f32, 3), verts[0].ax);
    try std.testing.expectEqual(@as(f32, 4), verts[0].ay);
    try std.testing.expectEqual(@as(f32, 0), verts[0].bx);
    try std.testing.expectEqual(@as(f32, 1), verts[0].by);
    try std.testing.expectEqual(@as(f32, 2.5), verts[0].cx);
    try std.testing.expectEqual(kind_marker, verts[6].kind);
    try std.testing.expectEqual(@as(f32, 4), verts[6].bx);
}

test "an antialiased polygon fills, fringes, and strokes; hard skips the fringe" {
    const alloc = std.testing.allocator;
    const pts = [_]CanvasPoint{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 0 },
        .{ .x = 1, .y = 1 },
        .{ .x = 0, .y = 1 },
    };
    const prim = CanvasPrimitive{ .polygon = .{
        .points = &pts,
        .fill = .{ 0.2, 0.3, 0.4, 1 },
        .stroke = .{ 0, 0, 0, 1 },
        .thickness = 2,
    } };
    const aa = try tessellate(alloc, &.{prim}, true);
    defer alloc.free(aa);
    const hard = try tessellate(alloc, &.{prim}, false);
    defer alloc.free(hard);
    // 2 triangles + 4 fringe edges + 4 stroke segments, versus no fringe.
    try std.testing.expectEqual(@as(usize, 6 + 24 + 24), aa.len);
    try std.testing.expectEqual(@as(usize, 6 + 24), hard.len);
    try std.testing.expectEqual(kind_triangle, aa[0].kind);
    try std.testing.expectEqual(kind_fringe, aa[6].kind);
    try std.testing.expectEqual(@as(f32, 1), aa[6].cx);
    try std.testing.expectEqual(kind_segment, aa[30].kind);
    try std.testing.expectEqual(@as(f32, 1), aa[30].e0);
}

test "a world arc is kind 0 and a screen-radius arc is kind 5" {
    const alloc = std.testing.allocator;
    const prims = [_]CanvasPrimitive{
        .{ .arc = .{ .x = 1, .y = 2, .radius = 0.35, .sweep = std.math.pi, .thickness = 1, .color = .{ 1, 1, 1, 1 } } },
        .{ .arc = .{ .x = 1, .y = 2, .radius = 8, .sweep = std.math.pi, .thickness = 1, .screen_radius = true, .color = .{ 1, 1, 1, 1 } } },
    };
    const verts = try tessellate(alloc, &prims, true);
    defer alloc.free(verts);
    try std.testing.expect(verts.len > 12);
    try std.testing.expectEqual(kind_segment, verts[0].kind);
    var saw_screen = false;
    for (verts) |v| if (v.kind == kind_screen_segment) {
        saw_screen = true;
        break;
    };
    try std.testing.expect(saw_screen);
}

test "a hard segment quad matches the thickness/2 corners" {
    const v = gv(kind_segment, 0, .{ 0, 0 }, .{ 10, 0 }, .{ 2, 0 }, .{ 0, 0 }, .{ 1, 0, 0, 0.5 }, .{ 0, 0, 0, 0 }, 1, 2);
    const s = shadeSegment(v, 1, 1, 0, 0).?;
    // Extended to [-1, 0] .. [12, 0], half-width 1.
    try std.testing.expectEqual(@as(f32, -1), s[0].x);
    try std.testing.expectEqual(@as(f32, 1), s[0].y);
    try std.testing.expectEqual(@as(f32, 12), s[1].x);
    try std.testing.expectEqual(@as(f32, 1), s[1].y);
    try std.testing.expectEqual(@as(f32, 12), s[2].x);
    try std.testing.expectEqual(@as(f32, -1), s[2].y);
    try std.testing.expectEqual(@as(f32, 0.5), s[0].a);
}
