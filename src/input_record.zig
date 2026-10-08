//! Input record / replay file format (`TEAK_RECORD` / `TEAK_REPLAY`).
//!
//! A recording is the Host's per-frame `InputState` stream, NOT the Msgs it
//! produced (a Msg may borrow slices that die with its frame, and replaying
//! inputs re-runs the real routing, so a recording stays valid when the app's
//! Msg set changes). One text line per frame that had any input:
//!
//!     <frame> m=<x>,<y> b=<down>,<up> mod=<bits> w=<dx>,<dy> c=<hex utf8> k=<key>,<key>
//!
//! Every field after the frame number is optional. `m` is the pointer position
//! (written when it changed since the last recorded frame), `b` the button edges
//! (bitmask left=1 middle=2 right=4), `mod` the modifier bits (shift=1 ctrl=2
//! alt=4 meta=8, written when changed), `w` the accumulated wheel pixels, `c`
//! the typed UTF-8 as hex and `k` the special-key names (`SpecialKey` tags), in
//! order. Lines starting with `#` are comments. Frame numbers are the
//! runtime's own count (the first `frame()` call is frame 0) and increase.
//!
//! Pure data: no host, no clock, no allocation (fixed-size parse results).

const std = @import("std");
const keys = @import("input/keys.zig");
const pointer = @import("core/pointer.zig");

pub const max_chars = 64;
pub const max_keys = 32;

/// One frame's recorded input, as written to / parsed from a line.
pub const FrameRec = struct {
    frame: u32 = 0,
    /// Pointer position, present when it changed.
    move: ?[2]f32 = null,
    down: pointer.Buttons = .{},
    up: pointer.Buttons = .{},
    /// Modifier state, present when it changed.
    mods: ?pointer.Modifiers = null,
    wheel: [2]f32 = .{ 0, 0 },
    chars: [max_chars]u8 = undefined,
    chars_len: usize = 0,
    keys: [max_keys]keys.SpecialKey = undefined,
    keys_len: usize = 0,

    pub fn charsSlice(self: *const FrameRec) []const u8 {
        return self.chars[0..self.chars_len];
    }
    pub fn keysSlice(self: *const FrameRec) []const keys.SpecialKey {
        return self.keys[0..self.keys_len];
    }

    /// True when the frame carries nothing worth a line.
    pub fn isEmpty(self: *const FrameRec) bool {
        return self.move == null and !self.down.any() and !self.up.any() and self.mods == null and
            self.wheel[0] == 0 and self.wheel[1] == 0 and self.chars_len == 0 and self.keys_len == 0;
    }
};

fn buttonBits(b: pointer.Buttons) u8 {
    return @as(u8, @intFromBool(b.left)) | @as(u8, @intFromBool(b.middle)) << 1 | @as(u8, @intFromBool(b.right)) << 2;
}

fn bitsButtons(v: u8) pointer.Buttons {
    return .{ .left = v & 1 != 0, .middle = v & 2 != 0, .right = v & 4 != 0 };
}

fn modBits(m: pointer.Modifiers) u8 {
    return @as(u8, @intFromBool(m.shift)) | @as(u8, @intFromBool(m.ctrl)) << 1 |
        @as(u8, @intFromBool(m.alt)) << 2 | @as(u8, @intFromBool(m.meta)) << 3;
}

fn bitsMods(v: u8) pointer.Modifiers {
    return .{ .shift = v & 1 != 0, .ctrl = v & 2 != 0, .alt = v & 4 != 0, .meta = v & 8 != 0 };
}

/// Append one line (with newline) for `r`.
pub fn writeLine(w: *std.Io.Writer, r: *const FrameRec) std.Io.Writer.Error!void {
    try w.print("{d}", .{r.frame});
    if (r.move) |m| try w.print(" m={d},{d}", .{ m[0], m[1] });
    if (r.down.any() or r.up.any()) try w.print(" b={d},{d}", .{ buttonBits(r.down), buttonBits(r.up) });
    if (r.mods) |m| try w.print(" mod={d}", .{modBits(m)});
    if (r.wheel[0] != 0 or r.wheel[1] != 0) try w.print(" w={d},{d}", .{ r.wheel[0], r.wheel[1] });
    if (r.chars_len > 0) {
        try w.writeAll(" c=");
        for (r.charsSlice()) |c| try w.print("{x:0>2}", .{c});
    }
    if (r.keys_len > 0) {
        try w.writeAll(" k=");
        for (r.keysSlice(), 0..) |k, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeAll(@tagName(k));
        }
    }
    try w.writeByte('\n');
}

pub const ParseError = error{BadRecordLine};

/// Parse one line. Returns null for a blank line or a comment.
pub fn parseLine(line: []const u8) ParseError!?FrameRec {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;
    var it = std.mem.tokenizeScalar(u8, trimmed, ' ');
    const first = it.next() orelse return null;
    var r: FrameRec = .{ .frame = std.fmt.parseInt(u32, first, 10) catch return error.BadRecordLine };
    while (it.next()) |tok| {
        const eq = std.mem.indexOfScalar(u8, tok, '=') orelse return error.BadRecordLine;
        const key = tok[0..eq];
        const val = tok[eq + 1 ..];
        if (std.mem.eql(u8, key, "m")) {
            r.move = try parseF2(val);
        } else if (std.mem.eql(u8, key, "b")) {
            const p = try parseF2(val);
            r.down = bitsButtons(@intFromFloat(p[0]));
            r.up = bitsButtons(@intFromFloat(p[1]));
        } else if (std.mem.eql(u8, key, "mod")) {
            r.mods = bitsMods(std.fmt.parseInt(u8, val, 10) catch return error.BadRecordLine);
        } else if (std.mem.eql(u8, key, "w")) {
            r.wheel = try parseF2(val);
        } else if (std.mem.eql(u8, key, "c")) {
            if (val.len % 2 != 0 or val.len / 2 > max_chars) return error.BadRecordLine;
            r.chars_len = val.len / 2;
            _ = std.fmt.hexToBytes(r.chars[0..r.chars_len], val) catch return error.BadRecordLine;
        } else if (std.mem.eql(u8, key, "k")) {
            var kit = std.mem.splitScalar(u8, val, ',');
            while (kit.next()) |name| {
                if (r.keys_len == max_keys) return error.BadRecordLine;
                r.keys[r.keys_len] = std.meta.stringToEnum(keys.SpecialKey, name) orelse return error.BadRecordLine;
                r.keys_len += 1;
            }
        } else return error.BadRecordLine;
    }
    return r;
}

fn parseF2(s: []const u8) ParseError![2]f32 {
    const comma = std.mem.indexOfScalar(u8, s, ',') orelse return error.BadRecordLine;
    return .{
        std.fmt.parseFloat(f32, s[0..comma]) catch return error.BadRecordLine,
        std.fmt.parseFloat(f32, s[comma + 1 ..]) catch return error.BadRecordLine,
    };
}

/// Turns a stream of per-frame input into `FrameRec`s, tracking what changed
/// since the last frame (pointer position, modifiers).
pub const Tracker = struct {
    last_x: f32 = 0,
    last_y: f32 = 0,
    last_mods: pointer.Modifiers = .{},

    /// `input` is any struct with the `InputState` input fields. Returns null
    /// when the frame had no input worth recording.
    pub fn observe(self: *Tracker, frame: u32, input: anytype) ?FrameRec {
        var r: FrameRec = .{ .frame = frame };
        if (input.mouse_x != self.last_x or input.mouse_y != self.last_y) {
            r.move = .{ input.mouse_x, input.mouse_y };
            self.last_x = input.mouse_x;
            self.last_y = input.mouse_y;
        }
        r.down = input.button_down;
        r.up = input.button_up;
        if (modBits(input.mods) != modBits(self.last_mods)) {
            r.mods = input.mods;
            self.last_mods = input.mods;
        }
        r.wheel = .{ input.wheel_dx, input.wheel_dy };
        r.chars_len = @min(input.chars.len, max_chars);
        @memcpy(r.chars[0..r.chars_len], input.chars[0..r.chars_len]);
        r.keys_len = @min(input.keys.len, max_keys);
        @memcpy(r.keys[0..r.keys_len], input.keys[0..r.keys_len]);
        if (r.isEmpty()) return null;
        return r;
    }
};

test "writeLine and parseLine round-trip every field" {
    var r: FrameRec = .{
        .frame = 42,
        .move = .{ 100.5, 20 },
        .down = .{ .left = true },
        .up = .{ .left = true, .right = true },
        .mods = .{ .shift = true, .ctrl = true },
        .wheel = .{ 0, -48 },
    };
    r.chars_len = 3;
    @memcpy(r.chars[0..3], "h\xc3\xa9");
    r.keys_len = 2;
    r.keys[0] = .enter;
    r.keys[1] = .ctrl_shift_left;

    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeLine(&w, &r);
    const line = w.buffered();
    try std.testing.expectEqualStrings("42 m=100.5,20 b=1,5 mod=3 w=0,-48 c=68c3a9 k=enter,ctrl_shift_left\n", line);

    const back = (try parseLine(line)).?;
    try std.testing.expectEqual(@as(u32, 42), back.frame);
    try std.testing.expectEqual([2]f32{ 100.5, 20 }, back.move.?);
    try std.testing.expect(back.down.left and !back.down.right);
    try std.testing.expect(back.up.left and back.up.right);
    try std.testing.expect(back.mods.?.shift and back.mods.?.ctrl and !back.mods.?.alt);
    try std.testing.expectEqual([2]f32{ 0, -48 }, back.wheel);
    try std.testing.expectEqualStrings("h\xc3\xa9", back.charsSlice());
    try std.testing.expectEqual(@as(usize, 2), back.keys_len);
    try std.testing.expectEqual(keys.SpecialKey.ctrl_shift_left, back.keys[1]);
}

test "parseLine skips comments and rejects junk" {
    try std.testing.expect((try parseLine("# a comment")) == null);
    try std.testing.expect((try parseLine("   ")) == null);
    try std.testing.expectError(error.BadRecordLine, parseLine("x m=1,2"));
    try std.testing.expectError(error.BadRecordLine, parseLine("3 k=not_a_key"));
    try std.testing.expectError(error.BadRecordLine, parseLine("3 c=abc"));
    try std.testing.expectError(error.BadRecordLine, parseLine("3 zz=1"));
}

test "Tracker records only what changed" {
    const In = struct {
        mouse_x: f32 = 0,
        mouse_y: f32 = 0,
        button_down: pointer.Buttons = .{},
        button_up: pointer.Buttons = .{},
        mods: pointer.Modifiers = .{},
        wheel_dx: f32 = 0,
        wheel_dy: f32 = 0,
        chars: []const u8 = "",
        keys: []const keys.SpecialKey = &.{},
    };
    var t: Tracker = .{};
    try std.testing.expect(t.observe(0, In{}) == null);
    const a = t.observe(1, In{ .mouse_x = 5, .mouse_y = 6 }).?;
    try std.testing.expectEqual([2]f32{ 5, 6 }, a.move.?);
    // Same position again: nothing to record.
    try std.testing.expect(t.observe(2, In{ .mouse_x = 5, .mouse_y = 6 }) == null);
    const c = t.observe(3, In{ .mouse_x = 5, .mouse_y = 6, .chars = "x", .keys = &.{.enter} }).?;
    try std.testing.expect(c.move == null);
    try std.testing.expectEqualStrings("x", c.charsSlice());
    try std.testing.expectEqual(@as(usize, 1), c.keys_len);
}
