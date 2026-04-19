const std = @import("std");
const layout = @import("../layout/engine.zig");
const Rect = layout.Rect;
const ClipStack = layout.ClipStack;
const clipRect = layout.clipRect;
const TransientState = @import("../core/transient.zig").TransientState;
const vertex = @import("vertex.zig");
const Vertex = vertex.Vertex;
const emitQuad = vertex.emitQuad;

// CHAR_WIDTH mirrors the layout pass so the cursor sits on glyph boundaries.
const CHAR_WIDTH: f32 = 10;
const BORDER_WIDTH: f32 = 2;
const CURSOR_WIDTH: f32 = 2;
const INPUT_TEXT_PADDING: f32 = 6;
const SLIDER_TRACK_PADDING: f32 = 2;

fn insetRect(r: Rect, amount: f32) Rect {
    const w = @max(0, r.w - 2 * amount);
    const h = @max(0, r.h - 2 * amount);
    return .{ .x = r.x + amount, .y = r.y + amount, .w = w, .h = h };
}

fn emit(verts: *std.ArrayList(Vertex), alloc: std.mem.Allocator, r: Rect, color: [4]f32, clip: Rect) void {
    const cr = clipRect(r, clip);
    if (cr.w <= 0 or cr.h <= 0) return;
    emitQuad(verts, alloc, cr, color);
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

    var clip: ClipStack = .{};

    for (cmds, rects, 0..) |c, rect, i| {
        const cur_clip = clip.top();
        switch (c) {
            .text => {
                emit(verts, alloc, rect, .{ 0.15, 0.15, 0.2, 1.0 }, cur_clip);
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
                emit(verts, alloc, rect, bg, cur_clip);
            },
            .text_input => |ti| {
                const focused = if (transient.focus_index) |fi| fi == i else false;
                const border_color = if (focused) ti.style.focus_border else ti.style.border;

                emit(verts, alloc, rect, border_color, cur_clip);
                const inner = insetRect(rect, BORDER_WIDTH);
                emit(verts, alloc, inner, ti.style.bg, cur_clip);

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
                    emit(verts, alloc, text_rect, .{ 0.55, 0.55, 0.6, 1.0 }, cur_clip);
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
                    emit(verts, alloc, cursor_rect, ti.style.cursor, cur_clip);
                }
            },
            .checkbox => |cb| {
                const box_rect = Rect{
                    .x = rect.x,
                    .y = rect.y + @max(0, (rect.h - cb.style.size) * 0.5),
                    .w = cb.style.size,
                    .h = cb.style.size,
                };
                emit(verts, alloc, box_rect, cb.style.box_border, cur_clip);
                const inner = insetRect(box_rect, BORDER_WIDTH);
                emit(verts, alloc, inner, cb.style.box_bg, cur_clip);
                if (cb.checked) {
                    const check = insetRect(inner, 2);
                    emit(verts, alloc, check, cb.style.check, cur_clip);
                }
                if (cb.label.len > 0) {
                    const label_x = box_rect.x + cb.style.size + cb.style.label_gap;
                    const label_w = @as(f32, @floatFromInt(cb.label.len)) * CHAR_WIDTH;
                    emit(verts, alloc, .{
                        .x = label_x,
                        .y = rect.y + @max(0, (rect.h - 16) * 0.5),
                        .w = label_w,
                        .h = 16,
                    }, .{ 0.55, 0.55, 0.6, 1.0 }, cur_clip);
                }
            },
            .radio => |rd| {
                // Quads-only renderer: a filled inner square stands in for
                // the classic radio dot until we get a circle primitive.
                const box_rect = Rect{
                    .x = rect.x,
                    .y = rect.y + @max(0, (rect.h - rd.style.size) * 0.5),
                    .w = rd.style.size,
                    .h = rd.style.size,
                };
                emit(verts, alloc, box_rect, rd.style.box_border, cur_clip);
                const inner = insetRect(box_rect, BORDER_WIDTH);
                emit(verts, alloc, inner, rd.style.box_bg, cur_clip);
                if (rd.selected) {
                    const dot = insetRect(box_rect, rd.style.size * 0.28);
                    emit(verts, alloc, dot, rd.style.dot, cur_clip);
                }
                if (rd.label.len > 0) {
                    const label_x = box_rect.x + rd.style.size + rd.style.label_gap;
                    const label_w = @as(f32, @floatFromInt(rd.label.len)) * CHAR_WIDTH;
                    emit(verts, alloc, .{
                        .x = label_x,
                        .y = rect.y + @max(0, (rect.h - 16) * 0.5),
                        .w = label_w,
                        .h = 16,
                    }, .{ 0.55, 0.55, 0.6, 1.0 }, cur_clip);
                }
            },
            .slider => |sl| {
                const v = @min(@max(sl.value, 0), 1);
                const track_h = sl.style.track_height;
                const track = Rect{
                    .x = rect.x,
                    .y = rect.y + @max(0, (rect.h - track_h) * 0.5),
                    .w = rect.w,
                    .h = track_h,
                };
                emit(verts, alloc, track, sl.style.track_bg, cur_clip);
                if (v > 0 and track.w > 2 * SLIDER_TRACK_PADDING) {
                    const fill = Rect{
                        .x = track.x + SLIDER_TRACK_PADDING,
                        .y = track.y + SLIDER_TRACK_PADDING,
                        .w = @max(0, (track.w - 2 * SLIDER_TRACK_PADDING) * v),
                        .h = @max(0, track.h - 2 * SLIDER_TRACK_PADDING),
                    };
                    emit(verts, alloc, fill, sl.style.track_fill, cur_clip);
                }
                const thumb_x = rect.x + v * @max(0, rect.w - sl.style.thumb_size);
                const thumb = Rect{
                    .x = thumb_x,
                    .y = rect.y + @max(0, (rect.h - sl.style.thumb_size) * 0.5),
                    .w = sl.style.thumb_size,
                    .h = sl.style.thumb_size,
                };
                emit(verts, alloc, thumb, sl.style.thumb, cur_clip);
            },
            .divider => |dv| {
                emit(verts, alloc, rect, dv.color, cur_clip);
            },
            .push_scroll => clip.push(clipRect(rect, cur_clip)),
            .pop_scroll => clip.pop(),
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

test "buildVertices clips child widgets to scroll container" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    const CmdBuffer = cmd_mod.CmdBuffer(Msg);

    var cb = CmdBuffer.init(testing.allocator);
    defer cb.deinit();

    // 100x100 viewport, two buttons — first fits, second overflows.
    cb.pushScroll(.{ .width = 100, .height = 100, .padding = 0, .gap = 0 });
    cb.button(.a, "A"); // y = 0..36, fits
    cb.button(.a, "B"); // y = 36..72, fits
    cb.button(.a, "C"); // y = 72..108, partially clipped
    cb.button(.a, "D"); // y = 108..144, fully clipped
    cb.popScroll();

    var rects: [16]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 400, 400);

    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(testing.allocator);
    buildVertices(&verts, testing.allocator, cb.cmds.items, rects[0..cb.cmds.items.len], .{});

    // Button D is fully outside the clip → no vertices.
    // Buttons A/B fit, C is partially clipped. Exact vertex count depends
    // on how many quads each button emits (1), so expect 3 * 6 = 18.
    try testing.expectEqual(@as(usize, 18), verts.items.len);
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
