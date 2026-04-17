# Ready-to-file zunk issue (drafted on teak side, not yet submitted)

**Target repo**: `hotschmoe/zunk`
**Target branch for resulting PR**: `master` (v0.1.0 tip)
**Drafted**: 2026-04-16 · **Re-scoped**: 2026-04-17 (zunk v0.1.0 / Zig 0.16.0 migration)
**Source**: Teak's `docs/zunk-integration.md` §3.1 audit, re-verified against `zunk` commit `5835cf0` (v0.1.0, post-Zig-0.16.0 migration)

Paste everything below the `---` line into https://github.com/hotschmoe/zunk/issues/new.

---

## Title

`[gpu] Add vertex buffer layout support to createRenderPipeline + setVertexBuffer on render pass`

## Body

### Summary

`zunk.web.gpu` currently cannot create a render pipeline that consumes vertices from a `BufferUsage.VERTEX` buffer bound via `setVertexBuffer`. Pipelines can only source vertex data from a storage buffer read in the shader (the `particle-life` pattern). This blocks any consumer that already targets wgpu-native's standard vertex-buffer path — notably [teak](https://github.com/hotschmoe/teak), which generates CPU-side vertex data per frame and uploads it via `queueWriteBuffer` + `setVertexBuffer`.

### Why this matters

Teak is the first external zunk consumer (per `INTEGRATION.md` intent in `docs/zunk-integration.md`). Its render pipeline is:

1. Traverse command buffer + rect buffer on CPU → produce `[]Vertex` where `Vertex = struct { pos: [2]f32, color: [4]f32, uv: [2]f32 }` (8 × f32 = 32 bytes interleaved; 3 attributes at `@location(0..2)`, offsets 0 / 8 / 24).
2. Upload to `BufferUsage.VERTEX | BufferUsage.COPY_DST` buffer via `wgpuQueueWriteBuffer` (native) / `bufferWrite` (web).
3. Bind via `wgpuRenderPassEncoderSetVertexBuffer(pass, 0, buf, 0, size)`.
4. `draw(count, 1, 0, 0)` — shader reads `@location(0)`/`@location(1)`/... attributes.

Step 3 has no zunk equivalent today. Rewriting Teak to use storage buffers would diverge the web and native render paths and defeat the "same app, two hosts" model.

### Current gap

Scanning `src/web/gpu.zig` at `5835cf0` (v0.1.0):

- `createRenderPipeline(layout, shader, vert_entry, frag_entry)` — no vertex-buffer-layout parameter.
- `createRenderPipelineHDR(...)` — adds `(format, blending)` but still no vertex layout.
- `RenderPassEncoder` — no `setVertexBuffer` binding.
- No `zunk_gpu_render_pass_set_vertex_buffer` extern.

### Proposed API

Single path — **extend the existing externs in place, no `_v2`**. Zunk is pre-1.0 (v0.1.0 cut today), all current consumers are in-tree under `examples/`, and the pointer+length blob pattern already matches `zunk_gpu_create_bind_group_layout(entries_ptr, entries_len)` where `len=0` is a valid empty case. Shape below is open to redesign on details.

Zig-side types:

```zig
pub const VertexFormat = enum(u32) {
    float32, float32x2, float32x3, float32x4,
    uint32, uint32x2, uint32x3, uint32x4,
    sint32, sint32x2, sint32x3, sint32x4,
    // extend as needed
};

pub const VertexStepMode = enum(u32) { vertex = 0, instance = 1 };

pub const VertexAttribute = extern struct {
    format: u32,         // VertexFormat
    offset: u32,
    shader_location: u32,
    _pad: u32 = 0,
};

pub const VertexBufferLayout = extern struct {
    array_stride: u32,
    step_mode: u32,      // VertexStepMode
    attributes_ptr: [*]const VertexAttribute,
    attributes_len: u32,
};
```

Zig-side API — extend `createRenderPipeline` / `createRenderPipelineHDR` with a trailing `vertex_buffers` parameter (default empty = today's behavior); add one new binding fn:

```zig
pub fn createRenderPipeline(
    layout: PipelineLayout,
    shader: ShaderModule,
    vertex_entry: []const u8,
    fragment_entry: []const u8,
    vertex_buffers: []const VertexBufferLayout, // &.{} for storage-buffer-fed pipelines
) RenderPipeline;

pub fn createRenderPipelineHDR(
    layout: PipelineLayout,
    shader: ShaderModule,
    vertex_entry: []const u8,
    fragment_entry: []const u8,
    format: TextureFormat,
    blending: bool,
    vertex_buffers: []const VertexBufferLayout,
) RenderPipeline;

pub fn renderPassSetVertexBuffer(
    pass: RenderPassEncoder,
    slot: u32,
    buffer: Buffer,
    offset: u64,
    size: u64,
) void;
```

Paired externs — extend the existing two in place, add one new (u64 split into lo/hi per the existing `zunk_gpu_*` convention):

```zig
extern "env" fn zunk_gpu_create_render_pipeline(
    layout_h: i32, shader_h: i32,
    vert_ptr: [*]const u8, vert_len: u32,
    frag_ptr: [*]const u8, frag_len: u32,
    vbuf_layouts_ptr: [*]const u8, vbuf_layouts_len: u32, // new; len=0 allowed
) i32;

extern "env" fn zunk_gpu_create_render_pipeline_hdr(
    layout_h: i32, shader_h: i32,
    vert_ptr: [*]const u8, vert_len: u32,
    frag_ptr: [*]const u8, frag_len: u32,
    format: u32, blending: u32,
    vbuf_layouts_ptr: [*]const u8, vbuf_layouts_len: u32, // new
) i32;

extern "env" fn zunk_gpu_render_pass_set_vertex_buffer(
    pass_h: i32, slot: u32, buffer_h: i32,
    offset_lo: u32, offset_hi: u32,
    size_lo: u32, size_hi: u32,
) void;
```

Existing in-tree examples (`particle-life`, `audio-demo-1/2`, `imgui-demo`, `input-demo`) get a trailing `&.{}` at each call site — one-line edit per example.

### JS-side sketch

The resolver reads `vbuf_layouts_ptr` as a packed array of `VertexBufferLayout` + flattened `VertexAttribute` entries, constructs the standard WebGPU `GPUVertexState.buffers` descriptor, and passes it to `device.createRenderPipeline`. Standard WebGPU — no novel semantics.

### Acceptance

A zunk example that:
1. Creates a `VERTEX | COPY_DST` buffer.
2. Writes three `{pos: vec2, color: vec3}` vertices via `bufferWrite`.
3. Creates a render pipeline with a `VertexBufferLayout` describing the 20-byte stride + two attributes.
4. Binds the buffer via `setVertexBuffer`, calls `draw(3, 1, 0, 0)`.
5. Renders a solid-color triangle.

Teak becomes the second consumer.

### Non-goals for this issue

- Sampler creation / binding (separate issue — blocks glyph rendering, not vertex-buffer demos).
- CPU-bytes texture upload (separate issue).
- Depth/stencil state (separate issue, not blocking 2D UI).

### Coordination note

Teak's short-path plan (`docs/path_to_wasm_test.md`) pins zunk to a commit *after* this issue lands, on top of v0.1.0. The Zig 0.16.0 migration is already in (zunk commits `5a98341` + `6e73e53`, tagged as v0.1.0 at `5835cf0`), so this feature is the last remaining blocker for Teak's `zig build web` bring-up.

### References

- Teak audit: `hotschmoe/teak/docs/zunk-integration.md` §3.1
- Teak wasm path plan: `hotschmoe/teak/docs/path_to_wasm_test.md`
- zunk source scanned: `src/web/gpu.zig` @ `5835cf0` (v0.1.0, 2026-04-17)
