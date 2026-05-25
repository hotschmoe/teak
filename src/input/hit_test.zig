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

/// Msg carried by an interactive leaf, if any. Lets hit-test and the
/// interactive-leaf hoverTest arm share one predicate.
fn leafMsg(c: anytype) ?@TypeOf(c).MsgT {
    return switch (c) {
        .button => |b| b.msg,
        .text_input => |t| t.focus_msg,
        .checkbox => |cb| cb.msg,
        .radio => |r| r.msg,
        .slider => |s| s.grab_msg,
        else => null,
    };
}

/// Forward-walk cmds/rects maintaining a scroll-clip stack; keep the
/// *last* hit so painter's order wins (a later draw is on top). Two
/// passes — non-overlay first, then overlay — so the overlay layer
/// (HARDLINE §2 escape hatch 5) wins z-order without per-cmd z fields.
/// A backward walk would be simpler for z-order but couldn't honor
/// scroll clips that accumulate top-down.
///
/// `HitResult.msg` is `?Msg`: a `null` msg means a modal overlay
/// consumed the click but the app didn't supply a `backdrop_msg`. The
/// host must NOT fall through to widgets behind the modal in that
/// case — see the doc on `HitResult.msg`.
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
            else => if (visible_to_layer) {
                if (leafMsg(c)) |msg| {
                    if (rectContains(rects[i], mouse_x, mouse_y) and rectContains(cur_clip, mouse_x, mouse_y))
                        best = .{ .index = i, .msg = msg };
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

/// Like hitTest but returns only the index (no msg). Also respects
/// scroll clips and the overlay layer (overlay-layer hover wins).
pub fn hoverTest(
    cmds: anytype,
    rects: []const Rect,
    mouse_x: f32,
    mouse_y: f32,
) ?usize {
    if (hoverTestLayer(cmds, rects, mouse_x, mouse_y, .overlay)) |h| return h;
    return hoverTestLayer(cmds, rects, mouse_x, mouse_y, .base);
}

fn hoverTestLayer(
    cmds: anytype,
    rects: []const Rect,
    mouse_x: f32,
    mouse_y: f32,
    layer: Layer,
) ?usize {
    var clip: ClipStack = .{};
    var overlay_depth: u32 = 0;
    var best: ?usize = null;

    // Mirror `hitTestLayer`'s modal handling: track the innermost modal
    // overlay containing the mouse during the .overlay pass so we can
    // claim the hover even if no interactive leaf catches it. Hosts
    // gate `hitTest` behind a press-target dance — they call
    // `hoverTest` on mousedown to arm `press_target` and again on
    // mouseup to gate `hitTest`. If hover returns null over a modal
    // backdrop, press_target never arms and the modal-fallback path in
    // `hitTest` is never reached. The index-equality check
    // (`hover_under_mouse == press_target`) works fine here: press and
    // release both yield the overlay's cmd index.
    var modal_index: ?usize = null;

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
                if (layer == .overlay and ov.modal and
                    rectContains(rects[i], mouse_x, mouse_y) and
                    rectContains(cur_clip, mouse_x, mouse_y))
                {
                    modal_index = i;
                }
            },
            .pop_overlay => {
                overlay_depth -= 1;
                clip.pop();
            },
            .push_group, .pop_group, .push_virtual_list, .pop_virtual_list => {},
            else => if (visible_to_layer and leafMsg(c) != null) {
                if (rectContains(rects[i], mouse_x, mouse_y) and rectContains(cur_clip, mouse_x, mouse_y))
                    best = i;
            },
        }
    }
    if (best) |b| return b;
    // No leaf claimed the hover. A modal overlay containing the mouse
    // claims the empty backdrop area on its own behalf so the host's
    // press-target gate arms on the overlay's cmd index — without this
    // the press/release pair never fires `hitTest` and the modal's
    // `backdrop_msg` would be unreachable in practice.
    return modal_index;
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
