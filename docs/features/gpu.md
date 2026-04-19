# Gpu interface

**Status**: `pub` in `src/teak.zig` as `ClearColor`, `validateGpu`.
**Source**: `src/gpu/context.zig`; concrete backends at `src/gpu/native.zig` (wgpu-native) and `src/gpu/web.zig` (zunk.web.gpu).
**Tests**: `validateGpu` has a colocated stub-acceptance test. Backend behavior is exercised by running the example.

Sibling of the [Host interface](host.md). The only layer allowed to import wgpu-native or `zunk.web.gpu` — everything above (`render/`, `layout/`, `input/`, `core/`) compiles `wasm32-freestanding`-clean, enforced by `zig build test-wasm`.

## Contract

A Gpu type must expose four declarations:

| Decl | Signature | Purpose |
|---|---|---|
| `init` | backend-specific (e.g. `fn(NativeHandle, u32, u32) !Gpu`) | Create device + surface + pipeline. **Not** validated — the `NativeHandle` shape differs per backend. |
| `deinit` | `fn(*Gpu) void` | Release GPU resources. |
| `resize` | `fn(*Gpu, u32, u32) void` | Reconfigure the surface. Called when `InputState.resized` is true. |
| `uploadVertices` | `fn(*Gpu, []const Vertex) void` | Copy the current frame's vertex buffer to the GPU. Called each frame after `buildVertices`. |
| `renderFrame` | `fn(*Gpu, ClearColor) void` | Encode + submit + present one frame using the last uploaded vertices. |

`ClearColor = [4]f32` (RGBA, 0..1). `validateGpu` comptime-asserts the four non-`init` decls exist. Compile-error format:

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
- **No textures / samplers.** Blocks text-rendering-via-glyph-atlas. Both upstream-blocked: the native backend could do it today; the web backend (zunk) lists samplers as a known coverage gap.
- **No multiple render passes.** Adding e.g. a post-process pass would expand the contract to `beginFrame` / `endFrame` pair — not planned.
- **No query objects / timestamps.** Profiling happens externally.
- **`init` signatures differ.** Native takes a Win32 `HWND` and window dimensions; web takes an empty placeholder (canvas is implicit to zunk). Example builds bind them explicitly.

## Test coverage target

- **Stub acceptance** (covered): `validateGpu` accepts a minimal conformant struct.
- **Gap tests** (missing): one compile-fail test per missing decl.
- **Vertex upload round-trip** (missing, backend-specific): a native test that uploads a known triangle and reads back the framebuffer pixel. Would catch vertex-layout drift between Zig and WGSL. Web-side equivalent blocked on zunk adding a readback API.
- **Cross-backend screenshot diff** (long-term): render the same scene on both backends and compare. Out of scope until the web GPU coverage gaps close.
