const std = @import("std");
const teak = @import("teak");
const App = teak.App;

const c = @cImport({
    @cDefine("WGPU_SHARED_LIBRARY", "1");
    @cInclude("webgpu.h");
    @cInclude("wgpu.h");
});

// ════════════════════════════════════════════════════════════════════
// Win32 Declarations
// ════════════════════════════════════════════════════════════════════

const WINAPI = std.builtin.CallingConvention.winapi;
const BOOL = c_int;
const UINT = c_uint;
const DWORD = c_ulong;
const WPARAM = usize;
const LPARAM = isize;
const LRESULT = isize;
const HANDLE = *anyopaque;
const LPCWSTR = [*:0]const u16;
const WNDPROC = *const fn (HANDLE, UINT, WPARAM, LPARAM) callconv(WINAPI) LRESULT;

const MSG = extern struct {
    hwnd: ?HANDLE,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt_x: c_long,
    pt_y: c_long,
};

const WNDCLASSEXW = extern struct {
    cbSize: UINT = @sizeOf(WNDCLASSEXW),
    style: UINT = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: c_int = 0,
    cbWndExtra: c_int = 0,
    hInstance: ?HANDLE = null,
    hIcon: ?HANDLE = null,
    hCursor: ?HANDLE = null,
    hbrBackground: ?HANDLE = null,
    lpszMenuName: ?LPCWSTR = null,
    lpszClassName: LPCWSTR,
    hIconSm: ?HANDLE = null,
};

const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
const CW_USEDEFAULT: c_int = @bitCast(@as(c_uint, 0x80000000));
const SW_SHOW: c_int = 5;
const PM_REMOVE: UINT = 0x0001;
const CS_HREDRAW: UINT = 0x0002;
const CS_VREDRAW: UINT = 0x0001;
const WM_DESTROY: UINT = 0x0002;
const WM_SIZE: UINT = 0x0005;
const WM_CHAR: UINT = 0x0102;
const WM_KEYDOWN: UINT = 0x0100;
const WM_MOUSEMOVE: UINT = 0x0200;
const WM_LBUTTONDOWN: UINT = 0x0201;
const WM_LBUTTONUP: UINT = 0x0202;
const IDC_ARROW: LPCWSTR = @ptrFromInt(32512);

const VK_BACK: WPARAM = 0x08;
const VK_LEFT: WPARAM = 0x25;
const VK_RIGHT: WPARAM = 0x27;

extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(WINAPI) u16;
extern "user32" fn CreateWindowExW(DWORD, LPCWSTR, LPCWSTR, DWORD, c_int, c_int, c_int, c_int, ?HANDLE, ?HANDLE, ?HANDLE, ?*anyopaque) callconv(WINAPI) ?HANDLE;
extern "user32" fn ShowWindow(HANDLE, c_int) callconv(WINAPI) BOOL;
extern "user32" fn PeekMessageW(*MSG, ?HANDLE, UINT, UINT, UINT) callconv(WINAPI) BOOL;
extern "user32" fn TranslateMessage(*const MSG) callconv(WINAPI) BOOL;
extern "user32" fn DispatchMessageW(*const MSG) callconv(WINAPI) LRESULT;
extern "user32" fn DefWindowProcW(HANDLE, UINT, WPARAM, LPARAM) callconv(WINAPI) LRESULT;
extern "user32" fn PostQuitMessage(c_int) callconv(WINAPI) void;
extern "user32" fn LoadCursorW(?HANDLE, LPCWSTR) callconv(WINAPI) ?HANDLE;
extern "kernel32" fn GetModuleHandleW(?LPCWSTR) callconv(WINAPI) ?HANDLE;

// ════════════════════════════════════════════════════════════════════
// Input State (written by WndProc, drained by main loop)
// ════════════════════════════════════════════════════════════════════

var g_mouse_x: f32 = 0;
var g_mouse_y: f32 = 0;
var g_running: bool = true;
var g_width: u32 = 800;
var g_height: u32 = 600;
var g_resized: bool = true;

// Edge events — set by wndProc, drained by main loop.
var g_mouse_down_pending: bool = false;
var g_mouse_up_pending: bool = false;

var g_chars: [64]u8 = undefined;
var g_chars_count: usize = 0;

var g_keys: [32]App.SpecialKey = undefined;
var g_keys_count: usize = 0;

fn loword(lp: LPARAM) u16 {
    return @truncate(@as(usize, @bitCast(lp)));
}
fn hiword(lp: LPARAM) u16 {
    return @truncate(@as(usize, @bitCast(lp)) >> 16);
}
fn lowordSigned(lp: LPARAM) i16 {
    return @bitCast(loword(lp));
}
fn hiwordSigned(lp: LPARAM) i16 {
    return @bitCast(hiword(lp));
}

fn pushChar(ch: u8) void {
    if (g_chars_count < g_chars.len) {
        g_chars[g_chars_count] = ch;
        g_chars_count += 1;
    }
}

fn pushKey(k: App.SpecialKey) void {
    if (g_keys_count < g_keys.len) {
        g_keys[g_keys_count] = k;
        g_keys_count += 1;
    }
}

fn wndProc(hwnd: HANDLE, msg: UINT, wp: WPARAM, lp: LPARAM) callconv(WINAPI) LRESULT {
    switch (msg) {
        WM_DESTROY => {
            g_running = false;
            PostQuitMessage(0);
            return 0;
        },
        WM_SIZE => {
            const w: u32 = loword(lp);
            const h: u32 = hiword(lp);
            if (w > 0 and h > 0) {
                g_width = w;
                g_height = h;
                g_resized = true;
            }
            return 0;
        },
        WM_MOUSEMOVE => {
            g_mouse_x = @floatFromInt(lowordSigned(lp));
            g_mouse_y = @floatFromInt(hiwordSigned(lp));
            return 0;
        },
        WM_LBUTTONDOWN => {
            g_mouse_x = @floatFromInt(lowordSigned(lp));
            g_mouse_y = @floatFromInt(hiwordSigned(lp));
            g_mouse_down_pending = true;
            return 0;
        },
        WM_LBUTTONUP => {
            g_mouse_x = @floatFromInt(lowordSigned(lp));
            g_mouse_y = @floatFromInt(hiwordSigned(lp));
            g_mouse_up_pending = true;
            return 0;
        },
        WM_CHAR => {
            // WM_CHAR delivers a translated character. 0x08 is backspace —
            // handle special keys via WM_KEYDOWN and ignore the control
            // range from WM_CHAR to avoid dispatching \b as text.
            if (wp >= 0x20 and wp < 0x7F) {
                pushChar(@intCast(wp));
            }
            return 0;
        },
        WM_KEYDOWN => {
            switch (wp) {
                VK_BACK => pushKey(.backspace),
                VK_LEFT => pushKey(.left),
                VK_RIGHT => pushKey(.right),
                else => {},
            }
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wp, lp),
    }
}

// ════════════════════════════════════════════════════════════════════
// Frame Diff
// ════════════════════════════════════════════════════════════════════

fn cmdsEqual(a: []const teak.Cmd(App.Msg), b: []const teak.Cmd(App.Msg)) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.meta.activeTag(ca) != std.meta.activeTag(cb)) return false;
        switch (ca) {
            .push_group => |ga| {
                const gb = cb.push_group;
                if (ga.direction != gb.direction or ga.padding != gb.padding or
                    ga.gap != gb.gap or ga.flex != gb.flex) return false;
            },
            .pop_group => {},
            .text => |ta| if (!std.mem.eql(u8, ta.content, cb.text.content)) return false,
            .button => |ba| if (!std.mem.eql(u8, ba.label, cb.button.label)) return false,
            .text_input => |tia| {
                const tib = cb.text_input;
                if (tia.cursor != tib.cursor) return false;
                if (!std.mem.eql(u8, tia.content, tib.content)) return false;
            },
        }
    }
    return true;
}

fn rectsEqual(a: []const teak.Rect, b: []const teak.Rect) bool {
    if (a.len != b.len) return false;
    for (a, b) |ra, rb| {
        if (ra.x != rb.x or ra.y != rb.y or ra.w != rb.w or ra.h != rb.h) return false;
    }
    return true;
}

fn transientEqual(a: teak.TransientState, b: teak.TransientState) bool {
    return a.hover_index == b.hover_index and
        a.press_index == b.press_index and
        a.focus_index == b.focus_index;
}

// ════════════════════════════════════════════════════════════════════
// wgpu Helpers
// ════════════════════════════════════════════════════════════════════

fn wgpuStr(s: []const u8) c.WGPUStringView {
    return .{ .data = s.ptr, .length = s.len };
}

// ════════════════════════════════════════════════════════════════════
// Main
// ════════════════════════════════════════════════════════════════════

pub fn main() !void {
    var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    // ── Win32 Window ───────────────────────────────────────────────

    const hinstance = GetModuleHandleW(null) orelse @panic("GetModuleHandle failed");

    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("TeakWindow");
    const wc = WNDCLASSEXW{
        .style = CS_HREDRAW | CS_VREDRAW,
        .lpfnWndProc = &wndProc,
        .hInstance = hinstance,
        .hCursor = LoadCursorW(null, IDC_ARROW),
        .lpszClassName = class_name,
    };
    if (RegisterClassExW(&wc) == 0) @panic("RegisterClassExW failed");

    const window_name = std.unicode.utf8ToUtf16LeStringLiteral("Teak — Counter + Greeter");
    const hwnd = CreateWindowExW(
        0,
        class_name,
        window_name,
        WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT,
        CW_USEDEFAULT,
        900,
        500,
        null,
        null,
        hinstance,
        null,
    ) orelse @panic("CreateWindowExW failed");
    _ = ShowWindow(hwnd, SW_SHOW);

    // ── wgpu Instance ──────────────────────────────────────────────

    var instance_desc = std.mem.zeroes(c.WGPUInstanceDescriptor);
    const instance = c.wgpuCreateInstance(&instance_desc) orelse @panic("wgpuCreateInstance failed");

    // ── Surface ────────────────────────────────────────────────────

    var hwnd_source = std.mem.zeroes(c.WGPUSurfaceSourceWindowsHWND);
    hwnd_source.chain.sType = c.WGPUSType_SurfaceSourceWindowsHWND;
    hwnd_source.hinstance = @ptrCast(hinstance);
    hwnd_source.hwnd = @ptrCast(hwnd);

    var surface_desc = std.mem.zeroes(c.WGPUSurfaceDescriptor);
    surface_desc.nextInChain = @ptrCast(&hwnd_source.chain);
    surface_desc.label = wgpuStr("teak-surface");
    const surface = c.wgpuInstanceCreateSurface(instance, &surface_desc) orelse @panic("wgpuInstanceCreateSurface failed");

    // ── Adapter ────────────────────────────────────────────────────

    var adapter: c.WGPUAdapter = null;

    var adapter_opts = std.mem.zeroes(c.WGPURequestAdapterOptions);
    adapter_opts.compatibleSurface = surface;
    adapter_opts.powerPreference = c.WGPUPowerPreference_HighPerformance;
    adapter_opts.featureLevel = c.WGPUFeatureLevel_Core;

    var adapter_cb_info = std.mem.zeroes(c.WGPURequestAdapterCallbackInfo);
    adapter_cb_info.mode = c.WGPUCallbackMode_AllowSpontaneous;
    adapter_cb_info.callback = &adapterCallback;
    adapter_cb_info.userdata1 = @ptrCast(&adapter);

    _ = c.wgpuInstanceRequestAdapter(instance, &adapter_opts, adapter_cb_info);
    while (adapter == null) c.wgpuInstanceProcessEvents(instance);
    std.debug.print("Adapter acquired.\n", .{});

    // ── Device ─────────────────────────────────────────────────────

    var device: c.WGPUDevice = null;

    var device_desc = std.mem.zeroes(c.WGPUDeviceDescriptor);
    device_desc.label = wgpuStr("teak-device");
    device_desc.defaultQueue.label = wgpuStr("teak-queue");
    device_desc.deviceLostCallbackInfo.callback = &deviceLostCallback;

    var device_cb_info = std.mem.zeroes(c.WGPURequestDeviceCallbackInfo);
    device_cb_info.mode = c.WGPUCallbackMode_AllowSpontaneous;
    device_cb_info.callback = &deviceCallback;
    device_cb_info.userdata1 = @ptrCast(&device);

    _ = c.wgpuAdapterRequestDevice(adapter, &device_desc, device_cb_info);
    while (device == null) c.wgpuInstanceProcessEvents(instance);
    std.debug.print("Device acquired.\n", .{});

    const queue = c.wgpuDeviceGetQueue(device);

    // ── Shader Module ──────────────────────────────────────────────

    const shader_code =
        \\struct VertexOutput {
        \\    @builtin(position) pos: vec4f,
        \\    @location(0) color: vec4f,
        \\    @location(1) uv: vec2f,
        \\};
        \\
        \\struct Uniforms {
        \\    screen_size: vec2f,
        \\};
        \\
        \\@group(0) @binding(0) var<uniform> uniforms: Uniforms;
        \\
        \\@vertex
        \\fn vs_main(
        \\    @location(0) pos: vec2f,
        \\    @location(1) color: vec4f,
        \\    @location(2) uv: vec2f,
        \\) -> VertexOutput {
        \\    let clip = vec2f(
        \\        (pos.x / uniforms.screen_size.x) * 2.0 - 1.0,
        \\        1.0 - (pos.y / uniforms.screen_size.y) * 2.0,
        \\    );
        \\    return VertexOutput(vec4f(clip, 0.0, 1.0), color, uv);
        \\}
        \\
        \\@fragment
        \\fn fs_main(in: VertexOutput) -> @location(0) vec4f {
        \\    return in.color;
        \\}
    ;

    var wgsl_desc = std.mem.zeroes(c.WGPUShaderSourceWGSL);
    wgsl_desc.chain.sType = c.WGPUSType_ShaderSourceWGSL;
    wgsl_desc.code = wgpuStr(shader_code);

    var shader_desc = std.mem.zeroes(c.WGPUShaderModuleDescriptor);
    shader_desc.nextInChain = @ptrCast(&wgsl_desc.chain);
    shader_desc.label = wgpuStr("quad-shader");
    const shader = c.wgpuDeviceCreateShaderModule(device, &shader_desc) orelse @panic("Shader creation failed");

    // ── Bind Group Layout ──────────────────────────────────────────

    var bgl_entry = std.mem.zeroes(c.WGPUBindGroupLayoutEntry);
    bgl_entry.binding = 0;
    bgl_entry.visibility = c.WGPUShaderStage_Vertex;
    bgl_entry.buffer.type = c.WGPUBufferBindingType_Uniform;
    bgl_entry.buffer.minBindingSize = 8;

    var bgl_desc = std.mem.zeroes(c.WGPUBindGroupLayoutDescriptor);
    bgl_desc.label = wgpuStr("uniform-bgl");
    bgl_desc.entryCount = 1;
    bgl_desc.entries = &bgl_entry;
    const bind_group_layout = c.wgpuDeviceCreateBindGroupLayout(device, &bgl_desc) orelse @panic("BGL creation failed");

    // ── Pipeline Layout ────────────────────────────────────────────

    var pl_desc = std.mem.zeroes(c.WGPUPipelineLayoutDescriptor);
    pl_desc.label = wgpuStr("pipeline-layout");
    pl_desc.bindGroupLayoutCount = 1;
    pl_desc.bindGroupLayouts = &bind_group_layout;
    const pipeline_layout = c.wgpuDeviceCreatePipelineLayout(device, &pl_desc) orelse @panic("Pipeline layout failed");

    // ── Render Pipeline ────────────────────────────────────────────

    const surf_format = c.WGPUTextureFormat_BGRA8Unorm;

    const vert_attrs = [_]c.WGPUVertexAttribute{
        .{ .format = c.WGPUVertexFormat_Float32x2, .offset = 0, .shaderLocation = 0 },
        .{ .format = c.WGPUVertexFormat_Float32x4, .offset = 8, .shaderLocation = 1 },
        .{ .format = c.WGPUVertexFormat_Float32x2, .offset = 24, .shaderLocation = 2 },
    };

    const vert_buf_layout = c.WGPUVertexBufferLayout{
        .arrayStride = @sizeOf(teak.Vertex),
        .stepMode = c.WGPUVertexStepMode_Vertex,
        .attributeCount = vert_attrs.len,
        .attributes = &vert_attrs,
    };

    const blend_state = c.WGPUBlendState{
        .color = .{
            .operation = c.WGPUBlendOperation_Add,
            .srcFactor = c.WGPUBlendFactor_SrcAlpha,
            .dstFactor = c.WGPUBlendFactor_OneMinusSrcAlpha,
        },
        .alpha = .{
            .operation = c.WGPUBlendOperation_Add,
            .srcFactor = c.WGPUBlendFactor_One,
            .dstFactor = c.WGPUBlendFactor_OneMinusSrcAlpha,
        },
    };

    var color_target = std.mem.zeroes(c.WGPUColorTargetState);
    color_target.format = surf_format;
    color_target.blend = &blend_state;
    color_target.writeMask = c.WGPUColorWriteMask_All;

    var frag_state = std.mem.zeroes(c.WGPUFragmentState);
    frag_state.module = shader;
    frag_state.entryPoint = wgpuStr("fs_main");
    frag_state.targetCount = 1;
    frag_state.targets = &color_target;

    var pipeline_desc = std.mem.zeroes(c.WGPURenderPipelineDescriptor);
    pipeline_desc.label = wgpuStr("quad-pipeline");
    pipeline_desc.layout = pipeline_layout;
    pipeline_desc.vertex.module = shader;
    pipeline_desc.vertex.entryPoint = wgpuStr("vs_main");
    pipeline_desc.vertex.bufferCount = 1;
    pipeline_desc.vertex.buffers = &vert_buf_layout;
    pipeline_desc.primitive.topology = c.WGPUPrimitiveTopology_TriangleList;
    pipeline_desc.primitive.frontFace = c.WGPUFrontFace_CCW;
    pipeline_desc.primitive.cullMode = c.WGPUCullMode_None;
    pipeline_desc.multisample.count = 1;
    pipeline_desc.multisample.mask = 0xFFFFFFFF;
    pipeline_desc.fragment = &frag_state;
    const pipeline = c.wgpuDeviceCreateRenderPipeline(device, &pipeline_desc) orelse @panic("Pipeline creation failed");

    // ── Uniform Buffer ─────────────────────────────────────────────

    var ub_desc = std.mem.zeroes(c.WGPUBufferDescriptor);
    ub_desc.label = wgpuStr("uniform-buf");
    ub_desc.usage = c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst;
    ub_desc.size = 8;
    const uniform_buf = c.wgpuDeviceCreateBuffer(device, &ub_desc) orelse @panic("Uniform buffer failed");

    // ── Bind Group ─────────────────────────────────────────────────

    var bg_entry = std.mem.zeroes(c.WGPUBindGroupEntry);
    bg_entry.binding = 0;
    bg_entry.buffer = uniform_buf;
    bg_entry.offset = 0;
    bg_entry.size = 8;

    var bg_desc = std.mem.zeroes(c.WGPUBindGroupDescriptor);
    bg_desc.label = wgpuStr("bind-group");
    bg_desc.layout = bind_group_layout;
    bg_desc.entryCount = 1;
    bg_desc.entries = &bg_entry;
    const bind_group = c.wgpuDeviceCreateBindGroup(device, &bg_desc) orelse @panic("Bind group failed");

    // ════════════════════════════════════════════════════════════════
    // Application State — Double-buffered CmdBuffer + rects
    // ════════════════════════════════════════════════════════════════

    const MAX_RECTS: usize = 256;
    const CmdBufT = teak.CmdBuffer(App.Msg);

    var model: App.Model = .{};

    var bufs: [2]CmdBufT = .{ CmdBufT.init(gpa), CmdBufT.init(gpa) };
    defer for (&bufs) |*b| b.deinit();

    var rects_store: [2][MAX_RECTS]teak.Rect = undefined;
    var rects_len: [2]usize = .{ 0, 0 };
    var current: u1 = 0;

    var verts: std.ArrayList(teak.Vertex) = .empty;
    defer verts.deinit(gpa);

    var transient_state: teak.TransientState = .{};
    var prev_transient: teak.TransientState = .{};

    // Mouse press tracking (proto: press_index is set on mousedown over a
    // widget; mouseup fires the click Msg only if still over the same index;
    // drag-off cancels the press without emitting a Msg).
    var press_target: ?usize = null;

    var gpu_vert_buf: c.WGPUBuffer = null;
    var gpu_vert_buf_size: u64 = 0;

    var skip_count: u64 = 0;

    // ════════════════════════════════════════════════════════════════
    // Main Loop
    // ════════════════════════════════════════════════════════════════

    std.debug.print("Teak UI running.\n", .{});

    while (g_running) {
        // 1. Drain Win32 messages (fills g_chars/g_keys/mouse edge flags).
        var msg: MSG = undefined;
        while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE) != 0) {
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }
        if (!g_running) break;

        // 2. Handle resize (reconfigure surface + update uniform).
        if (g_resized) {
            g_resized = false;
            var surf_config = std.mem.zeroes(c.WGPUSurfaceConfiguration);
            surf_config.device = device;
            surf_config.format = surf_format;
            surf_config.usage = c.WGPUTextureUsage_RenderAttachment;
            surf_config.width = g_width;
            surf_config.height = g_height;
            surf_config.presentMode = c.WGPUPresentMode_Fifo;
            surf_config.alphaMode = c.WGPUCompositeAlphaMode_Auto;
            c.wgpuSurfaceConfigure(surface, &surf_config);

            const screen_size = [2]f32{ @floatFromInt(g_width), @floatFromInt(g_height) };
            c.wgpuQueueWriteBuffer(queue, uniform_buf, 0, &screen_size, @sizeOf([2]f32));
        }

        // 3. Process input against the *previous* frame's layout.
        const prev = current ^ 1;
        const prev_cmds = bufs[prev].cmds.items;
        const prev_rects = rects_store[prev][0..rects_len[prev]];

        // 3a. Mouse-down → arm press_target.
        if (g_mouse_down_pending) {
            g_mouse_down_pending = false;
            if (prev_cmds.len > 0) {
                press_target = teak.hoverTest(prev_cmds, prev_rects, g_mouse_x, g_mouse_y);
            }
        }

        // 3b. Mouse-up → fire click Msg if still over press_target.
        if (g_mouse_up_pending) {
            g_mouse_up_pending = false;
            if (press_target) |pt| {
                const cur_hit = if (prev_cmds.len > 0)
                    teak.hoverTest(prev_cmds, prev_rects, g_mouse_x, g_mouse_y)
                else
                    null;
                if (cur_hit != null and cur_hit.? == pt) {
                    if (teak.hitTest(prev_cmds, prev_rects, g_mouse_x, g_mouse_y)) |hit| {
                        App.update(&model, hit.msg);
                        std.debug.print("click -> {s}\n", .{@tagName(hit.msg)});
                    }
                }
            }
            press_target = null;
        }

        // 3c. Drag-off cancels press.
        if (press_target) |pt| {
            const cur_hit = if (prev_cmds.len > 0)
                teak.hoverTest(prev_cmds, prev_rects, g_mouse_x, g_mouse_y)
            else
                null;
            if (cur_hit == null or cur_hit.? != pt) press_target = null;
        }

        // 3d. Drain keyboard queue, route via Model.focused.
        for (g_chars[0..g_chars_count]) |ch| {
            if (App.keyCharMsg(&model, ch)) |m| App.update(&model, m);
        }
        g_chars_count = 0;

        for (g_keys[0..g_keys_count]) |k| {
            if (App.keySpecialMsg(&model, k)) |m| App.update(&model, m);
        }
        g_keys_count = 0;

        // 4. Build this frame into the other buffer.
        current ^= 1;
        const cur = current;
        bufs[cur].reset();
        App.view(&model, &bufs[cur]);

        const cur_cmds = bufs[cur].cmds.items;
        if (cur_cmds.len > MAX_RECTS) @panic("Too many commands for MAX_RECTS");

        teak.LayoutEngine.doLayout(
            rects_store[cur][0..cur_cmds.len],
            cur_cmds,
            @floatFromInt(g_width),
            @floatFromInt(g_height),
        );
        rects_len[cur] = cur_cmds.len;

        // 5. Update transient state (hover/press/focus) against THIS frame's layout.
        transient_state.hover_index = teak.hoverTest(cur_cmds, rects_store[cur][0..cur_cmds.len], g_mouse_x, g_mouse_y);
        transient_state.press_index = press_target;
        transient_state.focus_index = focusIndex(cur_cmds, model.focused);
        transient_state.mouse_x = g_mouse_x;
        transient_state.mouse_y = g_mouse_y;
        transient_state.frame_counter +%= 1;

        // 6. Diff against previous frame to decide whether to rebuild vertices.
        const prev_cur = current ^ 1;
        const prev_cmds2 = bufs[prev_cur].cmds.items;
        const prev_rects2 = rects_store[prev_cur][0..rects_len[prev_cur]];
        const cmds_same = cmdsEqual(cur_cmds, prev_cmds2);
        const rects_same = rectsEqual(rects_store[cur][0..cur_cmds.len], prev_rects2);
        const transient_same = transientEqual(transient_state, prev_transient);

        // Force rebuild every 30 frames while a text input is focused to
        // drive the cursor blink. A real impl would notice blink phase
        // explicitly; all-or-nothing is fine for the proto.
        const blink_tick = transient_state.focus_index != null and
            (transient_state.frame_counter % 30 == 0);

        const need_rebuild = !cmds_same or !rects_same or !transient_same or blink_tick;

        if (need_rebuild) {
            teak.buildVertices(&verts, gpa, cur_cmds, rects_store[cur][0..cur_cmds.len], transient_state);
            const vert_data_size: u64 = @intCast(verts.items.len * @sizeOf(teak.Vertex));
            if (vert_data_size > 0) {
                if (gpu_vert_buf == null or vert_data_size > gpu_vert_buf_size) {
                    if (gpu_vert_buf) |buf| c.wgpuBufferRelease(buf);
                    gpu_vert_buf_size = @max(vert_data_size, 4096);
                    var vb_desc = std.mem.zeroes(c.WGPUBufferDescriptor);
                    vb_desc.label = wgpuStr("vertex-buf");
                    vb_desc.usage = c.WGPUBufferUsage_Vertex | c.WGPUBufferUsage_CopyDst;
                    vb_desc.size = gpu_vert_buf_size;
                    gpu_vert_buf = c.wgpuDeviceCreateBuffer(device, &vb_desc);
                }
                c.wgpuQueueWriteBuffer(queue, gpu_vert_buf, 0, verts.items.ptr, vert_data_size);
            }
        } else {
            skip_count += 1;
            if (skip_count % 120 == 0) std.debug.print("diff: skipped vertex rebuild (total skipped = {d})\n", .{skip_count});
        }

        prev_transient = transient_state;

        // 7. Acquire surface texture.
        var surface_texture: c.WGPUSurfaceTexture = undefined;
        c.wgpuSurfaceGetCurrentTexture(surface, &surface_texture);
        if (surface_texture.status != c.WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal and
            surface_texture.status != c.WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal)
        {
            continue;
        }

        const texture_view = c.wgpuTextureCreateView(surface_texture.texture, null);

        // 8. Encode render pass.
        var enc_desc = std.mem.zeroes(c.WGPUCommandEncoderDescriptor);
        enc_desc.label = wgpuStr("frame-encoder");
        const encoder = c.wgpuDeviceCreateCommandEncoder(device, &enc_desc);

        var color_attachment = std.mem.zeroes(c.WGPURenderPassColorAttachment);
        color_attachment.view = texture_view;
        color_attachment.loadOp = c.WGPULoadOp_Clear;
        color_attachment.storeOp = c.WGPUStoreOp_Store;
        color_attachment.clearValue = .{ .r = 0.08, .g = 0.08, .b = 0.1, .a = 1.0 };
        color_attachment.depthSlice = 0xFFFFFFFF;

        var rp_desc = std.mem.zeroes(c.WGPURenderPassDescriptor);
        rp_desc.label = wgpuStr("render-pass");
        rp_desc.colorAttachmentCount = 1;
        rp_desc.colorAttachments = &color_attachment;

        const pass = c.wgpuCommandEncoderBeginRenderPass(encoder, &rp_desc);

        if (verts.items.len > 0 and gpu_vert_buf != null) {
            const draw_byte_size: u64 = @intCast(verts.items.len * @sizeOf(teak.Vertex));
            c.wgpuRenderPassEncoderSetPipeline(pass, pipeline);
            c.wgpuRenderPassEncoderSetBindGroup(pass, 0, bind_group, 0, null);
            c.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, gpu_vert_buf, 0, draw_byte_size);
            c.wgpuRenderPassEncoderDraw(pass, @intCast(verts.items.len), 1, 0, 0);
        }

        c.wgpuRenderPassEncoderEnd(pass);
        c.wgpuRenderPassEncoderRelease(pass);

        // 9. Submit + present.
        var cmd_buf_desc = std.mem.zeroes(c.WGPUCommandBufferDescriptor);
        cmd_buf_desc.label = wgpuStr("frame-cmds");
        const command_buffer = c.wgpuCommandEncoderFinish(encoder, &cmd_buf_desc);
        c.wgpuCommandEncoderRelease(encoder);

        c.wgpuQueueSubmit(queue, 1, &command_buffer);
        c.wgpuCommandBufferRelease(command_buffer);

        _ = c.wgpuSurfacePresent(surface);
        c.wgpuTextureViewRelease(texture_view);
    }

    std.debug.print("Teak UI exiting. (skipped {d} vertex rebuilds)\n", .{skip_count});
}

/// Map model.focused → cmd index of the corresponding text_input in the
/// current frame. For proto 2 there is a single text_input, so a linear
/// scan is fine.
fn focusIndex(cmds: []const teak.Cmd(App.Msg), focused: ?App.FocusField) ?usize {
    const f = focused orelse return null;
    switch (f) {
        .greeter => {
            for (cmds, 0..) |cc, i| {
                if (cc == .text_input) return i;
            }
            return null;
        },
    }
}

// ════════════════════════════════════════════════════════════════════
// wgpu Callbacks
// ════════════════════════════════════════════════════════════════════

fn adapterCallback(
    status: c.WGPURequestAdapterStatus,
    adapter: c.WGPUAdapter,
    message: c.WGPUStringView,
    userdata1: ?*anyopaque,
    _: ?*anyopaque,
) callconv(.c) void {
    if (status != c.WGPURequestAdapterStatus_Success) {
        if (message.data) |data| {
            std.debug.print("Adapter request failed: {s}\n", .{data[0..message.length]});
        }
        return;
    }
    const ptr: *c.WGPUAdapter = @ptrCast(@alignCast(userdata1));
    ptr.* = adapter;
}

fn deviceCallback(
    status: c.WGPURequestDeviceStatus,
    dev: c.WGPUDevice,
    message: c.WGPUStringView,
    userdata1: ?*anyopaque,
    _: ?*anyopaque,
) callconv(.c) void {
    if (status != c.WGPURequestDeviceStatus_Success) {
        if (message.data) |data| {
            std.debug.print("Device request failed: {s}\n", .{data[0..message.length]});
        }
        return;
    }
    const ptr: *c.WGPUDevice = @ptrCast(@alignCast(userdata1));
    ptr.* = dev;
}

fn deviceLostCallback(
    _: [*c]const c.WGPUDevice,
    reason: c.WGPUDeviceLostReason,
    message: c.WGPUStringView,
    _: ?*anyopaque,
    _: ?*anyopaque,
) callconv(.c) void {
    if (message.data) |data| {
        std.debug.print("Device lost (reason {d}): {s}\n", .{ reason, data[0..message.length] });
    }
}
