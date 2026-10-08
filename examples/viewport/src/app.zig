//! Viewport example: a pan / zoom canvas and a scrollable list with a
//! scrollbar — the two interaction patterns `teak.run` routes for you.
//!
//! * `canvasMsg` turns pointer input over the interactive canvas into Msgs:
//!   drag (left or middle button) pans, the wheel zooms about the cursor, and
//!   the canvas reports its own size (`layout`) so the Model knows the viewport.
//! * `scrollMsg` / `scrollLayoutMsg` scroll the list with the wheel and report
//!   its viewport + content size, enough to clamp the offset and size a
//!   scrollbar thumb. The view never reads layout; the Model holds the numbers.

const std = @import("std");
const teak = @import("teak");

const CANVAS_ID: u32 = 1;
const LIST_ID: u32 = 2;
const LIST_ROWS: usize = 40;
const LIST_HEIGHT: f32 = 300;
const GRID: f32 = 50; // world units between grid lines
const MIN_ZOOM: f32 = 0.2;
const MAX_ZOOM: f32 = 8;

pub const Model = struct {
    /// Canvas size, reported by the `layout` event.
    view_w: f32 = 0,
    view_h: f32 = 0,
    /// View transform: screen = world * zoom + pan.
    pan_x: f32 = 0,
    pan_y: f32 = 0,
    zoom: f32 = 1,
    /// Last hover position in canvas-local px (null while the cursor is away).
    hover: ?[2]f32 = null,
    /// Scroll list state.
    list_scroll: f32 = 0,
    list_viewport: f32 = LIST_HEIGHT,
    list_content: f32 = 0,
};

pub const Msg = union(enum) {
    view_size: [2]f32,
    pan: [2]f32,
    zoom_at: struct { dy: f32, x: f32, y: f32 },
    hover: ?[2]f32,
    list_scroll_by: f32,
    list_extent: [2]f32,
    reset,
};

pub fn update(m: *Model, msg: Msg) void {
    switch (msg) {
        .view_size => |s| {
            m.view_w = s[0];
            m.view_h = s[1];
        },
        .pan => |d| {
            m.pan_x += d[0];
            m.pan_y += d[1];
        },
        .zoom_at => |z| {
            const old = m.zoom;
            m.zoom = std.math.clamp(old * @exp(-z.dy * 0.0015), MIN_ZOOM, MAX_ZOOM);
            // Keep the world point under the cursor fixed.
            const k = m.zoom / old;
            m.pan_x = z.x - (z.x - m.pan_x) * k;
            m.pan_y = z.y - (z.y - m.pan_y) * k;
        },
        .hover => |h| m.hover = h,
        .list_scroll_by => |dy| m.list_scroll = clampScroll(m, m.list_scroll + dy),
        .list_extent => |e| {
            m.list_viewport = e[0];
            m.list_content = e[1];
            m.list_scroll = clampScroll(m, m.list_scroll);
        },
        .reset => {
            m.pan_x = 0;
            m.pan_y = 0;
            m.zoom = 1;
        },
    }
}

fn clampScroll(m: *const Model, y: f32) f32 {
    return std.math.clamp(y, 0, @max(0, m.list_content - m.list_viewport));
}

pub fn canvasMsg(_: *const Model, ev: teak.CanvasEvent) ?Msg {
    return switch (ev.kind) {
        .layout => Msg{ .view_size = .{ ev.w, ev.h } },
        .move => if (ev.buttons.left or ev.buttons.middle)
            Msg{ .pan = .{ ev.dx, ev.dy } }
        else
            Msg{ .hover = .{ ev.x, ev.y } },
        .wheel => Msg{ .zoom_at = .{ .dy = ev.dy, .x = ev.x, .y = ev.y } },
        .leave => Msg{ .hover = null },
        .down, .up, .key => null,
    };
}

pub fn scrollMsg(_: *const Model, id: u32, _: f32, dy: f32) ?Msg {
    return if (id == LIST_ID) Msg{ .list_scroll_by = dy } else null;
}

pub fn scrollLayoutMsg(_: *const Model, id: u32, _: f32, vh: f32, _: f32, ch: f32) ?Msg {
    return if (id == LIST_ID) Msg{ .list_extent = .{ vh, ch } } else null;
}

pub fn view(m: *const Model, cb: anytype) void {
    const arena = cb.arena.allocator();
    cb.pushGroup(.{ .direction = .horizontal, .padding = 12, .gap = 12 });

    cb.canvasInteractive(
        .{ .width = 560, .height = 460, .bg = .{ 0.10, 0.11, 0.14, 1 } },
        gridPrimitives(arena, m),
        CANVAS_ID,
        "pan / zoom viewport",
    );

    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 8 });
    cb.text("Drag to pan, wheel to zoom");
    cb.text(std.fmt.allocPrint(arena, "zoom {d:.2}  pan {d:.0}, {d:.0}", .{ m.zoom, m.pan_x, m.pan_y }) catch "");
    cb.text(if (m.hover) |h|
        std.fmt.allocPrint(arena, "cursor {d:.0}, {d:.0}  world {d:.1}, {d:.1}", .{ h[0], h[1], (h[0] - m.pan_x) / m.zoom, (h[1] - m.pan_y) / m.zoom }) catch ""
    else
        "cursor -");
    cb.text(std.fmt.allocPrint(arena, "canvas {d:.0} x {d:.0}", .{ m.view_w, m.view_h }) catch "");
    cb.button(.reset, "Reset view");

    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 4 });
    cb.pushScroll(.{ .direction = .vertical, .padding = 0, .gap = 2, .width = 160, .height = LIST_HEIGHT, .scroll_y = m.list_scroll, .id = LIST_ID });
    for (0..LIST_ROWS) |i| cb.text(std.fmt.allocPrint(arena, "Row {d}", .{i + 1}) catch "");
    cb.popScroll();
    cb.canvas(.{ .width = 8, .height = LIST_HEIGHT, .bg = .{ 0.16, 0.17, 0.2, 1 } }, scrollbarThumb(arena, m));
    cb.popGroup();

    cb.popGroup();
    cb.popGroup();
}

/// World-space grid + origin marker, mapped through the view transform and
/// clipped to the canvas. Everything is canvas-local px, built into the
/// frame arena.
fn gridPrimitives(arena: std.mem.Allocator, m: *const Model) []const teak.CanvasPrimitive {
    var prims: std.ArrayList(teak.CanvasPrimitive) = .empty;
    const step = GRID * m.zoom;
    if (step < 6 or m.view_w <= 0) return prims.items;

    const first_x = @mod(m.pan_x, step);
    var x = first_x;
    while (x < m.view_w) : (x += step) {
        const major = @mod(@round((x - m.pan_x) / step), 5) == 0;
        prims.append(arena, .{ .vline = .{ .x = x, .color = if (major) .{ 0.32, 0.34, 0.42, 1 } else .{ 0.2, 0.21, 0.27, 1 } } }) catch return prims.items;
    }
    const first_y = @mod(m.pan_y, step);
    var y = first_y;
    while (y < m.view_h) : (y += step) {
        const major = @mod(@round((y - m.pan_y) / step), 5) == 0;
        prims.append(arena, .{ .hline = .{ .y = y, .color = if (major) .{ 0.32, 0.34, 0.42, 1 } else .{ 0.2, 0.21, 0.27, 1 } } }) catch return prims.items;
    }
    // Coordinate labels at grid intersections, spaced >= ~130 px apart on screen. They are
    // world-space text: the font size follows the zoom, and `scalable` draws every size from
    // one distance-field glyph set, so zooming 0.2x - 8x never re-rasterizes or blurs.
    const every: f32 = @max(1, @ceil(130 / step));
    const label_font: teak.FontSpec = .{ .size_px = 11 * m.zoom, .family = .mono, .scalable = true };
    var ly = first_y;
    while (ly < m.view_h) : (ly += step) {
        const iy = @round((ly - m.pan_y) / step);
        if (@mod(iy, every) != 0) continue;
        var lx = first_x;
        while (lx < m.view_w) : (lx += step) {
            const ix = @round((lx - m.pan_x) / step);
            if (@mod(ix, every) != 0) continue;
            const label = std.fmt.allocPrint(arena, "{d:.0},{d:.0}", .{ ix * GRID, iy * GRID }) catch continue;
            prims.append(arena, .{ .text = .{ .x = lx + 3 * m.zoom, .y = ly + 2 * m.zoom, .content = label, .font = label_font, .color = .{ 0.62, 0.68, 0.85, 1 } } }) catch break;
        }
    }
    // World origin.
    prims.append(arena, .{ .marker = .{ .x = m.pan_x, .y = m.pan_y, .size = 10, .color = .{ 0.95, 0.6, 0.2, 1 } } }) catch {};
    return prims.items;
}

fn scrollbarThumb(arena: std.mem.Allocator, m: *const Model) []const teak.CanvasPrimitive {
    if (m.list_content <= m.list_viewport or m.list_content <= 0) return &.{};
    const track = LIST_HEIGHT;
    const thumb_h = @max(16, track * m.list_viewport / m.list_content);
    const range = m.list_content - m.list_viewport;
    const thumb_y = (track - thumb_h) * (m.list_scroll / range);
    const prims = arena.alloc(teak.CanvasPrimitive, 1) catch return &.{};
    prims[0] = .{ .filled_rect = .{ .x = 0, .y = thumb_y, .w = 8, .h = thumb_h, .color = .{ 0.55, 0.6, 0.75, 1 } } };
    return prims;
}

test "zoom keeps the world point under the cursor fixed" {
    var m = Model{ .pan_x = 40, .pan_y = 10 };
    const wx = (200 - m.pan_x) / m.zoom;
    const wy = (120 - m.pan_y) / m.zoom;
    update(&m, .{ .zoom_at = .{ .dy = -240, .x = 200, .y = 120 } });
    try std.testing.expect(m.zoom > 1);
    try std.testing.expectApproxEqAbs(wx, (200 - m.pan_x) / m.zoom, 0.001);
    try std.testing.expectApproxEqAbs(wy, (120 - m.pan_y) / m.zoom, 0.001);
}

test "canvasMsg: drag pans, hover tracks, wheel zooms, layout sizes" {
    const m = Model{};
    const drag = canvasMsg(&m, .{ .id = CANVAS_ID, .kind = .move, .dx = 3, .dy = -2, .buttons = .{ .left = true } }).?;
    try std.testing.expectEqual(@as(f32, 3), drag.pan[0]);
    const hover = canvasMsg(&m, .{ .id = CANVAS_ID, .kind = .move, .x = 9, .y = 8 }).?;
    try std.testing.expectEqual(@as(f32, 9), hover.hover.?[0]);
    try std.testing.expect(canvasMsg(&m, .{ .id = CANVAS_ID, .kind = .down }) == null);
    const lay = canvasMsg(&m, .{ .id = CANVAS_ID, .kind = .layout, .w = 560, .h = 460 }).?;
    try std.testing.expectEqual(@as(f32, 460), lay.view_size[1]);
}

test "scroll offset clamps to the reported content extent" {
    var m = Model{};
    update(&m, .{ .list_extent = .{ 300, 1000 } });
    update(&m, .{ .list_scroll_by = 5000 });
    try std.testing.expectEqual(@as(f32, 700), m.list_scroll);
    update(&m, .{ .list_scroll_by = -9999 });
    try std.testing.expectEqual(@as(f32, 0), m.list_scroll);
    // Content shrinks below the offset: re-clamped on the next report.
    update(&m, .{ .list_scroll_by = 400 });
    update(&m, .{ .list_extent = .{ 300, 500 } });
    try std.testing.expectEqual(@as(f32, 200), m.list_scroll);
}
