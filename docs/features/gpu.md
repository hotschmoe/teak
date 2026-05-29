# Gpu interface

**Status**: `pub` in `src/teak.zig` as `ClearColor`, `validateGpu`.
**Source**: `src/gpu/context.zig`; the wgpu pipeline is `src/gpu/wgpu_core.zig`, bound to a concrete backend by `src/gpu/native.zig` (Windows) and `src/gpu/native_linux.zig` (Linux); the web backend is `src/gpu/web.zig` (zunk.web.gpu).
**Tests**: `validateGpu` has a colocated stub-acceptance test (and each native stitch runs it in a `comptime` block). Backend behavior is exercised by running the example.

Sibling of the [Host interface](host.md). The only layer allowed to import wgpu-native or `zunk.web.gpu` — everything above (`render/`, `layout/`, `input/`, `core/`) compiles `wasm32-freestanding`-clean, enforced by `zig build test-wasm`.

## Provider decomposition (`wgpu_core.Gpu(Surface, Rasterizer)`)

The two native backends share **one** wgpu pipeline. `wgpu_core.zig`
exposes `pub fn Gpu(comptime Surface: type, comptime Rasterizer: type)
type` — the full wgpu lifecycle (instance, adapter, device, the quad /
text / image pipelines, the glyph cache) parameterized over two seams:

- **`Surface`** — a *surface provider* exposing `Handle` + `createSurface(WGPUInstance, anytype) !WGPUSurface`. `surface_win32.zig` wraps an HWND pair; `surface_xlib.zig` wraps an X11 `Display*` + `Window` XID. `createSurface` takes the handle as `anytype`, so the Host's structurally-identical `NativeHandle` coerces without the platform layer importing the gpu layer.
- **`Rasterizer`** — a *rasterizer provider* exposing `init(Allocator)` / `deinit` / `rasterize(bytes, FontSpec, [4]f32, w, h) ?Bitmap`, returning a **BGRA8, top-down** `Bitmap` (`[b, g, r, coverage]` per pixel) ready for a `BGRA8Unorm` texture upload. `raster_gdi.GdiRasterizer` uses Win32/GDI; `text_stbtt.StbttRasterizer` uses vendored stb_truetype.

The OS stitch files bind the concrete pair and `validateGpu` it:

```zig
// native.zig (Windows)
pub const Gpu = wgpu_core.Gpu(surface_win32, raster_gdi.GdiRasterizer);
// native_linux.zig (Linux)
pub const Gpu = wgpu_core.Gpu(surface_xlib, text.StbttRasterizer);
```

`build.zig`'s `linkNativeWgpu` selects the stitch by target OS and exposes
it under the stable import name `teak-gpu-native`, so one `ui_main.zig`
compiles on both.

**Why parameterize instead of `switch (builtin.os.tag)`?** Each OS's
`extern`s (GDI vs Xlib) only land in *that* OS's translation unit — the
Linux build never sees the GDI externs and vice-versa, so there is no
comptime platform gating inside the gpu layer (the same idiom as
`glyph_cache.GlyphCache(Backend)`). `wgpu_core.zig` owns the **single**
`@cImport` of the wgpu headers; both surface providers re-import it
(`@import("wgpu_core.zig").c`) so `WGPUSurface` / `WGPUInstance` have one
type identity across the seam — without that, each file's `@cImport` would
mint a distinct `WGPUSurface` and the seam wouldn't typecheck.

**Text differs per OS, layout doesn't.** On Windows the GDI rasterizer
backs rendering and the Win32 Host's GDI measurer backs layout. On Linux
the `teak-text` module (`text_stbtt.zig`) provides **both** the GPU
rasterizer *and* the X11 Host's `TextMeasurer` from the **same** loaded
font, so measure-vs-render metrics can't drift. v1 loads one monospace
face (DejaVuSansMono by default; override with `TEAK_FONT`) and ignores
`FontSpec.family`.

## Contract

A Gpu type must expose these declarations:

| Decl | Signature | Purpose |
|---|---|---|
| `init` | backend-specific (e.g. `fn(NativeHandle, u32, u32) !Gpu`) | Create device + surface + pipelines. **Not** validated — the `NativeHandle` shape differs per backend. |
| `deinit` | `fn(*Gpu) void` | Release GPU resources. |
| `resize` | `fn(*Gpu, u32, u32) void` | Reconfigure the surface. Called when `InputState.resized` is true. |
| `uploadVertices` | `fn(*Gpu, []const Vertex) void` | Copy the current frame's colored-quad vertex buffer to the GPU. Called each frame after `buildVertices`. |
| `renderFrame` | `fn(*Gpu, ClearColor) void` | Encode + submit + present one frame using the last uploaded vertices, text draws, and image draws. |
| `rasterizeText` | `fn(*Gpu, []const u8, FontSpec, [4]f32, u32, u32) TextureHandle` | Rasterize a string at a given font + color into a glyph-atlas texture and return an opaque handle. Backends cache by (text, font, color); the app stashes the handle in its Model. |
| `uploadText` | `fn(*Gpu, []const TextDraw) void` | Per-frame: ingest the renderer's `TextDraw` list and build the textured-quad buffer that `renderFrame` will draw. |
| `uploadImage` | `fn(*Gpu, []const u8, u32, u32) TextureHandle` | Upload an RGBA8 image (`width * height * 4` bytes) and return an opaque handle the app stashes in `ImageCmd.handle`. App-driven cache; cached for the lifetime of the Gpu. Implemented on both native and web (web wires zunk v0.6.0+ texture upload). |
| `uploadImages` | `fn(*Gpu, []const ImageDraw) void` | Per-frame counterpart to `uploadText` for images. Walks `ImageDraw`s and records a draw entry per visible image. |
| `renderToWindow` | `fn(*Gpu, u32, ClearColor) void` | Render the last-uploaded buffers into the surface for `window_id` (0 = primary, ≥1 = secondaries opened via `openSecondarySurface`). `renderFrame` is a thin wrapper for `renderToWindow(0, ...)`. The shared uniform buffer is rewritten with the target window's pixel dims before each call. |
| `openSecondarySurface` | `fn(*Gpu, *anyopaque, *anyopaque, u32, u32) ?u32` | Create a wgpu surface bound to an additional native window. Takes `(hinstance, hwnd, w, h)` as opaque pointers so the GPU module never imports platform types (HARDLINE §4(c)). Returns a 1-based id matching the Host's secondary id space. |
| `closeSecondarySurface` | `fn(*Gpu, u32) void` | Release the surface for the given secondary id. No-op on invalid ids. |
| `resizeWindow` | `fn(*Gpu, u32, u32, u32) void` | Reconfigure a window's surface. `id = 0` is the primary (same effect as `resize`). |

`ClearColor = [4]f32` (RGBA, 0..1). `validateGpu` comptime-asserts every non-`init` decl above. `rasterizeText` / `uploadText` / `uploadImage` / `uploadImages` / `renderToWindow` / `openSecondarySurface` / `closeSecondarySurface` / `resizeWindow` are HARDLINE §4(d) surface extensions added during / after the `functional_gaps_yolo` push. Compile-error format:

```
Gpu 'MyGpu' is missing declaration 'uploadVertices'
```

## Invariants

- **Single owner.** One Gpu per app, created after the Host.
- **Fixed pipeline.** Backends build one render pipeline at `init`. Shader, vertex layout, target format are all baked in. Swapping shaders at runtime is out of scope.
- **Vertex format is shared.** Both backends consume `teak.Vertex` (8 × f32 interleaved: pos, color, rect_pos, rect_size). Changing `Vertex` is a coordinated change across `render/vertex.zig`, `shaders/quad.wgsl`, and both backends.
- **`uploadVertices` is a replace, not an append.** Each call overwrites the buffer. Old frames' data is gone.
- **`renderFrame` is atomic.** One clear + one draw of the uploaded vertices + one present. No partial submits, no multi-pass.

## Non-goals / known limits

- **No depth / stencil.** Teak is 2D; painter's order gives us z-ordering.
- **No multiple render passes.** Adding e.g. a post-process pass would expand the contract to `beginFrame` / `endFrame` pair — not planned.
- **No query objects / timestamps.** Profiling happens externally.
- **`init` signatures differ.** Native takes the Host's `nativeHandle()` (an HWND pair on Windows, a `Display*` + `Window` on Linux — duck-typed via `anytype`) and window dimensions; web takes an empty placeholder (canvas is implicit to zunk). Example builds bind them explicitly.
- **Multi-window: Win32 only so far.** `renderToWindow(id)` works for both primary (id 0) and secondary windows on Win32 + native wgpu, with per-surface tables on both Host and Gpu layers. The shared uniform buffer holds the target window's dims and is rewritten at the start of every `renderToWindow` call so cross-window renders don't bleed each other's viewports. The Linux X11 backend currently exposes the primary surface only (secondary X11 windows are not yet wired). Wasm `openSecondaryWindow` returns null — no secondary surfaces on web.

## Test coverage target

- **Stub acceptance** (covered): `validateGpu` accepts a minimal conformant struct.
- **Gap tests** (missing): one compile-fail test per missing decl.
- **Vertex upload round-trip** (missing, backend-specific): a native test that uploads a known triangle and reads back the framebuffer pixel. Would catch vertex-layout drift between Zig and WGSL. Web-side equivalent blocked on zunk adding a readback API.
- **Cross-backend screenshot diff** (long-term): render the same scene on both backends and compare. Out of scope until the web GPU coverage gaps close.
