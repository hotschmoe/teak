//! X11 host backend. Implements the `platform/host.zig` contract — the
//! Linux counterpart to `win32.zig`.
//!
//! libX11 is loaded at runtime via `std.DynLib` (`libX11.so.6`) rather
//! than linked, so the build needs no X11 dev package / `.so` symlink and
//! compiles on a headless box. The Xlib types we touch are hand-declared
//! here (as `win32.zig` hand-declares the Win32 API) — only layout and
//! field types matter for the C ABI, not field names.
//!
//! Unlike Win32's callback-driven WNDPROC, X11 delivers events
//! synchronously through `XNextEvent`, so all state lives on the `Host`
//! struct — no module-scope globals. X11 runs under XWayland too, so a
//! single X11 host covers both X11 and Wayland desktops; a native Wayland
//! backend is a future addition.
//!
//! Text measurement shares the `teak-text` (stb_truetype) module with the
//! GPU rasterizer so layout and rendering agree on metrics.

const std = @import("std");
const teak = @import("teak");
const text = @import("teak-text");

pub const InputState = teak.InputState;
pub const SpecialKey = teak.SpecialKey;
pub const TextMeasurer = teak.TextMeasurer;
pub const TextMetrics = teak.TextMetrics;
pub const FontSpec = teak.FontSpec;
pub const FontFamily = teak.FontFamily;
pub const Clipboard = teak.Clipboard;
pub const ImeState = teak.ImeState;
pub const A11yNode = teak.A11yNode;
pub const FileDialogResult = teak.FileDialogResult;
pub const FileDialogFilter = teak.FileDialogFilter;
pub const FileDialogPoll = teak.FileDialogPoll;

// ── Xlib types (hand-declared; 64-bit ABI) ─────────────────────────
//
// Display is opaque. Window / Atom / KeySym / Time are `unsigned long`.
// Bool is `int`. Event structs share an `int type` first field (named
// `kind` here — `type` is a Zig primitive); the XEvent union aliases it.

const Display = anyopaque;
const Window = c_ulong;
const Atom = c_ulong;
const KeySym = c_ulong;

const XKeyEvent = extern struct {
    kind: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: c_ulong,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    keycode: c_uint,
    same_screen: c_int,
};

const XButtonEvent = extern struct {
    kind: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: c_ulong,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    button: c_uint,
    same_screen: c_int,
};

const XMotionEvent = extern struct {
    kind: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    window: Window,
    root: Window,
    subwindow: Window,
    time: c_ulong,
    x: c_int,
    y: c_int,
    x_root: c_int,
    y_root: c_int,
    state: c_uint,
    is_hint: u8,
    same_screen: c_int,
};

const XConfigureEvent = extern struct {
    kind: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    event: Window,
    window: Window,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    border_width: c_int,
    above: Window,
    override_redirect: c_int,
};

const XClientMessageData = extern union {
    b: [20]u8,
    s: [10]c_short,
    l: [5]c_long,
};

const XClientMessageEvent = extern struct {
    kind: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    window: Window,
    message_type: Atom,
    format: c_int,
    data: XClientMessageData,
};

/// XEvent. The `kind` member aliases the `int type` first field of every
/// event struct (extern-union semantics). `pad` guarantees the union is
/// at least as large as the real XEvent (24 longs = 192 bytes on 64-bit)
/// so `XNextEvent` never writes past it.
const XEvent = extern union {
    kind: c_int,
    xkey: XKeyEvent,
    xbutton: XButtonEvent,
    xmotion: XMotionEvent,
    xconfigure: XConfigureEvent,
    xclient: XClientMessageEvent,
    pad: [24]c_long,
};

// X protocol event type codes.
const KeyPress: c_int = 2;
const ButtonPress: c_int = 4;
const ButtonRelease: c_int = 5;
const MotionNotify: c_int = 6;
const ConfigureNotify: c_int = 22;
const ClientMessage: c_int = 33;

// Modifier masks (XKeyEvent.state).
const ShiftMask: c_uint = 1 << 0;
const ControlMask: c_uint = 1 << 2;

// XSelectInput event masks.
const KeyPressMask: c_long = 1 << 0;
const ButtonPressMask: c_long = 1 << 2;
const ButtonReleaseMask: c_long = 1 << 3;
const PointerMotionMask: c_long = 1 << 6;
const ExposureMask: c_long = 1 << 15;
const StructureNotifyMask: c_long = 1 << 17;

// Keysyms (keysymdef.h).
const XK_BackSpace: KeySym = 0xff08;
const XK_Tab: KeySym = 0xff09;
const XK_ISO_Left_Tab: KeySym = 0xfe20;
const XK_Return: KeySym = 0xff0d;
const XK_KP_Enter: KeySym = 0xff8d;
const XK_Escape: KeySym = 0xff1b;
const XK_Delete: KeySym = 0xffff;
const XK_Home: KeySym = 0xff50;
const XK_Left: KeySym = 0xff51;
const XK_Up: KeySym = 0xff52;
const XK_Right: KeySym = 0xff53;
const XK_Down: KeySym = 0xff54;
const XK_Prior: KeySym = 0xff55; // Page Up
const XK_Next: KeySym = 0xff56; // Page Down
const XK_End: KeySym = 0xff57;

/// Pixels of intended scroll per wheel notch — matches win32's
/// WHEEL_PIXELS_PER_NOTCH so wheel feel is consistent across hosts.
const WHEEL_PIXELS_PER_NOTCH: f32 = 48;

// ── Xlib function pointer table (resolved via dlopen) ───────────────

const Xlib = struct {
    XOpenDisplay: *const fn (?[*:0]const u8) callconv(.c) ?*Display,
    XCloseDisplay: *const fn (*Display) callconv(.c) c_int,
    XDefaultScreen: *const fn (*Display) callconv(.c) c_int,
    XRootWindow: *const fn (*Display, c_int) callconv(.c) Window,
    XCreateSimpleWindow: *const fn (*Display, Window, c_int, c_int, c_uint, c_uint, c_uint, c_ulong, c_ulong) callconv(.c) Window,
    XDestroyWindow: *const fn (*Display, Window) callconv(.c) c_int,
    XStoreName: *const fn (*Display, Window, [*:0]const u8) callconv(.c) c_int,
    XSelectInput: *const fn (*Display, Window, c_long) callconv(.c) c_int,
    XMapWindow: *const fn (*Display, Window) callconv(.c) c_int,
    XNextEvent: *const fn (*Display, *XEvent) callconv(.c) c_int,
    XPending: *const fn (*Display) callconv(.c) c_int,
    XLookupString: *const fn (*XKeyEvent, [*]u8, c_int, *KeySym, ?*anyopaque) callconv(.c) c_int,
    XInternAtom: *const fn (*Display, [*:0]const u8, c_int) callconv(.c) Atom,
    XSetWMProtocols: *const fn (*Display, Window, *Atom, c_int) callconv(.c) c_int,
    XFlush: *const fn (*Display) callconv(.c) c_int,

    fn load(lib: *std.DynLib) !Xlib {
        var x: Xlib = undefined;
        inline for (@typeInfo(Xlib).@"struct".fields) |field| {
            if (field.type == void) continue;
            @field(x, field.name) = lib.lookup(field.type, field.name ++ "") orelse
                return error.X11SymbolMissing;
        }
        return x;
    }
};

// ── Public types ───────────────────────────────────────────────────

/// X11 native window handle: opaque `Display*` + `Window` XID. Structurally
/// matches `gpu/surface_xlib.Handle`; that provider duck-types it.
pub const NativeHandle = struct {
    display: *anyopaque,
    window: u64,
};

pub const Host = struct {
    lib: std.DynLib,
    x: Xlib,
    display: *Display,
    window: Window,
    wm_protocols: Atom,
    wm_delete: Atom,
    font: text.Font,

    width: u32,
    height: u32,
    running: bool,
    /// Frame-1 forces a resize so the Gpu configures its surface before
    /// the first present (X11 may not deliver ConfigureNotify first).
    first_resize: bool,
    resized_pending: bool,

    mouse_x: f32,
    mouse_y: f32,
    wheel_dx: f32,
    wheel_dy: f32,

    chars: [64]u8,
    chars_count: usize,
    keys: [32]SpecialKey,
    keys_count: usize,

    /// Owned buffer for clipboard reads (stub returns empty; see below).
    clipboard_buf: [65536]u8,

    pub fn init(title: []const u8, width: u32, height: u32) !Host {
        var lib = std.DynLib.open("libX11.so.6") catch return error.X11LoadFailed;
        errdefer lib.close();
        const x = try Xlib.load(&lib);

        const display = x.XOpenDisplay(null) orelse return error.X11OpenDisplayFailed;
        errdefer _ = x.XCloseDisplay(display);

        const screen = x.XDefaultScreen(display);
        const root = x.XRootWindow(display, screen);
        const window = x.XCreateSimpleWindow(display, root, 0, 0, width, height, 0, 0, 0);

        setWindowTitle(&x, display, window, title);
        _ = x.XSelectInput(display, window, KeyPressMask | ButtonPressMask |
            ButtonReleaseMask | PointerMotionMask | StructureNotifyMask | ExposureMask);

        // Route the window-manager close button through ClientMessage.
        // We keep both atoms so the ClientMessage handler can confirm the
        // message is a WM_PROTOCOLS/WM_DELETE_WINDOW pair (not some other
        // client message whose data happens to collide with the atom id).
        const wm_protocols = x.XInternAtom(display, "WM_PROTOCOLS", 0);
        var wm_delete = x.XInternAtom(display, "WM_DELETE_WINDOW", 0);
        _ = x.XSetWMProtocols(display, window, &wm_delete, 1);

        _ = x.XMapWindow(display, window);
        _ = x.XFlush(display);

        const font = try text.Font.load(std.heap.page_allocator);

        return .{
            .lib = lib,
            .x = x,
            .display = display,
            .window = window,
            .wm_protocols = wm_protocols,
            .wm_delete = wm_delete,
            .font = font,
            .width = width,
            .height = height,
            .running = true,
            .first_resize = true,
            .resized_pending = false,
            .mouse_x = 0,
            .mouse_y = 0,
            .wheel_dx = 0,
            .wheel_dy = 0,
            .chars = undefined,
            .chars_count = 0,
            .keys = undefined,
            .keys_count = 0,
            .clipboard_buf = undefined,
        };
    }

    pub fn deinit(self: *Host) void {
        self.font.deinit();
        _ = self.x.XDestroyWindow(self.display, self.window);
        _ = self.x.XCloseDisplay(self.display);
        self.lib.close();
    }

    pub fn pollInputs(self: *Host) InputState {
        self.chars_count = 0;
        self.keys_count = 0;
        var mouse_down = false;
        var mouse_up = false;

        while (self.x.XPending(self.display) > 0) {
            var ev: XEvent = undefined;
            _ = self.x.XNextEvent(self.display, &ev);
            switch (ev.kind) {
                MotionNotify => {
                    self.mouse_x = @floatFromInt(ev.xmotion.x);
                    self.mouse_y = @floatFromInt(ev.xmotion.y);
                },
                ButtonPress => {
                    self.mouse_x = @floatFromInt(ev.xbutton.x);
                    self.mouse_y = @floatFromInt(ev.xbutton.y);
                    switch (ev.xbutton.button) {
                        1 => mouse_down = true,
                        // X11 wheel = buttons 4/5 (vertical), 6/7 (horizontal).
                        // Sign per InputState: positive dy = scroll down.
                        4 => self.wheel_dy -= WHEEL_PIXELS_PER_NOTCH,
                        5 => self.wheel_dy += WHEEL_PIXELS_PER_NOTCH,
                        6 => self.wheel_dx -= WHEEL_PIXELS_PER_NOTCH,
                        7 => self.wheel_dx += WHEEL_PIXELS_PER_NOTCH,
                        else => {},
                    }
                },
                ButtonRelease => {
                    if (ev.xbutton.button == 1) {
                        self.mouse_x = @floatFromInt(ev.xbutton.x);
                        self.mouse_y = @floatFromInt(ev.xbutton.y);
                        mouse_up = true;
                    }
                },
                KeyPress => self.handleKey(&ev.xkey),
                ConfigureNotify => {
                    const w = ev.xconfigure.width;
                    const h = ev.xconfigure.height;
                    if (w > 0 and h > 0) {
                        const uw: u32 = @intCast(w);
                        const uh: u32 = @intCast(h);
                        if (uw != self.width or uh != self.height) {
                            self.width = uw;
                            self.height = uh;
                            self.resized_pending = true;
                        }
                    }
                },
                ClientMessage => {
                    if (ev.xclient.message_type == self.wm_protocols and
                        ev.xclient.data.l[0] == @as(c_long, @bitCast(self.wm_delete)))
                    {
                        self.running = false;
                    }
                },
                else => {},
            }
        }

        const resized = self.resized_pending or self.first_resize;
        self.first_resize = false;
        self.resized_pending = false;
        const wheel_dx = self.wheel_dx;
        const wheel_dy = self.wheel_dy;
        self.wheel_dx = 0;
        self.wheel_dy = 0;

        return .{
            .mouse_x = self.mouse_x,
            .mouse_y = self.mouse_y,
            .mouse_down = mouse_down,
            .mouse_up = mouse_up,
            .wheel_dx = wheel_dx,
            .wheel_dy = wheel_dy,
            .chars = self.chars[0..self.chars_count],
            .keys = self.keys[0..self.keys_count],
            .resized = resized,
            .width = self.width,
            .height = self.height,
        };
    }

    fn handleKey(self: *Host, ev: *XKeyEvent) void {
        var buf: [16]u8 = undefined;
        var keysym: KeySym = 0;
        const n = self.x.XLookupString(ev, &buf, buf.len, &keysym, null);
        const shift = (ev.state & ShiftMask) != 0;
        const ctrl = (ev.state & ControlMask) != 0;

        // 1. Navigation / editing keys.
        if (mapSpecial(keysym, shift)) |sk| {
            self.pushKey(sk);
            return;
        }
        // 2. Ctrl chords (don't emit their control-char text).
        if (ctrl) {
            if (mapCtrlChord(keysym)) |sk| self.pushKey(sk);
            return;
        }
        // 3. Printable ASCII text (XLookupString gives Latin-1; we keep the
        //    ASCII range, matching the Win32 host's WM_CHAR filter). Wider
        //    Unicode text entry needs Xutf8LookupString + an input method.
        var i: usize = 0;
        const count: usize = if (n > 0) @intCast(n) else 0;
        while (i < count) : (i += 1) {
            const b = buf[i];
            if (b >= 0x20 and b < 0x7f) self.pushChar(b);
        }
    }

    fn pushChar(self: *Host, ch: u8) void {
        if (self.chars_count < self.chars.len) {
            self.chars[self.chars_count] = ch;
            self.chars_count += 1;
        }
    }

    fn pushKey(self: *Host, k: SpecialKey) void {
        if (self.keys_count < self.keys.len) {
            self.keys[self.keys_count] = k;
            self.keys_count += 1;
        }
    }

    pub fn shouldClose(self: *const Host) bool {
        return !self.running;
    }

    pub fn nativeHandle(self: *const Host) NativeHandle {
        return .{ .display = @ptrCast(self.display), .window = @intCast(self.window) };
    }

    pub fn setTitle(self: *Host, title: []const u8) void {
        setWindowTitle(&self.x, self.display, self.window, title);
        _ = self.x.XFlush(self.display);
    }

    pub fn textMeasurer(self: *Host) TextMeasurer {
        return .{ .ctx = @ptrCast(self), .measure_fn = stbMeasure };
    }

    fn stbMeasure(ctx: *anyopaque, text_bytes: []const u8, font: FontSpec) TextMetrics {
        const self: *Host = @ptrCast(@alignCast(ctx));
        const vm = self.font.vMetrics(font.size_px);
        return .{
            .width = self.font.measureWidth(text_bytes, font.size_px),
            .height = vm.ascent + vm.descent,
            .ascent = vm.ascent,
            .descent = vm.descent,
        };
    }

    /// X11 clipboard (selections) requires an async XConvertSelection /
    /// SelectionNotify round-trip; not yet implemented. Read returns
    /// empty, write is a no-op — apps can call it unconditionally.
    pub fn clipboard(self: *Host) Clipboard {
        return .{ .ctx = @ptrCast(self), .read_fn = clipRead, .write_fn = clipWrite };
    }

    fn clipRead(ctx: *anyopaque) []const u8 {
        const self: *Host = @ptrCast(@alignCast(ctx));
        return self.clipboard_buf[0..0];
    }

    fn clipWrite(_: *anyopaque, _: []const u8) void {}

    pub fn imeState(_: *const Host) ImeState {
        return .{};
    }

    /// AT-SPI integration is a future addition; accept and discard so apps
    /// can publish unconditionally.
    pub fn publishA11yTree(_: *Host, _: []const A11yNode) void {}

    /// File dialogs need a portal / toolkit dependency (xdg-desktop-portal
    /// or GTK); not wired in v1. Returns null (cancel) — callers fall back.
    pub fn openFileDialog(_: *Host, _: FileDialogFilter) FileDialogResult {
        return null;
    }

    pub fn saveFileDialog(_: *Host, _: FileDialogFilter) FileDialogResult {
        return null;
    }

    pub fn openSecondaryWindow(_: *Host, _: []const u8, _: u32, _: u32) ?u32 {
        return null;
    }

    /// Secondary windows are not yet wired on X11 — the primary surface
    /// is all this host exposes. The secondary id space stays empty.
    pub fn pollSecondaryInputs(_: *Host, _: u32) ?InputState {
        return null;
    }

    pub fn closeSecondaryWindow(_: *Host, _: u32) void {}

    pub fn secondaryWindowHandle(_: *const Host, _: u32) ?NativeHandle {
        return null;
    }

    /// Async file-dialog surface. Like the blocking `openFileDialog`
    /// above, X11 has no native picker without a portal/toolkit dep, so
    /// submission fails (id 0) and apps never enter the poll loop.
    pub fn requestFileDialog(_: *Host, _: FileDialogFilter) u32 {
        return 0;
    }

    pub fn requestSaveFileDialog(_: *Host, _: FileDialogFilter) u32 {
        return 0;
    }

    pub fn pollFileDialogResult(_: *Host, _: u32) FileDialogPoll {
        return .{ .pending = {} };
    }

    pub fn nowMs(_: *const Host) u64 {
        return @intCast(std.time.milliTimestamp());
    }
};

fn setWindowTitle(x: *const Xlib, display: *Display, window: Window, title: []const u8) void {
    var buf: [256]u8 = undefined;
    const n = @min(title.len, buf.len - 1);
    @memcpy(buf[0..n], title[0..n]);
    buf[n] = 0;
    _ = x.XStoreName(display, window, @ptrCast(&buf));
}

fn mapSpecial(keysym: KeySym, shift: bool) ?SpecialKey {
    return switch (keysym) {
        XK_BackSpace => .backspace,
        XK_Delete => .delete,
        XK_Left => if (shift) .shift_left else .left,
        XK_Right => if (shift) .shift_right else .right,
        XK_Up => if (shift) .shift_up else .up,
        XK_Down => if (shift) .shift_down else .down,
        XK_Home => if (shift) .shift_home else .home,
        XK_End => if (shift) .shift_end else .end,
        XK_Prior => .page_up,
        XK_Next => .page_down,
        XK_Return, XK_KP_Enter => .enter,
        XK_Tab => .tab,
        XK_ISO_Left_Tab => .shift_tab,
        XK_Escape => .escape,
        else => null,
    };
}

fn mapCtrlChord(keysym: KeySym) ?SpecialKey {
    // Fold A–Z onto a–z; only ASCII letters reach the arms below.
    return switch (keysym | 0x20) {
        'a' => .ctrl_a,
        'c' => .ctrl_c,
        'v' => .ctrl_v,
        'x' => .ctrl_x,
        'y' => .ctrl_y,
        'z' => .ctrl_z,
        else => null,
    };
}

comptime {
    teak.validateHost(Host);
}

test "mapSpecial covers navigation, shift variants, and chords path" {
    try std.testing.expectEqual(SpecialKey.left, mapSpecial(XK_Left, false).?);
    try std.testing.expectEqual(SpecialKey.shift_left, mapSpecial(XK_Left, true).?);
    try std.testing.expectEqual(SpecialKey.enter, mapSpecial(XK_Return, false).?);
    try std.testing.expectEqual(SpecialKey.shift_tab, mapSpecial(XK_ISO_Left_Tab, false).?);
    try std.testing.expectEqual(SpecialKey.tab, mapSpecial(XK_Tab, false).?);
    try std.testing.expect(mapSpecial(0x61, false) == null); // 'a' is text, not special
    try std.testing.expectEqual(SpecialKey.ctrl_c, mapCtrlChord(0x63).?); // 'c'
    try std.testing.expectEqual(SpecialKey.ctrl_c, mapCtrlChord(0x43).?); // 'C'
    try std.testing.expect(mapCtrlChord(0x31) == null); // '1'
}
