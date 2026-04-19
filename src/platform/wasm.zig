//! Wasm host backed by zunk's `web.input` + `web.app` modules. Zunk
//! owns the rAF loop; `pollInputs` snapshots zunk's shared-memory
//! state into teak's `InputState`.
//!
//! Mouse `mouse_down`/`mouse_up` are derived locally from diffs of the
//! button state because zunk reports held-state, not edges.
//!
//! Mouse coords are normalized from device pixels to CSS pixels by
//! dividing by devicePixelRatio. Zunk reports mouse_x/y in canvas
//! backing pixels (which it sets to clientWidth × DPR) while
//! viewport_width/height is reported in CSS pixels — at DPR > 1 the
//! two frames diverge and hit-tests miss every widget. Tracked in
//! docs/zunk-handoff.md §2.

const std = @import("std");
const teak = @import("teak");
const zunk = @import("zunk");

const zinput = zunk.web.input;
const zapp = zunk.web.app;

pub const InputState = teak.InputState;
pub const SpecialKey = teak.SpecialKey;
pub const TextMeasurer = teak.TextMeasurer;
pub const TextMetrics = teak.TextMetrics;
pub const FontSpec = teak.FontSpec;

pub const NativeHandle = struct {};

// Delete/Home/End are absent from zunk.web.input.Key; tracked in
// docs/zunk-handoff.md as a follow-up ask.
const key_mappings = [_]struct { from: zinput.Key, to: SpecialKey }{
    .{ .from = .backspace, .to = .backspace },
    .{ .from = .enter, .to = .enter },
    .{ .from = .tab, .to = .tab },
    .{ .from = .escape, .to = .escape },
    .{ .from = .arrow_left, .to = .left },
    .{ .from = .arrow_right, .to = .right },
    .{ .from = .arrow_up, .to = .up },
    .{ .from = .arrow_down, .to = .down },
};

pub const Host = struct {
    width: u32,
    height: u32,
    prev_left: bool = false,
    first_poll: bool = true,
    keys_buf: [16]SpecialKey = undefined,
    keys_len: usize = 0,
    chars_buf: [32]u8 = undefined,
    chars_len: usize = 0,

    pub fn init(title: []const u8, width: u32, height: u32) !Host {
        zinput.init();
        zapp.setTitle(title);
        return .{ .width = width, .height = height };
    }

    pub fn deinit(_: *Host) void {}

    pub fn pollInputs(self: *Host) InputState {
        zinput.poll();

        const mouse = zinput.getMouse();
        const dpr = zinput.getDevicePixelRatio();
        const inv_dpr: f32 = if (dpr > 0.0) 1.0 / dpr else 1.0;
        const cur_left = mouse.buttons.left;
        const mouse_down = !self.prev_left and cur_left;
        const mouse_up = self.prev_left and !cur_left;
        self.prev_left = cur_left;

        self.keys_len = 0;
        for (key_mappings) |m| {
            if (self.keys_len >= self.keys_buf.len) break;
            if (zinput.isKeyPressed(m.from)) {
                self.keys_buf[self.keys_len] = m.to;
                self.keys_len += 1;
            }
        }

        // Zunk pushes Backspace (8) and Enter (10) into typed_chars in
        // addition to reporting them as pressed keys. Without this filter,
        // backspace double-acts: it inserts char 8 then deletes one, and the
        // user sees nothing change. Drop ASCII control codes here — the
        // special-key path owns those events. Tracked upstream at
        // https://github.com/hotschmoe/zunk/issues/8.
        self.chars_len = 0;
        for (zinput.getTypedChars()) |c| {
            if (c < 0x20 or c == 0x7f) continue;
            if (self.chars_len >= self.chars_buf.len) break;
            self.chars_buf[self.chars_len] = c;
            self.chars_len += 1;
        }

        const vp = zinput.getViewportSize();
        const w = if (vp.w != 0) vp.w else self.width;
        const h = if (vp.h != 0) vp.h else self.height;
        const resized = self.first_poll or w != self.width or h != self.height;
        self.first_poll = false;
        self.width = w;
        self.height = h;

        return .{
            .mouse_x = mouse.x * inv_dpr,
            .mouse_y = mouse.y * inv_dpr,
            .mouse_down = mouse_down,
            .mouse_up = mouse_up,
            .chars = self.chars_buf[0..self.chars_len],
            .keys = self.keys_buf[0..self.keys_len],
            .resized = resized,
            .width = w,
            .height = h,
        };
    }

    pub fn shouldClose(_: *const Host) bool {
        return false;
    }

    pub fn nativeHandle(_: *const Host) NativeHandle {
        return .{};
    }

    /// WS1 stub — mirrors the CHAR_WIDTH approximation. WS4 replaces
    /// with `zunk.web.gpu.measureText`.
    pub fn textMeasurer(self: *Host) TextMeasurer {
        return .{ .ctx = @ptrCast(self), .measure_fn = stubMeasure };
    }

    fn stubMeasure(_: *anyopaque, text_bytes: []const u8, _: FontSpec) TextMetrics {
        return .{
            .width = @as(f32, @floatFromInt(text_bytes.len)) * 10,
            .height = 20,
            .ascent = 15,
            .descent = 5,
        };
    }
};

comptime {
    teak.validateHost(Host);
}
