//! Keysym -> host-neutral key mapping shared by the Linux hosts. X11 and
//! xkbcommon (Wayland) use the same keysym values, so one table serves both.
//! Pure: no OS types.

const std = @import("std");
const teak = @import("teak");

pub const NavKey = teak.NavKey;

pub const BackSpace: u32 = 0xff08;
pub const Tab: u32 = 0xff09;
pub const ISO_Left_Tab: u32 = 0xfe20;
pub const Return: u32 = 0xff0d;
pub const KP_Enter: u32 = 0xff8d;
pub const Escape: u32 = 0xff1b;
pub const Delete: u32 = 0xffff;
pub const Home: u32 = 0xff50;
pub const Left: u32 = 0xff51;
pub const Up: u32 = 0xff52;
pub const Right: u32 = 0xff53;
pub const Down: u32 = 0xff54;
pub const Prior: u32 = 0xff55; // Page Up
pub const Next: u32 = 0xff56; // Page Down
pub const End: u32 = 0xff57;

/// Non-text keys. `ISO_Left_Tab` is what Shift+Tab produces; the Shift
/// modifier turns `.tab` into `shift_tab`.
pub fn navFromKeysym(sym: u32) ?NavKey {
    return switch (sym) {
        BackSpace => .backspace,
        Delete => .delete,
        Left => .left,
        Right => .right,
        Up => .up,
        Down => .down,
        Home => .home,
        End => .end,
        Prior => .page_up,
        Next => .page_down,
        Return, KP_Enter => .enter,
        Tab, ISO_Left_Tab => .tab,
        Escape => .escape,
        else => null,
    };
}

/// Letter keysyms that form editing chords (only consulted with Ctrl held).
pub fn chordFromKeysym(sym: u32) ?NavKey {
    // Fold A-Z onto a-z so Caps Lock / Shift don't matter.
    return switch (sym | 0x20) {
        'a' => .a,
        'c' => .c,
        'x' => .x,
        'v' => .v,
        'y' => .y,
        'z' => .z,
        else => null,
    };
}

test "navFromKeysym / chordFromKeysym" {
    try std.testing.expectEqual(NavKey.tab, navFromKeysym(ISO_Left_Tab).?);
    try std.testing.expect(navFromKeysym('a') == null);
    try std.testing.expectEqual(NavKey.c, chordFromKeysym('C').?);
    try std.testing.expect(chordFromKeysym('1') == null);
}
