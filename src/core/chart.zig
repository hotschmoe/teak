//! teak.chart — pure line-chart primitive builder.
//!
//! Data-in, data-out: maps an `f32` data series plus value bounds into a
//! slice of `CanvasPrimitive`s (horizontal gridlines + one polyline) that
//! a `canvas` cmd renders. A consumer gets a line chart in ~3 lines of
//! view code:
//!
//!     const prims = teak.chart.lineChartPrimitives(cb.arena.allocator(),
//!         series, .{ .width = 300, .height = 120, .min = 0, .max = 100 });
//!     cb.canvas(.{ .width = 300, .height = 120 }, prims);
//!
//! Lives in core: no platform / gpu imports, no wall-clock, no globals.
//! Allocation is only through the caller-supplied (per-frame) arena, so
//! the output is bulk-freed with everything else (HARDLINE §1). The
//! function is pure: same inputs → same primitives.

const std = @import("std");
const cmd = @import("cmd.zig");

const CanvasPrimitive = cmd.CanvasPrimitive;
const CanvasPoint = cmd.CanvasPoint;

pub const LineChartOpts = struct {
    /// Canvas size the primitives are laid out for. Must match the
    /// `CanvasStyle` the app emits, or the chart won't fill its box.
    width: f32,
    height: f32,
    /// Value range mapped onto the plot's vertical axis: `min` sits at the
    /// bottom edge, `max` at the top. Values outside are clamped. When
    /// `min == max` the series draws flat at mid-height.
    min: f32,
    max: f32,
    /// Inset (px) between the canvas edge and the plot area on all sides.
    padding: f32 = 4,
    line_color: [4]f32 = .{ 0.3, 0.7, 1.0, 1.0 },
    line_thickness: f32 = 2,
    grid_color: [4]f32 = .{ 0.3, 0.3, 0.35, 1.0 },
    /// Number of evenly-spaced horizontal gridlines, counting both the
    /// top and bottom edges. 0 or 1 draws none.
    grid_lines: u32 = 5,
};

/// Build the primitives for a line chart of `series`. Returns an
/// arena-allocated slice owned by the caller's per-frame arena. Ordering
/// is gridlines first, then the polyline, so the line paints on top.
///
/// A series shorter than 2 points emits gridlines only (a single point has
/// no line to draw). An empty `series` with `grid_lines <= 1` returns an
/// empty slice.
pub fn lineChartPrimitives(
    arena: std.mem.Allocator,
    series: []const f32,
    opts: LineChartOpts,
) []const CanvasPrimitive {
    var list: std.ArrayList(CanvasPrimitive) = .empty;

    const plot_top = opts.padding;
    const plot_bottom = opts.height - opts.padding;
    const plot_left = opts.padding;
    const plot_right = opts.width - opts.padding;
    const plot_h = @max(0, plot_bottom - plot_top);
    const plot_w = @max(0, plot_right - plot_left);

    // Horizontal gridlines, top edge to bottom edge inclusive.
    if (opts.grid_lines > 1) {
        var g: u32 = 0;
        while (g < opts.grid_lines) : (g += 1) {
            const frac = @as(f32, @floatFromInt(g)) / @as(f32, @floatFromInt(opts.grid_lines - 1));
            const y = plot_top + frac * plot_h;
            list.append(arena, .{ .hline = .{ .y = y, .color = opts.grid_color, .thickness = 1 } }) catch unreachable;
        }
    }

    // Polyline through the mapped data points.
    if (series.len >= 2) {
        const pts = arena.alloc(CanvasPoint, series.len) catch unreachable;
        const span = opts.max - opts.min;
        for (series, 0..) |v, i| {
            const xf = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(series.len - 1));
            const x = plot_left + xf * plot_w;
            const vn = if (span != 0) (v - opts.min) / span else 0.5;
            const y = plot_bottom - std.math.clamp(vn, 0, 1) * plot_h;
            pts[i] = .{ .x = x, .y = y };
        }
        list.append(arena, .{ .polyline = .{
            .points = pts,
            .color = opts.line_color,
            .thickness = opts.line_thickness,
        } }) catch unreachable;
    }

    return list.toOwnedSlice(arena) catch unreachable;
}

// ── Tests ──────────────────────────────────────────────────────────

test "lineChartPrimitives: gridlines + polyline count" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const series = [_]f32{ 0, 5, 10, 5, 0 };
    const prims = lineChartPrimitives(arena.allocator(), &series, .{
        .width = 100,
        .height = 50,
        .min = 0,
        .max = 10,
        .grid_lines = 3,
    });

    // 3 gridlines + 1 polyline = 4 primitives.
    try testing.expectEqual(@as(usize, 4), prims.len);
    try testing.expectEqual(std.meta.Tag(CanvasPrimitive).hline, std.meta.activeTag(prims[0]));
    try testing.expectEqual(std.meta.Tag(CanvasPrimitive).polyline, std.meta.activeTag(prims[3]));
    try testing.expectEqual(@as(usize, 5), prims[3].polyline.points.len);
}

test "lineChartPrimitives: maps min to bottom, max to top" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    // Two points: value at min then at max. padding=0 so the plot fills
    // the whole canvas. y for min == height (bottom), y for max == 0 (top).
    const series = [_]f32{ 0, 100 };
    const prims = lineChartPrimitives(arena.allocator(), &series, .{
        .width = 200,
        .height = 80,
        .min = 0,
        .max = 100,
        .padding = 0,
        .grid_lines = 0,
    });

    // grid_lines=0 → only the polyline.
    try testing.expectEqual(@as(usize, 1), prims.len);
    const pts = prims[0].polyline.points;
    try testing.expectEqual(@as(f32, 0), pts[0].x); // first sample at left edge
    try testing.expectEqual(@as(f32, 80), pts[0].y); // min → bottom
    try testing.expectEqual(@as(f32, 200), pts[1].x); // last sample at right edge
    try testing.expectEqual(@as(f32, 0), pts[1].y); // max → top
}

test "lineChartPrimitives: single point emits gridlines only, no polyline" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const series = [_]f32{ 42 };
    const prims = lineChartPrimitives(arena.allocator(), &series, .{
        .width = 100,
        .height = 50,
        .min = 0,
        .max = 100,
        .grid_lines = 2,
    });

    // 2 gridlines, no polyline (need >= 2 points).
    try testing.expectEqual(@as(usize, 2), prims.len);
    for (prims) |p| try testing.expectEqual(std.meta.Tag(CanvasPrimitive).hline, std.meta.activeTag(p));
}

test "lineChartPrimitives: flat when min == max" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const series = [_]f32{ 5, 5, 5 };
    const prims = lineChartPrimitives(arena.allocator(), &series, .{
        .width = 90,
        .height = 60,
        .min = 5,
        .max = 5,
        .padding = 0,
        .grid_lines = 0,
    });

    const pts = prims[0].polyline.points;
    // min == max → every point at mid-height (0.5 * 60 = 30).
    for (pts) |pt| try testing.expectEqual(@as(f32, 30), pt.y);
}
