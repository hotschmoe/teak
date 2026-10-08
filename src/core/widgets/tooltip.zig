//! Tooltip: a small popup that appears after the pointer rests on a widget.
//!
//! HARDLINE argument. A tooltip's *visibility* changes what `view` emits, so
//! the hover state it depends on cannot live in `TransientState` (which is
//! presentation-only and must never influence the Cmd stream). It therefore
//! lives in the Model, fed by data: the App's optional `hoverMsg` hook hands
//! the app a `PointerEvent` (the widget's click Msg, its rect from the
//! previous frame's layout, and the host clock) each time the hovered widget
//! changes, and the app maps it to `Tooltip.Msg.hover`. The delay is a
//! declarative `Sub.at(deadline)` the app lists while a tooltip is pending.
//! No timers in widgets, no layout reads in `view`, no hashing: the widget is
//! identified by the very Msg it would dispatch, compared with `std.meta.eql`.
//!
//! ```zig
//! const tips = [_]Msg{ .save, .open };                // widgets that have tips
//! const tip_text = [_][]const u8{ "Save (Ctrl+S)", "Open a file" };
//!
//! pub fn hoverMsg(m: *const Model, ev: teak.PointerEvent(Msg)) ?Msg {
//!     return .{ .tip = Tooltip.hoverMsg(Msg, ev, &tips, 500) };
//! }
//! pub fn subscribe(m: *const Model) []const Sub(Msg) {
//!     if (Tooltip.deadline(&m.tip)) |d| return &.{.{ .at = .{ .deadline_ms = d, .msg = .{ .tip = .show } } }};
//!     return &.{};
//! }
//! // view, last (so the popup is on top):
//! Tooltip.view(&m.tip, cb, &tip_text, .{ .window_w = m.w, .window_h = m.h });
//! ```

const std = @import("std");
const cmd = @import("../cmd.zig");
const component = @import("../component.zig");
const pointer = @import("../pointer.zig");

pub const Model = struct {
    /// Index into the app's tooltip table of the hovered widget, if it has a tip.
    item: ?u16 = null,
    /// The hovered widget's rect (window coordinates, previous frame).
    box: pointer.Box = .{},
    /// Host-clock time at which the popup appears; null once shown or idle.
    deadline: ?u64 = null,
    shown: bool = false,
};

pub const Msg = union(enum) {
    /// The hovered widget changed. Build with `hoverMsg`.
    hover: Hover,
    /// The delay elapsed (fired by the app's `Sub.at(deadline(model))`).
    show,
    /// Hide now (a click, a key press, a dialog opening...).
    hide,

    pub const Hover = struct {
        item: ?u16,
        box: pointer.Box,
        /// `now_ms + delay`.
        deadline: u64,
    };
};

pub fn update(model: *Model, msg: Msg) void {
    switch (msg) {
        .hover => |h| {
            // Same widget re-reported (layout shifted an index): keep what we have.
            if (h.item != null and h.item == model.item) {
                model.box = h.box;
                return;
            }
            model.item = h.item;
            model.box = h.box;
            model.shown = false;
            model.deadline = if (h.item != null) h.deadline else null;
        },
        .show => {
            if (model.item != null) model.shown = true;
            model.deadline = null;
        },
        .hide => {
            model.shown = false;
            model.deadline = null;
            model.item = null;
        },
    }
}

/// The hover Msg for `ev`: which of `targets` (the click Msgs of the widgets
/// that have tooltips, matched by value) the pointer is on. `delay_ms` is the
/// hover delay. A pointer on an untargeted widget, or on nothing, clears it.
pub fn hoverMsg(comptime AppMsg: type, ev: pointer.PointerEvent(AppMsg), targets: []const AppMsg, delay_ms: u32) Msg {
    var item: ?u16 = null;
    if (ev.hit) |h| {
        for (targets, 0..) |t, i| {
            if (std.meta.eql(t, h)) {
                item = @intCast(i);
                break;
            }
        }
    }
    return .{ .hover = .{ .item = item, .box = ev.box, .deadline = ev.now_ms + delay_ms } };
}

/// The pending deadline for the app's `subscribe` (`Sub.at`), or null.
pub fn deadline(model: *const Model) ?u64 {
    return model.deadline;
}

pub const ViewOpts = struct {
    /// Window size, so the popup flips to stay on screen.
    window_w: f32,
    window_h: f32,
    /// Gap between the widget and the popup.
    gap: f32 = 6,
};

/// Component-contract view (the popup needs text; use the 4-arg `view`).
pub fn viewDefault(model: *const Model, cb: anytype, msgs: anytype) void {
    _ = model;
    _ = cb;
    _ = msgs;
}

/// Emit the popup when it is due. `texts[i]` is the tip for target `i`.
/// Call it last in `view` so the overlay is drawn over everything.
pub fn view(model: *const Model, cb: anytype, texts: []const []const u8, o: ViewOpts) void {
    if (!model.shown) return;
    const i = model.item orelse return;
    if (i >= texts.len) return;
    const pal = cb.theme.palette;
    const b = model.box;
    // Prefer below-left of the widget; flip to above / right-aligned when the
    // widget is in the lower third / right half of the window.
    const above = b.y + b.h > o.window_h * 0.66;
    const right = b.x + b.w * 0.5 > o.window_w * 0.5;
    cb.pushOverlay(.{
        .x = if (right) b.x + b.w else b.x,
        .y = if (above) b.y - o.gap else b.y + b.h + o.gap,
        .anchor_x_frac = if (right) 1 else 0,
        .anchor_y_frac = if (above) 1 else 0,
        .padding = 0,
        .gap = 0,
        .shadow = .{ 0, 0, 0, 0.35 },
        .shadow_offset = .{ 2, 2 },
    });
    cb.pushGroup(.{ .direction = .vertical, .padding = 6, .gap = 0, .bg = pal.bg_panel, .border = pal.border });
    cb.text(texts[i]);
    cb.popGroup();
    cb.popOverlay();
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;
const snapshot = @import("../snapshot.zig");
const engine = @import("../../layout/engine.zig");
const text_mod = @import("../text.zig");

const TMsg = union(enum) { save, open, quit };
const tip_targets = [_]TMsg{ .save, .open };
const tip_text = [_][]const u8{ "Save (Ctrl+S)", "Open a file" };

fn mkev(hit: ?TMsg, now: u64) pointer.PointerEvent(TMsg) {
    return .{ .x = 10, .y = 10, .hit = hit, .box = .{ .x = 10, .y = 20, .w = 60, .h = 30 }, .now_ms = now };
}

test "tooltip: hover arms a deadline; show makes it visible; leaving clears it" {
    var m: Model = .{};
    update(&m, hoverMsg(TMsg, mkev(.save, 1000), &tip_targets, 500));
    try testing.expectEqual(@as(?u16, 0), m.item);
    try testing.expectEqual(@as(?u64, 1500), deadline(&m));
    try testing.expect(!m.shown);
    update(&m, .show);
    try testing.expect(m.shown);
    try testing.expectEqual(@as(?u64, null), deadline(&m));
    update(&m, hoverMsg(TMsg, mkev(null, 2000), &tip_targets, 500));
    try testing.expect(!m.shown and m.item == null and deadline(&m) == null);
}

test "tooltip: a widget without a tip never arms; moving to another widget re-arms" {
    var m: Model = .{};
    update(&m, hoverMsg(TMsg, mkev(.quit, 0), &tip_targets, 500));
    try testing.expect(m.item == null and deadline(&m) == null);
    update(&m, .show); // a stray timer does nothing
    try testing.expect(!m.shown);

    update(&m, hoverMsg(TMsg, mkev(.save, 0), &tip_targets, 500));
    update(&m, .show);
    update(&m, hoverMsg(TMsg, mkev(.open, 100), &tip_targets, 500));
    try testing.expect(!m.shown); // hidden until the new delay passes
    try testing.expectEqual(@as(?u16, 1), m.item);
    try testing.expectEqual(@as(?u64, 600), deadline(&m));
}

test "tooltip: re-reporting the same widget keeps the shown state and refreshes the box" {
    var m: Model = .{};
    update(&m, hoverMsg(TMsg, mkev(.save, 0), &tip_targets, 500));
    update(&m, .show);
    var e = mkev(.save, 50);
    e.box.x = 99;
    update(&m, hoverMsg(TMsg, e, &tip_targets, 500));
    try testing.expect(m.shown);
    try testing.expectEqual(@as(f32, 99), m.box.x);
}

test "tooltip: hide clears everything" {
    var m: Model = .{};
    update(&m, hoverMsg(TMsg, mkev(.save, 0), &tip_targets, 500));
    update(&m, .show);
    update(&m, .hide);
    try testing.expect(!m.shown and m.item == null and deadline(&m) == null);
}

test "tooltip: view emits nothing until shown, then an overlay below the widget" {
    var m: Model = .{};
    var cb = cmd.CmdBuffer(TMsg).init(testing.allocator);
    defer cb.deinit();
    view(&m, &cb, &tip_text, .{ .window_w = 800, .window_h = 600 });
    try testing.expectEqual(@as(usize, 0), cb.cmds.items.len);

    update(&m, hoverMsg(TMsg, mkev(.save, 0), &tip_targets, 0));
    update(&m, .show);
    view(&m, &cb, &tip_text, .{ .window_w = 800, .window_h = 600 });
    const ov = cb.cmds.items[0].push_overlay;
    try testing.expectEqual(@as(f32, 10), ov.x);
    try testing.expectEqual(@as(f32, 20 + 30 + 6), ov.y);
    try testing.expectEqual(@as(f32, 0), ov.anchor_y_frac);
    try testing.expect(!ov.modal); // it never blocks the pointer
}

test "tooltip: flips above and right-aligned near the bottom-right corner" {
    var m: Model = .{ .item = 0, .shown = true, .box = .{ .x = 700, .y = 560, .w = 80, .h = 30 } };
    var cb = cmd.CmdBuffer(TMsg).init(testing.allocator);
    defer cb.deinit();
    view(&m, &cb, &tip_text, .{ .window_w = 800, .window_h = 600 });
    const ov = cb.cmds.items[0].push_overlay;
    try testing.expectEqual(@as(f32, 1), ov.anchor_x_frac);
    try testing.expectEqual(@as(f32, 1), ov.anchor_y_frac);
    try testing.expectEqual(@as(f32, 780), ov.x);
    try testing.expectEqual(@as(f32, 554), ov.y);
}

test "tooltip: snapshot golden" {
    const m: Model = .{ .item = 1, .shown = true, .box = .{ .x = 40, .y = 100, .w = 60, .h = 30 } };
    var cb = cmd.CmdBuffer(TMsg).init(testing.allocator);
    defer cb.deinit();
    cb.pushGroup(.{ .padding = 0, .gap = 0 });
    cb.button(.open, "Open");
    cb.popGroup();
    view(&m, &cb, &tip_text, .{ .window_w = 400, .window_h = 300 });
    var rects: [16]engine.Rect = undefined;
    const n = cb.cmds.items.len;
    engine.LayoutEngine.doLayout(rects[0..n], cb.cmds.items, 400, 300, text_mod.monoMeasurer());
    try snapshot.expectSnapshot(cb.cmds.items, rects[0..n], .{},
        \\group (0,0,400,300) vertical
        \\  button (0,0,60,36) "Open"
        \\overlay (40,136,122,32) layer=1 shadow
        \\  group (40,136,122,32) vertical bg border
        \\    text (46,142,110,20) "Open a file"
        \\
    );
}
