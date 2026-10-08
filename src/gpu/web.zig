//! WebGPU backend via zunk. Mirrors `gpu/wgpu_core.zig`'s pipeline shape —
//! shared wgsl shaders, same Vertex layout, same screen_size uniform,
//! same solid / image pipelines, the shared glyph-atlas text pass
//! (`text_stage.zig` + `shaders/glyph.wgsl`, stb_truetype in wasm), and
//! the same frame structure: stage UI draws, `renderScenes` (offscreen 3D
//! via `web_scene.zig`), then the main pass (optionally 4x MSAA).
//! Zunk owns the canvas + swap-chain, so there's no surface config and
//! `beginRenderPass` / `present` wrap encoder/queue/submit on the JS
//! side. `init` takes `handle: anytype` purely to mirror the native
//! call site; the handle is unused.
//!
//! Coordinates: teak's web space is CSS pixels, the canvas backing store
//! is CSS x devicePixelRatio. The main pass maps CSS pixels to the whole
//! canvas through the screen_size uniform; scene targets are rendered at
//! device resolution (`scene_scale`) so 3D stays crisp on HiDPI.

const std = @import("std");
const teak = @import("teak");
const zunk = @import("zunk");
const web_font = @import("teak-web-font");
const glyph_atlas = @import("glyph_atlas.zig");
const text_stage = @import("text_stage.zig");
const text = @import("teak-text");
const web_scene = @import("web_scene.zig");
const scene_common = @import("scene_common.zig");
const SlotTable = @import("slot_table.zig").SlotTable;
const GrowSlotTable = @import("slot_table.zig").GrowSlotTable;
const overlay = @import("overlay.zig");

const zgpu = zunk.web.gpu;
const Vertex = teak.Vertex;
const OverlaySplit = teak.OverlaySplit;

pub const ClearColor = teak.ClearColor;
pub const TextureHandle = teak.TextureHandle;
pub const FontSpec = teak.FontSpec;
pub const FontFamily = teak.FontFamily;
pub const TextDraw = teak.TextDraw;
pub const InitOptions = teak.gpu.InitOptions;

const SHADER_SOLID = @import("teak-shaders").quad_wgsl;
const SHADER_GLYPH = @import("teak-shaders").glyph_wgsl;
const SHADER_IMAGE = @import("teak-shaders").image_wgsl;

/// Allocator for the growable image tables.
const image_gpa = std.heap.wasm_allocator;
/// Ceiling on live app images (handles are `u32`; this bounds a runaway app).
const IMAGE_MAX_SLOTS: u32 = 1 << 16;
const SCENE_VERT_BUF_CAPACITY: usize = scene_common.max_scenes * 6;

/// A draw of one textured quad (6 vertices at `vert_offset`) with its own
/// bind group — shared by the text, image and scene-composite lists.
const QuadDraw = struct {
    bind_group: zgpu.BindGroup,
    vert_offset: u32,
};

/// A sampled texture plus the bind group the text/image/scene pipelines
/// use to read it.
const Sampled = struct {
    texture: zgpu.Texture,
    view: zgpu.TextureView,
    bind_group: zgpu.BindGroup,

    fn release(self: Sampled) void {
        zgpu.release(self.bind_group);
        zgpu.release(self.view);
        zgpu.destroyTexture(self.texture);
    }
};

// ── Image cache (app-driven, growable, no eviction) ────────────────────────────────
//
// The app uploads an RGBA8 image once via `uploadImage`, stashes the
// returned handle, and emits `cmd.image(handle, ...)` each frame; it
// frees the slot with `releaseImage`. The table grows on demand up to
// 65536 live images; `uploadImage` returns TEXTURE_HANDLE_NONE (with a
// log line) only at that ceiling, and the renderer falls back to the
// tinted-placeholder quad emitted by `render/build.zig`.

const ImageCache = GrowSlotTable(Sampled, IMAGE_MAX_SLOTS);

// ── Text: glyph atlas ──────────────────────────────────────────────
//
// Glyph shaping, packing and instance building live in `text_stage.zig`
// (shared with the native core). This file owns the GPU side: R8 page
// textures, the instance buffer and one instanced draw per page per layer.

/// One atlas page on the GPU; the CPU copy lives in the `TextStage`.
const AtlasPage = struct {
    texture: zgpu.Texture,
    view: zgpu.TextureView,
    bind_group: zgpu.BindGroup,
};

/// Glyph provider: stb_truetype in wasm for every glyph the app's faces have,
/// canvas 2D (via zunk) for code points no face covers (CJK, symbols).
const WebRaster = struct {
    /// Size over speed on web: shape each run fresh (a few us per label).
    pub const shaped_run_cache = false;

    inner: text.StbttRasterizer,
    /// Scratch for one canvas-rasterized cluster (`rasterCluster` reports a
    /// larger size if it does not fit; such a glyph is skipped).
    cluster_px: [192 * 192]u8 = undefined,

    pub fn deinit(self: *WebRaster) void {
        self.inner.deinit();
    }

    pub fn shape(self: *WebRaster, t: []const u8, font: FontSpec, out: []teak.ShapedGlyph) teak.ShapeResult {
        return self.inner.shape(t, font, out);
    }

    pub fn ascent(self: *WebRaster, font: FontSpec, scale: f32) f32 {
        return self.inner.ascent(font, scale);
    }

    pub fn epoch(self: *const WebRaster) u64 {
        return self.inner.epoch();
    }

    pub fn rasterizeGlyph(self: *WebRaster, face: u16, gid: u16, size_px: f32, bin: u2) ?text.GlyphBitmap {
        return self.inner.rasterizeGlyph(face, gid, size_px, bin);
    }

    /// Signed-distance glyphs (`FontSpec.scalable`): see `raster.zig`.
    pub const sdf_em = text.StbttRasterizer.sdf_em;

    pub fn rasterizeSdf(self: *WebRaster, face: u16, gid: u16) ?text.GlyphBitmap {
        return self.inner.rasterizeSdf(face, gid);
    }

    pub fn rasterizeCluster(self: *WebRaster, utf8: []const u8, font: FontSpec, size_px: f32) ?text.GlyphBitmap {
        var font_buf: [web_font.css_buf_len]u8 = undefined;
        const css = web_font.css(&font_buf, font);
        const bmp = zgpu.rasterCluster(utf8, css, size_px, &self.cluster_px);
        if (bmp.truncated) return null;
        const m = bmp.metrics;
        // zunk: pixel (0,0) is at (pen + bearing_x, baseline - bearing_y); the atlas
        // convention is y down from the baseline.
        return .{
            .pixels = bmp.pixels,
            .width = m.width,
            .height = m.height,
            .bearing_x = m.bearing_x,
            .bearing_y = -m.bearing_y,
        };
    }
};

const TextStage = text_stage.TextStage(WebRaster);

pub const Gpu = struct {
    // Solid pipeline.
    pipeline: zgpu.RenderPipeline,
    /// Built lazily for the current `vert_buf` (it is also bound as storage).
    bind_group: ?zgpu.BindGroup,
    bind_group_buf: ?zgpu.Buffer,
    /// `vert_buf_size` the bind group was built for (a reallocation can hand
    /// back the same buffer id, so the handle alone cannot show it).
    bind_group_size: u32,
    solid_bgl: zgpu.BindGroupLayout,
    uniform_buf: zgpu.Buffer,
    vert_buf: ?zgpu.Buffer,
    vert_buf_size: u32,
    vert_count: u32,
    width: u32,
    height: u32,

    /// Samples per pixel of the main pass: 1, or 4 with
    /// `InitOptions.msaa`. Every main-pass pipeline is built for it.
    samples: u32,
    msaa: ?MsaaTarget,

    // Text pipeline (instanced glyph quads from the atlas).
    glyph_pipeline: zgpu.RenderPipeline,
    glyph_bgl: zgpu.BindGroupLayout,
    /// {logical size, device scale, text gamma}; see shaders/glyph.wgsl.
    glyph_uniform_buf: zgpu.Buffer,
    glyph_sampler: zgpu.Sampler,
    /// Layout + sampler shared by the image and scene-composite pipelines.
    text_bgl: zgpu.BindGroupLayout,
    sampler: zgpu.Sampler,
    text: TextStage,
    atlas_pages: std.ArrayList(AtlasPage),
    glyph_buf: ?zgpu.Buffer,
    glyph_buf_size: u32,

    // Image pipeline. Shares `text_bgl` + `sampler` with the text path
    // since both bind {uniform, texture, sampler}. Only the shader differs
    // — `image.wgsl` modulates the texture by the tint (real RGBA), while
    image_pipeline: zgpu.RenderPipeline,
    images: ImageCache,
    image_draws: std.ArrayList(QuadDraw),
    image_verts: std.ArrayList(Vertex),
    image_vert_buf: ?zgpu.Buffer,
    image_vert_buf_size: u32,

    // 3D scenes: `scene` renders offscreen; the main pass draws each
    // target as an image-pipeline quad. Composite bind groups are cached
    // per slot and rebuilt when the slot's target is recreated.
    scene: web_scene.Renderer,
    /// Device pixels per logical (CSS) pixel, refreshed every `renderScenes`.
    scene_scale: f32,
    scene_bind_groups: [scene_common.max_scenes]?zgpu.BindGroup,
    scene_bg_gen: [scene_common.max_scenes]u32,
    scene_draws: [scene_common.max_scenes]QuadDraw,
    scene_draw_count: usize,
    scene_verts: [SCENE_VERT_BUF_CAPACITY]Vertex,
    scene_vert_count: u32,
    scene_vert_buf: ?zgpu.Buffer,
    scene_vert_buf_size: u32,

    // Overlay layering: `setOverlayStart` records where the overlay layer
    // begins in each input list; the upload loops translate that into
    // staged-record indices (`*_ov`) so the main pass draws all base content
    // before the overlay's. null = no split (draw by kind).
    overlay_split: ?OverlaySplit,
    image_ov: usize,
    scene_ov: usize,

    /// The multisampled colour target of the main pass; always the canvas's
    /// pixel size, recreated when the canvas is resized.
    const MsaaTarget = struct {
        w: u32,
        h: u32,
        texture: zgpu.Texture,
        view: zgpu.TextureView,
    };

    pub fn init(handle: anytype, width: u32, height: u32) !Gpu {
        return initWithOptions(handle, width, height, .{});
    }

    pub fn initWithOptions(_: anytype, width: u32, height: u32, options: InitOptions) !Gpu {
        const samples: u32 = if (options.msaa) scene_common.msaa_samples else 1;
        const shader = zgpu.createShaderModule(SHADER_SOLID);

        // binding 0: screen size; binding 1: the solid vertex buffer again,
        // read-only, so SDF quads can fetch their records (render/sdf.zig).
        const bgl = zgpu.createBindGroupLayout(&.{
            zgpu.BindGroupLayoutEntry.initBuffer(0, zgpu.ShaderVisibility.VERTEX, .uniform)
                .withMinSize(8),
            zgpu.BindGroupLayoutEntry.initBuffer(1, zgpu.ShaderVisibility.FRAGMENT, .read_only_storage),
        });
        const pl = zgpu.createPipelineLayout(&.{bgl});

        const attrs = [_]zgpu.VertexAttribute{
            .{ .shader_location = 0, .format = .float32x2, .offset = 0 },
            .{ .shader_location = 1, .format = .float32x4, .offset = 8 },
            .{ .shader_location = 2, .format = .float32x2, .offset = 24 },
        };
        const layouts = [_]zgpu.VertexBufferLayout{
            zgpu.VertexBufferLayout.fromSlice(@sizeOf(Vertex), .vertex, &attrs),
        };
        const pipeline = uiPipeline(pl, shader, &layouts, samples);

        const uniform_buf = zgpu.createBuffer(8, zgpu.BufferUsage.UNIFORM | zgpu.BufferUsage.COPY_DST);

        // Text + image pipelines: 3-entry BGL {uniform, texture, sampler},
        // same vertex layout as the solid pipeline; only the fragment
        // shader differs.
        const text_bgl = zgpu.createBindGroupLayout(&.{
            zgpu.BindGroupLayoutEntry.initBuffer(0, zgpu.ShaderVisibility.VERTEX, .uniform)
                .withMinSize(8),
            zgpu.BindGroupLayoutEntry.initTexture(1, zgpu.ShaderVisibility.FRAGMENT, .float),
            zgpu.BindGroupLayoutEntry.initSampler(2, zgpu.ShaderVisibility.FRAGMENT, .filtering),
        });
        const text_pl = zgpu.createPipelineLayout(&.{text_bgl});

        // Glyph pipeline: {uniform, R8 atlas page}, one instance per glyph. The
        // instance is read as raw 32-bit words (unpacked in glyph.wgsl).
        const glyph_bgl = zgpu.createBindGroupLayout(&.{
            zgpu.BindGroupLayoutEntry.initBuffer(0, zgpu.ShaderVisibility.VERTEX | zgpu.ShaderVisibility.FRAGMENT, .uniform)
                .withMinSize(16),
            zgpu.BindGroupLayoutEntry.initTexture(1, zgpu.ShaderVisibility.FRAGMENT, .float),
            zgpu.BindGroupLayoutEntry.initSampler(2, zgpu.ShaderVisibility.FRAGMENT, .filtering),
        });
        const glyph_attrs = [_]zgpu.VertexAttribute{
            .{ .shader_location = 0, .format = .float32x2, .offset = @offsetOf(glyph_atlas.GlyphInstance, "x") },
            .{ .shader_location = 1, .format = .uint32x2, .offset = @offsetOf(glyph_atlas.GlyphInstance, "w") },
            .{ .shader_location = 2, .format = .uint32, .offset = @offsetOf(glyph_atlas.GlyphInstance, "color") },
            .{ .shader_location = 3, .format = .uint32x2, .offset = @offsetOf(glyph_atlas.GlyphInstance, "clip_xy") },
            .{ .shader_location = 4, .format = .uint32, .offset = @offsetOf(glyph_atlas.GlyphInstance, "flags") },
        };
        const glyph_layouts = [_]zgpu.VertexBufferLayout{
            zgpu.VertexBufferLayout.fromSlice(@sizeOf(glyph_atlas.GlyphInstance), .instance, &glyph_attrs),
        };
        const glyph_pipeline = uiPipeline(zgpu.createPipelineLayout(&.{glyph_bgl}), zgpu.createShaderModule(SHADER_GLYPH), &glyph_layouts, samples);
        // Distance-field glyphs are sampled bilinearly (coverage glyphs use textureLoad).
        const glyph_sampler = zgpu.createSampler(.{
            .mag_filter = .linear,
            .min_filter = .linear,
            .address_u = .clamp_to_edge,
            .address_v = .clamp_to_edge,
            .address_w = .clamp_to_edge,
        });
        const glyph_uniform_buf = zgpu.createBuffer(16, zgpu.BufferUsage.UNIFORM | zgpu.BufferUsage.COPY_DST);
        const image_pipeline = uiPipeline(text_pl, zgpu.createShaderModule(SHADER_IMAGE), &layouts, samples);

        const sampler = zgpu.createSampler(.{
            .mag_filter = .nearest,
            .min_filter = .linear,
            .address_u = .clamp_to_edge,
            .address_v = .clamp_to_edge,
            .address_w = .clamp_to_edge,
        });

        const web_text = try TextStage.init(
            std.heap.wasm_allocator,
            .{ .inner = try text.StbttRasterizer.init(std.heap.wasm_allocator) },
            options.max_atlas_pages,
            1,
        );

        var self: Gpu = .{
            .pipeline = pipeline,
            .bind_group = null,
            .bind_group_buf = null,
            .bind_group_size = 0,
            .solid_bgl = bgl,
            .uniform_buf = uniform_buf,
            .vert_buf = null,
            .vert_buf_size = 0,
            .vert_count = 0,
            .width = width,
            .height = height,
            .samples = samples,
            .msaa = null,
            .glyph_pipeline = glyph_pipeline,
            .glyph_bgl = glyph_bgl,
            .glyph_uniform_buf = glyph_uniform_buf,
            .glyph_sampler = glyph_sampler,
            .text_bgl = text_bgl,
            .sampler = sampler,
            .text = web_text,
            .atlas_pages = .empty,
            .glyph_buf = null,
            .glyph_buf_size = 0,
            .image_pipeline = image_pipeline,
            .images = .{},
            .image_draws = .empty,
            .image_verts = .empty,
            .image_vert_buf = null,
            .image_vert_buf_size = 0,
            .scene = web_scene.Renderer.init(options.scene_msaa),
            .scene_scale = 1,
            .scene_bind_groups = @splat(null),
            .scene_bg_gen = @splat(0),
            .scene_draws = undefined,
            .scene_draw_count = 0,
            .scene_verts = undefined,
            .scene_vert_count = 0,
            .scene_vert_buf = null,
            .scene_vert_buf_size = 0,
            .overlay_split = null,
            .image_ov = 0,
            .scene_ov = 0,
        };
        self.writeScreenSize();
        return self;
    }

    /// Alpha-blended triangle-list pipeline into the canvas; every UI
    /// pipeline shares this shape.
    fn uiPipeline(
        layout: zgpu.PipelineLayout,
        shader: zgpu.ShaderModule,
        vertex_buffers: []const zgpu.VertexBufferLayout,
        samples: u32,
    ) zgpu.RenderPipeline {
        return zgpu.createRenderPipelineDesc(.{
            .layout = layout,
            .shader = shader,
            .vertex_entry = "vs_main",
            .fragment_entry = "fs_main",
            .vertex_buffers = vertex_buffers,
            .sample_count = samples,
        });
    }

    pub fn deinit(self: *Gpu) void {
        for (self.scene_bind_groups) |bg| if (bg) |g| zgpu.release(g);
        if (self.scene_vert_buf) |b| zgpu.bufferDestroy(b);
        self.scene.deinit();

        var images = self.images.iterator();
        while (images.next()) |e| e.release();
        self.images.deinit(image_gpa);
        self.image_draws.deinit(image_gpa);
        self.image_verts.deinit(image_gpa);
        for (self.atlas_pages.items) |pg| {
            zgpu.release(pg.bind_group);
            zgpu.release(pg.view);
            zgpu.destroyTexture(pg.texture);
        }
        self.atlas_pages.deinit(std.heap.wasm_allocator);
        self.text.deinit();
        if (self.glyph_buf) |gb| zgpu.bufferDestroy(gb);
        zgpu.bufferDestroy(self.glyph_uniform_buf);
        zgpu.destroySampler(self.glyph_sampler);
        zgpu.destroySampler(self.sampler);
        if (self.image_vert_buf) |ib| zgpu.bufferDestroy(ib);
        if (self.vert_buf) |vb| zgpu.bufferDestroy(vb);
        if (self.bind_group) |bg| zgpu.release(bg);
        zgpu.bufferDestroy(self.uniform_buf);
        self.releaseMsaa();
    }

    pub fn resize(self: *Gpu, width: u32, height: u32) void {
        self.width = width;
        self.height = height;
        self.writeScreenSize();
    }

    fn writeScreenSize(self: *Gpu) void {
        const screen_size = [2]f32{ @floatFromInt(self.width), @floatFromInt(self.height) };
        zgpu.bufferWriteTyped(f32, self.uniform_buf, 0, &screen_size);
        self.writeGlyphUniform();
    }

    fn writeGlyphUniform(self: *Gpu) void {
        const u = [4]f32{ @floatFromInt(self.width), @floatFromInt(self.height), self.text.scale, 1.0 };
        zgpu.bufferWriteTyped(f32, self.glyph_uniform_buf, 0, &u);
    }

    /// Grow `buf` to hold `verts` and write them. Shared by the solid,
    /// text, image and scene-composite vertex streams.
    fn writeVerts(buf: *?zgpu.Buffer, size: *u32, verts: []const Vertex) void {
        writeVertsAs(zgpu.BufferUsage.VERTEX, buf, size, verts);
    }

    fn writeVertsAs(usage: u32, buf: *?zgpu.Buffer, size: *u32, verts: []const Vertex) void {
        const byte_size: u32 = @intCast(verts.len * @sizeOf(Vertex));
        if (byte_size == 0) return;
        if (buf.* == null or byte_size > size.*) {
            if (buf.*) |old| zgpu.bufferDestroy(old);
            size.* = @max(byte_size, 4096);
            buf.* = zgpu.createBuffer(size.*, usage | zgpu.BufferUsage.COPY_DST);
        }
        zgpu.bufferWriteTyped(Vertex, buf.*.?, 0, verts);
    }

    /// Where the overlay layer starts in this frame's lists (from
    /// `render.buildFrame`). Call before `uploadVertices` / `uploadText` /
    /// `uploadImages` / `renderScenes`; the main pass then draws all base
    /// content (solids, images, scenes, text) before the overlay's.
    pub fn setOverlayStart(self: *Gpu, split: OverlaySplit) void {
        self.overlay_split = split;
    }

    fn splitOf(self: *const Gpu, comptime field: []const u8, len: usize) usize {
        return if (self.overlay_split) |o| @as(usize, @field(o, field)) else len;
    }

    pub fn uploadVertices(self: *Gpu, verts: []const Vertex) void {
        self.vert_count = @intCast(verts.len);
        // Also bound read-only in the fragment stage: SDF quads read their records from it.
        writeVertsAs(zgpu.BufferUsage.VERTEX | zgpu.BufferUsage.STORAGE, &self.vert_buf, &self.vert_buf_size, verts);
    }

    // ── Main pass ──────────────────────────────────────────────────

    fn releaseMsaa(self: *Gpu) void {
        if (self.msaa) |m| {
            zgpu.release(m.view);
            zgpu.destroyTexture(m.texture);
        }
        self.msaa = null;
    }

    /// The multisampled colour target matching the canvas's pixel size,
    /// created or resized on demand.
    fn msaaView(self: *Gpu) zgpu.TextureView {
        const canvas = zgpu.canvasSize();
        if (self.msaa) |m| {
            if (m.w == canvas.w and m.h == canvas.h) return m.view;
        }
        self.releaseMsaa();
        const texture = zgpu.createTextureMultisampled(
            canvas.w,
            canvas.h,
            zgpu.canvasFormat(),
            zgpu.TextureUsage.RENDER_ATTACHMENT,
            self.samples,
        );
        const view = zgpu.createTextureView(texture);
        self.msaa = .{ .w = canvas.w, .h = canvas.h, .texture = texture, .view = view };
        return view;
    }

    pub fn renderFrame(self: *Gpu, clear_color: ClearColor) void {
        const pass = if (self.samples > 1)
            // Draw into the multisampled target, resolve into the canvas,
            // discard the samples.
            zgpu.beginRenderPassDesc(.{
                .color = self.msaaView(),
                .resolve = zgpu.canvasView(),
                .color_store = .discard,
                .clear = clear_color,
            })
        else
            zgpu.beginRenderPassDesc(.{ .clear = clear_color });

        // Base layer first, then the overlay: within a layer, solids,
        // images, scene composites (same pipeline: a scene is an image the
        // GPU rendered this frame), then text on top. Drawing the overlay's
        // solids after the base's TEXT is what lets an opaque popup hide the
        // text beneath it. Matches gpu/wgpu_core.zig's draw order.
        const solid = overlay.Range.of(self.splitOf("verts", self.vert_count), self.vert_count);
        const imgs = overlay.Range.of(self.image_ov, self.image_draws.items.len);
        const scns = overlay.Range.of(self.scene_ov, self.scene_draw_count);
        inline for (.{ "base", "overlay" }) |layer| {
            self.drawSolids(pass, @field(overlay.Range, layer)(solid));
            drawQuads(pass, self.image_pipeline, self.image_vert_buf, @intCast(self.image_verts.items.len), self.image_draws.items, @field(overlay.Range, layer)(imgs));
            drawQuads(pass, self.image_pipeline, self.scene_vert_buf, self.scene_vert_count, self.scene_draws[0..self.scene_draw_count], @field(overlay.Range, layer)(scns));
            self.drawGlyphs(pass, if (comptime std.mem.eql(u8, layer, "base")) 0 else 1);
        }

        zgpu.renderPassEnd(pass);
        zgpu.present();
    }

    /// Solid quads `[from, to)` (vertex indices).
    /// {screen size, solid vertex buffer as read-only storage}, rebuilt
    /// whenever `vert_buf` is reallocated.
    fn rebuildSolidBindGroup(self: *Gpu) void {
        if (self.bind_group) |old| zgpu.release(old);
        self.bind_group = zgpu.createBindGroup(self.solid_bgl, &.{
            zgpu.BindGroupEntry.initBufferFull(0, self.uniform_buf, 8),
            zgpu.BindGroupEntry.initBufferFull(1, self.vert_buf.?, self.vert_buf_size),
        });
        self.bind_group_buf = self.vert_buf;
        self.bind_group_size = self.vert_buf_size;
    }

    fn drawSolids(self: *Gpu, pass: zgpu.RenderPassEncoder, range: struct { usize, usize }) void {
        const from, const to = range;
        if (to <= from or self.vert_buf == null) return;
        const draw_bytes: u64 = @as(u64, self.vert_count) * @sizeOf(Vertex);
        if (self.bind_group_buf == null or self.bind_group_buf.? != self.vert_buf.? or self.bind_group_size != self.vert_buf_size) self.rebuildSolidBindGroup();
        zgpu.renderPassSetPipeline(pass, self.pipeline);
        zgpu.renderPassSetBindGroup(pass, 0, self.bind_group.?);
        zgpu.renderPassSetVertexBuffer(pass, 0, self.vert_buf.?, 0, draw_bytes);
        zgpu.renderPassDraw(pass, @intCast(to - from), 1, @intCast(from), 0);
    }

    /// The staged textured-quad `all[from..to]`, vertices in `vert_buf`.
    fn drawQuads(
        pass: zgpu.RenderPassEncoder,
        pipeline: zgpu.RenderPipeline,
        vert_buf: ?zgpu.Buffer,
        vert_count: u32,
        all: []const QuadDraw,
        range: struct { usize, usize },
    ) void {
        const from, const to = range;
        const draws = all[from..to];
        if (draws.len == 0 or vert_buf == null) return;
        const bytes: u64 = @as(u64, vert_count) * @sizeOf(Vertex);
        zgpu.renderPassSetPipeline(pass, pipeline);
        zgpu.renderPassSetVertexBuffer(pass, 0, vert_buf.?, 0, bytes);
        for (draws) |rec| {
            zgpu.renderPassSetBindGroup(pass, 0, rec.bind_group);
            zgpu.renderPassDraw(pass, 6, 1, rec.vert_offset, 0);
        }
    }

    // ── Sampled textures (text glyph runs, images) ─────────────────

    /// Bind group for sampling `view` through the text/image pipelines:
    /// {screen-size uniform, texture, sampler}.
    fn textureBindGroup(self: *Gpu, view: zgpu.TextureView) zgpu.BindGroup {
        return zgpu.createBindGroup(self.text_bgl, &.{
            zgpu.BindGroupEntry.initBufferFull(0, self.uniform_buf, 8),
            zgpu.BindGroupEntry.initTextureView(1, view),
            zgpu.BindGroupEntry.initSampler(2, self.sampler),
        });
    }

    fn sampledFrom(self: *Gpu, texture: zgpu.Texture) Sampled {
        const view = zgpu.createTextureView(texture);
        return .{ .texture = texture, .view = view, .bind_group = self.textureBindGroup(view) };
    }

    // ── Text: shaped glyphs -> atlas -> instanced quads ────────────

    /// Per-frame text staging (call after `uploadVertices`, before
    /// `renderFrame`): `text_stage` shapes and packs, this uploads the dirty
    /// atlas rects and the instances. Atlas exhaustion is reported through
    /// `text.dropped` (the web build has no logger).
    pub fn uploadText(self: *Gpu, draws: []const TextDraw) void {
        // CSS px -> canvas device px; the atlas is rasterized at the device size.
        const canvas = zgpu.canvasSize();
        const scale: f32 = if (self.width > 0) @as(f32, @floatFromInt(canvas.w)) / @as(f32, @floatFromInt(self.width)) else 1;
        if (scale != self.text.scale) {
            self.text.scale = scale;
            self.writeGlyphUniform();
        }
        self.text.stage(draws, self.splitOf("text", draws.len));
        self.flushGlyphs();
    }

    fn ensurePages(self: *Gpu) void {
        while (self.atlas_pages.items.len < self.text.pageCount()) {
            const texture = zgpu.createTexture(
                text_stage.atlas_dim,
                text_stage.atlas_dim,
                .r8unorm,
                zgpu.TextureUsage.TEXTURE_BINDING | zgpu.TextureUsage.COPY_DST,
            );
            const view = zgpu.createTextureView(texture);
            const bg = zgpu.createBindGroup(self.glyph_bgl, &.{
                zgpu.BindGroupEntry.initBufferFull(0, self.glyph_uniform_buf, 16),
                zgpu.BindGroupEntry.initTextureView(1, view),
                zgpu.BindGroupEntry.initSampler(2, self.glyph_sampler),
            });
            self.atlas_pages.append(std.heap.wasm_allocator, .{ .texture = texture, .view = view, .bind_group = bg }) catch return;
        }
    }

    fn flushGlyphs(self: *Gpu) void {
        self.ensurePages();
        for (self.atlas_pages.items, 0..) |pg, i| {
            if (i >= self.text.pageCount()) break;
            const d = self.text.takeDirty(i) orelse continue;
            const staging = self.text.pageStaging(i);
            const start = @as(usize, d.y) * text_stage.atlas_dim + d.x;
            const len = (@as(usize, d.h) - 1) * text_stage.atlas_dim + d.w;
            zgpu.writeTextureRegion(pg.texture, d.x, d.y, d.w, d.h, staging[start..][0..len], text_stage.atlas_dim);
        }

        const total = self.text.finish();
        if (total == 0) return;
        const stride = @sizeOf(glyph_atlas.GlyphInstance);
        const bytes: u32 = total * stride;
        if (self.glyph_buf == null or bytes > self.glyph_buf_size) {
            if (self.glyph_buf) |old| zgpu.bufferDestroy(old);
            // Grow geometrically so a scrolling frame does not reallocate every frame.
            self.glyph_buf_size = @max(bytes + bytes / 2, 4096);
            self.glyph_buf = zgpu.createBuffer(self.glyph_buf_size, zgpu.BufferUsage.VERTEX | zgpu.BufferUsage.COPY_DST);
        }
        for (0..2) |layer| {
            for (self.text.insts.items) |*pi| {
                const list = pi.list[layer].items;
                if (list.len == 0) continue;
                zgpu.bufferWriteTyped(glyph_atlas.GlyphInstance, self.glyph_buf.?, pi.first[layer] * stride, list);
            }
        }
    }

    /// One instanced draw per atlas page holding glyphs of `layer`.
    fn drawGlyphs(self: *Gpu, pass: zgpu.RenderPassEncoder, layer: usize) void {
        const buf = self.glyph_buf orelse return;
        var bound = false;
        for (self.text.insts.items, 0..) |pi, i| {
            const n = pi.list[layer].items.len;
            if (n == 0 or i >= self.atlas_pages.items.len) continue;
            if (!bound) {
                zgpu.renderPassSetPipeline(pass, self.glyph_pipeline);
                zgpu.renderPassSetVertexBuffer(pass, 0, buf, 0, self.glyph_buf_size);
                bound = true;
            }
            zgpu.renderPassSetBindGroup(pass, 0, self.atlas_pages.items[i].bind_group);
            zgpu.renderPassDraw(pass, 6, @intCast(n), 0, pi.first[layer]);
        }
    }

    /// Upload an RGBA8 image. `bytes.len` must equal `width * height * 4`.
    /// Returns an opaque handle (slot index + 1) the app stashes in
    /// `ImageCmd.handle`. Returns `TEXTURE_HANDLE_NONE` on bad dims or at
    /// the 65536-image ceiling (the cache grows on demand) — the renderer
    /// falls back to a tinted-placeholder quad so apps still render.
    pub fn uploadImage(self: *Gpu, bytes: []const u8, width: u32, height: u32) TextureHandle {
        if (width == 0 or height == 0) return teak.TEXTURE_HANDLE_NONE;
        const need = @as(usize, width) * @as(usize, height) * 4;
        if (bytes.len < need) return teak.TEXTURE_HANDLE_NONE;

        const texture = zgpu.createTexture(width, height, .rgba8unorm, zgpu.TextureUsage.TEXTURE_BINDING | zgpu.TextureUsage.COPY_DST);
        zgpu.writeTexture(texture, bytes[0..need], width * 4, width, height);
        const sampled = self.sampledFrom(texture);
        return self.images.insert(image_gpa, sampled) orelse {
            sampled.release();
            return teak.TEXTURE_HANDLE_NONE;
        };
    }

    /// Read-only view of the image table for the scene renderer's sprites.
    const ImageLookup = struct {
        cache: *ImageCache,
        pub fn hasImage(self: ImageLookup, handle: u32) bool {
            return self.cache.get(handle) != null;
        }
        pub fn viewOf(self: ImageLookup, handle: u32) ?zgpu.TextureView {
            return (self.cache.get(handle) orelse return null).view;
        }
    };

    fn imageLookup(self: *Gpu) ImageLookup {
        return .{ .cache = &self.images };
    }

    /// Free an image uploaded with `uploadImage`. The handle (and any
    /// `ImageDraw` still carrying it) is dead afterwards; the slot is
    /// reused by the next upload. Call between frames, never while a
    /// frame recorded with the image is still unpresented.
    pub fn releaseImage(self: *Gpu, handle: TextureHandle) void {
        if (self.images.remove(image_gpa, handle)) |e| e.release();
    }

    /// Per-frame draw orchestration for images. Walks ImageDraws, emits 6
    /// textured vertices per visible draw, records a draw entry per image.
    /// Call after `uploadText` and before `renderFrame`. Matches
    /// gpu/wgpu_core.zig structurally so the two backends produce
    /// identical per-frame draw lists.
    pub fn uploadImages(self: *Gpu, draws: []const teak.ImageDraw) void {
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

        writeVerts(&self.image_vert_buf, &self.image_vert_buf_size, self.image_verts.items);
    }

    // ── 3D scenes ──────────────────────────────────────────────────

    /// Upload mesh geometry; the returned handle goes into
    /// `SceneDraw.mesh`. `MESH_HANDLE_NONE` on invalid data or a full
    /// table. Release meshes between frames (see `releaseImage`).
    pub fn uploadMesh(self: *Gpu, data: teak.MeshData) teak.MeshHandle {
        return self.scene.uploadMesh(data);
    }

    pub fn releaseMesh(self: *Gpu, handle: teak.MeshHandle) void {
        self.scene.releaseMesh(handle);
    }

    /// Render each scene into its offscreen target (recorded into this
    /// frame's encoder, ahead of the main pass) and stage a composite quad
    /// per visible scene for the next `renderFrame`. Call after
    /// `uploadImages`, before `renderFrame`. Scenes whose content did not
    /// change since the last frame are not redrawn.
    pub fn renderScenes(self: *Gpu, draws: []const teak.SceneDraw, data: teak.SceneData) void {
        self.scene_draw_count = 0;
        self.scene_vert_count = 0;
        var mark: overlay.Marker = .{ .start = self.splitOf("scenes", draws.len) };
        defer self.scene_ov = mark.finish(self.scene_draw_count);
        if (draws.len == 0) return;

        // Logical (CSS) pixels -> device pixels of the canvas.
        const canvas = zgpu.canvasSize();
        self.scene_scale = if (self.width > 0)
            @as(f32, @floatFromInt(canvas.w)) / @as(f32, @floatFromInt(self.width))
        else
            1;
        const scale = self.scene_scale;

        for (draws[0..@min(draws.len, scene_common.max_scenes)], 0..) |draw, i| {
            mark.visit(i, self.scene_draw_count);
            const size = self.scene.renderInto(i, draw, scene_common.itemsOf(draw, data.items), scene_common.spritesOf(draw, data.sprites), self.imageLookup(), scale) orelse continue;
            const quad = scene_common.compositeQuad(draw, size, scale) orelse continue;
            const bind_group = self.sceneBindGroup(i) orelse continue;

            const offset = self.scene_vert_count;
            @memcpy(self.scene_verts[offset..][0..6], &quad);
            self.scene_vert_count += 6;
            self.scene_draws[self.scene_draw_count] = .{ .bind_group = bind_group, .vert_offset = offset };
            self.scene_draw_count += 1;
        }

        writeVerts(&self.scene_vert_buf, &self.scene_vert_buf_size, self.scene_verts[0..self.scene_vert_count]);
    }

    /// Composite bind group for scene slot `i`, rebuilt whenever the
    /// slot's target was recreated.
    fn sceneBindGroup(self: *Gpu, i: usize) ?zgpu.BindGroup {
        const target = self.scene.target(i) orelse return null;
        if (self.scene_bind_groups[i]) |bg| {
            if (self.scene_bg_gen[i] == target.generation) return bg;
            zgpu.release(bg);
        }
        const bg = self.textureBindGroup(target.color_view);
        self.scene_bind_groups[i] = bg;
        self.scene_bg_gen[i] = target.generation;
        return bg;
    }
};

comptime {
    teak.validateGpu(Gpu);
}
