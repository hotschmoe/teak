//! Grid layout tests (`push_grid` / `pop_grid`): column tracks (fixed /
//! auto / fr), row-major wrapping, row height, gaps and padding, cell
//! alignment, nesting, wrapped text in a column, and the other passes
//! (snapshot, hit-test, render, a11y, balance) seeing a grid.

const std = @import("std");
const testing = std.testing;
const cmd = @import("../core/cmd.zig");
const text = @import("../core/text.zig");
const snapshot = @import("../core/snapshot.zig");
const hit_test = @import("../input/hit_test.zig");
const a11y = @import("../input/a11y.zig");
const engine = @import("engine.zig");
const Rect = engine.Rect;
const LayoutEngine = engine.LayoutEngine;

// 10 px per byte, 20 px line height.
const test_measurer = text.monoMeasurer();

const Msg = union(enum) { a, b, c, d };
const Buf = cmd.CmdBuffer(Msg);

fn layoutOf(cb: *Buf, rects: []Rect, w: f32, h: f32) []const Rect {
    LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, w, h, test_measurer);
    return rects[0..cb.cmds.items.len];
}

fn expectRect(r: Rect, x: f32, y: f32, w: f32, h: f32) !void {
    try testing.expectApproxEqAbs(x, r.x, 0.01);
    try testing.expectApproxEqAbs(y, r.y, 0.01);
    try testing.expectApproxEqAbs(w, r.w, 0.01);
    try testing.expectApproxEqAbs(h, r.h, 0.01);
}













