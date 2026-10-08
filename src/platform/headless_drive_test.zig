//! End-to-end tests of the agent control channel and input record/replay on
//! the headless Host (docs/features/agent-driver.md): a small todo app is
//! driven over the real Unix-socket protocol, and a scripted session is
//! recorded then replayed to an identical final frame.

const std = @import("std");
const teak = @import("teak");
const Host = @import("headless.zig").Host;
const control_socket = @import("control_socket.zig");

// ── The app under test: a miniature of examples/todo ───────────────

const App = struct {
    pub const Item = struct { label: [32]u8 = @splat(0), len: u8 = 0, done: bool = false };
    pub const Model = struct {
        items: [8]Item = @splat(.{}),
        n: usize = 0,
        input: [32]u8 = @splat(0),
        input_len: u8 = 0,
        focused: bool = false,
    };
    pub const Msg = union(enum) { focus, char: u8, backspace, add, toggle: usize };

    pub fn update(m: *Model, msg: Msg) void {
        switch (msg) {
            .focus => m.focused = true,
            .char => |c| if (m.input_len < m.input.len) {
                m.input[m.input_len] = c;
                m.input_len += 1;
            },
            .backspace => if (m.input_len > 0) {
                m.input_len -= 1;
            },
            .add => if (m.input_len > 0 and m.n < m.items.len) {
                m.items[m.n] = .{ .len = m.input_len };
                @memcpy(m.items[m.n].label[0..m.input_len], m.input[0..m.input_len]);
                m.n += 1;
                m.input_len = 0;
            },
            .toggle => |i| if (i < m.n) {
                m.items[i].done = !m.items[i].done;
            },
        }
    }

    pub fn view(m: *const Model, cb: anytype) void {
        cb.pushGroup(.{ .direction = .vertical, .padding = 16, .gap = 8 });
        cb.text("Todo");
        cb.pushGroup(.{ .direction = .horizontal, .gap = 8, .padding = 0 });
        cb.textInput(.focus, m.input[0..m.input_len], m.input_len);
        cb.button(.add, "Add");
        cb.popGroup();
        for (m.items[0..m.n], 0..) |*it, i| cb.checkbox(.{ .toggle = i }, it.done, it.label[0..it.len]);
        cb.popGroup();
    }

    pub fn keyCharMsg(m: *const Model, c: u8) ?Msg {
        return if (m.focused) .{ .char = c } else null;
    }
    pub fn keySpecialMsg(m: *const Model, k: teak.SpecialKey) ?Msg {
        if (!m.focused) return null;
        return switch (k) {
            .backspace => .backspace,
            .enter => .add,
            else => null,
        };
    }
    pub fn debugState(m: *const Model, w: *std.Io.Writer) void {
        w.print("items={d} input={s}", .{ m.n, m.input[0..m.input_len] }) catch {};
    }
};

/// Minimal Gpu: the loop only needs these (no pixels, so no `readFrame`).
const StubGpu = struct {
    pub fn deinit(_: *StubGpu) void {}
    pub fn resize(_: *StubGpu, _: u32, _: u32) void {}
    pub fn uploadVertices(_: *StubGpu, _: []const teak.Vertex) void {}
    pub fn uploadText(_: *StubGpu, _: []const teak.TextDraw) void {}
    pub fn uploadImages(_: *StubGpu, _: anytype) void {}
    pub fn renderFrame(_: *StubGpu, _: [4]f32) void {}
    pub fn rasterizeText(_: *StubGpu, _: []const u8, _: teak.FontSpec, _: [4]f32, _: u32, _: u32) teak.TextureHandle {
        return teak.TEXTURE_HANDLE_NONE;
    }
    pub fn uploadImage(_: *StubGpu, _: []const u8, _: u32, _: u32) teak.TextureHandle {
        return teak.TEXTURE_HANDLE_NONE;
    }
};

const Rt = teak.Runtime(App, Host, StubGpu);

fn testHost() !Host {
    return Host.init(std.testing.allocator, 480, 360) catch |e| switch (e) {
        error.FontNotFound => return error.SkipZigTest,
        else => return e,
    };
}

fn tmpPath(buf: []u8, comptime what: []const u8) ![]u8 {
    return std.fmt.bufPrint(buf, "/tmp/teak-drive-test-{d}-" ++ what, .{std.os.linux.getpid()});
}

/// Send `line`, run frames until the reply is readable, return it.
fn ask(rt: *Rt, cl: *control_socket.Client, line: []const u8) ![]u8 {
    try cl.sendLine(line);
    // The reply is written from inside a frame; a fresh command is picked up
    // by the next one. Bound the frames so a bug fails the test, not hangs it.
    var fds = [_]std.os.linux.pollfd{.{ .fd = cl.fd, .events = std.os.linux.POLL.IN, .revents = 0 }};
    for (0..200) |_| {
        try rt.frame();
        if (std.os.linux.poll(&fds, 1, 0) == 1) return cl.readLine(std.testing.allocator);
    }
    return error.NoReply;
}

fn expectOk(reply: []const u8) !void {
    if (std.mem.indexOf(u8, reply, "\"ok\":true") == null) {
        std.debug.print("expected ok, got: {s}\n", .{reply});
        return error.NotOk;
    }
}

test "control channel: drive the todo app with selectors, typing, keys and queries" {
    if (comptime !control_socket.supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var sock_buf: [96]u8 = undefined;
    const sock = try tmpPath(&sock_buf, "ctl.sock");

    var host = try testHost();
    defer host.deinit();
    var gpu: StubGpu = .{};
    var rt = try Rt.init(gpa, &host, &gpu, .{ .control_path = sock });
    defer rt.deinit();
    try std.testing.expect(rt.ctl.active);
    try rt.frame();

    var cl = try control_socket.Client.connect(sock);
    defer cl.close();

    // info
    {
        const r = try ask(&rt, &cl, "{\"cmd\":\"info\"}");
        defer gpa.free(r);
        try expectOk(r);
        try std.testing.expect(std.mem.indexOf(u8, r, "\"width\":480") != null);
    }
    // Focus the input by selector, type, press Enter: three todos.
    {
        const r = try ask(&rt, &cl, "{\"cmd\":\"click\",\"selector\":{\"role\":\"text_input\"}}");
        defer gpa.free(r);
        try expectOk(r);
        try std.testing.expect(std.mem.indexOf(u8, r, "\"last_msg\":\"focus\"") != null);
    }
    for ([_][]const u8{ "milk", "eggs", "bread" }) |item| {
        var buf: [96]u8 = undefined;
        const t = try std.fmt.bufPrint(&buf, "{{\"cmd\":\"type\",\"text\":\"{s}\"}}", .{item});
        const r1 = try ask(&rt, &cl, t);
        gpa.free(r1);
        const r2 = try ask(&rt, &cl, "{\"cmd\":\"key\",\"name\":\"enter\"}");
        defer gpa.free(r2);
        try expectOk(r2);
    }
    try std.testing.expectEqual(@as(usize, 3), rt.model.n);
    try std.testing.expectEqualStrings("eggs", rt.model.items[1].label[0..rt.model.items[1].len]);

    // Click the Add button too (empty input: no-op) then toggle "eggs" by label.
    {
        const r = try ask(&rt, &cl, "{\"cmd\":\"click\",\"selector\":{\"role\":\"checkbox\",\"label\":\"EGGS\"}}");
        defer gpa.free(r);
        try expectOk(r);
        try std.testing.expect(rt.model.items[1].done and !rt.model.items[0].done);
    }
    // A selector that matches nothing is a clean error, not a hang.
    {
        const r = try ask(&rt, &cl, "{\"cmd\":\"click\",\"selector\":{\"role\":\"button\",\"label\":\"nonexistent\"}}");
        defer gpa.free(r);
        try std.testing.expect(std.mem.indexOf(u8, r, "\"ok\":false") != null);
    }
    // tree: valid JSON, with the three checkboxes and the checked state.
    {
        const r = try ask(&rt, &cl, "{\"cmd\":\"tree\"}");
        defer gpa.free(r);
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, r, .{});
        defer parsed.deinit();
        const nodes = parsed.value.object.get("nodes").?.array.items;
        var boxes: usize = 0;
        var checked: usize = 0;
        for (nodes) |n| {
            if (std.mem.eql(u8, n.object.get("role").?.string, "checkbox")) {
                boxes += 1;
                if (n.object.get("checked").?.bool) checked += 1;
            }
        }
        try std.testing.expectEqual(@as(usize, 3), boxes);
        try std.testing.expectEqual(@as(usize, 1), checked);
    }
    // snapshot carries the typed items.
    {
        const r = try ask(&rt, &cl, "{\"cmd\":\"snapshot\"}");
        defer gpa.free(r);
        try std.testing.expect(std.mem.indexOf(u8, r, "milk") != null);
        try std.testing.expect(std.mem.indexOf(u8, r, "bread") != null);
    }
    // msglog shows the transitions, newest last.
    {
        const r = try ask(&rt, &cl, "{\"cmd\":\"msglog\",\"n\":2}");
        defer gpa.free(r);
        try std.testing.expect(std.mem.indexOf(u8, r, ".toggle(1)") != null);
        try std.testing.expect(std.mem.indexOf(u8, r, ".char(") == null);
    }
    // state via the debugState hook.
    {
        const r = try ask(&rt, &cl, "{\"cmd\":\"state\"}");
        defer gpa.free(r);
        try std.testing.expect(std.mem.indexOf(u8, r, "items=3") != null);
    }
    // wait until_text succeeds immediately, then times out on absent text.
    {
        const r = try ask(&rt, &cl, "{\"cmd\":\"wait\",\"until_text\":\"milk\"}");
        defer gpa.free(r);
        try expectOk(r);
        const r2 = try ask(&rt, &cl, "{\"cmd\":\"wait\",\"until_text\":\"nope\",\"timeout_frames\":3}");
        defer gpa.free(r2);
        try std.testing.expect(std.mem.indexOf(u8, r2, "timeout") != null);
    }
    // A screenshot on a Gpu without readFrame is a clean error.
    {
        const r = try ask(&rt, &cl, "{\"cmd\":\"screenshot\",\"path\":\"/tmp/never.png\"}");
        defer gpa.free(r);
        try std.testing.expect(std.mem.indexOf(u8, r, "\"ok\":false") != null);
    }
    // quit closes the host.
    {
        const r = try ask(&rt, &cl, "{\"cmd\":\"quit\"}");
        defer gpa.free(r);
        try expectOk(r);
        try std.testing.expect(host.shouldClose());
    }
}

fn centerOf(rt: *Rt, comptime tag: std.meta.Tag(@TypeOf(rt.bufs[0].cmds.items[0])), nth: usize) [2]f32 {
    var seen: usize = 0;
    for (rt.bufs[rt.current].cmds.items, 0..) |c, i| {
        if (c != tag) continue;
        if (seen == nth) {
            const r = rt.rects[rt.current].items[i];
            return .{ r.x + r.w / 2, r.y + r.h / 2 };
        }
        seen += 1;
    }
    unreachable;
}

fn finalSnapshot(rt: *Rt) ![]u8 {
    return teak.snapshotAlloc(std.testing.allocator, rt.bufs[rt.current].cmds.items, rt.rects[rt.current].items, .{
        .header = .{ .window_w = 480, .window_h = 360, .frame = rt.ts.frame_counter, .last_msg = rt.last_msg },
        .transient = &rt.ts,
    });
}

test "record a scripted todo session, replay it to an identical final snapshot" {
    const gpa = std.testing.allocator;
    var rec_buf: [96]u8 = undefined;
    const rec_path = try tmpPath(&rec_buf, "session.rec");
    defer std.Io.Dir.cwd().deleteFile(std.Options.debug_io, rec_path) catch {};

    var recorded: []u8 = undefined;
    var frames: u32 = 0;
    {
        var host = try testHost();
        defer host.deinit();
        var gpu: StubGpu = .{};
        var rt = try Rt.init(gpa, &host, &gpu, .{ .record_path = rec_path });
        defer rt.deinit();
        try rt.frame();
        try rt.frame();

        const input = centerOf(&rt, .text_input, 0);
        try teak.headless.play(&rt, &host, &.{ .{ .click = input }, .{ .chars = "milk" }, .{ .key = .enter }, .{ .frames = 1 } });
        try teak.headless.play(&rt, &host, &.{ .{ .chars = "eggs" }, .{ .key = .enter }, .{ .frames = 1 } });
        try teak.headless.play(&rt, &host, &.{ .{ .chars = "xy" }, .{ .key = .backspace }, .{ .key = .enter }, .{ .frames = 2 } });
        const box = centerOf(&rt, .checkbox, 1);
        try teak.headless.play(&rt, &host, &.{ .{ .click = box }, .{ .frames = 2 } });
        try std.testing.expectEqual(@as(usize, 3), rt.model.n);
        try std.testing.expect(rt.model.items[1].done);
        frames = rt.ctl.frame_no;
        recorded = try finalSnapshot(&rt);
    }
    defer gpa.free(recorded);

    // The recording is plain text, one line per frame that had input.
    const file = try std.Io.Dir.cwd().readFileAlloc(std.Options.debug_io, rec_path, gpa, .limited(1 << 20));
    defer gpa.free(file);
    try std.testing.expect(std.mem.indexOf(u8, file, "c=6d696c6b") != null); // "milk"
    try std.testing.expect(std.mem.indexOf(u8, file, "k=enter") != null);

    {
        var host = try testHost();
        defer host.deinit();
        var gpu: StubGpu = .{};
        var rt = try Rt.init(gpa, &host, &gpu, .{ .replay_path = rec_path });
        defer rt.deinit();
        for (0..frames) |_| try rt.frame();
        try std.testing.expect(rt.ctl.replayDone());
        try std.testing.expectEqual(@as(usize, 3), rt.model.n);
        const replayed = try finalSnapshot(&rt);
        defer gpa.free(replayed);
        try std.testing.expectEqualStrings(recorded, replayed);
    }
}

test "inspector: TEAK_INSPECT-style option draws the panel; F12 toggles it; control reads stay app-only" {
    const gpa = std.testing.allocator;
    var host = try testHost();
    defer host.deinit();
    var gpu: StubGpu = .{};
    var rt = try Rt.init(gpa, &host, &gpu, .{ .inspect = true, .inspect_hotkey = true });
    defer rt.deinit();
    for (0..3) |_| try rt.frame();

    const has = struct {
        fn panel(r: *Rt) bool {
            for (r.bufs[r.current].cmds.items) |c| switch (c) {
                .text => |t| if (std.mem.indexOf(u8, t.content, "TEAK INSPECTOR") != null) return true,
                else => {},
            };
            return false;
        }
    };
    try std.testing.expect(has.panel(&rt));
    // The app-only view (what `snapshot` / `tree` read) has no panel.
    try std.testing.expect(rt.ctl.app_len[rt.current] < rt.bufs[rt.current].cmds.items.len);

    host.pushKey(.f12);
    try rt.frame();
    try rt.frame();
    try std.testing.expect(!has.panel(&rt));
    host.pushKey(.f12);
    try rt.frame();
    try rt.frame();
    try std.testing.expect(has.panel(&rt));
}

test "idle: a listening control channel caps the quiet wait at one frame; commands finish on quiet frames" {
    if (comptime !control_socket.supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var sock_buf: [96]u8 = undefined;
    const sock = try tmpPath(&sock_buf, "idle.sock");
    var host = try testHost();
    defer host.deinit();
    var gpu: StubGpu = .{};

    // Without a control channel the idle wait is the long default.
    {
        var rt0 = try Rt.init(gpa, &host, &gpu, .{});
        defer rt0.deinit();
        for (0..3) |_| try rt0.frame();
        try std.testing.expect(rt0.quiet);
        try std.testing.expect(rt0.idleTimeoutMs() > 16);
    }
    var rt = try Rt.init(gpa, &host, &gpu, .{ .control_path = sock });
    defer rt.deinit();
    for (0..3) |_| try rt.frame();
    try std.testing.expect(rt.quiet); // nothing happening: frames are skipped...
    try std.testing.expect(rt.idleTimeoutMs() <= 16); // ...but the Host must come back within a frame

    // A wait command is made of quiet frames; it still completes.
    var cl = try control_socket.Client.connect(sock);
    defer cl.close();
    const r = try ask(&rt, &cl, "{\"cmd\":\"wait\",\"frames\":3}");
    defer gpa.free(r);
    try expectOk(r);
    try std.testing.expect(rt.quiet);

    // Toggling the inspector over the channel forces a rebuilt frame even
    // though no input arrived.
    const before = rt.bufs[rt.current].cmds.items.len;
    const r2 = try ask(&rt, &cl, "{\"cmd\":\"inspect\",\"on\":true}");
    defer gpa.free(r2);
    try rt.frame();
    try std.testing.expect(rt.bufs[rt.current].cmds.items.len > before);
}
