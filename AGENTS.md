# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## Read this first: HARDLINE

Teak is a **novel UI framework**, not a port of React/Flutter/SwiftUI. The
failure mode is drift — reaching for a familiar pattern (reactive signals,
virtual DOM diffing, widget-internal state, lifecycle hooks) because
"that's how UI frameworks do it" and accidentally recreating someone
else's paradigm.

[`docs/HARDLINE.md`](docs/HARDLINE.md) is the keystone doc. It lists:

- **§1 Core invariants** — all state in `Model`, every transition is a
  `Msg`, `view` is pure, passes are independent, per-frame arena only.
- **§2 Deliberate breaks** — the four named escape hatches (comptime
  component stitching, TransientState, flat-buffer layout, Host layer),
  each with explicit bounds.
- **§3 Forbidden patterns** — concrete things to reject: widget-internal
  statics, fn-pointer smuggling on `Cmd`, ID hashing, VDOM diffing,
  reactive signals, per-widget lifecycle hooks, platform imports in
  core, conditional compilation in core, allocator parameters in
  `view`, wall-clock reads in `view`.
- **§4 Proposing a new break** — the process (high bar) for adding a new
  escape hatch.
- **§5 Drift audit checklist** — greppable rules to verify the codebase
  still conforms.

**Before touching state flow, widget identity, passes, or the host
boundary: check HARDLINE.** When a proposed change bumps against it,
the change yields, not the doc. If you believe the doc is wrong, invoke
§4 — don't quietly work around it.

## Build Commands

Requires **Zig 0.17.0+**.

The repo is split into a **library** (root `build.zig`) and **examples** (each with their own `build.zig`). Library tests run from root; example steps run from the example's directory.

```sh
# Library
zig build test                              # Library tests (run from repo root)
tools/gate.sh [--quick]                    # Full merge gate: lib+ReleaseSafe+audit+gpu+examples+fmt+win cross+zunk (GATE_OUT for PNGs)

# Example: counter_greeter (CLI + wgpu UI)
cd examples/counter_greeter
zig build test                              # Example tests
zig build run                               # CLI canary
zig build web                               # wasm + WebGPU (zunk) -> dist/

# Native UI — teak.linkNativeWgpu dispatches on target OS:
zig build ui                                # native host (Linux X11 / Windows) for the host OS
zig build ui -Dtarget=aarch64-windows-gnu   # cross to Windows ARM64 (Win32 + wgpu)
zig build ui -Dtarget=x86_64-linux-gnu       # cross to Linux x86_64 (X11 + wgpu)
```

The native UI backend is chosen per target OS: **Windows** (Win32 window + GDI text) and **Linux** (X11 window + stb_truetype text); both render through wgpu-native. The `ui` step only exists when teak ships a native backend for the target (`teak.hasNativeBackend`), so `run`/`test`/`web` configure on every OS. On Linux, libX11 is loaded at runtime via `std.DynLib` — **no X11 dev package is needed to build** (only `libX11.so.6` + a Vulkan driver at runtime). A monospace TTF is located by path probe (override with the `TEAK_FONT` env var); DejaVuSansMono is the default. Wayland is not yet supported directly — X11 apps run under XWayland.

The `wgpu-native` prebuilts live in teak's own `build.zig.zon` (one per OS × arch) and are fetched lazily on the first native/web UI build; pure-library consumers never pay for them. The root library has no external dependencies. The build targets Windows ARM64 (Snapdragon X Elite) with a workaround for Zig's missing `i8mm` CPU feature detection on aarch64.

### Windows ARM64 (Zig 0.17+)

With Zig 0.17 the native `aarch64-windows` `zig.exe` works (the 0.16 crash, [Codeberg #31865](https://codeberg.org/ziglang/zig/issues/31865), is fixed). CI proves it on a `windows-11-arm` runner: the ARM64 toolchain builds and runs the library tests (ReleaseSafe), all examples, and an optimized `examples/chrome` canary natively ([run](https://github.com/hotschmoe/teak/actions/runs/37712840052)). So on a Windows ARM64 host:

- Install the **aarch64-windows** Zig build; no x86_64 `zig.exe` under Prism emulation, no `-Dtarget=` flag. The native default target is `aarch64-windows`, and `zig build ui` produces a native ARM64 binary.
- Cross-compiling still works from any host (`-Dtarget=aarch64-windows-gnu`, `-Dtarget=x86_64-windows-gnu`).
- teak's `build.zig.zon` declares the wgpu-native prebuilts per OS × arch; `linkNativeWgpu` selects the matching one by `target.result.os.tag` + `cpu.arch`, so no flags are needed on a native host.

History of the 0.16 crash and the old emulation workaround: [`docs/archive/zig-016-win-arm64-crash.md`](docs/archive/zig-016-win-arm64-crash.md).

## Architecture

Teak is a Zig-native UI framework combining **TEA (The Elm Architecture)** for state management with **command buffer rendering** via wgpu.

### The Core Loop

```
Model -> view() -> []Cmd -> layout -> []Rect -> render -> pixels
                                        ^
          mouse click -> hit_test -> Msg -> update -> Model'
```

Every arrow is a function call with explicit inputs and outputs. No globals, no singletons, no event bus.

### Layers

| Layer | What it does | Key types |
|-------|-------------|-----------|
| **State (TEA)** | `Model` struct holds all app state. `Msg` tagged union enumerates transitions. `update` is a switch. | `Model`, `Msg`, `update()` |
| **View** | `view()` emits flat `[]Cmd` tagged unions into an arena-allocated `CmdBuffer`. Runs every frame. | `Cmd`, `CmdBuffer`, `view()` |
| **Layout** | Two O(n) linear passes (measure bottom-up, position top-down) over `[]Cmd` producing `[]Rect`. Stack-based, no tree allocation. | `Rect`, `LayoutEngine` |
| **Hit-test** | Walks `[]Cmd` + `[]Rect` backwards (painter's order). Returns the `Msg` embedded in the command. No ID hashing. | `hit_test()` |
| **Render** | Converts `[]Cmd` + `[]Rect` + `TransientState` into vertices plus text / image / scene draw records (SDF rounded rects, borders, gradients, soft shadows; canvas tessellation). | `buildFrame()`, `Vertex`, `render/sdf.zig` |
| **Text** | Host-side `teak-text` module: face table, shaper (SimpleShaper / optional HarfBuzz), exact measure cache, glyph atlas + text stage; pure wrap / bidi / line-break / editor logic lives in `core/`. | `TextMeasurer`, `Editor`, `TextArea`, `GlyphAtlas` |
| **Widgets** | Zero-new-Cmd widgets composed from primitives (dropdown, combobox, menus, tabs, split, toast, dialog, tooltip, date field, DataTable / VarList / TreeList) plus Cmd-backed `text_area`, `canvas`, `scene3d`. | `teak.widgets`, `DataTable`, `Dropdown` |
| **Scene** | Orbit camera, picking, instanced items, grid + gizmo, section cuts, depth-sorted layers: pure data in `core/scene/`, drawn by `gpu/wgpu_scene.zig` / `gpu/web_scene.zig`. | `viewport3d`, `SceneDraw` |
| **Host / Gpu** | Window + input + clipboard + effects (`platform/`), and the wgpu / WebGPU pipelines (`gpu/`): the only layers with mutable platform state (hatch 4). Win32, X11, Wayland (one Linux binary), web, headless. | `validateHost`, `validateGpu` |
| **TransientState** | Hover/press/focus state that bypasses the TEA loop entirely -- short circuits from input to render. | `TransientState` |

### Key Design Patterns

- **All state in one Model struct.** No hidden widget state. Cursor positions, scroll offsets, focus -- all explicit fields.
- **Commands are flat tagged unions.** Layout, hit-test, and render are independent passes over the same `[]Cmd` buffer.
- **Arena allocation per frame.** Two arenas alternate. Bulk-free each frame. Zero per-widget deallocation.
- **Hit-test runs against the previous frame's commands/rects.** One-frame latency is correct and imperceptible.
- **Comptime component composition.** Components expose `Model`/`Msg`/`update`/`view`; comptime generates routing.

### Adding Features

Every feature follows four mechanical steps:

1. Add a field to `Model` (new state)
2. Add a variant to `Msg` (new transition)
3. Add a switch arm to `update` (new behavior)
4. Add `cmd.*` calls to `view` (new UI)

The compiler enforces exhaustive switching -- missing a `Msg` arm won't compile.

### Adding Widgets

A genuinely new `Cmd` variant touches every pass over the flat buffer. The
passes take `anytype`, but every switch over the `Cmd` tag in layout
(`measurePass`, `positionPass`), hit-test, focus, render, snapshot, a11y,
scroll extent is **exhaustive (no `else =>`)**, so adding a variant makes each
of them fail to compile until it is handled (a pass that legitimately ignores
it lists it explicitly). The frame diff (`cmdsEqual`) is derived by comptime
reflection (`core/eql.zig`) — nothing to write. Do not add `else =>` to a
switch over Cmd tags. Checklist:

*Compiler-enforced (follow the errors):*

1. **`Cmd` variant + style/cmd struct** in `src/core/cmd.zig` (data only, no
   fn-pointers) + a convenience **emitter** method on `CmdBuffer`.
2. **Layout** (`layout/engine.zig`): arms in `measurePass` + `positionPass`.
3. **Hit-test / focus** (`input/hit_test.zig`, `input/focus.zig`): return its
   click `Msg` (or `null`); say whether it is focusable.
4. **Render** (`render/build.zig`; + `render/vertex.zig` for a new quad shape).
5. **Snapshot** (`core/snapshot.zig`): a `writeCmd` arm (`tag (x,y,w,h) …`).
6. **A11y** (`input/a11y.zig`): a `Role` member + mapping arm.

*Manual (nothing fails to compile):*

7. **Win32 UIA** (`platform/win32.zig`): map the `Role` in
   `controlTypeForRole` (+ `isFocusableRole` if keyboard-focusable).
8. **Re-export** in `src/teak.zig` **and** document in `llms.txt` — the
   `zig build audit` `LLMS_TXT_RULE` fails the build otherwise.

Prefer composing from existing primitives (that's how `Dropdown` works — zero
new variants). Worked example: [`docs/cookbook.md`](docs/cookbook.md) recipe 12.

## Module Structure

<!-- module-tree:start (generated by tools/gen_tree.py; do not edit by hand) -->
```
src/                                          -- the library, consumable as a Zig module
  control.zig                                 -- Agent control channel + input record/replay, driven from Runtime.frame
  headless_run.zig                            -- Tool API for headless runs: script input, run frames, grab pixels, write a PNG
  input_record.zig                            -- Input record / replay file format (TEAK_RECORD / TEAK_REPLAY)
  resources.zig                               -- run-loop resource table (key -> Gpu handle), stageDraws
  run.zig                                     -- teak.run + Runtime(App, Host, Gpu): the canonical loop (one frame() per tick), App hooks, idle
  teak.zig                                    -- public library root: every re-export, documented
  core/
    anim.zig                                  -- Model-driven animation: tweens, easing curves and interpolation
    bidi.zig                                  -- UAX #9 Unicode Bidirectional Algorithm (Unicode 16): pure, std only
    chart.zig                                 -- teak.chart — pure line-chart primitive builder
    cmd.zig                                   -- Cmd union, CmdBuffer + emitters, arena, validateBalance, OverlayStyle/leafMsg
    combobox.zig                              -- Searchable select ("combobox"): a text input that filters an app-owned option list shown in the
    component.zig                             -- Components(), validateComponent, buildMsgs: comptime component stitching (hatch 1)
    component_list.zig                        -- ComponentList: a comptime-generated dynamic list of homogeneous sub-components
    cursor.zig                                -- Mouse-cursor shapes and the rule that picks one from the hovered cmd
    data_table.zig                            -- DataTable: a virtualized, sortable, resizable, selectable table for large row counts (100k rows
    debug_overlay.zig                         -- Debug overlay: dump the current frame's cmds + rects into an overlay-layer panel for visual
    dropdown.zig                              -- Dropdown(cap): closed button + auto-anchored overlay list (no new Cmd)
    editor.zig                                -- Text-editing state: a fixed-capacity UTF-8 buffer with a cursor, an optional selection anchor
    effects.zig                               -- Declarative effects (HARDLINE §2 escape hatch 7 — the sibling of Sub, hatch 6)
    eql.zig                                   -- Generic deep equality over plain-data types — the frame diff's compare
    inspector.zig                             -- Dev inspector panel: the widget tree, the hovered widget's rect + style dump, the last Msgs and
    linebreak.zig                             -- UAX #14 "lite" line-break opportunities over grapheme clusters
    numeric_field.zig                         -- Numeric input component: TextField + float parsing + range validation
    oom.zig                                   -- The framework's single out-of-memory policy
    pointer.zig                               -- Pointer / canvas-event types shared by the Host, teak.run, hit-test and the App
    resources.zig                             -- Declarative GPU resources (HARDLINE §2 escape hatch 8)
    scene.zig                                 -- Data types for 3D scene rendering: mesh geometry, camera, and the per-frame SceneDraw record
    scroller.zig                              -- Scroll position with smooth wheel and kinetic (fling) motion, as plain data
    snapshot.zig                              -- teak.snapshot — LLM-readable serialization of a rendered frame
    sub.zig                                   -- Subscriptions — declarative timers / external-event listeners
    surface.zig                               -- Surface decoration data shared by the style structs: per-corner radii, soft drop shadows and
    table.zig                                 -- Fixed-column monospace tables, as pure helpers
    text.zig                                  -- Text measurement and rasterization types
    text_area.zig                             -- TextArea(cap): the canonical multi-line editor component -- an Editor plus scroll state, driven
    text_event.zig                            -- Pointer / navigation / metrics events for text_area (text-engine 6.3-6.4)
    text_field.zig                            -- Canonical text-input component + key-dispatch helpers
    text_wrap.zig                             -- Pure text wrapping, height-for-width measurement and caret/point mapping
    theme.zig                                 -- Theme: bundled style + typography defaults consulted by un-styled convenience emitters
    transient.zig                             -- TransientState: hover/press/focus/IME/caret-phase (hatch 2)
    tree_list.zig                             -- TreeList: a virtualized tree view over a very large node set
    unicode.zig                               -- Unicode support for text entry and layout: lossy UTF-8 decoding, UAX #29 extended grapheme
    unicode_tables.zig                        -- GENERATED by tools/gen_unicode.zig -- do not edit by hand
    var_list.zig                              -- VarList: a virtualized list whose rows have different heights
    widgets.zig                               -- Widgets built purely from existing Cmd primitives (zero new Cmd variants)
    scene/
      camera.zig                              -- Orbit camera, projection modes, pointer-driven navigation, picking rays
      mat.zig                                 -- Small, allocation-free linear algebra for the scene helpers
      pick.zig                                -- CPU ray picking: ray-triangle (Moller-Trumbore), ray-AABB, an optional per-mesh BVH, items over
      section.zig                             -- Section cuts on the CPU: plane x triangle-mesh intersection as line segments, chaining of those
      sort.zig                                -- Depth ordering for blended scene layers (translucent planes, sprites)
      view.zig                                -- The data a viewport3d Cmd carries besides the camera: placed mesh instances (Item) and
    widgets/
      date.zig                                -- Calendar dates: pure proleptic-Gregorian maths, ISO 8601 parse / format, no allocation and no
      date_field.zig                          -- Date field: an ISO text field (YYYY-MM-DD) with a calendar popover
      dialog.zig                              -- Modal dialog helper: a centred card over a dimmed window with a title, a message (or app
      menu.zig                                -- Menus: a menu bar with drop-down menus and nested submenus, and a context (right-click) menu
      progress.zig                            -- Progress bar: determinate (a fraction) and indeterminate (a block sliding across the track)
      split.zig                               -- Split pane: two panes separated by a draggable divider, with minimum sizes and a ratio that
      tabs.zig                                -- Tab strip: a row of tabs where exactly one is selected, with keyboard navigation
      toast.zig                               -- Toasts: transient notifications stacked in a corner that dismiss themselves
      toggle.zig                              -- Toggle switch: an on/off control that reads as a switch rather than a checkbox
      tooltip.zig                             -- Tooltip: a small popup that appears after the pointer rests on a widget
      util.zig                                -- Helpers shared by the widget components (internal)
  gpu/
    context.zig                               -- Gpu interface: the only layer allowed to touch wgpu-native or zunk.web.gpu
    glyph_atlas.zig                           -- GlyphAtlas: pure CPU-side bookkeeping for a paged glyph-texture atlas
    native.zig                                -- Win32 + wgpu-native GPU backend (the Windows stitch)
    native_headless.zig                       -- Headless native GPU stitch: the wgpu core with no surface provider and the stb_truetype
    native_linux.zig                          -- Linux + wgpu-native GPU backend (the Linux stitch), for the X11 and Wayland hosts
    overlay.zig                               -- Overlay layering shared by the GPU backends (HARDLINE §2 hatch 5: two levels, base z=0 and
    raster_gdi.zig                            -- GDI glyph rasterizer — the Windows "rasterizer provider" consumed by wgpu_core.Gpu(Surface
    scene_common.zig                          -- Backend-independent half of 3D scene rendering: uniform packing, target sizing, the
    scene_pass.zig                            -- Backend-neutral plan of what a scene slot draws: the packed per-instance records, the runs of
    slot_table.zig                            -- Fixed-capacity slot table behind the GPU backends' app-owned resource caches (images, meshes)
    surface_linux.zig                         -- Linux surface provider: builds the wgpu surface source for whichever backend platform/linux.zig
    surface_win32.zig                         -- Win32 HWND surface source for the wgpu backend
    surface_xlib.zig                          -- Xlib Window surface source for the wgpu backend — the Linux counterpart to surface_win32.zig
    text_stage.zig                            -- Backend-neutral text staging for the glyph-atlas path (shared by the wgpu core and the web
    web.zig                                   -- WebGPU backend via zunk
    web_font.zig                              -- CSS font strings for the web backends
    web_scene.zig                             -- Web (zunk WebGPU) 3D scene renderer: the counterpart of wgpu_scene.zig, with the same shape and
    wgpu_c.zig                                -- The single translate-c import (wgpu-c, see src/gpu/vendor/wgpu_c.h) of the wgpu-native headers
    wgpu_core.zig                             -- Shared wgpu-native GPU core, parameterized over a *surface provider* and a *glyph rasterizer*
    wgpu_scene.zig                            -- Native (wgpu-native) 3D scene renderer: mesh resources plus offscreen scene targets
  input/
    a11y.zig                                  -- Accessibility tree builder
    focus.zig                                 -- Focus traversal helpers: walk []Cmd to find the next/previous focusable widget
    keys.zig                                  -- Framework-authoritative list of non-text keys that Hosts may deliver
  layout/
    engine.zig                                -- LayoutEngine: measure / widths / heights / position passes, ClipStack
    scroll_extent.zig                         -- Content extent of a scroll region, measured from the rects the layout passes already produced
    virtual_rows.zig                          -- Measured row extents of a virtual list, read from the rects the layout passes already produced
  platform/
    control_socket.zig                        -- Unix-domain-socket transport for the agent control channel (docs/features/agent-driver.md): a
    headless.zig                              -- Headless Host: scripted input, a fake clock and real text metrics, for running a teak App with
    host.zig                                  -- Host interface: window + input event source
    input_queue.zig                           -- Shared per-window input accumulator for event-driven Hosts (Win32, X11)
    keysym.zig                                -- Keysym -> host-neutral key mapping shared by the Linux hosts
    linux.zig                                 -- The Linux host: one binary, two backends
    native_drops.zig                          -- Turning pasted / dropped bytes into the EffectResults the web host produces, for native hosts
    native_effects.zig                        -- Declarative-effects service for native hosts (Linux/X11 today): what Host.submit /
    wasm.zig                                  -- Wasm host backed by zunk's web.input + web.app modules
    wayland.zig                               -- Wayland host backend: the platform/host.zig contract on top of xdg-shell, the Linux counterpart
    win32.zig                                 -- Win32 host backend
    x11.zig                                   -- X11 host backend
    x11_data.zig                              -- Pure, display-free helpers for the X11 host's clipboard / drag-and-drop / input-method support
    wayland/
      client.zig                              -- libwayland-client, loaded with std.DynLib (no wayland dev package and no -lwayland-client at
      data.zig                                -- Display-free decoding for the Wayland host: everything that turns raw protocol values (button
      protocols.zig                           -- GENERATED by tools/gen_wayland.zig from the Wayland protocol XML — do not edit
  render/
    build.zig                                 -- []Cmd + []Rect + TransientState -> vertices, text/image/scene draws
    canvas_tess.zig                           -- Canvas-primitive tessellation: CanvasPrimitive -> Vertex triangles, clipped to a rect
    sdf.zig                                   -- Rounded rects, borders, gradients and soft shadows as signed-distance quads, drawn by the SAME
    vertex.zig                                -- Vertex layout + quad emitters
  text/
    compose_table.zig                         -- Generated by tools/gen_compose.py (Unicode 14.0.0): do not edit
    face.zig                                  -- Font faces for the teak-text module: the stb_truetype Font wrapper, the (family, weight) face
    fallback.zig                              -- Glyph fallback for the native text path (text-engine section 11, risk 2)
    hb_shaper.zig                             -- HarfBuzz shaper (optional; -Dharfbuzz=true, docs/features/harfbuzz.md)
    measure.zig                               -- Text measurement over the shaper: width == sum(advances), so layout, the caret and the
    raster.zig                                -- Native glyph rasterizer provider for the wgpu text path
    shaper.zig                                -- SimpleShaper: UTF-8 -> positioned glyph ids for Latin and unshaped scripts
    stb_wasm_shim.zig                         -- libc stand-ins for stb_truetype on wasm32-freestanding (no libc there): stb_wasm_impl.c points
    text.zig                                  -- teak-text: the shared native text module (face table, shaper, measurer, rasterizer)

examples/                                     -- each its own build.zig; consume teak as a module
  chrome/                                     -- Chrome: a 1970s engineering-workstation shell built only from stock Teak
  counter_greeter/                            -- the proto-2 demo: composed Counter + Greeter (Components), selection + clipboard, help modal
  effects/                                    -- Effects example: every teak.Effect in one window, each with a visible result
  fonts/                                      -- Fonts example: IBM Plex Mono at three weights, with tracking, on every backend
  gallery/                                    -- The gallery: every Teak widget on one screen, in three looks
  kerf_viewer/                                -- Kerf workstation (dogfood): a Kerf document (mesh + drawings) in three synchronised views
  notes/                                      -- Notes: a multi-line editor and a chat box, both teak.TextAreas
  scene3d/                                    -- scene3d: a depth-tested, lit stud-wall mesh with feature lines (a scene3d Cmd), next to a
  scene_layers/                               -- scene_layers: 2.5D in a 3D scene
  tables/                                     -- Tables at scale: a 100 000-row sortable / resizable / selectable table, a variable-height list
  todo/                                       -- dynamic-content stress: N rows from Model.items, Msg-with-index, scroll-clipped list
  tree/                                       -- recursive view emission with expand/collapse over a flat pre-order node array
  viewport/                                   -- Viewport example: a pan / zoom canvas and a scrollable list with a scrollbar — the two

shaders/
  glyph.wgsl                                  -- Instanced glyph quads sampled from an R8 coverage atlas page
  image.wgsl                                  -- RGBA image: multiply texture color by tint. `color` is the
  quad.wgsl                                   -- Solid quads, plus signed-distance rounded rects (per-corner radii, inside
  scene.wgsl                                  -- 3D scene shader: flat-shaded lit triangles and camera-facing line quads
  scene_grid.wgsl                             -- Infinite ground grid for 3D scenes: a fullscreen triangle whose fragment

tools/
  audit.zig                                   -- HARDLINE drift audit. Walks `src/` and flags the greppable rules
  gate.sh                                     -- Local merge gate for teak (+ the sibling zunk checkout)
  gen_api.zig                                 -- Generated API reference: walks `src/teak.zig` with `std.zig.Ast`, follows
  gen_compose.py                              -- generates src/text/compose_table.zig (Unicode compose sequences)
  gen_tree.py                                 -- regenerates the Module Structure tree in CLAUDE.md / AGENTS.md from the files on disk
  gen_unicode.zig                             -- Generator for `src/core/unicode_tables.zig`
  gen_wayland.zig                             -- Generator for `src/platform/wayland/protocols.zig`
  release.sh                                  -- Cut a release: bump the ONE version (build.zig.zon .version), commit, tag v<version>, push
  teak_drive.zig                              -- teak-drive: drive a running teak app from a shell or from an LLM agent
  web-frame-bench.mjs                         -- rAF cost of a web example under scrolling: serve a zunk `dist/`, load it in headless Chromium
  webshot.mjs                                 -- Web smoke test: serve a zunk `dist/`, load it in headless Chromium with
```
<!-- module-tree:end -->

The library has no external dependencies; `wgpu-native` is owned by teak's build helper (`linkNativeWgpu`/`linkWebWgpu`) and fetched lazily per target. The `src/gpu/` and `src/platform/` split (backend-polymorphic GPU context + Host interface) is executed per [`docs/archive/tasks-file-struct.md`](docs/archive/tasks-file-struct.md). Native backends are assembled by **comptime provider injection** — `wgpu_core.Gpu(Surface, Rasterizer)` is bound to `(surface_win32, GdiRasterizer)` by `native.zig` on Windows and `(surface_xlib, StbttRasterizer)` by `native_linux.zig` on Linux — so each OS's `extern`s only compile for that OS (no `switch (builtin.os.tag)` smuggling platform code into the other's translation unit). Host backends live in `src/platform/{win32,linux (Wayland or X11, picked at runtime),wasm,headless}.zig`; the build exposes the chosen native pair under the stable import names `teak-platform-native` / `teak-gpu-native` so one `ui_main.zig` compiles on every OS.

**Functional gaps overview**: [`docs/features/functional-gaps.md`](docs/features/functional-gaps.md) covers the 8 features added in the `functional_gaps_yolo` branch — overlay layer, image rendering, selection + clipboard, subscriptions, multi-window + dialogs, virtual list, a11y tree, rich text via rich_zig.

**Ergonomic helpers**: [`docs/features/ergonomic-helpers.md`](docs/features/ergonomic-helpers.md) covers the 7 ergonomic helpers also added on `functional_gaps_yolo` — Theme system, mixed-font text builder, sliderDrag, TextField + key dispatch helpers, pushFormRow / popFormRow, ComponentList, and appendDebugOverlay.

## Implementation Status

The framework is **implemented and shipping** (facts below were checked against master `4f898c0`; the open list is `tasks.md`):

- **Platforms:** Windows (Win32 + wgpu-native, x86_64 and native ARM64), Linux (one binary, Wayland when `WAYLAND_DISPLAY` is set else X11), web (wasm + WebGPU via zunk, release wasm stripped of debug info), and a headless Host + Gpu for screenshots / CI. macOS is in review (#54), not on master.
- **Text:** stb_truetype rasterizer into a paged glyph atlas (instanced quads), `Shaper` interface with the built-in SimpleShaper (kerning, ligatures, combining marks) and optional HarfBuzz, exact measure cache, wrapping / ellipsis, UAX #29 graphemes + #14 line breaks, bidi algorithm (#9; rendering queued), `Editor` with undo, `TextField` / `NumericField` / multi-line `TextArea`, IME on X11 / Win32.
- **Rendering:** SDF rounded rects / borders / gradients / soft shadows, images, canvas primitives + chart helper, depth-tested `scene3d` with picking / instancing / grid / section cuts / plane layers.
- **Widgets:** button, checkbox, radio, slider, dropdown, combobox, numeric + date field, toggle, progress, tabs, split, tooltip, toast, dialog, menu bar / context menu, `DataTable`, `VarList`, `TreeList`, kinetic `Scroller`.
- **Loop:** `teak.run` / `Runtime` with event-driven idle (`waitEvents`, caret-aware), declarative `Sub` timers + `animation_frame` (`teak.anim` tweens), declarative effects, declarative GPU resources, `pointerMsg` (stage 1) and the Msg-returning clipboard hooks; every pass is exhaustive over `Cmd` tags and the frame diff is derived by reflection (`core/eql.zig`).
- **Tooling:** `zig build audit` (HARDLINE greppable half + doc drift + module-tree coverage), `zig build bench`, `TEAK_SNAPSHOT` live frames and golden snapshots, headless `zig build shot`, generated API reference (`zig build api` -> `docs/api.md`, `llms-full.txt`), `tools/gate.sh`.
- **In review, not on master:** agent driver / MCP (#46), hot reload (#79), visual-regression suite (#32), accessibility publishing (#58), commands / shortcuts (#60), macOS (#54), font fallback (#44); see `tasks.md`.
- **Examples (13):** `chrome`, `counter_greeter`, `effects`, `fonts`, `gallery`, `kerf_viewer`, `notes`, `scene3d`, `scene_layers`, `tables`, `todo`, `tree`, `viewport`.

Shipped phases, in order: prototype core loop → cleanup/abstraction hardening → text rendering → functional gaps → ergonomic helpers → consumer DX → Linux native → agent DX → the Oct 2026 session (idiomatic-Zig cleanup, text engine, SDF render, widgets, scene, tables at scale, Wayland, idle + animation). History is in `CHANGELOG.md`; the original phase-by-phase prototype guide survives at `docs/archive/init_convo/first_proto.md`.

## Key Documentation

- `docs/HARDLINE.md` -- **the non-negotiable rules**. Read before any design-touching change. See the "Read this first: HARDLINE" section above.
- `llms.txt` -- the whole public API in one read (audit-enforced to stay in sync with `src/teak.zig`); `llms-full.txt` + `docs/api.md` -- generated full API reference (`zig build api`, audit-enforced fresh)
- `docs/consuming-teak.md` -- consumer onboarding: build.zig.zon rules, native / web / headless entry points, App hooks
- `docs/features/run.md` -- the loop, **the one table of every App hook**; `host.md` / `gpu.md` -- Host and Gpu surfaces; `features/README.md` indexes the rest
- `docs/cookbook.md` -- intent-oriented recipes ("add X to my app"), verified against `src/`; `docs/pitfalls.md` -- bugs that took real debugging
- `docs/PARITY.md` -- what exists vs egui / Dear ImGui / iced / Slint / Flutter; `docs/REVIEW-2026-10.md` -- strategic review; `docs/qa-2026-10.md` -- visual QA findings
- `tasks.md` -- the open list; `CHANGELOG.md` -- what shipped; `docs/migration-*.md` -- breaking-change notes
- `spec.md` -- full architecture specification
- `docs/archive/` -- historical design conversations (first prototype guide, diagrams, refinement notes)

## Zig Conventions

- Types: `PascalCase`. Functions: `camelCase` (std-lib style — `hitTest`, `buttonDisabled`). Enum variants: lowercase with underscores.
- Explicit allocators everywhere. Arena allocators for per-frame data.
- Convenience emitters on `CmdBuffer` stay non-error-returning; allocation failure goes through `core/oom.zig`'s `oom()` (`alloc(...) catch oom()`), a loud `@panic` in every optimize mode. Never `catch unreachable` an allocation (UB in release).
- Text measurement flows through the Host's `TextMeasurer` (real platform metrics at layout time). `teak.monoMeasurer()` is the stateless stub for CLI canaries and tests. `CHAR_WIDTH` is gone — `zig build audit` forbids reintroducing it.

## Versioning
`build.zig.zon` `.version` is the single source of truth; code reads `teak.version` (from `build_options`). Never write a version literal elsewhere, never bump it in a feature PR. Releases are cut explicitly with `tools/release.sh <semver>`. See [`docs/VERSIONING.md`](docs/VERSIONING.md).
