const cmd = @import("cmd.zig");
const Cmd = cmd.Cmd;
const layout = @import("layout.zig");
const Rect = layout.Rect;
const model = @import("model.zig");
const Msg = model.Msg;

// ── Hit-Test ───────────────────────────────────────────────────────

pub const HitResult = struct {
    index: usize,
    msg: Msg,
};

fn rectContains(r: Rect, px: f32, py: f32) bool {
    return px >= r.x and px <= r.x + r.w and
        py >= r.y and py <= r.y + r.h;
}

/// Walk backwards through cmds/rects (painter's order for z-ordering).
/// Returns the first button index whose rect contains the point, or null.
fn findButtonAt(cmds: []const Cmd, rects: []const Rect, mx: f32, my: f32) ?usize {
    var i: usize = cmds.len;
    while (i > 0) {
        i -= 1;
        switch (cmds[i]) {
            .button => if (rectContains(rects[i], mx, my)) return i,
            else => {},
        }
    }
    return null;
}

/// Walk backwards through cmds/rects (painter's order for z-ordering).
/// Returns the Msg embedded in the first button whose rect contains the point.
pub fn hitTest(
    cmds: []const Cmd,
    rects: []const Rect,
    mouse_x: f32,
    mouse_y: f32,
) ?HitResult {
    const i = findButtonAt(cmds, rects, mouse_x, mouse_y) orelse return null;
    return .{ .index = i, .msg = cmds[i].button.msg };
}

/// Walk backwards, return the index of the first button whose rect contains the point.
/// Used for hover detection -- no Msg needed.
pub fn hoverTest(
    cmds: []const Cmd,
    rects: []const Rect,
    mouse_x: f32,
    mouse_y: f32,
) ?usize {
    return findButtonAt(cmds, rects, mouse_x, mouse_y);
}

// ── Tests ──────────────────────────────────────────────────────────

const std = @import("std");
const LayoutEngine = layout.LayoutEngine;
const CmdBuffer = cmd.CmdBuffer;

test "hit_test finds correct button" {
    const testing = std.testing;
    var cb = CmdBuffer.init(testing.allocator);
    defer cb.deinit();

    model.view(.{}, &cb);
    const cmds = cb.cmds.items;

    var rects: [32]Rect = undefined;
    LayoutEngine.doLayout(rects[0..cmds.len], cmds, 400, 300);

    // Click on "+" button (at 28,60 size 60x36)
    const plus_hit = hitTest(cmds, rects[0..cmds.len], 50, 75);
    try testing.expect(plus_hit != null);
    try testing.expectEqual(Msg.increment, plus_hit.?.msg);

    // Click on "-" button (at 96,60 size 60x36)
    const minus_hit = hitTest(cmds, rects[0..cmds.len], 120, 75);
    try testing.expect(minus_hit != null);
    try testing.expectEqual(Msg.decrement, minus_hit.?.msg);

    // Click on "Reset" button (at 20,116 size 66x36)
    const reset_hit = hitTest(cmds, rects[0..cmds.len], 40, 130);
    try testing.expect(reset_hit != null);
    try testing.expectEqual(Msg.reset, reset_hit.?.msg);

    // Click on empty space
    const miss = hitTest(cmds, rects[0..cmds.len], 300, 250);
    try testing.expect(miss == null);
}

test "hover_test finds correct button index" {
    const testing = std.testing;
    var cb = CmdBuffer.init(testing.allocator);
    defer cb.deinit();

    model.view(.{}, &cb);
    const cmds = cb.cmds.items;

    var rects: [32]Rect = undefined;
    LayoutEngine.doLayout(rects[0..cmds.len], cmds, 400, 300);

    // Hover over "+" button
    const hover = hoverTest(cmds, rects[0..cmds.len], 50, 75);
    try testing.expect(hover != null);
    try testing.expectEqual(@as(usize, 3), hover.?);

    // Hover over empty space
    const miss = hoverTest(cmds, rects[0..cmds.len], 300, 250);
    try testing.expect(miss == null);
}
