const std = @import("std");
const layout = @import("../layout/engine.zig");
const Rect = layout.Rect;
const TransientState = @import("../core/transient.zig").TransientState;
const vertex = @import("vertex.zig");
const Vertex = vertex.Vertex;
const emitQuad = vertex.emitQuad;

// Text-input visual constants. Monospace CHAR_WIDTH matches the layout
// pass so the cursor sits on glyph boundaries.
const CHAR_WIDTH: f32 = 10;
const BORDER_WIDTH: f32 = 2;
const CURSOR_WIDTH: f32 = 2;
const INPUT_TEXT_PADDING: f32 = 6;

fn insetRect(r: Rect, amount: f32) Rect {
    const w = @max(0, r.w - 2 * amount);
    const h = @max(0, r.h - 2 * amount);
    return .{ .x = r.x + amount, .y = r.y + amount, .w = w, .h = h };
}

/// Generic over the Cmd slice type. Walks (cmd, rect) pairs and emits a
/// quad (or several) per visible widget. Presentation state (hover,
/// press, focus, blink) pulls from TransientState without touching Model.
pub fn buildVertices(
    verts: *std.ArrayList(Vertex),
    alloc: std.mem.Allocator,
    cmds: anytype,
    rects: []const Rect,
    transient: TransientState,
) void {
    verts.clearRetainingCapacity();

    for (cmds, rects, 0..) |c, rect, i| {
        switch (c) {
            .text => {
                emitQuad(verts, alloc, rect, .{ 0.15, 0.15, 0.2, 1.0 });
            },
            .button => |btn| {
                const pressed = if (transient.press_index) |pi| pi == i else false;
                const hovered = if (transient.hover_index) |hi| hi == i else false;
                const bg = if (pressed)
                    btn.style.press_bg
                else if (hovered)
                    btn.style.hover_bg
                else
                    btn.style.bg;
                emitQuad(verts, alloc, rect, bg);
            },
            .text_input => |ti| {
                const focused = if (transient.focus_index) |fi| fi == i else false;
                const border_color = if (focused) ti.style.focus_border else ti.style.border;

                // Outer rect = border color; inner inset rect = bg.
                emitQuad(verts, alloc, rect, border_color);
                const inner = insetRect(rect, BORDER_WIDTH);
                emitQuad(verts, alloc, inner, ti.style.bg);

                // Text content placeholder: a muted rectangle sized to the
                // text length. Real glyphs come later; this at least shows
                // that typing changes the displayed length.
                if (ti.content.len > 0 and inner.w > 2 * INPUT_TEXT_PADDING) {
                    const text_w_raw = @as(f32, @floatFromInt(ti.content.len)) * CHAR_WIDTH;
                    const max_w = @max(0, inner.w - 2 * INPUT_TEXT_PADDING);
                    const text_w = @min(text_w_raw, max_w);
                    const text_h = @max(0, inner.h - 2 * INPUT_TEXT_PADDING);
                    const text_rect = Rect{
                        .x = inner.x + INPUT_TEXT_PADDING,
                        .y = inner.y + INPUT_TEXT_PADDING,
                        .w = text_w,
                        .h = text_h,
                    };
                    emitQuad(verts, alloc, text_rect, .{ 0.55, 0.55, 0.6, 1.0 });
                }

                // Blinking cursor when focused. ~0.5s on / 0.5s off at 60fps.
                if (focused and ((transient.frame_counter / 30) & 1) == 0) {
                    const cursor_x = inner.x + INPUT_TEXT_PADDING +
                        @as(f32, @floatFromInt(ti.cursor)) * CHAR_WIDTH;
                    const cursor_h = @max(0, inner.h - 2 * INPUT_TEXT_PADDING);
                    const cursor_rect = Rect{
                        .x = cursor_x,
                        .y = inner.y + INPUT_TEXT_PADDING,
                        .w = CURSOR_WIDTH,
                        .h = cursor_h,
                    };
                    emitQuad(verts, alloc, cursor_rect, ti.style.cursor);
                }
            },
            .push_group, .pop_group => {},
        }
    }
}

// ── Tests ──────────────────────────────────────────────────────────

const cmd_mod = @import("../core/cmd.zig");

test "buildVertices emits one quad per button and text" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    const CmdBuffer = cmd_mod.CmdBuffer(Msg);

    var cb = CmdBuffer.init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{});
    cb.text("hello");
    cb.button(.a, "+");
    cb.popGroup();

    var rects: [8]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 400, 300);

    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(testing.allocator);

    buildVertices(&verts, testing.allocator, cb.cmds.items, rects[0..cb.cmds.items.len], .{});
    // 1 text + 1 button = 2 quads * 6 verts
    try testing.expectEqual(@as(usize, 12), verts.items.len);
}

test "buildVertices draws border + bg + cursor for focused text input" {
    const testing = std.testing;
    const Msg = union(enum) { focus };
    const CmdBuffer = cmd_mod.CmdBuffer(Msg);

    var cb = CmdBuffer.init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{});
    cb.textInput(.focus, "ab", 1);
    cb.popGroup();

    var rects: [8]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 400, 300);

    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(testing.allocator);

    // Focused, blink-on frame (frame_counter 0 -> on).
    buildVertices(&verts, testing.allocator, cb.cmds.items, rects[0..cb.cmds.items.len], .{
        .focus_index = 1,
        .frame_counter = 0,
    });
    // border + bg + text + cursor = 4 quads = 24 verts
    try testing.expectEqual(@as(usize, 24), verts.items.len);
}
