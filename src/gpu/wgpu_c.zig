//! The single translate-c import (`wgpu-c`, see `src/gpu/vendor/wgpu_c.h`) of the wgpu-native headers plus the small,
//! backend-neutral helpers every native GPU file shares (device bring-up,
//! shader / buffer / pipeline creation). Surface providers re-import `c`
//! through `wgpu_core.zig`, so `WGPUSurface` and friends have one type
//! identity across the whole native backend.

const std = @import("std");

pub const c = @import("wgpu-c");

pub fn wgpuStr(s: []const u8) c.WGPUStringView {
    return .{ .data = s.ptr, .length = s.len };
}

// ── Device bring-up ────────────────────────────────────────────────
//
// wgpu-native completes these requests inside `wgpuInstanceProcessEvents`,
// so a spin loop is enough on native; each callback only stores the result
// through `userdata1` (or logs why there is none).

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
    const out: *c.WGPUAdapter = @ptrCast(@alignCast(userdata1));
    out.* = adapter;
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
    const out: *c.WGPUDevice = @ptrCast(@alignCast(userdata1));
    out.* = dev;
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

/// Validation / OOM / internal errors that no error scope captured. Loud on
/// purpose: a silently invalid draw is far harder to debug than a log line.
fn uncapturedErrorCallback(
    _: [*c]const c.WGPUDevice,
    kind: c.WGPUErrorType,
    message: c.WGPUStringView,
    _: ?*anyopaque,
    _: ?*anyopaque,
) callconv(.c) void {
    const text: []const u8 = if (message.data) |data| data[0..message.length] else "(no message)";
    std.debug.print("wgpu uncaptured error (type {d}): {s}\n", .{ kind, text });
}

/// An instance restricted to `backends` (e.g. `WGPUInstanceBackend_Vulkan`).
/// Headless tests use this to avoid wgpu falling back to a GL software
/// adapter on machines whose only real GPU path is a software Vulkan ICD.
pub fn createInstance(backends: c.WGPUInstanceBackend) ?c.WGPUInstance {
    var extras = std.mem.zeroes(c.WGPUInstanceExtras);
    extras.chain.sType = c.WGPUSType_InstanceExtras;
    extras.backends = backends;
    var desc = std.mem.zeroes(c.WGPUInstanceDescriptor);
    desc.nextInChain = &extras.chain;
    return c.wgpuCreateInstance(&desc);
}

pub const DeviceContext = struct {
    adapter: c.WGPUAdapter,
    device: c.WGPUDevice,
    queue: c.WGPUQueue,

    pub fn release(self: DeviceContext) void {
        c.wgpuQueueRelease(self.queue);
        c.wgpuDeviceRelease(self.device);
        c.wgpuAdapterRelease(self.adapter);
    }
};

/// Pick an adapter (compatible with `surface` when given; headless
/// otherwise) and open a device + queue on it.
pub fn requestDevice(instance: c.WGPUInstance, surface: ?c.WGPUSurface) error{ AdapterFailed, DeviceFailed }!DeviceContext {
    var adapter: c.WGPUAdapter = null;
    var adapter_opts = std.mem.zeroes(c.WGPURequestAdapterOptions);
    adapter_opts.compatibleSurface = surface orelse null;
    adapter_opts.powerPreference = c.WGPUPowerPreference_HighPerformance;
    adapter_opts.featureLevel = c.WGPUFeatureLevel_Core;
    // `TEAK_GPU_FALLBACK=1` asks for a software adapter (DX12 WARP, lavapipe,
    // SwiftShader): CI runners and containers without a GPU.
    if (std.c.getenv("TEAK_GPU_FALLBACK")) |v| {
        if (std.mem.span(v).len > 0 and v[0] != '0') adapter_opts.forceFallbackAdapter = 1;
    }

    var adapter_cb = std.mem.zeroes(c.WGPURequestAdapterCallbackInfo);
    adapter_cb.mode = c.WGPUCallbackMode_AllowSpontaneous;
    adapter_cb.callback = &adapterCallback;
    adapter_cb.userdata1 = @ptrCast(&adapter);
    _ = c.wgpuInstanceRequestAdapter(instance, &adapter_opts, adapter_cb);
    var spins: u32 = 0;
    while (adapter == null) : (spins += 1) {
        if (spins > 100_000) return error.AdapterFailed;
        c.wgpuInstanceProcessEvents(instance);
    }

    // Ask for what the adapter can do rather than wgpu's defaults, which
    // software adapters (SwiftShader) cannot all satisfy.
    var limits = std.mem.zeroes(c.WGPULimits);
    _ = c.wgpuAdapterGetLimits(adapter, &limits);
    var device: c.WGPUDevice = null;
    var device_desc = std.mem.zeroes(c.WGPUDeviceDescriptor);
    device_desc.label = wgpuStr("teak-device");
    device_desc.defaultQueue.label = wgpuStr("teak-queue");
    device_desc.requiredLimits = &limits;
    device_desc.deviceLostCallbackInfo.mode = c.WGPUCallbackMode_AllowSpontaneous;
    device_desc.deviceLostCallbackInfo.callback = &deviceLostCallback;
    device_desc.uncapturedErrorCallbackInfo.callback = &uncapturedErrorCallback;

    var device_cb = std.mem.zeroes(c.WGPURequestDeviceCallbackInfo);
    device_cb.mode = c.WGPUCallbackMode_AllowSpontaneous;
    device_cb.callback = &deviceCallback;
    device_cb.userdata1 = @ptrCast(&device);
    _ = c.wgpuAdapterRequestDevice(adapter, &device_desc, device_cb);
    spins = 0;
    while (device == null) : (spins += 1) {
        if (spins > 100_000) return error.DeviceFailed;
        c.wgpuInstanceProcessEvents(instance);
    }

    return .{ .adapter = adapter, .device = device, .queue = c.wgpuDeviceGetQueue(device) };
}

// ── Resource helpers ───────────────────────────────────────────────

pub fn createShader(device: c.WGPUDevice, label: []const u8, wgsl: []const u8) error{ShaderCreateFailed}!c.WGPUShaderModule {
    var src = std.mem.zeroes(c.WGPUShaderSourceWGSL);
    src.chain.sType = c.WGPUSType_ShaderSourceWGSL;
    src.code = wgpuStr(wgsl);
    var desc = std.mem.zeroes(c.WGPUShaderModuleDescriptor);
    desc.nextInChain = @ptrCast(&src.chain);
    desc.label = wgpuStr(label);
    return c.wgpuDeviceCreateShaderModule(device, &desc) orelse error.ShaderCreateFailed;
}

pub fn createBuffer(device: c.WGPUDevice, label: []const u8, usage: c.WGPUBufferUsage, size: u64) c.WGPUBuffer {
    var desc = std.mem.zeroes(c.WGPUBufferDescriptor);
    desc.label = wgpuStr(label);
    desc.usage = usage;
    desc.size = size;
    return c.wgpuDeviceCreateBuffer(device, &desc);
}

/// `buf` grown (recreated) to hold at least `needed` bytes; contents are
/// not preserved. `size` is updated to the new capacity (min 4 KiB).
pub fn ensureBuffer(
    device: c.WGPUDevice,
    label: []const u8,
    usage: c.WGPUBufferUsage,
    buf: *c.WGPUBuffer,
    size: *u64,
    needed: u64,
) void {
    if (buf.* != null and needed <= size.*) return;
    if (buf.*) |old| c.wgpuBufferRelease(old);
    size.* = @max(needed, 4096);
    buf.* = createBuffer(device, label, usage, size.*);
}

pub const TextureOptions = struct {
    width: u32,
    height: u32,
    format: c.WGPUTextureFormat,
    usage: c.WGPUTextureUsage,
    samples: u32 = 1,
};

pub fn createTexture2D(device: c.WGPUDevice, label: []const u8, o: TextureOptions) c.WGPUTexture {
    var desc = std.mem.zeroes(c.WGPUTextureDescriptor);
    desc.label = wgpuStr(label);
    desc.usage = o.usage;
    desc.dimension = c.WGPUTextureDimension_2D;
    desc.size = .{ .width = o.width, .height = o.height, .depthOrArrayLayers = 1 };
    desc.format = o.format;
    desc.mipLevelCount = 1;
    desc.sampleCount = o.samples;
    return c.wgpuDeviceCreateTexture(device, &desc);
}

pub fn createView2D(texture: c.WGPUTexture, label: []const u8, format: c.WGPUTextureFormat) c.WGPUTextureView {
    var desc = std.mem.zeroes(c.WGPUTextureViewDescriptor);
    desc.label = wgpuStr(label);
    desc.format = format;
    desc.dimension = c.WGPUTextureViewDimension_2D;
    desc.mipLevelCount = 1;
    desc.arrayLayerCount = 1;
    desc.aspect = c.WGPUTextureAspect_All;
    return c.wgpuTextureCreateView(texture, &desc);
}

pub const alpha_blend = c.WGPUBlendState{
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

pub const PipelineOptions = struct {
    label: []const u8,
    layout: c.WGPUPipelineLayout,
    module: c.WGPUShaderModule,
    vs_entry: []const u8 = "vs_main",
    fs_entry: []const u8 = "fs_main",
    vertex_buffers: []const c.WGPUVertexBufferLayout,
    format: c.WGPUTextureFormat,
    /// null = write the shader output unblended.
    blend: ?*const c.WGPUBlendState = &alpha_blend,
    cull_mode: c.WGPUCullMode = c.WGPUCullMode_None,
    /// Colour channels written; `WGPUColorWriteMask_None` for stencil-only passes.
    write_mask: c.WGPUColorWriteMask = c.WGPUColorWriteMask_All,
    /// null = no depth attachment in the pass.
    depth: ?c.WGPUDepthStencilState = null,
    samples: u32 = 1,
};

/// Triangle-list render pipeline with one colour target.
pub fn createPipeline(device: c.WGPUDevice, o: PipelineOptions) c.WGPURenderPipeline {
    var color_target = std.mem.zeroes(c.WGPUColorTargetState);
    color_target.format = o.format;
    color_target.blend = if (o.blend) |b| b else null;
    color_target.writeMask = o.write_mask;

    var frag = std.mem.zeroes(c.WGPUFragmentState);
    frag.module = o.module;
    frag.entryPoint = wgpuStr(o.fs_entry);
    frag.targetCount = 1;
    frag.targets = &color_target;

    var depth = o.depth;

    var desc = std.mem.zeroes(c.WGPURenderPipelineDescriptor);
    desc.label = wgpuStr(o.label);
    desc.layout = o.layout;
    desc.vertex.module = o.module;
    desc.vertex.entryPoint = wgpuStr(o.vs_entry);
    desc.vertex.bufferCount = o.vertex_buffers.len;
    desc.vertex.buffers = o.vertex_buffers.ptr;
    desc.primitive.topology = c.WGPUPrimitiveTopology_TriangleList;
    desc.primitive.frontFace = c.WGPUFrontFace_CCW;
    desc.primitive.cullMode = o.cull_mode;
    desc.depthStencil = if (depth != null) &depth.? else null;
    desc.multisample.count = o.samples;
    desc.multisample.mask = 0xFFFFFFFF;
    desc.fragment = &frag;
    return c.wgpuDeviceCreateRenderPipeline(device, &desc);
}

pub fn depthState(format: c.WGPUTextureFormat, write: bool, compare: c.WGPUCompareFunction) c.WGPUDepthStencilState {
    var d = std.mem.zeroes(c.WGPUDepthStencilState);
    d.format = format;
    d.depthWriteEnabled = if (write) c.WGPUOptionalBool_True else c.WGPUOptionalBool_False;
    d.depthCompare = compare;
    return d;
}

// ── Readback (tests, screenshots) ──────────────────────────────────

fn mapCallback(
    status: c.WGPUMapAsyncStatus,
    _: c.WGPUStringView,
    userdata1: ?*anyopaque,
    _: ?*anyopaque,
) callconv(.c) void {
    const out: *c.WGPUMapAsyncStatus = @ptrCast(@alignCast(userdata1));
    out.* = status;
}

/// Copy `texture` (COPY_SRC, `bytes_per_pixel` per texel) into freshly
/// allocated tightly-packed rows. Blocks until the GPU is done.
pub fn readTexture(
    allocator: std.mem.Allocator,
    ctx: DeviceContext,
    texture: c.WGPUTexture,
    width: u32,
    height: u32,
    bytes_per_pixel: u32,
) ![]u8 {
    const row_bytes = width * bytes_per_pixel;
    const padded_row = std.mem.alignForward(u32, row_bytes, 256);
    const staging = createBuffer(ctx.device, "readback", c.WGPUBufferUsage_MapRead | c.WGPUBufferUsage_CopyDst, @as(u64, padded_row) * height) orelse
        return error.BufferCreateFailed;
    defer c.wgpuBufferRelease(staging);

    var enc_desc = std.mem.zeroes(c.WGPUCommandEncoderDescriptor);
    const encoder = c.wgpuDeviceCreateCommandEncoder(ctx.device, &enc_desc);
    var src = std.mem.zeroes(c.WGPUTexelCopyTextureInfo);
    src.texture = texture;
    src.aspect = c.WGPUTextureAspect_All;
    var dst = std.mem.zeroes(c.WGPUTexelCopyBufferInfo);
    dst.buffer = staging;
    dst.layout.bytesPerRow = padded_row;
    dst.layout.rowsPerImage = height;
    const extent = c.WGPUExtent3D{ .width = width, .height = height, .depthOrArrayLayers = 1 };
    c.wgpuCommandEncoderCopyTextureToBuffer(encoder, &src, &dst, &extent);
    var cb_desc = std.mem.zeroes(c.WGPUCommandBufferDescriptor);
    const cmd = c.wgpuCommandEncoderFinish(encoder, &cb_desc);
    c.wgpuCommandEncoderRelease(encoder);
    c.wgpuQueueSubmit(ctx.queue, 1, &cmd);
    c.wgpuCommandBufferRelease(cmd);

    var status: c.WGPUMapAsyncStatus = 0;
    var map_cb = std.mem.zeroes(c.WGPUBufferMapCallbackInfo);
    map_cb.mode = c.WGPUCallbackMode_AllowSpontaneous;
    map_cb.callback = &mapCallback;
    map_cb.userdata1 = @ptrCast(&status);
    _ = c.wgpuBufferMapAsync(staging, c.WGPUMapMode_Read, 0, @as(usize, padded_row) * height, map_cb);
    _ = c.wgpuDevicePoll(ctx.device, 1, null);
    if (status != c.WGPUMapAsyncStatus_Success) return error.MapFailed;

    const mapped: [*]const u8 = @ptrCast(c.wgpuBufferGetConstMappedRange(staging, 0, @as(usize, padded_row) * height) orelse return error.MapFailed);
    const out = try allocator.alloc(u8, @as(usize, row_bytes) * height);
    for (0..height) |y| {
        @memcpy(out[y * row_bytes ..][0..row_bytes], mapped[y * padded_row ..][0..row_bytes]);
    }
    c.wgpuBufferUnmap(staging);
    return out;
}
