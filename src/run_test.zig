//! Tests for the canonical loop (`run.zig`): the whole `Runtime` is driven
//! headlessly by a scripted Host and a counting Gpu, so a click, a key, a
//! timer or a drag is one line of script and the assertions read the
//! finished Runtime (`t.rt.model`, `t.gpu`, `t.host`) — no statics.
//!
//! Input is routed against the PREVIOUS frame's layout, so frame 1 only
//! builds the view; real pointer events start at frame 2.

const std = @import("std");

const run_mod = @import("run.zig");
const cmd = @import("core/cmd.zig");
const pointer = @import("core/pointer.zig");
const sub_mod = @import("core/sub.zig");
const text = @import("core/text.zig");
const theme_mod = @import("core/theme.zig");
const keys = @import("input/keys.zig");
const render = @import("render/build.zig");
const vertex = @import("render/vertex.zig");
const scene = @import("core/scene.zig");
const resources_mod = @import("core/resources.zig");
const host_iface = @import("platform/host.zig");
const gpu_iface = @import("gpu/context.zig");

const commands_mod = @import("core/commands.zig");
const Runtime = run_mod.Runtime;
const SecondaryWindowSpec = run_mod.SecondaryWindowSpec;
const cmdsEqual = run_mod.cmdsEqual;
const InputState = host_iface.InputState;

// ── Scripted Host + counting Gpu ────────────────────────────────────

/// One frame of scripted input.
pub const Frame = struct {
    x: f32 = -10,
    y: f32 = -10,
    /// Buttons held after this frame's events.
    held: pointer.Buttons = .{},
    down: pointer.Buttons = .{},
    up: pointer.Buttons = .{},
    mods: pointer.Modifiers = .{},
    wheel_dx: f32 = 0,
    wheel_dy: f32 = 0,
    chars: []const u8 = "",
    keys: []const keys.SpecialKey = &.{},
    chords: []const keys.Chord = &.{},
    /// Sets the Host clock (`nowMs`) from this frame on.
    clock_ms: ?u64 = null,
    /// Starts / updates an IME composition from this frame on. Written IN
    /// PLACE into one shared buffer, like a real Host's global.
    ime: ?[]const u8 = null,
    /// A result the Host receives at the start of this frame, as if it had
    /// arrived asynchronously (an unsolicited drop or paste, or a scripted
    /// answer to an effect). Delivered by `pollEffectResults` after the
    /// frame's key routing.
    fx_result: ?host_iface.EffectResult = null,
    /// Assistive-technology requests the Host reports at the start of this
    /// frame (delivered by `pollA11yActions`).
    a11y: []const host_iface.A11yAction = &.{},
};

const left: pointer.Buttons = .{ .left = true };
const right: pointer.Buttons = .{ .right = true };
const both: pointer.Buttons = .{ .left = true, .right = true };

/// Plays `script` one frame per `pollInputs`, then reports close. The
/// secondary-window methods are scripted by `secondary_polls`.
pub const ScriptHost = struct {
    script: []const Frame,
    next: usize = 0,
    width: u32 = 400,
    height: u32 = 300,
    clock_ms: u64 = 0,
    set_title_calls: u32 = 0,
    cursor_calls: u32 = 0,
    cursor: host_iface.CursorShape = .arrow,
    ime_buf: [8]u8 = undefined,
    ime_len: usize = 0,
    ime_on: bool = false,
    /// Optional IME extensions: how often the runtime called them, and the last state.
    ime_active_calls: u32 = 0,
    ime_active_last: bool = false,
    ime_spot_calls: u32 = 0,
    /// null: no secondary window support (`openSecondaryWindow` returns
    /// null). Otherwise window id 1 opens and its poll yields input this many
    /// times, then null (the user closed it from the OS).
    secondary_polls: ?u32 = null,
    secondary_polled: u32 = 0,

    // Declarative-effects extension (`submit` / `pollEffectResults`).
    /// What `submit` answers.
    fx_mode: host_iface.EffectSubmit = .accepted,
    /// Every effect `submit` was offered (accepted or not), in order. The
    /// slices inside borrow from the test's statics.
    fx_submitted: [64]host_iface.Effect = undefined,
    fx_submitted_n: usize = 0,
    /// Answer accepted `http` / `storage_get` / `clock` / `query_param`
    /// requests on the next poll, like a real async host.
    fx_auto_answer: bool = false,
    /// Results waiting for the next `pollEffectResults`.
    fx_queue: [32]host_iface.EffectResult = undefined,
    fx_queue_n: usize = 0,

    // Recording a11y bridge: every published tree is copied here.
    a11y_publishes: u32 = 0,
    a11y_nodes: [64]host_iface.A11yNode = undefined,
    a11y_count: usize = 0,
    a11y_bytes: [4096]u8 = undefined,
    /// Actions the current frame reports.
    a11y_pending: []const host_iface.A11yAction = &.{},
    /// Clipboard: what a paste reads, and the last text a copy wrote.
    clip_in: []const u8 = "",
    clip_out: [64]u8 = undefined,
    clip_out_len: usize = 0,
    clip_writes: u32 = 0,
    /// `waitEvents` calls from `run` after quiet frames, and the last timeout.
    wait_calls: u32 = 0,
    last_wait_ms: u32 = 0,

    pub const NativeHandle = struct { tag: u32 = 7 };
    const forever = std.math.maxInt(u32);

    pub fn deinit(_: *ScriptHost) void {}
    pub fn waitEvents(self: *ScriptHost, timeout_ms: u32) void {
        self.wait_calls += 1;
        self.last_wait_ms = timeout_ms;
    }
    pub fn shouldClose(self: *const ScriptHost) bool {
        return self.next > self.script.len;
    }
    pub fn pollInputs(self: *ScriptHost) InputState {
        defer self.next += 1;
        var in = std.mem.zeroes(InputState);
        in.width = self.width;
        in.height = self.height;
        if (self.next >= self.script.len) return in; // past the end: the loop closes
        const f = self.script[self.next];
        if (f.clock_ms) |t| self.clock_ms = t;
        if (f.ime) |t| {
            @memcpy(self.ime_buf[0..t.len], t);
            self.ime_len = t.len;
            self.ime_on = true;
        }
        in.resized = self.next == 0;
        in.mouse_x = f.x;
        in.mouse_y = f.y;
        in.buttons = f.held;
        in.button_down = f.down;
        in.button_up = f.up;
        in.mouse_down = f.down.left;
        in.mouse_up = f.up.left;
        in.mods = f.mods;
        in.wheel_dx = f.wheel_dx;
        in.wheel_dy = f.wheel_dy;
        in.chars = f.chars;
        in.keys = f.keys;
        in.chords = f.chords;
        if (f.fx_result) |r| self.queueResult(r);
        self.a11y_pending = f.a11y;
        return in;
    }
    pub fn queueResult(self: *ScriptHost, r: host_iface.EffectResult) void {
        self.fx_queue[self.fx_queue_n] = r;
        self.fx_queue_n += 1;
    }
    pub fn submit(self: *ScriptHost, e: host_iface.Effect) host_iface.EffectSubmit {
        self.fx_submitted[self.fx_submitted_n] = e;
        self.fx_submitted_n += 1;
        if (self.fx_mode != .accepted) return self.fx_mode;
        if (self.fx_auto_answer) switch (e) {
            .http => |r| self.queueResult(.{ .http = .{ .id = r.id, .status = 200, .body = "pong" } }),
            .storage_get => |r| self.queueResult(.{ .storage_value = .{ .id = r.id, .value = "stored" } }),
            .clock => |r| self.queueResult(.{ .clock = .{ .id = r.id, .unix_ms = 1_700_000_000_000, .utc_offset_min = 60 } }),
            .query_param => |r| self.queueResult(.{ .query_value = .{ .id = r.id, .value = "v" } }),
            else => {},
        };
        return .accepted;
    }
    pub fn pollEffectResults(self: *ScriptHost, buf: []host_iface.EffectResult) usize {
        const n = @min(buf.len, self.fx_queue_n);
        @memcpy(buf[0..n], self.fx_queue[0..n]);
        std.mem.copyForwards(host_iface.EffectResult, self.fx_queue[0 .. self.fx_queue_n - n], self.fx_queue[n..self.fx_queue_n]);
        self.fx_queue_n -= n;
        return n;
    }
    pub fn nativeHandle(_: *const ScriptHost) void {}
    pub fn textMeasurer(_: *ScriptHost) text.TextMeasurer {
        return text.monoMeasurer();
    }
    pub fn clipboard(self: *ScriptHost) host_iface.Clipboard {
        return .{ .ctx = @ptrCast(self), .read_fn = clipRead, .write_fn = clipWrite };
    }
    fn clipRead(ctx: *anyopaque) []const u8 {
        const self: *ScriptHost = @ptrCast(@alignCast(ctx));
        return self.clip_in;
    }
    /// Records the last text written (what the loop copied), for assertions.
    fn clipWrite(ctx: *anyopaque, bytes: []const u8) void {
        const self: *ScriptHost = @ptrCast(@alignCast(ctx));
        const n = @min(bytes.len, self.clip_out.len);
        @memcpy(self.clip_out[0..n], bytes[0..n]);
        self.clip_out_len = n;
        self.clip_writes += 1;
    }
    fn writeDiscard(_: *anyopaque, _: []const u8) void {}
    pub fn setImeActive(self: *ScriptHost, active: bool) void {
        self.ime_active_calls += 1;
        self.ime_active_last = active;
    }
    pub fn setImeSpot(self: *ScriptHost, _: i32, _: i32) void {
        self.ime_spot_calls += 1;
    }
    pub fn imeState(self: *const ScriptHost) host_iface.ImeState {
        return .{ .active = self.ime_on, .text = self.ime_buf[0..self.ime_len], .cursor = self.ime_len };
    }
    pub fn publishA11yTree(self: *ScriptHost, nodes: []const host_iface.A11yNode) void {
        self.a11y_publishes += 1;
        self.a11y_count = @min(nodes.len, self.a11y_nodes.len);
        var used: usize = 0;
        for (nodes[0..self.a11y_count], 0..) |n, i| {
            var c = n;
            const lo = used;
            @memcpy(self.a11y_bytes[used..][0..n.label.len], n.label);
            used += n.label.len;
            const vo = used;
            @memcpy(self.a11y_bytes[used..][0..n.value.len], n.value);
            used += n.value.len;
            c.label = self.a11y_bytes[lo..vo];
            c.value = self.a11y_bytes[vo..used];
            self.a11y_nodes[i] = c;
        }
    }
    pub fn pollA11yActions(self: *ScriptHost, out: []host_iface.A11yAction) usize {
        const n = @min(out.len, self.a11y_pending.len);
        @memcpy(out[0..n], self.a11y_pending[0..n]);
        self.a11y_pending = &.{};
        return n;
    }
    pub fn openFileDialog(_: *ScriptHost, _: host_iface.FileDialogFilter) host_iface.FileDialogResult {
        return null;
    }
    pub fn saveFileDialog(_: *ScriptHost, _: host_iface.FileDialogFilter) host_iface.FileDialogResult {
        return null;
    }
    pub fn requestFileDialog(_: *ScriptHost, _: host_iface.FileDialogFilter) u32 {
        return 0;
    }
    pub fn requestSaveFileDialog(_: *ScriptHost, _: host_iface.FileDialogFilter) u32 {
        return 0;
    }
    pub fn pollFileDialogResult(_: *ScriptHost, _: u32) host_iface.FileDialogPoll {
        return .{ .pending = {} };
    }
    pub fn openSecondaryWindow(self: *ScriptHost, _: []const u8, _: u32, _: u32) ?u32 {
        return if (self.secondary_polls != null) 1 else null;
    }
    pub fn secondaryWindowHandle(self: *const ScriptHost, _: u32) ?NativeHandle {
        return if (self.secondary_polls != null) .{} else null;
    }
    pub fn pollSecondaryInputs(self: *ScriptHost, _: u32) ?InputState {
        const limit = self.secondary_polls orelse return null;
        if (self.secondary_polled >= limit) return null;
        self.secondary_polled += 1;
        var in = std.mem.zeroes(InputState);
        in.width = 360;
        in.height = 200;
        return in;
    }
    pub fn closeSecondaryWindow(_: *ScriptHost, _: u32) void {}
    pub fn setCursor(self: *ScriptHost, shape: host_iface.CursorShape) void {
        self.cursor_calls += 1;
        self.cursor = shape;
    }
    pub fn setTitle(self: *ScriptHost, _: []const u8) void {
        self.set_title_calls += 1;
    }
    pub fn nowMs(self: *const ScriptHost) u64 {
        return self.clock_ms;
    }
};

/// Counts what the loop asks of a Gpu, including the secondary-surface
/// extensions that sit outside `validateGpu`.
pub const StubGpu = struct {
    resize_calls: u32 = 0,
    upload_vert_calls: u32 = 0,
    render_calls: u32 = 0,
    last_clear: [4]f32 = .{ 0, 0, 0, 0 },
    secondary_opened: u32 = 0,
    secondary_rendered: u32 = 0,
    secondary_closed: u32 = 0,

    // Scene / resource extension: handles are handed out from 100 so a
    // test can tell a backend handle from an app key.
    next_handle: u32 = 100,
    mesh_uploads: u32 = 0,
    image_uploads: u32 = 0,
    mesh_releases: u32 = 0,
    image_releases: u32 = 0,
    scene_calls: u32 = 0,
    last_scene_mesh: u32 = 0,
    last_scene_count: usize = 0,
    last_image_handle: u32 = 0,
    last_split: ?render.OverlaySplit = null,

    pub fn deinit(_: *StubGpu) void {}
    pub fn resize(self: *StubGpu, _: u32, _: u32) void {
        self.resize_calls += 1;
    }
    pub fn uploadVertices(self: *StubGpu, _: []const vertex.Vertex) void {
        self.upload_vert_calls += 1;
    }
    pub fn uploadText(_: *StubGpu, _: []const text.TextDraw) void {}
    pub fn uploadImages(self: *StubGpu, d: []const render.ImageDraw) void {
        if (d.len > 0) self.last_image_handle = d[0].handle;
    }
    pub fn setOverlayStart(self: *StubGpu, split: render.OverlaySplit) void {
        self.last_split = split;
    }
    pub fn uploadMesh(self: *StubGpu, _: scene.MeshData) u32 {
        self.mesh_uploads += 1;
        return self.takeHandle();
    }
    pub fn releaseMesh(self: *StubGpu, _: u32) void {
        self.mesh_releases += 1;
    }
    pub fn releaseImage(self: *StubGpu, _: u32) void {
        self.image_releases += 1;
    }
    pub fn renderScenes(self: *StubGpu, d: []const render.SceneDraw, _: render.SceneData) void {
        self.scene_calls += 1;
        self.last_scene_count = d.len;
        if (d.len > 0) self.last_scene_mesh = d[0].mesh;
    }
    fn takeHandle(self: *StubGpu) u32 {
        defer self.next_handle += 1;
        return self.next_handle;
    }
    pub fn renderFrame(self: *StubGpu, clear: [4]f32) void {
        self.render_calls += 1;
        self.last_clear = clear;
    }
    pub fn rasterizeText(_: *StubGpu, _: []const u8, _: text.FontSpec, _: [4]f32, _: u32, _: u32) text.TextureHandle {
        return text.TEXTURE_HANDLE_NONE;
    }
    pub fn uploadImage(self: *StubGpu, _: []const u8, _: u32, _: u32) text.TextureHandle {
        self.image_uploads += 1;
        return self.takeHandle();
    }
    pub fn openSecondarySurface(self: *StubGpu, _: anytype, _: u32, _: u32) ?u32 {
        self.secondary_opened += 1;
        return 1;
    }
    pub fn closeSecondarySurface(self: *StubGpu, _: u32) void {
        self.secondary_closed += 1;
    }
    pub fn resizeWindow(_: *StubGpu, _: u32, _: u32, _: u32) void {}
    pub fn renderToWindow(self: *StubGpu, _: u32, _: [4]f32) void {
        self.secondary_rendered += 1;
    }
};

/// A finished run: the Runtime plus the Host and Gpu it drove. Heap-allocated
/// because the Runtime points at its Host and Gpu, so none may move.
pub fn Played(comptime App: type) type {
    return struct {
        host: ScriptHost,
        gpu: StubGpu,
        rt: Runtime(App, ScriptHost, StubGpu),

        pub fn destroy(self: *@This()) void {
            self.rt.deinit();
            std.testing.allocator.destroy(self);
        }
    };
}

/// Drive `App` through `host`'s script to the end.
pub fn playWith(comptime App: type, host: ScriptHost, opts: run_mod.RunOptions) !*Played(App) {
    const p = try begin(App, host, opts);
    errdefer p.destroy();
    while (!p.host.shouldClose()) try p.rt.frame();
    return p;
}

/// Build the Runtime without running it, for tests that step `rt.frame()`
/// by hand and change the Model in between.
pub fn begin(comptime App: type, host: ScriptHost, opts: run_mod.RunOptions) !*Played(App) {
    const p = try std.testing.allocator.create(Played(App));
    errdefer std.testing.allocator.destroy(p);
    p.host = host;
    p.gpu = .{};
    p.rt = try Runtime(App, ScriptHost, StubGpu).init(std.testing.allocator, &p.host, &p.gpu, opts);
    return p;
}

pub fn play(comptime App: type, script: []const Frame) !*Played(App) {
    return playWith(App, .{ .script = script }, .{});
}

test "the scripted stubs satisfy the real Host / Gpu contracts" {
    comptime host_iface.validateHost(ScriptHost);
    comptime gpu_iface.validateGpu(StubGpu);
}

// ── Click, keys, focus ──────────────────────────────────────────────

const ClickApp = struct {
    pub const Model = struct { count: i32 = 0 };
    pub const Msg = union(enum) { click };
    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .click => m.count += 1,
        }
    }
    pub fn view(_: *const Model, cb: anytype) void {
        // Root group with zero padding so the button sits at the origin
        // with intrinsic size (~60x36 under the mono measurer) — a click at
        // (5,5) lands on it. (A view must start with a container.)
        cb.pushGroup(.{ .padding = 0, .gap = 0 });
        cb.button(.click, "X");
        cb.popGroup();
    }
};

test "run: a click routes through update and the loop presents each frame" {
    const t = try play(ClickApp, &.{
        .{}, // 1: idle (populates the layout input is routed against)
        .{ .x = 5, .y = 5, .held = left, .down = left }, // 2: press on the button
        .{ .x = 5, .y = 5, .up = left }, // 3: release on it -> click
    });
    defer t.destroy();
    try std.testing.expectEqual(@as(i32, 1), t.rt.model.count);
    try std.testing.expectEqual(@as(u32, 1), t.gpu.resize_calls); // frame 1 resized
    // The 4th poll reports close before rendering: frames 1-3 present.
    try std.testing.expectEqual(@as(u32, 3), t.gpu.render_calls);
}

test "run: drag-off cancels the click" {
    const t = try play(ClickApp, &.{
        .{},
        .{ .x = 5, .y = 5, .held = left, .down = left },
        .{ .x = 150, .y = 90, .held = left }, // dragged off the button
        .{ .x = 5, .y = 5, .up = left }, // released back over it: press was cancelled
    });
    defer t.destroy();
    try std.testing.expectEqual(@as(i32, 0), t.rt.model.count);
}

const HookApp = struct {
    pub const Model = struct {
        hovers: u32 = 0,
        hovered_a: bool = false,
        last_box: pointer.Box = .{},
        last_now: u64 = 0,
        contexts: u32 = 0,
        ctx_on_a: bool = false,
        ctx_x: f32 = -1,
    };
    pub const Msg = union(enum) { a, b, hover: ?u8, ctx: struct { on_a: bool, x: f32 } };
    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .a, .b => {},
            .hover => |h| {
                m.hovers += 1;
                m.hovered_a = h != null and h.? == 'a';
            },
            .ctx => |c| {
                m.contexts += 1;
                m.ctx_on_a = c.on_a;
                m.ctx_x = c.x;
            },
        }
    }
    pub fn view(_: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .padding = 0, .gap = 0, .direction = .vertical });
        cb.button(.a, "A");
        cb.button(.b, "B");
        cb.popGroup();
    }
    pub fn hoverMsg(_: *const Model, ev: pointer.PointerEvent(Msg)) ?Msg {
        const h = ev.hit orelse return .{ .hover = null };
        return .{ .hover = if (std.meta.eql(h, Msg.a)) 'a' else 'b' };
    }
    pub fn contextMsg(_: *const Model, ev: pointer.PointerEvent(Msg)) ?Msg {
        const on_a = if (ev.hit) |h| std.meta.eql(h, Msg.a) else false;
        return .{ .ctx = .{ .on_a = on_a, .x = ev.x } };
    }
};

test "run: hoverMsg fires when the widget under the pointer changes, not every frame" {
    const t = try play(HookApp, &.{
        .{}, // 1: lays out; the pointer is off-window and over nothing
        .{ .x = 5, .y = 5 }, // 2: enters A
        .{ .x = 6, .y = 6 }, // 3: still A: no event
        .{ .x = 5, .y = 45 }, // 4: B
        .{ .x = 500, .y = 500 }, // 5: leaves everything
    });
    defer t.destroy();
    try std.testing.expectEqual(@as(u32, 3), t.rt.model.hovers); // A, B, none
    try std.testing.expect(!t.rt.model.hovered_a);
}

test "run: contextMsg fires on right-button down with the widget under the cursor" {
    const t = try play(HookApp, &.{
        .{},
        .{ .x = 5, .y = 5, .held = right, .down = right },
        .{ .x = 5, .y = 5, .up = right },
        .{ .x = 300, .y = 200, .held = right, .down = right }, // empty space
    });
    defer t.destroy();
    try std.testing.expectEqual(@as(u32, 2), t.rt.model.contexts);
    try std.testing.expect(!t.rt.model.ctx_on_a); // the last one was over nothing
    try std.testing.expectEqual(@as(f32, 300), t.rt.model.ctx_x);
}

const SliderApp = struct {
    pub const Model = struct { value: f32 = -1, clicks: u32 = 0, updates: u32 = 0 };
    pub const Msg = union(enum) { grab, set: f32, other };
    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .grab, .other => m.clicks += 1,
            .set => |v| {
                m.value = v;
                m.updates += 1;
            },
        }
    }
    pub fn view(_: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .padding = 0, .gap = 0, .direction = .vertical });
        cb.slider(.grab, 0);
        cb.button(.other, "B");
        cb.popGroup();
    }
    pub fn sliderMsg(_: *const Model, _: Msg, value: f32) ?Msg {
        return .{ .set = value };
    }
};

test "run: sliderMsg drags with capture, and the slider's plain click is not dispatched" {
    // The slider sits at the top-left, min_width 120.
    const t = try play(SliderApp, &.{
        .{},
        .{ .x = 30, .y = 5, .held = left, .down = left }, // press at ~1/4
        .{ .x = 90, .y = 200, .held = left }, // dragged far off the track: still captured
        .{ .x = 500, .y = 5, .held = left }, // past the end: clamps to 1
        .{ .x = 500, .y = 5, .up = left },
        .{ .x = 5, .y = 60, .held = left, .down = left }, // press the button below: normal click
        .{ .x = 5, .y = 60, .up = left },
    });
    defer t.destroy();
    try std.testing.expectEqual(@as(f32, 1), t.rt.model.value);
    try std.testing.expect(t.rt.model.updates >= 3);
    try std.testing.expectEqual(@as(u32, 1), t.rt.model.clicks); // only the button; the slider never fired `.grab`
}

const KeyApp = struct {
    pub const Model = struct {
        typed: [8]u8 = undefined,
        typed_len: usize = 0,
        backspaces: u32 = 0,
    };
    pub const Msg = union(enum) { char: u8, backspace };
    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .char => |c| {
                m.typed[m.typed_len] = c;
                m.typed_len += 1;
            },
            .backspace => m.backspaces += 1,
        }
    }
    pub fn view(_: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .padding = 0, .gap = 0 });
        cb.textInput(.{ .char = 0 }, "", 0);
        cb.popGroup();
    }
    pub fn keyCharMsg(_: *const Model, c: u8) ?Msg {
        return .{ .char = c };
    }
    pub fn keySpecialMsg(_: *const Model, k: keys.SpecialKey) ?Msg {
        return if (k == .backspace) Msg.backspace else null;
    }
    pub fn themeFor(_: *const Model) theme_mod.Theme {
        return theme_mod.Theme.light_default;
    }
};

test "run: routes typed chars + special keys through the optional hooks" {
    const t = try play(KeyApp, &.{
        .{},
        .{ .chars = "Hi" },
        .{ .keys = &.{.backspace} },
    });
    defer t.destroy();
    try std.testing.expectEqualStrings("Hi", t.rt.model.typed[0..t.rt.model.typed_len]);
    try std.testing.expectEqual(@as(u32, 1), t.rt.model.backspaces);
    // `themeFor` reached the view's CmdBuffer.
    try std.testing.expect(std.meta.eql(theme_mod.Theme.light_default, t.rt.bufs[t.rt.current].theme));
}

// ── Commands: shortcuts + the palette ───────────────────────────────

const CmdApp = struct {
    const Palette = commands_mod.CommandPalette(16);
    pub const Model = struct {
        saves: u32 = 0,
        dirty: bool = true,
        copies: u32 = 0,
        typed: u32 = 0,
        opened_palette: u32 = 0,
        palette: Palette.Model = .{},
        ran: [4]u8 = @splat(0),
        ran_len: usize = 0,
    };
    pub const Msg = union(enum) { save, clear_dirty, copy, typed, palette: Palette.Msg, palette_run: usize };

    pub fn commands(m: *const Model, list: *commands_mod.CommandList(Msg)) void {
        list.add(.{ .id = "file.save", .label = "Save", .shortcut = keys.Chord.ctrl(.s), .enabled = m.dirty, .msg = .save });
        list.add(.{ .id = "edit.copy", .label = "Copy", .shortcut = keys.Chord.ctrl(.c), .msg = .copy });
        list.add(.{ .id = "palette", .label = "Command Palette", .shortcut = keys.Chord.ctrlShift(.p), .alt_shortcut = keys.Chord.ctrl(.k), .hidden = true, .msg = .{ .palette = .focus } });
        list.add(.{ .id = "file.clean", .label = "Mark Clean", .msg = .clear_dirty });
    }

    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .save => m.saves += 1,
            .clear_dirty => m.dirty = false,
            .copy => m.copies += 1,
            .typed => m.typed += 1,
            .palette => |pm| {
                if (pm == .focus) m.opened_palette += 1;
                Palette.update(&m.palette, pm);
            },
            .palette_run => |i| {
                Palette.update(&m.palette, .close);
                var list: commands_mod.CommandList(Msg) = .{};
                commands(m, &list);
                if (list.paletteCommand(i)) |c| {
                    m.ran[m.ran_len] = c.id[0];
                    m.ran_len += 1;
                    update(m, c.msg);
                }
            },
        }
    }
    fn selectMsg(i: usize) Msg {
        return .{ .palette_run = i };
    }
    pub fn view(m: *const Model, cb: anytype) void {
        cb.pushGroup(.{});
        cb.text("app");
        cb.popGroup();
        var list: commands_mod.CommandList(Msg) = .{};
        commands(m, &list);
        Palette.viewPalette(&m.palette, cb, &list, .{ .focus = Msg{ .palette = .focus }, .close = Msg{ .palette = .close }, .selectMsg = selectMsg }, .{});
    }
    pub fn keyCharMsg(m: *const Model, c: u8) ?Msg {
        if (m.palette.open) return .{ .palette = Palette.charMsg(c) };
        return .typed;
    }
    pub fn keySpecialMsg(m: *const Model, k: keys.SpecialKey) ?Msg {
        if (!m.palette.open) return if (k == .ctrl_c) Msg.typed else null;
        var list: commands_mod.CommandList(Msg) = .{};
        commands(m, &list);
        const pm = Palette.keyMsg(&m.palette, k, &list, .{}) orelse return null;
        // Enter selects: run the command through the app's own Msg.
        return switch (pm) {
            .select => |i| Msg{ .palette_run = i },
            else => Msg{ .palette = pm },
        };
    }
};

test "commands: a matched chord dispatches its Msg and swallows its text and special key" {
    const C = keys.Chord;
    const t = try play(CmdApp, &.{
        .{},
        .{ .chords = &.{C.ctrl(.s)}, .chars = "q" }, // claimed: no typed text
        .{ .chords = &.{C.ctrl(.c)}, .keys = &.{.ctrl_c} }, // claimed: ctrl_c swallowed
        .{ .chords = &.{C.ctrl(.z)}, .keys = &.{.ctrl_z}, .chars = "z" }, // unclaimed: text still types
        .{ .chords = &.{ C.ctrl(.s), C.ctrl(.s) } }, // two in one frame
        .{ .keys = &.{.ctrl_c} }, // a bare special key (no chord) still reaches the app
    });
    defer t.destroy();
    const m = t.rt.model;
    try std.testing.expectEqual(@as(u32, 3), m.saves);
    try std.testing.expectEqual(@as(u32, 1), m.copies);
    try std.testing.expectEqual(@as(u32, 2), m.typed); // "z" and the bare ctrl_c
}

test "commands: a disabled command's chord does nothing" {
    const C = keys.Chord;
    const t = try play(CmdApp, &.{
        .{},
        .{ .chords = &.{C.ctrl(.s)} },
        .{ .chords = &.{C.ctrl(.s)} },
    });
    defer t.destroy();
    try std.testing.expectEqual(@as(u32, 2), t.rt.model.saves);
    t.rt.model.dirty = false;
    var p2 = try play(CmdApp, &.{ .{}, .{ .chords = &.{C.ctrl(.s)} } });
    defer p2.destroy();
    p2.rt.model.dirty = false;
    try p2.rt.frame();
    try std.testing.expectEqual(@as(u32, 1), p2.rt.model.saves);
}

test "commands: the palette opens from its chords, filters fuzzily, Enter runs the command" {
    const C = keys.Chord;
    const t = try play(CmdApp, &.{
        .{},
        .{ .chords = &.{C.ctrlShift(.p)} },
        .{ .chars = "mc" }, // fuzzy: Mark Clean
        .{},
        .{ .keys = &.{.enter} },
        .{},
        .{ .chords = &.{C.ctrl(.k)} }, // the second binding opens it again
        .{ .keys = &.{.escape} },
        .{ .chords = &.{C.ctrl(.s)} }, // Mark Clean ran: Save is disabled now
    });
    defer t.destroy();
    const m = t.rt.model;
    try std.testing.expectEqual(@as(u32, 2), m.opened_palette);
    try std.testing.expect(!m.dirty);
    try std.testing.expectEqualStrings("f", m.ran[0..m.ran_len]);
    try std.testing.expect(!m.palette.open);
    try std.testing.expectEqual(@as(u32, 0), m.saves);
    try std.testing.expectEqual(@as(u32, 0), m.typed); // palette chars never reached the app
}

// ── In-app drag and drop ────────────────────────────────────────────

const DragApp = struct {
    pub const Model = struct {
        starts: u32 = 0,
        moves: u32 = 0,
        drops: u32 = 0,
        cancels: u32 = 0,
        last_over: u32 = 99,
        drop_over: u32 = 99,
        src_id: u32 = 0,
        grab: [2]f32 = .{ 0, 0 },
        drop_fy: f32 = -1,
        clicks: u32 = 0,
    };
    pub const Msg = union(enum) { drag: teak_pointer.DragEvent, click };
    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .click => m.clicks += 1,
            .drag => |ev| switch (ev.phase) {
                .start => {
                    m.starts += 1;
                    m.src_id = ev.id;
                    m.grab = .{ ev.grab_dx, ev.grab_dy };
                },
                .move => {
                    m.moves += 1;
                    m.last_over = ev.over;
                },
                .drop => {
                    m.drops += 1;
                    m.drop_over = ev.over;
                    m.drop_fy = ev.over_fy;
                },
                .cancel => m.cancels += 1,
            },
        }
    }
    pub fn view(_: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0, .align_cross = .start });
        for (0..4) |i| {
            const id: u32 = @intCast(i + 1);
            cb.pushGroup(.{ .padding = 0, .gap = 0, .width = 100, .height = 30, .drag_id = id, .drop_id = id });
            if (i == 0) cb.button(.click, "go"); // an interactive child: a press on it is a click
            cb.popGroup();
        }
        cb.popGroup();
    }
    pub fn dragMsg(_: *const Model, ev: teak_pointer.DragEvent) ?Msg {
        return .{ .drag = ev };
    }
};
const teak_pointer = pointer;

test "drag: press on a source, move past the threshold, hover targets, drop" {
    const t = try play(DragApp, &.{
        .{},
        .{ .x = 80, .y = 45, .held = left, .down = left }, // row 2 (id 2), grab at (80, 15)
        .{ .x = 82, .y = 46, .held = left }, // within the 4px slop: not a drag yet
        .{ .x = 70, .y = 100, .held = left }, // row 4: drag starts
        .{ .x = 70, .y = 110, .held = left }, // move
        .{ .x = 70, .y = 110, .up = left }, // drop on row 4, lower half
        .{},
    });
    defer t.destroy();
    const m = t.rt.model;
    try std.testing.expectEqual(@as(u32, 1), m.starts);
    try std.testing.expectEqual(@as(u32, 2), m.src_id);
    try std.testing.expectEqual(@as(f32, 80), m.grab[0]);
    try std.testing.expect(m.moves >= 1);
    try std.testing.expectEqual(@as(u32, 4), m.last_over);
    try std.testing.expectEqual(@as(u32, 1), m.drops);
    try std.testing.expectEqual(@as(u32, 4), m.drop_over);
    try std.testing.expect(m.drop_fy > 0.5);
    try std.testing.expectEqual(@as(u32, 0), m.cancels);
}

test "drag: a press-release without movement is not a drag; a press on a button is a click" {
    const t = try play(DragApp, &.{
        .{},
        .{ .x = 80, .y = 15, .held = left, .down = left },
        .{ .x = 80, .y = 15, .up = left },
        .{ .x = 10, .y = 10 }, // hover the button ("go" sits at the row's top-left)
        .{ .x = 10, .y = 10, .held = left, .down = left },
        .{ .x = 10, .y = 10, .up = left },
        .{},
    });
    defer t.destroy();
    try std.testing.expectEqual(@as(u32, 0), t.rt.model.starts);
    try std.testing.expectEqual(@as(u32, 1), t.rt.model.clicks);
}

test "drag: Escape cancels and later frames report nothing" {
    const t = try play(DragApp, &.{
        .{},
        .{ .x = 80, .y = 45, .held = left, .down = left },
        .{ .x = 70, .y = 100, .held = left },
        .{ .x = 70, .y = 100, .held = left, .keys = &.{.escape} },
        .{ .x = 70, .y = 100, .held = left },
        .{ .x = 70, .y = 100, .up = left },
        .{},
    });
    defer t.destroy();
    const m = t.rt.model;
    try std.testing.expectEqual(@as(u32, 1), m.starts);
    try std.testing.expectEqual(@as(u32, 1), m.cancels);
    try std.testing.expectEqual(@as(u32, 0), m.drops);
}

test "run: the clear colour follows the theme unless RunOptions pins one" {
    // KeyApp's themeFor is the light theme.
    const t = try play(KeyApp, &.{.{}});
    defer t.destroy();
    try std.testing.expectEqual(theme_mod.light_palette.bg, t.gpu.last_clear);

    const pinned = try playWith(KeyApp, .{ .script = &.{.{}} }, .{ .clear_color = .{ 0.5, 0.25, 0.125, 1 } });
    defer pinned.destroy();
    try std.testing.expectEqual([4]f32{ 0.5, 0.25, 0.125, 1 }, pinned.gpu.last_clear);
}

const TabApp = struct {
    pub const Focus = enum { none, a, b };
    pub const Model = struct { focus: Focus = .none, submitted: bool = false };
    pub const Msg = union(enum) { focus_a, focus_b, submit };
    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .focus_a => m.focus = .a,
            .focus_b => m.focus = .b,
            .submit => m.submitted = true,
        }
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

test "run: Tab advances focus across inputs and Enter fires submitMsg" {
    const t = try play(TabApp, &.{
        .{},
        .{ .keys = &.{.tab} }, // none -> a
        .{ .keys = &.{.tab} }, // a -> b
        .{ .keys = &.{.enter} },
    });
    defer t.destroy();
    try std.testing.expectEqual(TabApp.Focus.b, t.rt.model.focus);
    try std.testing.expect(t.rt.model.submitted);
}

test "run: Shift+Tab walks focus backwards" {
    const t = try play(TabApp, &.{
        .{},
        .{ .keys = &.{.tab} }, // none -> a
        .{ .keys = &.{.tab} }, // a -> b
        .{ .keys = &.{.shift_tab} }, // b -> a
    });
    defer t.destroy();
    try std.testing.expectEqual(TabApp.Focus.a, t.rt.model.focus);
}

test "run: the IME field is activated once while a text input is focused, released when focus leaves" {
    const t = try play(TabApp, &.{
        .{},
        .{ .keys = &.{.tab} }, // none -> a: a text input is focused
        .{},
        .{},
        .{ .keys = &.{.tab} }, // a -> b: still a text input, no new activation
        .{},
    });
    defer t.destroy();
    try std.testing.expectEqual(@as(u32, 1), t.host.ime_active_calls);
    try std.testing.expect(t.host.ime_active_last);
    try std.testing.expect(t.host.ime_spot_calls >= 2); // the caret moved between inputs
}

// ── Measured rows + modifier reports ────────────────────────────────

const RowsApp = struct {
    pub const Model = struct { got: [4]f32 = @splat(0), n: usize = 0, first: u32 = 99, calls: u32 = 0, shift: bool = false, mods_calls: u32 = 0 };
    pub const Msg = union(enum) { rows: struct { first: u32, n: u8, h: [4]f32 }, mods: pointer.Modifiers };
    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .rows => |r| {
                m.calls += 1;
                m.first = r.first;
                m.n = r.n;
                m.got = r.h;
            },
            .mods => |mm| {
                m.shift = mm.shift;
                m.mods_calls += 1;
            },
        }
    }
    pub fn view(_: *const Model, cb: anytype) void {
        cb.pushScroll(.{ .padding = 0, .gap = 0, .width = 200, .height = 100, .id = 1 });
        cb.pushVirtualList(.{ .total_extent = 1000, .start_offset = 300, .visible_start = 7, .visible_end = 9, .id = 4, .align_cross = .stretch });
        cb.pushGroup(.{ .padding = 0, .gap = 0, .height = 20 });
        cb.popGroup();
        cb.pushGroup(.{ .padding = 0, .gap = 0, .height = 30 });
        cb.popGroup();
        cb.popVirtualList();
        cb.popScroll();
    }
    pub fn virtualRowsMsg(_: *const Model, id: u32, first: u32, heights: []const f32) ?Msg {
        if (id != 4) return null;
        var h: [4]f32 = @splat(0);
        @memcpy(h[0..heights.len], heights);
        return .{ .rows = .{ .first = first, .n = @intCast(heights.len), .h = h } };
    }
    pub fn modsMsg(_: *const Model, mods: pointer.Modifiers) ?Msg {
        return .{ .mods = mods };
    }
};

test "run: virtualRowsMsg reports the measured row heights once, and again only when they change" {
    const t = try playWith(RowsApp, .{ .script = &.{ .{}, .{}, .{}, .{} } }, .{ .idle_skip = false });
    defer t.destroy();
    try std.testing.expectEqual(@as(u32, 1), t.rt.model.calls);
    try std.testing.expectEqual(@as(u32, 7), t.rt.model.first);
    try std.testing.expectEqual(@as(usize, 2), t.rt.model.n);
    try std.testing.expectEqual(@as(f32, 20), t.rt.model.got[0]);
    try std.testing.expectEqual(@as(f32, 30), t.rt.model.got[1]);
}

test "run: modsMsg fires when the modifier keys change, not every frame" {
    const t = try playWith(RowsApp, .{ .script = &.{
        .{},
        .{ .mods = .{ .shift = true } },
        .{ .mods = .{ .shift = true } },
        .{},
    } }, .{ .idle_skip = false });
    defer t.destroy();
    try std.testing.expectEqual(@as(u32, 2), t.rt.model.mods_calls); // shift down, shift up
    try std.testing.expect(!t.rt.model.shift);
}

// ── Frame diff: IME aliasing, over-long title ───────────────────────

const NoopApp = struct {
    pub const Model = struct {};
    pub const Msg = union(enum) { noop };
    pub fn update(_: *Model, _: Msg) void {}
    pub fn view(_: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .padding = 0, .gap = 0 });
        cb.button(.noop, "X");
        cb.popGroup();
    }
};

test "run: a same-length IME composition change forces a rebuild" {
    // Blink disabled so the ONLY rebuild triggers are content/transient
    // changes — the IME edit must be one of them.
    const t = try playWith(NoopApp, .{
        .script = &.{
            .{},
            .{ .ime = "ab" }, // composition starts
            .{ .ime = "cd" }, // same length, written over "ab" in the Host's one shared buffer
        },
    }, .{ .blink_half_ms = 0 });
    defer t.destroy();
    // Frame 1: first content. Frame 2: IME activates. Frame 3: "cd" — a
    // rebuild ONLY if the loop copies each frame's composition into its own
    // buffer; aliasing prev/cur to the Host's buffer compares equal -> 2.
    try std.testing.expectEqual(@as(u32, 3), t.gpu.upload_vert_calls);
}

const LongTitleApp = struct {
    pub const Model = struct {};
    pub const Msg = union(enum) { noop };
    const long_title: [300]u8 = @splat('T');
    pub fn update(_: *Model, _: Msg) void {}
    pub fn view(_: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .padding = 0, .gap = 0 });
        cb.text("hi");
        cb.popGroup();
    }
    pub fn windowTitle(_: *const Model) ?[]const u8 {
        return &long_title;
    }
};

test "run: an over-long window title fires setTitle once, not every frame" {
    const t = try play(LongTitleApp, &.{ .{}, .{}, .{} });
    defer t.destroy();
    // The title never changes, so after the first push it must compare equal
    // to the stored (truncated) prefix. Comparing the full 300 bytes against
    // the 256-byte cache would re-issue the syscall every frame.
    try std.testing.expectEqual(@as(u32, 1), t.host.set_title_calls);
}

// ── Live-snapshot sink ──────────────────────────────────────────────

/// Button "X" over a live count label; the label changes on click so the
/// snapshot diff is observable.
const SnapApp = struct {
    pub const Model = struct {
        count: i32 = 0,
        buf: [16]u8 = undefined,
        len: usize = 0,

        pub fn init() Model {
            var m = Model{};
            m.format();
            return m;
        }
        fn format(m: *Model) void {
            const s = std.fmt.bufPrint(&m.buf, "count: {d}", .{m.count}) catch "count: ?";
            m.len = s.len;
        }
        fn label(m: *const Model) []const u8 {
            return m.buf[0..m.len];
        }
    };
    pub const Msg = union(enum) { click };
    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .click => {
                m.count += 1;
                m.format();
            },
        }
    }
    pub fn view(m: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
        cb.button(.click, "X");
        cb.text(m.label());
        cb.popGroup();
    }
};

/// A cwd-relative path into `td` (the sink writes through `cwd()`).
fn snapshotPath(td: anytype, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}/{s}", .{ td.sub_path, name });
}

fn readSnapshot(td: anytype, name: []const u8) ![]u8 {
    return td.dir.readFileAlloc(std.Options.debug_io, name, std.testing.allocator, .limited(1 << 20));
}

test "run: live snapshot mirrors the frame and skips idle rewrites" {
    const gpa = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const path = try snapshotPath(td, "app.snap");
    defer gpa.free(path);

    // Cursor parked over the button throughout. The last content change is
    // the click, so a correct sink stamps its frame; a higher number would
    // mean an idle frame rewrote the file.
    const t = try playWith(SnapApp, .{
        .script = &.{
            .{ .x = 5, .y = 5 }, // 1: first write
            .{ .x = 5, .y = 5 }, // 2: idle
            .{ .x = 5, .y = 5, .held = left, .down = left }, // 3
            .{ .x = 5, .y = 5, .up = left }, // 4: click
            .{ .x = 5, .y = 5 }, // 5: idle
            .{ .x = 5, .y = 5 }, // 6: idle
        },
    }, .{ .snapshot_path = path });
    defer t.destroy();

    const contents = try readSnapshot(td, "app.snap");
    defer gpa.free(contents);

    try std.testing.expect(std.mem.startsWith(u8, contents, "window="));
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"X\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"count: 1\"") != null);
    // The file holds only the latest frame.
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"count: 0\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "last_msg=click") != null);

    const marker = "frame=";
    const fi = std.mem.indexOf(u8, contents, marker).?;
    const after = contents[fi + marker.len ..];
    const end = std.mem.indexOfScalar(u8, after, ' ') orelse after.len;
    // Frame 2 was a quiet frame (skipped, uncounted), so the click is the
    // third frame that actually built.
    try std.testing.expectEqual(@as(u32, 3), try std.fmt.parseInt(u32, after[0..end], 10));
}

// ── Secondary window ────────────────────────────────────────────────

const SecondaryApp = struct {
    pub const Model = struct { stats_open: bool = true, closed_msgs: u32 = 0, ticks: i32 = 0 };
    pub const Msg = union(enum) { close_stats, tick };
    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .close_stats => {
                m.stats_open = false;
                m.closed_msgs += 1;
            },
            .tick => m.ticks += 1,
        }
    }
    pub fn view(_: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .padding = 0, .gap = 0 });
        cb.text("main");
        cb.popGroup();
    }
    pub fn secondaryWindow(m: *const Model) ?SecondaryWindowSpec {
        return if (m.stats_open) .{ .title = "Stats", .width = 360, .height = 200 } else null;
    }
    pub fn secondaryView(m: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
        cb.text(std.fmt.allocPrint(cb.arena.allocator(), "ticks: {d}", .{m.ticks}) catch "ticks: ?");
        cb.popGroup();
    }
    pub fn secondaryClosedMsg(_: *const Model) ?Msg {
        return Msg.close_stats;
    }
    pub fn subscribe(_: *const Model) []const sub_mod.Sub(Msg) {
        return &.{.{ .every = .{ .interval_ms = 100, .msg = .tick } }};
    }
};

test "run: drives the secondary window open -> render -> user-close lifecycle" {
    // The primary runs 4 frames; the secondary poll yields input twice, then
    // null (the user closed the OS window).
    const t = try playWith(SecondaryApp, .{ .script = &.{ .{}, .{}, .{}, .{} }, .secondary_polls = 2 }, .{});
    defer t.destroy();
    // One surface opened, rendered while the OS window was alive, torn down on
    // the user-close poll, and the close mirrored back through `update`.
    try std.testing.expectEqual(@as(u32, 1), t.gpu.secondary_opened);
    try std.testing.expectEqual(@as(u32, 2), t.gpu.secondary_rendered);
    try std.testing.expectEqual(@as(u32, 1), t.gpu.secondary_closed);
    try std.testing.expectEqual(@as(u32, 1), t.rt.model.closed_msgs);
}

/// Like `SecondaryApp` but never learns the window closed: it keeps
/// requesting it and omits `secondaryClosedMsg`.
const StubbornSecondaryApp = struct {
    pub const Model = struct {};
    pub const Msg = union(enum) { noop };
    pub fn update(_: *Model, _: Msg) void {}
    pub fn view(_: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .padding = 0, .gap = 0 });
        cb.text("main");
        cb.popGroup();
    }
    pub fn secondaryWindow(_: *const Model) ?SecondaryWindowSpec {
        return .{ .title = "Stats", .width = 360, .height = 200 };
    }
    pub fn secondaryView(_: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .padding = 0, .gap = 0 });
        cb.text("stats");
        cb.popGroup();
    }
};

test "run: user-close without secondaryClosedMsg does not immediately reopen" {
    const t = try playWith(StubbornSecondaryApp, .{ .script = &.{ .{}, .{}, .{}, .{} }, .secondary_polls = 2 }, .{});
    defer t.destroy();
    // Opened exactly once for the whole run: without the suppression the
    // window would flicker back every frame after the user-close.
    try std.testing.expectEqual(@as(u32, 1), t.gpu.secondary_opened);
}

test "run: an app with secondary hooks runs on a Host that cannot open a window" {
    // `openSecondaryWindow` returns null (the web): the hooks compile, the
    // window never opens, and the primary is unaffected.
    const t = try play(SecondaryApp, &.{ .{}, .{}, .{} });
    defer t.destroy();
    try std.testing.expectEqual(@as(u32, 0), t.gpu.secondary_opened);
    try std.testing.expectEqual(@as(u32, 3), t.gpu.render_calls);
}

// ── Subscriptions + snapshot of a secondary-only change ─────────────

const TimerApp = struct {
    pub const Model = struct { ticks: i32 = 0 };
    pub const Msg = union(enum) { tick };
    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .tick => m.ticks += 1,
        }
    }
    pub fn view(m: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
        // Formatted into the per-frame arena (not aliased from Model), so the
        // two frame buffers hold distinct copies and the frame diff can see
        // the count change with no accompanying transient-state change.
        cb.text(std.fmt.allocPrint(cb.arena.allocator(), "ticks: {d}", .{m.ticks}) catch "ticks: ?");
        cb.popGroup();
    }
    pub fn subscribe(_: *const Model) []const sub_mod.Sub(Msg) {
        // Fire `.tick` on every crossed 100 ms boundary.
        return &.{.{ .every = .{ .interval_ms = 100, .msg = .tick } }};
    }
};

test "run: services a .every subscription and mirrors the fired Msg to the snapshot" {
    const gpa = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const path = try snapshotPath(td, "timer.snap");
    defer gpa.free(path);

    const t = try playWith(TimerApp, .{
        .script = &.{
            .{ .clock_ms = 50 }, // first frame: no window to compare, no fire
            .{ .clock_ms = 250 }, // crosses the 100 and 200 ms boundaries
        },
    }, .{ .snapshot_path = path });
    defer t.destroy();

    try std.testing.expectEqual(@as(i32, 2), t.rt.model.ticks);
    try std.testing.expectEqualStrings("tick", t.rt.last_msg);

    const contents = try readSnapshot(td, "timer.snap");
    defer gpa.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"ticks: 2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "last_msg=tick") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"ticks: 0\"") == null);
}

test "run: a secondary-content-only change re-mirrors the snapshot" {
    // `SecondaryApp`'s tick shows only in the secondary view; the primary
    // never changes. The snapshot gate must see the secondary diff, or the
    // mirror stays frozen at the opening frame.
    const gpa = std.testing.allocator;
    var td = std.testing.tmpDir(.{});
    defer td.cleanup();
    const path = try snapshotPath(td, "sec.snap");
    defer gpa.free(path);

    const t = try playWith(SecondaryApp, .{ .script = &.{
        .{ .clock_ms = 50 },
        .{ .clock_ms = 150 },
        .{ .clock_ms = 250 },
    }, .secondary_polls = ScriptHost.forever }, .{ .snapshot_path = path });
    defer t.destroy();

    const contents = try readSnapshot(td, "sec.snap");
    defer gpa.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "=== secondary \"Stats\" ===") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"ticks: 2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"ticks: 0\"") == null);
}

// ── Frame diff (cmdsEqual) ──────────────────────────────────────────

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

test "cmdsEqual: a style-only change (button bg) compares unequal (F1)" {
    const Msg = union(enum) { a };
    var x = cmd.CmdBuffer(Msg).init(std.testing.allocator);
    defer x.deinit();
    var y = cmd.CmdBuffer(Msg).init(std.testing.allocator);
    defer y.deinit();

    // Same label + msg, but a different background color — the kind of
    // difference a themeFor flip or a `buttonStyled` danger color produces.
    // If cmdsEqual ignores style, the vertex rebuild + snapshot write are
    // skipped and the screen keeps stale pixels.
    var danger = cmd.ButtonStyle{};
    danger.bg = .{ 0.8, 0.1, 0.1, 1.0 };
    x.buttonStyled(.a, "Go", .{});
    y.buttonStyled(.a, "Go", danger);
    try std.testing.expect(!cmdsEqual(Msg, x.cmds.items, y.cmds.items));

    // Identical styles still compare equal.
    y.reset();
    y.buttonStyled(.a, "Go", .{});
    try std.testing.expect(cmdsEqual(Msg, x.cmds.items, y.cmds.items));
}

// ── Interactive canvases + scroll regions ───────────────────────────

/// Fixed-capacity Msg log the test Models keep, so assertions read the
/// Model straight off the finished Runtime.
const EventLog = struct {
    buf: [64]PointerApp.Logged = undefined,
    n: usize = 0,

    fn push(self: *EventLog, l: PointerApp.Logged) void {
        self.buf[self.n] = l;
        self.n += 1;
    }
    fn items(self: *const EventLog) []const PointerApp.Logged {
        return self.buf[0..self.n];
    }
};

const PointerApp = struct {
    const Logged = union(enum) {
        canvas: pointer.CanvasEvent,
        click,
        wheel: f32,
        scroll: struct { id: u32, dx: f32, dy: f32 },
        scroll_layout: struct { id: u32, vw: f32, vh: f32, cw: f32, ch: f32 },
        widen,
    };
    pub const Model = struct {
        log: EventLog = .{},
        wide: bool = false,
    };
    pub const Msg = Logged;
    pub fn update(m: *Model, msg: Msg) void {
        if (msg == .widen) m.wide = true;
        m.log.push(msg);
    }
    pub fn view(m: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
        cb.canvasInteractive(.{ .width = if (m.wide) 300 else 200, .height = 100 }, &.{}, 7, "viewport");
        cb.button(.click, "B");
        cb.popGroup();
    }
    pub fn canvasMsg(_: *const Model, ev: pointer.CanvasEvent) ?Msg {
        return .{ .canvas = ev };
    }
    pub fn wheelMsg(_: *const Model, dy: f32) ?Msg {
        return .{ .wheel = dy };
    }
    pub fn keySpecialMsg(_: *const Model, k: keys.SpecialKey) ?Msg {
        return if (k == .enter) Msg.widen else null;
    }
};

fn expectKinds(log: []const PointerApp.Logged, expected: []const pointer.CanvasEventKind) !void {
    var got: [64]pointer.CanvasEventKind = undefined;
    var n: usize = 0;
    for (log) |l| switch (l) {
        .canvas => |ev| {
            got[n] = ev.kind;
            n += 1;
        },
        else => {},
    };
    try std.testing.expectEqualSlices(pointer.CanvasEventKind, expected, got[0..n]);
}

test "canvas events: hover, press captures through a drag outside, release + leave" {
    const t = try play(PointerApp, &.{
        .{}, // 1: view built; canvas laid out -> `layout`
        .{ .x = 50, .y = 40 }, // 2: enters the canvas
        .{ .x = 60, .y = 45 }, // 3: moves within it
        .{ .x = 60, .y = 45, .held = left, .down = left }, // 4: press
        .{ .x = 300, .y = 250, .held = left }, // 5: dragged off the canvas, still captured
        .{ .x = 300, .y = 250, .up = left }, // 6: release outside
        .{ .x = 300, .y = 250 }, // 7: idle
    });
    defer t.destroy();
    const log = t.rt.model.log.items();

    try expectKinds(log, &.{ .layout, .move, .move, .down, .move, .up, .leave });

    const layout_ev = log[0].canvas;
    try std.testing.expectEqual(@as(u32, 7), layout_ev.id);
    try std.testing.expectEqual(@as(f32, 200), layout_ev.w);
    try std.testing.expectEqual(@as(f32, 100), layout_ev.h);

    // Entry move: local coords, zero delta. Second move: delta from the first.
    const enter = log[1].canvas;
    try std.testing.expectEqual(@as(f32, 50), enter.x);
    try std.testing.expectEqual(@as(f32, 40), enter.y);
    try std.testing.expectEqual(@as(f32, 0), enter.dx);
    const mv = log[2].canvas;
    try std.testing.expectEqual(@as(f32, 10), mv.dx);
    try std.testing.expectEqual(@as(f32, 5), mv.dy);

    const down = log[3].canvas;
    try std.testing.expectEqual(pointer.Button.left, down.button);
    try std.testing.expect(down.buttons.left);
    try std.testing.expectEqual(@as(f32, 60), down.x);

    // Captured move outside the rect: local coords run past the canvas.
    const drag = log[4].canvas;
    try std.testing.expectEqual(@as(f32, 300), drag.x);
    try std.testing.expectEqual(@as(f32, 240), drag.dx);
    try std.testing.expect(drag.buttons.left);

    const up = log[5].canvas;
    try std.testing.expectEqual(pointer.Button.left, up.button);
    try std.testing.expect(!up.buttons.any());
    // No stray click Msg: a pointer canvas has no click msg.
    for (log) |l| try std.testing.expect(l != .click);
}

test "canvas events: leaving without a press sends leave; wheel goes to the canvas, not wheelMsg" {
    const t = try play(PointerApp, &.{
        .{},
        .{ .x = 50, .y = 40 },
        .{ .x = 50, .y = 40, .wheel_dy = 120, .mods = .{ .ctrl = true } }, // pinch-style wheel on the canvas
        .{ .x = 50, .y = 150 }, // moved onto the button below
        .{ .x = 50, .y = 150, .wheel_dy = 48 }, // wheel over a button: plain wheelMsg
    });
    defer t.destroy();
    const log = t.rt.model.log.items();

    try expectKinds(log, &.{ .layout, .move, .wheel, .leave });
    const wheel_ev = log[2].canvas;
    try std.testing.expectEqual(@as(f32, 120), wheel_ev.dy);
    try std.testing.expect(wheel_ev.mods.ctrl);
    try std.testing.expectEqual(@as(f32, 50), wheel_ev.x);
    // Exactly one plain wheel Msg: the one over the button, none for the canvas wheel.
    var plain: usize = 0;
    for (log) |l| if (l == .wheel) {
        plain += 1;
        try std.testing.expectEqual(@as(f32, 48), l.wheel);
    };
    try std.testing.expectEqual(@as(usize, 1), plain);
}

test "canvas events: a press that started elsewhere does not hover the canvas" {
    const t = try play(PointerApp, &.{
        .{},
        .{ .x = 50, .y = 150, .held = left, .down = left }, // press on the button
        .{ .x = 50, .y = 50, .held = left }, // dragged over the canvas
        .{ .x = 50, .y = 50, .up = left }, // released over it
        .{ .x = 55, .y = 50 }, // now hovering is fine
    });
    defer t.destroy();
    try expectKinds(t.rt.model.log.items(), &.{ .layout, .move });
    // The release over the canvas did not click the button (drag-off cancel).
    for (t.rt.model.log.items()) |l| try std.testing.expect(l != .click);
}

test "canvas events: a click inside one frame sends down then up and leaves no capture" {
    const t = try play(PointerApp, &.{
        .{},
        .{ .x = 10, .y = 10, .held = .{}, .down = left, .up = left }, // fast click
        .{ .x = 20, .y = 20 }, // hover continues, nothing captured
    });
    defer t.destroy();
    try expectKinds(t.rt.model.log.items(), &.{ .layout, .move, .down, .up, .move });
}

test "canvas events: multiple buttons keep the capture until all are released" {
    const t = try play(PointerApp, &.{
        .{},
        .{ .x = 10, .y = 10 },
        .{ .x = 10, .y = 10, .held = left, .down = left },
        .{ .x = 300, .y = 10, .held = both, .down = right, .mods = .{ .shift = true } }, // 2nd button, off the canvas
        .{ .x = 300, .y = 10, .held = right, .up = left }, // one released: still captured
        .{ .x = 300, .y = 10, .up = right }, // last released outside
    });
    defer t.destroy();
    const log = t.rt.model.log.items();
    try expectKinds(log, &.{ .layout, .move, .down, .move, .down, .up, .up, .leave });
    const second_down = log[4].canvas;
    try std.testing.expectEqual(pointer.Button.right, second_down.button);
    try std.testing.expect(second_down.buttons.left and second_down.buttons.right);
    try std.testing.expect(second_down.mods.shift);
}

test "canvas events: layout fires again when the canvas size changes, not otherwise" {
    const t = try play(PointerApp, &.{
        .{}, // 1: layout 200x100
        .{}, // 2: unchanged -> nothing
        .{ .keys = &.{.enter} }, // 3: model.wide = true
        .{}, // 4: view builds the 300-wide canvas -> layout
        .{}, // 5: unchanged
    });
    defer t.destroy();
    const log = t.rt.model.log.items();
    var layouts: usize = 0;
    var last_w: f32 = 0;
    for (log) |l| switch (l) {
        .canvas => |ev| if (ev.kind == .layout) {
            layouts += 1;
            last_w = ev.w;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), layouts);
    try std.testing.expectEqual(@as(f32, 300), last_w);
}

/// A scroll region (id 3) with a button list above a plain button, plus an
/// id-0 region, to exercise `scrollMsg` / `scrollLayoutMsg`.
const ScrollApp = struct {
    pub const Model = struct {
        log: EventLog = .{},
        rows: u32 = 3,
    };
    pub const Msg = PointerApp.Logged;
    pub fn update(m: *Model, msg: Msg) void {
        if (msg == .widen) m.rows += 2;
        m.log.push(msg);
    }
    pub fn view(m: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
        cb.pushScroll(.{ .id = 3, .width = 200, .height = 80, .padding = 0 }); // 0..80
        for (0..m.rows) |_| cb.button(.click, "row");
        cb.popScroll();
        cb.pushScroll(.{ .id = 0, .width = 200, .height = 80, .padding = 0 }); // 80..160
        cb.button(.click, "plain");
        cb.popScroll();
        cb.popGroup();
    }
    pub fn scrollMsg(_: *const Model, id: u32, dx: f32, dy: f32) ?Msg {
        return .{ .scroll = .{ .id = id, .dx = dx, .dy = dy } };
    }
    pub fn scrollLayoutMsg(_: *const Model, id: u32, vw: f32, vh: f32, cw: f32, ch: f32) ?Msg {
        return .{ .scroll_layout = .{ .id = id, .vw = vw, .vh = vh, .cw = cw, .ch = ch } };
    }
    pub fn wheelMsg(_: *const Model, dy: f32) ?Msg {
        return .{ .wheel = dy };
    }
    pub fn keySpecialMsg(_: *const Model, k: keys.SpecialKey) ?Msg {
        return if (k == .enter) Msg.widen else null;
    }
};

test "scrollMsg: wheel over an id-bearing region; elsewhere falls to wheelMsg" {
    const t = try play(ScrollApp, &.{
        .{},
        .{ .x = 50, .y = 40, .wheel_dy = 96, .wheel_dx = 12 }, // over region id 3
        .{ .x = 50, .y = 120, .wheel_dy = 48 }, // over the id-0 region: no consumer
    });
    defer t.destroy();
    var scrolls: usize = 0;
    var wheels: usize = 0;
    for (t.rt.model.log.items()) |l| switch (l) {
        .scroll => |s| {
            scrolls += 1;
            try std.testing.expectEqual(@as(u32, 3), s.id);
            try std.testing.expectEqual(@as(f32, 96), s.dy);
            try std.testing.expectEqual(@as(f32, 12), s.dx);
        },
        .wheel => |dy| {
            wheels += 1;
            try std.testing.expectEqual(@as(f32, 48), dy);
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), scrolls);
    try std.testing.expectEqual(@as(usize, 1), wheels);
}

test "scrollLayoutMsg: first layout and content changes, not idle frames" {
    const t = try play(ScrollApp, &.{
        .{}, // 1: first layout of region 3
        .{}, // 2: idle -> nothing
        .{ .keys = &.{.enter} }, // 3: 3 -> 5 rows
        .{}, // 4: new content size reported
        .{}, // 5: idle
    });
    defer t.destroy();
    var reports: [8]@TypeOf(@as(PointerApp.Logged, undefined).scroll_layout) = undefined;
    var n: usize = 0;
    for (t.rt.model.log.items()) |l| switch (l) {
        .scroll_layout => |r| {
            reports[n] = r;
            n += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u32, 3), reports[0].id);
    try std.testing.expectEqual(@as(f32, 200), reports[0].vw);
    try std.testing.expectEqual(@as(f32, 80), reports[0].vh);
    try std.testing.expectEqual(@as(f32, 3 * 36), reports[0].ch);
    try std.testing.expectEqual(@as(f32, 5 * 36), reports[1].ch);
    try std.testing.expectEqual(@as(f32, 80), reports[1].vh); // viewport unchanged
}

test "cmdsEqual: canvas id / pointer changes compare unequal" {
    const Msg = union(enum) { a };
    var x = cmd.CmdBuffer(Msg).init(std.testing.allocator);
    defer x.deinit();
    var y = cmd.CmdBuffer(Msg).init(std.testing.allocator);
    defer y.deinit();

    x.canvasInteractive(.{}, &.{}, 1, "c");
    y.canvasInteractive(.{}, &.{}, 1, "c");
    try std.testing.expect(cmdsEqual(Msg, x.cmds.items, y.cmds.items));

    y.reset();
    y.canvasInteractive(.{}, &.{}, 2, "c");
    try std.testing.expect(!cmdsEqual(Msg, x.cmds.items, y.cmds.items));

    y.reset();
    y.canvasLabeled(.{}, &.{}, "c"); // same label, not interactive
    try std.testing.expect(!cmdsEqual(Msg, x.cmds.items, y.cmds.items));

    // Scroll region ids are part of the push_scroll payload.
    x.reset();
    y.reset();
    x.pushScroll(.{ .id = 1 });
    y.pushScroll(.{ .id = 2 });
    try std.testing.expect(!cmdsEqual(Msg, x.cmds.items, y.cmds.items));
}

/// Canvas (id 7) with a popup button overlapping its corner; `.widen` (Enter)
/// removes the canvas from the view altogether.
const OverlayApp = struct {
    pub const Model = struct {
        log: EventLog = .{},
        canvas_gone: bool = false,
    };
    pub const Msg = PointerApp.Logged;
    pub fn update(m: *Model, msg: Msg) void {
        if (msg == .widen) m.canvas_gone = true;
        m.log.push(msg);
    }
    pub fn view(m: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
        if (!m.canvas_gone) cb.canvasInteractive(.{ .width = 200, .height = 100 }, &.{}, 7, "");
        cb.popGroup();
        cb.pushOverlay(.{ .x = 10, .y = 10 });
        cb.button(.click, "Menu"); // 60x36 at (10,10)
        cb.popOverlay();
    }
    pub fn canvasMsg(_: *const Model, ev: pointer.CanvasEvent) ?Msg {
        return .{ .canvas = ev };
    }
    pub fn keySpecialMsg(_: *const Model, k: keys.SpecialKey) ?Msg {
        return if (k == .enter) Msg.widen else null;
    }
};

test "canvas events: an overlay widget over the canvas wins hover, press and click" {
    const t = try play(OverlayApp, &.{
        .{},
        .{ .x = 20, .y = 20 }, // over the popup button, which covers the canvas corner
        .{ .x = 20, .y = 20, .held = left, .down = left },
        .{ .x = 20, .y = 20, .up = left }, // click on the button
        .{ .x = 150, .y = 60 }, // canvas area outside the popup
    });
    defer t.destroy();
    const log = t.rt.model.log.items();
    // Only the canvas layout, then the move once the cursor leaves the popup.
    try expectKinds(log, &.{ .layout, .move });
    try std.testing.expectEqual(@as(f32, 150), log[log.len - 1].canvas.x);
    var clicks: usize = 0;
    for (log) |l| if (l == .click) {
        clicks += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), clicks);
}

test "canvas events: a capture whose canvas leaves the view is dropped, not stuck" {
    const t = try play(OverlayApp, &.{
        .{},
        .{ .x = 150, .y = 60 },
        .{ .x = 150, .y = 60, .held = left, .down = left }, // capture
        .{ .x = 150, .y = 60, .held = left, .keys = &.{.enter} }, // canvas removed from the view
        .{ .x = 160, .y = 60, .held = left }, // drag with the canvas gone: no events, no crash
        .{ .x = 160, .y = 60, .up = left },
        .{ .x = 150, .y = 60 },
    });
    defer t.destroy();
    try expectKinds(t.rt.model.log.items(), &.{ .layout, .move, .down });
}

// ── Scenes: resources hook, pointer routing, frame diff ────────────

const pixel_rgba = [_]u8{ 255, 0, 0, 255 };

/// A model whose `rev` a button click bumps; the scene's Cmd key is
/// deliberately constant so only the resource change can force a re-stage.
const ResourceApp = struct {
    pub const Model = struct { rev: u32 = 1 };
    pub const Msg = union(enum) { bump };
    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .bump => m.rev += 1,
        }
    }
    pub fn resources(m: *const Model) []const resources_mod.Resource {
        const S = struct {
            var list: [2]resources_mod.Resource = undefined;
        };
        S.list[0] = .{ .mesh = .{ .key = 5, .rev = m.rev, .data = .{} } };
        S.list[1] = .{ .image = .{ .key = 3, .rev = 1, .width = 1, .height = 1, .rgba = &pixel_rgba } };
        return &S.list;
    }
    pub fn view(_: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .padding = 0, .gap = 0 });
        cb.button(.bump, "X");
        cb.scene3d(.{ .style = .{ .width = 50, .height = 40 }, .mesh = 5 });
        cb.image(3, .{ .width = 16, .height = 16 });
        cb.popGroup();
    }
};

test "resources: uploaded once, keys remapped to handles, rev bump re-uploads, shutdown releases" {
    const t = try play(ResourceApp, &.{
        .{},
        .{ .x = 5, .y = 5, .held = left, .down = left },
        .{ .x = 5, .y = 5, .up = left }, // click => rev 2
        .{},
        .{},
    });
    const gpu = t.gpu; // copy the counters, then tear the runtime down
    t.destroy();

    // Mesh: rev 1, then rev 2 after the click. Image: once.
    try std.testing.expectEqual(@as(u32, 2), gpu.mesh_uploads);
    try std.testing.expectEqual(@as(u32, 1), gpu.image_uploads);
    // The Gpu only ever saw backend handles, never the app keys 5 / 3.
    try std.testing.expect(gpu.last_scene_mesh >= 100);
    try std.testing.expect(gpu.last_image_handle >= 100);
    try std.testing.expectEqual(@as(usize, 1), gpu.last_scene_count);
}

test "resources: the superseded handle is released on rev bump, the rest at deinit" {
    var host: ScriptHost = .{ .script = &.{
        .{},
        .{ .x = 5, .y = 5, .held = left, .down = left },
        .{ .x = 5, .y = 5, .up = left },
        .{},
    } };
    var gpu: StubGpu = .{};
    var rt = try Runtime(ResourceApp, ScriptHost, StubGpu).init(std.testing.allocator, &host, &gpu, .{});
    while (!host.shouldClose()) try rt.frame();

    // Before teardown: only the superseded mesh handle has been released,
    // and the re-upload re-staged the scene although its Cmd was unchanged.
    try std.testing.expectEqual(@as(u32, 1), gpu.mesh_releases);
    try std.testing.expectEqual(@as(u32, 0), gpu.image_releases);
    try std.testing.expectEqual(@as(u32, 102), gpu.last_scene_mesh);

    rt.deinit();
    try std.testing.expectEqual(@as(u32, 2), gpu.mesh_releases);
    try std.testing.expectEqual(@as(u32, 1), gpu.image_releases);
}

const PlainGpu = struct {
    renders: u32 = 0,
    pub fn deinit(_: *PlainGpu) void {}
    pub fn resize(_: *PlainGpu, _: u32, _: u32) void {}
    pub fn uploadVertices(_: *PlainGpu, _: []const vertex.Vertex) void {}
    pub fn uploadText(_: *PlainGpu, _: []const text.TextDraw) void {}
    pub fn uploadImages(_: *PlainGpu, _: []const render.ImageDraw) void {}
    pub fn renderFrame(self: *PlainGpu, _: [4]f32) void {
        self.renders += 1;
    }
    pub fn rasterizeText(_: *PlainGpu, _: []const u8, _: text.FontSpec, _: [4]f32, _: u32, _: u32) text.TextureHandle {
        return text.TEXTURE_HANDLE_NONE;
    }
    pub fn uploadImage(_: *PlainGpu, _: []const u8, _: u32, _: u32) text.TextureHandle {
        return text.TEXTURE_HANDLE_NONE;
    }
    pub fn releaseImage(_: *PlainGpu, _: text.TextureHandle) void {}
};

test "a Gpu without the scene extension still runs scene-bearing apps" {
    const NoResApp = struct {
        pub const Model = struct {};
        pub const Msg = union(enum) { x };
        pub fn update(_: *Model, _: Msg) void {}
        pub fn view(_: *const Model, cb: anytype) void {
            cb.pushGroup(.{ .padding = 0, .gap = 0 });
            cb.scene3d(.{ .style = .{ .width = 20, .height = 20 }, .mesh = 42 });
            cb.popGroup();
        }
    };
    comptime gpu_iface.validateGpu(PlainGpu);
    var host: ScriptHost = .{ .script = &.{ .{}, .{}, .{} } };
    var gpu: PlainGpu = .{};
    // Counts renders per frame, so idle skipping is off for this test.
    var rt = try Runtime(NoResApp, ScriptHost, PlainGpu).init(std.testing.allocator, &host, &gpu, .{ .idle_skip = false });
    defer rt.deinit();
    while (!host.shouldClose()) try rt.frame();
    try std.testing.expectEqual(@as(u32, 3), gpu.renders);
}

test "without the resources hook, scene mesh values are raw Gpu handles" {
    const RawApp = struct {
        pub const Model = struct {};
        pub const Msg = union(enum) { x };
        pub fn update(_: *Model, _: Msg) void {}
        pub fn view(_: *const Model, cb: anytype) void {
            cb.pushGroup(.{ .padding = 0, .gap = 0 });
            cb.scene3d(.{ .style = .{ .width = 20, .height = 20 }, .mesh = 42 });
            cb.popGroup();
        }
    };
    const t = try play(RawApp, &.{ .{}, .{} });
    defer t.destroy();
    try std.testing.expectEqual(@as(u32, 42), t.gpu.last_scene_mesh);
    try std.testing.expectEqual(@as(u32, 0), t.gpu.mesh_uploads);
}

/// Like PointerApp but the interactive surface is a 3D scene.
const SceneApp = struct {
    pub const Model = PointerApp.Model;
    pub const Msg = PointerApp.Msg;
    pub fn update(m: *Model, msg: Msg) void {
        PointerApp.update(m, msg);
    }
    pub fn view(_: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
        cb.scene3d(.{ .style = .{ .width = 200, .height = 100 }, .id = 7, .pointer = true, .label = "view" });
        cb.button(.click, "B");
        cb.popGroup();
    }
    pub const canvasMsg = PointerApp.canvasMsg;
    pub const wheelMsg = PointerApp.wheelMsg;
};

test "scene events: layout, hover, capture through a drag outside, release + leave" {
    const t = try play(SceneApp, &.{
        .{}, // layout
        .{ .x = 50, .y = 40 }, // enter
        .{ .x = 50, .y = 40, .held = left, .down = left }, // press
        .{ .x = 300, .y = 250, .held = left }, // dragged off, still captured
        .{ .x = 300, .y = 250, .up = left }, // release outside
        .{ .x = 300, .y = 250 }, // idle
    });
    defer t.destroy();
    const log = t.rt.model.log.items();
    try expectKinds(log, &.{ .layout, .move, .down, .move, .up, .leave });
    try std.testing.expectEqual(@as(u32, 7), log[0].canvas.id);
    try std.testing.expectEqual(@as(f32, 200), log[0].canvas.w);
    try std.testing.expectEqual(@as(f32, 300), log[3].canvas.x); // captured move past the rect
    for (log) |l| try std.testing.expect(l != .click);
}

test "scene events: wheel over the scene goes to the canvas hook, not wheelMsg" {
    const t = try play(SceneApp, &.{
        .{},
        .{ .x = 50, .y = 40 },
        .{ .x = 50, .y = 40, .wheel_dy = 3 },
    });
    defer t.destroy();
    const log = t.rt.model.log.items();
    var saw_wheel = false;
    for (log) |l| switch (l) {
        .canvas => |ev| if (ev.kind == .wheel) {
            saw_wheel = true;
            try std.testing.expectEqual(@as(u32, 7), ev.id);
            try std.testing.expectEqual(@as(f32, 3), ev.dy);
        },
        .wheel => return error.WheelLeakedToWheelMsg,
        else => {},
    };
    try std.testing.expect(saw_wheel);
}

test "scene events: a press that started elsewhere does not hover the scene" {
    const t = try play(SceneApp, &.{
        .{},
        .{ .x = 20, .y = 120, .held = left, .down = left }, // press on the button below
        .{ .x = 50, .y = 40, .held = left }, // drag over the scene
        .{ .x = 50, .y = 40, .up = left }, // released over it
        .{ .x = 55, .y = 40 }, // now hovering is fine
    });
    defer t.destroy();
    try expectKinds(t.rt.model.log.items(), &.{ .layout, .move });
}

test "cmdsEqual: scene3d fields and keyed canvas batches" {
    const Msg = union(enum) { a };
    const C = cmd.Cmd(Msg);
    const tri = [_]cmd.CanvasPrimitive.TriVertex{
        .{ .x = 0, .y = 0, .r = 1, .g = 1, .b = 1, .a = 1 },
        .{ .x = 1, .y = 0, .r = 1, .g = 1, .b = 1, .a = 1 },
        .{ .x = 0, .y = 1, .r = 1, .g = 1, .b = 1, .a = 1 },
    };
    const copy = tri; // same content, other address
    const Sc = @typeInfo(@FieldType(C, "scene3d")).pointer.child;
    const Cv = @typeInfo(@FieldType(C, "canvas")).pointer.child;
    const sa: Sc = .{ .mesh = 1, .key = 4, .id = 2, .pointer = true };
    const ca: Cv = .{ .primitives = &.{.{ .triangles = .{ .verts = &tri, .key = 9 } }} };
    const a = [_]C{ .{ .scene3d = &sa }, .{ .canvas = &ca } };
    var sb = sa;
    var cbv: Cv = .{ .primitives = &.{.{ .triangles = .{ .verts = &copy, .key = 9 } }} };
    var b = [_]C{ .{ .scene3d = &sb }, .{ .canvas = &cbv } };
    try std.testing.expect(cmdsEqual(Msg, &a, &b));
    sb.key = 5;
    try std.testing.expect(!cmdsEqual(Msg, &a, &b));
    sb.key = 4;
    sb.id = 3;
    try std.testing.expect(!cmdsEqual(Msg, &a, &b));
    sb.id = 2;
    sb.pointer = false;
    try std.testing.expect(!cmdsEqual(Msg, &a, &b));
    sb.pointer = true;
    cbv.primitives = &.{.{ .triangles = .{ .verts = &copy, .key = 10 } }};
    try std.testing.expect(!cmdsEqual(Msg, &a, &b));
}

test "overlay layering: the loop hands the Gpu the overlay split; a Gpu without the hook still runs" {
    const OverlayLayerApp = struct {
        pub const Model = struct {};
        pub const Msg = union(enum) { x };
        pub fn update(_: *Model, _: Msg) void {}
        pub fn view(_: *const Model, cb: anytype) void {
            cb.pushGroup(.{ .padding = 0, .gap = 0 });
            cb.text("under");
            cb.pushOverlay(.{ .x = 0, .y = 0, .width = 100, .height = 40, .backdrop = .{ 1, 1, 1, 1 } });
            cb.text("over");
            cb.popOverlay();
            cb.popGroup();
        }
    };
    const t = try play(OverlayLayerApp, &.{ .{}, .{} });
    defer t.destroy();
    const split = t.gpu.last_split.?;
    try std.testing.expectEqual(@as(u32, 1), split.text); // "under" is base, "over" starts the overlay
    try std.testing.expectEqual(@as(u32, 0), split.verts); // the backdrop quad is overlay

    // PlainGpu has no setOverlayStart: the loop must not require it.
    var host: ScriptHost = .{ .script = &.{ .{}, .{} } };
    var gpu: PlainGpu = .{};
    var rt = try Runtime(OverlayLayerApp, ScriptHost, PlainGpu).init(std.testing.allocator, &host, &gpu, .{});
    defer rt.deinit();
    while (!host.shouldClose()) try rt.frame();
}

const WindowApp = struct {
    pub const Model = struct { w: f32 = 0, h: f32 = 0, calls: u32 = 0 };
    pub const Msg = union(enum) { size: [2]f32 };
    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .size => |s| {
                m.w = s[0];
                m.h = s[1];
                m.calls += 1;
            },
        }
    }
    pub fn view(_: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .padding = 0, .gap = 0 });
        cb.popGroup();
    }
    pub fn windowMsg(_: *const Model, w: f32, h: f32) ?Msg {
        return .{ .size = .{ w, h } };
    }
};

test "run: windowMsg reports the window size on the first frame" {
    const t = try play(WindowApp, &.{ .{}, .{}, .{} });
    defer t.destroy();
    try std.testing.expectEqual(@as(f32, 400), t.rt.model.w);
    try std.testing.expectEqual(@as(f32, 300), t.rt.model.h);
    try std.testing.expectEqual(@as(u32, 1), t.rt.model.calls); // only the first frame resized
}

// ── Accessibility: publish-on-change and actions as input ───────────

const text_field_mod = @import("core/text_field.zig");

const A11yApp = struct {
    const TF = text_field_mod.TextField(16);
    pub const Msg = union(enum) { inc, name: TF.Msg, focus_name, open_modal, close_modal };
    pub const Model = struct {
        count: i32 = 0,
        name: TF.Model = .{},
        focused: bool = false,
        modal: bool = false,
    };
    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .inc => m.count += 1,
            .name => |n| TF.update(&m.name, n),
            .focus_name => m.focused = true,
            .open_modal => m.modal = true,
            .close_modal => m.modal = false,
        }
    }
    pub fn view(m: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .padding = 0, .gap = 0, .a11y = .{ .semantic = .toolbar, .label = "Main" } });
        const label = std.fmt.allocPrint(cb.arena.allocator(), "Count {d}", .{m.count}) catch "?";
        cb.button(.inc, label);
        cb.textInputSelected(.focus_name, m.name.content(), m.name.cursor, m.name.selection_anchor, cb.theme.text_input);
        cb.buttonA11y(.open_modal, "More", .{ .semantic = .menuitem, .expanded = m.modal });
        cb.popGroup();
        if (m.modal) {
            cb.pushOverlay(.{ .x = 0, .y = 0, .width = 400, .height = 300, .modal = true, .backdrop_msg = Msg.close_modal });
            cb.text("Dialog");
            cb.popOverlay();
        }
    }
    pub fn keyCharMsg(m: *const Model, c: u8) ?Msg {
        return if (m.focused) Msg{ .name = .{ .char = c } } else null;
    }
    pub fn keySpecialMsg(m: *const Model, k: keys.SpecialKey) ?Msg {
        if (!m.focused) return null;
        return switch (k) {
            .ctrl_a => Msg{ .name = .select_all },
            else => null,
        };
    }
    pub fn focusedMsg(m: *const Model) ?Msg {
        return if (m.focused) Msg.focus_name else null;
    }
};

fn findNode(h: *const ScriptHost, role: @import("input/a11y.zig").Role) ?host_iface.A11yNode {
    for (h.a11y_nodes[0..h.a11y_count]) |n| if (n.role == role) return n;
    return null;
}

test "a11y: the tree is published on the first frame and on change, not on idle frames" {
    const t = try play(A11yApp, &.{ .{}, .{}, .{}, .{}, .{} });
    defer t.destroy();
    try std.testing.expectEqual(@as(u32, 1), t.host.a11y_publishes);
    try std.testing.expect(findNode(&t.host, .toolbar) != null); // the group's hint became its role
    try std.testing.expectEqualStrings("Count 0", findNode(&t.host, .button).?.label);
}

test "a11y: a model change republishes; focus and hint state are in the tree" {
    // Frame 2 clicks the first button (at 5,5); its label then reads "Count 1".
    const t = try play(A11yApp, &.{
        .{},
        .{},
        .{ .x = 5, .y = 5, .held = left, .down = left },
        .{ .x = 5, .y = 5, .up = left },
        .{},
        .{},
    });
    defer t.destroy();
    try std.testing.expectEqual(@as(u32, 2), t.host.a11y_publishes);
    try std.testing.expectEqualStrings("Count 1", findNode(&t.host, .button).?.label);
    // The toolbar semantic arrived as a role with its name, and the input is a
    // textbox-to-be with an (empty) value.
    var saw_toolbar = false;
    for (t.host.a11y_nodes[0..t.host.a11y_count]) |n| {
        if (n.role == .toolbar) {
            saw_toolbar = true;
            try std.testing.expectEqualStrings("Main", n.label);
        }
    }
    try std.testing.expect(saw_toolbar);
    try std.testing.expect(findNode(&t.host, .text_input) != null);
}

test "a11y: RunOptions.a11y = false publishes nothing" {
    const t = try playWith(A11yApp, .{ .script = &.{ .{}, .{} } }, .{ .a11y = false });
    defer t.destroy();
    try std.testing.expectEqual(@as(u32, 0), t.host.a11y_publishes);
}

test "a11y actions: activate = click, focus = focus Msg, set_value = Ctrl+A + typing, stale index ignored" {
    // Node indexes in the published tree's cmd order: 0 group, 1 button, 2 input, 3 menu button.
    const t = try play(A11yApp, &.{
        .{},
        .{ .a11y = &.{.{ .kind = .activate, .cmd_index = 1 }} },
        .{ .a11y = &.{.{ .kind = .focus, .cmd_index = 2 }} },
        .{ .a11y = &.{.{ .kind = .set_value, .cmd_index = 2, .text = "hello" }} },
        .{ .a11y = &.{.{ .kind = .set_value, .cmd_index = 2, .text = "bye" }} },
        .{ .a11y = &.{.{ .kind = .activate, .cmd_index = 99 }} },
        .{},
    });
    defer t.destroy();
    const m = &t.rt.model;
    try std.testing.expectEqual(@as(i32, 1), m.count); // the activation clicked the button
    try std.testing.expect(m.focused);
    // The second set_value replaced the first (Ctrl+A selects it, typing replaces).
    try std.testing.expectEqualStrings("bye", m.name.content());
}

test "a11y actions: activation respects overlays (a modal swallows what is behind it)" {
    const open = try play(A11yApp, &.{
        .{},
        .{ .a11y = &.{.{ .kind = .activate, .cmd_index = 3 }} }, // "More" opens the modal
        .{},
        .{},
    });
    defer open.destroy();
    try std.testing.expect(open.rt.model.modal);
    try std.testing.expect(findNode(&open.host, .overlay) != null);
    for (open.host.a11y_nodes[0..open.host.a11y_count]) |n| {
        if (n.role == .menuitem) try std.testing.expectEqual(@as(?bool, true), n.expanded);
    }

    // Activating the button behind the open modal is a click on the backdrop:
    // the count does not move (and, like a mouse click outside, it closes the modal).
    const behind = try play(A11yApp, &.{
        .{},
        .{ .a11y = &.{.{ .kind = .activate, .cmd_index = 3 }} },
        .{},
        .{ .a11y = &.{.{ .kind = .activate, .cmd_index = 1 }} },
        .{},
    });
    defer behind.destroy();
    try std.testing.expectEqual(@as(i32, 0), behind.rt.model.count);
    try std.testing.expect(!behind.rt.model.modal);
}

// ── Cursor shapes + display scale ───────────────────────────────────

const CursorApp = struct {
    pub const Model = struct { override: bool = false };
    pub const Msg = union(enum) { click, edit };
    pub fn update(_: *Model, _: Msg) void {}
    pub fn view(_: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .padding = 0, .gap = 0 });
        cb.button(.click, "X");
        cb.buttonDisabled(.click, "off");
        cb.popGroup();
    }
    pub fn cursorFor(m: *const Model, kind: @import("core/cursor.zig").HoverKind) ?host_iface.CursorShape {
        return if (m.override and kind == .none) .crosshair else null;
    }
};

test "run: the cursor follows the hovered widget and setCursor fires only on change" {
    const t = try play(CursorApp, &.{
        .{}, // arrow (nothing hovered; matches the initial shape: no call)
        .{ .x = 5, .y = 5 }, // over the button -> pointer
        .{ .x = 6, .y = 6 }, // still the button: no new call
        .{ .x = 380, .y = 280 }, // empty space -> arrow
    });
    defer t.destroy();
    try std.testing.expectEqual(@as(u32, 2), t.host.cursor_calls);
    try std.testing.expectEqual(host_iface.CursorShape.arrow, t.host.cursor);
}

test "run: cursorFor can override the default and sees the hovered kind" {
    const p = try begin(CursorApp, .{ .script = &.{ .{}, .{}, .{ .x = 5, .y = 5 } } }, .{});
    defer p.destroy();
    p.rt.model.override = true;
    try p.rt.frame(); // empty space + override -> crosshair
    try std.testing.expectEqual(host_iface.CursorShape.crosshair, p.host.cursor);
    try p.rt.frame();
    try p.rt.frame(); // over the button: kind = button, hook declines -> pointer
    try std.testing.expectEqual(host_iface.CursorShape.pointer, p.host.cursor);
}

// ── text_area: pointer, motion, scroll, metrics (text-engine PR11b) ────

const text_area_mod = @import("core/text_area.zig");

/// A one-area app wired the documented way: `textMsg` -> `eventMsg`, chars and
/// special keys while focused, focus from the click.
const AreaApp = struct {
    const TA = text_area_mod.TextArea(1024);
    pub const Msg = union(enum) { area: TA.Msg };
    pub const Model = struct {
        area: TA.Model = .{},
        focused: bool = false,
        metrics_seen: u32 = 0,
        log: EventLog2 = .{},
    };
    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .area => |a| {
                if (a == .focus) m.focused = true;
                if (a == .event) {
                    m.log.push(a.event.kind);
                    if (a.event.kind == .metrics) m.metrics_seen += 1;
                }
                TA.update(&m.area, a);
            },
        }
    }
    pub fn view(m: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .padding = 0, .gap = 0 });
        TA.viewWith(&m.area, cb, .{ .focus = Msg{ .area = .focus } }, .{ .id = 1, .width = 200, .height = 100 });
        cb.popGroup();
    }
    pub fn textMsg(_: *const Model, ev: text_area_mod.TextEvent) ?Msg {
        return .{ .area = TA.eventMsg(ev) };
    }
    pub fn keyCharMsg(m: *const Model, c: u8) ?Msg {
        return if (m.focused) Msg{ .area = TA.charMsg(c) } else null;
    }
    pub fn keySpecialMsg(m: *const Model, k: keys.SpecialKey) ?Msg {
        if (!m.focused) return null;
        return if (TA.keyMsg(k)) |tm| Msg{ .area = tm } else null;
    }
    pub fn focusedMsg(m: *const Model) ?Msg {
        return if (m.focused) Msg{ .area = .focus } else null;
    }
};

const EventLog2 = struct {
    kinds: [64]@import("core/text_event.zig").TextEventKind = undefined,
    n: usize = 0,
    fn push(self: *EventLog2, k: @import("core/text_event.zig").TextEventKind) void {
        if (self.n < self.kinds.len) {
            self.kinds[self.n] = k;
            self.n += 1;
        }
    }
    fn count(self: *const EventLog2, k: @import("core/text_event.zig").TextEventKind) usize {
        var c: usize = 0;
        for (self.kinds[0..self.n]) |x| c += @intFromBool(x == k);
        return c;
    }
};

/// Area at (0,0): border 2 + padding 6 -> text origin (8, 8); inner width 184
/// = 18 mono chars per line, 20 px lines.
fn playArea(initial: []const u8, script: []const Frame) !*Played(AreaApp) {
    const p = try begin(AreaApp, .{ .script = script }, .{});
    errdefer p.destroy();
    p.rt.model.area.set(initial);
    p.rt.model.area.ed.cursor = 0;
    while (!p.host.shouldClose()) try p.rt.frame();
    return p;
}

fn at(col: f32, row: f32) [2]f32 {
    return .{ 8 + col * 10 + 1, 8 + row * 20 + 5 };
}

test "text_area: click puts the caret mid-word, Shift+click extends" {
    const c = at(3, 0);
    const c2 = at(8, 0);
    const t = try playArea("hello world", &.{
        .{},
        .{ .x = c[0], .y = c[1], .held = left, .down = left },
        .{ .x = c[0], .y = c[1], .up = left },
        .{ .x = c2[0], .y = c2[1], .held = left, .down = left, .mods = .{ .shift = true } },
        .{ .x = c2[0], .y = c2[1], .up = left, .mods = .{ .shift = true } },
        .{},
    });
    defer t.destroy();
    const m = &t.rt.model.area;
    try std.testing.expectEqual(@as(usize, 8), m.ed.cursor);
    try std.testing.expectEqualStrings("lo wo", m.selectionText());
    try std.testing.expect(t.rt.model.focused); // the click also focused it
}

test "text_area: drag selects across wrapped lines and keeps selecting outside the rect" {
    // 18 chars per line: "aaaa bbbb cccc dddd eeee ffff" wraps to 2 lines ("aaaa bbbb cccc dddd" is 19).
    const a = at(2, 0);
    const b = at(6, 1);
    const t = try playArea("aaaa bbbb cccc dddd eeee ffff", &.{
        .{},
        .{ .x = a[0], .y = a[1], .held = left, .down = left },
        .{ .x = b[0], .y = b[1], .held = left },
        .{ .x = 700, .y = 600, .held = left }, // far outside the rect: still captured
        .{ .x = 700, .y = 600, .up = left },
        .{},
    });
    defer t.destroy();
    const m = &t.rt.model.area;
    try std.testing.expectEqual(@as(usize, 2), m.ed.selection_anchor.?);
    try std.testing.expectEqual(m.content().len, m.ed.cursor); // dragged past the end
    try std.testing.expect(t.rt.model.log.count(.drag) >= 2);
    try std.testing.expectEqual(@as(usize, 1), t.rt.model.log.count(.up));
}

test "text_area: double click selects a word, triple click the line" {
    const p = at(6, 0); // inside "world"
    const t = try playArea("hello world\nsecond line", &.{
        .{ .clock_ms = 1000 },
        .{ .x = p[0], .y = p[1], .held = left, .down = left, .clock_ms = 1000 },
        .{ .x = p[0], .y = p[1], .up = left, .clock_ms = 1050 },
        .{ .x = p[0], .y = p[1], .held = left, .down = left, .clock_ms = 1100 },
        .{ .x = p[0], .y = p[1], .up = left, .clock_ms = 1150 },
    });
    defer t.destroy();
    try std.testing.expectEqualStrings("world", t.rt.model.area.selectionText());

    const t3 = try playArea("hello world\nsecond line", &.{
        .{ .clock_ms = 1000 },
        .{ .x = p[0], .y = p[1], .held = left, .down = left, .clock_ms = 1000 },
        .{ .x = p[0], .y = p[1], .up = left, .clock_ms = 1050 },
        .{ .x = p[0], .y = p[1], .held = left, .down = left, .clock_ms = 1100 },
        .{ .x = p[0], .y = p[1], .up = left, .clock_ms = 1150 },
        .{ .x = p[0], .y = p[1], .held = left, .down = left, .clock_ms = 1200 },
        .{ .x = p[0], .y = p[1], .up = left, .clock_ms = 1250 },
    });
    defer t3.destroy();
    try std.testing.expectEqualStrings("hello world\n", t3.rt.model.area.selectionText());

    // Too slow (> 400 ms): two single clicks, no word selection.
    const ts = try playArea("hello world", &.{
        .{ .clock_ms = 1000 },
        .{ .x = p[0], .y = p[1], .held = left, .down = left, .clock_ms = 1000 },
        .{ .x = p[0], .y = p[1], .up = left, .clock_ms = 1050 },
        .{ .x = p[0], .y = p[1], .held = left, .down = left, .clock_ms = 1900 },
        .{ .x = p[0], .y = p[1], .up = left, .clock_ms = 1950 },
    });
    defer ts.destroy();
    try std.testing.expect(!ts.rt.model.area.ed.hasSelection());
}

test "text_area: Up/Down/Home/End resolve against the wrapped layout, with a sticky column" {
    const c = at(4, 0);
    const t = try playArea("aaaa bbbb cccc dddd eeee ffff\nshort", &.{
        .{},
        .{ .x = c[0], .y = c[1], .held = left, .down = left },
        .{ .x = c[0], .y = c[1], .up = left },
        .{ .keys = &.{.down} }, // visual line 1: "eeee ffff"
        .{ .keys = &.{.down} }, // hard line "short" (5 chars): clamps, goal stays col 4
        .{ .keys = &.{.down} }, // past the end -> document end
    });
    defer t.destroy();
    const m = &t.rt.model.area;
    try std.testing.expectEqual(m.content().len, m.ed.cursor);

    const t2 = try playArea("aaaa bbbb cccc dddd eeee ffff\nshort", &.{
        .{},
        .{ .x = c[0], .y = c[1], .held = left, .down = left },
        .{ .x = c[0], .y = c[1], .up = left },
        .{ .keys = &.{.down} },
        .{ .keys = &.{.down} },
        .{ .keys = &.{.up} },
        .{ .keys = &.{.shift_end} },
    });
    defer t2.destroy();
    const m2 = &t2.rt.model.area;
    // Down, down (clamped to "short"), up: the sticky column returns to col 4 of
    // the wrapped second line; shift+End extends to that line's visual end.
    try std.testing.expect(m2.ed.hasSelection());
    try std.testing.expectEqual(@as(usize, 29), m2.ed.cursor); // end of "eeee ffff"
    try std.testing.expectEqual(@as(usize, 19), m2.ed.selection_anchor.?); // col 4 of that line
}

test "text_area: wheel scrolls; typing at the bottom reveals the caret via metrics" {
    // 12 hard lines = 240 px of content in an inner height of 84.
    const body = "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12";
    const p = at(1, 1);
    const t = try playArea(body, &.{
        .{},
        .{ .x = p[0], .y = p[1], .wheel_dy = 60 },
        .{ .x = p[0], .y = p[1], .wheel_dy = 1000 },
        .{ .x = p[0], .y = p[1], .wheel_dy = -30 },
    });
    defer t.destroy();
    const m = &t.rt.model.area;
    try std.testing.expect(t.rt.model.metrics_seen >= 1);
    try std.testing.expectEqual(@as(f32, 84), m.viewport_h);
    try std.testing.expectEqual(@as(f32, 240), m.content_h);
    try std.testing.expectEqual(@as(f32, 156 - 30), m.scroll_y); // clamped at content_h - viewport_h, then -30

    // Typing at the end of a long document scrolls the caret into view.
    const q = at(1, 0);
    const t2 = try playArea(body, &.{
        .{},
        .{ .x = q[0], .y = q[1], .held = left, .down = left },
        .{ .x = q[0], .y = q[1], .up = left },
        .{ .keys = &.{.ctrl_end} },
        .{ .chars = "z" },
        .{},
    });
    defer t2.destroy();
    const m2 = &t2.rt.model.area;
    try std.testing.expect(m2.scroll_y > 0);
    try std.testing.expectEqual(@as(f32, 240 - 84), m2.scroll_y); // caret on the last line
}

test "text_area: metrics fire on layout and on change only" {
    const t = try playArea("abc", &.{ .{}, .{}, .{}, .{} });
    defer t.destroy();
    try std.testing.expectEqual(@as(u32, 1), t.rt.model.metrics_seen);

    const q = at(1, 0);
    const t2 = try playArea("abc", &.{
        .{},
        .{ .x = q[0], .y = q[1], .held = left, .down = left },
        .{ .x = q[0], .y = q[1], .up = left },
        .{ .chars = "d" },
        .{},
        .{},
    });
    defer t2.destroy();
    try std.testing.expectEqual(@as(u32, 3), t2.rt.model.metrics_seen); // layout, caret moved to 1, typed
}

test "text_area: a draw frame renders the area (quads + per-line text)" {
    const t = try playArea("hello\nworld", &.{ .{}, .{}, .{} });
    defer t.destroy();
    try std.testing.expect(t.rt.text_draws.items.len >= 2);
}

// Equivalence proof for the reflection-derived diff: for EVERY variant of
// `Cmd`, build a sample payload by reflection, then change each leaf field
// in turn (ints, floats, bools, enums, every slice element, every nested
// optional / union / array) and assert `cmdsEqual` notices. A field added
// to any payload later is covered automatically; one the diff cannot see
// fails here. Unions are exercised for every variant index (`pick`).
const mutation = struct {
    const Alloc = std.mem.Allocator;

    fn wrap(comptime PF: type, a: Alloc, v: anytype) !PF {
        if (@typeInfo(PF) != .pointer) return v;
        const p = try a.create(@TypeOf(v));
        p.* = v;
        return p;
    }

    /// Deterministic non-trivial value of `T`. Every union picks field
    /// `pick % n`. A field named `key` stays 0 so canvas batches compare
    /// by content (a non-zero key deliberately short-circuits the diff).
    fn sample(comptime T: type, a: Alloc, pick: usize, comptime name: []const u8) !T {
        switch (@typeInfo(T)) {
            .void => return {},
            .bool => return false,
            .int => return if (comptime std.mem.eql(u8, name, "key")) 0 else std.math.cast(T, (3 + pick) % 4) orelse 0,
            .float => return 1.5,
            .@"enum" => |i| return @fromBackingInt(@intCast(i.field_values[0])),
            .optional => |i| return try sample(i.child, a, pick, name),
            .array => |i| {
                var out: T = undefined;
                for (&out) |*e| e.* = try sample(i.child, a, pick, name);
                return out;
            },
            .@"struct" => |i| {
                var out: T = undefined;
                inline for (i.field_names, i.field_types) |n, F| {
                    @field(out, n) = try sample(F, a, pick, n);
                }
                return out;
            },
            .@"union" => |i| {
                switch (pick % i.field_names.len) {
                    inline 0...i.field_names.len - 1 => |idx| {
                        const F = i.field_types[idx];
                        return @unionInit(T, i.field_names[idx], try sample(F, a, pick, name));
                    },
                    else => unreachable,
                }
            },
            .pointer => |i| {
                comptime std.debug.assert(i.size == .slice);
                const buf = try a.alloc(i.child, 2);
                for (buf) |*e| e.* = try sample(i.child, a, pick, name);
                return buf;
            },
            else => @compileError("mutation.sample: unsupported " ++ @typeName(T)),
        }
    }

    /// Change the `k`-th leaf (in walk order) of `v`; true once applied.
    fn mutate(comptime T: type, v: *T, k: *usize) bool {
        switch (@typeInfo(T)) {
            .void => return false,
            .bool => {
                if (k.* != 0) {
                    k.* -= 1;
                    return false;
                }
                v.* = !v.*;
                return true;
            },
            .int => {
                if (k.* != 0) {
                    k.* -= 1;
                    return false;
                }
                v.* +%= 1;
                return true;
            },
            .float => {
                if (k.* != 0) {
                    k.* -= 1;
                    return false;
                }
                v.* += 1;
                return true;
            },
            .@"enum" => |i| {
                if (i.field_values.len < 2) return false;
                if (k.* != 0) {
                    k.* -= 1;
                    return false;
                }
                v.* = @fromBackingInt(@intCast(i.field_values[1]));
                return true;
            },
            .optional => |i| {
                if (v.*) |*p| return mutate(i.child, p, k);
                return false;
            },
            .array => |i| {
                for (&v.*) |*e| if (mutate(i.child, e, k)) return true;
                return false;
            },
            .@"struct" => |i| {
                inline for (i.field_names, i.field_types) |n, F| {
                    if (i.layout == .@"packed") {
                        // fields of a packed struct have no addressable storage: edit a copy
                        var f = @field(v.*, n);
                        if (mutate(F, &f, k)) {
                            @field(v.*, n) = f;
                            return true;
                        }
                    } else if (mutate(F, &@field(v.*, n), k)) return true;
                }
                return false;
            },
            .@"union" => switch (v.*) {
                inline else => |*payload| return mutate(@TypeOf(payload.*), payload, k),
            },
            .pointer => |i| {
                for (@constCast(v.*)) |*e| if (mutate(i.child, e, k)) return true;
                return false;
            },
            else => unreachable,
        }
    }
};

test "cmdsEqual: every field of every Cmd variant is observed by the diff" {
    // Msg with a scalar, a slice and a nested struct, so the generic Msg
    // compare (not just tag equality) is covered too.
    const Msg = union(enum) { a, b: u32, c: []const u8, d: struct { f: f32, on: bool } };
    const C = cmd.Cmd(Msg);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var checked: usize = 0;
    inline for (@typeInfo(C).@"union".field_names, @typeInfo(C).@"union".field_types) |vname, PF| {
        // Out-of-line payloads (`*const T` into the frame arena) are sampled and
        // mutated as `T`, then boxed at a fresh address: the diff must follow the pointer.
        const boxed = @typeInfo(PF) == .pointer;
        const P = if (boxed) @typeInfo(PF).pointer.child else PF;
        var pick: usize = 0;
        while (pick < 9) : (pick += 1) {
            const pa = try mutation.sample(P, arena, pick, vname);
            const pb = try mutation.sample(P, arena, pick, vname);
            const ca = [_]C{@unionInit(C, vname, try mutation.wrap(PF, arena, pa))};
            const cb = [_]C{@unionInit(C, vname, try mutation.wrap(PF, arena, pb))};
            // Equal content at distinct addresses must compare equal.
            try std.testing.expect(cmdsEqual(Msg, &ca, &cb));

            var idx: usize = 0;
            while (true) : (idx += 1) {
                var mutated = try mutation.sample(P, arena, pick, vname);
                var k = idx;
                if (!mutation.mutate(P, &mutated, &k)) break;
                const cm = [_]C{@unionInit(C, vname, try mutation.wrap(PF, arena, mutated))};
                std.testing.expect(!cmdsEqual(Msg, &ca, &cm)) catch |e| {
                    std.debug.print("variant {s} pick {d}: leaf #{d} change not detected\n", .{ vname, pick, idx });
                    return e;
                };
                checked += 1;
            }
        }
    }
    try std.testing.expect(checked > 150);
}

test "cmdsEqual: Msg slices compare by content; variant swaps are detected" {
    const Msg = union(enum) { a, b: []const u8 };
    const C = cmd.Cmd(Msg);
    const Btn = @typeInfo(@FieldType(C, "button")).pointer.child;
    const bx: Btn = .{ .msg = .{ .b = "k1" }, .label = "L" };
    const x = [_]C{.{ .button = &bx }};
    var buf = "k1".*;
    const bs: Btn = .{ .msg = .{ .b = &buf }, .label = "L" };
    const same = [_]C{.{ .button = &bs }};
    const bd: Btn = .{ .msg = .{ .b = "k2" }, .label = "L" };
    const diff = [_]C{.{ .button = &bd }};
    const other_tag = [_]C{.{ .checkbox = &.{ .msg = .a, .checked = false, .label = "L" } }};
    try std.testing.expect(cmdsEqual(Msg, &x, &same));
    try std.testing.expect(!cmdsEqual(Msg, &x, &diff));
    try std.testing.expect(!cmdsEqual(Msg, &x, &other_tag));
}

// ── Event-driven idle ───────────────────────────────────────────────

const IdleApp = struct {
    pub const Model = struct { ticks: u32 = 0 };
    pub const Msg = union(enum) { tick };
    pub fn update(m: *Model, _: Msg) void {
        m.ticks += 1;
    }
    pub fn view(m: *const Model, cb: anytype) void {
        cb.pushGroup(.{});
        cb.text(std.fmt.allocPrint(cb.arena.allocator(), "ticks {d}", .{m.ticks}) catch "?");
        cb.popGroup();
    }
    pub fn subscribe(_: *const Model) []const sub_mod.Sub(Msg) {
        return &.{.{ .every = .{ .interval_ms = 100, .msg = .tick } }};
    }
};

fn runIdle(script: []const Frame, opts: run_mod.RunOptions) !struct { renders: u32, ticks: u32, waits: u32, last_wait: u32 } {
    var host: ScriptHost = .{ .script = script };
    var gpu: PlainGpu = .{};
    try run_mod.run(IdleApp, std.testing.allocator, &host, &gpu, opts);
    return .{ .renders = gpu.renders, .ticks = 0, .waits = host.wait_calls, .last_wait = host.last_wait_ms };
}

test "idle: frames with no input, sub or dispatch skip view/render and block in waitEvents" {
    const r = try runIdle(&.{ .{ .clock_ms = 10 }, .{ .clock_ms = 10 }, .{ .clock_ms = 10 }, .{ .clock_ms = 10 } }, .{});
    try std.testing.expectEqual(@as(u32, 1), r.renders); // only the first frame built
    try std.testing.expectEqual(@as(u32, 3), r.waits);
    try std.testing.expectEqual(@as(u32, 90), r.last_wait); // until the 100 ms sub boundary
}

test "idle: a fired sub, a moved mouse and a click each wake the pipeline; idle_skip=false never skips" {
    // Frame 3 crosses the 100 ms boundary: the sub dispatches a Msg.
    const sub_fired = try runIdle(&.{ .{ .clock_ms = 10 }, .{ .clock_ms = 10 }, .{ .clock_ms = 150 }, .{ .clock_ms = 150 } }, .{});
    try std.testing.expectEqual(@as(u32, 2), sub_fired.renders);

    const moved = try runIdle(&.{ .{ .clock_ms = 10 }, .{ .x = 5, .y = 5, .clock_ms = 10 }, .{ .x = 5, .y = 5, .clock_ms = 10 } }, .{});
    try std.testing.expectEqual(@as(u32, 2), moved.renders); // the move built; the still mouse after it did not

    const clicked = try runIdle(&.{ .{}, .{ .held = left, .down = left }, .{ .up = left }, .{} }, .{});
    try std.testing.expectEqual(@as(u32, 3), clicked.renders);

    const never = try runIdle(&.{ .{}, .{}, .{}, .{} }, .{ .idle_skip = false });
    try std.testing.expectEqual(@as(u32, 4), never.renders);
    try std.testing.expectEqual(@as(u32, 0), never.waits);
}

const LayoutIdleApp = struct {
    pub const Model = struct { w: f32 = 0 };
    pub const Msg = union(enum) { size: f32 };
    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .size => |w| m.w = w,
        }
    }
    pub fn view(m: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .padding = 0, .gap = 0 });
        cb.canvasInteractive(.{ .width = 40 + m.w * 0, .height = 20 }, &.{}, 3, "c");
        cb.popGroup();
    }
    pub fn canvasMsg(_: *const Model, ev: pointer.CanvasEvent) ?Msg {
        return if (ev.kind == .layout) Msg{ .size = ev.w } else null;
    }
};

test "idle: a canvas layout Msg dispatched after the build wakes the next frame" {
    // Frame 1 builds and reports the canvas size, which updates the Model after the
    // build; frame 2 has no input and no dispatch of its own but must still rebuild
    // (or the shown frame would keep the stale Model until the next event).
    var host: ScriptHost = .{ .script = &.{ .{}, .{}, .{}, .{} } };
    var gpu: PlainGpu = .{};
    try run_mod.run(LayoutIdleApp, std.testing.allocator, &host, &gpu, .{});
    try std.testing.expectEqual(@as(u32, 2), gpu.renders); // frame 1 and the follow-up; then idle
}

// ── Blink-aware idle ────────────────────────────────────────────────

const FocusApp = struct {
    pub const Model = struct {};
    pub const Msg = union(enum) { focus, noop };
    pub fn update(_: *Model, _: Msg) void {}
    pub fn view(_: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .padding = 0, .gap = 0 });
        cb.textInput(.focus, "ab", 2);
        cb.popGroup();
    }
    pub fn focusedMsg(_: *const Model) ?Msg {
        return .focus;
    }
};

test "idle + blink: a focused input idles, toggling the caret with a vertex-only re-render" {
    // Half-period 500 ms: caret on at t=0..499, off at 500..999, on at 1000.
    const t = try playWith(FocusApp, .{
        .script = &.{
            .{ .clock_ms = 0 }, // builds (caret on)
            .{ .clock_ms = 100 }, // idle, same phase: nothing
            .{ .clock_ms = 499 }, // idle, same phase: nothing
            .{ .clock_ms = 500 }, // toggles off: re-render, still no view
            .{ .clock_ms = 700 }, // idle
            .{ .clock_ms = 1000 }, // toggles on
        },
    }, .{});
    defer t.destroy();
    try std.testing.expectEqual(@as(u32, 1), t.rt.ts.frame_counter); // only the first frame ran view/layout
    try std.testing.expectEqual(@as(u32, 3), t.gpu.upload_vert_calls); // build + off + on
    try std.testing.expect(t.rt.ts.blink_on);
    try std.testing.expect(t.rt.quiet);
}

test "idle + blink: the wait timeout is the nearer of the next caret toggle and the next sub" {
    var host: ScriptHost = .{ .script = &.{ .{ .clock_ms = 0 }, .{ .clock_ms = 120 } } };
    var gpu: PlainGpu = .{};
    try run_mod.run(FocusApp, std.testing.allocator, &host, &gpu, .{});
    try std.testing.expectEqual(@as(u32, 380), host.last_wait_ms); // 500 - 120
    // With blink off the same app has no focus timer: it waits the 1 s cap.
    var host2: ScriptHost = .{ .script = &.{ .{ .clock_ms = 0 }, .{ .clock_ms = 120 } } };
    var gpu2: PlainGpu = .{};
    try run_mod.run(FocusApp, std.testing.allocator, &host2, &gpu2, .{ .blink_half_ms = 0 });
    try std.testing.expectEqual(@as(u32, 1000), host2.last_wait_ms);
}

test "idle + blink: a sub due before the toggle wins the timeout" {
    const FocusSub = struct {
        pub const Model = FocusApp.Model;
        pub const Msg = FocusApp.Msg;
        pub const update = FocusApp.update;
        pub const view = FocusApp.view;
        pub const focusedMsg = FocusApp.focusedMsg;
        pub fn subscribe(_: *const Model) []const sub_mod.Sub(Msg) {
            return &.{.{ .every = .{ .interval_ms = 100, .msg = .noop } }};
        }
    };
    var host: ScriptHost = .{ .script = &.{ .{ .clock_ms = 10 }, .{ .clock_ms = 20 } } };
    var gpu: PlainGpu = .{};
    try run_mod.run(FocusSub, std.testing.allocator, &host, &gpu, .{});
    try std.testing.expectEqual(@as(u32, 80), host.last_wait_ms); // sub at 100 vs caret at 500
}

const AnimApp = struct {
    pub const Model = struct { tween: @import("core/anim.zig").Tween(f32) = .still(0), frames_seen: u32 = 0 };
    pub const Msg = union(enum) { go, frame: u32 };
    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .go => m.tween.start(100, 100, .linear),
            .frame => |dt| {
                m.frames_seen += 1;
                m.tween.advance(dt);
            },
        }
    }
    pub fn view(m: *const Model, cb: anytype) void {
        cb.pushGroup(.{});
        cb.text(std.fmt.allocPrint(cb.arena.allocator(), "v {d}", .{@as(u32, @intFromFloat(m.tween.value()))}) catch "?");
        cb.popGroup();
    }
    pub fn subscribe(m: *const Model) []const sub_mod.Sub(Msg) {
        return if (m.tween.active()) &.{.animation_frame} else &.{};
    }
    pub fn animationMsg(_: *const Model, dt: u32) ?Msg {
        return .{ .frame = dt };
    }
};

test "animation_frame: dt reaches the app, frames flow while active, idle resumes after" {
    var host: ScriptHost = .{
        .script = &.{
            .{ .clock_ms = 0 },
            .{ .clock_ms = 0 },
            .{ .clock_ms = 40 },
            .{ .clock_ms = 80 },
            .{ .clock_ms = 120 }, // tween (100 ms) finished at this frame's dt
            .{ .clock_ms = 120 }, // quiet again
            .{ .clock_ms = 120 },
        },
    };
    var gpu: PlainGpu = .{};
    var rt = try Runtime(AnimApp, ScriptHost, PlainGpu).init(std.testing.allocator, &host, &gpu, .{});
    defer rt.deinit();
    rt.model.tween.start(100, 100, .linear); // as if a Msg.go had run
    while (!host.shouldClose()) try rt.frame();
    try std.testing.expectEqual(@as(f32, 100), rt.model.tween.value());
    try std.testing.expect(!rt.model.tween.active());
    // dt is frame time: 0 (first), 0, 40, 40, 40 -> 120 ms capped by the 100 ms tween.
    try std.testing.expectEqual(@as(u32, 5), rt.model.frames_seen);
    try std.testing.expect(rt.quiet); // finished: the loop idles again
    try std.testing.expect(gpu.renders >= 4 and gpu.renders <= 6);
}

test "animation_frame: dt is capped so a stalled frame cannot skip an animation" {
    var host: ScriptHost = .{ .script = &.{ .{ .clock_ms = 0 }, .{ .clock_ms = 5000 } } };
    var gpu: PlainGpu = .{};
    var rt = try Runtime(AnimApp, ScriptHost, PlainGpu).init(std.testing.allocator, &host, &gpu, .{});
    defer rt.deinit();
    rt.model.tween.start(1000, 1000, .linear);
    while (!host.shouldClose()) try rt.frame();
    try std.testing.expectEqual(@as(f32, 100), rt.model.tween.value()); // advanced by the 100 ms cap, not 5000
}

// ── Keyboard navigation (Tab ring, Space/Enter, arrows) ─────────────────

const NavApp = struct {
    pub const Msg = union(enum) { press: u8, check, pick: u8, vol: f32, grab_vol, focus_name, blur, noop };
    pub const Model = struct {
        pressed: [4]u32 = @splat(0),
        checked: bool = false,
        picked: u8 = 0,
        vol: f32 = 0.5,
        name_focus: bool = false,
        blurs: u32 = 0,
        extra_first: bool = false, // a button inserted BEFORE everything (list mutation)
    };
    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .press => |i| m.pressed[i] += 1,
            .check => m.checked = !m.checked,
            .pick => |i| m.picked = i,
            .vol => |v| m.vol = v,
            .focus_name => m.name_focus = true,
            .blur => {
                m.name_focus = false;
                m.blurs += 1;
            },
            .grab_vol, .noop => {},
        }
    }
    pub fn view(m: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .padding = 0, .gap = 2, .direction = .vertical });
        if (m.extra_first) cb.button(.{ .press = 3 }, "new");
        cb.button(.{ .press = 0 }, "A");
        cb.buttonDisabled(.{ .press = 1 }, "off");
        cb.button(.{ .press = 2 }, "B");
        cb.checkbox(.check, m.checked, "chk");
        cb.pushGroup(.{ .padding = 0, .gap = 0, .direction = .vertical });
        cb.radio(.{ .pick = 0 }, m.picked == 0, "r0");
        cb.radio(.{ .pick = 1 }, m.picked == 1, "r1");
        cb.radio(.{ .pick = 2 }, m.picked == 2, "r2");
        cb.popGroup();
        cb.slider(.grab_vol, m.vol);
        cb.textInput(.focus_name, "", 0);
        cb.popGroup();
    }
    pub fn sliderMsg(_: *const Model, _: Msg, v: f32) ?Msg {
        return .{ .vol = v };
    }
    pub fn focusedMsg(m: *const Model) ?Msg {
        return if (m.name_focus) .focus_name else null;
    }
    pub fn blurMsg(m: *const Model) ?Msg {
        return if (m.name_focus) .blur else null;
    }
    pub fn keySpecialMsg(_: *const Model, _: keys.SpecialKey) ?Msg {
        return null;
    }
};

const TAB: Frame = .{ .keys = &.{.tab} };
const STAB: Frame = .{ .keys = &.{.shift_tab} };

test "keyboard nav: Tab walks buttons, checkbox, radios, slider, text field; disabled is skipped; the ring follows" {
    const t = try playWith(NavApp, .{ .script = &.{ .{}, TAB, .{}, TAB, .{}, TAB, .{}, TAB, .{}, TAB, .{} } }, .{});
    defer t.destroy();
    const cmds = t.rt.bufs[t.rt.current].cmds.items;
    // After five Tabs: A, B (the disabled one skipped), checkbox, r0, r1.
    const ni = t.rt.ts.nav_index.?;
    try std.testing.expect(cmds[ni] == .radio);
    try std.testing.expectEqual(@as(u8, 1), cmds[ni].radio.msg.pick);
}

test "keyboard nav: Shift+Tab goes backwards and wraps; reaching the text field focuses it through its Msg" {
    const t = try playWith(NavApp, .{ .script = &.{ .{}, STAB, .{} } }, .{});
    defer t.destroy();
    // First Shift+Tab from nothing lands on the LAST navigable leaf: the text input.
    try std.testing.expect(t.rt.model.name_focus);
    try std.testing.expect(t.rt.ts.nav_index == null);
}

test "keyboard nav: Space and Enter activate the focused button / checkbox; moving off a text field blurs it" {
    const t = try playWith(NavApp, .{
        .script = &.{
            .{},
            STAB, // text input focused (Model)
            .{},
            TAB, // wraps to the first button A: the app is asked to blur
            .{},
            .{ .chars = " " }, // Space presses A
            .{},
            .{ .keys = &.{.enter} }, // Enter presses A again
            .{},
            TAB, // B
            .{},
            .{ .chars = " " },
            .{},
            TAB, // checkbox
            .{},
            .{ .chars = " " },
            .{},
        },
    }, .{});
    defer t.destroy();
    const m = &t.rt.model;
    try std.testing.expectEqual(@as(u32, 1), m.blurs);
    try std.testing.expect(!m.name_focus);
    try std.testing.expectEqual(@as(u32, 2), m.pressed[0]);
    try std.testing.expectEqual(@as(u32, 1), m.pressed[2]);
    try std.testing.expectEqual(@as(u32, 0), m.pressed[1]); // disabled never fires
    try std.testing.expect(m.checked);
}

test "keyboard nav: arrows inside a radio group move and select, wrapping at the ends" {
    const t = try playWith(NavApp, .{
        .script = &.{
            .{},
            TAB,                    .{}, TAB,                    .{}, TAB, .{}, TAB, .{}, // A, B, checkbox, r0
            .{ .keys = &.{.down} }, .{}, .{ .keys = &.{.down} }, .{},
            .{ .keys = &.{.down} }, // wraps to r0
            .{},
            .{ .keys = &.{.up} }, // back to r2
            .{},
        },
    }, .{});
    defer t.destroy();
    try std.testing.expectEqual(@as(u8, 2), t.rt.model.picked);
}

test "keyboard nav: slider arrows, Home/End and PageUp go through sliderMsg" {
    const t = try playWith(NavApp, .{
        .script = &.{
            .{},
            STAB,                    .{}, STAB,                      .{}, // text field, then the slider
            .{ .keys = &.{.right} }, .{}, .{ .keys = &.{.page_up} }, .{},
            .{ .keys = &.{.end} },   .{}, .{ .keys = &.{.left} },    .{},
        },
    }, .{});
    defer t.destroy();
    try std.testing.expectApproxEqAbs(@as(f32, 0.95), t.rt.model.vol, 0.001);
}

test "keyboard nav: focus follows its widget when a button is inserted before it" {
    const t = try begin(NavApp, .{ .script = &.{ .{}, TAB, .{}, TAB, .{}, .{}, .{} } }, .{});
    defer t.destroy();
    try t.rt.frame();
    try t.rt.frame();
    try t.rt.frame(); // A focused
    try t.rt.frame();
    try t.rt.frame(); // B focused
    var cmds = t.rt.bufs[t.rt.current].cmds.items;
    try std.testing.expectEqual(@as(u8, 2), cmds[t.rt.ts.nav_index.?].button.msg.press);
    t.rt.model.extra_first = true; // a new first button shifts every index
    try t.rt.frame();
    try t.rt.frame();
    cmds = t.rt.bufs[t.rt.current].cmds.items;
    try std.testing.expectEqual(@as(u8, 2), cmds[t.rt.ts.nav_index.?].button.msg.press);
}

test "keyboard nav: clicking a widget moves the keyboard focus there" {
    // A is the top-left button.
    const t = try playWith(NavApp, .{ .script = &.{
        .{},
        .{ .x = 5, .y = 5, .held = left, .down = left },
        .{ .x = 5, .y = 5, .up = left },
        .{},
        .{ .keys = &.{.enter} },
        .{},
    } }, .{});
    defer t.destroy();
    try std.testing.expectEqual(@as(u32, 2), t.rt.model.pressed[0]); // the click, then Enter on the focused button
}

test "keyboard nav off: Tab walks only text fields, as before" {
    const t = try playWith(NavApp, .{ .script = &.{ .{}, TAB, .{} } }, .{ .keyboard_nav = false });
    defer t.destroy();
    try std.testing.expect(t.rt.model.name_focus);
    try std.testing.expect(t.rt.ts.nav_index == null);
}

const ModalNavApp = struct {
    pub const Msg = union(enum) { open, close, ok, behind };
    pub const Model = struct { open: bool = false, oks: u32 = 0, behind: u32 = 0 };
    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .open => m.open = true,
            .close => m.open = false,
            .ok => m.oks += 1,
            .behind => m.behind += 1,
        }
    }
    pub fn view(m: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .padding = 0, .gap = 2 });
        cb.button(.open, "Open");
        cb.button(.behind, "Behind");
        if (m.open) {
            cb.pushOverlay(.{ .width = 360, .height = 300, .modal = true, .backdrop = .{ 0, 0, 0, 0.5 } });
            cb.button(.ok, "OK");
            cb.button(.close, "Close");
            cb.popOverlay();
        }
        cb.popGroup();
    }
    pub fn keySpecialMsg(m: *const Model, k: keys.SpecialKey) ?Msg {
        return if (m.open and k == .escape) .close else null;
    }
};

test "keyboard nav: a modal traps Tab, takes focus on open, and returns it to the opener on close" {
    const t = try playWith(ModalNavApp, .{
        .script = &.{
            .{},
            TAB, .{}, // Open
            .{ .keys = &.{.enter} }, .{}, // opens the modal: focus moves inside (OK)
            .{ .chars = " " }, .{}, // Space presses OK, not "Open"/"Behind"
            TAB, .{}, // Close
            TAB,               .{}, // wraps inside the modal: OK again (never "Behind")
            .{ .chars = " " }, .{},
            TAB, .{}, // Close
            .{ .keys = &.{.escape} }, .{}, // app closes the modal
            .{ .keys = &.{.enter} }, .{}, // focus is back on Open: Enter reopens it
        },
    }, .{});
    defer t.destroy();
    try std.testing.expectEqual(@as(u32, 2), t.rt.model.oks);
    try std.testing.expectEqual(@as(u32, 0), t.rt.model.behind);
    try std.testing.expect(t.rt.model.open); // reopened by Enter on the restored focus
}

// ── Lists: one Tab stop + roving arrows; dropdown keys; context-menu key ──

fn RovingApp(comptime select: bool) type {
    return struct {
        pub const Msg = union(enum) { pick: u8, before, after };
        pub const Model = struct { active: u8 = 1, picks: u32 = 0, last: u8 = 255, after: u32 = 0 };
        pub fn update(m: *Model, msg: Msg) void {
            switch (msg) {
                .pick => |i| {
                    m.active = i;
                    m.last = i;
                    m.picks += 1;
                },
                .before => {},
                .after => m.after += 1,
            }
        }
        pub fn view(m: *const Model, cb: anytype) void {
            cb.pushGroup(.{ .padding = 0, .gap = 0 });
            cb.button(.before, "before");
            cb.pushGroup(.{ .padding = 0, .gap = 0 });
            for (0..4) |i| {
                cb.buttonNav(.{ .pick = @intCast(i) }, "row", cb.theme.button, .{
                    .tab_stop = i == m.active,
                    .roving = if (select) .select else .focus,
                });
            }
            cb.popGroup();
            cb.button(.after, "after");
            cb.popGroup();
        }
    };
}

test "lists: a roving list is ONE Tab stop; arrows move the focus (focus mode: Enter activates)" {
    const A = RovingApp(false);
    const t = try playWith(A, .{
        .script = &.{
            .{},
            TAB, .{}, // before
            TAB, .{}, // the list's active row (1)
            .{ .keys = &.{.down} }, .{}, // row 2: focus only, no Msg
            .{ .keys = &.{.down} }, .{}, // row 3
            .{ .keys = &.{.down} }, .{}, // clamped at the end
            .{ .keys = &.{.enter} }, .{}, // activates row 3
            TAB,                     .{}, // leaves the list: after
            .{ .keys = &.{.enter} }, .{},
        },
    }, .{});
    defer t.destroy();
    try std.testing.expectEqual(@as(u32, 1), t.rt.model.picks);
    try std.testing.expectEqual(@as(u8, 3), t.rt.model.last);
    try std.testing.expectEqual(@as(u32, 1), t.rt.model.after);
}

test "lists: select mode dispatches the row Msg as the focus moves; Home/End/PageDown jump" {
    const A = RovingApp(true);
    const t = try playWith(A, .{
        .script = &.{
            .{},
            TAB,                   .{}, TAB,                    .{}, // row 1
            .{ .keys = &.{.end} }, .{}, .{ .keys = &.{.home} }, .{},
            .{ .keys = &.{.page_down} }, .{}, // +5 clamps to the last row
        },
    }, .{});
    defer t.destroy();
    try std.testing.expectEqual(@as(u8, 3), t.rt.model.active);
    try std.testing.expectEqual(@as(u32, 3), t.rt.model.picks);
}

const DropApp = struct {
    const DD = @import("core/dropdown.zig").Dropdown(4);
    const opts_list = [_][]const u8{ "Small", "Medium", "Large" };
    pub const Msg = union(enum) { drop: DD.Msg, other };
    pub const Model = struct { drop: DD.Model = .{ .selected = 0 }, other: u32 = 0 };
    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .drop => |d| DD.update(&m.drop, d),
            .other => m.other += 1,
        }
    }
    fn sel(i: usize) Msg {
        return .{ .drop = .{ .select = i } };
    }
    pub fn view(m: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .padding = 0, .gap = 4 });
        cb.button(.other, "x");
        DD.viewWith(&m.drop, cb, &opts_list, .{ .toggle = Msg{ .drop = .toggle }, .close = Msg{ .drop = .close }, .selectMsg = sel }, .{ .list_x = 0, .list_y = 60, .list_width = 120 });
        cb.popGroup();
    }
    pub fn keySpecialMsg(m: *const Model, k: keys.SpecialKey) ?Msg {
        if (DD.keyMsg(&m.drop, k, opts_list.len, .{})) |d| return .{ .drop = d };
        return null;
    }
};

test "dropdown: Tab to the trigger, Enter opens, arrows + Enter choose, focus returns to the trigger" {
    const t = try playWith(DropApp, .{
        .script = &.{
            .{},
            TAB, .{}, TAB, .{}, // x, then the trigger
            .{ .keys = &.{.enter} }, .{}, // opens the list (focus moves into it)
            .{ .keys = &.{.down} },  .{},
            .{ .keys = &.{.down} },  .{},
            .{ .keys = &.{.enter} }, .{}, // chooses "Large", closes
            .{ .keys = &.{.enter} }, .{}, // focus is back on the trigger: reopens
            .{ .keys = &.{.escape} }, .{}, // Escape closes without changing
        },
    }, .{});
    defer t.destroy();
    try std.testing.expectEqual(@as(usize, 2), t.rt.model.drop.selected);
    try std.testing.expect(!t.rt.model.drop.open);
    try std.testing.expectEqual(@as(u32, 0), t.rt.model.other);
}

const CtxApp = struct {
    pub const Msg = union(enum) { check, ctx: [2]f32 };
    pub const Model = struct { on: bool = false, at: ?[2]f32 = null, hit_check: bool = false };
    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .check => m.on = !m.on,
            .ctx => |p| m.at = p,
        }
    }
    pub fn view(m: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .padding = 0, .gap = 0 });
        cb.button(.check, "first");
        cb.checkbox(.check, m.on, "chk");
        cb.popGroup();
    }
    pub fn contextMsg(_: *const Model, ev: pointer.PointerEvent(Msg)) ?Msg {
        return .{ .ctx = .{ ev.x, ev.y } };
    }
};

test "context menu key: Menu / Shift+F10 asks contextMsg at the focused widget's bottom-left" {
    const t = try playWith(CtxApp, .{ .script = &.{ .{}, TAB, .{}, TAB, .{}, .{ .keys = &.{.context_menu} }, .{} } }, .{});
    defer t.destroy();
    const pos = t.rt.model.at.?;
    const cmds = t.rt.bufs[t.rt.current].cmds.items;
    const r = t.rt.rects[t.rt.current].items[t.rt.ts.nav_index.?];
    try std.testing.expect(cmds[t.rt.ts.nav_index.?] == .checkbox);
    try std.testing.expectEqual(r.x, pos[0]);
    try std.testing.expectEqual(r.y + r.h, pos[1]);
}

// ── Keyboard gaps: split divider, scroll regions, tooltip focus, toast Escape ──

const split_w = @import("core/widgets/split.zig");
const toast_w = @import("core/widgets/toast.zig");

const SplitKeyApp = struct {
    pub const Msg = union(enum) { split: split_w.Msg, after };
    pub const Model = struct { split: split_w.Model = .{}, after: u32 = 0 };
    const opts: split_w.Opts = .{ .width = 400, .height = 100, .min_a = 50, .min_b = 50 };
    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .split => |s| split_w.update(&m.split, s),
            .after => m.after += 1,
        }
    }
    pub fn view(m: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .padding = 0, .gap = 0 });
        split_w.begin(&m.split, cb, opts);
        cb.text("left");
        split_w.dividerFocusable(&m.split, cb, opts, Msg{ .split = .focus });
        cb.button(.after, "right pane");
        split_w.end(cb);
        cb.popGroup();
    }
    pub fn canvasMsg(m: *const Model, ev: pointer.CanvasEvent) ?Msg {
        if (split_w.canvasMsg(&m.split, ev, opts)) |s| return .{ .split = s };
        return null;
    }
};

test "keyboard nav: a focused split divider resizes with arrows, collapses with Home / End" {
    // Tab order: the divider, then the button in the right pane.
    const t = try playWith(SplitKeyApp, .{ .script = &.{
        .{},
        TAB,
        .{},
        .{ .keys = &.{.right} },
        .{},
        .{ .keys = &.{.right} },
        .{},
    } }, .{});
    defer t.destroy();
    const cmds = t.rt.bufs[t.rt.current].cmds.items;
    try std.testing.expect(cmds[t.rt.ts.nav_index.?] == .canvas);
    try std.testing.expectApproxEqAbs((197.0 + 32.0) / 394.0, t.rt.model.split.ratio, 0.001);

    const t2 = try playWith(SplitKeyApp, .{ .script = &.{
        .{},                    TAB, .{},
        .{ .keys = &.{.home} }, .{},
    } }, .{});
    defer t2.destroy();
    try std.testing.expectApproxEqAbs(50.0 / 394.0, t2.rt.model.split.ratio, 0.001);

    const t3 = try playWith(SplitKeyApp, .{
        .script = &.{
            .{},                   TAB, .{},
            .{ .keys = &.{.end} }, .{},
            .{ .keys = &.{.up} }, .{}, // vertical keys do nothing on a horizontal split
            .{ .keys = &.{.enter} }, .{}, // Enter is the no-op focus Msg
        },
    }, .{});
    defer t3.destroy();
    try std.testing.expectApproxEqAbs(344.0 / 394.0, t3.rt.model.split.ratio, 0.001);
}

const ScrollKeyApp = struct {
    pub const Msg = union(enum) { press: u8 };
    pub const Model = struct { dy: f32 = 0, dx: f32 = 0, calls: u32 = 0, id: u32 = 0, pressed: u32 = 0 };
    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .press => m.pressed += 1,
        }
    }
    pub fn view(_: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .padding = 0, .gap = 0 });
        cb.pushScroll(.{ .id = 7, .height = 100, .padding = 0, .gap = 0 });
        var i: u8 = 0;
        while (i < 10) : (i += 1) cb.button(.{ .press = i }, "row");
        cb.popScroll();
        cb.popGroup();
    }
    pub fn scrollMsg(_: *const Model, _: u32, _: f32, _: f32) ?Msg {
        return null;
    }
};

const ScrollRecordApp = struct {
    pub const Msg = union(enum) { press: u8, scrolled: [3]f32 };
    pub const Model = struct { last: [3]f32 = .{ 0, 0, 0 }, calls: u32 = 0 };
    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .press => {},
            .scrolled => |s| {
                m.last = s;
                m.calls += 1;
            },
        }
    }
    pub fn view(m: *const Model, cb: anytype) void {
        ScrollKeyApp.view(&.{}, cb);
        _ = m;
    }
    pub fn scrollMsg(_: *const Model, id: u32, dx: f32, dy: f32) ?Msg {
        return .{ .scrolled = .{ @floatFromInt(id), dx, dy } };
    }
};

test "keyboard nav: arrows / PageUp / PageDown / Home / End scroll the region around the focused widget" {
    const t = try playWith(ScrollRecordApp, .{
        .script = &.{
            .{},
            TAB,                    .{}, // first row button focused
            .{ .keys = &.{.down} }, .{},
        },
    }, .{});
    defer t.destroy();
    try std.testing.expectEqual(@as(f32, 7), t.rt.model.last[0]);
    try std.testing.expectEqual(@as(f32, 40), t.rt.model.last[2]);

    const t2 = try playWith(ScrollRecordApp, .{ .script = &.{
        .{},                         TAB, .{},
        .{ .keys = &.{.page_down} }, .{},
    } }, .{});
    defer t2.destroy();
    try std.testing.expect(t2.rt.model.last[2] > 40 and t2.rt.model.last[2] <= 100);

    const t3 = try playWith(ScrollRecordApp, .{
        .script = &.{
            .{},                   TAB, .{},
            .{ .keys = &.{.end} }, .{}, .{ .keys = &.{.home} },
            .{},
            .{ .keys = &.{.left} }, .{}, // vertical region: Left is not a scroll key
        },
    }, .{});
    defer t3.destroy();
    try std.testing.expect(t3.rt.model.last[2] < -1.0e6);
    try std.testing.expectEqual(@as(u32, 2), t3.rt.model.calls);
}

const TipFocusApp = struct {
    pub const Msg = union(enum) { a, b };
    pub const Model = struct { hovers: u32 = 0, last_hit: ?Msg = null, last_box_w: f32 = 0 };
    pub fn update(_: *Model, _: Msg) void {}
    pub fn view(_: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .padding = 0, .gap = 2 });
        cb.button(.a, "A");
        cb.button(.b, "B");
        cb.popGroup();
    }
    pub var seen_hits: [8]?Msg = @splat(null);
    pub var seen_n: usize = 0;
    pub fn hoverMsg(_: *const Model, ev: pointer.PointerEvent(Msg)) ?Msg {
        if (seen_n < seen_hits.len) {
            seen_hits[seen_n] = ev.hit;
            seen_n += 1;
        }
        return null;
    }
};

test "keyboard nav: tabbing reports the focused widget through hoverMsg (so a tooltip shows)" {
    TipFocusApp.seen_n = 0;
    const t = try playWith(TipFocusApp, .{
        .script = &.{
            .{ .x = 390, .y = 290 }, // pointer parked over nothing
            .{},
            TAB,
            .{},
            .{},
            TAB,
            .{},
            .{},
            TAB, .{}, .{}, // wraps to A
        },
    }, .{});
    defer t.destroy();
    var saw_a = false;
    var saw_b = false;
    for (TipFocusApp.seen_hits[0..TipFocusApp.seen_n]) |h| {
        if (h) |m| switch (m) {
            .a => saw_a = true,
            .b => saw_b = true,
        };
    }
    try std.testing.expect(saw_a and saw_b);
}

test "toast: Escape dismisses the newest showing toast, then the next, then nothing" {
    const Ts = toast_w.Toast(3, 16);
    var m: Ts.Model = .{};
    try std.testing.expect(Ts.keyMsg(&m, .escape) == null); // nothing showing
    Ts.push(&m, .info, "one", 0);
    Ts.push(&m, .info, "two", 0);
    try std.testing.expect(Ts.keyMsg(&m, .enter) == null);
    const first = Ts.keyMsg(&m, .escape).?;
    try std.testing.expectEqual(m.items[1].id, first.dismiss);
    Ts.update(&m, first); // starts leaving
    const second = Ts.keyMsg(&m, .escape).?;
    try std.testing.expectEqual(m.items[0].id, second.dismiss);
    Ts.update(&m, second);
    try std.testing.expect(Ts.keyMsg(&m, .escape) == null); // both leaving
}

// ── Clipboard hooks ─────────────────────────────────────────────────

const ClipApp = struct {
    pub const Model = struct { text: [32]u8 = undefined, len: usize = 0, sel_len: usize = 0, pastes: u32 = 0 };
    pub const Msg = union(enum) { paste: []const u8, cut, copied, noop };
    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .paste => |t| {
                @memcpy(m.text[m.len..][0..t.len], t);
                m.len += t.len;
                m.pastes += 1;
            },
            .cut => m.len = 0,
            .copied, .noop => {},
        }
    }
    pub fn view(_: *const Model, cb: anytype) void {
        cb.pushGroup(.{});
        cb.text("clip");
        cb.popGroup();
    }
    pub fn clipboardText(m: *const Model, key: keys.SpecialKey) ?[]const u8 {
        if (key != .ctrl_c and key != .ctrl_x) return null;
        return if (m.len > 0) m.text[0..m.len] else null;
    }
    pub fn clipboardMsg(_: *const Model, key: keys.SpecialKey, text_in: []const u8) ?Msg {
        return switch (key) {
            .ctrl_v => .{ .paste = text_in },
            .ctrl_x => .cut,
            .ctrl_c => .copied,
            else => null,
        };
    }
};

test "clipboardMsg: Ctrl+V delivers the clipboard text as a Msg through update" {
    const t = try playWith(ClipApp, .{ .script = &.{ .{}, .{ .keys = &.{.ctrl_v} }, .{ .keys = &.{.ctrl_v} } }, .clip_in = "ab" }, .{});
    defer t.destroy();
    try std.testing.expectEqual(@as(u32, 2), t.rt.model.pastes);
    try std.testing.expectEqualStrings("abab", t.rt.model.text[0..t.rt.model.len]);
}

test "clipboardText + clipboardMsg: Ctrl+C copies without mutating, Ctrl+X copies then cuts" {
    const t = try playWith(ClipApp, .{
        .script = &.{
            .{},
            .{ .keys = &.{.ctrl_v} }, // model now holds "xyz"
            .{ .keys = &.{.ctrl_c} },
            .{ .keys = &.{.ctrl_x} },
        },
        .clip_in = "xyz",
    }, .{});
    defer t.destroy();
    try std.testing.expectEqual(@as(u32, 2), t.host.clip_writes); // copy and cut each wrote
    try std.testing.expectEqualStrings("xyz", t.host.clip_out[0..t.host.clip_out_len]);
    try std.testing.expectEqual(@as(usize, 0), t.rt.model.len); // the cut ran AFTER the text was read
}

test "clipboardMsg: an empty paste is not delivered (image pastes stay unclaimed)" {
    const t = try playWith(ClipApp, .{ .script = &.{ .{}, .{ .keys = &.{.ctrl_v} } }, .clip_in = "" }, .{});
    defer t.destroy();
    try std.testing.expectEqual(@as(u32, 0), t.rt.model.pastes);
}

test "handleClipboard (deprecated adapter) still works for apps that have not migrated" {
    const Old = struct {
        pub const Model = struct { pasted: u32 = 0 };
        pub const Msg = union(enum) { noop };
        pub fn update(_: *Model, _: Msg) void {}
        pub fn view(_: *const Model, cb: anytype) void {
            cb.pushGroup(.{});
            cb.text("old");
            cb.popGroup();
        }
        pub fn keyNeedsClipboard(k: keys.SpecialKey) bool {
            return k == .ctrl_v;
        }
        pub fn handleClipboard(m: *Model, _: keys.SpecialKey, clip: host_iface.Clipboard) void {
            if (clip.read().len > 0) m.pasted += 1;
        }
    };
    const t = try playWith(Old, .{ .script = &.{ .{}, .{ .keys = &.{.ctrl_v} } }, .clip_in = "q" }, .{});
    defer t.destroy();
    try std.testing.expectEqual(@as(u32, 1), t.rt.model.pasted);
}

// ── Enter in a focused text_area is a key, not a submit ─────────────

const EnterApp = struct {
    pub const Model = struct { area_focused: bool = true, submits: u32 = 0, newlines: u32 = 0 };
    pub const Msg = union(enum) { focus_area, focus_in, submit, newline };
    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .submit => m.submits += 1,
            .newline => m.newlines += 1,
            else => {},
        }
    }
    pub fn view(m: *const Model, cb: anytype) void {
        cb.pushGroup(.{});
        if (m.area_focused) {
            cb.textArea(.{ .focus_msg = .focus_area, .id = 1, .content = "", .cursor = 0, .height = 60 });
        } else {
            cb.textInput(.focus_in, "", 0);
        }
        cb.popGroup();
    }
    pub fn focusedMsg(m: *const Model) ?Msg {
        return if (m.area_focused) .focus_area else .focus_in;
    }
    pub fn submitMsg(_: *const Model) ?Msg {
        return .submit;
    }
    pub fn keySpecialMsg(_: *const Model, k: keys.SpecialKey) ?Msg {
        return if (k == .enter) .newline else null;
    }
};

test "Enter: a focused text_area gets it as a key (keySpecialMsg), a text_input still submits" {
    const t = try play(EnterApp, &.{ .{}, .{ .keys = &.{.enter} } });
    defer t.destroy();
    try std.testing.expectEqual(@as(u32, 1), t.rt.model.newlines);
    try std.testing.expectEqual(@as(u32, 0), t.rt.model.submits);

    var host: ScriptHost = .{ .script = &.{ .{}, .{ .keys = &.{.enter} } } };
    var gpu: StubGpu = .{};
    var rt = try Runtime(EnterApp, ScriptHost, StubGpu).init(std.testing.allocator, &host, &gpu, .{});
    defer rt.deinit();
    rt.model.area_focused = false;
    while (!host.shouldClose()) try rt.frame();
    try std.testing.expectEqual(@as(u32, 1), rt.model.submits);
    try std.testing.expectEqual(@as(u32, 0), rt.model.newlines);
}

// ── pointerMsg: one hook, blank-space clicks included ───────────────

const PmApp = struct {
    pub const Model = struct { focused: bool = true, blank_downs: u32 = 0, widget_downs: u32 = 0, ups: u32 = 0, contexts: u32 = 0, hovers: u32 = 0, last_button: pointer.Button = .none };
    pub const Msg = union(enum) { a, b, blur, saw: struct { kind: pointer.PointerEvent(Msg).Kind, blank: bool, button: pointer.Button } };
    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .blur => m.focused = false,
            .saw => |s| {
                m.last_button = s.button;
                switch (s.kind) {
                    .down => if (s.blank) {
                        m.blank_downs += 1;
                    } else {
                        m.widget_downs += 1;
                    },
                    .up => m.ups += 1,
                    .context => m.contexts += 1,
                    .hover => m.hovers += 1,
                }
            },
            .a, .b => {},
        }
    }
    pub fn view(_: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .padding = 0, .gap = 0, .direction = .vertical });
        cb.button(.a, "A");
        cb.popGroup();
    }
    pub fn pointerMsg(m: *const Model, ev: pointer.PointerEvent(Msg)) ?Msg {
        // The documented recipe: a press on blank space clears focus.
        if (ev.kind == .down and ev.isBlank() and m.focused) return .blur;
        return .{ .saw = .{ .kind = ev.kind, .blank = ev.isBlank(), .button = ev.button } };
    }
};

test "pointerMsg: blank-space press (kind=down, hit=null) lets the app clear focus; widget presses carry their Msg" {
    const t = try play(PmApp, &.{
        .{}, // lays out
        .{ .x = 300, .y = 200, .held = left, .down = left }, // press on blank space
        .{ .x = 300, .y = 200, .up = left },
        .{ .x = 5, .y = 5, .held = left, .down = left }, // press on button A
        .{ .x = 5, .y = 5, .up = left },
    });
    defer t.destroy();
    try std.testing.expect(!t.rt.model.focused); // the blank press delivered .blur
    try std.testing.expectEqual(@as(u32, 1), t.rt.model.widget_downs);
    try std.testing.expectEqual(@as(u32, 2), t.rt.model.ups);
    try std.testing.expect(t.rt.model.hovers >= 1); // entering A
}

test "pointerMsg: the right button arrives as kind=context with button=right" {
    const t = try play(PmApp, &.{
        .{},
        .{ .x = 5, .y = 5, .held = right, .down = right },
    });
    defer t.destroy();
    try std.testing.expectEqual(@as(u32, 1), t.rt.model.contexts);
    try std.testing.expectEqual(pointer.Button.right, t.rt.model.last_button);
}
