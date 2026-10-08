const std = @import("std");
const layout = @import("../layout/engine.zig");
const Rect = layout.Rect;
const ClipStack = layout.ClipStack;
const clipRect = layout.clipRect;
const TransientState = @import("../core/transient.zig").TransientState;
const text_mod = @import("../core/text.zig");
const text_wrap = @import("../core/text_wrap.zig");
const bidi_text = @import("../core/bidi_text.zig");
const TextDraw = text_mod.TextDraw;
const TextMeasurer = text_mod.TextMeasurer;
const FontSpec = text_mod.FontSpec;
const TextureHandle = text_mod.TextureHandle;
const TEXTURE_HANDLE_NONE = text_mod.TEXTURE_HANDLE_NONE;
const cmd_types = @import("../core/cmd.zig");
const CanvasPrimitive = cmd_types.CanvasPrimitive;
const scene_types = @import("../core/scene.zig");
pub const SceneDraw = scene_types.SceneDraw;
pub const SceneItem = scene_types.Item;
pub const SceneSprite = scene_types.Sprite;
pub const SceneData = scene_types.SceneData;
const vertex = @import("vertex.zig");
const Vertex = vertex.Vertex;
const emitQuad = vertex.emitQuad;
const emitQuadCorners = vertex.emitQuadCorners;
pub const canvas_tess = @import("canvas_tess.zig");
const emit = canvas_tess.emit;
const emitCanvasPrimitive = canvas_tess.emitCanvasPrimitive;
const clipSegment = canvas_tess.clipSegment;
const emitTriangles = canvas_tess.emitTriangles;
pub const sdf = @import("sdf.zig");

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
/// Where the overlay layer (HARDLINE §2 hatch 5: base z=0, overlay z=1)
/// starts inside each staged list, as counts of what the base layer
/// produced. A Gpu that honours it draws base solids, images, scene
/// composites and text first, THEN the overlay's solids, images, composites
/// and text, so an opaque overlay panel hides base-layer text and images
/// beneath it. Without a split (all lists drawn by kind) the base layer's
/// text and images would show through overlay quads.
pub const OverlaySplit = struct {
    /// Vertices in `verts` produced by the base layer.
    verts: u32 = 0,
    text: u32 = 0,
    images: u32 = 0,
    scenes: u32 = 0,
};

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

/// Draw a direction-aware line: one `TextDraw` per directional run, placed left
/// to right as displayed. Right-to-left runs set `font.rtl` so the shaper
/// returns them in visual order.
fn emitBidiRuns(
    text_draws: *std.ArrayList(TextDraw),
    alloc: std.mem.Allocator,
    lay: *const bidi_text.Layout,
    x: f32,
    y: f32,
    h: f32,
    color: [4]f32,
    clip: Rect,
) void {
    for (lay.items()) |r| {
        var f = lay.font;
        f.rtl = r.rtl();
        emitText(text_draws, alloc, lay.text[r.start..r.end], f, color, .{ .x = x + r.x, .y = y, .w = r.w, .h = h }, clip);
    }
}

/// A rect with rounded corners, a gradient and / or a soft shadow, plus an
/// inside border stroke, as one SDF quad. Returns false (nothing emitted)
/// when the rect uses none of those, so the caller keeps its plain solid
/// quads, which is what makes the defaults pixel-identical to before.
fn emitSurface(
    verts: *std.ArrayList(Vertex),
    alloc: std.mem.Allocator,
    r: Rect,
    radii: cmd_types.Radii,
    fill: ?[4]f32,
    gradient: ?cmd_types.Gradient,
    border: ?[4]f32,
    border_width: f32,
    shadow: ?cmd_types.Shadow,
    clip: Rect,
) bool {
    if (!sdf.needed(radii, gradient, shadow)) return false;
    sdf.emitRect(verts, alloc, .{
        .rect = r,
        .radii = radii,
        .fill = fill orelse .{ 0, 0, 0, 0 },
        .gradient = gradient,
        .border_width = if (border != null) border_width else 0,
        .border = border orelse .{ 0, 0, 0, 0 },
        .shadow = shadow,
    }, clip);
    return true;
}

/// One TextDraw per wrapped line of a `text` Cmd with `wrap != .none`, using
/// the same `text_wrap` line walk layout used for the height, so the line
/// count drawn equals the height reserved. Lines wholly outside `clip` are
/// skipped; an ellipsized line is the kept text plus a second draw of U+2026
/// (no allocation: `alloc` is the long-lived run-loop allocator).
fn emitWrapped(
    text_draws: *std.ArrayList(TextDraw),
    alloc: std.mem.Allocator,
    txt: anytype,
    rect: Rect,
    clip: Rect,
    measurer: TextMeasurer,
) void {
    if (rect.w <= 0 or rect.h <= 0) return;
    const lh = text_wrap.lineHeight(txt.font, measurer);
    var it = text_wrap.LineIter.init(txt.content, txt.font, rect.w, txt.wrap, txt.max_lines, measurer);
    var li: f32 = 0;
    while (it.next()) |line| : (li += 1) {
        const y = rect.y + li * lh;
        if (y + lh <= clip.y or y >= clip.y + clip.h) continue;
        const x = switch (txt.text_align) {
            .start => rect.x,
            .center => rect.x + (rect.w - line.width) * 0.5,
            .end => rect.x + rect.w - line.width,
        };
        const piece = txt.content[line.start..line.end];
        if (!line.ellipsized and bidi_text.mayBeRtl(piece)) {
            var sc: bidi_text.Scratch = .{};
            if (bidi_text.layoutLine(txt.content, line.start, line.end, txt.font, measurer, std.math.inf(f32), &sc)) |lay| {
                // A right-to-left paragraph starts at the right edge.
                const bx = switch (txt.text_align) {
                    .start => if (lay.para_rtl) rect.x + rect.w - line.width else rect.x,
                    else => x,
                };
                emitBidiRuns(text_draws, alloc, &lay, bx, y, lh, txt.color, clip);
                continue;
            }
        }
        if (line.ellipsized) {
            // Two draws, no allocation: the kept text, then a static "…"
            // right after it (the run loop's allocator is the long-lived gpa).
            const ew = measurer.measure(text_wrap.ELLIPSIS, txt.font).width;
            const kept_w = line.width - ew;
            emitText(text_draws, alloc, piece, txt.font, txt.color, .{ .x = x, .y = y, .w = kept_w, .h = lh }, clip);
            emitText(text_draws, alloc, text_wrap.ELLIPSIS, txt.font, txt.color, .{ .x = x + kept_w, .y = y, .w = ew, .h = lh }, clip);
        } else {
            emitText(text_draws, alloc, piece, txt.font, txt.color, .{ .x = x, .y = y, .w = line.width, .h = lh }, clip);
        }
    }
}

/// A wrapped `rich_text`: lines break across spans with the same `text_wrap`
/// walk layout used (via `RichMeasure`); each line is drawn as one TextDraw
/// per same-font/colour piece, left to right, aligned by `text_align`.
fn emitRichWrapped(
    text_draws: *std.ArrayList(TextDraw),
    alloc: std.mem.Allocator,
    rt: anytype,
    rect: Rect,
    clip: Rect,
    measurer: TextMeasurer,
) void {
    if (rect.w <= 0 or rect.h <= 0) return;
    const rm = text_wrap.RichMeasure.init(rt.content, rt.spans, rt.default_font, measurer);
    const lh = rm.max_height;
    var it = text_wrap.LineIter.init(rt.content, rt.default_font, rect.w, rt.wrap, rt.max_lines, rm.measurer());
    var li: f32 = 0;
    while (it.next()) |line| : (li += 1) {
        const y = rect.y + li * lh;
        if (y + lh <= clip.y or y >= clip.y + clip.h) continue;
        var x = switch (rt.text_align) {
            .start => rect.x,
            .center => rect.x + (rect.w - line.width) * 0.5,
            .end => rect.x + rect.w - line.width,
        };
        var cursor: usize = line.start;
        while (cursor < line.end) {
            var font = rt.default_font;
            var color = rt.default_color;
            var stop: usize = line.end;
            for (rt.spans) |sp| {
                const s: usize = @min(sp.start, rt.content.len);
                const e: usize = @min(sp.end, rt.content.len);
                if (e <= cursor) continue;
                if (s <= cursor) {
                    font = sp.font;
                    color = sp.color;
                    stop = @min(e, stop);
                } else stop = @min(s, stop);
                break;
            }
            const piece = rt.content[cursor..stop];
            const w = measurer.measure(piece, font).width;
            emitText(text_draws, alloc, piece, font, color, .{ .x = x, .y = y, .w = w, .h = lh }, clip);
            x += w;
            cursor = stop;
        }
        if (line.ellipsized) {
            const ew = measurer.measure(text_wrap.ELLIPSIS, rt.default_font).width;
            emitText(text_draws, alloc, text_wrap.ELLIPSIS, rt.default_font, rt.default_color, .{ .x = x, .y = y, .w = ew, .h = lh }, clip);
        }
    }
}

/// A `text_area`: border + bg, selection quads per wrapped line, one
/// `TextDraw` per visible line (culled by scroll), the IME composition at the
/// caret, and the blinking caret -- all clipped to the inner box. Line breaks
/// come from the same `text_wrap` walk the metrics event and pointer
/// resolution use, so caret, selection and hit-testing agree.
fn emitTextArea(
    verts: *std.ArrayList(Vertex),
    text_draws: *std.ArrayList(TextDraw),
    alloc: std.mem.Allocator,
    ta: anytype,
    rect: Rect,
    cur_clip: Rect,
    transient: TransientState,
    measurer: TextMeasurer,
    focused: bool,
) void {
    const st = ta.style;
    const border_color = if (ta.disabled) st.disabled_border else if (focused) st.focus_border else st.border;
    emit(verts, alloc, rect, border_color, cur_clip);
    emit(verts, alloc, insetRect(rect, st.border_width), if (ta.disabled) st.disabled_bg else st.bg, cur_clip);

    const inner = layout.textAreaInner(rect, ta);
    const clip = clipRect(inner, cur_clip);
    if (clip.w <= 0 or clip.h <= 0) return;
    const wrap_w = layout.textAreaWrapWidth(inner, ta);
    const mode: text_wrap.Wrap = if (ta.wrap == .ellipsis) .none else ta.wrap;
    const lh = text_wrap.lineHeight(ta.font, measurer);
    const ox = inner.x - ta.scroll_x;
    const oy = inner.y - ta.scroll_y;
    const fg = if (ta.disabled) st.disabled_fg else st.fg;

    const sel_lo: usize = if (ta.selection_anchor) |a| @min(a, ta.cursor) else 0;
    const sel_hi: usize = if (ta.selection_anchor) |a| @max(a, ta.cursor) else 0;
    const has_sel = !ta.disabled and sel_hi > sel_lo;

    var scratch: bidi_text.Scratch = .{};
    var it = text_wrap.LineIter.init(ta.content, ta.font, wrap_w, mode, 0, measurer);
    var li: f32 = 0;
    while (it.next()) |line| : (li += 1) {
        const y = oy + li * lh;
        if (y >= clip.y + clip.h) break;
        if (y + lh <= clip.y) continue;
        var lay_storage: bidi_text.Layout = undefined;
        const lay: ?*const bidi_text.Layout = if (bidi_text.mayBeRtl(ta.content) and line.end > line.start) blk: {
            lay_storage = bidi_text.layoutLine(ta.content, line.start, line.end, ta.font, measurer, wrap_w, &scratch) orelse break :blk null;
            break :blk &lay_storage;
        } else null;
        if (has_sel and sel_hi > line.start and sel_lo < line.next and lay != null) {
            var spans: [8]bidi_text.Span = undefined;
            for (lay.?.selection(sel_lo, sel_hi, &spans)) |sp| {
                emit(verts, alloc, .{ .x = ox + sp.x0, .y = y, .w = sp.x1 - sp.x0, .h = lh }, st.selection_bg, clip);
            }
            if (sel_hi > line.hang) {
                const ex = ox + lay.?.caretX(line.end) + (if (lay.?.para_rtl) -lh * 0.3 else 0);
                emit(verts, alloc, .{ .x = ex, .y = y, .w = lh * 0.3, .h = lh }, st.selection_bg, clip);
            }
        } else if (has_sel and sel_hi > line.start and sel_lo < line.next) {
            const a = @max(sel_lo, @as(usize, line.start));
            const b = @min(sel_hi, @as(usize, line.hang));
            const x0 = if (a > line.start) measurer.measure(ta.content[line.start..a], ta.font).width else 0;
            var x1 = if (b > line.start) measurer.measure(ta.content[line.start..b], ta.font).width else x0;
            // A selection that runs past the line end shows a newline stub.
            if (sel_hi > line.hang) x1 += lh * 0.3;
            if (x1 > x0) emit(verts, alloc, .{ .x = ox + x0, .y = y, .w = x1 - x0, .h = lh }, st.selection_bg, clip);
        }
        if (lay) |l| {
            emitBidiRuns(text_draws, alloc, l, ox, y, lh, fg, clip);
        } else if (line.end > line.start) {
            emitText(text_draws, alloc, ta.content[line.start..line.end], ta.font, fg, .{ .x = ox, .y = y, .w = line.width, .h = lh }, clip);
        }
    }

    if (!focused) return;
    const caret = text_wrap.caretPos(ta.content, ta.cursor, ta.font, wrap_w, mode, 0, measurer);
    var cx = ox + caret.x;
    const cy = oy + caret.y;
    const ime_drawn = transient.ime_active and transient.ime_text.len > 0;
    if (ime_drawn) {
        const m = measurer.measure(transient.ime_text, ta.font);
        emitText(text_draws, alloc, transient.ime_text, ta.font, st.fg, .{ .x = cx, .y = cy, .w = m.width, .h = lh }, clip);
        emit(verts, alloc, .{ .x = cx, .y = cy + lh - 1, .w = m.width, .h = 1 }, st.cursor, clip);
        cx += measurer.prefixWidth(transient.ime_text, ta.font, transient.ime_cursor);
    }
    if (((transient.frame_counter / 30) & 1) == 0) {
        emit(verts, alloc, .{ .x = cx, .y = cy, .w = CURSOR_WIDTH, .h = lh }, st.cursor, clip);
    }
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
    scene_items: *std.ArrayList(SceneItem),
    scene_sprites: *std.ArrayList(SceneSprite),
    alloc: std.mem.Allocator,
    cmds: anytype,
    rects: []const Rect,
    transient: TransientState,
    measurer: TextMeasurer,
) OverlaySplit {
    verts.clearRetainingCapacity();
    text_draws.clearRetainingCapacity();
    image_draws.clearRetainingCapacity();
    scene_draws.clearRetainingCapacity();
    scene_items.clearRetainingCapacity();
    scene_sprites.clearRetainingCapacity();

    buildLayer(verts, text_draws, image_draws, scene_draws, scene_items, scene_sprites, alloc, cmds, rects, transient, measurer, .base);
    const split: OverlaySplit = .{
        .verts = @intCast(verts.items.len),
        .text = @intCast(text_draws.items.len),
        .images = @intCast(image_draws.items.len),
        .scenes = @intCast(scene_draws.items.len),
    };
    buildLayer(verts, text_draws, image_draws, scene_draws, scene_items, scene_sprites, alloc, cmds, rects, transient, measurer, .overlay);
    return split;
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
    var items: std.ArrayList(SceneItem) = .empty;
    defer items.deinit(alloc);
    var sprites: std.ArrayList(SceneSprite) = .empty;
    defer sprites.deinit(alloc);
    _ = buildFrame(verts, text_draws, image_draws, &scenes, &items, &sprites, alloc, cmds, rects, transient, measurer);
}

const Layer = enum { base, overlay };

fn buildLayer(
    verts: *std.ArrayList(Vertex),
    text_draws: *std.ArrayList(TextDraw),
    image_draws: *std.ArrayList(ImageDraw),
    scene_draws: *std.ArrayList(SceneDraw),
    scene_items: *std.ArrayList(SceneItem),
    scene_sprites: *std.ArrayList(SceneSprite),
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
        // Keyboard focus ring: a frame just OUTSIDE the widget, drawn before it
        // (nothing of the widget covers it). One look in retro and modern.
        if (visible and transient.nav_index != null and transient.nav_index.? == i) {
            const w = transient.ring_width;
            const outer = Rect{ .x = rect.x - w, .y = rect.y - w, .w = rect.w + 2 * w, .h = rect.h + 2 * w };
            const radius = switch (c) {
                .button => |b| b.style.radius,
                else => cmd_types.Radii{},
            };
            const grown = cmd_types.Radii{ .tl = if (radius.tl > 0) radius.tl + w else 0, .tr = if (radius.tr > 0) radius.tr + w else 0, .br = if (radius.br > 0) radius.br + w else 0, .bl = if (radius.bl > 0) radius.bl + w else 0 };
            if (!emitSurface(verts, alloc, outer, grown, null, null, transient.ring_color, w, null, cur_clip)) {
                emitBorder(verts, alloc, outer, w, transient.ring_color, cur_clip);
            }
        }
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
                    if (!emitSurface(verts, alloc, rect, ov.radius, if (ov.backdrop[3] > 0) ov.backdrop else null, null, ov.border, ov.border_width, ov.soft_shadow, cur_clip)) {
                        if (ov.backdrop[3] > 0) emit(verts, alloc, rect, ov.backdrop, cur_clip);
                        if (ov.border) |bc| emitBorder(verts, alloc, rect, ov.border_width, bc, cur_clip);
                    }
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
                    if (!emitSurface(verts, alloc, rect, grp.radius, grp.bg, grp.gradient, grp.border, grp.border_width, grp.soft_shadow, cur_clip)) {
                        if (grp.bg) |bg| emit(verts, alloc, rect, bg, cur_clip);
                        if (grp.border) |bc| emitBorder(verts, alloc, rect, grp.border_width, bc, cur_clip);
                    }
                }
            },
            .pop_group, .push_virtual_list, .pop_virtual_list => {},
            .text => |txt| {
                if (!visible) continue;
                if (txt.wrap == .none) {
                    if (bidi_text.mayBeRtl(txt.content) and std.mem.indexOfScalar(u8, txt.content, '\n') == null) {
                        var sc: bidi_text.Scratch = .{};
                        if (bidi_text.layoutLine(txt.content, 0, txt.content.len, txt.font, measurer, std.math.inf(f32), &sc)) |lay| {
                            const bx = switch (txt.text_align) {
                                .start => if (lay.para_rtl) rect.x + rect.w - lay.width else rect.x,
                                .center => rect.x + (rect.w - lay.width) * 0.5,
                                .end => rect.x + rect.w - lay.width,
                            };
                            emitBidiRuns(text_draws, alloc, &lay, bx, rect.y, rect.h, txt.color, cur_clip);
                            continue;
                        }
                    }
                    emitText(text_draws, alloc, txt.content, txt.font, txt.color, rect, cur_clip);
                } else {
                    emitWrapped(text_draws, alloc, txt, rect, cur_clip, measurer);
                }
            },
            .rich_text => |rt| {
                if (!visible) continue;
                if (rt.wrap != .none) {
                    emitRichWrapped(text_draws, alloc, rt, rect, cur_clip, measurer);
                    continue;
                }
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
                    const end = @min(sp.end, std.math.lossyCast(u32, rt.content.len));
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
                const item_first: u32 = @intCast(scene_items.items.len);
                const sprite_first: u32 = @intCast(scene_sprites.items.len);
                for (sc.view.sprites) |sp| {
                    if (!sp.flags.hidden) scene_sprites.append(alloc, sp) catch {};
                }
                for (sc.view.items) |it| {
                    if (!it.flags.hidden) scene_items.append(alloc, it) catch {};
                }
                scene_draws.append(alloc, .{
                    .mesh = sc.mesh,
                    .item_first = item_first,
                    .item_count = @as(u32, @intCast(scene_items.items.len)) - item_first,
                    .sprite_first = sprite_first,
                    .sprite_count = @as(u32, @intCast(scene_sprites.items.len)) - sprite_first,
                    .planes = sc.view.planes,
                    .grid = sc.view.grid,
                    .gizmo = sc.view.gizmo,
                    .cut = sc.view.cut,
                    .material = sc.view.material,
                    .highlight_color = sc.view.highlight_color,
                    .highlight_mix = sc.view.highlight_mix,
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
                var idle = false;
                if (!btn.disabled) {
                    const pressed = if (transient.press_index) |pi| pi == i else false;
                    const hovered = if (transient.hover_index) |hi| hi == i else false;
                    idle = !pressed and !hovered;
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
                // Rounded / gradient / shadowed buttons are one SDF quad; the
                // gradient is the idle look, a raised shadow is dropped while
                // pressed or disabled.
                const raised = idle or (!btn.disabled and (if (transient.hover_index) |hi| hi == i else false));
                const sdf_drawn = emitSurface(verts, alloc, rect, btn.style.radius, bg, if (idle) btn.style.gradient else null, btn.style.border, btn.style.border_width, if (raised) btn.style.soft_shadow else null, cur_clip);
                if (!sdf_drawn) {
                    emit(verts, alloc, rect, bg, cur_clip);
                    if (btn.style.border) |bc| emitBorder(verts, alloc, rect, btn.style.border_width, bc, cur_clip);
                }

                if (btn.label.len > 0) {
                    const m = measurer.measure(btn.label, btn.font);
                    const avail = @max(0, rect.w - 2 * btn.style.h_padding);
                    if (btn.style.ellipsis and m.width > avail) {
                        // Cut at the pixel with U+2026, like `wrap = .ellipsis` text (two draws, no allocation).
                        var it = text_wrap.LineIter.init(btn.label, btn.font, avail, .ellipsis, 1, measurer);
                        const line = it.next() orelse continue;
                        const ew = measurer.measure(text_wrap.ELLIPSIS, btn.font).width;
                        const kept_w = @max(0, line.width - ew);
                        const y = rect.y + @max(0, (rect.h - m.height) * 0.5) + label_dy;
                        const x = rect.x + btn.style.h_padding;
                        emitText(text_draws, alloc, btn.label[line.start..line.end], btn.font, fg, .{ .x = x, .y = y, .w = kept_w, .h = m.height }, cur_clip);
                        emitText(text_draws, alloc, text_wrap.ELLIPSIS, btn.font, fg, .{ .x = x + kept_w, .y = y, .w = ew, .h = m.height }, cur_clip);
                        continue;
                    }
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
                    if (btn.underline) |at| if (at < btn.label.len and label_w >= m.width) {
                        // One glyph's width under the mnemonic letter, just below the baseline.
                        const before = measurer.measure(btn.label[0..at], btn.font).width;
                        const glyph = measurer.measure(btn.label[at .. at + 1], btn.font).width;
                        emit(verts, alloc, .{
                            .x = label_rect.x + before,
                            .y = label_rect.y + m.ascent + 2,
                            .w = glyph,
                            .h = 1,
                        }, fg, cur_clip);
                    };
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
                    const input_bg = if (ti.disabled) ti.style.disabled_bg else ti.style.bg;
                    inner = insetRect(rect, ti.style.border_width);
                    if (!emitSurface(verts, alloc, rect, ti.style.radius, input_bg, null, border_color, ti.style.border_width, null, cur_clip)) {
                        emit(verts, alloc, rect, border_color, cur_clip);
                        emit(verts, alloc, inner, input_bg, cur_clip);
                    }
                }

                // Selection highlight before the text so text draws on top.
                // Disabled inputs never draw selection.
                var ti_scratch: bidi_text.Scratch = .{};
                const ti_lay: ?bidi_text.Layout = if (bidi_text.mayBeRtl(ti.content) and std.mem.indexOfScalar(u8, ti.content, '\n') == null)
                    bidi_text.layoutLine(ti.content, 0, ti.content.len, ti.font, measurer, std.math.inf(f32), &ti_scratch)
                else
                    null;
                if (!ti.disabled) {
                    if (ti.selection_anchor) |anchor| {
                        if (anchor != ti.cursor and ti.content.len > 0 and ti_lay != null) {
                            var spans: [8]bidi_text.Span = undefined;
                            for (ti_lay.?.selection(@min(anchor, ti.cursor), @max(anchor, ti.cursor), &spans)) |sp| {
                                emit(verts, alloc, .{ .x = inner.x + pad_x + sp.x0, .y = inner.y + pad_y, .w = sp.x1 - sp.x0, .h = @max(0, inner.h - 2 * pad_y) }, ti.style.selection_bg, cur_clip);
                            }
                        } else if (anchor != ti.cursor and ti.content.len > 0) {
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
                    if (ti_lay) |*l| {
                        emitBidiRuns(text_draws, alloc, l, text_rect.x, text_rect.y, text_rect.h, text_color, cur_clip);
                    } else {
                        emitText(text_draws, alloc, ti.content, ti.font, text_color, text_rect, cur_clip);
                    }
                }

                // IME composition: when the focused input has an active
                // pre-commit string, draw it inline at the caret with an
                // underline indicator. The composition lives in
                // TransientState (mirror of Host.imeState()) and never
                // enters Model — commit fires WM_CHAR which flows through
                // the normal text-input update path.
                const ime_drawn = focused and transient.ime_active and transient.ime_text.len > 0;
                if (ime_drawn) {
                    const prefix_w = if (ti_lay) |l| l.caretX(ti.cursor) else measurer.prefixWidth(ti.content, ti.font, ti.cursor);
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

                // Blinking cursor when focused (phase from the run loop's
                // Host-clock `blink_on`, default 500 ms on / 500 ms off).
                // While IME composition is active the caret moves to the
                // end of the composition string so the user sees where
                // the next codepoint will commit.
                if (focused and transient.blink_on) {
                    const base_prefix = if (ti_lay) |l| l.caretX(ti.cursor) else measurer.prefixWidth(ti.content, ti.font, ti.cursor);
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
            .text_area => |ta| {
                if (!visible) continue;
                const focused = !ta.disabled and (if (transient.focus_index) |fi| fi == i else false);
                emitTextArea(verts, text_draws, alloc, ta, rect, cur_clip, transient, measurer, focused);
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
                    if (prim == .text) {
                        const t = prim.text;
                        const m = measurer.measure(t.content, t.font);
                        emitText(text_draws, alloc, t.content, t.font, t.color, .{ .x = rect.x + t.x, .y = rect.y + t.y, .w = m.width, .h = m.height }, canvas_clip);
                    } else emitCanvasPrimitive(verts, alloc, rect, prim, canvas_clip);
                }
            },
        }
    }
}

// ── Tests ──────────────────────────────────────────────────────────

// Chrome (border / shadow / hover / underline) tests live in their own file.
test {
    _ = sdf;
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

test "buildVertices: an underlined button label adds one thin quad under that glyph" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0 });
    cb.buttonStyledUnderlined(.a, "File", cb.theme.button, 0);
    cb.buttonStyledUnderlined(.a, "Edit", cb.theme.button, null);
    cb.buttonStyledUnderlined(.a, "Save", cb.theme.button, 9); // out of range: nothing drawn
    cb.popGroup();
    var rects: [8]Rect = undefined;
    const n = cb.cmds.items.len;
    layout.LayoutEngine.doLayout(rects[0..n], cb.cmds.items, 400, 300, text_mod.monoMeasurer());

    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(testing.allocator);
    var text_draws = newTextDraws(testing.allocator);
    defer text_draws.deinit(testing.allocator);
    var image_draws: std.ArrayList(ImageDraw) = .empty;
    defer image_draws.deinit(testing.allocator);
    buildVertices(&verts, &text_draws, &image_draws, testing.allocator, cb.cmds.items, rects[0..n], .{}, text_mod.monoMeasurer());
    // three button bgs (3 quads) + one underline quad
    try testing.expectEqual(@as(usize, 4 * 6), verts.items.len);
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

    // Focused, blink-on frame.
    buildVertices(&verts, &text_draws, &image_draws, testing.allocator, cb.cmds.items, rects[0..cb.cmds.items.len], .{
        .focus_index = 1,
        .blink_on = true,
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
    items: std.ArrayList(SceneItem) = .empty,
    sprites: std.ArrayList(SceneSprite) = .empty,
    split: OverlaySplit = .{},

    fn deinit(self: *TestFrame, alloc: std.mem.Allocator) void {
        self.verts.deinit(alloc);
        self.texts.deinit(alloc);
        self.images.deinit(alloc);
        self.scenes.deinit(alloc);
        self.items.deinit(alloc);
        self.sprites.deinit(alloc);
    }
};

/// Lay out `cb` in a 1000x1000 window and build its frame.
fn buildTestFrame(alloc: std.mem.Allocator, cb: anytype) !TestFrame {
    const rects = try alloc.alloc(Rect, cb.cmds.items.len);
    defer alloc.free(rects);
    layout.LayoutEngine.doLayout(rects, cb.cmds.items, 1000, 1000, text_mod.monoMeasurer());
    var f: TestFrame = .{};
    f.split = buildFrame(&f.verts, &f.texts, &f.images, &f.scenes, &f.items, &f.sprites, alloc, cb.cmds.items, rects, .{}, text_mod.monoMeasurer());
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

test "viewport3d items are flattened per scene with their range; hidden items are dropped" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    const first = [_]SceneItem{ .{ .mesh = 1, .id = 1 }, .{ .mesh = 2, .id = 2, .flags = .{ .hidden = true } }, .{ .mesh = 1, .id = 3 } };
    const second = [_]SceneItem{.{ .mesh = 4, .id = 9 }};
    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    cb.viewport3d(.{ .style = .{ .width = 100, .height = 50 }, .view = .{ .items = &first, .grid = .{}, .material = .flat } });
    cb.viewport3d(.{ .style = .{ .width = 100, .height = 50 }, .view = .{ .items = &second, .cut = .{ .plane = .{ 0, 1, 0, 2 } } } });
    cb.scene3d(.{ .style = .{ .width = 100, .height = 50 }, .mesh = 5 }); // legacy single mesh
    cb.popGroup();

    var f = try buildTestFrame(testing.allocator, &cb);
    defer f.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), f.scenes.items.len);
    try testing.expectEqual(@as(usize, 3), f.items.items.len);
    const a = f.scenes.items[0];
    try testing.expectEqual(@as(u32, 0), a.item_first);
    try testing.expectEqual(@as(u32, 2), a.item_count);
    try testing.expect(a.grid != null and a.material == .flat and a.cut == null);
    try testing.expectEqual(@as(u32, 3), f.items.items[1].id); // hidden id 2 skipped
    const b = f.scenes.items[1];
    try testing.expectEqual(@as(u32, 2), b.item_first);
    try testing.expectEqual(@as(u32, 1), b.item_count);
    try testing.expect(b.cut != null);
    const legacy = f.scenes.items[2];
    try testing.expectEqual(@as(u32, 0), legacy.item_count);
    try testing.expectEqual(@as(u32, 5), legacy.mesh);
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

test "buildFrame reports where the overlay layer starts in every list" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .bg = .{ 0.1, 0.1, 0.1, 1 } }); // 1 base quad
    cb.text("base"); // 1 base text
    cb.scene3d(.{ .mesh = 1 }); // 1 base scene
    cb.pushOverlay(.{ .x = 10, .y = 10, .width = 100, .height = 60, .backdrop = .{ 1, 1, 1, 1 } }); // overlay panel quad
    cb.text("over");
    cb.text("over2");
    cb.scene3d(.{ .mesh = 2 });
    cb.popOverlay();
    cb.popGroup();

    var f = try buildTestFrame(testing.allocator, &cb);
    defer f.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 6), f.split.verts); // base group bg = 1 quad
    try testing.expectEqual(@as(u32, 1), f.split.text);
    try testing.expectEqual(@as(u32, 0), f.split.images);
    try testing.expectEqual(@as(u32, 1), f.split.scenes);
    // Everything after the split is overlay content.
    try testing.expectEqual(@as(usize, 3), f.texts.items.len);
    try testing.expectEqualStrings("over", f.texts.items[f.split.text].content);
    try testing.expectEqual(@as(usize, 2), f.scenes.items.len);
    try testing.expectEqual(@as(u32, 2), f.scenes.items[f.split.scenes].mesh);
    try testing.expect(f.verts.items.len > f.split.verts);
}

test "buildFrame without an overlay splits at the end of every list" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{});
    cb.text("only base");
    cb.popGroup();
    var f = try buildTestFrame(testing.allocator, &cb);
    defer f.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, @intCast(f.verts.items.len)), f.split.verts);
    try testing.expectEqual(@as(u32, 1), f.split.text);
}

fn renderTexts(comptime Msg: type, cb: *cmd_mod.CmdBuffer(Msg), rects: []Rect, w: f32, h: f32, draws: *std.ArrayList(TextDraw)) !void {
    const testing = std.testing;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, w, h, text_mod.monoMeasurer());
    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(testing.allocator);
    var image_draws: std.ArrayList(ImageDraw) = .empty;
    defer image_draws.deinit(testing.allocator);
    draws.clearRetainingCapacity();
    buildVertices(&verts, draws, &image_draws, testing.allocator, cb.cmds.items, rects[0..cb.cmds.items.len], .{}, text_mod.monoMeasurer());
}

test "wrapped text emits one TextDraw per line, stacked at the line height" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0, .align_cross = .stretch });
    cb.paragraph("hello world foo bar");
    cb.popGroup();
    var rects: [4]Rect = undefined;
    var draws: std.ArrayList(TextDraw) = .empty;
    defer draws.deinit(testing.allocator);
    try renderTexts(Msg, &cb, &rects, 100, 200, &draws);
    try testing.expectEqual(@as(usize, 3), draws.items.len);
    try testing.expectEqualStrings("hello", draws.items[0].content);
    try testing.expectEqualStrings("world foo", draws.items[1].content);
    try testing.expectEqualStrings("bar", draws.items[2].content);
    try testing.expectEqual(@as(f32, 20), draws.items[1].rect_y);
    try testing.expectEqual(@as(f32, 40), draws.items[2].rect_y);
}

test "ellipsis and max_lines draw U+2026; center alignment offsets each line" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0, .align_cross = .stretch });
    cb.textEllipsis("one two three four five");
    cb.paragraphStyled("aa bb cc dd ee ff gg hh", cb.theme.typography.body, cb.theme.text_color, .{ .max_lines = 2, .text_align = .center });
    cb.popGroup();
    var rects: [8]Rect = undefined;
    var draws: std.ArrayList(TextDraw) = .empty;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 100, 200, text_mod.monoMeasurer());
    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(testing.allocator);
    var image_draws: std.ArrayList(ImageDraw) = .empty;
    defer image_draws.deinit(testing.allocator);
    buildVertices(&verts, &draws, &image_draws, arena.allocator(), cb.cmds.items, rects[0..cb.cmds.items.len], .{}, text_mod.monoMeasurer());
    try testing.expectEqualStrings("one two", draws.items[0].content);
    try testing.expectEqualStrings("\u{2026}", draws.items[1].content);
    try testing.expectEqual(@as(f32, 70), draws.items[1].rect_x); // right after the kept text
    try testing.expectEqualStrings("aa bb cc", draws.items[2].content);
    // Centered: line width 80 in a 100-wide rect.
    try testing.expectEqual(@as(f32, 10), draws.items[2].rect_x);
    try testing.expectEqualStrings("dd ee f", draws.items[3].content);
    try testing.expectEqualStrings("\u{2026}", draws.items[4].content);
}

test "layout height equals the rendered line count for random strings and widths" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var prng = std.Random.DefaultPrng.init(0xBEEF);
    const rnd = prng.random();
    const words = [_][]const u8{ "a", "bb", "ccc", "dddd", "eeeee", "ffffff", "supercalifragilistic", "日本", "。", "-", "x-y", "e\u{0301}e\u{0301}" };
    var buf: [256]u8 = undefined;
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    var rects: [4]Rect = undefined;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var iter: usize = 0;
    while (iter < 1000) : (iter += 1) {
        var n: usize = 0;
        for (0..1 + rnd.uintLessThan(usize, 12)) |_| {
            const w = words[rnd.uintLessThan(usize, words.len)];
            if (n + w.len + 1 > buf.len) break;
            @memcpy(buf[n..][0..w.len], w);
            n += w.len;
            if (rnd.boolean()) {
                buf[n] = ' ';
                n += 1;
            }
        }
        const width: f32 = @floatFromInt(20 + rnd.uintLessThan(u32, 300));
        const max_lines: u16 = @intCast(rnd.uintLessThan(u32, 4));
        const mode: cmd_mod.Wrap = if (rnd.uintLessThan(u8, 5) == 0) .char else .word;
        cb.reset();
        cb.pushGroup(.{ .padding = 0, .gap = 0, .align_cross = .stretch });
        cb.paragraphStyled(buf[0..n], cb.theme.typography.body, cb.theme.text_color, .{ .wrap = mode, .max_lines = max_lines });
        cb.popGroup();
        _ = arena.reset(.retain_capacity);
        var draws: std.ArrayList(TextDraw) = .empty;
        layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, width, 2000, text_mod.monoMeasurer());
        var verts: std.ArrayList(Vertex) = .empty;
        var image_draws: std.ArrayList(ImageDraw) = .empty;
        buildVertices(&verts, &draws, &image_draws, arena.allocator(), cb.cmds.items, rects[0..cb.cmds.items.len], .{}, text_mod.monoMeasurer());
        var drawn_lines: f32 = 0;
        var last_y: f32 = -1;
        for (draws.items) |d| {
            if (d.rect_y != last_y) drawn_lines += 1;
            last_y = d.rect_y;
        }
        testing.expectEqual(rects[1].h, drawn_lines * 20) catch |e| {
            std.debug.print("text='{s}' w={d} mode={s} max_lines={d}\n", .{ buf[0..n], width, @tagName(mode), max_lines });
            var it = text_wrap.LineIter.init(buf[0..n], cb.theme.typography.body, rects[1].w, mode, max_lines, text_mod.monoMeasurer());
            while (it.next()) |l| std.debug.print("  line {d}..{d} hang {d} next {d}\n", .{ l.start, l.end, l.hang, l.next });
            return e;
        };
    }
}

test "text_area: multi-line selection quads, per-line text, scroll culling, caret" {
    const testing = std.testing;
    const Msg = union(enum) { focus };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    const sel: [4]f32 = .{ 0.2, 0.4, 0.9, 0.5 };
    var style = cb.theme.text_input;
    style.selection_bg = sel;
    // Inner box: border 2 + padding 6 -> 184 wide = 18 chars; 5 rows of 20 px.
    const content = "aaaa bbbb cccc dddd eeee ffff gggg"; // wraps to 3 lines
    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    cb.textArea(.{ .focus_msg = .focus, .id = 1, .content = content, .cursor = 24, .selection_anchor = 7, .style = style, .width = 200, .height = 116 });
    cb.popGroup();
    var rects: [4]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 400, 300, text_mod.monoMeasurer());

    var ts: TransientState = .{};
    ts.focus_index = 1;
    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(testing.allocator);
    var text_draws: std.ArrayList(TextDraw) = .empty;
    defer text_draws.deinit(testing.allocator);
    var image_draws: std.ArrayList(ImageDraw) = .empty;
    defer image_draws.deinit(testing.allocator);
    var scenes: std.ArrayList(SceneDraw) = .empty;
    defer scenes.deinit(testing.allocator);
    var items: std.ArrayList(SceneItem) = .empty;
    defer items.deinit(testing.allocator);
    var sprites: std.ArrayList(SceneSprite) = .empty;
    defer sprites.deinit(testing.allocator);
    _ = buildFrame(&verts, &text_draws, &image_draws, &scenes, &items, &sprites, testing.allocator, cb.cmds.items, rects[0..cb.cmds.items.len], ts, text_mod.monoMeasurer());

    // Three wrapped lines of text.
    try testing.expectEqual(@as(usize, 3), text_draws.items.len);
    try testing.expectEqualStrings("aaaa bbbb cccc", text_draws.items[0].content);
    try testing.expectEqualStrings("dddd eeee ffff", text_draws.items[1].content);
    try testing.expectEqualStrings("gggg", text_draws.items[2].content);
    // Selection [7, 24) covers the tail of line 0, all of line 1 and nothing of line 2: two quads.
    var sel_quads: usize = 0;
    var i: usize = 0;
    while (i + 6 <= verts.items.len) : (i += 6) {
        const v = verts.items[i];
        if (v.r == sel[0] and v.g == sel[1] and v.b == sel[2] and v.a == sel[3]) sel_quads += 1;
    }
    try testing.expectEqual(@as(usize, 2), sel_quads);
    // Selection quads sit on rows 0 and 1 (origin y = 8).
    try testing.expectEqual(@as(f32, 8), text_draws.items[0].rect_y);
    try testing.expectEqual(@as(f32, 28), text_draws.items[1].rect_y);
}

test "text_area: scrolled content culls lines above the viewport" {
    const testing = std.testing;
    const Msg = union(enum) { focus };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    cb.textArea(.{ .focus_msg = .focus, .id = 1, .content = "1\n2\n3\n4\n5\n6\n7\n8", .scroll_y = 60, .width = 200, .height = 56 });
    cb.popGroup();
    var rects: [4]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 400, 300, text_mod.monoMeasurer());
    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(testing.allocator);
    var text_draws: std.ArrayList(TextDraw) = .empty;
    defer text_draws.deinit(testing.allocator);
    var image_draws: std.ArrayList(ImageDraw) = .empty;
    defer image_draws.deinit(testing.allocator);
    buildVertices(&verts, &text_draws, &image_draws, testing.allocator, cb.cmds.items, rects[0..cb.cmds.items.len], .{}, text_mod.monoMeasurer());
    // Inner height 40: rows 4..5 are visible (scroll 60 = 3 lines), lines 1-3 above are culled.
    try testing.expectEqual(@as(usize, 2), text_draws.items.len);
    try testing.expectEqualStrings("4", text_draws.items[0].content);
    try testing.expectEqualStrings("5", text_draws.items[1].content);
}

test "text_area: a right-to-left paragraph draws its runs in visual order, right-aligned" {
    const testing = std.testing;
    const Msg = union(enum) { focus };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    // Logical: Hebrew1 " abc " Hebrew2 -- RTL paragraph, so Hebrew2 is leftmost.
    const content = "\u{5d0}\u{5d1} abc \u{5d3}\u{5d4}";
    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    cb.textArea(.{ .focus_msg = .focus, .id = 1, .content = content, .width = 300, .height = 60 });
    cb.popGroup();
    var rects: [4]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 400, 300, text_mod.monoMeasurer());
    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(testing.allocator);
    var text_draws: std.ArrayList(TextDraw) = .empty;
    defer text_draws.deinit(testing.allocator);
    var image_draws: std.ArrayList(ImageDraw) = .empty;
    defer image_draws.deinit(testing.allocator);
    var scenes: std.ArrayList(SceneDraw) = .empty;
    defer scenes.deinit(testing.allocator);
    var items: std.ArrayList(SceneItem) = .empty;
    defer items.deinit(testing.allocator);
    var sprites: std.ArrayList(SceneSprite) = .empty;
    defer sprites.deinit(testing.allocator);
    _ = buildFrame(&verts, &text_draws, &image_draws, &scenes, &items, &sprites, testing.allocator, cb.cmds.items, rects[0..cb.cmds.items.len], .{}, text_mod.monoMeasurer());
    const d = text_draws.items;
    try testing.expectEqual(@as(usize, 3), d.len);
    try testing.expectEqualStrings(" \u{5d3}\u{5d4}", d[0].content);
    try testing.expect(d[0].font.rtl);
    try testing.expectEqualStrings("abc", d[1].content);
    try testing.expect(!d[1].font.rtl);
    try testing.expectEqualStrings("\u{5d0}\u{5d1} ", d[2].content);
    try testing.expect(d[2].font.rtl);
    try testing.expect(d[0].rect_x < d[1].rect_x and d[1].rect_x < d[2].rect_x);
    // Right-aligned inside the 300 px box (inner right edge = 400 - 2 - 6 ... of the area).
    const right = d[2].rect_x + d[2].rect_w;
    try testing.expectApproxEqAbs(rects[1].x + rects[1].w - 8, right, 0.5);
}

test "text_area: mixed-direction selection becomes per-run highlight rects" {
    const testing = std.testing;
    const Msg = union(enum) { focus };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    const sel: [4]f32 = .{ 0.2, 0.4, 0.9, 0.5 };
    var style = cb.theme.text_input;
    style.selection_bg = sel;
    // LTR paragraph; select from inside the Latin run into the Hebrew run.
    const content = "abcd \u{5d0}\u{5d1}\u{5d2}\u{5d3} efgh";
    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    cb.textArea(.{ .focus_msg = .focus, .id = 1, .content = content, .cursor = 5 + 4, .selection_anchor = 2, .style = style, .width = 400, .height = 60 });
    cb.popGroup();
    var rects: [4]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 500, 300, text_mod.monoMeasurer());
    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(testing.allocator);
    var text_draws: std.ArrayList(TextDraw) = .empty;
    defer text_draws.deinit(testing.allocator);
    var image_draws: std.ArrayList(ImageDraw) = .empty;
    defer image_draws.deinit(testing.allocator);
    var scenes: std.ArrayList(SceneDraw) = .empty;
    defer scenes.deinit(testing.allocator);
    var ts: TransientState = .{};
    ts.focus_index = 1;
    var items: std.ArrayList(SceneItem) = .empty;
    defer items.deinit(testing.allocator);
    var sprites: std.ArrayList(SceneSprite) = .empty;
    defer sprites.deinit(testing.allocator);
    _ = buildFrame(&verts, &text_draws, &image_draws, &scenes, &items, &sprites, testing.allocator, cb.cmds.items, rects[0..cb.cmds.items.len], ts, text_mod.monoMeasurer());
    var quads: usize = 0;
    var i: usize = 0;
    while (i + 6 <= verts.items.len) : (i += 6) {
        const v = verts.items[i];
        if (v.r == sel[0] and v.g == sel[1] and v.b == sel[2] and v.a == sel[3]) quads += 1;
    }
    // Logically contiguous, visually split: "cd " at the left, then alef+bet at
    // the RIGHT end of the Hebrew run (gimel, dalet lie between): two rects.
    try testing.expectEqual(@as(usize, 2), quads);
}

test "wrapped rich_text: per-line pieces keep their span font and colour, ellipsis closes the last line" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    const wide: FontSpec = .{ .letter_spacing = 10 };
    const red: [4]f32 = .{ 1, 0, 0, 1 };
    const spans = [_]cmd_mod.RichTextSpan{.{ .start = 3, .end = 7, .font = wide, .color = red }};
    cb.pushGroup(.{ .padding = 0, .gap = 0, .align_cross = .stretch });
    cb.richParagraph("aa bbbb cc dd ee ff gg hh", &spans, .{ .max_lines = 2 });
    cb.popGroup();
    var rects: [4]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 130, 300, text_mod.monoMeasurer());
    var verts: std.ArrayList(Vertex) = .empty;
    defer verts.deinit(testing.allocator);
    var draws: std.ArrayList(TextDraw) = .empty;
    defer draws.deinit(testing.allocator);
    var imgs: std.ArrayList(ImageDraw) = .empty;
    defer imgs.deinit(testing.allocator);
    buildVertices(&verts, &draws, &imgs, testing.allocator, cb.cmds.items, rects[0..cb.cmds.items.len], .{}, text_mod.monoMeasurer());

    // Line 1: "aa " default + "bbbb" wide/red; line 2 is ellipsized.
    try testing.expectEqualStrings("aa ", draws.items[0].content);
    try testing.expectEqualStrings("bbbb", draws.items[1].content);
    try testing.expectEqual(red, draws.items[1].color);
    try testing.expectEqual(@as(f32, 10), draws.items[1].font.letter_spacing);
    try testing.expectEqual(@as(f32, 30), draws.items[1].rect_x); // after "aa " (30 px)
    try testing.expectEqualStrings("cc dd ee", draws.items[2].content[0..8]); // line 2 starts at x = 0
    try testing.expectEqual(@as(f32, 0), draws.items[2].rect_x);
    try testing.expectEqual(@as(f32, 20), draws.items[2].rect_y);
    try testing.expectEqual(@as(f32, 0), draws.items[0].rect_y);
    const last = draws.items[draws.items.len - 1];
    try testing.expectEqualStrings("\u{2026}", last.content);
    try testing.expectEqual(@as(f32, 20), last.rect_y);
}

test "a button with `ellipsis` keeps its width and cuts its label at the pixel" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    var st = cb.theme.button;
    st.min_width = 100; // mono measurer: 10 px per byte; 8 px padding each side -> 84 px for text
    st.h_padding = 8;
    st.ellipsis = true;
    cb.buttonStyled(.a, "a long label here", st);
    cb.buttonStyled(.a, "short", st);
    cb.popGroup();
    var rects: [8]Rect = undefined;
    var draws: std.ArrayList(TextDraw) = .empty;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 400, 200, text_mod.monoMeasurer());
    try testing.expectEqual(@as(f32, 100), rects[1].w); // fixed, though the label is 170 px wide
    try testing.expectEqual(@as(f32, 100), rects[2].w);
    var verts: std.ArrayList(Vertex) = .empty;
    var image_draws: std.ArrayList(ImageDraw) = .empty;
    buildVertices(&verts, &draws, &image_draws, arena.allocator(), cb.cmds.items, rects[0..cb.cmds.items.len], .{}, text_mod.monoMeasurer());
    try testing.expectEqualStrings("a lon", draws.items[0].content); // 5 x 10 + "\u{2026}" (3 bytes = 30 under the mono measurer) = 80 <= 84
    try testing.expectEqualStrings("\u{2026}", draws.items[1].content);
    try testing.expect(draws.items[1].rect_x + draws.items[1].rect_w <= rects[1].x + rects[1].w - st.h_padding + 0.01);
    try testing.expectEqualStrings("short", draws.items[2].content); // fits: drawn plain
}
