const std = @import("std");
const cmd_mod = @import("../core/cmd.zig");
const layout = @import("../layout/engine.zig");
const Rect = layout.Rect;

// ── Hit-Test ───────────────────────────────────────────────────────
//
// Generic over the Cmd slice type. The Msg is recovered from the slice's
// element type via its `MsgT` decl, so callers just pass `cb.cmds.items`.

pub fn HitResult(comptime Msg: type) type {
    return struct {
        index: usize,
        msg: Msg,
    };
}

fn CmdMsg(comptime Slice: type) type {
    return std.meta.Elem(Slice).MsgT;
}

fn rectContains(r: Rect, px: f32, py: f32) bool {
    return px >= r.x and px <= r.x + r.w and
        py >= r.y and py <= r.y + r.h;
}

/// Walk cmds/rects backwards (painter's order for z-ordering). Returns
/// the msg embedded in the first interactive widget whose rect contains
/// the point, or null if nothing was hit.
pub fn hitTest(
    cmds: anytype,
    rects: []const Rect,
    mouse_x: f32,
    mouse_y: f32,
) ?HitResult(CmdMsg(@TypeOf(cmds))) {
    var i: usize = cmds.len;
    while (i > 0) {
        i -= 1;
        const r = rects[i];
        switch (cmds[i]) {
            .button => |btn| if (rectContains(r, mouse_x, mouse_y)) {
                return .{ .index = i, .msg = btn.msg };
            },
            .text_input => |ti| if (rectContains(r, mouse_x, mouse_y)) {
                return .{ .index = i, .msg = ti.focus_msg };
            },
            else => {},
        }
    }
    return null;
}

/// Walk backwards, return the index of the first interactive widget whose
/// rect contains the point. No Msg produced. Used for hover and for
/// mapping focus state from Model field → command index.
pub fn hoverTest(
    cmds: anytype,
    rects: []const Rect,
    mouse_x: f32,
    mouse_y: f32,
) ?usize {
    var i: usize = cmds.len;
    while (i > 0) {
        i -= 1;
        switch (cmds[i]) {
            .button, .text_input => if (rectContains(rects[i], mouse_x, mouse_y)) return i,
            else => {},
        }
    }
    return null;
}

// ── Tests ──────────────────────────────────────────────────────────

test "hitTest finds button at point" {
    const testing = std.testing;
    const Msg = union(enum) { inc, dec };
    const CmdBuffer = cmd_mod.CmdBuffer(Msg);

    var cb = CmdBuffer.init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0 });
    cb.button(.inc, "+");
    cb.button(.dec, "-");
    cb.popGroup();

    var rects: [8]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 400, 300);

    const hit_inc = hitTest(cb.cmds.items, rects[0..cb.cmds.items.len], 30, 18);
    try testing.expect(hit_inc != null);
    try testing.expectEqual(Msg.inc, hit_inc.?.msg);

    const hit_dec = hitTest(cb.cmds.items, rects[0..cb.cmds.items.len], 90, 18);
    try testing.expect(hit_dec != null);
    try testing.expectEqual(Msg.dec, hit_dec.?.msg);

    const miss = hitTest(cb.cmds.items, rects[0..cb.cmds.items.len], 300, 250);
    try testing.expect(miss == null);
}

test "hitTest returns focus msg for text_input click" {
    const testing = std.testing;
    const Msg = union(enum) { focus };
    const CmdBuffer = cmd_mod.CmdBuffer(Msg);

    var cb = CmdBuffer.init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .direction = .vertical, .padding = 10, .gap = 0 });
    cb.textInput(.focus, "", 0);
    cb.popGroup();

    var rects: [8]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 400, 300);

    const hit = hitTest(cb.cmds.items, rects[0..cb.cmds.items.len], 100, 20);
    try testing.expect(hit != null);
    try testing.expectEqual(Msg.focus, hit.?.msg);
}
