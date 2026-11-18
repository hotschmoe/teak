//! teak.chart — pure chart primitive builders: line (optionally filled),
//! bar and scatter.
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
const oom = @import("oom.zig").oom;
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
    /// Fill the area between the line and the bottom of the plot (an area
    /// chart); null = line only. Give it some transparency.
    fill: ?[4]f32 = null,
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
            list.append(arena, .{ .hline = .{ .y = y, .color = opts.grid_color, .thickness = 1 } }) catch oom();
        }
    }

    // Polyline through the mapped data points.
    if (series.len >= 2) {
        const pts = arena.alloc(CanvasPoint, series.len) catch oom();
        const span = opts.max - opts.min;
        for (series, 0..) |v, i| {
            const xf = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(series.len - 1));
            const x = plot_left + xf * plot_w;
            const vn = if (span != 0) (v - opts.min) / span else 0.5;
            const y = plot_bottom - std.math.clamp(vn, 0, 1) * plot_h;
            pts[i] = .{ .x = x, .y = y };
        }
        if (opts.fill) |fc| {
            const ring = arena.alloc(CanvasPoint, pts.len + 2) catch oom();
            @memcpy(ring[0..pts.len], pts);
            ring[pts.len] = .{ .x = plot_right, .y = plot_bottom };
            ring[pts.len + 1] = .{ .x = plot_left, .y = plot_bottom };
            list.append(arena, .{ .polygon = .{ .points = ring, .fill = fc } }) catch oom();
        }
        list.append(arena, .{ .polyline = .{
            .points = pts,
            .color = opts.line_color,
            .thickness = opts.line_thickness,
        } }) catch oom();
    }

    return list.toOwnedSlice(arena) catch oom();
}


pub const BarChartOpts = struct {
    /// Canvas size the primitives are laid out for (match the CanvasStyle).
    width: f32,
    height: f32,
    /// Value range on the vertical axis (min at the bottom). Bars grow
    /// from `baseline` (clamped into the range): negative values hang below.
    min: f32,
    max: f32,
    baseline: f32 = 0,
    padding: f32 = 4,
    /// Gap between neighbouring bars as a fraction of a slot (0..0.9).
    gap: f32 = 0.2,
    color: [4]f32 = .{ 0.3, 0.7, 1.0, 1.0 },
    /// Colour of bars below the baseline (null = `color`).
    negative_color: ?[4]f32 = null,
    grid_color: [4]f32 = .{ 0.3, 0.3, 0.35, 1.0 },
    grid_lines: u32 = 5,
    /// Draw the baseline as a 1 px rule.
    baseline_color: ?[4]f32 = .{ 0.55, 0.55, 0.6, 1.0 },
};

/// Gridlines, one filled rect per value, then the baseline rule.
/// Arena-allocated; pure.
pub fn barChartPrimitives(arena: std.mem.Allocator, values: []const f32, opts: BarChartOpts) []const CanvasPrimitive {
    var list: std.ArrayList(CanvasPrimitive) = .empty;
    const plot = Plot.of(opts.width, opts.height, opts.padding);
    plot.grid(arena, &list, opts.grid_lines, opts.grid_color);
    const base_y = plot.yOf(std.math.clamp(opts.baseline, @min(opts.min, opts.max), @max(opts.min, opts.max)), opts.min, opts.max);
    if (values.len > 0) {
        const slot = plot.w / @as(f32, @floatFromInt(values.len));
        const bar_w = @max(1, slot * (1 - std.math.clamp(opts.gap, 0, 0.9)));
        list.ensureUnusedCapacity(arena, values.len) catch oom();
        for (values, 0..) |v, i| {
            if (!std.math.isFinite(v)) continue;
            const y = plot.yOf(v, opts.min, opts.max);
            const x = plot.left + slot * @as(f32, @floatFromInt(i)) + (slot - bar_w) / 2;
            const below = v < opts.baseline;
            list.appendAssumeCapacity(.{ .filled_rect = .{
                .x = x,
                .y = @min(y, base_y),
                .w = bar_w,
                .h = @abs(base_y - y),
                .color = if (below) (opts.negative_color orelse opts.color) else opts.color,
            } });
        }
    }
    if (opts.baseline_color) |c| list.append(arena, .{ .hline = .{ .y = base_y, .color = c, .thickness = 1 } }) catch oom();
    return list.toOwnedSlice(arena) catch oom();
}

pub const ScatterOpts = struct {
    width: f32,
    height: f32,
    /// Data ranges mapped onto the plot area (x_min at the left, y_min at the bottom).
    x_min: f32,
    x_max: f32,
    y_min: f32,
    y_max: f32,
    padding: f32 = 4,
    /// Dot radius in px.
    radius: f32 = 3,
    color: [4]f32 = .{ 0.3, 0.7, 1.0, 1.0 },
    grid_color: [4]f32 = .{ 0.3, 0.3, 0.35, 1.0 },
    grid_lines: u32 = 5,
};

/// Gridlines plus one antialiased circle per (xs[i], ys[i]) inside the
/// ranges (points outside are skipped, not clamped). Arena-allocated; pure.
pub fn scatterPrimitives(arena: std.mem.Allocator, xs: []const f32, ys: []const f32, opts: ScatterOpts) []const CanvasPrimitive {
    var list: std.ArrayList(CanvasPrimitive) = .empty;
    const plot = Plot.of(opts.width, opts.height, opts.padding);
    plot.grid(arena, &list, opts.grid_lines, opts.grid_color);
    const n = @min(xs.len, ys.len);
    list.ensureUnusedCapacity(arena, n) catch oom();
    const xspan = opts.x_max - opts.x_min;
    for (xs[0..n], ys[0..n]) |x, y| {
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) continue;
        if (x < @min(opts.x_min, opts.x_max) or x > @max(opts.x_min, opts.x_max)) continue;
        if (y < @min(opts.y_min, opts.y_max) or y > @max(opts.y_min, opts.y_max)) continue;
        const fx = if (xspan != 0) (x - opts.x_min) / xspan else 0.5;
        list.appendAssumeCapacity(.{ .circle = .{
            .x = plot.left + fx * plot.w,
            .y = plot.yOf(y, opts.y_min, opts.y_max),
            .radius = opts.radius,
            .fill = opts.color,
            .screen_radius = true,
        } });
    }
    return list.toOwnedSlice(arena) catch oom();
}

const Plot = struct {
    left: f32,
    top: f32,
    w: f32,
    h: f32,

    fn of(width: f32, height: f32, padding: f32) Plot {
        return .{ .left = padding, .top = padding, .w = @max(0, width - 2 * padding), .h = @max(0, height - 2 * padding) };
    }

    /// Value -> y (min at the bottom), clamped to the plot.
    fn yOf(p: Plot, v: f32, min: f32, max: f32) f32 {
        const span = max - min;
        const vn = if (span != 0) (v - min) / span else 0.5;
        return p.top + p.h - std.math.clamp(vn, 0, 1) * p.h;
    }

    fn grid(p: Plot, arena: std.mem.Allocator, list: *std.ArrayList(CanvasPrimitive), lines: u32, color: [4]f32) void {
        if (lines <= 1) return;
        var g: u32 = 0;
        while (g < lines) : (g += 1) {
            const frac = @as(f32, @floatFromInt(g)) / @as(f32, @floatFromInt(lines - 1));
            list.append(arena, .{ .hline = .{ .y = p.top + frac * p.h, .color = color, .thickness = 1 } }) catch oom();
        }
    }
};







