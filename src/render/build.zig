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
                const bx = switch (txt.text_align) {
                    .start => if (lay.para_rtl) rect.x + rect.w - line.width else rect.x,
                    else => x,
                };
                emitBidiRuns(text_draws, alloc, &lay, bx, y, lh, txt.color, clip);
                continue;
            }
        }
        if (line.ellipsized) {
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
                    // A zero clip defensively suppresses overlay children in the base pass.
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
                if (visible) {
                    if (!emitSurface(verts, alloc, rect, grp.radius, grp.bg, grp.gradient, grp.border, grp.border_width, grp.soft_shadow, cur_clip)) {
                        if (grp.bg) |bg| emit(verts, alloc, rect, bg, cur_clip);
                        if (grp.border) |bc| emitBorder(verts, alloc, rect, grp.border_width, bc, cur_clip);
                    }
                }
            },
            .push_grid => |grd| if (visible) {
                if (grd.bg) |bg| emit(verts, alloc, rect, bg, cur_clip);
                if (grd.border) |bc| emitBorder(verts, alloc, rect, grd.border_width, bc, cur_clip);
            },
            .pop_group, .pop_grid, .push_virtual_list, .pop_virtual_list => {},
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
                const focused = !ti.disabled and (if (transient.focus_index) |fi| fi == i else false);
                const border_color = if (ti.disabled)
                    ti.style.disabled_border
                else if (focused)
                    ti.style.focus_border
                else
                    ti.style.border;

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
                const canvas_clip = clipRect(rect, cur_clip);
                if (canvas_clip.w <= 0 or canvas_clip.h <= 0) continue;
                if (cv.style.bg) |bg| emit(verts, alloc, rect, bg, cur_clip);
                const xf = cv.style.transform;
                const opts: canvas_tess.Opts = .{ .xf = xf, .aa = cv.style.antialias, .sdf_circles = true };
                for (cv.primitives) |prim| {
                    if (prim == .text) {
                        const t = prim.text;
                        const m = measurer.measure(t.content, t.font);
                        const tx = rect.x + t.x * xf.sx + xf.tx;
                        const ty = rect.y + t.y * xf.sy + xf.ty;
                        emitText(text_draws, alloc, t.content, t.font, t.color, .{ .x = tx, .y = ty, .w = m.width, .h = m.height }, canvas_clip);
                    } else canvas_tess.emitCanvasPrimitiveOpts(verts, alloc, rect, prim, canvas_clip, opts);
                }
            },
        }
    }
}



const cmd_mod = @import("../core/cmd.zig");

fn newTextDraws(alloc: std.mem.Allocator) std.ArrayList(TextDraw) {
    _ = alloc;
    return .empty;
}

















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









