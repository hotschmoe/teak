//! Toggle switch: an on/off control that reads as a switch rather than a
//! checkbox. Built from existing primitives (zero new Cmd variants): a
//! clickable `canvas` draws the track and the knob, a `text` carries the
//! label. The state is the app's own `bool`; the click Msg flips it.
//!
//! ```zig
//! teak.widgets.toggle.view(cb, .{ .toggle_wifi = {} }, m.wifi, "Wi-Fi");
//! ```
//!
//! Corners are square like every other teak quad: the "retro" switch is a
//! slab with a square knob; a theme that wants rounder shapes would need
//! the quad renderer to learn about corner radii.

const std = @import("std");
const oom = @import("../oom.zig").oom;
const cmd = @import("../cmd.zig");

pub const Style = struct {
    /// Outer track size in px.
    width: f32 = 40,
    height: f32 = 22,
    /// Gap between the knob and the track edge.
    inset: f32 = 3,
    /// Gap between the switch and its label.
    label_gap: f32 = 10,
    /// Null = derive from `cb.theme.palette` (accent when on, sunken when off).
    on_color: ?[4]f32 = null,
    off_color: ?[4]f32 = null,
    border_color: ?[4]f32 = null,
    knob_color: ?[4]f32 = null,
};

/// The switch plus its label, in a horizontal row.
pub fn view(cb: anytype, msg: anytype, on: bool, label: []const u8) void {
    viewStyled(cb, msg, on, label, .{});
}

pub fn viewStyled(cb: anytype, msg: anytype, on: bool, label: []const u8, style: Style) void {
    const pal = cb.theme.palette;
    const border = style.border_color orelse pal.border;
    const track = if (on) (style.on_color orelse pal.accent) else (style.off_color orelse pal.bg_sunken);
    const knob = style.knob_color orelse (if (on) pal.bg else pal.fg_muted);

    const w = style.width;
    const h = style.height;
    const k = h - 2 * style.inset;
    const kx = if (on) w - style.inset - k else style.inset;

    const prims = cb.arena.allocator().alloc(cmd.CanvasPrimitive, 3) catch oom();
    prims[0] = .{ .filled_rect = .{ .x = 0, .y = 0, .w = w, .h = h, .color = border } };
    prims[1] = .{ .filled_rect = .{ .x = 1, .y = 1, .w = w - 2, .h = h - 2, .color = track } };
    prims[2] = .{ .filled_rect = .{ .x = kx, .y = style.inset, .w = k, .h = k, .color = knob } };

    cb.pushGroup(.{ .direction = .horizontal, .padding = 0, .gap = style.label_gap, .align_cross = .center });
    cb.canvasClickable(msg, .{ .width = w, .height = h }, prims, label);
    if (label.len > 0) cb.text(label);
    cb.popGroup();
}

const testing = std.testing;
const snapshot = @import("../snapshot.zig");
const engine = @import("../../layout/engine.zig");
const text = @import("../text.zig");

const TestMsg = union(enum) { flip, other };
