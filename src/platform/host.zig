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

/// Clipboard surface — Host-owned because clipboards are an OS concept.
/// `read` returns a UTF-8 slice valid until the next `read` call (Host
/// owns the buffer). `write` copies the bytes into the OS clipboard. A
/// no-op implementation is acceptable for headless / wasm hosts (return
/// "" and discard writes).
pub const Clipboard = struct {
    ctx: *anyopaque,
    read_fn: *const fn (ctx: *anyopaque) []const u8,
    write_fn: *const fn (ctx: *anyopaque, text: []const u8) void,

    pub fn read(self: Clipboard) []const u8 {
        return self.read_fn(self.ctx);
    }

    pub fn write(self: Clipboard, t: []const u8) void {
        self.write_fn(self.ctx, t);
    }
};

/// IME composition state. `text` is the pre-commit composition buffer
/// (UTF-8); `cursor` is the byte offset inside it. When `active` is
/// false the app should display the regular cursor and ignore `text`.
/// Hosts that don't support IME (yet) return `.{ .active = false }`.
pub const ImeState = struct {
    active: bool = false,
    text: []const u8 = "",
    cursor: usize = 0,
};

pub const A11yNode = @import("../input/a11y.zig").A11yNode;

/// File dialog result. `path` is UTF-8; lives in the Host's internal
/// buffer and is valid until the next dialog call. null when the user
/// cancels.
pub const FileDialogResult = ?[]const u8;

/// File dialog filter — `name` is shown in the OS dialog, `pattern` is
/// a `;`-separated list of `*.ext` globs (matches the Win32 convention;
/// hosts that need different semantics translate at the call site).
pub const FileDialogFilter = struct {
    name: []const u8 = "All files",
    pattern: []const u8 = "*.*",
};

/// Per-frame input snapshot returned by `Host.pollInputs`.
///
/// `mouse_x` / `mouse_y` are the current cursor position (state, not an
/// event). `mouse_down` / `mouse_up` are edge events — true only on the
/// frame the button transitioned. `chars` and `keys` are queues drained
/// and returned in receive order; the slices reference Host-internal
/// storage and are valid only until the next `pollInputs` call.
///
/// `wheel_dx` / `wheel_dy` are accumulated pixels of intended scroll
/// since the previous `pollInputs`. Sign convention matches the DOM
/// `WheelEvent.deltaX` / `deltaY`: positive `wheel_dy` means the user
/// wants the content to scroll **down** (visible viewport advances
/// toward higher y) and positive `wheel_dx` means scroll right. Hosts
/// translate native wheel notches into pixels (typically 120 raw units
/// = ~48 px on Win32). Zero when no wheel events arrived this frame.
pub const InputState = struct {
    mouse_x: f32,
    mouse_y: f32,
    mouse_down: bool,
    mouse_up: bool,
    wheel_dx: f32,
    wheel_dy: f32,
    chars: []const u8,
    keys: []const SpecialKey,
    resized: bool,
    width: u32,
    height: u32,
};

/// Comptime contract. A Host must expose these declarations; `init`
/// signatures vary per backend and are NOT validated (some hosts take a
/// title, some take a canvas selector, etc.).
///
/// Surface extensions (HARDLINE §4(d)) — added in functional-gaps push:
/// - `clipboard()` returns a `Clipboard` vtable for OS-level cut/copy/paste.
/// - `imeState()` returns the current IME composition snapshot.
/// - `publishA11yTree(nodes)` hands the accessibility tree to whatever
///   screen-reader API the platform exposes (UI Automation on Windows,
///   AT-SPI on Linux, mirrored DOM on web). No-op on hosts without one.
/// - `openFileDialog(filter)` / `saveFileDialog(filter)` block until the
///   user picks a path. Return `null` on cancel. Native hosts call the
///   OS file picker; web stubs return `null` (browser file APIs need a
///   completely different flow).
/// - `openSecondaryWindow(title, w, h)` returns an opaque window handle
///   for a second top-level window sharing this Host's event source.
///   Tracked as a Host-internal id; the app holds it and renders into
///   it via the GPU layer's `renderToWindow`. Stub-only for now;
///   single-window hosts return `null`.
pub fn validateHost(comptime T: type) void {
    const required = [_][]const u8{
        "deinit",
        "pollInputs",
        "shouldClose",
        "nativeHandle",
        "textMeasurer",
        "clipboard",
        "imeState",
        "publishA11yTree",
        "openFileDialog",
        "saveFileDialog",
        "openSecondaryWindow",
        // Monotonic millisecond timestamp on the host's clock. Used by
        // subscriptions (`Sub.at(deadline_ms, msg)`) and by anything
        // else that needs a host-side wall-clock without violating
        // HARDLINE §3's "no wall-clock in view".
        "nowMs",
    };
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
        pub fn clipboard(_: *@This()) Clipboard {
            return .{ .ctx = undefined, .read_fn = stubRead, .write_fn = stubWrite };
        }
        pub fn imeState(_: *const @This()) ImeState {
            return .{};
        }
        pub fn publishA11yTree(_: *@This(), _: []const A11yNode) void {}
        pub fn openFileDialog(_: *@This(), _: FileDialogFilter) FileDialogResult {
            return null;
        }
        pub fn saveFileDialog(_: *@This(), _: FileDialogFilter) FileDialogResult {
            return null;
        }
        pub fn openSecondaryWindow(_: *@This(), _: []const u8, _: u32, _: u32) ?u32 {
            return null;
        }
        pub fn nowMs(_: *const @This()) u64 {
            return 0;
        }

        fn stubMeasure(_: *anyopaque, _: []const u8, _: FontSpec) TextMetrics {
            return .{ .width = 0, .height = 0, .ascent = 0, .descent = 0 };
        }
        fn stubRead(_: *anyopaque) []const u8 {
            return "";
        }
        fn stubWrite(_: *anyopaque, _: []const u8) void {}
    };
    comptime validateHost(Stub);
}

test "InputState wheel_d{x,y} zero-default through std.mem.zeroes" {
    const z = std.mem.zeroes(InputState);
    try std.testing.expectEqual(@as(f32, 0), z.wheel_dx);
    try std.testing.expectEqual(@as(f32, 0), z.wheel_dy);
}
