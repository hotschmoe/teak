//! WebGPU backend via zunk. Mirrors `gpu/native.zig`'s pipeline shape —
//! shared wgsl shaders, same Vertex layout, same screen_size uniform,
//! same two-pipeline (solid + text) split with matching glyph cache.
//! Zunk owns the canvas + swap-chain, so there's no surface config and
//! `beginRenderPass` / `present` wrap encoder/queue/submit on the JS
//! side. `init` takes `handle: anytype` purely to mirror the native
//! call site; the handle is unused.

const std = @import("std");
const teak = @import("teak");
const zunk = @import("zunk");
const glyph_cache = @import("glyph_cache.zig");

const zgpu = zunk.web.gpu;
const Vertex = teak.Vertex;

pub const ClearColor = teak.ClearColor;
pub const TextureHandle = teak.TextureHandle;
pub const FontSpec = teak.FontSpec;
pub const FontFamily = teak.FontFamily;
pub const TextDraw = teak.TextDraw;

const SHADER_SOLID = @import("teak-shaders").quad_wgsl;
const SHADER_TEXT = @import("teak-shaders").textured_quad_wgsl;
const SHADER_IMAGE = @import("teak-shaders").image_wgsl;

// ── Image cache (app-driven, no LRU; mirrors gpu/native.zig) ────────
//
// The app uploads an RGBA8 image once via `uploadImage`, stashes the
// returned handle, and emits `cmd.image(handle, ...)` each frame.
// Unlike the glyph cache there is no LRU — the app owns lifecycle. A
// fixed 64-slot table keeps the memory budget bounded; `uploadImage`
// returns TEXTURE_HANDLE_NONE once full and the renderer falls back
// to the tinted-placeholder quad emitted by `render/build.zig`.

const IMAGE_CACHE_CAPACITY: usize = 64;
const IMAGE_VERT_BUF_CAPACITY: usize = IMAGE_CACHE_CAPACITY * 6;

const ImageEntry = struct {
    texture: zgpu.Texture,
    view: zgpu.TextureView,
    bind_group: zgpu.BindGroup,
    width: u32,
    height: u32,
};

const ImageDrawRecord = struct {
    bind_group: zgpu.BindGroup,
    vert_offset: u32,
};

// ── Text cache ─────────────────────────────────────────────────────
//
// Layout, LRU, keying shared with gpu/native.zig via
// `glyph_cache.GlyphCache(Backend)`. Only destroy semantics differ:
// zunk exposes `destroyTexture` but no explicit destroy for views /
// bind groups / pipelines / BGLs — those are released when the JS
// handle table drops them. Bounded leak, documented below.

const TEXT_VERT_BUF_CAPACITY: usize = glyph_cache.CAPACITY * 6;

const WebBackend = struct {
    pub const Texture = zgpu.Texture;
    pub const View = zgpu.TextureView;
    pub const BindGroup = zgpu.BindGroup;

    pub fn destroyEntry(e: anytype) void {
        // Only the texture has an explicit destroy; views and bind
        // groups are GC'd on the JS side (see module comment).
        zgpu.destroyTexture(e.texture);
    }
};

const TextCache = glyph_cache.GlyphCache(WebBackend);

const TextDrawRecord = struct {
    bind_group: zgpu.BindGroup,
    vert_offset: u32,
};

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

    // Text pipeline.
    text_pipeline: zgpu.RenderPipeline,
    text_bgl: zgpu.BindGroupLayout,
    sampler: zgpu.Sampler,
    text_cache: TextCache,
    text_draws: [glyph_cache.CAPACITY]TextDrawRecord,
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
    image_cache: [IMAGE_CACHE_CAPACITY]ImageEntry,
    image_cache_len: usize,
    image_draws: [IMAGE_CACHE_CAPACITY]ImageDrawRecord,
    image_draw_count: usize,
    image_verts: [IMAGE_VERT_BUF_CAPACITY]Vertex,
    image_vert_count: u32,
    image_vert_buf: ?zgpu.Buffer,
    image_vert_buf_size: u32,

    pub fn init(_: anytype, width: u32, height: u32) !Gpu {
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
        const pipeline = zgpu.createRenderPipeline(pl, shader, "vs_main", "fs_main", &layouts);

        const uniform_buf = zgpu.createBuffer(8, zgpu.BufferUsage.UNIFORM | zgpu.BufferUsage.COPY_DST);

        const bind_group = zgpu.createBindGroup(bgl, &.{
            zgpu.BindGroupEntry.initBufferFull(0, uniform_buf, 8),
        });

        // ── Text pipeline: separate shader, 3-entry BGL, nearest-mag
        //    linear-min clamp-to-edge sampler. Reuses the same Vertex
        //    layout as the solid pipeline so we don't fork the attrs.
        const text_shader = zgpu.createShaderModule(SHADER_TEXT);
        const text_bgl = zgpu.createBindGroupLayout(&.{
            zgpu.BindGroupLayoutEntry.initBuffer(0, zgpu.ShaderVisibility.VERTEX, .uniform)
                .withMinSize(8),
            zgpu.BindGroupLayoutEntry.initTexture(1, zgpu.ShaderVisibility.FRAGMENT, .float),
            zgpu.BindGroupLayoutEntry.initSampler(2, zgpu.ShaderVisibility.FRAGMENT, .filtering),
        });
        const text_pl = zgpu.createPipelineLayout(&.{text_bgl});
        const text_pipeline = zgpu.createRenderPipeline(text_pl, text_shader, "vs_main", "fs_main", &layouts);

        const sampler = zgpu.createSampler(.{
            .mag_filter = .nearest,
            .min_filter = .linear,
            .address_u = .clamp_to_edge,
            .address_v = .clamp_to_edge,
            .address_w = .clamp_to_edge,
        });

        // Image pipeline reuses text BGL + sampler; only the shader
        // differs (texture * tint vs. alpha-from-texture * color).
        const image_shader = zgpu.createShaderModule(SHADER_IMAGE);
        const image_pipeline = zgpu.createRenderPipeline(text_pl, image_shader, "vs_main", "fs_main", &layouts);

        var self: Gpu = .{
            .pipeline = pipeline,
            .bind_group = bind_group,
            .uniform_buf = uniform_buf,
            .vert_buf = null,
            .vert_buf_size = 0,
            .vert_count = 0,
            .width = width,
            .height = height,
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
            .image_cache = undefined,
            .image_cache_len = 0,
            .image_draws = undefined,
            .image_draw_count = 0,
            .image_verts = undefined,
            .image_vert_count = 0,
            .image_vert_buf = null,
            .image_vert_buf_size = 0,
        };
        self.writeScreenSize();
        return self;
    }

    pub fn deinit(self: *Gpu) void {
        // Per-entry destroy semantics (texture only) live on
        // `WebBackend.destroyEntry`; see the module-level comment for
        // why zunk doesn't destroy views / bind groups / pipelines.
        self.text_cache.clear();
        for (self.image_cache[0..self.image_cache_len]) |e| {
            zgpu.destroyTexture(e.texture);
        }
        zgpu.destroySampler(self.sampler);
        if (self.image_vert_buf) |ib| zgpu.bufferDestroy(ib);
        if (self.text_vert_buf) |tb| zgpu.bufferDestroy(tb);
        if (self.vert_buf) |vb| zgpu.bufferDestroy(vb);
        zgpu.bufferDestroy(self.uniform_buf);
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

    pub fn uploadVertices(self: *Gpu, verts: []const Vertex) void {
        const byte_size: u32 = @intCast(verts.len * @sizeOf(Vertex));
        self.vert_count = @intCast(verts.len);
        if (byte_size == 0) return;

        if (self.vert_buf == null or byte_size > self.vert_buf_size) {
            if (self.vert_buf) |buf| zgpu.bufferDestroy(buf);
            self.vert_buf_size = @max(byte_size, 4096);
            self.vert_buf = zgpu.createBuffer(self.vert_buf_size, zgpu.BufferUsage.VERTEX | zgpu.BufferUsage.COPY_DST);
        }
        zgpu.bufferWriteTyped(Vertex, self.vert_buf.?, 0, verts);
    }

    pub fn renderFrame(self: *Gpu, clear_color: ClearColor) void {
        const pass = zgpu.beginRenderPass(clear_color[0], clear_color[1], clear_color[2], clear_color[3]);

        if (self.vert_count > 0 and self.vert_buf != null) {
            const draw_bytes: u64 = @intCast(self.vert_count * @sizeOf(Vertex));
            zgpu.renderPassSetPipeline(pass, self.pipeline);
            zgpu.renderPassSetBindGroup(pass, 0, self.bind_group);
            zgpu.renderPassSetVertexBuffer(pass, 0, self.vert_buf.?, 0, draw_bytes);
            zgpu.renderPassDraw(pass, self.vert_count, 1, 0, 0);
        }

        // Images before text so labels read on top of images. Matches
        // gpu/native.zig's draw order.
        if (self.image_draw_count > 0 and self.image_vert_buf != null) {
            const image_bytes: u64 = @intCast(self.image_vert_count * @sizeOf(Vertex));
            zgpu.renderPassSetPipeline(pass, self.image_pipeline);
            zgpu.renderPassSetVertexBuffer(pass, 0, self.image_vert_buf.?, 0, image_bytes);
            for (self.image_draws[0..self.image_draw_count]) |rec| {
                zgpu.renderPassSetBindGroup(pass, 0, rec.bind_group);
                zgpu.renderPassDraw(pass, 6, 1, rec.vert_offset, 0);
            }
        }

        if (self.text_draw_count > 0 and self.text_vert_buf != null) {
            const text_bytes: u64 = @intCast(self.text_vert_count * @sizeOf(Vertex));
            zgpu.renderPassSetPipeline(pass, self.text_pipeline);
            zgpu.renderPassSetVertexBuffer(pass, 0, self.text_vert_buf.?, 0, text_bytes);
            for (self.text_draws[0..self.text_draw_count]) |rec| {
                zgpu.renderPassSetBindGroup(pass, 0, rec.bind_group);
                zgpu.renderPassDraw(pass, 6, 1, rec.vert_offset, 0);
            }
        }

        zgpu.renderPassEnd(pass);
        zgpu.present();
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

        var font_buf: [32]u8 = undefined;
        const size_px: u16 = @intFromFloat(font.size_px);
        const css = std.fmt.bufPrint(&font_buf, "{d}px {s}", .{
            size_px,
            cssFontFamily(font.family),
        }) catch return teak.TEXTURE_HANDLE_NONE;

        const texture = zgpu.rasterizeText(text_bytes, css, color, width, height);
        const view = zgpu.createTextureView(texture);
        const bind_group = zgpu.createBindGroup(self.text_bgl, &.{
            zgpu.BindGroupEntry.initBufferFull(0, self.uniform_buf, 8),
            zgpu.BindGroupEntry.initTextureView(1, view),
            zgpu.BindGroupEntry.initSampler(2, self.sampler),
        });

        return self.text_cache.insert(
            key,
            @intCast(text_bytes.len),
            content_hash,
            texture,
            view,
            bind_group,
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

        for (draws) |draw| {
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

        const byte_size: u32 = @intCast(self.text_vert_count * @sizeOf(Vertex));
        if (byte_size == 0) return;

        if (self.text_vert_buf == null or byte_size > self.text_vert_buf_size) {
            if (self.text_vert_buf) |buf| zgpu.bufferDestroy(buf);
            self.text_vert_buf_size = @max(byte_size, 4096);
            self.text_vert_buf = zgpu.createBuffer(
                self.text_vert_buf_size,
                zgpu.BufferUsage.VERTEX | zgpu.BufferUsage.COPY_DST,
            );
        }
        zgpu.bufferWriteTyped(Vertex, self.text_vert_buf.?, 0, self.text_verts[0..self.text_vert_count]);
    }

    /// Upload an RGBA8 image. `bytes.len` must equal `width * height * 4`.
    /// Returns an opaque handle (slot index + 1) the app stashes in
    /// `ImageCmd.handle`. Returns `TEXTURE_HANDLE_NONE` on bad dims or
    /// when the 64-slot cache is full — the renderer falls back to a
    /// tinted-placeholder quad in either case so apps still render.
    pub fn uploadImage(self: *Gpu, bytes: []const u8, width: u32, height: u32) TextureHandle {
        if (width == 0 or height == 0) return teak.TEXTURE_HANDLE_NONE;
        if (bytes.len < @as(usize, width) * @as(usize, height) * 4) return teak.TEXTURE_HANDLE_NONE;
        if (self.image_cache_len >= self.image_cache.len) return teak.TEXTURE_HANDLE_NONE;

        const texture = zgpu.createTexture(width, height, .rgba8unorm, zgpu.TextureUsage.TEXTURE_BINDING | zgpu.TextureUsage.COPY_DST);
        zgpu.writeTexture(texture, bytes, width * 4, width, height);

        const view = zgpu.createTextureView(texture);
        const bind_group = zgpu.createBindGroup(self.text_bgl, &.{
            zgpu.BindGroupEntry.initBufferFull(0, self.uniform_buf, 8),
            zgpu.BindGroupEntry.initTextureView(1, view),
            zgpu.BindGroupEntry.initSampler(2, self.sampler),
        });

        const slot = self.image_cache_len;
        self.image_cache[slot] = .{
            .texture = texture,
            .view = view,
            .bind_group = bind_group,
            .width = width,
            .height = height,
        };
        self.image_cache_len += 1;
        return @intCast(slot + 1);
    }

    /// Per-frame draw orchestration for images. Walks ImageDraws, clips
    /// against the viewport, emits 6 textured vertices per visible draw,
    /// records a draw entry for the image pass. Call after `uploadText`
    /// and before `renderFrame`. Matches gpu/native.zig structurally so
    /// the two backends produce identical per-frame draw lists.
    pub fn uploadImages(self: *Gpu, draws: []const teak.ImageDraw) void {
        self.image_draw_count = 0;
        self.image_vert_count = 0;

        for (draws) |draw| {
            if (draw.handle == teak.TEXTURE_HANDLE_NONE) continue;
            const slot = draw.handle - 1;
            if (slot >= self.image_cache_len) continue;
            const entry = self.image_cache[slot];

            const r_x = draw.rect_x;
            const r_y = draw.rect_y;
            const r_w = draw.rect_w;
            const r_h = draw.rect_h;

            const c_x0 = draw.clip_x;
            const c_y0 = draw.clip_y;
            const c_x1 = draw.clip_x + draw.clip_w;
            const c_y1 = draw.clip_y + draw.clip_h;

            const vis_x0 = @max(r_x, c_x0);
            const vis_y0 = @max(r_y, c_y0);
            const vis_x1 = @min(r_x + r_w, c_x1);
            const vis_y1 = @min(r_y + r_h, c_y1);
            if (vis_x1 <= vis_x0 or vis_y1 <= vis_y0) continue;

            const uv_u0 = (vis_x0 - r_x) / r_w;
            const uv_v0 = (vis_y0 - r_y) / r_h;
            const uv_u1 = (vis_x1 - r_x) / r_w;
            const uv_v1 = (vis_y1 - r_y) / r_h;

            const r = draw.tint[0];
            const g = draw.tint[1];
            const b = draw.tint[2];
            const a = draw.tint[3];

            const offset = self.image_vert_count;
            if (offset + 6 > self.image_verts.len) break;

            const v = &self.image_verts;
            v[offset + 0] = .{ .x = vis_x0, .y = vis_y0, .r = r, .g = g, .b = b, .a = a, .u = uv_u0, .v = uv_v0 };
            v[offset + 1] = .{ .x = vis_x1, .y = vis_y0, .r = r, .g = g, .b = b, .a = a, .u = uv_u1, .v = uv_v0 };
            v[offset + 2] = .{ .x = vis_x0, .y = vis_y1, .r = r, .g = g, .b = b, .a = a, .u = uv_u0, .v = uv_v1 };
            v[offset + 3] = .{ .x = vis_x1, .y = vis_y0, .r = r, .g = g, .b = b, .a = a, .u = uv_u1, .v = uv_v0 };
            v[offset + 4] = .{ .x = vis_x1, .y = vis_y1, .r = r, .g = g, .b = b, .a = a, .u = uv_u1, .v = uv_v1 };
            v[offset + 5] = .{ .x = vis_x0, .y = vis_y1, .r = r, .g = g, .b = b, .a = a, .u = uv_u0, .v = uv_v1 };

            self.image_vert_count += 6;
            self.image_draws[self.image_draw_count] = .{
                .bind_group = entry.bind_group,
                .vert_offset = offset,
            };
            self.image_draw_count += 1;
        }

        const byte_size: u32 = @intCast(self.image_vert_count * @sizeOf(Vertex));
        if (byte_size == 0) return;

        if (self.image_vert_buf == null or byte_size > self.image_vert_buf_size) {
            if (self.image_vert_buf) |buf| zgpu.bufferDestroy(buf);
            self.image_vert_buf_size = @max(byte_size, 4096);
            self.image_vert_buf = zgpu.createBuffer(
                self.image_vert_buf_size,
                zgpu.BufferUsage.VERTEX | zgpu.BufferUsage.COPY_DST,
            );
        }
        zgpu.bufferWriteTyped(Vertex, self.image_vert_buf.?, 0, self.image_verts[0..self.image_vert_count]);
    }
};

fn cssFontFamily(family: FontFamily) []const u8 {
    return switch (family) {
        .sans => "sans-serif",
        .serif => "serif",
        .mono => "monospace",
    };
}

comptime {
    teak.validateGpu(Gpu);
}
