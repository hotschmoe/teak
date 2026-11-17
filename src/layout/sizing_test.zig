//! Sizing-model tests for the layout engine: fixed sizes, align, justify,
//! stretch, flex, min sizes, scroll overflow, overlays. Golden snapshots
//! assert whole screens; direct rect checks pin single numbers.

const std = @import("std");
const cmd = @import("../core/cmd.zig");
const text = @import("../core/text.zig");
const snapshot = @import("../core/snapshot.zig");
const engine = @import("engine.zig");
const Rect = engine.Rect;
const LayoutEngine = engine.LayoutEngine;

const test_measurer = text.monoMeasurer();

const Msg = union(enum) { a, b, c };
const Buf = cmd.CmdBuffer(Msg);

/// view -> layout (mono measurer) -> rects, for tests that assert on rects.
fn layoutOf(cb: *Buf, rects: []Rect, w: f32, h: f32) []const Rect {
    LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, w, h, test_measurer);
    return rects[0..cb.cmds.items.len];
}

fn expectLayout(cb: *Buf, w: f32, h: f32, expected: []const u8) !void {
    var rects: [64]Rect = undefined;
    const rs = layoutOf(cb, &rects, w, h);
    try snapshot.expectSnapshot(cb.cmds.items, rs, .{}, expected);
}















