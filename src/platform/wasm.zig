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
const zime = zunk.web.ime;
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

/// DOM `keyCode` -> shortcut key (see `InputQueue.pushShortcut`); built at
/// comptime from the key enum so letters, digits and F-keys cost no lines.
const ShortcutCode = struct { code: u8, key: teak.Key };
const shortcut_codes = shortcutTable();

fn shortcutTable() [shortcut_count]ShortcutCode {
    @setEvalBranchQuota(10_000);
    var out: [shortcut_count]ShortcutCode = undefined;
    var n: usize = 0;
    for (0..26) |i| {
        out[n] = .{ .code = @intCast(65 + i), .key = @fromBackingInt(@intCast(i)) };
        n += 1;
    }
    for (0..10) |i| {
        out[n] = .{ .code = @intCast(48 + i), .key = @fromBackingInt(@intCast(@backingInt(teak.Key.d0) + i)) };
        n += 1;
    }
    for (0..12) |i| {
        out[n] = .{ .code = @intCast(112 + i), .key = @fromBackingInt(@intCast(@backingInt(teak.Key.f1) + i)) };
        n += 1;
    }
    for (shortcut_extra) |e| {
        out[n] = e;
        n += 1;
    }
    return out;
}

const shortcut_extra = [_]ShortcutCode{
    .{ .code = 13, .key = .enter },          .{ .code = 9, .key = .tab },
    .{ .code = 27, .key = .escape },         .{ .code = 32, .key = .space },
    .{ .code = 8, .key = .backspace },       .{ .code = 46, .key = .delete },
    .{ .code = 45, .key = .insert },         .{ .code = 37, .key = .left },
    .{ .code = 39, .key = .right },          .{ .code = 38, .key = .up },
    .{ .code = 40, .key = .down },           .{ .code = 36, .key = .home },
    .{ .code = 35, .key = .end },            .{ .code = 33, .key = .page_up },
    .{ .code = 34, .key = .page_down },      .{ .code = 188, .key = .comma },
    .{ .code = 190, .key = .period },        .{ .code = 191, .key = .slash },
    .{ .code = 220, .key = .backslash },     .{ .code = 186, .key = .semicolon },
    .{ .code = 222, .key = .quote },         .{ .code = 189, .key = .minus },
    .{ .code = 187, .key = .equal },         .{ .code = 219, .key = .bracket_left },
    .{ .code = 221, .key = .bracket_right }, .{ .code = 192, .key = .grave },
};
const shortcut_count = 26 + 10 + 12 + shortcut_extra.len;
/// Longest preedit kept (UTF-8 bytes); the runtime's snapshot buffer is smaller still.
const ime_text_cap = 256;

/// zunk key code -> host-neutral key. Letters only matter as Ctrl chords;
/// `InputQueue.pushNav` drops them when Ctrl is not held.
const key_mappings = [_]struct { from: zinput.Key, to: NavKey }{
    .{ .from = .backspace, .to = .backspace },
    .{ .from = .delete, .to = .delete },
    .{ .from = .enter, .to = .enter },
    .{ .from = .tab, .to = .tab },
    .{ .from = .escape, .to = .escape },
    .{ .from = .f12, .to = .f12 },
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

// ── A11y DOM-mirror wire format (v2) ───────────────────────────────
//
// `publishA11yTree` ships the a11y snapshot (only when it changed: the run
// loop diffs) to the JS side over two parallel buffers: a fixed-stride record
// array (one record per node, parents before children) and a UTF-8 string
// heap holding every label and value back-to-back. The zunk shim mirrors the
// tree into a hidden, properly NESTED DOM subtree of ARIA elements, so
// screen readers can navigate and operate canvas-rendered widgets, and
// reports what the user does there back through `pollA11yActions`.
//
// Per-node record layout (little-endian; `extern struct`, 64 bytes):
//
//   offset  size  field
//        0     4  cmd_index      u32  index into the source Cmd buffer (action target)
//        4     4  role           u32  WIRE ROLE CODE (see `wireRole`, = zunk's table)
//        8     4  label_offset   u32  byte offset into the string heap
//       12     4  label_len      u32
//       16    16  bounds x,y,w,h i32  rounded window-pixel rect
//       32     4  state          f32  checkbox/radio 0/1, slider and progressbar [0, 1]
//       36     4  flags          u32  see A11Y_FLAG_*
//       40     4  value_offset   u32  editable text / value in the string heap
//       44     4  value_len      u32
//       48     4  sel_start      u32  selection inside the value (bytes)
//       52     4  sel_end        u32
//       56     4  parent         u32  record index of the enclosing node, 0xFFFFFFFF = root
//       60     4  level          u32  heading level / tree depth, 0 = unspecified
//
// Wire role codes (ARIA names): 0 generic, 1 region, 2 text, 3 text (rich),
// 4 button, 5 textbox, 6 checkbox, 7 radio, 8 slider, 9 separator, 10 img,
// 11 dialog, 12 textbox (multiline), 13 combobox, 14 listbox, 15 option,
// 16 menu, 17 menuitem, 18 tablist, 19 tab, 20 tree, 21 treeitem, 22 table,
// 23 row, 24 cell, 25 progressbar, 26 status, 27 alert, 28 list, 29 listitem,
// 30 toolbar, 31 heading, 32 menubar, 33 columnheader, 34 link.
//
// Fixed-size buffers (wasm-freestanding has no default heap; single-threaded;
// JS reads them synchronously inside the extern call): 512 nodes x 64 bytes
// = 32 KB of records, 32 KB string heap. Nodes past the cap and strings that
// do not fit are dropped (the record stays, unlabeled).
//
// Actions come back the other way: `pollA11yActions` calls
// `__zunk_poll_a11y_actions(recs, cap, strings, str_cap) -> count` once per
// frame; each 16-byte record is `{kind u32, cmd_index u32, str_off u32,
// str_len u32}` (kind = `a11y.ActionKind` order). The run loop turns them
// into ordinary input.

const MAX_A11Y_NODES: usize = 512;
const A11Y_STRING_HEAP_BYTES: usize = 32 * 1024;
const A11Y_RECORD_BYTES: usize = 64;

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
    value_offset: u32,
    value_len: u32,
    sel_start: u32,
    sel_end: u32,
    parent: u32,
    level: u32,

    comptime {
        if (@sizeOf(A11yRecord) != A11Y_RECORD_BYTES) {
            @compileError("A11yRecord size drifted from documented wire format");
        }
    }
};

/// Bit positions for `A11yRecord.flags`. Keep the table in sync with
/// the JS shim — adding a bit is a wire-format change.
const A11Y_FLAG_FOCUSED: u32 = 1 << 0;
const A11Y_FLAG_DISABLED: u32 = 1 << 1;
const A11Y_FLAG_SELECTED: u32 = 1 << 2;
const A11Y_FLAG_EXPANDABLE: u32 = 1 << 3;
const A11Y_FLAG_EXPANDED: u32 = 1 << 4;
const A11Y_FLAG_MODAL: u32 = 1 << 5;
const A11Y_FLAG_LIVE_POLITE: u32 = 1 << 6;
const A11Y_FLAG_LIVE_ASSERTIVE: u32 = 1 << 7;

/// The wire role code of a node (the JS table is indexed by it).
fn wireRole(n: A11yNode) u32 {
    return switch (n.role) {
        .group => 0,
        .scroll => 1,
        .text => 2,
        .rich_text => 3,
        .button => 4,
        .text_input, .text_area => 5,
        .checkbox => 6,
        .radio => 7,
        .slider => 8,
        .divider => 9,
        .image, .canvas => 10,
        .overlay => if (n.modal) 11 else 1,
        .dialog => 11,
        .combobox => 13,
        .listbox => 14,
        .option => 15,
        .menu => 16,
        .menuitem => 17,
        .tablist => 18,
        .tab => 19,
        .tree => 20,
        .treeitem => 21,
        .table => 22,
        .row => 23,
        .cell => 24,
        .progressbar => 25,
        .status => 26,
        .alert => 27,
        .list => 28,
        .listitem => 29,
        .toolbar => 30,
        .heading => 31,
        .menubar => 32,
        .columnheader => 33,
        .link => 34,
    };
}

// Module-scoped backing store for the two wire buffers. Single-host
// wasm process — one publish-tree call at a time, single-threaded,
// reused every frame. Zero per-frame allocation.
var g_a11y_records: [MAX_A11Y_NODES * A11Y_RECORD_BYTES]u8 align(@alignOf(A11yRecord)) = undefined;
var g_a11y_strings: [A11Y_STRING_HEAP_BYTES]u8 = undefined;

/// Append `bytes` to the string heap; returns `{offset, len}` (zeros when it does not fit).
fn putString(used: *u32, bytes: []const u8) struct { off: u32, len: u32 } {
    if (bytes.len == 0 or bytes.len > A11Y_STRING_HEAP_BYTES - used.*) return .{ .off = 0, .len = 0 };
    const off = used.*;
    @memcpy(g_a11y_strings[off..][0..bytes.len], bytes);
    used.* += @intCast(bytes.len);
    return .{ .off = off, .len = @intCast(bytes.len) };
}

/// Serialize an A11yNode slice into the module-scoped record + string
/// buffers and return the byte lengths actually written. Pure helper —
/// no zunk / JS calls — so tests can exercise it in isolation.
fn serializeA11yTree(nodes: []const A11yNode) struct { records_len: u32, strings_len: u32 } {
    const count = @min(nodes.len, MAX_A11Y_NODES);
    var strings_used: u32 = 0;
    const records: [*]A11yRecord = @ptrCast(&g_a11y_records);
    for (nodes[0..count], 0..) |node, i| {
        const label = putString(&strings_used, node.label);
        const value = putString(&strings_used, node.value);
        var flags: u32 = 0;
        if (node.focused) flags |= A11Y_FLAG_FOCUSED;
        if (node.disabled) flags |= A11Y_FLAG_DISABLED;
        if (node.selected) flags |= A11Y_FLAG_SELECTED;
        if (node.expanded) |e| flags |= A11Y_FLAG_EXPANDABLE | (if (e) A11Y_FLAG_EXPANDED else 0);
        if (node.modal) flags |= A11Y_FLAG_MODAL;
        switch (node.live) {
            .off => {},
            .polite => flags |= A11Y_FLAG_LIVE_POLITE,
            .assertive => flags |= A11Y_FLAG_LIVE_ASSERTIVE,
        }
        records[i] = .{
            .cmd_index = node.cmd_index,
            .role = wireRole(node),
            .label_offset = label.off,
            .label_len = label.len,
            .bounds_x = @intFromFloat(@round(node.bounds.x)),
            .bounds_y = @intFromFloat(@round(node.bounds.y)),
            .bounds_w = @intFromFloat(@round(node.bounds.w)),
            .bounds_h = @intFromFloat(@round(node.bounds.h)),
            .state = node.state,
            .flags = flags,
            .value_offset = value.off,
            .value_len = value.len,
            .sel_start = node.sel_start,
            .sel_end = node.sel_end,
            .parent = node.parent,
            .level = node.level,
        };
    }
    return .{ .records_len = @intCast(count * A11Y_RECORD_BYTES), .strings_len = strings_used };
}

// ── A11y actions back from the page ────────────────────────────────

const MAX_A11Y_ACTIONS: usize = 16;
const A11Y_ACTION_BYTES: usize = 16;
const A11Y_ACTION_TEXT_BYTES: usize = 2048;

const A11yActionRecord = extern struct { kind: u32, cmd_index: u32, str_off: u32, str_len: u32 };

var g_a11y_action_recs: [MAX_A11Y_ACTIONS]A11yActionRecord = undefined;
var g_a11y_action_text: [A11Y_ACTION_TEXT_BYTES]u8 = undefined;

/// Decode `count` action records (as the JS side wrote them) into `out`.
fn decodeA11yActions(count: usize, out: []teak.A11yAction) usize {
    var n: usize = 0;
    for (g_a11y_action_recs[0..@min(count, MAX_A11Y_ACTIONS)]) |r| {
        if (n == out.len) break;
        if (r.kind > @backingInt(teak.A11yActionKind.decrement)) continue;
        if (r.str_off > A11Y_ACTION_TEXT_BYTES or r.str_len > A11Y_ACTION_TEXT_BYTES - r.str_off) continue;
        out[n] = .{
            .kind = @fromBackingInt(@intCast(r.kind)),
            .cmd_index = r.cmd_index,
            .text = g_a11y_action_text[r.str_off..][0..r.str_len],
        };
        n += 1;
    }
    return n;
}

/// JS-side imports (wired by zunk's resolver — see zunk issue #14 for
/// the file-dialog shim and zunk issue #15 for the a11y DOM mirror).
/// Never gate a call on a has-decl check of this namespace: the decls are non-`pub`, so
/// it is always false (audit rule NO_HASDECL_EXTERNS).
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

    /// Drains the DOM mirror's queued AT requests into the buffers; returns the count.
    extern "env" fn __zunk_poll_a11y_actions(
        records_ptr: [*]u8,
        records_cap: u32,
        strings_ptr: [*]u8,
        strings_cap: u32,
    ) u32;
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
    /// IME composition mirror (`zunk.web.ime`): the live preedit, valid until the
    /// next `pollInputs`. Commits go to the input queue as typed text.
    ime_active: bool = false,
    ime_len: usize = 0,
    ime_cursor: usize = 0,
    ime_text: [ime_text_cap]u8 = undefined,
    ime_scratch: [1024]u8 = undefined,

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
        for (shortcut_codes) |m| {
            if (zinput.isKeyPressed(@fromBackingInt(@intCast(m.code)))) q.pushShortcut(m.key);
        }
        if (zinput.isKeyReleased(.alt)) q.altUp();
        q.mods = reported;
        // Zunk delivers whole UTF-8 code points and no control codes or
        // Ctrl/Cmd chords; `pushText` re-validates and drops anything else.
        q.pushText(zinput.getTypedChars());
        self.pollIme(q);

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

    /// The browser's IME composition. A hidden `<textarea>` (zunk's IME bridge)
    /// holds focus while a text field is focused, so the OS candidate window and
    /// composition work; its events are folded in by `pollInputs`.
    pub fn imeState(self: *const Host) ImeState {
        return .{ .active = self.ime_active, .text = self.ime_text[0..self.ime_len], .cursor = self.ime_cursor };
    }

    /// Focus the IME field while the app has a focused text input (optional Host
    /// extension, called by the runtime on focus transitions).
    pub fn setImeActive(self: *Host, active: bool) void {
        _ = self;
        zime.setActive(active);
    }

    /// Anchor the candidate window at the caret (CSS px, bottom of the caret line).
    pub fn setImeSpot(self: *Host, x: i32, y: i32) void {
        _ = self;
        zime.setSpot(@floatFromInt(x), @floatFromInt(y - 1), 1);
    }

    fn pollIme(self: *Host, q: *InputQueue) void {
        var events: [16]zime.Event = undefined;
        const n = zime.poll(&events, &self.ime_scratch);
        for (events[0..n]) |ev| self.applyImeEvent(q, ev.kind, ev.text, ev.cursor);
    }

    /// One bridge event: start/update replace the preedit, commit clears it and
    /// types the result (an empty commit is a cancelled composition).
    fn applyImeEvent(self: *Host, q: *InputQueue, kind: zime.Kind, text: []const u8, cursor: usize) void {
        switch (kind) {
            .start => {
                self.ime_active = true;
                self.ime_len = 0;
                self.ime_cursor = 0;
            },
            .update => {
                var n = @min(text.len, ime_text_cap);
                // Never keep half a code point.
                while (n > 0 and n < text.len and (text[n] & 0xC0) == 0x80) n -= 1;
                @memcpy(self.ime_text[0..n], text[0..n]);
                self.ime_len = n;
                self.ime_cursor = @min(cursor, n);
                self.ime_active = true;
            },
            .commit => {
                self.ime_active = false;
                self.ime_len = 0;
                self.ime_cursor = 0;
                q.pushText(text);
            },
        }
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
        externs.__zunk_publish_a11y_tree(
            &g_a11y_records,
            lens.records_len,
            &g_a11y_strings,
            lens.strings_len,
        );
    }

    /// Requests from assistive technology (a screen reader activating a
    /// control, focusing it, setting a text value) queued by the DOM mirror
    /// since the last frame. The run loop turns them into ordinary input.
    pub fn pollA11yActions(_: *Host, out: []teak.A11yAction) usize {
        const count = externs.__zunk_poll_a11y_actions(
            @ptrCast(&g_a11y_action_recs),
            MAX_A11Y_ACTIONS,
            &g_a11y_action_text,
            A11Y_ACTION_TEXT_BYTES,
        );
        return decodeA11yActions(count, out);
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
        // Unconditional: a has-decl check on the private externs is always false for non-`pub`
        // decls, which silently dropped every request (audit-enforced).
        {
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
            .write_clipboard_image => |c| fx.clipboardWriteImage(c.png),
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
    /// CSS `cursor` on the page body through zunk (`app.setCursor`).
    pub fn setCursor(_: *Host, shape: teak.CursorShape) void {
        zapp.setCursor(shape.cssName());
    }

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
    try testing.expectEqual(@as(u32, 4), records[0].role); // wire code: button
    try testing.expectEqual(@as(u32, 0), records[0].label_offset);
    try testing.expectEqual(@as(u32, 4), records[0].label_len);
    try testing.expectEqual(@as(i32, 10), records[0].bounds_x);
    try testing.expectEqual(@as(i32, 20), records[0].bounds_y);
    try testing.expectEqual(@as(i32, 100), records[0].bounds_w);
    try testing.expectEqual(@as(i32, 30), records[0].bounds_h);
    try testing.expectEqual(A11Y_FLAG_FOCUSED, records[0].flags & A11Y_FLAG_FOCUSED);

    // Record 1: checked, non-focused checkbox stacked after.
    try testing.expectEqual(@as(u32, 9), records[1].cmd_index);
    try testing.expectEqual(@as(u32, 6), records[1].role); // wire code: checkbox
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

test "IME events: a composition shows as preedit, the commit is typed and clears it" {
    var h = Host{ .width = 10, .height = 10 };
    var q: InputQueue = .{};
    q.beginFrame();
    h.applyImeEvent(&q, .start, "", 0);
    try std.testing.expect(h.imeState().active);
    h.applyImeEvent(&q, .update, "\u{306B}\u{307B}", 3);
    try std.testing.expectEqualStrings("\u{306B}\u{307B}", h.imeState().text);
    try std.testing.expectEqual(@as(usize, 3), h.imeState().cursor);
    h.applyImeEvent(&q, .commit, "\u{65E5}\u{672C}", 0);
    try std.testing.expect(!h.imeState().active);
    try std.testing.expectEqual(@as(usize, 0), h.imeState().text.len);
    const st = q.finish(false, 10, 10);
    try std.testing.expectEqualStrings("\u{65E5}\u{672C}", st.chars);
}

test "IME events: a cancelled composition types nothing; an oversized preedit is cut on a boundary" {
    var h = Host{ .width = 10, .height = 10 };
    var q: InputQueue = .{};
    q.beginFrame();
    h.applyImeEvent(&q, .update, "\u{3042}", 3);
    h.applyImeEvent(&q, .commit, "", 0);
    try std.testing.expect(!h.imeState().active);
    var big: [ime_text_cap + 2]u8 = undefined;
    for (0..big.len / 3) |i| @memcpy(big[i * 3 ..][0..3], "\u{3042}");
    h.applyImeEvent(&q, .update, big[0 .. big.len / 3 * 3], 0);
    try std.testing.expect(h.imeState().text.len <= ime_text_cap and h.imeState().text.len % 3 == 0);
    const st = q.finish(false, 10, 10);
    try std.testing.expectEqual(@as(usize, 0), st.chars.len);
}

test "serializeA11yTree: v2 fields (value, selection, parent, flags, wire roles)" {
    const testing = std.testing;
    const nodes = [_]A11yNode{
        .{ .role = .tablist, .cmd_index = 0, .bounds = .{ .w = 100, .h = 20 }, .label = "Parts" },
        .{ .role = .tab, .cmd_index = 1, .bounds = .{ .w = 50, .h = 20 }, .label = "A", .selected = true, .parent = 0 },
        .{ .role = .text_input, .cmd_index = 2, .bounds = .{}, .value = "hello", .sel_start = 1, .sel_end = 3, .focused = true, .disabled = true, .parent = 0 },
        .{ .role = .treeitem, .cmd_index = 3, .bounds = .{}, .label = "src", .expanded = false, .level = 2, .parent = 0 },
        .{ .role = .status, .cmd_index = 4, .bounds = .{}, .live = .polite },
        .{ .role = .overlay, .cmd_index = 5, .bounds = .{}, .modal = true },
        .{ .role = .overlay, .cmd_index = 6, .bounds = .{} },
    };
    const lens = serializeA11yTree(&nodes);
    try testing.expectEqual(@as(u32, nodes.len * A11Y_RECORD_BYTES), lens.records_len);
    const r: [*]const A11yRecord = @ptrCast(&g_a11y_records);
    try testing.expectEqual(@as(u32, 18), r[0].role); // tablist
    try testing.expectEqual(@as(u32, 0xFFFFFFFF), r[0].parent);
    try testing.expectEqual(@as(u32, 19), r[1].role); // tab
    try testing.expect(r[1].flags & A11Y_FLAG_SELECTED != 0);
    try testing.expectEqual(@as(u32, 0), r[1].parent);
    try testing.expectEqual(@as(u32, 5), r[2].role); // textbox
    try testing.expectEqualStrings("hello", g_a11y_strings[r[2].value_offset..][0..r[2].value_len]);
    try testing.expectEqual(@as(u32, 1), r[2].sel_start);
    try testing.expectEqual(@as(u32, 3), r[2].sel_end);
    try testing.expect(r[2].flags & (A11Y_FLAG_FOCUSED | A11Y_FLAG_DISABLED) == (A11Y_FLAG_FOCUSED | A11Y_FLAG_DISABLED));
    try testing.expectEqual(@as(u32, 21), r[3].role); // treeitem
    try testing.expect(r[3].flags & A11Y_FLAG_EXPANDABLE != 0 and r[3].flags & A11Y_FLAG_EXPANDED == 0);
    try testing.expectEqual(@as(u32, 2), r[3].level);
    try testing.expect(r[4].flags & A11Y_FLAG_LIVE_POLITE != 0);
    try testing.expectEqual(@as(u32, 11), r[5].role); // modal overlay -> dialog
    try testing.expect(r[5].flags & A11Y_FLAG_MODAL != 0);
    try testing.expectEqual(@as(u32, 1), r[6].role); // plain overlay -> region
}

test "decodeA11yActions: maps wire records, rejects bad kinds and out-of-range text" {
    const testing = std.testing;
    @memcpy(g_a11y_action_text[0..5], "hello");
    g_a11y_action_recs[0] = .{ .kind = 0, .cmd_index = 3, .str_off = 0, .str_len = 0 }; // activate
    g_a11y_action_recs[1] = .{ .kind = 2, .cmd_index = 4, .str_off = 0, .str_len = 5 }; // set_value
    g_a11y_action_recs[2] = .{ .kind = 99, .cmd_index = 5, .str_off = 0, .str_len = 0 }; // bad kind
    g_a11y_action_recs[3] = .{ .kind = 2, .cmd_index = 6, .str_off = 2040, .str_len = 100 }; // out of range
    var out: [8]teak.A11yAction = undefined;
    const n = decodeA11yActions(4, &out);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(teak.A11yActionKind.activate, out[0].kind);
    try testing.expectEqual(@as(u32, 3), out[0].cmd_index);
    try testing.expectEqual(teak.A11yActionKind.set_value, out[1].kind);
    try testing.expectEqualStrings("hello", out[1].text);
}
