//! Web (zunk WebGPU) 3D scene renderer: the counterpart of
//! `wgpu_scene.zig`, with the same shape and the same shared logic in
//! `scene_common.zig` (uniform layout, pixel snapping, change signature),
//! so both backends render and cache identically. Passes are recorded into
//! zunk's frame encoder, so scenes drawn before the main UI pass are
//! already complete when it samples them.

const std = @import("std");
const teak = @import("teak");
const zunk = @import("zunk");
const common = @import("scene_common.zig");
const scene_pass = @import("scene_pass.zig");
const SlotTable = @import("slot_table.zig").SlotTable;
const scene_wgsl = @import("teak-shaders").scene_wgsl;

const zgpu = zunk.web.gpu;
const MeshData = teak.MeshData;
const MeshHandle = teak.MeshHandle;
const MeshVertex = teak.MeshVertex;
const LineVertex = teak.LineVertex;
const SceneDraw = teak.SceneDraw;
const TargetSize = common.TargetSize;

pub const MESH_CAPACITY: usize = 128;
pub const depth_format: zgpu.TextureFormat = .depth32float;

/// Scratch for the per-frame plan (backend code outside the framework core).
const plan_allocator = std.heap.wasm_allocator;

const MeshEntry = struct {
    vertex_buf: ?zgpu.Buffer,
    index_buf: ?zgpu.Buffer,
    line_buf: ?zgpu.Buffer,
    vertex_bytes: u32,
    index_bytes: u32,
    segment_count: u32,
    /// Bumped on every upload so a re-upload into a reused slot is a
    /// different mesh as far as `signature` is concerned.
    version: u32,

    fn release(self: MeshEntry) void {
        if (self.vertex_buf) |b| zgpu.bufferDestroy(b);
        if (self.index_buf) |b| zgpu.bufferDestroy(b);
        if (self.line_buf) |b| zgpu.bufferDestroy(b);
    }
};

/// Resources of one scene slot; `generation` changes when they are
/// recreated so the owner can refresh anything bound to `color_view`.
pub const Target = struct {
    size: TargetSize,
    color: zgpu.Texture,
    color_view: zgpu.TextureView,
    msaa: ?zgpu.Texture,
    msaa_view: ?zgpu.TextureView,
    depth: zgpu.Texture,
    depth_view: zgpu.TextureView,
    uniform_buf: zgpu.Buffer,
    bind_group: zgpu.BindGroup,
    /// Packed per-item instance records (`scene_pass.Packed`), grown on demand.
    inst_buf: ?zgpu.Buffer = null,
    inst_cap: u32 = 0,
    signature: u64,
    generation: u32,

    fn release(self: Target) void {
        if (self.inst_buf) |b| zgpu.bufferDestroy(b);
        zgpu.release(self.bind_group);
        zgpu.bufferDestroy(self.uniform_buf);
        zgpu.release(self.depth_view);
        zgpu.destroyTexture(self.depth);
        if (self.msaa_view) |v| zgpu.release(v);
        if (self.msaa) |t| zgpu.destroyTexture(t);
        zgpu.release(self.color_view);
        zgpu.destroyTexture(self.color);
    }
};

pub const Renderer = struct {
    samples: u32,
    bgl: zgpu.BindGroupLayout,
    mesh_pipeline: zgpu.RenderPipeline,
    line_pipeline: zgpu.RenderPipeline,

    meshes: SlotTable(MeshEntry, MESH_CAPACITY) = .{},
    next_version: u32 = 1,
    plan: scene_pass.Plan = .{},
    targets: [common.max_scenes]?Target = @splat(null),
    next_generation: u32 = 1,

    /// `msaa` selects 4x multisampling of scene targets. The colour target
    /// format is the canvas format, so the UI pass can sample it directly.
    pub fn init(msaa: bool) Renderer {
        const samples: u32 = if (msaa) common.msaa_samples else 1;
        const format = zgpu.canvasFormat();
        const shader = zgpu.createShaderModule(scene_wgsl);

        const bgl = zgpu.createBindGroupLayout(&.{
            zgpu.BindGroupLayoutEntry.initBuffer(0, zgpu.ShaderVisibility.VERTEX | zgpu.ShaderVisibility.FRAGMENT, .uniform)
                .withMinSize(@sizeOf(common.Globals)),
        });
        const layout = zgpu.createPipelineLayout(&.{bgl});

        const mesh_attrs = [_]zgpu.VertexAttribute{
            .{ .format = .float32x3, .offset = @offsetOf(MeshVertex, "pos"), .shader_location = 0 },
            .{ .format = .float32x3, .offset = @offsetOf(MeshVertex, "normal"), .shader_location = 1 },
            .{ .format = .float32x4, .offset = @offsetOf(MeshVertex, "color"), .shader_location = 2 },
        };
        // Per-item instance stream (`scene_pass.Packed`): per-instance for
        // triangles, stride 0 for lines so every segment of one item reads
        // the same record.
        const inst_attrs = [_]zgpu.VertexAttribute{
            .{ .format = .float32x4, .offset = 0, .shader_location = 4 },
            .{ .format = .float32x4, .offset = 16, .shader_location = 5 },
            .{ .format = .float32x4, .offset = 32, .shader_location = 6 },
            .{ .format = .float32x4, .offset = 48, .shader_location = 7 },
            .{ .format = .uint32x2, .offset = 64, .shader_location = 8 },
        };
        const mesh_layouts = [_]zgpu.VertexBufferLayout{
            zgpu.VertexBufferLayout.fromSlice(@sizeOf(MeshVertex), .vertex, &mesh_attrs),
            zgpu.VertexBufferLayout.fromSlice(@sizeOf(scene_pass.Packed), .instance, &inst_attrs),
        };
        // One instance = one segment = a pair of LineVertex.
        const line_attrs = [_]zgpu.VertexAttribute{
            .{ .format = .float32x3, .offset = @offsetOf(LineVertex, "pos"), .shader_location = 0 },
            .{ .format = .float32x4, .offset = @offsetOf(LineVertex, "color"), .shader_location = 1 },
            .{ .format = .float32x3, .offset = @sizeOf(LineVertex) + @offsetOf(LineVertex, "pos"), .shader_location = 2 },
            .{ .format = .float32x4, .offset = @sizeOf(LineVertex) + @offsetOf(LineVertex, "color"), .shader_location = 3 },
        };
        const line_layouts = [_]zgpu.VertexBufferLayout{
            zgpu.VertexBufferLayout.fromSlice(2 * @sizeOf(LineVertex), .instance, &line_attrs),
            zgpu.VertexBufferLayout.fromSlice(0, .instance, inst_attrs[0..3]),
        };

        return .{
            .samples = samples,
            .bgl = bgl,
            .mesh_pipeline = zgpu.createRenderPipelineDesc(.{
                .layout = layout,
                .shader = shader,
                .vertex_entry = "vs_mesh",
                .fragment_entry = "fs_mesh",
                .vertex_buffers = &mesh_layouts,
                .color_format = format,
                .blend = .none,
                .depth = .{ .format = depth_format },
                .sample_count = samples,
            }),
            .line_pipeline = zgpu.createRenderPipelineDesc(.{
                .layout = layout,
                .shader = shader,
                .vertex_entry = "vs_line",
                .fragment_entry = "fs_line",
                .vertex_buffers = &line_layouts,
                .color_format = format,
                .blend = .alpha,
                .depth = .{ .format = depth_format, .write_enabled = false, .compare = .less_equal },
                .sample_count = samples,
            }),
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.plan.deinit(plan_allocator);
        var it = self.meshes.iterator();
        while (it.next()) |m| m.release();
        for (self.targets) |t| if (t) |tt| tt.release();
        zgpu.release(self.line_pipeline);
        zgpu.release(self.mesh_pipeline);
        zgpu.release(self.bgl);
    }

    // ── Meshes ─────────────────────────────────────────────────────

    /// Copy `data` into GPU buffers. Returns `MESH_HANDLE_NONE` when the
    /// data is invalid or the table is full.
    pub fn uploadMesh(self: *Renderer, data: MeshData) MeshHandle {
        data.validate() catch return teak.MESH_HANDLE_NONE;
        var entry = MeshEntry{
            .vertex_buf = null,
            .index_buf = null,
            .line_buf = null,
            .vertex_bytes = 0,
            .index_bytes = 0,
            .segment_count = @intCast(data.segmentCount()),
            .version = self.next_version,
        };
        if (data.vertices.len > 0 and data.indices.len > 0) {
            entry.vertex_buf = makeBuffer(zgpu.BufferUsage.VERTEX, std.mem.sliceAsBytes(data.vertices));
            entry.index_buf = makeBuffer(zgpu.BufferUsage.INDEX, std.mem.sliceAsBytes(data.indices));
            entry.vertex_bytes = @intCast(data.vertices.len * @sizeOf(MeshVertex));
            entry.index_bytes = @intCast(data.indices.len * @sizeOf(u32));
        }
        if (entry.segment_count > 0) {
            entry.line_buf = makeBuffer(zgpu.BufferUsage.VERTEX, std.mem.sliceAsBytes(data.lines[0 .. entry.segment_count * 2]));
        }
        const handle = self.meshes.insert(entry) orelse {
            entry.release();
            return teak.MESH_HANDLE_NONE;
        };
        self.next_version +%= 1;
        return handle;
    }

    fn makeBuffer(usage: u32, bytes: []const u8) zgpu.Buffer {
        const buf = zgpu.createBuffer(@intCast(bytes.len), usage | zgpu.BufferUsage.COPY_DST);
        zgpu.bufferWrite(buf, 0, bytes);
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

    /// Make sure `t.inst_buf` holds at least `bytes`; the caller rewrites the contents.
    fn ensureInstBuf(t: *Target, bytes: u32) zgpu.Buffer {
        if (t.inst_buf) |b| {
            if (t.inst_cap >= bytes) return b;
            zgpu.bufferDestroy(b);
        }
        const cap = @max(std.math.ceilPowerOfTwo(u32, bytes) catch bytes, 16 * @sizeOf(scene_pass.Packed));
        const buf = zgpu.createBuffer(cap, zgpu.BufferUsage.VERTEX | zgpu.BufferUsage.COPY_DST);
        t.inst_buf = buf;
        t.inst_cap = cap;
        return buf;
    }

    // ── Targets ────────────────────────────────────────────────────

    pub fn target(self: *const Renderer, index: usize) ?*const Target {
        return if (self.targets[index]) |*t| t else null;
    }

    fn createTarget(self: *Renderer, size: TargetSize) Target {
        const format = zgpu.canvasFormat();
        const color = zgpu.createRenderTarget(size.w, size.h, format);
        var msaa: ?zgpu.Texture = null;
        var msaa_view: ?zgpu.TextureView = null;
        if (self.samples > 1) {
            const tex = zgpu.createTextureMultisampled(size.w, size.h, format, zgpu.TextureUsage.RENDER_ATTACHMENT, self.samples);
            msaa = tex;
            msaa_view = zgpu.createTextureView(tex);
        }
        const depth = zgpu.createDepthTexture(size.w, size.h, depth_format, self.samples);
        const uniform_buf = zgpu.createUniformBuffer(@sizeOf(common.Globals));
        const gen = self.next_generation;
        self.next_generation +%= 1;
        return .{
            .size = size,
            .color = color,
            .color_view = zgpu.createTextureView(color),
            .msaa = msaa,
            .msaa_view = msaa_view,
            .depth = depth,
            .depth_view = zgpu.createTextureView(depth),
            .uniform_buf = uniform_buf,
            .bind_group = zgpu.createBindGroup(self.bgl, &.{
                zgpu.BindGroupEntry.initBufferFull(0, uniform_buf, @sizeOf(common.Globals)),
            }),
            .signature = 0,
            .generation = gen,
        };
    }

    fn ensureTarget(self: *Renderer, index: usize, size: TargetSize) *Target {
        if (self.targets[index]) |*t| {
            if (t.size.w == size.w and t.size.h == size.h) return t;
            t.release();
        }
        self.targets[index] = self.createTarget(size);
        return &self.targets[index].?;
    }

    /// Draw `draw` into slot `index` (recorded into the frame encoder); a
    /// no-op when the slot already holds this exact picture. Returns the
    /// target size, or null if the scene has no pixels. `scale` = device
    /// pixels per logical pixel (the canvas devicePixelRatio).
    pub fn renderInto(self: *Renderer, index: usize, draw: SceneDraw, items: []const teak.SceneItem, scale: f32) ?TargetSize {
        const size = common.targetSize(draw.rect_w, draw.rect_h, scale) orelse return null;
        const t = self.ensureTarget(index, size);

        self.plan.build(plan_allocator, draw, items, self) catch return null;
        const sig = common.signature(draw, size, scale, self.plan.contentHash(self));
        if (t.signature == sig) return size;
        t.signature = sig;

        const g = common.globals(draw, size, scale);
        zgpu.bufferWriteTyped(common.Globals, t.uniform_buf, 0, &.{g});

        const multisampled = t.msaa_view != null;
        const pass = zgpu.beginRenderPassDesc(.{
            .color = t.msaa_view orelse t.color_view,
            .resolve = if (multisampled) t.color_view else null,
            .color_store = if (multisampled) .discard else .store,
            .clear = draw.clear,
            .depth = t.depth_view,
            .depth_store = .discard,
        });

        const inst_bytes: u32 = @intCast(self.plan.insts.items.len * @sizeOf(scene_pass.Packed));
        if (inst_bytes > 0) {
            const inst_buf = ensureInstBuf(t, inst_bytes);
            zgpu.bufferWrite(inst_buf, 0, std.mem.sliceAsBytes(self.plan.insts.items));
            zgpu.renderPassSetBindGroup(pass, 0, t.bind_group);
            // Triangles: one instanced draw per run of items sharing a mesh.
            zgpu.renderPassSetPipeline(pass, self.mesh_pipeline);
            for (self.plan.runs.items) |run| {
                const m = self.meshes.get(run.mesh) orelse continue;
                if (m.index_bytes == 0) continue;
                zgpu.renderPassSetVertexBuffer(pass, 0, m.vertex_buf.?, 0, m.vertex_bytes);
                zgpu.renderPassSetVertexBuffer(pass, 1, inst_buf, 0, inst_bytes);
                zgpu.renderPassSetIndexBuffer(pass, m.index_buf.?, .uint32, 0, m.index_bytes);
                zgpu.renderPassDrawIndexed(pass, m.index_bytes / @sizeOf(u32), run.count, 0, 0, run.first);
            }
            // Feature edges: one draw per item (its transform is bound at stride 0).
            zgpu.renderPassSetPipeline(pass, self.line_pipeline);
            for (self.plan.runs.items) |run| {
                const m = self.meshes.get(run.mesh) orelse continue;
                if (m.segment_count == 0) continue;
                zgpu.renderPassSetVertexBuffer(pass, 0, m.line_buf.?, 0, m.segment_count * 2 * @sizeOf(LineVertex));
                for (self.plan.insts.items[run.first..][0..run.count], run.first..) |inst, k| {
                    if (inst.flags & scene_pass.flag_no_edges != 0) continue;
                    zgpu.renderPassSetVertexBuffer(pass, 1, inst_buf, @as(u32, @intCast(k)) * @sizeOf(scene_pass.Packed), @sizeOf(scene_pass.Packed));
                    zgpu.renderPassDraw(pass, 6, m.segment_count, 0, 0);
                }
            }
        }
        zgpu.renderPassEnd(pass);
        return size;
    }
};
