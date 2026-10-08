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
const scene_pass = @import("scene_pass.zig");
const SlotTable = @import("slot_table.zig").SlotTable;
const scene_wgsl = @import("teak-shaders").scene_wgsl;
const scene_grid_wgsl = @import("teak-shaders").scene_grid_wgsl;

const c = wgpu_c.c;
const MeshData = teak.MeshData;
const MeshHandle = teak.MeshHandle;
const MeshVertex = teak.MeshVertex;
const LineVertex = teak.LineVertex;
const SceneDraw = teak.SceneDraw;
const TargetSize = common.TargetSize;

pub const MESH_CAPACITY: usize = 128;
/// Depth + stencil: section caps use stencil parity. 24-bit depth is plenty
/// for the line bias (`scene_common.line_depth_bias`).
pub const depth_format = c.WGPUTextureFormat_Depth24PlusStencil8;

const sprite_bg_cache = 32;

/// A cached bind group for one image's texture view (rebuilt if the Gpu
/// replaced the view behind a handle).
const SpriteBg = struct { handle: u32 = 0, view: c.WGPUTextureView = null, bg: c.WGPUBindGroup = null };

/// An image source with nothing in it (scenes without sprites).
pub const NoImages = struct {
    pub fn hasImage(_: NoImages, _: u32) bool {
        return false;
    }
    pub fn viewOf(_: NoImages, _: u32) ?c.WGPUTextureView {
        return null;
    }
};

/// One cap quad to draw: which plan instance, and where its vertices start in `Target.cap_buf`.
const CapDraw = struct { inst: u32, first_vertex: u32 };

/// Scratch for the per-frame plan (item counts are small and unbounded by
/// design; this is backend code outside the framework core).
const plan_allocator = std.heap.page_allocator;

const MeshEntry = struct {
    vertex_buf: c.WGPUBuffer,
    index_buf: c.WGPUBuffer,
    line_buf: c.WGPUBuffer,
    index_count: u32,
    segment_count: u32,
    /// Bumped on every upload so a re-upload into a reused slot is a
    /// different mesh as far as `signature` is concerned.
    version: u32,
    /// CPU copy of positions + indices and the model-space bounds, kept for
    /// section outlines and cap quads (the GPU buffers cannot be read back).
    cpu_pos: []teak.scene.mat.Vec3 = &.{},
    cpu_idx: []u32 = &.{},
    lo: teak.scene.mat.Vec3 = .{ 0, 0, 0 },
    hi: teak.scene.mat.Vec3 = .{ 0, 0, 0 },

    fn release(self: MeshEntry) void {
        plan_allocator.free(self.cpu_pos);
        plan_allocator.free(self.cpu_idx);
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
    /// Packed per-item instance records (`scene_pass.Packed`), grown on demand.
    inst_buf: c.WGPUBuffer = null,
    inst_cap: usize = 0,
    /// Grid pass uniforms (`scene_pass.GridUniform`) + bind group.
    grid_buf: c.WGPUBuffer,
    grid_bg: c.WGPUBindGroup,
    /// Gizmo pass: its own `Globals`, bind group and line-segment vertices.
    gizmo_ubo: c.WGPUBuffer,
    gizmo_bg: c.WGPUBindGroup,
    gizmo_lines: c.WGPUBuffer,
    /// Section cut: cap quads, outline segments (+ their own `Globals`, since
    /// the outline width differs from the edge width).
    cap_buf: c.WGPUBuffer = null,
    cap_cap: usize = 0,
    /// Plane layers: tessellated vertices, plane records, sprite records.
    plane_vbuf: c.WGPUBuffer = null,
    plane_vcap: usize = 0,
    plane_ibuf: c.WGPUBuffer = null,
    plane_icap: usize = 0,
    sprite_buf: c.WGPUBuffer = null,
    sprite_cap: usize = 0,
    outline_buf: c.WGPUBuffer = null,
    outline_cap: usize = 0,
    outline_ubo: c.WGPUBuffer,
    outline_bg: c.WGPUBindGroup,
    signature: u64,
    generation: u32,

    fn release(self: Target) void {
        if (self.inst_buf) |b| c.wgpuBufferRelease(b);
        if (self.plane_vbuf) |b| c.wgpuBufferRelease(b);
        if (self.plane_ibuf) |b| c.wgpuBufferRelease(b);
        if (self.sprite_buf) |b| c.wgpuBufferRelease(b);
        if (self.cap_buf) |b| c.wgpuBufferRelease(b);
        if (self.outline_buf) |b| c.wgpuBufferRelease(b);
        c.wgpuBindGroupRelease(self.outline_bg);
        c.wgpuBufferRelease(self.outline_ubo);
        c.wgpuBufferRelease(self.gizmo_lines);
        c.wgpuBindGroupRelease(self.gizmo_bg);
        c.wgpuBufferRelease(self.gizmo_ubo);
        c.wgpuBindGroupRelease(self.grid_bg);
        c.wgpuBufferRelease(self.grid_buf);
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
    /// Line pipeline that ignores the depth buffer, for the gizmo overlay.
    gizmo_pipeline: c.WGPURenderPipeline,
    grid_bgl: c.WGPUBindGroupLayout,
    grid_pipeline: c.WGPURenderPipeline,
    /// One identity `Packed` record bound at stride 0 for gizmo lines.
    ident_buf: c.WGPUBuffer,
    /// Section cap: stencil-parity pre-pass (colour writes off) + the cap quad.
    stencil_pipeline: c.WGPURenderPipeline,
    cap_pipeline: c.WGPURenderPipeline,
    /// Scratch for per-frame cut geometry (cap quads, outline segments).
    layers: scene_pass.Layers = .{},
    plane_opaque_pipeline: c.WGPURenderPipeline,
    plane_blend_pipeline: c.WGPURenderPipeline,
    sprite_pipeline: c.WGPURenderPipeline,
    sprite_bgl: c.WGPUBindGroupLayout,
    sprite_sampler: c.WGPUSampler,
    sprite_bgs: [sprite_bg_cache]SpriteBg = @splat(.{}),
    next_sprite_bg: usize = 0,
    cap_quads: std.ArrayList(CapDraw) = .empty,
    cap_verts: std.ArrayList(LineVertex) = .empty,
    outline_segs: std.ArrayList(teak.scene.section.Segment) = .empty,
    outline_verts: std.ArrayList(LineVertex) = .empty,

    meshes: SlotTable(MeshEntry, MESH_CAPACITY) = .{},
    next_version: u32 = 1,
    plan: scene_pass.Plan = .{},
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
        // Per-item instance stream (`scene_pass.Packed`): drawn per instance for
        // triangles; bound with stride 0 for lines so every segment of one
        // item reads the same record.
        const inst_attrs = [_]c.WGPUVertexAttribute{
            .{ .format = c.WGPUVertexFormat_Float32x4, .offset = 0, .shaderLocation = 4 },
            .{ .format = c.WGPUVertexFormat_Float32x4, .offset = 16, .shaderLocation = 5 },
            .{ .format = c.WGPUVertexFormat_Float32x4, .offset = 32, .shaderLocation = 6 },
            .{ .format = c.WGPUVertexFormat_Float32x4, .offset = 48, .shaderLocation = 7 },
            .{ .format = c.WGPUVertexFormat_Uint32x2, .offset = 64, .shaderLocation = 8 },
        };
        const mesh_inst_layout = [_]c.WGPUVertexBufferLayout{ mesh_layout[0], .{
            .arrayStride = @sizeOf(scene_pass.Packed),
            .stepMode = c.WGPUVertexStepMode_Instance,
            .attributeCount = inst_attrs.len,
            .attributes = &inst_attrs,
        } };
        // One instance = one segment = a pair of LineVertex.
        const seg_stride = 2 * @sizeOf(LineVertex);
        const line_attrs = [_]c.WGPUVertexAttribute{
            .{ .format = c.WGPUVertexFormat_Float32x3, .offset = @offsetOf(LineVertex, "pos"), .shaderLocation = 0 },
            .{ .format = c.WGPUVertexFormat_Float32x4, .offset = @offsetOf(LineVertex, "color"), .shaderLocation = 1 },
            .{ .format = c.WGPUVertexFormat_Float32x3, .offset = @sizeOf(LineVertex) + @offsetOf(LineVertex, "pos"), .shaderLocation = 2 },
            .{ .format = c.WGPUVertexFormat_Float32x4, .offset = @sizeOf(LineVertex) + @offsetOf(LineVertex, "color"), .shaderLocation = 3 },
        };
        const line_xf_attrs = inst_attrs[0..3];
        const line_layout = [_]c.WGPUVertexBufferLayout{ .{
            .arrayStride = seg_stride,
            .stepMode = c.WGPUVertexStepMode_Instance,
            .attributeCount = line_attrs.len,
            .attributes = &line_attrs,
        }, .{
            .arrayStride = 0,
            .stepMode = c.WGPUVertexStepMode_Instance,
            .attributeCount = line_xf_attrs.len,
            .attributes = line_xf_attrs.ptr,
        } };

        const mesh_pipeline = wgpu_c.createPipeline(device, .{
            .label = "scene-mesh-pipeline",
            .layout = layout,
            .module = shader,
            .vs_entry = "vs_mesh",
            .fs_entry = "fs_mesh",
            .vertex_buffers = &mesh_inst_layout,
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

        const gizmo_pipeline = wgpu_c.createPipeline(device, .{
            .label = "scene-gizmo-pipeline",
            .layout = layout,
            .module = shader,
            .vs_entry = "vs_line",
            .fs_entry = "fs_line",
            .vertex_buffers = &line_layout,
            .format = format,
            .depth = wgpu_c.depthState(depth_format, false, c.WGPUCompareFunction_Always),
            .samples = samples,
        }) orelse return error.PipelineCreateFailed;

        // Grid: fullscreen triangle, its own uniform block.
        const grid_shader = try wgpu_c.createShader(device, "scene-grid-shader", scene_grid_wgsl);
        defer c.wgpuShaderModuleRelease(grid_shader);
        var grid_entry = std.mem.zeroes(c.WGPUBindGroupLayoutEntry);
        grid_entry.binding = 0;
        grid_entry.visibility = c.WGPUShaderStage_Vertex | c.WGPUShaderStage_Fragment;
        grid_entry.buffer.type = c.WGPUBufferBindingType_Uniform;
        grid_entry.buffer.minBindingSize = @sizeOf(scene_pass.GridUniform);
        var grid_bgl_desc = std.mem.zeroes(c.WGPUBindGroupLayoutDescriptor);
        grid_bgl_desc.label = wgpu_c.wgpuStr("scene-grid-bgl");
        grid_bgl_desc.entryCount = 1;
        grid_bgl_desc.entries = &grid_entry;
        const grid_bgl = c.wgpuDeviceCreateBindGroupLayout(device, &grid_bgl_desc) orelse return error.BglCreateFailed;
        var grid_pl_desc = std.mem.zeroes(c.WGPUPipelineLayoutDescriptor);
        grid_pl_desc.label = wgpu_c.wgpuStr("scene-grid-pipeline-layout");
        grid_pl_desc.bindGroupLayoutCount = 1;
        grid_pl_desc.bindGroupLayouts = &grid_bgl;
        const grid_layout = c.wgpuDeviceCreatePipelineLayout(device, &grid_pl_desc) orelse return error.PipelineLayoutFailed;
        defer c.wgpuPipelineLayoutRelease(grid_layout);
        const grid_pipeline = wgpu_c.createPipeline(device, .{
            .label = "scene-grid-pipeline",
            .layout = grid_layout,
            .module = grid_shader,
            .vs_entry = "vs_grid",
            .fs_entry = "fs_grid",
            .vertex_buffers = &.{},
            .format = format,
            .depth = wgpu_c.depthState(depth_format, false, c.WGPUCompareFunction_LessEqual),
            .samples = samples,
        }) orelse return error.PipelineCreateFailed;

        // Cap pipelines: both draw into the same depth+stencil attachment.
        var stencil_ds = wgpu_c.depthState(depth_format, false, c.WGPUCompareFunction_Always);
        stencil_ds.stencilFront = .{ .compare = c.WGPUCompareFunction_Always, .failOp = c.WGPUStencilOperation_Keep, .depthFailOp = c.WGPUStencilOperation_Keep, .passOp = c.WGPUStencilOperation_Invert };
        stencil_ds.stencilBack = stencil_ds.stencilFront;
        stencil_ds.stencilReadMask = 0xFFFFFFFF;
        stencil_ds.stencilWriteMask = 0xFFFFFFFF;
        const stencil_pipeline = wgpu_c.createPipeline(device, .{
            .label = "scene-stencil-pipeline",
            .layout = layout,
            .module = shader,
            .vs_entry = "vs_mesh",
            .fs_entry = "fs_stencil",
            .vertex_buffers = &mesh_inst_layout,
            .format = format,
            .blend = null,
            .write_mask = c.WGPUColorWriteMask_None,
            .depth = stencil_ds,
            .samples = samples,
        }) orelse return error.PipelineCreateFailed;
        var cap_ds = wgpu_c.depthState(depth_format, true, c.WGPUCompareFunction_LessEqual);
        cap_ds.stencilFront = .{ .compare = c.WGPUCompareFunction_NotEqual, .failOp = c.WGPUStencilOperation_Keep, .depthFailOp = c.WGPUStencilOperation_Zero, .passOp = c.WGPUStencilOperation_Zero };
        cap_ds.stencilBack = cap_ds.stencilFront;
        cap_ds.stencilReadMask = 0xFFFFFFFF;
        cap_ds.stencilWriteMask = 0xFFFFFFFF;
        // A cap vertex is a position and a colour: the `LineVertex` layout.
        const cap_attrs = [_]c.WGPUVertexAttribute{
            .{ .format = c.WGPUVertexFormat_Float32x3, .offset = @offsetOf(LineVertex, "pos"), .shaderLocation = 0 },
            .{ .format = c.WGPUVertexFormat_Float32x4, .offset = @offsetOf(LineVertex, "color"), .shaderLocation = 1 },
        };
        const cap_layout = [_]c.WGPUVertexBufferLayout{.{
            .arrayStride = @sizeOf(LineVertex),
            .stepMode = c.WGPUVertexStepMode_Vertex,
            .attributeCount = cap_attrs.len,
            .attributes = &cap_attrs,
        }};
        const cap_pipeline = wgpu_c.createPipeline(device, .{
            .label = "scene-cap-pipeline",
            .layout = layout,
            .module = shader,
            .vs_entry = "vs_cap",
            .fs_entry = "fs_cap",
            .vertex_buffers = &cap_layout,
            .format = format,
            .blend = null,
            .depth = cap_ds,
            .samples = samples,
        }) orelse return error.PipelineCreateFailed;

        // Plane layers and sprites.
        const layer_inst_attrs = [_]c.WGPUVertexAttribute{
            .{ .format = c.WGPUVertexFormat_Float32x4, .offset = 0, .shaderLocation = 4 },
            .{ .format = c.WGPUVertexFormat_Float32x4, .offset = 16, .shaderLocation = 5 },
            .{ .format = c.WGPUVertexFormat_Float32x4, .offset = 32, .shaderLocation = 6 },
            .{ .format = c.WGPUVertexFormat_Float32x4, .offset = 48, .shaderLocation = 7 },
            .{ .format = c.WGPUVertexFormat_Uint32x2, .offset = 64, .shaderLocation = 8 },
            .{ .format = c.WGPUVertexFormat_Sint32, .offset = 72, .shaderLocation = 9 },
        };
        const plane_vert_attrs = [_]c.WGPUVertexAttribute{
            .{ .format = c.WGPUVertexFormat_Float32x2, .offset = @offsetOf(teak.Vertex, "x"), .shaderLocation = 0 },
            .{ .format = c.WGPUVertexFormat_Float32x4, .offset = @offsetOf(teak.Vertex, "r"), .shaderLocation = 1 },
        };
        const plane_layout = [_]c.WGPUVertexBufferLayout{ .{
            .arrayStride = @sizeOf(teak.Vertex),
            .stepMode = c.WGPUVertexStepMode_Vertex,
            .attributeCount = plane_vert_attrs.len,
            .attributes = &plane_vert_attrs,
        }, .{
            .arrayStride = @sizeOf(scene_pass.LayerInst),
            .stepMode = c.WGPUVertexStepMode_Instance,
            .attributeCount = layer_inst_attrs.len,
            .attributes = &layer_inst_attrs,
        } };
        const plane_opaque_pipeline = wgpu_c.createPipeline(device, .{
            .label = "scene-plane-opaque",
            .layout = layout,
            .module = shader,
            .vs_entry = "vs_plane",
            .fs_entry = "fs_plane",
            .vertex_buffers = &plane_layout,
            .format = format,
            .depth = wgpu_c.depthState(depth_format, true, c.WGPUCompareFunction_LessEqual),
            .samples = samples,
        }) orelse return error.PipelineCreateFailed;
        const plane_blend_pipeline = wgpu_c.createPipeline(device, .{
            .label = "scene-plane-blend",
            .layout = layout,
            .module = shader,
            .vs_entry = "vs_plane",
            .fs_entry = "fs_plane",
            .vertex_buffers = &plane_layout,
            .format = format,
            .depth = wgpu_c.depthState(depth_format, false, c.WGPUCompareFunction_LessEqual),
            .samples = samples,
        }) orelse return error.PipelineCreateFailed;

        var sprite_entries = [_]c.WGPUBindGroupLayoutEntry{ std.mem.zeroes(c.WGPUBindGroupLayoutEntry), std.mem.zeroes(c.WGPUBindGroupLayoutEntry) };
        sprite_entries[0].binding = 0;
        sprite_entries[0].visibility = c.WGPUShaderStage_Fragment;
        sprite_entries[0].texture.sampleType = c.WGPUTextureSampleType_Float;
        sprite_entries[0].texture.viewDimension = c.WGPUTextureViewDimension_2D;
        sprite_entries[1].binding = 1;
        sprite_entries[1].visibility = c.WGPUShaderStage_Fragment;
        sprite_entries[1].sampler.type = c.WGPUSamplerBindingType_Filtering;
        var sprite_bgl_desc = std.mem.zeroes(c.WGPUBindGroupLayoutDescriptor);
        sprite_bgl_desc.label = wgpu_c.wgpuStr("scene-sprite-bgl");
        sprite_bgl_desc.entryCount = sprite_entries.len;
        sprite_bgl_desc.entries = &sprite_entries;
        const sprite_bgl = c.wgpuDeviceCreateBindGroupLayout(device, &sprite_bgl_desc) orelse return error.BglCreateFailed;
        const sprite_bgls = [_]c.WGPUBindGroupLayout{ bgl, sprite_bgl };
        var sprite_pl_desc = std.mem.zeroes(c.WGPUPipelineLayoutDescriptor);
        sprite_pl_desc.label = wgpu_c.wgpuStr("scene-sprite-pipeline-layout");
        sprite_pl_desc.bindGroupLayoutCount = sprite_bgls.len;
        sprite_pl_desc.bindGroupLayouts = &sprite_bgls;
        const sprite_layout = c.wgpuDeviceCreatePipelineLayout(device, &sprite_pl_desc) orelse return error.PipelineLayoutFailed;
        defer c.wgpuPipelineLayoutRelease(sprite_layout);
        const sprite_attrs = [_]c.WGPUVertexAttribute{
            .{ .format = c.WGPUVertexFormat_Float32x4, .offset = 0, .shaderLocation = 0 },
            .{ .format = c.WGPUVertexFormat_Float32x4, .offset = 16, .shaderLocation = 1 },
            .{ .format = c.WGPUVertexFormat_Float32x4, .offset = 32, .shaderLocation = 2 },
            .{ .format = c.WGPUVertexFormat_Float32x4, .offset = 48, .shaderLocation = 3 },
            .{ .format = c.WGPUVertexFormat_Float32x4, .offset = 64, .shaderLocation = 4 },
        };
        const sprite_vlayout = [_]c.WGPUVertexBufferLayout{.{
            .arrayStride = @sizeOf(scene_pass.SpriteInst),
            .stepMode = c.WGPUVertexStepMode_Instance,
            .attributeCount = sprite_attrs.len,
            .attributes = &sprite_attrs,
        }};
        const sprite_pipeline = wgpu_c.createPipeline(device, .{
            .label = "scene-sprite-pipeline",
            .layout = sprite_layout,
            .module = shader,
            .vs_entry = "vs_sprite",
            .fs_entry = "fs_sprite",
            .vertex_buffers = &sprite_vlayout,
            .format = format,
            .depth = wgpu_c.depthState(depth_format, false, c.WGPUCompareFunction_LessEqual),
            .samples = samples,
        }) orelse return error.PipelineCreateFailed;
        var sampler_desc = std.mem.zeroes(c.WGPUSamplerDescriptor);
        sampler_desc.label = wgpu_c.wgpuStr("scene-sprite-sampler");
        sampler_desc.addressModeU = c.WGPUAddressMode_ClampToEdge;
        sampler_desc.addressModeV = c.WGPUAddressMode_ClampToEdge;
        sampler_desc.addressModeW = c.WGPUAddressMode_ClampToEdge;
        sampler_desc.magFilter = c.WGPUFilterMode_Linear;
        sampler_desc.minFilter = c.WGPUFilterMode_Linear;
        sampler_desc.mipmapFilter = c.WGPUMipmapFilterMode_Nearest;
        sampler_desc.lodMaxClamp = 1;
        sampler_desc.maxAnisotropy = 1;
        const sprite_sampler = c.wgpuDeviceCreateSampler(device, &sampler_desc) orelse return error.SamplerFailed;

        const ident_buf = wgpu_c.createBuffer(device, "scene-identity", c.WGPUBufferUsage_Vertex | c.WGPUBufferUsage_CopyDst, @sizeOf(scene_pass.Packed)) orelse return error.GpuResource;
        const ident = scene_pass.pack(.{ .mesh = 1 });
        c.wgpuQueueWriteBuffer(queue, ident_buf, 0, &ident, @sizeOf(scene_pass.Packed));

        return .{
            .device = device,
            .queue = queue,
            .format = format,
            .samples = samples,
            .bgl = bgl,
            .mesh_pipeline = mesh_pipeline,
            .line_pipeline = line_pipeline,
            .gizmo_pipeline = gizmo_pipeline,
            .grid_bgl = grid_bgl,
            .grid_pipeline = grid_pipeline,
            .ident_buf = ident_buf,
            .stencil_pipeline = stencil_pipeline,
            .cap_pipeline = cap_pipeline,
            .plane_opaque_pipeline = plane_opaque_pipeline,
            .plane_blend_pipeline = plane_blend_pipeline,
            .sprite_pipeline = sprite_pipeline,
            .sprite_bgl = sprite_bgl,
            .sprite_sampler = sprite_sampler,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.plan.deinit(plan_allocator);
        var it = self.meshes.iterator();
        while (it.next()) |m| m.release();
        for (self.targets) |t| if (t) |tt| tt.release();
        self.layers.deinit(plan_allocator);
        for (self.sprite_bgs) |e| if (e.bg) |bg| c.wgpuBindGroupRelease(bg);
        c.wgpuSamplerRelease(self.sprite_sampler);
        c.wgpuBindGroupLayoutRelease(self.sprite_bgl);
        c.wgpuRenderPipelineRelease(self.sprite_pipeline);
        c.wgpuRenderPipelineRelease(self.plane_blend_pipeline);
        c.wgpuRenderPipelineRelease(self.plane_opaque_pipeline);
        c.wgpuRenderPipelineRelease(self.cap_pipeline);
        c.wgpuRenderPipelineRelease(self.stencil_pipeline);
        self.cap_quads.deinit(plan_allocator);
        self.cap_verts.deinit(plan_allocator);
        self.outline_segs.deinit(plan_allocator);
        self.outline_verts.deinit(plan_allocator);
        c.wgpuBufferRelease(self.ident_buf);
        c.wgpuRenderPipelineRelease(self.grid_pipeline);
        c.wgpuBindGroupLayoutRelease(self.grid_bgl);
        c.wgpuRenderPipelineRelease(self.gizmo_pipeline);
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
            const pos = plan_allocator.alloc(teak.scene.mat.Vec3, data.vertices.len) catch return false;
            entry.cpu_pos = pos; // freed by `release` even if a later step fails
            entry.cpu_idx = plan_allocator.dupe(u32, data.indices) catch return false;
            var lo: teak.scene.mat.Vec3 = @splat(std.math.inf(f32));
            var hi: teak.scene.mat.Vec3 = @splat(-std.math.inf(f32));
            for (data.vertices, pos) |v, *p| {
                p.* = v.pos;
                lo = teak.scene.mat.minV(lo, v.pos);
                hi = teak.scene.mat.maxV(hi, v.pos);
            }
            entry.lo = lo;
            entry.hi = hi;
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

    pub fn meshVersion(self: *Renderer, handle: MeshHandle) u32 {
        return if (self.meshes.get(handle)) |m| m.version else 0;
    }

    pub fn hasMesh(self: *Renderer, handle: MeshHandle) bool {
        return self.meshes.get(handle) != null;
    }

    const CutGeo = struct { outline_verts: u32 = 0 };

    /// Bind group for sampling image `handle`'s texture view (cached per handle;
    /// rebuilt when the Gpu hands out a different view for it).
    fn spriteBindGroup(self: *Renderer, handle: u32, view: c.WGPUTextureView) c.WGPUBindGroup {
        for (&self.sprite_bgs) |*e| {
            if (e.handle == handle and e.bg != null) {
                if (e.view == view) return e.bg;
                c.wgpuBindGroupRelease(e.bg);
                e.* = .{};
                break;
            }
        }
        var entries = [_]c.WGPUBindGroupEntry{ std.mem.zeroes(c.WGPUBindGroupEntry), std.mem.zeroes(c.WGPUBindGroupEntry) };
        entries[0].binding = 0;
        entries[0].textureView = view;
        entries[1].binding = 1;
        entries[1].sampler = self.sprite_sampler;
        var desc = std.mem.zeroes(c.WGPUBindGroupDescriptor);
        desc.label = wgpu_c.wgpuStr("scene-sprite-bg");
        desc.layout = self.sprite_bgl;
        desc.entryCount = entries.len;
        desc.entries = &entries;
        const bg = c.wgpuDeviceCreateBindGroup(self.device, &desc);
        const slot = for (self.sprite_bgs, 0..) |e, i| {
            if (e.bg == null) break i;
        } else blk: {
            const i = self.next_sprite_bg % sprite_bg_cache;
            self.next_sprite_bg += 1;
            if (self.sprite_bgs[i].bg) |old| c.wgpuBindGroupRelease(old);
            break :blk i;
        };
        self.sprite_bgs[slot] = .{ .handle = handle, .view = view, .bg = bg };
        return bg;
    }

    /// Plane layers and sprites: opaque planes first (depth written), then the
    /// blended planes and sprites back to front (depth tested, not written).
    fn drawLayers(self: *Renderer, pass: c.WGPURenderPassEncoder, t: *Target, draw: SceneDraw, images: anytype) void {
        _ = draw;
        const ly = &self.layers;
        if (ly.isEmpty()) return;
        const vbytes = ly.plane_verts.items.len * @sizeOf(teak.Vertex);
        const ibytes = ly.plane_insts.items.len * @sizeOf(scene_pass.LayerInst);
        const sbytes = ly.sprites.items.len * @sizeOf(scene_pass.SpriteInst);
        if (vbytes > 0 and self.growBuffer(&t.plane_vbuf, &t.plane_vcap, "scene-plane-verts", vbytes) and
            self.growBuffer(&t.plane_ibuf, &t.plane_icap, "scene-plane-insts", ibytes))
        {
            c.wgpuQueueWriteBuffer(self.queue, t.plane_vbuf, 0, ly.plane_verts.items.ptr, vbytes);
            c.wgpuQueueWriteBuffer(self.queue, t.plane_ibuf, 0, ly.plane_insts.items.ptr, ibytes);
        }
        if (sbytes > 0 and self.growBuffer(&t.sprite_buf, &t.sprite_cap, "scene-sprites", sbytes)) {
            c.wgpuQueueWriteBuffer(self.queue, t.sprite_buf, 0, ly.sprites.items.ptr, sbytes);
        }
        c.wgpuRenderPassEncoderSetBindGroup(pass, 0, t.bind_group, 0, null);
        if (vbytes > 0) {
            c.wgpuRenderPassEncoderSetPipeline(pass, self.plane_opaque_pipeline);
            for (ly.opaque_planes.items) |di| self.drawPlane(pass, t, ly.plane_draws.items[di]);
        }
        var bound_image: u32 = 0;
        var last_kind: ?@TypeOf(ly.blended.items[0].kind) = null;
        for (ly.blended.items) |b| {
            switch (b.kind) {
                .plane => {
                    if (last_kind != .plane) c.wgpuRenderPassEncoderSetPipeline(pass, self.plane_blend_pipeline);
                    self.drawPlane(pass, t, ly.plane_draws.items[b.index]);
                },
                .sprite => {
                    if (last_kind != .sprite) {
                        c.wgpuRenderPassEncoderSetPipeline(pass, self.sprite_pipeline);
                        c.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, t.sprite_buf, 0, sbytes);
                        bound_image = 0;
                    }
                    const handle = ly.sprite_images.items[b.index];
                    if (handle != bound_image) {
                        const view = images.viewOf(handle) orelse continue;
                        c.wgpuRenderPassEncoderSetBindGroup(pass, 1, self.spriteBindGroup(handle, view), 0, null);
                        bound_image = handle;
                    }
                    c.wgpuRenderPassEncoderDraw(pass, 6, 1, 0, b.index);
                },
            }
            last_kind = b.kind;
        }
    }

    fn drawPlane(self: *Renderer, pass: c.WGPURenderPassEncoder, t: *Target, pd: scene_pass.PlaneDraw) void {
        _ = self;
        c.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, t.plane_vbuf, @as(u64, pd.first_vertex) * @sizeOf(teak.Vertex), @as(u64, pd.vertex_count) * @sizeOf(teak.Vertex));
        c.wgpuRenderPassEncoderSetVertexBuffer(pass, 1, t.plane_ibuf, @as(u64, pd.inst) * @sizeOf(scene_pass.LayerInst), @sizeOf(scene_pass.LayerInst));
        c.wgpuRenderPassEncoderDraw(pass, pd.vertex_count, 1, 0, 0);
    }

    /// Backend mesh of plan instance `k` (the run that contains it).
    fn meshOfInstance(self: *Renderer, k: u32) ?MeshEntry {
        for (self.plan.runs.items) |run| {
            if (k >= run.first and k < run.first + run.count) return self.meshes.get(run.mesh).?.*;
        }
        return null;
    }

    fn growBuffer(self: *Renderer, buf: *c.WGPUBuffer, cap: *usize, label: []const u8, bytes: usize) bool {
        if (cap.* >= bytes and buf.* != null) return true;
        if (buf.*) |b| c.wgpuBufferRelease(b);
        const want = @max(std.math.ceilPowerOfTwo(usize, bytes) catch bytes, 4096);
        buf.* = wgpu_c.createBuffer(self.device, label, c.WGPUBufferUsage_Vertex | c.WGPUBufferUsage_CopyDst, want);
        cap.* = if (buf.* != null) want else 0;
        return buf.* != null;
    }

    /// Build and upload the per-frame cut geometry: one cap quad per capped
    /// item (`cap_quads` + `cap_buf`) and the exact outline segments of every
    /// item (`outline_buf`), plus the outline's `Globals`.
    fn prepareCut(self: *Renderer, t: *Target, draw: SceneDraw, cut: teak.scene.Cut, size: TargetSize, scale: f32) CutGeo {
        self.cap_quads.clearRetainingCapacity();
        self.cap_verts.clearRetainingCapacity();
        self.outline_segs.clearRetainingCapacity();
        self.outline_verts.clearRetainingCapacity();
        for (self.plan.runs.items) |run| {
            const m = (self.meshes.get(run.mesh) orelse continue).*;
            for (self.plan.insts.items[run.first..][0..run.count], run.first..) |inst, k| {
                const xf = scene_pass.affineOf(inst);
                if (cut.cap and inst.flags & scene_pass.flag_no_cap == 0 and m.index_count > 0) cap: {
                    const quad = scene_pass.capQuad(cut.plane, m.lo, m.hi, xf) orelse break :cap;
                    const own = self.plan.caps.items[k];
                    const col = if (own[3] > 0) own else cut.cap_color;
                    const first: u32 = @intCast(self.cap_verts.items.len);
                    for ([_]usize{ 0, 1, 2, 0, 2, 3 }) |qi| self.cap_verts.append(plan_allocator, .{ .pos = quad[qi], .color = col }) catch return .{};
                    self.cap_quads.append(plan_allocator, .{ .inst = @intCast(k), .first_vertex = first }) catch return .{};
                }
                if (cut.outline_px > 0 and m.cpu_idx.len > 0) {
                    teak.scene.section.outlinePositions(plan_allocator, m.cpu_pos, m.cpu_idx, xf, cut.plane, &self.outline_segs) catch return .{};
                }
            }
        }
        if (self.cap_verts.items.len > 0 and self.growBuffer(&t.cap_buf, &t.cap_cap, "scene-cap-quads", self.cap_verts.items.len * @sizeOf(LineVertex))) {
            c.wgpuQueueWriteBuffer(self.queue, t.cap_buf, 0, self.cap_verts.items.ptr, self.cap_verts.items.len * @sizeOf(LineVertex));
        } else self.cap_quads.clearRetainingCapacity();

        for (self.outline_segs.items) |sg| {
            self.outline_verts.append(plan_allocator, .{ .pos = sg.a, .color = .{ 1, 1, 1, 1 } }) catch return .{};
            self.outline_verts.append(plan_allocator, .{ .pos = sg.b, .color = .{ 1, 1, 1, 1 } }) catch return .{};
        }
        if (self.outline_verts.items.len == 0) return .{};
        if (!self.growBuffer(&t.outline_buf, &t.outline_cap, "scene-outline", self.outline_verts.items.len * @sizeOf(LineVertex))) return .{};
        c.wgpuQueueWriteBuffer(self.queue, t.outline_buf, 0, self.outline_verts.items.ptr, self.outline_verts.items.len * @sizeOf(LineVertex));
        var og = common.globals(draw, size, scale);
        og.edge_color = cut.outline_color;
        og.viewport[2] = cut.outline_px * scale;
        og.misc[2] = 0; // the outline lies on the plane: never cut it away
        c.wgpuQueueWriteBuffer(self.queue, t.outline_ubo, 0, &og, @sizeOf(common.Globals));
        return .{ .outline_verts = @intCast(self.outline_verts.items.len) };
    }

    /// Make sure `t.inst_buf` holds at least `bytes`; contents are rewritten by the caller.
    fn ensureInstBuf(self: *Renderer, t: *Target, bytes: usize) bool {
        if (t.inst_cap >= bytes) return true;
        if (t.inst_buf) |b| c.wgpuBufferRelease(b);
        const cap = @max(std.math.ceilPowerOfTwo(usize, bytes) catch bytes, 16 * @sizeOf(scene_pass.Packed));
        t.inst_buf = wgpu_c.createBuffer(self.device, "scene-instances", c.WGPUBufferUsage_Vertex | c.WGPUBufferUsage_CopyDst, cap);
        t.inst_cap = if (t.inst_buf != null) cap else 0;
        return t.inst_buf != null;
    }

    // ── Targets ────────────────────────────────────────────────────

    pub fn target(self: *const Renderer, index: usize) ?*const Target {
        return if (self.targets[index]) |*t| t else null;
    }

    fn uniformBindGroup(self: *Renderer, layout: c.WGPUBindGroupLayout, buf: c.WGPUBuffer, size: usize) c.WGPUBindGroup {
        var entry = std.mem.zeroes(c.WGPUBindGroupEntry);
        entry.binding = 0;
        entry.buffer = buf;
        entry.size = size;
        var desc = std.mem.zeroes(c.WGPUBindGroupDescriptor);
        desc.label = wgpu_c.wgpuStr("scene-bg");
        desc.layout = layout;
        desc.entryCount = 1;
        desc.entries = &entry;
        return c.wgpuDeviceCreateBindGroup(self.device, &desc);
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

        const bind_group = self.uniformBindGroup(self.bgl, uniform_buf, @sizeOf(common.Globals)) orelse return error.GpuResource;
        errdefer c.wgpuBindGroupRelease(bind_group);
        const grid_buf = wgpu_c.createBuffer(self.device, "scene-grid-uniforms", c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst, @sizeOf(scene_pass.GridUniform)) orelse return error.GpuResource;
        errdefer c.wgpuBufferRelease(grid_buf);
        const grid_bg = self.uniformBindGroup(self.grid_bgl, grid_buf, @sizeOf(scene_pass.GridUniform)) orelse return error.GpuResource;
        errdefer c.wgpuBindGroupRelease(grid_bg);
        const gizmo_ubo = wgpu_c.createBuffer(self.device, "scene-gizmo-uniforms", c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst, @sizeOf(common.Globals)) orelse return error.GpuResource;
        errdefer c.wgpuBufferRelease(gizmo_ubo);
        const gizmo_bg = self.uniformBindGroup(self.bgl, gizmo_ubo, @sizeOf(common.Globals)) orelse return error.GpuResource;
        errdefer c.wgpuBindGroupRelease(gizmo_bg);
        const outline_ubo = wgpu_c.createBuffer(self.device, "scene-outline-uniforms", c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst, @sizeOf(common.Globals)) orelse return error.GpuResource;
        errdefer c.wgpuBufferRelease(outline_ubo);
        const outline_bg = self.uniformBindGroup(self.bgl, outline_ubo, @sizeOf(common.Globals)) orelse return error.GpuResource;
        errdefer c.wgpuBindGroupRelease(outline_bg);
        const gizmo_lines = wgpu_c.createBuffer(self.device, "scene-gizmo-lines", c.WGPUBufferUsage_Vertex | c.WGPUBufferUsage_CopyDst, scene_pass.gizmo_segments * 2 * @sizeOf(LineVertex)) orelse return error.GpuResource;

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
            .grid_buf = grid_buf,
            .grid_bg = grid_bg,
            .gizmo_ubo = gizmo_ubo,
            .gizmo_bg = gizmo_bg,
            .gizmo_lines = gizmo_lines,
            .outline_ubo = outline_ubo,
            .outline_bg = outline_bg,
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
    pub fn renderInto(self: *Renderer, encoder: c.WGPUCommandEncoder, index: usize, draw: SceneDraw, items: []const teak.SceneItem, sprite_list: []const teak.SceneSprite, images: anytype, scale: f32) ?TargetSize {
        const size = common.targetSize(draw.rect_w, draw.rect_h, scale) orelse return null;
        const t = self.ensureTarget(index, size) orelse return null;

        self.plan.build(plan_allocator, draw, items, self) catch return null;
        self.layers.build(plan_allocator, draw, sprite_list, images) catch return null;
        const sig = common.signature(draw, size, scale, self.plan.contentHash(self) ^ (self.layers.contentHash() *% 0x9E3779B97F4A7C15));
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
        depth.stencilLoadOp = c.WGPULoadOp_Clear;
        depth.stencilStoreOp = c.WGPUStoreOp_Discard;
        depth.stencilClearValue = 0;

        var rp = std.mem.zeroes(c.WGPURenderPassDescriptor);
        rp.label = wgpu_c.wgpuStr("scene-pass");
        rp.colorAttachmentCount = 1;
        rp.colorAttachments = &color;
        rp.depthStencilAttachment = &depth;
        const cut_geo: CutGeo = if (draw.cut) |cut| self.prepareCut(t, draw, cut, size, scale) else .{};
        const pass = c.wgpuCommandEncoderBeginRenderPass(encoder, &rp);

        const inst_bytes = self.plan.insts.items.len * @sizeOf(scene_pass.Packed);
        if (inst_bytes > 0 and self.ensureInstBuf(t, inst_bytes)) {
            c.wgpuQueueWriteBuffer(self.queue, t.inst_buf, 0, self.plan.insts.items.ptr, inst_bytes);
            c.wgpuRenderPassEncoderSetBindGroup(pass, 0, t.bind_group, 0, null);
            // Triangles: one instanced draw per run of items sharing a mesh.
            c.wgpuRenderPassEncoderSetPipeline(pass, self.mesh_pipeline);
            for (self.plan.runs.items) |run| {
                const m = self.meshes.get(run.mesh) orelse continue;
                if (m.index_count == 0) continue;
                c.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, m.vertex_buf, 0, c.WGPU_WHOLE_SIZE);
                c.wgpuRenderPassEncoderSetVertexBuffer(pass, 1, t.inst_buf, 0, inst_bytes);
                c.wgpuRenderPassEncoderSetIndexBuffer(pass, m.index_buf, c.WGPUIndexFormat_Uint32, 0, c.WGPU_WHOLE_SIZE);
                c.wgpuRenderPassEncoderDrawIndexed(pass, m.index_count, run.count, 0, 0, run.first);
            }
            // Section caps: per item, stencil parity then the cap quad (which clears it).
            for (self.cap_quads.items) |cd| {
                const run_mesh = self.meshOfInstance(cd.inst) orelse continue;
                c.wgpuRenderPassEncoderSetPipeline(pass, self.stencil_pipeline);
                c.wgpuRenderPassEncoderSetBindGroup(pass, 0, t.bind_group, 0, null);
                c.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, run_mesh.vertex_buf, 0, c.WGPU_WHOLE_SIZE);
                c.wgpuRenderPassEncoderSetVertexBuffer(pass, 1, t.inst_buf, 0, inst_bytes);
                c.wgpuRenderPassEncoderSetIndexBuffer(pass, run_mesh.index_buf, c.WGPUIndexFormat_Uint32, 0, c.WGPU_WHOLE_SIZE);
                c.wgpuRenderPassEncoderDrawIndexed(pass, run_mesh.index_count, 1, 0, 0, cd.inst);
                c.wgpuRenderPassEncoderSetPipeline(pass, self.cap_pipeline);
                c.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, t.cap_buf, cd.first_vertex * @sizeOf(LineVertex), 6 * @sizeOf(LineVertex));
                c.wgpuRenderPassEncoderDraw(pass, 6, 1, 0, 0);
            }
            // Feature edges: one draw per item (its transform is bound at stride 0).
            c.wgpuRenderPassEncoderSetPipeline(pass, self.line_pipeline);
            for (self.plan.runs.items) |run| {
                const m = self.meshes.get(run.mesh) orelse continue;
                if (m.segment_count == 0) continue;
                c.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, m.line_buf, 0, c.WGPU_WHOLE_SIZE);
                for (self.plan.insts.items[run.first..][0..run.count], run.first..) |inst, k| {
                    if (inst.flags & scene_pass.flag_no_edges != 0) continue;
                    c.wgpuRenderPassEncoderSetVertexBuffer(pass, 1, t.inst_buf, k * @sizeOf(scene_pass.Packed), @sizeOf(scene_pass.Packed));
                    c.wgpuRenderPassEncoderDraw(pass, 6, m.segment_count, 0, 0);
                }
            }
        }

        self.drawLayers(pass, t, draw, images);

        // Cut outline: exact plane x mesh segments, in their own pass-wide line style.
        if (cut_geo.outline_verts > 0) {
            c.wgpuRenderPassEncoderSetPipeline(pass, self.line_pipeline);
            c.wgpuRenderPassEncoderSetBindGroup(pass, 0, t.outline_bg, 0, null);
            c.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, t.outline_buf, 0, cut_geo.outline_verts * @sizeOf(LineVertex));
            c.wgpuRenderPassEncoderSetVertexBuffer(pass, 1, self.ident_buf, 0, @sizeOf(scene_pass.Packed));
            c.wgpuRenderPassEncoderDraw(pass, 6, cut_geo.outline_verts / 2, 0, 0);
        }

        // Grid: depth-tested against everything drawn above, blended over it.
        if (draw.grid) |grid| if (scene_pass.gridUniform(draw, grid, size.w, size.h, scale)) |gu| {
            c.wgpuQueueWriteBuffer(self.queue, t.grid_buf, 0, &gu, @sizeOf(scene_pass.GridUniform));
            c.wgpuRenderPassEncoderSetPipeline(pass, self.grid_pipeline);
            c.wgpuRenderPassEncoderSetBindGroup(pass, 0, t.grid_bg, 0, null);
            c.wgpuRenderPassEncoderDraw(pass, 3, 1, 0, 0);
        };

        // Gizmo: axis triad in a corner sub-viewport, always on top.
        if (draw.gizmo) |gz| {
            const r = scene_pass.gizmoRect(gz, size.w, size.h, scale);
            const lines = scene_pass.gizmoLines(draw.camera.view_proj, gz);
            c.wgpuQueueWriteBuffer(self.queue, t.gizmo_lines, 0, &lines, @sizeOf(@TypeOf(lines)));
            var gg = common.globals(draw, .{ .w = @intFromFloat(r[2]), .h = @intFromFloat(r[3]) }, scale);
            gg.view_proj = scene_pass.gizmoProjection();
            gg.edge_color = .{ 1, 1, 1, 1 };
            gg.viewport[2] = 2 * scale;
            gg.viewport[3] = 0;
            gg.clip = .{ 0, 0, 0, 0 };
            gg.misc = .{ 0, 0, 0, 0 };
            c.wgpuQueueWriteBuffer(self.queue, t.gizmo_ubo, 0, &gg, @sizeOf(common.Globals));
            c.wgpuRenderPassEncoderSetViewport(pass, r[0], r[1], r[2], r[3], 0, 1);
            c.wgpuRenderPassEncoderSetScissorRect(pass, @intFromFloat(r[0]), @intFromFloat(r[1]), @intFromFloat(r[2]), @intFromFloat(r[3]));
            c.wgpuRenderPassEncoderSetPipeline(pass, self.gizmo_pipeline);
            c.wgpuRenderPassEncoderSetBindGroup(pass, 0, t.gizmo_bg, 0, null);
            c.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, t.gizmo_lines, 0, c.WGPU_WHOLE_SIZE);
            c.wgpuRenderPassEncoderSetVertexBuffer(pass, 1, self.ident_buf, 0, @sizeOf(scene_pass.Packed));
            c.wgpuRenderPassEncoderDraw(pass, 6, scene_pass.gizmo_segments, 0, 0);
        }

        c.wgpuRenderPassEncoderEnd(pass);
        c.wgpuRenderPassEncoderRelease(pass);
        return size;
    }
};
