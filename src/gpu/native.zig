//! wgpu-native GPU backend. Implements the `gpu/context.zig` contract.
//!
//! Consumer responsibility: add wgpu-native as a dependency, wire
//! include + library paths in the example's `build.zig`. Teak's library
//! build never links wgpu.

const std = @import("std");
const teak = @import("teak");

const Vertex = teak.Vertex;

const c = @cImport({
    @cDefine("WGPU_SHARED_LIBRARY", "1");
    @cInclude("webgpu.h");
    @cInclude("wgpu.h");
});

pub const ClearColor = teak.ClearColor;

// ── wgpu helpers ───────────────────────────────────────────────────

fn wgpuStr(s: []const u8) c.WGPUStringView {
    return .{ .data = s.ptr, .length = s.len };
}

const SHADER_CODE = @import("teak-shaders").quad_wgsl;

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

// ── Gpu ────────────────────────────────────────────────────────────

pub const Gpu = struct {
    instance: c.WGPUInstance,
    surface: c.WGPUSurface,
    adapter: c.WGPUAdapter,
    device: c.WGPUDevice,
    queue: c.WGPUQueue,
    pipeline: c.WGPURenderPipeline,
    bind_group: c.WGPUBindGroup,
    uniform_buf: c.WGPUBuffer,
    vert_buf: c.WGPUBuffer,
    vert_buf_size: u64,
    vert_count: u32,
    surf_format: c.WGPUTextureFormat,

    /// `handle` duck-types as `{ hinstance, hwnd }` (matches
    /// `platform/win32.zig`'s NativeHandle). Other surface sources would
    /// need alternative init entry points or a tagged NativeHandle.
    pub fn init(handle: anytype, width: u32, height: u32) !Gpu {
        var instance_desc = std.mem.zeroes(c.WGPUInstanceDescriptor);
        const instance = c.wgpuCreateInstance(&instance_desc) orelse return error.InstanceCreateFailed;

        // Surface from Win32 HWND.
        var hwnd_source = std.mem.zeroes(c.WGPUSurfaceSourceWindowsHWND);
        hwnd_source.chain.sType = c.WGPUSType_SurfaceSourceWindowsHWND;
        hwnd_source.hinstance = @ptrCast(handle.hinstance);
        hwnd_source.hwnd = @ptrCast(handle.hwnd);

        var surface_desc = std.mem.zeroes(c.WGPUSurfaceDescriptor);
        surface_desc.nextInChain = @ptrCast(&hwnd_source.chain);
        surface_desc.label = wgpuStr("teak-surface");
        const surface = c.wgpuInstanceCreateSurface(instance, &surface_desc) orelse return error.SurfaceCreateFailed;

        // Adapter (synchronous spin is fine on native; web can't do this).
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

        // Device.
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

        const queue = c.wgpuDeviceGetQueue(device);

        // Shader module.
        var wgsl_desc = std.mem.zeroes(c.WGPUShaderSourceWGSL);
        wgsl_desc.chain.sType = c.WGPUSType_ShaderSourceWGSL;
        wgsl_desc.code = wgpuStr(SHADER_CODE);

        var shader_desc = std.mem.zeroes(c.WGPUShaderModuleDescriptor);
        shader_desc.nextInChain = @ptrCast(&wgsl_desc.chain);
        shader_desc.label = wgpuStr("quad-shader");
        const shader = c.wgpuDeviceCreateShaderModule(device, &shader_desc) orelse return error.ShaderCreateFailed;
        defer c.wgpuShaderModuleRelease(shader);

        // Bind group layout (one uniform buffer for screen size).
        var bgl_entry = std.mem.zeroes(c.WGPUBindGroupLayoutEntry);
        bgl_entry.binding = 0;
        bgl_entry.visibility = c.WGPUShaderStage_Vertex;
        bgl_entry.buffer.type = c.WGPUBufferBindingType_Uniform;
        bgl_entry.buffer.minBindingSize = 8;

        var bgl_desc = std.mem.zeroes(c.WGPUBindGroupLayoutDescriptor);
        bgl_desc.label = wgpuStr("uniform-bgl");
        bgl_desc.entryCount = 1;
        bgl_desc.entries = &bgl_entry;
        const bind_group_layout = c.wgpuDeviceCreateBindGroupLayout(device, &bgl_desc) orelse return error.BglCreateFailed;
        defer c.wgpuBindGroupLayoutRelease(bind_group_layout);

        var pl_desc = std.mem.zeroes(c.WGPUPipelineLayoutDescriptor);
        pl_desc.label = wgpuStr("pipeline-layout");
        pl_desc.bindGroupLayoutCount = 1;
        pl_desc.bindGroupLayouts = &bind_group_layout;
        const pipeline_layout = c.wgpuDeviceCreatePipelineLayout(device, &pl_desc) orelse return error.PipelineLayoutFailed;
        defer c.wgpuPipelineLayoutRelease(pipeline_layout);

        // Render pipeline.
        const surf_format = c.WGPUTextureFormat_BGRA8Unorm;

        const vert_attrs = [_]c.WGPUVertexAttribute{
            .{ .format = c.WGPUVertexFormat_Float32x2, .offset = 0, .shaderLocation = 0 },
            .{ .format = c.WGPUVertexFormat_Float32x4, .offset = 8, .shaderLocation = 1 },
            .{ .format = c.WGPUVertexFormat_Float32x2, .offset = 24, .shaderLocation = 2 },
        };

        const vert_buf_layout = c.WGPUVertexBufferLayout{
            .arrayStride = @sizeOf(Vertex),
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
        const pipeline = c.wgpuDeviceCreateRenderPipeline(device, &pipeline_desc) orelse return error.PipelineCreateFailed;

        // Uniform buffer (8 bytes: vec2f screen_size).
        var ub_desc = std.mem.zeroes(c.WGPUBufferDescriptor);
        ub_desc.label = wgpuStr("uniform-buf");
        ub_desc.usage = c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst;
        ub_desc.size = 8;
        const uniform_buf = c.wgpuDeviceCreateBuffer(device, &ub_desc) orelse return error.UniformBufFailed;

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
        const bind_group = c.wgpuDeviceCreateBindGroup(device, &bg_desc) orelse return error.BindGroupFailed;

        var gpu: Gpu = .{
            .instance = instance,
            .surface = surface,
            .adapter = adapter,
            .device = device,
            .queue = queue,
            .pipeline = pipeline,
            .bind_group = bind_group,
            .uniform_buf = uniform_buf,
            .vert_buf = null,
            .vert_buf_size = 0,
            .vert_count = 0,
            .surf_format = surf_format,
        };
        gpu.resize(width, height);
        return gpu;
    }

    pub fn deinit(self: *Gpu) void {
        if (self.vert_buf) |vb| c.wgpuBufferRelease(vb);
        c.wgpuBindGroupRelease(self.bind_group);
        c.wgpuBufferRelease(self.uniform_buf);
        c.wgpuRenderPipelineRelease(self.pipeline);
        c.wgpuQueueRelease(self.queue);
        c.wgpuDeviceRelease(self.device);
        c.wgpuAdapterRelease(self.adapter);
        c.wgpuSurfaceRelease(self.surface);
        c.wgpuInstanceRelease(self.instance);
    }

    pub fn resize(self: *Gpu, width: u32, height: u32) void {
        var surf_config = std.mem.zeroes(c.WGPUSurfaceConfiguration);
        surf_config.device = self.device;
        surf_config.format = self.surf_format;
        surf_config.usage = c.WGPUTextureUsage_RenderAttachment;
        surf_config.width = width;
        surf_config.height = height;
        surf_config.presentMode = c.WGPUPresentMode_Fifo;
        surf_config.alphaMode = c.WGPUCompositeAlphaMode_Auto;
        c.wgpuSurfaceConfigure(self.surface, &surf_config);

        const screen_size = [2]f32{ @floatFromInt(width), @floatFromInt(height) };
        c.wgpuQueueWriteBuffer(self.queue, self.uniform_buf, 0, &screen_size, @sizeOf([2]f32));
    }

    pub fn uploadVertices(self: *Gpu, verts: []const Vertex) void {
        const byte_size: u64 = @intCast(verts.len * @sizeOf(Vertex));
        self.vert_count = @intCast(verts.len);
        if (byte_size == 0) return;

        if (self.vert_buf == null or byte_size > self.vert_buf_size) {
            if (self.vert_buf) |buf| c.wgpuBufferRelease(buf);
            self.vert_buf_size = @max(byte_size, 4096);
            var vb_desc = std.mem.zeroes(c.WGPUBufferDescriptor);
            vb_desc.label = wgpuStr("vertex-buf");
            vb_desc.usage = c.WGPUBufferUsage_Vertex | c.WGPUBufferUsage_CopyDst;
            vb_desc.size = self.vert_buf_size;
            self.vert_buf = c.wgpuDeviceCreateBuffer(self.device, &vb_desc);
        }
        c.wgpuQueueWriteBuffer(self.queue, self.vert_buf, 0, verts.ptr, byte_size);
    }

    pub fn renderFrame(self: *Gpu, clear_color: ClearColor) void {
        var surface_texture: c.WGPUSurfaceTexture = undefined;
        c.wgpuSurfaceGetCurrentTexture(self.surface, &surface_texture);
        if (surface_texture.status != c.WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal and
            surface_texture.status != c.WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal)
        {
            return;
        }

        const texture_view = c.wgpuTextureCreateView(surface_texture.texture, null);
        defer c.wgpuTextureViewRelease(texture_view);

        var enc_desc = std.mem.zeroes(c.WGPUCommandEncoderDescriptor);
        enc_desc.label = wgpuStr("frame-encoder");
        const encoder = c.wgpuDeviceCreateCommandEncoder(self.device, &enc_desc);

        var color_attachment = std.mem.zeroes(c.WGPURenderPassColorAttachment);
        color_attachment.view = texture_view;
        color_attachment.loadOp = c.WGPULoadOp_Clear;
        color_attachment.storeOp = c.WGPUStoreOp_Store;
        color_attachment.clearValue = .{
            .r = clear_color[0],
            .g = clear_color[1],
            .b = clear_color[2],
            .a = clear_color[3],
        };
        color_attachment.depthSlice = 0xFFFFFFFF;

        var rp_desc = std.mem.zeroes(c.WGPURenderPassDescriptor);
        rp_desc.label = wgpuStr("render-pass");
        rp_desc.colorAttachmentCount = 1;
        rp_desc.colorAttachments = &color_attachment;

        const pass = c.wgpuCommandEncoderBeginRenderPass(encoder, &rp_desc);

        if (self.vert_count > 0 and self.vert_buf != null) {
            const draw_byte_size: u64 = @intCast(self.vert_count * @sizeOf(Vertex));
            c.wgpuRenderPassEncoderSetPipeline(pass, self.pipeline);
            c.wgpuRenderPassEncoderSetBindGroup(pass, 0, self.bind_group, 0, null);
            c.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, self.vert_buf, 0, draw_byte_size);
            c.wgpuRenderPassEncoderDraw(pass, self.vert_count, 1, 0, 0);
        }

        c.wgpuRenderPassEncoderEnd(pass);
        c.wgpuRenderPassEncoderRelease(pass);

        var cmd_buf_desc = std.mem.zeroes(c.WGPUCommandBufferDescriptor);
        cmd_buf_desc.label = wgpuStr("frame-cmds");
        const command_buffer = c.wgpuCommandEncoderFinish(encoder, &cmd_buf_desc);
        c.wgpuCommandEncoderRelease(encoder);

        c.wgpuQueueSubmit(self.queue, 1, &command_buffer);
        c.wgpuCommandBufferRelease(command_buffer);

        _ = c.wgpuSurfacePresent(self.surface);
    }
};

comptime {
    teak.validateGpu(Gpu);
}
