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
        index: usize,
        msg: Msg,
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
pub fn hitTest(
    cmds: anytype,
    rects: []const Rect,
    mouse_x: f32,
    mouse_y: f32,
) ?HitResult(CmdMsg(@TypeOf(cmds))) {
    // Overlay layer first (it wins): a hit there short-circuits.
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
            .push_overlay => {
                overlay_depth += 1;
                // Overlay is its own clip so contents are bounded by
                // the overlay rect (e.g. menu items past the menu's
                // height shouldn't hit-test).
                clip.push(clipRect(rects[i], cur_clip));
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
    return best;
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
            .push_overlay => {
                overlay_depth += 1;
                clip.push(clipRect(rects[i], cur_clip));
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
    return best;
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
    try testing.expectEqual(Msg.inc, hit_inc.?.msg);

    const hit_dec = hitTest(cb.cmds.items, rects[0..cb.cmds.items.len], 90, 18);
    try testing.expect(hit_dec != null);
    try testing.expectEqual(Msg.dec, hit_dec.?.msg);

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
    try testing.expectEqual(Msg.focus, hit.?.msg);
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
    try testing.expectEqual(Msg.overlay_click, hit.?.msg);
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
    try testing.expectEqual(Msg.base_click, hit.?.msg);
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
    try testing.expectEqual(Msg.toggle, cb_hit.?.msg);

    const rd_hit = hitTest(cb.cmds.items, rects[0..cb.cmds.items.len], rects[2].x + 2, rects[2].y + 2);
    try testing.expectEqual(Msg.pick, rd_hit.?.msg);

    const sl_hit = hitTest(cb.cmds.items, rects[0..cb.cmds.items.len], rects[3].x + 10, rects[3].y + 10);
    try testing.expectEqual(Msg.grab, sl_hit.?.msg);
}
