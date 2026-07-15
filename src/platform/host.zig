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

/// Async file dialog poll result. Returned by `pollFileDialogResult` for
/// requests submitted via `requestFileDialog` / `requestSaveFileDialog`.
/// Required because browser file pickers are async + gesture-gated and
/// can't fit the synchronous `openFileDialog` shape. Win32 still implements
/// the sync API and additionally supports the async API by completing
/// the request immediately and parking the result in a slot.
///
/// `pending` means the host is still waiting on the user / browser.
/// `ok` carries the chosen path (UTF-8, valid until the next poll for
/// the same id). `cancelled` is a terminal state — the host frees the
/// slot and a subsequent poll on the same id returns `pending` (treated
/// as "request unknown / already consumed").
pub const FileDialogPoll = union(enum) {
    pending: void,
    ok: []const u8,
    cancelled: void,
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
/// Host capability note: not every backend wires both axes today —
/// e.g. the wasm host currently reports vertical wheel only and stubs
/// `wheel_dx = 0`. Apps that care about horizontal wheel should be
/// designed to tolerate a zero on hosts without it; treat the
/// horizontal axis as best-effort across backends.
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
///   it via the GPU layer's `renderToWindow`. Single-window hosts
///   (wasm) return `null`.
/// - `pollSecondaryInputs(window_id)` returns the per-frame input
///   snapshot for the given secondary window, or `null` if the id is
///   invalid or the host is single-window. The primary window keeps
///   using the legacy `pollInputs()` — secondaries are additive.
/// - `closeSecondaryWindow(window_id)` destroys the window and frees
///   its slot. No-op on single-window hosts or invalid ids.
/// - `secondaryWindowHandle(window_id)` returns the `NativeHandle` for
///   a secondary window so the app can hand it to `gpu.openSecondarySurface`.
///   Returns `null` for invalid ids.
/// - `requestFileDialog(filter)` / `requestSaveFileDialog(filter)` submit
///   an async file dialog and return an opaque `u32` request id (0 = the
///   submission failed; valid ids are non-zero). The app polls the same
///   id via `pollFileDialogResult` each frame (or via a `Sub`) until the
///   union resolves to `.ok` or `.cancelled`. Win32 completes the request
///   immediately on the same call so the very first poll returns the
///   result; wasm dispatches to the browser's async file picker and
///   stays in `.pending` until the JS bridge fires the resolution
///   callback (zunk issue #14).
/// - `pollFileDialogResult(id)` returns `.pending` / `.ok(path)` /
///   `.cancelled` for the given request id. On a `.ok` / `.cancelled`
///   return the host MAY recycle the slot — apps must consume the path
///   immediately and not poll the same id again.
/// - `setTitle(text)` updates the main window's title bar (UTF-8 in).
///   Lets an app reflect dynamic state — e.g. a "* unsaved" marker or
///   the current document name. Native hosts call the OS window-title
///   API; the web host sets `document.title`. No-op is acceptable for
///   headless hosts.
/// - `scaleFactor()` reports the number of physical device pixels per
///   logical UI unit at the window's current DPI (1.0 = no scaling).
///   HARDLINE §4(d) surface extension, but kept **optional** in
///   `validateHost` (existence-checked only when present) so Hosts that
///   predate it — and `run.zig`'s test stubs — still satisfy the
///   contract. Per-host truth: Win32 returns `GetDpiForWindow/96` (which
///   is 1.0 while the process is DPI-*unaware*, the default today); X11
///   returns `Xft.dpi/96` from the X resource manager; wasm returns 1.0
///   (teak's web coordinate space is CSS pixels — zunk owns the
///   devicePixelRatio backing store internally). Nothing in the
///   framework consumes it yet; see docs/features/host.md "DPI and
///   scaling" for the end-to-end render-at-scale follow-up.
/// One required Host declaration + the signature the error message
/// quotes when it's missing or not a function. Receiver types and a
/// handful of return types (e.g. `nativeHandle`) are platform-specific,
/// so the validator checks *presence + callability* and names the
/// expected shape — it does not pin exact parameter types (that would
/// over-constrain the per-backend handle types).
const HostDecl = struct { name: []const u8, sig: []const u8 };

pub fn validateHost(comptime T: type) void {
    const tn = @typeName(T);
    const required = [_]HostDecl{
        .{ .name = "deinit", .sig = "fn(*Host) void" },
        .{ .name = "pollInputs", .sig = "fn(*Host) InputState" },
        .{ .name = "shouldClose", .sig = "fn(*const Host) bool" },
        .{ .name = "nativeHandle", .sig = "fn(*Host) NativeHandle" },
        .{ .name = "textMeasurer", .sig = "fn(*Host) TextMeasurer" },
        .{ .name = "clipboard", .sig = "fn(*Host) Clipboard" },
        .{ .name = "imeState", .sig = "fn(*const Host) ImeState" },
        .{ .name = "publishA11yTree", .sig = "fn(*Host, []const A11yNode) void" },
        .{ .name = "openFileDialog", .sig = "fn(*Host, FileDialogFilter) FileDialogResult" },
        .{ .name = "saveFileDialog", .sig = "fn(*Host, FileDialogFilter) FileDialogResult" },
        .{ .name = "requestFileDialog", .sig = "fn(*Host, FileDialogFilter) u32" },
        .{ .name = "requestSaveFileDialog", .sig = "fn(*Host, FileDialogFilter) u32" },
        .{ .name = "pollFileDialogResult", .sig = "fn(*Host, u32) FileDialogPoll" },
        .{ .name = "openSecondaryWindow", .sig = "fn(*Host, []const u8, u32, u32) ?WindowId" },
        .{ .name = "pollSecondaryInputs", .sig = "fn(*Host, u32) ?InputState" },
        .{ .name = "closeSecondaryWindow", .sig = "fn(*Host, u32) void" },
        .{ .name = "secondaryWindowHandle", .sig = "fn(*const Host, u32) ?NativeHandle" },
        // Update the window title bar from a UTF-8 string (e.g. an
        // "* unsaved" marker or the open document's name). See the
        // surface-extension note above.
        .{ .name = "setTitle", .sig = "fn(*Host, []const u8) void" },
        // Monotonic millisecond timestamp on the host's clock. Used by
        // subscriptions (`Sub.at(deadline_ms, msg)`) and by anything
        // else that needs a host-side wall-clock without violating
        // HARDLINE §3's "no wall-clock in view".
        .{ .name = "nowMs", .sig = "fn(*const Host) u64" },
    };
    inline for (required) |d| {
        if (!@hasDecl(T, d.name))
            @compileError("Host '" ++ tn ++ "' is missing declaration '" ++ d.name ++
                "' (expected " ++ d.sig ++ ")");
        if (@typeInfo(@TypeOf(@field(T, d.name))) != .@"fn")
            @compileError("Host '" ++ tn ++ "'." ++ d.name ++ " must be a function " ++
                "(expected " ++ d.sig ++ ")");
    }

    // Optional surface extensions — checked for callability only when the
    // Host declares them, so their absence is not a contract violation. A
    // Host may omit `scaleFactor` (defaults to a 1.0 assumption at the
    // orchestrator once it consumes the decl); if present it must be a fn.
    const optional = [_]HostDecl{
        .{ .name = "scaleFactor", .sig = "fn(*const Host) f32" },
    };
    inline for (optional) |d| {
        if (@hasDecl(T, d.name)) {
            if (@typeInfo(@TypeOf(@field(T, d.name))) != .@"fn")
                @compileError("Host '" ++ tn ++ "'." ++ d.name ++ " must be a function " ++
                    "(expected " ++ d.sig ++ ")");
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
        pub fn requestFileDialog(_: *@This(), _: FileDialogFilter) u32 {
            return 0;
        }
        pub fn requestSaveFileDialog(_: *@This(), _: FileDialogFilter) u32 {
            return 0;
        }
        pub fn pollFileDialogResult(_: *@This(), _: u32) FileDialogPoll {
            return .{ .cancelled = {} };
        }
        pub fn openSecondaryWindow(_: *@This(), _: []const u8, _: u32, _: u32) ?u32 {
            return null;
        }
        pub fn pollSecondaryInputs(_: *@This(), _: u32) ?InputState {
            return null;
        }
        pub fn closeSecondaryWindow(_: *@This(), _: u32) void {}
        pub fn secondaryWindowHandle(_: *const @This(), _: u32) ?void {
            return null;
        }
        pub fn setTitle(_: *@This(), _: []const u8) void {}
        pub fn nowMs(_: *const @This()) u64 {
            return 0;
        }
        pub fn scaleFactor(_: *const @This()) f32 {
            return 1.0;
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

test "validateHost accepts a Host omitting the optional scaleFactor" {
    // The optional surface extension must not be a contract requirement:
    // a Host that predates it (no `scaleFactor` decl) still validates.
    const NoScale = struct {
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
            return .{ .ctx = undefined, .measure_fn = m };
        }
        pub fn clipboard(_: *@This()) Clipboard {
            return .{ .ctx = undefined, .read_fn = r, .write_fn = w };
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
        pub fn requestFileDialog(_: *@This(), _: FileDialogFilter) u32 {
            return 0;
        }
        pub fn requestSaveFileDialog(_: *@This(), _: FileDialogFilter) u32 {
            return 0;
        }
        pub fn pollFileDialogResult(_: *@This(), _: u32) FileDialogPoll {
            return .{ .cancelled = {} };
        }
        pub fn openSecondaryWindow(_: *@This(), _: []const u8, _: u32, _: u32) ?u32 {
            return null;
        }
        pub fn pollSecondaryInputs(_: *@This(), _: u32) ?InputState {
            return null;
        }
        pub fn closeSecondaryWindow(_: *@This(), _: u32) void {}
        pub fn secondaryWindowHandle(_: *const @This(), _: u32) ?void {
            return null;
        }
        pub fn setTitle(_: *@This(), _: []const u8) void {}
        pub fn nowMs(_: *const @This()) u64 {
            return 0;
        }
        fn m(_: *anyopaque, _: []const u8, _: FontSpec) TextMetrics {
            return .{ .width = 0, .height = 0, .ascent = 0, .descent = 0 };
        }
        fn r(_: *anyopaque) []const u8 {
            return "";
        }
        fn w(_: *anyopaque, _: []const u8) void {}
    };
    comptime validateHost(NoScale);
}

test "InputState wheel_d{x,y} zero-default through std.mem.zeroes" {
    const z = std.mem.zeroes(InputState);
    try std.testing.expectEqual(@as(f32, 0), z.wheel_dx);
    try std.testing.expectEqual(@as(f32, 0), z.wheel_dy);
}
