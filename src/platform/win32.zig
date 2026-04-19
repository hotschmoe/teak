//! Win32 host backend. Implements the `platform/host.zig` contract.
//!
//! Single-window per process: state lives in module-scoped globals because
//! Win32's WNDPROC callback has no context parameter. Threading a context
//! via `GWLP_USERDATA` is possible but not needed until a real use case
//! asks for multi-window.

const std = @import("std");
const teak = @import("teak");

pub const InputState = teak.InputState;
pub const SpecialKey = teak.SpecialKey;
pub const TextMeasurer = teak.TextMeasurer;
pub const TextMetrics = teak.TextMetrics;
pub const FontSpec = teak.FontSpec;
pub const FontFamily = teak.FontFamily;

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
const WM_CHAR: UINT = 0x0102;
const WM_KEYDOWN: UINT = 0x0100;
const WM_MOUSEMOVE: UINT = 0x0200;
const WM_LBUTTONDOWN: UINT = 0x0201;
const WM_LBUTTONUP: UINT = 0x0202;
const IDC_ARROW: LPCWSTR = @ptrFromInt(32512);

const VK_BACK: WPARAM = 0x08;
const VK_TAB: WPARAM = 0x09;
const VK_RETURN: WPARAM = 0x0D;
const VK_ESCAPE: WPARAM = 0x1B;
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
extern "user32" fn PeekMessageW(*MSG, ?HANDLE, UINT, UINT, UINT) callconv(WINAPI) BOOL;
extern "user32" fn TranslateMessage(*const MSG) callconv(WINAPI) BOOL;
extern "user32" fn DispatchMessageW(*const MSG) callconv(WINAPI) LRESULT;
extern "user32" fn DefWindowProcW(HANDLE, UINT, WPARAM, LPARAM) callconv(WINAPI) LRESULT;
extern "user32" fn PostQuitMessage(c_int) callconv(WINAPI) void;
extern "user32" fn LoadCursorW(?HANDLE, LPCWSTR) callconv(WINAPI) ?HANDLE;
extern "user32" fn GetDC(?HANDLE) callconv(WINAPI) ?HDC;
extern "user32" fn ReleaseDC(?HANDLE, HDC) callconv(WINAPI) c_int;
extern "kernel32" fn GetModuleHandleW(?LPCWSTR) callconv(WINAPI) ?HANDLE;

// ── GDI types + externs (text measurement) ────────────────────────

const HDC = *anyopaque;
const HFONT = *anyopaque;

const SIZE = extern struct {
    cx: c_long,
    cy: c_long,
};

const TEXTMETRICW = extern struct {
    tmHeight: c_long,
    tmAscent: c_long,
    tmDescent: c_long,
    tmInternalLeading: c_long,
    tmExternalLeading: c_long,
    tmAveCharWidth: c_long,
    tmMaxCharWidth: c_long,
    tmWeight: c_long,
    tmOverhang: c_long,
    tmDigitizedAspectX: c_long,
    tmDigitizedAspectY: c_long,
    tmFirstChar: u16,
    tmLastChar: u16,
    tmDefaultChar: u16,
    tmBreakChar: u16,
    tmItalic: u8,
    tmUnderlined: u8,
    tmStruckOut: u8,
    tmPitchAndFamily: u8,
    tmCharSet: u8,
};

const FW_NORMAL: c_int = 400;
const DEFAULT_CHARSET: DWORD = 1;
const OUT_TT_PRECIS: DWORD = 4;
const CLIP_DEFAULT_PRECIS: DWORD = 0;
const CLEARTYPE_QUALITY: DWORD = 5;
const DEFAULT_PITCH: DWORD = 0;

extern "gdi32" fn CreateCompatibleDC(?HDC) callconv(WINAPI) ?HDC;
extern "gdi32" fn DeleteDC(HDC) callconv(WINAPI) BOOL;
extern "gdi32" fn CreateFontW(
    nHeight: c_int,
    nWidth: c_int,
    nEscapement: c_int,
    nOrientation: c_int,
    fnWeight: c_int,
    fdwItalic: DWORD,
    fdwUnderline: DWORD,
    fdwStrikeOut: DWORD,
    fdwCharSet: DWORD,
    fdwOutputPrecision: DWORD,
    fdwClipPrecision: DWORD,
    fdwQuality: DWORD,
    fdwPitchAndFamily: DWORD,
    lpszFace: LPCWSTR,
) callconv(WINAPI) ?HFONT;
extern "gdi32" fn SelectObject(HDC, HANDLE) callconv(WINAPI) ?HANDLE;
extern "gdi32" fn DeleteObject(HANDLE) callconv(WINAPI) BOOL;
extern "gdi32" fn GetTextExtentPoint32W(HDC, LPCWSTR, c_int, *SIZE) callconv(WINAPI) BOOL;
extern "gdi32" fn GetTextMetricsW(HDC, *TEXTMETRICW) callconv(WINAPI) BOOL;

// Face names for each FontFamily. Windows ships Segoe UI / Cambria /
// Cascadia Mono on every supported version; no fallback chain.
const FACE_SANS = std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI");
const FACE_SERIF = std.unicode.utf8ToUtf16LeStringLiteral("Cambria");
const FACE_MONO = std.unicode.utf8ToUtf16LeStringLiteral("Cascadia Mono");

fn fontFaceUtf16(family: FontFamily) LPCWSTR {
    return switch (family) {
        .sans => FACE_SANS,
        .serif => FACE_SERIF,
        .mono => FACE_MONO,
    };
}

const FontCacheEntry = struct {
    family: FontFamily,
    size_px: u16,
    hfont: HFONT,
    ascent: f32,
    descent: f32,
    line_height: f32,
};

// ── Module-scoped state (written by wndProc, drained by pollInputs) ──

var g_mouse_x: f32 = 0;
var g_mouse_y: f32 = 0;
var g_running: bool = true;
var g_width: u32 = 0;
var g_height: u32 = 0;
var g_resized: bool = false;

var g_mouse_down_pending: bool = false;
var g_mouse_up_pending: bool = false;

var g_chars: [64]u8 = undefined;
var g_chars_count: usize = 0;

var g_keys: [32]SpecialKey = undefined;
var g_keys_count: usize = 0;

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

fn pushChar(ch: u8) void {
    if (g_chars_count < g_chars.len) {
        g_chars[g_chars_count] = ch;
        g_chars_count += 1;
    }
}

fn pushKey(k: SpecialKey) void {
    if (g_keys_count < g_keys.len) {
        g_keys[g_keys_count] = k;
        g_keys_count += 1;
    }
}

fn wndProc(hwnd: HANDLE, msg: UINT, wp: WPARAM, lp: LPARAM) callconv(WINAPI) LRESULT {
    switch (msg) {
        WM_DESTROY => {
            g_running = false;
            PostQuitMessage(0);
            return 0;
        },
        WM_SIZE => {
            const w: u32 = loword(lp);
            const h: u32 = hiword(lp);
            if (w > 0 and h > 0) {
                g_width = w;
                g_height = h;
                g_resized = true;
            }
            return 0;
        },
        WM_MOUSEMOVE => {
            g_mouse_x = @floatFromInt(lowordSigned(lp));
            g_mouse_y = @floatFromInt(hiwordSigned(lp));
            return 0;
        },
        WM_LBUTTONDOWN => {
            g_mouse_x = @floatFromInt(lowordSigned(lp));
            g_mouse_y = @floatFromInt(hiwordSigned(lp));
            g_mouse_down_pending = true;
            return 0;
        },
        WM_LBUTTONUP => {
            g_mouse_x = @floatFromInt(lowordSigned(lp));
            g_mouse_y = @floatFromInt(hiwordSigned(lp));
            g_mouse_up_pending = true;
            return 0;
        },
        WM_CHAR => {
            // 0x08 (backspace) and other control chars arrive here too —
            // ignore them; special keys route through WM_KEYDOWN.
            if (wp >= 0x20 and wp < 0x7F) {
                pushChar(@intCast(wp));
            }
            return 0;
        },
        WM_KEYDOWN => {
            switch (wp) {
                VK_BACK => pushKey(.backspace),
                VK_DELETE => pushKey(.delete),
                VK_LEFT => pushKey(.left),
                VK_RIGHT => pushKey(.right),
                VK_UP => pushKey(.up),
                VK_DOWN => pushKey(.down),
                VK_HOME => pushKey(.home),
                VK_END => pushKey(.end),
                VK_RETURN => pushKey(.enter),
                VK_TAB => pushKey(.tab),
                VK_ESCAPE => pushKey(.escape),
                else => {},
            }
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wp, lp),
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
    /// Memory DC reused for every measurement. `GetTextExtentPoint32W`
    /// needs a DC, but we never draw to this one — rasterization lives
    /// in the GPU layer (`src/gpu/native.zig`) with its own DC.
    measure_dc: HDC,
    font_cache: [8]FontCacheEntry,
    font_cache_len: usize,

    pub fn init(title: []const u8, width: u32, height: u32) !Host {
        g_running = true;
        g_width = width;
        g_height = height;
        g_resized = true; // force initial surface configure on first pollInputs

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

        const hwnd = CreateWindowExW(
            0,
            class_name,
            @ptrCast(&title_buf),
            WS_OVERLAPPEDWINDOW,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            @intCast(width),
            @intCast(height),
            null,
            null,
            hinstance,
            null,
        ) orelse return error.CreateWindowFailed;
        _ = ShowWindow(hwnd, SW_SHOW);

        const screen_dc = GetDC(null) orelse return error.GetDcFailed;
        defer _ = ReleaseDC(null, screen_dc);
        const measure_dc = CreateCompatibleDC(screen_dc) orelse return error.CreateDcFailed;

        return .{
            .hinstance = hinstance,
            .hwnd = hwnd,
            .measure_dc = measure_dc,
            .font_cache = undefined,
            .font_cache_len = 0,
        };
    }

    pub fn deinit(self: *Host) void {
        for (self.font_cache[0..self.font_cache_len]) |entry| {
            _ = DeleteObject(entry.hfont);
        }
        _ = DeleteDC(self.measure_dc);
        // Win32 cleans up the window on process exit; explicit teardown
        // would require tracking class registration state.
    }

    pub fn pollInputs(_: *Host) InputState {
        // Queues reset before pumping; edge flags latched after. Edges
        // must survive across the pump so Host.init's initial resized=true
        // flag (set before the first pump) is returned on frame 1.
        g_chars_count = 0;
        g_keys_count = 0;

        var msg: MSG = undefined;
        while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE) != 0) {
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }

        const mouse_down = g_mouse_down_pending;
        const mouse_up = g_mouse_up_pending;
        const resized = g_resized;
        g_mouse_down_pending = false;
        g_mouse_up_pending = false;
        g_resized = false;

        return .{
            .mouse_x = g_mouse_x,
            .mouse_y = g_mouse_y,
            .mouse_down = mouse_down,
            .mouse_up = mouse_up,
            .chars = g_chars[0..g_chars_count],
            .keys = g_keys[0..g_keys_count],
            .resized = resized,
            .width = g_width,
            .height = g_height,
        };
    }

    pub fn shouldClose(_: *const Host) bool {
        return !g_running;
    }

    pub fn nativeHandle(self: *const Host) NativeHandle {
        return .{ .hinstance = self.hinstance, .hwnd = self.hwnd };
    }

    /// Real GDI measurer. `GetTextExtentPoint32W` on the cached memory
    /// DC with an HFONT selected in. Caches HFONTs by (family, size_px)
    /// in an 8-entry fixed array — every in-tree example uses one or
    /// two FontSpec values.
    pub fn textMeasurer(self: *Host) TextMeasurer {
        return .{ .ctx = @ptrCast(self), .measure_fn = gdiMeasure };
    }

    fn gdiMeasure(ctx: *anyopaque, text_bytes: []const u8, font: FontSpec) TextMetrics {
        const self: *Host = @ptrCast(@alignCast(ctx));
        const entry = getOrCreateFont(self, font) orelse return fallbackMetrics();

        // UTF-8 → UTF-16 on the stack. 1024 code units covers any label
        // we'll ever measure; longer inputs clamp to len 0.
        var utf16_buf: [1024]u16 = undefined;
        const len = std.unicode.utf8ToUtf16Le(&utf16_buf, text_bytes) catch 0;

        _ = SelectObject(self.measure_dc, entry.hfont);

        var size: SIZE = undefined;
        const ok = GetTextExtentPoint32W(
            self.measure_dc,
            @ptrCast(&utf16_buf),
            @intCast(len),
            &size,
        );
        const width: f32 = if (ok != 0) @floatFromInt(size.cx) else 0;

        return .{
            .width = width,
            .height = entry.line_height,
            .ascent = entry.ascent,
            .descent = entry.descent,
        };
    }

    fn getOrCreateFont(self: *Host, font: FontSpec) ?*const FontCacheEntry {
        const size_px: u16 = @intFromFloat(font.size_px);
        for (self.font_cache[0..self.font_cache_len]) |*e| {
            if (e.family == font.family and e.size_px == size_px) return e;
        }
        if (self.font_cache_len >= self.font_cache.len) return null;

        // Negative lfHeight selects font by character (cell-less) height
        // in logical units — closest to "pixel size" for a 100% DPI DC.
        const hfont = CreateFontW(
            -@as(c_int, @intCast(size_px)),
            0,
            0,
            0,
            FW_NORMAL,
            0,
            0,
            0,
            DEFAULT_CHARSET,
            OUT_TT_PRECIS,
            CLIP_DEFAULT_PRECIS,
            CLEARTYPE_QUALITY,
            DEFAULT_PITCH,
            fontFaceUtf16(font.family),
        ) orelse return null;

        _ = SelectObject(self.measure_dc, hfont);
        var tm: TEXTMETRICW = undefined;
        _ = GetTextMetricsW(self.measure_dc, &tm);

        self.font_cache[self.font_cache_len] = .{
            .family = font.family,
            .size_px = size_px,
            .hfont = hfont,
            .ascent = @floatFromInt(tm.tmAscent),
            .descent = @floatFromInt(tm.tmDescent),
            .line_height = @floatFromInt(tm.tmHeight),
        };
        self.font_cache_len += 1;
        return &self.font_cache[self.font_cache_len - 1];
    }

    /// Returned when font creation or conversion fails. Mirrors the
    /// WS1 stub numbers so a broken font path doesn't explode layouts.
    fn fallbackMetrics() TextMetrics {
        return .{ .width = 0, .height = 20, .ascent = 15, .descent = 5 };
    }
};

comptime {
    teak.validateHost(Host);
}
