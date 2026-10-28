//! Vector canvas: a structural-frame-sized drawing (about 80 000 members,
//! 20 000 nodes, supports, moment diagrams) on one pan / zoom canvas.
//!
//! The geometry is built ONCE, in world units (metres, y up), into Model-owned
//! slices. `view` hands the same slices to the canvas every frame; pan and zoom
//! change only `CanvasStyle.transform`, so the view does no per-primitive work
//! and everything off the canvas is culled while lowering. Lines, circles,
//! arcs and polygons are antialiased (`CanvasStyle.antialias`). The `key` on
//! the big batches tells the frame diff the geometry did not change.
//!
//! Input (one `pointerMsg` hook): drag pans, the wheel zooms about the cursor,
//! the canvas reports its size (`layout`) so the first frame can fit the frame.

const std = @import("std");
const teak = @import("teak");

pub const CANVAS_ID: u32 = 1;
pub const BAYS: usize = 200; // columns of bays
pub const STORIES: usize = 100;
pub const BAY_W: f32 = 6; // m
pub const STORY_H: f32 = 3.5; // m
const MIN_SCALE: f32 = 0.5; // px per metre
const MAX_SCALE: f32 = 400;

pub const Geometry = struct {
    /// Beams, columns and both bracing diagonals: `{x0, y0, x1, y1}` in metres.
    members: []const [4]f32,
    braces: []const [4]f32,
    /// One node dot per joint.
    nodes: []const teak.CanvasPrimitive,
    /// Supports (triangles), moment diagrams (polygons) and release arcs.
    overlays: []const teak.CanvasPrimitive,

    pub fn build(a: std.mem.Allocator) !Geometry {
        const nx = BAYS;
        const ny = STORIES;
        var members: std.ArrayList([4]f32) = .empty;
        var braces: std.ArrayList([4]f32) = .empty;
        var nodes: std.ArrayList(teak.CanvasPrimitive) = .empty;
        var over: std.ArrayList(teak.CanvasPrimitive) = .empty;
        for (0..ny + 1) |j| {
            const y = @as(f32, @floatFromInt(j)) * STORY_H;
            for (0..nx + 1) |i| {
                const x = @as(f32, @floatFromInt(i)) * BAY_W;
                if (i < nx and j > 0) try members.append(a, .{ x, y, x + BAY_W, y }); // beam
                if (j < ny) try members.append(a, .{ x, y, x, y + STORY_H }); // column
                if (i < nx and j < ny) {
                    try braces.append(a, .{ x, y, x + BAY_W, y + STORY_H });
                    try braces.append(a, .{ x + BAY_W, y, x, y + STORY_H });
                }
                try nodes.append(a, .{ .circle = .{ .x = x, .y = y, .radius = 2.5, .screen_radius = true, .fill = .{ 0.95, 0.85, 0.55, 1 } } });
            }
        }
        // Pinned supports along the base: a world-size triangle under each node.
        for (0..nx + 1) |i| {
            const x = @as(f32, @floatFromInt(i)) * BAY_W;
            const tri = try a.alloc(teak.CanvasPoint, 3);
            tri[0] = .{ .x = x, .y = 0 };
            tri[1] = .{ .x = x - 0.8, .y = -1.2 };
            tri[2] = .{ .x = x + 0.8, .y = -1.2 };
            try over.append(a, .{ .polygon = .{ .points = tri, .fill = .{ 0.35, 0.75, 0.55, 0.9 }, .stroke = .{ 0.6, 0.95, 0.75, 1 }, .thickness = 1 } });
        }
        // Moment diagrams on the roof beams: the parabola of a uniformly loaded
        // simple span, drawn under the beam as a filled polygon (the beam line
        // closes it) plus a stroke. A diagram that changes sign crosses the
        // beam line: split it at the zero crossings into one polygon per lobe.
        const top = @as(f32, @floatFromInt(ny)) * STORY_H;
        const stations = 12;
        for (0..nx) |i| {
            const x0 = @as(f32, @floatFromInt(i)) * BAY_W;
            const pts = try a.alloc(teak.CanvasPoint, stations + 1);
            for (0..stations + 1) |k| {
                const t = @as(f32, @floatFromInt(k)) / stations;
                const m = 1.2 * (4 * t * (1 - t));
                pts[k] = .{ .x = x0 + t * BAY_W, .y = top - m };
            }
            try over.append(a, .{ .polygon = .{ .points = pts, .fill = .{ 0.95, 0.35, 0.35, 0.35 }, .stroke = .{ 1, 0.45, 0.45, 1 }, .thickness = 1.5 } });
        }
        // Moment releases on the first-floor beams: a small arc at each end.
        for (0..nx) |i| {
            const x0 = @as(f32, @floatFromInt(i)) * BAY_W;
            try over.append(a, .{ .arc = .{ .x = x0 + 0.5, .y = STORY_H, .radius = 0.35, .start = 0, .sweep = 2 * std.math.pi, .color = .{ 0.6, 0.8, 1, 1 }, .thickness = 1.25 } });
            try over.append(a, .{ .arc = .{ .x = x0 + BAY_W - 0.5, .y = STORY_H, .radius = 0.35, .start = -std.math.pi / 2.0, .sweep = std.math.pi, .color = .{ 0.6, 0.8, 1, 1 }, .thickness = 1.25 } });
        }
        return .{
            .members = try members.toOwnedSlice(a),
            .braces = try braces.toOwnedSlice(a),
            .nodes = try nodes.toOwnedSlice(a),
            .overlays = try over.toOwnedSlice(a),
        };
    }

    pub fn memberCount(g: Geometry) usize {
        return g.members.len + g.braces.len;
    }

    pub fn extent() [4]f32 {
        return .{ -2, -2, @as(f32, @floatFromInt(BAYS)) * BAY_W + 2, @as(f32, @floatFromInt(STORIES)) * STORY_H + 2 };
    }
};

pub const Model = struct {
    geo: *const Geometry,
    view_w: f32 = 0,
    view_h: f32 = 0,
    /// World (m, y up) -> canvas px. Null until the canvas reports its size.
    xf: ?teak.CanvasTransform = null,
    antialias: bool = true,
    show_braces: bool = true,

    pub fn init() Model {
        const a = std.heap.page_allocator;
        const g = a.create(Geometry) catch @panic("oom");
        g.* = Geometry.build(a) catch @panic("oom");
        return .{ .geo = g };
    }
};

pub const Msg = union(enum) {
    view_size: [2]f32,
    pan: [2]f32,
    zoom_at: struct { dy: f32, x: f32, y: f32 },
    fit,
    toggle_aa,
    toggle_braces,
};

fn fitXf(m: *const Model) teak.CanvasTransform {
    const e = Geometry.extent();
    return teak.CanvasTransform.fit(e[0], e[1], e[2], e[3], m.view_w, m.view_h, 12, true);
}

pub fn update(m: *Model, msg: Msg) void {
    switch (msg) {
        .view_size => |s| {
            m.view_w = s[0];
            m.view_h = s[1];
            if (m.xf == null) m.xf = fitXf(m);
        },
        .pan => |d| if (m.xf) |xf| {
            m.xf = xf.pan(d[0], d[1]);
        },
        .zoom_at => |z| if (m.xf) |xf| {
            const want = std.math.clamp(xf.sx * @exp(-z.dy * 0.0015), MIN_SCALE, MAX_SCALE);
            m.xf = xf.zoomAt(z.x, z.y, want / xf.sx);
        },
        .fit => m.xf = fitXf(m),
        .toggle_aa => m.antialias = !m.antialias,
        .toggle_braces => m.show_braces = !m.show_braces,
    }
}

pub fn pointerMsg(_: *const Model, ev: teak.PointerEvent(Msg)) ?Msg {
    const c = ev.asCanvas() orelse return null;
    return switch (c.kind) {
        .layout => Msg{ .view_size = .{ c.w, c.h } },
        .move => if (c.buttons.left or c.buttons.middle) Msg{ .pan = .{ c.dx, c.dy } } else null,
        .wheel => Msg{ .zoom_at = .{ .dy = c.dy, .x = c.x, .y = c.y } },
        .down, .up, .leave, .key => null,
    };
}

pub fn view(m: *const Model, cb: anytype) void {
    const arena = cb.arena.allocator();
    const g = m.geo;
    cb.pushGroup(.{ .direction = .vertical, .padding = 10, .gap = 8, .flex = 1, .align_cross = .stretch });

    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 8 });
    cb.button(.fit, "Fit");
    cb.button(.toggle_aa, if (m.antialias) "Antialias: on" else "Antialias: off");
    cb.button(.toggle_braces, if (m.show_braces) "Braces: on" else "Braces: off");
    const scale = if (m.xf) |xf| xf.sx else 0;
    cb.text(std.fmt.allocPrint(arena, "{d} members, {d} nodes, {d:.1} px/m", .{ g.memberCount(), g.nodes.len, scale }) catch "");
    cb.popGroup();

    // Painter's order: braces, members, overlays, node dots on top. The
    // slices are the Model's; nothing here is per-primitive work.
    var prims: [4]teak.CanvasPrimitive = undefined;
    var n: usize = 0;
    if (m.show_braces) {
        prims[n] = .{ .lines = .{ .segs = g.braces, .color = .{ 0.35, 0.42, 0.55, 1 }, .thickness = 1, .key = 1 } };
        n += 1;
    }
    prims[n] = .{ .lines = .{ .segs = g.members, .color = .{ 0.75, 0.82, 0.95, 1 }, .thickness = 1.5, .key = 2 } };
    n += 1;
    const all = arena.alloc(teak.CanvasPrimitive, n + g.overlays.len + g.nodes.len) catch return;
    @memcpy(all[0..n], prims[0..n]);
    @memcpy(all[n..][0..g.overlays.len], g.overlays);
    @memcpy(all[n + g.overlays.len ..], g.nodes);

    cb.canvasInteractive(.{
        .width = 0,
        .height = 0,
        .flex = 1,
        .bg = .{ 0.07, 0.08, 0.1, 1 },
        .transform = m.xf orelse .{},
        .antialias = m.antialias,
    }, if (m.xf == null) &.{} else all, CANVAS_ID, "frame");
    cb.popGroup();
}

test "geometry is built once at the advertised scale" {
    const g = try Geometry.build(std.testing.allocator);
    defer {
        std.testing.allocator.free(g.members);
        std.testing.allocator.free(g.braces);
        std.testing.allocator.free(g.nodes);
        for (g.overlays) |o| if (o == .polygon) std.testing.allocator.free(o.polygon.points);
        std.testing.allocator.free(g.overlays);
    }
    try std.testing.expect(g.memberCount() > 80_000);
    try std.testing.expectEqual((BAYS + 1) * (STORIES + 1), g.nodes.len);
}

test "first layout fits the frame; zoom keeps the cursor's world point" {
    var g = Geometry{ .members = &.{}, .braces = &.{}, .nodes = &.{}, .overlays = &.{} };
    var m = Model{ .geo = &g };
    update(&m, .{ .view_size = .{ 1200, 800 } });
    const xf = m.xf.?;
    try std.testing.expect(xf.sy < 0); // y up
    const w = xf.invert(.{ .x = 300, .y = 200 });
    update(&m, .{ .zoom_at = .{ .dy = -300, .x = 300, .y = 200 } });
    const p = m.xf.?.apply(w);
    try std.testing.expectApproxEqAbs(@as(f32, 300), p.x, 1e-2);
    try std.testing.expectApproxEqAbs(@as(f32, 200), p.y, 1e-2);
    try std.testing.expect(m.xf.?.sx > xf.sx);
}
