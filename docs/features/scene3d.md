# 3D scenes — depth-tested meshes inside the UI

**Status**: `pub` in `src/teak.zig` as `MeshData`, `MeshVertex`, `LineVertex`, `MeshHandle`, `MESH_HANDLE_NONE`, `Camera`, `SceneDraw`, `SceneCmd`, `SceneStyle`, `Resource`, `MeshResource`, `ImageResource`, `buildFrame`; the emitter is `CmdBuffer.scene3d`.
**Source**: `src/core/scene.zig` (data), `src/core/cmd.zig` (`SceneCmd`), `src/render/build.zig` (`SceneDraw` emission), `src/core/resources.zig` + `src/resources.zig` (declarative resources), `shaders/scene.wgsl`, backends `src/gpu/wgpu_scene.zig` + `src/gpu/web_scene.zig`, shared `src/gpu/scene_common.zig`.
**Tests**: `zig build test` (data, layout, hit-test, snapshot, a11y, render, resource table, run loop with a recording Gpu, `scene_common`); `zig build test-gpu` (real rendering + pixel readback on a Vulkan device); the `examples/scene3d` app on web and native.

Worked example: `examples/scene3d` (stud-wall mesh with edges + grid, orbiting camera driven by a `Sub` tick, a vector canvas of alpha-feathered triangles over a batched hatch, mesh declared through `resources()`; native via `teak.run` with MSAA on, web via a hand loop using `teak.ResourceTable` / `teak.stageDraws`).

A `scene3d` Cmd is a fixed-size leaf the Gpu fills with a **flat-shaded, lit, depth-tested triangle mesh plus constant-pixel-width feature lines**. It exists so a CAD-style app can show a 3D model beside regular teak widgets (and 2D vector linework via [canvas](canvas.md) triangles) without leaving the TEA loop: the app keeps a `Camera` in its `Model`, a `Msg` orbits it, `view` emits the Cmd.

## Contract

```zig
// data (core/scene.zig)
MeshVertex = extern struct { pos: [3]f32, normal: [3]f32, color: [4]f32 }   // 40 B
LineVertex = extern struct { pos: [3]f32, color: [4]f32 }                   // 28 B
MeshData   = struct { vertices: []const MeshVertex, indices: []const u32,   // triangle list
                      lines: []const LineVertex }                           // consecutive pairs = segments
Camera     = struct { view_proj: [16]f32,   // column-major projection*view, WebGPU clip (z 0..1, +y up)
                      eye: [3]f32,          // for two-sided lighting / headlight
                      light_dir: [3]f32 }   // direction the light travels; zero vector = headlight

// the Cmd (core/cmd.zig)
cb.scene3d(SceneCmd(Msg){
    .style = .{ .width = 480, .height = 360, .flex = 0 },
    .mesh = key_or_handle, .camera = cam,
    .clear = .{ 0.1, 0.11, 0.14, 1 },
    .edge_color = .{ 1, 1, 1, 1 }, .edge_px = 1.5,   // lines: colour = vertex colour * edge_color
    .key = rev,                                       // content revision (see below)
    .id = 0, .pointer = false, .msg = null, .label = "model view" });

// the Gpu (optional extension block of validateGpu)
uploadMesh(*Gpu, MeshData) MeshHandle      releaseMesh(*Gpu, MeshHandle) void
renderScenes(*Gpu, []const SceneDraw) void
```

Pipeline: `view` emits `scene3d` -> layout sizes it from `style` (like `image`) -> render pass emits a `SceneDraw` (rect, clip, camera, clear, edge style) per visible scene in painter order -> `Gpu.renderScenes` renders each into an offscreen colour + 32-bit-float depth (+4x MSAA) target of the scene's **device-pixel** size and stages a composite quad -> the main pass draws that quad with the image pipeline, clipped by the same scroll/overlay rules as images. See [gpu.md](gpu.md) for the frame structure.

### Shading and lines

- **Triangles**: flat colour from the vertex colour, one directional light + 0.35 ambient, **two-sided** (a face is lit as if it faced the camera; orientation uses `eye`, winding is irrelevant, no culling). Alpha is ignored (opaque). Depth test `less`, depth write on.
- **Lines**: each segment is drawn as an **instanced** camera-facing quad (one instance per `LineVertex` pair, six vertices per instance, vertex-stage expansion — no geometry shader) of `edge_px` logical pixels, extended half a width past each end so polylines join without gaps; the segment is clipped to the near plane before the perspective divide. Colour = line vertex colour x `edge_color`, alpha-blended, depth-**tested** (`less_equal`) but not written, with a small NDC depth bias (`1e-4`) so lines lying on faces win. Ground grids and construction lines use the same path: put them in `MeshData.lines`.
- Coordinates are world space; there is no model matrix (bake it into `view_proj` or the vertices). Pick a tight near/far: the line bias is a constant in NDC depth.

### Resources: `resources()` hook (HARDLINE hatch 8)

Without the hook, `SceneCmd.mesh` is a handle from `Gpu.uploadMesh` (and `ImageCmd.handle` one from `uploadImage`) that the app must store. With it, the App declares data and never sees a handle:

```zig
pub fn resources(m: *const Model) []const teak.Resource {
    return &.{
        .{ .mesh  = .{ .key = 1, .rev = m.mesh_rev, .data = m.mesh } },
        .{ .image = .{ .key = 2, .rev = 1, .width = 64, .height = 64, .rgba = m.icon } },
    };
}
// view: cb.scene3d(.{ .mesh = 1, .key = m.mesh_rev, ... });  cb.image(2, .{});
```

The loop uploads on a new `key`, re-uploads when `rev` changes, releases vanished keys, and maps keys to handles in the draw records (details in [run.md](run.md#resources-optional-hook)). **Bump `SceneCmd.key` together with the mesh `rev`**: the frame diff cannot see inside a mesh, only that the `mesh` key is unchanged.

### Pointer routing

`id` / `pointer` follow the canvas contract exactly ([canvas.md](canvas.md), `core/pointer.zig`), in the same `id` space as interactive canvases: a `pointer = true`, `id != 0` scene delivers `CanvasEvent`s (`layout` on first layout and resize, then `move` / `down` / `up` / `wheel` / `leave`, scene-local logical pixels, capture until every button is released, wheel over it goes to `canvasMsg` instead of `wheelMsg`) through the App's `canvasMsg(*const Model, CanvasEvent) ?Msg` hook, so the app can orbit / zoom / pan by dragging and keep the `Camera` in its `Model`. A pointer scene claims clicks (widgets behind it are not hit) but has no click Msg; a non-pointer scene with `msg` set is a plain click target. Routing lives in `hit_test.pointerTarget` / `pointerSurface` / `wheelTarget` and `run`'s `Runtime`; the scene participates through the same `pointerSurface` probe as canvases, so ids must be unique across both kinds.

## Per-pass behaviour

| Pass | Behaviour |
|---|---|
| Layout | Fixed-size leaf from `style.width/height`; `flex` counted for siblings (as `image`). |
| Hit-test | Interactive with a `msg` or `pointer = true` (shared leaf probe); `pointerSurface` / `wheelTarget` route pointer scenes like canvases. |
| Render | `SceneDraw` per visible scene (base layer, then overlay layer); nothing is added to the solid-vertex stream. `buildVertices` (the scene-less entry point) skips scenes. |
| Snapshot | `scene3d (x,y,w,h) mesh=N key=K [id=I] [pointer] ["label"]` |
| A11y | `Role.image` node with `label`. |
| Frame diff | `SceneCmd.eql`: every field (incl. `id`, `pointer`), label by content. |

## Invariants

- The `Cmd` is data (camera = 16 floats); meshes are uploaded once, never rebuilt per frame.
- A scene whose (camera, clear, edge style, mesh version, target size) is unchanged is **not re-rendered** (`scene_common.signature`); moving or clipping it only changes the composite quad.
- Scene targets are device-resolution (on web `devicePixelRatio` x CSS size), so the composite is a 1:1 pixel copy; `edge_px` is logical pixels.
- At most 16 scenes per frame and 128 resident meshes; extras are dropped / refused (`MESH_HANDLE_NONE`).

## Non-goals / known limits

- Composites draw with the images: within a layer above the solid quads and below the text; an opaque overlay hides base-layer scenes (overlay layering, see [gpu.md](gpu.md)).
- No transparency, no textures, no PBR, no picking against geometry (pick in app code from the camera + your own data), no per-object transforms, no shadows, no stencil.
- Release meshes between frames on web (a mesh destroyed while an unpresented recorded frame uses it invalidates the submit); `teak.run` releases during resource sync, before the frame is recorded.
- wgpu-native cannot open Chromium's SwiftShader ICD; `zig build test-gpu` needs a real Vulkan driver (it skips otherwise).
