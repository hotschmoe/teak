const std = @import("std");
const cmd_mod = @import("../core/cmd.zig");
const layout = @import("../layout/engine.zig");
const text_mod = @import("../core/text.zig");
const Rect = layout.Rect;
const ClipStack = layout.ClipStack;
const clipRect = layout.clipRect;


pub fn HitResult(comptime Msg: type) type {
    return struct {
        /// Cmd index of the hit. Useful for the host to look up the
        /// hit's rect (e.g. slider-drag). For a modal-backdrop hit with
        /// no `backdrop_msg`, this is the `push_overlay` cmd index — the
        /// hit was consumed by the modal but produces no Msg.
        index: usize,
        /// Msg to dispatch through `update`. `null` means the modal
        /// overlay (HARDLINE §2 hatch 5) consumed the click but the app
        /// didn't request a Msg for it (no `backdrop_msg`). Hosts must
        /// still treat the click as "handled" — i.e. NOT fall through
        /// to the base layer — but skip the `update` call. The pattern
        /// is `if (hit) |h| if (h.msg) |m| App.update(&model, m);`.
        msg: ?Msg,
    };
}

fn CmdMsg(comptime Slice: type) type {
    return std.meta.Elem(Slice).MsgT;
}

fn rectContains(r: Rect, px: f32, py: f32) bool {
    return px >= r.x and px <= r.x + r.w and
        py >= r.y and py <= r.y + r.h;
}

/// An interactive leaf as hit-testing sees it. `msg` is the click Msg; it is
/// null for a pointer-only canvas, which still claims the point (so widgets
/// behind it are not hit) but dispatches nothing on click — its input goes
/// through `canvasMsg` instead.
fn Leaf(comptime Msg: type) type {
    return struct { msg: ?Msg };
}

/// The interactive-leaf probe shared by hit-testing and hovering, or null for
/// a non-interactive cmd.
fn interactiveLeaf(c: anytype) ?Leaf(@TypeOf(c).MsgT) {
    return switch (c) {
        .button => |b| if (b.disabled) null else .{ .msg = b.msg },
        .text_input => |t| if (t.disabled) null else .{ .msg = t.focus_msg },
        .text_area => |t| if (t.disabled) null else .{ .msg = t.focus_msg },
        .checkbox => |cb| .{ .msg = cb.msg },
        .radio => |r| .{ .msg = r.msg },
        .slider => |s| .{ .msg = s.grab_msg },
        .canvas => |cv| if (cv.msg != null or cv.pointer) .{ .msg = cv.msg } else null,
        .scene3d => |sc| if (sc.msg != null or sc.pointer) .{ .msg = sc.msg } else null,
        // Exhaustive classification requires new command variants to be handled.
        .push_group,
        .push_grid,
        .pop_group,
        .pop_grid,
        .push_scroll,
        .pop_scroll,
        .push_overlay,
        .pop_overlay,
        .push_virtual_list,
        .pop_virtual_list,
        .text,
        .rich_text,
        .image,
        .divider,
        => null,
    };
}

/// Forward-walk cmds/rects maintaining a scroll-clip stack; keep the
/// *last* hit so painter's order wins (a later draw is on top). Two
/// passes — overlay first, then base — so the overlay layer
/// (HARDLINE §2 escape hatch 5) wins z-order without per-cmd z fields.
/// A backward walk would be simpler for z-order but couldn't honor
/// scroll clips that accumulate top-down.
///
/// `HitResult.msg` is `?Msg`: a `null` msg means a modal overlay
/// consumed the click but the app didn't supply a `backdrop_msg` (or the
/// hit was a pointer-only canvas). The host must NOT fall through to
/// widgets behind the modal in that case — see the doc on `HitResult.msg`.
pub fn hitTest(
    cmds: anytype,
    rects: []const Rect,
    mouse_x: f32,
    mouse_y: f32,
) ?HitResult(CmdMsg(@TypeOf(cmds))) {
    // Modal overlay clicks must not fall through to the base layer.
    if (hitTestLayer(cmds, rects, mouse_x, mouse_y, .overlay)) |h| return h;
    return hitTestLayer(cmds, rects, mouse_x, mouse_y, .base);
}

/// Like hitTest but returns only the cmd index (no msg). Hosts arm their
/// press target on it: a modal backdrop reports the overlay's index, so
/// press and release over it compare equal and its `backdrop_msg` is
/// reachable.
pub fn hoverTest(
    cmds: anytype,
    rects: []const Rect,
    mouse_x: f32,
    mouse_y: f32,
) ?usize {
    return if (hitTest(cmds, rects, mouse_x, mouse_y)) |h| h.index else null;
}

const Layer = enum { base, overlay };

fn hitTestLayer(
    cmds: anytype,
    rects: []const Rect,
    mouse_x: f32,
    mouse_y: f32,
    layer: Layer,
) ?HitResult(CmdMsg(@TypeOf(cmds))) {
    const Msg = CmdMsg(@TypeOf(cmds));
    var clip: ClipStack = .{};
    var overlay_depth: u32 = 0;
    var best: ?HitResult(Msg) = null;

    var modal_index: ?usize = null;
    var modal_msg: ?Msg = null;

    for (cmds, 0..) |c, i| {
        const cur_clip = clip.top();
        const in_overlay = overlay_depth > 0;
        const visible_to_layer = switch (layer) {
            .base => !in_overlay,
            .overlay => in_overlay,
        };
        switch (c) {
            .push_scroll => clip.push(clipRect(rects[i], cur_clip)),
            .pop_scroll => clip.pop(),
            .push_overlay => |ov| {
                overlay_depth += 1;
                clip.push(clipRect(rects[i], cur_clip));
                // A modal outside its parent clip must not claim the click.
                if (layer == .overlay and ov.modal and
                    rectContains(rects[i], mouse_x, mouse_y) and
                    rectContains(cur_clip, mouse_x, mouse_y))
                {
                    modal_index = i;
                    modal_msg = ov.backdrop_msg;
                }
            },
            .pop_overlay => {
                overlay_depth -= 1;
                clip.pop();
            },
            .push_group, .push_grid, .pop_group, .pop_grid, .push_virtual_list, .pop_virtual_list => {},
            .text, .rich_text, .image, .divider, .button, .text_input, .text_area, .checkbox, .radio, .slider, .canvas, .scene3d => if (visible_to_layer) {
                if (interactiveLeaf(c)) |leaf| {
                    if (rectContains(rects[i], mouse_x, mouse_y) and rectContains(cur_clip, mouse_x, mouse_y))
                        best = .{ .index = i, .msg = leaf.msg };
                }
            },
        }
    }
    if (best) |h| return h;
    if (modal_index) |idx| return .{ .index = idx, .msg = modal_msg };
    return null;
}


/// The pointer canvas (`CanvasCmd.pointer`) under the cursor.
pub const PointerTarget = struct {
    /// Cmd index of the canvas.
    index: usize,
    /// Its `CanvasCmd.id`.
    id: u32,
};

/// The pointer canvas a press / hover at (x, y) lands on, or null. Uses the
/// exact `hitTest` rules, so a later widget, an overlay leaf, or a modal
/// backdrop in front of the canvas wins and the canvas gets nothing.
pub fn pointerTarget(cmds: anytype, rects: []const Rect, x: f32, y: f32) ?PointerTarget {
    const hit = hitTest(cmds, rects, x, y) orelse return null;
    return pointerSurface(cmds, hit.index);
}

/// `index` as a pointer target, or null when that cmd is not a pointer canvas.
/// The one place that knows which cmd kinds are pointer surfaces.
pub fn pointerSurface(cmds: anytype, index: usize) ?PointerTarget {
    if (index >= cmds.len) return null;
    return switch (cmds[index]) {
        .canvas => |cv| if (cv.pointer) .{ .index = index, .id = cv.id } else null,
        .scene3d => |sc| if (sc.pointer) .{ .index = index, .id = sc.id } else null,
        .text_area => |ta| if (ta.disabled) null else .{ .index = index, .id = ta.id },
        else => null,
    };
}

/// Where a wheel event at (x, y) goes.
pub const WheelTarget = union(enum) {
    /// A pointer canvas: delivered as a `wheel` `CanvasEvent`.
    canvas: PointerTarget,
    /// An id-bearing scroll region (`ScrollStyle.id != 0`): delivered to `scrollMsg`.
    scroll: struct { index: usize, id: u32 },
};

/// The innermost wheel consumer under (x, y): a pointer canvas or a scroll
/// region with `id != 0`, whichever is last in document order among those
/// containing the point (children follow their container, so last = innermost
/// = topmost). Overlay-layer candidates win over base ones, and a modal
/// overlay under the point blocks everything behind it — the same layering
/// as `hitTest`.
pub fn wheelTarget(cmds: anytype, rects: []const Rect, x: f32, y: f32) ?WheelTarget {
    switch (wheelTargetLayer(cmds, rects, x, y, .overlay)) {
        .target => |t| return t,
        .blocked => return null,
        .none => {},
    }
    return switch (wheelTargetLayer(cmds, rects, x, y, .base)) {
        .target => |t| t,
        .blocked, .none => null,
    };
}

const LayerWheel = union(enum) {
    /// No consumer in this layer; fall through to the next.
    none,
    /// A modal overlay covers the point with no consumer in it: the wheel is
    /// swallowed, nothing behind the modal may scroll.
    blocked,
    target: WheelTarget,
};

fn wheelTargetLayer(cmds: anytype, rects: []const Rect, x: f32, y: f32, layer: Layer) LayerWheel {
    var clip: ClipStack = .{};
    var overlay_depth: u32 = 0;
    var best: ?WheelTarget = null;
    var modal_under_point = false;

    for (cmds, 0..) |c, i| {
        const cur_clip = clip.top();
        const visible = switch (layer) {
            .base => overlay_depth == 0,
            .overlay => overlay_depth > 0,
        };
        const inside = rectContains(rects[i], x, y) and rectContains(cur_clip, x, y);
        switch (c) {
            .push_scroll => |sc| {
                if (visible and sc.id != 0 and inside) best = .{ .scroll = .{ .index = i, .id = sc.id } };
                clip.push(clipRect(rects[i], cur_clip));
            },
            .pop_scroll => clip.pop(),
            .push_overlay => |ov| {
                overlay_depth += 1;
                clip.push(clipRect(rects[i], cur_clip));
                if (layer == .overlay and ov.modal and inside) modal_under_point = true;
            },
            .pop_overlay => {
                overlay_depth -= 1;
                clip.pop();
            },
            .canvas, .scene3d, .text_area => if (visible and inside) {
                if (pointerSurface(cmds, i)) |t| best = .{ .canvas = t };
            },
            .push_group, .push_grid, .pop_group, .pop_grid, .push_virtual_list, .pop_virtual_list => {},
            .text, .rich_text, .image, .divider, .button, .text_input, .checkbox, .radio, .slider => {},
        }
    }
    if (best) |t| return .{ .target = t };
    return if (modal_under_point) .blocked else .none;
}

/// A drag source or drop target found by `dragTargets`.
pub const DragZone = struct {
    /// Cmd index of the `push_group`.
    index: usize,
    /// Its `drag_id` / `drop_id`.
    id: u32,
};

pub const DragHit = struct {
    source: ?DragZone = null,
    target: ?DragZone = null,
};

/// The innermost drag source (`GroupStyle.drag_id != 0`) and innermost drop
/// target (`drop_id != 0`) containing (x, y), with the same layering as
/// `hitTest` / `wheelTarget`: overlay-layer zones win over base ones, and a
/// modal overlay under the point hides everything behind it.
pub fn dragTargets(cmds: anytype, rects: []const Rect, x: f32, y: f32) DragHit {
    switch (dragLayer(cmds, rects, x, y, .overlay)) {
        .hit => |h| return h,
        .blocked => return .{},
        .none => {},
    }
    return switch (dragLayer(cmds, rects, x, y, .base)) {
        .hit => |h| h,
        .blocked, .none => .{},
    };
}

const LayerDrag = union(enum) { none, blocked, hit: DragHit };

fn dragLayer(cmds: anytype, rects: []const Rect, x: f32, y: f32, layer: Layer) LayerDrag {
    var clip: ClipStack = .{};
    var overlay_depth: u32 = 0;
    var best: DragHit = .{};
    var modal_under_point = false;

    for (cmds, 0..) |c, i| {
        const cur_clip = clip.top();
        const visible = switch (layer) {
            .base => overlay_depth == 0,
            .overlay => overlay_depth > 0,
        };
        const inside = rectContains(rects[i], x, y) and rectContains(cur_clip, x, y);
        switch (c) {
            .push_group => |g| if (visible and inside) {
                if (g.drag_id != 0) best.source = .{ .index = i, .id = g.drag_id };
                if (g.drop_id != 0) best.target = .{ .index = i, .id = g.drop_id };
            },
            .push_scroll => clip.push(clipRect(rects[i], cur_clip)),
            .pop_scroll => clip.pop(),
            .push_overlay => |ov| {
                overlay_depth += 1;
                clip.push(clipRect(rects[i], cur_clip));
                if (layer == .overlay and ov.modal and inside) modal_under_point = true;
            },
            .pop_overlay => {
                overlay_depth -= 1;
                clip.pop();
            },
            else => {},
        }
    }
    if (best.source != null or best.target != null) return .{ .hit = best };
    return if (modal_under_point) .blocked else .none;
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

/// Convert a window-space mouse position into canvas-LOCAL coordinates
/// (origin at the canvas rect's top-left), given the canvas's rect.
/// Returns null when the point is outside the rect. Mirrors
/// `sliderValueAt`'s shape: after `hitTest` returns a canvas's click Msg
/// + index, the app reads `rects[index]` and calls this to recover the
/// data coordinate that was clicked (then maps it to its own value-space
/// via a Msg it owns — fn-pointer-free per HARDLINE §3).
pub fn canvasLocalPoint(rect: Rect, mouse_x: f32, mouse_y: f32) ?struct { x: f32, y: f32 } {
    if (!rectContains(rect, mouse_x, mouse_y)) return null;
    return .{ .x = mouse_x - rect.x, .y = mouse_y - rect.y };
}

/// Drag state for a slider currently being held. The host computes this
/// each frame while `press_target` points at a slider; the app reads
/// `.value` and dispatches its own value-carrying Msg (typically a
/// component Msg accepting `f32`) — fn-pointer-free per HARDLINE §3.
pub fn SliderDrag(comptime Msg: type) type {
    return struct {
        /// Cmd index of the slider being dragged. Same index that fed
        /// `grab_msg` to `update` on mousedown.
        index: usize,
        /// The slider's own `grab_msg` — useful when one app handles
        /// multiple sliders: the app dispatches `.value` to a route
        /// derived from `grab_msg` (e.g. by switch on its tag).
        grab_msg: Msg,
        /// Current normalized value in [0, 1] computed from
        /// `mouse_x` and the slider's rect.
        value: f32,
    };
}

/// Combine `press_target` + the previous frame's slider rect into a
/// `SliderDrag` whenever the held widget is a slider. Returns null if
/// nothing is pressed or the pressed widget isn't a slider. The host
/// calls this each frame while the mouse button is held and dispatches
/// the resulting value to a value-carrying Msg the app supplies.
///
/// Closes ergonomic gap 1 — every numeric input no longer rewrites the
/// "fetch rect by index, compute value, build Msg" dance.
pub fn sliderDrag(
    cmds: anytype,
    rects: []const Rect,
    press_target: ?usize,
    mouse_x: f32,
) ?SliderDrag(CmdMsg(@TypeOf(cmds))) {
    const idx = press_target orelse return null;
    if (idx >= cmds.len) return null;
    if (idx >= rects.len) return null;
    const c = cmds[idx];
    return switch (c) {
        .slider => |s| .{
            .index = idx,
            .grab_msg = s.grab_msg,
            .value = sliderValueAt(rects[idx], mouse_x),
        },
        else => null,
    };
}






















fn testLayout(rects: []Rect, cb: anytype, w: f32, h: f32) []const Rect {
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, w, h, text_mod.monoMeasurer());
    return rects[0..cb.cmds.items.len];
}








