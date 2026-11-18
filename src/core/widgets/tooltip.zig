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







