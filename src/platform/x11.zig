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
const data = @import("x11_data.zig");

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

const XSelectionRequestEvent = extern struct {
    kind: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    owner: Window,
    requestor: Window,
    selection: Atom,
    target: Atom,
    property: Atom,
    time: c_ulong,
};

/// Shared by SelectionNotify (the reply) and our SelectionRequest answers.
const XSelectionEvent = extern struct {
    kind: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    requestor: Window,
    selection: Atom,
    target: Atom,
    property: Atom,
    time: c_ulong,
};

const XSelectionClearEvent = extern struct {
    kind: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    window: Window,
    selection: Atom,
    time: c_ulong,
};

const XExposeEvent = extern struct {
    kind: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    window: Window,
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,
    /// Number of Expose events still to come in this batch; act on 0.
    count: c_int,
};

const XPropertyEvent = extern struct {
    kind: c_int,
    serial: c_ulong,
    send_event: c_int,
    display: ?*Display,
    window: Window,
    atom: Atom,
    time: c_ulong,
    state: c_int,
};

/// XEvent. The `kind` member aliases the `int type` first field of every
/// event struct (extern-union semantics). `pad` guarantees the union is
/// at least as large as the real XEvent (24 longs = 192 bytes on 64-bit)
/// so `XNextEvent` never writes past it.
pub const XEvent = extern union {
    kind: c_int,
    xkey: XKeyEvent,
    xbutton: XButtonEvent,
    xmotion: XMotionEvent,
    xconfigure: XConfigureEvent,
    xexpose: XExposeEvent,
    xclient: XClientMessageEvent,
    xselectionrequest: XSelectionRequestEvent,
    xselection: XSelectionEvent,
    xselectionclear: XSelectionClearEvent,
    xproperty: XPropertyEvent,
    pad: [24]c_long,
};

// X protocol event type codes.
const KeyPress: c_int = 2;
const ButtonPress: c_int = 4;
const ButtonRelease: c_int = 5;
const MotionNotify: c_int = 6;
const FocusIn: c_int = 9;
const FocusOut: c_int = 10;
const Expose: c_int = 12;
const ConfigureNotify: c_int = 22;
const PropertyNotify: c_int = 28;
const SelectionClear: c_int = 29;
const SelectionRequest: c_int = 30;
const SelectionNotify: c_int = 31;
const ClientMessage: c_int = 33;

const None: c_ulong = 0;
const CurrentTime: c_ulong = 0;
const XA_ATOM: Atom = 4;
const PropModeReplace: c_int = 0;
const PropertyNewValue: c_int = 0;
/// `Xutf8LookupString` status values.
const XBufferOverflow: c_int = -1;
const XLookupChars: c_int = 2;
const XLookupBoth: c_int = 4;

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
const FocusChangeMask: c_long = 1 << 21;
const PropertyChangeMask: c_long = 1 << 22;
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

/// Xlib entry points (pub for `x11_test.zig`).
pub const Xlib = struct {
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
    /// The connection's file descriptor (for `waitEvents`).
    XConnectionNumber: *const fn (*Display) callconv(.c) c_int,
    XLookupString: *const fn (*XKeyEvent, [*]u8, c_int, *KeySym, ?*anyopaque) callconv(.c) c_int,
    XInternAtom: *const fn (*Display, [*:0]const u8, c_int) callconv(.c) Atom,
    XSetWMProtocols: *const fn (*Display, Window, *Atom, c_int) callconv(.c) c_int,
    XFlush: *const fn (*Display) callconv(.c) c_int,
    /// Returns the root window's RESOURCE_MANAGER property (the `xrdb`
    /// database) as a NUL-terminated string, or null when unset. We read
    /// `Xft.dpi` out of it to derive the desktop scale factor.
    XResourceManagerString: *const fn (*Display) callconv(.c) ?[*:0]const u8,
    // Selections (clipboard + XDND).
    XSetSelectionOwner: *const fn (*Display, Atom, Window, c_ulong) callconv(.c) c_int,
    XGetSelectionOwner: *const fn (*Display, Atom) callconv(.c) Window,
    XConvertSelection: *const fn (*Display, Atom, Atom, Atom, Window, c_ulong) callconv(.c) c_int,
    XChangeProperty: *const fn (*Display, Window, Atom, Atom, c_int, c_int, [*]const u8, c_int) callconv(.c) c_int,
    XGetWindowProperty: *const fn (*Display, Window, Atom, c_long, c_long, c_int, Atom, *Atom, *c_int, *c_ulong, *c_ulong, *?[*]u8) callconv(.c) c_int,
    XDeleteProperty: *const fn (*Display, Window, Atom) callconv(.c) c_int,
    XSendEvent: *const fn (*Display, Window, c_int, c_long, *XEvent) callconv(.c) c_int,
    XCheckTypedWindowEvent: *const fn (*Display, Window, c_int, *XEvent) callconv(.c) c_int,
    XFree: *const fn (?*anyopaque) callconv(.c) c_int,
    XExtendedMaxRequestSize: *const fn (*Display) callconv(.c) c_long,
    XMaxRequestSize: *const fn (*Display) callconv(.c) c_long,
    // Input methods.
    XSupportsLocale: *const fn () callconv(.c) c_int,
    XSetLocaleModifiers: *const fn ([*:0]const u8) callconv(.c) ?[*:0]const u8,
    XFilterEvent: *const fn (*XEvent, Window) callconv(.c) c_int,
    XOpenIM: *const fn (*Display, ?*anyopaque, ?[*:0]const u8, ?[*:0]const u8) callconv(.c) ?*anyopaque,
    XCloseIM: *const fn (*anyopaque) callconv(.c) c_int,
    XGetIMValues: *const fn (*anyopaque, [*:0]const u8, ...) callconv(.c) ?[*:0]const u8,
    XCreateIC: *const fn (*anyopaque, [*:0]const u8, ...) callconv(.c) ?*anyopaque,
    XDestroyIC: *const fn (*anyopaque) callconv(.c) void,
    XGetICValues: *const fn (*anyopaque, [*:0]const u8, ...) callconv(.c) ?[*:0]const u8,
    XSetICValues: *const fn (*anyopaque, [*:0]const u8, ...) callconv(.c) ?[*:0]const u8,
    XSetICFocus: *const fn (*anyopaque) callconv(.c) void,
    XUnsetICFocus: *const fn (*anyopaque) callconv(.c) void,
    XVaCreateNestedList: *const fn (c_int, ...) callconv(.c) ?*anyopaque,
    Xutf8LookupString: *const fn (*anyopaque, *XKeyEvent, [*]u8, c_int, *KeySym, *c_int) callconv(.c) c_int,

    fn load(lib: *std.DynLib) !Xlib {
        var x: Xlib = undefined;
        const info = @typeInfo(Xlib).@"struct";
        inline for (info.field_names, info.field_types) |name, ty| {
            if (ty == void) continue;
            @field(x, name) = lib.lookup(ty, name ++ "") orelse
                return error.X11SymbolMissing;
        }
        return x;
    }
};

// ── Atoms, transfers, input-method plumbing ────────────────────────

pub const Atoms = struct {
    wm_protocols: Atom,
    wm_delete: Atom,
    clipboard: Atom,
    targets: Atom,
    utf8_string: Atom,
    string: Atom,
    text: Atom,
    text_plain_utf8: Atom,
    text_plain: Atom,
    image_png: Atom,
    uri_list: Atom,
    incr: Atom,
    /// Property our own conversions land on.
    teak_sel: Atom,
    xdnd_aware: Atom,
    xdnd_enter: Atom,
    xdnd_position: Atom,
    xdnd_status: Atom,
    xdnd_leave: Atom,
    xdnd_drop: Atom,
    xdnd_finished: Atom,
    xdnd_selection: Atom,
    xdnd_type_list: Atom,
    xdnd_action_copy: Atom,

    fn intern(x: *const Xlib, d: *Display) Atoms {
        var a: Atoms = undefined;
        const names = .{
            .{ "wm_protocols", "WM_PROTOCOLS" },
            .{ "wm_delete", "WM_DELETE_WINDOW" },
            .{ "clipboard", "CLIPBOARD" },
            .{ "targets", "TARGETS" },
            .{ "utf8_string", "UTF8_STRING" },
            .{ "string", "STRING" },
            .{ "text", "TEXT" },
            .{ "text_plain_utf8", "text/plain;charset=utf-8" },
            .{ "text_plain", "text/plain" },
            .{ "image_png", "image/png" },
            .{ "uri_list", "text/uri-list" },
            .{ "incr", "INCR" },
            .{ "teak_sel", "TEAK_SELECTION" },
            .{ "xdnd_aware", "XdndAware" },
            .{ "xdnd_enter", "XdndEnter" },
            .{ "xdnd_position", "XdndPosition" },
            .{ "xdnd_status", "XdndStatus" },
            .{ "xdnd_leave", "XdndLeave" },
            .{ "xdnd_drop", "XdndDrop" },
            .{ "xdnd_finished", "XdndFinished" },
            .{ "xdnd_selection", "XdndSelection" },
            .{ "xdnd_type_list", "XdndTypeList" },
            .{ "xdnd_action_copy", "XdndActionCopy" },
        };
        inline for (names) |n| @field(a, n[0]) = x.XInternAtom(d, n[1], 0);
        return a;
    }
};

/// Highest XDND protocol version we speak.
const XDND_VERSION: c_long = 5;
/// Largest incoming selection we accept (text or image bytes).
const MAX_TRANSFER_BYTES: usize = 64 * 1024 * 1024;
/// Largest dropped file we read.
const MAX_DROP_FILE_BYTES: usize = 32 * 1024 * 1024;
const MAX_DROP_FILES = 64;
/// How long an asynchronous transfer may wait for its owner/source.
const TRANSFER_TIMEOUT_MS: u64 = 5000;
/// How long the synchronous `Clipboard.read` waits for the owner.
const SYNC_READ_TIMEOUT_MS: u64 = 250;
const gpa = std.heap.page_allocator;

const XferKind = enum {
    /// `Clipboard.read`: blocking UTF8_STRING fetch into `read_buf`.
    sync_text,
    /// Unclaimed Ctrl+V, step 1: ask the owner what it offers.
    paste_targets,
    paste_text,
    paste_string,
    paste_png,
    dnd_uri,
    dnd_text,
};

/// One in-flight inbound selection conversion (clipboard paste or XDND drop).
const Transfer = struct {
    kind: XferKind,
    selection: Atom,
    buf: std.ArrayList(u8) = .empty,
    /// The owner announced INCR: chunks arrive as PropertyNotify events.
    incr: bool = false,
    deadline_ms: u64,
    /// XDND only: the drag source, owed an `XdndFinished`.
    dnd_source: Window = 0,
};

/// XDND session state between XdndEnter and the drop.
const Dnd = struct {
    source: Window = 0,
    offers_uri: bool = false,
    offers_text: bool = false,
};

const XIMCallback = extern struct {
    client_data: ?*anyopaque,
    callback: ?*const anyopaque,
};

const XIMText = extern struct {
    length: c_ushort,
    feedback: ?*c_ulong,
    encoding_is_wchar: c_int,
    string: extern union { multi_byte: ?[*]const u8, wide_char: ?[*]const u32 },
};

const XIMPreeditDrawCallbackStruct = extern struct {
    caret: c_int,
    chg_first: c_int,
    chg_length: c_int,
    text: ?*XIMText,
};

const XIMPreeditCaretCallbackStruct = extern struct {
    position: c_int,
    direction: c_int,
    style: c_int,
};

const XIMStyles = extern struct {
    count_styles: c_ushort,
    supported_styles: ?[*]c_ulong,
};

const XPoint = extern struct { x: c_short, y: c_short };

/// Heap-pinned input-method state: the preedit callbacks hold its address,
/// and `Host` is returned by value from `init`.
const ImeCtx = struct {
    preedit: data.Preedit = .{},
    mode: data.ImeMode = .nothing,
    cb_start: XIMCallback = undefined,
    cb_done: XIMCallback = undefined,
    cb_draw: XIMCallback = undefined,
    cb_caret: XIMCallback = undefined,
    spot: XPoint = .{ .x = 0, .y = 0 },
};

fn ctxOf(client_data: ?*anyopaque) ?*ImeCtx {
    return @ptrCast(@alignCast(client_data orelse return null));
}

fn preeditStart(_: ?*anyopaque, client_data: ?*anyopaque, _: ?*anyopaque) callconv(.c) c_int {
    if (ctxOf(client_data)) |c| c.preedit.start();
    return -1; // no length limit
}

fn preeditDone(_: ?*anyopaque, client_data: ?*anyopaque, _: ?*anyopaque) callconv(.c) void {
    if (ctxOf(client_data)) |c| c.preedit.done();
}

fn preeditDraw(_: ?*anyopaque, client_data: ?*anyopaque, call: ?*anyopaque) callconv(.c) void {
    const c = ctxOf(client_data) orelse return;
    const d: *const XIMPreeditDrawCallbackStruct = @ptrCast(@alignCast(call orelse return));
    var cps: [data.Preedit.CAP]u21 = undefined;
    var n: usize = 0;
    if (d.text) |t| {
        if (t.encoding_is_wchar != 0) {
            if (t.string.wide_char) |w| {
                while (n < @min(t.length, cps.len)) : (n += 1) {
                    cps[n] = std.math.cast(u21, w[n]) orelse 0xFFFD;
                }
            }
        } else if (t.string.multi_byte) |mb| {
            n = data.decodeUtf8Lossy(std.mem.sliceTo(mb, 0), &cps);
        }
    }
    const nonneg = struct {
        fn f(v: c_int) usize {
            return if (v < 0) 0 else @intCast(v);
        }
    }.f;
    c.preedit.draw(nonneg(d.chg_first), nonneg(d.chg_length), cps[0..n], nonneg(d.caret));
}

fn preeditCaret(_: ?*anyopaque, client_data: ?*anyopaque, call: ?*anyopaque) callconv(.c) void {
    const c = ctxOf(client_data) orelse return;
    const d: *const XIMPreeditCaretCallbackStruct = @ptrCast(@alignCast(call orelse return));
    if (d.position >= 0) c.preedit.moveCaret(@intCast(d.position));
}

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
    atoms: Atoms,
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

    /// Text we serve while we own the CLIPBOARD selection (null: not owner).
    clip_out: ?[]u8,
    /// Result of the last synchronous `Clipboard.read` (freed on the next).
    read_buf: ?[]u8,
    /// Largest property payload one `XChangeProperty` may carry; bigger
    /// clipboard writes are refused to requestors (no INCR on the send side).
    max_prop_bytes: usize,
    /// A Ctrl+V arrived this frame: unless `Clipboard.read` claims it,
    /// `pollEffectResults` starts an asynchronous paste.
    paste_requested: bool,
    /// The one inbound selection conversion in flight, if any.
    xfer: ?Transfer,
    dnd: Dnd,
    /// Input method (null when none is available: plain `Xutf8`-less path).
    xim: ?*anyopaque,
    xic: ?*anyopaque,
    ime: *ImeCtx,

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
        const atoms = Atoms.intern(&x, display);

        // Route the window-manager close button through ClientMessage.
        // We keep both atoms so the ClientMessage handler can confirm the
        // message is a WM_PROTOCOLS/WM_DELETE_WINDOW pair (not some other
        // client message whose data happens to collide with the atom id).
        var wm_delete = atoms.wm_delete;
        _ = x.XSetWMProtocols(display, window, &wm_delete, 1);

        // Accept XDND file / text drops (protocol version 5).
        var xdnd_ver: c_long = XDND_VERSION;
        _ = x.XChangeProperty(display, window, atoms.xdnd_aware, XA_ATOM, 32, PropModeReplace, @ptrCast(&xdnd_ver), 1);

        const ime = try gpa.create(ImeCtx);
        errdefer gpa.destroy(ime);
        ime.* = .{};
        const im = initIme(&x, display, window, ime);
        var select_mask: c_long = KeyPressMask | ButtonPressMask | ButtonReleaseMask |
            PointerMotionMask | StructureNotifyMask | ExposureMask | FocusChangeMask | PropertyChangeMask;
        if (im.ic) |ic| {
            // The IM may need events beyond the ones we asked for.
            var filter: c_ulong = 0;
            if (x.XGetICValues(ic, "filterEvents", &filter, @as(?*anyopaque, null)) == null)
                select_mask |= @as(c_long, @bitCast(filter));
            x.XSetICFocus(ic);
        }
        _ = x.XSelectInput(display, window, select_mask);

        const ext = x.XExtendedMaxRequestSize(display);
        const req_words: c_long = if (ext > 0) ext else x.XMaxRequestSize(display);
        const max_prop_bytes: usize = @intCast(@max(req_words * 4 - 1024, 4096));

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
            .atoms = atoms,
            .effects = effects,
            .width = width,
            .height = height,
            .scale = scale,
            .running = true,
            .first_resize = true,
            .resized_pending = false,
            .queue = .{},
            .clip_out = null,
            .read_buf = null,
            .max_prop_bytes = max_prop_bytes,
            .paste_requested = false,
            .xfer = null,
            .dnd = .{},
            .xim = im.xim,
            .xic = im.ic,
            .ime = ime,
        };
    }

    pub fn deinit(self: *Host) void {
        text.releaseFaces();
        self.abortTransfer();
        if (self.clip_out) |b| gpa.free(b);
        if (self.read_buf) |b| gpa.free(b);
        if (self.xic) |ic| self.x.XDestroyIC(ic);
        if (self.xim) |im| _ = self.x.XCloseIM(im);
        gpa.destroy(self.ime);
        self.effects.destroy();
        _ = self.x.XDestroyWindow(self.display, self.window);
        _ = self.x.XCloseDisplay(self.display);
        self.lib.close();
    }

    pub fn pollInputs(self: *Host) InputState {
        const q = &self.queue;
        q.beginFrame();
        self.paste_requested = false;
        self.expireTransfer();

        while (self.x.XPending(self.display) > 0) {
            var ev: XEvent = undefined;
            _ = self.x.XNextEvent(self.display, &ev);
            // Input methods get first refusal on every event (key events they
            // consume for composition never reach the switch below).
            if (self.x.XFilterEvent(&ev, None) != 0) continue;
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
                // Uncovered / first-mapped area: the idle loop skips frames, so an
                // expose must force the next one (the last frame is redrawn).
                Expose => if (ev.xexpose.count == 0) {
                    self.resized_pending = true;
                },
                ClientMessage => self.handleClientMessage(&ev.xclient),
                SelectionNotify => self.onSelectionNotify(&ev.xselection),
                PropertyNotify => self.onPropertyNotify(&ev.xproperty),
                SelectionRequest => self.onSelectionRequest(&ev.xselectionrequest),
                SelectionClear => if (ev.xselectionclear.selection == self.atoms.clipboard) {
                    if (self.clip_out) |b| gpa.free(b);
                    self.clip_out = null;
                },
                FocusIn => if (self.xic) |ic| self.x.XSetICFocus(ic),
                FocusOut => if (self.xic) |ic| self.x.XUnsetICFocus(ic),
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
        var buf: [512]u8 = undefined;
        var keysym: KeySym = 0;
        var n: c_int = 0;
        var has_chars = true;
        if (self.xic) |ic| {
            // Committed text from the input method (also dead keys / Compose
            // on the built-in IM). Overflow drops the commit rather than
            // splitting a code point.
            var status: c_int = 0;
            n = self.x.Xutf8LookupString(ic, ev, &buf, buf.len, &keysym, &status);
            has_chars = (status == XLookupChars or status == XLookupBoth) and status != XBufferOverflow;
            if (!has_chars) n = 0;
        } else {
            n = self.x.XLookupString(ev, &buf, buf.len, &keysym, null);
        }
        const chars = buf[0..if (n > 0) @intCast(n) else 0];

        // 1. Navigation / editing keys (Shift variants resolved by the queue).
        if (navFromKeysym(keysym)) |nk| return q.pushNav(nk);
        // 2. Ctrl chords (their control-char text is not typed).
        if (q.mods.ctrl) {
            if (chordFromKeysym(keysym)) |nk| {
                q.pushNav(nk);
                if (nk == .v) self.paste_requested = true;
            }
            return;
        }
        // 3. Text. With an input method the lookup yields whole UTF-8
        //    (committed compositions included); without, Unicode / Latin-1
        //    keysyms map straight to a code point and anything else falls
        //    back to the ASCII `XLookupString` produced.
        if (self.xic != null) {
            var it = std.unicode.Utf8View.initUnchecked(chars).iterator();
            if (std.unicode.utf8ValidateSlice(chars)) {
                while (it.nextCodepoint()) |cp| q.pushCodepoint(cp);
            }
            if (chars.len == 0) {
                if (codepointFromKeysym(keysym)) |cp| q.pushCodepoint(cp);
            }
            return;
        }
        if (codepointFromKeysym(keysym)) |cp| return q.pushCodepoint(cp);
        for (chars) |b| {
            if (b >= 0x20 and b < 0x7f) q.pushCodepoint(b);
        }
    }

    // ── Selections: clipboard + XDND ────────────────────────────────

    /// Send a 32-bit ClientMessage to `target` (pub for `x11_test.zig`).
    pub fn sendClientMessage(self: *Host, target: Window, msg_type: Atom, l: [5]c_long) void {
        var ev: XEvent = undefined;
        ev.xclient = .{
            .kind = ClientMessage,
            .serial = 0,
            .send_event = 1,
            .display = self.display,
            .window = target,
            .message_type = msg_type,
            .format = 32,
            .data = .{ .l = l },
        };
        _ = self.x.XSendEvent(self.display, target, 0, 0, &ev);
        _ = self.x.XFlush(self.display);
    }

    fn handleClientMessage(self: *Host, m: *const XClientMessageEvent) void {
        const a = &self.atoms;
        const l = m.data.l;
        if (m.message_type == a.wm_protocols) {
            if (l[0] == @as(c_long, @bitCast(a.wm_delete))) self.running = false;
        } else if (m.message_type == a.xdnd_enter) {
            self.dnd = .{ .source = @bitCast(l[0]) };
            const more = (l[1] & 1) != 0;
            var types: [3]Atom = .{ @bitCast(l[2]), @bitCast(l[3]), @bitCast(l[4]) };
            self.noteDndTypes(&types);
            if (more) {
                var list: std.ArrayList(u8) = .empty;
                defer list.deinit(gpa);
                if (self.fetchProperty(self.dnd.source, a.xdnd_type_list, false, &list) != null) {
                    var all: [64]Atom = undefined;
                    const n = atomsFromBytes(list.items, &all);
                    self.noteDndTypes(all[0..n]);
                }
            }
        } else if (m.message_type == a.xdnd_position) {
            const accept = self.dnd.source == @as(Window, @bitCast(l[0])) and (self.dnd.offers_uri or self.dnd.offers_text);
            self.sendClientMessage(@bitCast(l[0]), a.xdnd_status, .{
                @bitCast(self.window),
                if (accept) 1 else 0,
                0,
                0,
                if (accept) @bitCast(a.xdnd_action_copy) else 0,
            });
        } else if (m.message_type == a.xdnd_leave) {
            self.dnd = .{};
        } else if (m.message_type == a.xdnd_drop) {
            const src: Window = @bitCast(l[0]);
            const time: c_ulong = @bitCast(l[2]);
            if (src == self.dnd.source and (self.dnd.offers_uri or self.dnd.offers_text)) {
                const kind: XferKind = if (self.dnd.offers_uri) .dnd_uri else .dnd_text;
                const target = if (self.dnd.offers_uri) a.uri_list else a.utf8_string;
                self.startTransfer(kind, a.xdnd_selection, target, time, src);
            } else {
                self.sendDndFinished(src, false);
            }
            self.dnd = .{};
        }
    }

    fn noteDndTypes(self: *Host, types: []const Atom) void {
        for (types) |t| {
            if (t == self.atoms.uri_list) self.dnd.offers_uri = true;
            if (t == self.atoms.utf8_string) self.dnd.offers_text = true;
        }
    }

    fn sendDndFinished(self: *Host, source: Window, accepted: bool) void {
        self.sendClientMessage(source, self.atoms.xdnd_finished, .{
            @bitCast(self.window),
            if (accepted) 1 else 0,
            if (accepted) @bitCast(self.atoms.xdnd_action_copy) else 0,
            0,
            0,
        });
    }

    /// Append the whole value of `prop` on `win` to `out` (raw bytes; format-32
    /// items are 8-byte longs). `del` removes the property afterwards, which is
    /// also the ACK an INCR owner waits for. Null when the property is absent.
    fn fetchProperty(self: *Host, win: Window, prop: Atom, del: bool, out: *std.ArrayList(u8)) ?struct { type: Atom, format: c_int } {
        const CHUNK_LONGS: c_long = 262144; // 1 MiB per round trip
        var offset: c_long = 0;
        var first_type: Atom = None;
        var first_format: c_int = 0;
        while (true) {
            var actual_type: Atom = None;
            var actual_format: c_int = 0;
            var nitems: c_ulong = 0;
            var after: c_ulong = 0;
            var ptr: ?[*]u8 = null;
            const rc = self.x.XGetWindowProperty(self.display, win, prop, offset, CHUNK_LONGS, @intFromBool(del), 0, // AnyPropertyType
                &actual_type, &actual_format, &nitems, &after, &ptr);
            if (rc != 0 or actual_type == None) {
                if (ptr) |p| _ = self.x.XFree(p);
                return null;
            }
            if (offset == 0) {
                first_type = actual_type;
                first_format = actual_format;
            }
            const unit: usize = switch (actual_format) {
                8 => 1,
                16 => 2,
                else => @sizeOf(c_long),
            };
            if (ptr) |p| {
                out.appendSlice(gpa, p[0 .. @as(usize, nitems) * unit]) catch {
                    _ = self.x.XFree(p);
                    return null;
                };
                _ = self.x.XFree(p);
            }
            if (after == 0 or out.items.len > MAX_TRANSFER_BYTES) break;
            offset += CHUNK_LONGS;
        }
        return .{ .type = first_type, .format = first_format };
    }

    fn startTransfer(self: *Host, kind: XferKind, selection: Atom, target: Atom, time: c_ulong, dnd_source: Window) void {
        self.abortTransfer();
        self.xfer = .{
            .kind = kind,
            .selection = selection,
            .deadline_ms = self.nowMs() + TRANSFER_TIMEOUT_MS,
            .dnd_source = dnd_source,
        };
        _ = self.x.XDeleteProperty(self.display, self.window, self.atoms.teak_sel);
        _ = self.x.XConvertSelection(self.display, selection, target, self.atoms.teak_sel, self.window, time);
        _ = self.x.XFlush(self.display);
    }

    fn abortTransfer(self: *Host) void {
        if (self.xfer) |*t| {
            t.buf.deinit(gpa);
            self.xfer = null;
        }
    }

    /// The transfer failed or timed out: tell a drag source it was refused.
    fn failTransfer(self: *Host) void {
        if (self.xfer) |t| {
            if (t.dnd_source != 0) self.sendDndFinished(t.dnd_source, false);
        }
        self.abortTransfer();
    }

    fn expireTransfer(self: *Host) void {
        if (self.xfer) |t| {
            if (self.nowMs() >= t.deadline_ms) self.failTransfer();
        }
    }

    fn onSelectionNotify(self: *Host, ev: *const XSelectionEvent) void {
        const t = &(self.xfer orelse return);
        if (ev.selection != t.selection) return;
        if (ev.property == None) return self.failTransfer();
        const info = self.fetchProperty(self.window, ev.property, true, &t.buf) orelse return self.failTransfer();
        if (info.type == self.atoms.incr) {
            // The owner will stream chunks as PropertyNotify(NewValue) on our
            // property; the size hint it sent is discarded.
            t.incr = true;
            t.buf.clearRetainingCapacity();
            t.deadline_ms = self.nowMs() + TRANSFER_TIMEOUT_MS;
            return;
        }
        self.completeTransfer();
    }

    fn onPropertyNotify(self: *Host, ev: *const XPropertyEvent) void {
        const t = &(self.xfer orelse return);
        if (!t.incr or ev.window != self.window or ev.atom != self.atoms.teak_sel or ev.state != PropertyNewValue) return;
        const before = t.buf.items.len;
        _ = self.fetchProperty(self.window, self.atoms.teak_sel, true, &t.buf) orelse return self.failTransfer();
        if (t.buf.items.len == before) return self.completeTransfer(); // zero-length chunk ends INCR
        if (t.buf.items.len > MAX_TRANSFER_BYTES) return self.failTransfer();
        t.deadline_ms = self.nowMs() + TRANSFER_TIMEOUT_MS;
    }

    /// A transfer's bytes are all here: hand them to whoever asked.
    fn completeTransfer(self: *Host) void {
        var t = self.xfer orelse return;
        self.xfer = null; // `t` now owns buf
        defer t.buf.deinit(gpa);
        const bytes = t.buf.items;
        switch (t.kind) {
            .sync_text => {
                if (self.read_buf) |b| gpa.free(b);
                self.read_buf = gpa.dupe(u8, bytes) catch null;
            },
            .paste_targets => {
                var offered: [64]Atom = undefined;
                const n = atomsFromBytes(bytes, &offered);
                var has_utf8 = false;
                var has_string = false;
                var has_png = false;
                for (offered[0..n]) |o| {
                    if (o == self.atoms.utf8_string) has_utf8 = true;
                    if (o == self.atoms.string) has_string = true;
                    if (o == self.atoms.image_png) has_png = true;
                }
                const a = &self.atoms;
                switch (data.chooseTarget(has_utf8, has_string, has_png) orelse return) {
                    .utf8 => self.startTransfer(.paste_text, a.clipboard, a.utf8_string, CurrentTime, 0),
                    .string => self.startTransfer(.paste_string, a.clipboard, a.string, CurrentTime, 0),
                    .png => self.startTransfer(.paste_png, a.clipboard, a.image_png, CurrentTime, 0),
                }
            },
            .paste_text => self.deliverText(bytes),
            .paste_string => {
                const out = gpa.alloc(u8, bytes.len * 2) catch return;
                defer gpa.free(out);
                self.deliverText(data.latin1ToUtf8(bytes, out));
            },
            .paste_png => self.deliverImage(bytes),
            .dnd_text => {
                self.deliverDroppedText(bytes);
                self.sendDndFinished(t.dnd_source, true);
            },
            .dnd_uri => {
                self.deliverDroppedFiles(bytes);
                self.sendDndFinished(t.dnd_source, true);
            },
        }
    }

    /// Queue `.pasted_text` for the app's `effectMsg`.
    fn deliverText(self: *Host, txt: []const u8) void {
        if (txt.len == 0) return;
        const arena = native_effects.Service.newArena() orelse return;
        const copy = arena.allocator().dupe(u8, txt) catch return native_effects.Service.freeArena(arena);
        self.effects.push(arena, .{ .pasted_text = .{ .text = copy } });
    }

    fn deliverDroppedText(self: *Host, txt: []const u8) void {
        if (txt.len == 0) return;
        const arena = native_effects.Service.newArena() orelse return;
        const copy = arena.allocator().dupe(u8, txt) catch return native_effects.Service.freeArena(arena);
        self.effects.push(arena, .{ .dropped = .{ .kind = .text, .mime = "text/plain", .bytes = copy } });
    }

    /// A pasted PNG becomes the same `Drop{kind = .image}` the web host
    /// produces, minus the re-encode / thumbnail (native has no decoder):
    /// `bytes` is the owner's PNG verbatim, `width`/`height` come from its
    /// header, `thumb_rgba` is empty.
    fn deliverImage(self: *Host, png: []const u8) void {
        const size = data.pngSize(png) orelse return;
        const arena = native_effects.Service.newArena() orelse return;
        const copy = arena.allocator().dupe(u8, png) catch return native_effects.Service.freeArena(arena);
        self.effects.push(arena, .{ .dropped = .{
            .kind = .image,
            .mime = "image/png",
            .bytes = copy,
            .width = size.w,
            .height = size.h,
        } });
    }

    /// One `Drop` per readable regular file in a `text/uri-list`. Files are
    /// read here (up to 32 MiB each); unreadable ones, directories and remote
    /// URIs are skipped.
    fn deliverDroppedFiles(self: *Host, uri_list: []const u8) void {
        var it = data.UriIter{ .rest = uri_list };
        var count: usize = 0;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        while (it.next()) |uri| {
            if (count >= MAX_DROP_FILES) break;
            const path = data.uriToPath(uri, &path_buf) orelse continue;
            const arena = native_effects.Service.newArena() orelse return;
            const a = arena.allocator();
            const bytes = std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, path, a, .limited(MAX_DROP_FILE_BYTES)) catch {
                native_effects.Service.freeArena(arena);
                continue;
            };
            const name = a.dupe(u8, std.fs.path.basename(path)) catch {
                native_effects.Service.freeArena(arena);
                continue;
            };
            const mime = native_effects.mimeFromName(name);
            const is_image = std.mem.eql(u8, mime, "image/png") or std.mem.eql(u8, mime, "image/jpeg");
            const size = if (is_image) data.pngSize(bytes) else null;
            self.effects.push(arena, .{ .dropped = .{
                .kind = if (is_image) .image else .file,
                .name = name,
                .mime = mime,
                .bytes = bytes,
                .width = if (size) |s| s.w else 0,
                .height = if (size) |s| s.h else 0,
            } });
            count += 1;
        }
    }

    /// Answer another client's request for the CLIPBOARD we own.
    fn onSelectionRequest(self: *Host, req: *const XSelectionRequestEvent) void {
        const a = &self.atoms;
        var reply: XSelectionEvent = .{
            .kind = SelectionNotify,
            .serial = 0,
            .send_event = 1,
            .display = self.display,
            .requestor = req.requestor,
            .selection = req.selection,
            .target = req.target,
            .property = None,
            .time = req.time,
        };
        // Obsolete clients leave `property` unset: the target names it.
        const prop = if (req.property == None) req.target else req.property;
        if (req.selection == a.clipboard) if (self.clip_out) |out| {
            if (req.target == a.targets) {
                const offered = [_]c_ulong{ a.targets, a.utf8_string, a.string, a.text, a.text_plain_utf8, a.text_plain };
                _ = self.x.XChangeProperty(self.display, req.requestor, prop, XA_ATOM, 32, PropModeReplace, @ptrCast(&offered), offered.len);
                reply.property = prop;
            } else if (req.target == a.utf8_string or req.target == a.text or
                req.target == a.text_plain_utf8 or req.target == a.text_plain)
            {
                if (out.len <= self.max_prop_bytes) {
                    const ty = if (req.target == a.text) a.utf8_string else req.target;
                    _ = self.x.XChangeProperty(self.display, req.requestor, prop, ty, 8, PropModeReplace, out.ptr, @intCast(out.len));
                    reply.property = prop;
                }
            } else if (req.target == a.string) {
                if (gpa.alloc(u8, out.len)) |latin| {
                    defer gpa.free(latin);
                    const n = data.utf8ToLatin1(out, latin);
                    if (n <= self.max_prop_bytes) {
                        _ = self.x.XChangeProperty(self.display, req.requestor, prop, a.string, 8, PropModeReplace, latin.ptr, @intCast(n));
                        reply.property = prop;
                    }
                } else |_| {}
            }
        };
        var ev: XEvent = undefined;
        ev.xselection = reply;
        _ = self.x.XSendEvent(self.display, req.requestor, 0, 0, &ev);
        _ = self.x.XFlush(self.display);
    }

    /// Take ownership of CLIPBOARD and serve `txt` (copied) to requestors.
    /// Texts larger than the server's maximum request size (~16 MiB on a
    /// typical X.org) are served as "refused": INCR is not implemented on
    /// the sending side. The content dies with the process (no clipboard
    /// manager hand-off).
    pub fn writeClipboard(self: *Host, txt: []const u8) void {
        const copy = gpa.dupe(u8, txt) catch return;
        if (self.clip_out) |b| gpa.free(b);
        self.clip_out = copy;
        _ = self.x.XSetSelectionOwner(self.display, self.atoms.clipboard, self.window, CurrentTime);
        _ = self.x.XFlush(self.display);
        if (self.x.XGetSelectionOwner(self.display, self.atoms.clipboard) != self.window) {
            gpa.free(copy);
            self.clip_out = null;
        }
    }

    fn weOwnClipboard(self: *Host) bool {
        return self.clip_out != null and
            self.x.XGetSelectionOwner(self.display, self.atoms.clipboard) == self.window;
    }

    /// Begin the asynchronous paste for a Ctrl+V nobody claimed.
    fn startPaste(self: *Host) void {
        if (self.weOwnClipboard()) return self.deliverText(self.clip_out.?);
        const a = &self.atoms;
        if (self.x.XGetSelectionOwner(self.display, a.clipboard) == None) return;
        self.startTransfer(.paste_targets, a.clipboard, a.targets, CurrentTime, 0);
    }

    /// Blocking text read for the app's `handleClipboard` Ctrl+V path: our own
    /// content when we own the selection, else a bounded (250 ms) UTF8_STRING
    /// round trip that pumps only the selection events it needs.
    fn syncRead(self: *Host) []const u8 {
        if (self.read_buf) |b| gpa.free(b);
        self.read_buf = null;
        self.paste_requested = false; // claimed: no `pasted_text` for this press
        if (self.weOwnClipboard()) return self.clip_out.?;
        const a = &self.atoms;
        if (self.x.XGetSelectionOwner(self.display, a.clipboard) == None) return "";
        self.startTransfer(.sync_text, a.clipboard, a.utf8_string, CurrentTime, 0);
        const deadline = self.nowMs() + SYNC_READ_TIMEOUT_MS;
        while (self.xfer != null and self.nowMs() < deadline) {
            var ev: XEvent = undefined;
            if (self.x.XCheckTypedWindowEvent(self.display, self.window, SelectionNotify, &ev) != 0) {
                self.onSelectionNotify(&ev.xselection);
            } else if (self.x.XCheckTypedWindowEvent(self.display, self.window, PropertyNotify, &ev) != 0) {
                self.onPropertyNotify(&ev.xproperty);
            } else {
                std.Io.sleep(std.Options.debug_io, .fromMilliseconds(1), .awake) catch {};
            }
        }
        if (self.xfer != null) self.abortTransfer(); // owner never answered
        return self.read_buf orelse "";
    }

    /// Move the over-the-spot candidate position (window-relative logical
    /// pixels, the caret baseline of the focused text input). A no-op unless
    /// the input method negotiated the over-the-spot style; apps with an IME
    /// may call it whenever the caret moves.
    pub fn setImeSpot(self: *Host, spot_x: i32, spot_y: i32) void {
        const ic = self.xic orelse return;
        if (self.ime.mode != .position) return;
        self.ime.spot = .{ .x = @intCast(std.math.clamp(spot_x, 0, 32767)), .y = @intCast(std.math.clamp(spot_y, 0, 32767)) };
        const list = self.x.XVaCreateNestedList(0, @as([*:0]const u8, "spotLocation"), @as(*const XPoint, &self.ime.spot), @as(?*anyopaque, null));
        _ = self.x.XSetICValues(ic, @as([*:0]const u8, "preeditAttributes"), list, @as(?*anyopaque, null));
        if (list) |l| _ = self.x.XFree(l);
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
        switch (e) {
            .write_clipboard => |w| {
                self.writeClipboard(w.text);
                return .accepted;
            },
            else => return self.effects.submit(e),
        }
    }

    pub fn pollEffectResults(self: *Host, buf: []teak.EffectResult) usize {
        // Called after key routing: a Ctrl+V that `Clipboard.read` did not
        // claim becomes an asynchronous paste whose answer lands in a later
        // frame as `pasted_text` / `dropped`.
        if (self.paste_requested) {
            self.paste_requested = false;
            self.startPaste();
        }
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

    /// The CLIPBOARD selection. `write` takes ownership and serves the text
    /// to other clients (UTF8_STRING / STRING / TEXT / text/plain). `read`
    /// returns our own content when we own the selection, else does a
    /// bounded (250 ms) synchronous round trip to the owner; an unresponsive
    /// owner or an empty clipboard reads as "". Pastes the app did not claim
    /// through `read` arrive asynchronously as `pasted_text` / `dropped`.
    pub fn clipboard(self: *Host) Clipboard {
        return .{ .ctx = @ptrCast(self), .read_fn = clipRead, .write_fn = clipWrite };
    }

    fn clipRead(ctx: *anyopaque) []const u8 {
        const self: *Host = @ptrCast(@alignCast(ctx));
        return self.syncRead();
    }

    fn clipWrite(ctx: *anyopaque, txt: []const u8) void {
        const self: *Host = @ptrCast(@alignCast(ctx));
        self.writeClipboard(txt);
    }

    /// Input-method composition. Inactive without an input method (XMODIFIERS
    /// unset and no built-in IM) or outside a composition.
    pub fn imeState(self: *const Host) ImeState {
        const p = &self.ime.preedit;
        if (!p.active) return .{};
        return .{ .active = true, .text = p.text(), .cursor = p.out_caret };
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

    /// Event-driven idle: block until the X connection has something to read
    /// (input, expose/resize, clipboard traffic, IME) or `timeout_ms` passes.
    /// Returns immediately when events are already buffered in Xlib.
    pub fn waitEvents(self: *Host, timeout_ms: u32) void {
        if (self.x.XPending(self.display) > 0) return;
        _ = self.x.XFlush(self.display);
        var fds = [_]std.posix.pollfd{.{
            .fd = self.x.XConnectionNumber(self.display),
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        _ = std.posix.poll(&fds, @intCast(@min(timeout_ms, std.math.maxInt(i32)))) catch {};
    }

    pub fn nowMs(_: *const Host) u64 {
        // Monotonic milliseconds (clocks live behind `std.Io`).
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

/// Decode a format-32 property's raw bytes (8-byte longs) into atoms.
fn atomsFromBytes(bytes: []const u8, out: []Atom) usize {
    const n = @min(bytes.len / @sizeOf(c_long), out.len);
    for (0..n) |i| {
        out[i] = std.mem.readInt(c_ulong, bytes[i * @sizeOf(c_long) ..][0..@sizeOf(c_ulong)], @import("builtin").cpu.arch.endian());
    }
    return n;
}

extern "c" fn setlocale(category: c_int, locale: ?[*:0]const u8) ?[*:0]const u8;

const ImeHandles = struct { xim: ?*anyopaque = null, ic: ?*anyopaque = null };

/// Open an input method and create the context for `window`, preferring
/// on-the-spot preedit callbacks. Any failure (no locale support, no IM
/// running for `XMODIFIERS`, no usable style) returns nulls and the host
/// keeps its plain-keysym text path.
fn initIme(x: *const Xlib, display: *Display, window: Window, ctx: *ImeCtx) ImeHandles {
    const LC_CTYPE = 0;
    // Only the character-type category: leaves number formatting etc. alone.
    if (setlocale(LC_CTYPE, "") == null) return .{};
    if (x.XSupportsLocale() == 0) return .{};
    _ = x.XSetLocaleModifiers("");
    const xim = x.XOpenIM(display, null, null, null) orelse return .{};

    var styles: ?*XIMStyles = null;
    if (x.XGetIMValues(xim, "queryInputStyle", &styles, @as(?*anyopaque, null)) != null or styles == null) {
        _ = x.XCloseIM(xim);
        return .{};
    }
    const list = styles.?;
    const supported: []const c_ulong = if (list.supported_styles) |p| p[0..list.count_styles] else &.{};
    const choice = data.chooseImStyle(supported);
    _ = x.XFree(list);
    const pick = choice orelse {
        _ = x.XCloseIM(xim);
        return .{};
    };
    ctx.mode = pick.mode;

    const nul = @as(?*anyopaque, null);
    const style: c_ulong = pick.style;
    const win: c_ulong = window;
    var ic: ?*anyopaque = null;
    switch (pick.mode) {
        .callbacks => {
            ctx.cb_start = .{ .client_data = ctx, .callback = @ptrCast(&preeditStart) };
            ctx.cb_done = .{ .client_data = ctx, .callback = @ptrCast(&preeditDone) };
            ctx.cb_draw = .{ .client_data = ctx, .callback = @ptrCast(&preeditDraw) };
            ctx.cb_caret = .{ .client_data = ctx, .callback = @ptrCast(&preeditCaret) };
            const nested = x.XVaCreateNestedList(0, @as([*:0]const u8, "preeditStartCallback"), &ctx.cb_start, @as([*:0]const u8, "preeditDoneCallback"), &ctx.cb_done, @as([*:0]const u8, "preeditDrawCallback"), &ctx.cb_draw, @as([*:0]const u8, "preeditCaretCallback"), &ctx.cb_caret, nul);
            ic = x.XCreateIC(xim, "inputStyle", style, "clientWindow", win, "focusWindow", win, "preeditAttributes", nested, nul);
            if (nested) |n| _ = x.XFree(n);
        },
        .position => {
            const nested = x.XVaCreateNestedList(0, @as([*:0]const u8, "spotLocation"), @as(*const XPoint, &ctx.spot), nul);
            ic = x.XCreateIC(xim, "inputStyle", style, "clientWindow", win, "focusWindow", win, "preeditAttributes", nested, nul);
            if (nested) |n| _ = x.XFree(n);
        },
        .nothing => {
            ic = x.XCreateIC(xim, "inputStyle", style, "clientWindow", win, "focusWindow", win, nul);
        },
    }
    if (ic == null) {
        _ = x.XCloseIM(xim);
        return .{};
    }
    return .{ .xim = xim, .ic = ic };
}

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
    var seen = std.EnumSet(SpecialKey).empty;
    const keysyms = [_]KeySym{
        XK_BackSpace, XK_Delete,   XK_Left, XK_Right,        XK_Up,     XK_Down, XK_Home, XK_End, XK_Prior, XK_Next,
        XK_Return,    XK_KP_Enter, XK_Tab,  XK_ISO_Left_Tab, XK_Escape, 'a',     'c',     'x',    'v',      'y',
        'z',
    };
    const mod_sets = [_]teak.Modifiers{ .{}, .{ .shift = true }, .{ .ctrl = true }, .{ .ctrl = true, .shift = true } };
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

test "preedit callbacks drive the composition state (multibyte and wide)" {
    var ctx: ImeCtx = .{};
    try std.testing.expectEqual(@as(c_int, -1), preeditStart(null, &ctx, null));
    try std.testing.expect(ctx.preedit.active);

    var mb = XIMText{ .length = 2, .feedback = null, .encoding_is_wchar = 0, .string = .{ .multi_byte = "ni" } };
    var draw = XIMPreeditDrawCallbackStruct{ .caret = 2, .chg_first = 0, .chg_length = 0, .text = &mb };
    preeditDraw(null, &ctx, &draw);
    try std.testing.expectEqualStrings("ni", ctx.preedit.text());

    // The IM converts: replace both characters with one wide-char CJK glyph.
    const wide = [_]u32{ 0x4F60, 0 };
    var wt = XIMText{ .length = 1, .feedback = null, .encoding_is_wchar = 1, .string = .{ .wide_char = &wide } };
    draw = .{ .caret = 1, .chg_first = 0, .chg_length = 2, .text = &wt };
    preeditDraw(null, &ctx, &draw);
    try std.testing.expectEqualStrings("你", ctx.preedit.text());
    try std.testing.expectEqual(@as(usize, 3), ctx.preedit.out_caret);

    // text == NULL deletes the range; caret callback clamps.
    draw = .{ .caret = 0, .chg_first = 0, .chg_length = 1, .text = null };
    preeditDraw(null, &ctx, &draw);
    try std.testing.expectEqualStrings("", ctx.preedit.text());
    var caret = XIMPreeditCaretCallbackStruct{ .position = 9, .direction = 0, .style = 0 };
    preeditCaret(null, &ctx, &caret);
    try std.testing.expectEqual(@as(usize, 0), ctx.preedit.caret);

    preeditDone(null, &ctx, null);
    try std.testing.expect(!ctx.preedit.active);
}

test "atomsFromBytes decodes a format-32 property" {
    var raw: [3 * @sizeOf(c_long)]u8 = undefined;
    for (0..3) |i| std.mem.writeInt(c_ulong, raw[i * @sizeOf(c_long) ..][0..@sizeOf(c_ulong)], @as(c_ulong, 100) + @as(c_ulong, @intCast(i)), @import("builtin").cpu.arch.endian());
    var out: [4]Atom = undefined;
    try std.testing.expectEqual(@as(usize, 3), atomsFromBytes(&raw, &out));
    try std.testing.expectEqual(@as(Atom, 102), out[2]);
}
