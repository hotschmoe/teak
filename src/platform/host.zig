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
pub const Buttons = pointer.Buttons;
pub const Modifiers = pointer.Modifiers;

const pointer = @import("../core/pointer.zig");
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

pub const CursorShape = @import("../core/cursor.zig").CursorShape;

pub const A11yNode = @import("../input/a11y.zig").A11yNode;

pub const A11yActionKind = @import("../input/a11y.zig").ActionKind;
pub const A11yAction = @import("../input/a11y.zig").Action;
const effects = @import("../core/effects.zig");
pub const Effect = effects.Effect;
pub const EffectResult = effects.EffectResult;
pub const EffectSubmit = effects.EffectSubmit;

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

/// One synthetic input event, injected by the agent control channel
/// (`src/control.zig`) through the Host's optional `injectInput`. It lands in
/// the same queue real OS events do, so injected input takes exactly the path
/// real input takes (HARDLINE: no second mutation path).
pub const InjectEvent = union(enum) {
    move: [2]f32,
    down: pointer.Button,
    up: pointer.Button,
    /// DOM sign convention: positive `dy` scrolls content down.
    wheel: [2]f32,
    /// UTF-8 text; at most `InputQueue.CHARS_CAP` bytes land per frame.
    chars: []const u8,
    key: SpecialKey,
    mods: Modifiers,
};

/// Per-frame input snapshot returned by `Host.pollInputs`.
///
/// `mouse_x` / `mouse_y` are the current cursor position (state, not an
/// event), in logical pixels relative to the window's client area.
///
/// Buttons: `buttons` is what is held now; `button_down` / `button_up` are
/// the edges that happened since the previous poll — a press and release
/// inside one frame sets both (and `buttons` then reads released), so a
/// fast click is never lost. `mouse_down` / `mouse_up` are the left-button
/// edges (== `button_down.left` / `button_up.left`), kept for the
/// click-only code path. `mods` is the Shift/Ctrl/Alt/Meta state at the
/// time of the most recent input event.
///
/// `chars` is UTF-8 text typed this frame (whole code points, no control
/// codes, no Ctrl/Cmd chords); `keys` is the special-key queue (arrows,
/// Delete/Home/End, Shift-extended motion, Ctrl+A/C/X/V/Y/Z, Tab, Escape,
/// Enter...). Both are drained and returned in receive order; the slices
/// reference Host-internal storage and are valid only until the next
/// `pollInputs` call.
///
/// `wheel_dx` / `wheel_dy` are accumulated pixels of intended scroll
/// since the previous `pollInputs`. Sign convention matches the DOM
/// `WheelEvent.deltaX` / `deltaY`: positive `wheel_dy` means the user
/// wants the content to scroll **down** (visible viewport advances
/// toward higher y) and positive `wheel_dx` means scroll right. Hosts
/// translate native wheel notches into pixels (typically 120 raw units
/// = ~48 px on Win32). Zero when no wheel events arrived this frame. A
/// trackpad pinch on the web arrives as a wheel event with `mods.ctrl` set.
pub const InputState = struct {
    mouse_x: f32,
    mouse_y: f32,
    buttons: Buttons,
    button_down: Buttons,
    button_up: Buttons,
    mouse_down: bool,
    mouse_up: bool,
    mods: Modifiers,
    wheel_dx: f32,
    wheel_dy: f32,
    chars: []const u8,
    keys: []const SpecialKey,
    resized: bool,
    width: u32,
    height: u32,
};

/// One Host declaration + the signature the error message quotes when it is
/// missing or not a function. Receiver types and a handful of return types
/// (e.g. `nativeHandle`) are platform-specific, so the validator checks
/// *presence + callability* and names the expected shape — it does not pin
/// exact parameter types (that would over-constrain the per-backend handle
/// types).
const HostDecl = struct { name: []const u8, sig: []const u8 };

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
/// - Optional `waitEvents(timeout_ms: u32) void` (NOT checked by
///   `validateHost`): event-driven idle. `teak.run` calls it after a frame
///   that did nothing (`Runtime.quiet`, see `RunOptions.idle_skip`); the Host
///   should block until an input event arrives (including resize / expose,
///   which must surface as `InputState.resized`), an async effect result is
///   ready, or `timeout_ms` elapses — then return. Hosts without it keep
///   polling at their own pace (the skipped frames are still nearly free).
///   X11: `XPending` + `poll` on the connection fd; Win32:
///   `MsgWaitForMultipleObjects`; web: n/a (rAF drives `frame`).
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
///   This is the one scale API: apps pass it to the Gpu as
///   `InitOptions.scale`, and when it changes at runtime (Win32
///   `WM_DPICHANGED`) the run loop forwards the new value to `Gpu.setScale`.
/// - `setCursor(shape)` — **optional**: show the OS mouse cursor for a
///   `CursorShape`. `teak.run` calls it only when the shape picked from
///   the hovered cmd (or the App's `cursorFor` hook) changes. X11 maps to
///   XCursor theme names (font cursors as fallback), Win32 to `IDC_*` via
///   `WM_SETCURSOR`, web to CSS `cursor` through zunk.
/// - `submit(effect)` / `pollEffectResults(buf)` — the declarative-effects
///   surface (HARDLINE §2 hatch 7, docs/features/effects.md). **Optional as
///   a pair** (a Host with neither answers every effect as unsupported;
///   declaring only one is a compile error):
///   `submit(*Host, Effect) EffectSubmit` starts one effect. The slices
///   inside the effect are valid only during the call — copy what an async
///   request needs. Fire-and-forget effects (`storage_set`,
///   `write_clipboard`) are performed here and never answered.
///   `pollEffectResults(*Host, []EffectResult) usize` fills `buf` with the
///   results that arrived (async completions plus unsolicited
///   `dropped` / `pasted_text`) and returns the count; the result slices
///   stay valid until the Host's next `pollInputs` call (the runtime
///   dispatches them within the same frame). Called once per frame, after
///   key routing, so `Clipboard.read` can claim a paste first.
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
    // `submit` and `pollEffectResults` come as a pair.
    const optional = [_]HostDecl{
        .{ .name = "scaleFactor", .sig = "fn(*const Host) f32" },
        // Assistive-technology requests (web DOM mirror, UIA patterns): fills
        // `out` and returns the count; called once per frame before input routing.
        .{ .name = "pollA11yActions", .sig = "fn(*Host, []A11yAction) usize" },
        .{ .name = "setCursor", .sig = "fn(*Host, CursorShape) void" },
        .{ .name = "submit", .sig = "fn(*Host, Effect) EffectSubmit" },
        .{ .name = "pollEffectResults", .sig = "fn(*Host, []EffectResult) usize" },
    };
    inline for (optional) |d| {
        if (@hasDecl(T, d.name)) {
            if (@typeInfo(@TypeOf(@field(T, d.name))) != .@"fn")
                @compileError("Host '" ++ tn ++ "'." ++ d.name ++ " must be a function " ++
                    "(expected " ++ d.sig ++ ")");
        }
    }
    if (@hasDecl(T, "submit") != @hasDecl(T, "pollEffectResults"))
        @compileError("Host '" ++ tn ++ "' must declare both `submit` and `pollEffectResults` " ++
            "(declarative effects) or neither");
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
        pub fn submit(_: *@This(), _: Effect) EffectSubmit {
            return .unsupported;
        }
        pub fn pollEffectResults(_: *@This(), _: []EffectResult) usize {
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
