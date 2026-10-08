# Gpu interface

**Status**: `pub` in `src/teak.zig` as `ClearColor`, `validateGpu`, `InitOptions` (via `teak.gpu`), plus the scene data types (see [scene3d.md](scene3d.md)).
**Source**: `src/gpu/context.zig`; the wgpu pipeline is `src/gpu/wgpu_core.zig` (helpers in `wgpu_c.zig`, 3D in `wgpu_scene.zig`), bound to a concrete backend by `src/gpu/native.zig` (Windows) and `src/gpu/native_linux.zig` (Linux); the web backend is `src/gpu/web.zig` (+ `web_scene.zig`, on zunk.web.gpu). Shared, GPU-free pieces: `slot_table.zig`, `scene_common.zig`.
**Tests**: `validateGpu` has colocated acceptance tests (and each backend runs it in a `comptime` block). `zig build test` covers the pure pieces (`slot_table`, `scene_common`, `render/vertex.zig`). `zig build test-gpu` renders on a surface-less Vulkan device and checks pixels (depth test, lighting, line quads, scene compositing + clip, MSAA edges, images); it skips when no Vulkan device opens. The web backend is verified by running an app in headless Chromium (`--webgpu`, SwiftShader).

Sibling of the [Host interface](host.md). The only layer allowed to import wgpu-native or `zunk.web.gpu` — everything above (`render/`, `layout/`, `input/`, `core/`) compiles `wasm32-freestanding`-clean, enforced by `zig build test-wasm`.

## Provider decomposition (`wgpu_core.Gpu(Surface, Rasterizer)`)

The two native backends share **one** wgpu pipeline. `wgpu_core.zig`
exposes `pub fn Gpu(comptime Surface: type, comptime Rasterizer: type)
type` — the full wgpu lifecycle (instance, adapter, device, the quad /
text / image pipelines, the glyph cache) parameterized over two seams:

- **`Surface`** — a *surface provider* exposing `Handle` + `createSurface(WGPUInstance, anytype) !WGPUSurface`. `surface_win32.zig` wraps an HWND pair; `surface_xlib.zig` wraps an X11 `Display*` + `Window` XID. `createSurface` takes the handle as `anytype`, so the Host's structurally-identical `NativeHandle` coerces without the platform layer importing the gpu layer.
- **`Rasterizer`** — a *rasterizer provider* exposing `init(Allocator)` / `deinit` / `rasterize(bytes, FontSpec, [4]f32, w, h) ?Bitmap`, returning a **BGRA8, top-down** `Bitmap` (`[b, g, r, coverage]` per pixel) ready for a `BGRA8Unorm` texture upload. `raster.StbttRasterizer` (vendored stb_truetype) is used on every native OS.

The OS stitch files bind the concrete pair and `validateGpu` it:

```zig
// native.zig (Windows)
pub const Gpu = wgpu_core.Gpu(surface_win32, text.StbttRasterizer);
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
`text_stage.TextStage(Raster)`). `wgpu_core.zig` owns the **single**
`@cImport` of the wgpu headers; both surface providers re-import it
(`@import("wgpu_core.zig").c`) so `WGPUSurface` / `WGPUInstance` have one
type identity across the seam — without that, each file's `@cImport` would
mint a distinct `WGPUSurface` and the seam wouldn't typecheck.

**Text differs per OS, layout doesn't.** Both native OSes use the
`teak-text` module (`src/text/`): it provides **both** the GPU
rasterizer *and* the Host's `TextMeasurer` (X11 and Win32) from the **same**
loaded font, so measure-vs-render metrics can't drift. Windows probes
`%WINDIR%\Fonts` (Consolas, Courier New, Lucida Console, ...); the GDI
rasterizer is gone. v1 loads one monospace
face (DejaVuSansMono by default; override with `TEAK_FONT`) and ignores
`FontSpec.family`.

## Frame structure

1. `uploadVertices` / `uploadText` / `uploadImages` stage the UI draws.
2. `renderScenes` (optional extension) renders each 3D scene into an offscreen colour + depth (+4x MSAA) target of the scene's pixel size and stages one composite quad per scene. Native submits its own command buffer; web records into zunk's frame encoder, so the scene is complete before the main pass samples it.
3. `renderFrame` / `renderToWindow`: the main pass draws, in this order, solid quads, images, scene composites, text. Scene composites reuse the image pipeline and the image clip rules (`render/vertex.zig: clippedTexturedQuad`), and are snapped to the device pixel grid so the target maps 1:1 onto screen pixels.

**Overlay layering.** The render pass builds two layers (base z=0, overlay z=1; HARDLINE §2 hatch 5) into the same lists and `buildFrame` returns an `OverlaySplit` (how many vertices / text / image / scene draws the base layer produced). A Gpu with the optional `setOverlayStart(*Gpu, OverlaySplit)` extension (both backends; `teak.run` calls it before each frame's uploads) draws in this order: base solids, base images, base scene composites, base text, THEN overlay solids, images, composites, text. That is what lets an opaque popup (an overlay with an opaque backdrop) hide the base layer's text, images and scenes beneath it; drawing all text last would show base text through the panel. The staging loops translate the split from input-draw indices to staged-record indices (`gpu/overlay.zig`, `Marker`) because skipped draws shift them. Backends or loops without it draw by kind, as before. Tested natively by `zig build test-gpu` (opaque overlay vs base text and image, overlay text stays on top) and on web by the chrome example.

A scene slot is only re-rendered when its `scene_common.signature` (camera, clear colour, edge style, mesh version, target size) changes; a scene next to an animating widget costs nothing per frame.

## Init options (MSAA)

```zig
Gpu.init(handle, w, h)                                  // == initWithOptions(.., .{})
Gpu.initWithOptions(handle, w, h, teak.gpu.InitOptions{ .msaa = false, .scene_msaa = true })
```

`msaa` multisamples the **main UI pass** 4x (extra full-size colour target, resolved into the swap-chain; every main-pass pipeline is built for 4 samples) so rotated quads and canvas triangles get antialiased edges. It is **off** by default: axis-aligned UI is pixel-exact without it. `scene_msaa` (default on) multisamples scene targets. On web the MSAA target is sized from the canvas's backing store (CSS size x devicePixelRatio) every frame.

Scene targets are device-resolution: on web `scene_scale = canvas width / teak width` (= devicePixelRatio), so 3D stays crisp on HiDPI while the rest of teak keeps working in CSS pixels; `SceneDraw.edge_px` is in logical pixels.

## Contract

A Gpu type must expose these declarations:

| Decl | Signature | Purpose |
|---|---|---|
| `init` | backend-specific (e.g. `fn(NativeHandle, u32, u32) !Gpu`) | Create device + surface + pipelines. **Not** validated — the `NativeHandle` shape differs per backend. |
| `deinit` | `fn(*Gpu) void` | Release GPU resources. |
| `resize` | `fn(*Gpu, u32, u32) void` | Reconfigure the surface. Called when `InputState.resized` is true. |
| `setScale` *(optional; wgpu_core)* | `fn(*Gpu, f32) void` | Change device pixels per logical pixel at runtime (the window moved to a monitor with another DPI). The run loop calls it when `Host.scaleFactor()` changes; the initial value is `InitOptions.scale`. |
| `uploadVertices` | `fn(*Gpu, []const Vertex) void` | Copy the current frame's colored-quad vertex buffer to the GPU. Called each frame after `buildVertices`. |
| `renderFrame` | `fn(*Gpu, ClearColor) void` | Encode + submit + present one frame using the last uploaded vertices, text draws, and image draws. |
| `rasterizeText` | `fn(*Gpu, []const u8, FontSpec, [4]f32, u32, u32) TextureHandle` | **Web only; no longer required** (native backends draw text from the glyph atlas in `uploadText`). Rasterize a string into a cached texture and return an opaque handle. |
| `uploadText` | `fn(*Gpu, []const TextDraw) void` | Per-frame: ingest the renderer's `TextDraw` list and build the textured-quad buffer that `renderFrame` will draw. |
| `uploadImage` | `fn(*Gpu, []const u8, u32, u32) TextureHandle` | Upload an RGBA8 image (`width * height * 4` bytes) and return an opaque handle the app stashes in `ImageCmd.handle`. App-driven cache; cached for the lifetime of the Gpu. Implemented on both native and web (web wires zunk v0.6.0+ texture upload). |
| `uploadImages` | `fn(*Gpu, []const ImageDraw) void` | Per-frame counterpart to `uploadText` for images. Walks `ImageDraw`s and records a draw entry per visible image. |
| `setOverlayStart` | `fn(*Gpu, OverlaySplit) void` | *Optional.* Where the overlay layer starts in each staged list; call before `uploadVertices` / `uploadText` / `uploadImages` / `renderScenes` each frame (see "Overlay layering"). |
| `releaseImage` | `fn(*Gpu, TextureHandle) void` | Free an `uploadImage` texture; the slot is reused by the next upload. The handle is dead afterwards (no generation counter). The image table grows on demand (up to 65536 live images, then `uploadImage` logs and returns none); there is no eviction because handles are app-owned. |
| `uploadMesh` | `fn(*Gpu, MeshData) MeshHandle` | *Optional scene block.* Copy mesh geometry to GPU buffers (128-slot table). `MESH_HANDLE_NONE` on invalid data (`MeshData.validate`) or a full table. |
| `releaseMesh` | `fn(*Gpu, MeshHandle) void` | *Optional scene block.* Free a mesh. On web, call between frames (a mesh destroyed while a recorded-but-unpresented frame still uses it invalidates the submit). |
| `renderScenes` | `fn(*Gpu, []const SceneDraw) void` | *Optional scene block.* Render up to 16 scenes offscreen and stage their composites for the next `renderFrame`. Pass an empty slice to clear last frame's composites. |
| `renderToWindow` | `fn(*Gpu, u32, ClearColor) void` | Render the last-uploaded buffers into the surface for `window_id` (0 = primary, ≥1 = secondaries opened via `openSecondarySurface`). `renderFrame` is a thin wrapper for `renderToWindow(0, ...)`. The shared uniform buffer is rewritten with the target window's pixel dims before each call. |
| `openSecondarySurface` | `fn(*Gpu, *anyopaque, *anyopaque, u32, u32) ?u32` | Create a wgpu surface bound to an additional native window. Takes `(hinstance, hwnd, w, h)` as opaque pointers so the GPU module never imports platform types (HARDLINE §4(c)). Returns a 1-based id matching the Host's secondary id space. |
| `closeSecondarySurface` | `fn(*Gpu, u32) void` | Release the surface for the given secondary id. No-op on invalid ids. |
| `resizeWindow` | `fn(*Gpu, u32, u32, u32) void` | Reconfigure a window's surface. `id = 0` is the primary (same effect as `resize`). |

`ClearColor = [4]f32` (RGBA, 0..1). `validateGpu` comptime-asserts every required decl above. `rasterizeText` / `uploadText` / `uploadImage` / `uploadImages` / `renderToWindow` / `openSecondarySurface` / `closeSecondarySurface` / `resizeWindow` are HARDLINE §4(d) surface extensions added during / after the `functional_gaps_yolo` push. `releaseImage` is required. The scene block (`uploadMesh` + `releaseMesh` + `renderScenes`) is an *optional* extension checked only when declared (like `Host.scaleFactor`): the scene trio must come together, each a function; `teak.run` calls them only when present. Compile-error format:

```
Gpu 'MyGpu' is missing declaration 'uploadVertices'
```

## Invariants

- **Single owner.** One Gpu per app, created after the Host.
- **Fixed pipelines.** Backends build their pipelines at `init` (solid, text, image, and the two scene pipelines). Shader, vertex layout, target format are all baked in. Swapping shaders at runtime is out of scope.
- **Vertex format is shared.** Both backends consume `teak.Vertex` (8 × f32 interleaved: pos, color, uv). Changing `Vertex` is a coordinated change across `render/vertex.zig`, `shaders/quad.wgsl`, and both backends.
- **`uploadVertices` is a replace, not an append.** Each call overwrites the buffer. Old frames' data is gone.
- **`renderFrame` is atomic.** One clear + the staged draws + one present. Scene targets are rendered earlier by `renderScenes`, never inside the main pass.
- **Native-only headless entry points.** `initFromDevice(instance, null, ctx, w, h, opts)` + `renderToTexture(texture, w, h, clear)` run the whole UI frame without a surface (tests, screenshots).

## Non-goals / known limits

- **No depth in the main pass.** The UI is 2D; painter's order gives z-ordering. Depth exists only inside scene targets (32-bit float, `less`).
- **Scenes composite with the images**: within a layer (base or overlay) above the solid quads and below the text. An overlay with an opaque backdrop hides base-layer scenes, images and text.
- **At most 16 scenes per frame**, 128 meshes, 64 images; extras are dropped / refused.
- **No post-process passes.** Adding one would expand the contract to a `beginFrame` / `endFrame` pair — not planned.
- **No query objects / timestamps.** Profiling happens externally.
- **`init` signatures differ.** Native takes the Host's `nativeHandle()` (an HWND pair on Windows, a `Display*` + `Window` on Linux — duck-typed via `anytype`) and window dimensions; web takes an empty placeholder (canvas is implicit to zunk). Example builds bind them explicitly.
- **Multi-window: Win32 only so far.** `renderToWindow(id)` works for both primary (id 0) and secondary windows on Win32 + native wgpu, with per-surface tables on both Host and Gpu layers. The shared uniform buffer holds the target window's dims and is rewritten at the start of every `renderToWindow` call so cross-window renders don't bleed each other's viewports. The Linux X11 backend currently exposes the primary surface only (secondary X11 windows are not yet wired). Wasm `openSecondaryWindow` returns null — no secondary surfaces on web.

## Test coverage target

- **Stub acceptance** (covered): `validateGpu` accepts a minimal conformant struct.
- **Gap tests** (missing): one compile-fail test per missing decl.
- **Vertex upload round-trip** (covered natively by `zig build test-gpu`: triangle edges, quads, scenes, images read back from an offscreen target). The web side now has zunk readback (`Readback`), but no automated pixel test yet; it is checked by screenshot.
- **Cross-backend screenshot diff** (long-term): render the same scene on both backends and compare. Out of scope until the web GPU coverage gaps close.
