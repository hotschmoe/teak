# Teak ↔ zunk integration audit

**Purpose**: scoping doc for `src/host/wasm.zig` (task 3a) and the accompanying `zig build web` path (task 3c). Answers the questions in `tasks.md` §6 and `tasks-wasm.md` §4.

**Method**: read `../zunk/src/web/{gpu,input,app}.zig` at commit `d101693` on branch `dev-hotschmoe`; compared against every `wgpu*` call in `src/ui_main.zig` and every input touchpoint in the Win32 `WNDPROC`.

**Companion docs**: `tasks-wasm.md` §4 (input checklist this doc fills in), `zunk_teak_convo.md` §8 (integration model).

**Status key**: ✅ covered · ⚠ partial / workaround available · ❌ missing, upstream PR required.

---

## 1. Known answers (short reference)

Confirmed against zunk source — these stop being open questions.

| Area | Answer | Source |
|---|---|---|
| **Lifecycle** | `init()` / `frame(dt: f32)` / `resize(w: u32, h: u32)` / `cleanup()` — user-exported from wasm, zunk detects via import-section analysis and wires the JS driver. | `zunk/README.md` §Architecture; no code in `src/web/app.zig` because zunk's 5-tier resolver handles exports, not imports. |
| **Input polling** | `zunk.web.input.init()` once in `init`, then `input.poll()` once per frame. Shared-memory `InputState` struct is updated in place; accessor helpers (`isKeyDown`, `getMouse`, `getTypedChars`) read the struct. Matches Teak's Win32 drain-queue shape. | `src/web/input.zig:43-51` |
| **Unicode text input** | ✅ present. `InputState.typed_chars: [32]u8` + `typed_chars_len: u8`, drained per-frame via `getTypedChars()`. WM_CHAR-equivalent for the greeter. **Caveat**: 32-byte fixed buffer per frame → IME paste of >32 bytes would truncate silently. Not blocking prototype; log as follow-up if it bites. | `src/web/input.zig:39-40,228-230` |
| **Viewport + DPR** | `getViewportSize()` → `{w, h}`; `getDevicePixelRatio()` → `f32`; `hasFocus()` → `bool`. Replaces our `WM_SIZE` + GetDpiForWindow. | `src/web/input.zig:216-226` |
| **Shader format** | WGSL passed through unchanged. `createShaderModule([]const u8)` — `shaders/quad.wgsl` works as-is. | `src/web/gpu.zig:212-214` |
| **Async adapter/device** | Zunk finishes adapter+device acquisition **before** `init` fires; `gpu.getDevice()` returns a fixed handle (`bind.Handle.fromInt(1)`). Our Win32 spin loop (`while (adapter == null) wgpuInstanceProcessEvents(...)`) is **deleted** on web, not ported. | `src/web/gpu.zig:180-182`, zunk README |
| **Loop ownership** | zunk owns rAF; app exports `frame(dt)`. Task 3a's host interface must accommodate both "host drives" (Win32) and "app exports" (wasm) — see `tasks-wasm.md` §2d. | zunk README §Architecture |
| **Queue submit** | `queueSubmit(cmd: CommandBuffer)` — no explicit queue handle needed. Matches wgpu-native 1:1 modulo the handle. | `src/web/gpu.zig:319-321` |
| **Present** | `present()` — no surface/swapchain handle, canvas is implicit. Replaces `wgpuSurfaceGetCurrentTexture` + `wgpuSurfacePresent`. | `src/web/gpu.zig:347-349` |
| **HTML/JS glue** | Not Teak's concern. No `index.html`, no `bridge.js` needed for the prototype. | zunk README §Architecture |

---

## 2. Open audit items (per-call coverage table)

Every `wgpu*` call in `src/ui_main.zig` checked against `src/web/gpu.zig`. Sorted by blocking status.

### 2.1 Blockers for the Teak UI prototype (must resolve before `zig build web` works)

| Teak call | zunk equivalent | Status | Notes |
|---|---|---|---|
| `wgpuRenderPassEncoderSetVertexBuffer(pass, 0, buf, 0, size)` | **none** | ❌ | See §3.1 — this is the single load-bearing gap. Teak's whole render path (`buildVertices` → upload → draw) assumes vertex-buffer input. Zunk's pipeline creation takes no vertex-buffer-layout descriptor; the resulting pipeline can only source vertices from a storage buffer via bind group (the `particle-life` pattern). |
| `wgpuDeviceCreateRenderPipeline` with explicit `vertex.buffers` array describing `Vertex{pos: vec2, color: vec4, rect_pos: vec2, rect_size: vec2}` layout | `createRenderPipeline(layout, shader, vert_entry, frag_entry)` | ⚠ | Signature lacks *any* vertex-buffer-layout or target-format parameterization. `createRenderPipelineHDR` adds `(format, blending)` but still no vertex layout. Pairs with the setVertexBuffer gap — same upstream PR. |
| `wgpuSurfaceConfigure` (format, present mode, size) | implicit in `beginRenderPass` | ⚠ | No explicit surface-config step. Canvas size comes from `input.getViewportSize()`; the render pass's target format appears hardcoded JS-side. Acceptable if default is `bgra8unorm` — **verify in `js_resolve.zig`** or by running a minimal render-to-canvas probe once §3.1 lands. |

### 2.2 Non-blockers for prototype (cover today, revisit for text rendering)

| Teak call | zunk equivalent | Status | Notes |
|---|---|---|---|
| `wgpuCreateInstance` | n/a | ✅ | zunk owns the instance; never surfaced. |
| `wgpuInstanceCreateSurface(&win32_hwnd_desc)` | n/a | ✅ | Canvas is the implicit surface. |
| `wgpuInstanceRequestAdapter` / `wgpuAdapterRequestDevice` | `getDevice()` returns pre-acquired handle | ✅ | See §1. |
| `wgpuDeviceGetQueue` | implicit in `queueSubmit` / `bufferWrite` | ✅ | No queue handle exposed; calls take device implicitly. |
| `wgpuDeviceCreateShaderModule` | `createShaderModule` | ✅ | WGSL passthrough. |
| `wgpuDeviceCreateBindGroupLayout` | `createBindGroupLayout(entries)` | ✅ | `BindGroupLayoutEntry` covers buffer (uniform/storage/ro-storage) + texture. Teak only needs uniform — covered. |
| `wgpuDeviceCreatePipelineLayout` | `createPipelineLayout(layouts)` | ✅ | |
| `wgpuDeviceCreateBuffer(usage=UNIFORM|COPY_DST, size=8)` | `createUniformBuffer(size)` | ✅ | |
| `wgpuDeviceCreateBuffer(usage=VERTEX|COPY_DST, size=N)` | `createBuffer(size, BufferUsage.VERTEX|COPY_DST)` | ⚠ | Buffer creates fine. Blocked on §2.1 since pipeline can't consume VERTEX-usage buffers. |
| `wgpuQueueWriteBuffer(queue, buf, 0, data, size)` | `bufferWrite(buf, 0, data)` / `bufferWriteTyped` | ✅ | Same per-frame upload path. Need to confirm no per-call JS allocation in the resolver, but the extern fn takes a raw slice — looks clean. |
| `wgpuBufferRelease` | `bufferDestroy(buf)` | ✅ | Needed on resize (vertex buffer grows). |
| `wgpuDeviceCreateBindGroup` | `createBindGroup(layout, entries)` | ✅ | `BindGroupEntry.initBuffer` / `initBufferFull` covers Teak's uniform binding. |
| `wgpuSurfaceGetCurrentTexture` + `wgpuTextureCreateView` | implicit in `beginRenderPass` | ✅ | |
| `wgpuDeviceCreateCommandEncoder` | `createCommandEncoder()` | ✅ | |
| `wgpuCommandEncoderBeginRenderPass(color_attachment={view, load=clear, store=store, clear=color})` | `beginRenderPass(r, g, b, a)` | ⚠ | Only clear-color parameterization. Load op is implicit `clear`, store op implicit `store`. Adequate for Teak — log as a zunk flexibility gap, not a Teak blocker. |
| `wgpuRenderPassEncoderSetPipeline` | `renderPassSetPipeline` | ✅ | |
| `wgpuRenderPassEncoderSetBindGroup(pass, idx, bg, 0, null)` | `renderPassSetBindGroup(pass, idx, bg)` | ✅ | Dynamic offsets not surfaced; Teak doesn't use them. |
| `wgpuRenderPassEncoderDraw(count, 1, 0, 0)` | `renderPassDraw(pass, count, 1, 0, 0)` | ✅ | |
| `wgpuRenderPassEncoderEnd` / `wgpuRenderPassEncoderRelease` | `renderPassEnd(pass)` | ✅ | Release is JS-side on `end`. |
| `wgpuCommandEncoderFinish` | `encoderFinish(encoder)` | ✅ | |
| `wgpuQueueSubmit` | `queueSubmit(cmd)` | ✅ | |
| `wgpuSurfacePresent` | `present()` | ✅ | |

### 2.3 Future-blockers (text rendering, images)

These are **not** required for the counter/greeter prototype. Log them now so task 6's follow-up scope is visible.

| Need | Teak call | zunk coverage | Status |
|---|---|---|---|
| Sampler creation | `wgpuDeviceCreateSampler` | `BindGroupLayoutEntry` comment mentions `entry_type=2` (sampler), but no `zunk_gpu_create_sampler` extern, no `initSampler` constructor, no `Sampler` handle alias. | ❌ |
| Sampler binding | bind group entry with sampler resource | no `BindGroupEntry.initSampler` | ❌ |
| Texture upload from CPU bytes | `wgpuQueueWriteTexture` | only `createTextureFromAsset(asset_handle)` — asset-pipeline bound; no direct CPU-bytes-to-texture path | ❌ |
| Depth/stencil state in pipeline | `pipeline_desc.depthStencil` | `createRenderPipeline` takes no depth/stencil descriptor | ❌ (not blocking 2D UI) |
| Depth attachment in render pass | `RenderPassDescriptor.depthStencilAttachment` | `beginRenderPass` takes clear-color only | ❌ (not blocking 2D UI) |

---

## 3. Upstream issue queue (file against `hotschmoe/zunk`)

Each entry below is a ready-to-file issue. Use as-is or copy-paste into `gh issue create`. The doc is the canonical tracker until issues are filed — keep this section in sync as status changes.

### 3.1 [BLOCKER] Vertex buffer input support in render pipelines

**Status**: not filed · **Blocks**: Teak `zig build web` end-to-end · **Target branch**: n/a, feature PR against `master`

**Problem**: `gpu.createRenderPipeline(layout, shader, vert_entry, frag_entry)` and `createRenderPipelineHDR(...)` accept no vertex-buffer-layout parameter. The corresponding `RenderPassEncoder` has no `setVertexBuffer` binding. This means pipelines created through `zunk.web.gpu` can only source vertex data from a storage buffer accessed via a bind group (the pattern used in `particle-life`), not from a WebGPU vertex buffer bound with `setVertexBuffer`.

Teak ships a CPU vertex generator (`buildVertices` → `std.ArrayList(Vertex)`, where `Vertex` is `struct { pos: [2]f32, color: [4]f32, rect_pos: [2]f32, rect_size: [2]f32 }` — 8 × f32 = 32 bytes interleaved) and uploads it per frame via `wgpuQueueWriteBuffer` + binds it with `wgpuRenderPassEncoderSetVertexBuffer`. Storage-buffer-fed vertices would force every zunk consumer that already targets wgpu-native to duplicate their render path.

**Proposed API** (sketch — open to redesign):

```zig
pub const VertexFormat = enum(u32) {
    float32, float32x2, float32x3, float32x4,
    uint32, uint32x2, // ...
};

pub const VertexAttribute = extern struct {
    format: u32,        // VertexFormat
    offset: u32,
    shader_location: u32,
    _pad: u32 = 0,
};

pub const VertexBufferLayout = extern struct {
    array_stride: u32,
    step_mode: u32, // 0=vertex, 1=instance
    attributes_ptr: [*]const VertexAttribute,
    attributes_len: u32,
};

pub fn createRenderPipelineWithVertexLayout(
    layout: PipelineLayout,
    shader: ShaderModule,
    vertex_entry: []const u8,
    fragment_entry: []const u8,
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

Paired extern fns:
```zig
extern "env" fn zunk_gpu_create_render_pipeline_v2(
    layout_h: i32, shader_h: i32,
    vert_ptr: [*]const u8, vert_len: u32,
    frag_ptr: [*]const u8, frag_len: u32,
    format: u32, blending: u32,
    vbuf_layouts_ptr: [*]const u8, vbuf_layouts_len: u32,
) i32;
extern "env" fn zunk_gpu_render_pass_set_vertex_buffer(
    pass_h: i32, slot: u32, buffer_h: i32, offset_lo: u32, offset_hi: u32, size_lo: u32, size_hi: u32,
) void;
```

(Existing `createRenderPipeline` / `createRenderPipelineHDR` kept for backward compat — new entry point or optional `[]const VertexBufferLayout = &.{}` variant.)

**Acceptance**: a zunk example that renders a colored triangle from a `VERTEX`-usage buffer bound via `setVertexBuffer` (no storage buffer). Teak becomes that example's second consumer.

---

### 3.2 [FOLLOW-UP] Sampler creation and binding

**Status**: not filed · **Blocks**: text rendering via glyph atlas (Teak future work, not prototype)

**Problem**: `BindGroupLayoutEntry.entry_type` has `2=sampler` in the docstring, but there is no `zunk_gpu_create_sampler` extern, no `Sampler = bind.Handle` alias, no `BindGroupLayoutEntry.initSampler` constructor, and no `BindGroupEntry.initSampler`. Samplers cannot currently be created or bound.

**Proposed API**:
```zig
pub const Sampler = bind.Handle;
pub const FilterMode = enum(u32) { nearest = 0, linear = 1 };
pub const AddressMode = enum(u32) { clamp_to_edge = 0, repeat = 1, mirror_repeat = 2 };

pub fn createSampler(desc: SamplerDescriptor) Sampler;
pub fn (BindGroupLayoutEntry) initSampler(binding: u32, visibility: u32) BindGroupLayoutEntry;
pub fn (BindGroupEntry) initSampler(binding: u32, sampler: Sampler) BindGroupEntry;
```

**Acceptance**: zunk example sampling a texture with a linear sampler.

---

### 3.3 [FOLLOW-UP] CPU-bytes texture upload path

**Status**: not filed · **Blocks**: text rendering, loading images without the asset pipeline

**Problem**: `createTextureFromAsset(asset_handle)` is the only texture-data path; it's tied to zunk's asset system. No `queueWriteTexture(texture, bytes, layout)` equivalent. Teak's future glyph atlas needs to upload rasterized font bitmaps — generated at runtime, not shipped as an asset.

**Proposed API**:
```zig
pub fn queueWriteTexture(
    texture: Texture,
    data: []const u8,
    bytes_per_row: u32,
    rows_per_image: u32,
    origin: struct { x: u32, y: u32, z: u32 },
    extent: struct { w: u32, h: u32, d: u32 },
) void;
```

---

### 3.4 [MINOR] Render pass load/store op parameterization

**Status**: not filed · **Blocks**: nothing today

**Problem**: `beginRenderPass(r, g, b, a)` hardcodes `load=clear`, `store=store`. Some use cases want `load=load` (additive passes, post-processing). Teak currently only needs clear — log for symmetry with wgpu-native.

---

## 4. Action items

- [ ] **File issue 3.1** against `hotschmoe/zunk`. Link back to this doc and to `tasks.md` §6.
- [ ] **Land 3.1** (Teak can't `zig build web` without it — either zunk lands the PR or Teak contributes one).
- [ ] **Verify** §2.1 row 3 (surface format hardcoded bgra8unorm) with a canvas probe once 3.1 is in. One-liner: a zunk example that clears the canvas pink — visual confirmation that format + sRGB are what Teak expects.
- [ ] **File issues 3.2 / 3.3 / 3.4** when text rendering moves up the Teak roadmap. Not blocking today.
- [ ] **Regression canary** (`tasks-wasm.md` §5, hooks into task 5 pitfalls doc): CI step `zig build-exe ... -target wasm32-freestanding -fno-entry -rdynamic` on `src/root.zig` to prevent the framework core from picking up posix deps. Orthogonal to zunk but belongs in the same "wasm-ready" discipline.
- [ ] **Revisit this doc** after 3.1 lands — §2.1 rows should collapse into §2.2.

---

## 5. Non-changes

Explicitly not required, contrary to earlier worry items:

- **No `bridge.js`** — zunk's Layer 2 covers every Teak prototype need after 3.1 lands.
- **No input-refactor** — shared-memory poll matches Teak's drain loop directly.
- **No shader translation** — WGSL passes through.
- **No adapter/device spin loop port** — zunk fronts this.
- **No `index.html` or JS glue in Teak's tree** — zunk generates both.
- **No zunk fork into Teak** — per `zunk_teak_convo.md` §8, none of the three reconsideration criteria hold.
