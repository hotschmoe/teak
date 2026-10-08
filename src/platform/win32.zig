//! Win32 host backend. Implements the `platform/host.zig` contract.
//!
//! Single-window per process: state lives in module-scoped globals because
//! Win32's WNDPROC callback has no context parameter. Threading a context
//! via `GWLP_USERDATA` is possible but not needed until a real use case
//! asks for multi-window.

const std = @import("std");
const text = @import("teak-text");
const native_effects = @import("native_effects.zig");
const win32_data = @import("win32_data.zig");
const x11_data = @import("x11_data.zig");
const teak = @import("teak");

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
pub const A11yRole = teak.A11yRole;
pub const FileDialogResult = teak.FileDialogResult;
pub const FileDialogPoll = teak.FileDialogPoll;
pub const FileDialogFilter = teak.FileDialogFilter;

// ── Win32 types + constants ────────────────────────────────────────

const WINAPI = std.builtin.CallingConvention.winapi;
const BOOL = c_int;
const UINT = c_uint;
const DWORD = c_ulong;
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;
const HANDLE = *anyopaque;
const LPCWSTR = [*:0]const u16;
const WNDPROC = *const fn (HANDLE, UINT, WPARAM, LPARAM) callconv(WINAPI) LRESULT;

const MSG = extern struct {
    hwnd: ?HANDLE,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt_x: c_long,
    pt_y: c_long,
};

const WNDCLASSEXW = extern struct {
    cbSize: UINT = @sizeOf(WNDCLASSEXW),
    style: UINT = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: c_int = 0,
    cbWndExtra: c_int = 0,
    hInstance: ?HANDLE = null,
    hIcon: ?HANDLE = null,
    hCursor: ?HANDLE = null,
    hbrBackground: ?HANDLE = null,
    lpszMenuName: ?LPCWSTR = null,
    lpszClassName: LPCWSTR,
    hIconSm: ?HANDLE = null,
};

const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
const CW_USEDEFAULT: c_int = @bitCast(@as(c_uint, 0x80000000));
const SW_SHOW: c_int = 5;
const PM_REMOVE: UINT = 0x0001;
const CS_HREDRAW: UINT = 0x0002;
const CS_VREDRAW: UINT = 0x0001;
const WM_DESTROY: UINT = 0x0002;
const WM_SIZE: UINT = 0x0005;
const WM_PAINT: UINT = 0x000F;
/// `MsgWaitForMultipleObjectsEx`: wake on any queued input / message, and
/// also when one was already queued before the call.
const QS_ALLINPUT: DWORD = 0x04FF;
const MWMO_INPUTAVAILABLE: DWORD = 0x0004;
const WM_CHAR: UINT = 0x0102;
const WM_KEYDOWN: UINT = 0x0100;
const WM_SYSKEYDOWN: UINT = 0x0104;
const WM_SYSKEYUP: UINT = 0x0105;
const WM_MOUSEMOVE: UINT = 0x0200;
const WM_LBUTTONDOWN: UINT = 0x0201;
const WM_LBUTTONUP: UINT = 0x0202;
const WM_RBUTTONDOWN: UINT = 0x0204;
const WM_RBUTTONUP: UINT = 0x0205;
const WM_MBUTTONDOWN: UINT = 0x0207;
const WM_MBUTTONUP: UINT = 0x0208;
const WM_MOUSEWHEEL: UINT = 0x020A;
const WM_MOUSEHWHEEL: UINT = 0x020E;
const WHEEL_DELTA: f32 = 120;
/// Pixels per wheel notch (standard "3 lines × 16 px") — matches the
/// DOM convention browsers use when `deltaMode == 0` (pixel deltas).
const WHEEL_PIXELS_PER_NOTCH: f32 = 48;
const IDC_ARROW: LPCWSTR = @ptrFromInt(32512);
const WM_SETCURSOR: UINT = 0x0020;
const HTCLIENT: usize = 1;
extern "user32" fn SetCursor(?HANDLE) callconv(WINAPI) ?HANDLE;

/// Standard `IDC_*` resource id for a cursor shape. Win32 has no grab
/// cursor: `grab` is the hand, `grabbing` the four-way move arrow.
fn idcFor(shape: teak.CursorShape) usize {
    return switch (shape) {
        .arrow => 32512,
        .ibeam => 32513,
        .crosshair => 32515,
        .resize_nwse => 32642,
        .resize_nesw => 32643,
        .resize_ew => 32644,
        .resize_ns => 32645,
        .move, .grabbing => 32646,
        .not_allowed => 32648,
        .pointer, .grab => 32649,
    };
}

/// The cursor `WM_SETCURSOR` applies over the client area (null: arrow).
var g_cursor: ?HANDLE = null;

const VK_BACK: WPARAM = 0x08;
const VK_TAB: WPARAM = 0x09;
const VK_RETURN: WPARAM = 0x0D;
const VK_ESCAPE: WPARAM = 0x1B;
const VK_F12: WPARAM = 0x7B;
const VK_F10: WPARAM = 0x79;
const VK_APPS: WPARAM = 0x5D;
const VK_ALT: WPARAM = 0x12; // VK_MENU
const VK_PRIOR: WPARAM = 0x21; // page up
const VK_NEXT: WPARAM = 0x22; // page down
const VK_END: WPARAM = 0x23;
const VK_HOME: WPARAM = 0x24;
const VK_LEFT: WPARAM = 0x25;
const VK_UP: WPARAM = 0x26;
const VK_RIGHT: WPARAM = 0x27;
const VK_DOWN: WPARAM = 0x28;
const VK_DELETE: WPARAM = 0x2E;

extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(WINAPI) u16;
extern "user32" fn CreateWindowExW(DWORD, LPCWSTR, LPCWSTR, DWORD, c_int, c_int, c_int, c_int, ?HANDLE, ?HANDLE, ?HANDLE, ?*anyopaque) callconv(WINAPI) ?HANDLE;
extern "user32" fn ShowWindow(HANDLE, c_int) callconv(WINAPI) BOOL;
extern "user32" fn MsgWaitForMultipleObjectsEx(DWORD, ?*const HANDLE, DWORD, DWORD, DWORD) callconv(WINAPI) DWORD;
extern "user32" fn PeekMessageW(*MSG, ?HANDLE, UINT, UINT, UINT) callconv(WINAPI) BOOL;
extern "user32" fn TranslateMessage(*const MSG) callconv(WINAPI) BOOL;
extern "user32" fn DispatchMessageW(*const MSG) callconv(WINAPI) LRESULT;
extern "user32" fn DefWindowProcW(HANDLE, UINT, WPARAM, LPARAM) callconv(WINAPI) LRESULT;
extern "user32" fn PostQuitMessage(c_int) callconv(WINAPI) void;
extern "user32" fn LoadCursorW(?HANDLE, LPCWSTR) callconv(WINAPI) ?HANDLE;
extern "user32" fn GetKeyState(c_int) callconv(WINAPI) i16;
extern "user32" fn SetCapture(HANDLE) callconv(WINAPI) ?HANDLE;
extern "user32" fn ReleaseCapture() callconv(WINAPI) BOOL;
extern "user32" fn DestroyWindow(HANDLE) callconv(WINAPI) BOOL;
extern "user32" fn SetWindowTextW(HANDLE, LPCWSTR) callconv(WINAPI) BOOL;
/// Per-window DPI (Windows 10 1607+). Returns USER_DEFAULT_SCREEN_DPI
/// (96) while the process is DPI-*unaware*, and the true monitor DPI
/// once Per-Monitor(-v2) awareness is declared. See `Host.scaleFactor`.
extern "user32" fn GetDpiForWindow(HANDLE) callconv(WINAPI) UINT;
extern "kernel32" fn GetModuleHandleW(?LPCWSTR) callconv(WINAPI) ?HANDLE;

/// Standard screen DPI Windows treats as the 1.0 baseline.
const USER_DEFAULT_SCREEN_DPI: f32 = 96;

// Clipboard externs.
extern "user32" fn OpenClipboard(?HANDLE) callconv(WINAPI) BOOL;
extern "user32" fn CloseClipboard() callconv(WINAPI) BOOL;
extern "user32" fn EmptyClipboard() callconv(WINAPI) BOOL;
extern "user32" fn GetClipboardData(UINT) callconv(WINAPI) ?HANDLE;
extern "user32" fn SetClipboardData(UINT, HANDLE) callconv(WINAPI) ?HANDLE;
extern "kernel32" fn GlobalAlloc(UINT, usize) callconv(WINAPI) ?HANDLE;
extern "kernel32" fn GlobalLock(HANDLE) callconv(WINAPI) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(HANDLE) callconv(WINAPI) BOOL;
extern "kernel32" fn GlobalSize(HANDLE) callconv(WINAPI) usize;

const CF_UNICODETEXT: UINT = 13;
const GMEM_MOVEABLE: UINT = 0x0002;

// Common file dialog — OPENFILENAMEW (W version, the only one supported
// since Vista). Lots of fields; we use the minimum required for a
// "pick one file" dialog.
const OPENFILENAMEW = extern struct {
    lStructSize: DWORD = @sizeOf(OPENFILENAMEW),
    hwndOwner: ?HANDLE = null,
    hInstance: ?HANDLE = null,
    lpstrFilter: ?LPCWSTR = null,
    lpstrCustomFilter: ?[*]u16 = null,
    nMaxCustFilter: DWORD = 0,
    nFilterIndex: DWORD = 0,
    lpstrFile: [*]u16,
    nMaxFile: DWORD,
    lpstrFileTitle: ?[*]u16 = null,
    nMaxFileTitle: DWORD = 0,
    lpstrInitialDir: ?LPCWSTR = null,
    lpstrTitle: ?LPCWSTR = null,
    Flags: DWORD = 0,
    nFileOffset: u16 = 0,
    nFileExtension: u16 = 0,
    lpstrDefExt: ?LPCWSTR = null,
    lCustData: LPARAM = 0,
    lpfnHook: ?*anyopaque = null,
    lpTemplateName: ?LPCWSTR = null,
    pvReserved: ?*anyopaque = null,
    dwReserved: DWORD = 0,
    FlagsEx: DWORD = 0,
};

const OFN_PATHMUSTEXIST: DWORD = 0x00000800;
const OFN_FILEMUSTEXIST: DWORD = 0x00001000;
const OFN_OVERWRITEPROMPT: DWORD = 0x00000002;
const OFN_EXPLORER: DWORD = 0x00080000;

extern "comdlg32" fn GetOpenFileNameW(*OPENFILENAMEW) callconv(WINAPI) BOOL;
extern "comdlg32" fn GetSaveFileNameW(*OPENFILENAMEW) callconv(WINAPI) BOOL;

// Per-monitor DPI awareness (v2): Windows stops bitmap-stretching the window
// and reports physical pixels; the Host converts to logical units itself.
extern "user32" fn SetProcessDpiAwarenessContext(isize) callconv(WINAPI) BOOL;
extern "user32" fn GetDpiForSystem() callconv(WINAPI) UINT;
extern "user32" fn SetWindowPos(HANDLE, ?HANDLE, c_int, c_int, c_int, c_int, UINT) callconv(WINAPI) BOOL;
const DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2: isize = -4;
const WM_DPICHANGED: UINT = 0x02E0;
const SWP_NOZORDER: UINT = 0x0004;
const SWP_NOACTIVATE: UINT = 0x0010;

/// Physical pixels per logical unit of the (primary) window, from its DPI.
/// 1.0 until `Host.init` reads the real value and after `WM_DPICHANGED`.
var g_scale: f32 = 1.0;

/// Physical client pixels -> the logical units the app sees (at least 1).
fn toLogical(physical: u32) u32 {
    const v: f32 = @round(@as(f32, @floatFromInt(physical)) / g_scale);
    return @max(1, @as(u32, @intFromFloat(v)));
}

fn dpiScale(dpi: u32) f32 {
    return if (dpi == 0) 1.0 else @as(f32, @floatFromInt(dpi)) / USER_DEFAULT_SCREEN_DPI;
}

// Drag-and-drop of files from Explorer (WM_DROPFILES).
const WM_DROPFILES: UINT = 0x0233;
extern "shell32" fn DragAcceptFiles(HANDLE, BOOL) callconv(WINAPI) void;
extern "shell32" fn DragQueryFileW(HANDLE, UINT, ?[*]u16, UINT) callconv(WINAPI) UINT;
extern "shell32" fn DragFinish(HANDLE) callconv(WINAPI) void;

/// Paths dropped on the window since the last `pollEffectResults` (UTF-8,
/// written by `wndProc`, drained by the Host). A drop past the table is
/// ignored.
const MAX_PENDING_DROPS = 8;
var g_drops: [MAX_PENDING_DROPS][1024]u8 = undefined;
var g_drop_lens: [MAX_PENDING_DROPS]usize = @splat(0);
var g_drop_count: usize = 0;

fn queueDroppedFiles(hdrop: HANDLE) void {
    const n = DragQueryFileW(hdrop, 0xFFFFFFFF, null, 0);
    var i: UINT = 0;
    while (i < n and g_drop_count < MAX_PENDING_DROPS) : (i += 1) {
        var wide: [520]u16 = undefined;
        const len = DragQueryFileW(hdrop, i, &wide, wide.len);
        if (len == 0 or len >= wide.len) continue;
        const written = std.unicode.utf16LeToUtf8(&g_drops[g_drop_count], wide[0..len]) catch continue;
        g_drop_lens[g_drop_count] = written;
        g_drop_count += 1;
    }
}

// ── OLE drag-and-drop (IDropTarget) and image paste ────────────────
//
// `RegisterDragDrop` replaces `WM_DROPFILES` for the window and delivers
// whatever the source offers through an `IDataObject`: files (CF_HDROP,
// queued like WM_DROPFILES), images (registered "PNG", else CF_DIB) and
// text (CF_UNICODETEXT). Images become the same `Drop{kind = .image}` the web
// host produces (PNG <= 1568 px + RGBA thumbnail), text `Drop{kind = .text}`.
// The DIB / PNG / thumbnail conversions are pure and live in `win32_data.zig`.

const POINTL = extern struct { x: c_long, y: c_long };

const FORMATETC = extern struct {
    cfFormat: u16,
    ptd: ?*anyopaque,
    dwAspect: DWORD,
    lindex: c_long,
    tymed: DWORD,
};

const STGMEDIUM = extern struct {
    tymed: DWORD,
    hGlobal: ?HANDLE,
    pUnkForRelease: ?*anyopaque,
};

const DVASPECT_CONTENT: DWORD = 1;
const TYMED_HGLOBAL: DWORD = 1;
const DROPEFFECT_NONE: DWORD = 0;
const DROPEFFECT_COPY: DWORD = 1;
const CF_DIB: UINT = 8;
const CF_HDROP: UINT = 15;
const CF_DIBV5: UINT = 17;

const IID_IDropTarget: GUID = .{
    .Data1 = 0x00000122,
    .Data2 = 0x0000,
    .Data3 = 0x0000,
    .Data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};

const IDataObject = extern struct {
    vtbl: *const extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const anyopaque,
        GetData: *const fn (*IDataObject, *const FORMATETC, *STGMEDIUM) callconv(WINAPI) HRESULT,
        GetDataHere: *const anyopaque,
        QueryGetData: *const fn (*IDataObject, *const FORMATETC) callconv(WINAPI) HRESULT,
    },
};

const DropTarget = extern struct {
    vtbl: *const extern struct {
        QueryInterface: *const fn (*DropTarget, *const GUID, *?*anyopaque) callconv(WINAPI) HRESULT,
        AddRef: *const fn (*DropTarget) callconv(WINAPI) ULONG,
        Release: *const fn (*DropTarget) callconv(WINAPI) ULONG,
        DragEnter: *const fn (*DropTarget, *IDataObject, DWORD, POINTL, *DWORD) callconv(WINAPI) HRESULT,
        DragOver: *const fn (*DropTarget, DWORD, POINTL, *DWORD) callconv(WINAPI) HRESULT,
        DragLeave: *const fn (*DropTarget) callconv(WINAPI) HRESULT,
        Drop: *const fn (*DropTarget, *IDataObject, DWORD, POINTL, *DWORD) callconv(WINAPI) HRESULT,
    },
};

extern "ole32" fn OleInitialize(?*anyopaque) callconv(WINAPI) HRESULT;
extern "ole32" fn OleUninitialize() callconv(WINAPI) void;
extern "ole32" fn RegisterDragDrop(HANDLE, *DropTarget) callconv(WINAPI) HRESULT;
extern "ole32" fn RevokeDragDrop(HANDLE) callconv(WINAPI) HRESULT;
extern "ole32" fn ReleaseStgMedium(*STGMEDIUM) callconv(WINAPI) void;
extern "user32" fn IsClipboardFormatAvailable(UINT) callconv(WINAPI) BOOL;
extern "user32" fn RegisterClipboardFormatW(LPCWSTR) callconv(WINAPI) UINT;

const drop_gpa = std.heap.page_allocator;

/// The Host's effects service, set by `Host.init` so the (module-level) OLE
/// callbacks can queue results. Null outside a live Host.
var g_effects: ?*native_effects.Service = null;
var g_png_format: UINT = 0;
var g_ole_inited = false;
var g_ole_drop = false;
/// Whether the data object of the current drag offers something we take.
var g_drag_accepts = false;
/// Ctrl+V seen and not yet claimed by `Clipboard.read` (see `pollEffectResults`).
var g_paste_requested = false;

fn pngFormat() UINT {
    if (g_png_format == 0) g_png_format = RegisterClipboardFormatW(std.unicode.utf8ToUtf16LeStringLiteral("PNG"));
    return g_png_format;
}

/// Bytes of a global-memory block (valid until `GlobalUnlock`).
fn lockedBytes(h: HANDLE) ?struct { bytes: []const u8 } {
    const ptr = GlobalLock(h) orelse return null;
    const len = GlobalSize(h);
    const p: [*]const u8 = @ptrCast(ptr);
    return .{ .bytes = p[0..len] };
}

fn pushText(utf8: []const u8, pasted: bool) void {
    const svc = g_effects orelse return;
    if (utf8.len == 0) return;
    const arena = native_effects.Service.newArena() orelse return;
    const copy = arena.allocator().dupe(u8, utf8) catch return native_effects.Service.freeArena(arena);
    if (pasted) {
        svc.push(arena, .{ .pasted_text = .{ .text = copy } });
    } else {
        svc.push(arena, .{ .dropped = .{ .kind = .text, .mime = "text/plain", .bytes = copy } });
    }
}

/// An image that arrived as PNG bytes (the registered "PNG" format): handed
/// over verbatim, like the X11 host does.
fn pushPng(png: []const u8) void {
    const svc = g_effects orelse return;
    const size = x11_data.pngSize(png) orelse return;
    const arena = native_effects.Service.newArena() orelse return;
    const copy = arena.allocator().dupe(u8, png) catch return native_effects.Service.freeArena(arena);
    svc.push(arena, .{ .dropped = .{ .kind = .image, .mime = "image/png", .bytes = copy, .width = size.w, .height = size.h } });
}

/// An image that arrived as a packed DIB: decoded, re-encoded as PNG
/// (<= 1568 px) with an RGBA thumbnail, exactly the web host's `Drop`.
fn pushDib(dib: []const u8) void {
    const svc = g_effects orelse return;
    const arena = native_effects.Service.newArena() orelse return;
    const a = arena.allocator();
    const img = win32_data.dibToRgba(a, dib) catch return native_effects.Service.freeArena(arena);
    const parts = win32_data.imageParts(a, img) catch return native_effects.Service.freeArena(arena);
    svc.push(arena, .{ .dropped = .{
        .kind = .image,
        .mime = "image/png",
        .bytes = parts.png,
        .width = parts.w,
        .height = parts.h,
        .thumb_rgba = parts.thumb,
        .thumb_w = parts.thumb_w,
        .thumb_h = parts.thumb_h,
    } });
}

fn pushUtf16Text(wide: []const u8, pasted: bool) void {
    const units: [*]align(1) const u16 = @ptrCast(wide.ptr);
    var n: usize = 0;
    while (n < wide.len / 2 and units[n] != 0) : (n += 1) {}
    var buf: [65536]u8 = undefined;
    var tmp: [32768]u16 = undefined;
    const take = @min(n, tmp.len);
    for (0..take) |i| tmp[i] = units[i];
    const len = std.unicode.utf16LeToUtf8(&buf, tmp[0..take]) catch return;
    pushText(buf[0..len], pasted);
}

/// Deliver the image on the clipboard (PNG, else DIB) as a `dropped` image.
/// Returns whether one was found. The clipboard must be open.
fn pasteClipboardImage() bool {
    if (IsClipboardFormatAvailable(pngFormat()) != 0) {
        if (GetClipboardData(pngFormat())) |h| {
            if (lockedBytes(h)) |b| {
                defer _ = GlobalUnlock(h);
                pushPng(b.bytes);
                return true;
            }
        }
    }
    for ([_]UINT{ CF_DIBV5, CF_DIB }) |fmt| {
        if (IsClipboardFormatAvailable(fmt) == 0) continue;
        const h = GetClipboardData(fmt) orelse continue;
        const b = lockedBytes(h) orelse continue;
        defer _ = GlobalUnlock(h);
        pushDib(b.bytes);
        return true;
    }
    return false;
}

/// Ctrl+V that no `Clipboard.read` claimed: text arrives as `pasted_text`,
/// an image as `dropped` (the same results the web host reports).
fn pasteUnclaimed() void {
    if (OpenClipboard(null) == 0) return;
    defer _ = CloseClipboard();
    if (IsClipboardFormatAvailable(CF_UNICODETEXT) != 0) {
        const h = GetClipboardData(CF_UNICODETEXT) orelse return;
        const b = lockedBytes(h) orelse return;
        defer _ = GlobalUnlock(h);
        pushUtf16Text(b.bytes, true);
        return;
    }
    _ = pasteClipboardImage();
}

fn fmtEtc(cf: UINT) FORMATETC {
    return .{ .cfFormat = @intCast(cf), .ptd = null, .dwAspect = DVASPECT_CONTENT, .lindex = -1, .tymed = TYMED_HGLOBAL };
}

fn dataOffers(obj: *IDataObject, cf: UINT) bool {
    const f = fmtEtc(cf);
    return obj.vtbl.QueryGetData(obj, &f) == S_OK;
}

fn dropAcceptable(obj: *IDataObject) bool {
    for ([_]UINT{ CF_HDROP, pngFormat(), CF_DIBV5, CF_DIB, CF_UNICODETEXT }) |cf| {
        if (dataOffers(obj, cf)) return true;
    }
    return false;
}

fn dtQueryInterface(this: *DropTarget, iid: *const GUID, ppv: *?*anyopaque) callconv(WINAPI) HRESULT {
    if (guidEql(iid, &IID_IUnknown) or guidEql(iid, &IID_IDropTarget)) {
        ppv.* = @ptrCast(this);
        return S_OK;
    }
    ppv.* = null;
    return E_NOINTERFACE;
}
fn dtAddRef(_: *DropTarget) callconv(WINAPI) ULONG {
    return 1; // static singleton
}
fn dtRelease(_: *DropTarget) callconv(WINAPI) ULONG {
    return 1;
}
fn dtDragEnter(_: *DropTarget, obj: *IDataObject, _: DWORD, _: POINTL, effect: *DWORD) callconv(WINAPI) HRESULT {
    g_drag_accepts = dropAcceptable(obj);
    effect.* = if (g_drag_accepts) DROPEFFECT_COPY else DROPEFFECT_NONE;
    return S_OK;
}
fn dtDragOver(_: *DropTarget, _: DWORD, _: POINTL, effect: *DWORD) callconv(WINAPI) HRESULT {
    effect.* = if (g_drag_accepts) DROPEFFECT_COPY else DROPEFFECT_NONE;
    return S_OK;
}
fn dtDragLeave(_: *DropTarget) callconv(WINAPI) HRESULT {
    g_drag_accepts = false;
    return S_OK;
}
fn dtDrop(_: *DropTarget, obj: *IDataObject, _: DWORD, _: POINTL, effect: *DWORD) callconv(WINAPI) HRESULT {
    g_drag_accepts = false;
    effect.* = DROPEFFECT_NONE;
    var f = fmtEtc(CF_HDROP);
    var m: STGMEDIUM = undefined;
    if (obj.vtbl.GetData(obj, &f, &m) == S_OK) {
        defer ReleaseStgMedium(&m);
        if (m.hGlobal) |h| queueDroppedFiles(h);
        effect.* = DROPEFFECT_COPY;
        return S_OK;
    }
    f = fmtEtc(pngFormat());
    if (obj.vtbl.GetData(obj, &f, &m) == S_OK) {
        defer ReleaseStgMedium(&m);
        if (m.hGlobal) |h| if (lockedBytes(h)) |b| {
            defer _ = GlobalUnlock(h);
            pushPng(b.bytes);
            effect.* = DROPEFFECT_COPY;
        };
        if (effect.* == DROPEFFECT_COPY) return S_OK;
    }
    for ([_]UINT{ CF_DIBV5, CF_DIB }) |cf| {
        f = fmtEtc(cf);
        if (obj.vtbl.GetData(obj, &f, &m) != S_OK) continue;
        defer ReleaseStgMedium(&m);
        if (m.hGlobal) |h| if (lockedBytes(h)) |b| {
            defer _ = GlobalUnlock(h);
            pushDib(b.bytes);
            effect.* = DROPEFFECT_COPY;
        };
        if (effect.* == DROPEFFECT_COPY) return S_OK;
    }
    f = fmtEtc(CF_UNICODETEXT);
    if (obj.vtbl.GetData(obj, &f, &m) == S_OK) {
        defer ReleaseStgMedium(&m);
        if (m.hGlobal) |h| if (lockedBytes(h)) |b| {
            defer _ = GlobalUnlock(h);
            pushUtf16Text(b.bytes, false);
            effect.* = DROPEFFECT_COPY;
        };
    }
    return S_OK;
}

const drop_vtbl: @typeInfo(@FieldType(DropTarget, "vtbl")).pointer.child = .{
    .QueryInterface = dtQueryInterface,
    .AddRef = dtAddRef,
    .Release = dtRelease,
    .DragEnter = dtDragEnter,
    .DragOver = dtDragOver,
    .DragLeave = dtDragLeave,
    .Drop = dtDrop,
};
var g_drop_target: DropTarget = .{ .vtbl = &drop_vtbl };

/// Register the window for OLE drops; falls back to `WM_DROPFILES` (files
/// only) if OLE is unavailable.
fn registerDropTarget(hwnd: HANDLE) void {
    const hr = OleInitialize(null);
    // S_OK, or S_FALSE (already initialized on this thread).
    g_ole_inited = hr == S_OK or hr == 1;
    if (g_ole_inited and RegisterDragDrop(hwnd, &g_drop_target) == S_OK) {
        g_ole_drop = true;
        return;
    }
    DragAcceptFiles(hwnd, 1);
}

fn unregisterDropTarget(hwnd: HANDLE) void {
    if (g_ole_drop) _ = RevokeDragDrop(hwnd);
    g_ole_drop = false;
    if (g_ole_inited) OleUninitialize();
    g_ole_inited = false;
}

/// Async file-dialog slot table — see Host.file_dialog_slots. Four
/// concurrent requests is plenty for any reasonable app; oversaturating
/// returns id 0 ("submission failed") and the app should back off.
const MAX_FILE_DIALOG_SLOTS: usize = 4;

const FileDialogSlot = struct {
    active: bool = false,
    has_path: bool = false,
    path_len: usize = 0,
};

// ── IME externs (imm32) ───────────────────────────────────────────
//
// Imm* APIs surface the IME composition string to the application. The
// system delivers WM_IME_STARTCOMPOSITION, WM_IME_COMPOSITION (one or
// more times as the user edits the pre-commit string), and
// WM_IME_ENDCOMPOSITION. On commit, the system additionally posts
// WM_CHAR for each committed codepoint — which means we don't need to
// route committed text ourselves, just the pre-commit display.
//
// ImmGetCompositionStringW with GCS_COMPSTR returns the UTF-16 bytes of
// the in-flight string; with GCS_CURSORPOS returns the caret offset
// (in UTF-16 code units) inside it.
const HIMC = *anyopaque;
const WM_IME_STARTCOMPOSITION: UINT = 0x010D;
const WM_IME_ENDCOMPOSITION: UINT = 0x010E;
const WM_IME_COMPOSITION: UINT = 0x010F;
const GCS_COMPSTR: DWORD = 0x0008;
const GCS_CURSORPOS: DWORD = 0x0080;
const GCS_RESULTSTR: DWORD = 0x0800;

extern "imm32" fn ImmGetContext(HANDLE) callconv(WINAPI) ?HIMC;
extern "imm32" fn ImmReleaseContext(HANDLE, HIMC) callconv(WINAPI) BOOL;
extern "imm32" fn ImmGetCompositionStringW(HIMC, DWORD, ?*anyopaque, DWORD) callconv(WINAPI) c_long;

const VK_SHIFT: c_int = 0x10;
const VK_CONTROL: c_int = 0x11;
const VK_MENU: c_int = 0x12; // Alt
const VK_LWIN: c_int = 0x5B;
const VK_RWIN: c_int = 0x5C;
const VK_A: WPARAM = 0x41;
const VK_C: WPARAM = 0x43;
const VK_V: WPARAM = 0x56;
const VK_X: WPARAM = 0x58;
const VK_Y: WPARAM = 0x59;
const VK_Z: WPARAM = 0x5A;

// ── UIA (uiautomationcore.dll) ─────────────────────────────────────
//
// UI Automation bridge: per-frame `publishA11yTree` snapshots the
// flat A11yNode tree into module-scoped storage, and Narrator /
// Inspect.exe walk it via three published interfaces on the singleton
// root (Simple + Fragment + FragmentRoot) plus one Fragment provider
// per node (see `NodeProvider` below). All access is serialized by
// `g_a11y_lock` because UIA queries arrive on its own worker thread.
//
// HARDLINE: this is a Host §4(d) surface extension — same hatch
// clipboard / file dialogs / a11y-publishing already use. No platform
// types leak above the Host boundary; `publishA11yTree`'s public shape
// is unchanged.

const HRESULT = c_long;
const ULONG = c_ulong;
const LONG = c_long;
const SHORT = c_short;
const VARIANT_BOOL = SHORT;
const BSTR = ?[*:0]u16;

const S_OK: HRESULT = 0;
const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
const E_POINTER: HRESULT = @bitCast(@as(u32, 0x80004003));
const E_FAIL: HRESULT = @bitCast(@as(u32, 0x80004005));
const E_INVALIDARG: HRESULT = @bitCast(@as(u32, 0x80070057));

const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};

const IID_IUnknown: GUID = .{
    .Data1 = 0x00000000,
    .Data2 = 0,
    .Data3 = 0,
    .Data4 = .{ 0, 0, 0, 0, 0, 0, 0, 0x46 },
};
const IID_IRawElementProviderSimple: GUID = .{
    .Data1 = 0xD6DD68D1,
    .Data2 = 0x86FD,
    .Data3 = 0x4332,
    .Data4 = .{ 0x86, 0x66, 0x9A, 0xBE, 0xDE, 0xA2, 0xD2, 0x4C },
};
const IID_IRawElementProviderFragment: GUID = .{
    .Data1 = 0xF7063DA8,
    .Data2 = 0x8359,
    .Data3 = 0x439C,
    .Data4 = .{ 0x92, 0x97, 0xBB, 0xC5, 0x29, 0x9A, 0x7D, 0x87 },
};
const IID_IRawElementProviderFragmentRoot: GUID = .{
    .Data1 = 0x620CE2A5,
    .Data2 = 0xAB8F,
    .Data3 = 0x40A9,
    .Data4 = .{ 0x86, 0xCB, 0xDE, 0x3C, 0x75, 0x59, 0x9B, 0x58 },
};

const IID_IInvokeProvider: GUID = .{
    .Data1 = 0x54FCB24B,
    .Data2 = 0xE18E,
    .Data3 = 0x47A2,
    .Data4 = .{ 0xB4, 0xD3, 0xEC, 0xCB, 0xE7, 0x57, 0x59, 0x9E },
};
const IID_IToggleProvider: GUID = .{
    .Data1 = 0x56D00BD0,
    .Data2 = 0xC4F4,
    .Data3 = 0x433C,
    .Data4 = .{ 0xA8, 0x36, 0x1A, 0x52, 0xA5, 0x7E, 0x08, 0x92 },
};
const IID_IValueProvider: GUID = .{
    .Data1 = 0xC7935180,
    .Data2 = 0x6FB3,
    .Data3 = 0x4201,
    .Data4 = .{ 0xB1, 0x74, 0x7D, 0xF7, 0x3A, 0xDB, 0xF6, 0x4A },
};
const UIA_InvokePatternId: c_long = 10000;
const UIA_ValuePatternId: c_long = 10002;
const UIA_TogglePatternId: c_long = 10015;
const UIA_E_ELEMENTNOTENABLED: HRESULT = @bitCast(@as(u32, 0x80040200));
const UIA_E_ELEMENTNOTAVAILABLE: HRESULT = @bitCast(@as(u32, 0x80040201));
const ToggleState_Off: c_int = 0;
const ToggleState_On: c_int = 1;

// Provider option bits (only ServerSideProvider matters for us).
const ProviderOptions_ServerSideProvider: c_int = 0x01;

/// Marker sentinel UIA expects as the first element of a runtime ID
/// array. Tells UIA to prepend the host's runtime-id prefix; the second
/// element is our caller-defined id (we use the node's cmd_index).
const UiaAppendRuntimeId: c_int = 3;

// UIA property + control type constants we need.
const UIA_ControlTypePropertyId: c_long = 30003;
const UIA_NamePropertyId: c_long = 30005;
const UIA_IsKeyboardFocusablePropertyId: c_long = 30009;
const UIA_HasKeyboardFocusPropertyId: c_long = 30008;
const UIA_BoundingRectanglePropertyId: c_long = 30001;

// Control types: just the ones our roles map to.
const UIA_WindowControlTypeId: c_long = 50032;
const UIA_GroupControlTypeId: c_long = 50026;
const UIA_TextControlTypeId: c_long = 50020;
const UIA_ButtonControlTypeId: c_long = 50000;
const UIA_EditControlTypeId: c_long = 50004;
const UIA_CheckBoxControlTypeId: c_long = 50002;
const UIA_RadioButtonControlTypeId: c_long = 50013;
const UIA_SliderControlTypeId: c_long = 50015;
const UIA_SeparatorControlTypeId: c_long = 50038;
const UIA_ImageControlTypeId: c_long = 50006;
const UIA_PaneControlTypeId: c_long = 50033;
const UIA_ComboBoxControlTypeId: c_long = 50003;
const UIA_HyperlinkControlTypeId: c_long = 50005;
const UIA_ListItemControlTypeId: c_long = 50007;
const UIA_ListControlTypeId: c_long = 50008;
const UIA_MenuControlTypeId: c_long = 50009;
const UIA_MenuBarControlTypeId: c_long = 50010;
const UIA_MenuItemControlTypeId: c_long = 50011;
const UIA_ProgressBarControlTypeId: c_long = 50012;
const UIA_StatusBarControlTypeId: c_long = 50017;
const UIA_TabControlTypeId: c_long = 50018;
const UIA_TabItemControlTypeId: c_long = 50019;
const UIA_ToolBarControlTypeId: c_long = 50021;
const UIA_TreeControlTypeId: c_long = 50023;
const UIA_TreeItemControlTypeId: c_long = 50024;
const UIA_DataItemControlTypeId: c_long = 50029;
const UIA_HeaderItemControlTypeId: c_long = 50035;
const UIA_TableControlTypeId: c_long = 50036;

// Event ids
const UIA_StructureChangedEventId: c_long = 20002;
const StructureChangeType_ChildrenInvalidated: c_int = 4;

const UiaRootObjectId: LPARAM = -25;
const WM_GETOBJECT: UINT = 0x003D;

// VARIANT — *minimum* shape for the few types we return. Real VARIANT
// is much larger; this layout is the truncated form UIA tolerates when
// we only ever set vt = VT_I4, VT_BSTR, or VT_BOOL.
const VT_EMPTY: u16 = 0;
const VT_I4: u16 = 3;
const VT_BSTR: u16 = 8;
const VT_BOOL: u16 = 11;
const VT_R8: u16 = 5;
const VT_ARRAY: u16 = 0x2000;

const VARIANT = extern struct {
    vt: u16,
    wReserved1: u16 = 0,
    wReserved2: u16 = 0,
    wReserved3: u16 = 0,
    // 8-byte payload union. Use raw bytes; cast per vt.
    payload: [16]u8 = @splat(0),
};

/// Win32 RECT — top-left/bottom-right pixel coordinates. Used by
/// GetClientRect/ClientToScreen for the root's BoundingRectangle.
const RECT = extern struct {
    left: c_long,
    top: c_long,
    right: c_long,
    bottom: c_long,
};

/// Win32 POINT — used by ClientToScreen to translate a client-area
/// pixel into screen coordinates.
const POINT = extern struct {
    x: c_long,
    y: c_long,
};

/// UIA BoundingRectangle payload — four doubles in screen pixels.
/// Returned directly via `get_BoundingRectangle` (NOT via VARIANT/
/// SAFEARRAY — the fragment-level getter is a thin out-param).
const UiaRect = extern struct {
    left: f64,
    top: f64,
    width: f64,
    height: f64,
};

/// UIA NavigateDirection — values match the UIA spec, do NOT reorder.
const NavigateDirection = enum(c_int) {
    parent = 0,
    next_sibling = 1,
    previous_sibling = 2,
    first_child = 3,
    last_child = 4,
};

/// Opaque SAFEARRAY handle. We never read its fields directly — only
/// use SafeArrayCreateVector / Access / Unaccess and hand it to UIA.
const SAFEARRAY = extern struct { _opaque: [0]u8 = .{} };

/// CRITICAL_SECTION is 40 bytes on 64-bit Windows (RTL_CRITICAL_SECTION
/// layout). We never touch the internals; treat as an opaque blob with
/// 8-byte alignment so kernel32 sees it correctly.
const CRITICAL_SECTION = extern struct { _opaque: [40]u8 align(8) = @splat(0) };

extern "uiautomationcore" fn UiaReturnRawElementProvider(hwnd: HANDLE, wParam: WPARAM, lParam: LPARAM, el: *anyopaque) callconv(WINAPI) LRESULT;
extern "uiautomationcore" fn UiaHostProviderFromHwnd(hwnd: HANDLE, ppProvider: *?*anyopaque) callconv(WINAPI) HRESULT;
extern "uiautomationcore" fn UiaRaiseStructureChangedEvent(provider: *anyopaque, change_type: c_int, runtime_id: ?[*]const c_int, runtime_id_len: c_int) callconv(WINAPI) HRESULT;
extern "uiautomationcore" fn UiaDisconnectProvider(provider: *anyopaque) callconv(WINAPI) HRESULT;

extern "oleaut32" fn SysAllocString(psz: [*:0]const u16) callconv(WINAPI) BSTR;
extern "oleaut32" fn SysFreeString(bstr: BSTR) callconv(WINAPI) void;
extern "oleaut32" fn SafeArrayCreateVector(vt: c_short, lLbound: c_long, cElements: c_ulong) callconv(WINAPI) ?*SAFEARRAY;
extern "oleaut32" fn SafeArrayAccessData(psa: *SAFEARRAY, ppvData: *?*anyopaque) callconv(WINAPI) HRESULT;
extern "oleaut32" fn SafeArrayUnaccessData(psa: *SAFEARRAY) callconv(WINAPI) HRESULT;

extern "user32" fn GetClientRect(hwnd: HANDLE, lpRect: *RECT) callconv(WINAPI) BOOL;
extern "user32" fn ClientToScreen(hwnd: HANDLE, lpPoint: *POINT) callconv(WINAPI) BOOL;

extern "kernel32" fn InitializeCriticalSection(*CRITICAL_SECTION) callconv(WINAPI) void;
extern "kernel32" fn DeleteCriticalSection(*CRITICAL_SECTION) callconv(WINAPI) void;
extern "kernel32" fn EnterCriticalSection(*CRITICAL_SECTION) callconv(WINAPI) void;
extern "kernel32" fn LeaveCriticalSection(*CRITICAL_SECTION) callconv(WINAPI) void;

// ── COM vtable layout for the three interfaces we publish ─────────
//
// Each vtable's "this" parameter is typed as `*VtblPtr` — i.e. a
// pointer to the field inside the owning struct that holds the vtable
// pointer. UIA passes us a pointer to the interface (which IS a
// pointer to the vtable-pointer), so we can recover the owning
// RootProvider / NodeProvider via `@fieldParentPtr` on the field name
// that matches the vtable we're inside.
//
// Distinct typed pointers per vtable mean QueryInterface returns the
// right `this` for each interface, and the method bodies don't have
// to discriminate at runtime.

const SimpleThis = *const IRawElementProviderSimple_Vtbl;
const FragmentThis = *const IRawElementProviderFragment_Vtbl;
const FragmentRootThis = *const IRawElementProviderFragmentRoot_Vtbl;

const IRawElementProviderSimple_Vtbl = extern struct {
    QueryInterface: *const fn (*SimpleThis, *const GUID, *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (*SimpleThis) callconv(WINAPI) ULONG,
    Release: *const fn (*SimpleThis) callconv(WINAPI) ULONG,
    get_ProviderOptions: *const fn (*SimpleThis, *c_int) callconv(WINAPI) HRESULT,
    GetPatternProvider: *const fn (*SimpleThis, c_long, *?*anyopaque) callconv(WINAPI) HRESULT,
    GetPropertyValue: *const fn (*SimpleThis, c_long, *VARIANT) callconv(WINAPI) HRESULT,
    get_HostRawElementProvider: *const fn (*SimpleThis, *?*anyopaque) callconv(WINAPI) HRESULT,
};

const InvokeThis = *const IInvokeProvider_Vtbl;
const ToggleThis = *const IToggleProvider_Vtbl;
const ValueThis = *const IValueProvider_Vtbl;

const IInvokeProvider_Vtbl = extern struct {
    QueryInterface: *const fn (*InvokeThis, *const GUID, *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (*InvokeThis) callconv(WINAPI) ULONG,
    Release: *const fn (*InvokeThis) callconv(WINAPI) ULONG,
    Invoke: *const fn (*InvokeThis) callconv(WINAPI) HRESULT,
};

const IToggleProvider_Vtbl = extern struct {
    QueryInterface: *const fn (*ToggleThis, *const GUID, *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (*ToggleThis) callconv(WINAPI) ULONG,
    Release: *const fn (*ToggleThis) callconv(WINAPI) ULONG,
    Toggle: *const fn (*ToggleThis) callconv(WINAPI) HRESULT,
    get_ToggleState: *const fn (*ToggleThis, *c_int) callconv(WINAPI) HRESULT,
};

const IValueProvider_Vtbl = extern struct {
    QueryInterface: *const fn (*ValueThis, *const GUID, *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (*ValueThis) callconv(WINAPI) ULONG,
    Release: *const fn (*ValueThis) callconv(WINAPI) ULONG,
    SetValue: *const fn (*ValueThis, ?[*:0]const u16) callconv(WINAPI) HRESULT,
    get_Value: *const fn (*ValueThis, *BSTR) callconv(WINAPI) HRESULT,
    get_IsReadOnly: *const fn (*ValueThis, *BOOL) callconv(WINAPI) HRESULT,
};

const IRawElementProviderFragment_Vtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (*FragmentThis, *const GUID, *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (*FragmentThis) callconv(WINAPI) ULONG,
    Release: *const fn (*FragmentThis) callconv(WINAPI) ULONG,
    // IRawElementProviderFragment
    Navigate: *const fn (*FragmentThis, NavigateDirection, *?*anyopaque) callconv(WINAPI) HRESULT,
    GetRuntimeId: *const fn (*FragmentThis, *?*SAFEARRAY) callconv(WINAPI) HRESULT,
    get_BoundingRectangle: *const fn (*FragmentThis, *UiaRect) callconv(WINAPI) HRESULT,
    GetEmbeddedFragmentRoots: *const fn (*FragmentThis, *?*SAFEARRAY) callconv(WINAPI) HRESULT,
    SetFocus: *const fn (*FragmentThis) callconv(WINAPI) HRESULT,
    get_FragmentRoot: *const fn (*FragmentThis, *?*anyopaque) callconv(WINAPI) HRESULT,
};

const IRawElementProviderFragmentRoot_Vtbl = extern struct {
    // IUnknown
    QueryInterface: *const fn (*FragmentRootThis, *const GUID, *?*anyopaque) callconv(WINAPI) HRESULT,
    AddRef: *const fn (*FragmentRootThis) callconv(WINAPI) ULONG,
    Release: *const fn (*FragmentRootThis) callconv(WINAPI) ULONG,
    // IRawElementProviderFragmentRoot
    ElementProviderFromPoint: *const fn (*FragmentRootThis, f64, f64, *?*anyopaque) callconv(WINAPI) HRESULT,
    GetFocus: *const fn (*FragmentRootThis, *?*anyopaque) callconv(WINAPI) HRESULT,
};

/// Module-singleton COM object. We only ever publish ONE root provider
/// per window (single-window for now). Storage is module-scope so the
/// vtable function pointers can reach the host title without a
/// per-instance allocation.
///
/// Three vtable slots — one per published interface — sharing one
/// `RootProvider` instance. QueryInterface returns the address of the
/// requested vtable slot (Win32 / UIA aliases `*Interface` with
/// `*VtblPtr`), and each vtable method recovers the owning provider
/// via `@fieldParentPtr` on its slot name.
const RootProvider = extern struct {
    vtbl_simple: *const IRawElementProviderSimple_Vtbl,
    vtbl_fragment: *const IRawElementProviderFragment_Vtbl,
    vtbl_root: *const IRawElementProviderFragmentRoot_Vtbl,
};

/// Per-A11yNode COM object. Lives in a static pool indexed by tree
/// position; the index is rewritten on every `publishA11yTree` so
/// providers and their nodes stay 1:1. Two vtable slots: Simple +
/// Fragment (no FragmentRoot — only the window root is a fragment root).
const NodeProvider = extern struct {
    vtbl_simple: *const IRawElementProviderSimple_Vtbl,
    vtbl_fragment: *const IRawElementProviderFragment_Vtbl,
    /// Control patterns (handed out by GetPatternProvider per role).
    vtbl_invoke: *const IInvokeProvider_Vtbl,
    vtbl_toggle: *const IToggleProvider_Vtbl,
    vtbl_value: *const IValueProvider_Vtbl,
    /// Slot index inside `g_node_providers` — equal to the position
    /// in `g_published_nodes_buf` so siblings can be resolved by
    /// ±1 arithmetic.
    index: u32,
};

// ── RootProvider vtable methods (Simple) ───────────────────────────

fn rpQueryInterface(this: *SimpleThis, iid: *const GUID, ppv: *?*anyopaque) callconv(WINAPI) HRESULT {
    const self: *RootProvider = @fieldParentPtr("vtbl_simple", this);
    return rootQueryInterface(self, iid, ppv);
}

fn rpAddRef(_: *SimpleThis) callconv(WINAPI) ULONG {
    // Static singleton — module owns the lifetime, Win32 holds the
    // pointer for the process lifetime.
    return 1;
}

fn rpRelease(_: *SimpleThis) callconv(WINAPI) ULONG {
    return 1;
}

fn rpGetProviderOptions(_: *SimpleThis, opts: *c_int) callconv(WINAPI) HRESULT {
    opts.* = ProviderOptions_ServerSideProvider;
    return S_OK;
}

fn rpGetPatternProvider(_: *SimpleThis, _: c_long, out: *?*anyopaque) callconv(WINAPI) HRESULT {
    // No patterns implemented yet (Toggle/Value/Invoke are follow-up).
    out.* = null;
    return S_OK;
}

fn rpGetPropertyValue(_: *SimpleThis, prop_id: c_long, var_out: *VARIANT) callconv(WINAPI) HRESULT {
    switch (prop_id) {
        UIA_ControlTypePropertyId => {
            var_out.* = .{ .vt = VT_I4 };
            const v: c_long = UIA_WindowControlTypeId;
            @memcpy(var_out.payload[0..@sizeOf(c_long)], std.mem.asBytes(&v));
            return S_OK;
        },
        UIA_NamePropertyId => {
            const bstr = SysAllocString(@ptrCast(&g_window_title_w));
            var_out.* = .{ .vt = VT_BSTR };
            @memcpy(var_out.payload[0..@sizeOf(BSTR)], std.mem.asBytes(&bstr));
            return S_OK;
        },
        UIA_IsKeyboardFocusablePropertyId => {
            setBoolVariant(var_out, false);
            return S_OK;
        },
        else => {
            var_out.* = .{ .vt = VT_EMPTY };
            return S_OK;
        },
    }
}

fn rpGetHostRawElementProvider(_: *SimpleThis, pp: *?*anyopaque) callconv(WINAPI) HRESULT {
    if (g_hwnd_for_uia) |hwnd| {
        return UiaHostProviderFromHwnd(hwnd, pp);
    }
    pp.* = null;
    return E_FAIL;
}

/// Shared QueryInterface body — used by every vtable slot on the root
/// provider. Hands back the matching vtable slot's address (Simple,
/// Fragment, or FragmentRoot) so the caller's interface pointer is
/// pre-aimed at the right "this".
fn rootQueryInterface(self: *RootProvider, iid: *const GUID, ppv: *?*anyopaque) HRESULT {
    if (guidEql(iid, &IID_IUnknown) or guidEql(iid, &IID_IRawElementProviderSimple)) {
        ppv.* = @ptrCast(&self.vtbl_simple);
        return S_OK;
    }
    if (guidEql(iid, &IID_IRawElementProviderFragment)) {
        ppv.* = @ptrCast(&self.vtbl_fragment);
        return S_OK;
    }
    if (guidEql(iid, &IID_IRawElementProviderFragmentRoot)) {
        ppv.* = @ptrCast(&self.vtbl_root);
        return S_OK;
    }
    ppv.* = null;
    return E_NOINTERFACE;
}

// ── RootProvider vtable methods (Fragment) ─────────────────────────

fn rpfQueryInterface(this: *FragmentThis, iid: *const GUID, ppv: *?*anyopaque) callconv(WINAPI) HRESULT {
    const self: *RootProvider = @fieldParentPtr("vtbl_fragment", this);
    return rootQueryInterface(self, iid, ppv);
}

fn rpfAddRef(_: *FragmentThis) callconv(WINAPI) ULONG {
    return 1;
}

fn rpfRelease(_: *FragmentThis) callconv(WINAPI) ULONG {
    return 1;
}

fn rpfNavigate(_: *FragmentThis, direction: NavigateDirection, out: *?*anyopaque) callconv(WINAPI) HRESULT {
    // Root has no parent and no siblings; FirstChild / LastChild return
    // the corresponding ends of the published tree.
    EnterCriticalSection(&g_a11y_lock);
    defer LeaveCriticalSection(&g_a11y_lock);

    switch (direction) {
        .parent, .next_sibling, .previous_sibling => {
            out.* = null;
        },
        .first_child, .last_child => {
            if (g_published_count == 0) {
                out.* = null;
            } else {
                const idx = if (direction == .first_child) 0 else g_published_count - 1;
                out.* = @ptrCast(&g_node_providers[idx].vtbl_fragment);
            }
        },
    }
    return S_OK;
}

fn rpfGetRuntimeId(_: *FragmentThis, out: *?*SAFEARRAY) callconv(WINAPI) HRESULT {
    // The convention for the root's runtime id is just the
    // UiaAppendRuntimeId marker followed by a 0 — the system fills in
    // the host prefix.
    return makeRuntimeIdArray(0, out);
}

fn rpfGetBoundingRectangle(_: *FragmentThis, rect: *UiaRect) callconv(WINAPI) HRESULT {
    if (g_hwnd_for_uia) |hwnd| {
        var client: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        _ = GetClientRect(hwnd, &client);
        // GetClientRect always returns (0,0)-origin client coords,
        // so screenOrigin() gives the same screen-space top-left.
        const origin = screenOrigin();
        rect.* = .{
            .left = @floatFromInt(origin.x),
            .top = @floatFromInt(origin.y),
            .width = @floatFromInt(client.right - client.left),
            .height = @floatFromInt(client.bottom - client.top),
        };
        return S_OK;
    }
    rect.* = .{ .left = 0, .top = 0, .width = 0, .height = 0 };
    return S_OK;
}

fn rpfGetEmbeddedFragmentRoots(_: *FragmentThis, out: *?*SAFEARRAY) callconv(WINAPI) HRESULT {
    out.* = null;
    return S_OK;
}

fn rpfSetFocus(_: *FragmentThis) callconv(WINAPI) HRESULT {
    // No-op: focusing the root is meaningless for our model. Returning
    // S_OK matches what most providers do.
    return S_OK;
}

fn rpfGetFragmentRoot(this: *FragmentThis, out: *?*anyopaque) callconv(WINAPI) HRESULT {
    const self: *RootProvider = @fieldParentPtr("vtbl_fragment", this);
    out.* = @ptrCast(&self.vtbl_root);
    return S_OK;
}

// ── RootProvider vtable methods (FragmentRoot) ─────────────────────

fn rprQueryInterface(this: *FragmentRootThis, iid: *const GUID, ppv: *?*anyopaque) callconv(WINAPI) HRESULT {
    const self: *RootProvider = @fieldParentPtr("vtbl_root", this);
    return rootQueryInterface(self, iid, ppv);
}

fn rprAddRef(_: *FragmentRootThis) callconv(WINAPI) ULONG {
    return 1;
}

fn rprRelease(_: *FragmentRootThis) callconv(WINAPI) ULONG {
    return 1;
}

fn rprElementProviderFromPoint(this: *FragmentRootThis, x: f64, y: f64, out: *?*anyopaque) callconv(WINAPI) HRESULT {
    const self: *RootProvider = @fieldParentPtr("vtbl_root", this);
    // Translate from screen to client coords for comparison with the
    // node bounds (which are window-coord). If we can't translate,
    // fall back to self.
    const origin = screenOrigin();
    const cx: f32 = @floatCast(x - @as(f64, @floatFromInt(origin.x)));
    const cy: f32 = @floatCast(y - @as(f64, @floatFromInt(origin.y)));

    EnterCriticalSection(&g_a11y_lock);
    defer LeaveCriticalSection(&g_a11y_lock);

    // Walk back-to-front so the topmost hit wins (painter's order).
    var i: usize = g_published_count;
    while (i > 0) {
        i -= 1;
        const n = g_published_nodes_buf[i];
        if (cx >= n.bounds.x and cx < n.bounds.x + n.bounds.w and
            cy >= n.bounds.y and cy < n.bounds.y + n.bounds.h)
        {
            out.* = @ptrCast(&g_node_providers[i].vtbl_fragment);
            return S_OK;
        }
    }
    out.* = @ptrCast(&self.vtbl_fragment);
    return S_OK;
}

fn rprGetFocus(_: *FragmentRootThis, out: *?*anyopaque) callconv(WINAPI) HRESULT {
    EnterCriticalSection(&g_a11y_lock);
    defer LeaveCriticalSection(&g_a11y_lock);

    var i: usize = 0;
    while (i < g_published_count) : (i += 1) {
        if (g_published_nodes_buf[i].focused) {
            out.* = @ptrCast(&g_node_providers[i].vtbl_fragment);
            return S_OK;
        }
    }
    out.* = null;
    return S_OK;
}

// ── NodeProvider vtable methods (Simple) ───────────────────────────

fn npQueryInterface(this: *SimpleThis, iid: *const GUID, ppv: *?*anyopaque) callconv(WINAPI) HRESULT {
    const self: *NodeProvider = @fieldParentPtr("vtbl_simple", this);
    return nodeQueryInterface(self, iid, ppv);
}

fn npAddRef(_: *SimpleThis) callconv(WINAPI) ULONG {
    return 1;
}

fn npRelease(_: *SimpleThis) callconv(WINAPI) ULONG {
    return 1;
}

fn npGetProviderOptions(_: *SimpleThis, opts: *c_int) callconv(WINAPI) HRESULT {
    opts.* = ProviderOptions_ServerSideProvider;
    return S_OK;
}

/// Which control patterns a role supports.
fn supportsInvoke(role: A11yRole) bool {
    return switch (role) {
        .button, .tab, .menuitem, .link, .option, .treeitem, .radio => true,
        else => false,
    };
}
fn supportsToggle(role: A11yRole) bool {
    return role == .checkbox;
}
fn supportsValue(role: A11yRole) bool {
    return role == .text_input;
}

fn npGetPatternProvider(this: *SimpleThis, pattern_id: c_long, out: *?*anyopaque) callconv(WINAPI) HRESULT {
    const self: *NodeProvider = @fieldParentPtr("vtbl_simple", this);
    out.* = null;
    EnterCriticalSection(&g_a11y_lock);
    defer LeaveCriticalSection(&g_a11y_lock);
    if (self.index >= g_published_count) return S_OK;
    const role = g_published_nodes_buf[self.index].role;
    switch (pattern_id) {
        UIA_InvokePatternId => if (supportsInvoke(role)) {
            out.* = @ptrCast(&self.vtbl_invoke);
        },
        UIA_TogglePatternId => if (supportsToggle(role)) {
            out.* = @ptrCast(&self.vtbl_toggle);
        },
        UIA_ValuePatternId => if (supportsValue(role)) {
            out.* = @ptrCast(&self.vtbl_value);
        },
        else => {},
    }
    return S_OK;
}

// ── Control patterns: requests go onto `g_action_queue`, drained by
// `Host.pollA11yActions` on the run-loop thread, so they reach `update` as
// ordinary input. The pattern methods run on UIA's worker thread.

/// Queue `kind` for the published node `index` (lock held by the caller).
fn queueAction(index: u32, kind: teak.A11yActionKind, payload: []const u8) HRESULT {
    if (index >= g_published_count) return UIA_E_ELEMENTNOTAVAILABLE;
    const node = g_published_nodes_buf[index];
    if (node.disabled) return UIA_E_ELEMENTNOTENABLED;
    return if (g_action_queue.push(kind, node.cmd_index, payload)) S_OK else E_FAIL;
}

fn patQueryInterface(vt: anytype, iid: *const GUID, ppv: *?*anyopaque, comptime slot: []const u8) HRESULT {
    const self: *NodeProvider = @fieldParentPtr(slot, vt);
    return nodeQueryInterface(self, iid, ppv);
}

fn ipQueryInterface(this: *InvokeThis, iid: *const GUID, ppv: *?*anyopaque) callconv(WINAPI) HRESULT {
    return patQueryInterface(this, iid, ppv, "vtbl_invoke");
}
fn ipAddRef(_: *InvokeThis) callconv(WINAPI) ULONG {
    return 1;
}
fn ipRelease(_: *InvokeThis) callconv(WINAPI) ULONG {
    return 1;
}
fn ipInvoke(this: *InvokeThis) callconv(WINAPI) HRESULT {
    const self: *NodeProvider = @fieldParentPtr("vtbl_invoke", this);
    EnterCriticalSection(&g_a11y_lock);
    defer LeaveCriticalSection(&g_a11y_lock);
    return queueAction(self.index, .activate, "");
}

fn tpQueryInterface(this: *ToggleThis, iid: *const GUID, ppv: *?*anyopaque) callconv(WINAPI) HRESULT {
    return patQueryInterface(this, iid, ppv, "vtbl_toggle");
}
fn tpAddRef(_: *ToggleThis) callconv(WINAPI) ULONG {
    return 1;
}
fn tpRelease(_: *ToggleThis) callconv(WINAPI) ULONG {
    return 1;
}
fn tpToggle(this: *ToggleThis) callconv(WINAPI) HRESULT {
    const self: *NodeProvider = @fieldParentPtr("vtbl_toggle", this);
    EnterCriticalSection(&g_a11y_lock);
    defer LeaveCriticalSection(&g_a11y_lock);
    return queueAction(self.index, .activate, "");
}
fn tpGetState(this: *ToggleThis, out: *c_int) callconv(WINAPI) HRESULT {
    const self: *NodeProvider = @fieldParentPtr("vtbl_toggle", this);
    EnterCriticalSection(&g_a11y_lock);
    defer LeaveCriticalSection(&g_a11y_lock);
    if (self.index >= g_published_count) return UIA_E_ELEMENTNOTAVAILABLE;
    out.* = if (g_published_nodes_buf[self.index].state > 0.5) ToggleState_On else ToggleState_Off;
    return S_OK;
}

fn vpQueryInterface(this: *ValueThis, iid: *const GUID, ppv: *?*anyopaque) callconv(WINAPI) HRESULT {
    return patQueryInterface(this, iid, ppv, "vtbl_value");
}
fn vpAddRef(_: *ValueThis) callconv(WINAPI) ULONG {
    return 1;
}
fn vpRelease(_: *ValueThis) callconv(WINAPI) ULONG {
    return 1;
}
fn vpSetValue(this: *ValueThis, val: ?[*:0]const u16) callconv(WINAPI) HRESULT {
    const self: *NodeProvider = @fieldParentPtr("vtbl_value", this);
    const w = val orelse return E_INVALIDARG;
    var utf8: [1024]u8 = undefined;
    const n = std.unicode.utf16LeToUtf8(&utf8, std.mem.span(w)) catch return E_INVALIDARG;
    EnterCriticalSection(&g_a11y_lock);
    defer LeaveCriticalSection(&g_a11y_lock);
    return queueAction(self.index, .set_value, utf8[0..n]);
}
fn vpGetValue(this: *ValueThis, out: *BSTR) callconv(WINAPI) HRESULT {
    const self: *NodeProvider = @fieldParentPtr("vtbl_value", this);
    EnterCriticalSection(&g_a11y_lock);
    defer LeaveCriticalSection(&g_a11y_lock);
    if (self.index >= g_published_count) return UIA_E_ELEMENTNOTAVAILABLE;
    var utf16_buf: [512]u16 = undefined;
    const len = std.unicode.utf8ToUtf16Le(&utf16_buf, g_published_nodes_buf[self.index].value) catch 0;
    const clamped: usize = @min(len, utf16_buf.len - 1);
    utf16_buf[clamped] = 0;
    out.* = SysAllocString(@ptrCast(&utf16_buf));
    return S_OK;
}
fn vpGetIsReadOnly(this: *ValueThis, out: *BOOL) callconv(WINAPI) HRESULT {
    const self: *NodeProvider = @fieldParentPtr("vtbl_value", this);
    EnterCriticalSection(&g_a11y_lock);
    defer LeaveCriticalSection(&g_a11y_lock);
    out.* = if (self.index < g_published_count and g_published_nodes_buf[self.index].disabled) 1 else 0;
    return S_OK;
}

fn npGetPropertyValue(this: *SimpleThis, prop_id: c_long, var_out: *VARIANT) callconv(WINAPI) HRESULT {
    const self: *NodeProvider = @fieldParentPtr("vtbl_simple", this);
    return nodeGetPropertyValue(self, prop_id, var_out);
}

fn npGetHostRawElementProvider(_: *SimpleThis, pp: *?*anyopaque) callconv(WINAPI) HRESULT {
    // Only the root delegates to UiaHostProviderFromHwnd. Fragment
    // children must return null per the UIA spec.
    pp.* = null;
    return S_OK;
}

// ── NodeProvider vtable methods (Fragment) ─────────────────────────

fn npfQueryInterface(this: *FragmentThis, iid: *const GUID, ppv: *?*anyopaque) callconv(WINAPI) HRESULT {
    const self: *NodeProvider = @fieldParentPtr("vtbl_fragment", this);
    return nodeQueryInterface(self, iid, ppv);
}

fn npfAddRef(_: *FragmentThis) callconv(WINAPI) ULONG {
    return 1;
}

fn npfRelease(_: *FragmentThis) callconv(WINAPI) ULONG {
    return 1;
}

fn npfNavigate(this: *FragmentThis, direction: NavigateDirection, out: *?*anyopaque) callconv(WINAPI) HRESULT {
    const self: *NodeProvider = @fieldParentPtr("vtbl_fragment", this);

    EnterCriticalSection(&g_a11y_lock);
    defer LeaveCriticalSection(&g_a11y_lock);

    switch (direction) {
        .parent => {
            out.* = @ptrCast(&g_root_provider.vtbl_fragment);
            return S_OK;
        },
        .next_sibling => {
            const next = self.index +| 1;
            if (next < g_published_count) {
                out.* = @ptrCast(&g_node_providers[next].vtbl_fragment);
            } else {
                out.* = null;
            }
            return S_OK;
        },
        .previous_sibling => {
            if (self.index == 0) {
                out.* = null;
            } else {
                out.* = @ptrCast(&g_node_providers[self.index - 1].vtbl_fragment);
            }
            return S_OK;
        },
        .first_child, .last_child => {
            // Flat tree — no nesting in MVP.
            out.* = null;
            return S_OK;
        },
    }
}

fn npfGetRuntimeId(this: *FragmentThis, out: *?*SAFEARRAY) callconv(WINAPI) HRESULT {
    const self: *NodeProvider = @fieldParentPtr("vtbl_fragment", this);
    EnterCriticalSection(&g_a11y_lock);
    const cmd_idx: c_int = if (self.index < g_published_count)
        @intCast(g_published_nodes_buf[self.index].cmd_index)
    else
        @intCast(self.index);
    LeaveCriticalSection(&g_a11y_lock);

    return makeRuntimeIdArray(cmd_idx, out);
}

fn npfGetBoundingRectangle(this: *FragmentThis, rect: *UiaRect) callconv(WINAPI) HRESULT {
    const self: *NodeProvider = @fieldParentPtr("vtbl_fragment", this);

    EnterCriticalSection(&g_a11y_lock);
    if (self.index >= g_published_count) {
        LeaveCriticalSection(&g_a11y_lock);
        rect.* = .{ .left = 0, .top = 0, .width = 0, .height = 0 };
        return S_OK;
    }
    const b = g_published_nodes_buf[self.index].bounds;
    LeaveCriticalSection(&g_a11y_lock);

    const origin = screenOrigin();
    rect.* = .{
        .left = @as(f64, @floatFromInt(origin.x)) + @as(f64, b.x),
        .top = @as(f64, @floatFromInt(origin.y)) + @as(f64, b.y),
        .width = @as(f64, b.w),
        .height = @as(f64, b.h),
    };
    return S_OK;
}

fn npfGetEmbeddedFragmentRoots(_: *FragmentThis, out: *?*SAFEARRAY) callconv(WINAPI) HRESULT {
    out.* = null;
    return S_OK;
}

fn npfSetFocus(_: *FragmentThis) callconv(WINAPI) HRESULT {
    // No-op for the MVP. Routing this back into a Msg would require a
    // new Host §4 hatch — out of scope here.
    return S_OK;
}

fn npfGetFragmentRoot(_: *FragmentThis, out: *?*anyopaque) callconv(WINAPI) HRESULT {
    out.* = @ptrCast(&g_root_provider.vtbl_root);
    return S_OK;
}

// ── Shared NodeProvider helpers ────────────────────────────────────

/// Build the 2-element SAFEARRAY UIA expects from `GetRuntimeId` —
/// `[UiaAppendRuntimeId, caller_id]`. `caller_id` is 0 for the root
/// (UIA fills in a unique prefix) and the node's `cmd_index` for
/// fragments.
fn makeRuntimeIdArray(caller_id: c_int, out: *?*SAFEARRAY) HRESULT {
    const sa = SafeArrayCreateVector(@as(c_short, @intCast(VT_I4)), 0, 2) orelse {
        out.* = null;
        return E_FAIL;
    };
    var data_ptr: ?*anyopaque = null;
    if (SafeArrayAccessData(sa, &data_ptr) != S_OK or data_ptr == null) {
        out.* = null;
        return E_FAIL;
    }
    const ids: [*]c_int = @ptrCast(@alignCast(data_ptr.?));
    ids[0] = UiaAppendRuntimeId;
    ids[1] = caller_id;
    _ = SafeArrayUnaccessData(sa);
    out.* = sa;
    return S_OK;
}

fn nodeQueryInterface(self: *NodeProvider, iid: *const GUID, ppv: *?*anyopaque) HRESULT {
    if (guidEql(iid, &IID_IUnknown) or guidEql(iid, &IID_IRawElementProviderSimple)) {
        ppv.* = @ptrCast(&self.vtbl_simple);
        return S_OK;
    }
    if (guidEql(iid, &IID_IRawElementProviderFragment)) {
        ppv.* = @ptrCast(&self.vtbl_fragment);
        return S_OK;
    }
    if (guidEql(iid, &IID_IInvokeProvider)) {
        ppv.* = @ptrCast(&self.vtbl_invoke);
        return S_OK;
    }
    if (guidEql(iid, &IID_IToggleProvider)) {
        ppv.* = @ptrCast(&self.vtbl_toggle);
        return S_OK;
    }
    if (guidEql(iid, &IID_IValueProvider)) {
        ppv.* = @ptrCast(&self.vtbl_value);
        return S_OK;
    }
    ppv.* = null;
    return E_NOINTERFACE;
}

fn controlTypeForRole(role: A11yRole) c_long {
    return switch (role) {
        .group => UIA_GroupControlTypeId,
        .scroll => UIA_PaneControlTypeId,
        .text => UIA_TextControlTypeId,
        .rich_text => UIA_TextControlTypeId,
        .button => UIA_ButtonControlTypeId,
        .text_input, .text_area => UIA_EditControlTypeId,
        .checkbox => UIA_CheckBoxControlTypeId,
        .radio => UIA_RadioButtonControlTypeId,
        .slider => UIA_SliderControlTypeId,
        .divider => UIA_SeparatorControlTypeId,
        .image => UIA_ImageControlTypeId,
        // A canvas (chart / plot) is a custom-drawn graphic announced by
        // its label — Image is the closest UIA control type, matching
        // `.image` above (its primitives aren't individually exposed).
        .canvas => UIA_ImageControlTypeId,
        .overlay => UIA_PaneControlTypeId,
        .list, .listbox => UIA_ListControlTypeId,
        .listitem, .option => UIA_ListItemControlTypeId,
        .combobox => UIA_ComboBoxControlTypeId,
        .tablist => UIA_TabControlTypeId,
        .tab => UIA_TabItemControlTypeId,
        .tree => UIA_TreeControlTypeId,
        .treeitem => UIA_TreeItemControlTypeId,
        .table => UIA_TableControlTypeId,
        .row, .cell => UIA_DataItemControlTypeId,
        .columnheader => UIA_HeaderItemControlTypeId,
        .menu => UIA_MenuControlTypeId,
        .menubar => UIA_MenuBarControlTypeId,
        .menuitem => UIA_MenuItemControlTypeId,
        .toolbar => UIA_ToolBarControlTypeId,
        .dialog => UIA_PaneControlTypeId,
        .status, .alert => UIA_StatusBarControlTypeId,
        .progressbar => UIA_ProgressBarControlTypeId,
        .heading => UIA_TextControlTypeId,
        .link => UIA_HyperlinkControlTypeId,
    };
}

fn isFocusableRole(role: A11yRole) bool {
    return switch (role) {
        .button, .text_input, .text_area, .checkbox, .radio, .slider, .tab, .menuitem, .option, .treeitem, .link, .combobox => true,
        else => false,
    };
}

/// VARIANT_TRUE / VARIANT_FALSE are the Windows BOOL conventions for
/// the VT_BOOL variant payload. Don't confuse with c_int 0/1.
const VARIANT_TRUE: VARIANT_BOOL = -1;
const VARIANT_FALSE: VARIANT_BOOL = 0;

fn setBoolVariant(var_out: *VARIANT, b: bool) void {
    var_out.* = .{ .vt = VT_BOOL };
    const v: VARIANT_BOOL = if (b) VARIANT_TRUE else VARIANT_FALSE;
    @memcpy(var_out.payload[0..@sizeOf(VARIANT_BOOL)], std.mem.asBytes(&v));
}

/// Screen-coord origin of the window's client area. Zero if the HWND
/// isn't registered yet — callers add per-node offsets on top, so a
/// zero origin yields client-coord rectangles (still useful, just not
/// truly screen-coord).
fn screenOrigin() POINT {
    var origin: POINT = .{ .x = 0, .y = 0 };
    if (g_hwnd_for_uia) |hwnd| {
        _ = ClientToScreen(hwnd, &origin);
    }
    return origin;
}

fn nodeGetPropertyValue(self: *NodeProvider, prop_id: c_long, var_out: *VARIANT) HRESULT {
    EnterCriticalSection(&g_a11y_lock);
    defer LeaveCriticalSection(&g_a11y_lock);

    if (self.index >= g_published_count) {
        var_out.* = .{ .vt = VT_EMPTY };
        return S_OK;
    }
    const node = g_published_nodes_buf[self.index];

    switch (prop_id) {
        UIA_ControlTypePropertyId => {
            var_out.* = .{ .vt = VT_I4 };
            const v: c_long = controlTypeForRole(node.role);
            @memcpy(var_out.payload[0..@sizeOf(c_long)], std.mem.asBytes(&v));
            return S_OK;
        },
        UIA_NamePropertyId => {
            // Convert UTF-8 label → UTF-16 on the stack; allocate the
            // BSTR from the converted buffer. Labels capped at the
            // heap slot length (see MAX_A11Y_LABEL_BYTES).
            var utf16_buf: [512]u16 = undefined;
            const utf16_len = std.unicode.utf8ToUtf16Le(&utf16_buf, node.label) catch 0;
            const clamped: usize = @min(utf16_len, utf16_buf.len - 1);
            utf16_buf[clamped] = 0;
            const bstr = SysAllocString(@ptrCast(&utf16_buf));
            var_out.* = .{ .vt = VT_BSTR };
            @memcpy(var_out.payload[0..@sizeOf(BSTR)], std.mem.asBytes(&bstr));
            return S_OK;
        },
        UIA_IsKeyboardFocusablePropertyId => {
            setBoolVariant(var_out, isFocusableRole(node.role));
            return S_OK;
        },
        UIA_HasKeyboardFocusPropertyId => {
            setBoolVariant(var_out, node.focused);
            return S_OK;
        },
        else => {
            var_out.* = .{ .vt = VT_EMPTY };
            return S_OK;
        },
    }
}

fn guidEql(a: *const GUID, b: *const GUID) bool {
    if (a.Data1 != b.Data1) return false;
    if (a.Data2 != b.Data2) return false;
    if (a.Data3 != b.Data3) return false;
    return std.mem.eql(u8, &a.Data4, &b.Data4);
}

var g_root_provider_vtbl_simple: IRawElementProviderSimple_Vtbl = .{
    .QueryInterface = rpQueryInterface,
    .AddRef = rpAddRef,
    .Release = rpRelease,
    .get_ProviderOptions = rpGetProviderOptions,
    .GetPatternProvider = rpGetPatternProvider,
    .GetPropertyValue = rpGetPropertyValue,
    .get_HostRawElementProvider = rpGetHostRawElementProvider,
};

var g_root_provider_vtbl_fragment: IRawElementProviderFragment_Vtbl = .{
    .QueryInterface = rpfQueryInterface,
    .AddRef = rpfAddRef,
    .Release = rpfRelease,
    .Navigate = rpfNavigate,
    .GetRuntimeId = rpfGetRuntimeId,
    .get_BoundingRectangle = rpfGetBoundingRectangle,
    .GetEmbeddedFragmentRoots = rpfGetEmbeddedFragmentRoots,
    .SetFocus = rpfSetFocus,
    .get_FragmentRoot = rpfGetFragmentRoot,
};

var g_root_provider_vtbl_root: IRawElementProviderFragmentRoot_Vtbl = .{
    .QueryInterface = rprQueryInterface,
    .AddRef = rprAddRef,
    .Release = rprRelease,
    .ElementProviderFromPoint = rprElementProviderFromPoint,
    .GetFocus = rprGetFocus,
};

var g_root_provider: RootProvider = .{
    .vtbl_simple = &g_root_provider_vtbl_simple,
    .vtbl_fragment = &g_root_provider_vtbl_fragment,
    .vtbl_root = &g_root_provider_vtbl_root,
};

var g_node_provider_vtbl_simple: IRawElementProviderSimple_Vtbl = .{
    .QueryInterface = npQueryInterface,
    .AddRef = npAddRef,
    .Release = npRelease,
    .get_ProviderOptions = npGetProviderOptions,
    .GetPatternProvider = npGetPatternProvider,
    .GetPropertyValue = npGetPropertyValue,
    .get_HostRawElementProvider = npGetHostRawElementProvider,
};

var g_invoke_vtbl: IInvokeProvider_Vtbl = .{
    .QueryInterface = ipQueryInterface,
    .AddRef = ipAddRef,
    .Release = ipRelease,
    .Invoke = ipInvoke,
};

var g_toggle_vtbl: IToggleProvider_Vtbl = .{
    .QueryInterface = tpQueryInterface,
    .AddRef = tpAddRef,
    .Release = tpRelease,
    .Toggle = tpToggle,
    .get_ToggleState = tpGetState,
};

var g_value_vtbl: IValueProvider_Vtbl = .{
    .QueryInterface = vpQueryInterface,
    .AddRef = vpAddRef,
    .Release = vpRelease,
    .SetValue = vpSetValue,
    .get_Value = vpGetValue,
    .get_IsReadOnly = vpGetIsReadOnly,
};

var g_node_provider_vtbl_fragment: IRawElementProviderFragment_Vtbl = .{
    .QueryInterface = npfQueryInterface,
    .AddRef = npfAddRef,
    .Release = npfRelease,
    .Navigate = npfNavigate,
    .GetRuntimeId = npfGetRuntimeId,
    .get_BoundingRectangle = npfGetBoundingRectangle,
    .GetEmbeddedFragmentRoots = npfGetEmbeddedFragmentRoots,
    .SetFocus = npfSetFocus,
    .get_FragmentRoot = npfGetFragmentRoot,
};

/// Window title in UTF-16, allocated once and reused across
/// GetPropertyValue(NamePropertyId) calls. Updated by `Host.init`.
var g_window_title_w: [256]u16 = @splat(0);

/// HWND captured at Host.init for UiaHostProviderFromHwnd. Null before
/// init / after deinit so the property getter can fail closed.
var g_hwnd_for_uia: ?HANDLE = null;

// ── Stable a11y tree storage ───────────────────────────────────────
//
// `publishA11yTree`'s `nodes` slice points into the caller's per-
// frame arena — invalid after the next publish call AND unsafe for
// UIA queries (which may arrive on any thread, asynchronously). We
// snapshot into a fixed-size pair of buffers (node array + label
// string heap) under a critical section so UIA can read at will.
//
// MAX_A11Y_NODES bounds the published tree; oversize trees truncate
// silently. 256 nodes covers any realistic single-window app — large
// lists should be virtualized (cmd `push_virtual_list`) which
// collapses to one a11y node regardless of row count.
//
// MAX_A11Y_LABEL_BYTES is a flat string heap shared by all labels.
// Per-label cap is 512 (the SysAllocString stack buffer in
// `nodeGetPropertyValue`).

const MAX_A11Y_NODES: usize = 256;
const MAX_A11Y_LABEL_BYTES: usize = 8192;

var g_a11y_lock: CRITICAL_SECTION = .{};
var g_a11y_lock_initialized: bool = false;

var g_published_nodes_buf: [MAX_A11Y_NODES]A11yNode = undefined;
var g_published_count: usize = 0;
var g_label_heap: [MAX_A11Y_LABEL_BYTES]u8 = undefined;
var g_label_heap_used: usize = 0;

/// AT requests queued by the UIA pattern methods (worker thread, under
/// `g_a11y_lock`) and drained by `Host.pollA11yActions`.
var g_action_queue: teak.A11yActionQueue = .{};
/// Run-loop-owned copy of delivered action texts (valid until the next poll).
var g_action_text: [teak.A11yActionQueue.TEXT_CAP]u8 = undefined;

var g_node_providers: [MAX_A11Y_NODES]NodeProvider = undefined;
var g_node_providers_initialized: bool = false;

/// Initialize the static NodeProvider pool. Idempotent — safe to call
/// more than once across Host.init / deinit cycles.
fn initNodeProviderPool() void {
    if (g_node_providers_initialized) return;
    var i: u32 = 0;
    while (i < MAX_A11Y_NODES) : (i += 1) {
        g_node_providers[i] = .{
            .vtbl_simple = &g_node_provider_vtbl_simple,
            .vtbl_fragment = &g_node_provider_vtbl_fragment,
            .vtbl_invoke = &g_invoke_vtbl,
            .vtbl_toggle = &g_toggle_vtbl,
            .vtbl_value = &g_value_vtbl,
            .index = i,
        };
    }
    g_node_providers_initialized = true;
}

/// Coarse change detector — we only need to know whether the tree
/// *shape* has changed since the last publish so we can fire a single
/// StructureChanged event. A perfect diff is overkill for an MVP.
var g_last_tree_len: usize = 0;
var g_last_focus_index: ?u32 = null;

// ── Module-scoped state (written by wndProc, drained by pollInputs) ──

var g_running: bool = true;
var g_width: u32 = 0;
var g_height: u32 = 0;
var g_resized: bool = false;

/// Pointer, buttons, wheel, text and key queues for the primary window
/// (written by `wndProc`, drained by `pollInputs`). Wheel pixels follow the
/// `InputState` convention: positive dy = scroll down — Win32's
/// `WM_MOUSEWHEEL` reports the opposite, so `handleInputMessage` negates it.
var g_input: InputQueue = .{};

// IME composition mirror — populated from WM_IME_* messages and read by
// `imeState()`. The UTF-8 buffer is 256 bytes (≈85 CJK glyphs); longer
// compositions truncate cleanly. `g_ime_text_len == 0` plus
// `g_ime_active == false` means "no composition", which is also the
// default ImeState the renderer expects.
var g_ime_active: bool = false;
var g_ime_text: [256]u8 = undefined;
var g_ime_text_len: usize = 0;
var g_ime_cursor: usize = 0;

// ── Secondary windows ──────────────────────────────────────────────
//
// Single shared message queue (one per thread) feeds both the primary
// `wndProc` and `secondaryWndProc`; Win32 routes each message to the
// hwnd's registered class proc, so the primary pollInputs loop pumps
// secondary messages too. Each slot owns an independent input queue
// drained by `pollSecondaryInputs`.

pub const MAX_SECONDARY_WINDOWS: usize = 4;

const SecondaryWindow = struct {
    hwnd: HANDLE,
    width: u32,
    height: u32,
    resized: bool,
    input: InputQueue,
    closed: bool,
};

var g_secondaries: [MAX_SECONDARY_WINDOWS]?SecondaryWindow = @splat(null);
var g_secondary_class_registered: bool = false;

/// Walk the slot table for an hwnd match. Returns a pointer to the
/// SecondaryWindow inside the optional payload (caller writes through
/// it back into g_secondaries), or null if the hwnd isn't tracked.
/// Single-message dispatch — keep it simple; the table is at most
/// MAX_SECONDARY_WINDOWS entries.
fn findSecondaryByHwnd(hwnd: HANDLE) ?*SecondaryWindow {
    for (&g_secondaries) |*slot| {
        if (slot.* == null) continue;
        const sw: *SecondaryWindow = &slot.*.?;
        if (sw.hwnd == hwnd) return sw;
    }
    return null;
}

fn secondaryWndProc(hwnd: HANDLE, msg: UINT, wp: WPARAM, lp: LPARAM) callconv(WINAPI) LRESULT {
    const sw_opt = findSecondaryByHwnd(hwnd);
    const sw = sw_opt orelse return DefWindowProcW(hwnd, msg, wp, lp);
    switch (msg) {
        WM_DESTROY => {
            sw.closed = true;
            return 0;
        },
        WM_DROPFILES => {
            const hdrop: HANDLE = @ptrFromInt(wp);
            queueDroppedFiles(hdrop);
            DragFinish(hdrop);
            return 0;
        },
        WM_SIZE => {
            const w: u32 = loword(lp);
            const h: u32 = hiword(lp);
            if (w > 0 and h > 0) {
                sw.width = toLogical(w);
                sw.height = toLogical(h);
                sw.resized = true;
            }
            return 0;
        },
        else => {
            if (handleInputMessage(&sw.input, hwnd, msg, wp, lp)) return 0;
            return DefWindowProcW(hwnd, msg, wp, lp);
        },
    }
}

fn loword(lp: LPARAM) u16 {
    return @truncate(@as(usize, @bitCast(lp)));
}
fn hiword(lp: LPARAM) u16 {
    return @truncate(@as(usize, @bitCast(lp)) >> 16);
}
fn lowordSigned(lp: LPARAM) i16 {
    return @bitCast(loword(lp));
}
fn hiwordSigned(lp: LPARAM) i16 {
    return @bitCast(hiword(lp));
}

/// Modifier state right now (`GetKeyState` high bit = held). Sampled per
/// message so it reflects the same instant as the event it accompanies.
fn currentMods() teak.Modifiers {
    return .{
        .shift = GetKeyState(VK_SHIFT) < 0,
        .ctrl = GetKeyState(VK_CONTROL) < 0,
        .alt = GetKeyState(VK_MENU) < 0,
        .meta = GetKeyState(VK_LWIN) < 0 or GetKeyState(VK_RWIN) < 0,
    };
}

fn navFromVk(vk: WPARAM) ?NavKey {
    return switch (vk) {
        VK_BACK => .backspace,
        VK_DELETE => .delete,
        VK_LEFT => .left,
        VK_RIGHT => .right,
        VK_UP => .up,
        VK_DOWN => .down,
        VK_HOME => .home,
        VK_END => .end,
        VK_PRIOR => .page_up,
        VK_NEXT => .page_down,
        VK_RETURN => .enter,
        VK_TAB => .tab,
        VK_ESCAPE => .escape,
        VK_F12 => .f12,
        VK_F10 => .f10,
        VK_APPS => .menu,
        VK_A => .a,
        VK_C => .c,
        VK_X => .x,
        VK_V => .v,
        VK_Y => .y,
        VK_Z => .z,
        else => null,
    };
}

/// Pointer / wheel / text / key messages, shared by the primary and
/// secondary window procedures. Returns true when `msg` was one of them.
/// Button presses capture the mouse so a drag that leaves the window still
/// delivers its release.
fn handleInputMessage(q: *InputQueue, hwnd: HANDLE, msg: UINT, wp: WPARAM, lp: LPARAM) bool {
    switch (msg) {
        WM_MOUSEMOVE, WM_LBUTTONDOWN, WM_LBUTTONUP, WM_RBUTTONDOWN, WM_RBUTTONUP, WM_MBUTTONDOWN, WM_MBUTTONUP => {
            q.mods = currentMods();
            q.pointerMoved(@as(f32, @floatFromInt(lowordSigned(lp))) / g_scale, @as(f32, @floatFromInt(hiwordSigned(lp))) / g_scale);
            switch (msg) {
                WM_LBUTTONDOWN => q.buttonDown(.left),
                WM_RBUTTONDOWN => q.buttonDown(.right),
                WM_MBUTTONDOWN => q.buttonDown(.middle),
                WM_LBUTTONUP => q.buttonUp(.left),
                WM_RBUTTONUP => q.buttonUp(.right),
                WM_MBUTTONUP => q.buttonUp(.middle),
                else => {},
            }
            if (q.buttons.any()) _ = SetCapture(hwnd) else _ = ReleaseCapture();
        },
        WM_MOUSEWHEEL, WM_MOUSEHWHEEL => {
            // GET_WHEEL_DELTA_WPARAM: HIWORD of wparam, signed. Vertical:
            // positive = wheel turned away from the user (content scrolls
            // up), InputState wants positive = down, so negate. Horizontal:
            // positive = tilted right, which already matches.
            const raw_delta: i16 = @bitCast(@as(u16, @truncate(wp >> 16)));
            const px = (@as(f32, @floatFromInt(raw_delta)) / WHEEL_DELTA) * WHEEL_PIXELS_PER_NOTCH;
            q.mods = currentMods();
            if (msg == WM_MOUSEWHEEL) q.wheel(0, -px) else q.wheel(px, 0);
        },
        // WM_CHAR delivers UTF-16 code units, including control codes
        // (backspace etc.) which the queue drops — special keys route
        // through WM_KEYDOWN.
        WM_CHAR => q.pushUtf16Unit(@truncate(wp)),
        WM_KEYDOWN => {
            q.mods = currentMods();
            if (navFromVk(wp)) |nk| {
                q.pushNav(nk);
                if (nk == .v and q.mods.ctrl) g_paste_requested = true;
            }
        },
        // Alt-modified keys and F10 arrive as "system" keys. Alt alone and F10
        // are ours (menu-bar activation) and are swallowed so Windows does not
        // open its own system menu; Alt+other still reaches DefWindowProc
        // (Alt+F4, Alt+Space), after clearing the pending Alt tap.
        WM_SYSKEYDOWN => {
            q.mods = currentMods();
            if (wp == VK_ALT) {
                if ((lp & (1 << 30)) == 0) q.altDown(); // ignore auto-repeat
            } else if (wp == VK_F10) {
                q.pushNav(.f10);
            } else {
                q.alt_clean = false;
                return false;
            }
        },
        WM_SYSKEYUP => {
            if (wp == VK_ALT) q.altUp() else if (wp != VK_F10) return false;
        },
        else => return false,
    }
    return true;
}

/// Map a UTF-16 code-unit offset to a UTF-8 byte offset by walking the
/// UTF-8 buffer's codepoints. Used to translate IME caret positions
/// (delivered as UTF-16 offsets) onto our UTF-8 composition mirror.
/// Clamped to the buffer's byte length on overrun.
fn utf16OffsetToUtf8(utf8: []const u8, utf16_off: usize) usize {
    var byte_i: usize = 0;
    var u16_i: usize = 0;
    while (byte_i < utf8.len and u16_i < utf16_off) {
        const len = std.unicode.utf8ByteSequenceLength(utf8[byte_i]) catch return utf8.len;
        if (byte_i + len > utf8.len) return utf8.len;
        const cp = std.unicode.utf8Decode(utf8[byte_i..][0..len]) catch return utf8.len;
        // BMP codepoints take one UTF-16 unit; astral plane takes two.
        u16_i += if (cp >= 0x10000) 2 else 1;
        byte_i += len;
    }
    return byte_i;
}

// IME mirror transitions, split out of `wndProc` so synthetic messages can
// test them without an input method context.

fn imeStart() void {
    g_ime_active = true;
    imeClearText();
}

fn imeEnd() void {
    g_ime_active = false;
    imeClearText();
}

fn imeClearText() void {
    g_ime_text_len = 0;
    g_ime_cursor = 0;
}

/// Store the in-progress composition (UTF-16 as the IME reports it) and the
/// caret, which arrives as a UTF-16 unit offset and is stored as a UTF-8 byte
/// offset into the mirror. A negative / absent caret parks it at the end.
fn imeSetComposition(utf16: []const u16, cursor_units: c_long) void {
    g_ime_text_len = std.unicode.utf16LeToUtf8(g_ime_text[0..], utf16) catch 0;
    g_ime_cursor = if (cursor_units >= 0 and g_ime_text_len > 0)
        utf16OffsetToUtf8(g_ime_text[0..g_ime_text_len], @intCast(cursor_units))
    else
        g_ime_text_len;
}

fn wndProc(hwnd: HANDLE, msg: UINT, wp: WPARAM, lp: LPARAM) callconv(WINAPI) LRESULT {
    switch (msg) {
        WM_SETCURSOR => {
            // Only the client area is ours; borders keep the system cursor.
            if ((@as(usize, @bitCast(lp)) & 0xFFFF) == HTCLIENT) {
                if (g_cursor) |c| {
                    _ = SetCursor(c);
                    return 1;
                }
            }
            return DefWindowProcW(hwnd, msg, wp, lp);
        },
        WM_DESTROY => {
            g_running = false;
            PostQuitMessage(0);
            return 0;
        },
        WM_SIZE => {
            const w: u32 = loword(lp);
            const h: u32 = hiword(lp);
            if (w > 0 and h > 0) {
                g_width = toLogical(w);
                g_height = toLogical(h);
                g_resized = true;
            }
            return 0;
        },
        WM_DPICHANGED => {
            // New DPI in the low word of wParam; lParam is the window rect
            // Windows suggests so the window keeps its logical size on the
            // new monitor. Accepting it triggers WM_SIZE -> re-layout.
            g_scale = dpiScale(loword(@bitCast(wp)));
            const r: *const RECT = @ptrFromInt(@as(usize, @bitCast(lp)));
            _ = SetWindowPos(hwnd, null, r.left, r.top, r.right - r.left, r.bottom - r.top, SWP_NOZORDER | SWP_NOACTIVATE);
            g_resized = true;
            return 0;
        },
        // An uncovered / invalidated area: the idle loop skips frames, so
        // force the next one. DefWindowProc validates the region.
        WM_PAINT => {
            g_resized = true;
            return DefWindowProcW(hwnd, msg, wp, lp);
        },
        WM_IME_STARTCOMPOSITION => {
            imeStart();
            // Returning 0 suppresses the default IME window so the
            // composition is only rendered inline by teak. The caret
            // still receives WM_CHAR on commit via the IME's normal
            // result-string flow.
            return 0;
        },
        WM_IME_COMPOSITION => {
            // GCS_RESULTSTR is delivered alongside the final
            // WM_IME_COMPOSITION when the user commits. We let the
            // system handle it (DefWindowProcW posts WM_CHAR per
            // committed codepoint), but we also clear our pre-commit
            // mirror so the renderer doesn't keep the stale composition
            // up between commit and ENDCOMPOSITION.
            // WM_IME_COMPOSITION's lParam is a bitfield of GCS_* flags in
            // its low 32 bits. Truncate the platform-width isize/usize to
            // a 32-bit DWORD; @truncate is the canonical Zig narrow-conversion.
            const flags: DWORD = @truncate(@as(usize, @bitCast(lp)));
            if ((flags & GCS_COMPSTR) != 0) {
                const himc_opt = ImmGetContext(hwnd);
                if (himc_opt) |himc| {
                    defer _ = ImmReleaseContext(hwnd, himc);
                    var utf16_buf: [256]u16 = undefined;
                    const byte_len = ImmGetCompositionStringW(
                        himc,
                        GCS_COMPSTR,
                        @ptrCast(&utf16_buf),
                        @intCast(utf16_buf.len * @sizeOf(u16)),
                    );
                    const units: usize = if (byte_len > 0) @min(@as(usize, @intCast(@divTrunc(byte_len, @as(c_long, @sizeOf(u16))))), utf16_buf.len) else 0;
                    const cur_units = ImmGetCompositionStringW(himc, GCS_CURSORPOS, null, 0);
                    imeSetComposition(utf16_buf[0..units], cur_units);
                }
            } else if ((flags & GCS_COMPSTR) == 0 and (flags & GCS_RESULTSTR) != 0) {
                // Commit-only message: drop the pre-commit mirror but
                // stay active until WM_IME_ENDCOMPOSITION arrives.
                imeClearText();
            }
            // Pass through so the IME's commit -> WM_CHAR path still fires.
            return DefWindowProcW(hwnd, msg, wp, lp);
        },
        WM_IME_ENDCOMPOSITION => {
            imeEnd();
            return 0;
        },
        WM_GETOBJECT => {
            // UIA root request — hand back our singleton provider. Any
            // other object id (MSAA, etc.) falls through to DefWindowProc
            // so the system can synthesize a default. UIA owns the AddRef
            // contract here; our static AddRef-returns-1 is safe because
            // the provider lives in module storage. We hand the Simple
            // vtable slot — UIA's QueryInterface will pivot to the
            // Fragment / FragmentRoot vtables on demand.
            if (lp == UiaRootObjectId) {
                return UiaReturnRawElementProvider(hwnd, wp, lp, @ptrCast(&g_root_provider.vtbl_simple));
            }
            return DefWindowProcW(hwnd, msg, wp, lp);
        },
        else => {
            if (handleInputMessage(&g_input, hwnd, msg, wp, lp)) return 0;
            return DefWindowProcW(hwnd, msg, wp, lp);
        },
    }
}

// ── Public types ───────────────────────────────────────────────────

pub const NativeHandle = struct {
    hinstance: HANDLE,
    hwnd: HANDLE,
};

pub const Host = struct {
    hinstance: HANDLE,
    hwnd: HANDLE,
    /// Declarative-effects service (HTTP workers, storage, clock, ...);
    /// the picker / clipboard / drop effects are handled by this Host.
    effects: *native_effects.Service,
    /// Persistent UTF-8 buffer for the most recent clipboard read.
    /// Valid until the next `clipboard().read()` call (which overwrites
    /// it). 64K is plenty for any reasonable text payload; longer pastes
    /// truncate cleanly.
    clipboard_buf: [65536]u8 = undefined,
    clipboard_len: usize = 0,

    /// Persistent UTF-8 buffer for the most recent file dialog path.
    /// Valid until the next file dialog call. MAX_PATH * 4 covers
    /// any 3-byte UTF-8 expansion of Windows' 260-codepoint limit.
    dialog_path_buf: [1024]u8 = undefined,
    dialog_path_len: usize = 0,

    /// Per-request slots for async file dialogs. Win32 fills these in
    /// the same call as the request (the OS picker is sync), so the
    /// app's first poll always resolves. The path slice in `.ok` aliases
    /// `dialog_path_buf`, so only one open dialog result is valid at a
    /// time — apps polling more than one request id in flight must
    /// consume each `.ok` immediately. The 4-slot cap is generous; the
    /// pattern is "request → wait one frame → poll → consume".
    file_dialog_slots: [MAX_FILE_DIALOG_SLOTS]FileDialogSlot = @splat(.{}),

    pub fn init(title: []const u8, width: u32, height: u32) !Host {
        // Declare per-monitor v2 awareness before any window exists (a
        // failure — Windows older than 10 1703, or awareness already set by
        // a manifest — leaves the previous mode, which is fine). The
        // `width`/`height` asked for are logical; the window is created at
        // the system DPI's physical size and WM_SIZE converts back.
        _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        g_scale = dpiScale(GetDpiForSystem());
        g_running = true;
        g_width = width;
        g_height = height;
        g_resized = true; // force initial surface configure on first pollInputs

        // UIA tree storage is shared between the (single-threaded) Win32
        // message loop and the UIA worker thread; serialize all access
        // through a critical section. Initialize once per Host.init —
        // safe to re-init across Host.init / deinit cycles because
        // `deinit` deletes the section first.
        if (!g_a11y_lock_initialized) {
            InitializeCriticalSection(&g_a11y_lock);
            g_a11y_lock_initialized = true;
        }
        initNodeProviderPool();

        const hinstance = GetModuleHandleW(null) orelse return error.GetModuleHandleFailed;

        // UTF-16 literal class name — built at comptime.
        const class_name = std.unicode.utf8ToUtf16LeStringLiteral("TeakWindow");
        const wc = WNDCLASSEXW{
            .style = CS_HREDRAW | CS_VREDRAW,
            .lpfnWndProc = &wndProc,
            .hInstance = hinstance,
            .hCursor = LoadCursorW(null, IDC_ARROW),
            .lpszClassName = class_name,
        };
        if (RegisterClassExW(&wc) == 0) return error.RegisterClassFailed;

        // Convert the caller's UTF-8 title to UTF-16 on the stack. 256
        // code units is enough for any reasonable window title.
        var title_buf: [256]u16 = undefined;
        const title_len = try std.unicode.utf8ToUtf16Le(&title_buf, title);
        if (title_len >= title_buf.len) return error.TitleTooLong;
        title_buf[title_len] = 0;

        // Mirror the title into module storage so UIA's
        // GetPropertyValue(Name) can hand it to SysAllocString without
        // touching the Host struct. Length-clamped + null-terminated.
        const title_clamped = @min(title_len, g_window_title_w.len - 1);
        @memcpy(g_window_title_w[0..title_clamped], title_buf[0..title_clamped]);
        g_window_title_w[title_clamped] = 0;

        const hwnd = CreateWindowExW(
            0,
            class_name,
            @ptrCast(&title_buf),
            WS_OVERLAPPEDWINDOW,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            @intFromFloat(@round(@as(f32, @floatFromInt(width)) * g_scale)),
            @intFromFloat(@round(@as(f32, @floatFromInt(height)) * g_scale)),
            null,
            null,
            hinstance,
            null,
        ) orelse return error.CreateWindowFailed;
        _ = ShowWindow(hwnd, SW_SHOW);
        registerDropTarget(hwnd);
        g_scale = dpiScale(GetDpiForWindow(hwnd));
        const effects = try native_effects.Service.create(title);
        errdefer effects.destroy();
        g_effects = effects;

        // Capture the HWND so UIA's get_HostRawElementProvider can hand
        // it to UiaHostProviderFromHwnd for any property we don't
        // ourselves answer.
        g_hwnd_for_uia = hwnd;

        return .{
            .hinstance = hinstance,
            .hwnd = hwnd,
            .effects = effects,
            .clipboard_buf = undefined,
            .clipboard_len = 0,
            .dialog_path_buf = undefined,
            .dialog_path_len = 0,
            .file_dialog_slots = @splat(.{}),
        };
    }

    pub fn deinit(self: *Host) void {
        // Disconnect any lingering UIA listeners (Narrator, Inspect)
        // so they drop their references cleanly before we tear down
        // the underlying window/DC. Return value is ignored — there's
        // nothing actionable if it fails. Hand UIA the same Simple
        // vtable slot we returned from WM_GETOBJECT.
        _ = UiaDisconnectProvider(@ptrCast(&g_root_provider.vtbl_simple));
        g_hwnd_for_uia = null;

        // Tear down the critical section last (after Uia listeners
        // have been disconnected, so no async query is in flight).
        if (g_a11y_lock_initialized) {
            DeleteCriticalSection(&g_a11y_lock);
            g_a11y_lock_initialized = false;
        }

        unregisterDropTarget(self.hwnd);
        g_effects = null;
        self.effects.destroy();
        text.releaseFaces();
        // Win32 cleans up the window on process exit; explicit teardown
        // would require tracking class registration state.
    }

    pub fn pollInputs(_: *Host) InputState {
        // Queues reset before pumping; edges are latched until `finish`.
        // They must survive across the pump so Host.init's initial
        // resized=true flag (set before the first pump) is returned on frame 1.
        g_input.beginFrame();

        var msg: MSG = undefined;
        while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE) != 0) {
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }

        const resized = g_resized;
        g_resized = false;
        return g_input.finish(resized, g_width, g_height);
    }

    pub fn shouldClose(_: *const Host) bool {
        return !g_running;
    }

    pub fn nativeHandle(self: *const Host) NativeHandle {
        return .{ .hinstance = self.hinstance, .hwnd = self.hwnd };
    }

    /// Update the window title from a UTF-8 string. Mirrors init's title
    /// conversion: UTF-8 → stack UTF-16 (256 code units) → SetWindowTextW.
    /// A title is cosmetic, so an over-long or invalid string is dropped
    /// rather than erroring.
    /// Show `shape` over the client area (`WM_SETCURSOR` re-applies it whenever
    /// Windows asks, so it survives pointer moves).
    pub fn setCursor(_: *Host, shape: teak.CursorShape) void {
        g_cursor = LoadCursorW(null, @ptrFromInt(idcFor(shape)));
        _ = SetCursor(g_cursor);
    }

    pub fn setTitle(self: *Host, title: []const u8) void {
        var title_buf: [256]u16 = undefined;
        const title_len = std.unicode.utf8ToUtf16Le(&title_buf, title) catch return;
        if (title_len >= title_buf.len) return;
        title_buf[title_len] = 0;
        _ = SetWindowTextW(self.hwnd, @ptrCast(&title_buf));
    }

    // ── Declarative effects (docs/features/effects.md) ─────────────

    /// Start one effect. The file pickers, the clipboard and downloads are
    /// native Win32 UI and run here (blocking the frame while a dialog is
    /// up, like `openFileDialog`); everything else (HTTP on worker threads,
    /// storage under `%APPDATA%\teak\<app>`, clock, command-line query
    /// parameters) is the shared `native_effects.Service`. `TEAK_OPEN` /
    /// `TEAK_OUT` skip the dialogs so scripted runs stay hands-free.
    pub fn submit(self: *Host, e: teak.Effect) teak.EffectSubmit {
        switch (e) {
            .open_file => |o| {
                if (native_effects.envSet("TEAK_OPEN")) return self.effects.submit(e);
                self.effects.openPath(o.id, runFileDialog(self, .{}, false, ""));
            },
            .download => |d| {
                if (native_effects.envSet("TEAK_OUT")) return self.effects.submit(e);
                if (runFileDialog(self, .{}, true, std.fs.path.basename(d.name))) |path| {
                    self.effects.downloadTo(d.id, path, d.bytes);
                } else self.effects.downloadCancelled(d.id);
            },
            .write_clipboard => |w| clipWrite(@ptrCast(self), w.text),
            else => return self.effects.submit(e),
        }
        return .accepted;
    }

    /// Finished effect results plus files dropped on the window since the
    /// last poll. Slices stay valid until the next call.
    pub fn pollEffectResults(self: *Host, buf: []teak.EffectResult) usize {
        var i: usize = 0;
        while (i < g_drop_count) : (i += 1) self.effects.dropFile(g_drops[i][0..g_drop_lens[i]]);
        g_drop_count = 0;
        // A Ctrl+V the app's `handleClipboard` did not claim through
        // `Clipboard.read` is a page-style paste: text or an image.
        if (g_paste_requested) {
            g_paste_requested = false;
            pasteUnclaimed();
        }
        return self.effects.poll(buf, self.nowMs());
    }

    /// Name the app's storage directory (`%APPDATA%\teak\<name>\`);
    /// defaults to the window title.
    pub fn setAppName(self: *Host, name: []const u8) void {
        self.effects.setAppName(name) catch {};
    }

    /// The shared stb_truetype measurer (`teak-text`): the same faces and
    /// scale math the Gpu rasterizes from, so layout and render agree and
    /// `FontSpec.letter_spacing` is honoured identically on every native OS.
    pub fn textMeasurer(self: *Host) TextMeasurer {
        return .{ .ctx = @ptrCast(self), .measure_fn = stbMeasure };
    }

    fn stbMeasure(_: *anyopaque, text_bytes: []const u8, font: FontSpec) TextMetrics {
        return text.measure(text_bytes, font);
    }

    /// Register the TTF `ttf` (typically `@embedFile`, borrowed — keep it
    /// alive) as the face for (`family`, `weight`), shared by the measurer
    /// and the Gpu's rasterizer. Register before the first frame. A family
    /// without a registered face uses the system monospace font
    /// (`%WINDIR%\Fonts\consola.ttf`, or `TEAK_FONT`).
    pub fn registerFont(_: *Host, family: teak.FontFamily, weight: teak.FontWeight, ttf: []const u8) !void {
        try text.registerFace(family, weight, ttf);
    }

    pub fn clipboard(self: *Host) Clipboard {
        return .{ .ctx = @ptrCast(self), .read_fn = clipRead, .write_fn = clipWrite };
    }

    /// Composition state mirror, populated by WM_IME_* handlers in
    /// `wndProc`. The slice points into `g_ime_text` which is overwritten
    /// on the next WM_IME_COMPOSITION — callers must consume it within
    /// the current frame (the host loop snapshots it into TransientState
    /// before kicking off render). When inactive the default value is
    /// safe: empty slice, cursor 0.
    pub fn imeState(_: *const Host) ImeState {
        return .{
            .active = g_ime_active,
            .text = g_ime_text[0..g_ime_text_len],
            .cursor = g_ime_cursor,
        };
    }

    /// Forward the a11y tree to the platform. We snapshot the nodes
    /// (plus their labels) into module-scoped storage, then fire a
    /// StructureChanged event whenever the published tree differs from
    /// the previous one. Narrator iterates the snapshot via the per-
    /// node Fragment providers (see `NodeProvider` near the COM
    /// vtables); Inspect.exe can also enumerate live properties.
    pub fn publishA11yTree(_: *Host, nodes: []const A11yNode) void {
        // Snapshot the caller's per-frame slice into module-scoped
        // storage so UIA can read it at any time on a worker thread.
        // The label heap is a flat bump arena; on overflow we drop the
        // overflowing label (empty string) rather than fail the publish.
        EnterCriticalSection(&g_a11y_lock);

        const cap = @min(nodes.len, MAX_A11Y_NODES);
        g_label_heap_used = 0;
        for (nodes[0..cap], 0..) |src, i| {
            var n = src;
            // Copy the label into the heap and rewrite its slice to
            // point at the stable copy. On heap exhaustion the label
            // is dropped (slice cleared) so we never alias arena
            // memory across frames.
            const remaining = MAX_A11Y_LABEL_BYTES - g_label_heap_used;
            const take = @min(n.label.len, remaining);
            if (take > 0) {
                @memcpy(g_label_heap[g_label_heap_used..][0..take], n.label[0..take]);
                n.label = g_label_heap[g_label_heap_used..][0..take];
                g_label_heap_used += take;
            } else {
                n.label = &.{};
            }
            // Same for the value (ValuePattern.get_Value reads it on UIA's thread).
            const vremaining = MAX_A11Y_LABEL_BYTES - g_label_heap_used;
            const vtake = @min(n.value.len, vremaining);
            if (vtake > 0) {
                @memcpy(g_label_heap[g_label_heap_used..][0..vtake], n.value[0..vtake]);
                n.value = g_label_heap[g_label_heap_used..][0..vtake];
                g_label_heap_used += vtake;
            } else {
                n.value = &.{};
            }
            g_published_nodes_buf[i] = n;
        }
        g_published_count = cap;

        LeaveCriticalSection(&g_a11y_lock);

        // Coarse change detection: tree length + focused-cmd index is
        // enough to catch every shape change the framework can produce
        // in one frame without paying for a structural diff.
        var focus_idx: ?u32 = null;
        for (g_published_nodes_buf[0..g_published_count]) |n| {
            if (n.focused) {
                focus_idx = n.cmd_index;
                break;
            }
        }
        const changed = g_published_count != g_last_tree_len or focus_idx != g_last_focus_index;
        g_last_tree_len = g_published_count;
        g_last_focus_index = focus_idx;

        if (changed) {
            _ = UiaRaiseStructureChangedEvent(
                @ptrCast(&g_root_provider.vtbl_simple),
                StructureChangeType_ChildrenInvalidated,
                null,
                0,
            );
        }
    }

    /// Requests UIA clients made through the Invoke / Toggle / Value patterns
    /// since the last poll; `text` stays valid until the next call.
    pub fn pollA11yActions(_: *Host, out: []teak.A11yAction) usize {
        if (!g_a11y_lock_initialized) return 0;
        EnterCriticalSection(&g_a11y_lock);
        defer LeaveCriticalSection(&g_a11y_lock);
        return g_action_queue.drain(out, &g_action_text);
    }

    /// Blocks until the user picks a file or cancels. Returns a UTF-8
    /// slice into the Host's dialog buffer (valid until the next
    /// dialog call) or null on cancel.
    pub fn openFileDialog(self: *Host, filter: FileDialogFilter) FileDialogResult {
        return runFileDialog(self, filter, false, "");
    }

    pub fn saveFileDialog(self: *Host, filter: FileDialogFilter) FileDialogResult {
        return runFileDialog(self, filter, true, "");
    }

    /// Async file dialog request. Win32 has a synchronous file picker
    /// (`GetOpenFileNameW`), so we just run it inline and park the
    /// result in a per-request slot. Returns the slot's id (1-based;
    /// 0 means "no free slot"); the app polls via `pollFileDialogResult`.
    /// Designed so the same Host surface works for the browser (where
    /// the picker is genuinely async) without diverging.
    pub fn requestFileDialog(self: *Host, filter: FileDialogFilter) u32 {
        return submitFileDialog(self, filter, false);
    }

    pub fn requestSaveFileDialog(self: *Host, filter: FileDialogFilter) u32 {
        return submitFileDialog(self, filter, true);
    }

    /// Read the parked result for a request id. On Win32 this is a
    /// single-frame round trip — the slot is filled before the request
    /// call returns, so the first poll always resolves. After `.ok` /
    /// `.cancelled` the slot is freed; a second poll on the same id
    /// returns `.pending` (treated by callers as "unknown / consumed").
    pub fn pollFileDialogResult(self: *Host, id: u32) FileDialogPoll {
        if (id == 0 or id > MAX_FILE_DIALOG_SLOTS) return .{ .pending = {} };
        const slot = &self.file_dialog_slots[id - 1];
        if (!slot.active) return .{ .pending = {} };
        const result: FileDialogPoll = if (slot.has_path)
            .{ .ok = self.dialog_path_buf[0..slot.path_len] }
        else
            .{ .cancelled = {} };
        slot.active = false;
        slot.has_path = false;
        slot.path_len = 0;
        return result;
    }

    /// Create a second top-level Win32 window. Returns an opaque id
    /// (1-based slot index) on success, `null` if the slot table is
    /// full or window creation fails. The GPU surface for the new
    /// window is NOT created here — the app must call
    /// `gpu.openSecondarySurface(host.secondaryWindowHandle(id))` to
    /// bind a wgpu surface in lock-step.
    pub fn openSecondaryWindow(self: *Host, title: []const u8, w: u32, h: u32) ?u32 {
        // Find first empty slot.
        var slot_idx: usize = MAX_SECONDARY_WINDOWS;
        for (g_secondaries, 0..) |s, i| {
            if (s == null) {
                slot_idx = i;
                break;
            }
        }
        if (slot_idx == MAX_SECONDARY_WINDOWS) return null;

        // Register the secondary class once per process.
        if (!g_secondary_class_registered) {
            const sec_class = std.unicode.utf8ToUtf16LeStringLiteral("TeakSecondaryWindow");
            const wc = WNDCLASSEXW{
                .style = CS_HREDRAW | CS_VREDRAW,
                .lpfnWndProc = &secondaryWndProc,
                .hInstance = self.hinstance,
                .hCursor = LoadCursorW(null, IDC_ARROW),
                .lpszClassName = sec_class,
            };
            if (RegisterClassExW(&wc) == 0) return null;
            g_secondary_class_registered = true;
        }

        var title_buf: [256]u16 = undefined;
        const title_len = std.unicode.utf8ToUtf16Le(&title_buf, title) catch return null;
        if (title_len >= title_buf.len) return null;
        title_buf[title_len] = 0;

        const sec_class = std.unicode.utf8ToUtf16LeStringLiteral("TeakSecondaryWindow");
        const hwnd = CreateWindowExW(
            0,
            sec_class,
            @ptrCast(&title_buf),
            WS_OVERLAPPEDWINDOW,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            @intCast(w),
            @intCast(h),
            null,
            null,
            self.hinstance,
            null,
        ) orelse return null;

        g_secondaries[slot_idx] = .{
            .hwnd = hwnd,
            .width = w,
            .height = h,
            .resized = true, // first poll should publish dimensions
            .input = .{},
            .closed = false,
        };

        _ = ShowWindow(hwnd, SW_SHOW);
        return @intCast(slot_idx + 1);
    }

    /// Drain input queues for the given secondary window id. Returns
    /// null when `id` is 0, out of range, the slot is empty, or the
    /// window has been closed (caller treats as "window gone" and
    /// should call `closeSecondaryWindow`).
    pub fn pollSecondaryInputs(_: *Host, window_id: u32) ?InputState {
        if (window_id == 0 or window_id > MAX_SECONDARY_WINDOWS) return null;
        const slot_idx: usize = @intCast(window_id - 1);
        const slot_opt = &g_secondaries[slot_idx];
        if (slot_opt.* == null) return null;
        const sw: *SecondaryWindow = &slot_opt.*.?;
        if (sw.closed) return null;

        // Messages for this window were already pumped by the primary
        // `pollInputs`. Slices in the returned state alias `sw.input`: reset
        // the queue lengths only AFTER building them, so the next frame's
        // messages start at index 0 (valid until the next poll, as for the
        // primary window).
        const resized = sw.resized;
        sw.resized = false;
        const state = sw.input.finish(resized, sw.width, sw.height);
        sw.input.beginFrame();
        return state;
    }

    /// Destroy a secondary window and free its slot. No-op on invalid
    /// ids. Idempotent — calling twice is safe (second call hits a
    /// null slot).
    pub fn closeSecondaryWindow(_: *Host, window_id: u32) void {
        if (window_id == 0 or window_id > MAX_SECONDARY_WINDOWS) return;
        const slot_idx: usize = @intCast(window_id - 1);
        if (g_secondaries[slot_idx]) |sw| {
            // DestroyWindow posts WM_DESTROY; secondaryWndProc handles
            // it (sets `closed`). We blank the slot here directly so
            // the id can be reused immediately.
            _ = DestroyWindow(sw.hwnd);
            g_secondaries[slot_idx] = null;
        }
    }

    /// Look up the native handle for a secondary window so the app can
    /// pass it to `gpu.openSecondarySurface`. Returns null for invalid
    /// or empty ids.
    pub fn secondaryWindowHandle(self: *const Host, window_id: u32) ?NativeHandle {
        if (window_id == 0 or window_id > MAX_SECONDARY_WINDOWS) return null;
        const slot_idx: usize = @intCast(window_id - 1);
        if (g_secondaries[slot_idx]) |sw| {
            return .{ .hinstance = self.hinstance, .hwnd = sw.hwnd };
        }
        return null;
    }

    /// Monotonic milliseconds since some arbitrary epoch. Uses Zig's
    /// the `std.Io` awake clock, which is fine for sub-driven cadence
    /// — subs compare deltas, not absolute values.
    /// Event-driven idle: block until a message is queued for this thread
    /// (input, paint, resize, IME) or `timeout_ms` passes.
    pub fn waitEvents(_: *Host, timeout_ms: u32) void {
        _ = MsgWaitForMultipleObjectsEx(0, null, timeout_ms, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
    }

    pub fn nowMs(_: *const Host) u64 {
        // Monotonic milliseconds (clocks live behind `std.Io`).
        const now = std.Io.Clock.awake.now(std.Options.debug_io);
        return @intCast(@divFloor(now.nanoseconds, std.time.ns_per_ms));
    }

    /// Physical device pixels per logical unit at the window's current
    /// DPI. The process declares per-monitor v2 awareness in `init`, so
    /// this is the true monitor factor (1.0 at 96 DPI, 2.0 at 192).
    pub fn scaleFactor(self: *const Host) f32 {
        // (per-monitor v2 is declared in `init`, so this is the real factor)
        const dpi = GetDpiForWindow(self.hwnd);
        if (dpi == 0) return 1.0; // pre-1607 or invalid HWND
        return @as(f32, @floatFromInt(dpi)) / USER_DEFAULT_SCREEN_DPI;
    }

    /// Submit a request-style file dialog: find a free slot, run the
    /// (synchronous) OS picker, park the result, return the slot id.
    /// Returns 0 if the table is full or path conversion fails — the
    /// app treats 0 as "submission rejected, try later".
    fn submitFileDialog(self: *Host, filter: FileDialogFilter, save: bool) u32 {
        var slot_idx: usize = MAX_FILE_DIALOG_SLOTS;
        for (self.file_dialog_slots, 0..) |s, i| {
            if (!s.active) {
                slot_idx = i;
                break;
            }
        }
        if (slot_idx == MAX_FILE_DIALOG_SLOTS) return 0;

        const result = runFileDialog(self, filter, save, "");
        const slot = &self.file_dialog_slots[slot_idx];
        slot.active = true;
        if (result) |_| {
            slot.has_path = true;
            slot.path_len = self.dialog_path_len;
        } else {
            slot.has_path = false;
            slot.path_len = 0;
        }
        return @intCast(slot_idx + 1);
    }

    /// Show the (modal, blocking) picker. `initial_name` prefills the file
    /// name of a save dialog.
    fn runFileDialog(self: *Host, filter: FileDialogFilter, save: bool, initial_name: []const u8) FileDialogResult {
        var file_buf: [260]u16 = @splat(0);
        if (save and initial_name.len > 0) {
            // Truncate to leave the terminating NUL; an unconvertible name
            // just opens the dialog empty.
            _ = std.unicode.utf8ToUtf16Le(file_buf[0 .. file_buf.len - 1], initial_name) catch {};
        }

        // OFN filter format: "Name\0pattern\0Name2\0pattern2\0\0" — a
        // double-null-terminated alternating list. Build it on the stack.
        var filter_buf: [512]u16 = undefined;
        var off: usize = 0;
        const name_len = std.unicode.utf8ToUtf16Le(filter_buf[off..], filter.name) catch return null;
        off += name_len;
        if (off >= filter_buf.len - 1) return null;
        filter_buf[off] = 0;
        off += 1;
        const pat_len = std.unicode.utf8ToUtf16Le(filter_buf[off..], filter.pattern) catch return null;
        off += pat_len;
        if (off >= filter_buf.len - 2) return null;
        filter_buf[off] = 0;
        off += 1;
        filter_buf[off] = 0; // terminator
        const filter_ptr: LPCWSTR = @ptrCast(&filter_buf);

        var ofn = OPENFILENAMEW{
            .hwndOwner = self.hwnd,
            .lpstrFile = @ptrCast(&file_buf),
            .nMaxFile = file_buf.len,
            .lpstrFilter = filter_ptr,
            .Flags = OFN_EXPLORER | (if (save) OFN_OVERWRITEPROMPT else (OFN_PATHMUSTEXIST | OFN_FILEMUSTEXIST)),
        };

        const ok = if (save) GetSaveFileNameW(&ofn) else GetOpenFileNameW(&ofn);
        if (ok == 0) return null;

        // Find UTF-16 length (null-terminated by OFN).
        var u16_len: usize = 0;
        while (u16_len < file_buf.len and file_buf[u16_len] != 0) : (u16_len += 1) {}

        const written = std.unicode.utf16LeToUtf8(self.dialog_path_buf[0..], file_buf[0..u16_len]) catch return null;
        self.dialog_path_len = written;
        return self.dialog_path_buf[0..written];
    }

    fn clipRead(ctx: *anyopaque) []const u8 {
        const self: *Host = @ptrCast(@alignCast(ctx));
        g_paste_requested = false; // claimed: no `pasted_text` for this press
        if (OpenClipboard(null) == 0) return self.clipboard_buf[0..0];
        defer _ = CloseClipboard();

        const handle = GetClipboardData(CF_UNICODETEXT) orelse return self.clipboard_buf[0..0];
        const ptr = GlobalLock(handle) orelse return self.clipboard_buf[0..0];
        defer _ = GlobalUnlock(handle);

        const utf16_ptr: [*]const u16 = @ptrCast(@alignCast(ptr));
        // Find UTF-16 null terminator.
        var utf16_len: usize = 0;
        while (utf16_ptr[utf16_len] != 0) : (utf16_len += 1) {
            if (utf16_len >= self.clipboard_buf.len) break;
        }

        const written = std.unicode.utf16LeToUtf8(self.clipboard_buf[0..], utf16_ptr[0..utf16_len]) catch 0;
        self.clipboard_len = written;
        return self.clipboard_buf[0..written];
    }

    fn clipWrite(ctx: *anyopaque, t: []const u8) void {
        const self: *Host = @ptrCast(@alignCast(ctx));
        _ = self;
        if (t.len == 0) return;

        // UTF-8 → UTF-16 conversion. Cap at 32K UTF-16 code units (~64KB)
        // which is plenty for clipboard text.
        var utf16_buf: [32768]u16 = undefined;
        const utf16_len = std.unicode.utf8ToUtf16Le(&utf16_buf, t) catch return;
        if (utf16_len >= utf16_buf.len) return;

        const total_bytes = (utf16_len + 1) * @sizeOf(u16);
        const hmem = GlobalAlloc(GMEM_MOVEABLE, total_bytes) orelse return;
        const lock = GlobalLock(hmem) orelse return;
        const dst: [*]u16 = @ptrCast(@alignCast(lock));
        @memcpy(dst[0..utf16_len], utf16_buf[0..utf16_len]);
        dst[utf16_len] = 0;
        _ = GlobalUnlock(hmem);

        if (OpenClipboard(null) == 0) return;
        defer _ = CloseClipboard();
        _ = EmptyClipboard();
        _ = SetClipboardData(CF_UNICODETEXT, hmem);
    }
};

comptime {
    teak.validateHost(Host);
}

// ── Tests ──────────────────────────────────────────────────────────
//
// Win32-only smoke tests. Wired into `zig build test` via the
// `platform-win32` test target (Windows hosts only — see build.zig).
// Each test gates on `builtin.os.tag == .windows` so a cross-compiled
// run skips cleanly.

const builtin = @import("builtin");

test "uia per-node providers: publishA11yTree copies labels into the heap" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    // Initialize the same statics Host.init would set up. We don't
    // create a window — none of the per-node vtable methods exercised
    // here touch the HWND (BoundingRectangle does, but we don't call it).
    if (!g_a11y_lock_initialized) {
        InitializeCriticalSection(&g_a11y_lock);
        g_a11y_lock_initialized = true;
    }
    initNodeProviderPool();

    // Construct fake A11yNodes pointing at labels in an arena. Once
    // publishA11yTree returns, the labels in g_published_nodes_buf
    // must NOT alias these.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const lbl_btn = try a.dupe(u8, "Save");
    const lbl_input = try a.dupe(u8, "name");
    const lbl_check = try a.dupe(u8, "agree");

    const nodes = [_]A11yNode{
        .{ .role = .button, .cmd_index = 1, .bounds = .{ .x = 0, .y = 0, .w = 80, .h = 30 }, .label = lbl_btn },
        .{ .role = .text_input, .cmd_index = 2, .bounds = .{ .x = 0, .y = 40, .w = 200, .h = 30 }, .label = lbl_input, .focused = true },
        .{ .role = .checkbox, .cmd_index = 3, .bounds = .{ .x = 0, .y = 80, .w = 100, .h = 20 }, .label = lbl_check, .state = 1 },
    };

    var dummy_host: Host = undefined;
    dummy_host.publishA11yTree(&nodes);

    try std.testing.expectEqual(@as(usize, 3), g_published_count);
    // Labels should match by content but NOT by pointer (i.e. they
    // were copied into the heap).
    try std.testing.expectEqualStrings("Save", g_published_nodes_buf[0].label);
    try std.testing.expectEqualStrings("name", g_published_nodes_buf[1].label);
    try std.testing.expectEqualStrings("agree", g_published_nodes_buf[2].label);
    try std.testing.expect(g_published_nodes_buf[0].label.ptr != lbl_btn.ptr);
    try std.testing.expect(g_published_nodes_buf[1].label.ptr != lbl_input.ptr);
    try std.testing.expect(g_published_nodes_buf[2].label.ptr != lbl_check.ptr);

    // Root's Navigate(FirstChild) returns a non-null provider whose
    // GetPropertyValue(ControlType) matches the first node's role.
    var first_child: ?*anyopaque = null;
    const fragment_this_ptr: *FragmentThis = @ptrCast(&g_root_provider.vtbl_fragment);
    const nav_hr = g_root_provider_vtbl_fragment.Navigate(fragment_this_ptr, .first_child, &first_child);
    try std.testing.expectEqual(S_OK, nav_hr);
    try std.testing.expect(first_child != null);

    // The returned pointer is the address of a NodeProvider's
    // vtbl_fragment field — must be the first node in the pool.
    const child_fragment_ptr: *FragmentThis = @ptrCast(@alignCast(first_child.?));
    const child_node: *NodeProvider = @fieldParentPtr("vtbl_fragment", child_fragment_ptr);
    try std.testing.expectEqual(@as(u32, 0), child_node.index);

    // Read its ControlType via the Simple vtable.
    const simple_this_ptr: *SimpleThis = @ptrCast(&child_node.vtbl_simple);
    var v: VARIANT = .{ .vt = VT_EMPTY };
    const prop_hr = g_node_provider_vtbl_simple.GetPropertyValue(simple_this_ptr, UIA_ControlTypePropertyId, &v);
    try std.testing.expectEqual(S_OK, prop_hr);
    try std.testing.expectEqual(VT_I4, v.vt);
    var got_ct: c_long = 0;
    @memcpy(std.mem.asBytes(&got_ct), v.payload[0..@sizeOf(c_long)]);
    try std.testing.expectEqual(UIA_ButtonControlTypeId, got_ct);

    // GetFocus on the root should pick out the focused text_input
    // (node index 1).
    var focused: ?*anyopaque = null;
    const root_this_ptr: *FragmentRootThis = @ptrCast(&g_root_provider.vtbl_root);
    const focus_hr = g_root_provider_vtbl_root.GetFocus(root_this_ptr, &focused);
    try std.testing.expectEqual(S_OK, focus_hr);
    try std.testing.expect(focused != null);
    const focused_fragment_ptr: *FragmentThis = @ptrCast(@alignCast(focused.?));
    const focused_node: *NodeProvider = @fieldParentPtr("vtbl_fragment", focused_fragment_ptr);
    try std.testing.expectEqual(@as(u32, 1), focused_node.index);
}

test "DPI helpers: dpiScale and toLogical convert physical client pixels" {
    const saved = g_scale;
    defer g_scale = saved;
    try std.testing.expectEqual(@as(f32, 1.0), dpiScale(0));
    try std.testing.expectEqual(@as(f32, 1.5), dpiScale(144));
    g_scale = dpiScale(192);
    try std.testing.expectEqual(@as(u32, 640), toLogical(1280));
    try std.testing.expectEqual(@as(u32, 1), toLogical(0));
    g_scale = dpiScale(144);
    try std.testing.expectEqual(@as(u32, 800), toLogical(1200));
}

test "dropped paths queue is bounded and starts empty" {
    try std.testing.expectEqual(@as(usize, 0), g_drop_count);
    try std.testing.expect(MAX_PENDING_DROPS > 0);
}

test "IME: start / composition / commit / end drive imeState like the other hosts" {
    const host: *const Host = undefined; // imeState reads module state only
    try std.testing.expect(!host.imeState().active);

    // WM_IME_STARTCOMPOSITION through the real window procedure.
    const fake_hwnd: HANDLE = @ptrFromInt(0x1000);
    try std.testing.expectEqual(@as(LRESULT, 0), wndProc(fake_hwnd, WM_IME_STARTCOMPOSITION, 0, 0));
    try std.testing.expect(host.imeState().active);
    try std.testing.expectEqual(@as(usize, 0), host.imeState().text.len);

    // Composition "nihon" + one multi-byte char; caret after the 2nd UTF-16 unit.
    const comp = std.unicode.utf8ToUtf16LeStringLiteral("\u{65e5}\u{672c}go");
    imeSetComposition(comp, 2);
    var st = host.imeState();
    try std.testing.expect(st.active);
    try std.testing.expectEqualStrings("\u{65e5}\u{672c}go", st.text);
    try std.testing.expectEqual(@as(usize, 6), st.cursor); // 2 units -> 6 UTF-8 bytes

    // No caret reported: parked at the end.
    imeSetComposition(comp, -1);
    try std.testing.expectEqual(host.imeState().text.len, host.imeState().cursor);

    // Commit-only clears the mirror but stays active; end deactivates.
    imeClearText();
    st = host.imeState();
    try std.testing.expect(st.active);
    try std.testing.expectEqual(@as(usize, 0), st.text.len);
    try std.testing.expectEqual(@as(LRESULT, 0), wndProc(fake_hwnd, WM_IME_ENDCOMPOSITION, 0, 0));
    try std.testing.expect(!host.imeState().active);
}

test "uia patterns: Invoke / Toggle / SetValue queue actions that pollA11yActions delivers" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    if (!g_a11y_lock_initialized) {
        InitializeCriticalSection(&g_a11y_lock);
        g_a11y_lock_initialized = true;
    }
    initNodeProviderPool();
    const nodes = [_]A11yNode{
        .{ .role = .button, .cmd_index = 3, .bounds = .{}, .label = "Save" },
        .{ .role = .checkbox, .cmd_index = 5, .bounds = .{}, .label = "agree", .state = 1 },
        .{ .role = .text_input, .cmd_index = 8, .bounds = .{}, .label = "name", .value = "bob" },
        .{ .role = .button, .cmd_index = 9, .bounds = .{}, .label = "Off", .disabled = true },
        .{ .role = .text, .cmd_index = 10, .bounds = .{}, .label = "plain" },
    };
    var host: Host = undefined;
    host.publishA11yTree(&nodes);

    // GetPatternProvider is role-gated.
    var p: ?*anyopaque = null;
    const s0: *SimpleThis = @ptrCast(&g_node_providers[0].vtbl_simple);
    try std.testing.expectEqual(S_OK, g_node_provider_vtbl_simple.GetPatternProvider(s0, UIA_InvokePatternId, &p));
    try std.testing.expect(p != null);
    const inv: *InvokeThis = @ptrCast(@alignCast(p.?));
    try std.testing.expectEqual(S_OK, g_invoke_vtbl.Invoke(inv));
    p = null;
    _ = g_node_provider_vtbl_simple.GetPatternProvider(s0, UIA_TogglePatternId, &p);
    try std.testing.expect(p == null);

    const tog: *ToggleThis = @ptrCast(&g_node_providers[1].vtbl_toggle);
    var st: c_int = -1;
    try std.testing.expectEqual(S_OK, g_toggle_vtbl.get_ToggleState(tog, &st));
    try std.testing.expectEqual(ToggleState_On, st);
    try std.testing.expectEqual(S_OK, g_toggle_vtbl.Toggle(tog));

    const val: *ValueThis = @ptrCast(&g_node_providers[2].vtbl_value);
    const w = std.unicode.utf8ToUtf16LeStringLiteral("alice");
    try std.testing.expectEqual(S_OK, g_value_vtbl.SetValue(val, w));

    // Disabled elements refuse; non-patterned roles do not hand out patterns.
    const dis: *InvokeThis = @ptrCast(&g_node_providers[3].vtbl_invoke);
    try std.testing.expectEqual(UIA_E_ELEMENTNOTENABLED, g_invoke_vtbl.Invoke(dis));

    var out: [8]teak.A11yAction = undefined;
    const n = host.pollA11yActions(&out);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(teak.A11yActionKind.activate, out[0].kind);
    try std.testing.expectEqual(@as(u32, 3), out[0].cmd_index);
    try std.testing.expectEqual(@as(u32, 5), out[1].cmd_index);
    try std.testing.expectEqual(teak.A11yActionKind.set_value, out[2].kind);
    try std.testing.expectEqual(@as(u32, 8), out[2].cmd_index);
    try std.testing.expectEqualStrings("alice", out[2].text);
    try std.testing.expectEqual(@as(usize, 0), host.pollA11yActions(&out));
}
