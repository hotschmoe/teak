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



// ── Frame diff (cmdsEqual) ──────────────────────────────────────────



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



// Verbatim copy of docs/cookbook.md recipe 23 (keeps the doc honest).
const Recipe23 = struct {
    const teak = @import("teak.zig");

    const Notes = teak.TextArea(4096); // capacity in bytes

    pub const Model = struct {
        notes: Notes.Model = .{},
        focused: bool = false, // who owns the keyboard
    };
    pub const Msg = union(enum) { notes: Notes.Msg };

    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .notes => |a| {
                if (a == .focus) m.focused = true; // a click on the area
                Notes.update(&m.notes, a);
            },
        }
    }

    pub fn view(m: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .padding = 16, .gap = 8, .align_cross = .stretch });
        cb.heading("NOTES");
        // `id` must be distinct and non-zero per area; it names the area in events.
        Notes.viewWith(&m.notes, cb, .{ .focus = Msg{ .notes = .focus } }, .{ .id = 1, .height = 220 });
        cb.popGroup();
    }

    // ── Hooks teak.run looks for (all optional, by declaration) ──────────

    /// Pointer, wheel, resolved motion keys and layout metrics: one line per area.
    pub fn textMsg(_: *const Model, ev: teak.TextEvent) ?Msg {
        return .{ .notes = Notes.eventMsg(ev) };
    }

    /// Typed characters (a UTF-8 byte at a time; the editor assembles them).
    pub fn keyCharMsg(m: *const Model, c: u8) ?Msg {
        return if (m.focused) Msg{ .notes = Notes.charMsg(c) } else null;
    }

    /// Enter, Backspace/Delete, Left/Right, Ctrl+arrows, Ctrl+Z/Y/A, ...
    /// (Up/Down/PageUp/PageDown/Home/End never reach here: they arrive via `textMsg`.)
    pub fn keySpecialMsg(m: *const Model, k: teak.SpecialKey) ?Msg {
        if (!m.focused) return null;
        return if (Notes.keyMsg(k)) |a| Msg{ .notes = a } else null;
    }

    /// Lets the loop know which area has focus (Tab traversal, caret blink, IME spot).
    pub fn focusedMsg(m: *const Model) ?Msg {
        return if (m.focused) Msg{ .notes = .focus } else null;
    }

    // Clipboard is the app's policy: Ctrl+C / X / V reach you with the Host clipboard.
    pub fn keyNeedsClipboard(k: teak.SpecialKey) bool {
        return teak.keyNeedsClipboard(k);
    }
    pub fn handleClipboard(m: *Model, k: teak.SpecialKey, clip: teak.Clipboard) void {
        switch (k) {
            .ctrl_c => if (m.notes.selectionText().len > 0) clip.write(m.notes.selectionText()),
            .ctrl_x => if (m.notes.selectionText().len > 0) {
                clip.write(m.notes.selectionText());
                update(m, .{ .notes = .{ .key = .backspace } });
            },
            .ctrl_v => if (clip.read().len > 0) update(m, .{ .notes = Notes.pasteMsg(clip.read()) }),
            else => {},
        }
    }
};


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
                    else => {},
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



// ── pointerMsg: capture across target kinds, wheel fallback, adapters ──

/// One app with every pointer surface (canvas 7, slider, text area 1, scroll
/// region 3, a button), logging each `PointerEvent` it receives. Declares ONLY
/// `pointerMsg` (+ `wheelMsg`, the fallback).
const PmSurf = struct {
    const TA = text_area_mod.TextArea(1024);
    pub const Tag = enum { none, widget, canvas, text, slider, scroll };
    pub const Seen = struct { kind: pointer.PointerKind, tag: Tag, id: u32 = 0, x: f32 = 0, value: f32 = 0, offset: u32 = 0, clicks: u8 = 1 };
    pub const Msg = union(enum) { seen: Seen, wheel: f32, area: TA.Msg, grab, click };
    pub const Model = struct {
        log: [96]Seen = undefined,
        n: usize = 0,
        wheels: u32 = 0,
        area: TA.Model = .{},
        /// What `pointerMsg` answers for a `wheel` (null = decline, bubble on).
        claim_wheel: bool = false,
        /// `pointerMsg` declines slider events (the slider stays a plain click).
        ignore_slider: bool = false,
        grabs: u32 = 0,
        fn items(self: *const Model) []const Seen {
            return self.log[0..self.n];
        }
        fn count(self: *const Model, kind: pointer.PointerKind, tag: Tag) usize {
            var c: usize = 0;
            for (self.items()) |s| c += @intFromBool(s.kind == kind and s.tag == tag);
            return c;
        }
    };
    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .seen => |s| if (m.n < m.log.len) {
                m.log[m.n] = s;
                m.n += 1;
            },
            .wheel => m.wheels += 1,
            .area => |a| TA.update(&m.area, a),
            .grab => m.grabs += 1,
            .click => {},
        }
    }
    pub fn view(m: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .direction = .vertical, .padding = 0, .gap = 0 });
        cb.canvasInteractive(.{ .width = 200, .height = 100 }, &.{}, 7, "c"); // y 0..100
        cb.slider(.grab, 0.5); // y 100..
        TA.viewWith(&m.area, cb, .{ .focus = Msg{ .area = .focus } }, .{ .id = 1, .width = 200, .height = 100 });
        cb.pushScroll(.{ .id = 3, .width = 200, .height = 80, .padding = 0 });
        cb.button(.click, "row");
        cb.popScroll();
        cb.popGroup();
    }
    pub fn pointerMsg(m: *const Model, ev: pointer.PointerEvent(Msg)) ?Msg {
        if (ev.kind == .wheel and !m.claim_wheel and ev.target == .none) return null;
        if (m.ignore_slider and ev.target == .slider) return null;
        const s: Seen = switch (ev.target) {
            .none => .{ .kind = ev.kind, .tag = .none },
            .widget => .{ .kind = ev.kind, .tag = .widget },
            .canvas => |id| .{ .kind = ev.kind, .tag = .canvas, .id = id, .x = ev.local_x },
            .text_area => |t| .{ .kind = ev.kind, .tag = .text, .id = t.id, .offset = t.offset, .clicks = ev.clicks },
            .slider => |sl| .{ .kind = ev.kind, .tag = .slider, .value = sl.value },
            .scroll => |id| .{ .kind = ev.kind, .tag = .scroll, .id = id },
        };
        if (ev.target == .text_area) {
            if (ev.asText()) |te| return .{ .area = TA.eventMsg(te) };
        }
        return .{ .seen = s };
    }
    pub fn wheelMsg(_: *const Model, dy: f32) ?Msg {
        return .{ .wheel = dy };
    }
};

fn playSurf(initial: []const u8, host: ScriptHost) !*Played(PmSurf) {
    const p = try begin(PmSurf, host, .{});
    errdefer p.destroy();
    p.rt.model.area.set(initial);
    p.rt.model.area.ed.cursor = 0;
    while (!p.host.shouldClose()) try p.rt.frame();
    return p;
}







// ── Frame stats, continuous mode, exit-after-frames, HUD (#127) ─────





