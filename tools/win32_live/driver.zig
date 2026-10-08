//! Live Win32 test driver (CI job `win32-live`): launches a teak example's
//! native UI exe as a real window, drives it with real input (`SendInput`,
//! `DoDragDrop`, the clipboard), reads the GUI back as data through the
//! `TEAK_SNAPSHOT` sink, and captures the window to PNGs.
//!
//!   driver.exe <ui-exe> <out-dir> <chrome|effects>
//!
//! Exit code 0 only if every check passed; PNGs and the log are written either
//! way so a failing run can be inspected. Windows only.

const std = @import("std");
const teak = @import("teak");

const WINAPI = std.builtin.CallingConvention.winapi;
const HANDLE = *anyopaque;
const BOOL = c_int;
const DWORD = c_ulong;
const UINT = c_uint;
const HRESULT = c_long;
const LPCWSTR = [*:0]const u16;

const POINT = extern struct { x: c_long, y: c_long };
const RECT = extern struct { left: c_long, top: c_long, right: c_long, bottom: c_long };

const STARTUPINFOW = extern struct {
    cb: DWORD = @sizeOf(STARTUPINFOW),
    lpReserved: ?LPCWSTR = null,
    lpDesktop: ?LPCWSTR = null,
    lpTitle: ?LPCWSTR = null,
    dwX: DWORD = 0,
    dwY: DWORD = 0,
    dwXSize: DWORD = 0,
    dwYSize: DWORD = 0,
    dwXCountChars: DWORD = 0,
    dwYCountChars: DWORD = 0,
    dwFillAttribute: DWORD = 0,
    dwFlags: DWORD = 0,
    wShowWindow: u16 = 0,
    cbReserved2: u16 = 0,
    lpReserved2: ?*anyopaque = null,
    hStdInput: ?HANDLE = null,
    hStdOutput: ?HANDLE = null,
    hStdError: ?HANDLE = null,
};
const PROCESS_INFORMATION = extern struct { hProcess: ?HANDLE = null, hThread: ?HANDLE = null, dwProcessId: DWORD = 0, dwThreadId: DWORD = 0 };

const MOUSEINPUT = extern struct { dx: c_long, dy: c_long, mouseData: DWORD, dwFlags: DWORD, time: DWORD, dwExtraInfo: usize };
const KEYBDINPUT = extern struct { wVk: u16, wScan: u16, dwFlags: DWORD, time: DWORD, dwExtraInfo: usize };
const INPUT = extern struct {
    type: DWORD,
    u: extern union { mi: MOUSEINPUT, ki: KEYBDINPUT },
};

const BITMAPINFOHEADER = extern struct {
    biSize: DWORD = @sizeOf(BITMAPINFOHEADER),
    biWidth: c_long,
    biHeight: c_long,
    biPlanes: u16 = 1,
    biBitCount: u16 = 32,
    biCompression: DWORD = 0,
    biSizeImage: DWORD = 0,
    biXPelsPerMeter: c_long = 0,
    biYPelsPerMeter: c_long = 0,
    biClrUsed: DWORD = 0,
    biClrImportant: DWORD = 0,
};

extern "kernel32" fn CreateProcessW(?LPCWSTR, ?[*:0]u16, ?*anyopaque, ?*anyopaque, BOOL, DWORD, ?*anyopaque, ?LPCWSTR, *STARTUPINFOW, *PROCESS_INFORMATION) callconv(WINAPI) BOOL;
extern "kernel32" fn TerminateProcess(HANDLE, UINT) callconv(WINAPI) BOOL;
extern "kernel32" fn WaitForSingleObject(HANDLE, DWORD) callconv(WINAPI) DWORD;
extern "kernel32" fn CloseHandle(HANDLE) callconv(WINAPI) BOOL;
extern "kernel32" fn Sleep(DWORD) callconv(WINAPI) void;
extern "kernel32" fn SetEnvironmentVariableW(LPCWSTR, ?LPCWSTR) callconv(WINAPI) BOOL;
extern "kernel32" fn GlobalAlloc(UINT, usize) callconv(WINAPI) ?HANDLE;
extern "kernel32" fn GlobalLock(HANDLE) callconv(WINAPI) ?*anyopaque;
extern "kernel32" fn GlobalUnlock(HANDLE) callconv(WINAPI) BOOL;
extern "kernel32" fn GlobalSize(HANDLE) callconv(WINAPI) usize;
extern "kernel32" fn GetTickCount64() callconv(WINAPI) u64;

extern "user32" fn FindWindowW(?LPCWSTR, ?LPCWSTR) callconv(WINAPI) ?HANDLE;
extern "user32" fn SetForegroundWindow(HANDLE) callconv(WINAPI) BOOL;
extern "user32" fn GetForegroundWindow() callconv(WINAPI) ?HANDLE;
extern "user32" fn ShowWindow(HANDLE, c_int) callconv(WINAPI) BOOL;
extern "user32" fn SetWindowPos(HANDLE, ?HANDLE, c_int, c_int, c_int, c_int, UINT) callconv(WINAPI) BOOL;
extern "user32" fn GetClientRect(HANDLE, *RECT) callconv(WINAPI) BOOL;
extern "user32" fn ClientToScreen(HANDLE, *POINT) callconv(WINAPI) BOOL;
extern "user32" fn SendInput(UINT, [*]const INPUT, c_int) callconv(WINAPI) UINT;
extern "user32" fn SetCursorPos(c_int, c_int) callconv(WINAPI) BOOL;
extern "user32" fn PostMessageW(HANDLE, UINT, usize, isize) callconv(WINAPI) BOOL;
extern "user32" fn GetDC(?HANDLE) callconv(WINAPI) ?HANDLE;
extern "user32" fn ReleaseDC(?HANDLE, HANDLE) callconv(WINAPI) c_int;
extern "user32" fn PrintWindow(HANDLE, HANDLE, UINT) callconv(WINAPI) BOOL;
extern "user32" fn GetDpiForWindow(HANDLE) callconv(WINAPI) UINT;
extern "user32" fn SetProcessDpiAwarenessContext(isize) callconv(WINAPI) BOOL;
extern "user32" fn OpenClipboard(?HANDLE) callconv(WINAPI) BOOL;
extern "user32" fn CloseClipboard() callconv(WINAPI) BOOL;
extern "user32" fn EmptyClipboard() callconv(WINAPI) BOOL;
extern "user32" fn GetClipboardData(UINT) callconv(WINAPI) ?HANDLE;
extern "user32" fn SetClipboardData(UINT, HANDLE) callconv(WINAPI) ?HANDLE;
extern "user32" fn IsWindow(HANDLE) callconv(WINAPI) BOOL;
extern "user32" fn GetWindowThreadProcessId(HANDLE, ?*DWORD) callconv(WINAPI) DWORD;
extern "user32" fn AttachThreadInput(DWORD, DWORD, BOOL) callconv(WINAPI) BOOL;
extern "user32" fn BringWindowToTop(HANDLE) callconv(WINAPI) BOOL;
extern "user32" fn SetActiveWindow(HANDLE) callconv(WINAPI) ?HANDLE;
extern "user32" fn SetFocus(?HANDLE) callconv(WINAPI) ?HANDLE;
extern "kernel32" fn GetCurrentThreadId() callconv(WINAPI) DWORD;

extern "gdi32" fn CreateCompatibleDC(?HANDLE) callconv(WINAPI) ?HANDLE;
extern "gdi32" fn CreateCompatibleBitmap(HANDLE, c_int, c_int) callconv(WINAPI) ?HANDLE;
extern "gdi32" fn SelectObject(HANDLE, HANDLE) callconv(WINAPI) ?HANDLE;
extern "gdi32" fn BitBlt(HANDLE, c_int, c_int, c_int, c_int, HANDLE, c_int, c_int, DWORD) callconv(WINAPI) BOOL;
extern "gdi32" fn GetDIBits(HANDLE, HANDLE, UINT, UINT, ?*anyopaque, *BITMAPINFOHEADER, UINT) callconv(WINAPI) c_int;
extern "gdi32" fn DeleteObject(HANDLE) callconv(WINAPI) BOOL;
extern "gdi32" fn DeleteDC(HANDLE) callconv(WINAPI) BOOL;

extern "ole32" fn OleInitialize(?*anyopaque) callconv(WINAPI) HRESULT;
extern "ole32" fn DoDragDrop(*DataObject, *DropSource, DWORD, *DWORD) callconv(WINAPI) HRESULT;

const CF_UNICODETEXT: UINT = 13;
const CF_HDROP: UINT = 15;
const GMEM_MOVEABLE: UINT = 2;
const SRCCOPY: DWORD = 0x00CC0020;
const CAPTUREBLT: DWORD = 0x40000000;
const WM_CLOSE: UINT = 0x0010;
const WM_IME_STARTCOMPOSITION: UINT = 0x010D;
const WM_IME_ENDCOMPOSITION: UINT = 0x010E;
const WM_CHAR: UINT = 0x0102;
const VK_CONTROL: u16 = 0x11;
const VK_BACK: u16 = 0x08;
const KEYEVENTF_KEYUP: DWORD = 2;
const KEYEVENTF_UNICODE: DWORD = 4;
const SWP_NOZORDER: UINT = 4;
const SWP_NOMOVE: UINT = 2;
const SWP_NOSIZE: UINT = 1;

var failures: u32 = 0;
var out_dir: []const u8 = ".";
var io_: std.Io = undefined;
var gpa_: std.mem.Allocator = undefined;

fn log(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[live] " ++ fmt ++ "\n", args);
}

fn check(ok: bool, comptime what: []const u8) void {
    if (ok) {
        log("PASS {s}", .{what});
    } else {
        log("FAIL {s}", .{what});
        failures += 1;
    }
}

fn w(comptime s: []const u8) LPCWSTR {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

fn sleepMs(ms: u32) void {
    Sleep(ms);
}

// ── Snapshot (the GUI as data) ─────────────────────────────────────

var snap_path: []const u8 = "";

fn readSnapshot() ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io_, snap_path, gpa_, .limited(4 * 1024 * 1024)) catch null;
}

/// Wait until the snapshot contains `needle`; returns whether it did.
fn waitSnap(needle: []const u8, timeout_ms: u32) bool {
    const deadline = GetTickCount64() + timeout_ms;
    while (GetTickCount64() < deadline) {
        if (readSnapshot()) |s| {
            defer gpa_.free(s);
            if (std.mem.indexOf(u8, s, needle) != null) return true;
        }
        sleepMs(100);
    }
    return false;
}

/// Wait until the snapshot differs from `before`.
fn waitChange(before: []const u8, timeout_ms: u32) bool {
    const deadline = GetTickCount64() + timeout_ms;
    while (GetTickCount64() < deadline) {
        if (readSnapshot()) |s| {
            defer gpa_.free(s);
            if (!std.mem.eql(u8, s, before)) return true;
        }
        sleepMs(100);
    }
    return false;
}

const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

/// The rect of the first widget line containing `kind (` and `"label"`.
fn findWidget(snap: []const u8, kind: []const u8, label: []const u8) ?Rect {
    var it = std.mem.splitScalar(u8, snap, '\n');
    var quoted_buf: [128]u8 = undefined;
    const quoted = std.fmt.bufPrint(&quoted_buf, "\"{s}\"", .{label}) catch return null;
    while (it.next()) |line| {
        const t = std.mem.trimStart(u8, line, " ");
        if (!std.mem.startsWith(u8, t, kind) or t.len <= kind.len or t[kind.len] != ' ') continue;
        if (std.mem.indexOf(u8, t, quoted) == null) continue;
        const open = std.mem.indexOfScalar(u8, t, '(') orelse continue;
        const close = std.mem.indexOfScalarPos(u8, t, open, ')') orelse continue;
        var nums: [4]f32 = undefined;
        var parts = std.mem.splitScalar(u8, t[open + 1 .. close], ',');
        var n: usize = 0;
        while (parts.next()) |p| : (n += 1) {
            if (n >= 4) break;
            nums[n] = std.fmt.parseFloat(f32, p) catch return null;
        }
        if (n != 4) continue;
        return .{ .x = nums[0], .y = nums[1], .w = nums[2], .h = nums[3] };
    }
    return null;
}

// ── Window + input ─────────────────────────────────────────────────

var hwnd: HANDLE = undefined;
/// False when the runner would not give us the foreground: input is then
/// posted to the window as messages (clicks, typing; no Ctrl chords).
var foreground = true;

fn scale() f32 {
    const dpi = GetDpiForWindow(hwnd);
    return if (dpi == 0) 1 else @as(f32, @floatFromInt(dpi)) / 96.0;
}

fn focusWindow() void {
    _ = ShowWindow(hwnd, 9); // SW_RESTORE
    // A background process may not take the foreground: a synthetic ALT tap
    // lifts that restriction.
    var alt = [_]INPUT{
        .{ .type = 1, .u = .{ .ki = .{ .wVk = 0x12, .wScan = 0, .dwFlags = 0, .time = 0, .dwExtraInfo = 0 } } },
        .{ .type = 1, .u = .{ .ki = .{ .wVk = 0x12, .wScan = 0, .dwFlags = KEYEVENTF_KEYUP, .time = 0, .dwExtraInfo = 0 } } },
    };
    _ = SendInput(2, &alt, @sizeOf(INPUT));
    // Topmost first: some runner images keep a full-screen setup page open.
    _ = SetWindowPos(hwnd, @ptrFromInt(@as(usize, @bitCast(@as(isize, -1)))), 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE);
    _ = SetForegroundWindow(hwnd);
    sleepMs(300);
    if (GetForegroundWindow() != hwnd) {
        // Share the app thread's input queue, which lets us take the foreground.
        const app_thread = GetWindowThreadProcessId(hwnd, null);
        const me = GetCurrentThreadId();
        _ = AttachThreadInput(me, app_thread, 1);
        _ = BringWindowToTop(hwnd);
        _ = SetForegroundWindow(hwnd);
        _ = SetActiveWindow(hwnd);
        _ = SetFocus(hwnd);
        sleepMs(300);
        _ = AttachThreadInput(me, app_thread, 0);
    }
    foreground = GetForegroundWindow() == hwnd;
    log("foreground is the app window: {}", .{foreground});
    if (!foreground) log("input falls back to posted window messages (no chords)", .{});
}

fn clientOrigin() POINT {
    var p: POINT = .{ .x = 0, .y = 0 };
    _ = ClientToScreen(hwnd, &p);
    return p;
}

fn mouse(flags: DWORD) void {
    const in = [_]INPUT{.{ .type = 0, .u = .{ .mi = .{ .dx = 0, .dy = 0, .mouseData = 0, .dwFlags = flags, .time = 0, .dwExtraInfo = 0 } } }};
    _ = SendInput(1, &in, @sizeOf(INPUT));
}

fn moveTo(lx: f32, ly: f32) void {
    const o = clientOrigin();
    const s = scale();
    _ = SetCursorPos(o.x + @as(c_int, @intFromFloat(lx * s)), o.y + @as(c_int, @intFromFloat(ly * s)));
    sleepMs(80);
}

fn clickAt(lx: f32, ly: f32) void {
    if (!foreground) {
        const s = scale();
        const lp: isize = (@as(isize, @intFromFloat(ly * s)) << 16) | @as(isize, @intFromFloat(lx * s));
        _ = PostMessageW(hwnd, 0x0200, 0, lp); // WM_MOUSEMOVE
        sleepMs(60);
        _ = PostMessageW(hwnd, 0x0201, 1, lp); // WM_LBUTTONDOWN
        sleepMs(60);
        _ = PostMessageW(hwnd, 0x0202, 0, lp); // WM_LBUTTONUP
        sleepMs(200);
        return;
    }
    moveTo(lx, ly);
    mouse(2); // left down
    sleepMs(60);
    mouse(4); // left up
    sleepMs(200);
}

fn clickCenter(r: Rect) void {
    clickAt(r.x + r.w / 2, r.y + r.h / 2);
}

fn key(vk: u16, up: bool) INPUT {
    return .{ .type = 1, .u = .{ .ki = .{ .wVk = vk, .wScan = 0, .dwFlags = if (up) KEYEVENTF_KEYUP else 0, .time = 0, .dwExtraInfo = 0 } } };
}

fn chord(letter: u8) void {
    if (!foreground) return log("skipping Ctrl+{c}: needs the foreground", .{letter});
    const in = [_]INPUT{ key(VK_CONTROL, false), key(letter, false), key(letter, true), key(VK_CONTROL, true) };
    _ = SendInput(4, &in, @sizeOf(INPUT));
    sleepMs(300);
}

fn typeText(text: []const u8) void {
    var utf16: [128]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&utf16, text) catch return;
    for (utf16[0..n]) |unit| {
        if (!foreground) {
            _ = PostMessageW(hwnd, WM_CHAR, unit, 0);
            sleepMs(30);
            continue;
        }
        const in = [_]INPUT{
            .{ .type = 1, .u = .{ .ki = .{ .wVk = 0, .wScan = unit, .dwFlags = KEYEVENTF_UNICODE, .time = 0, .dwExtraInfo = 0 } } },
            .{ .type = 1, .u = .{ .ki = .{ .wVk = 0, .wScan = unit, .dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP, .time = 0, .dwExtraInfo = 0 } } },
        };
        _ = SendInput(2, &in, @sizeOf(INPUT));
        sleepMs(40);
    }
    sleepMs(200);
}

// ── Clipboard ──────────────────────────────────────────────────────

fn clipboardSet(text: []const u8) bool {
    var wide: [512]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide, text) catch return false;
    const mem = GlobalAlloc(GMEM_MOVEABLE, (n + 1) * 2) orelse return false;
    const p: [*]u16 = @ptrCast(@alignCast(GlobalLock(mem) orelse return false));
    @memcpy(p[0..n], wide[0..n]);
    p[n] = 0;
    _ = GlobalUnlock(mem);
    if (OpenClipboard(null) == 0) return false;
    defer _ = CloseClipboard();
    _ = EmptyClipboard();
    return SetClipboardData(CF_UNICODETEXT, mem) != null;
}

fn clipboardGet(buf: []u8) ?[]const u8 {
    var tries: u32 = 0;
    while (OpenClipboard(null) == 0) : (tries += 1) {
        if (tries > 20) return null;
        sleepMs(50);
    }
    defer _ = CloseClipboard();
    const h = GetClipboardData(CF_UNICODETEXT) orelse return null;
    const p: [*]const u16 = @ptrCast(@alignCast(GlobalLock(h) orelse return null));
    defer _ = GlobalUnlock(h);
    var n: usize = 0;
    while (n < GlobalSize(h) / 2 and p[n] != 0) : (n += 1) {}
    const len = std.unicode.utf16LeToUtf8(buf, p[0..n]) catch return null;
    return buf[0..len];
}

// ── Capture ────────────────────────────────────────────────────────

fn capture(name: []const u8) void {
    var rc: RECT = undefined;
    _ = GetClientRect(hwnd, &rc);
    const cw = rc.right - rc.left;
    const ch = rc.bottom - rc.top;
    if (cw <= 0 or ch <= 0) return log("capture {s}: empty client rect", .{name});
    const o = clientOrigin();
    const screen = GetDC(null) orelse return;
    defer _ = ReleaseDC(null, screen);
    const mem = CreateCompatibleDC(screen) orelse return;
    defer _ = DeleteDC(mem);
    const bmp = CreateCompatibleBitmap(screen, cw, ch) orelse return;
    defer _ = DeleteObject(bmp);
    const old = SelectObject(mem, bmp);
    defer if (old) |ob| {
        _ = SelectObject(mem, ob);
    };

    var hdr = BITMAPINFOHEADER{ .biWidth = cw, .biHeight = -ch };
    const px = gpa_.alloc(u8, @as(usize, @intCast(cw)) * @as(usize, @intCast(ch)) * 4) catch return;
    defer gpa_.free(px);

    // Screen grab first (what a user sees); PrintWindow if it came out black.
    _ = BitBlt(mem, 0, 0, cw, ch, screen, o.x, o.y, SRCCOPY | CAPTUREBLT);
    _ = GetDIBits(mem, bmp, 0, @intCast(ch), px.ptr, &hdr, 0);
    var method: []const u8 = "BitBlt";
    // Without the foreground another window may cover ours on screen:
    // ask the compositor for the window's own pixels instead.
    if (allBlack(px) or !foreground) {
        _ = PrintWindow(hwnd, mem, 2); // PW_RENDERFULLCONTENT
        _ = GetDIBits(mem, bmp, 0, @intCast(ch), px.ptr, &hdr, 0);
        method = "PrintWindow";
    }
    var i: usize = 0;
    while (i < px.len) : (i += 4) {
        std.mem.swap(u8, &px[i], &px[i + 2]); // BGRA -> RGBA
        px[i + 3] = 255;
    }
    const png = teak.headless.encodePng(gpa_, px, @intCast(cw), @intCast(ch)) catch return;
    defer gpa_.free(png);
    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.png", .{ out_dir, name }) catch return;
    std.Io.Dir.cwd().writeFile(io_, .{ .sub_path = path, .data = png }) catch |e| return log("write {s}: {s}", .{ path, @errorName(e) });
    log("captured {s} ({d}x{d}, {s}, black={})", .{ path, cw, ch, method, allBlack(px) });
}

fn allBlack(px: []const u8) bool {
    var i: usize = 0;
    while (i < px.len) : (i += 4) {
        if (px[i] != 0 or px[i + 1] != 0 or px[i + 2] != 0) return false;
    }
    return true;
}

// ── Drag and drop: an IDataObject offering one CF_HDROP file ───────

const DataObject = extern struct {
    vtbl: *const extern struct {
        QueryInterface: *const fn (*DataObject, *const anyopaque, *?*anyopaque) callconv(WINAPI) HRESULT,
        AddRef: *const fn (*DataObject) callconv(WINAPI) c_ulong,
        Release: *const fn (*DataObject) callconv(WINAPI) c_ulong,
        GetData: *const fn (*DataObject, *const FORMATETC, *STGMEDIUM) callconv(WINAPI) HRESULT,
        GetDataHere: *const fn (*DataObject, *const FORMATETC, *STGMEDIUM) callconv(WINAPI) HRESULT,
        QueryGetData: *const fn (*DataObject, *const FORMATETC) callconv(WINAPI) HRESULT,
        GetCanonicalFormatEtc: *const fn (*DataObject, *const FORMATETC, *FORMATETC) callconv(WINAPI) HRESULT,
        SetData: *const fn (*DataObject, *const FORMATETC, *STGMEDIUM, BOOL) callconv(WINAPI) HRESULT,
        EnumFormatEtc: *const fn (*DataObject, DWORD, *?*anyopaque) callconv(WINAPI) HRESULT,
        DAdvise: *const fn (*DataObject, *const FORMATETC, DWORD, ?*anyopaque, *DWORD) callconv(WINAPI) HRESULT,
        DUnadvise: *const fn (*DataObject, DWORD) callconv(WINAPI) HRESULT,
        EnumDAdvise: *const fn (*DataObject, *?*anyopaque) callconv(WINAPI) HRESULT,
    },
};
const FORMATETC = extern struct { cfFormat: u16, ptd: ?*anyopaque, dwAspect: DWORD, lindex: c_long, tymed: DWORD };
const STGMEDIUM = extern struct { tymed: DWORD, hGlobal: ?HANDLE, pUnk: ?*anyopaque };

const DropSource = extern struct {
    vtbl: *const extern struct {
        QueryInterface: *const fn (*DropSource, *const anyopaque, *?*anyopaque) callconv(WINAPI) HRESULT,
        AddRef: *const fn (*DropSource) callconv(WINAPI) c_ulong,
        Release: *const fn (*DropSource) callconv(WINAPI) c_ulong,
        QueryContinueDrag: *const fn (*DropSource, BOOL, DWORD) callconv(WINAPI) HRESULT,
        GiveFeedback: *const fn (*DropSource, DWORD) callconv(WINAPI) HRESULT,
    },
};

const E_NOTIMPL: HRESULT = @bitCast(@as(u32, 0x80004001));
const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x80004002));
const DV_E_FORMATETC: HRESULT = @bitCast(@as(u32, 0x80040064));
const DRAGDROP_S_DROP: HRESULT = 0x00040100;
const DRAGDROP_S_USEDEFAULTCURSORS: HRESULT = 0x00040102;

var drop_path_w: [300:0]u16 = undefined;
var drop_path_len: usize = 0;
var drag_polls: u32 = 0;

fn hdropBlock() ?HANDLE {
    const header = 20; // sizeof(DROPFILES)
    const bytes = header + (drop_path_len + 2) * 2;
    const mem = GlobalAlloc(GMEM_MOVEABLE | 0x40, bytes) orelse return null; // GHND: zeroed
    const p: [*]u8 = @ptrCast(GlobalLock(mem) orelse return null);
    std.mem.writeInt(u32, p[0..4], header, .little); // pFiles
    std.mem.writeInt(u32, p[16..20], 1, .little); // fWide
    const dst: [*]align(1) u16 = @ptrCast(p + header);
    for (0..drop_path_len) |i| dst[i] = drop_path_w[i];
    _ = GlobalUnlock(mem);
    return mem;
}

const GUID = extern struct { d1: u32, d2: u16, d3: u16, d4: [8]u8 };
fn guid(d1: u32) GUID {
    return .{ .d1 = d1, .d2 = 0, .d3 = 0, .d4 = .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 } };
}
fn isIid(iid: *const anyopaque, ids: []const u32) bool {
    const g: *const GUID = @ptrCast(@alignCast(iid));
    for (ids) |id| {
        const want = guid(id);
        if (g.d1 == want.d1 and g.d2 == 0 and g.d3 == 0 and std.mem.eql(u8, &g.d4, &want.d4)) return true;
    }
    return false;
}
// COM probes for IMarshal and friends while marshalling a drag source across
// processes: answering "yes" to those corrupts the drag, so only the real
// interfaces (IUnknown 0, IDataObject 0x10e, IDropSource 0x121) are offered.
fn doQI(this: *DataObject, iid: *const anyopaque, ppv: *?*anyopaque) callconv(WINAPI) HRESULT {
    if (!isIid(iid, &.{ 0x0, 0x10e })) {
        ppv.* = null;
        return E_NOINTERFACE;
    }
    ppv.* = @ptrCast(this);
    return 0;
}
fn doAddRef(_: *DataObject) callconv(WINAPI) c_ulong {
    return 1;
}
fn doGetData(_: *DataObject, f: *const FORMATETC, m: *STGMEDIUM) callconv(WINAPI) HRESULT {
    if (f.cfFormat != CF_HDROP) return DV_E_FORMATETC;
    m.* = .{ .tymed = 1, .hGlobal = hdropBlock(), .pUnk = null };
    return if (m.hGlobal == null) E_NOTIMPL else 0;
}
fn doGetDataHere(_: *DataObject, _: *const FORMATETC, _: *STGMEDIUM) callconv(WINAPI) HRESULT {
    return E_NOTIMPL;
}
fn doQueryGetData(_: *DataObject, f: *const FORMATETC) callconv(WINAPI) HRESULT {
    return if (f.cfFormat == CF_HDROP) 0 else DV_E_FORMATETC;
}
fn doCanon(_: *DataObject, _: *const FORMATETC, _: *FORMATETC) callconv(WINAPI) HRESULT {
    return E_NOTIMPL;
}
fn doSetData(_: *DataObject, _: *const FORMATETC, _: *STGMEDIUM, _: BOOL) callconv(WINAPI) HRESULT {
    return E_NOTIMPL;
}
fn doEnum(_: *DataObject, _: DWORD, out: *?*anyopaque) callconv(WINAPI) HRESULT {
    out.* = null;
    return E_NOTIMPL;
}
fn doDAdvise(_: *DataObject, _: *const FORMATETC, _: DWORD, _: ?*anyopaque, _: *DWORD) callconv(WINAPI) HRESULT {
    return E_NOTIMPL;
}
fn doDUnadvise(_: *DataObject, _: DWORD) callconv(WINAPI) HRESULT {
    return E_NOTIMPL;
}
fn doEnumDAdvise(_: *DataObject, out: *?*anyopaque) callconv(WINAPI) HRESULT {
    out.* = null;
    return E_NOTIMPL;
}
const data_vtbl: @typeInfo(@FieldType(DataObject, "vtbl")).pointer.child = .{
    .QueryInterface = doQI,
    .AddRef = doAddRef,
    .Release = doAddRef,
    .GetData = doGetData,
    .GetDataHere = doGetDataHere,
    .QueryGetData = doQueryGetData,
    .GetCanonicalFormatEtc = doCanon,
    .SetData = doSetData,
    .EnumFormatEtc = doEnum,
    .DAdvise = doDAdvise,
    .DUnadvise = doDUnadvise,
    .EnumDAdvise = doEnumDAdvise,
};
var data_object: DataObject = .{ .vtbl = &data_vtbl };

fn dsQI(this: *DropSource, iid: *const anyopaque, ppv: *?*anyopaque) callconv(WINAPI) HRESULT {
    if (!isIid(iid, &.{ 0x0, 0x121 })) {
        ppv.* = null;
        return E_NOINTERFACE;
    }
    ppv.* = @ptrCast(this);
    return 0;
}
fn dsAddRef(_: *DropSource) callconv(WINAPI) c_ulong {
    return 1;
}
fn dsQuery(_: *DropSource, escape: BOOL, _: DWORD) callconv(WINAPI) HRESULT {
    if (escape != 0) return 0x00040101; // DRAGDROP_S_CANCEL
    drag_polls += 1;
    // Let OLE hover over the target for a few polls, then drop.
    return if (drag_polls > 12) DRAGDROP_S_DROP else 0;
}
fn dsFeedback(_: *DropSource, _: DWORD) callconv(WINAPI) HRESULT {
    return DRAGDROP_S_USEDEFAULTCURSORS;
}
const source_vtbl: @typeInfo(@FieldType(DropSource, "vtbl")).pointer.child = .{
    .QueryInterface = dsQI,
    .AddRef = dsAddRef,
    .Release = dsAddRef,
    .QueryContinueDrag = dsQuery,
    .GiveFeedback = dsFeedback,
};
var drop_source: DropSource = .{ .vtbl = &source_vtbl };

/// Drag `path` over the window and drop it through OLE, as Explorer would.
fn dragFile(path: []const u8, over_lx: f32, over_ly: f32) bool {
    drop_path_len = std.unicode.utf8ToUtf16Le(drop_path_w[0..299], path) catch return false;
    drop_path_w[drop_path_len] = 0;
    drag_polls = 0;
    moveTo(over_lx, over_ly);
    mouse(2); // hold the left button like a real drag
    var effect: DWORD = 0;
    const hr = DoDragDrop(&data_object, &drop_source, 1, &effect);
    mouse(4);
    log("DoDragDrop hr=0x{x} effect={d}", .{ @as(u32, @bitCast(hr)), effect });
    sleepMs(300);
    return effect == 1;
}

// ── Process ────────────────────────────────────────────────────────

fn launch(exe: []const u8) ?HANDLE {
    var cmd: [1024:0]u16 = undefined;
    var tmp: [1024]u8 = undefined;
    const quoted = std.fmt.bufPrint(&tmp, "\"{s}\"", .{exe}) catch return null;
    const n = std.unicode.utf8ToUtf16Le(cmd[0..1023], quoted) catch return null;
    cmd[n] = 0;
    var si = STARTUPINFOW{};
    var pi = PROCESS_INFORMATION{};
    if (CreateProcessW(null, &cmd, null, null, 0, 0, null, null, &si, &pi) == 0) return null;
    if (pi.hThread) |t| _ = CloseHandle(t);
    return pi.hProcess;
}

fn waitWindow(timeout_ms: u32) bool {
    const deadline = GetTickCount64() + timeout_ms;
    while (GetTickCount64() < deadline) {
        if (FindWindowW(w("TeakWindow"), null)) |h| {
            hwnd = h;
            return true;
        }
        sleepMs(200);
    }
    return false;
}

// ── Scenarios ──────────────────────────────────────────────────────

fn windowSize(snap: []const u8) ?[2]u32 {
    const i = std.mem.indexOf(u8, snap, "window=") orelse return null;
    const rest = snap[i + 7 ..];
    const x = std.mem.indexOfScalar(u8, rest, 'x') orelse return null;
    const end = std.mem.indexOfAny(u8, rest, " \n") orelse rest.len;
    return .{
        std.fmt.parseInt(u32, rest[0..x], 10) catch return null,
        std.fmt.parseInt(u32, rest[x + 1 .. end], 10) catch return null,
    };
}

fn resizeCheck(tag: []const u8) void {
    const before = readSnapshot() orelse return;
    defer gpa_.free(before);
    const s0 = windowSize(before) orelse return check(false, "snapshot has window=WxH");
    _ = SetWindowPos(hwnd, null, 0, 0, 900, 620, SWP_NOZORDER | SWP_NOMOVE);
    check(waitChange(before, 8000), "resizing the window re-lays out the UI");
    sleepMs(500);
    if (readSnapshot()) |after| {
        defer gpa_.free(after);
        const s1 = windowSize(after) orelse .{ 0, 0 };
        log("{s}: logical window {d}x{d} -> {d}x{d} (scale {d:.2})", .{ tag, s0[0], s0[1], s1[0], s1[1], scale() });
        check(s1[0] != s0[0] or s1[1] != s0[1], "snapshot window size changed");
    }
}

fn chromeScenario() void {
    focusWindow();
    const snap0 = readSnapshot() orelse return check(false, "chrome: snapshot exists");
    defer gpa_.free(snap0);
    capture("chrome-1-start");

    // Click a button: "< PREV" selects the previous part.
    if (findWidget(snap0, "button", "< PREV")) |r| {
        clickCenter(r);
        check(waitChange(snap0, 5000), "clicking '< PREV' changes the GUI");
    } else check(false, "found the '< PREV' button in the snapshot");

    // Type into the NAME field: click it, then type.
    const snap1 = readSnapshot() orelse return;
    defer gpa_.free(snap1);
    if (std.mem.indexOf(u8, snap1, "text_input")) |_| {
        var it = std.mem.splitScalar(u8, snap1, '\n');
        while (it.next()) |line| {
            const t = std.mem.trimStart(u8, line, " ");
            if (!std.mem.startsWith(u8, t, "text_input (")) continue;
            const open = std.mem.indexOfScalar(u8, t, '(').?;
            const close = std.mem.indexOfScalarPos(u8, t, open, ')').?;
            var nums: [4]f32 = undefined;
            var parts = std.mem.splitScalar(u8, t[open + 1 .. close], ',');
            var n: usize = 0;
            while (parts.next()) |p| : (n += 1) {
                if (n < 4) nums[n] = std.fmt.parseFloat(f32, p) catch 0;
            }
            clickAt(nums[0] + nums[2] / 2, nums[1] + nums[3] / 2);
            break;
        }
        typeText("-LIVE");
        check(waitSnap("-LIVE", 5000), "typed text reaches the focused text field");
    }
    // Synthetic IME messages must not disturb the app.
    _ = PostMessageW(hwnd, WM_IME_STARTCOMPOSITION, 0, 0);
    _ = PostMessageW(hwnd, WM_IME_ENDCOMPOSITION, 0, 0);
    sleepMs(300);
    check(IsWindow(hwnd) != 0, "synthetic IME start/end composition keeps the app alive");
    capture("chrome-2-typed");

    resizeCheck("chrome");
    capture("chrome-3-resized");
}

fn effectsScenario() void {
    focusWindow();
    const snap0 = readSnapshot() orelse return check(false, "effects: snapshot exists");
    defer gpa_.free(snap0);
    capture("effects-1-start");

    // Clock effect (OS clock + UTC offset through the shared service).
    if (findWidget(snap0, "button", "Clock")) |r| {
        clickCenter(r);
        check(waitSnap("UTC, offset", 6000), "Clock effect answers");
        if (readSnapshot()) |s| {
            defer gpa_.free(s);
            check(std.mem.indexOf(u8, s, "1970-01-01") == null, "the clock is the real wall clock, not the unsupported placeholder");
        }
    } else check(false, "found the Clock button");

    // Storage round trip under %APPDATA%\teak\<app>.
    if (readSnapshot()) |s| {
        defer gpa_.free(s);
        if (findWidget(s, "button", "Storage save")) |r| clickCenter(r);
    }
    sleepMs(500);
    if (readSnapshot()) |s| {
        defer gpa_.free(s);
        if (findWidget(s, "button", "Storage load")) |r| clickCenter(r);
    }
    // "saved #1" shows in the save row and, once loaded from disk, again in the load row.
    sleepMs(800);
    if (readSnapshot()) |s| {
        defer gpa_.free(s);
        check(std.mem.count(u8, s, "saved #1") >= 2, "storage save then load round-trips through %APPDATA%");
    } else check(false, "snapshot readable after storage load");

    // Clipboard write effect -> the real clipboard.
    _ = clipboardSet("before");
    if (readSnapshot()) |s| {
        defer gpa_.free(s);
        if (findWidget(s, "button", "Clipboard write")) |r| clickCenter(r);
    }
    sleepMs(600);
    var buf: [256]u8 = undefined;
    check(if (clipboardGet(&buf)) |t| std.mem.eql(u8, t, "teak effects clipboard test") else false, "write_clipboard effect reaches the Windows clipboard");

    if (foreground) {
        // Ctrl+V reads the Windows clipboard through Clipboard.read.
        _ = clipboardSet("hello from the driver");
        chord('V');
        check(waitSnap("Ctrl+V via Clipboard.read: hello from the driver", 5000), "Ctrl+V pastes the clipboard text");
        // Ctrl+C writes the clipboard.
        chord('C');
        sleepMs(300);
        check(if (clipboardGet(&buf)) |t| std.mem.eql(u8, t, "teak effects Ctrl+C") else false, "Ctrl+C writes the Windows clipboard");
    }

    // Drag-drop a file through the OLE IDropTarget.
    var drop_buf: [512]u8 = undefined;
    const drop_file = std.fmt.bufPrint(&drop_buf, "{s}\\dropped.txt", .{out_dir}) catch return;
    std.Io.Dir.cwd().writeFile(io_, .{ .sub_path = drop_file, .data = "dropped by the live driver" }) catch {};
    const ok = dragFile(drop_file, 300, 300);
    check(ok, "DoDragDrop reports a copy");
    check(waitSnap("dropped.txt", 6000), "the dropped file arrives as a `dropped` effect result");
    capture("effects-2-dropped");

    resizeCheck("effects");
    capture("effects-3-resized");
}

pub fn main(init: std.process.Init) !void {
    io_ = init.io;
    gpa_ = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 4) {
        log("usage: driver <ui-exe> <out-dir> <chrome|effects>", .{});
        std.process.exit(2);
    }
    out_dir = args[2];
    try std.Io.Dir.cwd().createDirPath(io_, out_dir);
    _ = SetProcessDpiAwarenessContext(-4);
    log("OleInitialize hr=0x{x}", .{@as(u32, @bitCast(@as(i32, @intCast(OleInitialize(null)))))});

    var snap_buf: [600]u8 = undefined;
    snap_path = try std.fmt.bufPrint(&snap_buf, "{s}\\snapshot.txt", .{out_dir});
    std.Io.Dir.cwd().deleteFile(io_, snap_path) catch {};
    var snap_w: [600:0]u16 = undefined;
    const sn = try std.unicode.utf8ToUtf16Le(snap_w[0..599], snap_path);
    snap_w[sn] = 0;
    _ = SetEnvironmentVariableW(w("TEAK_SNAPSHOT"), &snap_w);
    _ = SetEnvironmentVariableW(w("TEAK_GPU_FALLBACK"), w("1"));

    const proc = launch(args[1]) orelse {
        log("could not start {s}", .{args[1]});
        std.process.exit(1);
    };
    defer {
        _ = PostMessageW(hwnd, WM_CLOSE, 0, 0);
        if (WaitForSingleObject(proc, 5000) != 0) _ = TerminateProcess(proc, 1);
        _ = CloseHandle(proc);
    }
    if (!waitWindow(60_000)) {
        log("no TeakWindow appeared", .{});
        _ = TerminateProcess(proc, 1);
        std.process.exit(1);
    }
    log("window up", .{});
    if (!waitSnap("window=", 60_000)) {
        log("the app never produced a snapshot (GPU init failed?)", .{});
        _ = TerminateProcess(proc, 1);
        std.process.exit(1);
    }
    sleepMs(1000);

    if (std.mem.eql(u8, args[3], "chrome")) chromeScenario() else effectsScenario();

    log("{d} failure(s)", .{failures});
    if (failures != 0) std.process.exit(1);
}
