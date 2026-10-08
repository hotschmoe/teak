//! WebGPU backend via zunk. Mirrors `gpu/wgpu_core.zig`'s pipeline shape —
//! shared wgsl shaders, same Vertex layout, same screen_size uniform,
//! same solid / text / image pipelines with a matching glyph cache, and
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
const glyph_cache = @import("glyph_cache.zig");
const web_scene = @import("web_scene.zig");
const scene_common = @import("scene_common.zig");
const SlotTable = @import("slot_table.zig").SlotTable;
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
const SHADER_TEXT = @import("teak-shaders").textured_quad_wgsl;
const SHADER_IMAGE = @import("teak-shaders").image_wgsl;

const IMAGE_CACHE_CAPACITY: usize = 64;
const IMAGE_VERT_BUF_CAPACITY: usize = IMAGE_CACHE_CAPACITY * 6;
const SCENE_VERT_BUF_CAPACITY: usize = scene_common.max_scenes * 6;
const TEXT_VERT_BUF_CAPACITY: usize = glyph_cache.CAPACITY * 6;

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

// ── Image cache (app-driven, no LRU) ────────────────────────────────
//
// The app uploads an RGBA8 image once via `uploadImage`, stashes the
// returned handle, and emits `cmd.image(handle, ...)` each frame; it
// frees the slot with `releaseImage`. A fixed 64-slot table keeps the
// memory budget bounded; `uploadImage` returns TEXTURE_HANDLE_NONE once
// full and the renderer falls back to the tinted-placeholder quad
// emitted by `render/build.zig`.

const ImageCache = SlotTable(Sampled, IMAGE_CACHE_CAPACITY);

// ── Text cache ─────────────────────────────────────────────────────
//
// Layout, LRU, keying shared with gpu/wgpu_core.zig via
// `glyph_cache.GlyphCache(Backend)`. Only the resource types differ.

const WebBackend = struct {
    pub const Texture = zgpu.Texture;
    pub const View = zgpu.TextureView;
    pub const BindGroup = zgpu.BindGroup;

    pub fn destroyEntry(e: anytype) void {
        zgpu.release(e.bind_group);
        zgpu.release(e.view);
        zgpu.destroyTexture(e.texture);
    }
};

const TextCache = glyph_cache.GlyphCache(WebBackend);

pub const Gpu = struct {
    // Solid pipeline.
    pipeline: zgpu.RenderPipeline,
    bind_group: zgpu.BindGroup,
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

    // Text pipeline.
    text_pipeline: zgpu.RenderPipeline,
    text_bgl: zgpu.BindGroupLayout,
    sampler: zgpu.Sampler,
    text_cache: TextCache,
    text_draws: [glyph_cache.CAPACITY]QuadDraw,
    text_draw_count: usize,
    text_verts: [TEXT_VERT_BUF_CAPACITY]Vertex,
    text_vert_count: u32,
    text_vert_buf: ?zgpu.Buffer,
    text_vert_buf_size: u32,

    // Image pipeline. Shares `text_bgl` + `sampler` with the text path
    // since both bind {uniform, texture, sampler}. Only the shader differs
    // — `image.wgsl` modulates the texture by the tint (real RGBA), while
    // `textured_quad.wgsl` modulates the alpha-only glyph by the color.
    image_pipeline: zgpu.RenderPipeline,
    images: ImageCache,
    image_draws: [IMAGE_CACHE_CAPACITY]QuadDraw,
    image_draw_count: usize,
    image_verts: [IMAGE_VERT_BUF_CAPACITY]Vertex,
    image_vert_count: u32,
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
    text_ov: usize,
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

        const bgl = zgpu.createBindGroupLayout(&.{
            zgpu.BindGroupLayoutEntry.initBuffer(0, zgpu.ShaderVisibility.VERTEX, .uniform)
                .withMinSize(8),
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
        const bind_group = zgpu.createBindGroup(bgl, &.{
            zgpu.BindGroupEntry.initBufferFull(0, uniform_buf, 8),
        });

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
        const text_pipeline = uiPipeline(text_pl, zgpu.createShaderModule(SHADER_TEXT), &layouts, samples);
        const image_pipeline = uiPipeline(text_pl, zgpu.createShaderModule(SHADER_IMAGE), &layouts, samples);

        const sampler = zgpu.createSampler(.{
            .mag_filter = .nearest,
            .min_filter = .linear,
            .address_u = .clamp_to_edge,
            .address_v = .clamp_to_edge,
            .address_w = .clamp_to_edge,
        });

        var self: Gpu = .{
            .pipeline = pipeline,
            .bind_group = bind_group,
            .uniform_buf = uniform_buf,
            .vert_buf = null,
            .vert_buf_size = 0,
            .vert_count = 0,
            .width = width,
            .height = height,
            .samples = samples,
            .msaa = null,
            .text_pipeline = text_pipeline,
            .text_bgl = text_bgl,
            .sampler = sampler,
            .text_cache = .{},
            .text_draws = undefined,
            .text_draw_count = 0,
            .text_verts = undefined,
            .text_vert_count = 0,
            .text_vert_buf = null,
            .text_vert_buf_size = 0,
            .image_pipeline = image_pipeline,
            .images = .{},
            .image_draws = undefined,
            .image_draw_count = 0,
            .image_verts = undefined,
            .image_vert_count = 0,
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
            .text_ov = 0,
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
        self.text_cache.clear();
        zgpu.destroySampler(self.sampler);
        if (self.image_vert_buf) |ib| zgpu.bufferDestroy(ib);
        if (self.text_vert_buf) |tb| zgpu.bufferDestroy(tb);
        if (self.vert_buf) |vb| zgpu.bufferDestroy(vb);
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
    }

    /// Grow `buf` to hold `verts` and write them. Shared by the solid,
    /// text, image and scene-composite vertex streams.
    fn writeVerts(buf: *?zgpu.Buffer, size: *u32, verts: []const Vertex) void {
        const byte_size: u32 = @intCast(verts.len * @sizeOf(Vertex));
        if (byte_size == 0) return;
        if (buf.* == null or byte_size > size.*) {
            if (buf.*) |old| zgpu.bufferDestroy(old);
            size.* = @max(byte_size, 4096);
            buf.* = zgpu.createBuffer(size.*, zgpu.BufferUsage.VERTEX | zgpu.BufferUsage.COPY_DST);
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
        writeVerts(&self.vert_buf, &self.vert_buf_size, verts);
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
        const imgs = overlay.Range.of(self.image_ov, self.image_draw_count);
        const scns = overlay.Range.of(self.scene_ov, self.scene_draw_count);
        const txts = overlay.Range.of(self.text_ov, self.text_draw_count);
        inline for (.{ "base", "overlay" }) |layer| {
            self.drawSolids(pass, @field(overlay.Range, layer)(solid));
            drawQuads(pass, self.image_pipeline, self.image_vert_buf, self.image_vert_count, self.image_draws[0..self.image_draw_count], @field(overlay.Range, layer)(imgs));
            drawQuads(pass, self.image_pipeline, self.scene_vert_buf, self.scene_vert_count, self.scene_draws[0..self.scene_draw_count], @field(overlay.Range, layer)(scns));
            drawQuads(pass, self.text_pipeline, self.text_vert_buf, self.text_vert_count, self.text_draws[0..self.text_draw_count], @field(overlay.Range, layer)(txts));
        }

        zgpu.renderPassEnd(pass);
        zgpu.present();
    }

    /// Solid quads `[from, to)` (vertex indices).
    fn drawSolids(self: *Gpu, pass: zgpu.RenderPassEncoder, range: struct { usize, usize }) void {
        const from, const to = range;
        if (to <= from or self.vert_buf == null) return;
        const draw_bytes: u64 = @as(u64, self.vert_count) * @sizeOf(Vertex);
        zgpu.renderPassSetPipeline(pass, self.pipeline);
        zgpu.renderPassSetBindGroup(pass, 0, self.bind_group);
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

    /// Rasterize `text_bytes` into an rgba8unorm texture `width × height`
    /// via zunk's canvas 2D shaper, return a `TextureHandle = (cache
    /// slot + 1)` so 0 stays the sentinel. Cache-aware: repeated calls
    /// with the same (content, font, color, w, h) reuse the existing
    /// texture + bind group. LRU-evicts by `last_used_frame` when full.
    pub fn rasterizeText(
        self: *Gpu,
        text_bytes: []const u8,
        font: FontSpec,
        color: [4]f32,
        width: u32,
        height: u32,
    ) TextureHandle {
        if (width == 0 or height == 0) return teak.TEXTURE_HANDLE_NONE;

        const key = glyph_cache.textCacheKey(text_bytes, font, color, width, height);
        const content_hash = std.hash.Wyhash.hash(0, text_bytes);

        const hit = self.text_cache.lookup(key, text_bytes.len, content_hash);
        if (hit != teak.TEXTURE_HANDLE_NONE) return hit;

        self.text_cache.evictLRU();

        var font_buf: [web_font.css_buf_len]u8 = undefined;
        const css = web_font.css(&font_buf, font);

        const sampled = self.sampledFrom(zgpu.rasterizeText(text_bytes, css, font.letter_spacing, color, width, height));
        return self.text_cache.insert(
            key,
            @intCast(text_bytes.len),
            content_hash,
            sampled.texture,
            sampled.view,
            sampled.bind_group,
        );
    }

    /// Per-frame text orchestration. Rasterizes each TextDraw (with
    /// cache), emits 6 textured vertices per visible draw, records a
    /// draw entry for `renderFrame`'s text pass. Must be called after
    /// `uploadVertices` and before `renderFrame`.
    pub fn uploadText(self: *Gpu, draws: []const TextDraw) void {
        self.text_cache.tick();
        self.text_draw_count = 0;
        self.text_vert_count = 0;
        var mark: overlay.Marker = .{ .start = self.splitOf("text", draws.len) };
        defer self.text_ov = mark.finish(self.text_draw_count);

        for (draws, 0..) |draw, di| {
            mark.visit(di, self.text_draw_count);
            // Snap rect + clip to integer pixel boundaries FIRST, then
            // derive visibility + UVs from the snapped coordinates (see
            // native.zig for the full rationale — edge-repeat bleed on
            // glyph rects otherwise).
            const r_x = @floor(draw.rect_x);
            const r_y = @floor(draw.rect_y);
            const r_w = @ceil(draw.rect_x + draw.rect_w) - r_x;
            const r_h = @ceil(draw.rect_y + draw.rect_h) - r_y;

            const c_x0 = @floor(draw.clip_x);
            const c_y0 = @floor(draw.clip_y);
            const c_x1 = @ceil(draw.clip_x + draw.clip_w);
            const c_y1 = @ceil(draw.clip_y + draw.clip_h);

            const vis_x0 = @max(r_x, c_x0);
            const vis_y0 = @max(r_y, c_y0);
            const vis_x1 = @min(r_x + r_w, c_x1);
            const vis_y1 = @min(r_y + r_h, c_y1);
            if (vis_x1 <= vis_x0 or vis_y1 <= vis_y0) continue;

            const tex_w: u32 = @intFromFloat(r_w);
            const tex_h: u32 = @intFromFloat(r_h);
            if (tex_w == 0 or tex_h == 0) continue;

            const handle = self.rasterizeText(draw.content, draw.font, draw.color, tex_w, tex_h);
            if (handle == teak.TEXTURE_HANDLE_NONE) continue;
            const entry = self.text_cache.entryPtr(handle);

            const uv_u0 = (vis_x0 - r_x) / r_w;
            const uv_v0 = (vis_y0 - r_y) / r_h;
            const uv_u1 = (vis_x1 - r_x) / r_w;
            const uv_v1 = (vis_y1 - r_y) / r_h;

            const r = draw.color[0];
            const g = draw.color[1];
            const b = draw.color[2];
            const a = draw.color[3];

            const offset = self.text_vert_count;
            if (offset + 6 > self.text_verts.len) break;

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

        writeVerts(&self.text_vert_buf, &self.text_vert_buf_size, self.text_verts[0..self.text_vert_count]);
    }

    /// Upload an RGBA8 image. `bytes.len` must equal `width * height * 4`.
    /// Returns an opaque handle (slot index + 1) the app stashes in
    /// `ImageCmd.handle`. Returns `TEXTURE_HANDLE_NONE` on bad dims or
    /// when the 64-slot cache is full — the renderer falls back to a
    /// tinted-placeholder quad in either case so apps still render.
    pub fn uploadImage(self: *Gpu, bytes: []const u8, width: u32, height: u32) TextureHandle {
        if (width == 0 or height == 0) return teak.TEXTURE_HANDLE_NONE;
        const need = @as(usize, width) * @as(usize, height) * 4;
        if (bytes.len < need) return teak.TEXTURE_HANDLE_NONE;

        const texture = zgpu.createTexture(width, height, .rgba8unorm, zgpu.TextureUsage.TEXTURE_BINDING | zgpu.TextureUsage.COPY_DST);
        zgpu.writeTexture(texture, bytes[0..need], width * 4, width, height);
        const sampled = self.sampledFrom(texture);
        return self.images.insert(sampled) orelse {
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
        if (self.images.remove(handle)) |e| e.release();
    }

    /// Per-frame draw orchestration for images. Walks ImageDraws, emits 6
    /// textured vertices per visible draw, records a draw entry per image.
    /// Call after `uploadText` and before `renderFrame`. Matches
    /// gpu/wgpu_core.zig structurally so the two backends produce
    /// identical per-frame draw lists.
    pub fn uploadImages(self: *Gpu, draws: []const teak.ImageDraw) void {
        self.image_draw_count = 0;
        self.image_vert_count = 0;
        var mark: overlay.Marker = .{ .start = self.splitOf("images", draws.len) };
        defer self.image_ov = mark.finish(self.image_draw_count);

        for (draws, 0..) |draw, di| {
            mark.visit(di, self.image_draw_count);
            const entry = self.images.get(draw.handle) orelse continue;
            const quad = teak.vertex.clippedTexturedQuad(
                .{ .x = draw.rect_x, .y = draw.rect_y, .w = draw.rect_w, .h = draw.rect_h },
                .{ .x = draw.clip_x, .y = draw.clip_y, .w = draw.clip_w, .h = draw.clip_h },
                draw.tint,
            ) orelse continue;

            const offset = self.image_vert_count;
            if (offset + 6 > self.image_verts.len) break;
            @memcpy(self.image_verts[offset..][0..6], &quad);
            self.image_vert_count += 6;
            self.image_draws[self.image_draw_count] = .{ .bind_group = entry.bind_group, .vert_offset = offset };
            self.image_draw_count += 1;
        }

        writeVerts(&self.image_vert_buf, &self.image_vert_buf_size, self.image_verts[0..self.image_vert_count]);
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
