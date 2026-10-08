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
//! `teak.run` services the list every frame. Each effect carries an
//! app-chosen `id` (a counter kept in `Model`, unique per request): `run`
//! hands an id to the host the first time it sees it listed, does nothing
//! while it stays listed, and forgets it the first frame it is no longer
//! listed. Results come back through `effectMsg` -> `update`, i.e. through
//! the one and only mutation path. A result whose id is not currently
//! listed is dropped, so delisting an effect cancels interest in its
//! answer.
//!
//! All slices inside an `Effect` must borrow from `Model` (or the frame
//! arena) and are valid only for the duration of the host's `submit` call —
//! the host copies what an async request needs. All slices inside an
//! `EffectResult` are valid only until the `update` call they trigger
//! returns — the app copies what it keeps.
//!
//! Pure data — no platform types, no callbacks (HARDLINE §3). See
//! `docs/features/effects.md`.

const std = @import("std");

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
    /// Native hosts: show a "Save As" dialog (suggesting `name`) instead of
    /// writing to the output directory straight away; the answer is
    /// `downloaded{ ok = false }` when the user cancels. The web always
    /// downloads (the browser owns the prompt) and ignores this.
    pick: bool = false,
    /// Dialog title for `pick` (empty: the toolkit's default).
    title: []const u8 = "",
};

/// Ask the user to pick a file; result is `file_opened` / `file_cancelled`.
pub const OpenFile = struct {
    id: u32,
    /// Comma-separated accept list, like the HTML `accept` attribute:
    /// ".json,.kerf.json" or "image/*". Native hosts map it to a filter.
    accept: []const u8 = "",
    /// Native dialog title (empty: the toolkit's default).
    title: []const u8 = "",
};

pub const WriteClipboard = struct {
    id: u32,
    text: []const u8,
};

/// Put a PNG image on the clipboard (fire and forget, like `write_clipboard`).
/// X11 / Wayland serve it as `image/png` while the window owns the selection;
/// the web writes a `ClipboardItem` (the browser may require a user gesture).
pub const WriteClipboardImage = struct {
    id: u32,
    /// An encoded PNG.
    png: []const u8,
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

/// Read a startup parameter: the URL query string value `?name=...` on the
/// web, a `--name=value` argv entry or the env var `TEAK_<NAME_UPPER>` on
/// native. Answered once with `EffectResult.query_value`.
pub const QueryParam = struct {
    id: u32,
    name: []const u8,
};

pub const Effect = union(enum) {
    http: HttpRequest,
    download: Download,
    open_file: OpenFile,
    write_clipboard: WriteClipboard,
    write_clipboard_image: WriteClipboardImage,
    storage_set: StorageSet,
    storage_get: StorageGet,
    clock: ClockRequest,
    query_param: QueryParam,

    /// The app-chosen request id.
    pub fn id(self: Effect) u32 {
        return switch (self) {
            inline else => |e| e.id,
        };
    }

    /// Fire-and-forget effects (`storage_set`, `write_clipboard`) produce no
    /// result; every other effect is answered exactly once.
    pub fn wantsResult(self: Effect) bool {
        return switch (self) {
            .storage_set, .write_clipboard, .write_clipboard_image => false,
            else => true,
        };
    }
};

/// What `Host.submit` did with an effect.
pub const EffectSubmit = enum {
    /// The host took it (and will answer through `pollEffectResults` when
    /// the effect has a result).
    accepted,
    /// The host cannot take it right now (its request table is full): the
    /// runtime retries on the next frame while the effect stays listed.
    busy,
    /// This host can never service this kind of effect. The runtime answers
    /// with the effect's "failed" result (see `unsupportedResult`) so the
    /// app never waits forever.
    unsupported,
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
    /// The file bytes. For `kind == .image` they are an encoded PNG or JPEG
    /// whose long side the host has already limited (web: <= 1568 px).
    bytes: []const u8,
    /// Images: pixel size of the encoded `bytes`; 0 otherwise.
    width: u32 = 0,
    height: u32 = 0,
    /// Images: a small preview, tightly packed RGBA8, `thumb_w * thumb_h * 4`
    /// bytes (long side <= 64 px), ready for `uploadImage`. Empty otherwise.
    thumb_rgba: []const u8 = "",
    thumb_w: u32 = 0,
    thumb_h: u32 = 0,
};

pub const EffectResult = union(enum) {
    http: HttpResult,
    /// `bytes` is the whole file.
    file_opened: struct { id: u32, name: []const u8, mime: []const u8, bytes: []const u8 },
    file_cancelled: struct { id: u32 },
    downloaded: struct { id: u32, ok: bool },
    /// `value == null` -> key absent.
    storage_value: struct { id: u32, value: ?[]const u8 },
    /// `value == null` -> the parameter is absent.
    query_value: struct { id: u32, value: ?[]const u8 },
    clock: struct { id: u32, unix_ms: i64, utc_offset_min: i32 },
    dropped: Drop,
    /// Text pasted with Ctrl/Cmd+V into a page that has no focused text
    /// input (web) — complements `dropped` image pastes.
    pasted_text: struct { text: []const u8 },
};

/// Result of an effect, as the app's `effectMsg` sees it.
pub fn resultId(r: EffectResult) ?u32 {
    return switch (r) {
        .dropped, .pasted_text => null,
        inline else => |v| v.id,
    };
}

/// The "failed" answer for an effect the host cannot service, so an app
/// never waits forever: HTTP status 0, a cancelled picker, an absent key.
/// Null for fire-and-forget effects.
pub fn unsupportedResult(e: Effect) ?EffectResult {
    return switch (e) {
        .http => |r| .{ .http = .{ .id = r.id, .status = 0, .err = "effects are not supported by this host" } },
        .download => |r| .{ .downloaded = .{ .id = r.id, .ok = false } },
        .open_file => |r| .{ .file_cancelled = .{ .id = r.id } },
        .storage_get => |r| .{ .storage_value = .{ .id = r.id, .value = null } },
        .clock => |r| .{ .clock = .{ .id = r.id, .unix_ms = 0, .utc_offset_min = 0 } },
        .query_param => |r| .{ .query_value = .{ .id = r.id, .value = null } },
        .storage_set, .write_clipboard, .write_clipboard_image => null,
    };
}

/// The runtime's table of effect ids it has handed to the host. Fixed size
/// (no allocation); loop bookkeeping, not application state.
///
/// Per frame: `beginFrame`, then `listed(id)` for every effect in the app's
/// list (true = already issued, so skip it), `issue(id)` after the host took
/// a new one, and `sweep` to forget ids that were not listed this frame.
pub fn IssuedTable(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        ids: [capacity]u32 = undefined,
        seen: [capacity]bool = undefined,
        len: usize = 0,

        fn find(self: *const Self, id: u32) ?usize {
            for (self.ids[0..self.len], 0..) |have, i| {
                if (have == id) return i;
            }
            return null;
        }

        /// True if `id` was issued and is still remembered.
        pub fn contains(self: *const Self, id: u32) bool {
            return self.find(id) != null;
        }

        pub fn isFull(self: *const Self) bool {
            return self.len == capacity;
        }

        pub fn beginFrame(self: *Self) void {
            @memset(self.seen[0..self.len], false);
        }

        /// Mark `id` as listed this frame; true if it had been issued.
        pub fn listed(self: *Self, id: u32) bool {
            const i = self.find(id) orelse return false;
            self.seen[i] = true;
            return true;
        }

        /// Remember a freshly issued id (counts as listed). False if full.
        pub fn issue(self: *Self, id: u32) bool {
            if (self.find(id) != null) return true;
            if (self.len == capacity) return false;
            self.ids[self.len] = id;
            self.seen[self.len] = true;
            self.len += 1;
            return true;
        }

        /// Forget every id that `listed` / `issue` did not touch since
        /// `beginFrame`.
        pub fn sweep(self: *Self) void {
            var keep: usize = 0;
            for (0..self.len) |i| {
                if (!self.seen[i]) continue;
                self.ids[keep] = self.ids[i];
                self.seen[keep] = true;
                keep += 1;
            }
            self.len = keep;
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────

test "Effect.id and wantsResult cover every variant" {
    const effs = [_]Effect{
        .{ .http = .{ .id = 1, .url = "u" } },
        .{ .download = .{ .id = 2, .name = "n", .bytes = "" } },
        .{ .open_file = .{ .id = 3 } },
        .{ .write_clipboard = .{ .id = 4, .text = "" } },
        .{ .storage_set = .{ .id = 5, .key = "k", .value = "v" } },
        .{ .storage_get = .{ .id = 6, .key = "k" } },
        .{ .clock = .{ .id = 7 } },
        .{ .query_param = .{ .id = 8, .name = "q" } },
        .{ .write_clipboard_image = .{ .id = 9, .png = "" } },
    };
    for (effs, 1..) |e, want| {
        try std.testing.expectEqual(@as(u32, @intCast(want)), e.id());
        // The fire-and-forget kinds are exactly the ones with no failed result.
        try std.testing.expectEqual(e.wantsResult(), unsupportedResult(e) != null);
    }
    try std.testing.expect(!effs[3].wantsResult());
    try std.testing.expect(!effs[4].wantsResult());
    try std.testing.expect(!effs[8].wantsResult());
}

test "unsupportedResult answers with the effect's own id" {
    const r = unsupportedResult(.{ .http = .{ .id = 9, .url = "u" } }).?;
    try std.testing.expectEqual(@as(u32, 9), resultId(r).?);
    try std.testing.expectEqual(@as(u16, 0), r.http.status);
    try std.testing.expect(r.http.err.len > 0);
    try std.testing.expect(unsupportedResult(.{ .open_file = .{ .id = 3 } }).? == .file_cancelled);
}

test "resultId is null for unsolicited results" {
    try std.testing.expect(resultId(.{ .pasted_text = .{ .text = "x" } }) == null);
    try std.testing.expect(resultId(.{ .dropped = .{ .kind = .file, .bytes = "" } }) == null);
    try std.testing.expectEqual(@as(u32, 4), resultId(.{ .query_value = .{ .id = 4, .value = null } }).?);
}

test "IssuedTable: issued once, remembered while listed, forgotten after" {
    var t: IssuedTable(4) = .{};

    t.beginFrame();
    try std.testing.expect(!t.listed(10)); // new: caller issues it
    try std.testing.expect(t.issue(10));
    t.sweep();
    try std.testing.expect(t.contains(10));

    t.beginFrame();
    try std.testing.expect(t.listed(10)); // still listed: not new
    t.sweep();
    try std.testing.expect(t.contains(10));

    t.beginFrame(); // delisted
    t.sweep();
    try std.testing.expect(!t.contains(10));

    t.beginFrame(); // relisting counts as new again
    try std.testing.expect(!t.listed(10));
}

test "IssuedTable: full table refuses new ids until one is forgotten" {
    var t: IssuedTable(2) = .{};
    t.beginFrame();
    try std.testing.expect(t.issue(1));
    try std.testing.expect(t.issue(2));
    try std.testing.expect(t.isFull());
    try std.testing.expect(!t.issue(3));
    t.sweep();

    t.beginFrame();
    _ = t.listed(2); // 1 delisted
    t.sweep();
    try std.testing.expect(!t.isFull());
    try std.testing.expect(t.issue(3));
    try std.testing.expect(t.contains(2) and t.contains(3) and !t.contains(1));
}
