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

fn rectIntersect(a: Rect, b: Rect) Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    if (x1 <= x0 or y1 <= y0) return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

const ClipStack = struct {
    buf: [16]Rect = undefined,
    len: usize = 0,

    fn push(self: *ClipStack, r: Rect) void {
        self.buf[self.len] = r;
        self.len += 1;
    }
    fn pop(self: *ClipStack) void {
        self.len -= 1;
    }
    fn top(self: *const ClipStack) Rect {
        if (self.len == 0) return .{ .x = -1e9, .y = -1e9, .w = 2e9, .h = 2e9 };
        return self.buf[self.len - 1];
    }
};

/// Walk cmds/rects forward, maintaining a scroll-clip stack; keep the
/// *last* hit (z-order = painter's order, so later draws are on top).
/// Inside a scroll container, the mouse must fall inside the viewport
/// rect as well as the widget rect.
pub fn hitTest(
    cmds: anytype,
    rects: []const Rect,
    mouse_x: f32,
    mouse_y: f32,
) ?HitResult(CmdMsg(@TypeOf(cmds))) {
    const Msg = CmdMsg(@TypeOf(cmds));
    var clip: ClipStack = .{};
    var best: ?HitResult(Msg) = null;
    for (cmds, 0..) |c, i| {
        const cur_clip = clip.top();
        switch (c) {
            .push_scroll => clip.push(rectIntersect(rects[i], cur_clip)),
            .pop_scroll => clip.pop(),
            .button => |btn| {
                if (rectContains(rects[i], mouse_x, mouse_y) and rectContains(cur_clip, mouse_x, mouse_y))
                    best = .{ .index = i, .msg = btn.msg };
            },
            .text_input => |ti| {
                if (rectContains(rects[i], mouse_x, mouse_y) and rectContains(cur_clip, mouse_x, mouse_y))
                    best = .{ .index = i, .msg = ti.focus_msg };
            },
            .checkbox => |cb| {
                if (rectContains(rects[i], mouse_x, mouse_y) and rectContains(cur_clip, mouse_x, mouse_y))
                    best = .{ .index = i, .msg = cb.msg };
            },
            .radio => |rd| {
                if (rectContains(rects[i], mouse_x, mouse_y) and rectContains(cur_clip, mouse_x, mouse_y))
                    best = .{ .index = i, .msg = rd.msg };
            },
            .slider => |sl| {
                if (rectContains(rects[i], mouse_x, mouse_y) and rectContains(cur_clip, mouse_x, mouse_y))
                    best = .{ .index = i, .msg = sl.grab_msg };
            },
            else => {},
        }
    }
    return best;
}

/// Like hitTest but returns only the index (no msg). Also respects
/// scroll clips.
pub fn hoverTest(
    cmds: anytype,
    rects: []const Rect,
    mouse_x: f32,
    mouse_y: f32,
) ?usize {
    var clip: ClipStack = .{};
    var best: ?usize = null;
    for (cmds, 0..) |c, i| {
        const cur_clip = clip.top();
        switch (c) {
            .push_scroll => clip.push(rectIntersect(rects[i], cur_clip)),
            .pop_scroll => clip.pop(),
            .button, .text_input, .checkbox, .radio, .slider => {
                if (rectContains(rects[i], mouse_x, mouse_y) and rectContains(cur_clip, mouse_x, mouse_y))
                    best = i;
            },
            else => {},
        }
    }
    return best;
}

/// Compute a slider's normalized value [0, 1] from an x position, given
/// the slider's rect. Intended for the host: after `hitTest` returns a
/// slider's `grab_msg` + index, the host reads `rects[index]` and calls
/// this to drive subsequent drag Msgs (one per frame while the button is
/// held).
pub fn sliderValueAt(rect: Rect, mouse_x: f32) f32 {
    if (rect.w <= 0) return 0;
    const t = (mouse_x - rect.x) / rect.w;
    return @min(@max(t, 0), 1);
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

test "hitTest clips descendants to scroll viewport" {
    const testing = std.testing;
    const Msg = union(enum) { pick };
    const CmdBuffer = cmd_mod.CmdBuffer(Msg);

    var cb = CmdBuffer.init(testing.allocator);
    defer cb.deinit();

    // Scroll viewport 100x100 at origin. Many buttons overflow.
    cb.pushScroll(.{
        .direction = .vertical,
        .padding = 0,
        .gap = 0,
        .width = 100,
        .height = 100,
        .scroll_y = 0,
    });
    cb.button(.pick, "A");
    cb.button(.pick, "B");
    cb.button(.pick, "C");
    cb.button(.pick, "D");
    cb.popScroll();

    var rects: [16]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 800, 600);

    // A button inside the viewport is hittable.
    try testing.expect(hitTest(cb.cmds.items, rects[0..cb.cmds.items.len], 10, 10) != null);
    // A later button that overflows past y=100 is clipped away.
    try testing.expect(hitTest(cb.cmds.items, rects[0..cb.cmds.items.len], 10, 150) == null);
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

test "sliderValueAt maps mouse_x to [0, 1]" {
    const testing = std.testing;
    const r: Rect = .{ .x = 100, .y = 0, .w = 200, .h = 20 };
    try testing.expectEqual(@as(f32, 0), sliderValueAt(r, 100));
    try testing.expectEqual(@as(f32, 0.5), sliderValueAt(r, 200));
    try testing.expectEqual(@as(f32, 1), sliderValueAt(r, 300));
    try testing.expectEqual(@as(f32, 0), sliderValueAt(r, 50)); // clamp low
    try testing.expectEqual(@as(f32, 1), sliderValueAt(r, 500)); // clamp high
}

test "hitTest returns msg for checkbox/radio/slider clicks" {
    const testing = std.testing;
    const Msg = union(enum) { toggle, pick, grab };
    const CmdBuffer = cmd_mod.CmdBuffer(Msg);

    var cb = CmdBuffer.init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.checkbox(.toggle, false, "x");
    cb.radio(.pick, true, "y");
    cb.slider(.grab, 0.5);
    cb.popGroup();

    var rects: [16]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 400, 300);

    const cb_hit = hitTest(cb.cmds.items, rects[0..cb.cmds.items.len], rects[1].x + 2, rects[1].y + 2);
    try testing.expectEqual(Msg.toggle, cb_hit.?.msg);

    const rd_hit = hitTest(cb.cmds.items, rects[0..cb.cmds.items.len], rects[2].x + 2, rects[2].y + 2);
    try testing.expectEqual(Msg.pick, rd_hit.?.msg);

    const sl_hit = hitTest(cb.cmds.items, rects[0..cb.cmds.items.len], rects[3].x + 10, rects[3].y + 10);
    try testing.expectEqual(Msg.grab, sl_hit.?.msg);
}
