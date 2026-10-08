# `teak.scene` — Viewport3D and 2.5D layers

**Status**: M1 and M2 shipped except the optional ID-buffer pick (M1b) and
text/offscreen planes (M2c). Shipped: camera, picking and section math (S1/S2),
the `View` payload (S3), instanced items with tint / highlight / flat (S4),
ground grid and axis gizmo (S5), section cuts with stencil caps and exact
outlines (S6), planes, sprites, depth sorting and their picking (P1-P3), and
the examples `kerf_viewer` and `scene_layers` (S7 / P4). How-to:
[cookbook recipe 15](../cookbook.md). Sections below keep the original design
rationale; where the implementation differs it is noted inline: the packed
instance record is 80 bytes, `Globals` is 208 bytes, scene targets are
`Depth24PlusStencil8`, `renderScenes` takes `SceneData{items, sprites}`, planes
are plane-local canvas primitives placed by `origin + x*u + y*v` (so +y of the
content maps to `v`), and sprite `screen_px` sizes apply to `camera_facing`. Builds on the shipped `scene3d` Cmd
([scene3d.md](scene3d.md)); nothing here changes the existing contract, it
extends it. Consumers: Kerf's teak app (CAD model view, section cuts, picking),
diagram / sheet previews (M2).

Reading order for implementers: [HARDLINE.md](../HARDLINE.md) §1-3 and hatches
7 + 8, [scene3d.md](scene3d.md), `src/core/scene.zig`, `src/gpu/scene_common.zig`,
`src/gpu/wgpu_scene.zig` / `web_scene.zig`, `shaders/scene.wgsl`.

## 0. Where we start (what exists, what is missing)

Shipped: one `scene3d` leaf per viewport; a mesh is `MeshData{vertices (pos,
normal, color), u32 indices, line pairs}` uploaded by key/rev through the
`resources()` hook (hatch 8); camera is a bare `view_proj` + eye + light in the
`Cmd`; the Gpu renders each scene into a device-resolution offscreen colour +
Depth32Float (+4x MSAA) target, skips re-rendering on an unchanged signature,
and the main pass composites the target like an image (clipped by scroll /
overlay rules). Pointer scenes deliver `CanvasEvent`s through `canvasMsg`.
Lines are instanced camera-facing quads with a depth bias. Kerf's archived app
(`apps/teak/src/app/{scene3d,cam}.zig`) shows the hand-rolled version: an
`Orbit{yaw,pitch,dist,target}` + `viewProj`, parts concatenated into one
`MeshData`, ground grid baked into `lines`, selection by re-colouring vertices
and re-uploading the whole mesh.

Missing, and what this design adds:

| Gap | Resolution |
|---|---|
| One mesh per scene, no per-object transform / tint / id | `View.items`: arena slice of `Item` (mesh key + 3x4 transform + tint + id + flags), drawn instanced |
| Camera math lives in apps | `core/scene/camera.zig`, pure, tested; `Orbit` struct lives in `Model` |
| Ortho projection | `Projection = persp \| ortho` in the camera helper (the Cmd still carries only matrices) |
| Selection requires mesh rebuild | per-item tint / `highlight` flag; no re-upload |
| No picking | CPU ray pick (pure, M1) + optional ID-buffer pick via hatch 7 (M1b) |
| No section cut | clip plane in the shader + stencil-parity caps |
| Grid is 80 line segments in the mesh | procedural grid pass (AA, fading, infinite-looking) |
| No gizmo | corner sub-viewport axis gizmo + pure hit/label helpers |
| No 2.5D | M2: planes carrying canvas primitives, sprites, depth-sorted layers |

## 1. Design principles (HARDLINE compliance)

This is the section a reviewer should check first.

1. **All scene state is in `Model`.** Camera (`Orbit`), projection mode, cut
   plane, grid/gizmo toggles, selection, hover id, item list inputs: plain
   structs of floats and ids. No `Viewport3D` object exists at runtime.
2. **Every transition is a `Msg`.** Pointer / wheel arrive as `CanvasEvent`s via
   the existing `canvasMsg` hook, the app wraps them in a Msg, `update` calls
   the pure helper `orbit.onEvent(...)`. Gizmo clicks, "view cube" presets and
   cut-plane drags are Msgs. A pick result is a Msg (section 6).
3. **`view` is pure and declarative.** `cb.viewport3d(.{...})` emits one `Cmd`
   carrying a `View` value: camera matrices, flags and **arena-allocated
   slices** of `Item`s. Nothing is retained between frames; the Gpu rebuilds
   its instance buffer when the content signature changes (already how
   `scene_common.signature` skips re-renders).
4. **Meshes are resources, not scene graph nodes** (hatch 8, unchanged). Heavy
   data is uploaded by `key`/`rev`; `Item.mesh` is a key. Per-frame placement
   (transform, tint, id) is cheap data in the Cmd. This is exactly the
   `image(key)` split the framework already has.
5. **No callbacks, no fn pointers, no handles in Cmd/Msg/Model.** `View` is data
   (audit-enforced like `SceneCmd`). The key -> handle remap stays in
   `src/resources.zig`.
6. **No ID hashing for widget identity.** Item `id`s are app-chosen `u32`s in
   `Model`-derived data (a part index, an entity id) and are only ever echoed
   back in pick results. They are not widget identity and carry no state.
7. **Passes stay independent.** Layout / hit-test / a11y / snapshot treat the
   viewport as the existing fixed-size scene leaf. Only render + Gpu learn the
   new fields. Core never imports GPU or platform code; `core/scene/*` is pure.
8. **No new escape hatch is proposed for M1.** Picking is solved in pure code
   (CPU ray) inside `update`. The optional GPU ID-buffer pick *extends hatch 7*
   (a Gpu-serviced effect kind) rather than adding hatch 9 — argued in section 6.
   No platform conditionals in core; no allocator params in `view` (items come
   from the frame arena the `CmdBuffer` already owns).

## 2. Module map (isolating touch points)

New code, owned by this work, is isolated in new files so the busy 2D files see
only one-line edits:

```
src/core/scene/               NEW dir, pure Zig, no GPU/platform imports
  mat.zig                     Vec3/Mat4 helpers (column-major, WebGPU clip z 0..1)
  camera.zig                  Orbit, Projection, Camera building, ray/project, presets
  view.zig                    View, Item, Grid, Gizmo, Cut, Plane, Sprite (data types)
  pick.zig                    ray-triangle, per-mesh BVH, pickItems, gizmoHit
  section.zig                 plane-triangle intersection -> outline segments, cap helpers
  mesh_build.zig              MeshData builders (box, cylinder, merge parts + Part ranges)
src/core/scene.zig            existing; SceneDraw gains item range + flags (small)
src/gpu/scene_common.zig      existing; Globals grows; signature hashes items
src/gpu/wgpu_scene.zig        existing; extended (instancing, grid, cut, id pass)
src/gpu/web_scene.zig         existing; same extensions via zunk
src/gpu/scene_pass.zig        NEW: backend-neutral pass plan (which draws, in what order)
shaders/scene.wgsl            existing; extended   shaders/scene_grid.wgsl NEW
```

Edits to shared files, all small and listed so other agents can plan around them:

- `src/core/cmd.zig`: **one new field** `view: scene_view.View = .{}` on `SceneCmd`,
  its `eql` arm (`View.eql`), and one emitter alias `viewport3d` (3 lines).
  Nothing else; no new `Cmd` variant, so layout / hit_test / a11y / frame-diff
  arms are untouched (the `scene3d` arms already handle the leaf).
- `src/render/build.zig`: the existing `scene3d` arm copies `sc.view` items
  into a flat `scene_items` list (like `scene_draws`) and sets
  `SceneDraw.item_first / item_count / flags`. ~25 lines inside one arm.
- `src/resources.zig`: `remapScenes` also remaps `Item.mesh` keys in the flat
  item list (the list is rebuilt from cmds on every stage, so remapping in
  place is safe — see section 4.3).
- `src/run.zig`: only in M1b (pick effect routing, section 6).
- `src/teak.zig`, `llms.txt`, `docs/features/scene3d.md` (point to this doc).

The 2D renderer (`render/build.zig` quad/text paths, `gpu/wgpu_core.zig`
main pass, glyph/atlas code) is **not touched** beyond the lines above plus a
`pickScene` passthrough in `wgpu_core.zig` in M1b.

## 3. API sketch

### 3.1 Camera (pure, `core/scene/camera.zig`)

```zig
pub const Mat4 = [16]f32;                 // column-major, element [col*4+row]
pub const Vec3 = [3]f32;

pub const Projection = union(enum) {
    perspective: struct { fov_y: f32 = 0.7 },     // radians
    ortho,                                        // extent from Orbit.dist
};

/// Orbit camera. Plain data: lives in the app's Model, mutated only in update.
pub const Orbit = struct {
    target: Vec3 = .{ 0, 0, 0 },
    yaw: f32 = -0.62,
    pitch: f32 = 0.5,               // clamped to +-(pi/2 - eps)
    dist: f32 = 10,                 // perspective: eye distance; ortho: half-height = dist*tan(fov/2)
    up: enum { y, z } = .y,         // Kerf is Y-up, CAD usually Z-up
    projection: Projection = .{ .perspective = .{} },
    near_far: ?[2]f32 = null,       // null = derive from `bounds` (see below)

    pub const Preset = enum { front, back, left, right, top, bottom, iso };
    pub fn setPreset(self: *Orbit, p: Preset) void;
    pub fn frame(self: *Orbit, lo: Vec3, hi: Vec3, aspect: f32) void;  // fit bounds in view
    pub fn eye(self: Orbit) Vec3;
    pub fn toggleProjection(self: *Orbit) void;   // keeps apparent size at the target

    pub const Bindings = struct { orbit: Button = .left, pan: Button = .middle,
        pan_with_shift: bool = true, zoom_to_cursor: bool = true,
        orbit_speed: f32 = 0.008, zoom_step: f32 = 1.12 };
    /// The whole input policy as one pure function. Feed it the CanvasEvents
    /// that `canvasMsg` forwarded; returns true when the camera changed.
    pub fn onEvent(self: *Orbit, ev: teak.CanvasEvent, b: Bindings) bool;

    /// View-projection for a viewport of `w x h` logical px. Near/far from
    /// `bounds` (sphere radius around target) when `near_far == null`, so the
    /// line depth bias (a constant in NDC) stays meaningful at any scale.
    pub fn camera(self: Orbit, w: f32, h: f32, bounds: ?Bounds) teak.Camera;
};

pub const Ray = struct { origin: Vec3, dir: Vec3 };
pub fn pickRay(cam: teak.Camera, w: f32, h: f32, x: f32, y: f32) Ray;  // inverse view_proj
pub fn project(cam: teak.Camera, w: f32, h: f32, p: Vec3) ?[3]f32;     // px + ndc depth; null if behind eye
```

`Camera` (the existing type) stays the Cmd payload; it gains nothing but is
extended by `Orbit.camera`. Ortho vs perspective is therefore *only* a matrix
choice — no shader change. Perspective <-> ortho toggling keeps the target
size constant (`ortho_half_h = dist * tan(fov_y/2)`), so the swap does not jump.
Zoom-to-cursor: perspective moves `target` along the cursor ray (dolly), ortho
scales `dist` and shifts `target` so the point under the cursor is fixed — the
same invariant as Kerf's `Cam2D.zoomAt`, covered by a unit test.

### 3.2 View payload (`core/scene/view.zig`)

```zig
pub const ItemFlags = packed struct(u8) {
    hidden: bool = false,       // cheap visibility toggle (layers)
    unlit: bool = false,        // flat colour, no Lambert
    no_edges: bool = false,
    no_pick: bool = false,
    highlight: bool = false,    // blend toward View.highlight_color
    _pad: u3 = 0,
};

/// One placed instance. 80 B on the GPU (3x vec4 transform rows, vec4 tint,
/// u32 id, u32 flags, 2 spare).
pub const Item = struct {
    mesh: u32,                              // resource key (MeshResource.key), like ImageCmd.handle
    transform: [12]f32 = identity_3x4,      // rows of the 3x4 affine matrix
    tint: [4]f32 = .{ 1, 1, 1, 1 },         // multiplied into vertex colour (alpha ignored in M1)
    id: u32 = 0,                            // echoed by picking; 0 = none
    flags: ItemFlags = .{},
};

pub const Material = enum(u8) { lambert, flat };   // View-wide default; Item.unlit overrides

pub const Grid = struct {
    plane: enum { xz, xy, yz } = .xz, offset: f32 = 0,
    spacing: f32 = 12, major_every: u32 = 5,
    minor: [4]f32, major: [4]f32, axis_x: [4]f32, axis_z: [4]f32,
    fade_dist: f32 = 0,            // 0 = derive from camera distance
};

pub const Gizmo = struct {          // axis triad in a corner sub-viewport
    corner: enum { top_left, top_right, bottom_left, bottom_right } = .bottom_left,
    size_px: f32 = 72, margin_px: f32 = 8,
    colors: [3][4]f32 = .{ red, green, blue },
};

/// Section cut: keep the half-space where dot(n, p) + d <= 0.
pub const Cut = struct {
    plane: [4]f32,                  // n.xyz (unit), d
    cap_color: [4]f32 = .{ 0.85, 0.2, 0.2, 1 },
    cap: bool = true,               // stencil-parity cap fill
    outline_px: f32 = 1.5,          // cap boundary line; 0 = off
};

pub const View = struct {
    items: []const Item = &.{},     // arena slice owned by the frame
    grid: ?Grid = null,
    gizmo: ?Gizmo = null,
    cut: ?Cut = null,
    material: Material = .lambert,
    highlight_color: [4]f32 = .{ 0.2, 0.5, 1, 1 },
    /// M2 (section 8): planes and sprites share the same Cmd.
    planes: []const Plane = &.{},
    sprites: []const Sprite = &.{},
    pub fn eql(a: View, b: View) bool;     // by content, for run.zig's frame diff
};
```

Because `SceneCmd` already has `mesh`/`camera`/`clear`/`edge_*`/`key`/`id`/
`pointer`/`label`, `viewport3d` is the same struct with `view` populated;
legacy `scene3d` with `mesh=` and no `view.items` keeps working (it becomes the
single-item case internally).

### 3.3 Emitter and app usage

```zig
// Model
cam: teak.scene.Orbit = .{}, cut: ?teak.scene.Cut = null,
selected: u32 = 0, hovered: u32 = 0, viewport: [2]f32 = .{ 640, 480 },

// Msg
view_event: teak.CanvasEvent, set_preset: Orbit.Preset, toggle_ortho, pick: u32, ...

// canvasMsg hook: viewport events -> Msg (the existing, only mechanism)
pub fn canvasMsg(m: *const Model, ev: teak.CanvasEvent) ?Msg { _ = m; return .{ .view_event = ev }; }

// update
.view_event => |ev| {
    if (ev.kind == .layout) m.viewport = .{ ev.w, ev.h };
    if (ev.kind == .down and ev.button == .left and !ev.mods.shift)   // click = pick
        m.selected = teak.scene.pick.items(rayFor(m, ev), m.view_items, meshesOf(m));
    _ = m.cam.onEvent(ev, .{});
},

// view
const items = cb.arena().alloc(teak.scene.Item, parts.len) catch unreachable;
for (parts, items, 0..) |p, *it, i| it.* = .{ .mesh = p.mesh_key, .id = @intCast(i + 1),
    .flags = .{ .highlight = (i + 1 == m.selected) } };
cb.viewport3d(.{
    .style = .{ .width = 0, .height = 0, .flex = 1 },
    .id = 7, .pointer = true, .label = "3D model",
    .camera = m.cam.camera(m.viewport[0], m.viewport[1], m.bounds),
    .view = .{ .items = items, .grid = .{}, .gizmo = .{}, .cut = m.cut },
    .clear = theme.bg, .key = m.mesh_rev,
});
```

`key` keeps its role: bump it when mesh *content* behind an unchanged key
changes. Items, grid, cut, camera are compared by content in `View.eql`, so
tint/selection/orbit re-render the viewport but not the rest of the UI.

Resources are unchanged: Kerf declares one `.mesh` resource per part (key = part
index + 1) through `resources()`. 42 parts (the largest golden) is far under the
128-resident limit; bigger models should merge by material and use `Part`
ranges (section 6.3). The 128 limit can be raised in `slot_table` if needed.

## 4. Rendering

### 4.1 Frame structure inside a scene slot

Per `renderInto(slot, draw)` when the signature changed (otherwise the cached
colour target is composited):

1. **Stencil pre-pass** (only if `cut.cap`): clip-plane discard, colour writes
   off, depth off, both faces, stencil op `invert` — see 4.4.
2. **Mesh pass**: instanced `drawIndexed` per run of equal `Item.mesh`
   (items are sorted by mesh key by the *Gpu*, not the app; stable sort of
   indices, instance buffer written in sorted order). Depth `less`, write on.
   Fragment: Lambert or flat, tint/highlight, clip-plane discard.
3. **Cap pass**: a plane-aligned quad (size from bounds) with stencil
   `equal 1`, depth test `less_equal` (no write), cap colour. Optional cut
   outline: lines from `section.outline` (CPU) drawn by the line pipeline.
4. **Line pass**: feature edges (per item, `no_edges` skips) — existing
   instanced quad path, plus the item transform and clip-plane discard.
5. **Grid pass**: fullscreen-triangle fragment shader that ray-intersects the
   grid plane (depth write off, depth test against the scene, alpha blend).
6. **Gizmo pass**: re-uses the line pipeline into a corner `setViewport`/scissor
   rect with a rotation-only camera; arrow heads are three tiny meshes.
7. MSAA resolve to the colour target (existing). Items drawn through a single
   `MeshData` handle remain MSAA-resolved the same way.

Depth: Depth32Float stays (line bias constant already tuned for it). The
stencil pre-pass needs a stencil aspect, so cut scenes use
`Depth24PlusStencil8` (core in WebGPU, no feature flag needed) for their depth
target; the format is a property of the slot target and can switch when `cut`
toggles (target recreation already exists via `generation`). Coarser depth is
acceptable for sectioned views; the per-pipeline `line_depth_bias` becomes a
per-format constant in `scene_common`.

### 4.2 Shader sketch (`shaders/scene.wgsl` additions)

```wgsl
struct Globals {                       // grows to 192 B; mirrored in scene_common.Globals
  view_proj: mat4x4f, eye: vec4f, light_dir: vec4f, edge_color: vec4f,
  viewport: vec4f,                     // xy px size, z line px, w line depth bias
  clip: vec4f,                         // cut plane n.xyz, d
  highlight: vec4f,                    // highlight colour, w = mix amount
  misc: vec4f,                         // x = material (0 lambert, 1 flat), y = id-pass flag, z = cut enabled
};
struct Instance { @location(4) m0: vec4f, @location(5) m1: vec4f, @location(6) m2: vec4f,
                  @location(7) tint: vec4f, @location(8) id_flags: vec2u };

fn place(inst: ..., p: vec3f) -> vec3f { let h = vec4f(p, 1);
  return vec3f(dot(inst.m0, h), dot(inst.m1, h), dot(inst.m2, h)); }
// Normal: transform by upper-left 3x3; non-uniform scale unsupported (documented),
// uniform scale re-normalised in the fragment stage (already does normalize()).

@fragment fn fs_mesh(in) -> @location(0) vec4f {
  if (g.misc.z > 0.5 && dot(g.clip.xyz, in.world) + g.clip.w > 0.0) { discard; }
  ... existing two-sided Lambert; colour = vertex.rgb * tint.rgb; flat skips shading;
  highlight: rgb = mix(rgb, g.highlight.rgb, g.highlight.w * f32(flags.highlight)) ...
}
```

The clip plane is `clip = vec4(n, d)`; the enable flag lives in `misc.z`. The line vertex stage gets the same
transform (read from the stride-0 instance buffer, 4.3) and a world-space
clip-plane test via a varying (`discard` in `fs_line`). The cap pass uses a
trivial `vs_cap`/`fs_cap`. `scene_grid.wgsl`:

```wgsl
// fullscreen triangle; unproject each pixel to a ray, intersect the grid plane,
// derive line coverage from fwidth(coord): AA lines at any distance, major/minor
// spacing, axis colours, fade with distance; write @builtin(frag_depth) so the
// grid is depth-tested against meshes and lines.
```

### 4.3 Instance data and per-backend plumbing

- `render/build.zig` appends each viewport's `Item`s to a flat
  `scene_items: ArrayList(Item)`; `SceneDraw` records `item_first`/`item_count`.
  The list is rebuilt from the `[]Cmd` every time draws are staged, so
  `Table.remapScenes` rewriting `Item.mesh` key -> handle in place is safe (the
  `Cmd`'s own `View.items` slice is never mutated). `stageDraws` signature gains
  one `items: []Item` parameter; it is called from three places
  (`run.zig`, headless, web hand loops) — covered by PR S3.
- The Gpu owns one `instance_buf` per scene slot, `writeBuffer`-ed when the
  signature changes (not per frame). `signature` now hashes the item bytes plus
  grid/cut/gizmo; that is O(items) once per frame, trivially cheap at
  CAD sizes (< 10k items).
- Per-item **line** draws: lines are already instanced per segment, so the item
  transform comes through a second vertex buffer slot bound to the item's
  64-byte record with `arrayStride = 0` and `stepMode = instance` (every
  segment instance reads the same bytes). One `draw` per item. Verify with
  wgpu validation on both backends in S4; fallback is a dynamic-offset uniform.
  Mesh triangles use the normal per-item instance step, so repeated parts
  collapse into one `drawIndexed(..., instance_count)`.
- Native: `wgpu_scene.zig` (wgpu-native C API). Web: `web_scene.zig` through
  zunk `renderPassDrawIndexed`/`setIndexBuffer`, which zunk PR #18 already
  provides along with depth + MSAA. Shared decisions live in `scene_common.zig`
  and the new backend-neutral `scene_pass.zig` (which pass runs, sort order,
  uniform packing, target formats), unit-tested without a GPU. Backends only
  translate that plan into API calls, keeping native/web parity by construction.

### 4.4 Section cut and caps

- **Clip**: one plane (M1; `[N]` planes is a mechanical extension of `Globals`).
  Fragment `discard` — WebGPU has no clip-distance. Applied to meshes, lines,
  and the grid does not need it.
- **Caps** by stencil parity: with the plane discarding the removed half, draw
  all faces of the clipped solids, no culling, no depth test, colour writes
  masked, stencil `invert` on pass. At a pixel the stencil is odd iff the ray
  enters the kept half *inside* a closed solid. Then draw the plane quad where
  stencil != 0. This is winding-independent and needs no CPU polygon work.
  **Constraint**: parts must be closed; open shells produce streaks. Kerf's
  extruded parts are closed; the `section.zig` outline can be validated against
  watertightness in the example test. Per-material cap colours would need one
  stencil pass per colour group and are out of scope (single `cap_color`).
- **Outline** (`section.outline(mesh, transform, plane, out)`): exact
  plane-triangle intersection segments, CPU, pure and unit-tested. Drawn with
  the existing line path so the cut boundary is crisp. Doubles as the input to
  2D section drawings.
- Cost: one extra pass over the same index buffers; only when `cut != null`.

### 4.5 MSAA, HiDPI, clipping, overlay

Unchanged from the shipped path and deliberately not reimplemented: targets
are device-pixel sized (`devicePixelRatio` on web), 4x MSAA via
`options.scene_msaa`, composite quad clipped by scroll/overlay clip rects.
Gizmo size, grid line widths and `edge_px` are logical px scaled by the same
`scale` already passed to `renderInto`. Stencil + MSAA: the stencil attachment
must share the sample count — the pre-pass is part of the multisampled pass
(cap quad edges therefore antialias too). Overlay interplay is the shipped
rule: scenes are images, an opaque overlay hides them; 2D labels and gizmo
letters drawn by the app *above* a viewport are text and therefore sit over it
(text draws after image composites).

## 5. Composition with the 2D command buffer

- A viewport is one fixed-size leaf in `[]Cmd`; it flows through layout,
  hit-test, snapshot, a11y and frame-diff via the existing `scene3d` arms.
  `snapshot` gains an optional suffix (`items=N grid cut gizmo`) — one line in
  `core/snapshot.zig` — so golden Cmd snapshots notice scene-level changes.
- Declarative per-frame description vs resources: **description** (placement,
  tint, camera, cut, grid) is per-frame arena data in the Cmd; **resources**
  (vertex/index/line buffers) are uploaded by key/rev. Same split as `image`.
- 3D never interleaves with 2D z-order inside the target: the viewport is an
  opaque rect. 2D content over it (HUD, selection rectangles, dimension
  labels) is ordinary Cmds placed after it in an `overlay` or later siblings.
  `camera.project` gives the screen anchors for such labels.
- Text on or in 3D (axis letters, part labels) is *always* 2D text positioned
  from `project(...)` in `view` — pure, and uses the Host measurer like all text.

## 6. Picking

### 6.1 Recommendation: CPU ray pick first (M1), ID buffer second (M1b, optional)

Both options are specified because the goal asked for ID-buffer picking; the
doc argues CPU-first.

**CPU ray (`core/scene/pick.zig`)**: `pick.items(ray, items, meshes) ?Hit`
where `Hit = {id, item, triangle, t, point, normal}`. Per-mesh BVH
(`pick.Bvh.build(mesh)`, median split over triangle bounds; building it is a
pure function of the mesh and can live in the `Model` next to the mesh data, or
be rebuilt lazily by the app when `rev` changes) so cost is O(log n) per
ray. Brute force is already fine for the Kerf goldens (<= 1264 triangles,
42 parts) — start brute force + AABB culling, add the BVH only if a profile
asks. The ray comes from `pickRay(camera, w, h, x, y)` with the event's
viewport-local logical px — identical on native and web, deterministic,
unit-testable, and `update` stays a pure function of (Model, Msg). Hover works
the same way on `move` events. **No GPU readback, no async, no hatch.**
Limitations: ignores nothing the app doesn't also know (clip plane — pass
`cut` to skip hits on the removed side; hidden items — skip via flags).
Vertex-shader-displaced geometry cannot exist (the shader never displaces).

**ID buffer (`M1b`)**: for scenes where CPU picking is too slow (millions of
triangles) or wants per-pixel exactness. The Gpu renders an *id pass* into a
non-MSAA `rgba32float` target of the viewport's size: `R = item id`, `G` = NDC
depth, `B` = instance/primitive info; blending off, same clip plane applied;
shader reuses `vs_mesh` with `misc.y = 1` selecting `fs_id`
(`rgba32float` so no uint-format support is needed in zunk; ids stay exact below
2^24). One pixel is read back (`copyTextureToBuffer` of a 1x1 region, then
`mapAsync` on web / `wgpuBufferMapAsync` + poll on native).

### 6.2 How the readback result returns without breaking HARDLINE

The readback is inherently asynchronous on web (mapAsync resolves in a later
tick) and impure; the pixel is a fact from the outside world, exactly like an
HTTP body or a file the user picked. That is the definition of hatch 7. Options
considered:

| Option | Verdict |
|---|---|
| **A. Effect kind served by the Gpu** (`Effect.scene_pick` -> `EffectResult.scene_pick`) | **Chosen** for M1b. Extends hatch 7; zero new paths into `update`. |
| B. Host-side "pick resource" that polls and emits a Msg | Rejected: a new mutation channel and a second place that knows about scenes; hatch 8 is declarative *uploads*, it never reports back (its doc says "nothing is reported back through Msg" on purpose). |
| C. Synchronous readback inside `renderScenes` writing into a Model pointer | Rejected: writes Model outside `update`; forbidden. |
| D. New hatch 9 | Rejected: the high bar in HARDLINE §4 is not met when hatch 7 fits. |

Shape (data only):

```zig
// core/effects.zig additions
pub const ScenePick = struct {
    id: u32,           // request id from Model (hatch 7 contract)
    scene: u32,        // SceneCmd.id of the viewport
    x: f32, y: f32,    // viewport-local logical px (from the CanvasEvent)
};
// Effect gains `.scene_pick: ScenePick`; wantsResult = true.
// EffectResult gains:
.scene_pick: struct { id: u32, hit: ?struct { item_id: u32, depth: f32, instance: u32 } },
```

Semantics, all inherited from hatch 7: the app lists the effect while it wants
the answer (id counter in `Model`; hovering on `move` events bumps the counter
and relists, stale ids are dropped), the result is a normal `Msg` through
`effectMsg`/`update`, result lifetime ends with `update`. The runtime (not the
Host) services this kind: `run.zig`'s effect servicing routes `scene_pick` to
`gpu.pickScene(scene_id, x, y)` when the Gpu has it (`@hasDecl`, like
`renderScenes`), otherwise answers with `unsupportedResult` (`hit = null`)
so an app never waits forever. The hatch 7 doc's "Platform machinery lives
behind Host.submit" bullet is amended to: "Gpu-serviced kinds (`scene_pick`)
are routed by the runtime to the Gpu's optional extension instead". Latency:
native resolves within the frame (blocking map is acceptable for a 16-byte
copy); web resolves 1-3 frames later, which is the same one-frame-latency idea
the framework already accepts for hit-test. Cost: HARDLINE §2 hatch 7 text
amendment + `docs/features/effects.md` entry; flagged for the orchestrator.

The pick pass renders only when a `scene_pick` request is outstanding (never
per frame otherwise), reuses the slot's depth buffer sizing, and tests pixel-
exactness with a recording Gpu stub in `run.zig` tests.

### 6.3 `Part` ranges

Kerf merges nothing; but big models want fewer, bigger meshes. `MeshData` gains
`parts: []const Part = &.{}` with `Part = {first_index, index_count, first_line,
line_count, id}`; items refer to the mesh as a whole and the id pass draws each
part range with `id` from the part (no per-item instance needed). CPU pick
reports the part id. Optional in M1 (kerf example uses one mesh per part).

## 7. Kerf mesh JSON

Schema (`kerf_mesh: "0.1"`), five goldens in `~/github/kerf/engines/zig/tests/golden/*/mesh.json`
(10-42 parts, 120-1264 triangles):

```
{ "kerf_mesh": "0.1",
  "parts": [ { "src": "beam", "part": null|name, "instance": 0, "material": "wood_engineered",
               "color": "#D6B271",
               "positions": [x,y,z,...],   // f32 triples, units = inches, Y up
               "normals":   [x,y,z,...],   // same count
               "indices":   [i,i,i,...],   // u32 triangle list, local to the part
               "edges":     [x0,y0,z0,x1,y1,z1,...] } ] }   // feature-edge segment endpoints
```

The loader is **example code**, not framework (`examples/kerf_viewer/src/kerf_mesh.zig`):
`std.json` -> one `MeshResource` per part (`key = idx+1`, positions/normals
interleaved into `MeshVertex` with the muted colour from `color`, edges into
`LineVertex` pairs), per-part `Item{mesh, id = idx+1}` and the overall
bounds for `Orbit.frame`. Normals missing -> compute face normals in the loader.
Kerf's `muted()` desaturation is a loader concern. Mesh units are inches, so
`Grid.spacing = 12` (feet) and `near_far` derives from bounds. Part-level
selection toggles a flag, not geometry: it removes the archived app's
"rebuild and re-upload the whole mesh on selection" cost.

## 8. Milestone 2 — 2.5D layers

Goal: diagrams / drawings / sheets floating in a 3D scene: tilted 2D planes
with 2D content, sprites/billboards, correct depth ordering. **No separate
subsystem**: planes and sprites are more `View` payload rendered by the same
scene pass into the same depth buffer.

```zig
pub const Plane = struct {
    origin: Vec3, u: Vec3, v: Vec3,          // plane axes; content (0..size) maps origin + s*u + t*v
    size: [2]f32,
    content: []const teak.CanvasPrimitive,   // existing vector canvas primitives, plane-local coords
    layer: i16 = 0,                          // coplanar stacking order (depth bias), z-fighting guard
    opacity: f32 = 1,
    background: ?[4]f32 = null,
    double_sided: bool = true,
    flags: ItemFlags = .{},                  // hidden / no_pick
    id: u32 = 0,
};

pub const Sprite = struct {
    pos: Vec3, image: u32,                   // image resource key (same hatch 8 table)
    size: [2]f32, size_in: enum { world, screen_px } = .screen_px,
    anchor: [2]f32 = .{ 0.5, 0.5 },
    mode: enum { camera_facing, axis_locked_y, fixed } = .camera_facing,
    uv: [4]f32 = .{ 0, 0, 1, 1 },
    tint: [4]f32 = .{ 1, 1, 1, 1 }, id: u32 = 0, layer: i16 = 0,
};
```

**Decision: project primitives directly, do not render 2D to an offscreen
texture.** Reasons: the canvas tessellator (`CanvasPrimitive` -> triangles /
quads) already exists in the render pass; transforming its vertices by the
plane matrix in the scene vertex stage gives resolution-independent edges at any
tilt/zoom, MSAA, correct depth interaction with meshes, and no per-plane
texture memory. An offscreen texture would be blurry when magnified, need a
resolution policy, and cost one render per plane per change. Offscreen
rendering of a plane remains a *later* option for content that cannot be
expressed as primitives (arbitrary widget trees or text, M2c), built on the
same slot/signature machinery as scenes.

- **Implementation**: a new pure function `scene_view.tessellatePlane(plane,
  arena) []PlaneVertex` (shares the canvas tessellation helper; if it is
  private to `render/build.zig` today, M2a extracts it into
  `src/render/canvas_tess.zig` — a pure move, serialised against other 2D
  render work). Output goes into a per-scene `plane_vertices` stream drawn by a
  `vs_plane` pipeline (position, colour, local uv) with alpha blending.
- **Depth sorting**: opaque meshes and opaque planes are depth-tested and
  written; translucent planes/sprites are depth-tested but not written and
  drawn after, **sorted back-to-front by camera distance** (pure
  `scene.sort.byDepth(cam, keys, out_order)`, stable, tested). `layer` applies
  a depth bias (`layer * unit`) so stacked coplanar sheets are deterministic.
  Intersecting translucent planes are an acknowledged limitation (no OIT).
- **Sprites/billboards**: instanced quads; vertex stage builds the quad from the
  camera right/up vectors (billboard) or constant pixel size (`screen_px`), image
  bound from the same `images` residency table. One bind group per distinct
  image (≤ 16 per scene), sprites grouped by image.
- **Text in 3D**: M2a does labels as 2D text at projected anchors (section 5).
  True tilted glyphs (text on a plane) wait for the text/atlas rework to
  settle, then become a `TextPlane` that emits atlas-sampled quads through the
  plane pipeline (M2c). The doc does not commit to it now to avoid coupling to
  active text work.
- Picking planes/sprites: CPU, ray-plane + rect test in `pick.zig`.
- CAD use: sheet previews as planes in the model's space (e.g. a drawing sheet
  standing next to the model), dimension leader sprites, annotation layers.

## 9. Test strategy

| Layer | Test | Where |
|---|---|---|
| Camera math | project/unproject roundtrip; ortho extents; perspective vs ortho swap preserves target size; zoomAt fixed point; pitch clamp; presets; `frame()` fits bounds in viewport; near/far from bounds | `core/scene/camera.zig` tests, `zig build test` |
| Pick | ray-triangle edge/vertex cases; nearest-hit; hidden / `no_pick` skipped; clipped-side skipped; BVH == brute force on random rays; gizmo hit | `pick.zig` tests |
| Section | plane-triangle outline segment count/area on a cube; watertight check | `section.zig` tests |
| View/Cmd | `View.eql`, item flags, snapshot suffix, `scene3d` back-compat (mesh= only) | cmd.zig / snapshot.zig tests |
| Plan | `scene_pass` ordering, instance packing, Globals layout size, signature changes iff input changes | no-GPU unit tests |
| Remap | in-place item remap safe across two stagings; unknown key -> none | `resources.zig` tests |
| Native pixels | centre-pixel colours (Lambert face, flat, highlight tint), cap colour inside a cut cube, grid line pixel, gizmo corner pixel, ID pass returns the item id | `zig build test-gpu` (needs real Vulkan; skips otherwise) |
| Goldens | `examples/kerf_viewer` `zig build shot -- out.png` with a scripted camera for each preset, cut on/off, ortho/perspective; compared with a per-pixel tolerance (Mali vs other drivers differ) against `tests/golden/*.png` in the example | native, headless |
| Web | `zig build web` + `shot.mjs` (`--webgpu --wait-ms 3000`) for the same scripts; checked by coarse probes + eyeball (SwiftShader is not bit-exact with Mali; separate golden set) | web parity |
| Run loop | recording-Gpu test of pick effect routing; unsupported Gpu answers `hit = null` | `run.zig` tests (M1b) |

Determinism rules for goldens: fixed viewport size and DPR 1, fixed clear
colour, camera from presets only, MSAA on (documented).

## 10. Risks and open questions

1. **zunk lacks** stencil texture formats and stencil ops in pipeline
   descriptors (`TextureFormat` stops at `r8unorm`), and `Readback`/
   `copyTextureToBuffer` copy the whole texture from origin. Needed: stencil
   format + `StencilState` in `RenderPipelineDescriptor` (cut caps), and a
   region-capable readback (M1b). These are the only zunk-side work; web
   pick/caps are blocked on those PRs. A stencil-free fallback for caps (depth
   peeling) is not worth the shader cost — prefer the zunk change.
2. `arrayStride = 0` instance stream for per-item line transforms must be
   validated on wgpu-native and in Chromium (spec allows it; verify early in
   PR S4, fallback described in 4.3).
3. Cap correctness requires closed parts; open shells give streaks. Document and
   expose `section.isClosed(mesh)` for the app to warn.
4. Depth24+Stencil8 vs Depth32F: line bias tuned for 32F; keep both formats and
   a per-format bias constant.
5. Translucent planes have no OIT; intersecting translucent sheets can sort wrong.
6. The 16-scene / 128-mesh limits stay; many-part models should merge parts
   (the `Part` range support exists for that reason).
7. Hatch 7 amendment (Gpu-serviced effect kind) needs orchestrator approval; M1
   acceptance does not depend on it because CPU pick ships first.

## 11. Implementation plan (agent-sized PRs)

Ownership key: **own** = new files only this PR touches; **edit** = small edit
to a shared file. Serialization: anything touching `src/core/cmd.zig`,
`render/build.zig`, `gpu/wgpu_core.zig` waits for a rebase window with the
text/atlas agents; PRs marked *parallel* touch only new files and can run
concurrently from the start.

### Milestone 1

| PR | Size | Content | Files | Needs |
|---|---|---|---|---|
| **S1** camera + math | 1.5-2 h, parallel | `Mat4/Vec3`, `Orbit`, projection modes, `camera()`, `onEvent`, presets, `frame`, `pickRay`, `project`; unit tests; `teak.scene` namespace re-export | own: `core/scene/{mat,camera}.zig`; edit: `teak.zig`, `llms.txt` | none |
| **S2** pick + section math | 2 h, parallel | ray-triangle, AABB, `pick.items`, optional BVH, `section.outline`, `isClosed`, `gizmoHit`; tests | own: `core/scene/{pick,section}.zig` | S1 (Ray, Camera) |
| **S3** View payload plumbing | 2-3 h, **serialised** (cmd.zig, build.zig) | `view.zig` types, `SceneCmd.view` + `eql`, `viewport3d` emitter, `scene_items` list + `SceneDraw.item_*`, `remapScenes` over items, `stageDraws` items param (all call sites), snapshot suffix, back-compat tests | own: `core/scene/view.zig`; edit: `cmd.zig`, `scene.zig`, `render/build.zig`, `resources.zig`, `run.zig` (stage call), `snapshot.zig`, examples' stage calls | S1 |
| **S4** instanced items + Lambert/flat/tint/highlight | 3 h | `scene_pass.zig` plan, Globals growth, instance buffer, per-run `drawIndexed`, per-item line draws, shader changes, signature over items, both backends | own: `gpu/scene_pass.zig`; edit: `scene_common.zig`, `wgpu_scene.zig`, `web_scene.zig`, `shaders/scene.wgsl` | S3 |
| **S5** grid + gizmo | 2-3 h | `scene_grid.wgsl`, grid pass, gizmo sub-viewport pass, label-anchor/hit helpers wired, test-gpu pixel probes | own: `shaders/scene_grid.wgsl`; edit: `wgpu_scene.zig`, `web_scene.zig`, `scene_pass.zig`, `build` shader embedding (`teak-shaders`) | S4 |
| **Z1** zunk stencil + region readback | 2 h, **zunk repo**, parallel | stencil formats (`depth24plus_stencil8`), `StencilState` in pipeline desc, `Readback` region, js_gen tables, zunk tests | zunk `src/web/gpu.zig`, `js_gen.zig` | none |
| **S6** section cut + caps | 2-3 h | clip uniform + discard, stencil pre-pass + cap pass, cut outline lines, format switch Depth24+Stencil8 on cut, pixel probes | edit: `wgpu_scene.zig`, `web_scene.zig`, `scene_pass.zig`, shader | S4, Z1 (web) |
| **S7** `examples/kerf_viewer` | 2-3 h | Kerf loader (`kerf_mesh.zig`), app (orbit/pan/zoom, presets, ortho toggle, click pick/hover, cut-plane slider, gizmo), `shot` + web build, goldens, copies of 2 fixtures | own: `examples/kerf_viewer/**` | S1-S6 (develop against S1-S4 first, add cut when S6 lands) |
| **S8** docs close-out | 0.5-1 h | `scene3d.md` pointer, `scene.md` -> "shipped", cookbook recipe, `llms.txt`, README feature list | docs only | S7 |

Acceptance (M1): `examples/kerf_viewer` renders a Kerf `mesh.json` (any of the
five goldens, loaded from a bundled copy or `?mesh=` query / file picker effect)
with orbit/pan/zoom, ortho + perspective, presets, click-to-select + hover,
section cut with caps, grid and gizmo; identical on native (`zig build shot`
golden) and web (`shot.mjs`), all gates green.

### Milestone 1b (optional)

| PR | Size | Content | Needs |
|---|---|---|---|
| **S9** ID-buffer pick | 3 h | `ScenePick` effect + `EffectResult.scene_pick` in `core/effects.zig`; `run.zig` routes to `gpu.pickScene`; `wgpu_scene`/`web_scene` id pass + 1px readback; `wgpu_core.zig` passthrough; HARDLINE hatch 7 amendment + `docs/features/effects.md`; tests with a recording Gpu | S4, Z1; orchestrator OK on hatch text |
| **S10** BVH + `Part` ranges | 2 h | BVH in `pick.zig`, `MeshData.parts`, id pass per part | S2, S9 |

### Milestone 2

| PR | Size | Content | Needs |
|---|---|---|---|
| **P1** planes | 3 h | `Plane`, extract canvas tessellation to `render/canvas_tess.zig` (pure move, serialised), `vs_plane` pipeline, `layer` bias, CPU ray-plane pick, tests | S4, quiet 2D renderer |
| **P2** sprites/billboards | 2-3 h | `Sprite`, billboard shader, grouped by image, `screen_px` size, pick | S4 |
| **P3** depth sort | 1.5 h | `sort.byDepth`, translucent pass ordering in `scene_pass.zig`, tests | P1, P2 |
| **P4** example | 2 h | `examples/scene_layers`: tilted sheets + billboards around the Kerf model | P1-P3 |
| **P5** (stretch) text/offscreen planes | 3 h+ | tilted text via atlas quads, or offscreen-texture plane for arbitrary 2D | text/atlas work landed |

Serialization summary: S1, S2, Z1 start immediately in parallel (new files /
other repo). S3 is the only M1 PR that must be scheduled against 2D
renderer/cmd.zig activity — keep it small and land it first after S1. S4->S5
and S4->S6 share `wgpu_scene.zig`/`web_scene.zig`/`scene.wgsl`: one agent each,
sequential. S7 can start scaffolding after S3 using a single mesh.
