//! World-space tessellation of canvas primitives into a retained buffer.
//! Vertex record layout and the shader contract: SRC.md.

const std = @import("std");
const cmd = @import("../core/cmd.zig");
const CanvasPrimitive = cmd.CanvasPrimitive;
const CanvasPoint = cmd.CanvasPoint;
const tess = @import("canvas_tess.zig");

const Allocator = std.mem.Allocator;

pub const kind_segment: f32 = 0;
pub const kind_triangle: f32 = 1;
pub const kind_circle: f32 = 2;
pub const kind_fringe: f32 = 3;
pub const kind_marker: f32 = 4;
pub const kind_screen_segment: f32 = 5;
pub const kind_arc: f32 = 6;

const max_arc_points: usize = tess.MAX_ARC_POINTS;
const quad_corners = [6]f32{ 0, 1, 2, 0, 2, 3 };

/// One retained vertex: ten `vec2` attributes for `shaders/canvas_geom.wgsl`.
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

/// Bytes between per-draw uniforms: WebGPU's minimum uniform-buffer offset alignment.
pub const draw_uniform_align: u32 = 256;

/// Per-draw uniform (`Draw` in the shader); `tx` / `ty` include the canvas origin.
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

/// Screen uniform (`Screen` in the shader): logical size and device pixels per logical pixel.
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

/// Tessellate `prims` in world space with `aa` baked in. Caller frees the slice.
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
    if (!(ar.radius > 0) or !finite2(.{ ar.x, ar.y }) or !finite2(.{ ar.start, ar.sweep }) or ar.sweep == 0) return;
    const full = @abs(ar.sweep) >= 2 * std.math.pi;
    const sweep = if (full) 2 * std.math.pi else ar.sweep;
    if (ar.screen_radius) {
        var buf: [max_arc_points + 1][2]f32 = undefined;
        const pts = arcPoints(&buf, ar.radius, ar.start, sweep, full);
        return strokePts(out, alloc, pts, full, ar.thickness, ar.color, aa, true, .{ ar.x, ar.y });
    }
    // A world radius has no pixel size until the transform is known, so the shader draws the arc analytically.
    if (aa and !(ar.color[3] * std.math.clamp(ar.thickness, 0, 1) > 0)) return;
    try appendQuad(out, alloc, kind_arc, .{ ar.x, ar.y }, .{ ar.radius, ar.thickness }, .{ ar.start, sweep }, .{ if (aa) 1 else 0, 0 }, ar.color, .{ 0, 0, 0, 0 }, 0, 0);
}

fn arcPoints(buf: *[max_arc_points + 1][2]f32, radius: f32, start: f32, sweep: f32, full: bool) [][2]f32 {
    const n = tess.arcSegments(radius, sweep);
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
        if (tess.isEar(pts, idx[0..m], ia, ib, ic, sign)) {
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
    // A closed outline joins even with hard edges, as `strokeWindowPath` does.
    const joins = closed or aa;
    for (0..segs) |i| {
        const a = pts[i];
        const b = pts[(i + 1) % n];
        var e0: f32 = 0;
        var e1: f32 = 0;
        if (joins and (closed or i > 0)) {
            const p = pts[(i + n - 1) % n];
            e0 = tess.joinExt(hw, p[0], p[1], a[0], a[1], b[0], b[1]);
        }
        if (joins and (closed or i + 2 < n)) {
            const q = pts[(i + 2) % n];
            e1 = tess.joinExt(hw, a[0], a[1], b[0], b[1], q[0], q[1]);
        }
        try appendSegment(out, alloc, a, b, thickness, color, e0, e1, aa, screen, center);
    }
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
