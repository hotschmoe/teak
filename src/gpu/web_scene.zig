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
const scene_grid_wgsl = @import("teak-shaders").scene_grid_wgsl;

const zgpu = zunk.web.gpu;
const MeshData = teak.MeshData;
const MeshHandle = teak.MeshHandle;
const MeshVertex = teak.MeshVertex;
const LineVertex = teak.LineVertex;
const SceneDraw = teak.SceneDraw;
const TargetSize = common.TargetSize;

pub const MESH_CAPACITY: usize = 128;
/// Depth + stencil: section caps use stencil parity.
pub const depth_format: zgpu.TextureFormat = .depth24plus_stencil8;

const sprite_bg_cache = 32;

/// A cached bind group for one image's texture view (rebuilt if the Gpu
/// replaced the view behind a handle).
const SpriteBg = struct { handle: u32 = 0, view: ?zgpu.TextureView = null, bg: ?zgpu.BindGroup = null };

/// An image source with nothing in it (scenes without sprites).
pub const NoImages = struct {
    pub fn hasImage(_: NoImages, _: u32) bool {
        return false;
    }
    pub fn viewOf(_: NoImages, _: u32) ?zgpu.TextureView {
        return null;
    }
};

/// One cap quad to draw: which plan instance, and where its vertices start in `Target.cap_buf`.
const CapDraw = struct { inst: u32, first_vertex: u32 };

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
    /// CPU copy of positions + indices and the model-space bounds, kept for
    /// section outlines and cap quads (GPU buffers cannot be read back).
    cpu_pos: []teak.scene.mat.Vec3 = &.{},
    cpu_idx: []u32 = &.{},
    lo: teak.scene.mat.Vec3 = .{ 0, 0, 0 },
    hi: teak.scene.mat.Vec3 = .{ 0, 0, 0 },

    fn release(self: MeshEntry) void {
        plan_allocator.free(self.cpu_pos);
        plan_allocator.free(self.cpu_idx);
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
    /// Grid pass uniforms (`scene_pass.GridUniform`) + bind group.
    grid_buf: zgpu.Buffer,
    grid_bg: zgpu.BindGroup,
    /// Gizmo pass: its own `Globals`, bind group and line-segment vertices.
    gizmo_ubo: zgpu.Buffer,
    gizmo_bg: zgpu.BindGroup,
    gizmo_lines: zgpu.Buffer,
    /// Section cut: cap quads, outline segments (+ their own `Globals`, since
    /// the outline width differs from the edge width).
    cap_buf: ?zgpu.Buffer = null,
    cap_cap: u32 = 0,
    /// Plane layers: tessellated vertices, plane records, sprite records.
    plane_vbuf: ?zgpu.Buffer = null,
    plane_vcap: u32 = 0,
    plane_ibuf: ?zgpu.Buffer = null,
    plane_icap: u32 = 0,
    sprite_buf: ?zgpu.Buffer = null,
    sprite_cap: u32 = 0,
    outline_buf: ?zgpu.Buffer = null,
    outline_cap: u32 = 0,
    outline_ubo: zgpu.Buffer,
    outline_bg: zgpu.BindGroup,
    signature: u64,
    generation: u32,

    fn release(self: Target) void {
        if (self.inst_buf) |b| zgpu.bufferDestroy(b);
        if (self.plane_vbuf) |b| zgpu.bufferDestroy(b);
        if (self.plane_ibuf) |b| zgpu.bufferDestroy(b);
        if (self.sprite_buf) |b| zgpu.bufferDestroy(b);
        if (self.cap_buf) |b| zgpu.bufferDestroy(b);
        if (self.outline_buf) |b| zgpu.bufferDestroy(b);
        zgpu.release(self.outline_bg);
        zgpu.bufferDestroy(self.outline_ubo);
        zgpu.bufferDestroy(self.gizmo_lines);
        zgpu.release(self.gizmo_bg);
        zgpu.bufferDestroy(self.gizmo_ubo);
        zgpu.release(self.grid_bg);
        zgpu.bufferDestroy(self.grid_buf);
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
    /// Line pipeline that ignores the depth buffer, for the gizmo overlay.
    gizmo_pipeline: zgpu.RenderPipeline,
    grid_bgl: zgpu.BindGroupLayout,
    grid_pipeline: zgpu.RenderPipeline,
    /// One identity `Packed` record bound at stride 0 for gizmo lines.
    ident_buf: zgpu.Buffer,
    /// Section cap: stencil-parity pre-pass (colour unchanged) + the cap quad.
    stencil_pipeline: zgpu.RenderPipeline,
    cap_pipeline: zgpu.RenderPipeline,
    /// Scratch for per-frame cut geometry (cap quads, outline segments).
    layers: scene_pass.Layers = .{},
    plane_opaque_pipeline: zgpu.RenderPipeline,
    plane_blend_pipeline: zgpu.RenderPipeline,
    sprite_pipeline: zgpu.RenderPipeline,
    sprite_bgl: zgpu.BindGroupLayout,
    sprite_sampler: zgpu.Sampler,
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

        const grid_shader = zgpu.createShaderModule(scene_grid_wgsl);
        const grid_bgl = zgpu.createBindGroupLayout(&.{
            zgpu.BindGroupLayoutEntry.initBuffer(0, zgpu.ShaderVisibility.VERTEX | zgpu.ShaderVisibility.FRAGMENT, .uniform)
                .withMinSize(@sizeOf(scene_pass.GridUniform)),
        });
        const ident_buf = makeBuffer(zgpu.BufferUsage.VERTEX, std.mem.asBytes(&scene_pass.pack(.{ .mesh = 1 })));

        // A cap vertex is a position and a colour: the `LineVertex` layout.
        const cap_attrs = [_]zgpu.VertexAttribute{
            .{ .format = .float32x3, .offset = @offsetOf(LineVertex, "pos"), .shader_location = 0 },
            .{ .format = .float32x4, .offset = @offsetOf(LineVertex, "color"), .shader_location = 1 },
        };
        const cap_layouts = [_]zgpu.VertexBufferLayout{
            zgpu.VertexBufferLayout.fromSlice(@sizeOf(LineVertex), .vertex, &cap_attrs),
        };
        const invert_face: zgpu.StencilFace = .{ .pass_op = .invert };
        const cap_face: zgpu.StencilFace = .{ .compare = .not_equal, .depth_fail_op = .zero, .pass_op = .zero };

        // Plane layers and sprites.
        const layer_inst_attrs = [_]zgpu.VertexAttribute{
            .{ .format = .float32x4, .offset = 0, .shader_location = 4 },
            .{ .format = .float32x4, .offset = 16, .shader_location = 5 },
            .{ .format = .float32x4, .offset = 32, .shader_location = 6 },
            .{ .format = .float32x4, .offset = 48, .shader_location = 7 },
            .{ .format = .uint32x2, .offset = 64, .shader_location = 8 },
            .{ .format = .sint32, .offset = 72, .shader_location = 9 },
        };
        const plane_vert_attrs = [_]zgpu.VertexAttribute{
            .{ .format = .float32x2, .offset = @offsetOf(teak.Vertex, "x"), .shader_location = 0 },
            .{ .format = .float32x4, .offset = @offsetOf(teak.Vertex, "r"), .shader_location = 1 },
        };
        const plane_layouts = [_]zgpu.VertexBufferLayout{
            zgpu.VertexBufferLayout.fromSlice(@sizeOf(teak.Vertex), .vertex, &plane_vert_attrs),
            zgpu.VertexBufferLayout.fromSlice(@sizeOf(scene_pass.LayerInst), .instance, &layer_inst_attrs),
        };
        const sprite_attrs = [_]zgpu.VertexAttribute{
            .{ .format = .float32x4, .offset = 0, .shader_location = 0 },
            .{ .format = .float32x4, .offset = 16, .shader_location = 1 },
            .{ .format = .float32x4, .offset = 32, .shader_location = 2 },
            .{ .format = .float32x4, .offset = 48, .shader_location = 3 },
            .{ .format = .float32x4, .offset = 64, .shader_location = 4 },
        };
        const sprite_layouts = [_]zgpu.VertexBufferLayout{
            zgpu.VertexBufferLayout.fromSlice(@sizeOf(scene_pass.SpriteInst), .instance, &sprite_attrs),
        };
        const sprite_bgl = zgpu.createBindGroupLayout(&.{
            zgpu.BindGroupLayoutEntry.initTexture(0, zgpu.ShaderVisibility.FRAGMENT, .float),
            zgpu.BindGroupLayoutEntry.initSampler(1, zgpu.ShaderVisibility.FRAGMENT, .filtering),
        });

        return .{
            .samples = samples,
            .bgl = bgl,
            .plane_opaque_pipeline = zgpu.createRenderPipelineDesc(.{
                .layout = layout,
                .shader = shader,
                .vertex_entry = "vs_plane",
                .fragment_entry = "fs_plane",
                .vertex_buffers = &plane_layouts,
                .color_format = format,
                .blend = .alpha,
                .depth = .{ .format = depth_format, .write_enabled = true, .compare = .less_equal },
                .sample_count = samples,
            }),
            .plane_blend_pipeline = zgpu.createRenderPipelineDesc(.{
                .layout = layout,
                .shader = shader,
                .vertex_entry = "vs_plane",
                .fragment_entry = "fs_plane",
                .vertex_buffers = &plane_layouts,
                .color_format = format,
                .blend = .alpha,
                .depth = .{ .format = depth_format, .write_enabled = false, .compare = .less_equal },
                .sample_count = samples,
            }),
            .sprite_bgl = sprite_bgl,
            .sprite_sampler = zgpu.createSampler(.{ .mag_filter = .linear, .min_filter = .linear }),
            .sprite_pipeline = zgpu.createRenderPipelineDesc(.{
                .layout = zgpu.createPipelineLayout(&.{ bgl, sprite_bgl }),
                .shader = shader,
                .vertex_entry = "vs_sprite",
                .fragment_entry = "fs_sprite",
                .vertex_buffers = &sprite_layouts,
                .color_format = format,
                .blend = .alpha,
                .depth = .{ .format = depth_format, .write_enabled = false, .compare = .less_equal },
                .sample_count = samples,
            }),
            // Additive blend of a zero fragment leaves the colour untouched: stencil-only.
            .stencil_pipeline = zgpu.createRenderPipelineDesc(.{
                .layout = layout,
                .shader = shader,
                .vertex_entry = "vs_mesh",
                .fragment_entry = "fs_stencil",
                .vertex_buffers = &mesh_layouts,
                .color_format = format,
                .blend = .additive,
                .depth = .{ .format = depth_format, .write_enabled = false, .compare = .always, .stencil = .{ .front = invert_face, .back = invert_face } },
                .sample_count = samples,
            }),
            .cap_pipeline = zgpu.createRenderPipelineDesc(.{
                .layout = layout,
                .shader = shader,
                .vertex_entry = "vs_cap",
                .fragment_entry = "fs_cap",
                .vertex_buffers = &cap_layouts,
                .color_format = format,
                .blend = .none,
                .depth = .{ .format = depth_format, .write_enabled = true, .compare = .less_equal, .stencil = .{ .front = cap_face, .back = cap_face } },
                .sample_count = samples,
            }),
            .gizmo_pipeline = zgpu.createRenderPipelineDesc(.{
                .layout = layout,
                .shader = shader,
                .vertex_entry = "vs_line",
                .fragment_entry = "fs_line",
                .vertex_buffers = &line_layouts,
                .color_format = format,
                .blend = .alpha,
                .depth = .{ .format = depth_format, .write_enabled = false, .compare = .always },
                .sample_count = samples,
            }),
            .grid_bgl = grid_bgl,
            .grid_pipeline = zgpu.createRenderPipelineDesc(.{
                .layout = zgpu.createPipelineLayout(&.{grid_bgl}),
                .shader = grid_shader,
                .vertex_entry = "vs_grid",
                .fragment_entry = "fs_grid",
                .color_format = format,
                .blend = .alpha,
                .depth = .{ .format = depth_format, .write_enabled = false, .compare = .less_equal },
                .sample_count = samples,
            }),
            .ident_buf = ident_buf,
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
        self.layers.deinit(plan_allocator);
        for (self.sprite_bgs) |e| if (e.bg) |bg| zgpu.release(bg);
        zgpu.destroySampler(self.sprite_sampler);
        zgpu.release(self.sprite_bgl);
        zgpu.release(self.sprite_pipeline);
        zgpu.release(self.plane_blend_pipeline);
        zgpu.release(self.plane_opaque_pipeline);
        zgpu.release(self.cap_pipeline);
        zgpu.release(self.stencil_pipeline);
        self.cap_quads.deinit(plan_allocator);
        self.cap_verts.deinit(plan_allocator);
        self.outline_segs.deinit(plan_allocator);
        self.outline_verts.deinit(plan_allocator);
        zgpu.bufferDestroy(self.ident_buf);
        zgpu.release(self.grid_pipeline);
        zgpu.release(self.grid_bgl);
        zgpu.release(self.gizmo_pipeline);
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
            if (plan_allocator.alloc(teak.scene.mat.Vec3, data.vertices.len)) |pos| {
                entry.cpu_pos = pos;
                var lo: teak.scene.mat.Vec3 = @splat(std.math.inf(f32));
                var hi: teak.scene.mat.Vec3 = @splat(-std.math.inf(f32));
                for (data.vertices, pos) |v, *p| {
                    p.* = v.pos;
                    lo = teak.scene.mat.minV(lo, v.pos);
                    hi = teak.scene.mat.maxV(hi, v.pos);
                }
                entry.lo = lo;
                entry.hi = hi;
                entry.cpu_idx = plan_allocator.dupe(u32, data.indices) catch &.{};
            } else |_| {}
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

    const CutGeo = struct { outline_verts: u32 = 0 };

    /// Bind group for sampling image `handle`'s texture view (cached per handle;
    /// rebuilt when the Gpu hands out a different view for it).
    fn spriteBindGroup(self: *Renderer, handle: u32, view: zgpu.TextureView) zgpu.BindGroup {
        for (&self.sprite_bgs) |*e| {
            if (e.handle == handle and e.bg != null) {
                if (e.view != null and e.view.? == view) return e.bg.?;
                zgpu.release(e.bg.?);
                e.* = .{};
                break;
            }
        }
        const bg = zgpu.createBindGroup(self.sprite_bgl, &.{
            zgpu.BindGroupEntry.initTextureView(0, view),
            zgpu.BindGroupEntry.initSampler(1, self.sprite_sampler),
        });
        const slot = for (self.sprite_bgs, 0..) |e, i| {
            if (e.bg == null) break i;
        } else blk: {
            const i = self.next_sprite_bg % sprite_bg_cache;
            self.next_sprite_bg += 1;
            if (self.sprite_bgs[i].bg) |old| zgpu.release(old);
            break :blk i;
        };
        self.sprite_bgs[slot] = .{ .handle = handle, .view = view, .bg = bg };
        return bg;
    }

    /// Plane layers and sprites: opaque planes first (depth written), then the
    /// blended planes and sprites back to front (depth tested, not written).
    fn drawLayers(self: *Renderer, pass: zgpu.RenderPassEncoder, t: *Target, images: anytype) void {
        const ly = &self.layers;
        if (ly.isEmpty()) return;
        const vbytes: u32 = @intCast(ly.plane_verts.items.len * @sizeOf(teak.Vertex));
        const ibytes: u32 = @intCast(ly.plane_insts.items.len * @sizeOf(scene_pass.LayerInst));
        const sbytes: u32 = @intCast(ly.sprites.items.len * @sizeOf(scene_pass.SpriteInst));
        if (vbytes > 0) {
            zgpu.bufferWrite(growBuffer(&t.plane_vbuf, &t.plane_vcap, vbytes), 0, std.mem.sliceAsBytes(ly.plane_verts.items));
            zgpu.bufferWrite(growBuffer(&t.plane_ibuf, &t.plane_icap, ibytes), 0, std.mem.sliceAsBytes(ly.plane_insts.items));
        }
        if (sbytes > 0) zgpu.bufferWrite(growBuffer(&t.sprite_buf, &t.sprite_cap, sbytes), 0, std.mem.sliceAsBytes(ly.sprites.items));
        zgpu.renderPassSetBindGroup(pass, 0, t.bind_group);
        if (vbytes > 0) {
            zgpu.renderPassSetPipeline(pass, self.plane_opaque_pipeline);
            for (ly.opaque_planes.items) |di| drawPlane(pass, t, ly.plane_draws.items[di]);
        }
        var bound_image: u32 = 0;
        var last_kind: ?@TypeOf(ly.blended.items[0].kind) = null;
        for (ly.blended.items) |b| {
            switch (b.kind) {
                .plane => {
                    if (last_kind != .plane) zgpu.renderPassSetPipeline(pass, self.plane_blend_pipeline);
                    drawPlane(pass, t, ly.plane_draws.items[b.index]);
                },
                .sprite => {
                    if (last_kind != .sprite) {
                        zgpu.renderPassSetPipeline(pass, self.sprite_pipeline);
                        zgpu.renderPassSetVertexBuffer(pass, 0, t.sprite_buf.?, 0, sbytes);
                        bound_image = 0;
                    }
                    const handle = ly.sprite_images.items[b.index];
                    if (handle != bound_image) {
                        const view = images.viewOf(handle) orelse continue;
                        zgpu.renderPassSetBindGroup(pass, 1, self.spriteBindGroup(handle, view));
                        bound_image = handle;
                    }
                    zgpu.renderPassDraw(pass, 6, 1, 0, b.index);
                },
            }
            last_kind = b.kind;
        }
    }

    fn drawPlane(pass: zgpu.RenderPassEncoder, t: *Target, pd: scene_pass.PlaneDraw) void {
        zgpu.renderPassSetVertexBuffer(pass, 0, t.plane_vbuf.?, pd.first_vertex * @sizeOf(teak.Vertex), pd.vertex_count * @sizeOf(teak.Vertex));
        zgpu.renderPassSetVertexBuffer(pass, 1, t.plane_ibuf.?, pd.inst * @sizeOf(scene_pass.LayerInst), @sizeOf(scene_pass.LayerInst));
        zgpu.renderPassDraw(pass, pd.vertex_count, 1, 0, 0);
    }

    /// Backend mesh of plan instance `k` (the run that contains it).
    fn meshOfInstance(self: *Renderer, k: u32) ?MeshEntry {
        for (self.plan.runs.items) |run| {
            if (k >= run.first and k < run.first + run.count) return (self.meshes.get(run.mesh) orelse return null).*;
        }
        return null;
    }

    fn growBuffer(buf: *?zgpu.Buffer, cap: *u32, bytes: u32) zgpu.Buffer {
        if (buf.*) |b| {
            if (cap.* >= bytes) return b;
            zgpu.bufferDestroy(b);
        }
        const want = @max(std.math.ceilPowerOfTwo(u32, bytes) catch bytes, 4096);
        const nb = zgpu.createBuffer(want, zgpu.BufferUsage.VERTEX | zgpu.BufferUsage.COPY_DST);
        buf.* = nb;
        cap.* = want;
        return nb;
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
                if (cut.cap and inst.flags & scene_pass.flag_no_cap == 0 and m.index_bytes > 0) cap: {
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
        if (self.cap_verts.items.len > 0) {
            const bytes: u32 = @intCast(self.cap_verts.items.len * @sizeOf(LineVertex));
            const buf = growBuffer(&t.cap_buf, &t.cap_cap, bytes);
            zgpu.bufferWrite(buf, 0, std.mem.sliceAsBytes(self.cap_verts.items));
        }

        for (self.outline_segs.items) |sg| {
            self.outline_verts.append(plan_allocator, .{ .pos = sg.a, .color = .{ 1, 1, 1, 1 } }) catch return .{};
            self.outline_verts.append(plan_allocator, .{ .pos = sg.b, .color = .{ 1, 1, 1, 1 } }) catch return .{};
        }
        if (self.outline_verts.items.len == 0) return .{};
        const obytes: u32 = @intCast(self.outline_verts.items.len * @sizeOf(LineVertex));
        const obuf = growBuffer(&t.outline_buf, &t.outline_cap, obytes);
        zgpu.bufferWrite(obuf, 0, std.mem.sliceAsBytes(self.outline_verts.items));
        var og = common.globals(draw, size, scale);
        og.edge_color = cut.outline_color;
        og.viewport[2] = cut.outline_px * scale;
        og.misc[2] = 0; // the outline lies on the plane: never cut it away
        zgpu.bufferWriteTyped(common.Globals, t.outline_ubo, 0, &.{og});
        return .{ .outline_verts = @intCast(self.outline_verts.items.len) };
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
        const grid_buf = zgpu.createUniformBuffer(@sizeOf(scene_pass.GridUniform));
        const gizmo_ubo = zgpu.createUniformBuffer(@sizeOf(common.Globals));
        const outline_ubo = zgpu.createUniformBuffer(@sizeOf(common.Globals));
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
            .grid_buf = grid_buf,
            .grid_bg = zgpu.createBindGroup(self.grid_bgl, &.{
                zgpu.BindGroupEntry.initBufferFull(0, grid_buf, @sizeOf(scene_pass.GridUniform)),
            }),
            .gizmo_ubo = gizmo_ubo,
            .gizmo_bg = zgpu.createBindGroup(self.bgl, &.{
                zgpu.BindGroupEntry.initBufferFull(0, gizmo_ubo, @sizeOf(common.Globals)),
            }),
            .gizmo_lines = zgpu.createBuffer(scene_pass.gizmo_segments * 2 * @sizeOf(LineVertex), zgpu.BufferUsage.VERTEX | zgpu.BufferUsage.COPY_DST),
            .outline_ubo = outline_ubo,
            .outline_bg = zgpu.createBindGroup(self.bgl, &.{
                zgpu.BindGroupEntry.initBufferFull(0, outline_ubo, @sizeOf(common.Globals)),
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
    pub fn renderInto(self: *Renderer, index: usize, draw: SceneDraw, items: []const teak.SceneItem, sprite_list: []const teak.SceneSprite, images: anytype, scale: f32) ?TargetSize {
        const size = common.targetSize(draw.rect_w, draw.rect_h, scale) orelse return null;
        const t = self.ensureTarget(index, size);

        self.plan.build(plan_allocator, draw, items, self) catch return null;
        self.layers.build(plan_allocator, draw, sprite_list, images) catch return null;
        const sig = common.signature(draw, size, scale, self.plan.contentHash(self) ^ (self.layers.contentHash() *% 0x9E3779B97F4A7C15));
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
            .stencil = .{ .store = .discard },
        });
        const cut_geo: CutGeo = if (draw.cut) |cut| self.prepareCut(t, draw, cut, size, scale) else .{};

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
            // Section caps: per item, stencil parity then the cap quad (which clears it).
            for (self.cap_quads.items) |cd| {
                const m = self.meshOfInstance(cd.inst) orelse continue;
                zgpu.renderPassSetPipeline(pass, self.stencil_pipeline);
                zgpu.renderPassSetBindGroup(pass, 0, t.bind_group);
                zgpu.renderPassSetVertexBuffer(pass, 0, m.vertex_buf.?, 0, m.vertex_bytes);
                zgpu.renderPassSetVertexBuffer(pass, 1, inst_buf, 0, inst_bytes);
                zgpu.renderPassSetIndexBuffer(pass, m.index_buf.?, .uint32, 0, m.index_bytes);
                zgpu.renderPassDrawIndexed(pass, m.index_bytes / @sizeOf(u32), 1, 0, 0, cd.inst);
                zgpu.renderPassSetPipeline(pass, self.cap_pipeline);
                zgpu.renderPassSetVertexBuffer(pass, 0, t.cap_buf.?, cd.first_vertex * @sizeOf(LineVertex), 6 * @sizeOf(LineVertex));
                zgpu.renderPassDraw(pass, 6, 1, 0, 0);
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

        self.drawLayers(pass, t, images);

        // Cut outline: exact plane x mesh segments with their own line width.
        if (cut_geo.outline_verts > 0) {
            zgpu.renderPassSetPipeline(pass, self.line_pipeline);
            zgpu.renderPassSetBindGroup(pass, 0, t.outline_bg);
            zgpu.renderPassSetVertexBuffer(pass, 0, t.outline_buf.?, 0, cut_geo.outline_verts * @sizeOf(LineVertex));
            zgpu.renderPassSetVertexBuffer(pass, 1, self.ident_buf, 0, @sizeOf(scene_pass.Packed));
            zgpu.renderPassDraw(pass, 6, cut_geo.outline_verts / 2, 0, 0);
        }

        // Grid: depth-tested against everything drawn above, blended over it.
        if (draw.grid) |grid| if (scene_pass.gridUniform(draw, grid, size.w, size.h, scale)) |gu| {
            zgpu.bufferWriteTyped(scene_pass.GridUniform, t.grid_buf, 0, &.{gu});
            zgpu.renderPassSetPipeline(pass, self.grid_pipeline);
            zgpu.renderPassSetBindGroup(pass, 0, t.grid_bg);
            zgpu.renderPassDraw(pass, 3, 1, 0, 0);
        };

        // Gizmo: axis triad in a corner sub-viewport, always on top.
        if (draw.gizmo) |gz| {
            const r = scene_pass.gizmoRect(gz, size.w, size.h, scale);
            const lines = scene_pass.gizmoLines(draw.camera.view_proj, gz);
            zgpu.bufferWrite(t.gizmo_lines, 0, std.mem.sliceAsBytes(&lines));
            var gg = common.globals(draw, .{ .w = @intFromFloat(r[2]), .h = @intFromFloat(r[3]) }, scale);
            gg.view_proj = scene_pass.gizmoProjection();
            gg.edge_color = .{ 1, 1, 1, 1 };
            gg.viewport[2] = 2 * scale;
            gg.viewport[3] = 0;
            gg.clip = .{ 0, 0, 0, 0 };
            gg.misc = .{ 0, 0, 0, 0 };
            zgpu.bufferWriteTyped(common.Globals, t.gizmo_ubo, 0, &.{gg});
            zgpu.renderPassSetViewport(pass, r[0], r[1], r[2], r[3], 0, 1);
            zgpu.renderPassSetScissorRect(pass, @intFromFloat(r[0]), @intFromFloat(r[1]), @intFromFloat(r[2]), @intFromFloat(r[3]));
            zgpu.renderPassSetPipeline(pass, self.gizmo_pipeline);
            zgpu.renderPassSetBindGroup(pass, 0, t.gizmo_bg);
            zgpu.renderPassSetVertexBuffer(pass, 0, t.gizmo_lines, 0, scene_pass.gizmo_segments * 2 * @sizeOf(LineVertex));
            zgpu.renderPassSetVertexBuffer(pass, 1, self.ident_buf, 0, @sizeOf(scene_pass.Packed));
            zgpu.renderPassDraw(pass, 6, scene_pass.gizmo_segments, 0, 0);
        }
        zgpu.renderPassEnd(pass);
        return size;
    }
};
