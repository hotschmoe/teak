//! Wasm host backed by zunk's `web.input` + `web.app` modules. Zunk
//! owns the rAF loop; `pollInputs` snapshots zunk's shared-memory
//! state into teak's `InputState`.
//!
//! Button edges, modifiers, horizontal wheel and UTF-8 typed text all come
//! straight from zunk's input block; the key policy (Shift/Ctrl variants)
//! is the shared `teak.resolveKey` via an `InputQueue`.
//!
//! All pointer + viewport coords are CSS pixels (zunk v0.5.2+).

const std = @import("std");
const teak = @import("teak");
const zunk = @import("zunk");

/// `std.Options.logFn` that writes `std.log` to the browser console. The
/// default logFn does not compile on wasm32-freestanding, so every web entry
/// point must declare `pub const std_options: std.Options = .{ .logFn = platform.logFn };`.
pub const logFn = zunk.web.logFn;

const zinput = zunk.web.input;
const zapp = zunk.web.app;
const zgpu = zunk.web.gpu;
const fx = zunk.web.fx;
const teak_text = @import("teak-text");
const font_data = @import("teak-web-fontdata");

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

pub const NativeHandle = struct {};

/// zunk key code -> host-neutral key. Letters only matter as Ctrl chords;
/// `InputQueue.pushNav` drops them when Ctrl is not held.
const key_mappings = [_]struct { from: zinput.Key, to: NavKey }{
    .{ .from = .backspace, .to = .backspace },
    .{ .from = .delete, .to = .delete },
    .{ .from = .enter, .to = .enter },
    .{ .from = .tab, .to = .tab },
    .{ .from = .escape, .to = .escape },
    .{ .from = .f10, .to = .f10 },
    .{ .from = .arrow_left, .to = .left },
    .{ .from = .arrow_right, .to = .right },
    .{ .from = .arrow_up, .to = .up },
    .{ .from = .arrow_down, .to = .down },
    .{ .from = .home, .to = .home },
    .{ .from = .end, .to = .end },
    .{ .from = .page_up, .to = .page_up },
    .{ .from = .page_down, .to = .page_down },
    .{ .from = .a, .to = .a },
    .{ .from = .c, .to = .c },
    .{ .from = .x, .to = .x },
    .{ .from = .v, .to = .v },
    .{ .from = .y, .to = .y },
    .{ .from = .z, .to = .z },
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

/// Allocator for transient request encodings (HTTP header text).
const request_allocator = std.heap.wasm_allocator;

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
            .role = @backingInt(node.role),
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

/// The default face (Plex Mono subset) is the fallback for every family without
/// a registered face, like the system font on native; then each `.fonts` file
/// goes into its slot and weight.
fn registerEmbeddedFonts() void {
    if (font_data.default_font.len > 0) teak_text.face.setFallbackBytes(font_data.default_font);
    for (font_data.faces) |f| {
        const family: teak.FontFamily = @fromBackingInt(@intCast(f.slot));
        const weight: teak.FontWeight = if (f.weight < 450) .regular else if (f.weight < 600) .medium else .bold;
        teak_text.registerFace(family, weight, f.bytes) catch {};
    }
}

pub const Host = struct {
    width: u32,
    height: u32,
    first_poll: bool = true,
    queue: InputQueue = .{},
    file_dialog_slots: [MAX_FILE_DIALOG_SLOTS]FileDialogSlot = @splat(.{}),
    /// This frame's effect completions (`zunk.web.fx`), fetched by
    /// `pollInputs` so `Clipboard.read` can see a paste before the keys are
    /// routed. `fx_next` is the first one `pollEffectResults` has not
    /// handed out; `fx_claimed` marks pastes taken through `Clipboard.read`;
    /// `fx_polled` says an app is draining results (otherwise a batch is
    /// simply replaced next frame).
    fx_batch: [fx.max_completions]fx.Completion = undefined,
    fx_count: usize = 0,
    fx_next: usize = 0,
    fx_claimed: u32 = 0,
    fx_polled: bool = false,

    pub fn init(title: []const u8, width: u32, height: u32) !Host {
        zinput.init();
        zapp.setTitle(title);
        registerEmbeddedFonts();
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
        if (self.fx_next >= self.fx_count or !self.fx_polled) {
            self.fx_count = fx.poll(&self.fx_batch);
            self.fx_next = 0;
            self.fx_claimed = 0;
            self.fx_polled = false;
        }

        // Zunk reports held state AND per-frame press/release edges (a click
        // that begins and ends inside one frame sets both), so there is no
        // local edge derivation. Wheel is CSS pixels, positive = down/right.
        const mouse = zinput.getMouse();
        const mods = zinput.getModifiers();
        const q = &self.queue;
        q.beginFrame();
        q.mods = .{ .shift = mods.shift, .ctrl = mods.ctrl, .alt = mods.alt, .meta = mods.meta };
        q.pointerMoved(mouse.x, mouse.y);
        q.buttons = .{ .left = mouse.buttons.left, .middle = mouse.buttons.middle, .right = mouse.buttons.right };
        q.pressed = buttonEdges(zinput.isMouseButtonPressed);
        q.released = buttonEdges(zinput.isMouseButtonReleased);
        q.wheel(mouse.wheel_x, mouse.wheel);

        // Cmd (meta) acts as Ctrl for the chord keys (Cmd+V pastes on macOS);
        // the reported `mods` keep the real state.
        const reported = q.mods;
        q.mods.ctrl = reported.ctrl or reported.meta;
        if (zinput.isKeyPressed(.alt)) q.altDown();
        for (key_mappings) |m| {
            if (zinput.isKeyPressed(m.from)) q.pushNav(m.to);
        }
        if (zinput.isKeyReleased(.alt)) q.altUp();
        q.mods = reported;
        // Zunk delivers whole UTF-8 code points and no control codes or
        // Ctrl/Cmd chords; `pushText` re-validates and drops anything else.
        q.pushText(zinput.getTypedChars());

        const vp = zinput.getViewportSize();
        const w = if (vp.w != 0) vp.w else self.width;
        const h = if (vp.h != 0) vp.h else self.height;
        const resized = self.first_poll or w != self.width or h != self.height;
        self.first_poll = false;
        self.width = w;
        self.height = h;
        return q.finish(resized, w, h);
    }

    fn buttonEdges(comptime isEdge: fn (zinput.MouseButton) bool) teak.Buttons {
        return .{
            .left = isEdge(.left),
            .middle = isEdge(.middle),
            .right = isEdge(.right),
        };
    }

    pub fn shouldClose(_: *const Host) bool {
        return false;
    }

    pub fn nativeHandle(_: *const Host) NativeHandle {
        return .{};
    }

    /// Measures with the shared stb_truetype shaper (`teak-text`), on the
    /// faces embedded in the wasm: the same advances the Gpu rasterizes with, and
    /// the same numbers as every native backend. Results are cached by the
    /// module, so repeated labels cost a hash.
    pub fn textMeasurer(self: *Host) TextMeasurer {
        return .{ .ctx = @ptrCast(self), .measure_fn = stbMeasure };
    }

    fn stbMeasure(_: *anyopaque, text_bytes: []const u8, font: FontSpec) TextMetrics {
        return teak_text.measure(text_bytes, font);
    }

    /// Register a TTF for (`family`, `weight`) at runtime; the bytes are
    /// borrowed (an `@embedFile` slice). The `.fonts` build option already
    /// registers its files at `init`.
    pub fn registerFont(_: *Host, family: teak.FontFamily, weight: teak.FontWeight, ttf: []const u8) !void {
        try teak_text.registerFace(family, weight, ttf);
    }

    /// Clipboard vtable. `write` goes through the effects bridge
    /// (`navigator.clipboard.writeText`, `execCommand` fallback). `read`
    /// returns the text of the paste event that accompanied the Ctrl/Cmd+V
    /// key press (browsers only expose the clipboard inside a `paste`
    /// event), and claims it, so the same paste is not also delivered as
    /// `EffectResult.pasted_text`. Empty when no paste arrived this frame.
    pub fn clipboard(self: *Host) Clipboard {
        return .{ .ctx = @ptrCast(self), .read_fn = clipboardRead, .write_fn = clipboardWrite };
    }

    fn clipboardRead(ctx: *anyopaque) []const u8 {
        const self: *Host = @ptrCast(@alignCast(ctx));
        for (self.fx_next..self.fx_count) |i| {
            const claimed = self.fx_claimed & (@as(u32, 1) << @intCast(i)) != 0;
            if (self.fx_batch[i].kind != .pasted_text or claimed) continue;
            self.fx_claimed |= @as(u32, 1) << @intCast(i);
            return self.fx_batch[i].blobs[0];
        }
        return "";
    }

    fn clipboardWrite(_: *anyopaque, text: []const u8) void {
        fx.clipboardWrite(text);
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

    // ── Declarative effects (zunk.web.fx) ──────────────────────────
    //
    // `submit` starts the work and returns; results (and unsolicited pastes /
    // drops) are fetched by `pollInputs` and handed out here. The completion
    // slices stay valid until the next `pollInputs`.

    pub fn submit(_: *Host, e: teak.Effect) teak.EffectSubmit {
        switch (e) {
            .http => |r| {
                const headers = fx.encodeHeaders(request_allocator, r.headers) catch return .busy;
                defer request_allocator.free(headers);
                fx.http(r.id, httpMethod(r.method), r.url, headers, r.body, r.timeout_ms);
            },
            .download => |d| fx.download(d.id, d.name, d.mime, d.bytes),
            .open_file => |o| fx.openFile(o.id, o.accept),
            .write_clipboard => |c| fx.clipboardWrite(c.text),
            .storage_set => |s| fx.storageSet(s.key, s.value),
            .storage_get => |g| fx.storageGet(g.id, g.key),
            .clock => |c| fx.clock(c.id),
            .query_param => |q| fx.queryParam(q.id, q.name),
        }
        return .accepted;
    }

    pub fn pollEffectResults(self: *Host, buf: []teak.EffectResult) usize {
        self.fx_polled = true;
        var n: usize = 0;
        while (n < buf.len and self.fx_next < self.fx_count) : (self.fx_next += 1) {
            const claimed = self.fx_claimed & (@as(u32, 1) << @intCast(self.fx_next)) != 0;
            if (claimed) continue;
            buf[n] = effectResult(self.fx_batch[self.fx_next]);
            n += 1;
        }
        return n;
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

    /// Browser monotonic time (`performance.now()`), in milliseconds.
    pub fn nowMs(_: *const Host) u64 {
        return @intFromFloat(@max(0, zapp.performanceNow()));
    }

    /// Physical pixels per logical unit. Teak's web coordinate space is
    /// CSS pixels end-to-end (zunk v0.5.2+): pointer coords, viewport
    /// size, layout, and the shader's `screen_size` uniform all share it.
    /// Zunk sizes the canvas backing store at CSS×devicePixelRatio and
    /// rasterizes glyphs at that resolution *internally*, so text stays
    /// crisp on HiDPI without teak ever seeing a physical pixel — the DPR
    /// lives entirely inside zunk's swap-chain. From teak's coordinate
    /// space the scale is therefore 1.0. (This is why the pre-v0.5.2
    /// `mouse * inv_dpr` shim was removed: teak and zunk now agree on CSS
    /// pixels, and dividing again halved coords on HiDPI.)
    pub fn scaleFactor(_: *const Host) f32 {
        return 1.0;
    }
};

fn httpMethod(m: teak.effects.HttpMethod) fx.Method {
    return switch (m) {
        .get => .get,
        .post => .post,
        .put => .put,
        .delete => .delete,
    };
}

/// A completion as the framework's contract type. Slices alias `c`.
fn effectResult(c: fx.Completion) teak.EffectResult {
    return switch (c.kind) {
        .http => .{ .http = .{
            .id = c.id,
            .status = std.math.cast(u16, c.a) orelse 0,
            .body = c.blobs[0],
            .err = c.blobs[1],
        } },
        .file_opened => .{ .file_opened = .{ .id = c.id, .name = c.blobs[0], .mime = c.blobs[1], .bytes = c.blobs[2] } },
        .file_cancelled => .{ .file_cancelled = .{ .id = c.id } },
        .downloaded => .{ .downloaded = .{ .id = c.id, .ok = c.a != 0 } },
        .storage_value => .{ .storage_value = .{ .id = c.id, .value = if (c.a != 0) c.blobs[0] else null } },
        .query_value => .{ .query_value = .{ .id = c.id, .value = if (c.a != 0) c.blobs[0] else null } },
        .clock => .{ .clock = .{ .id = c.id, .unix_ms = c.unixMs(), .utc_offset_min = c.a } },
        .pasted_text => .{ .pasted_text = .{ .text = c.blobs[0] } },
        .dropped => .{ .dropped = dropOf(c) },
    };
}

fn dropOf(c: fx.Completion) teak.Drop {
    const kind: teak.DropKind = switch (c.a) {
        1 => .image,
        2 => .text,
        else => .file,
    };
    const thumb = c.blobs[3];
    const thumb_w: u32 = if (c.d > 0) @intCast(c.d) else 0;
    // The preview is only meaningful when its length matches its width.
    const thumb_h: u32 = if (thumb_w > 0 and thumb.len % (4 * thumb_w) == 0) @intCast(thumb.len / (4 * thumb_w)) else 0;
    return .{
        .kind = kind,
        .name = c.blobs[0],
        .mime = c.blobs[1],
        .bytes = c.blobs[2],
        .width = if (c.b > 0) @intCast(c.b) else 0,
        .height = if (c.c > 0) @intCast(c.c) else 0,
        .thumb_rgba = if (thumb_h > 0) thumb else "",
        .thumb_w = if (thumb_h > 0) thumb_w else 0,
        .thumb_h = thumb_h,
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
    try testing.expectEqual(@as(u32, @backingInt(teak.A11yRole.button)), records[0].role);
    try testing.expectEqual(@as(u32, 0), records[0].label_offset);
    try testing.expectEqual(@as(u32, 4), records[0].label_len);
    try testing.expectEqual(@as(i32, 10), records[0].bounds_x);
    try testing.expectEqual(@as(i32, 20), records[0].bounds_y);
    try testing.expectEqual(@as(i32, 100), records[0].bounds_w);
    try testing.expectEqual(@as(i32, 30), records[0].bounds_h);
    try testing.expectEqual(A11Y_FLAG_FOCUSED, records[0].flags & A11Y_FLAG_FOCUSED);

    // Record 1: checked, non-focused checkbox stacked after.
    try testing.expectEqual(@as(u32, 9), records[1].cmd_index);
    try testing.expectEqual(@as(u32, @backingInt(teak.A11yRole.checkbox)), records[1].role);
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

test "wasm key table reaches every SpecialKey through the shared policy" {
    var seen = std.EnumSet(SpecialKey).empty;
    const mod_sets = [_]teak.Modifiers{ .{}, .{ .shift = true }, .{ .ctrl = true }, .{ .ctrl = true, .shift = true } };
    for (mod_sets) |mods| {
        for (key_mappings) |m| {
            if (teak.resolveKey(m.to, mods)) |sk| seen.insert(sk);
        }
    }
    for (std.enums.values(SpecialKey)) |sk| {
        if (sk == .alt_tap) continue; // synthesized by InputQueue.altUp, not a table key
        try std.testing.expect(seen.contains(sk));
    }
}

test "effectResult maps every completion kind to the contract type" {
    const blobs: [4][]const u8 = .{ "b0", "b1", "b2", "" };
    const base: fx.Completion = .{ .kind = .http, .id = 5, .a = 201, .b = 0, .c = 0, .d = 0, .blobs = blobs };

    const http = effectResult(base).http;
    try std.testing.expectEqual(@as(u32, 5), http.id);
    try std.testing.expectEqual(@as(u16, 201), http.status);
    try std.testing.expectEqualStrings("b0", http.body);
    try std.testing.expectEqualStrings("b1", http.err);

    var failed = base;
    failed.a = 0;
    try std.testing.expectEqual(@as(u16, 0), effectResult(failed).http.status);

    var opened = base;
    opened.kind = .file_opened;
    const f = effectResult(opened).file_opened;
    try std.testing.expectEqualStrings("b0", f.name);
    try std.testing.expectEqualStrings("b1", f.mime);
    try std.testing.expectEqualStrings("b2", f.bytes);

    var storage = base;
    storage.kind = .storage_value;
    storage.a = 0;
    try std.testing.expect(effectResult(storage).storage_value.value == null);
    storage.a = 1;
    try std.testing.expectEqualStrings("b0", effectResult(storage).storage_value.value.?);

    var q = base;
    q.kind = .query_value;
    q.a = 0;
    try std.testing.expect(effectResult(q).query_value.value == null);

    var ms: [8]u8 = undefined;
    std.mem.writeInt(i64, &ms, 1_700_000_000_000, .little);
    var clock = base;
    clock.kind = .clock;
    clock.a = -300;
    clock.blobs[0] = &ms;
    const t = effectResult(clock).clock;
    try std.testing.expectEqual(@as(i64, 1_700_000_000_000), t.unix_ms);
    try std.testing.expectEqual(@as(i32, -300), t.utc_offset_min);

    var paste = base;
    paste.kind = .pasted_text;
    try std.testing.expectEqualStrings("b0", effectResult(paste).pasted_text.text);
}

test "dropOf: image metadata and a thumbnail that matches its width" {
    const thumb: [4 * 3 * 2]u8 = @splat(7); // 3 x 2 RGBA
    const img = dropOf(.{ .kind = .dropped, .id = 0, .a = 1, .b = 1568, .c = 900, .d = 3, .blobs = .{ "s.png", "image/png", "PNG", &thumb } });
    try std.testing.expectEqual(teak.DropKind.image, img.kind);
    try std.testing.expectEqual(@as(u32, 1568), img.width);
    try std.testing.expectEqual(@as(u32, 900), img.height);
    try std.testing.expectEqual(@as(u32, 3), img.thumb_w);
    try std.testing.expectEqual(@as(u32, 2), img.thumb_h);
    try std.testing.expectEqual(@as(usize, 24), img.thumb_rgba.len);

    // A preview whose size does not fit its width is dropped, not guessed.
    const bad = dropOf(.{ .kind = .dropped, .id = 0, .a = 1, .b = 8, .c = 8, .d = 3, .blobs = .{ "", "image/png", "PNG", thumb[0..10] } });
    try std.testing.expectEqual(@as(usize, 0), bad.thumb_rgba.len);
    try std.testing.expectEqual(@as(u32, 0), bad.thumb_h);

    const file = dropOf(.{ .kind = .dropped, .id = 0, .a = 0, .b = 0, .c = 0, .d = 0, .blobs = .{ "a.json", "application/json", "{}", "" } });
    try std.testing.expectEqual(teak.DropKind.file, file.kind);
    try std.testing.expectEqual(@as(u32, 0), file.width);
    const text = dropOf(.{ .kind = .dropped, .id = 0, .a = 2, .b = 0, .c = 0, .d = 0, .blobs = .{ "", "text/plain", "hi", "" } });
    try std.testing.expectEqual(teak.DropKind.text, text.kind);
}
