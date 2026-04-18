//! WebGPU backend via zunk. Mirrors `gpu/native.zig`'s pipeline shape —
//! shared wgsl shader, same 32-byte Vertex layout (pos/color/uv at
//! offsets 0/8/24), same uniform buffer carrying `screen_size: vec2f`.
//!
//! Differences from native:
//!   * No surface config — zunk wires the canvas as the render target.
//!   * No encoder/queue/submit plumbing — `beginRenderPass` and
//!     `present()` wrap that on zunk's JS side.
//!   * `resize` just updates the uniform; zunk handles swap-chain.
//!
//! `init` takes `handle: anytype` so the example's call site
//! (`Gpu.init(host.nativeHandle(), w, h)`) matches the native backend —
//! the handle is unused here (zunk already owns the device + canvas).

const std = @import("std");
const teak = @import("teak");
const zunk = @import("zunk");

const zgpu = zunk.web.gpu;
const Vertex = teak.Vertex;

pub const ClearColor = teak.ClearColor;

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

        const bgl_entries = [_]zgpu.BindGroupLayoutEntry{
            zgpu.BindGroupLayoutEntry.initBuffer(0, zgpu.ShaderVisibility.VERTEX, .uniform)
                .withMinSize(8),
        };
        const bgl = zgpu.createBindGroupLayout(&bgl_entries);

        const pl_layouts = [_]zgpu.BindGroupLayout{bgl};
        const pl = zgpu.createPipelineLayout(&pl_layouts);

        const attrs = [_]zgpu.VertexAttribute{
            zgpu.VertexAttribute.init(0, .float32x2, 0),
            zgpu.VertexAttribute.init(1, .float32x4, 8),
            zgpu.VertexAttribute.init(2, .float32x2, 24),
        };
        const layouts = [_]zgpu.VertexBufferLayout{
            zgpu.VertexBufferLayout.init(@sizeOf(Vertex), .vertex, &attrs),
        };
        const pipeline = zgpu.createRenderPipeline(pl, shader, "vs_main", "fs_main", &layouts);

        const uniform_buf = zgpu.createBuffer(8, zgpu.BufferUsage.UNIFORM | zgpu.BufferUsage.COPY_DST);

        const bg_entries = [_]zgpu.BindGroupEntry{
            zgpu.BindGroupEntry.initBufferFull(0, uniform_buf, 8),
        };
        const bind_group = zgpu.createBindGroup(bgl, &bg_entries);

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
};

comptime {
    teak.validateGpu(Gpu);
}
