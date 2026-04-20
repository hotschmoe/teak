const std = @import("std");
const layout = @import("../layout/engine.zig");
const Rect = layout.Rect;
const ClipStack = layout.ClipStack;
const clipRect = layout.clipRect;
const TransientState = @import("../core/transient.zig").TransientState;
const text_mod = @import("../core/text.zig");
const TextDraw = text_mod.TextDraw;
const TextMeasurer = text_mod.TextMeasurer;
const FontSpec = text_mod.FontSpec;
const vertex = @import("vertex.zig");
const Vertex = vertex.Vertex;
const emitQuad = vertex.emitQuad;

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

fn emitText(
    text_draws: *std.ArrayList(TextDraw),
    alloc: std.mem.Allocator,
    content: []const u8,
    font: FontSpec,
    color: [4]f32,
    rect: Rect,
    clip: Rect,
) void {
    if (content.len == 0) return;
    if (rect.w <= 0 or rect.h <= 0) return;
    text_draws.append(alloc, .{
        .rect_x = rect.x,
        .rect_y = rect.y,
        .rect_w = rect.w,
        .rect_h = rect.h,
        .content = content,
        .font = font,
        .color = color,
        .clip_x = clip.x,
        .clip_y = clip.y,
        .clip_w = clip.w,
        .clip_h = clip.h,
    }) catch {};
}

/// Generic over the Cmd slice type. Walks (cmd, rect) pairs and emits
/// solid-fill quads into `verts` + textured draw records into
/// `text_draws`. Presentation state (hover, press, focus, blink) pulls
/// from TransientState without touching Model.
pub fn buildVertices(
    verts: *std.ArrayList(Vertex),
    text_draws: *std.ArrayList(TextDraw),
    alloc: std.mem.Allocator,
    cmds: anytype,
    rects: []const Rect,
    transient: TransientState,
    measurer: TextMeasurer,
) void {
    verts.clearRetainingCapacity();
    text_draws.clearRetainingCapacity();

    var clip: ClipStack = .{};

    for (cmds, rects, 0..) |c, rect, i| {
        const cur_clip = clip.top();
        switch (c) {
            .text => |txt| {
                emitText(text_draws, alloc, txt.content, txt.font, txt.color, rect, cur_clip);
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

                if (btn.label.len > 0) {
                    const m = measurer.measure(btn.label, btn.font);
                    const label_rect = Rect{
                        .x = rect.x + 8,
                        .y = rect.y + @max(0, (rect.h - m.height) * 0.5),
                        .w = @min(m.width, @max(0, rect.w - 16)),
                        .h = m.height,
                    };
                    emitText(text_draws, alloc, btn.label, btn.font, btn.style.fg, label_rect, cur_clip);
                }
            },
            .text_input => |ti| {
                const focused = if (transient.focus_index) |fi| fi == i else false;
                const border_color = if (focused) ti.style.focus_border else ti.style.border;

                emit(verts, alloc, rect, border_color, cur_clip);
                const inner = insetRect(rect, BORDER_WIDTH);
                emit(verts, alloc, inner, ti.style.bg, cur_clip);

                if (ti.content.len > 0 and inner.w > 2 * INPUT_TEXT_PADDING) {
                    const m = measurer.measure(ti.content, ti.font);
                    const max_w = @max(0, inner.w - 2 * INPUT_TEXT_PADDING);
                    const text_rect = Rect{
                        .x = inner.x + INPUT_TEXT_PADDING,
                        .y = inner.y + @max(0, (inner.h - m.height) * 0.5),
                        .w = @min(m.width, max_w),
                        .h = m.height,
                    };
                    emitText(text_draws, alloc, ti.content, ti.font, ti.style.fg, text_rect, cur_clip);
                }

                // Blinking cursor when focused. ~0.5s on / 0.5s off at 60fps.
                if (focused and ((transient.frame_counter / 30) & 1) == 0) {
                    const prefix_w = measurer.prefixWidth(ti.content, ti.font, ti.cursor);
                    const cursor_x = inner.x + INPUT_TEXT_PADDING + prefix_w;
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
                    const m = measurer.measure(cb.label, cb.font);
                    const label_rect = Rect{
                        .x = label_x,
                        .y = rect.y + @max(0, (rect.h - m.height) * 0.5),
                        .w = m.width,
                        .h = m.height,
                    };
                    emitText(text_draws, alloc, cb.label, cb.font, cb.style.fg, label_rect, cur_clip);
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
                    const m = measurer.measure(rd.label, rd.font);
                    const label_rect = Rect{
                        .x = label_x,
                        .y = rect.y + @max(0, (rect.h - m.height) * 0.5),
                        .w = m.width,
                        .h = m.height,
                    };
                    emitText(text_draws, alloc, rd.label, rd.font, rd.style.fg, label_rect, cur_clip);
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

fn newTextDraws(alloc: std.mem.Allocator) std.ArrayList(TextDraw) {
    _ = alloc;
    return .empty;
}

test "buildVertices emits one bg quad per button and one TextDraw per label/text" {
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
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 400, 300, text_mod.monoMeasurer());

    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(testing.allocator);
    var text_draws = newTextDraws(testing.allocator);
    defer text_draws.deinit(testing.allocator);

    buildVertices(&verts, &text_draws, testing.allocator, cb.cmds.items, rects[0..cb.cmds.items.len], .{}, text_mod.monoMeasurer());
    // 1 button bg = 1 quad * 6 verts. Text and label go to text_draws.
    try testing.expectEqual(@as(usize, 6), verts.items.len);
    try testing.expectEqual(@as(usize, 2), text_draws.items.len); // "hello" + "+"
}

test "buildVertices clips child widgets to scroll container" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    const CmdBuffer = cmd_mod.CmdBuffer(Msg);

    var cb = CmdBuffer.init(testing.allocator);
    defer cb.deinit();

    // 100x100 viewport, four buttons — first two fit, third partial, fourth fully clipped.
    cb.pushScroll(.{ .width = 100, .height = 100, .padding = 0, .gap = 0 });
    cb.button(.a, "A"); // y = 0..36, fits
    cb.button(.a, "B"); // y = 36..72, fits
    cb.button(.a, "C"); // y = 72..108, partially clipped
    cb.button(.a, "D"); // y = 108..144, fully clipped
    cb.popScroll();

    var rects: [16]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 400, 400, text_mod.monoMeasurer());

    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(testing.allocator);
    var text_draws = newTextDraws(testing.allocator);
    defer text_draws.deinit(testing.allocator);
    buildVertices(&verts, &text_draws, testing.allocator, cb.cmds.items, rects[0..cb.cmds.items.len], .{}, text_mod.monoMeasurer());

    // 3 visible button backgrounds = 3 * 6 verts. D fully clipped emits nothing.
    // C's bg still emits a (clipped) quad.
    try testing.expectEqual(@as(usize, 18), verts.items.len);
    // All four labels go into text_draws regardless of clip — the GPU
    // pass does visibility clipping on the draw side.
    try testing.expectEqual(@as(usize, 4), text_draws.items.len);
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
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 400, 300, text_mod.monoMeasurer());

    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(testing.allocator);
    var text_draws = newTextDraws(testing.allocator);
    defer text_draws.deinit(testing.allocator);

    // Focused, blink-on frame (frame_counter 0 -> on).
    buildVertices(&verts, &text_draws, testing.allocator, cb.cmds.items, rects[0..cb.cmds.items.len], .{
        .focus_index = 1,
        .frame_counter = 0,
    }, text_mod.monoMeasurer());
    // border + bg + cursor = 3 quads = 18 verts. Content goes to text_draws.
    try testing.expectEqual(@as(usize, 18), verts.items.len);
    try testing.expectEqual(@as(usize, 1), text_draws.items.len); // "ab"
}
