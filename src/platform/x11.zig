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
const native_effects = @import("native_effects.zig");

pub const InputState = teak.InputState;
pub const SpecialKey = teak.SpecialKey;
pub const InputQueue = teak.InputQueue;
const NavKey = teak.NavKey;
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

// Modifier masks (`state` of key / button / motion events).
const ShiftMask: c_uint = 1 << 0;
const ControlMask: c_uint = 1 << 2;
const Mod1Mask: c_uint = 1 << 3; // Alt
const Mod4Mask: c_uint = 1 << 6; // Super

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
    /// Returns the root window's RESOURCE_MANAGER property (the `xrdb`
    /// database) as a NUL-terminated string, or null when unset. We read
    /// `Xft.dpi` out of it to derive the desktop scale factor.
    XResourceManagerString: *const fn (*Display) callconv(.c) ?[*:0]const u8,

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
    /// Effect servicing (HTTP worker threads, storage files, ...).
    effects: *native_effects.Service,

    width: u32,
    height: u32,
    /// Physical-pixels-per-logical-unit derived from `Xft.dpi` at init
    /// (X11 delivers geometry + pointer coords in device pixels and has
    /// no automatic scaling, so this is the de-facto desktop scale). Read
    /// once — desktops rarely change DPI mid-session, and re-reading the
    /// resource DB per frame would be wasteful. Reported via
    /// `scaleFactor`; nothing in the framework consumes it yet.
    scale: f32,
    running: bool,
    /// Frame-1 forces a resize so the Gpu configures its surface before
    /// the first present (X11 may not deliver ConfigureNotify first).
    first_resize: bool,
    resized_pending: bool,

    /// Pointer, buttons, wheel, text and key queues — see `InputQueue`.
    queue: InputQueue,

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

        // Desktop scale from Xft.dpi (xrdb). Absent / unparsable → 1.0.
        const scale = if (x.XResourceManagerString(display)) |rm|
            scaleFromXrm(std.mem.span(rm))
        else
            1.0;

        const effects = try native_effects.Service.create(title);

        return .{
            .lib = lib,
            .x = x,
            .display = display,
            .window = window,
            .wm_protocols = wm_protocols,
            .wm_delete = wm_delete,
            .effects = effects,
            .width = width,
            .height = height,
            .scale = scale,
            .running = true,
            .first_resize = true,
            .resized_pending = false,
            .queue = .{},
            .clipboard_buf = undefined,
        };
    }

    pub fn deinit(self: *Host) void {
        text.releaseFaces();
        self.effects.destroy();
        _ = self.x.XDestroyWindow(self.display, self.window);
        _ = self.x.XCloseDisplay(self.display);
        self.lib.close();
    }

    pub fn pollInputs(self: *Host) InputState {
        const q = &self.queue;
        q.beginFrame();

        while (self.x.XPending(self.display) > 0) {
            var ev: XEvent = undefined;
            _ = self.x.XNextEvent(self.display, &ev);
            switch (ev.kind) {
                MotionNotify => {
                    q.mods = modsFromState(ev.xmotion.state);
                    q.pointerMoved(@floatFromInt(ev.xmotion.x), @floatFromInt(ev.xmotion.y));
                },
                ButtonPress => {
                    q.mods = modsFromState(ev.xbutton.state);
                    q.pointerMoved(@floatFromInt(ev.xbutton.x), @floatFromInt(ev.xbutton.y));
                    switch (ev.xbutton.button) {
                        1 => q.buttonDown(.left),
                        2 => q.buttonDown(.middle),
                        3 => q.buttonDown(.right),
                        // X11 wheel = buttons 4/5 (vertical), 6/7 (horizontal).
                        // Sign per InputState: positive = scroll down / right.
                        4 => q.wheel(0, -WHEEL_PIXELS_PER_NOTCH),
                        5 => q.wheel(0, WHEEL_PIXELS_PER_NOTCH),
                        6 => q.wheel(-WHEEL_PIXELS_PER_NOTCH, 0),
                        7 => q.wheel(WHEEL_PIXELS_PER_NOTCH, 0),
                        else => {},
                    }
                },
                ButtonRelease => {
                    q.mods = modsFromState(ev.xbutton.state);
                    q.pointerMoved(@floatFromInt(ev.xbutton.x), @floatFromInt(ev.xbutton.y));
                    switch (ev.xbutton.button) {
                        1 => q.buttonUp(.left),
                        2 => q.buttonUp(.middle),
                        3 => q.buttonUp(.right),
                        else => {},
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
        return q.finish(resized, self.width, self.height);
    }

    fn handleKey(self: *Host, ev: *XKeyEvent) void {
        const q = &self.queue;
        q.mods = modsFromState(ev.state);
        var buf: [16]u8 = undefined;
        var keysym: KeySym = 0;
        const n = self.x.XLookupString(ev, &buf, buf.len, &keysym, null);

        // 1. Navigation / editing keys (Shift variants resolved by the queue).
        if (navFromKeysym(keysym)) |nk| return q.pushNav(nk);
        // 2. Ctrl chords (their control-char text is not typed).
        if (q.mods.ctrl) {
            if (chordFromKeysym(keysym)) |nk| q.pushNav(nk);
            return;
        }
        // 3. Text. Unicode / Latin-1 keysyms map straight to a code point;
        //    keysyms outside that (keypad digits with NumLock, ...) fall back
        //    to the ASCII `XLookupString` produced. Input methods (CJK
        //    composition) would need Xutf8LookupString + XIM.
        if (codepointFromKeysym(keysym)) |cp| return q.pushCodepoint(cp);
        for (buf[0..if (n > 0) @intCast(n) else 0]) |b| {
            if (b >= 0x20 and b < 0x7f) q.pushCodepoint(b);
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

    fn stbMeasure(_: *anyopaque, text_bytes: []const u8, font: FontSpec) TextMetrics {
        return text.measure(text_bytes, font);
    }

    // ── Declarative effects (docs/features/effects.md) ──────────────

    pub fn submit(self: *Host, e: teak.Effect) teak.EffectSubmit {
        return self.effects.submit(e);
    }

    pub fn pollEffectResults(self: *Host, buf: []teak.EffectResult) usize {
        return self.effects.poll(buf, self.nowMs());
    }

    /// Name the app's storage directory (`<config>/teak/<name>/`); defaults
    /// to the window title.
    pub fn setAppName(self: *Host, name: []const u8) void {
        self.effects.setAppName(name) catch {};
    }

    /// Register the TTF `ttf` as the face for (`family`, `weight`), for both
    /// the measurer and the Gpu's rasterizer (they share one face table). The
    /// bytes are borrowed: pass an `@embedFile` slice. Register before the
    /// first frame; up to three weights per family. A family without a
    /// registered face uses the system monospace font (`TEAK_FONT`).
    pub fn registerFont(_: *Host, family: teak.FontFamily, weight: teak.FontWeight, ttf: []const u8) !void {
        try text.registerFace(family, weight, ttf);
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
        // Monotonic milliseconds (Zig 0.16: clocks live behind `std.Io`).
        const now = std.Io.Clock.awake.now(std.Options.debug_io);
        return @intCast(@divFloor(now.nanoseconds, std.time.ns_per_ms));
    }

    /// Physical device pixels per logical unit, from `Xft.dpi` read at
    /// init. X11 reports window geometry and pointer coordinates in device
    /// pixels with no automatic scaling, so on a HiDPI desktop the UI is
    /// crisp but renders undersized until a consumer scales fonts + layout
    /// by this factor. Nothing in the framework does so yet — see
    /// docs/features/host.md "DPI and scaling". Defaults to 1.0 when
    /// `Xft.dpi` is unset.
    pub fn scaleFactor(self: *const Host) f32 {
        return self.scale;
    }
};

/// Parse the `Xft.dpi` value out of an X resource-manager string — the
/// newline-separated `key:\tvalue` dump from `XResourceManagerString`.
/// Returns the DPI (e.g. 192) or null when the key is absent/malformed.
/// Pure + allocation-free so it unit-tests headlessly.
fn parseXftDpi(xrm: []const u8) ?f32 {
    var it = std.mem.splitScalar(u8, xrm, '\n');
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t\r");
        if (!std.mem.eql(u8, key, "Xft.dpi")) continue;
        const val = std.mem.trim(u8, line[colon + 1 ..], " \t\r");
        var end: usize = 0;
        while (end < val.len and (std.ascii.isDigit(val[end]) or val[end] == '.')) : (end += 1) {}
        if (end == 0) return null;
        return std.fmt.parseFloat(f32, val[0..end]) catch null;
    }
    return null;
}

/// Derive a device-pixels-per-logical-unit scale from an X resource
/// string: `Xft.dpi / 96`, clamped to a sane [0.5, 8] range. 1.0 when
/// `Xft.dpi` is unset or non-positive.
fn scaleFromXrm(xrm: []const u8) f32 {
    const dpi = parseXftDpi(xrm) orelse return 1.0;
    if (!(dpi > 0)) return 1.0;
    return std.math.clamp(dpi / 96.0, 0.5, 8.0);
}

fn setWindowTitle(x: *const Xlib, display: *Display, window: Window, title: []const u8) void {
    var buf: [256]u8 = undefined;
    const n = @min(title.len, buf.len - 1);
    @memcpy(buf[0..n], title[0..n]);
    buf[n] = 0;
    _ = x.XStoreName(display, window, @ptrCast(&buf));
}

fn modsFromState(state: c_uint) teak.Modifiers {
    return .{
        .shift = (state & ShiftMask) != 0,
        .ctrl = (state & ControlMask) != 0,
        .alt = (state & Mod1Mask) != 0,
        .meta = (state & Mod4Mask) != 0,
    };
}

/// Non-text keys. `XK_ISO_Left_Tab` is what X delivers for Shift+Tab; the
/// Shift modifier on the event turns `.tab` into `shift_tab`.
fn navFromKeysym(keysym: KeySym) ?NavKey {
    return switch (keysym) {
        XK_BackSpace => .backspace,
        XK_Delete => .delete,
        XK_Left => .left,
        XK_Right => .right,
        XK_Up => .up,
        XK_Down => .down,
        XK_Home => .home,
        XK_End => .end,
        XK_Prior => .page_up,
        XK_Next => .page_down,
        XK_Return, XK_KP_Enter => .enter,
        XK_Tab, XK_ISO_Left_Tab => .tab,
        XK_Escape => .escape,
        else => null,
    };
}

/// Letter keysyms that form editing chords (only consulted with Ctrl held).
fn chordFromKeysym(keysym: KeySym) ?NavKey {
    // Fold A-Z onto a-z so Caps Lock / Shift don't matter.
    return switch (keysym | 0x20) {
        'a' => .a,
        'c' => .c,
        'x' => .x,
        'v' => .v,
        'y' => .y,
        'z' => .z,
        else => null,
    };
}

/// Printable keysyms that are their own code point: ASCII + Latin-1
/// (0x20..0x7e, 0xa0..0xff) and the Unicode range (0x01000000 + cp).
fn codepointFromKeysym(keysym: KeySym) ?u21 {
    return switch (keysym) {
        0x20...0x7e, 0xa0...0xff => @intCast(keysym),
        0x01000100...0x0110ffff => @intCast(keysym - 0x01000000),
        else => null,
    };
}

comptime {
    teak.validateHost(Host);
}

test "X11 key tables reach every SpecialKey through the shared policy" {
    var seen = std.EnumSet(SpecialKey).initEmpty();
    const keysyms = [_]KeySym{
        XK_BackSpace, XK_Delete,   XK_Left, XK_Right,        XK_Up,     XK_Down, XK_Home, XK_End, XK_Prior, XK_Next,
        XK_Return,    XK_KP_Enter, XK_Tab,  XK_ISO_Left_Tab, XK_Escape, 'a',     'c',     'x',    'v',      'y',
        'z',
    };
    const mod_sets = [_]teak.Modifiers{ .{}, .{ .shift = true }, .{ .ctrl = true } };
    for (mod_sets) |mods| {
        for (keysyms) |ks| {
            const nk = (if (mods.ctrl) chordFromKeysym(ks) else null) orelse navFromKeysym(ks) orelse continue;
            if (teak.resolveKey(nk, mods)) |sk| seen.insert(sk);
        }
    }
    for (std.enums.values(SpecialKey)) |sk| try std.testing.expect(seen.contains(sk));
}

test "navFromKeysym: letters are text, not keys" {
    try std.testing.expect(navFromKeysym('a') == null);
    try std.testing.expectEqual(NavKey.tab, navFromKeysym(XK_ISO_Left_Tab).?);
    try std.testing.expectEqual(NavKey.c, chordFromKeysym('C').?); // Caps Lock / Shift folded
    try std.testing.expect(chordFromKeysym('1') == null);
}

test "codepointFromKeysym: ASCII, Latin-1 and Unicode keysyms" {
    try std.testing.expectEqual(@as(u21, 'q'), codepointFromKeysym('q').?);
    try std.testing.expectEqual(@as(u21, 0xE9), codepointFromKeysym(0xe9).?); // eacute
    try std.testing.expectEqual(@as(u21, 0x20AC), codepointFromKeysym(0x010020ac).?); // EuroSign
    try std.testing.expect(codepointFromKeysym(XK_Left) == null);
    try std.testing.expect(codepointFromKeysym(0x1f) == null);
}

test "modsFromState decodes shift/ctrl/alt/super" {
    const m = modsFromState(ShiftMask | Mod4Mask | 0x2); // 0x2 = Caps Lock: ignored
    try std.testing.expect(m.shift and m.meta and !m.ctrl and !m.alt);
    try std.testing.expect(modsFromState(ControlMask | Mod1Mask).ctrl);
}

test "parseXftDpi extracts the value from a resource-manager dump" {
    // Tab-separated (xrdb's default) and space-separated forms, with the
    // key surrounded by unrelated resources.
    try std.testing.expectEqual(@as(f32, 192), parseXftDpi("Xft.antialias:\t1\nXft.dpi:\t192\nXft.hinting:\t1\n").?);
    try std.testing.expectEqual(@as(f32, 96), parseXftDpi("*customization:\t-color\nXft.dpi:  96").?);
    try std.testing.expectEqual(@as(f32, 120.5), parseXftDpi("Xft.dpi:\t120.5\n").?);
    // Absent / empty / non-numeric → null.
    try std.testing.expect(parseXftDpi("Xft.antialias:\t1\n") == null);
    try std.testing.expect(parseXftDpi("") == null);
    try std.testing.expect(parseXftDpi("Xft.dpi:\tauto\n") == null);
    // Must not match a differently-named key that merely contains the text.
    try std.testing.expect(parseXftDpi("Xft.dpimode:\t7\n") == null);
}

test "scaleFromXrm derives a clamped scale, defaulting to 1.0" {
    try std.testing.expectEqual(@as(f32, 2.0), scaleFromXrm("Xft.dpi:\t192\n"));
    try std.testing.expectEqual(@as(f32, 1.0), scaleFromXrm("Xft.dpi:\t96\n"));
    try std.testing.expectEqual(@as(f32, 1.0), scaleFromXrm("")); // unset
    try std.testing.expectEqual(@as(f32, 1.0), scaleFromXrm("Xft.dpi:\t0\n")); // non-positive guard
    // Absurd values clamp into range rather than producing a giant scale.
    try std.testing.expectEqual(@as(f32, 8.0), scaleFromXrm("Xft.dpi:\t9999\n"));
}
