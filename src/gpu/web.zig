//! WebGPU backend via zunk. Mirrors `gpu/native.zig`'s pipeline shape —
//! shared wgsl shader, same Vertex layout, same screen_size uniform.
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

const SHADER_CODE = @import("teak-shaders").quad_wgsl;

pub const Gpu = struct {
    pipeline: zgpu.RenderPipeline,
    bind_group: zgpu.BindGroup,
    uniform_buf: zgpu.Buffer,
    vert_buf: ?zgpu.Buffer,
    vert_buf_size: u32,
    vert_count: u32,
    width: u32,
    height: u32,

    pub fn init(_: anytype, width: u32, height: u32) !Gpu {
        const shader = zgpu.createShaderModule(SHADER_CODE);

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

        var self: Gpu = .{
            .pipeline = pipeline,
            .bind_group = bind_group,
            .uniform_buf = uniform_buf,
            .vert_buf = null,
            .vert_buf_size = 0,
            .vert_count = 0,
            .width = width,
            .height = height,
        };
        self.writeScreenSize();
        return self;
    }

    pub fn deinit(_: *Gpu) void {}

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

        zgpu.renderPassEnd(pass);
        zgpu.present();
    }

    /// WS1 stub — returns the sentinel "no texture" handle. WS4 replaces
    /// with `zgpu.rasterizeText(...)` wiring.
    pub fn rasterizeText(
        _: *Gpu,
        _: []const u8,
        _: FontSpec,
        _: [4]f32,
        _: u32,
        _: u32,
    ) TextureHandle {
        return teak.TEXTURE_HANDLE_NONE;
    }
};

comptime {
    teak.validateGpu(Gpu);
}
