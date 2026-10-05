//! Native (wgpu-native) 3D scene renderer: mesh resources plus offscreen
//! scene targets. Knows nothing about surfaces or the UI pass, so it runs
//! headless (see `wgpu_scene_test.zig`); `wgpu_core.Gpu` owns one and
//! composites its targets into the UI frame.
//!
//! Per scene slot (`index` in `renderInto`) it keeps a colour target the
//! UI pass samples, plus MSAA colour and depth targets used while drawing.
//! A slot is only re-rendered when `scene_common.signature` changes, so a
//! scene beside an animating widget costs nothing per frame.

const std = @import("std");
const teak = @import("teak");
const wgpu_c = @import("wgpu_c.zig");
const common = @import("scene_common.zig");
const SlotTable = @import("slot_table.zig").SlotTable;
const scene_wgsl = @import("teak-shaders").scene_wgsl;

const c = wgpu_c.c;
const MeshData = teak.MeshData;
const MeshHandle = teak.MeshHandle;
const MeshVertex = teak.MeshVertex;
const LineVertex = teak.LineVertex;
const SceneDraw = teak.SceneDraw;
const TargetSize = common.TargetSize;

pub const MESH_CAPACITY: usize = 128;
pub const depth_format = c.WGPUTextureFormat_Depth32Float;

const MeshEntry = struct {
    vertex_buf: c.WGPUBuffer,
    index_buf: c.WGPUBuffer,
    line_buf: c.WGPUBuffer,
    index_count: u32,
    segment_count: u32,
    /// Bumped on every upload so a re-upload into a reused slot is a
    /// different mesh as far as `signature` is concerned.
    version: u32,

    fn release(self: MeshEntry) void {
        if (self.vertex_buf) |b| c.wgpuBufferRelease(b);
        if (self.index_buf) |b| c.wgpuBufferRelease(b);
        if (self.line_buf) |b| c.wgpuBufferRelease(b);
    }
};

/// Resources of one scene slot. `color_view` is what the UI pass samples;
/// `generation` changes whenever those resources are recreated so the
/// owner can refresh anything bound to the view.
pub const Target = struct {
    size: TargetSize,
    color: c.WGPUTexture,
    color_view: c.WGPUTextureView,
    msaa: c.WGPUTexture,
    msaa_view: c.WGPUTextureView,
    depth: c.WGPUTexture,
    depth_view: c.WGPUTextureView,
    uniform_buf: c.WGPUBuffer,
    bind_group: c.WGPUBindGroup,
    signature: u64,
    generation: u32,

    fn release(self: Target) void {
        c.wgpuBindGroupRelease(self.bind_group);
        c.wgpuBufferRelease(self.uniform_buf);
        c.wgpuTextureViewRelease(self.depth_view);
        c.wgpuTextureRelease(self.depth);
        if (self.msaa_view) |v| c.wgpuTextureViewRelease(v);
        if (self.msaa) |t| c.wgpuTextureRelease(t);
        c.wgpuTextureViewRelease(self.color_view);
        c.wgpuTextureRelease(self.color);
    }
};

pub const Renderer = struct {
    device: c.WGPUDevice,
    queue: c.WGPUQueue,
    format: c.WGPUTextureFormat,
    samples: u32,

    bgl: c.WGPUBindGroupLayout,
    mesh_pipeline: c.WGPURenderPipeline,
    line_pipeline: c.WGPURenderPipeline,

    meshes: SlotTable(MeshEntry, MESH_CAPACITY) = .{},
    next_version: u32 = 1,
    targets: [common.max_scenes]?Target = @splat(null),
    next_generation: u32 = 1,

    /// `format` is the colour format of the targets (and of the UI pass
    /// that samples them). `msaa` selects 4x multisampling of scene targets.
    pub fn init(device: c.WGPUDevice, queue: c.WGPUQueue, format: c.WGPUTextureFormat, msaa: bool) !Renderer {
        const samples: u32 = if (msaa) common.msaa_samples else 1;
        const shader = try wgpu_c.createShader(device, "scene-shader", scene_wgsl);
        defer c.wgpuShaderModuleRelease(shader);

        var entry = std.mem.zeroes(c.WGPUBindGroupLayoutEntry);
        entry.binding = 0;
        entry.visibility = c.WGPUShaderStage_Vertex | c.WGPUShaderStage_Fragment;
        entry.buffer.type = c.WGPUBufferBindingType_Uniform;
        entry.buffer.minBindingSize = @sizeOf(common.Globals);
        var bgl_desc = std.mem.zeroes(c.WGPUBindGroupLayoutDescriptor);
        bgl_desc.label = wgpu_c.wgpuStr("scene-bgl");
        bgl_desc.entryCount = 1;
        bgl_desc.entries = &entry;
        const bgl = c.wgpuDeviceCreateBindGroupLayout(device, &bgl_desc) orelse return error.BglCreateFailed;

        var pl_desc = std.mem.zeroes(c.WGPUPipelineLayoutDescriptor);
        pl_desc.label = wgpu_c.wgpuStr("scene-pipeline-layout");
        pl_desc.bindGroupLayoutCount = 1;
        pl_desc.bindGroupLayouts = &bgl;
        const layout = c.wgpuDeviceCreatePipelineLayout(device, &pl_desc) orelse return error.PipelineLayoutFailed;
        defer c.wgpuPipelineLayoutRelease(layout);

        const mesh_attrs = [_]c.WGPUVertexAttribute{
            .{ .format = c.WGPUVertexFormat_Float32x3, .offset = @offsetOf(MeshVertex, "pos"), .shaderLocation = 0 },
            .{ .format = c.WGPUVertexFormat_Float32x3, .offset = @offsetOf(MeshVertex, "normal"), .shaderLocation = 1 },
            .{ .format = c.WGPUVertexFormat_Float32x4, .offset = @offsetOf(MeshVertex, "color"), .shaderLocation = 2 },
        };
        const mesh_layout = [_]c.WGPUVertexBufferLayout{.{
            .arrayStride = @sizeOf(MeshVertex),
            .stepMode = c.WGPUVertexStepMode_Vertex,
            .attributeCount = mesh_attrs.len,
            .attributes = &mesh_attrs,
        }};
        // One instance = one segment = a pair of LineVertex.
        const seg_stride = 2 * @sizeOf(LineVertex);
        const line_attrs = [_]c.WGPUVertexAttribute{
            .{ .format = c.WGPUVertexFormat_Float32x3, .offset = @offsetOf(LineVertex, "pos"), .shaderLocation = 0 },
            .{ .format = c.WGPUVertexFormat_Float32x4, .offset = @offsetOf(LineVertex, "color"), .shaderLocation = 1 },
            .{ .format = c.WGPUVertexFormat_Float32x3, .offset = @sizeOf(LineVertex) + @offsetOf(LineVertex, "pos"), .shaderLocation = 2 },
            .{ .format = c.WGPUVertexFormat_Float32x4, .offset = @sizeOf(LineVertex) + @offsetOf(LineVertex, "color"), .shaderLocation = 3 },
        };
        const line_layout = [_]c.WGPUVertexBufferLayout{.{
            .arrayStride = seg_stride,
            .stepMode = c.WGPUVertexStepMode_Instance,
            .attributeCount = line_attrs.len,
            .attributes = &line_attrs,
        }};

        const mesh_pipeline = wgpu_c.createPipeline(device, .{
            .label = "scene-mesh-pipeline",
            .layout = layout,
            .module = shader,
            .vs_entry = "vs_mesh",
            .fs_entry = "fs_mesh",
            .vertex_buffers = &mesh_layout,
            .format = format,
            .blend = null,
            .depth = wgpu_c.depthState(depth_format, true, c.WGPUCompareFunction_Less),
            .samples = samples,
        }) orelse return error.PipelineCreateFailed;
        const line_pipeline = wgpu_c.createPipeline(device, .{
            .label = "scene-line-pipeline",
            .layout = layout,
            .module = shader,
            .vs_entry = "vs_line",
            .fs_entry = "fs_line",
            .vertex_buffers = &line_layout,
            .format = format,
            .depth = wgpu_c.depthState(depth_format, false, c.WGPUCompareFunction_LessEqual),
            .samples = samples,
        }) orelse return error.PipelineCreateFailed;

        return .{
            .device = device,
            .queue = queue,
            .format = format,
            .samples = samples,
            .bgl = bgl,
            .mesh_pipeline = mesh_pipeline,
            .line_pipeline = line_pipeline,
        };
    }

    pub fn deinit(self: *Renderer) void {
        var it = self.meshes.iterator();
        while (it.next()) |m| m.release();
        for (self.targets) |t| if (t) |tt| tt.release();
        c.wgpuRenderPipelineRelease(self.line_pipeline);
        c.wgpuRenderPipelineRelease(self.mesh_pipeline);
        c.wgpuBindGroupLayoutRelease(self.bgl);
    }

    // ── Meshes ─────────────────────────────────────────────────────

    /// Copy `data` into GPU buffers. Returns `MESH_HANDLE_NONE` when the
    /// data is invalid, the table is full, or the device refuses.
    pub fn uploadMesh(self: *Renderer, data: MeshData) MeshHandle {
        data.validate() catch return teak.MESH_HANDLE_NONE;
        var entry = MeshEntry{
            .vertex_buf = null,
            .index_buf = null,
            .line_buf = null,
            .index_count = 0,
            .segment_count = @intCast(data.segmentCount()),
            .version = self.next_version,
        };
        if (!self.fillMesh(&entry, data)) {
            entry.release();
            return teak.MESH_HANDLE_NONE;
        }
        const handle = self.meshes.insert(entry) orelse {
            entry.release();
            return teak.MESH_HANDLE_NONE;
        };
        self.next_version +%= 1;
        return handle;
    }

    /// Create and fill `entry`'s buffers; false on device failure (the
    /// caller releases whatever was created).
    fn fillMesh(self: *Renderer, entry: *MeshEntry, data: MeshData) bool {
        if (data.vertices.len > 0 and data.indices.len > 0) {
            entry.vertex_buf = self.makeBuffer("mesh-vertices", c.WGPUBufferUsage_Vertex, std.mem.sliceAsBytes(data.vertices)) orelse return false;
            entry.index_buf = self.makeBuffer("mesh-indices", c.WGPUBufferUsage_Index, std.mem.sliceAsBytes(data.indices)) orelse return false;
            entry.index_count = @intCast(data.indices.len);
        }
        if (entry.segment_count > 0) {
            const used = data.lines[0 .. entry.segment_count * 2];
            entry.line_buf = self.makeBuffer("mesh-lines", c.WGPUBufferUsage_Vertex, std.mem.sliceAsBytes(used)) orelse return false;
        }
        return true;
    }

    fn makeBuffer(self: *Renderer, label: []const u8, usage: c.WGPUBufferUsage, bytes: []const u8) c.WGPUBuffer {
        const buf = wgpu_c.createBuffer(self.device, label, usage | c.WGPUBufferUsage_CopyDst, bytes.len) orelse return null;
        c.wgpuQueueWriteBuffer(self.queue, buf, 0, bytes.ptr, bytes.len);
        return buf;
    }

    pub fn releaseMesh(self: *Renderer, handle: MeshHandle) void {
        if (self.meshes.remove(handle)) |m| m.release();
    }

    fn meshVersion(self: *Renderer, handle: MeshHandle) u32 {
        return if (self.meshes.get(handle)) |m| m.version else 0;
    }

    // ── Targets ────────────────────────────────────────────────────

    pub fn target(self: *const Renderer, index: usize) ?*const Target {
        return if (self.targets[index]) |*t| t else null;
    }

    fn createTarget(self: *Renderer, size: TargetSize) error{GpuResource}!Target {
        const sampled = c.WGPUTextureUsage_RenderAttachment | c.WGPUTextureUsage_TextureBinding | c.WGPUTextureUsage_CopySrc;
        const color = wgpu_c.createTexture2D(self.device, "scene-color", .{ .width = size.w, .height = size.h, .format = self.format, .usage = sampled }) orelse return error.GpuResource;
        errdefer c.wgpuTextureRelease(color);
        const color_view = wgpu_c.createView2D(color, "scene-color-view", self.format) orelse return error.GpuResource;
        errdefer c.wgpuTextureViewRelease(color_view);

        var msaa: c.WGPUTexture = null;
        var msaa_view: c.WGPUTextureView = null;
        if (self.samples > 1) {
            msaa = wgpu_c.createTexture2D(self.device, "scene-msaa", .{ .width = size.w, .height = size.h, .format = self.format, .usage = c.WGPUTextureUsage_RenderAttachment, .samples = self.samples }) orelse return error.GpuResource;
            msaa_view = wgpu_c.createView2D(msaa, "scene-msaa-view", self.format) orelse {
                c.wgpuTextureRelease(msaa);
                return error.GpuResource;
            };
        }
        errdefer if (msaa != null) {
            c.wgpuTextureViewRelease(msaa_view);
            c.wgpuTextureRelease(msaa);
        };

        const depth = wgpu_c.createTexture2D(self.device, "scene-depth", .{ .width = size.w, .height = size.h, .format = depth_format, .usage = c.WGPUTextureUsage_RenderAttachment, .samples = self.samples }) orelse return error.GpuResource;
        errdefer c.wgpuTextureRelease(depth);
        const depth_view = wgpu_c.createView2D(depth, "scene-depth-view", depth_format) orelse return error.GpuResource;
        errdefer c.wgpuTextureViewRelease(depth_view);
        const uniform_buf = wgpu_c.createBuffer(self.device, "scene-uniforms", c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst, @sizeOf(common.Globals)) orelse return error.GpuResource;
        errdefer c.wgpuBufferRelease(uniform_buf);

        var bg_entry = std.mem.zeroes(c.WGPUBindGroupEntry);
        bg_entry.binding = 0;
        bg_entry.buffer = uniform_buf;
        bg_entry.size = @sizeOf(common.Globals);
        var bg_desc = std.mem.zeroes(c.WGPUBindGroupDescriptor);
        bg_desc.label = wgpu_c.wgpuStr("scene-bg");
        bg_desc.layout = self.bgl;
        bg_desc.entryCount = 1;
        bg_desc.entries = &bg_entry;
        const bind_group = c.wgpuDeviceCreateBindGroup(self.device, &bg_desc) orelse return error.GpuResource;

        const gen = self.next_generation;
        self.next_generation +%= 1;
        return .{
            .size = size,
            .color = color,
            .color_view = color_view,
            .msaa = msaa,
            .msaa_view = msaa_view,
            .depth = depth,
            .depth_view = depth_view,
            .uniform_buf = uniform_buf,
            .bind_group = bind_group,
            .signature = 0,
            .generation = gen,
        };
    }

    /// Make sure slot `index` has targets of `size`, recreating on change.
    fn ensureTarget(self: *Renderer, index: usize, size: TargetSize) ?*Target {
        if (self.targets[index]) |*t| {
            if (t.size.w == size.w and t.size.h == size.h) return t;
            t.release();
            self.targets[index] = null;
        }
        self.targets[index] = self.createTarget(size) catch null;
        return if (self.targets[index]) |*t| t else null;
    }

    /// Draw `draw` into slot `index`, recording into `encoder`; a no-op
    /// when the slot already holds this exact picture. Returns the target
    /// size (the owner composites `target(index).color_view`), or null if
    /// the scene has no pixels or the device could not allocate targets.
    /// `scale` = device pixels per logical pixel.
    pub fn renderInto(self: *Renderer, encoder: c.WGPUCommandEncoder, index: usize, draw: SceneDraw, scale: f32) ?TargetSize {
        const size = common.targetSize(draw.rect_w, draw.rect_h, scale) orelse return null;
        const t = self.ensureTarget(index, size) orelse return null;

        const sig = common.signature(draw, size, scale, self.meshVersion(draw.mesh));
        if (t.signature == sig) return size;
        t.signature = sig;

        const g = common.globals(draw, size, scale);
        c.wgpuQueueWriteBuffer(self.queue, t.uniform_buf, 0, &g, @sizeOf(common.Globals));

        var color = std.mem.zeroes(c.WGPURenderPassColorAttachment);
        const multisampled = self.samples > 1;
        color.view = if (multisampled) t.msaa_view else t.color_view;
        color.resolveTarget = if (multisampled) t.color_view else null;
        color.loadOp = c.WGPULoadOp_Clear;
        color.storeOp = if (multisampled) c.WGPUStoreOp_Discard else c.WGPUStoreOp_Store;
        color.clearValue = .{ .r = draw.clear[0], .g = draw.clear[1], .b = draw.clear[2], .a = draw.clear[3] };
        color.depthSlice = 0xFFFFFFFF;

        var depth = std.mem.zeroes(c.WGPURenderPassDepthStencilAttachment);
        depth.view = t.depth_view;
        depth.depthLoadOp = c.WGPULoadOp_Clear;
        depth.depthStoreOp = c.WGPUStoreOp_Discard;
        depth.depthClearValue = 1.0;

        var rp = std.mem.zeroes(c.WGPURenderPassDescriptor);
        rp.label = wgpu_c.wgpuStr("scene-pass");
        rp.colorAttachmentCount = 1;
        rp.colorAttachments = &color;
        rp.depthStencilAttachment = &depth;
        const pass = c.wgpuCommandEncoderBeginRenderPass(encoder, &rp);

        if (self.meshes.get(draw.mesh)) |m| {
            c.wgpuRenderPassEncoderSetBindGroup(pass, 0, t.bind_group, 0, null);
            if (m.index_count > 0) {
                c.wgpuRenderPassEncoderSetPipeline(pass, self.mesh_pipeline);
                c.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, m.vertex_buf, 0, c.WGPU_WHOLE_SIZE);
                c.wgpuRenderPassEncoderSetIndexBuffer(pass, m.index_buf, c.WGPUIndexFormat_Uint32, 0, c.WGPU_WHOLE_SIZE);
                c.wgpuRenderPassEncoderDrawIndexed(pass, m.index_count, 1, 0, 0, 0);
            }
            if (m.segment_count > 0) {
                c.wgpuRenderPassEncoderSetPipeline(pass, self.line_pipeline);
                c.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, m.line_buf, 0, c.WGPU_WHOLE_SIZE);
                c.wgpuRenderPassEncoderDraw(pass, 6, m.segment_count, 0, 0);
            }
        }

        c.wgpuRenderPassEncoderEnd(pass);
        c.wgpuRenderPassEncoderRelease(pass);
        return size;
    }
};
