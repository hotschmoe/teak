//! Shared wgpu-native GPU core, parameterized over a *surface provider*
//! and a *glyph rasterizer* so Windows and Linux reuse one wgpu pipeline
//! and differ only at two seams:
//!
//!   * `Surface` — supplies `Handle` + `createSurface` (HWND on Windows,
//!     Xlib `Window` on Linux). See `surface_win32.zig` / `surface_xlib.zig`.
//!   * `Rasterizer` — supplies `init`/`deinit`/`rasterize` producing a
//!     `Bitmap` (GDI on Windows, stb_truetype on Linux). See
//!     `raster_gdi.zig` / `raster_stbtt.zig`.
//!
//! The OS-specific stitch files (`native.zig`, `native_linux.zig`) bind a
//! concrete `Gpu = Gpu(SurfaceProvider, RasterizerType)` and run
//! `validateGpu` on the result. This file imports neither — keeping each
//! OS's `extern`s out of the other's translation unit (no comptime
//! gating), the idiom `text_stage.TextStage(Raster)` shares with the web backend.
//!
//! Frame structure (see `docs/features/gpu.md`):
//!   1. `uploadVertices` / `uploadText` / `uploadImages` stage the UI draws.
//!   2. `renderScenes` (optional) renders each 3D scene into an offscreen
//!      target (`wgpu_scene.Renderer`) and stages a composite quad per scene.
//!   3. `renderFrame` / `renderToWindow` runs the main pass: solids, images,
//!      scene composites, text — optionally 4x multisampled.
//!
//! `pub const c` is the single translate-c module (`wgpu-c`) of the wgpu headers (it lives in
//! `wgpu_c.zig`); the provider files re-import it
//! (`@import("wgpu_core.zig").c`) so the `WGPUSurface`/`WGPUInstance`
//! types have one identity across the seam.

const std = @import("std");
const teak = @import("teak");
const glyph_atlas = @import("glyph_atlas.zig");
const text_stage = @import("text_stage.zig");
const wgpu_c = @import("wgpu_c.zig");
const wgpu_scene = @import("wgpu_scene.zig");
const scene_common = @import("scene_common.zig");
const SlotTable = @import("slot_table.zig").SlotTable;
const GrowSlotTable = @import("slot_table.zig").GrowSlotTable;
const overlay = @import("overlay.zig");

const Vertex = teak.Vertex;
const ImageDraw = teak.ImageDraw;
const OverlaySplit = teak.OverlaySplit;

pub const c = wgpu_c.c;
pub const wgpuStr = wgpu_c.wgpuStr;

pub const ClearColor = teak.ClearColor;
pub const TextureHandle = teak.TextureHandle;
pub const FontSpec = teak.FontSpec;
pub const FontFamily = teak.FontFamily;
pub const TextDraw = teak.TextDraw;
pub const InitOptions = teak.gpu.InitOptions;

/// Allocator for the growable image tables.
const image_gpa = std.heap.page_allocator;
/// Ceiling on live app images (handles are `u32`; this bounds a runaway app).
const IMAGE_MAX_SLOTS: u32 = 1 << 16;
const SCENE_VERT_BUF_CAPACITY: usize = scene_common.max_scenes * 6;

/// Atlas page edge in texels (R8, one byte per texel).
const atlas_dim: u32 = glyph_atlas.page_size;

/// One atlas page on the GPU: the texture and its bind group. The CPU copy
/// lives in the `TextStage`.
const AtlasPage = struct {
    texture: c.WGPUTexture,
    view: c.WGPUTextureView,
    bind_group: c.WGPUBindGroup,
};

/// A draw of one textured quad (6 vertices at `vert_offset`) with its own
/// bind group — shared by the text, image and scene-composite lists.
const QuadDraw = struct {
    bind_group: c.WGPUBindGroup,
    vert_offset: u32, // in vertices, not bytes
};

/// A sampled texture plus the bind group the text/image/scene pipelines
/// use to read it.
const Sampled = struct {
    texture: c.WGPUTexture,
    view: c.WGPUTextureView,
    bind_group: c.WGPUBindGroup,

    fn release(self: Sampled) void {
        c.wgpuBindGroupRelease(self.bind_group);
        c.wgpuTextureViewRelease(self.view);
        c.wgpuTextureRelease(self.texture);
    }
};

// ── Image cache (app-driven, growable, no eviction) ───────────────────────────────
//
// Unlike the glyph cache, the app explicitly creates image textures via
// `uploadImage` and frees them with `releaseImage`. The returned handle
// is a slot index (+1 so 0 is the sentinel).

const ImageCache = GrowSlotTable(Sampled, IMAGE_MAX_SLOTS);

const SHADER_CODE = @import("teak-shaders").quad_wgsl;
const SHADER_GLYPH = @import("teak-shaders").glyph_wgsl;
const SHADER_IMAGE = @import("teak-shaders").image_wgsl;

// ── Gpu ────────────────────────────────────────────────────────────

/// Mirror of `platform/win32.zig`'s MAX_SECONDARY_WINDOWS. We keep them
/// in lock-step so the same id space covers both layers; the GPU side
/// doesn't actually import the platform module (HARDLINE §4(c) — GPU
/// receives opaque hinstance/hwnd pointers, never platform types).
pub const MAX_SECONDARY_SURFACES: usize = 4;

const SurfaceSlot = struct {
    surface: c.WGPUSurface,
    width: u32,
    height: u32,
    active: bool,
};

/// Build a concrete GPU backend from a surface provider + rasterizer.
/// `Surface` must expose `Handle` and `createSurface(WGPUInstance,
/// Handle) !WGPUSurface`; `Rasterizer` must expose `init(Allocator)
/// !Self`, `deinit`, and `rasterize(bytes, FontSpec, [4]f32, w, h)
/// ?Bitmap`. The returned struct satisfies `teak.validateGpu`.
pub fn Gpu(comptime Surface: type, comptime Rasterizer: type) type {
    return struct {
        const Self = @This();

        instance: c.WGPUInstance,
        surface: c.WGPUSurface,
        adapter: c.WGPUAdapter,
        device: c.WGPUDevice,
        queue: c.WGPUQueue,
        pipeline: c.WGPURenderPipeline,
        /// Built lazily for the current `vert_buf` (it is also bound as storage).
        bind_group: c.WGPUBindGroup,
        bind_group_buf: c.WGPUBuffer,
        /// `vert_buf_size` the bind group was built for. A reallocation always
        /// changes it, which the handle alone cannot show: a released buffer's
        /// handle can come back for the new one, leaving a bind group on the
        /// stale buffer (SDF records read as garbage).
        bind_group_size: u64,
        solid_bgl: c.WGPUBindGroupLayout,
        uniform_buf: c.WGPUBuffer,
        vert_buf: c.WGPUBuffer,
        vert_buf_size: u64,
        vert_count: u32,
        surf_format: c.WGPUTextureFormat,

        /// Samples per pixel of the main pass: 1, or 4 with
        /// `InitOptions.msaa`. Every main-pass pipeline is built for it.
        samples: u32,
        msaa_tex: c.WGPUTexture,
        msaa_view: c.WGPUTextureView,
        msaa_w: u32,
        msaa_h: u32,

        /// Primary surface dimensions, updated by `resize`. Mirrored into
        /// `uniform_buf` on every `renderToWindow(0, ...)` call so the
        /// shader's screen_size matches what's on screen after a secondary
        /// render rewrites the same uniform with its own dims.
        width: u32,
        height: u32,

        // ── Text pass (instanced glyph quads from the atlas) ───────
        glyph_pipeline: c.WGPURenderPipeline,
        glyph_bgl: c.WGPUBindGroupLayout,
        /// {logical size, scale, text gamma}; see shaders/glyph.wgsl.
        glyph_uniform_buf: c.WGPUBuffer,
        /// Bind group layout + sampler shared by the image/scene pipelines.
        text_bgl: c.WGPUBindGroupLayout,
        sampler: c.WGPUSampler,
        text: text_stage.TextStage(Rasterizer),
        atlas_pages: std.ArrayList(AtlasPage),
        glyph_buf: c.WGPUBuffer,
        glyph_buf_size: u64,
        /// Device pixels per logical pixel (`InitOptions.scale`).
        scale: f32,

        // ── Image pass (shares text_bgl + sampler) ─────────────────
        image_pipeline: c.WGPURenderPipeline,
        images: ImageCache,
        image_draws: std.ArrayList(QuadDraw),
        image_verts: std.ArrayList(Vertex),
        image_vert_buf: c.WGPUBuffer,
        image_vert_buf_size: u64,

        // ── 3D scenes ──────────────────────────────────────────────
        //
        // `scene` renders into offscreen targets; the main pass draws each
        // target as an image-pipeline quad (`scene_draws`). Composite bind
        // groups are cached per slot and rebuilt when the slot's target
        // is recreated (`scene_bg_gen` != target.generation).
        scene: wgpu_scene.Renderer,
        scene_bind_groups: [scene_common.max_scenes]c.WGPUBindGroup,
        scene_bg_gen: [scene_common.max_scenes]u32,
        scene_draws: [scene_common.max_scenes]QuadDraw,
        scene_draw_count: usize,
        scene_verts: [SCENE_VERT_BUF_CAPACITY]Vertex,
        scene_vert_count: u32,
        scene_vert_buf: c.WGPUBuffer,
        scene_vert_buf_size: u64,

        /// Headless mode (`initOffscreen`): the colour target `renderFrame`
        /// presents to, read back by `readFrame`. null for windowed Gpus.
        offscreen: c.WGPUTexture,

        // ── Overlay layering ───────────────────────────────────────
        //
        // `setOverlayStart` records where the overlay layer begins in each
        // input list; the upload loops translate that into staged-record
        // indices (`*_ov`) so the main pass can draw base content first and
        // overlay content after it. null = no split (draw by kind).
        overlay_split: ?OverlaySplit,
        image_ov: usize,
        scene_ov: usize,

        // ── Secondary surfaces ─────────────────────────────────────
        //
        // The primary `surface` field above stays untouched — single-window
        // apps see no behavior change. Each entry below is an opaque wgpu
        // surface configured against an additional native window provided
        // by the Host layer; the device, queue, pipelines, and caches are
        // all shared. `renderToWindow(id)` picks the right surface;
        // `uniform_buf` is rewritten per call so the shader sees that
        // window's size.
        secondary_surfaces: [MAX_SECONDARY_SURFACES]SurfaceSlot,

        /// `handle` duck-types as the surface provider's `Handle` (an
        /// HWND pair on Windows, Display+Window on Linux) — it is taken as
        /// `anytype` so the Host's `NativeHandle` (a structurally
        /// identical but nominally distinct struct) coerces without the
        /// platform layer having to import the gpu layer's `Handle` type.
        /// The provider's `createSurface` turns it into a `WGPUSurface`;
        /// everything past that is platform-agnostic.
        pub fn init(handle: anytype, width: u32, height: u32) !Self {
            return initWithOptions(handle, width, height, .{});
        }

        pub fn initWithOptions(handle: anytype, width: u32, height: u32, options: InitOptions) !Self {
            var instance_desc = std.mem.zeroes(c.WGPUInstanceDescriptor);
            const instance = c.wgpuCreateInstance(&instance_desc) orelse return error.InstanceCreateFailed;
            const surface = try Surface.createSurface(instance, handle);
            const ctx = try wgpu_c.requestDevice(instance, surface);
            return initFromDevice(instance, surface, ctx, width, height, options);
        }

        /// A surface-less Gpu for headless runs (agents, CI screenshots): a
        /// device on the best Vulkan / Metal / D3D12 adapter and an
        /// offscreen colour target of the surface format and the same MSAA
        /// path as the windowed Gpu. `renderFrame` draws into that target
        /// ("presents" to it) and `readFrame` reads it back. Needs a GPU
        /// driver (software Vulkan works where wgpu supports it) but no
        /// window system.
        pub fn initOffscreen(width: u32, height: u32, options: InitOptions) !Self {
            const instance = wgpu_c.createInstance(c.WGPUInstanceBackend_Primary) orelse return error.InstanceCreateFailed;
            const ctx = try wgpu_c.requestDevice(instance, null);
            var gpu = try initFromDevice(instance, null, ctx, width, height, options);
            errdefer gpu.deinit();
            try gpu.recreateOffscreen(gpu.width, gpu.height);
            return gpu;
        }

        fn recreateOffscreen(self: *Self, width: u32, height: u32) error{GpuResource}!void {
            if (self.offscreen) |t| c.wgpuTextureRelease(t);
            self.offscreen = null;
            self.offscreen = wgpu_c.createTexture2D(self.device, "offscreen-frame", .{
                .width = @max(width, 1),
                .height = @max(height, 1),
                .format = self.surf_format,
                .usage = c.WGPUTextureUsage_RenderAttachment | c.WGPUTextureUsage_CopySrc,
            }) orelse return error.GpuResource;
        }

        /// The last frame `renderFrame` drew into the offscreen target
        /// (`initOffscreen`), as tightly packed RGBA8 rows `width * height * 4`
        /// bytes; the caller frees. Blocks until the GPU is done.
        pub fn readFrame(self: *Self, allocator: std.mem.Allocator) ![]u8 {
            const tex = self.offscreen orelse return error.NotOffscreen;
            const ctx: wgpu_c.DeviceContext = .{ .adapter = self.adapter, .device = self.device, .queue = self.queue };
            const px = try wgpu_c.readTexture(allocator, ctx, tex, @max(self.width, 1), @max(self.height, 1), 4);
            // The target is BGRA8; PNG and most consumers want RGBA.
            var i: usize = 0;
            while (i + 3 < px.len) : (i += 4) std.mem.swap(u8, &px[i], &px[i + 2]);
            return px;
        }

        /// Build the Gpu on an already opened device. Takes ownership of
        /// `instance`, `surface` and `ctx` (released by `deinit`). `surface`
        /// may be null for headless use, in which case frames are drawn
        /// with `renderToTexture`.
        pub fn initFromDevice(
            instance: c.WGPUInstance,
            surface: c.WGPUSurface,
            ctx: wgpu_c.DeviceContext,
            width: u32,
            height: u32,
            options: InitOptions,
        ) !Self {
            const device = ctx.device;

            // Surface format is hardcoded to BGRA8Unorm — universal on D3D12
            // (Windows) and on essentially every desktop Vulkan swapchain
            // (Linux/X11). If a Vulkan driver ever rejects it (blank/garbled
            // window), query the surface's supported set with
            // wgpuSurfaceGetCapabilities and pick from caps.formats here
            // (the glyph/image textures stay BGRA8Unorm regardless — they're
            // sampled independently of the swapchain format).
            const surf_format = c.WGPUTextureFormat_BGRA8Unorm;
            const samples: u32 = if (options.msaa) scene_common.msaa_samples else 1;

            // Every UI pipeline shares one vertex layout: pos, color, uv.
            const vert_attrs = [_]c.WGPUVertexAttribute{
                .{ .format = c.WGPUVertexFormat_Float32x2, .offset = 0, .shaderLocation = 0 },
                .{ .format = c.WGPUVertexFormat_Float32x4, .offset = 8, .shaderLocation = 1 },
                .{ .format = c.WGPUVertexFormat_Float32x2, .offset = 24, .shaderLocation = 2 },
            };
            const vert_buf_layout = [_]c.WGPUVertexBufferLayout{.{
                .arrayStride = @sizeOf(Vertex),
                .stepMode = c.WGPUVertexStepMode_Vertex,
                .attributeCount = vert_attrs.len,
                .attributes = &vert_attrs,
            }};

            // Solid pipeline: one uniform buffer (screen size).
            const shader = try wgpu_c.createShader(device, "quad-shader", SHADER_CODE);
            defer c.wgpuShaderModuleRelease(shader);

            // binding 0: screen size; binding 1: the solid vertex buffer again,
            // read-only, so SDF quads can fetch their records (render/sdf.zig).
            var bgl_entries = [_]c.WGPUBindGroupLayoutEntry{ std.mem.zeroes(c.WGPUBindGroupLayoutEntry), std.mem.zeroes(c.WGPUBindGroupLayoutEntry) };
            bgl_entries[0].binding = 0;
            bgl_entries[0].visibility = c.WGPUShaderStage_Vertex;
            bgl_entries[0].buffer.type = c.WGPUBufferBindingType_Uniform;
            bgl_entries[0].buffer.minBindingSize = 8;
            bgl_entries[1].binding = 1;
            bgl_entries[1].visibility = c.WGPUShaderStage_Fragment;
            bgl_entries[1].buffer.type = c.WGPUBufferBindingType_ReadOnlyStorage;
            var bgl_desc = std.mem.zeroes(c.WGPUBindGroupLayoutDescriptor);
            bgl_desc.label = wgpuStr("uniform-bgl");
            bgl_desc.entryCount = bgl_entries.len;
            bgl_desc.entries = &bgl_entries;
            const bind_group_layout = c.wgpuDeviceCreateBindGroupLayout(device, &bgl_desc) orelse return error.BglCreateFailed;
            errdefer c.wgpuBindGroupLayoutRelease(bind_group_layout);

            var pl_desc = std.mem.zeroes(c.WGPUPipelineLayoutDescriptor);
            pl_desc.label = wgpuStr("pipeline-layout");
            pl_desc.bindGroupLayoutCount = 1;
            pl_desc.bindGroupLayouts = &bind_group_layout;
            const pipeline_layout = c.wgpuDeviceCreatePipelineLayout(device, &pl_desc) orelse return error.PipelineLayoutFailed;
            defer c.wgpuPipelineLayoutRelease(pipeline_layout);

            const pipeline = wgpu_c.createPipeline(device, .{
                .label = "quad-pipeline",
                .layout = pipeline_layout,
                .module = shader,
                .vertex_buffers = &vert_buf_layout,
                .format = surf_format,
                .samples = samples,
            }) orelse return error.PipelineCreateFailed;

            // Uniform buffer (8 bytes: vec2f screen_size).
            const uniform_buf = wgpu_c.createBuffer(device, "uniform-buf", c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst, 8) orelse return error.UniformBufFailed;

            // Text + image pipelines: BGL with uniform + texture + sampler.
            // Same vertex layout / blend state as the solid pipeline; only
            // the fragment shader differs.
            var text_bgl_entries = [_]c.WGPUBindGroupLayoutEntry{
                std.mem.zeroes(c.WGPUBindGroupLayoutEntry),
                std.mem.zeroes(c.WGPUBindGroupLayoutEntry),
                std.mem.zeroes(c.WGPUBindGroupLayoutEntry),
            };
            text_bgl_entries[0].binding = 0;
            text_bgl_entries[0].visibility = c.WGPUShaderStage_Vertex;
            text_bgl_entries[0].buffer.type = c.WGPUBufferBindingType_Uniform;
            text_bgl_entries[0].buffer.minBindingSize = 8;
            text_bgl_entries[1].binding = 1;
            text_bgl_entries[1].visibility = c.WGPUShaderStage_Fragment;
            text_bgl_entries[1].texture.sampleType = c.WGPUTextureSampleType_Float;
            text_bgl_entries[1].texture.viewDimension = c.WGPUTextureViewDimension_2D;
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

            // Image shader: texture * tint, no alpha-from-texture trick.
            const image_shader = try wgpu_c.createShader(device, "image-shader", SHADER_IMAGE);
            defer c.wgpuShaderModuleRelease(image_shader);
            const image_pipeline = wgpu_c.createPipeline(device, .{
                .label = "image-pipeline",
                .layout = text_pipeline_layout,
                .module = image_shader,
                .vertex_buffers = &vert_buf_layout,
                .format = surf_format,
                .samples = samples,
            }) orelse return error.ImagePipelineFailed;

            var sampler_desc = std.mem.zeroes(c.WGPUSamplerDescriptor);
            sampler_desc.label = wgpuStr("text-sampler");
            sampler_desc.addressModeU = c.WGPUAddressMode_ClampToEdge;
            sampler_desc.addressModeV = c.WGPUAddressMode_ClampToEdge;
            sampler_desc.addressModeW = c.WGPUAddressMode_ClampToEdge;
            // Nearest on magnification avoids bilinear re-blurring of the
            // grayscale-AA the rasterizer already baked into the atlas.
            // Linear on minification handles the case where a text rect is
            // smaller than its backing texture (rare — `uploadText` sizes
            // the text quad to match the rasterization extent).
            sampler_desc.magFilter = c.WGPUFilterMode_Nearest;
            sampler_desc.minFilter = c.WGPUFilterMode_Linear;
            sampler_desc.mipmapFilter = c.WGPUMipmapFilterMode_Nearest;
            sampler_desc.lodMinClamp = 0;
            sampler_desc.lodMaxClamp = 1;
            sampler_desc.maxAnisotropy = 1;
            const sampler = c.wgpuDeviceCreateSampler(device, &sampler_desc) orelse return error.SamplerFailed;

            const scene = try wgpu_scene.Renderer.init(device, ctx.queue, surf_format, options.scene_msaa);

            // OS-specific glyph rasterizer (stb_truetype).
            const raster = try Rasterizer.init(std.heap.page_allocator);

            const scale: f32 = if (options.scale > 0) options.scale else 1;
            var text = try text_stage.TextStage(Rasterizer).init(std.heap.page_allocator, raster, options.max_atlas_pages, scale);
            errdefer text.deinit();

            // Glyph pipeline: {uniform, R8 atlas page}; instance-stepped quads.
            var glyph_bgl_entries = [_]c.WGPUBindGroupLayoutEntry{
                std.mem.zeroes(c.WGPUBindGroupLayoutEntry),
                std.mem.zeroes(c.WGPUBindGroupLayoutEntry),
            };
            glyph_bgl_entries[0].binding = 0;
            glyph_bgl_entries[0].visibility = c.WGPUShaderStage_Vertex | c.WGPUShaderStage_Fragment;
            glyph_bgl_entries[0].buffer.type = c.WGPUBufferBindingType_Uniform;
            glyph_bgl_entries[0].buffer.minBindingSize = 16;
            glyph_bgl_entries[1].binding = 1;
            glyph_bgl_entries[1].visibility = c.WGPUShaderStage_Fragment;
            glyph_bgl_entries[1].texture.sampleType = c.WGPUTextureSampleType_Float;
            glyph_bgl_entries[1].texture.viewDimension = c.WGPUTextureViewDimension_2D;
            var glyph_bgl_desc = std.mem.zeroes(c.WGPUBindGroupLayoutDescriptor);
            glyph_bgl_desc.label = wgpuStr("glyph-bgl");
            glyph_bgl_desc.entryCount = glyph_bgl_entries.len;
            glyph_bgl_desc.entries = &glyph_bgl_entries;
            const glyph_bgl = c.wgpuDeviceCreateBindGroupLayout(device, &glyph_bgl_desc) orelse return error.TextBglFailed;
            var glyph_pl_desc = std.mem.zeroes(c.WGPUPipelineLayoutDescriptor);
            glyph_pl_desc.label = wgpuStr("glyph-pipeline-layout");
            glyph_pl_desc.bindGroupLayoutCount = 1;
            glyph_pl_desc.bindGroupLayouts = &glyph_bgl;
            const glyph_pl = c.wgpuDeviceCreatePipelineLayout(device, &glyph_pl_desc) orelse return error.TextPipelineLayoutFailed;
            defer c.wgpuPipelineLayoutRelease(glyph_pl);
            const glyph_shader = try wgpu_c.createShader(device, "glyph-shader", SHADER_GLYPH);
            defer c.wgpuShaderModuleRelease(glyph_shader);
            // Raw words, unpacked in glyph.wgsl (shared with the web backend).
            const inst_attrs = [_]c.WGPUVertexAttribute{
                .{ .format = c.WGPUVertexFormat_Float32x2, .offset = @offsetOf(glyph_atlas.GlyphInstance, "x"), .shaderLocation = 0 },
                .{ .format = c.WGPUVertexFormat_Uint32x2, .offset = @offsetOf(glyph_atlas.GlyphInstance, "w"), .shaderLocation = 1 },
                .{ .format = c.WGPUVertexFormat_Uint32, .offset = @offsetOf(glyph_atlas.GlyphInstance, "color"), .shaderLocation = 2 },
                .{ .format = c.WGPUVertexFormat_Uint32x2, .offset = @offsetOf(glyph_atlas.GlyphInstance, "clip_xy"), .shaderLocation = 3 },
                .{ .format = c.WGPUVertexFormat_Uint32, .offset = @offsetOf(glyph_atlas.GlyphInstance, "flags"), .shaderLocation = 4 },
            };
            const inst_layout = [_]c.WGPUVertexBufferLayout{.{
                .arrayStride = @sizeOf(glyph_atlas.GlyphInstance),
                .stepMode = c.WGPUVertexStepMode_Instance,
                .attributeCount = inst_attrs.len,
                .attributes = &inst_attrs,
            }};
            const glyph_pipeline = wgpu_c.createPipeline(device, .{
                .label = "glyph-pipeline",
                .layout = glyph_pl,
                .module = glyph_shader,
                .vertex_buffers = &inst_layout,
                .format = surf_format,
                .samples = samples,
            }) orelse return error.TextPipelineFailed;
            const glyph_uniform_buf = wgpu_c.createBuffer(device, "glyph-uniform-buf", c.WGPUBufferUsage_Uniform | c.WGPUBufferUsage_CopyDst, 16) orelse return error.UniformBufFailed;

            var gpu: Self = .{
                .instance = instance,
                .surface = surface,
                .adapter = ctx.adapter,
                .device = device,
                .queue = ctx.queue,
                .pipeline = pipeline,
                .bind_group = null,
                .bind_group_buf = null,
                .bind_group_size = 0,
                .solid_bgl = bind_group_layout,
                .uniform_buf = uniform_buf,
                .vert_buf = null,
                .vert_buf_size = 0,
                .vert_count = 0,
                .surf_format = surf_format,
                .samples = samples,
                .msaa_tex = null,
                .msaa_view = null,
                .msaa_w = 0,
                .msaa_h = 0,
                // `gpu.resize(width, height)` below populates these for real;
                // zero-init here keeps the field set strictly post-init.
                .width = 0,
                .height = 0,
                .text_bgl = text_bgl,
                .sampler = sampler,
                .glyph_pipeline = glyph_pipeline,
                .glyph_bgl = glyph_bgl,
                .glyph_uniform_buf = glyph_uniform_buf,
                .text = text,
                .atlas_pages = .empty,
                .glyph_buf = null,
                .glyph_buf_size = 0,
                .scale = scale,
                .image_pipeline = image_pipeline,
                .images = .{},
                .image_draws = .empty,
                .image_verts = .empty,
                .image_vert_buf = null,
                .image_vert_buf_size = 0,
                .scene = scene,
                .scene_bind_groups = @splat(null),
                .scene_bg_gen = @splat(0),
                .scene_draws = undefined,
                .scene_draw_count = 0,
                .scene_verts = undefined,
                .scene_vert_count = 0,
                .scene_vert_buf = null,
                .scene_vert_buf_size = 0,
                .offscreen = null,
                .overlay_split = null,
                .image_ov = 0,
                .scene_ov = 0,
                .secondary_surfaces = @splat(.{
                    .surface = null,
                    .width = 0,
                    .height = 0,
                    .active = false,
                }),
            };
            gpu.resize(width, height);
            return gpu;
        }

        pub fn deinit(self: *Self) void {
            // Bind groups hold refs to views, which hold refs to textures:
            // release in that order. Vertex buffers last.
            for (self.scene_bind_groups) |bg| if (bg) |g| c.wgpuBindGroupRelease(g);
            if (self.scene_vert_buf) |b| c.wgpuBufferRelease(b);
            self.scene.deinit();

            var images = self.images.iterator();
            while (images.next()) |e| e.release();
            self.images.deinit(image_gpa);
            self.image_draws.deinit(image_gpa);
            self.image_verts.deinit(image_gpa);
            if (self.image_vert_buf) |ib| c.wgpuBufferRelease(ib);
            c.wgpuRenderPipelineRelease(self.image_pipeline);

            for (self.atlas_pages.items) |pg| {
                c.wgpuBindGroupRelease(pg.bind_group);
                c.wgpuTextureViewRelease(pg.view);
                c.wgpuTextureRelease(pg.texture);
            }
            self.atlas_pages.deinit(std.heap.page_allocator);
            self.text.deinit();
            if (self.glyph_buf) |gb| c.wgpuBufferRelease(gb);
            c.wgpuBufferRelease(self.glyph_uniform_buf);
            c.wgpuRenderPipelineRelease(self.glyph_pipeline);
            c.wgpuBindGroupLayoutRelease(self.glyph_bgl);
            c.wgpuSamplerRelease(self.sampler);
            c.wgpuBindGroupLayoutRelease(self.text_bgl);

            self.releaseMsaa();
            if (self.offscreen) |t| c.wgpuTextureRelease(t);
            if (self.vert_buf) |vb| c.wgpuBufferRelease(vb);
            if (self.bind_group) |bg| c.wgpuBindGroupRelease(bg);
            c.wgpuBindGroupLayoutRelease(self.solid_bgl);
            c.wgpuBufferRelease(self.uniform_buf);
            c.wgpuRenderPipelineRelease(self.pipeline);
            c.wgpuQueueRelease(self.queue);
            c.wgpuDeviceRelease(self.device);
            c.wgpuAdapterRelease(self.adapter);
            if (self.surface != null) c.wgpuSurfaceRelease(self.surface);

            // Release any still-active secondary surfaces. Apps that pair
            // `openSecondarySurface` with `closeSecondaryWindow` will have
            // already done so; this is the safety net for early-exit paths.
            for (&self.secondary_surfaces) |*slot| {
                if (slot.active and slot.surface != null) {
                    c.wgpuSurfaceRelease(slot.surface);
                    slot.active = false;
                    slot.surface = null;
                }
            }

            c.wgpuInstanceRelease(self.instance);
        }

        /// Shared surface configuration. Primary + secondary surfaces all
        /// take the same {format, usage, present mode, alpha mode} — only
        /// the dimensions differ. Centralizing this keeps the three call
        /// sites (`resize`, `openSecondarySurface`, `resizeWindow`) in
        /// lock-step on swap-chain semantics.
        fn configureSurface(self: *Self, surface: c.WGPUSurface, width: u32, height: u32) void {
            var surf_config = std.mem.zeroes(c.WGPUSurfaceConfiguration);
            surf_config.device = self.device;
            surf_config.format = self.surf_format;
            surf_config.usage = c.WGPUTextureUsage_RenderAttachment;
            surf_config.width = width;
            surf_config.height = height;
            surf_config.presentMode = c.WGPUPresentMode_Fifo;
            surf_config.alphaMode = c.WGPUCompositeAlphaMode_Auto;
            c.wgpuSurfaceConfigure(surface, &surf_config);
        }

        /// Device pixels for a logical extent: `InitOptions.scale` times it.
        /// `resize`, `init*` and the secondary-surface calls take the logical
        /// window size (identical to device pixels while the scale is 1).
        fn devicePx(self: *const Self, logical: u32) u32 {
            return @intFromFloat(@round(@as(f32, @floatFromInt(logical)) * self.scale));
        }

        pub fn resize(self: *Self, logical_w: u32, logical_h: u32) void {
            const width = self.devicePx(logical_w);
            const height = self.devicePx(logical_h);
            self.width = width;
            self.height = height;
            if (self.surface != null) self.configureSurface(self.surface, width, height);
            if (self.offscreen != null) self.recreateOffscreen(width, height) catch {};

            self.writeScreenSize(width, height);
        }

        /// Publish the target's size to the shaders: the solid/image pipelines
        /// work in logical px (device size / scale); the glyph pipeline also
        /// needs the scale because its instances are in device px.
        fn writeScreenSize(self: *Self, device_w: u32, device_h: u32) void {
            const logical = [2]f32{ @as(f32, @floatFromInt(device_w)) / self.scale, @as(f32, @floatFromInt(device_h)) / self.scale };
            c.wgpuQueueWriteBuffer(self.queue, self.uniform_buf, 0, &logical, @sizeOf([2]f32));
            const glyph_u = [4]f32{ logical[0], logical[1], self.scale, 1.0 };
            c.wgpuQueueWriteBuffer(self.queue, self.glyph_uniform_buf, 0, &glyph_u, @sizeOf([4]f32));
        }

        /// Grow `buf` to hold `verts` and write them. Shared by the solid,
        /// text, image and scene-composite vertex streams.
        fn writeVerts(self: *Self, label: []const u8, buf: *c.WGPUBuffer, size: *u64, verts: []const Vertex) void {
            self.writeVertsAs(label, c.WGPUBufferUsage_Vertex, buf, size, verts);
        }

        fn writeVertsAs(self: *Self, label: []const u8, usage: c.WGPUBufferUsage, buf: *c.WGPUBuffer, size: *u64, verts: []const Vertex) void {
            const byte_size: u64 = @intCast(verts.len * @sizeOf(Vertex));
            if (byte_size == 0) return;
            wgpu_c.ensureBuffer(self.device, label, usage | c.WGPUBufferUsage_CopyDst, buf, size, byte_size);
            c.wgpuQueueWriteBuffer(self.queue, buf.*, 0, verts.ptr, byte_size);
        }

        /// Where the overlay layer starts in this frame's lists (from
        /// `render.buildFrame`). Call before `uploadVertices` / `uploadText` /
        /// `uploadImages` / `renderScenes`; the main pass then draws all base
        /// content (solids, images, scenes, text) before the overlay's.
        pub fn setOverlayStart(self: *Self, split: OverlaySplit) void {
            self.overlay_split = split;
        }

        fn splitOf(self: *const Self, comptime field: []const u8, len: usize) usize {
            return if (self.overlay_split) |o| @as(usize, @field(o, field)) else len;
        }

        pub fn uploadVertices(self: *Self, verts: []const Vertex) void {
            self.vert_count = @intCast(verts.len);
            // Also bound read-only in the fragment stage: SDF quads read their records from it.
            self.writeVertsAs("vertex-buf", c.WGPUBufferUsage_Vertex | c.WGPUBufferUsage_Storage, &self.vert_buf, &self.vert_buf_size, verts);
        }

        // ── Main pass ──────────────────────────────────────────────

        fn releaseMsaa(self: *Self) void {
            if (self.msaa_view) |v| c.wgpuTextureViewRelease(v);
            if (self.msaa_tex) |t| c.wgpuTextureRelease(t);
            self.msaa_view = null;
            self.msaa_tex = null;
            self.msaa_w = 0;
            self.msaa_h = 0;
        }

        /// The multisampled colour target for a `w x h` surface, created or
        /// resized on demand (null if the device refuses). Shared by every
        /// window: switching between differently sized windows recreates it.
        fn msaaViewFor(self: *Self, w: u32, h: u32) c.WGPUTextureView {
            if (self.msaa_view != null and self.msaa_w == w and self.msaa_h == h) return self.msaa_view;
            self.releaseMsaa();
            const tex = wgpu_c.createTexture2D(self.device, "main-msaa", .{
                .width = w,
                .height = h,
                .format = self.surf_format,
                .usage = c.WGPUTextureUsage_RenderAttachment,
                .samples = self.samples,
            }) orelse return null;
            const view = wgpu_c.createView2D(tex, "main-msaa-view", self.surf_format) orelse {
                c.wgpuTextureRelease(tex);
                return null;
            };
            self.msaa_tex = tex;
            self.msaa_view = view;
            self.msaa_w = w;
            self.msaa_h = h;
            return view;
        }

        /// Render against the primary window. Thin wrapper around
        /// `renderToWindow(0, ...)` so single-window callers keep their
        /// existing call site verbatim.
        pub fn renderFrame(self: *Self, clear_color: ClearColor) void {
            self.renderToWindow(0, clear_color);
        }

        /// Render the most-recently-uploaded vertex / text / image / scene
        /// draws into the surface for `window_id`. `id = 0` selects the
        /// primary surface (the existing `renderFrame` path); `id >= 1`
        /// indexes secondary surfaces opened via `openSecondarySurface`.
        ///
        /// The uniform buffer is rewritten with the target window's size
        /// before issuing draws so the shader's vec2f screen_size matches
        /// the surface being rendered into. The caller is expected to have
        /// uploaded vertex/text/image data matching this window already
        /// (apps that render different content per window simply call
        /// upload* + renderToWindow once per window per frame).
        pub fn renderToWindow(self: *Self, window_id: u32, clear_color: ClearColor) void {
            if (self.surface == null and window_id == 0) {
                // Headless: the primary "window" is the offscreen target.
                if (self.offscreen) |t| self.renderToTexture(t, self.width, self.height, clear_color);
                return;
            }
            const target_w: u32, const target_h: u32, const surface_handle: c.WGPUSurface = blk: {
                if (window_id == 0) break :blk .{ self.width, self.height, self.surface };
                if (window_id > MAX_SECONDARY_SURFACES) return;
                const slot = self.secondary_surfaces[window_id - 1];
                if (!slot.active or slot.surface == null) return;
                break :blk .{ slot.width, slot.height, slot.surface };
            };

            // The shared uniform buffer holds the target window's pixel
            // size; the vertex shader divides clip-space against it. Must
            // be rewritten for EVERY renderToWindow call (primary included)
            // — otherwise rendering a secondary leaves its dims in the
            // uniform, scaling the next primary frame to the secondary's
            // viewport. Single 8-byte queue write per frame per window.
            self.writeScreenSize(target_w, target_h);

            var surface_texture: c.WGPUSurfaceTexture = undefined;
            c.wgpuSurfaceGetCurrentTexture(surface_handle, &surface_texture);
            if (surface_texture.status != c.WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal and
                surface_texture.status != c.WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal)
            {
                return;
            }

            const texture_view = c.wgpuTextureCreateView(surface_texture.texture, null);
            defer c.wgpuTextureViewRelease(texture_view);

            self.encodeMainPass(texture_view, target_w, target_h, clear_color);
            _ = c.wgpuSurfacePresent(surface_handle);
        }

        /// Render the staged draws into `texture` (a `w x h` render
        /// attachment in the surface format) instead of a window: headless
        /// tests and screenshots. Same pass as `renderFrame`, including MSAA.
        pub fn renderToTexture(self: *Self, texture: c.WGPUTexture, w: u32, h: u32, clear_color: ClearColor) void {
            self.writeScreenSize(w, h);
            const view = c.wgpuTextureCreateView(texture, null);
            defer c.wgpuTextureViewRelease(view);
            self.encodeMainPass(view, w, h, clear_color);
        }

        /// Record, submit and finish the main UI pass into `texture_view`.
        fn encodeMainPass(self: *Self, texture_view: c.WGPUTextureView, target_w: u32, target_h: u32, clear_color: ClearColor) void {
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
            // MSAA: draw into the multisampled target, resolve into the
            // swap-chain texture, and discard the samples.
            if (self.samples > 1) {
                if (self.msaaViewFor(target_w, target_h)) |msaa| {
                    color_attachment.view = msaa;
                    color_attachment.resolveTarget = texture_view;
                    color_attachment.storeOp = c.WGPUStoreOp_Discard;
                }
            }

            var rp_desc = std.mem.zeroes(c.WGPURenderPassDescriptor);
            rp_desc.label = wgpuStr("render-pass");
            rp_desc.colorAttachmentCount = 1;
            rp_desc.colorAttachments = &color_attachment;

            const pass = c.wgpuCommandEncoderBeginRenderPass(encoder, &rp_desc);

            // Base layer first, then the overlay: within a layer, solids,
            // images, scene composites (same pipeline: a scene is an image
            // the GPU rendered this frame), then text on top. Drawing the
            // overlay's solids after the base's TEXT is what lets an opaque
            // popup hide the text beneath it.
            const solid = overlay.Range.of(self.splitOf("verts", self.vert_count), self.vert_count);
            const imgs = overlay.Range.of(self.image_ov, self.image_draws.items.len);
            const scns = overlay.Range.of(self.scene_ov, self.scene_draw_count);
            inline for (.{ "base", "overlay" }) |layer| {
                self.drawSolids(pass, @field(overlay.Range, layer)(solid));
                drawQuads(pass, self.image_pipeline, self.image_vert_buf, @intCast(self.image_verts.items.len), self.image_draws.items, @field(overlay.Range, layer)(imgs));
                drawQuads(pass, self.image_pipeline, self.scene_vert_buf, self.scene_vert_count, self.scene_draws[0..self.scene_draw_count], @field(overlay.Range, layer)(scns));
                self.drawGlyphs(pass, if (comptime std.mem.eql(u8, layer, "base")) 0 else 1);
            }

            c.wgpuRenderPassEncoderEnd(pass);
            c.wgpuRenderPassEncoderRelease(pass);

            var cmd_buf_desc = std.mem.zeroes(c.WGPUCommandBufferDescriptor);
            cmd_buf_desc.label = wgpuStr("frame-cmds");
            const command_buffer = c.wgpuCommandEncoderFinish(encoder, &cmd_buf_desc);
            c.wgpuCommandEncoderRelease(encoder);

            c.wgpuQueueSubmit(self.queue, 1, &command_buffer);
            c.wgpuCommandBufferRelease(command_buffer);
        }

        /// {screen size, solid vertex buffer as read-only storage}, rebuilt
        /// whenever `vert_buf` is reallocated.
        fn rebuildSolidBindGroup(self: *Self) void {
            if (self.bind_group) |old| c.wgpuBindGroupRelease(old);
            var entries = [_]c.WGPUBindGroupEntry{ std.mem.zeroes(c.WGPUBindGroupEntry), std.mem.zeroes(c.WGPUBindGroupEntry) };
            entries[0].binding = 0;
            entries[0].buffer = self.uniform_buf;
            entries[0].size = 8;
            entries[1].binding = 1;
            entries[1].buffer = self.vert_buf;
            entries[1].size = self.vert_buf_size;
            var desc = std.mem.zeroes(c.WGPUBindGroupDescriptor);
            desc.label = wgpuStr("solid-bind-group");
            desc.layout = self.solid_bgl;
            desc.entryCount = entries.len;
            desc.entries = &entries;
            self.bind_group = c.wgpuDeviceCreateBindGroup(self.device, &desc);
            self.bind_group_buf = self.vert_buf;
            self.bind_group_size = self.vert_buf_size;
        }

        /// Solid quads `[from, to)` (vertex indices).
        fn drawSolids(self: *Self, pass: c.WGPURenderPassEncoder, range: struct { usize, usize }) void {
            const from, const to = range;
            if (to <= from or self.vert_buf == null) return;
            const draw_byte_size: u64 = @as(u64, self.vert_count) * @sizeOf(Vertex);
            if (self.bind_group_buf != self.vert_buf or self.bind_group_size != self.vert_buf_size) self.rebuildSolidBindGroup();
            c.wgpuRenderPassEncoderSetPipeline(pass, self.pipeline);
            c.wgpuRenderPassEncoderSetBindGroup(pass, 0, self.bind_group, 0, null);
            c.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, self.vert_buf, 0, draw_byte_size);
            c.wgpuRenderPassEncoderDraw(pass, @intCast(to - from), 1, @intCast(from), 0);
        }

        /// The staged textured-quad `draws[from..to]`, vertices in `vert_buf`.
        fn drawQuads(
            pass: c.WGPURenderPassEncoder,
            pipeline: c.WGPURenderPipeline,
            vert_buf: c.WGPUBuffer,
            vert_count: u32,
            all: []const QuadDraw,
            range: struct { usize, usize },
        ) void {
            const from, const to = range;
            const draws = all[from..to];
            if (draws.len == 0 or vert_buf == null) return;
            const byte_size: u64 = @as(u64, vert_count) * @sizeOf(Vertex);
            c.wgpuRenderPassEncoderSetPipeline(pass, pipeline);
            c.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, vert_buf, 0, byte_size);
            for (draws) |rec| {
                c.wgpuRenderPassEncoderSetBindGroup(pass, 0, rec.bind_group, 0, null);
                c.wgpuRenderPassEncoderDraw(pass, 6, 1, rec.vert_offset, 0);
            }
        }

        /// Create a wgpu surface bound to an additional native window.
        /// `handle` is the platform `NativeHandle` (the same value
        /// `host.secondaryWindowHandle` returns and that `init` consumed
        /// for the primary) — surface construction is delegated to the
        /// injected `Surface` provider so this path is platform-generic
        /// (HARDLINE §4(c) — the GPU layer never imports platform types;
        /// the handle is duck-typed by the provider). Returns a 1-based
        /// slot id matching the Host's secondary id space, or `null` on
        /// full-table / surface-create failure.
        pub fn openSecondarySurface(self: *Self, handle: anytype, w: u32, h: u32) ?u32 {
            var slot_idx: usize = MAX_SECONDARY_SURFACES;
            for (self.secondary_surfaces, 0..) |slot, i| {
                if (!slot.active) {
                    slot_idx = i;
                    break;
                }
            }
            if (slot_idx == MAX_SECONDARY_SURFACES) return null;

            const surface = Surface.createSurface(self.instance, handle) catch return null;

            // Configure the surface with the same format the primary uses.
            const dw = self.devicePx(w);
            const dh = self.devicePx(h);
            self.configureSurface(surface, dw, dh);

            self.secondary_surfaces[slot_idx] = .{
                .surface = surface,
                .width = dw,
                .height = dh,
                .active = true,
            };
            return @intCast(slot_idx + 1);
        }

        /// Release the secondary surface for `window_id`. No-op on invalid
        /// ids. Apps pair this with `host.closeSecondaryWindow` — same id.
        pub fn closeSecondarySurface(self: *Self, window_id: u32) void {
            if (window_id == 0 or window_id > MAX_SECONDARY_SURFACES) return;
            const slot = &self.secondary_surfaces[window_id - 1];
            if (slot.active and slot.surface != null) {
                c.wgpuSurfaceRelease(slot.surface);
            }
            slot.* = .{ .surface = null, .width = 0, .height = 0, .active = false };
        }

        /// Resize either the primary surface (id == 0) or a secondary one
        /// (id >= 1). For the primary this rewrites the shared uniform
        /// buffer; for secondaries the uniform is rewritten lazily inside
        /// `renderToWindow` each frame.
        pub fn resizeWindow(self: *Self, window_id: u32, w: u32, h: u32) void {
            if (window_id == 0) {
                self.resize(w, h);
                return;
            }
            if (window_id > MAX_SECONDARY_SURFACES) return;
            const slot = &self.secondary_surfaces[window_id - 1];
            if (!slot.active or slot.surface == null) return;

            slot.width = self.devicePx(w);
            slot.height = self.devicePx(h);
            self.configureSurface(slot.surface, slot.width, slot.height);
        }

        // ── Text: shaped glyphs -> atlas -> instanced quads ────────

        /// Per-frame text staging (call after `uploadVertices`, before
        /// `renderFrame`). `text_stage` shapes every `TextDraw`, packs glyphs the
        /// atlas has not seen (rasterized at the device pixel size with a
        /// quarter-pixel x bin) into CPU pages and appends one `GlyphInstance` per
        /// visible glyph; this uploads the new pages' dirty rects and the
        /// instances. Glyphs used this frame pin their page, so nothing visible is
        /// evicted mid-frame; if every page is pinned the glyph is dropped for the
        /// frame and a warning names `InitOptions.max_atlas_pages`.
        pub fn uploadText(self: *Self, draws: []const TextDraw) void {
            self.text.stage(draws, self.splitOf("text", draws.len));
            self.flushGlyphs();
            if (self.text.shouldReportDrops()) {
                std.log.warn(
                    "teak: glyph atlas exhausted ({d} pages in use this frame, cap {d}); dropped {d} glyphs. " ++
                        "Raise InitOptions.max_atlas_pages or draw fewer distinct glyphs/sizes per frame.",
                    .{ self.text.atlas.pageCount(), self.text.atlas.max_pages, self.text.dropped },
                );
            }
        }

        /// Create GPU textures for atlas pages added since the last frame.
        fn ensurePages(self: *Self) void {
            const alloc = std.heap.page_allocator;
            while (self.atlas_pages.items.len < self.text.pageCount()) {
                const texture = wgpu_c.createTexture2D(self.device, "glyph-atlas", .{
                    .width = atlas_dim,
                    .height = atlas_dim,
                    .format = c.WGPUTextureFormat_R8Unorm,
                    .usage = c.WGPUTextureUsage_TextureBinding | c.WGPUTextureUsage_CopyDst,
                }) orelse return;
                const view = wgpu_c.createView2D(texture, "glyph-atlas", c.WGPUTextureFormat_R8Unorm) orelse {
                    c.wgpuTextureRelease(texture);
                    return;
                };
                var entries = [_]c.WGPUBindGroupEntry{
                    std.mem.zeroes(c.WGPUBindGroupEntry),
                    std.mem.zeroes(c.WGPUBindGroupEntry),
                };
                entries[0].binding = 0;
                entries[0].buffer = self.glyph_uniform_buf;
                entries[0].size = 16;
                entries[1].binding = 1;
                entries[1].textureView = view;
                var desc = std.mem.zeroes(c.WGPUBindGroupDescriptor);
                desc.label = wgpuStr("glyph-atlas-bg");
                desc.layout = self.glyph_bgl;
                desc.entryCount = entries.len;
                desc.entries = &entries;
                const bg = c.wgpuDeviceCreateBindGroup(self.device, &desc) orelse {
                    c.wgpuTextureViewRelease(view);
                    c.wgpuTextureRelease(texture);
                    return;
                };
                self.atlas_pages.append(alloc, .{ .texture = texture, .view = view, .bind_group = bg }) catch return;
            }
        }

        /// Upload dirty atlas rects and the frame's instances.
        fn flushGlyphs(self: *Self) void {
            self.ensurePages();
            for (self.atlas_pages.items, 0..) |pg, i| {
                if (i >= self.text.pageCount()) break;
                const d = self.text.takeDirty(i) orelse continue;
                var dst = std.mem.zeroes(c.WGPUTexelCopyTextureInfo);
                dst.texture = pg.texture;
                dst.aspect = c.WGPUTextureAspect_All;
                dst.origin = .{ .x = d.x, .y = d.y, .z = 0 };
                var layout = std.mem.zeroes(c.WGPUTexelCopyBufferLayout);
                layout.bytesPerRow = atlas_dim;
                layout.rowsPerImage = d.h;
                const extent = c.WGPUExtent3D{ .width = d.w, .height = d.h, .depthOrArrayLayers = 1 };
                const staging = self.text.pageStaging(i);
                const start = @as(usize, d.y) * atlas_dim + d.x;
                const len = (@as(usize, d.h) - 1) * atlas_dim + d.w;
                c.wgpuQueueWriteTexture(self.queue, &dst, staging[start..].ptr, len, &layout, &extent);
            }

            const total = self.text.finish();
            if (total == 0) return;
            const bytes: u64 = @as(u64, total) * @sizeOf(glyph_atlas.GlyphInstance);
            // Grow geometrically so a scrolling frame does not reallocate every frame.
            const want = if (self.glyph_buf != null and bytes > self.glyph_buf_size) bytes + bytes / 2 else bytes;
            wgpu_c.ensureBuffer(self.device, "glyph-instances", c.WGPUBufferUsage_Vertex | c.WGPUBufferUsage_CopyDst, &self.glyph_buf, &self.glyph_buf_size, want);
            for (0..2) |layer| {
                for (self.text.insts.items) |*pi| {
                    const list = pi.list[layer].items;
                    if (list.len == 0) continue;
                    const off: u64 = @as(u64, pi.first[layer]) * @sizeOf(glyph_atlas.GlyphInstance);
                    c.wgpuQueueWriteBuffer(self.queue, self.glyph_buf, off, list.ptr, @as(u64, list.len) * @sizeOf(glyph_atlas.GlyphInstance));
                }
            }
        }

        /// One instanced draw per atlas page holding glyphs of `layer`.
        fn drawGlyphs(self: *Self, pass: c.WGPURenderPassEncoder, layer: usize) void {
            if (self.glyph_buf == null) return;
            var bound = false;
            for (self.text.insts.items, 0..) |pi, i| {
                const n = pi.list[layer].items.len;
                if (n == 0 or i >= self.atlas_pages.items.len) continue;
                if (!bound) {
                    c.wgpuRenderPassEncoderSetPipeline(pass, self.glyph_pipeline);
                    c.wgpuRenderPassEncoderSetVertexBuffer(pass, 0, self.glyph_buf, 0, self.glyph_buf_size);
                    bound = true;
                }
                c.wgpuRenderPassEncoderSetBindGroup(pass, 0, self.atlas_pages.items[i].bind_group, 0, null);
                c.wgpuRenderPassEncoderDraw(pass, 6, @intCast(n), 0, pi.first[layer]);
            }
        }

        // ── Sampled textures (text glyph runs, images) ─────────────

        /// Bind group for sampling `view` through the text/image pipelines:
        /// {screen-size uniform, texture, sampler}.
        fn textureBindGroup(self: *Self, label: []const u8, view: c.WGPUTextureView) c.WGPUBindGroup {
            var entries = [_]c.WGPUBindGroupEntry{
                std.mem.zeroes(c.WGPUBindGroupEntry),
                std.mem.zeroes(c.WGPUBindGroupEntry),
                std.mem.zeroes(c.WGPUBindGroupEntry),
            };
            entries[0].binding = 0;
            entries[0].buffer = self.uniform_buf;
            entries[0].size = 8;
            entries[1].binding = 1;
            entries[1].textureView = view;
            entries[2].binding = 2;
            entries[2].sampler = self.sampler;

            var desc = std.mem.zeroes(c.WGPUBindGroupDescriptor);
            desc.label = wgpuStr(label);
            desc.layout = self.text_bgl;
            desc.entryCount = entries.len;
            desc.entries = &entries;
            return c.wgpuDeviceCreateBindGroup(self.device, &desc);
        }

        /// Create a `width x height` texture of `format`, fill it with
        /// tightly packed `pixels`, and build its bind group.
        fn createSampled(
            self: *Self,
            label: []const u8,
            format: c.WGPUTextureFormat,
            pixels: []const u8,
            width: u32,
            height: u32,
        ) ?Sampled {
            const texture = wgpu_c.createTexture2D(self.device, label, .{
                .width = width,
                .height = height,
                .format = format,
                .usage = c.WGPUTextureUsage_TextureBinding | c.WGPUTextureUsage_CopyDst,
            }) orelse return null;

            var dst = std.mem.zeroes(c.WGPUTexelCopyTextureInfo);
            dst.texture = texture;
            dst.aspect = c.WGPUTextureAspect_All;
            var data_layout = std.mem.zeroes(c.WGPUTexelCopyBufferLayout);
            data_layout.bytesPerRow = width * 4;
            data_layout.rowsPerImage = height;
            const extent = c.WGPUExtent3D{ .width = width, .height = height, .depthOrArrayLayers = 1 };
            c.wgpuQueueWriteTexture(self.queue, &dst, pixels.ptr, pixels.len, &data_layout, &extent);

            const view = wgpu_c.createView2D(texture, label, format) orelse {
                c.wgpuTextureRelease(texture);
                return null;
            };
            const bind_group = self.textureBindGroup(label, view) orelse {
                c.wgpuTextureViewRelease(view);
                c.wgpuTextureRelease(texture);
                return null;
            };
            return .{ .texture = texture, .view = view, .bind_group = bind_group };
        }

        /// Upload an RGBA8 image. `bytes.len` must equal `width * height * 4`.
        /// Returns an opaque handle the app stashes in `ImageCmd.handle`.
        /// Returns `TEXTURE_HANDLE_NONE` on bad dims, device failure, or
        /// (loudly) at the 65536-image ceiling. The cache grows on demand.
        pub fn uploadImage(self: *Self, bytes: []const u8, width: u32, height: u32) TextureHandle {
            if (width == 0 or height == 0) return teak.TEXTURE_HANDLE_NONE;
            const need = @as(usize, width) * @as(usize, height) * 4;
            if (bytes.len < need) return teak.TEXTURE_HANDLE_NONE;
            const sampled = self.createSampled("image", c.WGPUTextureFormat_RGBA8Unorm, bytes[0..need], width, height) orelse
                return teak.TEXTURE_HANDLE_NONE;
            return self.images.insert(image_gpa, sampled) orelse {
                std.debug.print("teak: image cache full ({d} live images); upload dropped\n", .{IMAGE_MAX_SLOTS});
                sampled.release();
                return teak.TEXTURE_HANDLE_NONE;
            };
        }

        /// Free an image uploaded with `uploadImage`. The handle (and any
        /// `ImageDraw` still carrying it) is dead afterwards; the slot is
        /// reused by the next upload.
        pub fn releaseImage(self: *Self, handle: TextureHandle) void {
            if (self.images.remove(image_gpa, handle)) |e| e.release();
        }

        /// Per-frame draw orchestration for images. Walks ImageDraws, emits
        /// 6 textured vertices per visible draw, records a draw entry per
        /// image. Call after `uploadText` and before `renderFrame`.
        pub fn uploadImages(self: *Self, draws: []const ImageDraw) void {
            self.image_draws.clearRetainingCapacity();
            self.image_verts.clearRetainingCapacity();
            var mark: overlay.Marker = .{ .start = self.splitOf("images", draws.len) };
            defer self.image_ov = mark.finish(self.image_draws.items.len);

            for (draws, 0..) |draw, di| {
                mark.visit(di, self.image_draws.items.len);
                const entry = self.images.get(draw.handle) orelse continue;
                const quad = teak.vertex.clippedTexturedQuad(
                    .{ .x = draw.rect_x, .y = draw.rect_y, .w = draw.rect_w, .h = draw.rect_h },
                    .{ .x = draw.clip_x, .y = draw.clip_y, .w = draw.clip_w, .h = draw.clip_h },
                    draw.tint,
                ) orelse continue;

                const offset: u32 = @intCast(self.image_verts.items.len);
                self.image_draws.ensureUnusedCapacity(image_gpa, 1) catch break;
                self.image_verts.appendSlice(image_gpa, &quad) catch break;
                self.image_draws.appendAssumeCapacity(.{ .bind_group = entry.bind_group, .vert_offset = offset });
            }

            self.writeVerts("image-vert-buf", &self.image_vert_buf, &self.image_vert_buf_size, self.image_verts.items);
        }

        // ── 3D scenes ──────────────────────────────────────────────

        /// Upload mesh geometry; the returned handle goes into
        /// `SceneDraw.mesh`. `MESH_HANDLE_NONE` on invalid data or a full
        /// table. See `wgpu_scene.Renderer.uploadMesh`.
        pub fn uploadMesh(self: *Self, data: teak.MeshData) teak.MeshHandle {
            return self.scene.uploadMesh(data);
        }

        pub fn releaseMesh(self: *Self, handle: teak.MeshHandle) void {
            self.scene.releaseMesh(handle);
        }

        /// Render each scene into its offscreen target and stage a
        /// composite quad per visible scene for the next `renderFrame`.
        /// Call after `uploadImages`, before `renderFrame`. Scenes whose
        /// content did not change since the last frame are not redrawn.
        pub fn renderScenes(self: *Self, draws: []const teak.SceneDraw, items: []const teak.SceneItem) void {
            self.scene_draw_count = 0;
            self.scene_vert_count = 0;
            var mark: overlay.Marker = .{ .start = self.splitOf("scenes", draws.len) };
            defer self.scene_ov = mark.finish(self.scene_draw_count);
            if (draws.len == 0) return;

            var enc_desc = std.mem.zeroes(c.WGPUCommandEncoderDescriptor);
            enc_desc.label = wgpuStr("scene-encoder");
            const encoder = c.wgpuDeviceCreateCommandEncoder(self.device, &enc_desc);

            // Native logical pixels are device pixels.
            const scale: f32 = 1;
            for (draws[0..@min(draws.len, scene_common.max_scenes)], 0..) |draw, i| {
                mark.visit(i, self.scene_draw_count);
                const size = self.scene.renderInto(encoder, i, draw, scene_common.itemsOf(draw, items), scale) orelse continue;
                const quad = scene_common.compositeQuad(draw, size, scale) orelse continue;
                const bind_group = self.sceneBindGroup(i) orelse continue;

                const offset = self.scene_vert_count;
                @memcpy(self.scene_verts[offset..][0..6], &quad);
                self.scene_vert_count += 6;
                self.scene_draws[self.scene_draw_count] = .{ .bind_group = bind_group, .vert_offset = offset };
                self.scene_draw_count += 1;
            }

            var cb_desc = std.mem.zeroes(c.WGPUCommandBufferDescriptor);
            cb_desc.label = wgpuStr("scene-cmds");
            const command_buffer = c.wgpuCommandEncoderFinish(encoder, &cb_desc);
            c.wgpuCommandEncoderRelease(encoder);
            c.wgpuQueueSubmit(self.queue, 1, &command_buffer);
            c.wgpuCommandBufferRelease(command_buffer);

            self.writeVerts("scene-vert-buf", &self.scene_vert_buf, &self.scene_vert_buf_size, self.scene_verts[0..self.scene_vert_count]);
        }

        /// Composite bind group for scene slot `i`, rebuilt whenever the
        /// slot's target was recreated.
        fn sceneBindGroup(self: *Self, i: usize) c.WGPUBindGroup {
            const target = self.scene.target(i) orelse return null;
            if (self.scene_bind_groups[i] != null and self.scene_bg_gen[i] == target.generation) {
                return self.scene_bind_groups[i];
            }
            if (self.scene_bind_groups[i]) |old| c.wgpuBindGroupRelease(old);
            self.scene_bind_groups[i] = self.textureBindGroup("scene-composite", target.color_view);
            self.scene_bg_gen[i] = target.generation;
            return self.scene_bind_groups[i];
        }
    };
}
