# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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

Requires **Zig 0.16.0+**.

The repo is split into a **library** (root `build.zig`) and **examples** (each with their own `build.zig`). Library tests run from root; example steps run from the example's directory.

```sh
# Library
zig build test                              # Library tests (run from repo root)

# Example: counter_greeter (CLI + wgpu UI)
cd examples/counter_greeter
zig build test                              # Example tests
zig build run                               # CLI canary
zig build ui -Dtarget=aarch64-windows-gnu   # wgpu + Win32 UI (ARM64 host)
zig build ui                                # wgpu + Win32 UI (x86_64 host)
```

The `wgpu-native` dependency lives in the example's `build.zig.zon` and is fetched automatically on first build of a UI target. The root library has no external dependencies. The build targets Windows ARM64 (Snapdragon X Elite) with a workaround for Zig's missing `i8mm` CPU feature detection on aarch64.

### Windows ARM64 toolchain workaround (Zig 0.16.0)

Zig 0.16.0's native `aarch64-windows` compiler binary is broken upstream ([Codeberg #31865](https://codeberg.org/ziglang/zig/issues/31865)) — it segfaults on any compile. This machine runs the **x86_64-windows** `zig.exe` (installed at `C:\zig\`) under Windows-on-ARM (Prism) emulation and **cross-compiles** to aarch64-windows.

Implications for building:
- The native default target when running `zig build` is `x86_64-windows` (what Prism reports).
- The example's `build.zig.zon` declares two wgpu-native deps (`wgpu-native-aarch64` and `wgpu-native-x86_64`); its `build.zig` selects the matching one by `target.result.cpu.arch` so no flags are needed on a native host.
- **On this aarch64 host, pass `-Dtarget=aarch64-windows-gnu` to `zig build ui`** so the output binary runs natively instead of under Prism. Without it, the build still succeeds — you just get an x86_64 UI binary that runs emulated. (On a native x86_64 Windows host, no flag is needed.)
- Library `zig build test` from the root works without the flag (it doesn't link wgpu).

Full details: [`docs/zig-016-win-arm64-crash.md`](docs/zig-016-win-arm64-crash.md). When #31865 ships a fix, drop the emulation workaround and remove `-Dtarget=` from `zig build ui`.

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
| **Render** | Converts `[]Cmd` + `[]Rect` + `TransientState` into wgpu draw calls (colored quads). | `render_pass()`, `Vertex` |
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

Add a variant to the `Cmd` union + a case in each pass (layout, hit-test, render) + a convenience method on `CmdBuffer`.

## Module Structure

```
src/                           -- the library, consumable as a Zig module
  teak.zig                     -- public library root / re-exports
  core/
    cmd.zig                    -- Cmd union, CmdBuffer, arena management
                               --   (incl. overlay, image, virtual_list, rich_text variants;
                               --    pushFormRow/popFormRow; mixedText; theme-aware emitters)
    component.zig              -- Components(), validateComponent, buildMsgs, MsgsStructFor
    component_list.zig         -- ComponentList(Child, cap) — dynamic homogeneous list
                               --   (HARDLINE §2 hatch 1)
    text_field.zig             -- TextField(cap) canonical text-input component +
                               --   textFieldChar/textFieldSpecial/textFieldReplaceSelection
                               --   key dispatch helpers
    theme.zig                  -- Theme, Palette, Typography, dark/light presets
    debug_overlay.zig          -- appendDebugOverlay — cmd+rect dump as overlay
    transient.zig              -- hover/press/focus state (TransientState)
    text.zig                   -- TextMeasurer interface + FontSpec + TextureHandle
    sub.zig                    -- Sub(Msg) declarative timers (HARDLINE §2 hatch 6)
  layout/
    engine.zig                 -- measure + position passes
  input/
    hit_test.zig               -- mouse -> CmdIndex -> Msg (two-layer: base + overlay);
                               --   sliderDrag helper
    focus.zig                  -- next/prev focusable traversal
    keys.zig                   -- SpecialKey (incl. shift+arrows, ctrl chords)
    a11y.zig                   -- []Cmd + []Rect -> []A11yNode
  render/
    vertex.zig                 -- Vertex struct + emitQuad
    build.zig                  -- []Cmd + []Rect + TransientState
                               --   -> vertex / text_draws / image_draws buffers

examples/
  counter_greeter/             -- the proto-2 demo; consumes teak as a module
    build.zig                  -- wires teak + rich_zig + Win32/web targets
    build.zig.zon
    src/
      main.zig                 -- CLI canary entry
      ui_main.zig              -- wgpu + Win32 entry
      app.zig                  -- composed app (counter + greeter + help modal)
      counter.zig
      greeter.zig              -- text input w/ selection + clipboard editing
      rich_zig_adapter.zig     -- rich_zig markup -> teak RichTextSpan[]

shaders/
  quad.wgsl              -- shader for colored rectangles
  textured_quad.wgsl     -- alpha-from-texture (text glyphs)
  image.wgsl             -- texture * tint (RGBA images)
```

The library has no external dependencies; `wgpu-native` is owned by whichever example wires up a GPU host. The `src/gpu/` and `src/platform/` split (backend-polymorphic GPU context + Host interface) is executed per [`docs/archive/tasks-file-struct.md`](docs/archive/tasks-file-struct.md); concrete backends live in `src/gpu/{native,web}.zig` and `src/platform/{win32,wasm}.zig`.

**Functional gaps overview**: [`docs/features/functional-gaps.md`](docs/features/functional-gaps.md) covers the 8 features added in the `functional_gaps_yolo` branch — overlay layer, image rendering, selection + clipboard, subscriptions, multi-window + dialogs, virtual list, a11y tree, rich text via rich_zig.

**Ergonomic helpers**: [`docs/features/ergonomic-helpers.md`](docs/features/ergonomic-helpers.md) covers the 7 ergonomic helpers also added on `functional_gaps_yolo` — Theme system, mixed-font text builder, sliderDrag, TextField + key dispatch helpers, pushFormRow / popFormRow, ComponentList, and appendDebugOverlay.

## Implementation Status

The project is in **design-complete, implementation-starting** phase. The prototype goal is a clickable counter demonstrating the full closed loop. Implementation follows six sequential phases (see `docs/archive/init_convo/first_proto.md` for details and checkpoints):

1. Model/Msg/update (pure Zig, no wgpu)
2. CmdBuffer + view function
3. Layout pass (measure + position)
4. Render pass (wgpu colored quads)
5. Hit-test pass
6. Close the loop (wire main.zig)
7. Stretch: TransientState + hover

## Key Documentation

- `docs/HARDLINE.md` -- **the non-negotiable rules**. Read before any design-touching change. See the "Read this first: HARDLINE" section above.
- `spec.md` -- full architecture specification
- `docs/archive/init_convo/first_proto.md` -- phase-by-phase prototype guide with checkpoints
- `docs/archive/init_convo/ui-framework-diagrams.md` -- 15 architecture diagrams
- `docs/archive/init_convo/ui-framework-refinement.md` -- escape hatches, design tradeoffs, implementation traps

## Zig Conventions

- Types: `PascalCase`. Functions: `snake_case`. Enum variants: lowercase with underscores.
- Explicit allocators everywhere. Arena allocators for per-frame data.
- Convenience emitters on `CmdBuffer` use `catch unreachable` (arena OOM is unrecoverable).
- Text measurement uses monospace approximation (`content.len * CHAR_WIDTH`) for the prototype.
