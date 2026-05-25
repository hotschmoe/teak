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
const WM_CHAR: UINT = 0x0102;
const WM_KEYDOWN: UINT = 0x0100;
const WM_MOUSEMOVE: UINT = 0x0200;
const WM_LBUTTONDOWN: UINT = 0x0201;
const WM_LBUTTONUP: UINT = 0x0202;
const WM_MOUSEWHEEL: UINT = 0x020A;
const WM_MOUSEHWHEEL: UINT = 0x020E;
const WHEEL_DELTA: f32 = 120;
/// Pixels per wheel notch (standard "3 lines × 16 px") — matches the
/// DOM convention browsers use when `deltaMode == 0` (pixel deltas).
const WHEEL_PIXELS_PER_NOTCH: f32 = 48;
const IDC_ARROW: LPCWSTR = @ptrFromInt(32512);

const VK_BACK: WPARAM = 0x08;
const VK_TAB: WPARAM = 0x09;
const VK_RETURN: WPARAM = 0x0D;
const VK_ESCAPE: WPARAM = 0x1B;
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
extern "user32" fn PeekMessageW(*MSG, ?HANDLE, UINT, UINT, UINT) callconv(WINAPI) BOOL;
extern "user32" fn TranslateMessage(*const MSG) callconv(WINAPI) BOOL;
extern "user32" fn DispatchMessageW(*const MSG) callconv(WINAPI) LRESULT;
extern "user32" fn DefWindowProcW(HANDLE, UINT, WPARAM, LPARAM) callconv(WINAPI) LRESULT;
extern "user32" fn PostQuitMessage(c_int) callconv(WINAPI) void;
extern "user32" fn LoadCursorW(?HANDLE, LPCWSTR) callconv(WINAPI) ?HANDLE;
extern "user32" fn GetDC(?HANDLE) callconv(WINAPI) ?HDC;
extern "user32" fn ReleaseDC(?HANDLE, HDC) callconv(WINAPI) c_int;
extern "user32" fn GetKeyState(c_int) callconv(WINAPI) i16;
extern "user32" fn DestroyWindow(HANDLE) callconv(WINAPI) BOOL;
extern "kernel32" fn GetModuleHandleW(?LPCWSTR) callconv(WINAPI) ?HANDLE;

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
    payload: [16]u8 = [_]u8{0} ** 16,
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
            var_out.* = .{ .vt = VT_BOOL };
            const v: VARIANT_BOOL = 0;
            @memcpy(var_out.payload[0..@sizeOf(VARIANT_BOOL)], std.mem.asBytes(&v));
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
            return S_OK;
        },
        .first_child => {
            if (g_published_count == 0) {
                out.* = null;
                return S_OK;
            }
            out.* = @ptrCast(&g_node_providers[0].vtbl_fragment);
            return S_OK;
        },
        .last_child => {
            if (g_published_count == 0) {
                out.* = null;
                return S_OK;
            }
            out.* = @ptrCast(&g_node_providers[g_published_count - 1].vtbl_fragment);
            return S_OK;
        },
    }
}

fn rpfGetRuntimeId(_: *FragmentThis, out: *?*SAFEARRAY) callconv(WINAPI) HRESULT {
    // The convention for the root's runtime id is just the
    // UiaAppendRuntimeId marker followed by a 0 — the system fills in
    // the host prefix.
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
    ids[1] = 0;
    _ = SafeArrayUnaccessData(sa);
    out.* = sa;
    return S_OK;
}

fn rpfGetBoundingRectangle(_: *FragmentThis, rect: *UiaRect) callconv(WINAPI) HRESULT {
    if (g_hwnd_for_uia) |hwnd| {
        var client: RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        _ = GetClientRect(hwnd, &client);
        var origin: POINT = .{ .x = client.left, .y = client.top };
        _ = ClientToScreen(hwnd, &origin);
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
    out.* = @ptrCast(&self.vtbl_fragment);
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
    var origin: POINT = .{ .x = 0, .y = 0 };
    if (g_hwnd_for_uia) |hwnd| {
        _ = ClientToScreen(hwnd, &origin);
    }
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

fn npGetPatternProvider(_: *SimpleThis, _: c_long, out: *?*anyopaque) callconv(WINAPI) HRESULT {
    out.* = null;
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
    ids[1] = cmd_idx;
    _ = SafeArrayUnaccessData(sa);
    out.* = sa;
    return S_OK;
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

    var origin: POINT = .{ .x = 0, .y = 0 };
    if (g_hwnd_for_uia) |hwnd| {
        _ = ClientToScreen(hwnd, &origin);
    }
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
    out.* = @ptrCast(&g_root_provider.vtbl_fragment);
    return S_OK;
}

// ── Shared NodeProvider helpers ────────────────────────────────────

fn nodeQueryInterface(self: *NodeProvider, iid: *const GUID, ppv: *?*anyopaque) HRESULT {
    if (guidEql(iid, &IID_IUnknown) or guidEql(iid, &IID_IRawElementProviderSimple)) {
        ppv.* = @ptrCast(&self.vtbl_simple);
        return S_OK;
    }
    if (guidEql(iid, &IID_IRawElementProviderFragment)) {
        ppv.* = @ptrCast(&self.vtbl_fragment);
        return S_OK;
    }
    ppv.* = null;
    return E_NOINTERFACE;
}

/// Map an A11y role to the matching UIA control type id.
fn controlTypeForRole(role: A11yRole) c_long {
    return switch (role) {
        .group => UIA_GroupControlTypeId,
        .scroll => UIA_PaneControlTypeId,
        .text => UIA_TextControlTypeId,
        .rich_text => UIA_TextControlTypeId,
        .button => UIA_ButtonControlTypeId,
        .text_input => UIA_EditControlTypeId,
        .checkbox => UIA_CheckBoxControlTypeId,
        .radio => UIA_RadioButtonControlTypeId,
        .slider => UIA_SliderControlTypeId,
        .divider => UIA_SeparatorControlTypeId,
        .image => UIA_ImageControlTypeId,
        .overlay => UIA_PaneControlTypeId,
    };
}

fn isFocusableRole(role: A11yRole) bool {
    return switch (role) {
        .button, .text_input, .checkbox, .radio, .slider => true,
        else => false,
    };
}

/// VARIANT_TRUE / VARIANT_FALSE are the Windows BOOL conventions for
/// the VT_BOOL variant payload. Don't confuse with c_int 0/1.
const VARIANT_TRUE: VARIANT_BOOL = -1;
const VARIANT_FALSE: VARIANT_BOOL = 0;

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
            var_out.* = .{ .vt = VT_BOOL };
            const v: VARIANT_BOOL = if (isFocusableRole(node.role)) VARIANT_TRUE else VARIANT_FALSE;
            @memcpy(var_out.payload[0..@sizeOf(VARIANT_BOOL)], std.mem.asBytes(&v));
            return S_OK;
        },
        UIA_HasKeyboardFocusPropertyId => {
            var_out.* = .{ .vt = VT_BOOL };
            const v: VARIANT_BOOL = if (node.focused) VARIANT_TRUE else VARIANT_FALSE;
            @memcpy(var_out.payload[0..@sizeOf(VARIANT_BOOL)], std.mem.asBytes(&v));
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
var g_window_title_w: [256]u16 = [_]u16{0} ** 256;

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
// silently (debug log). 256 nodes covers any realistic single-window
// app — large lists should be virtualized (cmd `push_virtual_list`)
// which collapses to one a11y node regardless of row count.
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

// Wheel accumulators — pixels of intended scroll since the last
// pollInputs drain. Sign convention matches the InputState doc:
// positive wheel_dy = scroll down. Win32's WM_MOUSEWHEEL reports the
// opposite (positive = away from user = scroll up) so we negate. The
// horizontal axis already matches (positive = scroll right).
var g_wheel_dx: f32 = 0;
var g_wheel_dy: f32 = 0;

var g_chars: [64]u8 = undefined;
var g_chars_count: usize = 0;

var g_keys: [32]SpecialKey = undefined;
var g_keys_count: usize = 0;

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
    mouse_x: f32,
    mouse_y: f32,
    mouse_down_pending: bool,
    mouse_up_pending: bool,
    wheel_dx: f32,
    wheel_dy: f32,
    chars: [64]u8,
    chars_count: usize,
    keys: [32]SpecialKey,
    keys_count: usize,
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

fn secondaryPushChar(sw: *SecondaryWindow, ch: u8) void {
    if (sw.chars_count < sw.chars.len) {
        sw.chars[sw.chars_count] = ch;
        sw.chars_count += 1;
    }
}

fn secondaryPushKey(sw: *SecondaryWindow, k: SpecialKey) void {
    if (sw.keys_count < sw.keys.len) {
        sw.keys[sw.keys_count] = k;
        sw.keys_count += 1;
    }
}

fn secondaryWndProc(hwnd: HANDLE, msg: UINT, wp: WPARAM, lp: LPARAM) callconv(WINAPI) LRESULT {
    const sw_opt = findSecondaryByHwnd(hwnd);
    const sw = sw_opt orelse return DefWindowProcW(hwnd, msg, wp, lp);
    switch (msg) {
        WM_DESTROY => {
            sw.closed = true;
            return 0;
        },
        WM_SIZE => {
            const w: u32 = loword(lp);
            const h: u32 = hiword(lp);
            if (w > 0 and h > 0) {
                sw.width = w;
                sw.height = h;
                sw.resized = true;
            }
            return 0;
        },
        WM_MOUSEMOVE => {
            sw.mouse_x = @floatFromInt(lowordSigned(lp));
            sw.mouse_y = @floatFromInt(hiwordSigned(lp));
            return 0;
        },
        WM_LBUTTONDOWN => {
            sw.mouse_x = @floatFromInt(lowordSigned(lp));
            sw.mouse_y = @floatFromInt(hiwordSigned(lp));
            sw.mouse_down_pending = true;
            return 0;
        },
        WM_LBUTTONUP => {
            sw.mouse_x = @floatFromInt(lowordSigned(lp));
            sw.mouse_y = @floatFromInt(hiwordSigned(lp));
            sw.mouse_up_pending = true;
            return 0;
        },
        WM_MOUSEWHEEL => {
            const raw_delta: i16 = @bitCast(@as(u16, @truncate(wp >> 16)));
            const delta: f32 = @floatFromInt(raw_delta);
            sw.wheel_dy += -(delta / WHEEL_DELTA) * WHEEL_PIXELS_PER_NOTCH;
            return 0;
        },
        WM_MOUSEHWHEEL => {
            const raw_delta: i16 = @bitCast(@as(u16, @truncate(wp >> 16)));
            const delta: f32 = @floatFromInt(raw_delta);
            sw.wheel_dx += (delta / WHEEL_DELTA) * WHEEL_PIXELS_PER_NOTCH;
            return 0;
        },
        WM_CHAR => {
            if (wp >= 0x20 and wp < 0x7F) {
                secondaryPushChar(sw, @intCast(wp));
            }
            return 0;
        },
        WM_KEYDOWN => {
            const shift_down = GetKeyState(VK_SHIFT) < 0;
            const ctrl_down = GetKeyState(VK_CONTROL) < 0;
            switch (wp) {
                VK_BACK => secondaryPushKey(sw, .backspace),
                VK_DELETE => secondaryPushKey(sw, .delete),
                VK_LEFT => secondaryPushKey(sw, if (shift_down) .shift_left else .left),
                VK_RIGHT => secondaryPushKey(sw, if (shift_down) .shift_right else .right),
                VK_UP => secondaryPushKey(sw, if (shift_down) .shift_up else .up),
                VK_DOWN => secondaryPushKey(sw, if (shift_down) .shift_down else .down),
                VK_HOME => secondaryPushKey(sw, if (shift_down) .shift_home else .home),
                VK_END => secondaryPushKey(sw, if (shift_down) .shift_end else .end),
                VK_PRIOR => secondaryPushKey(sw, .page_up),
                VK_NEXT => secondaryPushKey(sw, .page_down),
                VK_RETURN => secondaryPushKey(sw, .enter),
                VK_TAB => secondaryPushKey(sw, .tab),
                VK_ESCAPE => secondaryPushKey(sw, .escape),
                VK_A => if (ctrl_down) secondaryPushKey(sw, .ctrl_a),
                VK_C => if (ctrl_down) secondaryPushKey(sw, .ctrl_c),
                VK_V => if (ctrl_down) secondaryPushKey(sw, .ctrl_v),
                VK_X => if (ctrl_down) secondaryPushKey(sw, .ctrl_x),
                VK_Y => if (ctrl_down) secondaryPushKey(sw, .ctrl_y),
                VK_Z => if (ctrl_down) secondaryPushKey(sw, .ctrl_z),
                else => {},
            }
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wp, lp),
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
        WM_MOUSEWHEEL => {
            // GET_WHEEL_DELTA_WPARAM: HIWORD of wparam, signed. Win32
            // sends positive when the wheel turns away from the user
            // (= content should scroll up); we want the InputState
            // convention "positive = scroll down" so negate.
            const raw_delta: i16 = @bitCast(@as(u16, @truncate(wp >> 16)));
            const delta: f32 = @floatFromInt(raw_delta);
            g_wheel_dy += -(delta / WHEEL_DELTA) * WHEEL_PIXELS_PER_NOTCH;
            return 0;
        },
        WM_MOUSEHWHEEL => {
            // Horizontal wheel: Win32 reports positive when tilted
            // right (= content should scroll right), which already
            // matches our "positive = scroll right" convention.
            const raw_delta: i16 = @bitCast(@as(u16, @truncate(wp >> 16)));
            const delta: f32 = @floatFromInt(raw_delta);
            g_wheel_dx += (delta / WHEEL_DELTA) * WHEEL_PIXELS_PER_NOTCH;
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
        WM_IME_STARTCOMPOSITION => {
            g_ime_active = true;
            g_ime_text_len = 0;
            g_ime_cursor = 0;
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
                    if (byte_len > 0) {
                        const u16_units: usize = @intCast(@divTrunc(byte_len, @as(c_long, @sizeOf(u16))));
                        const clamped: usize = @min(u16_units, utf16_buf.len);
                        const written = std.unicode.utf16LeToUtf8(g_ime_text[0..], utf16_buf[0..clamped]) catch 0;
                        g_ime_text_len = written;
                    } else {
                        g_ime_text_len = 0;
                    }
                    // Caret position is a UTF-16 code-unit offset; convert
                    // to a UTF-8 byte offset against our newly-decoded
                    // mirror so the renderer can place the caret correctly.
                    const cur_units = ImmGetCompositionStringW(himc, GCS_CURSORPOS, null, 0);
                    if (cur_units >= 0 and g_ime_text_len > 0) {
                        g_ime_cursor = utf16OffsetToUtf8(
                            g_ime_text[0..g_ime_text_len],
                            @intCast(cur_units),
                        );
                    } else {
                        g_ime_cursor = g_ime_text_len;
                    }
                }
            } else if ((flags & GCS_COMPSTR) == 0 and (flags & GCS_RESULTSTR) != 0) {
                // Commit-only message: drop the pre-commit mirror but
                // stay active until WM_IME_ENDCOMPOSITION arrives.
                g_ime_text_len = 0;
                g_ime_cursor = 0;
            }
            // Pass through so the IME's commit -> WM_CHAR path still fires.
            return DefWindowProcW(hwnd, msg, wp, lp);
        },
        WM_IME_ENDCOMPOSITION => {
            g_ime_active = false;
            g_ime_text_len = 0;
            g_ime_cursor = 0;
            return 0;
        },
        WM_KEYDOWN => {
            // High bit of GetKeyState = held. GetKeyState returns SHORT
            // (i16); checking `< 0` is equivalent to "high bit set" and
            // avoids the C idiom `& 0x8000` which Zig rejects (32768
            // doesn't fit in i16). Read once per WM_KEYDOWN so shift /
            // ctrl reflect the same instant as the key event.
            const shift_down = GetKeyState(VK_SHIFT) < 0;
            const ctrl_down = GetKeyState(VK_CONTROL) < 0;
            switch (wp) {
                VK_BACK => pushKey(.backspace),
                VK_DELETE => pushKey(.delete),
                VK_LEFT => pushKey(if (shift_down) .shift_left else .left),
                VK_RIGHT => pushKey(if (shift_down) .shift_right else .right),
                VK_UP => pushKey(if (shift_down) .shift_up else .up),
                VK_DOWN => pushKey(if (shift_down) .shift_down else .down),
                VK_HOME => pushKey(if (shift_down) .shift_home else .home),
                VK_END => pushKey(if (shift_down) .shift_end else .end),
                VK_PRIOR => pushKey(.page_up),
                VK_NEXT => pushKey(.page_down),
                VK_RETURN => pushKey(.enter),
                VK_TAB => pushKey(.tab),
                VK_ESCAPE => pushKey(.escape),
                VK_A => if (ctrl_down) pushKey(.ctrl_a),
                VK_C => if (ctrl_down) pushKey(.ctrl_c),
                VK_V => if (ctrl_down) pushKey(.ctrl_v),
                VK_X => if (ctrl_down) pushKey(.ctrl_x),
                VK_Y => if (ctrl_down) pushKey(.ctrl_y),
                VK_Z => if (ctrl_down) pushKey(.ctrl_z),
                else => {},
            }
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
            @intCast(width),
            @intCast(height),
            null,
            null,
            hinstance,
            null,
        ) orelse return error.CreateWindowFailed;
        _ = ShowWindow(hwnd, SW_SHOW);

        // Capture the HWND so UIA's get_HostRawElementProvider can hand
        // it to UiaHostProviderFromHwnd for any property we don't
        // ourselves answer.
        g_hwnd_for_uia = hwnd;

        const screen_dc = GetDC(null) orelse return error.GetDcFailed;
        defer _ = ReleaseDC(null, screen_dc);
        const measure_dc = CreateCompatibleDC(screen_dc) orelse return error.CreateDcFailed;

        return .{
            .hinstance = hinstance,
            .hwnd = hwnd,
            .measure_dc = measure_dc,
            .font_cache = undefined,
            .font_cache_len = 0,
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
        const wheel_dx = g_wheel_dx;
        const wheel_dy = g_wheel_dy;
        g_mouse_down_pending = false;
        g_mouse_up_pending = false;
        g_resized = false;
        g_wheel_dx = 0;
        g_wheel_dy = 0;

        return .{
            .mouse_x = g_mouse_x,
            .mouse_y = g_mouse_y,
            .mouse_down = mouse_down,
            .mouse_up = mouse_up,
            .wheel_dx = wheel_dx,
            .wheel_dy = wheel_dy,
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
        var i: usize = 0;
        while (i < cap) : (i += 1) {
            var n = nodes[i];
            // Copy the label into the heap and rewrite its slice to
            // point at the stable copy. Empty label → empty slice.
            if (n.label.len > 0) {
                const remaining = MAX_A11Y_LABEL_BYTES - g_label_heap_used;
                const take = @min(n.label.len, remaining);
                if (take > 0) {
                    @memcpy(g_label_heap[g_label_heap_used .. g_label_heap_used + take], n.label[0..take]);
                    n.label = g_label_heap[g_label_heap_used .. g_label_heap_used + take];
                    g_label_heap_used += take;
                } else {
                    n.label = &.{};
                }
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

    /// Blocks until the user picks a file or cancels. Returns a UTF-8
    /// slice into the Host's dialog buffer (valid until the next
    /// dialog call) or null on cancel.
    pub fn openFileDialog(self: *Host, filter: FileDialogFilter) FileDialogResult {
        return runFileDialog(self, filter, false);
    }

    pub fn saveFileDialog(self: *Host, filter: FileDialogFilter) FileDialogResult {
        return runFileDialog(self, filter, true);
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
            .mouse_x = 0,
            .mouse_y = 0,
            .mouse_down_pending = false,
            .mouse_up_pending = false,
            .wheel_dx = 0,
            .wheel_dy = 0,
            .chars = undefined,
            .chars_count = 0,
            .keys = undefined,
            .keys_count = 0,
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

        const mouse_down = sw.mouse_down_pending;
        const mouse_up = sw.mouse_up_pending;
        const resized = sw.resized;
        const wheel_dx = sw.wheel_dx;
        const wheel_dy = sw.wheel_dy;
        sw.mouse_down_pending = false;
        sw.mouse_up_pending = false;
        sw.resized = false;
        sw.wheel_dx = 0;
        sw.wheel_dy = 0;

        const input: InputState = .{
            .mouse_x = sw.mouse_x,
            .mouse_y = sw.mouse_y,
            .mouse_down = mouse_down,
            .mouse_up = mouse_up,
            .wheel_dx = wheel_dx,
            .wheel_dy = wheel_dy,
            .chars = sw.chars[0..sw.chars_count],
            .keys = sw.keys[0..sw.keys_count],
            .resized = resized,
            .width = sw.width,
            .height = sw.height,
        };

        // Reset queues for the next frame. Slices we returned point
        // into the same buffers; caller must consume before the next
        // poll. Same lifetime contract as the primary pollInputs.
        sw.chars_count = 0;
        sw.keys_count = 0;

        return input;
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
    /// `std.time.milliTimestamp` which is fine for sub-driven cadence
    /// — subs compare deltas, not absolute values.
    pub fn nowMs(_: *const Host) u64 {
        return @intCast(std.time.milliTimestamp());
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

        const result = runFileDialog(self, filter, save);
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

    fn runFileDialog(self: *Host, filter: FileDialogFilter, save: bool) FileDialogResult {
        var file_buf: [260]u16 = [_]u16{0} ** 260;

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
// Win32-only smoke tests. The root `zig build test` runs library
// tests only (not this module), so these won't fire there; they
// compile-check as part of `zig build ui`, and a dedicated win32
// test target could pick them up.

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
