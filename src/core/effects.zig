//! Declarative effects (HARDLINE §2 escape hatch 7 — the sibling of
//! `Sub`, hatch 6).
//!
//! TEA apps need to *ask the outside world for things* (an HTTP call, a
//! file, a download, the clipboard, the wall clock) and hear back later as
//! a `Msg`. Teak keeps `update` a pure `(*Model, Msg) void` switch, so an
//! App does not issue effects imperatively. Instead it **declares** the
//! effects it currently wants:
//!
//! ```zig
//! pub fn effects(m: *const Model) []const teak.Effect;       // pure; like `subscribe`
//! pub fn effectMsg(m: *const Model, r: teak.EffectResult) ?Msg;
//! ```
//!
//! `teak.run` services the list every frame: each effect carries an
//! app-chosen `id` (a counter kept in `Model`); `run` executes an id the
//! first time it sees it and never again while it stays listed (it keeps a
//! small table of issued ids and forgets one after its result has been
//! delivered AND the app stopped listing it). Results come back through
//! `effectMsg` -> `update`, i.e. through the one and only mutation path.
//!
//! All slices inside an `Effect` must borrow from `Model` or the frame
//! arena; all slices inside an `EffectResult` are valid only until the
//! `update` call they trigger returns — the app copies what it keeps.
//!
//! Pure data — no platform types, no callbacks (HARDLINE §3).

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const HttpMethod = enum { get, post, put, delete };

pub const HttpRequest = struct {
    id: u32,
    method: HttpMethod = .get,
    url: []const u8,
    headers: []const Header = &.{},
    body: []const u8 = "",
    /// Give up after this long; the result then has `status = 0`.
    timeout_ms: u32 = 120_000,
};

pub const HttpResult = struct {
    id: u32,
    /// HTTP status. 0 = transport failure (network error, CORS, timeout,
    /// TLS); `err` then says why.
    status: u16,
    body: []const u8 = "",
    err: []const u8 = "",
};

/// Offer bytes to the user as a file: browser download / native save to
/// the app's output directory (or a save dialog).
pub const Download = struct {
    id: u32,
    name: []const u8,
    mime: []const u8 = "application/octet-stream",
    bytes: []const u8,
};

/// Ask the user to pick a file; result is `file_opened` / `file_cancelled`.
pub const OpenFile = struct {
    id: u32,
    /// Comma-separated accept list, like the HTML `accept` attribute:
    /// ".json,.kerf.json" or "image/*". Native hosts map it to a filter.
    accept: []const u8 = "",
};

pub const WriteClipboard = struct {
    id: u32,
    text: []const u8,
};

/// Persistent key/value storage (browser localStorage / a file under the
/// user's config dir on native). `set` with an empty `value` deletes.
pub const StorageSet = struct {
    id: u32,
    key: []const u8,
    value: []const u8,
};

pub const StorageGet = struct {
    id: u32,
    key: []const u8,
};

/// Ask the host for the wall clock (unix epoch ms + local UTC offset
/// minutes). `view` must stay pure, so the time of day reaches the app as
/// a result Msg.
pub const ClockRequest = struct { id: u32 };

pub const Effect = union(enum) {
    http: HttpRequest,
    download: Download,
    open_file: OpenFile,
    write_clipboard: WriteClipboard,
    storage_set: StorageSet,
    storage_get: StorageGet,
    clock: ClockRequest,
};

pub const DropKind = enum { file, image, text };

/// Something the user pasted or dropped onto the window (unsolicited, so
/// it has no request id). Web: paste event / drag-and-drop. Native hosts
/// report `file` drops where the OS supports it.
pub const Drop = struct {
    kind: DropKind,
    /// File name when known ("" for pasted images / text).
    name: []const u8 = "",
    /// MIME type ("image/png", "text/plain", "application/json" ...).
    mime: []const u8 = "",
    bytes: []const u8,
};

pub const EffectResult = union(enum) {
    http: HttpResult,
    /// `bytes` is the whole file.
    file_opened: struct { id: u32, name: []const u8, mime: []const u8, bytes: []const u8 },
    file_cancelled: struct { id: u32 },
    downloaded: struct { id: u32, ok: bool },
    /// `value == null` -> key absent.
    storage_value: struct { id: u32, value: ?[]const u8 },
    clock: struct { id: u32, unix_ms: i64, utc_offset_min: i32 },
    dropped: Drop,
    /// Text pasted with Ctrl/Cmd+V into a page that has no focused text
    /// input (web) — complements `dropped` image pastes.
    pasted_text: struct { text: []const u8 },
};
