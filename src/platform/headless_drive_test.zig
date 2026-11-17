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
    pub const Msg = union(enum) { focus, char: u8, backspace, add, toggle: usize, drag: teak.DragEvent };

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
            .drag => |ev| if (ev.phase == .drop and ev.over != 0 and ev.id != ev.over and ev.id <= m.n and ev.over <= m.n) {
                const from = ev.id - 1;
                const to = ev.over - 1;
                const it = m.items[from];
                if (from < to) {
                    std.mem.copyForwards(Item, m.items[from..to], m.items[from + 1 .. to + 1]);
                } else {
                    std.mem.copyBackwards(Item, m.items[to + 1 .. from + 1], m.items[to..from]);
                }
                m.items[to] = it;
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
        for (m.items[0..m.n], 0..) |*it, i| {
            const id: u32 = @intCast(i + 1);
            cb.pushGroup(.{ .direction = .horizontal, .padding = 2, .gap = 8, .drag_id = id, .drop_id = id });
            cb.text("::");
            cb.checkbox(.{ .toggle = i }, it.done, it.label[0..it.len]);
            cb.popGroup();
        }
        cb.popGroup();
    }

    pub fn dragMsg(_: *const Model, ev: teak.DragEvent) ?Msg {
        return .{ .drag = ev };
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
    pub fn commands(m: *const Model, list: *teak.CommandList(Msg)) void {
        list.add(.{ .id = "todo.add", .label = "Add item", .shortcut = teak.Chord.ctrl(.enter), .enabled = m.input_len > 0, .msg = .add });
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





