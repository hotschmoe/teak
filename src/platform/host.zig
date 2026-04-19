//! Host interface: window + input event source. A Host owns the window
//! and whatever mechanism produces events (Win32 message pump, X11 event
//! loop, zunk's rAF callbacks). It does NOT own the render loop — the
//! application drives `pollInputs` each frame and hands a
//! viewport-agnostic snapshot back.
//!
//! This file defines the shared types and a comptime validator. Concrete
//! implementations live in sibling files (win32.zig, wasm.zig, ...). Pick
//! one via the example's build.zig — Teak never links them itself.

const std = @import("std");

pub const SpecialKey = @import("../input/keys.zig").SpecialKey;

const text = @import("../core/text.zig");
pub const TextMeasurer = text.TextMeasurer;
pub const TextMetrics = text.TextMetrics;
pub const FontSpec = text.FontSpec;

/// Per-frame input snapshot returned by `Host.pollInputs`.
///
/// `mouse_x` / `mouse_y` are the current cursor position (state, not an
/// event). `mouse_down` / `mouse_up` are edge events — true only on the
/// frame the button transitioned. `chars` and `keys` are queues drained
/// and returned in receive order; the slices reference Host-internal
/// storage and are valid only until the next `pollInputs` call.
pub const InputState = struct {
    mouse_x: f32,
    mouse_y: f32,
    mouse_down: bool,
    mouse_up: bool,
    chars: []const u8,
    keys: []const SpecialKey,
    resized: bool,
    width: u32,
    height: u32,
};

/// Comptime contract. A Host must expose these declarations; `init`
/// signatures vary per backend and are NOT validated (some hosts take a
/// title, some take a canvas selector, etc.).
pub fn validateHost(comptime T: type) void {
    const required = [_][]const u8{ "deinit", "pollInputs", "shouldClose", "nativeHandle", "textMeasurer" };
    inline for (required) |name| {
        if (!@hasDecl(T, name)) {
            @compileError("Host '" ++ @typeName(T) ++ "' is missing declaration '" ++ name ++ "'");
        }
    }
}

test "validateHost accepts a minimal shape" {
    const Stub = struct {
        pub fn init() void {}
        pub fn deinit(_: *@This()) void {}
        pub fn pollInputs(_: *@This()) InputState {
            return std.mem.zeroes(InputState);
        }
        pub fn shouldClose(_: *const @This()) bool {
            return true;
        }
        pub fn nativeHandle(_: *@This()) void {}
        pub fn textMeasurer(_: *@This()) TextMeasurer {
            return .{ .ctx = undefined, .measure_fn = stubMeasure };
        }

        fn stubMeasure(_: *anyopaque, _: []const u8, _: FontSpec) TextMetrics {
            return .{ .width = 0, .height = 0, .ascent = 0, .descent = 0 };
        }
    };
    comptime validateHost(Stub);
}
