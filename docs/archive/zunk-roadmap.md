# Zunk roadmap — Teak's requested workstreams

**Audience**: zunk contributors. Teak is zunk's first external consumer; this doc tells the zunk team what Teak will need next, in priority order, with acceptance criteria detailed enough to write tests against.

**Last updated**: 2026-04-18
**Teak branch**: `master`
**Zunk branch tracked**: `dev-hotschmoe` (path-dep from `../zunk`)

**Status of prior asks**:
- ✅ **Vertex buffer layouts** — landed and consumed in `src/gpu/web.zig:38-46`. No further ask from Teak.
- 🔜 **Samplers + textures** — workstream #1 below.
- 🔜 **Text-to-texture helper** — workstream #2 below (depends on #1).
- Open smaller items tracked in [`zunk-handoff.md`](zunk-handoff.md) (step-name collision, HiDPI coords, control-char leak, missing keys).

---

## Workstream 1 — Sampler + texture primitives

**Why**: Without samplers and textures, `zunk.web.gpu` can draw colored quads only. This blocks text rendering, images, rounded corners (if we ever SDF them), and any richer shader work. Native wgpu already has the full surface; web is the blocker.

**Priority**: **highest**. Blocks workstream 2.

### What Teak needs (minimum viable set)

Six additions to `zunk.web.gpu`. The surface below is a sketch — final names/shapes are zunk's call; these are semantic requirements.

#### 1.1 Texture handle + creation

```zig
pub const Texture = Handle;
pub const TextureView = Handle;

pub const TextureFormat = enum(u32) {
    rgba8_unorm,
    r8_unorm,       // single-channel — glyph atlases
    bgra8_unorm,
    // extend as needed
};

pub const TextureUsage = packed struct(u32) {
    copy_src: bool = false,
    copy_dst: bool = false,
    texture_binding: bool = false,
    storage_binding: bool = false,
    render_attachment: bool = false,
    _pad: u27 = 0,
};

pub fn createTexture(
    width: u32,
    height: u32,
    format: TextureFormat,
    usage: TextureUsage,
) Texture;

pub fn createTextureView(tex: Texture) TextureView;

pub fn textureDestroy(tex: Texture) void;
```

#### 1.2 CPU-bytes upload

```zig
pub fn writeTexture(
    tex: Texture,
    bytes: []const u8,
    /// Bytes per row in source data. For tightly packed data:
    /// width * bytes_per_pixel.
    bytes_per_row: u32,
    width: u32,
    height: u32,
) void;
```

`createTextureFromAsset(asset_handle)` already exists for asset-pipeline textures. Teak needs the CPU-bytes path because glyph atlases are generated per-frame from app state, not bundled at build time.

#### 1.3 Sampler handle + creation

```zig
pub const Sampler = Handle;

pub const FilterMode = enum(u32) { nearest, linear };
pub const AddressMode = enum(u32) { clamp_to_edge, repeat, mirror_repeat };

pub const SamplerDescriptor = extern struct {
    mag_filter: u32 = 0,    // FilterMode
    min_filter: u32 = 0,
    address_u: u32 = 0,     // AddressMode
    address_v: u32 = 0,
    _pad: u32 = 0,
};

pub fn createSampler(desc: SamplerDescriptor) Sampler;
```

No mipmaps, no anisotropy for Teak. `descriptor` struct leaves room to grow.

#### 1.4 BindGroupLayoutEntry extension

```zig
pub const TextureSampleType = enum(u32) { float, unfilterable_float, depth, sint, uint };
pub const SamplerBindingType = enum(u32) { filtering, non_filtering, comparison };

pub fn initTexture(
    binding: u32,
    visibility: u32,
    sample_type: TextureSampleType,
) BindGroupLayoutEntry;

pub fn initSampler(
    binding: u32,
    visibility: u32,
    sampler_type: SamplerBindingType,
) BindGroupLayoutEntry;
```

#### 1.5 BindGroupEntry extension

```zig
pub fn initTextureView(binding: u32, view: TextureView) BindGroupEntry;
pub fn initSampler(binding: u32, sampler: Sampler) BindGroupEntry;
```

#### 1.6 WGSL shader passthrough

No API work. Confirm that WGSL using `@group(0) @binding(1) var tex: texture_2d<f32>;` and `textureSample(tex, samp, uv)` passes through `createShaderModule` unchanged. This is standard WebGPU — should already work.

### Acceptance criteria

A zunk example `texture-demo` (or equivalent) that:

1. Creates a 2×2 `rgba8_unorm` texture with `texture_binding | copy_dst` usage.
2. Writes 16 bytes of CPU data (four colored pixels).
3. Creates a sampler with `linear` min/mag filter.
4. Creates a pipeline with a bind group that binds {uniform buffer, texture view, sampler}.
5. Renders a full-screen quad sampling the texture.
6. Result: the four colored pixels interpolate across the canvas.

### How Teak will consume it

On landing, Teak's `src/gpu/web.zig` gains a parallel text pipeline (not replacing the existing quad pipeline — both coexist). The quad pipeline continues to serve solid-fill widgets; the text pipeline takes UV-bearing vertices and samples a glyph atlas. No change needed in `src/gpu/context.zig`'s `validateGpu` contract — textures + samplers live inside the web-specific `init` and are exposed through the existing `uploadVertices` / `renderFrame` surface.

`src/gpu/native.zig` implements the same text path against wgpu-native in parallel. HARDLINE stays intact — textures are a GPU-layer detail; framework core above never sees them.

---

## Workstream 2 — Minimal text-to-texture helper

**Why**: Without this, every web consumer has to ship a Zig font rasterizer (fontdue, stb_truetype port, etc.) that runs in wasm. That's ~200 KB of binary per consumer and weeks of integration. Meanwhile, the browser already ships a full text shaper in canvas 2D. Expose it.

**Priority**: after workstream 1 lands. Completely depends on the texture primitives.

### What Teak needs (single function)

```zig
pub const TextMetrics = struct {
    width: u32,
    height: u32,
};

pub fn measureText(
    text: []const u8,
    font: []const u8,      // CSS font string: "14px monospace"
) TextMetrics;

pub fn rasterizeText(
    text: []const u8,
    font: []const u8,
    color: [4]f32,         // 0..1 RGBA — applied to foreground
    width: u32,            // texture size; usually measureText result
    height: u32,
) Texture;                 // rgba8_unorm, texture_binding | copy_dst
```

The resource created is a regular `Texture` from workstream 1 — same handle type, same binding path, same destroy call. No new concepts for the consumer.

JS side: offscreen `<canvas>`, set `ctx.font`, `ctx.fillStyle = "rgba(...)"`, `ctx.fillText(text, 0, baseline)`, copy pixels out with `getImageData`, upload via `queue.writeTexture`. Standard browser primitives, ~40 lines of JS.

### Acceptance criteria

A zunk example `text-demo` that:

1. Calls `measureText("Hello, world!", "20px sans-serif")` → `TextMetrics{w, h}`.
2. Calls `rasterizeText(text, font, .{1, 1, 1, 1}, w, h)` → `Texture`.
3. Binds the texture + a linear sampler in a pipeline.
4. Renders a quad covering `(0, 0)..(w, h)` sampling the texture.
5. Result: "Hello, world!" appears on screen, antialiased by canvas 2D.

### How Teak will consume it

Teak's widget emitters (`cb.text`, `cb.button`, `cb.textInput`) emit commands with a `content: []const u8`. The render pass today ignores `content` (we don't draw text). Post-workstreams-1-and-2:

1. Each frame, walk `[]Cmd`; collect unique `(content, font_size, color)` triples.
2. For each triple not in cache, call `rasterizeText` and cache the resulting texture handle.
3. Emit textured quads for text commands, sampling the cached texture at the widget's rect.
4. Drop cache entries unused for N frames (simple LRU).

Text-rendering UX remains **non-reactive** at the framework level — text is drawn, not interactive. Text input (cursor, selection) stays an app-level concern driven by `Msg` / `Model` as it is today. See `docs/features/components.md` for why.

**Layout**: `src/layout/engine.zig`'s `CHAR_WIDTH` approximation gets replaced by a `measureText` lookup at measure-pass time. This requires `measureText` to be callable *before* render — from inside `measurePass`. Which means `measureText` needs to be exposed to framework core, which currently cannot import `src/gpu/*` (HARDLINE §3). The fix: expose `measureText` through the Host interface, not the GPU interface. The Host owns the platform; the platform owns text measurement. Design to revisit when this lands.

---

## Workstream 3 — Anything else?

Open asks tracked in [`zunk-handoff.md`](zunk-handoff.md). In roughly descending impact on Teak:

1. **HiDPI coordinate-space mismatch** (handoff §2) — already worked around in `src/platform/wasm.zig`. Clean fix would let Teak drop its divide-by-DPR shim.
2. **`installApp` step-name collision** (handoff §1) — Teak inlines a fork in `build.zig`'s `linkWebWgpu`. A `run_step_name` option drops the fork.
3. **Control-char leak into `typed_chars`** (handoff §3) — worked around in `src/platform/wasm.zig`.
4. **Missing keys in `zunk.web.input.Key`** (handoff §4) — `Delete`, `Home`, `End`, `PageUp`, `PageDown`, `Insert`. Blocks text-input cursor navigation.
5. **Mouse edge events** (handoff §5) — synthesized on Teak side; zunk adding optional `mouse_buttons_pressed` / `released` bitmaps would let us drop the diff.

All are small. Any of them are fair game for zunk contributors looking for starter tasks; none block text rendering.

---

## Sequencing

```
workstream 1 (samplers + textures)
    ↓  [blocks workstream 2]
workstream 2 (text-to-texture)
    ↓  [unblocks Teak text rendering]
Teak glyph cache + textured quad pipeline + measureText-driven layout
```

**Parallel**: workstream 3 items — any contributor can pick one off `zunk-handoff.md`.

**Teak-side work**: waits for workstream 1. When 1 lands, Teak adds native + web texture pipelines in parallel to the existing quad pipeline (no interface churn above the GPU layer — HARDLINE §1 + escape hatch 4 keep the blast radius contained).

---

## Coordination

- **Path dep today**: `.zunk = .{ .path = "../zunk" }` in `build.zig.zon`. Will switch to tagged git URL once zunk cuts a release with workstream 1.
- **Design discussion**: open a zunk issue per workstream and cross-link from this doc. Teak is happy to iterate on the API shapes above before implementation — the shapes are sketches, not demands.
- **Zig version**: both projects track Zig 0.16.0. Coordinate bumps.
- **Non-goal on Teak's side**: introducing abstractions for texture/sampler support before workstream 1 lands. Per HARDLINE, we don't design for hypothetical features. The `Gpu` interface in `src/gpu/context.zig` stays as-is until there's working web code to compare against.
