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
        if (f.fx_result) |r| self.queueResult(r);
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
    pub fn clipboard(_: *ScriptHost) host_iface.Clipboard {
        return .{ .ctx = undefined, .read_fn = readEmpty, .write_fn = writeDiscard };
    }
    fn readEmpty(_: *anyopaque) []const u8 {
        return "";
    }
    fn writeDiscard(_: *anyopaque, _: []const u8) void {}
    pub fn imeState(self: *const ScriptHost) host_iface.ImeState {
        return .{ .active = self.ime_on, .text = self.ime_buf[0..self.ime_len], .cursor = self.ime_len };
    }
    pub fn publishA11yTree(_: *ScriptHost, _: []const host_iface.A11yNode) void {}
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
    pub fn renderScenes(self: *StubGpu, d: []const render.SceneDraw) void {
        self.scene_calls += 1;
        self.last_scene_count = d.len;
        if (d.len > 0) self.last_scene_mesh = d[0].mesh;
    }
    fn takeHandle(self: *StubGpu) u32 {
        defer self.next_handle += 1;
        return self.next_handle;
    }
    pub fn renderFrame(self: *StubGpu, _: [4]f32) void {
        self.render_calls += 1;
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
    }, .{ .blink_period = 0 });
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
    const a = [_]C{
        .{ .scene3d = .{ .mesh = 1, .key = 4, .id = 2, .pointer = true } },
        .{ .canvas = .{ .primitives = &.{.{ .triangles = .{ .verts = &tri, .key = 9 } }} } },
    };
    var b = [_]C{
        .{ .scene3d = .{ .mesh = 1, .key = 4, .id = 2, .pointer = true } },
        .{ .canvas = .{ .primitives = &.{.{ .triangles = .{ .verts = &copy, .key = 9 } }} } },
    };
    try std.testing.expect(cmdsEqual(Msg, &a, &b));
    b[0].scene3d.key = 5;
    try std.testing.expect(!cmdsEqual(Msg, &a, &b));
    b[0].scene3d.key = 4;
    b[0].scene3d.id = 3;
    try std.testing.expect(!cmdsEqual(Msg, &a, &b));
    b[0].scene3d.id = 2;
    b[0].scene3d.pointer = false;
    try std.testing.expect(!cmdsEqual(Msg, &a, &b));
    b[0].scene3d.pointer = true;
    b[1].canvas.primitives = &.{.{ .triangles = .{ .verts = &copy, .key = 10 } }};
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

// Equivalence proof for the reflection-derived diff: for EVERY variant of
// `Cmd`, build a sample payload by reflection, then change each leaf field
// in turn (ints, floats, bools, enums, every slice element, every nested
// optional / union / array) and assert `cmdsEqual` notices. A field added
// to any payload later is covered automatically; one the diff cannot see
// fails here. Unions are exercised for every variant index (`pick`).
const mutation = struct {
    const Alloc = std.mem.Allocator;

    /// Deterministic non-trivial value of `T`. Every union picks field
    /// `pick % n`. A field named `key` stays 0 so canvas batches compare
    /// by content (a non-zero key deliberately short-circuits the diff).
    fn sample(comptime T: type, a: Alloc, pick: usize, comptime name: []const u8) !T {
        switch (@typeInfo(T)) {
            .void => return {},
            .bool => return false,
            .int => return if (comptime std.mem.eql(u8, name, "key")) 0 else @truncate(3 + pick),
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
                    if (mutate(F, &@field(v.*, n), k)) return true;
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
    inline for (@typeInfo(C).@"union".field_names, @typeInfo(C).@"union".field_types) |vname, P| {
        var pick: usize = 0;
        while (pick < 9) : (pick += 1) {
            const pa = try mutation.sample(P, arena, pick, vname);
            const pb = try mutation.sample(P, arena, pick, vname);
            const ca = [_]C{@unionInit(C, vname, pa)};
            const cb = [_]C{@unionInit(C, vname, pb)};
            // Equal content at distinct addresses must compare equal.
            try std.testing.expect(cmdsEqual(Msg, &ca, &cb));

            var idx: usize = 0;
            while (true) : (idx += 1) {
                var mutated = try mutation.sample(P, arena, pick, vname);
                var k = idx;
                if (!mutation.mutate(P, &mutated, &k)) break;
                const cm = [_]C{@unionInit(C, vname, mutated)};
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
    const x = [_]C{.{ .button = .{ .msg = .{ .b = "k1" }, .label = "L" } }};
    var buf = "k1".*;
    const same = [_]C{.{ .button = .{ .msg = .{ .b = &buf }, .label = "L" } }};
    const diff = [_]C{.{ .button = .{ .msg = .{ .b = "k2" }, .label = "L" } }};
    const other_tag = [_]C{.{ .checkbox = .{ .msg = .a, .checked = false, .label = "L" } }};
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
