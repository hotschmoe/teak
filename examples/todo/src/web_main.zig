//! Wasm entry for the todo example. Mirrors counter_greeter/web_main
//! but wired for the todo app. Zunk owns the rAF loop; this file
//! exports `init` / `frame` / `resize` for zunk to call.

const std = @import("std");
const teak = @import("teak");
const platform = @import("teak-platform-wasm");
const gpu_web = @import("teak-gpu-web");
const App = @import("app.zig");

const Host = platform.Host;
const Gpu = gpu_web.Gpu;

comptime {
    teak.validateHost(Host);
    teak.validateGpu(Gpu);
}

const MAX_RECTS: usize = 2048;
const CmdBufT = teak.CmdBuffer(App.Msg);

var scratch_bytes: [1 << 20]u8 = undefined;
var fba: std.heap.FixedBufferAllocator = undefined;

var host: Host = undefined;
var gpu: Gpu = undefined;
var model: App.Model = .{};

var bufs: [2]CmdBufT = undefined;
var rects_store: [2][MAX_RECTS]teak.Rect = undefined;
var rects_len: [2]usize = .{ 0, 0 };
var current: u1 = 0;

var verts: std.ArrayList(teak.Vertex) = .empty;
var text_draws: std.ArrayList(teak.TextDraw) = .empty;

var transient_state: teak.TransientState = .{};
var press_target: ?usize = null;

export fn init() void {
    fba = std.heap.FixedBufferAllocator.init(&scratch_bytes);
    const alloc = fba.allocator();

    host = Host.init("Teak — Todo", 720, 600) catch unreachable;
    gpu = Gpu.init(host.nativeHandle(), 720, 600) catch unreachable;

    bufs[0] = CmdBufT.init(alloc);
    bufs[1] = CmdBufT.init(alloc);
}

export fn resize(w: u32, h: u32) void {
    gpu.resize(w, h);
}

export fn frame(_: f32) void {
    const alloc = fba.allocator();
    const input = host.pollInputs();
    if (input.resized) gpu.resize(input.width, input.height);

    const prev = current;
    const prev_cmds = bufs[prev].cmds.items;
    const prev_rects = rects_store[prev][0..rects_len[prev]];
    const hover_under_mouse: ?usize = if (prev_cmds.len > 0)
        teak.hoverTest(prev_cmds, prev_rects, input.mouse_x, input.mouse_y)
    else
        null;

    if (input.mouse_down) press_target = hover_under_mouse;
    if (input.mouse_up) {
        if (press_target != null and hover_under_mouse == press_target) {
            if (teak.hitTest(prev_cmds, prev_rects, input.mouse_x, input.mouse_y)) |hit| {
                App.update(&model, hit.msg);
            }
        }
        press_target = null;
    }
    if (press_target != null and hover_under_mouse != press_target) {
        press_target = null;
    }

    for (input.chars) |ch| {
        if (App.keyCharMsg(&model, ch)) |m| App.update(&model, m);
    }
    for (input.keys) |k| {
        if (App.keySpecialMsg(&model, k)) |m| App.update(&model, m);
    }

    current ^= 1;
    const cur = current;
    bufs[cur].reset();
    App.view(&model, &bufs[cur]);

    const cur_cmds = bufs[cur].cmds.items;
    if (cur_cmds.len > MAX_RECTS) return;

    teak.LayoutEngine.doLayout(
        rects_store[cur][0..cur_cmds.len],
        cur_cmds,
        @floatFromInt(input.width),
        @floatFromInt(input.height),
        host.textMeasurer(),
    );
    rects_len[cur] = cur_cmds.len;

    transient_state.hover_index = teak.hoverTest(cur_cmds, rects_store[cur][0..cur_cmds.len], input.mouse_x, input.mouse_y);
    transient_state.press_index = press_target;
    transient_state.focus_index = focusIndex(cur_cmds, model.input_focused);
    transient_state.mouse_x = input.mouse_x;
    transient_state.mouse_y = input.mouse_y;
    transient_state.frame_counter +%= 1;

    verts.clearRetainingCapacity();
    text_draws.clearRetainingCapacity();
    teak.buildVertices(&verts, &text_draws, alloc, cur_cmds, rects_store[cur][0..cur_cmds.len], transient_state, host.textMeasurer());
    gpu.uploadVertices(verts.items);
    gpu.uploadText(text_draws.items);
    gpu.renderFrame(.{ 0.08, 0.08, 0.1, 1.0 });
}

fn focusIndex(cmds: []const teak.Cmd(App.Msg), focused: bool) ?usize {
    if (!focused) return null;
    for (cmds, 0..) |cc, i| {
        if (cc == .text_input) return i;
    }
    return null;
}
