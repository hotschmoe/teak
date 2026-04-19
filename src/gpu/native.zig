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
pub const TextureHandle = teak.TextureHandle;
pub const FontSpec = teak.FontSpec;
pub const FontFamily = teak.FontFamily;
pub const TextDraw = teak.TextDraw;

// ── Win32 types + GDI externs (text rasterization) ────────────────

const WINAPI = std.builtin.CallingConvention.winapi;
const BOOL = c_int;
const UINT = c_uint;
const DWORD = c_ulong;
const HANDLE = *anyopaque;
const HDC = *anyopaque;
const HBITMAP = *anyopaque;
const HFONT = *anyopaque;
const LPCWSTR = [*:0]const u16;
const COLORREF = DWORD;

const RECT = extern struct {
    left: c_long,
    top: c_long,
    right: c_long,
    bottom: c_long,
};

const TEXTMETRICW = extern struct {
    tmHeight: c_long,
    tmAscent: c_long,
    tmDescent: c_long,
    tmInternalLeading: c_long,
    tmExternalLeading: c_long,
    tmAveCharWidth: c_long,
    tmMaxCharWidth: c_long,
    tmWeight: c_long,
    tmOverhang: c_long,
    tmDigitizedAspectX: c_long,
    tmDigitizedAspectY: c_long,
    tmFirstChar: u16,
    tmLastChar: u16,
    tmDefaultChar: u16,
    tmBreakChar: u16,
    tmItalic: u8,
    tmUnderlined: u8,
    tmStruckOut: u8,
    tmPitchAndFamily: u8,
    tmCharSet: u8,
};

const BITMAPINFOHEADER = extern struct {
    biSize: DWORD = @sizeOf(BITMAPINFOHEADER),
    biWidth: c_long = 0,
    biHeight: c_long = 0,
    biPlanes: u16 = 1,
    biBitCount: u16 = 32,
    biCompression: DWORD = 0, // BI_RGB
    biSizeImage: DWORD = 0,
    biXPelsPerMeter: c_long = 0,
    biYPelsPerMeter: c_long = 0,
    biClrUsed: DWORD = 0,
    biClrImportant: DWORD = 0,
};

const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER,
    bmiColors: [4]u8 = [_]u8{0} ** 4, // placeholder for the palette tail
};

const FW_NORMAL: c_int = 400;
const DEFAULT_CHARSET: DWORD = 1;
const OUT_TT_PRECIS: DWORD = 4;
const CLIP_DEFAULT_PRECIS: DWORD = 0;
const CLEARTYPE_QUALITY: DWORD = 5;
const DEFAULT_PITCH: DWORD = 0;
const DIB_RGB_COLORS: UINT = 0;
const TRANSPARENT_BK: c_int = 1;
const DT_LEFT: UINT = 0x0000;
const DT_TOP: UINT = 0x0000;
const DT_SINGLELINE: UINT = 0x0020;
const DT_NOPREFIX: UINT = 0x0800;

extern "user32" fn GetDC(?HANDLE) callconv(WINAPI) ?HDC;
extern "user32" fn ReleaseDC(?HANDLE, HDC) callconv(WINAPI) c_int;
extern "user32" fn DrawTextW(HDC, LPCWSTR, c_int, *RECT, UINT) callconv(WINAPI) c_int;
extern "gdi32" fn CreateCompatibleDC(?HDC) callconv(WINAPI) ?HDC;
extern "gdi32" fn DeleteDC(HDC) callconv(WINAPI) BOOL;
extern "gdi32" fn CreateDIBSection(?HDC, *const BITMAPINFO, UINT, *?*anyopaque, ?HANDLE, DWORD) callconv(WINAPI) ?HBITMAP;
extern "gdi32" fn CreateFontW(
    c_int,
    c_int,
    c_int,
    c_int,
    c_int,
    DWORD,
    DWORD,
    DWORD,
    DWORD,
    DWORD,
    DWORD,
    DWORD,
    DWORD,
    LPCWSTR,
) callconv(WINAPI) ?HFONT;
extern "gdi32" fn SelectObject(HDC, HANDLE) callconv(WINAPI) ?HANDLE;
extern "gdi32" fn DeleteObject(HANDLE) callconv(WINAPI) BOOL;
extern "gdi32" fn SetTextColor(HDC, COLORREF) callconv(WINAPI) COLORREF;
extern "gdi32" fn SetBkMode(HDC, c_int) callconv(WINAPI) c_int;
extern "gdi32" fn GetTextMetricsW(HDC, *TEXTMETRICW) callconv(WINAPI) BOOL;

const FACE_SANS = std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI");
const FACE_SERIF = std.unicode.utf8ToUtf16LeStringLiteral("Cambria");
const FACE_MONO = std.unicode.utf8ToUtf16LeStringLiteral("Cascadia Mono");

fn fontFaceUtf16(family: FontFamily) LPCWSTR {
    return switch (family) {
        .sans => FACE_SANS,
        .serif => FACE_SERIF,
        .mono => FACE_MONO,
    };
}

const FontCacheEntry = struct {
    family: FontFamily,
    size_px: u16,
    hfont: HFONT,
};

// ── Text cache ─────────────────────────────────────────────────────

const TEXT_CACHE_CAPACITY: usize = 256;
const TEXT_CACHE_TTL_FRAMES: u64 = 120;
const TEXT_VERT_BUF_CAPACITY: usize = 256 * 6; // 256 text draws × 6 verts

const TextCacheEntry = struct {
    key: u64,
    content_len: u32,
    content_hash: u64,
    texture: c.WGPUTexture,
    view: c.WGPUTextureView,
    bind_group: c.WGPUBindGroup,
    last_used_frame: u64,
};

const TextDrawRecord = struct {
    bind_group: c.WGPUBindGroup,
    vert_offset: u32, // in vertices, not bytes
};

const SHADER_TEXT = @import("teak-shaders").textured_quad_wgsl;

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

    // ── Text pass ──────────────────────────────────────────────────
    text_pipeline: c.WGPURenderPipeline,
    text_bgl: c.WGPUBindGroupLayout,
    sampler: c.WGPUSampler,
    text_cache: [TEXT_CACHE_CAPACITY]TextCacheEntry,
    text_cache_len: usize,
    text_draws: [TEXT_CACHE_CAPACITY]TextDrawRecord,
    text_draw_count: usize,
    text_verts: [TEXT_VERT_BUF_CAPACITY]Vertex,
    text_vert_count: u32,
    text_vert_buf: c.WGPUBuffer,
    text_vert_buf_size: u64,
    frame_counter: u64,

    // ── Rasterization state (GDI) ──────────────────────────────────
    raster_dc: HDC,
    raster_font_cache: [8]FontCacheEntry,
    raster_font_cache_len: usize,

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

        // ── Text pipeline: second shader + BGL with uniform + texture
        //    + sampler. Reuses the same Vertex layout / blend state as
        //    the solid pipeline.
        var text_wgsl_desc = std.mem.zeroes(c.WGPUShaderSourceWGSL);
        text_wgsl_desc.chain.sType = c.WGPUSType_ShaderSourceWGSL;
        text_wgsl_desc.code = wgpuStr(SHADER_TEXT);
        var text_shader_desc = std.mem.zeroes(c.WGPUShaderModuleDescriptor);
        text_shader_desc.nextInChain = @ptrCast(&text_wgsl_desc.chain);
        text_shader_desc.label = wgpuStr("text-shader");
        const text_shader = c.wgpuDeviceCreateShaderModule(device, &text_shader_desc) orelse return error.TextShaderFailed;
        defer c.wgpuShaderModuleRelease(text_shader);

        var text_bgl_entries: [3]c.WGPUBindGroupLayoutEntry = undefined;
        text_bgl_entries[0] = std.mem.zeroes(c.WGPUBindGroupLayoutEntry);
        text_bgl_entries[0].binding = 0;
        text_bgl_entries[0].visibility = c.WGPUShaderStage_Vertex;
        text_bgl_entries[0].buffer.type = c.WGPUBufferBindingType_Uniform;
        text_bgl_entries[0].buffer.minBindingSize = 8;
        text_bgl_entries[1] = std.mem.zeroes(c.WGPUBindGroupLayoutEntry);
        text_bgl_entries[1].binding = 1;
        text_bgl_entries[1].visibility = c.WGPUShaderStage_Fragment;
        text_bgl_entries[1].texture.sampleType = c.WGPUTextureSampleType_Float;
        text_bgl_entries[1].texture.viewDimension = c.WGPUTextureViewDimension_2D;
        text_bgl_entries[2] = std.mem.zeroes(c.WGPUBindGroupLayoutEntry);
        text_bgl_entries[2].binding = 2;
        text_bgl_entries[2].visibility = c.WGPUShaderStage_Fragment;
        text_bgl_entries[2].sampler.type = c.WGPUSamplerBindingType_Filtering;

        var text_bgl_desc = std.mem.zeroes(c.WGPUBindGroupLayoutDescriptor);
        text_bgl_desc.label = wgpuStr("text-bgl");
        text_bgl_desc.entryCount = text_bgl_entries.len;
        text_bgl_desc.entries = &text_bgl_entries;
        const text_bgl = c.wgpuDeviceCreateBindGroupLayout(device, &text_bgl_desc) orelse return error.TextBglFailed;

        var text_pl_desc = std.mem.zeroes(c.WGPUPipelineLayoutDescriptor);
        text_pl_desc.label = wgpuStr("text-pipeline-layout");
        text_pl_desc.bindGroupLayoutCount = 1;
        text_pl_desc.bindGroupLayouts = &text_bgl;
        const text_pipeline_layout = c.wgpuDeviceCreatePipelineLayout(device, &text_pl_desc) orelse return error.TextPipelineLayoutFailed;
        defer c.wgpuPipelineLayoutRelease(text_pipeline_layout);

        var text_frag_state = std.mem.zeroes(c.WGPUFragmentState);
        text_frag_state.module = text_shader;
        text_frag_state.entryPoint = wgpuStr("fs_main");
        text_frag_state.targetCount = 1;
        text_frag_state.targets = &color_target;

        var text_pipeline_desc = std.mem.zeroes(c.WGPURenderPipelineDescriptor);
        text_pipeline_desc.label = wgpuStr("text-pipeline");
        text_pipeline_desc.layout = text_pipeline_layout;
        text_pipeline_desc.vertex.module = text_shader;
        text_pipeline_desc.vertex.entryPoint = wgpuStr("vs_main");
        text_pipeline_desc.vertex.bufferCount = 1;
        text_pipeline_desc.vertex.buffers = &vert_buf_layout;
        text_pipeline_desc.primitive.topology = c.WGPUPrimitiveTopology_TriangleList;
        text_pipeline_desc.primitive.frontFace = c.WGPUFrontFace_CCW;
        text_pipeline_desc.primitive.cullMode = c.WGPUCullMode_None;
        text_pipeline_desc.multisample.count = 1;
        text_pipeline_desc.multisample.mask = 0xFFFFFFFF;
        text_pipeline_desc.fragment = &text_frag_state;
        const text_pipeline = c.wgpuDeviceCreateRenderPipeline(device, &text_pipeline_desc) orelse return error.TextPipelineFailed;

        var sampler_desc = std.mem.zeroes(c.WGPUSamplerDescriptor);
        sampler_desc.label = wgpuStr("text-sampler");
        sampler_desc.addressModeU = c.WGPUAddressMode_ClampToEdge;
        sampler_desc.addressModeV = c.WGPUAddressMode_ClampToEdge;
        sampler_desc.addressModeW = c.WGPUAddressMode_ClampToEdge;
        sampler_desc.magFilter = c.WGPUFilterMode_Linear;
        sampler_desc.minFilter = c.WGPUFilterMode_Linear;
        sampler_desc.mipmapFilter = c.WGPUMipmapFilterMode_Nearest;
        sampler_desc.lodMinClamp = 0;
        sampler_desc.lodMaxClamp = 1;
        sampler_desc.maxAnisotropy = 1;
        const sampler = c.wgpuDeviceCreateSampler(device, &sampler_desc) orelse return error.SamplerFailed;

        // Memory DC for GDI rasterization. Separate from the Host's
        // measurement DC — keeps Host and Gpu decoupled.
        const screen_dc = GetDC(null) orelse return error.GetDcFailed;
        defer _ = ReleaseDC(null, screen_dc);
        const raster_dc = CreateCompatibleDC(screen_dc) orelse return error.CreateDcFailed;

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
            .text_pipeline = text_pipeline,
            .text_bgl = text_bgl,
            .sampler = sampler,
            .text_cache = undefined,
            .text_cache_len = 0,
            .text_draws = undefined,
            .text_draw_count = 0,
            .text_verts = undefined,
            .text_vert_count = 0,
            .text_vert_buf = null,
            .text_vert_buf_size = 0,
            .frame_counter = 0,
            .raster_dc = raster_dc,
            .raster_font_cache = undefined,
            .raster_font_cache_len = 0,
        };
        gpu.resize(width, height);
        return gpu;
    }

    pub fn deinit(self: *Gpu) void {
        // Text cache entries first — bind groups hold refs to the
        // texture views, which hold refs to textures.
        for (self.text_cache[0..self.text_cache_len]) |*e| freeTextEntry(e);
        if (self.text_vert_buf) |tb| c.wgpuBufferRelease(tb);
        c.wgpuSamplerRelease(self.sampler);
        c.wgpuBindGroupLayoutRelease(self.text_bgl);
        c.wgpuRenderPipelineRelease(self.text_pipeline);

        // Release GDI state.
        for (self.raster_font_cache[0..self.raster_font_cache_len]) |e| {
            _ = DeleteObject(e.hfont);
        }
        _ = DeleteDC(self.raster_dc);

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

    fn freeTextEntry(e: *TextCacheEntry) void {
        c.wgpuBindGroupRelease(e.bind_group);
        c.wgpuTextureViewRelease(e.view);
        c.wgpuTextureRelease(e.texture);
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

        if (self.text_draw_count > 0 and self.text_vert_buf != null) {
            const text_byte_size: u64 = @intCast(self.text_vert_count * @sizeOf(Vertex));
            c.wgpuRenderPassEncoderSetPipeline(pass, self.text_pipeline);
            c.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, self.text_vert_buf, 0, text_byte_size);
            for (self.text_draws[0..self.text_draw_count]) |rec| {
                c.wgpuRenderPassEncoderSetBindGroup(pass, 0, rec.bind_group, 0, null);
                c.wgpuRenderPassEncoderDraw(pass, 6, 1, rec.vert_offset, 0);
            }
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

    /// Rasterize `text_bytes` into a BGRA8Unorm texture `width × height`
    /// via GDI DrawTextW, upload to the GPU, return a TextureHandle =
    /// (cache slot + 1) so 0 stays the sentinel. Cache-aware: repeated
    /// calls with the same (content, font, color, w, h) reuse the
    /// existing texture.
    ///
    /// Color semantics: the rasterizer fills the bitmap with white
    /// glyphs on a transparent background, then rewrites each pixel as
    /// `{ color.bgr * 255, alpha = grayscale(bgr) * color.a }`. The
    /// text pass's fragment shader samples the alpha and modulates the
    /// quad color by it, so the texture carries coverage-as-alpha in
    /// any color. Matches the plan's alpha-from-luminance scheme.
    pub fn rasterizeText(
        self: *Gpu,
        text_bytes: []const u8,
        font: FontSpec,
        color: [4]f32,
        width: u32,
        height: u32,
    ) TextureHandle {
        if (width == 0 or height == 0) return teak.TEXTURE_HANDLE_NONE;

        const key = textCacheKey(text_bytes, font, color, width, height);
        const content_hash = std.hash.Wyhash.hash(0, text_bytes);

        // Cache hit — return the existing slot.
        for (self.text_cache[0..self.text_cache_len], 0..) |*e, i| {
            if (e.key == key and e.content_len == text_bytes.len and e.content_hash == content_hash) {
                e.last_used_frame = self.frame_counter;
                return @intCast(i + 1);
            }
        }

        // Cache miss — evict the oldest entry if we're full.
        if (self.text_cache_len >= self.text_cache.len) {
            var oldest: usize = 0;
            var oldest_frame: u64 = self.text_cache[0].last_used_frame;
            for (self.text_cache[0..self.text_cache_len], 0..) |*e, i| {
                if (e.last_used_frame < oldest_frame) {
                    oldest = i;
                    oldest_frame = e.last_used_frame;
                }
            }
            freeTextEntry(&self.text_cache[oldest]);
            // Swap-with-last to compact.
            self.text_cache[oldest] = self.text_cache[self.text_cache_len - 1];
            self.text_cache_len -= 1;
        }

        // Rasterize via GDI into a DIB, upload to a wgpu texture, create
        // a bind group binding it.
        const texture = rasterAndUpload(self, text_bytes, font, color, width, height) orelse
            return teak.TEXTURE_HANDLE_NONE;

        self.text_cache[self.text_cache_len] = texture;
        self.text_cache[self.text_cache_len].key = key;
        self.text_cache[self.text_cache_len].content_len = @intCast(text_bytes.len);
        self.text_cache[self.text_cache_len].content_hash = content_hash;
        self.text_cache[self.text_cache_len].last_used_frame = self.frame_counter;
        self.text_cache_len += 1;
        return @intCast(self.text_cache_len); // handle = slot index + 1
    }

    /// Per-frame text orchestration. Rasterizes each TextDraw (with
    /// cache), emits 6 textured vertices per visible draw, records a
    /// draw entry for `renderFrame`'s text pass. Must be called after
    /// `uploadVertices` and before `renderFrame`.
    pub fn uploadText(self: *Gpu, draws: []const TextDraw) void {
        self.frame_counter += 1;
        self.text_draw_count = 0;
        self.text_vert_count = 0;

        for (draws) |draw| {
            // Clip entirely offscreen drops the whole quad.
            const vis_x0 = @max(draw.rect_x, draw.clip_x);
            const vis_y0 = @max(draw.rect_y, draw.clip_y);
            const vis_x1 = @min(draw.rect_x + draw.rect_w, draw.clip_x + draw.clip_w);
            const vis_y1 = @min(draw.rect_y + draw.rect_h, draw.clip_y + draw.clip_h);
            if (vis_x1 <= vis_x0 or vis_y1 <= vis_y0) continue;

            // Round texture size up to integer pixels.
            const tex_w: u32 = @intFromFloat(@ceil(draw.rect_w));
            const tex_h: u32 = @intFromFloat(@ceil(draw.rect_h));
            if (tex_w == 0 or tex_h == 0) continue;

            const handle = self.rasterizeText(draw.content, draw.font, draw.color, tex_w, tex_h);
            if (handle == teak.TEXTURE_HANDLE_NONE) continue;
            const entry = &self.text_cache[handle - 1];

            // UVs: clipped rect maps to a sub-rect of the full texture.
            // `u0/u1` would shadow Zig's integer-type primitives.
            const uv_u0 = (vis_x0 - draw.rect_x) / draw.rect_w;
            const uv_v0 = (vis_y0 - draw.rect_y) / draw.rect_h;
            const uv_u1 = (vis_x1 - draw.rect_x) / draw.rect_w;
            const uv_v1 = (vis_y1 - draw.rect_y) / draw.rect_h;

            // Color is passed through the vertex stream so the shader
            // can multiply the alpha-from-texture by color.a.
            const r = draw.color[0];
            const g = draw.color[1];
            const b = draw.color[2];
            const a = draw.color[3];

            const offset = self.text_vert_count;
            if (offset + 6 > self.text_verts.len) break; // text buffer full

            const verts = &self.text_verts;
            verts[offset + 0] = .{ .x = vis_x0, .y = vis_y0, .r = r, .g = g, .b = b, .a = a, .u = uv_u0, .v = uv_v0 };
            verts[offset + 1] = .{ .x = vis_x1, .y = vis_y0, .r = r, .g = g, .b = b, .a = a, .u = uv_u1, .v = uv_v0 };
            verts[offset + 2] = .{ .x = vis_x0, .y = vis_y1, .r = r, .g = g, .b = b, .a = a, .u = uv_u0, .v = uv_v1 };
            verts[offset + 3] = .{ .x = vis_x1, .y = vis_y0, .r = r, .g = g, .b = b, .a = a, .u = uv_u1, .v = uv_v0 };
            verts[offset + 4] = .{ .x = vis_x1, .y = vis_y1, .r = r, .g = g, .b = b, .a = a, .u = uv_u1, .v = uv_v1 };
            verts[offset + 5] = .{ .x = vis_x0, .y = vis_y1, .r = r, .g = g, .b = b, .a = a, .u = uv_u0, .v = uv_v1 };

            self.text_vert_count += 6;
            self.text_draws[self.text_draw_count] = .{
                .bind_group = entry.bind_group,
                .vert_offset = offset,
            };
            self.text_draw_count += 1;
        }

        // Upload the text vertex buffer.
        const byte_size: u64 = @intCast(self.text_vert_count * @sizeOf(Vertex));
        if (byte_size == 0) return;

        if (self.text_vert_buf == null or byte_size > self.text_vert_buf_size) {
            if (self.text_vert_buf) |buf| c.wgpuBufferRelease(buf);
            self.text_vert_buf_size = @max(byte_size, 4096);
            var vb_desc = std.mem.zeroes(c.WGPUBufferDescriptor);
            vb_desc.label = wgpuStr("text-vert-buf");
            vb_desc.usage = c.WGPUBufferUsage_Vertex | c.WGPUBufferUsage_CopyDst;
            vb_desc.size = self.text_vert_buf_size;
            self.text_vert_buf = c.wgpuDeviceCreateBuffer(self.device, &vb_desc);
        }
        c.wgpuQueueWriteBuffer(self.queue, self.text_vert_buf, 0, &self.text_verts, byte_size);
    }
};

// ── Cache helpers ──────────────────────────────────────────────────

fn textCacheKey(content: []const u8, font: FontSpec, color: [4]f32, w: u32, h: u32) u64 {
    const content_hash = std.hash.Wyhash.hash(0, content);
    const color_bits =
        (@as(u32, @intFromFloat(std.math.clamp(color[0], 0, 1) * 255)) << 24) |
        (@as(u32, @intFromFloat(std.math.clamp(color[1], 0, 1) * 255)) << 16) |
        (@as(u32, @intFromFloat(std.math.clamp(color[2], 0, 1) * 255)) << 8) |
        (@as(u32, @intFromFloat(std.math.clamp(color[3], 0, 1) * 255)));
    const size_px: u16 = @intFromFloat(font.size_px);
    const font_bits: u64 = (@as(u64, size_px) << 16) | @as(u64, @intFromEnum(font.family));
    const dim_bits: u64 = (@as(u64, w) << 32) | @as(u64, h);
    return content_hash ^ font_bits ^ @as(u64, color_bits) ^ dim_bits;
}

// ── GDI rasterization ──────────────────────────────────────────────

fn rasterAndUpload(
    self: *Gpu,
    text_bytes: []const u8,
    font: FontSpec,
    color: [4]f32,
    width: u32,
    height: u32,
) ?TextCacheEntry {
    const hfont = getOrCreateFont(self, font) orelse return null;

    // CreateDIBSection with negative height yields top-down rows,
    // matching wgpu's texture-upload row order.
    var bi = BITMAPINFO{
        .bmiHeader = .{
            .biWidth = @intCast(width),
            .biHeight = -@as(c_long, @intCast(height)),
            .biPlanes = 1,
            .biBitCount = 32,
            .biCompression = 0, // BI_RGB
        },
    };
    var pixels: ?*anyopaque = null;
    const hbmp = CreateDIBSection(self.raster_dc, &bi, DIB_RGB_COLORS, &pixels, null, 0) orelse return null;
    defer _ = DeleteObject(hbmp);
    const pixel_bytes: [*]u8 = @ptrCast(pixels orelse return null);

    // GDI writes RGB on the existing DIB bits; we initialized none,
    // but CreateDIBSection always zero-fills. Draw white glyphs on the
    // zeroed bg, then rewrite every pixel with the target color and
    // alpha = coverage.
    const old_bmp = SelectObject(self.raster_dc, hbmp);
    defer _ = SelectObject(self.raster_dc, old_bmp.?);
    _ = SelectObject(self.raster_dc, hfont);
    _ = SetTextColor(self.raster_dc, 0x00FFFFFF); // BGR white
    _ = SetBkMode(self.raster_dc, TRANSPARENT_BK);

    var rect = RECT{
        .left = 0,
        .top = 0,
        .right = @intCast(width),
        .bottom = @intCast(height),
    };

    var utf16_buf: [1024]u16 = undefined;
    const utf16_len = std.unicode.utf8ToUtf16Le(&utf16_buf, text_bytes) catch 0;
    if (utf16_len > 0) {
        _ = DrawTextW(
            self.raster_dc,
            @ptrCast(&utf16_buf),
            @intCast(utf16_len),
            &rect,
            DT_LEFT | DT_TOP | DT_SINGLELINE | DT_NOPREFIX,
        );
    }

    // Post-pass: convert grayscale-in-BGR into alpha, then stamp the
    // target color into BGR.
    const total_pixels = @as(usize, width) * @as(usize, height);
    const r_byte: u8 = @intFromFloat(std.math.clamp(color[0], 0, 1) * 255);
    const g_byte: u8 = @intFromFloat(std.math.clamp(color[1], 0, 1) * 255);
    const b_byte: u8 = @intFromFloat(std.math.clamp(color[2], 0, 1) * 255);
    var i: usize = 0;
    while (i < total_pixels) : (i += 1) {
        const off = i * 4;
        // CreateDIBSection stores BGRA little-endian (B, G, R, A).
        const bb = pixel_bytes[off + 0];
        const gg = pixel_bytes[off + 1];
        const rr = pixel_bytes[off + 2];
        const coverage = @max(@max(bb, gg), rr);
        pixel_bytes[off + 0] = b_byte;
        pixel_bytes[off + 1] = g_byte;
        pixel_bytes[off + 2] = r_byte;
        pixel_bytes[off + 3] = coverage;
    }

    // Upload to a fresh wgpu texture.
    var tex_desc = std.mem.zeroes(c.WGPUTextureDescriptor);
    tex_desc.label = wgpuStr("text-texture");
    tex_desc.usage = c.WGPUTextureUsage_TextureBinding | c.WGPUTextureUsage_CopyDst;
    tex_desc.dimension = c.WGPUTextureDimension_2D;
    tex_desc.size = .{ .width = width, .height = height, .depthOrArrayLayers = 1 };
    tex_desc.format = c.WGPUTextureFormat_BGRA8Unorm;
    tex_desc.mipLevelCount = 1;
    tex_desc.sampleCount = 1;
    const texture = c.wgpuDeviceCreateTexture(self.device, &tex_desc) orelse return null;

    var dst = std.mem.zeroes(c.WGPUTexelCopyTextureInfo);
    dst.texture = texture;
    dst.mipLevel = 0;
    dst.aspect = c.WGPUTextureAspect_All;

    var data_layout = std.mem.zeroes(c.WGPUTexelCopyBufferLayout);
    data_layout.offset = 0;
    data_layout.bytesPerRow = width * 4;
    data_layout.rowsPerImage = height;

    var write_size = std.mem.zeroes(c.WGPUExtent3D);
    write_size.width = width;
    write_size.height = height;
    write_size.depthOrArrayLayers = 1;

    c.wgpuQueueWriteTexture(self.queue, &dst, pixel_bytes, @as(usize, width) * @as(usize, height) * 4, &data_layout, &write_size);

    var view_desc = std.mem.zeroes(c.WGPUTextureViewDescriptor);
    view_desc.label = wgpuStr("text-texture-view");
    view_desc.format = c.WGPUTextureFormat_BGRA8Unorm;
    view_desc.dimension = c.WGPUTextureViewDimension_2D;
    view_desc.mipLevelCount = 1;
    view_desc.arrayLayerCount = 1;
    view_desc.aspect = c.WGPUTextureAspect_All;
    const view = c.wgpuTextureCreateView(texture, &view_desc) orelse {
        c.wgpuTextureRelease(texture);
        return null;
    };

    var bg_entries: [3]c.WGPUBindGroupEntry = undefined;
    bg_entries[0] = std.mem.zeroes(c.WGPUBindGroupEntry);
    bg_entries[0].binding = 0;
    bg_entries[0].buffer = self.uniform_buf;
    bg_entries[0].offset = 0;
    bg_entries[0].size = 8;
    bg_entries[1] = std.mem.zeroes(c.WGPUBindGroupEntry);
    bg_entries[1].binding = 1;
    bg_entries[1].textureView = view;
    bg_entries[2] = std.mem.zeroes(c.WGPUBindGroupEntry);
    bg_entries[2].binding = 2;
    bg_entries[2].sampler = self.sampler;

    var bg_desc = std.mem.zeroes(c.WGPUBindGroupDescriptor);
    bg_desc.label = wgpuStr("text-bg");
    bg_desc.layout = self.text_bgl;
    bg_desc.entryCount = bg_entries.len;
    bg_desc.entries = &bg_entries;
    const bind_group = c.wgpuDeviceCreateBindGroup(self.device, &bg_desc) orelse {
        c.wgpuTextureViewRelease(view);
        c.wgpuTextureRelease(texture);
        return null;
    };

    return TextCacheEntry{
        .key = 0, // caller fills in
        .content_len = 0,
        .content_hash = 0,
        .texture = texture,
        .view = view,
        .bind_group = bind_group,
        .last_used_frame = 0,
    };
}

fn getOrCreateFont(self: *Gpu, font: FontSpec) ?HFONT {
    const size_px: u16 = @intFromFloat(font.size_px);
    for (self.raster_font_cache[0..self.raster_font_cache_len]) |*e| {
        if (e.family == font.family and e.size_px == size_px) return e.hfont;
    }
    if (self.raster_font_cache_len >= self.raster_font_cache.len) return null;

    const hfont = CreateFontW(
        -@as(c_int, @intCast(size_px)),
        0,
        0,
        0,
        FW_NORMAL,
        0,
        0,
        0,
        DEFAULT_CHARSET,
        OUT_TT_PRECIS,
        CLIP_DEFAULT_PRECIS,
        CLEARTYPE_QUALITY,
        DEFAULT_PITCH,
        fontFaceUtf16(font.family),
    ) orelse return null;

    self.raster_font_cache[self.raster_font_cache_len] = .{
        .family = font.family,
        .size_px = size_px,
        .hfont = hfont,
    };
    self.raster_font_cache_len += 1;
    return hfont;
}

comptime {
    teak.validateGpu(Gpu);
}
