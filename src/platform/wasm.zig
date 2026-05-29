//! Wasm host backed by zunk's `web.input` + `web.app` modules. Zunk
//! owns the rAF loop; `pollInputs` snapshots zunk's shared-memory
//! state into teak's `InputState`.
//!
//! Mouse `mouse_down`/`mouse_up` are derived locally from diffs of the
//! button state because zunk reports held-state, not edges.
//!
//! All pointer + viewport coords are CSS pixels (zunk v0.5.2+).

const std = @import("std");
const teak = @import("teak");
const zunk = @import("zunk");

const zinput = zunk.web.input;
const zapp = zunk.web.app;
const zgpu = zunk.web.gpu;

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

pub const NativeHandle = struct {};

const MEASURE_CACHE_CAPACITY: usize = 128;

const MeasureCacheEntry = struct {
    content_hash: u64,
    content_len: u32,
    size_px: u16,
    family: FontFamily,
    metrics: TextMetrics,
    last_used: u64,
};

// Delete/Home/End are absent from zunk.web.input.Key; tracked in
// docs/zunk-handoff.md as a follow-up ask.
const key_mappings = [_]struct { from: zinput.Key, to: SpecialKey }{
    .{ .from = .backspace, .to = .backspace },
    .{ .from = .enter, .to = .enter },
    .{ .from = .tab, .to = .tab },
    .{ .from = .escape, .to = .escape },
    .{ .from = .arrow_left, .to = .left },
    .{ .from = .arrow_right, .to = .right },
    .{ .from = .arrow_up, .to = .up },
    .{ .from = .arrow_down, .to = .down },
    .{ .from = .page_up, .to = .page_up },
    .{ .from = .page_down, .to = .page_down },
};

/// Async file-dialog slot state. Matches the Win32 slot table's
/// semantics but with explicit `pending` since the wasm side genuinely
/// waits on a browser promise resolution.
const FileDialogSlotState = enum { free, pending, resolved_ok, resolved_cancelled };

const FileDialogSlot = struct {
    state: FileDialogSlotState = .free,
    path_buf: [1024]u8 = undefined,
    path_len: u32 = 0,
};

const MAX_FILE_DIALOG_SLOTS: usize = 4;

// ── A11y DOM-mirror wire format ────────────────────────────────────
//
// `publishA11yTree` ships the per-frame a11y snapshot to the JS side
// over two parallel buffers: a fixed-stride record array (one record
// per node) and a UTF-8 string heap that holds every label back-to-
// back. The JS shim deserializes both, diffs against last frame, and
// updates a hidden DOM subtree so NVDA/JAWS/VoiceOver can announce
// canvas-rendered widgets.
//
// Per-node record layout (little-endian, native Zig packing —
// `A11yRecord` is `extern struct` so its layout is fixed):
//
//   offset  size  field
//        0     4  cmd_index      u32  index into the source Cmd buffer
//        4     4  role           u32  enum tag, 0..11 (see a11y.Role)
//        8     4  label_offset   u32  byte offset into the string heap
//       12     4  label_len      u32  label length in bytes
//       16     4  bounds_x       i32  rounded pixel x
//       20     4  bounds_y       i32  rounded pixel y
//       24     4  bounds_w       i32  rounded pixel width
//       28     4  bounds_h       i32  rounded pixel height
//       32     4  state          f32  checkbox/radio checked (0/1),
//                                       slider value [0, 1]
//       36     4  flags          u32  bit 0 = focused
//   total: 40 bytes
//
// Fixed-size buffers (rather than an arena/general-purpose allocator)
// because wasm-freestanding has no default heap, the wasm side is
// single-threaded, and JS reads the buffers synchronously inside the
// extern call — the next publish-tree call can safely overwrite them.
// Tunables are bounded to keep wasm size down: 256 nodes × 40 bytes
// = 10 KB for records, 8 KB string heap. A 256-node frame already
// exceeds anything a human screen-reader user would meaningfully
// navigate; nodes past the cap are silently dropped.
//
// JS shim behavior (separate zunk issue tracks the bridge):
//   * Maintain a single off-screen container element with ARIA
//     mirrors for each record.
//   * Map `role` → ARIA role + apply label / state attributes.
//   * Diff against the previous frame; add/update/remove DOM nodes.
//   * If the shim is absent from the build, the extern resolves
//     away (see `@hasDecl` gate in `publishA11yTree`) and the call
//     becomes a build-time no-op.
//
// Buffer lifetime: the byte ranges passed to the extern are stable
// for the duration of that call only. JS must copy any bytes it
// wants to retain — the buffers are overwritten on the next frame.

const MAX_A11Y_NODES: usize = 256;
const A11Y_STRING_HEAP_BYTES: usize = 8 * 1024;
const A11Y_RECORD_BYTES: usize = 40;

/// One serialized a11y node. `extern struct` pins the field layout so
/// the JS side can decode by raw offsets without paying for any
/// per-field marshalling.
const A11yRecord = extern struct {
    cmd_index: u32,
    role: u32,
    label_offset: u32,
    label_len: u32,
    bounds_x: i32,
    bounds_y: i32,
    bounds_w: i32,
    bounds_h: i32,
    state: f32,
    flags: u32,

    comptime {
        if (@sizeOf(A11yRecord) != A11Y_RECORD_BYTES) {
            @compileError("A11yRecord size drifted from documented wire format");
        }
    }
};

/// Bit positions for `A11yRecord.flags`. Keep the table in sync with
/// the JS shim — adding a bit is a wire-format change.
const A11Y_FLAG_FOCUSED: u32 = 1 << 0;

// Module-scoped backing store for the two wire buffers. Single-host
// wasm process — one publish-tree call at a time, single-threaded,
// reused every frame. Zero per-frame allocation.
var g_a11y_records: [MAX_A11Y_NODES * A11Y_RECORD_BYTES]u8 align(@alignOf(A11yRecord)) = undefined;
var g_a11y_strings: [A11Y_STRING_HEAP_BYTES]u8 = undefined;

/// Serialize an A11yNode slice into the module-scoped record + string
/// buffers and return the byte lengths actually written. Pure helper —
/// no zunk / JS calls — so tests can exercise it in isolation.
///
/// Truncation rules:
///   * Drops nodes past `MAX_A11Y_NODES`.
///   * Drops labels whose bytes wouldn't fit in the remaining string
///     heap (record is still written with `label_len = 0` so the node
///     itself stays announceable, just unlabeled).
fn serializeA11yTree(nodes: []const A11yNode) struct { records_len: u32, strings_len: u32 } {
    const count = @min(nodes.len, MAX_A11Y_NODES);
    var strings_used: u32 = 0;

    // Records and strings live in parallel buffers — write one record
    // per node, append the label bytes to the heap, and record the
    // offset+len so JS can slice them back out.
    const records: [*]A11yRecord = @ptrCast(&g_a11y_records);
    for (nodes[0..count], 0..) |node, i| {
        const label_len_u32: u32 = @intCast(node.label.len);
        const remaining: u32 = @intCast(A11Y_STRING_HEAP_BYTES - strings_used);
        var label_offset: u32 = 0;
        var label_len: u32 = 0;
        if (label_len_u32 > 0 and label_len_u32 <= remaining) {
            label_offset = strings_used;
            label_len = label_len_u32;
            @memcpy(g_a11y_strings[strings_used..][0..label_len_u32], node.label);
            strings_used += label_len_u32;
        }

        var flags: u32 = 0;
        if (node.focused) flags |= A11Y_FLAG_FOCUSED;

        records[i] = .{
            .cmd_index = node.cmd_index,
            .role = @intFromEnum(node.role),
            .label_offset = label_offset,
            .label_len = label_len,
            .bounds_x = @intFromFloat(@round(node.bounds.x)),
            .bounds_y = @intFromFloat(@round(node.bounds.y)),
            .bounds_w = @intFromFloat(@round(node.bounds.w)),
            .bounds_h = @intFromFloat(@round(node.bounds.h)),
            .state = node.state,
            .flags = flags,
        };
    }

    const records_bytes: u32 = @intCast(count * A11Y_RECORD_BYTES);
    return .{ .records_len = records_bytes, .strings_len = strings_used };
}

/// JS-side imports (wired by zunk's resolver — see zunk issue #14 for
/// the file-dialog shim and zunk issue #15 for the a11y DOM mirror).
/// Stays in a sub-namespace so `@hasDecl` callers can short-circuit
/// cleanly when a symbol isn't resolved yet (browser builds where
/// zunk's bridge hasn't shipped).
const externs = struct {
    extern "env" fn __zunk_request_file_dialog(
        id: u32,
        mode: u32,
        name_ptr: [*]const u8,
        name_len: u32,
        pattern_ptr: [*]const u8,
        pattern_len: u32,
    ) void;

    extern "env" fn __zunk_publish_a11y_tree(
        records_ptr: [*]const u8,
        records_len: u32,
        strings_ptr: [*]const u8,
        strings_len: u32,
    ) void;
};

/// Pointer to the live Host so the wasm export callback can write the
/// dialog result into the right slot table. Set by `Host.init`, cleared
/// by `Host.deinit`. Single-host process — single global is sufficient.
var g_active_host: ?*Host = null;

pub const Host = struct {
    width: u32,
    height: u32,
    prev_left: bool = false,
    first_poll: bool = true,
    keys_buf: [16]SpecialKey = undefined,
    keys_len: usize = 0,
    chars_buf: [32]u8 = undefined,
    chars_len: usize = 0,
    measure_cache: [MEASURE_CACHE_CAPACITY]MeasureCacheEntry = undefined,
    measure_cache_len: usize = 0,
    measure_tick: u64 = 0,
    file_dialog_slots: [MAX_FILE_DIALOG_SLOTS]FileDialogSlot = @splat(.{}),

    pub fn init(title: []const u8, width: u32, height: u32) !Host {
        zinput.init();
        zapp.setTitle(title);
        return .{ .width = width, .height = height };
    }

    /// Register the address of an initialized Host so the wasm export
    /// callback can find it. Apps should call this once after `init`.
    /// Single-host process — re-registering overrides the previous.
    pub fn activate(self: *Host) void {
        g_active_host = self;
    }

    pub fn deinit(_: *Host) void {
        g_active_host = null;
    }

    pub fn pollInputs(self: *Host) InputState {
        zinput.poll();

        const mouse = zinput.getMouse();
        const cur_left = mouse.buttons.left;
        const mouse_down = !self.prev_left and cur_left;
        const mouse_up = self.prev_left and !cur_left;
        self.prev_left = cur_left;

        self.keys_len = 0;
        for (key_mappings) |m| {
            if (self.keys_len >= self.keys_buf.len) break;
            if (zinput.isKeyPressed(m.from)) {
                self.keys_buf[self.keys_len] = m.to;
                self.keys_len += 1;
            }
        }

        // Zunk pushes Backspace (8) and Enter (10) into typed_chars in
        // addition to reporting them as pressed keys. Without this filter,
        // backspace double-acts: it inserts char 8 then deletes one, and the
        // user sees nothing change. Drop ASCII control codes here — the
        // special-key path owns those events. Tracked upstream at
        // https://github.com/hotschmoe/zunk/issues/8.
        self.chars_len = 0;
        for (zinput.getTypedChars()) |c| {
            if (c < 0x20 or c == 0x7f) continue;
            if (self.chars_len >= self.chars_buf.len) break;
            self.chars_buf[self.chars_len] = c;
            self.chars_len += 1;
        }

        const vp = zinput.getViewportSize();
        const w = if (vp.w != 0) vp.w else self.width;
        const h = if (vp.h != 0) vp.h else self.height;
        const resized = self.first_poll or w != self.width or h != self.height;
        self.first_poll = false;
        self.width = w;
        self.height = h;

        // Zunk exposes a single `mouse.wheel` accumulator (vertical
        // only) in CSS pixels with deltaMode=0 — positive = scroll
        // down, matching the InputState convention. No horizontal-
        // wheel API today; tracked as a follow-up ask alongside the
        // other zunk gaps in docs/zunk-handoff.md.
        // TODO: zunk horizontal wheel events.
        const wheel_dy = mouse.wheel;
        const wheel_dx: f32 = 0;

        return .{
            .mouse_x = mouse.x,
            .mouse_y = mouse.y,
            .mouse_down = mouse_down,
            .mouse_up = mouse_up,
            .wheel_dx = wheel_dx,
            .wheel_dy = wheel_dy,
            .chars = self.chars_buf[0..self.chars_len],
            .keys = self.keys_buf[0..self.keys_len],
            .resized = resized,
            .width = w,
            .height = h,
        };
    }

    pub fn shouldClose(_: *const Host) bool {
        return false;
    }

    pub fn nativeHandle(_: *const Host) NativeHandle {
        return .{};
    }

    /// Measures via canvas 2D through `zunk.web.gpu.measureText`. Results
    /// are cached by (content_hash, size, family) because every
    /// measurement pays a wasm↔JS round-trip. Zunk's `TextMetrics`
    /// carries only width/height; ascent/descent are synthesized with
    /// the same 0.75/0.25 split `teak.monoMeasurer` uses.
    pub fn textMeasurer(self: *Host) TextMeasurer {
        return .{ .ctx = @ptrCast(self), .measure_fn = zunkMeasure };
    }

    fn zunkMeasure(ctx: *anyopaque, text_bytes: []const u8, font: FontSpec) TextMetrics {
        const self: *Host = @ptrCast(@alignCast(ctx));
        self.measure_tick += 1;
        const size_px: u16 = @intFromFloat(font.size_px);
        const content_hash = std.hash.Wyhash.hash(0, text_bytes);

        for (self.measure_cache[0..self.measure_cache_len]) |*e| {
            if (e.content_hash == content_hash and
                e.content_len == text_bytes.len and
                e.size_px == size_px and
                e.family == font.family)
            {
                e.last_used = self.measure_tick;
                return e.metrics;
            }
        }

        var font_buf: [32]u8 = undefined;
        const css = std.fmt.bufPrint(&font_buf, "{d}px {s}", .{
            size_px,
            cssFontFamily(font.family),
        }) catch return fallbackMetrics(font);

        const raw = zgpu.measureText(text_bytes, css);
        // Canvas `measureText` returns glyph-tight height
        // (actualBoundingBoxAscent + Descent), which varies per string —
        // "hello" is shorter than "helloy". Native returns font-scope
        // `tm.tmHeight` so every label sits on the same baseline.
        // Stabilize the web side with an em-plus-leading approximation;
        // rasterize-side em still fits because canvas `textBaseline='top'`
        // draws em-top at y=0 and 1.2× em leaves room for descenders.
        const stable_h = @ceil(font.size_px * 1.2);
        const metrics: TextMetrics = .{
            .width = @floatFromInt(raw.width),
            .height = stable_h,
            .ascent = font.size_px * 0.75,
            .descent = font.size_px * 0.25,
        };

        const slot = if (self.measure_cache_len < self.measure_cache.len) blk: {
            const i = self.measure_cache_len;
            self.measure_cache_len += 1;
            break :blk i;
        } else blk: {
            var oldest: usize = 0;
            var oldest_tick: u64 = self.measure_cache[0].last_used;
            for (self.measure_cache[0..self.measure_cache_len], 0..) |*e, i| {
                if (e.last_used < oldest_tick) {
                    oldest = i;
                    oldest_tick = e.last_used;
                }
            }
            break :blk oldest;
        };

        self.measure_cache[slot] = .{
            .content_hash = content_hash,
            .content_len = @intCast(text_bytes.len),
            .size_px = size_px,
            .family = font.family,
            .metrics = metrics,
            .last_used = self.measure_tick,
        };
        return metrics;
    }

    fn fallbackMetrics(font: FontSpec) TextMetrics {
        return .{
            .width = 0,
            .height = font.size_px,
            .ascent = font.size_px * 0.75,
            .descent = font.size_px * 0.25,
        };
    }

    // ── Clipboard + IME (stubs; web backend not yet wired) ─────────
    //
    // Browser clipboard requires async navigator.clipboard.* + a user
    // gesture, which doesn't fit the synchronous Clipboard.read shape
    // without a JS-side cache. Stubbed to satisfy validateHost; the
    // contract is honored (no crashes, sane no-op).
    pub fn clipboard(_: *Host) Clipboard {
        return .{ .ctx = undefined, .read_fn = stubRead, .write_fn = stubWrite };
    }

    pub fn imeState(_: *const Host) ImeState {
        return .{};
    }

    /// Serialize the per-frame a11y tree into the module-scoped wire
    /// buffers and hand the byte ranges to the JS shim. The shim
    /// mirrors the tree as hidden DOM elements with ARIA roles so
    /// NVDA/JAWS/VoiceOver can announce widgets rendered to the
    /// `<canvas>` by wgpu. See the `A11yRecord` doc block above for
    /// the wire format.
    ///
    /// When the JS shim isn't linked into the page (early consumers,
    /// pre-bridge zunk builds), the `__zunk_publish_a11y_tree` symbol
    /// resolves away at compile time and this becomes a serialize-
    /// then-no-op — the canary `zig build test-wasm` still passes
    /// without the JS half landing.
    ///
    /// Buffer lifetime: the records/strings byte ranges are stable
    /// for the duration of the extern call only and are overwritten
    /// on the next frame. The JS shim must copy anything it needs to
    /// retain into the DOM synchronously before returning.
    pub fn publishA11yTree(_: *Host, nodes: []const A11yNode) void {
        const lens = serializeA11yTree(nodes);
        if (comptime @hasDecl(externs, "__zunk_publish_a11y_tree")) {
            externs.__zunk_publish_a11y_tree(
                &g_a11y_records,
                lens.records_len,
                &g_a11y_strings,
                lens.strings_len,
            );
        }
    }

    // Browser file dialogs go through the showOpenFilePicker API which
    // is async and gesture-gated — incompatible with the synchronous
    // `openFileDialog` shape. The sync variants stay no-op; apps that
    // need cross-platform file picking should use the async
    // `requestFileDialog` / `pollFileDialogResult` pair below.
    pub fn openFileDialog(_: *Host, _: FileDialogFilter) FileDialogResult {
        return null;
    }

    pub fn saveFileDialog(_: *Host, _: FileDialogFilter) FileDialogResult {
        return null;
    }

    /// Submit an async open-file request. Bridges to the JS shim
    /// `__zunk_request_file_dialog` (tracked in zunk issue #14). Returns
    /// the request id; the app polls `pollFileDialogResult(id)` each
    /// frame (or via a Sub) until it resolves. While the JS bridge is
    /// pending in zunk, this routes through a slot table that stays
    /// in `.pending` forever — the surface contract is honored so the
    /// example compiles and runs cleanly.
    pub fn requestFileDialog(self: *Host, filter: FileDialogFilter) u32 {
        return submitFileDialog(self, filter, 0);
    }

    pub fn requestSaveFileDialog(self: *Host, filter: FileDialogFilter) u32 {
        return submitFileDialog(self, filter, 1);
    }

    pub fn pollFileDialogResult(self: *Host, id: u32) FileDialogPoll {
        if (id == 0 or id > self.file_dialog_slots.len) return .{ .pending = {} };
        const slot = &self.file_dialog_slots[id - 1];
        return switch (slot.state) {
            .free => .{ .pending = {} },
            .pending => .{ .pending = {} },
            .resolved_ok => blk: {
                const path = slot.path_buf[0..slot.path_len];
                slot.state = .free;
                slot.path_len = 0;
                break :blk .{ .ok = path };
            },
            .resolved_cancelled => blk: {
                slot.state = .free;
                break :blk .{ .cancelled = {} };
            },
        };
    }

    fn submitFileDialog(self: *Host, filter: FileDialogFilter, mode: u32) u32 {
        var slot_idx: usize = self.file_dialog_slots.len;
        for (&self.file_dialog_slots, 0..) |*s, i| {
            if (s.state == .free) {
                slot_idx = i;
                break;
            }
        }
        if (slot_idx == self.file_dialog_slots.len) return 0;
        self.file_dialog_slots[slot_idx].state = .pending;
        self.file_dialog_slots[slot_idx].path_len = 0;
        const id: u32 = @intCast(slot_idx + 1);
        // Best-effort dispatch. If zunk hasn't wired the JS shim yet,
        // the request just stays `.pending` forever (apps treat that
        // as "no file picker available on this host").
        if (@hasDecl(externs, "__zunk_request_file_dialog")) {
            externs.__zunk_request_file_dialog(
                id,
                mode,
                filter.name.ptr,
                @intCast(filter.name.len),
                filter.pattern.ptr,
                @intCast(filter.pattern.len),
            );
        }
        return id;
    }

    /// JS-side callback: invoked by zunk's runtime when the browser
    /// promise resolves (or rejects via user-cancel). `path_len == 0`
    /// signals a cancel. The exported name is `__zunk_file_dialog_result`
    /// — must match the symbol zunk's JS shim looks up.
    pub export fn __zunk_file_dialog_result(id: u32, path_ptr: [*]const u8, path_len: u32) void {
        if (id == 0 or id > g_active_host.?.file_dialog_slots.len) return;
        const slot = &g_active_host.?.file_dialog_slots[id - 1];
        if (slot.state != .pending) return;
        if (path_len == 0) {
            slot.state = .resolved_cancelled;
            slot.path_len = 0;
            return;
        }
        const cap: u32 = @intCast(slot.path_buf.len);
        const copy_len: u32 = @min(path_len, cap);
        @memcpy(slot.path_buf[0..copy_len], path_ptr[0..copy_len]);
        slot.path_len = copy_len;
        slot.state = .resolved_ok;
    }

    /// Web has no concept of a second top-level window (popup blockers
    /// killed window.open) — apps that want multi-pane on the web use
    /// overlays. Stub returns null.
    pub fn openSecondaryWindow(_: *Host, _: []const u8, _: u32, _: u32) ?u32 {
        return null;
    }

    /// Web is always single-window — there is no secondary input queue
    /// to drain. Returns null so callers can short-circuit cleanly.
    pub fn pollSecondaryInputs(_: *Host, _: u32) ?InputState {
        return null;
    }

    /// No-op: there are no secondary windows on the web host.
    pub fn closeSecondaryWindow(_: *Host, _: u32) void {}

    /// No secondary windows -> no handles to hand out.
    pub fn secondaryWindowHandle(_: *const Host, _: u32) ?NativeHandle {
        return null;
    }

    /// Update the browser tab title via zunk (sets `document.title`).
    /// Same call `init` uses for the initial title.
    pub fn setTitle(_: *Host, title: []const u8) void {
        zapp.setTitle(title);
    }

    /// Browser monotonic time. Goes through zunk which calls
    /// performance.now() under the hood; if that's not yet wired,
    /// falls back to 0 (subs degrade gracefully — `every` never fires).
    pub fn nowMs(self: *const Host) u64 {
        _ = self;
        // zunk.web.app exposes a frame timestamp; if not, return 0.
        if (@hasDecl(zapp, "nowMs")) return zapp.nowMs();
        return 0;
    }

    fn stubRead(_: *anyopaque) []const u8 {
        return "";
    }

    fn stubWrite(_: *anyopaque, _: []const u8) void {}
};

fn cssFontFamily(family: FontFamily) []const u8 {
    return switch (family) {
        .sans => "sans-serif",
        .serif => "serif",
        .mono => "monospace",
    };
}

comptime {
    teak.validateHost(Host);
}

// ── Tests ──────────────────────────────────────────────────────────
//
// These tests exercise the pure serialization helper
// (`serializeA11yTree`) without touching the JS bridge. Wired into
// `zig build test` via the `platform-wasm` test target — the tests
// reference only the helper, so zunk's `extern "env"` declarations
// stay un-instantiated and the host-target compile links cleanly
// without a wasm runtime.

test "serializeA11yTree: layout matches wire format" {
    const testing = std.testing;

    const nodes = [_]A11yNode{
        .{
            .role = .button,
            .cmd_index = 7,
            .bounds = .{ .x = 10, .y = 20, .w = 100, .h = 30 },
            .label = "Save",
            .focused = true,
        },
        .{
            .role = .checkbox,
            .cmd_index = 9,
            .bounds = .{ .x = 0, .y = 50, .w = 80, .h = 20 },
            .label = "Agree",
            .state = 1.0,
        },
    };

    const lens = serializeA11yTree(&nodes);

    try testing.expectEqual(@as(u32, 2 * A11Y_RECORD_BYTES), lens.records_len);
    try testing.expectEqual(@as(u32, "Save".len + "Agree".len), lens.strings_len);

    const records: [*]const A11yRecord = @ptrCast(&g_a11y_records);

    // Record 0: focused button.
    try testing.expectEqual(@as(u32, 7), records[0].cmd_index);
    try testing.expectEqual(@as(u32, @intFromEnum(teak.A11yRole.button)), records[0].role);
    try testing.expectEqual(@as(u32, 0), records[0].label_offset);
    try testing.expectEqual(@as(u32, 4), records[0].label_len);
    try testing.expectEqual(@as(i32, 10), records[0].bounds_x);
    try testing.expectEqual(@as(i32, 20), records[0].bounds_y);
    try testing.expectEqual(@as(i32, 100), records[0].bounds_w);
    try testing.expectEqual(@as(i32, 30), records[0].bounds_h);
    try testing.expectEqual(A11Y_FLAG_FOCUSED, records[0].flags & A11Y_FLAG_FOCUSED);

    // Record 1: checked, non-focused checkbox stacked after.
    try testing.expectEqual(@as(u32, 9), records[1].cmd_index);
    try testing.expectEqual(@as(u32, @intFromEnum(teak.A11yRole.checkbox)), records[1].role);
    try testing.expectEqual(@as(u32, 4), records[1].label_offset);
    try testing.expectEqual(@as(u32, 5), records[1].label_len);
    try testing.expectEqual(@as(f32, 1.0), records[1].state);
    try testing.expectEqual(@as(u32, 0), records[1].flags & A11Y_FLAG_FOCUSED);

    // String heap holds the labels back-to-back at the recorded offsets.
    try testing.expectEqualStrings("Save", g_a11y_strings[0..4]);
    try testing.expectEqualStrings("Agree", g_a11y_strings[4..9]);
}

test "serializeA11yTree: drops nodes past MAX_A11Y_NODES" {
    const testing = std.testing;

    var nodes: [MAX_A11Y_NODES + 8]A11yNode = undefined;
    for (&nodes, 0..) |*n, i| {
        n.* = .{
            .role = .text,
            .cmd_index = @intCast(i),
            .bounds = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        };
    }

    const lens = serializeA11yTree(&nodes);

    try testing.expectEqual(@as(u32, MAX_A11Y_NODES * A11Y_RECORD_BYTES), lens.records_len);
    try testing.expectEqual(@as(u32, 0), lens.strings_len);

    const records: [*]const A11yRecord = @ptrCast(&g_a11y_records);
    try testing.expectEqual(@as(u32, MAX_A11Y_NODES - 1), records[MAX_A11Y_NODES - 1].cmd_index);
}

test "serializeA11yTree: oversized label is skipped, record still emitted" {
    const testing = std.testing;

    var huge: [A11Y_STRING_HEAP_BYTES + 1]u8 = undefined;
    @memset(&huge, 'x');

    const nodes = [_]A11yNode{
        .{
            .role = .text,
            .cmd_index = 1,
            .bounds = .{ .x = 0, .y = 0, .w = 10, .h = 10 },
            .label = &huge,
        },
    };

    const lens = serializeA11yTree(&nodes);
    try testing.expectEqual(@as(u32, A11Y_RECORD_BYTES), lens.records_len);
    try testing.expectEqual(@as(u32, 0), lens.strings_len);

    const records: [*]const A11yRecord = @ptrCast(&g_a11y_records);
    try testing.expectEqual(@as(u32, 1), records[0].cmd_index);
    try testing.expectEqual(@as(u32, 0), records[0].label_len);
}

