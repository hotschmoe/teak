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
const cmd_types = @import("../core/cmd.zig");
const CanvasPrimitive = cmd_types.CanvasPrimitive;
const scene_types = @import("../core/scene.zig");
pub const SceneDraw = scene_types.SceneDraw;
const vertex = @import("vertex.zig");
const Vertex = vertex.Vertex;
const emitQuad = vertex.emitQuad;
const emitQuadCorners = vertex.emitQuadCorners;

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

/// Fixed outline of checkbox / radio boxes.
const BORDER_WIDTH: f32 = 2;
const CURSOR_WIDTH: f32 = 2;
const INPUT_TEXT_PADDING: f32 = 6;
const SLIDER_TRACK_PADDING: f32 = 2;
/// Underline-variant text input: label inset and rule thickness.
const UNDERLINE_PADDING_X: f32 = 2;
const UNDERLINE_PADDING_Y: f32 = 4;
const UNDERLINE_RULE: f32 = 1;
const UNDERLINE_RULE_FOCUSED: f32 = 2;

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

/// A `width`-thick frame INSIDE `r`: four non-overlapping edge quads (so a
/// translucent border doesn't double-blend at the corners). `width` is
/// clamped to half the smaller side.
fn emitBorder(verts: *std.ArrayList(Vertex), alloc: std.mem.Allocator, r: Rect, width: f32, color: [4]f32, clip: Rect) void {
    const t = @min(width, @min(r.w, r.h) * 0.5);
    if (t <= 0) return;
    emit(verts, alloc, .{ .x = r.x, .y = r.y, .w = r.w, .h = t }, color, clip);
    emit(verts, alloc, .{ .x = r.x, .y = r.y + r.h - t, .w = r.w, .h = t }, color, clip);
    emit(verts, alloc, .{ .x = r.x, .y = r.y + t, .w = t, .h = r.h - 2 * t }, color, clip);
    emit(verts, alloc, .{ .x = r.x + r.w - t, .y = r.y + t, .w = t, .h = r.h - 2 * t }, color, clip);
}

/// Generic over the Cmd slice type. Walks (cmd, rect) pairs and emits
/// solid-fill quads into `verts`, textured glyph records into
/// `text_draws`, textured image records into `image_draws`, and 3D scene
/// records into `scene_draws`. Presentation state (hover, press, focus,
/// blink) pulls from TransientState without touching Model. Two passes —
/// base layer (cmds outside any push_overlay), then overlay layer — so
/// overlays (HARDLINE §2 escape hatch 5) draw on top.
pub fn buildFrame(
    verts: *std.ArrayList(Vertex),
    text_draws: *std.ArrayList(TextDraw),
    image_draws: *std.ArrayList(ImageDraw),
    scene_draws: *std.ArrayList(SceneDraw),
    alloc: std.mem.Allocator,
    cmds: anytype,
    rects: []const Rect,
    transient: TransientState,
    measurer: TextMeasurer,
) void {
    verts.clearRetainingCapacity();
    text_draws.clearRetainingCapacity();
    image_draws.clearRetainingCapacity();
    scene_draws.clearRetainingCapacity();

    buildLayer(verts, text_draws, image_draws, scene_draws, alloc, cmds, rects, transient, measurer, .base);
    buildLayer(verts, text_draws, image_draws, scene_draws, alloc, cmds, rects, transient, measurer, .overlay);
}

/// `buildFrame` without scene output: `scene3d` Cmds are skipped. For
/// hand-rolled host loops that predate 3D scenes; `teak.run` uses
/// `buildFrame`.
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
    var scenes: std.ArrayList(SceneDraw) = .empty;
    defer scenes.deinit(alloc);
    buildFrame(verts, text_draws, image_draws, &scenes, alloc, cmds, rects, transient, measurer);
}

const Layer = enum { base, overlay };

fn buildLayer(
    verts: *std.ArrayList(Vertex),
    text_draws: *std.ArrayList(TextDraw),
    image_draws: *std.ArrayList(ImageDraw),
    scene_draws: *std.ArrayList(SceneDraw),
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
                    if (ov.shadow) |sh| {
                        const shadow_rect = Rect{ .x = rect.x + ov.shadow_offset[0], .y = rect.y + ov.shadow_offset[1], .w = rect.w, .h = rect.h };
                        emit(verts, alloc, shadow_rect, sh, cur_clip);
                    }
                    if (ov.backdrop[3] > 0) emit(verts, alloc, rect, ov.backdrop, cur_clip);
                    if (ov.border) |bc| emitBorder(verts, alloc, rect, ov.border_width, bc, cur_clip);
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
                if (visible) {
                    if (grp.bg) |bg| emit(verts, alloc, rect, bg, cur_clip);
                    if (grp.border) |bc| emitBorder(verts, alloc, rect, grp.border_width, bc, cur_clip);
                }
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
            .scene3d => |sc| {
                if (!visible) continue;
                if (rect.w <= 0 or rect.h <= 0) continue;
                scene_draws.append(alloc, .{
                    .mesh = sc.mesh,
                    .rect_x = rect.x,
                    .rect_y = rect.y,
                    .rect_w = rect.w,
                    .rect_h = rect.h,
                    .clip_x = cur_clip.x,
                    .clip_y = cur_clip.y,
                    .clip_w = cur_clip.w,
                    .clip_h = cur_clip.h,
                    .camera = sc.camera,
                    .clear = sc.clear,
                    .edge_color = sc.edge_color,
                    .edge_px = sc.edge_px,
                }) catch {};
            },
            .button => |btn| {
                if (!visible) continue;
                // Disabled buttons show no hover/press feedback: a flat
                // greyed-out bg + greyed label, skipping the color ladder.
                var bg = btn.style.disabled_bg;
                var fg = btn.style.disabled_fg;
                var label_dy: f32 = 0;
                if (!btn.disabled) {
                    const pressed = if (transient.press_index) |pi| pi == i else false;
                    const hovered = if (transient.hover_index) |hi| hi == i else false;
                    if (pressed) {
                        bg = btn.style.press_bg;
                        fg = btn.style.press_fg orelse btn.style.fg;
                        label_dy = btn.style.press_offset_y;
                    } else if (hovered) {
                        bg = btn.style.hover_bg;
                        fg = btn.style.hover_fg orelse btn.style.fg;
                    } else {
                        bg = btn.style.bg;
                        fg = btn.style.fg;
                    }
                }
                emit(verts, alloc, rect, bg, cur_clip);
                if (btn.style.border) |bc| emitBorder(verts, alloc, rect, btn.style.border_width, bc, cur_clip);

                if (btn.label.len > 0) {
                    const m = measurer.measure(btn.label, btn.font);
                    const avail = @max(0, rect.w - 2 * btn.style.h_padding);
                    const label_w = @min(m.width, avail);
                    const label_dx: f32 = switch (btn.style.label_align) {
                        .start => 0,
                        .center => (avail - label_w) * 0.5,
                        .end => avail - label_w,
                    };
                    const label_rect = Rect{
                        .x = rect.x + btn.style.h_padding + label_dx,
                        .y = rect.y + @max(0, (rect.h - m.height) * 0.5) + label_dy,
                        .w = label_w,
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

                // Boxed: border-colored rect with the bg inset inside it.
                // Underline: no box, just a rule along the bottom edge.
                const underline = ti.style.variant == .underline;
                const pad_x = if (underline) UNDERLINE_PADDING_X else INPUT_TEXT_PADDING;
                const pad_y = if (underline) UNDERLINE_PADDING_Y else INPUT_TEXT_PADDING;
                var inner = rect;
                if (underline) {
                    const rule = if (focused) UNDERLINE_RULE_FOCUSED else UNDERLINE_RULE;
                    emit(verts, alloc, .{ .x = rect.x, .y = rect.y + rect.h - rule, .w = rect.w, .h = rule }, border_color, cur_clip);
                    inner.h = @max(0, rect.h - rule);
                } else {
                    emit(verts, alloc, rect, border_color, cur_clip);
                    inner = insetRect(rect, ti.style.border_width);
                    emit(verts, alloc, inner, if (ti.disabled) ti.style.disabled_bg else ti.style.bg, cur_clip);
                }

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
                                .x = inner.x + pad_x + lo_w,
                                .y = inner.y + pad_y,
                                .w = @max(0, hi_w - lo_w),
                                .h = @max(0, inner.h - 2 * pad_y),
                            };
                            emit(verts, alloc, sel_rect, ti.style.selection_bg, cur_clip);
                        }
                    }
                }

                if (ti.content.len > 0 and inner.w > 2 * pad_x) {
                    const m = measurer.measure(ti.content, ti.font);
                    const max_w = @max(0, inner.w - 2 * pad_x);
                    const text_rect = Rect{
                        .x = inner.x + pad_x,
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
                        .x = inner.x + pad_x + prefix_w,
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
                    const cursor_x = inner.x + pad_x + base_prefix + ime_offset;
                    const cursor_h = @max(0, inner.h - 2 * pad_y);
                    const cursor_rect = Rect{
                        .x = cursor_x,
                        .y = inner.y + pad_y,
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
            .canvas => |cv| {
                if (!visible) continue;
                if (rect.w <= 0 or rect.h <= 0) continue;
                // Primitives clip to the canvas rect intersected with the
                // surrounding scroll/overlay clip — same rect-intersection
                // mechanism the rest of the pass uses, extended in data
                // space (Liang–Barsky) for the rotated polyline quads that
                // a plain rect clip can't express.
                const canvas_clip = clipRect(rect, cur_clip);
                if (canvas_clip.w <= 0 or canvas_clip.h <= 0) continue;
                if (cv.style.bg) |bg| emit(verts, alloc, rect, bg, cur_clip);
                for (cv.primitives) |prim| {
                    emitCanvasPrimitive(verts, alloc, rect, prim, canvas_clip);
                }
            },
        }
    }
}

// ── Canvas primitive emission ──────────────────────────────────────

/// Translate one canvas-local primitive to window space and emit it.
/// Axis-aligned prims go through `emit` (rect-clipped). Polyline segments
/// are clipped in data space then drawn as rotated quads via
/// `emitQuadCorners`.
fn emitCanvasPrimitive(
    verts: *std.ArrayList(Vertex),
    alloc: std.mem.Allocator,
    canvas: Rect,
    prim: CanvasPrimitive,
    clip: Rect,
) void {
    switch (prim) {
        .filled_rect => |fr| {
            emit(verts, alloc, .{
                .x = canvas.x + fr.x,
                .y = canvas.y + fr.y,
                .w = fr.w,
                .h = fr.h,
            }, fr.color, clip);
        },
        .hline => |h| {
            const half = h.thickness * 0.5;
            emit(verts, alloc, .{
                .x = canvas.x,
                .y = canvas.y + h.y - half,
                .w = canvas.w,
                .h = h.thickness,
            }, h.color, clip);
        },
        .vline => |v| {
            const half = v.thickness * 0.5;
            emit(verts, alloc, .{
                .x = canvas.x + v.x - half,
                .y = canvas.y,
                .w = v.thickness,
                .h = canvas.h,
            }, v.color, clip);
        },
        .marker => |mk| {
            const half = mk.size * 0.5;
            emit(verts, alloc, .{
                .x = canvas.x + mk.x - half,
                .y = canvas.y + mk.y - half,
                .w = mk.size,
                .h = mk.size,
            }, mk.color, clip);
        },
        .triangles => |tr| emitTriangles(verts, alloc, canvas, tr.verts, clip),
        .lines => |ln| {
            verts.ensureUnusedCapacity(alloc, ln.segs.len * 6) catch return;
            for (ln.segs) |sg| {
                var x0 = canvas.x + sg[0];
                var y0 = canvas.y + sg[1];
                var x1 = canvas.x + sg[2];
                var y1 = canvas.y + sg[3];
                if (clipSegment(&x0, &y0, &x1, &y1, clip)) {
                    emitSegmentQuad(verts, alloc, x0, y0, x1, y1, ln.thickness, ln.color);
                }
            }
        },
        .polyline => |pl| {
            if (pl.points.len < 2) return;
            var i: usize = 1;
            while (i < pl.points.len) : (i += 1) {
                const a = pl.points[i - 1];
                const b = pl.points[i];
                var x0 = canvas.x + a.x;
                var y0 = canvas.y + a.y;
                var x1 = canvas.x + b.x;
                var y1 = canvas.y + b.y;
                // Fully-outside segments are rejected; partially-outside
                // ones are trimmed to the clip rect at the data level. The
                // thick quad may still bulge by up to thickness/2 past the
                // boundary at a trimmed endpoint — negligible and bounded.
                if (clipSegment(&x0, &y0, &x1, &y1, clip)) {
                    emitSegmentQuad(verts, alloc, x0, y0, x1, y1, pl.thickness, pl.color);
                }
            }
        },
    }
}

// ── Triangle list emission ─────────────────────────────────────────

const TriVertex = CanvasPrimitive.TriVertex;

fn toVertex(canvas: Rect, v: TriVertex) Vertex {
    return .{ .x = canvas.x + v.x, .y = canvas.y + v.y, .r = v.r, .g = v.g, .b = v.b, .a = v.a, .u = 0, .v = 0 };
}

fn finiteVertex(v: TriVertex) bool {
    return std.math.isFinite(v.x) and std.math.isFinite(v.y);
}

/// Emit a canvas-local triangle list, clipped to `clip` (window space).
/// Three tiers, cheapest first: (1) the whole list's bounds sit inside the
/// clip — convert the vertices in one pass; (2) a triangle's own bounds do —
/// copy it; (3) otherwise Sutherland–Hodgman against the clip rect,
/// interpolating color, fan-triangulating the result. Triangles with a
/// non-finite position are dropped; a trailing partial triangle is ignored.
fn emitTriangles(
    verts: *std.ArrayList(Vertex),
    alloc: std.mem.Allocator,
    canvas: Rect,
    list: []const TriVertex,
    clip: Rect,
) void {
    const n = list.len - list.len % 3;
    if (n == 0) return;
    const tris = list[0..n];

    // Tier 1: bounds of everything (and finiteness) in one linear scan.
    var min_x = std.math.inf(f32);
    var min_y = std.math.inf(f32);
    var max_x = -std.math.inf(f32);
    var max_y = -std.math.inf(f32);
    var all_finite = true;
    for (tris) |v| {
        if (!finiteVertex(v)) {
            all_finite = false;
            break;
        }
        min_x = @min(min_x, v.x);
        min_y = @min(min_y, v.y);
        max_x = @max(max_x, v.x);
        max_y = @max(max_y, v.y);
    }
    if (all_finite and boundsInside(canvas, min_x, min_y, max_x, max_y, clip)) {
        const out = verts.addManyAsSlice(alloc, n) catch return;
        for (tris, out) |v, *o| o.* = toVertex(canvas, v);
        return;
    }

    var i: usize = 0;
    while (i < n) : (i += 3) {
        const t = tris[i..][0..3];
        if (!(finiteVertex(t[0]) and finiteVertex(t[1]) and finiteVertex(t[2]))) continue;
        const tx0 = @min(t[0].x, @min(t[1].x, t[2].x));
        const ty0 = @min(t[0].y, @min(t[1].y, t[2].y));
        const tx1 = @max(t[0].x, @max(t[1].x, t[2].x));
        const ty1 = @max(t[0].y, @max(t[1].y, t[2].y));
        if (boundsInside(canvas, tx0, ty0, tx1, ty1, clip)) {
            // Tier 2.
            verts.appendSlice(alloc, &.{ toVertex(canvas, t[0]), toVertex(canvas, t[1]), toVertex(canvas, t[2]) }) catch return;
        } else if (boundsOverlap(canvas, tx0, ty0, tx1, ty1, clip)) {
            // Tier 3.
            clipTriangle(verts, alloc, .{ toVertex(canvas, t[0]), toVertex(canvas, t[1]), toVertex(canvas, t[2]) }, clip);
        }
    }
}

fn boundsInside(canvas: Rect, x0: f32, y0: f32, x1: f32, y1: f32, clip: Rect) bool {
    return canvas.x + x0 >= clip.x and canvas.y + y0 >= clip.y and
        canvas.x + x1 <= clip.x + clip.w and canvas.y + y1 <= clip.y + clip.h;
}

fn boundsOverlap(canvas: Rect, x0: f32, y0: f32, x1: f32, y1: f32, clip: Rect) bool {
    return canvas.x + x1 > clip.x and canvas.y + y1 > clip.y and
        canvas.x + x0 < clip.x + clip.w and canvas.y + y0 < clip.y + clip.h;
}

fn lerpVertex(a: Vertex, b: Vertex, t: f32) Vertex {
    return .{
        .x = a.x + (b.x - a.x) * t,
        .y = a.y + (b.y - a.y) * t,
        .r = a.r + (b.r - a.r) * t,
        .g = a.g + (b.g - a.g) * t,
        .b = a.b + (b.b - a.b) * t,
        .a = a.a + (b.a - a.a) * t,
        .u = 0,
        .v = 0,
    };
}

/// A triangle clipped by four half-planes has at most 3 + 4 = 7 vertices.
const MAX_CLIP_POLY = 8;

/// Sutherland–Hodgman: clip one window-space triangle to `clip` and emit
/// the resulting convex polygon as a triangle fan.
fn clipTriangle(verts: *std.ArrayList(Vertex), alloc: std.mem.Allocator, tri: [3]Vertex, clip: Rect) void {
    // Ping-pong between two scratch polygons, one pass per clip edge.
    var buf_a: [MAX_CLIP_POLY]Vertex = undefined;
    var buf_b: [MAX_CLIP_POLY]Vertex = undefined;
    buf_a[0..3].* = tri;
    var src: []Vertex = buf_a[0..3];
    var dst: *[MAX_CLIP_POLY]Vertex = &buf_b;
    var spare: *[MAX_CLIP_POLY]Vertex = &buf_a;

    // Four edges: x >= left, x <= right, y >= top, y <= bottom.
    const Edge = struct { axis_y: bool, bound: f32, keep_greater: bool };
    const edges = [4]Edge{
        .{ .axis_y = false, .bound = clip.x, .keep_greater = true },
        .{ .axis_y = false, .bound = clip.x + clip.w, .keep_greater = false },
        .{ .axis_y = true, .bound = clip.y, .keep_greater = true },
        .{ .axis_y = true, .bound = clip.y + clip.h, .keep_greater = false },
    };
    for (edges) |e| {
        var out_len: usize = 0;
        for (src, 0..) |cur, i| {
            const prev = src[(i + src.len - 1) % src.len];
            const cur_c = if (e.axis_y) cur.y else cur.x;
            const prev_c = if (e.axis_y) prev.y else prev.x;
            const cur_in = if (e.keep_greater) cur_c >= e.bound else cur_c <= e.bound;
            const prev_in = if (e.keep_greater) prev_c >= e.bound else prev_c <= e.bound;
            if (cur_in != prev_in) {
                dst[out_len] = lerpVertex(prev, cur, (e.bound - prev_c) / (cur_c - prev_c));
                out_len += 1;
            }
            if (cur_in) {
                dst[out_len] = cur;
                out_len += 1;
            }
        }
        if (out_len < 3) return;
        src = dst[0..out_len];
        std.mem.swap(*[MAX_CLIP_POLY]Vertex, &dst, &spare);
    }

    verts.ensureUnusedCapacity(alloc, (src.len - 2) * 3) catch return;
    var k: usize = 1;
    while (k + 1 < src.len) : (k += 1) {
        verts.appendSliceAssumeCapacity(&.{ src[0], src[k], src[k + 1] });
    }
}

/// Build the 4 corners of a `thickness`-wide quad along segment
/// (x0,y0)→(x1,y1) and emit it. Zero-length segments draw nothing.
fn emitSegmentQuad(
    verts: *std.ArrayList(Vertex),
    alloc: std.mem.Allocator,
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,
    thickness: f32,
    color: [4]f32,
) void {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const len = @sqrt(dx * dx + dy * dy);
    if (len <= 0) return;
    const half = thickness * 0.5;
    // Unit normal (perpendicular to the segment) scaled by half-thickness.
    const nx = -dy / len * half;
    const ny = dx / len * half;
    emitQuadCorners(
        verts,
        alloc,
        .{ x0 + nx, y0 + ny },
        .{ x1 + nx, y1 + ny },
        .{ x1 - nx, y1 - ny },
        .{ x0 - nx, y0 - ny },
        color,
    );
}

/// Liang–Barsky segment clip against an axis-aligned rect. Mutates the
/// endpoints to the visible sub-segment and returns true if any part is
/// visible; returns false (endpoints untouched-but-ignored) if fully out.
fn clipSegment(x0: *f32, y0: *f32, x1: *f32, y1: *f32, clip: Rect) bool {
    // Reject a segment with any NaN endpoint outright. Every Liang–Barsky
    // t-comparison against a NaN is false, so a NaN segment would otherwise
    // sail through "accepted" and `emitSegmentQuad`'s `len <= 0` guard is also
    // false for a NaN length — the net result being six NaN vertices in the
    // buffer. Drop it here instead.
    if (std.math.isNan(x0.*) or std.math.isNan(y0.*) or
        std.math.isNan(x1.*) or std.math.isNan(y1.*)) return false;

    const dx = x1.* - x0.*;
    const dy = y1.* - y0.*;
    const xmin = clip.x;
    const xmax = clip.x + clip.w;
    const ymin = clip.y;
    const ymax = clip.y + clip.h;

    const p = [_]f32{ -dx, dx, -dy, dy };
    const q = [_]f32{ x0.* - xmin, xmax - x0.*, y0.* - ymin, ymax - y0.* };

    var t0: f32 = 0;
    var t1: f32 = 1;
    for (p, q) |pk, qk| {
        if (pk == 0) {
            // Segment parallel to this edge: reject if it starts outside.
            if (qk < 0) return false;
        } else {
            const t = qk / pk;
            if (pk < 0) {
                if (t > t1) return false;
                if (t > t0) t0 = t;
            } else {
                if (t < t0) return false;
                if (t < t1) t1 = t;
            }
        }
    }

    const nx0 = x0.* + t0 * dx;
    const ny0 = y0.* + t0 * dy;
    const nx1 = x0.* + t1 * dx;
    const ny1 = y0.* + t1 * dy;
    x0.* = nx0;
    y0.* = ny0;
    x1.* = nx1;
    y1.* = ny1;
    return true;
}

// ── Tests ──────────────────────────────────────────────────────────

// Chrome (border / shadow / hover / underline) tests live in their own file.
test {
    _ = @import("chrome_test.zig");
}

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

test "buildVertices: canvas axis-aligned prims each emit one quad" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    const prims = [_]CanvasPrimitive{
        .{ .filled_rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 } },
        .{ .hline = .{ .y = 20 } },
        .{ .vline = .{ .x = 30 } },
        .{ .marker = .{ .x = 40, .y = 40 } },
    };
    // bg + 4 axis-aligned prims = 5 quads = 30 verts.
    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.canvas(.{ .width = 100, .height = 100, .bg = .{ 0.1, 0.1, 0.1, 1 } }, &prims);
    cb.popGroup();

    var rects: [4]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 100, 100, text_mod.monoMeasurer());

    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(testing.allocator);
    var text_draws = newTextDraws(testing.allocator);
    defer text_draws.deinit(testing.allocator);
    var image_draws: std.ArrayList(ImageDraw) = .empty;
    defer image_draws.deinit(testing.allocator);

    buildVertices(&verts, &text_draws, &image_draws, testing.allocator, cb.cmds.items, rects[0..cb.cmds.items.len], .{}, text_mod.monoMeasurer());

    try testing.expectEqual(@as(usize, 30), verts.items.len);
}

test "clipSegment rejects NaN endpoints (F10)" {
    const testing = std.testing;
    const clip = Rect{ .x = 0, .y = 0, .w = 100, .h = 100 };

    // A NaN in any endpoint must reject: every Liang–Barsky t-test against NaN
    // is false, so without the guard the segment would be "accepted" with a
    // NaN length and emit six NaN vertices.
    inline for (0..4) |which| {
        var x0: f32 = 10;
        var y0: f32 = 10;
        var x1: f32 = 50;
        var y1: f32 = 50;
        const ptrs = [_]*f32{ &x0, &y0, &x1, &y1 };
        ptrs[which].* = std.math.nan(f32);
        try testing.expect(!clipSegment(&x0, &y0, &x1, &y1, clip));
    }

    // A finite, in-bounds segment is still accepted (no false negatives).
    var x0: f32 = 10;
    var y0: f32 = 10;
    var x1: f32 = 50;
    var y1: f32 = 50;
    try testing.expect(clipSegment(&x0, &y0, &x1, &y1, clip));
}

test "buildVertices: canvas polyline with a NaN point emits no NaN vertices (F10)" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    const nan = std.math.nan(f32);
    const prims = [_]CanvasPrimitive{
        .{ .polyline = .{
            .points = &.{ .{ .x = 0, .y = 0 }, .{ .x = nan, .y = nan }, .{ .x = 50, .y = 50 } },
            .thickness = 2,
        } },
    };
    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.canvas(.{ .width = 100, .height = 100 }, &prims);
    cb.popGroup();

    var rects: [4]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 100, 100, text_mod.monoMeasurer());

    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(testing.allocator);
    var text_draws = newTextDraws(testing.allocator);
    defer text_draws.deinit(testing.allocator);
    var image_draws: std.ArrayList(ImageDraw) = .empty;
    defer image_draws.deinit(testing.allocator);

    buildVertices(&verts, &text_draws, &image_draws, testing.allocator, cb.cmds.items, rects[0..cb.cmds.items.len], .{}, text_mod.monoMeasurer());

    // Both segments touch a NaN endpoint, so both are dropped — no vertices,
    // and definitely no NaN ones.
    for (verts.items) |v| {
        try testing.expect(!std.math.isNan(v.x));
        try testing.expect(!std.math.isNan(v.y));
    }
    try testing.expectEqual(@as(usize, 0), verts.items.len);
}

test "buildVertices: canvas polyline diagonal segment emits a rotated quad with expected corners" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    // Diagonal (0,0)->(50,50). thickness = 2√2 → half-width √2 → the
    // perpendicular offset is exactly (∓1, ±1). Canvas sits at the origin.
    const thick = 2.0 * @sqrt(2.0);
    const prims = [_]CanvasPrimitive{
        .{ .polyline = .{
            .points = &.{ .{ .x = 0, .y = 0 }, .{ .x = 50, .y = 50 } },
            .thickness = thick,
        } },
    };
    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.canvas(.{ .width = 100, .height = 100 }, &prims); // no bg
    cb.popGroup();

    var rects: [4]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 100, 100, text_mod.monoMeasurer());

    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(testing.allocator);
    var text_draws = newTextDraws(testing.allocator);
    defer text_draws.deinit(testing.allocator);
    var image_draws: std.ArrayList(ImageDraw) = .empty;
    defer image_draws.deinit(testing.allocator);

    buildVertices(&verts, &text_draws, &image_draws, testing.allocator, cb.cmds.items, rects[0..cb.cmds.items.len], .{}, text_mod.monoMeasurer());

    // One segment → one quad → 6 verts.
    try testing.expectEqual(@as(usize, 6), verts.items.len);
    // Triangle 1 corners: c0=(-1,1), c1=(49,51), c2=(51,49).
    try testing.expectApproxEqAbs(@as(f32, -1), verts.items[0].x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1), verts.items[0].y, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 49), verts.items[1].x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 51), verts.items[1].y, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 51), verts.items[2].x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 49), verts.items[2].y, 0.001);
    // Triangle 2 ends at c3=(1,-1).
    try testing.expectApproxEqAbs(@as(f32, 1), verts.items[5].x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, -1), verts.items[5].y, 0.001);
}

test "buildVertices: canvas polyline fully outside the canvas is clipped away" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    // Segment lives entirely past the canvas's 100x100 bounds → Liang–
    // Barsky rejects it → no geometry emitted.
    const prims = [_]CanvasPrimitive{
        .{ .polyline = .{
            .points = &.{ .{ .x = 200, .y = 200 }, .{ .x = 300, .y = 300 } },
            .thickness = 4,
        } },
    };
    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.canvas(.{ .width = 100, .height = 100 }, &prims);
    cb.popGroup();

    var rects: [4]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 100, 100, text_mod.monoMeasurer());

    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(testing.allocator);
    var text_draws = newTextDraws(testing.allocator);
    defer text_draws.deinit(testing.allocator);
    var image_draws: std.ArrayList(ImageDraw) = .empty;
    defer image_draws.deinit(testing.allocator);

    buildVertices(&verts, &text_draws, &image_draws, testing.allocator, cb.cmds.items, rects[0..cb.cmds.items.len], .{}, text_mod.monoMeasurer());

    try testing.expectEqual(@as(usize, 0), verts.items.len);
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

// ── Triangles / lines / scene draws ────────────────────────────────

const TestFrame = struct {
    verts: std.ArrayList(Vertex) = .empty,
    texts: std.ArrayList(TextDraw) = .empty,
    images: std.ArrayList(ImageDraw) = .empty,
    scenes: std.ArrayList(SceneDraw) = .empty,

    fn deinit(self: *TestFrame, alloc: std.mem.Allocator) void {
        self.verts.deinit(alloc);
        self.texts.deinit(alloc);
        self.images.deinit(alloc);
        self.scenes.deinit(alloc);
    }
};

/// Lay out `cb` in a 1000x1000 window and build its frame.
fn buildTestFrame(alloc: std.mem.Allocator, cb: anytype) !TestFrame {
    const rects = try alloc.alloc(Rect, cb.cmds.items.len);
    defer alloc.free(rects);
    layout.LayoutEngine.doLayout(rects, cb.cmds.items, 1000, 1000, text_mod.monoMeasurer());
    var f: TestFrame = .{};
    buildFrame(&f.verts, &f.texts, &f.images, &f.scenes, alloc, cb.cmds.items, rects, .{}, text_mod.monoMeasurer());
    return f;
}

const TV = CanvasPrimitive.TriVertex;

fn tv(x: f32, y: f32, r: f32, g: f32, b: f32) TV {
    return .{ .x = x, .y = y, .r = r, .g = g, .b = b, .a = 1 };
}

/// Area of a triangle-list vertex buffer (sum of |cross|/2).
fn totalArea(verts: []const Vertex) f32 {
    var area: f32 = 0;
    var i: usize = 0;
    while (i + 2 < verts.len) : (i += 3) {
        const a = verts[i];
        const b = verts[i + 1];
        const c = verts[i + 2];
        area += @abs((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)) * 0.5;
    }
    return area;
}

fn canvasWith(alloc: std.mem.Allocator, w: f32, h: f32, prims: []const CanvasPrimitive) !TestFrame {
    const Msg = union(enum) { a };
    var cb = cmd_mod.CmdBuffer(Msg).init(alloc);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    cb.canvas(.{ .width = w, .height = h }, prims);
    cb.popGroup();
    return buildTestFrame(alloc, &cb);
}

test "canvas triangles fully inside are copied through, translated and colored" {
    const testing = std.testing;
    const tris = [_]TV{ tv(10, 10, 1, 0, 0), tv(60, 10, 0, 1, 0), tv(10, 60, 0, 0, 1), tv(70, 70, 1, 1, 1), tv(90, 70, 1, 1, 1), tv(90, 90, 1, 1, 1) };
    var f = try canvasWith(testing.allocator, 100, 100, &.{.{ .triangles = .{ .verts = &tris } }});
    defer f.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 6), f.verts.items.len);
    // Group padding 0 + canvas at origin: local == window coords.
    try testing.expectEqual(@as(f32, 10), f.verts.items[0].x);
    try testing.expectEqual(@as(f32, 1), f.verts.items[0].r);
    try testing.expectEqual(@as(f32, 1), f.verts.items[1].g);
    try testing.expectEqual(@as(f32, 1), f.verts.items[2].b);
    try testing.expectEqual(@as(f32, 1), f.verts.items[2].a);
}

test "canvas triangles are clipped to the canvas rect with color interpolation" {
    const testing = std.testing;
    // A=(50,10) red, B=(150,10) green, C=(50,60) blue; canvas is 100x100 so
    // everything past x=100 is cut: the kept polygon is
    // A, (100,10), (100,35), C with area 1875.
    const tris = [_]TV{ tv(50, 10, 1, 0, 0), tv(150, 10, 0, 1, 0), tv(50, 60, 0, 0, 1) };
    var f = try canvasWith(testing.allocator, 100, 100, &.{.{ .triangles = .{ .verts = &tris } }});
    defer f.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 6), f.verts.items.len); // quad -> 2 triangles
    for (f.verts.items) |v| {
        try testing.expect(v.x >= 50 - 0.001 and v.x <= 100 + 0.001);
        try testing.expect(v.y >= 10 - 0.001 and v.y <= 60 + 0.001);
    }
    try testing.expectApproxEqAbs(@as(f32, 1875), totalArea(f.verts.items), 0.5);

    // The point where the A-B edge crosses x=100 is the midpoint: r=g=0.5.
    var found = false;
    for (f.verts.items) |v| {
        if (@abs(v.x - 100) < 0.001 and @abs(v.y - 10) < 0.001) {
            try testing.expectApproxEqAbs(@as(f32, 0.5), v.r, 1e-5);
            try testing.expectApproxEqAbs(@as(f32, 0.5), v.g, 1e-5);
            found = true;
        }
    }
    try testing.expect(found);
}

test "canvas triangles: fully outside, non-finite and trailing partial triangles are dropped" {
    const testing = std.testing;
    const nan = std.math.nan(f32);
    const tris = [_]TV{
        tv(200, 200, 1, 1, 1), tv(300, 200, 1, 1, 1), tv(200, 300, 1, 1, 1), // outside
        tv(nan, 0, 1, 1, 1), tv(10, 0, 1, 1, 1), tv(0, 10, 1, 1, 1), // NaN
        tv(10, 10, 1, 1, 1), tv(20, 10, 1, 1, 1), tv(10, 20, 1, 1, 1), // kept
        tv(1, 1, 1, 1, 1), tv(2, 2, 1, 1, 1), // partial trailer
    };
    var f = try canvasWith(testing.allocator, 100, 100, &.{.{ .triangles = .{ .verts = &tris } }});
    defer f.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), f.verts.items.len);
    for (f.verts.items) |v| try testing.expect(std.math.isFinite(v.x) and std.math.isFinite(v.y));
}

test "canvas triangles honour the surrounding scroll clip, not just the canvas rect" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    // A 100x40 viewport over a 100x100 canvas: only the top 40 rows show.
    const tris = [_]TV{ tv(0, 0, 1, 1, 1), tv(100, 0, 1, 1, 1), tv(0, 100, 1, 1, 1) };
    cb.pushScroll(.{ .width = 100, .height = 40, .padding = 0, .gap = 0 });
    cb.canvas(.{ .width = 100, .height = 100 }, &.{.{ .triangles = .{ .verts = &tris } }});
    cb.popScroll();
    var f = try buildTestFrame(testing.allocator, &cb);
    defer f.deinit(testing.allocator);

    try testing.expect(f.verts.items.len >= 3);
    for (f.verts.items) |v| try testing.expect(v.y <= 40 + 0.001);
    // Visible part: triangle area within y<=40 = 100*100/2 - 100*60... = 5000 - (60*60... )
    // The triangle narrows linearly: at y the width is 100*(1 - y/100).
    // Area(0..40) = integral of (100 - y) dy = 100*40 - 40*40/2 = 3200.
    try testing.expectApproxEqAbs(@as(f32, 3200), totalArea(f.verts.items), 1);
}

test "canvas lines: one quad per visible segment, trimmed to the canvas" {
    const testing = std.testing;
    const segs = [_][4]f32{
        .{ 10, 10, 90, 10 }, // inside
        .{ 200, 0, 300, 0 }, // outside
        .{ 50, 50, 150, 50 }, // crosses the right edge
    };
    var f = try canvasWith(testing.allocator, 100, 100, &.{.{ .lines = .{ .segs = &segs, .thickness = 2, .color = .{ 1, 0, 0, 1 } } }});
    defer f.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 12), f.verts.items.len); // 2 quads
    for (f.verts.items) |v| {
        try testing.expect(v.x <= 100 + 0.001);
        try testing.expectEqual(@as(f32, 1), v.r);
    }
}

test "scene3d emits a SceneDraw with rect, clip and camera; buildVertices skips it" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 10, .gap = 0 });
    cb.text("title");
    var cam: scene_types.Camera = .{};
    cam.eye = .{ 1, 2, 3 };
    cb.scene3d(.{ .style = .{ .width = 200, .height = 150 }, .mesh = 7, .camera = cam, .clear = .{ 1, 0, 0, 1 }, .edge_px = 3 });
    cb.popGroup();

    var f = try buildTestFrame(testing.allocator, &cb);
    defer f.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), f.scenes.items.len);
    const sd = f.scenes.items[0];
    try testing.expectEqual(@as(u32, 7), sd.mesh);
    try testing.expectEqual(@as(f32, 200), sd.rect_w);
    try testing.expectEqual(@as(f32, 150), sd.rect_h);
    try testing.expectEqual(@as(f32, 10), sd.rect_x);
    try testing.expectEqual(@as(f32, 3), sd.camera.eye[2]);
    try testing.expectEqual(@as(f32, 3), sd.edge_px);
    try testing.expectEqual(@as(f32, 1), sd.clear[0]);
    // No solid quad is drawn for the scene itself.
    try testing.expectEqual(@as(usize, 0), f.verts.items.len);

    // The scene-less entry point ignores it without leaking.
    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(testing.allocator);
    var texts: std.ArrayList(TextDraw) = .empty;
    defer texts.deinit(testing.allocator);
    var images: std.ArrayList(ImageDraw) = .empty;
    defer images.deinit(testing.allocator);
    var rects: [4]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 400, 400, text_mod.monoMeasurer());
    buildVertices(&verts, &texts, &images, testing.allocator, cb.cmds.items, rects[0..cb.cmds.items.len], .{}, text_mod.monoMeasurer());
    try testing.expectEqual(@as(usize, 1), texts.items.len);
}

test "scene3d is clipped by a scroll container's clip rect" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    cb.pushScroll(.{ .width = 100, .height = 60, .padding = 0, .gap = 0 });
    cb.scene3d(.{ .style = .{ .width = 300, .height = 300 } });
    cb.popScroll();
    var f = try buildTestFrame(testing.allocator, &cb);
    defer f.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), f.scenes.items.len);
    try testing.expectEqual(@as(f32, 300), f.scenes.items[0].rect_w);
    try testing.expectEqual(@as(f32, 100), f.scenes.items[0].clip_w);
    try testing.expectEqual(@as(f32, 60), f.scenes.items[0].clip_h);
}

test "scene3d inside an overlay is emitted by the overlay layer" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{});
    cb.scene3d(.{ .mesh = 1 });
    cb.pushOverlay(.{ .x = 50, .y = 50, .width = 200, .height = 200 });
    cb.scene3d(.{ .mesh = 2 });
    cb.popOverlay();
    cb.popGroup();
    var f = try buildTestFrame(testing.allocator, &cb);
    defer f.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), f.scenes.items.len);
    try testing.expectEqual(@as(u32, 1), f.scenes.items[0].mesh); // base layer first
    try testing.expectEqual(@as(u32, 2), f.scenes.items[1].mesh);
}

// 200k vertices (66k triangles): the all-inside path is a single bulk copy
// (one allocation); the clipping path stays linear. Wall-clock bounds are
// deliberately loose (Debug build, shared CI) — they catch accidental
// quadratic behaviour, not micro-regressions.
test "perf: 200k triangle vertices, inside and clipped" {
    const testing = std.testing;
    const n_tris: usize = 66_666;
    const list = try testing.allocator.alloc(TV, n_tris * 3);
    defer testing.allocator.free(list);
    for (0..n_tris) |t| {
        const x: f32 = @floatFromInt(t % 250);
        const y: f32 = @floatFromInt(t / 250 % 250);
        list[t * 3 + 0] = tv(x * 2, y * 2, 1, 0, 0);
        list[t * 3 + 1] = tv(x * 2 + 1.5, y * 2, 0, 1, 0);
        list[t * 3 + 2] = tv(x * 2, y * 2 + 1.5, 0, 0, 1);
    }

    const io = testing.io;
    const t0 = std.Io.Clock.awake.now(io).nanoseconds;

    // Inside: the clip covers everything -> one bulk conversion, one allocation.
    var counting = testing.FailingAllocator.init(testing.allocator, .{});
    var inside: std.ArrayList(Vertex) = .empty;
    defer inside.deinit(counting.allocator());
    const all: Rect = .{ .x = 0, .y = 0, .w = 600, .h = 600 };
    emitTriangles(&inside, counting.allocator(), all, list, all);
    try testing.expectEqual(n_tris * 3, inside.items.len);
    try testing.expectEqual(@as(usize, 1), counting.allocations);

    // Clipped: a 250x250 canvas cuts about 5/6 of the field; triangles
    // straddling the edge go through Sutherland–Hodgman.
    var clipped = try canvasWith(testing.allocator, 250, 250, &.{.{ .triangles = .{ .verts = list } }});
    defer clipped.deinit(testing.allocator);
    try testing.expect(clipped.verts.items.len > 0 and clipped.verts.items.len < n_tris * 3);
    for (clipped.verts.items) |v| try testing.expect(v.x <= 250.001 and v.y <= 250.001);

    const elapsed_ms = @divTrunc(std.Io.Clock.awake.now(io).nanoseconds - t0, std.time.ns_per_ms);
    try testing.expect(elapsed_ms < 3000);
}

test "perf: 100k line segments" {
    const testing = std.testing;
    const n: usize = 100_000;
    const segs = try testing.allocator.alloc([4]f32, n);
    defer testing.allocator.free(segs);
    for (segs, 0..) |*s, i| {
        const y: f32 = @floatFromInt(i % 500);
        const x: f32 = @floatFromInt(i / 500);
        s.* = .{ x, y, x + 3, y + 2 };
    }
    var f = try canvasWith(testing.allocator, 400, 400, &.{.{ .lines = .{ .segs = segs, .thickness = 1 } }});
    defer f.deinit(testing.allocator);
    try testing.expect(f.verts.items.len > 0 and f.verts.items.len <= n * 6);
}
