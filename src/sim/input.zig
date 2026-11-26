//! See SRC.md, src/sim/input.zig.
const assert = @import("../assert.zig").assert;
const pointer = @import("../core/pointer.zig");
const keys = @import("../input/keys.zig");

pub const events_max = 48;
pub const text_samples = [_][]const u8{ "task", " ", "é日", "שלום", "e\u{0301}" };

pub const Event = union(enum) {
    move: [2]f32,
    down: pointer.Button,
    up: pointer.Button,
    wheel: [2]f32,
    key: keys.SpecialKey,
    text: u8,
    modifiers: pointer.Modifiers,
    shortcut: keys.Chord,
    resize: [2]u32,
    scale: f32,
    focus_loss,
};

pub const Frame = struct {
    advance_ms: u32 = 16,
    count: u8 = 0,
    events: [events_max]Event = undefined,

    pub fn push(self: *Frame, event: Event) error{EventLimit}!void {
        assert(self.count <= events_max);
        if (self.count == events_max) return error.EventLimit;
        self.events[self.count] = event;
        self.count += 1;
        assert(self.count <= events_max);
    }
};
