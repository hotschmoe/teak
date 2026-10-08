//! Wayland host backend: the `platform/host.zig` contract on top of
//! xdg-shell, the Linux counterpart of `x11.zig` for compositors that no
//! longer ship (or hide) XWayland.
//!
//! Everything is loaded at runtime with `std.DynLib`, like the X11 host: no
//! wayland / xkbcommon development packages, nothing linked. The protocol
//! tables come from `wayland/protocols.zig` (generated, committed) and
//! libwayland-client does the marshalling (`wayland/client.zig`), so the
//! `wl_display*` / `wl_surface*` handed to the GPU backend are the real
//! objects Vulkan's Wayland WSI wants.
//!
//!   - window: xdg_wm_base / xdg_toplevel (+ xdg-decoration server-side when
//!     offered; otherwise the window is undecorated — libdecor is not used).
//!   - input: wl_pointer, wl_keyboard through xkbcommon (client-side key
//!     repeat), decoded by `wayland/data.zig`.
//!   - clipboard + drag and drop: wl_data_device; text and PNG paste and
//!     file / text drops surface as the same effect results as X11 / web.
//!   - IME: zwp_text_input_v3 (preedit -> `imeState`, commit -> typed text).
//!   - HiDPI: wp_fractional_scale_v1 + wp_viewporter, else the integer
//!     `wl_output` scale via `set_buffer_scale`. Sizes and pointer
//!     coordinates are logical; the Gpu renders `scale` times larger.
//!   - cursors: libwayland-cursor theme (optional).
//!
//! Host state lives in one heap `State`: libwayland keeps its address as the
//! listener user data, and `Host` itself is returned by value.

const std = @import("std");
const teak = @import("teak");
const text = @import("teak-text");
const native_effects = @import("native_effects.zig");
const drops = @import("native_drops.zig");
const x11_data = @import("x11_data.zig");
const wl = @import("wayland/protocols.zig");
const client = @import("wayland/client.zig");
const data = @import("wayland/data.zig");

pub const InputState = teak.InputState;
pub const SpecialKey = teak.SpecialKey;
pub const InputQueue = teak.InputQueue;
pub const TextMeasurer = teak.TextMeasurer;
pub const TextMetrics = teak.TextMetrics;
pub const FontSpec = teak.FontSpec;
pub const Clipboard = teak.Clipboard;
pub const ImeState = teak.ImeState;
pub const A11yNode = teak.A11yNode;
pub const FileDialogResult = teak.FileDialogResult;
pub const FileDialogFilter = teak.FileDialogFilter;
pub const FileDialogPoll = teak.FileDialogPoll;

const gpa = std.heap.page_allocator;

// ── libc bits (libc is linked: DynLib needs its dlopen) ────────────

const PollFd = extern struct { fd: c_int, events: c_short, revents: c_short };
const POLLIN: c_short = 0x001;
const POLLOUT: c_short = 0x004;
const POLLHUP: c_short = 0x010;
extern "c" fn poll(fds: [*]PollFd, n: c_ulong, timeout: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn memfd_create(name: [*:0]const u8, flags: c_uint) c_int;
extern "c" fn ftruncate(fd: c_int, len: i64) c_int;
extern "c" fn pipe2(fds: *[2]c_int, flags: c_int) c_int;
extern "c" fn mmap(addr: ?*anyopaque, len: usize, prot: c_int, flags: c_int, fd: c_int, off: isize) ?*anyopaque;
extern "c" fn munmap(addr: *anyopaque, len: usize) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
const O_NONBLOCK: c_int = 0x800;
const O_CLOEXEC: c_int = 0x80000;

// ── xkbcommon (dlopened) ───────────────────────────────────────────

const Xkb = struct {
    lib: std.DynLib,
    f: Fns,

    const Fns = struct {
        context_new: *const fn (c_int) callconv(.c) ?*anyopaque,
        context_unref: *const fn (*anyopaque) callconv(.c) void,
        keymap_new_from_string: *const fn (*anyopaque, [*:0]const u8, c_int, c_int) callconv(.c) ?*anyopaque,
        keymap_unref: *const fn (*anyopaque) callconv(.c) void,
        keymap_key_repeats: *const fn (*anyopaque, u32) callconv(.c) c_int,
        state_new: *const fn (*anyopaque) callconv(.c) ?*anyopaque,
        state_unref: *const fn (*anyopaque) callconv(.c) void,
        state_update_mask: *const fn (*anyopaque, u32, u32, u32, u32, u32, u32) callconv(.c) c_int,
        state_key_get_one_sym: *const fn (*anyopaque, u32) callconv(.c) u32,
        state_key_get_utf8: *const fn (*anyopaque, u32, [*]u8, usize) callconv(.c) c_int,
        state_mod_name_is_active: *const fn (*anyopaque, [*:0]const u8, c_int) callconv(.c) c_int,
    };

    fn load() ?Xkb {
        var lib = std.DynLib.open("libxkbcommon.so.0") catch return null;
        var f: Fns = undefined;
        const info = @typeInfo(Fns).@"struct";
        inline for (info.field_names, info.field_types) |name, ty| {
            @field(f, name) = lib.lookup(ty, "xkb_" ++ name) orelse {
                lib.close();
                return null;
            };
        }
        return .{ .lib = lib, .f = f };
    }
};

// ── libwayland-cursor (dlopened, optional) ─────────────────────────

const CursorImage = extern struct { width: u32, height: u32, hotspot_x: u32, hotspot_y: u32, delay: u32 };
const WlCursor = extern struct { image_count: c_uint, images: [*]*CursorImage, name: [*:0]const u8 };
const CursorLib = struct {
    lib: std.DynLib,
    theme_load: *const fn (?[*:0]const u8, c_int, *wl.wl_shm) callconv(.c) ?*anyopaque,
    theme_destroy: *const fn (*anyopaque) callconv(.c) void,
    theme_get_cursor: *const fn (*anyopaque, [*:0]const u8) callconv(.c) ?*WlCursor,
    image_get_buffer: *const fn (*CursorImage) callconv(.c) ?*wl.wl_buffer,

    fn load() ?CursorLib {
        var lib = std.DynLib.open("libwayland-cursor.so.0") catch return null;
        const a = lib.lookup(@FieldType(CursorLib, "theme_load"), "wl_cursor_theme_load");
        const b = lib.lookup(@FieldType(CursorLib, "theme_destroy"), "wl_cursor_theme_destroy");
        const c = lib.lookup(@FieldType(CursorLib, "theme_get_cursor"), "wl_cursor_theme_get_cursor");
        const d = lib.lookup(@FieldType(CursorLib, "image_get_buffer"), "wl_cursor_image_get_buffer");
        if (a == null or b == null or c == null or d == null) {
            lib.close();
            return null;
        }
        return .{ .lib = lib, .theme_load = a.?, .theme_destroy = b.?, .theme_get_cursor = c.?, .image_get_buffer = d.? };
    }
};

// ── Host state ─────────────────────────────────────────────────────

const MAX_OFFERS = 6;
const Offer = struct {
    proxy: ?*wl.wl_data_offer = null,
    flags: data.OfferFlags = .{},
};

const XferKind = enum { sync_text, paste_text, paste_png, dnd_uri, dnd_text };
const Transfer = struct {
    kind: XferKind,
    fd: c_int,
    buf: std.ArrayList(u8) = .empty,
    deadline_ms: u64,
    /// DnD: the offer to `finish` once the data is in.
    offer: ?*wl.wl_data_offer = null,
};

/// An outgoing clipboard payload being written to a requestor's pipe.
const WriteJob = struct { fd: c_int, bytes: []u8, off: usize = 0 };

const MAX_XFER_BYTES: usize = 64 * 1024 * 1024;
const XFER_TIMEOUT_MS: u64 = 5000;
const SYNC_READ_TIMEOUT_MS: u64 = 250;

const State = struct {
    xkb: ?Xkb,
    cursor_lib: ?CursorLib,
    display: *client.Display,

    // globals
    registry: *wl.wl_registry,
    compositor: ?*wl.wl_compositor = null,
    shm: ?*wl.wl_shm = null,
    wm_base: ?*wl.xdg_wm_base = null,
    seat: ?*wl.wl_seat = null,
    data_mgr: ?*wl.wl_data_device_manager = null,
    text_input_mgr: ?*wl.zwp_text_input_manager_v3 = null,
    decoration_mgr: ?*wl.zxdg_decoration_manager_v1 = null,
    fractional_mgr: ?*wl.wp_fractional_scale_manager_v1 = null,
    viewporter: ?*wl.wp_viewporter = null,
    output_scale: u32 = 1,

    // window
    surface: *wl.wl_surface = undefined,
    xdg_surface: *wl.xdg_surface = undefined,
    toplevel: *wl.xdg_toplevel = undefined,
    decoration: ?*wl.zxdg_toplevel_decoration_v1 = null,
    fractional: ?*wl.wp_fractional_scale_v1 = null,
    viewport: ?*wl.wp_viewport = null,
    configured: bool = false,
    running: bool = true,
    /// Logical size and the compositor's pending suggestion (0 = free).
    width: u32,
    height: u32,
    pending_w: u32 = 0,
    pending_h: u32 = 0,
    first_resize: bool = true,
    resized_pending: bool = false,
    scale: f32 = 1,
    scale_env: ?f32 = null,
    fractional_120: ?u32 = null,

    // input
    pointer: ?*wl.wl_pointer = null,
    keyboard: ?*wl.wl_keyboard = null,
    queue: InputQueue = .{},
    wheel: data.WheelAccum = .{},
    repeat: data.Repeat = .{},
    xkb_ctx: ?*anyopaque = null,
    xkb_keymap: ?*anyopaque = null,
    xkb_state: ?*anyopaque = null,
    last_serial: u32 = 0,
    pointer_serial: u32 = 0,
    /// Serial of the last pointer button event (drag-and-drop origin).
    button_serial: u32 = 0,
    /// The pointer is over our surface (enter .. leave).
    pointer_inside: bool = false,
    paste_requested: bool = false,
    now_ms: u64 = 0,

    // cursor
    cursor_surface: ?*wl.wl_surface = null,
    cursor_theme: ?*anyopaque = null,
    cursor_shape: teak.CursorShape = .arrow,

    // clipboard / dnd
    data_device: ?*wl.wl_data_device = null,
    offers: [MAX_OFFERS]Offer = @splat(.{}),
    selection: ?usize = null,
    dnd: ?usize = null,
    source: ?*wl.wl_data_source = null,
    clip_out: ?[]u8 = null,
    read_buf: ?[]u8 = null,
    xfer: ?Transfer = null,
    writes: [4]?WriteJob = @splat(null),

    // IME (zwp_text_input_v3)
    text_input: ?*wl.zwp_text_input_v3 = null,
    ti_enabled: bool = false,
    ti_serial: u32 = 0,
    preedit_pending: bool = false,
    preedit_set: bool = false,
    preedit_tmp: [128]u8 = undefined,
    preedit_tmp_len: usize = 0,
    preedit_cursor_tmp: usize = 0,
    commit_tmp: [256]u8 = undefined,
    commit_tmp_len: usize = 0,
    ime: x11_data.Preedit = .{},
    ime_buf: [128]u8 = undefined,
    ime_len: usize = 0,
    ime_cursor: usize = 0,
    ime_active: bool = false,

    effects: *native_effects.Service,

    // ── Window / scale ──────────────────────────────────────────────

    fn setTitleZ(self: *State, title: []const u8) void {
        var buf: [256]u8 = undefined;
        const n = @min(title.len, buf.len - 1);
        @memcpy(buf[0..n], title[0..n]);
        buf[n] = 0;
        wl.xdg_toplevel_set_title(self.toplevel, @ptrCast(&buf));
    }

    /// Adopt a configure size (0 = the compositor leaves it to us) and tell
    /// the compositor the logical size of the surface when a viewport is used.
    fn applySize(self: *State, w: u32, h: u32) void {
        const nw = if (w > 0) w else self.width;
        const nh = if (h > 0) h else self.height;
        if (nw != self.width or nh != self.height) {
            self.width = nw;
            self.height = nh;
            self.resized_pending = true;
        }
        if (self.viewport) |vp| wl.wp_viewport_set_destination(vp, @intCast(self.width), @intCast(self.height));
    }

    /// Recompute the display scale after a fractional / output / env change.
    fn updateScale(self: *State) void {
        const new = data.effectiveScale(.{
            .env = self.scale_env,
            .fractional_120 = self.fractional_120,
            .output = self.output_scale,
            .viewporter = self.viewport != null,
        });
        if (new != self.scale) {
            self.scale = new;
            self.resized_pending = true; // the Gpu re-sizes its surface
        }
        wl.wl_surface_set_buffer_scale(self.surface, data.bufferScale(self.scale, self.viewport != null));
        if (self.viewport) |vp| wl.wp_viewport_set_destination(vp, @intCast(self.width), @intCast(self.height));
    }

    // ── Event pump ──────────────────────────────────────────────────

    /// Read whatever the compositor sent (never blocks) and dispatch it.
    fn pumpEvents(self: *State) void {
        const api = &client.api;
        var rounds: u32 = 0;
        while (rounds < 8) : (rounds += 1) {
            while (api.display_prepare_read(self.display) != 0) _ = api.display_dispatch_pending(self.display);
            _ = api.display_flush(self.display);
            var pfd = [1]PollFd{.{ .fd = api.display_get_fd(self.display), .events = POLLIN, .revents = 0 }};
            const ready = poll(&pfd, 1, 0);
            if (ready > 0 and (pfd[0].revents & POLLIN) != 0) {
                if (api.display_read_events(self.display) < 0) {
                    self.running = false;
                    return;
                }
                _ = api.display_dispatch_pending(self.display);
            } else {
                api.display_cancel_read(self.display);
                _ = api.display_dispatch_pending(self.display);
                return;
            }
        }
    }

    // ── Keyboard ────────────────────────────────────────────────────

    fn currentMods(self: *State) teak.Modifiers {
        const x = self.xkb orelse return .{};
        const st = self.xkb_state orelse return .{};
        const eff = 8; // XKB_STATE_MODS_EFFECTIVE
        return .{
            .shift = x.f.state_mod_name_is_active(st, "Shift", eff) > 0,
            .ctrl = x.f.state_mod_name_is_active(st, "Control", eff) > 0,
            .alt = x.f.state_mod_name_is_active(st, "Mod1", eff) > 0,
            .meta = x.f.state_mod_name_is_active(st, "Mod4", eff) > 0,
        };
    }

    /// One key press (or a repeat of it) from an evdev keycode.
    fn keyPress(self: *State, key: u32, first: bool) void {
        const x = self.xkb orelse return;
        const st = self.xkb_state orelse return;
        const code = key + 8; // evdev -> xkb keycode
        const sym = x.f.state_key_get_one_sym(st, code);
        var utf8: [16]u8 = undefined;
        const n = x.f.state_key_get_utf8(st, code, &utf8, utf8.len);
        const text_bytes = utf8[0..if (n > 0) @intCast(@min(n, utf8.len)) else 0];
        const r = data.decodeKey(&self.queue, self.currentMods(), sym, text_bytes);
        if (r.paste and first) self.paste_requested = true;
        if (first and r.repeats and x.f.keymap_key_repeats(self.xkb_keymap.?, code) != 0) self.repeat.press(key, self.now_ms);
    }

    // ── Cursor ──────────────────────────────────────────────────────

    fn initCursor(self: *State) void {
        const lib = self.cursor_lib orelse return;
        const shm = self.shm orelse return;
        const comp = self.compositor orelse return;
        const bs: c_int = @max(1, @as(c_int, @intFromFloat(@ceil(self.scale))));
        self.cursor_theme = lib.theme_load(null, 24 * bs, shm);
        if (self.cursor_theme != null) self.cursor_surface = wl.wl_compositor_create_surface(comp);
    }

    /// Show `cursor_shape` (themed name, then the legacy X name).
    fn applyCursor(self: *State) void {
        const lib = self.cursor_lib orelse return;
        const theme = self.cursor_theme orelse return;
        const surf = self.cursor_surface orelse return;
        const ptr = self.pointer orelse return;
        if (self.pointer_serial == 0) return;
        const names = cursorNames(self.cursor_shape);
        const cur = lib.theme_get_cursor(theme, names[0]) orelse lib.theme_get_cursor(theme, names[1]) orelse return;
        if (cur.image_count == 0) return;
        const img = cur.images[0];
        const buf = lib.image_get_buffer(img) orelse return;
        const bs: i32 = @max(1, @as(i32, @intFromFloat(@ceil(self.scale))));
        wl.wl_surface_set_buffer_scale(surf, bs);
        wl.wl_surface_attach(surf, buf, 0, 0);
        wl.wl_surface_damage(surf, 0, 0, @intCast(img.width), @intCast(img.height));
        wl.wl_surface_commit(surf);
        wl.wl_pointer_set_cursor(ptr, self.pointer_serial, surf, @divTrunc(@as(i32, @intCast(img.hotspot_x)), bs), @divTrunc(@as(i32, @intCast(img.hotspot_y)), bs));
        _ = client.api.display_flush(self.display);
    }

    // ── Clipboard + drag and drop ───────────────────────────────────

    fn writeClipboard(self: *State, txt: []const u8) void {
        const mgr = self.data_mgr orelse return;
        const dd = self.data_device orelse return;
        const copy = gpa.dupe(u8, txt) catch return;
        if (self.clip_out) |b| gpa.free(b);
        self.clip_out = copy;
        if (self.source) |old| {
            self.source = null;
            wl.wl_data_source_destroy(old);
        }
        const src = wl.wl_data_device_manager_create_data_source(mgr);
        self.source = src;
        wl.wl_data_source_add_listener(src, &source_listener, self);
        wl.wl_data_source_offer(src, "text/plain;charset=utf-8");
        wl.wl_data_source_offer(src, "text/plain");
        wl.wl_data_source_offer(src, "UTF8_STRING");
        wl.wl_data_device_set_selection(dd, src, self.last_serial);
        _ = client.api.display_flush(self.display);
    }

    /// Push pending bytes of outgoing clipboard writes into their pipes.
    fn pumpWrites(self: *State) void {
        for (&self.writes) |*slot| {
            const j = &(slot.* orelse continue);
            while (j.off < j.bytes.len) {
                const n = write(j.fd, j.bytes.ptr + j.off, j.bytes.len - j.off);
                if (n <= 0) break; // EAGAIN (retry next frame) or the reader left
                j.off += @intCast(n);
            }
            if (j.off >= j.bytes.len or !fdOpenForWrite(j.fd)) {
                _ = close(j.fd);
                gpa.free(j.bytes);
                slot.* = null;
            }
        }
    }

    fn weOwnClipboard(self: *const State) bool {
        return self.source != null and self.clip_out != null;
    }

    fn startPaste(self: *State) void {
        if (self.weOwnClipboard()) return drops.pastedText(self.effects, self.clip_out.?);
        const idx = self.selection orelse return;
        const pick = data.pickForPaste(self.offers[idx].flags) orelse return;
        const kind: XferKind = if (pick.pick == .png) .paste_png else .paste_text;
        self.startTransfer(kind, self.offers[idx].proxy.?, pick.mime, null);
    }

    /// Begin receiving `mime` from `offer` into a non-blocking pipe.
    fn startTransfer(self: *State, kind: XferKind, offer: *wl.wl_data_offer, mime: [*:0]const u8, finish: ?*wl.wl_data_offer) void {
        self.abortTransfer();
        var fds: [2]c_int = undefined;
        if (pipe2(&fds, O_CLOEXEC | O_NONBLOCK) != 0) return;
        wl.wl_data_offer_receive(offer, mime, fds[1]);
        _ = close(fds[1]); // the source holds its own copy now
        _ = client.api.display_flush(self.display);
        self.xfer = .{ .kind = kind, .fd = fds[0], .deadline_ms = self.now_ms + XFER_TIMEOUT_MS, .offer = finish };
    }

    fn abortTransfer(self: *State) void {
        if (self.xfer) |*t| {
            _ = close(t.fd);
            t.buf.deinit(gpa);
            self.xfer = null;
        }
    }

    fn expireTransfer(self: *State) void {
        if (self.xfer) |t| if (self.now_ms >= t.deadline_ms) self.abortTransfer();
    }

    /// Read what the source has written so far; completes on EOF.
    fn progressTransfer(self: *State) void {
        const t = &(self.xfer orelse return);
        var chunk: [65536]u8 = undefined;
        while (true) {
            const n = read(t.fd, &chunk, chunk.len);
            if (n > 0) {
                t.buf.appendSlice(gpa, chunk[0..@intCast(n)]) catch return self.abortTransfer();
                if (t.buf.items.len > MAX_XFER_BYTES) return self.abortTransfer();
                continue;
            }
            if (n == 0) return self.completeTransfer();
            return; // EAGAIN: more later
        }
    }

    fn completeTransfer(self: *State) void {
        var t = self.xfer orelse return;
        self.xfer = null;
        defer {
            _ = close(t.fd);
            t.buf.deinit(gpa);
        }
        const bytes = t.buf.items;
        switch (t.kind) {
            .sync_text => {
                if (self.read_buf) |b| gpa.free(b);
                self.read_buf = gpa.dupe(u8, bytes) catch null;
            },
            .paste_text => drops.pastedText(self.effects, bytes),
            .paste_png => drops.pastedImage(self.effects, bytes),
            .dnd_text => drops.droppedText(self.effects, bytes),
            .dnd_uri => drops.droppedFiles(self.effects, bytes),
        }
        if (t.offer) |o| {
            wl.wl_data_offer_finish(o);
            _ = client.api.display_flush(self.display);
        }
    }

    /// `Clipboard.read`: our own text, else a bounded blocking pipe read.
    fn syncRead(self: *State) []const u8 {
        if (self.read_buf) |b| gpa.free(b);
        self.read_buf = null;
        self.paste_requested = false; // claimed: no `pasted_text` for this press
        if (self.weOwnClipboard()) return self.clip_out.?;
        const idx = self.selection orelse return "";
        const f = self.offers[idx].flags;
        if (!f.hasText()) return "";
        self.now_ms = monotonicMs();
        self.startTransfer(.sync_text, self.offers[idx].proxy.?, if (f.utf8) "text/plain;charset=utf-8" else "text/plain", null);
        const deadline = self.now_ms + SYNC_READ_TIMEOUT_MS;
        while (self.xfer != null and monotonicMs() < deadline) {
            var pfd = [1]PollFd{.{ .fd = self.xfer.?.fd, .events = POLLIN, .revents = 0 }};
            _ = poll(&pfd, 1, 5);
            self.progressTransfer();
        }
        if (self.xfer != null) self.abortTransfer();
        return self.read_buf orelse "";
    }

    // ── IME ─────────────────────────────────────────────────────────

    /// A text-input `done`: apply the commit, then the preedit.
    fn applyImeDone(self: *State) void {
        if (self.commit_tmp_len > 0) {
            const t = self.commit_tmp[0..self.commit_tmp_len];
            if (std.unicode.utf8ValidateSlice(t)) {
                var it = std.unicode.Utf8View.initUnchecked(t).iterator();
                while (it.nextCodepoint()) |cp| self.queue.pushCodepoint(cp);
            }
            self.commit_tmp_len = 0;
        }
        if (self.preedit_pending) {
            self.preedit_pending = false;
            const t = self.preedit_tmp[0..self.preedit_tmp_len];
            if (t.len == 0 or !std.unicode.utf8ValidateSlice(t)) {
                self.ime_active = false;
                self.ime_len = 0;
                self.ime_cursor = 0;
            } else {
                self.ime_active = true;
                self.ime_len = @min(t.len, self.ime_buf.len);
                @memcpy(self.ime_buf[0..self.ime_len], t[0..self.ime_len]);
                self.ime_cursor = @min(self.preedit_cursor_tmp, self.ime_len);
            }
        }
    }
};

fn fdOpenForWrite(fd: c_int) bool {
    var p = [1]PollFd{.{ .fd = fd, .events = POLLOUT, .revents = 0 }};
    _ = poll(&p, 1, 0);
    return (p[0].revents & (POLLHUP | 0x008)) == 0; // POLLERR = 0x008
}

/// Theme names for a shape: the CSS-style name, then the classic X name.
fn cursorNames(shape: teak.CursorShape) [2][:0]const u8 {
    return switch (shape) {
        .arrow => .{ "default", "left_ptr" },
        .pointer => .{ "pointer", "hand2" },
        .ibeam => .{ "text", "xterm" },
        .crosshair => .{ "crosshair", "cross" },
        .move => .{ "move", "fleur" },
        .resize_ew => .{ "ew-resize", "sb_h_double_arrow" },
        .resize_ns => .{ "ns-resize", "sb_v_double_arrow" },
        .resize_nwse => .{ "nwse-resize", "bottom_right_corner" },
        .resize_nesw => .{ "nesw-resize", "bottom_left_corner" },
        .not_allowed => .{ "not-allowed", "crossed_circle" },
        .grab => .{ "grab", "hand1" },
        .grabbing => .{ "grabbing", "fleur" },
    };
}

extern "c" fn signal(sig: c_int, handler: ?*const anyopaque) ?*const anyopaque;

fn S(d: ?*anyopaque) *State {
    return @ptrCast(@alignCast(d.?));
}

// ── Protocol callbacks ─────────────────────────────────────────────

fn nameIs(iface: [*:0]const u8, comptime want: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(iface), want);
}

fn bind(comptime T: type, reg: *wl.wl_registry, name: u32, iface: *const client.Interface, ver: u32, max: u32) *T {
    return @ptrCast(wl.wl_registry_bind(reg, name, iface, @min(ver, max)));
}

fn onGlobal(d: ?*anyopaque, reg: *wl.wl_registry, name: u32, iface: [*:0]const u8, ver: u32) callconv(.c) void {
    const s = S(d);
    if (nameIs(iface, "wl_compositor")) {
        s.compositor = bind(wl.wl_compositor, reg, name, &wl.wl_compositor_interface, ver, 4);
    } else if (nameIs(iface, "wl_shm")) {
        s.shm = bind(wl.wl_shm, reg, name, &wl.wl_shm_interface, ver, 1);
    } else if (nameIs(iface, "xdg_wm_base")) {
        s.wm_base = bind(wl.xdg_wm_base, reg, name, &wl.xdg_wm_base_interface, ver, 2);
    } else if (nameIs(iface, "wl_seat")) {
        if (s.seat == null) s.seat = bind(wl.wl_seat, reg, name, &wl.wl_seat_interface, ver, 8);
    } else if (nameIs(iface, "wl_data_device_manager")) {
        s.data_mgr = bind(wl.wl_data_device_manager, reg, name, &wl.wl_data_device_manager_interface, ver, 3);
    } else if (nameIs(iface, "zwp_text_input_manager_v3")) {
        s.text_input_mgr = bind(wl.zwp_text_input_manager_v3, reg, name, &wl.zwp_text_input_manager_v3_interface, ver, 1);
    } else if (nameIs(iface, "zxdg_decoration_manager_v1")) {
        s.decoration_mgr = bind(wl.zxdg_decoration_manager_v1, reg, name, &wl.zxdg_decoration_manager_v1_interface, ver, 1);
    } else if (nameIs(iface, "wp_fractional_scale_manager_v1")) {
        s.fractional_mgr = bind(wl.wp_fractional_scale_manager_v1, reg, name, &wl.wp_fractional_scale_manager_v1_interface, ver, 1);
    } else if (nameIs(iface, "wp_viewporter")) {
        s.viewporter = bind(wl.wp_viewporter, reg, name, &wl.wp_viewporter_interface, ver, 1);
    } else if (nameIs(iface, "wl_output")) {
        const o = bind(wl.wl_output, reg, name, &wl.wl_output_interface, ver, 2);
        wl.wl_output_add_listener(o, &output_listener, s);
    }
}

const registry_listener = wl.wl_registry_listener{ .global = onGlobal };

fn onOutputScale(d: ?*anyopaque, _: *wl.wl_output, factor: i32) callconv(.c) void {
    const s = S(d);
    if (factor > 0) s.output_scale = @max(s.output_scale, @as(u32, @intCast(factor)));
}
const output_listener = wl.wl_output_listener{ .scale = onOutputScale };

fn onPing(_: ?*anyopaque, base: *wl.xdg_wm_base, serial: u32) callconv(.c) void {
    wl.xdg_wm_base_pong(base, serial);
}
const wm_base_listener = wl.xdg_wm_base_listener{ .ping = onPing };

fn onXdgConfigure(d: ?*anyopaque, xs: *wl.xdg_surface, serial: u32) callconv(.c) void {
    const s = S(d);
    wl.xdg_surface_ack_configure(xs, serial);
    s.configured = true;
    s.applySize(s.pending_w, s.pending_h);
}
const xdg_surface_listener = wl.xdg_surface_listener{ .configure = onXdgConfigure };

fn onToplevelConfigure(d: ?*anyopaque, _: *wl.xdg_toplevel, w: i32, h: i32, _: *client.Array) callconv(.c) void {
    const s = S(d);
    s.pending_w = if (w > 0) @intCast(w) else 0;
    s.pending_h = if (h > 0) @intCast(h) else 0;
}
fn onToplevelClose(d: ?*anyopaque, _: *wl.xdg_toplevel) callconv(.c) void {
    S(d).running = false;
}
const toplevel_listener = wl.xdg_toplevel_listener{ .configure = onToplevelConfigure, .close = onToplevelClose };

fn onPreferredScale(d: ?*anyopaque, _: *wl.wp_fractional_scale_v1, v: u32) callconv(.c) void {
    const s = S(d);
    s.fractional_120 = v;
    s.updateScale();
}
const fractional_listener = wl.wp_fractional_scale_v1_listener{ .preferred_scale = onPreferredScale };

fn onSeatCaps(d: ?*anyopaque, seat: *wl.wl_seat, caps: u32) callconv(.c) void {
    const s = S(d);
    if (caps & wl.wl_seat__capability.pointer != 0 and s.pointer == null) {
        const p = wl.wl_seat_get_pointer(seat);
        s.pointer = p;
        wl.wl_pointer_add_listener(p, &pointer_listener, s);
    }
    if (caps & wl.wl_seat__capability.keyboard != 0 and s.keyboard == null) {
        const k = wl.wl_seat_get_keyboard(seat);
        s.keyboard = k;
        wl.wl_keyboard_add_listener(k, &keyboard_listener, s);
    }
}
const seat_listener = wl.wl_seat_listener{ .capabilities = onSeatCaps };

// pointer
fn onPtrEnter(d: ?*anyopaque, _: *wl.wl_pointer, serial: u32, _: *wl.wl_surface, x: i32, y: i32) callconv(.c) void {
    const s = S(d);
    s.pointer_serial = serial;
    s.pointer_inside = true;
    s.last_serial = serial;
    s.queue.pointerMoved(client.fixedToF32(x), client.fixedToF32(y));
    s.applyCursor();
}
fn onPtrLeave(d: ?*anyopaque, _: *wl.wl_pointer, _: u32, _: *wl.wl_surface) callconv(.c) void {
    S(d).pointer_inside = false;
}
fn onPtrMotion(d: ?*anyopaque, _: *wl.wl_pointer, _: u32, x: i32, y: i32) callconv(.c) void {
    S(d).queue.pointerMoved(client.fixedToF32(x), client.fixedToF32(y));
}
fn onPtrButton(d: ?*anyopaque, _: *wl.wl_pointer, serial: u32, _: u32, code: u32, state: u32) callconv(.c) void {
    const s = S(d);
    s.last_serial = serial;
    s.button_serial = serial;
    const b = data.buttonFromCode(code) orelse return;
    if (state == wl.wl_pointer__button_state.pressed) s.queue.buttonDown(b) else s.queue.buttonUp(b);
}
fn onPtrAxis(d: ?*anyopaque, _: *wl.wl_pointer, _: u32, axis: u32, value: i32) callconv(.c) void {
    if (axis > 1) return;
    S(d).wheel.axis(@fromBackingInt(@intCast(axis)), client.fixedToF32(value));
}
fn onPtrAxis120(d: ?*anyopaque, _: *wl.wl_pointer, axis: u32, v: i32) callconv(.c) void {
    if (axis > 1) return;
    S(d).wheel.value120(@fromBackingInt(@intCast(axis)), v);
}
fn onPtrFrame(d: ?*anyopaque, _: *wl.wl_pointer) callconv(.c) void {
    const s = S(d);
    s.wheel.frame(&s.queue);
}
const pointer_listener = wl.wl_pointer_listener{
    .enter = onPtrEnter,
    .leave = onPtrLeave,
    .motion = onPtrMotion,
    .button = onPtrButton,
    .axis = onPtrAxis,
    .axis_value120 = onPtrAxis120,
    .frame = onPtrFrame,
};

// keyboard
fn onKbKeymap(d: ?*anyopaque, _: *wl.wl_keyboard, format: u32, fd: i32, size: u32) callconv(.c) void {
    const s = S(d);
    defer _ = close(fd);
    const x = s.xkb orelse return;
    if (format != wl.wl_keyboard__keymap_format.xkb_v1) return;
    const map = mmap(null, size, 1, 2, fd, 0) orelse return; // PROT_READ, MAP_PRIVATE
    if (@intFromPtr(map) == std.math.maxInt(usize)) return;
    defer _ = munmap(map, size);
    const km = x.f.keymap_new_from_string(s.xkb_ctx.?, @ptrCast(map), 1, 0) orelse return;
    const st = x.f.state_new(km) orelse {
        x.f.keymap_unref(km);
        return;
    };
    if (s.xkb_state) |o| x.f.state_unref(o);
    if (s.xkb_keymap) |o| x.f.keymap_unref(o);
    s.xkb_keymap = km;
    s.xkb_state = st;
}
fn onKbEnter(d: ?*anyopaque, _: *wl.wl_keyboard, serial: u32, _: *wl.wl_surface, _: *client.Array) callconv(.c) void {
    S(d).last_serial = serial;
}
fn onKbLeave(d: ?*anyopaque, _: *wl.wl_keyboard, _: u32, _: *wl.wl_surface) callconv(.c) void {
    S(d).repeat.active = false;
}
fn onKbKey(d: ?*anyopaque, _: *wl.wl_keyboard, serial: u32, _: u32, key: u32, state: u32) callconv(.c) void {
    const s = S(d);
    s.last_serial = serial;
    if (state == wl.wl_keyboard__key_state.pressed) s.keyPress(key, true) else s.repeat.release(key);
}
fn onKbMods(d: ?*anyopaque, _: *wl.wl_keyboard, _: u32, dep: u32, lat: u32, lock: u32, group: u32) callconv(.c) void {
    const s = S(d);
    const x = s.xkb orelse return;
    const st = s.xkb_state orelse return;
    _ = x.f.state_update_mask(st, dep, lat, lock, 0, 0, group);
    s.queue.mods = s.currentMods();
}
fn onKbRepeat(d: ?*anyopaque, _: *wl.wl_keyboard, rate: i32, delay: i32) callconv(.c) void {
    const s = S(d);
    s.repeat.rate = if (rate > 0) @intCast(rate) else 0;
    s.repeat.delay_ms = if (delay > 0) @intCast(delay) else 600;
}
const keyboard_listener = wl.wl_keyboard_listener{
    .keymap = onKbKeymap,
    .enter = onKbEnter,
    .leave = onKbLeave,
    .key = onKbKey,
    .modifiers = onKbMods,
    .repeat_info = onKbRepeat,
};

// data device
fn offerIndex(s: *State, p: ?*wl.wl_data_offer) ?usize {
    const target = p orelse return null;
    for (s.offers, 0..) |o, i| if (o.proxy == target) return i;
    return null;
}

fn onOffer(d: ?*anyopaque, _: *wl.wl_data_offer, mime: [*:0]const u8) callconv(.c) void {
    const o: *Offer = @ptrCast(@alignCast(d.?));
    o.flags.note(std.mem.span(mime));
}
const offer_listener = wl.wl_data_offer_listener{ .offer = onOffer };

fn onDataOffer(d: ?*anyopaque, _: *wl.wl_data_device, id: *wl.wl_data_offer) callconv(.c) void {
    const s = S(d);
    // A free slot; failing that, one that is neither the clipboard
    // selection nor the drag in progress.
    var slot: usize = 0;
    var found = false;
    for (s.offers, 0..) |o, i| {
        if (o.proxy == null) {
            slot = i;
            found = true;
            break;
        }
    }
    if (!found) {
        for (0..MAX_OFFERS) |i| {
            if (i != s.selection and i != s.dnd) {
                slot = i;
                break;
            }
        }
    }
    if (s.offers[slot].proxy) |old| wl.wl_data_offer_destroy(old);
    s.offers[slot] = .{ .proxy = id };
    wl.wl_data_offer_add_listener(id, &offer_listener, &s.offers[slot]);
}
fn onSelection(d: ?*anyopaque, _: *wl.wl_data_device, id: ?*wl.wl_data_offer) callconv(.c) void {
    const s = S(d);
    s.selection = offerIndex(s, id);
}
fn onDndEnter(d: ?*anyopaque, _: *wl.wl_data_device, serial: u32, _: *wl.wl_surface, _: i32, _: i32, id: ?*wl.wl_data_offer) callconv(.c) void {
    const s = S(d);
    s.dnd = offerIndex(s, id);
    const idx = s.dnd orelse return;
    const f = s.offers[idx].flags;
    const p = s.offers[idx].proxy.?;
    if (f.uri_list) {
        wl.wl_data_offer_accept(p, serial, "text/uri-list");
    } else if (f.hasText()) {
        wl.wl_data_offer_accept(p, serial, if (f.utf8) "text/plain;charset=utf-8" else "text/plain");
    } else {
        wl.wl_data_offer_accept(p, serial, null);
        return;
    }
    wl.wl_data_offer_set_actions(p, wl.wl_data_device_manager__dnd_action.copy, wl.wl_data_device_manager__dnd_action.copy);
}
fn onDndLeave(d: ?*anyopaque, _: *wl.wl_data_device) callconv(.c) void {
    S(d).dnd = null;
}
fn onDndDrop(d: ?*anyopaque, _: *wl.wl_data_device) callconv(.c) void {
    const s = S(d);
    const idx = s.dnd orelse return;
    const f = s.offers[idx].flags;
    const p = s.offers[idx].proxy.?;
    if (f.uri_list) {
        s.startTransfer(.dnd_uri, p, "text/uri-list", p);
    } else if (f.hasText()) {
        s.startTransfer(.dnd_text, p, if (f.utf8) "text/plain;charset=utf-8" else "text/plain", p);
    }
}
const data_device_listener = wl.wl_data_device_listener{
    .data_offer = onDataOffer,
    .selection = onSelection,
    .enter = onDndEnter,
    .leave = onDndLeave,
    .drop = onDndDrop,
};

// data source (our clipboard)
fn onSourceSend(d: ?*anyopaque, _: *wl.wl_data_source, _: [*:0]const u8, fd: i32) callconv(.c) void {
    const s = S(d);
    const out = s.clip_out orelse {
        _ = close(fd);
        return;
    };
    const copy = gpa.dupe(u8, out) catch {
        _ = close(fd);
        return;
    };
    // Non-blocking so a slow reader cannot stall a frame; leftovers go
    // through `pumpWrites`.
    for (&s.writes) |*slot| if (slot.* == null) {
        slot.* = .{ .fd = fd, .bytes = copy };
        s.pumpWrites();
        return;
    };
    gpa.free(copy);
    _ = close(fd);
}
fn onSourceCancelled(d: ?*anyopaque, src: *wl.wl_data_source) callconv(.c) void {
    const s = S(d);
    if (s.source == src) {
        s.source = null;
        if (s.clip_out) |b| gpa.free(b);
        s.clip_out = null;
    }
    wl.wl_data_source_destroy(src);
}
const source_listener = wl.wl_data_source_listener{ .send = onSourceSend, .cancelled = onSourceCancelled };

// text input (IME)
fn onTiEnter(d: ?*anyopaque, ti: *wl.zwp_text_input_v3, _: *wl.wl_surface) callconv(.c) void {
    const s = S(d);
    wl.zwp_text_input_v3_enable(ti);
    wl.zwp_text_input_v3_set_content_type(ti, wl.zwp_text_input_v3__content_hint.none, wl.zwp_text_input_v3__content_purpose.normal);
    wl.zwp_text_input_v3_commit(ti);
    s.ti_enabled = true;
}
fn onTiLeave(d: ?*anyopaque, ti: *wl.zwp_text_input_v3, _: *wl.wl_surface) callconv(.c) void {
    const s = S(d);
    wl.zwp_text_input_v3_disable(ti);
    wl.zwp_text_input_v3_commit(ti);
    s.ti_enabled = false;
    s.ime.done();
    s.ime_active = false;
}
fn onTiPreedit(d: ?*anyopaque, _: *wl.zwp_text_input_v3, txt: ?[*:0]const u8, begin: i32, _: i32) callconv(.c) void {
    const s = S(d);
    const t = if (txt) |p| std.mem.span(p) else "";
    s.preedit_tmp_len = @min(t.len, s.preedit_tmp.len);
    @memcpy(s.preedit_tmp[0..s.preedit_tmp_len], t[0..s.preedit_tmp_len]);
    s.preedit_cursor_tmp = if (begin < 0) s.preedit_tmp_len else @min(@as(usize, @intCast(begin)), s.preedit_tmp_len);
    s.preedit_pending = true;
}
fn onTiCommit(d: ?*anyopaque, _: *wl.zwp_text_input_v3, txt: ?[*:0]const u8) callconv(.c) void {
    const s = S(d);
    const t = if (txt) |p| std.mem.span(p) else "";
    s.commit_tmp_len = @min(t.len, s.commit_tmp.len);
    @memcpy(s.commit_tmp[0..s.commit_tmp_len], t[0..s.commit_tmp_len]);
}
fn onTiDone(d: ?*anyopaque, _: *wl.zwp_text_input_v3, serial: u32) callconv(.c) void {
    const s = S(d);
    s.ti_serial = serial;
    s.applyImeDone();
}
const text_input_listener = wl.zwp_text_input_v3_listener{
    .enter = onTiEnter,
    .leave = onTiLeave,
    .preedit_string = onTiPreedit,
    .commit_string = onTiCommit,
    .done = onTiDone,
};

// ── State methods ──────────────────────────────────────────────────

fn monotonicMs() u64 {
    return @intCast(@divFloor(std.Io.Clock.awake.now(std.Options.debug_io).nanoseconds, std.time.ns_per_ms));
}

pub const Host = struct {
    lib_loaded: bool,
    st: *State,

    pub fn init(title: []const u8, width: u32, height: u32) !Host {
        client.load() catch return error.WaylandLoadFailed;
        // A clipboard reader that quits mid-transfer must not kill us.
        _ = signal(13, @ptrFromInt(1)); // SIGPIPE -> SIG_IGN
        const display = client.api.display_connect(null) orelse return error.WaylandConnectFailed;
        errdefer client.api.display_disconnect(display);

        const effects = try native_effects.Service.create(title);
        errdefer effects.destroy();

        const s = try gpa.create(State);
        errdefer gpa.destroy(s);
        const registry = wl.wl_display_get_registry(@ptrCast(display));
        s.* = .{
            .xkb = Xkb.load(),
            .cursor_lib = CursorLib.load(),
            .display = display,
            .registry = registry,
            .width = width,
            .height = height,
            .effects = effects,
            .scale_env = envScale(),
        };
        if (s.xkb) |x| s.xkb_ctx = x.f.context_new(0);
        wl.wl_registry_add_listener(registry, &registry_listener, s);
        _ = client.api.display_roundtrip(display);
        if (s.compositor == null or s.wm_base == null) return error.WaylandMissingGlobals;
        wl.xdg_wm_base_add_listener(s.wm_base.?, &wm_base_listener, s);

        if (s.seat) |seat| {
            wl.wl_seat_add_listener(seat, &seat_listener, s);
            if (s.data_mgr) |mgr| {
                const dd = wl.wl_data_device_manager_get_data_device(mgr, seat);
                s.data_device = dd;
                wl.wl_data_device_add_listener(dd, &data_device_listener, s);
            }
            if (s.text_input_mgr) |mgr| {
                const ti = wl.zwp_text_input_manager_v3_get_text_input(mgr, seat);
                s.text_input = ti;
                wl.zwp_text_input_v3_add_listener(ti, &text_input_listener, s);
            }
        }

        // The window.
        s.surface = wl.wl_compositor_create_surface(s.compositor.?);
        s.xdg_surface = wl.xdg_wm_base_get_xdg_surface(s.wm_base.?, s.surface);
        wl.xdg_surface_add_listener(s.xdg_surface, &xdg_surface_listener, s);
        s.toplevel = wl.xdg_surface_get_toplevel(s.xdg_surface);
        wl.xdg_toplevel_add_listener(s.toplevel, &toplevel_listener, s);
        s.setTitleZ(title);
        wl.xdg_toplevel_set_app_id(s.toplevel, "teak");
        if (s.decoration_mgr) |mgr| {
            const dec = wl.zxdg_decoration_manager_v1_get_toplevel_decoration(mgr, s.toplevel);
            s.decoration = dec;
            wl.zxdg_toplevel_decoration_v1_set_mode(dec, wl.zxdg_toplevel_decoration_v1__mode.server_side);
        }
        if (s.fractional_mgr) |mgr| {
            const f = wl.wp_fractional_scale_manager_v1_get_fractional_scale(mgr, s.surface);
            s.fractional = f;
            wl.wp_fractional_scale_v1_add_listener(f, &fractional_listener, s);
        }
        // TEAK_WL_NO_VIEWPORT=1 forces the integer `set_buffer_scale` path
        // (debugging compositors with a misbehaving wp_viewporter).
        if (s.viewporter) |vp| {
            if (std.c.getenv("TEAK_WL_NO_VIEWPORT") == null) s.viewport = wl.wp_viewporter_get_viewport(vp, s.surface);
        }
        wl.wl_surface_commit(s.surface);

        // Wait for the first configure (and the scale announcements).
        var tries: u32 = 0;
        while (!s.configured and tries < 50) : (tries += 1) _ = client.api.display_roundtrip(display);
        if (!s.configured) return error.WaylandNoConfigure;
        _ = client.api.display_roundtrip(display);
        s.updateScale();
        s.initCursor();
        s.now_ms = monotonicMs();
        return .{ .lib_loaded = true, .st = s };
    }

    pub fn deinit(self: *Host) void {
        const s = self.st;
        text.releaseFaces();
        s.abortTransfer();
        for (&s.writes) |*w| if (w.*) |j| {
            _ = close(j.fd);
            gpa.free(j.bytes);
            w.* = null;
        };
        if (s.clip_out) |b| gpa.free(b);
        if (s.read_buf) |b| gpa.free(b);
        s.effects.destroy();
        if (s.xkb) |*x| {
            if (s.xkb_state) |o| x.f.state_unref(o);
            if (s.xkb_keymap) |o| x.f.keymap_unref(o);
            if (s.xkb_ctx) |o| x.f.context_unref(o);
            x.lib.close();
        }
        client.api.display_disconnect(s.display);
        if (s.cursor_lib) |*c| c.lib.close();
        gpa.destroy(s);
    }

    /// Drain the connection without blocking and fold events into the input
    /// queue. Returns the per-frame snapshot.
    pub fn pollInputs(self: *Host) InputState {
        const s = self.st;
        const q = &s.queue;
        q.beginFrame();
        s.paste_requested = false;
        s.now_ms = monotonicMs();
        s.expireTransfer();
        s.pumpEvents();
        s.pumpWrites();
        s.progressTransfer();
        const n = s.repeat.due(s.now_ms);
        if (n > 0 and s.xkb_state != null) {
            var i: u32 = 0;
            while (i < n) : (i += 1) s.keyPress(s.repeat.key, false);
        }
        if (client.api.display_get_error(s.display) != 0) s.running = false;

        const resized = s.resized_pending or s.first_resize;
        s.first_resize = false;
        s.resized_pending = false;
        return q.finish(resized, s.width, s.height);
    }

    pub fn shouldClose(self: *const Host) bool {
        return !self.st.running;
    }

    pub const NativeHandle = struct { display: *anyopaque, surface: *anyopaque };

    pub fn nativeHandle(self: *const Host) NativeHandle {
        return .{ .display = @ptrCast(self.st.display), .surface = @ptrCast(self.st.surface) };
    }

    pub fn setTitle(self: *Host, title: []const u8) void {
        self.st.setTitleZ(title);
        _ = client.api.display_flush(self.st.display);
    }

    pub fn textMeasurer(self: *Host) TextMeasurer {
        return .{ .ctx = @ptrCast(self), .measure_fn = stbMeasure };
    }

    fn stbMeasure(_: *anyopaque, text_bytes: []const u8, font: FontSpec) TextMetrics {
        return text.measure(text_bytes, font);
    }

    // ── Effects ─────────────────────────────────────────────────────

    pub fn submit(self: *Host, e: teak.Effect) teak.EffectSubmit {
        switch (e) {
            .write_clipboard => |w| {
                self.st.writeClipboard(w.text);
                return .accepted;
            },
            else => return self.st.effects.submit(e),
        }
    }

    pub fn pollEffectResults(self: *Host, buf: []teak.EffectResult) usize {
        const s = self.st;
        // Ctrl+V that `Clipboard.read` did not claim: start an async paste.
        if (s.paste_requested) {
            s.paste_requested = false;
            s.startPaste();
        }
        return s.effects.poll(buf, self.nowMs());
    }

    pub fn setAppName(self: *Host, name: []const u8) void {
        self.st.effects.setAppName(name) catch {};
    }

    pub fn registerFont(_: *Host, family: teak.FontFamily, weight: teak.FontWeight, ttf: []const u8) !void {
        try text.registerFace(family, weight, ttf);
    }

    /// The clipboard: `write` owns the selection through a `wl_data_source`;
    /// `read` returns our own text or does a bounded (250 ms) pipe read from
    /// the current offer ("" on timeout, empty or non-text clipboards).
    pub fn clipboard(self: *Host) Clipboard {
        return .{ .ctx = @ptrCast(self), .read_fn = clipRead, .write_fn = clipWrite };
    }

    fn clipRead(ctx: *anyopaque) []const u8 {
        const self: *Host = @ptrCast(@alignCast(ctx));
        return self.st.syncRead();
    }

    fn clipWrite(ctx: *anyopaque, txt: []const u8) void {
        const self: *Host = @ptrCast(@alignCast(ctx));
        self.st.writeClipboard(txt);
    }

    /// Input-method composition (zwp_text_input_v3 preedit).
    pub fn imeState(self: *const Host) ImeState {
        const s = self.st;
        if (!s.ime_active) return .{};
        return .{ .active = true, .text = s.ime_buf[0..s.ime_len], .cursor = s.ime_cursor };
    }

    /// Tell the input method where the caret is (window-relative logical
    /// pixels) so it can place its candidate window.
    pub fn setImeSpot(self: *Host, spot_x: i32, spot_y: i32) void {
        const ti = self.st.text_input orelse return;
        if (!self.st.ti_enabled) return;
        wl.zwp_text_input_v3_set_cursor_rectangle(ti, spot_x, spot_y, 1, 16);
        wl.zwp_text_input_v3_commit(ti);
        _ = client.api.display_flush(self.st.display);
    }

    pub fn publishA11yTree(_: *Host, _: []const A11yNode) void {}

    pub fn openFileDialog(_: *Host, _: FileDialogFilter) FileDialogResult {
        return null;
    }

    pub fn saveFileDialog(_: *Host, _: FileDialogFilter) FileDialogResult {
        return null;
    }

    pub fn openSecondaryWindow(_: *Host, _: []const u8, _: u32, _: u32) ?u32 {
        return null;
    }

    pub fn pollSecondaryInputs(_: *Host, _: u32) ?InputState {
        return null;
    }

    pub fn closeSecondaryWindow(_: *Host, _: u32) void {}

    pub fn secondaryWindowHandle(_: *const Host, _: u32) ?NativeHandle {
        return null;
    }

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
        return monotonicMs();
    }

    /// Device pixels per logical unit: `TEAK_SCALE`, else the compositor's
    /// fractional scale, else the integer `wl_output` scale.
    pub fn scaleFactor(self: *const Host) f32 {
        return self.st.scale;
    }

    /// Map the window with a solid-colour `wl_shm` buffer of the current
    /// logical size. A Wayland toplevel only becomes visible (and can take
    /// pointer / keyboard focus) once a buffer is attached; the GPU backend
    /// does that on its first present, so this exists for display-only
    /// hosts and tests that never render. Not for use alongside a Gpu.
    pub fn mapWithShmBuffer(self: *Host) !void {
        const s = self.st;
        const shm = s.shm orelse return error.NoShm;
        const w: i32 = @intCast(s.width);
        const h: i32 = @intCast(s.height);
        const size: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
        const fd = memfd_create("teak-shm", 1); // MFD_CLOEXEC
        if (fd < 0) return error.MemfdFailed;
        defer _ = close(fd);
        if (ftruncate(fd, @intCast(size)) != 0) return error.MemfdFailed;
        const map = mmap(null, size, 3, 1, fd, 0) orelse return error.MmapFailed; // RW, SHARED
        if (@intFromPtr(map) == std.math.maxInt(usize)) return error.MmapFailed;
        @memset(@as([*]u8, @ptrCast(map))[0..size], 0x40);
        _ = munmap(map, size);
        const pool = wl.wl_shm_create_pool(shm, fd, @intCast(size));
        defer wl.wl_shm_pool_destroy(pool);
        const buf = wl.wl_shm_pool_create_buffer(pool, 0, w, h, w * 4, wl.wl_shm__format.xrgb8888);
        wl.wl_surface_attach(s.surface, buf, 0, 0);
        wl.wl_surface_damage(s.surface, 0, 0, w, h);
        wl.wl_surface_commit(s.surface);
        _ = client.api.display_roundtrip(s.display);
    }

    pub fn setCursor(self: *Host, shape: teak.CursorShape) void {
        self.st.cursor_shape = shape;
        self.st.applyCursor();
    }
};

fn envScale() ?f32 {
    const v = std.c.getenv("TEAK_SCALE") orelse return null;
    const f = std.fmt.parseFloat(f32, std.mem.span(v)) catch return null;
    return if (f >= 0.5 and f <= 8) f else null;
}

comptime {
    teak.validateHost(Host);
}

test "cursor names are non-empty for every shape" {
    for (std.enums.values(teak.CursorShape)) |sh| {
        const n = cursorNames(sh);
        try std.testing.expect(n[0].len > 0 and n[1].len > 0);
    }
}
