const std = @import("std");
const cmd_mod = @import("../core/cmd.zig");
const layout = @import("../layout/engine.zig");
const text_mod = @import("../core/text.zig");
const Rect = layout.Rect;
const ClipStack = layout.ClipStack;
const clipRect = layout.clipRect;

// ── Hit-Test ───────────────────────────────────────────────────────
//
// Generic over the Cmd slice type. The Msg is recovered from the slice's
// element type via its `MsgT` decl, so callers just pass `cb.cmds.items`.

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
        // Disabled buttons/inputs are non-interactive.
        .button => |b| if (b.disabled) null else .{ .msg = b.msg },
        .text_input => |t| if (t.disabled) null else .{ .msg = t.focus_msg },
        .text_area => |t| if (t.disabled) null else .{ .msg = t.focus_msg },
        .checkbox => |cb| .{ .msg = cb.msg },
        .radio => |r| .{ .msg = r.msg },
        .slider => |s| .{ .msg = s.grab_msg },
        // A canvas is interactive with a click Msg, a pointer surface, or
        // both; otherwise it is a decorative leaf that clicks pass through.
        .canvas => |cv| if (cv.msg != null or cv.pointer) .{ .msg = cv.msg } else null,
        // Same rule for a 3D scene.
        .scene3d => |sc| if (sc.msg != null or sc.pointer) .{ .msg = sc.msg } else null,
        // Containers and decorative leaves: clicks pass through. Listed
        // explicitly (no `else`) so a new Cmd variant must be classified here.
        .push_group,
        .pop_group,
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
    // Overlay layer first (it wins): a hit there short-circuits. A
    // modal overlay containing the mouse but with no interactive leaf
    // returns a "consumed, no Msg" result that *also* short-circuits —
    // the base layer must NOT receive clicks landing on a modal's dim
    // backdrop, regardless of `backdrop_msg`.
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

    // Track the innermost modal overlay containing the mouse during
    // the .overlay pass so we can synthesize a "consumed" hit if no
    // interactive leaf claimed the click. Painter's-order applies: a
    // later modal overlay overrides an earlier one if both contain
    // the point.
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
                // Overlay is its own clip so contents are bounded by
                // the overlay rect (e.g. menu items past the menu's
                // height shouldn't hit-test).
                clip.push(clipRect(rects[i], cur_clip));
                // Note a modal overlay containing the mouse so we can
                // claim the click below even if no leaf catches it.
                // Honor the parent clip too — a modal nested under a
                // scrolled-away parent shouldn't claim.
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
            .push_group, .pop_group, .push_virtual_list, .pop_virtual_list => {},
            .text, .rich_text, .image, .divider, .button, .text_input, .text_area, .checkbox, .radio, .slider, .canvas, .scene3d => if (visible_to_layer) {
                if (interactiveLeaf(c)) |leaf| {
                    if (rectContains(rects[i], mouse_x, mouse_y) and rectContains(cur_clip, mouse_x, mouse_y))
                        best = .{ .index = i, .msg = leaf.msg };
                }
            },
        }
    }
    if (best) |h| return h;
    // No leaf claimed the click. If a modal overlay contained the
    // mouse, consume the click on its behalf so base-layer widgets
    // underneath don't accidentally fire.
    if (modal_index) |idx| return .{ .index = idx, .msg = modal_msg };
    return null;
}

// ── Pointer / wheel targets ────────────────────────────────────────

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
            .push_group, .pop_group, .push_virtual_list, .pop_virtual_list => {},
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
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 400, 300, text_mod.monoMeasurer());

    const hit_inc = hitTest(cb.cmds.items, rects[0..cb.cmds.items.len], 30, 18);
    try testing.expect(hit_inc != null);
    try testing.expectEqual(@as(?Msg, Msg.inc), hit_inc.?.msg);

    const hit_dec = hitTest(cb.cmds.items, rects[0..cb.cmds.items.len], 90, 18);
    try testing.expect(hit_dec != null);
    try testing.expectEqual(@as(?Msg, Msg.dec), hit_dec.?.msg);

    const miss = hitTest(cb.cmds.items, rects[0..cb.cmds.items.len], 300, 250);
    try testing.expect(miss == null);
}

test "hitTest skips a disabled button" {
    const testing = std.testing;
    const Msg = union(enum) { clicked };
    const CmdBuffer = cmd_mod.CmdBuffer(Msg);

    // Enabled button at the center of its rect produces a hit.
    var enabled = CmdBuffer.init(testing.allocator);
    defer enabled.deinit();
    enabled.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    enabled.button(.clicked, "Add");
    enabled.popGroup();
    var en_rects: [4]Rect = undefined;
    layout.LayoutEngine.doLayout(en_rects[0..enabled.cmds.items.len], enabled.cmds.items, 400, 300, text_mod.monoMeasurer());
    // Button is cmd index 1 (after push_group). Hit its center.
    const er = en_rects[1];
    const px = er.x + er.w * 0.5;
    const py = er.y + er.h * 0.5;
    const en_hit = hitTest(enabled.cmds.items, en_rects[0..enabled.cmds.items.len], px, py);
    try testing.expect(en_hit != null);
    try testing.expectEqual(@as(?Msg, Msg.clicked), en_hit.?.msg);

    // Disabled button at the same point produces no hit.
    var disabled = CmdBuffer.init(testing.allocator);
    defer disabled.deinit();
    disabled.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    disabled.buttonDisabled(.clicked, "Add");
    disabled.popGroup();
    var di_rects: [4]Rect = undefined;
    layout.LayoutEngine.doLayout(di_rects[0..disabled.cmds.items.len], disabled.cmds.items, 400, 300, text_mod.monoMeasurer());
    const dr = di_rects[1];
    try testing.expect(hitTest(disabled.cmds.items, di_rects[0..disabled.cmds.items.len], dr.x + dr.w * 0.5, dr.y + dr.h * 0.5) == null);
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
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 800, 600, text_mod.monoMeasurer());

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
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 400, 300, text_mod.monoMeasurer());

    const hit = hitTest(cb.cmds.items, rects[0..cb.cmds.items.len], 100, 20);
    try testing.expect(hit != null);
    try testing.expectEqual(@as(?Msg, Msg.focus), hit.?.msg);
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

test "canvasLocalPoint converts a hit to canvas-local coords, else null" {
    const testing = std.testing;
    const r: Rect = .{ .x = 100, .y = 50, .w = 300, .h = 120 };

    // Inside → local offset from the rect's top-left.
    const p = canvasLocalPoint(r, 130, 80).?;
    try testing.expectEqual(@as(f32, 30), p.x);
    try testing.expectEqual(@as(f32, 30), p.y);

    // Top-left corner maps to (0, 0).
    const corner = canvasLocalPoint(r, 100, 50).?;
    try testing.expectEqual(@as(f32, 0), corner.x);
    try testing.expectEqual(@as(f32, 0), corner.y);

    // Outside → null.
    try testing.expect(canvasLocalPoint(r, 50, 80) == null);
    try testing.expect(canvasLocalPoint(r, 130, 200) == null);
}

test "hitTest: canvas is interactive only with a click msg" {
    const testing = std.testing;
    const Msg = union(enum) { poke };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.canvas(.{ .width = 200, .height = 100 }, &.{}); // index 1 — no msg
    cb.canvasClickable(.poke, .{ .width = 200, .height = 100 }, &.{}, "plot"); // index 2
    cb.popGroup();

    var rects: [8]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 400, 400, text_mod.monoMeasurer());

    // Non-interactive canvas: click passes through (no hit).
    const r1 = rects[1];
    try testing.expect(hitTest(cb.cmds.items, rects[0..cb.cmds.items.len], r1.x + 5, r1.y + 5) == null);

    // Clickable canvas: returns its msg.
    const r2 = rects[2];
    const hit = hitTest(cb.cmds.items, rects[0..cb.cmds.items.len], r2.x + 5, r2.y + 5);
    try testing.expect(hit != null);
    try testing.expectEqual(@as(?Msg, Msg.poke), hit.?.msg);
}

test "hitTest intersects nested scroll clips" {
    const testing = std.testing;
    const Msg = union(enum) { pick };
    const CmdBuffer = cmd_mod.CmdBuffer(Msg);

    var cb = CmdBuffer.init(testing.allocator);
    defer cb.deinit();

    // Outer scroll 80×80, inner scroll 200×200 nested inside. Buttons
    // are 36 tall with gap=0, so they stack at y=0..36, 36..72, 72..108.
    // Button C (y=72..108) straddles the outer clip boundary at y=80 —
    // a point inside its rect but below the outer viewport must miss.
    cb.pushScroll(.{ .direction = .vertical, .padding = 0, .gap = 0, .width = 80, .height = 80 });
    cb.pushScroll(.{ .direction = .vertical, .padding = 0, .gap = 0, .width = 200, .height = 200 });
    cb.button(.pick, "A"); // y ∈ [0, 36]
    cb.button(.pick, "B"); // y ∈ [36, 72]
    cb.button(.pick, "C"); // y ∈ [72, 108] — straddles y=80 outer edge
    cb.popScroll();
    cb.popScroll();

    var rects: [16]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 800, 600, text_mod.monoMeasurer());

    // Sanity: button A is inside both viewports → hit.
    try testing.expect(hitTest(cb.cmds.items, rects[0..cb.cmds.items.len], 10, 10) != null);
    // The actual test: y=90 is inside button C's rect AND the inner
    // viewport (y < 200), but outside the outer viewport (y > 80).
    // Clip intersection wins → miss.
    try testing.expect(hitTest(cb.cmds.items, rects[0..cb.cmds.items.len], 10, 90) == null);
}

test "hitTest: overlay wins over base layer at the same point" {
    const testing = std.testing;
    const Msg = union(enum) { base_click, overlay_click };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.button(.base_click, "Bottom"); // y ∈ [0, 36], x ∈ [0, 60]
    cb.pushOverlay(.{
        .x = 0,
        .y = 0,
        .width = 100,
        .height = 36,
        .padding = 0,
    });
    cb.button(.overlay_click, "Top"); // covers the same pixels
    cb.popOverlay();
    cb.popGroup();

    var rects: [16]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 800, 600, text_mod.monoMeasurer());

    const hit = hitTest(cb.cmds.items, rects[0..cb.cmds.items.len], 30, 18);
    try testing.expect(hit != null);
    try testing.expectEqual(@as(?Msg, Msg.overlay_click), hit.?.msg);
}

test "hitTest: clicking outside the overlay falls through to base layer" {
    const testing = std.testing;
    const Msg = union(enum) { base_click, overlay_click };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.button(.base_click, "Bottom"); // y ∈ [0, 36]
    cb.pushOverlay(.{
        .x = 200,
        .y = 200,
        .width = 100,
        .height = 36,
        .padding = 0,
    });
    cb.button(.overlay_click, "Far");
    cb.popOverlay();
    cb.popGroup();

    var rects: [16]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 800, 600, text_mod.monoMeasurer());

    // Click over the base button only.
    const hit = hitTest(cb.cmds.items, rects[0..cb.cmds.items.len], 30, 18);
    try testing.expect(hit != null);
    try testing.expectEqual(@as(?Msg, Msg.base_click), hit.?.msg);
}

test "sliderDrag returns value when press_target is a slider" {
    const testing = std.testing;
    const Msg = union(enum) { grab_a, grab_b, focus };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.textInput(.focus, "", 0); // index 1
    cb.slider(.grab_a, 0.3); // index 2
    cb.slider(.grab_b, 0.7); // index 3
    cb.popGroup();

    var rects: [16]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 400, 300, text_mod.monoMeasurer());

    // No press → null.
    try testing.expect(sliderDrag(cb.cmds.items, rects[0..cb.cmds.items.len], null, 100) == null);

    // Press on the text input (not a slider) → null.
    try testing.expect(sliderDrag(cb.cmds.items, rects[0..cb.cmds.items.len], 1, 100) == null);

    // Press on slider A, mouse at the middle → value ≈ 0.5, grab_msg = .grab_a.
    const mid_x = rects[2].x + rects[2].w * 0.5;
    const d_a = sliderDrag(cb.cmds.items, rects[0..cb.cmds.items.len], 2, mid_x).?;
    try testing.expectEqual(@as(usize, 2), d_a.index);
    try testing.expectEqual(Msg.grab_a, d_a.grab_msg);
    try testing.expectApproxEqAbs(@as(f32, 0.5), d_a.value, 0.01);

    // Press on slider B, mouse off the left → clamped to 0; grab_msg = .grab_b.
    const d_b = sliderDrag(cb.cmds.items, rects[0..cb.cmds.items.len], 3, rects[3].x - 100).?;
    try testing.expectEqual(@as(usize, 3), d_b.index);
    try testing.expectEqual(Msg.grab_b, d_b.grab_msg);
    try testing.expectEqual(@as(f32, 0), d_b.value);
}

test "sliderDrag: out-of-range press_target returns null" {
    const testing = std.testing;
    const Msg = union(enum) { grab };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = 0 });
    cb.slider(.grab, 0.5);
    cb.popGroup();

    var rects: [4]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 400, 100, text_mod.monoMeasurer());

    // Press index past end of cmds → null, no crash.
    try testing.expect(sliderDrag(cb.cmds.items, rects[0..cb.cmds.items.len], 99, 100) == null);
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
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 400, 300, text_mod.monoMeasurer());

    const cb_hit = hitTest(cb.cmds.items, rects[0..cb.cmds.items.len], rects[1].x + 2, rects[1].y + 2);
    try testing.expectEqual(@as(?Msg, Msg.toggle), cb_hit.?.msg);

    const rd_hit = hitTest(cb.cmds.items, rects[0..cb.cmds.items.len], rects[2].x + 2, rects[2].y + 2);
    try testing.expectEqual(@as(?Msg, Msg.pick), rd_hit.?.msg);

    const sl_hit = hitTest(cb.cmds.items, rects[0..cb.cmds.items.len], rects[3].x + 10, rects[3].y + 10);
    try testing.expectEqual(@as(?Msg, Msg.grab), sl_hit.?.msg);
}

// ── Modal overlay (click-outside-to-close, no fallthrough) ─────────

test "hitTest: modal overlay consumes click on backdrop with no backdrop_msg" {
    const testing = std.testing;
    const Msg = union(enum) { base_click };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    // Base-layer button under where the modal will sit. Without
    // `modal=true`, the click on the empty backdrop area would fall
    // through and fire base_click.
    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.button(.base_click, "Underneath");
    cb.pushOverlay(.{
        .x = 0,
        .y = 0,
        .width = 200,
        .height = 200,
        .padding = 0,
        .modal = true,
        // No backdrop_msg: clicking the dim area should be silently
        // swallowed — neither base_click nor any Msg fires.
    });
    cb.popOverlay();
    cb.popGroup();

    var rects: [16]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 800, 600, text_mod.monoMeasurer());

    // Click inside the modal's rect but on no interactive leaf.
    const hit = hitTest(cb.cmds.items, rects[0..cb.cmds.items.len], 100, 100);
    try testing.expect(hit != null);
    // Consumed-but-actionless: msg is null, index points at the
    // push_overlay cmd so the host can correlate if it wants.
    try testing.expectEqual(@as(?Msg, null), hit.?.msg);
}

test "hitTest: modal overlay with backdrop_msg returns it on backdrop click" {
    const testing = std.testing;
    const Msg = union(enum) { base_click, dismiss };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.button(.base_click, "Underneath");
    cb.pushOverlay(.{
        .x = 0,
        .y = 0,
        .width = 200,
        .height = 200,
        .padding = 0,
        .modal = true,
        .backdrop_msg = .dismiss,
    });
    cb.popOverlay();
    cb.popGroup();

    var rects: [16]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 800, 600, text_mod.monoMeasurer());

    const hit = hitTest(cb.cmds.items, rects[0..cb.cmds.items.len], 100, 100);
    try testing.expect(hit != null);
    try testing.expectEqual(@as(?Msg, Msg.dismiss), hit.?.msg);
}

test "hitTest: leaf inside modal overlay still wins over backdrop_msg" {
    const testing = std.testing;
    const Msg = union(enum) { dismiss, close };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushOverlay(.{
        .x = 0,
        .y = 0,
        .width = 400,
        .height = 200,
        .padding = 16,
        .modal = true,
        .backdrop_msg = .dismiss,
    });
    cb.button(.close, "Close"); // an inner leaf that should win
    cb.popOverlay();

    var rects: [16]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 800, 600, text_mod.monoMeasurer());

    // Click on the close button itself — leaf wins, NOT the backdrop.
    const button_rect = rects[1];
    const hit = hitTest(
        cb.cmds.items,
        rects[0..cb.cmds.items.len],
        button_rect.x + 4,
        button_rect.y + 4,
    );
    try testing.expect(hit != null);
    try testing.expectEqual(@as(?Msg, Msg.close), hit.?.msg);
}

// Regression for the press/release host gate: `hoverTest` must claim
// the modal-backdrop area so `press_target` arms on the overlay's cmd
// index. Otherwise the host's `hover_under_mouse == press_target`
// check fails on mouseup and `hitTest` is never invoked — making the
// modal-fallback path in `hitTest` dead code at runtime even though
// its unit tests pass.
test "hover+hit integration: modal backdrop arms press_target and dispatches backdrop_msg" {
    const testing = std.testing;
    const Msg = union(enum) { base_click, close };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    // Base-layer button that would fire if the modal didn't claim the
    // empty backdrop area. We click in the empty space inside the
    // modal — the base button must NOT be the hover/hit target.
    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.button(.base_click, "Underneath"); // base-layer leaf
    cb.pushOverlay(.{
        .x = 0,
        .y = 0,
        .width = 400,
        .height = 200,
        .padding = 0,
        .modal = true,
        .backdrop_msg = .close,
    });
    // Intentionally no interactive leaf inside the overlay — the click
    // point will land on the dim backdrop, not on any button.
    cb.popOverlay();
    cb.popGroup();

    var rects: [16]Rect = undefined;
    const cmds = cb.cmds.items;
    layout.LayoutEngine.doLayout(rects[0..cmds.len], cmds, 800, 600, text_mod.monoMeasurer());

    // The cmd indices: 0=push_group, 1=button, 2=push_overlay, 3=pop_overlay, 4=pop_group.
    const overlay_idx: usize = 2;
    const click_x: f32 = 200;
    const click_y: f32 = 100;

    // mousedown — host calls hoverTest to arm press_target. Must point
    // at the overlay's cmd index, NOT the base button (index 1) and
    // NOT null.
    const hover_at_press = hoverTest(cmds, rects[0..cmds.len], click_x, click_y);
    try testing.expect(hover_at_press != null);
    try testing.expectEqual(@as(?usize, overlay_idx), hover_at_press);

    // Simulate the host's press_target arming.
    const press_target: ?usize = hover_at_press;

    // mouseup — host calls hoverTest again and gates hitTest on
    // `hover_under_mouse == press_target`. Cursor hasn't moved, so the
    // gate must pass.
    const hover_at_release = hoverTest(cmds, rects[0..cmds.len], click_x, click_y);
    try testing.expect(hover_at_release != null);
    try testing.expectEqual(press_target, hover_at_release);

    // Gate passed → host calls hitTest. The modal-fallback path in
    // hitTestLayer fires and returns the backdrop_msg.
    const hit = hitTest(cmds, rects[0..cmds.len], click_x, click_y);
    try testing.expect(hit != null);
    try testing.expectEqual(overlay_idx, hit.?.index);
    try testing.expectEqual(@as(?Msg, Msg.close), hit.?.msg);
}

test "hitTest: non-modal overlay backdrop click falls through to base" {
    const testing = std.testing;
    const Msg = union(enum) { base_click };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    // Non-modal overlay — its empty area should still let the base
    // button claim the click. This preserves debug-overlay / tooltip /
    // popover semantics where the user must be able to interact with
    // content underneath.
    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.button(.base_click, "Underneath");
    cb.pushOverlay(.{
        .x = 0,
        .y = 0,
        .width = 400,
        .height = 200,
        .padding = 0,
        // modal defaults to false; no backdrop_msg.
    });
    cb.popOverlay();
    cb.popGroup();

    var rects: [16]Rect = undefined;
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, 800, 600, text_mod.monoMeasurer());

    // Click inside the overlay rect but on the base button.
    const button_rect = rects[1];
    const hit = hitTest(
        cb.cmds.items,
        rects[0..cb.cmds.items.len],
        button_rect.x + 4,
        button_rect.y + 4,
    );
    try testing.expect(hit != null);
    try testing.expectEqual(@as(?Msg, Msg.base_click), hit.?.msg);
}

// ── Pointer canvas + wheel target tests ────────────────────────────

fn testLayout(rects: []Rect, cb: anytype, w: f32, h: f32) []const Rect {
    layout.LayoutEngine.doLayout(rects[0..cb.cmds.items.len], cb.cmds.items, w, h, text_mod.monoMeasurer());
    return rects[0..cb.cmds.items.len];
}

test "pointer canvas is a hit-testable leaf with no click msg" {
    const testing = std.testing;
    const Msg = union(enum) { poke };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.canvasInteractive(.{ .width = 200, .height = 100 }, &.{}, 5, "view"); // index 1
    cb.button(.poke, "B"); // index 2, below the canvas
    cb.popGroup();

    var rects: [8]Rect = undefined;
    const rs = testLayout(&rects, &cb, 400, 400);

    const r = rs[1];
    const hit = hitTest(cb.cmds.items, rs, r.x + 5, r.y + 5).?;
    try testing.expectEqual(@as(usize, 1), hit.index);
    try testing.expectEqual(@as(?Msg, null), hit.msg); // claims the point, dispatches nothing
    try testing.expectEqual(@as(?usize, 1), hoverTest(cb.cmds.items, rs, r.x + 5, r.y + 5));

    const t = pointerTarget(cb.cmds.items, rs, r.x + 5, r.y + 5).?;
    try testing.expectEqual(@as(usize, 1), t.index);
    try testing.expectEqual(@as(u32, 5), t.id);

    // The button below is a hit but not a pointer target.
    const b = rs[2];
    try testing.expect(pointerTarget(cb.cmds.items, rs, b.x + 5, b.y + 5) == null);
    try testing.expectEqual(@as(?Msg, Msg.poke), hitTest(cb.cmds.items, rs, b.x + 5, b.y + 5).?.msg);
    // Outside everything: no target.
    try testing.expect(pointerTarget(cb.cmds.items, rs, 390, 390) == null);
}

test "overlay leaf and modal backdrop win over a pointer canvas" {
    const testing = std.testing;
    const Msg = union(enum) { poke, close };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.canvasInteractive(.{ .width = 300, .height = 300 }, &.{}, 1, "");
    cb.popGroup();
    // Non-modal popup with a button overlapping the canvas, then a modal.
    cb.pushOverlay(.{ .x = 10, .y = 10 });
    cb.button(.poke, "Menu");
    cb.popOverlay();

    var rects: [8]Rect = undefined;
    const rs = testLayout(&rects, &cb, 400, 400);
    const btn = rs[4];

    // Over the popup button: the button wins, the canvas gets nothing.
    try testing.expect(pointerTarget(cb.cmds.items, rs, btn.x + 4, btn.y + 4) == null);
    // Elsewhere on the canvas: still the canvas (a non-modal overlay passes through).
    try testing.expectEqual(@as(u32, 1), pointerTarget(cb.cmds.items, rs, 250, 250).?.id);

    var cm = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cm.deinit();
    cm.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cm.canvasInteractive(.{ .width = 300, .height = 300 }, &.{}, 1, "");
    cm.popGroup();
    cm.pushOverlay(.{ .x = 0, .y = 0, .width = 400, .height = 400, .modal = true });
    cm.popOverlay();
    var mrects: [8]Rect = undefined;
    const ms = testLayout(&mrects, &cm, 400, 400);
    // A modal backdrop consumes the point: the canvas below is not a target.
    try testing.expect(pointerTarget(cm.cmds.items, ms, 100, 100) == null);
    try testing.expect(wheelTarget(cm.cmds.items, ms, 100, 100) == null);
}

test "pointer canvas is clipped by its scroll viewport" {
    const testing = std.testing;
    const Msg = union(enum) { poke };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushScroll(.{ .width = 100, .height = 100, .padding = 0 });
    cb.canvasInteractive(.{ .width = 100, .height = 400 }, &.{}, 2, "");
    cb.popScroll();

    var rects: [8]Rect = undefined;
    const rs = testLayout(&rects, &cb, 400, 400);
    try testing.expectEqual(@as(u32, 2), pointerTarget(cb.cmds.items, rs, 50, 50).?.id);
    // The canvas extends to y=400 but the 100x100 viewport clips it.
    try testing.expect(pointerTarget(cb.cmds.items, rs, 50, 250) == null);
}

test "wheelTarget: innermost id-bearing scroll, canvas wins when innermost" {
    const testing = std.testing;
    const Msg = union(enum) { poke };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    // outer(id 1) { inner(id 0) { text } , inner2(id 3) { canvas(id 9) } , plain }
    cb.pushScroll(.{ .id = 1, .width = 300, .height = 300, .padding = 0, .direction = .vertical });
    cb.pushScroll(.{ .id = 0, .width = 300, .height = 100, .padding = 0 }); // index 1
    cb.text("hello");
    cb.popScroll();
    cb.pushScroll(.{ .id = 3, .width = 300, .height = 100, .padding = 0 }); // index 4
    cb.canvasInteractive(.{ .width = 300, .height = 100 }, &.{}, 9, ""); // index 5
    cb.popScroll();
    cb.pushScroll(.{ .id = 4, .width = 300, .height = 100, .padding = 0 }); // index 7
    cb.text("plain");
    cb.popScroll();
    cb.popScroll();

    var rects: [16]Rect = undefined;
    const rs = testLayout(&rects, &cb, 400, 400);

    // Over the id-0 inner region: falls to the outer id-1 region.
    const t0 = wheelTarget(cb.cmds.items, rs, 50, 50).?;
    try testing.expectEqual(@as(u32, 1), t0.scroll.id);
    // Over the id-3 region holding the pointer canvas: the canvas is innermost.
    const t1 = wheelTarget(cb.cmds.items, rs, 50, 150).?;
    try testing.expectEqual(@as(u32, 9), t1.canvas.id);
    // Over the id-4 region: its own id.
    const t2 = wheelTarget(cb.cmds.items, rs, 50, 250).?;
    try testing.expectEqual(@as(u32, 4), t2.scroll.id);
    try testing.expectEqual(@as(usize, 7), t2.scroll.index);
    // Outside everything.
    try testing.expect(wheelTarget(cb.cmds.items, rs, 390, 390) == null);
}

test "wheelTarget: an overlay scroll region wins over the base, a modal blocks it" {
    const testing = std.testing;
    const Msg = union(enum) { poke };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushScroll(.{ .id = 1, .width = 400, .height = 400, .padding = 0 }); // 0
    cb.text("base");
    cb.popScroll();
    cb.pushOverlay(.{ .x = 50, .y = 50, .width = 100, .height = 100 }); // 3
    cb.pushScroll(.{ .id = 2, .width = 100, .height = 100, .padding = 0 }); // 4
    cb.text("menu");
    cb.popScroll();
    cb.popOverlay();

    var rects: [16]Rect = undefined;
    const rs = testLayout(&rects, &cb, 400, 400);
    try testing.expectEqual(@as(u32, 2), wheelTarget(cb.cmds.items, rs, 70, 70).?.scroll.id);
    try testing.expectEqual(@as(u32, 1), wheelTarget(cb.cmds.items, rs, 300, 300).?.scroll.id);
}

test "hitTest: scene3d is interactive only with a click msg or pointer" {
    const testing = std.testing;
    const Msg = union(enum) { orbit };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();

    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.scene3d(.{ .style = .{ .width = 200, .height = 100 } }); // index 1 - inert
    cb.scene3d(.{ .style = .{ .width = 200, .height = 100 }, .msg = .orbit }); // index 2
    cb.scene3d(.{ .style = .{ .width = 200, .height = 100 }, .id = 3, .pointer = true }); // index 3
    cb.popGroup();

    var rects: [8]Rect = undefined;
    const rs = testLayout(&rects, &cb, 400, 400);

    try testing.expect(hitTest(cb.cmds.items, rs, rs[1].x + 5, rs[1].y + 5) == null);
    const hit = hitTest(cb.cmds.items, rs, rs[2].x + 5, rs[2].y + 5);
    try testing.expectEqual(@as(?Msg, Msg.orbit), hit.?.msg);
    // A pointer-only scene claims the point but dispatches no click Msg.
    const ph = hitTest(cb.cmds.items, rs, rs[3].x + 5, rs[3].y + 5);
    try testing.expectEqual(@as(usize, 3), ph.?.index);
    try testing.expectEqual(@as(?Msg, null), ph.?.msg);
    try testing.expectEqual(@as(?usize, null), hoverTest(cb.cmds.items, rs, rs[1].x + 5, rs[1].y + 5));
    try testing.expectEqual(@as(?usize, 2), hoverTest(cb.cmds.items, rs, rs[2].x + 5, rs[2].y + 5));
}

test "dragTargets: innermost source and target" {
    const testing = std.testing;
    const Msg = union(enum) { a };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
    cb.pushGroup(.{ .padding = 0, .gap = 0, .drag_id = 1, .drop_id = 1, .height = 30, .width = 100 });
    cb.text("one");
    cb.popGroup();
    cb.pushGroup(.{ .padding = 0, .gap = 0, .drag_id = 2, .drop_id = 2, .height = 30, .width = 100 });
    cb.text("two");
    cb.popGroup();
    cb.popGroup();
    var rects: [16]Rect = undefined;
    const n = cb.cmds.items.len;
    layout.LayoutEngine.doLayout(rects[0..n], cb.cmds.items, 200, 200, text_mod.monoMeasurer());

    const a = dragTargets(cb.cmds.items, rects[0..n], 10, 10);
    try testing.expectEqual(@as(u32, 1), a.source.?.id);
    try testing.expectEqual(@as(u32, 1), a.target.?.id);
    const b = dragTargets(cb.cmds.items, rects[0..n], 10, 45);
    try testing.expectEqual(@as(u32, 2), b.source.?.id);
    try testing.expect(dragTargets(cb.cmds.items, rects[0..n], 150, 10).source == null);
}

test "text_area: a click returns its focus msg and the area is a pointer target; wheel targets it" {
    const testing = std.testing;
    const Msg = union(enum) { focus, other };
    var cb = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    cb.textArea(.{ .focus_msg = .focus, .id = 9, .content = "x", .width = 200, .height = 100 });
    cb.button(.other, "B");
    cb.popGroup();
    var rects: [4]Rect = undefined;
    const rs = testLayout(&rects, &cb, 400, 400);
    try testing.expectEqual(@as(?Msg, Msg.focus), hitTest(cb.cmds.items, rs, 50, 50).?.msg);
    try testing.expectEqual(@as(u32, 9), pointerTarget(cb.cmds.items, rs, 50, 50).?.id);
    try testing.expectEqual(@as(u32, 9), wheelTarget(cb.cmds.items, rs, 50, 50).?.canvas.id);
    // The button below is not a pointer target; a disabled area is not either.
    try testing.expect(pointerTarget(cb.cmds.items, rs, 10, 110) == null);
    var off = cmd_mod.CmdBuffer(Msg).init(testing.allocator);
    defer off.deinit();
    off.pushGroup(.{ .padding = 0, .gap = 0 });
    off.textArea(.{ .focus_msg = .focus, .id = 9, .content = "x", .width = 200, .height = 100, .disabled = true });
    off.popGroup();
    var rects2: [4]Rect = undefined;
    const rs2 = testLayout(&rects2, &off, 400, 400);
    try testing.expect(pointerTarget(off.cmds.items, rs2, 50, 50) == null);
}
