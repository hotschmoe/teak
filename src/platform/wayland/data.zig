//! Display-free decoding for the Wayland host: everything that turns raw
//! protocol values (button codes, axis events, keysyms, key-repeat timing,
//! data-offer mime types, scale announcements) into teak input, so it can be
//! unit-tested with synthetic events. `wayland.zig` is the thin glue that
//! feeds it from libwayland callbacks.

const std = @import("std");
const teak = @import("teak");
const keysym = @import("../keysym.zig");

const InputQueue = teak.InputQueue;
const Modifiers = teak.Modifiers;

// ── Pointer ────────────────────────────────────────────────────────

pub const BTN_LEFT: u32 = 0x110;
pub const BTN_RIGHT: u32 = 0x111;
pub const BTN_MIDDLE: u32 = 0x112;

pub fn buttonFromCode(code: u32) ?teak.Button {
    return switch (code) {
        BTN_LEFT => .left,
        BTN_RIGHT => .right,
        BTN_MIDDLE => .middle,
        else => null,
    };
}

/// Pixels of intended scroll per wheel notch, matching X11 / Win32.
pub const PIXELS_PER_NOTCH: f32 = 48;

pub const Axis = enum(u32) { vertical = 0, horizontal = 1 };

/// Collects `wl_pointer` axis events until the `frame` event. A wheel sends
/// `axis_value120` (120 per notch) next to a continuous `axis`; a touchpad
/// sends only the continuous one. When notches are present they win (so a
/// wheel feels like the other hosts), otherwise the continuous value is used
/// as logical pixels.
pub const WheelAccum = struct {
    cont: [2]f32 = .{ 0, 0 },
    notch: [2]f32 = .{ 0, 0 },

    pub fn axis(self: *WheelAccum, a: Axis, value: f32) void {
        self.cont[@backingInt(a)] += value;
    }

    pub fn value120(self: *WheelAccum, a: Axis, v: i32) void {
        self.notch[@backingInt(a)] += @as(f32, @floatFromInt(v)) / 120.0;
    }

    /// Deliver and reset: positive = scroll down / right, as `InputState`.
    pub fn frame(self: *WheelAccum, q: *InputQueue) void {
        var d: [2]f32 = undefined;
        for (0..2) |i| d[i] = if (self.notch[i] != 0) self.notch[i] * PIXELS_PER_NOTCH else self.cont[i];
        self.* = .{};
        if (d[0] != 0 or d[1] != 0) q.wheel(d[1], d[0]);
    }
};

// ── Keyboard ───────────────────────────────────────────────────────

pub const KeyResult = struct {
    /// The key repeats while held (nav keys and text; chords do not).
    repeats: bool = false,
    /// Ctrl+V: the host may start an asynchronous paste.
    paste: bool = false,
};

/// Fold one key press into the queue: navigation keys, Ctrl chords, then text
/// (`utf8` is what xkbcommon produced for the key; whole code points).
pub fn decodeKey(q: *InputQueue, mods: Modifiers, sym: u32, utf8: []const u8) KeyResult {
    q.mods = mods;
    if (keysym.navFromKeysym(sym)) |nk| {
        q.pushNav(nk);
        return .{ .repeats = true };
    }
    if (mods.ctrl) {
        // Ctrl chords never type their control character.
        if (keysym.chordFromKeysym(sym)) |nk| {
            q.pushNav(nk);
            return .{ .paste = nk == .v };
        }
        return .{};
    }
    if (utf8.len == 0 or !std.unicode.utf8ValidateSlice(utf8)) return .{};
    var it = std.unicode.Utf8View.initUnchecked(utf8).iterator();
    while (it.nextCodepoint()) |cp| q.pushCodepoint(cp);
    return .{ .repeats = true };
}

/// Client-side key repeat (Wayland compositors only report rate/delay).
pub const Repeat = struct {
    key: u32 = 0,
    active: bool = false,
    next_ms: u64 = 0,
    delay_ms: u32 = 600,
    /// Repeats per second; 0 disables repeat.
    rate: u32 = 25,

    pub fn press(self: *Repeat, key: u32, now: u64) void {
        if (self.rate == 0) return;
        self.key = key;
        self.active = true;
        self.next_ms = now + self.delay_ms;
    }

    pub fn release(self: *Repeat, key: u32) void {
        if (self.active and self.key == key) self.active = false;
    }

    /// How many repeats are due at `now` (advances the schedule; capped so a
    /// stalled frame does not flood the queue).
    pub fn due(self: *Repeat, now: u64) u32 {
        if (!self.active or self.rate == 0 or now < self.next_ms) return 0;
        const period: u64 = @max(1000 / self.rate, 1);
        const n: u64 = @min((now - self.next_ms) / period + 1, 4);
        self.next_ms += n * period;
        if (now >= self.next_ms) self.next_ms = now + period; // dropped the backlog
        return @intCast(n);
    }
};

// ── Data offers (clipboard / drag and drop) ────────────────────────

/// What an offer advertises, accumulated from `wl_data_offer.offer` events.
pub const OfferFlags = struct {
    utf8: bool = false,
    text_plain: bool = false,
    png: bool = false,
    uri_list: bool = false,

    pub fn note(self: *OfferFlags, mime: []const u8) void {
        if (eqi(mime, "text/plain;charset=utf-8") or eqi(mime, "UTF8_STRING")) self.utf8 = true;
        if (eqi(mime, "text/plain") or eqi(mime, "TEXT") or eqi(mime, "STRING")) self.text_plain = true;
        if (std.mem.eql(u8, mime, "image/png")) self.png = true;
        if (std.mem.eql(u8, mime, "text/uri-list")) self.uri_list = true;
    }

    pub fn hasText(self: OfferFlags) bool {
        return self.utf8 or self.text_plain;
    }
};

fn eqi(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

pub const Pick = enum { text_utf8, text_plain, png };

/// What to ask a clipboard offer for: text wins over an image.
pub fn pickForPaste(f: OfferFlags) ?struct { pick: Pick, mime: [:0]const u8 } {
    if (f.utf8) return .{ .pick = .text_utf8, .mime = "text/plain;charset=utf-8" };
    if (f.text_plain) return .{ .pick = .text_plain, .mime = "text/plain" };
    if (f.png) return .{ .pick = .png, .mime = "image/png" };
    return null;
}

// ── Scale ──────────────────────────────────────────────────────────

pub const ScaleInputs = struct {
    /// `TEAK_SCALE` override.
    env: ?f32 = null,
    /// `wp_fractional_scale_v1.preferred_scale` (units of 1/120).
    fractional_120: ?u32 = null,
    /// Largest `wl_output.scale` seen (integer).
    output: u32 = 1,
    /// A `wp_viewporter` is available: any scale can be honoured by
    /// sizing the buffer and declaring the logical destination size.
    viewporter: bool = false,
};

/// The effective display scale. Without a viewporter only integer scales
/// work (`wl_surface.set_buffer_scale`), so the value is rounded.
pub fn effectiveScale(in: ScaleInputs) f32 {
    var s: f32 = 1;
    if (in.env) |e| {
        s = e;
    } else if (in.fractional_120) |f| {
        s = @as(f32, @floatFromInt(f)) / 120.0;
    } else {
        s = @floatFromInt(@max(in.output, 1));
    }
    s = std.math.clamp(s, 1, 8);
    if (!in.viewporter) s = @max(1, @round(s));
    return s;
}

/// `wl_surface.set_buffer_scale` value to declare: 1 when a viewport carries
/// the scale, else the (integer) scale itself.
pub fn bufferScale(scale: f32, viewporter: bool) i32 {
    return if (viewporter) 1 else @intFromFloat(@round(scale));
}

// ── tests ──────────────────────────────────────────────────────────

test "buttonFromCode" {
    try std.testing.expectEqual(teak.Button.left, buttonFromCode(BTN_LEFT).?);
    try std.testing.expectEqual(teak.Button.middle, buttonFromCode(BTN_MIDDLE).?);
    try std.testing.expect(buttonFromCode(0x113) == null);
}

test "WheelAccum: notches win over continuous, touchpad passes through" {
    var q: InputQueue = .{};
    var w: WheelAccum = .{};
    // Wheel: continuous 15 plus one notch (120) -> 48 px, not 15.
    w.axis(.vertical, 15);
    w.value120(.vertical, 120);
    w.frame(&q);
    try std.testing.expectEqual(@as(f32, 48), q.wheel_dy);
    q.wheel_dy = 0;
    // Touchpad: continuous only, horizontal and vertical.
    w.axis(.horizontal, -3.5);
    w.axis(.vertical, 7);
    w.frame(&q);
    try std.testing.expectEqual(@as(f32, 7), q.wheel_dy);
    try std.testing.expectEqual(@as(f32, -3.5), q.wheel_dx);
    // Accumulator resets after a frame.
    q.wheel_dx = 0;
    q.wheel_dy = 0;
    w.frame(&q);
    try std.testing.expectEqual(@as(f32, 0), q.wheel_dy);
}

test "decodeKey: nav, chords, text, shift variants" {
    var q: InputQueue = .{};
    q.beginFrame();
    var r = decodeKey(&q, .{}, keysym.Left, "");
    try std.testing.expect(r.repeats);
    r = decodeKey(&q, .{ .shift = true }, keysym.Left, "");
    r = decodeKey(&q, .{ .ctrl = true }, 'v', "\x16");
    try std.testing.expect(r.paste and !r.repeats);
    _ = decodeKey(&q, .{ .ctrl = true }, 'q', "\x11"); // unknown chord: nothing typed
    r = decodeKey(&q, .{}, 0xe9, "é");
    try std.testing.expect(r.repeats);
    _ = decodeKey(&q, .{}, 'a', "a");
    try std.testing.expectEqual(@as(usize, 3), q.keys_len);
    try std.testing.expectEqual(teak.SpecialKey.left, q.keys[0]);
    try std.testing.expectEqual(teak.SpecialKey.shift_left, q.keys[1]);
    try std.testing.expectEqual(teak.SpecialKey.ctrl_v, q.keys[2]);
    try std.testing.expectEqualStrings("éa", q.chars[0..q.chars_len]);
}

test "Repeat: delay, rate, release, backlog cap" {
    var r: Repeat = .{ .delay_ms = 500, .rate = 20 }; // period 50 ms
    r.press(30, 1000);
    try std.testing.expectEqual(@as(u32, 0), r.due(1499));
    try std.testing.expectEqual(@as(u32, 1), r.due(1500));
    try std.testing.expectEqual(@as(u32, 0), r.due(1549));
    try std.testing.expectEqual(@as(u32, 3), r.due(1650)); // 1550, 1600, 1650
    // A long stall emits at most 4 and drops the rest.
    try std.testing.expectEqual(@as(u32, 4), r.due(9999));
    try std.testing.expectEqual(@as(u32, 0), r.due(10000));
    r.release(31); // a different key does not stop it
    try std.testing.expect(r.active);
    r.release(30);
    try std.testing.expectEqual(@as(u32, 0), r.due(20000));
    var off: Repeat = .{ .rate = 0 };
    off.press(1, 0);
    try std.testing.expect(!off.active);
}

test "OfferFlags / pickForPaste prefer text over png" {
    var f: OfferFlags = .{};
    f.note("image/png");
    try std.testing.expectEqual(Pick.png, pickForPaste(f).?.pick);
    f.note("text/plain");
    try std.testing.expectEqual(Pick.text_plain, pickForPaste(f).?.pick);
    f.note("text/plain;charset=utf-8");
    try std.testing.expectEqual(Pick.text_utf8, pickForPaste(f).?.pick);
    f.note("text/uri-list");
    try std.testing.expect(f.uri_list and f.hasText());
    try std.testing.expect(pickForPaste(.{}) == null);
}

test "effectiveScale: env > fractional > output; integers without a viewporter" {
    try std.testing.expectEqual(@as(f32, 2), effectiveScale(.{ .env = 2, .fractional_120 = 180, .viewporter = true }));
    try std.testing.expectEqual(@as(f32, 1.5), effectiveScale(.{ .fractional_120 = 180, .viewporter = true }));
    try std.testing.expectEqual(@as(f32, 2), effectiveScale(.{ .fractional_120 = 180, .viewporter = false }));
    try std.testing.expectEqual(@as(f32, 2), effectiveScale(.{ .output = 2 }));
    try std.testing.expectEqual(@as(f32, 1), effectiveScale(.{}));
    try std.testing.expectEqual(@as(i32, 1), bufferScale(1.5, true));
    try std.testing.expectEqual(@as(i32, 2), bufferScale(2, false));
}
