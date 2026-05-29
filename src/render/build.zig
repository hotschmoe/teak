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
const TextureHandle = text_mod.TextureHandle;
const TEXTURE_HANDLE_NONE = text_mod.TEXTURE_HANDLE_NONE;
const vertex = @import("vertex.zig");
const Vertex = vertex.Vertex;
const emitQuad = vertex.emitQuad;

/// Image draw record. Parallel to TextDraw — the GPU backend consumes
/// these in `uploadImages` and emits 6 textured vertices per draw using
/// the tint as the vertex color (modulated against the texture alpha
/// and rgb in the shader, like text).
pub const ImageDraw = struct {
    rect_x: f32,
    rect_y: f32,
    rect_w: f32,
    rect_h: f32,
    handle: TextureHandle,
    tint: [4]f32,
    clip_x: f32,
    clip_y: f32,
    clip_w: f32,
    clip_h: f32,
};

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
/// solid-fill quads into `verts`, textured glyph records into
/// `text_draws`, and textured image records into `image_draws`.
/// Presentation state (hover, press, focus, blink) pulls from
/// TransientState without touching Model. Two passes — base layer
/// (cmds outside any push_overlay), then overlay layer — so overlays
/// (HARDLINE §2 escape hatch 5) draw on top.
pub fn buildVertices(
    verts: *std.ArrayList(Vertex),
    text_draws: *std.ArrayList(TextDraw),
    image_draws: *std.ArrayList(ImageDraw),
    alloc: std.mem.Allocator,
    cmds: anytype,
    rects: []const Rect,
    transient: TransientState,
    measurer: TextMeasurer,
) void {
    verts.clearRetainingCapacity();
    text_draws.clearRetainingCapacity();
    image_draws.clearRetainingCapacity();

    buildLayer(verts, text_draws, image_draws, alloc, cmds, rects, transient, measurer, .base);
    buildLayer(verts, text_draws, image_draws, alloc, cmds, rects, transient, measurer, .overlay);
}

const Layer = enum { base, overlay };

fn buildLayer(
    verts: *std.ArrayList(Vertex),
    text_draws: *std.ArrayList(TextDraw),
    image_draws: *std.ArrayList(ImageDraw),
    alloc: std.mem.Allocator,
    cmds: anytype,
    rects: []const Rect,
    transient: TransientState,
    measurer: TextMeasurer,
    layer: Layer,
) void {
    var clip: ClipStack = .{};
    var overlay_depth: u32 = 0;

    for (cmds, rects, 0..) |c, rect, i| {
        const cur_clip = clip.top();
        const in_overlay = overlay_depth > 0;
        const visible = switch (layer) {
            .base => !in_overlay,
            .overlay => in_overlay,
        };
        switch (c) {
            .push_overlay => |ov| {
                overlay_depth += 1;
                // Only the overlay layer draws the backdrop + clips to
                // the overlay rect.
                if (layer == .overlay) {
                    if (ov.backdrop[3] > 0) emit(verts, alloc, rect, ov.backdrop, cur_clip);
                    clip.push(clipRect(rect, cur_clip));
                } else {
                    // Base-layer must still push a clip so the
                    // overlay's children are correctly skipped from
                    // base-layer accumulation — but a no-effect clip
                    // (the existing cur_clip) is wrong because then
                    // contents would draw. We push a zero rect so
                    // anything inside is clipped away (defensive — the
                    // `visible` gate already drops them).
                    clip.push(.{ .x = -1e9, .y = -1e9, .w = 0, .h = 0 });
                }
            },
            .pop_overlay => {
                overlay_depth -= 1;
                clip.pop();
            },
            .push_scroll => clip.push(clipRect(rect, cur_clip)),
            .pop_scroll => clip.pop(),
            .push_group => |grp| {
                // Optional panel/card fill. Drawn BEFORE children so they
                // paint on top. Layout already gives us the group's full
                // (padded) rect; no inset.
                if (visible) if (grp.bg) |bg| emit(verts, alloc, rect, bg, cur_clip);
            },
            .pop_group, .push_virtual_list, .pop_virtual_list => {},
            .text => |txt| {
                if (visible) emitText(text_draws, alloc, txt.content, txt.font, txt.color, rect, cur_clip);
            },
            .rich_text => |rt| {
                if (!visible) continue;
                // Walk spans + uncovered ranges, emitting one TextDraw
                // per run. Maintains an x cursor along the rect.
                var x_cursor = rect.x;
                var byte_cursor: u32 = 0;
                for (rt.spans) |sp| {
                    if (sp.start > byte_cursor) {
                        const piece = rt.content[byte_cursor..sp.start];
                        const m = measurer.measure(piece, rt.default_font);
                        const r = Rect{ .x = x_cursor, .y = rect.y, .w = m.width, .h = rect.h };
                        emitText(text_draws, alloc, piece, rt.default_font, rt.default_color, r, cur_clip);
                        x_cursor += m.width;
                    }
                    const end = @min(sp.end, @as(u32, @intCast(rt.content.len)));
                    if (end > sp.start) {
                        const piece = rt.content[sp.start..end];
                        const m = measurer.measure(piece, sp.font);
                        const r = Rect{ .x = x_cursor, .y = rect.y, .w = m.width, .h = rect.h };
                        emitText(text_draws, alloc, piece, sp.font, sp.color, r, cur_clip);
                        x_cursor += m.width;
                    }
                    byte_cursor = end;
                }
                if (byte_cursor < rt.content.len) {
                    const piece = rt.content[byte_cursor..];
                    const m = measurer.measure(piece, rt.default_font);
                    const r = Rect{ .x = x_cursor, .y = rect.y, .w = m.width, .h = rect.h };
                    emitText(text_draws, alloc, piece, rt.default_font, rt.default_color, r, cur_clip);
                }
            },
            .image => |img| {
                if (!visible) continue;
                if (rect.w <= 0 or rect.h <= 0) continue;
                if (img.handle == TEXTURE_HANDLE_NONE) {
                    // No texture loaded yet — draw a tinted placeholder
                    // so the app sees where the image would go.
                    emit(verts, alloc, rect, img.style.tint, cur_clip);
                } else {
                    image_draws.append(alloc, .{
                        .rect_x = rect.x,
                        .rect_y = rect.y,
                        .rect_w = rect.w,
                        .rect_h = rect.h,
                        .handle = img.handle,
                        .tint = img.style.tint,
                        .clip_x = cur_clip.x,
                        .clip_y = cur_clip.y,
                        .clip_w = cur_clip.w,
                        .clip_h = cur_clip.h,
                    }) catch {};
                }
            },
            .button => |btn| {
                if (!visible) continue;
                // Disabled buttons show no hover/press feedback: a flat
                // greyed-out bg + greyed label, skipping the color ladder.
                var bg = btn.style.disabled_bg;
                var fg = btn.style.disabled_fg;
                if (!btn.disabled) {
                    const pressed = if (transient.press_index) |pi| pi == i else false;
                    const hovered = if (transient.hover_index) |hi| hi == i else false;
                    bg = if (pressed)
                        btn.style.press_bg
                    else if (hovered)
                        btn.style.hover_bg
                    else
                        btn.style.bg;
                    fg = btn.style.fg;
                }
                emit(verts, alloc, rect, bg, cur_clip);

                if (btn.label.len > 0) {
                    const m = measurer.measure(btn.label, btn.font);
                    const label_rect = Rect{
                        .x = rect.x + 8,
                        .y = rect.y + @max(0, (rect.h - m.height) * 0.5),
                        .w = @min(m.width, @max(0, rect.w - 16)),
                        .h = m.height,
                    };
                    emitText(text_draws, alloc, btn.label, btn.font, fg, label_rect, cur_clip);
                }
            },
            .text_input => |ti| {
                if (!visible) continue;
                // Disabled inputs are non-interactive: flat greyed border +
                // bg + text, skipping focus border, selection, and cursor.
                const focused = !ti.disabled and (if (transient.focus_index) |fi| fi == i else false);
                const border_color = if (ti.disabled)
                    ti.style.disabled_border
                else if (focused)
                    ti.style.focus_border
                else
                    ti.style.border;

                emit(verts, alloc, rect, border_color, cur_clip);
                const inner = insetRect(rect, BORDER_WIDTH);
                emit(verts, alloc, inner, if (ti.disabled) ti.style.disabled_bg else ti.style.bg, cur_clip);

                // Selection highlight before the text so text draws on top.
                // Disabled inputs never draw selection.
                if (!ti.disabled) {
                    if (ti.selection_anchor) |anchor| {
                        if (anchor != ti.cursor and ti.content.len > 0) {
                            const lo = @min(anchor, ti.cursor);
                            const hi = @max(anchor, ti.cursor);
                            const lo_w = measurer.prefixWidth(ti.content, ti.font, lo);
                            const hi_w = measurer.prefixWidth(ti.content, ti.font, hi);
                            const sel_rect = Rect{
                                .x = inner.x + INPUT_TEXT_PADDING + lo_w,
                                .y = inner.y + INPUT_TEXT_PADDING,
                                .w = @max(0, hi_w - lo_w),
                                .h = @max(0, inner.h - 2 * INPUT_TEXT_PADDING),
                            };
                            // Subtle highlight; the host can theme this via
                            // a new field on TextInputStyle if desired.
                            emit(verts, alloc, sel_rect, .{ 0.25, 0.45, 0.95, 0.45 }, cur_clip);
                        }
                    }
                }

                if (ti.content.len > 0 and inner.w > 2 * INPUT_TEXT_PADDING) {
                    const m = measurer.measure(ti.content, ti.font);
                    const max_w = @max(0, inner.w - 2 * INPUT_TEXT_PADDING);
                    const text_rect = Rect{
                        .x = inner.x + INPUT_TEXT_PADDING,
                        .y = inner.y + @max(0, (inner.h - m.height) * 0.5),
                        .w = @min(m.width, max_w),
                        .h = m.height,
                    };
                    const text_color = if (ti.disabled) ti.style.disabled_fg else ti.style.fg;
                    emitText(text_draws, alloc, ti.content, ti.font, text_color, text_rect, cur_clip);
                }

                // IME composition: when the focused input has an active
                // pre-commit string, draw it inline at the caret with an
                // underline indicator. The composition lives in
                // TransientState (mirror of Host.imeState()) and never
                // enters Model — commit fires WM_CHAR which flows through
                // the normal text-input update path.
                const ime_drawn = focused and transient.ime_active and transient.ime_text.len > 0;
                if (ime_drawn) {
                    const prefix_w = measurer.prefixWidth(ti.content, ti.font, ti.cursor);
                    const m = measurer.measure(transient.ime_text, ti.font);
                    const text_rect = Rect{
                        .x = inner.x + INPUT_TEXT_PADDING + prefix_w,
                        .y = inner.y + @max(0, (inner.h - m.height) * 0.5),
                        .w = m.width,
                        .h = m.height,
                    };
                    emitText(text_draws, alloc, transient.ime_text, ti.font, ti.style.fg, text_rect, cur_clip);
                    const underline_y = text_rect.y + m.height - 1;
                    const underline_rect = Rect{
                        .x = text_rect.x,
                        .y = underline_y,
                        .w = m.width,
                        .h = 1,
                    };
                    emit(verts, alloc, underline_rect, ti.style.cursor, cur_clip);
                }

                // Blinking cursor when focused. ~0.5s on / 0.5s off at 60fps.
                // While IME composition is active the caret moves to the
                // end of the composition string so the user sees where
                // the next codepoint will commit.
                if (focused and ((transient.frame_counter / 30) & 1) == 0) {
                    const base_prefix = measurer.prefixWidth(ti.content, ti.font, ti.cursor);
                    const ime_offset = if (ime_drawn)
                        measurer.prefixWidth(transient.ime_text, ti.font, transient.ime_cursor)
                    else
                        0;
                    const cursor_x = inner.x + INPUT_TEXT_PADDING + base_prefix + ime_offset;
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
                if (!visible) continue;
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
                if (!visible) continue;
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
                if (!visible) continue;
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
                if (!visible) continue;
                emit(verts, alloc, rect, dv.color, cur_clip);
            },
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

    var image_draws: std.ArrayList(ImageDraw) = .empty;
    defer image_draws.deinit(testing.allocator);
    buildVertices(&verts, &text_draws, &image_draws, testing.allocator, cb.cmds.items, rects[0..cb.cmds.items.len], .{}, text_mod.monoMeasurer());
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
    var image_draws: std.ArrayList(ImageDraw) = .empty;
    defer image_draws.deinit(testing.allocator);
    buildVertices(&verts, &text_draws, &image_draws, testing.allocator, cb.cmds.items, rects[0..cb.cmds.items.len], .{}, text_mod.monoMeasurer());

    // 3 visible button backgrounds = 3 * 6 verts. D fully clipped emits nothing.
    // C's bg still emits a (clipped) quad.
    try testing.expectEqual(@as(usize, 18), verts.items.len);
    // All four labels go into text_draws regardless of clip — the GPU
    // pass does visibility clipping on the draw side.
    try testing.expectEqual(@as(usize, 4), text_draws.items.len);
}

test "buildVertices draws overlay backdrop + content after base layer" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    const CmdBuffer = cmd_mod.CmdBuffer(Msg);

    var cb = CmdBuffer.init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.button(.a, "Base");
    cb.pushOverlay(.{
        .x = 100,
        .y = 100,
        .width = 200,
        .height = 100,
        .padding = 0,
        .backdrop = .{ 0, 0, 0, 0.5 },
    });
    cb.button(.a, "OvBtn");
    cb.popOverlay();
    cb.popGroup();

    var rects: [16]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 800, 600, text_mod.monoMeasurer());

    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(testing.allocator);
    var text_draws = newTextDraws(testing.allocator);
    defer text_draws.deinit(testing.allocator);
    var image_draws: std.ArrayList(ImageDraw) = .empty;
    defer image_draws.deinit(testing.allocator);

    buildVertices(&verts, &text_draws, &image_draws, testing.allocator, cb.cmds.items, rects[0..cb.cmds.items.len], .{}, text_mod.monoMeasurer());

    // 3 quads expected: base button bg, overlay backdrop, overlay button bg.
    try testing.expectEqual(@as(usize, 18), verts.items.len);
    // Both button labels rendered.
    try testing.expectEqual(@as(usize, 2), text_draws.items.len);
}

test "buildVertices rich_text emits one TextDraw per span" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    const CmdBuffer = cmd_mod.CmdBuffer(Msg);

    var cb = CmdBuffer.init(testing.allocator);
    defer cb.deinit();

    const spans = [_]@import("../core/cmd.zig").RichTextSpan{
        .{ .start = 0, .end = 5, .color = .{ 1, 0, 0, 1 } }, // "hello"
        .{ .start = 6, .end = 11, .color = .{ 0, 1, 0, 1 } }, // "world"
    };

    cb.pushGroup(.{});
    cb.richText("hello world", &spans);
    cb.popGroup();

    var rects: [8]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 400, 300, text_mod.monoMeasurer());

    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(testing.allocator);
    var text_draws = newTextDraws(testing.allocator);
    defer text_draws.deinit(testing.allocator);
    var image_draws: std.ArrayList(ImageDraw) = .empty;
    defer image_draws.deinit(testing.allocator);

    buildVertices(&verts, &text_draws, &image_draws, testing.allocator, cb.cmds.items, rects[0..cb.cmds.items.len], .{}, text_mod.monoMeasurer());

    // "hello", " " (uncovered), "world" = 3 draws.
    try testing.expectEqual(@as(usize, 3), text_draws.items.len);
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
    var image_draws: std.ArrayList(ImageDraw) = .empty;
    defer image_draws.deinit(testing.allocator);

    // Focused, blink-on frame (frame_counter 0 -> on).
    buildVertices(&verts, &text_draws, &image_draws, testing.allocator, cb.cmds.items, rects[0..cb.cmds.items.len], .{
        .focus_index = 1,
        .frame_counter = 0,
    }, text_mod.monoMeasurer());
    // border + bg + cursor = 3 quads = 18 verts. Content goes to text_draws.
    try testing.expectEqual(@as(usize, 18), verts.items.len);
    try testing.expectEqual(@as(usize, 1), text_draws.items.len); // "ab"
}

test "buildVertices: GroupStyle.bg emits a panel quad BEFORE children" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    const CmdBuffer = cmd_mod.CmdBuffer(Msg);

    var cb = CmdBuffer.init(testing.allocator);
    defer cb.deinit();

    // Single group with a red bg + a text child. The bg quad must be the
    // first 6 vertices in the stream (text goes to text_draws, not verts).
    cb.pushGroup(.{ .bg = .{ 1, 0, 0, 1 } });
    cb.text("hello");
    cb.popGroup();

    var rects: [8]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 400, 300, text_mod.monoMeasurer());

    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(testing.allocator);
    var text_draws = newTextDraws(testing.allocator);
    defer text_draws.deinit(testing.allocator);
    var image_draws: std.ArrayList(ImageDraw) = .empty;
    defer image_draws.deinit(testing.allocator);

    buildVertices(&verts, &text_draws, &image_draws, testing.allocator, cb.cmds.items, rects[0..cb.cmds.items.len], .{}, text_mod.monoMeasurer());

    // One bg quad = 6 vertices, all red. Text is in text_draws.
    try testing.expectEqual(@as(usize, 6), verts.items.len);
    try testing.expectEqual(@as(usize, 1), text_draws.items.len);
    // Every vertex of the bg quad should carry the red color we passed in.
    for (verts.items) |v| {
        try testing.expectEqual(@as(f32, 1), v.r);
        try testing.expectEqual(@as(f32, 0), v.g);
        try testing.expectEqual(@as(f32, 0), v.b);
        try testing.expectEqual(@as(f32, 1), v.a);
    }
}

test "buildVertices: GroupStyle.bg = null emits no panel quad (regression)" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    const CmdBuffer = cmd_mod.CmdBuffer(Msg);

    var cb = CmdBuffer.init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{}); // bg defaults to null
    cb.text("hello");
    cb.popGroup();

    var rects: [8]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 400, 300, text_mod.monoMeasurer());

    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(testing.allocator);
    var text_draws = newTextDraws(testing.allocator);
    defer text_draws.deinit(testing.allocator);
    var image_draws: std.ArrayList(ImageDraw) = .empty;
    defer image_draws.deinit(testing.allocator);

    buildVertices(&verts, &text_draws, &image_draws, testing.allocator, cb.cmds.items, rects[0..cb.cmds.items.len], .{}, text_mod.monoMeasurer());

    // Null bg → no quad at all. Text still flows to text_draws.
    try testing.expectEqual(@as(usize, 0), verts.items.len);
    try testing.expectEqual(@as(usize, 1), text_draws.items.len);
}

test "buildVertices: nested groups with bg render outer first, then inner" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    const CmdBuffer = cmd_mod.CmdBuffer(Msg);

    var cb = CmdBuffer.init(testing.allocator);
    defer cb.deinit();

    // Outer red, inner green. Painter's order → outer bg verts first,
    // then inner bg verts.
    cb.pushGroup(.{ .bg = .{ 1, 0, 0, 1 } });
    cb.pushGroup(.{ .bg = .{ 0, 1, 0, 1 } });
    cb.text("inner");
    cb.popGroup();
    cb.popGroup();

    var rects: [8]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 400, 300, text_mod.monoMeasurer());

    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(testing.allocator);
    var text_draws = newTextDraws(testing.allocator);
    defer text_draws.deinit(testing.allocator);
    var image_draws: std.ArrayList(ImageDraw) = .empty;
    defer image_draws.deinit(testing.allocator);

    buildVertices(&verts, &text_draws, &image_draws, testing.allocator, cb.cmds.items, rects[0..cb.cmds.items.len], .{}, text_mod.monoMeasurer());

    // Two bg quads = 12 vertices. First 6 = red (outer), next 6 = green (inner).
    try testing.expectEqual(@as(usize, 12), verts.items.len);
    for (verts.items[0..6]) |v| {
        try testing.expectEqual(@as(f32, 1), v.r);
        try testing.expectEqual(@as(f32, 0), v.g);
        try testing.expectEqual(@as(f32, 0), v.b);
    }
    for (verts.items[6..12]) |v| {
        try testing.expectEqual(@as(f32, 0), v.r);
        try testing.expectEqual(@as(f32, 1), v.g);
        try testing.expectEqual(@as(f32, 0), v.b);
    }
}
