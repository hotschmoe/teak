//! Canonical application loop — the `teak.run` wrapper.
//!
//! Every consumer used to hand-copy ~200 lines of host-loop glue:
//! double-buffered `CmdBuffer` + rect storage, the press-target
//! mousedown/up dance, keyboard + wheel routing, clipboard glue, the
//! frame-diff vertex-rebuild skip, layout, transient-state update,
//! `buildVertices` + upload, and `renderFrame`. ~80% of that is
//! identical across apps. `run` ships it once.
//!
//! ## Where this sits (HARDLINE)
//!
//! `run` is the host-loop orchestrator. It imports the framework's pure
//! passes (`core`, `layout`, `input`, `render`) but takes the concrete
//! `Host` and `Gpu` as `anytype` parameters — it imports **neither**
//! `platform/*` nor `gpu/*`. The dependency arrow still points inward
//! (HARDLINE §3): the consumer's entry point picks the backends and
//! hands them in; `run` only duck-types the `validateHost` /
//! `validateGpu` surfaces. It lives at `src/run.zig` (a sibling of the
//! library root), not in `src/{core,layout,input,render}/*`, so it is
//! outside the "framework core" the drift audit scans.
//!
//! ## The App contract
//!
//! Required public decls (the existing component shape):
//!   - `Model`            — default-initializable, or expose `Model.init()`
//!   - `Msg`              — tagged union
//!   - `update(*Model, Msg) void`
//!   - `view(*const Model, *CmdBuffer(Msg)) void`
//!
//! Optional decls, each detected at comptime via `@hasDecl` — present
//! only the ones the app needs:
//!   - `keyCharMsg(*const Model, u8) ?Msg`            — typed character
//!   - `keySpecialMsg(*const Model, SpecialKey) ?Msg` — arrows/enter/etc
//!   - `keyNeedsClipboard(SpecialKey) bool`           — pairs with…
//!   - `handleClipboard(*Model, SpecialKey, Clipboard) void` — cut/copy/paste
//!   - `wheelMsg(*const Model, f32) ?Msg`             — vertical wheel
//!   - `focusedMsg(*const Model) ?Msg`                — the focus Msg of the
//!     currently-focused widget; `run` maps it to a cmd index via
//!     `indexOfFocusMsg` (stable across conditional/reordered widgets)
//!     to drive the focus ring + cursor blink. Also enables built-in
//!     Tab / Shift+Tab traversal between focusable widgets.
//!   - `submitMsg(*const Model) ?Msg`                 — dispatched on the
//!     Enter key (takes precedence over `keySpecialMsg` for Enter)
//!   - `themeFor(*const Model) Theme`                 — per-frame theme
//!   - `windowTitle(*const Model) ?[]const u8`        — dynamic title bar
//!
//! Anything the app omits is simply skipped — a static read-only view is
//! just `Model` / `Msg` / `update` / `view`.

const std = @import("std");

const cmd = @import("core/cmd.zig");
const transient = @import("core/transient.zig");
const text = @import("core/text.zig");
const theme_mod = @import("core/theme.zig");
const layout = @import("layout/engine.zig");
const hit_test = @import("input/hit_test.zig");
const focus = @import("input/focus.zig");
const keys = @import("input/keys.zig");
const render = @import("render/build.zig");
const vertex = @import("render/vertex.zig");

const Rect = layout.Rect;
const TransientState = transient.TransientState;

pub const RunOptions = struct {
    /// Scene clear color passed to `Gpu.renderFrame` each frame.
    clear_color: [4]f32 = .{ 0.08, 0.08, 0.1, 1.0 },
    /// Frames between forced vertex rebuilds while a widget is focused,
    /// so the text cursor blink animates. 0 disables the blink tick
    /// (apps with no text input pay nothing). The renderer toggles the
    /// cursor on a 30-frame phase, so 30 matches it.
    blink_period: u32 = 30,
};

/// Run the application against `host` + `gpu` until the host signals
/// close. `gpa` backs the per-frame command buffers, the rect store,
/// and the vertex/text/image upload lists (all bulk-managed, never
/// per-widget). `host` must satisfy `validateHost`, `gpu`
/// `validateGpu`; both are taken as `anytype` so `run` never imports a
/// backend.
pub fn run(
    comptime App: type,
    gpa: std.mem.Allocator,
    host: anytype,
    gpu: anytype,
    opts: RunOptions,
) !void {
    const Msg = App.Msg;
    const CmdBufT = cmd.CmdBuffer(Msg);

    var model: App.Model = if (@hasDecl(App.Model, "init")) App.Model.init() else .{};

    // Double-buffered command buffers: build into one while hit-testing
    // against the other (one-frame input latency, imperceptible).
    var bufs = [2]CmdBufT{ CmdBufT.init(gpa), CmdBufT.init(gpa) };
    defer for (&bufs) |*b| b.deinit();

    // Parallel rect store, one slice per buffer, grown to fit the frame
    // (no fixed MAX_RECTS cap — the examples panicked past theirs).
    var rects = [2]std.ArrayList(Rect){ .empty, .empty };
    defer for (&rects) |*r| r.deinit(gpa);

    var verts: std.ArrayList(vertex.Vertex) = .empty;
    defer verts.deinit(gpa);
    var text_draws: std.ArrayList(text.TextDraw) = .empty;
    defer text_draws.deinit(gpa);
    var image_draws: std.ArrayList(render.ImageDraw) = .empty;
    defer image_draws.deinit(gpa);

    var ts: TransientState = .{};
    var prev_ts: TransientState = .{};

    // Press model: arm `press_target` on mousedown over a widget; fire
    // the click only if mouseup lands on the same widget; drag-off
    // cancels without firing.
    var press_target: ?usize = null;

    const measurer = host.textMeasurer();

    // Last title pushed to the host, so we only call setTitle on change.
    var title_buf: [256]u8 = undefined;
    var title_len: usize = 0;

    var current: u1 = 0;

    while (!host.shouldClose()) {
        // 1. Drain input.
        const input = host.pollInputs();
        if (host.shouldClose()) break;

        // 2. Resize.
        if (input.resized) gpu.resize(input.width, input.height);

        // 3. Input against the PREVIOUS frame's layout (`prev` captured
        //    before the swap below).
        const prev = current;
        const prev_cmds = bufs[prev].cmds.items;
        const prev_rects = rects[prev].items;
        const hover: ?usize = if (prev_cmds.len > 0)
            hit_test.hoverTest(prev_cmds, prev_rects, input.mouse_x, input.mouse_y)
        else
            null;

        if (input.mouse_down) press_target = hover;
        if (input.mouse_up) {
            if (press_target != null and hover == press_target) {
                if (hit_test.hitTest(prev_cmds, prev_rects, input.mouse_x, input.mouse_y)) |hit| {
                    // `hit.msg` is null when a modal overlay consumed the
                    // click but asked for no Msg (HARDLINE §2 hatch 5) —
                    // swallow it, don't fall through.
                    if (hit.msg) |m| App.update(&model, m);
                }
            }
            press_target = null;
        }
        if (press_target != null and hover != press_target) press_target = null;

        // 4. Keyboard. Characters first, then special keys; clipboard
        //    chords route to the app's own handler with the Host
        //    clipboard vtable (the app owns cut/copy/paste policy).
        if (@hasDecl(App, "keyCharMsg")) {
            for (input.chars) |ch| {
                if (App.keyCharMsg(&model, ch)) |m| App.update(&model, m);
            }
        }
        for (input.keys) |k| {
            // Built-in Tab / Shift+Tab focus traversal — only for apps
            // that expose `focusedMsg` (so `run` knows the current focus
            // and how to move it). Walk the PREVIOUS frame's focusables
            // (the layout the user sees), then dispatch the landing
            // widget's focus Msg so the app advances its focus field.
            if (@hasDecl(App, "focusedMsg")) {
                if (k == .tab or k == .shift_tab) {
                    const cur_idx = if (App.focusedMsg(&model)) |fm|
                        focus.indexOfFocusMsg(prev_cmds, fm)
                    else
                        null;
                    const target = if (k == .tab)
                        focus.nextFocusable(prev_cmds, cur_idx)
                    else
                        focus.prevFocusable(prev_cmds, cur_idx);
                    if (target) |ti| {
                        if (focus.focusMsgAt(prev_cmds, ti)) |fm| App.update(&model, fm);
                    }
                    continue;
                }
            }
            // Enter-to-submit — apps opt in with `submitMsg`. Takes
            // precedence over `keySpecialMsg` for the Enter key only.
            if (@hasDecl(App, "submitMsg")) {
                if (k == .enter) {
                    if (App.submitMsg(&model)) |m| App.update(&model, m);
                    continue;
                }
            }
            const handled_by_clipboard = comptime (@hasDecl(App, "keyNeedsClipboard") and @hasDecl(App, "handleClipboard"));
            if (handled_by_clipboard and App.keyNeedsClipboard(k)) {
                App.handleClipboard(&model, k, host.clipboard());
            } else if (@hasDecl(App, "keySpecialMsg")) {
                if (App.keySpecialMsg(&model, k)) |m| App.update(&model, m);
            }
        }

        // 5. Wheel.
        if (@hasDecl(App, "wheelMsg")) {
            if (input.wheel_dy != 0 or input.wheel_dx != 0) {
                if (App.wheelMsg(&model, input.wheel_dy)) |m| App.update(&model, m);
            }
        }

        // 6. Build this frame into the other buffer.
        current ^= 1;
        const cur = current;
        bufs[cur].reset();
        if (@hasDecl(App, "themeFor")) bufs[cur].theme = App.themeFor(&model);
        App.view(&model, &bufs[cur]);
        const cur_cmds = bufs[cur].cmds.items;

        // 7. Layout into the matching rect slice (grown to fit).
        try rects[cur].resize(gpa, cur_cmds.len);
        layout.LayoutEngine.doLayout(
            rects[cur].items,
            cur_cmds,
            @floatFromInt(input.width),
            @floatFromInt(input.height),
            measurer,
        );

        // 8. Transient state against THIS frame's layout.
        ts.hover_index = hit_test.hoverTest(cur_cmds, rects[cur].items, input.mouse_x, input.mouse_y);
        ts.press_index = press_target;
        ts.focus_index = focusIndex(App, &model, cur_cmds);
        ts.mouse_x = input.mouse_x;
        ts.mouse_y = input.mouse_y;
        ts.frame_counter +%= 1;

        // 9. Dynamic window title (only on change).
        if (@hasDecl(App, "windowTitle")) {
            if (App.windowTitle(&model)) |t| {
                if (!std.mem.eql(u8, t, title_buf[0..title_len])) {
                    host.setTitle(t);
                    title_len = @min(t.len, title_buf.len);
                    @memcpy(title_buf[0..title_len], t[0..title_len]);
                }
            }
        }

        // 10. Frame diff — skip the vertex rebuild + upload when nothing
        //     observable changed. The blink tick forces a rebuild on a
        //     phase boundary so a focused cursor animates.
        const cmds_same = cmdsEqual(Msg, cur_cmds, bufs[prev].cmds.items);
        const rects_same = rectsEqual(rects[cur].items, rects[prev].items);
        const ts_same = ts.hover_index == prev_ts.hover_index and
            ts.press_index == prev_ts.press_index and
            ts.focus_index == prev_ts.focus_index;
        const blink_tick = opts.blink_period > 0 and ts.focus_index != null and
            (ts.frame_counter % opts.blink_period == 0);

        if (!cmds_same or !rects_same or !ts_same or blink_tick) {
            render.buildVertices(&verts, &text_draws, &image_draws, gpa, cur_cmds, rects[cur].items, ts, measurer);
            gpu.uploadVertices(verts.items);
            gpu.uploadText(text_draws.items);
            gpu.uploadImages(image_draws.items);
        }

        prev_ts = ts;

        // 11. Present.
        gpu.renderFrame(opts.clear_color);
    }
}

/// Resolve the focused widget's cmd index for this frame. Apps that
/// expose `focusedMsg` get stable, Msg-keyed focus (survives
/// conditional/reordered widgets); apps without it have no focus ring.
fn focusIndex(comptime App: type, model: *const App.Model, cmds: anytype) ?usize {
    if (!@hasDecl(App, "focusedMsg")) return null;
    const fm = App.focusedMsg(model) orelse return null;
    return focus.indexOfFocusMsg(cmds, fm);
}

// ── Frame diff ──────────────────────────────────────────────────────
//
// Shared with what every example's ui_main hand-rolled. Compares the
// observable content of two cmd buffers: tags, styles, and — for
// variants carrying slices — string/span content (not pointer identity,
// since the arena hands out fresh addresses each frame).

/// True if two cmd buffers would render identically.
pub fn cmdsEqual(comptime Msg: type, a: []const cmd.Cmd(Msg), b: []const cmd.Cmd(Msg)) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.meta.activeTag(ca) != std.meta.activeTag(cb)) return false;
        switch (ca) {
            .push_group => |g| if (!std.meta.eql(g, cb.push_group)) return false,
            .pop_group => {},
            .push_scroll => |s| if (!std.meta.eql(s, cb.push_scroll)) return false,
            .pop_scroll => {},
            .push_overlay => |o| if (!std.meta.eql(o, cb.push_overlay)) return false,
            .pop_overlay => {},
            .push_virtual_list => |v| if (!std.meta.eql(v, cb.push_virtual_list)) return false,
            .pop_virtual_list => {},
            .text => |t| {
                const o = cb.text;
                if (!std.mem.eql(u8, t.content, o.content)) return false;
                if (!std.meta.eql(t.font, o.font) or !std.meta.eql(t.color, o.color)) return false;
            },
            .button => |x| {
                const o = cb.button;
                if (!std.mem.eql(u8, x.label, o.label)) return false;
                if (!std.meta.eql(x.msg, o.msg)) return false;
                if (x.disabled != o.disabled) return false;
            },
            .text_input => |x| {
                const o = cb.text_input;
                if (x.cursor != o.cursor or x.selection_anchor != o.selection_anchor) return false;
                if (x.disabled != o.disabled) return false;
                if (!std.mem.eql(u8, x.content, o.content)) return false;
            },
            .checkbox => |x| {
                const o = cb.checkbox;
                if (x.checked != o.checked) return false;
                if (!std.mem.eql(u8, x.label, o.label)) return false;
                if (!std.meta.eql(x.msg, o.msg)) return false;
            },
            .radio => |x| {
                const o = cb.radio;
                if (x.selected != o.selected) return false;
                if (!std.mem.eql(u8, x.label, o.label)) return false;
                if (!std.meta.eql(x.msg, o.msg)) return false;
            },
            .slider => |x| if (x.value != cb.slider.value) return false,
            .divider => |d| if (!std.meta.eql(d, cb.divider)) return false,
            .image => |im| if (!std.meta.eql(im, cb.image)) return false,
            .rich_text => |rt| {
                const o = cb.rich_text;
                if (!std.mem.eql(u8, rt.content, o.content)) return false;
                if (rt.spans.len != o.spans.len) return false;
                for (rt.spans, o.spans) |sa, sb| if (!std.meta.eql(sa, sb)) return false;
            },
        }
    }
    return true;
}

/// True if two rect slices are identical (position + size only).
pub fn rectsEqual(a: []const Rect, b: []const Rect) bool {
    if (a.len != b.len) return false;
    for (a, b) |ra, rb| {
        if (ra.x != rb.x or ra.y != rb.y or ra.w != rb.w or ra.h != rb.h) return false;
    }
    return true;
}

// ── Tests ───────────────────────────────────────────────────────────
//
// Driven by a headless Host + Gpu so the whole loop runs under
// `zig build test` with no window or GPU. The stub Host scripts a click
// over a button across frames; the stub Gpu counts the calls `run`
// makes.

const host_iface = @import("platform/host.zig");
const InputState = host_iface.InputState;
const Clipboard = host_iface.Clipboard;

const TestApp = struct {
    pub const Model = struct { count: i32 = 0 };
    pub const Msg = union(enum) { click };
    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .click => m.count += 1,
        }
    }
    pub fn view(_: *const Model, cb: anytype) void {
        // Root group with zero padding so the button sits at the origin
        // with intrinsic size (~60x36 under the mono measurer) — a click
        // at (5,5) lands on it. (A view must start with a container;
        // `doLayout` treats cmds[0] as the root and positionPass expects
        // every leaf to have a parent on the stack.)
        cb.pushGroup(.{ .padding = 0, .gap = 0 });
        cb.button(.click, "X");
        cb.popGroup();
    }
};

/// Scripts: frame 1 idle (populates prev), frame 2 mousedown over the
/// button, frame 3 mouseup over the button (fires .click), frame 4
/// closes. All at (5,5) except frame 1 which parks the cursor off-widget.
const StubHost = struct {
    frame: u32 = 0,
    closed: bool = false,

    pub fn deinit(_: *StubHost) void {}
    pub fn shouldClose(self: *const StubHost) bool {
        return self.closed;
    }
    pub fn pollInputs(self: *StubHost) InputState {
        self.frame += 1;
        var in = std.mem.zeroes(InputState);
        in.width = 200;
        in.height = 100;
        in.mouse_x = 5;
        in.mouse_y = 5;
        switch (self.frame) {
            1 => {
                in.mouse_x = -10;
                in.mouse_y = -10;
                in.resized = true;
            },
            2 => in.mouse_down = true,
            3 => in.mouse_up = true,
            else => self.closed = true,
        }
        in.chars = &.{};
        in.keys = &.{};
        return in;
    }
    pub fn nativeHandle(_: *const StubHost) void {}
    pub fn textMeasurer(_: *StubHost) text.TextMeasurer {
        return text.monoMeasurer();
    }
    pub fn clipboard(_: *StubHost) Clipboard {
        return .{ .ctx = undefined, .read_fn = stubRead, .write_fn = stubWrite };
    }
    fn stubRead(_: *anyopaque) []const u8 {
        return "";
    }
    fn stubWrite(_: *anyopaque, _: []const u8) void {}
    pub fn imeState(_: *const StubHost) host_iface.ImeState {
        return .{};
    }
    pub fn publishA11yTree(_: *StubHost, _: []const host_iface.A11yNode) void {}
    pub fn openFileDialog(_: *StubHost, _: host_iface.FileDialogFilter) host_iface.FileDialogResult {
        return null;
    }
    pub fn saveFileDialog(_: *StubHost, _: host_iface.FileDialogFilter) host_iface.FileDialogResult {
        return null;
    }
    pub fn openSecondaryWindow(_: *StubHost, _: []const u8, _: u32, _: u32) ?u32 {
        return null;
    }
    pub fn setTitle(_: *StubHost, _: []const u8) void {}
    pub fn nowMs(_: *const StubHost) u64 {
        return 0;
    }
};

const StubGpu = struct {
    resize_calls: u32 = 0,
    upload_vert_calls: u32 = 0,
    render_calls: u32 = 0,

    pub fn deinit(_: *StubGpu) void {}
    pub fn resize(self: *StubGpu, _: u32, _: u32) void {
        self.resize_calls += 1;
    }
    pub fn uploadVertices(self: *StubGpu, _: []const vertex.Vertex) void {
        self.upload_vert_calls += 1;
    }
    pub fn uploadText(_: *StubGpu, _: []const text.TextDraw) void {}
    pub fn uploadImages(_: *StubGpu, _: []const render.ImageDraw) void {}
    pub fn renderFrame(self: *StubGpu, _: [4]f32) void {
        self.render_calls += 1;
    }
    pub fn rasterizeText(_: *StubGpu, _: []const u8, _: text.FontSpec, _: [4]f32, _: u32, _: u32) text.TextureHandle {
        return text.TEXTURE_HANDLE_NONE;
    }
    pub fn uploadImage(_: *StubGpu, _: []const u8, _: u32, _: u32) text.TextureHandle {
        return text.TEXTURE_HANDLE_NONE;
    }
};

test "run: drives the loop, routes a click through update, presents each frame" {
    // Sanity: the stubs satisfy the real comptime contracts.
    comptime host_iface.validateHost(StubHost);
    comptime @import("gpu/context.zig").validateGpu(StubGpu);

    var host: StubHost = .{};
    var gpu: StubGpu = .{};

    try run(TestApp, std.testing.allocator, &host, &gpu, .{});

    // The scripted mousedown(frame2)+mouseup(frame3) over the button
    // fired exactly one .click.
    // (We can't read model here — run owns it — so assert via the side
    //  effects the stubs recorded plus the loop's own invariants.)
    try std.testing.expectEqual(@as(u32, 1), gpu.resize_calls); // frame 1 resized
    // renderFrame runs once per loop iteration that didn't early-break:
    // frames 1,2,3 present; frame 4 sets closed and breaks before render.
    try std.testing.expectEqual(@as(u32, 3), gpu.render_calls);
    try std.testing.expect(host.frame >= 4);
}

test "run: model state is observable through an app-held side channel" {
    // Same loop, but the app records its own count into a module-level
    // sink so the test can assert the click actually mutated Model.
    const Sink = struct {
        var count: i32 = -1;
    };
    const App = struct {
        pub const Model = struct { count: i32 = 0 };
        pub const Msg = union(enum) { click };
        pub fn update(m: *Model, msg: Msg) void {
            switch (msg) {
                .click => m.count += 1,
            }
            Sink.count = m.count;
        }
        pub fn view(_: *const Model, cb: anytype) void {
            cb.pushGroup(.{ .padding = 0, .gap = 0 });
            cb.button(.click, "X");
            cb.popGroup();
        }
    };

    var host: StubHost = .{};
    var gpu: StubGpu = .{};
    Sink.count = -1;
    try run(App, std.testing.allocator, &host, &gpu, .{});
    try std.testing.expectEqual(@as(i32, 1), Sink.count);
}

/// Scripts keyboard input: frame 1 idle, frame 2 delivers chars "Hi",
/// frame 3 a backspace special key, frame 4 closes. Exercises the
/// `keyCharMsg` / `keySpecialMsg` forwarding paths.
const KeyHost = struct {
    frame: u32 = 0,
    closed: bool = false,
    char_storage: [2]u8 = .{ 'H', 'i' },
    key_storage: [1]keys.SpecialKey = .{.backspace},

    pub fn deinit(_: *KeyHost) void {}
    pub fn shouldClose(self: *const KeyHost) bool {
        return self.closed;
    }
    pub fn pollInputs(self: *KeyHost) InputState {
        self.frame += 1;
        var in = std.mem.zeroes(InputState);
        in.width = 200;
        in.height = 100;
        in.mouse_x = -10;
        in.mouse_y = -10;
        in.chars = &.{};
        in.keys = &.{};
        switch (self.frame) {
            1 => in.resized = true,
            2 => in.chars = self.char_storage[0..],
            3 => in.keys = self.key_storage[0..],
            else => self.closed = true,
        }
        return in;
    }
    pub fn nativeHandle(_: *const KeyHost) void {}
    pub fn textMeasurer(_: *KeyHost) text.TextMeasurer {
        return text.monoMeasurer();
    }
    pub fn clipboard(_: *KeyHost) Clipboard {
        return .{ .ctx = undefined, .read_fn = StubHost.stubRead, .write_fn = StubHost.stubWrite };
    }
    pub fn imeState(_: *const KeyHost) host_iface.ImeState {
        return .{};
    }
    pub fn publishA11yTree(_: *KeyHost, _: []const host_iface.A11yNode) void {}
    pub fn openFileDialog(_: *KeyHost, _: host_iface.FileDialogFilter) host_iface.FileDialogResult {
        return null;
    }
    pub fn saveFileDialog(_: *KeyHost, _: host_iface.FileDialogFilter) host_iface.FileDialogResult {
        return null;
    }
    pub fn openSecondaryWindow(_: *KeyHost, _: []const u8, _: u32, _: u32) ?u32 {
        return null;
    }
    pub fn setTitle(_: *KeyHost, _: []const u8) void {}
    pub fn nowMs(_: *const KeyHost) u64 {
        return 0;
    }
};

test "run: routes typed chars + special keys through the optional hooks" {
    const Sink = struct {
        var typed: [8]u8 = undefined;
        var typed_len: usize = 0;
        var backspaces: u32 = 0;
        var theme_was_read: bool = false;
    };
    const App = struct {
        pub const Model = struct { focused: bool = true };
        pub const Msg = union(enum) { char: u8, backspace };
        pub fn update(_: *Model, msg: Msg) void {
            switch (msg) {
                .char => |c| {
                    Sink.typed[Sink.typed_len] = c;
                    Sink.typed_len += 1;
                },
                .backspace => Sink.backspaces += 1,
            }
        }
        pub fn view(_: *const Model, cb: anytype) void {
            // Read theme so themeFor's effect is observable, then emit a
            // focusable input inside a root group.
            Sink.theme_was_read = cb.theme.typography.body.size_px > 0;
            cb.pushGroup(.{ .padding = 0, .gap = 0 });
            cb.textInput(.{ .char = 0 }, "", 0);
            cb.popGroup();
        }
        pub fn keyCharMsg(m: *const Model, c: u8) ?Msg {
            return if (m.focused) Msg{ .char = c } else null;
        }
        pub fn keySpecialMsg(m: *const Model, k: keys.SpecialKey) ?Msg {
            if (!m.focused) return null;
            return switch (k) {
                .backspace => Msg.backspace,
                else => null,
            };
        }
        pub fn themeFor(_: *const Model) theme_mod.Theme {
            return theme_mod.Theme.light_default;
        }
    };

    Sink.typed_len = 0;
    Sink.backspaces = 0;
    Sink.theme_was_read = false;

    var host: KeyHost = .{};
    var gpu: StubGpu = .{};
    try run(App, std.testing.allocator, &host, &gpu, .{});

    try std.testing.expectEqualStrings("Hi", Sink.typed[0..Sink.typed_len]);
    try std.testing.expectEqual(@as(u32, 1), Sink.backspaces);
    try std.testing.expect(Sink.theme_was_read);
}

/// Scripts: frame 1 idle, frames 2-3 each a Tab, frame 4 Enter, frame 5
/// close. Exercises built-in Tab traversal + Enter-to-submit.
const TabHost = struct {
    frame: u32 = 0,
    closed: bool = false,
    tab: [1]keys.SpecialKey = .{.tab},
    enter: [1]keys.SpecialKey = .{.enter},

    pub fn deinit(_: *TabHost) void {}
    pub fn shouldClose(self: *const TabHost) bool {
        return self.closed;
    }
    pub fn pollInputs(self: *TabHost) InputState {
        self.frame += 1;
        var in = std.mem.zeroes(InputState);
        in.width = 300;
        in.height = 200;
        in.mouse_x = -10;
        in.mouse_y = -10;
        in.chars = &.{};
        in.keys = &.{};
        switch (self.frame) {
            1 => in.resized = true,
            2, 3 => in.keys = self.tab[0..],
            4 => in.keys = self.enter[0..],
            else => self.closed = true,
        }
        return in;
    }
    pub fn nativeHandle(_: *const TabHost) void {}
    pub fn textMeasurer(_: *TabHost) text.TextMeasurer {
        return text.monoMeasurer();
    }
    pub fn clipboard(_: *TabHost) Clipboard {
        return .{ .ctx = undefined, .read_fn = StubHost.stubRead, .write_fn = StubHost.stubWrite };
    }
    pub fn imeState(_: *const TabHost) host_iface.ImeState {
        return .{};
    }
    pub fn publishA11yTree(_: *TabHost, _: []const host_iface.A11yNode) void {}
    pub fn openFileDialog(_: *TabHost, _: host_iface.FileDialogFilter) host_iface.FileDialogResult {
        return null;
    }
    pub fn saveFileDialog(_: *TabHost, _: host_iface.FileDialogFilter) host_iface.FileDialogResult {
        return null;
    }
    pub fn openSecondaryWindow(_: *TabHost, _: []const u8, _: u32, _: u32) ?u32 {
        return null;
    }
    pub fn setTitle(_: *TabHost, _: []const u8) void {}
    pub fn nowMs(_: *const TabHost) u64 {
        return 0;
    }
};

test "run: Tab advances focus across inputs and Enter fires submitMsg" {
    const Sink = struct {
        var final_focus: u8 = 255;
        var submitted: bool = false;
    };
    const App = struct {
        pub const Focus = enum(u8) { none = 0, a = 1, b = 2 };
        pub const Model = struct { focus: Focus = .none };
        pub const Msg = union(enum) { focus_a, focus_b, submit };
        pub fn update(m: *Model, msg: Msg) void {
            switch (msg) {
                .focus_a => m.focus = .a,
                .focus_b => m.focus = .b,
                .submit => Sink.submitted = true,
            }
            Sink.final_focus = @intFromEnum(m.focus);
        }
        pub fn view(_: *const Model, cb: anytype) void {
            cb.pushGroup(.{ .direction = .vertical });
            cb.textInput(.focus_a, "", 0);
            cb.textInput(.focus_b, "", 0);
            cb.popGroup();
        }
        pub fn focusedMsg(m: *const Model) ?Msg {
            return switch (m.focus) {
                .none => null,
                .a => Msg.focus_a,
                .b => Msg.focus_b,
            };
        }
        pub fn submitMsg(_: *const Model) ?Msg {
            return Msg.submit;
        }
    };

    Sink.final_focus = 255;
    Sink.submitted = false;

    var host: TabHost = .{};
    var gpu: StubGpu = .{};
    try run(App, std.testing.allocator, &host, &gpu, .{});

    // Frame 2 Tab: none -> first input (a). Frame 3 Tab: a -> b.
    try std.testing.expectEqual(@as(u8, @intFromEnum(App.Focus.b)), Sink.final_focus);
    // Frame 4 Enter fired submitMsg.
    try std.testing.expect(Sink.submitted);
}

test "cmdsEqual: detects label, disabled, and length changes" {
    const Msg = union(enum) { a };
    var x = cmd.CmdBuffer(Msg).init(std.testing.allocator);
    defer x.deinit();
    var y = cmd.CmdBuffer(Msg).init(std.testing.allocator);
    defer y.deinit();

    x.button(.a, "Go");
    y.button(.a, "Go");
    try std.testing.expect(cmdsEqual(Msg, x.cmds.items, y.cmds.items));

    // Different label.
    y.reset();
    y.button(.a, "No");
    try std.testing.expect(!cmdsEqual(Msg, x.cmds.items, y.cmds.items));

    // Same label, different disabled state.
    y.reset();
    y.buttonDisabled(.a, "Go");
    try std.testing.expect(!cmdsEqual(Msg, x.cmds.items, y.cmds.items));

    // Different length.
    y.reset();
    y.button(.a, "Go");
    y.button(.a, "Go");
    try std.testing.expect(!cmdsEqual(Msg, x.cmds.items, y.cmds.items));
}
