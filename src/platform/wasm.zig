//! Wasm host backed by zunk's `web.input` + `web.app` modules. Zunk
//! owns the rAF loop — it calls the app-exported `init`/`frame`/`resize`;
//! this Host's `pollInputs` snapshots zunk's shared-memory input state
//! into teak's `InputState`.
//!
//! Mouse edge events (`mouse_down`/`mouse_up`) are derived locally by
//! diffing the button state across polls — zunk reports current state,
//! not edges. Key press events come through zunk's `keys_pressed`
//! bitmap (edge-triggered for the current poll tick).

const std = @import("std");
const teak = @import("teak");
const zunk = @import("zunk");

const zinput = zunk.web.input;
const zapp = zunk.web.app;

pub const InputState = teak.InputState;
pub const SpecialKey = teak.SpecialKey;

pub const NativeHandle = struct {};

// Mapping from zunk.web.input.Key → teak.SpecialKey. Keys not in
// zunk's enum yet (Delete/Home/End) are tracked in
// docs/zunk-handoff.md as a follow-up ask.
const KeyMapping = struct { z: zinput.Key, t: SpecialKey };
const key_mappings = [_]KeyMapping{
    .{ .z = .backspace, .t = .backspace },
    .{ .z = .enter, .t = .enter },
    .{ .z = .tab, .t = .tab },
    .{ .z = .escape, .t = .escape },
    .{ .z = .arrow_left, .t = .left },
    .{ .z = .arrow_right, .t = .right },
    .{ .z = .arrow_up, .t = .up },
    .{ .z = .arrow_down, .t = .down },
};

pub const Host = struct {
    width: u32,
    height: u32,
    prev_left: bool = false,
    first_poll: bool = true,
    keys_buf: [16]SpecialKey = undefined,
    keys_len: usize = 0,

    pub fn init(title: []const u8, width: u32, height: u32) !Host {
        zinput.init();
        zapp.setTitle(title);
        return .{ .width = width, .height = height };
    }

    pub fn deinit(_: *Host) void {}

    pub fn pollInputs(self: *Host) InputState {
        zinput.poll();

        const mouse = zinput.getMouse();
        const cur_left = mouse.buttons.left;
        const mouse_down = !self.prev_left and cur_left;
        const mouse_up = self.prev_left and !cur_left;
        self.prev_left = cur_left;

        self.keys_len = 0;
        for (key_mappings) |m| {
            if (self.keys_len >= self.keys_buf.len) break;
            if (zinput.isKeyPressed(m.z)) {
                self.keys_buf[self.keys_len] = m.t;
                self.keys_len += 1;
            }
        }

        const vp = zinput.getViewportSize();
        const w = if (vp.w != 0) vp.w else self.width;
        const h = if (vp.h != 0) vp.h else self.height;
        const resized = self.first_poll or w != self.width or h != self.height;
        self.first_poll = false;
        self.width = w;
        self.height = h;

        return .{
            .mouse_x = mouse.x,
            .mouse_y = mouse.y,
            .mouse_down = mouse_down,
            .mouse_up = mouse_up,
            .chars = zinput.getTypedChars(),
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
};

comptime {
    teak.validateHost(Host);
}
