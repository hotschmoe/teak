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

const zgpu = zunk.web.gpu;
const Vertex = teak.Vertex;

pub const ClearColor = teak.ClearColor;
pub const TextureHandle = teak.TextureHandle;
pub const FontSpec = teak.FontSpec;
pub const FontFamily = teak.FontFamily;
pub const TextDraw = teak.TextDraw;

const SHADER_SOLID = @import("teak-shaders").quad_wgsl;
const SHADER_TEXT = @import("teak-shaders").textured_quad_wgsl;

// ── Text cache ─────────────────────────────────────────────────────

const TEXT_CACHE_CAPACITY: usize = 256;
const TEXT_VERT_BUF_CAPACITY: usize = 256 * 6;

const TextCacheEntry = struct {
    key: u64,
    content_len: u32,
    content_hash: u64,
    texture: zgpu.Texture,
    view: zgpu.TextureView,
    bind_group: zgpu.BindGroup,
    last_used_frame: u64,
};

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
    text_cache: [TEXT_CACHE_CAPACITY]TextCacheEntry,
    text_cache_len: usize,
    text_draws: [TEXT_CACHE_CAPACITY]TextDrawRecord,
    text_draw_count: usize,
    text_verts: [TEXT_VERT_BUF_CAPACITY]Vertex,
    text_vert_count: u32,
    text_vert_buf: ?zgpu.Buffer,
    text_vert_buf_size: u32,
    frame_counter: u64,

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
            .text_cache = undefined,
            .text_cache_len = 0,
            .text_draws = undefined,
            .text_draw_count = 0,
            .text_verts = undefined,
            .text_vert_count = 0,
            .text_vert_buf = null,
            .text_vert_buf_size = 0,
            .frame_counter = 0,
        };
        self.writeScreenSize();
        return self;
    }

    pub fn deinit(self: *Gpu) void {
        // Zunk exposes destroyTexture / destroySampler but no explicit
        // destroy for texture views, bind groups, pipelines, or BGLs —
        // they're released when the JS handle table drops them. Destroy
        // only what we can; the rest are one-shot per Host lifetime so
        // the leak is bounded.
        for (self.text_cache[0..self.text_cache_len]) |*e| {
            zgpu.destroyTexture(e.texture);
        }
        zgpu.destroySampler(self.sampler);
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

        const key = textCacheKey(text_bytes, font, color, width, height);
        const content_hash = std.hash.Wyhash.hash(0, text_bytes);

        for (self.text_cache[0..self.text_cache_len], 0..) |*e, i| {
            if (e.key == key and e.content_len == text_bytes.len and e.content_hash == content_hash) {
                e.last_used_frame = self.frame_counter;
                return @intCast(i + 1);
            }
        }

        if (self.text_cache_len >= self.text_cache.len) {
            var oldest: usize = 0;
            var oldest_frame: u64 = self.text_cache[0].last_used_frame;
            for (self.text_cache[0..self.text_cache_len], 0..) |*e, i| {
                if (e.last_used_frame < oldest_frame) {
                    oldest = i;
                    oldest_frame = e.last_used_frame;
                }
            }
            zgpu.destroyTexture(self.text_cache[oldest].texture);
            self.text_cache[oldest] = self.text_cache[self.text_cache_len - 1];
            self.text_cache_len -= 1;
        }

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

        self.text_cache[self.text_cache_len] = .{
            .key = key,
            .content_len = @intCast(text_bytes.len),
            .content_hash = content_hash,
            .texture = texture,
            .view = view,
            .bind_group = bind_group,
            .last_used_frame = self.frame_counter,
        };
        self.text_cache_len += 1;
        return @intCast(self.text_cache_len);
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
            const entry = &self.text_cache[handle - 1];

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
};

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
