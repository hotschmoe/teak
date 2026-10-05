//! Content extent of a scroll region, measured from the rects the layout
//! passes already produced.
//!
//! The view cannot read layout results, so an app that wants to clamp a
//! scroll offset or draw a scrollbar needs the region's viewport size and its
//! content size reported back through a Msg (`scrollLayoutMsg`). The viewport
//! is the container's own rect; the content size is derived here from its
//! descendants' rects. Reads layout output only — it does not touch the
//! measure/position passes.

const std = @import("std");
const layout = @import("engine.zig");
const Rect = layout.Rect;

pub const Extent = struct {
    /// The region's own rect size (the viewport).
    viewport_w: f32,
    viewport_h: f32,
    /// The size of everything inside it, padding included, independent of the
    /// current scroll offset.
    content_w: f32,
    content_h: f32,
};

/// Viewport + content size of the `push_scroll` at `index`.
///
/// Content is measured from the scroll's content origin (`rect - scroll
/// offset`) to the far edge of its farthest descendant, plus the container's
/// trailing padding. Nested scroll regions contribute their own rect but not
/// their interiors (those are clipped to the nested viewport), and overlays
/// are absolute-positioned and do not contribute at all — the same rules the
/// layout pass uses to size a container from its children.
pub fn scrollExtent(cmds: anytype, rects: []const Rect, index: usize) Extent {
    const style = cmds[index].push_scroll;
    const origin = rects[index];

    var right: f32 = origin.x - style.scroll_x + style.padding;
    var bottom: f32 = origin.y - style.scroll_y + style.padding;

    var depth: usize = 1; // open containers below `index`, counting the scroll itself
    var skip_at: ?usize = null; // depth at which a skipped subtree began
    var i = index + 1;
    while (i < cmds.len and depth > 0) : (i += 1) {
        const c = cmds[i];
        switch (c) {
            .push_group, .push_virtual_list, .push_scroll, .push_overlay => {
                if (skip_at == null) {
                    switch (c) {
                        .push_overlay => skip_at = depth,
                        else => {
                            right = @max(right, rects[i].x + rects[i].w);
                            bottom = @max(bottom, rects[i].y + rects[i].h);
                            if (c == .push_scroll) skip_at = depth;
                        },
                    }
                }
                depth += 1;
            },
            .pop_group, .pop_virtual_list, .pop_scroll, .pop_overlay => {
                depth -= 1;
                if (skip_at) |d| {
                    if (depth == d) skip_at = null;
                }
            },
            else => if (skip_at == null) {
                right = @max(right, rects[i].x + rects[i].w);
                bottom = @max(bottom, rects[i].y + rects[i].h);
            },
        }
    }

    return .{
        .viewport_w = origin.w,
        .viewport_h = origin.h,
        .content_w = right - (origin.x - style.scroll_x) + style.padding,
        .content_h = bottom - (origin.y - style.scroll_y) + style.padding,
    };
}

// ── Tests ──────────────────────────────────────────────────────────

const cmd_mod = @import("../core/cmd.zig");
const text_mod = @import("../core/text.zig");

const Msg = union(enum) { a };

fn layoutOf(rects: []Rect, cb: *cmd_mod.CmdBuffer(Msg)) []const Rect {
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 400, 400, text_mod.monoMeasurer());
    return rects[0..cb.cmds.items.len];
}

test "scrollExtent: viewport vs content, independent of the scroll offset" {
    var rects: [16]Rect = undefined;
    inline for (.{ 0.0, 50.0 }) |scroll_y| {
        var cb = cmd_mod.CmdBuffer(Msg).init(std.testing.allocator);
        defer cb.deinit();
        cb.pushScroll(.{ .width = 100, .height = 60, .padding = 4, .gap = 2, .scroll_y = scroll_y, .id = 1 });
        cb.button(.a, "A");
        cb.button(.a, "B");
        cb.button(.a, "C");
        cb.popScroll();
        const rs = layoutOf(&rects, &cb);

        const e = scrollExtent(cb.cmds.items, rs, 0);
        try std.testing.expectEqual(@as(f32, 100), e.viewport_w);
        try std.testing.expectEqual(@as(f32, 60), e.viewport_h);
        // 3 buttons x 36 + 2 gaps x 2 + padding 4 on each side.
        try std.testing.expectEqual(@as(f32, 3 * 36 + 2 * 2 + 8), e.content_h);
    }
}

test "scrollExtent: nested scroll interiors and overlays do not count" {
    var rects: [24]Rect = undefined;
    var cb = cmd_mod.CmdBuffer(Msg).init(std.testing.allocator);
    defer cb.deinit();
    cb.pushScroll(.{ .width = 100, .height = 100, .padding = 0, .id = 1 }); // 0
    cb.button(.a, "A"); // 1: 36 tall
    cb.pushScroll(.{ .width = 100, .height = 20, .padding = 0 }); // 2: nested, 20 tall
    cb.button(.a, "B");
    cb.button(.a, "C");
    cb.button(.a, "D"); // tall interior, clipped by the nested viewport
    cb.popScroll();
    cb.pushOverlay(.{ .x = 0, .y = 300, .width = 50, .height = 50 });
    cb.button(.a, "O");
    cb.popOverlay();
    cb.popScroll();
    const rs = layoutOf(&rects, &cb);

    const e = scrollExtent(cb.cmds.items, rs, 0);
    try std.testing.expectEqual(@as(f32, 36 + 20), e.content_h);
}

test "scrollExtent: an empty region has only its padding" {
    var rects: [4]Rect = undefined;
    var cb = cmd_mod.CmdBuffer(Msg).init(std.testing.allocator);
    defer cb.deinit();
    cb.pushScroll(.{ .width = 80, .height = 80, .padding = 5, .id = 1 });
    cb.popScroll();
    const rs = layoutOf(&rects, &cb);
    const e = scrollExtent(cb.cmds.items, rs, 0);
    try std.testing.expectEqual(@as(f32, 10), e.content_w);
    try std.testing.expectEqual(@as(f32, 10), e.content_h);
}
