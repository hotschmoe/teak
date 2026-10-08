//! Shared per-window input accumulator for event-driven Hosts (Win32, X11).
//!
//! The OS delivers pointer/key/text events one at a time between two
//! `pollInputs` calls; the Host folds them into an `InputQueue` and hands
//! the loop one `InputState` per frame. Every host used to carry its own
//! copy of this bookkeeping (and its own key table); keeping it here means
//! button edges, UTF-8 text, wheel accumulation and the Shift/Ctrl key
//! policy behave identically on every backend. Polling hosts (wasm) reuse
//! the key policy (`resolveKey`) and the text queue.
//!
//! Pure data + arithmetic: no OS types, no allocation.

const std = @import("std");
const host = @import("host.zig");
const pointer = @import("../core/pointer.zig");
const keys = @import("../input/keys.zig");

const Buttons = pointer.Buttons;
const Button = pointer.Button;
const Modifiers = pointer.Modifiers;
const SpecialKey = keys.SpecialKey;

/// Host-neutral navigation / chord keys. Each backend maps its native key
/// codes onto this (a small switch) and `resolveKey` applies the
/// Shift/Ctrl policy once, so the `SpecialKey` variants (shift_left,
/// ctrl_a, ...) are derived in one place instead of per host.
pub const NavKey = enum {
    backspace,
    delete,
    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
    enter,
    tab,
    escape,
    f10,
    /// The Menu / Apps key.
    menu,
    // Letters that form editing chords. Plain letters are text, not keys:
    // they resolve to `null` unless Ctrl is held.
    a,
    c,
    x,
    v,
    y,
    z,
};

/// The `SpecialKey` for `k` under `mods`, or null when the combination is
/// not a special key (a plain letter, or Ctrl/Alt/Meta-less letter chord).
/// Shift extends motion keys and reverses Tab; Ctrl+letter is a chord; Ctrl
/// with Left/Right/Home/End/Backspace/Delete selects the word/document variants.
pub fn resolveKey(k: NavKey, mods: Modifiers) ?SpecialKey {
    const shift = mods.shift;
    const ctrl = mods.ctrl;
    return switch (k) {
        .backspace => if (ctrl) .ctrl_backspace else .backspace,
        .delete => if (ctrl) .ctrl_delete else .delete,
        .left => if (ctrl) (if (shift) .ctrl_shift_left else .ctrl_left) else if (shift) .shift_left else .left,
        .right => if (ctrl) (if (shift) .ctrl_shift_right else .ctrl_right) else if (shift) .shift_right else .right,
        .up => if (shift) .shift_up else .up,
        .down => if (shift) .shift_down else .down,
        .home => if (ctrl) (if (shift) .ctrl_shift_home else .ctrl_home) else if (shift) .shift_home else .home,
        .end => if (ctrl) (if (shift) .ctrl_shift_end else .ctrl_end) else if (shift) .shift_end else .end,
        .page_up => .page_up,
        .page_down => .page_down,
        .enter => .enter,
        .tab => if (shift) .shift_tab else .tab,
        .escape => .escape,
        .f10 => if (shift) .context_menu else .f10,
        .menu => .context_menu,
        .a => if (mods.ctrl) .ctrl_a else null,
        .c => if (mods.ctrl) .ctrl_c else null,
        .x => if (mods.ctrl) .ctrl_x else null,
        .v => if (mods.ctrl) .ctrl_v else null,
        .y => if (mods.ctrl) .ctrl_y else null,
        .z => if (!ctrl) null else if (shift) .ctrl_shift_z else .ctrl_z,
    };
}

pub const InputQueue = struct {
    pub const CHARS_CAP = 64;
    pub const KEYS_CAP = 32;

    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    /// Buttons held right now.
    buttons: Buttons = .{},
    /// Button edges since the last `finish` (a press and release inside one
    /// frame sets both; `buttons` then reads released).
    pressed: Buttons = .{},
    released: Buttons = .{},
    mods: Modifiers = .{},
    wheel_dx: f32 = 0,
    wheel_dy: f32 = 0,
    /// UTF-8 text typed this frame, whole code points only.
    chars: [CHARS_CAP]u8 = undefined,
    chars_len: usize = 0,
    keys: [KEYS_CAP]SpecialKey = undefined,
    keys_len: usize = 0,
    /// First half of a UTF-16 surrogate pair awaiting its partner
    /// (Win32 `WM_CHAR` delivers code units).
    pending_high: u16 = 0,
    /// True from an Alt press until any other key, text or button arrives;
    /// an Alt release while still clean is an `alt_tap`.
    alt_clean: bool = false,

    /// Drop last frame's text and keys. Call once at the top of a poll,
    /// before pumping events: the slices handed out by `finish` alias the
    /// queue's buffers and stay valid until this runs.
    pub fn beginFrame(self: *InputQueue) void {
        self.chars_len = 0;
        self.keys_len = 0;
    }

    pub fn pointerMoved(self: *InputQueue, x: f32, y: f32) void {
        self.mouse_x = x;
        self.mouse_y = y;
    }

    pub fn buttonDown(self: *InputQueue, b: Button) void {
        self.alt_clean = false;
        setButton(&self.buttons, b, true);
        setButton(&self.pressed, b, true);
    }

    pub fn buttonUp(self: *InputQueue, b: Button) void {
        setButton(&self.buttons, b, false);
        setButton(&self.released, b, true);
    }

    pub fn wheel(self: *InputQueue, dx: f32, dy: f32) void {
        self.wheel_dx += dx;
        self.wheel_dy += dy;
    }

    /// Alt went down. A following `altUp` with nothing in between queues `alt_tap`.
    pub fn altDown(self: *InputQueue) void {
        self.alt_clean = true;
    }

    /// Alt went up: queue `alt_tap` when no other input arrived since `altDown`.
    pub fn altUp(self: *InputQueue) void {
        if (self.alt_clean) {
            self.alt_clean = false;
            self.pushKey(.alt_tap);
        }
    }

    pub fn pushKey(self: *InputQueue, k: SpecialKey) void {
        self.alt_clean = false;
        if (self.keys_len < KEYS_CAP) {
            self.keys[self.keys_len] = k;
            self.keys_len += 1;
        }
    }

    /// Resolve a navigation/chord key under the current modifiers and queue it.
    pub fn pushNav(self: *InputQueue, k: NavKey) void {
        if (resolveKey(k, self.mods)) |sk| self.pushKey(sk);
    }

    /// Queue one typed code point as UTF-8. Control codes and invalid
    /// scalars are dropped (special keys own those); a code point that does
    /// not fit is dropped whole rather than split.
    pub fn pushCodepoint(self: *InputQueue, cp: u21) void {
        if (cp < 0x20 or cp == 0x7f) return;
        self.alt_clean = false;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return;
        if (self.chars_len + n > CHARS_CAP) return;
        @memcpy(self.chars[self.chars_len..][0..n], buf[0..n]);
        self.chars_len += n;
    }

    /// Queue already-encoded UTF-8 text, one code point at a time (so a
    /// full buffer never splits a character). Malformed input is skipped.
    pub fn pushText(self: *InputQueue, utf8: []const u8) void {
        if (!std.unicode.utf8ValidateSlice(utf8)) return;
        var it = std.unicode.Utf8View.initUnchecked(utf8).iterator();
        while (it.nextCodepoint()) |cp| self.pushCodepoint(cp);
    }

    /// Queue one UTF-16 code unit (Win32 `WM_CHAR`), pairing surrogates.
    pub fn pushUtf16Unit(self: *InputQueue, unit: u16) void {
        if (std.unicode.utf16IsHighSurrogate(unit)) {
            self.pending_high = unit;
            return;
        }
        if (std.unicode.utf16IsLowSurrogate(unit)) {
            const high = self.pending_high;
            self.pending_high = 0;
            if (high == 0) return;
            self.pushCodepoint(std.unicode.utf16DecodeSurrogatePair(&.{ high, unit }) catch return);
            return;
        }
        self.pending_high = 0;
        self.pushCodepoint(unit);
    }

    /// Build this frame's `InputState` and clear the per-frame edges and
    /// wheel accumulators. Text/key slices alias the queue; see `beginFrame`.
    pub fn finish(self: *InputQueue, resized: bool, width: u32, height: u32) host.InputState {
        const state: host.InputState = .{
            .mouse_x = self.mouse_x,
            .mouse_y = self.mouse_y,
            .buttons = self.buttons,
            .button_down = self.pressed,
            .button_up = self.released,
            .mouse_down = self.pressed.left,
            .mouse_up = self.released.left,
            .mods = self.mods,
            .wheel_dx = self.wheel_dx,
            .wheel_dy = self.wheel_dy,
            .chars = self.chars[0..self.chars_len],
            .keys = self.keys[0..self.keys_len],
            .resized = resized,
            .width = width,
            .height = height,
        };
        self.pressed = .{};
        self.released = .{};
        self.wheel_dx = 0;
        self.wheel_dy = 0;
        return state;
    }
};

fn setButton(set: *Buttons, b: Button, value: bool) void {
    switch (b) {
        .left => set.left = value,
        .middle => set.middle = value,
        .right => set.right = value,
        .none => {},
    }
}

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;

test "resolveKey applies the Shift / Ctrl policy" {
    const none: Modifiers = .{};
    const shift: Modifiers = .{ .shift = true };
    const ctrl: Modifiers = .{ .ctrl = true };

    try testing.expectEqual(SpecialKey.left, resolveKey(.left, none).?);
    try testing.expectEqual(SpecialKey.shift_left, resolveKey(.left, shift).?);
    try testing.expectEqual(SpecialKey.shift_home, resolveKey(.home, shift).?);
    try testing.expectEqual(SpecialKey.shift_end, resolveKey(.end, shift).?);
    try testing.expectEqual(SpecialKey.shift_tab, resolveKey(.tab, shift).?);
    try testing.expectEqual(SpecialKey.tab, resolveKey(.tab, none).?);
    try testing.expectEqual(SpecialKey.delete, resolveKey(.delete, none).?);
    try testing.expectEqual(SpecialKey.escape, resolveKey(.escape, shift).?);
    // Letters are text unless Ctrl is held.
    try testing.expect(resolveKey(.a, none) == null);
    try testing.expect(resolveKey(.a, shift) == null);
    try testing.expectEqual(SpecialKey.ctrl_a, resolveKey(.a, ctrl).?);
    try testing.expectEqual(SpecialKey.ctrl_c, resolveKey(.c, ctrl).?);
    try testing.expectEqual(SpecialKey.ctrl_x, resolveKey(.x, ctrl).?);
    try testing.expectEqual(SpecialKey.ctrl_v, resolveKey(.v, ctrl).?);
    try testing.expectEqual(SpecialKey.ctrl_y, resolveKey(.y, ctrl).?);
    try testing.expectEqual(SpecialKey.ctrl_z, resolveKey(.z, ctrl).?);
    const ctrl_shift: Modifiers = .{ .ctrl = true, .shift = true };
    try testing.expectEqual(SpecialKey.ctrl_shift_z, resolveKey(.z, ctrl_shift).?);
    try testing.expectEqual(SpecialKey.ctrl_left, resolveKey(.left, ctrl).?);
    try testing.expectEqual(SpecialKey.ctrl_shift_right, resolveKey(.right, ctrl_shift).?);
    try testing.expectEqual(SpecialKey.ctrl_home, resolveKey(.home, ctrl).?);
    try testing.expectEqual(SpecialKey.ctrl_shift_end, resolveKey(.end, ctrl_shift).?);
    try testing.expectEqual(SpecialKey.ctrl_backspace, resolveKey(.backspace, ctrl).?);
    try testing.expectEqual(SpecialKey.ctrl_delete, resolveKey(.delete, ctrl).?);
    try testing.expectEqual(SpecialKey.up, resolveKey(.up, ctrl).?);
}

test "InputQueue: a press and release inside one frame reports both edges" {
    var q: InputQueue = .{};
    q.beginFrame();
    q.pointerMoved(10, 20);
    q.buttonDown(.left);
    q.buttonUp(.left);
    q.buttonDown(.right);
    const in = q.finish(false, 100, 50);

    try testing.expect(in.button_down.left and in.button_up.left);
    try testing.expect(in.mouse_down and in.mouse_up);
    try testing.expect(!in.buttons.left and in.buttons.right);
    try testing.expect(in.button_down.right and !in.button_up.right);
    try testing.expectEqual(@as(f32, 10), in.mouse_x);

    // Edges clear after the frame; held state persists.
    q.beginFrame();
    const next = q.finish(false, 100, 50);
    try testing.expect(!next.button_down.any() and !next.button_up.any());
    try testing.expect(next.buttons.right);
}

test "InputQueue: middle and none buttons" {
    var q: InputQueue = .{};
    q.buttonDown(.middle);
    q.buttonDown(.none); // ignored
    const in = q.finish(false, 1, 1);
    try testing.expect(in.buttons.middle and in.button_down.middle);
    try testing.expect(!in.buttons.left and !in.mouse_down);
}

test "InputQueue: wheel accumulates and clears; mods pass through" {
    var q: InputQueue = .{};
    q.mods = .{ .ctrl = true };
    q.wheel(1, 2);
    q.wheel(3, -5);
    const in = q.finish(false, 1, 1);
    try testing.expectEqual(@as(f32, 4), in.wheel_dx);
    try testing.expectEqual(@as(f32, -3), in.wheel_dy);
    try testing.expect(in.mods.ctrl and !in.mods.shift);
    try testing.expectEqual(@as(f32, 0), q.finish(false, 1, 1).wheel_dy);
}

test "InputQueue: text is real UTF-8, whole code points, no control codes" {
    var q: InputQueue = .{};
    q.pushCodepoint('a');
    q.pushCodepoint(0x08); // backspace: a key, not text
    q.pushCodepoint(0xE9); // e-acute -> 2 bytes
    q.pushCodepoint(0x20AC); // euro -> 3 bytes
    q.pushCodepoint(0x1F600); // emoji -> 4 bytes
    q.pushText("\xC3\xB1"); // n-tilde
    q.pushText("\xFF\xFE"); // malformed: skipped
    try testing.expectEqualStrings("a\u{E9}\u{20AC}\u{1F600}\u{F1}", q.chars[0..q.chars_len]);
}

test "InputQueue: a code point that does not fit is dropped whole" {
    var q: InputQueue = .{};
    for (0..InputQueue.CHARS_CAP - 1) |_| q.pushCodepoint('x');
    q.pushCodepoint(0x20AC); // 3 bytes, 1 free: dropped, not split
    try testing.expectEqual(@as(usize, InputQueue.CHARS_CAP - 1), q.chars_len);
    q.pushCodepoint('y'); // an ASCII byte still fits
    try testing.expectEqual(@as(usize, InputQueue.CHARS_CAP), q.chars_len);
}

test "InputQueue: UTF-16 surrogate pairs decode to one code point" {
    var q: InputQueue = .{};
    q.pushUtf16Unit(0xD83D);
    q.pushUtf16Unit(0xDE00); // U+1F600
    q.pushUtf16Unit(0x00E9);
    q.pushUtf16Unit(0xDC00); // stray low surrogate: dropped
    try testing.expectEqualStrings("\u{1F600}\u{E9}", q.chars[0..q.chars_len]);
}

test "InputQueue: pushNav uses the live modifiers; keys queue in order" {
    var q: InputQueue = .{};
    q.pushNav(.left);
    q.mods = .{ .shift = true };
    q.pushNav(.left);
    q.pushNav(.a); // plain letter under Shift: text, not a key
    q.mods = .{ .ctrl = true };
    q.pushNav(.a);
    const in = q.finish(false, 1, 1);
    try testing.expectEqualSlices(SpecialKey, &.{ .left, .shift_left, .ctrl_a }, in.keys);
    q.beginFrame();
    try testing.expectEqual(@as(usize, 0), q.finish(false, 1, 1).keys.len);
}

test "InputQueue: a bare Alt tap queues alt_tap; Alt plus anything else does not" {
    var q: InputQueue = .{};
    q.altDown();
    q.altUp();
    try testing.expectEqualSlices(SpecialKey, &.{.alt_tap}, q.finish(false, 1, 1).keys);
    q.beginFrame();

    q.altDown();
    q.pushCodepoint('f'); // Alt+F: a chord, not a tap
    q.altUp();
    q.altDown();
    q.buttonDown(.left); // Alt+click
    q.altUp();
    q.altDown();
    q.pushNav(.left); // Alt+Left
    q.altUp();
    q.altUp(); // a release with no matching press is ignored
    const in = q.finish(false, 1, 1);
    try testing.expectEqualSlices(SpecialKey, &.{.left}, in.keys);
}

test "InputQueue: F10 resolves to a key" {
    var q: InputQueue = .{};
    q.pushNav(.f10);
    try testing.expectEqualSlices(SpecialKey, &.{.f10}, q.finish(false, 1, 1).keys);
}
