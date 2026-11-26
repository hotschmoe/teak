//! Vector canvas: a structural-frame-sized drawing (about 80 000 members,
//! 20 000 nodes, supports, moment diagrams) on one pan / zoom canvas.
//!
//! The geometry is built ONCE, in world units (metres, y up), into Model-owned
//! slices, and declared as four `.canvas_geometry` resources (braces, members,
//! overlays, nodes). The run loop tessellates each once; pan and zoom change
//! only `CanvasStyle.transform`, which the shader applies. Toggling antialias
//! bumps the geometry `rev` (the flag is baked). Hiding braces omits that
//! draw and does not re-upload. Retained draws sit above the canvas
//! background, in resource order.
//!
//! Input (one `pointerMsg` hook): drag pans, the wheel zooms about the cursor,
//! the canvas reports its size (`layout`) so the first frame can fit the frame.
//! The toolbar icons are SVG, rasterized once by `teak.svg` (see `Icons`).

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
        for (0..nx + 1) |i| {
            const x = @as(f32, @floatFromInt(i)) * BAY_W;
            const tri = try a.alloc(teak.CanvasPoint, 3);
            tri[0] = .{ .x = x, .y = 0 };
            tri[1] = .{ .x = x - 0.8, .y = -1.2 };
            tri[2] = .{ .x = x + 0.8, .y = -1.2 };
            try over.append(a, .{ .polygon = .{ .points = tri, .fill = .{ 0.35, 0.75, 0.55, 0.9 }, .stroke = .{ 0.6, 0.95, 0.75, 1 }, .thickness = 1 } });
        }
        // Sign changes require separate filled lobes at zero crossings.
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

/// Toolbar icons: SVG source rasterized once (`teak.svg`) into Model-owned
/// pixels and handed to the GPU as image resources. Drawn white and tinted
/// in `view`, so they follow the theme.
pub const Icons = struct {
    pub const PX = 40; // rasterized size (drawn at 20 logical px: crisp at 2x)
    pub const sources = [_][]const u8{
        \\<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
        \\<path d="M3 8V3h5M16 3h5v5M21 16v5h-5M8 21H3v-5"/></svg>
        ,
        \\<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round">
        \\<circle cx="12" cy="12" r="8"/><path d="M6.5 17.5l11-11"/></svg>
        ,
        \\<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round">
        \\<rect x="3" y="3" width="18" height="18" rx="2"/><path d="M3 3l18 18M21 3L3 21"/></svg>
        ,
    };
    pixels: [sources.len][PX * PX * 4]u8 = undefined,
    list: [sources.len]teak.Resource = undefined,

    pub fn build(self: *Icons, a: std.mem.Allocator) void {
        for (sources, 0..) |src, i| {
            teak.svg.rasterizeInto(a, src, PX, PX, &self.pixels[i], .{ .color = .{ 1, 1, 1, 1 } }) catch @memset(&self.pixels[i], 0);
            self.list[i] = .{ .image = .{ .key = @intCast(i + 1), .rev = 1, .width = PX, .height = PX, .rgba = &self.pixels[i] } };
        }
    }
};

pub fn resources(m: *const Model) []const teak.Resource {
    return if (m.icons != null) m.listed else &.{};
}

pub const Model = struct {
    geo: *const Geometry,
    icons: ?*const Icons = null,
    view_w: f32 = 0,
    view_h: f32 = 0,
    /// World (m, y up) -> canvas px. Null until the canvas reports its size.
    xf: ?teak.CanvasTransform = null,
    antialias: bool = true,
    show_braces: bool = true,
    /// Braces and members as `lines` batches; on the heap so resources outlive the copy out of `init`.
    batches: *[2]teak.CanvasPrimitive = undefined,
    /// Three toolbar images, then four canvas geometries (keys are per kind).
    listed: *[7]teak.Resource = undefined,

    pub fn init() Model {
        const a = std.heap.page_allocator;
        const g = a.create(Geometry) catch @panic("oom");
        g.* = Geometry.build(a) catch @panic("oom");
        const ic = a.create(Icons) catch @panic("oom");
        ic.build(a);
        const batches = a.create([2]teak.CanvasPrimitive) catch @panic("oom");
        batches[0] = .{ .lines = .{ .segs = g.braces, .color = .{ 0.35, 0.42, 0.55, 1 }, .thickness = 1, .key = 1 } };
        batches[1] = .{ .lines = .{ .segs = g.members, .color = .{ 0.75, 0.82, 0.95, 1 }, .thickness = 1.5, .key = 2 } };
        const listed = a.create([7]teak.Resource) catch @panic("oom");
        var m = Model{ .geo = g, .icons = ic, .batches = batches, .listed = listed };
        m.syncResources();
        return m;
    }

    /// Antialiasing is baked into the buffers, so each setting is its own `rev`.
    fn syncResources(m: *Model) void {
        const ic = m.icons orelse return;
        const rev: u32 = if (m.antialias) 2 else 1;
        const aa = m.antialias;
        m.listed[0] = ic.list[0];
        m.listed[1] = ic.list[1];
        m.listed[2] = ic.list[2];
        m.listed[3] = .{ .canvas_geometry = .{ .key = 1, .rev = rev, .antialias = aa, .prims = m.batches[0..1] } };
        m.listed[4] = .{ .canvas_geometry = .{ .key = 2, .rev = rev, .antialias = aa, .prims = m.batches[1..2] } };
        m.listed[5] = .{ .canvas_geometry = .{ .key = 3, .rev = rev, .antialias = aa, .prims = m.geo.overlays } };
        m.listed[6] = .{ .canvas_geometry = .{ .key = 4, .rev = rev, .antialias = aa, .prims = m.geo.nodes } };
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
        .toggle_aa => {
            m.antialias = !m.antialias;
            m.syncResources();
        },
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

    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 8, .align_cross = .center });
    const tint = cb.theme.palette.fg;
    cb.image(1, .{ .width = 20, .height = 20, .tint = tint });
    cb.button(.fit, "Fit");
    cb.image(2, .{ .width = 20, .height = 20, .tint = tint });
    cb.button(.toggle_aa, if (m.antialias) "Antialias: on" else "Antialias: off");
    cb.image(3, .{ .width = 20, .height = 20, .tint = tint });
    cb.button(.toggle_braces, if (m.show_braces) "Braces: on" else "Braces: off");
    const scale = if (m.xf) |xf| xf.sx else 0;
    cb.text(std.fmt.allocPrint(arena, "{d} members, {d} nodes, {d:.1} px/m", .{ g.memberCount(), g.nodes.len, scale }) catch "");
    cb.popGroup();

    // Painter's order: braces, members, overlays, node dots.
    var prims: [4]teak.CanvasPrimitive = undefined;
    var n: usize = 0;
    if (m.show_braces) {
        prims[n] = .{ .geometry = .{ .key = 1 } };
        n += 1;
    }
    prims[n] = .{ .geometry = .{ .key = 2 } };
    n += 1;
    prims[n] = .{ .geometry = .{ .key = 3 } };
    n += 1;
    prims[n] = .{ .geometry = .{ .key = 4 } };
    n += 1;
    const shown = arena.alloc(teak.CanvasPrimitive, n) catch return;
    @memcpy(shown, prims[0..n]);

    cb.canvasInteractive(.{
        .width = 0,
        .height = 0,
        .flex = 1,
        .bg = .{ 0.07, 0.08, 0.1, 1 },
        .transform = m.xf orelse .{},
        .antialias = m.antialias,
    }, if (m.xf == null) &.{} else shown, CANVAS_ID, "frame");
    cb.popGroup();
}
