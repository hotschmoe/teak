//! Wasm entry for scene3d. Zunk owns the rAF loop and calls the exported
//! `init` / `frame` / `resize`; this file is the hand-written equivalent of
//! `teak.run` for that shape: it sends the animation `.tick` itself (there
//! is no `Host.nowMs` sub clock here), keeps the declarative resource table
//! in sync (`teak.ResourceTable`) and stages draws with `teak.stageDraws`,
//! which remaps the mesh key to the uploaded handle and runs the scene pass.

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

const MAX_RECTS: usize = 256;
const CmdBufT = teak.CmdBuffer(App.Msg);

var scratch_bytes: [4 << 20]u8 = undefined;
var fba: std.heap.FixedBufferAllocator = undefined;

var host: Host = undefined;
var gpu: Gpu = undefined;
var model: App.Model = .{};
var resources: teak.ResourceTable = .{};

var bufs: [2]CmdBufT = undefined;
var rects_store: [2][MAX_RECTS]teak.Rect = undefined;
var rects_len: [2]usize = .{ 0, 0 };
var current: u1 = 0;

var verts: std.ArrayList(teak.Vertex) = .empty;
var text_draws: std.ArrayList(teak.TextDraw) = .empty;
var image_draws: std.ArrayList(teak.ImageDraw) = .empty;
var scene_draws: std.ArrayList(teak.SceneDraw) = .empty;

var transient_state: teak.TransientState = .{};
var press_target: ?usize = null;

export fn init() void {
    fba = std.heap.FixedBufferAllocator.init(&scratch_bytes);
    const alloc = fba.allocator();

    host = Host.init("Teak scene3d", 900, 500) catch unreachable;
    gpu = Gpu.initWithOptions(host.nativeHandle(), 900, 500, .{ .msaa = true }) catch unreachable;

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
    const hover: ?usize = if (prev_cmds.len > 0)
        teak.hoverTest(prev_cmds, prev_rects, input.mouse_x, input.mouse_y)
    else
        null;

    if (input.mouse_down) press_target = hover;
    if (input.mouse_up) {
        if (press_target != null and hover == press_target) {
            if (teak.hitTest(prev_cmds, prev_rects, input.mouse_x, input.mouse_y)) |hit| {
                if (hit.msg) |m| App.update(&model, m);
            }
        }
        press_target = null;
    }
    if (press_target != null and hover != press_target) press_target = null;

    App.update(&model, .tick);

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

    transient_state.hover_index = hover;
    transient_state.press_index = press_target;
    transient_state.mouse_x = input.mouse_x;
    transient_state.mouse_y = input.mouse_y;
    transient_state.frame_counter +%= 1;

    _ = resources.sync(&gpu, App.resources(&model));
    teak.buildFrame(&verts, &text_draws, &image_draws, &scene_draws, alloc, cur_cmds, rects_store[cur][0..cur_cmds.len], transient_state, host.textMeasurer());
    gpu.uploadVertices(verts.items);
    gpu.uploadText(text_draws.items);
    teak.stageDraws(&gpu, &resources, image_draws.items, scene_draws.items);
    gpu.renderFrame(.{ 0.07, 0.08, 0.1, 1 });
}
