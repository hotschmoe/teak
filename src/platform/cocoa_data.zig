//! Display-free decoding for the macOS host: virtual key codes, modifier
//! flags, scroll deltas, cursor mapping and UTF-16 <-> UTF-8 offsets for the
//! input method. Pure, so it unit-tests on any OS; `cocoa.zig` feeds it from
//! AppKit callbacks.

const std = @import("std");
const teak = @import("teak");
const keysym = @import("keysym.zig");

pub const NavKey = teak.NavKey;
pub const Modifiers = teak.Modifiers;
pub const SpecialKey = teak.SpecialKey;

// NSEventModifierFlags
pub const FLAG_SHIFT: u64 = 1 << 17;
pub const FLAG_CONTROL: u64 = 1 << 18;
pub const FLAG_OPTION: u64 = 1 << 19;
pub const FLAG_COMMAND: u64 = 1 << 20;

pub fn modsFromFlags(flags: u64) Modifiers {
    return .{
        .shift = flags & FLAG_SHIFT != 0,
        .ctrl = flags & FLAG_CONTROL != 0,
        .alt = flags & FLAG_OPTION != 0,
        .meta = flags & FLAG_COMMAND != 0,
    };
}

// kVK_* virtual key codes (Carbon HIToolbox/Events.h).
pub const KC_RETURN: u16 = 36;
pub const KC_TAB: u16 = 48;
pub const KC_DELETE: u16 = 51; // backspace
pub const KC_ESCAPE: u16 = 53;
pub const KC_KP_ENTER: u16 = 76;
pub const KC_HOME: u16 = 115;
pub const KC_PAGE_UP: u16 = 116;
pub const KC_FORWARD_DELETE: u16 = 117;
pub const KC_END: u16 = 119;
pub const KC_PAGE_DOWN: u16 = 121;
pub const KC_LEFT: u16 = 123;
pub const KC_RIGHT: u16 = 124;
pub const KC_DOWN: u16 = 125;
pub const KC_UP: u16 = 126;

pub fn navFromKeyCode(code: u16) ?NavKey {
    return switch (code) {
        KC_RETURN, KC_KP_ENTER => .enter,
        KC_TAB => .tab,
        KC_DELETE => .backspace,
        KC_ESCAPE => .escape,
        KC_HOME => .home,
        KC_PAGE_UP => .page_up,
        KC_FORWARD_DELETE => .delete,
        KC_END => .end,
        KC_PAGE_DOWN => .page_down,
        KC_LEFT => .left,
        KC_RIGHT => .right,
        KC_DOWN => .down,
        KC_UP => .up,
        else => null,
    };
}

/// What a key press means to the framework, or null when it is text (to be
/// routed through the input method) or nothing.
pub const Decoded = struct {
    special: ?SpecialKey = null,
    /// The press was Cmd+V (the host may start a paste).
    paste: bool = false,
    /// Cmd+Q / Cmd+W: the host closes the window.
    quit: bool = false,
};

/// Map a key-down to a `SpecialKey` with the macOS conventions: Cmd is the
/// primary modifier (Cmd+A/C/X/V/Z, Cmd+Shift+Z = redo), Option+arrows /
/// Option+Backspace / Option+Delete move or delete by word, Cmd+Left/Right
/// go to line start / end and Cmd+Up/Down to document start / end.
/// `ch` is the lower-cased first character ignoring modifiers (0 if none).
pub fn decodeKey(code: u16, flags: u64, ch: u8) Decoded {
    const m = modsFromFlags(flags);
    if (m.meta and !m.ctrl and !m.alt and (ch == 'q' or ch == 'w')) return .{ .quit = true };
    var out: Decoded = .{};
    if (navFromKeyCode(code)) |nk| {
        var mods = m;
        mods.meta = false;
        mods.alt = false;
        mods.ctrl = false;
        var key = nk;
        if (m.meta) {
            switch (nk) {
                .left => key = .home,
                .right => key = .end,
                .up => {
                    key = .home;
                    mods.ctrl = true;
                },
                .down => {
                    key = .end;
                    mods.ctrl = true;
                },
                // Cmd+Backspace: delete to line start isn't a SpecialKey;
                // behave like Option+Backspace (a word).
                .backspace, .delete => mods.ctrl = true,
                else => {},
            }
        } else if (m.alt or m.ctrl) {
            // Option (word) / Control navigation reuses the Ctrl variants.
            mods.ctrl = true;
        }
        out.special = teak.resolveKey(key, mods);
        return out;
    }
    if (m.meta or m.ctrl) {
        if (keysym.chordFromKeysym(ch)) |nk| {
            var mods = m;
            mods.ctrl = true;
            out.special = teak.resolveKey(nk, mods);
            out.paste = nk == .v;
        }
    }
    return out;
}

/// Pixels per line of a non-precise (mouse wheel) scroll event; matches the
/// 48 px notch of the other hosts (3 lines).
pub const WHEEL_PX_PER_LINE: f32 = 16;

/// Scroll deltas to `InputState` convention (positive = content scrolls
/// down / right). AppKit reports positive Y for "scroll up", so Y flips;
/// X is already "scroll right" negative-left, flip it too so positive means
/// right under the same sign rule.
pub fn scrollDelta(dx: f64, dy: f64, precise: bool) struct { x: f32, y: f32 } {
    const k: f32 = if (precise) 1 else WHEEL_PX_PER_LINE;
    return .{ .x = -@as(f32, @floatCast(dx)) * k, .y = -@as(f32, @floatCast(dy)) * k };
}

// ── NSCursor selectors ─────────────────────────────────────────────

/// Class-method selector on NSCursor for a shape (all public API), plus a
/// private-API selector tried first when non-empty (the diagonal resizes
/// and "move" have no public cursor).
pub const CursorSel = struct { private: [:0]const u8 = "", public: [:0]const u8 };

pub fn cursorSel(shape: teak.CursorShape) CursorSel {
    return switch (shape) {
        .arrow => .{ .public = "arrowCursor" },
        .pointer => .{ .public = "pointingHandCursor" },
        .ibeam => .{ .public = "IBeamCursor" },
        .crosshair => .{ .public = "crosshairCursor" },
        .move => .{ .private = "_moveCursor", .public = "openHandCursor" },
        .resize_ew => .{ .public = "resizeLeftRightCursor" },
        .resize_ns => .{ .public = "resizeUpDownCursor" },
        .resize_nwse => .{ .private = "_windowResizeNorthWestSouthEastCursor", .public = "crosshairCursor" },
        .resize_nesw => .{ .private = "_windowResizeNorthEastSouthWestCursor", .public = "crosshairCursor" },
        .not_allowed => .{ .public = "operationNotAllowedCursor" },
        .grab => .{ .public = "openHandCursor" },
        .grabbing => .{ .public = "closedHandCursor" },
    };
}

// ── UTF-16 offsets (NSString indices) ──────────────────────────────

/// Byte offset in `utf8` of UTF-16 code-unit index `idx` (clamped to the end
/// of the text), as the input method counts marked-text positions.
pub fn utf16IndexToByte(utf8: []const u8, idx: usize) usize {
    var units: usize = 0;
    var i: usize = 0;
    while (i < utf8.len and units < idx) {
        const len = std.unicode.utf8ByteSequenceLength(utf8[i]) catch 1;
        units += if (len == 4) 2 else 1;
        i += len;
    }
    return @min(i, utf8.len);
}

/// UTF-16 length of `utf8`.
pub fn utf16Len(utf8: []const u8) usize {
    var units: usize = 0;
    var i: usize = 0;
    while (i < utf8.len) {
        const len = std.unicode.utf8ByteSequenceLength(utf8[i]) catch 1;
        units += if (len == 4) 2 else 1;
        i += len;
    }
    return units;
}

test "modifier flags" {
    const m = modsFromFlags(FLAG_SHIFT | FLAG_COMMAND | 0x10000); // caps lock ignored
    try std.testing.expect(m.shift and m.meta and !m.ctrl and !m.alt);
}

test "Cmd is the primary modifier for chords" {
    try std.testing.expectEqual(SpecialKey.ctrl_c, decodeKey(8, FLAG_COMMAND, 'c').special.?);
    try std.testing.expectEqual(SpecialKey.ctrl_z, decodeKey(6, FLAG_COMMAND, 'z').special.?);
    try std.testing.expectEqual(SpecialKey.ctrl_shift_z, decodeKey(6, FLAG_COMMAND | FLAG_SHIFT, 'z').special.?);
    const v = decodeKey(9, FLAG_COMMAND, 'v');
    try std.testing.expect(v.paste and v.special.? == .ctrl_v);
    // A plain letter is text; Cmd+unknown letter is nothing.
    try std.testing.expect(decodeKey(0, 0, 'a').special == null);
    try std.testing.expect(decodeKey(12, FLAG_COMMAND, 'j').special == null);
    try std.testing.expect(decodeKey(12, FLAG_COMMAND, 'q').quit);
    try std.testing.expect(decodeKey(13, FLAG_COMMAND, 'w').quit);
}

test "navigation keys: shift extends, Option = word, Cmd = line / document" {
    try std.testing.expectEqual(SpecialKey.left, decodeKey(KC_LEFT, 0, 0).special.?);
    try std.testing.expectEqual(SpecialKey.shift_left, decodeKey(KC_LEFT, FLAG_SHIFT, 0).special.?);
    try std.testing.expectEqual(SpecialKey.ctrl_left, decodeKey(KC_LEFT, FLAG_OPTION, 0).special.?);
    try std.testing.expectEqual(SpecialKey.ctrl_shift_right, decodeKey(KC_RIGHT, FLAG_OPTION | FLAG_SHIFT, 0).special.?);
    try std.testing.expectEqual(SpecialKey.home, decodeKey(KC_LEFT, FLAG_COMMAND, 0).special.?);
    try std.testing.expectEqual(SpecialKey.end, decodeKey(KC_RIGHT, FLAG_COMMAND, 0).special.?);
    try std.testing.expectEqual(SpecialKey.ctrl_home, decodeKey(KC_UP, FLAG_COMMAND, 0).special.?);
    try std.testing.expectEqual(SpecialKey.ctrl_end, decodeKey(KC_DOWN, FLAG_COMMAND, 0).special.?);
    try std.testing.expectEqual(SpecialKey.ctrl_backspace, decodeKey(KC_DELETE, FLAG_OPTION, 0).special.?);
    try std.testing.expectEqual(SpecialKey.backspace, decodeKey(KC_DELETE, 0, 0).special.?);
    try std.testing.expectEqual(SpecialKey.delete, decodeKey(KC_FORWARD_DELETE, 0, 0).special.?);
    try std.testing.expectEqual(SpecialKey.shift_tab, decodeKey(KC_TAB, FLAG_SHIFT, 0).special.?);
    try std.testing.expectEqual(SpecialKey.enter, decodeKey(KC_RETURN, 0, 0).special.?);
    try std.testing.expectEqual(SpecialKey.escape, decodeKey(KC_ESCAPE, 0, 0).special.?);
}

test "every special key is reachable from some mac key" {
    // The shared policy yields each SpecialKey through this table.
    var seen = std.EnumSet(SpecialKey).empty;
    const codes = [_]u16{ KC_RETURN, KC_TAB, KC_DELETE, KC_ESCAPE, KC_HOME, KC_PAGE_UP, KC_FORWARD_DELETE, KC_END, KC_PAGE_DOWN, KC_LEFT, KC_RIGHT, KC_DOWN, KC_UP };
    const flag_sets = [_]u64{ 0, FLAG_SHIFT, FLAG_OPTION, FLAG_OPTION | FLAG_SHIFT, FLAG_COMMAND };
    for (codes) |c| for (flag_sets) |f| if (decodeKey(c, f, 0).special) |sk| seen.insert(sk);
    for ("acxvyz") |ch| for ([_]u64{ FLAG_COMMAND, FLAG_COMMAND | FLAG_SHIFT }) |f| if (decodeKey(0, f, ch).special) |sk| seen.insert(sk);
    for (std.enums.values(SpecialKey)) |sk| {
        if (!seen.contains(sk)) std.debug.print("unreachable on mac: {s}\n", .{@tagName(sk)});
    }
    for (std.enums.values(SpecialKey)) |sk| try std.testing.expect(seen.contains(sk));
}

test "scroll: precise deltas pass through, wheel lines scale, signs flip" {
    const p = scrollDelta(0, 10, true);
    try std.testing.expectEqual(@as(f32, -10), p.y);
    const w = scrollDelta(2, -3, false);
    try std.testing.expectEqual(@as(f32, 48), w.y);
    try std.testing.expectEqual(@as(f32, -32), w.x);
}

test "utf16 offsets" {
    const s = "a\u{1F600}b"; // 1 + 2 units + 1
    try std.testing.expectEqual(@as(usize, 4), utf16Len(s));
    try std.testing.expectEqual(@as(usize, 1), utf16IndexToByte(s, 1));
    try std.testing.expectEqual(@as(usize, 5), utf16IndexToByte(s, 3));
    try std.testing.expectEqual(s.len, utf16IndexToByte(s, 99));
}

test "every cursor shape has a selector" {
    for (std.enums.values(teak.CursorShape)) |sh| try std.testing.expect(cursorSel(sh).public.len > 0);
}
