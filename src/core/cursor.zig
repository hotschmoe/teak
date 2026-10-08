//! Mouse-cursor shapes and the rule that picks one from the hovered cmd.
//! Pure data + one switch: the Host maps a `CursorShape` onto its OS cursor
//! (`Host.setCursor`), and `teak.run` calls it only when the shape changes.

const std = @import("std");

pub const CursorShape = enum {
    arrow,
    /// The hand over something clickable.
    pointer,
    /// Text insertion beam.
    ibeam,
    crosshair,
    move,
    resize_ew,
    resize_ns,
    resize_nwse,
    resize_nesw,
    not_allowed,
    grab,
    grabbing,

    /// The CSS `cursor` keyword for this shape (web host; also the XCursor
    /// theme name for most shapes).
    pub fn cssName(self: CursorShape) [:0]const u8 {
        return switch (self) {
            .arrow => "default",
            .pointer => "pointer",
            .ibeam => "text",
            .crosshair => "crosshair",
            .move => "move",
            .resize_ew => "ew-resize",
            .resize_ns => "ns-resize",
            .resize_nwse => "nwse-resize",
            .resize_nesw => "nesw-resize",
            .not_allowed => "not-allowed",
            .grab => "grab",
            .grabbing => "grabbing",
        };
    }
};

/// What the pointer is over, as the App's optional `cursorFor(model, kind)`
/// hook sees it. `none` is empty space (or a non-interactive cmd).
pub const HoverKind = enum { none, button, checkbox, radio, slider, text_input, canvas, scene3d };

/// The framework's default shape for a hovered cmd (`null` for non-interactive
/// cmds). `cmd` is a `Cmd(Msg)` value; kept `anytype` so it serves every Msg.
/// Disabled widgets never hit-test, so they read as `.none` and get the arrow.
pub fn kindOf(cmd: anytype) HoverKind {
    return switch (cmd) {
        .button => .button,
        .checkbox => .checkbox,
        .radio => .radio,
        .slider => .slider,
        .text_input => .text_input,
        .canvas => .canvas,
        .scene3d => .scene3d,
        else => .none,
    };
}

/// Default cursor for a hovered cmd. An interactive canvas may name its own
/// (`CanvasCmd.cursor`); otherwise it keeps the arrow.
pub fn defaultFor(cmd: anytype) CursorShape {
    return switch (cmd) {
        .button, .checkbox, .radio, .slider => .pointer,
        .text_input => .ibeam,
        .canvas => |c| c.cursor orelse .arrow,
        else => .arrow,
    };
}

test "css names are distinct" {
    var seen = std.StringHashMap(void).init(std.testing.allocator);
    defer seen.deinit();
    for (std.enums.values(CursorShape)) |s| try seen.putNoClobber(s.cssName(), {});
}

test "defaultFor / kindOf over a real Cmd" {
    const Cmd = @import("cmd.zig").Cmd(u8);
    const btn: Cmd = .{ .button = &.{ .msg = 1, .label = "x" } };
    const inp: Cmd = .{ .text_input = &.{ .focus_msg = 1, .content = "", .cursor = 0 } };
    const cv: Cmd = .{ .canvas = &.{ .cursor = .move } };
    const plain_cv: Cmd = .{ .canvas = &.{} };
    try std.testing.expectEqual(CursorShape.pointer, defaultFor(btn));
    try std.testing.expectEqual(CursorShape.ibeam, defaultFor(inp));
    try std.testing.expectEqual(CursorShape.move, defaultFor(cv));
    try std.testing.expectEqual(CursorShape.arrow, defaultFor(plain_cv));
    try std.testing.expectEqual(HoverKind.text_input, kindOf(inp));
}
