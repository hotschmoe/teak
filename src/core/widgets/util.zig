//! Helpers shared by the widget components (internal).

const std = @import("std");

/// A full-window, fully transparent modal overlay whose only job is to catch
/// clicks outside a popup (menu, context menu, tooltip-free popovers): the
/// press lands on this backdrop and dispatches `close`. Emit it BEFORE the
/// popup's own overlay, which is later in the buffer and so wins hit-testing
/// where the two overlap (painter's order).
///
/// `cb` is a `*CmdBuffer(Msg)`; `close` is the app's Msg for "dismiss".
pub fn scrim(cb: anytype, close: anytype, window_w: f32, window_h: f32) void {
    cb.pushOverlay(.{
        .x = 0,
        .y = 0,
        .width = window_w,
        .height = window_h,
        .padding = 0,
        .gap = 0,
        .modal = true,
        .backdrop_msg = close,
    });
    cb.popOverlay();
}

/// Copy `bytes` into the frame arena (for strings a view builds on the fly).
pub fn frameStr(cb: anytype, bytes: []const u8) []const u8 {
    return cb.arena.allocator().dupe(u8, bytes) catch unreachable;
}

/// `fmt` into the frame arena.
pub fn frameFmt(cb: anytype, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.allocPrint(cb.arena.allocator(), fmt, args) catch unreachable;
}

/// Mix `a` toward `b` by `t` (0..1), per channel; alpha follows `a`.
pub fn mix(a: [4]f32, b: [4]f32, t: f32) [4]f32 {
    return .{
        a[0] + (b[0] - a[0]) * t,
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
        a[3],
    };
}
